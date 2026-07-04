//// `middle/ir_opt/mem_dse` — dead-store elimination (Phase-9 unit 03, the paged-tier headline).
////
//// A `pass.per_function` **look-ahead peephole**: for a store `store(F1, v1)` followed — in the
//// **same straight-line region**, with **only pure nodes between** — by a `MustAlias` later store
//// `store(F2, v2)`, the first store is **dead** (its write to `F1` is fully overwritten with
//// nothing observing it in between) and is removed. It only ever *removes* a `MemStore`; it never
//// adds, reorders, or moves an effect (D3a/M4).
////
//// ## Soundness (M3 — trap AND state preservation)
////
//// The shadowing store bounds-checks the **same address** as `store1` (`MustAlias` ⟹ same
//// `mem`/`addr`/`offset`/`bytes`), so:
//// - **trap-preserving:** if the address is out of bounds, the original traps `MemoryOutOfBounds`
////   at `store1` and the optimized traps `MemoryOutOfBounds` at `store2` — the *same* `TrapReason`;
//// - **state-preserving:** if in-bounds, `store2` overwrites everything `store1` wrote and the
////   final memory at `F1` is `v2` either way.
//// The **only pure nodes between** restriction is load-bearing: an intervening *effectful* op would
//// execute in the optimized program (after `store1` is removed) even on a path where the original
//// trapped at `store1` first — an observable divergence. Requiring the between-nodes to be
//// `ir/effect.is_pure` (deep) rules this out: a load, a store, a `MemGrow` (the only thing that can
//// *change* an address's in-bounds status), a call, or any control transfer is `Effectful` and
//// STOPS the peel. So DSE needs only `footprint_of`/`alias` from the keystone — the whole barrier
//// set is subsumed by `is_pure` here.
////
//// ## The paged-tier win (design-note invariant #3)
////
//// On the `paged` memory tier a `MemStore` is an O(page) immutable-binary **rebuild**; removing a
//// redundant store elides an entire rebuild, so DSE disproportionately closes the gap on the slow
//// runs-anywhere/`paged`/`portable` build (forwarding/RLE help every tier). Because `ir_opt` runs
//// upstream of tier selection (M2), the SAME pass delivers this without any per-tier code.
////
//// Imports `{ir, ir/effect, pass, mem_ssa, list}` — all acyclic (none imports `ir_opt`).

import gleam/list
import twocore/ir.{type Expr}
import twocore/ir/effect
import twocore/middle/ir_opt/mem_ssa.{type Footprint, MustAlias}
import twocore/middle/ir_opt/pass.{type Pass}

/// The dead-store-elimination pass (M3 lever #3). Removes a store fully shadowed by a `MustAlias`
/// later store with only pure nodes between. Trap- AND state-preserving (§module docs). Registered
/// by unit 04 into the `Baseline` arm (inherited by `Aggressive`). Total; never panics; only ever
/// removes `MemStore` nodes.
///
/// - Return: the `Pass` value. Semantics-preserving (F2/M3). Total — never fails.
pub fn dead_store_pass() -> Pass {
  pass.per_function("mem-dse", fn(f) {
    ir.Function(..f, body: dse_region(f.body))
  })
}

/// Rewrite one straight-line region front-to-back. At a lowered store (`Let([], MemStore, rest)`)
/// drop it iff it is `is_dead`; everywhere else recurse, treating each control-flow sub-expression
/// as a **fresh** region (the look-ahead resets at every boundary — DSE is per straight-line
/// region, M8). Total.
fn dse_region(e: Expr) -> Expr {
  case e {
    // A lowered store: `Let([], MemStore(..), rest)` — empty names, so its "result" is unused by
    // construction (nothing downstream can depend on a store's value; §emit_store).
    ir.Let([], ir.MemStore(_, _, _, _, _) as store, rest) ->
      case is_dead(store, rest) {
        // store1 is dead — drop it, keep the (recursively-DSE'd) tail.
        True -> dse_region(rest)
        False -> ir.Let([], store, dse_region(rest))
      }
    // Any other Let: recurse into the rhs (its own region) and the tail (a fresh head).
    ir.Let(names, rhs, body) -> ir.Let(names, dse_region(rhs), dse_region(body))
    // ── control-flow boundaries: each sub-expression is a FRESH straight-line region ──
    ir.If(cond, result, then_branch, else_branch) ->
      ir.If(cond, result, dse_region(then_branch), dse_region(else_branch))
    ir.Block(label, result, body) -> ir.Block(label, result, dse_region(body))
    ir.Loop(label, params, result, body) ->
      ir.Loop(label, params, result, dse_region(body))
    ir.Switch(selector, result, arms, default) ->
      ir.Switch(selector, result, dse_arms(arms), dse_region(default))
    ir.Try(result, body, handlers) ->
      ir.Try(result, dse_region(body), dse_handlers(handlers))
    ir.Charge(cost, body) -> ir.Charge(cost, dse_region(body))
    // leaves carry no sub-`Expr` — return unchanged.
    _ -> e
  }
}

/// Is `store` (a `MemStore`, footprint `f1`) fully shadowed further down `rest`? Peel leading PURE
/// `Let` frames; at the first non-pure node, `store` is dead iff that node is a `MustAlias`
/// `MemStore`.
fn is_dead(store: Expr, rest: Expr) -> Bool {
  case mem_ssa.footprint_of(store) {
    Error(Nil) -> False
    Ok(f1) -> shadowed(f1, rest)
  }
}

/// Peel pure computation between the two stores; test the first non-pure node. `store1` (footprint
/// `f1`) is dead iff the first non-pure node reached is a `MustAlias` `MemStore`.
fn shadowed(f1: Footprint, rest: Expr) -> Bool {
  case rest {
    ir.Let(_, rhs, inner) ->
      case effect.is_pure(rhs) {
        // Pure between the two stores is harmless — it cannot observe memory, trap, transfer
        // control, or change bounds — so keep peeling. (`is_pure` is DEEP: a Let whose rhs hides a
        // MemLoad/MemStore/call/grow is NOT pure, so an intervening load or barrier stops here.)
        True -> shadowed(f1, inner)
        // The FIRST non-pure node. `store1` is dead ONLY if it is a MustAlias later store.
        False ->
          case rhs {
            ir.MemStore(_, _, _, _, _) as store2 ->
              case mem_ssa.footprint_of(store2) {
                Ok(f2) -> mem_ssa.alias(f1, f2) == MustAlias
                Error(Nil) -> False
              }
            // a load, a barrier (grow/call/bulk), a trapping op, or a control transfer → KEEP.
            _ -> False
          }
      }
    // `rest` is not a Let-chain head (a bare value / control transfer) → nothing shadows → KEEP.
    _ -> False
  }
}

/// Map `dse_region` over each `SwitchArm.body`, preserving arm order and `match`.
fn dse_arms(arms: List(ir.SwitchArm)) -> List(ir.SwitchArm) {
  list.map(arms, fn(a) { ir.SwitchArm(..a, body: dse_region(a.body)) })
}

/// Map `dse_region` over each `CatchHandler.handler`, preserving handler order/tag/payload.
fn dse_handlers(handlers: List(ir.CatchHandler)) -> List(ir.CatchHandler) {
  list.map(handlers, fn(h) {
    ir.CatchHandler(..h, handler: dse_region(h.handler))
  })
}
