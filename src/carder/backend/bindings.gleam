//// Phase-12 folder-output orchestrator (P12-05): resolve `--bindings` langs → run
//// `emit_<lang>(describe(module, binding))` → write the `.beam` + the companion binding source
//// files into `--out`, deterministically.
////
//// This is the driver behind the `to-beam-wasm --bindings <langs> --out <dir>` CLI surface. It
//// treats each `emit_<lang>` (P12-02/03/04) as a black box returning `List(GeneratedFile)` and the
//// `iface.describe` gate as the single fail-closed check — it never re-derives from the IR.
////
//// ## The correctness crux — one module to describe AND codegen (R17)
////
//// `emit_bindings` does NOT lower the module itself: the CLI lowers+optimizes ONCE (via
//// `pipeline.ir_to_lowered_core`) and hands THAT module to `emit_bindings` alongside the `.beam`
//// compiled from the same lowered core. So `describe` (called here) and the `.beam` ABI see
//// byte-identical function bodies — `touches_state`/emitted-arity cannot diverge (the R17 failure
//// mode: a mutation-carrying export misclassified pure, silently dropping the returned state `St'`).
//// The `module` this function receives is the one the `.beam` was generated from; its `.name` is
//// the compiled atom, and the `.beam` is written as `<module.name>.beam` so it auto-loads by that
//// atom (R8/R14).
////
//// ## Determinism (R25a)
////
//// Identical input ⇒ byte-identical files + identical returned path order. Languages run in the
//// canonical order **Gleam < Erlang < Elixir** (`parse_langs` canonicalizes + dedups the CSV), each
//// language's files are path-sorted, and the `.beam` is written first — no timestamps, no
//// Set-derived iteration, no absolute paths in content (content-purity is the emitters' job).
////
//// ## Fail-closed (P8)
////
//// GATHER-then-write, describe-first: a rejected module (`Cell` / import-bearing / mutable-tier)
//// produces NO partial output — `describe` runs before any file is written, so the only write-time
//// faults are genuine IO errors (`MkdirFailed`/`WriteFailed`).

import carder/backend/emit_elixir_bindings
import carder/backend/emit_erlang_bindings
import carder/backend/emit_gleam_bindings
import carder/backend/iface
import carder/ir
import carder/runtime/instance
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// A requested target language for a companion binding. The constructor order is the CANONICAL
/// determinism order **Gleam < Erlang < Elixir** (R25a) — `parse_langs` emits langs in this order
/// and `emit_bindings` runs them in it, so file/path ordering is stable.
pub type BindingLang {
  Gleam
  Erlang
  Elixir
}

/// This stage's typed failure surface (post-compile — distinct from `pipeline.PipelineError`).
///
/// - `Rejected(e)`: `iface.describe/2` refused the module (`CellUnsupported` / `ImportBearingUnsupported`
///   / `MutableTierUnsupported`) — NOTHING was written (describe runs before any IO).
/// - `MkdirFailed(path, detail)`: `create_directory_all(out_dir)` failed; `detail` is the rendered
///   `simplifile` error.
/// - `WriteFailed(path, detail)`: writing the `.beam` or a `GeneratedFile` failed; `detail` is the
///   rendered `simplifile` error.
pub type BindingsError {
  Rejected(iface.IfaceError)
  MkdirFailed(path: String, detail: String)
  WriteFailed(path: String, detail: String)
}

/// Parse a `--bindings` CSV into a CANONICAL, DEDUPED language list (R25a). Total.
///
/// Splits on `,`, trims surrounding whitespace, lower-cases, and maps each token to a `BindingLang`;
/// the result is returned in the canonical order **Gleam < Erlang < Elixir** with duplicates
/// removed, regardless of input order — e.g. `"elixir,gleam,gleam"` → `Ok([Gleam, Elixir])`.
///
/// - `csv`: the raw `--bindings` value (e.g. `"gleam,erlang"`).
/// - Returns `Ok(langs)` — a non-empty canonical list — or `Error(msg)` fail-closed on an EMPTY list
///   (`""` / all-blank) or an UNRECOGNISED token (`"rust"`), so the caller exits non-zero.
pub fn parse_langs(csv: String) -> Result(List(BindingLang), String) {
  let tokens =
    csv
    |> string.split(",")
    |> list.map(fn(t) { string.trim(t) |> string.lowercase })
    |> list.filter(fn(t) { t != "" })
  case tokens {
    [] ->
      Error("--bindings expects a non-empty comma list of gleam|erlang|elixir")
    _ ->
      result.map(list.try_map(tokens, parse_lang_token), fn(langs) {
        // Canonicalize + dedup: keep each language at most once, in the fixed order below.
        list.filter([Gleam, Erlang, Elixir], fn(l) { list.contains(langs, l) })
      })
  }
}

/// Map one lower-cased `--bindings` token to a `BindingLang`, or `Error(msg)` naming the bad token.
fn parse_lang_token(token: String) -> Result(BindingLang, String) {
  case token {
    "gleam" -> Ok(Gleam)
    "erlang" -> Ok(Erlang)
    "elixir" -> Ok(Elixir)
    _ ->
      Error(
        "--bindings: unknown language `"
        <> token
        <> "` (expected gleam|erlang|elixir)",
      )
  }
}

/// Emit the companion bindings + the `.beam` into `out_dir` (P4/P6). GATHER-then-write and
/// describe-first, so a rejected module produces NO partial output. Total.
///
/// Steps:
///   1. if `langs != []`: `iface.describe(module, binding)` → `Iface`, else `Error(Rejected(_))`
///      (writes nothing — the R12/R20 fail-closed gate);
///   2. run each requested `emit_<lang>(iface)` (canonical lang order, each language's files
///      path-sorted), concatenating their `GeneratedFile`s — ALL content built IN MEMORY first;
///   3. `create_directory_all(out_dir)`;
///   4. write `<out_dir>/<module.name>.beam`, then each `<out_dir>/<file.path>`.
/// `langs == []` (`--out` given, no `--bindings`) skips describe/emit and writes ONLY the `.beam`.
///
/// - `module`: the SAME lowered+optimized `ir.Module` the `.beam` was generated from (R17). Its
///   `.name` is the compiled atom; the `.beam` is written as `<module.name>.beam` (R8/R14).
/// - `binding`: the resolved build `Binding`; its `state_strategy`/tiers drive `describe` (must be
///   Threaded over the pure-value `Paged`/`TablePaged` tiers, else a typed `Rejected`).
/// - `beam`: the compiled `.beam` bytes (from `pipeline.core_to_beam` / `build_beam.link_beam`).
/// - `out_dir`: the output folder (created if absent).
/// - `langs`: the requested target languages (canonical, deduped — from `parse_langs`).
/// - Returns `Ok(written_paths)` — the `.beam` path first, then every binding file path, in
///   deterministic order — or the FIRST `BindingsError` (`Rejected` / `MkdirFailed` / `WriteFailed`).
pub fn emit_bindings(
  module: ir.Module,
  binding: instance.Binding,
  beam: BitArray,
  out_dir: String,
  langs: List(BindingLang),
) -> Result(List(String), BindingsError) {
  // 1 + 2 — describe-first, gather all file content in memory (nothing written yet).
  use files <- result.try(case langs {
    [] -> Ok([])
    _ ->
      case iface.describe(module, binding) {
        Error(e) -> Error(Rejected(e))
        Ok(desc) ->
          Ok(
            list.flat_map(langs, fn(lang) {
              emit_for(lang, desc)
              |> list.sort(fn(a, b) { string.compare(a.path, b.path) })
            }),
          )
      }
  })

  // 3 — create the output directory.
  use _ <- result.try(
    simplifile.create_directory_all(out_dir)
    |> result.map_error(fn(e) {
      MkdirFailed(out_dir, simplifile.describe_error(e))
    }),
  )

  // 4 — write the `.beam` first (named after the compiled atom), then each companion file.
  let beam_path = join(out_dir, module.name <> ".beam")
  use _ <- result.try(
    simplifile.write_bits(beam_path, beam)
    |> result.map_error(fn(e) {
      WriteFailed(beam_path, simplifile.describe_error(e))
    }),
  )
  use file_paths <- result.try(
    list.try_map(files, fn(f) {
      let path = join(out_dir, f.path)
      simplifile.write_bits(path, bit_array.from_string(f.content))
      |> result.map(fn(_) { path })
      |> result.map_error(fn(e) {
        WriteFailed(path, simplifile.describe_error(e))
      })
    }),
  )
  Ok([beam_path, ..file_paths])
}

/// Dispatch one language to its frozen `iface.emit_<lang>` entry (P12-02/03/04).
fn emit_for(lang: BindingLang, desc: iface.Iface) -> List(iface.GeneratedFile) {
  case lang {
    Gleam -> emit_gleam_bindings.emit_gleam(desc)
    Erlang -> emit_erlang_bindings.emit_erlang(desc)
    Elixir -> emit_elixir_bindings.emit_elixir(desc)
  }
}

/// Join an output directory to a relative file name with exactly one `/` separator (an `out_dir`
/// with or without a trailing slash yields the same path). Total.
fn join(dir: String, name: String) -> String {
  case string.ends_with(dir, "/") {
    True -> dir <> name
    False -> dir <> "/" <> name
  }
}

/// A human-readable `BindingsError` for CLI stderr. Total; diagnostic only — match the variant, do
/// NOT parse this string.
///
/// The `Rejected` arms carry the ACTIONABLE hint for the honest-scope gate (P8):
/// - `Rejected(CellUnsupported)` → the R12 "re-run with `--threaded`" hint (the default `Cell`
///   binding is rejected, so `--bindings` without `--threaded` never surfaces a bare `CellUnsupported`);
/// - `Rejected(ImportBearingUnsupported)` → export-only this phase; the module has imports;
/// - `Rejected(MutableTierUnsupported)` → the R20 pure-value-tier requirement (`Paged`/`TablePaged`).
pub fn describe_error(e: BindingsError) -> String {
  case e {
    Rejected(iface.CellUnsupported) ->
      "--bindings requires a --threaded (tier-P) build: the default Cell (stateful) binding has no typed-binding surface this phase — re-run with --threaded"
    Rejected(iface.ImportBearingUnsupported) ->
      "--bindings supports export-only modules this phase; the module declares imports (a typed provider surface is deferred)"
    Rejected(iface.MutableTierUnsupported) ->
      "--bindings requires a pure-value memory/table tier (Paged + TablePaged): a value-threaded binding over a mutable tier (atomics/nif/ets) would alias mutable state"
    MkdirFailed(path, detail) ->
      "could not create output directory " <> path <> ": " <> detail
    WriteFailed(path, detail) -> "could not write " <> path <> ": " <> detail
  }
}
