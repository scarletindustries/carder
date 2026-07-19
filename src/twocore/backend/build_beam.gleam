//// The `build_beam` driver (Unit 04) — the backend's last seam.
////
//// Wraps the hand-written Erlang shim `twocore_codegen_ffi` (the «FFI-SHIM»)
//// behind one stable Gleam `Result` contract. It takes the backend's
//// Core-shaped AST (`CModule`), lowers it to Erlang Abstract Format forms
//// (`twocore/backend/eaf`), compiles them **in-process** with
//// `compile:forms/2` to an in-memory `.beam` binary, and loads that binary
//// into the CURRENT VM (decision D10), so generated modules can be `apply`-ed
//// and proven to be real, preemptible BEAM code (high-level §9.2).
////
//// There is deliberately NO text in this path any more: the old backend
//// printed `.core` text and re-parsed it with the compiler-internal
//// `core_scan`/`core_parse` modules plus the undocumented textual `from_core`
//// entry. Abstract forms are the documented `erts/absform` contract, so the
//// build is no longer pinned to compiler internals (only `compile:forms/2`
//// itself, a stable public API). `core_printer` remains solely as the human
//// inspection surface (`to-core` dumps); it is never re-parsed.

import gleam/erlang/atom.{type Atom}
import gleam/result
import twocore/backend/beam_link
import twocore/backend/core_erlang.{type CModule}
import twocore/backend/eaf
import twocore/backend/link_manifest

/// This stage's own error type (D4 — there is no shared `StageError`; each
/// stage owns its errors and the top-level driver composes them).
pub type BuildError {
  /// The AST → abstract-forms lowering or `compile:forms/2` reported one or
  /// more diagnostics.
  ///
  /// Each string is a normalized `"<loc>: <message>"` line where `<loc>` is a
  /// line number or the literal `"module"` (for module-level errors with no
  /// line); an `eaf` lowering error is rendered via `eaf.describe`. Messages
  /// are never a raw Erlang term. The list is always non-empty when this
  /// variant is produced.
  CompileFailed(errors: List(String))
  /// `code:load_binary/3` rejected the binary (e.g. `"sticky_directory"`,
  /// `"badfile"`, `"not_purged"`). `reason` is the VM's error atom rendered as
  /// text.
  LoadFailed(reason: String)
}

/// FFI into the «FFI-SHIM». Erlang module name is RAW (not Gleam-mangled).
/// Returns the shim's `{ok,{Mod,Beam}} | {error,[Bin]}` mapped onto a Gleam
/// `Result(#(Atom, BitArray), List(String))`. Gleam does NOT type-check this
/// boundary — shapes are validated in the tests (trust boundary).
@external(erlang, "twocore_codegen_ffi", "compile_forms")
fn ffi_compile_forms(
  forms: List(eaf.Form),
) -> Result(#(Atom, BitArray), List(String))

/// FFI into the «FFI-SHIM». Wraps `code:load_binary/3`. Returns the shim's
/// `{ok,Mod} | {error,Bin}` mapped onto `Result(Atom, String)`.
@external(erlang, "twocore_codegen_ffi", "load_module")
fn ffi_load_module(
  module: Atom,
  filename: String,
  beam: BitArray,
) -> Result(Atom, String)

/// FFI into the «FFI-SHIM»: pretty-print abstract forms as Erlang source text
/// (`erl_pp`) — the `to-erl` inspection dump.
@external(erlang, "twocore_codegen_ffi", "forms_to_erl")
fn ffi_forms_to_erl(forms: List(eaf.Form)) -> String

/// Compile already-lowered abstract FORMS to an in-memory `.beam` binary —
/// the forms-level seam (`compile_module` is this plus the AST lowering).
///
/// - `forms`: the abstract-format form list (from `eaf.module_forms`).
///
/// Returns `Ok(#(module_name, beam_binary))` on success; the `module_name`
/// atom is taken from the `-module` attribute. Returns
/// `Error(CompileFailed(lines))` on any compiler diagnostic. Never panics on a
/// malformed form list — the shim catches a compiler crash and renders it as a
/// diagnostic (fail-closed, D8).
pub fn compile_forms(
  forms: List(eaf.Form),
) -> Result(#(Atom, BitArray), BuildError) {
  ffi_compile_forms(forms)
  |> result.map_error(CompileFailed)
}

/// Compile a backend `CModule` to an in-memory `.beam` binary: lower it to
/// abstract forms (`eaf.module_forms`) and run them through `compile:forms/2`
/// in-process.
///
/// - `cmod`: the Core-shaped module `emit_core` produced.
///
/// Returns `Ok(#(module_name, beam_binary))` on success (the atom comes from
/// `cmod.name`). Returns `Error(CompileFailed(lines))` if the lowering or the
/// compiler rejects the module, where `lines` is a non-empty list of
/// human-readable strings.
///
/// Failure modes: never panics on a malformed module — a broken AST yields
/// `Error(CompileFailed(_))` (fail-closed, D8), whether the `eaf` lowering or
/// `erl_lint` inside `compile:forms` catches it.
pub fn compile_module(cmod: CModule) -> Result(#(Atom, BitArray), BuildError) {
  case eaf.module_forms(cmod) {
    Error(e) -> Error(CompileFailed([eaf.describe(e)]))
    Ok(forms) -> compile_forms(forms)
  }
}

/// Pretty-print a backend `CModule` as Erlang SOURCE text — the `.erl`-flavour
/// inspection dump (`to-erl`): the module is lowered to the SAME abstract
/// forms `compile_module` compiles and rendered with `erl_pp`, so the dump is
/// exactly what the compiler consumes (unlike the `.core` pretty-print, which
/// is a display-only rendering of the pre-lowering AST).
///
/// Returns `Ok(text)` or `Error(CompileFailed([line]))` if the AST cannot be
/// lowered. Total — never panics.
pub fn module_to_erl(cmod: CModule) -> Result(String, BuildError) {
  case eaf.module_forms(cmod) {
    Error(e) -> Error(CompileFailed([eaf.describe(e)]))
    Ok(forms) -> Ok(ffi_forms_to_erl(forms))
  }
}

/// Load a `.beam` binary into the CURRENT VM (D10) and return its module name.
///
/// - `module`: the module atom; MUST match the name baked into `beam`.
/// - `filename`: metadata only (surfaced by `code:which`); it does not affect
///   the loaded module's identity.
/// - `beam`: the compiled `.beam` binary (as returned by `compile_module`).
///
/// Returns `Ok(module)` once the module is resident, or `Error(reason)` where
/// `reason` is the VM's rejection atom rendered as text. This is a deliberately
/// thin pass-through exposing the raw VM reason; the composed stage surface is
/// `compile_and_load`, which folds the reason into `BuildError` (D4).
///
/// Side effect: a name collision HOT-REPLACES an already-loaded module — keep
/// generated modules namespaced `twocore@…` to avoid clobbering OTP or each
/// other.
pub fn load_module(
  module: Atom,
  filename: String,
  beam: BitArray,
) -> Result(Atom, String) {
  ffi_load_module(module, filename, beam)
}

/// Merge a generated module with its whole runtime dependency closure into ONE
/// self-contained `.beam` — the `--link` path (the linked analog of `compile_module`).
///
/// This is the single composition point that binds "which OTP modules stay remote" (the frozen
/// manifest's `ambient_allowlist/0`, R7) to a whole-program link — the CLI never re-spells the
/// allowlist. It is a one-way dependency onto `beam_link` (P11-03) + `link_manifest` (P11-02);
/// neither imports `build_beam`, so there is no cycle.
///
/// - `cmod`: the emitted Core-shaped module, exactly as `pipeline.ir_to_cmod` produced it —
///   its `name` names the merged module. It is lowered to abstract forms here and handed to the
///   linker, which recovers the cerl module via the compiler's own `to_core` pass in-process.
/// - Returns `Ok(#(merged_module_atom, merged_beam))` — one self-contained binary that loads on a
///   bare OTP node, whose declared module atom equals `merged_module_atom` — or the linker's typed
///   `beam_link.LinkError` (off-allowlist remote, unmergeable construct, Core-acquisition failure,
///   D3a authority, …). Fail-closed: never emits a partial or authority-bearing artifact, and
///   never panics on malformed input (it becomes a typed `Error`).
pub fn link_beam(
  cmod: CModule,
) -> Result(#(Atom, BitArray), beam_link.LinkError) {
  case eaf.module_forms(cmod) {
    Error(e) -> Error(beam_link.MalformedCore(eaf.describe(e)))
    Ok(forms) ->
      beam_link.link_program(
        forms,
        cmod.name,
        link_manifest.ambient_allowlist(),
      )
  }
}

/// Convenience: compile `cmod` then load the resulting binary, folding a
/// load failure into `BuildError` so the whole stage speaks one error type (D4).
///
/// - `cmod`: the Core-shaped module (see `compile_module`).
///
/// Returns `Ok(module)` — a resident module ready to `apply` — or the first
/// failing stage's error: `Error(CompileFailed(_))` if compilation fails, or
/// `Error(LoadFailed(_))` if loading fails. Does not panic on bad input.
///
/// The load `filename` is fixed to `"twocore_generated"` (metadata only); use
/// `load_module` directly if a specific `code:which` filename is needed.
pub fn compile_and_load(cmod: CModule) -> Result(Atom, BuildError) {
  use #(mod, beam) <- result.try(compile_module(cmod))
  load_module(mod, "twocore_generated", beam)
  |> result.map_error(LoadFailed)
}
