# Phase 10 — The Memory Optimizer, completed (LICM + cross-control-flow MemorySSA + range-based BCE)

> **Read this after the Phase-9 overview ([`../phase-9/00-overview.md`](../phase-9/00-overview.md),
> decisions M1–M8) — Phase 10 is its direct sequel, building the three linear-memory optimizations
> Phase 9 explicitly deferred (§6).** Every prior decision **still holds** — one owner per file (D1),
> runtime layers reached only through the binding chokepoint with **no ambient authority** (D3a),
> per-stage error types (D4), floats/v128 as raw bit patterns (D5), named-label structured IR (D6),
> the tier ladder, the two modes (Safe/Unsafe), **spec-first tests** (assert *defined* behavior, never
> change-detector output — D8), `gleam format`/`gleam build` clean, the strict Definition of Done.
> This page adds the Phase-10 decisions **N1–N8** and the work breakdown. Baseline entering Phase 10:
> **1783 tests, 0 failures, 0 warnings**; the Phase-9 MemorySSA + alias analysis + store→load
> forwarding / RLE / dead-store elimination are green on `main`, measured ~3–4× faster on paged.

---

## 0. Where Phase 10 sits (the platform, one paragraph)

Phase 9 shipped the three MemorySSA payoffs that need **no new IR surface** — store→load forwarding,
redundant-load elimination, dead-store elimination — each per *straight-line region*, each removing a
whole redundant access. It deferred (Phase-9 §6) the three linear-memory optimizations that need
*more*: **loop-invariant code motion** (hoist the loop-invariant work — including the loop-invariant
handle/address computation — out of the hot loop), **MemorySSA across control flow** (let
forwarding/RLE/DSE survive an `If`/`Block`/`Switch` when no branch clobbers the footprint — Phase 9
reset at every region boundary), and **range-based bounds-check elimination** (elide the
per-iteration `MemoryOutOfBounds` compare-and-branch on a loop whose whole access range is provably
in-bounds). Phase 10 builds all three. Two are **pure IR→IR** (LICM, cross-CF MemorySSA) — the same
trust-neutral, all-tiers/both-modes discipline as Phase 9. The third — range-based BCE — is the first
memory optimization since Phase 4 to **grow the runtime ABI** (an *unchecked* memory access), and it
is made **sound and trust-neutral by loop versioning**: a runtime range-guard picks the unchecked
fast loop **only when it has proven the whole range in-bounds**, and otherwise runs the original
checked loop — so observable value **and trap** behaviour are exactly preserved (N6).

---

## 1. The Phase-10 goal (concrete and measurable)

> **Complete the linear-memory optimizer: hoist the loop-invariant work, carry memory facts across
> control flow, and remove the per-iteration bounds check on provably-in-bounds loops — soundly, in
> a way that speeds up every tier and both modes.** LICM (`middle/ir_opt/licm`) hoists pure
> loop-invariant computation to a synthesized preheader. Cross-CF MemorySSA extends the Phase-9
> `avail`/DSE framework with a **may-clobber** analysis so a store's value survives an `If`/`Block`
> whose branches provably do not write the footprint. Range-based BCE (`middle/ir_opt/bce`)
> recognizes an **affine-access loop** (a monotone induction variable, loop-invariant bounds, no
> `grow`/call in the loop), computes its access range, and emits **loop versioning** — `if
> whole_range_in_bounds { loop-with-unchecked-accesses } else { original-checked-loop }` — lowering
> the unchecked accesses to new `rt_mem` **unchecked** entry points on the `paged` and `atomics`
> tiers. Every rewrite is **byte-for-byte semantics-preserving** (same values by bit pattern, same
> traps) over the whole Phase-1…9 corpus + WASM spec suite, under **both** profiles and **every**
> shipped `(state_strategy × mem_tier)`. The win is **measured**, not asserted: a committed benchmark
> reports LICM's hoist-count + speedup and BCE's per-iteration check removal + atomics speedup, with
> the honest pattern-dependence ceiling written down.

### Acceptance (owned by the capstone, unit 07)

| Area | Must demonstrate (spec-first, on the real BEAM) |
|---|---|
| **optimizer soundness (the bar)** | `optimize(m, OptNone) ≡ optimize(m, Baseline) ≡ optimize(m, Aggressive)` — byte-identical returned values (D5/D7) and identical traps — over the whole Phase-1…9 corpus + WASM spec suite, under **every** shipped `(state_strategy × mem_tier)` and **both** profiles |
| **LICM** | a pure, loop-invariant computation inside a `Loop` is hoisted to a preheader `Let` and evaluated once, not per iteration (proven by inspecting the optimized IR); a loop that runs **zero** times still never evaluates the hoisted expression's *effects* (LICM hoists only **pure** expressions, so there are none — the zero-trip soundness case); value + trap behaviour unchanged end-to-end |
| **cross-CF MemorySSA** | `store(F, v); if (c) {…no F write…}{…no F write…}; load(F)` forwards `v` across the `if` (proven by the load disappearing); the ADVERSARIAL case `store(F, v); if (c) { store(F, w) }{}; load(F)` does **not** forward (a branch may clobber F) — the may-clobber analysis is the safety gate |
| **range-based BCE (the runtime-touching one)** | an affine loop `for i in 0..n: acc += mem[base + 4·i]` with a loop-invariant `base`/`n` and no `grow`/call emits a versioned loop; the fast arm uses `MemLoadUnchecked` (no per-iteration bounds check); the guard falls to the **checked** loop when the range check fails — proven by (a) the in-bounds run returning the identical value and (b) an **out-of-range** run trapping `MemoryOutOfBounds` at the **same observable point** as the unoptimized loop (loop versioning preserves the trap) |
| **runtime unchecked entry points** | `rt_mem`/`rt_mem_atomics` gain `load_unchecked`/`store_unchecked` (+ threaded twins) that return the identical bits as the checked path for every in-bounds access (a differential vs the checked oracle); an OOB unchecked access is **BEAM-safe** (a caught error / trap, never memory corruption — paged slices an immutable binary, atomics indexes an `atomics` array); the `nif` tier **falls back to the checked path** (Safe forbids nif; BCE's win is on atomics) |
| **conformance-neutral + all-tier + both-mode** | the whole Phase-1…9 corpus + spec suite stay green (result-identical) under both profiles and every tier; the new IR nodes are **never produced by the WASM frontend** (additive, like Phase-8's nodes) so a module with no Phase-10 rewrite is unchanged; `.ir` round-trips the new nodes |
| **measured speedup** | committed benchmarks show LICM firing (a deterministic hoist count) + a wall-clock win on an invariant-heavy loop, and BCE firing (a deterministic per-iteration-check-removal count) + a wall-clock win on an atomics affine-access loop — with methodology and the honest ceiling in `docs/phase-10-benchmark.md`. No hero number. |

### Honest scope (N8 — do not overstate)

- **Two pure-IR passes + one runtime-touching pass.** LICM and cross-CF MemorySSA add **no** IR
  node and touch **no** runtime (pure IR→IR, trust-neutral, all tiers/modes — Phase-9 discipline).
  Range-based BCE is the exception: it adds the additive `MemLoadUnchecked`/`MemStoreUnchecked` IR
  nodes and the `rt_mem`/`rt_mem_atomics` unchecked entry points, and is made sound by **loop
  versioning** (N6) — it does **not** hoist-and-trap-early (which would change trap timing).
- **BCE is pattern-bounded and versioning-based, not a general range solver.** It recognizes the
  affine-access loop shape compilers emit — one monotone induction variable stepped by a constant,
  addresses affine in it (`base + c·i + off`), loop-invariant `base`/bound/stride, and **no `grow`
  or call in the loop body** (so the memory size is stable). Nested induction, non-affine addresses,
  and loops that grow/call are left checked (sound, just not accelerated). It is a **measured,
  pattern-dependent** win, largest on `atomics` (where a load is O(1) and the bounds branch is a
  real fraction); on `paged` the store rebuild dominates, so BCE's paged win is small (stated).
- **`nif` BCE is deferred (fallback to checked).** An unchecked *native* access could corrupt the
  node if the range analysis were wrong; Safe forbids nif and the nif C backend is a documented
  skeleton (Phase 4), so nif unchecked accesses **fall back to the checked path**. The unchecked
  entry points ship on `paged` + `atomics`, which are BEAM-safe even on an (impossible-by-guard) OOB.
- **Deferred, stated not dropped:** escape analysis for the term/object value path (object speed,
  not linear memory — a future phase gated on a frontend that emits object-heavy code); a general
  polyhedral range solver; nested-loop / multi-dimensional BCE; and the tier-N unchecked native path.

---

## 2. The Phase-10 decisions (N1–N8)

Frozen for Phase 10. If you believe one is wrong, raise it with the planner **before** building on
it (the D1 rule).

### N1 — One keystone freezes the shared analysis + the BCE surface; the three passes consume it

`middle/ir_opt/mem_ssa.gleam` (the Phase-9 keystone) already gives `Footprint`/`alias`/
`is_memory_barrier`/`byte_width`/`count_mem_ops`. Phase 10's keystone (unit 01) adds, as **new leaf
modules** and **additive** surface:

- `middle/ir_opt/loop_analysis.gleam` — the shared loop analysis LICM and BCE both need: loop
  structure, **loop-invariance** (a subexpression whose free variables are all defined *outside* the
  loop and which is pure), and **induction-variable recognition** (a `LoopParam` stepped by a
  constant each back-edge, with a loop-invariant trip bound).
- `middle/ir_opt/mem_clobber.gleam` — the **may-clobber** analysis cross-CF MemorySSA needs: given a
  control-flow subtree and a footprint `F`, *could any execution of this subtree write bytes that
  alias `F`, grow memory, or call out?* (Conservative: `True` unless proven `False`.)
- the additive IR nodes `MemLoadUnchecked`/`MemStoreUnchecked` (unit 01 lands their `ir.gleam`
  variants + `.ir` printer/parser round-trip + `ir/effect` classification + `mem_ssa`
  footprint/barrier handling + `map_expr`/`count_mem_ops` coverage + `emit_core` lowering — all
  freeze-safe: at the freeze they lower **exactly like the checked nodes** so nothing is unsound
  until unit 06 proves the guard).
- the `rt_mem`/`rt_mem_atomics` unchecked entry-point **signatures** (frozen; real bodies in unit 04).

The keystone lands **green with the pipeline still identity** — no pass produces a new node, no
runtime path changes behaviour — exactly like the Phase-9 keystone.

### N2 — LICM is pure IR→IR, trust-neutral, all tiers/both modes

`middle/ir_opt/licm.gleam` (unit 02) hoists a **pure, loop-invariant** `Let` binding from inside a
`Loop` body to a synthesized **preheader** (`Let(name, invariant_rhs, Loop(...))`). Soundness rests
on two facts: (i) the hoisted expression is `ir/effect.is_pure` (no effect to reorder, no trap to
move — **the zero-trip case is automatic**: a pure expression evaluated on a loop that runs zero
times changes nothing observable); (ii) its free variables are all defined outside the loop (so it
computes the same value every iteration). It hoists loop-invariant **address arithmetic** and
constant sub-expressions out of hot loops — a real per-tier win with no IR growth and no runtime
touch. Registered into `Baseline` (Safe gets it; Aggressive inherits it).

### N3 — Cross-CF MemorySSA extends the Phase-9 framework, gated by a may-clobber analysis

Phase 9 reset the `avail` map (forwarding/RLE) and stopped the DSE peel at **every** control-flow
boundary. Phase 10 (unit 03) relaxes that **only where provably safe**: at an `If`/`Block`/`Switch`,
instead of clearing an `avail` entry for footprint `F`, it **keeps** the entry iff
`mem_clobber.may_clobber(subtree, F) == False` for **every** control-flow child (no branch could
write `F`, grow, or call out). Likewise DSE may look *through* a no-clobber control-flow region to a
shadowing store. The may-clobber analysis is the safety gate (conservative: any doubt ⇒ clobber ⇒
clear, i.e. exactly Phase-9's behaviour). Pure IR; no new node; trust-neutral. This subsumes
Phase-9's per-region reset as the special case "every region may-clobbers."

### N4 — Range-based BCE is sound via **loop versioning**, never hoist-and-trap-early

A WASM memory access is **trap-or-access**; a bounds check may not simply be dropped, because a loop
with side effects before an OOB iteration must still trap **at that iteration** with those effects
already applied. So BCE (unit 06) **does not** hoist the check and trap early. It **versions the
loop**:

```
let all_in_bounds = <pure range check: base, stride, trip-count, offset, width vs memory.size>
if all_in_bounds
  then  <the loop, with its affine accesses lowered to MemLoadUnchecked/MemStoreUnchecked>
  else  <the original loop, unchanged (checked accesses)>
```

This is **exactly semantics-preserving**: when the range check passes, every iteration's access is
provably in-bounds, so the unchecked fast loop behaves identically to the checked loop (no trap would
have fired either way); when it fails, the original checked loop runs — identical values, identical
trap at the identical point. The range check is **pure** (arithmetic on loop-invariant quantities +
`memory.size`), so it introduces no new effect or trap. **Preconditions for versioning** (all
required, else leave the loop checked): a single monotone induction variable stepped by a constant;
affine accesses `base + stride·i + off` with loop-invariant `base`/`stride`/`off`; a loop-invariant
trip bound; and **no `MemGrow` and no call** in the loop body (so `memory.size` — read once in the
guard — is stable for the whole loop). Because versioning preserves traps exactly, BCE is
**trust-neutral** and runs at `Baseline` (all tiers/both modes).

### N5 — Unchecked entry points are BEAM-safe on paged/atomics; nif falls back to checked

`rt_mem` (paged) and `rt_mem_atomics` (atomics) gain `load_unchecked`/`store_unchecked` (+ the
`t_*` threaded twins + `_at` multi-memory twins as needed) that **skip the bounds compare** and go
straight to the byte access. Crucially, even though the loop guard makes an actual OOB impossible,
the unchecked path is **BEAM-memory-safe** if it ever were OOB: paged slices an **immutable binary**
(an out-of-range slice is a caught BEAM error → a trap, never corruption); atomics indexes an
`atomics` array (an out-of-range index is a caught error). So a hypothetical range-analysis bug
degrades to a *trap*, never a node crash or memory corruption. The **`nif` tier does not get
unchecked accesses** — an unchecked *native* access could corrupt the node, Safe forbids nif, and the
win is on atomics — so the BCE lowering emits the **checked** nif path (the versioned fast loop and
slow loop are identical there; a documented, sound no-op on nif). `emit_core` selects the unchecked
entry point by the linked `mem_module`, exactly as it selects the checked one (G5 — the emitter never
sees the tier).

### N6 — Additive + conformance-neutral, proven differentially across all tiers and both modes

Every Phase-10 rewrite preserves observable behaviour, so the Phase-1…9 corpus + spec suite must
stay **result-identical** — same values by bit pattern, same traps — under **both** profiles and
**every** shipped `(state_strategy × mem_tier)`. The new IR nodes are produced **only** by the BCE
pass, **never** by `decode`/`validate`/`lower` (the WASM frontend), so a module with no Phase-10
rewrite emits byte-identical code; the `.ir` textual form round-trips the new nodes (unit 01). This is
the F2-style differential (unit 07 owns the corpus wiring; each pass unit owns its fixtures) — "done"
= the differential is green corpus-wide, on every tier, under both modes.

### N7 — Termination stays well-founded; LICM and versioning are bounded

The Phase-9 fixpoint measure `μ₉ = (n_mem, n_loops, n_ops, n_nodes, n_vars)` is extended so the new
passes stay well-founded: **LICM** moves a `Let` from inside a loop to a preheader (node count
unchanged, but it is applied **once per invariant binding** and is idempotent — a hoisted binding is
not re-hoisted because its rhs is no longer inside the loop; a monotone "hoisted-out node count"
guarantees termination). **BCE loop versioning** *adds* nodes (it clones the loop) — so it is
applied **at most once per eligible loop** (an already-versioned loop's fast arm uses unchecked
accesses, which are not re-eligible; a guard on "the loop already contains an `Unchecked` access"
makes it idempotent) and is **not** part of the size-reducing fixpoint set. Cross-CF MemorySSA only
*removes* accesses (like Phase 9) → `n_mem` ↓. The keystone states the argument; the capstone
re-verifies convergence (no non-termination, no panic, no unbounded growth) over the corpus.

### N8 — Honest scope (measured, pattern-dependent, bounded)

See §1. Ship LICM + cross-CF MemorySSA (pure IR) + range-based BCE via loop versioning (paged +
atomics unchecked; nif checked-fallback). Escape analysis (object path), a general range solver,
nested/multi-dimensional BCE, and tier-N unchecked native remain deferred. The benchmark **states the
ceiling and measures the win** (LICM hoist-count + speedup; BCE check-removal count + atomics
speedup; DSE/paged is Phase-9's headline, not BCE's). No hero number.

---

## 3. Dependency DAG — the one freeze milestone

```
WAVE 0   01 KEYSTONE (one owner):
            «MEM10-FROZEN»  = loop_analysis (invariance + induction) + mem_clobber (may-clobber)
                              + MemLoadUnchecked/MemStoreUnchecked (ir + printer/parser + effect +
                              mem_ssa + emit — freeze-safe: lower like the checked nodes)
                              + rt_mem/rt_mem_atomics unchecked SIGNATURES (stub → 04)
            lands GREEN, pipeline identity (corpus byte-identical)
                                    │
        ┌───────────────┬───────────┼──────────────────┬─────────────────────────┐
        ▼ (loop_anal.)  ▼ (mem_clob) ▼ (rt_mem sigs)    ▼ (unchecked node)         ▼
   ┌──────────┐   ┌──────────────┐  ┌──────────────┐  (04 needs the sigs; 05/06 need 04)
   │ 02 LICM  │   │ 03 cross-CF  │  │ 04 rt_mem    │
   │ (pure IR)│   │ MemorySSA    │  │ unchecked    │
   └────┬─────┘   │ (pure IR)    │  │ (paged+atom) │
        │         └──────┬───────┘  └──────┬───────┘
        │                │                 ▼
        │                │          ┌──────────────┐   ┌──────────────┐
        │                │          │ 05 emit_core │──▶│ 06 range-BCE │
        │                │          │ unchecked    │   │ + versioning │
        │                │          │ lowering     │   │ (the pass)   │
        │                │          └──────────────┘   └──────┬───────┘
        └────────────────┴─────────────────────────────────────┤
                                                                ▼
                                        ┌───────────────────────────────────┐
WAVE C                                  │ 07 CAPSTONE: wire LICM + cross-CF  │
                                        │ + BCE into ir_opt.pipeline; corpus │
                                        │ differential (all tiers + modes) + │
                                        │ the measured benchmarks +          │
                                        │ docs/phase-10-benchmark.md         │
                                        └───────────────────────────────────┘
```

- **The keystone (01) gates everything.** It lands green with the pipeline identity (the unchecked
  nodes lower like checked nodes at the freeze, so nothing is unsound until unit 06 emits them under
  a proven guard). Start it first.
- **LICM (02) and cross-CF (03) parallelize** and are pure IR — they can land (and push) as soon as
  `loop_analysis` / `mem_clobber` freeze, independent of the BCE runtime chain.
- **The BCE chain is 04 → 05 → 06.** Runtime unchecked entry points (04) → `emit_core` lowering of
  the unchecked nodes (05) → the range-BCE + loop-versioning pass (06). Each pushable in turn.
- **The capstone (07)** is the only unit that edits `ir_opt.pipeline/1` (the single registration
  point). It wires all three passes, proves the corpus differential across every tier + both modes,
  and measures the win.

---

## 4. The units (implementation order = dependency order)

| # | Unit | Ships | Depends |
|---|---|---|---|
| 01 | [`01-keystone.md`](01-keystone.md) | `loop_analysis` + `mem_clobber` leaf modules; the additive `MemLoadUnchecked`/`MemStoreUnchecked` nodes (ir/printer/parser/effect/mem_ssa/emit, freeze-safe); the `rt_mem`/`rt_mem_atomics` unchecked signatures | — |
| 02 | [`02-licm.md`](02-licm.md) | `middle/ir_opt/licm.gleam` — hoist pure loop-invariant `Let`s to a preheader | 01 (`loop_analysis`) |
| 03 | [`03-cross-cf-memoryssa.md`](03-cross-cf-memoryssa.md) | cross-control-flow forwarding/RLE/DSE via `mem_clobber` (extends the Phase-9 passes or a new pass) | 01 (`mem_clobber`) |
| 04 | [`04-rt-mem-unchecked.md`](04-rt-mem-unchecked.md) | `rt_mem` + `rt_mem_atomics` `load_unchecked`/`store_unchecked` (+ `t_*` twins); differential vs the checked oracle; nif checked-fallback | 01 (sigs) |
| 05 | [`05-emit-unchecked.md`](05-emit-unchecked.md) | `emit_core` lowering of `MemLoadUnchecked`/`MemStoreUnchecked` to the unchecked entry points (paged/atomics) / checked fallback (nif) | 01, 04 |
| 06 | [`06-range-bce.md`](06-range-bce.md) | `middle/ir_opt/bce.gleam` — recognize an affine-access loop, synthesize the range guard + versioned loop with unchecked accesses | 01, 05, `loop_analysis` |
| 07 | [`07-capstone.md`](07-capstone.md) | wire LICM + cross-CF + BCE into `ir_opt.pipeline`; corpus differential (all tiers + modes) + `count_mem_ops`/idempotence checks; the measured benchmarks + `docs/phase-10-benchmark.md` | 02, 03, 06 |

**Every unit's Definition of Done:** spec-first tests that assert *defined* behavior (never bytes) —
for the passes, the transformation + its adversarial "must-NOT" fixtures + end-to-end BEAM
value/trap preservation; `gleam format` clean; `gleam build` 0 warnings; the full suite stays green
(≥ 1783, 0 failures); the WASM corpus result-identical under both profiles + every tier; committed as
one focused unit and pushed.

---

## 5. How to claim & complete (same as every prior phase)

Read this page → your unit doc → [`../state.md`](../state.md). Set status `in-progress`; confirm
`«MEM10-FROZEN»`; build to the Definition of Done (D8: **spec-cited** tests asserting defined
behaviour and the soundness invariant — never change-detectors; doc comments on every public
function; `gleam format --check src test` clean; **zero warnings**; your unit's suite passing).
Update `state.md`. When in doubt about a soundness decision — especially the BCE range check and the
may-clobber analysis — **ask the planner**; a wrong range proof or a false "no clobber" is silent
memory corruption. The manager QA-gates and commits + pushes each unit to `main`.

---

## 6. Deferred to a later phase (explicit — stated, not dropped)

- **Escape analysis for the term/object value path** — scalar-replace non-escaping maps, avoid
  boxing closures. A *different axis* (object speed, not linear memory) and premature until a
  frontend emits object-heavy code; a future phase.
- **A general (polyhedral) range solver** — Phase-10 BCE recognizes the single-affine-access,
  single-monotone-induction-variable loop shape; nested induction, multi-dimensional / non-affine
  addressing, and loops that `grow`/call remain checked.
- **Tier-N unchecked native access** — the unchecked path ships on paged + atomics (BEAM-safe); the
  nif tier stays checked (a real C NIF for tier-N memory is itself a documented Phase-4 deferral).
