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

**No phase in flight.** Phases 11–15 are proven on `main` and compacted into
[`01-status.md`](01-status.md) §3:

- **Phase 11** — `--link` self-contained output.
- **Phase 12** — typed host-language bindings.
- **Phase 13** — WASM tail calls (`return_call`/`return_call_indirect`) → constant-stack BEAM tail calls.
- **Phase 14** — cross-module funcref-in-`elem` init (`table_copy.wast` residual closed, +1,088 pass).
- **Phase 15** — production tier-N C NIF (bit-identical to paged, node-safe fuzz, unchecked path,
  3.10–5.73× over the paged delegate).

**Current baseline:** 2,111 gleam tests / 0 fail · `gleam build` zero warnings · `gleam format` clean ·
WASM conformance **47,734 pass / 683 skip / 0 fail** (Safe ≡ Unsafe, every `state_strategy × mem_tier`).

**Pick the next phase from [`02-roadmap.md`](02-roadmap.md)** and copy the template block below into this
file to start it. The nearest-leverage candidates (roadmap "Suggested sequencing"): an EH-lowering unit
to drive the 2 legacy EH `.wast` files green (Phase-13's honest deferral); escape analysis (gated on
arc's frontend emitting object-heavy IR); the `rt_table_ets` multi-table fix; tier-N imported-memory
native path + `priv/*.so` packaging.

---

## Template (copy this block when the next phase starts)

> Phase N — «title». Goal & honest scope: see the phase overview. Decisions: continue the letter series
> (Phase 13 = `Q`, 14 = `R`, 15 = `S`, next = `T`; `#1` = keystone, last = honest scope). All prior-phase
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
