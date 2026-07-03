//// Unit P3-03 — per-pass spec/differential tests for the trust-neutral Baseline pass set.
////
//// Every assertion is against WASM SPEC behavior (exec/numerics; exec/instructions §Control)
//// or the F2 semantics-preservation requirement — NOT against whatever the current code happens
//// to emit (no change-detectors, D8). The load-bearing differential: a folded constant equals
//// the DIRECT `rt_num` result bit-for-bit (D2/D7), so if a fold arm dispatched to the wrong
//// runtime function the expected value (computed here by calling `rt_num` directly) would
//// diverge and the test would fail.
////
//// The optimizer is run at `Baseline` (the trust-neutral set); `optimize` is total, so each
//// `opt_body` is the optimized body of a one-function module.

import gleam/list
import gleam/option
import twocore/ir
import twocore/middle/ir_opt
import twocore/runtime/rt_num

// ───────────────────────────── harness ─────────────────────────────

/// A one-function module whose body is `body` (numerics enabled, no memory/globals).
fn mod_with_body(body: ir.Expr) -> ir.Module {
  ir.Module(
    name: "twocore@opt@baseline_test",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [
      ir.Function(name: "f", params: [], result: [], locals: [], body: body),
    ],
    exports: [],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// The optimized (`Baseline`) body of the one-function module wrapping `body`. Total.
fn opt_body(body: ir.Expr) -> ir.Expr {
  first_body(ir_opt.optimize(mod_with_body(body), ir_opt.Baseline))
}

/// The first function's body, or an empty `Values` if (impossibly) absent — total, no panic.
fn first_body(m: ir.Module) -> ir.Expr {
  case m.functions {
    [f, ..] -> f.body
    [] -> ir.Values([])
  }
}

/// A binary `i32` op over two constants.
fn i32_binop(op: ir.NumOp, a: Int, b: Int) -> ir.Expr {
  ir.Num(op, [ir.ConstI32(a), ir.ConstI32(b)])
}

/// A binary `i64` op over two constants.
fn i64_binop(op: ir.NumOp, a: Int, b: Int) -> ir.Expr {
  ir.Num(op, [ir.ConstI64(a), ir.ConstI64(b)])
}

/// `Values([ConstI32(bits)])` — the shape a folded i32 site collapses to.
fn vi32(bits: Int) -> ir.Expr {
  ir.Values([ir.ConstI32(bits)])
}

/// `Values([ConstI64(bits)])`.
fn vi64(bits: Int) -> ir.Expr {
  ir.Values([ir.ConstI64(bits)])
}

/// `Values([ConstF32(bits)])`.
fn vf32(bits: Int) -> ir.Expr {
  ir.Values([ir.ConstF32(bits)])
}

/// `Values([ConstF64(bits)])`.
fn vf64(bits: Int) -> ir.Expr {
  ir.Values([ir.ConstF64(bits)])
}

/// Does a `Loop` node survive anywhere in `e`? (Used to prove de-loop / dead-branch removal.)
fn contains_loop(e: ir.Expr) -> Bool {
  case e {
    ir.Loop(_, _, _, _) -> True
    ir.Let(_, rhs, body) -> contains_loop(rhs) || contains_loop(body)
    ir.Block(_, _, body) -> contains_loop(body)
    ir.If(_, _, t, el) -> contains_loop(t) || contains_loop(el)
    ir.Switch(_, _, arms, default) ->
      list.any(arms, fn(a) { contains_loop(a.body) }) || contains_loop(default)
    ir.Charge(_, body) -> contains_loop(body)
    _ -> False
  }
}

// Interesting i32 corner constants (raw unsigned bit patterns) for the differential batteries.
const i32_corners: List(Int) = [
  0, 1, 2, 7, 2_147_483_647, 2_147_483_648, 4_294_967_295, 3_735_928_559, 65_535,
  305_419_896,
]

// Raw IEEE-754 bit patterns used across the float corner tests.
const f32_one: Int = 1_065_353_216

// 0x3F800000

const f32_pos_inf: Int = 2_139_095_040

// 0x7F800000

const f32_canonical_nan: Int = 2_143_289_344

// 0x7FC00000

const f64_neg_zero: Int = 9_223_372_036_854_775_808

// 0x8000000000000000

const f64_max_normal: Int = 9_218_868_437_227_405_311

// 0x7FEFFFFFFFFFFFFF

// ══════════════════════════ §1. const-fold ≡ rt_num, bit-exact ══════════════════════════

/// i32 two's-complement wrap (exec/numerics `iadd`): `0xFFFFFFFF + 1 == 0`, and the fold equals
/// the direct `rt_num.i32_add`.
pub fn fold_i32_add_wraps_test() {
  assert opt_body(i32_binop(ir.IAdd(ir.W32), 4_294_967_295, 1)) == vi32(0)
  assert opt_body(i32_binop(ir.IAdd(ir.W32), 4_294_967_295, 1))
    == vi32(rt_num.i32_add(4_294_967_295, 1))
}

/// i32 multiply overflow keeps the low 32 bits (exec/numerics `imul`); fold ≡ `rt_num.i32_mul`.
pub fn fold_i32_mul_overflow_test() {
  assert opt_body(i32_binop(ir.IMul(ir.W32), 65_536, 65_536))
    == vi32(rt_num.i32_mul(65_536, 65_536))
  // 2^16 * 2^16 = 2^32 ≡ 0 (mod 2^32).
  assert opt_body(i32_binop(ir.IMul(ir.W32), 65_536, 65_536)) == vi32(0)
}

/// i32 arithmetic shift-right SIGN-FILLS (exec/numerics `ishr_s`): `0x80000000 >> 4` fills the
/// top nibble with ones. Fold ≡ `rt_num.i32_shr_s`.
pub fn fold_i32_shr_s_sign_fills_test() {
  assert opt_body(i32_binop(ir.IShrS(ir.W32), 2_147_483_648, 4))
    == vi32(rt_num.i32_shr_s(2_147_483_648, 4))
  assert opt_body(i32_binop(ir.IShrS(ir.W32), 2_147_483_648, 4))
    == vi32(4_160_749_568)
  // 0xF8000000
}

/// An i32 comparison folds to the i32 truth value (`0`/`1`), NOT to the operand width.
pub fn fold_i32_comparison_is_truth_value_test() {
  assert opt_body(i32_binop(ir.ILtS(ir.W32), 4_294_967_295, 1)) == vi32(1)
  // -1 <s 1
  assert opt_body(i32_binop(ir.ILtU(ir.W32), 4_294_967_295, 1)) == vi32(0)
  // 0xFFFFFFFF >u 1
  assert opt_body(i32_binop(ir.IEq(ir.W32), 7, 7)) == vi32(1)
}

/// i64 folds land in a `ConstI64`; wrap and a width-64 comparison both match `rt_num`.
pub fn fold_i64_add_and_compare_test() {
  assert opt_body(i64_binop(ir.IAdd(ir.W64), 18_446_744_073_709_551_615, 1))
    == vi64(rt_num.i64_add(18_446_744_073_709_551_615, 1))
  assert opt_body(i64_binop(ir.IAdd(ir.W64), 18_446_744_073_709_551_615, 1))
    == vi64(0)
  // i64 comparison still yields an i32 truth value.
  assert opt_body(i64_binop(ir.IEq(ir.W64), 5, 5)) == vi32(1)
}

/// f64 overflow rounds to `+Inf` (exec/numerics): max-normal + max-normal → `+Inf`. Fold ≡
/// `rt_num.f64_add`.
pub fn fold_f64_add_overflow_to_inf_test() {
  assert opt_body(
      ir.Num(ir.FAdd(ir.FW64), [
        ir.ConstF64(f64_max_normal),
        ir.ConstF64(f64_max_normal),
      ]),
    )
    == vf64(rt_num.f64_add(f64_max_normal, f64_max_normal))
}

/// f32 `0 * Inf` produces the POSITIVE CANONICAL NaN (deterministic profile). Fold ≡
/// `rt_num.f32_mul`, and the bits are exactly `0x7FC00000`.
pub fn fold_f32_mul_canonical_nan_test() {
  assert opt_body(
      ir.Num(ir.FMul(ir.FW32), [
        ir.ConstF32(0),
        ir.ConstF32(f32_pos_inf),
      ]),
    )
    == vf32(rt_num.f32_mul(0, f32_pos_inf))
  assert opt_body(
      ir.Num(ir.FMul(ir.FW32), [
        ir.ConstF32(0),
        ir.ConstF32(f32_pos_inf),
      ]),
    )
    == vf32(f32_canonical_nan)
}

/// `-0.0` is preserved bit-exactly: `f64.neg(+0.0)` yields `-0.0` (a pure sign-bit flip). Fold ≡
/// `rt_num.f64_neg`.
pub fn fold_f64_neg_zero_bits_test() {
  assert opt_body(ir.Num(ir.FNeg(ir.FW64), [ir.ConstF64(0)]))
    == vf64(rt_num.f64_neg(0))
  assert opt_body(ir.Num(ir.FNeg(ir.FW64), [ir.ConstF64(0)]))
    == vf64(f64_neg_zero)
}

/// WASM `f*.min(+0, -0) = -0` (exec/numerics); const-fold reproduces the signed-zero rule.
pub fn fold_f64_min_signed_zero_test() {
  assert opt_body(
      ir.Num(ir.FMin(ir.FW64), [
        ir.ConstF64(0),
        ir.ConstF64(f64_neg_zero),
      ]),
    )
    == vf64(rt_num.f64_min(0, f64_neg_zero))
  assert opt_body(
      ir.Num(ir.FMin(ir.FW64), [
        ir.ConstF64(0),
        ir.ConstF64(f64_neg_zero),
      ]),
    )
    == vf64(f64_neg_zero)
}

/// `reinterpret` is bit-identity on our raw-bits representation: `i32.reinterpret_f32(1.0f)` is
/// the f32's bit pattern unchanged.
pub fn fold_reinterpret_bit_identity_test() {
  assert opt_body(ir.Convert(ir.ReinterpretFToI(ir.FW32), ir.ConstF32(f32_one)))
    == vi32(f32_one)
  assert opt_body(ir.Convert(ir.ReinterpretIToF(ir.W32), ir.ConstI32(f32_one)))
    == vf32(f32_one)
}

/// A representative conversion beyond reinterpret: `i64.extend_i32_s` sign-extends `-1`.
pub fn fold_extend_conversion_test() {
  assert opt_body(ir.Convert(ir.I64ExtendI32S, ir.ConstI32(4_294_967_295)))
    == vi64(rt_num.i64_extend_i32_s(4_294_967_295))
  assert opt_body(ir.Convert(ir.I64ExtendI32S, ir.ConstI32(4_294_967_295)))
    == vi64(18_446_744_073_709_551_615)
}

/// Property battery (§1 "random constants"): over a spread of i32 corner constants, every folded
/// binary op equals the direct `rt_num` call — bit-for-bit, for all pairs.
pub fn fold_i32_battery_matches_rt_num_test() {
  list.each(i32_corners, fn(a) {
    list.each(i32_corners, fn(b) {
      assert opt_body(i32_binop(ir.IAdd(ir.W32), a, b))
        == vi32(rt_num.i32_add(a, b))
      assert opt_body(i32_binop(ir.ISub(ir.W32), a, b))
        == vi32(rt_num.i32_sub(a, b))
      assert opt_body(i32_binop(ir.IMul(ir.W32), a, b))
        == vi32(rt_num.i32_mul(a, b))
      assert opt_body(i32_binop(ir.IAnd(ir.W32), a, b))
        == vi32(rt_num.i32_and(a, b))
      assert opt_body(i32_binop(ir.IOr(ir.W32), a, b))
        == vi32(rt_num.i32_or(a, b))
      assert opt_body(i32_binop(ir.IXor(ir.W32), a, b))
        == vi32(rt_num.i32_xor(a, b))
      assert opt_body(i32_binop(ir.IShl(ir.W32), a, b))
        == vi32(rt_num.i32_shl(a, b))
      assert opt_body(i32_binop(ir.IShrU(ir.W32), a, b))
        == vi32(rt_num.i32_shr_u(a, b))
      assert opt_body(i32_binop(ir.IGeU(ir.W32), a, b))
        == vi32(rt_num.i32_ge_u(a, b))
    })
  })
}

// ══════════════════════════ §2. trapping fold ══════════════════════════

/// A constant `div_s` by 0 folds to the EXACT trap `rt_num` returns — `Trap(IntDivByZero)`,
/// never a value (exec/numerics `idiv_s`).
pub fn fold_div_by_zero_traps_test() {
  assert rt_num.i32_div_s(5, 0) == Error(ir.IntDivByZero)
  assert opt_body(i32_binop(ir.IDivS(ir.W32), 5, 0)) == ir.Trap(ir.IntDivByZero)
  assert opt_body(i32_binop(ir.IDivU(ir.W32), 5, 0)) == ir.Trap(ir.IntDivByZero)
  assert opt_body(i32_binop(ir.IRemS(ir.W32), 5, 0)) == ir.Trap(ir.IntDivByZero)
}

/// `INT_MIN / -1` is the one signed-division OVERFLOW trap (exec/numerics `idiv_s`): it folds to
/// `Trap(IntOverflow)`, distinct from divide-by-zero.
pub fn fold_int_min_div_neg_one_overflows_test() {
  assert rt_num.i32_div_s(2_147_483_648, 4_294_967_295) == Error(ir.IntOverflow)
  assert opt_body(i32_binop(ir.IDivS(ir.W32), 2_147_483_648, 4_294_967_295))
    == ir.Trap(ir.IntOverflow)
}

/// `rem_s` never overflow-traps: `INT_MIN % -1 == 0` (exec/numerics), so it folds to `0`.
pub fn fold_int_min_rem_neg_one_is_zero_test() {
  assert opt_body(i32_binop(ir.IRemS(ir.W32), 2_147_483_648, 4_294_967_295))
    == vi32(0)
}

/// A trapping float→int truncation of NaN folds to `Trap(InvalidConversionToInteger)` (distinct
/// from the out-of-range `IntOverflow`), matching `rt_num.i32_trunc_f32_s` (exec/numerics).
pub fn fold_trunc_nan_traps_invalid_conversion_test() {
  assert rt_num.i32_trunc_f32_s(f32_canonical_nan)
    == Error(ir.InvalidConversionToInteger)
  assert opt_body(ir.Convert(
      ir.TruncS(ir.FW32, ir.W32),
      ir.ConstF32(f32_canonical_nan),
    ))
    == ir.Trap(ir.InvalidConversionToInteger)
}

/// A trapping truncation of `+Inf` is OUT OF RANGE → `Trap(IntOverflow)` (spec test suite:
/// `trunc(inf)` is "integer overflow"), matching `rt_num`.
pub fn fold_trunc_inf_traps_overflow_test() {
  assert opt_body(ir.Convert(
      ir.TruncS(ir.FW32, ir.W32),
      ir.ConstF32(f32_pos_inf),
    ))
    == ir.Trap(ir.IntOverflow)
}

/// The four boxing conversions have NO constant `Value` for a `TTerm`, so they are LEFT
/// UNCHANGED even over a constant operand (they are not foldable).
pub fn boxing_conversions_are_not_folded_test() {
  let box = ir.Convert(ir.BoxInt(ir.W32), ir.ConstI32(7))
  assert opt_body(box) == box
  let unbox = ir.Convert(ir.UnboxFloat(ir.FW64), ir.Var("t"))
  assert opt_body(unbox) == unbox
}

// ══════════════════════════ §3. prop + dead-`let` + F3 (must / must-NOT) ══════════════════════════

/// Copy/const-prop substitutes the atomic `Values` binding and drops the `let`; the substituted
/// constant then folds — `let x = 7 in x + 35` collapses to `42`.
pub fn prop_then_fold_test() {
  let e =
    ir.Let(
      ["x"],
      ir.Values([ir.ConstI32(7)]),
      ir.Num(ir.IAdd(ir.W32), [ir.Var("x"), ir.ConstI32(35)]),
    )
  assert opt_body(e) == vi32(42)
}

/// A PURE binding whose result is unused is removed (dead-`let`).
pub fn dead_pure_let_removed_test() {
  let e =
    ir.Let(
      ["x"],
      ir.Num(ir.IAdd(ir.W32), [ir.Var("a"), ir.Var("b")]),
      ir.Values([ir.ConstI32(9)]),
    )
  assert opt_body(e) == vi32(9)
}

/// F3 "must NOT" (E1/E6): an EFFECTFUL binding with an unused result is KEPT — a store, a global
/// write, a host call, and a fuel charge each survive `optimize` verbatim. Dropping any would
/// remove an observable effect.
pub fn effectful_dead_let_is_retained_test() {
  let store =
    ir.Let(
      ["d"],
      ir.MemStore(0, ir.MemAccess(4, False), ir.ConstI32(0), ir.ConstI32(1), 0),
      ir.Values([ir.ConstI32(9)]),
    )
  assert opt_body(store) == store

  let gset =
    ir.Let(
      ["d"],
      ir.GlobalSet("g", ir.ConstI32(1)),
      ir.Values([ir.ConstI32(9)]),
    )
  assert opt_body(gset) == gset

  let host =
    ir.Let(
      ["d"],
      ir.CallHost("io", "print", [ir.ConstI32(1)]),
      ir.Values([ir.ConstI32(9)]),
    )
  assert opt_body(host) == host

  let charge =
    ir.Let(["d"], ir.Charge(3, ir.Values([])), ir.Values([ir.ConstI32(9)]))
  assert opt_body(charge) == charge
}

/// F3 "must NOT": a TRAPPING `div` with a NON-constant, unused result is KEPT — deleting it would
/// erase a trap that might fire (its operands are variables, so const-fold cannot decide it).
pub fn trapping_dead_let_is_retained_test() {
  let e =
    ir.Let(
      ["d"],
      ir.Num(ir.IDivS(ir.W32), [ir.Var("a"), ir.Var("b")]),
      ir.Values([ir.ConstI32(9)]),
    )
  assert opt_body(e) == e
}

// ══════════════════════════ §4. algebraic — positive & negative ══════════════════════════

/// Safe integer identities fire on an atomic operand (ANF): `x+0`, `x*1`, `x<<0`, `x/1` → `x`.
pub fn algebraic_identity_returns_operand_test() {
  assert opt_body(ir.Num(ir.IAdd(ir.W32), [ir.Var("a"), ir.ConstI32(0)]))
    == ir.Values([ir.Var("a")])
  assert opt_body(ir.Num(ir.IMul(ir.W32), [ir.ConstI32(1), ir.Var("a")]))
    == ir.Values([ir.Var("a")])
  assert opt_body(ir.Num(ir.IShl(ir.W32), [ir.Var("a"), ir.ConstI32(0)]))
    == ir.Values([ir.Var("a")])
  assert opt_body(ir.Num(ir.IDivS(ir.W32), [ir.Var("a"), ir.ConstI32(1)]))
    == ir.Values([ir.Var("a")])
}

/// Absorbing / reflexive identities: `x*0 → 0`, `x^x → 0`, `x&x → x`, `x%1 → 0`.
pub fn algebraic_absorbing_and_reflexive_test() {
  assert opt_body(ir.Num(ir.IMul(ir.W32), [ir.Var("a"), ir.ConstI32(0)]))
    == vi32(0)
  assert opt_body(ir.Num(ir.IXor(ir.W32), [ir.Var("a"), ir.Var("a")]))
    == vi32(0)
  assert opt_body(ir.Num(ir.IAnd(ir.W32), [ir.Var("a"), ir.Var("a")]))
    == ir.Values([ir.Var("a")])
  assert opt_body(ir.Num(ir.IRemS(ir.W32), [ir.Var("a"), ir.ConstI32(1)]))
    == vi32(0)
}

/// Division / remainder by a literal `0` folds to `Trap(IntDivByZero)` regardless of the
/// dividend (exec/numerics), exposing the now-dead sequel to DCE.
pub fn algebraic_div_by_literal_zero_traps_test() {
  assert opt_body(ir.Num(ir.IDivS(ir.W32), [ir.Var("a"), ir.ConstI32(0)]))
    == ir.Trap(ir.IntDivByZero)
  assert opt_body(ir.Num(ir.IRemU(ir.W32), [ir.Var("a"), ir.ConstI32(0)]))
    == ir.Trap(ir.IntDivByZero)
}

/// Reflexive INTEGER comparisons: `x==x → 1`, `x<x → 0`, `x>=x → 1` (a `Var` reads the same bits
/// in both operand positions, §C).
pub fn algebraic_reflexive_compare_test() {
  assert opt_body(ir.Num(ir.IEq(ir.W32), [ir.Var("a"), ir.Var("a")])) == vi32(1)
  assert opt_body(ir.Num(ir.ILtS(ir.W32), [ir.Var("a"), ir.Var("a")]))
    == vi32(0)
  assert opt_body(ir.Num(ir.IGeU(ir.W32), [ir.Var("a"), ir.Var("a")]))
    == vi32(1)
}

/// NEGATIVE: `x / -1` is LEFT UNCHANGED — `INT_MIN / -1` overflow-traps, but a `0 - x` rewrite
/// would not, so this rewrite is unsound and must not happen (exec/numerics `idiv_s`).
pub fn algebraic_div_neg_one_not_rewritten_test() {
  let e = ir.Num(ir.IDivS(ir.W32), [ir.Var("a"), ir.ConstI32(4_294_967_295)])
  assert opt_body(e) == e
}

/// NEGATIVE: float `x + 0.0` and `x * 1.0` are LEFT UNCHANGED — `-0.0`/NaN corners mean `x ∘ id`
/// is not the identity on floats (`rt_num.fadd`/`fmul`), so fold only when BOTH are constant.
pub fn algebraic_float_identities_not_rewritten_test() {
  let add0 = ir.Num(ir.FAdd(ir.FW32), [ir.Var("a"), ir.ConstF32(0)])
  assert opt_body(add0) == add0
  let mul1 = ir.Num(ir.FMul(ir.FW32), [ir.Var("a"), ir.ConstF32(f32_one)])
  assert opt_body(mul1) == mul1
}

/// NEGATIVE: a float reflexive comparison `x == x` is LEFT UNCHANGED — for `x = NaN`, `x ≠ x`
/// (the integer reflexive identity does NOT carry to floats).
pub fn algebraic_float_reflexive_compare_not_rewritten_test() {
  let e = ir.Num(ir.FEq(ir.FW32), [ir.Var("a"), ir.Var("a")])
  assert opt_body(e) == e
}

// ══════════════════════════ §5. block / label & const-`if` (D6) ══════════════════════════

/// A block with NO break to its label collapses to its body (falling off yields what the body
/// yields).
pub fn block_with_no_break_collapses_test() {
  assert opt_body(ir.Block("b", [], ir.Values([ir.ConstI32(5)]))) == vi32(5)
}

/// A non-iterating `Loop` (no `Continue`) is DE-LOOPED and, with its init propagated, reduces to
/// the value it produces once — leaving NO `Loop` node.
pub fn non_iterating_loop_is_delooped_test() {
  let loop =
    ir.Loop(
      "l",
      [ir.LoopParam("i", ir.TI32, ir.ConstI32(0))],
      [ir.TI32],
      ir.Values([ir.Var("i")]),
    )
  assert opt_body(loop) == vi32(0)
  assert contains_loop(opt_body(loop)) == False
}

/// An ITERATING loop (a `Continue` to its own label) is PRESERVED — de-loop must not touch it.
pub fn iterating_loop_is_preserved_test() {
  let loop =
    ir.Loop(
      "l",
      [ir.LoopParam("i", ir.TI32, ir.ConstI32(0))],
      [ir.TI32],
      ir.Continue("l", [ir.ConstI32(0)]),
    )
  assert opt_body(loop) == loop
  assert contains_loop(opt_body(loop)) == True
}

/// `If(ConstI32(1), …)` selects the THEN branch and DISCARDS an effectful else branch — sound
/// because the discarded arm is statically unreached (§H); `emit_core` tests the i32 cond ≠ 0.
pub fn const_if_selects_then_discards_effect_test() {
  let e =
    ir.If(
      ir.ConstI32(1),
      [],
      ir.Values([ir.ConstI32(1)]),
      ir.GlobalSet("g", ir.ConstI32(9)),
    )
  assert opt_body(e) == vi32(1)
}

/// `If(ConstI32(0), …)` selects the ELSE branch (cond `== 0` is false).
pub fn const_if_zero_selects_else_test() {
  let e =
    ir.If(
      ir.ConstI32(0),
      [],
      ir.Values([ir.ConstI32(1)]),
      ir.Values([ir.ConstI32(2)]),
    )
  assert opt_body(e) == vi32(2)
}

/// `If` with a VARIABLE condition is LEFT UNCHANGED (nothing is statically decided).
pub fn var_if_is_untouched_test() {
  let e =
    ir.If(
      ir.Var("c"),
      [],
      ir.Values([ir.ConstI32(1)]),
      ir.Values([ir.ConstI32(2)]),
    )
  assert opt_body(e) == e
}

/// A `Switch` with a constant selector selects the matching arm's body; a selector matching no
/// arm selects the `default` (mirroring `emit_core`'s first-match `case`).
pub fn const_switch_selects_arm_and_default_test() {
  let arms = [
    ir.SwitchArm(0, ir.Values([ir.ConstI32(10)])),
    ir.SwitchArm(1, ir.Values([ir.ConstI32(20)])),
  ]
  let default = ir.Values([ir.ConstI32(99)])
  assert opt_body(ir.Switch(ir.ConstI32(1), [], arms, default)) == vi32(20)
  assert opt_body(ir.Switch(ir.ConstI32(5), [], arms, default)) == vi32(99)
}

// ══════════════════════════ §E. dead-code / unreachable ══════════════════════════

/// A `let` bound to a `Trap` makes the body UNREACHABLE (ANF evaluates the rhs first) → the body
/// (and any effects it holds) is dropped, leaving just the `Trap`.
pub fn dce_drops_body_after_trap_test() {
  let e = ir.Let(["x"], ir.Trap(ir.Unreachable), ir.Values([ir.ConstI32(5)]))
  assert opt_body(e) == ir.Trap(ir.Unreachable)
}

/// A `Charge` on a PROVABLY-UNREACHED path (after a `Trap`) is removed — it contributes zero
/// runtime fuel, so the metered bound is unchanged (F5).
pub fn dce_drops_charge_on_unreached_path_test() {
  let e = ir.Let(["x"], ir.Trap(ir.Unreachable), ir.Charge(5, ir.Values([])))
  assert opt_body(e) == ir.Trap(ir.Unreachable)
}

/// A LIVE `Charge` is never removed by baseline (F5): it survives verbatim on an executed path.
pub fn live_charge_is_preserved_test() {
  let e = ir.Charge(5, ir.Values([ir.ConstI32(1)]))
  assert opt_body(e) == e
}

/// `If(cond, _, Trap(x), Trap(x))` collapses to `Trap(x)` (both outcomes are the same
/// divergence; the atomic cond has no effect).
pub fn dce_if_identical_traps_collapses_test() {
  let e =
    ir.If(ir.Var("c"), [], ir.Trap(ir.IntOverflow), ir.Trap(ir.IntOverflow))
  assert opt_body(e) == ir.Trap(ir.IntOverflow)
}

/// `If(cond, _, Trap(x), Trap(y))` with DIFFERENT traps is LEFT UNCHANGED (the outcome depends
/// on the condition).
pub fn dce_if_different_traps_untouched_test() {
  let e =
    ir.If(ir.Var("c"), [], ir.Trap(ir.IntOverflow), ir.Trap(ir.Unreachable))
  assert opt_body(e) == e
}

// ══════════════════════════ §6. fixpoint / termination ══════════════════════════

/// A nested constant expression converges to a single constant in ≤ `max_rounds`:
/// `((2*3)+4) < 100` (ANF-sequenced) reduces to `1`.
pub fn nested_constant_expression_converges_test() {
  let e =
    ir.Let(
      ["a"],
      ir.Num(ir.IMul(ir.W32), [ir.ConstI32(2), ir.ConstI32(3)]),
      ir.Let(
        ["b"],
        ir.Num(ir.IAdd(ir.W32), [ir.Var("a"), ir.ConstI32(4)]),
        ir.Num(ir.ILtS(ir.W32), [ir.Var("b"), ir.ConstI32(100)]),
      ),
    )
  assert opt_body(e) == vi32(1)
}

/// A constant guard whose folded condition selects the non-loop arm ELIMINATES the loop entirely
/// (fold → prop → const-`if` compose across the fixpoint), leaving no `Loop`.
pub fn constant_guard_eliminates_loop_test() {
  let e =
    ir.Let(
      ["c"],
      ir.Num(ir.ILtS(ir.W32), [ir.ConstI32(10), ir.ConstI32(100)]),
      ir.If(
        ir.Var("c"),
        [ir.TI32],
        ir.Values([ir.ConstI32(1)]),
        ir.Loop("l", [], [ir.TI32], ir.Break("l", [ir.ConstI32(2)])),
      ),
    )
  assert opt_body(e) == vi32(1)
  assert contains_loop(opt_body(e)) == False
}

/// `optimize` reaches a FIXPOINT: re-optimizing an already-optimized module is a no-op
/// (idempotent), so the pipeline provably converges.
pub fn optimize_is_idempotent_test() {
  let e =
    ir.Let(
      ["a"],
      ir.Num(ir.IMul(ir.W32), [ir.ConstI32(6), ir.ConstI32(7)]),
      ir.If(
        ir.Var("a"),
        [ir.TI32],
        ir.Block("b", [ir.TI32], ir.Values([ir.Var("a")])),
        ir.Trap(ir.Unreachable),
      ),
    )
  let m = mod_with_body(e)
  let once = ir_opt.optimize(m, ir_opt.Baseline)
  assert ir_opt.optimize(once, ir_opt.Baseline) == once
}

/// `OptNone` is the exact identity even over a heavily-foldable module (the F2 differential
/// baseline): with no passes, nothing is rewritten.
pub fn optnone_is_exact_identity_test() {
  let m =
    mod_with_body(ir.Num(ir.IAdd(ir.W32), [ir.ConstI32(1), ir.ConstI32(2)]))
  assert ir_opt.optimize(m, ir_opt.OptNone) == m
}
