//// `rt_ref` — the forge-proof reference value model (Phase-5 keystone, R1).
////
//// References are **term-layer** values (the high-level term model, not the raw-bit numeric
//// path — D5/H1): every reference flows as a `Dynamic` BEAM term, never an `Int`. This is the
//// single owner of the reference representation, imported by `emit_core` (06), `rt_table`
//// (07), `rt_host`/`link` (09), and the conformance harness (11) — so the shape is agreed in
//// ONE place, not by coincidence across units (the L2 hazard the reconciliation closed).
////
//// ## The representation (R1 — forge-proof by construction)
////
//// | Reference value | Core Erlang term | Notes |
//// |---|---|---|
//// | `null` (any reftype) | `{ref_null}` (reserved 1-tuple) | `is_null(x)` ⟺ `x =:= {ref_null}` |
//// | `externref` | `{ref_extern, Term}` (wrapped) | `Term` opaque; the box makes a host term uncollidable with null / a funcref |
//// | `funcref` | `{FuncType, Closure}` | **UNCHANGED** from Phase-2 table entries — a funcref value *is* a table-entry shape, so `call_indirect` stays byte-identical |
////
//// The wrapping is what makes externref **forge-proof**: even an adversarial host that
//// forwards the atom-tuple `{ref_null}` as its term yields `{ref_extern, {ref_null}}`, which
//// `is_null` correctly reports as NOT null. Safe code cannot construct `{ref_null}` (no IR op
//// produces it except `ConstNull`, which lowers here), so the null sentinel is unforgeable.
////
//// ## Security (H6)
////
//// `externref` is opaque: Safe code may hold, pass, store, and null-test one but cannot read
//// the underlying host `Term` — this module exposes no unwrap. A `funcref` is always a
//// build-controlled closure captured at `ref.func`, never program-chosen data (D3a).

import gleam/dynamic.{type Dynamic}

/// Coerce any Gleam value to `Dynamic` (identity at runtime). Used to box an `Int` (the
/// harness's `ref.extern N` handle) into an externref term.
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

/// Construct the null sentinel `{ref_null}`.
@external(erlang, "carder_rt_ref_ffi", "null_ref")
fn ffi_null_ref() -> Dynamic

/// Box an opaque host term as an externref `{ref_extern, Term}`.
@external(erlang, "carder_rt_ref_ffi", "wrap_extern")
fn ffi_wrap_extern(term: Dynamic) -> Dynamic

/// Structural null test — `X =:= {ref_null}`.
@external(erlang, "carder_rt_ref_ffi", "is_null")
fn ffi_is_null(x: Dynamic) -> Bool

/// Structural externref test — `X` matches `{ref_extern, _}`.
@external(erlang, "carder_rt_ref_ffi", "is_extern")
fn ffi_is_extern(x: Dynamic) -> Bool

/// Structural exnref test — `X` matches `{ref_exn, _}` (the Phase-7 EH caught-exception box,
/// owned by `rt_exn`, T9). Delegated to `rt_exn`'s FFI shim so the `{ref_exn, _}` shape stays in
/// one place (D3b); `rt_ref` only needs the boolean to route `classify_ref` (below).
@external(erlang, "carder_rt_exn_ffi", "is_exnref")
fn ffi_is_exnref(x: Dynamic) -> Bool

/// The three reference kinds a runtime reference value can be (the result of `classify_ref`).
/// Used by the conformance harness to JUDGE a returned reference (R18) and by defensive
/// runtime checks.
///
/// - `NullRef`: the null sentinel `{ref_null}` (either reftype).
/// - `ExternRef`: a wrapped host reference `{ref_extern, _}`.
/// - `ExnRef`: a Phase-7 caught-exception handle `{ref_exn, _}` (owned by `rt_exn`, T9). Tested
///   BEFORE the funcref by-elimination arm so a `{ref_exn, _}` is never misclassified as a funcref.
/// - `FuncRef`: a function reference `{FuncType, Closure}` (a Phase-2 table entry shape).
pub type RefKind {
  NullRef
  ExternRef
  ExnRef
  FuncRef
}

/// The null reference sentinel — the single distinguished null shared by both reftypes (R1).
///
/// - Returns the `Dynamic` term `{ref_null}`. It is what `ConstNull(_)` lowers to and the
///   default fill of a `ref.null`-sourced `table.grow`/`table.fill`. Total; never fails.
pub fn null_ref() -> Dynamic {
  ffi_null_ref()
}

/// Wrap an opaque host `Term` as an `externref` — `{ref_extern, Term}` (R1).
///
/// - `term`: any BEAM term the host supplies. It is stored opaquely; this module never
///   inspects or exposes it (opacity is the security property, H6).
/// - Returns the boxed externref `Dynamic`. The box guarantees the result is neither the null
///   sentinel nor a funcref, whatever `term` is. Total; never fails.
pub fn wrap_extern(term: Dynamic) -> Dynamic {
  ffi_wrap_extern(term)
}

/// Build the harness's `ref.extern N` value — a wrapped externref carrying the integer handle
/// `n` (R18). Lets the conformance harness pass a distinguishable, comparable externref
/// argument and identify it on return.
///
/// - `n`: the host handle (an arbitrary distinguishing integer from the `.wast` script).
/// - Returns the externref `{ref_extern, n}`. Two calls with equal `n` compare equal; with
///   distinct `n` compare unequal. Total; never fails.
pub fn extern_of(n: Int) -> Dynamic {
  ffi_wrap_extern(to_dynamic(n))
}

/// Is `x` the null reference? — the `ref.is_null` primitive (R1).
///
/// - `x`: any reference `Dynamic` (funcref/externref/null).
/// - Returns `True` iff `x` is the null sentinel `{ref_null}`. Forge-proof: a wrapped
///   externref `{ref_extern, {ref_null}}` is `False` (it is not the sentinel itself). Total.
pub fn is_null(x: Dynamic) -> Bool {
  ffi_is_null(x)
}

/// Classify a runtime reference value (R18) — for the harness's reference-return judgement and
/// defensive runtime checks.
///
/// - `x`: any reference `Dynamic`.
/// - Returns `NullRef` for the sentinel, `ExternRef` for a `{ref_extern, _}` box, `ExnRef` for a
///   `{ref_exn, _}` caught-exception box (Phase-7 EH — owned by `rt_exn`, T9), else `FuncRef` (a
///   `{FuncType, Closure}` entry — the only remaining shape a well-typed reference can hold). Total;
///   never panics. The order (null, then extern, then exn, then funcref by elimination) is
///   forge-proof because the null/extern/exn tests are all structural — the exn arm precedes the
///   by-elimination funcref arm so a `{ref_exn, _}` is never misclassified.
pub fn classify_ref(x: Dynamic) -> RefKind {
  case ffi_is_null(x) {
    True -> NullRef
    False ->
      case ffi_is_extern(x) {
        True -> ExternRef
        False ->
          case ffi_is_exnref(x) {
            True -> ExnRef
            False -> FuncRef
          }
      }
  }
}
