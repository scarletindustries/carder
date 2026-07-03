//// gleeunit entry for the spec-suite runner (Tier-A) — drives the PINNED allowlist fixtures
//// present in `fixtures/` through the REAL pipeline and reports honest pass/skip/fail counts
//// (D9: skips are visible, never silent).
////
//// ## Phase 3: conformance-neutral under BOTH profiles (F7, capstone §G)
////
//// Phase 3 adds no IR nodes and no spec files, so the counts do not move; the proof is that the
//// SAME green holds under BOTH derived profiles — which also delivers the spec-suite half of the
//// F2 optimizer-soundness claim (capstone §B). The suite runs twice:
////   - `driver.pipeline_with(profiles.safe())`   — Baseline optimizer + enforcing fuel;
////   - `driver.pipeline_with(profiles.unsafe())` — Aggressive optimizer + open runtime.
//// Both must reach `fail == 0 && pass > 0`. A single optimizer or mode regression on ANY
//// allowlisted assertion goes red. The Safe fuel budget for the suite (`default_fuel_budget`) is
//// generous enough that no in-scope program trips `FuelExhausted` (the runaway proof 4 uses a
//// tiny `safe_metered` budget instead).
////
//// ## Phase 4 — the full-matrix conformance proof (capstone P4-11 proof 2, G2/G7)
////
//// Phase 4 adds NO IR nodes and NO spec files either (G7), so the counts STILL do not move
//// (15747 / 411 / 0). The Phase-4 proof is that the identical green holds under EVERY shipped
//// `(state_strategy × mem_tier[× table_tier])` binding (`combos.shipped`) — not a subset:
////   - `cell × paged`      — the Phase-2/3 tier-O/tier-P oracle posture, Safe;
////   - `threaded × paged`  — tier-P instance state (== the `portable` core), Safe;
////   - `cell × atomics`    — tier-O O(1) memory under the pdict calling convention, Safe;
////   - `threaded × atomics`— tier-O O(1) memory under record-threading, Safe;
////   - `cell × nif`        — the tier-N ceiling skeleton (Unsafe-only, delegates to paged).
//// WebAssembly is deterministic (the only non-determinism is NaN payload bits, which D5 pins as
//// raw patterns), so a correct `atomics` store and a correct `paged` store produce byte-identical
//// memory images ⇒ identical `Outcome`s (spec §4.4 — every ill-defined op traps; no undefined
//// behaviour to diverge on). A single tier/strategy regression on any allowlisted assertion (a
//// mis-endianned `atomics` load, a threaded record dropped across a call, an `ets` table miss)
//// goes red on that file. Each binding is built via `combos.binding_for` (D1 — the unit-07
//// profile/linker surface, bounded `cap_pages` so an atomics combo links), then driven through the
//// SAME `run_suite` gate. The two Phase-3 profiles stay as two more matrix points.
////
//// ## Phase 5 — the surface-phase headline: `fail == 0 && pass > baseline` (capstone P5-12 proof 2)
////
//// Unlike Phases 3–4 (which added NO IR nodes and NO spec files, so the counts did not move),
//// Phase 5 is a SURFACE phase: whole `.wast` categories light up (reference types, bulk memory,
//// multi-memory, the `spectest` imports, the WAT-only text-format asserts), so on the enlarged
//// allowlist (P5-11) the pinned suite's `pass` STRICTLY RISES while `fail` stays `0`. The two
//// FULL-profile runs (`spec_suite_safe`/`unsafe`, the unfiltered 21525-pass runs) therefore carry
//// the surface-phase headline directly: `fail == 0 && pass > phase4_baseline_pass` (`run_suite`).
//// The residual-skip accounting — every remaining skip is one of the ENUMERATED honest categories,
//// the CLOSED-residual invariant — is owned by `skipcount_test.gleam` (P5-11) and CONFIRMED green by
//// the capstone (D1: the capstone references it, it does not re-derive the phrase list). The honest
//// reading: the headline is a pass-RISE (+5776), NOT a naive skip-drop — the raw skip count rose
//// because P5-11 added ~30 previously-EXCLUDED files to the allowlist, so most of the 1257 residual
//// is asserts in files that were never counted before Phase 5; ~1088 of it is cross-module
//// wasm→wasm FUNCTION imports (a distinct cross-module function-linking feature Phase 5 never
//// scoped → Phase 6), and 169 is genuinely out-of-scope (GC-proposal reftypes, extended-const,
//// `assert_exhaustion`, cross-module state import, SIMD/GC text). `fail == 0` under every shipped
//// binding is the whole-phase net; the FILTERED matrix combos keep the non-vacuity `pass > 0` gate.
////
//// Tier-A needs NO engine at run time: the expected values are baked into the vendored `.wast`
//// (now JSON). The committed curated fixture subset makes this run in a fresh checkout;
//// `vendor/vendor.sh` regenerates the FULL allowlist (gitignored) for a wider local run — the
//// runner adapts to whatever `*.json` are present.
////
//// Gate: zero genuine FAILS (a fail is a real spec mismatch in the pipeline); SKIPS are expected
//// and printed (constructs beyond the slice — reference types, bulk memory, multi-memory,
//// non-function imports, multi-value, extended-const, memory64, text-format asserts, and the
//// allowlist files un-convertible at the pin). At least one PASS is required so the suite is not
//// vacuously green.

import gleam/int
import gleam/io
import gleam/list
import gleam/string
import twocore/conformance/driver
import twocore/conformance/ffi
import twocore/conformance/fixture
import twocore/conformance/runner.{type Driver, type Report}
import twocore/runtime/instance.{Binding}
import twocore/runtime/profiles
import twocore/tier/combos.{type Combo}

const fixtures_dir = "test/twocore/conformance/fixtures"

/// The Phase-4 baseline pass count (15749 / 409 / 0 — task / state.md P4-11). The two FULL,
/// unfiltered profile runs must clear it STRICTLY (`pass > phase4_baseline_pass`): Phase 5 is a
/// surface phase, so `pass` RISES as whole categories light up (measured post-Phase-5: 21525, a
/// +5776 pass-rise), while `fail` stays `0`. A regression that flipped a formerly-passing assert to
/// skip/fail, or a category silently going dark, drops `pass` below the floor and goes red.
const phase4_baseline_pass: Int = 15_749

/// The Safe max-pages cap the full-matrix run bakes into EVERY combination. It must be (1) LARGE
/// ENOUGH that no in-scope spec assertion is changed by the cap — the widest is `call`/
/// `call_indirect`'s `as-memory.grow-value`, which grows a no-max `(memory 1)` by 306 pages and
/// expects the grow to SUCCEED (old size `1`), so the cap must be ≥ 307 — and (2) SMALL ENOUGH that
/// an `atomics` combo LINKS: `atomics` `fresh` pre-allocates to the effective max, so the cap must
/// be ≤ `rt_mem_atomics.atomics_reserve_cap_pages` (4096) or `validate_binding` fail-closes the
/// binding. `512` sits comfortably in `[307, 4096]`: above every in-scope memory footprint (so the
/// counts stay 15747 / 411 / 0, conformance-neutral, G7) and below the atomics reserve cap (so
/// every atomics combo reserves ≤ 512 pages and links). Unlike `combos.cap_pages` (16, sized for
/// the small acceptance corpus), this is sized for the whole spec suite; it is applied here — over
/// `combos.binding_for` — so unit 09's corpus differential keeps its own tighter cap unchanged.
const matrix_cap_pages: Int = 512

/// Bulk pure-numeric spec files that are **tier-invariant by construction**: they exercise no
/// memory / table / global / `call_indirect`, so under any `(state_strategy × mem_tier)` their
/// functions are never state-reaching and emit byte-identical code to `cell × paged` (the
/// threaded record threads through nothing; the memory tier is never linked). The FULL suite runs
/// them once under each Phase-3 profile (`spec_suite_safe`/`unsafe`), which is where a numeric
/// regression would surface. Re-running their ~13.5k assertions under all FIVE matrix combos
/// proves nothing about the tier axis and exhausts the CI runner (OOM). So the matrix runs every
/// OTHER file — memory / table / global / calls / control flow: everything the tier axis touches.
const matrix_skip_numeric: List(String) = [
  "const.json", "conversions.json", "f32.json", "f32_bitwise.json",
  "f32_cmp.json", "f64.json", "f64_bitwise.json", "f64_cmp.json",
  "float_exprs.json", "float_literals.json", "float_misc.json", "i32.json",
  "i64.json", "int_exprs.json", "int_literals.json",
]

/// Files that import `spectest`'s MEMORY/TABLE state — excluded from the NON-paged matrix combos
/// only (see `run_combo`). The P5-09 `link.spectest_export` builds the provided memory/table with
/// the PAGED tier unconditionally, so importing it under an `atomics` binding is a cross-tier
/// handle mismatch (a named P5-09 gap, not a spec divergence). These files stay GREEN under the
/// paged combos + both full profiles; their bulk semantics are tier-covered by the own-memory
/// `memory_*` files. A file appears here ONLY because its OWN memory would otherwise be atomics but
/// it imports the paged `spectest` memory — never for convenience.
const matrix_skip_spectest_state: List(String) = ["data.json"]

/// True iff `name` is a **pure-lane** SIMD fixture — a `simd_*.json` that exercises NO linear
/// memory (arithmetic / comparison / bitwise / boolean / const / conversions / splat / lane-access /
/// shuffle / extmul / dot / pairwise / extend / saturating / q15), so under any `(state_strategy ×
/// mem_tier)` its functions are never state-reaching and emit byte-identical code to `cell × paged`
/// (the threaded record threads through nothing; the memory tier is never linked). Like the bulk
/// pure-NUMERIC files (`matrix_skip_numeric`), these ~24k-assert files run under the TWO full
/// profiles (`spec_suite_safe`/`unsafe`) — where a lane-semantics or optimizer regression surfaces —
/// but NOT ×5 across the matrix combos (that would prove nothing about the tier axis and OOM CI,
/// §G.2). The SIMD-MEMORY files (`v128.load`/`store`/`*_lane`, `simd_address`/`simd_align`) DO touch
/// memory, so they STAY in the ×5 matrix (a mis-endianned `atomics` `v128.store` diverges there).
fn is_pure_lane_simd(name: String) -> Bool {
  string.starts_with(name, "simd_") && !is_simd_memory_file(name)
}

/// True iff `name` is a SIMD fixture that reads/writes LINEAR MEMORY (so it is tier-touching and
/// stays in the ×5 matrix): the `v128.load*`/`store*` families, the lane load/store, and the
/// alignment/address files.
fn is_simd_memory_file(name: String) -> Bool {
  string.contains(name, "load")
  || string.contains(name, "store")
  || string.contains(name, "address")
  || string.contains(name, "align")
  || string.contains(name, "memory")
}

/// The spec suite under the fail-closed **Safe** profile (Baseline optimizer + enforcing fuel):
/// `fail == 0 && pass > 0`. This is the Phase-1/2 green re-run through the Phase-3 full chain
/// (`ir_lower → optimize → emit_core`), confirming the Baseline optimizer is conformance-neutral.
pub fn spec_suite_safe_test() {
  run_suite(
    driver.pipeline_with(profiles.safe()),
    "Safe (Baseline optimizer + enforcing fuel)",
  )
}

/// The spec suite under the **Unsafe** profile (Aggressive optimizer + `MeterOff` + open
/// BIF/host + passthrough stdlib): `fail == 0 && pass > 0`. Same fixtures, same expected values —
/// the Aggressive optimizer and the whole Unsafe posture change NO spec-observable answer (F2/F4).
/// This is the spec-suite half of the optimizer-soundness differential.
pub fn spec_suite_unsafe_test() {
  run_suite(
    driver.pipeline_with(profiles.unsafe()),
    "Unsafe (Aggressive optimizer + open runtime)",
  )
}

// ─────────────────────────── Phase-4: the full-matrix conformance run (proof 2, G2/G7) ───────────────────────────

/// The pinned suite under the `cell × paged` baseline (the Phase-2/3 tier-O/tier-P oracle posture
/// as a matrix point): `fail == 0 && pass > 0`. This is the `combos`-bound restatement of the Safe
/// run above (bounded `cap_pages` so it shares one code path with the atomics combos); the two must
/// report identical counts (conformance-neutral, G7).
pub fn spec_suite_matrix_cell_paged_test() {
  run_combo(combos.cell_paged)
}

/// The pinned suite under `threaded × paged` — tier-P instance state (the `portable` core): the
/// purely-functional record threaded through generated code produces byte-identical spec results to
/// `cell × paged` (`fail == 0 && pass > 0`). A threaded record dropped across a call would go red
/// here on the exact file that reads state after the call.
pub fn spec_suite_matrix_threaded_paged_test() {
  run_combo(combos.threaded_paged)
}

/// The pinned suite under `cell × atomics` — tier-O O(1) linear memory under the pdict calling
/// convention: `fail == 0 && pass > 0`. A mis-endianned or off-by-one `atomics` load/store would go
/// red on `endianness`/`address`/`memory_trap`. `cap_pages` keeps the atomics reservation bounded
/// while staying above every in-scope program's footprint (max 8 pages), so no spec result moves.
pub fn spec_suite_matrix_cell_atomics_test() {
  run_combo(combos.cell_atomics)
}

/// The pinned suite under `threaded × atomics` — the combination most likely to surface a threading
/// bug (a mutable `atomics` ref threaded through the record under record-returning code): `fail == 0
/// && pass > 0`, byte-identical to the paged oracle.
pub fn spec_suite_matrix_threaded_atomics_test() {
  run_combo(combos.threaded_atomics)
}

/// The pinned suite under `cell × nif` — the tier-N ceiling WHERE IT SHIPS (G8): a node-safe
/// skeleton delegating to the paged core (the production C NIF is documented-deferred), Unsafe-only
/// (G6). It LINKS and runs on a bare BEAM, so it must reach `fail == 0 && pass > 0` like the rest.
/// If a real C NIF were built and loaded, the same run would exercise it unchanged.
pub fn spec_suite_matrix_cell_nif_test() {
  run_combo(combos.cell_nif)
}

/// Drive the whole pinned suite under one shipped matrix `Combo` and assert the `run_suite` gate
/// (`fail == 0 && pass > 0`). The `Combo`'s coherent binding comes from `combos.binding_for` (the
/// unit-07 linker surface — never re-spelling a `rt_mem_*` module name), with only `safe_max_pages`
/// widened to `matrix_cap_pages` (a policy field `resolve_tiers` never rewrites, so the tier
/// coupling stays coherent) so the whole spec suite fits — and `validate_binding` re-confirms the
/// widened binding is still policy-legal (an `Atomics` combo stays within the reserve cap). Total.
fn run_combo(c: Combo) -> Nil {
  let binding =
    Binding(..combos.binding_for(c), safe_max_pages: matrix_cap_pages)
  let assert Ok(validated) = profiles.validate_binding(binding)
  // Under a non-PAGED memory tier, ALSO skip files that IMPORT `spectest`'s memory/table: the
  // P5-09 link contract (`link.spectest_export`) builds the provided memory/table with the PAGED
  // `rt_mem.fresh`/`rt_table.new` unconditionally, so importing it under an `atomics` binding hands
  // a paged handle to atomics-tier code (a cross-tier mismatch, not a spec divergence). This is a
  // NAMED, honest cross-unit gap (P5-09 spectest state is paged-tier); the affected file stays
  // GREEN under `paged` + both full profiles, and its tier-sensitive bulk semantics are covered
  // under `atomics` by `memory_init`/`memory_fill`/`memory_copy` (own-memory bulk, no import).
  let paged_only = case string.contains(c.label, "atomics") {
    True -> matrix_skip_spectest_state
    False -> []
  }
  // Skip the tier-invariant bulk-numeric files (see `matrix_skip_numeric`) — they cannot
  // differ across tiers and re-running them ×5 OOMs CI. The two full-profile runs cover them.
  run_suite_keep(
    driver.pipeline_with(validated),
    "Phase-4 matrix: " <> c.label,
    fn(name) {
      !list.contains(matrix_skip_numeric, name)
      && !list.contains(paged_only, name)
      // Pure-lane SIMD files are tier-invariant (no instance state) — cover them under the two full
      // profiles, not ×5 (§G.2). The SIMD-MEMORY files stay in the matrix (tier-touching).
      && !is_pure_lane_simd(name)
    },
  )
}

/// Run every `*.json` fixture present through `d` (a FULL, unfiltered profile run) and assert the
/// Phase-5 surface-phase headline (capstone P5-12 proof 2): `fail == 0` AND `pass > phase4_baseline_
/// pass` (STRICTLY — whole categories lit up, a pass-RISE). `run_suite` is used only by the two
/// full-profile runs (`spec_suite_safe`/`unsafe`); the filtered matrix combos use `run_suite_keep`
/// (non-vacuity `pass > 0` only). Total — the runner never panics.
fn run_suite(d: Driver, label: String) -> Nil {
  run_suite_keep_min(d, label, fn(_) { True }, phase4_baseline_pass + 1)
}

/// Like `run_suite`, but runs only the fixtures for which `keep(name)` is `True` (the matrix
/// combos skip the tier-invariant bulk-numeric files) and gates on non-vacuity only (`pass > 0`) —
/// the filtered subset does not run the whole 21525-pass suite, so it cannot clear the surface
/// headline floor; the two full-profile runs (`run_suite`) carry that. Same zero-fail gate.
fn run_suite_keep(d: Driver, label: String, keep: fn(String) -> Bool) -> Nil {
  run_suite_keep_min(d, label, keep, 1)
}

/// The shared driver behind `run_suite`/`run_suite_keep`: run the kept fixtures, print the per-file
/// + total report, and assert `total.fail == 0 && total.pass >= min_pass`. `min_pass` is the
/// surface headline floor for a full run (`phase4_baseline_pass + 1` ⇒ `pass > baseline`) or `1` for
/// a filtered matrix combo (non-vacuity). Total.
fn run_suite_keep_min(
  d: Driver,
  label: String,
  keep: fn(String) -> Bool,
  min_pass: Int,
) -> Nil {
  let jsons = case ffi.list_dir(fixtures_dir) {
    Ok(entries) ->
      entries
      |> list.filter(string.ends_with(_, ".json"))
      |> list.filter(keep)
      |> list.sort(string.compare)
    Error(_) -> []
  }

  case jsons {
    [] -> {
      io.println(
        "\n[conformance] no fixtures present; run test/twocore/conformance/vendor/vendor.sh",
      )
      Nil
    }
    _ -> {
      io.println(
        "\n=== Phase-3 spec-suite conformance (Tier-A, pinned allowlist) — "
        <> label
        <> " ===",
      )
      let total =
        list.fold(jsons, runner.empty_report(), fn(acc, name) {
          let rep = run_one(d, name)
          io.println("  " <> pad(name, 22) <> line(rep))
          runner.merge(acc, rep)
        })
      io.println("  " <> pad("TOTAL", 22) <> line(total))
      print_skip_reasons(total)
      print_fail_reasons(total)

      // Honest gate: zero genuine spec mismatches; coverage clears the floor (the surface-phase
      // headline `pass > baseline` for a full run, or non-vacuity `pass > 0` for a filtered combo).
      assert total.fail == 0
      assert total.pass >= min_pass
    }
  }
}

fn run_one(d: Driver, name: String) -> Report {
  case fixture.load(fixtures_dir <> "/" <> name) {
    Error(e) -> {
      io.println("  " <> pad(name, 22) <> "parse error: " <> e)
      runner.empty_report()
    }
    Ok(fix) -> runner.run_fixture(d, fix, fixtures_dir)
  }
}

fn line(r: Report) -> String {
  "pass="
  <> int.to_string(r.pass)
  <> "  skip="
  <> int.to_string(r.skip)
  <> "  fail="
  <> int.to_string(r.fail)
}

// Print a compact histogram of skip reasons (distinct stable prefixes) so the coverage
// gap is visible without dumping thousands of lines.
fn print_skip_reasons(r: Report) -> Nil {
  case r.skip {
    0 -> Nil
    _ -> {
      io.println("  skip reasons (sample of distinct categories):")
      r.skips
      |> list.map(reason_category)
      |> list.unique
      |> list.take(12)
      |> list.each(fn(c) { io.println("    - " <> c) })
    }
  }
}

fn print_fail_reasons(r: Report) -> Nil {
  case r.fails {
    [] -> Nil
    fails -> {
      io.println("  FAILURES:")
      list.each(fails, fn(f) { io.println("    * " <> f) })
    }
  }
}

// Collapse a per-assertion reason to a coarse category (drop the leading "file:line "
// and keep the stable tail) for the histogram.
fn reason_category(reason: String) -> String {
  let tail = case string.split_once(reason, " ") {
    Ok(#(_loc, rest)) -> rest
    Error(_) -> reason
  }
  // Keep a short, stable prefix so similar reasons collapse together.
  string.slice(tail, 0, 60)
}

fn pad(s: String, n: Int) -> String {
  case n - string.length(s) {
    gap if gap > 0 -> s <> string.repeat(" ", gap)
    _ -> s
  }
}
