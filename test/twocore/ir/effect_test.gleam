//// Unit 02 — adversarial fixtures for the IR effect/purity classifier (`ir/effect`).
////
//// These are the "the classifier must NOT get this wrong" tests (§G). Each targets a specific
//// CATASTROPHIC misclassification: a false `Pure` verdict lets a downstream pass delete a
//// store, CSE a load across a write, hoist a trap above its guard, or drop a fuel charge —
//// silent memory corruption or a wrong answer.
////
//// Per D8 every assertion is against the SPEC/soundness requirement (E6; WASM §4.2 store
//// model, §4.3.2/§4.3.3 trapping arithmetic/conversion, §4.4.7 memory access), never against
//// whatever the current body happens to emit. The trapping-op partition is asserted against a
//// test-side reimplementation of the WASM spec rule (div/rem trap on `/0`; `trunc_s`/`trunc_u`
//// trap on NaN/±∞/out-of-range), not against `effect`'s private helpers — so a body that
//// silently narrowed a trap-bearer to `Pure` fails here.

import gleam/list
import twocore/ir
import twocore/ir/effect.{
  Effectful, Pure, can_cse, can_eliminate_if_unused, can_reorder, classify,
  function_is_pure, is_effectful_node, is_pure,
}

// ───────────────────────────── shared fixtures ─────────────────────────────

/// A representative side-effecting store: `i32.store` of `%v` at `%a + 0`.
fn a_store() -> ir.Expr {
  ir.MemStore(0, ir.MemAccess(4, False), ir.Var("a"), ir.Var("v"), 0)
}

/// A representative side-effecting load: `i32.load` at `%a + 0`.
fn a_load() -> ir.Expr {
  ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("a"), 0, ir.TI32)
}

/// A representative non-trapping, side-effect-free add.
fn a_pure_add() -> ir.Expr {
  ir.Num(ir.IAdd(ir.W32), [ir.Var("a"), ir.Var("b")])
}

// ─────────────────────── §G.1 — a store is never pure ───────────────────────

/// E6/WASM §4.4.7: `MemStore` writes mutable memory. It must be `Effectful` forever (this
/// pins the keystone freeze — the never-narrow direction). Both the SHALLOW node test and the
/// DEEP classifier must reject it.
pub fn store_is_never_pure_test() {
  assert is_effectful_node(a_store()) == True
  assert is_pure(a_store()) == False
  assert classify(a_store()) == Effectful
}

// ────────────────── §G.2 — a load is never pure / never CSE-able ──────────────────

/// E6/WASM §4.4.7: `MemLoad` reads mutable memory, so it is not pure and — a fortiori — never
/// shareable across ANY other expression (in particular never across a store). The classifier
/// forbids ALL load CSE in Phase 3 (the strongest form of "never CSE'd across a store").
pub fn load_is_never_pure_or_cse_test() {
  assert is_effectful_node(a_load()) == True
  assert is_pure(a_load()) == False
  assert can_cse(a_load()) == False
}

// ───────────── §G.3 — an effect with an unused result is not eliminable ─────────────

/// F3 ("no DCE of an effect"): even when its result is dead, a state write / host call / fuel
/// charge must be KEPT — E1's ordered `let _ = effect in …` sequencing is load-bearing. Every
/// barrier here must be non-eliminable.
pub fn effect_with_unused_result_not_eliminable_test() {
  assert can_eliminate_if_unused(a_store()) == False
  assert can_eliminate_if_unused(ir.GlobalSet("g", ir.Var("v"))) == False
  assert can_eliminate_if_unused(ir.CallHost("io", "print", [ir.Var("x")]))
    == False
  assert can_eliminate_if_unused(ir.Charge(3, ir.Values([]))) == False
}

// ──────────── §G.4 — a trapping div/rem/trunc is not pure, not eliminable ────────────

/// The §B.1 crux (WASM §4.3.2/§4.3.3): a trapping `div`/`rem`/`trunc` is referentially
/// transparent yet NOT inert — deleting it or hoisting it onto a new path adds/removes a trap
/// (an F2 observable). It must be `Effectful`, not pure, and never eliminable. `Trap` itself is
/// likewise a barrier.
pub fn trapping_div_rem_trunc_not_pure_test() {
  // div_s by a literal zero: still Effectful — the classifier never inspects operand values.
  assert is_pure(ir.Num(ir.IDivS(ir.W32), [ir.Var("a"), ir.ConstI32(0)]))
    == False
  assert can_eliminate_if_unused(
      ir.Num(ir.IDivU(ir.W32), [ir.Var("a"), ir.Var("b")]),
    )
    == False
  assert is_pure(ir.Num(ir.IRemS(ir.W64), [ir.Var("a"), ir.Var("b")])) == False
  assert is_pure(ir.Num(ir.IRemU(ir.W64), [ir.Var("a"), ir.Var("b")])) == False
  assert is_pure(ir.Convert(ir.TruncS(ir.FW64, ir.W32), ir.Var("x"))) == False
  assert is_pure(ir.Convert(ir.TruncU(ir.FW32, ir.W64), ir.Var("x"))) == False
  // and the trapping subsets are SHALLOW barriers too.
  assert is_effectful_node(ir.Num(ir.IDivS(ir.W32), [ir.Var("a"), ir.Var("b")]))
    == True
  assert is_effectful_node(ir.Convert(ir.TruncS(ir.FW64, ir.W32), ir.Var("x")))
    == True
}

// ───────────── §G.5 — non-trapping arithmetic IS pure (not vacuous) ─────────────

/// The analysis must be USEFUL, not vacuously conservative: total ops (arith, ALL float ops —
/// IEEE never traps — non-trapping conversions, value forwarding) are `Pure`, which is what
/// lets Baseline fold/CSE them. If these were `Effectful` the optimizer would be dead.
pub fn non_trapping_arithmetic_is_pure_test() {
  assert is_pure(a_pure_add()) == True
  assert is_pure(ir.Num(ir.FMul(ir.FW64), [ir.Var("a"), ir.Var("b")])) == True
  // f.div NEVER traps (IEEE: /0 → ±Inf/NaN), so it is pure unlike integer div.
  assert is_pure(ir.Num(ir.FDiv(ir.FW64), [ir.Var("a"), ir.Var("b")])) == True
  assert is_pure(ir.Convert(ir.I32WrapI64, ir.Var("x"))) == True
  // saturating truncation NEVER traps (distinct from the trapping TruncS/TruncU).
  assert is_pure(ir.Convert(ir.TruncSatS(ir.FW64, ir.W32), ir.Var("x"))) == True
  assert is_pure(ir.Values([ir.Var("a")])) == True
  assert is_pure(ir.TermOp(ir.MakeTuple, [ir.Var("a"), ir.Var("b")])) == True
  // a pure node is shareable and eliminable-if-unused (proves the predicates aren't
  // vacuously False).
  assert can_cse(a_pure_add()) == True
  assert can_eliminate_if_unused(a_pure_add()) == True
}

/// SPEC (Phase-8 K8, 02-closures.md §Effect): `MakeClosure` is `Pure` — building a `fun` over
/// already-evaluated `Value` captures reads/writes no state and cannot trap, so it is a
/// non-barrier and is shareable/eliminable (CSE/DCE/hoist OK, a fun literal is inert).
/// `CallClosure` is `Effectful` + a barrier — applying a fun VALUE transfers control to arbitrary
/// code (the same class as `CallIndirect`/`CallHost`/`CallImport`), so it is never CSE'd,
/// eliminated-if-unused, or reordered. A misclassification here (a false `Pure` on `CallClosure`)
/// would let a pass delete or hoist a call — silently wrong, which this test forbids.
pub fn closure_nodes_effect_classification_test() {
  let make = ir.MakeClosure("f", [ir.Var("c")], 1)
  let call = ir.CallClosure(ir.Var("g"), [ir.Var("x")])
  // MakeClosure: pure, non-barrier, shareable, eliminable-if-unused.
  assert is_effectful_node(make) == False
  assert classify(make) == Pure
  assert is_pure(make) == True
  assert can_cse(make) == True
  assert can_eliminate_if_unused(make) == True
  // CallClosure: effectful barrier — never pure/shareable/eliminable.
  assert is_effectful_node(call) == True
  assert classify(call) == Effectful
  assert is_pure(call) == False
  assert can_cse(call) == False
  assert can_eliminate_if_unused(call) == False
  // A pure MakeClosure commutes with the barrier call; two barriers do not reorder.
  assert can_reorder(make, call) == True
  assert can_reorder(call, call) == False
}

/// SPEC (Phase-8 K8, 03-objects-maps.md §Effect): ALL SIX `MapOp`s are `Pure` non-barriers — a
/// BEAM map is immutable, so construction, functional update, AND the reads read/write no shared
/// mutable state, never trap, and transfer no control (CSE/DCE/reorder are sound). Every variant
/// must be a non-barrier, classify `Pure`, and be shareable + eliminable-if-unused. A false
/// `Effectful` here would needlessly forbid the optimizer; a false `Pure` is impossible (maps are
/// immutable) — this pins the whole family as pure. Covers every `MapOp`, so it also proves the
/// classifier is TOTAL over `MapOp`.
pub fn map_nodes_effect_classification_test() {
  let ops = [
    ir.MapOp(ir.MapNew, []),
    ir.MapOp(ir.MapGet, [ir.Var("m"), ir.Var("k"), ir.Var("d")]),
    ir.MapOp(ir.MapPut, [ir.Var("m"), ir.Var("k"), ir.Var("v")]),
    ir.MapOp(ir.MapHas, [ir.Var("m"), ir.Var("k")]),
    ir.MapOp(ir.MapRemove, [ir.Var("m"), ir.Var("k")]),
    ir.MapOp(ir.MapSize, [ir.Var("m")]),
  ]
  list.each(ops, fn(e) {
    assert is_effectful_node(e) == False
    assert classify(e) == Pure
    assert is_pure(e) == True
    assert can_cse(e) == True
    assert can_eliminate_if_unused(e) == True
  })
  // A pure map op commutes with a barrier (either-side-pure ⇒ reorderable).
  assert can_reorder(ir.MapOp(ir.MapSize, [ir.Var("m")]), a_store()) == True
  assert can_reorder(a_store(), ir.MapOp(ir.MapNew, [])) == True
}

// ─────────────────── §G.6 — purity is DEEP, not shallow ───────────────────

/// A non-barrier SHELL (`Let`/`Block`/`If`/`Switch`) is `Pure` only when all its
/// sub-expressions are: a `Let` binding a load is NOT pure even though `Let` is not itself a
/// barrier. Conversely a shell over only-pure children IS pure. This is what the DEEP
/// `classify` recursion buys over the shallow node test.
pub fn purity_is_deep_test() {
  // a non-barrier shell hiding a load → Effectful.
  let let_over_load = ir.Let(["t"], a_load(), ir.Values([ir.Var("t")]))
  assert is_effectful_node(let_over_load) == False
  assert is_pure(let_over_load) == False

  // shells over only-pure children → Pure.
  let pure_let = ir.Let(["t"], a_pure_add(), ir.Values([ir.Var("t")]))
  let pure_if =
    ir.If(
      ir.Var("c"),
      [ir.TI32],
      ir.Values([ir.ConstI32(1)]),
      ir.Values([ir.ConstI32(0)]),
    )
  let pure_block = ir.Block("b", [ir.TI32], ir.Values([ir.ConstI32(1)]))
  let pure_switch =
    ir.Switch(
      ir.Var("s"),
      [ir.TI32],
      [ir.SwitchArm(0, ir.Values([ir.ConstI32(10)]))],
      ir.Values([ir.ConstI32(20)]),
    )
  assert is_pure(pure_let) == True
  assert is_pure(pure_if) == True
  assert is_pure(pure_block) == True
  assert is_pure(pure_switch) == True

  // an effect buried in ANY child position taints the shell.
  let if_with_effect_arm =
    ir.If(ir.Var("c"), [ir.TI32], ir.Values([ir.ConstI32(1)]), a_store())
  let switch_with_effect_default =
    ir.Switch(ir.Var("s"), [], [ir.SwitchArm(0, ir.Values([]))], a_store())
  let switch_with_effect_arm =
    ir.Switch(ir.Var("s"), [], [ir.SwitchArm(0, a_store())], ir.Values([]))
  assert is_pure(if_with_effect_arm) == False
  assert is_pure(switch_with_effect_default) == False
  assert is_pure(switch_with_effect_arm) == False
}

// ─────────────────── §G.7 — a Loop is never pure (divergence) ───────────────────

/// F2: divergence (non-termination) is observable. A `Loop` may not terminate, so it is never
/// `Pure` — even with an empty body — and therefore never eliminable/reorderable.
pub fn loop_is_never_pure_test() {
  let empty_loop = ir.Loop("l", [], [], ir.Values([]))
  assert is_effectful_node(empty_loop) == True
  assert is_pure(empty_loop) == False
  assert can_eliminate_if_unused(empty_loop) == False
}

// ─────────────────── §G.8 — control transfers are effectful ───────────────────

/// `Break`/`Continue`/`Return` transfer control and `Trap` aborts — none is eliminable or
/// reorderable, so none is `Pure`.
pub fn control_transfers_are_effectful_test() {
  assert is_pure(ir.Return([ir.Var("x")])) == False
  assert is_pure(ir.Break("b", [])) == False
  assert is_pure(ir.Continue("l", [])) == False
  assert is_pure(ir.Trap(ir.Unreachable)) == False
  assert is_effectful_node(ir.Return([ir.Var("x")])) == True
  assert is_effectful_node(ir.Trap(ir.Unreachable)) == True
}

// ─────────────── §G.9 — can_reorder respects barriers and is DEEP ───────────────

/// `can_reorder(a, b)` is `True` iff at least one side is DEEP-pure. Two barriers keep order;
/// a pure/anything pair may swap. Critically it uses the DEEP `is_pure`, not the shallow node
/// test: a `Block` HIDING a store is a non-barrier NODE yet must not reorder past a store.
pub fn can_reorder_respects_barriers_test() {
  // two stores never swap.
  assert can_reorder(a_store(), a_store()) == False
  // a Charge and another BARRIER never swap (two effectful nodes keep their order).
  assert can_reorder(ir.Charge(1, ir.Values([])), a_store()) == False
  assert can_reorder(a_store(), ir.Charge(1, ir.Values([]))) == False
  // a load and a store never swap.
  assert can_reorder(a_load(), a_store()) == False
  // a pure add commutes with a store (either side pure → True).
  assert can_reorder(a_pure_add(), a_store()) == True
  assert can_reorder(a_store(), a_pure_add()) == True
  // a pure op even commutes with a Charge: the pure side has no effect and consumes no fuel
  // (only Charge nodes account fuel), so at-least-one-pure ⇒ reorderable.
  assert can_reorder(ir.Charge(1, ir.Values([])), a_pure_add()) == True

  // DEEP: a Block whose body is a store must NOT reorder past another store, even though
  // is_effectful_node(Block) is False. This fails if can_reorder used the shallow node test.
  let block_hiding_store = ir.Block("b", [], a_store())
  assert is_effectful_node(block_hiding_store) == False
  assert can_reorder(block_hiding_store, a_store()) == False
  // a Block hiding only-pure work DOES reorder past a store.
  let block_pure = ir.Block("b", [], ir.Values([]))
  assert can_reorder(block_pure, a_store()) == True
}

// ─────────── §G.10 — function_is_pure is conservative; barriers stay barriers ───────────

/// A straight-line arithmetic body is pure. Any `CallDirect`/`Loop`/`MemLoad`/trapping op in
/// the body makes the function `Effectful` (conservative — it does not chase callees).
pub fn function_is_pure_conservative_test() {
  let pure_fn =
    ir.Function(
      name: "add",
      params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        ["r"],
        ir.Num(ir.IAdd(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
        ir.Values([ir.Var("r")]),
      ),
    )
  assert function_is_pure(pure_fn) == True

  // each of these bodies contains one barrier → function is not pure.
  let impure_bodies = [
    ir.CallDirect("g", [ir.Var("p0")]),
    ir.Loop("l", [], [], ir.Values([])),
    ir.Let(["x"], a_load(), ir.Values([ir.Var("x")])),
    ir.Num(ir.IDivS(ir.W32), [ir.Var("p0"), ir.Var("p0")]),
    a_store(),
  ]
  list.each(impure_bodies, fn(body) {
    let f =
      ir.Function(
        name: "f",
        params: [ir.Local("p0", ir.TI32)],
        result: [],
        locals: [],
        body: body,
      )
    assert function_is_pure(f) == False
  })
}

// ─────────────────── §G.10/11 — totality over every variant ───────────────────

/// Every integer `NumOp` at width `w`.
fn int_ops(w: ir.IntWidth) -> List(ir.NumOp) {
  [
    ir.IAdd(w),
    ir.ISub(w),
    ir.IMul(w),
    ir.IDivS(w),
    ir.IDivU(w),
    ir.IRemS(w),
    ir.IRemU(w),
    ir.IAnd(w),
    ir.IOr(w),
    ir.IXor(w),
    ir.IShl(w),
    ir.IShrS(w),
    ir.IShrU(w),
    ir.IRotl(w),
    ir.IRotr(w),
    ir.IClz(w),
    ir.ICtz(w),
    ir.IPopcnt(w),
    ir.IEqz(w),
    ir.IEq(w),
    ir.INe(w),
    ir.ILtS(w),
    ir.ILtU(w),
    ir.IGtS(w),
    ir.IGtU(w),
    ir.ILeS(w),
    ir.ILeU(w),
    ir.IGeS(w),
    ir.IGeU(w),
  ]
}

/// Every float `NumOp` at width `w`.
fn float_ops(w: ir.FloatWidth) -> List(ir.NumOp) {
  [
    ir.FAdd(w),
    ir.FSub(w),
    ir.FMul(w),
    ir.FDiv(w),
    ir.FMin(w),
    ir.FMax(w),
    ir.FAbs(w),
    ir.FNeg(w),
    ir.FCeil(w),
    ir.FFloor(w),
    ir.FTrunc(w),
    ir.FNearest(w),
    ir.FSqrt(w),
    ir.FCopysign(w),
    ir.FEq(w),
    ir.FNe(w),
    ir.FLt(w),
    ir.FGt(w),
    ir.FLe(w),
    ir.FGe(w),
  ]
}

/// Every `NumOp` constructor at both widths.
fn all_numops() -> List(ir.NumOp) {
  list.flatten([
    int_ops(ir.W32),
    int_ops(ir.W64),
    float_ops(ir.FW32),
    float_ops(ir.FW64),
  ])
}

/// Every `ConvOp` constructor.
fn all_convops() -> List(ir.ConvOp) {
  [
    ir.I32WrapI64,
    ir.I64ExtendI32S,
    ir.I64ExtendI32U,
    ir.I32Extend8S,
    ir.I32Extend16S,
    ir.I64Extend8S,
    ir.I64Extend16S,
    ir.I64Extend32S,
    ir.TruncSatS(ir.FW32, ir.W32),
    ir.TruncSatS(ir.FW64, ir.W64),
    ir.TruncSatU(ir.FW32, ir.W64),
    ir.TruncSatU(ir.FW64, ir.W32),
    ir.ReinterpretFToI(ir.FW32),
    ir.ReinterpretFToI(ir.FW64),
    ir.ReinterpretIToF(ir.W32),
    ir.ReinterpretIToF(ir.W64),
    ir.BoxInt(ir.W32),
    ir.UnboxInt(ir.W64),
    ir.BoxFloat(ir.FW32),
    ir.UnboxFloat(ir.FW64),
    ir.TruncS(ir.FW32, ir.W32),
    ir.TruncS(ir.FW64, ir.W64),
    ir.TruncU(ir.FW32, ir.W64),
    ir.TruncU(ir.FW64, ir.W32),
    ir.ConvertS(ir.W32, ir.FW32),
    ir.ConvertU(ir.W64, ir.FW64),
    ir.F32DemoteF64,
    ir.F64PromoteF32,
  ]
}

/// The WASM-spec (§4.3.2) trapping integer ops — `div`/`rem`, signed & unsigned — the ONLY
/// `NumOp`s that can trap. This is a test-side reimplementation of the spec rule, independent
/// of `effect`'s private `trapping_numop`, so the classifier is checked against the SPEC and a
/// silent narrowing of a trap-bearer to `Pure` fails.
fn spec_numop_traps(op: ir.NumOp) -> Bool {
  case op {
    ir.IDivS(_) | ir.IDivU(_) | ir.IRemS(_) | ir.IRemU(_) -> True
    _ -> False
  }
}

/// The WASM-spec (§4.3.3) trapping float→int truncations — `trunc_s`/`trunc_u` — the ONLY
/// `ConvOp`s that can trap (the saturating `trunc_sat_*` never do). Test-side reimplementation
/// of the spec rule (see `spec_numop_traps`).
fn spec_convop_traps(op: ir.ConvOp) -> Bool {
  case op {
    ir.TruncS(_, _) | ir.TruncU(_, _) -> True
    _ -> False
  }
}

/// SPEC PROPERTY: a `Num(op, _)` is `Pure` iff `op` is not a trapping div/rem (WASM §4.3.2).
/// Covers every `NumOp` at both widths, so it also proves the classifier is TOTAL over `NumOp`.
pub fn numop_pure_iff_not_trapping_test() {
  list.each(all_numops(), fn(op) {
    let e = ir.Num(op, [ir.Var("a"), ir.Var("b")])
    assert is_pure(e) == !spec_numop_traps(op)
    assert classify(e)
      == case spec_numop_traps(op) {
        True -> Effectful
        False -> Pure
      }
  })
}

/// SPEC PROPERTY: a `Convert(op, _)` is `Pure` iff `op` is not a trapping truncation (WASM
/// §4.3.3). Covers every `ConvOp`, proving totality over `ConvOp` — in particular the saturating
/// family, extends, reinterpret, convert, demote/promote, and the boxing bridge are all pure.
pub fn convop_pure_iff_not_trapping_test() {
  list.each(all_convops(), fn(op) {
    let e = ir.Convert(op, ir.Var("x"))
    assert is_pure(e) == !spec_convop_traps(op)
  })
}

/// A corpus touching EVERY `Expr` variant, for the totality proof (§G.11): reaching the end of
/// the iteration without a panic proves the `case`s in `classify`/`is_effectful_node` are total.
fn every_expr_variant() -> List(ir.Expr) {
  [
    ir.Values([ir.Var("a")]),
    a_pure_add(),
    ir.Num(ir.IDivS(ir.W32), [ir.Var("a"), ir.Var("b")]),
    ir.Convert(ir.I32WrapI64, ir.Var("x")),
    ir.Convert(ir.TruncS(ir.FW64, ir.W32), ir.Var("x")),
    ir.TermOp(ir.MakeTuple, [ir.Var("a")]),
    ir.MapOp(ir.MapPut, [ir.Var("m"), ir.Var("k"), ir.Var("v")]),
    ir.MemSize(0),
    ir.MemGrow(0, ir.ConstI32(1)),
    a_load(),
    a_store(),
    ir.GlobalGet("g"),
    ir.GlobalSet("g", ir.Var("v")),
    ir.CallDirect("foo", [ir.Var("a")]),
    ir.CallIndirect("t", ir.Var("i"), ir.FuncType([], []), []),
    ir.CallHost("env", "print", [ir.Var("a")]),
    ir.Let(["t"], ir.Values([ir.Var("a")]), ir.Values([ir.Var("t")])),
    ir.Block("b", [], ir.Values([])),
    ir.Loop("l", [], [], ir.Values([])),
    ir.If(ir.Var("c"), [], ir.Values([]), ir.Values([])),
    ir.Switch(ir.Var("s"), [], [ir.SwitchArm(0, ir.Values([]))], ir.Values([])),
    ir.Break("b", []),
    ir.Continue("l", []),
    ir.Return([ir.Var("x")]),
    ir.Trap(ir.Unreachable),
    ir.Charge(10, ir.Values([])),
  ]
}

/// SPEC PROPERTY (§G.1/11): the state ops, calls, `Charge`, `Trap`, transfers, and `Loop` are
/// SHALLOW barriers; `Values`/`TermOp`/non-trapping `Num`/`Convert`/shells are not — and
/// `classify` never panics on any variant (totality). This asserts the E6/F3 barrier set
/// membership directly, and the completion of the iteration is the totality proof.
pub fn classify_total_and_barrier_set_correct_test() {
  // completing this iteration without a panic proves classify is total over Expr.
  list.each(every_expr_variant(), fn(e) {
    assert is_pure(e) == { classify(e) == Pure }
  })

  // the E6/F3 SHALLOW barrier set is exactly these variants.
  let barriers = [
    ir.MemSize(0),
    ir.MemGrow(0, ir.ConstI32(1)),
    a_load(),
    a_store(),
    ir.GlobalGet("g"),
    ir.GlobalSet("g", ir.Var("v")),
    ir.CallDirect("foo", [ir.Var("a")]),
    ir.CallIndirect("t", ir.Var("i"), ir.FuncType([], []), []),
    ir.CallHost("env", "print", [ir.Var("a")]),
    ir.Charge(10, ir.Values([])),
    ir.Trap(ir.Unreachable),
    ir.Break("b", []),
    ir.Continue("l", []),
    ir.Return([ir.Var("x")]),
    ir.Loop("l", [], [], ir.Values([])),
  ]
  assert list.all(barriers, is_effectful_node)

  // the non-barrier SHELLS + atomics are not shallow barriers.
  let non_barriers = [
    ir.Values([ir.Var("a")]),
    a_pure_add(),
    ir.Convert(ir.I32WrapI64, ir.Var("x")),
    ir.TermOp(ir.MakeTuple, [ir.Var("a")]),
    ir.MapOp(ir.MapNew, []),
    ir.Let(["t"], ir.Values([ir.Var("a")]), ir.Values([ir.Var("t")])),
    ir.Block("b", [], ir.Values([])),
    ir.If(ir.Var("c"), [], ir.Values([]), ir.Values([])),
    ir.Switch(ir.Var("s"), [], [ir.SwitchArm(0, ir.Values([]))], ir.Values([])),
  ]
  assert list.all(non_barriers, fn(e) { !is_effectful_node(e) })
}
