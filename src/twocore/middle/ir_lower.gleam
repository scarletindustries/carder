//// Unit 11a — `ir_lower` — the one middle-end POLICY pass (high-level §4 `M3`, §6).
////
//// `lower/2` is an IR→IR transform that runs *after* the frontend lowering (`lower.gleam`,
//// unit 10) and *before* the backend (`emit_core`, unit 08). It is the build-time
//// capability/stdlib/metering pass — the **only** middle-end pass Phase 1 ships. For a
//// `Safe` binding it does three things, all build-time, all fail-closed (D4/D9):
////
////   1. **`call_host` capability gate (fail-closed).** It classifies every `CallHost`:
////      - a call into the reserved `own`-stdlib capability (`"std"`) is *resolved* against
////        the Phase-1 stdlib surface and its concrete `module:fn/arity` target is gated
////        through the `rt_bif` allowlist. An unknown stdlib name → `UnknownStdlibFn`; a
////        resolved target not on the allowlist (including a wrong arity) → `BifNotAllowed`.
////      - a call to a **declared host import** (a `(capability, name)` present in
////        `module.imports`) is **left unchanged** — it is rejected at RUN time by the
////        deny-all host (`rt_host`), so the capability boundary is exercised end-to-end,
////        not short-circuited at build time (overview pitfall #3).
////      - a call into the reserved JS-runtime capability (`"js"`, Phase-8 unit 05 / K6) is
////        **admitted** here (exactly as a resolved `"std"` call is) and **left unchanged** —
////        its concrete `op → rt_js:<fn>` dispatch, and the fail-closed rejection of an unknown
////        op, are the build-fixed literal `case` in `emit_core` (`resolve_js`/`UnknownJsOp`,
////        D3a). This pass admits the *capability* (provenance); `emit_core` validates the *op*.
////      - a call to anything else — an un-allowlisted capability that is neither the
////        stdlib capability, the JS-runtime capability, nor a declared import — is **rejected
////        here**, fail-closed (`ForbiddenHost`).
////      `CallHost` nodes are not rewritten: the mechanical stdlib-vs-host routing is
////      `emit_core`'s `resolve_stdlib`/`call_host` split (unit 08). This pass is the
////      POLICY gate that decides which calls are *permitted* to reach that router; the
////      two share the same pinned `("std","gcd") → rt_stdlib:gcd/2` triple (state.md),
////      cross-checked against `rt_bif` by a test so they cannot drift.
////
////   2. **Metering insertion (the non-negotiable seam — D9).** Every function body is
////      wrapped in `Charge(fn_cost, body)`, and every `Loop` body in
////      `Charge(loop_cost, body)`, so the metering hook is exercised end-to-end and never
////      has to be retrofitted into codegen later. The cost *values* are a minimal fixed
////      model (their magnitude is irrelevant; the node's presence is the point). `Charge`
////      lowers (unit 08) to `let _ = rt_meter:charge(c) in body`, which neither changes
////      results nor moves a loop back-edge out of tail position — so the constant-space
////      loop property is preserved with metering on.
////
//// ## Phase-3 policy application (F5/F6/F7)
////
//// The pass is now **posture-aware**: it reads the `Binding`'s explicit policy fields
//// (`binding.meter`/`binding.stdlib`/`binding.bif_gate`, F7) — NOT the coarse `binding.mode`
//// — and realises Safe vs Unsafe from one code path:
////   - **metering (F5):** `MeterFuel` inserts `Charge` (the Phase-2 cost model); `MeterOff`
////     inserts NONE (zero-overhead — the emitted `.core` has no charge calls).
////   - **stdlib (F6):** shared-stdlib resolution is delegated to `rt_stdlib.resolve/4`
////     (posture-aware) — `StdlibOwn` → the vetted `own` target, `StdlibPassthrough` → the vetted
////     in-`rt_stdlib` shim (identical to `own` for the Phase-3 `gcd` corpus). The emitted module
////     atom is invariably `binding.stdlib_module`, never a raw BEAM module (F6/D3a).
////   - **BIF gate (F6):** the resolved target is gated through `rt_bif.check_gated/2` —
////     `BifAllowlist` keeps the fail-closed allowlist rejection; `BifOpen` admits any
////     build-controlled resolved target.
//// The Safe posture (`MeterFuel`/`StdlibOwn`/`BifAllowlist`) reproduces the Phase-2 output
//// exactly (byte-identical); the `ForbiddenHost` provenance gate stays fail-closed under EVERY
//// posture (undeclared non-stdlib capabilities are rejected regardless of `host_policy`).
////
//// This module reads `ir.gleam`, the `Binding` type, the build-time `rt_bif` gate, and
//// `rt_stdlib`'s **build-time** routing functions (`shared_surface`/`resolve` — the single
//// source of truth for the shared-stdlib surface; unit 08 retired its local copy). It does
//// **not** import the runtime IMPL modules `rt_trap`/`rt_host`/`rt_meter`, nor does it call
//// `rt_stdlib`'s runtime BODIES — those are invoked by *generated* code at run time, never by
//// this pass (D3a). `rt_bif` and `rt_stdlib`'s routing table are build-time policy data,
//// designed to be consulted here.

import gleam/list
import gleam/set.{type Set}
import twocore/ir.{type Expr, type Function, type Module, type Value}
import twocore/runtime/instance.{type Binding, MeterFuel, MeterOff}
import twocore/runtime/rt_bif
import twocore/runtime/rt_stdlib

// ─────────────────────────────── policy data (build-time) ───────────────────────────────

/// The reserved capability string that names the `own` standard library (high-level §6).
/// A `CallHost` whose capability equals this is a stdlib call and MUST resolve against the
/// stdlib surface (or be rejected); every other capability is a (potential) host import.
/// Pinned with unit 09 / state.md.
pub const stdlib_capability: String = "std"

/// The reserved capability string that names the JS runtime boundary (Phase-8 unit 05, K6).
/// A `CallHost` whose capability equals this is ADMITTED here (exactly as a resolved `"std"`
/// call is admitted) — its concrete `op → rt_js:<fn>` dispatch is the build-fixed literal `case`
/// in `emit_core` (`resolve_js`), where an unknown op FAILS CLOSED (`UnknownJsOp`, D3a — never
/// `apply` from data). This pass admits the CAPABILITY (provenance); `emit_core` validates the
/// OP (dispatch). Every OTHER non-stdlib, non-imported capability still fails closed here
/// (`ForbiddenHost`). Pinned with `emit_core.js_capability` /
/// `specs/phase-8/05-js-runtime-boundary.md`.
pub const js_capability: String = "js"

/// The minimal cost charged once on entry to every function body. The value is arbitrary
/// (D9 — only the metering *seam* matters in Phase 1); kept at `1` so the running fuel
/// total is a readable lower bound on the number of `Charge` sites executed.
pub const fn_cost: Int = 1

/// The minimal cost charged once per `Loop` iteration (re-entry of the loop head). As with
/// `fn_cost` the value is arbitrary; `1` makes fuel grow by exactly one per iteration so a
/// test can assert metering is proportional to loop work.
pub const loop_cost: Int = 1

// ─────────────────────────────── error type (D4) ───────────────────────────────

/// Every reason `lower` rejects a module (this pass's OWN error type — D4, there is no
/// shared `StageError`). `lower` is **total**: a policy violation returns `Error`, never a
/// `panic`/`let assert`.
///
/// - `UnknownStdlibFn(capability, name)`: a `CallHost` into the reserved stdlib capability
///   named a function absent from the `own` surface. Fail-closed.
/// - `BifNotAllowed(name)`: a resolved stdlib `CallHost` would reach a concrete BEAM target
///   not on the `rt_bif` allowlist (e.g. a wrong arity, or a binding whose `stdlib_module`
///   is not the vetted one). Fail-closed.
/// - `ForbiddenHost(capability, name)`: a `CallHost` to a capability that is neither the
///   stdlib capability nor a declared host import in `module.imports` — an un-allowlisted
///   capability with no provenance. Rejected here, fail-closed (a *declared* host import is
///   NOT rejected here; it is denied at run time by `rt_host`).
pub type LowerError {
  UnknownStdlibFn(capability: String, name: String)
  BifNotAllowed(name: String)
  ForbiddenHost(capability: String, name: String)
}

// ─────────────────────────────── entry point ───────────────────────────────

/// Apply the build-time capability/stdlib/metering POLICY to `module`, returning the
/// rewritten module or the FIRST policy violation.
///
/// - `module`: the IR module produced by the frontend lowering (unit 10). Its functions'
///   bodies are walked; `globals`/`imports`/`exports`/`data_segments` are unchanged
///   (Phase-1 globals carry only constant initialisers and contain no `CallHost`/`Loop`).
/// - `binding`: the build-time runtime binding. Posture is read from the Phase-3 policy
///   fields (F7), NOT from `binding.mode`:
///   - `binding.meter`   — `MeterFuel` inserts `Charge` (Phase-2 cost model); `MeterOff`
///     inserts NONE (F5 zero-overhead — the emitted `.core` has no charge calls).
///   - `binding.stdlib`  — BOTH postures resolve shared calls to `binding.stdlib_module`
///     (F6); `StdlibPassthrough` only re-points the resolved *function* to a vetted
///     in-`rt_stdlib` shim (identical to `own` for the Phase-3 `gcd` corpus).
///   - `binding.bif_gate`— `BifAllowlist` rejects a resolved target off the `rt_bif`
///     allowlist (fail-closed); `BifOpen` admits any build-controlled resolved target (F6).
///   The impl module *bodies* are never imported (D3a); only `rt_stdlib`'s build-time
///   routing table and `rt_bif`'s build-time gate are consulted.
///
/// The `CallHost` provenance gate (`ForbiddenHost` for an undeclared capability) is applied
/// under EVERY posture — it is a well-formedness check, independent of `host_policy` (a
/// run-time `rt_host` decision, out of this pass's scope). `binding.mode` remains on the
/// record for other consumers (the linker; audit) but this pass no longer branches on it.
///
/// Returns `Ok(rewritten_module)` if every `CallHost` is permitted, or `Error(LowerError)`
/// on the first violation (fail-closed). Total — never panics on any input IR.
pub fn lower(module: Module, binding: Binding) -> Result(Module, LowerError) {
  let imports = import_set(module)
  case
    list.try_map(module.functions, fn(f) { lower_function(f, binding, imports) })
  {
    Error(e) -> Error(e)
    Ok(fns) -> Ok(ir.Module(..module, functions: fns))
  }
}

// ─────────────────────────────── per-function ───────────────────────────────

/// Lower one function: gate every `CallHost` in its body and meter loop bodies, then — under
/// `MeterFuel` — wrap the whole (rewritten) body in a `Charge(fn_cost, _)` so each call to the
/// function meters once on entry. Under `MeterOff` NO wrapping `Charge` is emitted (F5
/// zero-overhead: the absence of the node, not `Charge(0, …)`). Returns the rewritten
/// `Function` or the first policy violation.
fn lower_function(
  f: Function,
  binding: Binding,
  imports: Set(#(String, String)),
) -> Result(Function, LowerError) {
  case lower_expr(f.body, binding, imports) {
    Error(e) -> Error(e)
    Ok(body) ->
      case binding.meter {
        MeterFuel -> Ok(ir.Function(..f, body: ir.Charge(fn_cost, body)))
        MeterOff -> Ok(ir.Function(..f, body:))
      }
  }
}

/// Recursively walk an expression: validate every nested `CallHost` against the policy and
/// wrap every `Loop` body in `Charge(loop_cost, _)`. Pure/leaf and control-transfer nodes
/// are returned unchanged. Total; returns the first policy violation as `Error`.
fn lower_expr(
  expr: Expr,
  binding: Binding,
  imports: Set(#(String, String)),
) -> Result(Expr, LowerError) {
  case expr {
    // leaves — nothing to gate or meter (no CallHost, no Loop, no sub-Expr). The Phase-5
    // reference/table/bulk nodes join here: they carry only `Value` operands, so `ir_lower`
    // (a CallHost-gate + Loop-meter pass) leaves them unchanged.
    ir.Values(_)
    | ir.Num(_, _)
    | ir.Convert(_, _)
    | ir.TermOp(_, _)
    | ir.MemSize(_)
    | ir.MemGrow(_, _)
    | ir.MemLoad(_, _, _, _, _)
    | ir.MemStore(_, _, _, _, _)
    | ir.GlobalGet(_)
    | ir.GlobalSet(_, _)
    | ir.CallDirect(_, _)
    | ir.CallIndirect(_, _, _, _)
    | ir.Break(_, _)
    | ir.Continue(_, _)
    | ir.Return(_)
    | ir.Trap(_)
    | ir.RefFunc(_)
    | ir.RefIsNull(_)
    | ir.TableGet(_, _)
    | ir.TableSet(_, _, _)
    | ir.TableSize(_)
    | ir.TableGrow(_, _, _)
    | ir.TableFill(_, _, _, _)
    | ir.TableInit(_, _, _, _, _)
    | ir.TableCopy(_, _, _, _, _)
    | ir.ElemDrop(_)
    | ir.MemFill(_, _, _, _)
    | ir.MemCopy(_, _, _, _, _)
    | ir.MemInit(_, _, _, _, _)
    | ir.DataDrop(_)
    | // Phase-6 SIMD nodes + `CallImport` carry only `Value` operands (no sub-`Expr`), so this
      // CallHost-gate + Loop-meter pass leaves them unchanged. `CallImport` is a call but NOT a
      // `CallHost` (no capability-policy gate applies; it resolves to a linker-built closure, S5).
      ir.Simd(_, _)
    | ir.SimdShuffle(_, _, _)
    | ir.SimdLoad(_, _, _, _)
    | ir.SimdStore(_, _, _, _)
    | ir.SimdLoadLane(_, _, _, _, _, _)
    | ir.SimdStoreLane(_, _, _, _, _, _)
    | ir.CallImport(_, _, _)
    | // Phase-7 `Throw`/`ThrowRef` carry only `Value` operands (no sub-`Expr`, no `CallHost`, no
      // `Loop`), so this CallHost-gate + Loop-meter pass leaves them unchanged.
      ir.Throw(_, _)
    | ir.ThrowRef(_)
    | // Phase-8 native closures carry only `Value` operands (captures / callee + args) — no
      // `CallHost`, no `Loop`, no sub-`Expr` — so this CallHost-gate + Loop-meter pass leaves them
      // unchanged. `CallClosure` is a call but NOT a `CallHost` (no capability-policy gate: it
      // applies a fun VALUE already in hand, K3). Neither arises from WASM (K7).
      ir.MakeClosure(_, _, _)
    | ir.CallClosure(_, _)
    | // Phase-8 map layer (unit 03) carries only `Value` operands (no `CallHost`, no `Loop`, no
      // sub-`Expr`), so this CallHost-gate + Loop-meter pass leaves it unchanged. Never arises from
      // WASM (K7).
      ir.MapOp(_, _) -> Ok(expr)

    // THE capability boundary — gate it; the node is left unchanged for `emit_core` to route
    ir.CallHost(cap, name, args) ->
      case classify_call_host(cap, name, args, binding, imports) {
        Error(e) -> Error(e)
        Ok(Nil) -> Ok(expr)
      }

    // sequencing / structured control — recurse into sub-expressions
    ir.Let(names, rhs, body) ->
      case lower_expr(rhs, binding, imports) {
        Error(e) -> Error(e)
        Ok(rhs2) ->
          case lower_expr(body, binding, imports) {
            Error(e) -> Error(e)
            Ok(body2) -> Ok(ir.Let(names, rhs2, body2))
          }
      }

    ir.Block(label, result, body) ->
      case lower_expr(body, binding, imports) {
        Error(e) -> Error(e)
        Ok(body2) -> Ok(ir.Block(label, result, body2))
      }

    // a loop body is metered once per iteration under `MeterFuel`: wrap the rewritten body in
    // `Charge`. Under `MeterOff` the body is emitted unwrapped (F5) — the label/params/result
    // are untouched either way, so the constant-space tail-`apply` loop template survives.
    ir.Loop(label, params, result, body) ->
      case lower_expr(body, binding, imports) {
        Error(e) -> Error(e)
        Ok(body2) ->
          case binding.meter {
            MeterFuel ->
              Ok(ir.Loop(label, params, result, ir.Charge(loop_cost, body2)))
            MeterOff -> Ok(ir.Loop(label, params, result, body2))
          }
      }

    ir.If(cond, result, then_branch, else_branch) ->
      case lower_expr(then_branch, binding, imports) {
        Error(e) -> Error(e)
        Ok(then2) ->
          case lower_expr(else_branch, binding, imports) {
            Error(e) -> Error(e)
            Ok(else2) -> Ok(ir.If(cond, result, then2, else2))
          }
      }

    ir.Switch(selector, result, arms, default) ->
      case
        list.try_map(arms, fn(arm) {
          case lower_expr(arm.body, binding, imports) {
            Error(e) -> Error(e)
            Ok(b) -> Ok(ir.SwitchArm(arm.match, b))
          }
        })
      {
        Error(e) -> Error(e)
        Ok(arms2) ->
          case lower_expr(default, binding, imports) {
            Error(e) -> Error(e)
            Ok(default2) -> Ok(ir.Switch(selector, result, arms2, default2))
          }
      }

    // already-metered subtree (idempotent — not expected pre-lowering, but kept total)
    ir.Charge(cost, body) ->
      case lower_expr(body, binding, imports) {
        Error(e) -> Error(e)
        Ok(body2) -> Ok(ir.Charge(cost, body2))
      }

    // Phase-7 `Try` region (T1): recurse into its `body` and each handler's inline `handler`
    // expression so a `CallHost` / `Loop` inside an EH region is gated / metered like any other
    // structured-control interior. Byte-neutral (no Phase-1..6 module has this node); P7-05/06
    // own the real EH lowering + emit.
    ir.Try(result, body, handlers) ->
      case lower_expr(body, binding, imports) {
        Error(e) -> Error(e)
        Ok(body2) ->
          case
            list.try_map(handlers, fn(h) {
              case lower_expr(h.handler, binding, imports) {
                Error(e) -> Error(e)
                Ok(h2) -> Ok(ir.CatchHandler(..h, handler: h2))
              }
            })
          {
            Error(e) -> Error(e)
            Ok(handlers2) -> Ok(ir.Try(result, body2, handlers2))
          }
      }
  }
}

// ─────────────────────────────── the capability gate ───────────────────────────────

/// Decide whether a single `CallHost(capability, name, args)` is PERMITTED under `binding`'s
/// policy. Returns `Ok(Nil)` if it may stand (the node is left unchanged for `emit_core` to
/// route), or the typed `LowerError` on a violation. See `LowerError` for the three cases.
///
/// Posture-aware: the reserved-stdlib branch resolves the target under `binding.stdlib` and
/// gates it under `binding.bif_gate` (`BifAllowlist` fail-closed vs `BifOpen` admit). The
/// non-stdlib branch (declared-import vs `ForbiddenHost`) is posture-INDEPENDENT — an open BIF
/// gate widens the *build-controlled BIF* allow-set, never host provenance (a `ForbiddenHost`
/// stays fail-closed under every posture).
fn classify_call_host(
  capability: String,
  name: String,
  args: List(Value),
  binding: Binding,
  imports: Set(#(String, String)),
) -> Result(Nil, LowerError) {
  case capability == stdlib_capability, capability == js_capability {
    // reserved stdlib capability → resolve posture-aware, then gate on `binding.bif_gate`
    True, _ ->
      case resolve_stdlib_fn(name, list.length(args), binding) {
        Error(_) -> Error(UnknownStdlibFn(capability, name))
        Ok(target) ->
          case rt_bif.check_gated(target, binding.bif_gate) {
            Ok(Nil) -> Ok(Nil)
            Error(_) -> Error(BifNotAllowed(name))
          }
      }
    // reserved JS runtime capability (K6) → ADMITTED (like a resolved `"std"` call). The concrete
    // `op → rt_js:<fn>` dispatch — and the fail-closed rejection of an unknown op — is the
    // build-fixed literal `case` in `emit_core` (`resolve_js`/`UnknownJsOp`, D3a). Admitting the
    // capability here means a `"js"` call is NOT `ForbiddenHost`; it is NOT rewritten (the node is
    // left for `emit_core` to route, exactly like a stdlib/host call).
    _, True -> Ok(Nil)
    // any other capability → a declared host import is allowed (run-time deny); else reject
    False, False ->
      case set.contains(imports, #(capability, name)) {
        True -> Ok(Nil)
        False -> Error(ForbiddenHost(capability, name))
      }
  }
}

/// Resolve a shared-stdlib IR `name` at call `arity` to its concrete BEAM `BifTarget` under
/// `binding` — posture-aware, and the single resolution seam `emit_core` (unit 09) shares so
/// its emission target cannot disagree with this gate (§C.3). The target module is invariably
/// `binding.stdlib_module` (a `twocore@runtime@rt_*` module), never a raw BEAM module (F6/D3a).
///
/// The shared surface + passthrough routing come from `rt_stdlib` (the single source of truth;
/// unit 08 retired its local copy):
/// - `StdlibOwn`: `rt_stdlib.resolve` returns the vetted `own` target.
/// - `StdlibPassthrough`: `rt_stdlib.resolve` returns the vetted in-`rt_stdlib` shim — which,
///   for the Phase-3 `gcd` corpus (no active passthrough route), EQUALS the `own` target
///   byte-for-byte, so emit is identical under both postures.
///
/// Failure mapping around `rt_stdlib.resolve/4`, which keys on name AND arity:
/// - `name` is NOT on `rt_stdlib.shared_surface()` (name-only) → `Error(Nil)` → the caller
///   maps this to `UnknownStdlibFn` (fail-closed).
/// - `name` IS on the surface but the CALL arity differs from the surface arity → the own
///   target is reconstructed AT THE CALL ARITY and returned as `Ok`, so the downstream
///   `rt_bif` gate rejects it (`BifAllowlist` → `BifNotAllowed`) or admits it (`BifOpen`) —
///   preserving the Phase-2 semantics that a wrong-arity `gcd/1` is a gate-level rejection,
///   not an unknown-name rejection.
///
/// Returns `Ok(target)` when `name` is on the surface (target at the call arity), else
/// `Error(Nil)`. Total — never panics.
pub fn resolve_stdlib_fn(
  name: String,
  arity: Int,
  binding: Binding,
) -> Result(rt_bif.BifTarget, Nil) {
  case list.find(rt_stdlib.shared_surface(), fn(e) { e.0 == name }) {
    // name not on the shared surface → unknown stdlib fn (fail-closed)
    Error(_) -> Error(Nil)
    Ok(#(_ir_name, own_fn, _surface_arity)) ->
      case
        rt_stdlib.resolve(name, arity, binding.stdlib, binding.stdlib_module)
      {
        // correct arity: the posture-aware resolved target (own, or the passthrough shim)
        Ok(target) -> Ok(target)
        // name known, arity mismatch: rebuild the own target at the CALL arity so the BIF gate
        // decides (rejected under allowlist, admitted under open) — never an unknown-name error.
        Error(_) ->
          Ok(rt_bif.BifTarget(
            module: binding.stdlib_module,
            function: own_fn,
            arity:,
          ))
      }
  }
}

/// The set of `(capability, name)` pairs the module DECLARES as host imports. A `CallHost`
/// to a non-stdlib capability is permitted to stand (and be denied at run time) only if its
/// `(capability, name)` is in this set; otherwise it is rejected fail-closed.
fn import_set(module: Module) -> Set(#(String, String)) {
  list.fold(module.imports, set.new(), fn(acc, imp) {
    case imp {
      ir.ImportFn(capability, name, _ty) -> set.insert(acc, #(capability, name))
      // Non-function imports (H4) + a Phase-7 imported TAG (T2) are PROVIDED STATE, not
      // capabilities — they are wired into the instance by the instantiation contract (unit 09),
      // never reached via `CallHost`, so they contribute nothing to the host-capability set.
      ir.ImportGlobal(..)
      | ir.ImportTable(..)
      | ir.ImportMemory(..)
      | ir.ImportTag(..) -> acc
    }
  })
}

// ─────────────────────────────── audit / cross-check support ───────────────────────────────

/// The concrete `rt_bif` targets this pass resolves its shared-stdlib surface to, under
/// `binding` — posture-aware. Every target's module is `binding.stdlib_module` (a
/// `twocore@runtime@rt_*` module) under BOTH postures. Exposed for the anti-drift cross-check
/// test so the surface here and the published passthrough/allowlist surfaces cannot silently
/// diverge (§C.3):
/// - `StdlibOwn`         ⇒ the `own` targets (must equal `rt_bif.allowlist()`).
/// - `StdlibPassthrough` ⇒ the passthrough targets (unit 06's published passthrough surface —
///   all `binding.stdlib_module` targets; for the Phase-3 `gcd` corpus these EQUAL the `own`
///   targets, since no active passthrough route ships).
///
/// Each surface entry is resolved at its own surface arity, so the resolution never falls into
/// the wrong-arity path. Total.
pub fn resolved_stdlib_targets(binding: Binding) -> List(rt_bif.BifTarget) {
  list.filter_map(rt_stdlib.shared_surface(), fn(entry) {
    let #(ir_name, _own_fn, arity) = entry
    rt_stdlib.resolve(ir_name, arity, binding.stdlib, binding.stdlib_module)
  })
}
