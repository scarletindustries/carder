//// Lever 6 — single-use, non-recursive `letrec` join-function INLINING (`emit_core.inline_join_funs`,
//// gated by `binding.inline_joins`).
////
//// Two layers, both objective (not emitted-text change-detectors):
////
//// **AST-level** — drive the pure `CModule -> CModule` pass directly over hand-built Core ASTs and
//// assert the SOUNDNESS contract of a standard single-use inline: a single-use non-recursive join is
//// beta-reduced to a `let`-binding (its `letrec` gone, its body spliced); a MULTI-exit join (applied
//// twice) is left intact; a RECURSIVE loop `letrec` (its body self-applies) is left intact; a
//// try-body `letrec` (applied as a `try` `Arg`) is left intact (pinned, so the hoist that avoids the
//// `ambiguous_catch_try_state` validator rejection survives); a zero-arity join splices its body with
//// no `let`; nested single-use joins collapse in one pass.
////
//// **Behavioral / gate** — through `emit_core.emit_module`: a fall-through-only `Block` produces a
//// single-use join that DISAPPEARS under `inline_joins: True` but REMAINS under the default
//// `inline_joins: False` (so the default emitted Core is unchanged); an `If` produces a two-exit join
//// that survives even under `True`; and a small module compiles + loads + RUNS to the spec-correct
//// value under `inline_joins: True` (proving the transform preserves semantics through real codegen).

import gleam/bit_array
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import twocore/backend/build_beam
import twocore/backend/core_erlang.{
  type CExpr, type CModule, CApply, CAtom, CCase, CClause, CFun, CInt, CLet,
  CLetrec, CModule, CTry, CTuple, CVar, FName, FunDef, PInt, PVar,
}
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/ir
import twocore/runtime/instance

// Test-only FFI (see `test/twocore_emit_test_ffi.erl`): apply `M:F(Args)` and capture a trap as
// `Error(text)` instead of crashing the test process.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

// ───────────────────────────── plumbing ─────────────────────────────

/// A `CModule` with a single def `'f'/0 = fun () -> body`, so the pass can be exercised over `body`.
fn wrap(body: CExpr) -> CModule {
  CModule(name: "twocore@inline@t", exports: [], attributes: [], defs: [
    FunDef(FName("f", 0), CFun([], body)),
  ])
}

/// Run the pass over `wrap(body)` and return the (possibly-rewritten) body of `'f'/0`.
fn inlined(body: CExpr) -> CExpr {
  let assert [FunDef(_, CFun(_, out))] =
    emit_core.inline_join_funs(wrap(body)).defs
  out
}

/// Does `expr` contain ANY `letrec` node (anywhere in the tree)? Used to assert a join was — or was
/// not — dissolved.
fn has_letrec(expr: CExpr) -> Bool {
  case expr {
    CLetrec(..) -> True
    CLet(_, arg, body) -> has_letrec(arg) || has_letrec(body)
    CCase(arg, clauses) ->
      has_letrec(arg)
      || list.any(clauses, fn(cl) {
        has_letrec(cl.body) || has_letrec(cl.guard)
      })
    CTuple(es) -> list.any(es, has_letrec)
    CApply(_, args) -> list.any(args, has_letrec)
    CTry(arg, _, body, _, handler) ->
      has_letrec(arg) || has_letrec(body) || has_letrec(handler)
    CFun(_, b) -> has_letrec(b)
    _ -> False
  }
}

/// The default (fail-closed) binding — `inline_joins: False`.
fn off() -> instance.Binding {
  instance.safe_default()
}

/// The lever-6 binding — the default posture with only `inline_joins` flipped `True`.
fn on() -> instance.Binding {
  instance.Binding(..instance.safe_default(), inline_joins: True)
}

/// Emit `module` under `binding` and return the Core body of function `name`.
fn body_of(
  module: ir.Module,
  binding: instance.Binding,
  name: String,
) -> CExpr {
  let assert Ok(cm) = emit_core.emit_module(module, binding)
  let assert Ok(FunDef(_, CFun(_, body))) =
    list.find(cm.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == name
    })
  body
}

/// A numerics-on, memory-off module wrapping `functions`, exporting each by name.
fn module(name: String, functions: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "twocore@inline@" <> name,
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

/// Emit `module` under `binding`, compile it, and load it; return the loaded module atom.
fn load(module: ir.Module, binding: instance.Binding) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(module, binding)
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

// ═══════════════════════════ AST-level: the soundness contract ═══════════════════════════

/// A NON-RECURSIVE join applied EXACTLY ONCE is beta-reduced: the `letrec` disappears and the sole
/// `apply 'j0'/1(7)` becomes `let p = 7 in <body>` (params fresh, so no capture).
pub fn single_use_join_is_inlined_test() {
  let body =
    CLetrec(
      [FunDef(FName("j0", 1), CFun(["p"], CApply(FName("k", 1), [CVar("p")])))],
      CApply(FName("j0", 1), [CInt(7)]),
    )
  let out = inlined(body)
  // No `letrec`/`fun` for the join remains; the body is spliced under a `let`.
  assert out == CLet(["p"], CInt(7), CApply(FName("k", 1), [CVar("p")]))
  assert has_letrec(out) == False
}

/// A MULTI-EXIT join — applied TWICE (once per `case` arm, the shape an `If`/`Switch` continuation
/// emits) — is NOT inlined: duplicating its body would be a size blow-up and it is not single-use, so
/// the `letrec` stays.
pub fn multi_use_join_not_inlined_test() {
  let body =
    CLetrec(
      [FunDef(FName("j0", 1), CFun(["p"], CVar("p")))],
      CCase(CVar("x"), [
        CClause([PInt(0)], CAtom("true"), CApply(FName("j0", 1), [CInt(1)])),
        CClause([PVar("w")], CAtom("true"), CApply(FName("j0", 1), [CInt(2)])),
      ]),
    )
  // Unchanged: the join is reached from two exits, so the pass leaves the node byte-identical.
  assert inlined(body) == body
}

/// A RECURSIVE `letrec` (a loop head whose body self-applies on the back-edge) is NEVER inlined, even
/// though its inner is a single entry `apply` — inlining would drop the loop. The self-apply marks it
/// recursive, so the `letrec` (and the back-edge tail call) survives.
pub fn recursive_loop_not_inlined_test() {
  let body =
    CLetrec(
      [FunDef(FName("j0", 1), CFun(["i"], CApply(FName("j0", 1), [CVar("i")])))],
      CApply(FName("j0", 1), [CInt(0)]),
    )
  assert inlined(body) == body
  assert has_letrec(inlined(body)) == True
}

/// A try-body `letrec` (applied EXACTLY ONCE, as the `try` `Arg`) is PINNED, NOT inlined: `emit_try`
/// hoists the protected body into a nullary local fun precisely so the `Arg` stays a single `apply`
/// (splicing it back would re-expose the `ambiguous_catch_try_state` BEAM-validator rejection).
pub fn try_body_join_not_inlined_test() {
  let body =
    CLetrec(
      [FunDef(FName("j0", 0), CFun([], CInt(42)))],
      CTry(
        arg: CApply(FName("j0", 0), []),
        body_vars: ["v"],
        body: CVar("v"),
        evars: ["c", "r", "s"],
        handler: CVar("r"),
      ),
    )
  assert inlined(body) == body
}

/// A single-use ZERO-ARITY join splices its body with NO `let` (the vacuous `let <> = <> in body`
/// is elided, mirroring `apply_cont`'s empty-`KBind` handling).
pub fn zero_arity_join_inlined_test() {
  let body =
    CLetrec(
      [FunDef(FName("j0", 0), CFun([], CInt(42)))],
      CTuple([
        CApply(FName("j0", 0), []),
        CInt(1),
      ]),
    )
  // The `apply 'j0'/0()` becomes just its body `42` — no wrapping `let`.
  assert inlined(body) == CTuple([CInt(42), CInt(1)])
}

/// Nested single-use joins collapse in ONE bottom-up-consistent pass: `j0` (used once, inside `j1`'s
/// body) and `j1` (used once) both dissolve into nested `let`s, with no re-traversal and no residual
/// `letrec`.
pub fn nested_single_use_joins_collapse_test() {
  let body =
    CLetrec(
      [FunDef(FName("j0", 1), CFun(["a"], CApply(FName("k", 1), [CVar("a")])))],
      CLetrec(
        [
          FunDef(
            FName("j1", 1),
            CFun(["b"], CApply(FName("j0", 1), [CVar("b")])),
          ),
        ],
        CApply(FName("j1", 1), [CInt(9)]),
      ),
    )
  let out = inlined(body)
  assert has_letrec(out) == False
  // `let b = 9 in (let a = b in apply 'k'/1(a))`.
  assert out
    == CLet(
      ["b"],
      CInt(9),
      CLet(["a"], CVar("b"), CApply(FName("k", 1), [CVar("a")])),
    )
}

// ═══════════════════════════ through emit_core: the gate + real joins ═══════════════════════════

/// `f(x) = { block b -> x + 1 }; y * 2` (a fall-through-only block whose result is used once) lowers
/// to a SINGLE-USE join. Under the default `inline_joins: False` the `letrec` is present (the emitted
/// Core is unchanged); under `inline_joins: True` the pass dissolves it.
fn block_single_use_module() -> ir.Function {
  ir.Function(
    name: "f",
    params: [ir.Local("x", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Let(
      ["y"],
      ir.Block(
        "b",
        [ir.TI32],
        ir.Num(ir.IAdd(ir.W32), [ir.Var("x"), ir.ConstI32(1)]),
      ),
      ir.Num(ir.IMul(ir.W32), [ir.Var("y"), ir.ConstI32(2)]),
    ),
  )
}

/// DEFAULT-OFF gate: a single-use block join is a `letrec` in the emitted Core when `inline_joins`
/// is `False` (the fail-closed default) — the default output is unperturbed.
pub fn block_join_present_by_default_test() {
  let b = body_of(module("block_off", [block_single_use_module()]), off(), "f")
  assert has_letrec(b) == True
}

/// LEVER-6 ON: the SAME single-use block join is beta-reduced away — no `letrec` remains in `f`.
pub fn block_join_inlined_when_enabled_test() {
  let b = body_of(module("block_on", [block_single_use_module()]), on(), "f")
  assert has_letrec(b) == False
}

/// `f(x) = (if x then x+1 else x-1)` continuation is a TWO-EXIT join (both arms `apply` it). Even
/// under `inline_joins: True` it is NOT inlined — the `letrec` survives (multi-use guard).
pub fn if_join_not_inlined_when_enabled_test() {
  let f =
    ir.Function(
      name: "f",
      params: [ir.Local("x", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        ["y"],
        ir.If(
          cond: ir.Var("x"),
          result: [ir.TI32],
          then_branch: ir.Num(ir.IAdd(ir.W32), [ir.Var("x"), ir.ConstI32(1)]),
          else_branch: ir.Num(ir.ISub(ir.W32), [ir.Var("x"), ir.ConstI32(1)]),
        ),
        ir.Return([ir.Var("y")]),
      ),
    )
  let b = body_of(module("if_on", [f]), on(), "f")
  assert has_letrec(b) == True
}

/// SEMANTICS through real codegen: the single-use-block module compiles + loads + RUNS to the
/// spec-correct value under `inline_joins: True` — `f(5) = (5 + 1) * 2 = 12` — proving the inline
/// preserves behavior end-to-end on the BEAM.
pub fn inlined_module_runs_correctly_test() {
  let mod = load(module("block_run", [block_single_use_module()]), on())
  assert catch_apply(mod, atom.create("f"), [5]) == Ok(12)
  // A larger input to exercise the same spliced path: f(20) = 42.
  assert catch_apply(mod, atom.create("f"), [20]) == Ok(42)
}
