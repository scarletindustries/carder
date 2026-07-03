# Unit P6-10 — Conformance expansion + the empirical residual audit + differential

> **Owner: 1 agent · Wave B · depends on the whole Phase-6 pipeline + runtime (P6-01
> keystone, P6-03 decode, P6-04 validate, P6-05 lower, P6-06 emit_core, P6-07 rt_simd,
> P6-08 rt_mem/memory64, P6-09 cross-module linking) and, transitively, the entire landed
> Phase-5 harness (P5-11) which this unit EXTENDS in place.** Read
> [`00-overview.md`](00-overview.md) (decisions I1–I8) and
> [`PROVISIONAL-SURFACE.md`](PROVISIONAL-SURFACE.md) first, then — the doc whose shape and rigor
> this one MATCHES — Phase-5 [`11-conformance-expansion.md`](../phase-5/11-conformance-expansion.md)
> (the allowlist / oracle / term-ABI / skip-count machinery this unit extends, never duplicates) and
> the Phase-5 [`RECONCILIATION.md`](../phase-5/RECONCILIATION.md) decisions **R16** (greenness is
> MEASURED, never promised), **R17** (the multi-value / value-list run-ABI), **R18** (host-
> constructible values for the harness). This unit owns a **test suite + the vendor allowlist/pin**;
> **no production code**. Its headline deliverable is a **number** — the pinned suite's `pass` count
> roughly **doubles** as `simd/*.wast` (the largest file set in the whole testsuite) lights up, `fail`
> stays `0`, and the residual is **categorized and honest** (D9) — **plus** it OWNS the **empirical
> residual audit (R16)**: it measures exactly what the Phase-5 residual `~1088 asserts` *are* at the
> pinned SHA (the Phase-5 skipcount test and the Phase-5 capstone label them two *different* ways —
> this unit resolves the ambiguity by measurement), re-verifies `wast2json` convertibility per target
> file, routes the un-convertible files through our own WAT parser, and reports **measured** pass /
> skip / fail. Spec-first, never a change-detector (D8).

---

## Context

Phase 5 closed at **21525 pass / 1257 skip / 0 fail** under every shipped `(mode × state_strategy ×
mem_tier)` binding (the committed `docs/wasm-conformance.svg` counts) — the **complete standardized
WebAssembly surface minus SIMD**. That green is over an allowlist that deliberately **excludes** the
single largest slice of the testsuite: the `simd/*.wast` file set (the `v128` value type + ~236 lane
instructions), the `memory64.wast` runtime file, and `linking.wast` (cross-module wasm→wasm function
linking). Each was excluded for exactly one of three reasons, and Phase 6 removes all three:

1. **The engine could not run the construct.** SIMD (`v128.*`, the lane arithmetic / comparison /
   bitwise / shift / shuffle / swizzle / splat / extract-replace / narrow / widen / extend / convert
   / dot / pairwise / boolean-reduction / bitmask families + the `v128` memory load/store family) and
   the memory64 runtime (`i64`-addressed linear memory) decoded/validated *nowhere* or *lowered
   nowhere* (memory64 `lower`/`link` **rejected** `Idx64` with a categorized skip — R12). P6-03..P6-08
   build them; this unit **turns the corresponding `.wast` files on**.
2. **Cross-module function dispatch did not exist.** `link.gleam` *matched* `ProvidedFunc` signatures
   (P5) but generated code could not *call* an imported function living in another instance. So every
   file whose verifier module imports another module's **function** (chiefly `table_copy.wast` — see
   §D) had its dependent asserts skip wholesale. P6-09 wires the build-constructed closure capability;
   this unit **drives those files through it** and **measures the residual drop**.
3. **The file was un-`wast2json`-able at the pin.** `linking.wast` (typed-reference globals — GC
   syntax wabt 1.0.41 rejects) and `memory64.wast` (a `(module definition …)` module-linking form)
   have no binary the decoder can eat *at the pinned SHA*. P5-10 gave us a first-class WAT text parser
   producing the same `frontend/wasm/ast.gleam` Module the binary decoder produces; this unit **routes
   the un-convertible files through OUR parser** and **categorizes the genuinely out-of-scope text
   honestly** (never a silent drop).

This unit is the **surface-completion phase's measuring instrument**. It adds no engine behaviour; it
**proves** — honestly, against the [WebAssembly spec](https://webassembly.github.io/spec/core/)
(for SIMD the [vector instructions](https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions)
+ the fixed-width SIMD instruction set) and differentially against `wasmtime` — that the behaviour the
other units built is spec-correct under **both named modes and the `(state_strategy × mem_tier)`
matrix each new feature is defined for**, and it publishes the two numbers that make Phase 6 legible:
**how far `pass` rose** (SIMD roughly doubles it) and **how far the residual fell** once cross-module
function linking and the memory64 runtime land.

> **Empirical grounding (measured at the pinned SHA `193e551ff…`, wabt `1.0.41`, wasmtime `46.0.1`
> — the exact `vendor/PIN` versions, verified present on this machine).** Every count in this doc was
> produced by running `wast2json` at the pin and counting command types in the emitted JSON. They are
> the *convertibility + assert-count* facts the implementer builds on; the *post-run pass/skip/fail*
> are **measured by the run**, per R16, not asserted as magic integers here.

## Goal

> **Light up the SIMD surface, close the measured residual, report honestly, stay green under the
> matrix each feature is defined for.** Extend the vendor allowlist to the 59 `simd/*.wast` files +
> `memory64.wast` + `linking.wast`; teach the harness the `v128` **value** (a 16-byte binary carried
> as `V128Val` with a lane-typed, lane-wise oracle — integer lanes exact, float lanes by class per
> lane) and the **v128 invoke/result ABI** (16 raw little-endian bytes crossing the term ABI); route
> the un-`wast2json`-able files (`linking.wast`, `memory64.wast`) through the P5-10 parser and
> categorize their out-of-scope subset (typed-ref globals, `(module definition …)`) honestly; **own
> the R16 empirical residual audit** — measure exactly what the Phase-5 `~1088-assert` residual is,
> resolve the "multi-table `call_indirect`" vs "cross-module function imports" label conflict by
> measurement, and report the measured drop as those two features land; differentially check the new
> numeric surface against `wasmtime` (skipping gracefully when absent); and keep the whole thing at
> **`fail == 0`**. **Measurable done:** the pinned suite's `pass` **roughly doubles** (SIMD alone
> contributes **~24,281 `assert_return` + ~54 `assert_trap`** execution asserts + **~671 `assert_
> invalid` + ~509 `assert_malformed`** frontend asserts — *measured*), the residual **drops
> materially** as `table_copy.wast`'s ~1,649 asserts flip to pass (cross-module fn linking +
> multi-table `call_indirect`) and `memory64.wast`/`linking.wast`'s in-scope asserts light up via the
> WAT route, the residual skips are enumerated by **category** and asserted **closed** (no
> uncategorized skip), and the new surface is byte-identical across every shipped combination it is
> defined for (I7) — never "it compiles".

## Files owned

All under `test/twocore/conformance/**` (D1 — this unit is the sole owner of the harness and the
vendor pin; it **extends** the P5-11 machinery in place). **Nothing in `src/` is touched.**

| Path | Change | Purpose |
|---|---|---|
| `vendor/ALLOWLIST` | **extend** | Add the 59 `simd_*` files (flagless — SIMD is default-on at wabt 1.0.41; **`simd_memory-multi` needs `--enable-multi-memory`**); add `memory64` + `linking` annotated **parser-driven** (un-convertible at the pin); refresh the DEFERRED block to name what genuinely stays out of scope (relaxed-SIMD, GC typed refs, module-linking, EH). |
| `vendor/PIN` | **review/keep** | Confirm (do **not** bump unless a needed file is absent/mis-converts — R16/B.3): SIMD converts flaglessly at `WABT_VERSION=1.0.41`; `WASMTIME_VERSION=46.0.1` runs `v128`. The pin already holds SIMD. |
| `vendor/vendor.sh` | **extend** | SIMD files convert with default flags (+ the one multi-memory file); `memory64`/`linking` (un-convertible at pin) are **routed to the parser-driven path** — the raw `.wast` text is copied to `fixtures/<name>.wast` for the WAT runner, not dropped. The `spectest-interp` self-check still gates every convertible file. |
| `fixture.gleam` | **extend** | The `V128Val(lane: V128Lane, lanes: List(SpecValue))` `SpecValue` variant; decode the wast2json `{"type":"v128","lane_type":…,"value":[…]}` shape into per-lane scalar `SpecValue`s; per-lane `nan:canonical`/`nan:arithmetic` for `f32`/`f64` lanes. |
| `oracle.gleam` | **extend** | Lane-wise `v128` comparison: decode both actual and expected at the expected's `lane_type`, compare each lane with the **existing scalar oracle** (integer lanes exact bit-equality; `f32`/`f64` lanes by bit-equality OR NaN-class — the single comparison authority, reused per lane). |
| `driver.gleam` | **extend** | `TV128` arms in `tag`/`tag_term`/`export_types`; `use_term_abi` returns `True` when any arg/result is `v128`; `spec_to_term` assembles the 16-byte little-endian binary from a `V128Val`'s lanes; `tag_term`/`classify` decodes a returned 16-byte binary into lanes. The memory64/linking `instantiate_ast` path is unchanged (P5-11's seam). |
| `ffi.gleam` + `../../twocore_conformance_ffi.erl` | **extend** | `mk_v128(bytes: BitArray) -> Dynamic` / classify a returned `<<_:128>>` binary; the term-carrying invoke already exists (P5-11). |
| `wat_fixture.gleam` | **extend** | Drive `linking.wast` / `memory64.wast` through P5-10's `parse_script`; the typed-ref-global modules in `linking.wast` and the `(module definition …)` module in `memory64.wast` → categorized parse-skip (`wat.Unsupported`), the in-scope cross-module-fn / memory64 modules → run. |
| `reference/wasmtime.gleam` + `reference/wasmtime_test.gleam` | **extend** | Tier-B differential over the SIMD numeric surface + memory64 large-offset arithmetic; the `v128`-arg/result CLI marshalling (16 hex bytes) or the documented restriction; skip gracefully when wasmtime absent. |
| `conformance_test.gleam` | **extend** | Add the SIMD files to the two-profile `run_suite` + the tier matrix `run_combo` (SIMD-memory/lane-store files are tier-touching); **fix the stale module-doc** that mislabels the residual (§D); CI right-sizing for the ~24k new SIMD asserts. |
| `skipcount_test.gleam` | **extend** | Re-pin `phase5_baseline_pass`/`max_residual_skips` to the Phase-5 close; the R16 audit's category list gains `simd`/`v128`/`lane` as **passing** categories (they leave the skip set), and the residual's `call_indirect_table`/`cross-module`/`imported-global` gaps **shrink to 0** as P6-09 lands — asserted. |
| `residual_audit_test.gleam` | **new** | **The R16 deliverable.** Runs the pinned suite once, buckets every residual skip by `(file, reason-phrase)`, prints the audit table, and asserts the measured composition matches the enumerated categories — the honest, measured answer to "what are the ~1088 asserts". |
| `simd_conformance_test.gleam` | **new** | The SIMD headline roll-up: over the SIMD file set, `fail == 0 && pass > 0`, the previously-zero SIMD execution asserts now counted as passes; a per-family breakdown (int / float / mem / lane) so a single mis-lowered family fails on a named group, not diffusely. |
| `simd_differential_test.gleam` | **new** | The SIMD `(state_strategy × mem_tier)` differential over a small authored `.wat` corpus (reuses `combos.binding_for` / `Outcome`) — SIMD-memory ops are tier-touching, so a mis-endianned `atomics` `v128.store` diverges here. |
| `corpus/*.wat` + `*.expected` | **add** | `simdkernel.wat` (int+float lanes, shuffle, bitselect), `simdmem.wat` (`v128.load*`/`store*_lane` + an OOB trap), `mem64.wat` (i64-addressed load/store + a large-offset bounds trap), `xlink.wat` (cross-module function call) — spec-sourced `.expected`. |

> `test/twocore/tier/**` (P4-09's `combos.gleam`) is **not owned here** — this unit *consumes*
> `combos.binding_for` / `combos.shipped` (public, D1) and adds its own conformance-side differentials
> rather than editing that file (as P5-11 did — see its §H seam note). Adding a program to
> `combos.corpus_programs` would edit P4-09's const; this unit drives its new corpus from its own
> `*_differential_test.gleam` instead.

## Deliverables & freeze milestones

**Consumes** (every Phase-6 freeze + the landed pipeline/runtime + the whole Phase-5 harness):
- `«IR4-FROZEN»` (P6-01) — the **`TV128` `ValType`**, the **`ConstV128(bytes)` `Value`**, the SIMD
  `Expr` node(s) + the `SimdOp` enum, the SIMD-memory node decision, and any new `TrapReason`
  (**expected: none** — SIMD memory reuses `MemoryOutOfBounds`; §D SIMD trap phrase confirmed). The
  harness's `V128Val` + `tag`/`tag_term` arms must match the frozen `TV128` shape.
- `«RT-SIMD-SIG»` (P6-01) + the landed **`rt_simd`** (P6-07) — the ~236 lane ops the SIMD `.wast`
  files exercise (the harness never inspects `rt_simd`; it invokes the *compiled module* and judges
  results).
- `«MEM64-RUNTIME»` (P6-01) + the landed **rt_mem memory64** (P6-08) — `lower`/`link` accept `Idx64`;
  a 64-bit memory runs; the **documented page cap** is the trap boundary `memory64.wast`'s bounds
  asserts land on.
- `«XLINK»` (P6-01) + the landed **cross-module linking** (P6-09) — the `ProvidedFunc` closure
  dispatch that lights up `table_copy.wast`'s + `linking.wast`'s function imports.
- The landed **v128 invoke marshalling** — the keystone's host-constructible `v128` (a 16-byte
  binary) the harness builds for a `v128` argument and inspects for a `v128` result (R18-style, the
  SIMD analogue of `rt_ref.extern_of`/`classify_ref`). **Cross-unit seam — flagged in Open questions.**
- The landed P5 harness (P5-11): the term invoke-ABI (`ffi.call_instance_terms`/`result_list`, R17),
  the `ImportEnv`/`(register)` substrate, the `wat_fixture.gleam` adapter, the two-profile + matrix
  `conformance_test.gleam`, the `skipcount_test.gleam` guard.

**Produces** (terminal for the conformance axis — the **capstone P6-11** consumes this unit's measured
`pass/skip/fail` + the residual audit to write the phase's honest close and refresh the SVG): the
expanded allowlist, the `v128`-aware harness (value + oracle + ABI), the WAT route for the two
un-convertible files, the SIMD differential, the R16 residual audit, and the two headline tests
(`simd_conformance_test`, `residual_audit_test`) + the re-pinned `skipcount_test`. This unit publishes
**no** freeze milestone.

## Depends on (freeze milestones)

`«IR4-FROZEN»` · `«RT-SIMD-SIG»` · `«MEM64-RUNTIME»` · `«XLINK»` (all P6-01), plus the *landed*
implementations of P6-03..P6-09. Like P1-07's `Driver` seam and P5-11's, the harness machinery (the
`V128Val` value model, the lane-wise oracle, the allowlist, the WAT route) can be **built and
self-tested against a stub driver** before the pipeline lands; the compare-to-our-output assertions go
green as each upstream unit lands and flip fully green at the P6-11 capstone.

---

## A. The headline metric — the SIMD-led pass surge + the honest residual drop (MEASURED)

The one number Phase 6's conformance story turns on. State it as a **before/after with a categorized
residual**, and pin it in a test so a regression (a category silently going dark, a skip creeping
back, the residual re-inflating) goes red.

### A.1 The baseline (Phase-5, measured & committed)

| Metric | Phase-5 value | Source |
|---|---|---|
| **pass** | 21525 | `state.md` P5-12 row; `docs/wasm-conformance.svg` |
| **skip** | 1257 | within-allowlist skips (dominated by `table_copy.wast` — §D) |
| **fail** | 0 | the hard gate |
| whole files **excluded** | all 59 `simd_*` files; `memory64`; `linking`; + GC/EH/module-linking files (relaxed-SIMD is not in the testsuite) | ALLOWLIST DEFERRED block |

The 1257 in-allowlist skips are **not** the whole Phase-6 gap — the far larger gap is the **excluded
SIMD files** (measured below at **~25,515 assertions**, more than the entire current suite). So the
Phase-6 headline is two movements at once: the **excluded SIMD files enter the allowlist and roughly
double `pass`**, *and* the **in-allowlist residual falls** as cross-module function linking + the
memory64 runtime land.

### A.2 The after (what P6-10 must demonstrate — the measured shape)

**SIMD is the headline. Measured at the pin (all 59 `simd_*` files convert; `simd_memory-multi`
needs `--enable-multi-memory`):**

| SIMD assert kind | Measured count | Where it lands |
|---|---|---|
| **`assert_return`** (execution) | **24,281** | full pipeline → `Simd`/`SimdShuffle`/`SimdLoad*` through `rt_simd`/`rt_mem` |
| **`assert_trap`** (SIMD memory OOB) | **54** | `simd_load_splat` 32, `simd_load_extend` 12, `simd_address` 6, `simd_load_zero` 4 — all `"out of bounds memory access"` |
| **`assert_invalid`** (validation) | **671** | frontend-only → P6-04 (`v128` typing, lane-index range, shuffle indices 0..31) |
| **`assert_malformed`** (decode) | **509** | frontend-only → P6-03 (`0xFD` prefix, sub-opcodes, immediates) |
| **SIMD total** | **~25,515** | — |

So **`pass` roughly doubles** (from 21,525) as the SIMD files light up — the single largest
conformance movement in the project's history. Every SIMD `assert_return` is a spec-baked expected
`v128` (or a scalar for extract-lane / `any_true` / `all_true` / `bitmask`), compared **bit-exact
lane-wise** by the oracle (§C.2); the 54 SIMD-memory traps route through the **existing bounds-checked
`rt_mem` seam** and match the existing `"out of bounds memory access"` phrase (no new `TrapReason` —
I1/I6).

**The residual falls (measured composition — §D):** `table_copy.wast`'s **1,649 asserts** (443
`assert_return` + 1,206 `assert_trap`) flip from skip to pass as **cross-module function linking
(P6-09)** + **multi-table `call_indirect`** both hold; `memory64.wast`'s **45 `assert_return`** and
`linking.wast`'s in-scope function-linking asserts light up via the WAT route (§E).

**The exact post-Phase-6 `pass / skip / fail` are MEASURED by the run (R16), recorded by the
capstone** — this doc pins the **shape** (SIMD ~doubles `pass`; residual drops as P6-08/09 land;
`fail == 0`; residual closed), not the integers.

### A.3 The test that guards it

Extend `skipcount_test.gleam` (owned here) — re-pin the baseline to the Phase-5 close and add SIMD as
a **passing** category that *leaves* the skip set, and assert the two Phase-5 emit/link gaps shrink to
zero as P6-09 lands:

```gleam
/// The Phase-6 headline (I1 acceptance "conformance expansion"). Runs the full pinned suite once
/// (Safe profile) and asserts (a) fail == 0, (b) pass rose MATERIALLY over the Phase-5 baseline of
/// 21525 (SIMD lit up — ~24k execution asserts), (c) EVERY residual skip's reason is one of the
/// enumerated honest categories, (d) the total skip is at/below the re-pinned ceiling, and (e) the
/// two Phase-5 residual gaps — multi-table call_indirect + cross-module function imports (the
/// `table_copy.wast` block, §D) — are GONE (their skip buckets are empty) now that P6-08/09 landed.
pub fn skip_count_dropped_and_residual_is_honest_test() {
  let #(_count, total) = run_full_suite()
  assert total.fail == 0
  assert total.pass > phase5_baseline_pass          // SIMD doubled the suite
  assert total.skip <= max_residual_skips           // re-pinned ceiling (measured)
  let uncategorised = list.filter(total.skips, fn(r) { !in_allowed_category(r) })
  assert uncategorised == []                         // every residual skip is honest (D9)
  // The R16 close: the Phase-5 residual gaps are lit up, not merely re-labelled.
  assert list.filter(total.skips, is_cross_module_fn) == []
  assert list.filter(total.skips, is_multi_table_ci) == []
}
```

`in_allowed_category` matches by stable phrase; the Phase-5 `"call_indirect_table"` / `"cross-module"`
/ `"imported-global element-init"` phrases stay recognized (so a *regression* re-appearing is still
categorized, not uncategorized) but are asserted **empty** on a green Phase-6 run. `max_residual_skips`
and `phase5_baseline_pass` are named constants the implementer sets from the measured run; **the
assert direction (SIMD ↑ pass, the two gaps → 0, residual closed) is the spec-grounded invariant**,
not the exact integers (R16, D8).

---

## B. Allowlist + pin — turning on `simd/*`, `memory64`, `linking`

### B.1 The SIMD file set (measured, complete, with flags)

The complete `simd_*.wast` set at the pinned SHA — **59 files**, enumerated (never hand-waved). All
convert **flaglessly** at wabt 1.0.41 (**SIMD is default-on** — `--enable-simd` is not even a
recognized option at this version, verified) **except `simd_memory-multi` which needs
`--enable-multi-memory`**. Counts are the measured `assert_return` / `assert_trap` (execution) +
`assert_invalid` / `assert_malformed` (frontend) per file:

| File | ret | trap | inv | mal | Notes |
|---|---:|---:|---:|---:|---|
| `simd_address` | 36 | 6 | 2 | 2 | `v128.load`/`store` w/ static offset + OOB traps |
| `simd_align` | 8 | 0 | 12 | 34 | alignment validation (mostly frontend) |
| `simd_bit_shift` | 211 | 0 | 24 | 15 | `iNxM.shl/shr_s/shr_u`, count masked mod lane width |
| `simd_bitwise` | 139 | 0 | 28 | 0 | `v128.not/and/or/xor/andnot/bitselect` |
| `simd_boolean` | 259 | 0 | 12 | 4 | `any_true`/`all_true` |
| `simd_const` | 265 | 0 | 0 | 181 | `v128.const` round-trip (all lane shapes) |
| `simd_conversions` | 232 | 0 | 18 | 30 | narrow/widen/extend/convert/trunc_sat |
| `simd_f32x4` | 772 | 0 | 8 | 8 | f32x4 min/max/abs/neg/sqrt + NaN/`-0.0` |
| `simd_f32x4_arith` | 1803 | 0 | 16 | 0 | f32x4 add/sub/mul/div (single-rounding) |
| `simd_f32x4_cmp` | 2581 | 0 | 18 | 6 | f32x4 eq/ne/lt/le/gt/ge |
| `simd_f32x4_pmin_pmax` | 3872 | 0 | 6 | 8 | f32x4 pseudo-min/max (NaN/`-0.0` corners) |
| `simd_f32x4_rounding` | 176 | 0 | 8 | 16 | ceil/floor/trunc/nearest |
| `simd_f64x2` | 793 | 0 | 8 | 0 | f64x2 min/max/abs/neg/sqrt |
| `simd_f64x2_arith` | 1806 | 0 | 16 | 0 | f64x2 add/sub/mul/div |
| `simd_f64x2_cmp` | 2659 | 0 | 18 | 6 | f64x2 comparisons |
| `simd_f64x2_pmin_pmax` | 3872 | 0 | 6 | 8 | f64x2 pseudo-min/max |
| `simd_f64x2_rounding` | 176 | 0 | 8 | 16 | ceil/floor/trunc/nearest |
| `simd_i16x8_arith` | 181 | 0 | 11 | 0 | i16x8 add/sub/mul/neg |
| `simd_i16x8_arith2` | 151 | 0 | 17 | 2 | min/max (s/u), avgr_u, abs |
| `simd_i16x8_cmp` | 433 | 0 | 30 | 0 | i16x8 comparisons |
| `simd_i16x8_extadd_pairwise_i8x16` | 16 | 0 | 4 | 0 | `extadd_pairwise` |
| `simd_i16x8_extmul_i8x16` | 104 | 0 | 12 | 0 | extended-multiply low/high s/u |
| `simd_i16x8_q15mulr_sat_s` | 26 | 0 | 3 | 0 | `q15mulr_sat_s` (saturating) |
| `simd_i16x8_sat_arith` | 204 | 0 | 12 | 4 | add/sub sat (s/u) |
| `simd_i32x4_arith` | 181 | 0 | 11 | 0 | i32x4 add/sub/mul/neg |
| `simd_i32x4_arith2` | 121 | 0 | 14 | 12 | min/max/abs/dot corners |
| `simd_i32x4_cmp` | 433 | 0 | 30 | 10 | i32x4 comparisons |
| `simd_i32x4_dot_i16x8` | 28 | 0 | 3 | 0 | `dot_i16x8_s` |
| `simd_i32x4_extadd_pairwise_i16x8` | 16 | 0 | 4 | 0 | `extadd_pairwise` |
| `simd_i32x4_extmul_i16x8` | 104 | 0 | 12 | 0 | extended-multiply |
| `simd_i32x4_trunc_sat_f32x4` | 102 | 0 | 4 | 0 | `trunc_sat_f32x4_s/u` |
| `simd_i32x4_trunc_sat_f64x2` | 102 | 0 | 4 | 0 | `trunc_sat_f64x2_s/u_zero` |
| `simd_i64x2_arith` | 187 | 0 | 11 | 0 | i64x2 add/sub/mul/neg |
| `simd_i64x2_arith2` | 21 | 0 | 2 | 0 | abs |
| `simd_i64x2_cmp` | 102 | 0 | 10 | 0 | i64x2 eq/ne/lt_s/… |
| `simd_i64x2_extmul_i32x4` | 104 | 0 | 12 | 0 | extended-multiply |
| `simd_i8x16_arith` | 121 | 0 | 8 | 0 | i8x16 add/sub/neg (**no i8x16.mul**) |
| `simd_i8x16_arith2` | 184 | 0 | 19 | 6 | min/max/avgr_u/abs/popcnt |
| `simd_i8x16_cmp` | 413 | 0 | 30 | 0 | i8x16 comparisons |
| `simd_i8x16_sat_arith` | 188 | 0 | 12 | 12 | add/sub sat (s/u) |
| `simd_int_to_int_extend` | 228 | 0 | 24 | 0 | extend low/high s/u |
| `simd_lane` | 274 | 0 | 83 | 106 | `extract_lane`/`replace_lane`/`shuffle`/`swizzle` |
| `simd_linking` | 0 | 0 | 0 | 0 | **v128 globals across modules** (register + import; structural — see B.2) |
| `simd_load` | 17 | 0 | 5 | 3 | `v128.load` |
| `simd_load16_lane` | 32 | 0 | 3 | 0 | `v128.load16_lane` |
| `simd_load32_lane` | 20 | 0 | 3 | 0 | `v128.load32_lane` |
| `simd_load64_lane` | 12 | 0 | 3 | 0 | `v128.load64_lane` |
| `simd_load8_lane` | 48 | 0 | 3 | 0 | `v128.load8_lane` |
| `simd_load_extend` | 72 | 12 | 12 | 6 | `load8x8/16x4/32x2_s/u` + OOB traps |
| `simd_load_splat` | 80 | 32 | 8 | 4 | `load8/16/32/64_splat` + OOB traps |
| `simd_load_zero` | 23 | 4 | 4 | 6 | `load32/64_zero` + OOB traps |
| `simd_memory-multi` | 0 | 0 | — | — | **needs `--enable-multi-memory`**; structural (multi-memory v128 access) |
| `simd_select` | 6 | 0 | 0 | 0 | `select` over v128 |
| `simd_splat` | 158 | 0 | 22 | 1 | `iNxM.splat`/`fNxM.splat` |
| `simd_store` | 17 | 0 | 6 | 3 | `v128.store` |
| `simd_store16_lane` | 32 | 0 | 3 | 0 | `v128.store16_lane` |
| `simd_store32_lane` | 20 | 0 | 3 | 0 | `v128.store32_lane` |
| `simd_store64_lane` | 12 | 0 | 3 | 0 | `v128.store64_lane` |
| `simd_store8_lane` | 48 | 0 | 3 | 0 | `v128.store8_lane` |
| **SIMD TOTAL** | **24,281** | **54** | **671** | **509** | **58 flagless + 1 multi-memory** |

> **`simd_linking.wast`** exercises a **`v128` global exported from one module and imported (as `(mut
> v128)`) by another** (`(register "Mv128")` + `(import "Mv128" "mg-v128" (global (mut v128)))`). It
> carries no `assert_return` of the counted kinds (its non-commented content is module definitions +
> a register + an import), so it is a **structural/link file** — it exercises SIMD + cross-module
> **state** linking. Allowlist it; if its (few) asserts need cross-module mutable v128-global state
> that the E5 isolation model makes hard (§D.2 depth honesty in P5-11), categorize that honestly
> rather than fake-green it. **`simd_memory-multi.wast`** similarly is a multi-memory-with-v128
> structural file (0 counted execution asserts; needs `--enable-multi-memory`).

### B.2 `memory64.wast` + `linking.wast` — un-convertible at the pin (the WAT route)

Both are **un-`wast2json`-able at the pinned SHA** — measured, with the exact failing token:

- **`linking.wast`** (610 lines, 21 modules, **133 asserts**: 65 `assert_return` + 25 `assert_trap` +
  43 `assert_unlinkable`). `wast2json` aborts at **line 99**: `(global (export "g-const-funcnull")
  (ref null func) (ref.null func))` — **typed-reference globals** (`(ref null func)` / `(ref func)`,
  the GC-proposal typed-reference syntax) that wabt 1.0.41 rejects (`expected i32, i64, f32, f64,
  v128, externref, exnref or funcref`). 28 such forms exist. The file's **core** is cross-module
  function/table/memory/global linking (3 function imports; 4 `call_indirect`; 43 `assert_unlinkable`
  fail-closed cases). **Route through the WAT parser (§E):** the typed-ref-global modules →
  categorized parse-skip (GC typed refs, out of scope); the in-scope function/table/memory-linking
  modules + their `assert_return`/`assert_trap`/`assert_unlinkable` → run through **P6-09**.
- **`memory64.wast`** (206 lines, 10 modules, **45 `assert_return` + 14 `assert_invalid`**, 0 trap).
  `wast2json` aborts at **line 8**: `(module definition (memory i64 0x1_0000_0000_0000))` — a **`(module
  definition …)` module-linking-proposal form** (`expected a module field`). That is the **only**
  blocking line; the other 9 modules (`(module (memory i64 …))` + `memory.size`/data-segment asserts)
  are in-scope memory64. **Route through the WAT parser (§E):** the one `(module definition …)` module
  → categorized parse-skip (module-linking, out of scope); the 9 in-scope memory64 modules + their 45
  asserts → run through **P6-08** (the memory64 runtime), landing on the **documented page cap** trap
  boundary where the spec's asserts expect.

> **This is exactly the R16 discipline (measured, honest).** The two files Phase 6 most wants are
> **not simply "turn on with a flag"** — they are entangled with out-of-scope proposal syntax at this
> pin. The audit **measures** that entanglement, routes what our own parser can handle, and
> categorizes the rest — never claims greenness it did not measure.

### B.3 Pin discipline

The pinned `TESTSUITE_SHA=193e551ff…` already carries the whole SIMD file set and both target files
(verified: 59 `simd_*` + `memory64` + `linking` all exist at the pin). **SIMD converts flaglessly**
at `WABT_VERSION=1.0.41` and **`WASMTIME_VERSION=46.0.1` runs `v128`** (both verified present). So a
bump is **unnecessary for SIMD** and is **not the preferred fix** for `memory64`/`linking` (R16: route
through the WAT parser, don't bump). **Only if** the WAT parser genuinely cannot handle the in-scope
subset of `memory64`/`linking` at this pin (e.g. our parser lacks `(memory i64 …)` text support —
**flagged, §E cross-unit seam**) do we consider a bump to a testsuite revision whose `memory64.wast`/
`linking.wast` drop the module-linking / typed-ref-global forms — a deliberate, reviewed change,
because the baked-in expected values are only trustworthy against a known revision (P1-07 "Grounded
facts"), and a bump could perturb *other* files' baked values (re-run the whole allowlist to confirm
neutrality if it happens). **The default is: keep the pin, route through the parser, categorize the
residual.**

### B.4 `vendor.sh` — SIMD converts, the two un-convertibles become parser-driven

- The 59 `simd_*` files convert with default flags (`simd_memory-multi` gets the
  `--enable-multi-memory` flag column, mirroring the existing `align → --enable-memory64`
  convention). The `spectest-interp` self-check gates each (it validates the baked expected values are
  self-consistent before the fixtures are trusted).
- `memory64` / `linking` (un-convertible at the pin) get the P5-11 **route change**: `vendor.sh`
  copies the raw `.wast` text into `fixtures/<name>.wast` so the runner drives them through the P5-10
  parser (§E), instead of dropping them. They are gated by the §F.2 `wat_parse ≡ decode∘wat2wasm`
  differential + their own baked `assert_return`/`assert_trap` values (which the parser reads
  directly — still spec-sourced Tier-A).

---

## C. The `v128` value in the harness — `V128Val`, the lane-wise oracle, and the 16-byte invoke ABI

The invoke ABI is numeric + reference today (P5-11). A `v128` is neither an integer nor a reference —
it is a **16-byte binary** (`<<_:128>>`, I1/D5), and the spec's expected `v128` is a **lane-typed
array** of per-lane scalar expectations. Three layers extend in lock-step: the fixture value model,
the oracle, and the marshalling.

### C.1 `V128Val` — the fixture value model (`fixture.gleam`)

wast2json encodes a `v128` value as (measured, verified against wabt 1.0.41 output):

```json
{"type": "v128", "lane_type": "i32", "value": ["0", "0", "0", "0"]}
```

- `lane_type` ∈ `{"i8","i16","i32","i64","f32","f64"}` — how the 16 bytes are chunked into lanes
  (i8→16 lanes, i16→8, i32→4, i64→2, f32→4, f64→2).
- `value` is an **array of decimal-of-unsigned-bits strings**, one per lane — exactly the scalar
  encoding (D5), so `f32 1.0` is `"1065353216"`, `-0.0` is `"2147483648"`. **Float lanes may carry the
  NaN tokens** `"nan:canonical"` / `"nan:arithmetic"` per lane (verified — `simd_f32x4_arith` etc.).

Model a `v128` as its **lane_type + a list of per-lane scalar `SpecValue`s**, so the oracle reuses the
existing scalar comparison per lane (§C.2) — the cleanest, most spec-faithful shape:

```gleam
/// Which lane shape a v128 expectation is decoded at (the wast2json `lane_type` field). Determines
/// the lane count and each lane's scalar type for the lane-wise oracle.
pub type V128Lane {
  Lane_I8   Lane_I16   Lane_I32   Lane_I64   Lane_F32   Lane_F64
}

pub type SpecValue {
  // …existing I32Val/I64Val/F32Bits/F64Bits/F32Nan/F64Nan/NullRef/ExternRefVal/FuncRefVal…
  /// A v128 value (P6-10). `lane` is the wast2json `lane_type`; `lanes` is one scalar `SpecValue`
  /// per lane (I32Val/I64Val for integer lanes; F32Bits/F64Bits or F32Nan/F64Nan for float lanes) in
  /// **lane order 0..N-1** (== little-endian byte order — lane 0 is the low bytes). The raw 16-byte
  /// binary is reconstructible from `lanes` (see driver.spec_to_term); a returned v128 is decoded
  /// back into this shape at the EXPECTED's lane type for lane-wise comparison (oracle).
  V128Val(lane: V128Lane, lanes: List(SpecValue))
}
```

`parse_spec_value` gains the `"v128"` arm: read `lane_type` → `V128Lane`; map each `value[i]` string
through the **existing** scalar `parse_spec_value` at the lane's scalar type (`"i32"`/`"f32"`/… — so
per-lane NaN tokens and decimal-of-bits are handled by the already-tested scalar path, no new parsing
logic). An absent `value` (a placeholder) → an all-zero `v128` never compared.

### C.2 The oracle — lane-wise `v128` comparison (`oracle.gleam`)

Per the spec's vector value model
(<https://webassembly.github.io/spec/core/syntax/values.html#vectors>) and vector-instruction
semantics (<https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions>), a
`v128` result is correct iff **every lane** is correct at the expected's lane interpretation. Crucially
this **cannot be a raw 16-byte `==`**: a float-lane result may be a **NaN**, which the spec compares by
**class** (canonical/arithmetic), not by bit pattern — exactly as for scalar floats. So the oracle
**decodes both actual and expected at the expected's `lane_type` and compares lane-by-lane with the
existing scalar `matches`**:

```gleam
/// v128 comparison (P6-10). Decode `actual` and `expected` into `lane` lanes and compare each with
/// the SCALAR oracle: integer lanes by exact width-masked bit-equality; f32/f64 lanes by bit-equality
/// OR NaN-class (the same `is_f32_nan`/`is_f64_nan` used for scalar floats — sign ignored, canonical
/// ⊂ arithmetic). This is the ONLY correct comparison: a lane-wise float result may be a NaN whose
/// payload bits are implementation-chosen but spec-legal, so a raw 16-byte `==` would wrongly reject
/// a spec-correct result. Cites the SIMD NaN-propagation rules (mirror scalar §4.4.numerics).
V128Val(lane, exp_lanes) ->
  case actual {
    V128Val(_actual_lane, act_lanes) ->
      // decode both at `lane` (the expected's interpretation), then lane-wise scalar match
      matches_all(reinterpret(act_lanes, lane), exp_lanes)
    _ -> False
  }
```

Because a `v128` is stored as its lanes, `reinterpret` is identity when the actual is already tagged
at the same lane type (the common case); the driver always tags a returned `v128` result at the
export's declared `TV128` and the oracle decodes at the *expected's* `lane_type`. The oracle stays the
**single comparison authority** (D8) — no `v128` equality decided anywhere else, and the NaN-class
rule is the same one already tested for scalar floats (reused, not re-implemented).

> **Spec corner — SIMD NaN.** The SIMD spec's float lane ops follow the **scalar** NaN
> propagation/canonicalization (I3): `f32x4`/`f64x2` `min`/`max`/`pmin`/`pmax` return the spec NaN /
> `-0.0` result, arithmetic ops may produce arithmetic NaNs. The `simd_f32x4*`/`simd_f64x2*` files
> assert these with per-lane `nan:canonical`/`nan:arithmetic` tokens — the lane-wise class oracle is
> exactly what judges them. A single-rounded `f32x4` op that produced a double-rounded lane, or a
> `min` that returned the wrong NaN, fails on the exact file.

### C.3 The `v128` invoke/result ABI — 16 raw little-endian bytes (`driver.gleam` + `ffi.gleam`)

A `v128` crosses the harness ABI as **16 raw little-endian bytes** — a BEAM binary, like a reference
(a term), **not** an integer. So it rides the **term ABI** (`ffi.call_instance_terms` / `result_list`,
already built for R17/R18), and `use_term_abi` must fire on `v128`:

- **`use_term_abi(args, results)`** returns `True` when any arg is a `V128Val` **or** any result type
  is `TV128` (in addition to the existing reference / multi-value triggers). A pure numeric call stays
  on the byte-identical integer fast-path (I7 — a non-SIMD module is unchanged).
- **`spec_to_term(V128Val(lane, lanes))`** assembles the **16-byte little-endian binary** from the
  lanes: each lane's raw bits packed at its width, lane 0 lowest (`<<l0:.../little, l1:.../little,
  …>>`), then handed to `ffi.mk_v128` (which is identity over a `BitArray` — the generated code
  expects `<<_:128>>`). This is the "16 raw bytes across the harness ABI" contract: the argument
  *is* the 16 bytes, byte-order little-endian, exactly the runtime representation (I1).
- **`tag_term(TV128, term)`** classifies the returned 16-byte binary back into a `V128Val`. Because a
  returned `v128` has no intrinsic lane type (it is 16 opaque bytes), the driver tags it at a
  **canonical lane** (e.g. `Lane_I8`, the finest) or defers lane interpretation to the oracle
  (the oracle re-decodes at the *expected's* `lane_type`). Either is correct — the load-bearing fact
  is that the 16 bytes round-trip **byte-exact** (a `v128` result whose bytes differ from the spec's
  expectation in any lane fails).
- **`export_types` / `tag`** gain a `TV128` arm (they exhaustively match `ir.ValType`, which P6-01
  grows with `TV128` — see the cross-unit seam below).

```gleam
/// Construct the 16-byte binary a v128 argument carries (P6-10). Identity over the BitArray at
/// runtime — the generated code treats a v128 as <<_:128>> (I1). The 16 bytes are little-endian
/// lane layout: lane 0 occupies the low-order bytes. CONTRACT with P6-01/P6-06: this is the exact
/// shape emit_core/rt_simd consume as a v128 operand.
@external(erlang, "twocore_conformance_ffi", "mk_v128")
pub fn mk_v128(bytes: BitArray) -> Dynamic
```

> **Cross-unit seam (flagged, Open questions).** `TV128` is added to `ir.ValType` by **P6-01**. The
> harness's `driver.gleam` matches `ir.ValType` **exhaustively** (`tag`, `tag_term`, `export_types`,
> `use_term_abi`). When `TV128` lands, those matches break unless a `TV128` arm exists — and
> **`driver.gleam` is THIS unit's file**. P6-01 must therefore either add a minimal compile-satisfying
> `TV128` arm to `driver.gleam` when it grows `ValType` (so the tree stays green Wave-0→Wave-B), **or**
> the reconcile pass sequences it so the harness lands its real `TV128` arms immediately after the
> keystone. Analogous to P5-11's R18 seam (the harness must construct/inspect the keystone's frozen
> value shape): the keystone must expose a **host-constructible `v128`** (a 16-byte binary is trivially
> host-constructible — no opaque box like `externref`), so `mk_v128` is just the identity over a
> `BitArray`. **Confirm in reconcile.**

---

## D. The empirical residual audit (R16) — resolving the `~1088-assert` ambiguity by measurement

**This unit OWNS the R16 audit.** The Phase-5 residual is labelled **two incompatible ways** in the
committed tree, and the task is explicit that P6-10 must resolve it by *measuring* what those asserts
actually are:

- `skipcount_test.gleam` (Phase-5) attributes the residual to **"multi-table `call_indirect`"**
  (`~1092 asserts` blocked by `emit: UnsupportedNode("call_indirect_table…")` in `table_copy.wast`).
- `conformance_test.gleam`'s module doc + `docs/phase-5-surface.md` + `state.md` P5-12 attribute the
  **`~1088`** residual to **"cross-module wasm→wasm FUNCTION imports"** (a distinct linking feature).

These read as a contradiction. **The measurement resolves it — and the answer is: both labels
describe the SAME file, `table_copy.wast`, which needs BOTH features.**

### D.1 What `table_copy.wast` actually is (measured)

`table_copy.wast` (auto-generated from `meta/generate_table_copy.js`) is **1,649 asserts** (443
`assert_return` + 1,206 `assert_trap`). Measured structure:

- It **registers** a first module `a` exporting `ef0..ef4`, then a second (verifier) module does
  **`(import "a" "ef0" (func (result i32)))` × 5** — **cross-module wasm→wasm FUNCTION imports** (90
  `(import …)` forms across the file).
- The verifier declares **two tables** `$t0`, `$t1` and its check functions do **`call_indirect $t0`
  / `call_indirect $t1`** — **36 explicit non-zero-table `call_indirect`s** (18 each). It fills the
  tables with `elem` segments referencing the imported functions and `table.copy`s within/between
  them, then verifies each slot by calling **the imported function through the non-zero table**.

So **every verifier assert requires both**: (1) cross-module function dispatch (to reach the imported
`ef*`) **and** (2) multi-table `call_indirect` (to dispatch through `$t0`/`$t1`). The Phase-5 skipcount
label ("multi-table `call_indirect`") and the Phase-5 capstone label ("cross-module function imports")
are **two facets of the one blocking file** — not a contradiction, and **neither alone was the whole
story**. The audit states this precisely.

### D.2 The resolution + the Phase-6 movement

- **Multi-table `call_indirect`** landed in the Phase-5 follow-up (`aa89228 "P5 follow-up: multi-table
  call_indirect + imported-global/declarative element-init"`). So as of the pin, that facet is
  **already satisfied** — which is why the skipcount test's `is_multi_table_ci` bucket may already be
  shrinking. **The audit re-measures this at the current pin** (do not trust the stale label).
- **Cross-module function dispatch** is **P6-09**. Once it lands, the verifier module **instantiates
  and dispatches**, and `table_copy.wast`'s **~1,649 asserts flip from skip to pass**. That is the
  bulk of the Phase-5 residual, closed — **measured, not promised**.
- `linking.wast`'s in-scope function-linking asserts (§B.2, §E) similarly light up via P6-09 + the
  WAT route; its typed-ref-global asserts stay a **categorized** GC skip.

**The audit deliverable (`residual_audit_test.gleam`, new).** Run the pinned suite once; bucket every
residual skip by `(file, stable-reason-phrase)`; print an **audit table** (file → count → cause); and
assert the measured composition matches the enumerated causes. This is the honest, measured answer the
task demands — and it makes the *next* residual (if any) legible instead of mislabelled:

```gleam
/// The R16 empirical residual audit (P6-10 owns it). Runs the pinned suite once (Safe), groups the
/// residual skips by originating FILE and stable reason-phrase, prints the audit table, and asserts:
///  (a) the Phase-5 `table_copy.wast` block (cross-module fn import + multi-table call_indirect) is
///      GONE — its skip bucket is empty (P6-08/09 landed);
///  (b) every remaining residual skip is one of the ENUMERATED Phase-6 categories (relaxed-SIMD,
///      GC-proposal typed refs, module-linking `(module definition)`, EH `(tag)`, `assert_exhaustion`,
///      cross-module MUTABLE-state depth) — never an uncategorised / mislabelled skip (D9);
///  (c) NO skip reason is a stale mislabel: the audit prints file+phrase so a future reader sees the
///      TRUE cause, not a guessed one.
pub fn residual_audit_is_measured_and_honest_test()
```

### D.3 The categorized Phase-6 residual (what stays skipped — honestly)

After Phase 6 lights up SIMD + memory64 + cross-module function linking, the residual is **only**:

1. **Relaxed-SIMD** — the separate non-deterministic proposal (not in this testsuite revision; if any
   relaxed op appears, categorized). Deferred (I8).
2. **GC-proposal typed references** — `linking.wast`'s typed-ref globals (`(ref null func)` etc.),
   `ref_null`/`ref_is_null`/`elem`/`select`/`table_init`'s GC-tainted asserts (already a Phase-5
   category). Later.
3. **Module-linking / component-model syntax** — `(module definition …)` in `memory64`/`memory`/
   `table`; the one memory64 module → categorized parse-skip (§E). Later.
4. **Exception-handling** — `imports.wast`'s `(tag …)`. Non-goal.
5. **`assert_exhaustion`** (call-stack depth) — a BEAM/WASM stack-model mismatch, a categorized skip
   since Phase 1. Not a surface gap.
6. **Cross-module MUTABLE-state depth** — a later module importing a registered module's *mutable*
   table/memory (the P5-11 §D.2 depth honesty; `simd_linking.wast`'s `(mut v128)` global import may
   land here). Reported honestly if invasive under the E5 isolation model; a **named** category, never
   a silent drop.

`memory64` **iff its runtime landed** (P6-08 is in-scope this phase, so it should light up — if a
quality problem forces a cut, its files are a **named file-level skip**, R16, never silent).

---

## E. The WAT-only path for the un-convertible target files (`linking.wast`, `memory64.wast`)

The real payoff of the WAT parser (H5/P5-10) for Phase 6: the two files `wast2json` cannot convert at
the pin (§B.2) run **from our own `parse_script`** through the P5-11 `wat_fixture.gleam` adapter +
`instantiate_ast` driver seam (both already built). This unit **extends** the adapter to drive them
and to categorize their out-of-scope subset:

- **`memory64.wast`** — the WAT parser parses the 9 in-scope `(module (memory i64 …))` modules; the
  one `(module definition (memory i64 0x1_0000_0000_0000))` → `wat.Unsupported` (module-linking) →
  categorized parse-skip. The in-scope modules' 45 `assert_return` (`memory.size` on a fresh i64
  memory, data-segment sizing) run through **P6-08** (the memory64 runtime); the 14 `assert_invalid`
  (`(data (i64.const 0))` "unknown memory", i64 address type mismatches) run through the frontend
  (`check_frontend_ast`). **Landing point:** the memory64 asserts exercise the **documented page cap**
  (I4) as the trap boundary — a `grow` beyond the cap returns `-1`, an access beyond it traps
  `MemoryOutOfBounds`, exactly where the spec's asserts expect.
- **`linking.wast`** — the WAT parser parses the cross-module function/table/memory-linking modules;
  the 28 typed-ref-global forms → `wat.Unsupported` (GC typed refs) → categorized parse-skip. The
  in-scope modules run through **P6-09** (function dispatch across instances) + P5-09 (state imports);
  its 43 `assert_unlinkable` (unsatisfied / type-mismatched imports) prove **fail-closed** at link
  time (the H6/D3a proof — a silent link would be ambient authority).

> **Cross-unit seam (flagged, Open questions).** The WAT route for `memory64.wast` requires **P5-10's
> `parse_module`/`parse_script` to accept `(memory i64 …)` text syntax**. Decode/validate already
> handle memory64 (P5, R12) and the `.ir` printer/parser round-trips `memory i64` (P5-02); but whether
> the *WAT text* parser (P5-10) parses `(memory i64 …)` and `(module definition …)`-as-Unsupported is a
> **P6-02/P6-03 frontend concern**. If P5-10's parser does **not** accept `(memory i64 …)` text at the
> pin, this unit **flags it** (rather than working around it) and the fallback is a reviewed pin
> consideration (§B.3) or a named file-level skip for `memory64.wast` — measured, never faked. Same
> for `linking.wast`: the parser must skip typed-ref-global modules as `Unsupported` (not choke the
> whole file). Confirm the parser's WAT surface in reconcile.

---

## F. The new-surface differential (Tier-B `wasmtime` + `wat_parse ≡ decode∘wat2wasm`)

Two differential obligations, both extending `reference/wasmtime.gleam` (Tier-B — never on the Tier-A
path; the `.wast` files still carry their own baked expected values, which are the primary trust):

### F.1 `wasmtime` differential over the SIMD numeric + memory64 surface

For **authored / random** inputs where a corpus program carries no baked `.wast` answer, cross-check
the new surface against `wasmtime 46.0.1` (verified present, runs `v128`):

- **SIMD numeric** — lane arithmetic / comparison / shuffle / conversion / dot / narrow-widen results.
  Honest scope of the ABI: `wasmtime run --invoke` prints ints as signed decimal and floats as decimal
  (not raw bits), and a **`v128` argument/result** must be marshalled in wasmtime's textual `v128`
  form (`iNxM a b …` / `fNxM …`). The adapter either (a) passes/reads `v128` via wasmtime's lane-decimal
  form (documented in the module doc), or (b) restricts the SIMD differential to programs whose
  **exported result is a scalar** (extract-lane / `any_true` / `all_true` / `bitmask` / a lane read
  after the op) so the existing scalar CLI path suffices — **the recommended, simplest path** (a
  `v128` op is fully observed through a scalar lane read, and the baked `.wast` values are the primary
  Tier-A oracle regardless). **Argue the choice in the module doc; the baked values remain primary.**
- **memory64** — large-offset (> 2³²) `i64`-addressed load/store byte images + the page-cap trap
  boundary, cross-checked against wasmtime's memory64 support where the executable has it.

It **skips gracefully** when wasmtime is absent (the existing `wasmtime.available()` guard), recorded
— the CI pin installs it.

### F.2 `wat_parse(text) ≡ decode(wat2wasm(text))` over the new text (H5 DoD)

For the WAT-routed files (`memory64`/`linking`) and a small SIMD `.wat` corpus, assert our parser and
the binary path produce the **same runnable behaviour** (byte-identical results + identical traps):
`wat2wasm(text) → decode → validate → lower → run` **≡** `wat.parse_module(text) → validate → lower →
run`, over a set of exported invokes. `wat2wasm` is the pinned reference (a `vendor/PIN` prerequisite,
verified present); it skips gracefully when wabt is absent. This is the safety net that keeps the WAT
route trustworthy (a parser bug — a mis-folded expression, a dropped `memory i64` — diverges on the
exact input) rather than a fixture crutch.

---

## G. Full matrix × both profiles — tier-sensitivity of the new files + CI sizing

### G.1 What runs under the matrix

- **Both named profiles** (`spec_suite_safe_test` / `spec_suite_unsafe_test`) run the **whole**
  expanded allowlist — the conformance-neutral + optimizer-soundness proof (I7) now covers SIMD too. A
  SIMD assertion the Aggressive optimizer perturbs (e.g. a const-folded `v128.const` lane) goes red.
- **The five shipped combos** (`combos.shipped`) run the **tier-touching** files. **SIMD-memory** ops
  (`v128.load*`/`store*`/`*_lane`, the `simd_load_*`/`simd_store_*`/`simd_address`/`simd_memory-multi`
  files) read/write linear memory → they **must** run under `cell×paged`, `threaded×paged`,
  `cell×atomics`, `threaded×atomics`, `cell×nif` (a mis-endianned `atomics` `v128.store`, a threaded
  record dropping a v128 across a call → red on the exact file). **Pure lane** SIMD files (arithmetic /
  comparison / bitwise / shuffle over locals — the bulk of the ~24k asserts) are **tier-invariant by
  construction** (no memory/table/global state) → they run under the two full profiles only, and join
  `matrix_skip_numeric` with the documented tier-invariance justification (§G.2).

### G.2 CI right-sizing (extend `matrix_skip_numeric`, don't gut coverage)

SIMD adds **~24k asserts** — running the pure-lane files ×5 combos would OOM CI exactly as the
pure-numeric files would. Extend the **same honest principle** the existing `matrix_skip_numeric`
carries (tier-invariant files run under the two profiles, not ×5):

- **Keep** every **SIMD-memory / lane-store / multi-memory-v128** file in the ×5 matrix (that is the
  whole point of the tier axis).
- **Add** the **pure-lane SIMD** files (arith/cmp/bitwise/boolean/const/conversions/splat/lane/
  shuffle/extmul/dot/pairwise/extend — the ~24k-assert bulk) to `matrix_skip_numeric` **with the
  tier-invariance justification** (they exercise no instance state, so their code is byte-identical
  across strategies/tiers; the two full-profile runs cover them). Never for convenience — always with
  the justification the existing entries carry.
- If total matrix memory is still too high, **partition by combo** (subsets of tier-touching files
  under subsets of combos such that every tier-sensitive file is covered by every relevant tier at
  least once) rather than dropping files — and record the partition. Flag the exact CI budget as an
  Open question for the capstone's CI config (the ~24k SIMD asserts are a real budget change).

### G.3 memory64 + cross-module linking under the matrix (I4/I5)

- **memory64** runs under `paged` (+ `portable`) — I4: `atomics`/`nif` **fail closed** for an over-cap
  64-bit memory (the existing atomics fail-closed gate). So the memory64-routed asserts run under the
  `paged` combos + both full profiles; an over-cap 64-bit atomics binding is a **categorized** tier
  edge (I4), exactly as Phase-4/5 categorized their tier edges — never a silent pass.
- **cross-module linking** (`table_copy`, `linking`) is **`cell`-first** (I5): cross-instance calls
  compose cleanly under `cell` (each instance owns its state). Under `threaded`, calling into instance
  B against B's state record is a scoping question (I5) — the honest first target is `cell` (the Safe
  default) for these files, with the `threaded` cross-module interaction **categorized honestly** if
  it proves invasive. Lighting them up under one profile is a real conformance win; how far the matrix
  extends is a reconcile decision (Open questions).

---

## H. New acceptance corpus programs (tier differential of the new surface)

The pinned suite proves spec-correctness; the tier differential proves **byte-identity across
strategies/tiers** on a small, fast, spec-`.expected`-bearing corpus. Add four programs (authored
`.wat` → `wat2wasm` → `.wasm`, `.expected` spec-sourced / `wasmtime`-cross-checked), driven under
`combos.shipped` via the reused `combos.binding_for` / `Outcome` machinery:

| Program | Exercises | Spec anchor for `.expected` |
|---|---|---|
| `simdkernel.wat` | integer + float lane arithmetic, `i8x16.shuffle` (16 immediates), `v128.bitselect`, `any_true`/`all_true`/`bitmask`, `splat`/`extract_lane`, a narrow/widen round-trip, `i32x4.dot_i16x8_s` — result observed via a scalar `extract_lane` / `all_true` | vector instructions <https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions> |
| `simdmem.wat` | `v128.load`/`store`, `load8_splat`/`load32_zero`/`load8x8_s` (extend), `load8_lane`/`store8_lane`, and an **out-of-bounds `v128.load` → trap `out of bounds memory access` with no host escape** (via the bounds-checked `rt_mem` seam, I6) | memory instructions (SIMD load/store); eager bounds (I6) |
| `mem64.wat` | a 64-bit memory: `i64`-addressed load/store, `memory.size`/`grow` returning `i64` page counts, a **large (> 2³²) offset access → bounds trap** at the documented cap | memory64 proposal; §4.4.7 with `i64` address (I4) |
| `xlink.wat` | module B `(import "a" "f" (func …))` calls module A's exported function across instances via the linker-built closure (I5); an **unsatisfied import → `assert_unlinkable` fail-closed** | §7 embedding; §4.5.4 linking (I5/I6) |

`simd_differential_test.gleam` drives these: each program's `Outcome` must (a) match `.expected` and
(b) be **byte-identical across every shipped combination it is defined for** (the P4-09 two-assertion
pattern, D7/D8). The load-bearing spec corners: `simdmem`'s **trap-before-write** (no partial effect,
via the checked seam), `mem64`'s **page-cap trap boundary** (I4 — the exact spec-cited constant P6-08
pins), and `simdkernel`'s **lane-exactness** (a mis-lowered lane / wrong shuffle index diverges).

> **Seam note:** these live in `conformance/corpus/**` (this unit's) and the differential in
> `conformance/**` (this unit's), reusing `combos.binding_for` (public). It does **not** add them to
> `combos.corpus_programs` (P4-09's const). If the capstone wants them in the canonical tier list,
> that is a P4-09/P6-11 reconcile decision (Open questions).

---

## Effect / soundness / security note

- **The harness cannot make an unsound engine look sound (D8/I6).** Every expected value is
  spec-sourced (the baked `.wast` answers for Tier-A; the IEEE/lane-semantics rules for the oracle;
  `wasmtime` for authored Tier-B). "Green" means *every spec-observable was preserved* — **v128 by
  bit pattern, lane-wise** (D5/D7: integer lanes exact, float lanes by bit-or-NaN-class), traps by
  spec phrase, references by null-ness/identity — not "it compiled". A wrong lane, a double-rounded
  `f32x4` op, a mis-endianned `v128.store`, a missing SIMD-memory OOB trap, an unsound optimizer pass,
  or a tier that diverges byte-for-byte all turn a **specific file** red.
- **SIMD's only trap surface is the bounds-checked memory seam (I6).** SIMD ops are pure/total (no
  SIMD trap — saturation replaces overflow-trap; no SIMD division-trap). The 54 SIMD-memory OOB
  asserts route through the **existing `rt_mem` bounds check → `MemoryOutOfBounds`** (`"out of bounds
  memory access"` — the existing phrase, no new `TrapReason`, I1). A `v128` is an opaque 16-byte value
  in Safe mode — it cannot address memory except through the checked seam. **Worst case of a SIMD bug
  is a wrong result or a node-safe crash, never a host escape** — the harness proves this by asserting
  the OOB trap fires (a silent OOB `v128.load` that returned garbage would fail the `assert_trap`).
- **Fail-closed cross-module imports are PROVEN, not assumed (I5/I6/D3a).** `linking.wast`'s 43
  `assert_unlinkable` assert that an unsatisfied / type-mismatched **function** import **fails at link
  time** (`link:` phrase) — a silent link would be exactly the ambient authority D3a forbids. The
  dispatch is a **handed-in closure** (P6-09), never an ambient `apply` of an attacker-named
  `module:atom` — the harness supplies a value set, the linker matches (D3a intact). `table_copy`'s
  cross-module calls dispatch through that closure capability.
- **memory64 keeps every access bounds-checked → trap; the page cap is a hard trap boundary (I4).**
  The harness asserts a `grow` beyond the documented cap returns `-1` and an access beyond current
  size traps exactly where the spec's asserts expect — the page cap is a *trap boundary*, not a
  reservation, and Safe forbids tier-N as before.
- **Floats-and-v128 as raw bits throughout (D5/D7).** SIMD changes nothing here: `v128` results and
  `.expected` values are raw bit patterns (lane-wise), NaN stays class-matched per lane, `-0.0` stays
  distinct from `+0.0` per lane. The `mem64` `i64` addresses are raw integers, never a BEAM-double
  round-trip.
- **Isolation is unchanged (E5).** Every instance is one-process; the harness never spawns a second
  process against one instance's memory. Cross-module linking shares *provided closures / state
  values* through P6-09's contract, not raw processes; the shared-**mutable**-import depth stays
  P6-09's concern and is reported honestly, never faked green.

---

## Deviations from the provisional surface (ARGUED)

The provisional surface (`PROVISIONAL-SURFACE.md`) sketches IR4 / AST4 / `rt_simd` / linker — the
*compiler* surface. It says **nothing about the conformance harness's value model / ABI**, which is
correct (that is this unit's to define). The deviations are therefore *additions* the harness needs,
argued so reconcile can pin ownership:

1. **`V128Val(lane, lanes)` in `fixture.SpecValue` — a NEW harness value variant (not in the
   provisional surface).** *Argument:* wast2json encodes a `v128` expectation as a lane-typed array of
   per-lane decimal-bit strings (measured: `{"type":"v128","lane_type":"i32","value":["…"]}`), and the
   oracle **must** compare lane-wise (a float lane may be a NaN, so a raw 16-byte `==` is *wrong*).
   Carrying the lane_type + per-lane scalar `SpecValue`s lets the oracle **reuse the existing scalar
   comparison** per lane (NaN-by-class included) — the minimal, most spec-faithful shape. The
   alternative (store raw 16 bytes + compare by `==`) is **rejected**: it would false-fail a
   spec-correct float-lane NaN result. This is a test-side type; it does not touch the IR's
   `ConstV128(bytes: BitArray)` (which correctly stores raw bytes for the *compiler*).
2. **The `v128` invoke ABI rides the TERM path (`call_instance_terms`), not a new SIMD ABI.**
   *Argument:* a `v128` is a BEAM binary (`<<_:128>>`) — a term, not an integer — so the R17/R18 term
   ABI (already built) carries it unchanged; `use_term_abi` simply fires on `v128` too. No new FFI
   beyond `mk_v128` (identity over a `BitArray`). This keeps the numeric fast-path byte-identical (I7).
3. **`memory64.wast` / `linking.wast` are PARSER-DRIVEN, not `wast2json`-driven.** *Argument:*
   measured — both are **un-`wast2json`-able at the pinned SHA** (a `(module definition …)` line;
   typed-ref globals). The provisional surface assumes memory64/linking "light up"; the *honest*
   (R16) route is the WAT parser + categorized parse-skips for the out-of-scope subset, or a reviewed
   pin change if the parser cannot handle the in-scope subset. Flagged, not silently assumed.
4. **The residual is `table_copy.wast` needing BOTH cross-module fn linking AND multi-table
   `call_indirect` — the two Phase-5 labels are the same file.** *Argument:* measured (§D) — this
   resolves the provisional/overview ambiguity (the overview §1 notes the labels disagree; the audit
   settles it by measurement). Not a deviation in the surface, but a correction to the *residual
   accounting* the overview asked this unit to own.

No deviation touches the IR4/`rt_simd`/linker *compiler* surface — those are P6-01..09's. This unit's
surface is the **harness**, and every addition above is confined to `test/twocore/conformance/**`.

---

## Verification — Definition of Done (D8)

- **SIMD headline green (§A/§C).** The 59 `simd_*` files reach `fail == 0` with their **~24,281
  `assert_return` + ~54 `assert_trap`** counted as **passes**; `pass` **rose materially** over the
  Phase-5 baseline of 21,525 (SIMD roughly doubled the suite — the exact post count measured &
  recorded by the capstone, R16). The lane-wise oracle (§C.2) self-tests green: an integer-lane result
  matches by exact bits; an `f32x4` NaN lane matches by class; a mis-endianned or wrong-lane result
  fails. Cites the vector-instruction + NaN-propagation spec.
- **v128 ABI green (§C.3).** A `v128` argument round-trips as 16 little-endian bytes (arg → engine →
  result), byte-exact; `use_term_abi` fires on `v128`; a non-SIMD module stays on the byte-identical
  numeric fast-path (I7).
- **Residual audit green (§D — the R16 deliverable).** `residual_audit_test` prints the measured
  `(file → count → cause)` table; the Phase-5 `table_copy.wast` block (cross-module fn import +
  multi-table `call_indirect`) is **empty** (P6-08/09 landed); every remaining skip is one of the
  enumerated Phase-6 categories; **no skip is mislabelled** (the audit prints the true cause). The
  `skipcount_test` re-pin asserts `is_cross_module_fn` and `is_multi_table_ci` buckets are empty.
- **WAT route green (§E).** `memory64.wast` runs from our parser to `fail == 0` on its in-scope
  modules (the `(module definition …)` module a categorized skip); `linking.wast`'s in-scope
  function-linking asserts pass (typed-ref-global modules a categorized GC skip); its
  `assert_unlinkable` cases prove **fail-closed**. If P5-10's parser cannot handle `(memory i64 …)`
  text at the pin, that is **flagged** (Open questions), not worked around.
- **Differential green (§F).** The SIMD numeric surface + memory64 large-offset arithmetic agree with
  `wasmtime` on authored inputs; `wat_parse ≡ decode∘wat2wasm` agrees over the new text corpus (both
  skip gracefully + recorded when wabt/wasmtime absent; installed + pinned in CI).
- **Matrix + both profiles green (§G).** The whole expanded allowlist is `fail == 0 && pass > 0` under
  `profiles.safe()` **and** `profiles.unsafe()`; the **SIMD-memory / lane-store** files are `fail == 0`
  under **every** `combos.shipped` combination and **byte-identical** across them (I7); the pure-lane
  SIMD bulk is tier-invariant-justified in `matrix_skip_numeric`; memory64 runs under `paged`(+
  `portable`) with the over-cap atomics edge categorized (I4); cross-module linking runs `cell`-first
  with the `threaded` interaction categorized if invasive (I5). CI stays within budget (documented
  partition, coverage auditable).
- **New-surface corpus green (§H).** `simdkernel`/`simdmem`/`mem64`/`xlink` match `.expected` and are
  byte-identical across the combos each is defined for; `simdmem`'s OOB `v128.load` traps
  before-write; `mem64`'s over-cap access traps at the documented boundary; `xlink`'s unsatisfied
  import fails closed.
- **Repo gate.** `gleam format --check src test` clean; `gleam build` **zero warnings**; `gleam test`
  green (≥ the current 1212, now higher); every new public function carries a contract doc comment.
  **Done = the expanded suite passes** under real backends, never "it compiles".

---

## What this unit leaves

The Phase-6 surface is **proven runnable and spec-correct, and measured**: the SIMD file set is green
(the `v128` value + ~236 lane ops, bit-exact lane-wise, ~24k execution asserts lit up — the largest
conformance movement in the project), the memory64 runtime file runs at the documented page-cap trap
boundary, and cross-module function linking closes the Phase-5 residual (`table_copy.wast`'s ~1,649
asserts, `linking.wast`'s in-scope function-linking asserts). The **R16 empirical residual audit is
owned and answered**: the `~1088-assert` Phase-5 residual is measured to be `table_copy.wast` needing
**both** cross-module function dispatch **and** multi-table `call_indirect` (resolving the two
conflicting Phase-5 labels), and the Phase-6 residual is enumerated, categorized, and asserted closed.
The new surface is byte-identical across every shipped `(state_strategy × mem_tier)` it is defined for
and under both modes, differentially checked against `wasmtime`, and — for the two un-convertible files
— driven from our own WAT parser with the out-of-scope subset categorized honestly. This unit consumes
the whole Phase-6 pipeline and emits nothing downstream except **the numbers** and the green.

**Its sibling / consumer:** the **capstone P6-11** quotes this unit's measured `pass / skip / fail`,
refreshes `docs/wasm-conformance.svg` to Phase-6 scope (the complete standardized surface — SIMD +
memory64 + cross-module linking), and writes the phase's honest close (what was proved; what — relaxed
SIMD, GC typed refs, module-linking, EH, cross-module mutable-state depth — stays deferred; and that
**Phase 7 / Porffor is now unblocked**).

**Deferred (stated, not dropped):** relaxed-SIMD (the separate non-deterministic proposal → later);
GC-proposal typed references (`(ref null func)` globals, typed refs / `struct`/`array`/`i31`); the
module-linking / component-model `(module definition …)` syntax; exception-handling `(tag …)`;
cross-module **mutable**-state depth (gated by the E5 isolation model — driven and reported here, not
guaranteed); `assert_exhaustion` (a BEAM/WASM stack-model mismatch, a categorized skip). *JS on the
BEAM via Porffor* is the **goal** the completed surface now enables (Phase 7).

---

## Open questions (for the planner / cross-unit sync)

1. **`TV128` host-constructibility + the driver exhaustive-match seam (P6-01).** §C.3 needs the
   keystone's `v128` to be host-constructible (trivial — a 16-byte binary; `mk_v128` is identity over
   a `BitArray`) **and** needs `driver.gleam`'s exhaustive `ir.ValType` matches (`tag`/`tag_term`/
   `export_types`/`use_term_abi`) to gain a `TV128` arm **when P6-01 grows `ValType`**, or the tree
   won't compile between Wave 0 and Wave B. **Ask:** P6-01 adds a minimal compile-satisfying `TV128`
   arm to `driver.gleam` (as its file-ownership note already commits to "minimal compile-satisfying
   arms" in downstream files), and documents the `v128` runtime shape (16-byte LE binary) in
   `«RT-SIMD-SIG»` so the harness's `mk_v128`/`spec_to_term` match it byte-for-byte.
2. **The WAT parser's memory64 + skip-the-out-of-scope-module surface (P5-10 / P6-02/03).** §E requires
   `wat.parse_module`/`parse_script` to (a) parse `(memory i64 …)` text and (b) emit `wat.Unsupported`
   for the `(module definition …)` module and the typed-ref-global modules **without choking the whole
   file**. If P5-10's parser lacks `(memory i64 …)` text support at the pin, the memory64 WAT route
   fails. **Ask:** confirm the parser's Phase-6 WAT surface; if absent, decide (reconcile) between a
   parser extension, a reviewed pin bump, or a named file-level skip for `memory64.wast` — measured,
   never faked.
3. **The `v128` differential ABI vs `wasmtime` (§F.1).** wasmtime's CLI marshals `v128` in a textual
   lane form, not raw bytes. **Ask:** confirm the recommended restriction — the SIMD `wasmtime`
   differential covers programs whose **exported result is a scalar** (a lane read / `all_true` /
   `bitmask`), so the existing scalar CLI path suffices and the baked `.wast` values stay the primary
   Tier-A oracle — is acceptable, or whether a full `v128`-in/`v128`-out wasmtime marshalling is
   wanted.
4. **CI budget for ~24k new SIMD asserts (§G.2).** SIMD roughly doubles the suite; running the
   pure-lane files ×5 combos would OOM. **Ask:** confirm the plan — pure-lane SIMD files join
   `matrix_skip_numeric` (tier-invariance-justified), SIMD-memory/lane-store files stay ×5, partition
   by combo if still too large — and pin the exact CI budget with the capstone's config (P6-11).
5. **Cross-module linking's `state_strategy` reach (P6-09 / I5).** `table_copy`/`linking` light up
   `cell`-first; the `threaded` cross-instance interaction is categorized if invasive. **Ask:** confirm
   how far the matrix extends for these files (Open Q (d) in the overview) so the skip category is
   either "runs under every combo" or a named "`threaded` cross-module → categorized edge", never a
   silent gap.
6. **`simd_linking.wast` mutable v128-global import (§B.1 / §D.3).** It imports a `(mut v128)` global
   across modules — cross-module **mutable** state, which the E5 isolation model makes hard (the
   P5-11 §D.2 depth honesty). **Ask:** confirm this is a named categorized edge (cross-module
   mutable-state depth), not a required green, so the file is allowlisted honestly.
7. **`memory_grow.wast` re-verify (P5 note).** The Phase-5 ALLOWLIST claims `memory_grow.wast` is
   "100% multi-memory at pin (spectest-interp 0/50)", but measured it converts with
   `--enable-multi-memory` to **47 `assert_return`**. **Ask:** re-run `spectest-interp` at the pin
   during the audit; if it now self-checks, it may be a bonus allowlist add (multi-memory grow) — a
   small measured win to fold into the R16 audit, not a promise.
