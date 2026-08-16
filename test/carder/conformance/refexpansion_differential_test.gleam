//// The new-surface tier differential (unit P5-11 §H) — the reference-types / bulk-memory /
//// multi-memory acceptance programs run under EVERY shipped `(state_strategy × mem_tier)`
//// combination, asserting (a) each program is spec-correct against its `.expected` under every
//// combo, and (b) its outcomes are BYTE-IDENTICAL across all combos (H7 — a varied tier axis
//// changes no observable). Reuses the P4-09 `combos.binding_for` / `combos.evaluate` /
//// `combos.identity_across` machinery UNCHANGED (this unit consumes the public surface; it does not
//// add these programs to `combos.corpus_programs`, which is P4-09's const — §H seam note).
////
//// The load-bearing spec corners (H2/H6): reftab's null-slot `call_indirect` → `uninitialized
//// element` and an OOB `table.get` → `out of bounds table access`; bulkmem's eager-bounds trap with
//// NO partial write and memmove-correct overlap, plus a dropped passive segment behaving as
//// length-0; multimem's independent regions + a `memory.copy` ACROSS memories. A tier that did a
//// naïve forward copy, wrote before checking bounds, mis-endianned an atomics store, or dropped a
//// threaded record across a table op diverges HERE on the exact program. Every `.expected` value is
//// spec-sourced (Tier-A), so "green" means every spec-observable was preserved, never "it compiled".

import carder/conformance/driver
import carder/tier/combos
import gleam/list

/// The three new-surface programs (authored `.wat` → `.wasm`, `.expected` spec-sourced). Each uses
/// i32-observable results (null-ness / call results / loaded bytes) so the numeric `.expected`
/// format applies while still exercising the full reference/bulk/multi-memory op surface.
const programs: List(String) = ["reftab", "bulkmem", "multimem"]

/// Each new-surface program is spec-correct under EVERY shipped combo AND byte-identical across
/// them. A per-combo spec violation (a wrong result / missing trap) OR a cross-combo divergence
/// (a tier changed an observable) fails with the exact program + combo named.
pub fn refexpansion_tier_differential_test() {
  let failures = list.flat_map(programs, check_program)
  assert failures == []
}

/// Drive `name` under every `combos.shipped` combination, collecting (1) the per-combo spec-
/// correctness failures and (2) the cross-combo byte-identity failures. Empty ⇒ green.
fn check_program(name: String) -> List(String) {
  let runs =
    list.map(combos.shipped, fn(c) {
      let d = driver.pipeline_with(combos.binding_for(c))
      let #(outcomes, fails) = combos.evaluate(d, name)
      #(c.label, outcomes, fails)
    })
  // (1) spec-correctness under each combo.
  let spec_failures = list.flat_map(runs, fn(r) { r.2 })
  // (2) byte-identity across combos (baseline = the first combo).
  let identity_runs = list.map(runs, fn(r) { #(r.0, r.1) })
  let identity_failures = combos.identity_across(name, identity_runs)
  list.append(spec_failures, identity_failures)
}
