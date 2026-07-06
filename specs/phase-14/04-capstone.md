# R14-04 — The capstone: Phase 14 proven (cross-module funcref-in-`elem`, end-to-end)

> **Status:** scoped, awaiting build. **Owner:** R14-04 (the capstone — Wave B, goes last and alone).
> **Depends on:** the whole DAG behind `«REFFUNC-IMPORT-FROZEN»` — R14-01 (keystone: the
> `RefFuncImport(slot, ty)` IR node + the lowering import-split + the `.ir` round-trip + every
> exhaustiveness arm + the conservative fail-closed `emit_core` arm), R14-02 (the heart: the real
> imported-funcref emission — `emit_ref_func_import`, `imported_reference_func_entry` Cell+Threaded, the
> `render_ref_item` arm, the `render_ref_global_init` completion, `all_reffunc`/`byte_ident_funcref` treating
> `RefFuncImport` as not-plain, the extended **public** `needs_func_imports` element-segment scan **and** the
> delegating `driver.module_calls_import` (it calls `needs_func_imports`) — LOCKSTEP), R14-03 (the runtime differential: an import-routed funcref slot stores/dispatches
> identically across `TablePaged`/`TableEts`/`TableAtomics` × Cell/Threaded — pure test-only, no `src/`
> file, since the adapter seam is frozen to inline). **Read order:**
> [`00-overview.md`](00-overview.md) → the distilled codebase map (`brief-phase14-xmodule-elem.md`) →
> this doc.
>
> **A capstone CONFIRMS green; it does not re-derive prior units.** R14-01…03 each shipped their own
> spec-cited suite (the freeze test; the emit e2e/dispatch + arity tests; the rt_table reftype/tier/state
> differentials). This unit ties the pipeline end-to-end, **measures** the `table_copy.wast` cross-module
> funcref-in-`elem` residual flip on the **real conformance file**, drives an **authored in-scope
> backstop** (`corpus/xlink`) across the state/tier matrix, tightens the audits so a regression turns the
> suite red, re-measures the conformance + test headline, regenerates the SVG, writes the surface doc, and
> compacts the phase into [`../01-status.md`](../01-status.md). Where a prior unit already proves a
> property (R14-02's D3a codegen-security assertion; R14-03's tier/state differential), the capstone
> **re-runs it green and cites it** — it does not restate the proof.
>
> **Honors R5** (byte-identical by default for modules with no imported `ref.func`; where the new surface
> is driven, **result-identical** across `OptNone ≡ Baseline ≡ Aggressive` and the full
> `(mode × state × mem × table)` matrix), **R6** (correctness = the real `table_copy.wast` + a
> cross-strategy/tier differential, **not** goldens/change-detectors), **R7** (categorization tightens,
> never loosens — the audit phrases that hid this category are removed, the skip ceiling lowered, a pass
> floor added), **R8** (honest scope — imported *function* references into `elem` only; no externref, no
> threaded cross-instance linking, no runtime shape change, no new trap reason). It is the single unit
> that **owns the conformance-wiring / registration / status surface** (D1) and the sole point that
> **proves the §1 acceptance table**.
>
> All prior-phase decisions and the permanent invariants
> ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold. Entering baseline (from
> [`../01-status.md`](../01-status.md), Phase-12 close, re-confirmed by R14-01…03 on landing):
> **~1,978 Gleam tests / 0 fail**, `gleam build` zero warnings, `gleam format --check` clean, WASM
> conformance **46,529 / 1,768 / 0** (Safe ≡ Unsafe, every `state_strategy × mem_tier`). This unit
> re-measures and re-confirms the exact running totals on landing.

---

## §1. Goal

Turn "the pipeline can build and dispatch an imported funcref" into "**the phase is proven**". Concretely:

1. **Measure the `table_copy.wast` residual flip on the REAL file (R6/R16).** `table_copy.wast` is
   *already* driven from JSON fixtures (`vendor/ALLOWLIST:82`), so landing R14-01…03 lights up the real
   file with **no vendor change**. The capstone re-runs the main `conformance_test`, **measures** the
   cross-module funcref-in-`elem` asserts flipping skip→pass (`skipcount_test:20` records **1080** today;
   `table_copy`'s other **569** same-module + multi-table asserts already pass, `skipcount_test:26`),
   asserts `fail == 0`, and reports the reality — whatever it is (per R16: report the measured number, not
   a promised "1649 flip", S11).
2. **Author an in-scope cross-module backstop** — `corpus/xlink.{wat,wasm,expected}` (R6): a provider
   module `a` exporting funcref-able functions, `(register "a")`, and an importer module `b` that fills an
   active `elem` segment with `ref.func` of those **imported** functions across **two** tables (table 0
   and a non-zero table), then dispatches via `call_indirect`. Wired through `combos.gleam` and driven
   across **Cell / Threaded × every table tier**, asserting bit-identical values + identical traps.
3. **Prove the §1 acceptance table (overview §1)** end-to-end: the residual flip (`fail == 0`); the
   cross-strategy / cross-tier differential (an imported funcref via `call_indirect` returns the same
   value as a direct `call` of that import, under Cell **and** Threaded, on `TablePaged`/`TableEts`/
   `TableAtomics`); **D3a** (the slot's adapter closure captures only the literal slot integer and
   dispatches via `link.call_import`, never `erlang:apply` on table/program data); **arity lockstep** (a
   module that only `ref.func`s an import — no `CallImport` in any body — is import-bearing to **both**
   `emit_core.needs_func_imports` and `driver.module_calls_import`, so `instantiate/0` vs `instantiate/1`
   never desyncs, R3); the 3 ordered fail-closed guards for import-routed slots (including after
   `table.copy` shuffles them); and `OptNone ≡ Baseline ≡ Aggressive` **result-identical** across the full
   matrix (R5).
4. **Tighten the audits so a tail-of-this-category regression cannot hide (R7)** — **lower**
   `skipcount_test.max_residual_skips`, **add** a measured Phase-14 pass floor, and **remove** the
   `residual_audit` `allowed_phrases` (`"UnknownFunction"` / `"call_indirect_table"`) that categorized
   this residual, so a re-skip of these asserts turns the suite **red (uncategorised)** instead of hiding.
5. **Re-measure + document** — regenerate `docs/wasm-conformance.svg`, write `docs/phase-14-surface.md`,
   update the `docs/phase-6-surface.md:76` residual accounting and the `vendor/ALLOWLIST:182–185` comment,
   update [`../01-status.md`](../01-status.md), and **report the running gleeunit total**.

This unit writes **no Gleam source in `src/`** and **no test that locks in emitted Core text** (R6). Its
only source-shaped artifacts are the `corpus/xlink.{wat,wasm,expected}` fixture, the `combos.gleam`
wiring, and authored gleeunit proofs in a fresh capstone test file.

---

## §2. Depends on / Produces

**Depends on (frozen upstream — must all be landed + green before this unit claims):**
- R14-01 `«REFFUNC-IMPORT-FROZEN»`: `ir.RefFuncImport(slot: Int, ty: FuncType)` (a pure barrier, mirror of
  `CallImport`), the `lower.gleam:757–759` import-split (`f < ctx.imported` → `RefFuncImport`), the `.ir`
  printer/parser round-trip, all exhaustiveness arms.
- R14-02: the real imported-funcref emission in `src/twocore/backend/emit_core.gleam`
  (`emit_ref_func_import`, `imported_reference_func_entry` Cell+Threaded, the `render_ref_item:4031–4043`
  arm, the `render_ref_global_init:5282` completion, `all_reffunc`/`byte_ident_funcref:5732–5744` treating
  `RefFuncImport` as **not**-plain-`RefFunc`, the extended **public** `needs_func_imports:4715–4717`
  element-segment scan) **and** the LOCKSTEP delegation — `driver.module_calls_import:325–340` now **calls**
  `emit_core.needs_func_imports` (the private `expr_calls_import` mirror deleted) — plus R14-02's
  e2e/dispatch + arity + D3a codegen-security tests.
- R14-03: `test/twocore/runtime/rt_table_reftype_differential_test.gleam` (+ siblings) — an import-routed
  funcref slot stores + dispatches identically across `TablePaged`/`TableEts`/`TableAtomics` × Cell/
  Threaded. Pure test-only: no `src/` file (the adapter seam is frozen to inline — R14-02 emits it inline).
- The toolchain pins (`vendor/PIN`): the `WebAssembly/testsuite` SHA + wabt (`wat2wasm`/`wast2json`).

**Produces:** the phase proof (§4 acceptance table, every row green + **measured**), the
`corpus/xlink.{wat,wasm,expected}` backstop, the `combos.gleam` wiring, the tightened audits, the
regenerated SVG, `docs/phase-14-surface.md`, the `docs/phase-6-surface.md:76` accounting update, and the
[`../01-status.md`](../01-status.md) compaction. After this unit lands, `phase-14/` is removed per
[`../03-phase-workflow.md`](../03-phase-workflow.md) §1.

---

## §3. What it owns + the exact edits (D1 — the single conformance-wiring / status owner)

Every file below is assigned to R14-04 by the [`00-overview.md`](00-overview.md) §4 ownership map. No
other unit touches these; **this unit touches no `src/` file and no upstream unit's file** (R14-01/02/03
own `ir.gleam`/`lower.gleam`/`emit_core.gleam`/`driver.gleam`/`rt_table*`; `link.gleam` is untouched by
Phase 14 — the adapter is emitted inline). The one
deliberate cross-file *reach* is the two comment-only edits in `vendor/ALLOWLIST` and
`docs/phase-6-surface.md` (accounting honesty), recorded in `state.md`.

### 3.1 Re-measure the `table_copy` flip — no vendor change, `conformance_test` already drives it

`table_copy.wast` is **already** in the driven allowlist (`vendor/ALLOWLIST:82`,
`table_copy … 1727 asserts`) and lands in the top-level `fixtures/` glob the main `conformance_test`
drives. **No `ALLOWLIST`/`vendor.sh` entry is added** — landing R14-01…03 makes the previously-skipped
cross-module funcref-in-`elem` asserts *build and dispatch*, so they flip skip→pass automatically. The
capstone's job is to **measure and assert** the flip, not to wire a new file:

- Run the full suite (`RUN_VENDOR=1 scripts/gen-conformance-svg.sh` re-vendors, or run `vendor.sh` then
  `gleam test -- twocore/conformance/conformance_test`). The main gate `assert total.fail == 0`
  (`conformance_test.gleam:308`) must hold across **every** shipped matrix point (`spec_suite_safe`,
  `spec_suite_unsafe`, and the five `spec_suite_matrix_*` combos, `conformance_test.gleam:152–207`).
- Confirm the fixture is the one the brief names: `table_copy.1.wasm` imports `a.ef0..ef4` (funcidx 0–4),
  fills 6 `elem` segments mixing **imported** (funcidx 1–4) + **defined** (funcidx 5–9) across tables 0/1,
  then dispatches `call_indirect (type 0)` / `call_indirect 1 (type 0)`; module 0 exports `ef0..ef4` and
  `(register "a")`. The harness cross-module plumbing is present and unchanged:
  `register` → `runner.provider_from_instance:153–163` → `link.Registered(name, exports)`, each export a
  `link.provided_func(sig, routing_closure)` (`runner.routing_closure:170–183`); `export_func_sigs`
  publishes the provider signatures (`driver.gleam:270–285`).
- **`table_copy` has 1206 `assert_trap` sub-asserts** (brief §Conformance): after `table.copy` shuffles
  the slots, the 3 ordered `call_indirect` guards must still fire on the *right* slots
  (`rt_table.gleam:203–223`: bounds → null → exact-type). This is the fail-closed row of §4 — it falls out
  of the unchanged slot ABI (`#(FuncType, closure)`, R2/R8) because an imported funcref is just another
  build-controlled closure in a slot; the capstone **measures** it (the trap asserts pass, `fail == 0`),
  it does not special-case it.
- **Record the reality (R16/S11).** The `1080` in `skipcount_test:20` is the *entering* residual; the
  capstone prints and asserts the *measured* post-flip figure — whatever it is. Some `table_copy`
  sub-asserts may remain categorized skips for orthogonal reasons (e.g. a `register`/harness edge); if so,
  they stay honestly categorized, never re-labelled as a pass (the honest "measured, not promised"
  accounting).

### 3.2 Tighten `skipcount_test.gleam` — lower the ceiling, add a pass floor, re-measure the doc

**`test/twocore/conformance/skipcount_test.gleam`.**

- **`max_residual_skips` (`:58`, currently `1900`) — LOWER it (R7).** Re-measure the total `skip` after
  the flip (it drops by ~1080 as the `table_copy` cross-module asserts pass) and set the ceiling to the
  new measured `skip` plus the existing small drift headroom. It must stay a **real ceiling**: a
  regression that re-skips the flipped asserts inflates `skip` above the lowered ceiling → the `(d)`
  assertion `total.skip <= max_residual_skips` (`:190`) goes red.
- **Add a measured Phase-14 pass floor — BUMP the pass gate (R7).** The two historical lower bounds
  `phase4_baseline_pass` (`:47`, `15_749`) and `phase5_baseline_pass` (`:51`, `21_525`) are far below the
  measured pass count, so neither catches a ~1080-assert regression. Add a **new tight** constant
  `const phase14_pass_floor: Int = <measured post-flip pass − small headroom>` and assert
  `total.pass >= phase14_pass_floor` inside the `full_suite_present` branch. Now a regression that
  re-skips the `table_copy` cross-module asserts drops `pass` below the floor → **red**. (Do **not** lower
  or inflate `phase4_baseline_pass`/`phase5_baseline_pass`; they are prior-phase history — the `>`
  assertions keep holding because pass only grows.)
- **The MEASURED-headline module-doc (`:15–33`).** Rewrite the "pass = 46529 … skip = 1768" narrative and
  the residual-composition bullet **#1** (`:20–24`) to record the flip: the `table_copy.wast`
  cross-module funcref-in-`elem` asserts are now **driven and passing** (Phase 14 landed the imported
  `ref.func` distinction — `RefFuncImport` + the D3a adapter closure), no longer a categorized deferral.
  Update the figure honestly (S11) — the new `pass` / `skip` after the flip, with `table_copy` counted as
  a **positive movement**, not a residual.
- **The printed residual-composition line (`:157–164`) + `is_imported_global_elem` (`:110–114`).** These
  print `n_imported_global` (the cross-module funcref-elem bucket, matched by `"UnknownFunction"`). After
  the flip that bucket collapses toward `0`; the test **prints** it (never asserts empty — it stays a
  MEASURED report, S11). Keep the print; update the accompanying comment from "categorised-deferred" to
  "closed by Phase 14 (measured)". The SIMD text-format residual (`is_simd_text`, `:209–220`) is untouched
  (S13, out of scope, orthogonal).

> **Consistency note.** `skipcount_test.allowed_phrases()` (`:67–99`) still lists `"UnknownFunction"` /
> `"call_indirect_table"` as *known emit gaps*. After the flip, re-run: if nothing in the suite still
> carries them, they may be pruned here too for symmetry with §3.3 — but the **binding** categorisation
> gate is `residual_audit`'s (§3.3). Keep `skipcount`'s list a superset unless the re-measure shows a phrase
> is dead; reconcile toward the tighter `residual_audit` set and record it (mirrors the Phase-13 capstone
> discipline).

### 3.3 Tighten `residual_audit_test.gleam` — remove the phrases that hid this category (R7)

**`test/twocore/conformance/residual_audit_test.gleam`** — `allowed_phrases()` (`:30–48`) currently opens
with the cross-module funcref-in-`elem` category (`:32–34`):

```gleam
    // cross-module funcref-in-elem-segment init (table_copy) — deeper than CallImport dispatch (S11)
    "UnknownFunction", "imported-global element-init", "NonConstInit",
    "NonConstantExpr", "call_indirect_table", "UnsupportedNode",
```

**Remove `"UnknownFunction"` and `"call_indirect_table"`** — the two phrases the overview R7 names as
covering *this* category (an imported `ref.func` fell out as `Error(UnknownFunction("f1"))`, brief §gap;
`call_indirect_table` was the multi-table label, already GONE per `skipcount:191–194`). **MEASURE THEN
REMOVE (F2), not remove-then-hope:** first run the suite and confirm that **no** residual skip still carries
`"UnknownFunction"` — imported `ref.func` is now driven (the `RefFuncImport` distinction + the D3a adapter
close *every* path that fell out this way, including the reference-global-init path R14-02 completes, 02
§3.1e). **Only then** remove the phrase. If any residual **still** carries `"UnknownFunction"`, do **not**
remove the phrase — categorise that residual honestly under its true cause (per the discipline below). After a
clean measure + removal, `residual_audit_is_measured_and_honest_test` stays green (`uncategorised == []`,
`:119`): imported `ref.func` is now driven (the `RefFuncImport` distinction + D3a adapter), so no residual
skip should carry `"UnknownFunction"` from the cross-module funcref-in-`elem` gap, and a `RefFuncImport`-shaped
regression that re-skips these asserts now turns the audit **red** instead of hiding. **Keep**
`"imported-global element-init"` / `"NonConstInit"` / `"NonConstantExpr"` (a genuinely different,
still-deferred gap — an element/data segment initialised from an *imported global*'s `global.get`, not a
`ref.func` of an imported *function*) and `"UnsupportedNode"` (kept unless the re-measure proves it dead —
then it may go too).

> **Discipline (R7, mirrors Phase-13 §3.3).** If removing the two phrases surfaces a *previously-hidden*
> residual (audit goes red), that is a real finding: **categorise it honestly** under its true cause (or
> fix the regression). Do **not** re-add the blanket phrases to paper over it. Genuine non-funcref
> residuals stay categorised under their own phrases; this removal is scoped to the cross-module
> funcref-in-`elem` category only.

### 3.4 The `xlink` backstop — `corpus/xlink.{wat,wasm,expected}` + `combos.gleam` wiring

**Why this backstop is cross-module by construction (the key design point).** An *imported* funcref
**requires a real provider** — a single self-contained corpus module cannot express it, and a single-module
corpus import is **fail-closed rejected** under the deny-all Safe host (`driver.func_imports_all_provided:298–309`,
the invariant that keeps `corpus/hostimport` a `reject`). So `xlink` cannot ride the plain single-module
`combos.evaluate` / `whole_corpus_tier_differential_test` path (which supplies no provider). It is a
**two-module** fixture driven through the *same* `(register)` → import plumbing `table_copy.wast` uses,
under each shipped `Combo`. This is exactly the feature under test, in miniature and in-scope (R6).

**New fixture** under `test/twocore/conformance/corpus/` (coexists with the Phase-6
`corpus/xlink.wast` — the *direct*-cross-module-call backstop; this is the distinct `.wat/.wasm/.expected`
*imported-funcref-through-`call_indirect`* backstop, same family stem, different concern):

`corpus/xlink.wat` — the authored multi-module source (human-readable spec fixture; the importer module is
compiled to `xlink.wasm` with `wat2wasm`, decoded by **our** decoder end-to-end):

```wat
;; Phase-14 acceptance — cross-module funcref-in-elem-segment init + call_indirect of an IMPORTED
;; function. Per the WASM spec (element segments; §4.5.4 / instantiation): funcidx space is unified —
;; imports occupy 0..n-1 — so `ref.func x` for an IMPORTED x yields that import's function reference;
;; an active elem writes it into the table at the offset. Per §exec/instructions (call_indirect), a
;; call through such a slot dispatches to the imported function and MUST behave identically to a direct
;; `call` of that import; the 3 fail-closed guards (bounds → null → exact type) evaluate in order.
;; Values spec-obvious (arithmetic); cross-checked with wasmtime (Tier-B) at authoring time.
(module $a                                   ;; the provider — exports funcref-able functions
  (func (export "ef0") (param i32) (result i32) (i32.add (local.get 0) (i32.const 10)))
  (func (export "ef1") (param i32) (result i32) (i32.mul (local.get 0) (i32.const 2))))
(register "a" $a)

(module $b                                   ;; the importer — the module compiled to xlink.wasm
  (type $unary (func (param i32) (result i32)))
  (import "a" "ef0" (func $ef0 (param i32) (result i32)))   ;; funcidx 0 (imported)
  (import "a" "ef1" (func $ef1 (param i32) (result i32)))   ;; funcidx 1 (imported)
  (func $defined (param i32) (result i32) (i32.sub (local.get 0) (i32.const 1)))  ;; funcidx 2 (defined)
  (table 3 funcref)                          ;; table 0
  (table 2 funcref)                          ;; table 1 (non-zero table dispatch)
  ;; MIXED active elem on table 0: imported ef0 @0, defined @1, imported ef1 @2 (slot ABI unchanged).
  (elem (table 0) (i32.const 0) func $ef0 $defined $ef1)
  ;; imported ef0 on table 1 @0 (leaves slot 1 null for the uninitialized-element guard).
  (elem (table 1) (i32.const 0) func $ef0)
  (declare func $ef0)                        ;; ensure the imported ref is declared (validate.gleam:1057)

  ;; via_ci(i,x): call_indirect table 0 slot i — reaches an IMPORTED funcref at i∈{0,2}.
  (func (export "via_ci") (param $i i32) (param $x i32) (result i32)
    (local.get $x) (local.get $i) (call_indirect 0 (type $unary)))
  ;; via_ci1(x): call_indirect table 1 slot 0 — imported funcref on a NON-ZERO table.
  (func (export "via_ci1") (param $x i32) (result i32)
    (local.get $x) (i32.const 0) (call_indirect 1 (type $unary)))
  ;; direct(x): the oracle — a DIRECT call of the same import ef0. Spec: via_ci(0,x) == direct(x).
  (func (export "direct") (param $x i32) (result i32) (call $ef0 (local.get $x)))

  ;; the 3 ordered fail-closed guards on import-routed slots (same traps + order as call_indirect):
  (func (export "ci_oob")  (param $x i32) (result i32)     ;; idx 9 ≥ size 3 → undefined element
    (local.get $x) (i32.const 9) (call_indirect 0 (type $unary)))
  (func (export "ci_null") (param $x i32) (result i32)     ;; table 1 slot 1 present-but-null → uninit
    (local.get $x) (i32.const 1) (call_indirect 1 (type $unary)))
  (func (export "ci_type") (param $x i32) (result i32)     ;; slot @0 is $unary; call as binary → mismatch
    (local.get $x) (local.get $x) (i32.const 0) (call_indirect 0 (type (func (param i32 i32) (result i32))))))
```

`corpus/xlink.expected` — the corpus value/trap oracle (same DSL as `callind.expected`/`reftab.expected`;
Tier-A baked values cross-checked with wasmtime):

```
# Phase-14 cross-module funcref-in-elem. Values spec-obvious; trap phrases per rt_trap.spec_trap_message.
# ef0(x)=x+10, ef1(x)=x*2, defined(x)=x-1. slot 0=ef0(import), 1=defined, 2=ef1(import) on table 0.
invoke via_ci  i32:0 i32:5   => return i32:15    # slot 0 = imported ef0 → 5+10
invoke via_ci  i32:2 i32:5   => return i32:10    # slot 2 = imported ef1 → 5*2
invoke via_ci  i32:1 i32:5   => return i32:4     # slot 1 = defined     → 5-1  (mixed segment)
invoke via_ci1 i32:7         => return i32:17    # imported ef0 on table 1 → 7+10
invoke direct  i32:5         => return i32:15    # DIRECT call of ef0 — MUST equal via_ci(0,5)
# The three ordered fail-closed guards on import-routed slots (spec order: bounds → null → type).
invoke ci_oob  i32:0         => trap undefined element
invoke ci_null i32:0         => trap uninitialized element
invoke ci_type i32:0         => trap indirect call type mismatch
```

**`test/twocore/tier/combos.gleam` — the wiring (R14-04 edits this P4-09 support module per the overview
§4 ownership map).** Because `xlink` needs a provider, it is **not** added to `corpus_programs:49–52`
(that list drives the single-module `whole_corpus_tier_differential_test` with no provider — enrolling
`xlink` there would `Rejected` it, exactly like `hostimport`). Instead add a **sibling** list + a
**linked-drive** helper that mirrors `evaluate` (`:201–243`) but registers a provider first — keeping the
cross-module drive machinery single-source (D7):

- **`pub const cross_module_programs: List(String) = ["xlink"]`** (with a `///` doc: cross-module funcref
  backstops that require a `(register)`ed provider, so they are driven by `evaluate_linked`, never the
  single-module `evaluate`).
- **`pub fn evaluate_linked(d: Driver, provider_name: String, provider_bytes: BitArray, importer: String)
  -> #(List(Outcome), List(String))`** — instantiate the provider (`d.instantiate(provider_bytes)`), build
  `runner.provider_from_instance(provider_name, inst_a)`, instantiate the importer **with** that provider
  (`d.instantiate_env(importer_bytes, ImportEnv([provider]))`, the provider-carrying seam
  `driver.pipeline_with:82–92` exposes as `instantiate_env`), then reduce every `.expected` point through
  the **existing** `run_point`/`raw_of`/oracle machinery (reuse it — do not re-spell). Returns the same
  `#(outcomes, failures)` shape `evaluate` returns, so `identity_across:327–350` compares combos unchanged.

The provider bytes for module `a` are supplied by the capstone test (§3.5) — `a` is tiny, so the test
compiles it from an inline WAT string (or a small pre-built byte literal); `xlink.wasm` is module `b`
alone. This keeps the fixture to the overview's three files (`corpus/xlink.{wat,wasm,expected}`).

### 3.5 The authored capstone tests — the differential, D3a, arity lockstep, opt-level identity

**New file `test/twocore/tier/xlink_capstone_test.gleam`** (a fresh file — one owner, no D1 conflict;
mirrors the Phase-13 `tailcall_capstone_test.gleam` dedicated-capstone pattern). It drives the `xlink`
backstop across the shipped matrix and houses the properties the plain single-module tier differential
cannot express. Each test carries a `///` contract doc citing the WASM spec clause it enforces and what
makes it go red. All comparisons are over the spec-observable `combos.Outcome` (raw value bits / trap
reason), **never** over `.core` text (R6 — not a change-detector).

1. **`imported_funcref_matches_direct_call_test`** — the load-bearing semantic identity. For each
   `combo in combos.shipped` (`:125–131`), drive `xlink` via `combos.evaluate_linked`; assert
   `via_ci(0, x) == direct(x)` and `via_ci(2, x) == ef1(x)` at several `x`. **Spec:** an imported function
   reached via `call_indirect` behaves **identically** to a direct `call` of that import (brief §spec;
   unified funcidx space). A wrong adapter closure (wrong slot, wrong `FuncType` renderer, an
   `erlang:apply` path) would diverge here.
2. **`imported_funcref_cross_combo_bit_identical_test`** — the cross-strategy / cross-tier differential
   (R6). Collect each combo's `Outcome` list from `evaluate_linked`, then `combos.identity_across("xlink",
   runs)` must be `[]`: **bit-identical values + identical traps** across Cell/Threaded × every table tier.
   **REQUIRED (F5): drive `xlink` end-to-end through `TableEts` too** — add the ETS `Combo` (e.g.
   `Combo("cell×ets", Cell, Paged, TableEts, Safe)`) so the authored fixture actually runs on
   `TablePaged`/`TableEts`/`TableAtomics`, matching the §4 "End-to-end dispatch" row's claim that *every*
   tier is proven e2e. This is one extra `Combo` — cheap. R14-03's hand-built slot-store/dispatch
   differential across the same tiers is the **substrate backstop** cited alongside, **not** a substitute for
   the e2e drive (do not swap the ETS `Combo` for a bare R14-03 citation). **Spec:** the state strategy and
   table tier are non-observable — a Threaded build threads `St` unchanged through the adapter (R2), so the
   imported funcref dispatches to the same value on every tier.
3. **`imported_funcref_opt_level_result_identical_test`** — the explicit `OptNone ≡ Baseline ≡ Aggressive`
   differential (R5). For each shipped `(state × mem × table)` combo, compile+drive `xlink` at all three
   `opt_level`s (vary **only** the `opt_level` field of the `Binding`, via `binding_for` +
   `Binding(..b, opt_level: …)`), reduce each to its `Outcome` list, and assert the three levels are
   **result-identical** at every point and every combo. `RefFuncImport` is a **pure barrier** in the
   optimizer (R1); an arm that wrongly reordered/CSE'd/DCE'd across it would diverge here.
4. **`imported_funcref_fail_closed_guards_test`** — the 3 ordered guards on import-routed slots. Drive
   `ci_oob` → `undefined element`, `ci_null` → `uninitialized element`, `ci_type` → `indirect call type
   mismatch`, under every combo. **Spec:** `call_indirect` checks bounds → slot-non-null → exact structural
   `FuncType`, **in that order** (`rt_table.gleam:203–223`); an import-routed slot uses the *same* guards
   (unchanged ABI, R8). This is the authored companion to `table_copy`'s 1206 post-`table.copy` trap
   asserts (§3.1).
5. **`ref_func_import_only_arity_lockstep_test`** — the sharpest edge (R3). Hand-build (or author a tiny
   fixture for) a module that **only** `ref.func`s an import into an `elem` segment and **never**
   `CallImport`s it in any body. Assert: it compiles to the **import-bearing** ABI — `emit_core`'s
   `needs_func_imports:4715–4717` (extended by R14-02 to scan element segments, now `pub`) seeds the
   func-import vector, and `driver.module_calls_import:325–340` (now **delegating to** that same
   `needs_func_imports`, R14-02) weaves the provider closures — so it instantiates as **`instantiate/1`**,
   links against a provider, and dispatches correctly. Because the driver calls the one shared predicate, a
   desync is structurally impossible; were the extended element scan to regress, both sides would drop the
   seed together and the module would silently lose its import — this test pins the seed *fires*. Re-runs R14-02's arity
   test green and **cites it**; adds the end-to-end drive as the capstone-level witness.
6. **`imported_funcref_slot_is_d3a_clean_test`** — the D3a proof. **Cite and re-run** R14-02's extension of
   `test/twocore/backend/emit_core_security_test.gleam` (the codegen-security test the overview §1
   requires be "extended to cover it"): the imported-funcref slot's closure captures **only** the literal
   integer slot; dispatch is `link.call_import(func_import_at(slot), args)` (`emit_call_import:3366–3401`
   reuse), never `erlang:apply(Mod,Fun,Args)` on table/program data. The capstone re-runs that suite green
   and cites it; it does **not** re-derive the Core-text assertion (owned by R14-02). If R14-02's security
   test does not already assert the imported-funcref arm, the capstone adds a focused positive/negative
   check (the emitted `.core` for `xlink.wasm` contains `func_import_at`/`call_import` for the slot and
   **no** `apply` on a program-derived module:atom).
7. **`running_total_report_test`** — **prints** (does not assert a magic number) the measured Gleam-test
   total and the measured conformance headline, so the capstone's stdout carries the running totals the
   surface doc + status quote. Asserts only the invariant shape (`fail == 0`), never a brittle count.

Compile+load via the same `driver.pipeline_with(combos.binding_for(combo))` → `instantiate_env` machinery
the conformance suite uses; give each loaded module a process-unique name (`driver.uniquify` /
`ir.Module(..m, name: …)`) so concurrent combos do not clobber a BEAM module name.

> **Run the WHOLE `test/twocore/tier/` suite** after the `combos.gleam` edit — any suite iterating
> `combos.corpus_programs` is unaffected (`xlink` is in the new `cross_module_programs`, not
> `corpus_programs`), but confirm every tier suite stays green.

### 3.6 Docs + SVG + status

- **`docs/wasm-conformance.svg`** — regenerate via `RUN_VENDOR=1 scripts/gen-conformance-svg.sh`. After
  the flip the header totals (`scripts/gen-conformance-svg.sh:192`, "N passing · M out of scope") move —
  `table_copy`'s cross-module asserts shift from skip→pass. The footnote (`gen-conformance-svg.sh:257`)
  does **not** name cross-module-funcref in its residual-out-of-scope list, so no removal is forced there;
  **verify** the regenerated header/bars reflect the new measured `pass`/`skip`, and add a short Phase-14
  note to the footnote if a phase line is warranted ("Phase 14: cross-module funcref-in-`elem` init —
  `ref.func` of an imported function through `call_indirect`, D3a-clean via the func-import adapter
  closure; `table_copy.wast` runs green"). Commit the new SVG.
- **`docs/phase-14-surface.md`** — new surface writeup (mirrors `docs/phase-{5,6,12}-surface.md`).
  Contents: what shipped (the `RefFuncImport(slot, ty)` distinction; the D3a Cell/Threaded adapter closure
  over `func_import_at`/`t_func_import_at` + `link.call_import`; the unchanged funcref slot ABI
  `#(FuncType, closure)`; the extended **public** `needs_func_imports` element-scan + the driver's LOCKSTEP delegation to it);
  the acceptance table (§4) with the **MEASURED** numbers filled in; the `table_copy.wast` flip (569 pass
  → all driven, the ~1080 cross-module residual **closed**, measured not promised, S11); the honest scope
  (R8 — imported *function* refs into `elem` only; no externref, no threaded cross-instance linking, no
  runtime shape change, no new trap reason); the note that a module with no imported `ref.func` compiles
  **byte-identically** to Phase 13, and modules that drive the new surface are **result-identical** across
  the full matrix. One line per proof → the test that proves it (§4). MEASURED, never promised.
- **`docs/phase-6-surface.md:76`** — the residual-table row (`table_copy.wast cross-module
  funcref-in-`elem`-segment init … ~1,088 … Categorized-deferred`). **Rewrite it** to mark the category
  **CLOSED by Phase 14**: `table_copy.wast` is now fully driven — its cross-module funcref-in-`elem`
  asserts pass — with a pointer to `docs/phase-14-surface.md`. Keep the number MEASURED and honest (the
  "569 pass / ~1,088 residual" framing becomes "fully driven, residual closed in Phase 14"). Leave the
  SIMD-text and post-2.0 rows untouched.
- **`test/twocore/conformance/vendor/ALLOWLIST:182–185`** — the deferral comment ("table_copy.wast … 569
  asserts PASS; ~1080 remain a CATEGORIZED residual …"). **Rewrite** it to state the residual is **closed
  in Phase 14** (imported `ref.func` through `call_indirect` now lands): `table_copy.wast` is fully driven.
  A comment-only reach (the fixture entry at `:82` is unchanged), recorded in `state.md`.
- **[`../01-status.md`](../01-status.md)** — the compaction:
  - §1 **Live metrics** (`:30`, `:32`): bump "Gleam tests" to the new measured `N pass / 0 fail`; bump
    "WASM spec conformance" (`:32`) to the new measured `pass / skip / 0` (the `table_copy` flip raises
    `pass` and lowers `skip` by the measured ~1080). Keep the "identical under Safe and Unsafe, every
    combo" clause.
  - §3 **condensed history** (`:65–76`): add a **Phase 14** row — "Cross-module funcref-in-`elem`-segment
    init: `ref.func` of an *imported* function (the `RefFuncImport` IR distinction) made a table-storable,
    `call_indirect`-able funcref that dispatches through the D3a import capability (`link.call_import` over
    the func-import adapter closure — never `erlang:apply` on table data), across both state strategies and
    all table tiers; flips the `table_copy.wast` cross-module residual to pass; non-imported-`ref.func`
    output byte-identical." with the "Proven at close" MEASURED totals.
  - §9 **residual** (`:286+`): drop `table_copy` cross-module funcref-in-`elem` from the out-of-scope /
    categorized-deferred list; note it is now driven.
  - Add `docs/phase-14-surface.md` to the docs line (§8/§9 doc list).

---

## §4. The acceptance table — how each row is proven (the capstone's contract)

The capstone **owns** the overview §1 acceptance table. Each row maps to a concrete, MEASURED proof:

| Row (overview §1) | Proven by | Gate |
|---|---|---|
| **The residual flips** | `table_copy.wast` driven by the main `conformance_test` (§3.1, no vendor change); `skipcount`/`residual_audit` re-measured + tightened (§3.2/§3.3) | the **binding** gate is `skip <= max_residual_skips` (lowered to the measured post-flip `skip`) **and** `pass >= phase14_pass_floor` (the measured post-flip `pass` minus a small headroom); `fail == 0` (`conformance_test.gleam:308`) is a **necessary-but-not-sufficient** co-condition — it was already true *before* Phase 14 (the cross-module asserts merely *skipped*), so it cannot by itself witness the flip. Measured `skip` drops ~1080; `residual_audit` `uncategorised == []` with `"UnknownFunction"`/`"call_indirect_table"` removed (measure-then-remove, §3.3) |
| **End-to-end dispatch** | `xlink_capstone_test.imported_funcref_matches_direct_call_test` + `_cross_combo_bit_identical_test` (§3.5) over `corpus/xlink` (§3.4) under Cell **and** Threaded × `TablePaged`/`TableEts`/`TableAtomics` | `via_ci(0,x) == direct(x)`; `identity_across("xlink", runs) == []` across every combo; `fail == 0` |
| **Fail-closed guards preserved** | `xlink_capstone_test.imported_funcref_fail_closed_guards_test` (§3.5) + `table_copy`'s 1206 post-`table.copy` `assert_trap`s (§3.1) | `undefined` → `uninitialized` → `type mismatch`, same order as `call_indirect`, on import-routed slots and after `table.copy` shuffles; `fail == 0` |
| **D3a clean** | R14-02's extended `emit_core_security_test.gleam` (imported-funcref adapter captures only the literal slot; dispatch via `link.call_import`, no `erlang:apply` on program data) — re-run + cited by `imported_funcref_slot_is_d3a_clean_test` (§3.5) | R14-02 security suite green (re-run); no `apply` on a program-derived `module:atom` in the `xlink.wasm` `.core` |
| **Arity in lockstep** | `xlink_capstone_test.ref_func_import_only_arity_lockstep_test` (§3.5) — a `ref.func`-of-import-only module (no `CallImport`) recognised as import-bearing by the single public `needs_func_imports` (element-scan) that `module_calls_import` **delegates to** | instantiates as `instantiate/1`, links against a provider, dispatches; one shared predicate → desync structurally impossible. R14-02's arity test re-run + cited |
| **Default unaffected** | full conformance for all non-`table_copy` files UNCHANGED (results); `imported_funcref_opt_level_result_identical_test` (§3.5); byte-identity for no-imported-`ref.func` modules confirmed by the unchanged corpus/conformance run (R5) | non-imported-`ref.func` modules byte-identical; `OptNone ≡ Baseline ≡ Aggressive` result-identical on `xlink`; the frozen `init_elem` fast path unchanged for pure-defined segments; `fail == 0` everywhere |

"Green" here always means **MEASURED** (a count printed and asserted), never "it compiled" (R16/S11/R6).

---

## §5. The work (ordered, buildable)

1. **Confirm the pipeline is frozen + green.** `gleam test` on `main` with R14-01…03 landed: 0 fail,
   `gleam build` zero warnings, `gleam format --check src test` clean. Re-run R14-02's emit e2e/dispatch +
   arity + `emit_core_security_test`, and R14-03's `rt_table_reftype_differential_test`, green — the
   capstone builds on their guarantees.
2. **Re-measure the flip.** `RUN_VENDOR=1 scripts/gen-conformance-svg.sh` (or `vendor.sh` then
   `gleam test -- twocore/conformance/conformance_test`). Confirm `table_copy.wast`'s cross-module
   funcref-in-`elem` asserts pass and `fail == 0` across `spec_suite_safe`/`_unsafe`/the five matrix
   combos. Record the new measured `pass` / `skip`.
3. **Corpus.** Author `corpus/xlink.wat` (§3.4), build `xlink.wasm` (module `$b`) with `wat2wasm`
   (`--enable-reference-types` if the pin requires it), write `xlink.expected`; cross-check every value
   with wasmtime. Add `cross_module_programs` + `evaluate_linked` to `combos.gleam` (§3.4).
4. **Authored proofs.** Write `test/twocore/tier/xlink_capstone_test.gleam` (§3.5). `gleam test --
   twocore/tier/xlink_capstone_test` green (semantic identity + cross-combo bit-identity + guard order +
   arity lockstep + opt-level identity + D3a citation + running-total report). Run the whole `tier/` suite.
5. **Audits.** Lower `skipcount_test:max_residual_skips` + add `phase14_pass_floor` + re-measure the doc
   (§3.2); remove `residual_audit_test:32–34` `"UnknownFunction"`/`"call_indirect_table"` (§3.3). Run both:
   `residual_audit` stays `uncategorised == []`; `skipcount` `fail == 0`, within the lowered ceiling, above
   the new pass floor.
6. **Docs + SVG + status.** Regenerate `docs/wasm-conformance.svg` (verify header totals; optional footnote
   note); write `docs/phase-14-surface.md`; update `docs/phase-6-surface.md:76`, `vendor/ALLOWLIST:182–185`,
   and `../01-status.md` (§3.6). Fill every MEASURED number.
7. **Final gate.** `gleam format` → `gleam format --check src test` clean → `gleam build` zero warnings →
   full `gleam test` → record the exact `N pass / 0 fail` total (entering ~1,978 + R14-01…03 + this unit's
   proofs; report the measured number). Update `state.md`; announce the phase proven; compact per
   [`../03-phase-workflow.md`](../03-phase-workflow.md) §1.

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. **Residual flip MEASURED + green.** `table_copy.wast` driven by the main `conformance_test` with
   `fail == 0` across Safe/Unsafe/every matrix combo; the measured `pass`/`skip` recorded (stdout + status
   + surface doc). No `ALLOWLIST` deferral comment still lists `table_copy`'s cross-module residual as open.
2. **Backstop green.** `corpus/xlink.{wat,wasm,expected}` authored; `xlink_capstone_test` drives it across
   Cell/Threaded × `TablePaged`/`TableEts`/`TableAtomics`, proving semantic identity (`via_ci == direct`),
   cross-combo **bit-identity** (`identity_across == []`), the 3 ordered fail-closed guards, and
   `OptNone ≡ Baseline ≡ Aggressive` result-identity. `combos.gleam` carries `cross_module_programs` +
   `evaluate_linked`, and the whole `tier/` suite stays green.
3. **Arity lockstep + D3a proven.** The `ref.func`-of-import-only module instantiates as `instantiate/1`
   and dispatches (no desync); R14-02's extended `emit_core_security_test` re-runs green and is cited (the
   imported-funcref slot is D3a-clean — `link.call_import`, never `erlang:apply` on program data).
4. **Audits honest + tight (R7).** `residual_audit` green with `"UnknownFunction"`/`"call_indirect_table"`
   removed (`uncategorised == []`); `skipcount` `fail == 0`, within the **lowered** `max_residual_skips`
   and above the **added** `phase14_pass_floor`, with the MEASURED-headline doc updated. No phrase re-added
   to paper over a surfaced residual.
5. **Docs current.** `docs/wasm-conformance.svg` regenerated (header totals reflect the flip);
   `docs/phase-14-surface.md` written (acceptance table with measured numbers, one-line-per-proof);
   `docs/phase-6-surface.md:76` + `vendor/ALLOWLIST:182–185` accounting updated to CLOSED; `../01-status.md`
   metrics, history row, residual, and doc list updated.
6. **Clean build.** `gleam format --check src test` clean; `gleam build` **zero warnings**; the full
   `gleam test` suite green with the **exact running total recorded** (entering ~1,978 + R14-01…03 + this
   unit's proofs; report the measured `N pass / 0 fail`).
7. **`///` doc comments on every new public/test function** authored here (`combos.cross_module_programs`,
   `combos.evaluate_linked`, and each `xlink_capstone_test` function): what it proves, which WASM spec
   clause it enforces, and what makes it go red. No undocumented public/test surface (§Definition of Done
   #2).

---

## §7. What it leaves

- **Nothing downstream in-phase.** R14-04 is the terminal unit; after it lands, `phase-14/` is removed and
  its decisions live in the code + tests + [`../01-status.md`](../01-status.md).
- **Categorized-deferred (unchanged, honest — kept MEASURED in the audits/docs, not closed here, R8):**
  externref construction and cross-module *externref*-in-`elem`; cross-module **table** imports beyond what
  Phase 6 landed; **threaded cross-instance** linking (an invasive `threaded` cross-instance reach — a
  *named* category, `cell` remains the proven target, [`../02-roadmap.md`](../02-roadmap.md) §C); the
  *imported-global* element-init gap (a different residual — an element/data segment initialised from an
  imported global's `global.get`, still `residual_audit`-categorised under `"imported-global
  element-init"` / `"NonConstInit"` / `"NonConstantExpr"`). These stay categorized-deferred; the
  residual/skipcount audits keep them MEASURED and named.
- **No new trap, no optimizer/tier/state-strategy change, no runtime shape change (R8).** An imported
  funcref reached via `call_indirect` traps for exactly the reasons any funcref does (bounds → null →
  type, unchanged order); the funcref value stays `#(FuncType, closure)`; the frozen `init_elem` fast path
  for pure-defined table-0 segments is untouched — which is the byte-identical-by-default point R5 proves.
