//// Self-test for the `wat_fixture` adapter (unit P5-11 §E, H5) — an IN-SCOPE `.wast` script runs
//// end-to-end FROM our own WAT parser (`wat.parse_script`) through the harness `Driver`, proving the
//// parser-driven path is a faithful second frontend (not a fixture crutch). The `.wast` carries its
//// own baked-in expected values (Tier-A, spec-sourced), so a wrong result / missing trap goes red.
////
//// It exercises: a `(module …)` definition, `assert_return` (incl. i32 wrap + a memory store/load),
//// `assert_trap` (div-by-zero → spec phrase), a `(module quote …)` `assert_malformed` REJECTED at
//// parse, and `(register …)` + a `$name`-targeted invoke. The un-`wast2json`-able real suite files
//// (`memory.wast`/`table.wast`/`select.wast`) are genuinely out of scope for BOTH wabt and our
//// parser (GC reference types / `(module definition)` module-linking), so they stay categorised
//// skips (R16); this authored file is the in-scope proof the adapter itself is correct.

import carder/conformance/driver
import carder/conformance/wat_fixture

const script_path = "test/carder/conformance/corpus/wat_script.wast"

/// The authored in-scope `.wast` runs green through the parser-driven path: every `assert_return`/
/// `assert_trap` passes, the `(module quote)` malformed case is rejected (a pass), and NOTHING fails
/// or skips. Cite: the parser is a faithful frontend (H5) — validate/lower serve the WAT AST
/// unchanged, and the oracle judges the baked-in spec values.
pub fn wat_script_runs_from_parser_test() {
  let report = wat_fixture.run_wat_fixture(driver.pipeline(), script_path)
  // 6 assertions: 4 assert_return + 1 assert_trap + 1 assert_malformed(quote). All pass.
  assert report.fail == 0
  assert report.skip == 0
  assert report.pass == 6
}
