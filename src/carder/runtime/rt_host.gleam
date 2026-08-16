//// `rt_host` — the per-instance capability boundary (F4). Fail-closed (D4/D9).
////
//// `CallHost` is the single IR node for every call that leaves the module's own values
//// (host imports and `own` stdlib alike). `ir_lower` (unit 11) rewrites a *resolved*
//// `own`-stdlib call into a direct `rt_stdlib` call; a *genuine host import* is left as a
//// `call 'carder@runtime@rt_host':'call_host'(Cap, Name, Args)` (the calling convention
//// in `runtime/instance.gleam`) and lands here — where THIS instance's `HostPolicy`
//// decides whether it is dispatched or denied.
////
//// ## The three postures (F4) — one build-controlled module, per-instance behaviour
////
//// The `HostPolicy` selects *behaviour*, never a module swap — `host_module` is the single
//// build-controlled `carder@runtime@rt_host` for Safe AND Unsafe (keystone §B.4). The
//// posture is per-instance state, seeded into the owning process's dictionary at
//// instantiation (like `rt_meter`'s fuel budget and `rt_state`'s cell, E1):
////
//// - `HostDenyAll` — every call denied (the Phase-1 fail-closed boundary, unchanged). The
////   **unseeded default**, so all Phase-1/2 code (which never seeds) still denies every host
////   call.
//// - `HostWhitelist(allow)` — dispatched iff `#(cap,name)` is in the build-controlled allow
////   set AND a vetted handler exists; every other pair is denied (fail-closed conjunction).
//// - `HostOpen` — dispatched iff a vetted handler exists; a handler-less pair is STILL denied
////   (even open cannot invoke a non-existent handler — no ambient authority).
////
//// ## No ambient authority survives open (D3a)
////
//// The `#(capability, name) → handler` mapping is a build-fixed literal `case`
//// (`resolve_handler/2`), exactly as `rt_bif.allowlist/0` is a fixed list and `rt_table`
//// dispatches through build-controlled closures. The dispatched target is always a closure
//// written in THIS module, invoked directly (`handler(args)`); `rt_host` NEVER builds a
//// module/function atom from `capability`/`name`/`args` and NEVER calls `erlang:apply/3` on
//// data-derived names. "Open" widens *which build-fixed handlers are reachable*; it adds no
//// new authority.
////
//// ## The rejection term shape (byte-identical to Phase 1)
////
//// A denied call raises the catchable error-class reason `{capability_denied, Cap, Name}`,
//// echoing which capability/name was rejected. Error class (not `throw`/`exit`) so it is
//// catchable the same way traps are — unit 11's runner surfaces a denial as an ordinary
//// `Trapped`, no new plumbing.
////
//// ## Fail-closed by default (D4)
////
//// `current_policy()` returns `HostDenyAll` when no policy was seeded — deny is the safe
//// omission, so a build that forgets to seed still denies. There is no `#(cap,name)`,
//// argument, seeded value, or handler that turns `HostDenyAll` into a return; `HostOpen` is
//// reachable only through `profiles.unsafe()` (an explicit, tested opt-in). The seed is
//// wired by `emit_core`'s `instantiate/0` (unit 09), which emits
//// `rt_host:seed_policy(binding.host_policy)` alongside `rt_meter.seed_fuel`.

import carder/runtime/instance.{
  type HostPolicy, HostDenyAll, HostOpen, HostWhitelist,
}
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/list

/// `erlang:error/1` — raises an error-class exception with the given reason and never
/// returns (catchable via `try … catch error:Reason`). Direct BIF reference (tier-P;
/// raises, does not crash the node).
@external(erlang, "erlang", "error")
fn erlang_error(reason: a) -> b

/// `erlang:put/2` — store `value` under `key` in the current process dictionary; returns
/// the previous value (or the atom `undefined` if unset), which callers here discard.
/// Direct BIF reference; process-local, cannot crash the node. Process-local ⇒ two
/// instances on one node gate INDEPENDENTLY (F4 coexistence).
@external(erlang, "erlang", "put")
fn erlang_put(key: k, value: v) -> Dynamic

/// `erlang:get/1` — read `key` from the current process dictionary, or the atom
/// `undefined` if it was never set. Typed `Dynamic` because the result is either a seeded
/// `HostPolicy` term or `undefined`; `current_policy` guards the `undefined` case first.
@external(erlang, "erlang", "get")
fn erlang_get(key: k) -> Dynamic

/// Identity coercion of the stored `Dynamic` back to `HostPolicy`. Sound because `rt_host`
/// is the SOLE producer of the term under this key (the `rt_table`/`rt_mem` cell-coercion
/// precedent). Only reached for a seeded value; the unseeded `undefined` atom is guarded
/// FIRST by `is_unseeded` (see `current_policy`).
@external(erlang, "gleam_stdlib", "identity")
fn coerce_policy(raw: Dynamic) -> HostPolicy

/// Identity coercion of the stored host output cell (`Dynamic`) back to a `BitArray`. Sound
/// because `rt_host` is the SOLE producer of the term under `CarderRtHostOutput` (the same
/// cell-coercion precedent as `coerce_policy`). Only reached for a seeded value; the unseeded
/// `undefined` atom is guarded FIRST by `is_unseeded` (see `read_output_cell`).
@external(erlang, "gleam_stdlib", "identity")
fn coerce_bitarray(raw: Dynamic) -> BitArray

/// The process-dictionary key holding this process's host policy. As a 0-field Gleam
/// constructor it compiles to the unique, namespace-hygienic atom `carder_rt_host_policy`,
/// so it cannot clash with `rt_meter`'s fuel keys, `rt_state`'s cell, or any other library's
/// pdict keys.
type HostKey {
  CarderRtHostPolicy
}

/// The fixed tag of the deny rejection reason. As a 0-field Gleam constructor it compiles to
/// the Erlang atom `capability_denied` (unchanged from Phase 1).
type Tag {
  CapabilityDenied
}

/// The process-dictionary key holding THIS instance's host output buffer (§E). As a
/// 0-field Gleam constructor it compiles to the unique atom `carder_rt_host_output`,
/// disjoint from the host-policy key, `rt_meter`'s fuel, and `rt_state`'s cell — so the buffer
/// is per-instance (process-local) and GC'd with the instance's owned process (E1).
type HostOutKey {
  CarderRtHostOutput
}

/// A vetted host handler: raw WASM argument bit patterns (D5 — i32/i64/f32/f64 all `Int`) →
/// result bit patterns. Every handler is TOTAL and node-safe (tier-P/O, never a
/// node-crashing partial) — a host handler that could crash the node is a sandbox hole. Its
/// FuncType-correctness is the embedder's contract; `rt_host` invokes it structurally by
/// argument list, the same `List(Int) -> List(Int)` shape `call_indirect` uses.
pub type HostHandler =
  fn(List(Int)) -> List(Int)

/// Seed THIS instance's host policy (F4). Called once by `emit_core`'s synthesized
/// `instantiate/0` (unit 09 — the sole seed emitter) inside the instance's OWNED process,
/// alongside `rt_meter.seed_fuel` and the `rt_state` cell — so the posture is isolated per
/// instance and GC'd with the process.
///
/// - `policy`: the build-controlled `binding.host_policy` (`HostDenyAll` for Safe,
///   `HostWhitelist(allow)` for Safe-whitelist, `HostOpen` for Unsafe). The value is baked
///   as a Core Erlang literal at emit time from the `Binding` — it is NEVER derived from
///   program data.
/// - Returns `Nil`. Total; process-local; cannot crash the node. A (re)instantiation
///   re-seeds ⇒ a fresh posture (one atomic `put`).
pub fn seed_policy(policy: HostPolicy) -> Nil {
  let _ = erlang_put(CarderRtHostPolicy, policy)
  Nil
}

/// The host policy in effect for the CURRENT process.
///
/// - Returns the seeded `HostPolicy`, or **`HostDenyAll` when no policy was seeded** — the
///   FAIL-CLOSED default (D4). `erlang:get/1` yields the atom `undefined` for an absent key;
///   `current_policy` treats that as deny, so Phase-1/2 code (which never seeds) still denies
///   every host call. Total; never raises; exposed for tests.
/// - The `is_unseeded` guard runs FIRST — it, not `coerce_policy`, is what makes "no seed ⇒
///   deny" a hard property. `HostDenyAll`/`HostOpen` compile to the atoms
///   `host_deny_all`/`host_open` and `HostWhitelist(_)` to `{host_whitelist, Allow}` — all
///   distinct from `undefined`, so the guard is unambiguous.
pub fn current_policy() -> HostPolicy {
  let raw = erlang_get(CarderRtHostPolicy)
  case is_unseeded(raw) {
    True -> HostDenyAll
    False -> coerce_policy(raw)
  }
}

/// `True` iff `raw` is the Erlang atom `undefined` (what `erlang:get/1` returns for a
/// never-set key). LOAD-BEARING: this guard, not the identity coercion, is what makes the
/// unseeded posture deny-all (D4). Any seeded `HostPolicy` term decodes to a distinct atom
/// (`host_deny_all`/`host_open`) or a tuple (`{host_whitelist, _}`), none of which is
/// `undefined`, so a false positive is impossible. Total; never raises.
fn is_unseeded(raw: Dynamic) -> Bool {
  case decode.run(raw, atom.decoder()) {
    Ok(a) -> atom.to_string(a) == "undefined"
    Error(_) -> False
  }
}

/// Resolve the BUILD-FIXED vetted handler for a host `#(capability, name)`, if carder provides
/// one. This mapping is a literal `case` in THIS module — it is NEVER constructed from program
/// or runtime data (D3a): the only inputs are the static capability/name strings, and the
/// result is a closure written here at build time, invoked directly (`handler(args)`), never
/// `apply(Mod, Fun, Args)` with a data-derived `Mod`/`Fun`.
///
/// Returns `Ok(handler)` for a vetted pair, `Error(Nil)` when carder implements no such host
/// function. `Error(Nil)` is FAIL-CLOSED for BOTH whitelist and open: an unimplemented import
/// is denied, never assumed callable (WebAssembly spec §4.5.4 — an unprovided import is not
/// callable).
fn resolve_handler(
  capability: String,
  name: String,
) -> Result(HostHandler, Nil) {
  case capability, name {
    // The Phase-3 host environment is deliberately minimal (F7/F8 add no host surface). This
    // single representative handler is deterministic + side-effect-free (tier-P), so it
    // neither perturbs the F2 optimizer differential nor introduces non-determinism, and it
    // exercises the admit path end-to-end. carder itself implements NO named host module: a
    // frontend's host surface (the spec suite's `spectest`, a Porffor guest's `""` intrinsics,
    // a TeaVM guest's `teavmJso`) is supplied as a `link.Provider.Namespace` in the frontend's
    // own repo, whose handlers are closures the trusted embedder hands in — the same
    // capability shape as `ProvidedFunc`, so nothing here has to know a producer's name.
    "env", "identity" -> Ok(fn(args) { args })
    _, _ -> Error(Nil)
  }
}

/// Dispatch a host import under THIS instance's policy (F4). ABI: arity 3, name `call_host`,
/// emitted verbatim by `emit_core` — UNCHANGED, so no generated code changes. Its type is
/// refined from the Phase-1 `List(x) -> a` to `List(Int) -> List(Int)` so a dispatched call
/// can *return* a result; behaviour-preserving for every existing path (deny-all never
/// returns, and no corpus program consumes a host result yet).
///
/// - `capability` / `name`: the import's `#(capability, name)` identity (echoed on denial).
/// - `args`: the call's raw WASM argument bit patterns (D5).
/// - Return: the handler's result bit patterns on a permitted, implemented call; otherwise it
///   **diverges** by raising the catchable `{capability_denied, Capability, Name}` (error
///   class — the same channel traps ride).
///
/// Policy semantics (fail-closed conjunction — permitted AND implemented):
/// - `HostDenyAll` — **every** call denied (no `#(cap,name)`, argument, or handler makes it
///   return). Deny-all denies even a call for which `resolve_handler` HAS a handler.
/// - `HostWhitelist(allow)` — dispatched iff `#(cap,name) ∈ allow` AND a handler exists; every
///   other pair (unlisted, or listed-but-unimplemented) is denied.
/// - `HostOpen` — dispatched iff a handler exists; a `#(cap,name)` with no build-fixed handler
///   is STILL denied (even open cannot invoke a non-existent handler — no ambient authority).
pub fn call_host(
  capability: String,
  name: String,
  args: List(Int),
) -> List(Int) {
  case current_policy() {
    HostDenyAll -> deny(capability, name)
    HostWhitelist(allow) ->
      case list.contains(allow, #(capability, name)) {
        True -> dispatch(capability, name, args)
        False -> deny(capability, name)
      }
    HostOpen -> dispatch(capability, name, args)
  }
}

/// Resolve the build-fixed handler and invoke it DIRECTLY (`handler(args)` — a closure
/// application, never `apply/3` on data-derived names, D3a). No build-fixed handler ⇒ deny
/// (fail-closed for both whitelist and open). Private: the single admit chokepoint.
fn dispatch(capability: String, name: String, args: List(Int)) -> List(Int) {
  case resolve_handler(capability, name) {
    Ok(handler) -> handler(args)
    Error(Nil) -> deny(capability, name)
  }
}

/// Raise the Phase-1 deny term (byte-identical): error-class `{capability_denied, Cap, Name}`.
/// Never returns; typed `-> List(Int)` so it unifies with `call_host`'s refined return type.
/// Private: the single denial chokepoint every posture routes through.
fn deny(capability: String, name: String) -> List(Int) {
  erlang_error(#(CapabilityDenied, capability, name))
}

// ───────────────────────────── the per-instance host output buffer (§E) ─────────────────────────────

/// Read THIS process's accumulated host output buffer, or `<<>>` if never written. The
/// `is_unseeded` guard runs FIRST (the same fail-safe as `current_policy`): `erlang:get/1`
/// yields the atom `undefined` for an absent key, treated as the empty buffer — so a
/// never-printed (or unseeded) instance reads `<<>>`, never a crash. Private.
fn read_output_cell() -> BitArray {
  let raw = erlang_get(CarderRtHostOutput)
  case is_unseeded(raw) {
    True -> <<>>
    False -> coerce_bitarray(raw)
  }
}

/// Append `bytes` to THIS instance's host output buffer — the sink a frontend's `print`-style
/// host handler writes to (e.g. scribbler's Porffor `print`/`printChar` intrinsics). Reads the
/// current buffer (or `<<>>` if unseeded — the buffer self-initialises empty per instance
/// process, so no explicit seed is required), appends, and stores.
///
/// PUBLIC because the handlers that write to it live in the FRONTEND's repo now, while the
/// buffer itself must live here: it is process-local to the instance's owned process (E1) and
/// is drained through carder's own run-ABI (`pipeline.host_output`). Total; process-local;
/// cannot crash the node — it grants no authority beyond appending bytes to a pdict cell that
/// is GC'd with the instance.
pub fn append_output(bytes: BitArray) -> Nil {
  let _ =
    erlang_put(CarderRtHostOutput, bit_array.append(read_output_cell(), bytes))
  Nil
}

/// Clear THIS instance's host output buffer to `<<>>`. Provided for an explicit reset (and for
/// tests); NOT required at instantiate because `append_output` self-initialises the buffer
/// empty in each instance's fresh owned process (E1). Total; process-local; cannot crash the
/// node.
pub fn host_output_seed() -> Nil {
  let _ = erlang_put(CarderRtHostOutput, <<>>)
  Nil
}

/// Read THIS instance's accumulated host output as a raw `BitArray` — the exact byte stream a
/// frontend's `print`-style handlers produced, including any ANSI escapes (baked in-band).
/// Must run IN the instance's owned process (the buffer is process-local, E1), so a caller
/// routes a call into that process to collect it (`pipeline.host_output`). Returns `<<>>` for a
/// never-printed (or unseeded) instance — fail-safe empty, never a crash. Total.
pub fn host_output() -> BitArray {
  read_output_cell()
}
