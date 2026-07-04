# Phase 10 · Unit 01 — The keystone (shared analysis + the unchecked-access surface)

> **One owner · Wave 0 · the load-bearing freeze.** Read [`00-overview.md`](00-overview.md) (N1–N8)
> and the Phase-9 keystone [`../phase-9/01-mem-ssa-keystone.md`](../phase-9/01-mem-ssa-keystone.md)
> first. This unit freezes everything units 02–07 build on: the shared loop analysis (`loop_analysis`),
> the may-clobber analysis (`mem_clobber`), the additive **unchecked** memory-access IR nodes
> (`MemLoadUnchecked`/`MemStoreUnchecked`), and the `rt_mem`/`rt_mem_atomics` unchecked entry-point
> signatures. It lands **GREEN with the optimizer pipeline still identity** — the new nodes lower
> **exactly like the checked nodes** at the freeze, and no pass produces them yet, so the whole
> corpus is byte-identical until unit 06 emits an unchecked node under a proven guard.

---

## Context

Phase 10's three passes need shared machinery: **LICM** (unit 02) needs loop-invariance (a pure
subexpression whose free variables are all defined outside the loop); **range-BCE** (unit 06) needs
the same invariance for the loop's `base`/`stride`/bound plus induction recognition (its own,
unit 06); **cross-CF MemorySSA** (unit 03) needs a **may-clobber** oracle (could this control-flow
subtree write bytes that alias `F`, grow, or call out?). And BCE needs an IR way to say "this access
is proven in-bounds — skip the check" plus a runtime that honours it. This keystone provides all of
it as **additive, freeze-safe** surface (leaf modules + additive IR variants), reusing the Phase-9
`mem_ssa` vocabulary (`Footprint`/`alias`/`byte_width`/`count_mem_ops`) rather than duplicating it.

---

## A. `loop_analysis.gleam` (NEW leaf; imports `ir` + `ir/effect` only)

The shared loop/invariance primitives. LICM (02) and BCE (06) both consume these.

```gleam
//// middle/ir_opt/loop_analysis — shared loop-invariance primitives (Phase-10 N2, used by LICM+BCE).

import gleam/set.{type Set}
import twocore/ir.{type Expr, type Value}

/// The free `Var` names of `e` — every `Var(n)` that occurs in `e` and is NOT bound by an inner
/// `Let`/`Loop`/`Block`/handler within `e` itself. The invariance test's core input. Total.
pub fn free_vars(e: Expr) -> Set(String)

/// The `Var` names of `values` (a flat operand list) — the leaf case of `free_vars`. Total.
pub fn value_vars(values: List(Value)) -> Set(String)

/// Is `e` **loop-invariant** with respect to a loop whose body BINDS the names `bound_in_loop`
/// (the loop params + every name a `Let` inside the loop body binds)? `True` iff `e` is
/// `ir/effect.is_pure` AND `free_vars(e)` is disjoint from `bound_in_loop` — so `e` computes the
/// same value every iteration and has no effect to reorder. CONSERVATIVE: any impurity or any free
/// variable defined inside the loop ⇒ `False` (not invariant — the safe direction). Total.
pub fn is_loop_invariant(e: Expr, bound_in_loop: Set(String)) -> Bool

/// The set of names BOUND anywhere inside `body` (every `Let`/`Loop`/`Block`/`Switch`/`Try`
/// binder reachable in `body`), UNION the loop's own `param` names. This is the `bound_in_loop`
/// argument to `is_loop_invariant`. Total.
pub fn bound_names(loop_params: List(ir.LoopParam), body: Expr) -> Set(String)
```

Invariance is defined purely structurally (no runtime, matching D6 unique-name IR). A pure `rhs`
whose free variables are all loop-external is safe to hoist because ANF gives it one value in scope
(Phase-3 §C invariant) and hoisting a pure expression can only be observed through its result value.

---

## B. `mem_clobber.gleam` (NEW leaf; imports `ir` + `ir/effect` + `mem_ssa`)

The may-clobber oracle cross-CF MemorySSA (03) needs — the safety gate for carrying a memory fact
*across* a control-flow subtree.

```gleam
//// middle/ir_opt/mem_clobber — "could this subtree perturb linear memory / a footprint?" (N3).

import twocore/ir.{type Expr}
import twocore/middle/ir_opt/mem_ssa.{type Footprint}

/// May EVALUATING `e` (anywhere in its control flow) write bytes that ALIAS `f`, reallocate memory
/// (`MemGrow`), or call out (which could do either)? CONSERVATIVE — `True` unless PROVEN `False`:
///
/// - a `MemStore(G, …)` with `mem_ssa.alias(G, f) != NoAlias` ⇒ `True` (may overwrite `f`);
/// - `MemGrow` / any call (`CallDirect`/`CallIndirect`/`CallHost`/`CallImport`/`CallClosure`) /
///   any bulk-memory op (`MemFill`/`MemCopy`/`MemInit`) / any SIMD-memory store ⇒ `True`;
/// - a `MemStore(G, …)` with `alias(G, f) == NoAlias`, a `MemLoad`, `MemSize`, `GlobalGet`/`GlobalSet`,
///   and pure ops ⇒ do NOT clobber `f` (recurse into control-flow children; `True` if any child does).
///
/// Used by cross-CF MemorySSA: an `avail[f]` entry may survive an `If`/`Block`/`Switch` iff
/// `may_clobber(child, f) == False` for EVERY control-flow child. Total; never panics.
pub fn may_clobber(e: Expr, f: Footprint) -> Bool

/// May evaluating `e` write ANY linear memory, grow, or call out (footprint-independent)? The
/// coarser gate DSE's cross-CF look-through uses when it has no single footprint to test. `True`
/// unless proven `False`. Total.
pub fn may_write_memory(e: Expr) -> Bool
```

`may_clobber` reuses the Phase-9 `alias` lattice: a store to a `NoAlias` footprint (a disjoint
offset off the same base) does **not** clobber `f`, so a store to `base+4` does not block forwarding
`base+0` across the `if` — the cross-CF version of the disjoint-offset disambiguation.

---

## C. The additive unchecked-access IR nodes (`ir.gleam`, freeze-safe)

Two new `Expr` variants — **produced only by the BCE pass (unit 06), never by the WASM frontend**
(additive, exactly like the Phase-8 nodes, N6):

```gleam
  /// A linear-memory load the optimizer has PROVEN in-bounds (Phase-10 range-BCE, N4). Identical
  /// operands to `MemLoad`, but it carries NO bounds check: `emit_core` lowers it to `rt_mem`'s
  /// UNCHECKED entry point (unit 05), which skips the `MemoryOutOfBounds` compare. Emitted ONLY
  /// inside the fast arm of a versioned loop whose runtime range-guard proved the whole access
  /// range in-bounds (unit 06); a WASM module never produces one (decode/validate/lower reject/never
  /// emit it). On paged/atomics the unchecked path is BEAM-safe even on an (guard-impossible) OOB
  /// (a caught error → trap, never corruption); on nif it FALLS BACK to the checked path (N5).
  MemLoadUnchecked(mem: Int, op: MemAccess, addr: Value, offset: Int, result: ValType)
  /// A linear-memory store the optimizer has PROVEN in-bounds (Phase-10 range-BCE, N4). The
  /// unchecked twin of `MemStore` — see `MemLoadUnchecked`. Effectful (writes memory); a barrier.
  MemStoreUnchecked(mem: Int, op: MemAccess, addr: Value, value: Value, offset: Int)
```

**Freeze-safe wiring (all landed by unit 01, all conservative):**

| Site | Freeze behaviour |
|---|---|
| `ir/printer` + `ir/parser` | round-trip `mem.load_unchecked` / `mem.store_unchecked` (same grammar as the checked forms + an `unchecked` marker); the round-trip test covers them |
| `ir/effect.is_effectful_node` + `classify` | `MemLoadUnchecked`/`MemStoreUnchecked` are **barriers** exactly like `MemLoad`/`MemStore` (they read/write mutable memory) |
| `mem_ssa.footprint_of` | returns the footprint for the unchecked nodes too (they alias the checked nodes) |
| `mem_ssa.is_memory_barrier` | `False` (they are footprints, handled precisely by the walkers — like the checked nodes) |
| `mem_ssa.count_mem_ops` + the `map_expr` traversal | count them as memory ops; leaves (no sub-`Expr`) |
| `emit_core` | **at the freeze, lower them EXACTLY like the checked nodes** (route to `load`/`store`, not `load_unchecked`) — so a stray unchecked node is never unsound before unit 05 wires the real path. Unit 05 flips this to the unchecked entry points. |

Because the frontend never produces these nodes and (at the freeze) they lower like checked nodes,
**the whole corpus is byte-identical** after unit 01.

---

## D. `rt_mem` / `rt_mem_atomics` unchecked signatures (frozen; bodies → unit 04)

Frozen signatures (real bodies in unit 04), mirroring the checked `load`/`store` (§recon) minus the
`Result`/trap:

```gleam
// rt_mem (paged) and rt_mem_atomics (atomics) — the unchecked twins:
pub fn load_unchecked(bytes, signed, result_width, addr, offset) -> Int       // no Result
pub fn store_unchecked(bytes, addr, value, offset) -> Nil                       // no Result (cell)
pub fn t_load_unchecked(st, bytes, signed, result_width, addr, offset) -> Int  // threaded twin
pub fn t_store_unchecked(st, bytes, addr, value, offset) -> InstanceState       // threaded twin
```

At the freeze these may be **stubs that delegate to the checked path** (unwrapping the `Result`,
`let assert Ok`) — sound (they still trap on OOB), just not yet the fast path; unit 04 replaces them
with the genuinely check-free bodies (still BEAM-safe on OOB). `nif` gets **no** unchecked twin (N5).

---

## E. Termination (N7) — what unit 01 states for the fixpoint

The Phase-9 measure `μ₉ = (n_mem, n_loops, n_ops, n_nodes, n_vars)` already counts the unchecked
nodes as memory ops (`count_mem_ops` covers them, §C). Unit 01 states the argument the later passes
preserve: **cross-CF MemorySSA** only removes accesses (`n_mem` ↓, like Phase 9); **LICM** and **BCE
versioning** are applied at most once per binding / per loop and are idempotent (unit 02/06 own the
guards), so they are **not** in the size-reducing fixpoint set and cannot loop. The capstone
re-verifies convergence over the corpus.

---

## F. Verification (Definition of Done — D8)

1. **`free_vars` / `is_loop_invariant`.** `free_vars` correct on nested `Let`/`Loop` (an inner-bound
   name is NOT free); `is_loop_invariant` is `True` for a pure expression over loop-external names,
   `False` for an impure one and for one referencing a loop-bound name (adversarial: a `MemLoad`, a
   loop param, a trapping `div` are each non-invariant).
2. **`may_clobber`.** `True` for a store aliasing `f`, a `MemGrow`, a call, a bulk op; `False` for a
   `NoAlias` store, a load, a global op, pure ops — recursing through `If`/`Block`/`Switch`. The
   adversarial fixtures pin the `True` direction (a call inside an `if` clobbers everything).
3. **Unchecked nodes round-trip + classify.** `parse(print(m)) == m` for a module containing the
   unchecked nodes; `ir/effect` classifies them as barriers; `mem_ssa.footprint_of` returns their
   footprint; `count_mem_ops` counts them.
4. **Freeze-safe emission.** A hand-built module using `MemLoadUnchecked`/`MemStoreUnchecked` compiles
   + runs on the BEAM and returns the **identical** result + trap as the checked equivalent (because
   at the freeze they lower to the checked path).
5. **Green + corpus byte-identical.** `gleam format --check src test` clean; `gleam build` 0 warnings
   (every function total, no `todo`/`panic` on a live path); `gleam test` ≥ 1783 + the new tests, 0
   failures; the WASM corpus **byte-identical** (pipeline untouched; unchecked nodes lower like
   checked).

---

## What this unit leaves for others

- **Unit 02 (LICM)** consumes `free_vars`/`is_loop_invariant`/`bound_names`.
- **Unit 03 (cross-CF)** consumes `mem_clobber.may_clobber`/`may_write_memory`.
- **Unit 04 (runtime)** replaces the unchecked stubs with genuinely check-free (BEAM-safe) bodies.
- **Unit 05 (emit)** flips the unchecked-node lowering from the checked path to the unchecked entry
  points (paged/atomics) / checked fallback (nif).
- **Unit 06 (BCE)** produces the unchecked nodes inside the fast arm of a versioned loop, using
  `loop_analysis` for the invariance of `base`/`stride`/bound.
- **Unit 07 (capstone)** wires LICM + cross-CF + BCE into `ir_opt.pipeline`.
