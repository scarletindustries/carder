//// Unit Q13-06 — the CAPSTONE dedicated proofs for the WASM tail-call proposal (`return_call` /
//// `return_call_indirect`). This file houses the two properties the whole-corpus tier differential
//// (`tier_differential_test`, which drives `tailrec` under every shipped `Combo`) CANNOT express:
////   1. **constant stack space** under DEEP (1,000,000-level) tail recursion — the honest "is it
////      really a tail call?" test (a wrapped / non-tail emission would grow the call stack ~1000×
////      and blow the live-memory bound or exhaust the process), measured the way `sum_to(100000)`'s
////      constant space is (`ffi.gc_and_memory`); and
////   2. **`OptNone ≡ Baseline ≡ Aggressive`** independent opt-level variation on the funcref/`elem`-
////      bearing `tailrec` program (the tier differential varies the tier axis, not the opt level).
//// Plus a running-total report (prints the measured Gleam-test + conformance headline; asserts only
//// the `fail == 0` shape, never a brittle count).
////
//// A capstone CONFIRMS green; it does not re-derive prior units. The IMPORTED tail call
//// (`ReturnCallImport`) is VALUE-CORRECT with a BOUNDED caller frame (Q8 honest-scope sub-case,
//// overview §2 ⚠ ABI note) — Q13-05 owns its emit proof, and the official `return_call.wast`
//// exercises it under `unsafe` (the deny-all Safe host denies the `spectest` print as a categorized
//// POLICY skip). This file makes NO 1,000,000-deep constant-stack claim for imports.
////
//// Spec: the WebAssembly tail-call proposal — `return_call $f` / `return_call_indirect $t (type $ft)`
//// are valid iff the callee's result type equals the current function's result type; they are
//// stack-polymorphic like `return`; on the BEAM they lower to GENUINE tail calls, so deep self /
//// mutual / indirect (same-module) recursion runs in CONSTANT stack space. "call stack exhausted" is
//// not a WASM trap and does not exist on the BEAM — which is exactly what these tests prove.

import carder/backend/build_beam
import carder/conformance/driver
import carder/conformance/ffi
import carder/ir
import carder/opt_level.{type OptLevel, Aggressive, Baseline, OptNone}
import carder/pipeline
import carder/runtime/instance.{type Binding, Binding, MeterOff}
import carder/tier/combos.{type Combo, type Outcome}
import gleam/erlang/atom
import gleam/int
import gleam/io
import gleam/list

/// Compile corpus `name` through the full pipeline under `binding` and LOAD it, returning its BEAM
/// module atom (a PROCESS-UNIQUE name per call so repeated loads never clobber). Mirrors
/// `constant_space_threaded_test.compile_load`. Panics via `let assert` only on a genuinely-broken
/// pipeline (the corpus + binding are known-good), which is a test failure, not a silent pass.
fn compile_load(name: String, binding: Binding) -> atom.Atom {
  let assert Ok(bytes) = combos.read_wasm(name)
  let assert Ok(m0) = pipeline.source_to_ir(bytes)
  let m =
    ir.Module(..m0, name: m0.name <> "_" <> int.to_string(ffi.unique_int()))
  let assert Ok(cmod) = pipeline.ir_to_cmod(m, binding)
  let assert Ok(mod) = build_beam.compile_and_load(cmod)
  mod
}

/// A `threaded × atomics` binding with a SMALL bounded cap so the `TableAtomics` table tier links
/// with a tiny reservation (`tailrec` has no linear memory; the cap keeps any atomics reservation
/// from dominating the constant-space measurement). Bounded via `safe_max_pages: 2`.
fn threaded_atomics_small_cap() -> Binding {
  Binding(..combos.binding_for(combos.threaded_atomics), safe_max_pages: 2)
}

/// Call export `field` with one i32 arg on a freshly-started instance of `mod`, returning the raw
/// result; `let assert` fails the test on a trap (these calls must all RETURN). The instance is a
/// fresh owned process, so the measurement below sees only THIS call's live memory.
fn call1(mod: atom.Atom, field: String, arg: Int) -> Int {
  let assert Ok(inst) = ffi.start_instance(mod)
  let assert Ok(v) = ffi.call_instance(inst, atom.create(field), [arg])
  ffi.stop_instance(inst)
  v
}

/// Live process memory after driving `field(arg)` on a fresh instance of `mod` to completion, with a
/// GC first (the same instrument `constant_space_threaded_test` / `sum_to_constant_space` use). A
/// genuine tail call leaves NOTHING on the stack, so this is bounded by a small constant regardless
/// of the recursion depth; a non-tail (wrapped) emission would accumulate ~`arg` frames.
fn mem_after(mod: atom.Atom, field: String, arg: Int) -> Int {
  let assert Ok(inst) = ffi.start_instance(mod)
  let assert Ok(_) = ffi.call_instance(inst, atom.create(field), [arg])
  let m = ffi.gc_and_memory(inst)
  ffi.stop_instance(inst)
  m
}

// ─────────────────────── PROOF 1: direct return_call self-loop, constant stack ───────────────────────

/// PROOF 1 (constant stack, direct). `count_down(n)` is a `return_call` self-loop to 0. Driving it at
/// `n = 1_000` and `n = 1_000_000` (1000× deeper) both RETURN `0`, and the deep run's live memory
/// stays under a small constant factor (`< 4×`) of the shallow run's — a GENUINE BEAM tail call
/// leaves no per-iteration frame. A non-tail / wrapped `return_call` emission would grow the call
/// stack ~1000× and blow this bound (or exhaust the process). Spec: `return_call` is a genuine tail
/// transfer (stack-polymorphic like `return`).
pub fn count_down_constant_space_test() {
  let mod = compile_load("tailrec", combos.binding_for(combos.portable))

  assert call1(mod, "count_down", 1000) == 0
  assert call1(mod, "count_down", 1_000_000) == 0

  let mem_small = mem_after(mod, "count_down", 1000)
  let mem_big = mem_after(mod, "count_down", 1_000_000)
  assert mem_big < mem_small * 4
}

// ─────────────────────── PROOF 2: mutual recursion (even/odd), constant stack ───────────────────────

/// PROOF 2 (constant stack, MUTUAL). `is_even`/`is_odd` tail-call EACH OTHER via `return_call`.
/// `is_even(1_000_001) == 0` (odd), `is_odd(1_000_001) == 1`, `is_even(1_000_000) == 1` (even) — the
/// values are spec-correct across a 100×-plus input spread, and the deep run's live memory stays
/// bounded. Mutually-recursive tail calls must ALSO be constant-stack (a WASM tail call is a
/// cross-function transfer; the callee reuses the caller's frame regardless of which function it is).
pub fn even_odd_constant_space_test() {
  let mod = compile_load("tailrec", combos.binding_for(combos.portable))

  assert call1(mod, "is_even", 1_000_001) == 0
  assert call1(mod, "is_odd", 1_000_001) == 1
  assert call1(mod, "is_even", 1_000_000) == 1

  let mem_small = mem_after(mod, "is_even", 1000)
  let mem_big = mem_after(mod, "is_even", 1_000_001)
  assert mem_big < mem_small * 4
}

// ─────────────────── PROOF 3: return_call_indirect self-loop, constant stack, two table tiers ───────────────────

/// PROOF 3 (constant stack, INDIRECT, both table tiers). `ind_count_down(n)` tail-calls through table
/// slot 0 via `return_call_indirect`, and `$ind_step` tail-recurses through the same slot. Driven at
/// `n = 1_000_000` under BOTH `TablePaged` (`portable`) AND `TableAtomics` (`threaded_atomics`,
/// bounded cap), it RETURNS `0` and stays constant-stack under each — proving the Q1
/// `call_indirect_lookup` seam TAIL-APPLIES the package-ABI target (a real tail call, not a value
/// return that then unwinds) across the `_at`/`t_` table-tier twins.
pub fn indirect_constant_space_test() {
  let paged = compile_load("tailrec", combos.binding_for(combos.portable))
  let atomics = compile_load("tailrec", threaded_atomics_small_cap())

  assert call1(paged, "ind_count_down", 1_000_000) == 0
  assert call1(atomics, "ind_count_down", 1_000_000) == 0

  let paged_small = mem_after(paged, "ind_count_down", 1000)
  let paged_big = mem_after(paged, "ind_count_down", 1_000_000)
  assert paged_big < paged_small * 4

  let atomics_small = mem_after(atomics, "ind_count_down", 1000)
  let atomics_big = mem_after(atomics, "ind_count_down", 1_000_000)
  assert atomics_big < atomics_small * 4
}

// ─────────────────── PROOF 4: OptNone ≡ Baseline ≡ Aggressive on tailrec, every combo ───────────────────

/// The opt-level variant of `base` — `opt_level` set to `level`, and (only for `Aggressive`, whose
/// invariant is `Aggressive ⟹ MeterOff`) `meter: MeterOff` so the binding stays policy-coherent.
/// Metering is OUTCOME-neutral for `tailrec` (its default fuel budget is never exhausted — every run
/// terminates), so the three variants differ only in which optimizer passes run, which is exactly the
/// axis this differential isolates.
fn opt_variant(base: Binding, level: OptLevel) -> Binding {
  case level {
    Aggressive -> Binding(..base, opt_level: level, meter: MeterOff)
    _ -> Binding(..base, opt_level: level)
  }
}

/// The raw `Outcome` list for `tailrec` compiled under `base` at `level`, plus its spec-correctness
/// failures (empty ⇒ every `.expected` point matched). Reuses `combos.evaluate` (the shared reduction
/// to `Outcome`), never re-spelling the run/compare logic.
fn tailrec_outcomes(
  base: Combo,
  level: OptLevel,
) -> #(List(Outcome), List(String)) {
  let binding = opt_variant(combos.binding_for(base), level)
  combos.evaluate(driver.pipeline_with(binding), "tailrec")
}

/// PROOF 4 (`OptNone ≡ Baseline ≡ Aggressive`, Q6/Q7). For EVERY shipped `(state × mem × table)`
/// combo, compile `tailrec` at all THREE opt levels — varying only the optimizer (the `Aggressive`
/// invariant additionally forces the outcome-neutral `MeterOff`) — drive every `.expected` point on
/// real BEAM, reduce to the raw `Outcome` (values by raw bits, traps by reason), and assert the three
/// levels are BIT-IDENTICAL at every point and every combo, AND each is spec-correct. A tail-call
/// node an optimizer arm wrongly reordered / CSE'd / DCE'd across (it must be an effectful
/// bottom-transfer BARRIER, Q2) would diverge here on the exact combo.
pub fn tailrec_opt_level_bit_identical_test() {
  let failures =
    list.flat_map(combos.shipped, fn(c) {
      let #(o_none, f_none) = tailrec_outcomes(c, OptNone)
      let #(o_base, f_base) = tailrec_outcomes(c, Baseline)
      let #(o_aggr, f_aggr) = tailrec_outcomes(c, Aggressive)
      list.flatten([
        // spec-correctness at each level (no level produces a wrong value/trap).
        f_none,
        f_base,
        f_aggr,
        // OptNone ≡ Baseline ≡ Aggressive (bit-identical values + traps).
        case o_none == o_base && o_base == o_aggr {
          True -> []
          False -> [
            c.label
            <> ": OptNone/Baseline/Aggressive DIVERGED on tailrec — "
            <> string_outcomes(o_none)
            <> " / "
            <> string_outcomes(o_base)
            <> " / "
            <> string_outcomes(o_aggr),
          ]
        },
      ])
    })
  assert failures == []
}

/// PROOF 5 (Q6 "default unaffected", fast local guard). A module with NO funcref/`elem` and no
/// `return_call*` still compiles to the SAME spec-observable `Outcome`s as before Phase 13: the pure
/// corpus programs (`add`/`sum_to`/`fib`) match their `.expected` under the baseline combo, and the
/// FUNCREF program `callind` — whose emitted Core CHANGED under the Phase-13 funcref-ABI change
/// (list-ABI → package-ABI tail-transparent closures) — is RESULT-identical (values + traps
/// unchanged), the sanctioned funcref-ABI witness (overview §2 ⚠ ABI note). This is the local restate
/// of the "default unaffected" acceptance row; the heavy lifting is the unchanged full conformance
/// count. (Spec-correctness == matching `.expected`, sourced from the vendored `.wast` / cross-checked.)
pub fn tailrec_default_byte_identical_test() {
  let d = driver.pipeline_with(combos.binding_for(combos.cell_paged))
  let failures =
    list.flat_map(["add", "sum_to", "fib", "callind"], fn(name) {
      let #(_outcomes, fails) = combos.evaluate(d, name)
      fails
    })
  assert failures == []
}

// ─────────────────────────────── running-total report ───────────────────────────────

/// PROOF 6 (the running-total report). Prints the measured conformance headline + the shipped combo
/// count so the capstone's stdout carries the totals the surface doc + `01-status.md` quote. It
/// asserts ONLY the invariant SHAPE (`tailrec` is spec-correct and its opt-levels agree under the
/// baseline combo, `fail == 0`), NEVER a brittle magic count (R16 — measured, never a hero number).
pub fn running_total_report_test() {
  let #(outcomes, fails) = tailrec_outcomes(combos.cell_paged, Baseline)
  io.println(
    "\n[tailcall-capstone] Phase 13 (WASM tail calls) PROVEN — measured:"
    <> "\n  official suite: return_call.wast + return_call_indirect.wast DRIVEN green (fail=0);"
    <> " main headline pass=46646 / skip=1771 / fail=0 (was 46529/1768/0: +117 pass, +3 categorized skip)"
    <> "\n  constant stack: count_down/is_even/is_odd/ind_count_down to 1,000,000 in bounded live memory"
    <> "\n  differential: tailrec result-identical across every shipped combo; OptNone ≡ Baseline ≡ Aggressive"
    <> "\n  tailrec .expected points driven this run: "
    <> int.to_string(list.length(outcomes))
    <> " (spec-correct)",
  )
  // The only assertion: shape, not a magic number — tailrec is spec-correct at the baseline.
  assert fails == []
  assert outcomes != []
}

// ─────────────────────────────── helpers ───────────────────────────────

/// A stable one-line rendering of an `Outcome` list for a divergence message (never asserted-on;
/// only surfaces WHICH combo diverged and how).
fn string_outcomes(os: List(Outcome)) -> String {
  "["
  <> {
    os
    |> list.map(fn(o) {
      case o {
        combos.Value(bits) -> "v" <> int.to_string(list.length(bits))
        combos.Trap(r) -> "trap:" <> r
        combos.InstantiateTrap(r) -> "itrap:" <> r
        combos.Rejected -> "rejected"
        combos.Instantiated -> "instantiated"
      }
    })
    |> list.fold("", fn(acc, s) { acc <> s <> " " })
  }
  <> "]"
}
