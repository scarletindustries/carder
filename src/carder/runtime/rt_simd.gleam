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
//// `Bool`/`List` — unit 07 adds `import carder/runtime/rt_num` when it fills the bodies, so the
//// keystone stays warning-free (no unused import). 07 CONSUMES `rt_num`, never edits it.
////
//// ## Spec anchor
////
//// The fixed-width SIMD instruction semantics (WebAssembly spec §4.4 vector instructions);
//// per-lane semantics are pinned in `ir.SimdOp`'s doc (two's-complement lane wrap, shift-count
//// masking mod lane width, f32 single-rounding, NaN canonicalisation, saturating narrow,
//// pmin/pmax pseudo-form, `dot_i16x8_s` wrapping, `avgr_u` rounding, swizzle OOB → 0).

import carder/runtime/rt_num
import gleam/bit_array
import gleam/int
import gleam/list

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

/// `i16x8.q15mulr_sat_s` — lane-wise Q15 fixed-point rounding multiply, saturating (spec
/// `q15mulr_sat_s`): `sat_s16((a·b + 0x4000) >> 15)` with SIGNED i16 inputs. The `+ 0x4000`
/// (= 2^14) is the round-to-nearest bias; the `>> 15` is an arithmetic (sign-filling) shift; the
/// result is clamped to `[-2^15, 2^15-1]`. The only lane that actually saturates is
/// `(-32768)·(-32768)` → `0x7FFF`. Never traps.
pub fn i16x8_q15mulr_sat_s(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 16, fn(x, y) {
    sat_s(
      int.bitwise_shift_right(signed_of(x, 16) * signed_of(y, 16) + 0x4000, 15),
      16,
    )
  })
}

/// `i32x4.dot_i16x8_s` — signed pairwise dot product (spec `idot`): for each i32 output lane `j`,
/// `(a[2j]·b[2j]) + (a[2j+1]·b[2j+1])` with SIGNED i16 inputs. Each product is exact in i32
/// (`|i16·i16| ≤ 2^30`); the sum of two adjacent products **WRAPS** at i32 (all lanes `-32768` →
/// `2^30 + 2^30 = 2^31` wraps to `0x80000000` = INT_MIN — verified vs wasmtime). Never traps.
pub fn i32x4_dot_i16x8_s(a: BitArray, b: BitArray) -> BitArray {
  let products =
    list.map2(
      list.map(decode_lanes(a, 16), fn(x) { signed_of(x, 16) }),
      list.map(decode_lanes(b, 16), fn(y) { signed_of(y, 16) }),
      fn(x, y) { x * y },
    )
  encode_lanes(pairwise(products, fn(x, y) { mask_low(x + y, 32) }), 32)
}

// ─────────────────────────── pass 07b private helpers (compare / bitwise / reductions / lane access) ───────────────────────────
//
// PRIVATE infrastructure for the comparison-mask, whole-vector bitwise, boolean-reduction and
// lane-access families. All funnel through the 07a codec (`decode_lanes`/`encode_lanes`/
// `map2_lanes`/`mask_low`/`signed_of`/`all_ones`/`pow2`); the only genuinely new primitives are
// the 128-bit whole-vector view (`bits128`/`from_bits128`) the shape-agnostic bitwise ops need
// and the lane-index read/write (`lane_at`/`set_lane`) the extract/replace ops need. Signed lane
// comparisons reuse the codec's `signed_of` (the sanctioned local mirror of `rt_num`'s two's-
// complement interpretation, §A.3), exactly as 07a's `min_s`/`max_s` do.

/// Decode the whole 16-byte v128 as ONE 128-bit unsigned integer. Endianness is irrelevant for
/// a shape-agnostic bitwise op: `bits128` and `from_bits128` use the same bit direction, so every
/// bit round-trips to its original position. Crashes node-safe if `v` is not exactly 16 bytes (an
/// internal-invariant failure — validation guarantees a 16-byte v128 — never a WASM trap).
fn bits128(v: BitArray) -> Int {
  let assert <<n:128>> = v
  n
}

/// Re-encode a 128-bit integer `n ∈ [0, 2^128)` as the 16-byte v128 (the inverse of `bits128`).
fn from_bits128(n: Int) -> BitArray {
  <<n:128>>
}

/// Per-lane comparison → mask: decode both operands into `w`-bit lanes, apply the boolean
/// relation `rel` to each corresponding lane pair, and emit the WASM lane result — `all_ones(w)`
/// (a lane of `-1` in two's complement, e.g. `0xFF` for i8) where the relation holds, `0`
/// (all-zeros) where it does not (spec `ieq`/`ilt_s`/… over vectors, §exec/numerics).
fn cmp_mask(
  a: BitArray,
  b: BitArray,
  w: Int,
  rel: fn(Int, Int) -> Bool,
) -> BitArray {
  map2_lanes(a, b, w, fn(x, y) {
    case rel(x, y) {
      True -> all_ones(w)
      False -> 0
    }
  })
}

/// `1` if EVERY `w`-bit lane of `v` is non-zero, else `0` (spec `all_true`). An empty-lane
/// vacuous truth cannot occur (a v128 always has ≥ 2 lanes).
fn all_true(v: BitArray, w: Int) -> Int {
  case list.all(decode_lanes(v, w), fn(lane) { lane != 0 }) {
    True -> 1
    False -> 0
  }
}

/// Gather the SIGN bit (bit `w-1`) of each `w`-bit lane of `v` into the low bits of an i32,
/// lane 0 → bit 0 (spec `bitmask`): a set sign bit in lane `i` contributes `1 << i`. Yields a
/// 16-bit result for i8x16, 8-bit for i16x8, 4-bit for i32x4, 2-bit for i64x2.
fn bitmask(v: BitArray, w: Int) -> Int {
  list.index_fold(decode_lanes(v, w), 0, fn(acc, lane, i) {
    case int.bitwise_and(lane, pow2(w - 1)) {
      0 -> acc
      _ -> int.bitwise_or(acc, int.bitwise_shift_left(1, i))
    }
  })
}

/// The raw `w`-bit lane at index `lane` of `v` as its non-negative bit pattern. `lane` is a
/// static immediate validation guarantees in `[0, 128/w)`; an out-of-range index crashes
/// node-safe (an internal-invariant failure, never a WASM trap).
fn lane_at(v: BitArray, w: Int, lane: Int) -> Int {
  let assert [x, ..] = list.drop(decode_lanes(v, w), lane)
  x
}

/// A copy of `v` with lane `lane` (of width `w`) replaced by the raw bits `x mod 2^w`. `lane`
/// is a static immediate in `[0, 128/w)` (validation-guaranteed).
fn set_lane(v: BitArray, w: Int, lane: Int, x: Int) -> BitArray {
  encode_lanes(
    list.index_map(decode_lanes(v, w), fn(l, i) {
      case i == lane {
        True -> mask_low(x, w)
        False -> l
      }
    }),
    w,
  )
}

/// Broadcast the raw-bit scalar `x` (taken mod `2^w`) into all `128/w` lanes of width `w`
/// (spec `splat`) — all 16 bytes are the scalar repeated in little-endian lane order.
fn splat(x: Int, w: Int) -> BitArray {
  encode_lanes(list.repeat(mask_low(x, w), 128 / w), w)
}

// ── integer comparisons → a v128 MASK (all-ones / all-zeros per lane) ─────────────────────────────────────────────

/// `i8x16.eq` — per-lane equality; each lane → `0xFF` (all-ones) if equal, `0x00` otherwise.
pub fn i8x16_eq(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 8, fn(x, y) { x == y })
}

/// `i8x16.ne` — per-lane inequality; `0xFF` if unequal, `0x00` otherwise.
pub fn i8x16_ne(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 8, fn(x, y) { x != y })
}

/// `i8x16.lt_s` — per-lane SIGNED less-than (two's-complement); `0xFF` if `a < b`, else `0x00`.
pub fn i8x16_lt_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 8, fn(x, y) { signed_of(x, 8) < signed_of(y, 8) })
}

/// `i8x16.lt_u` — per-lane UNSIGNED less-than (raw pattern); `0xFF` if `a < b`, else `0x00`.
pub fn i8x16_lt_u(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 8, fn(x, y) { x < y })
}

/// `i8x16.gt_s` — per-lane SIGNED greater-than; `0xFF` if `a > b`, else `0x00`.
pub fn i8x16_gt_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 8, fn(x, y) { signed_of(x, 8) > signed_of(y, 8) })
}

/// `i8x16.gt_u` — per-lane UNSIGNED greater-than; `0xFF` if `a > b`, else `0x00`.
pub fn i8x16_gt_u(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 8, fn(x, y) { x > y })
}

/// `i8x16.le_s` — per-lane SIGNED less-or-equal; `0xFF` if `a ≤ b`, else `0x00`.
pub fn i8x16_le_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 8, fn(x, y) { signed_of(x, 8) <= signed_of(y, 8) })
}

/// `i8x16.le_u` — per-lane UNSIGNED less-or-equal; `0xFF` if `a ≤ b`, else `0x00`.
pub fn i8x16_le_u(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 8, fn(x, y) { x <= y })
}

/// `i8x16.ge_s` — per-lane SIGNED greater-or-equal; `0xFF` if `a ≥ b`, else `0x00`.
pub fn i8x16_ge_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 8, fn(x, y) { signed_of(x, 8) >= signed_of(y, 8) })
}

/// `i8x16.ge_u` — per-lane UNSIGNED greater-or-equal; `0xFF` if `a ≥ b`, else `0x00`.
pub fn i8x16_ge_u(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 8, fn(x, y) { x >= y })
}

/// `i16x8.eq` — per-lane equality; each lane → `0xFFFF` if equal, `0x0000` otherwise.
pub fn i16x8_eq(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 16, fn(x, y) { x == y })
}

/// `i16x8.ne` — per-lane inequality; `0xFFFF` if unequal, `0x0000` otherwise.
pub fn i16x8_ne(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 16, fn(x, y) { x != y })
}

/// `i16x8.lt_s` — per-lane SIGNED less-than; `0xFFFF` if `a < b`, else `0x0000`.
pub fn i16x8_lt_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 16, fn(x, y) { signed_of(x, 16) < signed_of(y, 16) })
}

/// `i16x8.lt_u` — per-lane UNSIGNED less-than; `0xFFFF` if `a < b`, else `0x0000`.
pub fn i16x8_lt_u(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 16, fn(x, y) { x < y })
}

/// `i16x8.gt_s` — per-lane SIGNED greater-than; `0xFFFF` if `a > b`, else `0x0000`.
pub fn i16x8_gt_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 16, fn(x, y) { signed_of(x, 16) > signed_of(y, 16) })
}

/// `i16x8.gt_u` — per-lane UNSIGNED greater-than; `0xFFFF` if `a > b`, else `0x0000`.
pub fn i16x8_gt_u(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 16, fn(x, y) { x > y })
}

/// `i16x8.le_s` — per-lane SIGNED less-or-equal; `0xFFFF` if `a ≤ b`, else `0x0000`.
pub fn i16x8_le_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 16, fn(x, y) { signed_of(x, 16) <= signed_of(y, 16) })
}

/// `i16x8.le_u` — per-lane UNSIGNED less-or-equal; `0xFFFF` if `a ≤ b`, else `0x0000`.
pub fn i16x8_le_u(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 16, fn(x, y) { x <= y })
}

/// `i16x8.ge_s` — per-lane SIGNED greater-or-equal; `0xFFFF` if `a ≥ b`, else `0x0000`.
pub fn i16x8_ge_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 16, fn(x, y) { signed_of(x, 16) >= signed_of(y, 16) })
}

/// `i16x8.ge_u` — per-lane UNSIGNED greater-or-equal; `0xFFFF` if `a ≥ b`, else `0x0000`.
pub fn i16x8_ge_u(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 16, fn(x, y) { x >= y })
}

/// `i32x4.eq` — per-lane equality; each lane → `0xFFFFFFFF` if equal, `0` otherwise.
pub fn i32x4_eq(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 32, fn(x, y) { x == y })
}

/// `i32x4.ne` — per-lane inequality; `0xFFFFFFFF` if unequal, `0` otherwise.
pub fn i32x4_ne(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 32, fn(x, y) { x != y })
}

/// `i32x4.lt_s` — per-lane SIGNED less-than; `0xFFFFFFFF` if `a < b`, else `0`.
pub fn i32x4_lt_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 32, fn(x, y) { signed_of(x, 32) < signed_of(y, 32) })
}

/// `i32x4.lt_u` — per-lane UNSIGNED less-than; `0xFFFFFFFF` if `a < b`, else `0`.
pub fn i32x4_lt_u(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 32, fn(x, y) { x < y })
}

/// `i32x4.gt_s` — per-lane SIGNED greater-than; `0xFFFFFFFF` if `a > b`, else `0`.
pub fn i32x4_gt_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 32, fn(x, y) { signed_of(x, 32) > signed_of(y, 32) })
}

/// `i32x4.gt_u` — per-lane UNSIGNED greater-than; `0xFFFFFFFF` if `a > b`, else `0`.
pub fn i32x4_gt_u(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 32, fn(x, y) { x > y })
}

/// `i32x4.le_s` — per-lane SIGNED less-or-equal; `0xFFFFFFFF` if `a ≤ b`, else `0`.
pub fn i32x4_le_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 32, fn(x, y) { signed_of(x, 32) <= signed_of(y, 32) })
}

/// `i32x4.le_u` — per-lane UNSIGNED less-or-equal; `0xFFFFFFFF` if `a ≤ b`, else `0`.
pub fn i32x4_le_u(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 32, fn(x, y) { x <= y })
}

/// `i32x4.ge_s` — per-lane SIGNED greater-or-equal; `0xFFFFFFFF` if `a ≥ b`, else `0`.
pub fn i32x4_ge_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 32, fn(x, y) { signed_of(x, 32) >= signed_of(y, 32) })
}

/// `i32x4.ge_u` — per-lane UNSIGNED greater-or-equal; `0xFFFFFFFF` if `a ≥ b`, else `0`.
pub fn i32x4_ge_u(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 32, fn(x, y) { x >= y })
}

/// `i64x2.eq` — per-lane equality; each lane → all-ones (64-bit) if equal, `0` otherwise.
pub fn i64x2_eq(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 64, fn(x, y) { x == y })
}

/// `i64x2.ne` — per-lane inequality; all-ones if unequal, `0` otherwise.
pub fn i64x2_ne(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 64, fn(x, y) { x != y })
}

/// `i64x2.lt_s` — per-lane SIGNED less-than; all-ones if `a < b`, else `0`. (i64x2 has only
/// SIGNED ordering compares — no unsigned variants exist in the spec.)
pub fn i64x2_lt_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 64, fn(x, y) { signed_of(x, 64) < signed_of(y, 64) })
}

/// `i64x2.gt_s` — per-lane SIGNED greater-than; all-ones if `a > b`, else `0`.
pub fn i64x2_gt_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 64, fn(x, y) { signed_of(x, 64) > signed_of(y, 64) })
}

/// `i64x2.le_s` — per-lane SIGNED less-or-equal; all-ones if `a ≤ b`, else `0`.
pub fn i64x2_le_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 64, fn(x, y) { signed_of(x, 64) <= signed_of(y, 64) })
}

/// `i64x2.ge_s` — per-lane SIGNED greater-or-equal; all-ones if `a ≥ b`, else `0`.
pub fn i64x2_ge_s(a: BitArray, b: BitArray) -> BitArray {
  cmp_mask(a, b, 64, fn(x, y) { signed_of(x, 64) >= signed_of(y, 64) })
}

// ── v128 bitwise (shape-agnostic — operate on the whole 128 bits) ─────────────────────────────────────────────

/// `v128.not` — bitwise complement of all 128 bits (`~a`), computed as `a XOR all-ones`.
pub fn v128_not(a: BitArray) -> BitArray {
  from_bits128(int.bitwise_exclusive_or(bits128(a), all_ones(128)))
}

/// `v128.and` — bitwise AND of all 128 bits.
pub fn v128_and(a: BitArray, b: BitArray) -> BitArray {
  from_bits128(int.bitwise_and(bits128(a), bits128(b)))
}

/// `v128.or` — bitwise OR of all 128 bits.
pub fn v128_or(a: BitArray, b: BitArray) -> BitArray {
  from_bits128(int.bitwise_or(bits128(a), bits128(b)))
}

/// `v128.xor` — bitwise XOR of all 128 bits.
pub fn v128_xor(a: BitArray, b: BitArray) -> BitArray {
  from_bits128(int.bitwise_exclusive_or(bits128(a), bits128(b)))
}

/// `v128.andnot` — `a AND (NOT b)` over all 128 bits (note the fixed operand order: `a` is kept
/// where `b` is clear).
pub fn v128_andnot(a: BitArray, b: BitArray) -> BitArray {
  from_bits128(int.bitwise_and(
    bits128(a),
    int.bitwise_exclusive_or(bits128(b), all_ones(128)),
  ))
}

/// `v128.bitselect` — per-bit `(a AND mask) OR (b AND NOT mask)`: bit `i` of the result is `a`'s
/// bit where `mask`'s bit is 1, else `b`'s bit.
pub fn v128_bitselect(a: BitArray, b: BitArray, mask: BitArray) -> BitArray {
  let m = bits128(mask)
  from_bits128(int.bitwise_or(
    int.bitwise_and(bits128(a), m),
    int.bitwise_and(bits128(b), int.bitwise_exclusive_or(m, all_ones(128))),
  ))
}

// ── boolean reductions / mask (→ i32) ─────────────────────────────────────────────

/// `v128.any_true` — `1` if ANY bit of the whole 128-bit value is set, else `0`
/// (shape-agnostic; spec `any_true`).
pub fn v128_any_true(a: BitArray) -> Int {
  case bits128(a) {
    0 -> 0
    _ -> 1
  }
}

/// `i8x16.all_true` — `1` if every one of the 16 i8 lanes is non-zero, else `0`.
pub fn i8x16_all_true(a: BitArray) -> Int {
  all_true(a, 8)
}

/// `i16x8.all_true` — `1` if every one of the 8 i16 lanes is non-zero, else `0`.
pub fn i16x8_all_true(a: BitArray) -> Int {
  all_true(a, 16)
}

/// `i32x4.all_true` — `1` if every one of the 4 i32 lanes is non-zero, else `0`.
pub fn i32x4_all_true(a: BitArray) -> Int {
  all_true(a, 32)
}

/// `i64x2.all_true` — `1` if both i64 lanes are non-zero, else `0`.
pub fn i64x2_all_true(a: BitArray) -> Int {
  all_true(a, 64)
}

/// `i8x16.bitmask` — gather the high bit of each of the 16 i8 lanes into the low 16 bits of an
/// i32 (lane 0 → bit 0).
pub fn i8x16_bitmask(a: BitArray) -> Int {
  bitmask(a, 8)
}

/// `i16x8.bitmask` — gather the high bit of each of the 8 i16 lanes into the low 8 bits of an i32.
pub fn i16x8_bitmask(a: BitArray) -> Int {
  bitmask(a, 16)
}

/// `i32x4.bitmask` — gather the high bit of each of the 4 i32 lanes into the low 4 bits of an i32.
pub fn i32x4_bitmask(a: BitArray) -> Int {
  bitmask(a, 32)
}

/// `i64x2.bitmask` — gather the high bit of each of the 2 i64 lanes into the low 2 bits of an i32.
pub fn i64x2_bitmask(a: BitArray) -> Int {
  bitmask(a, 64)
}

// ── splat — scalar (raw bits) → v128 (all lanes = scalar) ─────────────────────────────────────────────

/// `i8x16.splat` — broadcast `x`'s low 8 bits (i32 raw scalar, `x mod 2^8`) into all 16 lanes.
pub fn i8x16_splat(x: Int) -> BitArray {
  splat(x, 8)
}

/// `i16x8.splat` — broadcast `x`'s low 16 bits (`x mod 2^16`) into all 8 lanes.
pub fn i16x8_splat(x: Int) -> BitArray {
  splat(x, 16)
}

/// `i32x4.splat` — broadcast the i32 raw bits `x` into all 4 lanes.
pub fn i32x4_splat(x: Int) -> BitArray {
  splat(x, 32)
}

/// `i64x2.splat` — broadcast the i64 raw bits `x` into both lanes.
pub fn i64x2_splat(x: Int) -> BitArray {
  splat(x, 64)
}

/// `f32x4.splat` — broadcast the f32 raw bit pattern `x` into all 4 lanes (identical byte layout
/// to `i32x4.splat`; the float interpretation is `rt_num`'s job, not the codec's).
pub fn f32x4_splat(x: Int) -> BitArray {
  splat(x, 32)
}

/// `f64x2.splat` — broadcast the f64 raw bit pattern `x` into both lanes.
pub fn f64x2_splat(x: Int) -> BitArray {
  splat(x, 64)
}

// ── extract / replace lane (immediates as Int args) ─────────────────────────────────────────────

/// `i8x16.extract_lane_s` — read lane `lane` (an i8) SIGN-extended to i32 raw bits (reuses
/// `rt_num.i32_extend8_s`): byte `0xFF` → `0xFFFFFFFF` (=−1).
pub fn i8x16_extract_lane_s(a: BitArray, lane: Int) -> Int {
  rt_num.i32_extend8_s(lane_at(a, 8, lane))
}

/// `i8x16.extract_lane_u` — read lane `lane` (an i8) ZERO-extended to i32: byte `0xFF` →
/// `0x000000FF` (=255). (The raw lane pattern is already the zero-extension.)
pub fn i8x16_extract_lane_u(a: BitArray, lane: Int) -> Int {
  lane_at(a, 8, lane)
}

/// `i16x8.extract_lane_s` — read lane `lane` (an i16) SIGN-extended to i32 raw bits (reuses
/// `rt_num.i32_extend16_s`): `0x8000` → `0xFFFF8000`.
pub fn i16x8_extract_lane_s(a: BitArray, lane: Int) -> Int {
  rt_num.i32_extend16_s(lane_at(a, 16, lane))
}

/// `i16x8.extract_lane_u` — read lane `lane` (an i16) ZERO-extended to i32.
pub fn i16x8_extract_lane_u(a: BitArray, lane: Int) -> Int {
  lane_at(a, 16, lane)
}

/// `i32x4.extract_lane` — read lane `lane` as its i32 raw bits (no s/u — the lane already fills
/// an i32).
pub fn i32x4_extract_lane(a: BitArray, lane: Int) -> Int {
  lane_at(a, 32, lane)
}

/// `i64x2.extract_lane` — read lane `lane` as its i64 raw bits.
pub fn i64x2_extract_lane(a: BitArray, lane: Int) -> Int {
  lane_at(a, 64, lane)
}

/// `f32x4.extract_lane` — read lane `lane` as its f32 raw bit pattern (no re-interpretation).
pub fn f32x4_extract_lane(a: BitArray, lane: Int) -> Int {
  lane_at(a, 32, lane)
}

/// `f64x2.extract_lane` — read lane `lane` as its f64 raw bit pattern.
pub fn f64x2_extract_lane(a: BitArray, lane: Int) -> Int {
  lane_at(a, 64, lane)
}

/// `i8x16.replace_lane` — a copy of `a` with lane `lane` set to `x`'s low 8 bits (`x mod 2^8`).
pub fn i8x16_replace_lane(a: BitArray, lane: Int, x: Int) -> BitArray {
  set_lane(a, 8, lane, x)
}

/// `i16x8.replace_lane` — a copy of `a` with lane `lane` set to `x`'s low 16 bits.
pub fn i16x8_replace_lane(a: BitArray, lane: Int, x: Int) -> BitArray {
  set_lane(a, 16, lane, x)
}

/// `i32x4.replace_lane` — a copy of `a` with lane `lane` set to the i32 raw bits `x`.
pub fn i32x4_replace_lane(a: BitArray, lane: Int, x: Int) -> BitArray {
  set_lane(a, 32, lane, x)
}

/// `i64x2.replace_lane` — a copy of `a` with lane `lane` set to the i64 raw bits `x`.
pub fn i64x2_replace_lane(a: BitArray, lane: Int, x: Int) -> BitArray {
  set_lane(a, 64, lane, x)
}

/// `f32x4.replace_lane` — a copy of `a` with lane `lane` set to the f32 raw bit pattern `x`.
pub fn f32x4_replace_lane(a: BitArray, lane: Int, x: Int) -> BitArray {
  set_lane(a, 32, lane, x)
}

/// `f64x2.replace_lane` — a copy of `a` with lane `lane` set to the f64 raw bit pattern `x`.
pub fn f64x2_replace_lane(a: BitArray, lane: Int, x: Int) -> BitArray {
  set_lane(a, 64, lane, x)
}

// ── float lanes — IEEE-754 (f32x4 single-rounding); no trap ─────────────────────────────────────────────
//
// PRIVATE 07c helpers. The float lanes + conversions reuse the 07a codec VERBATIM: a float lane
// IS its raw 32/64-bit pattern (D5), so `decode_lanes(v, 32/64)` hands each lane straight to the
// matching `rt_num` f32/f64 head — f32 single-rounding, the canonical-NaN lock, exact overflow→
// ±Inf, and the WASM min/max NaN & -0.0 rules all live INSIDE `rt_num`, so per-lane reuse inherits
// them (I3). `map1_lanes`/`map2_lanes` (07a) are the drivers; `cmp_mask` (07b) builds the compare
// masks. The only genuinely-new primitives are the pseudo-min/max SELECT (`pmin_lane`/`pmax_lane`,
// built from `rt_num`'s raw `f*_lt`), the compare→mask adapter (`fcmp`, bridging `rt_num`'s 1/0
// truth into `cmp_mask`), and the two lane-count-changing conversion drivers (`convert_low2`
// halves 4→2 lanes; `narrow_zero` doubles 2→4 with a zero top half).

/// Pseudo-minimum of one lane pair (spec `fpmin`): `pmin(a,b) = (b < a) ? b : a` — a strict-`<`
/// SELECT, NOT the min/max NaN rules. `lt` is `rt_num.f32_lt`/`f64_lt`, which returns `0` for ANY
/// NaN operand, so if either operand is NaN the compare is false and `pmin` returns `a` VERBATIM
/// (its raw bits — pmin/pmax do NOT canonicalise the NaN payload). Also asymmetric on signed zero:
/// since `-0 < +0` is IEEE-false, `pmin(-0,+0) = -0` and `pmin(+0,-0) = +0`.
fn pmin_lane(a: Int, b: Int, lt: fn(Int, Int) -> Int) -> Int {
  case lt(b, a) {
    1 -> b
    _ -> a
  }
}

/// Pseudo-maximum of one lane pair (spec `fpmax`): `pmax(a,b) = (a < b) ? b : a`. Same posture as
/// `pmin_lane` — a NaN operand makes the compare false and returns `a` verbatim; `pmax(-0,+0)=+0`,
/// `pmax(+0,-0)=-0` (asymmetric, since `-0 < +0` is false).
fn pmax_lane(a: Int, b: Int, lt: fn(Int, Int) -> Int) -> Int {
  case lt(a, b) {
    1 -> b
    _ -> a
  }
}

/// Lane-wise float comparison → v128 mask: bridge `rt_num`'s `1`/`0` ordered-compare result
/// (`rel`, e.g. `rt_num.f32_eq`) into 07b's `cmp_mask`, so each lane becomes `all_ones(w)` where
/// the relation holds and `0` otherwise. NaN semantics are `rt_num`'s: `eq/lt/le/gt/ge` are `0`
/// for any NaN operand (→ all-zeros lane); `ne` is `1` (→ all-ones lane).
fn fcmp(
  a: BitArray,
  b: BitArray,
  w: Int,
  rel: fn(Int, Int) -> Int,
) -> BitArray {
  cmp_mask(a, b, w, fn(x, y) { rel(x, y) == 1 })
}

/// Widening lane-count-HALVING conversion driver (`convert_low_i32x4_*`, `promote_low_f32x4`):
/// decode `a` into its four `from_w`-bit lanes, keep only the LOW 2 (the upper 2 are ignored per
/// spec), apply `f` per lane, and re-encode as two `to_w`-bit lanes (a 16-byte v128).
fn convert_low2(
  a: BitArray,
  from_w: Int,
  to_w: Int,
  f: fn(Int) -> Int,
) -> BitArray {
  encode_lanes(list.map(list.take(decode_lanes(a, from_w), 2), f), to_w)
}

/// Narrowing lane-count-DOUBLING `_zero` conversion driver (`trunc_sat_f64x2_*_zero`,
/// `demote_f64x2_zero`): decode `a` into its two `from_w`-bit lanes, apply `f` per lane to fill
/// result lanes 0,1, and force result lanes 2,3 to `0` (the `_zero` suffix — `+0.0` for f32 /
/// `0x00000000` for i32, both the all-zero pattern), re-encoded as four `to_w`-bit lanes.
fn narrow_zero(
  a: BitArray,
  from_w: Int,
  to_w: Int,
  f: fn(Int) -> Int,
) -> BitArray {
  encode_lanes(list.append(list.map(decode_lanes(a, from_w), f), [0, 0]), to_w)
}

/// `f32x4.add` — lane-wise IEEE-754 add.
pub fn f32x4_add(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, rt_num.f32_add)
}

/// `f32x4.sub` — lane-wise IEEE-754 sub.
pub fn f32x4_sub(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, rt_num.f32_sub)
}

/// `f32x4.mul` — lane-wise IEEE-754 mul.
pub fn f32x4_mul(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, rt_num.f32_mul)
}

/// `f32x4.div` — lane-wise IEEE-754 div.
pub fn f32x4_div(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, rt_num.f32_div)
}

/// `f32x4.neg` — lane-wise IEEE-754 neg.
pub fn f32x4_neg(a: BitArray) -> BitArray {
  map1_lanes(a, 32, rt_num.f32_neg)
}

/// `f32x4.abs` — lane-wise IEEE-754 abs.
pub fn f32x4_abs(a: BitArray) -> BitArray {
  map1_lanes(a, 32, rt_num.f32_abs)
}

/// `f32x4.sqrt` — lane-wise IEEE-754 sqrt.
pub fn f32x4_sqrt(a: BitArray) -> BitArray {
  map1_lanes(a, 32, rt_num.f32_sqrt)
}

/// `f32x4.min` — spec min (NaN- and -0.0-aware).
pub fn f32x4_min(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, rt_num.f32_min)
}

/// `f32x4.max` — spec max (NaN- and -0.0-aware).
pub fn f32x4_max(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, rt_num.f32_max)
}

/// `f32x4.pmin` — pseudo-min (`(b<a)?b:a`).
pub fn f32x4_pmin(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, fn(x, y) { pmin_lane(x, y, rt_num.f32_lt) })
}

/// `f32x4.pmax` — pseudo-max (`(a<b)?b:a`).
pub fn f32x4_pmax(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 32, fn(x, y) { pmax_lane(x, y, rt_num.f32_lt) })
}

/// `f32x4.ceil` — lane-wise IEEE round variant.
pub fn f32x4_ceil(a: BitArray) -> BitArray {
  map1_lanes(a, 32, rt_num.f32_ceil)
}

/// `f32x4.floor` — lane-wise IEEE round variant.
pub fn f32x4_floor(a: BitArray) -> BitArray {
  map1_lanes(a, 32, rt_num.f32_floor)
}

/// `f32x4.trunc` — lane-wise IEEE round variant.
pub fn f32x4_trunc(a: BitArray) -> BitArray {
  map1_lanes(a, 32, rt_num.f32_trunc)
}

/// `f32x4.nearest` — lane-wise IEEE round variant.
pub fn f32x4_nearest(a: BitArray) -> BitArray {
  map1_lanes(a, 32, rt_num.f32_nearest)
}

/// `f64x2.add` — lane-wise IEEE-754 add.
pub fn f64x2_add(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 64, rt_num.f64_add)
}

/// `f64x2.sub` — lane-wise IEEE-754 sub.
pub fn f64x2_sub(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 64, rt_num.f64_sub)
}

/// `f64x2.mul` — lane-wise IEEE-754 mul.
pub fn f64x2_mul(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 64, rt_num.f64_mul)
}

/// `f64x2.div` — lane-wise IEEE-754 div.
pub fn f64x2_div(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 64, rt_num.f64_div)
}

/// `f64x2.neg` — lane-wise IEEE-754 neg.
pub fn f64x2_neg(a: BitArray) -> BitArray {
  map1_lanes(a, 64, rt_num.f64_neg)
}

/// `f64x2.abs` — lane-wise IEEE-754 abs.
pub fn f64x2_abs(a: BitArray) -> BitArray {
  map1_lanes(a, 64, rt_num.f64_abs)
}

/// `f64x2.sqrt` — lane-wise IEEE-754 sqrt.
pub fn f64x2_sqrt(a: BitArray) -> BitArray {
  map1_lanes(a, 64, rt_num.f64_sqrt)
}

/// `f64x2.min` — spec min (NaN- and -0.0-aware).
pub fn f64x2_min(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 64, rt_num.f64_min)
}

/// `f64x2.max` — spec max (NaN- and -0.0-aware).
pub fn f64x2_max(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 64, rt_num.f64_max)
}

/// `f64x2.pmin` — pseudo-min (`(b<a)?b:a`).
pub fn f64x2_pmin(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 64, fn(x, y) { pmin_lane(x, y, rt_num.f64_lt) })
}

/// `f64x2.pmax` — pseudo-max (`(a<b)?b:a`).
pub fn f64x2_pmax(a: BitArray, b: BitArray) -> BitArray {
  map2_lanes(a, b, 64, fn(x, y) { pmax_lane(x, y, rt_num.f64_lt) })
}

/// `f64x2.ceil` — lane-wise IEEE round variant.
pub fn f64x2_ceil(a: BitArray) -> BitArray {
  map1_lanes(a, 64, rt_num.f64_ceil)
}

/// `f64x2.floor` — lane-wise IEEE round variant.
pub fn f64x2_floor(a: BitArray) -> BitArray {
  map1_lanes(a, 64, rt_num.f64_floor)
}

/// `f64x2.trunc` — lane-wise IEEE round variant.
pub fn f64x2_trunc(a: BitArray) -> BitArray {
  map1_lanes(a, 64, rt_num.f64_trunc)
}

/// `f64x2.nearest` — lane-wise IEEE round variant.
pub fn f64x2_nearest(a: BitArray) -> BitArray {
  map1_lanes(a, 64, rt_num.f64_nearest)
}

// ── float comparisons → a v128 mask ─────────────────────────────────────────────

/// `f32x4.eq` — lane-wise ordered comparison → per-lane mask.
pub fn f32x4_eq(a: BitArray, b: BitArray) -> BitArray {
  fcmp(a, b, 32, rt_num.f32_eq)
}

/// `f32x4.ne` — lane-wise ordered comparison → per-lane mask.
pub fn f32x4_ne(a: BitArray, b: BitArray) -> BitArray {
  fcmp(a, b, 32, rt_num.f32_ne)
}

/// `f32x4.lt` — lane-wise ordered comparison → per-lane mask.
pub fn f32x4_lt(a: BitArray, b: BitArray) -> BitArray {
  fcmp(a, b, 32, rt_num.f32_lt)
}

/// `f32x4.le` — lane-wise ordered comparison → per-lane mask.
pub fn f32x4_le(a: BitArray, b: BitArray) -> BitArray {
  fcmp(a, b, 32, rt_num.f32_le)
}

/// `f32x4.gt` — lane-wise ordered comparison → per-lane mask.
pub fn f32x4_gt(a: BitArray, b: BitArray) -> BitArray {
  fcmp(a, b, 32, rt_num.f32_gt)
}

/// `f32x4.ge` — lane-wise ordered comparison → per-lane mask.
pub fn f32x4_ge(a: BitArray, b: BitArray) -> BitArray {
  fcmp(a, b, 32, rt_num.f32_ge)
}

/// `f64x2.eq` — lane-wise ordered comparison → per-lane mask.
pub fn f64x2_eq(a: BitArray, b: BitArray) -> BitArray {
  fcmp(a, b, 64, rt_num.f64_eq)
}

/// `f64x2.ne` — lane-wise ordered comparison → per-lane mask.
pub fn f64x2_ne(a: BitArray, b: BitArray) -> BitArray {
  fcmp(a, b, 64, rt_num.f64_ne)
}

/// `f64x2.lt` — lane-wise ordered comparison → per-lane mask.
pub fn f64x2_lt(a: BitArray, b: BitArray) -> BitArray {
  fcmp(a, b, 64, rt_num.f64_lt)
}

/// `f64x2.le` — lane-wise ordered comparison → per-lane mask.
pub fn f64x2_le(a: BitArray, b: BitArray) -> BitArray {
  fcmp(a, b, 64, rt_num.f64_le)
}

/// `f64x2.gt` — lane-wise ordered comparison → per-lane mask.
pub fn f64x2_gt(a: BitArray, b: BitArray) -> BitArray {
  fcmp(a, b, 64, rt_num.f64_gt)
}

/// `f64x2.ge` — lane-wise ordered comparison → per-lane mask.
pub fn f64x2_ge(a: BitArray, b: BitArray) -> BitArray {
  fcmp(a, b, 64, rt_num.f64_ge)
}

// ── conversions (singular — convert / trunc_sat / demote / promote) ─────────────────────────────────────────────

/// `i32x4.trunc_sat_f32x4_s` — saturating f32x4→i32x4 (NaN→0).
pub fn i32x4_trunc_sat_f32x4_s(a: BitArray) -> BitArray {
  map1_lanes(a, 32, rt_num.i32_trunc_sat_f32_s)
}

/// `i32x4.trunc_sat_f32x4_u` — saturating unsigned f32x4→i32x4.
pub fn i32x4_trunc_sat_f32x4_u(a: BitArray) -> BitArray {
  map1_lanes(a, 32, rt_num.i32_trunc_sat_f32_u)
}

/// `i32x4.trunc_sat_f64x2_s_zero` — f64x2→i32x4, upper lanes 0.
pub fn i32x4_trunc_sat_f64x2_s_zero(a: BitArray) -> BitArray {
  narrow_zero(a, 64, 32, rt_num.i32_trunc_sat_f64_s)
}

/// `i32x4.trunc_sat_f64x2_u_zero` — unsigned f64x2→i32x4, upper 0.
pub fn i32x4_trunc_sat_f64x2_u_zero(a: BitArray) -> BitArray {
  narrow_zero(a, 64, 32, rt_num.i32_trunc_sat_f64_u)
}

/// `f32x4.convert_i32x4_s` — signed i32x4→f32x4.
pub fn f32x4_convert_i32x4_s(a: BitArray) -> BitArray {
  map1_lanes(a, 32, rt_num.f32_convert_i32_s)
}

/// `f32x4.convert_i32x4_u` — unsigned i32x4→f32x4.
pub fn f32x4_convert_i32x4_u(a: BitArray) -> BitArray {
  map1_lanes(a, 32, rt_num.f32_convert_i32_u)
}

/// `f32x4.demote_f64x2_zero` — f64x2→f32x4, upper lanes 0.
pub fn f32x4_demote_f64x2_zero(a: BitArray) -> BitArray {
  narrow_zero(a, 64, 32, rt_num.f32_demote_f64)
}

/// `f64x2.convert_low_i32x4_s` — low two i32x4→f64x2 (signed).
pub fn f64x2_convert_low_i32x4_s(a: BitArray) -> BitArray {
  convert_low2(a, 32, 64, rt_num.f64_convert_i32_s)
}

/// `f64x2.convert_low_i32x4_u` — low two i32x4→f64x2 (unsigned).
pub fn f64x2_convert_low_i32x4_u(a: BitArray) -> BitArray {
  convert_low2(a, 32, 64, rt_num.f64_convert_i32_u)
}

/// `f64x2.promote_low_f32x4` — low two f32x4→f64x2.
pub fn f64x2_promote_low_f32x4(a: BitArray) -> BitArray {
  convert_low2(a, 32, 64, rt_num.f64_promote_f32)
}

// ── narrow (saturating), extend, extmul, extadd_pairwise (07d) ─────────────────────────────────────────────
//
// PRIVATE infrastructure for the shape-CHANGING integer families. All funnel through the 07a
// codec (`decode_lanes`/`encode_lanes`/`signed_of`/`mask_low`/`sat_s`/`sat_u`). Three plumbing
// primitives are shared: `half` (select the low/high N/2 source lanes), `extend_lanes` (sign/zero-
// widen a lane list to the target width), and `pairwise` (fold adjacent lane pairs). The
// dispatchers `narrow`/`extend`/`extmul`/`extadd_pairwise` are each parametric over
// from-width/to-width/half/sign, so every head is a one-line application.

/// The low (`high = False`) or high (`high = True`) half of a decoded `from_w`-bit lane list — the
/// first / last `N/2` of the `N = 128 / from_w` source lanes, i.e. the operand half the low/high
/// shape-changing ops read.
fn half(lanes: List(Int), from_w: Int, high: Bool) -> List(Int) {
  let count = 128 / from_w / 2
  case high {
    True -> list.drop(lanes, count)
    False -> list.take(lanes, count)
  }
}

/// Sign- (`signed = True`) or zero-extend each `from_w`-bit lane pattern to its `to_w`-bit pattern
/// (`to_w > from_w`). Signed: interpret two's-complement then re-encode mod `2^to_w` (`0xFF`@8 →
/// `0xFFFF`@16 = −1). Unsigned: the raw non-negative pattern already IS the zero-extension, so the
/// lanes pass through unchanged.
fn extend_lanes(
  lanes: List(Int),
  from_w: Int,
  to_w: Int,
  signed: Bool,
) -> List(Int) {
  case signed {
    True -> list.map(lanes, fn(x) { mask_low(signed_of(x, from_w), to_w) })
    False -> lanes
  }
}

/// Fold a lane list into its adjacent-pair combinations `[combine(l0,l1), combine(l2,l3), …]` —
/// the shared worker behind `extadd_pairwise` (combine = widening add) and `dot` (combine = the
/// wrapping sum of two products). An odd tail element is dropped (never occurs: v128 lane counts
/// are even).
fn pairwise(lanes: List(Int), combine: fn(Int, Int) -> Int) -> List(Int) {
  case lanes {
    [x, y, ..rest] -> [combine(x, y), ..pairwise(rest, combine)]
    _ -> []
  }
}

/// Saturating narrow of two source vectors into the half-width shape: sign-interpret each `from_w`
/// lane of `a` (then `b`), saturate to the `to_w` range via `sat` (`sat_s` → signed range, `sat_u`
/// → unsigned range so a negative source → 0), and concat the `a`-lanes (low half of the result)
/// then the `b`-lanes. Shared worker behind the 4 `narrow_*` heads.
fn narrow(
  a: BitArray,
  b: BitArray,
  from_w: Int,
  to_w: Int,
  sat: fn(Int, Int) -> Int,
) -> BitArray {
  let f = fn(lane) { sat(signed_of(lane, from_w), to_w) }
  encode_lanes(
    list.append(
      list.map(decode_lanes(a, from_w), f),
      list.map(decode_lanes(b, from_w), f),
    ),
    to_w,
  )
}

/// Extend (sign/zero) one half of a source vector into the double-width shape: decode `a` into
/// `from_w` lanes, take the low or high half, widen each to `to_w`, re-encode. The shared worker
/// behind the 12 `extend_low/high_*_s/u` heads AND the extending v128 memory loads (§E).
fn extend(
  a: BitArray,
  from_w: Int,
  to_w: Int,
  high: Bool,
  signed: Bool,
) -> BitArray {
  encode_lanes(
    extend_lanes(
      half(decode_lanes(a, from_w), from_w, high),
      from_w,
      to_w,
      signed,
    ),
    to_w,
  )
}

/// Interpret a `from_w`-bit lane pattern as SIGNED (two's complement) or UNSIGNED (raw) per
/// `signed` — the per-lane numeric interpretation `extmul`/`extadd_pairwise` widen from.
fn interp_lane(x: Int, from_w: Int, signed: Bool) -> Int {
  case signed {
    True -> signed_of(x, from_w)
    False -> x
  }
}

/// Extended multiply of one half: interpret (s/u) the low or high half of both operands, multiply
/// pairwise into the double-width lane. The product of two half-width lanes fits EXACTLY in the
/// double width (`|i8·i8| < 2^15`, `|i16·i16| < 2^31`, `|i32·i32| < 2^63`), so the `mask_low`
/// only re-encodes a negative product to its unsigned pattern — no value is lost. Shared worker
/// behind the 12 `extmul_low/high_*_s/u` heads.
fn extmul(
  a: BitArray,
  b: BitArray,
  from_w: Int,
  to_w: Int,
  high: Bool,
  signed: Bool,
) -> BitArray {
  let ha =
    list.map(half(decode_lanes(a, from_w), from_w, high), fn(x) {
      interp_lane(x, from_w, signed)
    })
  let hb =
    list.map(half(decode_lanes(b, from_w), from_w, high), fn(y) {
      interp_lane(y, from_w, signed)
    })
  encode_lanes(list.map2(ha, hb, fn(x, y) { mask_low(x * y, to_w) }), to_w)
}

/// Extended pairwise add: interpret (s/u) every source lane, then sum ADJACENT pairs into the
/// double-width output lane (`out[j] = ext(a[2j]) + ext(a[2j+1])`). The sum of two half-width
/// values fits in the double width, so `mask_low` only re-encodes the sign. Shared worker behind
/// the 4 `extadd_pairwise_*` heads.
fn extadd_pairwise(
  a: BitArray,
  from_w: Int,
  to_w: Int,
  signed: Bool,
) -> BitArray {
  let lanes =
    list.map(decode_lanes(a, from_w), fn(x) { interp_lane(x, from_w, signed) })
  encode_lanes(pairwise(lanes, fn(x, y) { mask_low(x + y, to_w) }), to_w)
}

/// `i8x16.narrow_i16x8_s` — take the 8 SIGNED i16 lanes of `a` then of `b`, saturate each to the
/// signed i8 range `[-128, 127]`, giving an i8x16 (`a`-lanes low, `b`-lanes high).
pub fn i8x16_narrow_i16x8_s(a: BitArray, b: BitArray) -> BitArray {
  narrow(a, b, 16, 8, sat_s)
}

/// `i8x16.narrow_i16x8_u` — saturate each SIGNED i16 lane to the UNSIGNED u8 range `[0, 255]` (a
/// negative i16 → `0`, `> 255` → `255`), giving an i8x16 (`a`-lanes low, `b`-lanes high).
pub fn i8x16_narrow_i16x8_u(a: BitArray, b: BitArray) -> BitArray {
  narrow(a, b, 16, 8, sat_u)
}

/// `i16x8.narrow_i32x4_s` — signed saturating narrow of i32 lanes to signed i16 `[-32768, 32767]`.
pub fn i16x8_narrow_i32x4_s(a: BitArray, b: BitArray) -> BitArray {
  narrow(a, b, 32, 16, sat_s)
}

/// `i16x8.narrow_i32x4_u` — saturate each SIGNED i32 lane to unsigned u16 `[0, 65535]`.
pub fn i16x8_narrow_i32x4_u(a: BitArray, b: BitArray) -> BitArray {
  narrow(a, b, 32, 16, sat_u)
}

/// `i16x8.extend_low_i8x16_s` — sign-extend the LOW 8 i8 lanes to i16.
pub fn i16x8_extend_low_i8x16_s(a: BitArray) -> BitArray {
  extend(a, 8, 16, False, True)
}

/// `i16x8.extend_low_i8x16_u` — zero-extend the LOW 8 i8 lanes to i16.
pub fn i16x8_extend_low_i8x16_u(a: BitArray) -> BitArray {
  extend(a, 8, 16, False, False)
}

/// `i16x8.extend_high_i8x16_s` — sign-extend the HIGH 8 i8 lanes (bytes 8..15) to i16.
pub fn i16x8_extend_high_i8x16_s(a: BitArray) -> BitArray {
  extend(a, 8, 16, True, True)
}

/// `i16x8.extend_high_i8x16_u` — zero-extend the HIGH 8 i8 lanes (bytes 8..15) to i16.
pub fn i16x8_extend_high_i8x16_u(a: BitArray) -> BitArray {
  extend(a, 8, 16, True, False)
}

/// `i32x4.extend_low_i16x8_s` — sign-extend the LOW 4 i16 lanes to i32.
pub fn i32x4_extend_low_i16x8_s(a: BitArray) -> BitArray {
  extend(a, 16, 32, False, True)
}

/// `i32x4.extend_low_i16x8_u` — zero-extend the LOW 4 i16 lanes to i32.
pub fn i32x4_extend_low_i16x8_u(a: BitArray) -> BitArray {
  extend(a, 16, 32, False, False)
}

/// `i32x4.extend_high_i16x8_s` — sign-extend the HIGH 4 i16 lanes to i32.
pub fn i32x4_extend_high_i16x8_s(a: BitArray) -> BitArray {
  extend(a, 16, 32, True, True)
}

/// `i32x4.extend_high_i16x8_u` — zero-extend the HIGH 4 i16 lanes to i32.
pub fn i32x4_extend_high_i16x8_u(a: BitArray) -> BitArray {
  extend(a, 16, 32, True, False)
}

/// `i64x2.extend_low_i32x4_s` — sign-extend the LOW 2 i32 lanes to i64.
pub fn i64x2_extend_low_i32x4_s(a: BitArray) -> BitArray {
  extend(a, 32, 64, False, True)
}

/// `i64x2.extend_low_i32x4_u` — zero-extend the LOW 2 i32 lanes to i64.
pub fn i64x2_extend_low_i32x4_u(a: BitArray) -> BitArray {
  extend(a, 32, 64, False, False)
}

/// `i64x2.extend_high_i32x4_s` — sign-extend the HIGH 2 i32 lanes to i64.
pub fn i64x2_extend_high_i32x4_s(a: BitArray) -> BitArray {
  extend(a, 32, 64, True, True)
}

/// `i64x2.extend_high_i32x4_u` — zero-extend the HIGH 2 i32 lanes to i64.
pub fn i64x2_extend_high_i32x4_u(a: BitArray) -> BitArray {
  extend(a, 32, 64, True, False)
}

/// `i16x8.extmul_low_i8x16_s` — signed extended multiply of the low 8 i8 lane pairs → i16.
pub fn i16x8_extmul_low_i8x16_s(a: BitArray, b: BitArray) -> BitArray {
  extmul(a, b, 8, 16, False, True)
}

/// `i16x8.extmul_low_i8x16_u` — unsigned extended multiply of the low 8 i8 lane pairs → i16.
pub fn i16x8_extmul_low_i8x16_u(a: BitArray, b: BitArray) -> BitArray {
  extmul(a, b, 8, 16, False, False)
}

/// `i16x8.extmul_high_i8x16_s` — signed extended multiply of the high 8 i8 lane pairs → i16.
pub fn i16x8_extmul_high_i8x16_s(a: BitArray, b: BitArray) -> BitArray {
  extmul(a, b, 8, 16, True, True)
}

/// `i16x8.extmul_high_i8x16_u` — unsigned extended multiply of the high 8 i8 lane pairs → i16.
pub fn i16x8_extmul_high_i8x16_u(a: BitArray, b: BitArray) -> BitArray {
  extmul(a, b, 8, 16, True, False)
}

/// `i32x4.extmul_low_i16x8_s` — signed extended multiply of the low 4 i16 lane pairs → i32.
pub fn i32x4_extmul_low_i16x8_s(a: BitArray, b: BitArray) -> BitArray {
  extmul(a, b, 16, 32, False, True)
}

/// `i32x4.extmul_low_i16x8_u` — unsigned extended multiply of the low 4 i16 lane pairs → i32.
pub fn i32x4_extmul_low_i16x8_u(a: BitArray, b: BitArray) -> BitArray {
  extmul(a, b, 16, 32, False, False)
}

/// `i32x4.extmul_high_i16x8_s` — signed extended multiply of the high 4 i16 lane pairs → i32.
pub fn i32x4_extmul_high_i16x8_s(a: BitArray, b: BitArray) -> BitArray {
  extmul(a, b, 16, 32, True, True)
}

/// `i32x4.extmul_high_i16x8_u` — unsigned extended multiply of the high 4 i16 lane pairs → i32.
pub fn i32x4_extmul_high_i16x8_u(a: BitArray, b: BitArray) -> BitArray {
  extmul(a, b, 16, 32, True, False)
}

/// `i64x2.extmul_low_i32x4_s` — signed extended multiply of the low 2 i32 lane pairs → i64.
pub fn i64x2_extmul_low_i32x4_s(a: BitArray, b: BitArray) -> BitArray {
  extmul(a, b, 32, 64, False, True)
}

/// `i64x2.extmul_low_i32x4_u` — unsigned extended multiply of the low 2 i32 lane pairs → i64.
pub fn i64x2_extmul_low_i32x4_u(a: BitArray, b: BitArray) -> BitArray {
  extmul(a, b, 32, 64, False, False)
}

/// `i64x2.extmul_high_i32x4_s` — signed extended multiply of the high 2 i32 lane pairs → i64.
pub fn i64x2_extmul_high_i32x4_s(a: BitArray, b: BitArray) -> BitArray {
  extmul(a, b, 32, 64, True, True)
}

/// `i64x2.extmul_high_i32x4_u` — unsigned extended multiply of the high 2 i32 lane pairs → i64.
pub fn i64x2_extmul_high_i32x4_u(a: BitArray, b: BitArray) -> BitArray {
  extmul(a, b, 32, 64, True, False)
}

/// `i16x8.extadd_pairwise_i8x16_s` — sum adjacent SIGNED i8 lane pairs → 8 i16 lanes.
pub fn i16x8_extadd_pairwise_i8x16_s(a: BitArray) -> BitArray {
  extadd_pairwise(a, 8, 16, True)
}

/// `i16x8.extadd_pairwise_i8x16_u` — sum adjacent UNSIGNED i8 lane pairs → 8 i16 lanes.
pub fn i16x8_extadd_pairwise_i8x16_u(a: BitArray) -> BitArray {
  extadd_pairwise(a, 8, 16, False)
}

/// `i32x4.extadd_pairwise_i16x8_s` — sum adjacent SIGNED i16 lane pairs → 4 i32 lanes.
pub fn i32x4_extadd_pairwise_i16x8_s(a: BitArray) -> BitArray {
  extadd_pairwise(a, 16, 32, True)
}

/// `i32x4.extadd_pairwise_i16x8_u` — sum adjacent UNSIGNED i16 lane pairs → 4 i32 lanes.
pub fn i32x4_extadd_pairwise_i16x8_u(a: BitArray) -> BitArray {
  extadd_pairwise(a, 16, 32, False)
}

// ── shuffle / swizzle ─────────────────────────────────────────────

/// The byte at index `i` of a decoded byte list (`i8x16.swizzle`'s 16-element source, or
/// `i8x16.shuffle`'s 32-element `a ++ b`). `i` is guaranteed in range by the caller (shuffle
/// immediates validated `< 32`; swizzle indices filtered `< 16` before this is called), so the
/// `list.drop` head always exists; an out-of-range `i` would crash node-safe (never a WASM trap).
fn byte_at(bytes: List(Int), i: Int) -> Int {
  let assert [x, ..] = list.drop(bytes, i)
  x
}

/// `i8x16.shuffle` — 16 IMMEDIATE lane indices (each `0..31`, validated by P6-04) select bytes
/// from the 32-byte concatenation `a ++ b` (spec `shuffle`): output byte `i` = `(a ++ b)[lanes[i]]`.
/// Pure byte gather — no lane arithmetic. `[0,…,15]` yields `a`; `[16,…,31]` yields `b`.
pub fn i8x16_shuffle(a: BitArray, b: BitArray, lanes: List(Int)) -> BitArray {
  let concat = list.append(decode_lanes(a, 8), decode_lanes(b, 8))
  encode_lanes(list.map(lanes, fn(i) { byte_at(concat, i) }), 8)
}

/// `i8x16.swizzle` — dynamic byte select (spec `swizzle`): output byte `i` = `a[idx_i]` if the
/// UNSIGNED index byte `idx_i < 16`, else **`0`** (the load-bearing OOB → 0 corner — an index of
/// 16..255 produces a zero byte, never a trap). `idx` is a v128 of 16 byte indices (param `idx`, S15).
pub fn i8x16_swizzle(a: BitArray, idx: BitArray) -> BitArray {
  let bytes = decode_lanes(a, 8)
  encode_lanes(
    list.map(decode_lanes(idx, 8), fn(i) {
      case i < 16 {
        True -> byte_at(bytes, i)
        False -> 0
      }
    }),
    8,
  )
}

// ── v128 memory lane-assembly helpers (PURE; rt_mem owns the bounds check — S4) ─────────────────────────────────────────────
//
// The four PUBLIC helpers `emit_core` (P6-06) composes with the bounds-checked `rt_mem` byte-slice
// seam (which owns the OOB trap). `rt_simd` supplies only the pure value assembly — it never
// touches memory, bounds, or the trap. `pad_low` is the one genuinely-new private worker (S4);
// everything else reuses the codec / `extend` / `set_lane` / `lane_at` already proven above.

/// Zero-extend a ≤16-byte little-endian slice into a full 16-byte v128: the loaded bytes occupy the
/// LOW positions, every higher byte is `0` (the natural little-endian placement — the low value is
/// preserved, the top is zeroed). The private worker behind the extending v128 memory loads (S4 —
/// not public; `emit_core` reaches it only through `v128_load_extend`).
fn pad_low(bytes: BitArray) -> BitArray {
  let pad_bits = { 16 - bit_array.byte_size(bytes) } * 8
  <<bytes:bits, 0:size(pad_bits)>>
}

/// Assemble the `v128.load{8x8,16x4,32x2}_{s,u}` result: `bytes8` is the 8-byte memory slice
/// `rt_mem` supplied; interpret it as 8/4/2 lanes of `source_bits` (`8`/`16`/`32`) and sign- or
/// zero-extend (`signed`) each to the double width, filling the v128 (i16x8/i32x4/i64x2). Padding
/// the slice to 16 bytes then extending its LOW half reuses the `extend` driver verbatim. Pure —
/// the bounds check + trap were `rt_mem`'s, before this is ever reached.
pub fn v128_load_extend(
  bytes8: BitArray,
  source_bits: Int,
  signed: Bool,
) -> BitArray {
  extend(pad_low(bytes8), source_bits, source_bits * 2, False, signed)
}

/// Assemble the `v128.load{32,64}_zero` result: place the low `lane_bits` (`32`/`64`) little-endian
/// value from `bytes` into lane 0, zero every higher bit (spec `load_zero` — the high 96/64 bits are
/// `0`). Pure — `rt_mem` supplied `bytes` after its bounds check.
pub fn v128_load_zero(bytes: BitArray, lane_bits: Int) -> BitArray {
  let assert <<low:size(lane_bits)-little-unsigned, _:bits>> = bytes
  encode_lanes([low, ..list.repeat(0, 128 / lane_bits - 1)], lane_bits)
}

/// Assemble the `v128.load{8,16,32,64}_lane` result: return a copy of `vec` with lane `lane` (of
/// `width` = 8/16/32/64 BITS) overwritten by the raw `bits` (`bits mod 2^width`) that `rt_mem`
/// loaded. A thin alias of the lane replace over an explicit bit-width (S4).
pub fn v128_replace_lane_bits(
  vec: BitArray,
  lane: Int,
  width: Int,
  bits: Int,
) -> BitArray {
  set_lane(vec, width, lane, bits)
}

/// Extract lane `lane` of `vec` as its raw `width`-bit (8/16/32/64) pattern — the scalar
/// `emit_core` then hands to `rt_mem.store` for `v128.store{8,16,32,64}_lane` (S4). A thin alias of
/// the lane read over an explicit bit-width.
pub fn v128_extract_lane_bits(vec: BitArray, lane: Int, width: Int) -> Int {
  lane_at(vec, width, lane)
}
