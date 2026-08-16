//// `rt_js` — the JS runtime boundary (Phase-8 unit 05, K6; HANDOFF-arc-frontend.md §4).
////
//// The **real** JS-semantics runtime the arc frontend's emitter targets (v1 surface). Every
//// JS *semantic* that is not a first-class IR node — coercion, sentinel-aware IEEE arithmetic,
//// `typeof`, truthiness, mutable cells, objects, `console.log` — lives behind this module,
//// reached ONLY via `CallHost("js", op, args)`.
////
//// ## How the boundary reaches here (K6 / D3a — the capability chokepoint)
////
//// JS-semantic operations are **not** IR nodes (the IR stays source-agnostic, K1). The frontend
//// emits `CallHost("js", op, args)`; two build-time gates route it here, fail-closed:
////
////   1. `ir_lower` ADMITS the `"js"` capability (like the reserved `"std"` stdlib capability) —
////      so a `"js"` call is not `ForbiddenHost`. It admits the *capability* (provenance); it does
////      not validate the op.
////   2. `emit_core.emit_call_host` DISPATCHES the op through a build-fixed **literal `case`**
////      (`resolve_js`) to a function in the `Binding.js_runtime_module` atom (this module by
////      default), emitting `call 'carder@runtime@rt_js':'<fn>'(Args…)`. The target module +
////      function are compile-time-fixed literal atoms — **never** built from `op`/`args` data, so
////      there is **no `apply(Mod,Fn,Args)`** and no `op` string can reach an arbitrary MFA (D3a).
////      An unrecognised `op` resolves to no function → `UnknownJsOp` (fail-closed): no call is
////      emitted at all.
////
//// So the whole authority surface of the JS boundary is the CLOSED set of ops `resolve_js`
//// recognises. Adding an op is: one literal arm in `emit_core.resolve_js` + the impl here (the
//// `"js"` capability is already admitted wholesale in `ir_lower`, so no `ir_lower` change per op).
////
//// ## The value model (FIXED — shared with the arc emitter; carder_rt_js_ffi.erl header)
////
//// A JS value is a **BEAM term** (`TTerm` to the IR — opaque): numbers are native BEAM
//// integers/floats with the sentinel atoms `js_nan`/`js_inf`/`js_neg_inf` for the three
//// unrepresentable doubles; booleans are `true`/`false`; `undefined`/`null` are those atoms;
//// strings are UTF-8 binaries; **cells** (mutable storage) are `make_ref()`s keyed into the
//// process dictionary (the `rt_state` `cell` model); **objects** are cells holding binary-keyed
//// maps; functions are BEAM funs (the IR's `make_closure`). Errors raise
//// `{js_error, Kind, Detail}` (JS try/catch integration is a later milestone).
////
//// ## Shape of this module
////
//// A typed FACADE: every op delegates 1:1 to `carder_rt_js_ffi` (hand-written Erlang), because
//// each op is dynamic by nature — it inspects arbitrary term shapes, catches `badarith` to
//// resolve IEEE overflow into the sentinels, and touches the process dictionary. The FFI header
//// documents the semantics per op and every known ECMAScript divergence; the doc comments here
//// give the contract. Ops that answer a JS boolean return an **i32 term `1`/`0`** (the IR's
//// truth-value convention, like `TermTest`).

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}

// ───────────────────────── arithmetic (sentinel-aware IEEE) ─────────────────────────

/// JS `+`. Either operand a string → concatenation (the other coerced via `to_string`; an
/// object/fun operand is a `type_error` — no ToPrimitive in v1). Otherwise numeric: NaN
/// propagates, `Infinity + -Infinity` is NaN, float overflow resolves to ±Infinity.
@external(erlang, "carder_rt_js_ffi", "add")
pub fn add(a: Dynamic, b: Dynamic) -> Dynamic

/// JS binary `-` (numeric only; non-numbers are a `type_error`). Sentinel-aware; overflow
/// resolves to ±Infinity by the minuend's sign.
@external(erlang, "carder_rt_js_ffi", "sub")
pub fn sub(a: Dynamic, b: Dynamic) -> Dynamic

/// JS `*` (numeric only). `Infinity × 0` is NaN; overflow resolves to ±Infinity by the
/// operands' signs.
@external(erlang, "carder_rt_js_ffi", "mul")
pub fn mul(a: Dynamic, b: Dynamic) -> Dynamic

/// JS unary `-` (numeric only). NaN stays NaN; the infinities flip sign.
@external(erlang, "carder_rt_js_ffi", "neg")
pub fn neg(a: Dynamic) -> Dynamic

/// JS `/` — always real division (`7/2` is `3.5`). `x/±0` → ±Infinity by the signs (`0/0` →
/// NaN, honouring a float zero's sign bit so `1/-0.0` is `-Infinity`); `finite/±Infinity` → a
/// signed zero; `±Inf/±Inf` → NaN; overflow → ±Infinity. (Erlang-reserved-word note: the op
/// string is `"div"`; the function is named `divide`.)
@external(erlang, "carder_rt_js_ffi", "divide")
pub fn divide(a: Dynamic, b: Dynamic) -> Dynamic

/// JS `%` — fmod carrying the DIVIDEND's sign. `y = ±0` or non-finite `x` → NaN; finite `x`
/// with infinite `y` → `x`. Integer pairs stay exact (`rem`). (Op string `"mod"`; function
/// `modulo`.)
@external(erlang, "carder_rt_js_ffi", "modulo")
pub fn modulo(a: Dynamic, b: Dynamic) -> Dynamic

// ───────────────────────── comparisons (i32 term 1|0) ─────────────────────────

/// JS `<` → i32 `1`/`0`. Two strings compare byte-wise lexicographically (diverges from JS's
/// UTF-16 code-unit order only for astral-plane edge cases — FFI header note); anything else
/// coerces to a number (undefined/objects → NaN); any NaN-involving compare is `0`.
@external(erlang, "carder_rt_js_ffi", "lt")
pub fn lt(a: Dynamic, b: Dynamic) -> Int

/// JS `<=` → i32 `1`/`0` (same coercion/NaN rules as `lt`).
@external(erlang, "carder_rt_js_ffi", "le")
pub fn le(a: Dynamic, b: Dynamic) -> Int

/// JS `>` → i32 `1`/`0` (same coercion/NaN rules as `lt`).
@external(erlang, "carder_rt_js_ffi", "gt")
pub fn gt(a: Dynamic, b: Dynamic) -> Int

/// JS `>=` → i32 `1`/`0` (same coercion/NaN rules as `lt`).
@external(erlang, "carder_rt_js_ffi", "ge")
pub fn ge(a: Dynamic, b: Dynamic) -> Int

/// JS `===` → i32 `1`/`0`: same JS type AND value. `NaN ≠ NaN`; `+0 == -0`; ints and floats
/// are ONE number type (`1 === 1.0`); objects/cells/funs compare by identity.
@external(erlang, "carder_rt_js_ffi", "strict_eq")
pub fn strict_eq(a: Dynamic, b: Dynamic) -> Int

/// The JS `==` SUBSET → i32 `1`/`0`: `strict_eq`, plus `null == undefined`, number == string
/// (string → number), and boolean → number coercion. An object against a primitive is `0`
/// (no ToPrimitive in v1); object == object is reference identity.
@external(erlang, "carder_rt_js_ffi", "eq")
pub fn eq(a: Dynamic, b: Dynamic) -> Int

// ───────────────────────── truthiness / coercion ─────────────────────────

/// JS ToBoolean → i32 `1`/`0`. Falsy: `false`, `null`, `undefined`, NaN, every numeric zero
/// (`0`, `0.0`, `-0.0`), the empty string. Everything else — including empty objects and all
/// funs — is truthy.
@external(erlang, "carder_rt_js_ffi", "truthy")
pub fn truthy(v: Dynamic) -> Int

/// JS ToString → a binary. Strings pass through; integral floats < 1e21 print integer-style
/// (`String(5.0)` is `"5"`); other floats print shortest-round-trip (`[short]` — exponent
/// FORMATTING diverges from Number::toString at the extremes, FFI header note); sentinels are
/// `"NaN"`/`"Infinity"`/`"-Infinity"`; objects are `"[object Object]"`; funs are the
/// `"function"` placeholder.
@external(erlang, "carder_rt_js_ffi", "to_string")
pub fn to_string(v: Dynamic) -> BitArray

/// JS `typeof` → a binary. The sentinel numbers are `"number"`; `null` is (famously)
/// `"object"`; cells/objects (refs) are `"object"`; funs are `"function"`; the stub's
/// number/boolean/string/undefined arms are preserved.
@external(erlang, "carder_rt_js_ffi", "type_of")
pub fn type_of(x: Dynamic) -> BitArray

/// The `undefined` sentinel — the BEAM atom `undefined` (arity 0; the one op kept verbatim
/// from the Phase-8 stub).
pub fn undefined_sentinel() -> Atom {
  atom.create("undefined")
}

// ───────────────────────── cells (mutable captures + object storage) ─────────────────────────

/// A fresh mutable cell holding `init` — a `make_ref()` keyed into THIS process's dictionary
/// (the same one-instance-one-process model as `rt_state`'s `cell` strategy). The handle is
/// the capture value for a mutated (`is_boxed`) JS local.
@external(erlang, "carder_rt_js_ffi", "cell_new")
pub fn cell_new(init: Dynamic) -> Dynamic

/// The cell's current value. A non-reference receiver is a `type_error`.
@external(erlang, "carder_rt_js_ffi", "cell_get")
pub fn cell_get(cell: Dynamic) -> Dynamic

/// Store `v` in the cell; returns `undefined`.
@external(erlang, "carder_rt_js_ffi", "cell_set")
pub fn cell_set(cell: Dynamic, v: Dynamic) -> Dynamic

// ───────────────────────── objects ─────────────────────────

/// A fresh empty object: a cell holding an empty map (binary keys → term values).
@external(erlang, "carder_rt_js_ffi", "new_object")
pub fn new_object() -> Dynamic

/// `obj[key]` → the stored value, or `undefined` when absent (own properties only — no
/// prototype chain in v1). Keys are binaries; a NUMBER key normalizes to its JS string form
/// (`5`, `5.0` and `"5"` are the same key). A non-object receiver is a `type_error`.
@external(erlang, "carder_rt_js_ffi", "get_prop")
pub fn get_prop(obj: Dynamic, key: Dynamic) -> Dynamic

/// `obj[key] = v` — stores and returns `v` (the value of a JS assignment).
@external(erlang, "carder_rt_js_ffi", "set_prop")
pub fn set_prop(obj: Dynamic, key: Dynamic, v: Dynamic) -> Dynamic

/// `key in obj` → i32 `1`/`0` (own properties only, like `get_prop`).
@external(erlang, "carder_rt_js_ffi", "has_prop")
pub fn has_prop(obj: Dynamic, key: Dynamic) -> Int

// ───────────────────────── lists / console / misc ─────────────────────────

/// The empty BEAM list `[]` (arity 0) — the nil tail an args-cons-list build starts from.
/// Exists because the IR has no `[]` literal (`ConstNil` would be the upstream fix).
@external(erlang, "carder_rt_js_ffi", "empty_list")
pub fn empty_list() -> Dynamic

/// `console.log(...args)` — takes ONE term, the cons list of the arguments. Prints them
/// space-separated on one line to stdout (strings bare, everything else via the `to_string`
/// rules) and returns `undefined`. A non-list argument is a `type_error`.
@external(erlang, "carder_rt_js_ffi", "console_log")
pub fn console_log(args: Dynamic) -> Dynamic

/// The emitter's guard for `callee(...)` where the callee failed `is_fun`: ALWAYS raises
/// `{js_error, type_error, <the value>}`. (Typed as returning `Dynamic` so a `Let` can bind
/// it; it never returns.)
@external(erlang, "carder_rt_js_ffi", "not_callable")
pub fn not_callable(v: Dynamic) -> Dynamic
