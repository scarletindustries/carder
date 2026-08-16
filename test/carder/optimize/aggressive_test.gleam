//// Unit P3-04 — per-pass spec/differential tests for the Unsafe-only Aggressive passes.
////
//// Every assertion is against WASM SPEC behavior (a `call` evaluates its already-computed args,
//// runs the callee to completion, and propagates any trap at the call site — spec §4.4.7
//// Control Instructions) or the F2 semantics-preservation requirement — NOT against whatever
//// the current code emits (no change-detectors, D8). The load-bearing technique: construct
//// modules whose fully-inlined bodies fold (via the fixpoint's baseline sweep) to a single
//// constant or a `Trap`, then assert that constant/trap is exactly what the un-inlined program
//// computes. A capture bug, a dropped trap, or a reordered effect would change that value.
////
//// The optimizer is run at `Aggressive` (baseline + charge_elide + inline), and — for the
//// Unsafe-only gating tests (F4) — also at `Baseline`/`OptNone`.

import carder/backend/emit_core
import carder/ir
import carder/middle/ir_opt
import carder/middle/ir_opt/aggressive
import carder/middle/ir_opt/pass
import carder/opt_level.{Aggressive, Baseline, OptNone}
import carder/runtime/profiles
import gleam/int
import gleam/list
import gleam/option
import gleam/result

// ───────────────────────────── harness ─────────────────────────────

/// A module wrapping `funcs`, with the given `exports` (export-name = fn-name) — numerics on, no
/// memory/globals/tables.
fn mod_of(funcs: List(ir.Function), exports: List(ir.ExportDecl)) -> ir.Module {
  ir.Module(
    name: "carder@opt@aggressive_test",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: funcs,
    exports: exports,
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// A zero-arg entry function named `name` with result types `result` and body `body`.
fn func(
  name: String,
  params: List(ir.Local),
  result: List(ir.ValType),
  body: ir.Expr,
) -> ir.Function {
  ir.Function(
    name: name,
    params: params,
    result: result,
    locals: [],
    body: body,
  )
}

/// An `i32` param slot.
fn p_i32(name: String) -> ir.Local {
  ir.Local(name, ir.TI32)
}

/// The optimized (`Aggressive`) module.
fn opt_agg(m: ir.Module) -> ir.Module {
  ir_opt.optimize(m, Aggressive)
}

/// The optimized (`Baseline`) module.
fn opt_base(m: ir.Module) -> ir.Module {
  ir_opt.optimize(m, Baseline)
}

/// The body of the function named `name` in `m`, or `Values([])` if absent (total, no panic).
fn body_of(m: ir.Module, name: String) -> ir.Expr {
  case list.find(m.functions, fn(f) { f.name == name }) {
    Ok(f) -> f.body
    Error(Nil) -> ir.Values([])
  }
}

/// Is a function named `name` present in `m`?
fn has_function(m: ir.Module, name: String) -> Bool {
  list.any(m.functions, fn(f) { f.name == name })
}

/// `Values([ConstI32(bits)])` — the shape a fully-folded i32 body collapses to.
fn vi32(bits: Int) -> ir.Expr {
  ir.Values([ir.ConstI32(bits)])
}

/// Does any call (`CallDirect`/`CallIndirect`/`CallHost`) survive anywhere in `e`?
fn has_call(e: ir.Expr) -> Bool {
  case e {
    ir.CallDirect(_, _) | ir.CallIndirect(_, _, _, _) | ir.CallHost(_, _, _) ->
      True
    ir.Let(_, rhs, body) -> has_call(rhs) || has_call(body)
    ir.Block(_, _, body) -> has_call(body)
    ir.Loop(_, _, _, body) -> has_call(body)
    ir.If(_, _, t, el) -> has_call(t) || has_call(el)
    ir.Switch(_, _, arms, default) ->
      list.any(arms, fn(a) { has_call(a.body) }) || has_call(default)
    ir.Charge(_, body) -> has_call(body)
    _ -> False
  }
}

/// Does a `CallDirect(name, _)` survive anywhere in `e`?
fn calls_directly(e: ir.Expr, name: String) -> Bool {
  case e {
    ir.CallDirect(n, _) -> n == name
    ir.Let(_, rhs, body) ->
      calls_directly(rhs, name) || calls_directly(body, name)
    ir.Block(_, _, body) -> calls_directly(body, name)
    ir.Loop(_, _, _, body) -> calls_directly(body, name)
    ir.If(_, _, t, el) -> calls_directly(t, name) || calls_directly(el, name)
    ir.Switch(_, _, arms, default) ->
      list.any(arms, fn(a) { calls_directly(a.body, name) })
      || calls_directly(default, name)
    ir.Charge(_, body) -> calls_directly(body, name)
    _ -> False
  }
}

/// Does a `Charge` node survive anywhere in `e`?
fn contains_charge(e: ir.Expr) -> Bool {
  case e {
    ir.Charge(_, _) -> True
    ir.Let(_, rhs, body) -> contains_charge(rhs) || contains_charge(body)
    ir.Block(_, _, body) -> contains_charge(body)
    ir.Loop(_, _, _, body) -> contains_charge(body)
    ir.If(_, _, t, el) -> contains_charge(t) || contains_charge(el)
    ir.Switch(_, _, arms, default) ->
      list.any(arms, fn(a) { contains_charge(a.body) })
      || contains_charge(default)
    _ -> False
  }
}

// Common callees ---------------------------------------------------------------

/// `add(a, b) = a + b` — a leaf callee (`Return([a + b])` in ANF).
fn add_callee() -> ir.Function {
  func(
    "add",
    [p_i32("a"), p_i32("b")],
    [ir.TI32],
    ir.Let(
      ["s"],
      ir.Num(ir.IAdd(ir.W32), [ir.Var("a"), ir.Var("b")]),
      ir.Return([ir.Var("s")]),
    ),
  )
}

/// `dbl(p) = p * 2` — a small leaf callee.
fn dbl_callee() -> ir.Function {
  func(
    "dbl",
    [p_i32("p")],
    [ir.TI32],
    ir.Let(
      ["d"],
      ir.Num(ir.IMul(ir.W32), [ir.Var("p"), ir.ConstI32(2)]),
      ir.Return([ir.Var("d")]),
    ),
  )
}

// ══════════════════════════ §1. inlining preserves values ══════════════════════════

/// Inlining a leaf callee preserves its returned value: `add(20, 22)` inlines and folds to `42`
/// (spec §4.4.7 — the call runs the callee to completion and yields its result). The direct
/// `CallDirect` disappears at `Aggressive`.
pub fn inline_leaf_preserves_value_test() {
  let main =
    func(
      "main",
      [],
      [ir.TI32],
      ir.Let(
        ["r"],
        ir.CallDirect("add", [ir.ConstI32(20), ir.ConstI32(22)]),
        ir.Values([ir.Var("r")]),
      ),
    )
  let m = mod_of([main, add_callee()], [])
  assert body_of(opt_agg(m), "main") == vi32(42)
  assert has_call(body_of(opt_agg(m), "main")) == False
}

/// A callee with an early `Return` inside an `If` inlines correctly through the single-exit
/// (`Return → Break(exit_label)`) rewrite: `sel(1) = 1`, `sel(0) = 2`.
pub fn inline_early_return_in_branch_test() {
  let sel =
    func(
      "sel",
      [p_i32("p")],
      [ir.TI32],
      ir.If(
        ir.Var("p"),
        [ir.TI32],
        ir.Return([ir.ConstI32(1)]),
        ir.Values([ir.ConstI32(2)]),
      ),
    )
  let caller = fn(arg: Int) {
    mod_of(
      [
        func(
          "main",
          [],
          [ir.TI32],
          ir.Let(
            ["r"],
            ir.CallDirect("sel", [ir.ConstI32(arg)]),
            ir.Values([ir.Var("r")]),
          ),
        ),
        sel,
      ],
      [],
    )
  }
  assert body_of(opt_agg(caller(1)), "main") == vi32(1)
  assert body_of(opt_agg(caller(0)), "main") == vi32(2)
}

/// Two call sites of the same small callee each inline with DISTINCT fresh names and the module
/// stays well-formed: `dbl(10) + dbl(20)` folds to `60`.
pub fn inline_multiple_sites_test() {
  let main =
    func(
      "main",
      [],
      [ir.TI32],
      ir.Let(
        ["a"],
        ir.CallDirect("dbl", [ir.ConstI32(10)]),
        ir.Let(
          ["b"],
          ir.CallDirect("dbl", [ir.ConstI32(20)]),
          ir.Num(ir.IAdd(ir.W32), [ir.Var("a"), ir.Var("b")]),
        ),
      ),
    )
  let m = mod_of([main, dbl_callee()], [])
  assert body_of(opt_agg(m), "main") == vi32(60)
}

/// A chain of non-recursive callees `main → f3 → f2 → f1 → f0` inlines fully within the fixpoint
/// and folds to `f0`'s constant `1` — demonstrating convergence over an acyclic call graph.
pub fn inline_chain_converges_test() {
  let leaf = fn(name: String, callee: String) {
    func(
      name,
      [],
      [ir.TI32],
      ir.Let(["v"], ir.CallDirect(callee, []), ir.Return([ir.Var("v")])),
    )
  }
  let f0 = func("f0", [], [ir.TI32], ir.Return([ir.ConstI32(1)]))
  let m =
    mod_of(
      [
        func(
          "main",
          [],
          [ir.TI32],
          ir.Let(["r"], ir.CallDirect("f3", []), ir.Values([ir.Var("r")])),
        ),
        leaf("f3", "f2"),
        leaf("f2", "f1"),
        leaf("f1", "f0"),
        f0,
      ],
      [],
    )
  assert body_of(opt_agg(m), "main") == vi32(1)
  assert has_call(body_of(opt_agg(m), "main")) == False
}

// ══════════════════════════ §2. inlining preserves traps (WASM has no UB) ══════════════════════════

/// Inlining does NOT drop a trap: a callee that computes `a / b` inlined with `b = 0` folds to
/// `Trap(IntDivByZero)` — the exact trap the un-inlined call would raise (spec §4.4.7 propagates
/// the callee trap at the call site). With `b ≠ 0` it folds to the quotient.
pub fn inline_preserves_div_by_zero_trap_test() {
  let divf =
    func(
      "divf",
      [p_i32("a"), p_i32("b")],
      [ir.TI32],
      ir.Let(
        ["q"],
        ir.Num(ir.IDivS(ir.W32), [ir.Var("a"), ir.Var("b")]),
        ir.Return([ir.Var("q")]),
      ),
    )
  let caller = fn(a: Int, b: Int) {
    mod_of(
      [
        func(
          "main",
          [],
          [ir.TI32],
          ir.Let(
            ["r"],
            ir.CallDirect("divf", [ir.ConstI32(a), ir.ConstI32(b)]),
            ir.Values([ir.Var("r")]),
          ),
        ),
        divf,
      ],
      [],
    )
  }
  // The trapping input: the trap survives inlining (NOT dropped).
  assert body_of(opt_agg(caller(5, 0)), "main") == ir.Trap(ir.IntDivByZero)
  // A non-trapping input: the value is preserved.
  assert body_of(opt_agg(caller(10, 2)), "main") == vi32(5)
}

/// An `Unreachable` inside the callee fires at the same program point after inlining — the trap
/// is preserved, never elided by the Unsafe posture.
pub fn inline_preserves_unreachable_trap_test() {
  let boom = func("boom", [], [ir.TI32], ir.Trap(ir.Unreachable))
  let m =
    mod_of(
      [
        func(
          "main",
          [],
          [ir.TI32],
          ir.Let(["r"], ir.CallDirect("boom", []), ir.Values([ir.Var("r")])),
        ),
        boom,
      ],
      [],
    )
  assert body_of(opt_agg(m), "main") == ir.Trap(ir.Unreachable)
}

// ══════════════════════════ §3. capture-avoidance ══════════════════════════

/// Capture-avoidance: a caller local `x` passed as the arg, and a callee local ALSO named `x`,
/// must not collide. `f(p) = { x = 7; p + x }` called as `f(x)` with caller `x = 100` must yield
/// `107` (arg `x` = 100 plus callee `x` = 7), NOT `14` (which is what a capture bug — the callee
/// `x` rebinding the arg `x` — would produce).
pub fn inline_capture_avoidance_test() {
  let f =
    func(
      "f",
      [p_i32("p")],
      [ir.TI32],
      ir.Let(
        ["x"],
        ir.Values([ir.ConstI32(7)]),
        ir.Num(ir.IAdd(ir.W32), [ir.Var("p"), ir.Var("x")]),
      ),
    )
  let main =
    func(
      "main",
      [],
      [ir.TI32],
      ir.Let(
        ["x"],
        ir.Values([ir.ConstI32(100)]),
        ir.Let(
          ["r"],
          ir.CallDirect("f", [ir.Var("x")]),
          ir.Values([ir.Var("r")]),
        ),
      ),
    )
  let m = mod_of([main, f], [])
  assert body_of(opt_agg(m), "main") == vi32(107)
}

// ══════════════════════════ §4. recursion guard (termination) ══════════════════════════

/// A self-recursive callee is NEVER inlined (the acyclic call-graph guard) — the `CallDirect`
/// survives and `optimize` still converges (no timeout).
pub fn self_recursive_not_inlined_test() {
  let self_fn =
    func(
      "self",
      [p_i32("n")],
      [ir.TI32],
      ir.Let(
        ["x"],
        ir.CallDirect("self", [ir.Var("n")]),
        ir.Return([ir.Var("x")]),
      ),
    )
  let m =
    mod_of(
      [
        func(
          "main",
          [],
          [ir.TI32],
          ir.Let(
            ["r"],
            ir.CallDirect("self", [ir.ConstI32(3)]),
            ir.Values([ir.Var("r")]),
          ),
        ),
        self_fn,
      ],
      [],
    )
  assert calls_directly(body_of(opt_agg(m), "main"), "self") == True
}

/// A mutually-recursive pair `f → g → f` is on a cycle, so NEITHER is inlined; a caller of `f`
/// keeps its direct call and the pipeline converges.
pub fn mutual_recursion_not_inlined_test() {
  let f =
    func(
      "f",
      [p_i32("n")],
      [ir.TI32],
      ir.Let(["x"], ir.CallDirect("g", [ir.Var("n")]), ir.Return([ir.Var("x")])),
    )
  let g =
    func(
      "g",
      [p_i32("n")],
      [ir.TI32],
      ir.Let(["y"], ir.CallDirect("f", [ir.Var("n")]), ir.Return([ir.Var("y")])),
    )
  let m =
    mod_of(
      [
        func(
          "main",
          [],
          [ir.TI32],
          ir.Let(
            ["r"],
            ir.CallDirect("f", [ir.ConstI32(0)]),
            ir.Values([ir.Var("r")]),
          ),
        ),
        f,
        g,
      ],
      [],
    )
  assert calls_directly(body_of(opt_agg(m), "main"), "f") == True
}

/// `optimize(_, Aggressive)` reaches a FIXPOINT — re-optimizing an already-optimized module is a
/// no-op (idempotent), so the pipeline provably converges even with inlining registered.
pub fn aggressive_is_idempotent_test() {
  let m =
    mod_of(
      [
        func(
          "main",
          [],
          [ir.TI32],
          ir.Let(
            ["a"],
            ir.CallDirect("dbl", [ir.ConstI32(21)]),
            ir.Values([ir.Var("a")]),
          ),
        ),
        dbl_callee(),
      ],
      [],
    )
  let once = opt_agg(m)
  assert opt_agg(once) == once
}

// ══════════════════════════ §5. orphan deletion (single-owner) ══════════════════════════

/// A single-call-site callee inlined at its only site becomes an orphan (zero remaining call
/// sites, not exported) and is DELETED from the module.
pub fn orphaned_callee_is_deleted_test() {
  let main =
    func(
      "main",
      [],
      [ir.TI32],
      ir.Let(
        ["r"],
        ir.CallDirect("dbl", [ir.ConstI32(5)]),
        ir.Values([ir.Var("r")]),
      ),
    )
  let m = mod_of([main, dbl_callee()], [])
  assert has_function(m, "dbl") == True
  assert has_function(opt_agg(m), "dbl") == False
  // and the result is still correct (dbl(5) = 10)
  assert body_of(opt_agg(m), "main") == vi32(10)
}

/// An EXPORTED callee is inlined at its internal call site but is NOT deleted — it stays a
/// callable entry point even with zero remaining `CallDirect` sites (entry-referenced).
pub fn exported_callee_is_retained_test() {
  let main =
    func(
      "main",
      [],
      [ir.TI32],
      ir.Let(
        ["r"],
        ir.CallDirect("dbl", [ir.ConstI32(5)]),
        ir.Values([ir.Var("r")]),
      ),
    )
  let m = mod_of([main, dbl_callee()], [ir.ExportFn("double", "dbl")])
  assert has_function(opt_agg(m), "dbl") == True
}

// ══════════════════════════ §6. fixpoint reuse — baseline folds inlined constants (§D) ══════════════════════════

/// Inlining exposes a constant argument that the fixpoint's baseline sweep then folds:
/// `is_zero(0) = 1` (the callee's `IEqz` folds after the constant arg is substituted), with no
/// new pass — post-inline cleanup is baseline re-run.
pub fn inline_then_baseline_folds_test() {
  let is_zero =
    func(
      "is_zero",
      [p_i32("p")],
      [ir.TI32],
      ir.Let(
        ["z"],
        ir.Num(ir.IEqz(ir.W32), [ir.Var("p")]),
        ir.Return([ir.Var("z")]),
      ),
    )
  let caller = fn(arg: Int) {
    mod_of(
      [
        func(
          "main",
          [],
          [ir.TI32],
          ir.Let(
            ["r"],
            ir.CallDirect("is_zero", [ir.ConstI32(arg)]),
            ir.Values([ir.Var("r")]),
          ),
        ),
        is_zero,
      ],
      [],
    )
  }
  assert body_of(opt_agg(caller(0)), "main") == vi32(1)
  assert body_of(opt_agg(caller(5)), "main") == vi32(0)
}

// ══════════════════════════ §7. Charge-elision + postcondition (§C) ══════════════════════════

/// Charge-elision removes a hand-inserted `Charge` and preserves the result: `Charge(5, 9)`
/// yields `9` with no `Charge` node (the Aggressive postcondition — output is `Charge`-free).
pub fn charge_elide_removes_and_preserves_value_test() {
  let m =
    mod_of(
      [func("main", [], [ir.TI32], ir.Charge(5, ir.Values([ir.ConstI32(9)])))],
      [],
    )
  assert body_of(opt_agg(m), "main") == vi32(9)
  assert contains_charge(body_of(opt_agg(m), "main")) == False
}

/// Nested `Charge`s collapse (bottom-up): `Charge(3, Charge(4, 1))` yields `1`, `Charge`-free.
pub fn charge_elide_nested_test() {
  let m =
    mod_of(
      [
        func(
          "main",
          [],
          [ir.TI32],
          ir.Charge(3, ir.Charge(4, ir.Values([ir.ConstI32(1)]))),
        ),
      ],
      [],
    )
  assert body_of(opt_agg(m), "main") == vi32(1)
  assert contains_charge(body_of(opt_agg(m), "main")) == False
}

/// Charge-elision removes the metering overlay but KEEPS the wrapped effect: `Charge(2,
/// MemStore(..))` becomes the bare `MemStore` — no value/trap of the store is lost (it is a
/// policy overlay, not a WASM semantic).
pub fn charge_elide_keeps_inner_effect_test() {
  let store =
    ir.MemStore(0, ir.MemAccess(4, False), ir.ConstI32(0), ir.ConstI32(1), 0)
  let m = mod_of([func("main", [], [], ir.Charge(2, store))], [])
  assert body_of(opt_agg(m), "main") == store
}

/// Reconciliation (§C.1): `charge_elide` is a NO-OP on an already-`Charge`-free module — a body
/// with no calls and no `Charge` optimizes IDENTICALLY at `Aggressive` and `Baseline`.
pub fn charge_elide_noop_on_charge_free_test() {
  let m =
    mod_of(
      [
        func(
          "main",
          [],
          [ir.TI32],
          ir.Num(ir.IAdd(ir.W32), [ir.ConstI32(2), ir.ConstI32(3)]),
        ),
      ],
      [],
    )
  assert opt_agg(m) == opt_base(m)
  assert body_of(opt_agg(m), "main") == vi32(5)
}

// ══════════════════════════ §8. Unsafe-only gating (F4) ══════════════════════════

/// F4: `Baseline` does NOT inline and does NOT elide `Charge`, while `Aggressive` does both. A
/// module with an inlinable call keeps its `CallDirect` at `Baseline` but not at `Aggressive`.
pub fn baseline_does_not_inline_test() {
  let main =
    func(
      "main",
      [],
      [ir.TI32],
      ir.Let(
        ["r"],
        ir.CallDirect("dbl", [ir.ConstI32(5)]),
        ir.Values([ir.Var("r")]),
      ),
    )
  let m = mod_of([main, dbl_callee()], [])
  assert has_call(body_of(opt_base(m), "main")) == True
  assert has_call(body_of(opt_agg(m), "main")) == False
}

/// F4: a LIVE `Charge` on an executed path survives `Baseline` (baseline never elides an effect)
/// but is removed at `Aggressive`.
pub fn baseline_keeps_charge_aggressive_elides_test() {
  let m =
    mod_of(
      [func("main", [], [ir.TI32], ir.Charge(5, ir.Values([ir.ConstI32(9)])))],
      [],
    )
  assert contains_charge(body_of(opt_base(m), "main")) == True
  assert contains_charge(body_of(opt_agg(m), "main")) == False
}

/// F1: `OptNone` is the exact identity even over an inlinable + `Charge`-bearing module — no
/// pass runs, so nothing is rewritten (the F2 differential baseline).
pub fn optnone_is_identity_test() {
  let main =
    func(
      "main",
      [],
      [ir.TI32],
      ir.Let(
        ["r"],
        ir.CallDirect("dbl", [ir.ConstI32(5)]),
        ir.Charge(1, ir.Values([ir.Var("r")])),
      ),
    )
  let m = mod_of([main, dbl_callee()], [])
  assert ir_opt.optimize(m, OptNone) == m
}

// ══════════════════════════ §9. end-to-end emittability of the inlined shape ══════════════════════════

/// A surviving inlined region (a non-constant arg keeps the `Block(exit, …, Break)` from fully
/// folding) is well-formed Core-Erlang-emittable IR: inlining `dbl(q)` into `main(q)` (with `q`
/// a runtime param) and emitting through the real Unsafe binding succeeds. This pins that the
/// single-exit `Let(names, Block(exit, result, …), cont)` shape lowers cleanly (IR open-question
/// #4: a block result may be bound by a `Let`).
pub fn inlined_shape_is_emittable_test() {
  let main =
    func(
      "main",
      [p_i32("q")],
      [ir.TI32],
      ir.Let(
        ["r"],
        ir.CallDirect("dbl", [ir.Var("q")]),
        ir.Return([ir.Var("r")]),
      ),
    )
  let m = mod_of([main, dbl_callee()], [ir.ExportFn("main", "main")])
  let optimized = opt_agg(m)
  // The call was inlined away…
  assert has_call(body_of(optimized, "main")) == False
  // …and the optimized module emits Core Erlang without error under the Unsafe profile.
  assert result.is_ok(emit_core.emit_module(optimized, profiles.unsafe()))
}

// ══════════════════════════ §10. pass registration ══════════════════════════

/// The Aggressive arm registers EXACTLY the two Unsafe-only passes, in order — `charge-elide`
/// then `inline` — each appearing once (pins §A order and the single-registration invariant).
pub fn aggressive_passes_are_registered_once_test() {
  assert list.map(aggressive.aggressive_passes(), pass.pass_name)
    == ["charge-elide", "inline"]
}

// ══════════════════════════ §11. graceful degradation on a large module (F8) ══════════════════════════

/// The Expr-node count of `e` (each node 1; structured forms add their sub-nodes) — a local mirror
/// of the inliner's own cost measure, for the graceful-degradation bound below.
fn expr_nodes(e: ir.Expr) -> Int {
  case e {
    ir.Let(_, rhs, body) -> 1 + expr_nodes(rhs) + expr_nodes(body)
    ir.Block(_, _, body) -> 1 + expr_nodes(body)
    ir.Loop(_, _, _, body) -> 1 + expr_nodes(body)
    ir.If(_, _, t, el) -> 1 + expr_nodes(t) + expr_nodes(el)
    ir.Switch(_, _, arms, default) ->
      list.fold(arms, 1 + expr_nodes(default), fn(acc, a) {
        acc + expr_nodes(a.body)
      })
    ir.Charge(_, body) -> 1 + expr_nodes(body)
    _ -> 1
  }
}

/// The total Expr-node count across every function body in `m`.
fn module_nodes(m: ir.Module) -> Int {
  list.fold(m.functions, 0, fn(acc, f) { acc + expr_nodes(f.body) })
}

/// The ascending list `[1, 2, …, n]` (empty for `n ≤ 0`) — a local range helper.
fn upto(n: Int) -> List(Int) {
  case n <= 0 {
    True -> []
    False -> list.append(upto(n - 1), [n])
  }
}

/// GRACEFUL DEGRADATION (F8; Phase-3 §00 F8 "the optimizer is deliberately bounded"). On a module
/// whose fully-inlined form would explode, the inliner fills up to the absolute
/// `inline_node_ceiling` and then CLEANLY STOPS — it does NOT blow up, and (because reducing
/// inlining is always sound, §B.4) it still preserves results.
///
/// The explosion driver is a depth-20 binary fan-out `blow(q) → e19 → … → e0`, where
/// `e_k(x) = e_{k-1}(x) + e_{k-1}(x)`: each `e_k` is a small (≤ `small_body_nodes`) acyclic leaf-ish
/// callee, so all are inlining-eligible, and the naive fully-inlined body is ~2²⁰ nodes. The leaf
/// combines the *param* `q` (not a constant), so the expanded tree of adds does NOT constant-fold
/// away — the expansion PERSISTS in the output, making the node-count bound meaningful. Without the
/// cap this would compound across fixpoint rounds into a compile-time explosion.
///
/// Two assertions, exactly as the robustness fix requires:
///   1. the optimized module's node count is BOUNDED by `inline_node_ceiling` (no explosion) — and
///      it did grow well past the tiny input, so the cap is what stopped it (not a lack of work);
///   2. a small embedded differential still holds: an independent probe chain
///      `probe → p2 → p1 → p0` (`p0 = 42`) still fully inlines-and-folds to `42` — the value is
///      preserved through the (bounded) inlining.
pub fn large_module_degrades_gracefully_test() {
  let depth = 20
  // e0(x) = x  (leaf identity); e_k(x) = e_{k-1}(x) + e_{k-1}(x).
  let e0 = func("e0", [p_i32("x")], [ir.TI32], ir.Return([ir.Var("x")]))
  let e_levels =
    list.map(upto(depth), fn(k) {
      let prev = "e" <> int.to_string(k - 1)
      func(
        "e" <> int.to_string(k),
        [p_i32("x")],
        [ir.TI32],
        ir.Let(
          ["a"],
          ir.CallDirect(prev, [ir.Var("x")]),
          ir.Let(
            ["b"],
            ir.CallDirect(prev, [ir.Var("x")]),
            ir.Let(
              ["s"],
              ir.Num(ir.IAdd(ir.W32), [ir.Var("a"), ir.Var("b")]),
              ir.Return([ir.Var("s")]),
            ),
          ),
        ),
      )
    })
  let blow =
    func(
      "blow",
      [p_i32("q")],
      [ir.TI32],
      ir.Let(
        ["r"],
        ir.CallDirect("e" <> int.to_string(depth), [ir.Var("q")]),
        ir.Return([ir.Var("r")]),
      ),
    )

  // Embedded probe (placed FIRST so it inlines within budget before `blow` consumes the rest):
  // probe → p2 → p1 → p0, folding to the constant 42.
  let p0 = func("p0", [], [ir.TI32], ir.Return([ir.ConstI32(42)]))
  let relay = fn(name: String, callee: String) {
    func(
      name,
      [],
      [ir.TI32],
      ir.Let(["v"], ir.CallDirect(callee, []), ir.Return([ir.Var("v")])),
    )
  }
  let probe =
    func(
      "probe",
      [],
      [ir.TI32],
      ir.Let(["v"], ir.CallDirect("p2", []), ir.Values([ir.Var("v")])),
    )

  let funcs =
    list.flatten([
      [probe, relay("p2", "p1"), relay("p1", "p0"), p0],
      [blow, e0],
      e_levels,
    ])
  let m =
    mod_of(funcs, [ir.ExportFn("blow", "blow"), ir.ExportFn("probe", "probe")])
  let optimized = opt_agg(m)

  // (1) Graceful degradation — bounded output, no explosion; and the cap genuinely engaged (the
  // module grew far beyond its tiny input rather than being left untouched).
  assert module_nodes(optimized) <= aggressive.inline_node_ceiling
  assert module_nodes(optimized) > module_nodes(m)

  // (2) Results preserved — the embedded probe still inlines-and-folds to 42.
  assert body_of(optimized, "probe") == vi32(42)
}
