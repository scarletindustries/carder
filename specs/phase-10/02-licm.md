# Phase 10 · Unit 02 — Loop-invariant code motion (pure IR→IR LICM)

> **One owner · Wave A · pure IR→IR, no runtime touch.** Read [`00-overview.md`](00-overview.md)
> (N1–N8, especially **N2** and **N7**) and the keystone [`01-keystone.md`](01-keystone.md) first —
> this unit consumes the **FROZEN** `loop_analysis` interface (`«MEM10-FROZEN»`): `free_vars/1`,
> `is_loop_invariant/2`, and `bound_names/2`. It also inherits the Phase-3 `ir_opt` machinery
> (`pass`/`per_function`/`map_expr`/`run_pipeline`, [`../phase-3/03-ir-opt-baseline.md`](../phase-3/03-ir-opt-baseline.md))
> and the ANF/unique-name invariants (D6, Phase-3 §C). LICM **hoists a pure, loop-invariant `Let`
> binding out of a `Loop` body to a synthesized preheader** — the same trust-neutral,
> all-tiers/both-modes discipline as every Phase-9 pure pass. It ships `licm.gleam` + its tests and
> does **NOT** touch `ir_opt.pipeline` (unit 07 wires it), so the corpus stays **byte-identical**
> after this unit.

---

## Context

Phase 9 shipped the straight-line memory optimizations; Phase 10 (N2) adds the first of the three
deferred loop optimizations: **loop-invariant code motion**. The practical win is hoisting the
loop-invariant **address arithmetic** that feeds a hot memory access — `base + off`, `base + c·stride`
with a loop-invariant `base`/`off`/`stride`, index scaling, constant sub-expressions — out of the
loop so it is computed **once** in a preheader instead of **every iteration**. Because the IR is ANF
with unique names (D6) and every operand is an atomic `Value`, the "is this subexpression the same
value every iteration, and safe to move?" question reduces to two purely structural checks the
keystone already froze:

- **purity** — `ir/effect.is_pure(rhs)` (no effect to reorder, no trap to relocate); and
- **loop-externality** — `free_vars(rhs)` is disjoint from every name bound inside the loop.

`loop_analysis.is_loop_invariant/2` bundles exactly these two, conservatively (any impurity or any
loop-bound free variable ⇒ `False` — the safe direction). LICM is therefore a thin, sound consumer:
it walks each function body, and at every `Loop` it peels the loop-invariant leading `Let`s off the
body into a preheader. It adds **no** IR node, touches **no** runtime, and is registered (by unit 07)
into `Baseline` — Safe gets it, Aggressive inherits it.

---

## Deliverables & freeze milestones

**Consume (frozen upstream, `«MEM10-FROZEN»` — keystone §A):**

- `middle/ir_opt/loop_analysis.{free_vars, value_vars, is_loop_invariant, bound_names}` — the shared
  loop-invariance primitives. LICM calls **only** `bound_names/2` (to compute the loop's bound-name
  set) and `is_loop_invariant/2` (the hoist predicate); `free_vars/1` is used transitively by the
  latter. LICM does **not** reimplement invariance — a parallel reimplementation would be a
  change-detector waiting to drift (D8).
- The Phase-3 `middle/ir_opt/pass.{Pass, per_function, map_expr, run_pipeline}` machinery
  (`«IROPT-IFACE-FROZEN»`) — LICM is a `per_function` walk built with these; the fixpoint driver is
  already written.
- `ir.gleam` (`«IR2-FROZEN»`) — `Loop(label, params: List(LoopParam), result, body)` and
  `LoopParam(name, ty, init: Value)`. LICM rewrites only existing nodes (no new IR — N2).

**Produce:**

- `src/twocore/middle/ir_opt/licm.gleam` (**NEW**, single-owner) — `pub fn licm_pass() -> pass.Pass`
  plus the private hoist walk.
- `test/twocore/optimize/licm_test.gleam` (**NEW**) — the transformation fixtures, the adversarial
  "must-NOT-hoist" fixtures, and the end-to-end BEAM value/trap-preservation tests (§Verification).

**Do NOT edit** `ir_opt.gleam` / `ir_opt.pipeline/1`: LICM is **not** registered by this unit. The
capstone (unit 07) appends `licm_pass()` to the pipeline and owns the corpus differential. Until
then, no pass produces the rewrite, so the whole Phase-1…9 corpus is **byte-identical** after this
unit lands (the same discipline the Phase-3 leaf passes followed before unit 03 wired them).

No new freeze token: unit 02 is a leaf on the DAG. It hands unit 07 the `licm_pass()` accessor.

---

## A. The pass shape — a `per_function` hoist walk

`licm_pass()` is a whole-module pass built from the keystone `per_function` combinator: it maps the
hoist walk over every function body, leaving the rest of the module untouched. The traversal reuses
`pass.map_expr` (the shared **bottom-up** combinator) so that **nested loops are hoisted first** — an
inner loop's preheader `Let`s land in the enclosing loop's body *before* the enclosing loop is
examined, so a binding that is invariant with respect to the outer loop can be hoisted a second level
out within the same application.

```gleam
//// middle/ir_opt/licm — loop-invariant code motion (Phase-10 N2): hoist pure, loop-invariant
//// leading `Let`s from a `Loop` body to a synthesized preheader. Pure IR→IR, trust-neutral,
//// all tiers / both modes; adds no IR node and touches no runtime. Consumes the frozen
//// `loop_analysis` invariance primitives (`bound_names`/`is_loop_invariant`).

import gleam/set.{type Set}
import twocore/ir
import twocore/middle/ir_opt/loop_analysis
import twocore/middle/ir_opt/pass.{type Pass}

/// The LICM pass: hoist pure, loop-invariant leading `Let`s out of every `Loop` in every function
/// body to a preheader `Let`. Semantics-preserving (F2 / N2): identical returned values by bit
/// pattern and identical traps — see §C. Registered into `Baseline` by unit 07 (not here). Total.
pub fn licm_pass() -> Pass {
  pass.per_function("licm", fn(f) {
    // `map_expr` is BOTTOM-UP, so `hoist_at_loop` sees a `Loop` only after its body's own loops
    // have already been hoisted (nested-loop composition within one application).
    ir.Function(..f, body: pass.map_expr(f.body, hoist_at_loop))
  })
}

/// Rewrite one node: at a `Loop`, peel its invariant leading `Let`s into a preheader; leave every
/// other node unchanged. (`map_expr` supplies the recursion; this only acts at `Loop` heads.)
fn hoist_at_loop(e: ir.Expr) -> ir.Expr {
  case e {
    ir.Loop(label, params, result, body) ->
      drain(label, params, result, body, loop_analysis.bound_names(params, body))
    _ -> e
  }
}
```

Note that `map_expr` invokes `hoist_at_loop` on the **reconstructed** `Loop` node exactly once, and
`drain` returns a `Let(name, rhs, Loop(…))` chain — the freshly-created preheader `Let`s are **not**
`Loop`s, so they are not re-examined, and the residual `Loop` at the bottom of the chain is the loop
we just drained (its leading `Let`s are now non-invariant), so a re-application is a no-op. This is
what makes one application idempotent (§D).

---

## B. The hoist walk — draining the invariant leading `Let`-chain

At a `Loop(label, params, result, body)`, LICM examines the body's **leading `Let`-chain** and moves
each single-binding `Let([name], rhs, inner)` whose `rhs` is loop-invariant out to the preheader,
**in order**, stopping at the first non-invariant (or non-single-binding) node. The preheader binding
lives **outside** the loop, so a hoisted `rhs` must reference no loop-bound name — which is exactly
what `is_loop_invariant(rhs, bound)` guarantees (its `free_vars(rhs)` are disjoint from `bound`, and
`bound ⊇ params`).

**The moving-frontier subtlety (hoist bindings in order).** `bound_names(params, body)` is the loop
params **plus every name bound anywhere in `body`** — including the names we are about to hoist. So a
binding used by a *later* invariant binding must not block it: once `let k = a*b` is hoisted, `k` is
bound in the **preheader**, i.e. loop-external, so a subsequent `let m = k+1` is now invariant too.
`drain` therefore **removes each hoisted name from `bound`** before testing the rest of the chain
(sound because names are unique — D6 — so a deletion cannot un-bind a different, still-interior use).

```gleam
/// Peel the maximal prefix of loop-invariant single-binding `Let`s off `body`, wrapping the
/// residual loop in a preheader `Let` for each — in original order. `bound` starts as
/// `bound_names(params, body)` and shrinks by each hoisted name (which becomes loop-external).
///
/// - Return: `Let([n1], r1, … Let([nk], rk, Loop(label, params, result, residual)))`, or the
///   `Loop` unchanged when nothing hoists. Total.
fn drain(
  label: String,
  params: List(ir.LoopParam),
  result: List(ir.ValType),
  body: ir.Expr,
  bound: Set(String),
) -> ir.Expr {
  case body {
    // A single-binding leading `Let` whose rhs is pure AND loop-external ⇒ hoist it.
    ir.Let([name], rhs, inner) ->
      case loop_analysis.is_loop_invariant(rhs, bound) {
        True ->
          // Emit the preheader binding; `name` is now loop-external, so keep draining `inner`
          // with `name` removed from the interior-bound set.
          ir.Let(
            [name],
            rhs,
            drain(label, params, result, inner, set.delete(bound, name)),
          )
        // Not invariant (impure/trapping, or references a loop-bound name) ⇒ stop; the loop keeps
        // this `Let` and everything after it.
        False -> ir.Loop(label, params, result, body)
      }
    // Anything else at the head (the loop's real work, a zero-name effect `Let`, a multi-binding
    // `Let`, a control node) ⇒ stop draining. Conservative and sound (see below).
    _ -> ir.Loop(label, params, result, body)
  }
}
```

**Deliberate, sound restrictions (stated, not half-done):**

- **Single-binding only (`[name]`).** A multi-binding `Let([a, b], rhs, …)` (a value-projection) is
  left in place — hoisting it is sound but needs value-projection bookkeeping out of this unit's
  scope. Conservative ⇒ sound.
- **Leading chain only.** LICM peels the *prefix* of invariant `Let`s; it does not reorder the loop
  body to float an invariant binding up past an intervening effectful/loop-dependent node. That is a
  separate, heavier motion; the leading-chain form captures the compiler-emitted "compute the
  invariant address, then loop over it" shape that is the win, and it composes across the fixpoint.
- **No shadowing to worry about (D6).** Unique names mean a hoisted binding cannot capture or be
  captured by any binder outside the loop — the preheader `Let` introduces a name that is unique
  module-wide, so moving it out cannot change which binding any `Var` resolves to. State this
  explicitly: LICM performs **no** renaming, and needs none.
- **No use-check required.** Hoisting an *unused* pure invariant binding is harmless; dead-`let`
  (Phase-3 §D) reclaims it later. LICM does not compute liveness.

---

## C. Soundness (the F2 bar for LICM)

LICM must be **semantics-preserving**: `optimize(m)` and `m` return identical values (bit-for-bit,
D5/D7) and trap identically, on every input, under every `(state_strategy × mem_tier)` and both
profiles. Two facts carry the proof; both are exactly the two conjuncts `is_loop_invariant` checks.

**(1) Zero-trip case — hoisting a *pure* expression is invisible when the loop runs zero times.**
A WASM loop guarded by a `br_if`/`If` may execute its body **zero** times
([exec/instructions §Control](https://webassembly.github.io/spec/core/exec/instructions.html) — the
guard can skip straight to the exit). If LICM hoisted an expression with an **effect** or a **trap**,
that effect/trap would now fire in the preheader even on a zero-trip loop, changing observable
behaviour (a store that never happened, a trap that never fired). LICM hoists **only** expressions for
which `is_pure(rhs) == True` — no memory write, no global write, no grow, no call, no `Charge`, and
**not** a trapping `Num`/`Convert` (`ir/effect` classifies `IDivS`/`IDivU`/`IRemS`/`IRemU` and the
trapping `TruncS`/`TruncU` as non-pure; `MemLoad`/`GlobalGet` as barriers; `Trap` itself as
non-pure). A pure, total expression has **no** observable effect and **cannot** trap, so evaluating
it once in the preheader — whether the loop then runs 0, 1, or n times — adds nothing observable. The
zero-trip soundness is therefore **automatic** from the purity gate; LICM never needs a "does the
loop always run at least once?" proof.

**(2) Same-value — a loop-invariant pure `rhs` computes one value for the whole loop.** Every free
variable of a hoisted `rhs` is loop-external (`free_vars(rhs)` disjoint from `bound ⊇ params`). By the
ANF unique-name / per-iteration-SSA invariant (Phase-3 §C), a name denotes **one** immutable value in
its scope — a loop variable is rebound only at the `Continue` back-edge, which begins a *fresh*
iteration, and a hoisted `rhs` references **none** of the loop's params or interior bindings. So the
`rhs` reads the same bits on every iteration and evaluates to the same value; a pure expression is a
deterministic function of those bits (D7 — the numeric runtime is bit-exact). Evaluating it **once**
before the loop and reading that value each iteration is therefore **value-exact** — identical bit
pattern to recomputing it every iteration.

**(3) Trust-neutral, all tiers / both modes, no IR growth, no runtime touch.** LICM makes **no** trust
assumption (soundness rests only on `is_pure` + loop-externality, both unconditional), so it runs at
**Baseline** and Aggressive inherits it — Safe and Unsafe alike. It produces **no** new IR node (only
`Let`/`Loop` reshaping) and calls **no** runtime function, so it is conformance-neutral by
construction: the emitter, every `mem_tier`, and the fuel accounting see structurally the same
program. On fuel specifically (Safe): a hoisted pure `rhs` carries **no** `Charge` (`Charge` is
effectful ⇒ never inside a hoisted binding), so no metered work moves across the loop boundary and
the deterministic `FuelExhausted` bound is unchanged. The concrete win — hoisting loop-invariant
**address arithmetic** feeding a `MemLoad`/`MemStore` (the `MemLoad` itself stays put; only its
pure invariant address computation moves) — is a real per-tier speedup with no semantic cost.

---

## D. Termination (N7)

LICM is applied by the `run_pipeline` fixpoint driver, so it must not loop and must not grow the
program without bound.

- **Idempotent.** Once a binding is hoisted, its `rhs` is no longer *inside* the loop — it sits in the
  preheader — so `drain` cannot re-hoist it (it is not part of the residual loop body). A second
  application of `licm_pass()` finds the residual loop's leading `Let` non-invariant (or the loop
  fully drained) and drains **zero**, returning the module unchanged (`==`). The fixpoint is reached
  in the round after the last productive hoist.
- **A monotone measure strictly decreases per hoist.** Let `η(m)` = the number of `Expr` nodes that
  lie **inside some `Loop` body**. Each hoist moves exactly one `Let` node from inside a loop to
  outside it (the preheader is outside), so `η` strictly decreases by ≥ 1 and never increases (LICM
  builds no node inside a loop; it only removes `Let`s from loop bodies and creates preheader `Let`s
  *outside*). `η` is bounded below by 0, so only finitely many hoists occur. LICM adds **no** `Loop`
  and removes none, so it is orthogonal to the Phase-3/Phase-9 size measure `μ` (it leaves `n_loops`
  unchanged) and cannot destabilize the joint fixpoint — the capstone (unit 07) re-verifies
  convergence corpus-wide.

---

## Verification (Definition of Done — D8)

Tests assert **defined** behaviour (the transformation the invariance proof licenses, and the
value/trap semantics per the WASM spec) — never the current byte output (no change-detectors). A
`licm(slots, body)` helper runs `licm_pass()` in isolation via the fixpoint driver
(`pass.run_pipeline(m, [licm.licm_pass()])`) over a one-function module and returns the optimized
body (mirroring `test/twocore/optimize/mem_forward_test.gleam`'s `fwd`); a `run(m, export, args)`
helper compiles under `profiles.safe()` and drives the real BEAM
(`pipeline.ir_to_core` → `core_to_beam` → `instantiate` → `invoke_instance` → `stop_instance`).

1. **(a) Invariant binding hoists to a preheader (structural, the positive case).** A loop whose body
   begins `let k = a*b` with `a`, `b` function params (loop-external) and a body that uses `k` and the
   loop var `i`:
   `Loop("l", [LoopParam("i", TI32, ConstI32(0))], [TI32], Let(["k"], Num(IMul, [Var("a"), Var("b")]), Let(["s"], Num(IAdd, [Var("k"), Var("i")]), …)))`.
   Assert the optimized body is `Let(["k"], Num(IMul, [Var("a"), Var("b")]), Loop("l", …))` — `k`'s
   binding is now the **preheader** and the loop body no longer contains `let k`. A second fixture
   pins the **chained** case: `let k = a*b; let m = k+1` both hoist (`m` after `k` becomes external),
   proving the moving-frontier `set.delete` logic. Include the practical shape: a loop-invariant
   address `let addr = base + off` (with `base`/`off` loop-external) hoisted above a per-iteration
   `MemLoad(addr)` — the `MemLoad` stays inside, the address computation moves out.

2. **(b) A loop-var-dependent binding is NOT hoisted (adversarial).** `let x = i + 1` where `i` is the
   loop param: `free_vars` includes `i ∈ bound`, so `is_loop_invariant` is `False`. Assert the
   optimized loop body still contains `let x` inside the `Loop` (no preheader binding for `x`).

3. **(c) An effectful / trapping `rhs` is NOT hoisted, even when loop-external (adversarial).** Two
   fixtures, both with only loop-external free variables so **only** the purity gate can stop them:
   `let y = MemLoad(0, MemAccess(4, False), Var("base"), 0, TI32)` (a barrier — reading memory could
   observe a store from a prior iteration / another instance) and
   `let z = Num(IDivS(W32), [Var("a"), Var("b")])` (can trap `IntDivByZero` / `IntOverflow` —
   [exec/numerics](https://webassembly.github.io/spec/core/exec/numerics.html)). Assert **both** stay
   inside the loop. This is the load-bearing check: hoisting either out of a **zero-trip** loop would
   introduce a memory read / a trap that the original program never performs (§C.1).

4. **(d) End-to-end on the real BEAM — value + trap unchanged vs unoptimized.** Build a module with a
   loop carrying a hoistable invariant sub-expression (e.g. an accumulator loop `acc += k` where
   `k = a*b` is invariant) exported as a function; assert `run(m, f, args) == run(licm-optimized(m), f, args)`
   for a value-returning run (result-identical, D7), for a **zero-trip** run (loop bound makes the body
   never execute — the hoisted pure expression changes nothing observable), and — to pin trap
   preservation — for a module whose loop *does* trap on some iteration (e.g. an interior checked
   `MemLoad` that goes OOB, which LICM leaves in place): assert both programs `Trapped` identically.
   Since LICM hoists only pure expressions, there is no trap to relocate — the trap fires at the same
   observable point in both.

5. **(e) Green DoD.** `gleam format --check src test` clean; `gleam build` **zero warnings** (every
   function total — no `todo`/`panic`/`let assert` on a live path); `gleam test` green (≥ the current
   count + the new tests, 0 failures); every public function/type carries a `///` contract doc. The
   corpus stays byte-identical (pipeline untouched — this unit does not register the pass).

---

## What this unit leaves for others

- **Unit 07 (capstone)** appends `licm_pass()` to `ir_opt.pipeline(Baseline)` (Aggressive inherits
  it), and owns the corpus-wide `optimize(m) ≡ m` differential across every tier + both modes, the
  idempotence/convergence re-verification (N7), and the committed benchmark that reports LICM's
  deterministic **hoist count** and its wall-clock win on an invariant-heavy loop
  (`docs/phase-10-benchmark.md`). Until then LICM is dormant and the corpus is byte-identical.
- **Unit 06 (range-BCE)** independently consumes the same `loop_analysis` invariance primitives for
  the invariance of its `base`/`stride`/bound; LICM and BCE share the analysis, not the pass.
