//// Spec-cited tests for `rt_exn` (unit P7-07) — the tagged-exception runtime.
////
//// Assertions target the WebAssembly **exception-handling proposal** exec semantics
//// (<https://github.com/WebAssembly/exception-handling> — §4.4.9 `throw`/`try_table`/`throw_ref`,
//// the tag section §5.5, tag identity §4.5) and Porffor's MEASURED `(tag (param f64 i32))`, NOT
//// whatever the implementation happens to emit (D8 — no change-detectors). The load-bearing
//// properties proven:
////
//// - **throw/catch round-trip** — a thrown tag's payload is recovered by `match_tag` at the same
////   tag id (T4 one-identity), and a DIFFERENT tag id yields `Error` (spec tag identity §4.5);
//// - **`catch_all` ≠ trap (T7, the sandbox floor S8)** — `is_wasm_exn` is True for a wasm exn but
////   FALSE for a real `rt_trap` trap term AND a `FuelExhausted` raise, so a `catch_all` lets a trap
////   PROPAGATE;
//// - **faithful re-raise** — `reraise` preserves class + reason (spec §4.4.9 unwinding);
//// - **`exnref`** — capture → `throw_ref` → re-catch round-trips the reason; the `{ref_exn, _}` box
////   is forge-proof (uncollidable with null / externref / funcref / a raw exn / v128 / Int) and
////   `classify_ref` recognises it as `ExnRef` (T9); a null `throw_ref` TRAPS (spec §4.4.9);
//// - **D3a** — `rt_exn` + its FFI shim carry no ambient authority (no `apply`/`*_to_atom`).
////
//// Exceptions are RAISED (via `rt_exn`/`rt_trap`) and the caught `{Class, Reason, Stacktrace}` is
//// recovered into Gleam by `carder_rt_exn_test_ffi` (pure Gleam cannot `catch`), where the real
//// `rt_exn` heads are exercised on the genuine caught terms — mirroring the `try…catch <C,R,S>`
//// P7-06 will emit. The catch is inside a `try`, so no raise reaches the eunit runner.

import carder/ir
import carder/runtime/rt_exn
import carder/runtime/rt_ref
import carder/runtime/rt_trap
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/result
import gleam/string
import gleeunit/should
import simplifile

// ── test FFI: recover a caught exception's Class / Reason / Stacktrace into Gleam ─────────────────

/// Run `action` (which must raise) and return the caught exception's Reason term (any class).
@external(erlang, "carder_rt_exn_test_ffi", "caught_reason")
fn caught_reason(action: fn() -> a) -> Dynamic

/// Run `action` (which must raise) and return the caught exception's CLASS atom (error/throw/exit).
@external(erlang, "carder_rt_exn_test_ffi", "caught_class")
fn caught_class(action: fn() -> a) -> Dynamic

/// Run `action` (which must raise) and return the caught exception's Stacktrace.
@external(erlang, "carder_rt_exn_test_ffi", "caught_stack")
fn caught_stack(action: fn() -> a) -> Dynamic

/// From `carder_rt_test_ffi` (unit 09): `Ok(kind)` iff `action` raises `error:{wasm_trap, Kind}`,
/// else `Error(_)`. Reused here to assert the null-`throw_ref` TRAP is a genuine trap.
@external(erlang, "carder_rt_test_ffi", "trap_kind")
fn trap_kind(action: fn() -> a) -> Result(String, String)

/// A representative 16-byte `v128` value, carried opaquely (bit-exact) in a payload.
fn v128_bytes() -> BitArray {
  <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>
}

// ── D.1/D.2: throw/catch round-trip; tag identity (spec §4.4.9 throw / catch; §4.5) ──────────────

/// `throw_exn(0, [P0, P1])` caught and matched by `match_tag(_, 0)` yields `Ok([P0, P1])` — the
/// payload survives bit-exact (D5). This is the throw → catch → bind path P7-06 composes (§C.2).
pub fn throw_catch_round_trip_test() {
  let p0 = dynamic.int(0x1234)
  let p1 = dynamic.int(-7)
  let reason = caught_reason(fn() { rt_exn.throw_exn(0, [p0, p1]) })
  rt_exn.match_tag(reason, 0)
  |> should.equal(Ok([p0, p1]))
}

/// `match_tag` matches ONLY the exact tag id (spec tag identity §4.5): a different id ⇒ `Error`
/// (the clause does not fire → the next clause / re-raise), the same id ⇒ `Ok`.
pub fn match_tag_is_by_exact_tag_identity_test() {
  let p0 = dynamic.int(42)
  let reason = caught_reason(fn() { rt_exn.throw_exn(0, [p0]) })
  rt_exn.match_tag(reason, 1)
  |> should.equal(Error(Nil))
  rt_exn.match_tag(reason, 0)
  |> should.equal(Ok([p0]))
}

// ── D.4 / T7 (LOAD-BEARING): catch_all catches EXCEPTIONS but NEVER a TRAP (S8 floor) ────────────

/// `is_wasm_exn` is True for a wasm exn (any tag) — the `catch_all` gate fires for it.
pub fn is_wasm_exn_true_for_any_wasm_exn_test() {
  let reason = caught_reason(fn() { rt_exn.throw_exn(7, []) })
  rt_exn.is_wasm_exn(reason)
  |> should.be_true
}

/// The load-bearing T7 invariant: a REAL `rt_trap` trap term is NOT a wasm exn, so a `catch_all`
/// built on `is_wasm_exn` lets it PROPAGATE (spec §4.4: `catch_all` catches exceptions, not traps).
/// Asserted against `rt_trap`'s actual raised term shape — not the impl's internals.
pub fn is_wasm_exn_false_for_a_real_trap_test() {
  let mem = caught_reason(fn() { rt_trap.raise(ir.MemoryOutOfBounds) })
  rt_exn.is_wasm_exn(mem)
  |> should.be_false
  let div = caught_reason(fn() { rt_trap.raise(ir.IntDivByZero) })
  rt_exn.is_wasm_exn(div)
  |> should.be_false
  // …and match_tag never claims a trap for any tag.
  rt_exn.match_tag(mem, 0)
  |> should.equal(Error(Nil))
}

/// A `FuelExhausted` raise (the preemption trap) is NOT a wasm exn — so it bites THROUGH any `try`
/// region and can never be swallowed by a `catch_all` (J5/J7 — fuel must always bite).
pub fn is_wasm_exn_false_for_fuel_exhaustion_test() {
  let fuel = caught_reason(fn() { rt_trap.raise(ir.FuelExhausted) })
  rt_exn.is_wasm_exn(fuel)
  |> should.be_false
  rt_exn.match_tag(fuel, 0)
  |> should.equal(Error(Nil))
}

// ── D.7: faithful re-raise preserves the exception (spec §4.4.9 unwinding) ───────────────────────

/// `reraise(Class, Reason, Stack)` re-raises the IDENTICAL reason at the SAME class, so an outer
/// handler sees the exception unchanged (a wasm exn stays catchable by its tag with its payload).
pub fn reraise_preserves_class_and_reason_test() {
  let p = dynamic.int(99)
  let thrower = fn() { rt_exn.throw_exn(3, [p]) }
  let reason = caught_reason(thrower)
  let class = caught_class(thrower)
  let stack = caught_stack(thrower)
  let reraised_reason =
    caught_reason(fn() { rt_exn.reraise(class, reason, stack) })
  let reraised_class =
    caught_class(fn() { rt_exn.reraise(class, reason, stack) })
  reraised_reason
  |> should.equal(reason)
  reraised_class
  |> should.equal(class)
  rt_exn.match_tag(reraised_reason, 3)
  |> should.equal(Ok([p]))
}

/// A re-raised TRAP stays a trap (never mis-promoted to a wasm exn) — the terminal `reraise` arm of
/// a `catch_all` chain propagates a trap unchanged (S8).
pub fn reraise_of_a_trap_stays_a_trap_test() {
  let trapper = fn() { rt_trap.raise(ir.MemoryOutOfBounds) }
  let reason = caught_reason(trapper)
  let class = caught_class(trapper)
  let stack = caught_stack(trapper)
  let reraised = caught_reason(fn() { rt_exn.reraise(class, reason, stack) })
  reraised
  |> should.equal(reason)
  rt_exn.is_wasm_exn(reraised)
  |> should.be_false
}

// ── nested try/catch unwinding + clause ordering (spec §4.4.9 — searched in order) ───────────────

/// Nested handlers: an inner handler for tag 0 does NOT catch a tag-1 throw (`match_tag(_, 0)`
/// Error → propagate); the outer handler for tag 1 DOES, with the identical payload. (The Core
/// Erlang nesting is P7-06; this asserts the `rt_exn` dispatch that makes it correct.)
pub fn non_matching_tag_propagates_to_outer_handler_test() {
  let p = dynamic.int(1234)
  let reason = caught_reason(fn() { rt_exn.throw_exn(1, [p]) })
  rt_exn.match_tag(reason, 0)
  |> should.equal(Error(Nil))
  rt_exn.match_tag(reason, 1)
  |> should.equal(Ok([p]))
}

/// `[catch 0 → L1, catch_all → L2]`: tag 0 routes to L1 (first match wins — `match_tag` Ok); tag 1
/// falls PAST `match_tag(_, 0)=Error` to the `catch_all` gate `is_wasm_exn=True` → L2 (spec: the
/// handler list is searched in order, first match wins).
pub fn catch_tag_then_catch_all_dispatch_order_test() {
  let pa = dynamic.int(10)
  let pb = dynamic.int(20)
  let reason_a = caught_reason(fn() { rt_exn.throw_exn(0, [pa]) })
  let reason_b = caught_reason(fn() { rt_exn.throw_exn(1, [pb]) })
  rt_exn.match_tag(reason_a, 0)
  |> should.equal(Ok([pa]))
  rt_exn.match_tag(reason_b, 0)
  |> should.equal(Error(Nil))
  rt_exn.is_wasm_exn(reason_b)
  |> should.be_true
}

// ── D.3/D.6/§E: exnref capture + throw_ref re-throw + forge-proofness ─────────────────────────────

/// `capture_exnref(Reason) = {ref_exn, Reason}` (T9); `throw_ref` of it re-raises `Reason`
/// identically, re-caught by an outer `match_tag(_, 0) = Ok(P)` — a full capture → re-throw →
/// re-catch round-trip (D.3/D.6). The re-thrown reason is bit-identical to the original.
pub fn capture_exnref_throw_ref_round_trip_test() {
  let p0 = dynamic.int(0)
  let p1 = dynamic.int(1)
  let reason = caught_reason(fn() { rt_exn.throw_exn(0, [p0, p1]) })
  let box = rt_exn.capture_exnref(reason)
  rt_exn.is_exnref(box)
  |> should.be_true
  let rethrown = caught_reason(fn() { rt_exn.throw_ref(box) })
  rethrown
  |> should.equal(reason)
  rt_exn.match_tag(rethrown, 0)
  |> should.equal(Ok([p0, p1]))
}

/// Null `throw_ref` TRAPS (spec §4.4.9: re-throwing `ref.null exn` traps) — an ERROR-class
/// `{wasm_trap, _}`, NOT a wasm exn. Assert it is a genuine trap (`trap_kind` Ok) and is classified
/// as NEITHER a wasm exn NOR an exnref. (Per §G/S8 the exact trap Kind is provisional — the
/// spec-load-bearing fact is that it TRAPS, so we assert the class, not a specific message.)
pub fn throw_ref_on_null_traps_test() {
  let null = rt_ref.null_ref()
  trap_kind(fn() { rt_exn.throw_ref(null) })
  |> result.is_ok
  |> should.be_true
  let reason = caught_reason(fn() { rt_exn.throw_ref(null) })
  rt_exn.is_wasm_exn(reason)
  |> should.be_false
  rt_exn.is_exnref(reason)
  |> should.be_false
  rt_exn.match_tag(reason, 0)
  |> should.equal(Error(Nil))
}

/// The `{ref_exn, _}` box is uncollidable with EVERY other value (§E): `is_exnref` is True only on
/// the box and False on null, an externref, a raw thrown exn, a `v128` binary, and an Int.
pub fn exnref_box_is_uncollidable_test() {
  let reason = caught_reason(fn() { rt_exn.throw_exn(0, [dynamic.int(5)]) })
  let box = rt_exn.capture_exnref(reason)
  rt_exn.is_exnref(box)
  |> should.be_true
  rt_exn.is_exnref(rt_ref.null_ref())
  |> should.be_false
  rt_exn.is_exnref(rt_ref.wrap_extern(dynamic.int(1)))
  |> should.be_false
  // a RAW thrown exn {wasm_exn,_,_} is NOT the box (capture wraps it):
  rt_exn.is_exnref(reason)
  |> should.be_false
  rt_exn.is_exnref(dynamic.int(42))
  |> should.be_false
  rt_exn.is_exnref(dynamic.bit_array(v128_bytes()))
  |> should.be_false
}

/// FORGE-PROOFNESS (H6): the BOX is the identity, not the contents. A crafted externref that WRAPS
/// a real caught exn (`{ref_extern, {wasm_exn,_,_}}`) is NOT an exnref and classifies as
/// `ExternRef` — mirroring `rt_ref`'s `{ref_extern, {ref_null}} ≠ null`. So Safe code cannot forge
/// an exnref by disguising a term.
pub fn extern_wrapping_an_exn_is_not_an_exnref_test() {
  let reason = caught_reason(fn() { rt_exn.throw_exn(0, [dynamic.int(7)]) })
  let disguised = rt_ref.wrap_extern(reason)
  rt_exn.is_exnref(disguised)
  |> should.be_false
  rt_ref.classify_ref(disguised)
  |> should.equal(rt_ref.ExternRef)
}

/// `classify_ref` recognises the `{ref_exn, _}` box as `ExnRef` (T9), tested BEFORE the funcref
/// by-elimination arm so it is never misclassified. Regression: null/externref still classify
/// correctly (the new arm did not perturb the existing ones).
pub fn classify_ref_recognizes_exnref_test() {
  let reason = caught_reason(fn() { rt_exn.throw_exn(0, []) })
  let box = rt_exn.capture_exnref(reason)
  rt_ref.classify_ref(box)
  |> should.equal(rt_ref.ExnRef)
  rt_ref.classify_ref(rt_ref.null_ref())
  |> should.equal(rt_ref.NullRef)
  rt_ref.classify_ref(rt_ref.wrap_extern(dynamic.int(1)))
  |> should.equal(rt_ref.ExternRef)
}

// ── D5: payload heterogeneity + the Porffor-shaped (f64, i32) case ───────────────────────────────

/// A payload mixing an `Int` (numeric raw bits), a 16-byte `BitArray` (`v128`), and a reference
/// `Dynamic` round-trips bit-identically — the list carries the operands opaquely, no coercion (D5).
pub fn payload_heterogeneity_round_trips_test() {
  let p_int = dynamic.int(0xDEADBEEF)
  let p_v128 = dynamic.bit_array(v128_bytes())
  let p_ref = rt_ref.null_ref()
  let reason =
    caught_reason(fn() { rt_exn.throw_exn(4, [p_int, p_v128, p_ref]) })
  rt_exn.match_tag(reason, 4)
  |> should.equal(Ok([p_int, p_v128, p_ref]))
}

/// The MEASURED Porffor tag `(tag (param f64 i32))`: the thrown JS value's f64 raw bits + its i32
/// type tag. Both operands survive intact through throw → catch — the concrete shape the JS harness
/// (P7-09) depends on.
pub fn porffor_shaped_f64_i32_payload_test() {
  // The IEEE-754 raw bits of an f64 (carried opaquely as an Int — D5) + a type tag.
  let f64_bits = dynamic.int(4_614_256_656_552_045_848)
  let type_tag = dynamic.int(1)
  let reason = caught_reason(fn() { rt_exn.throw_exn(0, [f64_bits, type_tag]) })
  rt_exn.match_tag(reason, 0)
  |> should.equal(Ok([f64_bits, type_tag]))
}

// ── property tests (spec laws over a spread of inputs) ───────────────────────────────────────────

/// For a spread of tag ids / payloads: `match_tag(throw of tag t, t) = Ok(payload)`, `match_tag(…,
/// t') = Error` for `t' ≠ t`, every thrown wasm exn is a wasm exn, and capture → `throw_ref` →
/// re-catch round-trips the payload. Properties assert spec identities, never impl internals.
pub fn property_throw_match_and_exnref_round_trip_test() {
  [0, 1, 2, 3, 5, 7, 11, 13, 100, 255, 1000]
  |> list.each(fn(t) {
    let payload = [dynamic.int(t), dynamic.int(t * 7 - 3)]
    let reason = caught_reason(fn() { rt_exn.throw_exn(t, payload) })
    rt_exn.match_tag(reason, t)
    |> should.equal(Ok(payload))
    rt_exn.match_tag(reason, t + 1)
    |> should.equal(Error(Nil))
    rt_exn.match_tag(reason, t + 100)
    |> should.equal(Error(Nil))
    rt_exn.is_wasm_exn(reason)
    |> should.be_true
    let box = rt_exn.capture_exnref(reason)
    rt_exn.is_exnref(box)
    |> should.be_true
    let rethrown = caught_reason(fn() { rt_exn.throw_ref(box) })
    rt_exn.match_tag(rethrown, t)
    |> should.equal(Ok(payload))
  })
}

/// `is_wasm_exn` is False for EVERY `TrapReason` kind (the S8 floor: a trap must always bite, never
/// be caught by a `catch_all`). Iterated over the full ten-variant trap set.
pub fn property_no_trap_is_ever_a_wasm_exn_test() {
  [
    ir.IntDivByZero,
    ir.IntOverflow,
    ir.Unreachable,
    ir.IndirectCallTypeMismatch,
    ir.MemoryOutOfBounds,
    ir.InvalidConversionToInteger,
    ir.UndefinedElement,
    ir.UninitializedElement,
    ir.TableOutOfBounds,
    ir.FuelExhausted,
  ]
  |> list.each(fn(kind) {
    let reason = caught_reason(fn() { rt_trap.raise(kind) })
    rt_exn.is_wasm_exn(reason)
    |> should.be_false
    rt_exn.is_exnref(reason)
    |> should.be_false
    rt_exn.match_tag(reason, 0)
    |> should.equal(Error(Nil))
  })
}

// ── D3a: no ambient authority (grep-backed, mirrors the P5/P6 backend checks) ────────────────────

/// D3a (grep-backed): `rt_exn.gleam` + `carder_rt_exn_ffi.erl` contain NO `apply`, NO
/// `binary_to_atom`/`list_to_atom`, and NO module-name construction — only fixed-tuple
/// construction/matching + `erlang:error`/`raise`. A thrown value is a term, never authority (J5).
/// Comment lines (which may name these in prose) are stripped first.
pub fn no_ambient_authority_d3a_test() {
  let assert Ok(gleam_src) = simplifile.read("src/carder/runtime/rt_exn.gleam")
  let assert Ok(erl_src) = simplifile.read("src/carder_rt_exn_ffi.erl")
  let code_of = fn(src: String) {
    src
    |> string.split("\n")
    |> list.filter(fn(line) {
      let t = string.trim_start(line)
      !string.starts_with(t, "//") && !string.starts_with(t, "%")
    })
    |> string.join("\n")
  }
  [code_of(gleam_src), code_of(erl_src)]
  |> list.each(fn(code) {
    string.contains(code, "apply")
    |> should.be_false
    string.contains(code, "binary_to_atom")
    |> should.be_false
    string.contains(code, "list_to_atom")
    |> should.be_false
  })
}
