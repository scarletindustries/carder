//// P12-06 — THE CAPSTONE: the per-language compile+call differential that PROVES Phase 12.
////
//// This is the phase proof (decision P7): for each emitted host language, *generate* a typed
//// binding → *compile* it with the **real toolchain** (`gleam build` / in-VM `erlc` / `elixirc`)
//// → *call* representative exports through the compiled native surface → assert the native result
//// (and a genuine trap → the language's error idiom) is **identical** to the in-process pipeline
//// **oracle**, by RAW BITS. Not golden change-detectors (D8) — "it compiles with that language's
//// own compiler AND the call matches the oracle."
////
//// ## What the capstone adds over the three emitter-unit differentials (P12-02/03/04)
////
//// The emitter units each proved their own language compiles+calls for i32 / multi-value / trap /
//// f32 / f64(finite+non-finite) / zero-result / threaded-state / the Stateless two-shape API. The
//// capstone completes the **§1 acceptance TYPE MATRIX** by adding the types those units did not
//// exercise — **i64** (a value > 2³² and the two's-complement high-bit case), **v128** (16-byte
//// binary identity), and **funcref/externref** (opaque passthrough) — across ALL THREE languages,
//// and it does three things structurally new:
////
//// 1. **Two oracles, compared by raw bits.** Scalar Int/float/trap rows use the in-process pipeline
////    oracle `pipeline.instantiate`+`invoke_instance` (Int-typed, `Returned([bits])`/`Trapped`).
////    The v128 / multi-value / reference rows CANNOT ride that Int oracle (R10), so they use the
////    conformance harness's **term-ABI** oracle (`start_instance`/`call_instance`/`result_list`/
////    `stop_instance`, R25c) and compare the decoded RAW term. Non-finite floats are compared by
////    raw IEEE bits (R18), so a NaN/±Inf divergence would be caught.
//// 2. **The R16 cross-language atom purge.** The Gleam binding `<base>_bindings` and the Erlang
////    binding `<base>_bindings` share ONE BEAM atom. The capstone deliberately uses the SAME module
////    base for both, loads them into the one test VM in sequence, and `code:purge`/`code:delete`s
////    the binding module BETWEEN per-language runs (`purge_shared_bindings`) — without which the
////    second load would leave the two co-resident and a later dispatch could run the wrong-language
////    binding (a silent false green — observed). The Elixir binding compiles to the DISTINCT atom
////    `Elixir.*`, so it never collides.
//// 3. **The shipped folder path + determinism.** `folder_driver_shipped_path_test` drives the SAME
////    entry the CLI uses (`bindings.emit_bindings`) to write the `.beam` + companion files, proving
////    the deterministic path (P6). `deterministic_emit_test` pins byte-identical re-emission (R25a).
////
//// ## Elixir best-effort (P8/R23)
////
//// The Elixir arm is GATED on `elixirc` being on `PATH` (`twocore_bindings_ffi:which`). CI does NOT
//// install Elixir, so there it prints a categorized skip and PASSES — never a failure, never a
//// false green. Erlang (`erlc` IS the BEAM) and Gleam (the project's own toolchain) are required
//// in-tree and always run. Because the Erlang and Elixir bindings present WASM values as the same
//// BEAM terms, ONE differential body (`run_beam`) drives both.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/string
import simplifile
import twocore/backend/bindings
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/backend/emit_elixir_bindings
import twocore/backend/emit_erlang_bindings
import twocore/backend/emit_gleam_bindings
import twocore/backend/iface
import twocore/ir
import twocore/pipeline
import twocore/runtime/profiles
import twocore/runtime/rt_ref

// ───────────────────────────── raw-bit constants (spec anchors, D5) ─────────────────────────────

/// The raw IEEE-754 f64 bit patterns of a few literals (as `Int`s — the D5 ABI). Used as the raw
/// arguments the Int oracle takes (a float arg IS its bit pattern at the run-ABI) and as the
/// spec-anchored expected results.
const bits_6_0: Int = 4_618_441_417_868_443_648

const bits_2_0: Int = 4_611_686_018_427_387_904

const bits_3_0: Int = 4_613_937_818_241_073_152

const bits_1_0: Int = 4_607_182_418_800_017_408

/// +Inf as raw f64 bits (`0x7FF0000000000000`) — the non-finite result of `1.0 / 0.0` (R18).
const bits_pos_inf: Int = 9_218_868_437_227_405_312

/// `0.1` single-rounded to binary32 (`0x3DCCCCCD`) — distinct from `0.1`'s f64 pattern, so it
/// proves the f32 codec single-rounds and does NOT re-round (the adversarial f32 case).
const bits_f32_0_1: Int = 1_036_831_949

// ───────────────────────────── IR fixtures — the type matrix ─────────────────────────────

/// A named, typed value slot.
fn local(name: String, ty: ir.ValType) -> ir.Local {
  ir.Local(name, ty)
}

/// A pure `add(i32,i32)->[i32]` (`p0 + p1`) — the signed-int headline (also `mkref`'s referent).
fn add_fn() -> ir.Function {
  ir.Function(
    name: "add",
    params: [local("p0", ir.TI32), local("p1", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Num(ir.IAdd(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
  )
}

/// A pure MULTI-VALUE `divmod(i32,i32)->[i32,i32]` = `<div_s, rem_s>`; traps on a zero divisor.
fn divmod_fn() -> ir.Function {
  ir.Function(
    name: "divmod",
    params: [local("p0", ir.TI32), local("p1", ir.TI32)],
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

/// A pure `i64sum(i64,i64)->[i64]` (`p0 + p1`, 64-bit wrapping) — exercises i64 values BEYOND 2³²
/// (host bignums) AND the two's-complement high-bit boundary (`0x8000000000000000`).
fn i64sum_fn() -> ir.Function {
  ir.Function(
    name: "i64sum",
    params: [local("p0", ir.TI64), local("p1", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Num(ir.IAdd(ir.W64), [ir.Var("p0"), ir.Var("p1")]),
  )
}

/// A pure `fdiv(f64,f64)->[f64]` (`p0 / p1`). Float division by zero yields `±Inf` (no trap) — the
/// non-finite path.
fn fdiv_fn() -> ir.Function {
  ir.Function(
    name: "fdiv",
    params: [local("p0", ir.TF64), local("p1", ir.TF64)],
    result: [ir.TF64],
    locals: [],
    body: ir.Num(ir.FDiv(ir.FW64), [ir.Var("p0"), ir.Var("p1")]),
  )
}

/// A pure `f32id(f32)->[f32]` = `p0 + 0.0f` (identity, exercising f32 single-rounding).
fn f32id_fn() -> ir.Function {
  ir.Function(
    name: "f32id",
    params: [local("p0", ir.TF32)],
    result: [ir.TF32],
    locals: [],
    body: ir.Num(ir.FAdd(ir.FW32), [ir.Var("p0"), ir.ConstF32(0)]),
  )
}

/// A pure `v128id(v128)->[v128]` = `p0` (identity) — exercises the 16-byte-binary value ABI.
fn v128id_fn() -> ir.Function {
  ir.Function(
    name: "v128id",
    params: [local("p0", ir.TV128)],
    result: [ir.TV128],
    locals: [],
    body: ir.Values([ir.Var("p0")]),
  )
}

/// A pure `mkref()->[funcref]` = `ref.func $add` — produces a non-null funcref (an opaque handle).
fn mkref_fn() -> ir.Function {
  ir.Function(
    name: "mkref",
    params: [],
    result: [ir.TFuncRef],
    locals: [],
    body: ir.RefFunc("add"),
  )
}

/// A pure `isnull(funcref)->[i32]` = `ref.is_null p0` — consumes a reference opaquely and reports
/// whether it is the null sentinel (spec: a non-null funcref → `0`).
fn isnull_fn() -> ir.Function {
  ir.Function(
    name: "isnull",
    params: [local("p0", ir.TFuncRef)],
    result: [ir.TI32],
    locals: [],
    body: ir.RefIsNull(ir.Var("p0")),
  )
}

/// A pure `extern_id(externref)->[externref]` = `p0` (identity) — proves an externref rides through
/// the binding unmodified, so its host-identity round-trips exactly (R18 externref-by-identity).
fn extern_id_fn() -> ir.Function {
  ir.Function(
    name: "extern_id",
    params: [local("p0", ir.TExternRef)],
    result: [ir.TExternRef],
    locals: [],
    body: ir.Values([ir.Var("p0")]),
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

/// A state-MUTATING `bump(i32)->[i32]`: `counter += p0; return counter` (reads+writes a global, so
/// `touches_state == True`) — the threaded-state export.
fn bump_fn() -> ir.Function {
  ir.Function(
    name: "bump",
    params: [local("p0", ir.TI32)],
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

/// Assemble a numerics module named `twocore@wasm@<base>` (R14) from `functions`, exporting each by
/// its own name in declaration order, over one mutable global.
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

/// The THREADED type-matrix fixture (`bump` reaches state → the whole HOST surface is Threaded, R19):
/// every value type + a trap + a zero-result + threaded state, all in one module (so one toolchain
/// compile per language covers the whole matrix — CI-affordable, R25b).
fn matrix_module() -> ir.Module {
  module_of("capstone", [
    add_fn(),
    divmod_fn(),
    i64sum_fn(),
    fdiv_fn(),
    f32id_fn(),
    v128id_fn(),
    mkref_fn(),
    isnull_fn(),
    extern_id_fn(),
    noop_fn(),
    bump_fn(),
  ])
}

/// The STATELESS fixture (no export reaches the global → the pure surface, R19 "the beautiful pure
/// file"): add + fdiv, presented with NO `Instance`.
fn stateless_module() -> ir.Module {
  module_of("capstonep", [add_fn(), fdiv_fn()])
}

/// The 16 distinct v128 bytes the matrix round-trips (little-endian lane layout).
fn v128_bytes() -> BitArray {
  <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>
}

// ───────────────────────────── the oracle (the in-process pipeline truth) ─────────────────────────────

/// The RAW-bit values the in-process pipeline produces for the matrix module — the truth every
/// compiled binding must reproduce (by bit pattern, D5/D7). Scalar rows come from the Int oracle
/// (`pipeline.invoke_instance`); the v128 / multi-value / externref rows from the conformance
/// term-ABI oracle (R10/R25c). Every field is a raw unsigned bit pattern (or the raw v128 bytes).
type Oracle {
  Oracle(
    add_raw: Int,
    i64_big_raw: Int,
    i64_neg_raw: Int,
    divmod_raw: #(Int, Int),
    fdiv_finite_bits: Int,
    fdiv_inf_bits: Int,
    f32_bits: Int,
    v128_bytes: BitArray,
    extern_payload: Int,
  )
}

/// Compile + load the matrix + stateless modules into the test VM (so every binding's dispatch
/// resolves) and compute the `Oracle` once. Returns `#(matrix_atom, stateless_atom, oracle)` where
/// the two atoms are the loaded `.beam` module names (`twocore@wasm@capstone` / `…capstonep`, R14).
///
/// A `let assert` in here is the test's success contract (a compile/load/oracle failure is a genuine
/// capstone failure). The two owned oracle processes are stopped before returning; the module CODE
/// stays loaded (stopping a process does not unload code), so the bindings still dispatch.
fn setup() -> #(String, String, Oracle) {
  let m = matrix_module()
  let mp = stateless_module()

  // Compile the matrix module; load its code AND get an Int-oracle instance process.
  let assert Ok(cm) = emit_core.emit_module(m, profiles.portable())
  let core = core_printer.print_module(cm)
  let assert Ok(beam) = pipeline.core_to_beam(core, m.name)
  let assert Ok(int_proc) = pipeline.instantiate(beam, m.name)

  // Load the stateless module's code (its binding dispatches into it; no oracle proc needed).
  let assert Ok(cmp) = emit_core.emit_module(mp, profiles.portable())
  let core_p = core_printer.print_module(cmp)
  let assert Ok(_) = build_beam.compile_and_load(bit_array.from_string(core_p))

  // The term-ABI oracle process (for v128 / multi-value / externref — the non-Int rows).
  let assert Ok(term_proc) = start_instance(atom.create(m.name))

  let oracle = compute_oracle(int_proc, term_proc)
  pipeline.stop_instance(int_proc)
  stop_instance(term_proc)
  #(m.name, mp.name, oracle)
}

/// Compute the raw-bit `Oracle` from a live Int-oracle process (`int_proc`) and term-ABI-oracle
/// process (`term_proc`). Scalar rows: `invoke_instance` returns `Returned([bits])`. A float
/// argument is passed as its raw IEEE bit pattern (the D5 run-ABI). The trapping `divmod(_,0)` is
/// asserted `Trapped` HERE too (the oracle traps identically to the binding). The v128 / multi-value
/// / externref packages are unpacked with `result_list` and decoded to raw bits / payload.
fn compute_oracle(int_proc: pipeline.InstanceProc, term_proc: Pid) -> Oracle {
  let assert pipeline.Returned([add_raw]) =
    pipeline.invoke_instance(int_proc, "add", [2, 4_294_967_293])
  let assert pipeline.Returned([i64_big]) =
    pipeline.invoke_instance(int_proc, "i64sum", [4_294_967_296, 8_589_934_595])
  let assert pipeline.Returned([i64_neg]) =
    pipeline.invoke_instance(int_proc, "i64sum", [
      9_223_372_036_854_775_808,
      0,
    ])
  let assert pipeline.Returned([fdiv_fin]) =
    pipeline.invoke_instance(int_proc, "fdiv", [bits_6_0, bits_2_0])
  let assert pipeline.Returned([fdiv_inf]) =
    pipeline.invoke_instance(int_proc, "fdiv", [bits_1_0, 0])
  let assert pipeline.Returned([f32_raw]) =
    pipeline.invoke_instance(int_proc, "f32id", [bits_f32_0_1])
  // The oracle traps on div-by-zero exactly as the binding must (a genuine trap, R24 — not a throw).
  let assert pipeline.Trapped(reason) =
    pipeline.invoke_instance(int_proc, "divmod", [10, 0])
  assert string.contains(reason, "int_div_by_zero")

  // Term-ABI rows (R10): decode raw bits / the raw term.
  let assert Ok(dm_pkg) =
    call_terms(term_proc, atom.create("divmod"), [to_dynamic(17), to_dynamic(5)])
  let assert [q, r] = result_list(2, dm_pkg)
  let assert Ok(v_pkg) =
    call_terms(term_proc, atom.create("v128id"), [to_dynamic(v128_bytes())])
  let assert [vbin] = result_list(1, v_pkg)
  let assert Ok(ex_pkg) =
    call_terms(term_proc, atom.create("extern_id"), [rt_ref.extern_of(42)])
  let assert [exref] = result_list(1, ex_pkg)
  // Sanity: `mkref` yields a NON-null funcref the term ABI classifies as `FuncRef`.
  let assert Ok(mk_pkg) = call_terms(term_proc, atom.create("mkref"), [])
  let assert [funcref] = result_list(1, mk_pkg)
  assert rt_ref.classify_ref(funcref) == rt_ref.FuncRef

  // Spec-anchored sanity on the derived raw bits (the oracle agrees with the WASM spec).
  assert add_raw == 4_294_967_295
  assert i64_big == 12_884_901_891
  assert i64_neg == 9_223_372_036_854_775_808
  assert fdiv_fin == bits_3_0
  assert fdiv_inf == bits_pos_inf
  assert f32_raw == bits_f32_0_1

  Oracle(
    add_raw: add_raw,
    i64_big_raw: i64_big,
    i64_neg_raw: i64_neg,
    divmod_raw: #(dyn_to_int(q), dyn_to_int(r)),
    fdiv_finite_bits: fdiv_fin,
    fdiv_inf_bits: fdiv_inf,
    f32_bits: f32_raw,
    v128_bytes: dyn_to_bits(vbin),
    extern_payload: dyn_to_int(extern_payload(exref)),
  )
}

// ───────────────────────────── term-ABI oracle FFI (conformance harness, R25c) ─────────────────────────────

@external(erlang, "twocore_conformance_ffi", "start_instance")
fn start_instance(module: Atom) -> Result(Pid, String)

/// Invoke `function` with raw TERM args inside the instance's owned process, returning the raw
/// result PACKAGE opaquely (bound to the same `call_instance/3` as the Int path; Erlang is untyped).
@external(erlang, "twocore_conformance_ffi", "call_instance")
fn call_terms(
  proc: Pid,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

@external(erlang, "twocore_conformance_ffi", "result_list")
fn result_list(arity: Int, package: Dynamic) -> List(Dynamic)

@external(erlang, "twocore_conformance_ffi", "extern_payload")
fn extern_payload(ref: Dynamic) -> Dynamic

@external(erlang, "twocore_conformance_ffi", "stop_instance")
fn stop_instance(proc: Pid) -> Nil

// ───────────────────────────── compile+call FFI (real toolchains) + R16 purge ─────────────────────────────

@external(erlang, "twocore_bindings_ffi", "which")
fn which(exe: String) -> Result(String, Nil)

@external(erlang, "twocore_bindings_ffi", "compile_load_gleam")
fn compile_load_gleam(
  files: List(#(String, String)),
  main: Atom,
) -> Result(Atom, String)

@external(erlang, "twocore_bindings_ffi", "compile_load_erlang")
fn compile_load_erlang(
  files: List(#(String, String)),
  main: Atom,
) -> Result(Atom, String)

@external(erlang, "twocore_bindings_ffi", "compile_load_elixir")
fn compile_load_elixir(
  files: List(#(String, String)),
  main: Atom,
) -> Result(Atom, String)

/// Fully unload a binding module between per-language runs (R16 — see `twocore_bindings_ffi:purge`).
@external(erlang, "twocore_bindings_ffi", "purge")
fn purge_module(module: Atom) -> Nil

/// `True` iff `module:function/arity` is an exported function of the CURRENTLY-loaded `module` — the
/// language probe for the R16 clobber test (the Gleam binding exports the R18 accessor `f64_bits/1`;
/// the Erlang binding's float codec is a PRIVATE helper, so it does not).
@external(erlang, "erlang", "function_exported")
fn function_exported(module: Atom, function: Atom, arity: Int) -> Bool

/// `True` iff `module` currently has code resident — distinguishes "resident (possibly the
/// wrong-language binding)" from "fully unloaded by `purge`" in the R16 test.
@external(erlang, "twocore_bindings_ffi", "is_loaded")
fn is_loaded(module: Atom) -> Bool

// `call/3` re-typed per (arg-list, result) shape. For the GLEAM driver each function returns a bare
// comparable value, so `call/3` wraps it `{ok, V}` → `Ok(V)`.
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

@external(erlang, "twocore_bindings_ffi", "call")
fn call_bits_bits(
  m: Atom,
  f: Atom,
  args: List(BitArray),
) -> Result(BitArray, String)

// For the ERLANG/ELIXIR bindings called DIRECTLY: the binding returns `{ok, T}` / `{error, Trap}`,
// so `call/3`'s `{ok, _}` safety-net wrap nests as `Ok(Ok(T))` / `Ok(Error(Trap))`; an emitter bug
// (a wrong arity ⇒ `undef`) surfaces as `Error(text)` instead of crashing the suite.
@external(erlang, "twocore_bindings_ffi", "call")
fn call_i(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(Int, Dynamic), String)

@external(erlang, "twocore_bindings_ffi", "call")
fn call_pair(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(#(Int, Int), Dynamic), String)

@external(erlang, "twocore_bindings_ffi", "call")
fn call_finite(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(#(Atom, Float), Dynamic), String)

@external(erlang, "twocore_bindings_ffi", "call")
fn call_nonfinite(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(#(Atom, BitArray), Dynamic), String)

@external(erlang, "twocore_bindings_ffi", "call")
fn call_unit(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(Atom, Dynamic), String)

@external(erlang, "twocore_bindings_ffi", "call")
fn call_dyn(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(Dynamic, Dynamic), String)

@external(erlang, "twocore_bindings_ffi", "call")
fn call_ti(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(#(Int, Dynamic), Dynamic), String)

@external(erlang, "twocore_bindings_ffi", "call")
fn call_bits(
  m: Atom,
  f: Atom,
  a: List(Dynamic),
) -> Result(Result(BitArray, Dynamic), String)

/// Coerce any Gleam value to `Dynamic` (identity at runtime) — to build the heterogeneous
/// `[inst, arg, …]` apply list the Erlang/Elixir bindings' exports take.
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

/// Coerce a term-ABI result element (a raw integer `Dynamic`) to `Int` (identity at runtime).
@external(erlang, "gleam_stdlib", "identity")
fn dyn_to_int(d: Dynamic) -> Int

/// Coerce a term-ABI result element (a raw 16-byte binary `Dynamic`) to `BitArray`.
@external(erlang, "gleam_stdlib", "identity")
fn dyn_to_bits(d: Dynamic) -> BitArray

/// Coerce a trap `Dynamic` (`{wasm_trap, Kind}`) to a `#(Atom, Atom)` so the kind can be matched.
@external(erlang, "gleam_stdlib", "identity")
fn as_trap(d: Dynamic) -> #(Atom, Atom)

/// A finite `floatval()` argument `{finite, X}` as a `Dynamic` the bindings' float exports accept.
fn finite(x: Float) -> Dynamic {
  to_dynamic(#(atom.create("finite"), x))
}

// ───────────────────────────── raw re-encoders (native → raw bits, D5/D7) ─────────────────────────────

/// Re-encode a host-signed i32 value as its raw unsigned 32-bit pattern (two's-complement).
fn u32(v: Int) -> Int {
  let m = v % 0x1_0000_0000
  case m < 0 {
    True -> m + 0x1_0000_0000
    False -> m
  }
}

/// Re-encode a host-signed i64 value as its raw unsigned 64-bit pattern (two's-complement).
fn u64(v: Int) -> Int {
  let m = v % 0x1_0000_0000_0000_0000
  case m < 0 {
    True -> m + 0x1_0000_0000_0000_0000
    False -> m
  }
}

/// The raw IEEE-754 bit pattern of a native `Float`, as an `Int` (big-endian codec, the canonical
/// pattern) — for comparing a finite binding result to the raw oracle.
fn f64_to_bits(f: Float) -> Int {
  let assert <<b:size(64)>> = <<f:float-size(64)>>
  b
}

/// The raw IEEE-754 binary32 bit pattern of a native `Float`, single-rounded, as an `Int`.
fn f32_to_bits(f: Float) -> Int {
  let assert <<b:size(32)>> = <<f:float-size(32)>>
  b
}

/// The 8 raw bytes of an f64 `NonFinite`/`{nonfinite,_}` result as an unsigned 64-bit `Int`.
fn bytes_to_u64(bytes: BitArray) -> Int {
  let assert <<b:size(64)>> = bytes
  b
}

// ───────────────────────────── the Gleam driver (imports both bindings) ─────────────────────────────

/// A hand-written Gleam program that `import`s BOTH emitted bindings and exposes flat,
/// bare-valued functions the differential calls through `call/3`. Prelude-only (it lives in the
/// dependency-free probe project the harness stages), so it uses `let assert`/`case`/tuples and the
/// bindings' `pub` types only. `s` = the threaded matrix binding; `p` = the stateless binding.
///
/// The reference row (`g_isnull_mkref`) proves the opaque `Ref` passthrough end-to-end IN GLEAM: a
/// funcref is produced by one export (`mkref`) and consumed by another (`isnull`) through the opaque
/// handle — the host can neither forge nor inspect it — and the spec-correct `0` (non-null) comes
/// back.
fn gleam_driver_source() -> String {
  "import twocore_wasm_capstone_bindings as s
import twocore_wasm_capstonep_bindings as p

pub fn g_add(a: Int, b: Int) -> Int {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(v) = s.add(inst, a, b)
  v
}

pub fn g_i64sum(a: Int, b: Int) -> Int {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(v) = s.i64sum(inst, a, b)
  v
}

pub fn g_divmod(a: Int, b: Int) -> #(Int, Int) {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(qr) = s.divmod(inst, a, b)
  qr
}

pub fn g_divmod_trap(a: Int, b: Int) -> String {
  let assert Ok(inst) = s.instantiate()
  case s.divmod(inst, a, b) {
    Ok(_) -> \"NOTRAP\"
    Error(s.Trap(reason)) -> reason
  }
}

pub fn g_fdiv_bits(a: Float, b: Float) -> BitArray {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(r) = s.fdiv(inst, s.Finite(a), s.Finite(b))
  s.f64_bits(r)
}

pub fn g_fdiv_finite(a: Float, b: Float) -> Float {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(r) = s.fdiv(inst, s.Finite(a), s.Finite(b))
  let assert s.Finite(v) = r
  v
}

pub fn g_fdiv_is_nonfinite(a: Float, b: Float) -> Int {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(r) = s.fdiv(inst, s.Finite(a), s.Finite(b))
  case r {
    s.NonFinite(_) -> 1
    s.Finite(_) -> 0
  }
}

pub fn g_f32id_bits(x: Float) -> BitArray {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(r) = s.f32id(inst, s.Finite(x))
  s.f32_bits(r)
}

pub fn g_v128id(x: BitArray) -> BitArray {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(v) = s.v128id(inst, x)
  v
}

pub fn g_isnull_mkref() -> Int {
  let assert Ok(inst) = s.instantiate()
  let assert Ok(ref) = s.mkref(inst)
  let assert Ok(n) = s.isnull(inst, ref)
  n
}

pub fn g_noop() -> Int {
  let assert Ok(inst) = s.instantiate()
  case s.noop(inst) {
    Ok(Nil) -> 1
    Error(_) -> 0
  }
}

pub fn g_bump_twice(x: Int, y: Int) -> Int {
  let assert Ok(inst0) = s.instantiate()
  let assert Ok(#(_v1, inst1)) = s.bump(inst0, x)
  let assert Ok(#(v2, _inst2)) = s.bump(inst1, y)
  v2
}

pub fn g_bump_old(x: Int, y: Int) -> Int {
  let assert Ok(inst0) = s.instantiate()
  let assert Ok(#(_v1, _inst1)) = s.bump(inst0, x)
  let assert Ok(#(v, _)) = s.bump(inst0, y)
  v
}

pub fn gp_add(a: Int, b: Int) -> Int {
  let assert Ok(v) = p.add(a, b)
  v
}

pub fn gp_fdiv_finite(a: Float, b: Float) -> Float {
  let assert Ok(r) = p.fdiv(p.Finite(a), p.Finite(b))
  let assert p.Finite(v) = r
  v
}
"
}

/// The `.gleam`/`.erl` source files of an emitted Gleam binding, as `#(basename, content)` for
/// `compile_load_gleam` (drops the README — not a compilation input).
fn gleam_source_files(desc: iface.Iface) -> List(#(String, String)) {
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

/// The single `.erl`/`.ex` source of an emitted Erlang/Elixir binding, as `#(basename, content)`.
fn single_source(files: List(iface.GeneratedFile)) -> #(String, String) {
  let assert [gf] = files
  #(gf.path, gf.content)
}

// ───────────────────────────── THE CAPSTONE differential (all three languages) ─────────────────────────────

/// PHASE 12 PROVEN — the end-to-end compile+call differential across Gleam, Erlang, and (best-effort)
/// Elixir, over the full §1 type matrix + threaded state, comparing every native result to the raw
/// in-process oracle. Runs the three languages SEQUENTIALLY in the one test VM with an R16
/// `code:purge` of the shared binding atom between them (Gleam and Erlang emit the SAME binding
/// module atom `twocore_wasm_capstone_bindings`, so without the purge the second load would leave the
/// two co-resident and dispatch could run the wrong-language binding — a silent false green).
///
/// Gleam (`gleam`, the project's own toolchain) and Erlang (`erlc` IS the BEAM) are required and
/// always run. Elixir is gated on `elixirc` (P8/R23) — a categorized skip when absent (as on CI),
/// never a failure and never a false green.
pub fn phase12_capstone_differential_test() {
  let #(matrix_name, stateless_name, oracle) = setup()

  // ── GLEAM (the headline: the real `gleam` toolchain) ──
  run_gleam(oracle)
  purge_shared_bindings()

  // ── ERLANG (the in-VM `erlc`) ──
  run_beam(
    matrix_name,
    stateless_name,
    "twocore_wasm_capstone_bindings",
    "twocore_wasm_capstonep_bindings",
    erlang_compile,
    oracle,
  )
  purge_shared_bindings()

  // ── ELIXIR (best-effort — gated on `elixirc`) ──
  case which("elixirc") {
    Error(_) ->
      io.println(
        "\n[p12-06] elixirc not on PATH — Elixir compile+call SKIPPED (categorized, best-effort P8/R23)",
      )
    Ok(_) -> {
      run_beam(
        matrix_name,
        stateless_name,
        "Elixir.TwocoreWasmCapstoneBindings",
        "Elixir.TwocoreWasmCapstonepBindings",
        elixir_compile,
        oracle,
      )
      // The Elixir binding atoms are DISTINCT (`Elixir.*`), so this purge is hygiene, not R16.
      purge_module(atom.create("Elixir.TwocoreWasmCapstoneBindings"))
      purge_module(atom.create("Elixir.TwocoreWasmCapstonepBindings"))
      Nil
    }
  }
}

/// Purge the SHARED Gleam/Erlang binding module atoms (R16), plus the Gleam-only companion shims and
/// driver, so the next language's load starts from a clean slate. Idempotent (purging an absent
/// module is a harmless no-op), so it is safe to call after Gleam AND after Erlang.
fn purge_shared_bindings() -> Nil {
  purge_module(atom.create("twocore_wasm_capstone_bindings"))
  purge_module(atom.create("twocore_wasm_capstonep_bindings"))
  purge_module(atom.create("twocore_wasm_capstone_bindings_ffi"))
  purge_module(atom.create("twocore_wasm_capstonep_bindings_ffi"))
  purge_module(atom.create("driver"))
  Nil
}

/// R16 — the cross-language binding-atom collision is REAL, and the purge is the remedy. This test
/// EXHIBITS the clobber empirically and shows the purge cleanly unloads the atom so the next
/// language starts from a bare slate (it uses a DISTINCT base `r16probe`, so it cannot perturb the
/// main differential's `capstone` binding). The language probe is the Gleam-only R18 accessor
/// `f64_bits/1`: a Gleam binding exports it (`pub fn`), an Erlang binding does NOT (its float codec
/// is a private helper), so the atom's export table tells which language is currently resident.
///
///  1. Compile+load the GLEAM binding for an f64 module → the atom is loaded AND exports `f64_bits/1`.
///  2. Compile+load the ERLANG binding under the SAME atom WITHOUT purging → the second load makes
///     the Erlang binding current: the atom is STILL loaded but `f64_bits/1` is GONE. So loading two
///     languages under one atom leaves the WRONG-language binding resident — exactly the co-residency
///     false-green R16 warns about (were the caller still expecting to dispatch into the Gleam
///     binding). This is WHY the capstone purges between per-language runs.
///  3. `purge` the atom → it is no longer loaded at all (a clean slate, no co-residency).
///  4. Reload the GLEAM binding → `f64_bits/1` is exported again (a clean fresh load).
///
/// Gated on `gleam` (always present in-tree; `erlc` is the BEAM). No target module needs loading —
/// the probes read only the binding's own load state / export table.
pub fn r16_shared_atom_clobber_and_purge_test() {
  case which("gleam") {
    Error(_) -> Nil
    Ok(_) -> {
      let m = module_of("r16probe", [fdiv_fn()])
      let assert Ok(desc) = iface.describe(m, profiles.portable())
      let binding = atom.create("twocore_wasm_r16probe_bindings")
      let f64_bits = atom.create("f64_bits")

      // 1. Gleam binding resident → loaded, and the Gleam-only R18 accessor is exported.
      let assert Ok(_) = compile_load_gleam(gleam_source_files(desc), binding)
      assert is_loaded(binding) == True
      assert function_exported(binding, f64_bits, 1) == True

      // 2. Erlang binding loaded over it WITHOUT a purge → the atom is STILL loaded but is now the
      //    Erlang binding (no f64_bits/1): the two collide and the wrong-language module wins.
      let assert Ok(_) =
        compile_load_erlang(
          [single_source(emit_erlang_bindings.emit_erlang(desc))],
          binding,
        )
      assert is_loaded(binding) == True
      assert function_exported(binding, f64_bits, 1) == False

      // 3. purge → the atom is fully unloaded (the R16 remedy: no co-residency between runs).
      purge_module(binding)
      assert is_loaded(binding) == False

      // 4. A fresh Gleam load resolves cleanly → f64_bits/1 exported again.
      let assert Ok(_) = compile_load_gleam(gleam_source_files(desc), binding)
      assert function_exported(binding, f64_bits, 1) == True

      purge_module(binding)
      purge_module(atom.create("twocore_wasm_r16probe_bindings_ffi"))
      Nil
    }
  }
}

/// Compile both emitted Gleam bindings + the driver with the REAL `gleam` toolchain, then drive the
/// whole type matrix through the compiled native surface and compare each result to the raw oracle.
/// Guarded on `gleam` being present (always true in-tree). Compiles ONCE (both bindings + shims +
/// driver in one project), then calls many exports (R25b).
fn run_gleam(oracle: Oracle) -> Nil {
  case which("gleam") {
    Error(_) -> Nil
    Ok(_) -> {
      let assert Ok(desc_c) =
        iface.describe(matrix_module(), profiles.portable())
      let assert Ok(desc_p) =
        iface.describe(stateless_module(), profiles.portable())
      assert desc_c.state_model == iface.Threaded
      assert desc_p.state_model == iface.Stateless

      let project =
        list.flatten([
          [#("driver.gleam", gleam_driver_source())],
          gleam_source_files(desc_c),
          gleam_source_files(desc_p),
        ])
      let assert Ok(_) = compile_load_gleam(project, atom.create("driver"))
      let d = atom.create("driver")

      // i32 signed: add(2, -3) == -1; its raw pattern is the unsigned 0xFFFFFFFF the oracle saw.
      let assert Ok(add_v) = call_i_i(d, atom.create("g_add"), [2, -3])
      assert add_v == -1
      assert u32(add_v) == oracle.add_raw

      // i64 > 2^32 (host bignum round-trip) and the two's-complement high-bit boundary.
      let assert Ok(i64_big) =
        call_i_i(d, atom.create("g_i64sum"), [4_294_967_296, 8_589_934_595])
      assert u64(i64_big) == oracle.i64_big_raw
      let assert Ok(i64_neg) =
        call_i_i(d, atom.create("g_i64sum"), [-9_223_372_036_854_775_808, 0])
      assert i64_neg == -9_223_372_036_854_775_808
      assert u64(i64_neg) == oracle.i64_neg_raw

      // multi-value tuple: divmod(17,5) == (3,2) (signed trunc-toward-zero).
      let assert Ok(qr) = call_i_pair(d, atom.create("g_divmod"), [17, 5])
      assert qr == oracle.divmod_raw

      // trap: divmod(_,0) → Error(Trap(reason)), never a raw exception; the oracle Trapped too.
      let assert Ok(reason) =
        call_i_str(d, atom.create("g_divmod_trap"), [10, 0])
      assert string.contains(reason, "wasm_trap")
      assert string.contains(reason, "int_div_by_zero")

      // f64 finite: 6.0/2.0 == 3.0 (native Float), and its raw bits equal the oracle's.
      let assert Ok(fin_bits) =
        call_f_bits(d, atom.create("g_fdiv_bits"), [6.0, 2.0])
      assert bytes_to_u64(fin_bits) == oracle.fdiv_finite_bits
      assert call_f_f(d, atom.create("g_fdiv_finite"), [6.0, 2.0]) == Ok(3.0)

      // f64 non-finite (the raw-bits path): 1.0/0.0 == +Inf, carried as its raw bytes (R18).
      let assert Ok(inf_bits) =
        call_f_bits(d, atom.create("g_fdiv_bits"), [1.0, 0.0])
      assert bytes_to_u64(inf_bits) == oracle.fdiv_inf_bits
      assert call_f_i(d, atom.create("g_fdiv_is_nonfinite"), [1.0, 0.0])
        == Ok(1)
      assert call_f_i(d, atom.create("g_fdiv_is_nonfinite"), [6.0, 2.0])
        == Ok(0)

      // f32 single-rounding: f32id(0.1) is binary32 0x3DCCCCCD, distinct from 0.1's f64.
      let assert Ok(f32_bits) =
        call_f_bits(d, atom.create("g_f32id_bits"), [0.1])
      assert bytes_to_u32(f32_bits) == oracle.f32_bits

      // v128: 16-byte binary identity.
      let assert Ok(vbin) =
        call_bits_bits(d, atom.create("g_v128id"), [v128_bytes()])
      assert vbin == oracle.v128_bytes

      // funcref opaque passthrough: produced by mkref, consumed by isnull through the opaque Ref → 0.
      assert call_i_i(d, atom.create("g_isnull_mkref"), []) == Ok(0)

      // zero-result export → Ok(Nil).
      assert call_i_i(d, atom.create("g_noop"), []) == Ok(1)

      // threaded state: two bumps accumulate (5 then 10 → 15); the OLD instance stays immutable (R11).
      assert call_i_i(d, atom.create("g_bump_twice"), [5, 10]) == Ok(15)
      assert call_i_i(d, atom.create("g_bump_old"), [5, 10]) == Ok(10)

      // Stateless two-shape API: no Instance in the surface, re-instantiating internally per call.
      assert call_i_i(d, atom.create("gp_add"), [100, -1]) == Ok(99)
      assert call_f_f(d, atom.create("gp_fdiv_finite"), [9.0, 3.0]) == Ok(3.0)
      Nil
    }
  }
}

/// The 4-byte f32 result of `g_f32id_bits` — decode the 32-bit big-endian pattern as an `Int`.
fn bytes_to_u32(bytes: BitArray) -> Int {
  let assert <<b:size(32)>> = bytes
  b
}

// ── the shared Erlang/Elixir differential (identical BEAM terms) ──

/// A per-language "compile the two emitted single-file bindings and load them" step. Returns the
/// loaded matrix binding module atom, or `Error(diagnostics)` (a compile failure is a TEST failure —
/// P5's teeth). `desc_c`/`desc_p` are the matrix/stateless descriptors; `c_atom` is the loaded
/// binding module atom to drive.
type BeamCompile =
  fn(iface.Iface, iface.Iface, Atom) -> Result(Atom, String)

/// Compile both Erlang bindings with the in-VM `erlc` (`compile:file` — always available).
fn erlang_compile(
  desc_c: iface.Iface,
  desc_p: iface.Iface,
  c_atom: Atom,
) -> Result(Atom, String) {
  compile_load_erlang(
    [
      single_source(emit_erlang_bindings.emit_erlang(desc_c)),
      single_source(emit_erlang_bindings.emit_erlang(desc_p)),
    ],
    c_atom,
  )
}

/// Compile both Elixir bindings with the real `elixirc` (best-effort; the caller has already gated
/// on `elixirc` being present).
fn elixir_compile(
  desc_c: iface.Iface,
  desc_p: iface.Iface,
  c_atom: Atom,
) -> Result(Atom, String) {
  compile_load_elixir(
    [
      single_source(emit_elixir_bindings.emit_elixir(desc_c)),
      single_source(emit_elixir_bindings.emit_elixir(desc_p)),
    ],
    c_atom,
  )
}

/// Compile + drive an Erlang OR Elixir binding through the FULL type matrix, comparing every native
/// result to the raw oracle. Both languages present WASM values as the SAME BEAM terms (integers,
/// `{finite,_}`/`{nonfinite,_}` tuples, 16-byte binaries, `{wasm_trap,_}`, `{ref_extern,_}`), so ONE
/// body serves both — parameterised only by the compile step and the two binding module atoms.
///
/// - `matrix_name`/`stateless_name`: the loaded `.beam` module atoms (unused directly here; the
///   binding dispatches into them and they are already loaded by `setup`).
/// - `c_name`/`p_name`: the matrix / stateless BINDING module atom NAMES to compile+drive.
/// - `compile`: the language's `BeamCompile` step.
fn run_beam(
  matrix_name: String,
  stateless_name: String,
  c_name: String,
  p_name: String,
  compile: BeamCompile,
  oracle: Oracle,
) -> Nil {
  let _ = matrix_name
  let _ = stateless_name
  let assert Ok(desc_c) = iface.describe(matrix_module(), profiles.portable())
  let assert Ok(desc_p) =
    iface.describe(stateless_module(), profiles.portable())
  let c = atom.create(c_name)
  let p = atom.create(p_name)
  let assert Ok(_) = compile(desc_c, desc_p, c)

  // Instantiate the threaded binding once; the pure exports reuse the fresh instance.
  let assert Ok(Ok(inst)) = call_dyn(c, atom.create("instantiate"), [])

  // i32 signed.
  let assert Ok(Ok(add_v)) =
    call_i(c, atom.create("add"), [inst, to_dynamic(2), to_dynamic(-3)])
  assert add_v == -1
  assert u32(add_v) == oracle.add_raw

  // i64 > 2^32 and the two's-complement high-bit boundary.
  let assert Ok(Ok(i64_big)) =
    call_i(c, atom.create("i64sum"), [
      inst,
      to_dynamic(4_294_967_296),
      to_dynamic(8_589_934_595),
    ])
  assert u64(i64_big) == oracle.i64_big_raw
  let assert Ok(Ok(i64_neg)) =
    call_i(c, atom.create("i64sum"), [
      inst,
      to_dynamic(-9_223_372_036_854_775_808),
      to_dynamic(0),
    ])
  assert i64_neg == -9_223_372_036_854_775_808
  assert u64(i64_neg) == oracle.i64_neg_raw

  // multi-value tuple.
  let assert Ok(Ok(qr)) =
    call_pair(c, atom.create("divmod"), [inst, to_dynamic(17), to_dynamic(5)])
  assert qr == oracle.divmod_raw

  // trap → {error, {wasm_trap, int_div_by_zero}}, never a raw exception.
  let assert Ok(Error(trap)) =
    call_pair(c, atom.create("divmod"), [inst, to_dynamic(10), to_dynamic(0)])
  assert as_trap(trap)
    == #(atom.create("wasm_trap"), atom.create("int_div_by_zero"))

  // f64 finite: native float() on the {finite,_} path, raw bits equal the oracle.
  let assert Ok(Ok(#(fin_tag, fin_f))) =
    call_finite(c, atom.create("fdiv"), [inst, finite(6.0), finite(2.0)])
  assert fin_tag == atom.create("finite")
  assert fin_f == 3.0
  assert f64_to_bits(fin_f) == oracle.fdiv_finite_bits

  // f64 non-finite (the {nonfinite,_}/raw-bits path): 1.0/0.0 == +Inf (R18).
  let assert Ok(Ok(#(inf_tag, inf_bytes))) =
    call_nonfinite(c, atom.create("fdiv"), [inst, finite(1.0), finite(0.0)])
  assert inf_tag == atom.create("nonfinite")
  assert bytes_to_u64(inf_bytes) == oracle.fdiv_inf_bits

  // f32 single-rounding: 0.1 → binary32 0x3DCCCCCD (NOT re-rounded).
  let assert Ok(Ok(#(f32_tag, f32_f))) =
    call_finite(c, atom.create("f32id"), [inst, finite(0.1)])
  assert f32_tag == atom.create("finite")
  assert f32_to_bits(f32_f) == oracle.f32_bits

  // v128: 16-byte binary identity.
  let assert Ok(Ok(vbin)) =
    call_bits(c, atom.create("v128id"), [inst, to_dynamic(v128_bytes())])
  assert vbin == oracle.v128_bytes

  // funcref opaque passthrough: mkref → non-null funcref; isnull(it) → 0.
  let assert Ok(Ok(funcref)) = call_dyn(c, atom.create("mkref"), [inst])
  assert rt_ref.classify_ref(funcref) == rt_ref.FuncRef
  assert call_i(c, atom.create("isnull"), [inst, funcref]) == Ok(Ok(0))

  // externref identity: extern_id({ref_extern,42}) round-trips exactly (== the term-ABI oracle).
  let assert Ok(Ok(exref)) =
    call_dyn(c, atom.create("extern_id"), [inst, rt_ref.extern_of(42)])
  assert rt_ref.classify_ref(exref) == rt_ref.ExternRef
  assert dyn_to_int(extern_payload(exref)) == 42
  assert dyn_to_int(extern_payload(exref)) == oracle.extern_payload

  // zero-result export → {ok, ok} (the unit atom).
  assert call_unit(c, atom.create("noop"), [inst]) == Ok(Ok(atom.create("ok")))

  // threaded state: two bumps accumulate (5 then 10 → 15); the OLD instance is immutable (R11).
  let assert Ok(Ok(inst0)) = call_dyn(c, atom.create("instantiate"), [])
  let assert Ok(Ok(#(v1, inst1))) =
    call_ti(c, atom.create("bump"), [inst0, to_dynamic(5)])
  assert v1 == 5
  let assert Ok(Ok(#(v2, _inst2))) =
    call_ti(c, atom.create("bump"), [inst1, to_dynamic(10)])
  assert v2 == 15
  let assert Ok(Ok(#(v_old, _))) =
    call_ti(c, atom.create("bump"), [inst0, to_dynamic(10)])
  assert v_old == 10

  // Stateless two-shape API: no instance() in the surface, re-instantiating internally.
  assert call_i(p, atom.create("add"), [to_dynamic(100), to_dynamic(-1)])
    == Ok(Ok(99))
  assert call_finite(p, atom.create("fdiv"), [finite(9.0), finite(3.0)])
    == Ok(Ok(#(atom.create("finite"), 3.0)))
  Nil
}

// ───────────────────────────── determinism + the shipped folder path (P6/R25a) ─────────────────────────────

/// Determinism (R25a): the same `Iface` renders byte-identical files for every emitter (in-memory —
/// the emitters, not the compiled `build/` outputs which carry metadata).
pub fn deterministic_emit_test() {
  let assert Ok(desc) = iface.describe(matrix_module(), profiles.portable())
  assert emit_gleam_bindings.emit_gleam(desc)
    == emit_gleam_bindings.emit_gleam(desc)
  assert emit_erlang_bindings.emit_erlang(desc)
    == emit_erlang_bindings.emit_erlang(desc)
  assert emit_elixir_bindings.emit_elixir(desc)
    == emit_elixir_bindings.emit_elixir(desc)
}

/// The shipped folder path (P6): drive generation through `bindings.emit_bindings` — the SAME entry
/// the CLI uses — to write the `.beam` + companion files into a scratch dir, and assert (a) the
/// returned path list is the deterministic, `.beam`-first, canonical-lang-ordered set, (b) the
/// written `.beam` is byte-identical to the compiled artifact, and (c) a second run into a fresh dir
/// yields the byte-identical binding files (no timestamps/paths in content).
pub fn folder_driver_shipped_path_test() {
  let m = matrix_module()
  let assert Ok(cm) = emit_core.emit_module(m, profiles.portable())
  let assert Ok(beam) =
    pipeline.core_to_beam(core_printer.print_module(cm), m.name)

  let dir_a = scratch_dir("a")
  let langs = [bindings.Gleam, bindings.Erlang, bindings.Elixir]
  let assert Ok(paths) =
    bindings.emit_bindings(m, profiles.portable(), beam, dir_a, langs)

  // The deterministic path set (P6): the `.beam` first, then per-lang path-sorted (Gleam<Erlang<Elixir).
  assert paths
    == [
      dir_a <> "/twocore@wasm@capstone.beam",
      dir_a <> "/twocore_wasm_capstone_bindings.gleam",
      dir_a <> "/twocore_wasm_capstone_bindings_README.md",
      dir_a <> "/twocore_wasm_capstone_bindings_ffi.erl",
      dir_a <> "/twocore_wasm_capstone_bindings.erl",
      dir_a <> "/twocore_wasm_capstone_bindings.ex",
    ]

  // The written `.beam` is exactly the compiled artifact (the bindings are companions — P4).
  let assert Ok(written_beam) =
    simplifile.read_bits(dir_a <> "/twocore@wasm@capstone.beam")
  assert written_beam == beam

  // A second run into a fresh dir yields byte-identical binding SOURCE files (determinism).
  let dir_b = scratch_dir("b")
  let assert Ok(_) =
    bindings.emit_bindings(m, profiles.portable(), beam, dir_b, langs)
  assert read_text(dir_a, "twocore_wasm_capstone_bindings.gleam")
    == read_text(dir_b, "twocore_wasm_capstone_bindings.gleam")
  assert read_text(dir_a, "twocore_wasm_capstone_bindings.erl")
    == read_text(dir_b, "twocore_wasm_capstone_bindings.erl")
  assert read_text(dir_a, "twocore_wasm_capstone_bindings.ex")
    == read_text(dir_b, "twocore_wasm_capstone_bindings.ex")

  let _ = simplifile.delete(dir_a)
  let _ = simplifile.delete(dir_b)
  Nil
}

/// A unique scratch directory path under the OS temp root (created by `emit_bindings`, deleted by
/// the caller). The unique suffix avoids collisions across parallel runs.
fn scratch_dir(tag: String) -> String {
  "/tmp/twocore_p12_capstone_" <> tag <> "_" <> int.to_string(unique_int())
}

/// Read a companion file's UTF-8 content from a scratch dir (a `let assert` — the file must exist).
fn read_text(dir: String, name: String) -> String {
  let assert Ok(content) = simplifile.read(dir <> "/" <> name)
  content
}

@external(erlang, "twocore_conformance_ffi", "unique_int")
fn unique_int() -> Int
