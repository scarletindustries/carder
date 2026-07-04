# Phase 9 — The Memory Optimizer (MemorySSA + alias-aware load/store rewriting)

> **Read this after the Phase-1…8 overviews and, above all, after the design note
> [`specs/future-work-memory-optimizer.md`](../future-work-memory-optimizer.md) — this phase is
> that note made concrete.** Every prior decision **still holds** — one owner per file (D1),
> runtime layers reached only through the binding chokepoint with **no ambient authority** (D3a),
> per-stage error types (D4), floats/v128 as raw bit patterns (D5), named-label structured IR
> (D6), the tier ladder, the two modes (Safe/Unsafe), **spec-first tests** (assert *defined*
> behavior, never change-detector output — D8), `gleam format`/`gleam build` clean, the strict
> Definition of Done. This page adds the Phase-9 decisions **M1–M8** and the work breakdown.
> Baseline entering Phase 9: **1734 tests, 0 failures, 0 warnings**; the complete WASM 2.0 surface,
> the Phase-7 Porffor→BEAM path, and the Phase-8 BEAM-native value layer are all green.

---

## 0. Where Phase 9 sits (the platform, one paragraph)

Phase 3 built the **shared IR-level optimizer** (`ir_opt`) and shipped a vetted, trust-neutral
**baseline** pass set (const-fold, copy/const-prop, algebraic identity, const-`if`, block/label,
DCE, dead-`let`) plus an Unsafe-only **aggressive** set (inlining, charge-elision). It
**deliberately deferred** the memory-dataflow passes — LICM, range-based bounds-check elimination,
and any load/store CSE — because they need a **memory-dependence analysis** the platform did not
yet have (Phase-3 §00 F8; `ir/effect.gleam` `can_cse` forbids **all** load CSE as "the strongest
sound under-approximation … *because we had no memory-dependence analysis yet*"). Phase 4 then made
the **tier ladder** real (`paged`/`atomics`/`nif` memory, `cell`/`threaded` state) and measured a
**memory-access residual** on every tier: fetch the memory handle → **bounds-compare + branch** →
the O(1) read/write → bit-syntax decode. Phase 9 attacks that residual with the **memory optimizer**
the design note scoped: a **middle-end (`ir_opt`) analysis + rewrite over the `MemLoad`/`MemStore`
IR nodes**. Because it runs **upstream of tier + mode selection**, a sound pass here **speeds up
every tier (`paged`/`atomics`/`nif`) and both modes (Safe/Unsafe)** — and, because the IR is
language-neutral, **every present and future frontend** (WASM/Rust today, JS/Gleam later) inherits
it for free. It touches **no runtime ABI and adds no IR node types**: it is pure IR→IR.

---

## 1. The Phase-9 goal (concrete and measurable)

> **Remove redundant and provably-safe linear-memory traffic at the IR level, soundly, in a way
> that speeds up every tier and both modes.** The optimizer gains a **MemorySSA + linear-memory
> alias analysis** (unit 01) and three alias-aware rewrites that consume it: **store→load
> forwarding** and **redundant-load elimination** (unit 02) and **dead-store elimination**
> (unit 03). Each removes a whole memory access — a handle fetch **and** its bounds-compare/branch
> **and** its bit-syntax decode — for accesses the analysis proves redundant, **without changing a
> single observable result or trap** over the Phase-1…8 acceptance corpus + spec suite, at **every**
> `(state_strategy × mem_tier)` and under **both** profiles. The passes are **trust-neutral** — they
> preserve WASM's trap-or-read semantics exactly — so they run at **`Baseline`** (Safe) and are
> therefore inherited by `Aggressive` (Unsafe = baseline ++ aggressive). Phase 9's win is
> **measured**, not asserted: a committed benchmark reports both a **deterministic** static metric
> (memory-op nodes eliminated) and **wall-clock** ns/call on a memory-traffic-heavy kernel, with
> methodology and the honest pattern-dependence ceiling written down.

### Acceptance (owned by the capstone, unit 04)

| Area | Must demonstrate (spec-first, run on the real BEAM) |
|---|---|
| **optimizer soundness (the bar)** | `optimize(m, Baseline)` and `m` produce **byte-identical returned values** (by bit pattern, D5/D7) and **identical traps** (same `TrapReason`, same trap-or-not) for **every** program in the Phase-1…8 acceptance corpus + spec suite — a **differential over the whole corpus**, run under **every shipped `(state_strategy × mem_tier)` combo** and **both** profiles (the passes must be sound on `paged`/`atomics`/`nif` and Safe/Unsafe alike) |
| **store→load forwarding** | after a store that dominates a **must-alias** load in the same straight-line region with no intervening clobber, the load is replaced by the stored value; a targeted fixture proves the load node is **gone** from the optimized IR, and an end-to-end run proves the value + trap behaviour is unchanged (the store proved in-bounds ⟹ the load is in-bounds ⟹ trap-neutral) |
| **redundant-load elimination** | two must-alias loads in the same region with no intervening clobber collapse to one; the second load is replaced by the first's bound value; trap-neutral (the first load already proved in-bounds) |
| **dead-store elimination (paged headline)** | a store immediately shadowed by a **must-alias** store with only pure computation between is removed; trap-neutral (the shadowing store bounds-checks the **same** address, so it preserves the exact `MemoryOutOfBounds` behaviour); on `paged` this elides a whole O(page) rebuild |
| **alias soundness (the safety gate)** | the analysis **only** disambiguates the tractable shapes (same `mem`, same base `Value`, distinct constant `offset`/width → `NoAlias`; identical footprint → `MustAlias`; **everything else → `MayAlias`**), and a barrier (a call, `MemGrow`, a bulk-memory op, a trap/control transfer, or a differently-based access) **kills all memory knowledge** — proven by adversarial "must-NOT forward / must-NOT eliminate" fixtures the optimizer must not break |
| **conformance-neutral + all-tier + both-mode** | the entire Phase-1…8 corpus + spec suite stay green (result-identical) under both profiles and every tier; a module with no redundant memory traffic is left semantically unchanged (the passes only *remove* redundancy — they never add a node, never reorder an effect, never introduce a call or an `apply`) |
| **measured speedup (the headline)** | a committed benchmark shows the passes **fire** (a deterministic count of eliminated `MemLoad`/`MemStore` nodes, independent of the clock) **and** run **measurably faster** wall-clock on a memory-traffic-heavy kernel — with methodology, the tier breakdown (DSE's paged advantage), and the honest ceiling (structured `base + const` patterns win; fully-dynamic addressing does not) written into `docs/phase-9-benchmark.md` |

### Honest scope (M8 — do not overstate)

- **Middle-end only; no runtime, no IR growth.** Phase 9 adds **no** `Expr`/`Value`/`ConvOp`/`NumOp`
  variant and **no** `.ir` grammar change — the optimizer only *rewrites and removes* existing
  `MemLoad`/`MemStore` nodes. It touches **no** `rt_mem`/`rt_state`/`emit_core` runtime ABI. So the
  emitted `.core` for an *unoptimized* module is byte-identical to Phase 8; an *optimized* module
  differs only by having **fewer** memory accesses (result-identical, F2-style differential).
- **The three MemorySSA payoffs the note names as "concrete," not the whole wish-list.** Ship
  store→load forwarding, redundant-load elimination, and dead-store elimination — the rewrites that
  need **no new IR surface** because they only remove/replace nodes. **Deferred, stated not dropped
  (M8, §6):** *standalone* range-based bounds-check elimination (dropping the check while keeping the
  read — needs an "unchecked access" representation the IR does not have), **LICM** of the
  loop-invariant handle fetch (needs the handle exposed as an IR value), and **MemorySSA across
  control flow** (the analysis is intraprocedural and **per straight-line region** — it resets at
  every `If`/`Switch`/`Loop`/`Block`/`Try` boundary; a φ-joined cross-block MemorySSA is later work).
  The note's flagship BCE case — "after `store(a,v)` succeeds, `load(a)` is in bounds ⟹ forward `v`
  **and** drop its check" — **is shipped**, subsumed by store→load forwarding (the whole load,
  check included, vanishes).
- **Trap-preservation is the soundness gate, and it is absolute.** A WASM load/store is
  *trap-or-access*, **not** a pure read/write (M3). Every rewrite is legal **only** because it
  preserves the exact observable trap behaviour: forwarding/RLE reuse a value guarded by a
  **dominating successful access** that already proved the address in-bounds; DSE preserves the trap
  because the **shadowing store bounds-checks the same address**. A rewrite that could change
  *when or whether* a trap fires is **out** — that would break the sandbox's observable semantics.
- **Honest, pattern-dependent ceiling — measured, not asserted.** The alias analysis is precise on
  the address shapes compilers actually emit — a reused base `Value` with distinct constant memarg
  offsets, and syntactically-equal operands (Rust/Porffor output). It is **deliberately
  conservative** (→ `MayAlias`, → no rewrite) on differently-based or fully-dynamic addresses. The
  win is real but pattern-dependent; the benchmark **states the ceiling and measures the win**, per
  the note's invariant #4. No hero number.

---

## 2. The Phase-9 decisions (M1–M8)

These are frozen for Phase 9. If you believe one is wrong, raise it with the planner **before**
building on it — do not silently diverge (the D1 rule).

### M1 — MemorySSA + linear-memory alias analysis is the keystone (a leaf module)

The enabler is a shared analysis, `src/twocore/middle/ir_opt/mem_ssa.gleam` (unit 01), that imports
`ir` and `ir/effect` **only** (a leaf below the passes in the import DAG, exactly like `pass.gleam`
sits below `baseline`/`aggressive`). It provides, per the design note's "framework":

- an **access footprint** `#(mem, addr, offset, bytes)` naming *what memory an access touches* —
  the memory index, the dynamic base `Value`, the static memarg `offset`, and the width in bytes
  (all four **kept distinct** — M4: do **not** fold `addr + offset`; keep `mem`/`offset` separate,
  the invariant that keeps the IR analyzable);
- an **alias oracle** `alias(a, b) -> AliasResult` (`MustAlias`/`NoAlias`/`MayAlias`) — the
  Array-SSA-style element/offset disambiguation that lets "store to `base+0`" *not* kill "load from
  `base+4`" (§M5);
- a **barrier test** built on `ir/effect.is_effectful_node` refined for *memory dependence*: the
  set of nodes that force the analysis to forget everything it knows about memory (§M5);
- the **reaching-value map** (`avail`) the forwarding/RLE pass threads, and the extended
  **termination measure** the whole `ir_opt` fixpoint stays well-founded under (§M7).

`mem_ssa` is the phase's load-bearing correctness unit (as `ir/effect` was Phase 3's): an unsound
`alias` or a too-narrow barrier set makes **every** downstream rewrite unsound (a single
forward-across-an-aliasing-store is silent memory corruption). It ships with **adversarial
fixtures** and lands green with the pipeline **still empty** (identity), exactly like the Phase-3
keystone.

### M2 — The memory passes are **trust-neutral**: they run at `Baseline`, so every tier and both modes win

The design note's load-bearing invariant #1: getting trap-preservation right "is what keeps the
passes **trust-neutral so they run in Safe mode** — a memory speedup that does not weaken the
sandbox is a core platform win." Phase 9's passes are registered into the **`Baseline`** pipeline
(unit 04, at `ir_opt.pipeline/1`'s single registration point), so:

- **Safe** (`Baseline`) gets them — the sandbox is not weakened, because the passes preserve every
  trap;
- **Unsafe** (`Aggressive = baseline ++ aggressive`) inherits them for free (a strict superset,
  keystone A.2);
- because `ir_opt` runs **before** tier + mode selection (`ir_lower → ir_opt → emit_core`, F1), the
  **same** sound rewrite speeds up `paged`, `atomics`, and `nif`, and `cell` and `threaded`, with no
  per-tier code (M4: no runtime touch). The note's "a sound pass speeds up every tier and both
  modes" is realized structurally by *where in the pipeline the passes sit*, not by N copies.

### M3 — Trap-preservation is the soundness gate; the lever is "a dominating successful access proves in-bounds"

A WASM `MemLoad`/`MemStore` is **trap-or-access** (`emit_core` routes every one through
`rt_mem`'s bounds-check → `rt_trap.raise(MemoryOutOfBounds)`), not a pure read/write. So a rewrite
is sound **only** if it preserves *when and whether* a trap fires. The three legal levers, each
resting on a **dominating access in the same straight-line region**:

- **store→load forwarding.** `store(F, v)` then (later, same region, no clobber between) `load(F)`
  with `F` a **must-alias** full-width footprint ⟹ replace the load with `Values([v])`. Sound
  because the store **succeeded** (if it trapped, control left and the load never ran — in the
  original *and* the optimized program), so `F`'s address is in-bounds ⟹ the load is in-bounds ⟹
  forwarding drops a load that could not have trapped. The value `v` is a `Value` (a `Const*` or a
  unique-name `Var`), immutable within the region, so it still reads the same bits.
- **redundant-load elimination.** `load(F)` bound to `y`, then (later, same region, no clobber)
  `load(F)` must-alias ⟹ replace the second with `Values([Var(y)])`. Sound because the first load
  **succeeded** (else control left), so the second same-address load is in-bounds too, and the
  memory at `F` is unchanged (no clobber between), so `y` holds the exact bits.
- **dead-store elimination.** `store(F, v₁)` then (same region, **only pure nodes between**)
  `store(F, v₂)` must-alias ⟹ drop the first store. Sound because the shadowing store bounds-checks
  the **same** address `F`: if `F` is OOB, the *original* traps at store₁ and the *optimized* traps
  at store₂ — **same `MemoryOutOfBounds`, same effect** — and with *only pure nodes between*, no
  observable effect is skipped and no intervening op can change `F`'s in-bounds status (only
  `MemGrow` can, and it is not pure — it is a barrier that blocks DSE). The final memory state is
  identical (`v₂` wins either way).

**Never reorder across a possibly-trapping access without a no-trap proof** (invariant #1). Phase-9
passes therefore **never reorder** an effect — they only *remove* a redundant one or *replace* a
load with a value already in hand; ordering is preserved verbatim.

### M4 — Keep the IR analyzable; **no new node types**; the passes only remove/replace nodes

Per the note's invariant #2: keep `mem` and `offset` as **distinct fields** on `MemLoad`/`MemStore`
(never pre-fold `addr + offset`), and keep **per-access IR nodes** (do not lower memory ops to
opaque runtime calls before the optimizer runs — the IR still exposes `#(mem, addr, offset, bytes)`,
which is exactly what makes disambiguation tractable). Phase 9 honours this by construction: it adds
**no** IR variant and rewrites **only** by *removing* a `MemStore` (DSE) or *replacing* a `MemLoad`
with a `Values` of an already-bound `Value` (forwarding/RLE). This is what keeps the phase
**conformance-neutral** (result-identical differential, not byte-identical emission — an optimized
module legitimately has fewer accesses) and **additive** (a module with no redundancy is unchanged).

### M5 — The alias analysis: precise on the tractable shapes, conservative everywhere else; barriers forget everything

`alias(a, b)` over two footprints `#(mem, base, offset, bytes)`:

- **different `mem`** ⇒ `NoAlias` (multi-memory: memories are disjoint address spaces).
- **same `mem`, both bases syntactically equal `Value`s** (same `Var` name, or equal `Const*`) ⇒
  compare byte ranges `[offset, offset+bytes)`: **identical range** ⇒ `MustAlias`; **disjoint
  ranges** ⇒ `NoAlias` (this is the Array-SSA element disambiguation — `base+0`/4 bytes vs
  `base+4`/4 bytes do not alias); **partial overlap** ⇒ `MayAlias`.
- **same `mem`, different or unknown bases** (a `Var` vs a different `Var`, or a `Var` vs a `Const`)
  ⇒ `MayAlias` — general pointer aliasing is undecidable, and Phase 9 does **not** attempt base
  value-numbering beyond syntactic equality (the honest ceiling, M8). This is the *conservative*
  direction (→ no rewrite), so it is always safe.

A **memory barrier** — anything that may read/write/reallocate linear memory or leave the region —
**clears all memory knowledge** (the `avail` map is emptied; DSE look-ahead stops). The barrier set:
`MemGrow` (reallocates), every call (`CallDirect`/`CallIndirect`/`CallHost`/`CallImport`/
`CallClosure` — may touch any memory), every **bulk-memory** op (`MemFill`/`MemCopy`/`MemInit`/
`DataDrop` — write ranges a scalar footprint cannot be disambiguated against), and every
non-returning / control-flow node (`Trap`/`Throw`/`ThrowRef`/`Return`/`Break`/`Continue`, and the
structured `If`/`Switch`/`Loop`/`Block`/`Try` region boundaries — the analysis is **per
straight-line region**, M8). **Memory-transparent** (do *not* clear memory knowledge — they touch a
provably-disjoint state cell and cannot trap): `GlobalGet`/`GlobalSet` (the globals cell, not linear
memory), and the pure ops (`Values`/`Num`/`Convert`/`TermOp`/`Simd`/…). This is a **refinement** of
`ir/effect` for *memory dependence*, and it is **strictly more conservative than needed** wherever
there is doubt — the classifier defaults to "barrier."

### M6 — Additive + conformance-neutral, proven differentially across all tiers and both modes

Every Phase-9 rewrite preserves observable behaviour (M3), so the Phase-1…8 corpus + spec suite must
stay **result-identical** — same values by bit pattern, same traps — under **both** profiles and
**every** shipped `(state_strategy × mem_tier)` combo. This is the F2-style **differential harness**
(unit 04 owns the corpus wiring; each pass unit owns per-pass fixtures). Unlike Phase 8 (which was
*emission*-byte-identical because its nodes were never produced by WASM), Phase 9 legitimately
changes the *emitted* code (fewer accesses) — so the bar is **result**-identical, exactly like the
Phase-3 optimizer differential (`OptNone ≡ Baseline ≡ Aggressive`). "Done" = that differential is
green corpus-wide, on every tier, under both modes.

### M7 — Termination stays well-founded: no memory pass ever *creates* a `MemLoad`/`MemStore`

The Phase-3 `run_pipeline` fixpoint converges under the lexicographic measure
`μ = (n_loops, n_ops, n_nodes, n_vars)`; every baseline rewrite is non-increasing in `μ` and any
*changing* one strictly decreases it. Phase 9 **prepends a most-significant component**
`n_mem` = the number of `MemLoad` + `MemStore` nodes:

```
μ₉(m) = ( n_mem , n_loops , n_ops , n_nodes , n_vars )
```

- **store→load forwarding / RLE** replace a `MemLoad` with `Values` ⟹ `n_mem` strictly ↓.
- **dead-store elimination** removes a `MemStore` ⟹ `n_mem` strictly ↓.
- **no Phase-9 pass ever constructs a `MemLoad` or `MemStore`**, and **no baseline pass does either**
  (fold/prop/DCE/dead-`let`/block-label only remove or shrink structure). So `n_mem` is
  monotonically non-increasing across every round, and every *changing* memory rewrite strictly
  decreases the most-significant component — the baseline passes keep decreasing the lower-order
  components as before. `μ₉` is bounded below by `(0,0,0,0,0)`, so the fixpoint is reached well
  before `max_rounds`, and no pass can undo another (each moves the program toward a strictly smaller
  `μ₉`). The keystone (unit 01) states and the capstone (unit 04) re-verifies this over the corpus
  (no non-convergence, no panic).

### M8 — Honest scope (measured, pattern-dependent, bounded)

See §1 honest scope and §6. Ship the three no-new-surface MemorySSA payoffs; defer standalone-BCE,
LICM, and cross-control-flow MemorySSA (stated, not dropped). Trap-preservation is absolute. The
alias analysis is precise on structured `base + const` patterns and conservative elsewhere — the
benchmark **states the ceiling and measures the win** (deterministic elimination counts + wall-clock,
DSE's paged advantage broken out), per the note's invariant #4. No hero number.

---

## 3. Dependency DAG — the one freeze milestone

```
WAVE 0   01 KEYSTONE (one owner):
            «MEM-SSA-FROZEN»  (mem_ssa.gleam — footprint + AliasResult + alias/2 +
                               is_memory_barrier/1 + the avail-map type + μ₉ measure helper;
                               imports `ir` + `ir/effect` ONLY → no cycle)
            lands GREEN with the pipeline STILL EMPTY (identity; corpus byte-identical)
                                    │
                 ┌──────────────────┴───────────────────┐
                 ▼ «MEM-SSA»                              ▼ «MEM-SSA»
          ┌────────────────┐                      ┌────────────────┐
          │ 02 mem_forward │                      │ 03 mem_dse     │
          │ store→load fwd │                      │ dead-store     │
          │ + redundant-   │                      │ elimination    │
          │   load elim    │                      │ (paged win)    │
          └───────┬────────┘                      └───────┬────────┘
                  │  (each ships its pass(es) + fixtures; NOT yet wired — corpus untouched)
                  └───────────────────┬──────────────────┘
                                      ▼
                        ┌───────────────────────────────┐
WAVE C                  │ 04 CAPSTONE: wire the three    │
                        │ passes into ir_opt.pipeline    │
                        │ (Baseline arm → inherited by   │
                        │ Aggressive); corpus-wide       │
                        │ differential (OptNone ≡        │
                        │ Baseline, every tier + both    │
                        │ modes); the memory benchmark   │
                        │ (static counts + wall-clock);  │
                        │ docs/phase-9-benchmark.md      │
                        └───────────────────────────────┘
```

- **The keystone (01) gates everything** — an unsound `alias`/barrier set makes every rewrite
  unsound. Start it first; it lands green with an empty pipeline (identity), so the corpus stays
  byte-identical until unit 04 wires the passes in.
- **Units 02 and 03 parallelize** once `«MEM-SSA-FROZEN»` publishes the footprint/alias/barrier
  interface. Each ships its pass(es) + isolated fixtures **without** touching `ir_opt.pipeline` — so
  the corpus is byte-identical at 02 and 03 too (the passes exist, tested in isolation, but are not
  yet in the pipeline). This keeps 01/02/03 individually green + pushable.
- **The capstone (04) is the only unit that edits `ir_opt.pipeline/1`** — the single registration
  point (exactly as Phase-3 units 03/04 edited it). Wiring the passes is what makes the corpus
  differential and the benchmark meaningful; it is where conformance-neutrality across tiers/modes is
  proven and speed is measured. "Faster" is unit 04's deliverable.

---

## 4. File-ownership map (D1)

> Single owner per file. The capstone makes exactly one documented cross-file reach (the pipeline
> registration point), as every optimizer phase before it did.

| Unit | File(s) | Notes |
|---|---|---|
| **01** keystone | `src/twocore/middle/ir_opt/mem_ssa.gleam` (**NEW**, owned) · `test/twocore/optimize/mem_ssa_test.gleam` (**NEW**) | `«MEM-SSA-FROZEN»`: footprint/`AliasResult`/`alias`/`is_memory_barrier`/`avail`-map/`μ₉` measure. Imports `ir` + `ir/effect` only. Adversarial alias fixtures. Lands green, pipeline still empty. |
| **02** forwarding + RLE | `src/twocore/middle/ir_opt/mem_forward.gleam` (**NEW**, owned) · `test/twocore/optimize/mem_forward_test.gleam` (**NEW**) | **One** unified pass `forwarding_pass()` (a `pass.per_function` scope-aware walk threading the `avail` map) realizing **both** store→load forwarding **and** redundant-load elimination — they are the *same* transfer function (a load is served from `avail` whether the entry came from a preceding store or a preceding load). Ships the pass + fixtures; **does not** touch `ir_opt.pipeline`. |
| **03** DSE | `src/twocore/middle/ir_opt/mem_dse.gleam` (**NEW**, owned) · `test/twocore/optimize/mem_dse_test.gleam` (**NEW**) | One pass `dead_store_pass()`, a `pass.per_function` look-ahead peephole. Ships the pass + fixtures + the paged-win rationale; **does not** touch `ir_opt.pipeline`. |
| **04** capstone | `src/twocore/middle/ir_opt.gleam` (**edit `pipeline/1`** — the single registration point) · `test/twocore/optimize/memory_differential_test.gleam` (**NEW**) · a benchmark harness (`smoke/mem_bench.sh` + a fixture kernel) · `docs/phase-9-benchmark.md` (**NEW**) | Append `[mem_forward.store_load_forward(), mem_forward.redundant_load_elim(), mem_dse.dead_store_elim()]` to the `Baseline` arm (inherited by `Aggressive`). Corpus-wide differential across tiers + modes. The measured benchmark + honest report. |

**The capstone's one reach.** `ir_opt.pipeline/1` currently returns `baseline.baseline_passes()` for
`Baseline` and `baseline_passes() ++ aggressive.aggressive_passes()` for `Aggressive`. Unit 04
inserts the memory passes **between** baseline and aggressive so `Aggressive` stays a superset,
where `memory_passes` is the two-pass list
`[mem_forward.forwarding_pass(), mem_dse.dead_store_pass()]`:
`Baseline -> baseline_passes() ++ memory_passes` and
`Aggressive -> baseline_passes() ++ memory_passes ++ aggressive_passes()`.
`ir_opt.gleam` importing `mem_forward`/`mem_dse` is acyclic (they import `{ir, ir/effect, pass,
mem_ssa}`; none imports `ir_opt`). Document the reach in `state.md`.

---

## 5. How to claim & complete (same as every prior phase)

Read this page → your unit doc → [`specs/state.md`](../state.md). Set status `in-progress`; confirm
`«MEM-SSA-FROZEN»`; build to the Definition of Done (D8: **spec-cited** tests that assert *defined
behaviour* and the trap-preservation invariant — never change-detectors; doc comments on every
public function; `gleam format --check src test` clean; **zero warnings**; and your unit's
suite passing — "done" is *the suite passes*, never "it compiles"). Update `state.md` with what you
leave. When in doubt about a soundness decision, **ask the planner** rather than guessing — a single
unsound alias judgement is silent memory corruption. The manager QA-gates
(`format`/`build`/`test` + a spec-DoD read) and commits + pushes each unit to `main`.

---

## 6. Deferred to a later phase (explicit — stated, not dropped)

- **Standalone range-based bounds-check elimination.** Dropping the bounds *check* while keeping the
  read/write (the note's second lever) needs an **unchecked-access representation** the IR does not
  have (a new `MemLoad`/`MemStore` "known-safe" form + `rt_mem` unchecked entry points across every
  tier and both state strategies). Phase 9 ships the check-dropping that needs *no* new surface
  (forwarding removes the whole access, check included); the standalone form is a later unit.
- **Loop-invariant code motion (LICM).** Hoisting the loop-invariant **handle fetch** (in `atomics`,
  `grow` reallocates, so absent a `grow` the handle is loop-invariant) needs the handle **exposed as
  an IR value** — today it is fetched inside each `rt_mem` call, below the IR. That is an
  `emit_core`/`rt_mem` seam change, out of Phase 9's pure-IR scope.
- **MemorySSA across control flow.** Phase 9's analysis is intraprocedural and **per straight-line
  region** — it resets at every `If`/`Switch`/`Loop`/`Block`/`Try` boundary. A φ-joined cross-block
  MemorySSA (forward a store into both arms of an `If`; RLE across a loop back-edge under a
  no-clobber proof) is the natural sequel.
- **Escape analysis for the term/object value path.** Per the note's invariant on the framework:
  escape analysis is **not** the lever for linear memory (our one-instance-one-process design
  pre-satisfies its classic payoff). It is tagged for the **term/object** path (scalar-replace
  objects, avoid boxing closures — the Phase-8 value layer's speed unit), which is object speed, not
  linear-memory speed. Out of Phase 9.
