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

**Phases 11, 12 & 13 are proven on `main` and compacted into [`01-status.md`](01-status.md) §3.** Two
follow-on phases remain, scoped + adversarially-validated, landing in sequence: **Phase 14** —
cross-module funcref-in-`elem` init; **Phase 15** — production tier-N C NIF. This ledger tracks Phase 14.

---

### ▶ Phase 14 — Cross-module funcref-in-`elem`-segment initialization

Overview: [`phase-14/00-overview.md`](phase-14/00-overview.md). Goal: make `ref.func` of an **imported**
function a first-class, table-storable, `call_indirect`-able funcref dispatching through the D3a import
capability, across both state strategies + all table tiers — flipping the `table_copy.wast` cross-module
residual (~1,080 asserts) to pass. Byte-identical for modules with no imported `ref.func`. Decisions
`R1–R8`; units `R14-01 … R14-04`. All prior-phase decisions + the invariants
([`03-phase-workflow.md`](03-phase-workflow.md) §8) still hold.

**Baseline entering Phase 14** (keystone re-confirms on landing): **2,049 gleam tests / 0 fail** ·
`gleam build` zero warnings · `gleam format` clean · WASM conformance **46,646 pass / 1,771 skip / 0
fail** (Safe ≡ Unsafe, every `state_strategy × mem_tier`).

**Scoping critique verdict:** GO, no architectural blocker — the imported-funcref adapter closure is
value-correct and avoids the Phase-13 `function_return`-package-vs-list-ABI bug class (`link.call_import`
already returns the result **list**, which is exactly the funcref-slot ABI, so **no re-wrap**). Doc fixes
applied: adapter frozen to **inline** (`link.gleam` untouched); the import-bearing predicate is **one
public `needs_func_imports`** the driver **delegates** to (no mirrored desync — this is the exact class of
bug Phase 13's capstone had to hand-fix in `driver.gleam`); `render_ref_global_init` completed;
capstone drives `TableEts` end-to-end + measures-then-removes the audit phrase.

### Freeze milestones

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«REFFUNC-IMPORT-FROZEN»` — the `RefFuncImport(slot, ty)` IR node, the lowering import-split, the `.ir` round-trip, every exhaustiveness arm (effect/printer/parser/ir_lower/ir_opt as pure-barrier pass-throughs; the forced `collect_expr` pass-through), and a conservative fail-closed `emit_core` arm (imported `ref.func` still yields the existing skip → byte-identical, no regression) that R14-02 completes | R14-01 | `unclaimed` | R14-02, R14-03, R14-04 |

### Units

| Unit | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|
| **R14-01** Keystone: `RefFuncImport` node + lower split + IR plumbing | `done` | — | `«REFFUNC-IMPORT-FROZEN» ✓`; byte-identical (imported `ref.func` still skips `UnknownFunction`, conformance unchanged). Import-split wired at **all three** `ref.func` sites (body + element-segment/const-expr + global-init) so R14-02 flips `table_copy` without re-touching `lower.gleam` (D1). `collect_expr` pass-through is PERMANENT. 8 freeze tests. |
| **R14-02** Backend + seed + driver (the heart, lockstep) | `unclaimed` | `«REFFUNC-IMPORT-FROZEN»` | Real imported-funcref emission (inline D3a adapter, Cell+Threaded; `render_ref_item` + `render_ref_global_init` arms; `all_reffunc`/`byte_ident_funcref` treat it as not-plain; `needs_func_imports` scans element segments) + the driver **delegates** to the now-public `needs_func_imports`. |
| **R14-03** Runtime differential coverage | `unclaimed` | `«REFFUNC-IMPORT-FROZEN»` | An import-routed funcref slot stores/dispatches identically across `TablePaged`/`TableEts`/`TableAtomics` × Cell/Threaded; the 3 guards fire (incl. after `table.copy`). Pure test-only (no `src/` file; adapter is inline). |
| **R14-04** Capstone | `unclaimed` | all above | **PHASE 14 PROVEN.** Measured `table_copy` flip (~1,080), `xlink` corpus (incl. `TableEts` e2e), D3a, arity single-source-of-truth, `OptNone≡Baseline≡Aggressive` result-identical; SVG + `docs/phase-14-surface.md`; `01-status.md`. |

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
