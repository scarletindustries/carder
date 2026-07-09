//// PROOF: run a real TeaVM WASM GC module — a Java program (`demo.Client.compute()`: allocate
//// objects behind an interface + dispatch virtually → 46) — end-to-end on the BEAM through 2core,
//// with the TeaVM host runtime provided by `rt_teavm`.
////
//// The committed fixture `test/twocore/teavm/compute.wasm` is TeaVM 0.15.0's WASM GC output for
//// `test/twocore/teavm/Client.java` (see that file to rebuild). It imports the TeaVM host runtime
//// (`teavmJso`/`wasm:js-string`/`teavmMemory`/`teavmDate`/`teavm` + a linear `memory` and two
//// globals); `link` resolves those to `rt_teavm`. This drives the conformance `driver` because the
//// import-bearing `instantiate/1(Imports)` path is the harness's, not the CLI `run` verb's.
////
//// The engine computes 46 (9 + 12 + 25) by genuinely allocating three GC structs and calling
//// `area()` on each through the vtable `call_ref` — a stubbed host runtime cannot fabricate it.

import gleam/io
import gleam/string
import twocore/conformance/driver
import twocore/conformance/ffi
import twocore/conformance/fixture
import twocore/conformance/runner
import twocore/runtime/profiles

/// The committed TeaVM WASM GC fixture (relative to the repo root, where tests run).
const teavm_wasm = "test/twocore/teavm/compute.wasm"

/// `demo.Client.compute()` runs on the BEAM and returns 46.
pub fn teavm_compute_run_test() {
  let assert Ok(bytes) = ffi.read_file(teavm_wasm)
  let d = driver.pipeline_with(profiles.unsafe())
  // Import-bearing instantiate (`instantiate/1(Imports)`): `link` resolves the TeaVM host imports to
  // `rt_teavm` and supplies the imported memory + globals, then the module's `(start)` bootstrap runs.
  let assert Ok(inst) = d.instantiate(bytes)
  let result = d.invoke(inst, "compute", [])
  io.println("\n[teavm] demo.Client.compute() = " <> string.inspect(result))
  // 9 (3²) + 12 (3·2²) + 25 (5²) = 46 — object allocation + virtual dispatch, spec-correct.
  assert result == runner.Returned([fixture.I32Val(46)])
}
