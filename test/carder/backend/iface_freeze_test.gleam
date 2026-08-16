//// P12-01 freeze tests for the Interface Descriptor (`«IFACE-DESC-FROZEN»`).
////
//// Objective tests against the FROZEN contract + P2/P8 + the R-corrections — NOT
//// change-detectors. The load-bearing ones:
////
//// - **R2 (the arity crux):** for a MIXED module (a pure export + a state-mutating export),
////   each `ExportSig.emitted_arity` is asserted EQUAL to the arity of the corresponding export
////   in the REAL emitted `.core` (`emit_core.emit_module`) — so the typed binding can never
////   disagree with the `.beam` ABI.
//// - **R1/§3.3 (the transitive crux):** a pure-BODIED export that `CallDirect`s a memory-writing
////   helper is `touches_state == True` (a shallow scan would say `False` and drop `St'`).
//// - **P8 fail-closed:** Cell, import-bearing, and mutable-tier builds are rejected up front.
//// - **P2 value-ABI:** `host_types/1` / `value_abi/1` / `result_encoding/1` frozen exactly.
//// - **R8:** `Iface.module_name == module.name` (never normalized).
//// - **R25b:** the shared compile+call FFI compiles+loads+calls real Erlang/Gleam/Elixir.

import carder/backend/core_erlang.{type FName, FName}
import carder/backend/emit_core
import carder/backend/iface
import carder/ir
import carder/runtime/instance
import carder/runtime/profiles
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option

// ───────────────────────────── IR fixtures ─────────────────────────────

/// A side-effect-free function `f(p0, p1) -> [TI32]` computing `p0 + p1` (no stateful node).
fn pure_add(name: String) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Num(ir.IAdd(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
  )
}

/// A state-touching function `f() -> [TI32]` whose body reads global `g` (a stateful node, so a
/// seed of the state-reaching closure).
fn reads_global(name: String) -> ir.Function {
  ir.Function(
    name: name,
    params: [],
    result: [ir.TI32],
    locals: [],
    body: ir.GlobalGet("g"),
  )
}

/// A state-MUTATING helper `f() -> []` that stores to linear memory (a stateful node).
fn writes_mem(name: String) -> ir.Function {
  ir.Function(
    name: name,
    params: [],
    result: [],
    locals: [],
    body: ir.MemStore(
      0,
      ir.MemAccess(bytes: 4, signed: False),
      ir.ConstI32(0),
      ir.ConstI32(0),
      0,
    ),
  )
}

/// A PURE-BODIED function `f() -> []` whose ONLY effect is a `CallDirect` of `callee` (no stateful
/// node of its own) — the adversarial transitive case: state-reaching iff `callee` is.
fn calls(name: String, callee: String) -> ir.Function {
  ir.Function(
    name: name,
    params: [],
    result: [],
    locals: [],
    body: ir.CallDirect(callee, []),
  )
}

/// Assemble a numerics+memory module named `carder@wasm@<base>` (the R14 shape) from the given
/// functions, exports, and imports. Declares one memory + one mutable global so every fixture
/// emits coherently under `emit_core`.
fn module_of(
  base: String,
  functions: List(ir.Function),
  exports: List(ir.ExportDecl),
  imports: List(ir.ImportDecl),
) -> ir.Module {
  ir.Module(
    name: "carder@wasm@" <> base,
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [ir.GlobalDecl("g", ir.TI32, True, ir.Values([ir.ConstI32(0)]))],
    imports: imports,
    functions: functions,
    exports: exports,
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// The accepted Phase-12 binding: `Threaded` state strategy over the pure-value `Paged` /
/// `TablePaged` tiers (`profiles.portable()`).
fn threaded() -> instance.Binding {
  profiles.portable()
}

/// The arity of the emitted `.core` export named `name` (its `FName` arity in the `CModule`).
fn emitted_arity(exports: List(FName), name: String) -> Int {
  let assert Ok(FName(_, arity)) =
    list.find(exports, fn(fname) {
      let FName(n, _) = fname
      n == name
    })
  arity
}

// ───────────────────────────── P8 — fail-closed rejections ─────────────────────────────

/// §5.1 — a `Cell` build is rejected `CellUnsupported` (the process-wrapped server binding is
/// deferred). `instance.safe_default()` is the ready-made Cell witness.
pub fn describe_rejects_cell_test() {
  let m = module_of("addc", [pure_add("add")], [ir.ExportFn("add", "add")], [])
  assert iface.describe(m, instance.safe_default())
    == Error(iface.CellUnsupported)
}

/// §5.2 — an import-bearing module is rejected `ImportBearingUnsupported`, for BOTH a function
/// import and a state (global) import, under an otherwise-accepted Threaded binding.
pub fn describe_rejects_function_import_test() {
  let imp = ir.ImportFn("host", "log", ir.FuncType([ir.TI32], []))
  let m =
    module_of("imf", [pure_add("add")], [ir.ExportFn("add", "add")], [imp])
  assert iface.describe(m, threaded()) == Error(iface.ImportBearingUnsupported)
}

pub fn describe_rejects_global_import_test() {
  let imp = ir.ImportGlobal("env", "base", ir.TI32, False)
  let m =
    module_of("img", [pure_add("add")], [ir.ExportFn("add", "add")], [imp])
  assert iface.describe(m, threaded()) == Error(iface.ImportBearingUnsupported)
}

/// R20 — a Threaded build over a MUTABLE memory tier (`Atomics`) is rejected
/// `MutableTierUnsupported`: a value-threaded binding over aliased mutable state would be a lie.
pub fn describe_rejects_mutable_mem_tier_test() {
  let binding = instance.Binding(..threaded(), mem_tier: instance.Atomics)
  let m = module_of("mut", [pure_add("add")], [ir.ExportFn("add", "add")], [])
  assert iface.describe(m, binding) == Error(iface.MutableTierUnsupported)
}

/// R20 — likewise a mutable TABLE tier (`TableAtomics`) is rejected.
pub fn describe_rejects_mutable_table_tier_test() {
  let binding =
    instance.Binding(..threaded(), table_tier: instance.TableAtomics)
  let m = module_of("mut", [pure_add("add")], [ir.ExportFn("add", "add")], [])
  assert iface.describe(m, binding) == Error(iface.MutableTierUnsupported)
}

// ───────────────────────────── state model + signatures ─────────────────────────────

/// §5.3 — a wholly pure module is `Stateless`, every export `touches_state == False`, and each
/// export's `params`/`results` equal `ir.signature` of its target function.
pub fn pure_module_is_stateless_test() {
  let m = module_of("pure", [pure_add("add")], [ir.ExportFn("add", "add")], [])
  let assert Ok(desc) = iface.describe(m, threaded())
  assert desc.state_model == iface.Stateless
  let assert [sig] = desc.exports
  assert sig.touches_state == False
  assert sig.params == [ir.TI32, ir.TI32]
  assert sig.results == [ir.TI32]
  assert sig.dispatch_atom == "add"
  assert sig.host_name == "add"
}

/// §5.4 — a state-touching export (`GlobalGet`) makes the export `touches_state == True` and the
/// whole module `Threaded`.
pub fn state_touching_export_is_threaded_test() {
  let m =
    module_of("g", [reads_global("getg")], [ir.ExportFn("getg", "getg")], [])
  let assert Ok(desc) = iface.describe(m, threaded())
  assert desc.state_model == iface.Threaded
  let assert [sig] = desc.exports
  assert sig.touches_state == True
}

/// §5.5 / R1 — the ADVERSARIAL transitive case: a pure-BODIED export that `CallDirect`s a
/// memory-writing helper is `touches_state == True` (a shallow `expr_touches_state` would report
/// `False`). This is what keeps the descriptor in agreement with the emitted `n+1` arity.
pub fn transitive_state_reaching_test() {
  let m =
    module_of(
      "t",
      [calls("pure_caller", "writer"), writes_mem("writer")],
      [ir.ExportFn("pure_caller", "pure_caller")],
      [],
    )
  let assert Ok(desc) = iface.describe(m, threaded())
  let assert [sig] = desc.exports
  assert sig.touches_state == True
  assert desc.state_model == iface.Threaded
}

// ───────────────────────────── R2 — arity mirrors the emitted core ─────────────────────────────

/// R2 (the crux) — for a MIXED module (a PURE export + a state-MUTATING export), each
/// `ExportSig.emitted_arity` EQUALS the arity of the same export in the real emitted `.core`
/// (`emit_core.emit_module` under the same Threaded binding). Both the pure export (adapter,
/// `n+1`) and the stateful export (direct, `n+1`) are checked.
pub fn export_sig_arity_matches_emitted_core_test() {
  let m =
    module_of(
      "mix",
      [pure_add("add"), writes_mem("writer")],
      [ir.ExportFn("add", "add"), ir.ExportFn("writer", "writer")],
      [],
    )
  let assert Ok(desc) = iface.describe(m, threaded())
  let assert Ok(cmod) = emit_core.emit_module(m, threaded())

  let assert Ok(add_sig) =
    list.find(desc.exports, fn(e) { e.dispatch_atom == "add" })
  let assert Ok(writer_sig) =
    list.find(desc.exports, fn(e) { e.dispatch_atom == "writer" })

  // The descriptor's declared emitted arity.
  assert add_sig.emitted_arity == 3
  assert writer_sig.emitted_arity == 1
  assert add_sig.leading_state == True
  assert writer_sig.leading_state == True

  // …equal to the ACTUAL emitted `.core` export arity (n+1 for both — R19).
  assert add_sig.emitted_arity == emitted_arity(cmod.exports, "add")
  assert writer_sig.emitted_arity == emitted_arity(cmod.exports, "writer")

  // …and the pure/stateful distinction is captured in `touches_state`, not the arity.
  assert add_sig.touches_state == False
  assert writer_sig.touches_state == True
}

// ───────────────────────────── P2 value-ABI mapping ─────────────────────────────

/// §5.6 — `host_types/1` for all NINE `ValType`s across all three languages, exactly per the P2
/// table (integers→int, floats→float, v128→binary, every reference/term→opaque).
pub fn host_types_frozen_test() {
  assert iface.host_types(ir.TI32)
    == iface.HostTypeNames("Int", "integer()", "integer()")
  assert iface.host_types(ir.TI64)
    == iface.HostTypeNames("Int", "integer()", "integer()")
  assert iface.host_types(ir.TF32)
    == iface.HostTypeNames("Float", "float()", "float()")
  assert iface.host_types(ir.TF64)
    == iface.HostTypeNames("Float", "float()", "float()")
  assert iface.host_types(ir.TV128)
    == iface.HostTypeNames("BitArray", "binary()", "binary()")
  assert iface.host_types(ir.TFuncRef)
    == iface.HostTypeNames("Ref", "term()", "term()")
  assert iface.host_types(ir.TExternRef)
    == iface.HostTypeNames("Ref", "term()", "term()")
  assert iface.host_types(ir.TExnRef)
    == iface.HostTypeNames("Ref", "term()", "term()")
  assert iface.host_types(ir.TTerm)
    == iface.HostTypeNames("Ref", "term()", "term()")
}

/// R18/P2 — `value_abi/1` carries the boundary class + the FLOAT CODEC WIDTH (32/64) every
/// emitter uses for the raw-bits round-trip (never `host_types`, which says `Float` for both).
pub fn value_abi_frozen_test() {
  assert iface.value_abi(ir.TI32) == iface.IntAbi(32)
  assert iface.value_abi(ir.TI64) == iface.IntAbi(64)
  assert iface.value_abi(ir.TF32) == iface.FloatAbi(32)
  assert iface.value_abi(ir.TF64) == iface.FloatAbi(64)
  assert iface.value_abi(ir.TV128) == iface.V128Abi
  assert iface.value_abi(ir.TFuncRef) == iface.RefAbi
  assert iface.value_abi(ir.TExternRef) == iface.RefAbi
  assert iface.value_abi(ir.TExnRef) == iface.RefAbi
  assert iface.value_abi(ir.TTerm) == iface.RefAbi
}

/// R4 — the result-package encoding: `[]` → `ResultUnit` (atom `ok`); one result → `ResultBare`;
/// N≥2 → `ResultTuple(N)` in declaration order.
pub fn result_encoding_frozen_test() {
  assert iface.result_encoding([]) == iface.ResultUnit
  assert iface.result_encoding([ir.TI32]) == iface.ResultBare
  assert iface.result_encoding([ir.TI32, ir.TF64]) == iface.ResultTuple(2)
  assert iface.result_encoding([ir.TI32, ir.TF64, ir.TV128])
    == iface.ResultTuple(3)
}

/// §5.7 — multi-value + float coexistence: an export returning `[TI32, TF64]` keeps its results in
/// declaration order (the emitters' tuple + float-round-trip cases build on this).
pub fn multivalue_results_preserved_test() {
  let f =
    ir.Function(
      name: "pair",
      params: [],
      result: [ir.TI32, ir.TF64],
      locals: [],
      body: ir.Values([ir.ConstI32(1), ir.ConstF64(0)]),
    )
  let m = module_of("mv", [f], [ir.ExportFn("pair", "pair")], [])
  let assert Ok(desc) = iface.describe(m, threaded())
  let assert [sig] = desc.exports
  assert sig.results == [ir.TI32, ir.TF64]
  assert iface.result_encoding(sig.results) == iface.ResultTuple(2)
}

// ───────────────────────────── determinism + ordering + skips ─────────────────────────────

/// §5.8 / R8 — exports appear in DECLARATION order; a re-`describe` is byte-equal; and
/// `Iface.module_name` is `module.name` VERBATIM (never normalized).
pub fn ordering_determinism_and_module_name_test() {
  let m =
    module_of(
      "ord",
      [pure_add("a"), pure_add("b"), pure_add("c")],
      [
        ir.ExportFn("a", "a"),
        ir.ExportFn("b", "b"),
        ir.ExportFn("c", "c"),
      ],
      [],
    )
  let assert Ok(desc) = iface.describe(m, threaded())
  assert list.map(desc.exports, fn(e) { e.dispatch_atom }) == ["a", "b", "c"]
  assert desc.module_name == "carder@wasm@ord"
  // Deterministic: describing the same module again is equal.
  assert iface.describe(m, threaded()) == Ok(desc)
}

/// §5.9 — exported STATE (`ExportMemory`/`ExportGlobal`) alongside an `ExportFn` is SKIPPED; only
/// the function surfaces (R13).
pub fn state_exports_skipped_test() {
  let m =
    module_of(
      "sk",
      [pure_add("add")],
      [
        ir.ExportMemory("mem", 0),
        ir.ExportGlobal("gg", "g"),
        ir.ExportFn("add", "add"),
      ],
      [],
    )
  let assert Ok(desc) = iface.describe(m, threaded())
  assert list.map(desc.exports, fn(e) { e.dispatch_atom }) == ["add"]
}

// ───────────────────────────── R9/R15 host-name sanitization ─────────────────────────────

/// R9/R15 — the single-name sanitizer: keeps legal identifiers, lowercases, maps illegal bytes to
/// `_`, and prefixes `e_` when the result cannot start a Gleam identifier (leading digit / `_`).
pub fn sanitize_identifier_test() {
  assert iface.sanitize_identifier("add") == "add"
  assert iface.sanitize_identifier("run-test") == "run_test"
  assert iface.sanitize_identifier("foo.bar") == "foo_bar"
  assert iface.sanitize_identifier("Camel") == "camel"
  assert iface.sanitize_identifier("0") == "e_0"
  assert iface.sanitize_identifier("_start") == "e__start"
  assert iface.sanitize_identifier("") == "e_"
}

/// R15 — `describe/2` resolves host-name collisions + reserved API names deterministically:
/// `dispatch_atom` stays the exact WASM export name, `host_name` is disambiguated with `_2`.
pub fn host_name_collision_resolution_test() {
  let m =
    module_of(
      "coll",
      [pure_add("a"), pure_add("b"), pure_add("c"), pure_add("d")],
      [
        ir.ExportFn("run-test", "a"),
        ir.ExportFn("run.test", "b"),
        ir.ExportFn("instantiate", "c"),
        ir.ExportFn("0", "d"),
      ],
      [],
    )
  let assert Ok(desc) = iface.describe(m, threaded())
  // dispatch atoms are the exact WASM names (never sanitized).
  assert list.map(desc.exports, fn(e) { e.dispatch_atom })
    == ["run-test", "run.test", "instantiate", "0"]
  // host names: sanitized, duplicate disambiguated, reserved `instantiate` bumped.
  assert list.map(desc.exports, fn(e) { e.host_name })
    == ["run_test", "run_test_2", "instantiate_2", "e_0"]
}

// ───────────────────────────── R25b — the compile+call FFI companion ─────────────────────────────

@external(erlang, "carder_bindings_ffi", "which")
fn which(exe: String) -> Result(String, Nil)

@external(erlang, "carder_bindings_ffi", "compile_load_erlang")
fn compile_load_erlang(
  files: List(#(String, String)),
  main: Atom,
) -> Result(Atom, String)

@external(erlang, "carder_bindings_ffi", "compile_load_gleam")
fn compile_load_gleam(
  files: List(#(String, String)),
  main: Atom,
) -> Result(Atom, String)

@external(erlang, "carder_bindings_ffi", "compile_load_elixir")
fn compile_load_elixir(
  files: List(#(String, String)),
  main: Atom,
) -> Result(Atom, String)

// Bound with an `Int` result because every fixture export returns an int (the runtime term is an
// int; `@external` does not type-check the wire). The frozen FFI contract is `Result(Dynamic, _)`.
@external(erlang, "carder_bindings_ffi", "call")
fn call_int(m: Atom, f: Atom, args: List(Int)) -> Result(Int, String)

/// `which/1` finds a present toolchain and reports a bogus one absent (the Elixir best-effort gate).
pub fn ffi_which_test() {
  assert which("erl") != Error(Nil)
  assert which("gleam") != Error(Nil)
  assert which("definitely_not_a_real_executable_zzz") == Error(Nil)
}

/// The in-VM Erlang compile+load+call path: a value fixture returns `{ok, 42}`, and a fixture that
/// RAISES `{wasm_trap, _}` is captured by `call/3` as `Error(_)` (the emitter-bug safety net).
pub fn ffi_erlang_compile_call_test() {
  let val_src =
    "-module(bind_probe_val).\n-export([answer/0]).\nanswer() -> 42.\n"
  let assert Ok(_) =
    compile_load_erlang(
      [#("bind_probe_val.erl", val_src)],
      atom.create("bind_probe_val"),
    )
  assert call_int(atom.create("bind_probe_val"), atom.create("answer"), [])
    == Ok(42)

  let trap_src =
    "-module(bind_probe_trap).\n-export([boom/0]).\nboom() -> erlang:error({wasm_trap, div_by_zero}).\n"
  let assert Ok(_) =
    compile_load_erlang(
      [#("bind_probe_trap.erl", trap_src)],
      atom.create("bind_probe_trap"),
    )
  let assert Error(_) =
    call_int(atom.create("bind_probe_trap"), atom.create("boom"), [])
}

/// The full Gleam shell-out: stage a temp Gleam project, `gleam build`, load, and call — proving
/// the Gleam emitter (P12-02) can compile+call in its own DoD via this companion.
pub fn ffi_gleam_compile_call_test() {
  case which("gleam") {
    Error(_) -> Nil
    Ok(_) -> {
      let src = "pub fn answer() -> Int {\n  42\n}\n"
      let assert Ok(_) =
        compile_load_gleam(
          [#("probe_bindings.gleam", src)],
          atom.create("probe_bindings"),
        )
      assert call_int(atom.create("probe_bindings"), atom.create("answer"), [])
        == Ok(42)
      Nil
    }
  }
}

/// The Elixir shell-out — BEST-EFFORT (P8/R23): a categorized skip when `elixirc` is absent, never
/// a false green. When present, `elixirc` compiles the fixture and the call returns `{ok, 42}`.
pub fn ffi_elixir_compile_call_test() {
  case which("elixirc") {
    Error(_) -> Nil
    Ok(_) -> {
      let src = "defmodule ProbeBindings do\n  def answer, do: 42\nend\n"
      let assert Ok(_) =
        compile_load_elixir(
          [#("probe_bindings.ex", src)],
          atom.create("Elixir.ProbeBindings"),
        )
      assert call_int(
          atom.create("Elixir.ProbeBindings"),
          atom.create("answer"),
          [],
        )
        == Ok(42)
      Nil
    }
  }
}
