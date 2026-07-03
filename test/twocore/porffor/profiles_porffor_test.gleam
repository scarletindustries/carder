//// Tests for the `profiles.porffor()` / `js()` JS-on-BEAM posture (P7-08 §G). Asserts it is a
//// **Safe** `HostWhitelist` admitting EXACTLY the four `""` intrinsics — never `HostOpen`, and
//// otherwise byte-identical to `safe()` (the fail-closed enumeration is unperturbed, J5).

import gleeunit/should
import twocore/runtime/instance.{HostWhitelist, Safe}
import twocore/runtime/profiles

/// `porffor_allow()` is exactly the four `#("", letter)` pairs — the closed authority surface.
pub fn porffor_allow_is_four_pairs_test() {
  profiles.porffor_allow()
  |> should.equal([#("", "a"), #("", "b"), #("", "c"), #("", "d")])
}

/// `porffor()` is a **Safe** posture (mode `Safe`) whose host policy is the whitelist of the four
/// intrinsics — NOT `HostOpen`, so no unrelated capability is reachable.
pub fn porffor_is_safe_whitelist_test() {
  let binding = profiles.porffor()
  binding.mode |> should.equal(Safe)
  binding.host_policy
  |> should.equal(
    HostWhitelist([#("", "a"), #("", "b"), #("", "c"), #("", "d")]),
  )
}

/// `porffor()` differs from `safe()` ONLY in `host_policy` — every other field (mode, tiers,
/// caps, module names) is inherited unchanged (conformance-neutral, J6).
pub fn porffor_differs_only_in_host_policy_test() {
  let base = profiles.safe()
  let porf = profiles.porffor()
  should.equal(porf, instance.Binding(..base, host_policy: porf.host_policy))
}

/// `js()` is an alias for `porffor()` — identical binding (the intent-named posture).
pub fn js_aliases_porffor_test() {
  profiles.js() |> should.equal(profiles.porffor())
}

/// `porffor()` links cleanly (it changes only `host_policy`, so it is a coherent Safe binding).
pub fn porffor_links_ok_test() {
  profiles.link(profiles.porffor()) |> should.be_ok
}
