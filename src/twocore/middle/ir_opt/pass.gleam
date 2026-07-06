//// `middle/ir_opt/pass` — the optimizer `Pass` type, its combinators, and the fixpoint
//// driver (`run_pipeline`) — the shared machinery every optimizer pass is built from (F1).
////
//// ## Why this is a leaf module (the import-cycle fix)
////
//// This module imports `twocore/ir` **ONLY**. Hosting the `Pass` type and its combinators
//// here — *below* `ir_opt` in the import DAG — lets `ir_opt` (the entry point), `baseline`
//// (unit 03), and `aggressive` (unit 04) **all** import it without forming a cycle: a pass
//// author needs the `pass`/`per_function`/`per_expr`/`map_expr` constructors, `ir_opt` needs
//// `Pass`/`run_pipeline`, and none of the three imports the others. The import chain stays
//// `pass → ir`; `ir_opt → {ir, pass}`; `{baseline, aggressive} → {ir, pass, ir/effect}`.
////
//// ## The soundness contract this machinery upholds (F2/F3, E6)
////
//// A `Pass` is a **pure function on the IR** — a semantics-preserving IR→IR rewrite. The
//// shared traversal `map_expr` is deliberately **effect-agnostic**: it never drops, reorders,
//// or duplicates a node; it only rebuilds the tree with `rewrite` applied bottom-up. A pass
//// that wants to elide/CSE/reorder an *effect* must gate that decision on `ir/effect`
//// (unit 02) — this module gives it faithful, complete coverage of every `Expr`, and nothing
//// more. At the freeze there are no registered passes, so this machinery is only exercised as
//// the identity; units 03/04 register the real passes.

import gleam/list
import twocore/ir.{type Expr, type Function, type Module}

/// The safety valve bounding the fixpoint driver. A full round that leaves the module
/// unchanged (`==`) is the real termination condition — the baseline passes are
/// size-reducing over a well-founded measure (fold/DCE/prop), so they converge — and this
/// bound only caps a pathological non-convergent registration. At the freeze (empty
/// pipeline) convergence is reached in round 0, well within the bound.
const max_rounds: Int = 16

/// One optimizer pass: a **named** IR→IR rewrite (F1). Opaque so its invariant — a pass is a
/// *pure function on the IR* (F2) — cannot be bypassed by constructing one another way, and so
/// per-pass differential tests bind to `pass_name` rather than the internal shape.
pub opaque type Pass {
  Pass(name: String, run: fn(Module) -> Module)
}

/// Build a whole-module pass from a `name` and its `run` transform.
///
/// - `name`: the pass's registered name (used for pipeline logging and per-pass tests).
/// - `run`: the IR→IR rewrite the pass performs; it must be semantics-preserving (F2).
/// - Return: the `Pass` value. Total — never fails.
pub fn pass(name: String, run: fn(Module) -> Module) -> Pass {
  Pass(name: name, run: run)
}

/// The pass's registered name — for pipeline logging and per-pass differential tests.
///
/// - `p`: the pass to inspect.
/// - Return: the `name` `p` was built with. Total — never fails.
pub fn pass_name(p: Pass) -> String {
  p.name
}

/// Lift a **per-function** rewrite to a whole-module `Pass`: it maps `rewrite` over every
/// function in `module.functions`, leaving the rest of the module untouched.
///
/// - `name`: the pass's registered name.
/// - `rewrite`: the per-function IR→IR transform; must be semantics-preserving (F2).
/// - Return: a `Pass` applying `rewrite` to each `Function`. Total — never fails.
pub fn per_function(name: String, rewrite: fn(Function) -> Function) -> Pass {
  pass(name, fn(module) {
    ir.Module(..module, functions: list.map(module.functions, rewrite))
  })
}

/// Lift a **per-node** rewrite to a `Pass`: it applies `rewrite` **bottom-up** to every
/// `Expr` in every function body via `map_expr`. The author decides *legality* (whether a
/// given rewrite is sound at that node, via `ir/effect`); the traversal only guarantees
/// complete, faithful coverage of the tree.
///
/// - `name`: the pass's registered name.
/// - `rewrite`: the per-`Expr` transform, applied to each already-rewritten sub-tree then to
///   the node itself (see `map_expr`). Must be semantics-preserving (F2).
/// - Return: a `Pass` applying `rewrite` bottom-up across every function body. Total.
pub fn per_expr(name: String, rewrite: fn(Expr) -> Expr) -> Pass {
  per_function(name, fn(f) { ir.Function(..f, body: map_expr(f.body, rewrite)) })
}

/// The shared **bottom-up** traversal combinator: rebuild `e` with `rewrite` applied to each
/// already-rewritten sub-expression, then apply `rewrite` to the reconstructed node itself.
///
/// - `e`: the expression to traverse.
/// - `rewrite`: applied once to every node, after its children have been rewritten.
/// - Return: the rewritten expression. Total.
///
/// **Effect-agnostic (F3, E6).** It never drops, reorders, or duplicates a node — it only
/// rebuilds the same shape with rewritten children. A pass that elides/CSEs/reorders an effect
/// must gate that on `ir/effect`; this combinator gives it coverage, not permission.
///
/// **Exhaustiveness is load-bearing.** Every `Expr` variant is matched explicitly (no
/// wildcard): the 17 leaf forms return unchanged (they carry no sub-`Expr`), and the six
/// structured-control / sequencing forms (`Let`, `Block`, `Loop`, `If`, `Switch`, `Charge`)
/// recurse into each of their sub-expressions. A future `Expr` variant therefore forces a
/// compile error here — a missed variant would be a silently-unoptimized (never *unsound*)
/// subtree, which this full match prevents.
pub fn map_expr(e: Expr, rewrite: fn(Expr) -> Expr) -> Expr {
  let rebuilt = case e {
    // leaves — carry no sub-`Expr`; returned unchanged (then rewritten as the node itself).
    ir.Values(_)
    | ir.Num(..)
    | ir.Convert(..)
    | ir.TermOp(..)
    | ir.MemSize(..)
    | ir.MemGrow(..)
    | ir.MemLoad(..)
    | ir.MemStore(..)
    | // Phase-10 unchecked accesses (N4) carry only `Value` operands (no sub-`Expr`), so like the
      // checked memory leaves they return unchanged from this traversal.
      ir.MemLoadUnchecked(..)
    | ir.MemStoreUnchecked(..)
    | ir.GlobalGet(..)
    | ir.GlobalSet(..)
    | ir.CallDirect(..)
    | ir.CallIndirect(..)
    | ir.CallHost(..)
    | ir.Break(..)
    | ir.Continue(..)
    | ir.Return(..)
    | ir.Trap(..)
    | // Phase-5 reference/table/bulk nodes carry only `Value` operands (no sub-`Expr`), so like
      // the memory leaves they return unchanged from this `Expr`-traversal combinator. They are
      // barriers (`ir/effect`), so no pass hoists across them; a pass that rewrites their `Value`
      // operands does so in its own per-node arm, not here.
      ir.RefFunc(..)
    | ir.RefIsNull(..)
    | ir.TableGet(..)
    | ir.TableSet(..)
    | ir.TableSize(..)
    | ir.TableGrow(..)
    | ir.TableFill(..)
    | ir.TableInit(..)
    | ir.TableCopy(..)
    | ir.ElemDrop(..)
    | ir.MemFill(..)
    | ir.MemCopy(..)
    | ir.MemInit(..)
    | ir.DataDrop(..)
    | // Phase-6 SIMD nodes + `CallImport` carry only `Value` operands (no sub-`Expr`), so like
      // the memory leaves they return unchanged from this `Expr`-traversal combinator. The pure
      // `Simd`/`SimdShuffle` participate in const-fold/DCE (§effect); a pass that rewrites their
      // `Value` operands does so in its own per-node arm, not here.
      ir.Simd(..)
    | ir.SimdShuffle(..)
    | ir.SimdLoad(..)
    | ir.SimdStore(..)
    | ir.SimdLoadLane(..)
    | ir.SimdStoreLane(..)
    | ir.CallImport(..)
    | // Phase-13 tail-call nodes carry only `Value` operands (no sub-`Expr`), so like the leaves
      // they return unchanged from this `Expr`-traversal combinator. They are barriers
      // (`ir/effect`), so no pass hoists across them; a pass that rewrites their `Value` operands
      // does so in its own per-node arm, not here.
      ir.ReturnCall(..)
    | ir.ReturnCallIndirect(..)
    | ir.ReturnCallImport(..)
    | // Phase-7 `Throw`/`ThrowRef` carry only `Value` operands (no sub-`Expr`), so like the leaves
      // they return unchanged. They are barriers (`ir/effect`), so no pass hoists across them.
      ir.Throw(..)
    | ir.ThrowRef(..)
    | // Phase-8 native closures carry only `Value` operands (no sub-`Expr`), so like the leaves
      // they return unchanged from this `Expr`-traversal combinator. `CallClosure` is a barrier
      // (`ir/effect`), so no pass hoists across it; `MakeClosure` is pure. A pass that rewrites
      // their `Value` operands does so in its own per-node arm, not here.
      ir.MakeClosure(..)
    | ir.CallClosure(..)
    | // Phase-8 map layer (unit 03) carries only `Value` operands (no sub-`Expr`), so like the
      // leaves it returns unchanged from this `Expr`-traversal combinator. It is pure (`ir/effect`);
      // a pass that rewrites its `Value` operands does so in its own per-node arm, not here.
      ir.MapOp(..)
    | // Phase-8 term classification + native number arithmetic (unit 06) carry only `Value`
      // operands (no sub-`Expr`), so like the leaves they return unchanged here. `TermTest`/`TermTag`
      // are pure; `NumTerm` is a barrier (`ir/effect`), so no pass hoists across it. A pass that
      // rewrites their `Value` operands does so in its own per-node arm, not here.
      ir.TermTest(..)
    | ir.TermTag(..)
    | ir.NumTerm(..) -> e
    // structured-control / sequencing — recurse into each sub-`Expr`, preserving shape.
    // Phase-7 `Try` recurses into its `body` and each handler's inline `handler` expression
    // (both are sub-`Expr`s), so a traversal reaches an EH region's interior. The node itself is
    // a barrier (`ir/effect`), so no pass hoists across it.
    ir.Try(result, body, handlers) ->
      ir.Try(
        result,
        map_expr(body, rewrite),
        map_catch_handlers(handlers, rewrite),
      )
    ir.Let(names, rhs, body) ->
      ir.Let(names, map_expr(rhs, rewrite), map_expr(body, rewrite))
    ir.Block(label, result, body) ->
      ir.Block(label, result, map_expr(body, rewrite))
    ir.Loop(label, params, result, body) ->
      ir.Loop(label, params, result, map_expr(body, rewrite))
    ir.If(cond, result, then_branch, else_branch) ->
      ir.If(
        cond,
        result,
        map_expr(then_branch, rewrite),
        map_expr(else_branch, rewrite),
      )
    ir.Switch(selector, result, arms, default) ->
      ir.Switch(
        selector,
        result,
        map_switch_arms(arms, rewrite),
        map_expr(default, rewrite),
      )
    ir.Charge(cost, body) -> ir.Charge(cost, map_expr(body, rewrite))
  }
  rewrite(rebuilt)
}

/// Run `passes` in order to a **fixpoint**: repeat the whole ordered list until a full round
/// leaves `module` structurally unchanged (`==`, cheap because the IR is plain data) or the
/// documented `max_rounds` safety bound is reached.
///
/// - `module`: the IR module to optimize.
/// - `passes`: the ordered pass list (from `ir_opt.pipeline/1`).
/// - Return: the module after the pipeline has reached a fixpoint. Total.
///
/// Convergence rests on the baseline passes being size-reducing over a well-founded measure;
/// `max_rounds` is a valve, not the termination argument. FREEZE: an empty `passes` list is a
/// fixpoint immediately, so this returns `module` unchanged in round 0.
pub fn run_pipeline(module: Module, passes: List(Pass)) -> Module {
  run_to_fixpoint(module, passes, max_rounds)
}

// ───────────────────────────── internal helpers ─────────────────────────────

/// Map `map_expr(_, rewrite)` over each `SwitchArm.body`, preserving arm order and `match`.
fn map_switch_arms(
  arms: List(ir.SwitchArm),
  rewrite: fn(Expr) -> Expr,
) -> List(ir.SwitchArm) {
  list.map(arms, fn(arm) {
    ir.SwitchArm(..arm, body: map_expr(arm.body, rewrite))
  })
}

/// Map `map_expr(_, rewrite)` over each `CatchHandler.handler` of a `Try` region, preserving the
/// handler order, its `on` tag, `payload` names, and `exnref` capture (Phase-7, T1).
fn map_catch_handlers(
  handlers: List(ir.CatchHandler),
  rewrite: fn(Expr) -> Expr,
) -> List(ir.CatchHandler) {
  list.map(handlers, fn(h) {
    ir.CatchHandler(..h, handler: map_expr(h.handler, rewrite))
  })
}

/// Run the ordered `passes` once, folding each pass's `run` over `module` left to right.
fn run_once(module: Module, passes: List(Pass)) -> Module {
  list.fold(passes, module, fn(m, p) { p.run(m) })
}

/// Repeat `run_once` until a round is a no-op (`==`) or `rounds_left` hits zero.
fn run_to_fixpoint(
  module: Module,
  passes: List(Pass),
  rounds_left: Int,
) -> Module {
  case rounds_left <= 0 {
    True -> module
    False -> {
      let next = run_once(module, passes)
      case next == module {
        True -> module
        False -> run_to_fixpoint(next, passes, rounds_left - 1)
      }
    }
  }
}
