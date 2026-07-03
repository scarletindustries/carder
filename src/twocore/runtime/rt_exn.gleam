//// `rt_exn` — the tagged-exception runtime (Phase-7 keystone freeze, J1/T3).
////
//// The EH analogue of `rt_trap`: the single auditable chokepoint for exception fidelity —
//// it RAISES (never crashes the node), and the `{wasm_exn, …}` / `{ref_exn, …}` term shapes
//// live in exactly ONE module (D3b — the binding chokepoint, never smeared across emitted Core
//// Erlang). `emit_core` (P7-06) lowers `Throw`/`Try`/`ThrowRef` to calls of exactly these heads;
//// P7-07 fills the bodies over the frozen terms.
////
//// ## The frozen representation contract (T3/T6/T9 — pinned here, implemented by P7-07)
////
//// - **A WASM exception is the 3-tuple `{wasm_exn, TagId, Payload}`** raised ERROR class (so it
////   rides the same catchable channel as `rt_trap`'s `{wasm_trap, Kind}`). `TagId` is a
////   module-local `Int` (the tag's index — T4; single-module Porffor scope: it exports its one
////   tag, imports none). `Payload` is the operand value list `List(Dynamic)` (each element a
////   raw-bit `Int` for i32/i64/f32/f64 — D5 — a `BitArray` for v128, a boxed `Dynamic` for a
////   reference). **EH ships CELL-ONLY (T6): there is NO threaded-state field** — the term is
////   exactly the 3-tuple, no state.
//// - **A caught exception binds `{Class, Reason, Stack}`** — the Core Erlang `try…catch` binds
////   these three; `reraise` uses `erlang:raise(Class, Reason, Stack)` to preserve the original
////   class + stacktrace faithfully (transparent propagation).
//// - **An `exnref` is the reason-only forge-proof box `{ref_exn, Reason}`** (T9 — NOT the
////   `{Class, Reason, Stk}` triple: WASM has no observable stack, so `throw_ref` is a fresh
////   `erlang:throw` of the captured reason — simpler + spec-faithful). The box is uncollidable
////   with null (`{ref_null}`, reused verbatim from `rt_ref`) / a funcref / an externref, and
////   OPAQUE (Safe code cannot unwrap it — H6/J5).
//// - **Raising heads are bottom (`-> a`)** — `throw_exn`/`reraise`/`throw_ref` DIVERGE (raise),
////   never return, so the emitter can place them in any value position (exactly like
////   `rt_trap.raise`).
//// - **D3a — no ambient authority.** The raised term is BUILD-CONTROLLED (a fixed
////   `{wasm_exn, …}` / `{ref_exn, …}` shape); there is no `apply(Mod, Fun, Args)` of a
////   program-chosen target anywhere on the path.
////
//// ## Load-bearing rule: `catch_all` catches EXCEPTIONS but NOT TRAPS (spec §4.4)
////
//// `is_wasm_exn` matches ONLY `{wasm_exn, _, _}`, NEVER `{wasm_trap, _}` (or a fuel exhaustion,
//// or any other BEAM error). The emitted `catch_all` handler tests it and re-raises otherwise, so
//// a real 2core trap (memory OOB, fuel) PROPAGATES through any `try` region untouched (§H.2).
////
//// ## Keystone posture (P7-01)
////
//// This unit CREATES the file with every public head, its doc, and a fail-loud `panic`
//// placeholder body — `todo`-free (Gleam's `todo` warns; `panic` does not), zero-warning (a
//// `pub fn` is never "unused"; args are consumed via `let _ = #(…)`), and IMPORT-free beyond
//// `gleam/dynamic` (P7-07 adds `import twocore/runtime/rt_ref`/`rt_trap` when it fills bodies, so
//// the keystone has no unused-import warning). No Phase-1..6 module and no keystone freeze test
//// CALLS these heads (the keystone's `emit` arms return `UnsupportedNode`), so the placeholders
//// are never reached until P7-07.

import gleam/dynamic.{type Dynamic}

/// Raise a WASM exception carrying `tag_id` + `payload` as `{wasm_exn, TagId, Payload}` (error
/// class — catchable via a `try … catch error:{wasm_exn, _, _}`). NEVER returns (diverges). This
/// is the `Throw` / legacy-`throw` / modern-`throw` lowering target (§H). `tag_id` is the
/// module-local tag index (T4); `payload` is the operand value list (§contract).
///
/// Placeholder body (P7-07 implements): fail-loud `panic` — never reached until P7-07.
pub fn throw_exn(tag_id: Int, payload: List(Dynamic)) -> a {
  let _ = #(tag_id, payload)
  panic as "rt_exn.throw_exn — implemented in P7-07"
}

/// Match a caught `reason` against a specific module-local `tag_id` (the `catch $t` case).
/// `Ok(Payload)` iff `reason` is `{wasm_exn, tag_id, Payload}` with THE SAME tag identity (spec
/// tag-identity match); `Error(Nil)` otherwise (a different tag, or not a `wasm_exn` at all → the
/// caller re-raises). The catch dispatch routes through this ONE identity so `throw`+`catch`
/// agree (T4).
///
/// Placeholder body (P7-07 implements): fail-loud `panic` — never reached until P7-07.
pub fn match_tag(reason: Dynamic, tag_id: Int) -> Result(List(Dynamic), Nil) {
  let _ = #(reason, tag_id)
  panic as "rt_exn.match_tag — implemented in P7-07"
}

/// `True` iff a caught `reason` is a WASM exception `{wasm_exn, _, _}` — NOT a WASM trap
/// `{wasm_trap, _}`, a fuel exhaustion, or any other BEAM error. LOAD-BEARING: this is what makes
/// `catch_all` catch **exceptions but not traps** (spec §4.4) — the emitted handler tests it
/// before treating a caught reason as an exception, and re-raises otherwise (§H.2).
///
/// Placeholder body (P7-07 implements): fail-loud `panic` — never reached until P7-07.
pub fn is_wasm_exn(reason: Dynamic) -> Bool {
  let _ = reason
  panic as "rt_exn.is_wasm_exn — implemented in P7-07"
}

/// Faithfully re-raise a caught exception, preserving its class + stacktrace
/// (`erlang:raise(Class, Reason, Stack)`). The non-matching-handler propagation path (§H.2) — a
/// re-thrown exception is indistinguishable from the original at an outer handler. NEVER returns.
///
/// Placeholder body (P7-07 implements): fail-loud `panic` — never reached until P7-07.
pub fn reraise(class: Dynamic, reason: Dynamic, stack: Dynamic) -> a {
  let _ = #(class, reason, stack)
  panic as "rt_exn.reraise — implemented in P7-07"
}

/// Wrap a caught `reason` as an `exnref` handle `{ref_exn, Reason}` (the `catch_ref`/
/// `catch_all_ref` capture — T9). Reason-only (WASM has no observable stack), forge-proof (the
/// box is uncollidable with null / a funcref / an externref) and opaque (Safe code cannot unwrap
/// it — H6/J5). Porffor-INERT (spec-conformance surface only).
///
/// Placeholder body (P7-07 implements): fail-loud `panic` — never reached until P7-07.
pub fn capture_exnref(reason: Dynamic) -> Dynamic {
  let _ = reason
  panic as "rt_exn.capture_exnref — implemented in P7-07"
}

/// Re-raise the exception referenced by an `exnref` (`ThrowRef` / `throw_ref`, §H.3). Unwraps
/// `{ref_exn, Reason}` and re-raises `Reason` as a fresh `erlang:throw` (T9); a NULL exnref traps
/// (spec: re-throwing `ref.null exn` traps — routes through `rt_trap`). NEVER returns.
/// Porffor-INERT (spec-conformance surface only).
///
/// Placeholder body (P7-07 implements): fail-loud `panic` — never reached until P7-07.
pub fn throw_ref(exnref: Dynamic) -> a {
  let _ = exnref
  panic as "rt_exn.throw_ref — implemented in P7-07"
}

/// `True` iff `x` is an `exnref` box `{ref_exn, _}` (T9) — for defensive runtime checks + the
/// harness's reference-return judgement. Forge-proof: the box is structurally distinct from null
/// / a funcref / an externref. Porffor-INERT (spec-conformance surface only).
///
/// Placeholder body (P7-07 implements): fail-loud `panic` — never reached until P7-07.
pub fn is_exnref(x: Dynamic) -> Bool {
  let _ = x
  panic as "rt_exn.is_exnref — implemented in P7-07"
}
