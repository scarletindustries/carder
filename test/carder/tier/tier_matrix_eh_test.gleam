//// Unit P7-10 — the CAPSTONE tier-matrix EH proof (Phase-7 proof 4). Exception handling is
//// BEAM-native control flow: a throw unwinds the process's NATIVE stack, not the `state_strategy`
//// record/cell or the `mem_tier` memory. So the EH surface is **tier-invariant by construction** —
//// it neither reads nor writes instance state — and every EH backstop program must produce a
//// BYTE-IDENTICAL `Outcome` under EVERY shipped `state_strategy × mem_tier` combination
//// (`combos.shipped`: cell/paged, threaded/paged, cell/atomics, threaded/atomics, cell/nif). A
//// divergence across combos would mean the lowering entangled EH with instance state (a bug the
//// pure control-flow model forbids).
////
//// This is the Phase-7 analogue of P6-10's `simd_differential_test` (SIMD across the tier matrix):
//// the tier axis for the deliberately-authored backstop, orthogonal to `new_surface_test`'s MODE
//// axis (safe/unsafe/portable) and to the official-`.wast` EH run (`eh_conformance_test`, which
//// departed with the WebAssembly frontend to `scribbler`). The EH programs
//// carry NO linear memory, so the `mem_tier` (paged/atomics/nif) is never even linked — the matrix
//// varies the `state_strategy` (cell/threaded) and the mode (Safe/Unsafe) while the throw unwinds
//// the native stack regardless. This is the empirical demonstration of the T6 nuance: the STATE-FREE
//// EH surface runs identically under Cell AND Threaded; the T6 "Cell-only" bound is retained only for
//// the state-threaded-THROUGH-a-throw combination (a program mutating threaded instance state across
//// a throw/catch), which the backstop deliberately does not exercise (scalar-observable, no global
//// mutation across a throw).
////
//// ## Why this file lives under `tier/` (the frontend split)
////
//// It was previously filed under the WebAssembly conformance tree, but it is not a spec-suite test:
//// it reads no `.wast` fixture and judges no script command. It asserts that the EH backstop's
//// spec-observable `combos.Outcome` is BYTE-IDENTICAL across `combos.shipped` — a TIER claim, which
//// is what `tier/` owns. The conformance suite left with the WebAssembly frontend (to the
//// `scribbler` repo), taking the official-`.wast` EH run (`eh_conformance_test`) with it; this
//// tier-matrix proof stayed, because the `state_strategy × mem_tier` lattice it varies is carder's.
//// Its corpus input is now `.ir` SOURCE TEXT (`combos.corpus_dir`), driven through the same
//// `combos.evaluate` every other tier proof uses.
////
//// Spec anchor: the WebAssembly exception-handling proposal (throw/try_table/catch/throw_ref); the
//// tier model of Phase 4 (`state_strategy × mem_tier`). Every `.expected` value is spec-sourced
//// (differential vs wasmtime 46.0.1 for the modern programs; the official `legacy/throw.wast`
//// validates the legacy `ehthrow`), so "identical" means every spec-observable was preserved under
//// every tier, never "it compiled".

import carder/harness/driver
import carder/tier/combos.{type Combo}
import gleam/list

/// The capstone-authored EH backstop programs (both encodings, scalar-observable) — the same set
/// `new_surface_test` drives across the MODE axis; here they cross the TIER axis.
const eh_programs: List(String) = [
  "ehthrow", "ehcatch", "ehcatchall", "ehnested", "ehrethrow",
]

/// PROOF 4 (EH green under the tier matrix). Every EH program is (1) spec-correct against its
/// `.expected` under each shipped combo and (2) BYTE-IDENTICAL across all five combos
/// (`combos.shipped`). A per-combo spec violation (a wrong catch, a lost payload) OR a cross-combo
/// divergence (the lowering entangled EH with the `state_strategy` record/cell — a real bug) fails
/// naming the exact program. EH is tier-invariant because a throw unwinds the native BEAM stack, so
/// this expects byte-identity across EVERY combo, like the pure-numeric files — not a per-tier caveat.
pub fn eh_backstop_byte_identical_across_tier_matrix_test() {
  let failures = list.flat_map(eh_programs, check_across_combos)
  assert failures == []
}

/// Drive `name` under every shipped `Combo`, collecting per-combo spec-correctness failures and
/// cross-combo byte-identity failures (baseline = the first combo). Empty ⇒ green. Each combo's
/// coherent binding comes from `combos.binding_for` (never re-spelling a tier module name).
fn check_across_combos(name: String) -> List(String) {
  let runs =
    list.map(combos.shipped, fn(c: Combo) {
      let binding = combos.binding_for(c)
      let #(outcomes, fails) =
        combos.evaluate(driver.pipeline_with(binding), name)
      #(c.label, outcomes, fails)
    })
  let spec_failures = list.flat_map(runs, fn(r) { r.2 })
  let identity_runs = list.map(runs, fn(r) { #(r.0, r.1) })
  list.append(spec_failures, combos.identity_across(name, identity_runs))
}
