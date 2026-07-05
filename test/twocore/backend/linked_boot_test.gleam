//// Self-test for the bare-node isolation boot harness (Phase 11 · P11-05).
////
//// These tests PROVE the harness is trustworthy BEFORE the capstone (P11-06 · L2)
//// relies on it — the "proven first" mandate of `RECONCILIATION.md` R16 (novel infra
//// must be proven before the capstone trusts it). They are grounded in the acceptance
//// rows of `phase-11/00-overview.md` §1 ("Single artifact" — loads via an isolated
//// `-pa` with no `twocore@*`/`gleam@*` reachable; "Bare-node proof" — the artifact is
//// ACTUALLY booted on a clean node, measured not asserted), in R6 (seed-then-call in
//// one process), and in the Phase-10 "measured, not asserted" precedent
//// (`03-phase-workflow.md` §8).
////
//// The load-bearing pair is directional:
////   * POSITIVE — a hand-authored, genuinely self-contained `.beam` boots on the
////     isolated child and reports the correct value (isolation held).
////   * NEGATIVE — with a `twocore@` module deliberately on the child path, the in-child
////     gate FIRES (exit 3, `LEAK:`) and success is NOT reported. This non-vacuity proof
////     is the whole point: it shows the gate actually gates and is not a no-op.
////
//// Every fixture is compiled at test time via `compile_source/2` — NO dependency on the
//// linker (P11-03), so this unit lands independently (P11-05 §2).

import gleam/erlang/atom.{type Atom}
import gleam/string

// ───────────────────────── frozen harness bindings ─────────────────────────
// «BARE-NODE-HARNESS-PROVEN» — the exact FFI surface P11-06 · L2 builds against.

/// Compile hand-authored Erlang `source` (whose `-module` must equal `module`) into a
/// `.beam` binary, deterministically and WITHOUT the linker. `Ok(beam)` is the compiled
/// binary; `Error(text)` carries the rendered compile errors. Lets the self-test
/// manufacture self-contained fixtures (and the negative test's `twocore@` leak stub).
@external(erlang, "twocore_linked_boot_ffi", "compile_source")
fn compile_source(module: Atom, source: String) -> Result(BitArray, String)

/// Boot `beam` on a FRESH, environment-scrubbed (`ERL_LIBS`/`ERL_*FLAGS` dropped),
/// code-path-isolated `erl` and, in ONE child process, run `module:instantiate()` then
/// invoke `function(args)` (seed-then-call, R6). `extra` are additional `#(mod, beam)`
/// pairs written to a SEPARATE `-pa` dir (`[]` = the isolated case; the negative test
/// injects a `twocore@` module here). Returns `#(exit_status, combined_stdout_stderr)`.
/// Frozen contract: exit `0` + `RESULT:<v>` = ran clean (isolation held — the in-child
/// gate halts before invoke on any leak); `0` + `TRAP:<r>` = export trapped; `3` +
/// `LEAK:<mod>` = isolation gate hit; `4` + `NOLOAD:<mod>` = module not on child path;
/// `127` = no `erl`.
@external(erlang, "twocore_linked_boot_ffi", "boot_invoke")
fn boot_invoke(
  beam: BitArray,
  module: Atom,
  function: Atom,
  args: List(Int),
  extra: List(#(Atom, BitArray)),
) -> #(Int, String)

/// `code:which/1` in the PARENT (test) VM. `Ok(path)` if `module` resolves here,
/// `Error(Nil)` if it is `non_existing`. Used only by the anti-vacuity test to prove the
/// child's gate atoms are REAL — so their child-side `non_existing` is a genuine absence,
/// not a typo that would let the gate pass vacuously.
@external(erlang, "twocore_linked_boot_ffi", "which_in_parent")
fn which_in_parent(module: Atom) -> Result(String, Nil)

// ───────────────────────────── fixtures ─────────────────────────────

/// The positive fixture module atom (Cell state ABI). Its `instantiate/0` returns `ok`.
fn self_module() -> Atom {
  atom.create("twocore_link_selftest_ok")
}

/// A genuinely self-contained Cell-ABI fixture: it calls ONLY `erlang:error/1` and `+`
/// (ambient BIFs on every OTP node) — no `twocore@`/`gleam@` edge — so it runs on the
/// bare child. `instantiate/0 -> ok` (Cell), `answer/0 -> 42`, `boom/0` raises a
/// `wasm_trap`-shaped error to exercise the trap path.
fn self_source() -> String {
  "-module(twocore_link_selftest_ok).\n"
  <> "-export([instantiate/0, answer/0, boom/0]).\n"
  <> "instantiate() -> ok.\n"
  <> "answer() -> 42.\n"
  <> "boom() -> erlang:error({wasm_trap, unreachable}).\n"
}

/// The Threaded-ABI fixture module atom. Its `instantiate/0` returns the
/// `{instance_state, _}` record (self-detected as Threaded by the runner).
fn self_threaded_module() -> Atom {
  atom.create("twocore_link_selftest_threaded")
}

/// A self-contained Threaded-ABI fixture: `instantiate/0 -> {instance_state, 7}` and
/// `answer(St) -> {element(2, St) + 35, St}` (the uniform threaded ABI `{Package, St'}`).
/// `answer` therefore yields `{42, St}`; the runner unwraps `element(1, …) = 42`.
fn self_threaded_source() -> String {
  "-module(twocore_link_selftest_threaded).\n"
  <> "-export([instantiate/0, answer/1]).\n"
  <> "instantiate() -> {instance_state, 7}.\n"
  <> "answer(St) -> {element(2, St) + 35, St}.\n"
}

/// Compile the positive fixture, asserting success (a compile failure is a real test
/// failure, not an expected `Error`).
fn self_beam() -> BitArray {
  let assert Ok(beam) = compile_source(self_module(), self_source())
  beam
}

// ══════════════════ 1. anti-vacuity: the gate atoms are REAL ══════════════════

/// The representative closure set the in-child gate probes MUST be resolvable in the
/// PARENT build — otherwise the child's `non_existing` would be a typo, not a measured
/// absence, and the isolation gate would pass vacuously. Asserts one module per
/// mergeable bucket (a `twocore@runtime@*`, a `gleam@*`, the `gleam_stdlib` FFI, the
/// `twocore@ir` leaf) is `Ok(_)` here. Closes the "misspelled gate ⇒ vacuous pass" hole.
pub fn gate_atoms_are_real_test() {
  let assert Ok(_) = which_in_parent(atom.create("twocore@runtime@rt_mem"))
  let assert Ok(_) = which_in_parent(atom.create("gleam@list"))
  let assert Ok(_) = which_in_parent(atom.create("gleam_stdlib"))
  let assert Ok(_) = which_in_parent(atom.create("twocore@ir"))
}

// ══════════════════ 2. POSITIVE: isolation held ⇒ correct value ══════════════════

/// "Single artifact" / "Bare-node proof" (measured): a trivial genuinely-self-contained
/// `.beam` booted on the isolated child reports `RESULT:42` at exit `0`. Because the gate
/// halts BEFORE the invoke on any closure-module hit, a `RESULT:` line at exit 0 PROVES
/// isolation held — nothing else was reachable on the child path.
pub fn reports_result_on_trivial_selfcontained_beam_test() {
  let #(code, out) =
    boot_invoke(self_beam(), self_module(), atom.create("answer"), [], [])
  assert code == 0
  assert string.contains(out, "RESULT:42")
}

// ══════════════════ 3. NEGATIVE: the gate gates (non-vacuity) ══════════════════

/// The "gate gates" proof (adversarial must-NOT). With a `twocore@runtime@rt_mem` stub
/// deliberately placed on the child path, the in-child gate MUST fire: exit `3`, stdout
/// contains `LEAK:` and does NOT contain `RESULT:`. This is the direction that makes the
/// harness non-vacuous — it refuses to report success while a runtime module is
/// reachable, so a leaky `-pa`/env in a future run fails loudly instead of false-greening.
pub fn gate_fires_when_twocore_module_on_child_path_test() {
  let rt_mem = atom.create("twocore@runtime@rt_mem")
  let assert Ok(stub) =
    compile_source(rt_mem, "-module('twocore@runtime@rt_mem').\n-export([]).\n")
  let #(code, out) =
    boot_invoke(self_beam(), self_module(), atom.create("answer"), [], [
      #(rt_mem, stub),
    ])
  assert code == 3
  assert string.contains(out, "LEAK:")
  assert !string.contains(out, "RESULT:")
}

// ══════════════════ 4. trap path: a trap ≠ an isolation failure ══════════════════

/// A trapping export surfaces as exit `0` + `TRAP:` carrying the reason substring
/// (`wasm_trap`), and NOT `RESULT:`. Proves the harness distinguishes a genuine trap
/// (still a clean, isolated run) from an isolation failure (`LEAK:`, exit 3), so P11-06
/// can diff trap-identity through the harness.
pub fn reports_trap_on_trapping_export_test() {
  let #(code, out) =
    boot_invoke(self_beam(), self_module(), atom.create("boom"), [], [])
  assert code == 0
  assert string.contains(out, "TRAP:")
  assert string.contains(out, "wasm_trap")
  assert !string.contains(out, "RESULT:")
}

// ══════════════════ 5. Threaded ABI self-detected ══════════════════

/// The runner self-detects the Threaded state ABI from `instantiate/0`'s return: a
/// fixture whose `instantiate/0` returns `{instance_state, 7}` and whose `answer/1`
/// returns `{Package, St'}` yields `RESULT:42` at exit `0` — the runner leads with the
/// state record and unwraps `element(1, …)`. Covers the Threaded branch so P11-06 can
/// drive tier-O threaded builds through the same `boot_invoke`.
pub fn threaded_instance_shape_is_self_detected_test() {
  let assert Ok(tbeam) =
    compile_source(self_threaded_module(), self_threaded_source())
  let #(code, out) =
    boot_invoke(tbeam, self_threaded_module(), atom.create("answer"), [], [])
  assert code == 0
  assert string.contains(out, "RESULT:42")
}

// ══════════════════ 6. NOLOAD distinguishes a path bug from a trap ══════════════════

/// Booting a `.beam` under a module atom that does NOT match the written file yields exit
/// `4` + `NOLOAD:` — the module is not on the child path. Proves the harness separates a
/// harness/path bug from a genuine trap (exit 0 `TRAP:`) or a leak (exit 3 `LEAK:`).
pub fn noload_when_module_absent_test() {
  let #(code, out) =
    boot_invoke(
      self_beam(),
      atom.create("wrong_module_name"),
      atom.create("answer"),
      [],
      [],
    )
  assert code == 4
  assert string.contains(out, "NOLOAD:")
}
