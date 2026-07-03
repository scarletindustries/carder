//// THE LIVE DIFFERENTIAL (P7-09 §E, Tier-B) — re-confirm the corpus against a live Porffor + Node.
////
//// Tier-A (`js_conformance_test`) judges every program against the BAKED `.expected`. This unit
//// re-confirms those bakes against a LIVE toolchain when one is installed (skipping gracefully,
//// recorded, when absent — the `wasmtime` differential precedent), giving two live proofs:
////
//// 1. **`beam == porf run`** (the T13 fair oracle): 2core's captured console output equals Porffor's
////    OWN execution of the SAME `.wasm` byte-for-byte (color in-band) for every CLEAN program, and
////    matches the outcome class (both threw) for every uncaught-throw program. A divergence here is a
////    real 2core bug — this is the strongest differential (same compiled artifact, same reference).
//// 2. **the porf-vs-node categorization** (§E.2): re-derives, live, that every expected-pass program
////    agrees `porf == node` and every documented `PorfforVsNodeDivergence` program actually diverges
////    `porf != node` — so the skip categories are live-verified Porffor bugs, not stale bakes.

import gleam/bit_array
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import simplifile
import twocore/js/corpus.{type Program}
import twocore/js/porffor
import twocore/pipeline

/// **Live `beam == porf run` (T13).** For each corpus program, run its vendored `.wasm` through
/// 2core AND run Porffor live on the `.js`; assert 2core reproduces Porffor's own execution — a
/// CLEAN program byte-for-byte (including in-band ANSI color), an uncaught-throw program by matching
/// outcome class (both surfaced an exception; the pre-throw stdout is judged byte-exact in Tier-A).
/// Skips gracefully (recorded) when Porffor is not installed.
pub fn js_beam_equals_porf_run_live_test() {
  case porffor.available() {
    False -> {
      io.println(
        "\n[js-diff] npx/porffor not installed — live beam==porf differential SKIPPED (recorded)",
      )
      Nil
    }
    True -> {
      io.println(
        "\n[js-diff] live beam==porf run over the representative sample:",
      )
      list.each(corpus.sample(), fn(program) {
        let assert Ok(wasm) = simplifile.read_bits(corpus.wasm_path(program))
        let assert Ok(beam) = pipeline.run_porffor(wasm, "m")
        let #(code, out) = porffor.run(corpus.js_path(program))
        case code {
          // clean run: Porffor's folded stdout IS the console reference — byte-exact.
          0 -> beam.output |> should.equal(bit_array.from_string(out))
          // uncaught throw: 2core must ALSO have surfaced an exception (outcome class).
          _ -> { beam.trapped != None } |> should.be_true
        }
      })
    }
  }
}

/// **Live porf-vs-node categorization (§E.2).** Re-derives, from a live Porffor + Node, that the
/// manifest's `skip` decisions are correct: an expected-pass program (`skip: None`) must have
/// `porf == node`; a `PorfforVsNodeDivergence` program (`skip: Some`) must have `porf != node`. This
/// live-verifies that "pass" means 2core reproduced CORRECT JS and each skip is a genuine Porffor
/// bug. Skips gracefully (recorded) when Porffor or Node is absent.
pub fn js_porf_vs_node_categorization_live_test() {
  case porffor.available() && porffor.node_available() {
    False -> {
      io.println(
        "\n[js-diff] npx/porffor or node not installed — porf-vs-node cross-check SKIPPED (recorded)",
      )
      Nil
    }
    True -> {
      io.println("\n[js-diff] live porf-vs-node categorization re-check:")
      list.each(corpus.sample(), fn(program) {
        let expect_agree = case program.skip {
          None -> True
          Some(_) -> False
        }
        agree(program) |> should.equal(expect_agree)
      })
    }
  }
}

/// `True` iff Porffor and Node AGREE on `program` (live): identical outcome class (both exit 0, or
/// both exit non-zero) AND, when both ran clean, identical logical output (ANSI-stripped — Node does
/// not colorize a pipe, §E.2). A `False` is a Porffor-vs-Node divergence (a Porffor bug). Total over
/// the live shell-out results. Used only under the `available()` guard.
fn agree(program: Program) -> Bool {
  let #(pcode, pout) = porffor.run(corpus.js_path(program))
  let #(ncode, nout) = porffor.node_run(corpus.js_path(program))
  let outcome_agree = { pcode == 0 } == { ncode == 0 }
  case pcode == 0 && ncode == 0 {
    True -> outcome_agree && porffor.strip_ansi(pout) == nout
    False -> outcome_agree
  }
}
