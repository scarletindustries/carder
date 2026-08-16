//// Reference-value self-tests (unit P5-11 §C) — the oracle's reference judgement and the term
//// invoke-ABI round-trip, held to the WebAssembly reference-value model
//// (<https://webassembly.github.io/spec/core/syntax/types.html#reference-types>). Spec-objective,
//// never a change-detector: each asserts what the spec SAYS a reference comparison / round-trip is.
////
//// Two layers:
////  1. Pure oracle self-tests (no compiler): a null matches a null of EITHER reftype; an externref
////     matches BY IDENTITY (and rejects a different id); a funcref matches any NON-NULL funcref and
////     rejects null; a reference never matches a numeric expectation.
////  2. An end-to-end term-ABI round-trip through the AST path (H5): a `(func (param externref)
////     (result externref) (local.get 0))` identity export, parsed by our WAT parser, instantiated
////     via `instantiate_ast`, and invoked with `ref.extern 7` — the SAME id must round-trip, and a
////     `ref.is_null` export must report null-ness correctly. This exercises the reference marshalling
////     (rt_ref), the multi-shape invoke ABI, and the WAT AST path together.

import carder/conformance/driver
import carder/conformance/fixture.{
  ExternRefTag, ExternRefVal, F64Bits, FuncRefTag, FuncRefVal, I32Val, NullRef,
}
import carder/conformance/oracle
import carder/conformance/runner.{Returned}
import carder/frontend/wasm/wat
import gleam/option.{None, Some}

// ─────────────────────────────── pure oracle self-tests ───────────────────────────────

/// A null reference matches a null of EITHER reftype — at the value layer a null slot's reftype is
/// not observable (both reftypes share the one null sentinel, R1). Spec: reference values.
pub fn oracle_null_matches_either_type_test() {
  assert oracle.matches(NullRef(FuncRefTag), NullRef(FuncRefTag))
  assert oracle.matches(NullRef(ExternRefTag), NullRef(ExternRefTag))
  // cross-type null still matches (the sentinel is shared)
  assert oracle.matches(NullRef(FuncRefTag), NullRef(ExternRefTag))
  assert oracle.matches(NullRef(ExternRefTag), NullRef(FuncRefTag))
}

/// An externref matches BY IDENTITY: the `ref.extern N` handle must round-trip exactly. A different
/// id does NOT match (the opacity contract observed from outside — the same term must come back).
pub fn oracle_externref_matches_by_identity_test() {
  assert oracle.matches(ExternRefVal(7), ExternRefVal(7))
  assert oracle.matches(ExternRefVal(0), ExternRefVal(0))
  assert !oracle.matches(ExternRefVal(7), ExternRefVal(8))
  // an externref is not a null, and vice-versa.
  assert !oracle.matches(ExternRefVal(7), NullRef(ExternRefTag))
  assert !oracle.matches(NullRef(ExternRefTag), ExternRefVal(7))
}

/// A funcref matches any NON-NULL funcref (identity deliberately not compared — our funcref is an
/// opaque type-tagged table entry; the suite's funcref checks are null-vs-non-null). A funcref does
/// NOT match a null expectation.
pub fn oracle_funcref_matches_any_nonnull_test() {
  assert oracle.matches(FuncRefVal(Some(0)), FuncRefVal(None))
  assert oracle.matches(FuncRefVal(None), FuncRefVal(Some(3)))
  assert !oracle.matches(NullRef(FuncRefTag), FuncRefVal(None))
  assert !oracle.matches(FuncRefVal(None), NullRef(FuncRefTag))
}

/// A reference value never matches a NUMERIC expectation (and vice-versa) — the reference and
/// numeric families are disjoint at the oracle (no accidental bit coercion).
pub fn oracle_reference_never_matches_numeric_test() {
  assert !oracle.matches(ExternRefVal(1), I32Val(1))
  assert !oracle.matches(I32Val(0), NullRef(FuncRefTag))
  assert !oracle.matches(NullRef(FuncRefTag), F64Bits(0))
}

// ─────────────────────────────── the term-ABI round-trip (end-to-end) ───────────────────────────────

const extern_id_module = "(module
  (func (export \"id_extern\") (param externref) (result externref) (local.get 0))
  (func (export \"is_null\") (param externref) (result i32) (local.get 0) (ref.is_null)))"

/// End-to-end (H5 + R18): the identity externref export, parsed by OUR WAT parser and instantiated
/// via the AST path, ROUND-TRIPS a `ref.extern 7` (the same id comes back), and `ref.is_null`
/// reports null-ness correctly. This proves the reference marshalling (rt_ref), the term invoke-ABI,
/// and the WAT AST path together — a lost identity or a mis-marshalled reference would go red here.
pub fn term_abi_externref_roundtrip_test() {
  let assert Ok(m) = wat.parse_module(extern_id_module)
  let d = driver.pipeline()
  let assert Ok(inst) = d.instantiate_ast(m, driver.empty_env())

  // ref.extern 7 → id_extern → ref.extern 7 (identity preserved).
  assert d.invoke(inst, "id_extern", [ExternRefVal(7)])
    == Returned([ExternRefVal(7)])
  // a distinct id round-trips distinctly.
  assert d.invoke(inst, "id_extern", [ExternRefVal(42)])
    == Returned([ExternRefVal(42)])
  // ref.null extern → id_extern → a null (of the declared externref result type).
  assert d.invoke(inst, "id_extern", [NullRef(ExternRefTag)])
    == Returned([NullRef(ExternRefTag)])

  // ref.is_null: a non-null externref → 0; a null → 1 (spec §4.4.6 ref.is_null).
  assert d.invoke(inst, "is_null", [ExternRefVal(7)]) == Returned([I32Val(0)])
  assert d.invoke(inst, "is_null", [NullRef(ExternRefTag)])
    == Returned([I32Val(1)])
}
