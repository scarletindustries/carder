//// `runtime/rt_simd` — the SIMD lane-op runtime chokepoint (NEW, Phase-6 keystone P6-01).
////
//// The SIMD analogue of `rt_num`: the single auditable chokepoint for SIMD fidelity (tier-P
//// `bif`). `emit_core` (P6-06) maps each `ir.SimdOp` constructor to one of these concrete heads
//// — the binding chokepoint, exactly like `NumOp → rt_num`. This is a **faithful, emulated,
//// lane-wise** implementation (I3): no hardware vectorisation and none claimed. Each op (when
//// implemented by P6-07) decodes the 16-byte operand binary(ies) into lanes via bit-syntax,
//// applies the per-lane operation **reusing `rt_num`'s exact scalar semantics**, and re-encodes.
////
//// ## The frozen representation contract (§G.1)
////
//// - **`v128` in/out is a `BitArray`** — exactly 16 bytes, little-endian lane layout.
//// - **Scalars in/out are raw-bit `Int`** — i32/i64 as the unsigned bit pattern, f32/f64 as the
////   raw IEEE-754 bit pattern (D5), exactly as `rt_num` uses them. A lane index / shift count /
////   shuffle index / lane width is a plain `Int`.
//// - **Every op is TOTAL** (returns a bare value, never `Result`) — SIMD lane ops do not trap
////   (I3), so no head returns `Result(_, TrapReason)`. The memory-bounds trap lives in `rt_mem`,
////   not here: the four v128 lane-ASSEMBLY helpers below (`v128_load_extend`/`v128_load_zero`/
////   `v128_replace_lane_bits`/`v128_extract_lane_bits`) are PURE — `emit_core` (P6-06) composes
////   each SIMD memory instruction from the bounds-checked `rt_mem` seam (which owns the OOB check
////   → trap `MemoryOutOfBounds`) PLUS one of these pure helpers. `rt_simd` never touches memory.
////
//// ## The placeholder posture (§G.2 — todo-free, zero-warning, fail-loud)
////
//// Every head lands here with a `panic as "rt_simd.<name> — implemented in P6-07"` body:
//// **`todo`-free** (Gleam's `todo` warns; `panic` does not), **zero-warning** (a `pub fn` is
//// never "unused"), and **fail-loud** (07's differential tests catch any unfilled head; a
//// `panic` in generated code is a node-safe crash, never a silent wrong answer — D4). No
//// Phase-1..5 module or the freeze test CALLS `rt_simd` (the keystone's `emit` arms return
//// `UnsupportedNode`), so the placeholders are never reached until P6-06 emits calls + P6-07
//// fills bodies. This mirrors the Phase-5 R5 keystone posture.
////
//// **Deliberately IMPORT-FREE** (§G.1, seam 2): the heads need only prelude `BitArray`/`Int`/
//// `Bool`/`List` — unit 07 adds `import twocore/runtime/rt_num` when it fills the bodies, so the
//// keystone stays warning-free (no unused import). 07 CONSUMES `rt_num`, never edits it.
////
//// ## Spec anchor
////
//// The fixed-width SIMD instruction semantics (WebAssembly spec §4.4 vector instructions);
//// per-lane semantics are pinned in `ir.SimdOp`'s doc (two's-complement lane wrap, shift-count
//// masking mod lane width, f32 single-rounding, NaN canonicalisation, saturating narrow,
//// pmin/pmax pseudo-form, `dot_i16x8_s` wrapping, `avgr_u` rounding, swizzle OOB → 0).

import gleam/bit_array
import gleam/int
import gleam/list
import twocore/runtime/rt_num

// ─────────────────────────── the shared lane codec + integer width-core (07a) ───────────────────────────
//
// PRIVATE infrastructure established by pass 07a and REUSED by 07b/07c/07d.
//
// A `v128` is 16 bytes; a "shape" slices it into `128 / w` lanes of `w ∈ {8,16,32,64}` bits,
// little-endian, lane 0 lowest-addressed (D5). `decode_lanes`/`encode_lanes` are the ONE codec
// every lane op funnels through. `mask_low`/`signed_of`/`shift_count`/`all_ones` are the
// width-parametric integer core for the 8-/16-bit widths `rt_num` does not implement (§A.3) —
// each mirrors a `rt_num` PRIVATE worker at an arbitrary lane width. The subtle scalar numerics
// (the two's-complement wrap, popcount) are CONSUMED from `rt_num`, which is NEVER edited (D1).

/// `2^n` as a BEAM bignum — the modulus bounding an `n`-bit lane.
fn pow2(n: Int) -> Int {
  int.bitwise_shift_left(1, n)
}

/// The all-ones bit pattern of a `w`-bit lane (`2^w - 1`): the width mask (and, in 07b, the
/// "relation holds" comparison-mask value).
fn all_ones(w: Int) -> Int {
  pow2(w) - 1
}

/// Reduce `x` to its `w`-bit unsigned bit pattern `x mod 2^w` in `[0, 2^w)`. `x` may be
/// negative: `band` treats a BEAM integer as an infinite two's-complement string, so this
/// re-encodes a signed lane result to its unsigned pattern (`band(-128, 0xFF) = 128`). Mirrors
/// `rt_num`'s private `norm` at an arbitrary lane width.
fn mask_low(x: Int, w: Int) -> Int {
  int.bitwise_and(x, all_ones(w))
}

/// Interpret the `w`-bit unsigned pattern `u ∈ [0, 2^w)` as a two's-complement SIGNED integer
/// in `[-2^(w-1), 2^(w-1))`. Mirrors `rt_num`'s private `signed` at a lane width (the
/// sanctioned local `lane_signed`, §A.3).
fn signed_of(u: Int, w: Int) -> Int {
  case u >= pow2(w - 1) {
    True -> u - pow2(w)
    False -> u
  }
}

/// The shift amount `count` reduced mod the lane width `w` (a power of two): `count band
/// (w - 1)`, so a shift by `w` is the identity and by `w + 1` equals by `1` (spec vector
/// shift-count masking). Mirrors `rt_num`'s private `shift_count`.
fn shift_count(count: Int, w: Int) -> Int {
  int.bitwise_and(count, w - 1)
}

/// Decode the 16-byte little-endian v128 `v` into its lanes, each `w` bits wide
/// (`w ∈ {8,16,32,64}` → 16/8/4/2 lanes), lane 0 first, as raw NON-NEGATIVE bit patterns in
/// `[0, 2^w)`. THE shared decode 07b/07c/07d reuse — a float lane is simply its raw 32/64-bit
/// pattern (decode with `w = 32/64`; the IEEE interpretation is `rt_num`'s job, not the
/// codec's). A `v` whose length is not a whole multiple of `w / 8` bytes is an
/// internal-invariant crash (P6-04 validation guarantees a well-typed 16-byte v128), never a
/// WASM trap.
fn decode_lanes(v: BitArray, w: Int) -> List(Int) {
  case v {
    <<>> -> []
    <<lane:size(w)-little-unsigned, rest:bits>> -> [
      lane,
      ..decode_lanes(rest, w)
    ]
    _ ->
      panic as "rt_simd.decode_lanes — v128 length not a multiple of the lane width"
  }
}

/// Re-encode a lane list (lane 0 first) of `w`-bit lanes into the little-endian byte string
/// (`length(lanes) * w` MUST be 128 for a v128 result). Each lane is taken mod `2^w` by the
/// `size(w)` segment; callers pass already-normalised non-negative lanes. THE shared encode
/// 07b/07c/07d reuse (the exact inverse of `decode_lanes`).
fn encode_lanes(lanes: List(Int), w: Int) -> BitArray {
  bit_array.concat(list.map(lanes, fn(lane) { <<lane:size(w)-little>> }))
}

/// Decode both operands into `w`-bit lanes, apply `f` to each corresponding lane pair, and
/// re-encode — the driver every shape-preserving binary head funnels through.
fn map2_lanes(
  a: BitArray,
  b: BitArray,
  w: Int,
  f: fn(Int, Int) -> Int,
) -> BitArray {
  encode_lanes(list.map2(decode_lanes(a, w), decode_lanes(b, w), f), w)
}

/// Decode into `w`-bit lanes, apply the unary `f` per lane, and re-encode.
fn map1_lanes(a: BitArray, w: Int, f: fn(Int) -> Int) -> BitArray {
  encode_lanes(list.map(decode_lanes(a, w), f), w)
}

// ── per-lane integer workers (reuse `rt_num` for the scalar wrap / popcount; §A.3) ──

/// Lane-wise wrapping add of two `w`-bit patterns: `rt_num`'s audited wrap (`i32`/`i64_add`)
/// masked to the lane width. Widen-and-mask is exact because `2^8 | 2^16 | 2^32` (so
/// `((a+b) mod 2^32) mod 2^w = (a+b) mod 2^w`), and for `w = 32/64` the `rt_num` wrap already
/// IS the lane wrap.
fn add_lane(a: Int, b: Int, w: Int) -> Int {
  case w {
    64 -> rt_num.i64_add(a, b)
    _ -> mask_low(rt_num.i32_add(a, b), w)
  }
}

/// Lane-wise wrapping subtract (`rt_num.i{32,64}_sub` then mask).
fn sub_lane(a: Int, b: Int, w: Int) -> Int {
  case w {
    64 -> rt_num.i64_sub(a, b)
    _ -> mask_low(rt_num.i32_sub(a, b), w)
  }
}

/// Lane-wise wrapping multiply (`rt_num.i{32,64}_mul` then mask).
fn mul_lane(a: Int, b: Int, w: Int) -> Int {
  case w {
    64 -> rt_num.i64_mul(a, b)
    _ -> mask_low(rt_num.i32_mul(a, b), w)
  }
}

/// Lane-wise two's-complement negation `(0 - a) mod 2^w` (spec `ineg`; `neg(INT_MIN) = INT_MIN`).
fn neg_lane(a: Int, w: Int) -> Int {
  sub_lane(0, a, w)
}

/// Lane-wise two's-complement absolute value: `|signed(a)|` re-encoded mod `2^w` (spec `iabs`;
/// wraps — `abs(INT_MIN) = INT_MIN`).
fn abs_lane(a: Int, w: Int) -> Int {
  mask_low(int.absolute_value(signed_of(a, w)), w)
}

/// The `w`-bit signed range endpoints (`INT_MIN` / `INT_MAX`).
fn int_min_s(w: Int) -> Int {
  0 - pow2(w - 1)
}

fn int_max_s(w: Int) -> Int {
  pow2(w - 1) - 1
}

/// Clamp signed `x` to `[-2^(w-1), 2^(w-1)-1]`, then re-encode to the unsigned lane pattern.
fn sat_s(x: Int, w: Int) -> Int {
  mask_low(int.clamp(x, int_min_s(w), int_max_s(w)), w)
}

/// Clamp `x` to the unsigned range `[0, 2^w-1]` (the clamped result is already a lane pattern).
fn sat_u(x: Int, w: Int) -> Int {
  int.clamp(x, 0, all_ones(w))
}

/// Signed saturating add: the EXACT (bignum) signed sum, clamped to the `w`-bit signed range.
fn add_sat_s_lane(a: Int, b: Int, w: Int) -> Int {
  sat_s(signed_of(a, w) + signed_of(b, w), w)
}

/// Unsigned saturating add: the exact sum clamped to `[0, 2^w-1]`.
fn add_sat_u_lane(a: Int, b: Int, w: Int) -> Int {
  sat_u(a + b, w)
}

/// Signed saturating subtract: the exact signed difference clamped to the `w`-bit signed range.
fn sub_sat_s_lane(a: Int, b: Int, w: Int) -> Int {
  sat_s(signed_of(a, w) - signed_of(b, w), w)
}

/// Unsigned saturating subtract: the exact difference clamped to `[0, 2^w-1]`.
fn sub_sat_u_lane(a: Int, b: Int, w: Int) -> Int {
  sat_u(a - b, w)
}

/// Lane-wise signed minimum: select the operand bits of the numerically smaller SIGNED value.
fn min_s_lane(a: Int, b: Int, w: Int) -> Int {
  case signed_of(a, w) < signed_of(b, w) {
    True -> a
    False -> b
  }
}

/// Lane-wise signed maximum.
fn max_s_lane(a: Int, b: Int, w: Int) -> Int {
  case signed_of(a, w) < signed_of(b, w) {
    True -> b
    False -> a
  }
}

/// Lane-wise unsigned minimum (raw compare of the non-negative lane patterns).
fn min_u_lane(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}

/// Lane-wise unsigned maximum.
fn max_u_lane(a: Int, b: Int) -> Int {
  case a < b {
    True -> b
    False -> a
  }
}

/// Rounding unsigned average `(a + b + 1) >> 1` in full precision (never overflows; the result
/// is `≤ 2^w - 1`, so no mask is needed). Spec `iavgr_u`.
fn avgr_u_lane(a: Int, b: Int) -> Int {
  { a + b + 1 } / 2
}

/// Lane-wise left shift by `count` masked mod `w`: `(a << k) mod 2^w`.
fn shl_lane(a: Int, count: Int, w: Int) -> Int {
  mask_low(int.bitwise_shift_left(a, shift_count(count, w)), w)
}

/// Lane-wise logical right shift by `count` masked mod `w` (`a` is the non-negative pattern, so
/// an Erlang `bsr` is a zero-filling shift; the result stays `< 2^w`).
fn shr_u_lane(a: Int, count: Int, w: Int) -> Int {
  int.bitwise_shift_right(a, shift_count(count, w))
}

/// Lane-wise arithmetic right shift by `count` masked mod `w`: sign-extend the lane, `bsr`
/// (Erlang `bsr` floors on a negative operand = a sign-filling shift), and re-encode mod `2^w`.
fn shr_s_lane(a: Int, count: Int, w: Int) -> Int {
  mask_low(int.bitwise_shift_right(signed_of(a, w), shift_count(count, w)), w)
}

// ── integer arithmetic: lane-wise, two's-complement at the LANE width (I3) ─────────────────────────────────────────────

/// `i8x16.add` — lane-wise addition, wrapping at the lane width.
pub fn i8x16_add(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 8, fn(x, y) { add_lane(x, y, 8) })
}

/// `i16x8.add` — lane-wise addition, wrapping at the lane width.
pub fn i16x8_add(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 16, fn(x, y) { add_lane(x, y, 16) })
}

/// `i32x4.add` — lane-wise addition, wrapping at the lane width.
pub fn i32x4_add(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, fn(x, y) { add_lane(x, y, 32) })
}

/// `i64x2.add` — lane-wise addition, wrapping at the lane width.
pub fn i64x2_add(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 64, fn(x, y) { add_lane(x, y, 64) })
}

/// `i8x16.sub` — lane-wise subtraction, wrapping at the lane width.
pub fn i8x16_sub(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 8, fn(x, y) { sub_lane(x, y, 8) })
}

/// `i16x8.sub` — lane-wise subtraction, wrapping at the lane width.
pub fn i16x8_sub(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 16, fn(x, y) { sub_lane(x, y, 16) })
}

/// `i32x4.sub` — lane-wise subtraction, wrapping at the lane width.
pub fn i32x4_sub(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, fn(x, y) { sub_lane(x, y, 32) })
}

/// `i64x2.sub` — lane-wise subtraction, wrapping at the lane width.
pub fn i64x2_sub(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 64, fn(x, y) { sub_lane(x, y, 64) })
}

/// `i16x8.mul` — lane-wise multiplication, wrapping (no `i8x16.mul`).
pub fn i16x8_mul(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 16, fn(x, y) { mul_lane(x, y, 16) })
}

/// `i32x4.mul` — lane-wise multiplication, wrapping (no `i8x16.mul`).
pub fn i32x4_mul(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, fn(x, y) { mul_lane(x, y, 32) })
}

/// `i64x2.mul` — lane-wise multiplication, wrapping (no `i8x16.mul`).
pub fn i64x2_mul(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 64, fn(x, y) { mul_lane(x, y, 64) })
}

/// `i8x16.neg` — lane-wise negation (two's-complement).
pub fn i8x16_neg(a: BitArray) -> BitArray {
  map1_lanes(a, 8, fn(x) { neg_lane(x, 8) })
}

/// `i16x8.neg` — lane-wise negation (two's-complement).
pub fn i16x8_neg(a: BitArray) -> BitArray {
  map1_lanes(a, 16, fn(x) { neg_lane(x, 16) })
}

/// `i32x4.neg` — lane-wise negation (two's-complement).
pub fn i32x4_neg(a: BitArray) -> BitArray {
  map1_lanes(a, 32, fn(x) { neg_lane(x, 32) })
}

/// `i64x2.neg` — lane-wise negation (two's-complement).
pub fn i64x2_neg(a: BitArray) -> BitArray {
  map1_lanes(a, 64, fn(x) { neg_lane(x, 64) })
}

/// `i8x16.abs` — lane-wise absolute value (two's-complement).
pub fn i8x16_abs(a: BitArray) -> BitArray {
  map1_lanes(a, 8, fn(x) { abs_lane(x, 8) })
}

/// `i16x8.abs` — lane-wise absolute value (two's-complement).
pub fn i16x8_abs(a: BitArray) -> BitArray {
  map1_lanes(a, 16, fn(x) { abs_lane(x, 16) })
}

/// `i32x4.abs` — lane-wise absolute value (two's-complement).
pub fn i32x4_abs(a: BitArray) -> BitArray {
  map1_lanes(a, 32, fn(x) { abs_lane(x, 32) })
}

/// `i64x2.abs` — lane-wise absolute value (two's-complement).
pub fn i64x2_abs(a: BitArray) -> BitArray {
  map1_lanes(a, 64, fn(x) { abs_lane(x, 64) })
}

/// `i8x16.add_sat_s` — signed saturating add (never traps).
pub fn i8x16_add_sat_s(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 8, fn(x, y) { add_sat_s_lane(x, y, 8) })
}

/// `i16x8.add_sat_s` — signed saturating add (never traps).
pub fn i16x8_add_sat_s(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 16, fn(x, y) { add_sat_s_lane(x, y, 16) })
}

/// `i8x16.add_sat_u` — unsigned saturating add.
pub fn i8x16_add_sat_u(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 8, fn(x, y) { add_sat_u_lane(x, y, 8) })
}

/// `i16x8.add_sat_u` — unsigned saturating add.
pub fn i16x8_add_sat_u(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 16, fn(x, y) { add_sat_u_lane(x, y, 16) })
}

/// `i8x16.sub_sat_s` — signed saturating subtract.
pub fn i8x16_sub_sat_s(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 8, fn(x, y) { sub_sat_s_lane(x, y, 8) })
}

/// `i16x8.sub_sat_s` — signed saturating subtract.
pub fn i16x8_sub_sat_s(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 16, fn(x, y) { sub_sat_s_lane(x, y, 16) })
}

/// `i8x16.sub_sat_u` — unsigned saturating subtract.
pub fn i8x16_sub_sat_u(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 8, fn(x, y) { sub_sat_u_lane(x, y, 8) })
}

/// `i16x8.sub_sat_u` — unsigned saturating subtract.
pub fn i16x8_sub_sat_u(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 16, fn(x, y) { sub_sat_u_lane(x, y, 16) })
}

/// `i8x16.min_s` — lane-wise signed minimum.
pub fn i8x16_min_s(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 8, fn(x, y) { min_s_lane(x, y, 8) })
}

/// `i16x8.min_s` — lane-wise signed minimum.
pub fn i16x8_min_s(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 16, fn(x, y) { min_s_lane(x, y, 16) })
}

/// `i32x4.min_s` — lane-wise signed minimum.
pub fn i32x4_min_s(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, fn(x, y) { min_s_lane(x, y, 32) })
}

/// `i8x16.min_u` — lane-wise unsigned minimum.
pub fn i8x16_min_u(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 8, min_u_lane)
}

/// `i16x8.min_u` — lane-wise unsigned minimum.
pub fn i16x8_min_u(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 16, min_u_lane)
}

/// `i32x4.min_u` — lane-wise unsigned minimum.
pub fn i32x4_min_u(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, min_u_lane)
}

/// `i8x16.max_s` — lane-wise signed maximum.
pub fn i8x16_max_s(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 8, fn(x, y) { max_s_lane(x, y, 8) })
}

/// `i16x8.max_s` — lane-wise signed maximum.
pub fn i16x8_max_s(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 16, fn(x, y) { max_s_lane(x, y, 16) })
}

/// `i32x4.max_s` — lane-wise signed maximum.
pub fn i32x4_max_s(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, fn(x, y) { max_s_lane(x, y, 32) })
}

/// `i8x16.max_u` — lane-wise unsigned maximum.
pub fn i8x16_max_u(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 8, max_u_lane)
}

/// `i16x8.max_u` — lane-wise unsigned maximum.
pub fn i16x8_max_u(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 16, max_u_lane)
}

/// `i32x4.max_u` — lane-wise unsigned maximum.
pub fn i32x4_max_u(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, max_u_lane)
}

/// `i8x16.avgr_u` — rounding unsigned average `(a+b+1)>>1`.
pub fn i8x16_avgr_u(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 8, avgr_u_lane)
}

/// `i16x8.avgr_u` — rounding unsigned average `(a+b+1)>>1`.
pub fn i16x8_avgr_u(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 16, avgr_u_lane)
}

/// `i8x16.popcnt` — per-lane population count.
pub fn i8x16_popcnt(a: BitArray) -> BitArray {
  map1_lanes(a, 8, rt_num.i32_popcnt)
}

/// `i8x16.shl` — shift each lane left by `count` masked mod the lane width.
pub fn i8x16_shl(a: BitArray, count: Int) -> BitArray {
  map1_lanes(a, 8, fn(x) { shl_lane(x, count, 8) })
}

/// `i16x8.shl` — shift each lane left by `count` masked mod the lane width.
pub fn i16x8_shl(a: BitArray, count: Int) -> BitArray {
  map1_lanes(a, 16, fn(x) { shl_lane(x, count, 16) })
}

/// `i32x4.shl` — shift each lane left by `count` masked mod the lane width.
pub fn i32x4_shl(a: BitArray, count: Int) -> BitArray {
  map1_lanes(a, 32, fn(x) { shl_lane(x, count, 32) })
}

/// `i64x2.shl` — shift each lane left by `count` masked mod the lane width.
pub fn i64x2_shl(a: BitArray, count: Int) -> BitArray {
  map1_lanes(a, 64, fn(x) { shl_lane(x, count, 64) })
}

/// `i8x16.shr_s` — arithmetic right shift, `count` masked mod the lane width.
pub fn i8x16_shr_s(a: BitArray, count: Int) -> BitArray {
  map1_lanes(a, 8, fn(x) { shr_s_lane(x, count, 8) })
}

/// `i16x8.shr_s` — arithmetic right shift, `count` masked mod the lane width.
pub fn i16x8_shr_s(a: BitArray, count: Int) -> BitArray {
  map1_lanes(a, 16, fn(x) { shr_s_lane(x, count, 16) })
}

/// `i32x4.shr_s` — arithmetic right shift, `count` masked mod the lane width.
pub fn i32x4_shr_s(a: BitArray, count: Int) -> BitArray {
  map1_lanes(a, 32, fn(x) { shr_s_lane(x, count, 32) })
}

/// `i64x2.shr_s` — arithmetic right shift, `count` masked mod the lane width.
pub fn i64x2_shr_s(a: BitArray, count: Int) -> BitArray {
  map1_lanes(a, 64, fn(x) { shr_s_lane(x, count, 64) })
}

/// `i8x16.shr_u` — logical right shift, `count` masked mod the lane width.
pub fn i8x16_shr_u(a: BitArray, count: Int) -> BitArray {
  map1_lanes(a, 8, fn(x) { shr_u_lane(x, count, 8) })
}

/// `i16x8.shr_u` — logical right shift, `count` masked mod the lane width.
pub fn i16x8_shr_u(a: BitArray, count: Int) -> BitArray {
  map1_lanes(a, 16, fn(x) { shr_u_lane(x, count, 16) })
}

/// `i32x4.shr_u` — logical right shift, `count` masked mod the lane width.
pub fn i32x4_shr_u(a: BitArray, count: Int) -> BitArray {
  map1_lanes(a, 32, fn(x) { shr_u_lane(x, count, 32) })
}

/// `i64x2.shr_u` — logical right shift, `count` masked mod the lane width.
pub fn i64x2_shr_u(a: BitArray, count: Int) -> BitArray {
  map1_lanes(a, 64, fn(x) { shr_u_lane(x, count, 64) })
}

/// `i16x8.q15mulr_sat_s` — Q15 fixed-point rounding multiply, saturating.
pub fn i16x8_q15mulr_sat_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_q15mulr_sat_s — implemented in P6-07"
}

/// `i32x4.dot_i16x8_s` — pairwise i16x8 multiply-add → i32x4 (WRAPS at i32).
pub fn i32x4_dot_i16x8_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_dot_i16x8_s — implemented in P6-07"
}

// ── integer comparisons → a v128 MASK (all-ones / all-zeros per lane) ─────────────────────────────────────────────

/// `i8x16.eq` — lane-wise comparison → per-lane mask.
pub fn i8x16_eq(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i8x16_eq — implemented in P6-07"
}

/// `i8x16.ne` — lane-wise comparison → per-lane mask.
pub fn i8x16_ne(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i8x16_ne — implemented in P6-07"
}

/// `i8x16.lt_s` — lane-wise comparison → per-lane mask.
pub fn i8x16_lt_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i8x16_lt_s — implemented in P6-07"
}

/// `i8x16.lt_u` — lane-wise comparison → per-lane mask.
pub fn i8x16_lt_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i8x16_lt_u — implemented in P6-07"
}

/// `i8x16.gt_s` — lane-wise comparison → per-lane mask.
pub fn i8x16_gt_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i8x16_gt_s — implemented in P6-07"
}

/// `i8x16.gt_u` — lane-wise comparison → per-lane mask.
pub fn i8x16_gt_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i8x16_gt_u — implemented in P6-07"
}

/// `i8x16.le_s` — lane-wise comparison → per-lane mask.
pub fn i8x16_le_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i8x16_le_s — implemented in P6-07"
}

/// `i8x16.le_u` — lane-wise comparison → per-lane mask.
pub fn i8x16_le_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i8x16_le_u — implemented in P6-07"
}

/// `i8x16.ge_s` — lane-wise comparison → per-lane mask.
pub fn i8x16_ge_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i8x16_ge_s — implemented in P6-07"
}

/// `i8x16.ge_u` — lane-wise comparison → per-lane mask.
pub fn i8x16_ge_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i8x16_ge_u — implemented in P6-07"
}

/// `i16x8.eq` — lane-wise comparison → per-lane mask.
pub fn i16x8_eq(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_eq — implemented in P6-07"
}

/// `i16x8.ne` — lane-wise comparison → per-lane mask.
pub fn i16x8_ne(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_ne — implemented in P6-07"
}

/// `i16x8.lt_s` — lane-wise comparison → per-lane mask.
pub fn i16x8_lt_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_lt_s — implemented in P6-07"
}

/// `i16x8.lt_u` — lane-wise comparison → per-lane mask.
pub fn i16x8_lt_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_lt_u — implemented in P6-07"
}

/// `i16x8.gt_s` — lane-wise comparison → per-lane mask.
pub fn i16x8_gt_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_gt_s — implemented in P6-07"
}

/// `i16x8.gt_u` — lane-wise comparison → per-lane mask.
pub fn i16x8_gt_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_gt_u — implemented in P6-07"
}

/// `i16x8.le_s` — lane-wise comparison → per-lane mask.
pub fn i16x8_le_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_le_s — implemented in P6-07"
}

/// `i16x8.le_u` — lane-wise comparison → per-lane mask.
pub fn i16x8_le_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_le_u — implemented in P6-07"
}

/// `i16x8.ge_s` — lane-wise comparison → per-lane mask.
pub fn i16x8_ge_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_ge_s — implemented in P6-07"
}

/// `i16x8.ge_u` — lane-wise comparison → per-lane mask.
pub fn i16x8_ge_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_ge_u — implemented in P6-07"
}

/// `i32x4.eq` — lane-wise comparison → per-lane mask.
pub fn i32x4_eq(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_eq — implemented in P6-07"
}

/// `i32x4.ne` — lane-wise comparison → per-lane mask.
pub fn i32x4_ne(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_ne — implemented in P6-07"
}

/// `i32x4.lt_s` — lane-wise comparison → per-lane mask.
pub fn i32x4_lt_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_lt_s — implemented in P6-07"
}

/// `i32x4.lt_u` — lane-wise comparison → per-lane mask.
pub fn i32x4_lt_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_lt_u — implemented in P6-07"
}

/// `i32x4.gt_s` — lane-wise comparison → per-lane mask.
pub fn i32x4_gt_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_gt_s — implemented in P6-07"
}

/// `i32x4.gt_u` — lane-wise comparison → per-lane mask.
pub fn i32x4_gt_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_gt_u — implemented in P6-07"
}

/// `i32x4.le_s` — lane-wise comparison → per-lane mask.
pub fn i32x4_le_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_le_s — implemented in P6-07"
}

/// `i32x4.le_u` — lane-wise comparison → per-lane mask.
pub fn i32x4_le_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_le_u — implemented in P6-07"
}

/// `i32x4.ge_s` — lane-wise comparison → per-lane mask.
pub fn i32x4_ge_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_ge_s — implemented in P6-07"
}

/// `i32x4.ge_u` — lane-wise comparison → per-lane mask.
pub fn i32x4_ge_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_ge_u — implemented in P6-07"
}

/// `i64x2.eq` — lane-wise comparison → per-lane mask.
pub fn i64x2_eq(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i64x2_eq — implemented in P6-07"
}

/// `i64x2.ne` — lane-wise comparison → per-lane mask.
pub fn i64x2_ne(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i64x2_ne — implemented in P6-07"
}

/// `i64x2.lt_s` — lane-wise comparison → per-lane mask.
pub fn i64x2_lt_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i64x2_lt_s — implemented in P6-07"
}

/// `i64x2.gt_s` — lane-wise comparison → per-lane mask.
pub fn i64x2_gt_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i64x2_gt_s — implemented in P6-07"
}

/// `i64x2.le_s` — lane-wise comparison → per-lane mask.
pub fn i64x2_le_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i64x2_le_s — implemented in P6-07"
}

/// `i64x2.ge_s` — lane-wise comparison → per-lane mask.
pub fn i64x2_ge_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i64x2_ge_s — implemented in P6-07"
}

// ── v128 bitwise (shape-agnostic — operate on the whole 128 bits) ─────────────────────────────────────────────

/// `v128.not` — bitwise complement.
pub fn v128_not(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.v128_not — implemented in P6-07"
}

/// `v128.and` — bitwise AND.
pub fn v128_and(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.v128_and — implemented in P6-07"
}

/// `v128.or` — bitwise OR.
pub fn v128_or(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.v128_or — implemented in P6-07"
}

/// `v128.xor` — bitwise XOR.
pub fn v128_xor(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.v128_xor — implemented in P6-07"
}

/// `v128.andnot` — `a AND (NOT b)`.
pub fn v128_andnot(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.v128_andnot — implemented in P6-07"
}

/// `v128.bitselect` — per-bit `(a AND mask) OR (b AND NOT mask)`.
pub fn v128_bitselect(a: BitArray, b: BitArray, mask: BitArray) -> BitArray {
  let _ = #(a, b, mask)
  panic as "rt_simd.v128_bitselect — implemented in P6-07"
}

// ── boolean reductions / mask (→ i32) ─────────────────────────────────────────────

/// `v128.any_true` — 1 if any bit set, else 0.
pub fn v128_any_true(a: BitArray) -> Int {
  let _ = a
  panic as "rt_simd.v128_any_true — implemented in P6-07"
}

/// `i8x16.all_true` — 1 if every lane is non-zero, else 0.
pub fn i8x16_all_true(a: BitArray) -> Int {
  let _ = a
  panic as "rt_simd.i8x16_all_true — implemented in P6-07"
}

/// `i16x8.all_true` — 1 if every lane is non-zero, else 0.
pub fn i16x8_all_true(a: BitArray) -> Int {
  let _ = a
  panic as "rt_simd.i16x8_all_true — implemented in P6-07"
}

/// `i32x4.all_true` — 1 if every lane is non-zero, else 0.
pub fn i32x4_all_true(a: BitArray) -> Int {
  let _ = a
  panic as "rt_simd.i32x4_all_true — implemented in P6-07"
}

/// `i64x2.all_true` — 1 if every lane is non-zero, else 0.
pub fn i64x2_all_true(a: BitArray) -> Int {
  let _ = a
  panic as "rt_simd.i64x2_all_true — implemented in P6-07"
}

/// `i8x16.bitmask` — pack the high bit of each lane into an i32.
pub fn i8x16_bitmask(a: BitArray) -> Int {
  let _ = a
  panic as "rt_simd.i8x16_bitmask — implemented in P6-07"
}

/// `i16x8.bitmask` — pack the high bit of each lane into an i32.
pub fn i16x8_bitmask(a: BitArray) -> Int {
  let _ = a
  panic as "rt_simd.i16x8_bitmask — implemented in P6-07"
}

/// `i32x4.bitmask` — pack the high bit of each lane into an i32.
pub fn i32x4_bitmask(a: BitArray) -> Int {
  let _ = a
  panic as "rt_simd.i32x4_bitmask — implemented in P6-07"
}

/// `i64x2.bitmask` — pack the high bit of each lane into an i32.
pub fn i64x2_bitmask(a: BitArray) -> Int {
  let _ = a
  panic as "rt_simd.i64x2_bitmask — implemented in P6-07"
}

// ── splat — scalar (raw bits) → v128 (all lanes = scalar) ─────────────────────────────────────────────

/// `i8x16.splat` — `x` = i32 raw bits, low 8 used per lane.
pub fn i8x16_splat(x: Int) -> BitArray {
  let _ = x
  panic as "rt_simd.i8x16_splat — implemented in P6-07"
}

/// `i16x8.splat` — `x` = i32 raw bits, low 16 used per lane.
pub fn i16x8_splat(x: Int) -> BitArray {
  let _ = x
  panic as "rt_simd.i16x8_splat — implemented in P6-07"
}

/// `i32x4.splat` — `x` = i32 raw bits.
pub fn i32x4_splat(x: Int) -> BitArray {
  let _ = x
  panic as "rt_simd.i32x4_splat — implemented in P6-07"
}

/// `i64x2.splat` — `x` = i64 raw bits.
pub fn i64x2_splat(x: Int) -> BitArray {
  let _ = x
  panic as "rt_simd.i64x2_splat — implemented in P6-07"
}

/// `f32x4.splat` — `x` = f32 raw bits.
pub fn f32x4_splat(x: Int) -> BitArray {
  let _ = x
  panic as "rt_simd.f32x4_splat — implemented in P6-07"
}

/// `f64x2.splat` — `x` = f64 raw bits.
pub fn f64x2_splat(x: Int) -> BitArray {
  let _ = x
  panic as "rt_simd.f64x2_splat — implemented in P6-07"
}

// ── extract / replace lane (immediates as Int args) ─────────────────────────────────────────────

/// `i8x16.extract_lane_s` — sign-extend lane `lane` to i32.
pub fn i8x16_extract_lane_s(a: BitArray, lane: Int) -> Int {
  let _ = #(a, lane)
  panic as "rt_simd.i8x16_extract_lane_s — implemented in P6-07"
}

/// `i8x16.extract_lane_u` — zero-extend lane `lane` to i32.
pub fn i8x16_extract_lane_u(a: BitArray, lane: Int) -> Int {
  let _ = #(a, lane)
  panic as "rt_simd.i8x16_extract_lane_u — implemented in P6-07"
}

/// `i16x8.extract_lane_s` — sign-extend lane `lane` to i32.
pub fn i16x8_extract_lane_s(a: BitArray, lane: Int) -> Int {
  let _ = #(a, lane)
  panic as "rt_simd.i16x8_extract_lane_s — implemented in P6-07"
}

/// `i16x8.extract_lane_u` — zero-extend lane `lane` to i32.
pub fn i16x8_extract_lane_u(a: BitArray, lane: Int) -> Int {
  let _ = #(a, lane)
  panic as "rt_simd.i16x8_extract_lane_u — implemented in P6-07"
}

/// `i32x4.extract_lane` — lane `lane` as i32 raw bits.
pub fn i32x4_extract_lane(a: BitArray, lane: Int) -> Int {
  let _ = #(a, lane)
  panic as "rt_simd.i32x4_extract_lane — implemented in P6-07"
}

/// `i64x2.extract_lane` — lane `lane` as i64 raw bits.
pub fn i64x2_extract_lane(a: BitArray, lane: Int) -> Int {
  let _ = #(a, lane)
  panic as "rt_simd.i64x2_extract_lane — implemented in P6-07"
}

/// `f32x4.extract_lane` — lane `lane` as f32 raw bits.
pub fn f32x4_extract_lane(a: BitArray, lane: Int) -> Int {
  let _ = #(a, lane)
  panic as "rt_simd.f32x4_extract_lane — implemented in P6-07"
}

/// `f64x2.extract_lane` — lane `lane` as f64 raw bits.
pub fn f64x2_extract_lane(a: BitArray, lane: Int) -> Int {
  let _ = #(a, lane)
  panic as "rt_simd.f64x2_extract_lane — implemented in P6-07"
}

/// `i8x16.replace_lane` — replace lane `lane` with scalar `x` (raw bits).
pub fn i8x16_replace_lane(a: BitArray, lane: Int, x: Int) -> BitArray {
  let _ = #(a, lane, x)
  panic as "rt_simd.i8x16_replace_lane — implemented in P6-07"
}

/// `i16x8.replace_lane` — replace lane `lane` with scalar `x` (raw bits).
pub fn i16x8_replace_lane(a: BitArray, lane: Int, x: Int) -> BitArray {
  let _ = #(a, lane, x)
  panic as "rt_simd.i16x8_replace_lane — implemented in P6-07"
}

/// `i32x4.replace_lane` — replace lane `lane` with scalar `x` (raw bits).
pub fn i32x4_replace_lane(a: BitArray, lane: Int, x: Int) -> BitArray {
  let _ = #(a, lane, x)
  panic as "rt_simd.i32x4_replace_lane — implemented in P6-07"
}

/// `i64x2.replace_lane` — replace lane `lane` with scalar `x` (raw bits).
pub fn i64x2_replace_lane(a: BitArray, lane: Int, x: Int) -> BitArray {
  let _ = #(a, lane, x)
  panic as "rt_simd.i64x2_replace_lane — implemented in P6-07"
}

/// `f32x4.replace_lane` — replace lane `lane` with scalar `x` (raw bits).
pub fn f32x4_replace_lane(a: BitArray, lane: Int, x: Int) -> BitArray {
  let _ = #(a, lane, x)
  panic as "rt_simd.f32x4_replace_lane — implemented in P6-07"
}

/// `f64x2.replace_lane` — replace lane `lane` with scalar `x` (raw bits).
pub fn f64x2_replace_lane(a: BitArray, lane: Int, x: Int) -> BitArray {
  let _ = #(a, lane, x)
  panic as "rt_simd.f64x2_replace_lane — implemented in P6-07"
}

// ── float lanes — IEEE-754 (f32x4 single-rounding); no trap ─────────────────────────────────────────────

/// `f32x4.add` — lane-wise IEEE-754 add.
pub fn f32x4_add(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f32x4_add — implemented in P6-07"
}

/// `f32x4.sub` — lane-wise IEEE-754 sub.
pub fn f32x4_sub(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f32x4_sub — implemented in P6-07"
}

/// `f32x4.mul` — lane-wise IEEE-754 mul.
pub fn f32x4_mul(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f32x4_mul — implemented in P6-07"
}

/// `f32x4.div` — lane-wise IEEE-754 div.
pub fn f32x4_div(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f32x4_div — implemented in P6-07"
}

/// `f32x4.neg` — lane-wise IEEE-754 neg.
pub fn f32x4_neg(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f32x4_neg — implemented in P6-07"
}

/// `f32x4.abs` — lane-wise IEEE-754 abs.
pub fn f32x4_abs(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f32x4_abs — implemented in P6-07"
}

/// `f32x4.sqrt` — lane-wise IEEE-754 sqrt.
pub fn f32x4_sqrt(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f32x4_sqrt — implemented in P6-07"
}

/// `f32x4.min` — spec min (NaN- and -0.0-aware).
pub fn f32x4_min(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f32x4_min — implemented in P6-07"
}

/// `f32x4.max` — spec max (NaN- and -0.0-aware).
pub fn f32x4_max(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f32x4_max — implemented in P6-07"
}

/// `f32x4.pmin` — pseudo-min (`(b<a)?b:a`).
pub fn f32x4_pmin(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f32x4_pmin — implemented in P6-07"
}

/// `f32x4.pmax` — pseudo-max (`(a<b)?b:a`).
pub fn f32x4_pmax(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f32x4_pmax — implemented in P6-07"
}

/// `f32x4.ceil` — lane-wise IEEE round variant.
pub fn f32x4_ceil(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f32x4_ceil — implemented in P6-07"
}

/// `f32x4.floor` — lane-wise IEEE round variant.
pub fn f32x4_floor(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f32x4_floor — implemented in P6-07"
}

/// `f32x4.trunc` — lane-wise IEEE round variant.
pub fn f32x4_trunc(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f32x4_trunc — implemented in P6-07"
}

/// `f32x4.nearest` — lane-wise IEEE round variant.
pub fn f32x4_nearest(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f32x4_nearest — implemented in P6-07"
}

/// `f64x2.add` — lane-wise IEEE-754 add.
pub fn f64x2_add(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f64x2_add — implemented in P6-07"
}

/// `f64x2.sub` — lane-wise IEEE-754 sub.
pub fn f64x2_sub(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f64x2_sub — implemented in P6-07"
}

/// `f64x2.mul` — lane-wise IEEE-754 mul.
pub fn f64x2_mul(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f64x2_mul — implemented in P6-07"
}

/// `f64x2.div` — lane-wise IEEE-754 div.
pub fn f64x2_div(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f64x2_div — implemented in P6-07"
}

/// `f64x2.neg` — lane-wise IEEE-754 neg.
pub fn f64x2_neg(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f64x2_neg — implemented in P6-07"
}

/// `f64x2.abs` — lane-wise IEEE-754 abs.
pub fn f64x2_abs(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f64x2_abs — implemented in P6-07"
}

/// `f64x2.sqrt` — lane-wise IEEE-754 sqrt.
pub fn f64x2_sqrt(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f64x2_sqrt — implemented in P6-07"
}

/// `f64x2.min` — spec min (NaN- and -0.0-aware).
pub fn f64x2_min(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f64x2_min — implemented in P6-07"
}

/// `f64x2.max` — spec max (NaN- and -0.0-aware).
pub fn f64x2_max(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f64x2_max — implemented in P6-07"
}

/// `f64x2.pmin` — pseudo-min (`(b<a)?b:a`).
pub fn f64x2_pmin(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f64x2_pmin — implemented in P6-07"
}

/// `f64x2.pmax` — pseudo-max (`(a<b)?b:a`).
pub fn f64x2_pmax(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f64x2_pmax — implemented in P6-07"
}

/// `f64x2.ceil` — lane-wise IEEE round variant.
pub fn f64x2_ceil(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f64x2_ceil — implemented in P6-07"
}

/// `f64x2.floor` — lane-wise IEEE round variant.
pub fn f64x2_floor(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f64x2_floor — implemented in P6-07"
}

/// `f64x2.trunc` — lane-wise IEEE round variant.
pub fn f64x2_trunc(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f64x2_trunc — implemented in P6-07"
}

/// `f64x2.nearest` — lane-wise IEEE round variant.
pub fn f64x2_nearest(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f64x2_nearest — implemented in P6-07"
}

// ── float comparisons → a v128 mask ─────────────────────────────────────────────

/// `f32x4.eq` — lane-wise ordered comparison → per-lane mask.
pub fn f32x4_eq(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f32x4_eq — implemented in P6-07"
}

/// `f32x4.ne` — lane-wise ordered comparison → per-lane mask.
pub fn f32x4_ne(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f32x4_ne — implemented in P6-07"
}

/// `f32x4.lt` — lane-wise ordered comparison → per-lane mask.
pub fn f32x4_lt(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f32x4_lt — implemented in P6-07"
}

/// `f32x4.le` — lane-wise ordered comparison → per-lane mask.
pub fn f32x4_le(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f32x4_le — implemented in P6-07"
}

/// `f32x4.gt` — lane-wise ordered comparison → per-lane mask.
pub fn f32x4_gt(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f32x4_gt — implemented in P6-07"
}

/// `f32x4.ge` — lane-wise ordered comparison → per-lane mask.
pub fn f32x4_ge(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f32x4_ge — implemented in P6-07"
}

/// `f64x2.eq` — lane-wise ordered comparison → per-lane mask.
pub fn f64x2_eq(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f64x2_eq — implemented in P6-07"
}

/// `f64x2.ne` — lane-wise ordered comparison → per-lane mask.
pub fn f64x2_ne(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f64x2_ne — implemented in P6-07"
}

/// `f64x2.lt` — lane-wise ordered comparison → per-lane mask.
pub fn f64x2_lt(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f64x2_lt — implemented in P6-07"
}

/// `f64x2.le` — lane-wise ordered comparison → per-lane mask.
pub fn f64x2_le(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f64x2_le — implemented in P6-07"
}

/// `f64x2.gt` — lane-wise ordered comparison → per-lane mask.
pub fn f64x2_gt(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f64x2_gt — implemented in P6-07"
}

/// `f64x2.ge` — lane-wise ordered comparison → per-lane mask.
pub fn f64x2_ge(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.f64x2_ge — implemented in P6-07"
}

// ── conversions (singular — convert / trunc_sat / demote / promote) ─────────────────────────────────────────────

/// `i32x4.trunc_sat_f32x4_s` — saturating f32x4→i32x4 (NaN→0).
pub fn i32x4_trunc_sat_f32x4_s(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i32x4_trunc_sat_f32x4_s — implemented in P6-07"
}

/// `i32x4.trunc_sat_f32x4_u` — saturating unsigned f32x4→i32x4.
pub fn i32x4_trunc_sat_f32x4_u(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i32x4_trunc_sat_f32x4_u — implemented in P6-07"
}

/// `i32x4.trunc_sat_f64x2_s_zero` — f64x2→i32x4, upper lanes 0.
pub fn i32x4_trunc_sat_f64x2_s_zero(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i32x4_trunc_sat_f64x2_s_zero — implemented in P6-07"
}

/// `i32x4.trunc_sat_f64x2_u_zero` — unsigned f64x2→i32x4, upper 0.
pub fn i32x4_trunc_sat_f64x2_u_zero(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i32x4_trunc_sat_f64x2_u_zero — implemented in P6-07"
}

/// `f32x4.convert_i32x4_s` — signed i32x4→f32x4.
pub fn f32x4_convert_i32x4_s(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f32x4_convert_i32x4_s — implemented in P6-07"
}

/// `f32x4.convert_i32x4_u` — unsigned i32x4→f32x4.
pub fn f32x4_convert_i32x4_u(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f32x4_convert_i32x4_u — implemented in P6-07"
}

/// `f32x4.demote_f64x2_zero` — f64x2→f32x4, upper lanes 0.
pub fn f32x4_demote_f64x2_zero(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f32x4_demote_f64x2_zero — implemented in P6-07"
}

/// `f64x2.convert_low_i32x4_s` — low two i32x4→f64x2 (signed).
pub fn f64x2_convert_low_i32x4_s(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f64x2_convert_low_i32x4_s — implemented in P6-07"
}

/// `f64x2.convert_low_i32x4_u` — low two i32x4→f64x2 (unsigned).
pub fn f64x2_convert_low_i32x4_u(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f64x2_convert_low_i32x4_u — implemented in P6-07"
}

/// `f64x2.promote_low_f32x4` — low two f32x4→f64x2.
pub fn f64x2_promote_low_f32x4(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.f64x2_promote_low_f32x4 — implemented in P6-07"
}

// ── narrow (saturating), extend, extmul, extadd_pairwise ─────────────────────────────────────────────

/// `i8x16.narrow_i16x8_s` — signed saturating narrow of a++b.
pub fn i8x16_narrow_i16x8_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i8x16_narrow_i16x8_s — implemented in P6-07"
}

/// `i8x16.narrow_i16x8_u` — unsigned saturating narrow.
pub fn i8x16_narrow_i16x8_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i8x16_narrow_i16x8_u — implemented in P6-07"
}

/// `i16x8.narrow_i32x4_s` — signed saturating narrow.
pub fn i16x8_narrow_i32x4_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_narrow_i32x4_s — implemented in P6-07"
}

/// `i16x8.narrow_i32x4_u` — unsigned saturating narrow.
pub fn i16x8_narrow_i32x4_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_narrow_i32x4_u — implemented in P6-07"
}

/// `i16x8.extend_low_i8x16_s` — extend the low half of i8x16.
pub fn i16x8_extend_low_i8x16_s(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i16x8_extend_low_i8x16_s — implemented in P6-07"
}

/// `i16x8.extend_low_i8x16_u` — extend the low half of i8x16.
pub fn i16x8_extend_low_i8x16_u(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i16x8_extend_low_i8x16_u — implemented in P6-07"
}

/// `i16x8.extend_high_i8x16_s` — extend the high half of i8x16.
pub fn i16x8_extend_high_i8x16_s(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i16x8_extend_high_i8x16_s — implemented in P6-07"
}

/// `i16x8.extend_high_i8x16_u` — extend the high half of i8x16.
pub fn i16x8_extend_high_i8x16_u(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i16x8_extend_high_i8x16_u — implemented in P6-07"
}

/// `i32x4.extend_low_i16x8_s` — extend the low half of i16x8.
pub fn i32x4_extend_low_i16x8_s(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i32x4_extend_low_i16x8_s — implemented in P6-07"
}

/// `i32x4.extend_low_i16x8_u` — extend the low half of i16x8.
pub fn i32x4_extend_low_i16x8_u(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i32x4_extend_low_i16x8_u — implemented in P6-07"
}

/// `i32x4.extend_high_i16x8_s` — extend the high half of i16x8.
pub fn i32x4_extend_high_i16x8_s(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i32x4_extend_high_i16x8_s — implemented in P6-07"
}

/// `i32x4.extend_high_i16x8_u` — extend the high half of i16x8.
pub fn i32x4_extend_high_i16x8_u(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i32x4_extend_high_i16x8_u — implemented in P6-07"
}

/// `i64x2.extend_low_i32x4_s` — extend the low half of i32x4.
pub fn i64x2_extend_low_i32x4_s(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i64x2_extend_low_i32x4_s — implemented in P6-07"
}

/// `i64x2.extend_low_i32x4_u` — extend the low half of i32x4.
pub fn i64x2_extend_low_i32x4_u(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i64x2_extend_low_i32x4_u — implemented in P6-07"
}

/// `i64x2.extend_high_i32x4_s` — extend the high half of i32x4.
pub fn i64x2_extend_high_i32x4_s(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i64x2_extend_high_i32x4_s — implemented in P6-07"
}

/// `i64x2.extend_high_i32x4_u` — extend the high half of i32x4.
pub fn i64x2_extend_high_i32x4_u(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i64x2_extend_high_i32x4_u — implemented in P6-07"
}

/// `i16x8.extmul_low_i8x16_s` — extended multiply of the low half.
pub fn i16x8_extmul_low_i8x16_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_extmul_low_i8x16_s — implemented in P6-07"
}

/// `i16x8.extmul_low_i8x16_u` — extended multiply of the low half.
pub fn i16x8_extmul_low_i8x16_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_extmul_low_i8x16_u — implemented in P6-07"
}

/// `i16x8.extmul_high_i8x16_s` — extended multiply of the high half.
pub fn i16x8_extmul_high_i8x16_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_extmul_high_i8x16_s — implemented in P6-07"
}

/// `i16x8.extmul_high_i8x16_u` — extended multiply of the high half.
pub fn i16x8_extmul_high_i8x16_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i16x8_extmul_high_i8x16_u — implemented in P6-07"
}

/// `i32x4.extmul_low_i16x8_s` — extended multiply of the low half.
pub fn i32x4_extmul_low_i16x8_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_extmul_low_i16x8_s — implemented in P6-07"
}

/// `i32x4.extmul_low_i16x8_u` — extended multiply of the low half.
pub fn i32x4_extmul_low_i16x8_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_extmul_low_i16x8_u — implemented in P6-07"
}

/// `i32x4.extmul_high_i16x8_s` — extended multiply of the high half.
pub fn i32x4_extmul_high_i16x8_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_extmul_high_i16x8_s — implemented in P6-07"
}

/// `i32x4.extmul_high_i16x8_u` — extended multiply of the high half.
pub fn i32x4_extmul_high_i16x8_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i32x4_extmul_high_i16x8_u — implemented in P6-07"
}

/// `i64x2.extmul_low_i32x4_s` — extended multiply of the low half.
pub fn i64x2_extmul_low_i32x4_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i64x2_extmul_low_i32x4_s — implemented in P6-07"
}

/// `i64x2.extmul_low_i32x4_u` — extended multiply of the low half.
pub fn i64x2_extmul_low_i32x4_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i64x2_extmul_low_i32x4_u — implemented in P6-07"
}

/// `i64x2.extmul_high_i32x4_s` — extended multiply of the high half.
pub fn i64x2_extmul_high_i32x4_s(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i64x2_extmul_high_i32x4_s — implemented in P6-07"
}

/// `i64x2.extmul_high_i32x4_u` — extended multiply of the high half.
pub fn i64x2_extmul_high_i32x4_u(a: BitArray, b: BitArray) -> BitArray {
  let _ = #(a, b)
  panic as "rt_simd.i64x2_extmul_high_i32x4_u — implemented in P6-07"
}

/// `i16x8.extadd_pairwise_i8x16_s` — pairwise widening add.
pub fn i16x8_extadd_pairwise_i8x16_s(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i16x8_extadd_pairwise_i8x16_s — implemented in P6-07"
}

/// `i16x8.extadd_pairwise_i8x16_u` — pairwise widening add.
pub fn i16x8_extadd_pairwise_i8x16_u(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i16x8_extadd_pairwise_i8x16_u — implemented in P6-07"
}

/// `i32x4.extadd_pairwise_i16x8_s` — pairwise widening add.
pub fn i32x4_extadd_pairwise_i16x8_s(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i32x4_extadd_pairwise_i16x8_s — implemented in P6-07"
}

/// `i32x4.extadd_pairwise_i16x8_u` — pairwise widening add.
pub fn i32x4_extadd_pairwise_i16x8_u(a: BitArray) -> BitArray {
  let _ = a
  panic as "rt_simd.i32x4_extadd_pairwise_i16x8_u — implemented in P6-07"
}

// ── shuffle / swizzle ─────────────────────────────────────────────

/// `i8x16.shuffle` — 16 immediate lane indices (0..31) select bytes from a ++ b.
pub fn i8x16_shuffle(a: BitArray, b: BitArray, lanes: List(Int)) -> BitArray {
  let _ = #(a, b, lanes)
  panic as "rt_simd.i8x16_shuffle — implemented in P6-07"
}

/// `i8x16.swizzle` — dynamic byte select; index ≥ 16 → 0 (param `idx`, S15).
pub fn i8x16_swizzle(a: BitArray, idx: BitArray) -> BitArray {
  let _ = #(a, idx)
  panic as "rt_simd.i8x16_swizzle — implemented in P6-07"
}

// ── v128 memory lane-assembly helpers (PURE; rt_mem owns the bounds check — S4) ─────────────────────────────────────────────

/// Build a v128 by extending each of 8/4/2 `source_bits`-wide lanes of the 8-byte slice to double width (`v128.load8x8`/`load16x4`/`load32x2`).
pub fn v128_load_extend(
  bytes8: BitArray,
  source_bits: Int,
  signed: Bool,
) -> BitArray {
  let _ = #(bytes8, source_bits, signed)
  panic as "rt_simd.v128_load_extend — implemented in P6-07"
}

/// Build a v128 with the loaded `lane_bits` (32/64) in the low lane, upper bits zero (`v128.load32_zero`/`load64_zero`).
pub fn v128_load_zero(bytes: BitArray, lane_bits: Int) -> BitArray {
  let _ = #(bytes, lane_bits)
  panic as "rt_simd.v128_load_zero — implemented in P6-07"
}

/// Insert `bits` (`width` = 8/16/32/64) into lane `lane` of `vec` (`v128.loadN_lane` assembly).
pub fn v128_replace_lane_bits(
  vec: BitArray,
  lane: Int,
  width: Int,
  bits: Int,
) -> BitArray {
  let _ = #(vec, lane, width, bits)
  panic as "rt_simd.v128_replace_lane_bits — implemented in P6-07"
}

/// Extract lane `lane` (`width` bits) of `vec` as raw bits (`v128.storeN_lane` extraction).
pub fn v128_extract_lane_bits(vec: BitArray, lane: Int, width: Int) -> Int {
  let _ = #(vec, lane, width)
  panic as "rt_simd.v128_extract_lane_bits — implemented in P6-07"
}
