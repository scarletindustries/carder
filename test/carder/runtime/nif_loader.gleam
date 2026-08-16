//// Shared test-harness helper (S15-04): idempotently ensure the tier-N («nif») native `.so`
//// (`c_src/carder_rt_mem_nif.c`) is built + `load_nif`'d ONCE and REUSED everywhere the native
//// backend must be exercised — the security fuzz (`rt_mem_nif_safety_test`) and, transparently, the
//// whole-corpus tier differential (`tier_differential_test` via `combos.binding_for`).
////
//// ## Why a SINGLE shared helper — the VM-global ordering invariant
////
//// `load_nif` is VM-GLOBAL: it attaches C to the `carder_rt_mem_nif_ffi` shim atom, so ANY test that
//// (re)loads it changes the backend for EVERY other test in the run, whatever order they run in. And
//// `rt_mem_nif` dispatches native-vs-paged PER OP on `nif_available()` — so once the `.so` is attached,
//// EVERY `cell_nif` driver (conformance and the corpus differential alike) drives native memory
//// automatically, no per-caller wiring needed. If each caller rolled its own load logic, ordering would
//// decide who wins and could poison the `cell_nif` matrix (the S15-02/03 caveat). This helper funnels
//// the native-needing callers through ONE reuse-first path (`ensure_loaded`): if the full `.so` is
//// already attached (`available()`), REUSE it — never a redundant reload (`erlang:load_nif` REFUSES to
//// re-attach while resources from a prior load are still live, the S15-02 caveat); otherwise sweep every
//// process's unreferenced resources (`gc_all`) and build+load once, retrying across a short yield.
////
//// ## The keystone-probe constraint — why `binding_for` must NOT force a load (`reuse_if_available`)
////
//// gleeunit runs test modules in `filelib:wildcard` (sorted-by-path) order, so `carder/harness/*`
//// runs BEFORE `carder/runtime/rt_mem_nif_build_test` (the S15-01 keystone probe) — which force-reloads
//// the shim with a `nif_ping`-only probe `.so` whose `load` callback opens the resource type with
//// `ERL_NIF_RT_CREATE` **only** (not `TAKEOVER`). `enif_open_resource_type(CREATE)` FAILS while ANY
//// resource of that type is live — and the conformance harness (`carder_harness_ffi:start_common`)
//// spawns each instance in an UNLINKED orphan process (`spawn`, one-instance-one-process, E5) that holds
//// its memory forever. So if the conformance `cell_nif` matrix FORCE-LOADED the native `.so`, its leaked
//// resources would permanently block the keystone probe's reload (`load_nif_failed`). Neither the probe
//// source (S15-01) nor the leaking `spawn` (trap-isolation, must stay unlinked) is this unit's to change.
////
//// The resolution: `combos.binding_for` calls `reuse_if_available()` — it drives native WHEN the `.so` is
//// already attached, but NEVER forces a fresh compile+load. The dedicated native tests
//// (`rt_mem_nif_safety_test`, `rt_mem_nif_test`), which sort AFTER the keystone probe, attach the `.so`
//// via `ensure_loaded()` and leave it attached, so the corpus tier differential (which sorts after them)
//// drives NATIVE memory. The pre-probe conformance `cell_nif` point runs on the paged delegate
//// (byte-identical, `fail=0`) — protecting the keystone probe. This is the S15-04 honest categorization:
//// the load-bearing "bit-identical native tier" proof is the native corpus differential + the native
//// fuzz; conformance's `cell_nif` stays the delegate so nothing regresses (fail=0 either way).
////
//// ## The `cc` gate (S6) — never a false green
////
//// Absent a C toolchain the build FFI returns `SkipNoToolchain`: `reuse_if_available()` reports the `.so`
//// unattached, `cell_nif` uses the paged delegate (still byte-identical — MF3), and the fuzz categorizes
//// a skip. A broken pipe (`BuildError`) is surfaced to the caller (the fuzz panics loudly). This is the
//// same `loaded | skip_no_toolchain | {build_error, _}` marshalling `rt_mem_nif_test` uses.

import gleam/dynamic.{type Dynamic}
import gleam/list

/// The `compile_load_cnif/0` result, marshalled directly from the frozen build FFI:
/// `loaded → Loaded`, `skip_no_toolchain → SkipNoToolchain`, `{build_error, Bin} → BuildError(String)`.
pub type LoadState {
  Loaded
  SkipNoToolchain
  BuildError(String)
}

/// Compile the committed `c_src/carder_rt_mem_nif.c` + `load_nif` it into the shim (the S15-01 build
/// gate). `Loaded` (cc present, attached), `SkipNoToolchain` (no cc — categorized), or `BuildError`.
@external(erlang, "carder_rt_mem_nif_build_ffi", "compile_load_cnif")
fn compile_load_cnif() -> LoadState

/// The shim's `nif_available/0`: `True` ONLY when the real `.so` is attached (the `.erl` stub answers
/// `False`, the `nif_ping`-only probe leaves it a stub). THE reuse probe + the native/paged dispatch.
@external(erlang, "carder_rt_mem_nif_ffi", "nif_available")
fn nif_available() -> Bool

/// `erlang:processes/0` — every live process (so each can be GC'd to release unreferenced resources).
@external(erlang, "erlang", "processes")
fn all_pids() -> List(Dynamic)

/// `erlang:garbage_collect/1` — GC the given process, freeing any nif resource it no longer references.
@external(erlang, "erlang", "garbage_collect")
fn gc_pid(pid: Dynamic) -> Bool

/// `timer:sleep/1` — yield so a just-exited test process's pending resource free completes before a
/// reload retry.
@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Dynamic

/// `carder/runtime/rt_state:clear/0` — drop this process's seeded cell (its memory handle) so a native
/// reload is not blocked by a resource this caller left live.
@external(erlang, "carder@runtime@rt_state", "clear")
fn clear_state() -> Nil

/// GC EVERY live process, freeing any nif resource that has become unreferenced. `erlang:load_nif`
/// refuses to attach (on the build FFI's purge+delete+reload path) while ANY resource from a prior load
/// is still live — and a gleeunit run spreads them across per-test processes — so a global sweep is what
/// lets the reload attach.
fn gc_all() -> Nil {
  list.each(all_pids(), fn(p) {
    let _ = gc_pid(p)
    Nil
  })
}

/// `True` iff the native `.so` is CURRENTLY attached to the shim (a cheap cached-atom read). The
/// native/paged dispatch switch — probed so a caller can confirm the native arm is genuinely live
/// (never a false green).
pub fn available() -> Bool {
  nif_available()
}

/// Reuse the native `.so` if it is ALREADY attached (so a `cell_nif` driver drives native memory), and
/// return whether it is. Crucially, this NEVER forces a fresh compile+load — see the module doc's
/// "keystone-probe constraint": `combos.binding_for` runs during the PRE-keystone-probe conformance
/// matrix, whose leaked instance-process resources would block the probe's `CREATE`-only reload if the
/// `.so` were attached there. The dedicated post-probe native tests attach it; `rt_mem_nif` then routes
/// native per-op via `nif_available()`. `False` ⇒ the paged delegate (byte-identical, still green).
pub fn reuse_if_available() -> Bool {
  nif_available()
}

/// Idempotently ensure the full native `.so` is attached, returning its `LoadState`:
/// - already attached (`available()`) → `Loaded`, REUSED with NO reload (the S15-02 live-resource
///   caveat: never force a reload while resources may be live);
/// - not attached → sweep unreferenced resources + build+load once (retrying across a short yield);
/// - no `cc` → `SkipNoToolchain` (the caller falls back to the paged delegate);
/// - a broken pipe → `BuildError(text)` (the caller decides: the fuzz panics, `binding_for` degrades).
///
/// This is THE single entry point `combos.binding_for` (for a `Nif` combo) and the fuzz both call, so
/// the shim's state is reused/restored consistently regardless of test order.
pub fn ensure_loaded() -> LoadState {
  case nif_available() {
    True -> Loaded
    False -> load_clean(4)
  }
}

/// Clear this process's cell + sweep every process's unreferenced resources, THEN build+load. On a
/// transient `BuildError` (e.g. a not-yet-freed resource from a just-finished test still blocking the
/// reload) retry across a short yield, up to `attempts` times, before surfacing it.
fn load_clean(attempts: Int) -> LoadState {
  clear_state()
  gc_all()
  case compile_load_cnif() {
    BuildError(text) ->
      case attempts > 1 {
        True -> {
          let _ = sleep(25)
          load_clean(attempts - 1)
        }
        False -> BuildError(text)
      }
    result -> result
  }
}
