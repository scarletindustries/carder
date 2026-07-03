# Phase 6 — Provisional shared surface (EM-provided, for scoping coherence)

> **Purpose.** So the scoping fan-out authors coherent unit docs (nothing frozen two incompatible
> ways), this file sketches a **provisional** IR4 / AST4 / `rt_simd` / linker surface. It is
> **provisional** — the keystone (P6-01) freezes the real thing and the scoping agents may refine
> any of it, but a refinement must be **argued** (in your unit doc's "deviations from the provisional
> surface" note) so the critique + reconciliation can adjudicate. Where a unit needs a shape this
> file doesn't give, propose one *in this file's idiom* (neutral names — D6; no WASM opcode strings).
>
> Grounding: this mirrors the existing `ir.gleam` (`NumOp`/`ConvOp` carried by `Num`/`Convert`,
> routed to `rt_num` by `emit_core`; `ConstF32(bits)` stores raw IEEE bits per D5). SIMD follows the
> **same** pattern one level up: a compact op-enum routed to `rt_simd`, `v128` stored as raw bytes.

---

## A. `v128` value & type (IR4)

```gleam
// ir.gleam — ValType gains ONE constructor (byte-identical for non-v128 modules):
pub type ValType {
  TI32  TI64  TF32  TF64  TTerm  TFuncRef  TExternRef
  TV128                              // NEW — a 128-bit fixed-width low-level value
}

// ir.gleam — Value gains the v128 literal (D5: store the raw 16 bytes, never a decoded structure):
pub type Value {
  Var(name: String)
  ConstI32(bits: Int)  ConstI64(bits: Int)  ConstF32(bits: Int)  ConstF64(bits: Int)
  ConstNull(ty: RefType)
  ConstV128(bytes: BitArray)         // NEW — exactly 16 bytes, little-endian lane layout
}
```

**Runtime representation:** a `v128` is a **16-byte binary** (`<<_:128>>`). The BEAM has no 128-bit
scalar; a binary is the natural fixed-width byte container (consistent with linear memory). Lane
decode/encode is bit-syntax (`<<a:32/little, b:32/little, c:32/little, d:32/little>>`).

## B. Lane shapes

```gleam
// The six standardized SIMD lane shapes. Carried by shape-uniform SimdOp constructors (like
// NumOp carries IntWidth). Integer shapes for int ops; float shapes for float ops.
pub type SimdShape {
  I8x16  I16x8  I32x4  I64x2  F32x4  F64x2
}
```

## C. `SimdOp` (IR4) — the compact op-enum (PROVISIONAL taxonomy)

The design goal: **shape-tag the uniform ops** (one constructor serves all applicable shapes, like
`IAdd(IntWidth)`), **name the shape-specific ops individually**. `emit_core` maps each
`(SimdOp[, shape])` to a concrete `rt_simd` function (the binding chokepoint). ~236 WASM instructions
collapse to on the order of ~110 `SimdOp` constructors; `rt_simd` still has ~236 concrete heads
(shape × op). **Scoping agents (esp. 01/03/07) refine this taxonomy and enumerate every op.**

```gleam
pub type SimdOp {
  // --- lane-uniform integer arithmetic (shape ∈ integer shapes) ---
  SAdd(SimdShape)   SSub(SimdShape)   SMul(SimdShape)          // i*x*: add/sub/mul (no i8x16.mul — validate/enumerate)
  SNeg(SimdShape)   SAbs(SimdShape)
  SMinS(SimdShape)  SMinU(SimdShape)  SMaxS(SimdShape)  SMaxU(SimdShape)
  SAvgrU(SimdShape)                                             // i8x16/i16x8 only
  SShl(SimdShape)   SShrS(SimdShape)  SShrU(SimdShape)          // shift by scalar i32, masked mod lane width
  // --- lane-uniform comparisons → a v128 mask (all-ones / all-zeros per lane) ---
  SEq(SimdShape)  SNe(SimdShape)
  SLtS(SimdShape) SLtU(SimdShape) SLeS(SimdShape) SLeU(SimdShape)
  SGtS(SimdShape) SGtU(SimdShape) SGeS(SimdShape) SGeU(SimdShape)
  // --- v128 bitwise (shape-agnostic) ---
  VNot  VAnd  VOr  VXor  VAndNot  VBitselect
  // --- boolean reductions / mask ---
  VAnyTrue                       // over the whole v128
  SAllTrue(SimdShape)  SBitmask(SimdShape)
  // --- lane access / build (carry a lane index or are splats) ---
  SSplat(SimdShape)
  SExtractLaneS(shape: SimdShape, lane: Int)  SExtractLaneU(shape: SimdShape, lane: Int)
  SReplaceLane(shape: SimdShape, lane: Int)
  // --- float-lane ops (shape ∈ F32x4/F64x2) ---
  FAdd(SimdShape) FSub(SimdShape) FMul(SimdShape) FDiv(SimdShape)
  FNeg(SimdShape) FAbs(SimdShape) FSqrt(SimdShape)
  FMin(SimdShape) FMax(SimdShape) FPMin(SimdShape) FPMax(SimdShape)
  FCeil(SimdShape) FFloor(SimdShape) FTrunc(SimdShape) FNearest(SimdShape)
  FEq(SimdShape) FNe(SimdShape) FLt(SimdShape) FLe(SimdShape) FGt(SimdShape) FGe(SimdShape)
  // --- conversions / narrow / widen / extend (shape-specific; enumerate ALL) ---
  I32x4TruncSatF32x4S  I32x4TruncSatF32x4U  I32x4TruncSatF64x2SZero  I32x4TruncSatF64x2UZero
  F32x4ConvertI32x4S   F32x4ConvertI32x4U   F32x4DemoteF64x2Zero
  F64x2ConvertLowI32x4S F64x2ConvertLowI32x4U F64x2PromoteLowF32x4
  I8x16NarrowI16x8S  I8x16NarrowI16x8U  I16x8NarrowI32x4S  I16x8NarrowI32x4U
  I16x8ExtendLowI8x16S I16x8ExtendHighI8x16S I16x8ExtendLowI8x16U I16x8ExtendHighI8x16U
  I32x4ExtendLowI16x8S /* …High/U */  I64x2ExtendLowI32x4S /* …High/U */
  // --- extended / pairwise / dot / q15 ---
  I16x8ExtMulLowI8x16S /* …High/U, I32x4ExtMul…, I64x2ExtMul… */
  I16x8ExtAddPairwiseI8x16S I16x8ExtAddPairwiseI8x16U I32x4ExtAddPairwiseI16x8S I32x4ExtAddPairwiseI16x8U
  I32x4DotI16x8S
  I16x8Q15MulrSatS
  I8x16Popcnt
  // --- byte shuffle / swizzle ---
  I8x16Swizzle                    // dynamic: v128 indices; OOB → 0
  // (i8x16.shuffle carries 16 immediates — see the dedicated Expr node in §D)
}
```

## D. SIMD `Expr` nodes (IR4) — PROVISIONAL

```gleam
pub type Expr {
  // …existing…
  /// Pure lane-wise SIMD op. `args` arity matches the op (1 unary, 2 binary, 3 for bitselect;
  /// splat takes a scalar; extract yields a scalar; replace takes v128+scalar). Yields a v128
  /// (or a scalar for extract-lane / any_true / all_true / bitmask). PURE — no trap, no state
  /// (effect.gleam classifies Simd as pure; it participates in const-fold/DCE like Num).
  Simd(op: SimdOp, args: List(Value))
  /// `i8x16.shuffle` — 16 immediate lane indices (each 0..31), selecting bytes from a ++ b.
  SimdShuffle(lanes: List(Int), a: Value, b: Value)
  // --- SIMD memory (route through rt_mem — bounds-checked; NOT pure) ---
  /// `v128.load` / the splat/extend/zero loads. `kind` selects plain|splatN|loadNxM_s/u|loadN_zero.
  SimdLoad(mem: Int, kind: SimdLoadKind, addr: Value, offset: Int)
  /// `v128.store`.
  SimdStore(mem: Int, addr: Value, value: Value, offset: Int)
  /// `v128.loadN_lane` — load N bits into `lane` of `vec`.
  SimdLoadLane(mem: Int, width: Int, addr: Value, offset: Int, lane: Int, vec: Value)
  /// `v128.storeN_lane` — store lane `lane` of `vec` (N bits) to memory.
  SimdStoreLane(mem: Int, width: Int, addr: Value, offset: Int, lane: Int, vec: Value)
}
```

`SimdLoadKind` (provisional): `V128 | Splat(width) | Extend(from_shape, signed) | Zero(width)`.
**Scoping note (open Q a):** 03/06/07 decide whether the SIMD-memory family is dedicated nodes (above)
or extended `MemLoad`/`MemStore` access kinds. The provisional pick is **dedicated nodes** (cleaner —
`MemLoad`'s `result: ValType` + `MemAccess` don't stretch to splat/extend/lane), but argue if you disagree.

## E. `rt_simd` (NEW runtime module) — signature idiom

Mirror `rt_num`: pure functions over raw bit patterns, tier-P `bif`, **reuse `rt_num` per lane**.
`v128` in/out is a `BitArray` (16 bytes). Scalars in/out are raw-bit `Int` (i32/i64/f32/f64 bits, D5).

```gleam
// runtime/rt_simd.gleam  (07 owns; 01 freezes the heads todo-free)
pub fn i32x4_add(a: BitArray, b: BitArray) -> BitArray
pub fn f32x4_mul(a: BitArray, b: BitArray) -> BitArray     // per-lane rt_num.f32_mul (single-rounding)
pub fn i8x16_swizzle(a: BitArray, idx: BitArray) -> BitArray
pub fn i8x16_shuffle(a: BitArray, b: BitArray, lanes: List(Int)) -> BitArray
pub fn i32x4_splat(x: Int) -> BitArray                     // x = i32 raw bits
pub fn i32x4_extract_lane(a: BitArray, lane: Int) -> Int
pub fn v128_any_true(a: BitArray) -> Int                   // → i32 0/1
// … ~236 heads total, enumerated by 07 across 07a (int) / 07b (float+convert) / 07c (misc+mem+shuffle)
```

**07 consumes `rt_num`, never edits it.** The SIMD-memory family (`SimdLoad*`/`SimdStore*`) is emitted
by 06 as a compose of the bounds-checked `rt_mem` seam (load/store a 16-byte slice, or N-byte for the
splat/lane variants) — `rt_simd` provides the pure lane-assembly helpers, `rt_mem` owns the bounds check.

## F. memory64 runtime (IR unchanged — `IdxType` already frozen)

- `instance.gleam` `Binding` gains **`mem64_max_pages: Int`** (PROVISIONAL name) — the documented,
  spec-aligned page cap for a 64-bit memory. **08 pins the exact constant + a spec citation** —
  RECONCILED (S9): the memory64 spec DECLARABLE type-max is **2⁴⁸ pages** (= 2⁶⁴ bytes, validate
  accepts up to this); the RUNTIME cap `mem64_max_pages` default is **2³² pages = 2⁴⁸ bytes = 256
  TiB** (a sparse trap boundary the paged backend never allocates — grow beyond → -1, access beyond
  current size → MemoryOutOfBounds). Do not conflate the two. 01
  freezes the field; `safe_default` sets it.
- `lower.gleam`: **delete the `Memory64Unsupported` rejection** for `Idx64`; thread the i64 address
  width. `emit_core`: a 64-bit memory's addr/bounds arithmetic is i64 (a 32-bit memory unchanged →
  byte-identical). `memory.size`/`grow` on a 64-bit memory take/return i64 page counts.
- `rt_mem.gleam`: the `t_load`/`t_store`/bounds core takes an address that may exceed 2³² for a 64-bit
  memory; the cap is a trap boundary. `atomics`/`nif` fail closed for an over-cap 64-bit memory.

## G. Cross-module function linking (extends P5 `link.gleam`)

`link.gleam` already has `ProvidedFunc(ty: FuncType)` (P5 uses it ONLY for signature *matching*).
Phase 6 adds the **dispatch capability**:

```gleam
// PROVISIONAL — 09 finalizes. Carry the callable closure alongside the signature:
pub type Provided {
  // …existing ProvidedGlobal/Table/Memory/RefGlobal…
  ProvidedFunc(ty: FuncType, call: fn(List(Dynamic)) -> Dynamic)   // NEW field: the linker-built closure
}
```

- The **linker builds `call`** capturing the exporting instance + its exported function (e.g.
  `fn(args){ a_instance:f(args) }`). `emit_core` lowers an imported-function `CallDirect`/`CallIndirect`
  target to **`apply(Closure, Args)` over the provided closure** — a capability, **not** an ambient
  `apply` of an attacker-named `module:atom` (D3a). The generated code holds the closure by its
  **positional import slot** (P5 R4: positional, name-free), never a runtime name lookup.
- `link_imports` extends to reject an unsatisfied/mismatched **function** import (fail-closed →
  `assert_unlinkable`). `(register …)` is P5-10b's parsed command; the multi-module registry is the
  substrate. **Open Q (d):** the `state_strategy` reach — `cell`-first for `linking.wast`; the threaded
  cross-instance case is categorized if invasive.

## H. What does NOT change (defaults byte-identical — I7)

A module with **no `v128`**, **no SIMD op**, a **single 32-bit memory**, and **no cross-module
imports** must decode/validate/lower/emit **byte-identically** to Phase-5 under both modes and every
shipped tier. `TV128`/`ConstV128`/`Simd*` are additive; the `mem64_max_pages` field defaults away for
32-bit memories; `ProvidedFunc`'s new field is unused by import-free modules. Assert this (H7-style).
