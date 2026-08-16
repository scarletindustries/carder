//// Fail-closed tests for `rt_bif` (unit 09) — the build-time BEAM-function allowlist gate.
////
//// The asserted property (D4/D9): an allowlisted target passes (`Ok(Nil)`); **everything
//// else fails closed** (`Error(NotAllowlisted(_))`), including a known module/function at
//// the wrong arity. There is no Safe path to `open` — the type/profile simply offers
//// none — so we also assert the allowlist is the small vetted set and nothing dangerous
//// is on it.

import carder/runtime/instance.{BifAllowlist, BifOpen}
import carder/runtime/profiles
import carder/runtime/rt_bif.{BifTarget, NotAllowlisted}
import gleam/list
import gleeunit/should

/// The resolved `own`-stdlib target `rt_stdlib:gcd/2` is permitted.
pub fn allowlisted_target_passes_test() {
  rt_bif.check(BifTarget("carder@runtime@rt_stdlib", "gcd", 2))
  |> should.equal(Ok(Nil))
}

/// A non-allowlisted module/function fails closed.
pub fn unknown_target_fails_closed_test() {
  let target = BifTarget("erlang", "halt", 0)
  rt_bif.check(target)
  |> should.equal(Error(NotAllowlisted(target)))
}

/// A dangerous BEAM target (shelling out) is rejected — it is simply absent.
pub fn dangerous_target_fails_closed_test() {
  let target = BifTarget("os", "cmd", 1)
  rt_bif.check(target)
  |> should.equal(Error(NotAllowlisted(target)))
}

/// Right module+function, WRONG arity ⇒ rejected (the triple must match exactly).
pub fn wrong_arity_fails_closed_test() {
  let target = BifTarget("carder@runtime@rt_stdlib", "gcd", 3)
  rt_bif.check(target)
  |> should.equal(Error(NotAllowlisted(target)))
}

/// `is_allowed` agrees with `check` (allowed) …
pub fn is_allowed_true_test() {
  rt_bif.is_allowed(BifTarget("carder@runtime@rt_stdlib", "gcd", 2))
  |> should.equal(True)
}

/// … and (denied).
pub fn is_allowed_false_test() {
  rt_bif.is_allowed(BifTarget("erlang", "halt", 0))
  |> should.equal(False)
}

/// The allowlist exposes the vetted set for audit, and it contains the gcd target.
pub fn allowlist_contains_gcd_test() {
  rt_bif.allowlist()
  |> list.contains(BifTarget("carder@runtime@rt_stdlib", "gcd", 2))
  |> should.equal(True)
}

/// Every entry on the allowlist is itself permitted by `check` (internal consistency).
pub fn allowlist_entries_all_pass_test() {
  rt_bif.allowlist()
  |> list.all(fn(t) { rt_bif.check(t) == Ok(Nil) })
  |> should.equal(True)
}

// ───────────────────────── the posture-aware gate `check_gated/2` (F6, §C.3) ─────────────────────────

/// Safe posture (`BifAllowlist`) is EXACTLY the untouched `check`: a build-fixed
/// non-allowlisted target is still rejected fail-closed (D4/D9). The gate wrapper changes
/// nothing about the Safe verdict.
pub fn gated_allowlist_rejects_non_allowlisted_test() {
  let t = BifTarget("erlang", "abs", 1)
  rt_bif.check_gated(t, BifAllowlist)
  |> should.equal(Error(NotAllowlisted(t)))
  // …and it is LITERALLY `check(t)` — the Safe gate is byte-for-byte unchanged.
  rt_bif.check_gated(t, BifAllowlist)
  |> should.equal(rt_bif.check(t))
}

/// Open posture (`BifOpen`, Unsafe) ADMITS the same build-fixed target Safe just rejected —
/// widening the build-controlled allow-set (never ambient authority: the target is still a
/// compiler-built triple, D3a).
pub fn gated_open_admits_previously_rejected_test() {
  let t = BifTarget("erlang", "abs", 1)
  // Safe rejects it …
  rt_bif.check_gated(t, BifAllowlist)
  |> should.equal(Error(NotAllowlisted(t)))
  // … open admits it.
  rt_bif.check_gated(t, BifOpen)
  |> should.equal(Ok(Nil))
}

/// An allowlisted target passes under BOTH postures — open does not corrupt the Safe-admitted
/// case.
pub fn gated_allowlisted_passes_both_postures_test() {
  let t = BifTarget("carder@runtime@rt_stdlib", "gcd", 2)
  rt_bif.check_gated(t, BifAllowlist) |> should.equal(Ok(Nil))
  rt_bif.check_gated(t, BifOpen) |> should.equal(Ok(Nil))
}

/// Reachability is PROFILE-BOUND (§C.2): the open verdict is a property of the linked profile,
/// not a flag a program can flip — `profiles.safe()` pins `BifAllowlist`, and only
/// `profiles.unsafe()` yields `BifOpen`. So `check_gated(_, BifOpen)` is unreachable from a
/// Safe build.
pub fn gate_reachability_is_profile_bound_test() {
  profiles.safe().bif_gate |> should.equal(BifAllowlist)
  profiles.unsafe().bif_gate |> should.equal(BifOpen)
}
