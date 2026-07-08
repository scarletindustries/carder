//// `middle/ir_opt/aggressive` — the Unsafe-only optimizer passes (Phase-3 unit 04, F1/F2/F4).
////
//// These passes run ONLY at `OptLevel.Aggressive`, which is reachable ONLY from
//// `profiles.unsafe()` (F4) — the Safe default (`Baseline`) never executes a line of this
//// module. Each pass carries an EXPLICIT, documented trust assumption and is proven not to
//// change a returned value (bit-for-bit, D7) or a trap (reason + trap-or-not) on any input
//// (F2). Unsafe is NOT a licence to break WebAssembly semantics: WASM has no C-style undefined
//// behaviour, so every ill-defined operation traps and inlining never drops a trap. The trust
//// here is confined to the fuel-metering POLICY overlay (`MeterOff`) and toolchain
//// well-formedness — never to WASM value/trap behaviour.
////
//// ## The profile coupling (Aggressive ⟹ MeterOff)
////
//// Both passes are sound only because `OptLevel = Aggressive` implies `MeterMode = MeterOff`
//// (only `Baseline`/`OptNone` may pair with `MeterFuel`, pinned by a keystone test). A legal
//// Aggressive build is therefore always `MeterOff`, so it carries NO `Charge` nodes and no
//// seeded fuel budget: inlining cannot perturb a fuel observable and `Charge`-elision cannot
//// drop a `FuelExhausted` trap. On real pipeline input `charge_elide` is a defence-in-depth
//// no-op; it exists so the Aggressive POSTCONDITION (output contains no `Charge`) holds
//// structurally even for hand-written `.ir` fed straight to `optimize(_, Aggressive)`.
////
//// ## Import hygiene (no cycle)
////
//// This module imports the `Pass` machinery from `middle/ir_opt/pass` (a leaf importing `ir`
//// only), NOT from `middle/ir_opt` — `ir_opt` imports THIS module to register the Aggressive
//// arm, so importing it back would cycle. The edges `aggressive → {ir, pass}` are acyclic. It
//// never imports a `runtime/*` impl module (D3a — this is a build-time IR→IR pass).
////
//// ## Honest scope (F8)
////
//// What is deliberately NOT here: LICM (needs a richer aliasing model), range-based
//// bounds-check elimination (a wrong range proof would drop a `MemoryOutOfBounds` trap), SIMD
//// vectorisation (no SIMD IR), and pure-call CSE / compile-time call evaluation (needs a
//// partial evaluator). Post-inlining copy-prop/const-fold/DCE are NOT new passes — the
//// `run_pipeline` fixpoint re-runs the whole arm (baseline included) over the enlarged bodies,
//// so inlining's newly-exposed constants are folded by unit 03's passes for free.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set.{type Set}
import gleam/string
import twocore/ir
import twocore/middle/ir_opt/pass.{type Pass, map_expr, pass, per_expr}

/// The maximum callee body size (Expr-node count) eligible for inlining at a non-unique call
/// site. Bodies larger than this are inlined ONLY when single-call-site (inline-and-delete is
/// size-neutral). A knob, not a correctness bound — termination rests on the acyclic-callee
/// guard + the size budget, not on this number.
const small_body_nodes: Int = 24

/// The ABSOLUTE ceiling (whole-module Expr-node count) inlining is allowed to grow a module to —
/// the graceful-degradation bound (F8; Phase-3 §00 F8: "the optimizer is deliberately bounded").
///
/// The per-run size budget `8·nodes + 4096` scales with the input, so on a very large module
/// (unit-11's ~80-function capstone finding) it would still license a MANY-FOLD expansion, and
/// because `run_pipeline` recomputes that budget each fixpoint round over the already-enlarged
/// module the growth compounds — a compile-time code explosion. This constant clamps the budget
/// to a FIXED node ceiling INDEPENDENT of input size, so the module can never grow past it: on a
/// large module the inliner fills up to the ceiling and then CLEANLY STOPS, leaving the remaining
/// calls un-inlined. Reducing inlining is always sound (§B.4 — the un-inlined call keeps the exact
/// same value/trap), so this cannot introduce a soundness bug; it only bounds compile time/size.
///
/// A tuning knob, not a correctness bound. It is far above every corpus/spec module (whose per-run
/// budget never binds), so it changes nothing on realistic input; it engages only on pathological
/// inputs whose fully-inlined form would explode.
pub const inline_node_ceiling: Int = 65_536

/// The ordered Unsafe-only passes, appended after the baseline passes to build the `Aggressive`
/// pipeline arm: `pipeline(Aggressive) == baseline.baseline_passes() ++ aggressive_passes()`.
///
/// Order: `[charge_elide(), inline()]`. `charge_elide` first normalises away any metering
/// instrumentation (belt-and-suspenders — §C), so inlining and the fixpoint's baseline sweep
/// see `Charge`-free bodies. Post-inlining cleanup is delivered by the `run_pipeline` fixpoint
/// re-running unit 03's baseline passes over the enlarged bodies, so no separate cleanup pass
/// appears here.
///
/// - Return: the two `Pass` values in fixed order. Total — never fails.
pub fn aggressive_passes() -> List(Pass) {
  [charge_elide(), inline()]
}

// ─────────────────────────── Pass 2 — Charge-elision ───────────────────────────

/// Elide every `Charge(cost, body)` node, rewriting it to `body` (bottom-up via `map_expr`, so
/// nested charges collapse). Implemented as `per_expr("charge-elide", …)`.
///
/// TRUST ASSUMPTION (documented, F2/F3): `binding.meter == MeterOff`. Under `MeterOff` no fuel
/// budget is ever seeded (unit 05), so `rt_meter.charge` neither raises `FuelExhausted` nor
/// participates in any observable — `fuel_consumed()` is not a contract of the Unsafe profile.
/// Removing the node therefore changes NO returned value and NO trap. This is sound ONLY under
/// the profile coupling `Aggressive ⟹ MeterOff` (see module docs) — NOT independent of
/// provenance: under Safe (`MeterFuel`) the identical elision would drop the `Charge` sites
/// whose exhaustion raises `FuelExhausted`, which is forbidden by F2. A legal Aggressive build
/// carries no `Charge` nodes at all, so on real pipeline input this pass is a no-op; it runs as
/// defence-in-depth so the Aggressive postcondition ("output contains no `Charge`") holds
/// structurally even for hand-written input.
///
/// - Return: a `Pass` that deletes every `Charge` node from every function body. Total.
pub fn charge_elide() -> Pass {
  per_expr("charge-elide", fn(e) {
    case e {
      ir.Charge(_cost, body) -> body
      other -> other
    }
  })
}

// ─────────────────────────── Pass 1 — function inlining ───────────────────────────

/// Inline eligible `CallDirect` sites (§B.1) with a capture-avoiding copy of the callee body,
/// then delete any callee left with zero remaining call sites and no export/entry reference.
///
/// A `Let(names, CallDirect(f, args), cont)` is inlined iff `f` is (1) a DEFINED function of this
/// module, (2) NON-recursive (not self-calling and not on a `CallDirect` call-graph cycle),
/// (3) leaf OR small-body (≤ `small_body_nodes`) OR called from exactly one site module-wide,
/// and (4) the running size budget can afford the callee body. The transform is
/// capture-avoiding: every callee-bound name (locals/`Let`/`Block`/`Loop` labels + loop-param
/// names) is alpha-renamed to a fresh unique name, params are substituted with the atomic ANF
/// `Value` args (no effect duplication/reorder), and the body is wrapped in a fresh
/// `Block(exit_label, f.result, …)` with every callee `Return(vs)` rewritten to
/// `Break(exit_label, vs)` (single-exit — the `Return` yields to the inlined region, not the
/// caller).
///
/// TRUST ASSUMPTION (documented, F2): `binding.meter == MeterOff` — NO `Charge` nodes present
/// (guaranteed by the `Aggressive ⟹ MeterOff` coupling), so inlining perturbs no fuel
/// observable. The pass ALSO assumes toolchain well-formedness (the callee body faithfully
/// implements `f`; names unique per-function). It never inspects or depends on WASM value/trap
/// semantics, which it preserves exactly: args are pre-evaluated `Value`s so substitution adds
/// no evaluation; the body is transplanted verbatim (only renamed) so every effect and trap
/// fires at the same point in the same order; no trap (`IntDivByZero`/`IntOverflow`/
/// `MemoryOutOfBounds`/`Unreachable`/…) is ever elided.
///
/// TERMINATION: the well-founded measure is the remaining size budget `B_remaining` — a
/// non-negative integer decremented by ≥ 1 per inline (a callee body is ≥ 1 node), bounded
/// below by 0 — plus the acyclic-callee guard (no callee is ever re-entered). When the budget is
/// spent or no site is eligible, `run` is the identity, so the `run_pipeline` fixpoint
/// converges. No `let assert`/`panic`: an ineligible/malformed shape is left unchanged (D4).
///
/// GRACEFUL DEGRADATION (F8): the per-run budget is clamped by the absolute `inline_node_ceiling`,
/// so on a very large module the inliner grows it to the ceiling and then cleanly STOPS — the
/// remaining calls are left un-inlined (always sound, §B.4). This bounds compile time/size on a
/// pathological input instead of letting the round-compounding budget explode.
///
/// - Return: the whole-module inlining `Pass`. Total — never fails.
pub fn inline() -> Pass {
  pass("inline", run_inline)
}

/// Threaded state for one `run_inline` invocation: the remaining size budget and the next fresh
/// alpha-rename counter.
///
/// - `budget`: `B_remaining` — the number of Expr-nodes inlining may still ADD across the whole
///   module. Strictly decreases per inline; when it drops below the next callee's cost the site
///   is left unchanged (the termination measure). Seeded as
///   `max(0, min(8·nodes + 4096, inline_node_ceiling − nodes))` — the generous size-proportional
///   allowance, CLAMPED so the output can never exceed the absolute `inline_node_ceiling`
///   (graceful degradation on a large module, F8).
/// - `counter`: the next unused integer suffix for a fresh `…$inl<n>` name. Monotonically
///   increasing so every generated name is unique.
type InlineState {
  InlineState(budget: Int, counter: Int)
}

/// The per-`run` resolution context: the callee lookup, the recursion set, and the module-wide
/// `CallDirect` site counts. Computed once from the input module, before the walk.
///
/// - `by_name`: every defined function keyed by name (the callee resolver).
/// - `recursive`: the names of functions that are self-recursive or on a `CallDirect` cycle —
///   never eligible for inlining (the acyclic guard).
/// - `sites`: `fn_name -> number of CallDirect sites` in the input module (the single-call-site
///   heuristic input).
type InlineCtx {
  InlineCtx(
    by_name: Dict(String, ir.Function),
    recursive: Set(String),
    sites: Dict(String, Int),
  )
}

/// The whole-module inlining transform: resolve the callee graph, walk every body inlining
/// eligible sites within the budget, then drop callees orphaned by the inlining.
///
/// - `module`: the IR module to rewrite.
/// - Return: `module` with eligible `CallDirect` sites inlined and orphaned non-exported callees
///   removed. Total — never fails; ineligible or malformed shapes are left unchanged.
fn run_inline(module: ir.Module) -> ir.Module {
  let funcs = module.functions
  let by_name = dict.from_list(list.map(funcs, fn(f) { #(f.name, f) }))
  let graph = build_call_graph(funcs, by_name)
  let recursive = recursive_names(funcs, graph)
  let input_sites = count_calls_module(funcs)
  let ctx =
    InlineCtx(by_name: by_name, recursive: recursive, sites: input_sites)
  // Budget: the generous size-proportional allowance `8·nodes + 4096` (a safety valve; on the
  // corpus it is never exhausted), CLAMPED so the module can never grow past the absolute
  // `inline_node_ceiling`. The `inline_node_ceiling - nodes` term is the graceful-degradation
  // bound (F8): the size-proportional term alone would license a many-fold, round-compounding
  // expansion on a large module, so we cap total output at a FIXED node ceiling — the inliner
  // fills up to it and then cleanly stops (remaining calls left un-inlined; always sound, §B.4).
  // Kept non-negative: an already-oversized input (nodes ≥ ceiling) yields budget 0 → no inlining.
  // Counter: seeded ABOVE every `$inl` suffix already present so generated names are globally
  // unique across fixpoint rounds.
  let nodes = module_node_count(funcs)
  let budget =
    int.max(0, int.min(8 * nodes + 4096, inline_node_ceiling - nodes))
  let seed = 1 + max_inl_counter_module(funcs)
  let st0 = InlineState(budget: budget, counter: seed)

  let #(new_funcs_rev, _final) =
    list.fold(funcs, #([], st0), fn(acc, f) {
      let #(done, st) = acc
      let #(body2, st2) = go(f.body, ctx, st)
      #([ir.Function(..f, body: body2), ..done], st2)
    })
  let new_funcs = list.reverse(new_funcs_rev)

  // Orphan deletion: a function called in the input but no longer called in the output, that is
  // not exported / the start / referenced by an element segment, is dead — remove it.
  let output_sites = count_calls_module(new_funcs)
  let protected = protected_names(module)
  let kept =
    list.filter(new_funcs, fn(f) {
      keep_function(f.name, input_sites, output_sites, protected)
    })
  ir.Module(..module, functions: kept)
}

/// Walk one expression top-down, threading the budget/counter state and inlining eligible
/// `Let(_, CallDirect, _)` sites. Recurses INTO each inlined body so calls-of-calls are also
/// expanded within the same `run` (full acyclic expansion, bounded by the budget).
///
/// - `e`: the expression to rewrite.
/// - `ctx`: the resolution context.
/// - `st`: the threaded state on entry.
/// - Return: `#(rewritten_expr, state_after)`. Total.
fn go(e: ir.Expr, ctx: InlineCtx, st: InlineState) -> #(ir.Expr, InlineState) {
  case e {
    // the inline trigger — a call bound by a `Let`
    ir.Let(names, ir.CallDirect(fname, args), cont) ->
      case try_inline(names, fname, args, cont, ctx, st) {
        Ok(res) -> res
        Error(Nil) -> {
          let #(cont2, st2) = go(cont, ctx, st)
          #(ir.Let(names, ir.CallDirect(fname, args), cont2), st2)
        }
      }
    ir.Let(names, rhs, cont) -> {
      let #(rhs2, st1) = go(rhs, ctx, st)
      let #(cont2, st2) = go(cont, ctx, st1)
      #(ir.Let(names, rhs2, cont2), st2)
    }
    ir.Block(label, result, body) -> {
      let #(b2, st1) = go(body, ctx, st)
      #(ir.Block(label, result, b2), st1)
    }
    ir.Loop(label, params, result, body) -> {
      let #(b2, st1) = go(body, ctx, st)
      #(ir.Loop(label, params, result, b2), st1)
    }
    ir.If(cond, result, then_branch, else_branch) -> {
      let #(t2, st1) = go(then_branch, ctx, st)
      let #(e2, st2) = go(else_branch, ctx, st1)
      #(ir.If(cond, result, t2, e2), st2)
    }
    ir.Switch(sel, result, arms, default) -> {
      let #(arms_rev, st1) =
        list.fold(arms, #([], st), fn(acc, arm) {
          let #(done, s) = acc
          let #(b2, s2) = go(arm.body, ctx, s)
          #([ir.SwitchArm(..arm, body: b2), ..done], s2)
        })
      let #(def2, st2) = go(default, ctx, st1)
      #(ir.Switch(sel, result, list.reverse(arms_rev), def2), st2)
    }
    ir.Charge(cost, body) -> {
      let #(b2, st1) = go(body, ctx, st)
      #(ir.Charge(cost, b2), st1)
    }
    // leaves — no sub-expression to descend into.
    _ -> #(e, st)
  }
}

/// Attempt to inline `Let(names, CallDirect(fname, args), cont)`. Returns `Ok(#(expr, state))`
/// with the fully-processed replacement (the inlined block, itself walked for nested calls,
/// followed by the walked `cont`), or `Error(Nil)` when the site is ineligible, mis-arity, or
/// unaffordable — the caller then leaves the call unchanged (fail-safe, D4).
fn try_inline(
  names: List(String),
  fname: String,
  args: List(ir.Value),
  cont: ir.Expr,
  ctx: InlineCtx,
  st: InlineState,
) -> Result(#(ir.Expr, InlineState), Nil) {
  case eligible(fname, ctx) {
    False -> Error(Nil)
    True ->
      case dict.get(ctx.by_name, fname) {
        Error(Nil) -> Error(Nil)
        Ok(f) -> {
          let arity_ok =
            list.length(names) == list.length(f.result)
            && list.length(args) == list.length(f.params)
          case arity_ok {
            False -> Error(Nil)
            True -> {
              let cost = node_count(f.body)
              case st.budget >= cost {
                False -> Error(Nil)
                True -> {
                  let st_b = InlineState(..st, budget: st.budget - cost)
                  let #(block, st1) = build_inline(f, args, st_b)
                  let #(block2, st2) = go(block, ctx, st1)
                  let #(cont2, st3) = go(cont, ctx, st2)
                  Ok(#(ir.Let(names, block2, cont2), st3))
                }
              }
            }
          }
        }
      }
  }
}

/// Build the capture-avoiding, single-exit inlined block for a call to `f` with `args`.
///
/// Alpha-renames every callee-bound name to a fresh `…$inl<n>` name, substitutes each param with
/// its atomic `Value` arg, rewrites every `Return(vs)` to `Break(exit_label, vs)`, and wraps the
/// result in `Block(exit_label, f.result, …)`. The counter in `st` is advanced past every name
/// minted (one per bound name + one for the exit label); the budget is left untouched (the
/// caller already charged `node_count(f.body)`).
///
/// - `f`: the callee.
/// - `args`: the call's argument `Value`s (length already matched to `f.params`).
/// - `st`: the state carrying the fresh-name counter.
/// - Return: `#(inlined_block, state_with_advanced_counter)`. Total.
fn build_inline(
  f: ir.Function,
  args: List(ir.Value),
  st: InlineState,
) -> #(ir.Expr, InlineState) {
  let param_names = list.map(f.params, fn(l) { l.name })
  let subst = list.zip(param_names, args)
  let bound = list.unique(collect_bound_names(f.body))
  let #(rename, counter1) = build_rename(bound, st.counter)
  let exit_label = "exit$inl" <> int.to_string(counter1)
  let counter2 = counter1 + 1
  let body1 = apply_rename_subst(f.body, rename, subst)
  let body2 = rewrite_returns(body1, exit_label)
  let block = ir.Block(exit_label, f.result, body2)
  #(block, InlineState(budget: st.budget, counter: counter2))
}

/// Assign each bound `name` a fresh `name$inl<n>` starting at `base`. Returns the rename map and
/// the next unused counter.
fn build_rename(
  bound: List(String),
  base: Int,
) -> #(Dict(String, String), Int) {
  let #(pairs, next) =
    list.fold(bound, #([], base), fn(acc, name) {
      let #(ps, n) = acc
      let fresh = name <> "$inl" <> int.to_string(n)
      #([#(name, fresh), ..ps], n + 1)
    })
  #(dict.from_list(pairs), next)
}

/// Rewrite every `Return(vs)` in `e` to `Break(exit_label, vs)` (the single-exit rewrite).
/// `exit_label` is fresh, so it cannot pre-exist in `e`; other transfers are untouched.
fn rewrite_returns(e: ir.Expr, exit_label: String) -> ir.Expr {
  map_expr(e, fn(node) {
    case node {
      ir.Return(vs) -> ir.Break(exit_label, vs)
      other -> other
    }
  })
}

/// Whether a `CallDirect` to `fname` is eligible to inline (heuristic gate + recursion + defined
/// guards; the budget affordability check is applied separately at the call site).
///
/// - `fname`: the callee name.
/// - `ctx`: the resolution context.
/// - Return: `True` iff `fname` is defined, non-recursive, and leaf / small / single-call-site.
///   Total.
fn eligible(fname: String, ctx: InlineCtx) -> Bool {
  case dict.get(ctx.by_name, fname) {
    Error(Nil) -> False
    Ok(f) ->
      // Phase-13 (Q13-05): a callee whose body contains ANY tail-call node (`ReturnCall*`) is NOT
      // inline-eligible — treated exactly like a recursive function. Inlining a tail-call-containing
      // body would splice a FUNCTION-level bottom transfer into the caller (wrong value + broken
      // stack, since `rewrite_returns` rewrites `Return` but not `ReturnCall*`), and the
      // `CallDirect`-only recursion detector cannot see a `return_call` cycle (it would look
      // non-recursive → wrongly eligible). Excluding it sidesteps BOTH in one stroke — correctness-
      // preserving (OptNone ≡ Baseline ≡ Aggressive), costing at most a missed inline.
      case set.contains(ctx.recursive, fname) || has_tail_call(f.body) {
        True -> False
        False -> {
          let leaf = !has_any_call(f.body)
          let small = node_count(f.body) <= small_body_nodes
          let single = result.unwrap(dict.get(ctx.sites, fname), 0) == 1
          leaf || small || single
        }
      }
  }
}

/// Does `e` contain ANY Phase-13 tail-call node (`ReturnCall` / `ReturnCallIndirect` /
/// `ReturnCallImport`)? Recurses into EVERY sub-expression (including `Try`), so the exclusion is
/// fail-closed: a tail call anywhere in the body makes the callee inline-ineligible (§Q13-05).
fn has_tail_call(e: ir.Expr) -> Bool {
  case e {
    ir.ReturnCall(_, _)
    | ir.ReturnCallIndirect(_, _, _, _)
    | ir.ReturnCallRef(_, _)
    | ir.ReturnCallImport(_, _, _) -> True
    ir.Let(_, rhs, body) -> has_tail_call(rhs) || has_tail_call(body)
    ir.Block(_, _, body) -> has_tail_call(body)
    ir.Loop(_, _, _, body) -> has_tail_call(body)
    ir.If(_, _, then_branch, else_branch) ->
      has_tail_call(then_branch) || has_tail_call(else_branch)
    ir.Switch(_, _, arms, default) ->
      list.any(arms, fn(a) { has_tail_call(a.body) }) || has_tail_call(default)
    ir.Charge(_, body) -> has_tail_call(body)
    ir.Try(_, body, handlers) ->
      has_tail_call(body)
      || list.any(handlers, fn(h) { has_tail_call(h.handler) })
    _ -> False
  }
}

// ─────────────────────────── rename / substitution walk ───────────────────────────

/// Apply the alpha-`rename` (bound names → fresh) and param `subst` (name → arg `Value`) to `e`
/// in one traversal. Binding positions (`Let`/`Block`/`Loop` labels + loop-param names) are
/// renamed; `Var` uses resolve param → arg first, then bound → fresh, else unchanged; module
/// globals and function names are never renamed. Capture-free because the fresh names are unique
/// in the whole caller.
fn apply_rename_subst(
  e: ir.Expr,
  rename: Dict(String, String),
  subst: List(#(String, ir.Value)),
) -> ir.Expr {
  case e {
    ir.Values(vs) -> ir.Values(rs_values(vs, rename, subst))
    ir.Num(op, args) -> ir.Num(op, rs_values(args, rename, subst))
    ir.Convert(op, arg) -> ir.Convert(op, rs_value(arg, rename, subst))
    ir.TermOp(op, args) -> ir.TermOp(op, rs_values(args, rename, subst))
    // Phase-8 map layer: rewrite the `Value` operands (the `op` is static). Pure, so a pass may
    // hoist/CSE it (`ir/effect`); the operand rewrite happens here.
    ir.MapOp(op, args) -> ir.MapOp(op, rs_values(args, rename, subst))
    // Phase-8 term classification + native number arithmetic (unit 06): rewrite the `Value`
    // operands (the `kind`/`op` are static). `TermTest`/`TermTag` are pure; `NumTerm` is a barrier
    // (`ir/effect`) — but this operand-rewrite is unconditional (it does not move the node), and
    // none of the three calls user code, so no `has_any_call` arm is needed.
    ir.TermTest(kind, arg) -> ir.TermTest(kind, rs_value(arg, rename, subst))
    ir.TermTag(arg) -> ir.TermTag(rs_value(arg, rename, subst))
    ir.NumTerm(op, lhs, rhs) ->
      ir.NumTerm(op, rs_value(lhs, rename, subst), rs_value(rhs, rename, subst))
    ir.MemSize(_) -> e
    ir.MemGrow(mem, delta) -> ir.MemGrow(mem, rs_value(delta, rename, subst))
    ir.MemLoad(mem, op, addr, offset, result) ->
      ir.MemLoad(mem, op, rs_value(addr, rename, subst), offset, result)
    ir.MemStore(mem, op, addr, value, offset) ->
      ir.MemStore(
        mem,
        op,
        rs_value(addr, rename, subst),
        rs_value(value, rename, subst),
        offset,
      )
    // Phase-10 unchecked accesses (N4): rewrite their `Value` operands exactly like the checked
    // twins (the `mem`/`op`/`offset`/`result` are static).
    ir.MemLoadUnchecked(mem, op, addr, offset, result) ->
      ir.MemLoadUnchecked(
        mem,
        op,
        rs_value(addr, rename, subst),
        offset,
        result,
      )
    ir.MemStoreUnchecked(mem, op, addr, value, offset) ->
      ir.MemStoreUnchecked(
        mem,
        op,
        rs_value(addr, rename, subst),
        rs_value(value, rename, subst),
        offset,
      )
    // ── Phase-5 reference/table/bulk nodes: rewrite their `Value` operands so an inlined
    // callee's params are substituted into them (their names/segment indices are static). ──
    ir.RefFunc(_) -> e
    // Phase-14 `RefFuncImport` (R1): a static slot + type — no `Value` operands to rewrite.
    ir.RefFuncImport(_, _) -> e
    ir.RefIsNull(arg) -> ir.RefIsNull(rs_value(arg, rename, subst))
    ir.TableGet(table, index) ->
      ir.TableGet(table, rs_value(index, rename, subst))
    ir.TableSet(table, index, value) ->
      ir.TableSet(
        table,
        rs_value(index, rename, subst),
        rs_value(value, rename, subst),
      )
    ir.TableSize(_) -> e
    ir.TableGrow(table, delta, init) ->
      ir.TableGrow(
        table,
        rs_value(delta, rename, subst),
        rs_value(init, rename, subst),
      )
    ir.TableFill(table, offset, value, count) ->
      ir.TableFill(
        table,
        rs_value(offset, rename, subst),
        rs_value(value, rename, subst),
        rs_value(count, rename, subst),
      )
    ir.TableInit(table, seg, dst, src, count) ->
      ir.TableInit(
        table,
        seg,
        rs_value(dst, rename, subst),
        rs_value(src, rename, subst),
        rs_value(count, rename, subst),
      )
    ir.TableCopy(dst_table, src_table, dst, src, count) ->
      ir.TableCopy(
        dst_table,
        src_table,
        rs_value(dst, rename, subst),
        rs_value(src, rename, subst),
        rs_value(count, rename, subst),
      )
    ir.ElemDrop(_) -> e
    ir.MemFill(mem, dest, value, count) ->
      ir.MemFill(
        mem,
        rs_value(dest, rename, subst),
        rs_value(value, rename, subst),
        rs_value(count, rename, subst),
      )
    ir.MemCopy(dst_mem, src_mem, dst, src, count) ->
      ir.MemCopy(
        dst_mem,
        src_mem,
        rs_value(dst, rename, subst),
        rs_value(src, rename, subst),
        rs_value(count, rename, subst),
      )
    ir.MemInit(mem, seg, dst, src, count) ->
      ir.MemInit(
        mem,
        seg,
        rs_value(dst, rename, subst),
        rs_value(src, rename, subst),
        rs_value(count, rename, subst),
      )
    ir.DataDrop(_) -> e
    ir.GlobalGet(_) -> e
    ir.GlobalSet(name, value) ->
      ir.GlobalSet(name, rs_value(value, rename, subst))
    ir.CallDirect(fn_name, cargs) ->
      ir.CallDirect(fn_name, rs_values(cargs, rename, subst))
    // ── Phase-8 native closures: rewrite their `Value` operands so an inlined callee's params are
    // substituted into the captures / callee / args (the `fn_name` and `arity` are static). ──
    ir.MakeClosure(fn_name, captures, arity) ->
      ir.MakeClosure(fn_name, rs_values(captures, rename, subst), arity)
    ir.CallClosure(callee, cargs) ->
      ir.CallClosure(
        rs_value(callee, rename, subst),
        rs_values(cargs, rename, subst),
      )
    ir.CallIndirect(table, index, ty, cargs) ->
      ir.CallIndirect(
        table,
        rs_value(index, rename, subst),
        ty,
        rs_values(cargs, rename, subst),
      )
    ir.CallHost(cap, name, cargs) ->
      ir.CallHost(cap, name, rs_values(cargs, rename, subst))
    ir.Let(names, rhs, body) ->
      ir.Let(
        list.map(names, fn(n) { rename_name(n, rename) }),
        apply_rename_subst(rhs, rename, subst),
        apply_rename_subst(body, rename, subst),
      )
    ir.Block(label, result, body) ->
      ir.Block(
        rename_name(label, rename),
        result,
        apply_rename_subst(body, rename, subst),
      )
    ir.Loop(label, params, result, body) ->
      ir.Loop(
        rename_name(label, rename),
        list.map(params, fn(p) {
          ir.LoopParam(
            ..p,
            name: rename_name(p.name, rename),
            init: rs_value(p.init, rename, subst),
          )
        }),
        result,
        apply_rename_subst(body, rename, subst),
      )
    ir.If(cond, result, then_branch, else_branch) ->
      ir.If(
        rs_value(cond, rename, subst),
        result,
        apply_rename_subst(then_branch, rename, subst),
        apply_rename_subst(else_branch, rename, subst),
      )
    ir.Switch(sel, result, arms, default) ->
      ir.Switch(
        rs_value(sel, rename, subst),
        result,
        list.map(arms, fn(a) {
          ir.SwitchArm(..a, body: apply_rename_subst(a.body, rename, subst))
        }),
        apply_rename_subst(default, rename, subst),
      )
    ir.Break(label, values) ->
      ir.Break(rename_name(label, rename), rs_values(values, rename, subst))
    ir.Continue(label, values) ->
      ir.Continue(rename_name(label, rename), rs_values(values, rename, subst))
    ir.Return(values) -> ir.Return(rs_values(values, rename, subst))
    ir.Trap(_) -> e
    ir.Charge(cost, body) ->
      ir.Charge(cost, apply_rename_subst(body, rename, subst))
    // ── Phase-6 SIMD nodes + `CallImport`: rewrite their `Value` operands (their op tag / lane
    // immediates / mem index / import slot are static). ──
    ir.Simd(op, sargs) -> ir.Simd(op, rs_values(sargs, rename, subst))
    ir.Gc(op, gargs) -> ir.Gc(op, rs_values(gargs, rename, subst))
    ir.SimdShuffle(lanes, a, b) ->
      ir.SimdShuffle(
        lanes,
        rs_value(a, rename, subst),
        rs_value(b, rename, subst),
      )
    ir.SimdLoad(mem, kind, addr, offset) ->
      ir.SimdLoad(mem, kind, rs_value(addr, rename, subst), offset)
    ir.SimdStore(mem, addr, value, offset) ->
      ir.SimdStore(
        mem,
        rs_value(addr, rename, subst),
        rs_value(value, rename, subst),
        offset,
      )
    ir.SimdLoadLane(mem, width, addr, offset, lane, vec) ->
      ir.SimdLoadLane(
        mem,
        width,
        rs_value(addr, rename, subst),
        offset,
        lane,
        rs_value(vec, rename, subst),
      )
    ir.SimdStoreLane(mem, width, addr, offset, lane, vec) ->
      ir.SimdStoreLane(
        mem,
        width,
        rs_value(addr, rename, subst),
        offset,
        lane,
        rs_value(vec, rename, subst),
      )
    ir.CallImport(slot, ty, cargs) ->
      ir.CallImport(slot, ty, rs_values(cargs, rename, subst))
    // ── Phase-13 tail calls: rewrite their `Value` operands (the indirect `index` + the args);
    // the `fn_name`/`table`/`slot`/`ty` are static. Value-only bottom transfers, like
    // `CallImport`/`CallIndirect`. Never CSE/hoist/DCE across them (barriers, from `effect`). ──
    ir.ReturnCall(fn_name, cargs) ->
      ir.ReturnCall(fn_name, rs_values(cargs, rename, subst))
    ir.ReturnCallIndirect(table, index, ty, cargs) ->
      ir.ReturnCallIndirect(
        table,
        rs_value(index, rename, subst),
        ty,
        rs_values(cargs, rename, subst),
      )
    ir.ReturnCallRef(funcref, cargs) ->
      ir.ReturnCallRef(
        rs_value(funcref, rename, subst),
        rs_values(cargs, rename, subst),
      )
    ir.ReturnCallImport(slot, ty, cargs) ->
      ir.ReturnCallImport(slot, ty, rs_values(cargs, rename, subst))
    // ── Phase-7 EH nodes: rewrite their `Value` operands (the tag NAME is static). `Try`
    // recurses into its body + each handler's inline handler expression (the handler's own
    // `payload`/`exnref` binders are left untouched — a static-name introduction). Conservative:
    // no Phase-1..6 module has these nodes, so this is byte-neutral. ──
    ir.Throw(tag, args) -> ir.Throw(tag, rs_values(args, rename, subst))
    ir.ThrowRef(exnref) -> ir.ThrowRef(rs_value(exnref, rename, subst))
    ir.Try(result, body, handlers) ->
      ir.Try(
        result,
        apply_rename_subst(body, rename, subst),
        list.map(handlers, fn(h) {
          ir.CatchHandler(
            ..h,
            handler: apply_rename_subst(h.handler, rename, subst),
          )
        }),
      )
  }
}

/// Resolve one bound name through the alpha-`rename` map; an unmapped name is unchanged.
fn rename_name(n: String, rename: Dict(String, String)) -> String {
  case dict.get(rename, n) {
    Ok(fresh) -> fresh
    Error(Nil) -> n
  }
}

/// Resolve one `Value`: a `Var` bound as a callee param becomes its arg `Value`; a `Var` bound
/// inside the callee becomes its renamed `Var`; every other `Value` (constants, a global-free
/// unmapped `Var`) is unchanged.
fn rs_value(
  v: ir.Value,
  rename: Dict(String, String),
  subst: List(#(String, ir.Value)),
) -> ir.Value {
  case v {
    ir.Var(n) ->
      case list.key_find(subst, n) {
        Ok(arg) -> arg
        Error(Nil) ->
          case dict.get(rename, n) {
            Ok(fresh) -> ir.Var(fresh)
            Error(Nil) -> v
          }
      }
    _ -> v
  }
}

/// Map `rs_value` over a list of operands.
fn rs_values(
  vs: List(ir.Value),
  rename: Dict(String, String),
  subst: List(#(String, ir.Value)),
) -> List(ir.Value) {
  list.map(vs, fn(v) { rs_value(v, rename, subst) })
}

// ─────────────────────────── IR analyses (graph / counts / names) ───────────────────────────

/// Every name BOUND inside `e`: `Let` names, `Block`/`Loop` labels, and loop-param names. These
/// are exactly the names inlining must alpha-rename to avoid capture.
fn collect_bound_names(e: ir.Expr) -> List(String) {
  case e {
    ir.Let(names, rhs, body) ->
      list.append(
        names,
        list.append(collect_bound_names(rhs), collect_bound_names(body)),
      )
    ir.Block(label, _, body) -> [label, ..collect_bound_names(body)]
    ir.Loop(label, params, _, body) -> [
      label,
      ..list.append(
        list.map(params, fn(p) { p.name }),
        collect_bound_names(body),
      )
    ]
    ir.If(_, _, then_branch, else_branch) ->
      list.append(
        collect_bound_names(then_branch),
        collect_bound_names(else_branch),
      )
    ir.Switch(_, _, arms, default) ->
      list.append(
        list.flat_map(arms, fn(a) { collect_bound_names(a.body) }),
        collect_bound_names(default),
      )
    ir.Charge(_, body) -> collect_bound_names(body)
    _ -> []
  }
}

/// The Expr-node count of `e` (each node counts 1; structured forms add their sub-nodes). The
/// callee's cost used by the budget and the small-body heuristic.
fn node_count(e: ir.Expr) -> Int {
  case e {
    ir.Let(_, rhs, body) -> 1 + node_count(rhs) + node_count(body)
    ir.Block(_, _, body) -> 1 + node_count(body)
    ir.Loop(_, _, _, body) -> 1 + node_count(body)
    ir.If(_, _, then_branch, else_branch) ->
      1 + node_count(then_branch) + node_count(else_branch)
    ir.Switch(_, _, arms, default) ->
      list.fold(arms, 1 + node_count(default), fn(acc, a) {
        acc + node_count(a.body)
      })
    ir.Charge(_, body) -> 1 + node_count(body)
    _ -> 1
  }
}

/// The total Expr-node count across every function body — the base for the size budget.
fn module_node_count(funcs: List(ir.Function)) -> Int {
  list.fold(funcs, 0, fn(acc, f) { acc + node_count(f.body) })
}

/// Does `e` contain ANY call (`CallDirect`/`CallIndirect`/`CallHost`)? A body with none is a
/// leaf callee (always inlining-eligible).
fn has_any_call(e: ir.Expr) -> Bool {
  case e {
    // A `CallClosure` applies a fun value — a call, like the other three (Phase-8, K3).
    // `MakeClosure` merely BUILDS a fun (no transfer of control), so it is NOT a call.
    ir.CallDirect(_, _)
    | ir.CallIndirect(_, _, _, _)
    | ir.CallHost(_, _, _)
    | ir.CallClosure(_, _)
    | // Phase-13 (Q13-05): the tail-call nodes are calls too (a body containing one is not a leaf).
      ir.ReturnCall(_, _)
    | ir.ReturnCallIndirect(_, _, _, _)
    | ir.ReturnCallRef(_, _)
    | ir.ReturnCallImport(_, _, _) -> True
    ir.Let(_, rhs, body) -> has_any_call(rhs) || has_any_call(body)
    ir.Block(_, _, body) -> has_any_call(body)
    ir.Loop(_, _, _, body) -> has_any_call(body)
    ir.If(_, _, then_branch, else_branch) ->
      has_any_call(then_branch) || has_any_call(else_branch)
    ir.Switch(_, _, arms, default) ->
      list.any(arms, fn(a) { has_any_call(a.body) }) || has_any_call(default)
    ir.Charge(_, body) -> has_any_call(body)
    _ -> False
  }
}

/// Every `CallDirect` target name in `e` (with duplicates — one per site).
fn calldirect_names(e: ir.Expr) -> List(String) {
  case e {
    ir.CallDirect(name, _) -> [name]
    ir.Let(_, rhs, body) ->
      list.append(calldirect_names(rhs), calldirect_names(body))
    ir.Block(_, _, body) -> calldirect_names(body)
    ir.Loop(_, _, _, body) -> calldirect_names(body)
    ir.If(_, _, then_branch, else_branch) ->
      list.append(calldirect_names(then_branch), calldirect_names(else_branch))
    ir.Switch(_, _, arms, default) ->
      list.append(
        list.flat_map(arms, fn(a) { calldirect_names(a.body) }),
        calldirect_names(default),
      )
    ir.Charge(_, body) -> calldirect_names(body)
    _ -> []
  }
}

/// `fn_name -> number of CallDirect sites` across every function body in `funcs`.
fn count_calls_module(funcs: List(ir.Function)) -> Dict(String, Int) {
  list.fold(funcs, dict.new(), fn(acc, f) {
    list.fold(calldirect_names(f.body), acc, fn(d, name) {
      dict.insert(d, name, result.unwrap(dict.get(d, name), 0) + 1)
    })
  })
}

/// The `CallDirect` call graph restricted to defined functions: `fn_name -> deduped list of
/// defined callees`. Imports (`CallHost`) and indirect calls are excluded — inlining only ever
/// touches same-module direct calls.
fn build_call_graph(
  funcs: List(ir.Function),
  by_name: Dict(String, ir.Function),
) -> Dict(String, List(String)) {
  list.fold(funcs, dict.new(), fn(acc, f) {
    let callees =
      calldirect_names(f.body)
      |> list.filter(fn(n) { dict.has_key(by_name, n) })
      |> list.unique
    dict.insert(acc, f.name, callees)
  })
}

/// The set of function names that are self-recursive or on a `CallDirect` cycle — i.e. every `f`
/// reachable from itself via ≥ 1 call edge. These are never inlined (the acyclic termination
/// guard).
fn recursive_names(
  funcs: List(ir.Function),
  graph: Dict(String, List(String)),
) -> Set(String) {
  let n = list.length(funcs)
  // A generous step bound (never reached in practice); `closure` also terminates naturally when
  // the visited set stops growing.
  let fuel = n * n + n + 100
  list.fold(funcs, set.new(), fn(acc, f) {
    let start = result.unwrap(dict.get(graph, f.name), [])
    let reach = closure(start, graph, set.new(), fuel)
    case set.contains(reach, f.name) {
      True -> set.insert(acc, f.name)
      False -> acc
    }
  })
}

/// Transitive closure (reachable set) over the call `graph` from a `frontier`, bounded by
/// `fuel`. Total — terminates when the frontier empties, the visited set is saturated, or the
/// fuel runs out.
fn closure(
  frontier: List(String),
  graph: Dict(String, List(String)),
  visited: Set(String),
  fuel: Int,
) -> Set(String) {
  case fuel <= 0 {
    True -> visited
    False ->
      case frontier {
        [] -> visited
        [x, ..rest] ->
          case set.contains(visited, x) {
            True -> closure(rest, graph, visited, fuel - 1)
            False -> {
              let visited2 = set.insert(visited, x)
              let succ = result.unwrap(dict.get(graph, x), [])
              closure(list.append(succ, rest), graph, visited2, fuel - 1)
            }
          }
      }
  }
}

// ─────────────────────────── orphan deletion ───────────────────────────

/// The names a function must NOT be deleted for even when orphaned: exported functions, the
/// start function, and any function named in an element segment (reachable via `CallIndirect`).
fn protected_names(module: ir.Module) -> Set(String) {
  // Only FUNCTION exports protect a function; exported state (global/table/memory) names no
  // function (H4).
  let exported =
    list.filter_map(module.exports, fn(x) {
      case x {
        ir.ExportFn(_, fn_name) -> Ok(fn_name)
        // Exported state (global/table/memory) + a Phase-7 exported TAG name no function (H4/T2),
        // so none protects a function from orphan deletion.
        ir.ExportGlobal(..)
        | ir.ExportTable(..)
        | ir.ExportMemory(..)
        | ir.ExportTag(..) -> Error(Nil)
      }
    })
  let started = case module.start {
    option.Some(s) -> [s]
    option.None -> []
  }
  // A function named by a `ref.func` element item is reachable via `CallIndirect`/`ref.func`,
  // so it must not be deleted. Element items are ref-expressions now (H2); collect the
  // `RefFunc` targets (a `ConstNull` item names no function).
  let element_refs =
    list.flat_map(module.elements, fn(el) {
      list.filter_map(el.init, fn(item) {
        case item {
          ir.RefFunc(fn_name) -> Ok(fn_name)
          _ -> Error(Nil)
        }
      })
    })
  set.from_list(list.append(exported, list.append(started, element_refs)))
}

/// Keep function `name` unless it became orphaned by inlining — i.e. it WAS called in the input
/// but is no longer called in the output — and is not protected. Pre-existing dead functions
/// (never called) are left untouched.
fn keep_function(
  name: String,
  input_sites: Dict(String, Int),
  output_sites: Dict(String, Int),
  protected: Set(String),
) -> Bool {
  let was_called = result.unwrap(dict.get(input_sites, name), 0) > 0
  let still_called = result.unwrap(dict.get(output_sites, name), 0) > 0
  let became_orphan = was_called && !still_called
  !became_orphan || set.contains(protected, name)
}

// ─────────────────────────── fresh-name seeding ───────────────────────────

/// One more than the largest `$inl<n>` counter already bound anywhere in `funcs`, or `0` if
/// there are none. Seeding the fresh counter above this makes every generated name globally
/// unique across fixpoint rounds (a name dropped by a later baseline pass cannot be re-minted).
fn max_inl_counter_module(funcs: List(ir.Function)) -> Int {
  list.fold(funcs, -1, fn(acc, f) {
    list.fold(collect_bound_names(f.body), acc, fn(m, name) {
      int.max(m, inl_counter(name))
    })
  })
}

/// The `<n>` suffix of a `…$inl<n>` name, or `-1` when `name` carries no such suffix.
fn inl_counter(name: String) -> Int {
  case string.contains(name, "$inl") {
    False -> -1
    True ->
      case list.last(string.split(name, "$inl")) {
        Ok(tail) ->
          case int.parse(tail) {
            Ok(n) -> n
            Error(Nil) -> -1
          }
        Error(Nil) -> -1
      }
  }
}
