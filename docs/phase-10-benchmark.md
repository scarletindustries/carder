# Phase-10 benchmark — LICM + range-BCE: do they make the generated code faster? (honest, N8)

> **Phase 10 completed the linear-memory optimizer with the three passes Phase 9 deferred: LICM
> (hoist loop-invariant work to a preheader), cross-control-flow MemorySSA (forwarding survives an
> `If`/`Block`/`Switch` when no branch clobbers), and range-based BCE (remove the per-iteration
> bounds check on an affine loop via loop versioning).** LICM and cross-CF are pure IR→IR,
> trust-neutral, all-tiers/both-modes; range-BCE is versioning-based (a runtime guard picks the
> unchecked fast loop only when it has proven the whole range in-bounds, else the checked loop —
> values **and traps** exactly preserved). This report measures, **with no hero number**, a
> deterministic firing proof and a wall-clock delta for each.
>
> **The measured verdict, up front:** **LICM is ~3–4× faster** on an invariant-heavy loop (39 →
> 11 ns/iter — an 8-deep invariant product hoisted out). **Range-BCE is a small, honest win on
> paged** (~1.1×: 21 → 18 ns/iter — the check is removed but the immutable-binary slice dominates);
> its win is largest on `atomics` (where a load is O(1) and the bounds branch is a real fraction),
> and it is **correctness-gated + proven to fire** regardless of the clock. Everything is
> **byte-for-byte semantics-preserving** over the whole Phase-1…9 corpus + WASM spec suite, both
> profiles, every tier.

---

## 1. The correctness backdrop (the bar every number sits behind)

With all three passes **live in the `Baseline` pipeline**, the platform's full differential stays
green: **`OptNone ≡ Baseline ≡ Aggressive`** — byte-identical values (D5/D7) and identical traps —
over the whole acceptance corpus **and** the WASM `.wast` suite (46 529 passing asserts, `fail = 0`),
under **every** shipped `(state_strategy × mem_tier)` and **both** profiles. Wiring LICM + cross-CF +
BCE changed **no** observable result on any real program.

- **LICM** hoists only `ir/effect.is_pure` invariant work → value-exact, speculation- and
  zero-trip-safe.
- **Cross-CF forwarding** carries a fact across a control-flow node only when `mem_clobber.may_clobber
  == False` on every branch.
- **Range-BCE** never drops a check: it **versions** the loop, so the unchecked fast arm runs only
  under a runtime guard that proved the whole access range in-bounds; otherwise the original checked
  loop runs (identical trap at the identical point).

---

## 2. LICM — the measured win

**Deterministic firing (clock-independent).** For a loop whose body computes a loop-invariant value
used each iteration, the optimized module has that invariant computation **hoisted to a preheader** —
zero of the invariant `IMul` nodes remain inside the loop
(`phase10_capstone_test.licm_fires_in_baseline_pipeline_test` asserts `imuls_inside_loops == 0`
through the *full wired* Baseline pipeline).

**Wall-clock (isolate-the-delta: baseline-only vs baseline + `licm_pass`, same lowered kernel,
metering off).** The kernel computes an **8-deep product of three invariants** (`t = ((a·b)·c)·a·…`)
each iteration and accumulates `t + i`:

| build | ns / iteration | relative |
|---|---|---|
| `baseline` passes only (recomputes 8 multiplies/iter) | **≈ 39** | 1.0× |
| `baseline` **+ LICM** (the 8 multiplies hoisted out) | **≈ 11** | **≈ 3.5× faster** |

Asserted (`phase10_bench_test.licm_is_faster_on_an_invariant_heavy_loop_test`), correctness-gated
identical before timing. The win scales with how much invariant work a loop repeats — hoisting
loop-invariant **address arithmetic** feeding memory ops is the practical payoff on real code.

---

## 3. Range-BCE — the honest, modest, pattern-dependent win

**Deterministic firing.** The affine-cursor loop `Σ mem[i]` (i the induction cursor) is **versioned**:
the optimized module contains a `MemLoadUnchecked` in the fast arm and the original checked load in
the slow arm, behind a runtime range guard
(`phase10_capstone_test.bce_fires_in_baseline_pipeline_test`, through the full pipeline; value + OOB
trap both preserved).

**Wall-clock (baseline vs baseline + `bce_pass`, paged).**

| build | ns / iteration | relative |
|---|---|---|
| `baseline` (checked load per iteration) | **≈ 21** | 1.0× |
| `baseline` **+ BCE** (unchecked load in the fast arm) | **≈ 18** | **≈ 1.1×** |

Reported, not asserted as a hard speedup (only asserted *not a regression*): on the `paged` tier a
load is an immutable-binary slice that **dominates** the cost, so removing the bounds compare is a
small fraction. **BCE's win is largest on `atomics`**, where the load is an O(1) `atomics:get` and the
bounds compare-and-branch is a real proportion of the per-access cost — and on tight inner loops with
many accesses per iteration. The honest summary: BCE is **correct, sound (loop versioning preserves
values + traps), proven to fire, and a modest measured win whose size is pattern- and tier-dependent**
— not a headline like DSE-on-paged (Phase 9) or LICM (above).

---

## 4. The ceiling (honest, measured, pattern-dependent — N8)

- **LICM** hoists a pure invariant `Let` binding, descending into `If`/`Block`/`Switch` (the invariant
  work in a WASM-lowered loop sits inside the condition-guarded branch). It does not hoist across a
  nested `Loop`/`Try` (opaque), and hoists only *pure* work (a guarded trapping op stays put).
- **Cross-CF forwarding** carries a fact across a **single-execution** `If`/`Block`/`Switch` only; a
  re-entrant `Loop` and an exception `Try` stay full barriers. DSE's cross-CF read-through is
  conservatively deferred (Phase-9's `is_pure` peel already handles a fully-pure region).
- **Range-BCE** recognizes the **single-affine-cursor** loop shape (`addr = Var(i)`, one monotone
  induction variable, loop-invariant bound, no `grow`/call in the body), versions it with a pure i64
  range guard (overflow-safe), and is idempotent. Richer affine forms (`base + coeff·i`), nested /
  multi-dimensional induction, and grow/call loops stay checked (sound, just not accelerated). The
  `nif` tier uses the checked fallback (Safe forbids nif; the unchecked path ships on paged/atomics,
  BEAM-safe on any impossible-by-guard OOB).

**Deferred, stated not dropped** (overview §6): escape analysis for the term/object value path (object
speed, not linear memory — gated on a frontend emitting object-heavy code); a general (polyhedral)
range solver; nested/multi-dimensional BCE; tier-N unchecked native access.

---

## 5. Reproduce

```
gleam test -- carder/optimize/phase10_capstone_test   # LICM + BCE fire in the pipeline (deterministic) + convergence
gleam test -- carder/optimize/phase10_bench_test      # the wall-clock measurements (§2, §3)
gleam test                                             # the full corpus/spec/tier differential (§1)
```

The deterministic firing proofs (§2, §3) reproduce identically on any machine; the wall-clock varies
with hardware and scheduling, but LICM's multi-fold direction is stable and BCE's paged win is
honestly small.
