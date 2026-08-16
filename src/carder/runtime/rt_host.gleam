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

import carder/ir.{type FuncType, FuncType, TF32, TF64, TI32, TI64}
import carder/runtime/instance.{
  type HostPolicy, HostDenyAll, HostOpen, HostWhitelist,
}
import carder/runtime/porffor_abi
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

/// Identity coercion of the stored Porffor output cell (`Dynamic`) back to a `BitArray`. Sound
/// because `rt_host` is the SOLE producer of the term under `CarderRtPorfforOutput` (the same
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

/// The process-dictionary key holding THIS instance's Porffor console output buffer (§E). As a
/// 0-field Gleam constructor it compiles to the unique atom `carder_rt_porffor_output`,
/// disjoint from the host-policy key, `rt_meter`'s fuel, and `rt_state`'s cell — so the buffer
/// is per-instance (process-local) and GC'd with the instance's owned process (E1).
type PorfOutKey {
  CarderRtPorfforOutput
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
    // exercises the admit path end-to-end. The broad environment (spectest, the Porffor host
    // shim) plugs into this same registry in Phase 5/6 — one new arm each, no dispatch change.
    "env", "identity" -> Ok(fn(args) { args })
    // ── Phase 5: the official `spectest` host module's `print*` family (R14, F8). Each
    //    consumes its argument bit patterns and returns `[]` (the WASM result type `[]`), so it
    //    is deterministic + node-safe (tier-P/O) and a no-op body is spec-adequate — the suite
    //    NEVER asserts on print output. These are the DISPATCH face of `spectest`; their declared
    //    signatures are the build-fixed `spectest_func_type` table below (link-matching, §C.3) —
    //    the two literal cases MUST agree on this exact set of seven names. A `spectest` print is
    //    still DENIED unless the instance's `HostPolicy` admits `#("spectest", name)`
    //    (`profiles.safe_spectest()`), so the fail-closed conjunction is unchanged.
    "spectest", "print" -> Ok(fn(_args) { [] })
    "spectest", "print_i32" -> Ok(fn(_args) { [] })
    "spectest", "print_i64" -> Ok(fn(_args) { [] })
    "spectest", "print_f32" -> Ok(fn(_args) { [] })
    "spectest", "print_f64" -> Ok(fn(_args) { [] })
    "spectest", "print_i32_f32" -> Ok(fn(_args) { [] })
    "spectest", "print_f64_f64" -> Ok(fn(_args) { [] })
    // ── Phase 7: the Porffor runtime intrinsics (module ""), keyed on the build-fixed
    //    creation-order ident LETTER (§A.3, Porffor 0.61.13 `precompile.js`/`wrap.js`).
    //    print/printChar are SIDE-EFFECTING (append to this instance's output buffer, §E);
    //    time/timeOrigin read a (deterministic) clock. Each is TOTAL + node-safe (tier-P/O),
    //    so it perturbs no optimizer differential beyond the CallHost barrier already
    //    respected. A literal `case` selecting a build-fixed closure written here — never a
    //    data-derived target (D3a). An `""` name outside {a,b,c,d} falls through to deny.
    "", "a" -> Ok(porffor_print)
    // print      : (param f64) -> ()  — a number → its ECMAScript decimal string
    "", "b" -> Ok(porffor_print_char)
    // printChar  : (param f64) -> ()  — one UTF-16 code unit → its UTF-8 bytes
    "", "c" -> Ok(porffor_time)
    // time       : () -> (result f64) — performance.now() (deterministic 0.0, §B.2)
    "", "d" -> Ok(porffor_time_origin)
    // timeOrigin : () -> (result f64) — performance.timeOrigin (deterministic 0.0)
    _, _ -> Error(Nil)
  }
}

/// The build-fixed Porffor-0.61.13 intrinsic ident letters (module `""`), in `createImport`
/// creation order (§A.3, `compiler/builtins.js` `const ident = String.fromCharCode(97 +
/// importedFuncs.length)`): `print → "a"`, `printChar → "b"`, `time → "c"`, `timeOrigin → "d"`.
/// The LETTER is the stable identity (the assembler tree-shakes + re-orders the func *index*
/// but emits each survivor's original ident verbatim, `assemble.js:184`). Named so the pin is
/// legible and a Porffor version bump is a conscious one-line re-measure, never a silent
/// mis-dispatch. `#(letter, builtin)`.
pub const porffor_intrinsics: List(#(String, String)) = [
  #("a", "print"),
  #("b", "printChar"),
  #("c", "time"),
  #("d", "timeOrigin"),
]

/// `print` (Porffor `""."a"`, `i => print(i.toString())`). Appends the number's ECMAScript
/// decimal string (`Number::toString(x, 10)`, §F) to THIS instance's output buffer (§E).
/// `args` is `[raw_f64_bits]` (D5 — the f64 argument as its raw IEEE-754 64-bit pattern, an
/// Erlang integer). Returns `[]` (WASM result type `[]`). Total; node-safe; NaN/±Inf/±0
/// handled by `porffor_abi`. A defensive empty-arg call (impossible post-validation) is a
/// no-op.
fn porffor_print(args: List(Int)) -> List(Int) {
  case args {
    [bits, ..] -> {
      append_output(porffor_abi.number_to_string_bytes(bits))
      []
    }
    [] -> []
  }
}

/// `printChar` (Porffor `""."b"`, `i => print(String.fromCharCode(i))`). Appends the single
/// UTF-16 code unit `truncate(f64) & 0xFFFF`, UTF-8-encoded to match Node's `stdout.write`
/// bytes (§E), to the output buffer. ALL Porffor static console text (string literals, the
/// trailing `\n`, ANSI color escapes) flows through `printChar` — so capturing print +
/// printChar captures the COMPLETE console byte stream (§E.2). `args` is `[raw_f64_bits]`.
/// Returns `[]`. Total; node-safe.
fn porffor_print_char(args: List(Int)) -> List(Int) {
  case args {
    [bits, ..] -> {
      append_output(porffor_abi.char_code_to_utf8(bits))
      []
    }
    [] -> []
  }
}

/// `time` (Porffor `""."c"`, `() => performance.now()`). Returns `[raw_f64_bits]` of a
/// DETERMINISTIC `0.0` ms — a fixed value (not the real BEAM clock) so a conformance run is
/// reproducible (§B.2); a program whose output depends on `time`/`timeOrigin` is a categorized
/// non-judgeable edge, never a false green. `0.0`'s raw pattern is `0`. Total; node-safe.
fn porffor_time(_args: List(Int)) -> List(Int) {
  [0]
}

/// `timeOrigin` (Porffor `""."d"`, `() => performance.timeOrigin`). Returns `[raw_f64_bits]`
/// of a DETERMINISTIC `0.0` (same reproducibility rationale as `time`). Total; node-safe.
fn porffor_time_origin(_args: List(Int)) -> List(Int) {
  [0]
}

/// The build-fixed `FuncType` of a Porffor intrinsic (module `""`, keyed on the ident letter,
/// §A.3), the signature face of the four builtins (analogue of `spectest_func_type/1`). A
/// literal `case` (D3a). `print`/`printChar` are `[f64] -> []`; `time`/`timeOrigin` are
/// `[] -> [f64]`.
///
/// - `letter`: the imported function name under module `""` (`"a"`/`"b"`/`"c"`/`"d"`).
/// - Returns `Ok(ty)` for a known letter, `Error(Nil)` otherwise. A DIAGNOSTIC/categorization
///   aid (not a hard link check — Phase-6 gates host imports at the call-site `HostPolicy`, not
///   at link, so a signature-mismatched Porffor import is a categorizable mismatch, never a
///   silent accept). Total; never raises.
pub fn porffor_func_type(letter: String) -> Result(FuncType, Nil) {
  case letter {
    "a" | "b" -> Ok(FuncType(params: [TF64], results: []))
    "c" | "d" -> Ok(FuncType(params: [], results: [TF64]))
    _ -> Error(Nil)
  }
}

/// The build-fixed `FuncType` of a `spectest` host FUNCTION, for link-time import matching
/// (spec §3.2 function matching / §4.5.4 — a missing or mismatched function import is an
/// `assert_unlinkable`, §C.3). A literal `case` (D3a — no ambient authority; `name` selects
/// among build-controlled results, never constructs a target), the LINKING face of the same
/// seven `spectest` functions the `resolve_handler` arms above DISPATCH; the two literal cases
/// are kept in lock-step (identical name set).
///
/// The reference `spectest` module's signatures (the spec's `imports.wast` host module):
/// `print : [] -> []`, `print_i32 : [i32] -> []`, `print_i64 : [i64] -> []`,
/// `print_f32 : [f32] -> []`, `print_f64 : [f64] -> []`, `print_i32_f32 : [i32 f32] -> []`,
/// `print_f64_f64 : [f64 f64] -> []`.
///
/// - `name`: the imported function name under module `"spectest"`.
/// - Returns `Ok(ty)` for a known `spectest` function (its declared signature), or `Error(Nil)`
///   otherwise (→ the link resolver's `UnknownImport`). Total; never raises.
pub fn spectest_func_type(name: String) -> Result(FuncType, Nil) {
  case name {
    "print" -> Ok(FuncType(params: [], results: []))
    "print_i32" -> Ok(FuncType(params: [TI32], results: []))
    "print_i64" -> Ok(FuncType(params: [TI64], results: []))
    "print_f32" -> Ok(FuncType(params: [TF32], results: []))
    "print_f64" -> Ok(FuncType(params: [TF64], results: []))
    "print_i32_f32" -> Ok(FuncType(params: [TI32, TF32], results: []))
    "print_f64_f64" -> Ok(FuncType(params: [TF64, TF64], results: []))
    _ -> Error(Nil)
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

// ───────────────────────────── Phase-7: the Porffor console output buffer (§E) ─────────────────────────────

/// Read THIS process's accumulated Porffor output buffer, or `<<>>` if never written. The
/// `is_unseeded` guard runs FIRST (the same fail-safe as `current_policy`): `erlang:get/1`
/// yields the atom `undefined` for an absent key, treated as the empty buffer — so a
/// never-printed (or unseeded) instance reads `<<>>`, never a crash. Private.
fn read_output_cell() -> BitArray {
  let raw = erlang_get(CarderRtPorfforOutput)
  case is_unseeded(raw) {
    True -> <<>>
    False -> coerce_bitarray(raw)
  }
}

/// Append `bytes` to THIS instance's Porffor output buffer (the `print`/`printChar` sink, §B).
/// Reads the current buffer (or `<<>>` if unseeded — the buffer self-initialises empty per
/// instance process, so no explicit seed is required), appends, and stores. Private — only the
/// two print handlers call it. Total; process-local; cannot crash the node.
fn append_output(bytes: BitArray) -> Nil {
  let _ =
    erlang_put(
      CarderRtPorfforOutput,
      bit_array.append(read_output_cell(), bytes),
    )
  Nil
}

/// Clear THIS instance's Porffor output buffer to `<<>>`. Provided for an explicit reset (and
/// for tests); NOT required at instantiate because `append_output` self-initialises the buffer
/// empty in each instance's fresh owned process (E1). Total; process-local; cannot crash the
/// node.
pub fn porffor_seed_output() -> Nil {
  let _ = erlang_put(CarderRtPorfforOutput, <<>>)
  Nil
}

/// Read THIS instance's accumulated Porffor console output as a raw `BitArray` — the exact byte
/// stream `print`/`printChar` produced (§E), including ANSI escapes (baked in-band, §E.2). Must
/// run IN the instance's owned process (the buffer is process-local, E1), so the harness routes
/// a call into that process to collect it (§H.2). Returns `<<>>` for a never-printed (or
/// unseeded) instance — fail-safe empty, never a crash. Total.
pub fn porffor_output() -> BitArray {
  read_output_cell()
}
