//// `rt_stdlib` — the minimal Safe `own` standard library. Tiny + auditable by design (D9).
////
//// The positive path of the capability boundary: unit 11's `ir_lower` recognises a
//// `CallHost(capability, name)` that maps to an `own`-stdlib entry, gates the resolved
//// BEAM target through `rt_bif.check`, and rewrites it into a direct call into this
//// module — `call 'carder@runtime@rt_stdlib':'<fn>'(Args…)`. A vetted stdlib call does
//// **not** go through the deny-all host.
////
//// Phase 1 ships a single vetted function (`gcd`) to exercise that positive path
//// end-to-end. Breadth (and the `passthrough` Unsafe stdlib) is deferred to Phase 2 (D9).
//// Everything here must be **tier-P**: pure, total, no host access, cannot crash the node.
////
//// ## Coordination (the `(capability, name)` → fn map)
////
//// The mapping from an IR `CallHost(capability, name)` to this module's functions is
//// owned by unit 11's `ir_lower` (the rewrite) and unit 08 (the emit). The suggested
//// Phase-1 entry is `(capability: "std", name: "gcd")` → `rt_stdlib:gcd/2`, whose BEAM
//// target `("carder@runtime@rt_stdlib", "gcd", 2)` is on the `rt_bif` allowlist.
////
//// ## Phase-3 addition: BUILD-TIME stdlib routing (`shared_surface`/`passthrough_route`/`resolve`, F6)
////
//// The routing functions below are consulted by `ir_lower` (unit 08) at **compile time** to
//// choose a call target under `StdlibOwn` vs `StdlibPassthrough`; they are the single source
//// of truth for the shared surface (unit 08 retires its local `own_stdlib_surface`). They are
//// **NOT** called by generated code — only the runtime bodies (`gcd`) are. A passthrough route
//// is ALWAYS realized as a thin vetted shim INSIDE this module (its target module is invariably
//// `stdlib_module`, a `carder@runtime@rt_*` module in the D3a `runtime_modules` set), so the
//// emitted call's module atom is byte-identical under both profiles — only the in-module
//// implementation differs. There is never a route to a bare `erlang`/OTP module.
////
//// **Honest scope (F8): Phase 3 ships ZERO active passthrough routes.** The sole shared
//// function, `gcd`, has no BEAM equivalent that is simultaneously faster, trusted/node-safe,
//// and observably identical, so it is kept in-house under BOTH profiles and
//// `passthrough_route("gcd", 2) == None`. What ships is the *mechanism* — the routing table,
//// the resolver, and the `passthrough ≡ own` differential (with its non-vacuity self-test) —
//// fully working and proven. Each future route is added to `passthrough_route` and admitted
//// only by passing that differential. Acyclic: `rt_stdlib → rt_bif → instance → ir_opt → ir`
//// (nothing on that chain imports `rt_stdlib`).

import carder/runtime/instance.{type StdlibMode, StdlibOwn, StdlibPassthrough}
import carder/runtime/rt_bif.{type BifTarget, BifTarget}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// The greatest common divisor of `a` and `b`, by the Euclidean algorithm.
///
/// Spec/definition (mathematics, not the implementation): `gcd` is the largest
/// non-negative integer dividing both arguments, with the conventions `gcd(n, 0) = |n|`,
/// `gcd(0, n) = |n|`, and `gcd(0, 0) = 0`.
///
/// - `a`, `b`: any integers (BEAM bignums; negatives are handled — the result is the
///   non-negative gcd of their magnitudes).
/// - Return: the gcd as a non-negative `Int`. Total — never traps, never raises, no host
///   access. Tail-recursive, so it runs in constant stack space.
pub fn gcd(a: Int, b: Int) -> Int {
  case b {
    0 -> int.absolute_value(a)
    _ -> gcd(b, a % b)
  }
}

// ─────────────────────── BUILD-TIME stdlib routing (F6, unit 08 adopts) ───────────────────────

/// The shared stdlib **surface**: the `#(ir_name, own_fn, arity)` triples a frontend may reach
/// via `CallHost(stdlib_capability, ir_name, args)`. This is the single source of truth for the
/// surface — unit 08 adopts it, retiring `ir_lower`'s local `own_stdlib_surface` so the two
/// cannot drift.
///
/// - `ir_name`: the name used in the IR `CallHost`.
/// - `own_fn`: the `rt_stdlib` function the `own` body lives in.
/// - `arity`: the parameter count of both.
///
/// Return: the surface as a `List(#(String, String, Int))`. Phase-3 surface is exactly
/// `#("gcd", "gcd", 2)` (F7 adds no new frontend surface, so passthrough must stay
/// conformance-neutral over exactly this set). Total.
pub fn shared_surface() -> List(#(String, String, Int)) {
  [#("gcd", "gcd", 2)]
}

/// The passthrough route for a shared-stdlib `name`/`arity`, or `None` to keep it IN-HOUSE.
///
/// A registered route always names a thin shim INSIDE `rt_stdlib` (module = `stdlib_module`, a
/// `carder@runtime@rt_*` module in the D3a `runtime_modules` set) whose body calls the faster
/// BIF — NEVER a bare `erlang`/OTP module — so the emitted call's module atom is invariant
/// across profiles. A route is registered ONLY when the wrapped BIF is, provably, ALL of:
///   (a) FASTER than the own body on the hot path;
///   (b) TRUSTED — a vetted OTP function that is node-safe (cannot crash the node, no
///       partial/`badarg` reachable on the call's domain);
///   (c) OBSERVABLY IDENTICAL to the own body across the WHOLE input domain incl. every
///       spec/edge case (the `passthrough ≡ own` differential is the admission gate).
/// If any of (a)/(b)/(c) fails, the function is KEPT IN-HOUSE (`None`).
///
/// - `name`/`arity`: the shared-stdlib function being routed.
/// - Return: `Some(target)` if a route is registered, else `None`.
///
/// Phase-3 registry is EMPTY: `gcd` (the sole shared fn) has no BEAM equivalent satisfying
/// (a)+(b)+(c) — OTP ships no `gcd` BIF, and `gcd`'s sign/zero conventions plus its
/// constant-space tail recursion are load-bearing — so it stays in-house and
/// `passthrough_route("gcd", 2) == None`. This function is the seam future routes are added to,
/// each admitted only by passing the differential. Total.
pub fn passthrough_route(name: String, arity: Int) -> Option(BifTarget) {
  case name, arity {
    // No shared function has a qualifying BEAM equivalent in Phase 3. A future route is added
    // as an arm here returning `Some(BifTarget(<stdlib_module-invariant shim>, ...))`.
    _, _ -> None
  }
}

/// Resolve a shared-stdlib call to its concrete build-fixed BEAM `BifTarget` under `mode`.
///
/// - `StdlibOwn`         → the own target `own_module:<own_fn>/arity` (Safe; unchanged path).
/// - `StdlibPassthrough` → `passthrough_route(name, arity)` if registered — a shim in the SAME
///   `own_module`, so only the target *function* differs and the emitted module atom is
///   unchanged — else the own target (the in-house fallback; passthrough NEVER silently drops a
///   function).
///
/// - `name`/`arity`: the shared-stdlib function and its call arity.
/// - `mode`: the resolution strategy from `binding.stdlib`.
/// - `own_module`: the own-impl module name, read from `binding.stdlib_module` (never
///   hard-coded, so `resolve` and the `rt_bif` allowlist agree by construction).
///
/// Return: `Ok(target)` with a BUILD-FIXED triple (D3a — module/fn/arity are compiler data,
/// never program input), or `Error(Nil)` iff `name`/`arity` is not on `shared_surface()` (an
/// unknown stdlib fn — `ir_lower` maps this to `UnknownStdlibFn`). Total — never panics.
pub fn resolve(
  name: String,
  arity: Int,
  mode: StdlibMode,
  own_module: String,
) -> Result(BifTarget, Nil) {
  case list.find(shared_surface(), fn(e) { e.0 == name && e.2 == arity }) {
    Error(_) -> Error(Nil)
    Ok(#(_ir_name, own_fn, own_arity)) -> {
      let own_target =
        BifTarget(module: own_module, function: own_fn, arity: own_arity)
      case mode {
        StdlibOwn -> Ok(own_target)
        StdlibPassthrough ->
          case passthrough_route(name, arity) {
            Some(route) -> Ok(route)
            None -> Ok(own_target)
          }
      }
    }
  }
}
