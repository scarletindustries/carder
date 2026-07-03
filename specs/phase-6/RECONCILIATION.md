# Phase 6 — Canonical reconciliation decisions (AUTHORITATIVE)

> This document is the **canonical decisions block** for Phase 6. It is the output of the 4-lens
> adversarial critique folded back by the engineering manager. **Where any unit doc (`01`–`11`)
> conflicts with a decision here, THIS DOCUMENT WINS** — the unit doc is stale on that point and the
> implementing agent follows the decision below. Read order for every implementation agent:
> [`00-overview.md`](00-overview.md) → **this file** → your unit doc.
>
> Nothing is built yet, so every conflict below is a *doc-level* contradiction resolved before code.
> Decisions are numbered **S1–S15**; each names the units it patches. The critique caught **8
> blockers + 7 majors** — the dominant theme is that the parallel scoping agents each invented their
> own spelling of the SIMD AST/IR taxonomy and the cross-module / SIMD-memory seams, so several
> contracts were frozen 2–3 incompatible ways. The keystone (01, IR owner) and decode (03, AST owner)
> made mostly-correct choices; the consumers (04/05/06) diverged. Reconciliation pins the **owner's**
> shape and forces the consumers to conform.

---

## S1 — «WASM-AST4» is DECODE's (03) shape; validate (04) + lower (05) conform; validate is fail-CLOSED

The SIMD AST surface was frozen **three incompatible ways** (03 shape-tagged `ast.Simd(op)` + 6
dedicated memory/const/shuffle `Instr`s; 04 a flat ~236-arm `SimdInstr` sub-enum; 05 flat per-op
`Instr` constructors like `ast.I8x16Add`). **03 owns `frontend/wasm/ast.gleam` and publishes
«WASM-AST4» day-1, so 03's shape IS the freeze:**

- `ast.ValType` gains **`V128`** (03's spelling + ordering — S15).
- A **shape-tagged `ast.SimdOp` enum** (`SAdd(SimdShape)`, `SEq(SimdShape)`, `SExtractLaneS(shape,
  lane)`, …) carried by **one** `Instr` constructor **`Simd(op: SimdOp)`**, PLUS **six dedicated
  `Instr` constructors**: `V128Const(bytes: BitArray)`, `I8x16Shuffle(lanes: List(Int))`,
  `SimdLoad(kind: SimdLoadKind, arg: MemArg)`, `SimdStore(arg: MemArg)`,
  `SimdLoadLane(width: Int, arg: MemArg, lane: Int)`, `SimdStoreLane(width: Int, arg: MemArg, lane:
  Int)`. SIMD memory is **one `SimdLoad` with a `SimdLoadKind` discriminant** (not per-flavour arms).
- **04 rewrites its typing tables and 05 rewrites its lowering arms to match these constructors.**
  Validate matches `ast.Simd(op)` (exhaustive on `SimdOp`) + the six dedicated arms; its const-expr
  arm is `[ast.V128Const(_)]`. Lower's SIMD-memory arms switch on `SimdLoad(kind, arg)`'s `kind`.
- **FAIL-CLOSED BUILD INVARIANT (security):** `validate.gleam`'s `validate_instr` has a `numeric_sig`
  fallthrough (`_ -> #([], [])`, line ~1730) that silently accepts an un-intercepted instruction as a
  typed no-op — a **fail-OPEN** hole. **04 MUST intercept every SIMD `Instr` constructor before that
  fallthrough** (7 arms: `Simd` + the six dedicated), so no SIMD op can reach `numeric_sig`. If a
  catch-all is unavoidable it becomes `Error(Unsupported(_))`, never a silent accept. Patch: 01/03/04/05.

## S2 — SIMD-memory width fields are **BITS** (8/16/32/64), never bytes

The keystone (01) + AST (03) froze `SimdLoadLane(width)` / `SimdLoadKind.LoadSplat(lane_bits)` /
`LoadZero(lane_bits)` / `LoadExtend(source_bits, signed)` all in **BITS**; 05's Deviations #4/#5
redefined the same bare-`Int` fields as **BYTES** (`SimdLoadLane(mem, 4, …)` for `load32_lane`) — a
silent 8× mis-sizing (a bounds check over the wrong length). **Pin BITS** (both owners agree; matches
the spec mnemonics `loadN_lane` where N is bits). **Reject 05's byte encoding.** Every unit reading a
`width`/`*_bits` field on a SIMD-memory node treats it as **bits**: `load32_lane → SimdLoadLane(mem,
32, …)`, `load8_splat → LoadSplat(8)`, `load32_zero → LoadZero(32)`, `load8x8_u → LoadExtend(8,
False)`. Patch: 05 §F (bits), ratify 01/03; 06/08 read bits.

## S3 — `ir.SimdOp` is the keystone's (01) PARAMETRIC taxonomy; lower (05) relabels to it; the saturating add/sub family is IN

`ir.SimdOp` was frozen two ways: the keystone (01, IR owner) chose **parametric/neutral** constructors
for the shape-changing ops (D6-clean); 05 copied 03's AST-private **fully-spelled** names
(`I16x8ExtendLowI8x16S`) that **do not exist in the frozen IR**. **The keystone's `ir.SimdOp` wins:**

- **Parametric constructors** for shape-family ops: `SExtend(from: SimdShape, half: SimdHalf, signed:
  Bool)`, `SNarrow(from: SimdShape, signed: Bool)`, `SExtMul(from: SimdShape, half: SimdHalf, signed:
  Bool)`, `SExtAddPairwise(from: SimdShape, signed: Bool)`; **`S`-prefixed named** conversions that are
  genuinely singular (`STruncSatF32x4S`, `STruncSatF32x4U`, `STruncSatF64x2SZero`,
  `STruncSatF64x2UZero`, `SConvertF32x4I32x4S`/`U`, `SConvertF64x2LowI32x4S`/`U`, `SDemoteF64x2Zero`,
  `SPromoteLowF32x4`, `SDotI16x8S`, `SQ15MulrSatS`, `SExtractLane`/`SExtractLaneS`/`SExtractLaneU`,
  `SReplaceLane`).
- **The saturating integer add/sub family IS in the enum** (the keystone already added it; the
  provisional omitted it): **`SAddSatS`/`SAddSatU`/`SSubSatS`/`SSubSatU`** (i8x16/i16x8 shapes). These
  back ~392 conformance asserts — they must appear in `ir.SimdOp` (01), `decode`/`validate` arms
  (03/04), the `simd_op_name` chokepoint (06), and `rt_simd` heads (07).
- **05 rewrites its IR-target column** to these constructors via an explicit lower→IR relabel table:
  `i16x8.extend_low_i8x16_s → SExtend(I8x16, Low, True)`, `i8x16.narrow_i16x8_s → SNarrow(I16x8,
  True)`, `i16x8.extmul_high_i8x16_u → SExtMul(I8x16, High, False)`, `i32x4.extadd_pairwise_i16x8_s →
  SExtAddPairwise(I16x8, True)`, `i32x4.trunc_sat_f32x4_s → STruncSatF32x4S`, etc. Pure relabel —
  semantics unchanged. The keystone's §B legality table is normative. Patch: 05 (relabel), 03/04/06
  (sat family arms), ratify 01.

## S4 — The SIMD-memory seam: `rt_mem.load_bytes`/`store_bytes` (owned by 08) + rt_simd's four dedicated lane-assembly helpers (owned by 07) + ONE pinned per-variant compose table (emitted by 06)

Three units froze the v128 load/store path incompatibly (06 invented ~20 dedicated byte-slice
helpers; 07 said the only new primitive is `pad_low` + reuse; the BitArray `load_bytes`/`store_bytes`
seam was **owned by nobody**). This path carries ~500 conformance asserts. **Pin all three pieces:**

1. **`rt_mem` gains `load_bytes` / `store_bytes` (owner: unit 08), returning/taking a `BitArray`:**
   `load_bytes(mem, addr, offset, n) -> Result(BitArray, TrapReason)` + `store_bytes(mem, addr, bytes,
   offset) -> Result(Nil, TrapReason)`, with **no-wrap bignum bounds → `MemoryOutOfBounds`,
   trap-before-write**, and the `_at` (index-routed) + threaded `t_*` twins. These are an `rt_mem`
   extension; 08 already owns the i64-address plumbing they thread. The keystone freezes the head
   names in «MEM64-RUNTIME»/«RT-SIMD-SIG». (Build on the existing PRIVATE `read_bytes`/`write_bytes`
   at rt_mem.gleam:1099+ by making the public checked wrappers.)
2. **`rt_simd` exposes four dedicated pure lane-assembly helpers (owner: unit 07)** as the frozen
   public surface (the keystone's §G names): `v128_load_extend(bytes8: BitArray, source_bits: Int,
   signed: Bool) -> BitArray`, `v128_load_zero(bytes: BitArray, lane_bits: Int) -> BitArray`,
   `v128_replace_lane_bits(vec: BitArray, lane: Int, width: Int, bits: Int) -> BitArray`,
   `v128_extract_lane_bits(vec: BitArray, lane: Int, width: Int) -> Int`. 07 implements them using
   `pad_low`+`extend_low` internally; **`pad_low` is a PRIVATE worker** (not public).
3. **ONE pinned per-variant compose table (06 emits exactly this):**

   | SIMD memory instr | byte width | rt_mem head | rt_simd assembly |
   |---|---|---|---|
   | `v128.load` | 16 | `load_bytes(16)` | — (the 16 bytes are the v128) |
   | `v128.store` | 16 | `store_bytes(16)` | — |
   | `v128.load{8x8,16x4,32x2}_{s,u}` | 8 | `load_bytes(8)` | `v128_load_extend(_, {8,16,32}, signed)` |
   | `v128.load{32,64}_zero` | 4/8 | `load_bytes({4,8})` | `v128_load_zero(_, {32,64})` |
   | `v128.load{8,16,32,64}_splat` | 1/2/4/8 | scalar `rt_mem.load` | `iNxM_splat` (existing lane splat) |
   | `v128.load{8,16,32,64}_lane` | 1/2/4/8 | scalar `rt_mem.load` | `v128_replace_lane_bits(vec, lane, N, _)` |
   | `v128.store{8,16,32,64}_lane` | 1/2/4/8 | scalar `rt_mem.store` | `v128_extract_lane_bits(vec, lane, N)` then store |

   **Delete 06's invented `load_splat_*`/`load_extend_*`/`load_zero_*`/`*_lane_bytes_*` head names** —
   they call rt_simd functions 07 never defines. The trap boundary is always `rt_mem`; `rt_simd` never
   touches memory or bounds. Patch: 06 (emit the table), 07 (the four helpers + pad_low private), 08
   (`load_bytes`/`store_bytes`), ratify 01 (freeze the head names).

## S5 — Cross-module + imported-function calls: the `CallImport` node + uniform link-time closure resolution (the biggest unlock)

The imported-function-CALL path is **greenfield** — `lower.gleam:1198` currently returns
`Error(Unsupported("imported call"))`, so **no** module that calls an imported function (host *or*
cross-module — including a module that calls `spectest.print`) compiles today. This is the bulk of the
measured residual (S11). The critique found the new path frozen **three ways** (06's `CallImport` +
compile-time host/cross-module split; 09's reuse-`CallDirect` + uniform link-time; the closure ABI
`fn(List)->Dynamic` vs 06's `erlang:apply(Closure, ArgsList)` arity-spread crash). Because it is
greenfield, pin the **clean uniform link-time-resolved model** (the scope lens is right that host-vs-
cross-module is a **link-time fact**, so there is NO compile-time split):

- **IR node (keystone-frozen):** an imported-function call lowers to **`CallImport(slot: Int, ty:
  FuncType, args: List(Value))`** where `slot` is the **positional function-import index** (imports
  occupy the low funcidx range; `slot` counts function imports only). `CallDirect` stays **same-module
  only** (`apply 'f'/n`). `CallImport` is explicit + D3a-legible in `.ir`. **ADD `CallImport` to
  «IR4-FROZEN» (01).** (This supersedes the provisional §G's "reuse CallDirect" note.)
- **Closure ABI (pin 09's list-taking shape, fix the arity bug):** the resolved import is a closure
  **`fn(List(Dynamic)) -> List(Dynamic)`** (arg list in, **value list** out — multi-value, consistent
  with the R17 invoke ABI). Generated code invokes it via a **`link.call_import(closure, args_list)`
  seam** (a plain 1-ary application of the closure to the arg list), **NEVER
  `erlang:apply(Closure, ArgsList)`** — the 2-arg `apply` SPREADS the list into an N-ary fun's
  parameters and crashes a 1-ary list-taker. (`apply/2` on a value is D3a-clean; the bug is arity, not
  authority.)
- **Uniform link-time resolution (no compile-time split):** every function import is a positional
  slot; **`link_imports` binds each slot to a closure** in the instance's function-import vector:
  - a **host / `spectest`** import → a closure that routes through the **existing `rt_host` checked
    dispatch** (`rt_host.call_host(cap, name, args)`), so the **capability boundary (deny-all /
    whitelist) is preserved** and the proven spectest registry is **reused inside the closure**;
  - a **cross-module** import → a closure that routes the call **into the exporting instance's owning
    process** (09's dispatch model — each `cell` instance owns its process, so pdict cells never
    collide) and invokes its exported function via the run-ABI.
- **State-strategy reach (honest — I5):** cross-module dispatch ships under **`cell`** (the Safe
  default; separate process per instance). The **`threaded`** cross-instance case is **categorized
  honestly** if invasive (as P5 categorized spectest-memory-under-atomics) — lighting `linking.wast`
  under one profile is a real win. `emit_core` handles the SIMD-free, non-cross-import module
  **byte-identically** (no `CallImport` ⇒ no change).
- **D3a proof (06 extends the security test):** `link.call_import` indexes a **handed-in** closure
  vector and applies a closure value — there is **no `apply(Module, Atom, …)` of an attacker-named
  target** anywhere on the path. Grep-verify.

Patch: 01 (freeze `CallImport` + the `fn(List)->List` closure ABI + `link.call_import`), 05 (lower
imported calls → `CallImport(slot, ty, args)`; delete the `Unsupported("imported call")` reject), 06
(emit `link.call_import`, never apply-spread; extend D3a test), 09 (build the host + cross-module
closures; extend `link_imports` to functions; the process-routing).

## S6 — v128 (and reference) globals reuse `rt_state`'s Dynamic boxed-globals map; owner unit 09

A `v128` global is a 16-byte `BitArray` (a `Dynamic`), so it cannot live in `rt_state`'s numeric-`Int`
`globals` map (which must stay byte-identical for D5 raw-bit numeric globals). **Reuse the existing
`ref_globals: Dict(String, Dynamic)` map** (Phase-5 R8, already holds funcref/externref `Dynamic`
values) for `v128` globals too — a 16-byte binary stores/retrieves exactly like a reference value.
`emit_core` (06) routes a `v128`-typed `GlobalGet`/`GlobalSet`/const-init to the boxed accessor (like
reftype globals). **`rt_state.gleam` changes in Phase 6 are owned by unit 09** (consistent with
Phase-5 R5, where 09 owned the rt_state bodies); 06/07/08 consume its accessors and never edit it.
Patch: 09 (widen `ref_globals`'s role to "boxed non-numeric globals"; seed v128 globals from
`StateDecl`), 06 (route v128 global access to the boxed accessor).

## S7 — Effect classification: pure lanewise SIMD is PURE; the four SIMD-memory nodes are barriers (ratified)

The keystone classifies `Simd`/`SimdShuffle` as **Pure** (unlike every Phase-5 new node, which was a
barrier) and the four SIMD-memory nodes (`SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`) as
**Effectful barriers**. **This is SOUND and ratified:** a lanewise SIMD op is **total and
deterministic** (no trap — S8; no state; saturation replaces overflow-trap), so CSE / DCE / reorder
over it preserve observable behaviour exactly as they do over `Num`. A pure `Simd` cannot move a trap
(it has none) or observe torn state (it touches none). The SIMD-memory nodes touch mutable memory and
can trap, so they are correctly barriers. `effect.gleam` (owned by the keystone for the freeze):
`Simd`/`SimdShuffle` → the pure classification; the four memory nodes → `Effectful`. No change to the
Phase-5 barrier set. (This is a deliberate, argued improvement over Phase-5's conservatism, enabling
SIMD const-fold/DCE later.)

## S8 — TrapReason is UNCHANGED (no new variants); ratified

Confirmed by three lenses: SIMD ops are **total** (I3 — no SIMD division-trap; saturating/narrowing
ops saturate, never trap); the **only** SIMD trap surface is a SIMD memory load/store, which reuses
`MemoryOutOfBounds`; **memory64** reuses `MemoryOutOfBounds`; an **unsatisfied/mismatched import** is a
link-time `ImportError`, not a runtime `TrapReason`. So the exhaustive `spec_trap_message` /
`trap_reason_atom` matches stay untouched (keystone lands green). **If** a pinned `simd/*.wast` /
`memory64.wast` `assert_trap` empirically needs a message the existing set cannot produce (expected:
none), add **exactly one** variant consciously — do not pre-add speculatively. Patch: ratify 01.

## S9 — memory64 numbers: DECLARABLE type-max = 2⁴⁸ **pages**; RUNTIME cap = 2³² pages (256 TiB)

The overview/provisional/capstone mis-stated the memory64 spec max as "2⁴⁸ **bytes** = 2³² pages"
(conflated). **The spec-correct numbers (08's §C is right, ratified):**

- **Declarable type maximum** (what `validate` accepts for a 64-bit memory's `limits`): **2⁴⁸ pages**
  (= 2⁶⁴ bytes) per the memory64 spec §2.5. A memory declaring more than 2⁴⁸ pages fails validation.
- **Runtime cap** (the `Binding.mem64_max_pages` field — a tunable trap boundary, NOT an allocation):
  **default 2³² pages = 2⁴⁸ bytes = 256 TiB**, a sparse trap-boundary the `paged` backend never
  actually allocates (it grows on demand). `grow` beyond the cap → `-1`; an access beyond the current
  size → `MemoryOutOfBounds`. This is the honest, spec-cited constant R12 demanded — not a guess.
- **32-bit memories are byte-identical** (the byte machinery is already bignum-64-bit-correct —
  confirmed: `in_bounds`/`ea = addr + offset` are never masked mod 2³²). `atomics`/`nif` keep their
  32-bit reserve and **fail closed** for an over-cap 64-bit memory (no silent fallback).

Patch: fix the number in 00-overview §1 / PROVISIONAL-SURFACE §F / 11 §C; ratify 08 §C as normative.

## S10 — `rt_simd` implements in FOUR balanced passes (07a–07d), not three

07's "three balanced passes" were badly imbalanced (07a ≈ 119 heads + the shared lane codec + integer
width-core = ~56% of the work; the finish risk). **Re-split into four passes** with stated head
counts (~214–224 concrete heads implementing ~236 instructions — S15):

- **07a — codec + integer arithmetic core** (~50): the shared lane decode/encode (`<<…/little>>`), int
  add/sub/mul/neg/abs, the **saturating add/sub family** (S3), min/max (s+u), avgr_u, shifts (masked
  mod lane width), `popcnt`.
- **07b — comparisons + reductions + lane access** (~60): all lane comparisons → v128 mask (eq/ne/lt/
  le/gt/ge s+u across shapes), bitwise (`and`/`or`/`xor`/`not`/`andnot`/`bitselect`), `any_true`/
  `all_true`/`bitmask`, `splat`, extract/replace lane (s+u variants).
- **07c — float lanes + conversions** (~58): f32x4/f64x2 add/sub/mul/div/neg/abs/sqrt/min/max/pmin/
  pmax/ceil/floor/trunc/nearest + float comparisons (f32 single-rounding per lane); convert/trunc_sat/
  demote/promote.
- **07d — misc + the v128 memory family** (~45): narrow (saturating)/widen/extend low+high s+u,
  extmul, extadd_pairwise, `dot_i16x8_s`, `q15mulr_sat_s`, `swizzle` (OOB→0), `shuffle`, and the four
  **v128 lane-assembly memory helpers** (S4) `v128_load_extend`/`v128_load_zero`/`v128_replace_lane_
  bits`/`v128_extract_lane_bits` + private `pad_low`.

Each pass is differential-tested vs the rebuild oracle / `wasmtime` as it lands. Patch: 07 §C, 00 §3.

## S11 — Conformance greenness + the residual are MEASURED, never overstated (R16 holds)

10/11 asserted an impossible headline (`table_copy.wast` = 1,649 asserts "flip skip→pass" while the
whole suite has only 1,257 skips; multi-table `call_indirect` already landed in aa89228, so part of
`table_copy` already passes). **Pin the R16 discipline concretely (owner: unit 10):**

- **Empirically measure, at the pinned SHA**, the count of *currently-skipped* asserts that flip to
  pass once cross-module fn dispatch (S5) + SIMD (S1–S4) + memory64 (S9) land — per file, with the
  `assert_return`/`assert_trap`/`assert_invalid`/`assert_malformed` breakdown. The residual `~1088`
  and any `table_copy` sub-count are **whatever the audit measures**, not a full-file assert count.
- **Re-verify `wast2json` convertibility per target file at the pin**; route un-convertible files
  through the WAT parser (P5-10) where in scope; a genuinely out-of-scope file (SIMD/GC text) is a
  **categorized skip**, never a silent mis-parse or a false-green.
- The skip-drop headline + `fail == 0` are reported as **measured numbers** with a fully-categorized,
  closed residual (the `skipcount` guard goes red if a skip escapes its category). Patch: 10/11.

## S12 — The close is "the complete WebAssembly **2.0** surface"; post-2.0 proposals are categorized-deferred (return_call* added to the residual)

The capstone's "complete standardized WebAssembly surface" **overstates** — `return_call.wast` /
`return_call_indirect.wast` (the **tail-call** proposal, post-2.0) exist in the pinned suite, are
**unimplemented** (no `return_call` in `src/`), and were **uncategorized**; GC and exception-handling
(WASM 3.0) are also standardized yet deferred. **Qualify the close honestly (I8):**

- Phase 6 completes **the WebAssembly 2.0 fixed-width surface**: reference types, bulk memory,
  multi-memory, memory64, **SIMD**, and cross-module linking — i.e. everything through the 2.0 spec.
- **Explicitly deferred (post-2.0 proposals), each categorized in the conformance residual + the
  capstone's honest-close block:** the **tail-call** proposal (`return_call*` — ADD it to the
  categorized residual and the ALLOWLIST DEFERRED block), **GC** (incl. GC-proposal reftypes),
  **exception-handling**, **stack-switching**, the **component model**, and **relaxed-SIMD** (the
  non-deterministic proposal). The capstone claim is **"the complete WebAssembly 2.0 surface"**, never
  "the complete standard".
- **EM note (not a Phase-6 obligation):** tail calls map beautifully onto the BEAM's native proper
  tail calls (high-level §12) and the backend already emits constant-space tail calls — `return_call`
  is a plausibly-cheap **fast-follow / Phase-7-adjacent** add. Do NOT fold it into Phase 6 (scope
  discipline — SIMD already dominates); flag it for the next phase. Patch: 00 §1/§6, 10 §D, 11 §close.

## S13 — The SIMD `wat_parse ≡ decode∘wat2wasm` differential is DROPPED; SIMD conformance uses `wast2json` JSON

The WAT text parser (`wat.gleam`) **rejects `v128` with `Unsupported(Simd)`** (lines 2186/2202/3562)
and no Phase-6 unit extends it for SIMD text, so 10 §F.2's proposed `wat_parse` differential over a
SIMD `.wat` corpus is **unbuildable**. **Drop it.** SIMD `simd/*.wast` files ARE `wast2json`-able at
the pin (the R16 audit confirms per file), so SIMD conformance drives from the **`wast2json` JSON**
directly (the existing harness path) + the `wasmtime` differential. **SIMD text in the WAT parser is
out of scope for Phase 6** (a categorized capability gap, stated). `memory64`/`linking` text that is
un-`wast2json`-able routes through the existing WAT parser (which already parses `(memory i64 …)` and
imports). Patch: 10 (drop §F.2's SIMD-wat differential; note the WAT-SIMD gap).

## S14 — The v128 invoke/result ABI is 16 raw little-endian bytes across the term ABI (ratified)

A `v128` crosses the conformance harness's term invoke/result ABI as **16 raw little-endian bytes**
(`mk_v128` is identity over a 16-byte binary; result judging reads the 16 bytes). This composes with
the R17 multi-value value-list ABI (a v128 is one value in the list). Ratified from 10 §C; owner 10.

## S15 — Minor pins (adopt without further debate)

- **`ast.ValType` `V128` ordering:** 03 owns `ast.gleam`; use 03's spelling/placement; 04/05 conform.
  Same for `ir.ValType` `TV128`: the keystone's placement is normative.
- **`i8x16_swizzle` parameter name** is `idx` (keystone §, not 07's `s`).
- **Head-count phrasing:** rt_simd has **~214–224 concrete `pub fn` heads** implementing **~236
  standardized instructions** (the ~11 v128-memory instructions + `v128.const` are composed by 06 from
  the four lane-assembly helpers + `rt_mem`, not one head each). Fix the "~236 heads" phrasing in
  07/06/00 to "~236 instructions / ~214–224 heads".
- **The natural-access-width `N` on the memory typing seam** is documented in **bits** (aligning 03's
  byte-width note to 04's bits) — consistent with S2. `2^align ≤ N/8` bytes for alignment.
- **`pad_low`** is a **private** rt_simd worker (S4), not public.

---

## What did NOT change (the critique confirmed these SOUND — implement as the docs specify)

Checked against the WebAssembly SIMD / core spec and the real source, and correct:

- **The decode opcode table is spec-exact** — all 236 `0xFD` sub-opcodes verified against the SIMD
  binary encoding; `v128.const` reads 16 RAW little-endian bytes (D5, no lane interpretation);
  `i8x16.shuffle` reads 16 immediate lane bytes; SIMD memory reuses the Phase-5 `decode_memarg`
  (multi-memory bit-6 memidx + u64 offset) unchanged, composing correctly with memory64 (03).
- **Validate signature classes are spec-correct** — SIMD **comparisons yield a v128 MASK**
  `[v128 v128]→[v128]`, NOT i32 (the classic pitfall is avoided); lane-immediate bounds (extract/
  replace `lane < dim(shape)`, shuffle each index `< 32`, load/store-lane `lane < 128/N`); untyped
  `select` correctly accepts `v128` as a vector type (04).
- **Lower's mapping is spec-faithful** — `v128.const → ConstV128(bytes)` value literal (like a numeric
  const, splat NOT trapping); the memory64 unfreeze is exactly "delete `reject_memory64/1` + its call
  + the `Memory64Unsupported` LowerError" (05).
- **The `rt_num`-reuse doctrine is buildable and correct** — every head 07 depends on exists as a
  `pub fn` in `rt_num.gleam` with the claimed semantics; per-lane semantics are spec-correct across the
  surface: **saturating narrow** (signed source → sat to the narrower signed/unsigned range),
  **pmin/pmax** pseudo-form (`(b<a)?b:a` via `f32_lt`), **`dot_i16x8_s` WRAPS** (all-(−32768) →
  INT_MIN, matching wasmtime), **avgr_u** rounds (`(a+b+1)>>1`), **shift counts masked mod LANE
  width**, **swizzle OOB → 0**, extend low/high s/u, extadd_pairwise, extmul, trunc_sat (NaN→0,
  saturate) (07).
- **The memory64 byte machinery is already 64-bit-correct** — `in_bounds`/`ea = addr+offset` use
  bignums, never masked mod 2³²; the page-cap decision is a sound, well-cited sparse trap boundary; the
  rebuild differential is adequate to catch a lane/endianness/off-by-one bug (08).
- **09's cross-module-into-owning-process dispatch model is correct and KEPT** — routing a cross-module
  call into the exporting instance's owning process is what makes `cell` pdict cells not collide (09).
- **The v128 invoke ABI (16 LE bytes) and the R16 empirical-residual methodology are sound** (10).
- **The DAG wave/freeze sequencing is coherent** — WAVE 0 keystone (IR4/RT-SIMD-SIG/MEM64-RUNTIME/
  XLINK) → WAVE A parallel 02–09 → WAVE B conformance → WAVE C capstone.

---

## Scope & DAG deltas (summary)

- **Unit count stays 11.** Unit **07 (rt_simd)** implements in **four** agent passes (07a codec+int,
  07b compares+reductions+lane, 07c float+convert, 07d misc+memory — S10), not three.
- **New IR node:** `CallImport(slot, ty, args)` (S5) — added to «IR4-FROZEN» (01).
- **New rt_mem heads:** `load_bytes`/`store_bytes` (+ `_at`/`t_*` twins) — owner **08** (S4).
- **New rt_simd helpers:** `v128_load_extend`/`v128_load_zero`/`v128_replace_lane_bits`/
  `v128_extract_lane_bits` (public) + `pad_low` (private) — owner **07** (S4).
- **New link seam:** `link.call_import(closure, args_list)` + the `fn(List(Dynamic)) -> List(Dynamic)`
  closure ABI — owner **09**, frozen head in 01 (S5).
- **`rt_state.gleam`** in Phase 6 is owned by **09** (v128/boxed globals — S6); 06/07/08 never edit it.
- **The saturating add/sub family** (`SAddSatS/U`, `SSubSatS/U`) is in `ir.SimdOp` (S3) — 01 freezes it.
- **Honesty deltas:** the close is "WASM **2.0** complete" with tail-call/GC/EH/stack-switching/
  component-model/relaxed-SIMD categorized-deferred (S12); the residual/`table_copy` number is
  measured (S11); the memory64 numbers are corrected (S9); the SIMD-wat differential is dropped (S13).
