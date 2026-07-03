# Unit P6-07 — `rt_simd` (the ~236 lane operations over a 16-byte binary)

> **One owner · Wave A (parallel with 02/03/04/05/06/08/09) · gated on `«IR4-FROZEN»`
> + `«RT-SIMD-SIG»` (keystone P6-01) and the `rt_mem` byte-slice seam (§E, P6-08/keystone).**
> Read [`00-overview.md`](00-overview.md) (I1–I8), [`PROVISIONAL-SURFACE.md`](PROVISIONAL-SURFACE.md)
> (§B–§E), the Phase-5 reconciliation [`../phase-5/RECONCILIATION.md`](../phase-5/RECONCILIATION.md)
> (R1/R9/R10/R11 still hold), and the template unit
> [`../phase-5/07-rt-table.md`](../phase-5/07-rt-table.md) first. You create **one new runtime
> module** — `runtime/rt_simd.gleam` — the tier-P `bif` reference implementation of the whole
> fixed-width SIMD lane-op surface: **~236 concrete function heads** over a 16-byte `BitArray`,
> **bit-exact and spec-differentially correct**, **reusing `rt_num`'s exact scalar semantics per
> lane** (07 *consumes* `rt_num`; it **never edits it**). Your load-bearing constraints: every op is
> **pure/total** (no SIMD op traps — I3/I6); float lanes are **IEEE-754 with f32 single-rounding +
> the canonical-NaN lock** (inherited from `rt_num`); integer lanes wrap **two's-complement at the
> *lane* width** (8/16/32/64, not 128); lane layout is **little-endian** (D5); the only trap on the
> whole SIMD surface is the **memory-bounds trap on a v128 load/store**, and that is **`rt_mem`'s**
> (§E) — `rt_simd` provides only the pure lane-assembly.

---

## Context

Phases 1–5 shipped the complete standardized WebAssembly surface **minus SIMD**. The numeric layer is
`rt_num` (`runtime/rt_num.gleam`): ~90 tier-P `bif` functions over **raw bit patterns** — integers as
the raw unsigned bit pattern in `[0, 2^width)`, floats as the raw IEEE-754 bit pattern in an `Int`
(D5, never a BEAM double), with two's-complement wrap, shift-count masking mod width, **f32 rounded to
single precision after every op**, the **canonical-NaN lock** (any NaN in/out → the positive canonical
NaN, a spec-permitted deterministic profile), exact overflow→±Inf, and the trapping div/rem/trunc ops
returning `Result(Int, TrapReason)`. Those functions hide behind the compact `NumOp`/`ConvOp` enums
carried by the `Num`/`Convert` IR nodes; `emit_core` maps each enum constructor to one `rt_num` head
(the binding chokepoint).

Phase 6 adds **fixed-width SIMD** — the single largest standardized WebAssembly proposal, folded into
the core spec (<https://webassembly.github.io/spec/core/>). It introduces one new value type, `v128`,
and **~236 lane instructions**: integer- and float-lane arithmetic, comparisons producing lane masks,
bitwise ops, shifts, byte shuffle & swizzle, splat / extract-lane / replace-lane, saturating narrowing,
sign/zero widening, extended multiply, pairwise extended add, dot product, boolean reductions, bitmask,
and the v128 memory load/store family. Per **I1/I2/I3**, `v128` is a **low-level 128-bit fixed-width
value represented at runtime as a 16-byte binary** (`<<_:128>>` — the BEAM has no 128-bit scalar), and
the ~236 instructions hide behind a compact `SimdOp` enum carried by a few `Expr` nodes, exactly
mirroring `NumOp`→`rt_num`. `emit_core` (P6-06) maps each `SimdOp` constructor to **one `rt_simd`
head** (this unit).

This is the analogue of P5-07 (`rt_table`), one level up: where `rt_table` grew the three table
backends into a typed reference store, **`rt_simd` is a brand-new runtime module** that decodes a
16-byte binary into lanes, applies the per-lane operation **reusing `rt_num`'s exact scalar
semantics**, and re-encodes — **faithful, not fast** (I3/I8: emulated lane-wise, no hardware SIMD, no
speed claim; a real-SIMD tier-N NIF is deferred). Because `rt_num` already solved the subtle
scalar-numerics problems (IEEE-754, NaN canonicalization, single-rounding, exact truncation, exact
overflow), the SIMD float and conversion lanes reduce to *calling `rt_num` per lane* — the correctness
payoff of I3's "reuse `rt_num`" mandate. `rt_simd` is where the ~236-way explosion is confined; the IR
and `emit_core` stay compact.

---

## Goal

Create `runtime/rt_simd.gleam` — the tier-P `bif`, `todo`-free reference implementation of the whole
SIMD lane-op surface — implementing, behind the keystone-frozen public heads (`«RT-SIMD-SIG»`):

- **Integer lanes** (`i8x16`/`i16x8`/`i32x4`/`i64x2`): `add`/`sub`/`mul` (no `i8x16.mul`),
  `add_sat_s/u` & `sub_sat_s/u` (i8/i16), `neg`/`abs`, `min_s/u`/`max_s/u` (i8/i16/i32), `avgr_u`
  (i8/i16), `shl`/`shr_s`/`shr_u` (count masked **mod the lane width**), all comparisons
  (`eq`/`ne`/`lt`/`le`/`gt`/`ge` s+u where applicable; i64x2 signed-only + `eq`/`ne`) producing a
  **per-lane all-ones / all-zeros mask**, the shape-agnostic bitwise ops
  (`not`/`and`/`or`/`xor`/`andnot`/`bitselect`), the boolean reductions (`v128.any_true`,
  `iNxM.all_true`), `iNxM.bitmask`, `i8x16.popcnt`, `splat`, `extract_lane_s/u`, `replace_lane` — each
  **two's-complement-exact at the lane width**.
- **Float lanes** (`f32x4`/`f64x2`): `add`/`sub`/`mul`/`div`/`neg`/`abs`/`sqrt`,
  `min`/`max`/`pmin`/`pmax`, `ceil`/`floor`/`trunc`/`nearest`, the six comparisons, `splat`,
  `extract_lane`, `replace_lane` — **IEEE-754-exact with f32 single-rounding**, the WASM
  `min`/`max` NaN & `-0.0` semantics, the `pmin`/`pmax` pseudo-min/max variants, and NaN
  canonicalization/propagation **inherited from `rt_num`**.
- **Conversions**: `f32x4.convert_i32x4_s/u`, `f64x2.convert_low_i32x4_s/u`,
  `i32x4.trunc_sat_f32x4_s/u`, `i32x4.trunc_sat_f64x2_s/u_zero`, `f32x4.demote_f64x2_zero`,
  `f64x2.promote_low_f32x4` — each **exact, reusing the corresponding `rt_num` scalar conversion**.
- **Shape-changing integer ops**: saturating `narrow` (i8x16←i16x8, i16x8←i32x4, s+u), `extend`
  low/high (i16x8←i8x16, i32x4←i16x8, i64x2←i32x4, s+u), `extmul` low/high (same shape triples, s+u),
  `extadd_pairwise` (i16x8←i8x16, i32x4←i16x8, s+u), `i32x4.dot_i16x8_s`, `i16x8.q15mulr_sat_s`.
- **Shuffle & swizzle**: `i8x16.shuffle` (16 immediate lane indices 0..31), `i8x16.swizzle`
  (dynamic byte indices; **OOB index → 0**).
- **The v128 memory family** — pure lane-assembly helpers for `v128.load`/`store`, the
  `load{8,16,32,64}_splat`, the extending `load{8x8,16x4,32x2}_{s,u}`, `load{32,64}_zero`, and
  `load/store{8,16,32,64}_lane` families — composed by `emit_core` (P6-06) with the
  **bounds-checked `rt_mem` byte-slice seam** (§E), which owns the trap.

Held **differentially to `wasmtime` and to an in-module `rebuild` oracle** over the whole
`simd/*.wast` corpus, property-tested for the algebraic laws the spec fixes, and **byte-identical for
non-SIMD modules** (a module with no `v128` links no `rt_simd`, so H7/I7 neutrality is automatic).

---

## Files owned

| File | Status |
|---|---|
| `src/twocore/runtime/rt_simd.gleam` | **NEW (single owner) — extended across 07a/07b/07c.** The ~236 lane heads over the 16-byte `BitArray`; the private lane decode/encode + width-parametric integer-lane helpers; the pure v128-memory lane-assembly helpers. `todo`-free at the end of each pass for that pass's heads. **Imports `rt_num`; NEVER edits it.** |
| `test/twocore/runtime/rt_simd_int_test.gleam` *(new, 07a)* | Spec-cited suite for the integer-lane surface (arithmetic/saturating/min-max/avgr/shifts/compares/bitwise/reductions/bitmask/popcnt/splat/extract/replace). |
| `test/twocore/runtime/rt_simd_float_test.gleam` *(new, 07b)* | Spec-cited suite for the float-lane + conversion surface (arith/rounding/compare/pmin-pmax + convert/trunc_sat/demote/promote), with the IEEE/NaN/`-0.0`/single-rounding corners. |
| `test/twocore/runtime/rt_simd_misc_test.gleam` *(new, 07c)* | Spec-cited suite for narrow/widen/extend/extmul/extadd_pairwise/dot/q15 + shuffle/swizzle + the v128-memory lane-assembly helpers. |
| `test/twocore/runtime/rt_simd_oracle_test.gleam` *(new, 07c)* | The `rebuild` differential: every op-family exercised through `rt_simd` and the independent flat-`list`-of-lanes oracle, asserting bit-identical 16-byte results (§verification). |

**You do NOT own** (describe the seam, do not claim — D1): `ir.gleam` (keystone P6-01 — `TV128`,
`ConstV128`, `SimdShape`, `SimdOp`, the `Simd`/`SimdShuffle`/`SimdLoad*`/`SimdStore*` `Expr` nodes; §A
pins the shapes this unit consumes), `runtime/rt_num.gleam` (**consumed, never edited**),
`runtime/rt_mem.gleam` (P6-08 — the bounds-checked `load_bytes`/`store_bytes` byte-slice seam, §E),
`backend/emit_core.gleam` (P6-06 — the `SimdOp`→`rt_simd` map + the memory composition + the D3a test),
`ir/effect.gleam` (keystone — classifies `Simd`/`SimdShuffle` **pure** and `SimdLoad*`/`SimdStore*`
**barriers**). Any shape this unit needs from the keystone is pinned in §A/§B and flagged in
Deviations / Open questions.

---

## Deliverables & freeze milestones

**Produces no freeze milestone** — this unit *consumes* `«IR4-FROZEN»` (the `SimdShape`/`SimdOp`
taxonomy + the SIMD `Expr` nodes), `«RT-SIMD-SIG»` (the keystone-frozen `rt_simd` public heads — §B —
so P6-06 emits against them while the bodies land here), and the `rt_mem` byte-slice seam
(`«MEM64-RUNTIME»`/§E). It ships:

1. **The ~236 lane-op bodies** across `07a` (integer, shape-preserving), `07b` (float + conversions),
   `07c` (shape-changing integer + shuffle/swizzle + memory assembly) — total, `todo`-free.
2. **The private lane codec** — bit-syntax decode/encode of the six lane shapes (little-endian, D5),
   and the width-parametric integer-lane helpers (`lane_mask`/`lane_signed`/`shift_count`/`all_ones`)
   for the 8- and 16-bit lane widths `rt_num` does not cover (§A, argued in Deviations).
3. **The v128-memory lane-assembly helpers** (§E) — pure `BitArray→BitArray` (or scalar↔`BitArray`),
   composed by P6-06 with the bounds-checked `rt_mem` slice ops.
4. **The `rebuild` differential + the spec-corner suites + the property suite** (§verification),
   readying the engine for `simd/*.wast` under P6-10 (fail=0, differential-vs-`wasmtime`).

---

## Depends on (freeze milestones)

- **`«IR4-FROZEN»` (P6-01)** — `SimdShape { I8x16 I16x8 I32x4 I64x2 F32x4 F64x2 }`, the `SimdOp` enum
  (the compact taxonomy `emit_core` carries), the `Simd`/`SimdShuffle`/`SimdLoad`/`SimdStore`/
  `SimdLoadLane`/`SimdStoreLane` `Expr` nodes, and the confirmation that **no new `TrapReason`** is
  added (SIMD ops are total; SIMD memory reuses `MemoryOutOfBounds`). §A confirms the exact shapes
  this unit reads.
- **`«RT-SIMD-SIG»` (P6-01)** — the keystone doc-freezes this unit's §B public heads (`todo` bodies)
  so P6-06 wires the `SimdOp`→fn-name map immediately while the bodies land here. The map **must**
  match these names.
- **`rt_num` (P1/P2, frozen & green)** — the per-lane scalar workers this unit reuses verbatim
  (§A.3): `i32_add/sub/mul`, `i64_add/sub/mul`, `i32_extend8_s`/`i32_extend16_s`,
  `i32_lt_s/le_s/gt_s/ge_s` + `i64_*`, `i32_popcnt`, the float surface
  (`f32_add/…/f32_sqrt/f32_min/f32_max/f32_ceil/…/f32_eq/…` and `f64_*`), and the conversions
  (`f32_convert_i32_s/u`, `f64_convert_i32_s/u`, `i32_trunc_sat_f32_s/u`, `i32_trunc_sat_f64_s/u`,
  `f32_demote_f64`, `f64_promote_f32`). All are stable public heads today.
- **The `rt_mem` byte-slice seam (P6-08/keystone, §E)** — `load_bytes(mem_idx, addr, offset, n)
  -> Result(BitArray, TrapReason)` and `store_bytes(mem_idx, addr, offset, bytes) -> Result(Nil,
  TrapReason)` (+ threaded twins), the no-wrap bounds check owner. `rt_simd` provides the pure
  assembly; `emit_core` composes. This seam's name/owner is flagged (Open questions #1).

---

## A. The representation — `v128` as a 16-byte binary, lanes little-endian, `rt_num` per lane

### A.1 The value

A `v128` is a **16-byte binary** (`<<_:128>>`, a Gleam `BitArray`). `ConstV128(bytes: BitArray)` holds
the exact 16 raw **little-endian** bytes (D5: the bits, never a decoded structure — so lane values,
NaN payloads, and `-0.0` are exact). This is the natural fixed-width byte container on a VM with no
128-bit scalar, and it is consistent with how linear-memory bytes are already handled — indeed a
`v128.load` is *literally* a 16-byte memory slice reinterpreted as a value (§E).

Every `rt_simd` head takes and returns `v128`s as `BitArray` and scalars as raw-bit `Int` (D5), exactly
mirroring the `rt_num` convention. **A `v128` argument is always exactly 16 bytes**; a scalar is the
raw i32/i64/f32/f64 bit pattern. `rt_simd` never constructs a `BitArray` of any other length for a
`v128` result (a `let assert <<…>>` decode enforces the 16-byte contract and would crash node-safe on
a violation — an internal-invariant failure, never a WASM trap; validation (P6-04) guarantees
well-typed inputs).

### A.2 Lane layout (little-endian, D5) — the six shapes

The spec fixes SIMD lane layout as **little-endian**: lane `i` occupies the `i`-th
lane-width-sized little-endian field of the 16 bytes, lane 0 lowest-addressed. The six standardized
shapes and their bit-syntax decode:

| shape | lanes × width | decode (Erlang bit syntax idiom) |
|---|---|---|
| `I8x16` | 16 × 8-bit | `<<l0:8, l1:8, …, l15:8>>` (byte order is layout order) |
| `I16x8` | 8 × 16-bit | `<<l0:16/little, …, l7:16/little>>` |
| `I32x4` | 4 × 32-bit | `<<l0:32/little, l1:32/little, l2:32/little, l3:32/little>>` |
| `I64x2` | 2 × 64-bit | `<<l0:64/little, l1:64/little>>` |
| `F32x4` | 4 × 32-bit | `<<l0:32/little, …, l3:32/little>>` (each `l` is the raw f32 bit pattern) |
| `F64x2` | 2 × 64-bit | `<<l0:64/little, l1:64/little>>` (each `l` is the raw f64 bit pattern) |

Each decoded integer lane is a **non-negative raw bit pattern** in `[0, 2^width)` — the same
convention as `rt_num`'s integer operands. Each decoded float lane is the **raw IEEE-754 bit pattern**
as an `Int` — the same convention as `rt_num`'s float operands, so it feeds `rt_num`'s float heads with
**no re-encoding**. Encode is the exact inverse (`<<r0:32/little, …>>`). Little-endian is load-bearing:
`i32x4.extract_lane` of a `v128.load`ed value must equal the little-endian `i32.load` at that offset,
so decode/encode **must** use `/little` on every multi-byte field. (`I8x16` needs no endianness marker —
a byte is a byte.) The private helpers are:

```gleam
/// Decode a 16-byte v128 into its 16 raw i8 lanes (little-endian; a byte is a byte), lane 0 first.
fn lanes_i8x16(v: BitArray) -> List(Int)
/// Decode into 8 raw i16 lanes / 4 raw i32 lanes / 2 raw i64 lanes (each little-endian, lane 0 first).
fn lanes_i16x8(v: BitArray) -> List(Int)
fn lanes_i32x4(v: BitArray) -> List(Int)
fn lanes_i64x2(v: BitArray) -> List(Int)
/// Re-encode a lane list (lane 0 first) of the given width into the 16-byte little-endian v128.
/// The list length × width MUST be 128; a mismatch is an internal-invariant crash (never a trap).
fn encode_lanes(lanes: List(Int), width: Int) -> BitArray
```

Float lanes reuse `lanes_i32x4`/`lanes_i64x2` + `encode_lanes(_, 32/64)` (a float lane *is* its 32/64-bit
raw pattern — identical byte layout to an integer lane of the same width; only the interpretation
differs, and that interpretation is `rt_num`'s job, not the codec's).

### A.3 The `rt_num`-reuse doctrine (I3) — what is direct, what is bridged, what is local

I3 mandates: **decode → apply the per-lane op reusing `rt_num`'s exact scalar semantics → re-encode.**
The reuse is **direct and total** for the parts of `rt_num` whose widths line up with a lane width,
and requires a small **rt_simd-local width core** only for the 8-/16-bit integer widths `rt_num` does
not implement (argued in Deviations — this is a clarification of the provisional "reuse `rt_num` per
lane"). Precisely:

- **Float lanes (F32x4/F64x2) — DIRECT reuse.** A float lane is exactly f32 (32-bit) or f64 (64-bit),
  so every float-lane op is `rt_num.f32_*` / `rt_num.f64_*` applied per lane, verbatim: `f32x4.add
  lane = rt_num.f32_add(a_i, b_i)`, `f64x2.sqrt lane = rt_num.f64_sqrt(a_i)`, and so on. This inherits
  **f32 single-rounding, the canonical-NaN lock, exact overflow→±Inf, the WASM min/max NaN & `-0.0`
  rules, and ties-to-even rounding** for free — the correctness payoff of I3. (`pmin`/`pmax` are the
  one float family `rt_num` lacks a head for; they are built *from* `rt_num.f32_lt`/`f64_lt` — §D.13.)
- **Conversions — DIRECT reuse.** Every SIMD conversion lane is f32↔i32 or f64↔i32 — widths `rt_num`
  covers: `i32x4.trunc_sat_f32x4_s lane = rt_num.i32_trunc_sat_f32_s(a_i)`, `f32x4.convert_i32x4_s
  lane = rt_num.f32_convert_i32_s(a_i)`, `f32x4.demote_f64x2_zero lane = rt_num.f32_demote_f64(a_i)`,
  `f64x2.promote_low_f32x4 lane = rt_num.f64_promote_f32(a_i)` (§D.14).
- **32-/64-bit integer lanes — DIRECT reuse.** `i32x4.add = rt_num.i32_add` per lane;
  `i64x2.mul = rt_num.i64_mul`; the i32x4 signed compares are `rt_num.i32_lt_s`/… and the i64x2 signed
  compares are `rt_num.i64_lt_s`/…; `i8x16.popcnt` per byte is `rt_num.i32_popcnt(byte)`.
- **Signed 8-/16-bit integer lanes — BRIDGED reuse.** A signed op on an i8/i16 lane is done by
  **sign-extending the lane to 32 bits with `rt_num.i32_extend8_s`/`i32_extend16_s`**, then reusing
  the 32-bit signed `rt_num` head, then masking the result back to the lane width: e.g. `i8x16.lt_s
  lane = rt_num.i32_lt_s(rt_num.i32_extend8_s(a_i), rt_num.i32_extend8_s(b_i))`; `i8x16.min_s` selects
  the operand by that comparison; `i8x16.abs` uses the sign-extended value's magnitude. This is
  genuine `rt_num` reuse (the sign-interpretation logic is `rt_num`'s), not a re-implementation.
- **Unsigned 8-/16-/32-/64-bit integer lanes — DIRECT/trivial.** An unsigned compare is a raw compare
  of the non-negative lane patterns (`rt_num.i32_lt_u` is `a < b`; identical for any width since the
  operands are non-negative). `min_u`/`max_u` select by it.
- **8-/16-bit integer add/sub/mul/neg — WIDEN-AND-MASK reuse.** `rt_num.i32_add/sub/mul` compute the
  exact sum/difference/product (the operands are small; no 32-bit wrap occurs), then `rt_simd` masks
  to the lane width (`(a+b) mod 2^8`). Because `2^8 | 2^16 | 2^32`, `((a op b) mod 2^32) mod 2^w = (a
  op b) mod 2^w`, so the widen-then-mask is exact. (For 32-/64-bit lanes the `rt_num` wrap already
  *is* the lane wrap — no mask.)
- **Shifts + the lane mask/codec — rt_simd-LOCAL.** Shift-count masking is **mod the lane width**
  (I3), but `rt_num`'s shift heads hardwire mod 32/64, so `rt_simd` masks the count itself
  (`shift_count(cnt, w) = cnt band (w-1)`) and shifts with `int.bitwise_shift_left/right` (`shr_s`
  sign-extends the lane first, arithmetic-shifts, masks). The lane mask (`all_ones(w)`), the width
  mask (`lane_mask(x, w) = x band (2^w - 1)`), and the codec (A.2) are the only genuinely-local
  primitives — a handful of one-line helpers, mirroring `rt_num`'s private `norm`/`shift_count`
  width-parametrically. **`rt_num` is never edited** (D1); these live inside `rt_simd`.

The net: the subtle numerics (IEEE-754, NaN, single-rounding, exact truncation/overflow — hundreds of
lines in `rt_num`) are reused **verbatim**; `rt_simd`'s own code is the lane plumbing (decode, dispatch
per lane, re-encode) plus a small integer width-core for the two widths below `rt_num`'s floor.

---

## B. The frozen uniform interface (`«RT-SIMD-SIG»`) — the ~236 heads

`emit_core` (P6-06) maps each `SimdOp` (and the `SimdShuffle`/memory nodes) to exactly one head below.
Naming mirrors `rt_num` and the WASM instruction: the instruction spelling with `.`→`_`
(`i8x16.narrow_i16x8_s` → `i8x16_narrow_i16x8_s`). **All heads are `pub`, total (no `Result`), and
carry a `///` contract doc** (D8). `v128` in/out is a 16-byte `BitArray`; scalars are raw-bit `Int`.
Grouped by family (the full per-op semantics are §D; the count annotation is the number of concrete
heads the family contributes):

```gleam
// ─────────────────────────── 07a — integer, shape-preserving ───────────────────────────

// arithmetic (add/sub: all 4 shapes; mul: i16x8/i32x4/i64x2 — NO i8x16.mul)          [11]
pub fn i8x16_add(a, b) i16x8_add(a, b) i32x4_add(a, b) i64x2_add(a, b) -> BitArray
pub fn i8x16_sub(a, b) i16x8_sub(a, b) i32x4_sub(a, b) i64x2_sub(a, b) -> BitArray
pub fn i16x8_mul(a, b) i32x4_mul(a, b) i64x2_mul(a, b) -> BitArray
// saturating add/sub (i8x16 + i16x8, signed + unsigned)                               [8]
pub fn i8x16_add_sat_s(a, b) i8x16_add_sat_u(a, b) i16x8_add_sat_s(a, b) i16x8_add_sat_u(a, b) -> BitArray
pub fn i8x16_sub_sat_s(a, b) i8x16_sub_sat_u(a, b) i16x8_sub_sat_s(a, b) i16x8_sub_sat_u(a, b) -> BitArray
// neg / abs (all 4 shapes)                                                            [8]
pub fn i8x16_neg(a) i16x8_neg(a) i32x4_neg(a) i64x2_neg(a) -> BitArray
pub fn i8x16_abs(a) i16x8_abs(a) i32x4_abs(a) i64x2_abs(a) -> BitArray
// min/max signed+unsigned (i8x16/i16x8/i32x4 — NOT i64x2)                             [12]
pub fn i8x16_min_s(a, b) i8x16_min_u(a, b) i8x16_max_s(a, b) i8x16_max_u(a, b) -> BitArray
pub fn i16x8_min_s(a, b) i16x8_min_u(a, b) i16x8_max_s(a, b) i16x8_max_u(a, b) -> BitArray
pub fn i32x4_min_s(a, b) i32x4_min_u(a, b) i32x4_max_s(a, b) i32x4_max_u(a, b) -> BitArray
// avgr_u (i8x16 + i16x8)                                                              [2]
pub fn i8x16_avgr_u(a, b) i16x8_avgr_u(a, b) -> BitArray
// shifts shl/shr_s/shr_u (all 4 shapes) — `count: Int` (masked mod lane width)        [12]
pub fn i8x16_shl(a: BitArray, count: Int) i8x16_shr_s(a, count) i8x16_shr_u(a, count) -> BitArray
pub fn i16x8_shl(a, count) i16x8_shr_s(a, count) i16x8_shr_u(a, count) -> BitArray
pub fn i32x4_shl(a, count) i32x4_shr_s(a, count) i32x4_shr_u(a, count) -> BitArray
pub fn i64x2_shl(a, count) i64x2_shr_s(a, count) i64x2_shr_u(a, count) -> BitArray
// comparisons → lane mask (i8x16/i16x8/i32x4: eq ne lt_s lt_u gt_s gt_u le_s le_u ge_s ge_u = 10 each;
//   i64x2: eq ne lt_s gt_s le_s ge_s = 6)                                             [36]
pub fn i8x16_eq(a, b) … i8x16_ge_u(a, b) -> BitArray   // 10
pub fn i16x8_eq(a, b) … i16x8_ge_u(a, b) -> BitArray   // 10
pub fn i32x4_eq(a, b) … i32x4_ge_u(a, b) -> BitArray   // 10
pub fn i64x2_eq(a, b) i64x2_ne(a, b) i64x2_lt_s(a, b) i64x2_gt_s(a, b) i64x2_le_s(a, b) i64x2_ge_s(a, b) -> BitArray  // 6
// v128 bitwise (shape-agnostic)                                                       [6]
pub fn v128_not(a) v128_and(a, b) v128_or(a, b) v128_xor(a, b) v128_andnot(a, b) v128_bitselect(a, b, c) -> BitArray
// boolean reductions / bitmask / popcnt                                              [10]
pub fn v128_any_true(a: BitArray) -> Int
pub fn i8x16_all_true(a) i16x8_all_true(a) i32x4_all_true(a) i64x2_all_true(a) -> Int
pub fn i8x16_bitmask(a) i16x8_bitmask(a) i32x4_bitmask(a) i64x2_bitmask(a) -> Int
pub fn i8x16_popcnt(a: BitArray) -> BitArray
// splat (int shapes; scalar → v128)                                                   [4]
pub fn i8x16_splat(x: Int) i16x8_splat(x) i32x4_splat(x) i64x2_splat(x) -> BitArray
// extract_lane (i8x16/i16x8: s+u; i32x4/i64x2: one each) + replace_lane (4)          [10]
pub fn i8x16_extract_lane_s(a: BitArray, lane: Int) -> Int   // + _u
pub fn i16x8_extract_lane_s(a, lane) -> Int                  // + _u
pub fn i32x4_extract_lane(a, lane) -> Int   pub fn i64x2_extract_lane(a, lane) -> Int
pub fn i8x16_replace_lane(a: BitArray, lane: Int, x: Int) -> BitArray   // + i16x8/i32x4/i64x2

// ─────────────────────────── 07b — float lanes + conversions ───────────────────────────

// f32x4 / f64x2 arithmetic (add sub mul div = 8) + unary (neg abs sqrt = 6)          [14]
pub fn f32x4_add(a, b) f32x4_sub(a, b) f32x4_mul(a, b) f32x4_div(a, b) -> BitArray   // + f64x2_*
pub fn f32x4_neg(a) f32x4_abs(a) f32x4_sqrt(a) -> BitArray                            // + f64x2_*
// min/max/pmin/pmax (4 × 2 shapes)                                                    [8]
pub fn f32x4_min(a, b) f32x4_max(a, b) f32x4_pmin(a, b) f32x4_pmax(a, b) -> BitArray  // + f64x2_*
// rounding ceil/floor/trunc/nearest (4 × 2 shapes)                                    [8]
pub fn f32x4_ceil(a) f32x4_floor(a) f32x4_trunc(a) f32x4_nearest(a) -> BitArray        // + f64x2_*
// comparisons → lane mask (eq ne lt gt le ge, 6 × 2 shapes)                          [12]
pub fn f32x4_eq(a, b) … f32x4_ge(a, b) -> BitArray                                     // + f64x2_*
// float splat / extract_lane / replace_lane (f32x4 + f64x2)                           [6]
pub fn f32x4_splat(x: Int) -> BitArray   pub fn f32x4_extract_lane(a, lane) -> Int
pub fn f32x4_replace_lane(a, lane, x) -> BitArray                                      // + f64x2_*
// conversions (convert 4 + trunc_sat 4 + demote 1 + promote 1)                       [10]
pub fn f32x4_convert_i32x4_s(a) f32x4_convert_i32x4_u(a) -> BitArray
pub fn f64x2_convert_low_i32x4_s(a) f64x2_convert_low_i32x4_u(a) -> BitArray
pub fn i32x4_trunc_sat_f32x4_s(a) i32x4_trunc_sat_f32x4_u(a) -> BitArray
pub fn i32x4_trunc_sat_f64x2_s_zero(a) i32x4_trunc_sat_f64x2_u_zero(a) -> BitArray
pub fn f32x4_demote_f64x2_zero(a) -> BitArray   pub fn f64x2_promote_low_f32x4(a) -> BitArray

// ─────────────────────────── 07c — shape-changing + shuffle/swizzle + memory ───────────────────────────

// narrow (saturating): i8x16←i16x8 s/u, i16x8←i32x4 s/u                               [4]
pub fn i8x16_narrow_i16x8_s(a, b) i8x16_narrow_i16x8_u(a, b) i16x8_narrow_i32x4_s(a, b) i16x8_narrow_i32x4_u(a, b) -> BitArray
// extend low/high s/u: i16x8←i8x16, i32x4←i16x8, i64x2←i32x4                          [12]
pub fn i16x8_extend_low_i8x16_s(a) … i64x2_extend_high_i32x4_u(a) -> BitArray
// extmul low/high s/u: same three shape triples                                       [12]
pub fn i16x8_extmul_low_i8x16_s(a, b) … i64x2_extmul_high_i32x4_u(a, b) -> BitArray
// extadd_pairwise s/u: i16x8←i8x16, i32x4←i16x8                                        [4]
pub fn i16x8_extadd_pairwise_i8x16_s(a) i16x8_extadd_pairwise_i8x16_u(a) i32x4_extadd_pairwise_i16x8_s(a) i32x4_extadd_pairwise_i16x8_u(a) -> BitArray
// dot + q15                                                                            [2]
pub fn i32x4_dot_i16x8_s(a, b) -> BitArray   pub fn i16x8_q15mulr_sat_s(a, b) -> BitArray
// byte shuffle / swizzle                                                               [2]
pub fn i8x16_shuffle(a: BitArray, b: BitArray, lanes: List(Int)) -> BitArray
pub fn i8x16_swizzle(a: BitArray, s: BitArray) -> BitArray
// v128-memory pure lane-assembly (§E) — the only NEW memory primitive is pad_low; the rest reuse
//   splat / extend_low / replace_lane / extract_lane over an rt_mem-supplied slice.
pub fn pad_low(bytes: BitArray) -> BitArray   // zero-extend a ≤16-byte little-endian slice to 16
```

Total ≈ **236 concrete heads** (the family counts above sum to the standardized instruction set minus
the handful of unassigned opcode slots). The exact head list is frozen by the keystone from this §B;
any addition/rename this unit finds necessary is flagged in Deviations.

---

## C. The three-pass implementation split (07a / 07b / 07c)

Like the WAT parser's 10a/10b (R15), `rt_simd` is **one doc, three sequential implementation passes**
over the single owned file — the op families are uniform within a pass, and each pass is independently
differential-tested. Each pass leaves the file `todo`-free **for its own heads** and green.

### 07a — integer, shape-preserving (the module's infra + the regular lane ops)

Lands the **private lane codec** (§A.2) and the **width-parametric integer core** (§A.3) that 07b/07c
reuse, then: `add`/`sub`/`mul`; `add_sat_s/u` & `sub_sat_s/u`; `neg`/`abs`; `min_s/u`/`max_s/u`;
`avgr_u`; `shl`/`shr_s`/`shr_u`; all integer comparisons → lane mask; `v128.not/and/or/xor/andnot/
bitselect`; `v128.any_true`, `iNxM.all_true`, `iNxM.bitmask`; `i8x16.popcnt`; `splat` (int);
`extract_lane_s/u` + `replace_lane` (int).
**Pass DoD:** `rt_simd_int_test.gleam` green (spec-cited, §D.1–D.10); `gleam build` zero warnings; the
07a heads `todo`-free; the codec proven by a round-trip test (`encode_lanes ∘ lanes_* = id`).

### 07b — float lanes + conversions

`f32x4`/`f64x2`: `add`/`sub`/`mul`/`div`; `neg`/`abs`/`sqrt`; `min`/`max`/`pmin`/`pmax`;
`ceil`/`floor`/`trunc`/`nearest`; the six comparisons → lane mask; float `splat`/`extract_lane`/
`replace_lane`; and all ten conversions (`convert`/`trunc_sat`/`demote`/`promote`). Each float/convert
lane is a **direct `rt_num` call** (§A.3); `pmin`/`pmax` are built from `rt_num.f{32,64}_lt`.
**Pass DoD:** `rt_simd_float_test.gleam` green (§D.11–D.14 — the IEEE/NaN/`-0.0`/single-rounding
corners asserted by bit pattern); 07b heads `todo`-free; zero warnings.

### 07c — shape-changing integer + shuffle/swizzle + v128 memory

`narrow` (saturating); `extend_low/high s/u`; `extmul_low/high s/u`; `extadd_pairwise s/u`;
`i32x4.dot_i16x8_s`; `i16x8.q15mulr_sat_s`; `i8x16.shuffle`; `i8x16.swizzle`; and the **pure
v128-memory lane-assembly** (`pad_low` + the reuse story of §E). This pass also owns the `rebuild`
differential (`rt_simd_oracle_test.gleam`).
**Pass DoD:** `rt_simd_misc_test.gleam` + `rt_simd_oracle_test.gleam` green (§D.15–D.20 + §E); all
heads `todo`-free (the whole module now compiles with **no `todo`**, zero warnings); the differential
green over every family.

---

## D. Per-op semantics tables (assert the spec, not the impl)

All references are to the WebAssembly core spec: vector instructions
<https://webassembly.github.io/spec/core/exec/instructions.html> (Vector Instructions), the vector
operators <https://webassembly.github.io/spec/core/exec/numerics.html> (the `i*x*`/`f*x*` operator
definitions — `iadd`, `imin_s`, `iavgr_u`, `narrow`, `extmul`, `idot`, `fmin`, `fpmin`, etc.), typing
<https://webassembly.github.io/spec/core/valid/instructions.html>, and the binary opcode table
<https://webassembly.github.io/spec/core/binary/instructions.html> (the `0xFD` prefix + the u32
sub-opcode). **The `0xFD` sub-opcode bytes are cited only for orientation; their authority is P6-03
(decode)** — `rt_simd` receives lowered IR and never sees a byte (flag to P6-03 if any differs). Below,
"lanewise" means: decode both operands into the shape's lanes, apply the scalar op to corresponding
lanes, re-encode.

### D.1 Integer arithmetic — `add` / `sub` / `mul` (opcodes 0xFD 110/113/…, 142/145/149, 174/177/181, 206/209/213)

Lanewise two's-complement wrap **at the lane width** `w` (§exec/numerics `iadd`/`isub`/`imul`):
`result_lane = (a_i op b_i) mod 2^w`. `add`/`sub` exist for all four shapes; **`mul` exists for
`i16x8`/`i32x4`/`i64x2` only — there is NO `i8x16.mul`** (validate/decode reject it; `rt_simd` has no
`i8x16_mul` head). Reuse: `rt_num.i{32,64}_{add,sub,mul}` per lane + mask to `w` (§A.3). Worked:
`i8x16.add` of lane `0xFF`(=−1) and `0x02` → `0x01` (255+2=257 mod 256). `i16x8.mul` of `0xFFFF`(=−1)
and `0xFFFF`(=−1) → `0x0001`.

### D.2 Saturating add/sub — `add_sat_s/u` / `sub_sat_s/u` (i8x16 & i16x8; 0xFD 111/112/114/115, 143/144/146/147)

Lanewise **saturating** (spec `iadd_sat_s`/`iadd_sat_u`/`isub_sat_s`/`isub_sat_u`): compute the exact
(unbounded) sum/difference, then **clamp** — signed to `[-2^(w-1), 2^(w-1)-1]`, unsigned to
`[0, 2^w-1]` — and re-encode (no wrap, no trap). Only `i8x16` and `i16x8` (not i32/i64). Worked:
`i8x16.add_sat_s(0x7F, 0x01)` = `0x7F` (127+1 clamps to 127); `i8x16.add_sat_u(0xFF, 0x01)` = `0xFF`
(255+1 clamps to 255); `i8x16.sub_sat_u(0x00, 0x01)` = `0x00` (0−1 clamps to 0); `i8x16.sub_sat_s(0x80,
0x01)` = `0x80`(=−128) (−128−1 clamps to −128).

### D.3 `neg` / `abs` (all four shapes; 0xFD 97/96, 129/128, 161/160, 193/192)

`neg`: lanewise `(0 - a_i) mod 2^w` (spec `ineg`; wraps — `neg(INT_MIN) = INT_MIN`). `abs`: lanewise
absolute value of the **signed** interpretation, then re-encode `mod 2^w` (spec `iabs`; wraps —
`abs(INT_MIN) = INT_MIN`, e.g. `i8x16.abs(0x80) = 0x80`). Reuse: `neg` via `rt_num.i{32,64}_sub(0, a)`
+ mask; `abs` via the sign-extended magnitude (`i32_extend8_s`/`i32_extend16_s`/direct) + mask.

### D.4 `min_s/u` / `max_s/u` (i8x16/i16x8/i32x4 — NOT i64x2; 0xFD 118–121, 150–153, 182–185)

Lanewise select by the signed/unsigned compare (spec `imin_s`/`imax_u`/…): `min_s = (signed a_i <
signed b_i) ? a_i : b_i`; `max`/unsigned analogous. **No i64x2 min/max** (no such instruction). Reuse:
the §A.3 signed/unsigned comparison bridge (`i32_extend8_s`/`i32_extend16_s` + `rt_num.i32_lt_s` for
8/16-bit; `rt_num.i32_lt_s`/`i32_lt_u` for 32-bit) selecting the operand lane bits. Worked:
`i8x16.min_s(0x80, 0x7F)` = `0x80` (−128 < 127); `i8x16.min_u(0x80, 0x7F)` = `0x7F` (128 > 127 unsigned →
min is 127).

### D.5 `avgr_u` (i8x16 & i16x8; 0xFD 123, 155)

Lanewise **rounding unsigned average** (spec `iavgr_u`): `result = (a_i + b_i + 1) >> 1`, computed in
full (bignum) precision so it never overflows, then re-encoded (`≤ 2^w-1`, no mask needed). Only i8/i16.
Worked: `i8x16.avgr_u(0xFF, 0xFF)` = `0xFF` ((255+255+1)/2 = 255); `i8x16.avgr_u(0x00, 0x01)` = `0x01`
((0+1+1)/2 = 1).

### D.6 Shifts — `shl` / `shr_s` / `shr_u` (all four shapes; 0xFD 107–109, 139–141, 171–173, 203–205)

The shift amount is a **scalar i32 `count`**, **masked mod the lane width** `w` (spec `ishl`/`ishr_s`/
`ishr_u` over vectors: `k = count mod w`). `shl`: `(a_i << k) mod 2^w`. `shr_u`: `a_i >> k` (logical;
`a_i` is already the non-negative pattern). `shr_s`: arithmetic — sign-extend `a_i` to signed, shift
right (floor), mask to `w`. **This is the one integer family that cannot reuse `rt_num`'s shift heads**
(they mask mod 32/64), so `rt_simd` masks the count (`count band (w-1)`) locally and shifts. Worked:
`i8x16.shl(0x01, 8)` = `0x01` (count 8 mod 8 = 0, identity — NOT zero); `i8x16.shr_s(0x80, 1)` = `0xC0`
(−128 arithmetic-shifted → −64); `i8x16.shr_u(0x80, 1)` = `0x40`.

### D.7 Comparisons → lane mask (i8x16/i16x8/i32x4: 10 each; i64x2: eq/ne/lt_s/gt_s/le_s/ge_s; 0xFD 35–64, 214–219)

Lanewise compare producing a **lane-width mask**: **all-ones** (`2^w - 1`) if the relation holds,
**all-zeros** otherwise (spec `ieq`/`ilt_s`/… over vectors — a lane result of `-1`/`0` in two's
complement). Signed variants interpret lanes as two's complement; unsigned as raw. `i64x2` has
**signed-only** ordering (`lt_s/gt_s/le_s/ge_s`) plus `eq`/`ne` — **no i64x2 unsigned compares**.
Reuse: `rt_num.i{32,64}_{eq,ne,lt_s,lt_u,…}` (+ the 8/16-bit sign-extend bridge) → `1`/`0` → expand to
`all_ones(w)`/`0`. Worked: `i8x16.eq(0x05, 0x05)` lane → `0xFF`; `i8x16.lt_s(0xFF, 0x00)` → `0xFF`
(−1 < 0); `i8x16.lt_u(0xFF, 0x00)` → `0x00` (255 < 0 is false).

### D.8 v128 bitwise — `not` / `and` / `or` / `xor` / `andnot` / `bitselect` (0xFD 77–82)

**Shape-agnostic**, over the whole 128-bit value (spec §exec vector bitwise): `not = ~a`;
`and`/`or`/`xor` elementwise; `andnot(a,b) = a AND (NOT b)`; `bitselect(a,b,c) = (a AND c) OR (b AND
(NOT c))` — bit `i` of the result is `a`'s bit where `c`'s bit is 1, else `b`'s bit. Implemented over
the raw 128-bit integer (`<<n:128>>` decode, integer bit-ops, `<<_:128>>` re-encode) — no lanes needed.
Worked: `bitselect(all-ones, all-zeros, 0xFF00…) ` = `0xFF00…` (mask picks operand a where mask=1).

### D.9 Boolean reductions / bitmask / popcnt (0xFD 83, 97+/131/163/195, 100/132/164/196, 98)

- **`v128.any_true(a) -> i32`** — `1` if **any** bit of the 128-bit value is set, else `0`
  (shape-agnostic; spec `any_true`). = `(a =/= 0) ? 1 : 0` over the 128-bit integer.
- **`iNxM.all_true(a) -> i32`** — `1` if **every lane** is nonzero, else `0` (spec `all_true`).
- **`iNxM.bitmask(a) -> i32`** — gather the **sign bit (high bit) of each lane** into the low bits of
  an i32, lane 0 → bit 0 (spec `bitmask`): `i8x16` → a 16-bit mask, `i16x8` → 8-bit, `i32x4` → 4-bit,
  `i64x2` → 2-bit. Worked: `i8x16.bitmask` of a vector whose lanes 0 and 15 have the high bit set →
  `0x8001`.
- **`i8x16.popcnt(a) -> v128`** — lanewise population count **per byte** (spec `popcnt`); reuse
  `rt_num.i32_popcnt(byte)` (byte < 256, result ≤ 8), re-encode as an i8x16. Worked: byte `0xFF` → `8`.

### D.10 Lane access — `splat` / `extract_lane` / `replace_lane`

- **`splat`** (0xFD 15–20): broadcast a scalar to every lane (spec `splat`). `i8x16.splat(x)` uses `x
  mod 2^8`; `i16x8` uses `x mod 2^16`; `i32x4` uses `x` (i32); `i64x2` uses `x` (i64); `f32x4`/`f64x2`
  use the raw float bits. All 16 bytes = the scalar repeated in little-endian lane order.
- **`extract_lane`** (0xFD 21–34): read lane `lane` as a scalar. `i8x16`/`i16x8` have **signed and
  unsigned** variants (sign- or zero-extend the sub-word lane to i32); `i32x4`→i32, `i64x2`→i64,
  `f32x4`→f32 bits, `f64x2`→f64 bits (no s/u). `lane` is a static immediate in range (P6-04 guarantees
  `0 ≤ lane < N`). Worked: `i8x16.extract_lane_s(_, k)` of lane byte `0xFF` → `0xFFFFFFFF`(=−1);
  `_u` → `0x000000FF`(=255).
- **`replace_lane`** (0xFD 23/26/28/30/32/34): return a copy of `a` with lane `lane` set to scalar `x`
  (`x` masked to the lane width for i8/i16). Pure byte-layout ops — no `rt_num`.

### D.11 Float arithmetic — `add` / `sub` / `mul` / `div` (0xFD 228–231, 240–243)

Lanewise IEEE-754, **direct `rt_num` reuse** (§A.3): `f32x4.add lane = rt_num.f32_add(a_i, b_i)`, etc.
This inherits: **f32 single-rounding after every op**; the **canonical-NaN lock** (any NaN in/out →
positive canonical NaN — spec-permitted deterministic profile, satisfies the suite's
`nan:canonical`/`nan:arithmetic` expectations); exact overflow→±Inf; `0·Inf`→NaN; `x/0`→±Inf; `0/0`,
`Inf/Inf`→NaN. `f64x2` uses `rt_num.f64_*`. Worked (bit-exact): `f32x4.div(1.0, 0.0)` lane →
`0x7F800000`(+Inf); `f32x4.mul(0.0, +Inf)` lane → `0x7FC00000`(canonical NaN).

### D.12 Float unary — `neg` / `abs` / `sqrt`; rounding `ceil`/`floor`/`trunc`/`nearest` (0xFD 224/225/227/…, 236/237/239/…, 103–106, 116/117/122/148)

Direct `rt_num` reuse per lane: `neg`/`abs` are **pure sign-bit ops** (preserve NaN payload, do NOT
canonicalize — `rt_num.f32_neg`/`f32_abs`); `sqrt` is correctly-rounded (NaN/−finite/−Inf → canonical
NaN, +Inf → +Inf, ±0 → same ±0); `ceil`/`floor`/`trunc`/`nearest` round to an integral float (NaN →
canonical; ±Inf/±0 preserved; small fractions yield the operand-signed zero, e.g. `ceil(-0.5) = -0`),
`nearest` ties-to-even. Note the opcode interleaving: `f32x4.ceil/floor/trunc/nearest` are 103–106
while `f64x2.ceil/floor` are 116/117 and `f64x2.trunc/nearest` are 122/148 (the decode authority is
P6-03; `rt_simd` sees `SimdOp`). Worked: `f32x4.nearest(2.5)` lane → `2.0`; `f32x4.abs(-NaN)` lane →
the same NaN payload with sign cleared (not canonicalized).

### D.13 Float min/max/pmin/pmax (0xFD 232–235, 244–247)

- **`min`/`max`**: the WASM scalar min/max — **direct reuse** of `rt_num.f{32,64}_min`/`_max`
  (NaN → canonical NaN; `min(+0,-0) = -0`; `max(+0,-0) = +0`).
- **`pmin`/`pmax`** (pseudo-min/max; spec `fpmin`/`fpmax`): `pmin(a,b) = (b < a) ? b : a`, `pmax(a,b) =
  (a < b) ? b : a` — a **select** by strict `<`, NOT the min/max NaN rules. Built from
  `rt_num.f{32,64}_lt` (which returns `0` for any NaN): `pmin` = `f32_lt(b,a)==1 ? b : a`, so if
  *either* operand is NaN the compare is false and `pmin` returns `a` (the first operand) **verbatim**
  (payload preserved — `pmin`/`pmax` do NOT canonicalize). Worked: `pmin(-0.0, +0.0)` → `+0.0`
  (`+0 < -0` is false → returns a = `-0.0`? note: `-0 < +0` is false in IEEE, so `pmin(-0,+0)=-0` and
  `pmin(+0,-0)=+0` — the spec's asymmetric pseudo-min; assert the exact bit pattern);
  `pmin(NaN, 1.0)` → `NaN`(the a operand); `pmin(1.0, NaN)` → `1.0`.

### D.14 Conversions — convert / trunc_sat / demote / promote (0xFD 248–255, 94, 95)

All **direct `rt_num` reuse** (§A.3), lanewise:

| SIMD op | per-lane `rt_num` reuse | note |
|---|---|---|
| `f32x4.convert_i32x4_s` / `_u` | `f32_convert_i32_s` / `_u` | 4 lanes; round-to-nearest-ties-even |
| `f64x2.convert_low_i32x4_s` / `_u` | `f64_convert_i32_s` / `_u` on the **low 2** i32 lanes | upper i32 lanes ignored |
| `i32x4.trunc_sat_f32x4_s` / `_u` | `i32_trunc_sat_f32_s` / `_u` | 4 lanes; **saturates, never traps** (NaN→0, ±Inf→INT_MIN/MAX or 0/UINT_MAX) |
| `i32x4.trunc_sat_f64x2_s_zero` / `_u_zero` | `i32_trunc_sat_f64_s` / `_u` on the **2** f64 lanes → i32 lanes 0,1; **lanes 2,3 = 0** | the `_zero` suffix |
| `f32x4.demote_f64x2_zero` | `f32_demote_f64` on the 2 f64 lanes → f32 lanes 0,1; **lanes 2,3 = +0.0** | narrowing, may overflow → ±Inf |
| `f64x2.promote_low_f32x4` | `f64_promote_f32` on the **low 2** f32 lanes | exact widening |

Worked: `i32x4.trunc_sat_f32x4_s` of a NaN lane → `0`; of a `+3.9` lane → `3`; of a `+1e30` lane →
`0x7FFFFFFF`(INT_MAX). `i32x4.trunc_sat_f64x2_u_zero` of two f64 lanes → i32 lanes 0,1 with lanes 2,3
exactly `0x00000000`.

### D.15 Narrow (saturating) — `narrow_i16x8_s/u`, `narrow_i32x4_s/u` (0xFD 101/102, 133/134)

`i8x16.narrow_i16x8_s(a, b)`: take the 8 **signed** i16 lanes of `a` then the 8 of `b` (16 total),
**saturate each to signed i8** `[-128, 127]`, produce an i8x16 (spec `narrow_s`). `_u`: saturate the
**signed** i16 value to **unsigned u8** `[0, 255]` (a negative i16 → `0`). `i16x8.narrow_i32x4_s/u`:
i32→i16 the same way. Result lane order: `a`'s lanes first (low half), then `b`'s. Reuse: sign-interpret
each lane (`i32_extend16_s`) then clamp. Worked: `i8x16.narrow_i16x8_u` of an i16 lane `0xFFFF`(=−1) →
`0x00`; of `0x00FF`(=255) → `0xFF`; of `0x0100`(=256) → `0xFF`.

### D.16 Widen / extend low/high s/u — i16x8←i8x16, i32x4←i16x8, i64x2←i32x4 (0xFD 135–138, 167–170, 199–202)

`extend_low_*_s`: take the **low** N lanes of the source, **sign-extend** each to the double-width lane,
produce the wider shape (spec `extend`); `extend_high_*` takes the **high** N lanes; `_u` zero-extends.
Reuse: the `rt_num.i32_extend8_s`/`i32_extend16_s` sign bridge (+ mask to the target width for i16;
direct for i32/i64). Worked: `i16x8.extend_low_i8x16_s` of source byte lanes 0..7 = `[0xFF,0,…]` → i16
lanes `[0xFFFF(=−1), 0, …]`; `i16x8.extend_high_i8x16_u` reads source bytes 8..15.

### D.17 Extended multiply — `extmul_low/high_*_s/u` (0xFD 156–159, 188–191, 220–223)

`i16x8.extmul_low_i8x16_s(a, b)`: for the **low** 8 i8 lanes, `sextend(a_i) * sextend(b_i)` producing an
i16 lane (spec `extmul`); `_high` uses the high 8 lanes; `_u` zero-extends. Same for i32x4←i16x8 and
i64x2←i32x4. The product of two sign-extended half-width lanes **fits exactly** in the double width (no
saturation, no wrap: `|i8·i8| ≤ 2^14 < 2^15`; `|i16·i16| < 2^31`; `|i32·i32| < 2^63`). Reuse: the
sign/zero bridge + `rt_num.i{32,64}_mul` (or a bignum multiply masked to the target width). Worked:
`i16x8.extmul_low_i8x16_s` of lanes `0x80`(=−128) and `0x80`(=−128) → `0x4000`(=16384).

### D.18 Extended pairwise add — `extadd_pairwise_*_s/u` (0xFD 124–127)

`i16x8.extadd_pairwise_i8x16_s(a)`: for each i16 output lane `j`, `sextend(a[2j]) + sextend(a[2j+1])`
(spec `extadd_pairwise`) — sum **adjacent pairs** of source lanes, widened; 16 i8 → 8 i16. `_u`
zero-extends. `i32x4.extadd_pairwise_i16x8_s/u`: 8 i16 → 4 i32. No overflow (two half-width sums fit).
Reuse: the sign/zero bridge + `rt_num.i32_add`. Worked: `i16x8.extadd_pairwise_i8x16_u` of source bytes
`[0xFF, 0xFF, 0, …]` → i16 lane 0 = `0x01FE`(=510).

### D.19 Dot product — `i32x4.dot_i16x8_s` (0xFD 186); Q15 — `i16x8.q15mulr_sat_s` (0xFD 130)

- **`dot_i16x8_s(a, b)`**: for each i32 output lane `j`, `(a[2j]·b[2j]) + (a[2j+1]·b[2j+1])` with
  **signed i16** inputs, **i32** result that **wraps** (spec `idot` — no saturation). Each product is
  exact in i32 (`|i16·i16| ≤ 2^30`); the sum of two can reach `2^31` (`(−32768)²·2`), which wraps to
  `INT_MIN`. Reuse: the i16 sign bridge for the products + `rt_num.i32_add` for the (wrapping) sum.
  Worked: `dot` of `a=[−32768,−32768,…]`, `b=[−32768,−32768,…]` → lane 0 = `0x80000000`(INT_MIN,
  from `2^30 + 2^30 = 2^31` wrapping).
- **`q15mulr_sat_s(a, b)`**: lanewise `saturate_s16((a_i · b_i + 0x4000) >> 15)` with signed i16 inputs
  (spec `q15mulr_sat_s` — fixed-point Q15 rounding multiply, saturated). The only saturating case is
  `(−32768)·(−32768)`. Reuse: the i16 sign bridge + clamp to `[-32768, 32767]`. Worked:
  `q15mulr_sat_s(0x8000, 0x8000)` → `0x7FFF` (the sole saturation).

### D.20 Byte shuffle / swizzle — `i8x16.shuffle` (0xFD 13), `i8x16.swizzle` (0xFD 14)

- **`shuffle(a, b, lanes)`**: `lanes` is 16 **immediate** indices, each `0..31` (validated by P6-04).
  Concatenate `a ++ b` into 32 bytes; output byte `i` = `concat[lanes[i]]` (spec `shuffle`). Pure byte
  gather — no `rt_num`. Worked: `lanes = [0,1,…,15]` → `a`; `lanes = [16,…,31]` → `b`.
- **`swizzle(a, s)`**: `s` is a **dynamic** v128 of byte indices; output byte `i` = `a[s_i]` if
  `s_i < 16`, else **`0`** (spec `swizzle` — **OOB index → 0**, the load-bearing corner). Worked:
  `s_i = 0x10`(=16) → output byte `0`; `s_i = 0xFF`(=255) → output byte `0`; `s_i = 0x03` → `a[3]`.

---

## E. The v128 memory family — lane assembly here, bounds check in `rt_mem`

Per I6/I2, the SIMD memory ops are the **only** trap surface on the whole SIMD path, and the trap is
`rt_mem`'s: every access is **bounds-checked → `MemoryOutOfBounds`** (no new `TrapReason`). `emit_core`
(P6-06) composes a **bounds-checked `rt_mem` byte-slice** with a **pure `rt_simd` lane-assembly
helper**; `rt_simd` owns only the pure part. The bounds rule is `rt_mem`'s existing no-wrap check —
`ea = addr + offset` (bignum) traps iff `ea + access_bytes > byte_len`, **before any partial effect**
(a store writes nothing on a trap). The per-variant `access_bytes` (the slice width) is:

| family (0xFD sub-op) | access_bytes | assembly (pure `rt_simd`) | composition |
|---|---|---|---|
| `v128.load` (0) | 16 | identity — the 16-byte slice **is** the v128 | `rt_mem.load_bytes(mem, addr, off, 16)` |
| `v128.store` (11) | 16 | identity — the v128 **is** the 16 bytes | `rt_mem.store_bytes(mem, addr, off, v)` |
| `v128.load8_splat` (7) | 1 | `i8x16_splat(byte)` | `rt_mem.load(1,…)` → byte → splat |
| `v128.load16_splat` (8) | 2 | `i16x8_splat(half)` | `rt_mem.load(2,…)` → splat |
| `v128.load32_splat` (9) | 4 | `i32x4_splat(word)` | `rt_mem.load(4,…)` → splat |
| `v128.load64_splat` (10) | 8 | `i64x2_splat(dword)` | `rt_mem.load(8,…)` → splat |
| `v128.load8x8_s`/`_u` (1/2) | 8 | `i16x8_extend_low_i8x16_{s,u}(pad_low(slice8))` | `rt_mem.load_bytes(…,8)` → pad → extend_low |
| `v128.load16x4_s`/`_u` (3/4) | 8 | `i32x4_extend_low_i16x8_{s,u}(pad_low(slice8))` | as above |
| `v128.load32x2_s`/`_u` (5/6) | 8 | `i64x2_extend_low_i32x4_{s,u}(pad_low(slice8))` | as above |
| `v128.load32_zero` (92) | 4 | `pad_low(slice4)` (high 96 bits `0`) | `rt_mem.load_bytes(…,4)` → pad |
| `v128.load64_zero` (93) | 8 | `pad_low(slice8)` (high 64 bits `0`) | `rt_mem.load_bytes(…,8)` → pad |
| `v128.load{8,16,32,64}_lane` (84–87) | N∈{1,2,4,8} | `iNxM_replace_lane(vec, lane, scalar)` | `rt_mem.load(N,…)` → replace_lane into `vec` |
| `v128.store{8,16,32,64}_lane` (88–91) | N | `iNxM_extract_lane_u(vec, lane)` → scalar | extract → `rt_mem.store(N,…)` |

**The only genuinely-new pure primitive `rt_simd` must add for memory is `pad_low`** — zero-extend a
`≤16`-byte little-endian slice into a full 16-byte v128 (high bytes `0`) — which serves both the
extending loads (composed with `extend_low`) and the `_zero` loads directly. Every other memory variant
**reuses** an existing `rt_simd` head (`splat`/`replace_lane`/`extract_lane`/`extend_low`) over a scalar
or slice that `rt_mem` supplies. So `rt_simd` gains **no bespoke "memory" logic** beyond `pad_low` — the
bounds check, the state, and the trap all stay in `rt_mem`, and `rt_simd` stays a pure value module.

**The `rt_mem` byte-slice seam (cross-unit; §Open questions #1).** `v128.load`/`store` (16 bytes) and
the extending/zero loads (8/4 bytes as a `BitArray`) need a bounds-checked **byte-slice** load/store —
the existing `rt_mem.load`/`store` return/take a scalar `Int` (≤ 8 bytes) and cannot express a 16-byte
value. `rt_mem` (P6-08) therefore exposes:

```gleam
/// Bounds-checked little-endian byte-slice load: Ok(<<n bytes>>) if ea + n <= byte_len, else
/// Error(MemoryOutOfBounds). (Cell + `_at` + threaded `t_*` twins, index-0 byte-identical.)
pub fn load_bytes(mem_idx: Int, addr: Int, offset: Int, n: Int) -> Result(BitArray, TrapReason)
/// Bounds-checked byte-slice store: writes `bytes` little-endian at ea; Ok(Nil) or trap-before-write.
pub fn store_bytes(mem_idx: Int, addr: Int, offset: Int, bytes: BitArray) -> Result(Nil, TrapReason)
```

`rt_simd` **consumes** these via `emit_core`'s composition (it does not import `rt_mem` directly — the
composition is emitted). The splat/lane variants may instead reuse the existing scalar `rt_mem.load`/
`store` (P6-06's choice); either way the trap boundary is `rt_mem`. This seam's exact home (P6-08 vs a
keystone freeze of the head) is Open question #1.

---

## F. Bit-syntax decode/encode (little-endian, D5) — the codec contract

The codec (§A.2) is the single source of the little-endian layout, and every op goes through it, so
endianness cannot drift op-to-op. Contract:

- **Decode** reads lane 0 from the **lowest** bytes: `let assert <<l0:32/little, l1:32/little,
  l2:32/little, l3:32/little>> = v` for `I32x4`. The `let assert` enforces the 16-byte width invariant
  (a non-16-byte `v128` is an internal-invariant crash — node-safe, never a WASM trap; validation
  guarantees it cannot happen).
- **Encode** is the exact inverse: `<<l0:32/little, …>>`, lane 0 lowest. `encode_lanes(lanes, w)`
  folds a lane list into the binary; a `length(lanes) * w /= 128` is an internal-invariant crash.
- **Float lanes share the integer codec** at the same width (a float lane *is* its raw bit pattern —
  identical bytes to an integer lane; only `rt_num`'s interpretation differs). So there is **one**
  32-bit codec and **one** 64-bit codec, used by both `i*x*` and `f*x*` of that width.
- **`i8x16` needs no endianness marker** — a byte is a byte; `<<l0:8, …, l15:8>>` is layout order.
- **Round-trip law (tested):** `encode_lanes(lanes_i32x4(v), 32) == v` for every 16-byte `v`, and
  likewise per shape — the codec is a bijection, asserted in 07a.

Little-endianness is **observable and load-bearing**: `i32x4.extract_lane(v128.load(p), 0)` must equal
`i32.load(p)` (both little-endian), and `v128.store` then `i32.load` at successive offsets must read
back lane 0, 1, 2, 3 in ascending address order. The differential (§verification) and the
`simd/simd_lane.wast` / `simd_load*.wast` files pin this.

---

## G. TrapReason mapping (no new reason; SIMD ops are total)

| op class | traps? | `TrapReason` | note |
|---|---|---|---|
| every pure lane op (§D) | **no** | — | SIMD arithmetic/compare/shift/narrow/… are **total** (I3: saturation replaces overflow-trap; no SIMD div-trap) |
| `v128.load*` / `store*` OOB | **yes** | `MemoryOutOfBounds` | `rt_mem`'s bounds check (§E); "out of bounds memory access"; **trap-before-write** |

No new `TrapReason` (confirmed by I1/I6 and the keystone). `rt_simd` heads **never return `Result`** —
they cannot trap. The only `Result` on the SIMD path is `rt_mem.load_bytes`/`store_bytes`, and that is
`rt_mem`'s existing `Result(_, MemoryOutOfBounds)` shape, `case`d-and-raised by `emit_core` exactly as
every other memory op. (`spec_trap_message(MemoryOutOfBounds) == "out of bounds memory access"` —
frozen in `rt_trap.gleam`; the `simd/*.wast` `assert_trap` strings match it.)

---

## Effect / soundness / security note

- **SIMD ops are pure/total (I3/I6).** Every `rt_simd` head is a pure function of its `BitArray`/`Int`
  arguments — no state, no trap, no divergence. `ir/effect.gleam` (keystone) classifies `Simd`/
  `SimdShuffle` **`Pure`** (they participate in const-fold/DCE/CSE like `Num`), and `SimdLoad*`/
  `SimdStore*` **barriers** (they touch mutable memory state through `rt_mem`). A SIMD-arithmetic bug's
  worst case is a **wrong result or a node-safe crash — never a host escape**: a `v128` is an opaque
  16-byte value that cannot address memory except through the checked `rt_mem` seam (§E).
- **Fail-closed bounds on SIMD memory (I6).** Every v128 load/store is bounds-checked → trap
  **before any partial effect**, via `rt_mem`'s existing no-wrap check (a store writes nothing on a
  trap; a lane load's `replace_lane` composes only *after* the checked scalar load succeeds). The worst
  case of a bounds bug is a wrong/missing trap or a node-safe crash — never an out-of-bounds host read.
- **No ambient authority (D3a), untouched.** `rt_simd` builds no atoms, does no `apply/3`, and calls no
  module derived from data — it is arithmetic over binaries. The memory composition emits
  `call 'twocore@runtime@rt_mem':'load_bytes'/…` (a build-fixed name), never a data-derived target.
- **Raw bits (D5) / canonical-NaN determinism.** Lanes are raw bit patterns; float lanes inherit
  `rt_num`'s **canonical-NaN lock**, so a NaN-producing SIMD float op yields the positive canonical NaN
  deterministically (a spec-permitted profile; the harness judges NaN lanes by the `nan:canonical`/
  `nan:arithmetic` pattern, not bit-equality — cross-unit flag to P6-10/P6-11).
- **Conformance-neutral by default (I7/H7).** A module with **no `v128`** references **no `SimdOp`** and
  links **no `rt_simd`** — so it decodes/validates/lowers/emits **byte-identically** to Phase-5. This is
  automatic (there is no Phase-5 `rt_simd` to differ from), not a constraint this unit must engineer;
  the unit only has to avoid perturbing `rt_num` (which it never edits — D1) and the shared codec.
- **Tier-P `bif`, runs anywhere (I3/I8).** `rt_simd` is pure Gleam over `BitArray`/`Int` — no OTP
  native state, no NIF; it cannot crash the node and runs on every BEAM. This is the **faithful, not
  fast** posture (no vectorization, no speed claim); a hardware-SIMD tier-N NIF is deferred, and the
  interface (pure lane heads) admits it later without a rewrite.

---

## Verification — Definition of Done (D8: assert the spec, not the impl)

Write the spec-cited suites (cite exec/instructions.html Vector Instructions, exec/numerics.html vector
operators, binary/instructions.html for opcode orientation, and the `simd/*.wast` corpus) — **not**
whatever the code emits. Every float expectation is asserted **by exact bit pattern** (as
`rt_num_floats_test.gleam` does), since `-0.0 ==. +0.0` and NaN `/=. ` NaN would mask real bugs. The
plan, mirroring the P5-07 shape:

1. **Integer arithmetic + wrap (07a).** `add`/`sub`/`mul` per shape at the lane-width wrap boundary
   (`i8x16.add(0xFF,0x02)=0x01`; `i16x8.mul(0xFFFF,0xFFFF)=0x0001`); assert **no `i8x16_mul` head
   exists** (compile-level / grep).
2. **Saturating (07a).** `add_sat_s/u`, `sub_sat_s/u` at both saturation edges and just inside them
   (`add_sat_s(0x7F,1)=0x7F`; `add_sat_u(0xFF,1)=0xFF`; `sub_sat_u(0,1)=0`; `sub_sat_s(0x80,1)=0x80`),
   for i8x16 and i16x8; assert the ops **do not exist** for i32x4/i64x2.
3. **neg/abs wrap (07a).** `abs(INT_MIN)=INT_MIN`, `neg(INT_MIN)=INT_MIN` per shape.
4. **min/max s/u (07a).** The signed-vs-unsigned split (`min_s(0x80,0x7F)=0x80` vs
   `min_u(0x80,0x7F)=0x7F`) for i8/i16/i32; assert **no i64x2 min/max head**.
5. **avgr_u rounding (07a).** `avgr_u(0xFF,0xFF)=0xFF`, `avgr_u(0,1)=1` (rounds up), i8x16 + i16x8.
6. **Shifts, count masked mod lane width (07a).** `i8x16.shl(x,8) == x` (count 8 mod 8 = 0, **not**
   zero); `shr_s` sign-fills (`0x80>>1=0xC0`); `shr_u` zero-fills (`0x80>>1=0x40`); repeat per shape at
   its width boundary (i32x4 shift by 32 = identity, by 33 = shift by 1).
7. **Comparisons → mask (07a).** Each relation yields `all_ones`/`0` per lane; the signed/unsigned
   split (`i8x16.lt_s(0xFF,0)=0xFF` vs `lt_u(0xFF,0)=0`); assert i64x2 has **eq/ne + signed ordering
   only** (no `i64x2_lt_u` head).
8. **Bitwise + bitselect (07a).** `andnot`, and the `bitselect(a,b,c)=(a&c)|(b&~c)` truth table on a
   crafted mask.
9. **Reductions/bitmask/popcnt (07a).** `any_true`/`all_true` on all-zero / one-lane-set / all-set
   vectors; `bitmask` gathers the correct sign bits (lane 0 → bit 0); `i8x16.popcnt(0xFF byte)=8`.
10. **Lane access (07a).** `splat` broadcasts and truncates the scalar to the lane width;
    `extract_lane_s`/`_u` sign/zero-extend correctly (`i8x16.extract_lane_s` of `0xFF` = `-1` bits,
    `_u` = `255`); `replace_lane` changes exactly one lane; **little-endian lane index** proven
    (`splat` then `extract` of each index round-trips).
11. **Float arithmetic — IEEE/NaN/single-rounding (07b).** `f32x4.add/sub/mul/div` bit-exact incl.
    `x/0 → ±Inf`, `0·Inf → canonical NaN`, `0/0 → canonical NaN`, overflow → signed Inf, and the
    **f32 single-rounding** corner (a value that rounds differently at single vs double precision);
    same for f64x2. Assert **every lane** independently (a bug that corrupts lane 3 only must fail).
12. **Float unary + rounding (07b).** `sqrt` (−1 → canonical NaN, +Inf → +Inf, ±0 → same ±0);
    `abs`/`neg` **preserve the NaN payload** (do NOT canonicalize) and only touch the sign bit;
    `ceil(-0.5)=-0`, `floor(0.5)=+0`, `nearest(2.5)=2` / `nearest(3.5)=4` (ties-to-even), per lane.
13. **min/max/pmin/pmax (07b).** `min(+0,-0)=-0`, `max(+0,-0)=+0`, NaN → canonical for min/max; and the
    **pseudo** semantics for pmin/pmax: `pmin(-0,+0)` vs `pmin(+0,-0)` (asymmetric — assert the exact
    bit), `pmin(NaN,1)=NaN`, `pmin(1,NaN)=1` (payload preserved, not canonicalized).
14. **Conversions (07b).** `trunc_sat_*` saturates (NaN→0, +Inf→INT_MAX, −Inf→INT_MIN/0) and **never
    traps**; the `_zero` variants zero lanes 2,3 exactly; `demote_f64x2_zero` zeros the upper two f32
    lanes and can overflow → ±Inf; `promote_low_f32x4` is exact; `convert_low` uses only the low 2 i32
    lanes.
15. **Narrow (07c).** `narrow_i16x8_u` maps a negative i16 → `0` and `>255` → `255`; `narrow_*_s` clamps
    to the signed range; result lane order is `a` then `b`.
16. **Extend/extmul/extadd (07c).** `extend_low` vs `extend_high` read the correct source half; `s` vs
    `u` sign/zero-extend; `extmul` products fit exactly (`(-128)·(-128)=16384` as i16); `extadd_pairwise`
    sums the correct adjacent pairs.
17. **dot + q15 (07c).** `dot` of all-`-32768` lanes wraps to `INT_MIN` (the sole overflow);
    `q15mulr_sat_s(0x8000,0x8000)=0x7FFF` (the sole saturation) and a non-saturating case matches
    `(a·b+0x4000)>>15`.
18. **shuffle/swizzle (07c).** `shuffle` selects from `a++b` by the 16 immediates (identity, swap,
    interleave); `swizzle` returns `0` for any index `≥16` (the OOB-→0 corner) and `a[i]` otherwise.
19. **v128 memory assembly (07c/§E).** `pad_low` zero-extends correctly; the extending-load assembly
    (`extend_low(pad_low(slice8))`) widens the right 8 bytes with the right sign; `load*_zero` zeros the
    high lanes; `load/store*_lane` compose `replace_lane`/`extract_lane` with the right lane; and (with
    a stub/real `rt_mem`) an **OOB v128.load traps `MemoryOutOfBounds` before any effect**, an in-bounds
    one reads the little-endian 16 bytes, and a store writes them back (round-trip through memory).
20. **Little-endian codec round-trip (07a, reused).** `encode_lanes ∘ lanes_* == id` per shape, and
    `i32x4.extract_lane(v128.load(p), k)` equals the little-endian `i32.load(p + 4k)` (the layout is
    observable — §F).
21. **The `rebuild` differential (07c — the headline).** An independent **flat-`List(Int)`-of-lanes
    oracle** (`OSimd`: decode to a list, apply the op with the plainest possible per-lane arithmetic,
    re-encode) is held to explicit spec-corner vectors **and** differentially driven against `rt_simd`
    across **every op family** on a fixed pseudo-random corpus of vectors (incl. the NaN/±0/INT_MIN/
    saturation/OOB-swizzle-index seeds), asserting **bit-identical 16-byte results** (and identical
    scalar results for extract/bitmask/any_true/all_true). This is `rt_simd`'s analogue of `rt_mem`'s
    `paged`-vs-`rebuild` oracle — a second implementation makes a transposition/endianness/off-by-one
    bug fail loudly.
22. **Property tests (spec laws).** `gleeunit`-style randomized checks of the algebraic laws the spec
    fixes: `add` commutative & `add(a, neg(a)) == 0` per lane; `and`/`or` idempotent, `xor(a,a)=0`,
    `not(not a)=a`, `bitselect(a,b,all-ones)=a` / `bitselect(a,b,0)=b`; `extract_lane(splat(x),k)=x`;
    `min_s(a,b)=min_s(b,a)`; `narrow`∘`extend` identities on in-range values; `shl(a,k)` then
    `shr_u(_,k)` clears the low bits. Properties assert **spec identities**, never impl internals.
23. **D3a (grep-backed).** `rt_simd.gleam` contains **no** `apply`, no `erlang:binary_to_atom`, no
    module-name construction — only binary/integer arithmetic and `rt_num` calls (grep-asserted in the
    test module, mirroring the P5 backend D3a check).
24. **Conformance readiness (wired by P6-10, proven here).** `rt_simd` is the engine under the
    `simd/*.wast` corpus — the arithmetic files (`simd_i*_arith*.wast`, `simd_f*_arith.wast`), the
    conversion/lane/load/store files (`simd_conversions.wast`, `simd_lane.wast`, `simd_load*.wast`,
    `simd_store*.wast`), `simd_bitwise.wast`, `simd_boolean.wast`, `simd_bit_shift.wast`,
    `simd_int_to_int_extend.wast`, `simd_extmul*.wast`, `simd_extadd*.wast`, `simd_dot_product.wast`,
    `simd_q15mulr_sat_s.wast`, `simd_i8x16_cmp.wast` … — **fail=0**, **differentially checked against
    `wasmtime`** (R16: greenness is measured, never promised; NaN lanes judged by the
    `nan:canonical`/`nan:arithmetic` pattern).

**Gate:** `gleam format --check src test` clean; `gleam build` **zero warnings** (no lingering `todo`
anywhere in `rt_simd.gleam`); `gleam test` stays green (the existing 1212 + your new suites); every new
public function/type carries a `///` contract doc (D8). **Done = the three per-pass suites + the
differential + the property suite + the cited `simd/*.wast` files pass**, never "it compiles."

---

## What this unit leaves

- **P6-06 (emit_core):** maps each `SimdOp` constructor to one `rt_simd` head (the binding chokepoint,
  exactly like `NumOp`→`rt_num`), lowers `SimdShuffle` to `i8x16_shuffle(A, B, [immediates])`, and
  **composes the SIMD memory family** — a bounds-checked `rt_mem.load_bytes`/`store_bytes` (or scalar
  `rt_mem.load`/`store`) `case`d-and-raised on `MemoryOutOfBounds`, then the pure `rt_simd` assembly
  helper (§E). It also extends the D3a security test to cover the SIMD seam (no ambient authority in the
  emitted memory composition).
- **P6-01 (keystone):** freezes §B (`«RT-SIMD-SIG»`, `todo` bodies) so 06 emits immediately; freezes
  the `SimdShape`/`SimdOp` taxonomy and the SIMD `Expr` nodes this unit consumes; classifies the SIMD
  nodes in `ir/effect.gleam` (pure lanewise / memory barriers); confirms **no new `TrapReason`**.
- **P6-08 (rt_mem):** owns the byte-slice seam `load_bytes`/`store_bytes` (§E) that the v128
  load/store family routes through, and the memory64 i64-address plumbing (orthogonal to this unit — a
  SIMD load on a 64-bit memory just threads the wider address through the same `rt_mem` seam).
- **P6-10 (conformance):** adds the `simd/*.wast` corpus to the allowlist, runs the `wast2json`
  convertibility audit at the pin (R16), judges NaN result lanes by the `nan:canonical`/`nan:arithmetic`
  pattern, reports the measured skip-count drop, and proves fail=0 differentially vs `wasmtime`.

---

## Deviations from the provisional surface (ARGUED)

1. **The `rt_num`-reuse claim is refined per width, not literal for all lanes.** The provisional §E
   says "reuse `rt_num` per lane". This is **directly true** for float lanes and all conversions
   (widths 32/64 line up with f32/f64 — the big correctness win) and for 32-/64-bit integer lanes, and
   is **bridged** for signed 8-/16-bit lanes (via `rt_num.i32_extend8_s`/`i32_extend16_s` +
   `rt_num.i32_lt_s`/…), but `rt_num` **only implements the 32- and 64-bit integer widths**, so the
   8-/16-bit integer *arithmetic* (add/sub/mul via widen-and-mask), the **shift-count masking mod the
   lane width** (`rt_num`'s shifts hardwire mod 32/64), and the lane codec require a small
   **`rt_simd`-local width core** (a few one-line helpers: `lane_mask`, `all_ones`, `shift_count`,
   `lanes_*`/`encode_lanes`). This is a *clarification*, not a contradiction — `rt_num` is still
   consumed and never edited (D1); the local core is the minimal plumbing `rt_num`'s 32/64-only floor
   leaves. Flagged so reconciliation reads "reuse `rt_num`" as "reuse where the widths line up; local
   two's-complement plumbing for the sub-32-bit widths."
2. **The `SimdOp` taxonomy must add the saturating add/sub family.** The provisional §C enumerates
   `SAdd`/`SSub`/`SMul`/`SAvgrU` but **omits `add_sat_s/u` and `sub_sat_s/u`** (8 real instructions,
   i8x16 + i16x8). `rt_simd` needs the four heads `i8x16_add_sat_s/u` … `i16x8_sub_sat_s/u`; the
   keystone's `SimdOp` must carry the corresponding constructors (`SAddSatS/SAddSatU/SSubSatS/SSubSatU`
   over the two applicable shapes, or four shape-tagged variants). Flagged for the keystone/03/06 to
   pin, so the enum and the `rt_simd` heads agree.
3. **The v128-memory family reuses existing heads + one new `pad_low`, rather than bespoke memory
   ops.** The provisional §D sketches dedicated `SimdLoad`/`SimdLoadLane`/… `Expr` nodes (kept — that
   is 01/03/06's node-shape decision, unchanged here) but leaves the *runtime* helper surface open.
   This unit specifies that `rt_simd` adds **only `pad_low`** and reuses `splat`/`replace_lane`/
   `extract_lane`/`extend_low` for every memory variant (§E), keeping `rt_simd` a pure value module and
   the bounds check + trap entirely in `rt_mem`. This narrows the "rt_simd provides the pure
   lane-assembly helpers" line to a concrete, minimal helper set and surfaces the **`rt_mem.load_bytes`/
   `store_bytes` byte-slice seam** as the one genuinely-new cross-unit dependency (Open question #1).
4. **Three passes split by *shape-change*, not by a flat op count.** The provisional/overview split is
   "07a int / 07b float+convert / 07c misc+mem+shuffle". This unit pins the boundary precisely:
   **07a = shape-preserving integer** (incl. popcnt/avgr/saturating), **07b = float + numeric
   conversions**, **07c = shape-*changing* integer** (narrow/extend/extmul/extadd/dot/q15) **+
   shuffle/swizzle + memory**. This keeps each pass's ops uniform (a single lane-mapping idiom per
   pass) and puts the module infra (codec + integer width core) in 07a where 07b/07c inherit it — a
   defensible refinement of the same three-way split, not a new one.

---

## Open questions (for the planner / cross-unit sync)

1. **The `rt_mem` byte-slice seam owner + name (§E).** `v128.load`/`store` (16 bytes) and the
   extending/zero loads need a bounds-checked `load_bytes(mem_idx, addr, offset, n) ->
   Result(BitArray, TrapReason)` / `store_bytes(…)` (+ `_at`/threaded twins) — a **new `rt_mem`
   head**, since the existing scalar `load`/`store` cap at 8 bytes. Recommend **P6-08 owns it** (it is
   an `rt_mem` extension, and 08 already owns the i64-address plumbing these must thread), with the
   keystone freezing the head in `«MEM64-RUNTIME»`/`«RT-SIMD-SIG»` so P6-06 can emit the composition
   and this unit's tests can drive it. Confirm the name and whether the splat/lane variants reuse the
   scalar `rt_mem.load`/`store` or also go through `load_bytes` (06's emit choice).
2. **The saturating-add/sub `SimdOp` constructors (Deviation #2).** Please add `add_sat_s/u`,
   `sub_sat_s/u` to the frozen `SimdOp` (they are core instructions the provisional taxonomy dropped),
   over the i8x16/i16x8 shapes only, so decode (03)/emit (06)/rt_simd (07) agree.
3. **NaN result judging in the harness (cross-unit → P6-10/P6-11).** `rt_simd` inherits `rt_num`'s
   **canonical-NaN lock** (deterministic positive canonical NaN). The `simd/*.wast` `assert_return`s
   use `nan:canonical`/`nan:arithmetic` **per-lane** patterns; the harness must judge NaN lanes by the
   pattern (canonical satisfies both), not bit-equality, and must handle the **per-lane** granularity
   (a v128 result where some lanes are exact and some are NaN-pattern). Flag to the conformance units so
   the value-comparison adapter is lane-aware.
4. **`extract_lane`/`bitmask`/`any_true`/`all_true` result typing at the seam.** These SIMD ops return
   a **scalar** (i32/i64/f32-bits/f64-bits), unlike the v128→v128 majority. Confirm `emit_core` lowers
   them to the scalar-result shape (the `Simd` node "yields a scalar" case, provisional §D) so the IR
   result type matches — this unit's heads already return `Int`, but the node-level typing is 01/06's.
5. **Should `pad_low` (and the codec) be shared, or `rt_simd`-private?** `pad_low` + the lane codec are
   used only by `rt_simd` (and the memory composition emitted by 06 calls `pad_low`). Recommend they
   stay **`rt_simd`-public** (so 06 can name `pad_low` in the emitted composition) with the codec
   private. Confirm 06 is content to call `rt_simd:pad_low/1` rather than inlining a pad in Core Erlang.
