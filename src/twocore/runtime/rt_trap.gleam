//// `rt_trap` — the Safe-mode trap surface (D2/D9; tier-P, cannot crash the node).
////
//// The generated Core Erlang calls this at run time: a `Trap(reason)` IR node, and the
//// error arm of every trapping `rt_num` op, both lower to
//// `call 'twocore@runtime@rt_trap':'raise'(Reason)` (see the calling convention in
//// `runtime/instance.gleam`). `Reason` is the snake_case atom form of a `TrapReason`
//// constructor — which is exactly how Gleam compiles a 0-field constructor — so
//// `raise` receives a `TrapReason` value directly.
////
//// ## Why `erlang:error/1` (error class), not `throw`/`exit`/`panic`
////
//// The reason must surface as a **catchable error-class** exception so the conformance
//// harness (unit 07) can `try … catch error:{wasm_trap, Kind} -> …` and map `Kind` to
//// the WASM-spec trap-message substring. Gleam's `panic` raises a `gleam`-flavoured
//// term (not `{wasm_trap, _}`), and `throw`/`exit` are the wrong exception class — so we
//// call `erlang:error/1` directly. `erlang:error/1` *raises*; it does not crash the node
//// (tier-P).
////
//// ## The reason term shape (frozen with unit 07)
////
//// Every trap raises `erlang:error({wasm_trap, Kind})`, i.e. the 2-tuple
//// `{wasm_trap, Kind}` where `Kind` is the trap-kind atom (`int_div_by_zero`,
//// `int_overflow`, `unreachable`, …). The fixed outer tag `wasm_trap` lets the harness
//// distinguish a *WASM trap* from any incidental BEAM error.

import twocore/ir.{
  type TrapReason, ArrayOutOfBounds, CastFailure, FuelExhausted,
  IndirectCallTypeMismatch, IntDivByZero, IntOverflow,
  InvalidConversionToInteger, MemoryOutOfBounds, NullReference, TableOutOfBounds,
  UndefinedElement, UninitializedElement, Unreachable,
}

/// `erlang:error/1` — raises an **error-class** exception with the given reason term and
/// never returns (diverges). Catchable via `try … catch error:Reason`. This is a direct
/// BIF reference (not a hand-written FFI module), so it does not need the `twocore_`
/// namespace prefix.
@external(erlang, "erlang", "error")
fn erlang_error(reason: a) -> b

/// The fixed outer tag of every WASM-trap error reason. As a 0-field Gleam constructor it
/// compiles to the Erlang atom `wasm_trap`, so `#(WasmTrap, reason)` is `{wasm_trap, …}`.
type Tag {
  WasmTrap
}

/// Raise the WASM trap `reason` as a catchable error-class exception `{wasm_trap, Kind}`.
///
/// - `reason`: the `TrapReason` to abort with. At run time this is its trap-kind atom
///   (`IntDivByZero` is `int_div_by_zero`, etc.), so `{wasm_trap, reason}` is exactly
///   `{wasm_trap, int_div_by_zero}`.
/// - Return: **never returns** — it diverges by raising. Typed `-> a` (bottom) so the
///   emitter can place a `raise` call in any value position (e.g. a `case` arm whose
///   sibling arms yield a value).
/// - Failure mode: always raises; this is the intended effect, not an error path. It
///   raises *error class* (not `throw`/`exit`), so a `try … catch error:R` sees it.
pub fn raise(reason: TrapReason) -> a {
  erlang_error(#(WasmTrap, reason))
}

/// The WASM-spec trap-message substring for a `TrapReason` — the audit/reference mapping
/// the conformance harness (unit 07) matches a caught `Kind` against.
///
/// The strings are the substrings the official WebAssembly spec test suite asserts via
/// `assert_trap` (see
/// <https://webassembly.github.io/spec/core/exec/instructions.html> and the suite's
/// `*.wast` trap expectations). This is *not* called by generated code; it is a total,
/// pure lookup provided so the trap taxonomy lives in one auditable place.
///
/// - `reason`: any `TrapReason` (including the Phase-2 lock-now reasons).
/// - Return: the lowercase spec message substring for that trap kind. Total — never
///   fails, covers every constructor.
pub fn spec_trap_message(reason: TrapReason) -> String {
  case reason {
    IntDivByZero -> "integer divide by zero"
    IntOverflow -> "integer overflow"
    Unreachable -> "unreachable"
    IndirectCallTypeMismatch -> "indirect call type mismatch"
    MemoryOutOfBounds -> "out of bounds memory access"
    InvalidConversionToInteger -> "invalid conversion to integer"
    UndefinedElement -> "undefined element"
    UninitializedElement -> "uninitialized element"
    TableOutOfBounds -> "out of bounds table access"
    // POLICY message (F5), present only for our own audit/diagnostics — NOT a WASM spec
    // trap. Deliberately DISTINCT from every WASM spec trap-message substring, including the
    // spec's "call stack exhausted" (`assert_exhaustion`), so the conformance harness can
    // never mis-map a real WASM trap to it or vice versa.
    FuelExhausted -> "fuel exhausted"
    // ── WasmGC (this proposal) trap messages, matching the spec test-suite
    // expectations (`ref.wast`/`array.wast`): a failed downcast, a null-reference
    // access, and an out-of-bounds array access. Each substring is distinct. ──
    CastFailure -> "cast failure"
    NullReference -> "null reference"
    ArrayOutOfBounds -> "out of bounds array access"
  }
}
