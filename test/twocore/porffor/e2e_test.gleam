//// THE HEADLINE PROOF (P7-08) — a real Porffor-compiled JS program runs end-to-end on the BEAM
//// via 2core, for the EH-free subset (T12).
////
//// Each program was compiled by **Porffor 0.61.13** (`porffor wasm foo.js foo.wasm`, committed
//// under `fixtures/`) and its byte-exact `porf run` output measured (`od -An -tx1`, T13). The
//// deterministic test runs each committed `.wasm` through the FULL 2core pipeline
//// (decode → validate → lower → emit → build_beam → load → instantiate → invoke `"m"`) under
//// `profiles.porffor()`, drains the console output, and asserts it is **byte-identical** to the
//// measured `porf run` output — ANSI escapes in-band (T11). The guarded differential re-checks
//// against a LIVE `porf run` when Porffor is on `PATH` (skips gracefully otherwise, like the
//// wasmtime differential). These programs are EH-FREE (verified: `wasm-tools validate` passes at
//// the wasm-2.0 baseline, zero tags/throws), so they run on the Phase-6 engine + the shim
//// WITHOUT the EH pipeline. **This is JS running on the BEAM.**

import gleam/bit_array
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import simplifile
import twocore/conformance/ffi
import twocore/js/porffor
import twocore/pipeline
import twocore/runtime/porffor_abi.{PNumber}

const fixture_dir = "test/twocore/porffor/fixtures/"

/// A non-string `console.log` value: Porffor wraps it in ANSI yellow + a trailing newline,
/// baked in-band as `printChar` calls (measured, §E.2) — `\x1b[33m<s>\x1b[0m\n`.
fn ansi_number(s: String) -> String {
  "\u{001B}[33m" <> s <> "\u{001B}[0m\n"
}

/// The console-output corpus: `#(fixture basename, measured `porf run` stdout bytes)`.
/// - `console.log(42)`            → `\x1b[33m42\x1b[0m\n`
/// - `console.log("hello world")` → `hello world\n` (top-level strings print RAW, no quotes/color)
/// - `console.log(Math.sqrt(16))` → `\x1b[33m4\x1b[0m\n`
/// - `console.log(2 + 3 * 4)`     → `\x1b[33m14\x1b[0m\n`
fn console_programs() -> List(#(String, String)) {
  [
    #("console_number", ansi_number("42")),
    #("console_string", "hello world\n"),
    #("math_sqrt", ansi_number("4")),
    #("arithmetic", ansi_number("14")),
  ]
}

/// **The headline.** Each committed Porffor `.wasm` runs through the whole 2core pipeline on the
/// BEAM and its drained console output is BYTE-IDENTICAL to the measured `porf run` output — ANSI
/// colors matched in-band, not stripped-and-guessed (T11/T13). A clean completion (`trapped: None`).
pub fn js_on_beam_console_headline_test() {
  list.each(console_programs(), fn(program) {
    let #(name, expected) = program
    let assert Ok(wasm) = simplifile.read_bits(fixture_dir <> name <> ".wasm")
    let assert Ok(run) = pipeline.run_porffor(wasm, "m")
    run.trapped |> should.equal(None)
    run.output |> should.equal(bit_array.from_string(expected))
  })
}

/// **The value ABI end-to-end (DoD #3).** A top-level expression program (`2 + 3`) is import-free
/// (no `console.log`), so it runs the `instantiate/0` path and returns its completion value as a
/// `(f64, i32)` pair — decoded to `PNumber(f64_bits(5.0))` (tag `0x01`). No console output.
pub fn js_on_beam_value_result_test() {
  let assert Ok(wasm) = simplifile.read_bits(fixture_dir <> "expr_value.wasm")
  let assert Ok(run) = pipeline.run_porffor(wasm, "m")
  run.trapped |> should.equal(None)
  run.output |> should.equal(<<>>)
  // 2 + 3 == 5.0 ; 5.0's raw IEEE-754 bits are 0x4014000000000000
  run.result |> should.equal(PNumber(0x4014000000000000))
}

/// **The guarded LIVE differential (T13, the fair oracle).** When Porffor is on `PATH`, run each
/// program through `porf run` and assert 2core's console output equals it byte-for-byte — the
/// same `.wasm`-derived program, so a divergence is a 2core bug. Skips gracefully (recorded) when
/// Porffor is not installed, exactly like the wasmtime differential.
pub fn js_on_beam_differential_test() {
  case ffi.find_executable("npx") {
    Error(_) -> {
      io.println(
        "\n[porffor-e2e] npx/porffor not installed — LIVE differential SKIPPED (recorded)",
      )
      Nil
    }
    Ok(npx) ->
      list.each(console_programs(), fn(program) {
        let #(name, _) = program
        let js = fixture_dir <> name <> ".js"
        let assert Ok(wasm) =
          simplifile.read_bits(fixture_dir <> name <> ".wasm")
        let assert Ok(run) = pipeline.run_porffor(wasm, "m")
        let #(code, raw) = ffi.run(npx, ["porffor", js])
        let oracle = porffor.strip_npm_noise(raw)
        case code {
          0 -> {
            io.println(
              "[porffor-e2e] "
              <> name
              <> " porf run == 2core: "
              <> string.inspect(oracle),
            )
            run.output |> should.equal(bit_array.from_string(oracle))
          }
          _ ->
            io.println(
              "[porffor-e2e] porf run nonzero exit for " <> name <> " (skipped)",
            )
        }
      })
  }
}

// ════════════════════ THE EH HEADLINE — JS exceptions running as BEAM exceptions (P7-06) ════════════════════

/// **THE EH HEADLINE — a real Porffor `try/catch` JS program runs as BEAM exceptions.** The
/// committed `trycatch.wasm` was compiled by **Porffor 0.61.13** from
/// `try { throw new Error("boom") } catch (e) { console.log("caught") }` — it carries a tag +
/// `throw` + legacy `try`/`catch` (verified: `wasm-tools print` shows `(tag …)`, `throw 0`,
/// `try`/`catch 0`; `wasm-tools validate --features=all` passes with EH). Run through the FULL
/// 2core pipeline under `profiles.porffor()`, the WASM/JS exception handling executes as native
/// BEAM `try…catch`/`raise` (P7-06): the throw unwinds to the catch, and the handler's
/// `console.log("caught")` runs. Its console output is BYTE-IDENTICAL to the measured `porf run`
/// output ("caught\n") on a clean completion (`trapped: None`). This is JavaScript exceptions
/// running on the BEAM.
pub fn js_on_beam_trycatch_headline_test() {
  let assert Ok(wasm) = simplifile.read_bits(fixture_dir <> "trycatch.wasm")
  let assert Ok(run) = pipeline.run_porffor(wasm, "m")
  run.trapped |> should.equal(None)
  run.output |> should.equal(bit_array.from_string("caught\n"))
}

/// **The guarded LIVE differential for the EH headline (T13).** When Porffor is on `PATH`, run the
/// `try/catch` program through `porf run` (V8 executing the SAME `.wasm`) and assert 2core's console
/// output equals it byte-for-byte — a divergence would be a 2core EH bug. Skips gracefully when
/// Porffor is not installed (recorded), exactly like the EH-free differential.
pub fn js_on_beam_trycatch_differential_test() {
  case ffi.find_executable("npx") {
    Error(_) -> {
      io.println(
        "\n[porffor-eh] npx/porffor not installed — try/catch LIVE differential SKIPPED (recorded)",
      )
      Nil
    }
    Ok(npx) -> {
      let js = fixture_dir <> "trycatch.js"
      let assert Ok(wasm) = simplifile.read_bits(fixture_dir <> "trycatch.wasm")
      let assert Ok(run) = pipeline.run_porffor(wasm, "m")
      let #(code, raw) = ffi.run(npx, ["porffor", js])
      let oracle = porffor.strip_npm_noise(raw)
      case code {
        0 -> {
          io.println(
            "[porffor-eh] trycatch porf run == 2core: "
            <> string.inspect(oracle),
          )
          run.output |> should.equal(bit_array.from_string(oracle))
        }
        _ ->
          io.println(
            "[porffor-eh] porf run nonzero exit for trycatch (skipped)",
          )
      }
    }
  }
}
