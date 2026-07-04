//// P11-02 — data-shape + adversarial-invariant tests for the link-closure manifest
//// (`src/twocore/backend/link_manifest.gleam`).
////
//// These are OBJECTIVE tests against the reconciled spec decisions (RECONCILIATION.md R1/R7/R8/R12/
//// R15), not change-detectors: each asserts a property the spec REQUIRES of the frozen data (the
//// allowlist is the measured floor, the acquisition order is R1, the mangle precondition holds, the
//// FFI bucket is exactly the reachable hand-FFI, surviving remotes ⊆ the allowlist). The companion
//// `link_manifest_drift_test` proves the frozen snapshots still match the CURRENT build.

import gleam/list
import gleam/set
import twocore/backend/link_manifest as m

/// Every atom string in `xs` is a member of `ys` (⊆).
fn subset_of(xs: List(String), ys: List(String)) -> Bool {
  list.all(xs, fn(x) { list.contains(ys, x) })
}

/// True iff `xs` has no duplicate members.
fn no_duplicates(xs: List(String)) -> Bool {
  list.length(xs) == set.size(set.from_list(xs))
}

// ---------------------------------------------------------------------------
// R7 — the OTP-ambient allowlist (the measured floor).
// ---------------------------------------------------------------------------

/// R7: `ambient_allowlist/0` contains every measured-floor atom the reconciliation cites, and has no
/// duplicates. The 15 are ERTS+kernel+stdlib modules present on every OTP install.
pub fn ambient_allowlist_is_measured_floor_test() {
  let expected = [
    "erlang", "lists", "maps", "binary", "math", "ets", "atomics", "unicode",
    "string", "io", "io_lib", "io_lib_format", "base64", "rand", "uri_string",
  ]
  let allow = m.ambient_allowlist()
  // Contains exactly the measured floor (⊆ both ways) and is duplicate-free.
  assert subset_of(expected, allow) == True
  assert subset_of(allow, expected) == True
  assert no_duplicates(allow) == True
  assert list.length(allow) == 15
}

/// R7: `is_ambient/1` is True only for allowlist members. Adversarial must-NOTs: an off-set OTP
/// module (`filelib`), a powerful-but-deliberately-excluded OTP module (`code`), and an in-closure
/// runtime module (`twocore@runtime@rt_num`) are all NOT ambient (fail-closed / in-closure ≠ ambient).
pub fn is_ambient_membership_test() {
  assert m.is_ambient("erlang") == True
  assert m.is_ambient("math") == True
  assert m.is_ambient("uri_string") == True
  // must-NOT:
  assert m.is_ambient("filelib") == False
  assert m.is_ambient("code") == False
  assert m.is_ambient("net_kernel") == False
  assert m.is_ambient("twocore@runtime@rt_num") == False
}

/// R7/R8: the module-granularity-only remotes `code`/`net_kernel`/`timer` (from `gleam_erlang_ffi`'s
/// unused process/node helpers) are deliberately NOT in the allowlist — no D3a-weakening widening for
/// `code`. They are documented as `dce_only_remotes/0` instead.
pub fn dce_only_remotes_are_not_ambient_test() {
  let dce = m.dce_only_remotes()
  assert dce == ["code", "net_kernel", "timer"]
  assert list.any(dce, m.is_ambient) == False
}

// ---------------------------------------------------------------------------
// R12 — mangle injectivity.
// ---------------------------------------------------------------------------

/// R12: the frozen closure (runtime ∪ gleam ∪ FFI) is mangle-injective — no member atom contains the
/// `__` separator, so `'M__F'/A` is collision-free.
pub fn mangle_injective_holds_for_frozen_closure_test() {
  assert m.mangle_separator == "__"
  assert m.mangle_injective(m.frozen_closure_modules()) == True
}

/// R12 (adversarial must-NOT): a module atom containing `__` breaks injectivity, so `mangle_injective`
/// must reject it — both a lone offender and one hidden among valid atoms.
pub fn mangle_injective_rejects_double_underscore_test() {
  assert m.mangle_injective(["a__b"]) == False
  assert m.mangle_injective(["gleam@x", "y__z"]) == False
}

// ---------------------------------------------------------------------------
// R1 — the Core-acquisition rule.
// ---------------------------------------------------------------------------

/// R1: the generated module uses `GeneratedCoreText`; every discovered in-closure module uses the
/// uniform `ResidentBeamCore` primary; the single fallback is `CompileFileToCore`.
pub fn acquisition_rule_test() {
  assert m.primary_acquisition(True) == m.GeneratedCoreText
  assert m.primary_acquisition(False) == m.ResidentBeamCore
  assert m.fallback_acquisition() == m.CompileFileToCore
}

// ---------------------------------------------------------------------------
// R8 — the FFI `.erl` bucket.
// ---------------------------------------------------------------------------

/// R8: `frozen_ffi_erl/0` is exactly the reachable hand-FFI — `gleam_stdlib` + the 5
/// `twocore_rt_*_ffi` shims + `gleam_erlang_ffi` (the reconciliation's `.erl` sketch omitted the
/// last; the real closure includes it via `rt_host` → `gleam@erlang@atom` → `gleam_erlang_ffi`).
/// Adversarial must-NOTs: the JS-only shim and the driver/compiler FFIs are NOT runtime FFI.
pub fn ffi_bucket_shape_test() {
  let ffi = m.frozen_ffi_erl()
  let expected = [
    "gleam_stdlib", "twocore_rt_exn_ffi", "twocore_rt_mem_atomics_ffi",
    "twocore_rt_ref_ffi", "twocore_rt_state_ffi", "twocore_rt_table_ets_ffi",
    "gleam_erlang_ffi",
  ]
  assert subset_of(expected, ffi) == True
  assert subset_of(ffi, expected) == True
  assert list.length(ffi) == 7
  // must-NOT: JS runtime FFI (off the WASM link path) and driver/compiler FFI.
  assert list.contains(ffi, "twocore_rt_js_ffi") == False
  assert list.contains(ffi, "twocore_cli_ffi") == False
  assert list.contains(ffi, "twocore_codegen_ffi") == False
}

// ---------------------------------------------------------------------------
// R7 — surviving remotes ⊆ the allowlist.
// ---------------------------------------------------------------------------

/// R7: the frozen post-DCE surviving-remote set is ⊆ `ambient_allowlist/0`; on this build it equals
/// the allowlist exactly (every allowlist member is genuinely used by the tier-P/O closure).
pub fn surviving_remotes_subset_of_ambient_test() {
  let remotes = m.frozen_surviving_remotes()
  let allow = m.ambient_allowlist()
  assert subset_of(remotes, allow) == True
  // exact equality (⊆ both ways): the measured floor is fully exercised.
  assert subset_of(allow, remotes) == True
  assert list.length(remotes) == 15
}

// ---------------------------------------------------------------------------
// Closure snapshot shape (R8/R15) — counts + adversarial exclusions.
// ---------------------------------------------------------------------------

/// The frozen closure snapshot has the expected shape: 16 runtime + 12 gleam + 7 FFI = 35 in-closure
/// modules, all duplicate-free, and the roots (15) are the runtime closure minus `porffor_abi` (the
/// only transitively-reached runtime member).
pub fn frozen_closure_shape_test() {
  assert list.length(m.frozen_runtime_closure()) == 16
  assert list.length(m.frozen_gleam_closure()) == 12
  assert list.length(m.frozen_ffi_erl()) == 7
  assert list.length(m.frozen_closure_modules()) == 35
  assert no_duplicates(m.frozen_closure_modules()) == True

  let roots = m.frozen_runtime_roots()
  assert list.length(roots) == 15
  assert subset_of(roots, m.frozen_runtime_closure()) == True
  // the sole non-root runtime member is porffor_abi (reached via rt_host).
  let extra =
    list.filter(m.frozen_runtime_closure(), fn(x) { !list.contains(roots, x) })
  assert extra == ["twocore@runtime@porffor_abi"]
}

/// Adversarial: the runtime closure EXCLUDES the modules that must never be merged into the WASM
/// `--link` artifact — the JS runtime (`rt_js`, JS-only), tier-N (`rt_mem_nif`), the build-time BIF
/// gate (`rt_bif`), and the build-time-only `instance`/`profiles`.
pub fn runtime_closure_excludes_offpath_modules_test() {
  let runtime = m.frozen_runtime_closure()
  assert list.contains(runtime, "twocore@runtime@rt_js") == False
  assert list.contains(runtime, "twocore@runtime@rt_mem_nif") == False
  assert list.contains(runtime, "twocore@runtime@rt_bif") == False
  assert list.contains(runtime, "twocore@runtime@instance") == False
  assert list.contains(runtime, "twocore@runtime@profiles") == False
}

// ---------------------------------------------------------------------------
// R15 — mergeability invariants as data.
// ---------------------------------------------------------------------------

/// R15: `mergeability_invariants/0` enumerates the complete forbidden-construct set (all 7 variants).
/// The drift test asserts NONE of these appears in the current build's closure.
pub fn mergeability_invariants_are_complete_test() {
  let invariants = m.mergeability_invariants()
  assert list.length(invariants) == 7
  assert list.contains(invariants, m.Nif) == True
  assert list.contains(invariants, m.OnLoad) == True
  assert list.contains(invariants, m.NamedOrPublicEts) == True
  assert list.contains(invariants, m.OtpApplication) == True
  assert list.contains(invariants, m.OtpSupervisor) == True
  assert list.contains(invariants, m.PersistentTerm) == True
  assert list.contains(invariants, m.GleamMainShim) == True
}
