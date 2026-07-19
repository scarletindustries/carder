//// Phase-14 (R14-02) — imported-`ref.func` emission, end-to-end + arity-lockstep.
////
//// Objective tests against the WebAssembly spec for element segments (§2.5.6 / §4.5.4 —
//// instantiation writes each element's `ref.func x` reference into the table, where the funcidx
//// space is unified with imports FIRST) and `call_indirect` of an imported function (§4.4.8 — an
//// imported function reached via `call_indirect` behaves IDENTICALLY to a direct `call` of that
//// import; the three guards — index-in-bounds → `UndefinedElement`, slot-non-null →
//// `UninitializedElement`, exact `FuncType` → `IndirectCallTypeMismatch` — evaluate in order).
////
//// These assert a spec-defined RESULT/behaviour, never the current byte output (not
//// change-detectors). The headline (§5.2) asserts the `call_indirect` of an imported funcref
//// returns the SAME SINGLE value as a direct call of the import (a scalar, NOT a wrapped list) —
//// under Cell AND Threaded. The e2e harness follows `emit_core_e2e_test`
//// (`emit_module → core_printer.print_module → build_beam.compile_and_load → catch_apply`).

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import twocore/backend/build_beam
import twocore/backend/emit_core
import twocore/conformance/driver
import twocore/ir
import twocore/runtime/instance
import twocore/runtime/link

// ───────────────────────────── test-only FFI (shared with `emit_core_e2e_test`) ─────────────────────────────

// Apply `M:F(Args)` capturing a trap as `Error(text)` instead of crashing the test process.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

// The SAME `catch_apply/3`, re-typed for `Dynamic` args/results — drives the `instantiate/1(Imports)`
// ABI (its single argument is the whole positional `[Provided ...]` list).
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply_dyn(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

// Apply `M:F(Args)` returning the raw result (used to route a provider closure into a loaded module).
@external(erlang, "twocore_emit_test_ffi", "apply3")
fn apply3(module: Atom, function: Atom, args: List(Dynamic)) -> Dynamic

// Run the record-returning threaded `instantiate/1(Imports)`, yielding the record or a trap text.
@external(erlang, "twocore_threaded_test_ffi", "instantiate_with")
fn t_instantiate_with(module: Atom, imports: Dynamic) -> Result(Dynamic, String)

// Invoke a value-returning export under Threaded: `{IntResult, St'}` on success (package coerced to
// `Int` at the FFI boundary), a trap text on `Error`.
@external(erlang, "twocore_threaded_test_ffi", "invoke")
fn t_invoke_int(
  module: Atom,
  function: Atom,
  st: Dynamic,
  args: List(Int),
) -> Result(#(Int, Dynamic), String)

// Coerce any Gleam value to `Dynamic` (identity at runtime) — hand the `[Provided ...]` list to
// `instantiate/1` as one opaque argument.
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

// ───────────────────────────── plumbing ─────────────────────────────

fn cell_binding() -> instance.Binding {
  instance.safe_default()
}

fn threaded_binding() -> instance.Binding {
  instance.Binding(..instance.safe_default(), state_strategy: instance.Threaded)
}

/// Emit `module` under `binding` to Core text and compile+load it; `Ok(atom)` on success, or the
/// first failing stage's `Error(text)`. Used both to LOAD (asserting `Ok`) and to prove
/// well-formedness (§5.1: emit + compile succeed ⇔ the adapter arity lines up with the slot ABI).
fn emit_and_load(
  module: ir.Module,
  binding: instance.Binding,
) -> Result(Atom, String) {
  case emit_core.emit_module(module, binding) {
    Error(e) -> Error("emit: " <> string.inspect(e))
    Ok(cm) ->
      build_beam.compile_and_load(cm)
      |> result.map_error(fn(e) { "build: " <> string.inspect(e) })
  }
}

/// Load `module`, asserting emit+compile succeed (a `let assert` success contract).
fn load(module: ir.Module, binding: instance.Binding) -> Atom {
  let assert Ok(mod) = emit_and_load(module, binding)
  mod
}

/// The import's declared signature used throughout: `[i32] -> [i32]`.
fn import_ty() -> ir.FuncType {
  ir.FuncType([ir.TI32], [ir.TI32])
}

/// A pure provider function `ef(x) = x + 41` (the imported callee), exported by name so a routing
/// closure can dispatch into it (`apply3`).
fn ef_fn() -> ir.Function {
  ir.Function(
    name: "ef",
    params: [ir.Local("x", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.Num(ir.IAdd(ir.W32), [ir.Var("x"), ir.ConstI32(41)]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// A provider module exporting a single function `functions`, by name (numerics on, no imports).
fn provider_module(name: String, functions: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "twocore@rfi@" <> name,
    uses_numerics: True,
    memories: [],
    globals: [],
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

/// A consumer module: imports `a.ef` (funcidx 0), declares one `FuncRef` table `t0` of `table_min`
/// slots, actively places `RefFuncImport(0, import_ty())` into slot 0, and carries `functions`
/// (exported by name). It NEVER `CallImport`s — its only use of the import is the element-segment
/// `ref.func`, so it is import-bearing PURELY through the element scan (`needs_func_imports`).
fn consumer_module(
  name: String,
  table_min: Int,
  functions: List(ir.Function),
) -> ir.Module {
  ir.Module(
    name: "twocore@rfi@" <> name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [ir.ImportFn("a", "ef", import_ty())],
    functions: functions,
    exports: list.map(functions, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [ir.TableDecl("t0", ir.FuncRef, table_min, option.None)],
    elements: [
      ir.ElementSegment(
        ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
        ir.FuncRef,
        [ir.RefFuncImport(0, import_ty())],
      ),
    ],
    start: option.None,
    tags: [],
  )
}

/// The `x ↦ x + 41` routing closure into `mod_a`'s exported `ef` — the D3a func-import capability
/// (`fn(List(Dynamic)) -> List(Dynamic)`), handed to `instantiate/1` as `[provided]`.
fn ef_provided(mod_a: Atom) -> link.Provided {
  link.provided_func(import_ty(), fn(args: List(Dynamic)) -> List(Dynamic) {
    [apply3(mod_a, atom.create("ef"), args)]
  })
}

/// `dispatch(k) = call_indirect $t0 (i32.const 0) (local.get k)` — dispatch slot 0 with argument
/// `k` at the import's declared type.
fn dispatch_fn() -> ir.Function {
  ir.Function(
    name: "dispatch",
    params: [ir.Local("k", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.CallIndirect("t0", ir.ConstI32(0), import_ty(), [ir.Var("k")]),
  )
}

// ───────────────────────────── §5.1 — well-formed Core (emits + compiles/loads) ─────────────────────────────

/// §5.1: a hand-built imported-funcref module (one `ImportFn`, one active `elem` placing a
/// `RefFuncImport` into a `FuncRef` table) EMITS and COMPILES/LOADS under BOTH Cell and Threaded —
/// i.e. the adapter closure's arity matches the table-entry ABI (`fun(Args)` cell, `fun(St, Args)`
/// threaded). The earlier `Error(UnknownFunction)` residual could never reach this bar.
pub fn imported_funcref_module_compiles_cell_and_threaded_test() {
  let m = consumer_module("s51_basic", 2, [dispatch_fn()])
  let assert Ok(_) = emit_and_load(m, cell_binding())
  let assert Ok(_) = emit_and_load(m, threaded_binding())
}

/// §5.1 adversarial — a MULTI-VALUE imported `ty` (`[i32,f64] -> [i32,f64]`): the adapter unpacks
/// `call_import`'s 2-element result list and re-packages it as the 2-tuple `function_return` the
/// slot ABI expects, so the Core compiles/loads under Cell and Threaded.
pub fn imported_funcref_multivalue_compiles_test() {
  let mv_ty = ir.FuncType([ir.TI32, ir.TF64], [ir.TI32, ir.TF64])
  let m =
    ir.Module(
      name: "twocore@rfi@s51_mv",
      uses_numerics: True,
      memories: [],
      globals: [],
      imports: [ir.ImportFn("a", "ef", mv_ty)],
      functions: [],
      exports: [],
      data_segments: [],
      tables: [ir.TableDecl("t0", ir.FuncRef, 2, option.None)],
      elements: [
        ir.ElementSegment(
          ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
          ir.FuncRef,
          [ir.RefFuncImport(0, mv_ty)],
        ),
      ],
      start: option.None,
      tags: [],
    )
  let assert Ok(_) = emit_and_load(m, cell_binding())
  let assert Ok(_) = emit_and_load(m, threaded_binding())
}

/// §5.1 adversarial — a NON-ZERO table target (tidx ≠ 0 forces `init_elem_ref`): the imported
/// funcref is placed into `t1` (index 1), so the segment cannot take the frozen table-0 `init_elem`
/// fast path. Compiles/loads under Cell and Threaded.
pub fn imported_funcref_nonzero_table_compiles_test() {
  let m =
    ir.Module(
      name: "twocore@rfi@s51_t1",
      uses_numerics: True,
      memories: [],
      globals: [],
      imports: [ir.ImportFn("a", "ef", import_ty())],
      functions: [],
      exports: [],
      data_segments: [],
      tables: [
        ir.TableDecl("t0", ir.FuncRef, 2, option.None),
        ir.TableDecl("t1", ir.FuncRef, 2, option.None),
      ],
      elements: [
        ir.ElementSegment(
          ir.ElemActive("t1", ir.Values([ir.ConstI32(0)])),
          ir.FuncRef,
          [ir.RefFuncImport(0, import_ty())],
        ),
      ],
      start: option.None,
      tags: [],
    )
  let assert Ok(_) = emit_and_load(m, cell_binding())
  let assert Ok(_) = emit_and_load(m, threaded_binding())
}

/// §5.1 adversarial — a MIXED segment `[RefFunc("f1"), RefFuncImport(0, …), ref.null func]`: the
/// imported item does NOT poison the defined/null items — `byte_ident_funcref` is `False` (the
/// segment routes through `init_elem_ref`) and EVERY item renders, so the Core compiles/loads.
pub fn imported_funcref_mixed_segment_compiles_test() {
  let f1 =
    ir.Function(
      name: "f1",
      params: [ir.Local("x", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Return([ir.Var("x")]),
    )
  let m =
    ir.Module(
      name: "twocore@rfi@s51_mixed",
      uses_numerics: True,
      memories: [],
      globals: [],
      imports: [ir.ImportFn("a", "ef", import_ty())],
      functions: [f1],
      exports: [],
      data_segments: [],
      tables: [ir.TableDecl("t0", ir.FuncRef, 3, option.None)],
      elements: [
        ir.ElementSegment(
          ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
          ir.FuncRef,
          [
            ir.RefFunc("f1"),
            ir.RefFuncImport(0, import_ty()),
            ir.Values([ir.ConstNull(ir.FuncRef)]),
          ],
        ),
      ],
      start: option.None,
      tags: [],
    )
  let assert Ok(_) = emit_and_load(m, cell_binding())
  let assert Ok(_) = emit_and_load(m, threaded_binding())
}

// ───────────────────────────── §5.2 — e2e dispatch == direct call (Cell AND Threaded) ─────────────────────────────

/// §5.2 (Cell): an imported function placed into a table via an active `elem` `ref.func` segment and
/// reached through `call_indirect` returns the SAME SINGLE value as a direct `call` of that import
/// (spec §4.4.8). The result is a scalar `K + 41`, NOT a wrapped list — proving the adapter returns
/// the package the slot ABI expects (unpacked once to the scalar), the exact double-wrap trap the
/// design guards against.
pub fn imported_funcref_call_indirect_equals_direct_cell_test() {
  let mod_a = load(provider_module("s52c_prov", [ef_fn()]), cell_binding())
  let provided = ef_provided(mod_a)
  let mod_b =
    load(consumer_module("s52c_cons", 2, [dispatch_fn()]), cell_binding())
  let assert Ok(_) =
    catch_apply_dyn(mod_b, atom.create("instantiate"), [to_dynamic([provided])])
  // The direct call of the import, and the call_indirect of it, MUST agree (a single value each).
  assert catch_apply(mod_a, atom.create("ef"), [1]) == Ok(42)
  assert catch_apply(mod_b, atom.create("dispatch"), [1]) == Ok(42)
  // A second value, to prove it is the real function (not a constant), and the exact scalar shape.
  assert catch_apply(mod_b, atom.create("dispatch"), [100]) == Ok(141)
}

/// §5.2 (Threaded): the same headline under a Threaded build — `instantiate/1(Imports)` returns the
/// record, and the threaded adapter threads `St` UNCHANGED (the imported callee threads its own
/// state inside the routing closure). The `call_indirect` still returns the scalar `K + 41`.
pub fn imported_funcref_call_indirect_equals_direct_threaded_test() {
  let mod_a = load(provider_module("s52t_prov", [ef_fn()]), cell_binding())
  let provided = ef_provided(mod_a)
  let mod_b =
    load(consumer_module("s52t_cons", 2, [dispatch_fn()]), threaded_binding())
  let assert Ok(st0) = t_instantiate_with(mod_b, to_dynamic([provided]))
  let assert Ok(#(v1, st1)) =
    t_invoke_int(mod_b, atom.create("dispatch"), st0, [1])
  assert v1 == 42
  let assert Ok(#(v2, _)) =
    t_invoke_int(mod_b, atom.create("dispatch"), st1, [100])
  assert v2 == 141
}

// ───────────────────────────── §5.3 — the three ordered guards fire on an import-routed slot ─────────────────────────────

/// A consumer with the SAME import-routed slot plus dispatch functions that violate exactly one
/// `call_indirect` guard each: `disp(idx, k)` dispatches an arbitrary slot; `disp_wrong(k)`
/// dispatches slot 0 with the WRONG expected type `[i64] -> [i64]`.
fn guards_consumer() -> ir.Module {
  let disp =
    ir.Function(
      name: "disp",
      params: [ir.Local("idx", ir.TI32), ir.Local("k", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.CallIndirect("t0", ir.Var("idx"), import_ty(), [ir.Var("k")]),
    )
  let disp_wrong =
    ir.Function(
      name: "disp_wrong",
      params: [ir.Local("k", ir.TI32)],
      result: [ir.TI64],
      locals: [],
      body: ir.CallIndirect(
        "t0",
        ir.ConstI32(0),
        ir.FuncType([ir.TI64], [ir.TI64]),
        [ir.ConstI64(0)],
      ),
    )
  consumer_module("s53", 2, [disp, disp_wrong])
}

/// §5.3: the three ordered `call_indirect` guards (spec §4.4.8) still fire for an import-routed slot,
/// exactly as for a defined-funcref slot: (1) index ≥ table size → `UndefinedElement`; (2) a
/// never-written slot → `UninitializedElement`; (3) an expected `FuncType` ≠ the import's declared
/// type → `IndirectCallTypeMismatch`. Slot 0 (in-bounds, initialised, matching type) dispatches.
pub fn import_routed_slot_guards_fire_in_order_test() {
  let mod_a = load(provider_module("s53_prov", [ef_fn()]), cell_binding())
  let provided = ef_provided(mod_a)
  let mod_b = load(guards_consumer(), cell_binding())
  let assert Ok(_) =
    catch_apply_dyn(mod_b, atom.create("instantiate"), [to_dynamic([provided])])
  // slot 0 works (in-bounds, initialised, exact type).
  assert catch_apply(mod_b, atom.create("disp"), [0, 5]) == Ok(46)
  // guard 1: index past the table bound (size 2) → UndefinedElement.
  let assert Error(undef) = catch_apply(mod_b, atom.create("disp"), [10, 5])
  assert string.contains(undef, "undefined_element")
  // guard 2: in-bounds but never-written slot 1 → UninitializedElement.
  let assert Error(uninit) = catch_apply(mod_b, atom.create("disp"), [1, 5])
  assert string.contains(uninit, "uninitialized_element")
  // guard 3: right slot, wrong expected type ([i64]->[i64] vs the stored [i32]->[i32]).
  let assert Error(mismatch) =
    catch_apply(mod_b, atom.create("disp_wrong"), [0])
  assert string.contains(mismatch, "indirect_call_type_mismatch")
}

// ───────────────────────────── §5.4 — instantiate/0 ⇄ instantiate/1 arity lockstep ─────────────────────────────

/// A passive-only consumer: its ONLY `RefFuncImport` sits in a PASSIVE `elem` segment that is never
/// `table.init`'d, with no `CallImport` in any body. Proves the conservative all-modes element scan
/// fires on passive segments too (R3/§3.3).
fn passive_only_module() -> ir.Module {
  ir.Module(
    name: "twocore@rfi@s54_passive",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [ir.ImportFn("a", "ef", import_ty())],
    functions: [],
    exports: [],
    data_segments: [],
    tables: [ir.TableDecl("t0", ir.FuncRef, 1, option.None)],
    elements: [
      ir.ElementSegment(ir.ElemPassive, ir.FuncRef, [
        ir.RefFuncImport(0, import_ty()),
      ]),
    ],
    start: option.None,
    tags: [],
  )
}

/// A body-only consumer: it `ref.func`s the import in a FUNCTION BODY (stored into a table slot via
/// `table.set`), never in an element segment and never `CallImport`. Proves the body scan
/// (`expr_has_ref_func_import`) fires (§3.3).
fn body_only_module() -> ir.Module {
  let stash =
    ir.Function(
      name: "stash",
      params: [],
      result: [],
      locals: [],
      body: ir.Let(
        ["ref"],
        ir.RefFuncImport(0, import_ty()),
        ir.Let(
          [],
          ir.TableSet("t0", ir.ConstI32(0), ir.Var("ref")),
          ir.Values([]),
        ),
      ),
    )
  ir.Module(
    name: "twocore@rfi@s54_body",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [ir.ImportFn("a", "ef", import_ty())],
    functions: [stash],
    exports: [ir.ExportFn("stash", "stash")],
    data_segments: [],
    tables: [ir.TableDecl("t0", ir.FuncRef, 1, option.None)],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// The NEGATIVE twin: imports `a.ef` but neither CALLS nor `ref.func`s it — stays import-free for
/// the func-import vector (`instantiate/0`, byte-neutral, I7).
fn negative_module() -> ir.Module {
  ir.Module(
    name: "twocore@rfi@s54_neg",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [ir.ImportFn("a", "ef", import_ty())],
    functions: [
      ir.Function(
        name: "id",
        params: [ir.Local("x", ir.TI32)],
        result: [ir.TI32],
        locals: [],
        body: ir.Return([ir.Var("x")]),
      ),
    ],
    exports: [ir.ExportFn("id", "id")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// §5.4: `emit_core.needs_func_imports` and `driver.module_calls_import` are ONE predicate over the
/// SAME `irmod`, so the generated `instantiate/1` arity and the driver's supplied `Imports` length
/// cannot desync (R3). A module import-bearing PURELY through an element-segment `ref.func` (active,
/// passive) OR a body-level `ref.func` — with NO `CallImport` — is recognised by both; its
/// `count_import_slots == count_function_imports > 0` (→ `instantiate/1`). The negative twin stays
/// `False` (→ `instantiate/0`).
pub fn import_bearing_detection_is_in_lockstep_test() {
  // Active-segment `ref.func` (no CallImport): both sides fire, arity is instantiate/1.
  let active = consumer_module("s54_active", 2, [dispatch_fn()])
  assert emit_core.needs_func_imports(active) == True
  assert driver.module_calls_import(active) == True
  assert emit_core.count_import_slots(active)
    == emit_core.count_function_imports(active)
  assert emit_core.count_import_slots(active) > 0

  // Passive-only `ref.func` (never table.init'd): the all-modes element scan still fires (§3.3).
  let passive = passive_only_module()
  assert emit_core.needs_func_imports(passive) == True
  assert driver.module_calls_import(passive) == True
  assert emit_core.count_import_slots(passive) > 0

  // Body-level `ref.func` (no elem, no CallImport): the body scan fires.
  let body = body_only_module()
  assert emit_core.needs_func_imports(body) == True
  assert driver.module_calls_import(body) == True
  assert emit_core.count_import_slots(body) > 0

  // Negative twin: imports but neither calls nor ref.funcs → instantiate/0, byte-neutral.
  let neg = negative_module()
  assert emit_core.needs_func_imports(neg) == False
  assert driver.module_calls_import(neg) == False
  assert emit_core.count_import_slots(neg) == 0
}

/// §5.4 behavioural: the passive-only and body-only modules also EMIT + COMPILE/LOAD under Cell and
/// Threaded (their `instantiate/1` arity is well-formed). Combined with §5.2 (which LOADS + RUNS the
/// active-segment module via `instantiate/1`), this closes the desync tripwire: emit's arity and the
/// driver's woven `Imports` length agree for every import-bearing shape.
pub fn import_bearing_modules_emit_under_both_strategies_test() {
  let assert Ok(_) = emit_and_load(passive_only_module(), cell_binding())
  let assert Ok(_) = emit_and_load(passive_only_module(), threaded_binding())
  let assert Ok(_) = emit_and_load(body_only_module(), cell_binding())
  let assert Ok(_) = emit_and_load(body_only_module(), threaded_binding())
}
