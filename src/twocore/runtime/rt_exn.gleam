//// `rt_exn` — the tagged-exception runtime (Phase-7, J1/T3; bodies filled by P7-07).
////
//// The EH analogue of `rt_trap`: the single auditable chokepoint for exception fidelity —
//// it RAISES (never crashes the node), and the `{wasm_exn, …}` / `{ref_exn, …}` term shapes
//// live in exactly ONE module (D3b — the binding chokepoint, never smeared across emitted Core
//// Erlang). `emit_core` (P7-06) lowers `Throw`/`Try`/`ThrowRef` to calls of exactly these heads;
//// P7-07 fills the bodies over the frozen terms (via the `twocore_rt_exn_ffi` shim).
////
//// ## The frozen representation contract (T3/T6/T9 — pinned by P7-01, implemented here)
////
//// - **A WASM exception is the 3-tuple `{wasm_exn, TagId, Payload}`** raised **ERROR class** (so it
////   rides the same catchable channel as `rt_trap`'s `{wasm_trap, Kind}`). `TagId` is a
////   module-local `Int` (the tag's index — T4; single-module Porffor scope: it exports its one
////   tag, imports none). `Payload` is the operand value list `List(Dynamic)` (each element a
////   raw-bit `Int` for i32/i64/f32/f64 — D5 — a `BitArray` for v128, a boxed `Dynamic` for a
////   reference). **EH ships CELL-ONLY (T6): there is NO threaded-state field** — the term is
////   exactly the 3-tuple, no state.
//// - **A caught exception binds `{Class, Reason, Stack}`** — the Core Erlang `try…catch` binds
////   these three; `reraise` uses `erlang:raise(Class, Reason, Stack)` to preserve the original
////   class + stacktrace faithfully (transparent propagation — spec §4.4.9 unwinding).
//// - **An `exnref` is the reason-only forge-proof box `{ref_exn, Reason}`** (T9 — NOT the
////   `{Class, Reason, Stk}` triple: WASM has no observable stack, so `throw_ref` is a fresh
////   raise of the captured reason — simpler + spec-faithful). The box is uncollidable with null
////   (`{ref_null}`, reused verbatim from `rt_ref`) / a funcref / an externref, and OPAQUE (Safe
////   code cannot unwrap it — H6/J5). `rt_ref.classify_ref` gains an `ExnRef` arm (T9) so a
////   `{ref_exn,_}` classifies distinctly rather than by-elimination as a funcref.
//// - **Raising heads are bottom (`-> a`)** — `throw_exn`/`reraise`/`throw_ref` DIVERGE (raise),
////   never return, so the emitter can place them in any value position (exactly like
////   `rt_trap.raise`).
//// - **D3a — no ambient authority.** The raised term is BUILD-CONTROLLED (a fixed
////   `{wasm_exn, …}` / `{ref_exn, …}` shape); there is no `apply(Mod, Fun, Args)` of a
////   program-chosen target anywhere on the path (grep-asserted — the payload is DATA, never
////   authority).
////
//// ## The raise CLASS and how P7-06's catch matches it (T7)
////
//// `throw_exn`/`throw_ref` raise **ERROR class**; `reraise` preserves whatever class was caught.
//// This does NOT constrain the catch: P7-06 emits `try B of <Vs> -> <Vs> catch <C, R, S> -> H`,
//// whose 3-variable catch catches **all** classes, and `H` decides caught-vs-reraise purely by the
//// TERM SHAPE (`match_tag` / `is_wasm_exn`), never by the class. So a stray non-WASM
//// `throw`/`error`/`exit` from any layer is faithfully re-raised, never mis-caught. The ERROR
//// class is only a distinctness convenience (a WASM exception and a WASM trap ride one channel;
//// the top-level run-ABI splits them by term shape — `{wasm_exn,_,_}` ⇒ `UncaughtException` (T8),
//// `{wasm_trap,_}` ⇒ `Trapped`).
////
//// ## Load-bearing rule: `catch_all` catches EXCEPTIONS but NOT TRAPS (spec §4.4; T7)
////
//// `is_wasm_exn` matches ONLY `{wasm_exn, _, _}`, NEVER `{wasm_trap, _}` (or a `FuelExhausted`
//// raise, or any other BEAM error). The emitted `catch_all` handler tests it and re-raises
//// otherwise, so a real 2core trap (memory OOB, fuel) PROPAGATES through any `try` region
//// untouched — a trap must always bite (the sandbox floor, S8).

import gleam/dynamic.{type Dynamic}
import twocore/ir.{Unreachable}
import twocore/runtime/rt_ref
import twocore/runtime/rt_trap

// ── the FFI shim (twocore_rt_exn_ffi) — fixed-tuple construction/matching + native raise ──────────

/// FFI: `erlang:error({wasm_exn, TagId, Payload})` — raise the build-fixed exception term.
@external(erlang, "twocore_rt_exn_ffi", "throw_exn")
fn ffi_throw_exn(tag_id: Int, payload: List(Dynamic)) -> a

/// FFI: `{ok, Payload}` iff `reason` is `{wasm_exn, tag_id, Payload}`, else `{error, nil}`.
@external(erlang, "twocore_rt_exn_ffi", "match_tag")
fn ffi_match_tag(reason: Dynamic, tag_id: Int) -> Result(List(Dynamic), Nil)

/// FFI: structural `{wasm_exn, _, _}` test (never true for a `{wasm_trap, _}` trap).
@external(erlang, "twocore_rt_exn_ffi", "is_wasm_exn")
fn ffi_is_wasm_exn(reason: Dynamic) -> Bool

/// FFI: `erlang:raise(Class, Reason, Stacktrace)` — faithful, stack-preserving re-raise.
@external(erlang, "twocore_rt_exn_ffi", "reraise")
fn ffi_reraise(class: Dynamic, reason: Dynamic, stack: Dynamic) -> a

/// FFI: box a caught `reason` as the forge-proof exnref `{ref_exn, Reason}` (T9 reason-only).
@external(erlang, "twocore_rt_exn_ffi", "capture_exnref")
fn ffi_capture_exnref(reason: Dynamic) -> Dynamic

/// FFI: unbox `{ref_exn, Reason}` and re-raise `Reason` as a FRESH `erlang:error` (no stack, T9).
@external(erlang, "twocore_rt_exn_ffi", "rethrow_exnref")
fn ffi_rethrow_exnref(exnref: Dynamic) -> a

/// FFI: structural `{ref_exn, _}` test (opaque — no unwrap exposed).
@external(erlang, "twocore_rt_exn_ffi", "is_exnref")
fn ffi_is_exnref(x: Dynamic) -> Bool

// ── the frozen public heads («RT-EXN-SIG», T3) ────────────────────────────────────────────────────

/// Raise a WASM exception carrying `tag_id` + `payload` as `{wasm_exn, TagId, Payload}` (ERROR
/// class — catchable via a `try … catch <C, R, S>` that dispatches on the term shape, §above).
/// NEVER returns (diverges). This is the `Throw` / legacy-`throw` / modern-`throw` lowering
/// target. `tag_id` is the module-local tag index (T4); `payload` is the operand value list
/// (bit-exact raw values, opaque `Dynamic` carriers — D5). D3a: `payload` is DATA, never
/// authority.
pub fn throw_exn(tag_id: Int, payload: List(Dynamic)) -> a {
  ffi_throw_exn(tag_id, payload)
}

/// Match a caught `reason` against a specific module-local `tag_id` (the `catch $t` case).
/// `Ok(Payload)` iff `reason` is `{wasm_exn, tag_id, Payload}` with THE SAME tag identity (spec
/// tag-identity match, §4.5); `Error(Nil)` otherwise — a DIFFERENT tag, a `{wasm_trap, _}` trap,
/// or any other BEAM term (the caller re-raises). Throw + catch route through this ONE identity so
/// they agree (T4). Total — never raises.
pub fn match_tag(reason: Dynamic, tag_id: Int) -> Result(List(Dynamic), Nil) {
  ffi_match_tag(reason, tag_id)
}

/// `True` iff a caught `reason` is a WASM exception `{wasm_exn, _, _}` — NOT a WASM trap
/// `{wasm_trap, _}`, a `FuelExhausted` raise, or any other BEAM error/exit. LOAD-BEARING (T7):
/// this is what makes `catch_all` catch **exceptions but not traps** (spec §4.4) — the emitted
/// handler tests it before treating a caught reason as an exception, and re-raises otherwise, so a
/// trap PROPAGATES through the `try` (a trap must always bite — S8). Total — never raises.
pub fn is_wasm_exn(reason: Dynamic) -> Bool {
  ffi_is_wasm_exn(reason)
}

/// Faithfully re-raise a caught exception, preserving its class + reason + stacktrace
/// (`erlang:raise(Class, Reason, Stack)` — spec §4.4.9 unwinding). The non-matching-handler
/// propagation path — a re-thrown exception is indistinguishable from the original at an outer
/// handler (a wasm exn stays catchable by tag; a trap stays a trap). NEVER returns.
pub fn reraise(class: Dynamic, reason: Dynamic, stack: Dynamic) -> a {
  ffi_reraise(class, reason, stack)
}

/// Wrap a caught `reason` as an `exnref` handle `{ref_exn, Reason}` (the `catch_ref`/
/// `catch_all_ref` capture — T9). Reason-only (WASM has no observable stack), forge-proof (the
/// box is uncollidable with null / a funcref / an externref) and opaque (Safe code cannot unwrap
/// it — H6/J5; this module exposes no unwrap). Total over any `reason` (in practice only ever a
/// `{wasm_exn, _, _}`, since it is called only after a positive match — traps are never caught).
/// Porffor-INERT (spec-conformance surface only).
pub fn capture_exnref(reason: Dynamic) -> Dynamic {
  ffi_capture_exnref(reason)
}

/// Re-raise the exception referenced by an `exnref` (`ThrowRef` / `throw_ref`; also legacy
/// `rethrow`). Unwraps `{ref_exn, Reason}` and re-raises `Reason` as a FRESH raise (T9 — no stack
/// preservation; ERROR class, same channel as `throw_exn`); a NULL exnref (`{ref_null}`) TRAPS
/// (spec §4.4.9: re-throwing `ref.null exn` traps — routed through `rt_trap`). NEVER returns.
/// Porffor-INERT (spec-conformance surface only).
///
/// The null-trap reason is `Unreachable` — PROVISIONAL per §G/S8 (reuse an existing `TrapReason`,
/// no new variant — T8): the spec asserts only that it traps; the exact message is deferred until a
/// pinned `throw_ref.wast` is measured (Porffor never emits `throw_ref`, so this is
/// engine-completeness, not corpus-blocking).
pub fn throw_ref(exnref: Dynamic) -> a {
  case rt_ref.is_null(exnref) {
    True -> rt_trap.raise(Unreachable)
    False -> ffi_rethrow_exnref(exnref)
  }
}

/// `True` iff `x` is an `exnref` box `{ref_exn, _}` (T9) — for defensive runtime checks + the
/// harness's reference-return judgement. Forge-proof: the box is structurally distinct from null
/// (`{ref_null}`), a funcref (`{FuncType, Closure}`), an externref (`{ref_extern, _}`), and a raw
/// thrown exn (`{wasm_exn, _, _}`), so it never mis-identifies. Total — never raises.
/// Porffor-INERT (spec-conformance surface only).
pub fn is_exnref(x: Dynamic) -> Bool {
  ffi_is_exnref(x)
}
