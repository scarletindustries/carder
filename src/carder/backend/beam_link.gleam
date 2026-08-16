//// The whole-program Core-Erlang linker (Phase 11 · P11-03) — `«LINKER-IFACE-FROZEN»`.
////
//// Merges a generated (wasm-derived) module and its ENTIRE transitive
//// `carder@*`/`gleam@*` dependency closure into ONE self-contained `.beam`
//// whose only remaining remote calls are to the fixed OTP-ambient allowlist —
//// dead code stripped, no ambient authority (D3a). This is the typed Gleam
//// orchestration over the `cerl` surgery in `src/carder_linker_ffi.erl`; the
//// AST work lives in the FFI (the same OTP-29-internals trust boundary as
//// `build_beam`/`carder_codegen_ffi`), and this module is the stable
//// `Result`-typed seam the CLI (P11-04) and capstone (P11-06) build against.
////
//// Naming (R17): `link` is 3-way overloaded — `profiles.link/1` (runtime
//// instantiation), `runtime/link.gleam` (import weaving). This whole-program
//// merge is named `link_program` to avoid confusion with either.
////
//// PINNED TO OTP 29 (via the FFI). See `src/carder_linker_ffi.erl` for the
//// merge algorithm (acquire → reachability → mangle → DCE → module_info/attrs →
//// deterministic `from_core`, with a built-in fail-closed structural D3a check).

import carder/backend/eaf
import gleam/erlang/atom.{type Atom}

/// Why a whole-program link refused to produce a `.beam` (fail-closed). Each
/// variant is a distinct, terminal reason surfaced at LINK time — never a
/// runtime `undef` on the target node. The CLI (P11-04) and capstone (P11-06)
/// match on these.
pub type LinkError {
  /// A remote call survived to a module that is neither the merged module nor
  /// on the OTP-ambient allowlist. `module`/`fun` name the offending target.
  /// (D3a backstop: after the merge every in-closure remote is rewritten to a
  /// local apply, so a surviving off-allowlist remote is a fail-closed refusal.)
  OffAllowlistRemote(module: String, fun: String)
  /// An in-closure module (reached by the walk, non-ambient) whose Core could
  /// not be located — its `.beam` was not on the code path. `module` names it.
  /// A missing dependency surfaces HERE, never as a runtime `undef`.
  MissingClosureModule(module: String)
  /// The D3a security invariant was violated: `erlang:apply`, an `apply`/call
  /// on a data-derived (computed) module, or a residual fun-capture to an
  /// off-closure module. `detail` describes the specific construct found.
  AmbientAuthorityFound(detail: String)
  /// A closure module carries a construct that cannot be merged into a `.beam`:
  /// an `-on_load` directive or an OTP behaviour (a NIF loader / load-time
  /// callback). `detail` names the module and construct. Absent in tier-P/O.
  UnmergeableConstruct(detail: String)
  /// The mangle-injectivity precondition (R12) was violated: a discovered
  /// in-closure module atom itself contains the `"__"` separator, so the
  /// `'M__F'` local-name scheme would not be collision-free. `a`/`b` carry the
  /// offending atom and detail.
  MangleCollision(a: String, b: String)
  /// The `to_core` lowering of the generated forms, `core_lint`, or
  /// `compile:forms` rejected the input or the merged output (e.g. broken
  /// generated forms, or a declared-name mismatch). `detail` is a
  /// human-readable diagnostic, never a raw term.
  MalformedCore(detail: String)
  /// An in-closure module was located but its Core could not be acquired (no
  /// `core_v1` `debug_info` chunk and no compilable source). `module`/`reason`
  /// identify it.
  CoreAcquisitionFailed(module: String, reason: String)
}

/// FFI into `carder_linker_ffi:link_program/3`. Returns the shim's
/// `{ok,{Mod,Beam}} | {error,{TagBin,ABin,BBin}}` mapped onto a Gleam
/// `Result(#(Atom, BitArray), #(String, String, String))` — a flat 3-string
/// error tuple this module decodes into `LinkError`. Gleam does NOT type-check
/// this boundary; the shapes are validated by the tests (trust boundary).
@external(erlang, "carder_linker_ffi", "link_program")
fn ffi_link_program(
  generated_forms: List(eaf.Form),
  module_name: String,
  ambient: List(String),
) -> Result(#(Atom, BitArray), #(String, String, String))

/// FFI into `carder_linker_ffi:link_to_core/3` — the same merge returning the
/// merged Core Erlang TEXT before compilation.
@external(erlang, "carder_linker_ffi", "link_to_core")
fn ffi_link_to_core(
  generated_forms: List(eaf.Form),
  module_name: String,
  ambient: List(String),
) -> Result(#(Atom, String), #(String, String, String))

/// Map the FFI's flat `#(tag, a, b)` error triple onto a typed `LinkError`.
/// An unrecognized tag is surfaced as `MalformedCore` (fail-closed toward the
/// safe, terminal error rather than silently succeeding).
fn to_link_error(err: #(String, String, String)) -> LinkError {
  let #(tag, a, b) = err
  case tag {
    "off_allowlist_remote" -> OffAllowlistRemote(a, b)
    "missing_closure_module" -> MissingClosureModule(a)
    "ambient_authority" -> AmbientAuthorityFound(a)
    "unmergeable_construct" -> UnmergeableConstruct(a)
    "mangle_collision" -> MangleCollision(a, b)
    "malformed_core" -> MalformedCore(a)
    "core_acquisition_failed" -> CoreAcquisitionFailed(a, b)
    _ -> MalformedCore("unrecognized linker error tag: " <> tag)
  }
}

/// Merge the generated module + its transitive carder/gleam closure into ONE
/// self-contained `.beam`.
///
/// - `generated_forms`: the generated module's Erlang Abstract Format forms
///   (from `eaf.module_forms` — exactly what `build_beam.compile_forms`
///   consumes); the linker recovers the cerl module via the compiler's own
///   `to_core` pass in-process.
/// - `module_name`: the generated module's atom name — it MUST equal the
///   `-module` attribute (`== ir.Module.name`). It BOTH locates the generated
///   module and names the merged output. Callers that load multiple linked
///   modules concurrently pass a uniquified name (R10/capstone).
/// - `ambient`: `link_manifest.ambient_allowlist()` — the modules DCE walks up
///   to but not into (left as remote calls).
///
/// Returns `Ok(#(atom, beam))` where `atom` is GUARANTEED to equal the module
/// name declared inside `beam` (P11-05 resolves the child via `code:which(atom)`
/// against `<atom>.beam`), or `Error(LinkError)` describing the fail-closed
/// reason. Never panics on bad input — a malformed generated `.core`, a missing
/// dependency, or a D3a violation all surface as a typed `Error`.
pub fn link_program(
  generated_forms: List(eaf.Form),
  module_name: String,
  ambient: List(String),
) -> Result(#(Atom, BitArray), LinkError) {
  case ffi_link_program(generated_forms, module_name, ambient) {
    Ok(pair) -> Ok(pair)
    Error(err) -> Error(to_link_error(err))
  }
}

/// The same merge as `link_program`, returning the merged Core Erlang TEXT
/// *before* compilation — the seam P11-06 uses to independently re-run the
/// structural D3a assertion and to inspect DCE.
///
/// - Parameters are identical to `link_program`.
///
/// Returns `Ok(#(atom, core_text))` — `core_text` is the deterministic,
/// annotation-stripped merged Core Erlang source whose declared module name is
/// `atom` — or `Error(LinkError)`. Single-sourced with `link_program` (which is
/// this merge followed by a deterministic `from_core` compile), so both apply
/// the identical reachability/mangle/DCE and the identical fail-closed D3a
/// self-check.
pub fn link_to_core(
  generated_forms: List(eaf.Form),
  module_name: String,
  ambient: List(String),
) -> Result(#(Atom, String), LinkError) {
  case ffi_link_to_core(generated_forms, module_name, ambient) {
    Ok(pair) -> Ok(pair)
    Error(err) -> Error(to_link_error(err))
  }
}
