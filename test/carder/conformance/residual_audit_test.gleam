//// The R16 empirical residual audit (P6-10 owns it, S11). Runs the pinned suite once (Safe), buckets
//// every residual SKIP by its originating FILE and a stable reason-phrase, prints the audit table,
//// and asserts the measured composition is HONEST — every residual skip is one of the enumerated
//// Phase-6 categories (never an uncategorised / mislabelled skip, D9), and `fail == 0`.
////
//// Phase 14 CLOSED the once-largest residual by MEASUREMENT (S11): `table_copy.wast`'s cross-module
//// funcref-in-`elem`-segment init — `ref.func` of an IMPORTED function placed in a table and reached
//// via `call_indirect` — now BUILDS + DISPATCHES (the `RefFuncImport` IR distinction + the D3a
//// import-adapter closure), so the file runs FULLY (`table_copy.wast` = 1649/0/0). The `"UnknownFunction"`
//// / `"call_indirect_table"` phrases that categorised that gap are REMOVED below (measured empty first),
//// so a `RefFuncImport`-shaped regression goes RED instead of hiding. The remaining named residuals are
//// the SIMD text-format frontend asserts (S13: SIMD text is out of scope for the WAT parser) and the
//// DISTINCT const-expr / imported-global element-init gap. The audit prints the TRUE cause per file so
//// a future reader never sees a guessed label.

import carder/conformance/driver
import carder/conformance/ffi
import carder/conformance/fixture
import carder/conformance/runner.{type Report}
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/string

const fixtures_dir = "test/carder/conformance/fixtures"

/// The enumerated honest Phase-6 residual categories (S11/S12/S13/D9). A residual skip is HONEST iff
/// its stable reason-phrase matches one of these; a skip matching none is UNCATEGORISED — a
/// construct that quietly went dark — and fails the audit.
fn allowed_phrases() -> List(String) {
  [
    // NOTE (Phase 14): the cross-module funcref-in-`elem`-segment gap is CLOSED — `table_copy.wast`
    // now BUILDS + DISPATCHES its `ref.func`-of-an-imported-function asserts (the `RefFuncImport` IR
    // distinction + the D3a import-adapter closure landed), so the `"UnknownFunction"` and
    // `"call_indirect_table"` phrases that categorised it are DELIBERATELY GONE. MEASURED before
    // removal: no residual skip carries either phrase (`table_copy.wast` = 1649/0/0). Removing them
    // means a `RefFuncImport`-shaped regression that re-skips these asserts goes RED (uncategorised)
    // instead of hiding. The DISTINCT, still-deferred const-expr / imported-global element-init gap
    // (a segment initialised from an *imported global*'s `global.get`, NOT a `ref.func` of an imported
    // *function*) keeps its own phrases below.
    "imported-global element-init", "NonConstInit", "NonConstantExpr",
    "UnsupportedNode",
    // SIMD text-format frontend asserts — SIMD text out of scope for the WAT parser (S13)
    "out-of-scope text", "v128", "simd", "lane",
    "text parser+validator accepted",
    // GC-proposal typed references / heap types — later
    "BadHeapType", "arrayref", "ref null", "extended-const",
    // memory64 / threads / shared — categorised
    "memory64", "shared", "atomic.",
    // post-2.0 proposals & harness paths (each a NAMED coverage gap, S12). NOTE (Phase 13): the
    // blanket `"return_call"` and `"call stack"` phrases are DELIBERATELY GONE — tail-call is now
    // DRIVEN (return_call.wast / return_call_indirect.wast run green), so no residual skip should
    // carry a `return_call` reason and the tail-call-adjacent "call stack" stack-model phrase should
    // categorize nothing. Removing them means a return_call-shaped regression (a re-skipped tail
    // call) goes RED (uncategorised) instead of hiding.
    "unhandled command: assert_exhaustion", "tag",
    // the ONE tail-call residual: a host-import tail/direct call (`spectest.print_i32_f32`) DENIED
    // under the deny-all Safe host — a POLICY denial, not a spec trap (it PASSES under `unsafe`).
    "capability_denied", "module definition", "link: unknown import",
    "unlinkable (out of scope)", "cross-module", "import-section construct",
    "uninstantiable (out of scope)", "register:", "no such export", "driver:",
  ]
}

fn in_allowed_category(reason: String) -> Bool {
  list.any(allowed_phrases(), fn(c) { string.contains(reason, c) })
}

/// The audit. Runs the pinned suite once, buckets residual skips by `(file, cause-category)`, prints
/// the table, and asserts every residual skip is categorised + `fail == 0`.
pub fn residual_audit_is_measured_and_honest_test() {
  let #(count, total) = run_full_suite()
  case count < 40 {
    True -> {
      io.println(
        "\n[residual-audit] no full suite present; run vendor/vendor.sh (skipping)",
      )
      Nil
    }
    False -> {
      // Bucket by (file, category) → count.
      let by_bucket =
        list.fold(total.skips, dict.new(), fn(acc, reason) {
          let key = file_of(reason) <> "  |  " <> category_of(reason)
          dict.upsert(acc, key, bump)
        })

      io.println(
        "\n=== R16 residual audit (Safe, "
        <> int.to_string(count)
        <> " fixtures) — pass="
        <> int.to_string(total.pass)
        <> " skip="
        <> int.to_string(total.skip)
        <> " fail="
        <> int.to_string(total.fail)
        <> " ===",
      )
      io.println("  (file  |  cause)  →  count  [top 30 buckets]")
      by_bucket
      |> dict.to_list
      |> list.sort(fn(a, b) {
        let #(_, ca) = a
        let #(_, cb) = b
        int.compare(cb, ca)
      })
      |> list.take(30)
      |> list.each(fn(kv) {
        let #(key, n) = kv
        io.println("    " <> key <> "  →  " <> int.to_string(n))
      })

      let uncategorised =
        list.filter(total.skips, fn(r) { !in_allowed_category(r) })
      case uncategorised {
        [] ->
          io.println(
            "  ALL residual skips categorised (honest, D9/S11) — every cause named above.",
          )
        _ -> {
          io.println(
            "  UNCATEGORISED ("
            <> int.to_string(list.length(uncategorised))
            <> "):",
          )
          uncategorised
          |> list.take(20)
          |> list.each(fn(r) { io.println("    * " <> r) })
        }
      }

      // The hard gates: zero spec mismatches; every residual skip is honestly categorised (D9).
      assert total.fail == 0
      assert uncategorised == []
    }
  }
}

/// The dict `upsert` accumulator can't pattern-match `Option` cleanly inline, so count via a helper.
/// (Gleam's `dict.upsert` passes `Option(v)`; a fresh key is `None`.)
fn bump(prev: option.Option(Int)) -> Int {
  case prev {
    option.Some(n) -> n + 1
    option.None -> 1
  }
}

/// Extract the originating file basename from a skip reason (`"<path>.wast:<line> <cause>"`).
fn file_of(reason: String) -> String {
  case string.split_once(reason, ".wast:") {
    Ok(#(pathish, _)) ->
      case string.split(pathish, "/") |> list.last {
        Ok(base) -> base <> ".wast"
        Error(_) -> pathish <> ".wast"
      }
    Error(_) -> "?"
  }
}

/// Collapse a skip reason to a coarse cause-category (drop the `file:line` prefix, keep a stable
/// tail) for the audit histogram.
fn category_of(reason: String) -> String {
  let tail = case string.split_once(reason, " ") {
    Ok(#(_loc, rest)) -> rest
    Error(_) -> reason
  }
  string.slice(tail, 0, 48)
}

/// Run every `*.json` fixture present under the Safe profile, returning `#(count, total)`.
fn run_full_suite() -> #(Int, Report) {
  let jsons = case ffi.list_dir(fixtures_dir) {
    Ok(entries) ->
      entries
      |> list.filter(string.ends_with(_, ".json"))
      |> list.sort(string.compare)
    Error(_) -> []
  }
  let d = driver.pipeline()
  let total =
    list.fold(jsons, runner.empty_report(), fn(acc, name) {
      case fixture.load(fixtures_dir <> "/" <> name) {
        Error(_) -> acc
        Ok(fix) -> runner.merge(acc, runner.run_fixture(d, fix, fixtures_dir))
      }
    })
  #(list.length(jsons), total)
}
