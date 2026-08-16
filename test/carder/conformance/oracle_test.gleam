//// Spec-grounded self-tests for the oracle (run NOW — no compiler needed).
////
//// Every expectation is derived from the WebAssembly spec / IEEE-754, NOT from
//// "whatever our code emitted" (D8). The NaN bit vectors are the canonical ones from
//// the unit doc / spec:
////   - f32 canonical NaN = 0x7FC00000 (exp all-ones, payload = MSB 0x400000);
////   - f64 canonical NaN = 0x7FF8000000000000 (payload = MSB 0x8000000000000);
////   - "arithmetic" ⇔ payload MSB set, remaining bits arbitrary; sign ignored.

import carder/conformance/fixture.{
  Arithmetic, Canonical, F32Bits, F32Nan, F64Bits, F64Nan, I32Val, I64Val,
}
import carder/conformance/oracle

// ─────────────────────────────── integers: bit-pattern equality ───────────────────────────────

/// Integers compare by exact unsigned bit pattern at the expected width.
pub fn int_exact_test() {
  assert oracle.matches(I32Val(5), I32Val(5))
  assert !oracle.matches(I32Val(5), I32Val(6))
  // 0xFFFFFFFF == 4294967295 (the unsigned bit pattern of i32 -1).
  assert oracle.matches(I32Val(4_294_967_295), I32Val(4_294_967_295))
  assert oracle.matches(
    I64Val(18_446_744_073_709_551_615),
    I64Val(18_446_744_073_709_551_615),
  )
}

/// Comparison masks the ACTUAL to the EXPECTED's width, so a loosely-tagged actual
/// (e.g. an i64-carried result) still matches a 32-bit expectation when its low 32 bits
/// agree, and an out-of-band high bit does not cause a spurious miss.
pub fn int_width_masking_test() {
  // actual carries 2^32 + 5; at i32 width that is 5.
  assert oracle.matches(I64Val(4_294_967_301), I32Val(5))
  // but 2^32 + 6 at i32 width is 6, not 5.
  assert !oracle.matches(I64Val(4_294_967_302), I32Val(5))
}

// ─────────────────────────────── floats: bits exact, -0.0 ≠ +0.0 ───────────────────────────────

/// Concrete floats compare by exact bits — so the f32 `1.0` vector (0x3F800000 =
/// 1065353216) matches, and `-0.0` (0x80000000) is correctly DISTINCT from `+0.0`.
pub fn float_bits_exact_test() {
  assert oracle.matches(F32Bits(1_065_353_216), F32Bits(1_065_353_216))
  assert !oracle.matches(F32Bits(0x80000000), F32Bits(0x00000000))
  assert oracle.matches(
    F64Bits(4_607_182_418_800_017_408),
    F64Bits(4_607_182_418_800_017_408),
  )
}

// ─────────────────────────────── NaN by class ───────────────────────────────

/// A canonical f32 NaN (0x7FC00000) matches `Canonical`; the sign is ignored, so the
/// negative canonical NaN (0xFFC00000) also matches.
pub fn f32_canonical_nan_test() {
  assert oracle.matches(F32Bits(0x7FC00000), F32Nan(Canonical))
  assert oracle.matches(F32Bits(0xFFC00000), F32Nan(Canonical))
  // canonical is a strict subset of arithmetic, so it matches Arithmetic too.
  assert oracle.matches(F32Bits(0x7FC00000), F32Nan(Arithmetic))
}

/// Arithmetic f32 NaNs (payload MSB set, rest arbitrary; either sign) match
/// `Arithmetic` but NOT `Canonical` (whose payload must be exactly the MSB).
pub fn f32_arithmetic_nan_test() {
  assert oracle.matches(F32Bits(0x7FC00001), F32Nan(Arithmetic))
  assert oracle.matches(F32Bits(0x7FE00000), F32Nan(Arithmetic))
  assert oracle.matches(F32Bits(0xFFFFFFFF), F32Nan(Arithmetic))
  assert !oracle.matches(F32Bits(0x7FC00001), F32Nan(Canonical))
}

/// A signalling NaN (exp all-ones, payload non-zero but MSB CLEAR, e.g. 0x7F800001) is
/// a NaN but matches NEITHER class; a finite value (1.0) matches neither either.
pub fn f32_non_nan_and_signalling_test() {
  assert !oracle.matches(F32Bits(0x7F800001), F32Nan(Canonical))
  assert !oracle.matches(F32Bits(0x7F800001), F32Nan(Arithmetic))
  assert !oracle.matches(F32Bits(1_065_353_216), F32Nan(Arithmetic))
  // +Inf (0x7F800000) has zero payload → not a NaN.
  assert !oracle.matches(F32Bits(0x7F800000), F32Nan(Arithmetic))
}

/// f64 canonical NaN (0x7FF8000000000000) matches `Canonical`; an arithmetic f64 NaN
/// matches only `Arithmetic`; sign ignored.
pub fn f64_nan_classes_test() {
  assert oracle.matches(F64Bits(0x7FF8000000000000), F64Nan(Canonical))
  assert oracle.matches(F64Bits(0xFFF8000000000000), F64Nan(Canonical))
  assert oracle.matches(F64Bits(0x7FF8000000000001), F64Nan(Arithmetic))
  assert !oracle.matches(F64Bits(0x7FF8000000000001), F64Nan(Canonical))
  // exp all-ones, payload MSB clear → not arithmetic.
  assert !oracle.matches(F64Bits(0x7FF0000000000001), F64Nan(Arithmetic))
}

// ─────────────────────────────── result-list matching ───────────────────────────────

/// `matches_all` requires equal length and pointwise matches.
pub fn matches_all_test() {
  assert oracle.matches_all([], [])
  assert oracle.matches_all([I32Val(1), I64Val(2)], [I32Val(1), I64Val(2)])
  assert !oracle.matches_all([I32Val(1)], [])
  assert !oracle.matches_all([I32Val(1)], [I32Val(2)])
}
