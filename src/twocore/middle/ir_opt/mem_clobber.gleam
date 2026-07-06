//// `middle/ir_opt/mem_clobber` — "could this subtree perturb linear memory?" (Phase-10 N3, used by
//// cross-control-flow MemorySSA, unit 03).
////
//// The safety gate for carrying a memory fact *across* a control-flow subtree: Phase 9 reset the
//// `avail` map at every control-flow boundary; Phase 10 relaxes that only where these oracles prove
//// it safe. A leaf module: imports `ir`, `ir/effect`-free (via `mem_ssa`) only. CONSERVATIVE — both
//// answers default to `True` (any doubt ⇒ "yes, it could"), so a false "no clobber" — the only
//// unsound direction — can never arise from an unhandled shape.

import gleam/list
import twocore/ir.{type Expr}
import twocore/middle/ir_opt/mem_ssa.{type Footprint, NoAlias}

/// May EVALUATING `e` (on any path through its control flow) write bytes that ALIAS `f`, reallocate
/// memory (`MemGrow`), or call out (which could do either)? Used by cross-CF **forwarding/RLE**: an
/// `avail[f]` entry may survive an `If`/`Block`/`Switch` iff `may_clobber(child, f) == False` for
/// EVERY control-flow child (no branch could write `f`). CONSERVATIVE — `True` unless proven `False`.
///
/// - a `MemStore`/`MemStoreUnchecked` with `mem_ssa.alias(its footprint, f) != NoAlias` ⇒ `True`
///   (may overwrite `f`); a `NoAlias` store (a disjoint offset off the same base) does NOT clobber
///   `f` — the cross-CF disjoint-offset disambiguation;
/// - `MemGrow` / any call / any bulk-memory op / any SIMD store ⇒ `True`;
/// - loads, `MemSize`, globals, table ops, pure ops, and control transfers do NOT clobber `f`
///   (recurse into control-flow children; `True` if any child clobbers). Total; never panics.
pub fn may_clobber(e: Expr, f: Footprint) -> Bool {
  case e {
    // a store may clobber `f` ONLY if it aliases it (NoAlias survives — the disjoint disambiguation).
    ir.MemStore(_, _, _, _, _) | ir.MemStoreUnchecked(_, _, _, _, _) ->
      store_aliases(e, f)
    // memory reallocation / range writes / SIMD writes / calls: clobber anything.
    ir.MemGrow(_, _)
    | ir.MemFill(_, _, _, _)
    | ir.MemCopy(_, _, _, _, _)
    | ir.MemInit(_, _, _, _, _)
    | ir.SimdStore(_, _, _, _)
    | ir.SimdStoreLane(_, _, _, _, _, _)
    | ir.CallDirect(_, _)
    | ir.CallIndirect(_, _, _, _)
    | ir.CallHost(_, _, _)
    | ir.CallImport(_, _, _)
    | ir.CallClosure(_, _)
    | // Phase-13 tail calls: a tail call is a call — it may write any memory in the callee, so it
      // clobbers any footprint, exactly like `CallImport`. ──
      ir.ReturnCall(_, _)
    | ir.ReturnCallIndirect(_, _, _, _)
    | ir.ReturnCallImport(_, _, _) -> True
    // sequencing / structured control: clobbers iff any sub-expression clobbers.
    ir.Let(_, rhs, body) -> may_clobber(rhs, f) || may_clobber(body, f)
    ir.Charge(_, body) -> may_clobber(body, f)
    ir.Block(_, _, body) -> may_clobber(body, f)
    ir.Loop(_, _, _, body) -> may_clobber(body, f)
    ir.If(_, _, then_branch, else_branch) ->
      may_clobber(then_branch, f) || may_clobber(else_branch, f)
    ir.Switch(_, _, arms, default) ->
      may_clobber(default, f)
      || list.any(arms, fn(a) { may_clobber(a.body, f) })
    ir.Try(_, body, handlers) ->
      may_clobber(body, f)
      || list.any(handlers, fn(h) { may_clobber(h.handler, f) })
    // everything else (loads, MemSize, globals, table/ref ops, pure ops, control transfers, traps)
    // writes no linear memory that could alias `f`.
    _ -> False
  }
}

/// May evaluating `e` write ANY linear memory, grow, call out, OR transfer control non-locally? The
/// coarser, stricter gate cross-CF **DSE** look-through uses — it may look *through* a control-flow
/// region to a shadowing store only when this is `False`, which guarantees the region neither writes
/// memory nor can exit before the shadowing store. `True` unless proven `False`. Total.
pub fn may_write_memory(e: Expr) -> Bool {
  case e {
    ir.MemStore(_, _, _, _, _)
    | ir.MemStoreUnchecked(_, _, _, _, _)
    | ir.MemGrow(_, _)
    | ir.MemFill(_, _, _, _)
    | ir.MemCopy(_, _, _, _, _)
    | ir.MemInit(_, _, _, _, _)
    | ir.SimdStore(_, _, _, _)
    | ir.SimdStoreLane(_, _, _, _, _, _)
    | ir.CallDirect(_, _)
    | ir.CallIndirect(_, _, _, _)
    | ir.CallHost(_, _, _)
    | ir.CallImport(_, _, _)
    | ir.CallClosure(_, _)
    | // Phase-13 tail calls: a tail call both may write any memory (a call) AND transfers control
      // non-locally out of the region (a bottom transfer, like `Return`) — a DSE look-through must
      // stop here on both counts. ──
      ir.ReturnCall(_, _)
    | ir.ReturnCallIndirect(_, _, _, _)
    | ir.ReturnCallImport(_, _, _)
    | // a non-local control transfer could exit before a later store, so a DSE look-through must
      // stop here (a store BEFORE such a transfer might be the last write on that path).
      ir.Break(_, _)
    | ir.Continue(_, _)
    | ir.Return(_)
    | ir.Throw(_, _)
    | ir.ThrowRef(_)
    | ir.Trap(_) -> True
    ir.Let(_, rhs, body) -> may_write_memory(rhs) || may_write_memory(body)
    ir.Charge(_, body) -> may_write_memory(body)
    ir.Block(_, _, body) -> may_write_memory(body)
    ir.Loop(_, _, _, body) -> may_write_memory(body)
    ir.If(_, _, then_branch, else_branch) ->
      may_write_memory(then_branch) || may_write_memory(else_branch)
    ir.Switch(_, _, arms, default) ->
      may_write_memory(default)
      || list.any(arms, fn(a) { may_write_memory(a.body) })
    ir.Try(_, body, handlers) ->
      may_write_memory(body)
      || list.any(handlers, fn(h) { may_write_memory(h.handler) })
    _ -> False
  }
}

/// Does the store node `store` write a footprint that aliases `f` (`!= NoAlias`)? A `MemStore`/
/// `MemStoreUnchecked` always has a footprint (`footprint_of` is `Ok`); a `NoAlias` write does not
/// clobber `f`. Conservatively `True` on the impossible `Error` case.
fn store_aliases(store: Expr, f: Footprint) -> Bool {
  case mem_ssa.footprint_of(store) {
    Ok(g) -> mem_ssa.alias(g, f) != NoAlias
    Error(Nil) -> True
  }
}
