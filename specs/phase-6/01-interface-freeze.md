# Unit 01 — Interface Freeze (Phase-6 keystone)

> **One owner. The spine of the phase. On the critical path of everything.** Read
> [`00-overview.md`](00-overview.md) (I1–I8) first, then
> [`PROVISIONAL-SURFACE.md`](PROVISIONAL-SURFACE.md), then the Phase-1…5 overviews
> (D1–D10 … R1–R18). Phase 6 is the **surface-completion / finishing** phase and the first
> since Phase 5 to **grow the IR** (I7). This unit freezes the **four** contracts the Phase-6
> swarm binds to — the **IR4 extension** (`«IR4-FROZEN»`: the `TV128` value type + the
> `ConstV128` value + the `SimdOp`/`SimdShape` enums + the SIMD `Expr` nodes + the SIMD-memory
> node decision + the effect classification + the `.ir` grammar delta), the **`rt_simd`
> signature heads** (`«RT-SIMD-SIG»`: the ~236 lane-op heads, doc-frozen, `todo`-free), the
> **memory64 runtime axis** (`«MEM64-RUNTIME»`: the `Binding` page-cap field + the "lower/link
> accept `Idx64`" contract), and the **cross-module function-dispatch capability**
> (`«XLINK»`: the `ProvidedFunc` closure-dispatch contract head) — and lands the IR extension
> **GREEN** (build compiles, `gleam test` passes, **zero warnings**) with defaults chosen so
> every Phase-1..5 module compiles **byte-identically** (I7).

The build is currently zero-warning with **1212 passing tests** (conformance **21525 pass /
1257 skip / 0 fail** under every shipped `(mode × state_strategy × mem_tier)` binding). **It
must stay that way after this unit.** Like the Phase-5 keystone (which grew `ValType`, `Value`,
`Expr`, `Module`, and five declaration/segment types), Phase 6 grows `ValType` (`TV128`),
`Value` (`ConstV128`), and `Expr` (six SIMD nodes). Because Gleam has no default field values
and every exhaustive `case` over these types must stay total, **growing `ValType`/`Value`/`Expr`
breaks every exhaustive match across `ir`/`printer`/`parser`/`effect`/`emit_core`/`lower`/
`ir_lower`/`ir_opt`** — plus the `Binding` field breaks every full `Binding(...)` constructor and
the `ProvidedFunc` field breaks its one match site. This unit **enumerates every one** (the reach
table below is load-bearing — treat it as the acceptance checklist, not a sketch), lands them all
green with byte-identical defaults, and **doc-freezes** the `rt_simd` signatures + the memory64
axis + the cross-module dispatch contract that units 02–11 implement — exactly the posture the
Phase-4/5 keystones took (frozen in prose, no `todo` stubs, so no new warnings).

The one structural difference from the Phase-5 keystone: **the SIMD lane ops are PURE, not
barriers.** Phase 5's new nodes were all effect barriers; Phase 6's pure lane-wise SIMD (`Simd`,
`SimdShuffle`) classify **`Pure` like `Num`** (they touch no state and cannot trap — I3), and only
the four SIMD-memory nodes are barriers. Getting that classification right is this unit's most
load-bearing semantic freeze.

---

## Context

Phases 1–5 built a correct, sandboxed, fast, runs-anywhere engine for the **complete standardized
WebAssembly surface *minus SIMD***: reference types, bulk memory & table ops, multiple memories,
non-function imports + `spectest`, a WAT text parser. Three things were deliberately deferred to
Phase 6 (stated, not dropped — overview §0):

1. **SIMD** — the `v128` value type + the ~236 standardized lane instructions. The IR has **no**
   `v128` type, **no** SIMD value, **no** SIMD op. `decode`/`validate`/`wat` all *categorize* a
   `v128`/`i8x16.*` construct as an explicit out-of-scope skip (`decode.gleam:520`,
   `validate.gleam:196`, `wat.gleam:2186/3561`) — never a silent mis-parse.
2. **The memory64 runtime** — the `IdxType`/`Idx64` axis is **frozen in the IR** (`ir.gleam:166`)
   and `decode`/`validate` accept a 64-bit memory (`decode.gleam:664`, `validate.gleam:674` types
   its `2^48`-page limit), but `lower` **rejects** it with `Error(Memory64Unsupported)`
   (`lower.gleam:270`) — the runtime was deferred (R12).
3. **Cross-module wasm→wasm function linking** — `link.gleam` **matches** a `ProvidedFunc(ty)`
   signature (`link.gleam:354`) but carries **no dispatch capability**: generated code cannot
   *call* a function that lives in another instance.

Phase 6 closes all three. Like Phase 5, it grows the IR — kept **language-neutral** (I7: a generic
128-bit fixed-width value + generic lane ops, not WASM opcodes; the generic `IdxType` axis already
in the IR; a generic provided-function capability) and **conformance-neutral by default** (a
Phase-1..5 module still compiles byte-identically under every mode × state-strategy × mem-tier).
All of that begins here, in the IR4 shapes, the `rt_simd` signatures, the memory64 field, and the
cross-module dispatch contract the rest of the phase is written against.

The provisional surface ([`PROVISIONAL-SURFACE.md`](PROVISIONAL-SURFACE.md)) proposed the exact
names and shapes; **this unit adopts them nearly verbatim**, with two argued refinements (the
tagged widen/extend/extmul/pairwise families in §B and the confirmed dedicated SIMD-memory nodes in
§C) recorded in "Deviations from the provisional surface" so the critique + reconciliation can
adjudicate.

## Goal

Freeze `«IR4-FROZEN»` / `«RT-SIMD-SIG»` / `«MEM64-RUNTIME»` / `«XLINK»`, land the IR4 extension green
and byte-identical, and prove the default-neutrality claim: a module with **no `v128`**, **no SIMD
op**, a **single 32-bit memory**, and **no cross-module imports** emits **byte-identical `.core`** to
Phase-5, under both state strategies and every shipped memory tier. Nothing in the Phase-1..5
acceptance corpus or the previously-passing spec suite may move by one atom.

## Files owned (single-owner / additive per D1)

| File | Ownership | This unit's change |
|---|---|---|
| `src/twocore/ir.gleam` | **owner-additive** | The whole IR4 surface: `ValType.TV128`; `Value.ConstV128`; `SimdShape`; `SimdHalf`; `SimdOp`; `SimdLoadKind`; the six SIMD `Expr` nodes (`Simd`/`SimdShuffle`/`SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`); `TrapReason` **unchanged** (reuse — §E). |
| `src/twocore/ir/effect.gleam` | **owner-additive** | Real classification (§D): `Simd`/`SimdShuffle` are **non-barriers → `Pure`** (like `Num`); the four SIMD-memory nodes are **barriers → `Effectful`**. Update the import list. Not a stub. |
| `src/twocore/runtime/rt_simd.gleam` | **NEW — owner** | The ~236 lane-op **signature heads** (§G), doc-frozen, `todo`-free, with fail-loud placeholder bodies (`panic`) that unit 07 replaces. No imports (the signatures need only prelude types). |
| `src/twocore/runtime/instance.gleam` | **owner-additive** | The `Binding.mem64_max_pages` field (§H) + `safe_default` sets it; doc updates. |
| `src/twocore/runtime/link.gleam` | **owner-additive** | The `ProvidedFunc` closure-dispatch **contract head** (§I): add the `call` closure field; update the one match site. The linker that *builds* the closures + the function `link_imports` extension are P6-09. |
| `src/twocore/ir/printer.gleam` | **land-green reach** (full impl → P6-02) | Minimal compile-satisfying arms for `TV128`/`ConstV128`/the six SIMD nodes so `.ir` printing stays total; byte-identical for the existing surface. |
| `src/twocore/ir/parser.gleam` | **land-green reach** (full impl → P6-02) | Minimal arms for the new value type / value / mnemonics (string-dispatch, so not a hard break; add just enough for the freeze-test round-trip). |
| `src/twocore/backend/emit_core.gleam` | **land-green reach** (full impl → P6-06) | Compile-satisfying arms: `TV128` in the valtype matches; `ConstV128` in `emit_value`; **one `Error(UnsupportedNode(node))` arm per SIMD `Expr` node**. Byte-identical existing output preserved. §J. |
| `src/twocore/frontend/wasm/lower.gleam` | **land-green reach** (full impl → P6-05) | `TV128`/`ConstV128` arms in `zero_value`/`value_type`. This unit makes it **compile & byte-identical**; P6-05 fills the real SIMD lowering + the memory64 `Idx64` acceptance. |
| `src/twocore/middle/ir_lower.gleam` | **land-green reach** (this unit) | Add the six SIMD nodes to the leaves arm (`Ok(expr)` — they carry only `Value` operands). |
| `src/twocore/middle/ir_opt/pass.gleam` | **land-green reach** (this unit) | Add the six SIMD nodes to `map_expr`'s leaves arm (`-> e`). |
| `src/twocore/runtime/profiles.gleam` | **land-green reach** (this unit) | The full `Binding(...)` constructors (`unsafe()`/`ceiling()`/…) gain `mem64_max_pages`. |
| Test corpus | **land-green reach** (this unit) | Every **full** `Binding(...)` constructor + the freeze test. `..spread` constructors absorb the field automatically. |

**Seam-doc only (frozen in this doc, implemented by the named unit):** `rt_simd` bodies (§G — unit
07); `rt_mem` memory64 addressing + the exact page-cap constant (§H — unit 08); the linker-built
closure + function `link_imports` (§I — unit 09); the `.ir` grammar delta (§F — unit 02); the
`frontend/wasm/ast.gleam` SIMD AST + `decode`/`validate`/`lower` SIMD pipeline (units 03/04/05).
This unit does **not** claim those files.

## Deliverables & freeze milestones

1. **`«IR4-FROZEN»`** — `ir.gleam` (all of §A–§E) + `ir/effect.gleam` (§D) landed green +
   byte-identical defaults; the `.ir` grammar delta **sketched** here (§F, owned + reconciled by
   P6-02). Unblocks **02, 03, 04, 05, 06, 07, 10, 11**.
2. **`«RT-SIMD-SIG»`** — the `runtime/rt_simd.gleam` public heads (§G), doc-frozen and `todo`-free
   (fail-loud placeholder bodies, never `todo`), so 06/07 implement bodies / the emit mapping
   without racing signatures. Unblocks **06, 07**.
3. **`«MEM64-RUNTIME»`** — the `Binding.mem64_max_pages` field (§H) + the "lower/link accept `Idx64`"
   contract (frozen in prose; the reject-removal is P6-05/09). Unblocks **05, 08**.
4. **`«XLINK»`** — the `ProvidedFunc` closure-dispatch contract head (§I): the `call` field + the
   `apply(Closure, Args)` dispatch model + the D3a cleanliness rule. Unblocks **06, 09**.

**Out of scope for this unit:** any SIMD decode/validate/lower logic (03/04/05); the real SIMD
codegen (06); the `rt_simd` bodies (07); the memory64 `rt_mem` addressing + the exact page cap (08);
the linker/registry (09); the conformance expansion (10/11). This unit ships the IR4 types (real,
total, zero `todo`) + the frozen runtime signatures + the memory64 field + the cross-module
contract head + the land-green reach + a scratch freeze test.

## Depends on (freeze milestones)

None upstream — this is Wave-0, the keystone. It consumes the Phase-5 `ir.gleam`/`Binding`/`link`
shapes (already green) and freezes on top of them.

---

## Land-green cross-file reaches (enumerate EVERY one)

Growing `ValType` (`TV128`), `Value` (`ConstV128`), and `Expr` (six SIMD nodes) breaks every
exhaustive `case` over these types. The `Binding` field breaks every **full** `Binding(...)`
constructor (the `..spread` ones absorb it). The `ProvidedFunc` field breaks its one match site.
Each row **must** be landed for the tree to stay green; the "full impl" column names the unit that
later replaces a minimal arm with the real one.

| # | File · symbol (line at freeze) | What breaks | Land-green edit (this unit) | Full impl |
|---|---|---|---|---|
| 1 | `ir.gleam` | owner-additive | Add everything in §A–§D. `TrapReason` unchanged (§E). | — |
| 2 | `ir/effect.gleam` · `is_effectful_node` (`:82`) + import (`:47`) | exhaustive `Expr` `case` | Add `Simd(_,_)`/`SimdShuffle(_,_,_)` to the **`False`** (non-barrier) group; add the four SIMD-memory nodes to the **`True`** (barrier) group; import all six. **Real classification (§D).** | — (this unit) |
| 3 | `ir/printer.gleam` · `print_valtype` (`:434`), `print_value` (`:462`), `print_expr` (`:508`) | 3 exhaustive `case`s | `TV128 -> "v128"`; `ConstV128(bytes) -> "v128.const 0x"<>hex`; one arm per SIMD `Expr` node (any spelling — conformance-neutral, no legacy module has them). Byte-identical existing surface. | **P6-02** |
| 4 | `ir/parser.gleam` · `parse_valtype` (`:1104`), `parse_value` (`:1136`), `parse_expr` (`:1192`) | string-dispatch (NOT a hard break) | Add `"v128" → TV128`, `"v128.const" → ConstV128`, and minimal SIMD mnemonic arms so the freeze-test round-trip parses. | **P6-02** |
| 5 | `backend/emit_core.gleam` · `result_width` (`:1568`), `valtype_atom` (`:2908`), `emit_value` (`:2821`), `emit` dispatch (`:833`) | 3 exhaustive `case`s + the `Expr` dispatch | `TV128 -> 128` / `"v128"`; `ConstV128(bytes) -> <Core binary literal>`; **one `Error(UnsupportedNode("simd_*"))` arm per SIMD `Expr` node**. Byte-identical existing output. §J. | **P6-06** |
| 6 | `frontend/wasm/lower.gleam` · `zero_value` (`:1850`), `value_type` (`:1942`) | 2 exhaustive `case`s | `TV128 -> ConstV128(<<0:128>>)`; `ConstV128(_) -> TV128`. Compile & byte-identical; P6-05 fills the real SIMD lowering. (`to_ir_valtype` matches **ast** valtype — ast unchanged here, so not broken; P6-03 grows ast.) | **P6-05** |
| 7 | `middle/ir_lower.gleam` · `lower_expr` (`:174`) | exhaustive `Expr` `case` | Add the six SIMD nodes to the **leaves** arm (`Ok(expr)`) — they carry only `Value` operands, so this CallHost-gate/Loop-meter pass leaves them unchanged. | — (this unit) |
| 8 | `middle/ir_opt/pass.gleam` · `map_expr` (`:100`) | exhaustive `Expr` `case` | Add the six SIMD nodes to the **leaves** arm (`-> e`) — they carry only `Value` operands (no sub-`Expr`); a pass rewriting their operands does so in its own per-node arm, not here. | — (this unit) |
| 9 | `instance.gleam` · `Binding` type (`:236`) + `safe_default` (`:272`) | the record type + one full constructor | Add `mem64_max_pages: Int` to the record; `safe_default` sets the provisional (§H). | — (this unit) |
| 10 | `runtime/profiles.gleam` · full `Binding(...)` at `:188`, `:366`, `:393` | full constructors | Add `mem64_max_pages: <val>` to each. (`Binding(..safe(), …)` spreads at `:99/:121/:153` absorb it automatically.) | — (this unit) |
| 11 | `runtime/link.gleam` · `ProvidedFunc` type (`:100`) + `resolve_fn_import` (`:354`) | the type + one match | Add `call: fn(List(Dynamic)) -> Dynamic`; update `Ok(ProvidedFunc(sig, _)) -> match_fn(…)` (matching uses only `ty`). §I. | **P6-09** |
| 12 | Test corpus | full `Binding(...)` at `emit_core_security_test.gleam:339/:574`, `profiles_test.gleam:510`; the `ProvidedFunc(..)` match at `link_test.gleam:383` (uses `..`, unaffected) | Add `mem64_max_pages` to the full constructors. `..spread` sites unaffected. | mixed |

**The four shape changes that break constructors/matches everywhere** (call them out — they are the
bulk of the diff):

- **`ValType` gains `TV128`** breaks `print_valtype`, `result_width`, `valtype_atom`, `zero_value`
  (four exhaustive `ValType` matches with **no catch-all**). `is_reference_type` (`emit_core:666`)
  and every other `ValType` match with a `_` catch-all is **unaffected** (v128 correctly falls to
  the default — it is not a reference type).
- **`Value` gains `ConstV128(bytes: BitArray)`** breaks `print_value`, `emit_value`, `value_type`
  (three exhaustive `Value` matches with no catch-all). The const-fold helpers that pattern-match
  `Values([ConstNull(_)])`/`ConstNull(_)` (`emit_core:2555/3332/4095`) have `_` catch-alls → a
  `ConstV128` falls to the "not a const-foldable-here" default (correct; P6-06 adds the v128
  const-fold arms).
- **`Expr` gains six SIMD nodes** breaks the six exhaustive `Expr` matches: `print_expr`,
  `emit`-dispatch, `is_effectful_node`, `lower_expr`, `map_expr`, **and** the effect
  `children_all_pure` (`_` catch-all → unaffected). `parse_expr` and `expr_touches_state`
  (`emit_core:751`, `_` catch-all) are string/catch-all dispatch → **not** hard breaks, but see §D/§J
  for the semantic arms P6-06 must add to `expr_touches_state`.
- **`Binding` gains `mem64_max_pages: Int`** breaks the ~5 full `Binding(...)` constructors; the
  ~30 `Binding(..spread, …)` sites absorb it. **`ProvidedFunc` gains `call`** breaks its one match.

Announce all four milestones in `state.md` with this reach list, exactly as the Phase-2/3/4/5
keystones did.

---

## A. `«IR4-FROZEN»` — the `v128` value type & literal (I1/I2)

### A.1 `ValType` gains one constructor

```gleam
pub type ValType {
  TI32  TI64  TF32  TF64  TTerm  TFuncRef  TExternRef
  /// A 128-bit fixed-width low-level value (`v128`, I1/I2). Represented at runtime as a
  /// 16-byte binary (`<<_:128>>`) — the natural BEAM fixed-width byte container (the BEAM has
  /// no 128-bit scalar), consistent with how linear-memory bytes are already handled. NEUTRAL:
  /// a generic 128-bit vector value, not a WASM-only construct (I7) — a future SIMD-capable
  /// frontend reuses it. On the **low-level (numeric) path**, never the term layer (I2): no
  /// implicit bridging to terms (only an explicit boxing `Convert` bridges, as for i32/i64).
  TV128
}
```

Spec anchor: `v128` is the sole vector type; `vectype = v128 ⊆ valtype`
([spec §2.3.2 vector types](https://webassembly.github.io/spec/core/syntax/types.html#vector-types),
[§4.2.1 values](https://webassembly.github.io/spec/core/exec/runtime.html)). Binary `v128 = 0x7B`
(the exact byte is **P6-03**'s decode freeze; the IR is opcode-neutral, D6 — cited only as the
surface this constructor models; `decode.gleam:520` currently rejects it as `BadValType`).

### A.2 `Value` gains the v128 literal — the raw 16 bytes (D5-style)

```gleam
pub type Value {
  Var(name: String)
  ConstI32(bits: Int)  ConstI64(bits: Int)  ConstF32(bits: Int)  ConstF64(bits: Int)
  ConstNull(ty: RefType)
  /// The `v128.const` literal — EXACTLY 16 raw bytes in **little-endian lane layout** (D5:
  /// store the bits, never a decoded lane structure, so every lane value, NaN payload, and
  /// `-0.0` is bit-exact). A `BitArray` of length 16; two equal byte sequences compare `==`
  /// (BEAM binary equality), so v128 constants const-fold / dedup like the other `Const*`.
  /// Pure (it is a `Value`). Invariant (validate/lower/emit uphold it): `bit_size(bytes) == 128`.
  ConstV128(bytes: BitArray)
}
```

**Runtime representation (the load-bearing decision).** A `v128` value at runtime is a **16-byte
binary** `<<_:128>>`. Lane decode/encode is bit-syntax with explicit little-endian widths
(`<<a:32/little, b:32/little, c:32/little, d:32/little>>` for `i32x4`), matching D5 (floats/v128 as
raw bit patterns) and the linear-memory byte convention. `emit_value(ConstV128(bytes))` lowers to a
Core Erlang **binary literal** carrying those 16 bytes verbatim (§J). This is the analogue of
`ConstF32(bits)`'s raw-bit representation, one level wider.

Why bytes, not a decoded lane tuple: the same reasoning as D5 for floats — a decoded structure
cannot preserve every NaN payload / `-0.0` / signed-zero across the lane shapes, and the BEAM has no
128-bit scalar. Bytes are exact, cheap to slice, and route through `rt_mem` unchanged.

Spec anchor: `v128.const` carries **16 immediate bytes**
([spec §5.4.9 vector instructions](https://webassembly.github.io/spec/core/binary/instructions.html#vector-instructions)).
Binary `0xFD 12` (P6-03's freeze).

---

## B. `«IR4-FROZEN»` — the `SimdOp` enum (I2)

Just as the ~90 `rt_num` functions hide behind the small `NumOp`/`ConvOp` enums carried by
`Num`/`Convert`, the ~236 SIMD instructions hide behind a **`SimdOp` enum** carried by a **few**
`Expr` nodes (§C). `emit_core` (P6-06) maps each `(SimdOp[, shape])` to a concrete `rt_simd`
function — the binding chokepoint, exactly like `NumOp → rt_num`. The design discipline (matching
`NumOp`): **shape-tag the uniform ops** (one constructor for all applicable lane shapes, like
`IAdd(IntWidth)`); **name the genuinely-singular ops** (like `ConvOp.I32WrapI64`); and **tag the
uniform-over-a-parameter families** (widen/extend/extmul/pairwise) rather than spell out every
opcode string (a D6 refinement of the provisional — argued in "Deviations").

### B.1 Lane-shape and half tags

```gleam
/// The six standardized SIMD lane shapes (spec §2.3.2 / §4.4.2). Carried by shape-uniform
/// `SimdOp` constructors the way `IntWidth` is carried by `NumOp`. Integer shapes
/// (`I8x16`/`I16x8`/`I32x4`/`I64x2`) serve the integer ops; float shapes (`F32x4`/`F64x2`) the
/// float ops. A shape's lane bit-width is `128 / lane_count`: I8x16→8, I16x8→16, I32x4→32,
/// I64x2→64, F32x4→32, F64x2→64.
pub type SimdShape {
  I8x16  I16x8  I32x4  I64x2  F32x4  F64x2
}

/// Which half of a source vector a widening/extending op consumes (`extend`, `extmul`). `Low`
/// selects lanes `0 .. n/2-1`, `High` selects `n/2 .. n-1` of the source, each promoted to the
/// double-width result shape. Neutral (a generic half-selector, not a WASM opcode string — D6).
pub type SimdHalf {
  Low  High
}
```

### B.2 `SimdOp` — the complete taxonomy (~80 constructors → ~214 concrete `rt_simd` heads)

> Not every `(op, shape)` pair is legal — e.g. there is no `i8x16.mul`, no `i64x2` min/max, `i64x2`
> comparisons are `eq/ne/lt_s/gt_s/le_s/ge_s` only, `avgr_u` is `i8x16`/`i16x8` only, `add_sat`/
> `sub_sat` are `i8x16`/`i16x8` only, `popcnt` is `i8x16` only. The enum is **permissive** (the
> shape-tag admits illegal combos, exactly as `Num(IAdd(W32))` admits a nonsensical width elsewhere);
> **`validate` (P6-04) rejects the illegal combinations fail-closed**, and `emit_core` (P6-06) only
> has a `rt_simd` mapping for the legal ones. The legality table below is normative for 04/06.

```gleam
pub type SimdOp {
  // ── lane-uniform integer arithmetic (shape ∈ integer shapes) ─────────────────
  SAdd(SimdShape)   SSub(SimdShape)   SMul(SimdShape)          // SMul illegal for I8x16
  SNeg(SimdShape)   SAbs(SimdShape)
  SAddSatS(SimdShape)  SAddSatU(SimdShape)                     // I8x16/I16x8 only
  SSubSatS(SimdShape)  SSubSatU(SimdShape)                     // I8x16/I16x8 only
  SMinS(SimdShape)  SMinU(SimdShape)  SMaxS(SimdShape)  SMaxU(SimdShape)   // I8x16/I16x8/I32x4
  SAvgrU(SimdShape)                                            // I8x16/I16x8 only
  SShl(SimdShape)   SShrS(SimdShape)  SShrU(SimdShape)         // shift by scalar i32, masked mod lane width
  SPopcnt(SimdShape)                                           // I8x16 only
  // ── lane-uniform comparisons → a v128 mask (all-ones / all-zeros per lane) ───
  SEq(SimdShape)  SNe(SimdShape)
  SLtS(SimdShape) SLtU(SimdShape) SLeS(SimdShape) SLeU(SimdShape)   // U illegal for I64x2
  SGtS(SimdShape) SGtU(SimdShape) SGeS(SimdShape) SGeU(SimdShape)   // U illegal for I64x2
  // ── v128 bitwise (shape-agnostic — operate on the whole 128 bits) ────────────
  VNot  VAnd  VOr  VXor  VAndNot  VBitselect
  // ── boolean reductions / mask ────────────────────────────────────────────────
  VAnyTrue                                                     // over the whole v128 → i32 0/1
  SAllTrue(SimdShape)   SBitmask(SimdShape)                    // integer shapes → i32
  // ── lane access / build (immediates ride as fields) ──────────────────────────
  SSplat(SimdShape)                                            // scalar → v128 (all lanes = scalar)
  SExtractLane(shape: SimdShape, lane: Int)                    // I32x4/I64x2/F32x4/F64x2 (full lane)
  SExtractLaneS(shape: SimdShape, lane: Int)                   // I8x16/I16x8 (sign-extend to i32)
  SExtractLaneU(shape: SimdShape, lane: Int)                   // I8x16/I16x8 (zero-extend to i32)
  SReplaceLane(shape: SimdShape, lane: Int)                    // v128 + scalar → v128
  // ── float-lane ops (shape ∈ F32x4/F64x2) ─────────────────────────────────────
  FAdd(SimdShape) FSub(SimdShape) FMul(SimdShape) FDiv(SimdShape)
  FNeg(SimdShape) FAbs(SimdShape) FSqrt(SimdShape)
  FMin(SimdShape) FMax(SimdShape) FPMin(SimdShape) FPMax(SimdShape)
  FCeil(SimdShape) FFloor(SimdShape) FTrunc(SimdShape) FNearest(SimdShape)
  FEq(SimdShape) FNe(SimdShape) FLt(SimdShape) FLe(SimdShape) FGt(SimdShape) FGe(SimdShape)
  // ── widen / narrow / extended-multiply / pairwise (tagged — see Deviations) ──
  SNarrow(from: SimdShape, signed: Bool)                       // I16x8→I8x16, I32x4→I16x8 (saturating)
  SExtend(from: SimdShape, half: SimdHalf, signed: Bool)       // I8x16→I16x8, I16x8→I32x4, I32x4→I64x2
  SExtMul(from: SimdShape, half: SimdHalf, signed: Bool)       // same source shapes as SExtend
  SExtAddPairwise(from: SimdShape, signed: Bool)               // I8x16→I16x8, I16x8→I32x4
  // ── conversions (genuinely singular — named like ConvOp) ─────────────────────
  STruncSatF32x4S   STruncSatF32x4U                            // f32x4 → i32x4 (saturating, never traps)
  STruncSatF64x2SZero  STruncSatF64x2UZero                     // f64x2 → i32x4 (upper two lanes = 0)
  SConvertF32x4I32x4S  SConvertF32x4I32x4U                     // i32x4 → f32x4
  SConvertF64x2LowI32x4S  SConvertF64x2LowI32x4U               // low two i32x4 lanes → f64x2
  SDemoteF64x2Zero                                             // f64x2 → f32x4 (upper two lanes = 0)
  SPromoteLowF32x4                                             // low two f32x4 lanes → f64x2
  // ── dot / q15 (singular) ─────────────────────────────────────────────────────
  SDotI16x8S                                                   // i16x8·i16x8 → i32x4 (pairwise mul-add)
  SQ15MulrSatS                                                 // i16x8 fixed-point rounding mul, saturating
  // ── byte swizzle (dynamic; shuffle is a dedicated Expr node — §C) ────────────
  SSwizzle                                                     // i8x16 dynamic byte select; OOB index → 0
}
```

`SimdOp` is **width-and-lane-tagged and neutral** (never a WASM opcode string — D6), the same
discipline as `NumOp`. The lane immediates on `SExtractLane*`/`SReplaceLane` are **static
immediates** (the `.wast` `i32x4.extract_lane 2` form); `i8x16.shuffle`'s 16 immediates ride on the
dedicated `SimdShuffle` node (§C). Binary sub-opcodes (`0xFD` prefix + a LEB128 sub-opcode 0..255)
are **P6-03's freeze**; enumerated in §G as the surface each `rt_simd` head models.

### B.3 Per-lane semantics (held to the spec, not the implementation — I3)

`rt_simd` (P6-07) implements each op by **decode** the operand binary(ies) into lanes, **apply** the
per-lane op **reusing `rt_num`'s exact scalar semantics**, **re-encode**. The invariants the freeze
pins (07 must honour, 04/06 must not contradict):

- **Integer lanes wrap two's-complement at the *lane* width** (8/16/32/64), never 128-bit. `SShl`/
  `SShrS`/`SShrU` take a **scalar i32 shift count masked mod the lane bit-width** (`count &
  (lane_bits-1)`), reusing `rt_num`'s `shift_count`. Signed/unsigned min/max/compare/narrow per lane.
- **Comparisons yield a per-lane mask**: all-ones (`-1` in the lane) if true, all-zeros if false
  (spec §4.4 relaxed to the SIMD lane-wise rule). `VAnyTrue → i32 0/1` over the whole 128 bits;
  `SAllTrue(shape) → i32 0/1` (all lanes non-zero); `SBitmask(shape) → i32` (the high bit of each lane).
- **Saturating ops saturate exactly, never trap** (`SAddSat*`, `SSubSat*`, `SNarrow`, `SQ15MulrSatS`,
  `STruncSat*`) — I3: saturation *replaces* the overflow trap. `SAvgrU` is the rounding unsigned
  average `(a + b + 1) >> 1` at lane width.
- **Float lanes are IEEE-754** with **f32x4 rounded to single precision after every op** (reusing
  `rt_num`'s f32 single-rounding), `FMin`/`FMax` returning the **spec NaN / `-0.0`** result, `FPMin`/
  `FPMax` the pseudo-min/max variants (return the second operand when either is NaN, no `-0.0`
  special-casing), and **NaN canonicalization/propagation per the SIMD spec** (which mirrors scalar —
  `rt_num`'s canonical-NaN lock). `FSqrt`/`FCeil`/`FFloor`/`FTrunc`/`FNearest` are the exact IEEE
  round variants. Conversions (`STruncSat*`/`SConvert*`/`SDemote*`/`SPromote*`) are exact.
- **SIMD ops do NOT trap** (I3). The *only* trap on the SIMD surface is the **memory-bounds trap on a
  SIMD load/store** (§C/§E), via the existing bounds-checked `rt_mem` path.

Spec anchors: the fixed-width SIMD instruction semantics
([spec §4.4 vector instructions](https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions),
[§2.4.2 vector instruction syntax](https://webassembly.github.io/spec/core/syntax/instructions.html#vector-instructions)),
`i16x8.q15mulr_sat_s` fixed-point rounding, `pmin`/`pmax` pseudo-min/max, the lane-wise NaN rule.

---

## C. `«IR4-FROZEN»` — the SIMD `Expr` nodes (I2, the SIMD-memory decision)

Six new `Expr` variants. Two are **pure** (lane-wise ops); four are **effect barriers** (SIMD
memory). Added to `Expr`:

```gleam
// ── pure lane-wise SIMD (PURE — no trap, no state; classify like Num, §D) ──────
/// A pure lane-wise SIMD op. `args` arity matches `op` (1 unary, 2 binary, 3 for `VBitselect`;
/// `SSplat` takes a scalar i32/i64/f32/f64-bits value; `SExtractLane*` yields a scalar; `SReplaceLane`
/// takes v128 + scalar). Yields a `v128` (or an i32/i64/f32/f64-bits scalar for extract-lane /
/// `VAnyTrue` / `SAllTrue` / `SBitmask`). PURE (no trap, no state) — participates in const-fold /
/// DCE / CSE exactly like `Num` (I3, §D). `emit_core` (P6-06) maps `op` → an `rt_simd` fn.
Simd(op: SimdOp, args: List(Value))
/// `i8x16.shuffle` — 16 immediate lane indices (each 0..31), selecting bytes from `a ++ b`
/// (indices 0..15 pick from `a`, 16..31 from `b`). Kept a DEDICATED node (not a `Simd` variant)
/// because its 16-element immediate does not fit the uniform `SimdOp` shape. PURE. Yields a v128.
SimdShuffle(lanes: List(Int), a: Value, b: Value)

// ── SIMD memory (route through the bounds-checked rt_mem seam — BARRIERS, §D) ──
/// `v128.load` and the splat/extend/zero load family. `kind` (a `SimdLoadKind`) selects the exact
/// form. Effective address is `addr + offset` (offset a static immediate ≥ 0) on memory `mem`.
/// **Bounds-checked → traps `MemoryOutOfBounds`** on OOB, before any partial effect (I6). Yields a
/// v128. NOT pure. (`mem` default 0; a single-memory module keeps `mem = 0`.)
SimdLoad(mem: Int, kind: SimdLoadKind, addr: Value, offset: Int)
/// `v128.store` — write the 16-byte `value` to memory `mem` at `addr + offset`. **Bounds-checked →
/// traps `MemoryOutOfBounds`.** NOT pure.
SimdStore(mem: Int, addr: Value, value: Value, offset: Int)
/// `v128.loadN_lane` — load `width` bits (8/16/32/64) from memory `mem` at `addr + offset` into
/// lane `lane` of `vec` (the other lanes preserved). **Bounds-checked → traps.** Yields a v128.
SimdLoadLane(mem: Int, width: Int, addr: Value, offset: Int, lane: Int, vec: Value)
/// `v128.storeN_lane` — store lane `lane` (`width` bits) of `vec` to memory `mem` at `addr + offset`.
/// **Bounds-checked → traps.** NOT pure.
SimdStoreLane(mem: Int, width: Int, addr: Value, offset: Int, lane: Int, vec: Value)
```

```gleam
/// The v128 memory-load family (spec §5.4.9). Distinguishes the load forms `SimdLoad` carries:
/// - `LoadV128`: a plain 16-byte load.
/// - `LoadSplat(lane_bits)`: load `lane_bits` (8/16/32/64) and splat to all lanes.
/// - `LoadExtend(source_bits, signed)`: load 8 bytes as `source_bits`-wide lanes (8/16/32 → 8/4/2
///   lanes) and sign/zero-extend each to double width (`load8x8`/`load16x4`/`load32x2`).
/// - `LoadZero(lane_bits)`: load `lane_bits` (32/64) into the low lane, zero the rest.
pub type SimdLoadKind {
  LoadV128
  LoadSplat(lane_bits: Int)
  LoadExtend(source_bits: Int, signed: Bool)
  LoadZero(lane_bits: Int)
}
```

### C.1 The SIMD-memory node decision (Open Q **a** — resolved: **dedicated nodes**)

The provisional offered two options: extend `MemLoad`/`MemStore` with new access kinds, **or**
dedicated `SimdLoad*`/`SimdStore*` nodes. **The keystone freezes DEDICATED nodes.** Rationale
(argued so 03/06/07 agree, and so the reconciliation can ratify):

1. **Byte-identity of the existing memory nodes (I7/H7).** `MemLoad(mem, op, addr, offset, result)`
   and `MemStore(mem, op, addr, value, offset)` stay **exactly** their Phase-5 shape. If the v128
   family rode inside them, every existing `MemLoad`/`MemStore` match (`emit_core`, `printer`,
   `ir_lower`, `ir_opt`, `effect`, the whole conformance corpus) would have to reason about a v128
   result-type / a splat/extend/lane immediate — a change that risks a byte-diff on a plain
   `i32.load`. Dedicated nodes keep the scalar memory path **untouched**.
2. **The shapes do not fit.** `MemLoad`'s `result: ValType` + `MemAccess(bytes, signed)` cannot
   express `load8x8_s` (8 sub-lanes, each extended), `load32_zero` (low-lane + zero), or the
   `lane`/`vec` operands of `loadN_lane` without stretching `MemAccess` into a tagged union — at
   which point it *is* a dedicated kind, just spelled inside `MemLoad`.
3. **The bounds-check invariant is identical either way** (I6): P6-06 emits every `SimdLoad*`/
   `SimdStore*` as a **compose of the bounds-checked `rt_mem` seam** (load/store the 16-byte — or
   N-byte for splat/lane/zero/extend — slice through `rt_mem`, which owns the bounds check → trap
   `MemoryOutOfBounds`) **plus** a pure `rt_simd` lane-assembly helper (§G.3). `rt_mem` owns the
   check; `rt_simd` owns the pure assembly. No raw term op; D3a/I6 hold.

**Alignment** is a decode/validate concern (validate checks `align ≤ natural`), **not** carried in
the IR — exactly as the existing `MemAccess` carries no alignment (it is a runtime no-op; the BEAM
binary access is unaligned-safe). P6-04 validates lane immediates in range (`lane < lane_count` for
the shape/width) and shuffle indices `0..31`.

Spec anchors: the v128 memory instructions and their memarg + lane immediates
([spec §5.4.9](https://webassembly.github.io/spec/core/binary/instructions.html#vector-instructions),
[§4.4.7 vector memory](https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions));
little-endian lane layout ([spec §4.4 — vectors are little-endian in memory]).

---

## D. `«IR4-FROZEN»` — effect classification (owner: this unit, REAL not stub)

`ir/effect.gleam` is the optimizer's soundness floor (E6/F3): anything not *proven* pure defaults to
`Effectful`. **This is the one place Phase 6 diverges structurally from the Phase-5 keystone** —
Phase 5's new nodes were all barriers; Phase 6's pure lane-wise SIMD are **`Pure` like `Num`**:

| Node | `is_effectful_node` | `classify` | Why |
|---|---|---|---|
| `Simd(op, args)` | **`False`** | **`Pure`** | No SIMD lane op reads/writes state or traps (I3). Carries only `Value` operands (no sub-`Expr`), so it is atomic → `classify` = `Pure`. Participates in const-fold / DCE / CSE exactly like a non-trapping `Num`. |
| `SimdShuffle(lanes, a, b)` | **`False`** | **`Pure`** | Same — a pure byte permutation over two `Value` operands. |
| `SimdLoad(..)` | **`True`** | `Effectful` | Reads mutable memory state → a barrier (no CSE of a load across a store, no reorder across a grow), exactly like `MemLoad`. |
| `SimdStore(..)` | **`True`** | `Effectful` | Writes memory → a barrier like `MemStore`. |
| `SimdLoadLane(..)` | **`True`** | `Effectful` | Reads memory → barrier. |
| `SimdStoreLane(..)` | **`True`** | `Effectful` | Writes memory → barrier. |

Concretely, the keystone edits `is_effectful_node`:
- Add `Simd(_, _)` and `SimdShuffle(_, _, _)` to the existing **`False`** group (alongside
  `Values`/non-trapping `Num`/non-trapping `Convert`/`TermOp`/the `Let`/`Block`/`If`/`Switch` shells).
- Add `SimdLoad(..) | SimdStore(..) | SimdLoadLane(..) | SimdStoreLane(..)` to the **`True`** barrier
  group (alongside `MemLoad`/`MemStore`/…).
- `children_all_pure` needs **no** edit: `Simd`/`SimdShuffle` are non-barriers with no sub-`Expr`, so
  they reach the existing `_ -> True` catch-all (vacuously pure); the four memory nodes are barriers,
  so `classify` short-circuits before `children_all_pure`.
- Update the module's `import twocore/ir.{…}` to name the six new constructors.

Because the `Simd`/`SimdShuffle` nodes are **pure**, they are the first Phase-5/6 "new" nodes the
baseline optimizer may **const-fold, CSE, and DCE** — a real (if small) optimization win, and the
reason the classification must be *exactly* right. This is **strictly the safe direction only where
proven**: a lane op that touched state or trapped would be unsound to call pure, but no SIMD lane op
does either (I3), and the spec is explicit that vector instructions are total value transforms
([spec §4.4](https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions)).
Since the `case` is exhaustive, **omitting any new node fails to compile** (fail-closed, D4).

---

## E. `«IR4-FROZEN»` — `TrapReason` (reuse — **no new variant**; ARGUED, I1/I6)

**The keystone adds ZERO `TrapReason` variants.** Argument (per I1/I6 — prefer reuse; a wrong/missing
trap is the worst case, never a host escape):

| Failure on the new surface | `TrapReason` | Why no new variant |
|---|---|---|
| any pure SIMD lane op (`Simd`/`SimdShuffle`) | **none** | SIMD lane ops are **total** (I3): saturation replaces overflow-trap; there is no SIMD divide-trap; conversions saturate. **No SIMD op traps.** |
| `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane` out of bounds | `MemoryOutOfBounds` (existing) | A SIMD memory access is a linear-memory access — the same bounds trap, address-width-agnostic, routed through the same `rt_mem` seam. |
| a 64-bit (`Idx64`) memory access beyond current size / the page cap | `MemoryOutOfBounds` (existing) | `MemoryOutOfBounds` is address-width-agnostic (the Phase-5 keystone already noted this, §D). memory64 adds no distinct reason. |
| an unsatisfied / signature-mismatched **cross-module function import** | **none (link-time)** | Unlinkable is a **link-time `ImportError`** (`UnknownImport`/`IncompatibleImportType` — already in `link.gleam`), surfaced as `assert_unlinkable`, **not** a runtime `TrapReason`. |

So `TrapReason` is **unchanged**, and the exhaustive `spec_trap_message` (`rt_trap.gleam:71`) /
`trap_reason_atom` (`emit_core.gleam:4248`) matches are **untouched** — one fewer reach than an
IR-growing keystone would otherwise take, exactly as Phase 5 achieved. Confirmed against the SIMD +
memory64 + linking suites: no `assert_trap` on the new surface produces a message the existing set
cannot ( `"out of bounds memory access"` covers every SIMD/memory64 OOB). **Flag (§Open):** if a
pinned `.wast` `assert_trap` in `simd/*.wast` or `memory64.wast` distinguishes a message this table
cannot produce, add **exactly one** variant + its `spec_trap_message` (the Phase-2/3 pattern) — a
conscious add, not a silent one. Expected: **none**.

Spec anchor: the SIMD proposal defines all vector instructions as non-trapping
([spec §4.4](https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions)); the
trap set is [spec §4.4 / runtime results](https://webassembly.github.io/spec/core/exec/runtime.html#results).

---

## F. `«IR4-FROZEN»` — the `.ir` grammar delta (sketch; owned + reconciled by P6-02)

Full spelling + round-trip is **P6-02**'s (as IR2/IR3 were), landing in
`specs/phase-6/ir-grammar-delta.md`. Sketched here so P6-02 and the printer/parser land-green arms
agree:

```
; value type
valtype     ::= … | "v128"                                   ; TV128
; the v128 literal — 16 bytes as 32 lower-case hex digits, little-endian lane order
value       ::= … | "v128.const" "0x" hex32                  ; ConstV128 (bit_size == 128)
; pure lane-wise SIMD (op is a neutral shape-tagged / named token; args are values)
expr        ::= … | "simd" simdop value*                     ; Simd(op, args)
              | "simd.shuffle" "[" int{16} "]" value value    ; SimdShuffle(lanes, a, b)  ; indices 0..31
; SIMD memory (mem index leads, ELIDED when 0 — byte-identical to a non-SIMD module's text)
              | "simd.load"  [mem] loadkind value "offset=" int          ; SimdLoad
              | "simd.store" [mem] value value "offset=" int             ; SimdStore
              | "simd.load_lane"  [mem] int value "offset=" int int value ; width addr offset lane vec
              | "simd.store_lane" [mem] int value "offset=" int int value ; width addr offset lane vec
loadkind    ::= "v128" | "splat" int | "extend" int ("s"|"u") | "zero" int
simdop      ::= "i32x4.add" | "f64x2.sqrt" | "i8x16.swizzle" | …          ; the ~80 neutral SimdOp tokens
```

**Byte-identity of the `.ir` text (I7).** A Phase-1..5 `.ir` fixture is unchanged: the new tokens
(`v128`, `v128.const`, `simd*`) appear **only** when a module actually uses SIMD, and the SIMD-memory
nodes **elide `mem 0`** (matching the existing `MemLoad`/`MemStore` `mem 0` elision, printer §A.6).
P6-02 reconciles the exact `simdop` token spelling into `ir-grammar-delta.md`; the keystone
guarantees only that the shape is expressible and the defaults elide.

---

## G. `«RT-SIMD-SIG»` — the `rt_simd` signature heads (NEW module; bodies → P6-07)

`runtime/rt_simd.gleam` is a **new** single-owned module, the SIMD analogue of `rt_num`: the single
auditable chokepoint for SIMD fidelity (tier-P `bif`). This unit **creates the file with every public
head, its doc comment, and a fail-loud placeholder body**; **unit 07 replaces the bodies** across
07a (integer) / 07b (float + conversions) / 07c (misc + memory helpers + shuffle). The keystone fixes
the **names, arities, and BitArray-vs-Int shape**; the spec-cited *semantics* (§B.3) are 07's.

### G.1 Conventions (the documented representation contract)

- **`v128` in/out is a `BitArray`** — exactly 16 bytes, little-endian lane layout (§A.2).
- **Scalars in/out are raw-bit `Int`** — i32/i64 as the unsigned bit pattern, f32/f64 as the raw
  IEEE-754 bit pattern (D5), exactly as `rt_num` uses them. A lane index / shift count / shuffle
  index is a plain `Int`.
- **Every op is total (returns a bare value, never `Result`)** — SIMD lane ops do not trap (I3), so
  **no `rt_simd` head returns `Result(_, TrapReason)`** (unlike `rt_num`'s trapping `div`/`rem`). The
  memory-bounds trap lives in `rt_mem`, not here (§G.3).
- **07 CONSUMES `rt_num`, never edits it** — each lane reuses `rt_num`'s exact scalar op (two's-
  complement mask, shift-count mask, f32 single-rounding, NaN canonicalization). The keystone's
  placeholder file has **no `import`** (the heads need only prelude `BitArray`/`Int`/`Bool`/`List`);
  07 adds `import twocore/runtime/rt_num` when it fills the bodies (so the keystone has no unused-import
  warning).

### G.2 The placeholder-body posture (todo-free, zero-warning, fail-loud)

Each head lands with a body of the form
`panic as "rt_simd.<name>: body pending unit 07"` — **`todo`-free** (Gleam's `todo` emits a warning;
`panic` does not), **zero-warning** (a `pub fn` is never "unused"), and **fail-loud** (07's differential
tests catch any unfilled head; a `panic` in generated code is a node-safe crash, never a silent wrong
answer — D4). No Phase-1..5 module or the keystone's own freeze test calls `rt_simd` (the keystone's
`emit` arms return `UnsupportedNode`, §J), so the placeholders are never reached until 07. This mirrors
Phase-5 R5 (the keystone lands `todo`-free conservative stub accessors; the Wave-A unit fills bodies).

### G.3 The head enumeration (~214 pure heads + ~10 memory helpers ≈ the ~236 surface)

Naming: `{shape}_{op}[_s|_u]` — concrete, like `rt_num`'s `i32_add`/`i64_div_s` (the D6
opcode-neutrality rule governs the **IR** `SimdOp`, not the runtime chokepoint, which is allowed
concrete names). `a`/`b`/`c` are `BitArray` (v128) unless noted; `x`/`count`/`lane` are `Int`.

**Integer arithmetic (57 heads).**
```gleam
// i8x16 (18): no mul
pub fn i8x16_add(a, b) -> BitArray   pub fn i8x16_sub(a, b) -> BitArray
pub fn i8x16_neg(a) -> BitArray      pub fn i8x16_abs(a) -> BitArray
pub fn i8x16_add_sat_s(a, b) -> BitArray  pub fn i8x16_add_sat_u(a, b) -> BitArray
pub fn i8x16_sub_sat_s(a, b) -> BitArray  pub fn i8x16_sub_sat_u(a, b) -> BitArray
pub fn i8x16_min_s(a, b) -> BitArray  pub fn i8x16_min_u(a, b) -> BitArray
pub fn i8x16_max_s(a, b) -> BitArray  pub fn i8x16_max_u(a, b) -> BitArray
pub fn i8x16_avgr_u(a, b) -> BitArray  pub fn i8x16_popcnt(a) -> BitArray
pub fn i8x16_shl(a, count: Int) -> BitArray
pub fn i8x16_shr_s(a, count: Int) -> BitArray  pub fn i8x16_shr_u(a, count: Int) -> BitArray
// i16x8 (18): + mul, q15mulr_sat_s; no popcnt
//   i16x8_add/sub/mul/neg/abs, i16x8_add_sat_s/u, i16x8_sub_sat_s/u,
//   i16x8_min_s/u, i16x8_max_s/u, i16x8_avgr_u, i16x8_q15mulr_sat_s,
//   i16x8_shl, i16x8_shr_s/u
// i32x4 (13): + mul, dot_i16x8_s; no add_sat/sub_sat/avgr/popcnt
//   i32x4_add/sub/mul/neg/abs, i32x4_min_s/u, i32x4_max_s/u,
//   i32x4_shl, i32x4_shr_s/u, i32x4_dot_i16x8_s
// i64x2 (8): add/sub/mul/neg/abs/shl/shr_s/shr_u  (no min/max/sat/avgr)
```

**Integer comparisons → mask (36 heads).**
```gleam
// i8x16 (10): eq ne lt_s lt_u gt_s gt_u le_s le_u ge_s ge_u
// i16x8 (10): same ten
// i32x4 (10): same ten
// i64x2 (6):  eq ne lt_s gt_s le_s ge_s      (NO unsigned comparisons)
pub fn i8x16_eq(a, b) -> BitArray   // … through i64x2_ge_s(a, b) -> BitArray
```

**v128 bitwise (6 heads).**
```gleam
pub fn v128_not(a) -> BitArray  pub fn v128_and(a, b) -> BitArray
pub fn v128_or(a, b) -> BitArray  pub fn v128_xor(a, b) -> BitArray
pub fn v128_andnot(a, b) -> BitArray  pub fn v128_bitselect(a, b, mask: BitArray) -> BitArray
```

**Boolean reductions / mask (9 heads).**
```gleam
pub fn v128_any_true(a) -> Int   // → i32 0/1
pub fn i8x16_all_true(a) -> Int   pub fn i16x8_all_true(a) -> Int
pub fn i32x4_all_true(a) -> Int   pub fn i64x2_all_true(a) -> Int
pub fn i8x16_bitmask(a) -> Int    pub fn i16x8_bitmask(a) -> Int
pub fn i32x4_bitmask(a) -> Int    pub fn i64x2_bitmask(a) -> Int
```

**Splat (6 heads) — scalar → v128.**
```gleam
pub fn i8x16_splat(x: Int) -> BitArray   // x = i32 raw bits, low 8 used
pub fn i16x8_splat(x: Int) -> BitArray   pub fn i32x4_splat(x: Int) -> BitArray
pub fn i64x2_splat(x: Int) -> BitArray   pub fn f32x4_splat(x: Int) -> BitArray  // x = f32 bits
pub fn f64x2_splat(x: Int) -> BitArray   // x = f64 bits
```

**Extract / replace lane (14 heads).**
```gleam
pub fn i8x16_extract_lane_s(a, lane: Int) -> Int   pub fn i8x16_extract_lane_u(a, lane: Int) -> Int
pub fn i16x8_extract_lane_s(a, lane: Int) -> Int   pub fn i16x8_extract_lane_u(a, lane: Int) -> Int
pub fn i32x4_extract_lane(a, lane: Int) -> Int     pub fn i64x2_extract_lane(a, lane: Int) -> Int
pub fn f32x4_extract_lane(a, lane: Int) -> Int     pub fn f64x2_extract_lane(a, lane: Int) -> Int
pub fn i8x16_replace_lane(a, lane: Int, x: Int) -> BitArray   // … through f64x2_replace_lane
```

**Float arithmetic (30 heads).**
```gleam
// f32x4 (15): add sub mul div neg abs sqrt min max pmin pmax ceil floor trunc nearest
// f64x2 (15): same fifteen
pub fn f32x4_add(a, b) -> BitArray   // … through f64x2_nearest(a) -> BitArray
```

**Float comparisons (12 heads).**
```gleam
// f32x4 (6): eq ne lt le gt ge      f64x2 (6): eq ne lt le gt ge
pub fn f32x4_eq(a, b) -> BitArray   // … through f64x2_ge(a, b) -> BitArray
```

**Conversions (10 heads).**
```gleam
pub fn i32x4_trunc_sat_f32x4_s(a) -> BitArray   pub fn i32x4_trunc_sat_f32x4_u(a) -> BitArray
pub fn i32x4_trunc_sat_f64x2_s_zero(a) -> BitArray   pub fn i32x4_trunc_sat_f64x2_u_zero(a) -> BitArray
pub fn f32x4_convert_i32x4_s(a) -> BitArray   pub fn f32x4_convert_i32x4_u(a) -> BitArray
pub fn f32x4_demote_f64x2_zero(a) -> BitArray
pub fn f64x2_convert_low_i32x4_s(a) -> BitArray   pub fn f64x2_convert_low_i32x4_u(a) -> BitArray
pub fn f64x2_promote_low_f32x4(a) -> BitArray
```

**Narrow (4) · Extend (12) · Extended-multiply (12) · Extended-pairwise-add (4) = 32 heads.**
```gleam
pub fn i8x16_narrow_i16x8_s(a, b) -> BitArray   pub fn i8x16_narrow_i16x8_u(a, b) -> BitArray
pub fn i16x8_narrow_i32x4_s(a, b) -> BitArray   pub fn i16x8_narrow_i32x4_u(a, b) -> BitArray
// extend_{low,high}_{s,u} for i16x8←i8x16, i32x4←i16x8, i64x2←i32x4 (12)
pub fn i16x8_extend_low_i8x16_s(a) -> BitArray   // … high/u; i32x4_extend_*; i64x2_extend_*
// extmul_{low,high}_{s,u} for i16x8←i8x16, i32x4←i16x8, i64x2←i32x4 (12)
pub fn i16x8_extmul_low_i8x16_s(a, b) -> BitArray   // … high/u; i32x4_extmul_*; i64x2_extmul_*
// extadd_pairwise_{s,u} for i16x8←i8x16, i32x4←i16x8 (4)
pub fn i16x8_extadd_pairwise_i8x16_s(a) -> BitArray   // … u; i32x4_extadd_pairwise_i16x8_{s,u}
```

**Shuffle / swizzle (2 heads).**
```gleam
/// 16 immediate lane indices (each 0..31) select bytes from `a ++ b`.
pub fn i8x16_shuffle(a, b, lanes: List(Int)) -> BitArray
/// Dynamic byte select: `idx` lane `i` (a byte 0..255) picks `a`'s byte `idx[i]`, or 0 if ≥ 16.
pub fn i8x16_swizzle(a, idx: BitArray) -> BitArray
```

**SIMD-memory lane-assembly helpers (~10 heads).** The full `SimdLoad*`/`SimdStore*` ops are
**emitted by P6-06** as a compose of the bounds-checked `rt_mem` seam (which does the OOB check →
trap) with these **pure** assembly helpers. `rt_simd` provides the pure part; `rt_mem` owns the check.
```gleam
/// Build a v128 from the loaded 8-byte slice by extending each of 8/4/2 `source_bits`-wide lanes to
/// double width, signed/unsigned (`v128.load8x8`/`load16x4`/`load32x2`).
pub fn v128_load_extend(bytes8: BitArray, source_bits: Int, signed: Bool) -> BitArray
/// Build a v128 with the loaded `lane_bits` (32/64) in the low lane, upper bits zero
/// (`v128.load32_zero`/`load64_zero`).
pub fn v128_load_zero(bytes: BitArray, lane_bits: Int) -> BitArray
/// Insert `bits` (`width` = 8/16/32/64) into lane `lane` of `vec` (`v128.loadN_lane` assembly).
pub fn v128_replace_lane_bits(vec: BitArray, lane: Int, width: Int, bits: Int) -> BitArray
/// Extract lane `lane` (`width` bits) of `vec` as raw bits (`v128.storeN_lane` extraction).
pub fn v128_extract_lane_bits(vec: BitArray, lane: Int, width: Int) -> Int
// (splat loads `v128.loadN_splat` reuse the six *_splat heads above — no new head.
//  a plain `v128.load`/`v128.store` is a pure 16-byte rt_mem slice — no assembly head.)
```

**Total: ~214 pure lane heads + ~10 memory helpers ≈ the ~236 SIMD surface.** (v128.const is a
`Value`, not a head; the plain load/store need no assembly head; splat-loads reuse `*_splat`.) **07
finalizes the exact head list** across 07a/07b/07c and may split a head or add a private worker; the
keystone freezes the public *shape* (names, arities, BitArray-vs-Int) so 06 (the emit mapping) and 07
(the bodies) never race signatures.

---

## H. `«MEM64-RUNTIME»` — the page-cap field + the accept-`Idx64` contract (I4/R12)

Phase 5 froze the `IdxType`/`Idx64` axis and shipped memory64 **decode + validate** (`decode.gleam`
parses the `0x04`/`0x05` limits flags; `validate.gleam:674` types the `2^48`-page declarable limit),
but `lower` **rejects** a 64-bit memory (`lower.gleam:270`, `Error(Memory64Unsupported)`). Phase 6
removes the rejection and makes a 64-bit memory **run**. The keystone freezes two things:

### H.1 The `Binding` page-cap field (frozen here; the exact constant pinned by P6-08)

```gleam
pub type Binding {
  Binding(
    …,
    safe_max_pages: Int,       // existing — the i32 (Idx32) Safe cap
    /// The documented, spec-aligned RUNTIME page cap for a 64-bit (`Idx64`) memory (I4). We do
    /// NOT reserve 2^64 bytes: the `paged` backend grows on demand, so this is a **trap
    /// boundary**, not a reservation — `memory.grow` beyond it returns `-1`, and an access beyond
    /// the *current* size traps `MemoryOutOfBounds` (the spec's `assert_trap`). Distinct from
    /// validate's `2^48`-page DECLARABLE limit (spec §3.2.5) — this is the smaller
    /// IMPLEMENTATION cap. **PROVISIONAL default; P6-08 pins the exact constant against
    /// memory64.wast + wasmtime's default with a citation.** Ignored for `Idx32` memories.
    mem64_max_pages: Int,
    …,
  )
}
```

`safe_default()` sets a **provisional** `mem64_max_pages: 4_294_967_296` (`2^32` pages = `2^48`
bytes = a 48-bit address space — the conventional hardware virtual-address ceiling), clearly marked
provisional. **Why a provisional is safe to ship:** memory64 is gated behind `Idx64`, which **no
Phase-1..5 module uses** (they are all `Idx32`), so the cap is conformance-neutral for the existing
corpus; P6-08 corrects it before `memory64.wast` is claimed green, and P6-11 may lower it to a real
Safe resource bound (as unit 11 tunes `safe_max_pages`). Under Safe, fuel is the real bound (a Safe
instance cannot actually touch `2^48` bytes within its budget), so a large trap-boundary cap is
honest (I4). The `profiles.gleam` full constructors (`unsafe()`/`ceiling()`/…) and the test full
`Binding(...)` sites gain the field; the `Binding(..spread, …)` sites absorb it.

> **Note the arithmetic discrepancy to reconcile (§Deviations/§Open):** the provisional-surface said
> "`2^48` bytes ⇒ `2^32` pages"; the in-tree `validate.gleam:77` `memory64_page_limit` is `2^48`
> **pages** (the spec §3.2.5 *declarable* max, `281_474_976_710_656`). These are three different
> numbers — the declarable limit (`2^48` pages), the provisional runtime cap (`2^32` pages), and
> whatever wasmtime defaults to. The keystone freezes only the **field**; **P6-08 pins the runtime
> cap** and cites it, and must not conflate it with validate's declarable limit.

### H.2 The accept-`Idx64` contract (frozen in prose; removal is P6-05/09)

- **`lower` accepts `Idx64`** — P6-05 deletes the `reject_memory64` guard (`lower.gleam:258-272`) and
  threads the i64 address width through the memory-index/address plumbing. The IR shape is
  **unchanged** (the `IdxType` axis is already frozen — I7); only the rejection goes.
- **`link` accepts `Idx64`** — the fail-closed limits/idx-type matching in `link.gleam`
  (`limits_match` + `pidx == idx_type`) already handles `Idx64` (P5 wired it for imported memories);
  P6-09 confirms a registered/`spectest` 64-bit memory links.
- **`emit_core` threads i64 addressing** — a 64-bit memory's addr/bounds arithmetic is i64; a 32-bit
  memory is **unchanged / byte-identical** (BEAM `Int`s are bignums, so the same `rt_mem` heads serve
  both widths — the `idx_type` is a lower/emit concern, not an `rt_mem` signature change). `memory.size`/
  `memory.grow` on a 64-bit memory take/return i64 page counts. This is **P6-06/08**'s.
- **`atomics`/`nif` fail closed for an over-cap 64-bit memory** (I4) — memory64 ships on `paged`
  (+`portable`); an over-cap 64-bit `atomics` binding is categorized honestly (the existing atomics
  fail-closed gate). **P6-08**'s.
- **Every access stays bounds-checked → trap** (I6): the worst case of a 64-bit bounds bug is a
  wrong/missing trap or a node-safe crash, never a host escape.

Spec anchor: the memory64 index-type flag rides the limits' flags byte; an `Idx64` memory's declared
pages are valid within `2^48`
([spec §5.3.7 / §3.2.5 limits](https://webassembly.github.io/spec/core/binary/types.html#limits) + the
memory64 proposal).

---

## I. `«XLINK»` — the cross-module `ProvidedFunc` closure-dispatch contract head (I5/R4/D3a)

Phase 5 wired imported **state** (globals/tables/memories) + the `spectest` module, and `link.gleam`
already **matches** a `ProvidedFunc(ty)` signature (`link.gleam:354`) — but there is **no
cross-instance function dispatch**: generated code cannot *call* an imported function that lives in
another module's instance. Phase 6 closes this. The keystone freezes the **contract head**; **P6-09
builds the linker + the function `link_imports` extension; P6-06 emits the call.**

### I.1 The `ProvidedFunc` closure field (frozen here)

```gleam
pub type Provided {
  ProvidedGlobal(value: Int, ty: ValType, mutable: Bool)
  ProvidedRefGlobal(value: Dynamic, ty: ValType, mutable: Bool)
  ProvidedTable(value: Dynamic, ref_ty: RefType, min: Int, max: Option(Int))
  ProvidedMemory(value: Dynamic, min_pages: Int, max_pages: Option(Int), idx_type: IdxType)
  /// A FUNCTION export made callable across instances (I5). `ty` drives fail-closed function-import
  /// matching (spec §3.2, unchanged from P5). `call` is the **linker-built closure capability**: a
  /// first-class `fun` the LINKER (P6-09) constructs, capturing the exporting instance + its
  /// exported function (e.g. `fn(args) { b_instance:f(args) }`, or the threaded-state analogue).
  /// The generated caller lowers an imported-function call to **`apply(call, Args)` over this
  /// handed-in closure** — a CAPABILITY, exactly like `externref`/`call_host`, NOT an ambient
  /// `apply` of an attacker-chosen `module:atom` (D3a). The closure is held by the caller's
  /// POSITIONAL import slot (R4 — name-free), never looked up by a runtime name in generated code.
  ProvidedFunc(ty: FuncType, call: fn(List(Dynamic)) -> Dynamic)
}
```

The land-green edit to `link.gleam`: add the `call` field and update the one match
`Ok(ProvidedFunc(sig, _)) -> match_fn(…)` (matching uses only `ty`; the closure is ignored for
signature matching). **No construction site exists in P5** (grep: `ProvidedFunc` is only *matched*,
never built — cross-instance dispatch was absent, I5), so the keystone's edit is minimal; P6-09 adds
the construction (the linker builds `call`) and the function-import `link_imports` path.

### I.2 The dispatch model (frozen in prose; P6-06 emits, P6-09 builds)

- **`emit_core` (P6-06) lowers an imported-function `CallDirect`/`CallIndirect` target to
  `apply(Closure, Args)`** over the `Provided.call` closure the caller holds by import slot. This is
  the **only** new control-transfer shape; it is a handed-in `fun`, so **D3a holds** (P6-06 extends
  the structural security test to grep-verify no ambient `apply(Mod, F, Args)` with `Mod` from data).
- **`link_imports` (P6-09) extends to functions**: an unsatisfied or signature-mismatched **function**
  import is a **link-time `ImportError`** (`UnknownImport`/`IncompatibleImportType` → `assert_unlinkable`),
  fail-closed (I6/H6). The `(register "name" $mod)` mechanism (P5's `Provider.Registered`) makes a
  prior module's exports importable by a later one.
- **The closure return shape is a cross-unit seam (flag).** `fn(List(Dynamic)) -> Dynamic` returns the
  callee's return **package** — a bare value for 1 result, an N-tuple for multi-value (exactly what
  `emit_core.function_return` already produces), which the caller destructures. This composes with the
  R17-analogue value-list invoke ABI; **P6-09 finalizes** whether to keep the single-`Dynamic` package
  or widen to `fn(List(Dynamic)) -> List(Dynamic)`. A `ProvidedFunc` carrying a `fun` **must never be
  compared with `==`** (BEAM compares funs by identity) — nothing in `link.gleam` does (`match_fn`
  compares `FuncType`, not `Provided`); flag so 09/11 keep it so.
- **State-strategy reach is a scoping question (Open Q, I5).** Cross-instance calls compose cleanly
  under **`cell`** (each instance owns its pdict state) — the honest first target for `linking.wast`.
  Under **`threaded`**, calling into instance B means threading B's state record; **P6-09 categorizes
  the threaded cross-module case honestly** if it proves invasive (as P5 categorized spectest-memory-
  under-atomics). The keystone freezes the closure contract; 09 decides the matrix reach.

Spec anchor: instantiation resolves function imports positionally against provided externvals; a
missing/type-mismatched import fails instantiation
([spec §4.5.4](https://webassembly.github.io/spec/core/exec/modules.html#instantiation),
matching [§3.2](https://webassembly.github.io/spec/core/valid/matching.html)).

---

## J. The `emit_core` / `lower` / `printer` / `parser` seam reach (doc; full impl → 02/05/06)

The keystone makes these files **compile** and stay **byte-identical** on the existing surface; it
does **not** implement the new codegen/lowering/round-trip (that is 02/05/06). Concretely:

- **`emit_value`** gains `ConstV128(bytes) -> <Core binary literal of the 16 bytes>` — a pure literal
  (P6-06 confirms the exact `CBinary`/`CLit` shape; the keystone may land it as the real literal since
  it is trivial and pure, or as an `UnsupportedNode` if the Core binary literal helper is P6-06's).
- **`result_width`/`valtype_atom`** gain `TV128 -> 128` / `"v128"`.
- **The six SIMD `Expr` arms** in `emit`'s dispatch each land as
  `Error(UnsupportedNode("simd_lane"/"simd_shuffle"/"simd_load"/"simd_store"/"simd_load_lane"/
  "simd_store_lane"))` — a real `Result` path (no new `EmitError` variant needed; `UnsupportedNode`
  already exists). Because **no Phase-1..5 module contains these nodes**, the corpus + suite are
  unaffected; **P6-06** replaces each arm with the real lowering (`Simd`/`SimdShuffle` → the `rt_simd`
  seam; `SimdLoad*`/`SimdStore*` → the `rt_mem`-compose-`rt_simd` seam).
- **`expr_touches_state` (`emit_core:751`) has a `_ -> False` catch-all**, so it is **not** a hard
  land-green break — but it is **semantically wrong** to leave the four SIMD-memory nodes at `False`
  (they read/write memory → state-reaching under `Threaded`). Since the keystone's `emit` arms return
  `UnsupportedNode`, the SIMD-memory nodes never reach codegen, so the wrong default is inert **until**
  P6-06 wires them — at which point **P6-06 MUST add `SimdLoad(..) | SimdStore(..) | SimdLoadLane(..) |
  SimdStoreLane(..) -> True`** here (and leave `Simd`/`SimdShuffle` to the `False` catch-all, correctly
  pure). **Flagged as a P6-06 obligation** so a threaded SIMD-memory function is correctly seeded.
- **`printer`** gains the `TV128`/`ConstV128`/six-SIMD-node arms (any spelling — conformance-neutral;
  P6-02 makes it the round-trip spelling). **`parser`** gains minimal string-dispatch arms (P6-02
  full). **`lower`** gains `TV128 -> ConstV128(<<0:128>>)` (`zero_value`) and `ConstV128(_) -> TV128`
  (`value_type`); P6-05 fills the real SIMD lowering + the `Idx64` acceptance.

The **D3a security-invariant test extension** (SIMD + the closure-dispatch no-ambient-authority
proof) is **P6-06's**; the keystone only guarantees the seam *shape* composes.

---

## Effect / soundness / security note

- **No ambient authority (D3a) survives the new surface.** A `v128` is an opaque 16-byte value in Safe
  mode — it cannot address memory except through the checked `rt_mem` seam (I6). SIMD lane ops emit
  fixed `twocore@runtime@rt_simd`/`rt_num` module atoms with literal function names; the SIMD-memory
  ops route through the same bounds-checked `rt_mem` seam as scalar loads/stores. The cross-module
  function call is `apply(Closure, Args)` over a **handed-in** closure (a capability, never a
  data-driven `module:atom`), held by positional import slot. P6-06 extends the structural security
  test to grep-verify both.
- **Fail-closed everywhere (D4/I6).** SIMD lane ops are **total** (no trap — I3); the only SIMD trap
  surface is the memory load/store bounds check → `MemoryOutOfBounds` **before any partial effect**.
  memory64 keeps every access bounds-checked → trap; the page cap is a hard trap boundary; **Safe
  forbids tier-N** as before. An unsatisfied/mismatched cross-module import fails at **link time**
  (`assert_unlinkable`) — never an ambient default. Worst case of any new bug is a wrong result or a
  node-safe crash, never a host escape.
- **Conformance-neutral by default (I7) — the proof.** The defaults are chosen so that a module with
  **no `TV128`/`ConstV128`/`Simd*` node**, `memories = [MemoryDecl(_, _, Idx32)]` (or `[]`), and no
  cross-module imports produces: the same `.ir` text (the new tokens appear only when SIMD is used;
  `mem 0` elided on SIMD-memory nodes, §F), the same `InstanceState`/`StateDecl` term, and the same
  `.core` bytes (the SIMD `emit` arms are unreached; `emit_value`/`result_width`/`valtype_atom` add
  arms that the existing surface never hits; `mem64_max_pages` defaults away for `Idx32`; `ProvidedFunc`'s
  `call` is unused by import-free modules). Since WebAssembly is deterministic and D5 pins v128/NaN/`-0.0`
  as raw bits, **byte-identity ⇒ result-identity** across both state strategies and every shipped tier.
  **Nothing observable changes** for the existing corpus + suite (the H7/I7 claim, asserted by the
  conformance suite passing unchanged).
- **v128 stays on the low-level (numeric) path (D5/I2).** A `v128` is a raw `BitArray`, never a decoded
  lane tuple and never a BEAM term round-trip — so NaN payloads / `-0.0` / signed lanes are exact. The
  only bridge to the term layer is an explicit boxing `Convert` (as for i32/i64), never implicit.

---

## Deviations from the provisional surface (ARGUED — for the critique + reconciliation)

1. **Tagged widen / extend / extmul / pairwise families (§B.2).** The provisional spelled these as
   individually-named constructors (`I16x8ExtendLowI8x16S`, `I16x8ExtendHighI8x16S`, … — 32 of them,
   plus `…High/U` placeholders it never fully enumerated). The keystone replaces them with **four
   tagged constructors** — `SNarrow(from, signed)`, `SExtend(from, half, signed)`, `SExtMul(from,
   half, signed)`, `SExtAddPairwise(from, signed)` — plus a `SimdHalf { Low High }` tag. **Argument:**
   (a) **D6 neutrality** — the individually-named forms are essentially the WASM opcode strings in
   CamelCase; the tagged forms are neutral (a generic "extend the low half of `from`, signed"),
   matching how `NumOp` tags `IAdd(IntWidth)` rather than spelling `I32Add`/`I64Add`. (b) **Compactness**
   — 4 constructors vs 32, so the enum stays ~80 (the provisional estimated ~110). (c) **It resolves
   the placeholders** the provisional left as prose (`…High/U`). The **cost**: the shape tag on
   `SExtend` means the *source* shape (result is the double-width shape), a slightly different reading
   than `SAdd(shape)`'s *result* shape — documented on each constructor. **Fallback if reconciliation
   prefers the provisional:** P6-03/07 can spell the 32 named constructors instead; the `rt_simd` heads
   (§G, concrete names) are identical either way, so the choice is IR-surface-only. **Recommend tagged.**

2. **The genuinely-singular conversions stay NAMED, not tagged (§B.2).** `STruncSatF32x4S`,
   `SDemoteF64x2Zero`, `SPromoteLowF32x4`, `SDotI16x8S`, `SQ15MulrSatS`, etc. are kept as named
   constructors (matching `ConvOp`'s `I32WrapI64`/`F32DemoteF64` precedent) rather than forced into a
   tagged family, because they are not shape-uniform (each is a single specific conversion). This is
   *consistent with the existing IR*, not a divergence from it.

3. **`SExtractLane` split into three constructors (§B.2).** The provisional had `SExtractLaneS`/
   `SExtractLaneU` shape-tagged. But `i32x4`/`i64x2`/`f32x4`/`f64x2` extract have **no sign variant**
   (they yield the full lane), while `i8x16`/`i16x8` extract **do** (sign/zero-extend to i32). The
   keystone adds a third plain `SExtractLane(shape, lane)` for the no-sign shapes, so the IR cannot
   express a nonsensical "signed extract of an f32x4 lane". Minor; strictly a correctness refinement.

4. **The SIMD-memory node decision is RESOLVED to dedicated nodes (§C.1).** The provisional left this
   as Open Q (a) with a recommendation; the keystone **freezes dedicated nodes** with the full argument
   (byte-identity of the existing `MemLoad`/`MemStore`, shape-fit, identical bounds-check invariant).

5. **`add_sat`/`sub_sat` were missing from the provisional `SimdOp` (§B.2) — added.** The provisional
   listed `SAvgrU` but omitted the saturating add/sub family (`i8x16`/`i16x8` `add_sat_s/u`,
   `sub_sat_s/u`). These are real standardized ops; the keystone adds `SAddSatS/U`, `SSubSatS/U`
   (shape-tagged). A gap-fill, not a taste choice.

6. **`mem64_max_pages` provisional value + the arithmetic discrepancy (§H.1).** The provisional froze
   the field name and noted "`2^48` bytes ⇒ `2^32` pages", but the in-tree validate limit is `2^48`
   **pages**. The keystone freezes the field with a clearly-provisional `2^32`-page default and
   **explicitly delegates the exact runtime cap + citation to P6-08**, flagging the three-number
   discrepancy for reconciliation. Not a shape change — a documentation/pin handoff.

7. **`ProvidedFunc.call` signature (§I.1).** Adopted verbatim from the provisional
   (`fn(List(Dynamic)) -> Dynamic`), with the multi-value return-package seam flagged for P6-09
   (consistent with the R17-analogue value-list invoke ABI). No divergence; a forward-flag only.

Everything else (the `TV128` constructor, the `ConstV128(bytes)` value + 16-byte little-endian
representation, the shape-tagged uniform arithmetic/comparison/bitwise/lane/float ops, `SimdShuffle`
as a dedicated node, the pure-vs-barrier effect split, the reuse of `MemoryOutOfBounds`, the `rt_simd`
= `rt_num`-style chokepoint, the accept-`Idx64` contract) is adopted **as the provisional specifies**.

---

## Verification — Definition of Done (D8)

- **`gleam build` compiles with zero warnings.** The only *behavioural* code the keystone lands is
  `ir.gleam` (types), `ir/effect.gleam` (real classification, §D), the land-green arms
  (printer/parser/emit_core/lower/ir_lower/ir_opt), the `Binding.mem64_max_pages` field, the
  `ProvidedFunc.call` field, and the **new `rt_simd.gleam`** (heads + `panic` placeholder bodies,
  `todo`-free, no imports → no unused-import warning). The `rt_simd` bodies, the memory64 addressing,
  the exact page cap, and the linker are frozen in **prose** (no `todo` stubs → no warnings), the
  Phase-4/5 posture.
- **`gleam format --check src test` clean; `gleam test` stays green (1212 tests, conformance
  21525/1257/0 under every shipped `(state_strategy × mem_tier)`).** The land-green reaches keep the
  tree total; the default paths are byte-identical, so **no conformance number moves** — the I7 proof,
  asserted by the existing conformance suite passing unchanged.
- **A scratch freeze test** (`test/twocore/ir/ir4_freeze_test.gleam`, mirroring `ir3_freeze_test`) —
  **spec assertions, not change-detectors**:
  - constructs an IR4 `Module` exercising the whole new surface (a function with `v128` params/locals;
    a body using `Simd` for each family — `SAdd(I32x4)`, `FMul(F64x2)`, `VBitselect`, `SEq(I8x16)`,
    `SSplat(I32x4)`, `SExtractLaneU(I16x8, 3)`, `SShl(I8x16)`, `SNarrow(I16x8, True)`,
    `SExtend(I8x16, Low, False)`, `STruncSatF32x4S`, `SDotI16x8S`, `VAnyTrue`, `SBitmask(I32x4)` —,
    a `SimdShuffle`, a `SimdLoad(LoadV128)`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`, and a
    `ConstV128(<<…:128>>)` operand; plus an `Idx64` `MemoryDecl`) and asserts it **typechecks** —
    proving the types express the whole Phase-6 surface before anyone builds on them.
  - asserts **`effect.classify(Simd(…)) == Pure`** and **`effect.classify(SimdShuffle(…)) == Pure`**
    (the load-bearing I3 freeze — SIMD lane ops are total value transforms, WASM §4.4), and
    **`effect.classify(SimdLoad(…)) == Effectful`** and the same for `SimdStore`/`SimdLoadLane`/
    `SimdStoreLane` (they are load/store ops, WASM §4.4.7) — asserted against the **spec rule**, not
    current output.
  - asserts **`bit_size(ConstV128.bytes) == 128`** for a constructed literal, and that
    `ConstV128(b1) == ConstV128(b2)` iff `b1`/`b2` are the same 16 bytes (BEAM binary equality — the
    const-fold/dedup contract).
  - asserts **default-neutrality structurally**: a single-`Idx32`-memory, no-SIMD, no-cross-import
    module round-trips its `.ir` text **byte-identically** to the Phase-5 spelling and lowers to a
    **byte-identical** `.core` (compare against a committed Phase-5 golden) — the I7 claim as a test.
  - asserts **`TrapReason` is unchanged** (§E) — a guard against an accidental variant addition breaking
    `spec_trap_message`/`trap_reason_atom`'s exhaustive matches (constructs the full list and asserts
    the count/messages are exactly Phase-5's).
  - asserts **`safe_default().mem64_max_pages`** is the frozen provisional (a bound, `> 0`), and that a
    `ProvidedFunc(ty, call)` can be constructed with a closure and matched (the `call` field exists).
- **The `.ir` grammar delta** (§F) is sketched for P6-02; the `«RT-SIMD-SIG»` heads (§G), the
  `«MEM64-RUNTIME»` field + contract (§H), and the `«XLINK»` contract head (§I) are frozen for 05–09.
- **Done = the freeze test + the full suite pass** (D8) — **not** "it compiles."
- Announce `«IR4-FROZEN»` / `«RT-SIMD-SIG»` / `«MEM64-RUNTIME»` / `«XLINK»` in `state.md` with the full
  reach list.

---

## What this unit leaves

- **02** implements the `.ir` printer/parser round-trip of the whole IR4 surface (§F) — `v128.const`
  (16-byte hex), every `SimdOp` token, the six SIMD nodes, and reconciles `ir-grammar-delta.md`;
  legacy modules print byte-identically.
- **03** publishes `«WASM-AST4»`: the `0xFD` SIMD prefix + all ~236 sub-opcodes, `v128.const` (16
  immediate bytes), the shuffle/lane immediates, the v128 memory instructions + their memarg + lane
  immediates; the `v128 = 0x7B` value type; and confirms the memory64 limits-flag decode (already in).
- **04** types the SIMD surface (`v128` on the abstract stack; the legal `(op, shape)` combinations
  from §B.2; lane-index immediates in range; shuffle indices `0..31`; SIMD-memory align ≤ natural),
  memory64 `i64`-address typing (mostly P5 — confirm), and cross-module function-import typing. The
  AST-only security boundary; rejects ill-typed fail-closed.
- **05** lowers WASM-AST4 → IR4 for every SIMD op (§B/§C), **accepts `Idx64`** (deletes the
  `Memory64Unsupported` reject, threads the i64 address width), and lowers cross-module function
  imports to the IR call shape — filling the real lowering the keystone left as land-green
  `zero_value`/`value_type` arms.
- **06** replaces the `emit_core` `UnsupportedNode` arms (§J) with the real SIMD codegen (`SimdOp` →
  `rt_simd` fn; `SimdLoad*`/`SimdStore*` → the `rt_mem`-compose-`rt_simd` seam), the i64 addressing,
  the **cross-module `apply(Closure, Args)`** dispatch, the `expr_touches_state` SIMD-memory arms, and
  the extended D3a security test.
- **07** implements the `«RT-SIMD-SIG»` bodies (§G) over the 16-byte binary, bit-exact, reusing
  `rt_num` per lane, across 07a (integer) / 07b (float + conversions) / 07c (misc + memory helpers +
  shuffle); differential vs `wasmtime`/the oracle. Consumes `rt_num`, never edits it.
- **08** implements memory64 `rt_mem` i64 addressing + the **documented page cap** (pins the exact
  `mem64_max_pages` constant + citation); paged (+ portable); atomics/nif fail closed for over-cap
  mem64; 32-bit heads byte-identical.
- **09** builds the linker-built closure capability (constructs `ProvidedFunc.call`), the function
  `link_imports` extension (fail-closed), the `(register …)` end-to-end, and the `state_strategy` reach
  decision (cell-first; threaded categorized if invasive).
- **10/11** light up `simd/*.wast`, `memory64.wast`, `linking.wast` with the empirical residual audit
  (R16), report measured pass/skip/fail, differential vs `wasmtime`, and prove the phase (unblocking
  Phase 7 — Porffor).

---

## Cross-unit seams (flagged for reconciliation — pin single ownership)

1. **The SIMD-memory node boundary (01/03/06/07).** Frozen as **dedicated nodes** (§C.1). 03 decodes
   into them, 06 emits them as `rt_mem`-compose-`rt_simd`, 07 provides the pure assembly helpers (§G.3).
   Pin: `rt_mem` owns the bounds check; `rt_simd` owns the pure lane assembly; **neither** stores v128
   state (v128 lives in memory bytes / SSA values, not a new `rt_state` field — but see seam 5).
2. **`rt_num` reuse by `rt_simd` (07 consumes, never edits `rt_num`).** The keystone's `rt_simd.gleam`
   has **no import**; 07 adds `import twocore/runtime/rt_num`. `rt_num.gleam` is untouched by Phase 6.
3. **The memory64 page-cap constant (01 freezes the field, 08 pins the value).** The `mem64_max_pages`
   field is frozen; the exact constant + spec/wasmtime citation is **08's**, and must be distinguished
   from validate's `2^48`-page *declarable* limit (§H.1). Reconcile the three-number discrepancy.
4. **The cross-module closure-dispatch seam (01/06/09) + its `state_strategy` reach.** 01 freezes the
   `ProvidedFunc.call` field + the `apply(Closure, Args)` model + D3a; 06 emits; 09 builds the closure
   + decides the cell/threaded matrix reach. Pin: the closure return-package shape (single `Dynamic`
   vs `List(Dynamic)`) — recommend single-`Dynamic` package (matches `function_return`); 09 finalizes.
   A `ProvidedFunc` with a `fun` must never be `==`'d.
5. **v128-typed globals (01/06/08-09 — NEW seam the keystone surfaces).** A `v128` global's value is a
   16-byte `BitArray` (a `Dynamic`), **not** an `Int`, so it cannot live in `rt_state`'s numeric
   `globals: Dict(String, Int)` (D5 raw-bits). It **can** live in the parallel `ref_globals:
   Dict(String, Dynamic)` (R8) — a `BitArray` is a valid `Dynamic`. **Recommend** generalizing
   `ref_globals` to "non-numeric (Dynamic) globals" so v128 globals reuse it and the numeric raw-bit
   `Int` path stays byte-identical; **P6-06/08/09 pin the storage** (the keystone does not own
   `rt_state`). `simd/*.wast`'s v128 globals are in scope for 10/11. **Flagged so it is not orphaned.**

---

## Open questions (for the planner / cross-unit sync)

1. **SimdOp taxonomy: tagged vs individually-named widen family (Deviation 1).** Recommend **tagged**
   (`SExtend(from, half, signed)` etc.) for D6 neutrality + compactness; the provisional's 32 named
   constructors are the fallback. IR-surface-only (identical `rt_simd` heads either way). Reconcile.
2. **The exact `mem64_max_pages` runtime cap (§H.1).** 08 pins it against `memory64.wast` + wasmtime;
   the keystone ships a provisional `2^32` pages. Confirm 08 owns the value + the citation, and that it
   is the *implementation* cap (not validate's `2^48`-page declarable limit).
3. **The cross-module closure return shape (§I.2, seam 4).** Single-`Dynamic` package (recommended,
   matches `function_return`) vs `List(Dynamic)` (aligns with a value-list invoke ABI). 09 finalizes.
4. **v128-typed global storage (seam 5).** Reuse `ref_globals` (recommended — keeps the numeric `Int`
   path byte-identical) or add a parallel `v128_globals`? An `rt_state` seam (06/08/09); the keystone
   flags the shape but does not own it.
5. **The threaded cross-module reach (§I.2).** How far does `linking.wast` extend across the
   `state_strategy × mem_tier` matrix vs an honest categorized edge (I5, Open Q d)? 09 + the
   reconciliation decide; the keystone freezes the closure contract, not the matrix.
6. **A distinct SIMD/memory64 trap message? (§E).** The keystone reuses `MemoryOutOfBounds` with **zero**
   new `TrapReason` variants and argues no SIMD op traps. If a pinned `simd/*.wast`/`memory64.wast`
   `assert_trap` distinguishes a message the existing set cannot produce, add **exactly one** variant +
   `spec_trap_message` (a conscious add). Expected: **none** — flagged so it is not silent.
7. **`rt_simd` placeholder body: `panic` vs a conservative value (§G.2).** Recommend **`panic`**
   (fail-loud, `todo`-free, never reached before 07). If the manager prefers a green-but-inert value
   (`<<0:128>>`), it risks a spurious pass; `panic` is the fail-closed choice. Reconcile if desired.
