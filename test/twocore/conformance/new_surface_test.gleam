//// Unit P6-11 — the CAPSTONE backstop (proofs 1–4), the deliberately-authored half of the
//// Phase-6 close. This file confirms, it does not re-derive (D1): the whole-suite SIMD roll-up +
//// the R16 residual audit + the tier sweep are P6-10's (`simd_conformance_test`, `skipcount_test`,
//// `residual_audit_test`, `simd_differential_test`); the per-op runtime microscopes are P6-07/08's;
//// the `.ir` round-trip is P6-02's; the D3a/emit byte-identity is P6-06's. THIS file adds the ONE
//// thing only the terminal unit makes — a small set of programs authored to exercise the new nodes
//// DELIBERATELY, each driven through the REAL shipped deployment profiles so a single mis-lowered
//// op fails on a NAMED program under a NAMED mode rather than diffusely in a ~24k-assert `.wast`.
////
//// ## Proof 1 — SIMD spec-correct end-to-end (I1/I2/I3/I6/I7)
////
//// `simddot` (integer lanes: `v128.const`, `i16x8.splat`, `i32x4.dot_i16x8_s`, the saturating
//// `i16x8.add_sat_s` family, `i32x4.mul`/`max_s`, `extract_lane`), `simdxform` (float lanes:
//// `f32x4.splat`/`mul`/`add`/`sqrt`/`min` with single-rounding + the -0.0/NaN corners, plus
//// `i8x16.shuffle`, `v128.bitselect`, `i32x4.eq` → a lane mask), and `simdmem` (`v128.load`/`store`,
//// `load32_splat`, `store32_lane`/`load32_lane` through the bounds-checked `rt_mem` seam + an OOB
//// `v128.load` → trap). Each exports a SCALAR (an `extract_lane` reduction — capstone Deviation #2)
//// so it rides the exact byte-identical numeric `Outcome` used since Phase 2 while exercising the
//// full lane surface. A mis-lowered lane, a wrong lane order (endianness), a double-rounded `f32x4`
//// lane, or a mis-propagated NaN diverges HERE on a named program. Values are spec-sourced from the
//// vector-instruction semantics and cross-checked against wasmtime 46.0.1 (the baked `.wast` remains
//// the Tier-A oracle; P6-10 drives the ~24.3k `simd_*.wast` `assert_return`s for the full
//// `v128`-in/`v128`-out lane-wise proof — the capstone need not re-derive it).
////
//// ## Proof 2 — memory64 runs (I4/S9)
////
//// `mem64` declares a `(memory i64 1)`, grows past the i32 4 GiB ceiling (O(1) sparse watermark),
//// stores/loads an i64 at byte 2^32+40 (i64 addressing), reads the fresh region past 2^32 as zero,
//// grows beyond the DOCUMENTED page cap (`Binding.mem64_max_pages` = 2^32 pages) → `-1` allocating
//// nothing, and traps `out of bounds memory access` at `byte_len`. The 65537-page grow charges
//// `delta * page_bytes` fuel on success (`rt_mem.mem_grow`, R9 — a legitimate CPU bound), which
//// exceeds the default budget; the memory64 RUNTIME is therefore observed ORTHOGONALLY to the fuel
//// meter (a raised budget on the Safe bindings; `MeterOff` under Unsafe) — exactly as P6-06's e2e
//// used `MeterOff`. The fuel bound itself is proven by the Phase-4 fuel suites, not re-derived here.
//// memory64 ships on `paged` (+ `portable`); the over-cap 64-bit `atomics` edge is P6-08's
//// fail-closed gate (a categorized tier edge, not driven here — Deviation #3).
////
//// ## Proof 3 — cross-module function linking (I5/I6)
////
//// `xlink` (a `.wast` script driven through OUR own `parse_script` — the official `linking.wast` is
//// a categorized parse-skip at the pin, S13/§D, so the backstop is authored IN SCOPE, the P5-12
//// precedent): module `$a` exports two functions; `(register "a" $a)` publishes them as cross-module
//// capabilities; module `$b` imports and CALLS them across instances via the linker-built closure
//// (D3a — a HANDED-IN capability, never an ambient `apply` of an attacker-named `module:atom`). An
//// unsatisfied import fails closed at link time (`assert_unlinkable`). Green under Safe/`cell`, and
//// the report is identical under `unsafe`/`portable` (the cross-module dispatch composes the same).
////
//// ## Proof 4 — conformance-neutral by default (I7)
////
//// A module with no `v128`, one 32-bit memory, and no cross-module imports compiles BYTE-IDENTICALLY
//// to Phase-5 — the IR grew (`TV128`/`ConstV128`/`SimdOp`/`CallImport`) but the defaults route the
//// new surface away. The emitter-level byte-identity is unit P6-06's (`emit_core` test, confirmed
//// green in `gleam test`); THIS file adds the whole-Phase-1..5-corpus behavioural neutrality across
//// the MODE axis: the entire Phase-1..4 acceptance corpus (`combos.corpus_programs`) AND the Phase-5
//// new-surface programs (`reftab`/`bulkmem`/`multimem`) produce the SAME `Outcome` under Safe and
//// Unsafe Phase-6 code. A Phase-6 change that perturbed a Phase-5 result — a `TV128` arm leaking into
//// a numeric match, an effect-analysis miss letting the Aggressive optimizer reorder a legacy state
//// op now that `Simd` joined the pure set (S7), an i64-address plumbing change touching the 32-bit
//// path — would diverge HERE.
////
//// Spec anchors: the vector value/type model and vector-instruction semantics
//// (<https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions>), IEEE-754
//// single-rounding + SIMD NaN propagation (I3); the memory64 proposal + the memory instructions with
//// an i64 address type; §7 embedding + the reference-interpreter `(register …)` mechanism. Every
//// `.expected` value is the spec-sourced Tier-A oracle, so "green" means every spec-observable was
//// preserved, never "it compiled".

import gleam/bit_array
import gleam/list
import gleam/string
import twocore/conformance/driver
import twocore/conformance/ffi
import twocore/conformance/wat_fixture
import twocore/runtime/instance.{type Binding, Binding}
import twocore/runtime/profiles
import twocore/tier/combos

// ─────────────────────────────── the deliberately-authored programs ───────────────────────────────

/// The Phase-5 new-surface programs the capstone re-confirms neutral under Phase-6 (authored `.wat`
/// → `.wasm`, `.expected` spec-sourced): `reftab` (reference & table surface), `bulkmem` (bulk
/// memory), `multimem` (two memories + a cross-memory copy). Kept LOCAL to the conformance corpus
/// (§H — not reached into `combos.corpus_programs`, a Phase-4 const).
const phase5_surface_programs: List(String) = ["reftab", "bulkmem", "multimem"]

/// The capstone-authored SIMD kernels (proof 1), each exporting a SCALAR so it rides the numeric
/// `Outcome` byte-identically across modes/tiers (Deviation #2). `simddot` = integer lanes + dot
/// product + saturating add; `simdxform` = float lanes + shuffle + bitselect; `simdmem` = the v128
/// memory family + an OOB trap. Authored `.wat` (compiled to `.wasm` with `wat2wasm`), `.expected`
/// spec-sourced (cross-checked vs wasmtime).
const simd_kernels: List(String) = ["simddot", "simdxform", "simdmem"]

/// The capstone-authored EXCEPTION-HANDLING backstop (Phase-7 proof 1), each exporting a SCALAR so
/// it rides the byte-identical numeric `Outcome` across modes/tiers while exercising one EH
/// behaviour on a NAMED program (the P6-11 SIMD-kernel discipline, now over EH). Both encodings the
/// frontend decodes into the one neutral IR (T1): `ehthrow` = the LEGACY `try`/`catch` Porffor
/// emits; `ehcatch` = the MODERN `try_table` catch→ENCLOSING-label transfer (the exact IR shape the
/// EH `.wast` run surfaced as the optimizer block-elimination bug — a fixture-independent regression
/// guard); `ehcatchall` = `catch_all` + a non-matching catch's no-match propagation (spec §4.4.9);
/// `ehnested` = nested try_table unwinding to the innermost MATCHING handler; `ehrethrow` = the
/// modern `exnref`/`throw_ref` re-raise (Porffor-inert, spec-only — T9). Values are differential vs
/// wasmtime 46.0.1 (`-W exceptions=y`) for the modern programs; the legacy `ehthrow` is spec-sourced
/// + cross-validated by the official `legacy/throw.wast` (eh_conformance_test).
const eh_backstop_programs: List(String) = [
  "ehthrow", "ehcatch", "ehcatchall", "ehnested", "ehrethrow",
]

/// The REAL shipped deployment profiles the capstone drives every SIMD kernel through — the exact
/// postures a user gets (not a test-capped variant). `safe` = Cell/Paged, Baseline optimizer,
/// enforcing fuel; `unsafe` = the Aggressive optimizer + open runtime (Paged, so the MODE axis is
/// isolated from the tier axis — the tier sweep is P6-10's `simd_differential_test`); `portable` =
/// the tier-P runs-anywhere build (Threaded/Paged/`bif`, Safe). Byte-identity across all three is
/// the I7 neutrality claim over the new surface.
fn shipped_profiles() -> List(#(String, Binding)) {
  [
    #("safe", profiles.safe()),
    #("unsafe", profiles.unsafe()),
    #("portable", profiles.portable()),
  ]
}

/// A per-instance fuel budget large enough for the `mem64` backstop's 65537-page grow, whose
/// success-path charge is `delta * page_bytes = 65537 * 65536 = 4_295_032_832` (`rt_mem.mem_grow`,
/// R9). The default budget (1e9) is deliberately BELOW this — growing 4 GiB of logical memory is
/// real CPU work, a legitimate Safe bound. To observe the memory64 RUNTIME orthogonally to the fuel
/// meter (exactly as P6-06's e2e used `MeterOff`), the Safe `mem64` bindings raise the budget here;
/// the fuel bound itself is proven by the Phase-4 fuel suites, never re-derived. Total, spec-
/// irrelevant: the budget changes no spec-observable answer, only whether the CPU bound fires.
const mem64_fuel: Int = 6_000_000_000

/// The `mem64` mode/state-axis profiles (proof 2). memory64 ships on `paged` (+ `portable`), so the
/// three points vary state strategy × optimizer × mode while holding the memory tier at `Paged` and
/// the fuel meter clear of the large grow: Safe/Cell (raised fuel), Safe/Threaded==portable (raised
/// fuel), and Unsafe (`MeterOff` — the aggressive posture, no fuel). Byte-identity across all three
/// is the memory64 neutrality claim; the over-cap 64-bit `atomics` binding is P6-08's fail-closed
/// categorized tier edge (not a spec divergence — Deviation #3), deliberately not driven here.
fn mem64_profiles() -> List(#(String, Binding)) {
  [
    #("safe·cell", Binding(..profiles.safe(), fuel_budget: mem64_fuel)),
    #(
      "portable·threaded",
      Binding(..profiles.portable(), fuel_budget: mem64_fuel),
    ),
    #("unsafe", profiles.unsafe()),
  ]
}

// ─────────────────────────────── proof 1 — SIMD end-to-end ───────────────────────────────

/// PROOF 1 (SIMD spec-correct end-to-end). Every SIMD kernel is spec-correct against its
/// spec-sourced `.expected` under `safe`/`unsafe`/`portable` AND byte-identical across the three. A
/// per-profile spec violation (a wrong lane, a double-rounded `f32x4`, a mis-endianned `v128.store`,
/// a missing OOB trap) OR a cross-profile divergence (the Aggressive optimizer mis-folded a pure
/// `Simd`, reordered an effectful `SimdStore`, or a tier changed a memory image) fails naming the
/// exact program + profile. This is the fine-grained backstop behind P6-10's whole-suite SIMD run.
pub fn simd_kernels_spec_correct_and_profile_neutral_test() {
  let failures =
    list.flat_map(simd_kernels, check_across_profiles(_, shipped_profiles()))
  assert failures == []
}

// ─────────────────────────────── Phase-7 proof 1 — EH engine (deliberately-authored backstop) ───────────────────────────────

/// PHASE-7 PROOF 1 (EH engine spec-correct end-to-end — the deliberately-authored backstop). Every
/// EH kernel is spec-correct against its `.expected` (differential vs wasmtime 46.0.1 for the modern
/// programs; the legacy `ehthrow` cross-validated by the official `legacy/throw.wast`) under
/// `safe`/`unsafe`/`portable` AND byte-identical across the three — because EH is BEAM-native control
/// flow that neither reads nor writes instance state, so it is invariant across the state strategy
/// (Cell in safe/unsafe, Threaded in portable — the state-free EH surface runs anywhere; the T6
/// Cell-only bound is only the state-threaded-through-throw combo, which these do not exercise). A
/// mis-lowered re-raise, a wrong catch-clause order, a lost payload, an eliminated block broken to
/// from a catch handler (the fixed optimizer bug), or a cross-profile divergence fails naming the
/// exact program + profile. This is the fine-grained backstop behind eh_conformance_test's official
/// `.wast` run (the P6-11 kernel/whole-suite division, now over EH).
pub fn eh_backstop_spec_correct_and_profile_neutral_test() {
  let failures =
    list.flat_map(eh_backstop_programs, check_across_profiles(
      _,
      shipped_profiles(),
    ))
  assert failures == []
}

// ─────────────────────────────── proof 2 — memory64 runs ───────────────────────────────

/// PROOF 2 (memory64 runs). The `mem64` program is spec-correct against its `.expected` under
/// Safe/Cell, portable/Threaded, and Unsafe (fuel raised clear of the large grow — see `mem64_fuel`)
/// AND byte-identical across the three: i64 addressing past 2^32, a store/load at byte 2^32+40, the
/// fresh region reading zero, a grow beyond the documented page cap → -1, and an access beyond the
/// current size → trap `out of bounds memory access`. A mis-threaded i64 address, a wrong cap
/// boundary, a missing OOB trap, or a state-strategy divergence fails naming the exact profile.
pub fn mem64_runtime_spec_correct_and_profile_neutral_test() {
  let failures = check_across_profiles("mem64", mem64_profiles())
  assert failures == []
}

// ─────────────────────────────── proof 3 — cross-module function linking ───────────────────────────────

/// PROOF 3 (cross-module function linking). The authored `xlink.wast` — module `$b` imports and
/// CALLS module `$a`'s exported functions across instances via the linker-built closure (D3a), and
/// an unsatisfied import fails closed at link time (`assert_unlinkable`) — runs GREEN (fail == 0,
/// every assert a pass) under `safe`/`unsafe`/`portable`, with an IDENTICAL report across the three
/// (the cross-module dispatch composes the same regardless of optimizer/state strategy). The official
/// `linking.wast` is a categorized parse-skip at the pin (S13); this in-scope backstop is the P5-12
/// precedent — authored to prove the cross-module dispatch on purpose.
pub fn cross_module_linking_spec_correct_and_profile_neutral_test() {
  let text = read_corpus_wast("xlink")
  let reports =
    list.map(shipped_profiles(), fn(p) {
      let #(label, binding) = p
      #(label, wat_fixture.run_wat_text(driver.pipeline_with(binding), text))
    })

  // (1) each profile: the whole script is green (no false green; every assert a real pass).
  let spec_failures =
    list.flat_map(reports, fn(r) {
      let #(label, rep) = r
      case rep.fail == 0 && rep.pass > 0 && rep.skip == 0 {
        True -> []
        False -> [
          "xlink ["
          <> label
          <> "]: pass="
          <> string.inspect(rep.pass)
          <> " skip="
          <> string.inspect(rep.skip)
          <> " fail="
          <> string.inspect(rep.fail)
          <> " fails="
          <> string.inspect(rep.fails)
          <> " skips="
          <> string.inspect(rep.skips),
        ]
      }
    })

  // (2) the report is identical across profiles (the neutral cross-module dispatch).
  let neutrality_failures = case reports {
    [] -> []
    [#(_, base), ..rest] ->
      list.flat_map(rest, fn(r) {
        let #(label, rep) = r
        case
          #(rep.pass, rep.skip, rep.fail) == #(base.pass, base.skip, base.fail)
        {
          True -> []
          False -> [
            "xlink ["
            <> label
            <> " ≢ safe oracle]: report differs across profiles",
          ]
        }
      })
  }

  assert list.append(spec_failures, neutrality_failures) == []
}

// ─────────────────────────────── proof 4 — conformance-neutral (Phase-1..5) ───────────────────────────────

/// PROOF 4 (conformance-neutral, MODE axis, Phase-1..5). The entire Phase-1..4 acceptance corpus
/// (`combos.corpus_programs` — pure-numeric, memory, table, global, trap) AND the Phase-5
/// new-surface programs (`reftab`/`bulkmem`/`multimem`) produce the SAME `Outcome` under Safe and
/// Unsafe Phase-6 code, each matching its spec-sourced `.expected`. A Phase-6 change that perturbed a
/// Phase-1..5 result would diverge HERE. Together with unit P6-06's emitter byte-identity and P6-10's
/// whole-suite pass-rise, this is the behavioural half of I7 (the SIMD/mem64/xlink defaults route the
/// new surface away — no `Simd*` node, `Idx32` memory, no `CallImport` closure). The `portable`-vs-
/// `cell/paged` corpus neutrality is Phase-4's `runs_anywhere_test`, still green.
pub fn phase_1_to_5_corpus_conformance_neutral_test() {
  let corpus = list.append(combos.corpus_programs, phase5_surface_programs)
  let failures =
    list.flat_map(corpus, fn(name) {
      check_two_profiles(
        name,
        profiles.safe(),
        "safe",
        profiles.unsafe(),
        "unsafe",
      )
    })
  assert failures == []
}

/// PROOF 4 (Phase-5 surface still green end-to-end under Phase-6). The reference/table, bulk-memory,
/// and multi-memory programs — the Phase-5 close's proof-1 backstop — remain spec-correct against
/// their `.expected` and byte-identical across `safe`/`unsafe`/`portable` under Phase-6 code. This
/// re-confirms Phase 6 did not regress the Phase-5 surface (the neutrality claim's positive half:
/// the Phase-5 nodes still execute identically, not merely that legacy numerics are unperturbed).
pub fn phase5_surface_still_neutral_under_phase6_test() {
  let failures =
    list.flat_map(phase5_surface_programs, check_across_profiles(
      _,
      shipped_profiles(),
    ))
  assert failures == []
}

// ─────────────────────────────── shared machinery ───────────────────────────────

/// Drive `name` under every profile in `profiles`, collecting (1) per-profile spec-correctness
/// failures and (2) cross-profile byte-identity failures (baseline = the first profile). Empty ⇒
/// green. The `.wasm`/`.expected` are read from the conformance corpus by `combos.evaluate`.
fn check_across_profiles(
  name: String,
  profiles: List(#(String, Binding)),
) -> List(String) {
  let runs =
    list.map(profiles, fn(p) {
      let #(label, binding) = p
      let #(outcomes, fails) =
        combos.evaluate(driver.pipeline_with(binding), name)
      #(label, outcomes, fails)
    })
  let spec_failures = list.flat_map(runs, fn(r) { r.2 })
  let identity_runs = list.map(runs, fn(r) { #(r.0, r.1) })
  list.append(spec_failures, combos.identity_across(name, identity_runs))
}

/// Drive `name` under two named profiles, asserting spec-correctness under each and byte-identity
/// between them — the corpus-neutrality workhorse for `phase_1_to_5_corpus_conformance_neutral_test`.
fn check_two_profiles(
  name: String,
  a: Binding,
  a_label: String,
  b: Binding,
  b_label: String,
) -> List(String) {
  let #(a_outs, a_fails) = combos.evaluate(driver.pipeline_with(a), name)
  let #(b_outs, b_fails) = combos.evaluate(driver.pipeline_with(b), name)
  list.flatten([
    a_fails,
    b_fails,
    case a_outs == b_outs {
      True -> []
      False -> [
        name
        <> " ["
        <> b_label
        <> " ≢ "
        <> a_label
        <> " oracle]: "
        <> string.inspect(a_outs)
        <> " vs "
        <> string.inspect(b_outs),
      ]
    },
  ])
}

/// Read a `corpus/<name>.wast` script as text (the cross-module `xlink` backstop is a multi-module
/// `.wast`, not a single `.wasm`, so it drives through `wat_fixture.run_wat_text`, not the binary
/// `combos.evaluate` path). `let assert` documents that the capstone-owned fixture is always present.
fn read_corpus_wast(name: String) -> String {
  let assert Ok(bytes) =
    ffi.read_file("test/twocore/conformance/corpus/" <> name <> ".wast")
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}
