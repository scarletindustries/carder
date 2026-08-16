//// Spec-corner tests for the Phase-2 `rt_num` float surface (unit 06): the unary ops,
//// copysign, the six comparisons, the trapping float→int truncations, the int→float
//// conversions, and demote/promote.
////
//// Assertions target the WebAssembly numerics spec
//// (<https://webassembly.github.io/spec/core/exec/numerics.html>) and the high-level
//// §9.1 fidelity contract — NOT whatever the implementation happens to emit. Floats are
//// raw IEEE-754 bit patterns in `Int`s, so every expectation is stated as the exact bit
//// pattern the spec requires (including signed-zero results, which are asserted by bit
//// pattern rather than `==.`, since `-0.0 ==. +0.0` is `True`).

import carder/ir.{IntOverflow, InvalidConversionToInteger}
import carder/runtime/rt_num as n
import gleeunit/should

// ───────────────────────────── helpers ─────────────────────────────

/// Bit pattern of a finite native double (test-side literal builder).
fn f64_bits(f: Float) -> Int {
  let assert <<b:size(64)>> = <<f:float-size(64)>>
  b
}

/// Bit pattern of a native double rounded to binary32 (test-side literal builder).
fn f32_bits(f: Float) -> Int {
  let assert <<b:size(32)>> = <<f:float-size(32)>>
  b
}

// f32 special bit patterns.
const f32_pos_zero = 0x00000000

const f32_neg_zero = 0x80000000

const f32_pos_inf = 0x7F800000

const f32_neg_inf = 0xFF800000

const f32_canon_nan = 0x7FC00000

// A non-canonical f32 NaN (payload 0x200000): every nondeterministic-NaN op canonicalizes
// it, but abs/neg/copysign must preserve it.
const f32_payload_nan = 0x7FA00000

// f64 special bit patterns.
const f64_pos_zero = 0x0000000000000000

const f64_neg_zero = 0x8000000000000000

const f64_pos_inf = 0x7FF0000000000000

const f64_neg_inf = 0xFFF0000000000000

const f64_canon_nan = 0x7FF8000000000000

const f64_payload_nan = 0x7FF4000000000000

// ───────────────────── nearest: round-to-nearest, ties-to-EVEN ─────────────────────
// Spec/§9.1: fnearest is ties-to-even (NOT erlang:round/1, which is ties-away-from-zero).
// nearest(2.5)=2, nearest(3.5)=4, nearest(-2.5)=-2, nearest(0.5)=+0, nearest(-0.5)=-0.

pub fn f32_nearest_ties_to_even_test() {
  n.f32_nearest(f32_bits(2.5)) |> should.equal(f32_bits(2.0))
  n.f32_nearest(f32_bits(3.5)) |> should.equal(f32_bits(4.0))
  n.f32_nearest(f32_bits(-2.5)) |> should.equal(f32_bits(-2.0))
  n.f32_nearest(f32_bits(1.5)) |> should.equal(f32_bits(2.0))
  n.f32_nearest(f32_bits(-1.5)) |> should.equal(f32_bits(-2.0))
}

pub fn f64_nearest_ties_to_even_test() {
  n.f64_nearest(f64_bits(2.5)) |> should.equal(f64_bits(2.0))
  n.f64_nearest(f64_bits(3.5)) |> should.equal(f64_bits(4.0))
  n.f64_nearest(f64_bits(-2.5)) |> should.equal(f64_bits(-2.0))
  n.f64_nearest(f64_bits(1.5)) |> should.equal(f64_bits(2.0))
  n.f64_nearest(f64_bits(-1.5)) |> should.equal(f64_bits(-2.0))
}

pub fn f32_nearest_signed_zero_test() {
  // Bit-exact: nearest(0.5)=+0, nearest(-0.5)=-0 (the operand's sign).
  n.f32_nearest(f32_bits(0.5)) |> should.equal(f32_pos_zero)
  n.f32_nearest(f32_bits(-0.5)) |> should.equal(f32_neg_zero)
  n.f32_nearest(f32_bits(0.3)) |> should.equal(f32_pos_zero)
  n.f32_nearest(f32_bits(-0.3)) |> should.equal(f32_neg_zero)
}

pub fn f64_nearest_signed_zero_test() {
  n.f64_nearest(f64_bits(0.5)) |> should.equal(f64_pos_zero)
  n.f64_nearest(f64_bits(-0.5)) |> should.equal(f64_neg_zero)
}

pub fn nearest_special_passthrough_test() {
  // NaN→canonical; ±Inf and ±0 unchanged.
  n.f32_nearest(f32_payload_nan) |> should.equal(f32_canon_nan)
  n.f32_nearest(f32_pos_inf) |> should.equal(f32_pos_inf)
  n.f32_nearest(f32_neg_inf) |> should.equal(f32_neg_inf)
  n.f32_nearest(f32_neg_zero) |> should.equal(f32_neg_zero)
  n.f64_nearest(f64_payload_nan) |> should.equal(f64_canon_nan)
  n.f64_nearest(f64_pos_inf) |> should.equal(f64_pos_inf)
}

// ───────────────────── ceil / floor / trunc ─────────────────────

pub fn f32_ceil_test() {
  n.f32_ceil(f32_bits(1.5)) |> should.equal(f32_bits(2.0))
  n.f32_ceil(f32_bits(-1.5)) |> should.equal(f32_bits(-1.0))
  // ceil(-0.5) = -0 (toward +∞ keeps the operand's sign on a zero result).
  n.f32_ceil(f32_bits(-0.5)) |> should.equal(f32_neg_zero)
  n.f32_ceil(f32_pos_inf) |> should.equal(f32_pos_inf)
  n.f32_ceil(f32_payload_nan) |> should.equal(f32_canon_nan)
}

pub fn f32_floor_test() {
  n.f32_floor(f32_bits(1.5)) |> should.equal(f32_bits(1.0))
  n.f32_floor(f32_bits(-1.5)) |> should.equal(f32_bits(-2.0))
  // floor(0.5) = +0.
  n.f32_floor(f32_bits(0.5)) |> should.equal(f32_pos_zero)
  n.f32_floor(f32_neg_inf) |> should.equal(f32_neg_inf)
}

pub fn f32_trunc_test() {
  n.f32_trunc(f32_bits(1.5)) |> should.equal(f32_bits(1.0))
  n.f32_trunc(f32_bits(-1.5)) |> should.equal(f32_bits(-1.0))
  // trunc(-0.7) = -0, trunc(0.7) = +0 (sign preserved).
  n.f32_trunc(f32_bits(-0.7)) |> should.equal(f32_neg_zero)
  n.f32_trunc(f32_bits(0.7)) |> should.equal(f32_pos_zero)
}

pub fn f64_ceil_floor_trunc_test() {
  n.f64_ceil(f64_bits(1.5)) |> should.equal(f64_bits(2.0))
  n.f64_ceil(f64_bits(-0.5)) |> should.equal(f64_neg_zero)
  n.f64_floor(f64_bits(1.5)) |> should.equal(f64_bits(1.0))
  n.f64_floor(f64_bits(0.5)) |> should.equal(f64_pos_zero)
  n.f64_trunc(f64_bits(-1.9)) |> should.equal(f64_bits(-1.0))
  n.f64_trunc(f64_payload_nan) |> should.equal(f64_canon_nan)
  n.f64_ceil(f64_neg_zero) |> should.equal(f64_neg_zero)
}

// ───────────────────── sqrt ─────────────────────

pub fn f32_sqrt_test() {
  n.f32_sqrt(f32_bits(4.0)) |> should.equal(f32_bits(2.0))
  n.f32_sqrt(f32_bits(9.0)) |> should.equal(f32_bits(3.0))
  n.f32_sqrt(f32_bits(0.25)) |> should.equal(f32_bits(0.5))
  // sqrt(-1) and sqrt(-Inf) → canonical NaN; sqrt(NaN payload) → canonical.
  n.f32_sqrt(f32_bits(-1.0)) |> should.equal(f32_canon_nan)
  n.f32_sqrt(f32_neg_inf) |> should.equal(f32_canon_nan)
  n.f32_sqrt(f32_payload_nan) |> should.equal(f32_canon_nan)
  // sqrt(+Inf)=+Inf; sqrt(±0) = same signed zero (bit-exact).
  n.f32_sqrt(f32_pos_inf) |> should.equal(f32_pos_inf)
  n.f32_sqrt(f32_neg_zero) |> should.equal(f32_neg_zero)
  n.f32_sqrt(f32_pos_zero) |> should.equal(f32_pos_zero)
}

pub fn f64_sqrt_test() {
  n.f64_sqrt(f64_bits(4.0)) |> should.equal(f64_bits(2.0))
  n.f64_sqrt(f64_bits(9.0)) |> should.equal(f64_bits(3.0))
  n.f64_sqrt(f64_bits(-1.0)) |> should.equal(f64_canon_nan)
  n.f64_sqrt(f64_neg_inf) |> should.equal(f64_canon_nan)
  n.f64_sqrt(f64_pos_inf) |> should.equal(f64_pos_inf)
  n.f64_sqrt(f64_neg_zero) |> should.equal(f64_neg_zero)
  // Correctly-rounded √2 (the spec mandates round-to-nearest-ties-to-even):
  // the canonical binary64 value of √2 is 0x3FF6A09E667F3BCD.
  n.f64_sqrt(f64_bits(2.0)) |> should.equal(0x3FF6A09E667F3BCD)
}

// ───────────────────── abs / neg / copysign (payload-preserving) ─────────────────────
// §9.1 / spec: abs/neg/copysign are deterministic sign-bit ops and DO NOT canonicalize
// NaN — the conformance suite asserts payload preservation.

pub fn f32_abs_test() {
  n.f32_abs(f32_bits(-3.0)) |> should.equal(f32_bits(3.0))
  n.f32_abs(f32_bits(3.0)) |> should.equal(f32_bits(3.0))
  n.f32_abs(f32_neg_zero) |> should.equal(f32_pos_zero)
  n.f32_abs(f32_neg_inf) |> should.equal(f32_pos_inf)
  // abs of a negative payload NaN clears the sign but PRESERVES the payload.
  n.f32_abs(0xFFA00000) |> should.equal(f32_payload_nan)
  n.f32_abs(f32_payload_nan) |> should.equal(f32_payload_nan)
}

pub fn f32_neg_test() {
  n.f32_neg(f32_bits(3.0)) |> should.equal(f32_bits(-3.0))
  n.f32_neg(f32_bits(-3.0)) |> should.equal(f32_bits(3.0))
  n.f32_neg(f32_pos_zero) |> should.equal(f32_neg_zero)
  n.f32_neg(f32_pos_inf) |> should.equal(f32_neg_inf)
  // neg flips the sign of a NaN, preserving the payload (NOT canonical).
  n.f32_neg(f32_payload_nan) |> should.equal(0xFFA00000)
}

pub fn f64_abs_neg_test() {
  n.f64_abs(f64_bits(-3.0)) |> should.equal(f64_bits(3.0))
  n.f64_abs(f64_neg_zero) |> should.equal(f64_pos_zero)
  n.f64_neg(f64_bits(3.0)) |> should.equal(f64_bits(-3.0))
  n.f64_neg(f64_neg_zero) |> should.equal(f64_pos_zero)
  n.f64_abs(f64_payload_nan) |> should.equal(f64_payload_nan)
  n.f64_neg(f64_payload_nan) |> should.equal(0xFFF4000000000000)
}

pub fn f32_copysign_test() {
  n.f32_copysign(f32_bits(3.0), f32_bits(-2.0)) |> should.equal(f32_bits(-3.0))
  n.f32_copysign(f32_bits(-3.0), f32_bits(2.0)) |> should.equal(f32_bits(3.0))
  // sign of b drawn from a signed zero.
  n.f32_copysign(f32_bits(3.0), f32_neg_zero) |> should.equal(f32_bits(-3.0))
  n.f32_copysign(f32_bits(-3.0), f32_pos_zero) |> should.equal(f32_bits(3.0))
  // payload of a preserved, sign taken from b (no canonicalization).
  n.f32_copysign(f32_payload_nan, f32_bits(-1.0)) |> should.equal(0xFFA00000)
}

pub fn f64_copysign_test() {
  n.f64_copysign(f64_bits(3.0), f64_bits(-2.0)) |> should.equal(f64_bits(-3.0))
  n.f64_copysign(f64_bits(-3.0), f64_bits(2.0)) |> should.equal(f64_bits(3.0))
  n.f64_copysign(f64_payload_nan, f64_bits(-1.0))
  |> should.equal(0xFFF4000000000000)
}

// ───────────────────── comparisons → i32 0/1 ─────────────────────
// Spec: any NaN operand → eq/lt/gt/le/ge are 0 (false) and ne is 1 (true);
// -0.0 == +0.0; +Inf > finite > -Inf.

pub fn f32_compare_nan_test() {
  let one = f32_bits(1.0)
  n.f32_eq(f32_payload_nan, one) |> should.equal(0)
  n.f32_lt(f32_payload_nan, one) |> should.equal(0)
  n.f32_gt(f32_payload_nan, one) |> should.equal(0)
  n.f32_le(f32_payload_nan, one) |> should.equal(0)
  n.f32_ge(f32_payload_nan, one) |> should.equal(0)
  n.f32_ne(f32_payload_nan, one) |> should.equal(1)
  // canonical NaN on the right too.
  n.f32_eq(one, f32_canon_nan) |> should.equal(0)
  n.f32_ne(one, f32_canon_nan) |> should.equal(1)
}

pub fn f32_compare_signed_zero_test() {
  // -0.0 and +0.0 compare equal.
  n.f32_eq(f32_neg_zero, f32_pos_zero) |> should.equal(1)
  n.f32_lt(f32_neg_zero, f32_pos_zero) |> should.equal(0)
  n.f32_ne(f32_neg_zero, f32_pos_zero) |> should.equal(0)
  n.f32_le(f32_neg_zero, f32_pos_zero) |> should.equal(1)
  n.f32_ge(f32_neg_zero, f32_pos_zero) |> should.equal(1)
}

pub fn f32_compare_ordered_test() {
  n.f32_lt(f32_bits(1.0), f32_bits(2.0)) |> should.equal(1)
  n.f32_gt(f32_bits(2.0), f32_bits(1.0)) |> should.equal(1)
  n.f32_le(f32_bits(2.0), f32_bits(2.0)) |> should.equal(1)
  n.f32_ge(f32_bits(2.0), f32_bits(2.0)) |> should.equal(1)
  // ±Inf ordering, handled WITHOUT decoding Inf bits.
  n.f32_lt(f32_neg_inf, f32_pos_inf) |> should.equal(1)
  n.f32_gt(f32_pos_inf, f32_bits(1.0e30)) |> should.equal(1)
  n.f32_lt(f32_neg_inf, f32_bits(-1.0e30)) |> should.equal(1)
}

pub fn f64_compare_test() {
  let one = f64_bits(1.0)
  n.f64_eq(f64_payload_nan, one) |> should.equal(0)
  n.f64_ne(f64_payload_nan, one) |> should.equal(1)
  n.f64_ge(f64_payload_nan, one) |> should.equal(0)
  n.f64_eq(f64_neg_zero, f64_pos_zero) |> should.equal(1)
  n.f64_lt(f64_neg_zero, f64_pos_zero) |> should.equal(0)
  n.f64_lt(f64_neg_inf, f64_pos_inf) |> should.equal(1)
  n.f64_gt(f64_pos_inf, one) |> should.equal(1)
  n.f64_le(f64_bits(2.0), f64_bits(2.0)) |> should.equal(1)
}

// ───────────────────── trapping float→int truncation ─────────────────────
// Two DISTINCT traps (per `exec/numerics` + the spec test suite): ONLY NaN traps
// InvalidConversionToInteger; ±Inf traps IntOverflow (like any out-of-range value), since
// `trunc(±inf)` is simply outside every integer range. Ranges are exact via the bignum
// truncation, so the boundary is precise.

pub fn i32_trunc_f32_s_boundaries_test() {
  // 2^31 is exactly representable in f32 and is out of [-2^31, 2^31-1] → overflow.
  n.i32_trunc_f32_s(f32_bits(2_147_483_648.0))
  |> should.equal(Error(IntOverflow))
  // The largest f32 strictly below 2^31 (0x4EFFFFFF = 2147483520) is in range.
  n.i32_trunc_f32_s(f32_bits(2_147_483_520.0))
  |> should.equal(Ok(2_147_483_520))
  // -2^31 (INT_MIN) is exactly representable and in range → 0x80000000.
  n.i32_trunc_f32_s(f32_bits(-2_147_483_648.0))
  |> should.equal(Ok(0x80000000))
  // -1.0 truncates to -1 = the unsigned bit pattern 0xFFFFFFFF.
  n.i32_trunc_f32_s(f32_bits(-1.0)) |> should.equal(Ok(0xFFFFFFFF))
  // NaN → invalid conversion; ±Inf → integer overflow (the spec's distinct messages).
  n.i32_trunc_f32_s(f32_payload_nan)
  |> should.equal(Error(InvalidConversionToInteger))
  n.i32_trunc_f32_s(f32_pos_inf)
  |> should.equal(Error(IntOverflow))
  n.i32_trunc_f32_s(f32_neg_inf)
  |> should.equal(Error(IntOverflow))
}

pub fn i32_trunc_truncates_toward_zero_test() {
  // Truncate toward zero (not round).
  n.i32_trunc_f64_s(f64_bits(3.9)) |> should.equal(Ok(3))
  n.i32_trunc_f64_s(f64_bits(-3.9)) |> should.equal(Ok(norm32(-3)))
  n.i32_trunc_f64_s(f64_pos_zero) |> should.equal(Ok(0))
}

pub fn i32_trunc_unsigned_test() {
  // -1.0 is finite but out of [0, 2^32-1] → overflow (NOT invalid conversion).
  n.i32_trunc_f32_u(f32_bits(-1.0)) |> should.equal(Error(IntOverflow))
  // 2^32 is finite and out of [0, 2^32-1] → overflow.
  n.i32_trunc_f64_u(f64_bits(4_294_967_296.0))
  |> should.equal(Error(IntOverflow))
  // largest valid u32 boundary in range.
  n.i32_trunc_f64_u(f64_bits(4_294_967_295.0))
  |> should.equal(Ok(4_294_967_295))
  n.i32_trunc_f64_u(f64_bits(3.7)) |> should.equal(Ok(3))
  n.i32_trunc_f32_u(f32_payload_nan)
  |> should.equal(Error(InvalidConversionToInteger))
}

pub fn i64_trunc_test() {
  n.i64_trunc_f64_s(f64_bits(2.9)) |> should.equal(Ok(2))
  n.i64_trunc_f64_s(f64_bits(-2.9)) |> should.equal(Ok(norm64(-2)))
  // 1.0e19 > 2^63-1 (≈9.22e18) → overflow.
  n.i64_trunc_f64_s(f64_bits(1.0e19)) |> should.equal(Error(IntOverflow))
  // -Inf → integer overflow (not invalid conversion — that is NaN-only).
  n.i64_trunc_f64_u(f64_neg_inf) |> should.equal(Error(IntOverflow))
}

// 2^32 / 2^64 two's-complement re-encoding helpers (test-side).
fn norm32(x: Int) -> Int {
  x + 0x100000000
}

fn norm64(x: Int) -> Int {
  x + 0x10000000000000000
}

// ───────────────────── int→float conversion ─────────────────────

pub fn convert_basic_test() {
  // f64.convert_i32_s(-1) = bits of -1.0 (operand is the unsigned i32 bit pattern).
  n.f64_convert_i32_s(0xFFFFFFFF) |> should.equal(f64_bits(-1.0))
  // _u reads the raw bits → 2^32-1 as a positive value.
  n.f64_convert_i32_u(0xFFFFFFFF) |> should.equal(f64_bits(4_294_967_295.0))
  n.f64_convert_i32_s(1) |> should.equal(f64_bits(1.0))
  n.f32_convert_i32_s(0) |> should.equal(f32_pos_zero)
}

pub fn f32_convert_i64_single_rounding_test() {
  // i64→f32 via the f64 intermediate is correctly SINGLE-rounded (53 ≥ 2·24+2):
  // 2^24+1 ties down to 2^24 (even); 2^24+3 ties up to 2^24+4 (even).
  n.f32_convert_i64_s(16_777_217) |> should.equal(f32_bits(16_777_216.0))
  n.f32_convert_i64_s(16_777_219) |> should.equal(f32_bits(16_777_220.0))
}

pub fn f64_convert_i64_test() {
  // u64 max rounds (ties-to-even) to 2^64 = 0x43F0000000000000.
  n.f64_convert_i64_u(0xFFFFFFFFFFFFFFFF) |> should.equal(0x43F0000000000000)
  // signed reading of the same bits is -1.0.
  n.f64_convert_i64_s(0xFFFFFFFFFFFFFFFF) |> should.equal(f64_bits(-1.0))
}

// ───────────────────── demote / promote ─────────────────────

pub fn f32_demote_f64_test() {
  // 1.0e300 overflows binary32 → +Inf (the round-to-single saturates).
  n.f32_demote_f64(f64_bits(1.0e300)) |> should.equal(f32_pos_inf)
  n.f32_demote_f64(f64_bits(-1.0e300)) |> should.equal(f32_neg_inf)
  // exact finite demote and signed-zero/NaN handling.
  n.f32_demote_f64(f64_bits(1.5)) |> should.equal(f32_bits(1.5))
  n.f32_demote_f64(f64_neg_zero) |> should.equal(f32_neg_zero)
  n.f32_demote_f64(f64_pos_inf) |> should.equal(f32_pos_inf)
  n.f32_demote_f64(f64_payload_nan) |> should.equal(f32_canon_nan)
}

pub fn f64_promote_f32_test() {
  // Promote is EXACT for every non-NaN value.
  n.f64_promote_f32(f32_bits(3.5)) |> should.equal(f64_bits(3.5))
  n.f64_promote_f32(f32_pos_inf) |> should.equal(f64_pos_inf)
  n.f64_promote_f32(f32_neg_inf) |> should.equal(f64_neg_inf)
  n.f64_promote_f32(f32_neg_zero) |> should.equal(f64_neg_zero)
  n.f64_promote_f32(f32_pos_zero) |> should.equal(f64_pos_zero)
  // A (signaling) payload NaN promotes to the quiet canonical f64 NaN under the lock.
  n.f64_promote_f32(f32_payload_nan) |> should.equal(f64_canon_nan)
}
