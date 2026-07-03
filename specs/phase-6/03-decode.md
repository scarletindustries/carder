# Unit P6-03 — WASM decode extension (+ «WASM-AST4»)

> **One owner. Wave A. Depends on nothing** upstream (extends the Phase-1/2/5
> `frontend/wasm/ast.gleam` + `decode.gleam`). **Publish the extended `ast.gleam`
> types as `«WASM-AST4»` on day 1** → unblocks **04 (validate)**, **05 (lower)**, and
> the WAT-parser SIMD un-skip (the P5-10 `wat.gleam` categorised SIMD as
> `Unsupported(Simd)`; that becomes a P6 follow-on that targets this AST). Read
> [`00-overview.md`](00-overview.md) (I1–I8), [`RECONCILIATION.md`](RECONCILIATION.md)
> (R1–R18 — still hold), the EM's [`PROVISIONAL-SURFACE.md`](PROVISIONAL-SURFACE.md)
> (the provisional IR4/`SimdOp` shapes this AST scopes against), and the Phase-5
> decode doc [`phase-5/03-decode.md`](../phase-5/03-decode.md) first.

---

## Context

Phase-5's decoder (`src/twocore/frontend/wasm/decode.gleam`, `«WASM-AST3»`) handles
the **whole standardized binary surface *minus SIMD***: the reftype value types
(`funcref`/`externref`), the reference/table/bulk-memory instructions, the import
section (2) with non-function imports, the datacount section (12), the multi-memory
memarg (bit-6 memidx + `u64` offset), the memory64 limits flags (`0x04`/`0x05` →
`Idx64`), and the full element (flags 0–7) / data (flags 0/1/2) segment grammar. Two
things it deliberately **decode-rejects** today are SIMD-shaped:

- the value-type byte **`v128 = 0x7B`** → `Error(ast.BadValType)` (in a valtype
  position) / `Error(ast.BadHeapType)` (in a reftype-only position), and
- the **`0xFD` prefix** → the byte is not in `leaf_instr`, is not `0xFC`, so it falls
  through `decode_instr`'s inner `case` to `Error(ast.UnknownOpcode(0xFD))`.

Phase 6 completes the standard. This unit is the **front door for the SIMD surface**:
it accepts `v128` as a first-class value type, un-rejects the `0xFD` prefix, and
decodes **all ~236 fixed-width SIMD sub-opcodes** — the `v128.const` 16-byte
immediate, the `i8x16.shuffle` 16 lane-index bytes, the extract/replace-lane byte
immediate, the whole lane-wise arithmetic/comparison/bitwise/conversion set, and the
`v128` memory family (`v128.load`/`store`, the splat/extend/zero loads, and the
load/store-`N`-lane ops) with their `memarg` + lane immediates. It publishes the AST
it produces as **`«WASM-AST4»`**.

The threat model is unchanged (D4 / H6): **the input is attacker-controlled.** Every
function stays total over arbitrary bytes — any malformation returns a typed
`DecodeError`, and **no `let assert`, `panic`, `todo`, or partial match is reachable
from input bytes**. This unit is purely *structural*: it does **not** type-check the
`v128` stack, range-check lane indices, verify shuffle indices are `0..31`, or check
that a SIMD `memarg`'s alignment fits the access width — those are **04 (validate)**'s
security-boundary job (the spec's `assert_malformed` (decode) vs `assert_invalid`
(validate) split). Its contract is: bytes → the extended WASM AST, faithfully and
fail-closed.

memory64's *decode* half already shipped in P5-03 (the `0x04`/`0x05` limits flags →
`Idx64` and the `u64` `memarg` offset). Phase 6 unfreezes the memory64 *runtime*
(P6-05 lower, P6-08 `rt_mem`) — **not decode**. This unit **confirms** the memory64
decode is complete and correct and changes nothing about it (§F).

## Goal

Decode the full fixed-width SIMD binary surface into an extended `ast.Module`:

- the **`v128` value type** (`0x7B`) wherever a valtype appears (params/results,
  locals, globals, typed `select`, blocktypes);
- the **`0xFD` prefix family** and **every** assigned sub-opcode in `0..255`
  (236 instructions; 20 reserved gaps + all `>= 256` relaxed-SIMD sub-opcodes →
  `UnknownSimdOpcode`);
- the **`v128.const`** 16-byte immediate (raw little-endian bytes, D5);
- the **`i8x16.shuffle`** 16 lane-index bytes;
- the **extract/replace-lane** single lane-index byte immediate;
- the **`v128` memory instructions** — `v128.load`/`store`, `v128.load{8,16,32,64}_splat`,
  `v128.load{8x8,16x4,32x2}_{s,u}`, `v128.load{32,64}_zero`, and
  `v128.load/store{8,16,32,64}_lane` — each with its `memarg` (and, for the lane forms,
  its trailing lane byte).

Prove it by decoding real `wat2wasm` fixtures to an exact AST for each new construct —
with **anti-swap / immediate-order fixtures** (v128.const byte order, shuffle lane
order, `memarg`-before-lane order, per-shape opcode disambiguation) — and by extending
the fail-closed fuzz battery to the SIMD surface (typed errors, zero panics).

## Files owned

| File | Action |
|---|---|
| `src/twocore/frontend/wasm/ast.gleam` | **Extend** (single-owner). `ValType` gains `V128`; the new AST-private `SimdShape`, `SimdOp`, `SimdLoadKind` types; the SIMD `Instr` constructors (`V128Const`, `Simd`, `I8x16Shuffle`, `SimdLoad`, `SimdStore`, `SimdLoadLane`, `SimdStoreLane`); the new `DecodeError` variant `UnknownSimdOpcode(Int)`. **This is `«WASM-AST4»`, published day 1.** |
| `src/twocore/frontend/wasm/decode.gleam` | **Extend** (single-owner). `decode_valtype` accepts `0x7B → V128`; `decode_blocktype` accepts the `-5` v128 encoding; `decode_instr` routes `0xFD` to the new `decode_simd`; `decode_simd` + its helpers decode all 236 sub-opcodes + their immediates. |
| `test/twocore/frontend/wasm/decode_test.gleam` (+ embedded fixtures) | **Extend.** Worked-fixture AST assertions per SIMD construct + the anti-swap fixtures + the fail-closed fuzz extension. |

**Day-1 publish (the freeze milestone `«WASM-AST4»`):** land the `ast.gleam` *type*
additions first as one compiling commit (the new/changed types, with the `decode.gleam`
arms filled just enough to compile — a stub `0xFD -> Error(ast.UnknownSimdOpcode(...))`
is acceptable), announce `«WASM-AST4»` in `state.md` with the full type delta listed,
**then** implement the decode bodies. Units 04/05 bind to the types, not the bodies.

## Deliverables & freeze milestones

1. **`«WASM-AST4»`** — the extended `ast.gleam` type surface (§A), day 1. The single
   milestone this unit *produces*; it is on the critical path for 04/05.
2. **`decode.gleam` bodies** — §§B–E decoded, fail-closed.
3. **Tests** — worked fixtures + anti-swap fixtures + fuzz (§Verification).

## Depends on

**Nothing upstream.** This unit extends the Phase-5 AST/decoder and touches neither
the IR (`ir.gleam`), the runtime, `rt_simd`, nor validate/lower. It can start
immediately. Like P5-03, it does **not** depend on the P6-01 keystone
(`«IR4-FROZEN»`) — the WASM AST is the frontend's *private* model, and lowering AST4 →
IR4 is unit 05's seam. **The AST must not import `ir.gleam`.** It **scopes its AST
against the provisional IR4 `SimdOp`/`SimdShape` taxonomy** (so 05's job is a
near-mechanical relabel), but it defines its **own** `ast.SimdOp`/`ast.SimdShape` —
exactly as the AST's numeric constructors (`I32Add`, …) are its own and lower bridges
them to `ir.NumOp` (§Deviations D1).

## Scope — in / out for Phase 6

**In (decode to AST4):**
- The `v128` value type (`0x7B`) in every valtype position + the `-5` blocktype
  encoding.
- The `0xFD` prefix and all **236** assigned sub-opcodes (§D): the memory family
  (`0..11`, `92`, `93`), `v128.const` (`12`), `i8x16.shuffle` (`13`), swizzle (`14`),
  splat (`15..20`), extract/replace lane (`21..34`), comparisons (`35..76`), bitwise +
  `any_true` (`77..83`), load/store lane (`84..91`), and the lane-wise
  arithmetic/rounding/narrow/widen/extend/dot/extmul/extadd/convert block (`94..255`).
- The SIMD immediates: the 16-byte `v128.const`, the 16-byte shuffle lane vector, the
  single lane byte (extract/replace + load/store-lane), and the `memarg` (reusing the
  Phase-5 `decode_memarg`, so the multi-memory bit-6 memidx + `u64` offset are already
  handled for SIMD memory ops).

**Out (defer; document, fail-closed):**
- **relaxed-SIMD** (the separate non-deterministic proposal; sub-opcodes `>= 256`, e.g.
  `i8x16.relaxed_swizzle` `0xFD 0x100`) → later. A sub-opcode `>= 256` — or any of the
  20 reserved gaps in `0..255` (§D.7) — is `Error(ast.UnknownSimdOpcode(sub))`.
- **All SIMD semantic checks** — the abstract-stack `v128` typing, lane-index range
  (`extract/replace_lane l` requires `l < lane-count`), shuffle indices `0..31`, the
  SIMD `memarg` alignment bound (`2^align <= N` where `N` is the *per-op* natural byte
  width — §E.5), and const-expr well-formedness for a `v128.const`-initialised global —
  are **validate's** (unit 04). Decode parses structure faithfully; validate is the
  security boundary for semantics.
- **The SIMD runtime** (`rt_simd`, P6-07) and **lowering** (AST4 → IR4, P6-05). Decode
  emits the AST node; nothing downstream is this unit's concern.
- **memory64 runtime** — unchanged here; already decode-complete (§F).

---

## A. `«WASM-AST4»` — the type surface (day-1 freeze)

Scope every new shape against the provisional IR4 (`PROVISIONAL-SURFACE.md` §§A–D) so
lower is mechanical, but keep the AST **WASM-shaped**: a flat instruction stream, raw
bit patterns (D5), and no `ir.gleam` import.

### A.1 The `v128` value type

Extend `ValType` with the one SIMD value type. In the binary format it is a single
byte in the same encoding position as a number valtype: **`v128 = 0x7B`** (spec
[binary/types.html#value-types](https://webassembly.github.io/spec/core/binary/types.html#binary-valtype)).

```gleam
/// A WebAssembly value type. Phase 1/2: the four number types. Phase 5 added the two
/// MVP reference types. Phase 6 (`«WASM-AST4»`) adds `V128` — the 128-bit fixed-width
/// SIMD value. Binary bytes: i32=0x7F i64=0x7E f32=0x7D f64=0x7C, v128=0x7B,
/// funcref=0x70, externref=0x6F. No GC-proposal reftypes.
pub type ValType {
  I32
  I64
  F32
  F64
  V128
  FuncRef
  ExternRef
}
```

`V128` is **not** a reftype — `decode_reftype` (reftype-only positions) still rejects
`0x7B` with `BadHeapType`; only `decode_valtype` accepts it (§B). Non-v128 modules
never carry `V128`, so every existing exhaustive match over `ValType` gains one
unreachable-in-practice arm and stays byte-identical (§G).

> **Cross-unit seam (S-VT):** `ast.V128` ↔ `ir.TV128` (keystone P6-01). Lower (05)
> maps `V128 → TV128`. The keystone owns `TV128`; this unit owns `ast.V128`. The two
> spellings must stay 1:1 (like `FuncRef`/`TFuncRef`).

### A.2 SIMD lane shapes

The six standardized SIMD lane shapes, carried by the shape-uniform `SimdOp`
constructors (the analogue of `NumOp` carrying `IntWidth`). AST-private (the IR has its
own `SimdShape` — §Deviations D1).

```gleam
/// The six standardized SIMD lane shapes (spec: the fixed-width SIMD value
/// interpretations). Integer shapes (`I8x16`/`I16x8`/`I32x4`/`I64x2`) tag the integer
/// lane ops; float shapes (`F32x4`/`F64x2`) tag the float lane ops. A `(shape, op)`
/// pair that has no standardized opcode (e.g. `SLtU(I64x2)` — i64x2 has no unsigned
/// compare) is simply never produced by `decode`; the enum admits it, the wire does
/// not.
pub type SimdShape {
  I8x16
  I16x8
  I32x4
  I64x2
  F32x4
  F64x2
}
```

### A.3 `SimdOp` — the compact lane-op enum

The design goal (mirroring `PROVISIONAL-SURFACE.md` §C and the frozen decision I2):
**shape-tag the uniform ops** (one constructor serves all applicable shapes), **name
the shape-specific ops individually**. Decode maps each `0xFD` sub-opcode to exactly
one `SimdOp` (or, for the immediate-bearing ops, to a dedicated `Instr` — §A.4). This
collapses the ~236 opcodes to ~120 `SimdOp` constructors; lower (05) relabels each to
`ir.SimdOp`, and `emit_core` (06) routes it to an `rt_simd` head.

```gleam
/// A single lane-wise SIMD operation (AST-private; the IR has its own `SimdOp`, which
/// lower relabels onto — §Deviations D1). Shape-uniform ops carry a `SimdShape`;
/// lane-access ops additionally carry a validated-later lane index; the shape-specific
/// conversions/narrow/widen/extend/dot/extmul/extadd ops are named individually.
/// Every constructor corresponds to one or more `0xFD` sub-opcodes enumerated in §D.
pub type SimdOp {
  // --- lane-uniform integer arithmetic (integer shapes) ---
  SAdd(SimdShape)   SSub(SimdShape)   SMul(SimdShape)
  SNeg(SimdShape)   SAbs(SimdShape)
  SMinS(SimdShape)  SMinU(SimdShape)  SMaxS(SimdShape)  SMaxU(SimdShape)
  SAvgrU(SimdShape)                               // i8x16 / i16x8 only
  SAddSatS(SimdShape) SAddSatU(SimdShape)         // i8x16 / i16x8 only
  SSubSatS(SimdShape) SSubSatU(SimdShape)         // i8x16 / i16x8 only
  SShl(SimdShape)   SShrS(SimdShape)  SShrU(SimdShape)   // shift count from a scalar i32
  SQ15MulrSatS                                    // i16x8 only
  SPopcnt                                         // i8x16 only
  // --- lane-uniform comparisons → an all-ones/all-zeros v128 mask ---
  SEq(SimdShape)  SNe(SimdShape)
  SLtS(SimdShape) SLtU(SimdShape) SLeS(SimdShape) SLeU(SimdShape)
  SGtS(SimdShape) SGtU(SimdShape) SGeS(SimdShape) SGeU(SimdShape)
  // --- v128 bitwise (shape-agnostic) + reductions ---
  VNot  VAnd  VAndNot  VOr  VXor  VBitselect
  VAnyTrue                                        // over the whole v128 → i32 0/1
  SAllTrue(SimdShape)  SBitmask(SimdShape)        // integer shapes → i32
  // --- lane access / build ---
  SSplat(SimdShape)
  SExtractLaneS(shape: SimdShape, lane: Int)      // i8x16 / i16x8
  SExtractLaneU(shape: SimdShape, lane: Int)      // i8x16 / i16x8
  SExtractLane(shape: SimdShape, lane: Int)       // i32x4 / i64x2 / f32x4 / f64x2
  SReplaceLane(shape: SimdShape, lane: Int)       // all shapes
  SSwizzle                                        // i8x16.swizzle (dynamic; OOB idx → 0)
  // --- float-lane ops (F32x4 / F64x2) ---
  FAdd(SimdShape) FSub(SimdShape) FMul(SimdShape) FDiv(SimdShape)
  FNeg(SimdShape) FAbs(SimdShape) FSqrt(SimdShape)
  FMin(SimdShape) FMax(SimdShape) FPMin(SimdShape) FPMax(SimdShape)
  FCeil(SimdShape) FFloor(SimdShape) FTrunc(SimdShape) FNearest(SimdShape)
  FEq(SimdShape) FNe(SimdShape) FLt(SimdShape) FLe(SimdShape) FGt(SimdShape) FGe(SimdShape)
  // --- narrowing (saturating) ---
  I8x16NarrowI16x8S  I8x16NarrowI16x8U  I16x8NarrowI32x4S  I16x8NarrowI32x4U
  // --- widening / extend (low/high, s/u) ---
  I16x8ExtendLowI8x16S  I16x8ExtendHighI8x16S  I16x8ExtendLowI8x16U  I16x8ExtendHighI8x16U
  I32x4ExtendLowI16x8S  I32x4ExtendHighI16x8S  I32x4ExtendLowI16x8U  I32x4ExtendHighI16x8U
  I64x2ExtendLowI32x4S  I64x2ExtendHighI32x4S  I64x2ExtendLowI32x4U  I64x2ExtendHighI32x4U
  // --- extended multiply (low/high, s/u) ---
  I16x8ExtMulLowI8x16S  I16x8ExtMulHighI8x16S  I16x8ExtMulLowI8x16U  I16x8ExtMulHighI8x16U
  I32x4ExtMulLowI16x8S  I32x4ExtMulHighI16x8S  I32x4ExtMulLowI16x8U  I32x4ExtMulHighI16x8U
  I64x2ExtMulLowI32x4S  I64x2ExtMulHighI32x4S  I64x2ExtMulLowI32x4U  I64x2ExtMulHighI32x4U
  // --- extended pairwise add + dot ---
  I16x8ExtAddPairwiseI8x16S  I16x8ExtAddPairwiseI8x16U
  I32x4ExtAddPairwiseI16x8S  I32x4ExtAddPairwiseI16x8U
  I32x4DotI16x8S
  // --- float ⇄ int conversions ---
  I32x4TruncSatF32x4S    I32x4TruncSatF32x4U
  I32x4TruncSatF64x2SZero I32x4TruncSatF64x2UZero
  F32x4ConvertI32x4S     F32x4ConvertI32x4U
  F32x4DemoteF64x2Zero
  F64x2ConvertLowI32x4S  F64x2ConvertLowI32x4U
  F64x2PromoteLowF32x4
}
```

Notes:
- **Lane indices ride in the op** (`SExtractLaneS(shape, lane)`, `SReplaceLane(shape,
  lane)`) rather than a dedicated `Instr` — matching `PROVISIONAL-SURFACE.md` §C. The
  `lane` byte is stored raw (an `Int` in `0..255`); validate checks `lane < lane-count`.
- The enum admits `(shape, op)` combinations with no wire opcode (e.g. `SMul(I8x16)` —
  there is no `i8x16.mul`; `SLtU(I64x2)`). Decode never emits them; validate never sees
  them. This is the same latitude `NumOp` has and costs nothing.

### A.4 SIMD `Instr` constructors

The immediate-bearing SIMD instructions get **dedicated `Instr` constructors** (raw
immediates are structurally distinct from a bare `SimdOp`); the pure lane ops ride a
single `Simd(op)` constructor. This keeps `Instr`'s SIMD surface to **seven**
constructors instead of ~236 (I2), and mirrors the provisional IR4 `Expr` shape
(`PROVISIONAL-SURFACE.md` §D) so lower is mechanical.

```gleam
pub type Instr {
  // …all existing Phase-1..5 constructors…

  // ===================== Phase 6 («WASM-AST4», the 0xFD family) =====================
  /// `v128.const` (0xFD 12) — the 16-byte immediate, stored RAW little-endian (D5: the
  /// bits, never a decoded lane structure, so NaN payloads / -0.0 survive). Always
  /// exactly 16 bytes; fewer is `Truncated`.
  V128Const(bytes: BitArray)
  /// A pure lane-wise SIMD op with no wire immediate beyond its identity (arithmetic,
  /// comparisons, bitwise, splat, extract/replace-lane — lane index inside `op` —,
  /// swizzle, conversions, narrow/widen/extend/dot/extmul/extadd/reductions). Operands
  /// come from the operand stack, as for every AST instruction.
  Simd(op: SimdOp)
  /// `i8x16.shuffle` (0xFD 13) — 16 immediate lane indices (each a raw byte, 0..255 on
  /// the wire; validate requires 0..31), selecting bytes from the two v128 operands
  /// `a ++ b`. `lanes` is always length 16; fewer bytes is `Truncated`.
  I8x16Shuffle(lanes: List(Int))
  /// A v128 memory LOAD (0xFD 0..10, 92, 93): `v128.load`, the `loadN_splat`, the
  /// extending `loadMxK_{s,u}`, and `loadN_zero`. `kind` selects which; `arg` is the
  /// standard `memarg` (multi-memory bit-6 memidx + u64 offset already handled). Routes
  /// through the bounds-checked `rt_mem` seam downstream (06/07) — never a raw term op.
  SimdLoad(kind: SimdLoadKind, arg: MemArg)
  /// `v128.store` (0xFD 11): stores a full 16-byte v128 to memory. `arg` is a `memarg`.
  SimdStore(arg: MemArg)
  /// `v128.loadN_lane` (0xFD 84..87): load N bits from memory into lane `lane` of the
  /// v128 operand. `width` ∈ {8,16,32,64}; `arg` is a `memarg`; `lane` is the trailing
  /// lane byte (decoded AFTER the memarg — §E.4). Validate checks `lane < 128/width`.
  SimdLoadLane(width: Int, arg: MemArg, lane: Int)
  /// `v128.storeN_lane` (0xFD 88..91): store the N-bit lane `lane` of the v128 operand
  /// to memory. Fields as `SimdLoadLane`.
  SimdStoreLane(width: Int, arg: MemArg, lane: Int)
}
```

```gleam
/// The v128 LOAD variant selected by a `SimdLoad`. Each maps 1:1 to a 0xFD sub-opcode
/// (§D.1). The extending variants (`Load8x8S`…`Load32x2U`) load 8 bytes and
/// sign-/zero-extend each of 8/4/2 sub-lanes to the next width; `Load{32,64}Zero` load
/// 4/8 bytes into the low lane and zero the rest; the `LoadNSplat` broadcast one
/// N-byte value across all lanes.
pub type SimdLoadKind {
  Load128                                 // v128.load          (0xFD 0)  N=16
  Load8x8S  Load8x8U                       // v128.load8x8_{s,u} (0xFD 1,2) N=8
  Load16x4S Load16x4U                      // v128.load16x4_{s,u}(0xFD 3,4) N=8
  Load32x2S Load32x2U                      // v128.load32x2_{s,u}(0xFD 5,6) N=8
  Load8Splat  Load16Splat                  // v128.load{8,16}_splat (0xFD 7,8)  N=1,2
  Load32Splat Load64Splat                  // v128.load{32,64}_splat(0xFD 9,10) N=4,8
  Load32Zero  Load64Zero                   // v128.load{32,64}_zero (0xFD 92,93)N=4,8
}
```

### A.5 New `DecodeError` variant

```gleam
/// A `0xFD`-prefixed sub-opcode outside the 236 standardized fixed-width SIMD
/// instructions: one of the 20 reserved gaps in 0..255 (§D.7), or a relaxed-SIMD
/// sub-opcode (`>= 256`, deferred). Carries the offending sub-opcode. The SIMD
/// analogue of `UnknownSatOpcode`.
UnknownSimdOpcode(Int)
```

This is the **only** new `DecodeError` variant. Every other SIMD malformation reuses an
existing one: a truncated `v128.const`/shuffle/lane/`memarg` → `Truncated`; a malformed
LEB sub-opcode → `LebOverflow`/`LebTooLong`/`Truncated`; a `v128` byte in a reftype-only
position → `BadHeapType` (unchanged). Per the P5-03 discipline: **reuse over add**;
every added variant must be justified against a distinct malformation the tests
exercise — `UnknownSimdOpcode` is (the unassigned-sub-opcode fuzz case, §Verification).

---

## B. `v128` valtype + blocktype

Two existing decoders gain a `v128` arm; `decode_reftype` is **unchanged** (v128 is not
a reftype).

**`decode_valtype`** adds `0x7B → V128` (spec
[binary/types.html#binary-valtype](https://webassembly.github.io/spec/core/binary/types.html#binary-valtype)):

| Byte | `decode_valtype` | `decode_reftype` |
|---|---|---|
| `0x7F 0x7E 0x7D 0x7C` | I32 I64 F32 F64 | → `BadHeapType` |
| **`0x7B`** | **V128** (NEW) | → `BadHeapType` (unchanged) |
| `0x70` | FuncRef | FuncRef |
| `0x6F` | ExternRef | ExternRef |
| other | `BadValType` | `BadHeapType` |

Because `decode_valtype` serves every valtype site, this one arm cascades correctly:
`v128` params/results (`decode_functype`), `v128` locals (`decode_locals`), a `v128`
global (`decode_global`), and a `v128`-typed `select (result v128)` (`SelectT([V128])`)
all decode with no further change. The existing `bad_heap_type_table_test`
(`0x7B` in a tabletype element position → `BadHeapType`) **still passes** — `v128` is
still not a legal table element type.

**`decode_blocktype`** adds the `v128` negative encoding. A valtype in a blocktype is
its byte value read as a signed LEB(33); `v128 = 0x7B` sign-extends to **`-5`** (spec
[binary/instructions.html#binary-blocktype](https://webassembly.github.io/spec/core/binary/instructions.html#binary-blocktype)):

| s33 value | `BlockType` |
|---|---|
| `>= 0` | `BlockTypeIdx(v)` |
| `-64` | `BlockEmpty` |
| `-1 -2 -3 -4` | `BlockVal(I32/I64/F32/F64)` |
| **`-5`** | **`BlockVal(V128)`** (NEW) |
| `-16 -17` | `BlockVal(FuncRef/ExternRef)` |
| other negative | `BadBlockType` |

A `v128`-result block (`(block (result v128) …)`) is legal and must decode; a
`v128`-const-init'd global (`(global v128 (v128.const …))`) needs both the valtype arm
and the `V128Const` instruction (§D.2), decoded structurally by `decode_const_expr`
(the const-ness restriction is validate's).

---

## C. The `0xFD` prefix dispatch

`0xFD` is a **prefix family**, exactly like `0xFC`: after the prefix byte, read a `u32`
sub-opcode (LEB128 — so sub-opcodes `>= 128` are multi-byte, e.g. `i32x4.add = 174`
encodes as `0xAE 0x01`), then dispatch on it. Add the `0xFD` arm alongside `0xFC` in
`decode_instr`'s inner fallthrough `case`:

```gleam
// inside decode_instr, the `_ ->` arm after leaf_instr/0xFC:
0xFD -> {
  use #(sub, r) <- result.try(decode_u_n(rest, 32))
  decode_simd(sub, r)
}
_ -> Error(ast.UnknownOpcode(op))
```

`decode_simd(sub, bytes)` is the SIMD sub-decoder. Its structure separates the six
immediate-bearing ranges from the pure-op bulk:

```gleam
/// Decode a 0xFD-prefixed SIMD instruction given its `sub`-opcode (a u32 already read)
/// and the bytes after it. Immediate-bearing ranges are handled explicitly; every
/// other sub-opcode is a pure lane op looked up by `simd_pure_op`. A sub-opcode with
/// no standardized fixed-width instruction (a reserved gap, or >= 256 relaxed-SIMD) is
/// `Error(ast.UnknownSimdOpcode(sub))`. Immediate order is WIRE order (§E, anti-swap).
fn decode_simd(sub: Int, bytes: BitArray)
  -> Result(#(Instr, BitArray), ast.DecodeError) {
  case sub {
    // memory loads / store (memarg)                      — §D.1
    0  -> simd_load(ast.Load128,   bytes)
    1  -> simd_load(ast.Load8x8S,  bytes)
    2  -> simd_load(ast.Load8x8U,  bytes)
    3  -> simd_load(ast.Load16x4S, bytes)
    4  -> simd_load(ast.Load16x4U, bytes)
    5  -> simd_load(ast.Load32x2S, bytes)
    6  -> simd_load(ast.Load32x2U, bytes)
    7  -> simd_load(ast.Load8Splat,  bytes)
    8  -> simd_load(ast.Load16Splat, bytes)
    9  -> simd_load(ast.Load32Splat, bytes)
    10 -> simd_load(ast.Load64Splat, bytes)
    11 -> { use #(a, r) <- result.try(decode_memarg(bytes)) Ok(#(ast.SimdStore(a), r)) }
    92 -> simd_load(ast.Load32Zero, bytes)
    93 -> simd_load(ast.Load64Zero, bytes)
    // v128.const / shuffle                                — §D.2
    12 -> decode_v128_const(bytes)
    13 -> decode_shuffle(bytes)
    // extract / replace lane (one lane byte)              — §D.3
    21 -> lane_op(bytes, ast.SExtractLaneS(ast.I8x16, _))
    22 -> lane_op(bytes, ast.SExtractLaneU(ast.I8x16, _))
    23 -> lane_op(bytes, ast.SReplaceLane(ast.I8x16, _))
    24 -> lane_op(bytes, ast.SExtractLaneS(ast.I16x8, _))
    25 -> lane_op(bytes, ast.SExtractLaneU(ast.I16x8, _))
    26 -> lane_op(bytes, ast.SReplaceLane(ast.I16x8, _))
    27 -> lane_op(bytes, ast.SExtractLane(ast.I32x4, _))
    28 -> lane_op(bytes, ast.SReplaceLane(ast.I32x4, _))
    29 -> lane_op(bytes, ast.SExtractLane(ast.I64x2, _))
    30 -> lane_op(bytes, ast.SReplaceLane(ast.I64x2, _))
    31 -> lane_op(bytes, ast.SExtractLane(ast.F32x4, _))
    32 -> lane_op(bytes, ast.SReplaceLane(ast.F32x4, _))
    33 -> lane_op(bytes, ast.SExtractLane(ast.F64x2, _))
    34 -> lane_op(bytes, ast.SReplaceLane(ast.F64x2, _))
    // load / store lane (memarg THEN lane byte)           — §D.6
    84 -> simd_load_lane(8,  bytes)
    85 -> simd_load_lane(16, bytes)
    86 -> simd_load_lane(32, bytes)
    87 -> simd_load_lane(64, bytes)
    88 -> simd_store_lane(8,  bytes)
    89 -> simd_store_lane(16, bytes)
    90 -> simd_store_lane(32, bytes)
    91 -> simd_store_lane(64, bytes)
    // everything else: a pure lane op (no immediate)      — §D.4/D.5/D.7
    _ ->
      case simd_pure_op(sub) {
        Ok(op) -> Ok(#(ast.Simd(op), bytes))
        Error(Nil) -> Error(ast.UnknownSimdOpcode(sub))
      }
  }
}
```

`simd_pure_op(sub: Int) -> Result(SimdOp, Nil)` is the pure-op lookup table (§D.4/D.5/
D.7). It is the SIMD analogue of `leaf_instr` / `sat_instr`: a total `case` over the
sub-opcode returning the `SimdOp`, or `Error(Nil)` for a gap → the caller reports
`UnknownSimdOpcode`.

---

## D. Full sub-opcode enumeration (all 236)

The authoritative source is the WebAssembly core spec's binary **vector instructions**
([binary/instructions.html#vector-instructions](https://webassembly.github.io/spec/core/binary/instructions.html#vector-instructions))
and the appendix instruction index
([appendix/index-instructions.html](https://webassembly.github.io/spec/core/appendix/index-instructions.html));
these fold the fixed-width SIMD proposal's `BinarySIMD.md`. **Every sub-opcode is a
`u32` LEB128** after the `0xFD` prefix. The 256 slots `0..255` hold **236 assigned**
instructions and **20 reserved gaps** (§D.7). Sub-opcodes `>= 256` are relaxed-SIMD
(out of scope).

### D.1 v128 memory — loads/store (sub 0..11, 92, 93) → `SimdLoad`/`SimdStore`

Each takes one `memarg` (§E.3). `N` is the natural access byte width (validate's
`2^align <= N` bound — §E.5; decode does not check it).

| Sub | Instruction | N | AST |
|---|---|---|---|
| 0  | `v128.load`        | 16 | `SimdLoad(Load128, arg)` |
| 1  | `v128.load8x8_s`   | 8  | `SimdLoad(Load8x8S, arg)` |
| 2  | `v128.load8x8_u`   | 8  | `SimdLoad(Load8x8U, arg)` |
| 3  | `v128.load16x4_s`  | 8  | `SimdLoad(Load16x4S, arg)` |
| 4  | `v128.load16x4_u`  | 8  | `SimdLoad(Load16x4U, arg)` |
| 5  | `v128.load32x2_s`  | 8  | `SimdLoad(Load32x2S, arg)` |
| 6  | `v128.load32x2_u`  | 8  | `SimdLoad(Load32x2U, arg)` |
| 7  | `v128.load8_splat` | 1  | `SimdLoad(Load8Splat, arg)` |
| 8  | `v128.load16_splat`| 2  | `SimdLoad(Load16Splat, arg)` |
| 9  | `v128.load32_splat`| 4  | `SimdLoad(Load32Splat, arg)` |
| 10 | `v128.load64_splat`| 8  | `SimdLoad(Load64Splat, arg)` |
| 11 | `v128.store`       | 16 | `SimdStore(arg)` |
| 92 | `v128.load32_zero` | 4  | `SimdLoad(Load32Zero, arg)` |
| 93 | `v128.load64_zero` | 8  | `SimdLoad(Load64Zero, arg)` |

### D.2 v128.const (sub 12) + i8x16.shuffle (sub 13)

| Sub | Instruction | Immediate | AST |
|---|---|---|---|
| 12 | `v128.const`     | 16 raw bytes (an `i128` literal, little-endian) | `V128Const(bytes)` — `bytes` exactly 16 |
| 13 | `i8x16.shuffle`  | 16 lane bytes (`laneidx^16`) | `I8x16Shuffle(lanes)` — `lanes` length 16 |

Both are fixed-length raw reads, **not** LEB or vectors (§E.1/E.2). A short input is
`Truncated`.

### D.3 splat / swizzle / lane-access (sub 14..34) → `Simd`

| Sub | Instruction | AST (`Simd(_)`) |
|---|---|---|
| 14 | `i8x16.swizzle` | `SSwizzle` |
| 15 | `i8x16.splat` | `SSplat(I8x16)` |
| 16 | `i16x8.splat` | `SSplat(I16x8)` |
| 17 | `i32x4.splat` | `SSplat(I32x4)` |
| 18 | `i64x2.splat` | `SSplat(I64x2)` |
| 19 | `f32x4.splat` | `SSplat(F32x4)` |
| 20 | `f64x2.splat` | `SSplat(F64x2)` |
| 21 | `i8x16.extract_lane_s` `l` | `SExtractLaneS(I8x16, l)` |
| 22 | `i8x16.extract_lane_u` `l` | `SExtractLaneU(I8x16, l)` |
| 23 | `i8x16.replace_lane` `l` | `SReplaceLane(I8x16, l)` |
| 24 | `i16x8.extract_lane_s` `l` | `SExtractLaneS(I16x8, l)` |
| 25 | `i16x8.extract_lane_u` `l` | `SExtractLaneU(I16x8, l)` |
| 26 | `i16x8.replace_lane` `l` | `SReplaceLane(I16x8, l)` |
| 27 | `i32x4.extract_lane` `l` | `SExtractLane(I32x4, l)` |
| 28 | `i32x4.replace_lane` `l` | `SReplaceLane(I32x4, l)` |
| 29 | `i64x2.extract_lane` `l` | `SExtractLane(I64x2, l)` |
| 30 | `i64x2.replace_lane` `l` | `SReplaceLane(I64x2, l)` |
| 31 | `f32x4.extract_lane` `l` | `SExtractLane(F32x4, l)` |
| 32 | `f32x4.replace_lane` `l` | `SReplaceLane(F32x4, l)` |
| 33 | `f64x2.extract_lane` `l` | `SExtractLane(F64x2, l)` |
| 34 | `f64x2.replace_lane` `l` | `SReplaceLane(F64x2, l)` |

`splat`/`swizzle` carry no immediate (operands from the stack). The 14 extract/replace
ops carry one lane byte (`l`, §E.2), folded into the `SimdOp` constructor. Sub 21..34
are handled in the explicit `case` (they have immediates); 14..20 are pure ops and may
be handled in `simd_pure_op` **or** the explicit `case` — either is fine; §C routes them
through `simd_pure_op` for a smaller `case`.

### D.4 comparisons (sub 35..76) → `Simd`

Integer comparisons yield a per-lane all-ones/all-zeros v128 mask; float comparisons the
same. Order within each shape: `eq ne lt(_s/_u) gt(_s/_u) le(_s/_u) ge(_s/_u)` for
integers; `eq ne lt gt le ge` for floats.

| Sub range | Shape | AST (`Simd(_)`) |
|---|---|---|
| 35 36 37 38 39 40 41 42 43 44 | i8x16 | `SEq/SNe/SLtS/SLtU/SGtS/SGtU/SLeS/SLeU/SGeS/SGeU(I8x16)` |
| 45 46 47 48 49 50 51 52 53 54 | i16x8 | …`(I16x8)` |
| 55 56 57 58 59 60 61 62 63 64 | i32x4 | …`(I32x4)` |
| 65 66 67 68 69 70 | f32x4 | `FEq/FNe/FLt/FGt/FLe/FGe(F32x4)` |
| 71 72 73 74 75 76 | f64x2 | `FEq/FNe/FLt/FGt/FLe/FGe(F64x2)` |

> **Note the float order:** the wire order is `eq ne lt gt le ge` — `gt` (67/74) comes
> **before** `le` (69/75). Do not sort them `lt le gt ge`. The i64x2 comparisons are
> **not** here — they live at 214..219 (§D.7).

### D.5 v128 bitwise + any_true (sub 77..83) → `Simd`

| Sub | Instruction | AST (`Simd(_)`) |
|---|---|---|
| 77 | `v128.not` | `VNot` |
| 78 | `v128.and` | `VAnd` |
| 79 | `v128.andnot` | `VAndNot` |
| 80 | `v128.or` | `VOr` |
| 81 | `v128.xor` | `VXor` |
| 82 | `v128.bitselect` | `VBitselect` |
| 83 | `v128.any_true` | `VAnyTrue` |

> **`andnot` is sub 79, between `and` (78) and `or` (80)** — a common transcription
> error is to place `or` at 79. Verified against the spec index.

### D.6 load/store lane (sub 84..91) → `SimdLoadLane`/`SimdStoreLane`

Each takes a `memarg` **then** a single lane byte (§E.4). `N` is the access width.

| Sub | Instruction | N | AST |
|---|---|---|---|
| 84 | `v128.load8_lane`  | 1 | `SimdLoadLane(8, arg, l)` |
| 85 | `v128.load16_lane` | 2 | `SimdLoadLane(16, arg, l)` |
| 86 | `v128.load32_lane` | 4 | `SimdLoadLane(32, arg, l)` |
| 87 | `v128.load64_lane` | 8 | `SimdLoadLane(64, arg, l)` |
| 88 | `v128.store8_lane` | 1 | `SimdStoreLane(8, arg, l)` |
| 89 | `v128.store16_lane`| 2 | `SimdStoreLane(16, arg, l)` |
| 90 | `v128.store32_lane`| 4 | `SimdStoreLane(32, arg, l)` |
| 91 | `v128.store64_lane`| 8 | `SimdStoreLane(64, arg, l)` |

### D.7 the lane-wise arithmetic / rounding / narrow / widen / extend / dot / extmul / extadd / convert block (sub 94..255) → `Simd`

This is the `simd_pure_op` bulk. The blocks are **not** contiguous per shape — the spec
interleaves the float rounding ops (`f32x4.ceil/floor/trunc/nearest`,
`f64x2.ceil/floor/trunc/nearest`) into the i8x16/i16x8 ranges — and there are **20
reserved gaps** (marked `— gap —`; a gap sub-opcode is `UnknownSimdOpcode`).

**94..95 — demote/promote**

| 94 `f32x4.demote_f64x2_zero` → `F32x4DemoteF64x2Zero` | 95 `f64x2.promote_low_f32x4` → `F64x2PromoteLowF32x4` |
|---|---|

**96..127 — i8x16 block (+ interleaved f32x4/f64x2 rounding), no gaps**

| Sub | Instr | `SimdOp` | Sub | Instr | `SimdOp` |
|---|---|---|---|---|---|
| 96  | i8x16.abs        | `SAbs(I8x16)`     | 112 | i8x16.add_sat_u  | `SAddSatU(I8x16)` |
| 97  | i8x16.neg        | `SNeg(I8x16)`     | 113 | i8x16.sub        | `SSub(I8x16)` |
| 98  | i8x16.popcnt     | `SPopcnt`         | 114 | i8x16.sub_sat_s  | `SSubSatS(I8x16)` |
| 99  | i8x16.all_true   | `SAllTrue(I8x16)` | 115 | i8x16.sub_sat_u  | `SSubSatU(I8x16)` |
| 100 | i8x16.bitmask    | `SBitmask(I8x16)` | 116 | f64x2.ceil       | `FCeil(F64x2)` |
| 101 | i8x16.narrow_i16x8_s | `I8x16NarrowI16x8S` | 117 | f64x2.floor  | `FFloor(F64x2)` |
| 102 | i8x16.narrow_i16x8_u | `I8x16NarrowI16x8U` | 118 | i8x16.min_s  | `SMinS(I8x16)` |
| 103 | f32x4.ceil       | `FCeil(F32x4)`    | 119 | i8x16.min_u      | `SMinU(I8x16)` |
| 104 | f32x4.floor      | `FFloor(F32x4)`   | 120 | i8x16.max_s      | `SMaxS(I8x16)` |
| 105 | f32x4.trunc      | `FTrunc(F32x4)`   | 121 | i8x16.max_u      | `SMaxU(I8x16)` |
| 106 | f32x4.nearest    | `FNearest(F32x4)` | 122 | f64x2.trunc      | `FTrunc(F64x2)` |
| 107 | i8x16.shl        | `SShl(I8x16)`     | 123 | i8x16.avgr_u     | `SAvgrU(I8x16)` |
| 108 | i8x16.shr_s      | `SShrS(I8x16)`    | 124 | i16x8.extadd_pairwise_i8x16_s | `I16x8ExtAddPairwiseI8x16S` |
| 109 | i8x16.shr_u      | `SShrU(I8x16)`    | 125 | i16x8.extadd_pairwise_i8x16_u | `I16x8ExtAddPairwiseI8x16U` |
| 110 | i8x16.add        | `SAdd(I8x16)`     | 126 | i32x4.extadd_pairwise_i16x8_s | `I32x4ExtAddPairwiseI16x8S` |
| 111 | i8x16.add_sat_s  | `SAddSatS(I8x16)` | 127 | i32x4.extadd_pairwise_i16x8_u | `I32x4ExtAddPairwiseI16x8U` |

**128..159 — i16x8 block (+ f64x2.nearest at 148), gap at 154**

| Sub | Instr | `SimdOp` | Sub | Instr | `SimdOp` |
|---|---|---|---|---|---|
| 128 | i16x8.abs        | `SAbs(I16x8)`     | 144 | i16x8.add_sat_u  | `SAddSatU(I16x8)` |
| 129 | i16x8.neg        | `SNeg(I16x8)`     | 145 | i16x8.sub        | `SSub(I16x8)` |
| 130 | i16x8.q15mulr_sat_s | `SQ15MulrSatS`  | 146 | i16x8.sub_sat_s  | `SSubSatS(I16x8)` |
| 131 | i16x8.all_true   | `SAllTrue(I16x8)` | 147 | i16x8.sub_sat_u  | `SSubSatU(I16x8)` |
| 132 | i16x8.bitmask    | `SBitmask(I16x8)` | 148 | f64x2.nearest    | `FNearest(F64x2)` |
| 133 | i16x8.narrow_i32x4_s | `I16x8NarrowI32x4S` | 149 | i16x8.mul    | `SMul(I16x8)` |
| 134 | i16x8.narrow_i32x4_u | `I16x8NarrowI32x4U` | 150 | i16x8.min_s  | `SMinS(I16x8)` |
| 135 | i16x8.extend_low_i8x16_s  | `I16x8ExtendLowI8x16S`  | 151 | i16x8.min_u | `SMinU(I16x8)` |
| 136 | i16x8.extend_high_i8x16_s | `I16x8ExtendHighI8x16S` | 152 | i16x8.max_s | `SMaxS(I16x8)` |
| 137 | i16x8.extend_low_i8x16_u  | `I16x8ExtendLowI8x16U`  | 153 | i16x8.max_u | `SMaxU(I16x8)` |
| 138 | i16x8.extend_high_i8x16_u | `I16x8ExtendHighI8x16U` | **154** | **— gap —** | `UnknownSimdOpcode(154)` |
| 139 | i16x8.shl        | `SShl(I16x8)`     | 155 | i16x8.avgr_u     | `SAvgrU(I16x8)` |
| 140 | i16x8.shr_s      | `SShrS(I16x8)`    | 156 | i16x8.extmul_low_i8x16_s  | `I16x8ExtMulLowI8x16S` |
| 141 | i16x8.shr_u      | `SShrU(I16x8)`    | 157 | i16x8.extmul_high_i8x16_s | `I16x8ExtMulHighI8x16S` |
| 142 | i16x8.add        | `SAdd(I16x8)`     | 158 | i16x8.extmul_low_i8x16_u  | `I16x8ExtMulLowI8x16U` |
| 143 | i16x8.add_sat_s  | `SAddSatS(I16x8)` | 159 | i16x8.extmul_high_i8x16_u | `I16x8ExtMulHighI8x16U` |

**160..191 — i32x4 block, gaps at 162, 165, 166, 175, 176, 178, 179, 180, 187**

| Sub | Instr | `SimdOp` | Sub | Instr | `SimdOp` |
|---|---|---|---|---|---|
| 160 | i32x4.abs        | `SAbs(I32x4)`     | 176 | — gap —          | `UnknownSimdOpcode(176)` |
| 161 | i32x4.neg        | `SNeg(I32x4)`     | 177 | i32x4.sub        | `SSub(I32x4)` |
| 162 | — gap —          | `UnknownSimdOpcode(162)` | 178 | — gap — | `UnknownSimdOpcode(178)` |
| 163 | i32x4.all_true   | `SAllTrue(I32x4)` | 179 | — gap —          | `UnknownSimdOpcode(179)` |
| 164 | i32x4.bitmask    | `SBitmask(I32x4)` | 180 | — gap —          | `UnknownSimdOpcode(180)` |
| 165 | — gap —          | `UnknownSimdOpcode(165)` | 181 | i32x4.mul | `SMul(I32x4)` |
| 166 | — gap —          | `UnknownSimdOpcode(166)` | 182 | i32x4.min_s | `SMinS(I32x4)` |
| 167 | i32x4.extend_low_i16x8_s  | `I32x4ExtendLowI16x8S`  | 183 | i32x4.min_u | `SMinU(I32x4)` |
| 168 | i32x4.extend_high_i16x8_s | `I32x4ExtendHighI16x8S` | 184 | i32x4.max_s | `SMaxS(I32x4)` |
| 169 | i32x4.extend_low_i16x8_u  | `I32x4ExtendLowI16x8U`  | 185 | i32x4.max_u | `SMaxU(I32x4)` |
| 170 | i32x4.extend_high_i16x8_u | `I32x4ExtendHighI16x8U` | 186 | i32x4.dot_i16x8_s | `I32x4DotI16x8S` |
| 171 | i32x4.shl        | `SShl(I32x4)`     | 187 | — gap —          | `UnknownSimdOpcode(187)` |
| 172 | i32x4.shr_s      | `SShrS(I32x4)`    | 188 | i32x4.extmul_low_i16x8_s  | `I32x4ExtMulLowI16x8S` |
| 173 | i32x4.shr_u      | `SShrU(I32x4)`    | 189 | i32x4.extmul_high_i16x8_s | `I32x4ExtMulHighI16x8S` |
| 174 | i32x4.add        | `SAdd(I32x4)`     | 190 | i32x4.extmul_low_i16x8_u  | `I32x4ExtMulLowI16x8U` |
| 175 | — gap —          | `UnknownSimdOpcode(175)` | 191 | i32x4.extmul_high_i16x8_u | `I32x4ExtMulHighI16x8U` |

**192..223 — i64x2 block (+ i64x2 comparisons 214..219), gaps at 194, 197, 198, 207, 208, 210, 211, 212**

| Sub | Instr | `SimdOp` | Sub | Instr | `SimdOp` |
|---|---|---|---|---|---|
| 192 | i64x2.abs        | `SAbs(I64x2)`     | 208 | — gap —          | `UnknownSimdOpcode(208)` |
| 193 | i64x2.neg        | `SNeg(I64x2)`     | 209 | i64x2.sub        | `SSub(I64x2)` |
| 194 | — gap —          | `UnknownSimdOpcode(194)` | 210 | — gap — | `UnknownSimdOpcode(210)` |
| 195 | i64x2.all_true   | `SAllTrue(I64x2)` | 211 | — gap —          | `UnknownSimdOpcode(211)` |
| 196 | i64x2.bitmask    | `SBitmask(I64x2)` | 212 | — gap —          | `UnknownSimdOpcode(212)` |
| 197 | — gap —          | `UnknownSimdOpcode(197)` | 213 | i64x2.mul | `SMul(I64x2)` |
| 198 | — gap —          | `UnknownSimdOpcode(198)` | 214 | i64x2.eq  | `SEq(I64x2)` |
| 199 | i64x2.extend_low_i32x4_s  | `I64x2ExtendLowI32x4S`  | 215 | i64x2.ne   | `SNe(I64x2)` |
| 200 | i64x2.extend_high_i32x4_s | `I64x2ExtendHighI32x4S` | 216 | i64x2.lt_s | `SLtS(I64x2)` |
| 201 | i64x2.extend_low_i32x4_u  | `I64x2ExtendLowI32x4U`  | 217 | i64x2.gt_s | `SGtS(I64x2)` |
| 202 | i64x2.extend_high_i32x4_u | `I64x2ExtendHighI32x4U` | 218 | i64x2.le_s | `SLeS(I64x2)` |
| 203 | i64x2.shl        | `SShl(I64x2)`     | 219 | i64x2.ge_s       | `SGeS(I64x2)` |
| 204 | i64x2.shr_s      | `SShrS(I64x2)`    | 220 | i64x2.extmul_low_i32x4_s  | `I64x2ExtMulLowI32x4S` |
| 205 | i64x2.shr_u      | `SShrU(I64x2)`    | 221 | i64x2.extmul_high_i32x4_s | `I64x2ExtMulHighI32x4S` |
| 206 | i64x2.add        | `SAdd(I64x2)`     | 222 | i64x2.extmul_low_i32x4_u  | `I64x2ExtMulLowI32x4U` |
| 207 | — gap —          | `UnknownSimdOpcode(207)` | 223 | i64x2.extmul_high_i32x4_u | `I64x2ExtMulHighI32x4U` |

> **i64x2 has only the six signed comparisons** (214..219: `eq ne lt_s gt_s le_s
> ge_s`) — no unsigned, no `min/max`. `SLtU(I64x2)` etc. exist in the enum but have no
> opcode and are never produced.

**224..235 — f32x4 block, gap at 226**

| 224 f32x4.abs `FAbs(F32x4)` | 225 f32x4.neg `FNeg(F32x4)` | 226 **— gap —** `UnknownSimdOpcode(226)` | 227 f32x4.sqrt `FSqrt(F32x4)` |
|---|---|---|---|
| 228 f32x4.add `FAdd(F32x4)` | 229 f32x4.sub `FSub(F32x4)` | 230 f32x4.mul `FMul(F32x4)` | 231 f32x4.div `FDiv(F32x4)` |
| 232 f32x4.min `FMin(F32x4)` | 233 f32x4.max `FMax(F32x4)` | 234 f32x4.pmin `FPMin(F32x4)` | 235 f32x4.pmax `FPMax(F32x4)` |

**236..247 — f64x2 block, gap at 238**

| 236 f64x2.abs `FAbs(F64x2)` | 237 f64x2.neg `FNeg(F64x2)` | 238 **— gap —** `UnknownSimdOpcode(238)` | 239 f64x2.sqrt `FSqrt(F64x2)` |
|---|---|---|---|
| 240 f64x2.add `FAdd(F64x2)` | 241 f64x2.sub `FSub(F64x2)` | 242 f64x2.mul `FMul(F64x2)` | 243 f64x2.div `FDiv(F64x2)` |
| 244 f64x2.min `FMin(F64x2)` | 245 f64x2.max `FMax(F64x2)` | 246 f64x2.pmin `FPMin(F64x2)` | 247 f64x2.pmax `FPMax(F64x2)` |

**248..255 — float ⇄ int conversions, no gaps**

| Sub | Instruction | `SimdOp` |
|---|---|---|
| 248 | i32x4.trunc_sat_f32x4_s        | `I32x4TruncSatF32x4S` |
| 249 | i32x4.trunc_sat_f32x4_u        | `I32x4TruncSatF32x4U` |
| 250 | f32x4.convert_i32x4_s          | `F32x4ConvertI32x4S` |
| 251 | f32x4.convert_i32x4_u          | `F32x4ConvertI32x4U` |
| 252 | i32x4.trunc_sat_f64x2_s_zero   | `I32x4TruncSatF64x2SZero` |
| 253 | i32x4.trunc_sat_f64x2_u_zero   | `I32x4TruncSatF64x2UZero` |
| 254 | f64x2.convert_low_i32x4_s      | `F64x2ConvertLowI32x4S` |
| 255 | f64x2.convert_low_i32x4_u      | `F64x2ConvertLowI32x4U` |

**Assigned-count audit.** Sum of assigned sub-opcodes: memory 14 (0..11,92,93) + const/
shuffle 2 + splat/swizzle/lane 21 (14..34) + comparisons 42 (35..76) + bitwise 7
(77..83) + load/store-lane 8 (84..91) + demote/promote 2 (94,95) + i8x16 block 32
(96..127) + i16x8 block 31 (128..159, gap 154) + i32x4 block 23 (160..191, 9 gaps) +
i64x2 block 24 (192..223, 8 gaps) + f32x4 block 11 (224..235, gap 226) + f64x2 block 11
(236..247, gap 238) + conversions 8 (248..255) = **236**. The 20 gaps: 154; 162,165,166,
175,176,178,179,180,187; 194,197,198,207,208,210,211,212; 226; 238. `236 + 20 = 256`.
This audit is a **test** (§Verification 3): a sweep over `0..255` asserting exactly the
236 listed subs decode `Ok` and exactly the 20 gaps + a sample of `>= 256` decode
`UnknownSimdOpcode`.

---

## E. Immediates, in detail (+ anti-swap)

The SIMD immediates are the sharp edges. Decode reads them faithfully in **wire order**;
a swap silently mis-decodes (e.g. reading the lane byte before the memarg), so each has a
fixture that fails if the order is wrong.

### E.1 `v128.const` — 16 raw bytes

```gleam
/// Decode `v128.const`'s 16-byte immediate (spec: an i128 literal, little-endian).
/// Stored RAW (D5) as a 16-byte BitArray — never a decoded lane structure, so NaN
/// payloads / -0.0 / exact lane bits survive. Fewer than 16 bytes ⇒ Truncated.
fn decode_v128_const(bytes) -> Result(#(Instr, BitArray), ast.DecodeError) {
  case bytes {
    <<imm:16-bytes, r:bytes>> -> Ok(#(ast.V128Const(imm), r))
    _ -> Error(ast.Truncated)
  }
}
```

The 16 bytes are consumed exactly as written; the AST stores them verbatim. `v128.const
i32x4 1 2 3 4` and `v128.const i8x16 1 0 0 0 2 0 0 0 …` produce **byte-identical**
16-byte arrays — decode does not interpret the shape annotation (that is a WAT-text
nicety); on the wire both are just 16 bytes. **Anti-swap fixture:** a `v128.const` whose
16 bytes are `00 01 02 … 0F` must decode to that exact `BitArray`, proving little-endian
byte order is preserved and not reversed/regrouped.

### E.2 `i8x16.shuffle` — 16 lane bytes; extract/replace — 1 lane byte

A `laneidx` is a **single byte** (`laneidx ::= l:byte`, spec
[binary/instructions.html#binary-laneidx](https://webassembly.github.io/spec/core/binary/instructions.html)) —
**not** LEB128. `i8x16.shuffle` carries sixteen of them (`laneidx^16`):

```gleam
/// Decode `i8x16.shuffle`'s 16 lane-index bytes. Each is a raw byte 0..255 (validate
/// requires 0..31). lanes[i] selects the byte for RESULT lane i, from the concatenation
/// a ++ b of the two v128 operands (0..15 → a, 16..31 → b). Fewer than 16 bytes ⇒
/// Truncated. Order is load-bearing: lanes[0] is result lane 0.
fn decode_shuffle(bytes) -> Result(#(Instr, BitArray), ast.DecodeError) {
  case bytes {
    <<l0,l1,l2,l3,l4,l5,l6,l7,l8,l9,l10,l11,l12,l13,l14,l15, r:bytes>> ->
      Ok(#(ast.I8x16Shuffle([l0,l1,l2,l3,l4,l5,l6,l7,l8,l9,l10,l11,l12,l13,l14,l15]), r))
    _ -> Error(ast.Truncated)
  }
}
```

A single lane byte (extract/replace) via a small helper:

```gleam
/// Read one lane-index byte and build a lane-carrying Simd instruction. Truncated if
/// the byte is absent. The lane is stored raw (0..255); validate checks lane < count.
fn lane_op(bytes, make: fn(Int) -> SimdOp)
  -> Result(#(Instr, BitArray), ast.DecodeError) {
  case bytes {
    <<l:8, r:bytes>> -> Ok(#(ast.Simd(make(l)), r))
    _ -> Error(ast.Truncated)
  }
}
```

**Anti-swap fixture:** `i8x16.shuffle` with lanes `0 1 2 … 15` must decode to
`[0,1,…,15]` (not `[15,…,0]`); a distinct permutation (e.g. `16 0 17 1 …`) proves each
byte lands at its result-lane position and the `a`/`b` halves are not swapped.

### E.3 SIMD `memarg` — reuse the Phase-5 decoder

SIMD memory ops carry the **same `memarg`** as scalar loads/stores — decode reuses the
existing `decode_memarg` unchanged. It already handles the multi-memory bit-6 memidx and
the `u64` offset (P5-03 §G.1), so a SIMD load into memory 1
(`v128.load (memory 1) …`) decodes `MemArg.mem == 1`, and a plain `v128.load` decodes
`MemArg.mem == 0`. No SIMD-specific memarg logic exists. (Validate owns the SIMD
alignment bound — §E.5.)

### E.4 load/store lane — memarg THEN lane byte (order is security-relevant)

The lane form is `memarg` **followed by** a `laneidx` byte — the memarg first, the lane
byte last (spec
[binary/instructions.html#vector-instructions](https://webassembly.github.io/spec/core/binary/instructions.html#vector-instructions)):

```gleam
/// v128.loadN_lane: a memarg THEN one lane byte. NOT lane-then-memarg — swapping them
/// reads the lane byte as the align flags and mis-decodes the whole instruction.
fn simd_load_lane(width: Int, bytes) -> Result(#(Instr, BitArray), ast.DecodeError) {
  use #(arg, r1) <- result.try(decode_memarg(bytes))
  case r1 {
    <<l:8, r2:bytes>> -> Ok(#(ast.SimdLoadLane(width, arg, l), r2))
    _ -> Error(ast.Truncated)
  }
}
// simd_store_lane is identical, building SimdStoreLane.
```

**Anti-swap fixture:** a `v128.load8_lane` with a **distinct** align/offset memarg and a
distinct lane byte (e.g. `align=0 offset=4 lane=3`) must decode `MemArg(align:0,
offset:4, mem:0)` and `lane:3` — swapping the two would decode `align=3` (wrong) and read
`4` as the lane. Include a form with the bit-6 memidx set (`v128.load16_lane (memory 1)
… lane 2`) so the memidx-then-offset-then-lane order is all exercised.

### E.5 What decode does NOT check (validate's, unit 04)

- **SIMD `memarg` alignment.** The spec bounds `2^align <= N` where `N` is the *natural
  byte width* of the SIMD access — `16` for `v128.load`/`store`; `1/2/4/8` for the
  `load{8,16,32,64}_splat` and `load/store{8,16,32,64}_lane`; `8` for the extending
  `load{8x8,16x4,32x2}_{s,u}` and `load64_zero`; `4` for `load32_zero`. The `N` column in
  §D.1/D.6 is validate's input; decode carries only the raw `align`.
- **Lane-index range.** `extract/replace_lane l` requires `l < 128/width` for the shape;
  `i8x16.shuffle`'s sixteen indices each require `0..31`. Decode stores the raw bytes;
  validate rejects out-of-range as `assert_invalid`.
- **v128 stack typing.** That a SIMD op finds a `v128` (or the right scalar for splat /
  the i32 shift count) on the abstract stack is validate's.

---

## F. memory64 — already decode-complete (confirm, no change)

The task calls for confirming memory64's decode. **It is complete and this unit changes
nothing about it.** P5-03 shipped:
- `decode_mem_limits` accepting the index-type flags `0x04` (Idx64, no max) and `0x05`
  (Idx64, with max), reading `min`/`max` as `u64` for the 64-bit forms;
- `MemType(limits, idx_type: Idx64)` and the `IdxType` axis in the AST;
- the `memarg` offset decoded as `u64` unconditionally (`decode_u_n(_, 64)`), so a 64-bit
  memory's `> 2^32` offsets decode.

Phase 6 unfreezes the memory64 **runtime** in lower (P6-05, "stop rejecting `Idx64`") and
`rt_mem` (P6-08, the page cap). **Decode is untouched** — there is no new byte to parse.
The only interaction with this unit is negative: a `v128` SIMD load into a **64-bit**
memory still decodes through `decode_memarg` with the `u64` offset, so SIMD-on-mem64
composes with zero extra decode logic. A regression fixture confirms `(memory i64 1)`
still decodes `MemType(Limits(1, None), Idx64)` after the AST4 additions (the `ValType`
gaining `V128` must not perturb the limits decoder).

---

## Effect / soundness / security note

- **Fail-closed over hostile bytes (D4/H6).** Every new SIMD sub-decoder returns a typed
  `DecodeError` on malformation; `decode.gleam` stays free of `let assert`, `panic`,
  `todo`, and non-exhaustive matches reachable from input. The `0xFD` sub-opcode is a
  `decode_u_n(_, 32)` (so a malformed LEB is `LebOverflow`/`LebTooLong`/`Truncated`,
  never a wrap); the fixed-width reads (`v128.const` 16 bytes, shuffle 16 bytes, lane
  byte) fail the bit-syntax match → `Truncated` on any shortfall, never an over-read; an
  unassigned sub-opcode is `UnknownSimdOpcode(sub)`. Totality holds over arbitrary bytes.
- **Decode is not the security boundary; it is the parser.** It deliberately does *not*
  type the `v128` stack, range-check lane indices, verify shuffle indices `0..31`, or
  bound the SIMD `memarg` alignment. Those are validate's (unit 04) — the spec's
  `assert_malformed` (decode) vs `assert_invalid` (validate) split. Decode's soundness
  obligation is **totality + faithful structure**: a well-formed SIMD binary decodes to
  the *exact* AST the spec's vector-instruction grammar prescribes, and every ill-formed
  binary is rejected without a crash.
- **`v128` is an opaque value at the AST.** The 16 bytes of a `v128.const` are stored
  raw (D5); the AST never decodes them into lanes, so NaN payloads, `-0.0`, and exact
  lane bits are preserved for `rt_simd` to interpret. No SIMD instruction at the AST
  grants memory authority except the `SimdLoad`/`SimdStore`/`SimdLoadLane`/
  `SimdStoreLane` family — and those carry only a `memarg`, routed downstream (06/07)
  through the **bounds-checked `rt_mem` seam** (I6): the worst case of a SIMD-memory bug
  is a wrong/missing trap or a node-safe crash, **never a host escape**.
- **Conformance-neutral defaults (I7/H7).** A module with **no `v128` value type and no
  `0xFD` instruction** decodes to a *structurally identical* AST4 — the `V128` `ValType`
  constructor is unused, no `Simd*`/`V128Const` node appears, and every Phase-1..5 field
  is untouched. The one behavioral change to an existing path (`decode_valtype` now maps
  `0x7B → V128` instead of `→ BadValType`) is unreachable for a non-SIMD module (which
  never contains `0x7B`), so the entire Phase-1..5 corpus decodes byte-identically. Lower
  must then re-emit byte-identical IR/`.core` (the H7 obligation is discharged jointly
  with 05/06; the AST-level neutrality is this unit's part).
- **No new authority.** Decoding a SIMD instruction records structure only; it grants
  nothing. `v128` in Safe mode is an opaque 16-byte value with no memory reach except the
  checked seam.

---

## Verification — Definition of Done (D8)

**Spec behavior, not change-detector.** Drive decode from `wat2wasm --enable-simd`-
produced binaries (embed the `.wasm` bytes as `BitArray` literals so the suite needs no
external tool at run time) and assert the AST against the **binary-format spec** (cite
the exact vector-instruction sub-opcode per fixture). Never assert "whatever decode
emits." The opcode numbers in §D are the spec; a fixture that decodes to the wrong
`SimdOp` is a *code* bug caught here.

### 1. Worked fixtures (exact AST), covering each family

- **`v128` value type:** a function `(func (param v128) (result v128) local.get 0)` →
  `FuncType([V128], [V128])`; a `(local v128)` → the local vector contains `V128`; a
  `(global v128 (v128.const i32x4 0 0 0 0))` → `Global(ty: V128, …, init: [V128Const(_),
  End-consumed])`; `select (result v128)` → `SelectT([V128])`; `(block (result v128) …)`
  → `Block(BlockVal(V128))`. A `v128` byte `0x7B` in a **tabletype** element position
  still → `BadHeapType` (keep `bad_heap_type_table_test`).
- **`v128.const` (anti-swap, §E.1):** bytes `00 01 … 0F` → `V128Const(<<0,1,…,15>>)`
  exactly (little-endian byte order preserved).
- **`i8x16.shuffle` (anti-swap, §E.2):** lanes `0..15` → `I8x16Shuffle([0,…,15])`; a
  permutation `[16,0,17,1,…]` → the exact list (proves per-position + a/b halves).
- **`i8x16.swizzle`** → `Simd(SSwizzle)`.
- **splat:** `i32x4.splat` (17) → `Simd(SSplat(I32x4))`; `f64x2.splat` (20) →
  `Simd(SSplat(F64x2))`.
- **extract/replace lane:** `i8x16.extract_lane_s 3` (21) →
  `Simd(SExtractLaneS(I8x16, 3))`; `i32x4.replace_lane 2` (28) →
  `Simd(SReplaceLane(I32x4, 2))`; `f64x2.extract_lane 1` (33) →
  `Simd(SExtractLane(F64x2, 1))`.
- **per-shape arithmetic disambiguation (multi-byte LEB):** `i8x16.add` (110, one-byte
  sub) → `Simd(SAdd(I8x16))`; **`i32x4.add`** (174, **two-byte** LEB `0xAE 0x01`) →
  `Simd(SAdd(I32x4))`; `i64x2.mul` (213, `0xD5 0x01`) → `Simd(SMul(I64x2))`. Proves both
  the multi-byte sub-opcode and shape disambiguation.
- **float lanes:** `f32x4.mul` (230) → `Simd(FMul(F32x4))`; `f64x2.pmin` (246) →
  `Simd(FPMin(F64x2))`; `f32x4.sqrt` (227) → `Simd(FSqrt(F32x4))`.
- **comparisons (order, §D.4):** `i32x4.eq` (55) → `Simd(SEq(I32x4))`; `f64x2.gt` (74) →
  `Simd(FGt(F64x2))` — asserting `gt` is 74, **not** `le`; `i64x2.lt_s` (216) →
  `Simd(SLtS(I64x2))`.
- **bitwise (order, §D.5):** `v128.andnot` (79) → `Simd(VAndNot)` (asserting 79, not
  `or`); `v128.bitselect` (82) → `Simd(VBitselect)`; `v128.any_true` (83) →
  `Simd(VAnyTrue)`.
- **narrow/widen/extend/dot/extmul/extadd/q15/popcnt:** one each —
  `i8x16.narrow_i16x8_s` (101), `i16x8.extend_low_i8x16_u` (137),
  `i32x4.dot_i16x8_s` (186), `i64x2.extmul_high_i32x4_u` (223),
  `i32x4.extadd_pairwise_i16x8_s` (126), `i16x8.q15mulr_sat_s` (130), `i8x16.popcnt`
  (98) → their named `SimdOp`s.
- **conversions:** `i32x4.trunc_sat_f32x4_s` (248) → `Simd(I32x4TruncSatF32x4S)`;
  `f64x2.promote_low_f32x4` (95) → `Simd(F64x2PromoteLowF32x4)`;
  `f32x4.demote_f64x2_zero` (94) → `Simd(F32x4DemoteF64x2Zero)`.
- **v128 memory (§D.1):** `v128.load` (0) with `align=4 offset=0` →
  `SimdLoad(Load128, MemArg(4,0,0))`; `v128.load8_splat` (7) → `SimdLoad(Load8Splat, …)`;
  `v128.load32x2_u` (6) → `SimdLoad(Load32x2U, …)`; `v128.load64_zero` (93) →
  `SimdLoad(Load64Zero, …)`; `v128.store` (11) → `SimdStore(…)`; a `(memory 1)` form →
  `MemArg.mem == 1`.
- **load/store lane (anti-swap, §E.4):** `v128.load8_lane` (84) with `align=0 offset=4
  lane=3` → `SimdLoadLane(8, MemArg(0,4,0), 3)`; `v128.store64_lane` (91) → the store
  form; a `(memory 1)` lane form → `MemArg.mem == 1` with the trailing lane still decoded.
- **memory64 regression (§F):** `(memory i64 1)` still → `MemType(Limits(1,None),
  Idx64)`; an i32 memory → `Idx32`.
- **neutrality:** the `add`/`mem`/`conv`/… Phase-1..5 fixtures decode **unchanged**
  (the `V128` constructor and `Simd*` nodes never appear).

### 2. Fail-closed fuzz on the SIMD surface (extend the battery)

Each returns a **specific `DecodeError`**, never a panic/`let assert`/loop:
- a `0xFD` reserved-gap sub-opcode (154, 162, 226, 238) → `UnknownSimdOpcode(sub)`;
- a `0xFD` relaxed-SIMD sub-opcode (`>= 256`, e.g. `0x80 0x02` = 256, `0xAC 0x02` = 300)
  → `UnknownSimdOpcode(sub)`;
- a `v128.const` (12) with fewer than 16 immediate bytes → `Truncated`;
- an `i8x16.shuffle` (13) with fewer than 16 lane bytes → `Truncated`;
- an `i8x16.extract_lane_s` (21) with the lane byte at EOF → `Truncated`;
- a `v128.load8_lane` (84) with the memarg present but the lane byte at EOF →
  `Truncated`;
- a `v128.load` (0) with a memarg whose bit-6 memidx flag is set but the memidx LEB is
  truncated → `Truncated`;
- a `0xFD` with a truncated (continuation-bit) sub-opcode LEB → `Truncated`; an
  over-wide sub-opcode LEB → `LebOverflow`/`LebTooLong`;
- a `v128` byte `0x7B` in a reftype-only position (tabletype element) → `BadHeapType`
  (unchanged), and in a valtype position (a `(param v128)`) → **accepted** as `V128`.
- **The single-byte-mutation + truncation sweep** over every new SIMD fixture always
  yields `Ok(_) | Error(DecodeError)` — the property is *totality*.
- Assert (grep in a test or by inspection) that `decode.gleam` contains no `let assert`,
  `panic`, or `todo`.

### 3. The opcode-map audit (spec-exhaustive)

A generated sweep over sub-opcodes `0..255` wrapped as a minimal `0xFD`-instruction body
asserts: **exactly the 236 listed sub-opcodes decode `Ok`** to the `SimdOp`/`Instr` §D
specifies, and **exactly the 20 gaps** (154; 162,165,166,175,176,178,179,180,187;
194,197,198,207,208,210,211,212; 226; 238) decode `UnknownSimdOpcode`. This is the
change-detector-proof form of §D: it is derived from the spec's opcode table, not from
the implementation, so a mis-transcribed opcode fails it.

### 4. Neutrality

The full Phase-1..5 decode fixture suite still decodes to the **same** AST (up to the
mechanical `ValType` widening — the `V128` constructor is simply never produced). `gleam
test` stays green (≥ the current count + the new tests). Embedded conformance numbers do
not regress (04/05 gate the new fixtures' downstream use).

### 5. Clean build & docs

`gleam format --check src test` clean; `gleam build` **zero warnings** (no leftover
`todo`/unused). Every new/changed public type, constructor, and function has a `///` doc
comment stating its contract, immediate order, accepted byte ranges, and failure modes
(D8).

### 6. `«WASM-AST4»` announced

In `state.md` the moment the types compile (day 1), listing: `ValType` gaining `V128`;
the new `SimdShape`, `SimdOp`, `SimdLoadKind` types; the seven SIMD `Instr` constructors
(`V128Const`, `Simd`, `I8x16Shuffle`, `SimdLoad`, `SimdStore`, `SimdLoadLane`,
`SimdStoreLane`); and the new `DecodeError` variant `UnknownSimdOpcode` — for 04/05.

**Spec citations to use in tests:** binary/types.html (the `v128 = 0x7B` valtype byte),
binary/instructions.html#binary-blocktype (the `-5` v128 blocktype),
binary/instructions.html#vector-instructions (the whole `0xFD` sub-opcode table — cite
the exact sub per fixture), binary/instructions.html#binary-laneidx (the single-byte
lane index; the 16-byte `v128.const`; the 16-byte shuffle), and
appendix/index-instructions.html (the authoritative opcode index for the §D audit).

## What this unit leaves for others

- **04 (validate)** consumes `«WASM-AST4»`: it types `v128` on the abstract stack, owns
  lane-index range (`extract/replace_lane l < 128/width`, shuffle indices `0..31`), the
  SIMD `memarg` alignment bound (`2^align <= N` per the §D.1/D.6 `N` column), the scalar
  operand types (splat's scalar, the i32 shift count, replace-lane's scalar), and rejects
  ill-typed modules fail-closed (`assert_invalid`). It also confirms the memory64 i64
  address typing composes with SIMD memory ops (mostly P5 work).
- **05 (lower)** maps AST4 → IR4: `ast.V128 → ir.TV128`; `V128Const(bytes) →
  ConstV128(bytes)`; `ast.Simd(op) → ir.Simd(ir_op, args)` relabelling `ast.SimdOp →
  ir.SimdOp` (near-identity — the taxonomies mirror); `I8x16Shuffle(lanes) →
  ir.SimdShuffle(lanes, a, b)`; the `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`
  family → the IR's SIMD-memory nodes (whatever the keystone froze — §Cross-unit). Lower
  is the adapter between this unit's AST-private `SimdOp` and the keystone's `ir.SimdOp`.
- **06 (emit_core)** routes each IR `SimdOp` to an `rt_simd` head and the SIMD-memory
  nodes through the bounds-checked `rt_mem` seam; it never sees this unit's `ast.SimdOp`.
- **07 (rt_simd)** implements the ~236 lane ops the §D opcodes name; the §D enumeration is
  the definitive list of what 07 must cover.
- **The WAT parser** (P5-10 `wat.gleam`, which currently returns `Unsupported(Simd)` for
  `v128.*` text) can be un-skipped in a P6 follow-on to target this same AST4 `Module`,
  so `wat_parse` and `decode` agree for validate/lower to serve unchanged.
- **10/11 (conformance)** source the newly-decodable `simd/*.wast` allowlist from this
  surface (the large SIMD file set: `simd_i32x4_arith`, `simd_f64x2`, `simd_load`,
  `simd_lane`, `simd_const`, `simd_bitwise`, …).

## Deviations from the provisional surface

Each is ARGUED for the critique + reconciliation to adjudicate.

- **D1 — the SIMD op enum is AST-private, not shared with the IR.** `PROVISIONAL-
  SURFACE.md` §§B–C place `SimdShape`/`SimdOp` in `ir.gleam` (owned by keystone P6-01).
  This unit defines **`ast.SimdShape`/`ast.SimdOp`/`ast.SimdLoadKind`** in `ast.gleam`,
  distinct from the IR's. **Why:** P5-03's frozen rule is that the WASM AST does **not**
  import `ir.gleam` — it is the frontend's private model, and every valtype/opcode is
  bridged to the IR by lower (exactly as `ast.I32Add` is a distinct constructor bridged
  to `ir.Num(IAdd(W32))`). A shared enum would force `ast.gleam` to depend on `ir.gleam`,
  breaking that layering. The cost is one relabel pass in lower (near-identity because
  the taxonomies mirror) — the same cost every scalar opcode already pays. This is a
  **refinement of "where the enum lives," not a change to the enum's shape** — my
  `ast.SimdOp` deliberately mirrors the provisional `ir.SimdOp` constructor names so 05
  is trivial. *(Reconciliation may instead choose a neutral `simd_op.gleam` module both
  `ast` and `ir` import, eliminating the duplication — see Open Q1.)*
- **D2 — lane index rides in the `SimdOp` constructor, not a dedicated `Instr`.** Matches
  `PROVISIONAL-SURFACE.md` §C (`SExtractLaneS(shape, lane)`), keeping `Instr`'s SIMD
  surface to seven constructors. The provisional §D also floated a dedicated
  extract/replace `Expr`; I do not add one — the op-field form is smaller and lower still
  reads the lane trivially.
- **D3 — seven `Instr` constructors, not ~236.** Ratifies I2 at the AST level (the
  provisional stated I2 for the IR; I make the AST match): the ~236 opcodes collapse to
  `V128Const` + `Simd(op)` + `I8x16Shuffle` + the four memory nodes. A flat 236-
  constructor `Instr` was considered and rejected — it would 8× the `Instr` type and
  force validate/lower into 236-arm matches with no benefit. *(This departs from the
  literal Phase-5 AST style of one-constructor-per-scalar-opcode; argued because the SIMD
  op count makes the flat style untenable and I2 already chose compact for the IR — Open
  Q2.)*
- **D4 — SIMD memory ops are dedicated AST nodes**, not extended `MemLoad`/`MemStore`
  access kinds. Matches the provisional's own recommended pick (§D open Q a): the scalar
  load/store `Instr`s carry a single typed `MemArg` and don't stretch to
  splat/extend/lane. `SimdLoad(kind, arg)` / `SimdStore(arg)` / `SimdLoadLane` /
  `SimdStoreLane` are the natural decode targets. The IR/emit side (06/07) may choose
  differently; lower bridges (§Cross-unit).
- **D5 — `SimdLoadKind` folds the splat/extend/zero widths into named constructors**
  (`Load8Splat`, `Load8x8S`, `Load32Zero`, …) rather than the provisional's parametric
  `Splat(width) | Extend(from_shape, signed) | Zero(width)`. **Why:** the fixed-width set
  has exactly these 14 loads; named constructors make the decode `case` and the validate
  `N`-width lookup total and unmistakable, and there is no open-ended width to
  parametrise. Trivially inter-convertible with the provisional shape if lower prefers
  the parametric form.
- **D6 — `V128Const` is its own `Instr`** (parallel to `F32Const`/`F64Const`), not a
  `Simd(op)` — a 16-byte immediate is structurally unlike a bare op, and this matches how
  the AST already carries scalar const immediates.
- **D7 — one new `DecodeError` (`UnknownSimdOpcode`).** The provisional expected "no new
  `TrapReason`" (correct — SIMD is total, and the memory trap reuses `MemoryOutOfBounds`).
  A *decode* error is different from a trap: an unassigned sub-opcode must be a typed
  malformed-decode error, and `UnknownSatOpcode` (0xFC) does not fit (wrong prefix). One
  variant, justified by the gap/relaxed-SIMD fuzz cases.

## Cross-unit seams (flag for reconciliation)

- **S-SIMDOP (03 ↔ 01/05).** `ast.SimdOp` (this unit) mirrors `ir.SimdOp` (keystone
  P6-01); lower (05) is the adapter. Reconciliation must pin **one** of: (a) keep them as
  parallel private mirrors (this doc's baseline — lower relabels), or (b) host a shared
  neutral `simd_op.gleam` both import (removes duplication, but adds a module + an
  ownership call). Either way, the keystone's `ir.SimdOp` must be able to express **all
  236** opcodes this unit's §D enumerates — **§D is the definitive opcode set** for the
  whole phase; if the keystone's taxonomy omits an op, it is wrong.
- **S-VT (03 ↔ 01/05).** `ast.V128` ↔ `ir.TV128`; lower maps; non-v128 modules stay
  byte-identical. 1:1 like `FuncRef`/`TFuncRef`.
- **S-SIMDMEM (03 ↔ 01/06/07).** The SIMD-memory node boundary. This unit's AST uses
  dedicated `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`. The IR side (keystone
  freezes; 06/07 implement) may use dedicated IR nodes or extended `MemLoad`/`MemStore`;
  lower (05) bridges either way. The invariant both sides must honor: **bounds-checked
  through `rt_mem`** (I6) — never a raw term op.
- **S-LANEWIDTH (03 ↔ 04/07).** The per-op natural access width `N` (§D.1/D.6) is decode
  metadata that validate (04) needs for `2^align <= N` and rt_simd (07) needs for the
  slice size. This doc pins `N` per op; 04/07 consume it. If reconciliation wants `N`
  materialised on the AST node (rather than re-derived from `SimdLoadKind`/`width`), that
  is a cheap field addition — flag.
- **S-LANEIDX (03 ↔ 04).** Decode stores lane indices raw (0..255); validate owns the
  range check (`< 128/width`; shuffle `0..31`). Confirm 04 applies it (the spec's
  `assert_invalid` lane cases).

## Open questions (for the planner / cross-unit sync)

- **Q1 — shared `simd_op.gleam` vs AST-private mirror.** I default to an AST-private
  `ast.SimdOp` (D1) to preserve P5-03's "AST does not import `ir.gleam`" rule. The
  alternative — a neutral `simd_op.gleam` (owned by the keystone) imported by both `ast`
  and `ir` — eliminates the duplication hazard the Phase-5 critique flagged (R1's "two
  units agree by coincidence"). It is a genuine ownership question: **does the keystone
  create a shared SIMD-op module, or do we accept the parallel-mirror + lower-adapter?**
  Recommend the mirror (smaller blast radius, matches every existing scalar opcode); flag
  for P6-01/P6-05.
- **Q2 — shape-tagged `SimdOp` vs flat per-shape constructors.** I shape-tag
  (`SAdd(SimdShape)`) per the provisional and NumOp precedent. A flat form (`I32x4Add`,
  …, ~236 constructors) is closer to the binary and needs no shape argument, but explodes
  the enum. Recommend shape-tagged; if reconciliation prefers flat for
  decode-transcription safety, the §D tables map 1:1 either way.
- **Q3 — `width` as `Int` vs an enum.** `SimdLoadLane`/`SimdStoreLane` carry `width: Int`
  (8/16/32/64) per the provisional. A `LaneWidth { W8 W16 W32 W64 }` enum would make the
  four values total and unmistakable at the cost of a new type. Recommend `Int` (matches
  the provisional; validate/rt_simd already switch on it); flag if 04/07 prefer the enum.
- **Q4 — `SimdLoadKind` naming.** Named constructors (D5) vs the provisional's parametric
  `Splat(width)|Extend(from,signed)|Zero(width)`. Recommend named (14 fixed variants, no
  open width); trivial to convert. Flag for 05/07's convenience.
- **Q5 — where the shuffle `0..31` range check lives.** I place it in validate (decode
  stores the 16 raw bytes). The spec frames an out-of-range shuffle index as
  `assert_invalid` (a *validation* error), so validate is correct; confirm 04 owns it and
  decode should **not** reject a `>= 32` lane byte. Flag for P6-04.
