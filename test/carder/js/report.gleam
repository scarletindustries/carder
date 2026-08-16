//// `report` — the honest JS-on-the-BEAM coverage ledger (P7-09 §F, S11/D9).
////
//// The Phase-7 headline is a NUMBER and a categorized residual: how many real JS programs,
//// compiled by Porffor and run through carder on the BEAM, produce output byte-identical to
//// Porffor's own execution (`porf run`, T13) — with every non-green program a TYPED, PRINTED
//// skip, never a false green. This module owns the ledger types (`Verdict`, `SkipCategory`,
//// `JsReport`), the accumulator, and the printed coverage table. It decides NO equality itself
//// (the judge lives in the conformance test, §E) — it only records + renders what the judge
//// returned, so the residual is a closed enum, not a free string.

import gleam/int
import gleam/list
import gleam/string

/// Why a corpus program is not a `Pass` — a CLOSED enum (S11/D9), so a program the harness cannot
/// turn green becomes a typed, printed skip, never an untracked "it didn't work". The categories
/// (§A.1):
/// - `PorfforUncompilable(diag)` — `porffor wasm` errored / non-zero exit: the JS is outside
///   Porffor's ~1/3-of-ECMA coverage (J8). NOT a carder gap.
/// - `UnprovidedIntrinsic(name)` — the `.wasm` imports a `""` intrinsic P7-08's shim does not
///   provide → the link fails CLOSED (never a silent stub).
/// - `CarderGap(stage)` — decode/validate/lower/emit/build REJECTED a construct carder does not
///   yet handle; carries the pipeline stage prefix. A real, named engine gap.
/// - `PorfforVsNodeDivergence(note)` — Porffor's output != Node's: a *Porffor* bug we cannot hold
///   carder to (carder still reproduces Porffor's wasm faithfully — beam == porf — but "pass" is
///   reserved for reproducing *correct* JS, so this is a skip). The note records the divergence.
/// - `ReferenceUnavailable` — neither a baked `.expected` nor a live reference is present.
pub type SkipCategory {
  PorfforUncompilable(diag: String)
  UnprovidedIntrinsic(name: String)
  CarderGap(stage: String)
  PorfforVsNodeDivergence(note: String)
  ReferenceUnavailable
}

/// The verdict for a single corpus program (§A.1). Exactly one of:
/// - `Pass` — Porffor compiled it, carder ran it on the BEAM, the BEAM console output is
///   byte-identical to `porf run` AND the reference is itself correct JS (`porf run == node`).
/// - `Fail(reason)` — Porffor compiled it + carder ran it, but the BEAM output/outcome DIVERGED
///   from Porffor's own execution — a real carder bug (the target of the whole harness).
/// - `Skip(category)` — a categorized non-green (see `SkipCategory`); never a false green.
pub type Verdict {
  Pass
  Fail(reason: String)
  Skip(category: SkipCategory)
}

/// The accumulated coverage ledger (§F). `pass`/`fail` are counts; `skips` and `fails` keep the
/// per-program labels so the printed table names each non-green program + its cause. `total` is
/// every program the harness considered — the drop-check invariant `pass + fail + |skips| == total`
/// (no program silently vanishes) is what the headline test asserts alongside `fail == 0`.
pub type JsReport {
  JsReport(
    pass: Int,
    fail: Int,
    skips: List(#(String, SkipCategory)),
    fails: List(#(String, String)),
    total: Int,
  )
}

/// The empty ledger (no program recorded yet). Total.
pub fn empty() -> JsReport {
  JsReport(pass: 0, fail: 0, skips: [], fails: [], total: 0)
}

/// Record one program's `verdict` under `label` (e.g. `"trycatch/basic"`) into `report`,
/// returning the updated ledger. Bumps exactly one bucket and `total`, so `pass + fail + |skips|`
/// stays equal to `total` (the drop-check invariant). Total — never fails.
pub fn record(report: JsReport, label: String, verdict: Verdict) -> JsReport {
  let base = JsReport(..report, total: report.total + 1)
  case verdict {
    Pass -> JsReport(..base, pass: base.pass + 1)
    Fail(reason) ->
      JsReport(..base, fail: base.fail + 1, fails: [
        #(label, reason),
        ..base.fails
      ])
    Skip(category) ->
      JsReport(..base, skips: [#(label, category), ..base.skips])
  }
}

/// A short human label for a `SkipCategory` (the printed table's right column). Total.
pub fn skip_label(category: SkipCategory) -> String {
  case category {
    PorfforUncompilable(diag) -> "PorfforUncompilable (" <> diag <> ")"
    UnprovidedIntrinsic(name) -> "UnprovidedIntrinsic (" <> name <> ")"
    CarderGap(stage) -> "CarderGap (" <> stage <> ")"
    PorfforVsNodeDivergence(note) -> "PorfforVsNodeDivergence (" <> note <> ")"
    ReferenceUnavailable -> "ReferenceUnavailable"
  }
}

/// The one-word bucket name for the histogram tally (`Uncompilable`/`Unprovided`/`CarderGap`/
/// `PorfVsNode`/`RefUnavail`). Total.
fn bucket_name(category: SkipCategory) -> String {
  case category {
    PorfforUncompilable(_) -> "Uncompilable"
    UnprovidedIntrinsic(_) -> "Unprovided"
    CarderGap(_) -> "CarderGap"
    PorfforVsNodeDivergence(_) -> "PorfVsNode"
    ReferenceUnavailable -> "RefUnavail"
  }
}

/// Count how many skips fall in `bucket` (one of the `bucket_name` words). Total.
fn count_bucket(report: JsReport, bucket: String) -> Int {
  report.skips
  |> list.filter(fn(s) { bucket_name(s.1) == bucket })
  |> list.length
}

/// The measured coverage headline + histogram (§F), rendered as a multi-line string. Names the
/// TOTAL line (pass / fail / skip) and the per-category skip tally, plus each skip's program +
/// cause and any fail's program + reason. This is the phase's measured "JS on the BEAM" number.
/// Total — pure string building, never fails.
pub fn render(report: JsReport) -> String {
  let skip_total = list.length(report.skips)
  let header =
    "  TOTAL   pass="
    <> int.to_string(report.pass)
    <> "  fail="
    <> int.to_string(report.fail)
    <> "  skip="
    <> int.to_string(skip_total)
    <> "   [ Uncompilable="
    <> int.to_string(count_bucket(report, "Uncompilable"))
    <> "  Unprovided="
    <> int.to_string(count_bucket(report, "Unprovided"))
    <> "  CarderGap="
    <> int.to_string(count_bucket(report, "CarderGap"))
    <> "  PorfVsNode="
    <> int.to_string(count_bucket(report, "PorfVsNode"))
    <> "  RefUnavail="
    <> int.to_string(count_bucket(report, "RefUnavail"))
    <> " ]"
  let skip_lines =
    report.skips
    |> list.reverse
    |> list.map(fn(s) { "  SKIP   " <> pad(s.0) <> "  " <> skip_label(s.1) })
    |> string.join("\n")
  let fail_lines =
    report.fails
    |> list.reverse
    |> list.map(fn(f) { "  FAIL   " <> pad(f.0) <> "  " <> f.1 })
    |> string.join("\n")
  [header, skip_lines, fail_lines]
  |> list.filter(fn(s) { s != "" })
  |> string.join("\n")
}

/// Right-pad a program label to a fixed width for column alignment in the printed table. Total.
fn pad(label: String) -> String {
  let n = string.length(label)
  case n < 28 {
    True -> label <> string.repeat(" ", 28 - n)
    False -> label
  }
}
