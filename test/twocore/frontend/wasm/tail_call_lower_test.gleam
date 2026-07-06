//// Q13-04 — spec-cited tests for the real bottom-transfer lowering of `return_call`
//// (`ast.ReturnCall`) and `return_call_indirect` (`ast.ReturnCallIndirect`) in
//// `twocore/frontend/wasm/lower`.
////
//// **Spec basis** (WebAssembly tail-call proposal — write against this, NOT against emitted
//// text): `return_call` / `return_call_indirect` *replace the current call frame* with a call
//// to the callee, are *stack-polymorphic* (the rest of the block is unreachable, exactly like
//// `return`), and `return_call_indirect`'s traps are identical to `call_indirect`. So `lower`
//// must (a) produce the correct **leaf bottom-transfer node**, (b) **drop the dead
//// continuation**, (c) split **import vs defined** correctly, and (d) route the indirect case
//// through the **structural type + index value only** (no funcidx, no `apply`).
////
//// **Harness (self-contained):** each test builds a `validate.TypedModule` DIRECTLY (bypassing
//// `validate.validate`, whose `return_call*` arm is still the Q13-03 keystone placeholder while
//// Q13-03 and Q13-04 run in parallel) and calls `lower.lower`, then inspects the target
//// function's body with local `all_exprs` / `func` copies. The bottom-transfer nodes are leaves,
//// so `all_exprs`'s default arm keeps them and a membership check finds them. This mirrors the
//// existing `throw_unknown_tag_fails_closed_test` idiom in `lower_test.gleam`.

import gleam/list
import gleam/option
import gleam/set
import gleeunit/should
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/lower
import twocore/frontend/wasm/validate
import twocore/ir

// ───────────────────────────── local inspection helpers ─────────────────────────────

/// Every expression node in `e`'s tree (itself plus all nested sub-expressions). The three
/// tail-call nodes are LEAVES (they carry only `Value` operands), so they land in the default
/// arm and a membership check over `all_exprs(body)` finds the bottom-transfer node.
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

/// The operand `Value`s directly carried by a call / transfer / values node (args, an indirect
/// index, or returned values). Enough to prove a dead operand did NOT survive lowering — since a
/// dropped continuation never produces the `Value` for its constants.
fn node_values(e: ir.Expr) -> List(ir.Value) {
  case e {
    ir.ReturnCall(_, args) -> args
    ir.ReturnCallImport(_, _, args) -> args
    ir.ReturnCallIndirect(_, index, _, args) -> [index, ..args]
    ir.CallDirect(_, args) -> args
    ir.CallIndirect(_, index, _, args) -> [index, ..args]
    ir.CallImport(_, _, args) -> args
    ir.Return(vals) -> vals
    ir.Values(vals) -> vals
    _ -> []
  }
}

/// Every operand `Value` reachable from `body` (via `node_values` over the whole expr tree).
fn all_values(body: ir.Expr) -> List(ir.Value) {
  list.flat_map(all_exprs(body), node_values)
}

/// True iff `e` is one of the three tail-call bottom-transfer nodes.
fn is_tail_node(e: ir.Expr) -> Bool {
  case e {
    ir.ReturnCall(_, _) -> True
    ir.ReturnCallIndirect(_, _, _, _) -> True
    ir.ReturnCallImport(_, _, _) -> True
    _ -> False
  }
}

/// True iff `body` contains a direct-`CallDirect` node OR a `Let` binding one — i.e. the WRONG
/// `Call` shape (bind results + splice a live continuation) that `lower_call` uses. `lower` of a
/// `return_call` must NOT produce this (the `Return`-shape discriminator).
fn has_call_direct_shape(body: ir.Expr) -> Bool {
  list.any(all_exprs(body), fn(e) {
    case e {
      ir.CallDirect(_, _) -> True
      ir.Let(_, ir.CallDirect(_, _), _) -> True
      _ -> False
    }
  })
}

/// True iff `body` contains a `CallIndirect` node OR a `Let` binding one (the wrong `Call` shape
/// for the indirect case).
fn has_call_indirect_shape(body: ir.Expr) -> Bool {
  list.any(all_exprs(body), fn(e) {
    case e {
      ir.CallIndirect(_, _, _, _) -> True
      ir.Let(_, ir.CallIndirect(_, _, _, _), _) -> True
      _ -> False
    }
  })
}

/// True iff `body` contains any same-module `ir.ReturnCall(name, _)` node.
fn has_return_call_named(body: ir.Expr) -> Bool {
  list.any(all_exprs(body), fn(e) {
    case e {
      ir.ReturnCall(_, _) -> True
      _ -> False
    }
  })
}

/// True iff `body` contains any `ir.ReturnCallImport(...)` node.
fn has_return_call_import(body: ir.Expr) -> Bool {
  list.any(all_exprs(body), fn(e) {
    case e {
      ir.ReturnCallImport(_, _, _) -> True
      _ -> False
    }
  })
}

// ───────────────────────────── fixture builders ─────────────────────────────

/// The `(i32) -> (i32)` function type, the common shape across the direct fixtures.
fn t_i32_i32() -> ast.FuncType {
  ast.FuncType([ast.I32], [ast.I32])
}

/// Build a `validate.TypedModule` directly, bypassing `validate.validate` (§2). Only the fields
/// `lower` reads for tail-call lowering are meaningful: `types` (indirect `sig`), `func_types`
/// (direct `sig`, indexed by absolute funcidx), `imported_func_count` (the import split), `funcs`
/// + `func_locals` (the defined functions and their `params ++ declared` local types). Everything
/// else is empty/zero — indirect lowering reads NO table state (only `ctx.types` + the popped
/// index), so `table_types: []` is fine.
fn typed_module(
  imported: Int,
  types: List(ast.FuncType),
  imports: List(ast.Import),
  func_types: List(ast.FuncType),
  func_locals: List(List(ast.ValType)),
  funcs: List(ast.Func),
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
      elements: [],
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

// ───────────────────────────── §5.1 direct self tail call ─────────────────────────────

/// §5.1 — a direct self `return_call 0` in an `f0 : (i32) -> (i32)` (no imports) lowers to the
/// EXACT `ir.ReturnCall("f0", [Var("p0")])` bottom node: funcidx 0 is not `< 0`, so the defined
/// arm fires; the single param is the arg.
pub fn direct_self_tail_call_exact_node_test() {
  let t = t_i32_i32()
  let tm =
    typed_module(0, [t], [], [t], [[ast.I32]], [
      ast.Func(0, [], [ast.LocalGet(0), ast.ReturnCall(0), ast.End]),
    ])
  let irm = lower_ok(tm)
  all_exprs(func(irm, "f0").body)
  |> list.contains(ir.ReturnCall("f0", [ir.Var("p0")]))
  |> should.equal(True)
}

// ───────────────────────────── §5.2 dead continuation dropped ─────────────────────────────

/// §5.2 — the load-bearing `Return`-shape discriminator (Q4). After a `return_call` the rest of
/// the block is UNREACHABLE (stack-polymorphic, like `return`), so lower must DROP it. Body
/// `[LocalGet(0), ReturnCall(0), I32Const(999), LocalGet(0), End]`:
/// - the `ir.ReturnCall("f0", [Var("p0")])` bottom node is present;
/// - the dead tail's constant `999` produces NO `ir.ConstI32(999)` anywhere (`consume_dead`
///   skipped it — proof the continuation was dropped, not lowered);
/// - NO `ir.CallDirect` / `ir.Let(_, ir.CallDirect, _)` (the wrong `Call` shape — bind results +
///   splice a live continuation — was NOT used).
pub fn direct_tail_call_dead_continuation_dropped_test() {
  let t = t_i32_i32()
  let tm =
    typed_module(0, [t], [], [t], [[ast.I32]], [
      ast.Func(0, [], [
        ast.LocalGet(0),
        ast.ReturnCall(0),
        ast.I32Const(999),
        ast.LocalGet(0),
        ast.End,
      ]),
    ])
  let body = func(lower_ok(tm), "f0").body

  all_exprs(body)
  |> list.contains(ir.ReturnCall("f0", [ir.Var("p0")]))
  |> should.equal(True)

  all_values(body)
  |> list.contains(ir.ConstI32(999))
  |> should.equal(False)

  has_call_direct_shape(body)
  |> should.equal(False)
}

// ───────────────────────────── §5.3 / §5.4 import-vs-defined split ─────────────────────────────

/// The shared 2-import + 2-defined fixture for §5.3/§5.4. Imports occupy funcidx `0,1`
/// (`ImportFunc`, both `(i32) -> (i32)`); defined `f2` (funcidx 2) tail-calls the IMPORT at
/// funcidx 0; defined `f3` (funcidx 3) tail-calls the DEFINED function at funcidx 2.
/// `func_types` is indexed by absolute funcidx (imports first), all `(i32) -> (i32)`.
fn import_split_module() -> validate.TypedModule {
  let t = t_i32_i32()
  typed_module(
    2,
    [t],
    [
      ast.Import("env", "imp0", ast.ImportFunc(0)),
      ast.Import("env", "imp1", ast.ImportFunc(0)),
    ],
    [t, t, t, t],
    [[ast.I32], [ast.I32]],
    [
      ast.Func(0, [], [ast.LocalGet(0), ast.ReturnCall(0), ast.End]),
      ast.Func(0, [], [ast.LocalGet(0), ast.ReturnCall(2), ast.End]),
    ],
  )
}

/// §5.3 — a `return_call` to an IMPORTED callee (funcidx `0 < imported = 2`) lowers to
/// `ir.ReturnCallImport(0, FuncType([TI32], [TI32]), [Var("p0")])` — slot = the import's
/// positional index, `ty` = the import's IR signature — and to NO same-module `ir.ReturnCall`.
pub fn import_split_imported_callee_test() {
  let body = func(lower_ok(import_split_module()), "f2").body

  all_exprs(body)
  |> list.contains(
    ir.ReturnCallImport(0, ir.FuncType([ir.TI32], [ir.TI32]), [ir.Var("p0")]),
  )
  |> should.equal(True)

  has_return_call_named(body)
  |> should.equal(False)
}

/// §5.4 — a `return_call` to a DEFINED callee (funcidx `2 >= imported = 2`) lowers to
/// `ir.ReturnCall("f2", [Var("p0")])` (name `"f<idx>"`) and to NO `ir.ReturnCallImport`.
pub fn import_split_defined_callee_test() {
  let body = func(lower_ok(import_split_module()), "f3").body

  all_exprs(body)
  |> list.contains(ir.ReturnCall("f2", [ir.Var("p0")]))
  |> should.equal(True)

  has_return_call_import(body)
  |> should.equal(False)
}

// ───────────────────────────── §5.5 / §5.6 indirect ─────────────────────────────

/// §5.5 — `return_call_indirect (type 0) 0` lowers to the EXACT
/// `ir.ReturnCallIndirect("t0", ConstI32(7), FuncType([TI32], [TI32]), [Var("p0")])`, proving:
/// the table name is `"t0"` (`tname(0)`); the popped INDEX is the top-of-stack value `7`; the
/// ARGS are the params beneath it; the `ty` is the STRUCTURAL `module.types[0]`. Lower carries no
/// funcidx and no `apply` — dispatch stays the runtime's job.
pub fn indirect_tail_call_exact_node_test() {
  let t = t_i32_i32()
  let tm =
    typed_module(0, [t], [], [t], [[ast.I32]], [
      ast.Func(0, [], [
        ast.LocalGet(0),
        ast.I32Const(7),
        ast.ReturnCallIndirect(0, 0),
        ast.End,
      ]),
    ])
  all_exprs(func(lower_ok(tm), "f0").body)
  |> list.contains(
    ir.ReturnCallIndirect(
      "t0",
      ir.ConstI32(7),
      ir.FuncType([ir.TI32], [ir.TI32]),
      [ir.Var("p0")],
    ),
  )
  |> should.equal(True)
}

/// §5.6 — indirect twin of §5.2: the dead continuation is dropped and the `Call` shape is not
/// used. Body `[LocalGet(0), I32Const(7), ReturnCallIndirect(0, 0), I32Const(999), End]`:
/// the `ReturnCallIndirect` is present, no `ir.ConstI32(999)`, and no
/// `ir.CallIndirect` / `ir.Let(_, ir.CallIndirect, _)`.
pub fn indirect_tail_call_dead_continuation_dropped_test() {
  let t = t_i32_i32()
  let tm =
    typed_module(0, [t], [], [t], [[ast.I32]], [
      ast.Func(0, [], [
        ast.LocalGet(0),
        ast.I32Const(7),
        ast.ReturnCallIndirect(0, 0),
        ast.I32Const(999),
        ast.End,
      ]),
    ])
  let body = func(lower_ok(tm), "f0").body

  all_exprs(body)
  |> list.contains(
    ir.ReturnCallIndirect(
      "t0",
      ir.ConstI32(7),
      ir.FuncType([ir.TI32], [ir.TI32]),
      [ir.Var("p0")],
    ),
  )
  |> should.equal(True)

  all_values(body)
  |> list.contains(ir.ConstI32(999))
  |> should.equal(False)

  has_call_indirect_shape(body)
  |> should.equal(False)
}

// ───────────────────────────── §5.7 multi-arg operand order ─────────────────────────────

/// §5.7 — the anti-swap operand-order check. `f0 : (i32, i32) -> (i32, i32)`, body
/// `[LocalGet(0), LocalGet(1), ReturnCall(0), End]` → `ir.ReturnCall("f0", [Var("p0"),
/// Var("p1")])`: args in PUSH order (deepest-first), the same ordering `take_push_order` gives
/// `lower_call`. (Multi-result carries no extra obligation — results are the callee's, never
/// bound here.)
pub fn multi_arg_operand_order_test() {
  let t = ast.FuncType([ast.I32, ast.I32], [ast.I32, ast.I32])
  let tm =
    typed_module(0, [t], [], [t], [[ast.I32, ast.I32]], [
      ast.Func(0, [], [
        ast.LocalGet(0),
        ast.LocalGet(1),
        ast.ReturnCall(0),
        ast.End,
      ]),
    ])
  all_exprs(func(lower_ok(tm), "f0").body)
  |> list.contains(ir.ReturnCall("f0", [ir.Var("p0"), ir.Var("p1")]))
  |> should.equal(True)
}

// ───────────────────────────── §5.8–5.10 fail-closed (unvalidated-module insurance) ─────────────────────────────

/// §5.8 — an out-of-range funcidx in `return_call` (only reachable on an UNVALIDATED module)
/// fails closed with `Error(UnknownFuncIndex(9))`, never a panic. `ReturnCall(9)` with a length-1
/// `func_types`.
pub fn return_call_unknown_funcidx_fails_closed_test() {
  let t = ast.FuncType([], [])
  let tm =
    typed_module(0, [t], [], [t], [[]], [
      ast.Func(0, [], [ast.ReturnCall(9), ast.End]),
    ])
  lower.lower(tm)
  |> should.equal(Error(lower.UnknownFuncIndex(9)))
}

/// §5.9 — an out-of-range typeidx in `return_call_indirect` fails closed with
/// `Error(UnknownTypeIndex(9))`. `ReturnCallIndirect(9, 0)` with a length-1 `module.types`.
pub fn return_call_indirect_unknown_typeidx_fails_closed_test() {
  let t = ast.FuncType([], [])
  let tm =
    typed_module(0, [t], [], [t], [[]], [
      ast.Func(0, [], [ast.ReturnCallIndirect(9, 0), ast.End]),
    ])
  lower.lower(tm)
  |> should.equal(Error(lower.UnknownTypeIndex(9)))
}

/// §5.10a — a direct `return_call` whose callee needs 2 params but only 1 operand is on the stack
/// fails closed with `Error(StackUnderflow)`. `f0 : (i32) -> (i32)` tail-calls funcidx 1, whose
/// `func_types` signature has 2 params.
pub fn return_call_stack_underflow_fails_closed_test() {
  let one = t_i32_i32()
  let two = ast.FuncType([ast.I32, ast.I32], [ast.I32, ast.I32])
  let tm =
    typed_module(0, [one], [], [one, two], [[ast.I32]], [
      ast.Func(0, [], [ast.LocalGet(0), ast.ReturnCall(1), ast.End]),
    ])
  lower.lower(tm)
  |> should.equal(Error(lower.StackUnderflow))
}

/// §5.10b — the indirect twin: the i32 index is present but the params are short beneath it.
/// `ReturnCallIndirect(1, 0)` selects `module.types[1]` (2 params); the stack holds only the
/// index + one param → `Error(StackUnderflow)`.
pub fn return_call_indirect_stack_underflow_fails_closed_test() {
  let one = t_i32_i32()
  let two = ast.FuncType([ast.I32, ast.I32], [ast.I32, ast.I32])
  let tm =
    typed_module(0, [one, two], [], [one], [[ast.I32]], [
      ast.Func(0, [], [
        ast.LocalGet(0),
        ast.I32Const(0),
        ast.ReturnCallIndirect(1, 0),
        ast.End,
      ]),
    ])
  lower.lower(tm)
  |> should.equal(Error(lower.StackUnderflow))
}

// ───────────────────────────── §5.11 byte-identical default ─────────────────────────────

/// §5.11 — a module using NO `return_call*` reaches none of the new arms and produces none of the
/// three bottom-transfer nodes (the local encoding of Q6's byte-identical default). A plain
/// `(i32, i32) -> (i32)` add lowers with no `ir.ReturnCall` / `ir.ReturnCallIndirect` /
/// `ir.ReturnCallImport` anywhere.
pub fn no_tail_call_default_has_no_tail_nodes_test() {
  let t = ast.FuncType([ast.I32, ast.I32], [ast.I32])
  let tm =
    typed_module(0, [t], [], [t], [[ast.I32, ast.I32]], [
      ast.Func(0, [], [
        ast.LocalGet(0),
        ast.LocalGet(1),
        ast.I32Add,
        ast.End,
      ]),
    ])
  let irm = lower_ok(tm)
  all_module_exprs(irm)
  |> list.any(is_tail_node)
  |> should.equal(False)
}
