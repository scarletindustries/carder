# How to scope & implement a phase

> The repeatable recipe that got this project to Phase 10. Ten phases were built this way; it works.
> Follow it. This is the "how we work" reference — read it before scoping anything new.
>
> **Scope note (post-split):** this repo is carder, the compiler **backend** — shared IR, middle-end,
> Core Erlang codegen + linking, the BEAM runtime, the embedder API, the CLI vocabulary. The
> WebAssembly frontend and the official spec-test conformance suite now live in the **scribbler**
> repo, which keeps its own copy of this file. §§0–7 (the process) are identical in both; §§8–10
> (invariants, Definition of Done, differentials) are repo-specific — these are carder's.
>
> Companions: [`00-high-level.md`](00-high-level.md) (the vision every phase serves),
> [`01-status.md`](01-status.md) (what's built), [`02-roadmap.md`](02-roadmap.md) (what to build next),
> [`state.md`](state.md) (the live ledger you update as you go),
> [`FRONTEND-API.md`](FRONTEND-API.md) (the public contract every frontend compiles against).

---

## 0. The shape of a phase

A **phase** is one coherent capability increment (a runtime tier, an optimizer family, a codegen or
linking surface). It is decomposed into numbered **units**, each single-owner and independently
committable. Unit **01 is always the keystone** (freezes the interfaces); the **last unit is always
the capstone** (proves the phase). Everything between builds in parallel behind the frozen
interfaces.

```
overview + decisions ─▶ scoping fan-out ─▶ adversarial critique ─▶ reconcile
        │                                                              │
        ▼                                                              ▼
   KEYSTONE (unit 01)  ──freezes «X-FROZEN» interfaces──▶  parallel units (02..N-1)  ──▶  CAPSTONE (unit N)
   lands green, defaults byte-identical                    each single-owner, green      proves the phase
```

The discipline that makes it parallelizable: **freeze the complete interface first, then build bodies
independently behind it.** A late-discovered interface gap re-breaks every exhaustive match in the
phase, so the keystone must freeze the *whole* surface (all trap reasons, all node variants, all
`Binding` fields) up front — not incrementally.

---

## 1. The lifecycle (seven steps)

1. **Author the overview** (`00-overview.md` in the phase's working area) to the fixed skeleton in §2.
   Open by restating that **all prior-phase decisions still hold** and cite the running baseline (test
   count / 0 warnings / defaults byte-identical).
2. **Scoping fan-out.** Multiple scoping agents propose/refine the unit split from the overview's
   proposed dependency DAG. The overview flags open seams for them to sanity-check (is `emit_core`
   single-agent-sized? does this feature belong in unit 08 or get cut?).
3. **Adversarial critique.** Critique the scoped decisions and unit docs from several lenses. This is
   the step that catches the blockers — incompatible interface spellings invented by parallel scoping
   agents, unsound analyses, missing IR variants, double-owned files.
4. **Reconcile.** Fold the fan-out + critique into a single authoritative `RECONCILIATION.md` carrying
   `R`-numbered decisions. Declared **authoritative: where a unit doc conflicts, RECONCILIATION wins.**
   Implementer read order becomes overview → RECONCILIATION → unit doc. *(Small phases with no
   conflicts skip the standalone file and fold resolutions into the overview.)*
5. **Freeze the keystone** (unit 01, §3). Publish the `«X-FROZEN»` interfaces, make the deliberate
   documented cross-file reaches, land **green** with the pipeline still identity / defaults
   byte-identical. Announce each milestone in [`state.md`](state.md) the moment it lands.
6. **Build the parallel units** (§4) in waves behind the frozen signatures. Each is single-owner, needs
   only the frozen *signatures* (not sibling bodies), ships code + adversarial fixtures, is individually
   green + committable, and updates `state.md` with what it leaves.
7. **Close with the capstone** (§5). The only unit that edits the single wiring/registration point. It
   runs the corpus-wide differential across every `(mode × state_strategy × mem_tier)`, satisfies the
   §1 acceptance table, and produces the measured benchmark.

Throughout, the manager QA-gates every unit (format / build / test + the corpus differential + a
spec-DoD read) before commit + push to `main`.

---

## 2. Anatomy of the overview doc

Fixed skeleton — every phase overview has these sections:

- **§0 Where this phase sits** — one paragraph placing it on the platform ([`00-high-level.md`](00-high-level.md)).
- **§1 Goal + acceptance table** — "Area | Must demonstrate" rows (the capstone owns proving these) and
  an **Honest-scope** subsection stating what is deferred and *to which future phase*.
- **§2 The numbered phase decisions** — a letter-prefixed list (see §6). Each is **frozen**: the
  standing rule is *"if you believe one is wrong, raise it with the planner BEFORE building — do not
  silently diverge."* By convention **decision #1 is the keystone** (the phase's load-bearing new
  thing) and **the last decision is "Honest scope."**
- **§3 The dependency DAG** — names the `«X-FROZEN»` milestones and the parallel waves.
- **§4 File-ownership map** — one owner per file (invariant D1).
- **§5 How to claim & complete** — pointer to the ledger conventions (§7 here).

---

## 3. The keystone (unit 01) — "Interface freeze"

Single-owner, goes **first and alone**. It:

- **Implements the phase's one load-bearing new thing** (decision #1) and **freezes its interface** as
  the `«X-FROZEN»` milestone(s): IR types, `.ir` grammar delta, new `TrapReason`s + their
  `rt_trap.spec_trap_message` arms, extended `Binding` fields + their enums, and runtime signatures as
  bodies that are **conservative-sound, never `todo`** (e.g. `effect → Effectful`, empty pipeline =
  identity).
- **Makes the deliberate, documented cross-file reaches** needed to compile. This is necessary because
  **Gleam has no default field values** — extending `Binding` or a `TrapReason` breaks every
  constructor and every exhaustive match. The keystone updates
  `instance.gleam`/`profiles.gleam`/`rt_trap.gleam`/`ir/printer`/`ir/parser`/`cli.gleam`/etc. so the
  tree compiles, and records every reach in `state.md`.
- **Lands green with the pipeline still identity** and defaults chosen so **every prior module is
  byte-identical**. Nothing is unsound until a later unit proves the guard.
- Ships a dedicated freeze test module (e.g. `ir3_freeze_test` / `eh_freeze_test` / `tier_freeze_test`)
  — small spec-tests that the new axes are expressible and the defaults are fail-closed.
- **Widens the frontend contract, if it widens at all, in one place.** A new IR node / `Binding` field /
  `Provider` variant is a change to [`FRONTEND-API.md`](FRONTEND-API.md) and must be additive and
  default-off, so every existing frontend (scribbler, arc) keeps compiling and keeps its current
  output byte-identical.

**Why first & alone:** an unsound oracle or a missing variant makes every downstream unit unsound; and
publishing the stable signatures is what lets the parallel units + `emit_core` build without racing on
names.

---

## 4. The units (02 … N-1)

- **Single-owner** (D1). Additive changes only. Needs only the frozen *signatures* of its dependencies,
  **not** their bodies — e.g. `emit_core` is built in parallel with the runtime bodies; a new pass
  gates on the day-1 published IR variant.
- **Does not touch the single pipeline/registration point** — that's the capstone's job. This is what
  keeps units independently committable without merge races.
- Ships its code **plus isolated, adversarial fixtures** — including "must-NOT-do-this" fixtures for
  anything whose failure is silent (an unsound CSE-across-store is silent memory corruption, so it gets
  its own adversarial unit).
- Is individually **green + committable + pushable**, and updates `state.md` with what it leaves and to
  which downstream unit.

---

## 5. The capstone (last unit) — "PHASE N PROVEN"

- The **only** unit that edits the single wiring/registration point: `ir_opt.pipeline/1` for optimizer
  phases (append new passes to the **Baseline** arm so **Aggressive inherits them as a strict
  superset**), or the run-ABI / `carder/cli` vocabulary / profile linker for surface phases.
- **Proves the phase** by owning the §1 acceptance table: the corpus-wide **differential** —
  `optimize(m) ≡ m` / `OptNone ≡ Baseline ≡ Aggressive` producing **byte-identical returned values (by
  bit pattern) and identical traps (same `TrapReason`, same trap-or-not)** — run over the checked-in
  `.ir` corpus (`test/carder/ir/corpus/*.ir`) under **every** shipped `(mode × state_strategy ×
  mem_tier)` combo and **both** profiles; plus the fail-closed / isolation / trap-preservation
  properties.
- Produces a committed, **measured** benchmark with methodology and the honest pattern-dependent
  ceiling written down (`docs/phase-N-benchmark.md` or `-surface.md`) — *measured, not asserted; no
  hero number.* Note that the benchmark harness (`smoke/`) is a **wasm** differential and lives in the
  scribbler repo; a carder capstone that needs it drives it cross-repo (see the reproduce line in
  `docs/phase-4-benchmark.md`).
- **If the phase widened the frontend contract**, says so explicitly and points at the scribbler-side
  (and, where relevant, arc-side) re-verification: the WASM conformance triple is **scribbler's** gate,
  not carder's, and a green carder capstone is not by itself evidence that conformance held.
- Reports the running gleeunit total. Capstones **confirm green, they do not re-derive** prior units.

---

## 6. Decision codes & reconciliation

Each phase's overview §2 carries its own letter-prefixed, sequentially-numbered decision list, frozen
for that phase. The letters advance one per phase:

| Phase | Codes | Phase | Codes |
|---|---|---|---|
| 1 | `D1–D10` (the permanent cross-phase invariants) | 6 | `I1–I8` + `S1–S15` (reconciliation) |
| 2 | `E1–E8` | 7 | `J1–J8` + `T1–T14` (reconciliation) |
| 3 | `F1–F8` | 9 | `M1–M8` |
| 4 | `G1–G8` | 10 | `N1–N8` |
| 5 | `H1–H8` + `R1–R18` (reconciliation) | 13 / 14 / 15 | `Q…` / `R…` / `S…` |

**Post-split the series forks, so the two repos can never mint colliding codes.** The unprefixed
letters `A`–`S` are the **pre-split shared history** (Phases 1–15, one tree, one series) and stay
readable as written wherever they appear. From the next phase onward:

| Repo | Series | Next |
|---|---|---|
| **carder** (this repo) | `C-`-prefixed, continuing the letter run | `C-T`, then `C-U`, `C-V`, … |
| **scribbler** (wasm frontend) | `S-`-prefixed, restarting at `A` | `S-A`, then `S-B`, `S-C`, … |

Within each list: **#1 = the keystone**, **last = "Honest scope."** When a fan-out + critique surfaces
conflicts, the resolutions become a separate authoritative `RECONCILIATION.md` with `R`-numbered
decisions that **win over any conflicting unit doc**.

---

## 7. Using the state file (`state.md`)

`state.md` is the **live ledger for the phase in flight** — the swarm's shared "who's doing what."
*Read it before claiming work; update it after finishing.* It is **not** a history archive — completed
phases are compacted out of it into [`01-status.md`](01-status.md) once proven (that's this
consolidation). Keep it small and current. It carries three things:

1. **A freeze-milestone table** — `Milestone | Produced by | Status | Unblocks`. Mark a milestone
   `FROZEN ✓` / `published ✓` the *moment* it lands.
2. **A unit table** — `Unit | Doc | Owner / status | Depends on (freeze) | Leaves`. Status legend:
   `unclaimed` · `in-progress (name)` · `blocked (on …)` · `done`. The **Leaves** column states what
   the unit produces and hands to which downstream unit.
3. **A landing log** — each landing recorded as a running count (`N tests (was M, +K)`), the corpus
   differential result, `0 warnings, format clean`, and `byte-identical`.

When a phase closes (capstone proven), fold its outcome into `01-status.md` §3, move any new deferrals
into `02-roadmap.md`, and reset `state.md` to the empty template for the next phase.

---

## 8. The permanent, cross-phase invariants (never violate these)

These are the load-bearing rules every phase preserved. They are the difference between "compiles" and
"correct + sandboxed." Treat them as a hard gate.

- **D1 — One owner per file.** Every file has a single owning unit; changes stay additive. Only the
  keystone/capstone make cross-file reaches, and only *deliberate, documented* ones (recorded in
  `state.md`) — justified because Gleam has no default field values.
- **D3a — No ambient authority / no ambient `apply`.** Runtime layers are reached only through the
  binding chokepoint (`emit_core`). The emitted call is **always** a static
  `call '<carder@runtime@rt_*>':'<fn>'(...)`, **never** a data-driven `apply(Mod,Fun,Args)` with
  Mod/Fun from table/program/runtime data. `call_indirect` dispatches via build-controlled closures
  with three ordered fail-closed guards (index-in-bounds → `UndefinedElement`; slot-non-null →
  `UninitializedElement`; exact structural `FuncType` match → `IndirectCallTypeMismatch`). Cross-module
  calls dispatch through a handed-in closure capability (`link.call_import`), **never**
  `erlang:apply(Closure, ArgsList)` (arity-spread crash). **carder hard-codes no host module by name:**
  a frontend supplies host functions as `link.Provider` values (`Namespace(link_name, func, state)`
  included), and `carder/cli.resolve_binding` is the fail-closed gate that turns a `Binding` into an
  `Instance`. A structural codegen-security test enforces this and is extended each phase.
- **D4 / D9 — Fail closed.** Safe is the default; `profiles` exposes no way to weaken posture by
  omission (Unsafe, lower caps, tier-N are explicit tested opt-ins). An unseeded runtime cell traps
  rather than reading garbage; an unsatisfied import fails at link time; **`Safe + nif` is a link-time
  rejection** (Safe permits tier P or O, never N). Per-stage error types.
- **D5 / D7 — Raw bit patterns, compared by bit pattern.** Floats and v128 are raw IEEE-754 / 16-byte
  bit patterns end to end (NaN payloads, `-0.0`, wrap all exact). A load needs only width+sign
  (`f32.load` == `i32.load` at the byte level). **All result equivalence is compared by bit pattern**,
  so the differential harness catches any bit-level divergence. The `.ir` textual form is the lossless
  inter-stage contract — and, post-split, the **actual repo boundary**: what a frontend hands carder is
  `.ir`, nothing else.
- **D6 — Language-neutral, named-label structured IR.** No WASM-isms in the IR core (references are
  term-layer values, bulk ops are generic sequence ops, the memory index is a generic multi-region
  model). The IR carries **no runtime handle operand** (tier-agnostic), so tier/state-strategy
  retrofits are provably confined to the `emit_core` seam + runtime. This is now enforced by
  construction: carder contains no source-language code at all.
- **E6 — Stateful ops are effects (the optimizer's safety boundary).** Made concrete in
  `ir/effect.gleam`: `MemLoad`/`MemStore`/`MemGrow`/`MemSize`/`GlobalGet`/`GlobalSet`/`CallIndirect`/
  `CallHost`/`Charge`/`Trap` and all calls are side-effecting — non-reorderable, non-CSE-able,
  non-DCE-able. The classifier is **conservative** (anything not provably pure is effectful). A memory
  barrier (grow, any call, any bulk-memory op, any control transfer / region boundary) clears all
  memory knowledge.
- **Trap-preservation is absolute.** A linear-memory access is **trap-or-access, not a pure
  read/write**. Every rewrite is legal only because it preserves *when and whether* a trap fires:
  forwarding/RLE rest on a dominating successful access proving in-bounds; DSE's shadowing store
  bounds-checks the same address; range-based BCE uses **loop versioning** (a pure runtime guard picks
  the unchecked fast loop only when the whole range is proven in-bounds, else runs the checked loop) —
  **never** hoist-and-trap-early. Unchecked entry points ship only on BEAM-memory-safe tiers
  (paged/atomics); nif falls back to checked.
- **Trust-neutral passes run at Baseline.** A semantics/trap-preserving optimization is registered in
  the **Baseline** arm, so it speeds up Safe **and** Unsafe and — because `ir_opt` runs *before* tier +
  mode selection — **every** `(paged/atomics/nif × cell/threaded)` and every present/future frontend
  inherits it with no per-tier code. Aggressive-only passes must each document their trust assumption
  and provably never change a corpus result (the IR's ill-defined operations all trap; there is no UB
  to exploit).
- **Byte-identical by default.** A program using no new surface compiles byte-identically to the prior
  phase (defaults route new surface away: memory-index 0 defaults away, unchecked nodes are never
  produced by a frontend, Safe.beam differs from Unsafe.beam only by charge instrumentation + the
  `instantiate/0` seed). Where a pass legitimately changes emitted code, the bar relaxes to
  **result-identical** (same values by bit pattern, same traps), proven by the corpus-wide
  differential. *The frontend-facing half of this rule — "WASM byte-identical / conformance-neutral by
  default" — is now scribbler's invariant, checked against the spec suite in that repo.*
- **Constant-space loops + preemption, preserved across every strategy.** The tail-`apply` back-edge
  stays byte-for-byte unchanged; the state handle / fuel budget / threaded record never becomes a
  growing loop-carried value; charge/pdict-get are ordinary reduction-consuming ops so the scheduler
  still preempts. A **tested** acceptance property (`sum_to(100000)` and a store-loop in constant
  space), not an assertion.
- **The instance is the unit of policy, realized at compile time (B3).** Safe.beam ≠ Unsafe.beam,
  threaded ≠ cell, nif ≠ paged — distinct builds sharing identical `carder@runtime@rt_*` modules;
  per-instance policy (fuel budget, host policy) is seeded once in the synthesized `instantiate/0` (the
  sole documented exception to posture-agnostic function bodies). The single-`.beam` runtime-dispatch
  model (B1) stays deferred.

---

## 9. Definition of Done (the hard gate)

From `CLAUDE.md` + decision D8 — applied **per unit** and **per phase**. Not a checklist to skim.

**Per unit:**
1. **Spec-cited tests** written against the original specification, asserting *defined* behavior —
   **not** change-detector tests that lock in current output. carder's citation authorities are the
   [Core Erlang language specification](https://www.erlang.org/doc/apps/compiler/), the OTP/ERTS
   documentation (`erl_nif`, `atomics`, `persistent_term`, the BEAM file format), and **the IR contract
   itself** — [`FRONTEND-API.md`](FRONTEND-API.md) plus the `.ir` grammar in `ir/printer` + `ir/parser`,
   which is normative for what a node *means*. For behavior a frontend inherited from a source
   language, cite that language's spec **in the frontend's repo**; carder asserts the IR-level
   contract. When a bug is found, add a failing spec-encoding test **first**, then fix. For optimizer
   passes: the transformation + adversarial "must-NOT" fixtures + end-to-end BEAM value/trap
   preservation.
2. **Doc comments** (`///` items, `////` module-level) on every public function — the *contract* (what
   / params-meaning-units-ranges / `Result`-`Ok`-`Error`-`Some`-`None` semantics / failure-modes +
   anything that can panic), not a restatement of the name.
3. `gleam format --check src test` **clean** (CI fails otherwise).
4. `gleam build` with **zero warnings**.
5. The unit's own differential/interface suite **passes** — *done is "the suite passes," never "it
   compiles."*

**Per phase (the capstone bar):** the whole prior acceptance corpus stays green and
**result-identical** (by bit pattern, same traps) under both profiles and every
`(state_strategy × mem_tier)`, driven from the checked-in `.ir` corpus; a measured benchmark. Where the
phase touched the frontend contract, the scribbler-side conformance re-run is part of the bar even
though it happens in another repo — say who ran it and what it measured. The manager QA-gates every
unit before commit + push to `main`.

---

## 10. Differential testing & toolchain pins

carder's oracle is **itself, under a different configuration**. Every claim is a differential between
two builds of the same `.ir` program, compared **by bit pattern** (D5/D7) on both returned values and
traps (same `TrapReason`, same trap-or-not):

- **Optimizer differential:** `OptNone ≡ Baseline ≡ Aggressive`, and `optimize(m) ≡ m` for an empty
  pipeline. A pass that changes emitted code must still be result-identical.
- **Tier / strategy matrix:** every `(mem_tier × state_strategy)` — `paged` / `atomics` / `nif` ×
  `cell` / `threaded` — must agree, and `Safe ≡ Unsafe` on every corpus program. Tier-N rows are
  `cc`-gated: with a C toolchain they run against the real `.so`, without one they **categorized-skip**
  (never a paged delegate silently reported as native).
- **Link differential:** a `--link` self-contained build ≡ the same program built non-linked; the
  `--bindings` emitters are checked against the generated-module contract, not against their own output.
- **Corpus:** `test/carder/ir/corpus/*.ir` — 35 checked-in IR programs with spec-sourced `.expected`
  values copied verbatim from the upstream suites that produced them. It was **measured** that
  `wasm → .beam` and `wasm → .ir → .beam` are byte-identical for all 32 corpus programs that came from
  wasm, which is why the pre-split proofs carry over unchanged. New corpus entries arrive as `.ir` —
  carder never grows a source-language decoder to obtain one.
- **Greenness is measured, never promised** (decision R16): re-verify empirically at the pinned SHA per
  file; the headline is whatever is measured, not what was planned.
- **Pins:** Gleam 1.17+, Erlang/OTP (the reference machine's OTP/erts version is stated in every
  benchmark doc), and a C compiler for the tier-N rows. The wasm-side pins (Porffor, Node, wabt,
  wasmtime) and the Tier-A/Tier-B `.wast` harness moved with the frontend and are pinned in the
  **scribbler** repo; the WASM conformance triple is reported there.

---

## Commit conventions (from `CLAUDE.md`)

Never Claude-brand commits or PRs (no `Co-Authored-By: Claude`, no "Generated with Claude Code").
Commit frequently — one logical unit per commit, small and independently reviewable. Only commit/push
when explicitly asked; if on `main`, branch first.
