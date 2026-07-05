//// P12-05 tests for the `--bindings`/`--out` CLI flags + the folder-output driver.
////
//// Spec-cited against P6 (CLI + folder output, deterministic) / P4 (bindings are companions, the
//// `.beam` untouched) / P8 (honest-scope gates) + the R-corrections — NOT golden change-detectors.
//// The load-bearing ones:
////
//// - **Default-off byte-identity (P4/P6):** `to-beam-wasm <in> <out.beam>` (no `--bindings`/`--out`)
////   writes bytes EQUAL to a fresh `pipeline.ir_to_core → core_to_beam` over the same binding —
////   `describe` is never reached and no directory is created.
//// - **R17 lower-ONCE seam (the crux):** the module `describe` sees IS the module the `.beam` is
////   generated from (`pipeline.ir_to_lowered_core`), so a memory-mutating export is `touches_state`
////   (Threaded) and its `ExportSig.emitted_arity` equals the arity in the REAL emitted `.core` — a
////   dropped-mutation misclassification cannot slip through.
//// - **R12 gate:** `--bindings` without `--threaded` (default `Cell`) surfaces the "re-run with
////   `--threaded`" hint and writes NOTHING. **R20:** a mutable tier is rejected.
//// - **Folder emission + `.beam` non-perturbation:** the emitted `.beam` equals the plain build and
////   each companion file's content EQUALS `emit_<lang>(describe(m, binding))` (composition).

import gleam/list
import gleam/option.{None}
import gleam/string
import simplifile
import twocore
import twocore/backend/bindings
import twocore/backend/core_erlang.{type FName, FName}
import twocore/backend/emit_core
import twocore/backend/emit_erlang_bindings
import twocore/backend/emit_gleam_bindings
import twocore/backend/iface
import twocore/ir
import twocore/pipeline
import twocore/runtime/instance
import twocore/runtime/profiles

const corpus = "test/twocore/conformance/corpus"

// ───────────────────────────── fixtures ─────────────────────────────

/// A side-effect-free `f(p0, p1) -> [TI32]` computing `p0 + p1` (no stateful node).
fn pure_add(name: String) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Num(ir.IAdd(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
  )
}

/// A minimal accepted-shape module `twocore@wasm@<base>` (memory + a mutable global so it emits
/// coherently) exporting a pure `add`. Import-free and pure-value-tier-clean by construction.
fn simple_module(base: String, imports: List(ir.ImportDecl)) -> ir.Module {
  ir.Module(
    name: "twocore@wasm@" <> base,
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, None, ir.Idx32)],
    globals: [ir.GlobalDecl("g", ir.TI32, True, ir.Values([ir.ConstI32(0)]))],
    imports: imports,
    functions: [pure_add("add")],
    exports: [ir.ExportFn("add", "add")],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
    tags: [],
  )
}

/// The arity of the emitted `.core` export named `name` (its `FName` arity in the `CModule`).
fn emitted_core_arity(exports: List(FName), name: String) -> Int {
  let assert Ok(FName(_, arity)) =
    list.find(exports, fn(fname) {
      let FName(n, _) = fname
      n == name
    })
  arity
}

/// The `--threaded` build binding the CLI resolves for `--threaded` (Safe base → Threaded, Paged /
/// TablePaged) — the accepted Phase-12 posture.
fn threaded_binding() -> instance.Binding {
  let assert Ok(b) =
    twocore.resolve_binding(profiles.safe(), True, None, None, None)
  b
}

// ───────────────────────────── parse_langs (P6/R25a) ─────────────────────────────

/// `parse_langs` maps a CSV to a CANONICAL, DEDUPED language list (Gleam < Erlang < Elixir),
/// regardless of input order or case, and fails closed on an empty list / unknown token.
pub fn parse_langs_canonical_test() {
  assert bindings.parse_langs("gleam,erlang,elixir")
    == Ok([bindings.Gleam, bindings.Erlang, bindings.Elixir])
  // reordered input → canonical output.
  assert bindings.parse_langs("elixir,gleam")
    == Ok([bindings.Gleam, bindings.Elixir])
  // deduped.
  assert bindings.parse_langs("gleam,gleam") == Ok([bindings.Gleam])
  // whitespace + case tolerated.
  assert bindings.parse_langs(" Gleam , ERLANG ")
    == Ok([bindings.Gleam, bindings.Erlang])
}

pub fn parse_langs_fail_closed_test() {
  let assert Error(_) = bindings.parse_langs("")
  let assert Error(_) = bindings.parse_langs("   ")
  let assert Error(msg) = bindings.parse_langs("rust")
  assert string.contains(msg, "rust")
}

// ───────────────────────────── default-off byte-identity (P4/P6) ─────────────────────────────

/// P4/P6 hard requirement — with neither `--bindings` nor `--out`, `to-beam-wasm <in> <out.beam>`
/// writes bytes EQUAL to the pre-existing default pipeline (`source_to_ir → ir_to_core →
/// core_to_beam`) over the identical resolved binding: the folder path adds NO default-path code and
/// `describe` is never reached.
pub fn default_off_byte_identical_test() {
  let wasm = corpus <> "/add.wasm"
  let out = "build/p12_default_add.beam"
  let _ = simplifile.delete(out)

  let assert Ok(msg) = twocore.run(["to-beam-wasm", wasm, out])
  assert string.contains(msg, "wrote")
  let assert Ok(cli_beam) = simplifile.read_bits(out)

  // Oracle: the default non-bindings path over the identical resolved binding.
  let assert Ok(bytes) = simplifile.read_bits(wasm)
  let assert Ok(m) = pipeline.source_to_ir(bytes)
  let assert Ok(binding) =
    twocore.resolve_binding(profiles.safe(), False, None, None, None)
  let assert Ok(core) = pipeline.ir_to_core(m, binding)
  let assert Ok(oracle_beam) = pipeline.core_to_beam(core, m.name)

  assert cli_beam == oracle_beam
  let _ = simplifile.delete(out)
}

// ───────────────────────────── fail-closed routing (P6) ─────────────────────────────

/// `--bindings` with no `--out` is rejected fail-closed, the diagnostic naming `--out`.
pub fn bindings_without_out_rejected_test() {
  let assert Error(msg) =
    twocore.run([
      "to-beam-wasm",
      "--threaded",
      "--bindings",
      "gleam",
      corpus <> "/add.wasm",
      "out.beam",
    ])
  assert string.contains(msg, "--out")
}

/// `--out` with too many positionals is rejected (the `.beam` name derives from the module atom).
pub fn out_too_many_positionals_rejected_test() {
  let assert Error(msg) =
    twocore.run([
      "to-beam-wasm",
      "--out",
      "build/p12_x",
      corpus <> "/add.wasm",
      "extra",
    ])
  assert string.contains(msg, "with --out")
}

/// A bad `--bindings` language token is rejected during flag parsing (fail-closed, before any IO).
pub fn bad_lang_token_rejected_test() {
  let assert Error(msg) =
    twocore.run([
      "to-beam-wasm",
      "--threaded",
      "--bindings",
      "rust",
      "--out",
      "build/p12_x",
      corpus <> "/add.wasm",
    ])
  assert string.contains(msg, "rust")
}

/// A second `--bindings` / `--out` is rejected fail-closed.
pub fn duplicate_output_flags_rejected_test() {
  let assert Error(_) =
    twocore.run([
      "to-beam-wasm",
      "--bindings",
      "gleam",
      "--bindings",
      "erlang",
      "--out",
      "d",
      corpus <> "/add.wasm",
    ])
  let assert Error(_) =
    twocore.run([
      "to-beam-wasm",
      "--out",
      "d1",
      "--out",
      "d2",
      corpus <> "/add.wasm",
    ])
}

/// R.§3.3 — `--bindings`/`--out` are `to-beam-wasm`-only: every other compile verb rejects them
/// fail-closed (via `reject_output_flags`), short-circuiting BEFORE any file IO.
pub fn output_flags_rejected_on_other_verbs_test() {
  let assert Error(m1) =
    twocore.run(["emit", "--bindings", "gleam", "--out", "d", "x.ir"])
  assert string.contains(m1, "to-beam-wasm")
  let assert Error(m2) = twocore.run(["to-core", "--out", "d", "x.ir"])
  assert string.contains(m2, "to-beam-wasm")
  let assert Error(m3) =
    twocore.run(["run", "--bindings", "erlang", "x.wasm", "add", "1", "2"])
  assert string.contains(m3, "to-beam-wasm")
}

// ───────────────────────────── honest-scope gates (P8 / R12 / R20) ─────────────────────────────

/// R12 — `--bindings` without `--threaded` (the default `Cell` binding) surfaces the "re-run with
/// `--threaded`" hint (NOT a bare `CellUnsupported`) and writes NOTHING (describe runs before any
/// IO, so no directory / `.beam` is created).
pub fn bindings_without_threaded_rejected_test() {
  let dir = "build/p12_cell_out"
  let _ = simplifile.delete(dir)

  let assert Error(msg) =
    twocore.run([
      "to-beam-wasm",
      "--bindings",
      "gleam",
      "--out",
      dir,
      corpus <> "/mem.wasm",
    ])
  assert string.contains(msg, "--threaded")
  // Nothing written — the `.beam` named after the module atom must be absent.
  let assert Error(_) =
    simplifile.read_bits(dir <> "/twocore@wasm@roundtrip.beam")
  let _ = simplifile.delete(dir)
}

/// R20 — a Threaded build over a MUTABLE memory tier (`Atomics`) is rejected
/// `Rejected(MutableTierUnsupported)`, with the pure-value-tier hint, and writes NOTHING. Driven at
/// the driver seam (a `<<>>` beam is never used — describe fails first).
pub fn emit_bindings_rejects_mutable_tier_test() {
  let dir = "build/p12_mut_out"
  let _ = simplifile.delete(dir)
  let m = simple_module("mut", [])
  let atomics =
    instance.Binding(..threaded_binding(), mem_tier: instance.Atomics)

  let assert Error(e) =
    bindings.emit_bindings(m, atomics, <<>>, dir, [bindings.Gleam])
  assert e == bindings.Rejected(iface.MutableTierUnsupported)
  assert string.contains(bindings.describe_error(e), "pure-value")
  let assert Error(_) = simplifile.read_bits(dir <> "/" <> m.name <> ".beam")
  let _ = simplifile.delete(dir)
}

/// P8 — an import-bearing module under an accepted (Threaded) binding is rejected
/// `Rejected(ImportBearingUnsupported)` and writes NOTHING (export-only this phase).
pub fn emit_bindings_rejects_import_bearing_test() {
  let dir = "build/p12_imp_out"
  let _ = simplifile.delete(dir)
  let imp = ir.ImportFn("host", "log", ir.FuncType([ir.TI32], []))
  let m = simple_module("imp", [imp])

  let assert Error(e) =
    bindings.emit_bindings(m, threaded_binding(), <<>>, dir, [bindings.Gleam])
  assert e == bindings.Rejected(iface.ImportBearingUnsupported)
  let assert Error(_) = simplifile.read_bits(dir <> "/" <> m.name <> ".beam")
  let _ = simplifile.delete(dir)
}

// ───────────────────────────── R17 lower-ONCE seam (the crux) ─────────────────────────────

/// R17 (correctness crux) — `describe` and the emitted `.beam` see the SAME module. Using the
/// lower-ONCE seam (`pipeline.ir_to_lowered_core`), a memory-mutating module is classified
/// `Threaded` with every export `touches_state`, and each `ExportSig.emitted_arity` EQUALS the arity
/// of the corresponding export in the REAL emitted `.core` (from the identical lowered module) —
/// value-level proof that a dropped-mutation misclassification cannot slip through.
pub fn r17_lower_once_seam_test() {
  let wasm = corpus <> "/mem.wasm"
  let binding = threaded_binding()
  let assert Ok(bytes) = simplifile.read_bits(wasm)
  let assert Ok(m) = pipeline.source_to_ir(bytes)

  // The seam: the module `describe` sees IS the one the `.core` (hence `.beam`) is generated from.
  let assert Ok(#(lowered, _core)) = pipeline.ir_to_lowered_core(m, binding)
  let assert Ok(desc) = iface.describe(lowered, binding)

  // Memory-mutating exports → Threaded, every export state-reaching.
  assert desc.state_model == iface.Threaded
  assert list.all(desc.exports, fn(e) { e.touches_state })

  // Arity agreement against the ACTUAL emitted `.core` of the IDENTICAL lowered module.
  let assert Ok(cmod) = emit_core.emit_module(lowered, binding)
  list.each(desc.exports, fn(e) {
    assert e.emitted_arity == emitted_core_arity(cmod.exports, e.dispatch_atom)
  })
}

// ───────────────────────────── folder emission + `.beam` non-perturbation (P4/P6) ─────────────────────────────

/// P4/P6 — for a real threaded, export-only `.wasm`, the FOLDER path writes
/// `<dir>/<module.name>.beam` whose bytes EQUAL the plain (no-bindings) build of the same module +
/// binding (bindings do not perturb the `.beam`), plus each requested language's companion files at
/// the emitters' `GeneratedFile.path`s — each file's content EQUALS `emit_<lang>(describe(m,
/// binding))` (composition, not a frozen string).
pub fn folder_emission_and_beam_non_perturbation_test() {
  let wasm = corpus <> "/mem.wasm"
  let dir = "build/p12_folder_out"
  let _ = simplifile.delete(dir)

  let assert Ok(msg) =
    twocore.run([
      "to-beam-wasm", "--threaded", "--bindings", "gleam,erlang", "--out", dir,
      wasm,
    ])
  assert string.contains(msg, "wrote")

  // The `.beam` is named after the compiled module atom.
  let beam_path = dir <> "/twocore@wasm@roundtrip.beam"
  let assert Ok(folder_beam) = simplifile.read_bits(beam_path)

  // `.beam` non-perturbation: equals the plain build of the same module + binding (via the seam).
  let binding = threaded_binding()
  let assert Ok(bytes) = simplifile.read_bits(wasm)
  let assert Ok(m) = pipeline.source_to_ir(bytes)
  let assert Ok(#(lowered, core)) = pipeline.ir_to_lowered_core(m, binding)
  let assert Ok(oracle_beam) = pipeline.core_to_beam(core, m.name)
  assert folder_beam == oracle_beam

  // Each companion file's content EQUALS the emitter's output for the same descriptor.
  let assert Ok(desc) = iface.describe(lowered, binding)
  let expected =
    list.append(
      emit_gleam_bindings.emit_gleam(desc),
      emit_erlang_bindings.emit_erlang(desc),
    )
  list.each(expected, fn(f) {
    let assert Ok(written) = simplifile.read(dir <> "/" <> f.path)
    assert written == f.content
  })
  // The Gleam drop is THREE files (R22) + Erlang's one — all present.
  assert list.length(expected) == 4
  let _ = simplifile.delete(dir)
}

// ───────────────────────────── determinism (P6/R25a) ─────────────────────────────

/// P6/R25a — `emit_bindings` is deterministic: two runs over the same input yield identical returned
/// path order (modulo the output dir) and byte-identical file contents. Uses a real threaded module
/// + `.beam` from the pipeline.
pub fn emit_bindings_deterministic_test() {
  let wasm = corpus <> "/mem.wasm"
  let binding = threaded_binding()
  let assert Ok(bytes) = simplifile.read_bits(wasm)
  let assert Ok(m) = pipeline.source_to_ir(bytes)
  let assert Ok(#(lowered, core)) = pipeline.ir_to_lowered_core(m, binding)
  let assert Ok(beam) = pipeline.core_to_beam(core, m.name)

  let d1 = "build/p12_det_1"
  let d2 = "build/p12_det_2"
  let _ = simplifile.delete(d1)
  let _ = simplifile.delete(d2)
  let langs = [bindings.Gleam, bindings.Erlang, bindings.Elixir]

  let assert Ok(p1) = bindings.emit_bindings(lowered, binding, beam, d1, langs)
  let assert Ok(p2) = bindings.emit_bindings(lowered, binding, beam, d2, langs)

  // Same file set + order (with the dir prefix stripped).
  let strip = fn(paths, dir) {
    list.map(paths, fn(p) { string.replace(p, dir <> "/", "") })
  }
  assert strip(p1, d1) == strip(p2, d2)
  // The `.beam` is written FIRST, then the companion files in canonical lang order.
  let assert [first, ..] = strip(p1, d1)
  assert first == "twocore@wasm@roundtrip.beam"

  // Byte-identical file contents across the two runs.
  list.each(strip(p1, d1), fn(rel) {
    let assert Ok(a) = simplifile.read_bits(d1 <> "/" <> rel)
    let assert Ok(b) = simplifile.read_bits(d2 <> "/" <> rel)
    assert a == b
  })
  let _ = simplifile.delete(d1)
  let _ = simplifile.delete(d2)
}
