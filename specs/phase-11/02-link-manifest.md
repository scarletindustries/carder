# Phase 11 · P11-02 — Link-closure manifest + allowlist + acquisition + invariants

> **Status:** spec, unclaimed · **Owner:** one agent · **Produces freeze:** `«CLOSURE-FROZEN»` ·
> **Depends on:** `«RT-LAYER-FROZEN»` (P11-01). Changes **no behavior** — inert data + tests only.
> Read order: `00-overview.md` → `RECONCILIATION.md` (authoritative) → this doc.

## §1 Goal

Deliver `src/twocore/backend/link_manifest.gleam`: the **inert reference data** the whole-program
linker (P11-03) builds against, plus the tests that keep it honest. It is *not* the closure discovery
engine — **the linker DISCOVERS the closure by reachability** (R6). The manifest supplies the three
things reachability cannot compute for itself:

1. the **OTP-ambient stop-set** — the fixed set of modules DCE walks *up to but not into* (R7);
2. the **frozen Core-acquisition rule** — how a closure member's `#c_module{}` is obtained (R1);
3. the **invariants as checkable data** — mangle-injectivity (R12), the FFI `.erl` bucket derivation
   (R8), and the mergeability invariants + a **drift test** that recomputes the transitive closure and
   surviving-remote set from the *current* build and diffs it against the frozen snapshot (R15/R12).

Decisions implemented: **R1** (freeze acquisition), **R7** (mechanically-derived, fail-closed OTP
allowlist), **R8** (FFI `.erl` bucket incl. `gleam_stdlib.erl`), **R12** (no in-closure atom contains
`__`), **R15** (mergeability invariants + drift guard). It also carries the enumerated closure snapshot
the overview §O1 called the "link-closure manifest."

## §2 Depends on / Produces

- **Consumes** `«RT-LAYER-FROZEN»` — P11-01 has moved `OptLevel` out of `middle/ir_opt` into the leaf
  `src/twocore/opt_level.gleam`, so the runtime closure provably reaches zero compiler modules. The
  manifest's frozen closure lists (§3) assume that clean boundary.
- **Produces** `«CLOSURE-FROZEN»` — the ambient allowlist, the acquisition rule, the mangle/mergeability
  invariants, and the closure/surviving-remote snapshots, all as compiled Gleam data with a green
  drift+invariant suite. P11-03 (linker) and P11-06 (capstone) build against these names.

## §3 What it owns + design

**Owns (creates, D1):**
- `src/twocore/backend/link_manifest.gleam` — the data module (a stdlib-only leaf: imports at most
  `gleam/list`, `gleam/string`, `gleam/set`; **no** project imports, so it never re-inverts the layer).
- `test/twocore/backend/link_manifest_test.gleam` — data-shape + invariant unit tests.
- `test/twocore/backend/link_manifest_drift_test.gleam` — the R15 drift/mergeability guard (uses a tiny
  read-only beam-introspection FFI; see §5).

Touches nothing else (no behavior change; the linker imports this module in P11-03).

### The ambient allowlist (R7)

The **fixed** ERTS+kernel+stdlib set present on every OTP install. Measured floor (grounded in the
merged `gleam_stdlib` surviving remotes):

```gleam
/// The FIXED OTP-ambient module set, as atom strings — the DCE stop-set (R7). A remote call whose
/// target module is in this set is left as a remote `#c_call`; the linker DCEs the walk here rather
/// than pulling the OTP module into the merge. Any surviving remote target that is neither in-closure
/// nor in this set is a fail-closed `LinkError` (never a runtime `undef`). This set is a CEILING, not a
/// floor: some members (`base64`, `rand`, `uri_string`, …) frequently DCE away. Widening it reactively
/// to make a program link is itself a D3a hole — do not.
pub fn ambient_allowlist() -> List(String)
// = ["erlang","lists","maps","binary","math","ets","atomics","unicode",
//    "string","io","io_lib","io_lib_format","base64","rand","uri_string"]

/// True iff `module_atom` is in `ambient_allowlist()`. Used by the linker's fail-closed remote check
/// and the D3a structural self-check (R9). `is_ambient("erlang")` is True; it does NOT sanction
/// `erlang:apply` — that is rejected structurally by the linker regardless (R9).
pub fn is_ambient(module_atom: String) -> Bool
```

Grounding: the runtime's direct OTP `@external` targets are `erlang` (10×: `rt_state.gleam:64`
`erlang:put`, `rt_trap.gleam:36` `erlang:error`, `rt_meter.gleam:84/90`, `porffor_abi.gleam:162`
`erlang:float_to_binary`, …) and `math` (`rt_num.gleam:1253` `math:sqrt`); the remaining allowlist
members (`lists`/`maps`/`string`/`io`/`io_lib`/`io_lib_format`/`base64`/`unicode`/`rand`/`uri_string`/
`binary`/`ets`/`atomics`) enter as surviving remotes of the merged `gleam_stdlib`/`gleam@*` closure.
`classify_dynamic` is a **local** function of `gleam_stdlib.erl` (`gleam_stdlib.erl:52`), not a
`dynamic:classify` remote — R7's open question is resolved: there is no such ambient target.

### The Core-acquisition rule (R1) — frozen here

```gleam
/// How a closure member's Core (`#c_module{}`) is acquired. Frozen order (R1).
pub type Acquisition {
  /// The GENERATED (wasm-derived) module ONLY: its `.core` TEXT via core_scan/core_parse
  /// (the existing twocore_codegen_ffi path).
  GeneratedCoreText
  /// UNIFORM primary for every DISCOVERED in-closure module: beam_lib:chunks(Beam,[debug_info])
  /// then Backend:debug_info(core_v1, Mod, Data, []) from the module's RESIDENT .beam — needs no
  /// .erl on disk.
  ResidentBeamCore
  /// FALLBACK only, when a resident .beam carries no core_v1 debug_info chunk:
  /// compile:file(F,[to_core]) on the .erl source.
  CompileFileToCore
}

/// Primary acquisition for a member. `is_generated` ⇒ GeneratedCoreText; otherwise ResidentBeamCore.
pub fn primary_acquisition(is_generated: Bool) -> Acquisition

/// The single fallback (CompileFileToCore) the linker uses iff ResidentBeamCore yields no core_v1.
pub fn fallback_acquisition() -> Acquisition
```

Verified on OTP 29.0.2 (this build): `beam_lib:chunks(Beam,[debug_info])` →
`Backend:debug_info(core_v1, Mod, Data, [])` returns a `#c_module{}` for `twocore@runtime@rt_num`,
`gleam@int`, `gleam@erlang@atom`, **and** the hand-written FFI beams `gleam_stdlib`,
`twocore_rt_exn_ffi`, `twocore_rt_ref_ffi`. So the uniform `ResidentBeamCore` path covers the `.erl`
bucket too — `CompileFileToCore` is genuinely just a safety fallback. The FFI shim lives in P11-03
(`src/twocore_linker_ffi.erl`, same OTP-internals trust boundary as `src/twocore_codegen_ffi.erl`); the
manifest only *names the rule* so acquisition is single-sourced.

### The mangle-injectivity invariant (R12)

```gleam
/// The mangling separator. `'M__F'/A` is injective ONLY because no in-closure module atom contains
/// this separator. The rewrite/mangle itself is owned by the linker (P11-03); this manifest owns the
/// PRECONDITION that makes it sound.
pub const mangle_separator: String = "__"

/// True iff mangling `M__F` over `closure_modules` is injective — i.e. NO member atom contains
/// `mangle_separator` (R12). The linker asserts this at freeze and FAILS CLOSED
/// (LinkError.MangleCollision) if a future module violates it.
pub fn mangle_injective(closure_modules: List(String)) -> Bool
```

Grounding: every in-closure atom uses `@`/single `_` — verified `__`-free across all
`build/dev/erlang/twocore/ebin/twocore@*` and `.../gleam_stdlib/ebin/gleam@*` beams and the FFI shim
atoms (`gleam_stdlib`, `twocore_rt_exn_ffi`, `twocore_rt_mem_atomics_ffi`, `twocore_rt_ref_ffi`,
`twocore_rt_state_ffi`, `twocore_rt_table_ets_ffi`).

### The closure snapshot + the `.erl` bucket (R8) — frozen for the drift diff

These are **snapshots the drift test diffs against**, not the linker's source of truth.

```gleam
/// The tier-P/O twocore@runtime@* modules in the closure (frozen snapshot).
pub fn frozen_runtime_closure() -> List(String)
/// The reachable gleam@* modules (frozen snapshot). tier-N modules (rt_mem_nif) are EXCLUDED.
pub fn frozen_gleam_closure() -> List(String)
/// The hand-written FFI .erl bucket — DERIVED from actual @external targets in reachable Gleam
/// modules, NOT hand-typed (R8): gleam_stdlib + the 5 twocore_rt_*_ffi shims.
pub fn frozen_ffi_erl() -> List(String)
// = ["gleam_stdlib","twocore_rt_exn_ffi","twocore_rt_mem_atomics_ffi",
//    "twocore_rt_ref_ffi","twocore_rt_state_ffi","twocore_rt_table_ets_ffi"]
/// The surviving remote-call target set after DCE (frozen snapshot) — MUST be ⊆ ambient_allowlist().
pub fn frozen_surviving_remotes() -> List(String)
```

Grounding for `frozen_ffi_erl`: the runtime's non-OTP `@external` targets are exactly `gleam_stdlib`
(32× — e.g. `gleam_stdlib:identity` in `rt_mem.gleam:126`, `rt_ref.gleam:32`, `rt_host.gleam:85`, used
~31× for D5 bit-identity coercions) plus the 5 `twocore_rt_*_ffi` shims (`rt_exn.gleam:61-85`,
`rt_mem_atomics.gleam:102-110`, `rt_ref.gleam:36-54`, `rt_state.gleam:78`, `rt_table_ets.gleam:74-90`).
`twocore_cli_ffi`/`twocore_codegen_ffi` are driver/compiler FFI (from `pipeline.gleam`/`build_beam.gleam`,
**not** runtime) — correctly outside the bucket.

### The mergeability invariants (R15)

```gleam
/// A construct that MUST be absent from every closure member for the merge to be sound (R15).
pub type Unmergeable {
  Nif OnLoad NamedOrPublicEts OtpApplication OtpSupervisor PersistentTerm GleamMainShim
}
/// The frozen forbidden set — the drift/structural test asserts none appears in the closure.
pub fn mergeability_invariants() -> List(Unmergeable)
```

## §4 The work (ordered, buildable)

1. Read `RECONCILIATION.md` R1/R7/R8/R12/R15 and P11-01's `«RT-LAYER-FROZEN»` note in `state.md`
   (confirm `opt_level.gleam` exists and the runtime reaches zero compiler modules).
2. Write `link_manifest.gleam` with the types/functions above; keep it a stdlib-only leaf. Module doc
   `////` states the ROLE (stop-set + acquisition rule + invariants; the linker discovers the closure).
3. Populate `ambient_allowlist()` with the R7 measured floor (exact 15 atoms above), `is_ambient`
   in terms of it.
4. Populate the four `frozen_*` snapshot functions from the current build: enumerate
   `build/dev/erlang/twocore/ebin/twocore@runtime@*.beam` (tier-P/O only — exclude `rt_mem_nif`),
   the reachable `gleam@*` set, the `frozen_ffi_erl` bucket, and the surviving-remote set (compute once
   via the §5 introspection helper, paste the result, and let the drift test keep it honest).
5. Add `Acquisition`, `primary_acquisition/1`, `fallback_acquisition/0`; `mangle_separator`,
   `mangle_injective/1`; `Unmergeable`, `mergeability_invariants/0`.
6. Write the two test modules (§5). `gleam format`, `gleam build` (zero warnings), `gleam test`.
7. Announce `«CLOSURE-FROZEN»` in `state.md` with the snapshot counts.

## §5 Tests

**`link_manifest_test.gleam`** (spec-cited data shape + adversarial invariants):
- `ambient_allowlist_is_measured_floor_test` — the returned list contains every R7-cited atom
  (`erlang`,`lists`,`maps`,`binary`,`math`,`ets`,`atomics`,`unicode`,`string`,`io`,`io_lib`,
  `io_lib_format`,`base64`,`rand`,`uri_string`), no duplicates.
- `is_ambient_membership_test` — `is_ambient("erlang")` True; **must-NOT:** `is_ambient("filelib")`,
  `is_ambient("code")`, `is_ambient("twocore@runtime@rt_num")` all False (off-set / in-closure ≠ ambient).
- `mangle_injective_holds_for_frozen_closure_test` — `mangle_injective(closure ∪ ffi)` is True.
- `mangle_injective_rejects_double_underscore_test` (**must-NOT**, R12) — `mangle_injective(["a__b"])`
  and `mangle_injective(["gleam@x", "y__z"])` are False; `mangle_separator == "__"`.
- `acquisition_rule_test` — `primary_acquisition(True) == GeneratedCoreText`,
  `primary_acquisition(False) == ResidentBeamCore`, `fallback_acquisition() == CompileFileToCore`.
- `ffi_bucket_shape_test` — `frozen_ffi_erl()` is exactly `gleam_stdlib` + the 5 `twocore_rt_*_ffi`;
  **must-NOT** contain `twocore_cli_ffi`/`twocore_codegen_ffi` (driver FFI, not runtime).
- `surviving_remotes_subset_of_ambient_test` — `frozen_surviving_remotes()` ⊆ `ambient_allowlist()`.

**`link_manifest_drift_test.gleam`** (R15 drift + mergeability — the guard that fails on surprise deps):
- `closure_drift_test` — recompute the transitive closure from the runtime roots by walking each
  resident `.beam`'s external-call imports (`beam_lib:chunks(Beam,[imports])`, or `xref`), starting at
  the frozen runtime roots, stopping at `ambient_allowlist()`; assert the computed
  `{runtime, gleam, ffi}` module sets equal the `frozen_*` snapshots. A new `import`/`@external` breaks
  **this** test, not the capstone.
- `surviving_remotes_drift_test` — recompute the surviving-remote target set (external MFA modules not
  in-closure) and assert it equals `frozen_surviving_remotes()` **and** ⊆ `ambient_allowlist()`
  (fail-closed on any off-set surprise remote).
- `no_double_underscore_in_build_test` (R12) — recompute in-closure atoms from the build and assert
  `mangle_injective` over them.
- `mergeability_absence_test` (R15) — assert no closure `.beam` declares `-on_load` / a NIF loader /
  an OTP `application`/`supervisor` behaviour / `persistent_term` usage / a `gleam@@main` shim, over
  the resident beams. **must-NOT (adversarial):** assert `gleam@erlang@application` ∉ the computed
  closure (it ships in the `gleam_erlang` package's ebin but must never be reachable) and
  `twocore@runtime@rt_mem_nif` ∉ the closure (tier-N excluded).

The drift test's beam-introspection uses a small read-only FFI over `beam_lib`/`xref` (verified this
build: `beam_lib:chunks(F,[debug_info|imports])` works for every runtime/gleam/ffi beam). It mirrors the
STRUCTURAL discipline of `test/twocore/backend/emit_core_security_test.gleam` (walk facts, assert a
property — never string-grep).

## §6 Definition of Done (§9, made concrete)

- `link_manifest.gleam` public functions/types carry `///` contracts (what / params-meaning /
  `Ok`/`Error` or enum semantics / failure modes); module has a `////` role paragraph. **§9.2**
- Every acceptance-relevant datum tied to a test: ambient set (R7) → `ambient_allowlist_*` +
  `surviving_remotes_*`; acquisition (R1) → `acquisition_rule_test`; `.erl` bucket (R8) →
  `ffi_bucket_shape_test`; mangle (R12) → the two `mangle_injective` cases + `no_double_underscore_*`;
  mergeability + drift (R15) → the drift test module. **§9.1**
- `gleam format --check src test` clean; `gleam build` **zero** warnings. **§9.3/§9.4**
- The two test modules pass; running total reported. **§9.5**
- Default output byte-identical (the manifest is imported by nothing yet ⇒ no emission change).
- `«CLOSURE-FROZEN»` announced in `state.md`.

## §7 What it leaves (handoff)

- **→ P11-03 (linker):** imports `link_manifest` for `ambient_allowlist()`/`is_ambient/1` (the DCE
  stop-set + fail-closed `OffAllowlistRemote` check and the R9 D3a self-check), `primary_acquisition`/
  `fallback_acquisition` (the frozen R1 order its `twocore_linker_ffi.erl` implements),
  `mangle_separator`/`mangle_injective` (the `MangleCollision` precondition). The linker still
  **discovers** the closure by reachability — the manifest is stop-set + rule + invariant, not the graph.
- **→ P11-06 (capstone):** the drift test is the standing guard that a future runtime change (new
  `import`/`@external`) surfaces here, not in the phase-closing differential; the `mergeability_invariants`
  + `frozen_*` snapshots are the reference the capstone's D3a/self-contained assertions cite.
