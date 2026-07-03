//// Spec-cited, differential tests for `rt_simd`'s pass-07d surface: the shape-CHANGING
//// integer families (saturating narrow, sign/zero extend low+high, extended multiply,
//// pairwise extended add, dot product, Q15 rounding multiply), byte shuffle/swizzle, and
//// the four pure v128-memory lane-assembly helpers.
////
//// Assertions target the WebAssembly fixed-width SIMD spec (the `i*x*` vector operators,
//// <https://webassembly.github.io/spec/core/exec/numerics.html> — `narrow`, `extend`,
//// `extmul`, `extadd_pairwise`, `idot`, `q15mulr_sat_s`, `shuffle`, `swizzle`), NOT whatever
//// the impl emits. Every family is checked DIFFERENTIALLY against an INDEPENDENT test-side
//// oracle — a flat `List(Int)` reimplementation of the per-lane spec formula packed
//// little-endian (D5) and compared byte-for-byte — plus hand-worked spec edge vectors: the
//// saturating narrow ranges (negative i16 → 0 for `_u`, clamp for `_s`), extend low-vs-high
//// and s-vs-u, extmul exact products, extadd adjacent-pair sums, the `dot_i16x8_s` WRAPPING
//// edge (all `-32768` → INT_MIN), the sole `q15mulr_sat_s` saturation, swizzle OOB → 0, and
//// shuffle byte-select across `a ++ b`. The oracle deliberately uses `%`/`/` (not the impl's
//// `band`) so a shared bug cannot hide.

import gleam/int
import gleam/list
import gleeunit/should
import twocore/runtime/rt_simd

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

/// Independent clamp.
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

/// Independent saturate-to-signed of `v` at width `w`.
fn osat_s(v: Int, w: Int) -> Int {
  clamp(v, 0 - two_pow(w - 1), two_pow(w - 1) - 1)
}

/// Independent saturate-to-unsigned of `v` at width `w`.
fn osat_u(v: Int, w: Int) -> Int {
  clamp(v, 0, two_pow(w) - 1)
}

/// Independent little-endian packer: `lanes` (lane 0 first), each `w` bits wide. Applies an
/// independent `%`-based wrap so signed oracle values re-encode to their lane pattern.
fn pack(lanes: List(Int), w: Int) -> BitArray {
  list.fold(lanes, <<>>, fn(acc, lane) {
    let norm = umask(lane, w)
    <<acc:bits, norm:size(w)-little>>
  })
}

/// Independent list index (`i` in range).
fn nth(xs: List(Int), i: Int) -> Int {
  let assert [x, ..] = list.drop(xs, i)
  x
}

/// Independent adjacent-pair fold: `[a0+a1, a2+a3, …]`.
fn pairs(xs: List(Int)) -> List(Int) {
  case xs {
    [a, b, ..rest] -> [a + b, ..pairs(rest)]
    _ -> []
  }
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

// ───────────────────────── edge-laden lane fixtures ─────────────────────────

const src_i8 = [
  0x00, 0x01, 0x7F, 0x80, 0xFF, 0xFE, 0x40, 0xC0, 0x11, 0x22, 0x88, 0xAA, 0x7E,
  0x81, 0x55, 0x99,
]

const src_i8_b = [
  0x02, 0x03, 0x01, 0x80, 0xFF, 0x7F, 0x10, 0x20, 0x33, 0x44, 0x08, 0x02, 0x7D,
  0x82, 0x40, 0xC0,
]

const src_i16 = [0x0000, 0x00FF, 0x0100, 0xFFFF, 0x8000, 0x7FFF, 0x0080, 0xFF80]

const src_i16_b = [
  0xFF80,
  0x0081,
  0x1234,
  0xABCD,
  0x0001,
  0x0002,
  0xFFFE,
  0x4000,
]

const src_i32 = [0x00000001, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF]

const src_i32_b = [0x00000002, 0xFFFFFFFF, 0x00010000, 0x0000FFFF]

// ───────────────────────── narrow (saturating) ─────────────────────────

fn diff_narrow(
  a: List(Int),
  b: List(Int),
  from_w: Int,
  to_w: Int,
  sat: fn(Int, Int) -> Int,
  head: fn(BitArray, BitArray) -> BitArray,
) -> Nil {
  let f = fn(x) { sat(sgn(x, from_w), to_w) }
  let expected = list.append(list.map(a, f), list.map(b, f))
  should.equal(head(pack(a, from_w), pack(b, from_w)), pack(expected, to_w))
}

/// spec D.15: `narrow_*_s` interprets the source SIGNED then clamps to the narrower SIGNED
/// range; result lane order is `a`'s lanes (low half) then `b`'s.
pub fn narrow_s_test() {
  diff_narrow(src_i16, src_i16_b, 16, 8, osat_s, rt_simd.i8x16_narrow_i16x8_s)
  diff_narrow(src_i32, src_i32_b, 32, 16, osat_s, rt_simd.i16x8_narrow_i32x4_s)
  // 0x8000 (=-32768) clamps to signed i8 min -128 = 0x80; 0x7FFF (=32767) → 127 = 0x7F.
  should.equal(
    rt_simd.i8x16_narrow_i16x8_s(splat16(0x8000), splat16(0x7FFF)),
    pack(list.append(list.repeat(0x80, 8), list.repeat(0x7F, 8)), 8),
  )
}

/// spec D.15: `narrow_*_u` interprets the source SIGNED then clamps to the narrower UNSIGNED
/// range — a NEGATIVE source → `0`, a source `> max` → `max`.
pub fn narrow_u_test() {
  diff_narrow(src_i16, src_i16_b, 16, 8, osat_u, rt_simd.i8x16_narrow_i16x8_u)
  diff_narrow(src_i32, src_i32_b, 32, 16, osat_u, rt_simd.i16x8_narrow_i32x4_u)
  // spec worked: 0xFFFF (=-1) → 0x00; 0x00FF (=255) → 0xFF; 0x0100 (=256) → 0xFF.
  should.equal(
    rt_simd.i8x16_narrow_i16x8_u(splat16(0xFFFF), splat16(0x00FF)),
    pack(list.append(list.repeat(0x00, 8), list.repeat(0xFF, 8)), 8),
  )
  should.equal(
    rt_simd.i8x16_narrow_i16x8_u(splat16(0x0100), splat16(0x0080)),
    pack(list.append(list.repeat(0xFF, 8), list.repeat(0x80, 8)), 8),
  )
}

// ───────────────────────── extend low / high, s / u ─────────────────────────

fn extract_half(src: List(Int), high: Bool) -> List(Int) {
  let n = list.length(src)
  case high {
    True -> list.drop(src, n / 2)
    False -> list.take(src, n / 2)
  }
}

fn diff_extend(
  src: List(Int),
  from_w: Int,
  to_w: Int,
  high: Bool,
  signed: Bool,
  head: fn(BitArray) -> BitArray,
) -> Nil {
  let h = extract_half(src, high)
  let expected = case signed {
    True -> list.map(h, fn(x) { sgn(x, from_w) })
    False -> h
  }
  should.equal(head(pack(src, from_w)), pack(expected, to_w))
}

/// spec D.16: `extend_low_*` reads the LOW half of the source, `extend_high_*` the HIGH half;
/// `_s` sign-extends, `_u` zero-extends, each to the double-width lane.
pub fn extend_i8_test() {
  diff_extend(src_i8, 8, 16, False, True, rt_simd.i16x8_extend_low_i8x16_s)
  diff_extend(src_i8, 8, 16, False, False, rt_simd.i16x8_extend_low_i8x16_u)
  diff_extend(src_i8, 8, 16, True, True, rt_simd.i16x8_extend_high_i8x16_s)
  diff_extend(src_i8, 8, 16, True, False, rt_simd.i16x8_extend_high_i8x16_u)
  // byte 0x80 (=-128) sign-extends to 0xFF80, zero-extends to 0x0080. Low half of src_i8 has
  // 0x80 at lane 3; the s/u split and low-vs-high selection are pinned by the differential.
  should.equal(rt_simd.i16x8_extend_low_i8x16_s(splat8(0x80)), splat16(0xFF80))
  should.equal(rt_simd.i16x8_extend_low_i8x16_u(splat8(0x80)), splat16(0x0080))
}

pub fn extend_i16_test() {
  diff_extend(src_i16, 16, 32, False, True, rt_simd.i32x4_extend_low_i16x8_s)
  diff_extend(src_i16, 16, 32, False, False, rt_simd.i32x4_extend_low_i16x8_u)
  diff_extend(src_i16, 16, 32, True, True, rt_simd.i32x4_extend_high_i16x8_s)
  diff_extend(src_i16, 16, 32, True, False, rt_simd.i32x4_extend_high_i16x8_u)
}

pub fn extend_i32_test() {
  diff_extend(src_i32, 32, 64, False, True, rt_simd.i64x2_extend_low_i32x4_s)
  diff_extend(src_i32, 32, 64, False, False, rt_simd.i64x2_extend_low_i32x4_u)
  diff_extend(src_i32, 32, 64, True, True, rt_simd.i64x2_extend_high_i32x4_s)
  diff_extend(src_i32, 32, 64, True, False, rt_simd.i64x2_extend_high_i32x4_u)
  // 0xFFFFFFFF (=-1) sign-extends to the full 64-bit -1, zero-extends to 0x00000000FFFFFFFF.
  should.equal(
    rt_simd.i64x2_extend_low_i32x4_s(splat32(0xFFFFFFFF)),
    pack([0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF], 64),
  )
  should.equal(
    rt_simd.i64x2_extend_low_i32x4_u(splat32(0xFFFFFFFF)),
    pack([0x00000000FFFFFFFF, 0x00000000FFFFFFFF], 64),
  )
}

// ───────────────────────── extended multiply ─────────────────────────

fn diff_extmul(
  a: List(Int),
  b: List(Int),
  from_w: Int,
  to_w: Int,
  high: Bool,
  signed: Bool,
  head: fn(BitArray, BitArray) -> BitArray,
) -> Nil {
  let interp = fn(x) {
    case signed {
      True -> sgn(x, from_w)
      False -> x
    }
  }
  let ha = list.map(extract_half(a, high), interp)
  let hb = list.map(extract_half(b, high), interp)
  let expected = list.map2(ha, hb, fn(x, y) { x * y })
  should.equal(head(pack(a, from_w), pack(b, from_w)), pack(expected, to_w))
}

/// spec D.17: extend (s/u) the low/high half of both operands then multiply pairwise into the
/// double-width lane — the product fits EXACTLY (no saturation, no wrap).
pub fn extmul_i8_test() {
  diff_extmul(
    src_i8,
    src_i8_b,
    8,
    16,
    False,
    True,
    rt_simd.i16x8_extmul_low_i8x16_s,
  )
  diff_extmul(
    src_i8,
    src_i8_b,
    8,
    16,
    False,
    False,
    rt_simd.i16x8_extmul_low_i8x16_u,
  )
  diff_extmul(
    src_i8,
    src_i8_b,
    8,
    16,
    True,
    True,
    rt_simd.i16x8_extmul_high_i8x16_s,
  )
  diff_extmul(
    src_i8,
    src_i8_b,
    8,
    16,
    True,
    False,
    rt_simd.i16x8_extmul_high_i8x16_u,
  )
  // spec worked: (-128)·(-128) = 16384 = 0x4000 as i16.
  should.equal(
    rt_simd.i16x8_extmul_low_i8x16_s(splat8(0x80), splat8(0x80)),
    splat16(0x4000),
  )
  // unsigned: 255·255 = 65025 = 0xFE01 (fits the i16 unsigned pattern exactly).
  should.equal(
    rt_simd.i16x8_extmul_low_i8x16_u(splat8(0xFF), splat8(0xFF)),
    splat16(0xFE01),
  )
}

pub fn extmul_i16_test() {
  diff_extmul(
    src_i16,
    src_i16_b,
    16,
    32,
    False,
    True,
    rt_simd.i32x4_extmul_low_i16x8_s,
  )
  diff_extmul(
    src_i16,
    src_i16_b,
    16,
    32,
    False,
    False,
    rt_simd.i32x4_extmul_low_i16x8_u,
  )
  diff_extmul(
    src_i16,
    src_i16_b,
    16,
    32,
    True,
    True,
    rt_simd.i32x4_extmul_high_i16x8_s,
  )
  diff_extmul(
    src_i16,
    src_i16_b,
    16,
    32,
    True,
    False,
    rt_simd.i32x4_extmul_high_i16x8_u,
  )
}

pub fn extmul_i32_test() {
  diff_extmul(
    src_i32,
    src_i32_b,
    32,
    64,
    False,
    True,
    rt_simd.i64x2_extmul_low_i32x4_s,
  )
  diff_extmul(
    src_i32,
    src_i32_b,
    32,
    64,
    False,
    False,
    rt_simd.i64x2_extmul_low_i32x4_u,
  )
  diff_extmul(
    src_i32,
    src_i32_b,
    32,
    64,
    True,
    True,
    rt_simd.i64x2_extmul_high_i32x4_s,
  )
  diff_extmul(
    src_i32,
    src_i32_b,
    32,
    64,
    True,
    False,
    rt_simd.i64x2_extmul_high_i32x4_u,
  )
}

// ───────────────────────── extended pairwise add ─────────────────────────

fn diff_extadd(
  src: List(Int),
  from_w: Int,
  to_w: Int,
  signed: Bool,
  head: fn(BitArray) -> BitArray,
) -> Nil {
  let interp = fn(x) {
    case signed {
      True -> sgn(x, from_w)
      False -> x
    }
  }
  let expected = pairs(list.map(src, interp))
  should.equal(head(pack(src, from_w)), pack(expected, to_w))
}

/// spec D.18: sum ADJACENT pairs of the (sign/zero-extended) source lanes into the wider lane.
pub fn extadd_pairwise_test() {
  diff_extadd(src_i8, 8, 16, True, rt_simd.i16x8_extadd_pairwise_i8x16_s)
  diff_extadd(src_i8, 8, 16, False, rt_simd.i16x8_extadd_pairwise_i8x16_u)
  diff_extadd(src_i16, 16, 32, True, rt_simd.i32x4_extadd_pairwise_i16x8_s)
  diff_extadd(src_i16, 16, 32, False, rt_simd.i32x4_extadd_pairwise_i16x8_u)
  // spec worked: unsigned [0xFF, 0xFF, …] → i16 lane 0.5 = 255+255 = 510 = 0x01FE.
  should.equal(
    rt_simd.i16x8_extadd_pairwise_i8x16_u(splat8(0xFF)),
    splat16(0x01FE),
  )
  // signed [0x80,0x80,…] = (-128)+(-128) = -256 → 0xFF00 as i16.
  should.equal(
    rt_simd.i16x8_extadd_pairwise_i8x16_s(splat8(0x80)),
    splat16(0xFF00),
  )
}

// ───────────────────────── dot product + Q15 ─────────────────────────

/// spec D.19: `dot_i16x8_s` — `a[2j]·b[2j] + a[2j+1]·b[2j+1]` (signed i16), i32 result that
/// WRAPS. The differential drives the general case; the pinned edge is the sole overflow.
pub fn dot_test() {
  let pa = list.map(src_i16, fn(x) { sgn(x, 16) })
  let pb = list.map(src_i16_b, fn(x) { sgn(x, 16) })
  let expected = pairs(list.map2(pa, pb, fn(x, y) { x * y }))
  should.equal(
    rt_simd.i32x4_dot_i16x8_s(pack(src_i16, 16), pack(src_i16_b, 16)),
    pack(expected, 32),
  )
  // spec worked: all lanes -32768 → each i32 lane = 2^30 + 2^30 = 2^31 WRAPS to 0x80000000.
  should.equal(
    rt_simd.i32x4_dot_i16x8_s(splat16(0x8000), splat16(0x8000)),
    splat32(0x80000000),
  )
}

/// spec D.19: `q15mulr_sat_s` — `saturate_s16((a·b + 0x4000) >> 15)`, signed i16 inputs.
pub fn q15_test() {
  let expected =
    list.map2(src_i16, src_i16_b, fn(x, y) {
      osat_s(int.bitwise_shift_right(sgn(x, 16) * sgn(y, 16) + 0x4000, 15), 16)
    })
  should.equal(
    rt_simd.i16x8_q15mulr_sat_s(pack(src_i16, 16), pack(src_i16_b, 16)),
    pack(expected, 16),
  )
  // spec worked: the SOLE saturation — (-32768)·(-32768) → 0x7FFF.
  should.equal(
    rt_simd.i16x8_q15mulr_sat_s(splat16(0x8000), splat16(0x8000)),
    splat16(0x7FFF),
  )
  // non-saturating: 0.5 · 0.5 in Q15 = 0x4000·0x4000 → 0x2000 (= 0.25).
  should.equal(
    rt_simd.i16x8_q15mulr_sat_s(splat16(0x4000), splat16(0x4000)),
    splat16(0x2000),
  )
}

// ───────────────────────── shuffle / swizzle ─────────────────────────

const shuf_a = [
  0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C,
  0x0D, 0x0E, 0x0F,
]

const shuf_b = [
  0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C,
  0x1D, 0x1E, 0x1F,
]

/// spec D.20: `shuffle` — 16 immediate indices `0..31` gather from `a ++ b`.
pub fn shuffle_test() {
  let concat = list.append(shuf_a, shuf_b)
  // identity: indices [0..15] (== shuf_a's values) select a; [16..31] (== shuf_b's) select b.
  should.equal(
    rt_simd.i8x16_shuffle(pack(shuf_a, 8), pack(shuf_b, 8), shuf_a),
    pack(shuf_a, 8),
  )
  should.equal(
    rt_simd.i8x16_shuffle(pack(shuf_a, 8), pack(shuf_b, 8), shuf_b),
    pack(shuf_b, 8),
  )
  // an interleave / reversing selection, checked against the independent gather.
  let sel = [31, 0, 30, 1, 29, 2, 28, 3, 16, 15, 17, 14, 18, 13, 19, 12]
  should.equal(
    rt_simd.i8x16_shuffle(pack(shuf_a, 8), pack(shuf_b, 8), sel),
    pack(list.map(sel, fn(i) { nth(concat, i) }), 8),
  )
}

/// spec D.20: `swizzle` — dynamic byte select; index `≥ 16` → `0` (the OOB corner).
pub fn swizzle_test() {
  // in-range permute (reverse).
  let rev = [15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0]
  should.equal(
    rt_simd.i8x16_swizzle(pack(shuf_a, 8), pack(rev, 8)),
    pack(list.map(rev, fn(i) { nth(shuf_a, i) }), 8),
  )
  // OOB indices → 0: 16 (=0x10) and 255 (=0xFF) both produce a zero byte; 3 → a[3].
  let idx = [3, 16, 255, 0, 16, 255, 5, 16, 255, 7, 16, 255, 9, 16, 255, 11]
  let expected =
    list.map(idx, fn(i) {
      case i < 16 {
        True -> nth(shuf_a, i)
        False -> 0
      }
    })
  should.equal(
    rt_simd.i8x16_swizzle(pack(shuf_a, 8), pack(idx, 8)),
    pack(expected, 8),
  )
  // every index OOB → the all-zero vector.
  should.equal(
    rt_simd.i8x16_swizzle(pack(shuf_a, 8), splat8(0x10)),
    splat8(0x00),
  )
}

// ───────────────────────── v128 memory lane-assembly helpers (§E) ─────────────────────────

fn diff_load_extend(lanes: List(Int), source_bits: Int, signed: Bool) -> Nil {
  let slice = pack(lanes, source_bits)
  let expected = case signed {
    True -> list.map(lanes, fn(x) { sgn(x, source_bits) })
    False -> lanes
  }
  should.equal(
    rt_simd.v128_load_extend(slice, source_bits, signed),
    pack(expected, source_bits * 2),
  )
}

/// §E: `v128_load_extend` widens an 8-byte slice — 8/4/2 lanes of `source_bits` sign/zero-
/// extended to fill the v128 (the `load8x8`/`load16x4`/`load32x2` assembly).
pub fn load_extend_test() {
  // 8-bit source (8 lanes → i16x8), signed vs unsigned.
  diff_load_extend([0x00, 0x7F, 0x80, 0xFF, 0x01, 0xFE, 0x40, 0xC0], 8, True)
  diff_load_extend([0x00, 0x7F, 0x80, 0xFF, 0x01, 0xFE, 0x40, 0xC0], 8, False)
  // 16-bit source (4 lanes → i32x4).
  diff_load_extend([0x0000, 0x7FFF, 0x8000, 0xFFFF], 16, True)
  diff_load_extend([0x0000, 0x7FFF, 0x8000, 0xFFFF], 16, False)
  // 32-bit source (2 lanes → i64x2).
  diff_load_extend([0x80000000, 0xFFFFFFFF], 32, True)
  diff_load_extend([0x80000000, 0xFFFFFFFF], 32, False)
  // pinned: a single 0x80 byte → i16 0xFF80 signed, 0x0080 unsigned (low lane).
  let s8 = <<0x80, 0, 0, 0, 0, 0, 0, 0>>
  should.equal(
    rt_simd.v128_load_extend(s8, 8, True),
    pack([0xFF80, 0, 0, 0, 0, 0, 0, 0], 16),
  )
  should.equal(
    rt_simd.v128_load_extend(s8, 8, False),
    pack([0x0080, 0, 0, 0, 0, 0, 0, 0], 16),
  )
}

/// §E: `v128_load_zero` places the low 4/8 bytes little-endian in lane 0, zeroing the rest.
pub fn load_zero_test() {
  // load32_zero: 4 bytes → i32 lane 0 = little-endian value, lanes 1..3 = 0.
  should.equal(
    rt_simd.v128_load_zero(<<1, 2, 3, 4>>, 32),
    pack([0x04030201, 0, 0, 0], 32),
  )
  // load64_zero: 8 bytes → i64 lane 0 = value, lane 1 = 0.
  should.equal(
    rt_simd.v128_load_zero(<<1, 2, 3, 4, 5, 6, 7, 8>>, 64),
    pack([0x0807060504030201, 0], 64),
  )
}

/// §E: `v128_replace_lane_bits` / `v128_extract_lane_bits` round-trip at each width — write raw
/// bits into a lane, read them straight back; other lanes are untouched.
pub fn replace_extract_roundtrip_test() {
  let base = splat32(0)
  // width 8, lane 5.
  let v8 = rt_simd.v128_replace_lane_bits(base, 5, 8, 0xAB)
  should.equal(rt_simd.v128_extract_lane_bits(v8, 5, 8), 0xAB)
  should.equal(rt_simd.v128_extract_lane_bits(v8, 4, 8), 0x00)
  // width 16, lane 3.
  let v16 = rt_simd.v128_replace_lane_bits(base, 3, 16, 0xBEEF)
  should.equal(rt_simd.v128_extract_lane_bits(v16, 3, 16), 0xBEEF)
  // width 32, lane 2.
  let v32 = rt_simd.v128_replace_lane_bits(base, 2, 32, 0xDEADBEEF)
  should.equal(rt_simd.v128_extract_lane_bits(v32, 2, 32), 0xDEADBEEF)
  // width 64, lane 1.
  let v64 = rt_simd.v128_replace_lane_bits(base, 1, 64, 0x0123456789ABCDEF)
  should.equal(rt_simd.v128_extract_lane_bits(v64, 1, 64), 0x0123456789ABCDEF)
  should.equal(rt_simd.v128_extract_lane_bits(v64, 0, 64), 0x00)
}

/// The extract reads the RAW bits little-endian: extracting the i32 lane 0 of `<<1,2,3,4,…>>`
/// yields `0x04030201` (matches the `i32.load` at that offset — §F little-endian layout).
pub fn extract_lane_bits_little_endian_test() {
  let v = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>
  should.equal(rt_simd.v128_extract_lane_bits(v, 0, 32), 0x04030201)
  should.equal(rt_simd.v128_extract_lane_bits(v, 3, 32), 0x100F0E0D)
}
