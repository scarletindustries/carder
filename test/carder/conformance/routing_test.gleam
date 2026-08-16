//// Self-tests for the runner's command-type PARTITION (run NOW — no compiler needed).
////
//// The partition fact (VERIFIED): `assert_invalid`/`assert_malformed` exercise the
//// FRONTEND only (`check_frontend`) and must NEVER be `instantiate`-d; `assert_return`/
//// `assert_trap` exercise the full pipeline (`instantiate`+`invoke`). Proven with a spy
//// `Driver` whose `instantiate` sets a flag — the test asserts the flag is untouched
//// for a frontend-only command and set for a full-pipeline command.

import carder/conformance/driver
import carder/conformance/ffi
import carder/conformance/fixture.{
  AssertInvalid, AssertReturn, BinaryModule, Fixture, I32Val, Invoke, ModuleCmd,
}
import carder/conformance/runner
import gleam/option.{None}

const corpus_dir = "test/carder/conformance/corpus"

// A spy driver: `check_frontend`/`check_frontend_ast` reject (so a frontend-only assert
// "passes" by rejection), and every INSTANTIATE path records that it was reached then fails
// (`ModuleCmd` now routes through `instantiate_env`). `invoke`/`get_global` are never reached.
fn spy_driver() -> runner.Driver {
  let spy_instantiate = fn() {
    ffi.spy_mark()
    Error("spy: instantiate must not run for invalid/malformed")
  }
  runner.Driver(
    check_frontend: fn(_bytes) { Error("spy: rejected by frontend") },
    instantiate: fn(_bytes) { spy_instantiate() },
    invoke: fn(_inst, _field, _args) { runner.DriverError("spy: no invoke") },
    instantiate_env: fn(_bytes, _env) { spy_instantiate() },
    instantiate_ast: fn(_m, _env) { spy_instantiate() },
    check_frontend_ast: fn(_m) { Error("spy: rejected by frontend") },
    get_global: fn(_inst, _field) { runner.DriverError("spy: no get_global") },
  )
}

/// `assert_invalid` routes to `check_frontend` ONLY: it passes by rejection and the
/// spy's `instantiate` is never reached.
pub fn assert_invalid_is_frontend_only_test() {
  ffi.spy_reset()
  // The referenced file must exist so the runner can read it; its content is
  // irrelevant here (the spy `check_frontend` rejects regardless).
  let fix =
    Fixture("routing", [
      AssertInvalid(4, "add.wasm", BinaryModule, "type mismatch"),
    ])
  let report = runner.run_fixture(spy_driver(), fix, corpus_dir)

  assert report.pass == 1
  assert report.fail == 0
  // The crux: instantiate was NOT called for a frontend-only command.
  assert ffi.spy_called() == False
}

/// `assert_return` DOES route through `instantiate` (the module load) — proving the
/// other half of the partition: full-pipeline commands reach the backend.
pub fn assert_return_uses_instantiate_test() {
  ffi.spy_reset()
  let fix =
    Fixture("routing", [
      ModuleCmd(1, None, "add.wasm"),
      AssertReturn(2, Invoke("add", [I32Val(2), I32Val(3)], None), [I32Val(5)]),
    ])
  let report = runner.run_fixture(spy_driver(), fix, corpus_dir)

  // The spy fails instantiation, so the assertion SKIPS (module didn't load) — not a
  // fail — but instantiate WAS reached.
  assert ffi.spy_called() == True
  assert report.skip == 1
  assert report.fail == 0
}

/// The default `stub` driver makes a frontend-only assertion pass by rejection while
/// `invoke`/`instantiate` stay unimplemented — the temporal seam unit 11 swaps.
pub fn stub_driver_partition_test() {
  let fix =
    Fixture("routing", [
      AssertInvalid(4, "add.wasm", BinaryModule, "type mismatch"),
    ])
  let report = runner.run_fixture(driver.stub(), fix, corpus_dir)
  assert report.pass == 1
  assert report.fail == 0
}
