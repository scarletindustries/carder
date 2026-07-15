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
////      default), emitting `call 'twocore@runtime@rt_js':'<fn>'(Args…)`. The target module +
////      function are compile-time-fixed literal atoms — **never** built from `op`/`args` data, so
////      there is **no `apply(Mod,Fn,Args)`** and no `op` string can reach an arbitrary MFA (D3a).
////      An unrecognised `op` resolves to no function → `UnknownJsOp` (fail-closed): no call is
////      emitted at all.
////
//// So the whole authority surface of the JS boundary is the CLOSED set of ops `resolve_js`
//// recognises. Adding an op is: one literal arm in `emit_core.resolve_js` + the impl here (the
//// `"js"` capability is already admitted wholesale in `ir_lower`, so no `ir_lower` change per op).
////
//// ## The value model (FIXED — shared with the arc emitter; twocore_rt_js_ffi.erl header)
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
//// A typed FACADE: every op delegates 1:1 to `twocore_rt_js_ffi` (hand-written Erlang), because
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
@external(erlang, "twocore_rt_js_ffi", "add")
pub fn add(a: Dynamic, b: Dynamic) -> Dynamic

/// JS binary `-` (numeric only; non-numbers are a `type_error`). Sentinel-aware; overflow
/// resolves to ±Infinity by the minuend's sign.
@external(erlang, "twocore_rt_js_ffi", "sub")
pub fn sub(a: Dynamic, b: Dynamic) -> Dynamic

/// JS `*` (numeric only). `Infinity × 0` is NaN; overflow resolves to ±Infinity by the
/// operands' signs.
@external(erlang, "twocore_rt_js_ffi", "mul")
pub fn mul(a: Dynamic, b: Dynamic) -> Dynamic

/// JS unary `-` (numeric only). NaN stays NaN; the infinities flip sign.
@external(erlang, "twocore_rt_js_ffi", "neg")
pub fn neg(a: Dynamic) -> Dynamic

/// JS `/` — always real division (`7/2` is `3.5`). `x/±0` → ±Infinity by the signs (`0/0` →
/// NaN, honouring a float zero's sign bit so `1/-0.0` is `-Infinity`); `finite/±Infinity` → a
/// signed zero; `±Inf/±Inf` → NaN; overflow → ±Infinity. (Erlang-reserved-word note: the op
/// string is `"div"`; the function is named `divide`.)
@external(erlang, "twocore_rt_js_ffi", "divide")
pub fn divide(a: Dynamic, b: Dynamic) -> Dynamic

/// JS `%` — fmod carrying the DIVIDEND's sign. `y = ±0` or non-finite `x` → NaN; finite `x`
/// with infinite `y` → `x`. Integer pairs stay exact (`rem`). (Op string `"mod"`; function
/// `modulo`.)
@external(erlang, "twocore_rt_js_ffi", "modulo")
pub fn modulo(a: Dynamic, b: Dynamic) -> Dynamic

// ───────────────────────── comparisons (i32 term 1|0) ─────────────────────────

/// JS `<` → i32 `1`/`0`. Two strings compare byte-wise lexicographically (diverges from JS's
/// UTF-16 code-unit order only for astral-plane edge cases — FFI header note); anything else
/// coerces to a number (undefined/objects → NaN); any NaN-involving compare is `0`.
@external(erlang, "twocore_rt_js_ffi", "lt")
pub fn lt(a: Dynamic, b: Dynamic) -> Int

/// JS `<=` → i32 `1`/`0` (same coercion/NaN rules as `lt`).
@external(erlang, "twocore_rt_js_ffi", "le")
pub fn le(a: Dynamic, b: Dynamic) -> Int

/// JS `>` → i32 `1`/`0` (same coercion/NaN rules as `lt`).
@external(erlang, "twocore_rt_js_ffi", "gt")
pub fn gt(a: Dynamic, b: Dynamic) -> Int

/// JS `>=` → i32 `1`/`0` (same coercion/NaN rules as `lt`).
@external(erlang, "twocore_rt_js_ffi", "ge")
pub fn ge(a: Dynamic, b: Dynamic) -> Int

/// JS `===` → i32 `1`/`0`: same JS type AND value. `NaN ≠ NaN`; `+0 == -0`; ints and floats
/// are ONE number type (`1 === 1.0`); objects/cells/funs compare by identity.
@external(erlang, "twocore_rt_js_ffi", "strict_eq")
pub fn strict_eq(a: Dynamic, b: Dynamic) -> Int

/// The JS `==` SUBSET → i32 `1`/`0`: `strict_eq`, plus `null == undefined`, number == string
/// (string → number), and boolean → number coercion. An object against a primitive is `0`
/// (no ToPrimitive in v1); object == object is reference identity.
@external(erlang, "twocore_rt_js_ffi", "eq")
pub fn eq(a: Dynamic, b: Dynamic) -> Int

// ───────────────────────── truthiness / coercion ─────────────────────────

/// JS ToBoolean → i32 `1`/`0`. Falsy: `false`, `null`, `undefined`, NaN, every numeric zero
/// (`0`, `0.0`, `-0.0`), the empty string. Everything else — including empty objects and all
/// funs — is truthy.
@external(erlang, "twocore_rt_js_ffi", "truthy")
pub fn truthy(v: Dynamic) -> Int

/// JS ToNumber — the coercion behind unary `+` and `Number(x)`. Numbers pass through;
/// `true`→1, `false`/`null`→0, `undefined`→NaN; a string parses as a decimal/float
/// (`" 5 "`→5, `""`→0, non-numeric→NaN; radix prefixes coerce to NaN — FFI header
/// note); objects/functions →NaN (no ToPrimitive in v1). NaN/±Infinity are the
/// `js_nan`/`js_inf`/`js_neg_inf` sentinels.
@external(erlang, "twocore_rt_js_ffi", "to_number")
pub fn to_number(v: Dynamic) -> Dynamic

// ───────────────────────── bitwise / shift (int32) ─────────────────────────
// Each operand is coerced with ToInt32 (ToUint32 for the left of `>>>` and shift
// counts), the op runs on 32-bit two's-complement, and the result is a signed int32
// — except `>>>`, which yields an unsigned uint32 (so `-1 >>> 0` is 4294967295).

/// JS `&` — bitwise AND on ToInt32 operands → signed int32.
@external(erlang, "twocore_rt_js_ffi", "bit_and")
pub fn bit_and(a: Dynamic, b: Dynamic) -> Dynamic

/// JS `|` — bitwise OR on ToInt32 operands → signed int32.
@external(erlang, "twocore_rt_js_ffi", "bit_or")
pub fn bit_or(a: Dynamic, b: Dynamic) -> Dynamic

/// JS `^` — bitwise XOR on ToInt32 operands → signed int32.
@external(erlang, "twocore_rt_js_ffi", "bit_xor")
pub fn bit_xor(a: Dynamic, b: Dynamic) -> Dynamic

/// JS `~` — bitwise NOT of ToInt32(a) → signed int32 (`~x === -(x)-1`).
@external(erlang, "twocore_rt_js_ffi", "bit_not")
pub fn bit_not(a: Dynamic) -> Dynamic

/// JS `<<` — left shift ToInt32(a) by `ToUint32(b) & 31`, re-wrapped to signed int32.
@external(erlang, "twocore_rt_js_ffi", "shl")
pub fn shl(a: Dynamic, b: Dynamic) -> Dynamic

/// JS `>>` — sign-propagating right shift of ToInt32(a) by `ToUint32(b) & 31`.
@external(erlang, "twocore_rt_js_ffi", "shr")
pub fn shr(a: Dynamic, b: Dynamic) -> Dynamic

/// JS `>>>` — zero-fill right shift of ToUint32(a) by `ToUint32(b) & 31` → uint32.
@external(erlang, "twocore_rt_js_ffi", "ushr")
pub fn ushr(a: Dynamic, b: Dynamic) -> Dynamic

/// JS `**` — `Number::exponentiate(ToNumber(a), ToNumber(b))`. Handles the spec
/// special cases (`x ** ±0` → 1 even for NaN base; NaN/±Infinity operands; a negative
/// base with a non-integer exponent → NaN); finite integer/integer stays exact.
@external(erlang, "twocore_rt_js_ffi", "pow")
pub fn pow(a: Dynamic, b: Dynamic) -> Dynamic

// ───────────────────────── Math ─────────────────────────
// `Math.method(args)`; the method is an atom. Each coerces with ToNumber and returns a
// JS number. `Math.PI`/`Math.E`/… constants are inlined at compile time.

/// Unary `Math` function (`floor`, `ceil`, `round`, `trunc`, `abs`, `sign`, `sqrt`,
/// `cbrt`, `exp`, `log`/`log2`/`log10`, `sin`/`cos`/`tan`/`asin`/`acos`/`atan`).
@external(erlang, "twocore_rt_js_ffi", "math_unary")
pub fn math_unary(method: Dynamic, x: Dynamic) -> Dynamic

/// Binary `Math` function: `pow(a, b)` or `atan2(y, x)`.
@external(erlang, "twocore_rt_js_ffi", "math_binary")
pub fn math_binary(method: Dynamic, a: Dynamic, b: Dynamic) -> Dynamic

/// Variadic `Math` function over a cons list of args: `min`, `max`, `hypot`.
@external(erlang, "twocore_rt_js_ffi", "math_reduce")
pub fn math_reduce(method: Dynamic, args: Dynamic) -> Dynamic

/// `Math.random()` → a float in (0, 1).
@external(erlang, "twocore_rt_js_ffi", "math_random")
pub fn math_random() -> Dynamic

/// JS ToString → a binary. Strings pass through; integral floats < 1e21 print integer-style
/// (`String(5.0)` is `"5"`); other floats print shortest-round-trip (`[short]` — exponent
/// FORMATTING diverges from Number::toString at the extremes, FFI header note); sentinels are
/// `"NaN"`/`"Infinity"`/`"-Infinity"`; objects are `"[object Object]"`; funs are the
/// `"function"` placeholder.
@external(erlang, "twocore_rt_js_ffi", "to_string")
pub fn to_string(v: Dynamic) -> BitArray

/// JS `typeof` → a binary. The sentinel numbers are `"number"`; `null` is (famously)
/// `"object"`; cells/objects (refs) are `"object"`; funs are `"function"`; the stub's
/// number/boolean/string/undefined arms are preserved.
@external(erlang, "twocore_rt_js_ffi", "type_of")
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
@external(erlang, "twocore_rt_js_ffi", "cell_new")
pub fn cell_new(init: Dynamic) -> Dynamic

/// The cell's current value. A non-reference receiver is a `type_error`.
@external(erlang, "twocore_rt_js_ffi", "cell_get")
pub fn cell_get(cell: Dynamic) -> Dynamic

/// Store `v` in the cell; returns `undefined`.
@external(erlang, "twocore_rt_js_ffi", "cell_set")
pub fn cell_set(cell: Dynamic, v: Dynamic) -> Dynamic

// ───────────────────────── objects ─────────────────────────

/// A fresh empty object: a cell holding an empty map (binary keys → term values).
@external(erlang, "twocore_rt_js_ffi", "new_object")
pub fn new_object() -> Dynamic

/// The `globalThis` value (§19.3.1): THE global object, returned as a stable
/// per-instance singleton cell so that `globalThis === globalThis` and
/// `globalThis.globalThis === globalThis` hold by reference identity. It is a
/// cell, hence `typeof` "object" and never null.
@external(erlang, "twocore_rt_js_ffi", "globalthis_new")
pub fn globalthis_new() -> Dynamic

/// `new Number(x)` / `new String(x)` / `new Boolean(x)` — a primitive wrapper OBJECT.
/// `kind` is the atom `number`/`string`/`boolean`; `x` is boxed after coercion
/// (ToNumber/ToString/ToBoolean). Returns a cell (`typeof` "object") whose `valueOf`
/// unwraps to the boxed primitive and whose `toString`/string-coercion unwraps to its
/// string form; a `string` wrapper also exposes `.length` and index reads.
@external(erlang, "twocore_rt_js_ffi", "wrapper_new")
pub fn wrapper_new(kind: Dynamic, x: Dynamic) -> Dynamic

/// `new Name(msg)` / `Name(msg)` — construct a JS error VALUE `{js_err, Name, Msg}`.
/// `name` is the binary constructor name ("TypeError", "Error", …); `msg_arg` is
/// the raw first constructor argument, or the `undefined` atom when none was given
/// (an `undefined` message becomes "" per §20.5.1.1). The result is a throwable
/// cell carrying readable `.name`/`.message` and a spec `toString`.
@external(erlang, "twocore_rt_js_ffi", "error_make")
pub fn error_make(name: Dynamic, msg_arg: Dynamic) -> Dynamic

/// An error constructor as a first-class fun VALUE — so a BARE `TypeError`
/// reference has `typeof` "function" and, if applied, constructs an error. `name`
/// is the binary constructor name.
@external(erlang, "twocore_rt_js_ffi", "error_ctor")
pub fn error_ctor(name: Dynamic) -> Dynamic

/// A built-in constructor (`Array`/`Object`/`String`/`Number`/`Boolean`/
/// `Function`/`RegExp`/`Date`/`Map`/`Set`) as a first-class fun VALUE — so a BARE
/// `Array` reference has `typeof` "function" and can be assigned/passed. The fun
/// closes over the (binary) `name`, so two references to the same constructor are
/// fun-identical (`Array === Array`, `[].constructor === Array`). Applied, it does
/// the constructor's call-without-`new` coercion.
@external(erlang, "twocore_rt_js_ffi", "builtin_ctor")
pub fn builtin_ctor(name: Dynamic) -> Dynamic

/// A built-in constructor's `.prototype` as a STABLE per-constructor marker cell,
/// memoised per `name` so `Array.prototype === Array.prototype` holds by identity.
/// Not a real prototype object (it carries no methods); `X.prototype.<method>` is
/// routed to the dedicated proto-fn ops by the frontend before this.
@external(erlang, "twocore_rt_js_ffi", "builtin_prototype")
pub fn builtin_prototype(name: Dynamic) -> Dynamic

/// `Object(x)` (call without `new`, §20.1.1.1) — ToObject-ish: an object flows
/// through unchanged, `undefined`/`null` yield a fresh object, a primitive is
/// returned as-is (no wrapper boxing in v1).
@external(erlang, "twocore_rt_js_ffi", "to_object")
pub fn to_object(x: Dynamic) -> Dynamic

/// `Error.isError(v)` (§20.5.2.1) → `1` when `v` is a genuine Error value (a cell
/// with an [[ErrorData]] slot, i.e. one made by `new Error`/a NativeError/a caught
/// engine error), `0` for every primitive and every ordinary object merely shaped
/// like an error. Returns an i32 the caller wraps into a JS boolean.
@external(erlang, "twocore_rt_js_ffi", "error_is_error")
pub fn error_is_error(x: Dynamic) -> Int

/// Classify a caught BEAM `reason` for a JS `try`/`catch`: when it is the runtime's
/// INTERNAL engine-error convention `{js_error, Kind, Detail}` (a `type_error` /
/// `range_error` / … raised by a bad primitive op), CONVERT it to a JS-level error VALUE
/// and return `Ok([err])` — `err` a fresh `{js_err, Name, Message}` cell whose `Name` is
/// the matching ECMAScript constructor ("TypeError", …), so the caught `e` answers
/// `.name` / `.message` / `instanceof` correctly. Returns `Error(Nil)` for ANY other
/// reason (an explicit-`throw` `{wasm_exn,_,_}` handled by `rt_exn.match_tag` upstream, a
/// `{wasm_trap,_}` trap, an exit, an arbitrary BEAM error) — the emitted catch then
/// RE-RAISES it, so traps / host aborts propagate out of the `try` untouched (T7). The
/// one-element list mirrors `rt_exn.match_tag`'s `Ok(Payload)` shape so ONE catch-binding
/// pattern serves both the explicit-throw and engine-error channels.
@external(erlang, "twocore_rt_js_ffi", "js_error_to_value")
pub fn js_error_to_value(reason: Dynamic) -> Result(List(Dynamic), Nil)

/// `obj[key]` → the stored value, or `undefined` when absent (own properties only — no
/// prototype chain in v1). Keys are binaries; a NUMBER key normalizes to its JS string form
/// (`5`, `5.0` and `"5"` are the same key). A non-object receiver is a `type_error`.
@external(erlang, "twocore_rt_js_ffi", "get_prop")
pub fn get_prop(obj: Dynamic, key: Dynamic) -> Dynamic

/// `obj[key] = v` — stores and returns `v` (the value of a JS assignment).
@external(erlang, "twocore_rt_js_ffi", "set_prop")
pub fn set_prop(obj: Dynamic, key: Dynamic, v: Dynamic) -> Dynamic

/// Define an own DATA property `obj[key] = v` with [[DefineOwnProperty]]
/// semantics — overwrites any existing value or accessor. Returns `v`.
@external(erlang, "twocore_rt_js_ffi", "define_data")
pub fn define_data(obj: Dynamic, key: Dynamic, v: Dynamic) -> Dynamic

/// Wrap a generator step closure into a generator object.
@external(erlang, "twocore_rt_js_ffi", "gen_make")
pub fn gen_make(step: Dynamic) -> Dynamic

/// `gen.next(v)` — advance a generator (or delegate to a user `next` method).
@external(erlang, "twocore_rt_js_ffi", "gen_next")
pub fn gen_next(gen: Dynamic, args: Dynamic) -> Dynamic

/// Materialize the source of a `for-of` as an array: arrays and strings pass
/// through, a generator is drained to an array, anything else becomes empty.
@external(erlang, "twocore_rt_js_ffi", "iter_array")
pub fn iter_array(source: Dynamic) -> Dynamic

/// Iterator.prototype.toArray — drain a generator/iterator receiver into a new
/// array (§27.1.4.19).
@external(erlang, "twocore_rt_js_ffi", "iter_to_array")
pub fn iter_to_array(source: Dynamic) -> Dynamic

/// Iterator.prototype.take — a lazy iterator yielding at most `limit` values
/// (§27.1.4.17). A negative limit raises a RangeError.
@external(erlang, "twocore_rt_js_ffi", "iter_take")
pub fn iter_take(source: Dynamic, limit: Dynamic) -> Dynamic

/// Iterator.prototype.drop — a lazy iterator skipping the first `limit` values
/// (§27.1.4.4). A negative limit raises a RangeError.
@external(erlang, "twocore_rt_js_ffi", "iter_drop")
pub fn iter_drop(source: Dynamic, limit: Dynamic) -> Dynamic

/// Read a static class field `Class.field` (`class` is the module-qualified name).
/// Returns `undefined` if unset.
@external(erlang, "twocore_rt_js_ffi", "static_get")
pub fn static_get(class: Dynamic, field: Dynamic) -> Dynamic

/// Read a static field along a chain of class keys (receiver first, then
/// ancestors); the first class that owns the field wins. Returns `undefined`.
@external(erlang, "twocore_rt_js_ffi", "static_get_chain")
pub fn static_get_chain(keys: Dynamic, field: Dynamic) -> Dynamic

/// Write a static class field `Class.field = v`; returns `v`.
@external(erlang, "twocore_rt_js_ffi", "static_set")
pub fn static_set(class: Dynamic, field: Dynamic, v: Dynamic) -> Dynamic

/// Install an accessor property: `getter`/`setter` are `this`-bound closures or
/// `undefined`. Defines `obj.key` as a getter/setter pair; returns `undefined`.
@external(erlang, "twocore_rt_js_ffi", "define_accessor")
pub fn define_accessor(
  obj: Dynamic,
  key: Dynamic,
  getter: Dynamic,
  setter: Dynamic,
) -> Dynamic

/// `key in obj` → i32 `1`/`0` (own properties only, like `get_prop`).
@external(erlang, "twocore_rt_js_ffi", "has_prop")
pub fn has_prop(obj: Dynamic, key: Dynamic) -> Int

/// `delete obj[key]` — remove the property; returns `true` (non-strict).
@external(erlang, "twocore_rt_js_ffi", "delete_prop")
pub fn delete_prop(obj: Dynamic, key: Dynamic) -> Dynamic

// ───────────────────────── arrays ─────────────────────────
// A JS array is a cell holding `{js_array, Length, Map}`. `typeof` is "object";
// `get_prop`/`set_prop`/`has_prop` above are array-aware (integer indices + `length`).

/// `[e0, e1, …]` — build an array from the cons list of its elements.
@external(erlang, "twocore_rt_js_ffi", "new_array")
pub fn new_array(elements: Dynamic) -> Dynamic

/// `Array(...)` / `new Array(...)` — a single numeric argument is the new array's
/// length (a sparse array of holes); any other argument list becomes the elements.
@external(erlang, "twocore_rt_js_ffi", "array_construct")
pub fn array_construct(args: Dynamic) -> Dynamic

/// `arr.push(...vals)` — append each element of the cons list `vals`; returns the
/// array's new length.
@external(erlang, "twocore_rt_js_ffi", "array_push")
pub fn array_push(arr: Dynamic, vals: Dynamic) -> Dynamic

/// `arr.pop()` — remove and return the last element (`undefined` when empty).
@external(erlang, "twocore_rt_js_ffi", "array_pop")
pub fn array_pop(arr: Dynamic) -> Dynamic

/// `Array.isArray(x)` → i32 `1`/`0`.
@external(erlang, "twocore_rt_js_ffi", "is_array")
pub fn is_array(x: Dynamic) -> Int

/// Spread `value` (an array's elements or a string's chars) into `target` in place;
/// behind array-literal spread `[...a]`.
@external(erlang, "twocore_rt_js_ffi", "array_spread_into")
pub fn array_spread_into(target: Dynamic, value: Dynamic) -> Dynamic

/// Apply a JS function value to a runtime-length argument list (behind call spread
/// `f(...args)`); arity-adaptive.
@external(erlang, "twocore_rt_js_ffi", "apply_fn")
pub fn apply_fn(f: Dynamic, args: Dynamic) -> Dynamic

/// `f.call(thisArg, ...args)` — apply function value `f` to the arguments after
/// `thisArg` (which is ignored: plain functions carry no receiver here). `args` is
/// the full call argument list `[thisArg, ...rest]`; a non-function receiver
/// delegates to a same-named user `call` method.
@external(erlang, "twocore_rt_js_ffi", "func_call")
pub fn func_call(f: Dynamic, args: Dynamic) -> Dynamic

/// `f.apply(thisArg, argArray)` — apply function value `f` to the elements of
/// `argArray` (a null/undefined `argArray` means no arguments; `thisArg` is
/// ignored). `args` is the full call argument list `[thisArg, argArray]`; a
/// non-function receiver delegates to a same-named user `apply` method.
@external(erlang, "twocore_rt_js_ffi", "func_apply")
pub fn func_apply(f: Dynamic, args: Dynamic) -> Dynamic

/// Pad (with undefined) or truncate an argument list to exactly `n` elements, so a
/// spread `new C(...args)` can call the fixed-arity constructor.
@external(erlang, "twocore_rt_js_ffi", "fit_list")
pub fn fit_list(args: Dynamic, n: Dynamic) -> Dynamic

/// The array's elements as a plain BEAM list (behind spread into a variadic sink).
@external(erlang, "twocore_rt_js_ffi", "array_to_list")
pub fn array_to_list(arr: Dynamic) -> Dynamic

/// `Array.from(x)` — a new array from an array/string/array-like.
@external(erlang, "twocore_rt_js_ffi", "array_from")
pub fn array_from(x: Dynamic) -> Dynamic

/// `Array.from(x, mapFn)` — array_from then mapFn(element, index) per element.
@external(erlang, "twocore_rt_js_ffi", "array_from_map")
pub fn array_from_map(x: Dynamic, map_fn: Dynamic) -> Dynamic

/// `arr.flat()` — flatten one level.
@external(erlang, "twocore_rt_js_ffi", "array_flat")
pub fn array_flat(arr: Dynamic, depth: Dynamic) -> Dynamic

/// `arr.fill(v, start, end)` — set elements in `[start, end)` to `v` in place
/// (defaults: start 0, end length); returns the array.
@external(erlang, "twocore_rt_js_ffi", "array_fill")
pub fn array_fill(
  arr: Dynamic,
  v: Dynamic,
  start: Dynamic,
  end: Dynamic,
) -> Dynamic

/// `arr.copyWithin(target, start, end)` — copy `[start, end)` to `target` in place;
/// returns the array.
@external(erlang, "twocore_rt_js_ffi", "array_copy_within")
pub fn array_copy_within(
  arr: Dynamic,
  target: Dynamic,
  start: Dynamic,
  end: Dynamic,
) -> Dynamic

/// `arr.splice(start, deleteCount, ...items)` — remove/insert in place (args as a
/// cons list); returns a new array of the removed elements.
@external(erlang, "twocore_rt_js_ffi", "array_splice")
pub fn array_splice(arr: Dynamic, args: Dynamic) -> Dynamic

/// `arr.at(i)` / `str.at(i)` — element at `i` (negative counts from the end), else
/// `undefined`.
@external(erlang, "twocore_rt_js_ffi", "array_at")
pub fn array_at(recv: Dynamic, i: Dynamic) -> Dynamic

/// `Array.prototype.<name>` as a first-class function value (the unbound method,
/// receiver-first). `name` is the method name; yields a callable whose `typeof`
/// is "function".
@external(erlang, "twocore_rt_js_ffi", "array_proto_fn")
pub fn array_proto_fn(name: Dynamic) -> Dynamic

/// `str.padStart(n, pad)` / `padEnd` — pad to length `n` (default pad is a space).
@external(erlang, "twocore_rt_js_ffi", "str_pad_start")
pub fn str_pad_start(str: Dynamic, n: Dynamic, pad: Dynamic) -> Dynamic

@external(erlang, "twocore_rt_js_ffi", "str_pad_end")
pub fn str_pad_end(str: Dynamic, n: Dynamic, pad: Dynamic) -> Dynamic

/// `String.fromCharCode(...codes)` — build a string from the cons list of code points.
@external(erlang, "twocore_rt_js_ffi", "string_from_char_code")
pub fn string_from_char_code(codes: Dynamic) -> Dynamic

/// `String.fromCodePoint(...points)` — build a string from full code points (no mask).
@external(erlang, "twocore_rt_js_ffi", "string_from_code_point")
pub fn string_from_code_point(points: Dynamic) -> Dynamic

/// `String.raw(template, ...subs)` — the default tagged-template tag: raw literal
/// segments interleaved with the stringified substitutions (`subs` a cons list).
@external(erlang, "twocore_rt_js_ffi", "string_raw")
pub fn string_raw(template: Dynamic, subs: Dynamic) -> Dynamic

/// `Date.now()` — milliseconds since the Unix epoch.
@external(erlang, "twocore_rt_js_ffi", "date_now")
pub fn date_now() -> Dynamic

/// `new Date(...)` — construct a Date cell from the argument cons list (no args →
/// now; one string → ISO parse; one Date → copy; one other → ToNumber; ≥2 → the
/// component form, treated as UTC).
@external(erlang, "twocore_rt_js_ffi", "date_new")
pub fn date_new(args: Dynamic) -> Dynamic

/// `Date.UTC(...)` — the time value (a number of ms, or NaN) for a component list.
@external(erlang, "twocore_rt_js_ffi", "date_utc")
pub fn date_utc(args: Dynamic) -> Dynamic

/// `Date.parse(s)` — ToString then parse as ISO 8601; the time value (ms) or NaN.
@external(erlang, "twocore_rt_js_ffi", "date_parse")
pub fn date_parse(s: Dynamic) -> Dynamic

/// A Date instance method (`getTime`/`valueOf`/`getUTCFullYear`/`toISOString`/…):
/// `recv` the receiver, `name` the JS method name (binary), `args` the full argument
/// cons list. Dispatches on `recv`'s tag; a non-Date receiver delegates to a user method.
@external(erlang, "twocore_rt_js_ffi", "date_call")
pub fn date_call(recv: Dynamic, name: Dynamic, args: Dynamic) -> Dynamic

/// `arr.flatMap(fn)` — map then flatten one level.
@external(erlang, "twocore_rt_js_ffi", "array_flat_map")
pub fn array_flat_map(arr: Dynamic, fn_: Dynamic) -> Dynamic

/// `arr.findLast(fn)` / `findLastIndex(fn)` — like find/findIndex, from the end.
@external(erlang, "twocore_rt_js_ffi", "array_find_last")
pub fn array_find_last(arr: Dynamic, fn_: Dynamic) -> Dynamic

@external(erlang, "twocore_rt_js_ffi", "array_find_last_index")
pub fn array_find_last_index(arr: Dynamic, fn_: Dynamic) -> Dynamic

/// `arr.lastIndexOf(x)` — last strict-equal index, or `-1`.
@external(erlang, "twocore_rt_js_ffi", "array_last_index_of")
pub fn array_last_index_of(arr: Dynamic, x: Dynamic, from: Dynamic) -> Dynamic

/// `num.toFixed(d)` — a fixed-point string with `d` decimals.
@external(erlang, "twocore_rt_js_ffi", "num_to_fixed")
pub fn num_to_fixed(n: Dynamic, d: Dynamic) -> Dynamic

/// `num.toExponential(d)` — exponential notation with `d` fraction digits
/// (undefined → the minimal digits that round-trip).
@external(erlang, "twocore_rt_js_ffi", "num_to_exponential")
pub fn num_to_exponential(n: Dynamic, d: Dynamic) -> Dynamic

/// `num.toPrecision(p)` — `p` significant digits (fixed or exponential per spec);
/// undefined precision is ToString.
@external(erlang, "twocore_rt_js_ffi", "num_to_precision")
pub fn num_to_precision(n: Dynamic, p: Dynamic) -> Dynamic

/// `recv.toString()` — a user `toString` method wins, else the default ToString.
@external(erlang, "twocore_rt_js_ffi", "to_string_dispatch")
pub fn to_string_dispatch(recv: Dynamic) -> Dynamic

/// `num.toString(radix)` — base-`radix` integer string (else default ToString).
@external(erlang, "twocore_rt_js_ffi", "num_to_string_radix")
pub fn num_to_string_radix(n: Dynamic, radix: Dynamic) -> Dynamic

// ───────────────────────── regex ─────────────────────────
// A `/pat/flags` literal compiles to an Erlang `re` (PCRE). `str.replace`/`str.split`
// above dispatch to the regex path when the pattern argument is a regex.

/// `/pattern/flags` — compile a regex (flags i/m/s map to caseless/multiline/dotall).
@external(erlang, "twocore_rt_js_ffi", "new_regex")
pub fn new_regex(pattern: Dynamic, flags: Dynamic) -> Dynamic

/// `new RegExp(pattern, flags)` / `RegExp(pattern, flags)` — resolve the pattern
/// (string or an existing RegExp whose source/flags are reused) and optional flags
/// per §22.2.3.1, then compile. `undefined` arguments become the empty pattern/flags.
@external(erlang, "twocore_rt_js_ffi", "regex_construct")
pub fn regex_construct(pattern: Dynamic, flags: Dynamic) -> Dynamic

/// `re.test(str)` → JS boolean (advances `lastIndex` for a global/sticky regex).
@external(erlang, "twocore_rt_js_ffi", "regex_test")
pub fn regex_test(re: Dynamic, str: Dynamic) -> Dynamic

/// `re.exec(str)` → an exec-result array (`[matched | captures]` with
/// `index`/`input`/`groups`), or `null`; updates `lastIndex` for global/sticky.
@external(erlang, "twocore_rt_js_ffi", "regex_exec")
pub fn regex_exec(re: Dynamic, str: Dynamic) -> Dynamic

/// `re.source` / `re.flags`.
@external(erlang, "twocore_rt_js_ffi", "regex_source")
pub fn regex_source(re: Dynamic) -> Dynamic

@external(erlang, "twocore_rt_js_ffi", "regex_flags")
pub fn regex_flags(re: Dynamic) -> Dynamic

/// `str.match(re)` → array of matches (global) or the exec array
/// (`[full, groups…]` with index/input/groups) non-global, else null.
@external(erlang, "twocore_rt_js_ffi", "str_match")
pub fn str_match(str: Dynamic, re: Dynamic) -> Dynamic

/// `str.search(re)` → code-point index of the first match, or -1.
@external(erlang, "twocore_rt_js_ffi", "str_search")
pub fn str_search(str: Dynamic, re: Dynamic) -> Dynamic

// ───────────────────────── Map / Set ─────────────────────────
// `new Map()`/`new Set()`; the methods delegate to a same-named user method when the
// receiver is a plain object, so they don't shadow user APIs. `.size` reads via get_prop.

/// `new Map(init?)` / `new Set(init?)` — optionally seeded from an array (of pairs).
@external(erlang, "twocore_rt_js_ffi", "new_map")
pub fn new_map(init: Dynamic) -> Dynamic

@external(erlang, "twocore_rt_js_ffi", "new_set")
pub fn new_set(init: Dynamic) -> Dynamic

/// `new WeakMap(init?)` — optionally seeded from an array of `[key, value]` pairs;
/// a non-object key in the iterable throws a TypeError (§24.3.1.1). Keys are held
/// strongly (no real weak references are modelled).
@external(erlang, "twocore_rt_js_ffi", "new_weakmap")
pub fn new_weakmap(init: Dynamic) -> Dynamic

/// The `WeakMap` constructor as a first-class fun value, so a bare `WeakMap`
/// reference reports `typeof` "function".
@external(erlang, "twocore_rt_js_ffi", "weakmap_ctor")
pub fn weakmap_ctor() -> Dynamic

/// `new WeakSet([iterable])` — a `{js_weakset, …}` cell (§24.4); `add`/`has`/`delete`
/// dispatch through `js_m_add`/`js_m_has`/`js_m_delete` on the WeakSet tag.
@external(erlang, "twocore_rt_js_ffi", "new_weakset")
pub fn new_weakset(init: Dynamic) -> Dynamic

/// The bare `WeakSet` identifier as a function value (so `typeof WeakSet` is
/// "function"); calling it without `new` throws a TypeError.
@external(erlang, "twocore_rt_js_ffi", "weakset_ctor")
pub fn weakset_ctor() -> Dynamic

/// `WeakSet(...)` called without `new` — always throws a TypeError (§24.4.1.1).
@external(erlang, "twocore_rt_js_ffi", "weakset_no_new")
pub fn weakset_no_new() -> Dynamic

// Each takes the receiver + a cons-list of ALL the call's arguments — so a delegated
// user method (plain-object receiver) receives every argument.

/// `map.set(k, v)` (returns the map) / `map.get(k)` / `set.add(v)` (returns the set).
@external(erlang, "twocore_rt_js_ffi", "js_m_set")
pub fn js_m_set(recv: Dynamic, args: Dynamic) -> Dynamic

@external(erlang, "twocore_rt_js_ffi", "js_m_get")
pub fn js_m_get(recv: Dynamic, args: Dynamic) -> Dynamic

@external(erlang, "twocore_rt_js_ffi", "js_m_add")
pub fn js_m_add(recv: Dynamic, args: Dynamic) -> Dynamic

/// `map.has(k)` / `set.has(v)` → JS boolean; `map.delete(k)` / `set.delete(v)` → boolean.
@external(erlang, "twocore_rt_js_ffi", "js_m_has")
pub fn js_m_has(recv: Dynamic, args: Dynamic) -> Dynamic

@external(erlang, "twocore_rt_js_ffi", "js_m_delete")
pub fn js_m_delete(recv: Dynamic, args: Dynamic) -> Dynamic

/// `map.clear()` / `set.clear()`.
@external(erlang, "twocore_rt_js_ffi", "js_m_clear")
pub fn js_m_clear(recv: Dynamic, args: Dynamic) -> Dynamic

/// `map.getOrInsert(key, value)` (TC39 upsert proposal). Returns the existing value
/// for `key` (SameValueZero) if present without overwriting, else inserts and returns
/// `value`.
@external(erlang, "twocore_rt_js_ffi", "js_m_get_or_insert")
pub fn js_m_get_or_insert(recv: Dynamic, args: Dynamic) -> Dynamic

/// `map.getOrInsertComputed(key, callbackfn)` (TC39 upsert proposal). Returns the
/// existing value if `key` is present (callback not called); else calls
/// `callbackfn(canonicalKey)`, stores its return value under `key`, and returns it.
@external(erlang, "twocore_rt_js_ffi", "js_m_get_or_insert_computed")
pub fn js_m_get_or_insert_computed(recv: Dynamic, args: Dynamic) -> Dynamic

/// `forEach(fn)` across arrays, Maps `fn(v, k, m)`, and Sets `fn(v, v, s)`.
@external(erlang, "twocore_rt_js_ffi", "js_m_foreach")
pub fn js_m_foreach(recv: Dynamic, args: Dynamic) -> Dynamic

/// `map.keys()`/`set.keys()`, `.values()`, `.entries()` — a live iterator object whose
/// `.next()` yields `{value, done}` in insertion order (a Set's key == its value).
@external(erlang, "twocore_rt_js_ffi", "js_m_keys")
pub fn js_m_keys(recv: Dynamic, args: Dynamic) -> Dynamic

@external(erlang, "twocore_rt_js_ffi", "js_m_values")
pub fn js_m_values(recv: Dynamic, args: Dynamic) -> Dynamic

@external(erlang, "twocore_rt_js_ffi", "js_m_entries")
pub fn js_m_entries(recv: Dynamic, args: Dynamic) -> Dynamic

// ES2024 Set composition methods. Each takes the receiver Set + a cons-list of the
// call's arguments (the single `other` set-like). union/intersection/difference/
// symmetricDifference return a fresh Set; the is* predicates return a JS boolean.

/// `set.union(other)` — a new Set of every element in either.
@external(erlang, "twocore_rt_js_ffi", "set_union")
pub fn set_union(recv: Dynamic, args: Dynamic) -> Dynamic

/// `set.intersection(other)` — a new Set of the elements in both.
@external(erlang, "twocore_rt_js_ffi", "set_intersection")
pub fn set_intersection(recv: Dynamic, args: Dynamic) -> Dynamic

/// `set.difference(other)` — a new Set of this's elements not in other.
@external(erlang, "twocore_rt_js_ffi", "set_difference")
pub fn set_difference(recv: Dynamic, args: Dynamic) -> Dynamic

/// `set.symmetricDifference(other)` — a new Set of the elements in exactly one.
@external(erlang, "twocore_rt_js_ffi", "set_symmetric_difference")
pub fn set_symmetric_difference(recv: Dynamic, args: Dynamic) -> Dynamic

/// `set.isDisjointFrom(other)` → boolean: no element in common.
@external(erlang, "twocore_rt_js_ffi", "set_is_disjoint_from")
pub fn set_is_disjoint_from(recv: Dynamic, args: Dynamic) -> Dynamic

/// `set.isSubsetOf(other)` → boolean: every element of this is in other.
@external(erlang, "twocore_rt_js_ffi", "set_is_subset_of")
pub fn set_is_subset_of(recv: Dynamic, args: Dynamic) -> Dynamic

/// `set.isSupersetOf(other)` → boolean: every element of other is in this.
@external(erlang, "twocore_rt_js_ffi", "set_is_superset_of")
pub fn set_is_superset_of(recv: Dynamic, args: Dynamic) -> Dynamic

// Array iteration/query methods. Callback-taking ones (`map`/`filter`/`reduce`/…) apply
// the JS callback with its own arity (extra/missing args tolerated).

/// `arr.map(fn)` → a new array of `fn(x, i, arr)`.
@external(erlang, "twocore_rt_js_ffi", "array_map")
pub fn array_map(arr: Dynamic, fn_: Dynamic) -> Dynamic

/// `arr.filter(fn)` → a new array of the elements where `fn(x, i, arr)` is truthy.
@external(erlang, "twocore_rt_js_ffi", "array_filter")
pub fn array_filter(arr: Dynamic, fn_: Dynamic) -> Dynamic

/// `arr.forEach(fn)` — apply `fn(x, i, arr)` to each element; returns `undefined`.
@external(erlang, "twocore_rt_js_ffi", "array_foreach")
pub fn array_foreach(arr: Dynamic, fn_: Dynamic) -> Dynamic

/// `arr.reduce(fn, init)` — left fold with `fn(acc, x, i, arr)`.
@external(erlang, "twocore_rt_js_ffi", "array_reduce")
pub fn array_reduce(arr: Dynamic, fn_: Dynamic, init: Dynamic) -> Dynamic

/// `arr.reduce(fn)` — left fold seeded by the first element (empty → TypeError).
@external(erlang, "twocore_rt_js_ffi", "array_reduce1")
pub fn array_reduce1(arr: Dynamic, fn_: Dynamic) -> Dynamic

/// `arr.reduceRight(fn, init)` — right fold with `fn(acc, x, i, arr)`.
@external(erlang, "twocore_rt_js_ffi", "array_reduce_right")
pub fn array_reduce_right(arr: Dynamic, fn_: Dynamic, init: Dynamic) -> Dynamic

/// `arr.reduceRight(fn)` — right fold seeded by the last element (empty → TypeError).
@external(erlang, "twocore_rt_js_ffi", "array_reduce_right1")
pub fn array_reduce_right1(arr: Dynamic, fn_: Dynamic) -> Dynamic

/// `arr.some(fn)` → JS boolean: any element satisfies `fn`.
@external(erlang, "twocore_rt_js_ffi", "array_some")
pub fn array_some(arr: Dynamic, fn_: Dynamic) -> Dynamic

/// `arr.every(fn)` → JS boolean: all elements satisfy `fn`.
@external(erlang, "twocore_rt_js_ffi", "array_every")
pub fn array_every(arr: Dynamic, fn_: Dynamic) -> Dynamic

/// `arr.find(fn)` → the first element satisfying `fn`, else `undefined`.
@external(erlang, "twocore_rt_js_ffi", "array_find")
pub fn array_find(arr: Dynamic, fn_: Dynamic) -> Dynamic

/// `arr.findIndex(fn)` → the first index satisfying `fn`, else `-1`.
@external(erlang, "twocore_rt_js_ffi", "array_find_index")
pub fn array_find_index(arr: Dynamic, fn_: Dynamic) -> Dynamic

/// `arr.indexOf(x)` → the first strict-equal index, else `-1`.
@external(erlang, "twocore_rt_js_ffi", "array_index_of")
pub fn array_index_of(arr: Dynamic, x: Dynamic, from: Dynamic) -> Dynamic

/// `arr.includes(x)` → JS boolean (strict equality).
@external(erlang, "twocore_rt_js_ffi", "array_includes")
pub fn array_includes(arr: Dynamic, x: Dynamic, from: Dynamic) -> Dynamic

/// `arr.join(sep)` → the elements ToString'd and joined by `sep` (null/undefined → "").
@external(erlang, "twocore_rt_js_ffi", "array_join")
pub fn array_join(arr: Dynamic, sep: Dynamic) -> Dynamic

/// `arr.slice(start, end)` → a shallow sub-array (negative indices count from the end;
/// `undefined` bounds default to `0` / `length`).
@external(erlang, "twocore_rt_js_ffi", "array_slice")
pub fn array_slice(arr: Dynamic, start: Dynamic, end: Dynamic) -> Dynamic

/// `arr.concat(...items)` → a new array; array items are spread, others appended.
@external(erlang, "twocore_rt_js_ffi", "array_concat")
pub fn array_concat(arr: Dynamic, items: Dynamic) -> Dynamic

/// `arr.reverse()` — reverse in place; returns the array.
@external(erlang, "twocore_rt_js_ffi", "array_reverse")
pub fn array_reverse(arr: Dynamic) -> Dynamic

/// `arr.shift()` — remove and return the first element (`undefined` when empty).
@external(erlang, "twocore_rt_js_ffi", "array_shift")
pub fn array_shift(arr: Dynamic) -> Dynamic

/// `arr.unshift(...vals)` — prepend each; returns the new length.
@external(erlang, "twocore_rt_js_ffi", "array_unshift")
pub fn array_unshift(arr: Dynamic, vals: Dynamic) -> Dynamic

/// `arr.sort(cmp)` — in place; default order is by ToString, else by the comparator.
@external(erlang, "twocore_rt_js_ffi", "array_sort")
pub fn array_sort(arr: Dynamic, cmp: Dynamic) -> Dynamic

/// `arr.toReversed()` (ES2023) — a new reversed array; `arr` is not mutated.
@external(erlang, "twocore_rt_js_ffi", "array_to_reversed")
pub fn array_to_reversed(arr: Dynamic) -> Dynamic

/// `arr.toSorted(cmp)` (ES2023) — a new sorted array; `arr` is not mutated. Holes
/// are read through as `undefined` (unlike `sort`, which skips them).
@external(erlang, "twocore_rt_js_ffi", "array_to_sorted")
pub fn array_to_sorted(arr: Dynamic, cmp: Dynamic) -> Dynamic

/// `arr.with(index, value)` (ES2023) — a new array with `index` replaced by
/// `value`; `arr` is not mutated. An out-of-range `index` raises a RangeError.
@external(erlang, "twocore_rt_js_ffi", "array_with")
pub fn array_with(arr: Dynamic, index: Dynamic, value: Dynamic) -> Dynamic

/// `arr.toSpliced(start, deleteCount, ...items)` (ES2023) — a new array with the
/// splice applied; `arr` is not mutated (`args` a cons list of all arguments).
@external(erlang, "twocore_rt_js_ffi", "array_to_spliced")
pub fn array_to_spliced(arr: Dynamic, args: Dynamic) -> Dynamic

// ───────────────────────── strings ─────────────────────────
// Strings are UTF-8 binaries. `.length`, indexing, `charAt`, `slice`, `substring` are
// code-point based (BMP-correct; astral chars count as 1 not 2 — a v1 deviation from
// JS's UTF-16 units). `indexOf`/`includes`/`slice`/`concat` are polymorphic over
// arrays and strings (see those declarations above).

/// `str.charAt(i)` → the 1-char string, or "" out of range.
@external(erlang, "twocore_rt_js_ffi", "str_char_at")
pub fn str_char_at(str: Dynamic, i: Dynamic) -> Dynamic

/// `str.charCodeAt(i)` → the code point as a number, or NaN out of range.
@external(erlang, "twocore_rt_js_ffi", "str_char_code_at")
pub fn str_char_code_at(str: Dynamic, i: Dynamic) -> Dynamic

/// `str.codePointAt(i)` → the code point as a number, or `undefined` out of range.
@external(erlang, "twocore_rt_js_ffi", "str_code_point_at")
pub fn str_code_point_at(str: Dynamic, i: Dynamic) -> Dynamic

/// `str.normalize(form)` — Unicode normalization (NFC default; NFD/NFKC/NFKD).
@external(erlang, "twocore_rt_js_ffi", "str_normalize")
pub fn str_normalize(str: Dynamic, form: Dynamic) -> Dynamic

/// `str.toUpperCase()`.
@external(erlang, "twocore_rt_js_ffi", "str_upper")
pub fn str_upper(str: Dynamic) -> Dynamic

/// `str.toLowerCase()`.
@external(erlang, "twocore_rt_js_ffi", "str_lower")
pub fn str_lower(str: Dynamic) -> Dynamic

/// `str.substring(start?, end?)` — clamps negatives to 0 and swaps if start > end.
@external(erlang, "twocore_rt_js_ffi", "str_substring")
pub fn str_substring(str: Dynamic, start: Dynamic, end: Dynamic) -> Dynamic

/// `str.split(sep?, limit?)` → an array of substrings (no sep → `[str]`; "" →
/// the characters). `limit` is coerced with ToUint32; `0` yields `[]`.
@external(erlang, "twocore_rt_js_ffi", "str_split")
pub fn str_split(str: Dynamic, sep: Dynamic, limit: Dynamic) -> Dynamic

/// `str.trim()` / `trimStart()` / `trimEnd()`.
@external(erlang, "twocore_rt_js_ffi", "str_trim")
pub fn str_trim(str: Dynamic) -> Dynamic

@external(erlang, "twocore_rt_js_ffi", "str_trim_start")
pub fn str_trim_start(str: Dynamic) -> Dynamic

@external(erlang, "twocore_rt_js_ffi", "str_trim_end")
pub fn str_trim_end(str: Dynamic) -> Dynamic

/// `str.repeat(n)` — `n` copies (negative → RangeError/type_error).
@external(erlang, "twocore_rt_js_ffi", "str_repeat")
pub fn str_repeat(str: Dynamic, n: Dynamic) -> Dynamic

/// `str.startsWith(prefix, position)` — true when `prefix` occurs at code-point
/// index `position` (ToIntegerOrInfinity, clamped to `[0, len]`; `undefined` →
/// 0). Returns a JS boolean.
@external(erlang, "twocore_rt_js_ffi", "str_starts_with")
pub fn str_starts_with(
  str: Dynamic,
  prefix: Dynamic,
  position: Dynamic,
) -> Dynamic

/// `str.endsWith(suffix, end_position)` — true when `suffix` ends at code-point
/// index `end_position` (`undefined` → `len`; else ToIntegerOrInfinity clamped
/// to `[0, len]`). Returns a JS boolean.
@external(erlang, "twocore_rt_js_ffi", "str_ends_with")
pub fn str_ends_with(
  str: Dynamic,
  suffix: Dynamic,
  end_position: Dynamic,
) -> Dynamic

/// `str.replace(search, repl)` — the first occurrence (string search, no regex in v1).
@external(erlang, "twocore_rt_js_ffi", "str_replace")
pub fn str_replace(str: Dynamic, search: Dynamic, repl: Dynamic) -> Dynamic

/// `str.replaceAll(search, repl)` — every occurrence.
@external(erlang, "twocore_rt_js_ffi", "str_replace_all")
pub fn str_replace_all(str: Dynamic, search: Dynamic, repl: Dynamic) -> Dynamic

/// `str.isWellFormed()` (§22.1.3.9) — `true`/`false` JS boolean: whether the string
/// contains no unpaired UTF-16 surrogate.
@external(erlang, "twocore_rt_js_ffi", "str_is_well_formed")
pub fn str_is_well_formed(str: Dynamic) -> Dynamic

/// `str.toWellFormed()` (§22.1.3.35) — a copy with every unpaired surrogate replaced
/// by U+FFFD.
@external(erlang, "twocore_rt_js_ffi", "str_to_well_formed")
pub fn str_to_well_formed(str: Dynamic) -> Dynamic

/// `str.localeCompare(that)` (§22.1.3.10) — default-locale (code-point lexicographic)
/// ordering: the JS number -1/0/1 for before/equal/after.
@external(erlang, "twocore_rt_js_ffi", "str_locale_compare")
pub fn str_locale_compare(str: Dynamic, that: Dynamic) -> Dynamic

/// `String.prototype.<method>` referenced as a value — the underlying builtin as a
/// function value (so `typeof String.prototype.at` is "function").
@external(erlang, "twocore_rt_js_ffi", "str_proto_fn")
pub fn str_proto_fn(name: Dynamic) -> Dynamic

// ───────────────────────── globals / statics ─────────────────────────

/// `parseInt(str, radix)` — leading integer (auto-detects `0x`; default radix 10).
@external(erlang, "twocore_rt_js_ffi", "parse_int")
pub fn parse_int(str: Dynamic, radix: Dynamic) -> Dynamic

/// `parseFloat(str)` — leading decimal/float (or Infinity), else NaN.
@external(erlang, "twocore_rt_js_ffi", "parse_float")
pub fn parse_float(str: Dynamic) -> Dynamic

/// `isNaN(x)` — ToNumber(x) is NaN (the coercing global form).
@external(erlang, "twocore_rt_js_ffi", "is_nan")
pub fn is_nan(x: Dynamic) -> Dynamic

/// `isFinite(x)` — ToNumber(x) is finite (the coercing global form).
@external(erlang, "twocore_rt_js_ffi", "is_finite")
pub fn is_finite(x: Dynamic) -> Dynamic

/// `encodeURIComponent(x)` — percent-encode ToString(x), keeping only the
/// uriUnescaped set (`A-Za-z0-9 - _ . ! ~ * ' ( )`) literal. Malformed UTF-8 in
/// the source string raises a URIError (`{js_error, uri_error, _}`).
@external(erlang, "twocore_rt_js_ffi", "encode_uri_component")
pub fn encode_uri_component(x: Dynamic) -> Dynamic

/// `encodeURI(x)` — like `encode_uri_component` but ALSO keeps the uriReserved
/// set and `#` (`; / ? : @ & = + $ , #`) literal.
@external(erlang, "twocore_rt_js_ffi", "encode_uri")
pub fn encode_uri(x: Dynamic) -> Dynamic

/// `decodeURIComponent(x)` — decode every `%XX` escape of ToString(x) into UTF-8
/// bytes (empty reserved set). A malformed escape or invalid UTF-8 run raises a
/// URIError.
@external(erlang, "twocore_rt_js_ffi", "decode_uri_component")
pub fn decode_uri_component(x: Dynamic) -> Dynamic

/// `decodeURI(x)` — decode `%XX` escapes of ToString(x), but leave a decoded
/// reserved character (`; / ? : @ & = + $ , #`) as its original escape verbatim.
@external(erlang, "twocore_rt_js_ffi", "decode_uri")
pub fn decode_uri(x: Dynamic) -> Dynamic

/// `escape(x)` — the legacy Annex B (B.2.1.1) escaper. Percent-escapes ToString(x)
/// code-unit by code-unit: a code unit ≥ 256 → `%uWXYZ`, a code unit < 256 not in
/// the unescaped set (`A-Za-z0-9@*_+-./`) → `%XY`, all uppercase hex. Never raises.
@external(erlang, "twocore_rt_js_ffi", "global_escape")
pub fn global_escape(x: Dynamic) -> Dynamic

/// `unescape(x)` — the legacy Annex B (B.2.1.2) inverse of `escape`. Replaces each
/// `%uXXXX` and `%XX` escape in ToString(x) with the corresponding code unit; a `%`
/// not followed by a well-formed escape is left verbatim. Never raises.
@external(erlang, "twocore_rt_js_ffi", "global_unescape")
pub fn global_unescape(x: Dynamic) -> Dynamic

/// `x` is `null` or `undefined` → i32 `1`/`0` (behind `??` and optional chaining `?.`).
@external(erlang, "twocore_rt_js_ffi", "is_nullish")
pub fn is_nullish(x: Dynamic) -> Int

/// `Number.isNaN(x)` — x IS the NaN number (no coercion).
@external(erlang, "twocore_rt_js_ffi", "number_is_nan")
pub fn number_is_nan(x: Dynamic) -> Dynamic

/// `Number.isFinite(x)` — x is a finite number (no coercion).
@external(erlang, "twocore_rt_js_ffi", "number_is_finite")
pub fn number_is_finite(x: Dynamic) -> Dynamic

/// `Number.isInteger(x)` — x is an integer-valued number (no coercion).
@external(erlang, "twocore_rt_js_ffi", "number_is_integer")
pub fn number_is_integer(x: Dynamic) -> Dynamic

/// `Number.isSafeInteger(x)` — x is an integer-valued number within the
/// safe-integer range |x| ≤ 2^53 − 1 (no coercion).
@external(erlang, "twocore_rt_js_ffi", "number_is_safe_integer")
pub fn number_is_safe_integer(x: Dynamic) -> Dynamic

/// `Object.keys(o)` → array of own string keys (map-iteration order; a v1 deviation).
@external(erlang, "twocore_rt_js_ffi", "object_keys")
pub fn object_keys(o: Dynamic) -> Dynamic

/// `Object.values(o)` → array of own values.
@external(erlang, "twocore_rt_js_ffi", "object_values")
pub fn object_values(o: Dynamic) -> Dynamic

/// `Object.entries(o)` → array of `[key, value]` pairs.
@external(erlang, "twocore_rt_js_ffi", "object_entries")
pub fn object_entries(o: Dynamic) -> Dynamic

/// Copy `source`'s own properties into `target` in place; behind object spread
/// `{...o}` (and would back `Object.assign`).
@external(erlang, "twocore_rt_js_ffi", "object_assign_into")
pub fn object_assign_into(target: Dynamic, source: Dynamic) -> Dynamic

/// A new object with `obj`'s own properties except those named in `excluded` (a
/// key-string array) — object-rest destructuring `{ a, ...rest }`.
@external(erlang, "twocore_rt_js_ffi", "object_rest")
pub fn object_rest(obj: Dynamic, excluded: Dynamic) -> Dynamic

/// `Object.freeze(o)` — mark `o` immutable (own-property writes/deletes become
/// non-strict no-ops) and return it; a non-object primitive is returned unchanged.
@external(erlang, "twocore_rt_js_ffi", "object_freeze")
pub fn object_freeze(obj: Dynamic) -> Dynamic

/// `Object.isFrozen(o)` → JS boolean (`true`/`false`); a non-object primitive is
/// frozen (`true`).
@external(erlang, "twocore_rt_js_ffi", "object_is_frozen")
pub fn object_is_frozen(obj: Dynamic) -> Dynamic

/// `Object.preventExtensions(o)` — mark `o` non-extensible (no new own property
/// may be added; existing ones stay writable/deletable) and return it; a
/// non-object primitive is returned unchanged.
@external(erlang, "twocore_rt_js_ffi", "object_prevent_extensions")
pub fn object_prevent_extensions(obj: Dynamic) -> Dynamic

/// `Object.isExtensible(o)` → JS boolean; `false` for any non-object primitive
/// (per ES2015 it does not throw).
@external(erlang, "twocore_rt_js_ffi", "object_is_extensible")
pub fn object_is_extensible(obj: Dynamic) -> Dynamic

/// `Object.seal(o)` — make `o` non-extensible and its existing own properties
/// non-configurable (they can no longer be deleted), then return it; a non-object
/// primitive is returned unchanged.
@external(erlang, "twocore_rt_js_ffi", "object_seal")
pub fn object_seal(obj: Dynamic) -> Dynamic

/// `Object.isSealed(o)` → JS boolean; `true` for any non-object primitive.
@external(erlang, "twocore_rt_js_ffi", "object_is_sealed")
pub fn object_is_sealed(obj: Dynamic) -> Dynamic

/// `Object.fromEntries(pairs)` — build an object from an array of `[key, value]` arrays.
@external(erlang, "twocore_rt_js_ffi", "object_from_entries")
pub fn object_from_entries(entries: Dynamic) -> Dynamic

/// `Object.is(x, y)` → JS boolean, the SameValue algorithm: like `===` except
/// `NaN` is same-value with `NaN` and `+0` is distinguished from `-0`.
@external(erlang, "twocore_rt_js_ffi", "object_is")
pub fn object_is(x: Dynamic, y: Dynamic) -> Dynamic

/// `obj.hasOwnProperty(key)` → JS boolean: whether the receiver owns a property
/// named `ToString(key)` (own properties only; null/undefined receivers throw).
@external(erlang, "twocore_rt_js_ffi", "object_has_own")
pub fn object_has_own(obj: Dynamic, key: Dynamic) -> Dynamic

/// `Reflect.has(target, key)` → JS boolean; whether `target` (which must be an
/// object, else TypeError) has the property `key` (own-property only in v1).
@external(erlang, "twocore_rt_js_ffi", "reflect_has")
pub fn reflect_has(target: Dynamic, key: Dynamic) -> Dynamic

/// `Reflect.get(target, key)` → the value of `target[key]` (or `undefined`);
/// `target` must be an object, else TypeError. The optional `receiver` is ignored.
@external(erlang, "twocore_rt_js_ffi", "reflect_get")
pub fn reflect_get(target: Dynamic, key: Dynamic) -> Dynamic

/// `Reflect.set(target, key, value)` → JS boolean success; `target` must be an
/// object, else TypeError. A frozen target reports `false`. `receiver` is ignored.
@external(erlang, "twocore_rt_js_ffi", "reflect_set")
pub fn reflect_set(target: Dynamic, key: Dynamic, value: Dynamic) -> Dynamic

/// `Reflect.deleteProperty(target, key)` → JS boolean success; `target` must be an
/// object, else TypeError. A frozen/sealed non-configurable property reports `false`.
@external(erlang, "twocore_rt_js_ffi", "reflect_delete_property")
pub fn reflect_delete_property(target: Dynamic, key: Dynamic) -> Dynamic

/// `Reflect.ownKeys(target)` → an array of `target`'s own property keys; `target`
/// must be an object, else TypeError.
@external(erlang, "twocore_rt_js_ffi", "reflect_own_keys")
pub fn reflect_own_keys(target: Dynamic) -> Dynamic

/// `Reflect.getPrototypeOf(target)` → the prototype, or `null` (this v1 model has
/// no prototype chain, so an ordinary object reports `null`); `target` must be an
/// object, else TypeError.
@external(erlang, "twocore_rt_js_ffi", "reflect_get_prototype_of")
pub fn reflect_get_prototype_of(target: Dynamic) -> Dynamic

/// `Reflect.isExtensible(target)` → JS boolean; `target` must be an object, else
/// TypeError (unlike `Object.isExtensible`, which does not throw on a primitive).
@external(erlang, "twocore_rt_js_ffi", "reflect_is_extensible")
pub fn reflect_is_extensible(target: Dynamic) -> Dynamic

/// `Reflect.preventExtensions(target)` → JS boolean success (`true`); `target` must
/// be an object, else TypeError.
@external(erlang, "twocore_rt_js_ffi", "reflect_prevent_extensions")
pub fn reflect_prevent_extensions(target: Dynamic) -> Dynamic

/// `Reflect.apply(target, thisArgument, argumentsList)` → the call result; `target`
/// must be callable, else TypeError. `argumentsList` is spread as the arguments.
@external(erlang, "twocore_rt_js_ffi", "reflect_apply")
pub fn reflect_apply(
  target: Dynamic,
  this_argument: Dynamic,
  arguments_list: Dynamic,
) -> Dynamic

/// `JSON.stringify(value, replacer, space)` → a JSON string, or `undefined` when
/// the root value serializes to nothing. `replacer` is a filter/transform (an
/// Array PropertyList or a callable), `space` the indentation gap; pass
/// `undefined` for either to omit it.
@external(erlang, "twocore_rt_js_ffi", "json_stringify")
pub fn json_stringify(
  value: Dynamic,
  replacer: Dynamic,
  space: Dynamic,
) -> Dynamic

/// `JSON.parse(s)` → the parsed value (malformed input is a type error).
@external(erlang, "twocore_rt_js_ffi", "json_parse")
pub fn json_parse(s: Dynamic) -> Dynamic

// ───────────────────────── lists / console / misc ─────────────────────────

/// The empty BEAM list `[]` (arity 0) — the nil tail an args-cons-list build starts from.
/// Exists because the IR has no `[]` literal (`ConstNil` would be the upstream fix).
@external(erlang, "twocore_rt_js_ffi", "empty_list")
pub fn empty_list() -> Dynamic

/// `console.log(...args)` — takes ONE term, the cons list of the arguments. Prints them
/// space-separated on one line to stdout (strings bare, everything else via the `to_string`
/// rules) and returns `undefined`. A non-list argument is a `type_error`.
@external(erlang, "twocore_rt_js_ffi", "console_log")
pub fn console_log(args: Dynamic) -> Dynamic

/// The emitter's guard for `callee(...)` where the callee failed `is_fun`: ALWAYS raises
/// `{js_error, type_error, <the value>}`. (Typed as returning `Dynamic` so a `Let` can bind
/// it; it never returns.)
@external(erlang, "twocore_rt_js_ffi", "not_callable")
pub fn not_callable(v: Dynamic) -> Dynamic

// ───────────────────────── Symbol ─────────────────────────

/// `Symbol(description)` — a fresh unique Symbol value (`{js_symbol, Id, Desc}`).
/// `desc` is the raw description argument, or the `undefined` atom when none was
/// given (an `undefined` description means the Symbol has no description; any other
/// value is coerced with ToString). `typeof` of the result is "symbol", and two
/// `Symbol()` results are never `===` even with equal descriptions.
@external(erlang, "twocore_rt_js_ffi", "symbol_make")
pub fn symbol_make(desc: Dynamic) -> Dynamic

/// The bare `Symbol` identifier as a first-class fun VALUE — so `typeof Symbol` is
/// "function". Applied, it constructs a Symbol from its single description argument.
@external(erlang, "twocore_rt_js_ffi", "symbol_ctor")
pub fn symbol_ctor() -> Dynamic

/// `new Symbol()` — the Symbol constructor is not new-able (§20.4.1.1 step 1); ALWAYS
/// raises a TypeError. (Typed as returning `Dynamic`; it never returns.)
@external(erlang, "twocore_rt_js_ffi", "symbol_no_new")
pub fn symbol_no_new() -> Dynamic

/// A well-known Symbol (§20.4.2.x): a single fixed unique value per `name` (the atom
/// `iterator`/`asyncIterator`/`hasInstance`/…). Its description is `"Symbol.<name>"`.
@external(erlang, "twocore_rt_js_ffi", "symbol_wellknown")
pub fn symbol_wellknown(name: Dynamic) -> Dynamic

/// `Symbol.for(key)` — the GlobalSymbolRegistry lookup: returns the same Symbol for
/// equal (ToString'd) keys, creating and registering one on first use.
@external(erlang, "twocore_rt_js_ffi", "symbol_for")
pub fn symbol_for(key: Dynamic) -> Dynamic

/// `Symbol.keyFor(sym)` — the registry key `sym` was registered under (via
/// `Symbol.for`), or `undefined` if it is not a registered Symbol. A non-Symbol
/// argument is a TypeError.
@external(erlang, "twocore_rt_js_ffi", "symbol_key_for")
pub fn symbol_key_for(sym: Dynamic) -> Dynamic
