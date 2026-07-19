//// Unit 11c CLI integration tests — drive the subcommand dispatcher (`twocore.run/1`)
//// exactly as `main` does (it is `run(argv.load().arguments)`), proving decision #5: every
//// stage is independently invokable, and bad input yields a typed error (never a panic).
////
//// These exercise the REAL pipeline + file IO (reading the committed corpus `.wasm` and
//// golden `.ir` fixtures), so they are true end-to-end CLI tests, not arg-parsing unit
//// tests.

import gleam/string
import simplifile
import twocore
import twocore/pipeline

const corpus = "test/twocore/conformance/corpus"

const golden = "test/twocore/ir/golden"

// ─────────────────────────────── end-to-end `run` ───────────────────────────────

/// `run add.wasm add 2 3` prints `5` (the documented arg convention: raw unsigned decimals).
/// This is the full Safe pipeline (decode→…→ir_lower→…→invoke) behind one command.
pub fn cli_run_add_test() {
  assert twocore.run(["run", corpus <> "/add.wasm", "add", "2", "3"]) == Ok("5")
}

/// `run sum_to.wasm sum_to 100` prints `5050` — the constant-space loop, through ir_lower.
pub fn cli_run_sum_to_test() {
  assert twocore.run(["run", corpus <> "/sum_to.wasm", "sum_to", "100"])
    == Ok("5050")
}

/// A divide-by-zero is reported as a trap (exit non-zero in `main`); the reason carries the
/// spec trap kind.
pub fn cli_run_trap_test() {
  let assert Error(msg) =
    twocore.run(["run", corpus <> "/intops.wasm", "divu", "10", "0"])
  assert string.contains(msg, "trap")
  assert string.contains(msg, "int_div_by_zero")
}

// ─────────────────────────────── per-stage subcommands ───────────────────────────────

/// `ir <in.wasm>` prints the `.ir` (source→IR end-to-end, unit 02's printer).
pub fn cli_ir_test() {
  let assert Ok(text) = twocore.run(["ir", corpus <> "/add.wasm"])
  assert string.contains(text, "module @")
  assert string.contains(text, "i.add.32")
}

/// `validate <in.wasm>` accepts a well-typed module.
pub fn cli_validate_test() {
  assert twocore.run(["validate", corpus <> "/fib.wasm"]) == Ok("valid")
}

/// `decode <in.wasm>` dumps the WASM AST.
pub fn cli_decode_test() {
  let assert Ok(text) = twocore.run(["decode", corpus <> "/add.wasm"])
  assert string.contains(text, "Module(")
}

/// `ir-lower <in.ir>` runs the Safe policy pass and prints `.ir` with the metering `charge`
/// inserted (the visible evidence that ir_lower ran).
pub fn cli_ir_lower_inserts_charge_test() {
  let assert Ok(text) = twocore.run(["ir-lower", golden <> "/sum_to.ir"])
  assert string.contains(text, "charge")
}

/// `to-core <in.ir>` runs ir_lower(Safe) + emit_core and prints `.core` text.
pub fn cli_to_core_test() {
  let assert Ok(text) = twocore.run(["to-core", golden <> "/add.ir"])
  assert string.contains(text, "module 'add'")
}

/// `emit <in.ir>` runs emit_core alone (no policy pass) and prints `.core` text.
pub fn cli_emit_test() {
  let assert Ok(text) = twocore.run(["emit", golden <> "/add.ir"])
  assert string.contains(text, "module 'add'")
}

/// `to-beam` compiles `.ir` to a real `.beam` binary on disk (the abstract-forms
/// backend — no textual `.core` round trip exists any more).
pub fn cli_to_beam_writes_beam_test() {
  let tmp_beam = "build/cli_test_add.beam"
  let assert Ok(msg) = twocore.run(["to-beam", golden <> "/add.ir", tmp_beam])
  assert string.contains(msg, "wrote")
  // the .beam exists and is non-trivial
  let assert Ok(beam) = simplifile.read_bits(tmp_beam)
  assert beam != <<>>
  let _ = simplifile.delete(tmp_beam)
}

/// `to-erl <in.ir>` dumps the generated module as Erlang source (`erl_pp` over
/// the abstract forms `compile:forms/2` consumes).
pub fn cli_to_erl_test() {
  let assert Ok(text) = twocore.run(["to-erl", golden <> "/add.ir"])
  assert string.contains(text, "-module(add).")
  assert string.contains(text, "instantiate()")
}

/// `to-beam-wasm [--unsafe] <in.wasm> <out.beam>` compiles a `.wasm` to a `.beam` under EACH
/// profile (the profile-selecting compile the benchmark needs), and `exec` runs the prebuilt
/// `.beam` — both profiles compute the same spec-correct result (`add(2,3) == 5`), proving the
/// Safe and Unsafe builds agree end-to-end through the CLI's benchmark path.
pub fn cli_to_beam_wasm_both_profiles_exec_test() {
  let wasm = corpus <> "/add.wasm"
  let safe_beam = "build/cli_bench_add_safe.beam"
  let unsafe_beam = "build/cli_bench_add_unsafe.beam"

  let assert Ok(m1) = twocore.run(["to-beam-wasm", wasm, safe_beam])
  assert string.contains(m1, "wrote")
  let assert Ok(m2) =
    twocore.run(["to-beam-wasm", "--unsafe", wasm, unsafe_beam])
  assert string.contains(m2, "wrote")

  // `exec` prints "<result>\n<timing>"; both profiles compute add(2,3) == 5.
  let assert Ok(safe_out) = twocore.run(["exec", safe_beam, "add", "2", "3"])
  assert string.starts_with(safe_out, "5")
  let assert Ok(unsafe_out) =
    twocore.run(["exec", unsafe_beam, "add", "2", "3"])
  assert string.starts_with(unsafe_out, "5")

  let _ = simplifile.delete(safe_beam)
  let _ = simplifile.delete(unsafe_beam)
}

// ─────────────────────────────── the `opt` stage + `--unsafe` profile flag ───────────────────────────────

/// `opt <in.ir>` round-trips (decision #5): its printed `.ir` re-parses to a well-formed
/// module (F2 — the optimizer emits valid IR), and at the freeze/`OptNone` level equals the
/// input module (compared by structural equality — floats are stored as bit patterns, so this
/// is bit-exact per D7). When real passes land the equality relaxes to semantics-preserving
/// (03/04/11); the round-trip-VALIDITY assertion stays.
pub fn cli_opt_roundtrips_test() {
  let assert Ok(text) = twocore.run(["opt", golden <> "/add.ir"])
  let assert Ok(reparsed) = pipeline.parse_ir(text)
  let assert Ok(original_text) = simplifile.read(golden <> "/add.ir")
  let assert Ok(original) = pipeline.parse_ir(original_text)
  assert reparsed == original
}

/// `opt --unsafe <in.ir>` succeeds and re-parses (the `Aggressive` level is also identity at
/// the freeze). Drives the optimizer stage at the Unsafe profile's level.
pub fn cli_opt_unsafe_succeeds_test() {
  let assert Ok(text) = twocore.run(["opt", "--unsafe", golden <> "/sum_to.ir"])
  let assert Ok(_) = pipeline.parse_ir(text)
}

/// `run --unsafe add.wasm add 2 3` prints `5` — the whole pipeline (decode → … → ir_lower →
/// optimize(Aggressive) → emit(unsafe) → instantiate(seeds) → invoke) runs correctly under the
/// Unsafe profile, returning the SAME spec-correct result as Safe (F2 — Unsafe never changes an
/// observable answer).
pub fn cli_run_unsafe_add_test() {
  assert twocore.run(["run", "--unsafe", corpus <> "/add.wasm", "add", "2", "3"])
    == Ok("5")
}

/// `emit` and `emit --unsafe` produce `.core` IDENTICAL in every function body for the same
/// `.ir` (A.1 — `emit` runs `emit_core` alone, which is posture-blind for bodies), differing
/// ONLY in `instantiate/0`'s seed lines (§A.4): the `seed_policy` literal `host_deny_all` (Safe)
/// vs `host_open` (Unsafe). Splits at the synthesized `instantiate/0` def header (the export
/// list writes `'instantiate'/0]`, never `'instantiate'/0 =`, so the split is unambiguous).
pub fn cli_emit_unsafe_bodies_are_posture_agnostic_test() {
  let assert Ok(safe) = twocore.run(["emit", golden <> "/add.ir"])
  let assert Ok(unsafe) = twocore.run(["emit", "--unsafe", golden <> "/add.ir"])
  // Every real function body (everything before the synthesized instantiate/0) is identical.
  assert bodies_before_instantiate(safe) == bodies_before_instantiate(unsafe)
  // The one documented exception — instantiate/0's baked host-posture literal.
  assert string.contains(safe, "'seed_policy'('host_deny_all')")
  assert string.contains(unsafe, "'seed_policy'('host_open')")
}

/// `to-core` vs `to-core --unsafe` demonstrates the F5 charge differential at the CLI: the
/// Safe `.core` carries `charge` instrumentation and the `seed_fuel` seed; the Unsafe `.core`
/// carries NEITHER (zero-overhead) — differing by exactly the metering.
pub fn cli_to_core_unsafe_charge_differential_test() {
  let assert Ok(safe) = twocore.run(["to-core", golden <> "/sum_to.ir"])
  let assert Ok(unsafe) =
    twocore.run(["to-core", "--unsafe", golden <> "/sum_to.ir"])
  assert string.contains(safe, "'charge'")
  assert !string.contains(unsafe, "'charge'")
  assert string.contains(safe, "'seed_fuel'")
  assert !string.contains(unsafe, "'seed_fuel'")
}

/// The `.core` text preceding the synthesized `instantiate/0` def — every real function body.
/// `'instantiate'/0 =` is the def header (the module's export list writes `'instantiate'/0]`,
/// so the split matches only the def, never the header).
fn bodies_before_instantiate(core: String) -> String {
  case string.split_once(core, "'instantiate'/0 =") {
    Ok(#(before, _)) -> before
    Error(_) -> core
  }
}

// ─────────────────────────────── fail-closed dispatch (never panics) ───────────────────────────────

/// No arguments → the usage text as an `Error` (exit non-zero), never a panic.
pub fn cli_usage_on_no_args_test() {
  let assert Error(msg) = twocore.run([])
  assert string.contains(msg, "Usage")
}

/// An unrecognised subcommand → the usage text as an `Error`.
pub fn cli_usage_on_unknown_command_test() {
  let assert Error(msg) = twocore.run(["frobnicate", "x"])
  assert string.contains(msg, "Usage")
}

/// A missing input file → a typed read error (`Error`), never a panic.
pub fn cli_missing_file_is_typed_error_test() {
  let assert Error(msg) =
    twocore.run(["decode", corpus <> "/does_not_exist.wasm"])
  assert string.contains(msg, "read")
}

/// A non-integer `run` argument → a typed error, never a panic.
pub fn cli_bad_run_argument_test() {
  let assert Error(msg) =
    twocore.run(["run", corpus <> "/add.wasm", "add", "two", "3"])
  assert string.contains(msg, "not an integer")
}
