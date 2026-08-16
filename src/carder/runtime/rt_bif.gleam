//// `rt_bif` — the Safe BEAM-function **allowlist** gate. BUILD-TIME, fail-closed (D4/D9).
////
//// This is **not** a runtime layer and is **not** in the `Binding` record: generated code
//// never calls it. It is consulted by unit 11's `ir_lower` at *build time* when resolving
//// a `CallHost`/BIF target to a concrete BEAM `module:function/arity`. Only targets on a
//// small, fixed, vetted allowlist are permitted; anything else **fails closed** (is
//// rejected, never assumed safe). The allowlist is build-controlled — Phase 1 ships no
//// Safe configuration that opens it (the `open` BIF policy is deferred to Phase 2, D9).
////
//// Phase-1 contents: the resolved `own`-stdlib targets that `ir_lower` may rewrite a
//// `CallHost` into — currently just `rt_stdlib:gcd/2`. (Numeric `rt_num` calls reach the
//// runtime through the binding chokepoint directly, not via this gate.)
////
//// ## Phase-3 extension: the POSTURE-aware gate (`check_gated/2`, F6)
////
//// The fail-closed allowlist (`check/1`, `allowlist/0`, `is_allowed/1`) is untouched — it
//// stays byte-for-byte the Phase-1 Safe gate. Phase 3 adds one wrapper, `check_gated/2`,
//// parameterised by `instance.BifGate`: under `BifAllowlist` (Safe) it *is* `check/1`
//// (fail-closed, unchanged); under `BifOpen` (Unsafe) it admits any BUILD-FIXED target. This
//// is the ONE place the allowlist can be relaxed, and it is reachable only through the tested
//// `profiles.unsafe()` opt-in (F4/D4/D9). Acyclic: `rt_bif → instance → ir_opt → ir`
//// (`instance` imports neither `rt_bif` nor `rt_stdlib`).

import carder/runtime/instance.{type BifGate, BifAllowlist, BifOpen}
import gleam/list

/// A concrete BEAM call target: a `module:function/arity` triple.
///
/// - `module`: the Gleam→Erlang-mangled module name (e.g. `"carder@runtime@rt_stdlib"`).
/// - `function`: the public function name as emitted (verbatim).
/// - `arity`: the parameter count.
pub type BifTarget {
  BifTarget(module: String, function: String, arity: Int)
}

/// Why a `check` rejected a target.
///
/// - `NotAllowlisted(target)`: `target` is not on the vetted Safe allowlist (the only
///   failure mode — fail closed).
pub type BifError {
  NotAllowlisted(BifTarget)
}

/// The vetted Safe allowlist: the fixed, build-controlled set of BEAM targets a resolved
/// `CallHost`/BIF may dispatch to.
///
/// - Return: the allowlist as a `List(BifTarget)`. Exposed for audit and tests. Total.
///   Phase 1: exactly the `own`-stdlib targets (`rt_stdlib:gcd/2`).
pub fn allowlist() -> List(BifTarget) {
  [BifTarget(module: "carder@runtime@rt_stdlib", function: "gcd", arity: 2)]
}

/// Is `target` permitted under the Safe allowlist?
///
/// - `target`: the concrete BEAM `module:function/arity` a build-time pass wants to emit.
/// - Return: `Ok(Nil)` if `target` is on `allowlist()`, else `Error(NotAllowlisted(target))`.
///   **Fail closed** — an unknown target (including a known module/function with the wrong
///   arity) is rejected, never assumed safe. Total — never panics.
pub fn check(target: BifTarget) -> Result(Nil, BifError) {
  case is_allowed(target) {
    True -> Ok(Nil)
    False -> Error(NotAllowlisted(target))
  }
}

/// Boolean form of `check`: whether `target` is on the Safe allowlist.
///
/// - `target`: the concrete BEAM target to test.
/// - Return: `True` iff `target` is on `allowlist()`, else `False`. Total. Provided for
///   call sites that want a predicate rather than a `Result`.
pub fn is_allowed(target: BifTarget) -> Bool {
  list.contains(allowlist(), target)
}

/// Gate a BUILD-FIXED `target` under the `gate` posture chosen by the profile
/// (`binding.bif_gate`, F6/F7). This is the **one** place the allowlist can be relaxed, and it
/// is reachable open only through the tested `profiles.unsafe()` opt-in (§C.2, F4/D4/D9).
///
/// - `target`: a concrete BEAM `module:function/arity` the compiler's build-time resolver
///   constructed (never a module atom read from program/attacker data — D3a).
/// - `gate`: the posture from `binding.bif_gate`.
///
/// Return:
/// - `BifAllowlist` (Safe): **exactly `check(target)`** — fail-closed. A non-allowlisted
///   target (including a known module/function at the wrong arity) is rejected
///   `Error(NotAllowlisted(target))`. Nothing about the Safe gate changes.
/// - `BifOpen` (Unsafe): a **no-op admit** — `Ok(Nil)` for any build-fixed `target`. This is
///   NOT "arbitrary/full BEAM access": it widens the *build-controlled* allow-set from the
///   small vetted list to exactly the targets the resolver constructs (the passthrough/own
///   surface only), never arbitrary BIFs and never a program-derived atom. Node-safety of any
///   admitted target rests on per-route human vetting, not on the gate. It adds no ambient
///   authority: an admitted target is still emitted as a STATIC `call '<mod>':'<fn>'(...)`,
///   never an `apply/3` of runtime data (D3a).
///
/// Total — never panics.
pub fn check_gated(target: BifTarget, gate: BifGate) -> Result(Nil, BifError) {
  case gate {
    BifAllowlist -> check(target)
    BifOpen -> Ok(Nil)
  }
}
