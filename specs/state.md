# Implementation State — the live ledger

> The swarm's shared ledger for **the phase currently in flight** in **carder** (the compiler backend).
> Before claiming work, read it; after finishing, update it. It is a *working* file, not a history
> archive — completed phases are compacted into [`01-status.md`](01-status.md) once proven, and this
> file resets to the template below for the next phase.
>
> **How to use this file:** [`03-phase-workflow.md`](03-phase-workflow.md) §7.
> **Where we are:** [`01-status.md`](01-status.md) · **What's next:** [`02-roadmap.md`](02-roadmap.md)
> · **Architecture:** [`00-high-level.md`](00-high-level.md) · **Frontend contract:**
> [`FRONTEND-API.md`](FRONTEND-API.md)
>
> The **WebAssembly frontend** has its own ledger in the **scribbler** repo (`specs/state.md`). A phase
> that spans both repos is claimed in both, with each side stating what it hands the other.

**Legend — unit status:** `unclaimed` · `in-progress (name)` · `blocked (on …)` · `done`
**Legend — freeze milestone:** a published, compiling type/signature stub that unblocks downstream
units. Announce it here the moment it lands (`FROZEN ✓` / `published ✓`).

---

## Current phase

**No phase in flight.** Phases 11–15 are proven and compacted into [`01-status.md`](01-status.md) §3:

- **Phase 11** — `--link` self-contained output.
- **Phase 12** — typed host-language bindings.
- **Phase 13** — WASM tail calls (`return_call`/`return_call_indirect`) → constant-stack BEAM tail
  calls. *(Frontend half now lives in the scribbler repo; the IR + `emit_core` half is here.)*
- **Phase 14** — cross-module funcref-in-`elem` init (`table_copy.wast` residual closed, +1,088 pass).
  *(Proven pre-split; the `.wast` evidence now lives in the scribbler repo.)*
- **Phase 15** — production tier-N C NIF (bit-identical to paged, node-safe fuzz, unchecked path,
  3.10–5.73× over the paged delegate).

**Then the repo split** — carder became backend-only (IR, middle-end, Core Erlang codegen + linking,
runtime, `embed`, `carder/cli`, the `.ir`-entry CLI); the WebAssembly frontend, the wasm host shims and
the entire spec-test conformance suite moved to **scribbler**. See [`01-status.md`](01-status.md) for
what moved and [`FRONTEND-API.md`](FRONTEND-API.md) for the contract that replaced the in-tree
coupling.

**Baselines.**

| | Figure | Provenance |
|---|---|---|
| **Historical (pre-split)** | `2,221` gleam tests / 0 fail · `gleam build` zero warnings · `gleam format` clean · WASM conformance **47,734 pass / 683 skip / 0 fail** (Safe ≡ Unsafe, every `state_strategy × mem_tier`) | the one tree, at the Phase-15 capstone, before the split. Cited as history — **not** carder's current number. |
| **Current (carder-only)** | gleam tests: **re-measure on the split tree** (`gleam test`; carder keeps roughly the backend 56% of the pre-split suite) · `gleam build` zero warnings · `gleam format` clean · the `.ir` corpus differential green | measure it, write the number here, and don't quote a number you didn't run. |
| **Conformance** | **not carder's metric any more.** The `pass / skip / fail` triple is measured and reported in the **scribbler** repo. | a green carder capstone is not by itself evidence conformance held — see [`03-phase-workflow.md`](03-phase-workflow.md) §5. |

The split's proof of cleanliness: carder's CI no longer contains the wabt / `wast2json` /
vendored-testsuite block at all, and `test/carder/ir/corpus/*.ir` (35 programs, spec-sourced
`.expected` values copied verbatim) drives the acceptance suite from IR alone. It was **measured**
pre-split that `wasm → .beam` is byte-identical to `wasm → .ir → .beam` for all 32 corpus programs of
wasm origin, so the pre-split proofs carry over unchanged.

**Pick the next phase from [`02-roadmap.md`](02-roadmap.md)** and copy the template block below into
this file to start it. The nearest-leverage candidates (roadmap "Suggested sequencing"), tagged by
owning repo:

- **carder** — escape analysis (gated on a frontend emitting object-heavy IR: arc, `alii/arc`); the
  `rt_table_ets` multi-table fix; tier-N imported-memory native path + `priv/*.so` packaging.
- **scribbler** — an EH-lowering unit to drive the 2 legacy EH `.wast` files green (Phase 13's honest
  deferral). If it needs anything from carder, it needs a *general seam*, proposed here as an additive,
  default-off change to [`FRONTEND-API.md`](FRONTEND-API.md).

---

## Template (copy this block when the next phase starts)

> Phase N — «title». Goal & honest scope: see the phase overview. Decisions: **carder's post-split
> series is `C-`-prefixed** — Phase 13 = `Q`, 14 = `R`, 15 = `S` were the last of the shared pre-split
> run, so the next carder phase is `C-T`, then `C-U`, `C-V`, … (`#1` = keystone, last = honest scope).
> The unprefixed letters `A`–`S` belong to the pre-split shared history and are never reissued.
> **scribbler mints `S-A`, `S-B`, … in its own repo**, so the two series can never collide. All
> prior-phase decisions and the invariants in [`03-phase-workflow.md`](03-phase-workflow.md) §8 still
> hold.

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

_(one line per landing: `unit — N tests (was M, +K), corpus differential green, 0 warnings, format clean, byte-identical`. If the phase widened [`FRONTEND-API.md`](FRONTEND-API.md), also record who re-ran the scribbler-side conformance and what it measured.)_
