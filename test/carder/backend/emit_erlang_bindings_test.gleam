//// P12-03 compile+call differential for the Erlang bindings emitter (`emit_erlang`).
////
//// Per P7 these are **compile + call** tests against the WebAssembly spec — NOT golden
//// change-detectors. The headline test builds two real modules through the pipeline, `describe`s
//// them, `emit_erlang`s the bindings, compiles the emitted `.erl` with the **real in-VM Erlang
//// compiler** (`carder_bindings_ffi:compile_load_erlang` → `compile:file`), and calls typed
//// exports through the compiled binding — asserting the native result equals BOTH the WASM-spec
//// value AND the raw in-process `.beam` oracle (`carder_threaded_test_ffi`). Coverage: a signed-int
//// export, a multi-value tuple export, a trapping export (`{error, {wasm_trap, _}}`), a finite
//// float export, a non-finite (`+Inf`) float via the `{nonfinite, _}`/raw-bits tagged tuple, an f32
//// single-rounding round-trip, a zero-result export, threaded state (two `bump`s accumulate; the old
//// instance is immutable), and the Stateless two-shape API (no `instance()`, re-instantiating
//// internally).
////
//// The pure unit tests (no external calls) pin determinism, the single-file emission, and the
//// Stateless vs Threaded `-spec` surface shapes (R19).
////
//// The binding module base names here (`carder@wasm@estate` / `carder@wasm@epure`) are
//// deliberately distinct from the Gleam sibling test's (`statemod`/`puremod`) so the emitted
//// binding module atom cannot clash with the Gleam binding's compiled module in the shared test VM
//// (R16 — the cross-language collision the capstone resolves).

import carder/backend/build_beam
import carder/backend/emit_core
import carder/backend/emit_erlang_bindings
import carder/backend/iface
import carder/ir
import carder/runtime/profiles
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import gleam/string

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

/// Assemble a numerics module named `carder@wasm@<base>` from `functions`, exporting each by its
/// own name in order, with one mutable global.
fn module_of(base: String, functions: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "carder@wasm@" <> base,
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
  module_of("estate", [
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
  module_of("epure", [add_fn(), fdiv_fn()])
}

// ───────────────────────────── oracle plumbing (raw in-process `.beam`) ─────────────────────────────

/// Emit `m` under the accepted portable binding (Threaded + Paged + TablePaged), compile it to a
/// `.beam`, and LOAD it into the test VM — so the emitted binding's remote dispatch resolves.
/// Returns the loaded module atom (= `m.name`). A `let assert` here is the test's success contract.
fn load(m: ir.Module) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(m, profiles.portable())
  let assert Ok(mod) = build_beam.compile_and_load(cm)
  mod
}

// The raw run-ABI oracle (`test/carder_threaded_test_ffi.erl`): drive `instantiate/0` and an
// export DIRECTLY (leading `St`, `{Package, St'}` return), bypassing the binding — the in-process
// pipeline truth the compiled binding must match.
@external(erlang, "carder_threaded_test_ffi", "instantiate")
fn t_instantiate(module: Atom) -> Result(Dynamic, String)

@external(erlang, "carder_threaded_test_ffi", "invoke")
fn t_invoke_int(
  module: Atom,
  function: Atom,
  st: Dynamic,
  args: List(Int),
) -> Result(#(Int, Dynamic), String)

@external(erlang, "carder_threaded_test_ffi", "invoke")
fn t_invoke_pair(
  module: Atom,
  function: Atom,
  st: Dynamic,
  args: List(Int),
) -> Result(#(#(Int, Int), Dynamic), String)

// ───────────────────────────── compile+call FFI (real in-VM erlc) ─────────────────────────────

@external(erlang, "carder_bindings_ffi", "compile_load_erlang")
fn compile_load_erlang(
  files: List(#(String, String)),
  main: Atom,
) -> Result(Atom, String)

// `call/3` re-typed per binding-return shape. `call/3` wraps the binding's own return in `{ok, _}`
// (its exception safety net), so a NORMAL binding return `{ok, T}` / `{error, Trap}` nests as
// `Ok(Ok(T))` / `Ok(Error(Trap))`; an emitter bug (bad arity ⇒ `undef`) surfaces as `Error(text)`.
@external(erlang, "carder_bindings_ffi", "call")
fn call_i(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(Int, Dynamic), String)

@external(erlang, "carder_bindings_ffi", "call")
fn call_pair(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(#(Int, Int), Dynamic), String)

@external(erlang, "carder_bindings_ffi", "call")
fn call_finite(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(#(Atom, Float), Dynamic), String)

@external(erlang, "carder_bindings_ffi", "call")
fn call_nonfinite(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(#(Atom, BitArray), Dynamic), String)

@external(erlang, "carder_bindings_ffi", "call")
fn call_unit(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(Atom, Dynamic), String)

@external(erlang, "carder_bindings_ffi", "call")
fn call_inst(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(Dynamic, Dynamic), String)

@external(erlang, "carder_bindings_ffi", "call")
fn call_ti(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(#(Int, Dynamic), Dynamic), String)

/// Coerce any Gleam value to `Dynamic` (identity at runtime) — to build the heterogeneous
/// `[Inst, Arg, …]` apply list the binding's exports take.
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

/// Coerce a trap `Dynamic` (`{wasm_trap, Kind}`) to a `#(Atom, Atom)` so the kind can be matched.
@external(erlang, "gleam_stdlib", "identity")
fn as_trap(d: Dynamic) -> #(Atom, Atom)

/// A finite `floatval()` argument `{finite, X}` as a `Dynamic` the binding's float exports accept.
fn finite(x: Float) -> Dynamic {
  to_dynamic(#(atom.create("finite"), x))
}

/// The single `.erl` source of an emitted binding, as `#(basename, content)` for
/// `compile_load_erlang`. `emit_erlang` returns exactly one file.
fn source_file(desc: iface.Iface) -> #(String, String) {
  let assert [gf] = emit_erlang_bindings.emit_erlang(desc)
  #(gf.path, gf.content)
}

// ───────────────────────────── the compile+call differential ─────────────────────────────

/// THE headline: compile both emitted bindings with the real in-VM Erlang compiler and call typed
/// exports through them, matching the WASM-spec value and the raw in-process `.beam` oracle.
///
/// `compile:file` is always available (Erlang IS the BEAM), so this is unconditional. Compiles ONCE
/// (both bindings in one call), then calls many exports — CI-affordable (P7/R25b).
pub fn erlang_binding_compile_call_test() {
  // Load both compiled `.beam`s into the VM (so the bindings' remote dispatch resolves).
  let sa = load(module_a())
  let _sb = load(module_b())

  let assert Ok(desc_a) = iface.describe(module_a(), profiles.portable())
  let assert Ok(desc_b) = iface.describe(module_b(), profiles.portable())
  assert desc_a.state_model == iface.Threaded
  assert desc_b.state_model == iface.Stateless

  // Compile both bindings (one in-VM compile per file) and load them.
  let a_atom = atom.create("carder_wasm_estate_bindings")
  let b_atom = atom.create("carder_wasm_epure_bindings")
  let assert Ok(_) =
    compile_load_erlang([source_file(desc_a), source_file(desc_b)], a_atom)

  // Instantiate the Threaded binding once; the pure exports reuse the fresh instance.
  let assert Ok(Ok(inst)) = call_inst(a_atom, atom.create("instantiate"), [])

  // ── signed int (the headline): i32.add(2, -3) == 0xFFFFFFFF == -1 (two's-complement) ──
  assert call_i(a_atom, atom.create("add"), [
      inst,
      to_dynamic(2),
      to_dynamic(-3),
    ])
    == Ok(Ok(-1))
  // 0x7FFFFFFF + 1 wraps to 0x80000000 == INT_MIN == -2147483648.
  assert call_i(a_atom, atom.create("add"), [
      inst,
      to_dynamic(2_147_483_647),
      to_dynamic(1),
    ])
    == Ok(Ok(-2_147_483_648))

  // ── multi-value tuple: divmod(17,5)=<3,2>; signed divmod(-7,2)=<-3,-1> (trunc toward zero) ──
  assert call_pair(a_atom, atom.create("divmod"), [
      inst,
      to_dynamic(17),
      to_dynamic(5),
    ])
    == Ok(Ok(#(3, 2)))
  assert call_pair(a_atom, atom.create("divmod"), [
      inst,
      to_dynamic(-7),
      to_dynamic(2),
    ])
    == Ok(Ok(#(-3, -1)))

  // ── trap: divmod(x, 0) → {error, {wasm_trap, int_div_by_zero}}, never a raw exception ──
  let assert Ok(Error(trap)) =
    call_pair(a_atom, atom.create("divmod"), [
      inst,
      to_dynamic(10),
      to_dynamic(0),
    ])
  assert as_trap(trap)
    == #(atom.create("wasm_trap"), atom.create("int_div_by_zero"))

  // ── finite float: 6.0 / 2.0 == 3.0 (native float() on the {finite, _} path) ──
  assert call_finite(a_atom, atom.create("fdiv"), [
      inst,
      finite(6.0),
      finite(2.0),
    ])
    == Ok(Ok(#(atom.create("finite"), 3.0)))

  // ── non-finite float (the {nonfinite, _}/raw-bits path): 1.0 / 0.0 == +Inf ──
  // +Inf f64 raw bits = 0x7FF0000000000000, big-endian bytes:
  assert call_nonfinite(a_atom, atom.create("fdiv"), [
      inst,
      finite(1.0),
      finite(0.0),
    ])
    == Ok(Ok(#(atom.create("nonfinite"), <<127, 240, 0, 0, 0, 0, 0, 0>>)))

  // ── f32 single-rounding: f32id(0.1) round-trips to binary32 0x3DCCCCCD (distinct f64 pattern) ──
  // 0.1 is finite, so the tag is `finite`; re-encoding the returned float to f32 bytes recovers the
  // single-rounded pattern the `.beam` computed (0.1 has no exact binary32, so it is NOT 0.1's f64).
  let assert Ok(Ok(#(f32tag, f32v))) =
    call_finite(a_atom, atom.create("f32id"), [inst, finite(0.1)])
  assert f32tag == atom.create("finite")
  assert <<f32v:float-size(32)>> == <<61, 204, 204, 205>>

  // ── zero-result export → {ok, ok} (the unit atom) ──
  assert call_unit(a_atom, atom.create("noop"), [inst])
    == Ok(Ok(atom.create("ok")))

  // ── threaded state: two bumps accumulate (5 then 10 → 15); the OLD instance stays 0-based ──
  let assert Ok(Ok(inst0)) = call_inst(a_atom, atom.create("instantiate"), [])
  let assert Ok(Ok(#(v1, inst1))) =
    call_ti(a_atom, atom.create("bump"), [inst0, to_dynamic(5)])
  assert v1 == 5
  let assert Ok(Ok(#(v2, _inst2))) =
    call_ti(a_atom, atom.create("bump"), [inst1, to_dynamic(10)])
  assert v2 == 15
  // the OLD instance is immutable (pure value threading — no shared process):
  let assert Ok(Ok(#(v_old, _))) =
    call_ti(a_atom, atom.create("bump"), [inst0, to_dynamic(10)])
  assert v_old == 10

  // ── Stateless two-shape API: no instance() in the surface, re-instantiating internally ──
  assert call_i(b_atom, atom.create("add"), [to_dynamic(100), to_dynamic(-1)])
    == Ok(Ok(99))
  assert call_finite(b_atom, atom.create("fdiv"), [finite(9.0), finite(3.0)])
    == Ok(Ok(#(atom.create("finite"), 3.0)))

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
  // fdiv: 1.0 (bits 4607182418800017408) / 0.0 → +Inf (bits 9218868437227405312); the binding's
  // {nonfinite, <<...>>} bytes are exactly those raw bits big-endian.
  let assert Ok(#(raw_inf, _)) =
    t_invoke_int(sa, atom.create("fdiv"), st, [4_607_182_418_800_017_408, 0])
  assert raw_inf == 9_218_868_437_227_405_312
}

// ───────────────────────────── pure unit tests (no external calls) ─────────────────────────────

/// Deterministic output (R25a): the same `Iface` renders byte-identical files.
pub fn deterministic_output_test() {
  let assert Ok(desc) = iface.describe(module_a(), profiles.portable())
  assert emit_erlang_bindings.emit_erlang(desc)
    == emit_erlang_bindings.emit_erlang(desc)
}

/// `emit_erlang` returns exactly ONE file (no companion catch shim — Erlang catches in-language),
/// named off the legalized module base, whose `-module` matches the basename.
pub fn emits_single_named_file_test() {
  let assert Ok(desc) = iface.describe(module_a(), profiles.portable())
  let files = emit_erlang_bindings.emit_erlang(desc)
  assert list.map(files, fn(f) { f.path })
    == ["carder_wasm_estate_bindings.erl"]
  let assert [gf] = files
  assert string.contains(gf.content, "-module(carder_wasm_estate_bindings).")
  // Remote dispatch targets the exact (single-quoted) loaded `.beam` module atom.
  assert string.contains(gf.content, "'carder@wasm@estate':instantiate()")
  // The trap catch is STRUCTURAL on error:{wasm_trap, _} (R7), never a bare catch-all.
  assert string.contains(
    gf.content,
    "error:{wasm_trap, _} = Trap -> {error, Trap}",
  )
  assert !string.contains(gf.content, "catch\n        _ ->")
}

/// The Threaded surface (R19): an opaque `instance()`, a `Result`-shaped `instantiate/0`, a
/// state-reaching export threading `instance()` back, and a pure export dropping it.
pub fn threaded_shape_test() {
  let assert Ok(desc) = iface.describe(module_a(), profiles.portable())
  let #(_path, c) = source_file(desc)
  assert desc.state_model == iface.Threaded
  assert string.contains(c, "-opaque instance() :: tuple().")
  assert string.contains(
    c,
    "-spec instantiate() -> {ok, instance()} | {error, trap()}.",
  )
  // a state-reaching export threads the new instance() out:
  assert string.contains(
    c,
    "-spec bump(instance(), integer()) -> {ok, {integer(), instance()}} | {error, trap()}.",
  )
  // a pure export takes instance() but returns the bare value:
  assert string.contains(
    c,
    "-spec add(instance(), integer(), integer()) -> {ok, integer()} | {error, trap()}.",
  )
  // a pure multi-value export → a result tuple; a zero-result → the unit atom `ok`:
  assert string.contains(
    c,
    "-spec divmod(instance(), integer(), integer()) -> {ok, {integer(), integer()}} | {error, trap()}.",
  )
  assert string.contains(
    c,
    "-spec noop(instance()) -> {ok, ok} | {error, trap()}.",
  )
  // a float export uses the floatval() tagged-tuple type:
  assert string.contains(
    c,
    "-spec fdiv(instance(), floatval(), floatval()) -> {ok, floatval()} | {error, trap()}.",
  )
  assert string.contains(
    c,
    "-type floatval() :: {finite, float()} | {nonfinite, binary()}.",
  )
}

/// The Stateless surface (R19, "the beautiful pure file"): NO `instance()`, NO `instantiate/0`,
/// each export `f(Args) -> {ok, T} | {error, trap()}` re-instantiating internally per call.
pub fn stateless_shape_test() {
  let assert Ok(desc) = iface.describe(module_b(), profiles.portable())
  let #(_path, c) = source_file(desc)
  assert desc.state_model == iface.Stateless
  assert !string.contains(c, "-opaque instance()")
  assert !string.contains(c, "instantiate/0")
  assert string.contains(
    c,
    "-spec add(integer(), integer()) -> {ok, integer()} | {error, trap()}.",
  )
  // the export re-instantiates internally (both instantiate + the call inside the trap-catch):
  assert string.contains(c, "St = 'carder@wasm@epure':instantiate(),")
}
