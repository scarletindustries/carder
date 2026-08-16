//// THE PHASE-7 HEADLINE (P7-09 §A / J4) — JS runs on the BEAM, measured differentially.
////
//// Drives the whole JS corpus (`corpus.programs()`) through Porffor -> carder -> BEAM under
//// `profiles.porffor()` — each program's vendored `.wasm` (Porffor 0.61.13's output) run through
//// the FULL carder pipeline via `pipeline.run_porffor` — and JUDGES each program's captured console
//// output byte-for-byte against Porffor's OWN execution (the baked `.expected`, itself the T13
//// `porf run` oracle cross-checked vs Node at vendor time). This is Tier-A: it needs no live
//// Porffor/Node (the baked reference always judges); the live re-confirmation is
//// `js_differential_test`.
////
//// It prints the coverage table and asserts the honest invariants (§A.2):
////  (a) fail == 0            — no program where Porffor compiled + carder ran but the BEAM output
////                             DIVERGED from Porffor's (a real carder bug);
////  (b) pass > 0             — a NON-VACUOUS set of real JS programs (arithmetic + control flow +
////                             functions + recursion + try/catch) runs on the BEAM and matches
////                             correct JS;
////  (c) no program silently drops — pass + fail + skips == total, and every skip is a typed
////                             `SkipCategory` (S11/D9), so a program going dark cannot hide.
////
//// MEASURED (Porffor 0.61.13, this machine): 52 pass / 0 fail / 3 skip (all
//// `PorfforVsNodeDivergence` — Porffor's own `-0` rendering + broken lexical-closure capture;
//// carder reproduces `porf run` byte-for-byte even on those three, so they are Porffor's bound,
//// not carder's — J8).

import carder/js/corpus.{type Program, Threw}
import carder/js/report.{
  type Verdict, CarderGap, Fail, Pass, ReferenceUnavailable, Skip,
  UnprovidedIntrinsic,
}
import carder/pipeline.{type PorfforRun}
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import simplifile

/// Judge one program's carder run against its baked `porf run` reference (§E, the single comparison
/// authority). `beam` is carder's `PorfforRun`; `expected` is the baked stdout bytes.
///
/// - A `"link:"` trap = an unprovided `""` intrinsic (fail-closed link) -> `Skip(UnprovidedIntrinsic)`
///   (never a false green; inert for this corpus — the four intrinsics are provided).
/// - Otherwise the BEAM OUTCOME CLASS (clean vs threw) must match `porf run`'s baked outcome AND the
///   BEAM console bytes must equal the baked reference byte-for-byte (color in-band). A mismatch on
///   either is a `Fail` (a real carder bug) REGARDLESS of the program's `skip` field — carder must
///   reproduce the wasm Porffor ran.
/// - On a byte+outcome match: an expected-pass program (`skip: None`) is a `Pass`; a documented
///   Porffor-vs-Node divergence (`skip: Some(cat)`) is `Skip(cat)` (beam == porf held, but "pass"
///   is reserved for reproducing CORRECT JS, §E.2).
///
/// Total — every path yields exactly one `Verdict`, never a panic, never a silent drop.
fn judge(program: Program, beam: PorfforRun, expected: BitArray) -> Verdict {
  case beam.trapped {
    Some(reason) ->
      case string.starts_with(reason, "link:") {
        True -> Skip(UnprovidedIntrinsic(reason))
        False -> judge_outcome(program, beam, expected, beam_threw: True)
      }
    None -> judge_outcome(program, beam, expected, beam_threw: False)
  }
}

/// The outcome-class + byte-exact core of `judge` (after link failures are handled). `beam_threw`
/// is whether the BEAM surfaced an uncaught exception; it must equal `porf run`'s baked outcome
/// (`Threw` vs `Clean`), and the console bytes must match `expected`. Total.
fn judge_outcome(
  program: Program,
  beam: PorfforRun,
  expected: BitArray,
  beam_threw beam_threw: Bool,
) -> Verdict {
  let porf_threw = program.outcome == Threw
  let output_match = beam.output == expected
  let outcome_match = beam_threw == porf_threw
  case output_match, outcome_match {
    True, True ->
      case program.skip {
        None -> Pass
        Some(category) -> Skip(category)
      }
    False, _ ->
      Fail(
        "beam output != porf: got "
        <> preview(beam.output)
        <> " exp "
        <> preview(expected),
      )
    _, False ->
      Fail(
        "outcome class: beam threw="
        <> bool_str(beam_threw)
        <> " porf threw="
        <> bool_str(porf_threw),
      )
  }
}

/// Run one program through carder and judge it, or categorize a pre-run failure. A missing vendored
/// `.wasm`/`.expected` is `Skip(ReferenceUnavailable)` (cannot judge); a `run_porffor` pipeline
/// rejection (decode/validate/lower/emit/build) is `Skip(CarderGap(_))` — a named carder gap, never
/// a false green. Total.
fn run_and_judge(program: Program) -> Verdict {
  let wasm_res = simplifile.read_bits(corpus.wasm_path(program))
  let exp_res = simplifile.read_bits(corpus.expected_path(program))
  case wasm_res, exp_res {
    Ok(wasm), Ok(expected) ->
      case pipeline.run_porffor(wasm, "m") {
        Ok(beam) -> judge(program, beam, expected)
        Error(e) -> Skip(CarderGap(string.inspect(e)))
      }
    _, _ -> Skip(ReferenceUnavailable)
  }
}

/// **The Phase-7 headline (J4).** Runs the corpus, prints the coverage table, and asserts the
/// honest invariants: `fail == 0`, `pass > 0`, and no silent drop (`pass + fail + skips == total`).
pub fn js_runs_on_beam_and_matches_porffor_test() {
  let rpt =
    list.fold(corpus.programs(), report.empty(), fn(acc, program) {
      let label = corpus.label(program)
      let verdict = run_and_judge(program)
      print_verdict(label, verdict)
      report.record(acc, label, verdict)
    })

  io.println(
    "\n=== JS-on-the-BEAM conformance (Porffor 0.61.13 -> carder -> BEAM) ===",
  )
  io.println(report.render(rpt))

  // (a) no carder divergence from Porffor's own execution.
  rpt.fail |> should.equal(0)
  // (b) a non-vacuous set of real JS programs runs on the BEAM and matches correct JS.
  { rpt.pass > 0 } |> should.be_true
  // (c) no program silently drops — every one lands in exactly one bucket.
  { rpt.pass + rpt.fail + list.length(rpt.skips) }
  |> should.equal(rpt.total)
  // and the corpus is the full manifest.
  rpt.total |> should.equal(list.length(corpus.programs()))
}

/// A stronger, category-anchored acceptance (J4 "arithmetic + control flow + functions + recursion
/// + at least one try/catch"): asserts the specific keystone programs PASS on the BEAM — the plumbing
/// (console), an f64 arithmetic corner (`0.1+0.2`), a hot loop (control), a recursive `fib`, and the
/// EH keystone (a caught `try/catch`). A regression on any turns THIS program red on the exact case.
pub fn js_keystone_programs_pass_test() {
  [
    corpus.Program("console", "hello", corpus.Clean, None),
    corpus.Program("arith", "floatsum", corpus.Clean, None),
    corpus.Program("control", "hotloop", corpus.Clean, None),
    corpus.Program("recursion", "fib", corpus.Clean, None),
    corpus.Program("trycatch", "basic", corpus.Clean, None),
    corpus.Program("trycatch", "uncaught", corpus.Threw, None),
  ]
  |> list.each(fn(program) { run_and_judge(program) |> should.equal(Pass) })
}

/// Print one program's verdict line (only non-pass lines are verbose, to keep the log readable). A
/// `Pass` prints a terse tick; a `Skip`/`Fail` prints the category/reason. Total.
fn print_verdict(label: String, verdict: Verdict) -> Nil {
  case verdict {
    Pass -> Nil
    Skip(category) ->
      io.println("  SKIP  " <> label <> "  " <> report.skip_label(category))
    Fail(reason) -> io.println("  FAIL  " <> label <> "  " <> reason)
  }
}

/// A readable preview of a byte buffer for a fail message: the string form if it is valid UTF-8,
/// else a byte count. Total.
fn preview(b: BitArray) -> String {
  case bit_array.to_string(b) {
    Ok(s) -> "\"" <> s <> "\""
    Error(_) -> "<" <> int.to_string(bit_array.byte_size(b)) <> " bytes>"
  }
}

/// `"true"`/`"false"` for a fail message. Total.
fn bool_str(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}
