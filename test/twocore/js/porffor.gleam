//// `porffor` — the JS toolchain adapter (P7-09 §B): Porffor (the compiler + reference executor)
//// and Node (the ground-truth JS oracle), shelled out through the generic, unowned conformance
//// FFI (`ffi.run`/`ffi.find_executable`). Skips GRACEFULLY when a toolchain is absent (the
//// `wasmtime.available()` precedent) so the suite still judges every program from the baked
//// `.expected`.
////
//// The two invocations (MEASURED, Porffor 0.61.13):
//// - `npx porffor <src.js>` — compile-and-execute; its stdout is the reference console output
////   (the T13 fair oracle: V8 running the SAME `.wasm` 2core consumes). Exit 0 = clean; exit 1 =
////   the program threw uncaught.
//// - `node <src.js>` — the ground-truth JS semantics (Tier-B secondary), distinguishing "2core
////   reproduced correct JS" from "Porffor is wrong" (§E.2).
////
//// `ffi.run` folds stderr into stdout, so for a CLEAN (exit-0) program the returned bytes ARE the
//// stdout console stream; for a threw (exit-1) program the bytes carry the error text too, so the
//// live differential byte-compares only the clean programs (the baked `.expected` — stdout only —
//// judges the rest, §E.3). Every function here is TOTAL.

import gleam/list
import gleam/string
import twocore/conformance/ffi

/// `True` iff a Porffor toolchain is reachable (`npx` on PATH). When `False`, the live
/// differential (`js_differential_test`) skips gracefully and the baked `.expected` (Tier-A) still
/// judges every program. Total.
pub fn available() -> Bool {
  case ffi.find_executable("npx") {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// `True` iff Node is reachable (`node` on PATH) — the ground-truth JS oracle for the live
/// porf-vs-node cross-check. Total.
pub fn node_available() -> Bool {
  case ffi.find_executable("node") {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Compile-and-execute `js_path` with Porffor (`npx porffor <js_path>`) — the T13 reference
/// execution. Returns `#(exit_code, output)` where `output` is the combined stdout+stderr byte
/// stream (stdout IS the console reference for an exit-0 clean run). `exit_code` 0 = clean, 1 = an
/// uncaught throw. Never fails (a missing `npx` is guarded by `available()` first). Total.
pub fn run(js_path: String) -> #(Int, String) {
  case ffi.find_executable("npx") {
    Ok(npx) -> {
      let #(code, output) = ffi.run(npx, ["porffor", js_path])
      #(code, strip_npm_noise(output))
    }
    Error(_) -> #(-1, "")
  }
}

/// Remove npm's own diagnostic lines (`npm warn …` / `npm notice …`) from a shelled-out
/// `npx porffor` output. On a COLD npm cache (e.g. CI's fresh runner), the FIRST `npx porffor`
/// invocation prints `npm warn exec The following package was not found and will be installed:
/// porffor@…` to stderr, which `ffi.run` folds into stdout — polluting the console reference the
/// live differential byte-compares. These lines are npm's diagnostics, NEVER a JS program's
/// `console.log` output, so dropping them makes the oracle robust regardless of npm cache state
/// (locally warm ⇒ unchanged; CI cold ⇒ the warning is removed). The exit code is untouched, so
/// uncaught-throw detection is unaffected. Total.
pub fn strip_npm_noise(s: String) -> String {
  s
  |> string.split("\n")
  |> list.filter(fn(line) { !is_npm_diagnostic(line) })
  |> string.join("\n")
}

/// `True` iff `line` is one of npm's diagnostic prefixes (`npm warn`/`npm WARN`/`npm notice`/
/// `npm warning`) — its install/exec/notice noise, distinct from any program output. Total.
fn is_npm_diagnostic(line: String) -> Bool {
  string.starts_with(line, "npm warn")
  || string.starts_with(line, "npm WARN")
  || string.starts_with(line, "npm notice")
  || string.starts_with(line, "npm warning")
}

/// Run `js_path` with Node (`node <js_path>`) — the ground-truth JS semantics oracle. Returns
/// `#(exit_code, output)` (stdout+stderr folded; Node does NOT colorize a non-TTY pipe, so its
/// stdout is the plain logical text the oracle compares ANSI-stripped, §E.2). Never fails. Total.
pub fn node_run(js_path: String) -> #(Int, String) {
  case ffi.find_executable("node") {
    Ok(node) -> ffi.run(node, [js_path])
    Error(_) -> #(-1, "")
  }
}

/// Strip ANSI SGR escape sequences (`\x1b[…m`) from `s` — for the LOGICAL comparison against Node,
/// whose console output is uncolored (§E.2). Porffor's in-band color (`\x1b[33m…\x1b[0m`) is
/// matched byte-exact against `porf run` (the primary oracle) but stripped for the Node
/// cross-check. Total.
pub fn strip_ansi(s: String) -> String {
  strip_ansi_loop(s, "")
}

/// Fold `s` removing each `\x1b[…m` SGR sequence, accumulating into `acc`. Total — a lone `\x1b`
/// with no terminating `m` is dropped to end (a malformed tail, not expected from either oracle).
fn strip_ansi_loop(s: String, acc: String) -> String {
  case string.split_once(s, "\u{001B}[") {
    Error(_) -> acc <> s
    Ok(#(before, after)) ->
      case string.split_once(after, "m") {
        Error(_) -> acc <> before
        Ok(#(_code, rest)) -> strip_ansi_loop(rest, acc <> before)
      }
  }
}
