//// Unit P4-11 — PROOF 1: the runs-anywhere HEADLINE (§C, G1/G3/G6 — the phase's proof-of-goal).
////
//// The platform's high-level pitch — *"no OTP, no NIF, runs-anywhere, provably unable to take over
//// the VM"* — is the tier-P **`portable`** posture: `Threaded` instance state (the state travels as
//// a purely-functional record threaded through generated code — no process-dictionary instance
//// cell), `Paged` linear memory (immutable BEAM binaries, no native code), `bif` numerics (pure
//// Gleam over BEAM bignums), the fail-closed **Safe** policy. This suite establishes it the two
//// ways the headline needs — because "it ran" and "it used nothing native" are DIFFERENT claims:
////
////   (a) **Grep-verified (static).** Emit the `profiles.portable()` build of state-heavy corpus
////       modules (memory + globals + a table) and grep the emitted `.core` — the one artifact that
////       names every runtime module the generated code links (the seam emits only fixed
////       `carder@runtime@*` atoms, D3a) — asserting ZERO native/unsafe primitives
////       (`atomics`/`ets`/`persistent_term`/NIF) EVERYWHERE and ZERO `rt_state` pdict *instance
////       cell* seam (`'seed'`/`'mem_get'`/`'global_get'`), which `Threaded` genuinely eliminates.
////   (b) **Executed (dynamic).** Compile the WHOLE acceptance corpus under the REAL
////       `profiles.portable()` profile (not a test-capped variant — the exact posture a user gets)
////       and run it through `load → instantiate → invoke` on a bare BEAM, asserting each program is
////       spec-correct AND byte-identical to the `cell`/`paged` oracle.
////
//// ## The one honest caveat (stated, not hidden — §C, keystone A.3, P4)
////
//// The grep's zero-set is the NATIVE/UNSAFE primitives + the pdict *instance-state* cell — it does
//// NOT assert zero pdict. A Safe `portable` build MANDATORILY keeps `MeterFuel` (the F5 fail-closed
//// CPU bound — `MeterOff`-under-Safe is rejected), so its `.core` DOES call `rt_meter`
//// (`seed_fuel`/`charge`) and seed the `rt_host` policy cell — each a single PROCESS-LOCAL pdict
//// value: node-safe, cannot escape, cannot crash the node, present on every BEAM. The project
//// taxonomy classifies pdict as tier-O (node-safe), and Safe permits tier P or O, never N — so
//// these overlays legitimately remain. The "runs on a bare BEAM, provably unable to take over the
//// VM" property is about NO NATIVE CODE and NO CRASHABLE INSTANCE STATE, which `portable` satisfies
//// in full. This suite asserts those overlays are PRESENT (> 0) to keep the headline proof honest.
////
//// The relationship to unit 09: unit 09's `tier/runs_anywhere_test` owns the fine-grained grep over
//// the `combos.portable` (capped) test binding; THIS capstone suite re-establishes the headline as
//// the consolidated proof-of-goal over the REAL, shipped `profiles.portable()` AND adds the
//// executed byte-identity half — the phase's proof-of-goal, not a change-detector. The two modules
//// therefore make DIFFERENT claims and share no `*_test` name; both live under `test/carder/tier/`.
////
//// ## Why this file lives under `tier/` (the frontend split)
////
//// It was previously filed under the WebAssembly conformance tree, but it is not a spec-suite test:
//// it never reads a `.wast` fixture and never judges a spec assertion. It greps the emitted `.core`
//// of `profiles.portable()` builds for banned RUNTIME modules and runs the corpus against the
//// `cell`/`paged` oracle — a BACKEND / runtime-layering claim, which is exactly what `tier/` owns.
//// The conformance suite left with the WebAssembly frontend (to the `scribbler` repo); this proof
//// stayed, because everything it audits (`ir_to_core`, the tier lattice, the emitted module
//// boundary) is carder's. Its corpus input is now `.ir` SOURCE TEXT — see `combos.corpus_dir`.
////
//// Spec anchors: keystone §B.1 (the seam emits fixed `carder@runtime@*` atoms); WebAssembly spec
//// §7 *Embedding* (the memory-safety invariant holds by construction when the whole memory
//// subsystem is immutable BEAM binaries); exec/instructions (bounds/traps) cited per corpus program
//// inside each `corpus/*.expected`.

import carder/harness/driver
import carder/pipeline
import carder/runtime/instance.{Binding, Nif}
import carder/runtime/profiles
import carder/tier/combos
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Compile corpus `name` to `.core` text under the REAL `profiles.portable()` profile — the exact
/// artifact `build_beam` compiles and the grep audits. The `portable` build links only pure-BEAM
/// `carder@runtime@*` modules; the emitted text names every one, so a grep of it is an exhaustive
/// audit of the module boundary a portable instance can cross. `let assert` here documents that a
/// well-formed corpus program always compiles under `portable` (a failure is a real regression).
///
/// The corpus fixture is `.ir` SOURCE TEXT (the wasm frontend moved to `scribbler`), so the front
/// half is `driver.parse` (UTF-8 decode + `pipeline.parse_ir`); the audited half — `ir_to_core`
/// under `profiles.portable()` — is untouched, and each `.ir` was measured to produce the
/// byte-identical `.beam` its `.wasm` did.
fn portable_core(name: String) -> String {
  let assert Ok(bytes) = combos.read_ir(name)
  let assert Ok(m) = driver.parse(bytes)
  let assert Ok(core) = pipeline.ir_to_core(m, profiles.portable())
  core
}

// ─────────────────────────── PROOF 1 (a): the grep — no native code, no instance cell ───────────────────────────

/// PROOF 1a (G6 — the "no OTP, no NIF" static half). Across every state-heavy corpus module
/// (`mem` = memory, `gvar` = mutable globals, `callind` = a table + indirect dispatch, `memgrow` =
/// `memory.grow`), the `portable` `.core` links ZERO native / OTP-native / native-code state: it
/// names no module containing `atomics`, `ets`, `persistent_term`, or a NIF loader. This is the
/// structural cross-check behind "runs on a bare BEAM": nothing native is even reachable.
pub fn portable_core_links_zero_native_state_test() {
  let failures =
    list.flat_map(["mem", "gvar", "callind", "memgrow"], fn(name) {
      let core = portable_core(name)
      let check = fn(tok) {
        case combos.count_occurrences(core, tok) {
          0 -> []
          n -> [
            name
            <> " links native primitive '"
            <> tok
            <> "' × "
            <> int.to_string(n),
          ]
        }
      }
      list.flatten([
        check("atomics"),
        check("ets"),
        check("persistent_term"),
        check("nif"),
        check("load_nif"),
        check("erlang_nif"),
      ])
    })
  assert failures == []
}

/// PROOF 1a (G1 — no crashable instance state). No process-dictionary INSTANCE-STATE cell: the
/// `Threaded` build replaces the `rt_state` pdict cell (`'seed'`/`'mem_get'`/`'mem_put'`/
/// `'global_get'`/`'global_set'`) with a value threaded through generated code, so those quoted
/// atoms are ABSENT from every state-heavy portable `.core`. (The quoted-atom grep is precise:
/// `'seed'` is 0 even though `'seed_fuel'` — the tier-O fuel overlay — is present, because the
/// closing quote after `seed` never matches inside `seed_fuel`.)
pub fn portable_core_has_no_instance_cell_seam_test() {
  let cell_seam = [
    "'seed'", "'mem_get'", "'mem_put'", "'global_get'", "'global_set'",
  ]
  let failures =
    list.flat_map(["mem", "gvar", "callind", "memgrow"], fn(name) {
      let core = portable_core(name)
      list.flat_map(cell_seam, fn(tok) {
        case combos.count_occurrences(core, tok) {
          0 -> []
          n -> [
            name
            <> " emits pdict instance-cell seam '"
            <> tok
            <> "' × "
            <> int.to_string(n),
          ]
        }
      })
    })
  assert failures == []
}

/// PROOF 1a (non-vacuity). The greps above are a REAL audit, not vacuously-green string matches:
/// the `portable` build DOES route state through the threaded record — `mem` names the threaded
/// memory family (`'t_load'`/`'t_store'`), `gvar` names the threaded global accessor
/// (`'t_global_get'`), and every build names `rt_state` (the `fresh` + threaded accessors). So the
/// "no cell seam" result is a REPLACEMENT (the record-threading build), not an absence of state ops.
pub fn portable_core_uses_threaded_state_families_test() {
  let mem = portable_core("mem")
  assert combos.count_occurrences(mem, "'t_load'") > 0
  assert combos.count_occurrences(mem, "'t_store'") > 0
  assert combos.count_occurrences(mem, "rt_state") > 0

  let gvar = portable_core("gvar")
  assert combos.count_occurrences(gvar, "'t_global_get'") > 0
  assert combos.count_occurrences(gvar, "rt_state") > 0
}

/// PROOF 1a (the honest caveat, P4). The Safe `portable` build MANDATORILY keeps `MeterFuel` (the
/// F5 CPU bound), so its `.core` DOES call the node-safe, process-local tier-O overlays — `rt_meter`
/// (`seed_fuel`/`charge`) and the `rt_host` policy cell. This asserts they are PRESENT (> 0), so the
/// runs-anywhere zero-set is documented as "native/unsafe primitives + the instance cell", NOT a
/// strict-zero-pdict claim: `MeterOff`-under-Safe is rejected because it would drop the CPU bound.
/// Stating this in an assertion keeps the headline proof TRUE rather than overstated.
pub fn portable_core_keeps_node_safe_tier_o_overlays_test() {
  let core = portable_core("mem")
  // The Safe CPU-fuel counter is baked in (seed at instantiate + charge sites) — node-safe pdict.
  assert combos.count_occurrences(core, "rt_meter") > 0
  assert combos.count_occurrences(core, "seed_fuel") > 0
  // The host-policy cell is present (deny-all under Safe) — node-safe pdict.
  assert combos.count_occurrences(core, "rt_host") > 0
}

/// PROOF 1a (the grep can see what it forbids). A `ceiling`/`atomics` `.core` DOES name the tier-O
/// `rt_mem_atomics` module — proving the zero-count above is a REAL audit (the grep sees the native/
/// O(1) backend WHEN it is linked), not a match that would pass on any input. The atomics build is
/// exactly what `portable` deliberately excludes.
pub fn atomics_build_names_the_tier_o_module_test() {
  let assert Ok(bytes) = combos.read_ir("mem")
  let assert Ok(m) = driver.parse(bytes)
  let assert Ok(core) =
    pipeline.ir_to_core(m, combos.binding_for(combos.cell_atomics))
  assert combos.count_occurrences(core, "rt_mem_atomics") > 0
  assert combos.count_occurrences(core, "carder@runtime@rt_mem_atomics") > 0
}

// ─────────────────────────── PROOF 1 (b): executed — byte-identical to the cell/paged oracle ───────────────────────────

/// PROOF 1b (G3 — the "it ran" dynamic half, THE HEADLINE). The WHOLE acceptance corpus, compiled
/// under the REAL `profiles.portable()` profile and run through `load → instantiate → invoke` on a
/// bare BEAM (no `atomics`/`ets`/NIF loaded at all), is (1) spec-correct against each program's
/// `.expected` and (2) BYTE-IDENTICAL (raw bit pattern, D5/D7) to the `cell`/`paged` oracle
/// (`profiles.safe()`). This is the executed headline: the runs-anywhere build produces the same
/// answers, values and traps alike, as the tier-O reference — the trust-tier axis is proven
/// correctness-neutral for the shipped `portable` posture. `sum_to(100000)` (a constant-space loop
/// under `Threaded`, G4) and the memory/global/table programs are all in this corpus, so this
/// re-confirms unit 09's constant-space property holds in the real `portable` composition.
pub fn portable_runs_corpus_byte_identical_to_oracle_test() {
  let portable_d = driver.pipeline_with(profiles.portable())
  let oracle_d = driver.pipeline_with(profiles.safe())

  let failures =
    list.flat_map(combos.corpus_programs, fn(name) {
      let #(p_outs, p_fails) = combos.evaluate(portable_d, name)
      let #(o_outs, _) = combos.evaluate(oracle_d, name)
      list.flatten([
        // (1) portable is spec-correct against `.expected`.
        list.map(p_fails, fn(f) { "portable spec-incorrect: " <> f }),
        // (2) portable is byte-identical to the cell/paged oracle.
        case p_outs == o_outs {
          True -> []
          False -> [
            name
            <> " [portable ≢ cell/paged oracle]: "
            <> string.inspect(o_outs)
            <> " vs "
            <> string.inspect(p_outs),
          ]
        },
      ])
    })
  assert failures == []
}

// ─────────────────────────── PROOF 4 (checkpoint): the two headline profiles compose fail-closed ───────────────────────────

/// PROOF 4 checkpoint (G3/G6). The capstone-level statement of the composed axis space's
/// fail-closed status for the two HEADLINE profiles (the exhaustive per-field linker tests live in
/// unit 07's `profiles_test`; this is the end-to-end proof-of-goal checkpoint, not a re-derivation):
///   - `portable()` (Safe, tier-P on every axis) validates `Ok` — the runs-anywhere build links;
///   - an uncapped `ceiling()` (Unsafe + `Atomics`) is REJECTED `AtomicsCapRequired` (P6 — atomics
///     needs a bounded reservation cap; no silent 4 GiB pre-allocation, no silent `paged` fallback);
///   - a hand-built `Safe + Nif` is REJECTED `SafeForbidsNif` (G6 — tier-N runs custom C that can
///     crash the node, so it is Unsafe-only; there is no unsafe-by-omission path).
pub fn headline_profiles_compose_fail_closed_test() {
  // The runs-anywhere build is admissible.
  assert result.is_ok(profiles.validate_binding(profiles.portable()))
  // The uncapped perf ceiling fails closed until a bounded cap is supplied (P6/§C).
  assert profiles.validate_binding(profiles.ceiling())
    == Error(profiles.AtomicsCapRequired)
  // Safe forbids the tier-N native memory, fail-closed (G6).
  assert profiles.validate_binding(Binding(..profiles.safe(), mem_tier: Nif))
    == Error(profiles.SafeForbidsNif)
}

// ─────────────────────────── P5-12 PROOF 4: runs-anywhere RE-CONFIRMED for the new surface (H3/H6) ───────────────────────────

/// The Phase-5 new-surface programs the runs-anywhere property must be RE-CONFIRMED over (capstone
/// §E): `reftab` (a reference-typed table + `ref.*` + `call_indirect`), `bulkmem` (bulk memory
/// fill/copy/init + a passive segment), `multimem` (two memories + a cross-memory copy). Phase 4
/// proved the tier-P `portable` build runs the Phase-4 corpus on a bare BEAM; Phase 5 GREW the
/// surface, so these new nodes must ALSO route through the purely-functional record with no native
/// code and no crashable instance cell — else the runs-anywhere headline no longer covers the whole
/// engine. Checked in as `corpus/<name>.ir` (capstone-owned, §H — originally authored as
/// `.wat`; the `.ir` was generated from its `.wasm` by the pre-split `to-ir`).
const new_surface_programs: List(String) = ["reftab", "bulkmem", "multimem"]

/// PROOF 4a (new surface, G6 — no native code). The `portable` `.core` of every new-surface program
/// links ZERO native / OTP-native state: it names no module containing `atomics`, `ets`,
/// `persistent_term`, or a NIF loader. The reference value model, the bulk ops, the passive-segment
/// drop state, and the memories vector are all pure-BEAM `carder@runtime@*` code — nothing native
/// is even reachable, so a bounds/type bug's worst case is a wrong/missing trap or a node-safe
/// process crash, never a host escape (spec §7 embedding; H6).
pub fn portable_new_surface_links_zero_native_state_test() {
  let failures =
    list.flat_map(new_surface_programs, fn(name) {
      let core = portable_core(name)
      let check = fn(tok) {
        case combos.count_occurrences(core, tok) {
          0 -> []
          n -> [
            name
            <> " links native primitive '"
            <> tok
            <> "' × "
            <> int.to_string(n),
          ]
        }
      }
      list.flatten([
        check("atomics"),
        check("ets"),
        check("persistent_term"),
        check("nif"),
        check("load_nif"),
        check("erlang_nif"),
      ])
    })
  assert failures == []
}

/// PROOF 4a (new surface, G1 — no crashable instance cell). No process-dictionary INSTANCE-STATE
/// seam in any new-surface `portable` `.core`: the `Threaded` build threads the memories/tables
/// vector + the passive drop-state through the record, never the `rt_state` pdict cell
/// (`'seed'`/`'mem_get'`/`'mem_put'`/`'global_get'`/`'global_set'`). So the whole new surface carries
/// the SAME "no crashable state" property Phase 4 proved for the base corpus.
pub fn portable_new_surface_has_no_instance_cell_seam_test() {
  let cell_seam = [
    "'seed'", "'mem_get'", "'mem_put'", "'global_get'", "'global_set'",
  ]
  let failures =
    list.flat_map(new_surface_programs, fn(name) {
      let core = portable_core(name)
      list.flat_map(cell_seam, fn(tok) {
        case combos.count_occurrences(core, tok) {
          0 -> []
          n -> [
            name
            <> " emits pdict instance-cell seam '"
            <> tok
            <> "' × "
            <> int.to_string(n),
          ]
        }
      })
    })
  assert failures == []
}

/// PROOF 4a (new surface, non-vacuity). The greps above are a REAL audit, not vacuously-green: the
/// `portable` build DOES route the new nodes through the THREADED runtime families (a replacement,
/// not an absence). `reftab` names the threaded reference-table accessors (`'t_get'`,
/// `'t_call_indirect'`, `'t_init_elem'`); `bulkmem` names the threaded bulk-memory family
/// (`'t_copy'`, `'t_init'`); `multimem` routes the second memory through the memory-index `_at`
/// accessors (`'t_load_at'`, `'t_store_at'`) and holds the memories vector in the record (`rt_state`
/// present). If units 07/08 renamed these, this test's tokens must follow — the seam is named, not
/// guessed.
pub fn portable_new_surface_uses_threaded_families_test() {
  let reftab = portable_core("reftab")
  assert combos.count_occurrences(reftab, "'t_get'") > 0
  assert combos.count_occurrences(reftab, "'t_call_indirect'") > 0
  assert combos.count_occurrences(reftab, "'t_init_elem'") > 0
  assert combos.count_occurrences(reftab, "rt_ref") > 0

  let bulkmem = portable_core("bulkmem")
  assert combos.count_occurrences(bulkmem, "'t_copy'") > 0
  assert combos.count_occurrences(bulkmem, "'t_init'") > 0

  let multimem = portable_core("multimem")
  assert combos.count_occurrences(multimem, "'t_load_at'") > 0
  assert combos.count_occurrences(multimem, "'t_store_at'") > 0
  assert combos.count_occurrences(multimem, "rt_state") > 0
}

/// PROOF 4b (new surface, EXECUTED — the dynamic half). Every new-surface program, compiled under
/// the REAL `profiles.portable()` profile and run through `load → instantiate → invoke` on a bare
/// BEAM, is (1) spec-correct against its `.expected` and (2) BYTE-IDENTICAL (raw bit pattern) to the
/// `cell`/`paged` oracle (`profiles.safe()`), values AND traps alike. This re-confirms that the
/// reference value model, the bulk ops, the passive-segment drop state, and the memories vector all
/// thread through the purely-functional record without a native backend and without a crashable
/// pdict cell — the runs-anywhere property now covers the WHOLE engine (spec §7 embedding).
pub fn portable_new_surface_runs_byte_identical_to_oracle_test() {
  let portable_d = driver.pipeline_with(profiles.portable())
  let oracle_d = driver.pipeline_with(profiles.safe())

  let failures =
    list.flat_map(new_surface_programs, fn(name) {
      let #(p_outs, p_fails) = combos.evaluate(portable_d, name)
      let #(o_outs, _) = combos.evaluate(oracle_d, name)
      list.flatten([
        list.map(p_fails, fn(f) { "portable spec-incorrect: " <> f }),
        case p_outs == o_outs {
          True -> []
          False -> [
            name
            <> " [portable ≢ cell/paged oracle]: "
            <> string.inspect(o_outs)
            <> " vs "
            <> string.inspect(p_outs),
          ]
        },
      ])
    })
  assert failures == []
}

// ─────────────── P6-11 PROOF 5: runs-anywhere RE-CONFIRMED for the SIMD + memory64 surface (I3/I6) ───────────────

/// The Phase-6 new-surface programs the runs-anywhere property must be RE-CONFIRMED over (capstone
/// §F.2): the pure SIMD kernels `simddot`/`simdxform` (v128 lane ops over consts/params, NO memory —
/// the cleanest non-vacuity: `rt_simd` present, native zero), `simdmem` (the v128 memory family
/// through the immutable-binary `rt_mem` seam), and `mem64` (i64 addressing threaded through the
/// record). Phase 6 grew the surface, so these MUST also run under the tier-P `portable` build with
/// no native code and no crashable instance cell — else the runs-anywhere headline no longer covers
/// the WHOLE engine. Checked in as `corpus/<name>.ir` (capstone-owned).
const p6_surface_programs: List(String) = [
  "simddot", "simdxform", "simdmem", "mem64",
]

/// A per-instance fuel budget clear of `mem64`'s 65537-page grow (whose success-path charge is
/// `65537 * 65536` — `rt_mem.mem_grow`, R9). The memory64 RUNTIME is observed here ORTHOGONALLY to
/// the fuel meter (raised on BOTH the portable build and the oracle, so the comparison isolates the
/// state-strategy axis, not the CPU bound — the fuel bound is proven by the Phase-4 fuel suites).
const mem64_fuel: Int = 6_000_000_000

/// PROOF 5a (new surface, G6 — no native code). The `portable` `.core` of every Phase-6 kernel links
/// ZERO native / OTP-native state: `rt_simd` is a pure tier-P `bif` (v128 lane ops over 16-byte
/// binaries), `rt_mem` is immutable BEAM binaries, i64 addressing is BEAM bignums — nothing native is
/// even reachable, so a lane/bounds bug's worst case is a wrong/missing trap or a node-safe process
/// crash, never a host escape (spec §7 embedding; I6).
pub fn portable_p6_surface_links_zero_native_state_test() {
  let failures =
    list.flat_map(p6_surface_programs, fn(name) {
      let core = portable_core(name)
      let check = fn(tok) {
        case combos.count_occurrences(core, tok) {
          0 -> []
          n -> [
            name
            <> " links native primitive '"
            <> tok
            <> "' × "
            <> int.to_string(n),
          ]
        }
      }
      list.flatten([
        check("atomics"),
        check("ets"),
        check("persistent_term"),
        check("nif"),
        check("load_nif"),
        check("erlang_nif"),
      ])
    })
  assert failures == []
}

/// PROOF 5a (new surface, G1 — no crashable instance cell). No process-dictionary INSTANCE-STATE
/// seam in any Phase-6 kernel's portable `.core`: the `Threaded` build threads the memories vector
/// (`simdmem`/`mem64`) through the record, never the `rt_state` pdict cell; the pure SIMD kernels
/// touch no state at all. So the whole Phase-6 surface carries the SAME "no crashable state" property
/// Phase 4 proved for the base corpus.
pub fn portable_p6_surface_has_no_instance_cell_seam_test() {
  let cell_seam = [
    "'seed'", "'mem_get'", "'mem_put'", "'global_get'", "'global_set'",
  ]
  let failures =
    list.flat_map(p6_surface_programs, fn(name) {
      let core = portable_core(name)
      list.flat_map(cell_seam, fn(tok) {
        case combos.count_occurrences(core, tok) {
          0 -> []
          n -> [
            name
            <> " emits pdict instance-cell seam '"
            <> tok
            <> "' × "
            <> int.to_string(n),
          ]
        }
      })
    })
  assert failures == []
}

/// PROOF 5a (new surface, non-vacuity). The greps above are a REAL audit, not vacuously-green: the
/// pure SIMD kernels DO route through `rt_simd` (the tier-P `bif` lane path — a real replacement, not
/// an absence); `simdmem` ALSO names `rt_mem` (the v128 memory family routes through the
/// bounds-checked seam) + the threaded `'t_load'` head; `mem64` threads the memories vector through
/// the record (`rt_state` + `rt_mem` present). And `rt_simd` is native-free: a pure SIMD kernel's
/// portable `.core` links no native primitive at all. If P6-07/08 renamed these, the tokens follow.
pub fn portable_p6_surface_uses_pure_beam_families_test() {
  // rt_simd is the stable non-vacuity token for the pure SIMD lane path.
  assert combos.count_occurrences(portable_core("simddot"), "rt_simd") > 0
  assert combos.count_occurrences(portable_core("simdxform"), "rt_simd") > 0

  // simdmem: the v128 memory family routes lane assembly through rt_simd AND the bounds-checked
  // rt_mem seam (threaded 't_load' head), never a raw term op.
  let simdmem = portable_core("simdmem")
  assert combos.count_occurrences(simdmem, "rt_simd") > 0
  assert combos.count_occurrences(simdmem, "rt_mem") > 0
  assert combos.count_occurrences(simdmem, "'t_load'") > 0

  // mem64: i64 addressing threads the memories vector through the record (rt_state) and the seam.
  let mem64 = portable_core("mem64")
  assert combos.count_occurrences(mem64, "rt_state") > 0
  assert combos.count_occurrences(mem64, "rt_mem") > 0

  // rt_simd is native-free (tier-P bif): a pure SIMD kernel links no native primitive.
  let core = portable_core("simddot")
  assert combos.count_occurrences(core, "atomics") == 0
  assert combos.count_occurrences(core, "load_nif") == 0
  assert combos.count_occurrences(core, "persistent_term") == 0
}

/// PROOF 5b (SIMD executed — the dynamic half). Each SIMD kernel, compiled under the REAL
/// `profiles.portable()` profile and run through `load → instantiate → invoke` on a bare BEAM, is
/// (1) spec-correct against its `.expected` and (2) BYTE-IDENTICAL (raw bit pattern, D5) to the
/// `cell`/`paged` oracle (`profiles.safe()`), values AND the OOB trap alike. This re-confirms that
/// the SIMD lane ops (pure `rt_simd` over binaries) and the SIMD-memory family (through the
/// immutable-binary `rt_mem`) execute on a bare BEAM without a native backend (spec §7 embedding).
pub fn portable_simd_kernels_run_byte_identical_to_oracle_test() {
  let portable_d = driver.pipeline_with(profiles.portable())
  let oracle_d = driver.pipeline_with(profiles.safe())

  let failures =
    list.flat_map(["simddot", "simdxform", "simdmem"], fn(name) {
      let #(p_outs, p_fails) = combos.evaluate(portable_d, name)
      let #(o_outs, _) = combos.evaluate(oracle_d, name)
      list.flatten([
        list.map(p_fails, fn(f) { "portable spec-incorrect: " <> f }),
        case p_outs == o_outs {
          True -> []
          False -> [
            name
            <> " [portable ≢ cell/paged oracle]: "
            <> string.inspect(o_outs)
            <> " vs "
            <> string.inspect(p_outs),
          ]
        },
      ])
    })
  assert failures == []
}

/// PROOF 5b (memory64 executed — the dynamic half). `mem64`, compiled under the REAL `portable`
/// profile (Threaded/Paged/`bif`, with the fuel meter raised clear of the 65537-page grow — the
/// fuel bound is orthogonal to the memory64 runtime, proven by the Phase-4 fuel suites), runs
/// through `load → instantiate → invoke` on a bare BEAM BYTE-IDENTICAL to the `cell`/`paged` oracle:
/// i64 addressing past 2^32, the page-cap grow → -1, and the OOB trap all execute on BEAM bignums,
/// no native code. So the runs-anywhere property covers the memory64 surface too.
pub fn portable_mem64_runs_byte_identical_to_oracle_test() {
  let portable_d =
    driver.pipeline_with(
      Binding(..profiles.portable(), fuel_budget: mem64_fuel),
    )
  let oracle_d =
    driver.pipeline_with(Binding(..profiles.safe(), fuel_budget: mem64_fuel))

  let #(p_outs, p_fails) = combos.evaluate(portable_d, "mem64")
  let #(o_outs, _) = combos.evaluate(oracle_d, "mem64")
  let failures =
    list.flatten([
      list.map(p_fails, fn(f) { "portable spec-incorrect: " <> f }),
      case p_outs == o_outs {
        True -> []
        False -> [
          "mem64 [portable ≢ cell/paged oracle]: "
          <> string.inspect(o_outs)
          <> " vs "
          <> string.inspect(p_outs),
        ]
      },
    ])
  assert failures == []
}

// ─────────────── P7-10 PROOF 5: runs-anywhere RE-CONFIRMED for the EXCEPTION-HANDLING surface (J5/J7) ───────────────

/// The Phase-7 EH backstop programs the runs-anywhere property must be RE-CONFIRMED over (capstone
/// §F). EH grew the surface again, so the `Throw`/`Try`/`ThrowRef` nodes + the `exnref` value must
/// ALSO run under the tier-P `portable` build (Threaded/Paged/`bif`) with no native code and no
/// crashable instance cell — else the runs-anywhere headline (and, transitively, the JS-on-the-BEAM
/// headline, since Porffor's output IS this surface) no longer covers the whole engine. EH is
/// BEAM-native control flow: a throw unwinds the process's native stack, not the `state_strategy`
/// record/cell, so the state-FREE EH surface is state-strategy-invariant and runs under `portable`
/// (Threaded) byte-identically to the `cell`/`paged` oracle — the T6 Cell-only bound is only the
/// state-threaded-through-throw combo, which these do not exercise. Checked in as `corpus/<name>.ir`
/// (capstone-owned; both encodings — legacy `ehthrow`, modern `ehcatch`/`ehcatchall`/`ehnested`/
/// `ehrethrow`).
const p7_eh_programs: List(String) = [
  "ehthrow", "ehcatch", "ehcatchall", "ehnested", "ehrethrow",
]

/// PROOF 5a (EH surface, J5 — no native code). The `portable` `.core` of every EH kernel links ZERO
/// native / OTP-native state: `rt_exn` is a pure-BEAM tuple-and-`raise` runtime (no NIF), the catch
/// is a native Core Erlang `try…catch`, the `exnref` is an opaque `{ref_exn,_}` box — nothing native
/// is even reachable, so the worst case of an EH-lowering bug under `portable` is a wrong-catch /
/// lost-payload / a node-safe process exception, NEVER a host escape (spec §7 embedding; J5).
pub fn portable_p7_eh_links_zero_native_state_test() {
  let failures =
    list.flat_map(p7_eh_programs, fn(name) {
      let core = portable_core(name)
      let check = fn(tok) {
        case combos.count_occurrences(core, tok) {
          0 -> []
          n -> [
            name
            <> " links native primitive '"
            <> tok
            <> "' × "
            <> int.to_string(n),
          ]
        }
      }
      list.flatten([
        check("atomics"),
        check("ets"),
        check("persistent_term"),
        check("load_nif"),
        check("erlang_nif"),
      ])
    })
  assert failures == []
}

/// PROOF 5a (EH surface, J5 — no crashable instance cell). No process-dictionary INSTANCE-STATE seam
/// (`'seed'`/`'mem_get'`/`'mem_put'`/`'global_get'`/`'global_set'`) in any EH kernel's portable
/// `.core`: the EH programs touch no memory/global, and a throw carries the build-controlled 3-tuple
/// `{wasm_exn, TagId, Payload}` — no instance state travels through the throw (T6). So the whole EH
/// surface carries the SAME "no crashable state" property Phase 4 proved for the base corpus.
pub fn portable_p7_eh_has_no_instance_cell_seam_test() {
  let cell_seam = [
    "'seed'", "'mem_get'", "'mem_put'", "'global_get'", "'global_set'",
  ]
  let failures =
    list.flat_map(p7_eh_programs, fn(name) {
      let core = portable_core(name)
      list.flat_map(cell_seam, fn(tok) {
        case combos.count_occurrences(core, tok) {
          0 -> []
          n -> [
            name
            <> " emits pdict instance-cell seam '"
            <> tok
            <> "' × "
            <> int.to_string(n),
          ]
        }
      })
    })
  assert failures == []
}

/// PROOF 5a (EH surface, non-vacuity). The greps above are a REAL audit, not vacuously-green: the
/// `portable` build DOES route the EH nodes through the pure-BEAM `rt_exn` runtime + native Core
/// Erlang `try` (a real replacement, not an absence). Every EH program names `rt_exn` (the stable
/// EH-runtime module — `throw_exn`/`match_tag`/`reraise`/`capture_exnref`/`throw_ref`) AND emits a
/// Core Erlang `try` (the catch). If P7-06/07 renamed the seam, these tokens follow — the seam is
/// named, not guessed. And `rt_exn` is native-free: an EH kernel's portable `.core` links no native
/// primitive at all (proven above).
pub fn portable_p7_eh_uses_pure_beam_rt_exn_test() {
  let failures =
    list.flat_map(p7_eh_programs, fn(name) {
      let core = portable_core(name)
      list.flatten([
        case combos.count_occurrences(core, "rt_exn") > 0 {
          True -> []
          False -> [
            name <> ": portable .core does not name rt_exn (EH seam absent)",
          ]
        },
        case combos.count_occurrences(core, "try") > 0 {
          True -> []
          False -> [
            name <> ": portable .core emits no Core Erlang 'try' (catch absent)",
          ]
        },
      ])
    })
  assert failures == []
}

/// PROOF 5b (EH EXECUTED — the dynamic half). Every EH kernel, compiled under the REAL
/// `profiles.portable()` profile and run through `load → instantiate → invoke` on a bare BEAM, is
/// (1) spec-correct against its `.expected` and (2) BYTE-IDENTICAL (raw bit pattern, D5) to the
/// `cell`/`paged` oracle (`profiles.safe()`). This re-confirms that the EH lowering (a throw →
/// `rt_exn` raise; a catch → a native Core Erlang `try`; a re-raise → `rt_exn` reraise) executes on a
/// bare BEAM without a native backend — the runs-anywhere property now covers the EH surface and,
/// transitively, the JS-on-the-BEAM surface (Porffor's output is this WASM surface).
pub fn portable_p7_eh_runs_byte_identical_to_oracle_test() {
  let portable_d = driver.pipeline_with(profiles.portable())
  let oracle_d = driver.pipeline_with(profiles.safe())

  let failures =
    list.flat_map(p7_eh_programs, fn(name) {
      let #(p_outs, p_fails) = combos.evaluate(portable_d, name)
      let #(o_outs, _) = combos.evaluate(oracle_d, name)
      list.flatten([
        list.map(p_fails, fn(f) { "portable spec-incorrect: " <> f }),
        case p_outs == o_outs {
          True -> []
          False -> [
            name
            <> " [portable ≢ cell/paged oracle]: "
            <> string.inspect(o_outs)
            <> " vs "
            <> string.inspect(p_outs),
          ]
        },
      ])
    })
  assert failures == []
}
