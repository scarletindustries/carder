# Phase 11 · P11-06 — Capstone — PHASE 11 PROVEN

> **Owner:** _unclaimed_ · **Consumes:** every prior freeze (P11-01…P11-05) · **Produces:** no new
> freeze — the terminal **`PHASE 11 PROVEN`** milestone. The ONLY unit that edits the single
> status/wiring point (`specs/01-status.md` §5 + `specs/state.md`) and writes `docs/phase-11-linking.md`.
> Read order: `00-overview.md` → `RECONCILIATION.md` (authoritative) → this doc.

## §1 Goal

Prove the overview §1 **acceptance table** for `--link` — that a single self-contained `.beam` is
byte-behaviour-identical to the in-process path and boots on a bare OTP node — through **two layers**
plus three correctness-hygiene assertions, then confirm the whole prior suite stays green:

- **L1 — in-process linked ≡ non-linked differential (isolates merge-correctness, cheap).** Over the
  FULL corpus × `{Safe, Unsafe}` × `{Cell, Threaded}` × `{tier-P (paged), tier-O (atomics)}`, compare
  the **linked** output (via `beam_link.link_program`, loaded in-process) against the **non-linked**
  oracle (`driver.pipeline_with`) by **bit pattern** (D5/D7) and identical **trap/`TrapReason`**.
  Implements **O5** (behaviour-identical), the acceptance rows *Result-identical* + *Conformance
  neutral*, and the linker corrections **R4/R5/R6** (fun-captures, intra-module apply, `instantiate/N`
  root) as organic regressions.
- **L2 — bare-node differential (measured, not asserted).** Over the IMPORT-FREE representative subset
  (a numeric, a memory, a trap, and a reference/v128 program) × `state_strategy` × `{tier-P, tier-O}`,
  drive the P11-05 harness (`twocore_linked_boot_ffi`) to boot a scrubbed fresh `erl` with only the
  merged `.beam` on `-pa`, diff its values/traps vs the L1 in-process oracle, and prove a
  **constant-space** `sum_to(100000)` run on the bare node. Implements the acceptance rows *Single
  artifact* + *Bare-node proof*.
- **Determinism (R10 / O7):** `link_program` run twice on the same input is **byte-identical**.
- **D3a (R9 / O3):** a STRUCTURAL assertion over the *merged* `cerl` for the whole corpus + `module_info`
  exact-export check (R11).
- **Green-confirm:** the full prior gleeunit suite + WASM conformance stay `fail=0` (confirm, do not
  re-derive — §5 of `03-phase-workflow.md`).

**Honest-scope boundary (O8/R14):** L2 covers **import-free** modules only — a bare node has no import
providers, so import-bearing modules are rejected on the `--link` CLI path (R14, P11-04). Import-bearing
**merge-correctness** is therefore proven only *in-process*, by L1 (which supplies providers and drives
the merged `instantiate/1`). tier-N (`nif`) is excluded from both layers (O8 — a NIF cannot be merged).

## §2 Depends on / Produces

| Consumes (freeze) | From | Used for |
|---|---|---|
| `«RT-LAYER-FROZEN»` — `opt_level.OptLevel` leaf | P11-01 | binding construction imports `OptLevel` from `twocore/opt_level` |
| `«CLOSURE-FROZEN»` — `link_manifest.ambient_allowlist()` | P11-02 | the `ambient` argument to `link_program`; the R11 export set |
| `«LINKER-IFACE-FROZEN»` — `beam_link.link_program` + `LinkError` | P11-03 | L1/L2 merge, determinism, D3a predicate |
| `«BARE-NODE-HARNESS-PROVEN»` — `twocore_linked_boot_ffi` | P11-05 | L2 spawn + isolation gate + seed-then-invoke |
| CLI `--link` gate (`to-beam-wasm`) | P11-04 | fail-closed rejection confirm |

**Produces:** `PHASE 11 PROVEN` — no downstream unit; on proof, Phase 11 is compacted into
`01-status.md` §3 and `specs/phase-11/` is removed.

## §3 What it owns + design

**Owns — create:**
- `test/twocore/backend/linked_selfcontained_test.gleam` — L1 + L2 + determinism + D3a + green-confirm.
- `docs/phase-11-linking.md` — the deployment doc + the R17 three-way `link` disambiguation
  (`profiles.link/1` = runtime instantiation; `runtime/link.gleam` = import weaving;
  `backend/beam_link.link_program` = whole-program merge).

**Owns — edit (the single status/wiring point, D1):**
- `specs/01-status.md` — rewrite §5 (today it records "an emitted module is **not self-contained**",
  `01-status.md:104`/`:115`) to add the `--link` self-contained path; add the Phase-11 line to §3 on proof.
- `specs/state.md` — landing log, then reset to the template for the next phase; remove `specs/phase-11/`.

**Touches NO `src/` file.** The CLI wiring is P11-04; the linker is P11-03. The capstone only *drives*
frozen public APIs and edits status/docs (overview §4 — "the single registration/wiring point only").

**L1 linked driver.** Build a `runner.Driver` that is `driver.pipeline_with(binding)` (`driver.gleam:82`)
with its instantiate seams overridden to interpose the merge at the `.core → .beam` boundary — reusing
the oracle's decode/validate/lower/`link.link_imports` chain (`driver.gleam:193` `instantiate_typed`) and
swapping only the tail `build_beam.compile_and_load(core)` for:

```gleam
// generated (non-linked) core text for `m` under `binding`
let assert Ok(core) = pipeline.ir_to_core(m, binding)          // pipeline.gleam:481
// whole-program merge (P11-03), ambient set from the frozen manifest (P11-02)
use #(atom, beam) <- result.try(
  beam_link.link_program(bit_array.from_string(core), m.name, link_manifest.ambient_allowlist())
  |> result.map_error(describe_link_error),                    // LinkError -> String
)
use loaded <- result.try(                                       // build_beam.gleam:91 (code:load_binary)
  build_beam.load_module(atom, "linked", beam) |> result.map_error(...),
)
// seed-then-invoke: import-free -> ffi.start_instance; import-bearing -> start_instance_with(imports)
```

The comparison reuses the existing normalized `Outcome` + machinery: `combos.evaluate(driver, name)`
(`combos.gleam:201`) reduces each program to `#(List(Outcome), spec_failures)` (`Outcome` = `Value(bits)`
/ `Trap(reason)` / `InstantiateTrap` / `Rejected` / `Instantiated`, `combos.gleam:184`), and
`combos.identity_across` (`combos.gleam:327`) diffs the **linked** outcome-list against the **oracle**
outcome-list per program. So each program point asserts (a) spec-correctness vs `.expected` and (b)
linked ≡ oracle by bit pattern — exactly the two load-bearing checks the Phase-3/4 differentials use
(`differential_test.gleam:84`, `tier_differential_test.gleam:63`).

**L1 binding matrix (8).** `{Safe, Unsafe} × {Cell, Threaded} × {Paged, Atomics}` — reuse
`combos.binding_for` for the four Safe non-`nif` combos (`combos.metered`, `combos.gleam:136`) and an
Unsafe overlay (`profiles.compose(Binding(..profiles.unsafe(), safe_max_pages: combos.cap_pages), …)`);
`nif`/tier-N is excluded (O8).

**L1 corpus.** The full value-corpus: `combos.corpus_programs` (`combos.gleam:49`) plus the
reference/SIMD/bulk/EH `.expected`-bearing programs (`reftab`, `simddot`, `simdmem`, `simdxform`,
`bulkmem`, `mem64`, `multimem`, `ehthrow`, `ehcatch`, `ehcatchall`, `ehnested`, `ehrethrow`) — the term
ABI is handled by `driver.invoke` (`driver.gleam:404`). Plus ONE authored import-bearing fixture (an
imported `spectest` global read by an export) driven **only** in L1 — the honest-scope home for
import-bearing merge-correctness (its merged `instantiate/1` is a reachability root, R6).

**L2 design.** For each import-free subset program × `state_strategy` × `{tier-P, tier-O}`: obtain
`#(atom, beam)` from `link_program`, hand it (+ export + args) to `twocore_linked_boot_ffi` (P11-05),
which writes `<atom>.beam` into an isolated `-pa` temp dir, spawns a fresh `erl` with `ERL_LIBS` scrubbed,
runs the in-child `code:which == non_existing` gate over the representative closure set (HALTs nonzero on
any hit), then **seed-then-invoke in ONE process** (R6 — `instantiate` then the export, matching the
strategy self-detect in `twocore_conformance_ffi:start_common`, `twocore_conformance_ffi.erl:80`), and
returns the value/trap. Diff each vs the L1 in-process oracle. The subset: **numeric** `sum_to`,
**memory** `mem` (round-trip + an OOB trap on invoke, `mem.expected`), **trap** `intops` (div-by-zero /
integer-overflow traps, `intops.expected`), **reference/v128** `simddot` (pure v128) and `reftab`
(references) — all import-free.

**Constant-space on the bare node.** `sum_to` at `n=1000` vs `n=100000` in the child, GC'd and measured
(the `gc_and_memory` precedent, `twocore_conformance_ffi.erl:21`; the harness reports child process
memory), asserting `mem_big < mem_small * 4` — mirroring `constant_space_threaded_test.gleam:62`.

**Determinism (R10).** `link_program(core, name, ambient)` twice ⇒ identical `beam` `BitArray` (`==`).

**D3a (R9).** Acquire the *merged* `cerl` for each corpus artifact and re-apply the linker's STRUCTURAL
predicate — extending the `emit_core_security_test` discipline (`emit_core_security_test.gleam`, the
structural walk over generated Core) to the merged artifact. The predicate (single-sourced in
`twocore_linker_ffi.erl`, P11-03) rejects `#c_call{module=erlang,name=apply}`, any apply on a
data-derived var, any residual off-closure fun-capture, and any off-allowlist remote — and MUST NOT flag
a legitimate first-class `apply Op(Args)` (`CApplyExpr`). Passing over the whole corpus (which contains
legitimate `call_indirect` applies) IS the proof of no false-positive. Plus R11: the merged module
exports **exactly** the original exports + `instantiate/N` + `module_info`.

## §4 The work

1. Scaffold `linked_selfcontained_test.gleam`: import `beam_link`, `link_manifest`, `build_beam`,
   `pipeline`, `driver`, `combos`, `runner`, `conformance/ffi`, `twocore/opt_level`, `profiles`,
   `instance.{Binding}`.
2. Write `linked_driver(binding) -> runner.Driver` (spread `driver.pipeline_with(binding)`, override the
   instantiate seams with the `link_program`+`load_module` tail from §3). Add
   `describe_link_error(LinkError) -> String` covering all seven variants.
3. Write `link_bindings() -> List(#(String, Binding))` — the 8-way matrix (§3).
4. **L1:** for each `(label, binding)` × program, run `combos.evaluate(linked_driver(binding), name)` and
   `combos.evaluate(driver.pipeline_with(binding), name)`; collect spec-failures from both +
   `combos.identity_across(name, [oracle, linked])`. Assert the flattened failure list is `[]`.
5. Add the import-bearing fixture + its L1-only differential (merged `instantiate/1` seeds correctly).
6. **Determinism:** compile one representative program to core; `link_program` twice; assert `beam == beam`.
7. **D3a:** acquire merged `cerl` per corpus artifact; assert the structural predicate returns `ok`;
   assert the R11 export set is exactly `original ++ [instantiate/N, module_info/0, module_info/1]`.
8. **L2:** for each subset program × strategy × `{tier-P, tier-O}`, merge → drive
   `twocore_linked_boot_ffi` → assert (a) the isolation gate fired (no `twocore@`/`gleam@` reachable in
   the child), (b) value/trap equals the in-process oracle. Add the bare-node `sum_to(100000)`
   constant-space assertion.
9. **Fail-closed confirm:** through the P11-04 CLI entry, `--link` on a tier-N build and on an
   import-bearing module both exit non-zero with a typed error (confirm; P11-04 owns the primary test).
10. Run `gleam format`, `gleam build` (0 warnings), `gleam test` (whole suite green), refresh the
    conformance triple; write `docs/phase-11-linking.md`; edit `01-status.md` §5/§3 + `state.md`; remove
    `specs/phase-11/`.

## §5 Tests

All in `linked_selfcontained_test.gleam`. Spec anchors: numerics
<https://webassembly.github.io/spec/core/exec/numerics.html>, bounds/traps
<https://webassembly.github.io/spec/core/exec/instructions.html>; every value is bit-pattern-compared
(D5/D7), every trap via `runner.trap_matches`.

- `l1_linked_equals_nonlinked_full_matrix_test` — the headline L1 differential over the full corpus × 8
  bindings; a single merge bug (a dropped def, a mis-mangled call) changes an `Outcome` → red on the exact
  program+binding. (O5; acceptance *Result-identical* / *Conformance neutral*.)
- `l1_fun_capture_reachability_test` — **R4 regression.** A Safe metered program (its metering path
  captures `fun gleam@dynamic@decode:decode_int/1`) and `simddot` (rt_simd's 332 remote fun-captures):
  if the linker missed fun-captures as roots/rewrite targets the merged module `undef`s — caught here in
  L1 (and fatally on the bare node in L2).
- `l1_intra_module_apply_links_test` — **R5 class-2 regression.** Any cross-helper program: a missed
  self-module mangle fails `core_lint` at link time, so `link_program` returns `Error` and the
  differential cannot build — asserts `link_program` returns `Ok` for the corpus.
- `l1_instantiate_root_seeds_state_test` — **R6 regression.** `mem`/`gvar`: if `instantiate/N` is not a
  DCE root the seed runtime is stripped and the export reads an unseeded cell → trap/undef; the merged
  module must reproduce the oracle's values.
- `l1_import_bearing_instantiate1_merges_test` — the import-bearing fixture (imported `spectest` global):
  its merged `instantiate/1` seeds + reads correctly in-process (honest-scope home; omitted from L2).
- `determinism_link_twice_byte_identical_test` — **R10.** `link_program` twice ⇒ identical `beam`.
- `merged_exports_exactly_original_plus_instantiate_plus_module_info_test` — **R11.** No extra exports, no
  per-module `module_info` leakage; exactly one synthesized `module_info` pair.
- `d3a_structural_over_merged_corpus_test` — **R9 positive.** The structural predicate returns `ok` over
  every merged corpus artifact (proves no false-positive on legitimate `CApplyExpr`/`call_indirect`).
  (The adversarial **must-NOT** negatives — off-allowlist remote → `OffAllowlistRemote`, residual remote
  capture → refuse-to-emit, `erlang:apply` → `AmbientAuthorityFound` — are P11-03's fixtures; this
  confirms the built-in check also fires end-to-end.)
- `l2_bare_node_import_free_differential_test` — **L2.** subset × strategy × `{tier-P, tier-O}`: the
  child's value/trap equals the in-process oracle, on a node with no `twocore@`/`gleam@` reachable.
- `l2_bare_node_isolation_gate_fires_test` — asserts the harness's `code:which == non_existing` gate ran
  and reported clean for the representative closure set (the gate itself is proven to *fail* when a
  `twocore@` module is reachable by P11-05's `«BARE-NODE-HARNESS-PROVEN»` self-test — confirmed here).
- `l2_constant_space_sum_to_100000_bare_node_test` — `sum_to(100000)` on the bare node in bounded memory
  (`mem_big < mem_small * 4`) — the acceptance *Bare-node proof* "runs 100k iters in constant space".
- `cli_link_rejects_tier_n_and_import_bearing_test` — **fail-closed confirm (R13/R14).** `--link` + tier-N
  and `--link` + import-bearing exit non-zero with a typed error (P11-04 owns the primary CLI test).

## §6 Definition of Done

The per-phase capstone bar (`03-phase-workflow.md` §9):

1. Every §5 test written against the spec (bit-pattern values, spec trap phrases via `runner.trap_matches`)
   and against the R-decisions — no change-detector tests (no assertions over `.core`/`.beam` bytes except
   the deliberate R10 determinism byte-check and R11 structural export check).
2. Doc comments (`////` module, `///` per test/helper) stating the contract each proof upholds.
3. `gleam format --check src test` clean.
4. `gleam build` — zero warnings.
5. `linked_selfcontained_test` passes; the **whole prior suite** (~1827 baseline + prior units) stays
   `fail=0`; WASM conformance stays `46,529 / 1,768 / 0` (Safe ≡ Unsafe, every non-nif
   `state_strategy × mem_tier`). Report the running gleeunit total (confirm green, do not re-derive).
6. `docs/phase-11-linking.md` written (deployment story + R17 disambiguation); `01-status.md` §5/§3 and
   `state.md` updated; `specs/phase-11/` removed. **PHASE 11 PROVEN.**

## §7 What it leaves

- To the **repo/manager:** a green, self-contained `--link` proven on a bare OTP node; Phase 11 compacted
  into `01-status.md` §3; `state.md` reset to the template; `specs/phase-11/` removed. `PHASE 11 PROVEN`.
- To the **next phase:** `docs/phase-11-linking.md` as the reference; the deferred follow-ups move to
  `02-roadmap.md` — `.core`-input `--link` (R13, no binding present), import-bearing bare-node linking
  (R14, needs a provider-baking story), tier-N/NIF merge (O8), and multi-module link (overview §1).
