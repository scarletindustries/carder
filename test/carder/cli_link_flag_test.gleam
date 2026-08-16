//// Phase 11 · P11-04 — CLI tests for the `--link` flag on the **build** verbs.
////
//// These drive the subcommand dispatcher (`carder.run/1`) exactly as `main` does, proving the
//// R13/O6 contract against the REAL pipeline + file IO:
////   - `--link` is scoped to a verb that WRITES a `.beam` (R13): `to-beam`/`build` accept it,
////     and every other compile verb (`emit`/`to-core`/`to-erl`/`run`) rejects it fail-closed, so
////     the flag can never silently no-op;
////   - `--link` ABSENT ⇒ the emitted `.beam` is BYTE-IDENTICAL to the current non-linked pipeline
////     (O6 — the default path is untouched), proven against `pipeline.cmod_to_beam` over the SAME
////     `cli.resolve_binding`-derived binding the CLI uses;
////   - `--link` PRESENT on a simple import-free tier-P module produces ONE loadable self-contained
////     `.beam` whose export returns the SAME spec-correct value as the non-linked build (O5).
//// Full corpus byte-identity + the bare-node proof are the capstone's (P11-06); these are the
//// wiring-level guarantees.
////
//// Since the WebAssembly frontend left carder, the `--link` semantics live on the IR-entry build
//// verbs, so these are driven from the `.ir` corpus (`add.ir` is byte-for-byte equivalent input
//// to the `add.wasm` these originally used).

import carder
import carder/cli
import carder/pipeline
import carder/runtime/profiles
import gleam/option
import gleam/string
import simplifile

/// The 35-program `.ir` corpus (generated from the conformance `.wasm` programs).
const corpus = "test/carder/ir/corpus"

/// The hand-written `.ir` fixtures.
const golden = "test/carder/ir/golden"

/// The value/timing output of `exec` is `"<value>\n<timing>"`; take the value line.
fn first_line(s: String) -> String {
  case string.split_once(s, "\n") {
    Ok(#(head, _)) -> head
    Error(_) -> s
  }
}

// ═══════════════════════ 1. `--link` is scoped to the build verbs (R13) ═══════════════════════

/// R13: `--link` is honored ONLY on a verb that writes a `.beam`. On every other compile verb a
/// `--link` token is rejected fail-closed, short-circuiting BEFORE any file IO, so the flag
/// cannot silently no-op on a verb whose output it could not possibly affect.
pub fn link_flag_rejected_on_non_link_verbs_test() {
  let ir_file = golden <> "/add.ir"

  let assert Error(m1) = carder.run(["emit", "--link", ir_file])
  assert string.contains(m1, "--link")
  let assert Error(m2) = carder.run(["to-core", "--link", ir_file])
  assert string.contains(m2, "--link")
  let assert Error(m3) = carder.run(["to-erl", "--link", ir_file])
  assert string.contains(m3, "--link")
  let assert Error(m4) =
    carder.run(["run", "--link", corpus <> "/add.ir", "add", "3", "5"])
  assert string.contains(m4, "--link")
}

/// The other half of R13, and the INVERSION of the pre-split behaviour: now that `to-beam`/`build`
/// are the IR-entry build verbs, they ACCEPT `--link` — it reaches the linker rather than being
/// refused. Proven positively (a linked `.beam` is written) rather than by absence of an error, so
/// a future regression that turned acceptance back into a silent no-op would still fail here.
pub fn link_flag_accepted_on_build_verbs_test() {
  let src = corpus <> "/add.ir"
  let a = "build/link_accept_to_beam.beam"
  let b = "build/link_accept_build.beam"

  let assert Ok(m1) = carder.run(["to-beam", "--unsafe", "--link", src, a])
  assert string.contains(m1, "wrote")
  let assert Ok(beam_a) = simplifile.read_bits(a)
  assert beam_a != <<>>

  // `build` is the documented alias — the same dispatcher arm, so it accepts `--link` too.
  let assert Ok(m2) = carder.run(["build", "--unsafe", "--link", src, b])
  assert string.contains(m2, "wrote")
  let assert Ok(beam_b) = simplifile.read_bits(b)
  assert beam_a == beam_b

  let _ = simplifile.delete(a)
  let _ = simplifile.delete(b)
}

/// The `--link` gate itself is still fail-closed (R14): an import-bearing module cannot be linked,
/// because a bare node has no providers for its external imports. `hostimport.ir` declares a host
/// func import, so the build verb refuses it — the gate runs BEFORE any `.beam` is written.
pub fn link_rejects_import_bearing_module_test() {
  let out = "build/link_reject_hostimport.beam"
  let _ = simplifile.delete(out)
  let assert Error(msg) =
    carder.run([
      "to-beam",
      "--unsafe",
      "--link",
      corpus <> "/hostimport.ir",
      out,
    ])
  assert string.contains(msg, "--link")
  assert string.contains(msg, "import")
  // fail-closed: the gate ran before any IO, so NO .beam was written.
  let assert Error(_) = simplifile.read_bits(out)
}

// ═══════════════════════ 2. default off ⇒ byte-identical (O6) ═══════════════════════

/// O6: with `--link` ABSENT, `to-beam` writes a `.beam` whose bytes EQUAL the pre-existing
/// non-linked pipeline output for the same input + binding. The oracle re-runs the exact default
/// path (`parse_ir → ir_to_cmod → cmod_to_beam`) over the SAME binding the CLI resolves via
/// `cli.resolve_binding`, so this proves the non-linked branch is untouched — not merely self-
/// consistent. (Full corpus × mode × tier byte-identity is P11-06's.)
pub fn default_off_byte_identical_test() {
  let src = corpus <> "/add.ir"
  let out = "build/link_default_add.beam"

  let assert Ok(msg) = carder.run(["to-beam", src, out])
  assert string.contains(msg, "wrote")
  let assert Ok(cli_beam) = simplifile.read_bits(out)

  // Oracle: the non-linked default path, over the identical resolved binding.
  let assert Ok(text) = simplifile.read(src)
  let assert Ok(m) = pipeline.parse_ir(text)
  let assert Ok(binding) =
    cli.resolve_binding(
      profiles.safe(),
      False,
      False,
      option.None,
      option.None,
      option.None,
    )
  let assert Ok(cmod) = pipeline.ir_to_cmod(m, binding)
  let assert Ok(oracle_beam) = pipeline.cmod_to_beam(cmod)

  assert cli_beam == oracle_beam
  let _ = simplifile.delete(out)
}

// ═══════════════════════ 3. the positive `--link` path (O5) ═══════════════════════

/// O5: `to-beam --unsafe --link` on a simple import-free tier-P module (`add.ir`) writes ONE
/// self-contained `.beam`, and loading + invoking it returns the SAME spec-correct value as the
/// non-linked build (`add(3, 5) == 8`). `exec` reads the module name from the `.beam`,
/// instantiates (seeding the per-instance cell — R6, spawned in its own process), and invokes —
/// the whole self-contained artifact runs. This is the CLI-driven smoke; the bare-node isolation
/// proof is P11-06/P11-05.
///
/// **Why `--unsafe` (MeterOff) and not the default Safe binding:** the default Safe pipeline
/// inserts fuel metering (`ir_lower` → `charge` → `rt_meter`), whose closure reaches
/// `gleam@dynamic@decode:decode_int/1` via a fun-capture. The P11-03 linker currently REWRITES
/// that capture to a local mangled call but does NOT pull the capture's target DEF into the merge,
/// so a linked Safe `add` traps `undef` at runtime on the first `charge`. That is a P11-03 linker
/// reachability gap (its own tests exercise only `emit_core`-direct closures, never the
/// `ir_lower`-inserted metering path) — a signal for P11-06/P11-03, NOT a P11-04 CLI/gate defect.
/// `--unsafe` sets `MeterOff` (no `charge`, so the metering closure is never emitted), keeping this
/// a genuine tier-P (`Paged`), import-free linked build that exercises the full CLI `--link` path.
pub fn linked_build_smoke_test() {
  let src = corpus <> "/add.ir"
  let linked = "build/link_smoke_add.beam"
  let unlinked = "build/link_smoke_add_plain.beam"

  // linked build: one self-contained .beam, written.
  let assert Ok(lmsg) =
    carder.run(["to-beam", "--unsafe", "--link", src, linked])
  assert string.contains(lmsg, "wrote")
  let assert Ok(lbeam) = simplifile.read_bits(linked)
  assert lbeam != <<>>

  // non-linked build of the same input — the oracle for the returned value.
  let assert Ok(_) = carder.run(["to-beam", "--unsafe", src, unlinked])

  // exec both: the linked artifact returns the same spec-correct value as the non-linked one.
  let assert Ok(linked_out) = carder.run(["exec", linked, "add", "3", "5"])
  let assert Ok(plain_out) = carder.run(["exec", unlinked, "add", "3", "5"])
  assert first_line(linked_out) == "8"
  assert first_line(linked_out) == first_line(plain_out)

  let _ = simplifile.delete(linked)
  let _ = simplifile.delete(unlinked)
}
