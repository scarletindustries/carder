//// `rt_js` — the JS runtime boundary **STUB** (Phase-8 unit 05, K6).
////
//// > **STUB.** The *real* `rt_js` — every JS semantic (property get with prototypes,
//// > `ToPrimitive`/`ToNumber` coercion, `+` with `ToPrimitive`, `typeof`, builtins, mutable
//// > cells, the `undefined`/`null` sentinels) — is the **frontend team's** deliverable. See
//// > `specs/phase-8/HANDOFF-arc-frontend.md §4` for the full ABI they must provide. This module
//// > ships only a handful of real ops so the *boundary* is testable now and the calling
//// > convention is demonstrated end-to-end (IR → `emit_core` → `build_beam` → BEAM). Its number
//// > semantics are deliberately NOT JS-correct; it exists to prove the boundary routes and
//// > returns a value, not to be a JS runtime.
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
//// ## The boxed-value ABI (K2/K5, unit 04)
////
//// A JS value is a **BEAM term** (`TTerm` to the IR — opaque; `rt_js` picks the concrete
//// encodings). 2core carries scalars as raw bit patterns and `BoxInt`/`BoxFloat` are identity
//// retags (unit 04), so a "boxed 2" is just the BEAM integer `2`. The ops below therefore take
//// and return ordinary BEAM terms directly, one result per call (K6 — a multi-result op would
//// tuple-pack; none here does). Args arrive as the direct call arguments (`add(A, B)`), not a
//// wrapped list — this is `rt_js`'s own ABI, distinct from `rt_host`'s `List(Int)` shape.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}

/// `rt_js` `"add"` — the STUB numeric `+` (Phase-8 unit 05). Adds two boxed integer terms with
/// the BEAM `+` (`erlang:'+'/2`). Because `BoxInt` is identity (unit 04), a boxed `2` is the
/// integer `2`, so `add(2, 3) == 5` — enough to prove the boundary routes and returns a value.
///
/// - `a`, `b`: two boxed integer terms (the raw i32/i64 bit pattern = the BEAM integer, unit 04).
/// - Returns: their integer sum, a single boxed value (K6). Total for integer inputs.
///
/// **STUB — NOT JS `+`.** The real `rt_js.add` implements ECMAScript `+`: string-or-number with
/// `ToPrimitive`/`ToNumber`, NaN/±Infinity sentinels, `-0`, bignum, etc. (HANDOFF §4). This stub
/// handles only the boxed-integer fast case (numeric add on boxed terms).
pub fn add(a: Int, b: Int) -> Int {
  a + b
}

/// `rt_js` `"type_of"` — a `typeof`-style STUB classifier (Phase-8 unit 05). Inspects a boxed
/// term's BEAM runtime shape and returns a **binary** (a JS-string-like term) naming a coarse
/// kind, so the boundary returns a real, inspectable value.
///
/// - `x`: any boxed term.
/// - Returns: a UTF-8 `BitArray` — `<<"number">>` (a BEAM integer or float), `<<"boolean">>`
///   (the atoms `true`/`false`), `<<"string">>` (a binary), `<<"undefined">>` (the
///   `undefined_sentinel/0` atom), else `<<"object">>`. Total; never panics.
///
/// **STUB — NOT ECMAScript `typeof`.** The real `rt_js.type_of` follows §12.5.5 exactly (its own
/// sentinels for `undefined`/`function`/`symbol`/`bigint`, `null → "object"`, etc., HANDOFF §4).
/// This stub only demonstrates a boxed term crossing the boundary and returning a binary.
pub fn type_of(x: Dynamic) -> BitArray {
  bit_array.from_string(classify(x))
}

/// The coarse BEAM-shape classifier behind `type_of` (STUB). Probes in a fixed order so the kinds
/// are disjoint (BEAM integers/floats/booleans/binaries/atoms are distinct term shapes). The
/// `undefined` sentinel (an atom) is checked before the catch-all `"object"`.
fn classify(x: Dynamic) -> String {
  case decode.run(x, decode.int) {
    Ok(_) -> "number"
    Error(_) ->
      case decode.run(x, decode.float) {
        Ok(_) -> "number"
        Error(_) ->
          case decode.run(x, decode.bool) {
            Ok(_) -> "boolean"
            Error(_) ->
              case decode.run(x, decode.string) {
                Ok(_) -> "string"
                Error(_) ->
                  case is_undefined(x) {
                    True -> "undefined"
                    False -> "object"
                  }
              }
          }
      }
  }
}

/// `True` iff `x` is exactly the `undefined_sentinel/0` term (the atom `undefined`). Used by
/// `classify` so `type_of(undefined_sentinel()) == <<"undefined">>`. Total; never panics.
fn is_undefined(x: Dynamic) -> Bool {
  case decode.run(x, atom.decoder()) {
    Ok(a) -> a == atom.create("undefined")
    Error(_) -> False
  }
}

/// `rt_js` `"undefined_sentinel"` — the STUB `undefined` value (Phase-8 unit 05). Returns the
/// BEAM atom `undefined`, a single boxed sentinel term (K6). A JS frontend uses its own sentinel
/// — an atom is a natural, cheap choice (HANDOFF §4: "your sentinels, e.g. atoms
/// `'undefined'`/`'null'`"), and `type_of` recognises it via `is_undefined`.
///
/// - Returns: the `undefined` sentinel term (arity 0). Total.
///
/// **STUB.** The real `rt_js` fixes the concrete sentinel encoding and threads it through every
/// op (coercion, `typeof`, comparisons, …); this stub only proves the 0-arg boundary call routes
/// and returns the sentinel.
pub fn undefined_sentinel() -> Atom {
  atom.create("undefined")
}
