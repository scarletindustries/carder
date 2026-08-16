//// Unit P4-09 — PROOF 1: the whole-acceptance-corpus tier differential (§B, the G7 headline).
////
//// A DIFFERENTIAL test: it holds the *program* fixed and varies the `Binding` over EVERY shipped
//// `(state_strategy × mem_tier × table_tier)` combination, then asserts two load-bearing things
//// for every program point (no change-detector, D8):
////   1. **spec-correctness** — each combination's `Outcome` matches the spec-sourced `.expected`
////      (values via the NaN-aware `oracle`, traps via `runner.trap_matches`), sourced from the
////      vendored `.wast`/wasmtime through `corpus.parse` — defeats a "consistently wrong" tier.
////   2. **cross-combination identity** — the raw `Outcome`s are BYTE-IDENTICAL (bit pattern, D7)
////      across every combination — defeats a change-detector and catches any single tier bug
////      (an off-by-one atomics bound, a threaded store that drops the rebound record, a nif
////      endianness slip) as a divergence on the exact program+combo.
//// Identity alone could pass on a mutually-broken pair; `.expected` alone is the existing
//// acceptance test; together they are G7.
////
//// The comparison is NEVER over `.core` text or the linked module name (which the tier is
//// *allowed* to change) — only over spec-observable behaviour. Spec anchors are cited per program
//// inside each `corpus/*.expected` (numerics
//// <https://webassembly.github.io/spec/core/exec/numerics.html>, bounds/traps
//// <https://webassembly.github.io/spec/core/exec/instructions.html>).

import carder/harness/driver
import carder/harness/runner
import carder/tier/combos.{type Outcome}
import gleam/list

/// One combination's driver + its label, built once and reused across the whole corpus.
type Bound {
  Bound(label: String, driver: runner.Driver)
}

/// Build a driver for every shipped combination (D1: each `Binding` through `binding_for`).
fn bound_drivers() -> List(Bound) {
  list.map(combos.shipped, fn(c) {
    Bound(c.label, driver.pipeline_with(combos.binding_for(c)))
  })
}

/// Evaluate `name` under every combination: `#(label, outcomes, spec_failures)` per combo.
fn evaluate_all(name: String) -> List(#(String, List(Outcome), List(String))) {
  list.map(bound_drivers(), fn(b) {
    let #(outs, fails) = combos.evaluate(b.driver, name)
    #(b.label, outs, fails)
  })
}

/// The failures for ONE program: every combo's spec-correctness violations PLUS the
/// cross-combination identity violations (each combo's outcomes must equal the baseline's).
fn program_failures(name: String) -> List(String) {
  let runs = evaluate_all(name)
  list.flatten([
    list.flat_map(runs, fn(r) { r.2 }),
    combos.identity_across(name, list.map(runs, fn(r) { #(r.0, r.1) })),
  ])
}

// ─────────────────────────── PROOF 1 (G7): the whole corpus ───────────────────────────

/// PROOF 1 (G7). Drive the WHOLE acceptance corpus under EVERY shipped `Combo`; assert each point
/// (a) matches the spec `.expected` and (b) is byte-identical across all combinations. A single
/// tier bug changes an `Outcome` and turns this red on the exact program+combo. This is the
/// Phase-4 headline correctness bar: the trust-tier axis is proven correctness-neutral.
pub fn whole_corpus_tier_differential_test() {
  let failures = list.flat_map(combos.corpus_programs, program_failures)
  assert failures == []
}

// ─────────── focused rows (fast, self-pinpointing halves of PROOF 1) ───────────
// The whole-corpus test above is the gate; these split it by tier-sensitivity so a failure
// names the axis it exercises without reading the aggregate message.

/// The MEMORY programs (`mem`/`memgrow`/`oobdata`) exercise `rt_mem` load/store/grow/init-data, so
/// `paged ≡ atomics ≡ nif` across both calling conventions — the tier-O backend and the nif
/// skeleton must be byte-identical to the paged oracle (spec exec/instructions memory + modules).
pub fn memory_programs_agree_across_tiers_test() {
  let failures = list.flat_map(["mem", "memgrow", "oobdata"], program_failures)
  assert failures == []
}

/// The TABLE program (`callind`) exercises `rt_table` dispatch + the three ordered fail-closed
/// faults, so `TablePaged ≡ TableAtomics` across both calling conventions (spec exec/instructions
/// call_indirect).
pub fn table_program_agrees_across_tiers_test() {
  assert program_failures("callind") == []
}

/// The GLOBALS program (`gvar`) exercises mutable globals, so `Cell`'s pdict globals ≡ `Threaded`'s
/// record-threaded globals — the `state_strategy` axis on the global seam (spec exec/instructions
/// variable-instructions).
pub fn globals_program_agrees_across_strategies_test() {
  assert program_failures("gvar") == []
}

/// The PURE-numeric programs (`add`/`intops`/`fib`/`fac`/`floatops`/`trunc`/`sum_to`) carry no
/// handle operand (G5), so the threaded seam adds NO change to a pure function (keystone §A.3: a
/// pure function keeps its Phase-1 signature) — every tier is byte-identical here by construction.
pub fn pure_numeric_programs_tier_insensitive_test() {
  let pure = ["add", "intops", "fib", "fac", "floatops", "trunc", "sum_to"]
  let failures = list.flat_map(pure, program_failures)
  assert failures == []
}

/// The fail-closed / instantiation-trap programs (`hostimport` rejects, `trapstart`/`oobdata`
/// instantiation-trap) reach the SAME module-level `Outcome` under every combination — a rejection
/// is policy/tier-independent (it is a frontend property), and an instantiation trap surfaces the
/// same reason across tiers (D4/G6).
pub fn fail_closed_programs_agree_across_tiers_test() {
  let failures =
    list.flat_map(["hostimport", "trapstart", "oobdata"], program_failures)
  assert failures == []
}
