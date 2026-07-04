//// Phase-8 unit 02 — native closures (`MakeClosure`/`CallClosure`), end-to-end on the BEAM.
////
//// THE HEADLINE (overview §Acceptance, 02-closures.md Tests): a closure over an
//// enclosing-function local — the exact thing a WASM target (Porffor) cannot build — is here
//// just a BEAM `fun`. Each test authors a small IR `Module` with a same-module helper
//// `Function`, builds a native closure over already-evaluated captured values with
//// `MakeClosure`, applies it with `CallClosure` (or, for the "outlives its frame" case, via
//// `erlang:apply` on the returned fun), lowers it IR → `emit_core` → `build_beam` → a loaded
//// `.beam`, and asserts the VALUE — never the emitted bytes.
////
//// Spec-first (CLAUDE.md D8): the asserted values are the ones the closure semantics REQUIRE
//// (`f(Cap, A) = Cap` sees its capture; `add(C1,C2,X) = C1+C2+X`; a nullary `k(C) = C`), not
//// whatever the current code happens to print. The harness (`load`/`module`) mirrors
//// `term_ops_test.gleam` / `emit_core_e2e_test.gleam`.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/ir
import twocore/runtime/instance

// Test-only FFI (see `test/twocore_emit_test_ffi.erl`): apply `M:F(Args)` / a fun value,
// capturing a raise as `Error(text)`. Re-typed for `Dynamic` args/results, sound because
// `erlang:apply` is untyped at runtime.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply_dyn(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

// Apply a fun VALUE (a returned `MakeClosure`) to an argument list via `erlang:apply(Fun,
// Args)` — proving the native `fun` outlives its creating frame and is callable from outside
// the generated module.
@external(erlang, "twocore_emit_test_ffi", "apply_fun")
fn apply_fun_dyn(fun: Dynamic, args: List(Dynamic)) -> Result(Dynamic, String)

// Coerce any Gleam value to `Dynamic` (identity at runtime) — to build `Dynamic` arg lists
// and expected-value comparisons.
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

// ───────────────────────────── plumbing ─────────────────────────────

/// Emit `module` to Core text, compile it, and load it into the test VM; return the loaded
/// module atom. `let assert` is the success contract — a failure to emit/compile/load is a
/// genuine test failure.
fn load(module: ir.Module) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(module, instance.safe_default())
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

/// Build a closure module wrapping `functions`, exporting each by name. `uses_numerics` is on
/// (the functions carry i32 constants / arithmetic); no memory/globals are linked, so the
/// module emits in the un-threaded (cell) run-ABI — the direct-IR Phase-8 shape.
fn module(name: String, functions: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "twocore@closures@" <> name,
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

fn i32(n: Int) -> ir.Value {
  ir.ConstI32(n)
}

fn local(name: String) -> ir.Local {
  ir.Local(name, ir.TI32)
}

// ───────────────────────────── the headline ─────────────────────────────

/// THE HEADLINE. A helper `f(Cap, A) = Cap` returns its FIRST parameter (the capture),
/// ignoring the runtime arg. An exported driver binds an enclosing local `c = 42`, builds
/// `MakeClosure("f", [c], 1)` as `g`, then `CallClosure(g, [0])`. The closure sees the
/// enclosing local and returns `42` — a closure over an enclosing local works (the Porffor
/// wall, gone). The runtime arg is deliberately a different value (`0`) so the assertion can
/// only pass if the CAPTURE (not the arg) is returned.
pub fn closure_captures_enclosing_local_e2e_test() {
  // f(cap, a) -> cap   (a same-module helper; the fun forwards to it)
  let f =
    ir.Function(
      name: "f",
      params: [local("cap"), local("a")],
      result: [ir.TI32],
      locals: [],
      body: ir.Values([ir.Var("cap")]),
    )
  // headline() -> let c = 42 in let g = make_closure @f (%c) arity=1 in call_closure %g (0)
  let headline =
    ir.Function(
      name: "headline",
      params: [],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        ["c"],
        ir.Values([i32(42)]),
        ir.Let(
          ["g"],
          ir.MakeClosure("f", [ir.Var("c")], 1),
          ir.CallClosure(ir.Var("g"), [i32(0)]),
        ),
      ),
    )
  let mod = load(module("headline", [f, headline]))

  assert catch_apply_dyn(mod, atom.create("headline"), []) == Ok(to_dynamic(42))
}

// ───────────────────────────── closure outlives its creator ─────────────────────────────

/// A closure carries its captured data PAST its creator's return: `make_g()` builds
/// `MakeClosure("f", [7], 1)` and RETURNS it (a fun `TTerm`). The test then applies the
/// returned fun later, from outside the module, via `erlang:apply` — and it still returns the
/// captured `7`. BEAM funs outlive their creating frame (free — no heap environment to keep
/// alive by hand).
pub fn closure_outlives_creating_frame_e2e_test() {
  // f(cap, a) -> cap
  let f =
    ir.Function(
      name: "f",
      params: [local("cap"), local("a")],
      result: [ir.TI32],
      locals: [],
      body: ir.Values([ir.Var("cap")]),
    )
  // make_g() -> let c = 7 in make_closure @f (%c) arity=1   (returns the fun by fall-through)
  let make_g =
    ir.Function(
      name: "make_g",
      params: [],
      result: [ir.TTerm],
      locals: [],
      body: ir.Let(
        ["c"],
        ir.Values([i32(7)]),
        ir.MakeClosure("f", [ir.Var("c")], 1),
      ),
    )
  let mod = load(module("outlive", [f, make_g]))

  // `make_g` returns a native fun; apply it later via erlang:apply — still yields the capture.
  let assert Ok(g) = catch_apply_dyn(mod, atom.create("make_g"), [])
  assert apply_fun_dyn(g, [to_dynamic(0)]) == Ok(to_dynamic(7))
}

// ───────────────────────────── multiple captures + non-zero arity ─────────────────────────────

/// Multiple captures composed with a runtime arg: `add(C1, C2, X) = C1 + C2 + X`.
/// `MakeClosure("add", [10, 20], 1)` closes over TWO values and takes ONE runtime arg;
/// `CallClosure(_, [5])` yields `10 + 20 + 5 = 35`. Proves the capture-then-args ordering and a
/// non-zero runtime arity together.
pub fn closure_multiple_captures_and_arity_e2e_test() {
  // add(c1, c2, x) -> (c1 + c2) + x
  let add =
    ir.Function(
      name: "add",
      params: [local("c1"), local("c2"), local("x")],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        ["s"],
        ir.Num(ir.IAdd(ir.W32), [ir.Var("c1"), ir.Var("c2")]),
        ir.Num(ir.IAdd(ir.W32), [ir.Var("s"), ir.Var("x")]),
      ),
    )
  // add35() -> let g = make_closure @add (10, 20) arity=1 in call_closure %g (5)
  let add35 =
    ir.Function(
      name: "add35",
      params: [],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        ["g"],
        ir.MakeClosure("add", [i32(10), i32(20)], 1),
        ir.CallClosure(ir.Var("g"), [i32(5)]),
      ),
    )
  let mod = load(module("multi", [add, add35]))

  assert catch_apply_dyn(mod, atom.create("add35"), []) == Ok(to_dynamic(35))
}

// ───────────────────────────── nullary closure (arity = 0) ─────────────────────────────

/// A nullary closure: `k(C) = C`. `MakeClosure("k", [7], 0)` builds a `fun () -> apply
/// 'k'/1(7)`; `CallClosure(_, [])` applies it with NO runtime args and yields the captured `7`.
/// Proves the `arity = 0` edge (a nullary fun whose body is the direct call to the target on the
/// captures alone).
pub fn closure_nullary_arity_zero_e2e_test() {
  // k(c) -> c
  let k =
    ir.Function(
      name: "k",
      params: [local("c")],
      result: [ir.TI32],
      locals: [],
      body: ir.Values([ir.Var("c")]),
    )
  // seven() -> let g = make_closure @k (7) arity=0 in call_closure %g ()
  let seven =
    ir.Function(
      name: "seven",
      params: [],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        ["g"],
        ir.MakeClosure("k", [i32(7)], 0),
        ir.CallClosure(ir.Var("g"), []),
      ),
    )
  let mod = load(module("nullary", [k, seven]))

  assert catch_apply_dyn(mod, atom.create("seven"), []) == Ok(to_dynamic(7))
}

// ───────────────────────────── resolution: typed errors, never a panic ─────────────────────────────

/// SPEC (02-closures.md §Core Erlang lowering / K7): `MakeClosure`'s `fn_name` joins the same
/// `UnknownFunction` resolution set as `CallDirect`. An UNDEFINED target is a TYPED backend error
/// (`Error(UnknownFunction)`), never a panic — proven by inspecting `emit_module`'s `Result`
/// directly rather than loading.
pub fn make_closure_unknown_function_is_typed_error_test() {
  // driver() -> make_closure @nope () arity=0   (no function named "nope" is defined)
  let driver =
    ir.Function(
      name: "driver",
      params: [],
      result: [ir.TTerm],
      locals: [],
      body: ir.MakeClosure("nope", [], 0),
    )
  let result =
    emit_core.emit_module(module("unknown", [driver]), instance.safe_default())
  assert result == Error(emit_core.UnknownFunction("nope"))
}

/// SPEC (02-closures.md §Core Erlang lowering edge cases): a `MakeClosure` whose `fn_name`
/// resolves to a defined function of the WRONG arity (its parameter count must equal
/// `len(captures) + arity`) is a TYPED error (`Error(ArityMismatch(expected, got))`), never a
/// panic. Here `f` has 2 params but the closure declares `1 capture + arity 2 = 3` expected
/// params, so `expected = 3`, `got = 2`.
pub fn make_closure_arity_mismatch_is_typed_error_test() {
  // f(cap, a) -> cap   (2 params)
  let f =
    ir.Function(
      name: "f",
      params: [local("cap"), local("a")],
      result: [ir.TI32],
      locals: [],
      body: ir.Values([ir.Var("cap")]),
    )
  // driver() -> make_closure @f (%anything) arity=2   (declares 1 + 2 = 3 expected params ≠ 2)
  let driver =
    ir.Function(
      name: "driver",
      params: [local("anything")],
      result: [ir.TTerm],
      locals: [],
      body: ir.MakeClosure("f", [ir.Var("anything")], 2),
    )
  let result =
    emit_core.emit_module(
      module("mismatch", [f, driver]),
      instance.safe_default(),
    )
  assert result == Error(emit_core.ArityMismatch(3, 2))
}
