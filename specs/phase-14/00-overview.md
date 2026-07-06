# Phase 14 — Cross-module funcref-in-`elem`-segment initialization

> **Status:** scoped, awaiting the scoping fan-out + critique. No code yet. Follows the fixed skeleton in
> [`../03-phase-workflow.md`](../03-phase-workflow.md) §2. Decisions are `R1–R8` (the letter series
> continues from Phase 13's `Q`; `R1` = keystone, `R8` = honest scope); **units** are `R14-01 … R14-04`.
>
> **All prior-phase decisions and the permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8)
> still hold.** Baseline entering: ~1,978 tests / 0 fail · `gleam build` zero warnings · `gleam format`
> clean · WASM conformance 46,529 / 1,768 / 0 (Safe ≡ Unsafe, every `state_strategy × mem_tier`). The
> keystone re-confirms the exact running total on landing.
>
> Small, focused **cross-module** phase. It folds its reconciliation into this overview unless the
> fan-out + critique surface a genuine conflict.

---

## §0. Where this phase sits

Phase 6 landed cross-module linking under `cell` and **direct** dispatch of imported functions
(`CallImport`). This phase closes the deeper cross-module case that Phase 6 left categorized:
initializing a table's `elem` segment with `ref.func` of an **imported** function and then reaching it
via `call_indirect`. It is **the single largest categorized conformance residual** — the `table_copy.wast`
verifier imports module `a`'s functions, fills `elem` segments with `ref.func` of those imports across
two tables, then dispatches indirectly (**~1,080 asserts skip today; 569 same-module/multi-table asserts
already pass**). See [`../02-roadmap.md`](../02-roadmap.md) §C.

The entire feature reduces to **one missing distinction and its downstream plumbing**: `ref.func` of an
imported function. `call` of an import already splits into the D3a import capability
(`link.call_import`); `ref.func` does not — it always names a *defined* function, so building a funcref
for an imported funcidx fails with `UnknownFunction`. Everything else the feature needs already exists:
the func-import dispatch vector (seeded before element segments run), the `link.call_import` capability,
the cross-module routing closures, and the funcref table-slot ABI `#(FuncType, closure)`. The work is to
route an imported `ref.func` into an **adapter closure** that reads its func-import slot and dispatches
via `link.call_import` — reusing the exact machinery `CallImport` already uses, D3a-clean.

---

## §1. Goal & acceptance

**Goal.** Make `ref.func` of an imported function a first-class, table-storable, `call_indirect`-able
funcref that dispatches through the D3a import capability (never `erlang:apply` from table data), across
both state strategies and all table tiers — flipping the `table_copy.wast` cross-module residual to pass.
A module that uses no imported `ref.func` compiles **byte-identically** to Phase 13.

**Acceptance table** (owned by the capstone, R14-04):

| Area | Must demonstrate |
|---|---|
| The residual flips | `table_copy.wast`'s cross-module funcref-in-elem asserts (~1,080) are **measured** to pass (per R16: report the reality, whatever it is); `fail=0`; the `skip` total drops accordingly and `max_residual_skips` is lowered to match. |
| End-to-end dispatch | An imported function placed in a table via an active `elem` `ref.func` segment and called through `call_indirect` returns the same value as a direct `call` of that import — under Cell **and** Threaded, on every table tier (`TablePaged`/`TableEts`/`TableAtomics`). |
| Fail-closed guards preserved | The 3 ordered `call_indirect` guards still fire correctly for slots holding imported funcrefs (index-in-bounds → `UndefinedElement`; slot-non-null → `UninitializedElement`; exact `FuncType` → `IndirectCallTypeMismatch`), including after `table.copy` shuffles the slots (the `table_copy` trap asserts). |
| D3a clean | The imported-funcref slot's closure captures only the literal integer slot; dispatch is `link.call_import(func_import_at(slot), args)`, never `erlang:apply(Mod,Fun,Args)` from table/program data. The codegen-security test is extended to cover it. |
| Arity in lockstep | `instantiate/0` vs `instantiate/1` never desyncs: a module that only `ref.func`s an import (no `CallImport` in any body) is still recognized as import-bearing by **both** `emit_core` (seeds the func-import vector) and the driver (weaves the provider closures). |
| Default unaffected | A module with no imported `ref.func` compiles byte-identically (the funcref value shape `#(FuncType, closure)` is unchanged; pure-defined table-0 segments keep the frozen `init_elem` fast path); `gleam test` + conformance stay green; `OptNone ≡ Baseline ≡ Aggressive` bit-identical across the full `(mode × state_strategy × mem_tier × table_tier)` matrix. |

**Honest scope** (= decision R8, restated in §2):
- **Function references only.** `ref.func` of an imported function into an `elem` segment (active,
  passive-then-`table.init`, and declarative). Not externref construction, not cross-module *table*
  imports beyond what Phase 6 landed, not threaded cross-instance linking (still `../02-roadmap.md` §C).
- **No runtime shape change.** The funcref stays `#(FuncType, closure)`; no new `rt_table`/`rt_ref`/
  `rt_state` data shape; `call_indirect`'s runtime is untouched (an imported funcref is just another
  build-controlled closure in a slot).
- **No new trap reason.** The imported-funcref path reuses the existing element/indirect traps.

---

## §2. Decisions (R1–R8)

> Each decision is **frozen** for this phase. Raise a disagreement with the planner BEFORE building. R1 is
> the keystone; R8 is honest scope.

**R1 (keystone) — A new IR node `RefFuncImport(slot, ty)` (mirroring `CallImport`), produced by an
import-split in lowering.** The load-bearing new thing. `ir.RefFunc` keeps its invariant ("`fn_name`
names a *defined* function"); imported `ref.func` becomes a distinct node carrying the func-import slot +
the imported `FuncType`. Lowering splits exactly like `lower_call`: `ast.RefFunc(f)` with
`f < ctx.imported` → `RefFuncImport(slot: f, ty)`, else `ir.RefFunc("f"<>f)`. The distinct node (rather
than overloading `ir.RefFunc`) is what keeps every non-imported path byte-identical and lets the emitter
route mixed/imported segments to the general `init_elem_ref` path while pure-defined table-0 segments keep
the frozen `init_elem` fast path. The node is a **pure barrier** in the optimizer/effect layers (like
`RefFunc`/`CallImport`), and round-trips losslessly in the `.ir` printer/parser (D5).

**R2 — The imported-funcref slot is an adapter closure over the func-import capability (D3a).** The table
slot is the unchanged `#(FuncType, closure)` funcref, where `FuncType = func_type_term(import_ty)` (the
*same* renderer `call_indirect`'s guard-3 uses, so structural type-match works unchanged) and the closure
is a build-emitted adapter capturing only the literal slot integer:
- **Cell:** `fun(Args) -> link:call_import(rt_state:func_import_at(Slot), Args)`.
- **Threaded:** `fun(St, Args) -> {link:call_import(rt_state:t_func_import_at(St, Slot), Args), St}` —
  threads `St` unchanged (the callee threads its own state inside the routing closure), exactly as
  `emit_call_import` does under `Threading`.

No new `rt_table`/`rt_ref`/`rt_state`/`link` runtime data or dispatch function is required — `func_import_at`
/ `t_func_import_at` / `call_import` already exist; the adapter is emitted **inline** in Core Erlang. The
inline-vs-helper seam is **frozen to inline** (§3): no `link.imported_funcref` helper is introduced and
`link.gleam` is not touched by R14-02 or R14-03. This is D3a-clean: the closure is build-controlled, only the
integer index/slot is program-derived, and there is no `erlang:apply` on program data.

**R3 — The import-bearing detection is ONE public predicate the driver calls (single source of truth).**
Today `emit_core.needs_func_imports` scans only *function bodies* for `CallImport` to decide whether to seed
the func-import vector; `driver.module_calls_import` maintains a *separate* mirror of it to decide whether to
weave provider closures into `Imports`. A module that only `ref.func`s an import in an `elem` segment (no
`CallImport` in any body) is missed by both — so the func-import vector is never seeded and
`func_import_at(slot)` would fault, or the `instantiate/0` vs `instantiate/1` arity desyncs.
`needs_func_imports` is extended to additionally scan element segments (and passive segments reachable via
`table.init`) for `RefFuncImport`, made **public**, and `driver.module_calls_import` is changed to **call
it** — both operate on the identical lowered `irmod`, so there is structurally **one** detector and no mirror
to desync (strictly stronger than diffing two copies by eye). A single unit owns both edits (R14-02).

**R4 — Seeding order is already correct; do not reorder.** The func-import vector is seeded *before*
element segments run in both `full_cell_body` and `full_threaded_body`, so an imported-funcref element
entry can safely read `func_import_at(slot)` at seed time. `slot == funcidx` holds because *all* function
imports are seeded (function imports occupy funcidx `0..imported-1`). These invariants are load-bearing —
the phase preserves them, it does not touch them.

**R5 — Byte-identical by default.** The funcref value shape is unchanged; the new IR node only exists for
imported `ref.func`; `all_reffunc`/`byte_ident_funcref` still see plain `ir.RefFunc` items for
pure-defined segments and keep the frozen `init_elem` fast path. A module with no imported `ref.func`
compiles byte-identically to Phase 13 (H7/§8). Where the capstone drives the new surface, the bar is
result-identical across `OptNone ≡ Baseline ≡ Aggressive` and the full tier/state/table matrix.

**R6 — Correctness is the real conformance file + a cross-strategy/tier differential, not goldens.**
`table_copy.wast` is already driven from JSON fixtures, so implementing the feature lights up the **real
file** — the proof is its measured pass flip (Tier-A baked values), plus an authored in-scope backstop
(`corpus/xlink`) exercising an imported funcref through `call_indirect` across Cell/Threaded × all table
tiers, bit-identical. Spec-cited: an imported function reached via `call_indirect` must behave identically
to a direct `call` of that import.

**R7 — Categorization tightens, never loosens.** After the flip, the residual-audit `allowed_phrases`
entry that covered this category (`"UnknownFunction"` / `"call_indirect_table"` for cross-module
funcref-in-elem) is **removed** so a regression that re-skips these asserts turns the suite red instead of
hiding in the residual. `skipcount_test` constants are re-measured (`max_residual_skips` lowered).

**R8 — Honest scope.** As §1: imported function references into `elem` segments only; no externref
construction, no threaded cross-instance linking, no runtime shape change, no new trap reason.

---

## §3. Dependency DAG & freeze milestone

```
   R14-01 keystone ──«REFFUNC-IMPORT-FROZEN»──┬──▶ R14-02 backend emit + seed + driver mirror ─┐
   (RefFuncImport node, lower import-split,     │    (adapter closures, needs_func_imports scan, │
    IR plumbing, conservative fail-closed        │     driver.module_calls_import — LOCKSTEP)     ├─▶ R14-04 capstone
    emit arm — byte-identical, still-skips)      └──▶ R14-03 runtime differential coverage ───────┘   (table_copy flip,
                                                                                                        corpus/xlink, docs)
```

**Freeze milestone:**

| Milestone | Produced by | Unblocks |
|---|---|---|
| `«REFFUNC-IMPORT-FROZEN»` — the `RefFuncImport(slot, ty)` IR node, the lowering import-split, the `.ir` round-trip, every exhaustiveness arm (effect/printer/parser/ir_lower/ir_opt as pure-barrier pass-throughs), and a **conservative fail-closed `emit_core` arm** (imported `ref.func` still yields the existing skip → byte-identical, no regression) that R14-02 completes | R14-01 | R14-02, R14-03, R14-04 |

**Waves.** Wave 0: R14-01. Wave A (behind the freeze): R14-02 (the heart — completes emit + seed + the
driver mirror in one unit for lockstep), R14-03 (runtime differential coverage, mostly test-only). Wave B:
R14-04 capstone.

**Open seams for the scoping fan-out / critique to resolve:**
1. **FROZEN to inline (resolved).** The Cell/Threaded adapter closures are emitted **inline** in Core
   Erlang — no `link.imported_funcref(slot)` runtime helper is introduced, and `link.gleam` is not touched
   by R14-02 or R14-03. R14-03 is pure test-only and builds its differential substrate by hand
   (`rt_table.funcref(ty, fn(...))`). Inline is D3a-clean and byte-neutral for non-imported modules.
2. The exact keystone conservative-emit-arm (does it keep returning today's `UnknownFunction`, or a
   clearer `RefFuncImportUnsupported` placeholder?) — it must be byte-identical to today for the skipped
   set and provably no-regression for the passing set.
3. Passive-segment `ref.func` of an import reached via `table.init` (not just active segments) — confirm
   R3's element-scan covers passive segments and the capstone exercises one.
4. Whether the `table_copy` trap asserts (guards 1–2 after `table.copy` shuffles slots) need any special
   handling for import-routed slots, or fall out for free from the unchanged slot ABI.

---

## §4. File-ownership map (one owner per file, D1)

| Unit | Owns / creates | Deliberate cross-file reaches |
|---|---|---|
| **R14-01** keystone | `src/twocore/ir.gleam` (`RefFuncImport`) · `src/twocore/frontend/wasm/lower.gleam` (the import-split) · `src/twocore/ir/effect.gleam` · `src/twocore/ir/printer.gleam` · `src/twocore/ir/parser.gleam` · `src/twocore/middle/ir_lower.gleam` · `src/twocore/middle/ir_opt/{baseline,aggressive,bce,mem_clobber}.gleam` (barrier arms) · new `test/twocore/reffunc_import_freeze_test.gleam` | the forced pass-through + conservative fail-closed arms into `src/twocore/backend/emit_core.gleam` (four arms; completed by R14-02), recorded in `state.md` |
| **R14-02** backend + driver (the heart, lockstep) | the real imported-funcref emission in `src/twocore/backend/emit_core.gleam` (`emit_ref_func_import`, `imported_reference_func_entry` Cell+Threaded, the `render_ref_item` arm, the `render_ref_global_init` completion, `all_reffunc`/`byte_ident_funcref` treating `RefFuncImport` as not-plain, and the extended **public** `needs_func_imports` element-segment scan) **and** the delegating change in `test/twocore/conformance/driver.gleam` (`module_calls_import` now **calls** `emit_core.needs_func_imports` — one shared predicate so the arity detection cannot desync) + `emit_core` e2e/dispatch tests | — |
| **R14-03** runtime differential | `test/twocore/runtime/rt_table_reftype_differential_test.gleam` (+ siblings): an import-routed funcref slot stores/dispatches identically across `TablePaged`/`TableEts`/`TableAtomics` × Cell/Threaded — **test-only; owns no `src/` file** (the adapter seam is frozen to inline, §3) | — |
| **R14-04** capstone | `test/twocore/conformance/skipcount_test.gleam` + `residual_audit_test.gleam` (re-measure + tighten) · a new `test/twocore/conformance/corpus/xlink.{wat,wasm,expected}` backstop + `test/twocore/tier/combos.gleam` wiring · `docs/phase-14-surface.md` + `docs/phase-6-surface.md` accounting update · `docs/wasm-conformance.svg` (regen) · `../01-status.md` | the single conformance-wiring + status point only |

---

## §5. How to claim & complete

Standard loop ([`../03-phase-workflow.md`](../03-phase-workflow.md) §7 + §9): read
[`../state.md`](../state.md); claim a unit; for R14-01 freeze `«REFFUNC-IMPORT-FROZEN»` and land green with
byte-identical default output (the imported-funcref case still skips, exactly as today); build R14-02/03
behind the frozen node; satisfy the per-unit Definition of Done (spec-cited tests, doc comments,
`gleam format --check src test` clean, `gleam build` zero warnings, the unit's suite green); update
`state.md`. The capstone (R14-04) proves the acceptance table (measured `table_copy` flip, the
cross-strategy/tier differential, D3a, arity lockstep), regenerates the conformance SVG, then this phase
is compacted into [`../01-status.md`](../01-status.md) and `phase-14/` removed.

> **Next step (per the methodology):** a scoping fan-out + adversarial critique before freezing — the
> arity-desync lockstep (R3), the D3a adapter closure (R2), and the byte-identity of the keystone's
> conservative arm (R5, open seam 2) are exactly the areas a critique should pressure-test.
