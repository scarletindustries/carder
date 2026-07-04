# Phase 10 · Unit 07 — Capstone: wire LICM + cross-CF + BCE, prove conformance-neutrality, measure the win

> **One owner · Wave C (last) · depends on the freeze AND the landed work of 02/03/06.** Read
> [`00-overview.md`](00-overview.md) (N1–N8, esp. §3 DAG / §4 units / the acceptance table), the
> keystone [`01-keystone.md`](01-keystone.md) (`loop_analysis`, `mem_clobber`, the unchecked nodes,
> `count_mem_ops`), then the three pass siblings — [`02-licm.md`](02-licm.md) (exports `licm_pass()`),
> [`03-cross-cf-memoryssa.md`](03-cross-cf-memoryssa.md) (edits `mem_forward`+`mem_dse` **in place**,
> **no new pass symbol**), [`06-range-bce.md`](06-range-bce.md) (exports `bce_pass()`) — and, for the
> format, the Phase-9 capstone [`../phase-9/04-capstone.md`](../phase-9/04-capstone.md) +
> [`docs/phase-9-benchmark.md`](../../docs/phase-9-benchmark.md) and the Phase-4 revisit
> [`../phase-4/10-benchmark-revisit.md`](../phase-4/10-benchmark-revisit.md). This is the terminal
> proof-of-goal unit: it **wires** all three Phase-10 passes into the pipeline (the one cross-file
> reach), proves the whole Phase-1…9 corpus + spec suite stays **result-identical** on every tier
> under both modes now that LICM + cross-CF MemorySSA + range-BCE (versioned loops + unchecked
> accesses) run on real programs, and **measures** the win with honest numbers. It is the only
> Phase-10 unit that edits `ir_opt.pipeline`; it emits nothing others build on. Baseline entering
> Phase 10: **1783 tests, 0 failures, 0 warnings.**

---

## Context

Phase 10 makes one claim only a capstone can prove: **the three deferred linear-memory
optimizations — loop-invariant code motion, MemorySSA carried across control flow, and range-based
bounds-check elimination via loop versioning — change no observable result or trap on any real
program, and they make real programs faster.** Both halves are *differential* claims — hold the
program fixed, vary the optimizer level (and the tier, and the mode), assert equivalence and measure
the delta — so the terminal unit owns the whole-corpus wiring, exactly as Phase-9's capstone owned
the memory-pass differential and Phase-3's owned `OptNone ≡ Baseline ≡ Aggressive`.

Until this unit, units 02/03/06 land **green with the pipeline unchanged**: unit 02 ships
`licm.licm_pass()` + its isolated fixtures; unit 03 edits `mem_forward.forwarding_pass()` /
`mem_dse.dead_store_pass()` **in place** (the may-clobber relaxation is folded into the *existing*
Phase-9 passes — **no new pass symbol**) + its adversarial "must-NOT forward across a clobbering
branch" fixtures; unit 06 ships `bce.bce_pass()` + its versioning fixtures. **None** touches
`ir_opt.pipeline`, so `optimize` still runs only the Phase-9 memory set and the corpus is unchanged.
This unit is where the three passes go live. Wiring them is what makes the corpus differential and
the benchmark **meaningful**: before the wire, `OptNone ≡ Baseline` was true without exercising a
single Phase-10 rewrite; after it, it is the load-bearing gate that a wrong "no clobber" proof (a
cross-CF forward across a hidden write), an unsound hoist (a non-pure expression lifted out of a
loop), or a wrong range proof (a versioned loop's fast arm reading OOB) would turn red on the exact
program, on the exact tier.

"Done" for the phase is three things, all owned here:

| # | Proof | Decision |
|---|---|---|
| 1 | **the three passes are wired** — `Baseline` runs `baseline ++ [forwarding, dse] ++ [licm, bce]` (inherited by `Aggressive`), `OptNone` stays `[]`; `Aggressive` stays a strict superset | N2/N3/N4 |
| 2 | **conformance-neutral, all-tier, both-mode** — the Phase-1…9 corpus + spec suite are **result-identical** (values byte-identical by bit pattern, traps identical) across `OptNone`/`Baseline`/`Aggressive`, under **every** shipped `(state_strategy × mem_tier)` combo and **both** profiles; the fixpoint converges (no non-termination, no panic, no unbounded growth — N7 re-verified now that a node-adding pass is in the arm) | N6/N7 |
| 3 | **measured speedup** — committed benchmarks show LICM firing (a deterministic hoist count) + a wall-clock win on an invariant-heavy loop, and BCE firing (a deterministic unchecked-access count) + a wall-clock win on an `atomics` affine-access loop, with methodology and the honest ceiling in `docs/phase-10-benchmark.md` | N8 |

Phase 10 legitimately changes the *emitted* code (hoisted work, versioned loops, unchecked
accesses), so — like Phase 9 and unlike Phase 8's emission-byte-identical differential — the bar is
**result**-identical, exactly like the Phase-3 optimizer differential. The benchmark is **measured**,
never asserted: no hero number, the ceiling stated.

---

## Deliverables & freeze milestones

**Consumes** (every Phase-10 freeze + the landed passes):

- `«MEM10-FROZEN»` (unit 01) — `loop_analysis` (`free_vars`/`is_loop_invariant`/`bound_names`),
  `mem_clobber` (`may_clobber`/`may_write_memory`), the additive `MemLoadUnchecked`/`MemStoreUnchecked`
  nodes (round-trip / effect / footprint / `count_mem_ops` / emit), and `mem_ssa.count_mem_ops/1` (the
  deterministic static metric + the μ₉ convergence argument).
- `licm.licm_pass()` (unit 02) — the pure-IR LICM pass (`pass.Pass` value), tested green in isolation.
- `mem_forward.forwarding_pass()` + `mem_dse.dead_store_pass()` (unit 03) — the **same** Phase-9 pass
  symbols, now cross-control-flow via `mem_clobber` (edited **in place**; no new registration).
- `bce.bce_pass()` (unit 06) — the range-BCE + loop-versioning pass (`pass.Pass` value), tested green
  in isolation; it consumes `loop_analysis` + emits the unchecked nodes inside a versioned fast arm.
- The landed pipeline surface: `ir_opt.optimize/2`, `ir_opt.OptLevel`, `pass.run_pipeline`,
  `baseline.baseline_passes()`, `aggressive.aggressive_passes()`, the existing `memory_passes()`
  helper; the run/bench ABI (`pipeline.source_to_ir`/`ir_to_core`/`core_to_beam`/`exec_beam`,
  `ir_lower.lower`, `emit_core.emit_module`, `core_printer.print_module`); the tier-combo differential
  machinery (`test/twocore/tier/combos.gleam` — `binding_for/1`, `shipped`, `evaluate/2`,
  `identity_across/2`, `Outcome`, `corpus_programs`, `cap_pages`).

**Produces** (terminal — nothing downstream depends on it): the one pipeline edit, the corpus-wide
Phase-10 differential, the two isolate-the-delta benchmark tests + the committed honest report. No
publish-day-1 stub, no freeze milestone.

---

## Files owned (D1)

| File | Role |
|---|---|
| `src/twocore/middle/ir_opt.gleam` (**edit `memory_passes/0`** — the ONE reach) | extend the pass list to `[forwarding, dse, licm, bce]`; add the `licm` + `bce` imports |
| `test/twocore/optimize/phase10_differential_test.gleam` (**NEW**) | the corpus-wide `OptNone ≡ Baseline ≡ Aggressive` differential across every tier + both modes; convergence/idempotence; the `count_mem_ops` sanity reframe (§B.3) |
| `test/twocore/optimize/licm_bench_test.gleam` (**NEW**) | the LICM kernel: deterministic hoist-count (clock-independent) + wall-clock, two beams differing only in `licm_pass()` |
| `test/twocore/optimize/bce_bench_test.gleam` (**NEW**) | the BCE kernel: deterministic unchecked-access count + `atomics` wall-clock, two beams differing only in `bce_pass()` |
| `docs/phase-10-benchmark.md` (**NEW**) | the committed honest report (methodology, LICM hoist-count + speedup, BCE check-removal count + atomics speedup, the ceiling) |

The **per-pass** fixtures (LICM's "must-hoist" / "must-NOT-hoist a loop-bound or impure expr"
cases; cross-CF's "must-forward across a no-clobber `if`" / adversarial "must-NOT forward across a
clobbering branch"; BCE's "must-version an affine loop" / "must-leave a `grow`/call loop checked" /
the OOB trap-at-same-point case) belong to units 02/03/06 under their own test files; this unit owns
only the **whole-corpus** differential and the two benchmarks. `test/twocore/optimize/phase10_*` and
`test/twocore/optimize/*_bench_test` are fresh names, so no ownership collision.

---

## A. The pipeline wiring — the one reach (N2 / N3 / N4)

`memory_passes/0` in `ir_opt.gleam` is the single registration point (Phase 9 introduced it; the
`pipeline/1` arms already append it, so **`pipeline/1` itself needs no change** — the wire is one
helper edit + two imports). Today it returns the Phase-9 two-pass list:

```gleam
fn memory_passes() -> List(Pass) {
  [mem_forward.forwarding_pass(), mem_dse.dead_store_pass()]
}
```

Extend it to the Phase-10 four-pass list, so `Baseline` runs `baseline ++ [forwarding, dse, licm,
bce]` and `Aggressive` inherits it (still a strict superset):

```gleam
import twocore/middle/ir_opt/bce
import twocore/middle/ir_opt/licm
// (mem_dse, mem_forward already imported by Phase 9)

/// The memory-optimizer pass set, in order. Phase 9 shipped `[forwarding, dse]`; Phase 10 extends it
/// with LICM and range-BCE. `forwarding_pass()`/`dead_store_pass()` are the SAME symbols — unit 03
/// made them cross-control-flow IN PLACE (via `mem_clobber`), so no new pass is registered for the
/// cross-CF relaxation. Ordering is load-bearing (see the module doc). Total.
fn memory_passes() -> List(Pass) {
  [
    mem_forward.forwarding_pass(),
    // Phase-9 store→load forwarding + RLE, now cross-CF (unit 03, in place).
    mem_dse.dead_store_pass(),
    // Phase-9 dead-store elimination, now cross-CF (unit 03, in place).
    licm.licm_pass(),
    // Phase-10 LICM — pure IR→IR; after the memory passes (they expose invariants), before BCE.
    bce.bce_pass(),
    // Phase-10 range-BCE + loop versioning — LAST (it clones loops; idempotence-guarded).
  ]
}
```

- `OptNone -> []` — unchanged, the exact identity, the N6 differential baseline.
- `Baseline -> baseline.baseline_passes() ++ memory_passes()` — Safe gets all three Phase-10 passes.
- `Aggressive -> baseline.baseline_passes() ++ memory_passes() ++ aggressive.aggressive_passes()`.

**The point (N2/N3/N4): Safe gets LICM + cross-CF + BCE.** They live in the `Baseline` arm, which
`profiles.safe()` selects (`opt_level: Baseline`), so the **Safe** sandbox runs them — and because
each is trust-neutral (LICM hoists only pure expressions; cross-CF forwards only under a proven
no-clobber; BCE preserves traps exactly via versioning), running them in Safe does not weaken the
sandbox. And because `ir_opt` runs **upstream of tier + mode selection** (`ir_lower →
ir_opt.optimize(_, binding.opt_level) → emit_core`), the **same** sound rewrite speeds up `paged`,
`atomics`, and `nif`, and both `cell` and `threaded`, with **no** per-tier code — "a sound pass
speeds up every tier and both modes" is realized structurally by *where in the pipeline the passes
sit*, exactly as Phase 9. (BCE's unchecked *lowering* is the one tier-conditioned seam — paged/atomics
get the unchecked entry point, nif falls back to the checked path — but that choice is `emit_core`'s,
by the linked `mem_module`, N5; the pass and its versioning are tier-independent.)

### Order rationale (why forwarding → dse → licm → bce)

- **The Phase-9 memory passes run first — LICM after them.** Forwarding/RLE/DSE (now cross-CF)
  *remove* redundant accesses from the loop body before LICM looks at it. This matters twice: (i) a
  removed load is one fewer effectful/barrier node in the body, so more of what remains is **pure**
  and therefore hoistable; (ii) a store→load *forward* replaces a `MemLoad` with an already-bound
  `Value`, and if that value is loop-invariant, LICM can now hoist the *use*. Running LICM before the
  memory passes would leave those invariants hidden behind accesses that had not yet been eliminated.
- **LICM before BCE — LICM stages BCE's preconditions.** BCE's range guard is a pure expression over
  the loop's `base`, `stride`, trip-bound, offset, and width (§`06`). LICM hoisting the loop-invariant
  **address arithmetic** to the preheader turns `base`/`stride`/`bound` into loop-invariant preheader
  `Let`s in scope — which is exactly the shape `loop_analysis.is_loop_invariant` recognizes and BCE's
  guard reads. LICM does not *enable* BCE (BCE recomputes invariance itself), but it presents the
  invariants as named bindings, making the range check cheaper to synthesize and the versioned loop's
  fast arm already-clean.
- **BCE last — it clones, so clone the optimized body.** BCE emits `if all_in_bounds { fast-loop }
  else { checked-loop }`, duplicating the loop body into the fast arm. Running it **after**
  forwarding/DSE/LICM means the body it clones is already the cleaned, hoisted one, so the fast arm
  inherits every prior win instead of re-deriving it. It is also the only **node-adding** pass, which
  is why it sits at the end (see the fixpoint note).
- **The fixpoint closes it (as Phase 9).** `run_pipeline` re-runs the whole arm to a fixed point:
  after BCE versions a loop, the next sweep re-runs baseline + the memory passes over **both** arms,
  cleaning the fast arm's unchecked body further; forwarding's `Let([y], Values([v]), …)` rebindings
  are folded by baseline copy-prop/dead-`let` on the following round; and inlining-exposed adjacencies
  get another memory sweep. No dedicated post-inline or cleanup pass is registered.

**Acyclicity.** `ir_opt` importing `licm`/`bce` is acyclic: the passes import
`{ir, ir/effect, pass, mem_ssa, loop_analysis, mem_clobber}`; none imports `ir_opt`, and the leaves
(`loop_analysis`, `mem_clobber`) import `{ir, ir/effect, mem_ssa}` only. The DAG stays leaf-below-
passes, identical to Phase 9's layering. Record the reach in [`../state.md`](../state.md).

### The BCE fixpoint / idempotence question (recommend the safe option)

BCE is **node-adding** (it clones the loop). A node-adding pass inside a **size-reducing** fixpoint
is a termination hazard: the naïve failure is that on sweep *k+1* BCE re-versions the checked loop
sitting in the `else`-arm it produced on sweep *k*, nesting `if … { fast } else { if … { fast' }
else { checked'' } }` without bound. Two ways to make it safe:

1. **Guarded, in the arm (RECOMMENDED).** Keep `bce_pass()` last in `memory_passes()` — inside
   `run_pipeline`'s fixpoint — and make it **idempotent** with a structural guard (unit 06 owns it,
   N7): BCE versions a loop **at most once**, skipping any loop that is already the `else`-arm of a
   range-guard `If` it emitted (recognized structurally, e.g. the enclosing `If`'s condition is the
   synthesized `all_in_bounds` binding) *and* any loop whose body already contains an `Unchecked`
   access. With the guard, BCE fires on sweep 1, is a **no-op** on every later sweep, so the fixpoint's
   "did the module change?" check stabilizes and no version guard nests. This keeps the **one
   registration point** (D1) — no special post-fixpoint phase — and is the option this unit wires.
2. **A single trailing pass, outside the fixpoint.** Run the fixpoint over `baseline ++ [forwarding,
   dse, licm]`, then apply `bce_pass()` exactly once. This removes the node-adding pass from the
   size-reducing set entirely (N7's framing) but requires `run_pipeline`/`pipeline` to grow a "final
   single-shot" phase — a heavier structural change than the guard needs.

**Recommendation: option 1.** The per-loop idempotence guard is what actually guarantees
termination (it is what makes BCE "not part of the size-reducing fixpoint set" in practice — its
added nodes are never re-touched), so the trailing-pass phase (option 2) buys nothing the guard does
not already give and costs a pipeline restructure. The capstone's convergence assertion (§B.3)
**re-verifies this over the whole corpus**: `optimize(optimize(m)) == optimize(m)` and `optimize`
terminating are the operational proof that BCE-in-the-fixpoint neither oscillates nor grows without
bound. If unit 06 finds its guard cannot be made structurally airtight, option 2 is the documented
fallback — but the guard is expected to suffice (it is the same "already-transformed ⇒ skip" shape
LICM uses for its once-per-binding hoist).

### Metering note — the deterministic fuel bound is unchanged on every executed path (F5-style, N7)

All three passes are **fuel-neutral**, so they are trust-neutral w.r.t. the `FuelExhausted` trap as
well as the WASM traps. `Charge(cost, body)` is an ordinary `Expr` whose constant `cost` is baked by
`ir_lower` **before** `ir_opt` runs, placed at loop back-edges + function entry (region boundaries,
already barriers); `ir/effect` classifies it effectful and `mem_ssa.is_memory_barrier` treats it as a
barrier. Each pass preserves it:

- **LICM only hoists PURE, non-`Charge` nodes.** `is_loop_invariant` requires `ir/effect.is_pure`,
  and `Charge` is effectful, so LICM never lifts a charge out of a loop — the per-iteration charges
  stay at their back-edge. A hoisted pure expression is not itself a `Charge` and is evaluated in the
  preheader (outside the metered back-edge), so it adds no charged work; the zero-trip case is
  automatic (a pure preheader expr on a zero-trip loop fires no charge, since charges live at the
  back-edge that never executes). The per-iteration fuel ledger is bit-identical.
- **Cross-CF MemorySSA never drops a `Charge`.** `Charge` is a barrier; the memory passes reset their
  knowledge at it and never look through, remove, or re-cost it (exactly Phase 9). `mem_clobber`
  treats a call/grow as a clobber and a `Charge`-bearing region conservatively, so the may-clobber
  relaxation never carries a fact across a charge either. Same charges, same order, same amounts.
- **BCE clones `Charge` into both arms faithfully.** When BCE duplicates the loop body into the fast
  arm, it copies the per-iteration `Charge` nodes **verbatim** — the fast arm and the slow arm carry
  the **same** per-iteration charges. Because the range guard picks **exactly one** arm and only that
  arm executes, the fuel consumed on the executed path is bit-identical to the unversioned loop, so
  the deterministic `FuelExhausted` bound is preserved on every executed path. The guard's own range
  check is a one-time pure preheader computation (uncharged, like LICM's hoisted expr) and adds no
  per-iteration cost, so it cannot flip whether a program exhausts fuel. (Under `Aggressive ⟹
  MeterOff` there are no `Charge` nodes at all — BCE clones a charge-free body, trivially neutral; the
  argument above is the `Baseline`/`MeterFuel` case, which is the one that must hold for Safe.)

Therefore the corpus differential (§B) runs the identical passes under `profiles.safe()` (MeterFuel)
and `profiles.unsafe()` (MeterOff) and gets result-identical, trap-identical, fuel-identical outcomes.

---

## B. The corpus-wide differential — the correctness bar (N6 / N7)

`test/twocore/optimize/phase10_differential_test.gleam`. The bar (N6): for **every** program in the
Phase-1…9 acceptance corpus + spec suite, `optimize(m, OptNone) ≡ optimize(m, Baseline) ≡
optimize(m, Aggressive)` — **byte-identical returned values** (by bit pattern, D5/D7) and
**identical traps** (same reason, same trap-or-not) — run under **every** shipped `(state_strategy ×
mem_tier)` combo (`cell`/`threaded` × `paged`/`atomics`/`nif`) and **both** profiles. This is the
make-or-break: it now exercises LICM + cross-CF forwarding/DSE + BCE (including the **versioned
loops** and **unchecked accesses** on the paged/atomics backends) on real programs, and a single
unsound rewrite — a hoist of an impure expr, a forward across a clobbering branch, a wrong range
proof reading OOB — turns it red on the exact program, on the exact tier.

### B.1 — Reuse the tier-combo machinery; vary the optimizer level on top of it

The tier differential (`test/twocore/tier/combos.gleam`) already holds the corpus fixed and reduces
each run to one normalized `Outcome` (`Value(bits)` / `Trap(reason)` / `InstantiateTrap(reason)` /
`Rejected` / `Instantiated`) with two load-bearing checks — spec-correctness against `.expected`, and
cross-run byte-identity (`identity_across`). This unit **composes** that machinery with the optimizer
axis (the exact shape Phase-9's `memory_differential_test` used), it does not re-implement it:

```gleam
// For every shipped tier combo (cell×paged, threaded×paged, cell×atomics, threaded×atomics,
// cell×nif) and every corpus program, drive OptNone / Baseline / Aggressive over that combo's
// coherent binding, and assert spec-match + cross-level byte-identity.
list.each(combos.shipped, fn(c) {
  let base = combos.binding_for(c)          // coherent, cap-baked, validated (unit-07 surface)
  let none = driver.pipeline_with(Binding(..base, opt_level: ir_opt.OptNone))
  let base_lvl = driver.pipeline_with(Binding(..base, opt_level: ir_opt.Baseline))
  let aggr = driver.pipeline_with(Binding(..base, opt_level: ir_opt.Aggressive))
  // for each corpus program p (combos.corpus_programs):
  //   (a) combos.evaluate(none, p) and combos.evaluate(base_lvl, p) each match .expected
  //   (b) outcomes(none,p) == outcomes(base_lvl,p) == outcomes(aggr,p)   (cross-level byte-identity)
})
```

- **Both checks are needed (D8, no change-detector).** Cross-level identity alone could pass on a
  mutually-broken pair; matching `.expected` alone is just the existing acceptance test. Together they
  are N6: the Phase-10 passes preserved the *spec* answer, and preserved it *identically* at every
  level.
- **`Aggressive` runs under a metered Safe combo on purpose** (the four `metered` combos are
  `MeterFuel`): `Aggressive`'s charge-elision touches only the fuel instrumentation (a policy overlay,
  not a WASM semantic), so eliding it under `MeterFuel` changes fuel accounting but not the WASM
  `Outcome` — which is exactly the invariant under test; the default budget is generous so
  `FuelExhausted` never fires. (`cell×nif` is `Unsafe`/`MeterOff`; spreading the three levels onto it
  varies only `opt_level`.)
- **Why the full tier matrix, not one combo.** Result-neutrality is proven by `OptNone ≡ Baseline`
  under a single combo. Running **all** combos proves the further, necessary thing: the emitted
  **hoisted / versioned / unchecked** code executes correctly through **every** runtime backend —
  that a BCE fast arm's `MemLoadUnchecked` returns the identical bits through `rt_mem` (paged
  immutable-binary slice) and `rt_mem_atomics` (atomics array index), and that `nif` runs the
  **checked-fallback** version to the same result, under both `cell` and `threaded`. That is the
  all-tier half of N6, and it is where the unchecked lowering (units 04/05) is exercised end-to-end on
  real programs for the first time.

### B.2 — Spec-suite half

The corpus gives fine-grained bit-identity on authored programs; the **whole spec suite** gives
breadth. Drive `conformance_test.gleam` (or the pinned allowlist here) at `fail == 0 && pass > 0`
under `driver.pipeline_with(profiles.safe())` (Baseline — LICM + cross-CF + BCE on) and
`driver.pipeline_with(profiles.unsafe())` (Aggressive). Phase 10 is **conformance-neutral**: the new
IR nodes are produced only by BCE, never by the WASM frontend, so a module the passes do not rewrite
emits byte-identical code and the pass/fail counts do not move — the proof is that the *same* green
holds with the three passes engaged, and that any spec program containing an affine loop BCE *does*
version stays result-identical (including its OOB-trap assertions — versioning preserves the trap at
the same point). The suite budget is generous enough that no in-scope program trips `FuelExhausted`.

### B.3 — Convergence, idempotence, and the `count_mem_ops` sanity reframe (N7)

Phase 9 asserted, corpus-wide, that `count_mem_ops(optimize(m, Baseline)) <= count_mem_ops(m)` — the
memory passes never *add* a memory op. **That global monotonicity no longer holds once BCE is
wired**, and the capstone must state this plainly rather than paper over it: BCE **clones** the loop
body, so a versioned loop contributes the fast arm's `MemLoadUnchecked`/`MemStoreUnchecked` (counted
as memory ops by `count_mem_ops`, keystone §C) **plus** the slow arm's original checked accesses —
`count_mem_ops` can **increase** on a program BCE versions. LICM (moves pure non-memory nodes) and
cross-CF (only *removes* accesses) do not add memory ops; BCE does. So the Phase-10 sanity is:

- **The invariants that hold universally are convergence + idempotence, not monotonicity.** Assert,
  over the whole corpus, that `optimize` **terminates** (reaching the assertion is the proof — it is
  total) and that the fixpoint is **stable**: `optimize(optimize(m, Baseline), Baseline) ==
  optimize(m, Baseline)`. This is the operational re-verification of N7 now that a node-adding pass
  sits in the arm — no oscillation, no unbounded growth (BCE's guard fires once per loop), no panic.
- **`count_mem_ops` monotonicity is asserted only where it still holds.** Keep the `<=` check on the
  subset that adds no memory op — e.g. on a fixture exercising only forwarding/DSE/LICM, or by driving
  `baseline ++ [forwarding, dse, licm]` (BCE excluded) and asserting `count_mem_ops <= count_mem_ops(m)`
  there. On the full `Baseline` list the corpus-wide check is the **convergence + idempotence** pair
  above, and BCE's firing is proven by its **own** deterministic metric (the unchecked-access count,
  §C.2), not by a `count_mem_ops` decrease.
- **Reconcile the Phase-9 assertion.** Wiring BCE into `Baseline` could break the Phase-9
  `memory_differential_test.gleam` monotonicity assert **iff** a Phase-1…9 corpus program has an
  affine loop BCE versions. The capstone must check this: the acceptance corpus (`add`, `intops`,
  `sum_to`, `fib`, `fac`, `floatops`, `hostimport`, `mem`, `callind`, `gvar`, `memgrow`, `trunc`,
  `trapstart`, `oobdata`) is unlikely to contain a BCE-eligible affine *memory* loop (`sum_to`/`fib`
  are arithmetic; the memory programs are straight-line), so the Phase-9 `<=` is expected to stay
  green empirically — **but the capstone must run the Phase-9 suite after the wire and confirm it**,
  and if any program does version, the Phase-9 assertion is reconciled (a documented cross-file touch,
  recorded in `state.md`) to the convergence/idempotence form above. Do not assume; verify.

---

## C. The benchmarks — the headline, MEASURED not asserted (N8)

Two kernels, each isolating **one** pass's delta by building two `.beam`s that differ in **exactly**
that pass — the `mem_bench_test` recipe (`test/twocore/optimize/mem_bench_test.gleam`): construct the
lowered module once, run `pass.run_pipeline` two ways (baseline-only vs baseline + the added pass),
`emit_core` → `core_to_beam` under the **same** binding, **correctness-gate identical** before timing,
then time with `pipeline.exec_beam` (invocations only). Each benchmark reports **two** numbers: a
deterministic, clock-independent proof the pass fired, and a wall-clock speedup.

### C.1 — LICM: an invariant-heavy loop (`licm_bench_test.gleam`)

**The kernel** — a loop whose body recomputes, each iteration, a **costly loop-invariant** pure
expression (a chain of arithmetic over loop-external names only), then does a little per-iteration
work with it:

```
licm_bench(n, base):
  loop (i=0, acc=0):
    if i >= n: return acc
    inv = <a long PURE arithmetic chain over `base` + constants — free vars all loop-external>
    acc = acc + inv + i          // the only per-iteration-varying work
    continue(i+1, acc)
```

`inv` is `ir/effect.is_pure` and `free_vars(inv)` is disjoint from the loop-bound names (`i`/`acc`),
so `licm_pass()` hoists it to a preheader `Let` evaluated **once**, not `n` times. Build two beams
that differ only in `licm_pass()` appended.

- **Deterministic firing metric (the spine).** Count the invariant `Let` bindings inside the `Loop`
  body before vs after `licm_pass()` — the hoist drops the loop-body invariant-node count to zero (or
  by the exact expected number). Assert `hoisted > 0` and equals the fixture's exact count. This is
  machine-independent — the report's clock-independent spine.
- **Wall-clock.** `exec_beam` both builds over `iters` iterations, `repeat` times; correctness-gate
  `licm_bench(500, base)` identical on both first; assert the LICM build is strictly faster. The win
  scales with (invariant work) / (total per-iteration work) — the kernel makes the invariant chain
  costly and the rest small so the delta is unambiguous, and the report says so (LICM's win is
  proportional to how much invariant work the loop repeats — an invariant-light loop gains little).

### C.2 — BCE: an affine-access loop on the `atomics` tier (`bce_bench_test.gleam`)

**The kernel** — a loop summing an affine memory access over a loop-invariant `base`/`n`, no
`grow`/call in the body, over **pre-seeded** memory (a data segment so each read is in-bounds and
deterministic):

```
bce_bench(n):
  loop (i=0, acc=0):
    if i >= n: return acc
    v = load(base + 4·i)         // affine, checked → MemLoadUnchecked in the versioned fast arm
    acc = acc + v
    continue(i+1, acc)
```

`bce_pass()` recognizes the affine shape and emits `if all_in_bounds { fast-loop-with-unchecked }
else { checked-loop }`. Build two beams that differ only in `bce_pass()` appended, on the **`atomics`**
tier (where a load is O(1) and the per-iteration bounds compare-and-branch is a real fraction of the
cost — the atomics-favoured measurement).

- **Deterministic firing metric (the spine).** Count `MemLoadUnchecked` nodes in the optimized IR's
  fast arm (equivalently, the per-iteration checks removed). Assert `unchecked > 0` and equals the
  fixture's exact count — the versioned loop's fast arm demonstrably uses unchecked accesses. This is
  machine-independent.
- **Wall-clock, `atomics` only, honest.** Correctness-gate `bce_bench(n)` identical on both builds
  first (the range guard passes ⇒ the fast arm runs ⇒ the unchecked path is what is timed), then time.
  The win is **modest and atomics-favoured** — the report states this plainly: on `atomics` BCE
  removes a per-iteration compare-and-branch off an O(1) access, a measurable but not multi-fold cut;
  on `paged` the BCE win is **small** because a paged load is already near-O(1) (a `dict.get` + a
  sub-binary slice, no rebuild) so the bounds branch is a smaller fraction, and BCE does **nothing**
  for paged *stores* — the O(page) store-rebuild was **DSE's** Phase-9 headline, not BCE's. Hence the
  BCE headline is measured on atomics, and the report says why.

### C.3 — The report (`docs/phase-10-benchmark.md`) must be HONEST

Structure mirrors `docs/phase-9-benchmark.md` + `docs/phase-4-benchmark.md`. It MUST carry:

- **The correctness backdrop** — the full differential clears first (`OptNone ≡ Baseline ≡
  Aggressive`, corpus + spec suite, every `(state_strategy × mem_tier)` combo, both profiles,
  `fail = 0`); a fast wrong number is not a number.
- **Methodology** — the two kernels, that each isolates one pass by building two beams differing only
  in that pass, the correctness gate FIRST, warmup + `N` repeats, that `exec_beam` times invocations
  only, and the machine/OTP/Gleam versions + the `atomics` `--cap`.
- **LICM: the hoist-count + the speedup** — the deterministic hoist count (machine-independent), then
  the wall-clock OptNone-of-LICM vs +LICM ns/iteration + ratio on the invariant-heavy loop.
- **BCE: the check-removal count + the atomics speedup** — the deterministic unchecked-access count,
  then the wall-clock baseline vs +BCE ns/iteration + ratio on `atomics`; the honest note that the
  paged BCE win is small (rebuild/near-O(1) load dominates) and that DSE/paged was Phase-9's headline.
- **The ceiling (honest, measured, pattern-dependent — N8).** State plainly what wins and what does
  not: **LICM** wins in proportion to repeated loop-invariant work (an invariant-light loop gains
  little); **BCE** wins on **single-monotone-induction-variable, affine-access** loops with
  loop-invariant `base`/`stride`/bound and **no `grow`/call**, largest on `atomics`, small on `paged`,
  and a **checked-fallback no-op on `nif`** (Safe forbids nif; an unchecked native access could
  corrupt the node). Nested induction, non-affine/dynamic addressing, and loops that grow/call remain
  **checked** (sound, not accelerated). **Deferred, stated not dropped** (overview §6): escape analysis
  for the term/object value path, a general (polyhedral) range solver, nested/multi-dimensional BCE,
  and the tier-N unchecked native path. **No hero number** — the report reports whatever the
  measurement says, with the ceiling beside it.

---

## Effect / soundness / security note

- **The passes cannot be unsound and pass.** An unsound rewrite — a cross-CF forward across a branch
  that clobbers `F` (a wrong `may_clobber == False`), a LICM hoist of an impure/trapping expression, a
  BCE range proof that lets the fast arm read OOB — changes a corpus `Outcome` (a value, a trap, or a
  trap *point*), and the differential (§B) goes red on the exact program, on the exact tier. Units
  02/03/06's adversarial "must-NOT" fixtures catch it earlier; this whole-corpus, all-tier differential
  is the backstop. "Green" means *every observable was preserved on every runtime backend under both
  modes*, not "it compiled."
- **Trap-preservation is absolute, including trap timing and the fuel trap.** Cross-CF forwards rest
  on a proven no-clobber (no trap moves); LICM hoists only pure expressions (no trap to move — the
  zero-trip case is automatic); BCE **versions** rather than hoist-and-trap-early, so an OOB access
  traps `MemoryOutOfBounds` at the **same iteration** with the same prior effects (the checked slow arm
  runs whenever the range guard fails). The metering note (§A) shows `FuelExhausted` is bit-identical
  on every executed path (charges preserved; BCE clones them into both arms, only one arm runs). This
  is why all three are Safe-legal.
- **The one runtime-touching seam is guarded and BEAM-safe.** The only new authority Phase 10 adds is
  BCE's unchecked access, and it is emitted **only** inside a fast arm the runtime range-guard proved
  in-bounds; even on an (impossible-by-guard) OOB the unchecked path is BEAM-memory-safe (paged slices
  an immutable binary → a caught error/trap; atomics indexes an `atomics` array → a caught error),
  never corruption. `nif` gets the checked fallback. The only cross-file reach this unit makes is the
  one documented `memory_passes` edit.

---

## Verification — Definition of Done (D8)

- **The wire (proof 1).** `memory_passes()` returns `[forwarding_pass(), dead_store_pass(),
  licm_pass(), bce_pass()]`; `Baseline -> baseline ++ memory_passes()` and `Aggressive -> baseline ++
  memory_passes() ++ aggressive`; `OptNone` stays `[]`. `Aggressive` is a strict superset of
  `Baseline`. The reach is recorded in `state.md`.
- **The differential (proof 2) — green corpus-wide, all tiers, both modes.** For every corpus
  program, `OptNone ≡ Baseline ≡ Aggressive` byte-identically (values by bit pattern, traps by
  reason) under **every** shipped `(state_strategy × mem_tier)` combo, and each level equals the
  spec-sourced `.expected`. The spec suite is `fail == 0 && pass > 0` under `profiles.safe()` and
  `profiles.unsafe()`; counts unchanged (conformance-neutral). The fixpoint **converges** and is
  **idempotent** (`optimize(optimize(m)) == optimize(m)`) with no non-termination, no panic, no
  unbounded growth (N7); the `count_mem_ops` sanity is asserted in its Phase-10 form (§B.3), and the
  Phase-9 monotonicity suite is re-run and confirmed/reconciled. **The WASM corpus is
  RESULT-identical** — the emitted code legitimately differs (hoisted work, versioned loops, unchecked
  accesses), so the bar is result-identical (like Phase 9), **not** byte-identical emission.
- **The benchmarks (proof 3) — the passes FIRE and are faster.** LICM: the deterministic hoist count
  is `> 0` and equals the fixture's exact value, and the +LICM build is measurably faster on the
  invariant-heavy loop (correctness-gated identical first). BCE: the deterministic unchecked-access
  count is `> 0` and equals the fixture's exact value, and the +BCE build is measurably faster on the
  `atomics` affine-access loop (correctness-gated identical first). `docs/phase-10-benchmark.md` is
  committed with the counts, the two wall-clock deltas, the atomics-favoured/paged-small BCE reading,
  and the honest ceiling — **no hero number**.
- **Green build.** `gleam format --check src test` clean; `gleam build` **zero warnings** (no
  `todo`/`panic`/`let assert` on any non-impossible path); `gleam test` ≥ 1783 + the new tests, 0
  failures. **Done = the suites pass and the report is committed with measured, correctness-gated
  numbers** — never "it compiled," never "the script ran."

---

## Phase 10 proven

The linear-memory optimizer is complete: **LICM** hoists the loop-invariant work to a preheader,
**cross-control-flow MemorySSA** carries store→load forwarding / RLE / DSE across an `If`/`Block`/
`Switch` under a proven no-clobber, and **range-based BCE** removes the per-iteration bounds check on
provably-in-bounds affine loops via **loop versioning** (a runtime range-guard picks the
unchecked fast loop only when it has proven the whole range in-bounds, else the original checked
loop) — all three wired into the **Baseline** pipeline, so **Safe** and every tier and both modes get
them, with **no** observable change on the whole Phase-1…9 corpus + spec suite, proven differentially
across every `(state_strategy × mem_tier)` combo under both profiles. The win is **measured**: a
deterministic hoist count + wall-clock speedup for LICM on an invariant-heavy loop, and a
deterministic unchecked-access count + an `atomics` wall-clock speedup for BCE on an affine-access
loop, with the pattern-dependent ceiling written down — no hero number.

**Deferred to a later phase (stated, not dropped — [`00-overview.md`](00-overview.md) §6):** escape
analysis for the term/object value path (object speed, not linear memory — gated on an object-heavy
frontend); a general (polyhedral) range solver + nested/multi-dimensional BCE (Phase-10 recognizes the
single-monotone-IV, single-affine-access loop shape); and the tier-N unchecked native path (the `nif`
memory tier stays checked, Safe-forbidden, and its C backend a documented Phase-4 skeleton).
