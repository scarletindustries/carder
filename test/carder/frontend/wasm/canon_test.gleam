//// Spec-based tests for iso-recursive type canonicalization (`carder/frontend/wasm/canon`)
//// and the GC type-section DECLARATION validation added to `validate` (Tier 1).
////
//// Assertions target the WebAssembly GC proposal's typing rules — type equivalence /
//// canonicalization (<https://webassembly.github.io/spec/core/valid/types.html>) and
//// the `subtype`/`comptype` well-formedness rules — NOT whatever the implementation
//// happens to emit. Two defined types are equivalent iff their rec groups canonicalize
//// to the same structural descriptor and they sit at the same position within their
//// group; `canon_ids` must reflect exactly that (equal ids iff equivalent), and the
//// declaration validator must reject `final`/kind/structural subtype violations while
//// accepting well-formed ones.

import carder/frontend/wasm/ast
import carder/frontend/wasm/canon
import carder/frontend/wasm/validate
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit/should

// ───────────────────────────── builders ─────────────────────────────

/// A value-typed struct field / array element with the given mutability.
fn field(vt: ast.ValType, mutable: Bool) -> ast.FieldType {
  ast.FieldType(storage: ast.StVal(vt), mutable: mutable)
}

/// A struct defined type.
fn struct_t(
  fields: List(ast.FieldType),
  super: Option(Int),
  final: Bool,
) -> ast.DefType {
  ast.DefType(comp: ast.CtStruct(fields), supertype: super, final: final)
}

/// An array defined type.
fn array_t(
  element: ast.FieldType,
  super: Option(Int),
  final: Bool,
) -> ast.DefType {
  ast.DefType(comp: ast.CtArray(element), supertype: super, final: final)
}

/// A final, supertype-less func type.
fn func_t(
  params: List(ast.ValType),
  results: List(ast.ValType),
) -> ast.DefType {
  ast.func_def(ast.FuncType(params, results))
}

/// A concrete reference value type `(ref null? $idx)`.
fn cref(nullable: Bool, idx: Int) -> ast.ValType {
  ast.Ref(ast.RefType(nullable: nullable, heap: ast.HConcrete(idx)))
}

/// A minimal module carrying only a type section (with its rec-group shape) — enough
/// to drive type-section declaration validation.
fn types_module(types: List(ast.DefType), rec_groups: List(Int)) -> ast.Module {
  ast.Module(
    imported_func_count: 0,
    types: types,
    rec_groups: rec_groups,
    imports: [],
    tables: [],
    memories: [],
    globals: [],
    tags: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
    data_count: None,
    exports: [],
  )
}

fn accepts(types: List(ast.DefType), rec_groups: List(Int)) -> Bool {
  case validate.validate(types_module(types, rec_groups)) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn rejected_invalid_subtype(
  types: List(ast.DefType),
  rec_groups: List(Int),
) -> Bool {
  case validate.validate(types_module(types, rec_groups)) {
    Error(validate.InvalidSubtype(_)) -> True
    _ -> False
  }
}

fn rejected_unknown_type(
  types: List(ast.DefType),
  rec_groups: List(Int),
) -> Bool {
  case validate.validate(types_module(types, rec_groups)) {
    Error(validate.UnknownType(_)) -> True
    _ -> False
  }
}

// ───────────────────────────── canon_ids ─────────────────────────────

/// Two structurally-DIFFERENT standalone types get DIFFERENT canonical ids (no
/// spurious merge).
pub fn canon_distinct_shapes_test() {
  let assert [c0, c1] =
    canon.canon_ids(
      [func_t([ast.I32], [ast.I32]), func_t([ast.I64], [ast.I64])],
      [],
    )
  should.be_true(c0 != c1)
}

/// Two structurally-IDENTICAL standalone types are iso-recursively equivalent, so
/// they share a canonical id even at different declared indices (spec: type
/// equivalence is structural, index-independent).
pub fn canon_identical_shapes_merge_test() {
  let a = struct_t([field(ast.I32, False)], None, True)
  let assert [c0, c1] = canon.canon_ids([a, a], [])
  should.equal(c0, c1)
}

/// A field difference (`i32` vs `i64`) breaks equivalence — different canonical ids.
pub fn canon_field_difference_distinct_test() {
  let a = struct_t([field(ast.I32, False)], None, True)
  let b = struct_t([field(ast.I64, False)], None, True)
  let assert [c0, c1] = canon.canon_ids([a, b], [])
  should.be_true(c0 != c1)
}

/// Two self-recursive singleton groups with identical structure are equivalent: the
/// intra-group self-reference is canonicalized as a de-Bruijn position, so
/// `struct { mut (ref null 0) }` and `struct { mut (ref null 1) }` (each pointing at
/// itself) share a canonical id.
pub fn canon_self_recursive_equivalent_test() {
  let a = struct_t([field(cref(True, 0), True)], None, False)
  let b = struct_t([field(cref(True, 1), True)], None, False)
  let assert [c0, c1] = canon.canon_ids([a, b], [1, 1])
  should.equal(c0, c1)
}

/// Two 2-member rec groups that are NOT structurally equal (one member differs) get
/// DIFFERENT canonical ids for their corresponding members — the over-merge guard
/// that keeps invalid `type-rec` modules rejectable.
pub fn canon_distinct_rec_groups_test() {
  // group A [0,2): m0 = struct { (ref null 1) }, m1 = struct { i32 }
  let a0 = struct_t([field(cref(True, 1), False)], None, False)
  let a1 = struct_t([field(ast.I32, False)], None, False)
  // group B [2,4): m2 = struct { (ref null 3) }, m3 = struct { i64 }  (m3 differs)
  let b0 = struct_t([field(cref(True, 3), False)], None, False)
  let b1 = struct_t([field(ast.I64, False)], None, False)
  let assert [c0, c1, c2, c3] = canon.canon_ids([a0, a1, b0, b1], [2, 2])
  // corresponding members differ (groups not equivalent)
  should.be_true(c0 != c2)
  should.be_true(c1 != c3)
  // distinct positions within a group differ too
  should.be_true(c0 != c1)
}

/// Two 2-member rec groups that ARE structurally equal produce matching canonical ids
/// for corresponding members (the cross-rec-group equivalence `type-equivalence`
/// relies on).
pub fn canon_equal_rec_groups_test() {
  let a0 = struct_t([field(cref(True, 1), False)], None, False)
  let a1 = struct_t([field(ast.I32, False)], None, False)
  let b0 = struct_t([field(cref(True, 3), False)], None, False)
  let b1 = struct_t([field(ast.I32, False)], None, False)
  let assert [c0, c1, c2, c3] = canon.canon_ids([a0, a1, b0, b1], [2, 2])
  should.equal(c0, c2)
  should.equal(c1, c3)
}

/// An all-singleton reading is the non-GC default: distinct func types map to distinct
/// ids, and the result has one id per type.
pub fn canon_length_test() {
  let ids =
    canon.canon_ids(
      [func_t([], []), func_t([ast.I32], []), func_t([ast.I64], [])],
      [],
    )
  should.equal(list.length(ids), 3)
}

// ───────────────────────────── group_spans ─────────────────────────────

/// Explicit rec-group partition.
pub fn group_spans_partition_test() {
  should.equal(canon.group_spans(4, [2, 2]), [#(0, 2), #(2, 4)])
}

/// Empty `rec_groups` ⇒ every index its own singleton span.
pub fn group_spans_singletons_test() {
  should.equal(canon.group_spans(3, []), [#(0, 1), #(1, 2), #(2, 3)])
}

/// A `rec_groups` whose members do not sum to `n` is ignored (defensive singleton
/// reading), so a stale value never mis-slices.
pub fn group_spans_bad_sum_falls_back_test() {
  should.equal(canon.group_spans(2, [5]), [#(0, 1), #(1, 2)])
}

// ─────────────────────── type-section declaration validation ───────────────────────

/// A struct extending a NON-final struct and adding a field is well-formed (width
/// subtyping) — accepted.
pub fn subtype_struct_widen_accept_test() {
  let a = struct_t([field(ast.I32, False)], None, False)
  let b =
    struct_t([field(ast.I32, False), field(ast.I64, False)], Some(0), True)
  should.be_true(accepts([a, b], []))
}

/// Extending a FINAL type is invalid (spec: a `final` type may not be subtyped).
pub fn subtype_final_supertype_reject_test() {
  let a = struct_t([field(ast.I32, False)], None, True)
  let b = struct_t([field(ast.I32, False)], Some(0), True)
  should.be_true(rejected_invalid_subtype([a, b], []))
}

/// A supertype of a DIFFERENT composite kind is invalid (a func may not extend a
/// struct).
pub fn subtype_kind_mismatch_reject_test() {
  let a = struct_t([field(ast.I32, False)], None, False)
  let b =
    ast.DefType(
      comp: ast.CtFunc(ast.FuncType([], [])),
      supertype: Some(0),
      final: True,
    )
  should.be_true(rejected_invalid_subtype([a, b], []))
}

/// A struct with FEWER fields than its supertype is not a structural subtype —
/// invalid (spec struct subtyping: the subtype keeps at least the supertype's
/// fields).
pub fn subtype_struct_narrow_reject_test() {
  let a = struct_t([field(ast.I32, False), field(ast.I64, False)], None, False)
  let b = struct_t([field(ast.I32, False)], Some(0), True)
  should.be_true(rejected_invalid_subtype([a, b], []))
}

/// Changing an IMMUTABLE field's type to a non-subtype breaks depth subtyping —
/// invalid.
pub fn subtype_struct_field_mismatch_reject_test() {
  let a = struct_t([field(ast.I32, False)], None, False)
  let b = struct_t([field(ast.I64, False)], Some(0), True)
  should.be_true(rejected_invalid_subtype([a, b], []))
}

/// An array extending a compatible array (identical immutable element) is well-formed.
pub fn subtype_array_accept_test() {
  let a = array_t(field(ast.I32, False), None, False)
  let b = array_t(field(ast.I32, False), Some(0), True)
  should.be_true(accepts([a, b], []))
}

/// A concrete reference to an out-of-range type index (a forward reference outside any
/// rec group) is rejected as an unknown type.
pub fn reference_out_of_bounds_reject_test() {
  // A single standalone struct whose field references type index 5 (does not exist).
  let a = struct_t([field(cref(True, 5), False)], None, True)
  should.be_true(rejected_unknown_type([a], []))
}

/// A within-rec-group forward reference is legal (mutual recursion): a rec group of
/// two structs referencing each other validates.
pub fn reference_intra_group_forward_accept_test() {
  // (rec (type (struct (field (ref null 1)))) (type (struct (field (ref null 0)))))
  let a = struct_t([field(cref(True, 1), False)], None, True)
  let b = struct_t([field(cref(True, 0), False)], None, True)
  should.be_true(accepts([a, b], [2]))
}

/// The SAME two structs declared as SEPARATE singleton groups may not reference each
/// other forward — index 0's reference to the later index 1 is out of its group's
/// scope, so it is rejected.
pub fn reference_cross_singleton_forward_reject_test() {
  let a = struct_t([field(cref(True, 1), False)], None, True)
  let b = struct_t([field(cref(True, 0), False)], None, True)
  should.be_true(rejected_unknown_type([a, b], []))
}
