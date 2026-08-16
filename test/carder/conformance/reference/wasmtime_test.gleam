//// Self-test for the Tier-B wasmtime adapter — TOLERANT: it skips (does not fail) when
//// `wasmtime` is not installed, so the suite stays green on a host without the engine.
//// When present, it cross-checks the adapter against the corpus modules using the
//// verified wasmtime 46 invoke syntax (flags + function before the module, args after).

import carder/conformance/reference/wasmtime
import gleam/io
import gleam/string

const corpus_dir = "test/carder/conformance/corpus"

/// With wasmtime present: `add(2,3)` returns 5 and `div_u(10,0)` traps "integer divide
/// by zero". Without it: log + skip.
pub fn wasmtime_cross_check_test() {
  case wasmtime.available() {
    False -> {
      io.println(
        "\n[conformance] wasmtime not installed; skipping Tier-B cross-check",
      )
      Nil
    }
    True -> {
      let assert wasmtime.Value("5") =
        wasmtime.invoke_ints(corpus_dir <> "/add.wasm", "add", [2, 3])

      let assert wasmtime.Trap(msg) =
        wasmtime.invoke_ints(corpus_dir <> "/intops.wasm", "divu", [10, 0])
      assert string.contains(msg, "integer divide by zero")
      Nil
    }
  }
}
