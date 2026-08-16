//// Unit P3-11 capstone — the REAL-METERING trap proof (proof 4 of the unit doc; F5).
////
//// Phase 1/2 shipped metering observe-only; Phase 3 makes CPU fuel ENFORCE in Safe. This proves
//// the resource bound BITES: a runaway program traps `FuelExhausted` at a deterministic finite
//// fuel bound, the trap surfaces through the run-ABI, and enforcement stays constant-space for a
//// tail loop (bounds recursion DEPTH for non-tail recursion). Two runaway shapes:
////   - `spin.ir`  — an unbounded TAIL loop (`(loop $l (br $l))` in the original WAT), charged
////     every iteration. The back-edge is a tail-`apply`; fuel lives in the process dictionary,
////     never loop-carried, so the runaway stays CONSTANT SPACE until it traps (E1/F5).
////   - `recurse.ir` — unbounded NON-TAIL recursion (its call result is consumed), charged
////     `fn_cost` per call, so fuel bounds recursion DEPTH. Unlike the tail spin, the process
////     stack grows to O(budget) frames before the trap — node memory O(budget), NOT constant (the
////     residual caveat, unit 05 §C.3). The bound still bites: the runaway TERMINATES
////     deterministically, which is the F5 property.
////
//// Spec anchor (WebAssembly spec §7 Embedding / the suite's `assert_exhaustion`): `FuelExhausted`
//// is an EMBEDDER-imposed CPU bound — it ABORTS, it never returns a wrong value, so it is sound
//// w.r.t. the spec but is NOT one of the spec's own traps. It therefore carries a NON-spec
//// message ("fuel exhausted") and never appears in an `assert_trap`.
////
//// Process hygiene (units 05/07/10): each seeding instance runs `instantiate/0` (which calls
//// `rt_meter:seed_fuel`) IN ITS OWN spawned/owned process via `ffi.start_instance`, so the fuel
//// budget lives in that process's dictionary, never the shared eunit runner process — no
//// cross-test pdict leak. The trap is matched on the RAISED ATOM `fuel_exhausted` directly (NOT
//// `runner.trap_matches`, which is for WASM spec phrases), keeping the policy trap out of the
//// conformance trap-phrase table.
////
//// ## Corpus input: `.ir` TEXT, not a `.wasm` binary
////
//// carder is now the BACKEND only — the WebAssembly frontend moved to the `scribbler` repo — so
//// the two runaway programs enter through `pipeline.parse_ir` over
//// `test/carder/ir/corpus/{spin,recurse}.ir` instead of `source_to_ir` over their `.wasm`s. Each
//// `.ir` was produced from the very same `.wasm` by the pre-split `to-ir`, and `wasm -> .beam`
//// was measured byte-identical to `wasm -> .ir text -> .beam`, so these tests still meter the
//// exact same compiled artifact.

import carder/backend/build_beam
import carder/harness/ffi
import carder/harness/runner
import carder/ir
import carder/pipeline
import carder/runtime/instance.{type Binding}
import carder/runtime/profiles
import carder/runtime/rt_trap
import gleam/bit_array
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The `.ir` corpus directory — the frontend-independent text form of the acceptance corpus
/// (`spin.ir` / `recurse.ir` here). See the module doc for why this replaced the `.wasm` corpus.
const corpus_dir = "test/carder/ir/corpus"

// ─────────────────────────── (a) it TRAPS FuelExhausted ───────────────────────────

/// A runaway TAIL loop under a small `profiles.safe_metered(budget)` traps `FuelExhausted` (F5).
/// The trap surfaces through the run-ABI as the catchable `{wasm_trap, fuel_exhausted}`, matched
/// on the raised atom directly (keystone C.1 — NOT `runner.trap_matches`).
pub fn spin_traps_fuel_exhausted_test() {
  let mod = compile_load("spin", profiles.safe_metered(1000))
  let assert Ok(proc) = ffi.start_instance(mod)
  let assert Error(reason) = ffi.call_instance(proc, atom.create("spin"), [])
  assert string.contains(reason, "fuel_exhausted")
  ffi.stop_instance(proc)
}

/// A runaway NON-TAIL recursion under a small `safe_metered(budget)` ALSO traps `FuelExhausted`
/// — proving fuel caps recursion DEPTH, not only loop iterations (its call result is consumed, so
/// a frame is kept and `fn_cost` is charged per call). Node memory at the trap is O(budget) (unit
/// 05 §C.3's documented caveat), but the bound bites: the runaway terminates deterministically.
pub fn recurse_traps_fuel_exhausted_test() {
  let mod = compile_load("recurse", profiles.safe_metered(500))
  let assert Ok(proc) = ffi.start_instance(mod)
  let assert Error(reason) =
    ffi.call_instance(proc, atom.create("recurse"), [0])
  assert string.contains(reason, "fuel_exhausted")
  ffi.stop_instance(proc)
}

// ─────────────────────────── (b) DETERMINISTIC ───────────────────────────

/// DETERMINISTIC: the same budget traps on EVERY (re)instantiation — a runaway is not flaky.
/// Each `start_instance` re-runs `instantiate/0` in a FRESH owned process (a fresh seeded
/// budget), so every one of the repeated runs trips the SAME bound and traps `fuel_exhausted`.
pub fn spin_trap_is_deterministic_test() {
  let mod = compile_load("spin", profiles.safe_metered(2000))
  list.each([1, 2, 3, 4, 5], fn(_i) {
    let assert Ok(proc) = ffi.start_instance(mod)
    let assert Error(reason) = ffi.call_instance(proc, atom.create("spin"), [])
    assert string.contains(reason, "fuel_exhausted")
    ffi.stop_instance(proc)
  })
}

/// DETERMINISTIC for the non-tail shape too: `recurse` traps `fuel_exhausted` on every repeated
/// (re)instantiation under the same small budget.
pub fn recurse_trap_is_deterministic_test() {
  let mod = compile_load("recurse", profiles.safe_metered(300))
  list.each([1, 2, 3], fn(_i) {
    let assert Ok(proc) = ffi.start_instance(mod)
    let assert Error(reason) =
      ffi.call_instance(proc, atom.create("recurse"), [0])
    assert string.contains(reason, "fuel_exhausted")
    ffi.stop_instance(proc)
  })
}

// ─────────────────────────── (c) CONSTANT SPACE (tail spin) ───────────────────────────

/// CONSTANT SPACE: a small budget and a 100×-larger budget BOTH trap using process memory
/// bounded by a small constant. The tail spin's back-edge is an unchanged tail-`apply`, and fuel
/// is process-dictionary state (a single in-place `Int`, never loop-carried, E1), so 100× the
/// iterations does NOT mean ~100× the live memory — a per-iteration leak WOULD blow this up.
/// Measured via `ffi.gc_and_memory` after the trap (the instance process survives a caught trap
/// and keeps its receive loop), exactly like the Phase-2 store-loop constant-space test.
pub fn spin_traps_in_constant_space_test() {
  let small = compile_load("spin", profiles.safe_metered(1000))
  let assert Ok(sp) = ffi.start_instance(small)
  let assert Error(_) = ffi.call_instance(sp, atom.create("spin"), [])
  let mem_small = ffi.gc_and_memory(sp)

  let big = compile_load("spin", profiles.safe_metered(100_000))
  let assert Ok(bp) = ffi.start_instance(big)
  let assert Error(_) = ffi.call_instance(bp, atom.create("spin"), [])
  let mem_big = ffi.gc_and_memory(bp)

  // 100× the iterations must stay well under a small constant factor of the small run's live
  // memory (a loop-carried / accumulating state would blow this up ~100×).
  assert mem_big < mem_small * 4

  ffi.stop_instance(sp)
  ffi.stop_instance(bp)
}

// ─────────────────────────── (d) the policy-trap message + isolation ───────────────────────────

/// The `FuelExhausted` spec message is the fixed policy phrase "fuel exhausted" (F5) — the single
/// mapping `rt_trap.spec_trap_message` publishes for the resource-limit trap.
pub fn fuel_exhausted_spec_message_test() {
  assert rt_trap.spec_trap_message(ir.FuelExhausted) == "fuel exhausted"
}

/// `FuelExhausted` stays OUT of the conformance trap-phrase table (keystone C.1): its message is
/// deliberately DISTINCT from every WASM spec phrase, so `runner.trap_matches` never maps a real
/// WASM trap to the policy trap or vice versa. A `{wasm_trap,fuel_exhausted}` reason matches NO
/// WASM spec phrase, and no WASM trap reason matches the "fuel exhausted" phrase.
pub fn fuel_exhausted_not_in_spec_phrase_table_test() {
  // The policy trap reason matches no WASM spec phrase (it is not in `spec_phrase_of`, and its
  // underscore atom does not raw-contain any spec phrase).
  assert !runner.trap_matches("{wasm_trap,fuel_exhausted}", "unreachable")
  assert !runner.trap_matches(
    "{wasm_trap,fuel_exhausted}",
    "out of bounds memory access",
  )
  // And a genuine WASM trap is never matched to the policy phrase.
  assert !runner.trap_matches("{wasm_trap,unreachable}", "fuel exhausted")
  assert !runner.trap_matches("{wasm_trap,int_div_by_zero}", "fuel exhausted")
}

// ─────────────────────────── compile helper ───────────────────────────

/// Compile an `ir/corpus/<name>.ir` program through the full pipeline under `binding` and
/// LOAD it, returning its BEAM module atom (a unique name per call). The metered runaway tests
/// pass a SMALL `profiles.safe_metered(budget)` here, and drive the loaded module via
/// `ffi.start_instance` so `instantiate/0` seeds the budget in the instance's OWN process.
///
/// - `name`: a corpus program's base name (no extension), e.g. `"spin"`.
/// - `binding`: the build-time posture; the budget rides in `binding` via `safe_metered`.
/// - Returns the loaded module's atom. `let assert Ok` at every stage is the contract — a
///   missing/unparseable corpus file or a compile failure is a broken checkout or a real
///   regression, never an expected path.
fn compile_load(name: String, binding: Binding) -> Atom {
  let assert Ok(m0) = {
    use bytes <- result.try(ffi.read_file(corpus_dir <> "/" <> name <> ".ir"))
    use text <- result.try(
      bit_array.to_string(bytes)
      |> result.replace_error("non-UTF8 .ir source"),
    )
    pipeline.parse_ir(text) |> result.map_error(string.inspect)
  }
  let m =
    ir.Module(..m0, name: m0.name <> "_" <> int.to_string(ffi.unique_int()))
  let assert Ok(cmod) = pipeline.ir_to_cmod(m, binding)
  let assert Ok(mod) = build_beam.compile_and_load(cmod)
  mod
}
