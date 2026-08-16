# Phase-9 benchmark — does the memory optimizer make the generated code faster? (honest, M8)

> **Phase 9 added a MemorySSA + linear-memory alias analysis and three trap-preserving,
> trust-neutral rewrites — store→load forwarding, redundant-load elimination, and dead-store
> elimination — wired into the shared `ir_opt` `Baseline` pipeline (so Safe gets them, and every
> tier + both modes inherit them).** This report measures, **with no hero number**, two things: a
> **deterministic, clock-independent** proof that the passes fire (a count of eliminated
> `MemLoad`/`MemStore` nodes), and a **wall-clock** measurement of the resulting speedup on a
> memory-traffic-heavy kernel. The design note's honest ceiling is stated and respected: the win is
> **real but pattern-dependent** — structured `base + constant-offset` access patterns win; fully
> dynamic addressing and cross-control-flow redundancy do not (deferred, §"The ceiling").
>
> **The measured verdict, up front:** on the `paged` memory tier (where each store is an O(page)
> immutable-binary rebuild — the design note's invariant #3), the memory passes make a store-churn
> loop **~3–4× faster** (baseline-only ≈ 1.4 µs/iteration → ≈ 0.38 µs/iteration with the memory
> passes, correctness-gated bit-identical). The passes are **byte-for-byte semantics-preserving**
> over the entire Phase-1…8 acceptance corpus + WASM spec suite, under **both** profiles and **every**
> shipped `(state_strategy × mem_tier)` combo (`fail = 0` throughout).

---

## 1. The correctness backdrop (the bar every number sits behind)

A fast wrong number is not a number. Before any timing, the passes clear the platform's full
differential:

- **`OptNone ≡ Baseline ≡ Aggressive`** — byte-identical returned values (by bit pattern, D5/D7)
  and identical traps — over the whole acceptance corpus **and** the official WASM spec `.wast`
  suite (46 529 passing asserts, `fail = 0`), run under **every** shipped `(state_strategy ×
  mem_tier)` combo (`cell`/`threaded` × `paged`/`atomics`/`nif`) and **both** profiles
  (`test/carder/optimize/differential_test.gleam`, the tier-matrix suites). Wiring the memory
  passes in changed **no** observable result on any real program.
- The passes only ever *remove* a `MemStore` (DSE) or *replace* a `MemLoad` with an already-bound
  `Value` (forwarding/RLE); they add no IR node, reorder no effect, introduce no call/`apply`. Every
  rewrite is trap-preserving (a dominating successful access proves the address in-bounds; a
  shadowing store bounds-checks the same address), which is what makes them **trust-neutral** — they
  run at `Baseline`, so the sandbox is not weakened.

---

## 2. The deterministic metric — the passes fire (clock-independent)

`mem_ssa.count_mem_ops(m)` counts `MemLoad + MemStore` nodes. Because no Phase-9 pass (and no
baseline pass) ever *constructs* one, the difference before/after the memory passes is exactly the
work they did — a deterministic number, independent of any timer.

| Kernel (`test/carder/optimize/memory_differential_test.gleam`) | mem-ops at `OptNone` | mem-ops at `Baseline` | eliminated |
|---|---|---|---|
| `churn` (1 dead store + store→load-forward + a disjoint-offset load + RLE, straight-line) | **6** | **2** | **4** (1 store via DSE, 3 loads via forwarding/RLE) |
| `bench` loop body (3 dead stores + 1 live store + 1 forwardable load, per iteration) | **5** | **1** | **4** per iteration (3 stores via DSE, 1 load via forwarding) |

These are asserted exactly (not `<=`) in the suite, so a regression that stops a pass firing breaks
a test. The full-corpus check additionally asserts **monotonicity**
(`count_mem_ops(optimize(m, Baseline)) <= count_mem_ops(m)` — the passes never *add* a memory op)
and **convergence** (`optimize(optimize(m)) == optimize(m)` — the fixpoint is reached, no
oscillation).

---

## 3. The wall-clock measurement (`test/carder/optimize/mem_bench_test.gleam`)

**Method — the memory-pass delta, isolated.** The benchmark builds the *same* lowered kernel two
ways that differ in **exactly** the memory passes: `baseline.baseline_passes()` alone, versus
`baseline.baseline_passes() ++ [forwarding_pass(), dead_store_pass()]`. Both are emitted under the
**same** binding (`paged` tier, `Cell` state, **metering off** so the hot loop is not fuel-bounded),
compiled to `.beam`, **correctness-gated identical** (`bench(500) = 873 250` for both), then timed
with `pipeline.exec_beam` (invocations only — compile/load/instantiate excluded).

**The kernel** — a loop whose body, per iteration, does 4 stores to a single scratch cell (3 dead,
shadowed by the 4th, with only pure arithmetic between) + 1 load of that cell:

```
bench(n):
  loop (i=0, acc=0):
    if i >= n: return acc
    store(0, i)          // dead  ┐
    store(0, i+1)        // dead  ├─ 3 stores DSE removes (each shadowed; pure between)
    store(0, i+2)        // dead  ┘
    store(0, i*7 + acc)  // live
    v = load(0)          // → store→load-forwarded away
    continue(i+1, v)
```

Per iteration the memory passes turn **4 paged stores + 1 load** into **1 store + 0 loads** — and,
because DSE makes the dead stores' operand computations (`i`, `i+1`, `i+2`) unreachable, the baseline
`dead-let` pass on the next fixpoint round removes that arithmetic too. On the `paged` tier a store
is an O(page) rebuild, so this is a large cut in the dominant cost.

**Measured (Apple-silicon dev machine, 80 000 loop iterations, four runs):**

| build | ns / iteration | relative |
|---|---|---|
| `baseline` passes only | **≈ 1360 – 1460** | 1.0× (baseline) |
| `baseline` **+ memory passes** | **≈ 350 – 450** | **≈ 3.0 – 4.1× faster** |

The number is noisy (BEAM scheduling, GC) but the direction is unambiguous and the magnitude is
multi-fold — consistent with the structural prediction (eliminating 3 of 4 O(page) stores per
iteration). The test **asserts** the memory build is strictly faster, so a regression that made the
passes ineffective (or harmful) would fail CI, not just print a worse number.

---

## 4. Why `paged` wins most — the tier breakdown

The memory passes run **upstream of tier + mode selection** (`ir_lower → ir_opt → emit_core`), so a
single sound rewrite speeds up every tier. But the *size* of the win is tier-dependent, exactly as
the design note's invariant #3 predicts:

- **Dead-store elimination helps `paged`/`portable` most.** A redundant `paged` store is a whole
  O(page) immutable-binary rebuild; eliminating it removes that entire rebuild. This is the
  headline measured above, and it is the tier that most needs the help (Phase 4 measured `paged` as
  the slow runs-anywhere floor).
- **Store→load forwarding and redundant-load elimination help every tier.** They remove the handle
  fetch **and** the bounds-compare/branch **and** the bit-syntax decode for the eliminated access —
  a real per-access saving on `atomics` (O(1)) and `nif` too, just a smaller absolute one than a
  `paged` store-rebuild.

No per-tier code exists for any of this: the wins fall out of *where in the pipeline the passes
sit* (M2).

---

## 5. The ceiling (honest, measured, pattern-dependent — M8)

The alias analysis is precise on the address shapes compilers actually emit and **deliberately
conservative** elsewhere. The win is real but pattern-dependent; do not extrapolate it to arbitrary
code:

- **Wins:** the same base `Value` reused with **distinct constant memarg offsets** (so `base+0` and
  `base+4` are proven disjoint — the Array-SSA element disambiguation), and syntactically-equal
  operands. This is the Rust/Porffor-emitted shape.
- **Does not win (returns `MayAlias` → no rewrite — sound, just missed):** two **different** base
  `Value`s (Phase 9 does not value-number bases beyond syntactic `==`), fully-dynamic address
  computation, and sub-width / truncating accesses (excluded by the truncation guard for
  correctness).
- **Per straight-line region.** The analysis **resets at every control-flow boundary**
  (`If`/`Switch`/`Loop`/`Block`/`Try`) — it optimizes within a region but carries no memory
  knowledge across one. A store→load across an `if`, or reuse across a loop back-edge, is **not**
  captured here (it needs a φ-joined cross-block MemorySSA — deferred).

**Deferred, stated not dropped** (see `specs/phase-9/00-overview.md` §6): standalone range-based
bounds-check elimination (dropping the check while keeping the read — needs an unchecked-access IR
form), LICM of the loop-invariant handle fetch (needs the handle exposed as an IR value), and
MemorySSA across control flow. Phase 9 ships the three payoffs that need **no new IR surface** and
are **trap-preserving and trust-neutral**; the flagship BCE case ("after `store(a,v)` succeeds,
`load(a)` is in bounds ⟹ forward `v` and drop its check") **is** shipped — subsumed by store→load
forwarding, which removes the whole load, check included.

---

## 6. Reproduce

```
gleam test -- carder/optimize/memory_differential_test   # the deterministic firing metric (§2)
gleam test -- carder/optimize/mem_bench_test              # the wall-clock measurement (§3)
gleam test                                                 # the full corpus/spec/tier differential (§1)
```

The static counts (§2) are exact and reproduce identically on any machine; the wall-clock (§3)
varies with hardware and scheduling but the multi-fold `paged` direction is stable across runs.
