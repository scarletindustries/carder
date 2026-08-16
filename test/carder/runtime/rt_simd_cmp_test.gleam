//// Spec-cited, differential tests for `rt_simd`'s pass-07b surface: the integer lane
//// comparisons (→ a per-lane all-ones / all-zeros mask), the shape-agnostic v128 bitwise
//// ops, the boolean reductions (`any_true`/`all_true`/`bitmask`), and lane access
//// (`splat`/`extract_lane(_s/_u)`/`replace_lane`).
////
//// Assertions target the WebAssembly fixed-width SIMD spec (the `i*x*` vector operators,
//// <https://webassembly.github.io/spec/core/exec/numerics.html> §D.7–D.10 of the unit doc),
//// NOT whatever the impl emits. Every family is checked DIFFERENTIALLY against an INDEPENDENT
//// test-side oracle — a flat `List(Int)` reimplementation of the per-lane spec formula packed
//// little-endian (D5) and compared byte-for-byte, plus hand-worked spec edge values. The
//// oracle deliberately uses `%` / `/` / arithmetic bit decomposition (NEVER the impl's `band`)
//// so a shared bug cannot hide. The load-bearing corners: the mask is all-ones (`2^w-1`) per
//// lane where the relation holds and all-zeros otherwise; signed and unsigned compares differ
//// (`lt_s(-1,0)=true` but `lt_u(0xFFFFFFFF,0)=false`); i64x2 has only signed ordering; the
//// bitmask gathers the SIGN bit of each lane, lane 0 → bit 0; extract_lane_s sign-extends a
//// sub-word lane to i32.

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

/// The all-ones `w`-bit mask (`2^w - 1`) — the "relation holds" lane value.
fn ones(w: Int) -> Int {
  two_pow(w) - 1
}

/// Independent little-endian packer: `lanes` (lane 0 first), each `w` bits wide.
fn pack(lanes: List(Int), w: Int) -> BitArray {
  list.fold(lanes, <<>>, fn(acc, lane) {
    let norm = umask(lane, w)
    <<acc:bits, norm:size(w)-little>>
  })
}

/// Independent bit-by-bit combine of two bytes with a per-bit boolean op (arithmetic only —
/// no `int.bitwise_*`, so it cannot share a bug with the impl).
fn combine_byte(x: Int, y: Int, f: fn(Int, Int) -> Int) -> Int {
  combine_go(x, y, f, 1, 0)
}

fn combine_go(
  x: Int,
  y: Int,
  f: fn(Int, Int) -> Int,
  weight: Int,
  acc: Int,
) -> Int {
  case weight == 256 {
    True -> acc
    False -> {
      let xb = x / weight % 2
      let yb = y / weight % 2
      combine_go(x, y, f, weight * 2, acc + f(xb, yb) * weight)
    }
  }
}

fn and_bit(a: Int, b: Int) -> Int {
  case a == 1 && b == 1 {
    True -> 1
    False -> 0
  }
}

fn or_bit(a: Int, b: Int) -> Int {
  case a == 1 || b == 1 {
    True -> 1
    False -> 0
  }
}

fn xor_bit(a: Int, b: Int) -> Int {
  case a != b {
    True -> 1
    False -> 0
  }
}

fn not_byte(x: Int) -> Int {
  255 - x
}

// ── differential drivers ──

/// Run a comparison head and assert it equals the oracle mask (all-ones where `rel` holds).
fn diff_cmp(
  a: List(Int),
  b: List(Int),
  w: Int,
  head: fn(BitArray, BitArray) -> BitArray,
  rel: fn(Int, Int) -> Bool,
) -> Nil {
  should.equal(
    head(pack(a, w), pack(b, w)),
    pack(
      list.map2(a, b, fn(x, y) {
        case rel(x, y) {
          True -> ones(w)
          False -> 0
        }
      }),
      w,
    ),
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

// ───────────────────────── comparisons → lane mask (i8x16/i16x8/i32x4) ─────────────────────────

pub fn eq_ne_test() {
  diff_cmp(i8_a, i8_b, 8, rt_simd.i8x16_eq, fn(x, y) { x == y })
  diff_cmp(i16_a, i16_b, 16, rt_simd.i16x8_eq, fn(x, y) { x == y })
  diff_cmp(i32_a, i32_b, 32, rt_simd.i32x4_eq, fn(x, y) { x == y })
  diff_cmp(i8_a, i8_b, 8, rt_simd.i8x16_ne, fn(x, y) { x != y })
  diff_cmp(i16_a, i16_b, 16, rt_simd.i16x8_ne, fn(x, y) { x != y })
  diff_cmp(i32_a, i32_b, 32, rt_simd.i32x4_ne, fn(x, y) { x != y })
  // spec D.7: eq of equal lanes → all-ones; unequal → all-zeros.
  should.equal(
    rt_simd.i8x16_eq(pack([0x05], 8), pack([0x05], 8)),
    pack([0xFF], 8),
  )
  should.equal(
    rt_simd.i8x16_eq(pack([0x05], 8), pack([0x06], 8)),
    pack([0x00], 8),
  )
  should.equal(
    rt_simd.i8x16_ne(pack([0x05], 8), pack([0x06], 8)),
    pack([0xFF], 8),
  )
}

pub fn lt_signed_test() {
  diff_cmp(i8_a, i8_b, 8, rt_simd.i8x16_lt_s, fn(x, y) { sgn(x, 8) < sgn(y, 8) })
  diff_cmp(i16_a, i16_b, 16, rt_simd.i16x8_lt_s, fn(x, y) {
    sgn(x, 16) < sgn(y, 16)
  })
  diff_cmp(i32_a, i32_b, 32, rt_simd.i32x4_lt_s, fn(x, y) {
    sgn(x, 32) < sgn(y, 32)
  })
  // spec D.7: lt_s(0xFF=-1, 0x00) → all-ones (-1 < 0).
  should.equal(
    rt_simd.i8x16_lt_s(pack([0xFF], 8), pack([0x00], 8)),
    pack([0xFF], 8),
  )
}

pub fn lt_unsigned_test() {
  diff_cmp(i8_a, i8_b, 8, rt_simd.i8x16_lt_u, fn(x, y) { x < y })
  diff_cmp(i16_a, i16_b, 16, rt_simd.i16x8_lt_u, fn(x, y) { x < y })
  diff_cmp(i32_a, i32_b, 32, rt_simd.i32x4_lt_u, fn(x, y) { x < y })
  // spec D.7: lt_u(0xFF=255, 0x00) → all-zeros (255 < 0 is FALSE — the signed/unsigned split).
  should.equal(
    rt_simd.i8x16_lt_u(pack([0xFF], 8), pack([0x00], 8)),
    pack([0x00], 8),
  )
}

/// The definitive signed-vs-unsigned pin (unit-doc §D.7 / prompt): `lt_s(-1,0)=true` but
/// `lt_u(0xFFFFFFFF,0)=false`, and symmetrically for the other orderings.
pub fn signed_unsigned_split_test() {
  let neg = pack([0x80000000, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000], 32)
  let zero = pack([0x00000000, 0x00000000, 0x00000000, 0x00000000], 32)
  // signed: 0x80000000(=INT_MIN) < 0 true; 0xFFFFFFFF(=-1) < 0 true; 0 < 0 false.
  should.equal(
    rt_simd.i32x4_lt_s(neg, zero),
    pack([0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000], 32),
  )
  // unsigned: every one of those large patterns is > 0, so lt_u is false everywhere.
  should.equal(rt_simd.i32x4_lt_u(neg, zero), zero)
  // ge_u of a huge value vs 0 is true; ge_s of INT_MIN vs 0 is false.
  should.equal(
    rt_simd.i32x4_ge_u(neg, zero),
    pack([0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF], 32),
  )
  should.equal(
    rt_simd.i32x4_ge_s(neg, zero),
    pack([0x00000000, 0x00000000, 0x00000000, 0xFFFFFFFF], 32),
  )
}

pub fn gt_le_ge_test() {
  // gt_s / gt_u
  diff_cmp(i8_a, i8_b, 8, rt_simd.i8x16_gt_s, fn(x, y) { sgn(x, 8) > sgn(y, 8) })
  diff_cmp(i8_a, i8_b, 8, rt_simd.i8x16_gt_u, fn(x, y) { x > y })
  diff_cmp(i32_a, i32_b, 32, rt_simd.i32x4_gt_s, fn(x, y) {
    sgn(x, 32) > sgn(y, 32)
  })
  diff_cmp(i32_a, i32_b, 32, rt_simd.i32x4_gt_u, fn(x, y) { x > y })
  // le_s / le_u
  diff_cmp(i8_a, i8_b, 8, rt_simd.i8x16_le_s, fn(x, y) {
    sgn(x, 8) <= sgn(y, 8)
  })
  diff_cmp(i8_a, i8_b, 8, rt_simd.i8x16_le_u, fn(x, y) { x <= y })
  diff_cmp(i16_a, i16_b, 16, rt_simd.i16x8_le_s, fn(x, y) {
    sgn(x, 16) <= sgn(y, 16)
  })
  diff_cmp(i16_a, i16_b, 16, rt_simd.i16x8_le_u, fn(x, y) { x <= y })
  // ge_s / ge_u
  diff_cmp(i8_a, i8_b, 8, rt_simd.i8x16_ge_s, fn(x, y) {
    sgn(x, 8) >= sgn(y, 8)
  })
  diff_cmp(i8_a, i8_b, 8, rt_simd.i8x16_ge_u, fn(x, y) { x >= y })
  diff_cmp(i16_a, i16_b, 16, rt_simd.i16x8_gt_s, fn(x, y) {
    sgn(x, 16) > sgn(y, 16)
  })
  diff_cmp(i16_a, i16_b, 16, rt_simd.i16x8_gt_u, fn(x, y) { x > y })
  diff_cmp(i32_a, i32_b, 32, rt_simd.i32x4_le_s, fn(x, y) {
    sgn(x, 32) <= sgn(y, 32)
  })
  diff_cmp(i32_a, i32_b, 32, rt_simd.i32x4_le_u, fn(x, y) { x <= y })
  diff_cmp(i32_a, i32_b, 32, rt_simd.i32x4_ge_u, fn(x, y) { x >= y })
}

// ───────────────────────── i64x2 compares (signed-only ordering + eq/ne) ─────────────────────────

pub fn i64x2_compares_test() {
  diff_cmp(i64_a, i64_b, 64, rt_simd.i64x2_eq, fn(x, y) { x == y })
  diff_cmp(i64_a, i64_b, 64, rt_simd.i64x2_ne, fn(x, y) { x != y })
  diff_cmp(i64_a, i64_b, 64, rt_simd.i64x2_lt_s, fn(x, y) {
    sgn(x, 64) < sgn(y, 64)
  })
  diff_cmp(i64_a, i64_b, 64, rt_simd.i64x2_gt_s, fn(x, y) {
    sgn(x, 64) > sgn(y, 64)
  })
  diff_cmp(i64_a, i64_b, 64, rt_simd.i64x2_le_s, fn(x, y) {
    sgn(x, 64) <= sgn(y, 64)
  })
  diff_cmp(i64_a, i64_b, 64, rt_simd.i64x2_ge_s, fn(x, y) {
    sgn(x, 64) >= sgn(y, 64)
  })
  // spec D.7: i64x2.lt_s(INT_MIN, 0) → all-ones; eq(x,x) → all-ones.
  let int_min = pack([0x8000000000000000, 0x0000000000000001], 64)
  let zero = pack([0x0000000000000000, 0x0000000000000000], 64)
  should.equal(rt_simd.i64x2_lt_s(int_min, zero), pack([ones(64), 0x0], 64))
  should.equal(
    rt_simd.i64x2_eq(int_min, int_min),
    pack([ones(64), ones(64)], 64),
  )
}

// ───────────────────────── v128 bitwise (shape-agnostic, whole 128 bits) ─────────────────────────

const bits_a = [
  0xFF, 0x00, 0xF0, 0x0F, 0xAA, 0x55, 0x01, 0x80, 0x12, 0x34, 0x56, 0x78, 0x9A,
  0xBC, 0xDE, 0xF0,
]

const bits_b = [
  0x0F, 0xFF, 0x33, 0xCC, 0x55, 0xAA, 0xFF, 0x7F, 0x87, 0x65, 0x43, 0x21, 0x0F,
  0xF0, 0x00, 0xFF,
]

pub fn bitwise_and_or_xor_test() {
  let a = pack(bits_a, 8)
  let b = pack(bits_b, 8)
  should.equal(
    rt_simd.v128_and(a, b),
    pack(list.map2(bits_a, bits_b, fn(x, y) { combine_byte(x, y, and_bit) }), 8),
  )
  should.equal(
    rt_simd.v128_or(a, b),
    pack(list.map2(bits_a, bits_b, fn(x, y) { combine_byte(x, y, or_bit) }), 8),
  )
  should.equal(
    rt_simd.v128_xor(a, b),
    pack(list.map2(bits_a, bits_b, fn(x, y) { combine_byte(x, y, xor_bit) }), 8),
  )
  // spec D.8 hand value: 0xF0 AND 0x0F = 0x00; 0xF0 OR 0x0F = 0xFF; 0xAA XOR 0x55 = 0xFF
  // (full 16-byte vectors — the ops are byte-independent).
  should.equal(
    rt_simd.v128_and(
      pack(list.repeat(0xF0, 16), 8),
      pack(list.repeat(0x0F, 16), 8),
    ),
    pack(list.repeat(0x00, 16), 8),
  )
  should.equal(
    rt_simd.v128_or(
      pack(list.repeat(0xF0, 16), 8),
      pack(list.repeat(0x0F, 16), 8),
    ),
    pack(list.repeat(0xFF, 16), 8),
  )
  should.equal(
    rt_simd.v128_xor(
      pack(list.repeat(0xAA, 16), 8),
      pack(list.repeat(0x55, 16), 8),
    ),
    pack(list.repeat(0xFF, 16), 8),
  )
}

pub fn bitwise_not_andnot_test() {
  let a = pack(bits_a, 8)
  let b = pack(bits_b, 8)
  should.equal(rt_simd.v128_not(a), pack(list.map(bits_a, not_byte), 8))
  // andnot(a, b) = a AND (NOT b), per byte.
  should.equal(
    rt_simd.v128_andnot(a, b),
    pack(
      list.map2(bits_a, bits_b, fn(x, y) {
        combine_byte(x, not_byte(y), and_bit)
      }),
      8,
    ),
  )
  // spec D.8: andnot(0xFF, 0x0F) = 0xFF AND 0xF0 = 0xF0 (operand order matters).
  should.equal(
    rt_simd.v128_andnot(
      pack(list.repeat(0xFF, 16), 8),
      pack(list.repeat(0x0F, 16), 8),
    ),
    pack(list.repeat(0xF0, 16), 8),
  )
}

pub fn bitselect_test() {
  let a = pack(bits_a, 8)
  let b = pack(bits_b, 8)
  let m =
    pack(
      [
        0xFF,
        0x00,
        0xF0,
        0x0F,
        0xAA,
        0x55,
        0xCC,
        0x33,
        0x00,
        0xFF,
        0x81,
        0x18,
        0x7E,
        0xE7,
        0x3C,
        0xC3,
      ],
      8,
    )
  // bitselect(a, b, m) = (a AND m) OR (b AND NOT m), per byte.
  let mask_bytes = [
    0xFF,
    0x00,
    0xF0,
    0x0F,
    0xAA,
    0x55,
    0xCC,
    0x33,
    0x00,
    0xFF,
    0x81,
    0x18,
    0x7E,
    0xE7,
    0x3C,
    0xC3,
  ]
  should.equal(
    rt_simd.v128_bitselect(a, b, m),
    pack(
      list.map2(list.zip(bits_a, bits_b), mask_bytes, fn(ab, mb) {
        let #(av, bv) = ab
        combine_byte(
          combine_byte(av, mb, and_bit),
          combine_byte(bv, not_byte(mb), and_bit),
          or_bit,
        )
      }),
      8,
    ),
  )
  // spec D.8 identities: mask=all-ones picks a; mask=all-zeros picks b.
  should.equal(rt_simd.v128_bitselect(a, b, pack(list.repeat(0xFF, 16), 8)), a)
  should.equal(rt_simd.v128_bitselect(a, b, pack(list.repeat(0x00, 16), 8)), b)
}

/// Algebraic laws the spec fixes (impl-independent): `a XOR a = 0`, `not(not a) = a`,
/// `a AND all-ones = a`, `a OR 0 = a`, `andnot(a, a) = 0`.
pub fn bitwise_laws_test() {
  let a = pack(bits_a, 8)
  let allones = pack(list.repeat(0xFF, 16), 8)
  let zero = pack(list.repeat(0x00, 16), 8)
  should.equal(rt_simd.v128_xor(a, a), zero)
  should.equal(rt_simd.v128_not(rt_simd.v128_not(a)), a)
  should.equal(rt_simd.v128_and(a, allones), a)
  should.equal(rt_simd.v128_or(a, zero), a)
  should.equal(rt_simd.v128_andnot(a, a), zero)
  should.equal(rt_simd.v128_not(zero), allones)
}

// ───────────────────────── boolean reductions ─────────────────────────

pub fn any_true_test() {
  // spec D.9: 1 if ANY bit set; 0 only for the all-zero vector.
  should.equal(rt_simd.v128_any_true(pack(list.repeat(0x00, 16), 8)), 0)
  should.equal(rt_simd.v128_any_true(pack(bits_a, 8)), 1)
  // a single set bit anywhere → 1.
  should.equal(
    rt_simd.v128_any_true(pack(
      [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01],
      8,
    )),
    1,
  )
}

pub fn all_true_test() {
  // spec D.9: 1 iff EVERY lane is non-zero.
  // i8x16: one zero lane → 0; all non-zero → 1.
  should.equal(
    rt_simd.i8x16_all_true(pack(
      [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0],
      8,
    )),
    0,
  )
  should.equal(rt_simd.i8x16_all_true(pack(list.repeat(1, 16), 8)), 1)
  // i32x4: a lane whose BYTES are individually non-zero but is treated as a 32-bit lane;
  // a lane of all zeros → 0.
  should.equal(rt_simd.i32x4_all_true(pack([1, 1, 0, 1], 32)), 0)
  should.equal(rt_simd.i32x4_all_true(pack([1, 1, 1, 1], 32)), 1)
  // i64x2 edge: both lanes non-zero → 1.
  should.equal(rt_simd.i64x2_all_true(pack([0x8000000000000000, 0x1], 64)), 1)
  should.equal(rt_simd.i64x2_all_true(pack([0x0, 0x1], 64)), 0)
  // A lane that is non-zero only via a high byte still counts as non-zero (i16x8).
  should.equal(
    rt_simd.i16x8_all_true(pack([0x0100, 1, 1, 1, 1, 1, 1, 1], 16)),
    1,
  )
}

pub fn bitmask_test() {
  // spec D.9: gather the SIGN bit of each lane, lane 0 → bit 0.
  // i8x16 worked example: lanes 0 and 15 have the high bit set → 0x8001.
  let v = pack([0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80], 8)
  should.equal(rt_simd.i8x16_bitmask(v), 0x8001)
  // i32x4 sign-bit gather [neg, pos, neg, pos] → 0b0101 = 5.
  should.equal(
    rt_simd.i32x4_bitmask(pack(
      [0x80000000, 0x00000001, 0xFFFFFFFF, 0x7FFFFFFF],
      32,
    )),
    0b0101,
  )
  // i16x8: all sign bits set → 0xFF (8 bits).
  should.equal(rt_simd.i16x8_bitmask(pack(list.repeat(0x8000, 8), 16)), 0xFF)
  // i64x2: [neg, pos] → 0b01; [pos, neg] → 0b10.
  should.equal(
    rt_simd.i64x2_bitmask(pack([0x8000000000000000, 0x0000000000000001], 64)),
    0b01,
  )
  should.equal(
    rt_simd.i64x2_bitmask(pack([0x0000000000000001, 0x8000000000000000], 64)),
    0b10,
  )
  // all sign bits clear → 0.
  should.equal(rt_simd.i8x16_bitmask(pack(list.repeat(0x7F, 16), 8)), 0)
}

// ───────────────────────── lane access: splat / extract / replace ─────────────────────────

pub fn splat_test() {
  // spec D.10: every lane = the scalar (masked to lane width), little-endian.
  should.equal(rt_simd.i8x16_splat(0xAB), pack(list.repeat(0xAB, 16), 8))
  // over-wide scalar is taken mod 2^w.
  should.equal(rt_simd.i8x16_splat(0x1FF), pack(list.repeat(0xFF, 16), 8))
  should.equal(rt_simd.i16x8_splat(0xBEEF), pack(list.repeat(0xBEEF, 8), 16))
  should.equal(
    rt_simd.i32x4_splat(0xDEADBEEF),
    pack(list.repeat(0xDEADBEEF, 4), 32),
  )
  should.equal(
    rt_simd.i64x2_splat(0x0123456789ABCDEF),
    pack(list.repeat(0x0123456789ABCDEF, 2), 64),
  )
  // float splats are raw-bit (identical layout to the same-width int splat).
  should.equal(
    rt_simd.f32x4_splat(0x3F800000),
    pack(list.repeat(0x3F800000, 4), 32),
  )
  should.equal(
    rt_simd.f64x2_splat(0x3FF0000000000000),
    pack(list.repeat(0x3FF0000000000000, 2), 64),
  )
}

pub fn extract_lane_differential_test() {
  // Build a known v128 from a lane list; every extract must return the packed lane.
  let v8 = pack(i8_a, 8)
  list.index_map(i8_a, fn(byte, k) {
    should.equal(rt_simd.i8x16_extract_lane_u(v8, k), umask(byte, 8))
    should.equal(
      rt_simd.i8x16_extract_lane_s(v8, k),
      umask(sgn(umask(byte, 8), 8), 32),
    )
  })
  let v16 = pack(i16_a, 16)
  list.index_map(i16_a, fn(lane, k) {
    should.equal(rt_simd.i16x8_extract_lane_u(v16, k), umask(lane, 16))
    should.equal(
      rt_simd.i16x8_extract_lane_s(v16, k),
      umask(sgn(umask(lane, 16), 16), 32),
    )
  })
  let v32 = pack(i32_a, 32)
  list.index_map(i32_a, fn(lane, k) {
    should.equal(rt_simd.i32x4_extract_lane(v32, k), umask(lane, 32))
    should.equal(rt_simd.f32x4_extract_lane(v32, k), umask(lane, 32))
  })
  let v64 = pack(i64_a, 64)
  should.equal(
    rt_simd.i64x2_extract_lane(v64, 0),
    umask(lane_get(i64_a, 0), 64),
  )
  should.equal(
    rt_simd.i64x2_extract_lane(v64, 1),
    umask(lane_get(i64_a, 1), 64),
  )
  should.equal(
    rt_simd.f64x2_extract_lane(v64, 0),
    umask(lane_get(i64_a, 0), 64),
  )
}

/// Sub-word `extract_lane_s` sign-extends to i32; `_u` zero-extends (spec D.10 worked values).
pub fn extract_sign_extension_test() {
  // i8 lane 0xFF: _s → 0xFFFFFFFF (=-1); _u → 0x000000FF (=255).
  let vff = rt_simd.i8x16_splat(0xFF)
  should.equal(rt_simd.i8x16_extract_lane_s(vff, 3), 0xFFFFFFFF)
  should.equal(rt_simd.i8x16_extract_lane_u(vff, 3), 0x000000FF)
  // i8 lane 0x80: _s → 0xFFFFFF80.
  let v80 = rt_simd.i8x16_splat(0x80)
  should.equal(rt_simd.i8x16_extract_lane_s(v80, 0), 0xFFFFFF80)
  should.equal(rt_simd.i8x16_extract_lane_u(v80, 0), 0x00000080)
  // i16 lane 0x8000: _s → 0xFFFF8000; _u → 0x00008000.
  let v8000 = rt_simd.i16x8_splat(0x8000)
  should.equal(rt_simd.i16x8_extract_lane_s(v8000, 5), 0xFFFF8000)
  should.equal(rt_simd.i16x8_extract_lane_u(v8000, 5), 0x00008000)
  // a positive sub-word lane is unchanged by _s.
  should.equal(rt_simd.i8x16_extract_lane_s(rt_simd.i8x16_splat(0x7F), 0), 0x7F)
}

pub fn replace_lane_roundtrip_test() {
  // spec D.10: replace writes one lane, leaves the rest; extract reads it back.
  let base = rt_simd.i32x4_splat(0)
  let v = rt_simd.i32x4_replace_lane(base, 2, 0xCAFEBABE)
  should.equal(rt_simd.i32x4_extract_lane(v, 2), 0xCAFEBABE)
  should.equal(rt_simd.i32x4_extract_lane(v, 0), 0)
  should.equal(rt_simd.i32x4_extract_lane(v, 1), 0)
  should.equal(rt_simd.i32x4_extract_lane(v, 3), 0)
  // i8x16 replace masks the value to the lane width; other lanes untouched.
  let v8 = rt_simd.i8x16_replace_lane(rt_simd.i8x16_splat(0x11), 7, 0x1AB)
  should.equal(rt_simd.i8x16_extract_lane_u(v8, 7), 0xAB)
  should.equal(rt_simd.i8x16_extract_lane_u(v8, 6), 0x11)
  should.equal(rt_simd.i8x16_extract_lane_u(v8, 8), 0x11)
  // i64x2 replace + read-back of a full-width value.
  let v64 =
    rt_simd.i64x2_replace_lane(rt_simd.i64x2_splat(0), 1, 0x0123456789ABCDEF)
  should.equal(rt_simd.i64x2_extract_lane(v64, 1), 0x0123456789ABCDEF)
  should.equal(rt_simd.i64x2_extract_lane(v64, 0), 0)
  // f32x4 replace preserves the raw bit pattern.
  let vf = rt_simd.f32x4_replace_lane(rt_simd.f32x4_splat(0), 0, 0x7FC00000)
  should.equal(rt_simd.f32x4_extract_lane(vf, 0), 0x7FC00000)
}

// ── local helper: index into a fixture list (test-side, independent) ──

fn lane_get(xs: List(Int), k: Int) -> Int {
  let assert [x, ..] = list.drop(xs, k)
  x
}
