//// Unit 06 — the `passthrough ≡ own` differential + the build-time stdlib routing
//// (`shared_surface`/`passthrough_route`/`resolve`) for `rt_stdlib`.
////
//// Two kinds of assertion, both against the spec rather than the implementation:
////
//// 1. **Routing behaviour** — `resolve` names the own `rt_stdlib:gcd/2` target under
////    `StdlibOwn`, and under `StdlibPassthrough` falls back to that same target (the Phase-3
////    registry is empty; passthrough never silently drops a function). An off-surface name is
////    `Error(Nil)`. Anti-drift: every surface own target is on the `rt_bif` allowlist.
//// 2. **The differential (§D)** — for every shared function, resolving under `StdlibOwn` and
////    `StdlibPassthrough` and INVOKING the resolved build-fixed target on a spec-derived
////    battery yields the SAME answer, and that answer is the mathematical gcd. `gcd` is
////    integer-valued so value equality is bit-exact (D5/D7). The **non-vacuity self-test**
////    routes `gcd` to a deliberately-wrong target through the same harness and asserts the
////    differential FAILS — proving the green run above detects a real mismatch.
////
//// `invoke` calls a build-fixed `apply(Mod, Fun, Args)`: `Mod`/`Fun` are compile-time
//// constants from the routing table, not program data, so this test tooling does not violate
//// D3a (which constrains generated code, not the compiler's own tests). The catching-apply FFI
//// shim (`carder_emit_test_ffi:catch_apply/3`) surfaces a raising target as `Error(text)`
//// rather than crashing the runner.

import carder/runtime/instance.{StdlibOwn, StdlibPassthrough}
import carder/runtime/rt_bif.{type BifTarget, BifTarget}
import carder/runtime/rt_stdlib
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

// Test-only FFI (shared with the unit-08 e2e suite): apply `M:F(Args)` and capture a raise as
// `Error(text)` instead of crashing the runner.
@external(erlang, "carder_emit_test_ffi", "catch_apply")
fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

/// The vetted own-impl module the tests resolve against (`rt_stdlib`, the D3a-invariant
/// `stdlib_module`).
const own_module = "carder@runtime@rt_stdlib"

/// Invoke a resolved BUILD-FIXED `target` on integer `args`, catching any raise as
/// `Error(text)`. `target.module`/`target.function` are compile-time constants from the
/// routing table (never program data), so the build-fixed apply is D3a-legitimate test tooling.
fn invoke(target: BifTarget, args: List(Int)) -> Result(Int, String) {
  catch_apply(atom.create(target.module), atom.create(target.function), args)
}

/// The spec battery for `gcd`, from the MATHEMATICAL definition (not the code): each
/// `#(args, expected_gcd)`. Covers commutativity, the zero conventions (`gcd(n,0)=|n|`,
/// `gcd(0,0)=0`), coprimality, negatives folded to magnitude, and large bignums crossing the
/// 60-bit small-int boundary (so a native-int passthrough that silently truncated would
/// diverge here).
fn gcd_battery() -> List(#(List(Int), Int)) {
  [
    #([12, 18], 6),
    #([18, 12], 6),
    #([0, 5], 5),
    #([5, 0], 5),
    #([0, 0], 0),
    #([17, 5], 1),
    #([48, 36], 12),
    #([-12, 18], 6),
    #([12, -18], 6),
    #([-12, -18], 6),
    // large bignums: gcd(6k, 4k) = 2k, k = 10^18 (> 2^59, so a BEAM bignum).
    #(
      [6_000_000_000_000_000_000, 4_000_000_000_000_000_000],
      2_000_000_000_000_000_000,
    ),
  ]
}

/// The spec battery for a surface `name` (empty for a name with no battery). Parameterises the
/// differential over `shared_surface()`.
fn battery_for(name: String) -> List(#(List(Int), Int)) {
  case name {
    "gcd" -> gcd_battery()
    _ -> []
  }
}

// ───────────────────────────── routing behaviour ─────────────────────────────

/// `shared_surface` is the single source of truth — the Phase-3 surface is exactly `gcd/2`
/// (F7 adds no new frontend surface).
pub fn shared_surface_is_gcd_only_test() {
  rt_stdlib.shared_surface()
  |> should.equal([#("gcd", "gcd", 2)])
}

/// The Phase-3 passthrough registry is EMPTY: `gcd` is kept in-house (`None`).
pub fn gcd_has_no_passthrough_route_test() {
  rt_stdlib.passthrough_route("gcd", 2)
  |> should.equal(None)
}

/// `resolve` under `StdlibOwn` names the own `rt_stdlib:gcd/2` target (Safe path, unchanged).
pub fn resolve_own_targets_rt_stdlib_test() {
  rt_stdlib.resolve("gcd", 2, StdlibOwn, own_module)
  |> should.equal(Ok(BifTarget(own_module, "gcd", 2)))
}

/// `resolve` under `StdlibPassthrough` FALLS BACK to the same own target (empty registry) —
/// passthrough never silently drops a function.
pub fn resolve_passthrough_falls_back_to_own_test() {
  rt_stdlib.resolve("gcd", 2, StdlibPassthrough, own_module)
  |> should.equal(Ok(BifTarget(own_module, "gcd", 2)))
}

/// On the current surface, `StdlibOwn` and `StdlibPassthrough` resolve to the SAME target for
/// every entry (conformance-neutral by construction, F7).
pub fn resolve_own_equals_passthrough_on_surface_test() {
  list.each(rt_stdlib.shared_surface(), fn(entry) {
    let #(name, _fn, arity) = entry
    let own = rt_stdlib.resolve(name, arity, StdlibOwn, own_module)
    let pt = rt_stdlib.resolve(name, arity, StdlibPassthrough, own_module)
    own |> should.equal(pt)
  })
}

/// `resolve` honours `own_module` (never hard-codes it), so it and the `rt_bif` allowlist agree
/// by construction whatever module the binding names.
pub fn resolve_uses_own_module_test() {
  rt_stdlib.resolve("gcd", 2, StdlibOwn, "some@other@module")
  |> should.equal(Ok(BifTarget("some@other@module", "gcd", 2)))
}

/// An off-surface name (or a wrong arity) resolves to `Error(Nil)` under both modes — the
/// unknown-stdlib-fn signal (`ir_lower` maps it to `UnknownStdlibFn`).
pub fn resolve_off_surface_is_error_test() {
  rt_stdlib.resolve("sqrt", 1, StdlibOwn, own_module)
  |> should.equal(Error(Nil))
  rt_stdlib.resolve("gcd", 3, StdlibPassthrough, own_module)
  |> should.equal(Error(Nil))
}

// ───────────────────────────── anti-drift (§C.3) ─────────────────────────────

/// Anti-drift: every `shared_surface()` own target is on the `rt_bif.allowlist()` — the own
/// path is always Safe-gateable, so a mis-registered surface entry is caught HERE, not at
/// runtime.
pub fn surface_own_targets_are_allowlisted_test() {
  list.each(rt_stdlib.shared_surface(), fn(entry) {
    let #(name, _fn, arity) = entry
    let assert Ok(own_t) = rt_stdlib.resolve(name, arity, StdlibOwn, own_module)
    rt_bif.is_allowed(own_t) |> should.equal(True)
  })
}

/// Anti-drift: every REGISTERED `passthrough_route` is a well-formed `BifTarget` naming a
/// `carder@runtime@rt_*` runtime module (D3a — never a bare `erlang`/OTP module). Vacuous
/// today (empty registry) but the guard every future route must clear.
pub fn passthrough_routes_are_runtime_targets_test() {
  list.each(rt_stdlib.shared_surface(), fn(entry) {
    let #(name, _fn, arity) = entry
    case rt_stdlib.passthrough_route(name, arity) {
      None -> Nil
      Some(t) -> {
        string.starts_with(t.module, "carder@runtime@rt_")
        |> should.equal(True)
        { t.arity >= 0 } |> should.equal(True)
        Nil
      }
    }
  })
}

// ───────────────────────── the `passthrough ≡ own` differential (§D) ─────────────────────────

/// §D differential: for every shared function, INVOKING the `StdlibOwn`- and
/// `StdlibPassthrough`-resolved build-fixed targets on every battery input yields the SAME
/// answer (`gcd` is integer-valued so value equality is bit-exact, D5/D7). The answer is also
/// asserted to equal the mathematical gcd, grounding the differential in the spec rather than
/// mere self-consistency.
pub fn passthrough_equals_own_differential_test() {
  list.each(rt_stdlib.shared_surface(), fn(entry) {
    let #(name, _fn, arity) = entry
    let assert Ok(own_t) = rt_stdlib.resolve(name, arity, StdlibOwn, own_module)
    let assert Ok(pt_t) =
      rt_stdlib.resolve(name, arity, StdlibPassthrough, own_module)
    list.each(battery_for(name), fn(case_) {
      let #(args, expected) = case_
      let own_r = invoke(own_t, args)
      let pt_r = invoke(pt_t, args)
      // the differential: own ≡ passthrough on this input.
      own_r |> should.equal(pt_r)
      // grounded in the spec: the own answer IS the mathematical gcd.
      own_r |> should.equal(Ok(expected))
    })
  })
}

/// §D.3 NON-VACUITY: a deliberately-wrong route (routing `gcd` to `erlang:'-'/2` subtraction),
/// run through the SAME `invoke` harness, must DIFFER from the own target on at least one
/// battery input. This proves the green differential above detects a real mismatch — it is not
/// vacuous. (The wrong target is build-fixed too; the harness never applies program data.)
pub fn differential_is_non_vacuous_test() {
  let assert Ok(own_t) = rt_stdlib.resolve("gcd", 2, StdlibOwn, own_module)
  let wrong_t = BifTarget("erlang", "-", 2)
  let differs =
    list.any(gcd_battery(), fn(case_) {
      let #(args, _expected) = case_
      invoke(own_t, args) != invoke(wrong_t, args)
    })
  differs |> should.equal(True)
}
