//// Phase 11 · P11-04 — CLI tests for the `--link` flag on `to-beam-wasm`.
////
//// These drive the subcommand dispatcher (`twocore.run/1`) exactly as `main` does, proving the
//// R13/O6 contract against the REAL pipeline + file IO:
////   - `--link` is scoped to `to-beam-wasm` (R13): it is rejected fail-closed on every other
////     compile verb and on the `.core`-input `to-beam`/`build` verbs, so it can never silently
////     no-op;
////   - `--link` ABSENT ⇒ the emitted `.beam` is BYTE-IDENTICAL to the current non-linked pipeline
////     (O6 — the default path is untouched), proven against `pipeline.core_to_beam` over the SAME
////     `resolve_binding`-derived binding the CLI uses;
////   - `--link` PRESENT on a simple import-free tier-P module produces ONE loadable self-contained
////     `.beam` whose export returns the SAME spec-correct value as the non-linked build (O5).
//// Full corpus byte-identity + the bare-node proof are the capstone's (P11-06); these are the
//// wiring-level guarantees.

import gleam/option
import gleam/string
import simplifile
import twocore
import twocore/pipeline
import twocore/runtime/profiles

const corpus = "test/twocore/conformance/corpus"

const golden = "test/twocore/ir/golden"

/// The `.core`-style timing/value output of `exec` is `"<value>\n<timing>"`; take the value line.
fn first_line(s: String) -> String {
  case string.split_once(s, "\n") {
    Ok(#(head, _)) -> head
    Error(_) -> s
  }
}

// ═══════════════════════ 1. `--link` is scoped to `to-beam-wasm` (R13) ═══════════════════════

/// R13: `--link` is recognized ONLY on `to-beam-wasm`. On every other compile verb — and on the
/// `.core`-input `to-beam` (deferred, it carries no `Binding` to gate) — a `--link` token is
/// rejected fail-closed, short-circuiting BEFORE any file IO, so the flag cannot silently no-op.
pub fn link_flag_rejected_on_non_link_verbs_test() {
  let wasm = corpus <> "/add.wasm"
  let ir_file = golden <> "/add.ir"

  let assert Error(m1) = twocore.run(["emit", "--link", ir_file])
  assert string.contains(m1, "--link")
  let assert Error(m2) = twocore.run(["to-core", "--link", ir_file])
  assert string.contains(m2, "--link")
  let assert Error(m3) = twocore.run(["run", "--link", wasm, "add", "2", "3"])
  assert string.contains(m3, "--link")
  // R13 deferral: the .core-input verb has no binding/profile to gate on.
  let assert Error(m4) = twocore.run(["to-beam", "--link", "x.core"])
  assert string.contains(m4, "--link")
}

// ═══════════════════════ 2. default off ⇒ byte-identical (O6) ═══════════════════════

/// O6: with `--link` ABSENT, `to-beam-wasm` writes a `.beam` whose bytes EQUAL the pre-existing
/// non-linked pipeline output for the same source + binding. The oracle re-runs the exact default
/// path (`source_to_ir → ir_to_core → core_to_beam`) over the SAME binding the CLI resolves via
/// `resolve_binding`, so this proves the non-linked branch is untouched — not merely self-
/// consistent. (Full corpus × mode × tier byte-identity is P11-06's.)
pub fn default_off_byte_identical_test() {
  let wasm = corpus <> "/add.wasm"
  let out = "build/link_default_add.beam"

  let assert Ok(msg) = twocore.run(["to-beam-wasm", wasm, out])
  assert string.contains(msg, "wrote")
  let assert Ok(cli_beam) = simplifile.read_bits(out)

  // Oracle: the non-linked default path, over the identical resolved binding.
  let assert Ok(bytes) = simplifile.read_bits(wasm)
  let assert Ok(m) = pipeline.source_to_ir(bytes)
  let assert Ok(binding) =
    twocore.resolve_binding(
      profiles.safe(),
      False,
      False,
      option.None,
      option.None,
      option.None,
    )
  let assert Ok(core) = pipeline.ir_to_core(m, binding)
  let assert Ok(oracle_beam) = pipeline.core_to_beam(core, m.name)

  assert cli_beam == oracle_beam
  let _ = simplifile.delete(out)
}

// ═══════════════════════ 3. the positive `--link` path (O5) ═══════════════════════

/// O5: `to-beam-wasm --unsafe --link` on a simple import-free tier-P module (`add.wasm`) writes
/// ONE self-contained `.beam`, and loading + invoking it returns the SAME spec-correct value as
/// the non-linked build (`add(2, 3) == 5`). `exec` reads the module name from the `.beam`,
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
  let wasm = corpus <> "/add.wasm"
  let linked = "build/link_smoke_add.beam"
  let unlinked = "build/link_smoke_add_plain.beam"

  // linked build: one self-contained .beam, written.
  let assert Ok(lmsg) =
    twocore.run(["to-beam-wasm", "--unsafe", "--link", wasm, linked])
  assert string.contains(lmsg, "wrote")
  let assert Ok(lbeam) = simplifile.read_bits(linked)
  assert lbeam != <<>>

  // non-linked build of the same source — the oracle for the returned value.
  let assert Ok(_) = twocore.run(["to-beam-wasm", "--unsafe", wasm, unlinked])

  // exec both: the linked artifact returns the same spec-correct value as the non-linked one.
  let assert Ok(linked_out) = twocore.run(["exec", linked, "add", "2", "3"])
  let assert Ok(plain_out) = twocore.run(["exec", unlinked, "add", "2", "3"])
  assert first_line(linked_out) == "5"
  assert first_line(linked_out) == first_line(plain_out)

  let _ = simplifile.delete(linked)
  let _ = simplifile.delete(unlinked)
}
