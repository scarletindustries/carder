//// Phase 11 · P11-02 — the link-closure manifest (`«CLOSURE-FROZEN»`).
////
//// INERT REFERENCE DATA the whole-program Core-Erlang linker (P11-03) builds against. This module
//// is a **stdlib-only leaf** (imports only `gleam/list`/`gleam/set`/`gleam/string`, no project
//// modules) so it can never re-invert the runtime/compiler layer split frozen by P11-01.
////
//// The linker DISCOVERS the actual closure by reachability from the generated module's exports
//// (R6) — this manifest does NOT compute the graph. It supplies the three things reachability
//// cannot decide for itself, plus a frozen snapshot the drift test keeps honest:
////
//// 1. the **OTP-ambient stop-set** (`ambient_allowlist/0`, R7) — the fixed ERTS+kernel+stdlib
////    modules DCE walks *up to but not into*; a surviving remote outside it is a fail-closed
////    `LinkError`, never a runtime `undef`;
//// 2. the **Core-acquisition rule** (`Acquisition`, R1) — how a closure member's `#c_module{}` is
////    obtained (resident-`.beam` `debug_info` primary, `to_core` fallback, generated-module text);
//// 3. the **invariants as checkable data** — mangle injectivity (R12), the mergeability
////    constraints (R15), and the frozen closure / surviving-remote snapshots (R8) the sibling
////    `link_manifest_drift_test` recomputes from the current build and diffs against.
////
//// Everything here is a snapshot of THIS build, measured mechanically (module-level `beam_lib`
//// `imports` walk from the runtime roots, which is R4-complete — the `imports` chunk records
//// `fun M:F/A` captures as well as direct calls). The drift test recomputes it; if a future runtime
//// change adds an `import`, an `@external`, or a remote target, the drift test fails HERE rather than
//// in the phase-closing capstone.

import gleam/list
import gleam/set
import gleam/string

/// The FIXED OTP-ambient module set (as atom strings) — the DCE stop-set (R7).
///
/// A remote `#c_call` whose target module is in this set is LEFT as a remote call; the linker DCEs
/// the reachability walk here rather than pulling the OTP module into the merge. These 15 modules are
/// ERTS+kernel+stdlib present on every standard OTP install by definition, so they never need
/// inlining. Any surviving remote target that is neither in-closure nor in this set is a fail-closed
/// `LinkError` (a missing-closure surfaces at LINK time, never as a runtime `undef`).
///
/// This is the **measured floor** for the frozen tier-P/O closure (`frozen_surviving_remotes/0`
/// equals it exactly). It is deliberately minimal: `is_ambient("erlang")` being True does NOT
/// sanction `erlang:apply` — that is rejected structurally by the linker regardless (R9). Widening
/// this set reactively to make a program link is itself a D3a hole — do NOT.
///
/// Returns the 15 atom strings, in the R7-documented order, with no duplicates.
pub fn ambient_allowlist() -> List(String) {
  [
    "erlang", "lists", "maps", "binary", "math", "ets", "atomics", "unicode",
    "string", "io", "io_lib", "io_lib_format", "base64", "rand", "uri_string",
  ]
}

/// True iff `module_atom` is a member of `ambient_allowlist/0`.
///
/// - `module_atom`: an Erlang module name as a string (e.g. `"erlang"`, `"code"`).
/// - Returns True only for the 15 fixed OTP-ambient modules. `is_ambient("erlang")` is True but does
///   NOT sanction `erlang:apply` (structurally refused by the linker, R9). An off-set OTP module such
///   as `is_ambient("code")` / `is_ambient("filelib")` is False (fail-closed), and an in-closure
///   module such as `is_ambient("twocore@runtime@rt_num")` is False (in-closure ≠ ambient).
pub fn is_ambient(module_atom: String) -> Bool {
  list.contains(ambient_allowlist(), module_atom)
}

/// Standard OTP modules reachable in the frozen closure ONLY at module granularity — a spec-drift
/// correction (R7/R8).
///
/// The merged FFI module `gleam_erlang_ffi` (pulled in because `rt_host` calls
/// `gleam@erlang@atom:decoder/0`, which uses `gleam_erlang_ffi:atom_from_string/identity`) also
/// contains unrelated process/node helpers — `connect_node/1` (`net_kernel:connect_node`),
/// `priv_directory/1` (`code:priv_dir`), `sleep/1`+`sleep_forever/0` (`timer:sleep`). A module-level
/// `imports` walk cannot see that those helpers are unreachable from the atom path, so it reports
/// `code`/`net_kernel`/`timer` as surviving remotes. The linker's FUNCTION-level DCE eliminates them
/// (they are never reached from the runtime roots), so they do NOT appear in linked output — hence
/// they are deliberately absent from `ambient_allowlist/0` (no D3a-weakening widening for `code`).
///
/// Returns the 3 atom strings `code`, `net_kernel`, `timer`. The drift test uses this to reconcile
/// the module-granularity ceiling (`frozen_surviving_remotes/0` ∪ this) with the post-DCE floor.
pub fn dce_only_remotes() -> List(String) {
  ["code", "net_kernel", "timer"]
}

/// How a closure member's Core (`#c_module{}`) is acquired for the merge — frozen order (R1).
///
/// The linker (P11-03) implements the acquisition in `twocore_linker_ffi.erl`; this manifest only
/// NAMES the rule so the choice is single-sourced. Verified acquirable on OTP 29.0.2 for every member
/// via the primary path.
pub type Acquisition {
  /// The GENERATED (wasm-derived) module ONLY: its `.core` source TEXT parsed via the existing
  /// `core_scan`/`core_parse` path (the `twocore_codegen_ffi` route).
  GeneratedCoreText
  /// The UNIFORM primary for every DISCOVERED in-closure module: `beam_lib:chunks(Beam,[debug_info])`
  /// then `Backend:debug_info(core_v1, Mod, Data, [])` straight from the module's RESIDENT `.beam` —
  /// needs no `.erl` on disk (verified on `rt_num`, `gleam@int`, `gleam_stdlib`, `twocore_rt_exn_ffi`).
  ResidentBeamCore
  /// The single FALLBACK, used only when a resident `.beam` carries no `core_v1` debug_info chunk:
  /// `compile:file(F,[to_core])` on the `.erl` source.
  CompileFileToCore
}

/// The primary acquisition method for a closure member (R1).
///
/// - `is_generated`: True for the wasm-derived generated module, False for every discovered
///   in-closure runtime/gleam/FFI module.
/// - Returns `GeneratedCoreText` when `is_generated`, otherwise `ResidentBeamCore` (the uniform
///   resident-`.beam` `debug_info` path that covers the `.erl` FFI bucket too).
pub fn primary_acquisition(is_generated: Bool) -> Acquisition {
  case is_generated {
    True -> GeneratedCoreText
    False -> ResidentBeamCore
  }
}

/// The single fallback acquisition method (R1).
///
/// Returns `CompileFileToCore` — the linker uses it iff `ResidentBeamCore` yields no `core_v1`
/// debug_info chunk for a member. On this build every member carries `core_v1`, so it is a genuine
/// safety fallback, not a routine path.
pub fn fallback_acquisition() -> Acquisition {
  CompileFileToCore
}

/// The mangling separator that makes the linker's `'M__F'/A` local-name scheme injective.
///
/// `'M__F'/A` (full module atom + this separator + the function name) is collision-free ONLY because
/// no in-closure module atom itself contains this separator. The rewrite/mangle is owned by the
/// linker (P11-03); this manifest owns the PRECONDITION (`mangle_injective/1`) that makes it sound.
pub const mangle_separator: String = "__"

/// True iff mangling `M__F` over `closure_modules` is injective — i.e. NO member atom contains
/// `mangle_separator` (R12).
///
/// - `closure_modules`: the in-closure module atoms as strings (the union the linker will merge).
/// - Returns True iff every member is `mangle_separator`-free. The linker asserts this at freeze and
///   FAILS CLOSED (`LinkError.MangleCollision`) if a future module violates it — e.g.
///   `mangle_injective(["a__b"])` and `mangle_injective(["gleam@x", "y__z"])` are both False. Every
///   atom in the frozen closure uses `@`/single `_` only, so the frozen closure is injective.
pub fn mangle_injective(closure_modules: List(String)) -> Bool {
  list.all(closure_modules, fn(m) { !string.contains(m, mangle_separator) })
}

/// The runtime modules a WASM tier-P/O generated module can call — the drift test's reachability seed
/// (NOT the linker's roots; the linker seeds from the generated module's exports, R6).
///
/// These are the 8 non-tier `Binding` module atoms (`rt_num`/`rt_trap`/`rt_host`/`rt_meter`/
/// `rt_stdlib`/`rt_state`, minus the JS-only `rt_js`), the tier-P/O memory/table impls
/// (`rt_mem`/`rt_mem_atomics`; `rt_table`/`rt_table_ets`/`rt_table_atomics` — `rt_mem_nif` is tier-N,
/// excluded), and the 4 fixed atoms `emit_core` reaches without a `Binding` field
/// (`rt_ref`/`link`/`rt_simd`/`rt_exn`). `porffor_abi` is reached transitively (via `rt_host`) and so
/// is a member of `frozen_runtime_closure/0` but NOT a root.
///
/// Returns the 16 fully-mangled `twocore@runtime@*` module atom strings, sorted. `rt_teavm` (the
/// TeaVM WASM GC host runtime, experimental) is reachable because `link.resolve_func_provided`
/// routes TeaVM host imports to it.
pub fn frozen_runtime_roots() -> List(String) {
  sorted([
    "twocore@runtime@link", "twocore@runtime@rt_exn", "twocore@runtime@rt_host",
    "twocore@runtime@rt_mem", "twocore@runtime@rt_mem_atomics",
    "twocore@runtime@rt_meter", "twocore@runtime@rt_num",
    "twocore@runtime@rt_ref", "twocore@runtime@rt_simd",
    "twocore@runtime@rt_state", "twocore@runtime@rt_stdlib",
    "twocore@runtime@rt_table", "twocore@runtime@rt_table_atomics",
    "twocore@runtime@rt_table_ets", "twocore@runtime@rt_teavm",
    "twocore@runtime@rt_trap",
  ])
}

/// The tier-P/O `twocore@runtime@*` modules in the closure — a frozen snapshot the drift test diffs
/// against (R8/R15).
///
/// This is `frozen_runtime_roots/0` plus `twocore@runtime@porffor_abi` (reached via `rt_host`). The
/// JS runtime (`rt_js`) and its FFI are EXCLUDED — they are only reachable via `CallHost("js", …)`,
/// which the WASM `--link` path never emits (and import-bearing modules are rejected, R14). `rt_bif`
/// is EXCLUDED — it is a build-time gate consulted by `ir_lower`, not a runtime call target.
/// `rt_mem_nif` is EXCLUDED — tier-N. `instance`/`profiles` are EXCLUDED — build-time only.
///
/// Returns 16 fully-mangled module atom strings, sorted.
pub fn frozen_runtime_closure() -> List(String) {
  sorted(["twocore@runtime@porffor_abi", ..frozen_runtime_roots()])
}

/// The reachable `gleam@*` package modules in the closure — a frozen snapshot (R8/R15).
///
/// Discovered by the module-level `imports` walk from `frozen_runtime_roots/0`. Returns 12
/// mangled `gleam@*` module atom strings, sorted.
pub fn frozen_gleam_closure() -> List(String) {
  sorted([
    "gleam@bit_array", "gleam@dict", "gleam@dynamic", "gleam@dynamic@decode",
    "gleam@erlang@atom", "gleam@float", "gleam@int", "gleam@list",
    "gleam@result", "gleam@set", "gleam@string", "gleam@string_tree",
  ])
}

/// The hand-written FFI `.erl` modules in the closure — DERIVED from the actual `@external` targets
/// in reachable Gleam modules, not hand-typed (R8).
///
/// The runtime's non-OTP `@external` targets are `gleam_stdlib` (~31× — e.g.
/// `gleam_stdlib:identity` for D5 bit-identity coercions) and the 5 `twocore_rt_*_ffi` shims;
/// `gleam_erlang_ffi` is reached transitively (`rt_host` → `gleam@erlang@atom:decoder/0` →
/// `gleam_erlang_ffi:atom_from_string/identity`). The overview's `.erl` sketch omitted
/// `gleam_erlang_ffi` — this snapshot corrects it (7 members, not 6). `twocore_rt_js_ffi` is EXCLUDED
/// (JS-only, off the WASM link path); `twocore_cli_ffi`/`twocore_codegen_ffi` are driver/compiler
/// FFI (from `pipeline`/`build_beam`, not runtime) — correctly outside the bucket.
///
/// Returns 7 bare module atom strings, sorted.
pub fn frozen_ffi_erl() -> List(String) {
  sorted([
    "gleam_erlang_ffi", "gleam_stdlib", "twocore_rt_exn_ffi",
    "twocore_rt_mem_atomics_ffi", "twocore_rt_ref_ffi", "twocore_rt_state_ffi",
    "twocore_rt_table_ets_ffi",
  ])
}

/// Every in-closure module atom (runtime ∪ gleam ∪ FFI) — the union the linker merges, and the
/// domain over which `mangle_injective/1` must hold.
///
/// Returns 35 module atom strings (16 runtime + 12 gleam + 7 FFI), sorted, no duplicates.
pub fn frozen_closure_modules() -> List(String) {
  sorted(
    list.flatten([
      frozen_runtime_closure(),
      frozen_gleam_closure(),
      frozen_ffi_erl(),
    ]),
  )
}

/// The surviving remote-call target set AFTER the linker's function-level DCE — a frozen snapshot
/// that MUST be ⊆ `ambient_allowlist/0` (R7).
///
/// This is the module-granularity ceiling MINUS `dce_only_remotes/0`: the modules that genuinely
/// remain as remote `#c_call`s in the linked artifact. It equals `ambient_allowlist/0` exactly on
/// this build (every allowlist member is actually used; none DCE fully away for the tier-P/O
/// closure). The drift test recomputes the module-level ceiling and asserts
/// `ceiling − dce_only_remotes() == frozen_surviving_remotes()`.
///
/// Returns 15 OTP module atom strings, sorted.
pub fn frozen_surviving_remotes() -> List(String) {
  sorted([
    "atomics", "base64", "binary", "erlang", "ets", "io", "io_lib",
    "io_lib_format", "lists", "maps", "math", "rand", "string", "unicode",
    "uri_string",
  ])
}

/// A construct that MUST be absent from every closure member for the whole-program merge to be sound
/// (R15). Verified absent across the frozen tier-P/O closure; the drift test asserts they stay absent.
pub type Unmergeable {
  /// A `-nif`/`erlang:load_nif` loader — a NIF cannot be merged into a `.beam` (tier-N, excluded).
  Nif
  /// An `-on_load` module directive — runs code at load time; none exist in tier P/O.
  OnLoad
  /// A named or `public` ETS table created at load/app-start — the runtime's ETS is call-time,
  /// `private`, and unnamed, so nothing collides across a merge.
  NamedOrPublicEts
  /// An OTP `application` behaviour / app-start callback — the closure has none.
  OtpApplication
  /// An OTP `supervisor` behaviour — the closure has none.
  OtpSupervisor
  /// `persistent_term` usage — global mutable term storage; the closure uses none.
  PersistentTerm
  /// A `gleam@@main`/`gleam@@compile` shim module — a program entry point that must never be merged.
  GleamMainShim
}

/// The frozen forbidden-construct set (R15) — the drift/structural test asserts none of these appears
/// in any closure member.
///
/// Returns all 7 `Unmergeable` variants (the complete list).
pub fn mergeability_invariants() -> List(Unmergeable) {
  [
    Nif,
    OnLoad,
    NamedOrPublicEts,
    OtpApplication,
    OtpSupervisor,
    PersistentTerm,
    GleamMainShim,
  ]
}

/// Sort a list of atom strings ascending with duplicates removed (internal helper for the frozen
/// snapshots so every accessor returns a canonical, order-stable value).
fn sorted(xs: List(String)) -> List(String) {
  xs
  |> set.from_list
  |> set.to_list
  |> list.sort(string.compare)
}
