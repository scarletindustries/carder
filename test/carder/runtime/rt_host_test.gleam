//// Security tests for `rt_host` — the per-instance capability boundary (F4).
////
//// These assert **security / spec behaviour** (D8), never "whatever the code emits". The
//// governing property is **fail-closed**: a host call returns ONLY when its posture permits
//// it AND carder provides a vetted handler; every other case DENIES by raising the
//// error-class `{capability_denied, Cap, Name}` (WebAssembly spec §4.5.4 — an unprovided
//// import is not callable; §7 — an embedder may abort a host call). Denials are caught via
//// the namespace-hygienic `carder_rt_test_ffi` `host_denial/1` helper (pure Gleam cannot
//// `catch`); admitted returns via `carder_rt_state_test_ffi` `catch_thunk/1`.
////
//// **Test isolation (F4/E1).** eunit runs a whole module's tests in ONE process, sharing one
//// process dictionary, so a seeded policy would leak across tests and re-enable host calls
//// elsewhere. Every policy-seeding assertion therefore runs inside its OWN spawned process
//// (`in_process`) — the one-instance-one-process posture — so seeds cannot leak. The unseeded
//// default is `HostDenyAll`, so the shared eunit process (never seeded here) keeps denying,
//// which is exactly why the Phase-1 deny-all tests below stay green unchanged.

import carder/ir
import carder/runtime/instance.{HostDenyAll, HostOpen, HostWhitelist}
import carder/runtime/rt_host
import gleam/erlang/process
import gleeunit/should

/// Run `action`; returns `Ok(#(capability, name))` only when it raises the error-class
/// `{capability_denied, Cap, Name}`, else `Error(description)` (e.g. if it returned).
@external(erlang, "carder_rt_test_ffi", "host_denial")
fn host_denial(action: fn() -> a) -> Result(#(String, String), String)

/// Run `thunk`, reporting `Ok(value)` on a normal return or `Error(text)` on any raise. Used
/// to capture the *value* an admitted host call returns. Shared catch shim; pure Gleam cannot
/// `catch`.
@external(erlang, "carder_rt_state_test_ffi", "catch_thunk")
fn catch_thunk(thunk: fn() -> a) -> Result(a, String)

// ── helpers ────────────────────────────────────────────────────────────────────

/// Run `work` in a FRESH BEAM process and return its value. A fresh process gives the policy
/// assertion an ISOLATED process dictionary, so a `seed_policy` inside `work` cannot leak into
/// eunit's shared per-module process and re-enable host calls in another test (F4/E1). NOTE:
/// `work` must not itself raise (it should catch via `host_denial`/`catch_thunk`), or the
/// spawned process would die and the receive time out.
fn in_process(work: fn() -> a) -> a {
  let reply = process.new_subject()
  let _ = process.spawn(fn() { process.send(reply, work()) })
  let assert Ok(value) = process.receive(reply, within: 5000)
  value
}

/// Seed `policy`, then attempt `call_host(cap, name, args)`, all inside a FRESH process.
/// Returns `Ok(#(cap, name))` iff the call was DENIED (raised `{capability_denied, _, _}`
/// echoing the pair), else `Error(desc)` (it returned, or raised the wrong class/shape).
fn denial_under(
  policy: instance.HostPolicy,
  cap: String,
  name: String,
  args: List(Int),
) -> Result(#(String, String), String) {
  in_process(fn() {
    rt_host.seed_policy(policy)
    host_denial(fn() { rt_host.call_host(cap, name, args) })
  })
}

/// Seed `policy`, then attempt `call_host(cap, name, args)`, all inside a FRESH process.
/// Returns `Ok(result_bits)` when the call was ADMITTED and returned, or `Error(desc)` when it
/// denied/raised — so an admit assertion pins the returned value.
fn call_under(
  policy: instance.HostPolicy,
  cap: String,
  name: String,
  args: List(Int),
) -> Result(List(Int), String) {
  in_process(fn() {
    rt_host.seed_policy(policy)
    catch_thunk(fn() { rt_host.call_host(cap, name, args) })
  })
}

// ── Phase-1 deny-all boundary: unchanged under the unseeded default ──────────────

// These run in eunit's shared (never-seeded) process, whose policy is the fail-closed
// default `HostDenyAll`, so every call still denies exactly as in Phase 1.

pub fn denies_empty_args_test() {
  host_denial(fn() { rt_host.call_host("fs", "open", []) })
  |> should.equal(Ok(#("fs", "open")))
}

pub fn denies_with_args_test() {
  host_denial(fn() { rt_host.call_host("net", "connect", [1, 2, 3]) })
  |> should.equal(Ok(#("net", "connect")))
}

/// A different capability/name is *also* denied — there is no privileged string. (Args are the
/// refined `List(Int)`; deny ignores them, so the asserted denial is unchanged.)
pub fn denies_arbitrary_capability_test() {
  host_denial(fn() { rt_host.call_host("anything", "at_all", [99]) })
  |> should.equal(Ok(#("anything", "at_all")))
}

/// The empty capability and empty name are denied too (no "blank = allowed" hole).
pub fn denies_empty_strings_test() {
  host_denial(fn() { rt_host.call_host("", "", []) })
  |> should.equal(Ok(#("", "")))
}

/// Cross-check: a spread of inputs all reject under the default posture.
pub fn always_denies_spread_test() {
  let denied = fn(cap: String, name: String) -> Bool {
    case host_denial(fn() { rt_host.call_host(cap, name, []) }) {
      Ok(_) -> True
      Error(_) -> False
    }
  }
  { denied("clock", "now") && denied("rand", "bytes") && denied("env", "get") }
  |> should.equal(True)
}

// ── The unseeded default is deny-all (fail-closed; the is_unseeded guard) ─────────

/// A fresh process that never seeded reads `HostDenyAll`. Proves "no seed ⇒ deny" — the
/// `is_unseeded` guard — the property that keeps all Phase-1/2 code (which never seeds)
/// denying every host call.
pub fn unseeded_current_policy_is_deny_all_test() {
  in_process(fn() { rt_host.current_policy() })
  |> should.equal(HostDenyAll)
}

/// Under the unseeded default, `call_host` denies EVERY pair — including `#("env","identity")`,
/// which HAS a build-fixed handler. Deny is not merely "no handler"; the default posture
/// itself denies.
pub fn unseeded_default_denies_even_handler_backed_test() {
  in_process(fn() {
    host_denial(fn() { rt_host.call_host("env", "identity", [7, 8]) })
  })
  |> should.equal(Ok(#("env", "identity")))

  in_process(fn() { host_denial(fn() { rt_host.call_host("fs", "open", []) }) })
  |> should.equal(Ok(#("fs", "open")))
}

// ── Seeded HostDenyAll denies unconditionally ────────────────────────────────────

/// Explicitly seeded `HostDenyAll` denies everything, including the handler-backed
/// `#("env","identity")` — deny-all is unconditional; no argument or handler makes it return.
pub fn deny_all_denies_even_handler_backed_test() {
  denial_under(HostDenyAll, "env", "identity", [7, 8])
  |> should.equal(Ok(#("env", "identity")))

  denial_under(HostDenyAll, "fs", "open", [])
  |> should.equal(Ok(#("fs", "open")))
}

// ── Whitelist admits exactly the listed pairs, denies the rest ───────────────────

/// `HostWhitelist([#("env","identity")])` admits exactly that listed, handler-backed pair
/// (dispatched to the vetted identity handler) and DENIES its complement — an unlisted
/// handler-less pair and the empty pair. "Admits exactly the listed, denies the rest."
pub fn whitelist_admits_exactly_listed_test() {
  let allow = [#("env", "identity")]

  call_under(HostWhitelist(allow), "env", "identity", [7, 8])
  |> should.equal(Ok([7, 8]))

  denial_under(HostWhitelist(allow), "fs", "open", [1])
  |> should.equal(Ok(#("fs", "open")))

  denial_under(HostWhitelist(allow), "", "", [])
  |> should.equal(Ok(#("", "")))
}

/// A pair that IS in the allow-set but has NO build-fixed handler is still denied — proving
/// the fail-closed conjunction (permitted AND implemented), not mere membership.
pub fn whitelisted_but_unimplemented_denies_test() {
  denial_under(HostWhitelist([#("fs", "open")]), "fs", "open", [1, 2])
  |> should.equal(Ok(#("fs", "open")))
}

// ── Open dispatches, but only to real handlers (no ambient authority) ─────────────

/// `HostOpen` dispatches a handler-backed pair (returning the handler's result bits) but a
/// handler-less pair `#("no","handler")` STILL denies — even open cannot invoke a
/// non-existent handler (D3a; §4.5.4 unprovided import).
pub fn open_dispatches_only_real_handlers_test() {
  call_under(HostOpen, "env", "identity", [42])
  |> should.equal(Ok([42]))

  denial_under(HostOpen, "no", "handler", [1])
  |> should.equal(Ok(#("no", "handler")))
}

// ── Per-instance isolation and coercion round-trip ───────────────────────────────

/// Seeding a policy in one process does NOT change `current_policy()` in a freshly-spawned
/// process (it reads `HostDenyAll`) — the pdict is process-local, the basis of F4 coexistence.
pub fn policy_is_process_local_test() {
  let seeded =
    in_process(fn() {
      rt_host.seed_policy(HostOpen)
      rt_host.current_policy()
    })
  let fresh = in_process(fn() { rt_host.current_policy() })

  seeded |> should.equal(HostOpen)
  fresh |> should.equal(HostDenyAll)
}

/// `current_policy` reflects the seeded value for all three postures — proving the identity
/// coercion round-trips (including the tuple-shaped `HostWhitelist`) and that `is_unseeded`
/// never false-positives on a genuinely seeded term.
pub fn current_policy_reflects_seed_test() {
  in_process(fn() {
    rt_host.seed_policy(HostDenyAll)
    rt_host.current_policy()
  })
  |> should.equal(HostDenyAll)

  in_process(fn() {
    rt_host.seed_policy(HostOpen)
    rt_host.current_policy()
  })
  |> should.equal(HostOpen)

  let wl = HostWhitelist([#("env", "identity"), #("fs", "open")])
  in_process(fn() {
    rt_host.seed_policy(wl)
    rt_host.current_policy()
  })
  |> should.equal(wl)
}

// ── Phase-5: the official `spectest` print family (R14, F8) ───────────────────────

/// The seven `#("spectest", print*)` pairs — the official host-module set (spec's `imports.wast`).
/// A LITERAL list here so the whitelist test mirrors `profiles.spectest_allow()` without coupling.
fn spectest_pairs() -> List(#(String, String)) {
  [
    #("spectest", "print"),
    #("spectest", "print_i32"),
    #("spectest", "print_i64"),
    #("spectest", "print_f32"),
    #("spectest", "print_f64"),
    #("spectest", "print_i32_f32"),
    #("spectest", "print_f64_f64"),
  ]
}

/// Under a whitelist admitting the seven `spectest` prints, EVERY `print*` is dispatched and
/// returns `[]` (the WASM result type `[]` — a side-effecting host fn that consumes its args and
/// yields nothing). Proves all seven arms exist and are handler-backed.
pub fn spectest_prints_dispatched_under_whitelist_test() {
  let allow = spectest_pairs()
  call_under(HostWhitelist(allow), "spectest", "print", [])
  |> should.equal(Ok([]))
  call_under(HostWhitelist(allow), "spectest", "print_i32", [42])
  |> should.equal(Ok([]))
  call_under(HostWhitelist(allow), "spectest", "print_i64", [42])
  |> should.equal(Ok([]))
  call_under(HostWhitelist(allow), "spectest", "print_f32", [0x4426A666])
  |> should.equal(Ok([]))
  call_under(HostWhitelist(allow), "spectest", "print_f64", [0x4084D4CCCCCCCCCD])
  |> should.equal(Ok([]))
  call_under(HostWhitelist(allow), "spectest", "print_i32_f32", [1, 0x4426A666])
  |> should.equal(Ok([]))
  call_under(HostWhitelist(allow), "spectest", "print_f64_f64", [0, 0])
  |> should.equal(Ok([]))
}

/// Under the fail-closed deny-all default, a `spectest` print DENIES (a `spectest`-importing
/// module linked without the whitelist gets no host authority) — the same fail-closed conjunction
/// as any other capability.
pub fn spectest_print_denied_under_deny_all_test() {
  denial_under(HostDenyAll, "spectest", "print_i32", [42])
  |> should.equal(Ok(#("spectest", "print_i32")))
}

/// The whitelist conjunction is per-pair: a whitelist admitting ONLY `print_i32` dispatches it
/// (`Ok([])`) but DENIES `print_f32` (listed-set membership is required, not merely being a
/// `spectest` name).
pub fn spectest_whitelist_is_per_pair_test() {
  let allow = [#("spectest", "print_i32")]
  call_under(HostWhitelist(allow), "spectest", "print_i32", [42])
  |> should.equal(Ok([]))
  denial_under(HostWhitelist(allow), "spectest", "print_f32", [0])
  |> should.equal(Ok(#("spectest", "print_f32")))
}

/// `spectest_func_type` returns each print's declared signature (the reference `spectest` module's
/// types) for link-time matching, and `Error(Nil)` for a non-`spectest` name (→ `UnknownImport`).
pub fn spectest_func_type_signatures_test() {
  rt_host.spectest_func_type("print")
  |> should.equal(Ok(ir.FuncType([], [])))
  rt_host.spectest_func_type("print_i32")
  |> should.equal(Ok(ir.FuncType([ir.TI32], [])))
  rt_host.spectest_func_type("print_i64")
  |> should.equal(Ok(ir.FuncType([ir.TI64], [])))
  rt_host.spectest_func_type("print_f32")
  |> should.equal(Ok(ir.FuncType([ir.TF32], [])))
  rt_host.spectest_func_type("print_f64")
  |> should.equal(Ok(ir.FuncType([ir.TF64], [])))
  rt_host.spectest_func_type("print_i32_f32")
  |> should.equal(Ok(ir.FuncType([ir.TI32, ir.TF32], [])))
  rt_host.spectest_func_type("print_f64_f64")
  |> should.equal(Ok(ir.FuncType([ir.TF64, ir.TF64], [])))
  rt_host.spectest_func_type("not_a_print") |> should.equal(Error(Nil))
}
