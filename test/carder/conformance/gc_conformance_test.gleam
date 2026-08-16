//// Unit P8 — the CAPSTONE WebAssembly-GC conformance run. Drives the OFFICIAL WebAssembly GC
//// `.wast` suite through the full carder pipeline (decode → validate → lower → emit → BEAM) and
//// asserts `fail == 0`, `pass > 0` on the driven-green set, with every residual categorized
//// honestly (R16/S11 — greenness is MEASURED, never promised). The GC analogue of
//// `eh_conformance_test.gleam`.
////
//// ## Vendoring (why wasm-tools, not wabt)
////
//// wabt 1.0.41 (the pinned MVP toolchain) cannot tokenize GC struct/array/i31 text or GC abstract
//// heap types — an upstream gap (wabt issue #2530; `--enable-gc` is a CLI facade with no parser).
//// So the GC suite is vendored with `wasm-tools json-from-wast` (which fully parses GC and emits a
//// wast2json-compatible `.json` + `.wasm` set) into `fixtures/gc/` — a SUBDIRECTORY the main
//// `conformance_test` top-level `.json` glob does not see, so the Phase-1..6 headline stays
//// byte-identical (the GC suite is driven HERE, not folded into the main allowlist). See the GC
//// section of `vendor/vendor.sh`.
////
//// ## What is driven green (MEASURED at the pin: testsuite 193e551…, wasm-tools 1.253.0)
////
//// 15 of the 23 top-level GC `.wast` files run GREEN end-to-end (`fail == 0`) — the struct/array/
//// i31 value surface, `ref.test`/`ref.cast`/`ref.eq`, `br_on_cast[_fail]`, the segment-sourced
//// array ops, and the type declaration/equivalence/canonicalization suites. This exercises the
//// GC engine carder added: struct/array/i31 allocation + access lowered onto a per-process arena of
//// `{gc,Id}`/`{i31,V}` handles (opt-in by pure reachability DCE, Safe-admissible); GC constant
//// expressions (`ref.i31`/`struct.new`/`array.new*` in globals & element segments); spec-conformant
//// GC trap messages; and iso-recursive type-section validation + concrete-heap-type canonicalization
//// (`sub`/finality/kind/structural-subtyping checks; canon-equal cross-rec-group identity).
////
//// ## The categorized residual (`gc_residual` — NOT driven green; honest, per R16)
////
//// 8 files carry residual failures, each a MEASURED engine gap OUTSIDE the value surface — chiefly
//// RUNTIME type identity that would need a canonical type id to survive lowering (GC concrete refs
//// erase to the neutral term ABI): cross-module import matching (`assert_unlinkable`), the
//// `call_indirect` runtime subtype check, and `ref.test`/`ref.cast` against an actual funcref. See
//// the per-file reasons below. These are deliberately deferred (they touch the funcref/table path
//// shared by the whole main suite), never a false green.

import carder/conformance/driver
import carder/conformance/ffi
import carder/conformance/fixture
import carder/conformance/runner.{type Report}
import carder/runtime/instance.{type Binding}
import carder/runtime/profiles
import gleam/int
import gleam/io
import gleam/list
import gleam/string

/// The GC fixtures subdirectory — isolated from the main `conformance_test.gleam` top-level `.json`
/// glob (so the headline stays byte-identical). Populated by `vendor/vendor.sh`'s GC section
/// (`wasm-tools json-from-wast`).
const gc_fixtures_dir = "test/carder/conformance/fixtures/gc"

/// The 15 official GC `.wast` files driven GREEN end-to-end at the pin (MEASURED — `fail == 0`).
const gc_green_files: List(String) = [
  "struct.json", "array.json", "array_copy.json", "array_fill.json",
  "array_init_data.json", "array_new_data.json", "binary-gc.json",
  "br_on_cast.json", "br_on_cast_fail.json", "i31.json", "ref_cast.json",
  "ref_eq.json", "ref_func.json", "type-canon.json", "type-equivalence.json",
]

/// The 8 GC `.wast` files with a categorized residual (NOT driven green), each with the honest
/// MEASURED reason (D9/S11 — never a false green). Overwhelmingly RUNTIME type identity that a
/// canonical type id would close (deferred: it touches the shared funcref/table path).
const gc_residual: List(#(String, String)) = [
  #(
    "type-subtyping.wast",
    "runtime type identity: assert_unlinkable import matching + call_indirect runtime subtype check + subtyping-dependent dispatch (needs a canonical type id threaded through the term ABI — GC concrete refs erase to the neutral term type at lowering)",
  ),
  #(
    "type-rec.wast",
    "runtime type identity: assert_unlinkable + call_indirect type-mismatch trap across rec-group-equal types (same canonical-id-at-runtime gap as type-subtyping)",
  ),
  #(
    "ref_test.wast",
    "ref.test/ref.cast against an actual funcref: the funcref runtime rep `{FuncType,Closure}` carries no concrete type id, so a `(ref $t)` matcher can't match it (Tier-3 funcref RTT)",
  ),
  #(
    "extern.wast",
    "host externalize/internalize identity: any.convert_extern/extern.convert_any round-trip of a host reference is not yet identity-preserving at runtime",
  ),
  #(
    "ref_null.wast",
    "exnref null return classification: a `(ref null exn)` result is not yet tagged as a null reference by the invoke ABI (an exnref-value edge, orthogonal to GC)",
  ),
  #(
    "array_init_elem.wast",
    "element-segment array init: a runtime edge in array.init_elem/array.new_elem value placement",
  ),
  #(
    "array_new_elem.wast",
    "element-segment array init: a runtime edge in array.new_elem value placement",
  ),
  #(
    "local_init.wast",
    "definite-assignment: a non-defaultable ref local read before set must be REJECTED — needs a separate dataflow pass, orthogonal to type canonicalization",
  ),
]

/// The deployment profiles the GC green set is driven through — `safe` (Cell/Paged, Baseline
/// optimizer + enforcing fuel) and `unsafe` (Cell/Paged, Aggressive optimizer + `MeterOff` + open
/// runtime). A real differential (both optimizer levels + both runtime postures), proving the GC
/// surface is optimizer- and posture-invariant.
///
/// **MEASURED Cell bound (T6-style, honest).** The `portable` (Threaded/Paged) profile is NOT
/// driven: a GC module that ALSO carries a data/element segment or a GC constant-expression global
/// instantiates its arena via the Cell seam, and under the Threaded state strategy that path hits
/// an un-seeded-cell contract (`rt_state: require_cell`) — GC INSTANTIATION is Cell-native today
/// (the runtime arena is process-local, but the segment/const-init seeding rides the Cell path).
/// This is a categorized runs-anywhere gap for GC-with-segments, not a value-surface failure;
/// segment-free GC (e.g. `struct.wast`) does run green under Threaded.
fn gc_profiles() -> List(#(String, Binding)) {
  [#("safe", profiles.safe()), #("unsafe", profiles.unsafe())]
}

/// PROOF (GC engine spec-correct end-to-end). The 15 driven GC `.wast` files run GREEN —
/// `fail == 0` (no GC assertion lit up wrong) and `pass > 0` (non-vacuous) — under both Cell
/// profiles (safe/unsafe). A lowering that mis-allocated a struct/array, misjudged a cast, dropped a trap, or
/// mis-canonicalized a rec-group type would flip an assertion to FAIL here, on a NAMED file. Skips
/// gracefully with a directive if the fixtures are absent (a fresh checkout without wasm-tools).
pub fn gc_wast_suite_spec_correct_test() {
  case ffi.list_dir(gc_fixtures_dir) {
    Error(_) -> announce_absent()
    Ok(_) -> {
      let results =
        list.flat_map(gc_profiles(), fn(p) {
          let #(label, binding) = p
          list.map(gc_green_files, fn(name) {
            #(label, name, run_gc_file(binding, name))
          })
        })
      print_report(results)
      print_residual()

      // The hard invariants: zero genuine GC mismatches on the driven set; the files DID light up.
      let total = fold_reports(list.map(results, fn(r) { r.2 }))
      assert total.fail == 0
      assert total.pass > 0
    }
  }
}

/// Load + run one GC fixture under `binding`, base-pathed at `fixtures/gc` so its `.N.wasm` modules
/// resolve. A parse failure surfaces as an all-skip report (never a silent pass).
fn run_gc_file(binding: Binding, name: String) -> Report {
  case fixture.load(gc_fixtures_dir <> "/" <> name) {
    Error(_) -> runner.empty_report()
    Ok(fix) ->
      runner.run_fixture(driver.pipeline_with(binding), fix, gc_fixtures_dir)
  }
}

fn fold_reports(reports: List(Report)) -> Report {
  list.fold(reports, runner.empty_report(), runner.merge)
}

fn print_report(results: List(#(String, String, Report))) -> Nil {
  io.println(
    "\n=== Phase-8 GC-engine conformance (official GC .wast → carder → BEAM, safe/unsafe [Cell]) ===",
  )
  list.each(results, fn(r) {
    let #(label, name, rep) = r
    io.println(
      "  "
      <> pad(name <> " [" <> label <> "]", 34)
      <> "pass="
      <> int.to_string(rep.pass)
      <> "  skip="
      <> int.to_string(rep.skip)
      <> "  fail="
      <> int.to_string(rep.fail),
    )
    list.each(rep.fails, fn(w) { io.println("      FAIL  " <> w) })
  })
  let total = fold_reports(list.map(results, fn(r) { r.2 }))
  io.println(
    "  "
    <> pad("TOTAL", 34)
    <> "pass="
    <> int.to_string(total.pass)
    <> "  skip="
    <> int.to_string(total.skip)
    <> "  fail="
    <> int.to_string(total.fail),
  )
}

/// Print the categorized residual — the 8 GC files NOT driven green, each with the honest MEASURED
/// reason (mostly runtime type identity: link import matching / call_indirect / funcref RTT).
fn print_residual() -> Nil {
  io.println(
    "  categorized GC residual (NOT driven green — mostly runtime type identity: link import matching, call_indirect subtype check, funcref RTT):",
  )
  list.each(gc_residual, fn(u) { io.println("    " <> pad(u.0, 22) <> u.1) })
}

fn announce_absent() -> Nil {
  io.println(
    "\n[gc-conformance] no fixtures/gc present; run test/carder/conformance/vendor/vendor.sh (needs wasm-tools)",
  )
}

fn pad(s: String, n: Int) -> String {
  case n - string.length(s) {
    gap if gap > 0 -> s <> string.repeat(" ", gap)
    _ -> s <> " "
  }
}
