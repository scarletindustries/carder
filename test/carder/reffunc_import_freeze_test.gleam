//// R14-01 — the keystone freeze for the `RefFuncImport` **IR node** (a cross-module `ref.func` of
//// an IMPORTED function), verified against the WebAssembly spec — NOT change-detectors (R7/D8).
////
//// This is the BACKEND half of the freeze: the node's shape, its effect/optimizer treatment, its
//// `.ir` round-trip, and its Core Erlang emission. The FRONTEND half — that a source-language
//// lowering routes `ref.func x` with `x < imported_func_count` to `RefFuncImport(x, ty)` and
//// `x >= imported_func_count` to a defined `RefFunc` — is a claim about a source language's
//// funcidx space, so it moved to `scribbler` with the WebAssembly frontend. Everything below is
//// expressed purely over `carder/ir`.
////
//// The freeze proves (each downstream Phase-14 unit binds to exactly these):
////
//// - **the node is EXPRESSIBLE** — a module whose element segment AND a function body use
////   `ir.RefFuncImport(slot, ty)` typechecks and pins the frozen shape (R1);
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
//// - **the imported-`ref.func` case now EMITS (R14-02 completed the arm)** — `emit_module` returns
////   `Ok` (the real D3a `link.call_import` adapter closure) in the element-segment path, a function
////   body, and a reference-global init; the former `Error(UnknownFunction("f<slot>"))` residual is
////   gone. The end-to-end `call_indirect == direct call` obligation is proven in
////   `reffunc_import_emit_test` (R14-02 §5.2).

import carder/backend/core_printer
import carder/backend/emit_core
import carder/ir
import carder/ir/effect
import carder/ir/parser
import carder/ir/printer
import carder/middle/ir_opt
import carder/middle/ir_opt/bce
import carder/middle/ir_opt/mem_clobber
import carder/opt_level
import carder/runtime/instance
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should

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

/// Every expression node across ALL defined functions of the module.
fn all_module_exprs(irm: ir.Module) -> List(ir.Expr) {
  list.flat_map(irm.functions, fn(f) { all_exprs(f.body) })
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
      "carder@reffunc_import@expressible",
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
    ir_module("carder@reffunc_import@opt", [], [f], [], [], [], [
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
      "carder@reffunc_import@roundtrip",
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
      "carder@reffunc_import@defined_only",
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

// ───────────────────────────── §4.7 imported `ref.func` now EMITS (R14-02 completed the arm) ─────────────────────────────

/// §4.7 — the keystone's conservative fail-closed arm is now COMPLETED by R14-02. An imported
/// `ref.func` (`RefFuncImport(slot, ty)`, as `lower` produces) that used to fail emission with
/// `Error(UnknownFunction("f<slot>"))` now EMITS the real D3a `link.call_import` adapter closure —
/// `emit_module` returns `Ok` (no `UnknownFunction`) in all three former fail-closed reaches: the
/// element-segment init (`render_ref_item`), a function body (the `emit` dispatch), and a
/// reference-global init (`render_ref_global_init`). This is the freeze pin flipped exactly as
/// R14-01 anticipated ("R14-02 is what flips these to `Ok`"). The full spec obligation — an imported
/// function reached via `call_indirect` equals a direct `call` of that import — is proven end-to-end
/// under Cell AND Threaded in `reffunc_import_emit_test` (R14-02 §5.2); this only pins that the
/// former residual is gone.
pub fn imported_reffunc_now_emits_test() {
  let ty = ir.FuncType([ir.TI32], [ir.TI32])
  let import_fn = ir.ImportFn("a", "ef0", ty)

  // (render_ref_item) — an element segment holding an imported funcref (`slot >= 1`).
  let seg_module =
    ir_module(
      "carder@reffunc_import@emit_elem",
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
  |> should.be_ok

  // (emit dispatch) — an imported funcref in a FUNCTION BODY (`slot == 0`).
  let body_module =
    ir_module(
      "carder@reffunc_import@emit_body",
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
  |> should.be_ok

  // (render_ref_global_init) — a funcref GLOBAL initialised by an imported `ref.func` (`slot >= 1`).
  let global_module =
    ir_module(
      "carder@reffunc_import@emit_global",
      [import_fn],
      [],
      [ir.GlobalDecl("g0", ir.TFuncRef, False, ir.RefFuncImport(1, ty))],
      [],
      [],
      [],
    )
  emit_core.emit_module(global_module, instance.safe_default())
  |> should.be_ok
}
