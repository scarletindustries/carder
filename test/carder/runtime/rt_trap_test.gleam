//// Spec-based tests for `rt_trap` (unit 09) — the Safe-mode trap surface.
////
//// Assertions target the WebAssembly trap taxonomy
//// (<https://webassembly.github.io/spec/core/exec/instructions.html>) and the spec
//// suite's `assert_trap` strings, NOT whatever the implementation emits. We prove that
//// `raise` surfaces a catchable **error-class** exception of shape `{wasm_trap, Kind}`,
//// that each `Kind` is the distinct trap-kind atom, and that every kind maps to the
//// spec's trap-message substring. Exceptions are caught via the namespace-hygienic
//// `carder_rt_test_ffi` helper (pure Gleam cannot `catch`).

import carder/ir.{
  IndirectCallTypeMismatch, IntDivByZero, IntOverflow, MemoryOutOfBounds,
  Unreachable,
}
import carder/runtime/rt_trap
import gleam/list
import gleeunit/should

/// Run `action` and capture a `{wasm_trap, Kind}` error-class raise; returns
/// `Ok(kind_atom_as_string)` only when the raise has exactly that class+shape, else
/// `Error(description)`. See `carder_rt_test_ffi`.
@external(erlang, "carder_rt_test_ffi", "trap_kind")
fn trap_kind(action: fn() -> a) -> Result(String, String)

// ── raise/1: error-class, {wasm_trap, Kind}, distinct kind per reason ──────────

pub fn raise_int_div_by_zero_kind_test() {
  trap_kind(fn() { rt_trap.raise(IntDivByZero) })
  |> should.equal(Ok("int_div_by_zero"))
}

pub fn raise_int_overflow_kind_test() {
  trap_kind(fn() { rt_trap.raise(IntOverflow) })
  |> should.equal(Ok("int_overflow"))
}

pub fn raise_unreachable_kind_test() {
  trap_kind(fn() { rt_trap.raise(Unreachable) })
  |> should.equal(Ok("unreachable"))
}

/// The three Phase-1 trap kinds are *distinguishable* — no two share a kind atom.
pub fn trap_kinds_are_distinct_test() {
  let kinds = [
    trap_kind(fn() { rt_trap.raise(IntDivByZero) }),
    trap_kind(fn() { rt_trap.raise(IntOverflow) }),
    trap_kind(fn() { rt_trap.raise(Unreachable) }),
  ]
  // all distinct ⇒ deduplicating leaves all three.
  kinds |> list.unique |> list.length |> should.equal(3)
}

// ── spec_trap_message/1: kind ↔ WASM-spec assert_trap substring ────────────────

pub fn spec_message_int_div_by_zero_test() {
  rt_trap.spec_trap_message(IntDivByZero)
  |> should.equal("integer divide by zero")
}

pub fn spec_message_int_overflow_test() {
  rt_trap.spec_trap_message(IntOverflow)
  |> should.equal("integer overflow")
}

pub fn spec_message_unreachable_test() {
  rt_trap.spec_trap_message(Unreachable)
  |> should.equal("unreachable")
}

pub fn spec_message_indirect_call_type_mismatch_test() {
  rt_trap.spec_trap_message(IndirectCallTypeMismatch)
  |> should.equal("indirect call type mismatch")
}

pub fn spec_message_memory_out_of_bounds_test() {
  rt_trap.spec_trap_message(MemoryOutOfBounds)
  |> should.equal("out of bounds memory access")
}
