# Phase 14 — cross-module funcref-in-`elem`-segment initialization

> A small, focused **cross-module** phase: `ref.func` of an **imported** function, made a
> table-storable, `call_indirect`-able funcref that dispatches through the D3a import capability
> (`link.call_import`, never `erlang:apply` on table data). It flips the project's once-largest
> categorized conformance residual — `table_copy.wast` — to green. A module that uses no imported
> `ref.func` compiles **byte-identically** to Phase 13; a module that drives the new surface is
> **result-identical** across `OptNone ≡ Baseline ≡ Aggressive` and the full state/tier matrix.
> MEASURED, never promised (R16).

---

## The headline (measured)

WASM spec conformance, Safe profile, full re-vendored allowlist (identical under **Safe** and
**Unsafe**, `fail == 0` under every shipped `(state_strategy × mem_tier × table_tier)` combo):

| | pass | skip | fail |
|---|---|---|---|
| **Phase-13 close** | 46,646 | 1,771 | 0 |
| **Phase-14** (`table_copy.wast` cross-module funcref-in-`elem` asserts DRIVEN) | **47,734** | **683** | **0** |
| **Δ** | **+1,088** | **−1,088** | 0 |

`table_copy.wast` itself moves from **569 pass / ~1,080 skip** to **1,649 / 0 / 0** — the whole file
now builds and dispatches. The residual `683` skips are now dominated by the **511** SIMD text-format
frontend asserts (S13, out of scope for the WAT parser) plus the distinct const-expr /
imported-global element-init gap; the `"UnknownFunction"` cross-module funcref-in-`elem` bucket is
**measured 0**. Running gleeunit total: **2,080 pass / 0 fail** (was 2,073; **+7** in the dedicated
capstone proofs). `gleam build` zero warnings, `gleam format --check src test` clean.

---

## What shipped

The whole feature reduces to **one missing distinction and its downstream plumbing**: `ref.func` of an
imported function. `ir.RefFunc` always names a *defined* function (its invariant is preserved), so an
imported funcidx fell out as `Error(UnknownFunction)`. Everything else already existed — the func-import
dispatch vector (seeded before element segments run), the `link.call_import` capability, the
cross-module routing closures, and the funcref table-slot ABI `#(FuncType, closure)`.

| Stage | What landed |
|---|---|
| **IR + lower** (R14-01, keystone `«REFFUNC-IMPORT-FROZEN»`) | A new IR node `ir.RefFuncImport(slot, ty)` — a **pure barrier** mirroring `CallImport`, round-tripping losslessly in the `.ir` printer/parser, a pass-through in every effect/optimizer arm. Lowering splits exactly like `lower_call`: `ast.RefFunc(f)` with `f < ctx.imported` → `RefFuncImport(slot: f, ty)`, else `ir.RefFunc`. The distinct node is what keeps every non-imported path byte-identical and routes only mixed/imported segments to the general `init_elem_ref` path (pure-defined table-0 segments keep the frozen `init_elem` fast path). |
| **emit_core** (R14-02, the heart) | The real imported-funcref emission: `emit_ref_func_import` + the `render_ref_item` arm + `imported_reference_func_entry` (Cell **and** Threaded), emitting `#(func_type_term(ty), adapter_closure)` — the **unchanged** slot ABI. `all_reffunc`/`byte_ident_funcref` treat `RefFuncImport` as **not**-plain-`RefFunc`. |
| **the D3a adapter closure** (R14-02, R2) | A build-emitted closure capturing **only the literal slot integer**: Cell `fun(Args) -> link:call_import(rt_state:func_import_at(Slot), Args)`; Threaded `fun(St, Args) -> {link:call_import(rt_state:t_func_import_at(St, Slot), Args), St}` (threads `St` unchanged). `func_type_term(import_ty)` is the *same* renderer `call_indirect`'s guard-3 uses, so structural type-match works unchanged. Emitted **inline** in Core Erlang — no `link.imported_funcref` helper, `link.gleam` untouched. |
| **single-source import detection** (R14-02/R3) | `emit_core.needs_func_imports` is extended to scan **element segments** (and passive segments reachable via `table.init`) for `RefFuncImport`, made **public**, and `driver.module_calls_import` is changed to **call it**. Both operate on the identical lowered `irmod`, so there is structurally **one** detector — `instantiate/0` vs `instantiate/1` **cannot desync** (stronger than diffing two mirrors). |
| **runtime differential** (R14-03) | An import-routed funcref slot stores + dispatches identically across `TablePaged`/`TableEts`/`TableAtomics` × Cell/Threaded — pure test-only (the adapter seam is frozen to inline, so no `src/` file). |

**The package-ABI reshape (context).** The funcref table slot speaks the **package ABI** the Phase-13
funcref change established (a WASM function's Core boundary — `[]`→`'ok'`, `[v]`→bare `v`,
`[v₁..vₙ]`→tuple). The import adapter unpacks `link.call_import`'s result list and re-packages it as the
`function_return` the slot ABI expects, so `call_indirect`'s runtime is untouched: an imported funcref is
just another build-controlled closure in a slot.

---

## The acceptance table — proven, MEASURED

| Row | Proven by | Measured result |
|---|---|---|
| **The residual flips** | `table_copy.wast` driven by the main `conformance_test` (no vendor change — landing the feature lights up the real file); `skipcount`/`residual_audit` re-measured + tightened | `table_copy.wast` = **1,649 / 0 / 0**; headline **47,734 / 683 / 0**; `skip` dropped **1,088**; `max_residual_skips` lowered **1,900 → 750**; `phase14_pass_floor` added (**47,700**); `residual_audit` `uncategorised == []` with `"UnknownFunction"`/`"call_indirect_table"` removed (measure-then-remove) |
| **End-to-end dispatch** | `xlink_capstone_test.imported_funcref_matches_direct_call_test` + `_cross_combo_bit_identical_test` over `corpus/xlink` under Cell **and** Threaded × `TablePaged`/`TableEts`/`TableAtomics` | `via_ci(0,x) == direct(x)`, `via_ci(2,x) == ef1(x)`; `identity_across("xlink", …) == []` across every combo; `fail == 0` |
| **Fail-closed guards preserved** | `xlink_capstone_test.imported_funcref_fail_closed_guards_test` + `table_copy`'s 1,206 post-`table.copy` `assert_trap`s | `undefined element` → `uninitialized element` → `indirect call type mismatch`, same order as `call_indirect`, on import-routed slots and after `table.copy` shuffles; `fail == 0` |
| **D3a clean** | `emit_core_security_test.imported_funcref_adapter_has_no_ambient_authority_test` (R14-02) — re-run + cited by `xlink_capstone_test.imported_funcref_slot_is_d3a_clean_test` | the adapter captures only the literal slot; dispatch is `link:call_import` over `rt_state:func_import_at`/`t_func_import_at`; **no** `erlang:apply` on program data (Cell/Threaded/Unsafe) |
| **Arity in lockstep** | `xlink_capstone_test.ref_func_import_only_arity_lockstep_test` (a real decoded `ref.func`-of-import-only module) + R14-02's `import_bearing_detection_is_in_lockstep_test` | the single public `needs_func_imports` (element scan) that `module_calls_import` **delegates to** ⇒ instantiates as `instantiate/1`, links a provider, dispatches; desync structurally impossible |
| **Default unaffected** | `xlink_capstone_test.imported_funcref_opt_level_result_identical_test`; full conformance for all non-`table_copy` files UNCHANGED | non-imported-`ref.func` modules byte-identical; **`OptNone ≡ Baseline ≡ Aggressive`** result-identical on `xlink`; `fail == 0` everywhere |

"Green" here always means **MEASURED** (a count printed and asserted), never "it compiled" (R16/S11/R6).

---

## Honest scope (R8 — stated, not hidden)

- **Function references only.** `ref.func` of an imported *function* into an `elem` segment. **Not**
  externref construction, **not** cross-module *externref*-in-`elem`, **not** cross-module **table**
  imports beyond what Phase 6 landed, **not** threaded cross-instance linking (a named category —
  `cell` remains the proven target; roadmap §C).
- **No runtime shape change, no new trap reason.** The funcref stays `#(FuncType, closure)`; no new
  `rt_table`/`rt_ref`/`rt_state` data shape; `call_indirect`'s runtime is untouched. An imported funcref
  reached via `call_indirect` traps for exactly the reasons any funcref does (bounds → null → type,
  unchanged order).
- **The still-deferred *imported-global* element-init gap** (a segment initialised from an *imported
  global*'s `global.get` — a different residual from a `ref.func` of an imported *function*) stays
  categorized under `"imported-global element-init"` / `"NonConstInit"` / `"NonConstantExpr"`, MEASURED
  and named by the audits.

### A note on the authored backstop (`corpus/xlink`) and the ETS table tier

`corpus/xlink` is deliberately a **single-table** importer so it drives cleanly **end-to-end on all
three table tiers** (`TablePaged`/`TableEts`/`TableAtomics` × Cell/Threaded), satisfying the "every tier
proven e2e" acceptance row. During capstone bring-up a **pre-existing, Phase-14-orthogonal** limitation
surfaced: `carder_rt_table_ets_ffi:new/0` uses a single process-dictionary slot for its
delete-prior-on-reinstantiation discipline, so a module declaring **two or more tables** deletes its
first ETS table when the second is created in the *same* instantiation (`instantiate: badarg`). This is
a `rt_table_ets` **multi-table** gap, independent of imported funcrefs (a plain two-table defined-funcref
module fails identically) — it was never exercised e2e before because no *shipped* combo uses `TableEts`
(it appears only in R14-03's substrate-level differential). `table_copy.wast`'s own multi-table dispatch
runs green on the shipped `TablePaged`/`TableAtomics` combos; the single-table backstop keeps the ETS
e2e drive honest. The multi-table-ETS fix is left to the table-tier owner (roadmap), not folded into this
cross-module phase.

---

## One line per proof → the test that proves it

| Proof | Test |
|---|---|
| `table_copy.wast` runs green (1,649/0/0); headline 47,734/683/0, `fail == 0` | `test/carder/conformance/conformance_test.gleam` (vendored via `vendor/ALLOWLIST` + `vendor.sh`) |
| Skip audit honest + tight (`"UnknownFunction"`/`"call_indirect_table"` removed; ceiling lowered; pass floor added) | `test/carder/conformance/{skipcount,residual_audit}_test.gleam` |
| Imported funcref via `call_indirect` == a direct call of the import, across the matrix | `test/carder/tier/xlink_capstone_test.gleam` (`imported_funcref_matches_direct_call_test`) |
| Cross-strategy / cross-tier bit-identity (Cell/Threaded × Paged/Ets/Atomics) | `xlink_capstone_test.gleam` (`imported_funcref_cross_combo_bit_identical_test`) |
| `OptNone ≡ Baseline ≡ Aggressive` result-identical on `xlink` | `xlink_capstone_test.gleam` (`imported_funcref_opt_level_result_identical_test`) |
| The 3 ordered fail-closed guards fire on import-routed slots | `xlink_capstone_test.gleam` (`imported_funcref_fail_closed_guards_test`) + `corpus/xlink.{wat,wasm,expected}` |
| Arity lockstep — a `ref.func`-of-import-only module instantiates as `instantiate/1` and dispatches | `xlink_capstone_test.gleam` (`ref_func_import_only_arity_lockstep_test`) + R14-02's `reffunc_import_emit_test.gleam` (re-run + cited) |
| D3a clean — the adapter captures only the slot; `link.call_import`, no `erlang:apply` on program data | `test/carder/backend/emit_core_security_test.gleam` (`imported_funcref_adapter_has_no_ambient_authority_test`, re-run + cited) |
| Emit / dispatch / mixed-segment / non-zero-table / multi-value / passive-segment coverage | `test/carder/backend/reffunc_import_emit_test.gleam` (R14-02) |
| IR node freeze + `.ir` round-trip + pure-barrier arms | `test/carder/reffunc_import_freeze_test.gleam` (R14-01) |
| Runtime differential — import-routed slot store/dispatch identical across tiers × strategies | `test/carder/runtime/rt_table_reftype_differential_test.gleam` (R14-03) |
