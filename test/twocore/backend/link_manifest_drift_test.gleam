//// P11-02 — the R15 DRIFT + mergeability guard for the link-closure manifest.
////
//// This is the load-bearing test that keeps `link_manifest.gleam`'s frozen snapshots HONEST. It does
//// NOT restate the frozen lists — it RECOMPUTES the runtime link closure + surviving-remote set from
//// the CURRENT build's shipped `.beam` files (a read-only `beam_lib` `imports` walk from the frozen
//// runtime roots, R4-complete because the `imports` chunk records `fun M:F/A` captures too) and diffs
//// the result against the manifest. A future runtime change — a new `import`, a new `@external`, a new
//// remote call target, or a newly-reachable unmergeable construct — therefore fails HERE, not in the
//// phase-closing capstone (P11-06).
////
//// The introspection FFI (`test/twocore_link_manifest_drift_ffi.erl`) is read-only: it reads
//// `imports`/`attributes` chunks, spawns nothing, loads no code. It mirrors the STRUCTURAL discipline
//// of `emit_core_security_test` (compute facts from the artifact, assert a property).

import gleam/list
import gleam/set
import gleam/string
import twocore/backend/link_manifest as m

/// Recompute the runtime link closure from `roots` over the current build.
/// Returns `#(runtime, gleam, ffi, remotes)` — four sorted lists of module-atom strings: the
/// in-closure `twocore@runtime@*`, in-closure `gleam@*`, in-closure hand-FFI `.erl`, and the
/// surviving remote (OTP-ambient) targets (module granularity).
@external(erlang, "twocore_link_manifest_drift_ffi", "closure")
fn recompute_closure(
  roots: List(String),
) -> #(List(String), List(String), List(String), List(String))

/// Recompute the R15 mergeability violations across `closure_modules`.
/// Returns `#(on_load, behaviour, persistent_term, nif, double_at)` — for each forbidden construct,
/// the sorted list of offending module strings (all-empty ⇒ the closure is mergeable).
@external(erlang, "twocore_link_manifest_drift_ffi", "mergeability_violations")
fn recompute_mergeability(
  closure_modules: List(String),
) -> #(List(String), List(String), List(String), List(String), List(String))

/// Sort ascending (so recomputed and frozen lists compare by value).
fn sorted(xs: List(String)) -> List(String) {
  list.sort(xs, string.compare)
}

/// Set difference `xs − ys`, sorted.
fn difference(xs: List(String), ys: List(String)) -> List(String) {
  set.difference(set.from_list(xs), set.from_list(ys))
  |> set.to_list
  |> sorted
}

/// Every member of `xs` is in `ys`.
fn subset_of(xs: List(String), ys: List(String)) -> Bool {
  list.all(xs, fn(x) { list.contains(ys, x) })
}

// ---------------------------------------------------------------------------
// R15 — closure drift: the recomputed module sets equal the frozen snapshots.
// ---------------------------------------------------------------------------

/// R15: recomputing the transitive closure from `frozen_runtime_roots/0` over the CURRENT build
/// reproduces the frozen `{runtime, gleam, ffi}` module sets EXACTLY. A new `import`/`@external` that
/// pulls a fresh module (or drops porffor_abi) makes a recomputed set diverge and fails here.
pub fn closure_drift_test() {
  let #(runtime, gleam, ffi, _remotes) =
    recompute_closure(m.frozen_runtime_roots())
  assert runtime == m.frozen_runtime_closure()
  assert gleam == m.frozen_gleam_closure()
  assert ffi == m.frozen_ffi_erl()
}

/// R7/R15: recomputing the surviving-remote set (module granularity) reproduces the frozen post-DCE
/// floor plus exactly the documented `dce_only_remotes/0`, and the post-DCE floor is ⊆ the allowlist.
/// A NEW remote target (a new `@external`/call to a non-closure OTP module) appears in the recomputed
/// ceiling, is neither in `frozen_surviving_remotes/0` nor `dce_only_remotes/0`, and fails here —
/// fail-closed, at manifest-drift time rather than as a bare-node `undef`.
pub fn surviving_remotes_drift_test() {
  let #(_runtime, _gleam, _ffi, remotes) =
    recompute_closure(m.frozen_runtime_roots())
  // The module-level ceiling = the post-DCE floor ∪ the DCE-only kernel modules.
  let ceiling =
    sorted(list.flatten([m.frozen_surviving_remotes(), m.dce_only_remotes()]))
  assert remotes == ceiling
  // Removing the DCE-only over-approximation yields exactly the frozen post-DCE floor…
  assert difference(remotes, m.dce_only_remotes())
    == m.frozen_surviving_remotes()
  // …which is ⊆ the allowlist (fail-closed: nothing off the fixed OTP set survives).
  assert subset_of(m.frozen_surviving_remotes(), m.ambient_allowlist()) == True
  // Every recomputed remote is a known OTP module (allowlist ∪ DCE-only) — no surprise remote.
  let known = list.flatten([m.ambient_allowlist(), m.dce_only_remotes()])
  assert subset_of(remotes, known) == True
}

// ---------------------------------------------------------------------------
// R12 — the `__`-free precondition holds over the recomputed closure.
// ---------------------------------------------------------------------------

/// R12: recompute the in-closure atoms from the build and assert `mangle_injective` over them — a
/// future closure member whose atom contains `__` breaks the injective `'M__F'/A` scheme and fails
/// here.
pub fn no_double_underscore_in_build_test() {
  let #(runtime, gleam, ffi, _remotes) =
    recompute_closure(m.frozen_runtime_roots())
  let closure = list.flatten([runtime, gleam, ffi])
  assert m.mangle_injective(closure) == True
}

// ---------------------------------------------------------------------------
// R15 — mergeability: no forbidden construct is reachable in the current build.
// ---------------------------------------------------------------------------

/// R15: no closure `.beam` declares an `-on_load`, an OTP `behaviour` (application/supervisor), a
/// `persistent_term` use, a NIF loader (`erlang:load_nif`), or is a `gleam@@*` shim — so the merge
/// stays sound. Recomputed over the CURRENT closure, not the frozen list, so a newly-reachable
/// unmergeable construct fails here.
pub fn mergeability_absence_test() {
  let #(runtime, gleam, ffi, _remotes) =
    recompute_closure(m.frozen_runtime_roots())
  let closure = list.flatten([runtime, gleam, ffi])
  let #(on_load, behaviour, persistent_term, nif, double_at) =
    recompute_mergeability(closure)
  assert on_load == []
  assert behaviour == []
  assert persistent_term == []
  assert nif == []
  assert double_at == []
}

/// R15 (adversarial must-NOTs): the computed closure never reaches `gleam@erlang@application` (it
/// ships in the `gleam_erlang` package's ebin but must never be reachable) nor the tier-N
/// `twocore@runtime@rt_mem_nif`. Proven against the RECOMPUTED closure, so a future edge that pulls
/// either one in fails here.
pub fn adversarial_exclusions_drift_test() {
  let #(runtime, gleam, ffi, _remotes) =
    recompute_closure(m.frozen_runtime_roots())
  let closure = list.flatten([runtime, gleam, ffi])
  assert list.contains(closure, "gleam@erlang@application") == False
  assert list.contains(closure, "twocore@runtime@rt_mem_nif") == False
  assert list.contains(closure, "twocore@runtime@rt_js") == False
}
