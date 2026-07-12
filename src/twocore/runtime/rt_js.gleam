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
pub fn array_last_index_of(arr: Dynamic, x: Dynamic) -> Dynamic

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

/// `re.test(str)` → JS boolean.
@external(erlang, "twocore_rt_js_ffi", "regex_test")
pub fn regex_test(re: Dynamic, str: Dynamic) -> Dynamic

/// `re.source` / `re.flags`.
@external(erlang, "twocore_rt_js_ffi", "regex_source")
pub fn regex_source(re: Dynamic) -> Dynamic

@external(erlang, "twocore_rt_js_ffi", "regex_flags")
pub fn regex_flags(re: Dynamic) -> Dynamic

/// `str.match(re)` → array of matches (global) or `[full, groups…]`, else null.
@external(erlang, "twocore_rt_js_ffi", "str_match")
pub fn str_match(str: Dynamic, re: Dynamic) -> Dynamic

// ───────────────────────── Map / Set ─────────────────────────
// `new Map()`/`new Set()`; the methods delegate to a same-named user method when the
// receiver is a plain object, so they don't shadow user APIs. `.size` reads via get_prop.

/// `new Map(init?)` / `new Set(init?)` — optionally seeded from an array (of pairs).
@external(erlang, "twocore_rt_js_ffi", "new_map")
pub fn new_map(init: Dynamic) -> Dynamic

@external(erlang, "twocore_rt_js_ffi", "new_set")
pub fn new_set(init: Dynamic) -> Dynamic

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

/// `forEach(fn)` across arrays, Maps `fn(v, k, m)`, and Sets `fn(v, v, s)`.
@external(erlang, "twocore_rt_js_ffi", "js_m_foreach")
pub fn js_m_foreach(recv: Dynamic, args: Dynamic) -> Dynamic

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
pub fn array_index_of(arr: Dynamic, x: Dynamic) -> Dynamic

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

/// `str.split(sep?)` → an array of substrings (no arg → `[str]`; "" → the characters).
@external(erlang, "twocore_rt_js_ffi", "str_split")
pub fn str_split(str: Dynamic, sep: Dynamic) -> Dynamic

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

/// `str.startsWith(prefix)` / `endsWith(suffix)` → JS boolean.
@external(erlang, "twocore_rt_js_ffi", "str_starts_with")
pub fn str_starts_with(str: Dynamic, prefix: Dynamic) -> Dynamic

@external(erlang, "twocore_rt_js_ffi", "str_ends_with")
pub fn str_ends_with(str: Dynamic, suffix: Dynamic) -> Dynamic

/// `str.replace(search, repl)` — the first occurrence (string search, no regex in v1).
@external(erlang, "twocore_rt_js_ffi", "str_replace")
pub fn str_replace(str: Dynamic, search: Dynamic, repl: Dynamic) -> Dynamic

/// `str.replaceAll(search, repl)` — every occurrence.
@external(erlang, "twocore_rt_js_ffi", "str_replace_all")
pub fn str_replace_all(str: Dynamic, search: Dynamic, repl: Dynamic) -> Dynamic

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

/// `Object.fromEntries(pairs)` — build an object from an array of `[key, value]` arrays.
@external(erlang, "twocore_rt_js_ffi", "object_from_entries")
pub fn object_from_entries(entries: Dynamic) -> Dynamic

/// `JSON.stringify(v)` → a JSON string (undefined/function → `undefined`).
@external(erlang, "twocore_rt_js_ffi", "json_stringify")
pub fn json_stringify(v: Dynamic) -> Dynamic

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
