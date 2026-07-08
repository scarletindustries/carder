//// `middle/ir_opt/loop_analysis` — shared loop-invariance primitives (Phase-10 N2, used by LICM
//// (unit 02) and range-BCE (unit 06)).
////
//// A leaf module: imports `ir` and `ir/effect` only. Provides the vocabulary the loop
//// optimizations rest on — the variables an expression references, and the test for whether an
//// expression is **loop-invariant** (pure AND referencing no name bound inside the loop). It
//// performs no rewrite.
////
//// ## `free_vars` is a sound over-approximation (and exact for the invariance test)
////
//// `free_vars(e)` returns **every `Var` name that occurs in `e`** — including names bound by an
//// inner `Let`/`Loop` *within* `e`. That is a sound OVER-approximation of the true free-variable
//// set. It is exactly what the invariance test needs: under the D6 unique-naming invariant (every
//// `Let`/param/loop name is unique within a function), an inner binder of `e` is a **fresh** name
//// that can never equal a loop's own bound name, so `free_vars(e)` intersected with the loop's
//// `bound_in_loop` set yields precisely "does `e` reference a name bound inside the loop?" — the
//// invariance question — with no false positive.

import gleam/list
import gleam/option
import gleam/set.{type Set}
import twocore/ir.{type Expr, type LoopParam, type Value}
import twocore/ir/effect

/// The `Var` names in a flat operand list `values` — the leaf of `free_vars`. Total.
pub fn value_vars(values: List(Value)) -> Set(String) {
  list.fold(values, set.new(), fn(acc, v) { add_value(acc, v) })
}

/// Every `Var` name occurring in `e` (a sound over-approximation of the free variables — see the
/// module docs). Exhaustive over `Expr` (a new variant fails to compile until it is handled).
/// Total; never panics.
pub fn free_vars(e: Expr) -> Set(String) {
  vars_in(set.new(), e)
}

/// Is `e` **loop-invariant** with respect to a loop whose body binds the names `bound_in_loop` (its
/// params + every name a `Let`/`Loop`/handler inside the body binds — see `bound_names`)? `True`
/// iff `e` is `ir/effect.is_pure` AND `free_vars(e)` is disjoint from `bound_in_loop`. So a
/// loop-invariant expression has no effect to reorder (pure) and computes the same value every
/// iteration (references only loop-external names). CONSERVATIVE: any impurity or any free variable
/// bound in the loop ⇒ `False` (not invariant — the safe direction). Total.
pub fn is_loop_invariant(e: Expr, bound_in_loop: Set(String)) -> Bool {
  effect.is_pure(e) && disjoint(free_vars(e), bound_in_loop)
}

/// The set of names BOUND inside a loop: the loop's own `loop_params` UNION every name bound by a
/// `Let`/`Loop`/`Try`-handler reachable in `body`. This is the `bound_in_loop` argument to
/// `is_loop_invariant`. Total.
pub fn bound_names(loop_params: List(LoopParam), body: Expr) -> Set(String) {
  let seed =
    list.fold(loop_params, set.new(), fn(acc, p) { set.insert(acc, p.name) })
  binders_in(seed, body)
}

// ───────────────────────────── internals ─────────────────────────────

fn add_value(acc: Set(String), v: Value) -> Set(String) {
  case v {
    ir.Var(n) -> set.insert(acc, n)
    _ -> acc
  }
}

fn union_values(acc: Set(String), vs: List(Value)) -> Set(String) {
  list.fold(vs, acc, add_value)
}

fn disjoint(a: Set(String), b: Set(String)) -> Bool {
  set.is_empty(set.intersection(a, b))
}

/// Accumulate every `Var` occurrence of `e` into `acc`. Exhaustive over `Expr`.
fn vars_in(acc: Set(String), e: Expr) -> Set(String) {
  case e {
    // pure / numeric / term leaves (operands only)
    ir.Values(vs) -> union_values(acc, vs)
    ir.Num(_, args) -> union_values(acc, args)
    ir.Convert(_, arg) -> add_value(acc, arg)
    ir.TermOp(_, args) -> union_values(acc, args)
    ir.MakeClosure(_, captures, _) -> union_values(acc, captures)
    ir.MapOp(_, args) -> union_values(acc, args)
    ir.TermTest(_, arg) -> add_value(acc, arg)
    ir.TermTag(arg) -> add_value(acc, arg)
    ir.NumTerm(_, lhs, rhs) -> add_value(add_value(acc, lhs), rhs)
    ir.Simd(_, args) -> union_values(acc, args)
    ir.Gc(_, args) -> union_values(acc, args)
    ir.SimdShuffle(_, a, b) -> add_value(add_value(acc, a), b)
    // reference / table layer
    ir.RefFunc(_) -> acc
    // Phase-14 `RefFuncImport` (R1): a slot + type only — contributes no loop-variant operand.
    ir.RefFuncImport(_, _) -> acc
    ir.RefIsNull(arg) -> add_value(acc, arg)
    ir.TableGet(_, index) -> add_value(acc, index)
    ir.TableSet(_, index, value) -> add_value(add_value(acc, index), value)
    ir.TableSize(_) -> acc
    ir.TableGrow(_, delta, init) -> add_value(add_value(acc, delta), init)
    ir.TableFill(_, offset, value, count) ->
      union_values(acc, [offset, value, count])
    ir.TableInit(_, _, dst, src, count) -> union_values(acc, [dst, src, count])
    ir.TableCopy(_, _, dst, src, count) -> union_values(acc, [dst, src, count])
    ir.ElemDrop(_) -> acc
    // linear-memory layer (checked + unchecked + bulk)
    ir.MemSize(_) -> acc
    ir.MemGrow(_, delta) -> add_value(acc, delta)
    ir.MemLoad(_, _, addr, _, _) -> add_value(acc, addr)
    ir.MemStore(_, _, addr, value, _) -> add_value(add_value(acc, addr), value)
    ir.MemLoadUnchecked(_, _, addr, _, _) -> add_value(acc, addr)
    ir.MemStoreUnchecked(_, _, addr, value, _) ->
      add_value(add_value(acc, addr), value)
    ir.MemFill(_, dest, value, count) -> union_values(acc, [dest, value, count])
    ir.MemCopy(_, _, dst, src, count) -> union_values(acc, [dst, src, count])
    ir.MemInit(_, _, dst, src, count) -> union_values(acc, [dst, src, count])
    ir.DataDrop(_) -> acc
    ir.SimdLoad(_, _, addr, _) -> add_value(acc, addr)
    ir.SimdStore(_, addr, value, _) -> add_value(add_value(acc, addr), value)
    ir.SimdLoadLane(_, _, addr, _, _, vec) ->
      add_value(add_value(acc, addr), vec)
    ir.SimdStoreLane(_, _, addr, _, _, vec) ->
      add_value(add_value(acc, addr), vec)
    // globals
    ir.GlobalGet(_) -> acc
    ir.GlobalSet(_, value) -> add_value(acc, value)
    // calls
    ir.CallDirect(_, args) -> union_values(acc, args)
    ir.CallIndirect(_, index, _, args) ->
      union_values(add_value(acc, index), args)
    ir.CallHost(_, _, args) -> union_values(acc, args)
    ir.CallImport(_, _, args) -> union_values(acc, args)
    ir.CallClosure(callee, args) -> union_values(add_value(acc, callee), args)
    // Phase-13 tail calls: collect their `Value` operands (the indirect `index` + the args), like
    // `CallImport`/`CallIndirect`.
    ir.ReturnCall(_, args) -> union_values(acc, args)
    ir.ReturnCallIndirect(_, index, _, args) ->
      union_values(add_value(acc, index), args)
    ir.ReturnCallImport(_, _, args) -> union_values(acc, args)
    // exceptions
    ir.Throw(_, args) -> union_values(acc, args)
    ir.ThrowRef(exnref) -> add_value(acc, exnref)
    ir.Try(_, body, handlers) ->
      list.fold(handlers, vars_in(acc, body), fn(a, h) { vars_in(a, h.handler) })
    // control transfers (operands)
    ir.Break(_, values) -> union_values(acc, values)
    ir.Continue(_, values) -> union_values(acc, values)
    ir.Return(values) -> union_values(acc, values)
    ir.Trap(_) -> acc
    // sequencing / structured control (recurse)
    ir.Let(_, rhs, body) -> vars_in(vars_in(acc, rhs), body)
    ir.Charge(_, body) -> vars_in(acc, body)
    ir.Block(_, _, body) -> vars_in(acc, body)
    ir.Loop(_, params, _, body) ->
      vars_in(list.fold(params, acc, fn(a, p) { add_value(a, p.init) }), body)
    ir.If(cond, _, then_branch, else_branch) ->
      vars_in(vars_in(add_value(acc, cond), then_branch), else_branch)
    ir.Switch(selector, _, arms, default) ->
      list.fold(arms, vars_in(add_value(acc, selector), default), fn(a, arm) {
        vars_in(a, arm.body)
      })
  }
}

/// Accumulate every name BOUND inside `e` (a `Let`'s names, a `Loop`'s param names, a `Try`
/// handler's payload/exnref names). Used by `bound_names`. Exhaustive over the sub-`Expr`-bearing
/// nodes; leaves bind nothing.
fn binders_in(acc: Set(String), e: Expr) -> Set(String) {
  case e {
    ir.Let(names, rhs, body) -> {
      let acc = list.fold(names, acc, set.insert)
      binders_in(binders_in(acc, rhs), body)
    }
    ir.Charge(_, body) -> binders_in(acc, body)
    ir.Block(_, _, body) -> binders_in(acc, body)
    ir.Loop(_, ps, _, body) -> {
      let acc = list.fold(ps, acc, fn(a, p) { set.insert(a, p.name) })
      binders_in(acc, body)
    }
    ir.If(_, _, then_branch, else_branch) ->
      binders_in(binders_in(acc, then_branch), else_branch)
    ir.Switch(_, _, arms, default) ->
      list.fold(arms, binders_in(acc, default), fn(a, arm) {
        binders_in(a, arm.body)
      })
    ir.Try(_, body, handlers) ->
      list.fold(handlers, binders_in(acc, body), fn(a, h) {
        let a = list.fold(h.payload, a, set.insert)
        let a = case h.exnref {
          option.Some(n) -> set.insert(a, n)
          option.None -> a
        }
        binders_in(a, h.handler)
      })
    // every other node binds no name and carries no sub-`Expr`.
    _ -> acc
  }
}
