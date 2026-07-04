# Phase 10 · Unit 03 — cross-control-flow MemorySSA (forwarding / RLE / DSE across an `If`/`Block`/`Switch`)

> **One owner · Wave A (parallel with unit 02) · freeze dep `«MEM10-FROZEN»`.** Read
> [`00-overview.md`](00-overview.md) (N1–N8, esp. **N3**), [`01-keystone.md`](01-keystone.md) (the
> frozen `mem_clobber` interface this unit **consumes** — `may_clobber(expr, footprint) -> Bool`,
> `may_write_memory(expr) -> Bool`), and the Phase-9 keystone
> [`../phase-9/01-mem-ssa-keystone.md`](../phase-9/01-mem-ssa-keystone.md) with its passes
> [`../phase-9/02-store-load-forward.md`](../phase-9/02-store-load-forward.md) /
> [`../phase-9/03-dead-store-elim.md`](../phase-9/03-dead-store-elim.md) first. Phase-1…9 decisions
> still hold. This unit ships **no new module and no new IR node** — it takes the **cross-CF slice**
> of two existing files (`mem_forward.gleam`, `mem_dse.gleam`), relaxing the Phase-9 "reset at every
> control-flow boundary" to **carry a memory fact across an `If`/`Block`/`Switch` when — and only
> when — the may-clobber oracle proves no branch could perturb the footprint.** It does **not** touch
> `ir_opt.pipeline`. A false "no clobber" is silent memory corruption, so the oracle is the safety
> gate and every doubt collapses to exactly Phase-9's behaviour.
>
> **Ownership note.** `mem_forward.gleam` (Phase-9 unit 02) and `mem_dse.gleam` (Phase-9 unit 03) are
> single-owner files; this unit makes **single-owner-additive** edits confined to the **cross-CF
> transition** in each (the point where the Phase-9 walk cleared its state at a control-flow head).
> No Phase-9 straight-line-region logic, transfer function, alias judgement, or truncation guard
> changes. The corpus stays **result-identical** (byte-identical where Phase-9 already was — this unit
> is unwired until unit 07).

---

## Context

Phase 9 built MemorySSA **per straight-line region** (M8): `mem_forward` threads a reaching-value
map (`mem_ssa.Avail`) front-to-back through a `Let`-chain and **clears it (`dict.new()`) at every
control-flow head** (`If`/`Switch`/`Loop`/`Block`/`Try`); `mem_dse` peels pure frames looking ahead
for a `MustAlias` shadowing store and **stops at the first non-pure node** — a control-flow head
included. This was a deliberate **scope limit**, not a soundness requirement: the overview (§6) named
"MemorySSA across control flow" as deferred work, and `mem_forward.gleam` says so verbatim
("cross-control-flow MemorySSA is Phase-9 §6 deferred work").

**Phase 10 lifts the limit where it is provably safe.** The insight (N3): a control-flow boundary is
only a barrier because *some* execution of the subtree *might* write the footprint, grow memory, or
call out. If the may-clobber oracle proves that **no** execution of **any** branch does so, the fact
is unchanged on **every** path through the subtree and may legitimately survive it. Unit 01 froze that
oracle — `mem_clobber.may_clobber(child, f)` (conservative: `True` unless proven `False`) — precisely
so this unit can replace the blanket "clear at a boundary" with a **precise, per-footprint filter**.
Phase-9's per-region reset becomes the special case "every child may-clobbers `f`."

This unit relaxes **`If`/`Block`/`Switch`** and keeps **`Loop`/`Try` as full barriers**, honestly:
a loop back-edge re-enters the head with fresh iteration bindings (a fact recorded in one iteration
need not hold in the next without a proof this unit does not build), and a `Try` region's control can
jump to a handler mid-body (a partial-execution path the may-clobber walk does not model). Both stay
clears — a stated scope limit, not a soundness claim about them being unanalyzable.

---

## Deliverables & the freeze it consumes

**Consume (frozen upstream — `«MEM10-FROZEN»`, keystone §B):**

- `mem_clobber.{may_clobber, may_write_memory}` — the may-clobber oracle. `may_clobber(e, f)` is
  `True` unless it proves evaluating `e` writes no bytes aliasing `f`, does not `MemGrow`, and calls
  nothing out; it **reuses the Phase-9 `mem_ssa.alias` lattice**, so a store to a `NoAlias` footprint
  (a disjoint offset off the same base) does **not** clobber `f`. `may_write_memory(e)` is the
  coarser footprint-independent gate (`True` if `e` may write **any** linear memory, grow, or call).
- `mem_ssa.{Avail, Footprint, alias, footprint_of, byte_width, ...}` and `pass.{Pass, run_pipeline}`,
  `ir/effect.{is_pure}` — all Phase-9 surface, unchanged.

**Produce (cross-CF slice, single-owner-additive):**

- `src/twocore/middle/ir_opt/mem_forward.gleam` — replace the `avail`-for-continuation at an
  `If`/`Block`/`Switch` head from `dict.new()` (clear) to a **may-clobber filter**; import
  `mem_clobber`. Loop/Try keep the clear. (§A.)
- `src/twocore/middle/ir_opt/mem_dse.gleam` — make the cross-CF DSE look-through **explicit and
  documented** at the control-flow head, gated by `may_write_memory` + the Phase-9 `is_pure`
  confirmation, and record the deferral of the richer read-through. (§B.)
- `test/twocore/optimize/cross_cf_test.gleam` (**NEW**) — the cross-CF positive fixtures, the
  adversarial "must-NOT" fixtures, and the end-to-end BEAM value/trap differentials. (§Verification.)
- `test/twocore/optimize/mem_forward_test.gleam` — **UPDATE** the Phase-9 scope-limit test
  `no_forward_across_control_flow_boundary_test` (it now forwards) + an adversarial sibling. (§ test
  note.)

**No pipeline edit.** `ir_opt.pipeline(Baseline)` is unchanged; unit 07 is the only editor of the
registration point. The corpus is **result-identical** after this unit (the passes are wired in unit
07; here they only gain reach where the oracle licenses it).

---

## A. Forwarding / RLE across a no-clobber `If`/`Block`/`Switch` (`mem_forward`)

Today `mem_forward.rewrite_rhs`, at a `Let(names, <control-flow head>, body)`, recurses into the head
via `optimize_control` (each child optimized as a **fresh** region) and threads **`dict.new()`** — a
clear — into the continuation `body`:

```gleam
// Phase-9 (current):
ir.If(..) | ir.Switch(..) | ir.Loop(..) | ir.Block(..) | ir.Try(..) -> #(
  optimize_control(rhs, types, globals),
  dict.new(),        // clear avail for the continuation — the per-region reset (M8)
)
```

**Phase-10 change.** Split the arm. `Loop`/`Try` keep the clear. For `If`/`Block`/`Switch`, keep each
`avail` entry `f ↦ v` for which **every** control-flow child provably does not clobber `f`:

```gleam
// Phase-10:
ir.If(..) | ir.Switch(..) | ir.Block(..) -> #(
  optimize_control(rhs, types, globals),  // children still optimized as FRESH regions (unchanged)
  carry_across(rhs, avail),               // survive: entries no child may clobber
)
ir.Loop(..) | ir.Try(..) -> #(
  optimize_control(rhs, types, globals),
  dict.new(),                             // full barrier — Phase-9 behaviour (stated scope limit)
)

/// Keep exactly the `avail` entries whose footprint NO control-flow child of `head` may clobber
/// (write-aliasing, grow, or call out). Any entry a child might perturb is dropped — that footprint
/// falls back to the Phase-9 reset. `head` is an `If`/`Block`/`Switch`; `control_children` lists its
/// branch bodies. Reuses `mem_ssa.alias` (via `may_clobber`): a store to `base+4` inside a branch
/// does NOT clobber `base+0`, so that entry survives.
fn carry_across(head: Expr, avail: Avail) -> Avail {
  let children = control_children(head)
  dict.filter(avail, fn(f, _v) {
    list.all(children, fn(child) { !mem_clobber.may_clobber(child, f) })
  })
}

/// The control-flow children of an `If`/`Block`/`Switch` — the subtrees an execution may take.
///   If     → [then_branch, else_branch]
///   Block  → [body]
///   Switch → [default, ..arm bodies]           (every arm AND the default are reachable)
fn control_children(head: Expr) -> List(Expr) {
  case head {
    ir.If(_, _, t, e) -> [t, e]
    ir.Block(_, _, body) -> [body]
    ir.Switch(_, _, arms, default) ->
      [default, ..list.map(arms, fn(a) { a.body })]
    _ -> []   // Loop/Try never reach carry_across (handled by the clearing arm)
  }
}
```

So `store(F, v); if (c) {…no F write…}{…no F write…}; load(F)` now forwards `v` across the `if`: both
arms are `may_clobber(arm, F) == False`, so `avail[F] = v` survives into the continuation and the
tail `load(F)` is a `MustAlias` hit → `Values([v])` (the `MemLoad` is gone). A `Switch` forwards only
when **every** arm *and* the default are clobber-free; a `Block` when its body is.

**Only the continuation is affected.** `optimize_control` is **unchanged** — each branch is still
optimized as a **fresh** region (empty `avail`). This unit does **not** carry `avail` *into* the
branches (forwarding an outer store into a branch is a separate, harder motion), only *past* the whole
head into what follows it. And the change lives only where a control-flow head is a `Let` **rhs** (has
a continuation); `region_tail` (a head that *is* the region tail, with nothing after it) is unchanged
— there is no continuation `avail` to carry.

---

## B. DSE look-through a no-clobber control-flow region (`mem_dse`)

`mem_dse.shadowed` peels leading **pure** `Let` frames between an earlier store `store1(f1)` and a
candidate shadowing store, stopping at the first non-pure node:

```gleam
// Phase-9 (current):
case effect.is_pure(rhs) {
  True  -> shadowed(f1, inner)        // a pure frame is inert — keep peeling
  False -> case rhs { ir.MemStore(..) as store2 -> <MustAlias?> ; _ -> False }
}
```

**A subtlety worth stating plainly (it shapes the whole DSE change): DSE deletes the *earlier* store,
whose out-of-bounds trap must be preserved on *every* path** (the mem_dse module doc: if `f1` is OOB,
the original traps `MemoryOutOfBounds` **at `store1`**; the optimized must trap the same reason at the
shadowing `store2`). That is why Phase-9 requires the between-nodes to be `is_pure` — deep-pure means
**trap-free and effect-free**, so nothing between can fire an effect or a *different* trap on the path
where the original already trapped at `store1`. Forwarding (§A) has no such hazard: it deletes a
**later, dominated** load that a preceding *successful* store already proved in-bounds — so a
footprint-only `may_clobber` gate is exactly right there. DSE's bar is strictly higher.

**Consequence for the gate.** `may_clobber`/`may_write_memory` reason about **linear memory**
(write-alias / grow / call). They do **not** catch a `GlobalSet` (writes a global, not linear
memory), a `MemLoad` that *reads* `f1`, or a non-OOB trap (`div`) — each of which
`may_write_memory` reports as `False` yet each of which breaks DSE's trap-preservation across a
deleted `store1`. So `may_write_memory(R) == False` is a **necessary but not sufficient** DSE gate.
The **sufficient** confirmation is Phase-9's `is_pure(R)` (barrier-free ⇒ no `GlobalSet`, no
`MemLoad`, no non-OOB trap, no escaping `Break`/`Return`/`Continue`/`Throw`).

**Phase-10 change — make the cross-CF DSE look-through explicit, gated soundly:**

```gleam
// Phase-10: at a control-flow head reached mid-peel, look THROUGH it iff it is provably inert
// between the two stores. `may_write_memory == False` is the fast, footprint-independent
// NECESSARY pre-check (no linear-mem write/grow/call); `is_pure` is the SUFFICIENT confirmation
// (also rules out global/table writes, non-OOB traps, and escaping control — none of which
// `may_write_memory` catches). Any doubt ⇒ keep Phase-9 behaviour (stop the peel).
case effect.is_pure(rhs) {
  True  -> shadowed(f1, inner)
  False ->
    case rhs {
      ir.MemStore(..) as store2 -> <MustAlias?>
      ir.If(..) | ir.Block(..) | ir.Switch(..) ->
        // control-flow head that is NOT deep-pure: peel through ONLY if inert.
        case mem_clobber.may_write_memory(rhs) {
          True  -> False                          // writes/grows/calls → keep store1
          False -> peel_through_inert(f1, rhs, inner)
        }
      _ -> False
    }
}
```

**`peel_through_inert` — the sound realization (kept simple).** Because DSE's bar is
trap-preservation across the deleted `store1`, the **simple sound** predicate is exactly Phase-9's
`is_pure`: peel through `R` iff `is_pure(R)` (which, given we are in the `False`-of-`is_pure` arm,
means `peel_through_inert` conservatively returns `False` — i.e. a control-flow region that
`may_write_memory` cleared but `is_pure` rejects is **kept**). The net behavioural effect of the DSE
change is therefore to **make the cross-CF look-through explicit and self-documenting** — Phase-9's
`is_pure` peel *already* crosses a **fully-pure** `If`/`Block`/`Switch` (all branches deep-pure) in
its `True` arm, so `store(F,v1); if(c){}{}; store(F,v2)` already removes `store1` — while nailing the
sound boundary so a future agent cannot widen it to the unsound `may_write_memory`-only gate. **The
richer, genuinely-additive read-through** — peeling through a region that only *reads* footprints
`NoAlias` with `f1` (and can trap only `MemoryOutOfBounds`, matching `store1`'s own possible trap), or
reads a global — is **sound but deferred**: it needs a per-load alias proof plus the "only-OOB-trap"
argument, which is more than the frozen oracle provides and more than "simple." Left for a later unit
(see "What this unit leaves").

> **Honest framing.** The substantive Phase-10 cross-CF win is in **forwarding** (§A), where the
> may-clobber gate is exactly the right, sufficient tool. DSE's cross-CF reach is bounded by its
> higher trap-preservation bar to the pure-region case Phase-9 already handles; this unit documents
> and pins that, adds the `may_write_memory` fast pre-check as the extension point, and defers the
> read-through. This is called out again as a consistency concern for the planner.

---

## Soundness (N3 — the required section)

**The invariant.** A memory fact `f ↦ v` (or "the bytes at `f` are unobserved-since-`store1`")
survives a control-flow subtree **iff no execution of that subtree could write bytes aliasing `f`,
grow memory, or call out** — exactly `may_clobber(child, f) == False` for **every** control-flow
child. The may-clobber oracle is the **safety gate**: it defaults to `True` (clobber), and returns
`False` only with a structural proof, so any doubt ⇒ clobber ⇒ the entry is dropped ⇒ **precisely
Phase-9's per-region reset** for that footprint. Phase-9 is the special case "every child clobbers."

**Forwarding is trap-preserving across a no-clobber `If`/`Block`/`Switch`.** Forwarding still rests on
a **dominating successful store** (Phase-9 §D): control reaches the forwarded load only by passing
through `store(F, v)`, which is **unchanged** by this unit — so if `F` were OOB the store still traps
`MemoryOutOfBounds` at the same point in both programs and the load is never reached. Given the store
**succeeded**, `F` is in-bounds; carrying `avail[F] = v` across an `If`/`Block`/`Switch` whose every
child is `may_clobber(child, F) == False` is sound because the memory at `F` is **unchanged on every
path** through the subtree (no aliasing write on any branch, no grow — `F` stays in-bounds — and no
call that could touch memory). On the fall-through path the continuation load is a `MustAlias` hit and
reads exactly `v`; on any path that leaves the region (a branch `Break`/`Return`) the load is not
reached, so forwarding it is vacuous. The pass still **removes/replaces only a load**, never reorders
an effect and never introduces a call (D3a). The forwarded `Value` is a reference (`Var`/`Const`), and
under D6 unique-name SSA it re-reads the same bits everywhere it is in scope — no staleness.

**The `NoAlias` disambiguation carries across too.** `may_clobber` reuses `mem_ssa.alias`: a store to
`base+4` inside a branch is `NoAlias` with `base+0`, so `may_clobber(branch, base+0) == False` and the
`base+0` fact **survives** the `If` — the cross-CF form of Phase-9's disjoint-offset (Array-SSA)
disambiguation. A branch that stores to a `MayAlias`/`MustAlias` footprint of `f`, that grows, or that
calls out ⇒ `may_clobber == True` ⇒ the entry is dropped.

**DSE's higher bar (why §B is conservative).** DSE deletes the *earlier* store, so its cross-CF
look-through must preserve `store1`'s OOB trap on **every** path: nothing between may fire an effect
or a non-`MemoryOutOfBounds` trap (else the store1-OOB path diverges), and nothing may observe
`store1`'s value. `may_write_memory == False` does not rule out a `GlobalSet`, a `MemLoad` of `f1`, or
a `div` — the sound gate is `is_pure`. This unit therefore keeps DSE's cross-CF reach at the pure
region (the `True`-of-`is_pure` peel Phase-9 already performs) and defers the richer read-through.

**Trust-neutral, pure IR.** Both edits are pure IR→IR over existing nodes — no new node, no runtime
touch, no ambient authority (D3a). They run at all tiers and both modes, exactly like Phase 9. The
soundness gate is the frozen `mem_clobber` oracle (adversarially pinned in unit 01), not new
judgement here — this unit only *consumes* it.

---

## The Phase-9 test change (flag explicitly)

`mem_forward_test.no_forward_across_control_flow_boundary_test` (Phase 9) asserted that
`store(p,v); if(c){}{}; load(p)` is **NOT** forwarded, encoding the Phase-9 **scope limit** ("memory
knowledge does NOT cross a control-flow boundary"). **Phase 10 lifts that limit** — the empty branches
do not clobber, so the load **now forwards** and **should**. This unit **must update that test**:

- **Update** the empty-`If` case to assert it **now forwards**: the tail `load(p)` becomes
  `Values([Var("v")])`. Rename it to reflect the new contract (e.g.
  `forwards_across_no_clobber_if_test`), and update the comment (the old "per straight-line region,
  M8" rationale is superseded by N3).
- **Add** an adversarial sibling `store(p,v); if(c){ store(p,w) }{}; load(p)` that must **NOT**
  forward: the then-branch stores `p` (`may_clobber(then, F) == True`), so `avail[F]` is dropped and
  the tail stays a `MemLoad`.

This is the one Phase-9 assertion Phase 10 deliberately reverses; it is a **contract change**, not a
regression. The adversarial sibling guards the reversal from over-firing. Both the updated positive
case and the adversarial case are also mirrored in the new `cross_cf_test.gleam` (with the end-to-end
BEAM differential); the in-place edit keeps `mem_forward_test` honest about the pass's new reach.

---

## Termination (N7)

Unchanged. Cross-CF MemorySSA **only removes accesses** — forwarding/RLE rewrite a `MemLoad` to
`Values`, DSE removes a `MemStore` — so `n_mem` (the most-significant component of
`μ₉ = (n_mem, n_loops, n_ops, n_nodes, n_vars)`) is monotonically non-increasing and every *changing*
rewrite strictly decreases it, exactly as in Phase 9. No pass constructs a `MemLoad`/`MemStore`; no
new node is added; the fixpoint measure is the Phase-9 one, so appending these (unit 07) keeps the
`run_pipeline` fixpoint well-founded. The `may_clobber` filter never adds an entry — it only *keeps a
subset* of `avail` — so it cannot loop.

---

## Verification (Definition of Done — D8)

Tests assert **spec/analysis behaviour** and the **soundness invariant** (a fact survives a subtree
iff no child may clobber it), cite the reasoning, and are **not** change-detectors. Passes are run in
isolation via `pass.run_pipeline(m, [mem_forward.forwarding_pass()])` /
`[mem_dse.dead_store_pass()]`; end-to-end runs compile IR → `emit_core` → BEAM → invoke on the real
BEAM (the `pipeline.ir_to_core → core_to_beam → instantiate → invoke_instance` recipe the Phase-9 tests
use), under `profiles.safe()`.

**(a) Forward across a no-clobber `If`/`Block`.** `store(F, v); if (c) {…no F write…}{…no F write…};
load(F)` → the tail `MemLoad` is **gone** (rewritten to `Values([v])`), proving the fact crossed the
`If`. A `Block` variant (`store; block l { …no F write… }; load`) and a `Switch` variant (every arm +
default clobber-free) forward likewise. **End-to-end:** the optimized and unoptimized modules return
**bit-identical** values for an in-bounds base and **both** trap `MemoryOutOfBounds` at the *store*
for an OOB base (the store the forward left untouched proved in-bounds).

**(b) DSE look-through a pure `If` to a shadowing store.** `store(F, v1); if (c) {}{}; store(F, v2)`
→ `store1` is removed (the shadowing `MustAlias` `store2` is found through the pure `If`). Pin that
this cross-CF DSE holds and that its sound boundary is the pure region; end-to-end the final memory is
`v2` and an OOB base traps at `store2`.

**(c) Adversarial "must-NOT" (the tripwires — each asserts the rewrite does NOT fire).**
- **a branch that stores `F`** — `store(F,v); if(c){ store(F,w) }{}; load(F)`: `may_clobber(then, F)
  == True` ⇒ `avail[F]` dropped ⇒ the load **survives** (not forwarded).
- **a branch that stores a `NoAlias` offset** — `store(F=base+0, v); if(c){ store(base+4, w) }{};
  load(base+0)`: `may_clobber(branch, base+0) == False` ⇒ the load **still forwards** (the positive
  proof that the filter is precise, not a blanket reset — the cross-CF Array-SSA case).
- **a branch that calls / grows** — `store(F,v); if(c){ CallHost(..) }{}; load(F)` and the `MemGrow`
  variant: `may_clobber == True` ⇒ **not** forwarded.
- **a branch that `Break`s past the load** — `store(F,v); if(c){ Break(outer,..) }{ store(F,w) };
  load(F)`: the clobbering else-branch drops the fact ⇒ not forwarded (and the DSE analogue: a branch
  that could `Break`/`Return` past a candidate `store2` is **not** looked through — Phase-9 behaviour).
- **DSE through a side-effecting region is blocked** — `store(F,v1); if(c){ global.set g, x }{};
  store(F,v2)`: the `If` is `may_write_memory == False` (a `GlobalSet` writes a global, not linear
  memory) **but** `is_pure == False`, so the peel **stops** and `store1` is **kept** — the fixture
  that pins why `may_write_memory` alone is an insufficient DSE gate.
- **`Loop`/`Try` stay barriers** — `store(F,v); loop l { … }; load(F)` and the `Try` variant are
  **not** forwarded across (full clear), matching the honest scope limit.

**(d) Green DoD, WASM result-identical.** `gleam format --check src test` clean; `gleam build` **zero
warnings** (every function total — no `todo`/`panic`/`let assert` on a live path); `gleam test` ≥
baseline + the new/updated tests, 0 failures; the WASM corpus **result-identical** under both profiles
and every tier (this unit is unwired — `optimize` is unchanged until unit 07 registers the passes).
Every new/edited public function carries a `///` contract doc; the updated Phase-9 test's comment
reflects the N3 contract change.

**Proof of goal:** forwarding/RLE carry a memory fact across an `If`/`Block`/`Switch` exactly when the
may-clobber oracle proves no branch perturbs the footprint (Phase-9's reset as the "everything
clobbers" special case), each direction pinned by an adversarial fixture and proven trap- and
bit-neutral on the real BEAM — so unit 07 can wire the relaxed passes and the corpus differential
stays result-identical while more redundant accesses disappear across control flow.

---

## What this unit leaves for others

- **Unit 07 (capstone)** wires `forwarding_pass()` + `dead_store_pass()` (now with cross-CF reach)
  into `ir_opt.pipeline/1` and proves the corpus differential across every tier and both modes; the
  cross-CF fixtures here are its per-pass evidence.
- **The richer DSE read-through (deferred, sound).** Peeling `store1` through a control-flow region
  that only **reads** footprints `NoAlias` with `f1` (or reads a global) — sound because such a region
  changes no value `store1` could have written and can trap only `MemoryOutOfBounds` (matching
  `store1`'s own possible OOB trap). It needs a per-load alias proof plus the "only-OOB-trap"
  argument; this unit keeps Phase-9 behaviour (stop the peel) there, per "prefer the simple sound
  version" and "if uncertain, keep Phase-9 behaviour."
- **`Loop`/`Try` cross-CF (deferred).** Carrying a fact across a loop needs a proof it survives the
  back-edge (loop-invariance of the footprint's non-clobber across iterations); across a `Try` needs
  modelling the mid-body jump to a handler. Both stay full barriers — a stated scope limit, not a
  claim they are unanalyzable.
- **Carrying `avail` *into* branches (deferred).** This unit carries a fact *past* an `If`/`Block`/
  `Switch`, not *into* its arms (forwarding an outer store to a load **inside** a clobber-free branch
  is a further, sound motion left to a later unit).
