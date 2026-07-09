//// `rt_teavm` — the TeaVM WASM GC host-runtime boundary (experimental).
////
//// TeaVM's WebAssembly-GC backend compiles Java to a `.wasm` that imports a small, stable set of
//// host functions from five namespaces — `teavmJso` (a generic Java↔JS object bridge),
//// `wasm:js-string` (the standard W3C JS String Builtins), `teavmMemory`/`teavmDate`/`teavm`
//// (heap, time, stack-trace hooks) — plus an imported linear `memory` and two `teavmMemory`
//// globals. In a browser those come from the generated `<module>.wasm-runtime.js`; on the BEAM
//// they come from HERE. This module is the direct sibling of `rt_js` (the Porffor JS runtime).
////
//// ## The reference ABI (why this is NOT the `rt_host`/`call_host` path)
////
//// TeaVM's imports are REFERENCE-typed (`externref`/`funcref`/GC refs = BEAM terms), but
//// `rt_host.call_host`/`HostHandler` is a NUMERIC ABI (`List(Int) -> List(Int)`), which cannot
//// carry a term. So `link.resolve_func_provided` special-cases the TeaVM namespaces to a
//// TERM-native `ProvidedFunc(ty, dispatch(cap, name))` — the same `fn(List(Dynamic)) ->
//// List(Dynamic)` closure ABI the cross-module register-seam uses. `dispatch/2` is a build-fixed
//// literal `case` (D3a): the target closure is written HERE, selected by the static
//// capability/name strings, never `apply/3` on program data.
////
//// ## Scope (v0 — enough to instantiate + run a pure-compute Java method)
////
//// The `(start)` bootstrap calls only four `teavmJso` functions (`createClass`/`createFunction1`/
//// `defineFunction`/`defineStaticMethod`) to wire the module's export table; `compute()`-style
//// methods allocate GC objects and dispatch via `call_ref` without touching any import. So every
//// handler here is a TYPE-CORRECT stub — an `externref`/`(ref extern)` result is a real non-null
//// externref (`{ref_extern, 0}`), a GC-ref result is the shared null sentinel, a numeric result is
//// `0`, a `()`-typed result is the empty list. `stringBuiltinsSupported → 0` steers TeaVM onto its
//// WASM-internal string path so the `wasm:js-string` handlers stay unreached. Real behaviour (JS
//// interop, host strings over binaries) is a follow-up; these stubs make the bootstrap survive.

import gleam/dynamic.{type Dynamic}
import twocore/runtime/rt_ref

/// Coerce a Gleam `Int` to `Dynamic` (identity at runtime) — a numeric result value (`i32`/`i64`
/// as its raw bit pattern, `f32`/`f64` as `0`-bits = `0.0`).
@external(erlang, "gleam_stdlib", "identity")
fn int_dyn(n: Int) -> Dynamic

/// A non-null externref stand-in for a JS handle the BEAM host does not model — `{ref_extern, 0}`
/// (via `rt_ref`, so it is a genuine, forge-proof externref term). Satisfies both `externref` and
/// the non-nullable `(ref extern)` result types.
fn ext0() -> Dynamic {
  rt_ref.extern_of(0)
}

/// The shared null sentinel `{ref_null}` — used for a GC object-reference (`(ref null $t)`) result
/// a stub does not produce.
fn null0() -> Dynamic {
  rt_ref.null_ref()
}

/// Resolve one TeaVM host import `#(capability, name)` to its BEAM handler — a TERM-native closure
/// `fn(List(Dynamic)) -> List(Dynamic)` (the `link.ProvidedFunc` ABI). Build-fixed literal `case`
/// (D3a): the returned closure is written here, never constructed from `capability`/`name`/`args`.
///
/// Every arm's RESULT arity + shape matches the import's declared `FuncType`: `externref`/`(ref
/// extern)` → `[ext0()]`; a GC object ref → `[null0()]`; `i32`/`f64` → `[int_dyn(0)]`; `()` → `[]`.
/// An unrecognised pair returns the empty result (a `()`-typed import 2core does not model), never a
/// crash. The `args` are ignored by every stub (the compute path never reads a stub's effect).
pub fn dispatch(
  capability: String,
  name: String,
) -> fn(List(Dynamic)) -> List(Dynamic) {
  case capability, name {
    // ── teavmJso — the generic Java↔JS object bridge. The FOUR the `(start)` bootstrap calls
    //    to build the module's JS-facing export table (each returns a JS handle we stub):
    "teavmJso", "createClass" -> fn(_args) { [ext0()] }
    "teavmJso", "createFunction1" -> fn(_args) { [ext0()] }
    "teavmJso", "defineFunction" -> fn(_args) { [ext0()] }
    "teavmJso", "defineStaticMethod" -> fn(_args) { [] }
    // ── teavmJso — the rest (unreached on the pure-compute path; type-correct stubs):
    "teavmJso", "getProperty" -> fn(_args) { [ext0()] }
    "teavmJso", "callFunction1" -> fn(_args) { [ext0()] }
    "teavmJso", "wrapInt" -> fn(_args) { [ext0()] }
    "teavmJso", "unwrapInt" -> fn(_args) { [int_dyn(0)] }
    "teavmJso", "wrapObject" -> fn(_args) { [null0()] }
    "teavmJso", "unwrapJavaObject" -> fn(_args) { [null0()] }
    "teavmJso", "javaObjectToJS" -> fn(_args) { [ext0()] }
    "teavmJso", "isUndefined" -> fn(_args) { [int_dyn(0)] }
    // Steer TeaVM off the host js-string path (0 = builtins unsupported) so the string handlers
    // below stay unreached; a pure-compute method needs no string ops.
    "teavmJso", "stringBuiltinsSupported" -> fn(_args) { [int_dyn(0)] }
    // ── wasm:js-string — the standard W3C JS String Builtins (unreached while builtins→0):
    "wasm:js-string", "fromCharCode" -> fn(_args) { [ext0()] }
    "wasm:js-string", "fromCharCodeArray" -> fn(_args) { [ext0()] }
    "wasm:js-string", "substring" -> fn(_args) { [ext0()] }
    "wasm:js-string", "concat" -> fn(_args) { [ext0()] }
    "wasm:js-string", "length" -> fn(_args) { [int_dyn(0)] }
    "wasm:js-string", "charCodeAt" -> fn(_args) { [int_dyn(0)] }
    "wasm:js-string", "intoCharCodeArray" -> fn(_args) { [int_dyn(0)] }
    // ── teavmMemory / teavmDate / teavm — heap, time, stack-trace hooks:
    "teavmMemory", "notifyHeapResized" -> fn(_args) { [] }
    "teavmDate", "currentTimeMillis" -> fn(_args) { [int_dyn(0)] }
    "teavm", "takeStackTrace" -> fn(_args) { [ext0()] }
    "teavm", "decorateException" -> fn(_args) { [] }
    // Any TeaVM host import 2core does not (yet) model: a `()`-result no-op, fail-soft.
    _, _ -> fn(_args) { [] }
  }
}

/// Whether `capability` is a TeaVM host namespace `rt_teavm` provides — the gate `link` uses to
/// route a function import here (term-native) instead of the numeric `call_host` path. The five
/// namespaces of the TeaVM WASM GC runtime.
pub fn is_teavm_capability(capability: String) -> Bool {
  case capability {
    "teavmJso" | "wasm:js-string" | "teavmMemory" | "teavmDate" | "teavm" ->
      True
    _ -> False
  }
}
