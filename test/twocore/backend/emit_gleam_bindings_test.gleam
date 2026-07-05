//// P12-02 compile+call differential for the Gleam bindings emitter (`emit_gleam`).
////
//// Per P7 these are **compile + call** tests against the WebAssembly spec — NOT golden
//// change-detectors. The headline test builds two real modules through the pipeline, `describe`s
//// them, `emit_gleam`s the bindings, writes the emitted `.gleam` + `.erl` (+ a hand-written
//// driver) into a scratch Gleam project, compiles it with the **real `gleam` toolchain**
//// (`twocore_bindings_ffi:compile_load_gleam`), and calls typed exports through the compiled
//// binding — asserting the native result equals BOTH the WASM-spec value AND the raw in-process
//// `.beam` oracle (`twocore_threaded_test_ffi`). Coverage: a signed-int export, a multi-value
//// tuple export, a trapping export (`Error(Trap)`), a finite float export, a non-finite (`+Inf`)
//// float via the `NonFinite`/raw-bits path, an f32 single-rounding round-trip, a zero-result
//// export, threaded state (two `bump`s accumulate; the old instance is immutable), and the
//// Stateless two-shape API (no `Instance`, re-instantiating internally).
////
//// The pure unit tests (no toolchain) pin determinism, the three-file drop, the no-`.beam`-atom-
//// collision module name, and the Stateless vs Threaded surface shapes (R19).

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import gleam/string
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/backend/emit_gleam_bindings
import twocore/backend/iface
import twocore/ir
import twocore/runtime/profiles

// ───────────────────────────── IR fixtures ─────────────────────────────

/// A pure `add(i32,i32)->[i32]` (`p0 + p1`, no state).
fn add_fn() -> ir.Function {
  ir.Function(
    name: "add",
    params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Num(ir.IAdd(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
  )
}

/// A pure MULTI-VALUE `divmod(i32,i32)->[i32,i32]` = `<div_s, rem_s>`; traps on a zero divisor.
fn divmod_fn() -> ir.Function {
  ir.Function(
    name: "divmod",
    params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
    result: [ir.TI32, ir.TI32],
    locals: [],
    body: ir.Let(
      ["q"],
      ir.Num(ir.IDivS(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
      ir.Let(
        ["r"],
        ir.Num(ir.IRemS(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
        ir.Return([ir.Var("q"), ir.Var("r")]),
      ),
    ),
  )
}

/// A pure `fdiv(f64,f64)->[f64]` (`p0 / p1`). Float division by zero yields `±Inf` (no trap) —
/// the non-finite path.
fn fdiv_fn() -> ir.Function {
  ir.Function(
    name: "fdiv",
    params: [ir.Local("p0", ir.TF64), ir.Local("p1", ir.TF64)],
    result: [ir.TF64],
    locals: [],
    body: ir.Num(ir.FDiv(ir.FW64), [ir.Var("p0"), ir.Var("p1")]),
  )
}

/// A pure `f32id(f32)->[f32]` = `p0 + 0.0f` (identity, exercising f32 single-rounding).
fn f32id_fn() -> ir.Function {
  ir.Function(
    name: "f32id",
    params: [ir.Local("p0", ir.TF32)],
    result: [ir.TF32],
    locals: [],
    body: ir.Num(ir.FAdd(ir.FW32), [ir.Var("p0"), ir.ConstF32(0)]),
  )
}

/// A pure ZERO-RESULT `noop()->[]`.
fn noop_fn() -> ir.Function {
  ir.Function(
    name: "noop",
    params: [],
    result: [],
    locals: [],
    body: ir.Values([]),
  )
}

/// A state-MUTATING `bump(i32)->[i32]`: `counter += p0; return counter` (reads+writes a global,
/// so `touches_state == True`).
fn bump_fn() -> ir.Function {
  ir.Function(
    name: "bump",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Let(
      ["c"],
      ir.GlobalGet("counter"),
      ir.Let(
        ["s"],
        ir.Num(ir.IAdd(ir.W32), [ir.Var("c"), ir.Var("p0")]),
        ir.Let(
          [],
          ir.GlobalSet("counter", ir.Var("s")),
          ir.Return([ir.Var("s")]),
        ),
      ),
    ),
  )
}

/// A mutable `i32` global `counter` (init 0) — the state `bump` threads.
fn counter_global() -> ir.GlobalDecl {
  ir.GlobalDecl("counter", ir.TI32, True, ir.Values([ir.ConstI32(0)]))
}

/// Assemble a numerics module named `twocore@wasm@<base>` from `functions`, exporting each by its
/// own name in order, with one mutable global.
fn module_of(base: String, functions: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "twocore@wasm@" <> base,
    uses_numerics: True,
    memories: [],
    globals: [counter_global()],
    imports: [],
    functions: functions,
    exports: list.map(functions, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// The THREADED fixture (a `bump` reaches state → the whole surface is Threaded): add, divmod,
/// fdiv, f32id, noop (all pure) + bump (state).
fn module_a() -> ir.Module {
  module_of("statemod", [
    add_fn(),
    divmod_fn(),
    fdiv_fn(),
    f32id_fn(),
    noop_fn(),
    bump_fn(),
  ])
}

/// The STATELESS fixture (no export reaches the global → the pure surface): add + fdiv.
fn module_b() -> ir.Module {
  module_of("puremod", [add_fn(), fdiv_fn()])
}

// ───────────────────────────── oracle plumbing (raw in-process `.beam`) ─────────────────────────────

/// Emit `m` under the accepted portable binding (Threaded + Paged + TablePaged), compile it to a
/// `.beam`, and LOAD it into the test VM — so the emitted binding's `@external` dispatch resolves.
/// Returns the loaded module atom (= `m.name`). A `let assert` here is the test's success contract.
fn load(m: ir.Module) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(m, profiles.portable())
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

// The raw run-ABI oracle (`test/twocore_threaded_test_ffi.erl`): drive `instantiate/0` and an
// export DIRECTLY (leading `St`, `{Package, St'}` return), bypassing the binding — the in-process
// pipeline truth the compiled binding must match.
@external(erlang, "twocore_threaded_test_ffi", "instantiate")
fn t_instantiate(module: Atom) -> Result(Dynamic, String)

@external(erlang, "twocore_threaded_test_ffi", "invoke")
fn t_invoke_int(
  module: Atom,
  function: Atom,
  st: Dynamic,
  args: List(Int),
) -> Result(#(Int, Dynamic), String)

@external(erlang, "twocore_threaded_test_ffi", "invoke")
fn t_invoke_pair(
  module: Atom,
  function: Atom,
  st: Dynamic,
  args: List(Int),
) -> Result(#(#(Int, Int), Dynamic), String)

// ───────────────────────────── compile+call FFI (real gleam toolchain) ─────────────────────────────

@external(erlang, "twocore_bindings_ffi", "which")
fn which(exe: String) -> Result(String, Nil)

@external(erlang, "twocore_bindings_ffi", "compile_load_gleam")
fn compile_load_gleam(
  files: List(#(String, String)),
  main: Atom,
) -> Result(Atom, String)

// `call/3` re-typed per (arg-list, result) shape — `@external` does not check the wire, and the
// driver returns bare comparable values (int / tuple / string / float / bit-array).
@external(erlang, "twocore_bindings_ffi", "call")
fn call_i_i(m: Atom, f: Atom, args: List(Int)) -> Result(Int, String)

@external(erlang, "twocore_bindings_ffi", "call")
fn call_i_pair(m: Atom, f: Atom, args: List(Int)) -> Result(#(Int, Int), String)

@external(erlang, "twocore_bindings_ffi", "call")
fn call_i_str(m: Atom, f: Atom, args: List(Int)) -> Result(String, String)

@external(erlang, "twocore_bindings_ffi", "call")
fn call_f_f(m: Atom, f: Atom, args: List(Float)) -> Result(Float, String)

@external(erlang, "twocore_bindings_ffi", "call")
fn call_f_bits(m: Atom, f: Atom, args: List(Float)) -> Result(BitArray, String)

@external(erlang, "twocore_bindings_ffi", "call")
fn call_f_i(m: Atom, f: Atom, args: List(Float)) -> Result(Int, String)

/// A hand-written Gleam driver that `import`s BOTH emitted bindings and exposes flat, bare-valued
/// functions the differential calls through `call/3`. Prelude-only (it lives in the dependency-free
/// probe project), so it uses `let assert`/`case`/tuples and the bindings' `pub` types only.
fn driver_source() -> String {
  "import twocore_wasm_statemod_bindings as s
import twocore_wasm_puremod_bindings as p

pub fn a_add(a: Int, b: Int) -> Int {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(v) = s.add(inst, a, b)
  v
}

pub fn a_divmod(a: Int, b: Int) -> #(Int, Int) {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(qr) = s.divmod(inst, a, b)
  qr
}

pub fn a_divmod_trap(a: Int, b: Int) -> String {
  let assert Ok(inst) = s.instantiate()
  case s.divmod(inst, a, b) {
    Ok(_) -> \"NOTRAP\"
    Error(s.Trap(reason)) -> reason
  }
}

pub fn a_fdiv_finite(a: Float, b: Float) -> Float {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(r) = s.fdiv(inst, s.Finite(a), s.Finite(b))
  let assert s.Finite(v) = r
  v
}

pub fn a_fdiv_bits(a: Float, b: Float) -> BitArray {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(r) = s.fdiv(inst, s.Finite(a), s.Finite(b))
  s.f64_bits(r)
}

pub fn a_fdiv_is_nonfinite(a: Float, b: Float) -> Int {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(r) = s.fdiv(inst, s.Finite(a), s.Finite(b))
  case r {
    s.NonFinite(_) -> 1
    s.Finite(_) -> 0
  }
}

pub fn a_f32id_bits(x: Float) -> BitArray {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(r) = s.f32id(inst, s.Finite(x))
  s.f32_bits(r)
}

pub fn a_noop() -> Int {
  let assert Ok(inst) = s.instantiate()
  case s.noop(inst) {
    Ok(Nil) -> 1
    Error(_) -> 0
  }
}

pub fn a_bump_twice(x: Int, y: Int) -> Int {
  let assert Ok(inst0) = s.instantiate()
  let assert Ok(#(_v1, inst1)) = s.bump(inst0, x)
  let assert Ok(#(v2, _inst2)) = s.bump(inst1, y)
  v2
}

pub fn a_bump_old(x: Int, y: Int) -> Int {
  let assert Ok(inst0) = s.instantiate()
  let assert Ok(#(_v1, _inst1)) = s.bump(inst0, x)
  let assert Ok(#(v, _)) = s.bump(inst0, y)
  v
}

pub fn b_add(a: Int, b: Int) -> Int {
  let assert Ok(v) = p.add(a, b)
  v
}

pub fn b_fdiv_finite(a: Float, b: Float) -> Float {
  let assert Ok(r) = p.fdiv(p.Finite(a), p.Finite(b))
  let assert p.Finite(v) = r
  v
}
"
}

/// The `.gleam`/`.erl` source files of an emitted binding, as `#(basename, content)` for
/// `compile_load_gleam` (drops the README — not a compilation input).
fn source_files(desc: iface.Iface) -> List(#(String, String)) {
  emit_gleam_bindings.emit_gleam(desc)
  |> list.filter_map(fn(gf) {
    case
      string.ends_with(gf.path, ".gleam") || string.ends_with(gf.path, ".erl")
    {
      True -> Ok(#(gf.path, gf.content))
      False -> Error(Nil)
    }
  })
}

// ───────────────────────────── the compile+call differential ─────────────────────────────

/// THE headline: compile both emitted bindings with the real `gleam` toolchain and call typed
/// exports through them, matching the WASM-spec value and the raw in-process `.beam` oracle.
///
/// Guarded on `gleam` being on `PATH` (always true in-tree). Compiles ONCE (both bindings + the
/// driver in one project), then calls many exports — CI-affordable (P7/R25b).
pub fn gleam_binding_compile_call_test() {
  case which("gleam") {
    Error(_) -> Nil
    Ok(_) -> run_differential()
  }
}

fn run_differential() -> Nil {
  // Load both compiled `.beam`s into the VM (so the bindings' @external dispatch resolves).
  let sa = load(module_a())
  let _sb = load(module_b())

  let assert Ok(desc_a) = iface.describe(module_a(), profiles.portable())
  let assert Ok(desc_b) = iface.describe(module_b(), profiles.portable())
  assert desc_a.state_model == iface.Threaded
  assert desc_b.state_model == iface.Stateless

  // Compile the whole drop (both bindings + shims + the driver) once, with the real toolchain.
  let project =
    list.flatten([
      [#("driver.gleam", driver_source())],
      source_files(desc_a),
      source_files(desc_b),
    ])
  let assert Ok(_) = compile_load_gleam(project, atom.create("driver"))
  let d = atom.create("driver")

  // ── signed int (the headline): i32.add(2, -3) == 0xFFFFFFFF == -1 (two's-complement) ──
  assert call_i_i(d, atom.create("a_add"), [2, -3]) == Ok(-1)
  // 0x7FFFFFFF + 1 wraps to 0x80000000 == INT_MIN == -2147483648.
  assert call_i_i(d, atom.create("a_add"), [2_147_483_647, 1])
    == Ok(-2_147_483_648)

  // ── multi-value tuple: divmod(17,5)=<3,2>; signed divmod(-7,2)=<-3,-1> (trunc toward zero) ──
  assert call_i_pair(d, atom.create("a_divmod"), [17, 5]) == Ok(#(3, 2))
  assert call_i_pair(d, atom.create("a_divmod"), [-7, 2]) == Ok(#(-3, -1))

  // ── trap: divmod(x, 0) → Error(Trap(reason)) carrying the spec phrase, never a raw exception ──
  let assert Ok(reason) = call_i_str(d, atom.create("a_divmod_trap"), [10, 0])
  assert string.contains(reason, "wasm_trap")
  assert string.contains(reason, "int_div_by_zero")

  // ── finite float: 6.0 / 2.0 == 3.0 (native Float on the Finite path) ──
  assert call_f_f(d, atom.create("a_fdiv_finite"), [6.0, 2.0]) == Ok(3.0)

  // ── non-finite float (the NonFinite/raw-bits path): 1.0 / 0.0 == +Inf ──
  assert call_f_i(d, atom.create("a_fdiv_is_nonfinite"), [1.0, 0.0]) == Ok(1)
  assert call_f_i(d, atom.create("a_fdiv_is_nonfinite"), [6.0, 2.0]) == Ok(0)
  // +Inf f64 raw bits = 0x7FF0000000000000, big-endian bytes:
  assert call_f_bits(d, atom.create("a_fdiv_bits"), [1.0, 0.0])
    == Ok(<<127, 240, 0, 0, 0, 0, 0, 0>>)

  // ── f32 single-rounding: 0.1 rounds to binary32 0x3DCCCCCD (distinct from the f64 pattern) ──
  assert call_f_bits(d, atom.create("a_f32id_bits"), [0.1])
    == Ok(<<61, 204, 204, 205>>)

  // ── zero-result export → Ok(Nil) ──
  assert call_i_i(d, atom.create("a_noop"), []) == Ok(1)

  // ── threaded state: two bumps accumulate (5 then 10 → 15); the OLD instance stays 0-based ──
  assert call_i_i(d, atom.create("a_bump_twice"), [5, 10]) == Ok(15)
  assert call_i_i(d, atom.create("a_bump_old"), [5, 10]) == Ok(10)

  // ── Stateless two-shape API: no Instance in the surface, re-instantiating internally ──
  assert call_i_i(d, atom.create("b_add"), [100, -1]) == Ok(99)
  assert call_f_f(d, atom.create("b_fdiv_finite"), [9.0, 3.0]) == Ok(3.0)

  // ── the raw in-process `.beam` oracle: the binding decoded exactly what the pipeline produced ──
  let assert Ok(st) = t_instantiate(sa)
  // add: the raw ABI returns the UNSIGNED pattern 4294967295; the binding presented it as -1.
  let assert Ok(#(raw_add, _)) =
    t_invoke_int(sa, atom.create("add"), st, [2, 4_294_967_293])
  assert raw_add == 4_294_967_295
  // divmod: the raw ABI package is the tuple {3, 2}; the binding presented #(3, 2).
  let assert Ok(#(raw_qr, _)) =
    t_invoke_pair(sa, atom.create("divmod"), st, [17, 5])
  assert raw_qr == #(3, 2)
  // fdiv: 1.0 (bits 4607182418800017408) / 0.0 → +Inf (bits 9218868437227405312); binding = NonFinite(+Inf bytes).
  let assert Ok(#(raw_inf, _)) =
    t_invoke_int(sa, atom.create("fdiv"), st, [4_607_182_418_800_017_408, 0])
  assert raw_inf == 9_218_868_437_227_405_312

  Nil
}

// ───────────────────────────── pure unit tests (no toolchain) ─────────────────────────────

/// Deterministic output (R25a): the same `Iface` renders byte-identical files.
pub fn deterministic_output_test() {
  let assert Ok(desc) = iface.describe(module_a(), profiles.portable())
  assert emit_gleam_bindings.emit_gleam(desc)
    == emit_gleam_bindings.emit_gleam(desc)
}

/// `emit_gleam` returns exactly THREE files, named off the legalized module base, in a fixed order
/// (the `.gleam`, its `.erl` catch-shim, the README) — R22.
pub fn emits_three_named_files_test() {
  let assert Ok(desc) = iface.describe(module_a(), profiles.portable())
  let files = emit_gleam_bindings.emit_gleam(desc)
  assert list.map(files, fn(f) { f.path })
    == [
      "twocore_wasm_statemod_bindings.gleam",
      "twocore_wasm_statemod_bindings_ffi.erl",
      "twocore_wasm_statemod_bindings_README.md",
    ]
}

/// The generated Gleam module name is legalized from `module_name`, so it can NEVER collide with
/// the loaded `.beam` module atom (a `foo.gleam` → Erlang module `foo` would clobber `foo.beam`).
/// It is `@`-free, differs from `<module_name>.gleam`, and still dispatches to the exact atom.
pub fn binding_module_name_differs_from_beam_atom_test() {
  let assert Ok(desc) = iface.describe(module_a(), profiles.portable())
  let assert [gleam_file, ..] = emit_gleam_bindings.emit_gleam(desc)
  assert gleam_file.path != desc.module_name <> ".gleam"
  assert !string.contains(gleam_file.path, "@")
  assert string.contains(
    gleam_file.content,
    "@external(erlang, \"twocore@wasm@statemod\", \"add\")",
  )
}

/// The Threaded surface (R19): an opaque `Instance`, a `Result`-returning `instantiate/0`, a
/// state-reaching export threading the `Instance` back, and a pure export dropping it.
pub fn threaded_shape_test() {
  let assert Ok(desc) = iface.describe(module_a(), profiles.portable())
  let assert [gleam_file, ..] = emit_gleam_bindings.emit_gleam(desc)
  let c = gleam_file.content
  assert desc.state_model == iface.Threaded
  assert string.contains(c, "pub opaque type Instance {")
  assert string.contains(c, "pub fn instantiate() -> Result(Instance, Trap)")
  assert string.contains(
    c,
    "pub fn bump(inst: Instance, a0: Int) -> Result(#(Int, Instance), Trap)",
  )
  assert string.contains(
    c,
    "pub fn add(inst: Instance, a0: Int, a1: Int) -> Result(Int, Trap)",
  )
}

/// The Stateless surface (R19, "the beautiful pure file"): NO `Instance`, NO public `instantiate`,
/// each export `fn(args) -> Result(T, Trap)` re-instantiating internally per call.
pub fn stateless_shape_test() {
  let assert Ok(desc) = iface.describe(module_b(), profiles.portable())
  let assert [gleam_file, ..] = emit_gleam_bindings.emit_gleam(desc)
  let c = gleam_file.content
  assert desc.state_model == iface.Stateless
  assert !string.contains(c, "pub opaque type Instance")
  assert !string.contains(c, "pub fn instantiate")
  assert string.contains(c, "pub fn add(a0: Int, a1: Int) -> Result(Int, Trap)")
  assert string.contains(c, "let st = raw_instantiate()")
}
