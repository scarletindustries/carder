//// Spec-based tests for `rt_js` (Phase-8 unit 05; HANDOFF-arc-frontend.md §4) — the
//// JS-semantics runtime the arc frontend targets via `CallHost("js", op, args)`.
////
//// Assertions target ECMA-262 semantics under the FIXED value model (rt_js.gleam header):
//// numbers are native BEAM ints/floats with `js_nan`/`js_inf`/`js_neg_inf` sentinel atoms
//// for the three unrepresentable doubles; booleans/`null`/`undefined` are atoms; strings
//// are UTF-8 binaries; cells/objects are pdict-backed refs; JS type errors raise
//// `{js_error, type_error, _}`.
////
//// Two layers:
////   1. Direct facade calls (the semantics: sentinel arithmetic incl. float overflow,
////      `+` concat, ==/===/relational matrices, truthiness, to_string/type_of, cells,
////      objects with numeric-key normalisation, console_log, not_callable).
////   2. The `resolve_js` registry: every op string the arc emitter writes must emit —
////      the dispatch is fail-closed, so an unregistered op is an emit error, not a
////      runtime one.

import carder/backend/emit_core
import carder/ir
import carder/runtime/instance
import carder/runtime/rt_js as js
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list

// ───────────────────────────── helpers ─────────────────────────────

/// Coerce any Gleam value to `Dynamic` (identity at runtime) — Gleam strings ARE
/// UTF-8 binaries, so `d("px")` is a JS string term as-is.
@external(erlang, "gleam_stdlib", "identity")
fn d(x: a) -> Dynamic

/// Apply `M:F(Args)` catching a raise as `Error(text)` (see test/carder_emit_test_ffi.erl) —
/// how the `{js_error, type_error, _}` contract is asserted without crashing the test VM.
@external(erlang, "carder_emit_test_ffi", "catch_apply")
fn catch_apply_dyn(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

fn rt_js_module() -> Atom {
  atom.create("carder@runtime@rt_js")
}

/// A sentinel/bool/null/undefined atom as a term.
fn a(name: String) -> Dynamic {
  d(atom.create(name))
}

fn bs(text: String) -> BitArray {
  bit_array.from_string(text)
}

/// Assert `M:F(Args)` raises `{js_error, type_error, _}`.
fn assert_type_error(function: String, args: List(Dynamic)) -> Nil {
  let assert Error(reason) =
    catch_apply_dyn(rt_js_module(), atom.create(function), args)
  assert string_contains(reason, "js_error")
  assert string_contains(reason, "type_error")
  Nil
}

@external(erlang, "string", "find")
fn string_find(haystack: String, needle: String) -> Dynamic

fn string_contains(haystack: String, needle: String) -> Bool {
  string_find(haystack, needle) != d(atom.create("nomatch"))
}

// ───────────────────────────── add: numeric, sentinels, overflow ─────────────────────────────

pub fn add_numeric_test() {
  assert js.add(d(1), d(2)) == d(3)
  assert js.add(d(1), d(2.5)) == d(3.5)
  // Integer arithmetic is exact BEAM bignum (documented divergence beyond 2^53).
  assert js.add(d(1_152_921_504_606_846_976), d(1_152_921_504_606_846_976))
    == d(2_305_843_009_213_693_952)
}

pub fn add_sentinel_test() {
  // NaN propagates; Inf + -Inf is NaN; Inf absorbs finites (§13.15.3 / IEEE).
  assert js.add(a("js_nan"), d(1)) == a("js_nan")
  assert js.add(d(1), a("js_nan")) == a("js_nan")
  assert js.add(a("js_inf"), d(1)) == a("js_inf")
  assert js.add(a("js_inf"), a("js_neg_inf")) == a("js_nan")
}

pub fn add_overflow_test() {
  // Float overflow resolves to the signed infinity sentinel — never badarith.
  assert js.add(d(1.0e308), d(1.0e308)) == a("js_inf")
  assert js.add(d(-1.0e308), d(-1.0e308)) == a("js_neg_inf")
}

pub fn add_concat_test() {
  // Either operand a string ⇒ concatenation, other side coerced (§13.15.3 step 3).
  assert js.add(d("a"), d("b")) == d("ab")
  assert js.add(d(1), d("px")) == d("1px")
  assert js.add(d("v="), a("true")) == d("v=true")
  assert js.add(d("x"), a("null")) == d("xnull")
  assert js.add(d("x"), a("undefined")) == d("xundefined")
  assert js.add(d(1.5), d("s")) == d("1.5s")
}

pub fn add_object_concat_type_error_test() {
  // v1 has no ToPrimitive walk: string + object is a typed error, not "[object Object]".
  assert_type_error("add", [d("s"), js.new_object()])
}

// ───────────────────────────── sub / mul / neg ─────────────────────────────

pub fn sub_test() {
  assert js.sub(d(5), d(2)) == d(3)
  assert js.sub(a("js_nan"), d(1)) == a("js_nan")
  assert js.sub(a("js_inf"), a("js_inf")) == a("js_nan")
}

pub fn mul_test() {
  assert js.mul(d(3), d(4)) == d(12)
  assert js.mul(d(1.0e308), d(10.0)) == a("js_inf")
  assert js.mul(d(-1.0e308), d(1.0e308)) == a("js_neg_inf")
  // Inf × 0 is NaN (§6.1.6.1.4).
  assert js.mul(a("js_inf"), d(0)) == a("js_nan")
}

pub fn neg_test() {
  assert js.neg(d(5)) == d(-5)
  assert js.neg(a("js_nan")) == a("js_nan")
  assert js.neg(a("js_inf")) == a("js_neg_inf")
  assert js.neg(a("js_neg_inf")) == a("js_inf")
}

pub fn arith_non_number_type_error_test() {
  assert_type_error("sub", [d("s"), d(1)])
  assert_type_error("neg", [d("s")])
}

// ───────────────────────────── divide ─────────────────────────────

pub fn divide_test() {
  // JS division is always real division — no integer div.
  assert js.divide(d(7), d(2)) == d(3.5)
  // ±x/±0 → signed infinity; 0/0 → NaN; Inf/Inf → NaN (§6.1.6.1.5).
  assert js.divide(d(1), d(0)) == a("js_inf")
  assert js.divide(d(-1), d(0)) == a("js_neg_inf")
  assert js.divide(d(1), d(-0.0)) == a("js_neg_inf")
  assert js.divide(d(0), d(0)) == a("js_nan")
  assert js.divide(a("js_inf"), a("js_inf")) == a("js_nan")
  // finite / Inf → zero; overflow → infinity.
  assert js.truthy(js.divide(d(1), a("js_inf"))) == 0
  assert js.divide(d(1.0e308), d(1.0e-308)) == a("js_inf")
}

// ───────────────────────────── modulo ─────────────────────────────

pub fn modulo_test() {
  // fmod with the DIVIDEND's sign (§6.1.6.1.6) — not Erlang rem/mod-toward-zero drama.
  assert js.modulo(d(7), d(3)) == d(1)
  assert js.modulo(d(-7), d(3)) == d(-1)
  assert js.modulo(d(5.5), d(2.0)) == d(1.5)
  // y = 0 or non-finite x → NaN; finite x % Inf → x.
  assert js.modulo(d(7), d(0)) == a("js_nan")
  assert js.modulo(a("js_inf"), d(3)) == a("js_nan")
  assert js.modulo(d(7), a("js_inf")) == d(7)
}

// ───────────────────────────── relational: lt / le / gt / ge ─────────────────────────────

pub fn relational_numeric_test() {
  assert js.lt(d(1), d(2)) == 1
  assert js.lt(d(2.5), d(2)) == 0
  assert js.le(d(2), d(2)) == 1
  assert js.gt(d(3), d(2)) == 1
  assert js.ge(d(2), d(3)) == 0
}

pub fn relational_nan_test() {
  // Every relational involving NaN is false (§7.2.13).
  assert js.lt(a("js_nan"), d(1)) == 0
  assert js.gt(a("js_nan"), d(1)) == 0
  assert js.le(a("js_nan"), a("js_nan")) == 0
}

pub fn relational_string_test() {
  // Two strings compare lexicographically; string vs number goes numeric
  // ("2" < 10 is true, though "2" > "10" byte-wise).
  assert js.lt(d("a"), d("b")) == 1
  assert js.lt(d("b"), d("a")) == 0
  assert js.ge(d("abc"), d("abc")) == 1
  assert js.lt(d("2"), d(10)) == 1
  assert js.lt(d("10"), d(9)) == 0
}

pub fn relational_coercion_test() {
  // ToNumber-ish: true→1, null→0, undefined→NaN (⇒ always false).
  assert js.lt(a("true"), d(2)) == 1
  assert js.lt(a("null"), d(1)) == 1
  assert js.lt(a("undefined"), d(1)) == 0
}

// ───────────────────────────── strict_eq / eq ─────────────────────────────

pub fn strict_eq_test() {
  // One number type: 1 === 1.0. NaN ≠ NaN. +0 === -0 (§7.2.16).
  assert js.strict_eq(d(1), d(1.0)) == 1
  assert js.strict_eq(a("js_nan"), a("js_nan")) == 0
  assert js.strict_eq(d(0), d(-0.0)) == 1
  assert js.strict_eq(d("a"), d("a")) == 1
  assert js.strict_eq(d("a"), d("b")) == 0
  assert js.strict_eq(a("true"), a("true")) == 1
  assert js.strict_eq(a("true"), d(1)) == 0
  assert js.strict_eq(a("null"), a("undefined")) == 0
}

pub fn strict_eq_identity_test() {
  let o1 = js.new_object()
  let o2 = js.new_object()
  assert js.strict_eq(o1, o1) == 1
  assert js.strict_eq(o1, o2) == 0
}

pub fn eq_test() {
  // Loose ==: null == undefined; number == string; boolean → number (§7.2.15).
  assert js.eq(a("null"), a("undefined")) == 1
  assert js.eq(d("1"), d(1)) == 1
  assert js.eq(a("true"), d(1)) == 1
  assert js.eq(a("false"), d("")) == 1
  // v1: object vs primitive is 0 (no ToPrimitive); object == object by identity.
  let o = js.new_object()
  assert js.eq(o, d(1)) == 0
  assert js.eq(o, o) == 1
}

// ───────────────────────────── truthy ─────────────────────────────

pub fn truthy_falsy_table_test() {
  assert js.truthy(a("false")) == 0
  assert js.truthy(a("null")) == 0
  assert js.truthy(a("undefined")) == 0
  assert js.truthy(a("js_nan")) == 0
  assert js.truthy(d(0)) == 0
  assert js.truthy(d(0.0)) == 0
  assert js.truthy(d(-0.0)) == 0
  assert js.truthy(d("")) == 0
}

pub fn truthy_truthy_table_test() {
  assert js.truthy(a("true")) == 1
  assert js.truthy(d(1)) == 1
  assert js.truthy(d(-1)) == 1
  assert js.truthy(d("a")) == 1
  assert js.truthy(a("js_inf")) == 1
  assert js.truthy(a("js_neg_inf")) == 1
  assert js.truthy(js.new_object()) == 1
  assert js.truthy(d(fn() { 1 })) == 1
}

// ───────────────────────────── to_string / type_of ─────────────────────────────

pub fn to_string_number_test() {
  // Integral doubles print integer-style: String(5.0) is "5", String(-0.0) is "0".
  assert js.to_string(d(5)) == bs("5")
  assert js.to_string(d(5.0)) == bs("5")
  assert js.to_string(d(-5)) == bs("-5")
  assert js.to_string(d(-0.0)) == bs("0")
  assert js.to_string(d(1.5)) == bs("1.5")
}

pub fn to_string_sentinel_and_atom_test() {
  assert js.to_string(a("js_nan")) == bs("NaN")
  assert js.to_string(a("js_inf")) == bs("Infinity")
  assert js.to_string(a("js_neg_inf")) == bs("-Infinity")
  assert js.to_string(a("true")) == bs("true")
  assert js.to_string(a("false")) == bs("false")
  assert js.to_string(a("null")) == bs("null")
  assert js.to_string(a("undefined")) == bs("undefined")
}

pub fn to_string_string_object_fun_test() {
  assert js.to_string(d("pass")) == bs("pass")
  assert js.to_string(js.new_object()) == bs("[object Object]")
  assert js.to_string(d(fn() { 1 })) == bs("function")
}

pub fn type_of_test() {
  assert js.type_of(d(5)) == bs("number")
  assert js.type_of(d(1.5)) == bs("number")
  assert js.type_of(a("js_nan")) == bs("number")
  assert js.type_of(a("js_inf")) == bs("number")
  assert js.type_of(d("s")) == bs("string")
  assert js.type_of(a("true")) == bs("boolean")
  assert js.type_of(a("undefined")) == bs("undefined")
  // typeof null is "object", the eternal wart; refs and funs classify too.
  assert js.type_of(a("null")) == bs("object")
  assert js.type_of(js.new_object()) == bs("object")
  assert js.type_of(d(fn() { 1 })) == bs("function")
}

pub fn undefined_sentinel_test() {
  assert js.undefined_sentinel() == atom.create("undefined")
}

// ───────────────────────────── cells ─────────────────────────────

pub fn cell_roundtrip_test() {
  let cell = js.cell_new(d(41))
  assert js.cell_get(cell) == d(41)
  // cell_set stores and returns `undefined` (the JS statement-position contract).
  assert js.cell_set(cell, d(42)) == a("undefined")
  assert js.cell_get(cell) == d(42)
}

pub fn cell_non_ref_type_error_test() {
  assert_type_error("cell_get", [d(5)])
}

// ───────────────────────────── objects ─────────────────────────────

pub fn object_roundtrip_test() {
  let o = js.new_object()
  assert js.get_prop(o, d("a")) == a("undefined")
  assert js.has_prop(o, d("a")) == 0
  // set_prop returns the value (JS assignment-expression value).
  assert js.set_prop(o, d("a"), d(7)) == d(7)
  assert js.get_prop(o, d("a")) == d(7)
  assert js.has_prop(o, d("a")) == 1
}

pub fn object_numeric_key_normalisation_test() {
  // o[5], o[5.0] and o["5"] are the same property (§6.1.7 keys are strings).
  let o = js.new_object()
  let _ = js.set_prop(o, d(5), d("x"))
  assert js.get_prop(o, d(5.0)) == d("x")
  assert js.get_prop(o, d("5")) == d("x")
  assert js.has_prop(o, d(5)) == 1
}

pub fn object_non_object_receiver_type_error_test() {
  assert_type_error("get_prop", [d(1), d("k")])
}

// ───────────────────────────── empty_list / console_log / not_callable ─────────────────────────────

pub fn empty_list_test() {
  // The workaround for the IR having no nil literal: [] on demand.
  let empty: List(Dynamic) = []
  assert js.empty_list() == d(empty)
}

pub fn console_log_returns_undefined_test() {
  // One cons-list argument; returns `undefined`. (Stdout formatting is exercised
  // by the arc-side E2E battery; here we pin the contract shape.)
  assert js.console_log(js.empty_list()) == a("undefined")
  assert js.console_log(d([d(1), d("a"), a("true")])) == a("undefined")
}

pub fn console_log_non_list_type_error_test() {
  assert_type_error("console_log", [d(5)])
}

pub fn not_callable_test() {
  assert_type_error("not_callable", [d(5)])
}

// ───────────────────────────── resolve_js registry (fail-closed dispatch) ─────────────────────────────

/// Every op string the arc emitter writes, with its arity. A missing `resolve_js`
/// arm makes `emit_module` fail (`UnknownJsOp`) — this is the drift alarm between
/// the emitter's op set and the registry.
const registry = [
  #("add", 2),
  #("sub", 2),
  #("mul", 2),
  #("neg", 1),
  #("div", 2),
  #("mod", 2),
  #("lt", 2),
  #("le", 2),
  #("gt", 2),
  #("ge", 2),
  #("strict_eq", 2),
  #("eq", 2),
  #("truthy", 1),
  #("to_string", 1),
  #("type_of", 1),
  #("undefined_sentinel", 0),
  #("cell_new", 1),
  #("cell_get", 1),
  #("cell_set", 2),
  #("new_object", 0),
  #("get_prop", 2),
  #("set_prop", 3),
  #("has_prop", 2),
  #("empty_list", 0),
  #("console_log", 1),
  #("not_callable", 1),
]

pub fn resolve_js_registers_every_emitter_op_test() {
  let params = ["a", "b", "c"]
  let functions =
    list.map(registry, fn(entry) {
      let #(op, arity) = entry
      let args =
        list.take(params, arity)
        |> list.map(ir.Var)
      ir.Function(
        name: "op_" <> op,
        params: list.take(params, arity)
          |> list.map(fn(p) { ir.Local(p, ir.TTerm) }),
        result: [ir.TTerm],
        locals: [],
        body: ir.CallHost("js", op, args),
      )
    })
  let module =
    ir.Module(
      name: "carder@rt_js@registry",
      uses_numerics: False,
      memories: [],
      globals: [],
      imports: [],
      functions: functions,
      exports: [],
      data_segments: [],
      tables: [],
      elements: [],
      tags: [],
      start: option_none(),
    )
  let assert Ok(_compiled) =
    emit_core.emit_module(module, instance.safe_default())
}

pub fn resolve_js_rejects_unknown_op_test() {
  let module =
    ir.Module(
      name: "carder@rt_js@unknown",
      uses_numerics: False,
      memories: [],
      globals: [],
      imports: [],
      functions: [
        ir.Function(
          name: "bad",
          params: [],
          result: [ir.TTerm],
          locals: [],
          body: ir.CallHost("js", "definitely_not_an_op", []),
        ),
      ],
      exports: [],
      data_segments: [],
      tables: [],
      elements: [],
      tags: [],
      start: option_none(),
    )
  let assert Error(_reason) =
    emit_core.emit_module(module, instance.safe_default())
}

@external(erlang, "gleam_stdlib", "identity")
fn coerce(x: a) -> b

fn option_none() -> a {
  coerce(atom.create("none"))
}
