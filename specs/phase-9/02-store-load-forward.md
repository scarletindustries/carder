# Phase 9 · Unit 02 — store→load forwarding + redundant-load elimination (`mem_forward`)

> **One owner · Wave C-parallel (with unit 03) · freeze dep `«MEM-SSA-FROZEN»`.** Read
> [`00-overview.md`](00-overview.md) (M1–M8) and [`01-mem-ssa-keystone.md`](01-mem-ssa-keystone.md)
> (the frozen analysis surface this unit **consumes**) first; the design note
> [`../future-work-memory-optimizer.md`](../future-work-memory-optimizer.md) and Phase-1 D1–D10,
> Phase-2 E1–E8, Phase-3 F1–F8 still hold. This unit ships **one** optimizer pass —
> `pub fn forwarding_pass() -> pass.Pass` — that realizes **both** rewrites the overview names.
> **The reconciliation, stated up front:** *store→load forwarding* and *redundant-load elimination*
> are the **same transfer function** over **one** unified reaching-value map (`mem_ssa.Avail`). A
> load is served from `avail` whether that entry was put there by a preceding **store** (forwarding)
> or a preceding **load** (RLE) — there is no second pass, no second map, no second walk. So the
> overview's two names (`store_load_forward` / `redundant_load_elim`) collapse into the single
> `forwarding_pass()` this unit exports; unit 04 wires *that one pass*. The pass is registered
> **nowhere** in this unit — it ships tested in isolation, so the corpus stays **byte-identical**
> after unit 02 (unit 04 is the only edit to `ir_opt.pipeline`).

---

## Context

Phase 3's `ir/effect.gleam` **deliberately forbids all load CSE** (`can_cse` is "the strongest
sound under-approximation … *because we had no memory-dependence analysis yet*"). Unit 01 built that
analysis — the access-footprint model, the `alias` oracle, the `is_memory_barrier` classifier, the
`Avail` map type, the `byte_width` truncation primitive, and the `n_mem` termination component — and
landed it **green with the pipeline still empty** (identity). **This unit is the first consumer.** It
turns the analysis into a rewrite: a `pass.per_function`-shaped scope-aware walk that threads the
`avail` map through each **straight-line region** front-to-back and, at each memory access, either
**serves a load from a value already in hand** (removing the load) or **records the value it makes
available** for a later load.

The analysis is **intraprocedural and per straight-line region** (M8): the walk resets its memory
knowledge at every control-flow boundary (`If`/`Switch`/`Loop`/`Block`/`Try`) — those are barriers
in the keystone's `is_memory_barrier`. Within a region the walk is exactly the shape of Phase-3's
`propagate_and_drop`/`dead_let` (a scope-aware `Let`-chain walk that carries an environment the
effect-agnostic `map_expr` combinator cannot), except the environment it threads is the pair
`(avail, types)` rather than a substitution.

The load-bearing correctness fact is **M3, trap-preservation**: a WASM `MemLoad`/`MemStore` is
*trap-or-access*, **not** a pure read/write (spec
[exec/instructions §Memory](https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions):
every access first checks `ea + N/8 ≤ |mem|` and **traps** otherwise). Every rewrite here is legal
**only** because a **dominating successful access in the same region** already proved the address
in-bounds — so the removed/forwarded access could not have trapped. §D makes that argument precise;
the whole soundness of the pass rests on it and on the keystone's `alias`/`byte_width` being sound.

---

## Deliverables & freeze milestones

**Consume (frozen upstream — `«MEM-SSA-FROZEN»`, keystone §A):**

- `mem_ssa.{Footprint, AliasResult, MustAlias, NoAlias, MayAlias, Avail, footprint_of, alias,
  is_memory_barrier, byte_width, count_mem_ops}` — the analysis vocabulary. This unit performs the
  **transfer function** the keystone's `Avail` doc comment reserves for it ("Unit 02 owns the
  transfer function that maintains it — insert on store/load, invalidate on aliasing store, clear on
  a barrier"). It **re-derives none** of the analysis: `footprint_of` extracts footprints, `alias`
  answers every disambiguation, `is_memory_barrier` answers every "must I forget?", `byte_width`
  drives the truncation guard.
- `pass.{Pass, per_function, run_pipeline}` (Phase-3 unit 01) — the pass machinery. `run_pipeline`
  is used by the tests to run *this pass in isolation* (`run_pipeline(m, [forwarding_pass()])`),
  since the pipeline does not yet contain it.
- `ir.gleam` (`«IR4-FROZEN»`) — `MemLoad(mem, op, addr, offset, result)`,
  `MemStore(mem, op, addr, value, offset)`, `MemAccess(bytes, signed)`, `Value`, `ValType`,
  `Local(name, ty)`, `Function(params, locals, …)`, `GlobalDecl(name, ty, …)`. **No IR change** (M4).

**Produce (`mem_forward`, single-owner):**

- `src/twocore/middle/ir_opt/mem_forward.gleam` (**NEW**, owned) — `pub fn forwarding_pass() ->
  pass.Pass` and its private region walk + transfer function + the small name→`ValType` environment.
- `test/twocore/optimize/mem_forward_test.gleam` (**NEW**) — the positive fixtures (forward, RLE),
  the adversarial "must-NOT-forward" fixtures, the bit-identity fixture (D5), and the end-to-end
  BEAM differentials.

**Import hygiene (all acyclic — none imports `ir_opt`):**
`mem_forward` imports `{twocore/ir, twocore/ir/effect, twocore/middle/ir_opt/pass,
twocore/middle/ir_opt/mem_ssa, gleam/dict, gleam/list}`. The edge `mem_forward → mem_ssa → {ir,
ir/effect}` and `mem_forward → pass → ir` are both acyclic (exactly as `baseline → pass`), so this
unit builds without touching the `ir_opt` entry point.

**No pipeline edit.** `ir_opt.pipeline(Baseline)` stays `baseline.baseline_passes()`. The corpus is
**byte-identical** after this unit — it adds a module + tests only. Unit 04 appends
`forwarding_pass()` to the `Baseline` arm (inherited by `Aggressive`); *that* is where the corpus
differential and the speedup are proven.

---

## A. Binding to the keystone: the pass shape and the transfer function

`forwarding_pass()` is registered as **one** named pass. Because the truncation guard wants a
`GlobalGet`'s **declared** type (a fact that lives on `module.globals`, not on the `GlobalGet` node),
the pass is a whole-module `pass.pass` whose core is a **per-function region walk** — a thin
whole-module wrapper that first precomputes the module's global name→type table, then runs the
per-function walk over each function seeded from `params ++ locals`. This is exactly analogous to how
`pass.per_function` is itself a thin whole-module wrapper around a per-function transform; we spell it
out here only because the per-function core needs the module-level global table the plain
`per_function` combinator does not thread.

```gleam
//// middle/ir_opt/mem_forward — store→load forwarding + redundant-load elimination (M1/M3).
//// ONE pass, ONE reaching-value map: a load is served from `avail` whether the entry came from a
//// preceding store (forwarding) or a preceding load (RLE) — the SAME transfer function. Consumes
//// the frozen `mem_ssa` surface; performs no analysis of its own. Imports
//// {ir, ir/effect, pass, mem_ssa, dict, list} — all acyclic (none imports ir_opt).

import gleam/dict.{type Dict}
import gleam/list
import twocore/ir
import twocore/middle/ir_opt/mem_ssa.{type Avail, type Footprint}
import twocore/middle/ir_opt/pass.{type Pass}

/// The store→load-forwarding + redundant-load-elimination pass (M1/M3). Threads one
/// `mem_ssa.Avail` map through each straight-line region: a natural-width load whose footprint is
/// already in `avail` is replaced by `Values([that_value])` (the load node is GONE — baseline
/// copy-prop drops the residual `Let` on the next fixpoint round); a load that misses records its
/// bound name; a store invalidates every aliasing entry and, when non-truncating, inserts its
/// value; a barrier clears the map. Semantics-preserving (F2/M3): it removes/replaces a load
/// guarded by a dominating successful access, never reorders an effect, never adds a call (D3a).
/// Total.
pub fn forwarding_pass() -> Pass {
  pass.pass("mem-forward", fn(m) {
    let globals = global_types(m)
    ir.Module(
      ..m,
      functions: list.map(m.functions, fn(f) {
        let types0 = seed_types(f)  // params ++ locals, all `Local(name, ty)`
        ir.Function(..f, body: forward_region(f.body, dict.new(), types0, globals))
      }),
    )
  })
}
```

**The region walk.** `forward_region` processes a maximal straight-line `Let`-chain, threading the
pair `(avail, types)` from one binding to the next. A region **begins empty** (`dict.new()` for
`avail`) at the function body and at every control-flow child; `types` carries **into** children
(name→type is monotone and scope-stable) while `avail` is **reset** at every boundary.

```gleam
/// Walk one straight-line region front-to-back. `avail` is the reaching-value map (empty at a
/// region head); `types` is the name→ValType environment; `globals` the module global types.
fn forward_region(
  e: ir.Expr,
  avail: Avail,
  types: Dict(String, ir.ValType),
  globals: Dict(String, ir.ValType),
) -> ir.Expr {
  case e {
    // straight-line binding: rewrite the rhs in-context, thread the post-state into the body.
    ir.Let(names, rhs, body) -> {
      let #(rhs2, avail2, types2) = step(names, rhs, avail, types, globals)
      ir.Let(names, rhs2, forward_region(body, avail2, types2, globals))
    }
    // the region TAIL is a control-flow head or a leaf — no straight-line continuation follows.
    _ -> region_tail(e, types, globals)
  }
}
```

`step` is the transfer function proper (§B). `region_tail` handles an expression that ends a region:
a control-flow head (`If`/`Switch`/`Loop`/`Block`/`Try`) recurses into each sub-expression as a
**fresh** region (empty `avail`, `types` carried in — loop params added); a leaf (`Values`/`Break`/
`Return`/…) is returned unchanged.

---

## B. The transfer function, node by node (`step`)

Over a binding `Let(names, rhs, body)`, `step` inspects `rhs` and returns the rewritten `rhs` plus
the `(avail, types)` to thread into `body`. Four cases, in priority order.

### B.1 — `rhs` is a natural-width `MemLoad(F)`

`F = footprint_of(rhs)` (keystone). The load is **natural-width** iff `op.bytes == byte_width(result)`
(§C) — the exact-footprint case where the loaded value *is* the byte range verbatim, not a
zero/sign-extended transformation of it.

- **Hit** — `dict.get(avail, F)` is `Ok(v)`. An entry keyed by the identical `Footprint` is a
  `MustAlias` lookup **by construction** (keystone: equal footprints ⟹ `MustAlias`), so the value at
  those bytes is exactly `v`. **Rewrite the rhs to `Values([v])`** — the `MemLoad` node is gone. This
  is store→load forwarding when `v` was inserted by a store, redundant-load elimination when `v` is
  the `Var` a prior load bound; the walk does not distinguish, and does not need to. `avail` is
  unchanged (`F` still maps to `v`); `types` records the binding's type as `result`.
- **Miss** — record the load as a future source: loads bind **exactly one** name (`[y]`, keystone
  lowering), so **insert `avail[F] = ir.Var(y)`**. Keep the load (it is the first access to `F`).
  `types` records `y ↦ result`.

A **sub-width** load (`op.bytes != byte_width(result)`, e.g. `i32.load8_u`) is left untouched and is
**never inserted** into `avail`: its result is a transformation of the bytes, not their content
(§C), so it is neither a valid forward target nor a valid future source. `types` still records its
bound name's type.

### B.2 — `rhs` is a `MemStore(F, value)`

Two effects, in order:

1. **Invalidate.** Drop every `avail` key `K` with `alias(K, F) != NoAlias` — an aliasing store
   clobbers those bytes, so any value previously known there is stale. Keys with `alias(K, F) ==
   NoAlias` **survive** (the disjoint-offset disambiguation, keystone §B: a store to `base+0`/4B does
   not clobber the known value at `base+4`/4B). This is a `dict.filter` keeping the `NoAlias` keys.
2. **Insert (only if non-truncating).** If `op.bytes == byte_width(type_of(value, types))` — the
   store writes its value **un-narrowed** (§C) — insert `avail[F] = value`. A **truncating** store
   (`i32.store8`, `i64.store32`, …) **invalidates but does not insert**: it wrote only the low
   `op.bytes` of a wider value, so forwarding the whole `value` into a later natural-width load slot
   would forward bits that load never sees.

`MemStore` binds `[]` (zero-result effect, keystone lowering), so `types` is unchanged. When
`type_of(value)` is **unknown** (an unrecorded `Var`), the store is conservatively treated as
**not a forward source** — invalidate, do not insert.

### B.3 — `rhs` is a barrier

`is_memory_barrier(rhs)` is `True` — a call (`CallDirect`/`CallIndirect`/`CallHost`/`CallImport`/
`CallClosure`), `MemGrow`, a bulk-memory op (`MemFill`/`MemCopy`/`MemInit`/`DataDrop`), a
SIMD-memory op (`SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`), a control transfer
(`Trap`/`Throw`/`ThrowRef`/`Return`/`Break`/`Continue`), or a structured region head
(`If`/`Switch`/`Loop`/`Block`/`Try`). **Clear `avail` entirely** (`dict.new()`) — the barrier may
read, write, reallocate, or leave the region, so nothing known about memory survives it.

For a **region head** specifically, first **recurse into each sub-expression as a fresh region**
(`forward_region(child, dict.new(), types', globals)`, `types'` = `types` plus any loop params) so
the interior is still optimized, then continue the outer region with `avail` cleared. For an opaque
barrier (a call, `MemGrow`, a bulk/SIMD-mem op) there are no sub-`Expr`s to recurse into (they carry
only `Value` operands), so the node passes through unchanged with `avail` cleared. `types` records
the binding's type only when it is statically inferable (§B.5) — for a region head, from its declared
`result` when that is a single value type, else the binding is left unknown.

### B.4 — `rhs` is memory-transparent

Everything else — `GlobalGet`/`GlobalSet` (the globals cell is disjoint from linear memory and
cannot trap, keystone M5), and the pure value ops (`Values`/`Num`/`Convert`/`TermOp`/`Simd`/…). These
do **not** touch linear memory, so **`avail` is unchanged**. `types` is extended when the rhs result
type is inferable (§B.5). The store-value it might feed is recorded for the truncation guard.

### B.5 — The `types` environment (the truncation-guard input)

`types: Dict(String, ir.ValType)` maps in-scope names to their value type. It is the *only* state
this unit adds beyond the keystone's `avail`, and it exists **solely** to run the store truncation
guard (§C) — a store forwards a value faithfully only if we know that value's width.

- **Seeded** from the function's `params ++ locals` (all `Local(name, ty)`) — these are the names in
  scope at the body.
- **Extended** at a `Let(names, rhs, body)` whose rhs result type is statically inferable:
  a `MemLoad`'s `result`; a `Num`/`Convert`'s result width (from the op); a `Const*`'s type
  (`ConstI32→TI32`, `ConstF64→TF64`, …); a `GlobalGet(name)`'s declared type (looked up in the
  precomputed `globals` table). Types carry **into** control-flow children (they are in scope there).
- **Conservative default.** A binding whose rhs type is *not* inferable (a call result, a region-head
  result of mixed arity, anything unlisted) records **nothing** — the name stays unknown, and a store
  of an unknown-typed value is **not** a valid forward source (§B.2). Unknown ⟹ no forward is always
  the safe direction (a missed optimization, never an unsound one).

`type_of(value, types)` resolves a `Value`: a `Const*` yields its type directly; a `Var(n)` yields
`dict.get(types, n)` (or `Error(Nil)` when unknown).

---

## C. The truncation guard / natural-width rules (keystone §C, `byte_width`)

Two accesses with the **same** `Footprint` still do not move a value faithfully unless **both are
natural-width** — the hazard the keystone put `byte_width` in the analysis surface to exclude. An
access is **natural-width** iff its declared width in bytes equals the natural in-memory width of its
value type:

```gleam
/// A load/store is *natural-width* iff `op.bytes == byte_width(t)` — it moves the whole value
/// un-narrowed / un-extended. Reference/term types (`byte_width == Error`) are never natural-width.
fn is_natural_width(op: ir.MemAccess, t: ir.ValType) -> Bool {
  case mem_ssa.byte_width(t) {
    Ok(w) -> op.bytes == w
    Error(_) -> False
  }
}
```

- **Sub-width load excluded as a forward *target*** — `i32.load8_u`: `op.bytes = 1`,
  `result = TI32`, `byte_width(TI32) = 4`. It zero/sign-extends one byte into a 4-byte value; the
  loaded value is a *transformation* of the bytes, not their content. §B.1 forwards a load only when
  `is_natural_width(op, result)`.
- **Truncating store excluded as a forward *source*** — `i64.store32`: `op.bytes = 4`,
  `value: TI64`, `byte_width(TI64) = 8`. It writes the low 4 bytes of an 8-byte value; forwarding the
  whole `i64` into a later 4-byte load slot would forward bits the load never reads. §B.2 inserts a
  store only when `is_natural_width(op, type_of(value))`.

**Why natural-width forwarding is bit-exact even across value types (the D5 point).** When a
natural-width store and a natural-width load share a `Footprint`, they move the identical
`bytes`-byte range. Because 2core carries every scalar as its **raw little-endian bit pattern in an
Erlang integer** (D5), an `i32.store` followed by a same-footprint `f32.load` forwards the same
integer bit pattern the `f32.load` would have assembled from those bytes — the `Value` is a faithful
representative regardless of the two ends' `ValType`s, **provided neither truncates nor extends**.
The keystone owns `byte_width`; this unit owns the `type_of`-of-a-value threading (§B.5) because it is
specific to the forwarding transfer function. The verification pins the bit-identity (§Verification
(d)).

---

## D. Trap-preservation — the soundness story (M3)

A WASM `MemLoad`/`MemStore` is **trap-or-access**: `emit_core` routes every one through `rt_mem`'s
bounds check → `rt_trap.raise(MemoryOutOfBounds)`
([exec/instructions §Memory](https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions):
a load/store first checks `ea + N/8 ≤ |mem|` and **traps** if it fails; a load then *reads*, a store
then *writes*). A rewrite is sound **only** if it preserves *when and whether* a trap fires. Both
rewrites this pass performs rest on the same lever: **a dominating successful access in the same
straight-line region proves the address in-bounds.**

**Store→load forwarding.** The region is straight-line, so the store `MemStore(F, v)` **dominates**
the forwarded load `MemLoad(F)` — control reaches the load only by passing through the store. Because
control *did* reach the load, the store **succeeded**: had it trapped `MemoryOutOfBounds`, control
would have left the region and the load would never have run (in the original program *and* in the
optimized one — the store is unchanged, so it still traps in exactly the same place). A successful
store proves its effective address `ea` is in-bounds; `F` being `MustAlias` with the load means the
load's effective address is the **same** `ea`; therefore the load is in-bounds ⟹ removing it removes
an access that **could not have trapped**. No trap is added, none is removed, none moves.

- **Value stability.** The forwarded `Value` is a `Const*` or a `Var(y)`. Under D6 (unique-name /
  per-iteration SSA — the Phase-3 §C invariant): a name denotes **one** value in its scope; params/
  locals/`let`s are unique within a function, and a loop variable is rebound **only** at the
  `Continue` back-edge, which begins a *fresh* region (a barrier here — the loop head clears `avail`).
  So within the region a `Var(y)` re-reads the same bits everywhere it is in scope, and the forwarded
  value reads the exact bits the removed load would have. We forward a **reference**, never a snapshot
  — no staleness, no capture.
- **No clobber between.** Any intervening `MemStore` to a footprint `K` with `alias(K, F) != NoAlias`
  invalidated `avail[F]` (§B.2), so a surviving `avail[F]` entry certifies **no aliasing write**
  reached those bytes; `MayAlias` is treated as a clobber (conservative — the entry is dropped). Any
  barrier cleared the whole map (§B.3). So a hit is only possible when the value at `F` is provably
  unchanged since it was recorded.

**Redundant-load elimination.** Identical argument with the **first load** as the dominating
successful access: the first `MemLoad(F) → y` succeeded (else control left), so a later `MustAlias`
`MemLoad(F)` is at the same in-bounds address and — with no clobber between — reads the same bits `y`
holds. Replacing it with `Values([Var(y)])` removes an access that could not have trapped and reads
the identical value.

**The truncation guard makes it bit-exact across value types.** §C: only natural-width store→load and
load→load pairs move the value un-narrowed / un-extended, so the forwarded `Value` is the exact bit
pattern the removed load would have produced (D5). A sub-width load is never a target and a truncating
store is never a source — the two ways forwarding could change *bits* (not just traps) are excluded in
the keystone's `byte_width` and this unit's guard together.

**Never reorder; never introduce a call.** The pass **removes** a load or **replaces** it with a
value already in hand; it never moves an effect past another, never changes the order of two accesses,
and never constructs a `CallHost`/`apply` or any new node (D3a). Ordering is preserved verbatim — the
`Let`-chain is rebuilt in place, only the rewritten `rhs` differs.

---

## E. Termination (M7 — `n_mem` strictly decreases)

The Phase-3 fixpoint (`pass.run_pipeline`) converges under `μ = (n_loops, n_ops, n_nodes, n_vars)`;
the keystone prepended the most-significant `n_mem = count_mem_ops(m)` (the number of `MemLoad` +
`MemStore` nodes):

```
μ₉(m) = ( n_mem , n_loops , n_ops , n_nodes , n_vars )
```

Every *changing* rewrite this pass performs replaces a `MemLoad` with `Values` ⟹ **`n_mem` strictly
↓** (and adds no `Loop`, no op, no node — `Values([v])` is smaller than the load it replaces). The
pass **never constructs** a `MemLoad` or `MemStore` (nor does any baseline pass — keystone §D), so
`n_mem` is monotonically non-increasing across every `run_pipeline` round and each changing memory
rewrite strictly decreases the most-significant component. `μ₉` is bounded below by `(0,0,0,0,0)`, so
appending `forwarding_pass()` to the pipeline (unit 04) keeps the fixpoint well-founded — the residual
`Let([y], Values([v]), body)` a forward leaves behind is cleaned up by baseline copy-prop on the next
round (itself strictly decreasing the lower-order components), and no pass can undo a forward (nothing
raises `n_mem`). This unit does not touch `run_pipeline`; it only *is* a pass whose changing rounds
decrease the keystone's measure, which is what unit 04's registration relies on.

---

## Effect / soundness note

- **F2/M3 is the bar.** The pass is semantics-preserving: it removes or replaces a load guarded by a
  dominating successful access (§D). It changes the *emitted* code (fewer accesses) but never a
  returned value's bits or a trap — the corpus differential is **result**-identical, not
  byte-identical (M6), which unit 04 proves corpus-wide across every tier and both modes.
- **The soundness gate is the keystone, not this unit.** Forwarding fires **only** on an exact-
  `Footprint` hit in `avail`, which is `MustAlias` by construction; invalidation drops everything
  that is not `NoAlias`; a barrier clears everything. So an unsound rewrite is possible only via an
  unsound `alias`/`is_memory_barrier` — both frozen and adversarially pinned in unit 01. This unit
  adds **no** new alias judgement; it only *consumes* the oracle.
- **No effect is ever reordered, dropped, or duplicated.** A store is never removed here (that is
  unit 03's DSE); it only *populates/invalidates* `avail`. A load is removed only when its value is
  already available and its address provably in-bounds. Ordering is verbatim.
- **No ambient authority (D3a).** The pass emits no call and no `apply`, and fabricates no host/BIF
  target — it is pure IR→IR rewriting over existing nodes.
- **Metering (F5) preserved.** `ir_opt` runs after `ir_lower`, so under Safe the walk sees `Charge`
  nodes. `Charge` is memory-transparent (§B.4 / keystone — it is not a memory barrier) so it does not
  clear `avail`, and it is **never removed or reordered** by this pass — only loads are. So the fuel
  charged on every executed path is unchanged. (A forwarded load's own bounds-check/decode cost is
  runtime work `rt_mem` does, not a `Charge` node, so removing the load removes no metered fuel.)

---

## Verification (Definition of Done — D8)

Tests assert **spec/analysis behaviour** and the **trap-preservation invariant**, cite the reasoning,
and are **not** change-detectors. "Done" = the suite passes — never "it compiles". The pass is run in
isolation via `pass.run_pipeline(m, [mem_forward.forwarding_pass()])` (it is not in the pipeline yet);
end-to-end runs compile IR → `emit_core` → `build_beam` → invoke on the BEAM, using the
`pipeline.ir_to_core → core_to_beam → instantiate → invoke_instance` recipe the existing
`differential_test.gleam` / `pipeline_opt_test.gleam` drive (`run_add`-style).

**(a) Store→load forwarding — the load node is gone, and the BEAM agrees.** A module with
`Let([], MemStore(0, i32(4B), Var(p), Var(v), 0), Let([y], MemLoad(0, i32(4B), Var(p), 0, TI32),
body-using-y))` — a store then a **must-alias natural-width** load through the same base. Assert on
the optimized IR that the `MemLoad` is **gone** (the `y`-binding's rhs is `Values([Var(v)])`), proving
forwarding fired. Then compile **both** the unoptimized module and the forwarded module to the BEAM
and assert the invoked result is **bit-identical** and the trap behaviour identical (in-bounds ⟹ both
return the stored value; an OOB base ⟹ **both** trap `MemoryOutOfBounds` at the *store*, which the
forward left untouched — the store proved in-bounds ⟹ the load could not trap, §D).

**(b) Redundant-load elimination — two must-alias loads collapse.** `Let([y1], MemLoad(F), Let([y2],
MemLoad(F), body))` with `F` the same natural-width footprint and no clobber between → the second
load's rhs becomes `Values([Var(y1)])` (the `MemLoad` gone); end-to-end the value + trap are
unchanged (the first load proved in-bounds).

**(c) Adversarial "must NOT forward" (the tripwires).** Each asserts the load/store **survives**
`optimize` — a future narrowing that forwards any of these is silent memory corruption:
- **across a `MayAlias` store** — a store through a **different** `Var` base between the source store
  and the load (`alias == MayAlias`) invalidates `avail[F]`, so the load is **not** forwarded.
- **across a barrier** — a `CallHost` / `MemGrow` / `MemFill` between source and load clears `avail`
  entirely; the load survives.
- **a sub-width load is never a forward target** — a store to `F` then an `i32.load8_u` at the same
  base+offset (`op.bytes = 1 != 4 = byte_width(TI32)`) is left untouched (§C).
- **a truncating store is never a forward source** — an `i64.store32` to `F` then a natural-width
  load at `F` does **not** forward the `i64` value (the store invalidated but did not insert, §B.2/§C).
- **disjoint same-base offsets do not clobber** — a store to `base+0`/4B does **not** invalidate the
  known value at `base+4`/4B, so a load at `base+4` still forwards **across** the `base+0` store
  (`alias == NoAlias` — the Array-SSA disambiguation, keystone §B). This is the positive proof that
  invalidation is precise, not a blanket clear.

**(d) Cross-type bit-identity (D5).** A module storing an `i32` value to `F` and loading `f32` from
the **same** natural-width footprint: the forwarded `Value` is **bit-identical** to the value the
round-tripped `f32.load` would assemble — proven end-to-end on the BEAM (invoke returns the same raw
bits with and without the forward). This pins the §C claim that raw-bit-pattern scalars forward
faithfully across `ValType`s when neither end truncates.

**(e) Green DoD.** `gleam format --check src test` clean; `gleam build` **zero warnings** (no
`todo`/`panic`/`let assert` on any path — every function total); `gleam test` ≥ baseline (1734) + the
new tests, 0 failures; the WASM corpus **byte-identical** (this unit does not wire the pass, so
`optimize` is unchanged and the conformance image does not move). Every public function/type carries a
`///` contract doc.

**Proof of goal:** a single transfer function that forwards a store's or a prior load's value to a
must-alias natural-width load, invalidates precisely on aliasing stores, clears on barriers, and
respects the truncation guard — each pinned by an adversarial fixture and each proven trap- and
bit-neutral on the real BEAM — so unit 04 can append `forwarding_pass()` to the `Baseline` pipeline
and the corpus-wide differential stays result-identical while the memory traffic drops.

---

## What this unit leaves for others

- **Unit 03** (`mem_dse`) is the DSE sibling: it consumes the **same** frozen `mem_ssa` surface
  (`alias`/`is_memory_barrier`/`byte_width`) for the dead-store look-ahead peephole (a `MustAlias`
  later store with only-pure-nodes-between shadows an earlier store). It parallelizes with this unit;
  neither touches `ir_opt.pipeline`.
- **Unit 04** (capstone) wires `forwarding_pass()` into `ir_opt.pipeline/1`'s `Baseline` arm
  (inherited by `Aggressive`) — appending it **between** `baseline_passes()` and
  `aggressive_passes()` so `Aggressive` stays a strict superset. It runs the corpus-wide
  `OptNone ≡ Baseline` differential across every `(state_strategy × mem_tier)` and both modes, uses
  `count_mem_ops` for the deterministic elimination count, and measures the wall-clock win. **Naming
  reconciliation for unit 04:** the overview §4 listed unit 02 as two passes (`store_load_forward()`
  + `redundant_load_elim()`); this unit unifies them into the single `forwarding_pass()` (one map, one
  walk), so unit 04's `memory_passes` list is `[mem_forward.forwarding_pass(),
  mem_dse.dead_store_elim()]` — one forwarding pass, not two.
