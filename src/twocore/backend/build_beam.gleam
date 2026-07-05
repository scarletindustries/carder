//// The `build_beam` driver (Unit 04) — the backend's last seam.
////
//// Wraps the hand-written Erlang shim `twocore_codegen_ffi` (the «FFI-SHIM»)
//// behind one stable Gleam `Result` contract. It takes Core Erlang source
//// *text*, compiles it to an in-memory `.beam` binary, and loads that binary
//// into the CURRENT VM (decision D10), so generated modules can be `apply`-ed
//// and proven to be real, preemptible BEAM code (high-level §9.2).
////
//// The in-memory path is the default. A file fallback (`compile:file`) is
//// possible behind the *same* `Result` contract should a future OTP quirk
//// demand it, but is intentionally not the default — see the unit doc.
////
//// PINNED TO OTP 29: the underlying shim uses the compiler-internal
//// `core_scan`/`core_parse` modules and the undocumented textual `from_core`
//// format. See `src/twocore_codegen_ffi.erl`.

import gleam/erlang/atom.{type Atom}
import gleam/result
import twocore/backend/beam_link
import twocore/backend/link_manifest

/// This stage's own error type (D4 — there is no shared `StageError`; each
/// stage owns its errors and the top-level driver composes them).
pub type BuildError {
  /// Core Erlang scan, parse, or compile reported one or more diagnostics.
  ///
  /// Each string is a normalized `"<loc>: <message>"` line where `<loc>` is a
  /// line number or the literal `"module"` (for module-level errors with no
  /// line). Messages are rendered via the failing module's `format_error/1` —
  /// never a raw Erlang term. The list is always non-empty when this variant
  /// is produced.
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
@external(erlang, "twocore_codegen_ffi", "compile_core")
fn ffi_compile_core(core: BitArray) -> Result(#(Atom, BitArray), List(String))

/// FFI into the «FFI-SHIM». Wraps `code:load_binary/3`. Returns the shim's
/// `{ok,Mod} | {error,Bin}` mapped onto `Result(Atom, String)`.
@external(erlang, "twocore_codegen_ffi", "load_module")
fn ffi_load_module(
  module: Atom,
  filename: String,
  beam: BitArray,
) -> Result(Atom, String)

/// Compile Core Erlang source TEXT to an in-memory `.beam` binary.
///
/// - `core_text`: UTF-8 `.core` source as a byte-aligned `BitArray` (it is read
///   on the Erlang side as a binary; do not pass a non-byte-aligned bitstring).
///
/// Returns `Ok(#(module_name, beam_binary))` on success. The `module_name` atom
/// is taken from the `.core` `module` header, NOT from any filename. Returns
/// `Error(CompileFailed(lines))` if `core_scan`/`core_parse`/`compile` reports
/// any diagnostic, where `lines` is a non-empty list of human-readable
/// `"<loc>: <message>"` strings.
///
/// Failure modes: never panics on malformed (syntactically or semantically
/// broken) input — broken input yields `Error(CompileFailed(_))`. This
/// fail-closed behavior is a tested property (D8). The only inputs that could
/// still crash the shim guard are non-byte-aligned bitstrings, which the
/// `BitArray` contract for text excludes.
pub fn compile_core(
  core_text: BitArray,
) -> Result(#(Atom, BitArray), BuildError) {
  ffi_compile_core(core_text)
  |> result.map_error(CompileFailed)
}

/// Load a `.beam` binary into the CURRENT VM (D10) and return its module name.
///
/// - `module`: the module atom; MUST match the name baked into `beam`.
/// - `filename`: metadata only (surfaced by `code:which`); it does not affect
///   the loaded module's identity.
/// - `beam`: the compiled `.beam` binary (as returned by `compile_core`).
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

/// Merge a generated module's Core Erlang with its whole runtime dependency closure into ONE
/// self-contained `.beam` — the `--link` path (the linked analog of `compile_core/1`).
///
/// This is the single composition point that binds "which OTP modules stay remote" (the frozen
/// manifest's `ambient_allowlist/0`, R7) to a whole-program link — the CLI never re-spells the
/// allowlist. It is a one-way dependency onto `beam_link` (P11-03) + `link_manifest` (P11-02);
/// neither imports `build_beam`, so there is no cycle.
///
/// - `generated_core`: the emitted `.core` TEXT for the generated module (UTF-8, byte-aligned),
///   exactly as `pipeline.ir_to_core` produced it — its `module` header names the merged module.
/// - `module_name`: the generated module's name (`ir.Module.name`); passed through so the linker
///   can locate the generated module within the acquired closure and name the merged output. It
///   MUST equal the `.core` `module` header (a mismatch is `Error(MalformedCore(_))`).
/// - Returns `Ok(#(merged_module_atom, merged_beam))` — one self-contained binary that loads on a
///   bare OTP node, whose declared module atom equals `merged_module_atom` — or the linker's typed
///   `beam_link.LinkError` (off-allowlist remote, unmergeable construct, Core-acquisition failure,
///   D3a authority, …). Fail-closed: never emits a partial or authority-bearing artifact, and
///   never panics on malformed input (it becomes a typed `Error`).
pub fn link_beam(
  generated_core: BitArray,
  module_name: String,
) -> Result(#(Atom, BitArray), beam_link.LinkError) {
  beam_link.link_program(
    generated_core,
    module_name,
    link_manifest.ambient_allowlist(),
  )
}

/// Convenience: compile `core_text` then load the resulting binary, folding a
/// load failure into `BuildError` so the whole stage speaks one error type (D4).
///
/// - `core_text`: UTF-8 `.core` source (see `compile_core`).
///
/// Returns `Ok(module)` — a resident module ready to `apply` — or the first
/// failing stage's error: `Error(CompileFailed(_))` if compilation fails, or
/// `Error(LoadFailed(_))` if loading fails. Does not panic on bad input.
///
/// The load `filename` is fixed to `"twocore_generated"` (metadata only); use
/// `load_module` directly if a specific `code:which` filename is needed.
pub fn compile_and_load(core_text: BitArray) -> Result(Atom, BuildError) {
  use #(mod, beam) <- result.try(compile_core(core_text))
  load_module(mod, "twocore_generated", beam)
  |> result.map_error(LoadFailed)
}
