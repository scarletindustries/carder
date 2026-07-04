//// `middle/ir_opt/baseline` — the trust-neutral Baseline pass set (Phase-3 unit 03, F1/F2).
////
//// These seven passes run at BOTH `Baseline` and `Aggressive` (unit 04 appends its
//// Unsafe-only passes to `Aggressive`), so every one is sound **unconditionally** — there is
//// NO trust assumption anywhere. Each pass is a semantics-preserving IR→IR rewrite (F2):
//// `optimize(m, Baseline)` and `m` produce identical returned values (bit-for-bit, D7) and
//// identical traps.
////
//// ## The soundness story, pass by pass
////
//// - **const-fold** dispatches to `rt_num` (D2), the SAME numeric runtime `emit_core` calls, so
////   a folded constant is bit-identical to the run-time result *by construction* — including
////   two's-complement wrap, div/rem traps, shift masking, and the IEEE NaN/`-0.0` corners. A
////   constant *trapping* op folds to `Trap(reason)` (never a wrong value).
//// - **copy/const-prop** substitutes an atomic `Value` (a `Const*` or a `Var`) for a name whose
////   binding is `Values` — pure and reorder-free.
//// - **algebraic** rewrites only the provably-safe operand identities; float and `x/-1` hazards
////   are EXCLUDED (see `algebraic_num`).
//// - **const-`if`/`switch`** selects the taken arm; the discarded arm is statically unreached,
////   so dropping its effects is sound (F3).
//// - **block/label** is structural: it never drops or reorders an *executed* effect.
//// - **dead-code (DCE)** drops only the provably-unreached sequel of a divergent `rhs`.
//// - **dead-`let`** is the one pass gated on `ir/effect.is_pure` (F3): an effectful/trapping
////   binding is NEVER dropped, even when its result is unused.
////
//// ## Import hygiene (no cycle)
////
//// This module imports the pass machinery from `middle/ir_opt/pass` (a leaf that imports `ir`
//// only), NOT from `middle/ir_opt` — `ir_opt` imports THIS module, so importing it back would
//// cycle. The edges `baseline → {pass, ir, ir/effect, rt_num}` are all acyclic (`rt_num` and
//// `ir/effect` import only `ir`; nothing in the runtime imports the optimizer), so calling the
//// runtime for bit-exact folding is legal.

import gleam/list
import twocore/ir
import twocore/ir/effect
import twocore/middle/ir_opt/pass.{type Pass}
import twocore/runtime/rt_num

/// The ordered Baseline pass list (§I fixes the order + the termination argument). This is the
/// value `ir_opt.pipeline(Baseline)` returns; unit 04 prepends it to `Aggressive`
/// (`baseline_passes() ++ aggressive_passes()`, a strict superset — keystone A.2).
///
/// Order (one round): const-fold → copy/const-prop → algebraic → const-`if`/`switch` →
/// block/label → DCE → dead-`let`. Each pass feeds the next, and `run_pipeline` iterates the
/// whole list to a fixpoint over the lexicographic measure μ = (n_loops, n_ops, n_nodes,
/// n_vars) — every rewrite is non-increasing in μ and any *changing* rewrite strictly decreases
/// it, so convergence is reached well before `max_rounds`.
///
/// - Return: the seven `Pass` values in fixed order. Total — never fails.
pub fn baseline_passes() -> List(Pass) {
  [
    pass.pass("const-fold", const_fold_module),
    pass.per_function("copy-const-prop", propagate_and_drop),
    pass.per_expr("algebraic-identity", algebraic),
    pass.per_expr("const-if", const_condition),
    pass.per_function("block-label-simplify", block_simplify),
    pass.per_expr("dead-code", dce),
    pass.per_function("dead-let", dead_let),
  ]
}

// ─────────────────────────────── B. constant folding ───────────────────────────────

/// Constant-fold every `Num`/`Convert` with all-constant operands across every function body.
///
/// Applies `fold_node` bottom-up (via `map_expr`), so a fold that exposes a new constant deeper
/// in the tree is picked up on the pipeline's next round.
///
/// - `module`: the IR module to fold.
/// - Return: `module` with each foldable numeric/conversion site replaced by `Values([Const])`
///   (on success) or `Trap(reason)` (when the op traps on those exact constants). Total.
fn const_fold_module(module: ir.Module) -> ir.Module {
  ir.Module(
    ..module,
    functions: list.map(module.functions, fn(f) {
      ir.Function(..f, body: pass.map_expr(f.body, fold_node))
    }),
  )
}

/// Fold a single node if it is a constant `Num`/`Convert`; otherwise return it unchanged.
fn fold_node(e: ir.Expr) -> ir.Expr {
  case e {
    ir.Num(op, args) ->
      case fold_num(op, args) {
        Ok(folded) -> folded
        Error(Nil) -> e
      }
    ir.Convert(op, arg) ->
      case fold_conv(op, arg) {
        Ok(folded) -> folded
        Error(Nil) -> e
      }
    _ -> e
  }
}

/// Wrap a folded constant `Value` as a value-producing `Expr`.
fn ok_val(v: ir.Value) -> Result(ir.Expr, Nil) {
  Ok(ir.Values([v]))
}

/// The width-typed integer constant for raw `bits`.
fn const_int(w: ir.IntWidth, bits: Int) -> ir.Value {
  case w {
    ir.W32 -> ir.ConstI32(bits)
    ir.W64 -> ir.ConstI64(bits)
  }
}

/// Fold a TRAPPING integer result: `Ok(bits)` → `Values([Const])`, `Error(reason)` → the exact
/// `Trap(reason)` `rt_num` returned. Shared by `div`/`rem` and the trapping `trunc`s.
fn fold_trap_int(
  r: Result(Int, ir.TrapReason),
  w: ir.IntWidth,
) -> Result(ir.Expr, Nil) {
  case r {
    Ok(bits) -> ok_val(const_int(w, bits))
    Error(reason) -> Ok(ir.Trap(reason))
  }
}

/// Fold one `Num(op, args)` with all-constant operands. `Ok(expr')` when foldable (a
/// `Values([Const])`, or a `Trap` for a trapping op on those operands), `Error(Nil)` to leave
/// the node unchanged (a `Var` operand, wrong arity, or ill-typed operand kind).
///
/// Every arm dispatches to the exact `rt_num` function `emit_core` uses at run time, so the
/// fold is bit-identical to execution (D2/D7). Comparisons (and `eqz`) yield an `i32` truth
/// value; `clz`/`ctz`/`popcnt` yield the operand width. Per WASM exec/numerics.
fn fold_num(op: ir.NumOp, args: List(ir.Value)) -> Result(ir.Expr, Nil) {
  case op, args {
    // ── i32 total arithmetic / bitwise / shift / rotate → ConstI32 ──
    ir.IAdd(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_add(a, b)))
    ir.ISub(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_sub(a, b)))
    ir.IMul(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_mul(a, b)))
    ir.IAnd(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_and(a, b)))
    ir.IOr(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_or(a, b)))
    ir.IXor(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_xor(a, b)))
    ir.IShl(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_shl(a, b)))
    ir.IShrS(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_shr_s(a, b)))
    ir.IShrU(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_shr_u(a, b)))
    ir.IRotl(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_rotl(a, b)))
    ir.IRotr(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_rotr(a, b)))
    // ── i32 unary counts → ConstI32 ──
    ir.IClz(ir.W32), [ir.ConstI32(a)] -> ok_val(ir.ConstI32(rt_num.i32_clz(a)))
    ir.ICtz(ir.W32), [ir.ConstI32(a)] -> ok_val(ir.ConstI32(rt_num.i32_ctz(a)))
    ir.IPopcnt(ir.W32), [ir.ConstI32(a)] ->
      ok_val(ir.ConstI32(rt_num.i32_popcnt(a)))
    // ── i32 comparisons → ConstI32 truth ──
    ir.IEqz(ir.W32), [ir.ConstI32(a)] -> ok_val(ir.ConstI32(rt_num.i32_eqz(a)))
    ir.IEq(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_eq(a, b)))
    ir.INe(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_ne(a, b)))
    ir.ILtS(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_lt_s(a, b)))
    ir.ILtU(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_lt_u(a, b)))
    ir.IGtS(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_gt_s(a, b)))
    ir.IGtU(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_gt_u(a, b)))
    ir.ILeS(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_le_s(a, b)))
    ir.ILeU(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_le_u(a, b)))
    ir.IGeS(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_ge_s(a, b)))
    ir.IGeU(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      ok_val(ir.ConstI32(rt_num.i32_ge_u(a, b)))
    // ── i32 trapping div/rem → ConstI32 or Trap ──
    ir.IDivS(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      fold_trap_int(rt_num.i32_div_s(a, b), ir.W32)
    ir.IDivU(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      fold_trap_int(rt_num.i32_div_u(a, b), ir.W32)
    ir.IRemS(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      fold_trap_int(rt_num.i32_rem_s(a, b), ir.W32)
    ir.IRemU(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      fold_trap_int(rt_num.i32_rem_u(a, b), ir.W32)

    // ── i64 total arithmetic / bitwise / shift / rotate → ConstI64 ──
    ir.IAdd(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI64(rt_num.i64_add(a, b)))
    ir.ISub(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI64(rt_num.i64_sub(a, b)))
    ir.IMul(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI64(rt_num.i64_mul(a, b)))
    ir.IAnd(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI64(rt_num.i64_and(a, b)))
    ir.IOr(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI64(rt_num.i64_or(a, b)))
    ir.IXor(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI64(rt_num.i64_xor(a, b)))
    ir.IShl(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI64(rt_num.i64_shl(a, b)))
    ir.IShrS(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI64(rt_num.i64_shr_s(a, b)))
    ir.IShrU(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI64(rt_num.i64_shr_u(a, b)))
    ir.IRotl(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI64(rt_num.i64_rotl(a, b)))
    ir.IRotr(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI64(rt_num.i64_rotr(a, b)))
    // ── i64 unary counts → ConstI64 ──
    ir.IClz(ir.W64), [ir.ConstI64(a)] -> ok_val(ir.ConstI64(rt_num.i64_clz(a)))
    ir.ICtz(ir.W64), [ir.ConstI64(a)] -> ok_val(ir.ConstI64(rt_num.i64_ctz(a)))
    ir.IPopcnt(ir.W64), [ir.ConstI64(a)] ->
      ok_val(ir.ConstI64(rt_num.i64_popcnt(a)))
    // ── i64 comparisons → ConstI32 truth ──
    ir.IEqz(ir.W64), [ir.ConstI64(a)] -> ok_val(ir.ConstI32(rt_num.i64_eqz(a)))
    ir.IEq(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI32(rt_num.i64_eq(a, b)))
    ir.INe(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI32(rt_num.i64_ne(a, b)))
    ir.ILtS(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI32(rt_num.i64_lt_s(a, b)))
    ir.ILtU(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI32(rt_num.i64_lt_u(a, b)))
    ir.IGtS(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI32(rt_num.i64_gt_s(a, b)))
    ir.IGtU(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI32(rt_num.i64_gt_u(a, b)))
    ir.ILeS(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI32(rt_num.i64_le_s(a, b)))
    ir.ILeU(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI32(rt_num.i64_le_u(a, b)))
    ir.IGeS(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI32(rt_num.i64_ge_s(a, b)))
    ir.IGeU(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      ok_val(ir.ConstI32(rt_num.i64_ge_u(a, b)))
    // ── i64 trapping div/rem → ConstI64 or Trap ──
    ir.IDivS(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      fold_trap_int(rt_num.i64_div_s(a, b), ir.W64)
    ir.IDivU(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      fold_trap_int(rt_num.i64_div_u(a, b), ir.W64)
    ir.IRemS(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      fold_trap_int(rt_num.i64_rem_s(a, b), ir.W64)
    ir.IRemU(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      fold_trap_int(rt_num.i64_rem_u(a, b), ir.W64)

    // ── f32 binary / unary → ConstF32 (NaN/±0/±Inf handled inside rt_num) ──
    ir.FAdd(ir.FW32), [ir.ConstF32(a), ir.ConstF32(b)] ->
      ok_val(ir.ConstF32(rt_num.f32_add(a, b)))
    ir.FSub(ir.FW32), [ir.ConstF32(a), ir.ConstF32(b)] ->
      ok_val(ir.ConstF32(rt_num.f32_sub(a, b)))
    ir.FMul(ir.FW32), [ir.ConstF32(a), ir.ConstF32(b)] ->
      ok_val(ir.ConstF32(rt_num.f32_mul(a, b)))
    ir.FDiv(ir.FW32), [ir.ConstF32(a), ir.ConstF32(b)] ->
      ok_val(ir.ConstF32(rt_num.f32_div(a, b)))
    ir.FMin(ir.FW32), [ir.ConstF32(a), ir.ConstF32(b)] ->
      ok_val(ir.ConstF32(rt_num.f32_min(a, b)))
    ir.FMax(ir.FW32), [ir.ConstF32(a), ir.ConstF32(b)] ->
      ok_val(ir.ConstF32(rt_num.f32_max(a, b)))
    ir.FCopysign(ir.FW32), [ir.ConstF32(a), ir.ConstF32(b)] ->
      ok_val(ir.ConstF32(rt_num.f32_copysign(a, b)))
    ir.FAbs(ir.FW32), [ir.ConstF32(a)] -> ok_val(ir.ConstF32(rt_num.f32_abs(a)))
    ir.FNeg(ir.FW32), [ir.ConstF32(a)] -> ok_val(ir.ConstF32(rt_num.f32_neg(a)))
    ir.FCeil(ir.FW32), [ir.ConstF32(a)] ->
      ok_val(ir.ConstF32(rt_num.f32_ceil(a)))
    ir.FFloor(ir.FW32), [ir.ConstF32(a)] ->
      ok_val(ir.ConstF32(rt_num.f32_floor(a)))
    ir.FTrunc(ir.FW32), [ir.ConstF32(a)] ->
      ok_val(ir.ConstF32(rt_num.f32_trunc(a)))
    ir.FNearest(ir.FW32), [ir.ConstF32(a)] ->
      ok_val(ir.ConstF32(rt_num.f32_nearest(a)))
    ir.FSqrt(ir.FW32), [ir.ConstF32(a)] ->
      ok_val(ir.ConstF32(rt_num.f32_sqrt(a)))
    // ── f32 comparisons → ConstI32 truth ──
    ir.FEq(ir.FW32), [ir.ConstF32(a), ir.ConstF32(b)] ->
      ok_val(ir.ConstI32(rt_num.f32_eq(a, b)))
    ir.FNe(ir.FW32), [ir.ConstF32(a), ir.ConstF32(b)] ->
      ok_val(ir.ConstI32(rt_num.f32_ne(a, b)))
    ir.FLt(ir.FW32), [ir.ConstF32(a), ir.ConstF32(b)] ->
      ok_val(ir.ConstI32(rt_num.f32_lt(a, b)))
    ir.FGt(ir.FW32), [ir.ConstF32(a), ir.ConstF32(b)] ->
      ok_val(ir.ConstI32(rt_num.f32_gt(a, b)))
    ir.FLe(ir.FW32), [ir.ConstF32(a), ir.ConstF32(b)] ->
      ok_val(ir.ConstI32(rt_num.f32_le(a, b)))
    ir.FGe(ir.FW32), [ir.ConstF32(a), ir.ConstF32(b)] ->
      ok_val(ir.ConstI32(rt_num.f32_ge(a, b)))

    // ── f64 binary / unary → ConstF64 ──
    ir.FAdd(ir.FW64), [ir.ConstF64(a), ir.ConstF64(b)] ->
      ok_val(ir.ConstF64(rt_num.f64_add(a, b)))
    ir.FSub(ir.FW64), [ir.ConstF64(a), ir.ConstF64(b)] ->
      ok_val(ir.ConstF64(rt_num.f64_sub(a, b)))
    ir.FMul(ir.FW64), [ir.ConstF64(a), ir.ConstF64(b)] ->
      ok_val(ir.ConstF64(rt_num.f64_mul(a, b)))
    ir.FDiv(ir.FW64), [ir.ConstF64(a), ir.ConstF64(b)] ->
      ok_val(ir.ConstF64(rt_num.f64_div(a, b)))
    ir.FMin(ir.FW64), [ir.ConstF64(a), ir.ConstF64(b)] ->
      ok_val(ir.ConstF64(rt_num.f64_min(a, b)))
    ir.FMax(ir.FW64), [ir.ConstF64(a), ir.ConstF64(b)] ->
      ok_val(ir.ConstF64(rt_num.f64_max(a, b)))
    ir.FCopysign(ir.FW64), [ir.ConstF64(a), ir.ConstF64(b)] ->
      ok_val(ir.ConstF64(rt_num.f64_copysign(a, b)))
    ir.FAbs(ir.FW64), [ir.ConstF64(a)] -> ok_val(ir.ConstF64(rt_num.f64_abs(a)))
    ir.FNeg(ir.FW64), [ir.ConstF64(a)] -> ok_val(ir.ConstF64(rt_num.f64_neg(a)))
    ir.FCeil(ir.FW64), [ir.ConstF64(a)] ->
      ok_val(ir.ConstF64(rt_num.f64_ceil(a)))
    ir.FFloor(ir.FW64), [ir.ConstF64(a)] ->
      ok_val(ir.ConstF64(rt_num.f64_floor(a)))
    ir.FTrunc(ir.FW64), [ir.ConstF64(a)] ->
      ok_val(ir.ConstF64(rt_num.f64_trunc(a)))
    ir.FNearest(ir.FW64), [ir.ConstF64(a)] ->
      ok_val(ir.ConstF64(rt_num.f64_nearest(a)))
    ir.FSqrt(ir.FW64), [ir.ConstF64(a)] ->
      ok_val(ir.ConstF64(rt_num.f64_sqrt(a)))
    // ── f64 comparisons → ConstI32 truth ──
    ir.FEq(ir.FW64), [ir.ConstF64(a), ir.ConstF64(b)] ->
      ok_val(ir.ConstI32(rt_num.f64_eq(a, b)))
    ir.FNe(ir.FW64), [ir.ConstF64(a), ir.ConstF64(b)] ->
      ok_val(ir.ConstI32(rt_num.f64_ne(a, b)))
    ir.FLt(ir.FW64), [ir.ConstF64(a), ir.ConstF64(b)] ->
      ok_val(ir.ConstI32(rt_num.f64_lt(a, b)))
    ir.FGt(ir.FW64), [ir.ConstF64(a), ir.ConstF64(b)] ->
      ok_val(ir.ConstI32(rt_num.f64_gt(a, b)))
    ir.FLe(ir.FW64), [ir.ConstF64(a), ir.ConstF64(b)] ->
      ok_val(ir.ConstI32(rt_num.f64_le(a, b)))
    ir.FGe(ir.FW64), [ir.ConstF64(a), ir.ConstF64(b)] ->
      ok_val(ir.ConstI32(rt_num.f64_ge(a, b)))

    // A `Var` operand, wrong arity, or ill-typed operand kind: leave unfolded, never panic.
    _, _ -> Error(Nil)
  }
}

/// Fold one `Convert(op, arg)` with a constant operand. `Ok(expr')` when foldable, `Error(Nil)`
/// to leave unchanged. The four boxing ops (`BoxInt`/`UnboxInt`/`BoxFloat`/`UnboxFloat`) are NOT
/// foldable — there is no constant `Value` for a boxed `TTerm` — and fall through to `Error`.
/// Trapping `TruncS`/`TruncU` fold to `Trap` on `rt_num`'s `Error`. Per WASM exec/numerics.
fn fold_conv(op: ir.ConvOp, arg: ir.Value) -> Result(ir.Expr, Nil) {
  case op, arg {
    // width / sign changes within the integer layer
    ir.I32WrapI64, ir.ConstI64(a) -> ok_val(ir.ConstI32(rt_num.i32_wrap_i64(a)))
    ir.I64ExtendI32S, ir.ConstI32(a) ->
      ok_val(ir.ConstI64(rt_num.i64_extend_i32_s(a)))
    ir.I64ExtendI32U, ir.ConstI32(a) ->
      ok_val(ir.ConstI64(rt_num.i64_extend_i32_u(a)))
    ir.I32Extend8S, ir.ConstI32(a) ->
      ok_val(ir.ConstI32(rt_num.i32_extend8_s(a)))
    ir.I32Extend16S, ir.ConstI32(a) ->
      ok_val(ir.ConstI32(rt_num.i32_extend16_s(a)))
    ir.I64Extend8S, ir.ConstI64(a) ->
      ok_val(ir.ConstI64(rt_num.i64_extend8_s(a)))
    ir.I64Extend16S, ir.ConstI64(a) ->
      ok_val(ir.ConstI64(rt_num.i64_extend16_s(a)))
    ir.I64Extend32S, ir.ConstI64(a) ->
      ok_val(ir.ConstI64(rt_num.i64_extend32_s(a)))
    // reinterpret (bit-identity)
    ir.ReinterpretFToI(ir.FW32), ir.ConstF32(a) ->
      ok_val(ir.ConstI32(rt_num.i32_reinterpret_f32(a)))
    ir.ReinterpretFToI(ir.FW64), ir.ConstF64(a) ->
      ok_val(ir.ConstI64(rt_num.i64_reinterpret_f64(a)))
    ir.ReinterpretIToF(ir.W32), ir.ConstI32(a) ->
      ok_val(ir.ConstF32(rt_num.f32_reinterpret_i32(a)))
    ir.ReinterpretIToF(ir.W64), ir.ConstI64(a) ->
      ok_val(ir.ConstF64(rt_num.f64_reinterpret_i64(a)))
    // saturating float→int truncation (total)
    ir.TruncSatS(ir.FW32, ir.W32), ir.ConstF32(a) ->
      ok_val(ir.ConstI32(rt_num.i32_trunc_sat_f32_s(a)))
    ir.TruncSatS(ir.FW64, ir.W32), ir.ConstF64(a) ->
      ok_val(ir.ConstI32(rt_num.i32_trunc_sat_f64_s(a)))
    ir.TruncSatS(ir.FW32, ir.W64), ir.ConstF32(a) ->
      ok_val(ir.ConstI64(rt_num.i64_trunc_sat_f32_s(a)))
    ir.TruncSatS(ir.FW64, ir.W64), ir.ConstF64(a) ->
      ok_val(ir.ConstI64(rt_num.i64_trunc_sat_f64_s(a)))
    ir.TruncSatU(ir.FW32, ir.W32), ir.ConstF32(a) ->
      ok_val(ir.ConstI32(rt_num.i32_trunc_sat_f32_u(a)))
    ir.TruncSatU(ir.FW64, ir.W32), ir.ConstF64(a) ->
      ok_val(ir.ConstI32(rt_num.i32_trunc_sat_f64_u(a)))
    ir.TruncSatU(ir.FW32, ir.W64), ir.ConstF32(a) ->
      ok_val(ir.ConstI64(rt_num.i64_trunc_sat_f32_u(a)))
    ir.TruncSatU(ir.FW64, ir.W64), ir.ConstF64(a) ->
      ok_val(ir.ConstI64(rt_num.i64_trunc_sat_f64_u(a)))
    // TRAPPING float→int truncation → ConstI* or Trap
    ir.TruncS(ir.FW32, ir.W32), ir.ConstF32(a) ->
      fold_trap_int(rt_num.i32_trunc_f32_s(a), ir.W32)
    ir.TruncS(ir.FW64, ir.W32), ir.ConstF64(a) ->
      fold_trap_int(rt_num.i32_trunc_f64_s(a), ir.W32)
    ir.TruncS(ir.FW32, ir.W64), ir.ConstF32(a) ->
      fold_trap_int(rt_num.i64_trunc_f32_s(a), ir.W64)
    ir.TruncS(ir.FW64, ir.W64), ir.ConstF64(a) ->
      fold_trap_int(rt_num.i64_trunc_f64_s(a), ir.W64)
    ir.TruncU(ir.FW32, ir.W32), ir.ConstF32(a) ->
      fold_trap_int(rt_num.i32_trunc_f32_u(a), ir.W32)
    ir.TruncU(ir.FW64, ir.W32), ir.ConstF64(a) ->
      fold_trap_int(rt_num.i32_trunc_f64_u(a), ir.W32)
    ir.TruncU(ir.FW32, ir.W64), ir.ConstF32(a) ->
      fold_trap_int(rt_num.i64_trunc_f32_u(a), ir.W64)
    ir.TruncU(ir.FW64, ir.W64), ir.ConstF64(a) ->
      fold_trap_int(rt_num.i64_trunc_f64_u(a), ir.W64)
    // int→float conversion (total)
    ir.ConvertS(ir.W32, ir.FW32), ir.ConstI32(a) ->
      ok_val(ir.ConstF32(rt_num.f32_convert_i32_s(a)))
    ir.ConvertS(ir.W64, ir.FW32), ir.ConstI64(a) ->
      ok_val(ir.ConstF32(rt_num.f32_convert_i64_s(a)))
    ir.ConvertS(ir.W32, ir.FW64), ir.ConstI32(a) ->
      ok_val(ir.ConstF64(rt_num.f64_convert_i32_s(a)))
    ir.ConvertS(ir.W64, ir.FW64), ir.ConstI64(a) ->
      ok_val(ir.ConstF64(rt_num.f64_convert_i64_s(a)))
    ir.ConvertU(ir.W32, ir.FW32), ir.ConstI32(a) ->
      ok_val(ir.ConstF32(rt_num.f32_convert_i32_u(a)))
    ir.ConvertU(ir.W64, ir.FW32), ir.ConstI64(a) ->
      ok_val(ir.ConstF32(rt_num.f32_convert_i64_u(a)))
    ir.ConvertU(ir.W32, ir.FW64), ir.ConstI32(a) ->
      ok_val(ir.ConstF64(rt_num.f64_convert_i32_u(a)))
    ir.ConvertU(ir.W64, ir.FW64), ir.ConstI64(a) ->
      ok_val(ir.ConstF64(rt_num.f64_convert_i64_u(a)))
    // float width changes
    ir.F32DemoteF64, ir.ConstF64(a) ->
      ok_val(ir.ConstF32(rt_num.f32_demote_f64(a)))
    ir.F64PromoteF32, ir.ConstF32(a) ->
      ok_val(ir.ConstF64(rt_num.f64_promote_f32(a)))
    // boxing bridge (not foldable) + any ill-typed operand kind: leave unchanged.
    _, _ -> Error(Nil)
  }
}

// ─────────────────────────── C. copy / constant propagation ───────────────────────────

/// Copy/constant-propagate then drop, per function: a `Let(names, Values(vs), body)` (matching
/// arity) is replaced by `body` with each `name_i` substituted by the atomic `Value` `v_i`.
///
/// Substituting an atomic reference (`Const*` or `Var`) is value-exact under the unique-name /
/// per-iteration-SSA invariant (§C): a name denotes one value in its scope, so a substituted
/// `Var(y)` re-reads the same bits everywhere it is in scope. Only `Values` right-hand sides are
/// propagated; a computation `rhs` is left to dead-`let` (§D), never copied.
///
/// - `f`: the function to rewrite.
/// - Return: `f` with every `Values`-bound `Let` propagated and removed. Total.
fn propagate_and_drop(f: ir.Function) -> ir.Function {
  ir.Function(..f, body: pass.map_expr(f.body, prop_node))
}

/// Propagate + drop one node if it binds atomic `Values`; otherwise leave it unchanged.
fn prop_node(e: ir.Expr) -> ir.Expr {
  case e {
    ir.Let(names, ir.Values(vs), body) ->
      case list.length(names) == list.length(vs) {
        True -> subst_expr(body, list.zip(names, vs))
        False -> e
      }
    _ -> e
  }
}

// ───────────────────────────── D. dead-`let` elimination ─────────────────────────────

/// Dead-`let` elimination, per function — the F3 gate. A `Let(names, rhs, body)` is removed
/// (rewritten to `body`) only when (i) NO `name_i` occurs in `body` AND (ii)
/// `effect.is_pure(rhs)` holds.
///
/// Clause (ii) is the load-bearing safety boundary: a `rhs` that stores, writes a global, grows
/// memory, calls, charges fuel, or CAN TRAP (the trapping `Num`/`Convert` ops) is not pure and
/// is therefore NEVER dropped, even with an unused result — its `let _ = effect in …` sequencing
/// survives (E1/F3). Multi-name bindings are removed only when ALL names are dead.
///
/// - `f`: the function to rewrite.
/// - Return: `f` with pure, fully-dead bindings removed. Total.
fn dead_let(f: ir.Function) -> ir.Function {
  ir.Function(..f, body: pass.map_expr(f.body, dead_let_node))
}

/// Drop one `Let` when its bound names are all dead in `body` and its `rhs` is pure.
fn dead_let_node(e: ir.Expr) -> ir.Expr {
  case e {
    ir.Let(names, rhs, body) ->
      case !any_var_occurs(names, body) && effect.is_pure(rhs) {
        True -> body
        False -> e
      }
    _ -> e
  }
}

/// Does any name in `names` occur (as a `Var`) anywhere in `body`? Because names are unique per
/// function (no shadowing), any occurrence is a live use of that binding.
fn any_var_occurs(names: List(String), body: ir.Expr) -> Bool {
  let used = expr_vars(body)
  list.any(names, fn(n) { list.contains(used, n) })
}

// ─────────────────────── E. dead-code / unreachable elimination ───────────────────────

/// Dead-code elimination (per node). Drops the provably-unreached sequel of a non-returning
/// binding, and collapses an `If` whose two arms are the same trap.
///
/// 1. `Let(names, rhs, body)` with a NON-RETURNING `rhs` (`Trap`/`Return`/`Break`/`Continue`):
///    ANF evaluates `rhs` first and it diverts control, so `body` is unreachable → rewrite to
///    `rhs`. This does NOT violate F3 ("no DCE of an effect"): `body` is provably never reached,
///    so its (possibly effectful) contents — including any `Charge` — never run. The dominant
///    driver is const-fold's `Let(_, Trap(reason), _)`.
/// 2. `If(cond, _, Trap(x), Trap(x))` → `Trap(x)`: `cond` is an atomic `Value` (pure, no trap),
///    and both outcomes are the same divergence, so the branch is dead.
///
/// - `e`: the node to inspect.
/// - Return: the reduced node, or `e` unchanged. Total.
fn dce(e: ir.Expr) -> ir.Expr {
  case e {
    ir.Let(_, rhs, _) ->
      case is_non_returning(rhs) {
        True -> rhs
        False -> e
      }
    ir.If(_, _, ir.Trap(x), ir.Trap(y)) ->
      case x == y {
        True -> ir.Trap(x)
        False -> e
      }
    _ -> e
  }
}

/// Is `e` a non-returning control transfer (never falls through to a sequel)?
fn is_non_returning(e: ir.Expr) -> Bool {
  case e {
    ir.Trap(_) | ir.Return(_) | ir.Break(_, _) | ir.Continue(_, _) -> True
    _ -> False
  }
}

// ───────────────────────────── F. algebraic identities ─────────────────────────────

/// Algebraic identities (per node) — only the PROVABLY-SAFE set. Every operand is an atomic
/// `Value` (ANF), so reading it has no effect and cannot trap; the identities below are
/// therefore unconditional.
///
/// EXCLUDED as unsound (encoded as negative tests): `IDivS[x, -1]` (`INT_MIN/-1` overflow-traps
/// but a negation would not), ALL float arithmetic identities (`-0.0`/NaN corners — e.g.
/// `-0.0 + +0.0 = +0.0`, and any NaN operand canonicalizes), and float reflexive comparisons
/// (`NaN ≠ NaN`). Fold floats only when BOTH operands are constant (§B).
///
/// - `e`: the node to inspect.
/// - Return: the simplified node, or `e` unchanged. Total.
fn algebraic(e: ir.Expr) -> ir.Expr {
  case e {
    ir.Num(op, args) ->
      case algebraic_num(op, args) {
        Ok(rewritten) -> rewritten
        Error(Nil) -> e
      }
    _ -> e
  }
}

/// The safe integer identities. `Ok(expr')` when one fires, `Error(Nil)` to leave unchanged.
/// `4_294_967_295` / `18_446_744_073_709_551_615` are the all-ones (`2ⁿ−1`) patterns; note the
/// division-by-`-1` case is deliberately absent.
fn algebraic_num(op: ir.NumOp, args: List(ir.Value)) -> Result(ir.Expr, Nil) {
  case op, args {
    // ── additive/or/xor identity: x∘0 = x (commutative), and x−0 = x ──
    ir.IAdd(_), [x, ir.ConstI32(0)]
    | ir.IAdd(_), [ir.ConstI32(0), x]
    | ir.IAdd(_), [x, ir.ConstI64(0)]
    | ir.IAdd(_), [ir.ConstI64(0), x]
    | ir.IOr(_), [x, ir.ConstI32(0)]
    | ir.IOr(_), [ir.ConstI32(0), x]
    | ir.IOr(_), [x, ir.ConstI64(0)]
    | ir.IOr(_), [ir.ConstI64(0), x]
    | ir.IXor(_), [x, ir.ConstI32(0)]
    | ir.IXor(_), [ir.ConstI32(0), x]
    | ir.IXor(_), [x, ir.ConstI64(0)]
    | ir.IXor(_), [ir.ConstI64(0), x]
    | ir.ISub(_), [x, ir.ConstI32(0)]
    | ir.ISub(_), [x, ir.ConstI64(0)]
    | ir.IMul(_), [x, ir.ConstI32(1)]
    | ir.IMul(_), [ir.ConstI32(1), x]
    | ir.IMul(_), [x, ir.ConstI64(1)]
    | ir.IMul(_), [ir.ConstI64(1), x]
    | ir.IShl(_), [x, ir.ConstI32(0)]
    | ir.IShl(_), [x, ir.ConstI64(0)]
    | ir.IShrS(_), [x, ir.ConstI32(0)]
    | ir.IShrS(_), [x, ir.ConstI64(0)]
    | ir.IShrU(_), [x, ir.ConstI32(0)]
    | ir.IShrU(_), [x, ir.ConstI64(0)]
    | ir.IRotl(_), [x, ir.ConstI32(0)]
    | ir.IRotl(_), [x, ir.ConstI64(0)]
    | ir.IRotr(_), [x, ir.ConstI32(0)]
    | ir.IRotr(_), [x, ir.ConstI64(0)]
    | ir.IDivS(_), [x, ir.ConstI32(1)]
    | ir.IDivS(_), [x, ir.ConstI64(1)]
    | ir.IDivU(_), [x, ir.ConstI32(1)]
    | ir.IDivU(_), [x, ir.ConstI64(1)]
    | ir.IAnd(_), [x, ir.ConstI32(4_294_967_295)]
    | ir.IAnd(_), [ir.ConstI32(4_294_967_295), x]
    | ir.IAnd(_), [x, ir.ConstI64(18_446_744_073_709_551_615)]
    | ir.IAnd(_), [ir.ConstI64(18_446_744_073_709_551_615), x]
    -> Ok(ir.Values([x]))

    // ── x*0 = 0 and x&0 = 0 (width from the zero operand) ──
    ir.IMul(_), [_, ir.ConstI32(0)]
    | ir.IMul(_), [ir.ConstI32(0), _]
    | ir.IAnd(_), [_, ir.ConstI32(0)]
    | ir.IAnd(_), [ir.ConstI32(0), _]
    -> Ok(ir.Values([ir.ConstI32(0)]))
    ir.IMul(_), [_, ir.ConstI64(0)]
    | ir.IMul(_), [ir.ConstI64(0), _]
    | ir.IAnd(_), [_, ir.ConstI64(0)]
    | ir.IAnd(_), [ir.ConstI64(0), _]
    -> Ok(ir.Values([ir.ConstI64(0)]))

    // ── x | 2ⁿ−1 = 2ⁿ−1 ──
    ir.IOr(_), [_, ir.ConstI32(4_294_967_295)]
    | ir.IOr(_), [ir.ConstI32(4_294_967_295), _]
    -> Ok(ir.Values([ir.ConstI32(4_294_967_295)]))
    ir.IOr(_), [_, ir.ConstI64(18_446_744_073_709_551_615)]
    | ir.IOr(_), [ir.ConstI64(18_446_744_073_709_551_615), _]
    -> Ok(ir.Values([ir.ConstI64(18_446_744_073_709_551_615)]))

    // ── x % 1 = 0 (width from the divisor) ──
    ir.IRemS(_), [_, ir.ConstI32(1)] | ir.IRemU(_), [_, ir.ConstI32(1)] ->
      Ok(ir.Values([ir.ConstI32(0)]))
    ir.IRemS(_), [_, ir.ConstI64(1)] | ir.IRemU(_), [_, ir.ConstI64(1)] ->
      Ok(ir.Values([ir.ConstI64(0)]))

    // ── division / remainder by a literal 0 always traps IntDivByZero ──
    ir.IDivS(_), [_, ir.ConstI32(0)]
    | ir.IDivU(_), [_, ir.ConstI32(0)]
    | ir.IRemS(_), [_, ir.ConstI32(0)]
    | ir.IRemU(_), [_, ir.ConstI32(0)]
    | ir.IDivS(_), [_, ir.ConstI64(0)]
    | ir.IDivU(_), [_, ir.ConstI64(0)]
    | ir.IRemS(_), [_, ir.ConstI64(0)]
    | ir.IRemU(_), [_, ir.ConstI64(0)]
    -> Ok(ir.Trap(ir.IntDivByZero))

    // ── reflexive: x−x = 0, x^x = 0 (width-typed zero) ──
    ir.ISub(ir.W32), [a, b] if a == b -> Ok(ir.Values([ir.ConstI32(0)]))
    ir.IXor(ir.W32), [a, b] if a == b -> Ok(ir.Values([ir.ConstI32(0)]))
    ir.ISub(ir.W64), [a, b] if a == b -> Ok(ir.Values([ir.ConstI64(0)]))
    ir.IXor(ir.W64), [a, b] if a == b -> Ok(ir.Values([ir.ConstI64(0)]))

    // ── reflexive: x&x = x, x|x = x ──
    ir.IAnd(_), [a, b] if a == b -> Ok(ir.Values([a]))
    ir.IOr(_), [a, b] if a == b -> Ok(ir.Values([a]))

    // ── reflexive integer comparisons → i32 truth ──
    ir.IEq(_), [a, b] if a == b -> Ok(ir.Values([ir.ConstI32(1)]))
    ir.INe(_), [a, b] if a == b -> Ok(ir.Values([ir.ConstI32(0)]))
    ir.ILtS(_), [a, b] if a == b -> Ok(ir.Values([ir.ConstI32(0)]))
    ir.ILtU(_), [a, b] if a == b -> Ok(ir.Values([ir.ConstI32(0)]))
    ir.IGtS(_), [a, b] if a == b -> Ok(ir.Values([ir.ConstI32(0)]))
    ir.IGtU(_), [a, b] if a == b -> Ok(ir.Values([ir.ConstI32(0)]))
    ir.ILeS(_), [a, b] if a == b -> Ok(ir.Values([ir.ConstI32(1)]))
    ir.ILeU(_), [a, b] if a == b -> Ok(ir.Values([ir.ConstI32(1)]))
    ir.IGeS(_), [a, b] if a == b -> Ok(ir.Values([ir.ConstI32(1)]))
    ir.IGeU(_), [a, b] if a == b -> Ok(ir.Values([ir.ConstI32(1)]))

    _, _ -> Error(Nil)
  }
}

// ─────────────────────── H. constant-condition `if` / `switch` ───────────────────────

/// Constant-condition selection (per node). An `If` with a constant `i32` condition, or a
/// `Switch` with a constant selector, is replaced by the single arm that runs at run time; the
/// not-taken arm is STATICALLY UNREACHED, so discarding its effects is sound (F3, §H). A `Var`
/// condition/selector is left untouched (const-prop is what turns it into a literal first).
///
/// - `e`: the node to inspect.
/// - Return: the selected arm, or `e` unchanged. Total.
fn const_condition(e: ir.Expr) -> ir.Expr {
  case e {
    // `emit_core` lowers `If` to `case cond { 0 -> else; _ -> then }` (i32 truth, tested ≠ 0).
    ir.If(ir.ConstI32(n), _, then_branch, else_branch) ->
      case n != 0 {
        True -> then_branch
        False -> else_branch
      }
    // `emit_core` lowers `Switch` to `case selector { match -> body; _ -> default }`.
    ir.Switch(ir.ConstI32(k), _, arms, default) -> select_arm(k, arms, default)
    ir.Switch(ir.ConstI64(k), _, arms, default) -> select_arm(k, arms, default)
    _ -> e
  }
}

/// Pick the body of the first arm whose `match` equals the constant selector `k`, else the
/// `default` (mirroring the run-time `case`'s first-match semantics).
fn select_arm(k: Int, arms: List(ir.SwitchArm), default: ir.Expr) -> ir.Expr {
  case list.find(arms, fn(a) { a.match == k }) {
    Ok(arm) -> arm.body
    Error(Nil) -> default
  }
}

// ───────────────────────────── G. block / label simplification ─────────────────────────────

/// Block/label simplification, per function (D6 — labels are unique per function, so a "does
/// `Break`/`Continue` to this label occur" scan is exact). Three structural rewrites, none of
/// which drops or reorders an EXECUTED effect (the body is preserved verbatim or replaced by the
/// values it would have produced):
///
/// 1. Tail-break peephole: `Block(l, _, Break(l, vs))` → `Values(vs)`.
/// 2. Transparent-block merge: `Block(l, _, body)` with NO `Break(l, _)` in `body` → `body`.
/// 3. Non-iterating loop → block: `Loop(l, params, result, body)` with NO `Continue(l, _)` runs
///    once — bind each param to its `init` and wrap `body` in a block carrying `l`. This is the
///    sole baseline rewrite that touches a `Loop`, and it strictly REMOVES one (μ's most-
///    significant component `n_loops` ↓), so it can never be undone.
///
/// - `f`: the function to rewrite.
/// - Return: `f` with blocks/loops simplified. Total.
fn block_simplify(f: ir.Function) -> ir.Function {
  ir.Function(..f, body: pass.map_expr(f.body, block_rewrite))
}

/// Apply the three block/label rewrites to one node; leave any other node unchanged.
fn block_rewrite(e: ir.Expr) -> ir.Expr {
  case e {
    ir.Block(label, _, ir.Break(bl, vs)) if bl == label -> ir.Values(vs)
    ir.Block(label, _, body) ->
      case breaks_to(label, body) {
        True -> e
        False -> body
      }
    ir.Loop(label, params, result, body) ->
      case continues_to(label, body) {
        True -> e
        False -> deloop(label, params, result, body)
      }
    _ -> e
  }
}

/// De-loop a non-iterating loop: bind each param to its `init`, then run `body` once inside a
/// block carrying the loop label (so a `Break(l, vs)` in `body` still exits with `vs`). An empty
/// param list skips the (degenerate) binding.
fn deloop(
  label: String,
  params: List(ir.LoopParam),
  result: List(ir.ValType),
  body: ir.Expr,
) -> ir.Expr {
  case params {
    [] -> ir.Block(label, result, body)
    _ -> {
      let names = list.map(params, fn(p) { p.name })
      let inits = list.map(params, fn(p) { p.init })
      ir.Let(names, ir.Values(inits), ir.Block(label, result, body))
    }
  }
}

/// Does a `Break(label, _)` occur anywhere in `e`? Scans the whole subtree (a break names its
/// target by label, D6, so a nested `Break(label, _)` still targets THIS block).
fn breaks_to(label: String, e: ir.Expr) -> Bool {
  case e {
    ir.Break(l, _) -> l == label
    ir.Let(_, rhs, body) -> breaks_to(label, rhs) || breaks_to(label, body)
    ir.Block(_, _, body) -> breaks_to(label, body)
    ir.Loop(_, _, _, body) -> breaks_to(label, body)
    ir.If(_, _, t, el) -> breaks_to(label, t) || breaks_to(label, el)
    ir.Switch(_, _, arms, default) ->
      list.any(arms, fn(a) { breaks_to(label, a.body) })
      || breaks_to(label, default)
    ir.Charge(_, body) -> breaks_to(label, body)
    // A `Try` region's body AND every catch handler are sub-expressions a `Break` may live
    // in (Phase 7 — a modern `try_table` catch clause transfers to an ENCLOSING label via a
    // `Break` in its handler, T1). This scan MUST descend into both, exactly as `lower`'s
    // `expr_breaks_to` does, or block-simplify would wrongly drop a block that is broken to
    // only from inside a catch handler — leaving a dangling `Break` → `emit: UnboundLabel`.
    ir.Try(_, body, handlers) ->
      breaks_to(label, body)
      || list.any(handlers, fn(h) { breaks_to(label, h.handler) })
    _ -> False
  }
}

/// Does a `Continue(label, _)` occur anywhere in `e`? (The loop back-edge test for de-looping.)
fn continues_to(label: String, e: ir.Expr) -> Bool {
  case e {
    ir.Continue(l, _) -> l == label
    ir.Let(_, rhs, body) ->
      continues_to(label, rhs) || continues_to(label, body)
    ir.Block(_, _, body) -> continues_to(label, body)
    ir.Loop(_, _, _, body) -> continues_to(label, body)
    ir.If(_, _, t, el) -> continues_to(label, t) || continues_to(label, el)
    ir.Switch(_, _, arms, default) ->
      list.any(arms, fn(a) { continues_to(label, a.body) })
      || continues_to(label, default)
    ir.Charge(_, body) -> continues_to(label, body)
    // Descend into a `Try`'s body + catch handlers (symmetric with `breaks_to`): a
    // `Continue` to an enclosing loop can live in a catch handler's transfer (T1).
    ir.Try(_, body, handlers) ->
      continues_to(label, body)
      || list.any(handlers, fn(h) { continues_to(label, h.handler) })
    _ -> False
  }
}

// ───────────────────────────── shared IR walks (subst / free vars) ─────────────────────────────

/// Substitute each bound `Var(name)` by its mapped `Value` throughout `e`. Capture-free because
/// names are unique per function (§C), so a substituted `Var` never clashes with an inner binder.
fn subst_expr(e: ir.Expr, subs: List(#(String, ir.Value))) -> ir.Expr {
  case e {
    ir.Values(vs) -> ir.Values(subst_values(vs, subs))
    ir.Num(op, args) -> ir.Num(op, subst_values(args, subs))
    ir.Convert(op, arg) -> ir.Convert(op, subst_value(arg, subs))
    ir.TermOp(op, args) -> ir.TermOp(op, subst_values(args, subs))
    // Phase-8 map layer: substitute into the `Value` operands (the `op` is static).
    ir.MapOp(op, args) -> ir.MapOp(op, subst_values(args, subs))
    // Phase-8 term classification + native number arithmetic (unit 06): substitute into the `Value`
    // operands (the `kind`/`op` are static).
    ir.TermTest(kind, arg) -> ir.TermTest(kind, subst_value(arg, subs))
    ir.TermTag(arg) -> ir.TermTag(subst_value(arg, subs))
    ir.NumTerm(op, lhs, rhs) ->
      ir.NumTerm(op, subst_value(lhs, subs), subst_value(rhs, subs))
    ir.MemSize(_) -> e
    ir.MemGrow(mem, delta) -> ir.MemGrow(mem, subst_value(delta, subs))
    ir.MemLoad(mem, op, addr, offset, result) ->
      ir.MemLoad(mem, op, subst_value(addr, subs), offset, result)
    ir.MemStore(mem, op, addr, value, offset) ->
      ir.MemStore(
        mem,
        op,
        subst_value(addr, subs),
        subst_value(value, subs),
        offset,
      )
    // Phase-10 unchecked accesses (N4): substitute into their `Value` operands like the checked twins.
    ir.MemLoadUnchecked(mem, op, addr, offset, result) ->
      ir.MemLoadUnchecked(mem, op, subst_value(addr, subs), offset, result)
    ir.MemStoreUnchecked(mem, op, addr, value, offset) ->
      ir.MemStoreUnchecked(
        mem,
        op,
        subst_value(addr, subs),
        subst_value(value, subs),
        offset,
      )
    // ── Phase-5 reference/table/bulk nodes: substitute into their `Value` operands. ──
    ir.RefFunc(_) -> e
    ir.RefIsNull(arg) -> ir.RefIsNull(subst_value(arg, subs))
    ir.TableGet(table, index) -> ir.TableGet(table, subst_value(index, subs))
    ir.TableSet(table, index, value) ->
      ir.TableSet(table, subst_value(index, subs), subst_value(value, subs))
    ir.TableSize(_) -> e
    ir.TableGrow(table, delta, init) ->
      ir.TableGrow(table, subst_value(delta, subs), subst_value(init, subs))
    ir.TableFill(table, offset, value, count) ->
      ir.TableFill(
        table,
        subst_value(offset, subs),
        subst_value(value, subs),
        subst_value(count, subs),
      )
    ir.TableInit(table, seg, dst, src, count) ->
      ir.TableInit(
        table,
        seg,
        subst_value(dst, subs),
        subst_value(src, subs),
        subst_value(count, subs),
      )
    ir.TableCopy(dst_table, src_table, dst, src, count) ->
      ir.TableCopy(
        dst_table,
        src_table,
        subst_value(dst, subs),
        subst_value(src, subs),
        subst_value(count, subs),
      )
    ir.ElemDrop(_) -> e
    ir.MemFill(mem, dest, value, count) ->
      ir.MemFill(
        mem,
        subst_value(dest, subs),
        subst_value(value, subs),
        subst_value(count, subs),
      )
    ir.MemCopy(dst_mem, src_mem, dst, src, count) ->
      ir.MemCopy(
        dst_mem,
        src_mem,
        subst_value(dst, subs),
        subst_value(src, subs),
        subst_value(count, subs),
      )
    ir.MemInit(mem, seg, dst, src, count) ->
      ir.MemInit(
        mem,
        seg,
        subst_value(dst, subs),
        subst_value(src, subs),
        subst_value(count, subs),
      )
    ir.DataDrop(_) -> e
    ir.GlobalGet(_) -> e
    ir.GlobalSet(name, value) -> ir.GlobalSet(name, subst_value(value, subs))
    ir.CallDirect(fn_name, cargs) ->
      ir.CallDirect(fn_name, subst_values(cargs, subs))
    // ── Phase-8 native closures: substitute into their `Value` operands (captures / callee +
    // args); the `fn_name` and `arity` are static. ──
    ir.MakeClosure(fn_name, captures, arity) ->
      ir.MakeClosure(fn_name, subst_values(captures, subs), arity)
    ir.CallClosure(callee, cargs) ->
      ir.CallClosure(subst_value(callee, subs), subst_values(cargs, subs))
    ir.CallIndirect(table, index, ty, cargs) ->
      ir.CallIndirect(
        table,
        subst_value(index, subs),
        ty,
        subst_values(cargs, subs),
      )
    ir.CallHost(cap, name, cargs) ->
      ir.CallHost(cap, name, subst_values(cargs, subs))
    ir.Let(names, rhs, body) ->
      ir.Let(names, subst_expr(rhs, subs), subst_expr(body, subs))
    ir.Block(label, result, body) ->
      ir.Block(label, result, subst_expr(body, subs))
    ir.Loop(label, params, result, body) ->
      ir.Loop(
        label,
        list.map(params, fn(p) {
          ir.LoopParam(..p, init: subst_value(p.init, subs))
        }),
        result,
        subst_expr(body, subs),
      )
    ir.If(cond, result, then_branch, else_branch) ->
      ir.If(
        subst_value(cond, subs),
        result,
        subst_expr(then_branch, subs),
        subst_expr(else_branch, subs),
      )
    ir.Switch(sel, result, arms, default) ->
      ir.Switch(
        subst_value(sel, subs),
        result,
        list.map(arms, fn(a) {
          ir.SwitchArm(..a, body: subst_expr(a.body, subs))
        }),
        subst_expr(default, subs),
      )
    ir.Break(label, values) -> ir.Break(label, subst_values(values, subs))
    ir.Continue(label, values) -> ir.Continue(label, subst_values(values, subs))
    ir.Return(values) -> ir.Return(subst_values(values, subs))
    ir.Trap(_) -> e
    ir.Charge(cost, body) -> ir.Charge(cost, subst_expr(body, subs))
    // ── Phase-6 SIMD nodes + `CallImport`: substitute into their `Value` operands (they carry
    // only `Value`s, no sub-`Expr`). ──
    ir.Simd(op, sargs) -> ir.Simd(op, subst_values(sargs, subs))
    ir.SimdShuffle(lanes, a, b) ->
      ir.SimdShuffle(lanes, subst_value(a, subs), subst_value(b, subs))
    ir.SimdLoad(mem, kind, addr, offset) ->
      ir.SimdLoad(mem, kind, subst_value(addr, subs), offset)
    ir.SimdStore(mem, addr, value, offset) ->
      ir.SimdStore(
        mem,
        subst_value(addr, subs),
        subst_value(value, subs),
        offset,
      )
    ir.SimdLoadLane(mem, width, addr, offset, lane, vec) ->
      ir.SimdLoadLane(
        mem,
        width,
        subst_value(addr, subs),
        offset,
        lane,
        subst_value(vec, subs),
      )
    ir.SimdStoreLane(mem, width, addr, offset, lane, vec) ->
      ir.SimdStoreLane(
        mem,
        width,
        subst_value(addr, subs),
        offset,
        lane,
        subst_value(vec, subs),
      )
    ir.CallImport(slot, ty, cargs) ->
      ir.CallImport(slot, ty, subst_values(cargs, subs))
    // ── Phase-7 EH nodes: substitute their `Value` operands (the tag NAME is static); `Try`
    // recurses into its body + each handler's inline handler expression. Byte-neutral (no
    // Phase-1..6 module has these nodes). ──
    ir.Throw(tag, args) -> ir.Throw(tag, subst_values(args, subs))
    ir.ThrowRef(exnref) -> ir.ThrowRef(subst_value(exnref, subs))
    ir.Try(result, body, handlers) ->
      ir.Try(
        result,
        subst_expr(body, subs),
        list.map(handlers, fn(h) {
          ir.CatchHandler(..h, handler: subst_expr(h.handler, subs))
        }),
      )
  }
}

/// Substitute one atomic `Value`: a `Var` bound in `subs` maps to its replacement; everything
/// else (a `Const*`, or an unbound `Var`) is unchanged.
fn subst_value(v: ir.Value, subs: List(#(String, ir.Value))) -> ir.Value {
  case v {
    ir.Var(name) ->
      case list.key_find(subs, name) {
        Ok(replacement) -> replacement
        Error(Nil) -> v
      }
    _ -> v
  }
}

/// Map `subst_value` over a list of operands.
fn subst_values(
  vs: List(ir.Value),
  subs: List(#(String, ir.Value)),
) -> List(ir.Value) {
  list.map(vs, fn(v) { subst_value(v, subs) })
}

/// All `Var` names appearing in `e` (with duplicates). Used by dead-`let` to test liveness.
fn expr_vars(e: ir.Expr) -> List(String) {
  case e {
    ir.Values(vs) -> values_names(vs)
    ir.Num(_, args) -> values_names(args)
    ir.Convert(_, arg) -> value_name(arg)
    ir.TermOp(_, args) -> values_names(args)
    // Phase-8 map layer: collect the `Var` names in the map op's operands (the `op` is static).
    ir.MapOp(_, args) -> values_names(args)
    // Phase-8 term classification + native number arithmetic (unit 06): collect the `Var` names in
    // their operands (the `kind`/`op` are static).
    ir.TermTest(_, arg) -> value_name(arg)
    ir.TermTag(arg) -> value_name(arg)
    ir.NumTerm(_, lhs, rhs) -> list.append(value_name(lhs), value_name(rhs))
    ir.MemSize(_) -> []
    ir.MemGrow(_, delta) -> value_name(delta)
    ir.MemLoad(_, _, addr, _, _) -> value_name(addr)
    ir.MemStore(_, _, addr, value, _) ->
      list.append(value_name(addr), value_name(value))
    ir.MemLoadUnchecked(_, _, addr, _, _) -> value_name(addr)
    ir.MemStoreUnchecked(_, _, addr, value, _) ->
      list.append(value_name(addr), value_name(value))
    // ── Phase-5 reference/table/bulk nodes: collect the `Var` names in their operands. ──
    ir.RefFunc(_) -> []
    ir.RefIsNull(arg) -> value_name(arg)
    ir.TableGet(_, index) -> value_name(index)
    ir.TableSet(_, index, value) ->
      list.append(value_name(index), value_name(value))
    ir.TableSize(_) -> []
    ir.TableGrow(_, delta, init) ->
      list.append(value_name(delta), value_name(init))
    ir.TableFill(_, offset, value, count) ->
      list.append(
        value_name(offset),
        list.append(value_name(value), value_name(count)),
      )
    ir.TableInit(_, _, dst, src, count) ->
      list.append(
        value_name(dst),
        list.append(value_name(src), value_name(count)),
      )
    ir.TableCopy(_, _, dst, src, count) ->
      list.append(
        value_name(dst),
        list.append(value_name(src), value_name(count)),
      )
    ir.ElemDrop(_) -> []
    ir.MemFill(_, dest, value, count) ->
      list.append(
        value_name(dest),
        list.append(value_name(value), value_name(count)),
      )
    ir.MemCopy(_, _, dst, src, count) ->
      list.append(
        value_name(dst),
        list.append(value_name(src), value_name(count)),
      )
    ir.MemInit(_, _, dst, src, count) ->
      list.append(
        value_name(dst),
        list.append(value_name(src), value_name(count)),
      )
    ir.DataDrop(_) -> []
    ir.GlobalGet(_) -> []
    ir.GlobalSet(_, value) -> value_name(value)
    ir.CallDirect(_, args) -> values_names(args)
    // ── Phase-8 native closures: collect the `Var` names in their operands (captures / callee +
    // args); the `fn_name` is a function name, not a `Var`. ──
    ir.MakeClosure(_, captures, _) -> values_names(captures)
    ir.CallClosure(callee, args) ->
      list.append(value_name(callee), values_names(args))
    ir.CallIndirect(_, index, _, args) ->
      list.append(value_name(index), values_names(args))
    ir.CallHost(_, _, args) -> values_names(args)
    ir.Let(_, rhs, body) -> list.append(expr_vars(rhs), expr_vars(body))
    ir.Block(_, _, body) -> expr_vars(body)
    ir.Loop(_, params, _, body) ->
      list.append(
        list.flat_map(params, fn(p) { value_name(p.init) }),
        expr_vars(body),
      )
    ir.If(cond, _, then_branch, else_branch) ->
      list.append(
        value_name(cond),
        list.append(expr_vars(then_branch), expr_vars(else_branch)),
      )
    ir.Switch(sel, _, arms, default) ->
      list.append(
        value_name(sel),
        list.append(
          list.flat_map(arms, fn(a) { expr_vars(a.body) }),
          expr_vars(default),
        ),
      )
    ir.Break(_, values) -> values_names(values)
    ir.Continue(_, values) -> values_names(values)
    ir.Return(values) -> values_names(values)
    ir.Trap(_) -> []
    ir.Charge(_, body) -> expr_vars(body)
    // ── Phase-6 SIMD nodes + `CallImport`: collect the `Var` names in their `Value` operands. ──
    ir.Simd(_, args) -> values_names(args)
    ir.SimdShuffle(_, a, b) -> list.append(value_name(a), value_name(b))
    ir.SimdLoad(_, _, addr, _) -> value_name(addr)
    ir.SimdStore(_, addr, value, _) ->
      list.append(value_name(addr), value_name(value))
    ir.SimdLoadLane(_, _, addr, _, _, vec) ->
      list.append(value_name(addr), value_name(vec))
    ir.SimdStoreLane(_, _, addr, _, _, vec) ->
      list.append(value_name(addr), value_name(vec))
    ir.CallImport(_, _, args) -> values_names(args)
    // ── Phase-7 EH nodes: collect the `Var` names in their operands / sub-expressions (the tag
    // NAME is static). Over-approximating (including handler binders) is safe for liveness —
    // names are function-unique. Byte-neutral (no Phase-1..6 module has these nodes). ──
    ir.Throw(_, args) -> values_names(args)
    ir.ThrowRef(exnref) -> value_name(exnref)
    ir.Try(_, body, handlers) ->
      list.append(
        expr_vars(body),
        list.flat_map(handlers, fn(h) { expr_vars(h.handler) }),
      )
  }
}

/// The name of a `Var` value as a singleton list, or `[]` for a constant.
fn value_name(v: ir.Value) -> List(String) {
  case v {
    ir.Var(n) -> [n]
    _ -> []
  }
}

/// The `Var` names among a list of operands.
fn values_names(vs: List(ir.Value)) -> List(String) {
  list.flat_map(vs, value_name)
}
