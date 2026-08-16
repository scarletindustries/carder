//// Spec-cited, differential tests for `rt_simd`'s pass-07a surface: the shared lane codec
//// plus the integer shape-preserving arithmetic core (add/sub/mul, neg/abs, saturating
//// add/sub, min/max, avgr_u, shifts, popcnt).
////
//// Assertions target the WebAssembly fixed-width SIMD spec (the `i*x*` vector operators,
//// <https://webassembly.github.io/spec/core/exec/numerics.html>), NOT whatever the impl
//// happens to emit. Every op is checked DIFFERENTIALLY against an INDEPENDENT test-side
//// oracle — a flat `List(Int)` reimplementation of the per-lane spec formula, packed
//// little-endian (D5) and compared byte-for-byte to the head's 16-byte result. The oracle
//// deliberately uses `%` / `/` (not the impl's `band`) so a shared bug cannot hide. Spec
//// edge cases are pinned with hand-worked values: two's-complement wrap, the saturation
//// boundaries, `avgr_u` rounding, shift-count masking mod the lane width, `popcnt`,
//// signed-vs-unsigned min/max, and the little-endian lane layout.

import carder/runtime/rt_simd
import gleam/int
import gleam/list
import gleeunit/should

// ───────────────────────── independent test-side oracle ─────────────────────────

fn two_pow(n: Int) -> Int {
  int.bitwise_shift_left(1, n)
}

/// Independent unsigned wrap of `x` to `w` bits (via `%`, not the impl's `band`).
fn umask(x: Int, w: Int) -> Int {
  let m = two_pow(w)
  let r = x % m
  case r < 0 {
    True -> r + m
    False -> r
  }
}

/// Independent two's-complement signed interpretation of a `w`-bit pattern.
fn sgn(u: Int, w: Int) -> Int {
  let m = two_pow(w)
  case u >= m / 2 {
    True -> u - m
    False -> u
  }
}

/// Independent clamp (used by the saturating-op oracle).
fn clamp(x: Int, lo: Int, hi: Int) -> Int {
  case x < lo {
    True -> lo
    False ->
      case x > hi {
        True -> hi
        False -> x
      }
  }
}

/// Independent per-byte population count (`0 ≤ x < 256`).
fn popcount(x: Int) -> Int {
  case x {
    0 -> 0
    _ -> x % 2 + popcount(x / 2)
  }
}

/// Independent little-endian packer: `lanes` (lane 0 first), each `w` bits wide.
fn pack(lanes: List(Int), w: Int) -> BitArray {
  list.fold(lanes, <<>>, fn(acc, lane) {
    let norm = umask(lane, w)
    <<acc:bits, norm:size(w)-little>>
  })
}

fn splat8(x: Int) -> BitArray {
  pack(list.repeat(x, 16), 8)
}

fn splat16(x: Int) -> BitArray {
  pack(list.repeat(x, 8), 16)
}

fn splat32(x: Int) -> BitArray {
  pack(list.repeat(x, 4), 32)
}

fn splat64(x: Int) -> BitArray {
  pack(list.repeat(x, 2), 64)
}

// ── differential drivers: run the head, compare to the oracle-computed lanes ──

fn diff2(
  a: List(Int),
  b: List(Int),
  w: Int,
  head: fn(BitArray, BitArray) -> BitArray,
  op: fn(Int, Int) -> Int,
) -> Nil {
  should.equal(head(pack(a, w), pack(b, w)), pack(list.map2(a, b, op), w))
}

fn diff1(
  a: List(Int),
  w: Int,
  head: fn(BitArray) -> BitArray,
  op: fn(Int) -> Int,
) -> Nil {
  should.equal(head(pack(a, w)), pack(list.map(a, op), w))
}

fn diff_shift(
  a: List(Int),
  count: Int,
  w: Int,
  head: fn(BitArray, Int) -> BitArray,
  op: fn(Int, Int) -> Int,
) -> Nil {
  should.equal(
    head(pack(a, w), count),
    pack(list.map(a, fn(x) { op(x, count) }), w),
  )
}

// ── representative lane fixtures (edge-laden: 0, 1, INT_MAX, INT_MIN, -1, …) ──

const i8_a = [
  0x00, 0x01, 0x7F, 0x80, 0xFF, 0xFE, 0x02, 0x10, 0x81, 0x40, 0xC0, 0x7E, 0x03,
  0xAB, 0x55, 0x99,
]

const i8_b = [
  0x00, 0xFF, 0x01, 0x01, 0xFF, 0x02, 0x7F, 0x80, 0x7F, 0x40, 0x80, 0x02, 0xFD,
  0x54, 0xAA, 0x01,
]

const i16_a = [0x0000, 0x0001, 0x7FFF, 0x8000, 0xFFFF, 0x1234, 0x8001, 0x00FF]

const i16_b = [0x0000, 0xFFFF, 0x0001, 0x0001, 0xFFFF, 0x4321, 0x7FFF, 0xFF00]

const i32_a = [0x00000001, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF]

const i32_b = [0xFFFFFFFF, 0x00000001, 0x00000001, 0x00000002]

const i64_a = [0x7FFFFFFFFFFFFFFF, 0x8000000000000000]

const i64_b = [0x0000000000000001, 0xFFFFFFFFFFFFFFFF]

// ───────────────────────── codec round-trip + lane layout ─────────────────────────

/// Adding the zero vector is the identity — this exercises `decode_lanes ∘ encode_lanes`
/// at every shape (the shared codec 07b/07c/07d reuse) and asserts it round-trips.
pub fn codec_roundtrip_test() {
  should.equal(rt_simd.i8x16_add(pack(i8_a, 8), splat8(0)), pack(i8_a, 8))
  should.equal(rt_simd.i8x16_add(splat8(0), pack(i8_a, 8)), pack(i8_a, 8))
  should.equal(rt_simd.i16x8_add(pack(i16_a, 16), splat16(0)), pack(i16_a, 16))
  should.equal(rt_simd.i32x4_add(pack(i32_a, 32), splat32(0)), pack(i32_a, 32))
  should.equal(rt_simd.i64x2_add(pack(i64_a, 64), splat64(0)), pack(i64_a, 64))
}

/// The lane layout is LITTLE-ENDIAN (D5): the i32 lane at byte offset 0 of
/// `<<1,2,3,4, …>>` is `0x04030201`, so `>> 24` yields its highest byte `0x04`. A
/// big-endian decode would read `0x01020304` and produce `0x01` — this pins the direction.
pub fn little_endian_lane_layout_test() {
  let v = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>
  should.equal(rt_simd.i32x4_shr_u(v, 24), pack([0x04, 0x08, 0x0C, 0x10], 32))
}

// ───────────────────────── arithmetic: add / sub / mul ─────────────────────────

pub fn add_test() {
  diff2(i8_a, i8_b, 8, rt_simd.i8x16_add, fn(x, y) { umask(x + y, 8) })
  diff2(i16_a, i16_b, 16, rt_simd.i16x8_add, fn(x, y) { umask(x + y, 16) })
  diff2(i32_a, i32_b, 32, rt_simd.i32x4_add, fn(x, y) { umask(x + y, 32) })
  diff2(i64_a, i64_b, 64, rt_simd.i64x2_add, fn(x, y) { umask(x + y, 64) })
  // spec D.1: i8x16.add of 0xFF (=-1) and 0x02 → 0x01 (257 mod 256).
  should.equal(rt_simd.i8x16_add(splat8(0xFF), splat8(0x02)), splat8(0x01))
}

pub fn sub_test() {
  diff2(i8_a, i8_b, 8, rt_simd.i8x16_sub, fn(x, y) { umask(x - y, 8) })
  diff2(i16_a, i16_b, 16, rt_simd.i16x8_sub, fn(x, y) { umask(x - y, 16) })
  diff2(i32_a, i32_b, 32, rt_simd.i32x4_sub, fn(x, y) { umask(x - y, 32) })
  diff2(i64_a, i64_b, 64, rt_simd.i64x2_sub, fn(x, y) { umask(x - y, 64) })
  // 0x00 - 0x01 wraps to 0xFF.
  should.equal(rt_simd.i8x16_sub(splat8(0x00), splat8(0x01)), splat8(0xFF))
}

pub fn mul_test() {
  diff2(i16_a, i16_b, 16, rt_simd.i16x8_mul, fn(x, y) { umask(x * y, 16) })
  diff2(i32_a, i32_b, 32, rt_simd.i32x4_mul, fn(x, y) { umask(x * y, 32) })
  diff2(i64_a, i64_b, 64, rt_simd.i64x2_mul, fn(x, y) { umask(x * y, 64) })
  // spec D.1: i16x8.mul of 0xFFFF (=-1) and 0xFFFF (=-1) → 0x0001.
  should.equal(
    rt_simd.i16x8_mul(splat16(0xFFFF), splat16(0xFFFF)),
    splat16(0x0001),
  )
}

// ───────────────────────── neg / abs ─────────────────────────

pub fn neg_test() {
  diff1(i8_a, 8, rt_simd.i8x16_neg, fn(x) { umask(0 - x, 8) })
  diff1(i16_a, 16, rt_simd.i16x8_neg, fn(x) { umask(0 - x, 16) })
  diff1(i32_a, 32, rt_simd.i32x4_neg, fn(x) { umask(0 - x, 32) })
  diff1(i64_a, 64, rt_simd.i64x2_neg, fn(x) { umask(0 - x, 64) })
  // spec D.3: neg(INT_MIN) = INT_MIN (wraps).
  should.equal(rt_simd.i8x16_neg(splat8(0x80)), splat8(0x80))
  should.equal(rt_simd.i8x16_neg(splat8(0x01)), splat8(0xFF))
}

pub fn abs_test() {
  diff1(i8_a, 8, rt_simd.i8x16_abs, fn(x) {
    umask(int.absolute_value(sgn(x, 8)), 8)
  })
  diff1(i16_a, 16, rt_simd.i16x8_abs, fn(x) {
    umask(int.absolute_value(sgn(x, 16)), 16)
  })
  diff1(i32_a, 32, rt_simd.i32x4_abs, fn(x) {
    umask(int.absolute_value(sgn(x, 32)), 32)
  })
  diff1(i64_a, 64, rt_simd.i64x2_abs, fn(x) {
    umask(int.absolute_value(sgn(x, 64)), 64)
  })
  // spec D.3: abs(INT_MIN) = INT_MIN (wraps); abs(-1) = 1.
  should.equal(rt_simd.i8x16_abs(splat8(0x80)), splat8(0x80))
  should.equal(rt_simd.i8x16_abs(splat8(0xFF)), splat8(0x01))
}

// ───────────────────────── saturating add / sub (i8x16, i16x8) ─────────────────────────

pub fn add_sat_s_test() {
  diff2(i8_a, i8_b, 8, rt_simd.i8x16_add_sat_s, fn(x, y) {
    umask(clamp(sgn(x, 8) + sgn(y, 8), -128, 127), 8)
  })
  diff2(i16_a, i16_b, 16, rt_simd.i16x8_add_sat_s, fn(x, y) {
    umask(clamp(sgn(x, 16) + sgn(y, 16), -32_768, 32_767), 16)
  })
  // spec D.2: 127 + 1 clamps to 127; -128 + -1 clamps to -128.
  should.equal(
    rt_simd.i8x16_add_sat_s(splat8(0x7F), splat8(0x01)),
    splat8(0x7F),
  )
  should.equal(
    rt_simd.i8x16_add_sat_s(splat8(0x80), splat8(0xFF)),
    splat8(0x80),
  )
  should.equal(
    rt_simd.i16x8_add_sat_s(splat16(0x7FFF), splat16(0x0001)),
    splat16(0x7FFF),
  )
}

pub fn add_sat_u_test() {
  diff2(i8_a, i8_b, 8, rt_simd.i8x16_add_sat_u, fn(x, y) {
    clamp(x + y, 0, 255)
  })
  diff2(i16_a, i16_b, 16, rt_simd.i16x8_add_sat_u, fn(x, y) {
    clamp(x + y, 0, 65_535)
  })
  // spec D.2: 255 + 1 clamps to 255.
  should.equal(
    rt_simd.i8x16_add_sat_u(splat8(0xFF), splat8(0x01)),
    splat8(0xFF),
  )
  should.equal(
    rt_simd.i16x8_add_sat_u(splat16(0xFFFF), splat16(0x0001)),
    splat16(0xFFFF),
  )
}

pub fn sub_sat_s_test() {
  diff2(i8_a, i8_b, 8, rt_simd.i8x16_sub_sat_s, fn(x, y) {
    umask(clamp(sgn(x, 8) - sgn(y, 8), -128, 127), 8)
  })
  diff2(i16_a, i16_b, 16, rt_simd.i16x8_sub_sat_s, fn(x, y) {
    umask(clamp(sgn(x, 16) - sgn(y, 16), -32_768, 32_767), 16)
  })
  // spec D.2: -128 - 1 clamps to -128.
  should.equal(
    rt_simd.i8x16_sub_sat_s(splat8(0x80), splat8(0x01)),
    splat8(0x80),
  )
  should.equal(
    rt_simd.i16x8_sub_sat_s(splat16(0x8000), splat16(0x0001)),
    splat16(0x8000),
  )
}

pub fn sub_sat_u_test() {
  diff2(i8_a, i8_b, 8, rt_simd.i8x16_sub_sat_u, fn(x, y) {
    clamp(x - y, 0, 255)
  })
  diff2(i16_a, i16_b, 16, rt_simd.i16x8_sub_sat_u, fn(x, y) {
    clamp(x - y, 0, 65_535)
  })
  // spec D.2: 0 - 1 clamps to 0.
  should.equal(
    rt_simd.i8x16_sub_sat_u(splat8(0x00), splat8(0x01)),
    splat8(0x00),
  )
  should.equal(
    rt_simd.i16x8_sub_sat_u(splat16(0x0000), splat16(0x0001)),
    splat16(0x0000),
  )
}

// ───────────────────────── min / max, signed + unsigned (i8x16/i16x8/i32x4) ─────────────────────────

fn omin_s(x: Int, y: Int, w: Int) -> Int {
  case sgn(x, w) < sgn(y, w) {
    True -> x
    False -> y
  }
}

fn omax_s(x: Int, y: Int, w: Int) -> Int {
  case sgn(x, w) > sgn(y, w) {
    True -> x
    False -> y
  }
}

fn omin_u(x: Int, y: Int) -> Int {
  case x < y {
    True -> x
    False -> y
  }
}

fn omax_u(x: Int, y: Int) -> Int {
  case x > y {
    True -> x
    False -> y
  }
}

pub fn min_s_test() {
  diff2(i8_a, i8_b, 8, rt_simd.i8x16_min_s, fn(x, y) { omin_s(x, y, 8) })
  diff2(i16_a, i16_b, 16, rt_simd.i16x8_min_s, fn(x, y) { omin_s(x, y, 16) })
  diff2(i32_a, i32_b, 32, rt_simd.i32x4_min_s, fn(x, y) { omin_s(x, y, 32) })
  // spec D.4: min_s(-128, 127) = -128.
  should.equal(rt_simd.i8x16_min_s(splat8(0x80), splat8(0x7F)), splat8(0x80))
}

pub fn min_u_test() {
  diff2(i8_a, i8_b, 8, rt_simd.i8x16_min_u, omin_u)
  diff2(i16_a, i16_b, 16, rt_simd.i16x8_min_u, omin_u)
  diff2(i32_a, i32_b, 32, rt_simd.i32x4_min_u, omin_u)
  // spec D.4: min_u(128, 127) = 127 (unsigned, 128 > 127).
  should.equal(rt_simd.i8x16_min_u(splat8(0x80), splat8(0x7F)), splat8(0x7F))
}

pub fn max_s_test() {
  diff2(i8_a, i8_b, 8, rt_simd.i8x16_max_s, fn(x, y) { omax_s(x, y, 8) })
  diff2(i16_a, i16_b, 16, rt_simd.i16x8_max_s, fn(x, y) { omax_s(x, y, 16) })
  diff2(i32_a, i32_b, 32, rt_simd.i32x4_max_s, fn(x, y) { omax_s(x, y, 32) })
  // signed max(-128, 127) = 127.
  should.equal(rt_simd.i8x16_max_s(splat8(0x80), splat8(0x7F)), splat8(0x7F))
}

pub fn max_u_test() {
  diff2(i8_a, i8_b, 8, rt_simd.i8x16_max_u, omax_u)
  diff2(i16_a, i16_b, 16, rt_simd.i16x8_max_u, omax_u)
  diff2(i32_a, i32_b, 32, rt_simd.i32x4_max_u, omax_u)
  // unsigned max(128, 127) = 128.
  should.equal(rt_simd.i8x16_max_u(splat8(0x80), splat8(0x7F)), splat8(0x80))
}

// ───────────────────────── avgr_u (i8x16, i16x8) ─────────────────────────

pub fn avgr_u_test() {
  diff2(i8_a, i8_b, 8, rt_simd.i8x16_avgr_u, fn(x, y) { { x + y + 1 } / 2 })
  diff2(i16_a, i16_b, 16, rt_simd.i16x8_avgr_u, fn(x, y) { { x + y + 1 } / 2 })
  // spec D.5: rounds up — avgr_u(255,255)=255, avgr_u(0,1)=1.
  should.equal(rt_simd.i8x16_avgr_u(splat8(0xFF), splat8(0xFF)), splat8(0xFF))
  should.equal(rt_simd.i8x16_avgr_u(splat8(0x00), splat8(0x01)), splat8(0x01))
  should.equal(
    rt_simd.i16x8_avgr_u(splat16(0xFFFF), splat16(0xFFFF)),
    splat16(0xFFFF),
  )
}

// ───────────────────────── popcnt (i8x16) ─────────────────────────

pub fn popcnt_test() {
  diff1(i8_a, 8, rt_simd.i8x16_popcnt, popcount)
  // spec D.9: byte 0xFF → 8; 0x00 → 0; 0x01 → 1.
  should.equal(rt_simd.i8x16_popcnt(splat8(0xFF)), splat8(8))
  should.equal(rt_simd.i8x16_popcnt(splat8(0x00)), splat8(0))
  should.equal(rt_simd.i8x16_popcnt(splat8(0x01)), splat8(1))
}

// ───────────────────────── shifts: shl / shr_s / shr_u (all four shapes) ─────────────────────────

pub fn shl_test() {
  // in-range counts (differential across all shapes).
  diff_shift(i8_a, 3, 8, rt_simd.i8x16_shl, fn(x, k) {
    umask(int.bitwise_shift_left(x, k % 8), 8)
  })
  diff_shift(i16_a, 5, 16, rt_simd.i16x8_shl, fn(x, k) {
    umask(int.bitwise_shift_left(x, k % 16), 16)
  })
  diff_shift(i32_a, 5, 32, rt_simd.i32x4_shl, fn(x, k) {
    umask(int.bitwise_shift_left(x, k % 32), 32)
  })
  diff_shift(i64_a, 5, 64, rt_simd.i64x2_shl, fn(x, k) {
    umask(int.bitwise_shift_left(x, k % 64), 64)
  })
  // spec D.6: shl(0x01, 8) is the IDENTITY (count 8 mod 8 = 0), NOT zero.
  should.equal(rt_simd.i8x16_shl(splat8(0x01), 8), splat8(0x01))
  should.equal(rt_simd.i8x16_shl(splat8(0x01), 1), splat8(0x02))
}

pub fn shr_s_test() {
  diff_shift(i8_a, 2, 8, rt_simd.i8x16_shr_s, fn(x, k) {
    umask(int.bitwise_shift_right(sgn(x, 8), k % 8), 8)
  })
  diff_shift(i16_a, 3, 16, rt_simd.i16x8_shr_s, fn(x, k) {
    umask(int.bitwise_shift_right(sgn(x, 16), k % 16), 16)
  })
  diff_shift(i32_a, 4, 32, rt_simd.i32x4_shr_s, fn(x, k) {
    umask(int.bitwise_shift_right(sgn(x, 32), k % 32), 32)
  })
  diff_shift(i64_a, 5, 64, rt_simd.i64x2_shr_s, fn(x, k) {
    umask(int.bitwise_shift_right(sgn(x, 64), k % 64), 64)
  })
  // spec D.6: shr_s(0x80, 1) = 0xC0 (-128 arithmetic-shifted → -64).
  should.equal(rt_simd.i8x16_shr_s(splat8(0x80), 1), splat8(0xC0))
}

pub fn shr_u_test() {
  diff_shift(i8_a, 2, 8, rt_simd.i8x16_shr_u, fn(x, k) {
    int.bitwise_shift_right(x, k % 8)
  })
  diff_shift(i16_a, 3, 16, rt_simd.i16x8_shr_u, fn(x, k) {
    int.bitwise_shift_right(x, k % 16)
  })
  diff_shift(i32_a, 4, 32, rt_simd.i32x4_shr_u, fn(x, k) {
    int.bitwise_shift_right(x, k % 32)
  })
  diff_shift(i64_a, 5, 64, rt_simd.i64x2_shr_u, fn(x, k) {
    int.bitwise_shift_right(x, k % 64)
  })
  // spec D.6: shr_u(0x80, 1) = 0x40 (logical).
  should.equal(rt_simd.i8x16_shr_u(splat8(0x80), 1), splat8(0x40))
}

/// The shift amount is masked mod the lane width (spec vector `ishl`/`ishr`): a count of
/// `w` is the identity and `w + k` equals `k`. Exercised at every shape.
pub fn shift_count_masking_test() {
  // i32x4: shl by 33 == shl by 1; shl by 32 == identity.
  should.equal(
    rt_simd.i32x4_shl(splat32(1), 33),
    rt_simd.i32x4_shl(splat32(1), 1),
  )
  should.equal(rt_simd.i32x4_shl(splat32(1), 33), splat32(2))
  should.equal(rt_simd.i32x4_shl(splat32(7), 32), splat32(7))
  // i8x16: shr_u by 9 == shr_u by 1.
  should.equal(
    rt_simd.i8x16_shr_u(splat8(0x80), 9),
    rt_simd.i8x16_shr_u(splat8(0x80), 1),
  )
  // i16x8: shr_s by 17 == shr_s by 1.
  should.equal(
    rt_simd.i16x8_shr_s(splat16(0x8000), 17),
    rt_simd.i16x8_shr_s(splat16(0x8000), 1),
  )
  // i64x2: shl by 65 == shl by 1; shr_u by 64 == identity.
  should.equal(
    rt_simd.i64x2_shl(splat64(1), 65),
    rt_simd.i64x2_shl(splat64(1), 1),
  )
  should.equal(
    rt_simd.i64x2_shr_u(splat64(0x8000000000000000), 64),
    splat64(0x8000000000000000),
  )
}
