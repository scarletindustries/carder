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
| `«TC-FROZEN»` — the 3 IR nodes (`ReturnCall`/`ReturnCallIndirect`/`ReturnCallImport`), the 2 AST instrs (`ReturnCall`/`ReturnCallIndirect`), the `.ir` printer/parser round-trip, and every exhaustiveness-forced arm (effect/optimizer as final barriers; validate/lower/emit as conservative-sound value-correct placeholders their units complete). **Per the reconciled scope (overview §2 ⚠ ABI note), the `rt_table.call_indirect_lookup` seam + the funcref-ABI change + the `link` tail-import path are NOT part of the freeze — they are self-contained in Q13-05; the keystone touched neither `rt_table.gleam` nor `link.gleam`.** | Q13-01 | `FROZEN ✓` | Q13-02 … Q13-06 |

### Units

| Unit | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|
| **Q13-01** Keystone: surface + IR vocabulary freeze | `done` | — | `«TC-FROZEN»`; byte-identical default output; 3 documented cross-file reaches (conservative-sound, value-correct **placeholders**) for the completion units: **validate.gleam** (`return`-shape operand typing landed; result-equality check + `assert_invalid` deferred to Q13-03), **lower.gleam** (bottom-transfer desugar to ordinary-call-then-`Return`; the real `ir.ReturnCall*` nodes deferred to Q13-04), **emit_core.gleam** (non-tail delegation via the existing `emit_call_direct`/`emit_call_indirect`/`emit_call_import` under `KBind(_, Return, KReturn)`; forced-`KReturn` constant-stack tail emit + `rt_table` lookup seam + funcref-ABI change deferred to Q13-05). **Did NOT touch `rt_table.gleam` / `link.gleam`** (Q13-05's, per overview §2 ⚠ ABI note). |
| **Q13-02** decode (0x12/0x13) + WAT text | `done` | `«TC-FROZEN»` | Binary + text ingest of the two instructions → AST; round-trip tested (incl. live WAT↔binary via `wat2wasm --enable-tail-call`). |
| **Q13-03** validate: tail-call typing rule | `done` | `«TC-FROZEN»` | Callee-results == function-results rule (reuses `TypeMismatch`, no new variant), stack-polymorphic; 11 `assert_invalid`/positive spec tests. |
| **Q13-04** lower: bottom-transfer lowering | `done` | `«TC-FROZEN»` | Return-shaped lowering (`consume_dead`+`end_or_else`, no `wrap_let`), import-vs-defined split → the 3 IR nodes now flow to `emit` (the keystone placeholders are LIVE, value-correct/non-tail until Q13-05). 12 tests. |
| **Q13-05** emit_core + rt_table: constant-stack tail codegen | `done` | `«TC-FROZEN»` | Real tail calls: direct (forced `KReturn`), indirect (`rt_table.call_indirect_lookup` seam + tail-apply the package-ABI target), imported (existing path under `KReturn`, value-correct/bounded frame). Funcref stored closures → **package-ABI tail-transparent**; non-tail `call_indirect` re-wraps package→list in `rt_table` (arity via `result_arity`); cascaded across all 3 table tiers. Aggressive-inliner excludes tail-call bodies. Constant stack proven to 1,000,000 (direct + indirect + even/odd). Funcref/`elem` modules now **result-identical** (differential green). 23 tests. |
| **Q13-06** Capstone | `unclaimed` | all above | **PHASE 13 PROVEN.** Official `return_call*.wast` green, constant stack, EH unblock, `OptNone≡Baseline≡Aggressive` differential; SVG + `docs/phase-13-surface.md`; `01-status.md`. |

### Landing log

_(one line per landing: `unit — N tests (was M, +K), conformance p/s/f, 0 warnings, format clean, byte-identical`)_

- **Q13-02 decode + WAT** — 1,997 gleam tests (was 1,984, +13 in `test/twocore/frontend/wasm/tail_call_ingest_test.gleam`), 0 fail · `gleam build` 0 warnings · `gleam format --check src test` clean · **ingest byte-identical for modules using neither instruction**. `0x12 → ast.ReturnCall`, `0x13 → ast.ReturnCallIndirect` (typeidx then tableidx, anti-swap); WAT `return_call`/`return_call_indirect` (shared `call_indirect_instr` via a ctor param). `return_call_ref`/SIMD/GC neighbours still reject (Q8). Owns `decode.gleam`, `wat.gleam` + the new ingest test. The `diff_tail` WAT↔binary equivalence ran LIVE via local `wat2wasm 1.0.41 --enable-tail-call`.
- **Q13-01 «TC-FROZEN»** — 1,984 gleam tests (was 1,978, +6 in `test/twocore/tail_call_freeze_test.gleam`), 0 fail · `gleam build` 0 warnings · `gleam format --check src test` clean · **default output byte-identical** (the 3 IR nodes + 2 AST instrs are inert-by-default — nothing produces them until Q13-02/04; the new effect/optimizer/lower arms are dead until then, and the validate/lower/emit reaches are unreachable at freeze time since no module yet decodes `0x12`/`0x13`). Owns `ir.gleam` (3 nodes) · `ast.gleam` (2 instrs) · `effect.gleam` · `printer.gleam` · `parser.gleam` · `ir_lower.gleam` · `ir_opt/{pass,baseline,aggressive,bce,loop_analysis,mem_clobber,mem_ssa}.gleam` · new freeze test. Reaches (placeholders): `validate.gleam` · `lower.gleam` · `emit_core.gleam`. **Untouched: `rt_table.gleam`, `link.gleam`.**

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
