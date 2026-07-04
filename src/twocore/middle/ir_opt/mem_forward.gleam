//// `middle/ir_opt/mem_forward` — store→load forwarding + redundant-load elimination (Phase-9
//// unit 02, M1/M3).
////
//// **ONE pass, ONE reaching-value map.** Store→load forwarding and redundant-load elimination are
//// the *same* transfer function: a load is served from the `avail` map whether the entry came from
//// a preceding store (forwarding) or a preceding load (RLE). The pass threads one `mem_ssa.Avail`
//// map front-to-back through each **straight-line region** and rewrites a natural-width load whose
//// footprint is already known to `Values([that_value])` — the `MemLoad` node is GONE (baseline
//// copy-prop drops the residual `Let([y], Values([v]), …)` on the next fixpoint round).
////
//// ## Soundness (M3, trap-preservation — the whole story)
////
//// A WASM `MemLoad`/`MemStore` is **trap-or-access**, not a pure read/write. Forwarding/RLE are
//// sound because a **dominating successful access in the same straight-line region proves the
//// address in-bounds**: the store/first-load succeeded (else control left the region and the
//// forwarded value is never observed), so the must-alias later load is at the same in-bounds
//// address and — with no clobber between — reads the same bits. The pass NEVER reorders an effect
//// and NEVER introduces a call/`apply` (D3a); it only removes/replaces a load. See the truncation
//// guard (`store_writes_full_value`/`is_natural_width`) for why forwarding is bit-exact even across
//// value types (D5: raw-bit-pattern scalars).
////
//// ## The region discipline (M5/M8)
////
//// The analysis is **per straight-line region**: the walk threads `avail` through a `Let`-chain but
//// **resets it (empty) at every control-flow boundary** (`If`/`Switch`/`Loop`/`Block`/`Try`) — it
//// recurses into those as fresh regions so their interiors are still optimized, but carries no
//// memory knowledge across them (cross-control-flow MemorySSA is Phase-9 §6 deferred work). A
//// `mem_ssa.is_memory_barrier` node (a call, `MemGrow`, a bulk/SIMD-mem op, a control transfer)
//// clears the map. `Charge` is memory-transparent (fuel only), so `avail` threads through its body.
////
//// Imports `{ir, ir/effect-free via mem_ssa, pass, mem_ssa, dict, list}` — all acyclic (none
//// imports `ir_opt`). It performs no analysis of its own: `Footprint`/`alias`/`is_memory_barrier`/
//// `byte_width` all come from the frozen `mem_ssa` keystone.

import gleam/dict.{type Dict}
import gleam/list
import twocore/ir.{type Expr, type ValType, type Value}
import twocore/middle/ir_opt/mem_ssa.{type Avail, type Footprint, NoAlias}
import twocore/middle/ir_opt/pass.{type Pass}

/// The store→load-forwarding + redundant-load-elimination pass (M1/M3). A whole-module `pass.pass`
/// whose core is a per-function straight-line-region walk: it precomputes the module's global
/// name→type table (needed by the truncation guard for `GlobalGet` results), then walks each
/// function body seeded with `params ++ locals` as the name→type environment and an empty `avail`.
///
/// - Return: the `Pass` value unit 04 appends to the `Baseline` pipeline (inherited by
///   `Aggressive`). Semantics-preserving (F2/M3). Total — never fails.
pub fn forwarding_pass() -> Pass {
  pass.pass("mem-forward", fn(m) {
    let globals = global_types(m)
    ir.Module(
      ..m,
      functions: list.map(m.functions, fn(f) {
        let types0 = seed_types(f)
        ir.Function(
          ..f,
          body: forward_region(f.body, dict.new(), types0, globals),
        )
      }),
    )
  })
}

// ───────────────────────────── the region walk ─────────────────────────────

/// Walk one straight-line region front-to-back, threading `(avail, types)` from each `Let` binding
/// into its body. `avail` is the reaching-value map (empty at a region head); `types` the name→type
/// environment (for the truncation guard); `globals` the module global types.
///
/// - `Let(names, rhs, body)`: rewrite `rhs` in-context (forwarding a load hit, updating `avail` on a
///   store/load, clearing it on a barrier), extend `types` with the binding, and thread the result
///   into `body`.
/// - `Charge(cost, body)`: memory-transparent — thread `avail` unchanged into `body` (charging fuel
///   cannot touch linear memory).
/// - anything else ends the region (a control-flow head or a leaf) — handled by `region_tail`.
fn forward_region(
  e: Expr,
  avail: Avail,
  types: Dict(String, ValType),
  globals: Dict(String, ValType),
) -> Expr {
  case e {
    ir.Let(names, rhs, body) -> {
      let #(rhs2, avail2) = rewrite_rhs(names, rhs, avail, types, globals)
      let types2 = extend_types(types, names, rhs, globals)
      ir.Let(names, rhs2, forward_region(body, avail2, types2, globals))
    }
    ir.Charge(cost, body) ->
      ir.Charge(cost, forward_region(body, avail, types, globals))
    _ -> region_tail(e, avail, types, globals)
  }
}

/// Rewrite a `Let`'s `rhs` in the current region state, returning the rewritten `rhs` and the
/// `avail` to thread into the binding's body. The transfer function proper (§B of the unit doc).
///
/// - a **natural-width** `MemLoad(F)` that HITS `avail` → `Values([v])` (forward/RLE; the load is
///   gone); a MISS records `avail[F] = Var(bound_name)` for later RLE and keeps the load;
/// - a `MemStore(F, value)` INVALIDATES every aliasing `avail` key (keeps `NoAlias` — the disjoint
///   disambiguation) and INSERTS `avail[F] = value` only when the store writes its value un-narrowed
///   (the truncation guard);
/// - a control-flow head recurses into its sub-regions FRESH and clears `avail` for the
///   continuation; an opaque barrier clears `avail`; a transparent op leaves `avail` unchanged.
fn rewrite_rhs(
  names: List(String),
  rhs: Expr,
  avail: Avail,
  types: Dict(String, ValType),
  globals: Dict(String, ValType),
) -> #(Expr, Avail) {
  case rhs {
    ir.MemLoad(_, op, _, _, result) ->
      case is_natural_width(op, result), mem_ssa.footprint_of(rhs) {
        True, Ok(f) ->
          case dict.get(avail, f) {
            // HIT: the value at F is exactly `v` (equal footprint ⟹ MustAlias). Forward it.
            Ok(v) -> #(ir.Values([v]), avail)
            // MISS: record this load as a future RLE source (loads bind exactly one name).
            Error(_) ->
              case names {
                [y] -> #(rhs, dict.insert(avail, f, ir.Var(y)))
                _ -> #(rhs, avail)
              }
          }
        // sub-width load (e.g. i32.load8_u): never forwarded, never a source.
        _, _ -> #(rhs, avail)
      }
    ir.MemStore(_, op, _, value, _) ->
      case mem_ssa.footprint_of(rhs) {
        Ok(f) -> #(rhs, store_update(avail, f, op, value, types))
        Error(_) -> #(rhs, dict.new())
      }
    // control-flow head bound to a name: recurse into it FRESH, clear `avail` for the continuation
    // (either branch may have written memory).
    ir.If(..) | ir.Switch(..) | ir.Loop(..) | ir.Block(..) | ir.Try(..) -> #(
      optimize_control(rhs, types, globals),
      dict.new(),
    )
    // a rhs-position Charge (rare): recurse its inner FRESH and clear (conservative — the inner may
    // store).
    ir.Charge(cost, inner) -> #(
      ir.Charge(cost, forward_region(inner, dict.new(), types, globals)),
      dict.new(),
    )
    _ ->
      case mem_ssa.is_memory_barrier(rhs) {
        // opaque barrier (a call, MemGrow, a bulk/SIMD-mem op, a control transfer): forget memory.
        True -> #(rhs, dict.new())
        // memory-transparent (globals, MemSize, pure value ops): avail unchanged.
        False -> #(rhs, avail)
      }
  }
}

/// Handle an expression that ENDS a straight-line region (the tail of a `Let`-chain, or a body that
/// is not a `Let`/`Charge`): forward a natural-width tail load if it hits `avail`, recurse into a
/// control-flow head as fresh regions, and leave any other leaf unchanged.
fn region_tail(
  e: Expr,
  avail: Avail,
  types: Dict(String, ValType),
  globals: Dict(String, ValType),
) -> Expr {
  case e {
    ir.MemLoad(_, op, _, _, result) ->
      case is_natural_width(op, result), mem_ssa.footprint_of(e) {
        True, Ok(f) ->
          case dict.get(avail, f) {
            Ok(v) -> ir.Values([v])
            Error(_) -> e
          }
        _, _ -> e
      }
    ir.If(..) | ir.Switch(..) | ir.Loop(..) | ir.Block(..) | ir.Try(..) ->
      optimize_control(e, types, globals)
    _ -> e
  }
}

/// Recurse into a control-flow head's sub-expressions, optimizing each as a **fresh** region
/// (empty `avail`, `types` carried in — loop params added). The per-straight-line-region reset
/// (M5/M8): memory knowledge does not cross a control-flow boundary in Phase 9.
fn optimize_control(
  e: Expr,
  types: Dict(String, ValType),
  globals: Dict(String, ValType),
) -> Expr {
  case e {
    ir.If(cond, result, then_branch, else_branch) ->
      ir.If(
        cond,
        result,
        forward_region(then_branch, dict.new(), types, globals),
        forward_region(else_branch, dict.new(), types, globals),
      )
    ir.Switch(selector, result, arms, default) ->
      ir.Switch(
        selector,
        result,
        list.map(arms, fn(a) {
          ir.SwitchArm(
            ..a,
            body: forward_region(a.body, dict.new(), types, globals),
          )
        }),
        forward_region(default, dict.new(), types, globals),
      )
    ir.Loop(label, params, result, body) ->
      ir.Loop(
        label,
        params,
        result,
        forward_region(body, dict.new(), add_params(types, params), globals),
      )
    ir.Block(label, result, body) ->
      ir.Block(label, result, forward_region(body, dict.new(), types, globals))
    ir.Try(result, body, handlers) ->
      ir.Try(
        result,
        forward_region(body, dict.new(), types, globals),
        list.map(handlers, fn(h) {
          ir.CatchHandler(
            ..h,
            handler: forward_region(h.handler, dict.new(), types, globals),
          )
        }),
      )
    // not a control-flow head — unreachable from the call sites, returned unchanged for totality.
    _ -> e
  }
}

// ───────────────────────────── the store transfer + truncation guard ─────────────────────────────

/// Update `avail` for a `MemStore` at footprint `f`: drop every key that ALIASES `f` (a `MayAlias`/
/// `MustAlias` write clobbers the known value there), keeping only the `NoAlias` keys (the disjoint
/// disambiguation — a store to `base+0`/4B does not clobber the known `base+4`/4B); then insert
/// `avail[f] = value` iff the store writes its value un-narrowed (`store_writes_full_value`).
fn store_update(
  avail: Avail,
  f: Footprint,
  op: ir.MemAccess,
  value: Value,
  types: Dict(String, ValType),
) -> Avail {
  let kept = dict.filter(avail, fn(k, _v) { mem_ssa.alias(k, f) == NoAlias })
  case store_writes_full_value(op, value, types) {
    True -> dict.insert(kept, f, value)
    False -> kept
  }
}

/// Does the store write its whole `value` un-narrowed (so `value` faithfully represents the stored
/// bytes and may be forwarded)? The truncation guard (keystone §C).
///
/// - width 8 / 16 → always full (the only 8/16-byte stores are `i64`/`f64`/`v128.store`).
/// - width 1 / 2 → always truncating (`i{32,64}.store8`/`store16`) — never a forward source.
/// - width 4 → AMBIGUOUS (`i32.store`/`f32.store` are full; `i64.store32` truncates the low 4 bytes
///   of an 8-byte value): full iff the value's type is a **4-byte** type (`byte_width == Ok(4)`).
///   An unknown-typed value is conservatively treated as truncating (no forward — the safe
///   direction).
fn store_writes_full_value(
  op: ir.MemAccess,
  value: Value,
  types: Dict(String, ValType),
) -> Bool {
  case op.bytes {
    8 | 16 -> True
    1 | 2 -> False
    4 ->
      case type_of_value(value, types) {
        Ok(t) -> mem_ssa.byte_width(t) == Ok(4)
        Error(_) -> False
      }
    _ -> False
  }
}

/// Is a load/store of width `op.bytes` the NATURAL width of value type `t` (`op.bytes ==
/// byte_width(t)`)? A natural-width access moves the whole value un-narrowed / un-extended — the
/// forward-target eligibility test for a load (excludes `i32.load8_u` and friends). Reference/term
/// types (`byte_width == Error`) are never natural-width.
fn is_natural_width(op: ir.MemAccess, t: ValType) -> Bool {
  mem_ssa.byte_width(t) == Ok(op.bytes)
}

// ───────────────────────────── the name→type environment ─────────────────────────────

/// The module's global name→declared-type table — the truncation guard's source for a
/// `GlobalGet` result type (which lives on `module.globals`, not the `GlobalGet` node).
fn global_types(m: ir.Module) -> Dict(String, ValType) {
  list.fold(m.globals, dict.new(), fn(acc, g) { dict.insert(acc, g.name, g.ty) })
}

/// Seed the name→type environment from a function's `params ++ locals` (all `Local(name, ty)`) —
/// the names in scope at the body.
fn seed_types(f: ir.Function) -> Dict(String, ValType) {
  add_locals(add_locals(dict.new(), f.params), f.locals)
}

/// Add loop params to the environment (they are in scope inside the loop body).
fn add_params(
  types: Dict(String, ValType),
  params: List(ir.LoopParam),
) -> Dict(String, ValType) {
  list.fold(params, types, fn(acc, p) { dict.insert(acc, p.name, p.ty) })
}

/// Add a list of `Local(name, ty)` slots to the environment.
fn add_locals(
  types: Dict(String, ValType),
  locals: List(ir.Local),
) -> Dict(String, ValType) {
  list.fold(locals, types, fn(acc, l) { dict.insert(acc, l.name, l.ty) })
}

/// Extend `types` with a `Let` binding's names, when the `rhs` result type is statically inferable
/// AND there is exactly one bound name (the common case for the truncation guard). A multi-name or
/// uninferable binding records nothing — the name stays unknown, and an unknown-typed store value is
/// never a forward source (§store_writes_full_value), always the safe direction.
fn extend_types(
  types: Dict(String, ValType),
  names: List(String),
  rhs: Expr,
  globals: Dict(String, ValType),
) -> Dict(String, ValType) {
  case names, infer_binding_type(rhs, types, globals) {
    [name], Ok(t) -> dict.insert(types, name, t)
    _, _ -> types
  }
}

/// Infer the single-value result type of a `Let`'s `rhs`, or `Error(Nil)` when it is not a
/// single-value op with a statically-known type. Covers the forwarding-relevant sources: a load's
/// `result`, a numeric op's result, a conversion's result, a global's declared type, and a
/// `Values([one])` forwarding one atomic value.
fn infer_binding_type(
  rhs: Expr,
  types: Dict(String, ValType),
  globals: Dict(String, ValType),
) -> Result(ValType, Nil) {
  case rhs {
    ir.MemLoad(_, _, _, _, result) -> Ok(result)
    ir.Num(op, _) -> Ok(numop_result_type(op))
    ir.Convert(op, _) -> Ok(convop_result_type(op))
    ir.GlobalGet(name) -> dict.get(globals, name)
    ir.Values([one]) -> type_of_value(one, types)
    _ -> Error(Nil)
  }
}

/// The value type of an atomic `Value`: a `Const*` yields its type directly; a `Var(n)` is looked
/// up in `types` (`Error(Nil)` when unknown). Reference/term consts (`ConstNull`/`ConstAtom`/
/// `ConstBinary`) are not linear-memory scalars → `Error(Nil)`.
fn type_of_value(
  v: Value,
  types: Dict(String, ValType),
) -> Result(ValType, Nil) {
  case v {
    ir.ConstI32(_) -> Ok(ir.TI32)
    ir.ConstI64(_) -> Ok(ir.TI64)
    ir.ConstF32(_) -> Ok(ir.TF32)
    ir.ConstF64(_) -> Ok(ir.TF64)
    ir.ConstV128(_) -> Ok(ir.TV128)
    ir.Var(n) -> dict.get(types, n)
    _ -> Error(Nil)
  }
}

// ── numeric result-type inference (mirrors the frontend `lower`'s private helpers) ──

/// The result value type of a `NumOp`: integer/float comparisons yield `TI32` (a truth value);
/// integer arith/bit ops yield the width's integer type; float arith/unary ops the width's float
/// type. Total; mirrors `frontend/wasm/lower`'s `numop_result_type` (kept in sync by construction —
/// both are exhaustive over `NumOp`).
fn numop_result_type(op: ir.NumOp) -> ValType {
  case op {
    ir.IEqz(_)
    | ir.IEq(_)
    | ir.INe(_)
    | ir.ILtS(_)
    | ir.ILtU(_)
    | ir.IGtS(_)
    | ir.IGtU(_)
    | ir.ILeS(_)
    | ir.ILeU(_)
    | ir.IGeS(_)
    | ir.IGeU(_) -> ir.TI32
    ir.FEq(_) | ir.FNe(_) | ir.FLt(_) | ir.FGt(_) | ir.FLe(_) | ir.FGe(_) ->
      ir.TI32
    ir.IAdd(w)
    | ir.ISub(w)
    | ir.IMul(w)
    | ir.IDivS(w)
    | ir.IDivU(w)
    | ir.IRemS(w)
    | ir.IRemU(w)
    | ir.IAnd(w)
    | ir.IOr(w)
    | ir.IXor(w)
    | ir.IShl(w)
    | ir.IShrS(w)
    | ir.IShrU(w)
    | ir.IRotl(w)
    | ir.IRotr(w)
    | ir.IClz(w)
    | ir.ICtz(w)
    | ir.IPopcnt(w) -> int_width_ty(w)
    ir.FAdd(w)
    | ir.FSub(w)
    | ir.FMul(w)
    | ir.FDiv(w)
    | ir.FMin(w)
    | ir.FMax(w)
    | ir.FAbs(w)
    | ir.FNeg(w)
    | ir.FCeil(w)
    | ir.FFloor(w)
    | ir.FTrunc(w)
    | ir.FNearest(w)
    | ir.FSqrt(w)
    | ir.FCopysign(w) -> float_width_ty(w)
  }
}

/// The result value type of a `ConvOp`. Total; mirrors `frontend/wasm/lower`'s
/// `convop_result_type`. Boxing conversions produce a `TTerm` (which `byte_width` rejects, so a
/// boxed value is correctly never a linear-memory forward source).
fn convop_result_type(op: ir.ConvOp) -> ValType {
  case op {
    ir.I32WrapI64 -> ir.TI32
    ir.I64ExtendI32S | ir.I64ExtendI32U -> ir.TI64
    ir.I32Extend8S | ir.I32Extend16S -> ir.TI32
    ir.I64Extend8S | ir.I64Extend16S | ir.I64Extend32S -> ir.TI64
    ir.TruncSatS(_, to) | ir.TruncSatU(_, to) -> int_width_ty(to)
    ir.TruncS(_, to) | ir.TruncU(_, to) -> int_width_ty(to)
    ir.ConvertS(_, to) | ir.ConvertU(_, to) -> float_width_ty(to)
    ir.ReinterpretFToI(w) -> fwidth_to_int(w)
    ir.ReinterpretIToF(w) -> iwidth_to_float(w)
    ir.F32DemoteF64 -> ir.TF32
    ir.F64PromoteF32 -> ir.TF64
    ir.BoxInt(_) | ir.BoxFloat(_) -> ir.TTerm
    ir.UnboxInt(w) -> int_width_ty(w)
    ir.UnboxFloat(w) -> float_width_ty(w)
  }
}

fn int_width_ty(w: ir.IntWidth) -> ValType {
  case w {
    ir.W32 -> ir.TI32
    ir.W64 -> ir.TI64
  }
}

fn float_width_ty(w: ir.FloatWidth) -> ValType {
  case w {
    ir.FW32 -> ir.TF32
    ir.FW64 -> ir.TF64
  }
}

fn fwidth_to_int(w: ir.FloatWidth) -> ValType {
  case w {
    ir.FW32 -> ir.TI32
    ir.FW64 -> ir.TI64
  }
}

fn iwidth_to_float(w: ir.IntWidth) -> ValType {
  case w {
    ir.W32 -> ir.TF32
    ir.W64 -> ir.TF64
  }
}
