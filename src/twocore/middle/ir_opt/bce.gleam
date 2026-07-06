//// `middle/ir_opt/bce` — range-based bounds-check elimination via LOOP VERSIONING (Phase-10 unit
//// 06, N4).
////
//// A WASM memory access is **trap-or-access**; a bounds check may not simply be dropped (a loop
//// with side effects before an OOB iteration must still trap AT that iteration). So BCE does **not**
//// hoist-and-trap-early. It **versions** an eligible affine-access loop:
////
////   let guard = <pure i64 range check> in
////   if guard  then  <the loop, its i-addressed accesses UNCHECKED>
////             else  <the original loop, unchanged (checked)>
////
//// This is EXACTLY semantics-preserving (values AND traps): when the guard passes, every iteration's
//// recognized access is provably in-bounds, so the unchecked fast loop behaves identically to the
//// checked loop; when it fails, the original checked loop runs — identical values, identical trap at
//// the identical point. The guard is pure (arithmetic on loop-invariant quantities + `memory.size`),
//// so it adds no observable. Trust-neutral → runs at `Baseline`.
////
//// ## The recognized shape (N8 — pattern-bounded, conservative; bail = checked, always sound)
////
//// v1 recognizes the single-affine-cursor loop the WASM frontend lowers a `for`-over-a-buffer to:
////   `Loop(l, params, result, Let([c], Num(cmp, [Var(i), n]), If(Var(c), A, B)))`
//// where `i` is a loop PARAM, `cmp` is `i.lt_u n` (work in the TRUE arm) or `i.ge_u n` (work in the
//// FALSE arm, the standard `if i>=n break` shape), `n` is loop-INVARIANT, and the loads/stores whose
//// `addr` is exactly `Var(i)` (the byte cursor) are in the guarded ("work") arm. It requires **no
//// `MemGrow` and no call** anywhere in the loop body (so `memory.size` is stable), and is idempotent
//// (skips a loop already containing an unchecked node). Anything else stays checked — richer affine
//// forms (`base + coeff·i`), multiple induction variables, and loops that grow/call are deferred.

import gleam/list
import gleam/set
import gleam/string
import twocore/ir.{type Expr, type Value}
import twocore/middle/ir_opt/loop_analysis
import twocore/middle/ir_opt/pass.{type Pass}

const page_bytes: Int = 65_536

/// The unique prefix of every guard variable a versioning introduces. It is derived from the loop's
/// LABEL (unique per function, D6), so distinct versionings never collide; an `If` whose condition
/// is a `$bce$…` guard var is an ALREADY-VERSIONED guard, which the walk does not re-version (the
/// idempotence marker — N7).
const guard_marker: String = "$bce$"

/// The range-based bounds-check-elimination pass (N4). A `pass.per_function` walk that versions each
/// eligible affine-cursor loop. Semantics-preserving (§module docs). Registered by unit 07 into the
/// `Baseline` arm (inherited by `Aggressive`). Total; never panics.
pub fn bce_pass() -> Pass {
  pass.per_function("bce", fn(f) { ir.Function(..f, body: bce_expr(f.body)) })
}

/// Bottom-up walk: optimize sub-expressions first, then try to version a `Loop`.
fn bce_expr(e: Expr) -> Expr {
  case e {
    ir.Loop(label, params, result, body) ->
      try_version(label, params, result, bce_expr(body))
    ir.Let(names, rhs, body) -> ir.Let(names, bce_expr(rhs), bce_expr(body))
    ir.Block(label, result, body) -> ir.Block(label, result, bce_expr(body))
    // An already-versioned guard (`if $bce$… { fast } { slow }`): do NOT re-version its arms' top
    // loops (that would nest a fresh versioning around the pristine slow arm — the idempotence bug).
    // Still descend into each arm's BODY so a NESTED loop is versioned (N7 / R7b).
    ir.If(cond, result, then_branch, else_branch) ->
      case is_guard_cond(cond) {
        True ->
          ir.If(
            cond,
            result,
            descend_only(then_branch),
            descend_only(else_branch),
          )
        False ->
          ir.If(cond, result, bce_expr(then_branch), bce_expr(else_branch))
      }
    ir.Switch(selector, result, arms, default) ->
      ir.Switch(
        selector,
        result,
        list.map(arms, fn(a) { ir.SwitchArm(..a, body: bce_expr(a.body)) }),
        bce_expr(default),
      )
    ir.Charge(cost, body) -> ir.Charge(cost, bce_expr(body))
    ir.Try(result, body, handlers) ->
      ir.Try(
        result,
        bce_expr(body),
        list.map(handlers, fn(h) {
          ir.CatchHandler(..h, handler: bce_expr(h.handler))
        }),
      )
    _ -> e
  }
}

/// Is `cond` a versioning-guard variable (a `$bce$…` name)? Marks an already-versioned `If` so its
/// arms are not re-versioned (idempotence, N7).
fn is_guard_cond(cond: Value) -> Bool {
  case cond {
    ir.Var(name) -> string.starts_with(name, guard_marker)
    _ -> False
  }
}

/// Recurse into a versioned arm's body (versioning any NESTED loop) WITHOUT re-versioning the arm's
/// own top loop.
fn descend_only(e: Expr) -> Expr {
  case e {
    ir.Loop(label, params, result, body) ->
      ir.Loop(label, params, result, bce_expr(body))
    _ -> bce_expr(e)
  }
}

/// Try to version `Loop(label, params, result, body)`; return it unchanged if not eligible.
fn try_version(
  label: String,
  params: List(ir.LoopParam),
  result: List(ir.ValType),
  body: Expr,
) -> Expr {
  let loop = ir.Loop(label, params, result, body)
  // idempotence: a loop already containing an unchecked node (this or a sibling arm) is not eligible.
  case has_unchecked(body) || has_grow_or_call(body) {
    True -> loop
    False ->
      case recognize(params, body) {
        Error(Nil) -> loop
        Ok(Recognized(i_name, n, work_is_then, cond_name, cmp, work, other)) -> {
          // the i-addressed accesses in the guarded ("work") arm — their max (offset + bytes).
          let accesses = cursor_accesses(work, i_name)
          case accesses {
            [] -> loop
            _ -> {
              let max_span = list.fold(accesses, 0, fn(m, s) { int_max(m, s) })
              // fast arm: convert the i-addressed accesses in the work branch to unchecked.
              let fast_work = to_unchecked(work, i_name)
              let fast_body =
                rebuild_body(
                  cond_name,
                  cmp,
                  i_name,
                  n,
                  work_is_then,
                  fast_work,
                  other,
                )
              let fast = ir.Loop(label, params, result, fast_body)
              // versioned: guard ? fast : original-checked. Guard vars are keyed on `label` (unique
              // per function, D6) so distinct versionings never collide.
              build_versioned(label, n, max_span, result, fast, loop)
            }
          }
        }
      }
  }
}

// ───────────────────────────── recognition ─────────────────────────────

/// A recognized affine-cursor loop: the induction var `i`, the invariant bound `n`, whether the
/// guarded work is the THEN arm (`work_is_then`), the condition binding's name, the comparison op,
/// the work branch, and the other (exit) branch.
type Recognized {
  Recognized(
    i_name: String,
    n: Value,
    work_is_then: Bool,
    cond_name: String,
    cmp: ir.NumOp,
    work: Expr,
    other: Expr,
  )
}

/// Match the recognized loop shape (§module docs). `Error(Nil)` if not the affine-cursor shape.
fn recognize(
  params: List(ir.LoopParam),
  body: Expr,
) -> Result(Recognized, Nil) {
  case body {
    ir.Let(
      [cond_name],
      ir.Num(cmp, [ir.Var(i_name), n]),
      ir.If(ir.Var(c2), _result, then_branch, else_branch),
    )
      if cond_name == c2
    ->
      case is_param(i_name, params), invariant_bound(n, params, body) {
        True, True ->
          case cmp {
            // i < n : the TRUE arm runs when i < n → work = then.
            ir.ILtU(ir.W32) ->
              Ok(Recognized(
                i_name,
                n,
                True,
                cond_name,
                cmp,
                then_branch,
                else_branch,
              ))
            // i >= n : the TRUE arm is the exit; the FALSE arm runs when i < n → work = else.
            ir.IGeU(ir.W32) ->
              Ok(Recognized(
                i_name,
                n,
                False,
                cond_name,
                cmp,
                else_branch,
                then_branch,
              ))
            _ -> Error(Nil)
          }
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Is `name` one of the loop's params (the induction candidate)?
fn is_param(name: String, params: List(ir.LoopParam)) -> Bool {
  list.any(params, fn(p) { p.name == name })
}

/// Is the bound `n` loop-INVARIANT — a constant, or a `Var` that is NEITHER a loop param NOR bound
/// inside the body (so it holds the same value every iteration)? Conservative.
fn invariant_bound(n: Value, params: List(ir.LoopParam), body: Expr) -> Bool {
  case n {
    ir.ConstI32(_) -> True
    ir.Var(name) -> !set.contains(loop_analysis.bound_names(params, body), name)
    _ -> False
  }
}

/// The list of `(offset + bytes)` spans of the `MemLoad`/`MemStore` in `work` whose `addr` is exactly
/// `Var(i_name)` — the recognized affine cursor accesses. (A nested Loop is opaque; `i` is immutable
/// within the outer iteration, so its accesses anywhere in the arm satisfy `i < n`.)
fn cursor_accesses(work: Expr, i_name: String) -> List(Int) {
  spans_in(work, i_name, [])
}

fn spans_in(e: Expr, i_name: String, acc: List(Int)) -> List(Int) {
  case e {
    ir.MemLoad(_, op, ir.Var(a), offset, _) if a == i_name -> [
      offset + op.bytes,
      ..acc
    ]
    ir.MemStore(_, op, ir.Var(a), _, offset) if a == i_name -> [
      offset + op.bytes,
      ..acc
    ]
    ir.Let(_, rhs, body) -> spans_in(body, i_name, spans_in(rhs, i_name, acc))
    ir.Block(_, _, body) -> spans_in(body, i_name, acc)
    ir.Charge(_, body) -> spans_in(body, i_name, acc)
    ir.If(_, _, t, el) -> spans_in(el, i_name, spans_in(t, i_name, acc))
    ir.Switch(_, _, arms, def) ->
      list.fold(arms, spans_in(def, i_name, acc), fn(a, arm) {
        spans_in(arm.body, i_name, a)
      })
    // a nested Loop / Try is opaque to the recognizer (its accesses are its own concern).
    _ -> acc
  }
}

// ───────────────────────────── the fast-arm rewrite ─────────────────────────────

/// Rewrite every `MemLoad`/`MemStore` whose `addr` is `Var(i_name)` in `e` to its UNCHECKED twin.
/// (Descends into `Let`/`If`/`Switch`/`Block`/`Charge`; a nested `Loop`/`Try` is left as-is.)
fn to_unchecked(e: Expr, i_name: String) -> Expr {
  case e {
    ir.MemLoad(mem, op, ir.Var(a), offset, result) if a == i_name ->
      ir.MemLoadUnchecked(mem, op, ir.Var(a), offset, result)
    ir.MemStore(mem, op, ir.Var(a), value, offset) if a == i_name ->
      ir.MemStoreUnchecked(mem, op, ir.Var(a), value, offset)
    ir.Let(names, rhs, body) ->
      ir.Let(names, to_unchecked(rhs, i_name), to_unchecked(body, i_name))
    ir.Block(label, result, body) ->
      ir.Block(label, result, to_unchecked(body, i_name))
    ir.Charge(cost, body) -> ir.Charge(cost, to_unchecked(body, i_name))
    ir.If(cond, result, t, el) ->
      ir.If(cond, result, to_unchecked(t, i_name), to_unchecked(el, i_name))
    ir.Switch(selector, result, arms, default) ->
      ir.Switch(
        selector,
        result,
        list.map(arms, fn(a) {
          ir.SwitchArm(..a, body: to_unchecked(a.body, i_name))
        }),
        to_unchecked(default, i_name),
      )
    _ -> e
  }
}

/// Reassemble the loop body `Let([cond], Num(cmp, [Var(i), n]), If(cond, then, else))` with the
/// (possibly rewritten) work branch placed back in its arm.
fn rebuild_body(
  cond_name: String,
  cmp: ir.NumOp,
  i_name: String,
  n: Value,
  work_is_then: Bool,
  work: Expr,
  other: Expr,
) -> Expr {
  let #(then_branch, else_branch) = case work_is_then {
    True -> #(work, other)
    False -> #(other, work)
  }
  ir.Let(
    [cond_name],
    ir.Num(cmp, [ir.Var(i_name), n]),
    ir.If(ir.Var(cond_name), [], then_branch, else_branch),
  )
}

// ───────────────────────────── the versioning guard ─────────────────────────────

/// Build `let … in if <guard> then fast else slow`. The guard is the PURE i64 range check
/// `n + max_span <= memory.size * page_bytes` (unsigned) — computed in i64 to avoid any i32 wrap
/// (n < 2³², max_span small, byte_len ≤ 2³², all well within i64). When true, every recognized
/// access `Var(i)+offset` with `i < n` satisfies `i + offset + bytes <= n + max_span <= byte_len`
/// (in bounds); when false, the checked `slow` loop runs. `max_span` = max(offset + bytes).
fn build_versioned(
  label: String,
  n: Value,
  max_span: Int,
  result: List(ir.ValType),
  fast: Expr,
  slow: Expr,
) -> Expr {
  let sz = gvar(label, "sz")
  let sz64 = gvar(label, "sz64")
  let bytelen = gvar(label, "bytelen")
  let n64 = gvar(label, "n64")
  let need = gvar(label, "need")
  let guard = gvar(label, "guard")
  ir.Let(
    [sz],
    ir.MemSize(0),
    ir.Let(
      [sz64],
      ir.Convert(ir.I64ExtendI32U, ir.Var(sz)),
      ir.Let(
        [bytelen],
        ir.Num(ir.IMul(ir.W64), [ir.Var(sz64), ir.ConstI64(page_bytes)]),
        ir.Let(
          [n64],
          ir.Convert(ir.I64ExtendI32U, extend_source(n)),
          ir.Let(
            [need],
            ir.Num(ir.IAdd(ir.W64), [ir.Var(n64), ir.ConstI64(max_span)]),
            ir.Let(
              [guard],
              ir.Num(ir.ILeU(ir.W64), [ir.Var(need), ir.Var(bytelen)]),
              ir.If(ir.Var(guard), result, fast, slow),
            ),
          ),
        ),
      ),
    ),
  )
}

/// A unique guard-variable name for the loop labelled `label`: `$bce$<label>$<suffix>`. The label is
/// unique per function (D6), so guard vars of distinct versionings never collide, and the `$bce$`
/// prefix marks a versioning `If`'s condition for the idempotence check (`is_guard_cond`).
fn gvar(label: String, suffix: String) -> String {
  guard_marker <> label <> "$" <> suffix
}

/// The i32 value to feed `I64ExtendI32U` for the bound `n`: a `Var` passes through; a `ConstI32`
/// stays a `ConstI32` (extend zero-extends its unsigned bits). Any other (unreachable — `n` is a
/// validated i32) defaults to `ConstI32(0)`.
fn extend_source(n: Value) -> Value {
  case n {
    ir.Var(_) | ir.ConstI32(_) -> n
    _ -> ir.ConstI32(0)
  }
}

// ───────────────────────────── scans ─────────────────────────────

/// Does `e` (recursively) contain a `MemGrow` or any CALL? Such a node could change `memory.size`
/// mid-loop, invalidating the range guard — so a loop containing one is NOT eligible for versioning.
///
/// Phase-14 note: a `RefFuncImport` (R1) is NOT a call — it constructs a funcref, it dispatches
/// nothing — so it is NOT in the `-> True` group and falls to the `_ -> False` default, exactly like
/// `RefFunc`. A loop containing only a `RefFuncImport` therefore stays versioning-eligible. This is
/// the one place `RefFuncImport` deliberately does NOT mirror `CallImport` (which IS a call). Public
/// so the keystone freeze test can assert this directly (not confirm it by silence).
pub fn has_grow_or_call(e: Expr) -> Bool {
  case e {
    ir.MemGrow(_, _)
    | ir.CallDirect(_, _)
    | ir.CallIndirect(_, _, _, _)
    | ir.CallHost(_, _, _)
    | ir.CallImport(_, _, _)
    | ir.CallClosure(_, _)
    | // Phase-13: a tail CALL is a call — it may change `memory.size` mid-loop (grow inside the
      // callee) exactly like any other call, so a loop containing one is NOT versioning-eligible. ──
      ir.ReturnCall(_, _)
    | ir.ReturnCallIndirect(_, _, _, _)
    | ir.ReturnCallImport(_, _, _) -> True
    ir.Let(_, rhs, body) -> has_grow_or_call(rhs) || has_grow_or_call(body)
    ir.Block(_, _, body) -> has_grow_or_call(body)
    ir.Loop(_, _, _, body) -> has_grow_or_call(body)
    ir.Charge(_, body) -> has_grow_or_call(body)
    ir.If(_, _, t, el) -> has_grow_or_call(t) || has_grow_or_call(el)
    ir.Switch(_, _, arms, def) ->
      has_grow_or_call(def)
      || list.any(arms, fn(a) { has_grow_or_call(a.body) })
    ir.Try(_, body, hs) ->
      has_grow_or_call(body)
      || list.any(hs, fn(h) { has_grow_or_call(h.handler) })
    _ -> False
  }
}

/// Does `e` (recursively) already contain an unchecked access (⟹ already versioned — idempotence)?
fn has_unchecked(e: Expr) -> Bool {
  case e {
    ir.MemLoadUnchecked(_, _, _, _, _) | ir.MemStoreUnchecked(_, _, _, _, _) ->
      True
    ir.Let(_, rhs, body) -> has_unchecked(rhs) || has_unchecked(body)
    ir.Block(_, _, body) -> has_unchecked(body)
    ir.Loop(_, _, _, body) -> has_unchecked(body)
    ir.Charge(_, body) -> has_unchecked(body)
    ir.If(_, _, t, el) -> has_unchecked(t) || has_unchecked(el)
    ir.Switch(_, _, arms, def) ->
      has_unchecked(def) || list.any(arms, fn(a) { has_unchecked(a.body) })
    ir.Try(_, body, hs) ->
      has_unchecked(body) || list.any(hs, fn(h) { has_unchecked(h.handler) })
    _ -> False
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}
