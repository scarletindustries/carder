//// S15-01 keystone proof — the tier-N («nif») native TOOLCHAIN PATH, proven live.
////
//// This module proves the *pipe, not the water* (keystone §1): that a real C `erl_nif` NIF
//// COMPILES into a loadable `.so`, `load_nif` ATTACHES it to the `twocore_rt_mem_nif_ffi` shim, and a
//// NIF called through the shim RETURNS — on both CI gcc and macOS clang. It ships NO memory logic:
//// `rt_mem_nif.gleam` stays the byte-identical paged-delegate, untouched (its own differential suite,
//// `rt_mem_nif_test.gleam`, stays green unchanged).
////
//// The proof is a live compile+load+call, NOT a golden (S7): no test locks C source or emitted Core
//// text. The headline test is toolchain-gated — on a host with `cc`/`gcc` it builds+loads+asserts
//// `pong`; on a host without a C toolchain it prints a CATEGORIZED SKIP and passes (never a false
//// green — S6), exactly as the Phase-12 Elixir binding arm skip-gates on `elixirc`.

import gleam/erlang/atom.{type Atom}
import gleam/io
import gleeunit/should

/// The three-valued outcome of a toolchain-gated NIF build, marshalled directly from the build FFI's
/// `loaded | skip_no_toolchain | {build_error, Bin}` (no manual decode):
///
/// - `Loaded` — the `.so` compiled, `load_nif` attached it, and `nif_ping()` returned `pong`.
/// - `SkipNoToolchain` — no `cc`/`gcc` on PATH; the build was skipped BEFORE any compile (categorized,
///   never a false green — S6).
/// - `BuildError(String)` — a LOUD failure (compile error, `load_nif` failed, or a wrong `nif_ping`
///   answer): the pipe is broken. The message carries the toolchain/loader diagnostics.
pub type BuildResult {
  Loaded
  SkipNoToolchain
  BuildError(String)
}

/// Compile the embedded `nif_ping` probe `.c` (against the committed `c_src/twocore_rt_mem_nif.h`),
/// force-reload the shim so `-on_load` attaches the fresh `.so`, and verify `nif_ping()` returns
/// `pong`. See `test/twocore_rt_mem_nif_build_ffi.erl`. Returns the categorized `BuildResult`.
@external(erlang, "twocore_rt_mem_nif_build_ffi", "compile_load_probe")
fn compile_load_probe() -> BuildResult

/// Probe a toolchain executable on PATH: `Ok(path)` if found, `Error(Nil)` if not. THE gate — this is
/// what `compile_load_*` maps to `SkipNoToolchain` on absence.
@external(erlang, "twocore_rt_mem_nif_build_ffi", "which")
fn which(exe: String) -> Result(String, Nil)

/// The shim's `nif_ping/0` NIF: returns the atom `pong` once the `.so` is attached; raises
/// `nif_not_loaded` until then. Only ever CALLED after `compile_load_probe()` reports `Loaded`.
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_ping")
fn nif_ping() -> Atom

/// THE keystone live proof (toolchain-gated). On a host with `cc`/`gcc` (CI gcc, dev macOS clang) this
/// compiles the `nif_ping` probe, `load_nif`s it, and asserts the round-tripped atom is `pong` —
/// proving the entire native toolchain path (erl_nif.h resolution, the committed `.h` compiling,
/// resource-type registration, `ERL_NIF_INIT` dispatch, term marshalling). Absent a toolchain it is a
/// CATEGORIZED SKIP that passes; a compile/`load_nif` failure is a LOUD test failure (the pipe is
/// broken). This is the `«NIF-BUILD-FROZEN»` proof.
pub fn nif_ping_compiles_loads_and_returns_pong_test() {
  case compile_load_probe() {
    SkipNoToolchain -> {
      io.println(
        "\n[s15-01] no C toolchain (cc/gcc) on PATH — tier-N NIF build+load SKIPPED (categorized, S6)",
      )
      Nil
    }
    BuildError(text) -> panic as text
    Loaded -> nif_ping() |> should.equal(atom.create("pong"))
  }
}

/// The gate-categorization logic, asserted independently of the ambient toolchain. The
/// `SkipNoToolchain` branch above is only *taken* where `cc`/`gcc` is genuinely absent (CI/dev always
/// have one), so assert the CATEGORIZATION directly: `os:find_executable` for a name that cannot exist
/// returns the `Error(Nil)` that `compile_load_*` maps to `SkipNoToolchain`. This is why the skip arm
/// is trusted to be a real, categorized pass — the gate, not the toolchain, is what's proven here.
pub fn gate_categorizes_toolchain_absence_test() {
  which("twocore-cc-that-does-not-exist-xyz")
  |> should.equal(Error(Nil))
}
