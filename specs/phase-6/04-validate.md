# Unit P6-04 — WASM `validate` extension (typing SIMD + closing memory64 & cross-module gaps)

> **One owner · Wave A · AST-only.** Gates on **`«WASM-AST4»`** (unit **P6-03** decode's type
> stub, published day 1) — *not* on completed decoding — and runs in **parallel** with all the
> IR/runtime work (it never imports `twocore/ir`). Read [`00-overview.md`](00-overview.md)
> (decisions **I1–I8**), [`PROVISIONAL-SURFACE.md`](PROVISIONAL-SURFACE.md), and (when it lands)
> `RECONCILIATION.md` first; where reconciliation conflicts with this doc, reconciliation wins.
> D1 (single-owner-per-file), D3a (no ambient authority), D5 (floats/v128 as raw bits), D6 (neutral
> op names), I7 (conformance-neutral by default), and the Definition of Done still hold. This unit
> **extends** the existing [`phase-5/04-validate.md`](../phase-5/04-validate.md) validator — the
> Phase-1/2 polymorphic-stack / label / else-less-`if` / `max_locals` machinery, and the whole
> Phase-5 reference-types / bulk / multi-memory / memory64-typing / import surface, are kept
> **verbatim**. Phase 6 adds exactly three things to this file: **SIMD typing**, a **verification +
> gap-close of memory64 `i64`-address typing** (the runtime lands in Phase 6, R12→I4, but the typing
> is already spec-complete — confirm it), and a documented **cross-module function-import typing**
> boundary.

---

## Context

`validate.gleam` is the **security boundary** (overview D4/D9, I6). Its input AST is populated by
`frontend/wasm/decode.gleam` from **UNTRUSTED** bytes; everything downstream — `lower` (P6-05),
`emit_core` (P6-06), `rt_simd`/`rt_mem`/`link` (P6-07/08/09), the runtime — *trusts* that a module
which validated is well-typed, so it emits straight-line lane code with **no re-checks**. Phase 1
shipped a faithful transcription of the spec's abstract stack-typing algorithm; Phase 2 extended it
to the full WASM-1.0 op set; Phase 5 (P5-04) completed the standardized surface **minus SIMD** —
reference types, typed `select`, reftype-typed multi-tables, bulk memory & table ops, multi-memory
`memidx` routing, **memory64 `i64`-address typing** (decode/validate-only; runtime deferred to Phase
6, R12), and non-function imports wired into the `imports ++ defined` index spaces.

Phase 6 closes the last gap in the standardized surface. The validator must now type-check — and,
critically, **fail-closed-reject** — the **fixed-width SIMD** instruction set (the `v128` value type
+ the 236 standardized vector instructions), while **confirming** the memory64 typing shipped in P5
is complete (its runtime now lands, so a mis-typing here would surface as a real bug), and
**documenting** that cross-module function imports type against the import's *declared* `FuncType`
(the link-time *satisfaction* is P6-09's, not validate's). Specifically:

- **`v128` as a first-class value type** — a *vector type* (§C), distinct from the number types and
  from the reference types. It flows through function signatures, globals, locals, block results,
  and the abstract operand stack exactly like any other value type (the machinery is untouched); it
  is permitted by **untyped `select`** (a vector type, not a reference type — §C.3), rejected by
  `ref.is_null` (not a reference), and carried opaquely (D5: 16 raw bytes, never a decoded lane
  structure at this layer).
- **SIMD lane instructions** — the pure lane-wise arithmetic / comparison / bitwise / shift /
  boolean-reduction / conversion / narrow / widen / extend / extmul / dot / pairwise families
  (§D), each with an exact abstract-stack signature over `{v128, i32, i64, f32, f64}`.
- **Lane-immediate ops** — `extract_lane`/`replace_lane` (lane index `< dim(shape)`), `i8x16.shuffle`
  (16 immediate lane indices, each `< 32`) (§D.5/§D.6): the immediate bounds are a **validation**
  rule, checked here.
- **The v128 memory family** — `v128.load`/`store`, the splat/extend/zero loads, and the
  `load/store{8,16,32,64}_lane` ops (§E): each routes through a `memarg` whose **alignment cap is the
  access width** (`2^align ≤ N/8`), whose **address operand type follows the memory's index width**
  (`i32` for a 32-bit memory, `i64` for a 64-bit one — the memory64 seam), and whose **lane index
  (for the lane variants) is `< 128/N`**.
- **memory64 confirmation** (§F) — P5-04 already types `i64` addresses everywhere; Phase 6's runtime
  makes a mis-typing *dangerous*, so this unit re-derives every memory64 typing rule against the spec
  and asserts no gap (SIMD memory ops must use the same `mem_addr_type` seam; the **validation limit**
  stays the spec's `2^48` pages, distinct from P6-08's smaller *runtime* page cap).
- **Cross-module function-import typing** (§G) — validate types a `call` to an imported function
  against the import's **declared** `FuncType` (already wired in P5 via the `imports ++ defined`
  func index space); this is **unchanged** in Phase 6. The cross-instance *dispatch* and the
  fail-closed *satisfaction* of the import are P6-09's, flagged here so the two units do not
  double-own the import contract.

The validator gates **independently of the IR**: a type-unsafe module must be rejected here even if
the backend would coincidentally have produced something. Every ill-typed SIMD fixture must be
rejected with a **spec-cited** `ValidateError`; the worst case of a lane-index / alignment / operand
bug must be a wrong/missing *validation* rejection, **never** a host escape (I6). Because `rt_simd`
emits straight-line lane code with no operand re-checks, this boundary is what makes the SIMD runtime
sound.

## Goal

Extend the abstract-stack validator to the 236 SIMD instructions so that (a) every well-typed module
is accepted and (b) every ill-typed module is rejected with the `ValidateError` the spec rule demands
— **without** touching the polymorphic-stack / label algorithm or the Phase-5 typing arms. Confirm
the memory64 `i64`-address typing is spec-complete now its runtime lands, and document the
cross-module function-import typing boundary. A measurable outcome: the pinned spec suite's SIMD
files (`simd_*.wast` — including the `assert_invalid` corpora in `simd_lane.wast`, `simd_align.wast`,
`simd_load*_lane.wast`, `simd_store*_lane.wast`, and the type-mismatch cases across the arithmetic
files) land on this validator and go **green** (accepted when valid; rejected for the spec-correct
reason when invalid — not silently skipped); `memory64.wast`/`memory64-imports.wast` continue to
type correctly (their runtime is P6-08); a Phase-1..5 module with no `v128` validates **byte-
identically** (I7).

## Files owned

| File | Action |
|---|---|
| `src/twocore/frontend/wasm/validate.gleam` | **EXTEND** (single-owner; AST-only — the security boundary). |
| `test/twocore/frontend/wasm/validate_test.gleam` | **EXTEND** — spec-cited acceptance + rejection tests for the SIMD ops + a memory64/cross-module confirmation set. |

No other file. This unit imports `twocore/frontend/wasm/ast` **only** (grep-proven: **no
`twocore/ir` import**), so its conformance gates independently of the backend, `rt_simd`, and the
linker.

## Deliverables & freeze milestones

This unit produces **no** cross-unit freeze milestone of its own — it is a *consumer* of
`«WASM-AST4»` and a *producer* of the extended `TypedModule` that **P6-05 (lower)** consumes. It
must, however, **confirm the `TypedModule` + `ValidateError` + `Ctx` shapes early** (a mini-freeze,
day 1 of Wave A) so P6-05 can target them — and the headline is that these shapes barely change
(SIMD needs no new `TypedModule` fact; the abstract stack absorbs `v128` generically). Deliverables:

1. One new `ValidateError` variant — `BadLaneIndex(index)` (§B.1) — additive; every Phase-1..5
   variant kept, `Unsupported` re-scoped (SIMD is no longer out of scope).
2. `v128` absorbed as a value type on the abstract stack, with the `select`/`ref.is_null`
   interactions confirmed (§C).
3. Per-op SIMD typing (§D) transcribed from the spec vector-instruction rules, each spec-cited,
   routed through one exhaustive dispatch (fail-closed §H).
4. The v128 memory family's memarg alignment caps, address typing, and lane bounds (§E).
5. A memory64 typing verification + gap-close (§F) and the cross-module function-import boundary
   note (§G).
6. Spec-cited acceptance + rejection tests (§Verification).

## Depends on (freeze milestones)

- **`«WASM-AST4»`** (P6-03 decode, published day 1) — the extended `frontend/wasm/ast.gleam`: the
  `V128` value type, the `0xFD`-prefix SIMD instruction surface (`v128.const`'s 16 immediate bytes,
  the splat/extract/replace/shuffle/swizzle ops, the pure lane ops, and the v128 memory ops with
  their `MemArg` + lane immediates). **Stub against it meanwhile** — P6-03 owns the *exact* spelling.
  Write the typing tables keyed by the spec **mnemonic + shape**; if P6-03's constructor names
  differ, only the `case` patterns change, not the rules. §A is this unit's precise expectation of
  that shape — the seam to reconcile with P6-03.
- It does **NOT** depend on `«IR4-FROZEN»`, `«RT-SIMD-SIG»`, `«MEM64-RUNTIME»`, or `«XLINK»` (AST-only
  boundary). memory64's *runtime* (P6-08) and cross-module *dispatch* (P6-09) are downstream of this
  unit's typing, not upstream.

## Scope — in / out for Phase 6

**In:** `v128` as a value type on the abstract stack + its `select`/`ref.is_null`/blocktype/global/
local interactions; typing for every SIMD instruction (const, splat, extract/replace lane, shuffle,
swizzle, all lane-wise arithmetic/comparison/bitwise/shift/test/bitmask/conversion/narrow/widen/
extend/extmul/extadd_pairwise/dot/q15mulr ops); the lane-immediate bounds (extract/replace `<
dim(shape)`; shuffle indices `< 32`; load/store-lane `< 128/N`); the v128 memory family's memarg
alignment caps (max align per access width) + `i32`/`i64` address typing + `memidx` routing;
confirmation that all Phase-5 memory64 `i64`-address typing is spec-complete; the cross-module
function-import typing boundary documentation.

**Out (defer — state it, don't drop it):**
- **Relaxed-SIMD** (the separate, non-deterministic proposal: `f32x4.relaxed_madd`, `i8x16.relaxed_swizzle`,
  the relaxed dot/laneselect/min-max/trunc families) → **later** (I8). A relaxed-SIMD leaf stays
  whatever P6-03 emits (decoder-rejected as an `UnknownSimdOpcode`); this validator does **not** grow
  a relaxed-SIMD arm, and if one ever reached here it is rejected `Unsupported("relaxed-simd")`,
  never waved through.
- **memory64 *runtime*** — the address arithmetic, the documented page cap, `grow`→-1 beyond it,
  the trap boundary (P6-08). This unit only *types* memory64 (it already did in P5). The
  **validation** limit stays `2^48` pages; the smaller **runtime** cap is P6-08's trap boundary, not
  a validation rejection (§F — a spec-legal-but-runtime-capped memory must **validate**).
- **Cross-module link-time satisfaction** — whether a provided function actually matches, the
  closure-dispatch capability, `(register …)`, `assert_unlinkable` (P6-09). This unit types the
  import *shape* (its declared `FuncType` in the index space); the *satisfaction* is P6-09 (§G).
- **All runtime trap behaviour** (SIMD memory OOB, memory64 OOB / over-cap) is **dynamic**, not
  validation. SIMD lane ops **never trap** (I3): there is no SIMD divide-trap, saturation replaces
  overflow-trap; the only SIMD trap surface is the memory-bounds trap on a v128 load/store, which is
  a *runtime* check (P6-07/08), not a validation one. `i8x16.swizzle`'s out-of-range index yielding
  `0` is a **runtime** semantics, not a validation error (indices are dynamic v128 lanes, not
  immediates).
- **GC-proposal reference types / the extended-const proposal** — unchanged from P5 (still deferred /
  categorized-skip).

---

## A. The `«WASM-AST4»` surface this unit consumes (the P6-03 seam)

This is the **precise shape** the typing rules below assume. P6-03 owns the final spelling; where a
name is provisional it is flagged. If P6-03 diverges, keep the *rules* and re-map the `case`
patterns. (Contrast the EM's `PROVISIONAL-SURFACE.md`, which froze the **IR4** shapes — `TV128`,
`SimdOp`, the `Simd`/`SimdShuffle`/`SimdLoad*` `Expr` nodes; this section is the parallel **AST4**
expectation, since `validate` reads the AST, never the IR. The AST is WASM-shaped and stays a private
decoder representation.)

### A.1 `v128` as a value type

```gleam
// ast.gleam — ValType gains ONE constructor (byte-identical for non-v128 modules):
pub type ValType {
  I32  I64  F32  F64
  FuncRef  ExternRef
  V128            // NEW — 0x7B, the 128-bit vector value type (spec binary/types §vectype)
}
```

`v128` is a **vector type** (`vectype`), a third category alongside the four number types
(`numtype`) and the two reference types (`reftype`) — spec
[`syntax/types` — Value Types](https://webassembly.github.io/spec/core/syntax/types.html#value-types).
The classification matters for exactly one existing typing rule: **untyped `select`** accepts a
number *or vector* type but not a reference type (§C.3). Everywhere else `v128` is just another
`ValType` on the abstract stack — no machinery change.

> **Cross-unit seam.** `V128` on `ast.ValType` breaks every exhaustive `case` on `ast.ValType`
> across the frontend. P6-03 owns the AST-side addition and its byte `0x7B`; the IR-side `TV128`
> is P6-01's (`PROVISIONAL-SURFACE.md` §A). This unit only reads the AST `V128`.

### A.2 The SIMD instruction surface

**RECOMMENDED shape (a deviation — argued in "Deviations", §Deviations D1):** wrap the SIMD
instruction set in a dedicated AST sub-enum carried by **one** `Instr` constructor, mirroring the
IR4 `Simd(SimdOp)` design and — critically — giving this validator a **single, compiler-checked
exhaustive** dispatch arm (fail-closed by construction; §H):

```gleam
// ast.gleam — Instr gains ONE SIMD constructor carrying an exhaustive sub-enum:
pub type Instr {
  // …existing Phase-1..5 instructions, verbatim…
  Simd(SimdInstr)        // 0xFD <u32 sub-opcode> — all 236 vector instructions
}

/// The fixed-width SIMD instruction set (spec binary/instructions §vector). The
/// memarg/lane immediates ride as fields where they are static immediates.
pub type SimdInstr {
  // constants / lane build
  V128Const(bytes: BitArray)                       // 16 immediate bytes
  I8x16Shuffle(lanes: List(Int))                   // 16 lane immediates, each 0..31
  I8x16Swizzle
  I8x16Splat  I16x8Splat  I32x4Splat  I64x2Splat  F32x4Splat  F64x2Splat
  I8x16ExtractLaneS(lane: Int)  I8x16ExtractLaneU(lane: Int)  I8x16ReplaceLane(lane: Int)
  I16x8ExtractLaneS(lane: Int)  I16x8ExtractLaneU(lane: Int)  I16x8ReplaceLane(lane: Int)
  I32x4ExtractLane(lane: Int)   I32x4ReplaceLane(lane: Int)
  I64x2ExtractLane(lane: Int)   I64x2ReplaceLane(lane: Int)
  F32x4ExtractLane(lane: Int)   F32x4ReplaceLane(lane: Int)
  F64x2ExtractLane(lane: Int)   F64x2ReplaceLane(lane: Int)
  // pure lane-wise ops (arith / cmp / bitwise / shift / test / bitmask / convert / …)
  //   — one constructor per op (§D enumerates every one), no immediates
  V128Not  V128And  V128AndNot  V128Or  V128Xor  V128Bitselect  V128AnyTrue
  I8x16Add  I8x16Sub  /* … see §D … */
  // v128 memory family (carry a MemArg; the lane variants also a lane index)
  V128Load(MemArg)  V128Store(MemArg)
  V128Load8Splat(MemArg)  V128Load16Splat(MemArg)  V128Load32Splat(MemArg)  V128Load64Splat(MemArg)
  V128Load8x8S(MemArg)  V128Load8x8U(MemArg)  V128Load16x4S(MemArg)  V128Load16x4U(MemArg)
  V128Load32x2S(MemArg)  V128Load32x2U(MemArg)  V128Load32Zero(MemArg)  V128Load64Zero(MemArg)
  V128Load8Lane(MemArg, lane: Int)   V128Load16Lane(MemArg, lane: Int)
  V128Load32Lane(MemArg, lane: Int)  V128Load64Lane(MemArg, lane: Int)
  V128Store8Lane(MemArg, lane: Int)  V128Store16Lane(MemArg, lane: Int)
  V128Store32Lane(MemArg, lane: Int) V128Store64Lane(MemArg, lane: Int)
}
```

The `MemArg` shape is **unchanged** from P5 (`MemArg(align, offset, mem)`, §A.3 below); the SIMD
memory ops reuse it (multi-memory `memidx` + memory64 `u64` offset already handled). If P6-03 prefers
a *flat* Instr surface (one `Instr` constructor per SIMD op, mirroring the scalar-AST idiom), the
typing rules are identical — but the fail-closed guarantee then requires that **every** SIMD
constructor be intercepted in `validate_instr` before the numeric fallthrough (§H). The recommended
grouped shape makes that guarantee a compiler invariant rather than a review obligation.

### A.3 Unchanged from `«WASM-AST3»`

`MemArg(align: Int, offset: Int, mem: Int)`, `IdxType {Idx32 Idx64}`, `MemType(limits, idx_type)`,
the import/export/segment shapes, and every scalar instruction constructor are consumed **verbatim**
from P5. This unit adds no requirement on them beyond what P5-04 already stated.

---

## B. `ValidateError`, `Ctx`, and `TypedModule` — the (minimal) Phase-6 delta

### B.1 `ValidateError` — one new variant (additive; keep every Phase-1..5 variant)

```gleam
pub type ValidateError {
  // … every Phase-1..5 variant kept verbatim: TypeMismatch, Underflow, UnknownLocal,
  //   UnknownGlobal, UnknownFunc, UnknownType, UnknownLabel, UnknownMemory, UnknownTable,
  //   ImmutableGlobal, BadAlignment, NonConstantExpr, BadLimits, TooManyMemories,
  //   TooManyTables, BadStartType, BranchArityMismatch, IfElseMismatch, UnexpectedEnd,
  //   TooManyLocals, Unsupported, OffsetOutOfRange, UnknownData, UnknownElem,
  //   UndeclaredFunctionRef, RefTypeMismatch, BadSelectType, UnknownImportKind …
  BadLaneIndex(index: Int)         // NEW — a static lane immediate out of range
}
```

Notes on variant choice (spec-honest, diagnosable):

- **`BadLaneIndex(index)` is the one genuinely-new rejection.** It fires when a static lane immediate
  exceeds its bound: `extract_lane`/`replace_lane` with `lane ≥ dim(shape)` (spec
  [`valid/instructions` — `shape.extract_lane`/`replace_lane`](https://webassembly.github.io/spec/core/valid/instructions.html#vector-instructions):
  "the lane index `x` must be smaller than `dim`"); `i8x16.shuffle` with any of its 16 indices `≥ 32`
  ("for all `i`, `x_i < 32`"); `load/store{8,16,32,64}_lane` with `lane ≥ 128/N`. It carries the
  offending index for diagnosis. Reusing `TypeMismatch` would be *wrong* (this is not an operand-type
  disagreement); a dedicated variant is correct and the conformance runner asserts *a* rejection,
  never message text.
- **`BadAlignment` is REUSED for the v128 memory ops** (not a new variant). The memarg alignment rule
  `2^align ≤ N/8` (spec `valid/instructions` memarg) is the *same rule* as the scalar loads/stores,
  only with a different per-op `N`; `check_align(memarg, max_align)` already implements exactly
  `align > max_align → BadAlignment`. `simd_align.wast`'s `assert_invalid` "alignment must not be
  larger than natural" routes to `BadAlignment` (§E).
- **`OffsetOutOfRange` is REUSED** for a v128 memory op with a static offset `≥ 2^32` on a 32-bit
  memory (§E/§F) — identical to the scalar rule.
- **`Unsupported(detail)` is RE-SCOPED, not removed.** In P5 it was reserved for "a `v128`/SIMD leaf
  or a GC reftype". SIMD is now **in scope**, so it is reserved for the genuinely-deferred
  constructs: relaxed-SIMD (if one ever decodes) and GC-proposal reftypes. It remains a fail-closed
  reject, never a wave-through. Keep the variant (removing it is an API break; an unused public
  constructor does not warn in Gleam, so DoD "zero warnings" holds).
- **No new v128-specific type-mismatch variant.** A wrong operand to a SIMD op (e.g. `i32x4.add` fed
  an `f32`, or `i8x16.replace_lane` fed an `i64`) is a plain `TypeMismatch` — the abstract stack's
  `pop_expect` produces it uniformly. `v128` is just a `ValType`; there is nothing reference-shaped
  about it that would want `RefTypeMismatch`.

### B.2 `Ctx` — unchanged

The Phase-5 `Ctx` (types, func_types, globals, imported_global_count, tables, memories, data_count,
elem_types, refs, locals) is **unchanged**. SIMD needs no new module-level fact: every SIMD op's
type is fully determined by its own constructor + the memory it touches (via `ctx.memories`, already
present). `v128` locals/params/globals flow through the existing `locals`/`globals`/`func_types`
lists as an ordinary `ValType`.

### B.3 `TypedModule` — unchanged (a conformance-neutrality result)

The Phase-5 `TypedModule` is **structurally unchanged**. SIMD adds no typing fact that lowering
cannot re-derive from the instruction constructor itself (the discipline P5-04 fixed: "load result
widths live on the opcode"). A SIMD op's result type — `v128`, or the `i32`/`i64`/`f32`/`f64` of an
extract-lane / test / bitmask — is a static function of the constructor, so P6-05 reads it off the
op, exactly as it reads a scalar load's width. `v128` may appear as a value type *inside* the
existing fields (a `v128` param in `func_types`, a `v128` global in `global_types`, a `v128` local in
`func_locals`) — that is data flowing through unchanged fields, not a new field. **This is the
headline conformance-neutrality fact for validate: a module with no `v128` produces a
byte-identical `TypedModule`, and a module *with* `v128` needs no new typing map.**

For **cross-module function imports**, the linker (P6-09) consumes `TypedModule.module.imports` +
`TypedModule.imported_func_count` + `TypedModule.func_types` (the imports-first func space) to build
its fail-closed match table — all already present since P5 (§G). No new field.

---

## C. `v128` as a value type — the abstract stack & existing-rule interactions

Spec: [`syntax/types` — Value Types](https://webassembly.github.io/spec/core/syntax/types.html#value-types),
[`valid/instructions`](https://webassembly.github.io/spec/core/valid/instructions.html).

### C.1 The stack machinery is untouched

`StackType` already wraps an arbitrary `ast.ValType`; `Known(ast.V128)` needs no new constructor.
`push_val`/`pop_val`/`pop_expect`/`pop_vals`/`push_vals`/`types_match` all operate on `ValType`
generically, so `v128` participates in the abstract stack, `unreachable` polymorphism, block
result-checking, and branch-arity checking with **zero** machinery change (the P5-04 discipline of
keeping the algorithm verbatim). A `block (result v128)`, a `br` carrying a `v128`, a `v128` function
result, a `v128` local — all validate through the existing code the moment `V128` is a `ValType`.

### C.2 `v128` signatures / globals / locals

- **Function signatures / blocktypes:** a `FuncType` or `BlockVal(V128)` with `v128` params/results
  type-checks generically (`blocktype_types` is unchanged).
- **Globals:** a `v128` global is validated like any other — its init is a constant expression of
  type `v128` (§C.4). `global.get`/`global.set` push/pop `v128` via the existing arms.
- **Locals:** a `v128` local is counted against `max_locals` (unchanged) and typed by `local_type`.

### C.3 Untyped `select` accepts `v128` (a confirmed conformance point — NO code change)

Spec [`valid/instructions` — Parametric](https://webassembly.github.io/spec/core/valid/instructions.html#parametric-instructions):
untyped `select` (0x1B) has type `[t t i32] → [t]` where **`t` is a number type *or a vector type*** —
i.e. **not** a reference type. So `select` of two `v128`s is **valid** (untyped), while `select` of
two references still requires the typed `select t` form.

The existing untyped-`select` arm already implements this correctly by construction: it rejects only
when `is_reftype(vt) == True`, and `is_reftype(V128) == False` (it matches only `FuncRef`/`ExternRef`).
So a `v128`/`v128` pair falls through to acceptance. **Confirm this with a test** (`simd_select.wast`
exercises `select` of `v128`), but write **no** code change — document that the `is_reftype` guard is
the load-bearing predicate and that `v128` is deliberately *not* a reftype, so the existing arm is
already spec-correct. (Were `v128` ever mis-classified into `is_reftype`, untyped `select` of vectors
would wrongly reject — a change-detector regression the `simd_select.wast` acceptance test guards.)

### C.4 `ref.is_null`, const-exprs, and `v128`

- **`ref.is_null` on a `v128` → `TypeMismatch`.** `ref.is_null` is reference-polymorphic: it pops an
  operand that must be a reference type (`is_reftype` True) or `Unknown`. `v128` is neither → the
  existing arm returns `TypeMismatch`, which is spec-correct (`ref.is_null` accepts only references).
  No code change; confirm with a test.
- **`v128.const` in a constant expression.** `v128.const c` is a valid constant instruction (spec
  [`valid/instructions` — Constant Expressions](https://webassembly.github.io/spec/core/valid/instructions.html#constant-expressions)
  lists `t.const`, which includes `v128.const`). Extend `validate_const_expr` with one arm:
  ```gleam
  [ast.Simd(ast.V128Const(_))] -> expect_const_type(ast.V128, expected)
  ```
  so a `v128` global initialized by `v128.const` validates (`simd_const.wast` exercises this). No
  other SIMD op is a constant instruction (they are not in the const grammar) → any other
  `Simd(_)` in a const-expr falls to `NonConstantExpr`, spec-correct.

---

## D. SIMD lane instructions — the abstract-stack typing rules (full enumeration)

Spec: [`valid/instructions` — Vector Instructions](https://webassembly.github.io/spec/core/valid/instructions.html#vector-instructions).
Binary opcodes: [`binary/instructions` — Vector Instructions](https://webassembly.github.io/spec/core/binary/instructions.html#vector-instructions)
(the `0xFD` prefix + a `u32` sub-opcode — P6-03's concern; sub-opcodes are given here only to anchor
the mnemonics). Every rule below is the spec's abstract-stack signature. There are **no traps** in
this section (I3): all SIMD lane ops are total; saturation replaces overflow, `swizzle` OOB→0 is
runtime, division-by-zero does not arise (there is no integer SIMD divide).

Two definitions used throughout (spec `valid/instructions`, vector conventions):

- **`dim(shape)`** — the lane count: `i8x16 = 16`, `i16x8 = 8`, `i32x4 = 4`, `i64x2 = 2`,
  `f32x4 = 4`, `f64x2 = 2`.
- **`unpacked(shape)`** — the scalar type a lane packs/extracts to: `i8x16 → i32`, `i16x8 → i32`,
  `i32x4 → i32`, `i64x2 → i64`, `f32x4 → f32`, `f64x2 → f64`. (Lanes narrower than 32 bits unpack to
  `i32`, hence the sign-choosing `extract_lane_s`/`_u`; 32-bit-and-wider lanes unpack to their own
  width.)

### D.1 Fixed-signature ops — the `simd_sig` table

The bulk of the 236 ops have a **static** operand→result signature over `{v128, i32, i64, f32, f64}`
with no immediate. They are typed by a `simd_sig(SimdInstr) -> #(List(ValType), List(ValType))` table
(the exact analogue of the existing `numeric_sig`), applied by a `validate_simd_sig` helper that pops
the operands and pushes the results. The five signature classes, **fully enumerated**:

#### D.1.1 `[v128] → [v128]` — vector unary (`vunop`, `vvunop`, `vcvtop`)

| shape / op | mnemonics |
|---|---|
| bitwise unary (`vvunop`) | `v128.not` |
| int abs/neg | `i8x16.abs` `i8x16.neg` · `i16x8.abs` `i16x8.neg` · `i32x4.abs` `i32x4.neg` · `i64x2.abs` `i64x2.neg` |
| `i8x16.popcnt` | `i8x16.popcnt` |
| float unary | `f32x4.abs` `f32x4.neg` `f32x4.sqrt` `f32x4.ceil` `f32x4.floor` `f32x4.trunc` `f32x4.nearest` · `f64x2.abs` `f64x2.neg` `f64x2.sqrt` `f64x2.ceil` `f64x2.floor` `f64x2.trunc` `f64x2.nearest` |
| widen (extend low/high, s+u) | `i16x8.extend_low_i8x16_s` `…_high_…_s` `…_low_…_u` `…_high_…_u` · `i32x4.extend_{low,high}_i16x8_{s,u}` · `i64x2.extend_{low,high}_i32x4_{s,u}` |
| extadd_pairwise | `i16x8.extadd_pairwise_i8x16_s` `…_u` · `i32x4.extadd_pairwise_i16x8_s` `…_u` |
| conversions | `i32x4.trunc_sat_f32x4_s` `…_u` · `i32x4.trunc_sat_f64x2_s_zero` `…_u_zero` · `f32x4.convert_i32x4_s` `…_u` · `f64x2.convert_low_i32x4_s` `…_u` · `f32x4.demote_f64x2_zero` · `f64x2.promote_low_f32x4` |

All of these: `pop_expect(v128)`, `push_val(v128)`. The lane semantics (single-rounding, saturation,
NaN handling) are `rt_simd`'s (P6-07); typing only asserts `[v128] → [v128]`.

#### D.1.2 `[v128 v128] → [v128]` — vector binary (`vbinop`, `vvbinop`, `vrelop`)

| family | mnemonics |
|---|---|
| bitwise binary (`vvbinop`) | `v128.and` `v128.andnot` `v128.or` `v128.xor` |
| int add/sub | `i8x16.add` `i8x16.sub` · `i16x8.add` `i16x8.sub` · `i32x4.add` `i32x4.sub` · `i64x2.add` `i64x2.sub` |
| int saturating add/sub | `i8x16.add_sat_s` `…_u` `i8x16.sub_sat_s` `…_u` · `i16x8.add_sat_s` `…_u` `i16x8.sub_sat_s` `…_u` |
| int mul | `i16x8.mul` · `i32x4.mul` · `i64x2.mul` (**no `i8x16.mul`** — omit; it is not a standardized op) |
| int min/max (s+u) | `i8x16.{min,max}_{s,u}` · `i16x8.{min,max}_{s,u}` · `i32x4.{min,max}_{s,u}` |
| int avgr_u | `i8x16.avgr_u` · `i16x8.avgr_u` |
| `i16x8.q15mulr_sat_s` | `i16x8.q15mulr_sat_s` |
| narrow (saturating, s+u) | `i8x16.narrow_i16x8_s` `…_u` · `i16x8.narrow_i32x4_s` `…_u` |
| extmul (low/high, s+u) | `i16x8.extmul_{low,high}_i8x16_{s,u}` · `i32x4.extmul_{low,high}_i16x8_{s,u}` · `i64x2.extmul_{low,high}_i32x4_{s,u}` |
| dot | `i32x4.dot_i16x8_s` |
| float arith | `f32x4.{add,sub,mul,div,min,max,pmin,pmax}` · `f64x2.{add,sub,mul,div,min,max,pmin,pmax}` |
| swizzle | `i8x16.swizzle` (dynamic byte indices in a `v128`; OOB→0 is **runtime**, not validation) |
| comparisons (`vrelop`) → mask | `i8x16.{eq,ne,lt_s,lt_u,gt_s,gt_u,le_s,le_u,ge_s,ge_u}` · `i16x8.{…same 10…}` · `i32x4.{…same 10…}` · `i64x2.{eq,ne,lt_s,gt_s,le_s,ge_s}` · `f32x4.{eq,ne,lt,gt,le,ge}` · `f64x2.{eq,ne,lt,gt,le,ge}` |

All of these: `pop_vals([v128, v128])`, `push_val(v128)`. **Note the comparison result is a `v128`
lane mask** (all-ones/all-zeros per lane), *not* an `i32` — a common pitfall; the spec `vrelop` rule
is `[v128 v128] → [v128]`. `i64x2` has only the six signed/equality comparisons (no unsigned `lt/gt/
le/ge_u`) — enumerate exactly those.

#### D.1.3 `[v128 i32] → [v128]` — vector shifts (`vshiftop`)

`i8x16.{shl,shr_s,shr_u}` · `i16x8.{shl,shr_s,shr_u}` · `i32x4.{shl,shr_s,shr_u}` ·
`i64x2.{shl,shr_s,shr_u}`. The shift **count is an `i32`** (the second operand, on top), regardless
of lane width — the spec `vshiftop` rule is `[v128 i32] → [v128]`. Pop `i32`, pop `v128`, push
`v128`. (The count-mask-mod-lane-width is a `rt_simd` runtime semantics, not validation.)

#### D.1.4 `[v128] → [i32]` — vector test / bitmask (`vtestop`, `vvtestop`, bitmask)

`v128.any_true` · `i8x16.all_true` `i16x8.all_true` `i32x4.all_true` `i64x2.all_true` ·
`i8x16.bitmask` `i16x8.bitmask` `i32x4.bitmask` `i64x2.bitmask`. Pop `v128`, push `i32`. (`any_true`
is shape-agnostic — it tests the whole `v128`; `all_true`/`bitmask` are per-shape but share this
signature.)

#### D.1.5 `[v128 v128 v128] → [v128]` — vector ternary (`vvternop`)

`v128.bitselect` — pop three `v128`, push one. The mask-select lane semantics are `rt_simd`'s.

### D.2 `v128.const` — `[] → [v128]`

`v128.const c` (0xFD 0x0C, 16 immediate bytes): pushes a `v128`. The 16-byte immediate is opaque data
(D5 — the raw bits, decoded by P6-03 as a `BitArray`; validate does not interpret lanes). Signature
`[] → [v128]`. Also valid as a constant expression (§C.4). Cite `simd_const.wast`.

### D.3 Splat — `[unpacked(shape)] → [v128]`

| op | operand | result |
|---|---|---|
| `i8x16.splat` | `i32` | `v128` |
| `i16x8.splat` | `i32` | `v128` |
| `i32x4.splat` | `i32` | `v128` |
| `i64x2.splat` | `i64` | `v128` |
| `f32x4.splat` | `f32` | `v128` |
| `f64x2.splat` | `f64` | `v128` |

Spec `shape.splat`: `[unpacked(shape)] → [v128]`. Pop the scalar of the shape's unpacked type, push
`v128`. These are fixed-signature and can live in `simd_sig` (no immediate). A wrong scalar (e.g.
`i64x2.splat` fed an `i32`) → `TypeMismatch`. Cite `simd_splat.wast`.

### D.4 Extract-lane — `[v128] → [unpacked(shape)]`, lane `< dim(shape)`

| op | result | lane bound |
|---|---|---|
| `i8x16.extract_lane_s` / `_u` | `i32` | `lane < 16` |
| `i16x8.extract_lane_s` / `_u` | `i32` | `lane < 8` |
| `i32x4.extract_lane` | `i32` | `lane < 4` |
| `i64x2.extract_lane` | `i64` | `lane < 2` |
| `f32x4.extract_lane` | `f32` | `lane < 4` |
| `f64x2.extract_lane` | `f64` | `lane < 2` |

Spec `shape.extract_lane_sx x`: "the lane index `x` must be smaller than `dim(shape)`", type
`[v128] → [unpacked(shape)]`. **Explicit arm** (the lane immediate must be range-checked *before*
the stack op): `check_lane(lane, dim)` → `BadLaneIndex(lane)` if `lane ≥ dim` (or `< 0`, defensively);
then pop `v128`, push the unpacked type. `_s`/`_u` differ only in runtime sign-extension, not typing.
Cite `simd_lane.wast` (its `assert_invalid` "invalid lane index" corpus).

### D.5 Replace-lane — `[v128 unpacked(shape)] → [v128]`, lane `< dim(shape)`

| op | operand (scalar, on top) | lane bound |
|---|---|---|
| `i8x16.replace_lane` | `i32` | `lane < 16` |
| `i16x8.replace_lane` | `i32` | `lane < 8` |
| `i32x4.replace_lane` | `i32` | `lane < 4` |
| `i64x2.replace_lane` | `i64` | `lane < 2` |
| `f32x4.replace_lane` | `f32` | `lane < 4` |
| `f64x2.replace_lane` | `f64` | `lane < 2` |

Spec `shape.replace_lane x`: lane `x < dim(shape)`, type `[v128 unpacked(shape)] → [v128]`. **Explicit
arm:** `check_lane(lane, dim)`; then `pop_vals([v128, unpacked])` (scalar on top), `push_val(v128)`.
A wrong scalar → `TypeMismatch`; an out-of-range lane → `BadLaneIndex`. Cite `simd_lane.wast`.

### D.6 Shuffle & swizzle

- **`i8x16.shuffle x^16`** (0xFD 0x0D): 16 immediate lane indices, **each `< 32`** (they select bytes
  from the 32-byte concatenation of the two operands). Spec `i8x16.shuffle`: "for all `i`, `x_i < 32`",
  type `[v128 v128] → [v128]`. **Explicit arm:** check all 16 indices with `check_lane(x_i, 32)`
  (`BadLaneIndex(x_i)` on the first offender), *and* assert there are exactly 16 (a decode invariant;
  defensively `list.length(lanes) == 16` else `BadLaneIndex` — see Open Q 2); then `pop_vals([v128,
  v128])`, `push_val(v128)`. Cite `simd_lane.wast` (its shuffle `assert_invalid` cases).
- **`i8x16.swizzle`** (0xFD 0x0E): `[v128 v128] → [v128]`, no immediate — the indices are *dynamic*
  v128 lanes (an OOB index yields `0` at **runtime**, not a validation error). Fixed-signature →
  `simd_sig` (§D.1.2).

### D.7 The dispatch — one exhaustive `validate_simd`

`validate_instr` gains **one** arm: `ast.Simd(s) -> validate_simd(st, s, ctx)`. `validate_simd` is an
**exhaustive** `case s` (the Gleam compiler enforces exhaustiveness — the fail-closed guarantee, §H):
the memory ops route to §E, the lane-immediate ops (extract/replace/shuffle) to their §D.4/§D.5/§D.6
explicit handling, and every other op to `validate_simd_sig(st, simd_sig(s))`. `simd_sig` has an
explicit arm for **every** fixed-signature op (§D.1–D.3) — there is **no** `_ -> #([], [])` catch-all
in `simd_sig` (unlike `numeric_sig`, whose catch-all is safe only because `validate_simd` intercepts
all SIMD ops first). Any op reachable only from a future proposal is a compile error until given an
arm — fail-closed by construction.

---

## E. The v128 memory family — memarg alignment caps, address typing, lane bounds

Spec: [`valid/instructions` — Vector Memory Instructions](https://webassembly.github.io/spec/core/valid/instructions.html#vector-memory-instructions).
Every v128 memory op carries a `MemArg(align, offset, mem)`. Three checks, in order, then the stack
op:

1. **Resolve the memory + address width** — `at = mem_addr_type(ctx, memarg.mem)` (`i32` for a 32-bit
   memory, `i64` for a 64-bit one; out of range → `UnknownMemory(memarg.mem)`). **This is the
   memory64 seam — the SIMD memory ops use the *same* `mem_addr_type` as the scalar ops (§F), so a
   `v128.load` on a 64-bit memory pops an `i64` address.**
2. **Alignment cap** — `check_align(memarg, max_align)` where `max_align = log2(N/8)` and `N` is the
   number of **bits accessed** (spec memarg rule `2^align ≤ N/8`). `BadAlignment` on violation. **The
   cap follows the *access* width, not the address width** — identical for 32- and 64-bit memories.
3. **Offset ceiling** — `check_offset(memarg, at)` (`< 2^32` on a 32-bit memory → else
   `OffsetOutOfRange`; unbounded within `u64` on a 64-bit memory) — reused verbatim from P5.
4. **Lane bound (lane variants only)** — `check_lane(lane, 128/N)` → `BadLaneIndex` (see the table).

The **full enumeration** of the family (with the exact per-op `N`, `max_align`, lane bound, and
signature — the address operand type is `at` per step 1):

| op | sub-opcode | bits `N` | `max_align` | lane bound | signature |
|---|---|---|---|---|---|
| `v128.load` | 0xFD 0 | 128 | 4 | — | `[at] → [v128]` |
| `v128.load8x8_s` | 0xFD 1 | 64 | 3 | — | `[at] → [v128]` |
| `v128.load8x8_u` | 0xFD 2 | 64 | 3 | — | `[at] → [v128]` |
| `v128.load16x4_s` | 0xFD 3 | 64 | 3 | — | `[at] → [v128]` |
| `v128.load16x4_u` | 0xFD 4 | 64 | 3 | — | `[at] → [v128]` |
| `v128.load32x2_s` | 0xFD 5 | 64 | 3 | — | `[at] → [v128]` |
| `v128.load32x2_u` | 0xFD 6 | 64 | 3 | — | `[at] → [v128]` |
| `v128.load8_splat` | 0xFD 7 | 8 | 0 | — | `[at] → [v128]` |
| `v128.load16_splat` | 0xFD 8 | 16 | 1 | — | `[at] → [v128]` |
| `v128.load32_splat` | 0xFD 9 | 32 | 2 | — | `[at] → [v128]` |
| `v128.load64_splat` | 0xFD 10 | 64 | 3 | — | `[at] → [v128]` |
| `v128.store` | 0xFD 11 | 128 | 4 | — | `[at v128] → []` |
| `v128.load32_zero` | 0xFD 92 | 32 | 2 | — | `[at] → [v128]` |
| `v128.load64_zero` | 0xFD 93 | 64 | 3 | — | `[at] → [v128]` |
| `v128.load8_lane` | 0xFD 84 | 8 | 0 | `lane < 16` | `[at v128] → [v128]` |
| `v128.load16_lane` | 0xFD 85 | 16 | 1 | `lane < 8` | `[at v128] → [v128]` |
| `v128.load32_lane` | 0xFD 86 | 32 | 2 | `lane < 4` | `[at v128] → [v128]` |
| `v128.load64_lane` | 0xFD 87 | 64 | 3 | `lane < 2` | `[at v128] → [v128]` |
| `v128.store8_lane` | 0xFD 88 | 8 | 0 | `lane < 16` | `[at v128] → []` |
| `v128.store16_lane` | 0xFD 89 | 16 | 1 | `lane < 8` | `[at v128] → []` |
| `v128.store32_lane` | 0xFD 90 | 32 | 2 | `lane < 4` | `[at v128] → []` |
| `v128.store64_lane` | 0xFD 91 | 64 | 3 | `lane < 2` | `[at v128] → []` |

**Operand order (bottom → top):** for a plain load `[at]` the address is the sole operand. For
`v128.store` `[at v128]` the **address is deeper, the `v128` value is on top** (pop `v128`, then
`at`). For `load/store*_lane` `[at v128]` likewise — the address is deeper, the `v128` (the vector the
lane is inserted into / read from) is on top (pop `v128`, then `at`; a load-lane then pushes `v128`).
This mirrors the scalar `[i32 t]` store order (address deeper). Getting it backwards silently
mis-types — assert the order in a test.

Helpers (parallel to the scalar `check_load`/`check_store`):

```gleam
// pop the address, push v128 (plain + splat + extend + zero loads)
fn check_simd_load(st, ctx, memarg, max_align) -> Result(VState, ValidateError)
// pop v128 then the address (v128.store)
fn check_simd_store(st, ctx, memarg, max_align) -> Result(VState, ValidateError)
// lane bound, then pop v128 then the address, then push v128 (load*_lane)
fn check_simd_load_lane(st, ctx, memarg, max_align, lane, dim) -> Result(VState, ValidateError)
// lane bound, then pop v128 then the address (store*_lane)
fn check_simd_store_lane(st, ctx, memarg, max_align, lane, dim) -> Result(VState, ValidateError)
```

Each begins with `mem_addr_type` (step 1) + `check_align` (step 2) + `check_offset` (step 3) + (for
lane variants) `check_lane` (step 4), then the stack op. Cite `simd_load.wast`, `simd_load_splat.wast`,
`simd_load_extend.wast`, `simd_load_zero.wast`, `simd_store.wast`, `simd_load{8,16,32,64}_lane.wast`,
`simd_store{8,16,32,64}_lane.wast`, `simd_align.wast` (the `assert_invalid` alignment corpus),
`simd_address.wast`, and `simd_memory-multi.wast` (multi-memory `memidx` routing).

---

## F. memory64 — confirm the `i64`-address typing is spec-complete (verify + close gaps)

P5-04 shipped memory64 typing (R12: "VALIDATE types i64 addresses correctly"). Phase 6 lands its
**runtime** (I4), so a typing gap that was harmless in P5 (the module never ran) is now a real bug.
This unit **re-derives every memory64 typing rule against the spec and asserts no gap** — it changes
nothing that is already correct (I7: 32-bit memories stay byte-identical) and adds only the SIMD
memory ops to the same seam.

The seam is `mem_addr_type(ctx, memidx) -> at ∈ {i32, i64}` (`addr_type(Idx32)=i32`,
`addr_type(Idx64)=i64`). The verification table (spec / the
[memory64 proposal](https://github.com/WebAssembly/memory64), merged into the core spec):

| instruction | 32-bit memory | 64-bit memory | already in P5? |
|---|---|---|---|
| scalar `t.load` / `t.store` | addr `i32` | addr `i64` | ✅ (via `check_load`/`check_store` `mem_addr_type`) |
| `memory.size` | `[] → [i32]` | `[] → [i64]` | ✅ |
| `memory.grow` | `[i32] → [i32]` | `[i64] → [i64]` | ✅ |
| `memory.fill` | `[i32 i32 i32] → []` | `[i64 i32 i64] → []` (value byte stays `i32`) | ✅ |
| `memory.init` | `[i32 i32 i32] → []` | `[i64 i32 i32] → []` (src/len index the data seg → `i32`) | ✅ |
| `memory.copy dm sm` | `[i32 i32 i32] → []` | `[at(dm) at(sm) min(at(dm),at(sm))] → []` | ✅ (via `min_addr_type`) |
| active data offset | `i32` const-expr | `i64` const-expr | ✅ (via `check_data`/`mem_addr_type`) |
| memarg static offset ceiling | `< 2^32` (`OffsetOutOfRange`) | any `u64` | ✅ (via `check_offset`) |
| memarg alignment cap | `2^align ≤ N/8` (access width) | same (access width) | ✅ (via `check_align`) |
| **v128 memory ops (NEW)** | addr `i32` | addr `i64` | **✅ this unit — §E uses `mem_addr_type`** |

**Verification conclusion:** the P5 memory64 typing is spec-complete; the only Phase-6 addition is
routing the v128 memory family through the *same* `mem_addr_type` seam (§E), so a `v128.load` on a
64-bit memory pops `i64` exactly as a scalar load does. **Gaps closed:** none in the scalar surface
(re-asserted by test); the SIMD surface is covered by §E by construction.

**Two seams to pin (do not double-own):**

1. **The validation limit is `2^48` pages, NOT the runtime cap.** `memory64_page_limit = 2^48`
   (`281_474_976_710_656`) is the spec's abstract limit range for an `i64` memory (address space
   `2^64` bytes ÷ `2^16` bytes/page). It is **unchanged**. P6-08 introduces a *smaller* documented
   **runtime** page cap (`mem64_max_pages` on the `Binding`, I4) as a *trap boundary* — that cap is
   **not** a validation rejection. A 64-bit memory declaring `min ≤ 2^48` **validates** (it is
   spec-legal) even though growth beyond the smaller runtime cap fails (`grow → -1`) or an access
   beyond the current size traps at runtime (P6-08). **Do not** import the runtime cap into
   validation — that would wrongly reject spec-valid modules and break conformance. Flagged so P6-08
   and this unit do not double-own the memory64 limit.
2. **memory64 `atomics`/`nif` tier fail-closed is a linker/binding concern (P6-08/09), not
   validation.** Validate types a 64-bit memory identically regardless of the memory tier; the
   over-cap fail-closed gate for `atomics`/`nif` is enforced at instantiate/link time (I4), not here.

Cite `memory64.wast`, `memory64-imports.wast`, `float_memory64.wast`.

---

## G. Cross-module function-import typing — the declared `FuncType` boundary

Spec: [`valid/modules` — Imports](https://webassembly.github.io/spec/core/valid/modules.html#imports).
Phase 6 adds cross-module function *dispatch* (I5 — a linker-built closure capability, P6-09), but
the **typing is unchanged from P5** and is stated here so the boundary is explicit and not
double-owned.

- **An imported function types against its *declared* `FuncType`.** P5-04 already builds the func
  index space `imports ++ defined` (`imported_func_types` resolves each `ImportFunc(type_idx)` against
  `module.types` → `UnknownType` if out of range; imports occupy the low funcidx slots). So a `call f`
  where `f` addresses an imported function type-checks against `func_types[f]` — the import's declared
  signature — via the existing `ast.Call` arm. **This is complete and unchanged.** `call_indirect`
  through an imported table likewise types against its static `typeidx` (unchanged). Confirm with a
  test (a module importing `(func (param i32) (result i32))` and calling it).
- **Validation does not check import *satisfaction*.** Whether a *provided* function actually matches
  the declared type — the fail-closed `assert_unlinkable` — is **P6-09's** link-time contract, not
  validation's. A module that imports a function no other module provides still **type-checks**
  against its declared import type; the *link* fails, not validation. **Seam:** the two units must not
  double-own the import contract — validate owns the *shape* (the declared `FuncType` in the index
  space), P6-09 owns the *satisfaction* (the closure capability + the type match at link time). This
  is the same seam P5-04 flagged with P5-09, now extended to cross-instance *dispatch* (which is
  invisible to validate — it types a `call`, the linker builds the closure `emit_core` applies).
- **What the linker consumes from `TypedModule`** (already present, §B.3): `module.imports` (the
  module/name pairs + the `ImportFunc(type_idx)` descriptors), `imported_func_count` (the funcidx
  offset), and `func_types` (imports-first, so `list.take(func_types, imported_func_count)` is the
  imported functions' declared signatures in order). P6-09 builds its fail-closed match table from
  these. **No new `TypedModule` field is needed.**
- **Per-instance policy (I6).** A Safe instance importing an Unsafe instance's function is governed
  by the existing per-instance policy (the callee runs under its own linked runtime); this is a
  link/profile concern (P6-09), invisible to validation. Validate types the import shape identically
  regardless of the exporter's mode.

Cite `linking.wast`, `linking0..3.wast`, `simd_linking.wast` (a module importing/exporting a `v128`
global across modules — the declared type is `v128`, typed generically).

---

## H. Effect / soundness / security note (I6)

- **Fail-closed is the whole point — and SIMD makes it structural.** The recommended grouped
  `ast.Simd(SimdInstr)` shape gives `validate_simd` an **exhaustive** `case` the Gleam compiler
  checks: it is *impossible* to add a SIMD op to the AST and forget to type it — the build fails
  until every constructor has an arm. `simd_sig` has **no** `_ -> #([], [])` catch-all (the
  fail-open hazard `numeric_sig` narrowly avoids by being reached only for genuine numeric leaves).
  **The one hazard to guard if P6-03 chooses a flat Instr surface** (§A.2): a flat SIMD constructor
  not matched in `validate_instr` would fall through to `_ -> validate_numeric`, and `numeric_sig`'s
  `_ -> #([], [])` would **silently accept it as a no-op** — a fail-*open* validator bug (a SIMD op
  that mutates the stack wrongly, or a lane op accepted with no bounds check). With the grouped shape
  this cannot happen. If flat is chosen, **P6-04 must additionally harden `numeric_sig`'s catch-all
  to `Error(Unsupported("unhandled opcode"))`** (a belt-and-suspenders fail-closed fallback — it does
  not break the existing suite because every real numeric leaf has an explicit arm). Recommend the
  grouped shape; flag the hardening as the fallback (Open Q 1).
- **The boundary is what makes the SIMD runtime sound.** `rt_simd` (P6-07) emits straight-line lane
  code with **no** operand re-checks — it trusts that a validated `i8x16.replace_lane` has a lane
  `< 16` and a `v128` + `i32` on the stack. Validate guarantees exactly that: every lane immediate is
  in range, every operand is the right type, every v128 memory op carries an in-range `memidx` and a
  legal alignment. So the worst case of a validator bug is a wrong/missing *validation* rejection,
  never a `rt_simd` out-of-bounds lane decode or a host escape.
- **SIMD lane ops have no trap surface (I3).** The only SIMD trap is the memory-bounds trap on a v128
  load/store, enforced at **runtime** by the bounds-checked `rt_mem` seam (P6-07/08) — validate only
  types the op and checks the *static* memarg (alignment, offset ceiling, memidx range). `v128` is an
  opaque 16-byte value that cannot address memory except through the checked seam; validate never
  inspects or forges lane data.
- **memory64 keeps every access bounds-checked → trap** (I6); the validation limit (`2^48`) and the
  runtime page cap (P6-08) are distinct (§F). Safe forbids tier-N as before — a binding/link concern,
  not validation.
- **Cross-module imports are fail-closed at *link* time, not here** (§G); validate types the declared
  shape, the linker fail-closes on satisfaction. `v128` opacity + `externref` opacity are both
  preserved structurally: validate only ever *types* these values, never inspects them.
- **Total.** `validate` never `panic`s / `let assert`s / diverges on any decodable AST — a
  decodable-but-ill-typed SIMD module (a bad lane index, a wrong operand, an over-aligned v128 load,
  an out-of-range `memidx`) is a typed `Error`, fail-closed.

---

## Verification — Definition of Done (spec-cited tests)

Tests assert the **spec rule**, not the implementation (no change-detector tests). Cite the spec
section / `.wast` file each test encodes. Fixtures: valid `.wasm` via `wat2wasm --enable-all` (or the
Phase-5 WAT parser once P6-03/decode round-trips SIMD); invalid-but-decodable via `wat2wasm
--no-check` (decode succeeds; only typing fails). Keep the Phase-1..5 suite green (regression).

**Acceptance (must be `Ok`, and carry a correct `TypedModule`):**
- `v128.const` producing `v128`; a `v128` global initialized by `v128.const`; a function with `v128`
  params/results/locals; a `block (result v128)` (`simd_const.wast`, generic stack).
- one representative op from **each** signature class typed correctly: `i32x4.add` (`[v128 v128] →
  [v128]`), `f64x2.sqrt` (`[v128] → [v128]`), `i16x8.shl` (`[v128 i32] → [v128]`), `v128.any_true`
  and `i8x16.bitmask` (`[v128] → [i32]`), `v128.bitselect` (`[v128 v128 v128] → [v128]`),
  `i32x4.splat` (`[i32] → [v128]`), `i64x2.splat` (`[i64] → [v128]`), `f32x4.splat` (`[f32] →
  [v128]`) — cite `simd_i32x4_arith.wast`, `simd_f64x2.wast`, `simd_bit_shift.wast`,
  `simd_boolean.wast`, `simd_bitwise.wast`, `simd_splat.wast`.
- **comparison results are `v128` masks**: `i8x16.eq` typed `[v128 v128] → [v128]` (a test that
  would fail if it were mis-typed to yield `i32`) — `simd_i8x16_cmp.wast`.
- extract/replace at a **valid** lane: `i8x16.extract_lane_s 15` → `i32`, `i64x2.extract_lane 1` →
  `i64`, `f32x4.replace_lane 3` consuming `f32` — `simd_lane.wast`.
- `i8x16.shuffle` with 16 indices all `< 32`; `i8x16.swizzle` (`[v128 v128] → [v128]`) —
  `simd_lane.wast`.
- the v128 memory family at a **valid** alignment: `v128.load align=4`, `v128.load32_splat align=2`,
  `v128.load8x8_s align=3`, `v128.load64_zero align=3`, `v128.store align=4`, `v128.load32_lane
  align=2 lane=3`, `v128.store8_lane align=0 lane=15` — `simd_load*.wast`, `simd_store*.wast`,
  `simd_align.wast` (the valid cases).
- **untyped `select` of two `v128`s is accepted** (a vector type, not a reference) —
  `simd_select.wast`.
- a **memory64** module: `v128.load` on a 64-bit memory pops an `i64` address; scalar `i64.load`,
  `i64` `memory.size`/`grow`, a `memory.copy` between a 64-bit and 32-bit memory (count `i32`); a
  64-bit limit of `2^48` accepted, `2^48 + 1` rejected — `memory64.wast`, `memory64-imports.wast`.
- a module **importing a function** `(func (param i32) (result i32))` and calling it: the import
  types into the func space and the `call` type-checks against the declared signature — `linking.wast`.

**Rejection (must be the cited `Error`):**
- `BadLaneIndex` — `i8x16.extract_lane_s 16` (lane `≥ 16`); `i32x4.replace_lane 4`; `i64x2.extract_lane 2`;
  `i8x16.shuffle` with any index `≥ 32`; `v128.load8_lane lane=16`; `v128.store64_lane lane=2` — cite
  `simd_lane.wast` and `simd_load*_lane.wast`/`simd_store*_lane.wast` `assert_invalid` corpora, spec
  vector-instruction lane rule (`x < dim` / `x < 32` / `x < 128/N`).
- `BadAlignment` — `v128.load align=5` (`2^5 = 32 > 16`); `v128.load32_splat align=3` (`> 4 bytes`);
  `v128.load8_lane align=1` (`> 1 byte`); `v128.store align=5` — cite `simd_align.wast` `assert_invalid`
  "alignment must not be larger than natural", spec memarg rule `2^align ≤ N/8`.
- `TypeMismatch` — `i32x4.add` fed an `f32x4`-typed operand path (a non-`v128` operand);
  `i64x2.splat` fed an `i32`; `i8x16.replace_lane` fed an `i64`; `f32x4.replace_lane` fed an `i32`;
  `ref.is_null` on a `v128`; a `v128.store` value that is not `v128`; a memory64 scalar `i32.load`
  address on a 64-bit memory (wants `i64`) — spec vector/parametric typing rules, `simd_*.wast`
  type-mismatch cases, `memory64.wast`.
- `UnknownMemory(memidx)` — a `v128.load` with a `memidx` past the module's memories
  (`simd_memory-multi.wast` / spec `C.mems[memidx]`).
- `OffsetOutOfRange` — a v128 memory op with a static offset `≥ 2^32` on a 32-bit memory
  (`simd_address.wast` boundary; spec memarg offset rule).
- `NonConstantExpr` — a `v128` global initialized by a non-const SIMD op (e.g. `i32x4.add`) — only
  `v128.const` is a constant SIMD instruction (spec constant expressions).
- `BadLimits` — a 64-bit memory limit `> 2^48` (`memory64.wast`); unchanged 32-bit / table rules.

**Properties:**
- **AST-only:** grep the source to prove **no `twocore/ir` import** (gates independently of the
  backend, `rt_simd`, and the linker).
- **Total / fail-closed:** never panics / `let assert`s / diverges on any decodable AST (fuzz the
  SIMD arms — a hostile lane index, a wrong operand, an over-aligned load, an out-of-range memidx all
  produce a typed `Error`). **Prove no SIMD op is silently accepted:** a test that every `SimdInstr`
  constructor either type-checks a well-formed use or rejects an ill-formed one — the exhaustive
  `validate_simd` (§H) makes the "silently no-op'd" outcome unreachable (with the grouped shape, a
  compile invariant).
- **Conformance-neutral (I7):** a Phase-1..5 module (no `v128`, one 32-bit memory, no cross-module
  imports) validates **identically** — assert a Phase-5 fixture's `TypedModule` is the same shape
  (no new field; the SIMD path is never entered). This is the headline neutrality proof.
- `gleam format --check src test` clean; `gleam build` **zero warnings**; `gleam test` green (≥ the
  current count; the manager gates conformance `fail=0`).

**Prove the boundary end-to-end:** the conformance harness routes `assert_invalid` →
`check_frontend` (decode + validate). So the new negative corpora from `simd_lane`/`simd_align`/the
lane load/store files flow here automatically; validate's rejection is what makes each `assert_invalid`
pass. Unit **P6-10** wires the SIMD allowlist and audits the residual; **this** unit's job is that the
rejections are **spec-correct** so those assertions go green (not silently skipped).

---

## What this unit leaves for others

- **P6-05 (lower)** consumes the (structurally unchanged) `TypedModule` — it reads a SIMD op's result
  type off the op constructor (no new typing map), maps each `SimdInstr` → the IR4 `Simd(SimdOp,…)` /
  `SimdShuffle` / `SimdLoad*` nodes, threads the memory64 `i64` address width from `memory_idx_types`
  (unchanged), and trusts every lane immediate is in range + every operand is sound (never
  re-validates). memory64 lower stops rejecting `Idx64` (I4) — a lower concern, not validation's.
- **P6-06 (emit_core)** trusts the boundary: it emits `rt_simd` lane calls and v128 memory ops with
  no type re-checks; the only runtime guard is the dynamic memory-bounds trap. The cross-module
  imported-function call lowers to `apply(Closure, Args)` over the linker-built closure (D3a) — the
  *typing* of that call is this unit's (against the declared `FuncType`), the *dispatch* is P6-06/09.
- **P6-07 (rt_simd)** relies on the lane-immediate + operand-type guarantees this boundary provides
  to emit straight-line, re-check-free lane code (§H).
- **P6-08 (rt_mem memory64)** owns the *runtime* page cap + the `i64` bounds arithmetic + the
  `atomics`/`nif` fail-closed gate; this unit owns only the memory64 *typing* (the `2^48` validation
  limit, distinct from the runtime cap — §F, do not double-own).
- **P6-09 (cross-module linking)** owns the link-time import *satisfaction* (the closure capability,
  the fail-closed type match, `(register …)`, `assert_unlinkable`); this unit owns only the import
  *shape* typing (§G, do not double-own).
- **P6-10 (conformance)** adds the SIMD `.wast` allowlist + the residual audit; document any
  `assert_invalid` this validator does *not* yet cover (relaxed-SIMD, GC reftypes) as an explicit,
  categorized skip.

---

## Deviations from the provisional surface

The provisional `PROVISIONAL-SURFACE.md` froze the **IR4** shapes (`TV128`, `SimdOp`, the
`Simd`/`SimdShuffle`/`SimdLoad*` `Expr` nodes). It does **not** prescribe the **AST4** SIMD
instruction shape (P6-03's, and validate's input). This unit therefore proposes the AST4 shape and
argues two points:

- **D1 — AST4 groups SIMD under one `Instr` constructor `Simd(SimdInstr)` (a strong recommendation to
  P6-03), rather than a flat one-constructor-per-opcode surface.** *Argument:* the AST idiom to date
  is flat (scalar ops, the `0xFC` bulk ops), which is fine at ~30 ops but balloons to ~236 for SIMD
  and — critically — **loses the fail-closed guarantee** validate depends on. With a flat surface, a
  SIMD op not matched in `validate_instr` silently reaches `numeric_sig`'s `_ -> #([], [])` catch-all
  and is **accepted as a no-op** (fail-*open* — the single worst validator failure mode). The grouped
  shape gives `validate_simd` a compiler-checked **exhaustive** `case`, turning "no SIMD op is
  silently accepted" from a review obligation into a build invariant, and mirrors the IR4
  `Simd(SimdOp)` design for symmetry. This is a P6-03-owned decision flagged for reconciliation; if
  reconciliation keeps a flat surface, this unit **must** harden `numeric_sig`'s catch-all to a
  fail-closed `Error` (§H) — stated as the fallback, not the preference.
- **D2 — the SIMD memory family stays `MemArg`-carrying AST instructions and reuses the *scalar*
  `check_align`/`check_offset`/`mem_addr_type` seam, not a new alignment/offset mechanism.**
  *Argument:* the memarg alignment rule (`2^align ≤ N/8`), the offset ceiling, and the `i32`/`i64`
  address typing are the **same rules** as the scalar loads/stores, only with a per-op `N`. Reusing
  the P5 helpers (a) keeps 32-bit memories byte-identical (I7), (b) makes the memory64 seam a single
  shared `mem_addr_type` (so §F's "the SIMD ops route through the same seam" is true by construction),
  and (c) needs **no** new `ValidateError` for alignment/offset (reuse `BadAlignment`/`OffsetOutOfRange`).
  The provisional IR4 uses dedicated `SimdLoad*` nodes on the IR side; that is P6-01/05/06's concern —
  the AST side reuses the scalar seam because the *typing* is identical.

No deviation from the `PROVISIONAL-SURFACE.md` IR4 shapes themselves (this unit does not touch the
IR). One `ValidateError` addition (`BadLaneIndex`) is not a deviation — the provisional surface
expected no new `TrapReason` (correct: lane-index is a *validation* error, not a trap) and left the
new `ValidateError` variants to the owning unit (this one).

---

## Open questions (for the planner / cross-unit sync)

1. **Grouped vs. flat AST4 SIMD surface + the `numeric_sig` catch-all.** Recommend grouped
   `Simd(SimdInstr)` (D1 — compiler-enforced fail-closed). If reconciliation keeps a flat surface,
   this unit hardens `numeric_sig`'s `_ -> #([], [])` to a fail-closed `Error(Unsupported(_))`.
   Confirm the choice with P6-03; it changes only the *dispatch shape*, never the typing rules.
2. **Shuffle immediate count (16) — decode or validate?** `i8x16.shuffle` carries exactly 16 lane
   indices. If P6-03 guarantees exactly 16 at decode (a structural read of 16 bytes), validate checks
   only each `x_i < 32`. If P6-03 emits a variable-length list, validate additionally asserts
   `length == 16` (→ `BadLaneIndex` or a dedicated error). Confirm P6-03 reads a fixed 16 (like
   `v128.const`'s fixed 16 bytes) so the count is a decode invariant.
3. **`extract_lane_s`/`_u` for narrow shapes only.** The `_s`/`_u` split exists **only** for `i8x16`
   and `i16x8` (lanes narrower than the `i32` they unpack to); `i32x4`/`i64x2`/`f32x4`/`f64x2` have a
   single `extract_lane`. Confirm P6-03's constructor set matches (no phantom `i32x4.extract_lane_s`)
   so validate's arm set is exact.
4. **`v128.const` as a constant instruction.** Confirm P6-03 decodes `v128.const` inside a const-expr
   (global init / element item) as an ordinary `Simd(V128Const(_))` in the instruction list, so
   `validate_const_expr`'s new arm (§C.4) catches it. (No other SIMD op is a constant instruction.)
5. **memory64 validation limit vs. runtime cap (P6-08 seam).** This unit keeps `memory64_page_limit =
   2^48` as the **validation** limit and does **not** import P6-08's smaller runtime `mem64_max_pages`
   cap into validation (§F). Confirm P6-08 agrees the runtime cap is a *trap boundary*, not a
   validation rejection — a spec-legal-but-runtime-capped 64-bit memory must **validate** (else
   conformance breaks). Single-owner: validate owns the `2^48` typing limit; P6-08 owns the runtime
   cap.
6. **Cross-module function-import typing is a no-op delta (P6-09 seam).** Validate types imported-
   function calls against the declared `FuncType` (already complete in P5). Confirm P6-09 owns the
   link-time *satisfaction* + closure dispatch and does not expect validate to grow any new import
   typing — the `TypedModule` already exposes `imports` + `imported_func_count` + `func_types` for
   the linker's fail-closed match table (§G).
7. **Relaxed-SIMD rejection point.** Relaxed-SIMD ops are out of scope (I8). Confirm P6-03 rejects
   them at *decode* (`UnknownSimdOpcode`/`UnknownSatOpcode`-style), so they never reach validate. If
   any relaxed op is decoded (e.g. into a placeholder), validate rejects it `Unsupported("relaxed-simd")`
   — fail-closed, never waved through.
