//// Tier-B reference-engine adapter — shells out to `wasmtime` to produce expected
//// values for AUTHORED corpus programs and random/property inputs (cases where the
//// spec `.wast` carries no baked-in answer). Tier-B ONLY — never on the Tier-A path
//// (the spec files already contain their expected values; see `oracle`/`fixture`).
////
//// Verified invoke syntax for the pinned wasmtime 46.0.1 (vendor/PIN) — flags + the
//// function name go BEFORE the module, call arguments AFTER it (the older positional
//// `--invoke 'f(a,b)'` form was removed):
////
////     wasmtime run --invoke <field> <module.wasm> <arg> <arg> ...
////
//// Note (verified): for this version `wasmtime` prints integer results as SIGNED
//// decimal and float results as a decimal float (NOT the raw bit pattern), and a trap
//// goes to stderr as `wasm trap: <message>` with a non-zero exit. So Tier-B confirms a
//// VALUE; the corpus still records expected bit patterns sourced from the spec/IEEE.

import carder/conformance/ffi
import gleam/int
import gleam/list
import gleam/string

/// The result of a Tier-B invocation.
///
/// - `Value(line)`: a normal return; `line` is wasmtime's printed result (signed
///   decimal for ints, decimal float for floats).
/// - `Trap(message)`: the program trapped; `message` is the `wasm trap: …` text.
/// - `Failure(text)`: the engine could not run the request (bad module, etc.).
pub type Outcome {
  Value(line: String)
  Trap(message: String)
  Failure(text: String)
}

/// Whether `wasmtime` is on `PATH`. Lets callers (and the self-test) SKIP gracefully
/// rather than fail when the Tier-B engine is not installed.
pub fn available() -> Bool {
  case ffi.find_executable("wasmtime") {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Invoke export `field` of the module at `path` with the given string `args`, using
/// the verified wasmtime 46 CLI form. Combined stdout+stderr is captured; a `wasm
/// trap:` line maps to `Trap`, a clean exit to `Value` (last meaningful output line),
/// otherwise `Failure`.
pub fn invoke(path: String, field: String, args: List(String)) -> Outcome {
  // `open_port({spawn_executable, …})` needs an ABSOLUTE path (it does not search
  // PATH), so resolve `wasmtime` first.
  case ffi.find_executable("wasmtime") {
    Error(_) -> Failure("wasmtime not found on PATH")
    Ok(exe) -> {
      let argv = list.flatten([["run", "--invoke", field, path], args])
      let #(code, output) = ffi.run(exe, argv)
      case code {
        0 -> Value(last_meaningful_line(output))
        _ ->
          case extract_trap(output) {
            Ok(msg) -> Trap(msg)
            Error(_) -> Failure(string.trim(output))
          }
      }
    }
  }
}

/// Convenience: invoke with integer arguments (rendered as decimal).
pub fn invoke_ints(path: String, field: String, args: List(Int)) -> Outcome {
  invoke(path, field, list.map(args, int.to_string))
}

/// The last non-empty, non-warning line of combined output — wasmtime emits the result
/// on its own line and prefixes experimental-feature warnings with `warning:`.
fn last_meaningful_line(output: String) -> String {
  output
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(l) { l != "" && !string.starts_with(l, "warning:") })
  |> list.last
  |> result_unwrap("")
}

fn extract_trap(output: String) -> Result(String, Nil) {
  output
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(string.contains(_, "wasm trap:"))
  |> list.last
}

fn result_unwrap(r: Result(String, a), default: String) -> String {
  case r {
    Ok(v) -> v
    Error(_) -> default
  }
}
