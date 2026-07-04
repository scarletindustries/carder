# Phase 9 · Unit 03 — dead-store elimination (`mem_dse`, the paged-tier headline)

> **One owner · Wave after `«MEM-SSA-FROZEN»` (parallel with unit 02) · the paged-tier win.**
> Read [`00-overview.md`](00-overview.md) (M1–M8), the design note
> [`../future-work-memory-optimizer.md`](../future-work-memory-optimizer.md) (invariant #3 — "DSE
> helps paged/portable most"), and the keystone [`01-mem-ssa-keystone.md`](01-mem-ssa-keystone.md)
> `«MEM-SSA-FROZEN»` first; Phase-1 D1–D10, Phase-2 E1–E8, Phase-3 F1–F8 and the Phase-9 decisions
> M1–M8 still hold. **Freeze dep:** `«MEM-SSA-FROZEN»` — this unit CONSUMES the keystone's
> `Footprint`/`AliasResult`/`alias/2`/`footprint_of/1` surface and rewrites nothing in it. It ships
> **one** optimizer pass — `dead_store_pass()` — a `pass.per_function` look-ahead peephole that
> performs **dead-store elimination**, plus its adversarial fixtures. It does **not** touch
> `ir_opt.pipeline` (unit 04 wires it in), so the acceptance corpus stays **byte-identical** after
> this unit — the pass is tested in isolation.

---

## Context

A WebAssembly `t.store` is **trap-or-write**: it bounds-checks `addr + offset` against the current
memory length and either traps `MemoryOutOfBounds` or writes the value's little-endian bytes
([spec exec/instructions §Memory Instructions](https://webassembly.github.io/spec/core/exec/instructions.html);
[exec/memory](https://webassembly.github.io/spec/core/exec/memory.html)). It is emphatically **not**
a pure write — which is exactly why the Phase-3 baseline `dead_let` pass, gated on
`ir/effect.is_pure`, can **never** remove a store: `is_pure(MemStore(..)) == False`, so a store's
`let _ = store in …` sequencing is load-bearing and always survives (F3). That conservatism is
correct but leaves a whole class of redundancy on the table: a value written to some address that is
**completely overwritten** before anyone reads it is dead traffic. Removing it needs the one fact
`ir/effect` deliberately does not have — *does this later store touch the same bytes?* — which the
keystone's `alias` oracle now supplies.

This unit is the **dead-store** consumer of that oracle. It is intraprocedural and **per
straight-line region** (M8): it walks each function body's `Let`-chain and resets at every
control-flow boundary (`If`/`Switch`/`Loop`/`Block`/`Try`). It removes stores; it never adds,
reorders, or moves one, and it never introduces a call or an `apply` (D3a). Its correctness rests
entirely on two frozen facts from the keystone — `alias(F1, F2) == MustAlias` (the two stores hit
the exact same bytes) and `ir/effect.is_pure` (nothing between them can observe or perturb those
bytes or the trap) — so a single unsound `alias` judgement would be silent memory corruption, which
is why the keystone shipped `alias` with adversarial "must-be-`MayAlias`" tripwires first.

---

## Deliverables & freeze milestones

**Consume (frozen upstream):**

- `«MEM-SSA-FROZEN»` — `mem_ssa.{type Footprint, type AliasResult, MustAlias, NoAlias, MayAlias,
  footprint_of, alias}` (unit 01). DSE uses `footprint_of/1` to name each store's touched bytes and
  `alias/2` to test the shadow. It does **not** need `is_memory_barrier/1` (see §A: the `is_pure`
  peel already stops at every barrier), nor `byte_width/1` (see §B: a truncating shadow is caught by
  `alias` returning `MayAlias`, never `MustAlias`).
- `ir/effect.{is_pure}` (Phase-3 unit 02) — the **deep** purity classifier that decides whether the
  computation between the two stores is harmless. `is_pure` is conservative and total.
- `middle/ir_opt/pass.{type Pass, per_function}` (Phase-3 unit 01) — the pass constructor.
- `ir.gleam` (`«IR4-FROZEN»`) — the `Expr` surface; in particular the lowered store shape
  `Let([], MemStore(mem, op, addr, value, offset), body)` — a **zero-result effect with an EMPTY
  names list** (`src/twocore/frontend/wasm/lower.gleam`, `emit_store`/`emit_effect`). **No IR
  change** (M4): DSE only *removes* a `MemStore` node (and its enclosing `Let([], …)`).

**Produce (`«MEM-SSA-FROZEN»` consumer — publishes no new freeze token; a leaf on the DAG):**

- `src/twocore/middle/ir_opt/mem_dse.gleam` (**NEW**, owned) — exports `pub fn dead_store_pass() ->
  pass.Pass`; the look-ahead peephole below. Imports `{ir, ir/effect, middle/ir_opt/pass,
  middle/ir_opt/mem_ssa, gleam/list}` — all acyclic (none imports `ir_opt` or `mem_dse`).
- `test/twocore/optimize/mem_dse_test.gleam` (**NEW**) — the spec-cited positive + adversarial
  fixtures (§Verification), including the end-to-end BEAM runs.

**No pipeline edit.** `ir_opt.pipeline(Baseline)` stays `baseline.baseline_passes()`; the memory
passes are **not** appended until unit 04. So `optimize(m, _)` is unchanged and the WASM corpus is
**byte-identical** after this unit — it only *adds* a module + tests. This keeps unit 03
individually green and pushable, exactly as the DAG (§00 §3) requires.

> **Naming note (flagged for the planner).** `00-overview.md`'s DAG/ownership sketch abbreviates
> this pass as `dead_store_elim()`. Per this unit's brief the exported symbol is
> **`dead_store_pass()`**; unit 04 appends the exported name. The two docs should be reconciled to a
> single spelling before unit 04 wires the pipeline — this doc uses `dead_store_pass()` throughout.

---

## A. The pass shape + the look-ahead peephole

`dead_store_pass()` is a `pass.per_function` **scope-aware look-ahead peephole** over the
`Let`-chain. Unlike the `per_expr` baseline passes it cannot use the effect-agnostic bottom-up
`map_expr` combinator: DSE's decision at a store depends on *what follows it* in the straight-line
region, so it walks the chain explicitly (like `dead_let`/`block_simplify` do their own recursion).

The walk is two mutually-simple functions:

- `dse_region/1` rewrites one straight-line region front-to-back. At a store it asks "is this store
  dead?"; everywhere else it recurses, **resetting the look-ahead at every control-flow boundary**
  by descending into `If`/`Switch`/`Loop`/`Block`/`Try` sub-expressions as **fresh regions** (DSE,
  like forwarding, is per straight-line region — M8).
- `is_dead/2` answers the peephole question by peeling the leading **pure** frames off the tail and
  inspecting the first non-pure node.

```gleam
//// middle/ir_opt/mem_dse — dead-store elimination (Phase-9 unit 03, the paged-tier headline).
//// A pass.per_function look-ahead peephole consuming `«MEM-SSA-FROZEN»` (footprint_of + alias).
//// Removes a store fully shadowed by a MustAlias later store with only pure nodes between; it
//// only REMOVES a MemStore — never adds, reorders, or moves an effect (D3a/M4).

import gleam/list
import twocore/ir
import twocore/ir/effect
import twocore/middle/ir_opt/mem_ssa.{type Footprint, MustAlias}
import twocore/middle/ir_opt/pass.{type Pass}

/// The dead-store-elimination pass (M3 lever #3). For `store(F1,v1)` followed — in the same
/// straight-line region, with ONLY PURE nodes between — by a MustAlias `store(F2,v2)`, the first
/// store is DEAD and is removed. Trap- AND state-preserving (§B). Registered by unit 04 into the
/// `Baseline` arm (inherited by `Aggressive`). Total; never panics; only ever removes nodes.
pub fn dead_store_pass() -> Pass {
  pass.per_function("mem-dse", fn(f) { ir.Function(..f, body: dse_region(f.body)) })
}

/// Rewrite one straight-line region. At a store, drop it iff `is_dead`; everywhere else recurse,
/// treating each control-flow sub-expression as a FRESH region (the look-ahead resets there).
fn dse_region(e: ir.Expr) -> ir.Expr {
  case e {
    // A lowered store: `Let([], MemStore(..), rest)` — empty names, so its "result" is unused
    // by construction (nothing downstream can depend on a store's value).
    ir.Let([], ir.MemStore(_, _, _, _, _) as store, rest) ->
      case is_dead(store, rest) {
        True -> dse_region(rest)                    // store1 is dead — drop it, keep the tail
        False -> ir.Let([], store, dse_region(rest))
      }
    // Any other Let: recurse into rhs (its own region) and into the tail (a fresh head).
    ir.Let(names, rhs, body) ->
      ir.Let(names, dse_region(rhs), dse_region(body))
    // ── control-flow boundaries: each sub-expression is a FRESH straight-line region ──
    ir.If(c, r, t, el) -> ir.If(c, r, dse_region(t), dse_region(el))
    ir.Block(l, r, body) -> ir.Block(l, r, dse_region(body))
    ir.Loop(l, ps, r, body) -> ir.Loop(l, ps, r, dse_region(body))
    ir.Switch(sel, r, arms, def) ->
      ir.Switch(sel, r, dse_arms(arms), dse_region(def))
    ir.Try(r, body, hs) -> ir.Try(r, dse_region(body), dse_handlers(hs))
    ir.Charge(cost, body) -> ir.Charge(cost, dse_region(body))
    // leaves carry no sub-`Expr` — return unchanged.
    _ -> e
  }
}

/// Is `store` (footprint F1) fully shadowed further down `rest`? Peel leading PURE `Let` frames;
/// at the first non-pure node, `store` is dead iff that node is a MustAlias `MemStore`.
fn is_dead(store: ir.Expr, rest: ir.Expr) -> Bool {
  case mem_ssa.footprint_of(store) {
    Error(Nil) -> False
    Ok(f1) -> shadowed(f1, rest)
  }
}

/// Peel pure computation between the two stores; test the first non-pure node.
fn shadowed(f1: Footprint, rest: ir.Expr) -> Bool {
  case rest {
    ir.Let(_, rhs, inner) ->
      case effect.is_pure(rhs) {
        // Pure between the two stores is harmless — it cannot observe memory, trap, transfer
        // control, or change bounds — so keep peeling. (`is_pure` is DEEP: a Let whose rhs hides
        // a MemLoad/MemStore/call is NOT pure, so a load or barrier stops the peel here.)
        True -> shadowed(f1, inner)
        // The FIRST non-pure node. store1 is dead ONLY if it is a MustAlias later store.
        False ->
          case rhs {
            ir.MemStore(_, _, _, _, _) as store2 ->
              case mem_ssa.footprint_of(store2) {
                Ok(f2) -> mem_ssa.alias(f1, f2) == MustAlias
                Error(Nil) -> False
              }
            // a load, a barrier (grow/call/bulk), a trapping op, or a control transfer → KEEP.
            _ -> False
          }
      }
    // `rest` is not a Let-chain head (a bare value / control transfer) → nothing shadows → KEEP.
    _ -> False
  }
}
```

*(`dse_arms`/`dse_handlers` map `dse_region` over each `SwitchArm.body` / `CatchHandler.handler`,
mirroring the keystone traversal helpers. The sketch is illustrative — the shipped body is total,
`todo`-free, and doc-commented per the DoD.)*

**Why the empty-names shape matters.** A lowered store is `Let([], MemStore(..), body)` — it binds
**no** names (§`emit_store`/`emit_effect`, `lower.gleam:1153-1196`). So "the store's result is
unused" is **automatic**: nothing downstream can reference a store's value, and dropping the store
cannot orphan a live binding. Contrast a value-producing node, where "result unused" is a separate
liveness question `dead_let` must compute; here it is free.

**Why the peel uses the DEEP `is_pure`.** The look-ahead must stop at the **first** node that could
observe or perturb F1's bytes or its trap status. `ir/effect.is_pure` is exactly that stopper, and
it is deep: `is_pure(MemLoad(..)) == False` and `is_pure(MemStore(..)) == False`, so an intervening
**load** or **store** stops the peel; `is_pure(MemGrow(..)) == False`, `is_pure(CallHost(..)) ==
False`, `is_pure(MemFill(..)) == False`, so every barrier stops it; every control transfer
(`Trap`/`Return`/`Break`/`Continue`/`Throw`) is effectful, so it stops it too. This is a clean
consequence worth stating: **DSE needs only `footprint_of`/`alias` from the keystone** — the whole
barrier set is subsumed by `is_pure` here, because every keystone barrier is already `Effectful` in
`ir/effect` (forwarding/RLE use `is_memory_barrier` to *clear* their `avail` map; DSE's peel gets
the same fail-closed behaviour directly from `is_pure`). If the first non-pure node is a load,
store1 is correctly **kept** — an intervening load of F1 would observe `v1`, so store1 is not dead.

**Why testing against the (already-recursed) tail is sound and why chains collapse.** DSE only ever
*removes* stores, so a store that was dead against the original `rest` is still dead against
`dse_region(rest)`. Transitive chains — `store(F,a); store(F,b); store(F,c)` — collapse across the
`run_pipeline` fixpoint: one round removes `store(F,a)` (shadowed by `store(F,b)`) and
`store(F,b)` (shadowed by `store(F,c)`) wherever the between-nodes are pure, converging to just
`store(F,c)`; the μ₉ measure (§D) guarantees the fixpoint terminates.

---

## B. Trap-preservation and state-preservation (the whole soundness story — M3)

The rewrite is: `store(F1, v1)` then — only-pure-nodes-between — `store(F2, v2)` with
`alias(F1, F2) == MustAlias`, so **same `mem`, syntactically-equal base `addr`, same `offset`, same
`bytes`**: byte-for-byte the *same address*. DSE deletes `store(F1, v1)`, keeping `store(F2, v2)`
and everything after it **verbatim**. Two observables must be preserved (F2): the **trap** (same
`TrapReason`, same trap-or-not, at the same point in the observable trace) and the **final memory
state**.

**Trap-preservation.** The shadowing store bounds-checks the **same address** as store1 (MustAlias ⇒
identical `mem`/`addr`/`offset`/`bytes`, so identical `addr + offset` and identical width — the
bounds check `addr + offset + bytes ≤ len` is identical).

- **If the address is out of bounds:** the ORIGINAL program traps `MemoryOutOfBounds` at store1; the
  OPTIMIZED program (store1 removed) traps `MemoryOutOfBounds` at store2 — the **same `TrapReason`**.
  And because **only pure nodes run between them**, nothing observable was skipped by trapping later:
  a pure node performs no state write, no host call, no fuel charge, no control transfer, and cannot
  itself trap or diverge, so the observable trace up to the trap is identical whether it fires at
  store1 or at store2. Crucially, nothing between them can change the address's in-bounds status:
  the **only** operation that changes bounds is `MemGrow`, which is **not** pure — it is a barrier
  that stops the peel — and likewise any other store/load/call/bulk-op is non-pure and stops the
  peel. So on the OOB path the two programs trap identically. (Spec:
  [exec/instructions §Memory](https://webassembly.github.io/spec/core/exec/instructions.html) — a
  store bounds-checks *then* writes; OOB traps before any write.)
- **If the address is in bounds:** both stores succeed. Store1 writes `v1` to F1; store2 overwrites
  the exact same bytes with `v2`; and because **nothing between them reads memory** (an intervening
  load is non-pure and would have stopped the peel, keeping store1), no execution observes `v1` at
  F1. So the final memory at F1 is `v2` either way — store1's write is fully dead. **Identical final
  state.**

**State-preservation.** Follows from the in-bounds case: the whole tail (store2 and everything after
it) is kept verbatim and every name it binds is still bound (DSE deletes only store1, which binds no
names and whose value `v1` is used by nothing else). No other memory cell, global, table, or fuel
counter is touched by the rewrite.

**Why "only pure between" is required (state the divergence it rules out).** Suppose an *effectful*
op `E` sat between store1 and store2 — say a `CallHost`, a `GlobalSet`, or another store. If store1's
address were OOB, the ORIGINAL traps at store1 and **never runs `E`**. But the OPTIMIZED program
(store1 gone) would run `E` *before* reaching the trap at store2 — executing a side effect the
original skipped. That is an observable divergence (a host call that should not have happened, a
global that should not have been written). Requiring **only-pure-between** rules this out precisely:
a pure node has nothing to skip, so deferring the trap from store1 to store2 changes nothing. (This
is also why `MemGrow` must block DSE for a second reason beyond bounds: it is an effect whose
skipping would diverge.)

**No scoping hazard from the shared base.** MustAlias requires `store1.addr == store2.addr` by
**syntactic** `Value` equality. Under the unique-name / per-iteration-SSA invariant (D6), if that
shared base is a `Var(t)`, then `t` must be in scope at store1 — i.e. **bound before** store1 —
because store1 already references it. So the base cannot be a name introduced by one of the peeled
between-frames. Deleting store1 therefore never dangles a reference and never changes which value
the kept store2 reads.

**The pass never reorders and never fabricates a call (D3a).** It performs exactly one kind of edit
— delete a `Let([], MemStore(..), rest)` node, splicing in `rest` — so effect ordering is preserved
verbatim and no `apply`/host target is ever introduced.

**A documented, sound future relaxation (a later unit — stated, not shipped).** The only-pure
restriction can be safely widened to allow intervening **`NoAlias`** loads and stores: a load/store
proven by `alias` to touch **disjoint** bytes neither observes F1 (so store1's `v1` is still dead)
nor changes F1's bounds (a store cannot grow memory). That would let DSE fire across
`store(base+0); store(base+4); store(base+0)` shapes. Phase 9 deliberately ships the **clearly-sound
only-pure** version (the peel stops at *any* non-pure node, `NoAlias` or not); the `NoAlias`-tolerant
peel is future work, gated on the same frozen `alias` oracle.

---

## C. The paged-tier win (invariant #3)

On the `paged` (runs-anywhere / `portable`) memory tier, linear memory is an **immutable Erlang
binary**, so a single `MemStore` is an **O(page) rebuild** — the whole page binary is reconstructed
with the new bytes spliced in. A redundant store is therefore not a cheap wasted write but an entire
page reconstruction. **Eliminating one removes a whole O(page) rebuild**, which is why the design
note's invariant #3 says "DSE helps paged/portable most — a redundant paged store is a whole O(page)
rebuild — eliminating it is worth far more there." On the `atomics`/`nif` tiers the same store is
O(1), so DSE still helps (a handle fetch + bounds-compare/branch + width decode removed) but by far
less; forwarding/RLE and (deferred) BCE/LICM close those tiers' residual.

The platform gets this asymmetric win **for free, with no per-tier code**: because `ir_opt` runs
**upstream of tier + mode selection** (`ir_lower → ir_opt → emit_core`, M2), the *same* IR-level
`dead_store_pass()` disproportionately closes the gap on the slow `paged`/`portable` build while
also helping the fast tiers — a single sound rewrite, N tiers benefited. This is the **benchmark
headline** unit 04 measures: the tier breakdown (DSE's paged advantage broken out) and a
deterministic count of eliminated `MemStore` nodes, with the honest pattern-dependence ceiling
(structured `base + const` wins; fully-dynamic addressing → `MayAlias` → no fire) written down (M8).

---

## D. Termination (M7)

The Phase-9 fixpoint converges under the lexicographic measure
`μ₉(m) = (n_mem, n_loops, n_ops, n_nodes, n_vars)`, where `n_mem = mem_ssa.count_mem_ops(m)` is the
number of `MemLoad + MemStore` nodes (the keystone's most-significant component, §01 D).
**Dead-store elimination removes a `MemStore` node (and its enclosing `Let([], …)`)**, so:

- `n_mem` strictly **↓** on every *changing* application (one fewer `MemStore`), and `n_nodes`
  strictly ↓ too (the `Let` frame is gone).
- `dead_store_pass()` **never constructs** a `MemLoad`/`MemStore` — it only removes one and splices
  the tail — so `n_mem` is **monotonically non-increasing** across the whole `run_pipeline`
  round-robin, and every DSE rewrite strictly decreases the most-significant component. It also adds
  no `Loop`/`Num`/`Convert` and no `Var`, so the lower-order components never rise.

Because no baseline pass constructs a `MemLoad`/`MemStore` either (§01 D), `μ₉` is bounded below by
`(0,0,0,0,0)` and strictly decreases on every changing round once the memory passes are appended, so
the fixpoint is reached well before `max_rounds` and no pass can undo another. This unit does not
change `run_pipeline`; it only relies on `count_mem_ops` (exposed by the keystone) so unit 04 can
assert convergence/monotonicity over the corpus.

---

## Effect / soundness / metering note

- **F2 is the bar.** `dead_store_pass()` preserves the exact returned bits and the exact trap
  behaviour (§B), so a module optimized by it is **result-identical** to the unoptimized one — the
  differential unit 04 runs corpus-wide across every tier and both modes.
- **F3 is respected structurally.** DSE consults the deep `ir/effect.is_pure` to *refuse* eliding a
  store whenever anything non-pure sits between the two stores, and consults `alias` to *refuse*
  eliding unless the shadow is a proven `MustAlias`. It only ever **removes** a store; it never
  reorders an effect, never CSEs a load, never hoists a trap, and never drops a store whose write is
  observable.
- **No load is ever reused across a store, no store across a load.** The peel stops at the first
  non-pure node, so DSE cannot "see past" a load or a barrier — it is incapable of the unsound
  reorderings by construction.
- **F5 metering is preserved.** `Charge` is effectful, so `is_pure(Charge(..)) == False`: a
  `Charge` between the two stores stops the peel and keeps store1. DSE therefore never removes a
  store across a fuel charge and never removes a `Charge` itself, so the fuel consumed on every
  executed path — and the deterministic `FuelExhausted` bound — is unchanged. In Unsafe (`MeterOff`)
  there are no `Charge` nodes and DSE behaves identically.
- **No ambient authority introduced (D3a).** Pure IR→IR node removal; it emits no call and no
  `apply` and fabricates no host/BIF target.

---

## Verification (Definition of Done — D8)

Tests assert **spec behaviour** and the **trap-preservation invariant**, cite the reasoning, and are
**not** change-detectors. "Done" = the suite below passes — never "it compiles". The pass is run in
isolation (build a one-function module, apply `dead_store_pass()`, inspect the result), and the
soundness fixtures additionally run **end-to-end on the real BEAM** via
`pipeline.ir_to_core → core_to_beam → instantiate → invoke_instance → stop_instance` (the pattern in
`test/twocore/pipeline_tier_test.gleam` `run_one`, and the corpus differential in
`test/twocore/optimize/differential_test.gleam`).

1. **Positive — adjacent shadow (the headline).** `store(F, v1); store(F, v2)` adjacent (MustAlias,
   same `mem`/`addr`/`offset`/`bytes`) → optimized IR contains **exactly one** `MemStore` (store2),
   with store1 **gone** (proven by walking the optimized `Expr` and counting `MemStore` nodes, or by
   `mem_ssa.count_mem_ops`). Then, **end-to-end on the BEAM**: a `store32(a, v1); store32(a, v2)`
   export followed by `load32(a)` returns `v2` — identical to the unoptimized module — proving
   value + trap behaviour is unchanged. Spec anchor: little-endian store round-trip
   ([exec/memory](https://webassembly.github.io/spec/core/exec/memory.html)).
2. **Positive — pure ops between.** `store(F, v1); let t = <pure Num/Convert/Values>; store(F, v2)`
   → store1 still removed (the pure binding is peeled), store2 kept; end-to-end memory ends `v2`.
3. **Adversarial — must NOT eliminate (the tripwires).** Each of these leaves store1 **intact**
   (assert the `MemStore` survives `dead_store_pass()`):
   - an intervening **load of F1** (`store(F,v1); let y = load(F); store(F,v2)`) — the load observes
     `v1`, so store1 is live (the peel stops at the non-pure load);
   - an intervening **barrier** — `MemGrow`, `CallHost`, or `MemFill` — between the two stores (each
     could change bounds or observe/write memory);
   - an intervening **`Charge`** (metering must not be crossed);
   - a **`MayAlias`** later store — different base `Var` (or `Var` vs `Const` base): not a proven
     shadow → keep;
   - a **`NoAlias`** later store — same base, **different `offset`** (`base+0`/4B then `base+4`/4B):
     store2 does not overwrite F1, so store1 is **not** dead → keep (this pins that DSE fires only on
     `MustAlias`, never on a merely-same-base later store);
   - an **OOB** address end-to-end: build `store32(oob, v1); store32(oob, v2)`, run it on the BEAM,
     and assert it **still traps `MemoryOutOfBounds`** — the shadowing store bounds-checks the same
     OOB address, so the trap is preserved whether or not store1 was removed.
4. **Region reset.** A store followed by a MustAlias store in a *different* region — one under an
   `If` arm, the other after the `If` — is **not** eliminated (the look-ahead resets at the `If`
   boundary); a store inside a loop body shadowed by a store after the loop is **not** eliminated.
5. **Green DoD.** `gleam format --check src test` clean; `gleam build` **zero warnings** (no
   `todo`/`panic`/`let assert` on any path — every function total); `gleam test` ≥ the entering
   baseline (1734) + the new tests, 0 failures; the WASM corpus **byte-identical** (this unit adds
   only a module + tests — the pipeline is untouched, so `optimize` is unchanged); every public
   function/type carries a `///` contract doc.

**Proof of goal:** a look-ahead peephole that removes a store **iff** a `MustAlias` later store
shadows it with only pure nodes between — trap-preserving (same `MemoryOutOfBounds`, proven by an
OOB BEAM run) and state-preserving (memory ends `v2`, proven by a BEAM round-trip) — with the
adversarial load/barrier/`MayAlias`/`NoAlias`/region tripwires pinning that it **never** fires
unsoundly. So unit 04 can append `dead_store_pass()` to the `Baseline` arm and the corpus-wide
differential stays result-identical across every tier and both modes, while `paged` sheds whole
O(page) rebuilds.

---

## What this unit leaves for others

- **Unit 04** (capstone) appends `dead_store_pass()` (alongside unit 02's forwarding + RLE passes)
  to `ir_opt.pipeline`'s `Baseline` arm — inherited by `Aggressive` — the **single** registration
  point; runs the corpus-wide result-identity differential across all tiers + both modes; and owns
  the memory benchmark, where DSE's **paged advantage** (a whole O(page) rebuild removed per
  eliminated store) is the headline, broken out from the fast-tier win, with the honest
  pattern-dependence ceiling written into `docs/phase-9-benchmark.md`.
- **The `NoAlias`-tolerant peel** (allow intervening `NoAlias` loads/stores between the two stores —
  sound because a disjoint access neither observes F1 nor changes its bounds) is **future work**,
  stated in §B. Phase 9 ships the clearly-sound only-pure version.
- **Cross-region DSE** (a store shadowed across an `If`/`Loop` boundary, e.g. a store dead on *both*
  arms of an `If`) needs the φ-joined cross-block MemorySSA the phase defers (M8, §00 §6) — the
  natural sequel, on top of the same frozen `alias` oracle.
