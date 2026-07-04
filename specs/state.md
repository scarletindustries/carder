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

**No phase in flight.**

Phases 1–10 are complete and proven on `main` — see [`01-status.md`](01-status.md) §3. The last landed
work was **Phase 10** (LICM + cross-CF MemorySSA + range-based BCE), closing the memory optimizer.

**Baseline entering the next phase:** 1827 gleam tests / 0 fail · `gleam build` zero warnings ·
`gleam format` clean · WASM conformance **46,529 pass / 1,768 skip / 0 fail** (Safe ≡ Unsafe, every
`state_strategy × mem_tier`) · JS-on-BEAM 52 / 0 / 3.

To start the next phase: pick a candidate from [`02-roadmap.md`](02-roadmap.md), scope it per
[`03-phase-workflow.md`](03-phase-workflow.md), continue the decision-letter series (Phase 10 used
`N1–N8`, so the next is `O…`), and fill in the template below.

---

## Template (copy this block when a phase starts)

> Phase N — «title». Goal & honest scope: see the phase overview. Decisions: `O1–O8` (`O1` = keystone,
> `O8` = honest scope). All prior-phase decisions and the invariants in
> [`03-phase-workflow.md`](03-phase-workflow.md) §8 still hold.

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
