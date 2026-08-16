//// `middle/ir_opt/licm` — loop-invariant code motion (Phase-10 unit 02, N2).
////
//// Hoists a **pure, loop-invariant** `Let` binding out of a `Loop` body to a synthesized
//// **preheader** (`Let(name, invariant_rhs, Loop(…))`), so it is evaluated once instead of every
//// iteration. Pure IR→IR: no new IR node, no runtime touch, trust-neutral, all tiers / both modes.
////
//// ## Soundness (N2)
////
//// A binding is hoisted ONLY when `loop_analysis.is_loop_invariant(rhs, bound_in_loop)` — i.e. `rhs`
//// is `ir/effect.is_pure` AND references no name bound inside the loop. Two facts make hoisting
//// exact:
//// - **same value:** a loop-invariant `rhs` references only loop-external (and already-hoisted)
////   names, which are immutable in ANF (Phase-3 §C), so it computes the same value every iteration —
////   evaluating it once before the loop is value-exact.
//// - **speculation- and zero-trip-safe:** `rhs` is PURE — it has no effect to reorder and cannot
////   trap or diverge — so evaluating it before the loop (even when the loop runs zero times, or when
////   it originally sat inside a conditionally-taken branch that this iteration would skip) changes
////   nothing observable. This is exactly why LICM may pull a pure invariant binding out of an `If`
////   branch to the unconditional preheader (a guarded *trapping* op is not pure, so it is never
////   hoisted out of its guard).
////
//// ## What it descends into
////
//// The extraction walks the loop body's `Let`-chain AND descends into `If`/`Switch`/`Block`/`Charge`
//// — because WASM-lowered loops put the real invariant work *inside* the condition-guarded branch,
//// not in the leading chain. It treats a NESTED `Loop` (already LICM'd bottom-up) and a `Try` as
//// OPAQUE (does not hoist across them — the safe, simple boundary). The "moving frontier": once a
//// binding is hoisted, its name becomes loop-external, so a later binding depending on it also
//// hoists (dependency order is preserved in the preheader).
////
//// Imports `{ir, ir/effect-free via loop_analysis, pass, loop_analysis, gleam/set, gleam/list}`.

import carder/ir.{type Expr}
import carder/middle/ir_opt/loop_analysis
import carder/middle/ir_opt/pass.{type Pass}
import gleam/list
import gleam/set.{type Set}

/// The loop-invariant-code-motion pass (N2). A `pass.per_function` bottom-up walk that, at each
/// `Loop`, hoists every pure loop-invariant `Let` binding to a preheader. Semantics-preserving
/// (§module docs). Registered by unit 07 into the `Baseline` arm (inherited by `Aggressive`).
/// Total; never panics.
pub fn licm_pass() -> Pass {
  pass.per_function("licm", fn(f) { ir.Function(..f, body: licm_expr(f.body)) })
}

/// Bottom-up walk: optimize sub-expressions first (so a nested loop is LICM'd before its enclosing
/// one), then hoist at a `Loop`.
fn licm_expr(e: Expr) -> Expr {
  case e {
    ir.Loop(label, params, result, body) ->
      hoist_loop(label, params, result, licm_expr(body))
    ir.Let(names, rhs, body) -> ir.Let(names, licm_expr(rhs), licm_expr(body))
    ir.Block(label, result, body) -> ir.Block(label, result, licm_expr(body))
    ir.If(cond, result, then_branch, else_branch) ->
      ir.If(cond, result, licm_expr(then_branch), licm_expr(else_branch))
    ir.Switch(selector, result, arms, default) ->
      ir.Switch(
        selector,
        result,
        list.map(arms, fn(a) { ir.SwitchArm(..a, body: licm_expr(a.body)) }),
        licm_expr(default),
      )
    ir.Charge(cost, body) -> ir.Charge(cost, licm_expr(body))
    ir.Try(result, body, handlers) ->
      ir.Try(
        result,
        licm_expr(body),
        list.map(handlers, fn(h) {
          ir.CatchHandler(..h, handler: licm_expr(h.handler))
        }),
      )
    // leaves — no sub-`Expr`.
    _ -> e
  }
}

/// Hoist every pure loop-invariant `Let` in `body` to a preheader wrapping the loop.
fn hoist_loop(
  label: String,
  params: List(ir.LoopParam),
  result: List(ir.ValType),
  body: Expr,
) -> Expr {
  let bound = loop_analysis.bound_names(params, body)
  let #(hoisted, new_body) = extract(body, bound, set.new())
  // wrap the loop in the hoisted bindings, first-collected outermost (dependency order preserved).
  list.fold_right(hoisted, ir.Loop(label, params, result, new_body), fn(acc, h) {
    let #(name, rhs) = h
    ir.Let([name], rhs, acc)
  })
}

/// Pull every pure loop-invariant single-name `Let` binding out of `e`, returning the list of
/// hoisted `#(name, rhs)` bindings (in evaluation order) and `e` with them removed. `bound` is the
/// loop's bound-name set; `hoisted_set` is the set already pulled out (so a binding depending only
/// on loop-external + already-hoisted names is itself invariant — the moving frontier). Descends
/// into `Let`/`If`/`Switch`/`Block`/`Charge`; treats a nested `Loop`/`Try` and every leaf as opaque.
fn extract(
  e: Expr,
  bound: Set(String),
  hoisted_set: Set(String),
) -> #(List(#(String, Expr)), Expr) {
  case e {
    ir.Let([name], rhs, inner) -> {
      let effective_bound = set.difference(bound, hoisted_set)
      case loop_analysis.is_loop_invariant(rhs, effective_bound) {
        True -> {
          // hoist this binding; its name joins the frontier for the rest.
          let #(deeper, inner2) =
            extract(inner, bound, set.insert(hoisted_set, name))
          #([#(name, rhs), ..deeper], inner2)
        }
        False -> {
          let #(deeper, inner2) = extract(inner, bound, hoisted_set)
          #(deeper, ir.Let([name], rhs, inner2))
        }
      }
    }
    // multi-name (or zero-name) binding: never hoisted (a value-projection / effect); recurse the
    // continuation, keeping the binding in place.
    ir.Let(names, rhs, inner) -> {
      let #(deeper, inner2) = extract(inner, bound, hoisted_set)
      #(deeper, ir.Let(names, rhs, inner2))
    }
    ir.Charge(cost, inner) -> {
      let #(deeper, inner2) = extract(inner, bound, hoisted_set)
      #(deeper, ir.Charge(cost, inner2))
    }
    ir.Block(label, result, inner) -> {
      let #(deeper, inner2) = extract(inner, bound, hoisted_set)
      #(deeper, ir.Block(label, result, inner2))
    }
    ir.If(cond, result, then_branch, else_branch) -> {
      // both branches contribute to the preheader; they are parallel, so their hoisted bindings are
      // independent (D6 unique names) and use the SAME frontier.
      let #(ht, t2) = extract(then_branch, bound, hoisted_set)
      let #(he, e2) = extract(else_branch, bound, hoisted_set)
      #(list.append(ht, he), ir.If(cond, result, t2, e2))
    }
    ir.Switch(selector, result, arms, default) -> {
      let #(hd, def2) = extract(default, bound, hoisted_set)
      let #(harms, arms2) =
        list.fold(arms, #([], []), fn(acc, a) {
          let #(hs, out_arms) = acc
          let #(ha, body2) = extract(a.body, bound, hoisted_set)
          #(list.append(hs, ha), [ir.SwitchArm(..a, body: body2), ..out_arms])
        })
      #(
        list.append(hd, harms),
        ir.Switch(selector, result, list.reverse(arms2), def2),
      )
    }
    // opaque: a nested loop is already LICM'd; a `Try` region and every leaf are not descended into.
    _ -> #([], e)
  }
}
