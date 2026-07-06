# Q13-06 — The capstone: Phase 13 proven (tail-call, end-to-end)

> **Status:** scoped, awaiting build. **Owner:** Q13-06 (the capstone — Wave B, goes last and alone).
> **Depends on:** the whole DAG behind `«TC-FROZEN»` — Q13-01 (keystone: the three IR nodes + AST instrs
> + `.ir` round-trip + every exhaustiveness arm; the `rt_table` lookup seam + funcref-ABI change are
> **Q13-05's**, not the keystone's — overview §2 ⚠ ABI reconciliation note), Q13-02 (decode + WAT
> ingest of `0x12`/`0x13`), Q13-03 (the real validation typing rule), Q13-04 (the real bottom-transfer
> lowering), Q13-05 (the whole tail codegen: the funcref-ABI change + the `rt_table.call_indirect_lookup`
> seam + the real constant-stack `emit_core` tail emission). **Read order:**
> [`00-overview.md`](00-overview.md) → this doc.
>
> **A capstone CONFIRMS green; it does not re-derive prior units.** Q13-01…05 each shipped their own
> spec-cited suite (validation `assert_invalid`, lower AST→IR, emit tail-position + constant-stack for
> direct/indirect; imported value-correct/bounded-frame). This unit ties the pipeline end-to-end, drives
> the **official** suite + the **EH unblock** + a **constant-stack corpus witness** + the **differential
> matrix**, re-measures the conformance headline, regenerates the SVG, writes the surface doc, and
> compacts the phase into [`../01-status.md`](../01-status.md). Where a prior unit already proves a
> property (e.g. Q13-05's imported-tail-call **value-correctness** emit test), the capstone **re-runs it
> green and cites it** — it does not restate the proof.
>
> **Honors Q6** (byte-identical by default for non-funcref modules; funcref/`elem`-bearing modules
> **result-identical**), **Q7** (correctness = the official suite + a constant-stack property, not golden
> change-detectors), **Q8** (honest scope). It is the single unit that **owns the
> conformance-wiring / registration / status surface** (D1) and the sole point that **proves the §1
> acceptance table**.
>
> All prior-phase decisions and the permanent invariants
> ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold. Entering baseline (from
> [`../01-status.md`](../01-status.md), Phase-12 close): **1,978 Gleam tests / 0 fail**, `gleam build`
> zero warnings, `gleam format --check` clean, WASM conformance **46,529 / 1,768 / 0** (Safe ≡ Unsafe,
> every `state_strategy × mem_tier`). This unit re-confirms the exact running totals on landing.

---

## §1. Goal

Turn "the pipeline can do tail calls" into "**the phase is proven**". Concretely:

1. **Un-defer the two official tail-call `.wast` files** (`return_call.wast`, `return_call_indirect.wast`)
   — vendor them into the driven fixtures so the main conformance run drives them and asserts `fail == 0`.
2. **Unblock the two EH files that were blocked purely on `return_call`** (`legacy/try_catch.wast`,
   `legacy/try_delegate.wast`) — move them from `eh_unconvertible` into the driven `eh_files`, vendored
   with `--enable-exceptions`, so `eh_conformance_test` converts and runs them green.
3. **Author a constant-stack corpus witness** (`corpus/tailrec.{wat,wasm,expected}`) — a `return_call`
   self-loop to 1,000,000, mutually-recursive even/odd, and a `return_call_indirect` self-loop through a
   table slot (plus the three ordered indirect fail-closed traps) — enrolled into the tier differential
   and driven to constant space the way `sum_to(100000)` is. This proves the **direct + indirect
   (same-module)** constant-stack property; a `return_call` to an **imported** function is value-correct
   with a bounded caller frame, not a cross-module constant-stack claim (Q8; imported is cited to Q13-05,
   §3.5). Because `tailrec` uses a `funcref` table + `elem`, it is a **result-identical** (not
   byte-identical) module under the funcref-ABI change — the corpus differential proves its values/traps.
4. **Prove the §1 acceptance table** end-to-end: official suite green, constant stack (direct + indirect),
   EH unblock, typing rule, indirect fail-closed order, `OptNone ≡ Baseline ≡ Aggressive` bit-identical
   across the full `(mode × state_strategy × mem_tier)` matrix; default output byte-identical for
   non-funcref modules, result-identical for funcref/`elem`-bearing modules.
5. **Tighten the audits** so a tail-call regression cannot hide, **re-measure** the conformance /
   skip / test totals, **regenerate** `docs/wasm-conformance.svg`, **write** `docs/phase-13-surface.md`,
   and **update** [`../01-status.md`](../01-status.md).

This unit writes **no Gleam source in `src/`** and **no test that locks in emitted Core text** (Q7). Its
only source-shaped artifacts are test fixtures (`.wat`/`.wasm`/`.expected`) and authored gleeunit proofs.

---

## §2. Depends on / Produces

**Depends on (frozen upstream — must all be landed + green before this unit claims):**
- Q13-01 `«TC-FROZEN»`: `ir.ReturnCall`/`ReturnCallIndirect`/`ReturnCallImport`, the two AST
  constructors, the `.ir` printer/parser round-trip, all exhaustiveness arms. (The
  `rt_table.call_indirect_lookup*` seam + funcref-ABI change are **Q13-05's**, not part of the freeze —
  overview §2 ⚠ ABI reconciliation note.)
- Q13-02: `decode.gleam`/`wat.gleam` accept `0x12`/`0x13` and `return_call`/`return_call_indirect` text.
- Q13-03: the real result-type-equality validation rule (`assert_invalid` rejects a mismatch).
- Q13-04: the real bottom-transfer lowering (import split → `ReturnCallImport`/`ReturnCall`; indirect →
  `ReturnCallIndirect`).
- Q13-05: the whole tail codegen — the funcref-construction ABI change (package-ABI tail-transparent),
  the `rt_table.call_indirect_lookup*` seam + the non-tail `call_indirect*` package→list re-wrap, and the
  real constant-stack `emit_core` tail emission (direct reuses the KReturn tail path; indirect emits the
  lookup seam + tail-apply the package-ABI target in the ok-arm; imported reuses the existing import path
  under KReturn — value-correct/bounded-frame, no `link` change) + its emit tail-position + package-shape
  + constant-stack tests (direct/indirect; imported value-correct).
- The toolchain pins (`vendor/PIN`): testsuite SHA, wabt (`wat2wasm`/`wast2json`/`spectest-interp`).

**Produces:** the phase proof (§4 acceptance table, all rows green + measured), the re-vendored fixtures,
the regenerated SVG, `docs/phase-13-surface.md`, and the [`../01-status.md`](../01-status.md) compaction.
After this unit lands, `phase-13/` is removed per [`../03-phase-workflow.md`](../03-phase-workflow.md) §1.

---

## §3. What it owns + the exact edits (D1 — the single conformance-wiring / status owner)

Every file below is assigned to Q13-06 by the [`00-overview.md`](00-overview.md) §4 ownership map. No
other unit touches these; this unit touches no `src/` file and no upstream unit's file.

### 3.1 Un-defer the two tail-call `.wast` — `vendor/ALLOWLIST` + `vendor/vendor.sh`

**`test/twocore/conformance/vendor/ALLOWLIST`** — the deferred comment at **lines 186–188** currently
lists the tail-call files as post-2.0 categorized-deferred:

```
#   * Post-2.0 proposals — categorized-deferred (S12): return_call.wast / return_call_indirect.wast
#     (tail-call), GC (typed refs / struct/array/i31), exception-handling, stack-switching, the
#     component model, relaxed-SIMD. The Phase-6 close is "the complete WebAssembly 2.0 surface".
```

Edits:
- **Add two active allowlist entries** (uncommented lines, in the driven allowlist body — the same
  column format the loop reads, `vendor.sh:57–89`):
  ```
  return_call
  return_call_indirect
  ```
  The allowlist supports a **trailing flag column** (`vendor.sh:49–52,62,72`): if `wast2json` at the
  pin cannot parse tail-call text without a feature flag, append `--enable-tail-call` in that column
  (`return_call<TAB>--enable-tail-call`). **Verify at vendor time** — run `vendor.sh` and check
  `fixtures/return_call.json.convert.log` if conversion fails; wabt 1.0.41 enables tail-call by default,
  so the bare entry is the expected first attempt and the flag is the fallback.
- **Rewrite the 186–188 comment** so tail-call is no longer listed as deferred: it is now DRIVEN. Leave
  GC (typed refs / struct/array/i31), stack-switching, the component model, and relaxed-SIMD as the
  remaining post-2.0 categorized-deferred proposals. Keep the comment honest and MEASURED (D9/S12).

**`test/twocore/conformance/vendor/vendor.sh`** — the main allowlist loop (`:57–89`) converts every
allowlist entry into `fixtures/<name>.json`, so the two new entries are picked up automatically and
land in the top-level `fixtures/` glob the main `conformance_test` drives. **No new code path is needed
for the tail-call files here** — only the ALLOWLIST entries. (The EH additions in §3.2 DO edit
`vendor.sh` because they use the separate `vendor_eh` subdirectory path.)

### 3.2 EH unblock — move `try_catch`/`try_delegate` into the driven set

**`test/twocore/conformance/vendor/vendor.sh`** — the EH section (`:105–131`) explicitly vendors each EH
file with `--enable-exceptions` into `fixtures/eh/`. After the existing four `vendor_eh` calls
(`:128–131`) add two, using the wabt legacy flat-name convention (`legacy/throw.wast → legacy_throw`):

```
vendor_eh "legacy/try_catch.wast"    "legacy_try_catch"
vendor_eh "legacy/try_delegate.wast" "legacy_try_delegate"
```

Also update the EH-section comment (`:105–113`) from "4 of the 8 … the other 4 (`tag`, `try_table`,
legacy `try_catch`, legacy `try_delegate`) are blocked by … the tail-call proposal" to "**6 of the 8** …
the other 2 (`tag` — GC recursive types; `try_table` — typed refs / GC) …". MEASURED, not promised.

**`test/twocore/conformance/eh_conformance_test.gleam`** — the driven-set owner:
- **`eh_files` (`:84–86`):** add the two flat names so the run drives them:
  ```gleam
  const eh_files: List(String) = [
    "throw.json", "throw_ref.json", "legacy_throw.json", "legacy_rethrow.json",
    "legacy_try_catch.json", "legacy_try_delegate.json",
  ]
  ```
- **`eh_unconvertible` (`:92–100`):** **remove** the `legacy/try_catch.wast` and `legacy/try_delegate.wast`
  rows (they now convert). **Keep** `tag.wast` (GC `(rec …)`) and re-word the `try_table.wast` reason to
  drop `return_call` — `try_table` stays deferred on **typed refs / GC** alone (tail-call is no longer
  its blocker; Phase 13 is necessary-but-not-sufficient for it, per overview §0):
  ```gleam
  const eh_unconvertible: List(#(String, String)) = [
    #("tag.wast", "GC recursive type groups `(rec …)` — Phase-8 GC"),
    #("try_table.wast", "typed-ref `(ref null $t)` / `exn` heap type — GC/typed-refs (NOT tail-call)"),
  ]
  ```
- **Module-doc (`:8–29`):** update the "What actually converts at the pin" table (the `❌` rows for
  `try_catch`/`try_delegate` become `✅`; `try_table`'s reason loses `return_call`) and the "**4 of the
  8**" / "**The 4 convertible**" prose to "**6 of the 8**" / "**The 6 convertible**". This file is a
  MEASURED-honesty document (R16/S11); its narrative must match the new driven set.

The test body (`eh_wast_suite_spec_correct_test`) is unchanged in shape — `assert total.fail == 0` and
`assert total.pass > 0` now cover six files under all three profiles (`safe`/`unsafe`/`portable`).
**Re-measure** the aggregate EH assert count and record it (§3.6, the SVG footnote + status cite "153
asserts"; that number grows).

### 3.3 The audits — tighten `residual_audit`, re-measure `skipcount`

**`test/twocore/conformance/residual_audit_test.gleam`** — `allowed_phrases()` **line 43** currently reads:

```gleam
    "unhandled command: assert_exhaustion", "call stack", "return_call", "tag",
```

**Remove `"call stack"` and `"return_call"`** (keep `"unhandled command: assert_exhaustion"` and
`"tag"`). Rationale (the whole point per the brief): tail-call is now DRIVEN, so no residual skip should
carry a `return_call` reason, and the tail-call-adjacent "call stack" stack-model phrase should no longer
categorize anything — removing them means a return_call-shaped regression goes **red (uncategorised)**
instead of hiding. This is a MEASURED tightening: after removal, `residual_audit_is_measured_and_honest_test`
**must stay green** (`uncategorised == []`). If it does not, that surfaces a previously-hidden residual —
categorize it honestly (or fix the regression); do **not** re-add the blanket phrases to paper over it.
Genuine non-tail `assert_exhaustion` residuals remain categorized under
`"unhandled command: assert_exhaustion"`.

> **Note (skipcount consistency):** `skipcount_test.gleam` also carries `"call stack"` in its
> `allowed_phrases()` (`:86`). The brief scopes phrase-removal to `residual_audit_test:43` and scopes
> `skipcount_test` to the constant re-measure below. Keep `skipcount`'s phrase list as-is unless the
> re-measure shows a legitimately-categorized `"call stack"` skip has vanished; if the two audits
> disagree after the change, reconcile toward the tighter `residual_audit` set and record it.

**`test/twocore/conformance/skipcount_test.gleam`** — re-measure the pass/skip flip caused by vendoring
the two tail-call files (they add passing asserts; a handful of cross-module/`register`/`assert_exhaustion`
sub-asserts may skip, already-categorized). Steps:
- Run the **full** suite (`RUN_VENDOR=1 scripts/gen-conformance-svg.sh` re-vendors, or run `vendor.sh`
  then `gleam test -- twocore/conformance/skipcount_test`). Record the new `pass` / `skip` / `fail`.
- **`max_residual_skips` (`:58`, currently `1900`):** bump **only if** the measured `skip` exceeds it.
  Set it to the new measured value plus the existing small drift headroom; keep it a real ceiling
  (a further inflation must still go red).
- **`phase4_baseline_pass` (`:47`, `15_749`) and `phase5_baseline_pass` (`:51`, `21_525`):** these are
  **historical lower bounds** (`assert total.pass > phaseN_baseline_pass`). Pass only grows, so the `>`
  assertions keep holding — **do not lower or inflate them** unless the planner directs; they are prior-
  phase history, not a live target.
- **Module-doc MEASURED headline (`:15–33`):** update the "pass = 46529 … skip = 1768" narrative to the
  new measured figures, and note the two tail-call files as a NAMED positive movement (the honest
  accounting, S11) rather than a residual.

### 3.4 The corpus tail-recursion program — `corpus/tailrec.{wat,wasm,expected}` + `combos.gleam`

**New fixtures** under `test/twocore/conformance/corpus/`:

`corpus/tailrec.wat` (the spec fixture — build `tailrec.wasm` from it with `wat2wasm`, `--enable-tail-call`
if the pin requires it; the corpus `.wasm` is decoded by **our** Q13-02 decoder end-to-end):

```wat
;; Phase-13 acceptance — constant-stack tail calls (return_call / return_call_indirect).
;; Per the WASM tail-call proposal, return_call{,_indirect} are stack-polymorphic like `return`
;; and require the callee's result type to equal the current function's result type; on the BEAM
;; they lower to genuine tail calls, so deep self/mutual recursion runs in CONSTANT stack space.
;; Values cross-checked with wasmtime (Tier-B) at authoring time — NOT change-detectors.
(module
  (type $unary  (func (param i32) (result i32)))
  (type $binary (func (param i32 i32) (result i32)))
  (table 2 funcref)                 ;; slot 0 = $ind_step (filled by elem); slot 1 = null
  (elem (i32.const 0) $ind_step)

  ;; --- direct self-loop: count_down(n) tail-calls itself until 0 ---
  (func $count_down (export "count_down") (param $n i32) (result i32)
    (if (result i32) (i32.eqz (local.get $n))
      (then (i32.const 0))
      (else (return_call $count_down (i32.sub (local.get $n) (i32.const 1))))))

  ;; --- mutual recursion: is_even / is_odd via return_call ---
  (func $is_even (export "is_even") (param $n i32) (result i32)
    (if (result i32) (i32.eqz (local.get $n))
      (then (i32.const 1))
      (else (return_call $is_odd (i32.sub (local.get $n) (i32.const 1))))))
  (func $is_odd (export "is_odd") (param $n i32) (result i32)
    (if (result i32) (i32.eqz (local.get $n))
      (then (i32.const 0))
      (else (return_call $is_even (i32.sub (local.get $n) (i32.const 1))))))

  ;; --- indirect self-loop through table slot 0 ---
  (func $ind_step (param $n i32) (result i32)
    (if (result i32) (i32.eqz (local.get $n))
      (then (i32.const 0))
      (else (return_call_indirect (type $unary)
              (i32.sub (local.get $n) (i32.const 1)) (i32.const 0)))))
  (func (export "ind_count_down") (param $n i32) (result i32)
    (return_call_indirect (type $unary) (local.get $n) (i32.const 0)))

  ;; --- the three ordered indirect fail-closed guards (same traps + order as call_indirect) ---
  (func (export "ind_oob")  (param $n i32) (result i32)          ;; idx 5 >= size 2 → undefined element
    (return_call_indirect (type $unary) (local.get $n) (i32.const 5)))
  (func (export "ind_null") (param $n i32) (result i32)          ;; slot 1 present-but-null → uninit
    (return_call_indirect (type $unary) (local.get $n) (i32.const 1)))
  (func (export "ind_type") (param $a i32) (param $b i32) (result i32)  ;; slot 0 is $unary, called $binary
    (return_call_indirect (type $binary) (local.get $a) (local.get $b) (i32.const 0))))
```

`corpus/tailrec.expected` (Tier-A baked values — **modest** inputs for the value oracle so the differential
stays fast; the 1,000,000-deep space proof lives in the dedicated test, §3.5, exactly as `sum_to.expected`
uses 10/100 while the space test uses 100000):

```
# Phase-13 tail-call acceptance. Values cross-checked with wasmtime (Tier-B).
# Direct + mutual recursion (spec: tail-call proposal — result types equal; stack-polymorphic).
invoke count_down i32:0    => return i32:0
invoke count_down i32:1000 => return i32:0
invoke is_even i32:1000    => return i32:1
invoke is_even i32:1001    => return i32:0
invoke is_odd  i32:1001    => return i32:1
invoke is_odd  i32:1000    => return i32:0
# Indirect tail-call self-loop.
invoke ind_count_down i32:1000 => return i32:0
# Indirect fail-closed, three ordered guards (spec exec/instructions: bounds → null → type).
invoke ind_oob  i32:0      => trap undefined element
invoke ind_null i32:0      => trap uninitialized element
invoke ind_type i32:0 i32:0 => trap indirect call type mismatch
```

**`test/twocore/tier/combos.gleam`** — enroll the program into the shared corpus list. **Line 49**,
`corpus_programs`, append `"tailrec"`:

```gleam
pub const corpus_programs: List(String) = [
  "add", "intops", "sum_to", "fib", "fac", "floatops", "hostimport", "mem",
  "callind", "gvar", "memgrow", "trunc", "trapstart", "oobdata", "tailrec",
]
```

Update the `corpus_programs` doc-comment (`:43–48`) to note `tailrec` as the tail-call program (carries a
spec `.expected`; it uses a `funcref` table + `elem`, so under the funcref-ABI change it is a
**result-identical** module — its indirect tail call threads `cur` under `threaded`, so it is **not**
byte-identical across `cell`/`threaded`; the differential asserts identical **values + traps**, not
identical Core bytes, unlike a pure `sum_to`). Enrolling it makes
`tier_differential_test.whole_corpus_tier_differential_test` (`:63`) drive it under **every shipped
`Combo`** (`combos.shipped :125–131` = `cell_paged`, `threaded_paged`, `cell_atomics`, `threaded_atomics`,
`cell_nif`[Unsafe]) — proving, for free: (a) spec-correctness against `.expected` and (b) **cross-combo
result-identity** (values + traps) across `state_strategy × mem_tier × table_tier` (and Baseline vs
Aggressive via the Unsafe `cell_nif` point). The indirect self-loop + the three traps exercise the
`call_indirect_lookup` `_at`/`t_` twins across `TablePaged`/`TableAtomics` and `cell`/`threaded` — the
cross-tier proof of the
new seam.

> **Run the WHOLE `test/twocore/tier/` suite** after this edit — any other suite iterating
> `combos.corpus_programs` now includes `tailrec`; confirm all stay green.

### 3.5 The authored capstone tests — constant stack + `OptNone ≡ Baseline ≡ Aggressive`

**New file `test/twocore/tier/tailcall_capstone_test.gleam`** (a fresh file — one owner, no D1 conflict;
mirrors the dedicated-capstone pattern of `constant_space_threaded_test.gleam` and
`optimize/phase10_capstone_test.gleam`). It houses the two properties the tier differential cannot express
(memory-space, and independent opt-level variation), plus the running-total report. Compile+load via the
same `pipeline.source_to_ir` → `ir_to_core` → `build_beam.compile_and_load` + `ffi.start_instance` /
`ffi.call_instance` / `ffi.gc_and_memory` machinery `constant_space_threaded_test.gleam` uses; give each
loaded module a process-unique name (`ir.Module(..m, name: … <> unique_int())`).

Test functions (each with a `///` contract doc citing the tail-call proposal):

1. **`count_down_constant_space_test`** — direct `return_call` self-loop. Drive `count_down(1000)` and
   `count_down(1_000_000)` on the same instance-class; both return `0`; assert
   `mem_big < mem_small * 4` (a growing call stack — a non-tail wrapped emission — would exhaust the
   process or blow the live-memory bound ~1000×). This is the honest "is it really a tail call" proof
   (Q7). Spec: tail-call proposal — `return_call` is a genuine tail transfer.
2. **`even_odd_constant_space_test`** — mutual recursion. Drive `is_even(1_000_001) == 0` and
   `is_odd(1_000_001) == 1` (odd) and `is_even(1_000_000) == 1` (even); assert constant space across the
   100×-plus input spread. Mutually-recursive tail calls must also be constant-stack.
3. **`indirect_constant_space_test`** — `return_call_indirect` self-loop through table slot 0. Drive
   `ind_count_down(1_000_000) == 0` under **both** `TablePaged` (`portable`) and `TableAtomics`
   (`threaded_atomics`, small cap) bindings; assert constant space under each — proving the Q1 lookup
   seam tail-applies the target (constant stack) across table tiers, not merely returns a value.
4. **`tailrec_opt_level_bit_identical_test`** — the explicit `OptNone ≡ Baseline ≡ Aggressive`
   differential (Q6/Q7). For each shipped `(state × mem × table)` combo, compile `tailrec` at all three
   `opt_level`s (`OptNone`/`Baseline`/`Aggressive`) — varying **only** the `opt_level` field of the
   `Binding` — run every `.expected` point on real BEAM, reduce to the raw `Outcome`, and assert the
   three levels are **bit-identical** (values via raw bits, traps via reason) at every point and every
   combo. A tail-call node that an optimizer arm wrongly reordered / CSE'd / DCE'd across (it must be an
   effectful bottom-transfer barrier, Q2) would diverge here. Reuse the `combos.evaluate` /
   `combos.Outcome` reduction (already available) rather than re-spelling it.
5. **`tailrec_default_byte_identical_test`** (Q6 confirmation) — a module with **no funcref/`elem` and no**
   `return_call*` still compiles **byte-identically** to its Phase-12 form. Assert the existing non-funcref
   corpus programs (`add`/`sum_to`/`fib`) reduce to the SAME `Outcome`s they did pre-Phase-13; and assert
   the **funcref** corpus program `callind` reduces to the same `Outcome`s too — it is **result-identical**
   (values + traps unchanged) though its emitted Core changed under the funcref-ABI change (the `callind`
   differential is the sanctioned result-identity witness, overview §2 ⚠ ABI reconciliation note). This is
   the "default unaffected" acceptance row, restated locally. (The heavy lifting is the unchanged full
   conformance count in §3.6 — this is the fast local guard.)
6. **`running_total_report_test`** — prints (does not assert a magic number) the measured Gleam-test
   total and the measured conformance headline, so the capstone's stdout carries the running totals the
   surface doc + status quote. It asserts only the invariants (`fail == 0` shape), never a brittle count.

**Imported tail calls (`ReturnCallImport`) — VALUE-CORRECT, CONFIRMED, not re-derived.** A `return_call
$import` self-loop needs a host provider that re-enters the module, which the import-free differential
corpus cannot express. Q13-05 owns the imported emit test — it routes through the **existing** import
path under `KReturn` (no `link` change), which is **value-correct with a bounded caller frame**, **not** a
cross-module constant-stack claim (Q8 honest-scope sub-case, overview §2 ⚠ ABI reconciliation note). The
capstone **re-runs Q13-05's suite green and cites it** as the imported-tail-call **value-correctness**
proof; it does **not** restate it, and it makes **no** 1,000,000-deep constant-stack claim for imports.
Record this citation in `phase-13-surface.md` (§3.6) so the acceptance table's "imported" cell points at
the owning unit and is worded as value-correct / bounded-frame (not constant-stack).

### 3.6 Docs + SVG + status

- **`docs/wasm-conformance.svg`** — regenerate via `RUN_VENDOR=1 scripts/gen-conformance-svg.sh`. After
  vendoring, `return_call.json` + `return_call_indirect.json` are present, so they move from the "Not
  run (skipped)" grid to the "Run" bars automatically. **But the footnote is hardcoded** in the awk
  program (`scripts/gen-conformance-svg.sh` ~line 257): it lists tail-call under "Residual out of scope"
  and cites the EH "153 asserts" and "4 convertible" figures. **Edit that footnote string** before
  regenerating: remove `tail-call` from the residual-out-of-scope list, add a short Phase-13 note
  ("Phase 13: WebAssembly tail calls — `return_call`/`return_call_indirect` lowered to genuine BEAM tail
  calls in constant stack; the two official tail-call `.wast` run green; the two `return_call`-blocked EH
  files now convert"), and update the EH assert count to the new measured value. `scripts/gen-conformance-svg.sh`
  is the SVG pipeline this unit owns (overview §4 lists `docs/wasm-conformance.svg (regen)`); the
  footnote edit is the necessary reach to keep the regen honest. Regenerate and commit the new SVG.
- **`docs/phase-13-surface.md`** — new surface writeup (mirrors `docs/phase-{5,6}-surface.md`). Contents:
  what shipped (`return_call` `0x12` / `return_call_indirect` `0x13`, the tail-call typing rule, the
  constant-stack emission for direct + indirect, the funcref-ABI change → package-ABI tail-transparent
  closures + the `rt_table.call_indirect_lookup` seam (Q13-05), D3a-clean indirect dispatch — imports reuse
  the existing import path under `KReturn` with **no** `link` change); the acceptance table (§4) with the
  MEASURED numbers filled in; the EH unblock (4→6 driven files); the honest scope (Q8 — no
  GC/typed-refs/`try_table`/`tag`, no new trap, no optimizer/tier/state change; imported tail calls
  value-correct with bounded caller frames, not constant-stack); the note that funcref/`elem`-bearing
  modules are **result-identical** (not byte-identical, proven by the `callind` differential); and the
  imported-tail-call value-correctness citation to Q13-05. MEASURED, never promised.
- **[`../01-status.md`](../01-status.md)** — the compaction:
  - §1 **Live metrics** table: bump "Gleam tests" to the new measured `N pass / 0 fail`; bump "WASM spec
    conformance" to the new measured `pass / skip / 0` (the two tail-call files add passes). Keep the
    "identical under Safe and Unsafe, every combo" clause.
  - §3 **condensed history**: add a **Phase 13** row — "WebAssembly tail calls (`return_call` /
    `return_call_indirect`) lowered to genuine constant-stack BEAM tail calls (direct + indirect; imports
    value-correct with a bounded frame); D3a-clean indirect via the `rt_table` lookup seam over
    package-ABI funcref closures; unblocks the two `return_call`-blocked EH files; non-funcref output
    byte-identical, funcref/`elem` modules result-identical." with the "Proven at close" measured totals.
  - §9 **residual**: drop tail-call from the out-of-scope proposal list; note the two tail-call `.wast`
    are now driven.
  - Add `docs/phase-13-surface.md` to the docs line (§8/§9 doc list).

---

## §4. The acceptance table — how each row is proven (the capstone's contract)

The capstone **owns** the overview §1 acceptance table. Each row maps to a concrete, MEASURED proof:

| Row | Proven by | Gate |
|---|---|---|
| **Official suite** | `return_call.wast` + `return_call_indirect.wast` vendored (§3.1) and driven by the main `conformance_test` | `assert total.fail == 0` (`conformance_test.gleam:308`); measured pass reported |
| **Constant stack** | `tailcall_capstone_test` tests 1–3 (§3.5): 1,000,000-deep direct + mutual + indirect (same-module), `ffi.gc_and_memory` bounded; imported is **value-correct with a bounded frame** (cited to Q13-05), NOT a constant-stack claim | `mem_big < mem_small * 4` per direct/indirect case; a non-tail emission blows the bound; imported asserts value-correctness only |
| **Typing rule** | Q13-03's `assert_invalid` spec tests (result-type mismatch rejected; stack-polymorphism like `return`) — CONFIRMED green | Q13-03 suite green (re-run) |
| **Indirect fail-closed** | the three ordered traps in `tailrec.expected` (§3.4) driven across every combo + `return_call_indirect.wast` | `undefined` → `uninitialized` → `type mismatch`, same order as `call_indirect`; `fail == 0` |
| **EH unblock** | `legacy/try_catch` + `legacy/try_delegate` moved into `eh_files` (§3.2), vendored `--enable-exceptions`, converted | `eh_conformance_test`: `fail == 0 && pass > 0` over 6 files × 3 profiles |
| **Default unaffected** | full conformance for all non-tail files UNCHANGED (results); `tier_differential` + `tailrec_opt_level_bit_identical_test` + `tailrec_default_byte_identical_test` | non-funcref modules byte-identical; funcref/`elem` modules (e.g. `callind`) **result-identical** (values + traps unchanged); `OptNone ≡ Baseline ≡ Aggressive`; cross-combo results identical, `fail == 0` everywhere |

"Green" here always means **MEASURED** (a count printed and asserted), never "it compiled" (R16/S11/Q7).

---

## §5. The work (ordered, buildable)

1. **Confirm the pipeline is frozen + green.** `gleam test` on `main` with Q13-01…05 landed: 0 fail,
   `gleam build` zero warnings, `gleam format --check` clean. Re-run Q13-03/04/05 suites (the tail-call
   validation / lower / emit + constant-stack proofs) green — the capstone builds on their guarantees.
2. **Vendor.** Edit `ALLOWLIST` (§3.1) + `vendor.sh` EH section (§3.2). Run `vendor.sh` (or
   `RUN_VENDOR=1 scripts/gen-conformance-svg.sh`). Confirm `return_call.json`, `return_call_indirect.json`
   convert (+ `spectest-interp` self-consistent) and `fixtures/eh/legacy_try_catch.json`,
   `legacy_try_delegate.json` convert with `--enable-exceptions`. Inspect `.convert.log` on any skip;
   add `--enable-tail-call` if needed.
3. **EH driven set.** Edit `eh_conformance_test.gleam` `eh_files`/`eh_unconvertible` + module-doc (§3.2).
   `gleam test -- twocore/conformance/eh_conformance_test` → `fail == 0`, `pass > 0`, 6 files. Record the
   new EH assert count.
4. **Corpus.** Author `corpus/tailrec.wat`, build `tailrec.wasm` (`wat2wasm`), write `tailrec.expected`
   (§3.4); cross-check every value with wasmtime. Add `"tailrec"` to `combos.corpus_programs` + doc.
   `gleam test -- twocore/tier/tier_differential_test` (and the whole `tier/` suite) green.
5. **Authored proofs.** Write `test/twocore/tier/tailcall_capstone_test.gleam` (§3.5). `gleam test --
   twocore/tier/tailcall_capstone_test` green (constant space + opt-level bit-identity + default
   byte-identity + running-total report).
6. **Audits.** Tighten `residual_audit_test:43` (§3.3); re-measure `skipcount_test` constants + doc
   (§3.3). Run both; `residual_audit` stays `uncategorised == []`; `skipcount` `fail == 0` and within the
   (re-measured) ceiling.
7. **Full-suite re-measure.** `RUN_VENDOR=1 scripts/gen-conformance-svg.sh` (full vendored set). Record
   the new headline `pass / skip / 0`. Confirm the non-tail files' counts are unchanged (Q6).
8. **Docs + SVG + status.** Edit the SVG footnote, regenerate `docs/wasm-conformance.svg`; write
   `docs/phase-13-surface.md`; update `../01-status.md` (§3.6). Fill every MEASURED number.
9. **Final gate.** `gleam format` → `gleam format --check src test` clean → `gleam build` zero warnings →
   full `gleam test` → record the exact `N pass / 0 fail` total. Update `state.md`; announce the phase
   proven; compact per [`../03-phase-workflow.md`](../03-phase-workflow.md) §1.

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. **Official suite green (MEASURED).** `return_call.wast` + `return_call_indirect.wast` driven; the main
   `conformance_test` asserts `fail == 0`; the measured pass count is reported (in stdout + status +
   surface doc). No `return_call*` file is in an allowlist-deferred comment.
2. **EH unblock green.** `eh_conformance_test` drives 6 files × 3 profiles, `fail == 0 && pass > 0`;
   `eh_unconvertible` holds only `tag` + `try_table` (neither citing `return_call`); the module-doc
   narrative matches (6 of 8).
3. **Constant stack proven.** `tailcall_capstone_test` demonstrates 1,000,000-deep direct + mutual +
   indirect (same-module) tail recursion in bounded live memory; the imported case is **value-correct
   with a bounded caller frame** (cited to Q13-05's green suite), **not** a constant-stack claim (Q8).
4. **Differential green.** `tailrec` matches its spec `.expected` and is **result-identical** (values +
   traps) across every shipped `(state × mem × table)` combo (`tier_differential`) — it is funcref/`elem`-
   bearing, so not byte-identical — and **bit-identical** across `OptNone ≡ Baseline ≡ Aggressive`
   (`tailrec_opt_level_bit_identical_test`); non-tail results unchanged, non-funcref modules byte-identical
   and funcref modules (`callind`) result-identical (Q6).
5. **Audits honest + tight.** `residual_audit` green with `"call stack"`/`"return_call"` removed
   (`uncategorised == []`); `skipcount` `fail == 0`, within the re-measured ceiling, constants + doc
   updated to the MEASURED figures.
6. **Docs current.** `docs/wasm-conformance.svg` regenerated (footnote drops tail-call; EH count updated);
   `docs/phase-13-surface.md` written (acceptance table with measured numbers); `../01-status.md` metrics,
   history row, residual, and doc list updated.
7. **Clean build.** `gleam format --check src test` clean; `gleam build` zero warnings; the full
   `gleam test` suite green with the exact running total recorded (entering baseline 1,978 + Q13-01…05 +
   this unit's proofs; report the measured `N pass / 0 fail`).
8. **`///` doc comments on every new public/test function** authored here (contract: what it proves,
   which spec clause, what makes it go red) — no undocumented public surface.

---

## §7. What it leaves

- **Nothing downstream in-phase.** Q13-06 is the terminal unit; after it lands, `phase-13/` is removed and
  its decisions live in the code + tests + `../01-status.md`.
- **Categorized-deferred (unchanged, honest — updated in the audits/docs, not closed):** GC (typed refs /
  `struct`/`array`/`i31`), `try_table.wast` (needs typed refs / GC — Phase 13 is necessary-but-not-
  sufficient), `tag.wast` (`(rec …)` GC recursive types), stack-switching, the component model,
  relaxed-SIMD, WASI/DOM, and a native JS frontend. These stay in [`../02-roadmap.md`](../02-roadmap.md);
  the residual/skipcount audits keep them MEASURED and named.
- **No new trap, no optimizer/tier/state-strategy change** (Q8). A WASM tail call traps for exactly the
  reasons an ordinary call does; "call stack exhausted" is not a WASM trap and does not exist on the BEAM
  — which is the point the constant-stack witness proves.
