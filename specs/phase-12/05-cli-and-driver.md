# P12-05 — CLI flags + folder-output driver

> **Status:** scoped, awaiting build. **Owner:** unit P12-05 (Wave A — builds against the frozen
> emitter signatures, in parallel with P12-02/03/04). **Depends on freeze:** `«IFACE-DESC-FROZEN»`
> (P12-01). **Freezes:** nothing new — this is a leaf wiring unit. Implementer read order:
> [`00-overview.md`](00-overview.md) → this doc. All prior-phase decisions and the permanent invariants
> ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold.

---

## §1. Goal

Give `to-beam-wasm` two new flags — `--bindings <langs>` (comma list of `gleam`/`erlang`/`elixir`) and
`--out <dir>` — and a **folder-output driver** that, alongside the `.beam`, emits one typed companion
binding source file per requested language into `<dir>`. This is the CLI surface of the phase and the
realization of **decision P6** (CLI + folder output, deterministic; composes with `--link`). It also
enforces **P4** (bindings are companion source files, the `.beam` untouched) and **P8** (honest scope) at
the command boundary: a Cell (tier-O) or import-bearing module is rejected as a typed CLI error with a
non-zero exit, never a partial/garbage emission.

**Hard requirements** (from P6 / the acceptance table):
- **Default off ⇒ byte-identical.** Absent both flags, `to-beam-wasm` behaves *exactly* as today — same
  positionals `<in.wasm> <out.beam>`, same `.beam` bytes, no directory created, `describe/2` never called.
- **Deterministic.** Identical input ⇒ byte-identical files, stable filenames, stable write order, no
  timestamps/absolute paths in content (content-purity is the emitters' job; ordering + naming is ours).
- **Composes with Phase-11 `--link`.** The emitted binding calls `'<module_atom>':'<export>'(…)`; that
  atom is `Iface.module_name` and the `.beam` file is named after it — see the coupling note in §3.
- **Fail-closed.** A `describe/2` `IfaceError` (Cell / import-bearing) and a bad `--bindings` token both
  halt non-zero with a diagnostic; nothing partial is written.

---

## §2. Depends on / Produces

**Depends on (frozen signatures only, not sibling bodies):**
- `«IFACE-DESC-FROZEN»` — `src/twocore/backend/iface.gleam`: `describe(module, binding) -> Result(Iface,
  IfaceError)`, the `Iface`/`ExportSig`/`GeneratedFile`/`IfaceError` types, and the uniform emitter entries
  `emit_gleam` / `emit_erlang` / `emit_elixir : Iface -> List(GeneratedFile)` (P12-02/03/04 fill the bodies).
- Existing pipeline seams (read, not owned): `pipeline.source_to_ir/1` (`pipeline.gleam:423`),
  `pipeline.ir_to_core/2` (`:481`), `pipeline.core_to_beam/2` (`:504`); `instance.Binding`;
  `ir.Module` (its `.name` field, `ir.gleam:90`); `simplifile.write_bits` / `create_directory_all`.

**Produces:**
- **New** `src/twocore/backend/bindings.gleam` — the folder-output orchestrator (the one deliberate new file).
- **Edits** `src/twocore.gleam` — `--bindings`/`--out` parsing + the rewritten `cmd_to_beam_wasm` + usage.
- Test module `test/twocore/backend/bindings_driver_test.gleam`.

**Leaves to P12-06 (capstone):** a stable CLI + `bindings.emit_bindings` seam onto which the per-language
**compile+call differential** (invoke `gleam build`/`erlc`/`elixirc`, then call an export) is hung.

---

## §3. What it owns + design

**D1 files:** `src/twocore/backend/bindings.gleam` (new, sole owner); `src/twocore.gleam` (P12-05 owns the
Phase-12 CLI edits). No other file is touched.

### 3.1 The driver — `backend/bindings.gleam`

```gleam
//// Phase-12 folder-output orchestrator: langs → emit_<lang>(describe(module, binding)) → files.

import twocore/backend/iface
import twocore/ir
import twocore/runtime/instance

/// A requested target language. Canonical order for determinism: Gleam < Erlang < Elixir.
pub type BindingLang { Gleam  Erlang  Elixir }

/// This stage's typed failure surface (post-compile — distinct from pipeline.PipelineError).
pub type BindingsError {
  Rejected(iface.IfaceError)                    // describe/2 said no (Cell / import-bearing)
  MkdirFailed(path: String, detail: String)     // could not create <out_dir>
  WriteFailed(path: String, detail: String)     // a .beam or GeneratedFile write failed
}

/// Parse a `--bindings` CSV into a CANONICAL, DEDUPED language list. `"elixir,gleam,gleam"` →
/// `[Gleam, Elixir]`. `Error(msg)` on an empty list or an unrecognised token (fail-closed). Total.
pub fn parse_langs(csv: String) -> Result(List(BindingLang), String)

/// Emit companion bindings + the `.beam` into `out_dir`. GATHER-THEN-WRITE + describe-first, so a
/// rejected module produces NO partial output and the only write-time faults are genuine IO errors:
///   1. if `langs != []`, `describe(module, binding)` → `Iface` or `Error(Rejected(_))` (writes nothing);
///   2. run each requested `emit_<lang>(iface)`, concatenating their `GeneratedFile`s (canonical lang
///      order, files sorted by path) — all content built IN MEMORY first;
///   3. `create_directory_all(out_dir)`;
///   4. write `<out_dir>/<module.name>.beam`, then each `<out_dir>/<file.path>`.
/// `langs == []` (── `--out` given, no `--bindings`) skips describe/emit and writes only the `.beam`.
///
/// - `module`: the SAME `ir.Module` fed to `pipeline.ir_to_core` — its `.name` is the compiled atom.
/// - `binding`:  the resolved build `Binding` (its `state_strategy` drives `describe`; must be Threaded).
/// - `beam`:     the compiled `.beam` bytes (from `pipeline.core_to_beam`).
/// Returns `Ok(written_paths)` in deterministic order, or the first `BindingsError`. Total.
pub fn emit_bindings(
  module: ir.Module, binding: instance.Binding,
  beam: BitArray, out_dir: String, langs: List(BindingLang),
) -> Result(List(String), BindingsError)

/// Human-readable `BindingsError` for CLI stderr (mirrors `pipeline.describe`). Total; diagnostic only.
/// `Rejected(CellUnsupported)` → "…require a --threaded (tier-P) build…"; `Rejected(ImportBearingUnsupported)`
/// → "…export-only this phase; the module has imports…". Match the variant, don't parse this string.
pub fn describe_error(e: BindingsError) -> String
```

`emit_for(lang, iface)` is the private one-line dispatch to the three frozen `iface.emit_<lang>` entries.

### 3.2 The `.beam`-name / module-atom coupling (open seam §3.3 of the overview — RESOLVED)

`emit_core` emits the module header as **`module.name` verbatim** (`emit_core.gleam:356`, `:403`), and each
emitter derives the binding's dispatch atom + its own `GeneratedFile` filenames from `Iface.module_name`
(which P12-01 sets from `module.name`). Therefore the `.beam` **file** is named `<module.name>.beam` — *not*
after the input stem — so the loaded module's atom matches both the code path and the binding's
`'<module_atom>':'<export>'(…)` call. (The `app.wasm → app.beam` acceptance example holds because that
module's `.name` is `app`.) This composes with Phase-11 `--link` for free: `--link` renames `ir.Module.name`
*before* codegen, and P12-05 reads the name from **the same module it compiles**, so `Iface.module_name`,
the `.beam` filename, and the dispatch atom all track the linked atom with no extra wiring. (No `--link`
code exists in-tree yet — grep is clean — so this is a forward-compatibility guarantee, not a call site.)

### 3.3 CLI wiring — `src/twocore.gleam`

The compile verbs share one axis parser (`split_axis_flags` → `Axes`, `twocore.gleam:156-230`) reached via
`with_binding` (`:359`). The minimal-blast-radius design keeps **one parser**:

1. Extend `Axes` (`:156`) with `bindings: List(bindings.BindingLang)` and `out: Option(String)` (defaults
   `[]`, `None`).
2. Add two arms to `do_split_axis_flags` (`:190`): `["--bindings", v, ..rest]` → `parse_langs(v)` into
   `Axes.bindings` (a value-less `--bindings` falls through to the existing `"--"` catch-all → fail-closed);
   `["--out", v, ..rest]` → `Some(v)`. A second `--bindings`/`--out` is rejected.
3. Change `with_binding`'s continuation to `fn(Binding, Axes, List(String))`. The three
   binding-flag-irrelevant verbs (`emit`/`to-core`/`run`) call a one-line guard
   `reject_output_flags(axes)` (Error `"--bindings/--out are only valid on to-beam-wasm"` if either is set),
   preserving fail-closed behavior; `to-beam-wasm` reads `axes.bindings`/`axes.out`.
4. Rewrite `cmd_to_beam_wasm` (`:489`) to branch on `#(out, positionals)`:

```
       out            positionals        behavior
   ─────────────  ─────────────────  ─────────────────────────────────────────────────────────
   None           [in, out.beam]     LEGACY — today's body verbatim (byte-identical); langs MUST
                                      be [] else Error "--bindings requires --out <dir>".
   None           _                  Error(usage)  — legacy still needs exactly two positionals.
   Some(dir)      [in]               FOLDER — source_to_ir → ir_to_core(binding) → core_to_beam,
                                      then bindings.emit_bindings(m, binding, beam, dir, langs).
   Some(_)        _                  Error "with --out, pass only <in.wasm>; the .beam name derives
                                      from the module atom".
```

The **legacy** arm is the current `cmd_to_beam_wasm` body unchanged (`read_bits → source_to_ir →
ir_to_core → core_to_beam → simplifile.write_bits(output)`), guaranteeing byte-identity. The **folder** arm
maps `pipeline.describe` for pipeline errors and `bindings.describe_error` for `BindingsError`, printing
`"wrote <p1>, <p2>, …"` on success. Update `usage()` (`:629`) with the two flags on the `to-beam-wasm` line.

**`--threaded` is required with `--bindings`.** The default binding is `Cell`; `describe/2` returns
`CellUnsupported` for it. So `to-beam-wasm --bindings gleam --out ./o app.wasm` (no `--threaded`) fails
non-zero with the "re-run with `--threaded`" hint — the honest-scope P8 gate, surfaced ergonomically.

---

## §4. The work (ordered, each independently buildable)

1. **Scaffold `bindings.gleam`** with `BindingLang`, `BindingsError`, and `parse_langs` (canonicalize +
   dedup + fail-closed token check). Land + unit-test `parse_langs` in isolation.
2. **`emit_bindings`** — describe-first, gather-then-write; `emit_for` dispatch; `create_directory_all`;
   `write_bits` for the `.beam` and each `GeneratedFile` (map every IO error to `WriteFailed`/`MkdirFailed`).
3. **`describe_error`** — one arm per `IfaceError` + the two IO variants, with the actionable hints.
4. **`twocore.gleam` edits** — `Axes` fields, the two `do_split_axis_flags` arms, the `with_binding`
   continuation + `reject_output_flags` guard, the `cmd_to_beam_wasm` branch table, `usage()` text.
5. **Format, build (zero warnings), run the unit suite.** Confirm the full `gleam test` corpus is still
   green and a default `to-beam-wasm in out.beam` is byte-identical.

---

## §5. Tests — `test/twocore/backend/bindings_driver_test.gleam`

Spec-cited against P6/P4/P8, **not** golden change-detectors (D8). The full *compile+call* differential is
the capstone's (P12-06); this unit proves the driver contract:

- **`parse_langs` (P6):** `"gleam,erlang,elixir"` → all three in canonical order; `"elixir,gleam"` →
  `[Gleam, Elixir]` (re-ordered); `"gleam,gleam"` → `[Gleam]` (deduped); `""` and `"rust"` → `Error`.
- **Default-off byte-identity (P4/P6 hard req):** `run(["to-beam-wasm", wasm, out])` writes bytes
  **equal** to `pipeline.core_to_beam(pipeline.ir_to_core(m, safe()), m.name)` and creates **no** other
  file / directory. `describe/2` is never reached.
- **Fail-closed routing (P6):** `--bindings gleam` without `--out` → `Error` naming `--out`;
  `--out d in extra` → `Error` (too many positionals); `--bindings gleam --out d in extra` → `Error`;
  `--bindings foo` → `Error` from `parse_langs`; `emit --bindings gleam …` → `Error`
  (`reject_output_flags`). Each exits non-zero via the existing `halt(1)` path.
- **Honest-scope gates (P8):** `--bindings gleam --out d` (default Cell) on any module → the CLI surfaces
  `Rejected(CellUnsupported)` with the `--threaded` hint and **writes nothing** (assert `d` absent/empty);
  a `--threaded` build of an **import-bearing** fixture → `Rejected(ImportBearingUnsupported)`, nothing
  written. (Both assert *no partial output* — describe runs before any write.)
- **Folder emission + `.beam` non-perturbation (P4/P6):** for a real **threaded, export-only** `.wasm`,
  `run(["to-beam-wasm","--threaded","--bindings","gleam,erlang","--out",tmp, wasm])` → `Ok`; assert
  `<tmp>/<m.name>.beam` exists and its bytes **equal** the plain (no-bindings) build of the same
  module+binding (bindings do not change the `.beam`); the binding files exist at the emitters'
  `GeneratedFile.path`s; each file's content **equals** `emit_<lang>(describe(m, binding))` (composition,
  not a frozen string). *(Requires the sibling emitter bodies; where P12-02/03/04 are still stubs, this
  case is skipped-with-category until they land — the capstone owns the end-to-end call.)*
- **Determinism (P6):** two `emit_bindings` runs over the same input → identical file bytes and identical
  returned path order (no timestamps, canonical lang order, path-sorted).

---

## §6. Definition of Done ([`../03-phase-workflow.md`](../03-phase-workflow.md) §9, per unit)

1. Spec-cited tests above pass (parse/routing/fail-closed/byte-identity/determinism), each asserting the
   *defined* P4/P6/P8 behavior, not current output.
2. `///` doc comments on every public function in `bindings.gleam` and every new/changed `twocore.gleam`
   function — contract, params (meaning/ranges), `Ok`/`Error` semantics, failure modes.
3. `gleam format --check src test` clean.
4. `gleam build` with zero warnings.
5. The unit suite passes; the full `gleam test` corpus stays green; default `to-beam-wasm` is
   byte-identical and WASM conformance is unchanged (this unit adds no default-path code).

---

## §7. What it leaves (handoff)

- **To P12-06 (capstone):** a stable, tested CLI + a single driver seam `bindings.emit_bindings`. The
  capstone hangs the per-language **compile+call differential** off it — generate via this driver, invoke
  the real toolchain (`gleam build`/`erlc`/`elixirc`) on the emitted files, call an export, and assert the
  native result + trap match the in-process pipeline oracle (Elixir best-effort, skip-if-absent).
- **To the emitters (P12-02/03/04):** the driver treats each `emit_<lang>` as a black box returning
  `List(GeneratedFile)` — it prefixes `out_dir` onto each `path` and writes verbatim, so an emitter that
  needs an extra `.erl` catch shim just returns it as a second `GeneratedFile` (no driver change).
- **Deferred (P8, unchanged here):** Cell/process-wrapped bindings and an import-provider surface remain
  CLI-rejected; when they land, the `Rejected(_)` arm of `describe_error` and the branch table are the
  extension points.
