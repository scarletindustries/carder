# Phase 9 · Unit 04 — Capstone: wire the memory passes, prove conformance-neutrality, measure the win

> **One owner · Wave C (last) · depends on the freeze AND the landed work of 01/02/03.** Read
> [`00-overview.md`](00-overview.md) (M1–M8), the design note
> [`../future-work-memory-optimizer.md`](../future-work-memory-optimizer.md) (esp. invariant #4 —
> the win is real but pattern-dependent and **measured, not asserted**), then the keystone
> [`01-mem-ssa-keystone.md`](01-mem-ssa-keystone.md) (`count_mem_ops/1`, the μ₉ measure) and the two
> sibling passes [`02-store-load-forward.md`](02-store-load-forward.md) /
> [`03-dead-store-elim.md`](03-dead-store-elim.md). This is the terminal proof-of-goal unit: it
> **wires** the memory passes into the pipeline (the one cross-file reach), proves the whole
> Phase-1…8 corpus stays **result-identical** on every tier under both modes, and **measures** the
> speedup with honest numbers. It is the only Phase-9 unit that edits `ir_opt.pipeline/1`; it emits
> nothing others build on. Baseline entering Phase 9: **1734 tests, 0 failures, 0 warnings.**

---

## Context

Phase 9 makes one claim only a capstone can prove: **the memory optimizer removes redundant
linear-memory traffic without changing a single observable result or trap, and it makes real
programs faster.** Both halves are *differential* claims — hold the program fixed, vary the
optimizer level (and the tier, and the mode), assert equivalence and measure the delta — so the
terminal unit owns the whole-corpus wiring, exactly as Phase-3's capstone owned the
`OptNone ≡ Baseline ≡ Aggressive` differential and Phase-4's revisit owned the honest benchmark.

Until this unit, units 01/02/03 land **green with the pipeline still empty** (the keystone ships the
analysis; the two pass units ship the passes + isolated fixtures — but **none** touches
`ir_opt.pipeline`, so `optimize` is still the identity for the memory layer and the corpus is
byte-identical). This unit is where the passes go live. Wiring them is what makes the corpus
differential and the benchmark **meaningful**: before the wire, `OptNone ≡ Baseline` was trivially
true for memory (both ran no memory passes); after the wire it is the load-bearing correctness gate
that a single unsound `alias`/barrier misjudgement (silent memory corruption) would turn red.

"Done" for the phase is three things, all owned here:

| # | Proof | Decision |
|---|---|---|
| 1 | **the memory passes are wired** — `Baseline` runs them (inherited by `Aggressive`), `OptNone` stays empty; `Aggressive` stays a strict superset | M2/M4 |
| 2 | **conformance-neutral, all-tier, both-mode** — the Phase-1…8 corpus + spec suite are **result-identical** (values byte-identical by bit pattern, traps identical) across `OptNone`/`Baseline`/`Aggressive`, under **every** shipped `(state_strategy × mem_tier)` combo and **both** profiles; `count_mem_ops` is monotone non-increasing and the fixpoint converges | M6/M7 |
| 3 | **measured speedup** — a committed benchmark shows the passes **fire** (a deterministic count of eliminated `MemLoad`/`MemStore` nodes, clock-independent) **and** run **measurably faster** wall-clock on a memory-traffic-heavy kernel, with the tier breakdown (DSE's paged advantage) and the honest ceiling written into `docs/phase-9-benchmark.md` | M8 |

Phase 9 legitimately changes the *emitted* code (fewer accesses), so — unlike Phase 8's
emission-byte-identical differential — the bar is **result**-identical, exactly like the Phase-3
optimizer differential. The benchmark is **measured**, never asserted: no hero number, the ceiling
stated.

---

## Deliverables & freeze milestones

**Consumes** (every Phase-9 freeze + the landed passes):

- `«MEM-SSA-FROZEN»` (unit 01) — `mem_ssa.count_mem_ops/1` (the deterministic static metric + the
  μ₉ convergence/monotonicity assertion), and, transitively through the passes, the whole analysis
  surface (`Footprint`/`AliasResult`/`alias`/`is_memory_barrier`/`Avail`/`byte_width`).
- `mem_forward` (unit 02) — the **one** unified pass `forwarding_pass()` (`pass.Pass` value),
  realizing both store→load forwarding AND redundant-load elimination, tested green in isolation.
- `mem_dse` (unit 03) — the pass `dead_store_pass()` (`pass.Pass` value), tested green in isolation.
- The landed pipeline surface: `ir_opt.optimize/2`, `ir_opt.OptLevel`, `pass.run_pipeline`,
  `baseline.baseline_passes()`, `aggressive.aggressive_passes()`; the run/bench ABI
  (`pipeline.optimize_ir`/`ir_to_core`/`run_source`/`exec_beam`, `src/twocore.gleam`'s verbs);
  the tier-combo differential machinery (`test/twocore/tier/combos.gleam` — `binding_for/1`,
  `shipped`, `evaluate/2`, `identity_across/2`, `Outcome`, `corpus_programs`, `cap_pages`).

> **Frozen-name reconciliation (settled).** Store→load forwarding and redundant-load elimination are
> the **same** transfer function over one `avail` map, so unit 02 ships them as **one** pass
> `mem_forward.forwarding_pass()` (not two); unit 03 ships `mem_dse.dead_store_pass()`. The overview
> §4 file-ownership table + capstone-reach text and units 02/03 were reconciled to these two names;
> this spec uses them. `memory_passes` is therefore the **two**-pass list
> `[mem_forward.forwarding_pass(), mem_dse.dead_store_pass()]`.

**Produces** (terminal — nothing downstream depends on it): the one pipeline edit, the corpus-wide
memory differential, the benchmark harness + fixture, and the committed honest report. No
publish-day-1 stub, no freeze milestone.

---

## Files owned (D1)

| File | Role |
|---|---|
| `src/twocore/middle/ir_opt.gleam` (**edit `pipeline/1`** — the ONE reach) | insert the three memory passes between baseline and aggressive |
| `test/twocore/optimize/memory_differential_test.gleam` (**NEW**) | the corpus-wide `OptNone ≡ Baseline ≡ Aggressive` differential across every tier + both modes, plus the μ₉ monotonicity/convergence assertion |
| `smoke/mem_bench.sh` (**NEW**) | the benchmark harness (static-count report + wall-clock ns/call, per-tier) |
| `smoke/mem/memkern.wat` (+ committed `memkern.wasm`) (**NEW**) | the memory-traffic-heavy fixture kernel |
| `smoke/mem_bench_harness.gleam` (**NEW, fallback**) | tiny Gleam driver that emits the OptNone/Baseline `.beam`s directly if the CLI `-O0` flag (below) does not land |
| `docs/phase-9-benchmark.md` (**NEW**) | the committed honest report (methodology, static counts, wall-clock + tier breakdown, the ceiling) |

The **per-pass** fixtures (the "must forward" / "must-NOT forward" / "must-DSE" / adversarial
"must-NOT" cases) belong to units 02/03 under `test/twocore/optimize/mem_forward_test.gleam` and
`mem_dse_test.gleam`; this unit owns only the **whole-corpus** differential and the benchmark.
`test/twocore/optimize/**` and `smoke/mem/**` are fresh, so no ownership collision.

---

## A. The pipeline wiring — the one reach (M2 / M4)

`ir_opt.pipeline/1` is the single registration point (exactly as Phase-3 units 03/04 edited it).
Today it returns:

```gleam
fn pipeline(level: OptLevel) -> List(Pass) {
  case level {
    OptNone -> []
    Baseline -> baseline.baseline_passes()
    Aggressive ->
      list.append(baseline.baseline_passes(), aggressive.aggressive_passes())
  }
}
```

Insert the memory passes **between** baseline and aggressive so `Aggressive` stays a **strict
superset** of `Baseline` (keystone A.2):

```gleam
import twocore/middle/ir_opt/mem_dse
import twocore/middle/ir_opt/mem_forward

fn pipeline(level: OptLevel) -> List(Pass) {
  let memory_passes = [
    mem_forward.forwarding_pass(),
    mem_dse.dead_store_pass(),
  ]
  case level {
    OptNone -> []
    Baseline -> list.append(baseline.baseline_passes(), memory_passes)
    Aggressive ->
      list.append(
        list.append(baseline.baseline_passes(), memory_passes),
        aggressive.aggressive_passes(),
      )
  }
}
```

- `Baseline -> baseline.baseline_passes() ++ memory_passes`
- `Aggressive -> baseline.baseline_passes() ++ memory_passes ++ aggressive.aggressive_passes()`
- `OptNone -> []` (unchanged — the exact identity, the M6 differential baseline).

**The point (M2): Safe now gets the memory passes.** They live in the `Baseline` arm, which
`profiles.safe()` selects (`opt_level: Baseline`), so the **Safe** sandbox runs them — and because
they are trust-neutral (M3: every rewrite preserves the exact observable trap behaviour), running
them in Safe does not weaken the sandbox. `Aggressive` (= baseline ++ memory ++ aggressive) inherits
them for free. And because `ir_opt` runs **upstream of tier + mode selection**
(`ir_lower → ir_opt.optimize(_, binding.opt_level) → emit_core`, F1/F7), the **same** sound rewrite
speeds up `paged`, `atomics`, and `nif`, and both `cell` and `threaded`, with **no** per-tier code
(M4 — no runtime touch). "A sound pass speeds up every tier and both modes" is realized structurally
by *where in the pipeline the passes sit*, not by N copies.

### Order rationale (why baseline-then-memory-then-aggressive, and why the fixpoint closes it)

- **Memory passes run AFTER the baseline set.** const-fold and copy/const-prop have, by the time the
  memory passes see the module, already **propagated the base operands and folded constant
  addresses** — so two accesses that were written through separate `local.get`-derived copies now
  present the **same base `Value`** (a single `Var` name, or an equal `ConstI32`). The alias oracle
  disambiguates by **syntactic** equality (M5, keystone §B), so this pre-normalisation is exactly
  what turns a real WASM `local.get`-based access pair into a `MustAlias`/`NoAlias` pair the passes
  can act on. Running the memory passes *before* copy-prop would leave most bases un-unified →
  `MayAlias` → the passes would (soundly) do nothing. This ordering is load-bearing for the
  benchmark firing at all, and the static-count fixture (§C.1) is the tripwire that proves it did.
- **Memory passes run BEFORE aggressive inlining.** Inlining enlarges function bodies and can expose
  *new* straight-line adjacencies (a caller's store now sits in the same region as a callee's load).
  The `run_pipeline` fixpoint **re-runs the whole arm** over the enlarged bodies, so the memory
  passes get **another pass after inlining** and pick up the newly-exposed redundancy — no separate
  post-inline memory pass is registered.
- **Baseline cleans up after forwarding, for free.** Forwarding/RLE replace a `MemLoad` with
  `Values([v])`, which the transfer function surfaces as a small `Let([y], Values([v]), …)`
  rebinding; copy-prop + dead-`let` in the next fixpoint round fold those away. Because the fixpoint
  re-runs baseline over the memory passes' output, no dedicated cleanup pass is needed — the same
  free-cleanup property Phase 3 relied on for inlining.

**Acyclicity.** `ir_opt.gleam` importing `mem_forward`/`mem_dse` is acyclic: the passes import
`{ir, ir/effect, pass, mem_ssa}`; none imports `ir_opt`, and `mem_ssa` imports `ir` + `ir/effect`
only. The import DAG stays `pass → ir`; `mem_ssa → {ir, ir/effect}`; `{mem_forward, mem_dse} →
{ir, ir/effect, pass, mem_ssa}`; `ir_opt → {ir, list, pass, baseline, aggressive, mem_forward,
mem_dse}` — a leaf-below-passes layering identical to Phase 3's. Document the reach in
[`specs/state.md`](../state.md).

### Metering note — the deterministic fuel bound is unchanged on every executed path (F5-style)

The passes are **fuel-neutral**, and this is why they are trust-neutral even w.r.t. the *fuel* trap,
not only the WASM traps:

- **The passes never construct, remove, or re-cost a `Charge` node.** `Charge(cost: Int, body)` is
  an ordinary `Expr` variant whose `cost` is a constant **baked upstream by `ir_lower`** (before
  `ir_opt` runs). `ir/effect.is_effectful_node` already classifies `Charge` as effectful, so the
  keystone's `is_memory_barrier` (built on it, and fail-closed to *barrier* for anything not proven
  transparent — M5) treats `Charge` as a **barrier**: the memory passes reset their memory knowledge
  at a `Charge` and never look through it, remove it, or touch its baked `cost`. `ir_lower` places
  charges at loop back-edges and function entry (region boundaries — already barriers), not around
  individual accesses, so this does not fragment the straight-line bodies where the passes work.
- **Therefore fuel is charged identically.** On every executed path, the same `Charge` nodes fire in
  the same order for the same baked amounts, whether or not a redundant access below them was
  removed — so the **deterministic `FuelExhausted` bound is bit-identical** between `OptNone` and
  `Baseline`. A removed redundant access simply **isn't work the program needed to do** (its result
  was already in hand for forwarding/RLE, or its write was dead for DSE), and — crucially — it was
  **never separately charged**, so removing it cannot let a program that would have exhausted fuel
  now complete, nor vice-versa. The memory speedup is in the emitted BEAM's reductions (a dropped
  handle-fetch + bounds-check + decode), **not** in the fuel ledger.
- **The passes run identically under MeterFuel and MeterOff.** They read no `binding` field and do
  not branch on the mode; under `MeterOff` the module simply has no `Charge` nodes at all, under
  `MeterFuel` the charges sit at boundaries the passes already treat as barriers, so the **same**
  memory ops are eliminated on the **same** straight-line bodies either way. This is what lets the
  corpus differential (§B) run the identical passes under `profiles.safe()` (MeterFuel) and
  `profiles.unsafe()` (MeterOff) and get result-identical, trap-identical outcomes.

---

## B. The corpus-wide differential — the correctness bar (M6 / M7)

`test/twocore/optimize/memory_differential_test.gleam`. The bar (M6): for **every** program in the
Phase-1…8 acceptance corpus + spec suite, `optimize(m, OptNone) ≡ optimize(m, Baseline) ≡
optimize(m, Aggressive)` — **byte-identical returned values** (by bit pattern, D5/D7) and
**identical traps** (same reason, same trap-or-not) — run under **every** shipped
`(state_strategy × mem_tier)` combo (`cell`/`threaded` × `paged`/`atomics`/`nif`) and **both**
profiles. This proves the memory passes changed no observable result on real programs, on every tier
the design note promised to speed up.

### B.1 — Reuse the tier-combo machinery; vary the optimizer level on top of it

The tier differential (`test/twocore/tier/combos.gleam`) already holds the corpus fixed and varies
the `Binding` over the shipped `(state_strategy × mem_tier × table_tier)` matrix, reducing each run
to one normalized `Outcome` per program point (`Value(bits)` / `Trap(reason)` /
`InstantiateTrap(reason)` / `Rejected` / `Instantiated`) with two load-bearing checks:
**spec-correctness** against the spec-sourced `.expected`, and **cross-run byte-identity**
(`identity_across`). This unit **composes** that machinery with the optimizer axis — it does not
re-implement it:

```gleam
// For every shipped tier combo (cell×paged, threaded×paged, cell×atomics, threaded×atomics,
// cell×nif) and every corpus program, drive the three optimizer levels — OptNone, Baseline,
// Aggressive — spread over that combo's coherent binding, and assert byte-identity + spec-match.
list.each(combos.shipped, fn(c) {
  let base = combos.binding_for(c)          // coherent, cap-baked, validated (unit 07 surface)
  let none = driver.pipeline_with(Binding(..base, opt_level: ir_opt.OptNone))
  let base_lvl = driver.pipeline_with(Binding(..base, opt_level: ir_opt.Baseline))
  let aggr = driver.pipeline_with(Binding(..base, opt_level: ir_opt.Aggressive))
  // for each corpus program p:
  //   (a) outcome(none,p) == .expected  &&  outcome(base_lvl,p) == .expected  (spec-correct at each level)
  //   (b) outcome(none,p) == outcome(base_lvl,p) == outcome(aggr,p)           (cross-level byte-identity)
})
```

- **Both checks are needed (D8, no change-detector).** Cross-level identity alone could pass on a
  mutually-broken pair; matching `.expected` alone is just the existing acceptance test. Together
  they are M6: the memory passes preserved the *spec* answer, and preserved it *identically* at
  every level. This is the exact discipline `differential_test.gleam` and `combos.gleam` use.
- **`Aggressive` runs under a metered Safe combo on purpose** (the four `metered` combos are
  `MeterFuel`). As Phase-3's capstone documented: `Aggressive`'s charge-elision touches only the
  fuel instrumentation (a policy overlay, not a WASM semantic, F5), so eliding it under `MeterFuel`
  changes fuel accounting but **not** the WASM `Outcome` — which is exactly the invariant under
  test; the default budget is generous so `FuelExhausted` never fires. (The `cell×nif` combo is
  already `Unsafe`/`MeterOff`; spreading the three levels onto it varies only `opt_level`.)
- **Why the full tier matrix, not one combo.** The memory passes are tier-**independent** (they run
  before tier selection), so their *result-neutrality* is proven by `OptNone ≡ Baseline` under a
  single combo. Running **all** combos proves something further and necessary: that the emitted
  **fewer-access** code executes correctly through **every runtime backend** — that `rt_mem_paged`,
  `rt_mem_atomics`, and the `rt_mem_nif` skeleton each run the reduced access set to the same
  spec-observable result, under both the `cell` and `threaded` calling conventions. That is the
  all-tier half of M6, and it is not redundant with the single-combo result.

### B.2 — Spec-suite half

The corpus gives fine-grained bit-identity on authored programs; the **whole spec suite** gives
breadth. Extend `conformance_test.gleam` (or drive the pinned allowlist suite here) at `fail == 0 &&
pass > 0` under `driver.pipeline_with(profiles.safe())` (Baseline optimizer, memory passes on) and
`driver.pipeline_with(profiles.unsafe())` (Aggressive) — a single unsound memory rewrite on any
allowlisted assertion goes red. Phase 9 is **conformance-neutral**: no new IR nodes, no new spec
files, so the counts do not move — the proof is that the *same* green holds with the memory passes
engaged. (The suite budget is generous enough that no in-scope program trips `FuelExhausted`.)

### B.3 — The μ₉ monotonicity + convergence assertion (M7)

`count_mem_ops` (keystone) is exposed so the capstone can assert, over the corpus, that the passes
**never add** a memory op and the fixpoint **converges**. This is tier-independent (it is on the IR
before emit), so it runs once per corpus program against the post-`ir_lower` module `m`:

```gleam
// M7 — n_mem is monotone non-increasing, and the change is entirely the memory passes'.
assert mem_ssa.count_mem_ops(ir_opt.optimize(m, ir_opt.Baseline))
    <= mem_ssa.count_mem_ops(m)                                    // passes never ADD a mem op
// Baseline passes never touch n_mem (M7), so OptNone's count is m's count — the whole delta is memory:
assert mem_ssa.count_mem_ops(ir_opt.optimize(m, ir_opt.OptNone))
    == mem_ssa.count_mem_ops(m)                                    // OptNone is identity
// And optimize returns (no non-termination, no panic — `optimize` is total, so reaching this line is
// the convergence proof; the μ₉ measure bounds the fixpoint below max_rounds, keystone §D).
```

The first inequality is the M7 non-increase; the second equality pins that `OptNone` is the identity
and that the memory-op delta between `OptNone` and `Baseline` is **entirely attributable to the
memory passes** (no baseline pass creates or removes a `MemLoad`/`MemStore`) — which is exactly the
clean isolation the static benchmark metric (§C.1) rests on.

---

## C. The benchmark — the headline, MEASURED not asserted (M8)

`smoke/mem_bench.sh` + `docs/phase-9-benchmark.md`. Two metrics, **reported together**: a
deterministic static count (the passes fired) and wall-clock ns/call (they helped). Reuse
`smoke/bench.sh`'s structure verbatim — the portable `run_to` timeout, the `exec_ns`/`exec_val`/
`ratio`/`u32` helpers, the wasmtime correctness gate — and add the memory fixture + the OptNone
build column.

### C.1 — The deterministic static metric (clock-independent proof the passes FIRE)

The honest "the optimization happened" evidence is a **deterministic** count, independent of the
machine and the clock: how many `MemLoad`/`MemStore` nodes the memory passes eliminate on the
fixture. Because `count_mem_ops(OptNone) == count_mem_ops(m)` and no baseline pass touches `n_mem`
(§B.3 / M7), the delta

```
eliminated = count_mem_ops(optimize(m, OptNone)) - count_mem_ops(optimize(m, Baseline))
```

is **exactly** the number of memory ops the three memory passes removed — no git before/after, no
special "Baseline-without-memory" build needed; the M7 invariant *is* the isolation. This is a
Gleam test (in `memory_differential_test.gleam` or a co-located bench test), asserting
`eliminated == <the fixture's exact expected count>` and `eliminated > 0`. As a belt-and-suspenders
that also re-verifies M7, drive the pass lists directly and confirm the delta is entirely the memory
passes':

```gleam
let m = /* post-ir_lower IR of memkern.wasm, via source_to_ir |> lower_ir(profiles.safe()) */
let without = pass.run_pipeline(m, baseline.baseline_passes())
let with_mem =
  pass.run_pipeline(m, list.append(baseline.baseline_passes(), memory_passes))
assert mem_ssa.count_mem_ops(without) == mem_ssa.count_mem_ops(m)           // baseline leaves n_mem alone
assert mem_ssa.count_mem_ops(m) - mem_ssa.count_mem_ops(with_mem) == expected_eliminated
assert expected_eliminated > 0                                             // the passes FIRE
```

`docs/phase-9-benchmark.md` reports this count (per pass, if the fixture is instrumented to
distinguish them: N loads forwarded, N loads RLE'd, N stores DSE'd). This number is the same on
every machine — it is the report's clock-independent spine.

### C.2 — Wall-clock ns/call, per memory tier

Mirror `smoke/bench.sh`. Compile the fixture at **OptNone** (memory passes off) and **Baseline**
(memory passes on), **per memory tier**, correctness-gate each build **bit-exact vs wasmtime**
before timing (a fast wrong number is not a number), then `exec -n N` and report ns/call:

```sh
# smoke/mem_bench.sh (schematic): for each tier, build memkern.wasm at OptNone and at Baseline,
# gate bit-exact vs wasmtime, exec N times, print ns/call + the OptNone→Baseline speedup ratio.
for tier in "paged" "atomics --cap $CAP"; do
  gleam run -- to-beam-wasm -O0   --tier $tier "$WASM" "$OUT/none.$tier.beam"    # OptNone (see FLAG)
  gleam run -- to-beam-wasm       --tier $tier "$WASM" "$OUT/base.$tier.beam"    # Baseline (Safe default)
  gate_vs_wasmtime "$OUT/none.$tier.beam" && gate_vs_wasmtime "$OUT/base.$tier.beam" || exit 1
  exec_ns "$REPEAT" "$OUT/none.$tier.beam" memkern "$ARG"                        # ns/call, memory passes OFF
  exec_ns "$REPEAT" "$OUT/base.$tier.beam" memkern "$ARG"                        # ns/call, memory passes ON
done
```

- **The tier breakdown (invariant #3).** Report ns/call broken out per tier. The design note
  predicts **DSE's `paged` advantage is largest** — a redundant paged store is a whole O(page)
  rebuild, so eliminating it is worth far more there than on `atomics` (O(1) in-place). The report
  states this prediction and prints whether the numbers bore it out — the `paged` OptNone→Baseline
  ratio should exceed the `atomics` one on this store-bearing kernel. `nif` (skeleton over the paged
  core) tracks `paged`.
- **Honest caveat on what the wall-clock isolates.** OptNone→Baseline is an *end-to-end* delta:
  Baseline is baseline ++ memory passes, so the wall-clock includes the baseline passes too. The
  fixture is deliberately memory-traffic-**dominated** (no dead code, few foldable constants — see
  §C.3), so the baseline passes have little to do and the measured delta is dominated by the memory
  passes; but the report says so plainly. The **exact** memory-pass contribution is the deterministic
  static count of §C.1 — that is where the clean isolation lives; the wall-clock is the "does it
  translate to real time" number, per-tier.

> **FLAG for unit 11c (CLI, `src/twocore.gleam`).** The wall-clock needs an **OptNone** build, and
> today no profile yields `opt_level: OptNone` and no CLI flag selects it (all profiles are
> `Baseline`/`Aggressive`). Add a `-O0` / `--opt-none` compile flag on the compile verbs
> (`to-beam-wasm`, composing with the existing `--tier`/`--cap` axes) that spreads
> `opt_level: OptNone` onto the resolved binding — a small additive flag on `resolve_binding`, the
> exact shape Phase-3/4 flagged (`--profile`, `--tier`) and got. **If it does not land**,
> `mem_bench.sh` falls back to `smoke/mem_bench_harness.gleam` — a tiny Gleam driver that constructs
> `Binding(..profiles.safe(), opt_level: ir_opt.OptNone)` and `profiles.safe()` (with each tier's
> `mem_tier`/`--cap` set through `profiles.compose`/`resolve_tiers`) and emits both `.beam`s per tier
> via `pipeline.ir_to_core` → `core_to_beam` (the documented Phase-3/4 bench fallback). This unit
> does **not** edit `src/twocore.gleam` itself (that is unit 11c's file, D1) — it flags the need and
> ships the fallback.

### C.3 — The fixture kernel (`smoke/mem/memkern.wat`)

The fixture MUST exhibit **clear, provable** redundant memory traffic that each pass eliminates, on
**structured, compiler-shaped** addresses (a single base `Value` reused with distinct constant
memarg offsets — the shape the alias oracle is precise on, M5/invariant #4). A hand-written `.wat`
compiled with `wasm-tools`/`wat2wasm` is the right choice over a hand-written `.ir`: it is
**wasmtime-gateable** (bit-exact correctness, like `smoke/bench.sh`), it exercises the **real
frontend + the baseline-before-memory ordering** (so it proves the passes fire on *realistic* IR,
not on pre-baked nodes — a hand-crafted `.ir` that spells the exact `MemLoad`/`MemStore` shapes would
be closer to a change-detector), and the `.wat`+`.wasm` pair matches the committed-corpus convention
(`corpus/*.wat` + `*.wasm`). The kernel is one export over a single base pointer, looping `n` times:

```wat
(module
  (memory 1)
  (func (export "memkern") (param $n i32) (result i32)
    (local $i i32) (local $p i32) (local $acc i32)
    (local.set $p (i32.const 64))                 ;; a single fixed base, reused at distinct offsets
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
      ;; --- one straight-line region (no control flow until the back-edge) ---
      ;; (a) store→load forwarding: store [p+0], then load [p+0]  (MustAlias, natural i32 width)
      (i32.store offset=0 (local.get $p) (i32.add (local.get $acc) (local.get $i)))
      (local.set $acc (i32.load offset=0 (local.get $p)))                 ;; load ⇒ the stored value
      ;; (b) redundant-load elimination: read [p+4] twice, only pure ops between
      (local.set $acc (i32.add (local.get $acc) (i32.load offset=4 (local.get $p))))
      (local.set $acc (i32.add (local.get $acc) (i32.load offset=4 (local.get $p))))  ;; 2nd ⇒ 1st
      ;; (c) dead-store elimination: write [p+8] twice, only arithmetic between  (the paged headline)
      (i32.store offset=8 (local.get $p) (local.get $acc))               ;; DEAD — shadowed below
      (local.set $acc (i32.add (local.get $acc) (i32.const 1)))          ;; pure between
      (i32.store offset=8 (local.get $p) (local.get $acc))               ;; shadows the store above
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (i32.add (local.get $acc) (i32.load offset=8 (local.get $p)))))       ;; a deterministic result
```

**Why each pass fires** (after copy-prop unifies the `local.get $p` reads to one base `Var`, §A):

- **(a) store→load forwarding.** `store([p]+0, v)` then `load([p]+0)` — same base, offset 0, width
  4, both natural i32 width → `MustAlias`, no clobber between → the load is replaced by the stored
  value `v`; the load node **vanishes** (and with it a handle-fetch + bounds-check + decode). The
  store stays (nothing shadows `[p+0]`).
- **(b) redundant-load elimination.** two `load([p]+4)` with only pure `i32.add`/`local.set`
  between → `MustAlias`, no clobber → the second is replaced by the first's bound value; the second
  load **vanishes**. The intervening `[p+0]` store and `[p+8]` stores are `NoAlias` to `[p+4]` (the
  Array-SSA element disambiguation: `0..4`, `4..8`, `8..12` are disjoint), so they do **not** clobber
  `[p+4]`'s availability — this kernel showcases the alias oracle's offset disambiguation as much as
  the rewrites.
- **(c) dead-store elimination.** `store([p]+8, acc)` then a pure `i32.add` then `store([p]+8,
  acc+1)` — the shadowing store `MustAlias`es the same footprint with only pure nodes between → the
  first store **is removed**. Trap-neutral: the shadowing store bounds-checks the **same** address,
  so if `[p+8]` were OOB the original traps at store₁ and the optimized traps at store₂ — same
  `MemoryOutOfBounds`. On **`paged`** this elides a whole O(page) rebuild per iteration — the paged
  headline.

Per straight-line body: **3 eliminations** (1 forwarded load, 1 RLE'd load, 1 DSE'd store) — the
loop body appears once in the IR, so `expected_eliminated == 3` for §C.1 (the trailing `load
offset=8` is in a *fresh* region after the loop's control-flow boundary and correctly does **not**
forward across it — a barrier reset, which the kernel also implicitly checks). The result
`acc + [p+8]` is a deterministic function of `$n`, **bit-identical** at OptNone vs Baseline and
gate-able vs wasmtime.

### C.4 — The report (`docs/phase-9-benchmark.md`) must be HONEST

Structure mirrors `docs/phase-4-benchmark.md`. It MUST carry:

- **Methodology** — the fixture, that OptNone/Baseline run byte-identical work, the wasmtime
  correctness gate FIRST, warmup + `N` repeats, that `exec` times invocations only, the
  machine/OTP/Gleam/wasm-tools/wasmtime versions + testsuite pin, and the `atomics` `--cap`.
- **The static elimination counts** (§C.1) — the deterministic spine: N loads forwarded, N RLE'd,
  N stores DSE'd on the fixture; the count is machine-independent.
- **The wall-clock numbers with the tier breakdown** (§C.2) — one row per tier, OptNone vs Baseline
  ns/call + the speedup ratio; DSE's `paged` advantage called out (predicted, then confirmed or
  refuted by the measured ratio).
- **The honest ceiling (invariant #4 — MEASURED, not asserted).** State plainly what wins and what
  does **not**: structured `base + const` patterns with a reused base and distinct constant offsets
  win (this kernel, Rust/Porffor output); **fully-dynamic addressing** (a base computed per access)
  and **cross-control-flow redundancy** (a store in one arm, a load in another; a load hoistable
  across a loop back-edge) do **not** — those are deferred (§6: cross-control-flow MemorySSA,
  standalone-BCE, LICM). The win is real but pattern-dependent. **No hero number** — the report
  reports whatever the measurement says, and the ceiling is written down beside it.

---

## Effect / soundness / security note

- **The passes cannot be unsound and pass.** An unsound rewrite (a forward across an aliasing store,
  a DSE across a barrier, a mis-disambiguated `MayAlias`→`NoAlias`) changes a `mem`/`gvar` corpus
  `Outcome` — the differential (§B) goes red on the exact program, on the exact tier. Units 02/03's
  adversarial "must-NOT" fixtures catch it earlier; this whole-corpus, all-tier differential is the
  backstop for anything that slips past them. "Green" means *every observable was preserved on every
  runtime backend under both modes*, not "it compiled."
- **Trap-preservation is absolute (M3), including the fuel trap.** Every rewrite rests on a
  dominating successful access (forwarding/RLE) or a same-address shadowing store (DSE), so no WASM
  trap changes when or whether it fires; and the metering note (§A) shows the `FuelExhausted` bound
  is bit-identical too (baked `Charge` costs preserved verbatim). The sandbox's observable semantics
  — WASM traps *and* the policy fuel trap — are unchanged, which is why the passes are Safe-legal.
- **No new authority, no runtime touch (M4).** Phase 9 adds no IR node, no `rt_mem`/`rt_state`/
  `emit_core` ABI change, and introduces no call/`apply`. The only cross-file reach is the one
  documented pipeline registration; the emitted `.core` for an unoptimized module is byte-identical
  to Phase 8, and an optimized module differs only by having **fewer** accesses.

---

## Verification — Definition of Done (D8)

- **The wire (proof 1).** `ir_opt.pipeline/1` returns `baseline ++ memory_passes` for `Baseline` and
  `baseline ++ memory_passes ++ aggressive` for `Aggressive`; `OptNone` stays `[]`. `Aggressive` is
  a strict superset of `Baseline`. The reach is recorded in `state.md`.
- **The differential (proof 2) — green corpus-wide, all tiers, both modes.** For every corpus
  program, `OptNone ≡ Baseline ≡ Aggressive` byte-identically (values by bit pattern, traps by
  reason) under **every** shipped `(state_strategy × mem_tier)` combo, and each level equals the
  spec-sourced `.expected`. The spec suite is `fail == 0 && pass > 0` under `profiles.safe()` and
  `profiles.unsafe()`; counts unchanged (conformance-neutral). `count_mem_ops(optimize(m, Baseline))
  <= count_mem_ops(m)` over the corpus (M7), and the fixpoint converges (no non-termination, no
  panic). **The WASM corpus is RESULT-identical** — the emitted code legitimately differs (fewer
  accesses), so the bar is result-identical (like the Phase-3 optimizer differential), **not**
  byte-identical emission.
- **The benchmark (proof 3) — the passes FIRE and are faster.** The deterministic static count is
  `> 0` and equals the fixture's expected eliminations (`memkern`: 3/body); `docs/phase-9-benchmark.md`
  is committed with the static counts, the wall-clock ns/call **per tier** (OptNone vs Baseline,
  correctness-gated bit-exact vs wasmtime before timing), the DSE-`paged` breakdown, and the honest
  ceiling — **no hero number**.
- **Green build.** `gleam format --check src test` clean; `gleam build` **zero warnings** (no
  `todo`/`panic`/`let assert` on any non-impossible path); `gleam test` ≥ 1734 + the new tests,
  0 failures. **Done = the suites pass and the report is committed with measured, correctness-gated
  numbers** — never "it compiled," never "the script ran."

---

## Phase 9 proven

The memory optimizer is live: MemorySSA + linear-memory alias analysis feeds three trust-neutral
rewrites — store→load forwarding, redundant-load elimination, dead-store elimination — wired into
the **Baseline** pipeline, so **Safe** and every tier and both modes remove redundant memory traffic
with **no** observable change on the whole Phase-1…8 corpus + spec suite, proven differentially
across every `(state_strategy × mem_tier)` combo. The win is **measured**: a deterministic count of
eliminated `MemLoad`/`MemStore` nodes proves the passes fire, and per-tier wall-clock numbers show
the speedup (DSE's paged advantage largest, as the note predicted), with the pattern-dependent
ceiling written down — no hero number.

**Deferred to a later phase (stated, not dropped — §6 of the overview):** *standalone*
range-based bounds-check elimination (needs an "unchecked access" IR form), **LICM** of the
loop-invariant handle fetch (needs the handle exposed as an IR value — an `emit_core`/`rt_mem` seam
change), and **MemorySSA across control flow** (a φ-joined cross-block memory analysis — forward a
store into both arms of an `If`, RLE across a loop back-edge under a no-clobber proof). The
benchmark's own ceiling — fully-dynamic addressing and cross-control-flow redundancy do not win —
is exactly what those units attack. See [`00-overview.md`](00-overview.md) §6.
