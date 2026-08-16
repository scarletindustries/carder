//// Spec-based tests for `rt_num` (unit 06), the tier-P numeric reference impl.
////
//// Assertions target the WebAssembly numerics spec
//// (<https://webassembly.github.io/spec/core/exec/numerics.html>), NOT whatever the
//// implementation happens to emit. Every signed/unsigned variant is exercised with
//// high-bit-set operands, and the float tests cover NaN/±Inf/±0/overflow on the raw
//// bit patterns. Property laws (commutativity, the division identity, rotate inverses,
//// popcount complement, …) are checked over representative operand vectors.

import carder/ir.{IntDivByZero, IntOverflow}
import carder/runtime/rt_num as n
import gleam/list
import gleeunit/should

// ───────────────────────────── helpers ─────────────────────────────

/// Bit pattern of a finite native double (test-side oracle / literal builder).
fn f64_bits(f: Float) -> Int {
  let assert <<b:size(64)>> = <<f:float-size(64)>>
  b
}

/// Bit pattern of a native double rounded to binary32.
fn f32_bits(f: Float) -> Int {
  let assert <<b:size(32)>> = <<f:float-size(32)>>
  b
}

// f64 special bit patterns.
const f64_pos_zero = 0x0000000000000000

const f64_neg_zero = 0x8000000000000000

const f64_pos_inf = 0x7FF0000000000000

const f64_neg_inf = 0xFFF0000000000000

const f64_canon_nan = 0x7FF8000000000000

// A non-canonical (signalling-pattern) NaN: must be canonicalised by every op.
const f64_other_nan = 0x7FF0000000000001

const f64_max = 0x7FEFFFFFFFFFFFFF

// f32 special bit patterns.
const f32_pos_zero = 0x00000000

const f32_neg_zero = 0x80000000

const f32_pos_inf = 0x7F800000

const f32_neg_inf = 0xFF800000

const f32_canon_nan = 0x7FC00000

const f32_other_nan = 0x7F800001

const f32_max = 0x7F7FFFFF

/// Inclusive integer range `[lo, hi]` (the stdlib in use lacks `list.range`).
fn int_range(lo: Int, hi: Int) -> List(Int) {
  case lo > hi {
    True -> []
    False -> [lo, ..int_range(lo + 1, hi)]
  }
}

fn i32_samples() -> List(Int) {
  [
    0, 1, 2, 7, 0x40000000, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xC0000000,
    0xFFFFFFFE, 0xFFFFFFFF, 0x12345678, 0xDEADBEEF,
  ]
}

fn i64_samples() -> List(Int) {
  [
    0, 1, 2, 0x7FFFFFFFFFFFFFFF, 0x8000000000000000, 0x8000000000000001,
    0xFFFFFFFFFFFFFFFF, 0x123456789ABCDEF0, 0xDEADBEEFCAFEBABE,
  ]
}

// ───────────────────────────── wrap / add / sub / mul ─────────────────────────────

pub fn i32_add_wrap_test() {
  // 0x7FFFFFFF + 1 wraps to INT_MIN bit pattern (two's complement).
  n.i32_add(0x7FFFFFFF, 1) |> should.equal(0x80000000)
  n.i32_add(0xFFFFFFFF, 1) |> should.equal(0)
  n.i32_add(0xFFFFFFFF, 0xFFFFFFFF) |> should.equal(0xFFFFFFFE)
}

pub fn i64_add_wrap_test() {
  n.i64_add(0x7FFFFFFFFFFFFFFF, 1) |> should.equal(0x8000000000000000)
  n.i64_add(0xFFFFFFFFFFFFFFFF, 1) |> should.equal(0)
}

pub fn i32_sub_wrap_test() {
  n.i32_sub(0, 1) |> should.equal(0xFFFFFFFF)
  n.i32_sub(0x80000000, 1) |> should.equal(0x7FFFFFFF)
}

pub fn i32_mul_wrap_test() {
  // 0x10000 * 0x10000 = 2^32, wraps to 0.
  n.i32_mul(0x10000, 0x10000) |> should.equal(0)
  n.i32_mul(0xFFFFFFFF, 0xFFFFFFFF) |> should.equal(1)
}

pub fn add_commutative_test() {
  list.each(i32_samples(), fn(a) {
    list.each(i32_samples(), fn(b) {
      n.i32_add(a, b) |> should.equal(n.i32_add(b, a))
      n.i32_mul(a, b) |> should.equal(n.i32_mul(b, a))
    })
  })
}

pub fn add_negate_inverse_test() {
  // a + (0 - a) == 0 (mod 2^N), for both widths.
  list.each(i32_samples(), fn(a) {
    n.i32_add(a, n.i32_sub(0, a)) |> should.equal(0)
  })
  list.each(i64_samples(), fn(a) {
    n.i64_add(a, n.i64_sub(0, a)) |> should.equal(0)
  })
}

// ───────────────────────────── bitwise ─────────────────────────────

pub fn bitwise_test() {
  n.i32_and(0xFF00FF00, 0x0F0F0F0F) |> should.equal(0x0F000F00)
  n.i32_or(0xFF00FF00, 0x0F0F0F0F) |> should.equal(0xFF0FFF0F)
  n.i32_xor(0xFF00FF00, 0x0F0F0F0F) |> should.equal(0xF00FF00F)
  // results stay within [0, 2^N) even with the top bit set
  n.i64_and(0x8000000000000000, 0xFFFFFFFFFFFFFFFF)
  |> should.equal(0x8000000000000000)
}

// ───────────────────────────── shifts / rotates ─────────────────────────────

pub fn shl_count_masking_test() {
  // count taken mod N: shift by N is identity, by N+1 equals by 1.
  list.each(i32_samples(), fn(a) {
    n.i32_shl(a, 32) |> should.equal(a)
    n.i32_shl(a, 33) |> should.equal(n.i32_shl(a, 1))
  })
  list.each(i64_samples(), fn(a) {
    n.i64_shl(a, 64) |> should.equal(a)
    n.i64_shl(a, 65) |> should.equal(n.i64_shl(a, 1))
  })
}

pub fn rotl_count_masking_test() {
  list.each(i32_samples(), fn(a) {
    n.i32_rotl(a, 32) |> should.equal(a)
    n.i32_rotr(a, 32) |> should.equal(a)
    n.i32_rotl(a, 0) |> should.equal(a)
  })
  list.each(i64_samples(), fn(a) { n.i64_rotl(a, 64) |> should.equal(a) })
}

pub fn shr_s_sign_fill_test() {
  // arithmetic shift fills with the sign bit
  n.i32_shr_s(0x80000000, 1) |> should.equal(0xC0000000)
  // logical shift fills with zero
  n.i32_shr_u(0x80000000, 1) |> should.equal(0x40000000)
  // -1 >> any == -1
  n.i32_shr_s(0xFFFFFFFF, 5) |> should.equal(0xFFFFFFFF)
  n.i64_shr_s(0x8000000000000000, 1) |> should.equal(0xC000000000000000)
  n.i64_shr_u(0x8000000000000000, 1) |> should.equal(0x4000000000000000)
}

pub fn shl_test() {
  n.i32_shl(1, 31) |> should.equal(0x80000000)
  n.i32_shl(0xFFFFFFFF, 4) |> should.equal(0xFFFFFFF0)
}

pub fn rotl_rotr_inverse_test() {
  list.each(i32_samples(), fn(a) {
    int_range(0, 31)
    |> list.each(fn(k) {
      n.i32_rotl(n.i32_rotr(a, k), k) |> should.equal(a)
      // rotl(a, k) == rotr(a, N - k)
      n.i32_rotl(a, k) |> should.equal(n.i32_rotr(a, 32 - k))
    })
  })
}

// ───────────────────────────── clz / ctz / popcnt ─────────────────────────────

pub fn clz_ctz_popcnt_edges_test() {
  n.i32_clz(0) |> should.equal(32)
  n.i32_ctz(0) |> should.equal(32)
  n.i32_popcnt(0) |> should.equal(0)
  n.i64_clz(0) |> should.equal(64)
  n.i64_ctz(0) |> should.equal(64)
  n.i32_clz(1) |> should.equal(31)
  n.i32_ctz(0x80000000) |> should.equal(31)
  n.i32_clz(0x80000000) |> should.equal(0)
  n.i32_popcnt(0xFFFFFFFF) |> should.equal(32)
  n.i64_popcnt(0xFFFFFFFFFFFFFFFF) |> should.equal(64)
}

pub fn popcnt_complement_law_test() {
  // popcnt(a) + popcnt(~a) == N
  list.each(i32_samples(), fn(a) {
    let comp = 0xFFFFFFFF - a
    { n.i32_popcnt(a) + n.i32_popcnt(comp) } |> should.equal(32)
  })
  list.each(i64_samples(), fn(a) {
    let comp = 0xFFFFFFFFFFFFFFFF - a
    { n.i64_popcnt(a) + n.i64_popcnt(comp) } |> should.equal(64)
  })
}

// ───────────────────────────── comparisons ─────────────────────────────

pub fn eqz_eq_ne_test() {
  n.i32_eqz(0) |> should.equal(1)
  n.i32_eqz(0x80000000) |> should.equal(0)
  n.i32_eq(0x80000000, 0x80000000) |> should.equal(1)
  n.i32_ne(0x80000000, 0x80000000) |> should.equal(0)
}

pub fn signed_vs_unsigned_compare_test() {
  // 0x80000000 is INT_MIN (signed) but a large value (unsigned).
  n.i32_lt_s(0x80000000, 1) |> should.equal(1)
  n.i32_lt_u(0x80000000, 1) |> should.equal(0)
  n.i32_gt_s(0x80000000, 1) |> should.equal(0)
  n.i32_gt_u(0x80000000, 1) |> should.equal(1)
  // -1 (0xFFFFFFFF) vs 0
  n.i32_lt_s(0xFFFFFFFF, 0) |> should.equal(1)
  n.i32_lt_u(0xFFFFFFFF, 0) |> should.equal(0)
  n.i32_le_s(0x80000000, 0x80000000) |> should.equal(1)
  n.i32_ge_s(0x7FFFFFFF, 0x80000000) |> should.equal(1)
  // i64 comparisons return an i32 0/1
  n.i64_lt_s(0x8000000000000000, 1) |> should.equal(1)
  n.i64_lt_u(0x8000000000000000, 1) |> should.equal(0)
}

// ───────────────────────────── div / rem traps ─────────────────────────────

pub fn div_s_overflow_traps_test() {
  // INT_MIN / -1 overflows the signed range → IntOverflow (NOT a wraparound).
  n.i32_div_s(0x80000000, 0xFFFFFFFF) |> should.equal(Error(IntOverflow))
  n.i64_div_s(0x8000000000000000, 0xFFFFFFFFFFFFFFFF)
  |> should.equal(Error(IntOverflow))
}

pub fn rem_s_no_overflow_trap_test() {
  // INT_MIN % -1 == 0 — rem_s does NOT trap on the div_s overflow case.
  n.i32_rem_s(0x80000000, 0xFFFFFFFF) |> should.equal(Ok(0))
  n.i64_rem_s(0x8000000000000000, 0xFFFFFFFFFFFFFFFF) |> should.equal(Ok(0))
}

pub fn div_rem_zero_traps_test() {
  // All four trap on divisor 0 (proves Gleam's TOTAL `/` is not used — that returns 0).
  n.i32_div_s(5, 0) |> should.equal(Error(IntDivByZero))
  n.i32_div_u(5, 0) |> should.equal(Error(IntDivByZero))
  n.i32_rem_s(5, 0) |> should.equal(Error(IntDivByZero))
  n.i32_rem_u(5, 0) |> should.equal(Error(IntDivByZero))
  n.i64_div_s(5, 0) |> should.equal(Error(IntDivByZero))
  n.i64_div_u(5, 0) |> should.equal(Error(IntDivByZero))
  n.i64_rem_s(5, 0) |> should.equal(Error(IntDivByZero))
  n.i64_rem_u(5, 0) |> should.equal(Error(IntDivByZero))
  // INT_MIN / 0 traps on zero, not overflow
  n.i32_div_s(0x80000000, 0) |> should.equal(Error(IntDivByZero))
}

pub fn div_s_truncates_toward_zero_test() {
  // -7 / 2 == -3 (toward zero), encoded as the i32 bit pattern of -3.
  n.i32_div_s(n.i32_sub(0, 7), 2) |> should.equal(Ok(n.i32_sub(0, 3)))
  // 7 / -2 == -3
  n.i32_div_s(7, n.i32_sub(0, 2)) |> should.equal(Ok(n.i32_sub(0, 3)))
  // -7 % 2 == -1 (sign of dividend)
  n.i32_rem_s(n.i32_sub(0, 7), 2) |> should.equal(Ok(n.i32_sub(0, 1)))
  // 7 % -2 == 1
  n.i32_rem_s(7, n.i32_sub(0, 2)) |> should.equal(Ok(1))
}

pub fn div_u_test() {
  n.i32_div_u(0xFFFFFFFF, 2) |> should.equal(Ok(0x7FFFFFFF))
  n.i32_rem_u(0xFFFFFFFF, 2) |> should.equal(Ok(1))
}

pub fn division_identity_law_test() {
  // For every non-trapping signed pair: q*b + r == a (mod 2^N).
  let pairs = [
    #(7, 2),
    #(0xFFFFFFF9, 2),
    // -7, 2
    #(0xFFFFFFF9, 0xFFFFFFFE),
    // -7, -2
    #(0x80000000, 2),
    #(0x80000000, 3),
    #(0x7FFFFFFF, 0xFFFFFFFF),
    #(0xDEADBEEF, 0x1234),
  ]
  list.each(pairs, fn(p) {
    let #(a, b) = p
    let assert Ok(q) = n.i32_div_s(a, b)
    let assert Ok(r) = n.i32_rem_s(a, b)
    n.i32_add(n.i32_mul(q, b), r) |> should.equal(a)
  })
  // Unsigned identity too.
  list.each(pairs, fn(p) {
    let #(a, b) = p
    let assert Ok(q) = n.i32_div_u(a, b)
    let assert Ok(r) = n.i32_rem_u(a, b)
    n.i32_add(n.i32_mul(q, b), r) |> should.equal(a)
  })
}

// ───────────────────────────── conversions ─────────────────────────────

pub fn wrap_i64_test() {
  n.i32_wrap_i64(0x1_0000_00AB) |> should.equal(0x000000AB)
  n.i32_wrap_i64(0xFFFFFFFFFFFFFFFF) |> should.equal(0xFFFFFFFF)
}

pub fn extend_i32_test() {
  // zero-extend: identity
  n.i64_extend_i32_u(0x80000000) |> should.equal(0x80000000)
  // sign-extend: top bit propagates into the high 32 bits
  n.i64_extend_i32_s(0x80000000) |> should.equal(0xFFFFFFFF80000000)
  n.i64_extend_i32_s(0x7FFFFFFF) |> should.equal(0x000000007FFFFFFF)
  n.i64_extend_i32_s(0xFFFFFFFF) |> should.equal(0xFFFFFFFFFFFFFFFF)
}

pub fn extend_k_s_test() {
  n.i32_extend8_s(0x80) |> should.equal(0xFFFFFF80)
  n.i32_extend8_s(0x7F) |> should.equal(0x0000007F)
  n.i32_extend16_s(0x8000) |> should.equal(0xFFFF8000)
  n.i64_extend8_s(0x80) |> should.equal(0xFFFFFFFFFFFFFF80)
  n.i64_extend16_s(0x8000) |> should.equal(0xFFFFFFFFFFFF8000)
  n.i64_extend32_s(0x80000000) |> should.equal(0xFFFFFFFF80000000)
  n.i64_extend32_s(0x7FFFFFFF) |> should.equal(0x000000007FFFFFFF)
}

pub fn reinterpret_roundtrip_test() {
  list.each(i32_samples(), fn(x) {
    n.f32_reinterpret_i32(n.i32_reinterpret_f32(x)) |> should.equal(x)
    n.i32_reinterpret_f32(n.f32_reinterpret_i32(x)) |> should.equal(x)
  })
  list.each(i64_samples(), fn(x) {
    n.f64_reinterpret_i64(n.i64_reinterpret_f64(x)) |> should.equal(x)
  })
}

// ───────────────────────────── float: finite arithmetic ─────────────────────────────

pub fn f64_finite_arith_test() {
  // bit-exact against the native-double oracle on the finite path
  n.f64_add(f64_bits(1.0), f64_bits(2.0)) |> should.equal(f64_bits(3.0))
  n.f64_sub(f64_bits(3.0), f64_bits(1.0)) |> should.equal(f64_bits(2.0))
  n.f64_mul(f64_bits(2.0), f64_bits(3.0)) |> should.equal(f64_bits(6.0))
  n.f64_div(f64_bits(1.0), f64_bits(4.0)) |> should.equal(f64_bits(0.25))
  // the classic rounding case must match IEEE round-to-nearest exactly
  n.f64_add(f64_bits(0.1), f64_bits(0.2))
  |> should.equal(f64_bits(0.1 +. 0.2))
  n.f64_mul(f64_bits(-2.0), f64_bits(3.0)) |> should.equal(f64_bits(-6.0))
}

pub fn f32_finite_arith_test() {
  n.f32_add(f32_bits(1.0), f32_bits(2.0)) |> should.equal(f32_bits(3.0))
  n.f32_sub(f32_bits(3.0), f32_bits(1.0)) |> should.equal(f32_bits(2.0))
  n.f32_mul(f32_bits(2.0), f32_bits(3.0)) |> should.equal(f32_bits(6.0))
  n.f32_div(f32_bits(1.0), f32_bits(2.0)) |> should.equal(f32_bits(0.5))
  // f32 result is rounded to single (1.0 is 0x3F800000, 2.0 is 0x40000000)
  n.f32_add(0x3F800000, 0x3F800000) |> should.equal(0x40000000)
}

pub fn f64_signed_zero_results_test() {
  // a - a == +0; +0 + +0 == +0; -0 + -0 == -0
  n.f64_sub(f64_bits(1.0), f64_bits(1.0)) |> should.equal(f64_pos_zero)
  n.f64_add(f64_pos_zero, f64_neg_zero) |> should.equal(f64_pos_zero)
  n.f64_add(f64_neg_zero, f64_neg_zero) |> should.equal(f64_neg_zero)
  // 0 + x == x
  n.f64_add(f64_pos_zero, f64_bits(5.0)) |> should.equal(f64_bits(5.0))
}

// ───────────────────────────── float: NaN / Inf rules ─────────────────────────────

pub fn f64_nan_canonical_test() {
  // (NaN op x) and (x op NaN) → positive canonical NaN, for every op.
  let x = f64_bits(1.5)
  let ops = [n.f64_add, n.f64_sub, n.f64_mul, n.f64_div, n.f64_min, n.f64_max]
  list.each(ops, fn(op) {
    op(f64_other_nan, x) |> should.equal(f64_canon_nan)
    op(x, f64_other_nan) |> should.equal(f64_canon_nan)
    op(f64_canon_nan, x) |> should.equal(f64_canon_nan)
  })
}

pub fn f32_nan_canonical_test() {
  let x = f32_bits(1.5)
  let ops = [n.f32_add, n.f32_sub, n.f32_mul, n.f32_div, n.f32_min, n.f32_max]
  list.each(ops, fn(op) {
    op(f32_other_nan, x) |> should.equal(f32_canon_nan)
    op(x, f32_other_nan) |> should.equal(f32_canon_nan)
  })
}

pub fn f64_inf_rules_test() {
  // Inf + (-Inf) → NaN; Inf + Inf → Inf
  n.f64_add(f64_pos_inf, f64_neg_inf) |> should.equal(f64_canon_nan)
  n.f64_add(f64_pos_inf, f64_pos_inf) |> should.equal(f64_pos_inf)
  // x / 0 → signed Inf; 0/0 → NaN; Inf/Inf → NaN
  n.f64_div(f64_bits(1.0), f64_pos_zero) |> should.equal(f64_pos_inf)
  n.f64_div(f64_bits(-1.0), f64_pos_zero) |> should.equal(f64_neg_inf)
  n.f64_div(f64_bits(1.0), f64_neg_zero) |> should.equal(f64_neg_inf)
  n.f64_div(f64_pos_zero, f64_pos_zero) |> should.equal(f64_canon_nan)
  n.f64_div(f64_pos_inf, f64_pos_inf) |> should.equal(f64_canon_nan)
  // 0 * Inf → NaN
  n.f64_mul(f64_pos_zero, f64_pos_inf) |> should.equal(f64_canon_nan)
  // Inf * finite → signed Inf (-Inf * +2.0 == -Inf; -Inf * -2.0 == +Inf)
  n.f64_mul(f64_neg_inf, f64_bits(2.0)) |> should.equal(f64_neg_inf)
  n.f64_mul(f64_neg_inf, f64_bits(-2.0)) |> should.equal(f64_pos_inf)
}

pub fn f64_overflow_to_inf_test() {
  // The finite path must yield ±Inf (not a `badarith` crash) on overflow.
  n.f64_mul(f64_max, f64_bits(2.0)) |> should.equal(f64_pos_inf)
  n.f64_mul(f64_max, f64_bits(-2.0)) |> should.equal(f64_neg_inf)
  n.f64_add(f64_max, f64_max) |> should.equal(f64_pos_inf)
  // MAX / 0.5 == MAX * 2 → overflow
  n.f64_div(f64_max, f64_bits(0.5)) |> should.equal(f64_pos_inf)
  // MAX - (-MAX) == 2*MAX → overflow
  n.f64_sub(f64_max, f64_bits(0.0 -. 1.7976931348623157e308))
  |> should.equal(f64_pos_inf)
}

pub fn f32_overflow_to_inf_test() {
  // f32 result saturates to Inf via the 32-bit round-trip.
  n.f32_mul(f32_max, f32_bits(2.0)) |> should.equal(f32_pos_inf)
  n.f32_mul(f32_max, f32_bits(-2.0)) |> should.equal(f32_neg_inf)
}

// ───────────────────────────── float: min / max ─────────────────────────────

pub fn f32_min_max_signed_zero_test() {
  n.f32_min(f32_pos_zero, f32_neg_zero) |> should.equal(f32_neg_zero)
  n.f32_min(f32_neg_zero, f32_pos_zero) |> should.equal(f32_neg_zero)
  n.f32_max(f32_pos_zero, f32_neg_zero) |> should.equal(f32_pos_zero)
  n.f32_max(f32_neg_zero, f32_pos_zero) |> should.equal(f32_pos_zero)
}

pub fn f64_min_max_signed_zero_test() {
  n.f64_min(f64_pos_zero, f64_neg_zero) |> should.equal(f64_neg_zero)
  n.f64_max(f64_pos_zero, f64_neg_zero) |> should.equal(f64_pos_zero)
}

pub fn f64_min_max_values_test() {
  n.f64_min(f64_bits(2.0), f64_bits(5.0)) |> should.equal(f64_bits(2.0))
  n.f64_max(f64_bits(2.0), f64_bits(5.0)) |> should.equal(f64_bits(5.0))
  n.f64_min(f64_bits(-3.0), f64_bits(1.0)) |> should.equal(f64_bits(-3.0))
  // Inf handling
  n.f64_min(f64_neg_inf, f64_bits(0.0)) |> should.equal(f64_neg_inf)
  n.f64_max(f64_pos_inf, f64_bits(0.0)) |> should.equal(f64_pos_inf)
  n.f64_min(f64_pos_inf, f64_bits(7.0)) |> should.equal(f64_bits(7.0))
  // NaN → canonical NaN
  n.f64_min(f64_other_nan, f64_bits(1.0)) |> should.equal(f64_canon_nan)
  // one operand zero, one nonzero
  n.f64_min(f64_pos_zero, f64_bits(1.0)) |> should.equal(f64_pos_zero)
  n.f64_min(f64_neg_zero, f64_bits(1.0)) |> should.equal(f64_neg_zero)
}

// ───────────────────────────── float: trunc_sat ─────────────────────────────

pub fn trunc_sat_s_test() {
  n.i32_trunc_sat_f64_s(f64_bits(3.7)) |> should.equal(3)
  // truncate toward zero, then two's-complement encode
  n.i32_trunc_sat_f64_s(f64_bits(-3.7)) |> should.equal(n.i32_sub(0, 3))
  n.i32_trunc_sat_f64_s(f64_bits(0.9)) |> should.equal(0)
  n.i32_trunc_sat_f64_s(f64_bits(-0.9)) |> should.equal(0)
  // saturation at the signed bounds
  n.i32_trunc_sat_f64_s(f64_pos_inf) |> should.equal(0x7FFFFFFF)
  n.i32_trunc_sat_f64_s(f64_neg_inf) |> should.equal(0x80000000)
  n.i32_trunc_sat_f64_s(f64_canon_nan) |> should.equal(0)
  // out of range finite clamps
  n.i32_trunc_sat_f64_s(f64_bits(2_147_483_648.0)) |> should.equal(0x7FFFFFFF)
  n.i32_trunc_sat_f64_s(f64_bits(-3_000_000_000.0)) |> should.equal(0x80000000)
  // i64 bounds
  n.i64_trunc_sat_f64_s(f64_pos_inf) |> should.equal(0x7FFFFFFFFFFFFFFF)
  n.i64_trunc_sat_f64_s(f64_neg_inf) |> should.equal(0x8000000000000000)
  // f32 source
  n.i32_trunc_sat_f32_s(f32_bits(3.5)) |> should.equal(3)
}

pub fn trunc_sat_u_test() {
  n.i32_trunc_sat_f64_u(f64_canon_nan) |> should.equal(0)
  n.i32_trunc_sat_f64_u(f64_bits(-1.0)) |> should.equal(0)
  n.i32_trunc_sat_f64_u(f64_neg_inf) |> should.equal(0)
  n.i32_trunc_sat_f64_u(f64_pos_inf) |> should.equal(0xFFFFFFFF)
  n.i32_trunc_sat_f64_u(f64_bits(3.9)) |> should.equal(3)
  // out of range positive clamps to UINT_MAX
  n.i32_trunc_sat_f64_u(f64_bits(4_294_967_296.0)) |> should.equal(0xFFFFFFFF)
  n.i64_trunc_sat_f64_u(f64_pos_inf) |> should.equal(0xFFFFFFFFFFFFFFFF)
  n.i64_trunc_sat_f64_u(f64_bits(-5.0)) |> should.equal(0)
  // a value above i32 but within u32 (3 billion)
  n.i32_trunc_sat_f64_u(f64_bits(3_000_000_000.0))
  |> should.equal(3_000_000_000)
}

// ───────────────────────────── float: reinterpret with constants ─────────────────────────────

pub fn float_const_reinterpret_test() {
  // 1.0_f64 reinterprets to the integer 0x3FF0000000000000 (no value change).
  n.i64_reinterpret_f64(f64_bits(1.0)) |> should.equal(0x3FF0000000000000)
  n.f64_reinterpret_i64(0x3FF0000000000000) |> should.equal(f64_bits(1.0))
  n.i32_reinterpret_f32(f32_bits(1.0)) |> should.equal(0x3F800000)
}
