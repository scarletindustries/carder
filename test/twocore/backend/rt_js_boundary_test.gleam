//// Phase-8 unit 05 — the `rt_js` runtime boundary (the JS capability chokepoint), end-to-end
//// on the BEAM.
////
//// Spec-first (CLAUDE.md D8 / `specs/phase-8/05-js-runtime-boundary.md`, overview K6 + D3a):
//// each behavioral test authors a small IR `Module` that reaches the JS runtime via
//// `CallHost("js", op, args)` — the ONLY way JS semantics are invoked (they are NOT IR nodes,
//// K1) — lowers it IR → `emit_core` → `build_beam` → a loaded `.beam`, invokes an export with
//// `erlang:apply`, and asserts the **value** the `rt_js` STUB returns, never the emitted bytes.
//// The value coming back (e.g. `5` for `add(2,3)`) is itself the proof the boundary really
//// routed to `rt_js` and returned a result.
////
//// The security half asserts the D3a invariant directly: the dispatch is a build-fixed literal
//// `case` (`emit_core.resolve_js`), so an unrecognised `op` — including one that NAMES a real
//// BEAM MFA — resolves to NO function and FAILS CLOSED (`emit_core.UnknownJsOp`), never a panic,
//// never `apply(Mod,Fn,Args)` from data. The complementary "every emitted `call` targets a fixed
//// runtime module atom + literal function" AST walk lives in `emit_core_security_test.gleam`.
////
//// The harness (`load`/`module`/`fnN`/`catch_apply_dyn`/`to_dynamic`) mirrors `boxing_test.gleam`.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import gleam/string
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/ir
import twocore/middle/ir_lower
import twocore/runtime/instance

// Test-only FFI: apply `M:F(Args)` capturing a raise as `Error(text)` (reused from the unit-08
// shim). Re-typed for `Dynamic` args/results — sound because `erlang:apply` is untyped at run time.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply_dyn(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

// Coerce any Gleam value to `Dynamic` (identity at runtime) — to build `Dynamic` arg lists and
// expected-value comparisons.
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

// ───────────────────────────── plumbing ─────────────────────────────

/// Emit `module` to Core text under the Safe default binding (whose `js_runtime_module` is the
/// `rt_js` stub), compile it, and load it into the test VM; return the loaded module atom.
/// `let assert` is the success contract — a failure to emit/compile/load is a genuine failure.
fn load(module: ir.Module) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(module, instance.safe_default())
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

/// Wrap `functions` in a numerics-on, memory-off module exporting each by name.
fn module(name: String, functions: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "twocore@rtjs@" <> name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: functions,
    exports: list.map(functions, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// A zero-parameter function `name() -> rty` with body `body`.
fn fn0(name: String, rty: ir.ValType, body: ir.Expr) -> ir.Function {
  ir.Function(name: name, params: [], result: [rty], locals: [], body: body)
}

/// A one-parameter function `name(p0 : pty) -> rty` with body `body`.
fn fn1(
  name: String,
  pty: ir.ValType,
  rty: ir.ValType,
  body: ir.Expr,
) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("p0", pty)],
    result: [rty],
    locals: [],
    body: body,
  )
}

/// A two-parameter function `name(p0 : p0ty, p1 : p1ty) -> rty` with body `body`.
fn fn2(
  name: String,
  p0ty: ir.ValType,
  p1ty: ir.ValType,
  rty: ir.ValType,
  body: ir.Expr,
) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("p0", p0ty), ir.Local("p1", p1ty)],
    result: [rty],
    locals: [],
    body: body,
  )
}

// ───────────────────────────── behavioral: the boundary routes + returns a value ─────────────────────────────

/// `CallHost("js", "add", [a, b])` routes through the boundary to the `rt_js` stub's `add/2` and
/// returns the sum. Because `BoxInt` is identity (unit 04), a boxed `2` is the BEAM integer `2`,
/// so the stub's BEAM-`+` returns `5` — the returned value proves the boundary really reached
/// `rt_js:add`, not merely that emit succeeded. Several pairs assert it is genuine addition.
pub fn js_add_routes_through_stub_test() {
  let f =
    fn2(
      "js_add",
      ir.TI32,
      ir.TI32,
      ir.TTerm,
      ir.CallHost("js", "add", [ir.Var("p0"), ir.Var("p1")]),
    )
  let mod = load(module("add", [f]))
  let add = atom.create("js_add")
  assert catch_apply_dyn(mod, add, [to_dynamic(2), to_dynamic(3)])
    == Ok(to_dynamic(5))
  assert catch_apply_dyn(mod, add, [to_dynamic(40), to_dynamic(2)])
    == Ok(to_dynamic(42))
  assert catch_apply_dyn(mod, add, [to_dynamic(-4), to_dynamic(4)])
    == Ok(to_dynamic(0))
}

/// `CallHost("js", "type_of", [x])` routes to the stub's `type_of/1` and returns its classifier
/// binary. The stub is a coarse `typeof`-style classifier (NOT ECMAScript `typeof` — it is a
/// stub), so it returns `<<"number">>` for a BEAM integer, `<<"string">>` for a binary,
/// `<<"boolean">>` for `true`/`false`, and `<<"undefined">>` for the sentinel atom. One export
/// (a `TTerm` param) is exercised with several boxed inputs.
pub fn js_type_of_returns_stub_binary_test() {
  let f =
    fn1(
      "js_type_of",
      ir.TTerm,
      ir.TTerm,
      ir.CallHost("js", "type_of", [
        ir.Var("p0"),
      ]),
    )
  let mod = load(module("typeof", [f]))
  let type_of = atom.create("js_type_of")

  assert catch_apply_dyn(mod, type_of, [to_dynamic(42)])
    == Ok(to_dynamic(bit_array.from_string("number")))
  assert catch_apply_dyn(mod, type_of, [to_dynamic(bit_array.from_string("hi"))])
    == Ok(to_dynamic(bit_array.from_string("string")))
  assert catch_apply_dyn(mod, type_of, [to_dynamic(True)])
    == Ok(to_dynamic(bit_array.from_string("boolean")))
  assert catch_apply_dyn(mod, type_of, [to_dynamic(atom.create("undefined"))])
    == Ok(to_dynamic(bit_array.from_string("undefined")))
}

/// `CallHost("js", "undefined_sentinel", [])` routes to the stub's `undefined_sentinel/0` and
/// returns the sentinel term (the BEAM atom `undefined`). A 0-arg boundary call — proves the
/// dispatch handles the empty argument list.
pub fn js_undefined_sentinel_returns_sentinel_test() {
  let f = fn0("js_undef", ir.TTerm, ir.CallHost("js", "undefined_sentinel", []))
  let mod = load(module("undef", [f]))
  assert catch_apply_dyn(mod, atom.create("js_undef"), [])
    == Ok(to_dynamic(atom.create("undefined")))
}

/// The `type_of` of the stub's own sentinel is `<<"undefined">>` — the two stub ops compose, so
/// the boundary carries a real term out of one call and back into another (a JS frontend leans on
/// exactly this: sentinels flow through `rt_js` ops).
pub fn js_sentinel_then_type_of_composes_test() {
  let f =
    fn0(
      "js_undef_type",
      ir.TTerm,
      ir.Let(
        ["u"],
        ir.CallHost("js", "undefined_sentinel", []),
        ir.CallHost("js", "type_of", [ir.Var("u")]),
      ),
    )
  let mod = load(module("compose", [f]))
  assert catch_apply_dyn(mod, atom.create("js_undef_type"), [])
    == Ok(to_dynamic(bit_array.from_string("undefined")))
}

// ───────────────────────────── fail-closed (K6 / D3a) ─────────────────────────────

/// An unrecognised `"js"` op FAILS CLOSED at the emit chokepoint: `emit_core.emit_module`
/// returns the typed `UnknownJsOp(op)` — never a panic, and (crucially) no `call`/`apply` is
/// emitted for it. The dispatch is a literal `case` (`resolve_js`), so an op it does not
/// recognise resolves to no function at all.
pub fn unknown_js_op_fails_closed_at_emit_test() {
  let m = module("badjs", [fn0("bad", ir.TTerm, ir.CallHost("js", "nope", []))])
  let assert Error(e) = emit_core.emit_module(m, instance.safe_default())
  assert e == emit_core.UnknownJsOp("nope")
}

/// D3a — **no op string can reach an arbitrary MFA.** For a battery of adversarial op strings —
/// including ones that NAME real/dangerous BEAM targets (`erlang`, `halt`, `apply`), ops valid in
/// OTHER capabilities (`gcd` is `"std"`, `print` is Porffor's `""`), and a near-miss of a real op
/// (`"type_of "` with a trailing space) — `emit_module` FAILS CLOSED with `UnknownJsOp(op)`. Not
/// one synthesises a call: the routing is a compile-time literal `case`, not data-driven dispatch,
/// so `op` is a selector among a CLOSED set of fixed function atoms, never a target constructor.
pub fn no_op_string_reaches_arbitrary_mfa_test() {
  let adversarial = [
    "erlang", "halt", "apply", "os_cmd", "system", "nonexistent", "gcd", "print",
    "type_of ", "Add", "",
  ]
  list.each(adversarial, fn(op) {
    let m = module("adv", [fn0("bad", ir.TTerm, ir.CallHost("js", op, []))])
    let assert Error(got) = emit_core.emit_module(m, instance.safe_default())
    assert got == emit_core.UnknownJsOp(op)
  })
}

// ───────────────────────────── ir_lower gating (capability provenance) ─────────────────────────────

/// `ir_lower` ADMITS the `"js"` capability (exactly as it admits a resolved `"std"` call) — a
/// `"js"` `CallHost` is NOT `ForbiddenHost`; the node is left unchanged for `emit_core` to route.
/// Asserted for a KNOWN op and (because `ir_lower` gates the *capability*, not the op) an UNKNOWN
/// op alike: the op is validated downstream at the emit chokepoint, not here.
pub fn ir_lower_admits_js_capability_test() {
  let binding = instance.safe_default()
  let known = module("okjs", [fn0("f", ir.TTerm, ir.CallHost("js", "add", []))])
  let assert Ok(_) = ir_lower.lower(known, binding)
  // The capability is admitted regardless of the specific op (op validity is emit_core's job).
  let unknown =
    module("unkjs", [fn0("f", ir.TTerm, ir.CallHost("js", "whatever", []))])
  let assert Ok(_) = ir_lower.lower(unknown, binding)
}

/// The `"js"` admit does NOT widen the fail-closed default: every OTHER undeclared, non-stdlib
/// capability still fails closed with `ForbiddenHost` in `ir_lower`. Proves admitting `"js"` was
/// surgical (K6 — one capability), not a hole.
pub fn ir_lower_still_fails_closed_for_other_capabilities_test() {
  let binding = instance.safe_default()
  let m = module("evil", [fn0("f", ir.TTerm, ir.CallHost("evil", "op", []))])
  let assert Error(e) = ir_lower.lower(m, binding)
  assert e == ir_lower.ForbiddenHost("evil", "op")
}

// ───────────────────────────── the binding chokepoint (build-fixed rt_js atom) ─────────────────────────────

/// The boundary is bound to `Binding.js_runtime_module` at BUILD time: re-pointing that field to
/// an alternate JS-runtime module makes the emitted dispatch `call` the alternate atom instead —
/// demonstrating the module is a build-controlled literal (D3a), never derived from program data.
/// A behaviour-free structural check: the emitted Core routes `"js"`/`"add"` to the bound module's
/// `add` and to no other module.
pub fn js_dispatch_is_bound_to_js_runtime_module_test() {
  let m =
    module("bound", [
      fn2(
        "f",
        ir.TI32,
        ir.TI32,
        ir.TTerm,
        ir.CallHost("js", "add", [
          ir.Var("p0"),
          ir.Var("p1"),
        ]),
      ),
    ])
  // Default binding → the `rt_js` stub atom.
  let assert Ok(cm_default) = emit_core.emit_module(m, instance.safe_default())
  let core_default = core_printer.print_module(cm_default)
  assert contains(core_default, "'twocore@runtime@rt_js':'add'")

  // Re-point `js_runtime_module` → the dispatch follows the binding (build-fixed atom, not data).
  let rebound =
    instance.Binding(
      ..instance.safe_default(),
      js_runtime_module: "twocore@runtime@rt_js_alt",
    )
  let assert Ok(cm_alt) = emit_core.emit_module(m, rebound)
  let core_alt = core_printer.print_module(cm_alt)
  assert contains(core_alt, "'twocore@runtime@rt_js_alt':'add'")
  // The default atom is gone once re-pointed — the module position tracked the binding.
  assert !contains(core_alt, "'twocore@runtime@rt_js':'add'")
}

/// True iff `haystack` contains `needle` (a thin alias over `gleam/string.contains`).
fn contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}
