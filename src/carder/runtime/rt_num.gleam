//// The numeric runtime — SIGNATURES frozen by unit 01; BODIES implemented by unit 06
//// (the `bif`, tier-P reference implementation).
////
//// This module is the single auditable chokepoint for numeric fidelity (D2): the
//// generated Core Erlang calls these functions at run time, so the two's-complement
//// wrap, the trapping `div`/`rem` semantics, shift-count masking, and the float
//// bit-pattern representation all live here and ONLY here. Unit 01 fixes the
//// **names, arities, and `Result`-vs-bare-`Int` shape**; the spec-cited *semantics*
//// (and the float = raw-bits representation, never a BEAM double) are filled in by
//// unit 06.
////
//// ## Value representation conventions (the one documented convention)
////
//// - **Integers** (i32/i64 operands and results) are the **raw UNSIGNED bit pattern**
////   as an `Int` in `[0, 2^width)`. Signed operations interpret those bits as two's
////   complement internally (`signed/2`) and return the unsigned bit pattern of the
////   result (`norm/2`). `norm(x, n) = ((x % 2^n) + 2^n) % 2^n` is a TRUE non-negative
////   modulo — bare `%`/`int.remainder` follows the dividend's sign and would corrupt
////   the bit pattern, so wrapping always goes through `norm`.
//// - **Floats** (f32/f64) are the **raw IEEE-754 bit pattern** as an `Int` (D5 — never
////   a BEAM double, which cannot represent NaN/Infinity: arithmetic on them raises
////   `badarith` and `<<F:64/float>>` fails to match NaN/Inf bits). Each float op
////   classifies its operands from the bit fields, handles NaN/±Inf/±0 by IEEE rules on
////   the bits, and only decodes finite operands to a native double for the actual
////   arithmetic, re-encoding the finite result back to bits.
//// - **Canonical-NaN lock (spec-permitted determinism).** Whenever an operand is NaN
////   or an operation produces NaN, these functions return the **positive canonical
////   NaN** (`f32 = 0x7FC00000`, `f64 = 0x7FF8000000000000`). No NaN-payload
////   propagation is attempted; this is conformant and is the deterministic profile.
//// - **Overflow → ±Inf, never `badarith`.** BEAM double arithmetic raises `badarith`
////   on overflow instead of yielding `±Inf`. The finite path detects f64 overflow
////   exactly (via an integer significand/exponent comparison against the IEEE
////   round-to-nearest overflow threshold) and emits the correctly-signed Inf bits;
////   f32 results are produced by a 32-bit float round-trip, which rounds to single and
////   saturates out-of-range magnitudes to `±Inf` without raising.
//// - **Comparisons** (`*_eq`, `*_ne`, `*_lt_*`, …, `*_eqz`) return an **i32 truth
////   value**: `1` for true, `0` for false (including the `i64_*` comparisons).
//// - **Trapping ops** (`*_div_s`, `*_div_u`, `*_rem_s`, `*_rem_u`) return
////   `Result(Int, TrapReason)`: `Ok(bits)` on success, `Error(reason)` on a trap (the
////   *caller* — `emit_core` — raises via `rt_trap`; resolved open question #3). NB:
////   Gleam's `/` and `%` are TOTAL (`x / 0 == 0`), so these functions check the
////   divisor explicitly BEFORE dividing.

import carder/ir.{
  type TrapReason, IntDivByZero, IntOverflow, InvalidConversionToInteger,
}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/order

// ───────────────────── private integer representation helpers ─────────────────────

/// `2^n` for `n >= 0`, as an arbitrary-precision integer (BEAM bignum).
fn pow2(n: Int) -> Int {
  int.bitwise_shift_left(1, n)
}

/// The modulus `2^n` bounding an n-bit value: all stored bit patterns are in `[0, M)`.
fn modulus(n: Int) -> Int {
  pow2(n)
}

/// TRUE non-negative modulo: maps any integer `x` to its canonical n-bit unsigned bit
/// pattern in `[0, 2^n)`. This is the two's-complement "wrap"; unlike bare `%` it never
/// returns a negative value.
fn norm(x: Int, n: Int) -> Int {
  let m = modulus(n)
  let r = x % m
  case r < 0 {
    True -> r + m
    False -> r
  }
}

/// Interpret an n-bit unsigned bit pattern `u` in `[0, 2^n)` as a two's-complement
/// signed integer in `[-2^(n-1), 2^(n-1))`.
fn signed(u: Int, n: Int) -> Int {
  case u >= pow2(n - 1) {
    True -> u - modulus(n)
    False -> u
  }
}

/// The smallest two's-complement signed value for width `n`: `-2^(n-1)` (INT_MIN).
fn int_min_signed(n: Int) -> Int {
  0 - pow2(n - 1)
}

/// The low `k` bits of `a` (`a >= 0`), i.e. `a mod 2^k`.
fn low_bits(a: Int, k: Int) -> Int {
  int.bitwise_and(a, pow2(k) - 1)
}

/// The shift/rotate count: the operand `b` taken modulo the width `n` (`n` a power of
/// two), so a shift by `n` is the identity and a shift by `n+1` equals a shift by `1`.
fn shift_count(b: Int, n: Int) -> Int {
  int.bitwise_and(b, n - 1)
}

/// `1` if `b` is true, `0` otherwise — the i32 truth encoding used by every comparison.
fn bool_to_i32(b: Bool) -> Int {
  case b {
    True -> 1
    False -> 0
  }
}

// ───────────────────── private integer op workers (width-parametric) ─────────────────────

fn iadd(a: Int, b: Int, n: Int) -> Int {
  norm(a + b, n)
}

fn isub(a: Int, b: Int, n: Int) -> Int {
  norm(a - b, n)
}

fn imul(a: Int, b: Int, n: Int) -> Int {
  norm(a * b, n)
}

fn ishl(a: Int, b: Int, n: Int) -> Int {
  norm(int.bitwise_shift_left(a, shift_count(b, n)), n)
}

fn ishr_u(a: Int, b: Int, n: Int) -> Int {
  // `a >= 0`, so an arithmetic shift right is identical to a logical one.
  int.bitwise_shift_right(a, shift_count(b, n))
}

fn ishr_s(a: Int, b: Int, n: Int) -> Int {
  // Arithmetic (sign-filling) shift: floor(signed(a) / 2^k). Erlang `bsr` on a negative
  // operand floors, which is exactly what an arithmetic shift requires.
  norm(int.bitwise_shift_right(signed(a, n), shift_count(b, n)), n)
}

fn irotl(a: Int, b: Int, n: Int) -> Int {
  let k = shift_count(b, n)
  norm(
    int.bitwise_or(
      int.bitwise_shift_left(a, k),
      int.bitwise_shift_right(a, n - k),
    ),
    n,
  )
}

fn irotr(a: Int, b: Int, n: Int) -> Int {
  let k = shift_count(b, n)
  norm(
    int.bitwise_or(
      int.bitwise_shift_right(a, k),
      int.bitwise_shift_left(a, n - k),
    ),
    n,
  )
}

/// Number of significant bits of `a >= 0` (`0` for `a == 0`).
fn bit_length(a: Int) -> Int {
  case a {
    0 -> 0
    _ -> 1 + bit_length(a / 2)
  }
}

fn iclz(a: Int, n: Int) -> Int {
  n - bit_length(a)
}

fn trailing_zeros(a: Int) -> Int {
  case a % 2 {
    0 -> 1 + trailing_zeros(a / 2)
    _ -> 0
  }
}

fn ictz(a: Int, n: Int) -> Int {
  case a {
    0 -> n
    _ -> trailing_zeros(a)
  }
}

fn popcount(a: Int, acc: Int) -> Int {
  case a {
    0 -> acc
    _ -> popcount(a / 2, acc + a % 2)
  }
}

fn idiv_u(a: Int, b: Int) -> Result(Int, TrapReason) {
  case b {
    0 -> Error(IntDivByZero)
    _ -> Ok(a / b)
  }
}

fn irem_u(a: Int, b: Int) -> Result(Int, TrapReason) {
  case b {
    0 -> Error(IntDivByZero)
    _ -> Ok(a % b)
  }
}

fn idiv_s(a: Int, b: Int, n: Int) -> Result(Int, TrapReason) {
  case b {
    0 -> Error(IntDivByZero)
    _ -> {
      let sa = signed(a, n)
      let sb = signed(b, n)
      case sa == int_min_signed(n) && sb == -1 {
        True -> Error(IntOverflow)
        // Gleam `/` truncates toward zero (Erlang `div`).
        False -> Ok(norm(sa / sb, n))
      }
    }
  }
}

fn irem_s(a: Int, b: Int, n: Int) -> Result(Int, TrapReason) {
  case b {
    0 -> Error(IntDivByZero)
    // Gleam `%` is Erlang `rem`: it follows the dividend's sign and yields `0` for
    // `INT_MIN % -1` (so rem_s, unlike div_s, never traps on overflow).
    _ -> Ok(norm(signed(a, n) % signed(b, n), n))
  }
}

// ───────────────────────────── i32 — non-trapping ─────────────────────────────

/// 32-bit integer addition with two's-complement wrap. Returns the low-32-bit result as
/// an unsigned bit pattern. Never traps.
pub fn i32_add(a: Int, b: Int) -> Int {
  iadd(a, b, 32)
}

/// 32-bit integer subtraction with two's-complement wrap. Never traps.
pub fn i32_sub(a: Int, b: Int) -> Int {
  isub(a, b, 32)
}

/// 32-bit integer multiplication (low 32 bits, two's-complement wrap). Never traps.
pub fn i32_mul(a: Int, b: Int) -> Int {
  imul(a, b, 32)
}

/// 32-bit bitwise AND of the raw bit patterns.
pub fn i32_and(a: Int, b: Int) -> Int {
  int.bitwise_and(a, b)
}

/// 32-bit bitwise OR of the raw bit patterns.
pub fn i32_or(a: Int, b: Int) -> Int {
  int.bitwise_or(a, b)
}

/// 32-bit bitwise XOR of the raw bit patterns.
pub fn i32_xor(a: Int, b: Int) -> Int {
  int.bitwise_exclusive_or(a, b)
}

/// 32-bit shift left; the shift count `b` is taken modulo 32 (shift-count masking), so
/// a shift by 32 is the identity.
pub fn i32_shl(a: Int, b: Int) -> Int {
  ishl(a, b, 32)
}

/// 32-bit arithmetic (sign-propagating) shift right; count taken modulo 32.
pub fn i32_shr_s(a: Int, b: Int) -> Int {
  ishr_s(a, b, 32)
}

/// 32-bit logical (zero-filling) shift right; count taken modulo 32.
pub fn i32_shr_u(a: Int, b: Int) -> Int {
  ishr_u(a, b, 32)
}

/// 32-bit rotate left; count taken modulo 32 (count 0 is the identity).
pub fn i32_rotl(a: Int, b: Int) -> Int {
  irotl(a, b, 32)
}

/// 32-bit rotate right; count taken modulo 32 (count 0 is the identity).
pub fn i32_rotr(a: Int, b: Int) -> Int {
  irotr(a, b, 32)
}

/// Count leading zero bits of a 32-bit value; returns 32 for input 0.
pub fn i32_clz(a: Int) -> Int {
  iclz(a, 32)
}

/// Count trailing zero bits of a 32-bit value; returns 32 for input 0.
pub fn i32_ctz(a: Int) -> Int {
  ictz(a, 32)
}

/// Population count: number of set bits in a 32-bit value (bit scan).
pub fn i32_popcnt(a: Int) -> Int {
  popcount(a, 0)
}

/// Returns `1` if the 32-bit value is zero, else `0` (i32 truth value).
pub fn i32_eqz(a: Int) -> Int {
  bool_to_i32(a == 0)
}

/// 32-bit equality (raw bits); returns the i32 truth value `1`/`0`.
pub fn i32_eq(a: Int, b: Int) -> Int {
  bool_to_i32(a == b)
}

/// 32-bit inequality (raw bits); returns the i32 truth value `1`/`0`.
pub fn i32_ne(a: Int, b: Int) -> Int {
  bool_to_i32(a != b)
}

/// 32-bit signed less-than (operands read as two's complement); i32 truth value.
pub fn i32_lt_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 32) < signed(b, 32))
}

/// 32-bit unsigned less-than (raw bits); i32 truth value.
pub fn i32_lt_u(a: Int, b: Int) -> Int {
  bool_to_i32(a < b)
}

/// 32-bit signed greater-than; i32 truth value.
pub fn i32_gt_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 32) > signed(b, 32))
}

/// 32-bit unsigned greater-than (raw bits); i32 truth value.
pub fn i32_gt_u(a: Int, b: Int) -> Int {
  bool_to_i32(a > b)
}

/// 32-bit signed less-than-or-equal; i32 truth value.
pub fn i32_le_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 32) <= signed(b, 32))
}

/// 32-bit unsigned less-than-or-equal (raw bits); i32 truth value.
pub fn i32_le_u(a: Int, b: Int) -> Int {
  bool_to_i32(a <= b)
}

/// 32-bit signed greater-than-or-equal; i32 truth value.
pub fn i32_ge_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 32) >= signed(b, 32))
}

/// 32-bit unsigned greater-than-or-equal (raw bits); i32 truth value.
pub fn i32_ge_u(a: Int, b: Int) -> Int {
  bool_to_i32(a >= b)
}

// ───────────────────────────── i32 — trapping ─────────────────────────────

/// 32-bit signed division. `Error(IntDivByZero)` if `b == 0`; `Error(IntOverflow)` for
/// `INT_MIN / -1` (`0x80000000 / 0xFFFFFFFF`); else `Ok(quotient bits)` truncated toward
/// zero.
pub fn i32_div_s(a: Int, b: Int) -> Result(Int, TrapReason) {
  idiv_s(a, b, 32)
}

/// 32-bit unsigned division. `Error(IntDivByZero)` if `b == 0`; else `Ok(quotient)`
/// (truncated toward zero).
pub fn i32_div_u(a: Int, b: Int) -> Result(Int, TrapReason) {
  idiv_u(a, b)
}

/// 32-bit signed remainder. `Error(IntDivByZero)` if `b == 0`; else `Ok(remainder)` with
/// the sign of the dividend. No overflow trap: `INT_MIN % -1 == 0`.
pub fn i32_rem_s(a: Int, b: Int) -> Result(Int, TrapReason) {
  irem_s(a, b, 32)
}

/// 32-bit unsigned remainder. `Error(IntDivByZero)` if `b == 0`; else `Ok(remainder)`.
pub fn i32_rem_u(a: Int, b: Int) -> Result(Int, TrapReason) {
  irem_u(a, b)
}

// ───────────────────────────── i64 — non-trapping ─────────────────────────────

/// 64-bit integer addition with two's-complement wrap. Never traps.
pub fn i64_add(a: Int, b: Int) -> Int {
  iadd(a, b, 64)
}

/// 64-bit integer subtraction with two's-complement wrap. Never traps.
pub fn i64_sub(a: Int, b: Int) -> Int {
  isub(a, b, 64)
}

/// 64-bit integer multiplication (low 64 bits, two's-complement wrap). Never traps.
pub fn i64_mul(a: Int, b: Int) -> Int {
  imul(a, b, 64)
}

/// 64-bit bitwise AND of the raw bit patterns.
pub fn i64_and(a: Int, b: Int) -> Int {
  int.bitwise_and(a, b)
}

/// 64-bit bitwise OR of the raw bit patterns.
pub fn i64_or(a: Int, b: Int) -> Int {
  int.bitwise_or(a, b)
}

/// 64-bit bitwise XOR of the raw bit patterns.
pub fn i64_xor(a: Int, b: Int) -> Int {
  int.bitwise_exclusive_or(a, b)
}

/// 64-bit shift left; the shift count `b` is taken modulo 64 (shift-count masking).
pub fn i64_shl(a: Int, b: Int) -> Int {
  ishl(a, b, 64)
}

/// 64-bit arithmetic (sign-propagating) shift right; count taken modulo 64.
pub fn i64_shr_s(a: Int, b: Int) -> Int {
  ishr_s(a, b, 64)
}

/// 64-bit logical (zero-filling) shift right; count taken modulo 64.
pub fn i64_shr_u(a: Int, b: Int) -> Int {
  ishr_u(a, b, 64)
}

/// 64-bit rotate left; count taken modulo 64 (count 0 is the identity).
pub fn i64_rotl(a: Int, b: Int) -> Int {
  irotl(a, b, 64)
}

/// 64-bit rotate right; count taken modulo 64 (count 0 is the identity).
pub fn i64_rotr(a: Int, b: Int) -> Int {
  irotr(a, b, 64)
}

/// Count leading zero bits of a 64-bit value; returns 64 for input 0.
pub fn i64_clz(a: Int) -> Int {
  iclz(a, 64)
}

/// Count trailing zero bits of a 64-bit value; returns 64 for input 0.
pub fn i64_ctz(a: Int) -> Int {
  ictz(a, 64)
}

/// Population count: number of set bits in a 64-bit value (bit scan).
pub fn i64_popcnt(a: Int) -> Int {
  popcount(a, 0)
}

/// Returns `1` if the 64-bit value is zero, else `0` (i32 truth value).
pub fn i64_eqz(a: Int) -> Int {
  bool_to_i32(a == 0)
}

/// 64-bit equality (raw bits); returns the i32 truth value `1`/`0`.
pub fn i64_eq(a: Int, b: Int) -> Int {
  bool_to_i32(a == b)
}

/// 64-bit inequality (raw bits); returns the i32 truth value `1`/`0`.
pub fn i64_ne(a: Int, b: Int) -> Int {
  bool_to_i32(a != b)
}

/// 64-bit signed less-than; i32 truth value.
pub fn i64_lt_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 64) < signed(b, 64))
}

/// 64-bit unsigned less-than (raw bits); i32 truth value.
pub fn i64_lt_u(a: Int, b: Int) -> Int {
  bool_to_i32(a < b)
}

/// 64-bit signed greater-than; i32 truth value.
pub fn i64_gt_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 64) > signed(b, 64))
}

/// 64-bit unsigned greater-than (raw bits); i32 truth value.
pub fn i64_gt_u(a: Int, b: Int) -> Int {
  bool_to_i32(a > b)
}

/// 64-bit signed less-than-or-equal; i32 truth value.
pub fn i64_le_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 64) <= signed(b, 64))
}

/// 64-bit unsigned less-than-or-equal (raw bits); i32 truth value.
pub fn i64_le_u(a: Int, b: Int) -> Int {
  bool_to_i32(a <= b)
}

/// 64-bit signed greater-than-or-equal; i32 truth value.
pub fn i64_ge_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 64) >= signed(b, 64))
}

/// 64-bit unsigned greater-than-or-equal (raw bits); i32 truth value.
pub fn i64_ge_u(a: Int, b: Int) -> Int {
  bool_to_i32(a >= b)
}

// ───────────────────────────── i64 — trapping ─────────────────────────────

/// 64-bit signed division. `Error(IntDivByZero)` if `b == 0`; `Error(IntOverflow)` for
/// `INT_MIN / -1`; else `Ok(quotient bits)` truncated toward zero.
pub fn i64_div_s(a: Int, b: Int) -> Result(Int, TrapReason) {
  idiv_s(a, b, 64)
}

/// 64-bit unsigned division. `Error(IntDivByZero)` if `b == 0`; else `Ok(quotient)`.
pub fn i64_div_u(a: Int, b: Int) -> Result(Int, TrapReason) {
  idiv_u(a, b)
}

/// 64-bit signed remainder. `Error(IntDivByZero)` if `b == 0`; else `Ok(remainder)` with
/// the sign of the dividend. No overflow trap: `INT_MIN % -1 == 0`.
pub fn i64_rem_s(a: Int, b: Int) -> Result(Int, TrapReason) {
  irem_s(a, b, 64)
}

/// 64-bit unsigned remainder. `Error(IntDivByZero)` if `b == 0`; else `Ok(remainder)`.
pub fn i64_rem_u(a: Int, b: Int) -> Result(Int, TrapReason) {
  irem_u(a, b)
}

// ───────────────────────────── Conversions ─────────────────────────────

/// Wrap an i64 to its low 32 bits (`i32.wrap_i64`): `x mod 2^32`. Never traps.
pub fn i32_wrap_i64(a: Int) -> Int {
  norm(a, 32)
}

/// Sign-extend an i32 to i64 (`i64.extend_i32_s`): the low-32 value read as signed,
/// re-encoded into 64 bits.
pub fn i64_extend_i32_s(a: Int) -> Int {
  norm(signed(a, 32), 64)
}

/// Zero-extend an i32 to i64 (`i64.extend_i32_u`): identity, since `x ∈ [0, 2^32)` is
/// already a valid 64-bit bit pattern.
pub fn i64_extend_i32_u(a: Int) -> Int {
  a
}

/// Sign-extend the low 8 bits of an i32 to a full i32 (`i32.extend8_s`):
/// e.g. `0x80 -> 0xFFFFFF80`.
pub fn i32_extend8_s(a: Int) -> Int {
  norm(signed(low_bits(a, 8), 8), 32)
}

/// Sign-extend the low 16 bits of an i32 to a full i32 (`i32.extend16_s`):
/// e.g. `0x8000 -> 0xFFFF8000`.
pub fn i32_extend16_s(a: Int) -> Int {
  norm(signed(low_bits(a, 16), 16), 32)
}

/// Sign-extend the low 8 bits of an i64 to a full i64 (`i64.extend8_s`).
pub fn i64_extend8_s(a: Int) -> Int {
  norm(signed(low_bits(a, 8), 8), 64)
}

/// Sign-extend the low 16 bits of an i64 to a full i64 (`i64.extend16_s`).
pub fn i64_extend16_s(a: Int) -> Int {
  norm(signed(low_bits(a, 16), 16), 64)
}

/// Sign-extend the low 32 bits of an i64 to a full i64 (`i64.extend32_s`).
pub fn i64_extend32_s(a: Int) -> Int {
  norm(signed(low_bits(a, 32), 32), 64)
}

/// Reinterpret an f32 bit pattern as i32 bits (`i32.reinterpret_f32`). A no-op on our
/// representation: floats are *already* stored as their raw bit pattern, so only the
/// static IR type changes — the bits are returned unchanged.
pub fn i32_reinterpret_f32(a: Int) -> Int {
  a
}

/// Reinterpret an f64 bit pattern as i64 bits (`i64.reinterpret_f64`). A no-op — see
/// `i32_reinterpret_f32`.
pub fn i64_reinterpret_f64(a: Int) -> Int {
  a
}

/// Reinterpret an i32 bit pattern as f32 bits (`f32.reinterpret_i32`). A no-op — see
/// `i32_reinterpret_f32`.
pub fn f32_reinterpret_i32(a: Int) -> Int {
  a
}

/// Reinterpret an i64 bit pattern as f64 bits (`f64.reinterpret_i64`). A no-op — see
/// `i32_reinterpret_f32`.
pub fn f64_reinterpret_i64(a: Int) -> Int {
  a
}

/// Saturating signed truncation f32 → i32 (`i32.trunc_sat_f32_s`); never traps.
/// NaN → 0; `-Inf` → INT_MIN; `+Inf` → INT_MAX; else truncate toward zero and clamp.
pub fn i32_trunc_sat_f32_s(a: Int) -> Int {
  trunc_sat_s(f32_fmt, a, 32)
}

/// Saturating unsigned truncation f32 → i32 (`i32.trunc_sat_f32_u`); never traps.
/// NaN → 0; `<= 0`/`-Inf` → 0; `+Inf` → UINT32_MAX; else truncate toward zero and clamp.
pub fn i32_trunc_sat_f32_u(a: Int) -> Int {
  trunc_sat_u(f32_fmt, a, 32)
}

/// Saturating signed truncation f64 → i32 (`i32.trunc_sat_f64_s`); never traps.
pub fn i32_trunc_sat_f64_s(a: Int) -> Int {
  trunc_sat_s(f64_fmt, a, 32)
}

/// Saturating unsigned truncation f64 → i32 (`i32.trunc_sat_f64_u`); never traps.
pub fn i32_trunc_sat_f64_u(a: Int) -> Int {
  trunc_sat_u(f64_fmt, a, 32)
}

/// Saturating signed truncation f32 → i64 (`i64.trunc_sat_f32_s`); never traps.
pub fn i64_trunc_sat_f32_s(a: Int) -> Int {
  trunc_sat_s(f32_fmt, a, 64)
}

/// Saturating unsigned truncation f32 → i64 (`i64.trunc_sat_f32_u`); never traps.
pub fn i64_trunc_sat_f32_u(a: Int) -> Int {
  trunc_sat_u(f32_fmt, a, 64)
}

/// Saturating signed truncation f64 → i64 (`i64.trunc_sat_f64_s`); never traps.
pub fn i64_trunc_sat_f64_s(a: Int) -> Int {
  trunc_sat_s(f64_fmt, a, 64)
}

/// Saturating unsigned truncation f64 → i64 (`i64.trunc_sat_f64_u`); never traps.
pub fn i64_trunc_sat_f64_u(a: Int) -> Int {
  trunc_sat_u(f64_fmt, a, 64)
}

// ───────────────────── private float representation helpers ─────────────────────

/// The IEEE-754 binary format of a float: total width, exponent-field width, and
/// trailing-significand (mantissa) width, all in bits.
type FloatFmt {
  FloatFmt(total: Int, ebits: Int, mbits: Int)
}

const f32_fmt = FloatFmt(total: 32, ebits: 8, mbits: 23)

const f64_fmt = FloatFmt(total: 64, ebits: 11, mbits: 52)

/// The IEEE classification of a float, with the operand's sign bit (`0` positive,
/// `1` negative) where it is meaningful.
type FClass {
  CNan
  CInf(sign: Int)
  CZero(sign: Int)
  CFinite(sign: Int)
}

/// The arithmetic kind for the finite path (subtraction is realised as `a + (-b)`).
type FBinOp {
  AddOp
  MulOp
  DivOp
}

/// The all-ones exponent field for `fmt` (the NaN/Inf exponent).
fn exp_all_ones(fmt: FloatFmt) -> Int {
  pow2(fmt.ebits) - 1
}

/// The exponent bias for `fmt` (`127` for f32, `1023` for f64).
fn fbias(fmt: FloatFmt) -> Int {
  pow2(fmt.ebits - 1) - 1
}

/// The sign bit of `bits` (`0` or `1`).
fn sign_of(fmt: FloatFmt, bits: Int) -> Int {
  int.bitwise_shift_right(bits, fmt.total - 1)
}

/// The positive canonical quiet NaN bit pattern for `fmt`
/// (`0x7FC00000` for f32, `0x7FF8000000000000` for f64).
fn canonical_nan(fmt: FloatFmt) -> Int {
  exp_all_ones(fmt) * pow2(fmt.mbits) + pow2(fmt.mbits - 1)
}

/// The `±Inf` bit pattern for `fmt` (`sign` `0` → `+Inf`, else `-Inf`).
fn float_inf(fmt: FloatFmt, sign: Int) -> Int {
  let pos = exp_all_ones(fmt) * pow2(fmt.mbits)
  case sign {
    0 -> pos
    _ -> pos + pow2(fmt.total - 1)
  }
}

/// The `±0` bit pattern for `fmt` (`sign` `0` → `+0` i.e. all-zero, else `-0`).
fn float_zero(fmt: FloatFmt, sign: Int) -> Int {
  case sign {
    0 -> 0
    _ -> pow2(fmt.total - 1)
  }
}

/// Toggle the sign bit of `bits` (negation in the bit domain).
fn flip_sign(fmt: FloatFmt, bits: Int) -> Int {
  int.bitwise_exclusive_or(bits, pow2(fmt.total - 1))
}

/// Classify `bits` as NaN / ±Inf / ±0 / finite from its exponent and mantissa fields,
/// without decoding to a native double (which cannot hold NaN/Inf).
fn classify(fmt: FloatFmt, bits: Int) -> FClass {
  let sign = sign_of(fmt, bits)
  let exp =
    int.bitwise_and(int.bitwise_shift_right(bits, fmt.mbits), exp_all_ones(fmt))
  let mant = low_bits(bits, fmt.mbits)
  case exp == exp_all_ones(fmt) {
    True ->
      case mant == 0 {
        True -> CInf(sign)
        False -> CNan
      }
    False ->
      case exp == 0 && mant == 0 {
        True -> CZero(sign)
        False -> CFinite(sign)
      }
  }
}

/// Decompose a FINITE NONZERO float into `#(sign, significand, exp2)` such that the
/// magnitude equals `significand * 2^exp2` EXACTLY (`significand` an integer ≥ 1). Used
/// for exact overflow detection and exact truncation. Not valid for NaN/Inf/zero.
fn decompose(fmt: FloatFmt, bits: Int) -> #(Int, Int, Int) {
  let sign = sign_of(fmt, bits)
  let exp =
    int.bitwise_and(int.bitwise_shift_right(bits, fmt.mbits), exp_all_ones(fmt))
  let mant = low_bits(bits, fmt.mbits)
  case exp == 0 {
    // subnormal: value = mant * 2^(1 - bias - mbits)
    True -> #(sign, mant, 1 - fbias(fmt) - fmt.mbits)
    // normal: value = (2^mbits + mant) * 2^(exp - bias - mbits)
    False -> #(sign, pow2(fmt.mbits) + mant, exp - fbias(fmt) - fmt.mbits)
  }
}

/// Apply the operand's `sign` (`0`/`1`) to a magnitude, yielding a signed integer.
fn signed_significand(sign: Int, sig: Int) -> Int {
  case sign {
    0 -> sig
    _ -> 0 - sig
  }
}

/// Decode a finite/zero 64-bit pattern into a native double. Fails (`badmatch`) on
/// NaN/Inf bits — callers must classify first.
fn bits_to_f64(bits: Int) -> Float {
  let assert <<f:float-size(64)>> = <<bits:size(64)>>
  f
}

/// Encode a finite native double into its 64-bit pattern.
fn f64_to_bits(f: Float) -> Int {
  let assert <<bits:size(64)>> = <<f:float-size(64)>>
  bits
}

/// Decode a finite/zero 32-bit pattern into a native double (widening single → double).
/// Fails on NaN/Inf bits — callers must classify first.
fn bits_to_f32(bits: Int) -> Float {
  let assert <<f:float-size(32)>> = <<bits:size(32)>>
  f
}

/// Round a native double to binary32 and return its 32-bit pattern. The 32-bit float
/// construct rounds to nearest-ties-to-even and saturates out-of-single-range
/// magnitudes to `±Inf` without raising.
fn f32_round_to_bits(f: Float) -> Int {
  let assert <<bits:size(32)>> = <<f:float-size(32)>>
  bits
}

/// Decode a finite/zero `fmt` pattern into a native double.
fn decode_float(fmt: FloatFmt, bits: Int) -> Float {
  case fmt.total {
    32 -> bits_to_f32(bits)
    _ -> bits_to_f64(bits)
  }
}

/// Apply a binary op to two native doubles (only on the all-finite path).
fn apply_double(op: FBinOp, x: Float, y: Float) -> Float {
  case op {
    AddOp -> x +. y
    MulOp -> x *. y
    DivOp -> x /. y
  }
}

/// The IEEE round-to-nearest overflow threshold for binary64: a finite result rounds to
/// `±Inf` exactly when its magnitude is `>= 2^1024 - 2^970`.
fn f64_overflow_threshold() -> Int {
  pow2(1024) - pow2(970)
}

/// Compare `s1 * 2^e1` with `s2 * 2^e2` (`s1, s2 >= 0`), exactly, as bignums.
fn mag_cmp(s1: Int, e1: Int, s2: Int, e2: Int) -> order.Order {
  let m = int.min(e1, e2)
  int.compare(s1 * pow2(e1 - m), s2 * pow2(e2 - m))
}

/// `True` iff `s1 * 2^e1 >= s2 * 2^e2`.
fn mag_geq(s1: Int, e1: Int, s2: Int, e2: Int) -> Bool {
  mag_cmp(s1, e1, s2, e2) != order.Lt
}

/// Decide whether the f64 finite-finite op `a OP b` overflows to `±Inf`.
/// `Some(sign)` → the exact result has magnitude at/above the IEEE overflow threshold,
/// so emit Inf with that sign (`0`/`1`); `None` → the BEAM op is safe (no `badarith`).
fn f64_finite_overflow(a: Int, b: Int, op: FBinOp) -> Option(Int) {
  let #(sa, ma, ea) = decompose(f64_fmt, a)
  let #(sb, mb, eb) = decompose(f64_fmt, b)
  let t = f64_overflow_threshold()
  case op {
    MulOp ->
      // |a*b| = (ma*mb) * 2^(ea+eb)
      case mag_geq(ma * mb, ea + eb, t, 0) {
        True -> Some(int.bitwise_exclusive_or(sa, sb))
        False -> None
      }
    DivOp ->
      // |a/b| >= T  <=>  ma*2^ea >= (T*mb)*2^eb
      case mag_geq(ma, ea, t * mb, eb) {
        True -> Some(int.bitwise_exclusive_or(sa, sb))
        False -> None
      }
    AddOp -> {
      // exact signed result = S * 2^c, c = min(ea, eb)
      let c = int.min(ea, eb)
      let va = signed_significand(sa, ma) * pow2(ea - c)
      let vb = signed_significand(sb, mb) * pow2(eb - c)
      let s = va + vb
      case mag_geq(int.absolute_value(s), c, t, 0) {
        True ->
          case s < 0 {
            True -> Some(1)
            False -> Some(0)
          }
        False -> None
      }
    }
  }
}

/// The all-finite-nonzero arithmetic path. For f32, compute in double and round the
/// result to binary32 (which saturates overflow to `±Inf`). For f64, first detect
/// overflow exactly (emitting signed Inf) and otherwise let BEAM compute the
/// correctly-rounded finite result.
fn finite_binop(fmt: FloatFmt, a: Int, b: Int, op: FBinOp) -> Int {
  case fmt.total {
    32 -> f32_round_to_bits(apply_double(op, bits_to_f32(a), bits_to_f32(b)))
    _ ->
      case f64_finite_overflow(a, b, op) {
        Some(sign) -> float_inf(fmt, sign)
        None -> f64_to_bits(apply_double(op, bits_to_f64(a), bits_to_f64(b)))
      }
  }
}

/// IEEE-754 addition on raw bit patterns, with NaN → canonical, Inf/zero by IEEE rules.
fn fadd(fmt: FloatFmt, a: Int, b: Int) -> Int {
  case classify(fmt, a), classify(fmt, b) {
    CNan, _ -> canonical_nan(fmt)
    _, CNan -> canonical_nan(fmt)
    CInf(sa), CInf(sb) ->
      // +Inf + -Inf is NaN; same-sign Infs add to that Inf.
      case sa == sb {
        True -> float_inf(fmt, sa)
        False -> canonical_nan(fmt)
      }
    CInf(sa), _ -> float_inf(fmt, sa)
    _, CInf(sb) -> float_inf(fmt, sb)
    CZero(sa), CZero(sb) ->
      // -0 only when both addends are -0; otherwise +0 (round-to-nearest).
      case sa == 1 && sb == 1 {
        True -> float_zero(fmt, 1)
        False -> float_zero(fmt, 0)
      }
    CZero(_), _ -> b
    _, CZero(_) -> a
    CFinite(_), CFinite(_) -> finite_binop(fmt, a, b, AddOp)
  }
}

/// IEEE-754 subtraction: `a - b = a + (-b)`.
fn fsub(fmt: FloatFmt, a: Int, b: Int) -> Int {
  fadd(fmt, a, flip_sign(fmt, b))
}

/// IEEE-754 multiplication on raw bit patterns.
fn fmul(fmt: FloatFmt, a: Int, b: Int) -> Int {
  case classify(fmt, a), classify(fmt, b) {
    CNan, _ -> canonical_nan(fmt)
    _, CNan -> canonical_nan(fmt)
    CZero(_), CInf(_) -> canonical_nan(fmt)
    CInf(_), CZero(_) -> canonical_nan(fmt)
    CInf(sa), CInf(sb) -> float_inf(fmt, int.bitwise_exclusive_or(sa, sb))
    CInf(sa), CFinite(sb) -> float_inf(fmt, int.bitwise_exclusive_or(sa, sb))
    CFinite(sa), CInf(sb) -> float_inf(fmt, int.bitwise_exclusive_or(sa, sb))
    CZero(sa), CZero(sb) -> float_zero(fmt, int.bitwise_exclusive_or(sa, sb))
    CZero(sa), CFinite(sb) -> float_zero(fmt, int.bitwise_exclusive_or(sa, sb))
    CFinite(sa), CZero(sb) -> float_zero(fmt, int.bitwise_exclusive_or(sa, sb))
    CFinite(_), CFinite(_) -> finite_binop(fmt, a, b, MulOp)
  }
}

/// IEEE-754 division on raw bit patterns.
fn fdiv(fmt: FloatFmt, a: Int, b: Int) -> Int {
  case classify(fmt, a), classify(fmt, b) {
    CNan, _ -> canonical_nan(fmt)
    _, CNan -> canonical_nan(fmt)
    CInf(_), CInf(_) -> canonical_nan(fmt)
    CZero(_), CZero(_) -> canonical_nan(fmt)
    CInf(sa), CZero(sb) -> float_inf(fmt, int.bitwise_exclusive_or(sa, sb))
    CInf(sa), CFinite(sb) -> float_inf(fmt, int.bitwise_exclusive_or(sa, sb))
    CZero(sa), CInf(sb) -> float_zero(fmt, int.bitwise_exclusive_or(sa, sb))
    CFinite(sa), CInf(sb) -> float_zero(fmt, int.bitwise_exclusive_or(sa, sb))
    CZero(sa), CFinite(sb) -> float_zero(fmt, int.bitwise_exclusive_or(sa, sb))
    CFinite(sa), CZero(sb) -> float_inf(fmt, int.bitwise_exclusive_or(sa, sb))
    CFinite(_), CFinite(_) -> finite_binop(fmt, a, b, DivOp)
  }
}

/// WASM `fmin` on raw bit patterns: either NaN → canonical NaN; opposite-signed zeroes
/// → `-0`; else the numerically smaller value (with `-Inf`/`+Inf` handled directly).
fn fmin(fmt: FloatFmt, a: Int, b: Int) -> Int {
  case classify(fmt, a), classify(fmt, b) {
    CNan, _ -> canonical_nan(fmt)
    _, CNan -> canonical_nan(fmt)
    CZero(sa), CZero(sb) ->
      // min of signed zeroes is -0 whenever either is -0.
      case sa == 1 || sb == 1 {
        True -> float_zero(fmt, 1)
        False -> float_zero(fmt, 0)
      }
    CInf(1), _ -> a
    CInf(0), _ -> b
    _, CInf(1) -> b
    _, CInf(0) -> a
    _, _ -> {
      let da = decode_float(fmt, a)
      let db = decode_float(fmt, b)
      case da <. db {
        True -> a
        False ->
          case db <. da {
            True -> b
            False -> a
          }
      }
    }
  }
}

/// WASM `fmax` on raw bit patterns: either NaN → canonical NaN; opposite-signed zeroes
/// → `+0`; else the numerically larger value (with `-Inf`/`+Inf` handled directly).
fn fmax(fmt: FloatFmt, a: Int, b: Int) -> Int {
  case classify(fmt, a), classify(fmt, b) {
    CNan, _ -> canonical_nan(fmt)
    _, CNan -> canonical_nan(fmt)
    CZero(sa), CZero(sb) ->
      // max of signed zeroes is +0 whenever either is +0.
      case sa == 0 || sb == 0 {
        True -> float_zero(fmt, 0)
        False -> float_zero(fmt, 1)
      }
    CInf(0), _ -> a
    CInf(1), _ -> b
    _, CInf(0) -> b
    _, CInf(1) -> a
    _, _ -> {
      let da = decode_float(fmt, a)
      let db = decode_float(fmt, b)
      case da >. db {
        True -> a
        False ->
          case db >. da {
            True -> b
            False -> a
          }
      }
    }
  }
}

/// The exact truncation-toward-zero of a finite float, as a (possibly huge) signed
/// integer. Computed from the exact significand decomposition, so it is precise even for
/// magnitudes far outside the i32/i64 range (the caller then clamps).
fn trunc_integer(fmt: FloatFmt, bits: Int) -> Int {
  let #(sign, sig, exp) = decompose(fmt, bits)
  let mag = case exp >= 0 {
    True -> sig * pow2(exp)
    // sig >= 0, so integer division truncates the magnitude toward zero.
    False -> sig / pow2(0 - exp)
  }
  signed_significand(sign, mag)
}

/// Saturating signed float→int truncation to `target_bits` (`i.._trunc_sat_.._s`).
/// NaN → 0; `-Inf` → INT_MIN; `+Inf` → INT_MAX; else truncate toward zero, clamp to
/// `[-2^(N-1), 2^(N-1)-1]`, and re-encode to the unsigned bit pattern.
fn trunc_sat_s(fmt: FloatFmt, bits: Int, target_bits: Int) -> Int {
  let lo = int_min_signed(target_bits)
  let hi = pow2(target_bits - 1) - 1
  case classify(fmt, bits) {
    CNan -> 0
    CInf(0) -> hi
    CInf(_) -> norm(lo, target_bits)
    CZero(_) -> 0
    CFinite(_) -> norm(int.clamp(trunc_integer(fmt, bits), lo, hi), target_bits)
  }
}

/// Saturating unsigned float→int truncation to `target_bits` (`i.._trunc_sat_.._u`).
/// NaN → 0; `<= 0`/`-Inf` → 0; `+Inf` → `2^N - 1`; else truncate toward zero and clamp
/// to `[0, 2^N - 1]`.
fn trunc_sat_u(fmt: FloatFmt, bits: Int, target_bits: Int) -> Int {
  let hi = pow2(target_bits) - 1
  case classify(fmt, bits) {
    CNan -> 0
    CInf(0) -> hi
    CInf(_) -> 0
    CZero(_) -> 0
    CFinite(1) -> 0
    CFinite(_) -> int.clamp(trunc_integer(fmt, bits), 0, hi)
  }
}

// ───────────────────────────── f32 (raw bits) ─────────────────────────────

/// 32-bit float addition; operands and result are raw binary32 bit patterns. NaN in or
/// produced → canonical NaN (`0x7FC00000`); ±Inf/±0 by IEEE; overflow → signed Inf.
pub fn f32_add(a: Int, b: Int) -> Int {
  fadd(f32_fmt, a, b)
}

/// 32-bit float subtraction; raw binary32 bit patterns. (`a - b = a + (-b)`.)
pub fn f32_sub(a: Int, b: Int) -> Int {
  fsub(f32_fmt, a, b)
}

/// 32-bit float multiplication; raw binary32 bit patterns. `0 * Inf` → canonical NaN.
pub fn f32_mul(a: Int, b: Int) -> Int {
  fmul(f32_fmt, a, b)
}

/// 32-bit float division; raw binary32 bit patterns. `x / 0` → signed Inf; `0/0` and
/// `Inf/Inf` → canonical NaN.
pub fn f32_div(a: Int, b: Int) -> Int {
  fdiv(f32_fmt, a, b)
}

/// 32-bit float minimum (WASM semantics); raw binary32 bit patterns. NaN → canonical
/// NaN; `min(+0, -0)` → `-0`.
pub fn f32_min(a: Int, b: Int) -> Int {
  fmin(f32_fmt, a, b)
}

/// 32-bit float maximum (WASM semantics); raw binary32 bit patterns. NaN → canonical
/// NaN; `max(+0, -0)` → `+0`.
pub fn f32_max(a: Int, b: Int) -> Int {
  fmax(f32_fmt, a, b)
}

// ───────────────────────────── f64 (raw bits) ─────────────────────────────

/// 64-bit float addition; operands and result are raw binary64 bit patterns. NaN in or
/// produced → canonical NaN (`0x7FF8000000000000`); ±Inf/±0 by IEEE; overflow → signed
/// Inf (computed exactly, never `badarith`).
pub fn f64_add(a: Int, b: Int) -> Int {
  fadd(f64_fmt, a, b)
}

/// 64-bit float subtraction; raw binary64 bit patterns. (`a - b = a + (-b)`.)
pub fn f64_sub(a: Int, b: Int) -> Int {
  fsub(f64_fmt, a, b)
}

/// 64-bit float multiplication; raw binary64 bit patterns. `0 * Inf` → canonical NaN.
pub fn f64_mul(a: Int, b: Int) -> Int {
  fmul(f64_fmt, a, b)
}

/// 64-bit float division; raw binary64 bit patterns. `x / 0` → signed Inf; `0/0` and
/// `Inf/Inf` → canonical NaN.
pub fn f64_div(a: Int, b: Int) -> Int {
  fdiv(f64_fmt, a, b)
}

/// 64-bit float minimum (WASM semantics); raw binary64 bit patterns. NaN → canonical
/// NaN; `min(+0, -0)` → `-0`.
pub fn f64_min(a: Int, b: Int) -> Int {
  fmin(f64_fmt, a, b)
}

/// 64-bit float maximum (WASM semantics); raw binary64 bit patterns. NaN → canonical
/// NaN; `max(+0, -0)` → `+0`.
pub fn f64_max(a: Int, b: Int) -> Int {
  fmax(f64_fmt, a, b)
}

// ───────────────────── private float workers (Phase-2 unit 06) ─────────────────────

/// The rounding direction for `round_to_integral`: toward `+∞` (`RCeil`), toward `-∞`
/// (`RFloor`), toward zero (`RTrunc`), or to the nearest integer with ties broken to even
/// (`RNearest`) — the latter being the WASM/IEEE default for `f*.nearest`.
type RoundMode {
  RCeil
  RFloor
  RTrunc
  RNearest
}

/// `1` if `r > 0`, else `0` — the round-away carry used by `ceil`/`floor` when the
/// truncated value has a nonzero fractional remainder `r`.
fn bump(r: Int) -> Int {
  case r > 0 {
    True -> 1
    False -> 0
  }
}

/// Encode the signed integer `v = (sign==0 ? m : -m)` exactly into `fmt`'s bit pattern.
///
/// Only ever called from `round_to_integral`, where the integral magnitude `m` is within
/// the format's exact-integer range (`m ≤ 2^mbits`, i.e. ≤ 2^23 for f32 and ≤ 2^52 for
/// f64), so the `int.to_float` round-trip introduces NO rounding and cannot overflow.
/// `sign` is the operand's sign bit (`0` positive, `1` negative). Returns the raw bits.
fn encode_int_magnitude(fmt: FloatFmt, sign: Int, m: Int) -> Int {
  let v = case sign {
    0 -> m
    _ -> 0 - m
  }
  case fmt.total {
    32 -> f32_round_to_bits(int.to_float(v))
    _ -> f64_to_bits(int.to_float(v))
  }
}

/// Round a float `bits` to an integral float of the same `fmt`, per `mode`.
///
/// Drives `ceil`/`floor`/`trunc`/`nearest`, which ARE in the spec's nondeterministic-NaN
/// set, so a NaN operand yields the canonical NaN. `±Inf` is returned unchanged and `±0`
/// is returned as the SAME signed zero. A finite operand is decomposed exactly (no native
/// double), rounded per `mode`, and—crucially—a zero magnitude result is emitted as the
/// signed zero matching the operand's sign (`ceil(-0.5) = -0`, `floor(0.5) = +0`,
/// `nearest(-0.3) = -0`). `RNearest` resolves ties to even via an exact remainder-vs-half
/// comparison (NOT `erlang:round/1`, which is ties-away-from-zero). Returns the raw bits.
fn round_to_integral(fmt: FloatFmt, bits: Int, mode: RoundMode) -> Int {
  case classify(fmt, bits) {
    CNan -> canonical_nan(fmt)
    CInf(_) -> bits
    CZero(_) -> bits
    CFinite(sign) -> {
      let #(_, sig, exp2) = decompose(fmt, bits)
      case exp2 >= 0 {
        // Already integral (no fractional bits): identity.
        True -> bits
        False -> {
          let f = 0 - exp2
          let q = sig / pow2(f)
          let r = sig - q * pow2(f)
          let m = case mode {
            RTrunc -> q
            RCeil ->
              case sign == 0 {
                True -> q + bump(r)
                False -> q
              }
            RFloor ->
              case sign == 1 {
                True -> q + bump(r)
                False -> q
              }
            RNearest -> {
              let half = pow2(f - 1)
              case int.compare(r, half) {
                order.Lt -> q
                order.Gt -> q + 1
                // Exact tie: pick the even neighbour.
                order.Eq ->
                  case q % 2 == 0 {
                    True -> q
                    False -> q + 1
                  }
              }
            }
          }
          case m == 0 {
            True -> float_zero(fmt, sign)
            False -> encode_int_magnitude(fmt, sign, m)
          }
        }
      }
    }
  }
}

/// IEEE square root on raw `fmt` bits. NaN → canonical NaN; `-Inf` and any negative finite
/// → canonical NaN; `+Inf` → `+Inf`; `±0` → that same signed zero; a positive finite is
/// decoded to a native double, rooted, and re-rounded to `fmt`.
///
/// Uses Erlang `math:sqrt/1` (the hardware/libm CORRECTLY-ROUNDED double sqrt), NOT
/// `gleam/float.square_root` (which is `math:pow(_, 0.5)` — `pow` goes through `exp`/`log`
/// and is NOT correctly rounded, so it returns a 1-ULP-off f64 result on several spec
/// `sqrt` vectors). The WASM spec requires `fsqrt` to be correctly rounded
/// (exec/numerics.html). `math:sqrt` is reached ONLY on a positive-finite `d`, so it never
/// raises. The f32 path through the f64 root is correctly single-rounded (f64's 53
/// significand bits ≥ 2·24+2). Returns raw bits.
fn fsqrt(fmt: FloatFmt, bits: Int) -> Int {
  case classify(fmt, bits) {
    CNan -> canonical_nan(fmt)
    CInf(0) -> bits
    CInf(_) -> canonical_nan(fmt)
    CZero(_) -> bits
    // Negative finite (sign bit set) → NaN.
    CFinite(1) -> canonical_nan(fmt)
    // Positive finite (sign bit 0): the only remaining case.
    CFinite(_) -> {
      let d = decode_float(fmt, bits)
      let s = math_sqrt(d)
      case fmt.total {
        32 -> f32_round_to_bits(s)
        _ -> f64_to_bits(s)
      }
    }
  }
}

/// Erlang `math:sqrt/1` — the correctly-rounded IEEE-754 double square root. Used by `fsqrt`
/// instead of `float.square_root` (= `math:pow(_, 0.5)`, not correctly rounded). Only ever
/// called on a positive-finite operand, so it never raises `badarith`.
@external(erlang, "math", "sqrt")
fn math_sqrt(x: Float) -> Float

/// Total order of two non-NaN floats. `Ok(order)` is the IEEE ordering of `a` and `b`
/// (with `+0`/`-0` comparing `Eq` and `+Inf > finite > -Inf`); `Error(Nil)` iff EITHER
/// operand is NaN (the unordered case). `±Inf` is ordered by its sign WITHOUT decoding —
/// decoding Inf/NaN bits to a native double would `badmatch` — so only zero/finite
/// operands ever reach `decode_float`.
fn fcmp(fmt: FloatFmt, a: Int, b: Int) -> Result(order.Order, Nil) {
  case classify(fmt, a), classify(fmt, b) {
    CNan, _ -> Error(Nil)
    _, CNan -> Error(Nil)
    CInf(0), CInf(0) -> Ok(order.Eq)
    CInf(1), CInf(1) -> Ok(order.Eq)
    CInf(0), _ -> Ok(order.Gt)
    _, CInf(0) -> Ok(order.Lt)
    CInf(1), _ -> Ok(order.Lt)
    _, CInf(1) -> Ok(order.Gt)
    _, _ -> {
      let da = decode_float(fmt, a)
      let db = decode_float(fmt, b)
      case da <. db {
        True -> Ok(order.Lt)
        False ->
          case da >. db {
            True -> Ok(order.Gt)
            False -> Ok(order.Eq)
          }
      }
    }
  }
}

/// `f*.eq` worker: `1` iff `a` and `b` are ordered-equal (`+0 == -0`); any NaN → `0`.
fn f_eq(fmt: FloatFmt, a: Int, b: Int) -> Int {
  bool_to_i32(fcmp(fmt, a, b) == Ok(order.Eq))
}

/// `f*.ne` worker: `1` iff `a` and `b` are NOT ordered-equal; any NaN → `1`.
fn f_ne(fmt: FloatFmt, a: Int, b: Int) -> Int {
  bool_to_i32(fcmp(fmt, a, b) != Ok(order.Eq))
}

/// `f*.lt` worker: `1` iff `a < b`; any NaN → `0`.
fn f_lt(fmt: FloatFmt, a: Int, b: Int) -> Int {
  bool_to_i32(fcmp(fmt, a, b) == Ok(order.Lt))
}

/// `f*.gt` worker: `1` iff `a > b`; any NaN → `0`.
fn f_gt(fmt: FloatFmt, a: Int, b: Int) -> Int {
  bool_to_i32(fcmp(fmt, a, b) == Ok(order.Gt))
}

/// `f*.le` worker: `1` iff `a <= b` (`Lt` or `Eq`); any NaN → `0`.
fn f_le(fmt: FloatFmt, a: Int, b: Int) -> Int {
  case fcmp(fmt, a, b) {
    Ok(order.Lt) | Ok(order.Eq) -> 1
    _ -> 0
  }
}

/// `f*.ge` worker: `1` iff `a >= b` (`Gt` or `Eq`); any NaN → `0`.
fn f_ge(fmt: FloatFmt, a: Int, b: Int) -> Int {
  case fcmp(fmt, a, b) {
    Ok(order.Gt) | Ok(order.Eq) -> 1
    _ -> 0
  }
}

/// Trapping SIGNED float→int truncation to width `n`. Per `exec/numerics`, ONLY NaN traps
/// `InvalidConversionToInteger`; `±Inf` (like any out-of-range value) traps `IntOverflow`
/// (the spec test suite: `trunc(inf)` → "integer overflow", `trunc(nan)` → "invalid
/// conversion to integer"). `Ok(0)` on `±0`; otherwise the EXACT toward-zero truncation `j`
/// (bignum, via `trunc_integer`) is range-checked against `[-2^(n-1), 2^(n-1)-1]`:
/// in range → `Ok(norm(j, n))` (the unsigned bit pattern, so `-1.0 → 0xFFFF…`), else
/// `Error(IntOverflow)`. The exact `j` makes the boundary precise — `2^31` overflows but
/// the largest f32 strictly below it does not.
fn trunc_trap_s(fmt: FloatFmt, bits: Int, n: Int) -> Result(Int, TrapReason) {
  let lo = int_min_signed(n)
  let hi = pow2(n - 1) - 1
  case classify(fmt, bits) {
    CNan -> Error(InvalidConversionToInteger)
    CInf(_) -> Error(IntOverflow)
    CZero(_) -> Ok(0)
    CFinite(_) -> {
      let j = trunc_integer(fmt, bits)
      case j >= lo && j <= hi {
        True -> Ok(norm(j, n))
        False -> Error(IntOverflow)
      }
    }
  }
}

/// Trapping UNSIGNED float→int truncation to width `n`. Per `exec/numerics`, ONLY NaN traps
/// `InvalidConversionToInteger`; `±Inf` traps `IntOverflow` (spec test suite, as for the
/// signed variant). `Ok(0)` on `±0`; otherwise the EXACT toward-zero truncation `j` is
/// range-checked against `[0, 2^n-1]`: in range → `Ok(j)`, else `Error(IntOverflow)`
/// (so any negative truncation, e.g. `-1.0`, overflows).
fn trunc_trap_u(fmt: FloatFmt, bits: Int, n: Int) -> Result(Int, TrapReason) {
  let hi = pow2(n) - 1
  case classify(fmt, bits) {
    CNan -> Error(InvalidConversionToInteger)
    CInf(_) -> Error(IntOverflow)
    CZero(_) -> Ok(0)
    CFinite(_) -> {
      let j = trunc_integer(fmt, bits)
      case j >= 0 && j <= hi {
        True -> Ok(j)
        False -> Error(IntOverflow)
      }
    }
  }
}

/// Convert the signed integer `v` to `target`'s bit pattern, rounding to nearest ties-to-
/// even. Never traps, never overflows to Inf (`max|i64| = 2^63 < f32_max = 2^128`).
///
/// The f64 path is a single correctly-rounded `erlang:float/1` (ties-to-even on OTP 29). The
/// f32 path goes via f64, but a naive `i64 → f64 → f32` DOUBLE-ROUNDS for `|v| >= 2^53`
/// (the i64→f64 step can land exactly on an f32 tie, losing the "strictly above" bit), so
/// `int_to_f32_bits` pre-rounds the integer to 53 bits with a round-to-ODD sticky first —
/// then the f64 is exact and the f64→f32 step rounds correctly (the standard
/// double-rounding-avoidance trick). For `|v| < 2^53` the f64 is already exact (no
/// pre-rounding), so i32→f32 and small i64→f32 are unaffected.
fn int_to_float(target: FloatFmt, v: Int) -> Int {
  case target.total {
    32 -> int_to_f32_bits(v)
    _ -> f64_to_bits(int.to_float(v))
  }
}

/// Convert the signed integer `v` to f32 bits with CORRECT single rounding, avoiding the
/// `i64 → f64 → f32` double-rounding by pre-rounding `|v|` to 53 significant bits with a
/// round-to-ODD sticky when `|v|` exceeds f64's 53-bit exact range. With an odd 53-bit
/// intermediate, the subsequent f64→f32 round-to-nearest is provably the correctly-rounded
/// f32 (the discarded low bits can never re-create a spurious tie).
fn int_to_f32_bits(v: Int) -> Int {
  case v == 0 {
    True -> 0
    False -> {
      let neg = v < 0
      let m = case neg {
        True -> 0 - v
        False -> v
      }
      let bl = bit_length(m)
      let exact = case bl <= 53 {
        // f64 holds `m` exactly → the single f64→f32 rounding is already correct.
        True -> int.to_float(m)
        False -> {
          // Keep the top 53 bits; force the LSB odd if any low bit was dropped (sticky),
          // so the f64 is exact AND the f32 rounding cannot double-round.
          let shift = bl - 53
          let high = int.bitwise_shift_right(m, shift)
          let dropped = m - int.bitwise_shift_left(high, shift)
          let high_odd = case dropped != 0 && int.bitwise_and(high, 1) == 0 {
            True -> int.bitwise_or(high, 1)
            False -> high
          }
          int.to_float(high_odd) *. int.to_float(pow2(shift))
        }
      }
      let signed = case neg {
        True -> 0.0 -. exact
        False -> exact
      }
      f32_round_to_bits(signed)
    }
  }
}

// ───────────────────────── «RTNUM2-SIG-FROZEN» — Phase-2 float/convert heads ─────────────────────────
// SIGNATURES frozen by unit 01 (`todo` bodies); BODIES implemented by unit 06; the
// `NumOp/ConvOp → fn-name` map in `emit_core` (unit 10) MUST match these names. Operands
// and results are raw IEEE-754 bit-pattern `Int`s (D5). Each is documented for its WASM
// spec semantics; the body is `todo` until unit 06.

// ── f32 unary (raw bits → raw bits) ──────────────────────────────────────────

/// `f32.abs` — clear the sign bit. A PURE sign-bit op: it does NOT canonicalize NaN
/// (the spec does not list `abs` in `nans`), so a NaN operand keeps its payload, only its
/// sign cleared. Returns the raw bit pattern.
pub fn f32_abs(a: Int) -> Int {
  case sign_of(f32_fmt, a) {
    1 -> flip_sign(f32_fmt, a)
    _ -> a
  }
}

/// `f32.neg` — flip the sign bit (including for NaN/±0). PURE sign-bit op; preserves the
/// NaN payload (does NOT canonicalize). Returns the raw bit pattern.
pub fn f32_neg(a: Int) -> Int {
  flip_sign(f32_fmt, a)
}

/// `f32.ceil` — round toward +∞ (NaN→canonical NaN; ±Inf/±0 preserved; small fractions
/// yield the operand-signed zero, e.g. `ceil(-0.5) = -0`). Bit pattern.
pub fn f32_ceil(a: Int) -> Int {
  round_to_integral(f32_fmt, a, RCeil)
}

/// `f32.floor` — round toward −∞ (NaN→canonical; ±Inf/±0 preserved; `floor(0.5) = +0`).
/// Bit pattern.
pub fn f32_floor(a: Int) -> Int {
  round_to_integral(f32_fmt, a, RFloor)
}

/// `f32.trunc` — round toward zero (NaN→canonical; ±Inf/±0 preserved; `trunc(-0.7) = -0`).
/// Bit pattern.
pub fn f32_trunc(a: Int) -> Int {
  round_to_integral(f32_fmt, a, RTrunc)
}

/// `f32.nearest` — round to nearest, ties to even (NaN→canonical; `nearest(2.5) = 2`,
/// `nearest(3.5) = 4`, `nearest(0.5) = +0`). Bit pattern.
pub fn f32_nearest(a: Int) -> Int {
  round_to_integral(f32_fmt, a, RNearest)
}

/// `f32.sqrt` — IEEE square root. NaN/`-Inf`/negative → canonical NaN; `+Inf` → `+Inf`;
/// `±0` → that signed zero; positive finite → correctly-rounded root. Bit pattern.
pub fn f32_sqrt(a: Int) -> Int {
  fsqrt(f32_fmt, a)
}

/// `f32.copysign(a, b)` — magnitude (and NaN payload) of `a` with the sign of `b`. A PURE
/// sign-bit op: it does NOT canonicalize NaN. Returns the raw bit pattern.
pub fn f32_copysign(a: Int, b: Int) -> Int {
  case sign_of(f32_fmt, a) == sign_of(f32_fmt, b) {
    True -> a
    False -> flip_sign(f32_fmt, a)
  }
}

// ── f64 unary (raw bits → raw bits) ──────────────────────────────────────────

/// `f64.abs` — clear the sign bit. PURE sign-bit op; preserves the NaN payload (does NOT
/// canonicalize). Bit pattern.
pub fn f64_abs(a: Int) -> Int {
  case sign_of(f64_fmt, a) {
    1 -> flip_sign(f64_fmt, a)
    _ -> a
  }
}

/// `f64.neg` — flip the sign bit. PURE sign-bit op; preserves the NaN payload. Bit pattern.
pub fn f64_neg(a: Int) -> Int {
  flip_sign(f64_fmt, a)
}

/// `f64.ceil` — round toward +∞ (NaN→canonical; ±Inf/±0 preserved; `ceil(-0.5) = -0`).
/// Bit pattern.
pub fn f64_ceil(a: Int) -> Int {
  round_to_integral(f64_fmt, a, RCeil)
}

/// `f64.floor` — round toward −∞ (NaN→canonical; ±Inf/±0 preserved; `floor(0.5) = +0`).
/// Bit pattern.
pub fn f64_floor(a: Int) -> Int {
  round_to_integral(f64_fmt, a, RFloor)
}

/// `f64.trunc` — round toward zero (NaN→canonical; ±Inf/±0 preserved). Bit pattern.
pub fn f64_trunc(a: Int) -> Int {
  round_to_integral(f64_fmt, a, RTrunc)
}

/// `f64.nearest` — round to nearest, ties to even (NaN→canonical; `nearest(2.5) = 2`).
/// Bit pattern.
pub fn f64_nearest(a: Int) -> Int {
  round_to_integral(f64_fmt, a, RNearest)
}

/// `f64.sqrt` — IEEE square root. NaN/`-Inf`/negative → canonical NaN; `+Inf` → `+Inf`;
/// `±0` → that signed zero; positive finite → correctly-rounded root. Bit pattern.
pub fn f64_sqrt(a: Int) -> Int {
  fsqrt(f64_fmt, a)
}

/// `f64.copysign(a, b)` — magnitude (and NaN payload) of `a` with the sign of `b`. PURE
/// sign-bit op; does NOT canonicalize NaN. Bit pattern.
pub fn f64_copysign(a: Int, b: Int) -> Int {
  case sign_of(f64_fmt, a) == sign_of(f64_fmt, b) {
    True -> a
    False -> flip_sign(f64_fmt, a)
  }
}

// ── float comparisons → i32 truth value (0/1) ────────────────────────────────

/// `f32.eq` — ordered equality (`+0 == -0`; any NaN → `0`). Returns `1`/`0`.
pub fn f32_eq(a: Int, b: Int) -> Int {
  f_eq(f32_fmt, a, b)
}

/// `f32.ne` — ordered/unordered inequality (any NaN → `1`). Returns `1`/`0`.
pub fn f32_ne(a: Int, b: Int) -> Int {
  f_ne(f32_fmt, a, b)
}

/// `f32.lt` — ordered less-than (NaN → `0`). Returns `1`/`0`.
pub fn f32_lt(a: Int, b: Int) -> Int {
  f_lt(f32_fmt, a, b)
}

/// `f32.gt` — ordered greater-than (NaN → `0`). Returns `1`/`0`.
pub fn f32_gt(a: Int, b: Int) -> Int {
  f_gt(f32_fmt, a, b)
}

/// `f32.le` — ordered less-than-or-equal (NaN → `0`). Returns `1`/`0`.
pub fn f32_le(a: Int, b: Int) -> Int {
  f_le(f32_fmt, a, b)
}

/// `f32.ge` — ordered greater-than-or-equal (NaN → `0`). Returns `1`/`0`.
pub fn f32_ge(a: Int, b: Int) -> Int {
  f_ge(f32_fmt, a, b)
}

/// `f64.eq` — ordered equality (`+0 == -0`; any NaN → `0`). Returns `1`/`0`.
pub fn f64_eq(a: Int, b: Int) -> Int {
  f_eq(f64_fmt, a, b)
}

/// `f64.ne` — ordered/unordered inequality (any NaN → `1`). Returns `1`/`0`.
pub fn f64_ne(a: Int, b: Int) -> Int {
  f_ne(f64_fmt, a, b)
}

/// `f64.lt` — ordered less-than (NaN → `0`). Returns `1`/`0`.
pub fn f64_lt(a: Int, b: Int) -> Int {
  f_lt(f64_fmt, a, b)
}

/// `f64.gt` — ordered greater-than (NaN → `0`). Returns `1`/`0`.
pub fn f64_gt(a: Int, b: Int) -> Int {
  f_gt(f64_fmt, a, b)
}

/// `f64.le` — ordered less-than-or-equal (NaN → `0`). Returns `1`/`0`.
pub fn f64_le(a: Int, b: Int) -> Int {
  f_le(f64_fmt, a, b)
}

/// `f64.ge` — ordered greater-than-or-equal (NaN → `0`). Returns `1`/`0`.
pub fn f64_ge(a: Int, b: Int) -> Int {
  f_ge(f64_fmt, a, b)
}

// ── TRAPPING float→int truncation → Result(Int, TrapReason) ──────────────────
// `Error(InvalidConversionToInteger)` on NaN/±Inf; `Error(IntOverflow)` when the
// truncated magnitude is out of the target's range; else `Ok(bits)` (truncate toward 0).
// Distinct from the total saturating `*_trunc_sat_*` above.

/// `i32.trunc_f32_s` — trapping signed f32 → i32. `Error(InvalidConversionToInteger)` on
/// NaN/±Inf; `Error(IntOverflow)` if the toward-zero truncation is outside
/// `[-2^31, 2^31-1]`; else `Ok(bits)` (the unsigned i32 bit pattern).
pub fn i32_trunc_f32_s(a: Int) -> Result(Int, TrapReason) {
  trunc_trap_s(f32_fmt, a, 32)
}

/// `i32.trunc_f32_u` — trapping unsigned f32 → i32. `Error(InvalidConversionToInteger)` on
/// NaN/±Inf; `Error(IntOverflow)` if the truncation is outside `[0, 2^32-1]` (so any
/// negative value traps); else `Ok(bits)`.
pub fn i32_trunc_f32_u(a: Int) -> Result(Int, TrapReason) {
  trunc_trap_u(f32_fmt, a, 32)
}

/// `i32.trunc_f64_s` — trapping signed f64 → i32. Same trap split as `i32_trunc_f32_s`.
pub fn i32_trunc_f64_s(a: Int) -> Result(Int, TrapReason) {
  trunc_trap_s(f64_fmt, a, 32)
}

/// `i32.trunc_f64_u` — trapping unsigned f64 → i32. Same trap split as `i32_trunc_f32_u`.
pub fn i32_trunc_f64_u(a: Int) -> Result(Int, TrapReason) {
  trunc_trap_u(f64_fmt, a, 32)
}

/// `i64.trunc_f32_s` — trapping signed f32 → i64. Range `[-2^63, 2^63-1]`; trap split as
/// the i32 signed variant.
pub fn i64_trunc_f32_s(a: Int) -> Result(Int, TrapReason) {
  trunc_trap_s(f32_fmt, a, 64)
}

/// `i64.trunc_f32_u` — trapping unsigned f32 → i64. Range `[0, 2^64-1]`; trap split as the
/// i32 unsigned variant.
pub fn i64_trunc_f32_u(a: Int) -> Result(Int, TrapReason) {
  trunc_trap_u(f32_fmt, a, 64)
}

/// `i64.trunc_f64_s` — trapping signed f64 → i64. Range `[-2^63, 2^63-1]`.
pub fn i64_trunc_f64_s(a: Int) -> Result(Int, TrapReason) {
  trunc_trap_s(f64_fmt, a, 64)
}

/// `i64.trunc_f64_u` — trapping unsigned f64 → i64. Range `[0, 2^64-1]`.
pub fn i64_trunc_f64_u(a: Int) -> Result(Int, TrapReason) {
  trunc_trap_u(f64_fmt, a, 64)
}

// ── int→float conversion → Int (round to nearest, ties to even). Never traps. ─
// Operand is the raw integer bit pattern (interpreted signed for `*_s`, unsigned for
// `*_u`); the result is the raw float bit pattern.

/// `f32.convert_i32_s` — signed i32 → f32 (operand read as two's-complement; round to
/// nearest ties-to-even). Bit pattern.
pub fn f32_convert_i32_s(a: Int) -> Int {
  int_to_float(f32_fmt, signed(a, 32))
}

/// `f32.convert_i32_u` — unsigned i32 → f32 (operand read as the raw value). Bit pattern.
pub fn f32_convert_i32_u(a: Int) -> Int {
  int_to_float(f32_fmt, a)
}

/// `f32.convert_i64_s` — signed i64 → f32 (round to nearest ties-to-even; the f64
/// intermediate yields the correctly single-rounded f32). Bit pattern.
pub fn f32_convert_i64_s(a: Int) -> Int {
  int_to_float(f32_fmt, signed(a, 64))
}

/// `f32.convert_i64_u` — unsigned i64 → f32. Bit pattern.
pub fn f32_convert_i64_u(a: Int) -> Int {
  int_to_float(f32_fmt, a)
}

/// `f64.convert_i32_s` — signed i32 → f64 (exact; `|v| < 2^31 < 2^53`). Bit pattern.
pub fn f64_convert_i32_s(a: Int) -> Int {
  int_to_float(f64_fmt, signed(a, 32))
}

/// `f64.convert_i32_u` — unsigned i32 → f64 (exact). Bit pattern.
pub fn f64_convert_i32_u(a: Int) -> Int {
  int_to_float(f64_fmt, a)
}

/// `f64.convert_i64_s` — signed i64 → f64 (round to nearest ties-to-even). Bit pattern.
pub fn f64_convert_i64_s(a: Int) -> Int {
  int_to_float(f64_fmt, signed(a, 64))
}

/// `f64.convert_i64_u` — unsigned i64 → f64 (round to nearest ties-to-even). Bit pattern.
pub fn f64_convert_i64_u(a: Int) -> Int {
  int_to_float(f64_fmt, a)
}

// ── float width changes → Int (raw bits) ─────────────────────────────────────

/// `f32.demote_f64` — narrow an f64 to f32. NaN → canonical f32 NaN; `±Inf`/`±0` keep
/// their kind+sign; a finite f64 is round-to-single (ties-to-even) and may OVERFLOW to
/// `±Inf` (the 32-bit float construct saturates without raising). Returns the f32 bits.
pub fn f32_demote_f64(a: Int) -> Int {
  case classify(f64_fmt, a) {
    CNan -> canonical_nan(f32_fmt)
    CInf(s) -> float_inf(f32_fmt, s)
    CZero(s) -> float_zero(f32_fmt, s)
    CFinite(_) -> f32_round_to_bits(bits_to_f64(a))
  }
}

/// `f64.promote_f32` — widen an f32 to f64. NaN (incl. signaling) → quiet canonical f64
/// NaN under the lock; `±Inf`/`±0` keep their kind+sign; every finite f32 is EXACTLY
/// representable in f64 (no rounding). Returns the f64 bits.
pub fn f64_promote_f32(a: Int) -> Int {
  case classify(f32_fmt, a) {
    CNan -> canonical_nan(f64_fmt)
    CInf(s) -> float_inf(f64_fmt, s)
    CZero(s) -> float_zero(f64_fmt, s)
    CFinite(_) -> f64_to_bits(bits_to_f32(a))
  }
}
