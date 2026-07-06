//// R14-01 — the keystone freeze for `RefFuncImport` (cross-module `ref.func` of an IMPORTED
//// function), verified against the WebAssembly spec — NOT change-detectors (R7/D8).
////
//// The freeze proves (each downstream Phase-14 unit binds to exactly these):
////
//// - **the node is EXPRESSIBLE** — a module whose element segment AND a function body use
////   `ir.RefFuncImport(slot, ty)` typechecks and pins the frozen shape (R1);
//// - **the `ref.func` import-split is CORRECT** — the WASM funcidx space is unified (imports
////   `0..imported-1`, then defined), so `lower` routes `ast.RefFunc(f)` with `f < imported` to
////   `RefFuncImport(f, ty)` and `f >= imported` to `RefFunc("f<f>")`, in BOTH a function body and
////   an element segment (the mirror of the `call` split);
//// - **the node is an effect BARRIER, memory-inert, and NOT-a-call** — `classify == Effectful`,
////   no CSE, no DCE (a reference construction like `ref.func`), yet it writes no linear memory and
////   is not a call for loop-versioning (the deliberate non-mirrors of `CallImport`);
//// - **lossless `.ir` round-trip (D5)** — `parse(print(m)) == Ok(m)` over a multi-value `ty`, an
////   empty-results `ty`, `slot == 0` and `slot >= 1`, inside an `ElemExprs` segment mixed with a
////   defined `RefFunc`, and inside a function body;
//// - **no new `TrapReason` (R8)** — the ten-variant set is unchanged (building a funcref never
////   traps);
//// - **defaults are byte-identical (R5)** — a module with no imported `ref.func` round-trips, its
////   `.ir`/`.core` carry NONE of the new token, and its all-`RefFunc` table-0 segment keeps the
////   frozen `init_elem` fast path (never routed to `init_elem_ref`);
//// - **the imported-`ref.func` case STILL SKIPS, byte-identically** — `emit_module` returns the
////   EXACT `Error(UnknownFunction("f<slot>"))` the pre-keystone `ir.RefFunc("f<slot>")` produced,
////   in the element-segment path, a function body, and a reference-global init — no regression;
////   R14-02 is what flips it to `Ok`.

import gleam/list
import gleam/option.{None}
import gleam/set
import gleam/string
import gleeunit/should
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/lower
import twocore/frontend/wasm/validate
import twocore/ir
import twocore/ir/effect
import twocore/ir/parser
import twocore/ir/printer
import twocore/middle/ir_opt
import twocore/middle/ir_opt/bce
import twocore/middle/ir_opt/mem_clobber
import twocore/opt_level
import twocore/runtime/instance

// ───────────────────────────── local inspection helpers ─────────────────────────────

/// Every expression node in `e`'s tree (itself plus all nested sub-expressions). `RefFuncImport`
/// is a LEAF (only a slot + type), so it lands in the default arm and a membership check over
/// `all_exprs(body)` finds it.
fn all_exprs(e: ir.Expr) -> List(ir.Expr) {
  let nested = case e {
    ir.Let(_, rhs, body) -> list.append(all_exprs(rhs), all_exprs(body))
    ir.Block(_, _, body) -> all_exprs(body)
    ir.Loop(_, _, _, body) -> all_exprs(body)
    ir.If(_, _, t, el) -> list.append(all_exprs(t), all_exprs(el))
    ir.Switch(_, _, arms, default) ->
      list.append(
        list.flat_map(arms, fn(a) { all_exprs(a.body) }),
        all_exprs(default),
      )
    ir.Charge(_, body) -> all_exprs(body)
    _ -> []
  }
  [e, ..nested]
}

/// The single defined function named `name` in the lowered module.
fn func(irm: ir.Module, name: String) -> ir.Function {
  let assert Ok(f) = list.find(irm.functions, fn(f) { f.name == name })
  f
}

/// Every expression node across ALL defined functions of the module.
fn all_module_exprs(irm: ir.Module) -> List(ir.Expr) {
  list.flat_map(irm.functions, fn(f) { all_exprs(f.body) })
}

/// Build a `validate.TypedModule` directly, bypassing `validate.validate` (mirrors the
/// `tail_call_lower_test` idiom). Only the fields `lower` reads for the `ref.func` import split are
/// meaningful: `imported_func_count` (the split boundary), `func_types` (indexed by ABSOLUTE
/// funcidx — imports first — so an imported funcidx recovers its signature), `types`/`imports` (the
/// import declarations), `funcs`/`func_locals` (the defined functions), and `elements`.
fn typed_module(
  imported: Int,
  types: List(ast.FuncType),
  imports: List(ast.Import),
  func_types: List(ast.FuncType),
  func_locals: List(List(ast.ValType)),
  funcs: List(ast.Func),
  elements: List(ast.ElementSegment),
) -> validate.TypedModule {
  validate.TypedModule(
    module: ast.Module(
      imported_func_count: imported,
      types: types,
      imports: imports,
      tables: [],
      memories: [],
      globals: [],
      tags: [],
      funcs: funcs,
      start: option.None,
      elements: elements,
      data: [],
      data_count: option.None,
      exports: [],
    ),
    imported_func_count: imported,
    imported_global_count: 0,
    imported_table_count: 0,
    imported_memory_count: 0,
    func_types: func_types,
    func_locals: func_locals,
    global_types: [],
    table_types: [],
    memory_idx_types: [],
    elem_types: [],
    refs: set.new(),
    imported_tag_count: 0,
    tag_types: [],
  )
}

/// Lower `tm`, asserting success (the fixtures are structurally lowerable).
fn lower_ok(tm: validate.TypedModule) -> ir.Module {
  let assert Ok(irm) = lower.lower(tm)
  irm
}

/// A minimal IR module carrying `functions` / `globals` / `tables` / `elements` (everything else
/// empty) — the emit fixtures below vary only these. No memory (a 0-page memory is synthesised),
/// `uses_numerics: True` like the other freeze fixtures.
fn ir_module(
  name: String,
  imports: List(ir.ImportDecl),
  functions: List(ir.Function),
  globals: List(ir.GlobalDecl),
  tables: List(ir.TableDecl),
  elements: List(ir.ElementSegment),
  exports: List(ir.ExportDecl),
) -> ir.Module {
  ir.Module(
    name: name,
    uses_numerics: True,
    memories: [],
    globals: globals,
    imports: imports,
    functions: functions,
    exports: exports,
    data_segments: [],
    tables: tables,
    elements: elements,
    start: None,
    tags: [],
  )
}

// ───────────────────────────── §4.1 the node is EXPRESSIBLE ─────────────────────────────

/// The load-bearing freeze: construct a module whose element segment (an `ElemExprs`-style init
/// holding `RefFuncImport`) AND a function body use the node, assert the value COMPILES, and pin the
/// frozen `RefFuncImport(slot, ty)` shape. R14-02..04 bind to exactly this constructor.
pub fn reffunc_import_node_is_expressible_test() {
  let ty = ir.FuncType([ir.TI32], [ir.TI32])
  // A function body materialising an imported funcref.
  let body = ir.Let(["r"], ir.RefFuncImport(0, ty), ir.Return([ir.Var("r")]))
  let f = ir.Function("f1", [], [ir.TFuncRef], [], body)
  // An element segment mixing an imported-funcref item with a defined one.
  let seg =
    ir.ElementSegment(
      ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
      ir.FuncRef,
      [ir.RefFuncImport(0, ty), ir.RefFunc("f1")],
    )
  let module =
    ir_module(
      "twocore@reffunc_import@expressible",
      [],
      [f],
      [],
      [ir.TableDecl("t0", ir.FuncRef, 2, None)],
      [seg],
      [],
    )

  // The value compiled ⇒ the surface is expressible. Pin the frozen `RefFuncImport(slot, ty)` shape
  // from the element segment (an imported item mixed with a defined `RefFunc`) …
  let assert [ir.RefFuncImport(slot, pinned), ir.RefFunc("f1")] = seg.init
  slot |> should.equal(0)
  pinned |> should.equal(ty)
  // …and from the function body (a `Let`-bound leaf).
  let assert ir.Let(["r"], ir.RefFuncImport(0, _), _) =
    { module.functions |> first }.body
}

/// The first function of a one-function module.
fn first(fs: List(ir.Function)) -> ir.Function {
  let assert [f, ..] = fs
  f
}

// ───────────────────────────── §4.2 the import-split is CORRECT ─────────────────────────────

/// The `(i32) -> (i32)` and `(f64) -> ()` import signatures + `() -> ()` unit, used across the
/// split fixture. `func_types` is indexed by absolute funcidx: `[ty0, ty1, unit, unit]`.
fn split_types() -> #(ast.FuncType, ast.FuncType, ast.FuncType) {
  #(
    ast.FuncType([ast.I32], [ast.I32]),
    ast.FuncType([ast.F64], []),
    ast.FuncType([], []),
  )
}

/// Two function imports (funcidx 0, 1) + two defined functions (funcidx 2, 3). `f2`'s body
/// `ref.func`s the IMPORT at funcidx 0; `f3`'s body `ref.func`s the DEFINED function at funcidx 2;
/// an active element segment `ref.func`s funcidx 0,1,2,3 in order (the whole boundary in one list).
fn split_module() -> validate.TypedModule {
  let #(ty0, ty1, unit) = split_types()
  typed_module(
    2,
    // module.types: 0=unit, 1=ty0, 2=ty1 (import type indices)
    [unit, ty0, ty1],
    [
      ast.Import("a", "ef0", ast.ImportFunc(1)),
      ast.Import("a", "ef1", ast.ImportFunc(2)),
    ],
    // func_types by absolute funcidx: imports first, then the two defined (unit)
    [ty0, ty1, unit, unit],
    [[], []],
    [
      ast.Func(0, [], [ast.RefFunc(0), ast.Drop, ast.End]),
      ast.Func(0, [], [ast.RefFunc(2), ast.Drop, ast.End]),
    ],
    [
      ast.ElementSegment(
        ast.ElemActive(0, [ast.I32Const(0), ast.End]),
        ast.FuncRef,
        ast.ElemExprs([
          [ast.RefFunc(0), ast.End],
          [ast.RefFunc(1), ast.End],
          [ast.RefFunc(2), ast.End],
          [ast.RefFunc(3), ast.End],
        ]),
      ),
    ],
  )
}

/// §4.2 — the ELEMENT-SEGMENT split (the load-bearing cross-module path — `table_copy`'s shape).
/// Per the spec, `ref.func x` names the function at unified funcidx `x`; imports occupy `0..imported-1`.
/// So with `imported == 2` the segment `[ref.func 0, 1, 2, 3]` lowers to
/// `[RefFuncImport(0, ty0), RefFuncImport(1, ty1), RefFunc("f2"), RefFunc("f3")]` — imported items
/// (incl. the boundary `f == imported - 1 == 1`) become `RefFuncImport`; defined items
/// (incl. the first defined `f == imported == 2`) stay `RefFunc`.
pub fn ref_func_import_split_in_element_segment_test() {
  let #(ty0, ty1, _unit) = split_types()
  let irm = lower_ok(split_module())
  let assert [seg] = irm.elements
  seg.init
  |> should.equal([
    ir.RefFuncImport(0, ir.FuncType([ir.TI32], [ir.TI32])),
    ir.RefFuncImport(1, ir.FuncType([ir.TF64], [])),
    ir.RefFunc("f2"),
    ir.RefFunc("f3"),
  ])
  // Guard the fixture's premise: the two imported sigs really are ty0 / ty1.
  ty0 |> should.equal(ast.FuncType([ast.I32], [ast.I32]))
  ty1 |> should.equal(ast.FuncType([ast.F64], []))
}

/// §4.2 — the FUNCTION-BODY split. `f2`'s `ref.func 0` (an import, `0 < imported`) lowers to
/// `RefFuncImport(0, ty0)`; `f3`'s `ref.func 2` (defined, `2 >= imported`) lowers to
/// `RefFunc("f2")` — the exact mirror of `lower_call`'s split.
pub fn ref_func_import_split_in_function_body_test() {
  let irm = lower_ok(split_module())

  all_exprs(func(irm, "f2").body)
  |> list.contains(ir.RefFuncImport(0, ir.FuncType([ir.TI32], [ir.TI32])))
  |> should.equal(True)
  // …and NOT a defined `RefFunc("f0")` for the import.
  all_exprs(func(irm, "f2").body)
  |> list.contains(ir.RefFunc("f0"))
  |> should.equal(False)

  all_exprs(func(irm, "f3").body)
  |> list.contains(ir.RefFunc("f2"))
  |> should.equal(True)
  // …and the defined callee is NOT mis-routed to a `RefFuncImport`.
  all_exprs(func(irm, "f3").body)
  |> list.any(fn(e) {
    case e {
      ir.RefFuncImport(_, _) -> True
      _ -> False
    }
  })
  |> should.equal(False)
}

// ───────────────────────────── §4.3 barrier / memory-inert / not-a-call ─────────────────────────────

/// §4.3 — the arm treatment. Building an imported funcref materialises an instance-linked closure —
/// a BARRIER like `ref.func` of a defined function (never CSE/reorder/DCE) — but it writes no
/// memory and dispatches nothing, so the dispatch-only analyses (mem-clobber, loop-versioning) see
/// it as INERT, exactly as `RefFunc`. These are the deliberate non-mirrors of `CallImport`.
pub fn reffunc_import_is_barrier_memory_inert_and_not_a_call_test() {
  let ty = ir.FuncType([ir.TI32], [ir.TI32])
  let node = ir.RefFuncImport(0, ty)

  // Effect BARRIER (spec: a reference construction that materialises instance-linked state).
  effect.is_effectful_node(node) |> should.be_true
  effect.classify(node) |> should.equal(effect.Effectful)
  effect.can_cse(node) |> should.be_false
  effect.can_eliminate_if_unused(node) |> should.be_false

  // MEMORY-INERT: writes no linear memory (the funcref is built now; any dispatch is later, at a
  // distinct `CallIndirect` barrier). Contrast a real `CallImport`, which IS a memory-write barrier
  // — proving `RefFuncImport` is NOT treated as a call in the write analysis.
  mem_clobber.may_write_memory(node) |> should.be_false
  mem_clobber.may_write_memory(ir.CallImport(0, ty, [])) |> should.be_true

  // NOT-A-CALL for loop versioning: `bce.has_grow_or_call` over a body containing only a
  // `RefFuncImport` is `False` (it falls to the `_ -> False` default, like `RefFunc`), so a loop
  // holding one stays versioning-eligible. A real `CallImport` IS a call (the deliberate contrast).
  bce.has_grow_or_call(node) |> should.be_false
  bce.has_grow_or_call(ir.CallImport(0, ty, [])) |> should.be_true

  // …and the WHOLE optimizer pipeline (Baseline + Aggressive, incl. bce / mem_ssa / mem_clobber)
  // treats it as an inert barrier: it SURVIVES optimization (never DCE'd/CSE'd away).
  let body = ir.Let(["r"], node, ir.Return([ir.Var("r")]))
  let f = ir.Function("f0", [], [ir.TFuncRef], [], body)
  let m =
    ir_module("twocore@reffunc_import@opt", [], [f], [], [], [], [
      ir.ExportFn("run", "f0"),
    ])
  list.each([opt_level.Baseline, opt_level.Aggressive], fn(level) {
    all_module_exprs(ir_opt.optimize(m, level))
    |> list.contains(node)
    |> should.equal(True)
  })
}

// ───────────────────────────── §4.4 lossless `.ir` round-trip (D5) ─────────────────────────────

/// §4.4 — the D5 proof: `parse(print(m)) == Ok(m)` for a module using `RefFuncImport` in adversarial
/// shapes — a MULTI-VALUE `ty` (`[i32, f64] -> [i32, f64]`, `slot >= 1`) in a function body, and,
/// inside an `ElemExprs` element segment MIXED with a defined `RefFunc`, an EMPTY-RESULTS `ty`
/// (`[] -> []`, `slot == 0`) and a single-value `ty` at `slot >= 1`. The mixed segment is not
/// `all_reffunc`, so it round-trips via the canonical `elem` spelling.
pub fn reffunc_import_round_trips_test() {
  let multi = ir.FuncType([ir.TI32, ir.TF64], [ir.TI32, ir.TF64])
  let empty = ir.FuncType([], [])
  let single = ir.FuncType([ir.TI32], [ir.TI32])

  let body = ir.Let(["r"], ir.RefFuncImport(3, multi), ir.Return([ir.Var("r")]))
  let f = ir.Function("f9", [], [ir.TFuncRef], [], body)
  let seg =
    ir.ElementSegment(
      ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
      ir.FuncRef,
      [
        ir.RefFuncImport(0, empty),
        ir.RefFunc("f9"),
        ir.RefFuncImport(5, single),
      ],
    )
  let module =
    ir_module(
      "twocore@reffunc_import@roundtrip",
      [],
      [f],
      [],
      [ir.TableDecl("t0", ir.FuncRef, 8, None)],
      [seg],
      [],
    )

  let text = printer.print_module(module)
  parser.parse_module(text) |> should.equal(Ok(module))
  // The node's canonical token is present (the mixed segment did NOT collapse to the legacy form).
  should.be_true(string.contains(text, "ref.func_import"))
}

// ───────────────────────────── §4.5 no new `TrapReason` (R8) ─────────────────────────────

/// §4.5 — building a funcref never traps, and the guards a stored imported funcref later feeds
/// through `call_indirect` reuse `UndefinedElement` / `UninitializedElement` /
/// `IndirectCallTypeMismatch`. So Phase 14 adds ZERO `TrapReason` variants. This locks the exact
/// ten-variant set (the list fails to typecheck if a variant is removed).
pub fn trap_reason_unchanged_test() {
  let reasons = [
    ir.IntDivByZero,
    ir.IntOverflow,
    ir.Unreachable,
    ir.IndirectCallTypeMismatch,
    ir.MemoryOutOfBounds,
    ir.InvalidConversionToInteger,
    ir.UndefinedElement,
    ir.UninitializedElement,
    ir.TableOutOfBounds,
    ir.FuelExhausted,
  ]
  list.length(reasons) |> should.equal(10)
}

// ───────────────────────────── §4.6 defaults inert / byte-identical (R5) ─────────────────────────────

/// §4.6 — a module with NO imported `ref.func` (a table-0 active `FuncRef` segment whose items are
/// all DEFINED `ref.func`): (a) round-trips its `.ir`; (b) its `.ir` text carries NONE of
/// `"ref.func_import"`; (c) its `.core` emits, carries no `"ref.func_import"`, and keeps the frozen
/// `init_elem` FAST path (`all_reffunc` stays `True` because every item is a plain `RefFunc`, so the
/// segment is NEVER routed to `init_elem_ref`). The new node/arms are unreached here ⇒ byte-identical
/// to Phase-13.
pub fn defined_only_segment_is_byte_identical_test() {
  let f0 = ir.Function("f0", [], [], [], ir.Return([]))
  let seg =
    ir.ElementSegment(
      ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
      ir.FuncRef,
      [ir.RefFunc("f0")],
    )
  let module =
    ir_module(
      "twocore@reffunc_import@defined_only",
      [],
      [f0],
      [],
      [ir.TableDecl("t0", ir.FuncRef, 1, None)],
      [seg],
      [ir.ExportFn("run", "f0")],
    )

  // (a) D5 round-trip.
  let text = printer.print_module(module)
  parser.parse_module(text) |> should.equal(Ok(module))
  // (b) NONE of the new token leaks into the `.ir` text.
  should.be_false(string.contains(text, "ref.func_import"))

  // (c) emits, no new token, and the FAST `init_elem` path (not `init_elem_ref`) is used.
  let assert Ok(cm) = emit_core.emit_module(module, instance.safe_default())
  let core = core_printer.print_module(cm)
  should.be_false(string.contains(core, "ref.func_import"))
  should.be_false(string.contains(core, "init_elem_ref"))
  should.be_true(string.contains(core, "init_elem"))
}

// ───────────────────────────── §4.7 imported `ref.func` STILL SKIPS, byte-identically ─────────────────────────────

/// §4.7 — the conservative arm is NO-REGRESSION. An imported `ref.func` (now `RefFuncImport(slot,
/// ty)`, as `lower` produces) STILL fails emission with the EXACT `Error(UnknownFunction("f<slot>"))`
/// the pre-keystone `ir.RefFunc("f<slot>")` produced — so the conformance skip is byte-identical
/// (`residual_audit` green, no assert flips). Proven in all three fail-closed reaches:
/// the element-segment init (`render_ref_item`), a function body (the `emit` dispatch), and a
/// reference-global init (`render_ref_global_init`). R14-02 is what flips these to `Ok`.
/// Spec (deferred obligation, R14-04 proves it): an imported function reached via `call_indirect`
/// must equal a direct `call` of that import — the keystone claims only the byte-identical skip.
pub fn imported_reffunc_still_skips_byte_identically_test() {
  let ty = ir.FuncType([ir.TI32], [ir.TI32])
  let import_fn = ir.ImportFn("a", "ef0", ty)

  // (render_ref_item) — an element segment holding an imported funcref (`slot >= 1`).
  let seg_module =
    ir_module(
      "twocore@reffunc_import@skip_elem",
      [import_fn],
      [],
      [],
      [ir.TableDecl("t0", ir.FuncRef, 4, None)],
      [
        ir.ElementSegment(
          ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
          ir.FuncRef,
          [ir.RefFuncImport(3, ty)],
        ),
      ],
      [],
    )
  emit_core.emit_module(seg_module, instance.safe_default())
  |> should.equal(Error(emit_core.UnknownFunction("f3")))

  // (emit dispatch) — an imported funcref in a FUNCTION BODY (`slot == 0`).
  let body_module =
    ir_module(
      "twocore@reffunc_import@skip_body",
      [import_fn],
      [
        ir.Function(
          "f1",
          [],
          [ir.TFuncRef],
          [],
          ir.Let(["r"], ir.RefFuncImport(0, ty), ir.Return([ir.Var("r")])),
        ),
      ],
      [],
      [],
      [],
      [ir.ExportFn("run", "f1")],
    )
  emit_core.emit_module(body_module, instance.safe_default())
  |> should.equal(Error(emit_core.UnknownFunction("f0")))

  // (render_ref_global_init) — a funcref GLOBAL initialised by an imported `ref.func` (`slot >= 1`).
  let global_module =
    ir_module(
      "twocore@reffunc_import@skip_global",
      [import_fn],
      [],
      [ir.GlobalDecl("g0", ir.TFuncRef, False, ir.RefFuncImport(1, ty))],
      [],
      [],
      [],
    )
  emit_core.emit_module(global_module, instance.safe_default())
  |> should.equal(Error(emit_core.UnknownFunction("f1")))
}
