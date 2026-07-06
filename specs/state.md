# Implementation State — the live ledger

> The swarm's shared ledger for **the phase currently in flight**. Before claiming work, read it;
> after finishing, update it. It is a *working* file, not a history archive — completed phases are
> compacted into [`01-status.md`](01-status.md) once proven, and this file resets to the template
> below for the next phase.
>
> **How to use this file:** [`03-phase-workflow.md`](03-phase-workflow.md) §7.
> **Where we are:** [`01-status.md`](01-status.md) · **What's next:** [`02-roadmap.md`](02-roadmap.md)
> · **Architecture:** [`00-high-level.md`](00-high-level.md)

**Legend — unit status:** `unclaimed` · `in-progress (name)` · `blocked (on …)` · `done`
**Legend — freeze milestone:** a published, compiling type/signature stub that unblocks downstream
units. Announce it here the moment it lands (`FROZEN ✓` / `published ✓`).

---

## Current phase

**Phases 11 & 12 are proven on `main` and compacted into [`01-status.md`](01-status.md) §3–§5.** Three
follow-on phases are scoped (overviews written, awaiting/after the scoping fan-out): **Phase 13** —
tail-call (`return_call`/`return_call_indirect`); **Phase 14** — cross-module funcref-in-`elem` init;
**Phase 15** — production tier-N C NIF. They are **independent** and are being landed in sequence
13 → 14 → 15 (each capstone proven + pushed + CI-green before the next starts). This ledger tracks the
phase in flight.

---

### ▶ Phase 13 — Tail-call (`return_call` / `return_call_indirect`)

Overview: [`phase-13/00-overview.md`](phase-13/00-overview.md). Goal: implement the two tail-call
instructions end to end (decode + WAT + validate + lower + IR + `emit_core`) as **genuine BEAM tail calls
in constant stack space**, D3a-clean; unblock the 2 pure-`return_call` EH `.wast` files; land byte-
identical for modules that use neither. Decisions `Q1–Q8`; units `Q13-01 … Q13-06`. All prior-phase
decisions + the invariants ([`03-phase-workflow.md`](03-phase-workflow.md) §8) still hold.

**Baseline entering Phase 13** (keystone re-confirms on landing): ~1,978 gleam tests / 0 fail ·
`gleam build` zero warnings · `gleam format` clean · WASM conformance **46,529 pass / 1,768 skip / 0
fail** (Safe ≡ Unsafe, every `state_strategy × mem_tier`).

### Freeze milestones

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«TC-FROZEN»` — the 3 IR nodes (`ReturnCall`/`ReturnCallIndirect`/`ReturnCallImport`), the 2 AST instrs, the `rt_table.call_indirect_lookup` (+ `_at` + `t_`) seam signature, the `link` tail-import seam, the `.ir` printer/parser round-trip, and every exhaustiveness-forced arm (effect/optimizer as final barriers; validate/lower/emit as conservative-sound placeholders their units complete) | Q13-01 | `unclaimed` | Q13-02 … Q13-06 |

### Units

| Unit | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|
| **Q13-01** Keystone: surface + IR + `rt_table`/`link` tail seam freeze | `unclaimed` | — | `«TC-FROZEN»`; byte-identical default output; conservative-sound validate/lower/emit arms for Q13-03/04/05 to complete. |
| **Q13-02** decode (0x12/0x13) + WAT text | `unclaimed` | `«TC-FROZEN»` | Binary + text ingest of the two instructions → AST; round-trip tested. |
| **Q13-03** validate: tail-call typing rule | `unclaimed` | `«TC-FROZEN»` | Callee-results == function-results rule (reuses `TypeMismatch`), stack-polymorphic; `assert_invalid` spec tests. |
| **Q13-04** lower: bottom-transfer lowering | `unclaimed` | `«TC-FROZEN»` | Return-shaped lowering (dead continuation), import-vs-defined split → the 3 IR nodes. |
| **Q13-05** emit_core: constant-stack tail emission | `unclaimed` | `«TC-FROZEN»` | Real tail calls (direct reuse of the tail path; indirect via the lookup seam; imported via `link.call_import`); tail-position + constant-stack tests. |
| **Q13-06** Capstone | `unclaimed` | all above | **PHASE 13 PROVEN.** Official `return_call*.wast` green, constant stack, EH unblock, `OptNone≡Baseline≡Aggressive` differential; SVG + `docs/phase-13-surface.md`; `01-status.md`. |

### Landing log

_(one line per landing: `unit — N tests (was M, +K), conformance p/s/f, 0 warnings, format clean, byte-identical`)_

---

## Template (copy this block when the next phase starts)

> Phase N — «title». Goal & honest scope: see the phase overview. Decisions: continue the letter series
> (Phase 13 = `Q`, Phase 14 = `R`, Phase 15 = `S`; `#1` = keystone, last = honest scope). All prior-phase
> decisions and the invariants in [`03-phase-workflow.md`](03-phase-workflow.md) §8 still hold.

### Freeze milestones

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«X-FROZEN»` — … | 01 | `unclaimed` | … |

### Units

| Unit | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|
| **01** Interface freeze (keystone) | `unclaimed` | — | … |
| **…** | `unclaimed` | … | … |
| **N** Capstone | `unclaimed` | all above | **PHASE N PROVEN.** … |

### Landing log

_(one line per landing: `unit — N tests (was M, +K), conformance p/s/f, 0 warnings, format clean, byte-identical`)_
