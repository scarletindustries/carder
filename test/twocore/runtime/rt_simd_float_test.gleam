//// Spec-cited, differential tests for `rt_simd`'s pass-07c surface: the float lanes
//// (`f32x4`/`f64x2` arithmetic, unary, min/max/pmin/pmax, rounding, comparisons → v128 mask)
//// and the float↔int / width-changing conversions (convert / trunc_sat / demote / promote).
////
//// Assertions target the WebAssembly fixed-width SIMD spec (the `f*x*` vector operators,
//// <https://webassembly.github.io/spec/core/exec/numerics.html>, §D.11–D.14 of the unit doc),
//// NOT whatever the impl emits. Two independent oracles anchor every family:
////
////  1. **Hand-computed spec bit patterns** — exact IEEE-754 results built from Gleam `Float`
////     literals via BEAM bit-syntax (`<<x:float-size(32/64)>>`, an encoder DISTINCT from
////     `rt_num`) plus the spec's fixed special-value patterns (canonical NaN `0x7FC00000` /
////     `0x7FF8...`, ±Inf, ±0). These use NO `rt_num` call — they pin the spec answer directly.
////  2. **A flat-`List` rebuild oracle** — the per-lane scalar op (`rt_num.f*_*`, the audited
////     scalar reference this unit reuses) applied lane-by-lane and packed little-endian (D5)
////     test-side, compared byte-for-byte against the `rt_simd` head. This proves the SIMD
////     PLUMBING (decode → dispatch the right head at the right width → re-encode LE, and the
////     lane-count changes) is correct, independently of the LE packer.
////
//// Load-bearing corners asserted: f32 SINGLE-ROUNDING per lane (a value that rounds at f32 but
//// keeps precision at f64); a NaN lane through add/mul/min/max → the canonical NaN; min/max with
//// NaN → NaN while pmin/pmax return the non-forced operand VERBATIM (payload preserved, no
//// canonicalisation); ±0.0 in min/max/pmin (`min(-0,+0)=-0`, `max(-0,+0)=+0`, `pmin(+0,-0)=+0`);
//// abs/neg preserve the NaN payload; compares with NaN give the right mask; trunc_sat NaN→0 +
//// the saturation boundaries; demote/promote lane-count + rounding; convert_low uses only the
//// low 2 lanes; the `_zero` conversions force the top 2 lanes to zero.

import gleam/int
import gleam/list
import gleeunit/should
import twocore/runtime/rt_num
import twocore/runtime/rt_simd

// ───────────────────────── independent test-side codec ─────────────────────────

fn two_pow(n: Int) -> Int {
  int.bitwise_shift_left(1, n)
}

/// The all-ones `w`-bit mask (`2^w - 1`) — the "relation holds" lane value the compare masks emit.
fn ones(w: Int) -> Int {
  two_pow(w) - 1
}

/// Independent little-endian packer: `lanes` (lane 0 first), each `w` bits wide (D5). Distinct
/// from the impl's `encode_lanes` (this folds raw segments test-side).
fn pack(lanes: List(Int), w: Int) -> BitArray {
  list.fold(lanes, <<>>, fn(acc, lane) { <<acc:bits, lane:size(w)-little>> })
}

/// The raw f32 bit pattern of a Gleam `Float`, via BEAM's float encoder (NOT `rt_num`). Exact for
/// values that are f32-representable and whose value the caller has chosen to be exact.
fn f32_bits(x: Float) -> Int {
  let assert <<b:32>> = <<x:float-size(32)>>
  b
}

/// The raw f64 bit pattern of a Gleam `Float`, via BEAM's float encoder (NOT `rt_num`).
fn f64_bits(x: Float) -> Int {
  let assert <<b:64>> = <<x:float-size(64)>>
  b
}

// spec fixed patterns (§D.11/D.13) — no float literal produces these, so pin them directly.
const f32_can_nan = 0x7FC00000

const f32_pos_inf = 0x7F800000

const f32_neg_inf = 0xFF800000

const f32_neg_zero = 0x80000000

const f32_pos_zero = 0x00000000

const f64_can_nan = 0x7FF8000000000000

const f64_pos_inf = 0x7FF0000000000000

const f64_neg_inf = 0xFFF0000000000000

const f64_neg_zero = 0x8000000000000000

// ───────────────────────── rebuild-oracle drivers (per-lane rt_num, packed LE) ─────────────────────────

/// Run a shape-preserving binary float head and assert it equals the flat-`List` rebuild oracle:
/// the per-lane scalar `f` (an `rt_num` head) applied to each lane pair and packed LE test-side.
fn diff_bin(
  a: List(Int),
  b: List(Int),
  w: Int,
  head: fn(BitArray, BitArray) -> BitArray,
  f: fn(Int, Int) -> Int,
) -> Nil {
  should.equal(head(pack(a, w), pack(b, w)), pack(list.map2(a, b, f), w))
}

/// Run a shape-preserving unary float head and assert it equals the per-lane rebuild oracle.
fn diff_un(
  a: List(Int),
  w: Int,
  head: fn(BitArray) -> BitArray,
  f: fn(Int) -> Int,
) -> Nil {
  should.equal(head(pack(a, w)), pack(list.map(a, f), w))
}

/// Run a float comparison head and assert it equals the per-lane mask oracle: `all_ones(w)` where
/// the scalar `rel` (an `rt_num` compare returning `1`/`0`) is `1`, else `0`.
fn diff_cmp(
  a: List(Int),
  b: List(Int),
  w: Int,
  head: fn(BitArray, BitArray) -> BitArray,
  rel: fn(Int, Int) -> Int,
) -> Nil {
  should.equal(
    head(pack(a, w), pack(b, w)),
    pack(
      list.map2(a, b, fn(x, y) {
        case rel(x, y) {
          1 -> ones(w)
          _ -> 0
        }
      }),
      w,
    ),
  )
}

// edge-laden raw-bit fixtures (normal ±, ±Inf, ±0, canonical NaN).
const f32a = [0x3F800000, 0xC0400000, 0x7F800000, 0x00000000]

// 1.0, -3.0, +Inf, +0.0
const f32b = [0x40000000, 0x40800000, 0x3F000000, 0xFF800000]

// 2.0, 4.0, 0.5, -Inf
const f64a = [0x3FF0000000000000, 0xC008000000000000]

// 1.0, -3.0
const f64b = [0x4000000000000000, 0x3FE0000000000000]

// 2.0, 0.5

// ───────────────────────── f32x4 / f64x2 arithmetic (add/sub/mul/div) ─────────────────────────

pub fn arith_exact_test() {
  // spec D.11: exact IEEE results for representable operands (built from Float literals, no rt_num).
  let a =
    pack([f32_bits(1.0), f32_bits(3.0), f32_bits(2.0), f32_bits(10.0)], 32)
  let b = pack([f32_bits(2.0), f32_bits(1.0), f32_bits(3.0), f32_bits(4.0)], 32)
  should.equal(
    rt_simd.f32x4_add(a, b),
    pack([f32_bits(3.0), f32_bits(4.0), f32_bits(5.0), f32_bits(14.0)], 32),
  )
  should.equal(
    rt_simd.f32x4_sub(a, b),
    pack([f32_bits(-1.0), f32_bits(2.0), f32_bits(-1.0), f32_bits(6.0)], 32),
  )
  should.equal(
    rt_simd.f32x4_mul(a, b),
    pack([f32_bits(2.0), f32_bits(3.0), f32_bits(6.0), f32_bits(40.0)], 32),
  )
  should.equal(
    rt_simd.f32x4_div(a, b),
    pack(
      [f32_bits(0.5), f32_bits(3.0), f32_bits(2.0 /. 3.0), f32_bits(2.5)],
      32,
    ),
  )
  // f64x2 analogues.
  let da = pack([f64_bits(1.0), f64_bits(9.0)], 64)
  let db = pack([f64_bits(2.0), f64_bits(3.0)], 64)
  should.equal(
    rt_simd.f64x2_add(da, db),
    pack([f64_bits(3.0), f64_bits(12.0)], 64),
  )
  should.equal(
    rt_simd.f64x2_mul(da, db),
    pack([f64_bits(2.0), f64_bits(27.0)], 64),
  )
  should.equal(
    rt_simd.f64x2_div(da, db),
    pack([f64_bits(0.5), f64_bits(3.0)], 64),
  )
}

pub fn arith_special_values_test() {
  // spec D.11: x/0 → ±Inf; 0·Inf → canonical NaN; 0/0 → canonical NaN; any NaN in → canonical NaN.
  let one_negone =
    pack([f32_bits(1.0), f32_bits(-1.0), f32_bits(0.0), 0x7FC00000], 32)
  let zeros =
    pack([f32_pos_zero, f32_pos_zero, f32_pos_zero, f32_bits(1.0)], 32)
  should.equal(
    rt_simd.f32x4_div(one_negone, zeros),
    // 1/0 → +Inf ; -1/0 → -Inf ; 0/0 → NaN ; NaN/1 → canonical NaN.
    pack([f32_pos_inf, f32_neg_inf, f32_can_nan, f32_can_nan], 32),
  )
  // 0 · Inf → canonical NaN (per lane).
  should.equal(
    rt_simd.f32x4_mul(
      pack([f32_pos_zero, f32_pos_inf, f32_bits(2.0), f32_bits(3.0)], 32),
      pack([f32_pos_inf, f32_pos_zero, f32_bits(2.0), f32_bits(3.0)], 32),
    ),
    pack([f32_can_nan, f32_can_nan, f32_bits(4.0), f32_bits(9.0)], 32),
  )
  // A NaN operand (with a NON-canonical payload) is canonicalised by arithmetic (add/mul).
  should.equal(
    rt_simd.f32x4_add(
      pack([0x7FC00001, 0xFFABCDEF, f32_bits(1.0), f32_bits(1.0)], 32),
      pack([f32_bits(1.0), f32_bits(1.0), f32_bits(1.0), f32_bits(1.0)], 32),
    ),
    pack([f32_can_nan, f32_can_nan, f32_bits(2.0), f32_bits(2.0)], 32),
  )
  // f64x2: 1/0 → +Inf ; 0/0 → canonical NaN.
  should.equal(
    rt_simd.f64x2_div(
      pack([f64_bits(1.0), f64_bits(0.0)], 64),
      pack([f64_bits(0.0), f64_bits(0.0)], 64),
    ),
    pack([f64_pos_inf, f64_can_nan], 64),
  )
}

/// f32 SINGLE-ROUNDING per lane (spec §I3 / D.11): `1.0 + 2^-24` is exactly half a ULP of 1.0 in
/// f32, so ties-to-even rounds it back to `1.0`; the SAME inputs in f64 keep full precision
/// (`0x3FF0000010000000` ≠ f64 1.0). Demonstrates each f32 lane rounds at f32 precision while f64
/// lanes do not.
pub fn single_rounding_test() {
  // 2^-24 = 0x33800000 (f32) / 0x3E70000000000000 (f64).
  let f32_eps = 0x33800000
  let f64_eps = 0x3E70000000000000
  should.equal(
    rt_simd.f32x4_add(
      pack(list.repeat(f32_bits(1.0), 4), 32),
      pack(list.repeat(f32_eps, 4), 32),
    ),
    pack(list.repeat(f32_bits(1.0), 4), 32),
  )
  // f64: 1.0 + 2^-24 = 0x3FF0000010000000, strictly greater than 1.0 (no rounding away).
  should.equal(
    rt_simd.f64x2_add(
      pack(list.repeat(f64_bits(1.0), 2), 64),
      pack(list.repeat(f64_eps, 2), 64),
    ),
    pack(list.repeat(0x3FF0000010000000, 2), 64),
  )
}

pub fn arith_differential_test() {
  diff_bin(f32a, f32b, 32, rt_simd.f32x4_add, rt_num.f32_add)
  diff_bin(f32a, f32b, 32, rt_simd.f32x4_sub, rt_num.f32_sub)
  diff_bin(f32a, f32b, 32, rt_simd.f32x4_mul, rt_num.f32_mul)
  diff_bin(f32a, f32b, 32, rt_simd.f32x4_div, rt_num.f32_div)
  diff_bin(f64a, f64b, 64, rt_simd.f64x2_add, rt_num.f64_add)
  diff_bin(f64a, f64b, 64, rt_simd.f64x2_sub, rt_num.f64_sub)
  diff_bin(f64a, f64b, 64, rt_simd.f64x2_mul, rt_num.f64_mul)
  diff_bin(f64a, f64b, 64, rt_simd.f64x2_div, rt_num.f64_div)
}

// ───────────────────────── unary: neg / abs / sqrt ─────────────────────────

pub fn neg_abs_test() {
  // spec D.12: neg/abs are PURE sign-bit ops — they preserve the NaN PAYLOAD (do NOT canonicalise).
  let v = pack([f32_bits(1.0), f32_bits(-2.0), 0xFFC00001, f32_neg_zero], 32)
  should.equal(
    rt_simd.f32x4_neg(v),
    // sign flipped on every lane: -1.0, +2.0, 0x7FC00001 (payload kept!), +0.0.
    pack([f32_bits(-1.0), f32_bits(2.0), 0x7FC00001, f32_pos_zero], 32),
  )
  should.equal(
    rt_simd.f32x4_abs(v),
    // sign cleared: 1.0, 2.0, 0x7FC00001 (payload kept — NOT canonicalised), +0.0.
    pack([f32_bits(1.0), f32_bits(2.0), 0x7FC00001, f32_pos_zero], 32),
  )
  // f64x2 neg preserves the NaN payload too.
  should.equal(
    rt_simd.f64x2_abs(pack([0xFFF0000000000001, f64_bits(-5.0)], 64)),
    pack([0x7FF0000000000001, f64_bits(5.0)], 64),
  )
}

pub fn sqrt_test() {
  // spec D.12: sqrt of a perfect square is exact; of a negative/NaN → canonical NaN; +Inf → +Inf.
  should.equal(
    rt_simd.f32x4_sqrt(pack(
      [f32_bits(4.0), f32_bits(9.0), f32_bits(-1.0), f32_pos_inf],
      32,
    )),
    pack([f32_bits(2.0), f32_bits(3.0), f32_can_nan, f32_pos_inf], 32),
  )
  should.equal(
    rt_simd.f64x2_sqrt(pack([f64_bits(16.0), f64_neg_inf], 64)),
    pack([f64_bits(4.0), f64_can_nan], 64),
  )
  diff_un(f32a, 32, rt_simd.f32x4_sqrt, rt_num.f32_sqrt)
}

// ───────────────────────── rounding: ceil / floor / trunc / nearest ─────────────────────────

pub fn rounding_test() {
  // spec D.12: nearest is ties-to-even; small fractions yield the OPERAND-signed zero.
  should.equal(
    rt_simd.f32x4_nearest(pack(
      [f32_bits(2.5), f32_bits(3.5), f32_bits(0.5), f32_bits(-0.5)],
      32,
    )),
    // 2.5→2 (even), 3.5→4 (even), 0.5→+0, -0.5→-0.
    pack([f32_bits(2.0), f32_bits(4.0), f32_pos_zero, f32_neg_zero], 32),
  )
  // ceil(-0.5) = -0 ; floor(0.5) = +0 ; trunc(-0.7) = -0 ; ceil(1.1) = 2.
  should.equal(
    rt_simd.f32x4_ceil(pack(
      [f32_bits(-0.5), f32_bits(1.1), f32_bits(2.0), f32_pos_inf],
      32,
    )),
    pack([f32_neg_zero, f32_bits(2.0), f32_bits(2.0), f32_pos_inf], 32),
  )
  should.equal(
    rt_simd.f32x4_floor(pack(
      [f32_bits(0.5), f32_bits(-1.1), f32_bits(2.0), f32_can_nan],
      32,
    )),
    pack([f32_pos_zero, f32_bits(-2.0), f32_bits(2.0), f32_can_nan], 32),
  )
  should.equal(
    rt_simd.f32x4_trunc(pack(
      [f32_bits(-0.7), f32_bits(1.9), f32_bits(-1.9), f32_bits(0.2)],
      32,
    )),
    pack([f32_neg_zero, f32_bits(1.0), f32_bits(-1.0), f32_pos_zero], 32),
  )
  // f64x2 nearest ties-to-even.
  should.equal(
    rt_simd.f64x2_nearest(pack([f64_bits(2.5), f64_bits(-2.5)], 64)),
    pack([f64_bits(2.0), f64_bits(-2.0)], 64),
  )
  diff_un(f64a, 64, rt_simd.f64x2_trunc, rt_num.f64_trunc)
}

// ───────────────────────── min / max (NaN & ±0 aware) ─────────────────────────

pub fn min_max_test() {
  // spec D.13: min(-0,+0) = -0 ; max(-0,+0) = +0 ; any NaN → canonical NaN.
  should.equal(
    rt_simd.f32x4_min(
      pack([f32_neg_zero, f32_bits(1.0), f32_bits(3.0), 0x7FC00001], 32),
      pack([f32_pos_zero, f32_bits(2.0), 0x7FC00001, f32_bits(3.0)], 32),
    ),
    // -0 ; min(1,2)=1 ; NaN operand → canonical NaN ; NaN operand → canonical NaN.
    pack([f32_neg_zero, f32_bits(1.0), f32_can_nan, f32_can_nan], 32),
  )
  should.equal(
    rt_simd.f32x4_max(
      pack([f32_neg_zero, f32_bits(1.0), f32_bits(3.0), 0x7FC00001], 32),
      pack([f32_pos_zero, f32_bits(2.0), f32_bits(5.0), f32_bits(3.0)], 32),
    ),
    // +0 ; max(1,2)=2 ; max(3,5)=5 ; NaN → canonical NaN.
    pack([f32_pos_zero, f32_bits(2.0), f32_bits(5.0), f32_can_nan], 32),
  )
  // f64x2: min(-0,+0) = -0 ; max canonicalises NaN.
  should.equal(
    rt_simd.f64x2_min(
      pack([f64_neg_zero, f64_bits(7.0)], 64),
      pack([f64_bits(0.0), 0x7FF0000000000001], 64),
    ),
    pack([f64_neg_zero, f64_can_nan], 64),
  )
}

/// pmin/pmax (spec `fpmin`/`fpmax`, D.13) are the pseudo-min/max SELECT — they DIFFER from min/max
/// on NaN (return the non-forced operand VERBATIM, no canonicalisation) and are asymmetric on ±0.
pub fn pmin_pmax_test() {
  // pmin(a,b) = (b<a)?b:a. NaN makes the compare false → returns `a` verbatim.
  // lane0: pmin(NaN_payload, 1.0) → a = 0x7FC00001 (payload kept, NOT canonicalised like min).
  // lane1: pmin(1.0, NaN) → a = 1.0 (the non-NaN, since compare is false).
  // lane2: pmin(2.0, 1.0) → 1.0.  lane3: pmin(+0, -0) → a = +0 (since -0<+0 is false).
  should.equal(
    rt_simd.f32x4_pmin(
      pack([0x7FC00001, f32_bits(1.0), f32_bits(2.0), f32_pos_zero], 32),
      pack([f32_bits(1.0), 0x7FC00001, f32_bits(1.0), f32_neg_zero], 32),
    ),
    pack([0x7FC00001, f32_bits(1.0), f32_bits(1.0), f32_pos_zero], 32),
  )
  // pmax(a,b) = (a<b)?b:a.
  // lane0: pmax(NaN, 1.0) → a = NaN verbatim.  lane1: pmax(1.0, NaN) → a = 1.0.
  // lane2: pmax(2.0, 1.0) → 2.0.  lane3: pmax(-0, +0) → a = -0 (since -0<+0 is false).
  should.equal(
    rt_simd.f32x4_pmax(
      pack([0x7FC00001, f32_bits(1.0), f32_bits(2.0), f32_neg_zero], 32),
      pack([f32_bits(1.0), 0x7FC00001, f32_bits(1.0), f32_pos_zero], 32),
    ),
    pack([0x7FC00001, f32_bits(1.0), f32_bits(2.0), f32_neg_zero], 32),
  )
  // The definitive pmin≠min / pmax≠max pins on ±0: min(+0,-0)=-0 but pmin(+0,-0)=+0.
  should.equal(
    rt_simd.f32x4_pmin(
      pack(list.repeat(f32_pos_zero, 4), 32),
      pack(list.repeat(f32_neg_zero, 4), 32),
    ),
    pack(list.repeat(f32_pos_zero, 4), 32),
  )
  should.equal(
    rt_simd.f32x4_min(
      pack(list.repeat(f32_pos_zero, 4), 32),
      pack(list.repeat(f32_neg_zero, 4), 32),
    ),
    pack(list.repeat(f32_neg_zero, 4), 32),
  )
  // f64x2 pmin: NaN operand `a` returned verbatim (payload kept).
  should.equal(
    rt_simd.f64x2_pmin(
      pack([0x7FF0000000000001, f64_bits(2.0)], 64),
      pack([f64_bits(1.0), f64_bits(1.0)], 64),
    ),
    pack([0x7FF0000000000001, f64_bits(1.0)], 64),
  )
}

// ───────────────────────── comparisons → v128 mask ─────────────────────────

pub fn compare_exact_test() {
  // spec D.13/numerics: eq/lt/le/gt/ge with a NaN operand → false (all-zeros); ne → true (all-ones).
  let a = pack([f32_bits(1.0), f32_bits(2.0), f32_can_nan, f32_bits(3.0)], 32)
  let b = pack([f32_bits(1.0), f32_bits(1.0), f32_bits(1.0), f32_can_nan], 32)
  should.equal(rt_simd.f32x4_eq(a, b), pack([ones(32), 0, 0, 0], 32))
  should.equal(
    rt_simd.f32x4_ne(a, b),
    // 1≠1 false ; 2≠1 true ; NaN≠1 true (unordered) ; 3≠NaN true.
    pack([0, ones(32), ones(32), ones(32)], 32),
  )
  should.equal(
    rt_simd.f32x4_lt(a, b),
    // 1<1 false ; 2<1 false ; NaN<1 false ; 3<NaN false.
    pack([0, 0, 0, 0], 32),
  )
  should.equal(
    rt_simd.f32x4_le(a, b),
    // 1≤1 true ; 2≤1 false ; NaN false ; false.
    pack([ones(32), 0, 0, 0], 32),
  )
  should.equal(
    rt_simd.f32x4_gt(a, b),
    // 1>1 false ; 2>1 true ; NaN false ; false.
    pack([0, ones(32), 0, 0], 32),
  )
  should.equal(
    rt_simd.f32x4_ge(a, b),
    // 1≥1 true ; 2≥1 true ; NaN false ; false.
    pack([ones(32), ones(32), 0, 0], 32),
  )
  // +0 == -0 (ordered equality treats the two zeros as equal).
  should.equal(
    rt_simd.f32x4_eq(
      pack(list.repeat(f32_pos_zero, 4), 32),
      pack(list.repeat(f32_neg_zero, 4), 32),
    ),
    pack(list.repeat(ones(32), 4), 32),
  )
}

pub fn compare_differential_test() {
  diff_cmp(f32a, f32b, 32, rt_simd.f32x4_eq, rt_num.f32_eq)
  diff_cmp(f32a, f32b, 32, rt_simd.f32x4_ne, rt_num.f32_ne)
  diff_cmp(f32a, f32b, 32, rt_simd.f32x4_lt, rt_num.f32_lt)
  diff_cmp(f32a, f32b, 32, rt_simd.f32x4_le, rt_num.f32_le)
  diff_cmp(f32a, f32b, 32, rt_simd.f32x4_gt, rt_num.f32_gt)
  diff_cmp(f32a, f32b, 32, rt_simd.f32x4_ge, rt_num.f32_ge)
  diff_cmp(f64a, f64b, 64, rt_simd.f64x2_eq, rt_num.f64_eq)
  diff_cmp(f64a, f64b, 64, rt_simd.f64x2_ne, rt_num.f64_ne)
  diff_cmp(f64a, f64b, 64, rt_simd.f64x2_lt, rt_num.f64_lt)
  diff_cmp(f64a, f64b, 64, rt_simd.f64x2_le, rt_num.f64_le)
  diff_cmp(f64a, f64b, 64, rt_simd.f64x2_gt, rt_num.f64_gt)
  diff_cmp(f64a, f64b, 64, rt_simd.f64x2_ge, rt_num.f64_ge)
}

// ───────────────────────── conversions: convert (int → float) ─────────────────────────

pub fn convert_i32x4_test() {
  // spec D.14: signed i32 lanes → f32 (round to nearest ties-to-even).
  // 0→0.0 ; 1→1.0 ; -1→-1.0 ; INT_MAX(2147483647) rounds UP to 2^31 = 0x4F000000.
  should.equal(
    rt_simd.f32x4_convert_i32x4_s(pack([0, 1, 0xFFFFFFFF, 0x7FFFFFFF], 32)),
    pack(
      [f32_bits(0.0), f32_bits(1.0), f32_bits(-1.0), f32_bits(2_147_483_648.0)],
      32,
    ),
  )
  // unsigned: 0xFFFFFFFF is 4294967295 → rounds to 2^32 = 0x4F800000 (NOT -1).
  should.equal(
    rt_simd.f32x4_convert_i32x4_u(pack([0, 1, 0xFFFFFFFF, 100], 32)),
    pack(
      [f32_bits(0.0), f32_bits(1.0), f32_bits(4_294_967_296.0), f32_bits(100.0)],
      32,
    ),
  )
  diff_un(
    [0, 1, 0xFFFFFFFF, 0x80000000],
    32,
    rt_simd.f32x4_convert_i32x4_s,
    rt_num.f32_convert_i32_s,
  )
  diff_un(
    [0, 1, 0xFFFFFFFF, 0x80000000],
    32,
    rt_simd.f32x4_convert_i32x4_u,
    rt_num.f32_convert_i32_u,
  )
}

/// `convert_low` / `promote_low` widen to f64x2 and use ONLY the low 2 i32/f32 lanes (spec D.14) —
/// changing the upper 2 input lanes must not change the result.
pub fn convert_low_promote_test() {
  // low 2 signed i32 lanes 5, -7 → f64 5.0, -7.0 (upper lanes 999/111 ignored).
  let with_junk = pack([5, 0xFFFFFFF9, 999, 111], 32)
  let with_other_junk = pack([5, 0xFFFFFFF9, 123, 456], 32)
  let expect_s = pack([f64_bits(5.0), f64_bits(-7.0)], 64)
  should.equal(rt_simd.f64x2_convert_low_i32x4_s(with_junk), expect_s)
  should.equal(rt_simd.f64x2_convert_low_i32x4_s(with_other_junk), expect_s)
  // unsigned reading of 0xFFFFFFF9 = 4294967289.
  should.equal(
    rt_simd.f64x2_convert_low_i32x4_u(with_junk),
    pack([f64_bits(5.0), f64_bits(4_294_967_289.0)], 64),
  )
  // promote_low: low 2 f32 lanes 1.5, -2.5 → f64 exactly (widening never rounds).
  should.equal(
    rt_simd.f64x2_promote_low_f32x4(pack(
      [f32_bits(1.5), f32_bits(-2.5), f32_bits(9.0), f32_bits(9.0)],
      32,
    )),
    pack([f64_bits(1.5), f64_bits(-2.5)], 64),
  )
  // promote preserves ±Inf and canonicalises NaN.
  should.equal(
    rt_simd.f64x2_promote_low_f32x4(pack(
      [f32_pos_inf, f32_can_nan, f32_bits(0.0), f32_bits(0.0)],
      32,
    )),
    pack([f64_pos_inf, f64_can_nan], 64),
  )
}

// ───────────────────────── conversions: trunc_sat (float → int) ─────────────────────────

pub fn trunc_sat_f32x4_test() {
  // spec D.14: NaN→0 ; truncate toward zero ; saturate to the i32 range (never traps).
  should.equal(
    rt_simd.i32x4_trunc_sat_f32x4_s(pack(
      [f32_can_nan, f32_bits(3.9), f32_bits(-3.9), f32_bits(1.0e30)],
      32,
    )),
    // NaN→0 ; 3.9→3 ; -3.9→-3 (0xFFFFFFFD) ; 1e30 saturates to INT_MAX 0x7FFFFFFF.
    pack([0, 3, 0xFFFFFFFD, 0x7FFFFFFF], 32),
  )
  should.equal(
    rt_simd.i32x4_trunc_sat_f32x4_s(pack(
      [
        f32_bits(-1.0e30),
        f32_bits(0.0),
        f32_bits(2_147_483_648.0),
        f32_bits(-5.5),
      ],
      32,
    )),
    // -1e30 → INT_MIN 0x80000000 ; 0.0→0 ; 2^31 → INT_MAX (out of signed range) ; -5.5→-5.
    pack([0x80000000, 0, 0x7FFFFFFF, 0xFFFFFFFB], 32),
  )
  // unsigned: NaN→0 ; negative→0 ; +Inf/overflow → UINT_MAX ; 3.9→3.
  should.equal(
    rt_simd.i32x4_trunc_sat_f32x4_u(pack(
      [f32_can_nan, f32_bits(-1.0), f32_bits(1.0e30), f32_bits(3.9)],
      32,
    )),
    pack([0, 0, 0xFFFFFFFF, 3], 32),
  )
  diff_un(f32a, 32, rt_simd.i32x4_trunc_sat_f32x4_s, rt_num.i32_trunc_sat_f32_s)
  diff_un(f32a, 32, rt_simd.i32x4_trunc_sat_f32x4_u, rt_num.i32_trunc_sat_f32_u)
}

/// The `_zero` f64x2→i32x4 conversions truncate/saturate the 2 f64 lanes into i32 lanes 0,1 and
/// force lanes 2,3 to `0x00000000` (spec D.14, the `_zero` suffix).
pub fn trunc_sat_f64x2_zero_test() {
  should.equal(
    rt_simd.i32x4_trunc_sat_f64x2_s_zero(pack(
      [f64_bits(3.9), f64_bits(-3.9)],
      64,
    )),
    // lanes 0,1 = 3, -3 ; lanes 2,3 forced to 0.
    pack([3, 0xFFFFFFFD, 0, 0], 32),
  )
  // saturation still applies to the converted lanes; NaN→0.
  should.equal(
    rt_simd.i32x4_trunc_sat_f64x2_s_zero(pack(
      [f64_bits(1.0e30), f64_can_nan],
      64,
    )),
    pack([0x7FFFFFFF, 0, 0, 0], 32),
  )
  // unsigned: negative → 0 ; and the top 2 lanes are 0.
  should.equal(
    rt_simd.i32x4_trunc_sat_f64x2_u_zero(pack(
      [f64_bits(3.9), f64_bits(-1.0)],
      64,
    )),
    pack([3, 0, 0, 0], 32),
  )
}

// ───────────────────────── conversions: demote (f64 → f32) ─────────────────────────

/// `demote_f64x2_zero` narrows the 2 f64 lanes into f32 lanes 0,1 (single-rounding, may overflow to
/// ±Inf) and forces f32 lanes 2,3 to `+0.0` (spec D.14, the `_zero` suffix).
pub fn demote_test() {
  should.equal(
    rt_simd.f32x4_demote_f64x2_zero(pack([f64_bits(1.5), f64_bits(-2.5)], 64)),
    // exact-narrowing lanes 0,1 = 1.5, -2.5 ; lanes 2,3 = +0.0 (0x00000000).
    pack([f32_bits(1.5), f32_bits(-2.5), f32_pos_zero, f32_pos_zero], 32),
  )
  // demote of a value beyond f32's range overflows to ±Inf; NaN → canonical f32 NaN.
  should.equal(
    rt_simd.f32x4_demote_f64x2_zero(pack([f64_bits(1.0e300), f64_can_nan], 64)),
    pack([f32_pos_inf, f32_can_nan, f32_pos_zero, f32_pos_zero], 32),
  )
  should.equal(
    rt_simd.f32x4_demote_f64x2_zero(pack([f64_bits(-1.0e300), f64_pos_inf], 64)),
    pack([f32_neg_inf, f32_pos_inf, f32_pos_zero, f32_pos_zero], 32),
  )
  // demote SINGLE-ROUNDS: f64 (1 + 2^-24) = 0x3FF0000010000000 → f32 half-ULP tie → 1.0.
  should.equal(
    rt_simd.f32x4_demote_f64x2_zero(pack(
      [0x3FF0000010000000, f64_bits(1.0)],
      64,
    )),
    pack([f32_bits(1.0), f32_bits(1.0), f32_pos_zero, f32_pos_zero], 32),
  )
}
