//// Unit P4-09 — PROOF 4: the runs-anywhere grep proof (§E, G6 — the "no OTP, no NIF" pitch).
////
//// The `portable` build is the platform's headline: tier-P instance state + numerics (`Threaded`
//// state + `Paged` memory + `bif` numerics, Safe policy) carrying only the node-safe, process-local
//// tier-O policy overlays Safe mandates (the `rt_meter` CPU-fuel counter + the `rt_host` policy
//// cell), running on a bare BEAM with NONE of the native/unsafe primitives
//// (`atomics`/`ets`/`persistent_term`/`nif`) AND no pdict instance-state cell, provably unable to
//// crash the node. Proven STRUCTURALLY on the emitted `.core` — the one artifact that names every
//// runtime module the generated code links (the seam emits only fixed `carder@runtime@*` atoms,
//// D3a), so a grep of it is an exhaustive audit of what a portable instance can reach.
////
//// ## The decided scoping (P4 — stated so the headline proof is TRUE)
////
//// The grep's ZERO-set is:
////   - the native/unsafe primitives `atomics`/`ets`/`persistent_term`/`nif` — EVERYWHERE, and
////   - the pdict INSTANCE-STATE cell seam (`rt_state` `'seed'`/`'mem_get'`/`'mem_put'`/`'global_get'`
////     /`'global_set'`), which `Threaded` GENUINELY eliminates (the state is a value threaded
////     through generated code).
//// It deliberately does NOT assert zero pdict: a Safe `portable` build MANDATORILY keeps
//// `MeterFuel` (the F5 fail-closed CPU bound), so its `.core` DOES call `rt_meter:seed_fuel`/`charge`
//// and seed the `rt_host` policy cell — each a single PROCESS-LOCAL pdict value: node-safe, cannot
//// escape, cannot crash the node, available on every BEAM (so still "runs-anywhere"). The project
//// taxonomy classifies pdict as tier-O (node-safe), and Safe permits tier P or O, never N — so these
//// overlays legitimately remain (`MeterOff`-under-Safe is rejected; it would break the CPU bound).
//// This test states that scope explicitly, so the "no OTP, no NIF" headline it proves is honest.
////
//// Spec / decision anchors: keystone §B.1 (the seam emits fixed `carder@runtime@*` atoms), G6
//// (fail-closed, memory-safe by construction). The grep is over emitted text, so it is exhaustive
//// for the module BOUNDARY a portable instance crosses.

import carder/pipeline
import carder/tier/combos

/// Compile corpus `name` to `.core` text under `binding` (the artifact the grep audits). The
/// portable build links only pure-BEAM `carder@runtime@*` modules; the grep sees every one.
fn core_of(name: String, combo: combos.Combo) -> String {
  let assert Ok(bytes) = combos.read_wasm(name)
  let assert Ok(m) = pipeline.source_to_ir(bytes)
  let assert Ok(core) = pipeline.ir_to_core(m, combos.binding_for(combo))
  core
}

// ─────────────────────────── PROOF 4 (a): zero native / unsafe primitives ───────────────────────────

/// PROOF 4 (a) (G6). A `portable` (Threaded + Paged + Safe) `.core` links ZERO OTP-native /
/// native-code state: it names no module containing `atomics`, `ets`, `persistent_term`, or `nif`.
/// A memory-EXERCISING program (`mem` — load/store) is chosen so the tier seam is actually reached;
/// still, no native backend is named. This is the structural half of "no OTP, no NIF".
pub fn portable_links_no_native_state_test() {
  let core = core_of("mem", combos.portable)
  assert combos.count_occurrences(core, "atomics") == 0
  assert combos.count_occurrences(core, "ets") == 0
  assert combos.count_occurrences(core, "persistent_term") == 0
  assert combos.count_occurrences(core, "nif") == 0
}

/// PROOF 4 (b) (G6). No process-dictionary INSTANCE-STATE cell — `Threaded` replaces the `rt_state`
/// cell with a threaded record. The memory-cell seam (`'seed'`/`'mem_get'`/`'mem_put'`) is ABSENT
/// from a memory program's `.core`. Note the QUOTED-atom grep is precise: `'seed'` is 0 even though
/// `seed_fuel` (the tier-O fuel overlay) is present — the closing quote after `seed` never matches
/// inside `'seed_fuel'`.
pub fn portable_has_no_pdict_instance_cell_seam_test() {
  let core = core_of("mem", combos.portable)
  assert combos.count_occurrences(core, "'seed'") == 0
  assert combos.count_occurrences(core, "'mem_get'") == 0
  assert combos.count_occurrences(core, "'mem_put'") == 0
}

/// PROOF 4 (b, globals). The mutable-global cell seam (`'global_get'`/`'global_set'`/`'seed'`) is
/// ABSENT from a globals program's (`gvar`) portable `.core` — `Threaded` routes globals through the
/// threaded record (`'t_global_get'`/`'t_global_set'`), not the pdict cell. Non-vacuous: the threaded
/// global accessor IS present, so this is not vacuously green.
pub fn portable_globals_use_threaded_record_not_cell_test() {
  let core = core_of("gvar", combos.portable)
  assert combos.count_occurrences(core, "'global_get'") == 0
  assert combos.count_occurrences(core, "'global_set'") == 0
  assert combos.count_occurrences(core, "'seed'") == 0
  // The threaded family IS present — the cell seam was replaced, not merely dropped.
  assert combos.count_occurrences(core, "'t_global_get'") > 0
}

/// PROOF 4 (non-vacuity of the threaded memory family). A `portable` memory `.core` DOES name the
/// threaded memory family (`'t_store'`/`'t_load'`) — so proof (b)'s "no cell seam" is a REPLACEMENT
/// (the record-threading build), not a vacuous absence of memory ops.
pub fn portable_uses_threaded_memory_family_test() {
  let core = core_of("mem", combos.portable)
  assert combos.count_occurrences(core, "'t_store'") > 0
  assert combos.count_occurrences(core, "'t_load'") > 0
}

// ─────────────────────────── PROOF 4 (decided scope): the tier-O overlays legitimately remain ───────────────────────────

/// PROOF 4 (decided scope, P4). A Safe `portable` build MANDATORILY keeps `MeterFuel` (the F5 CPU
/// bound), so its `.core` DOES call the node-safe, process-local tier-O overlays — `rt_meter`
/// (`seed_fuel`/`charge`) and the `rt_host` policy cell. This test asserts they are PRESENT (> 0) to
/// document that the runs-anywhere claim's zero-set is the native/unsafe primitives + the instance
/// cell — NOT a strict-zero-pdict claim (`MeterOff`-under-Safe is rejected; it would break the CPU
/// bound). Stating this keeps the headline proof honest.
pub fn portable_keeps_node_safe_tier_o_overlays_test() {
  let core = core_of("mem", combos.portable)
  // The Safe CPU-fuel counter is baked in (seed at instantiate + charge sites) — node-safe pdict.
  assert combos.count_occurrences(core, "rt_meter") > 0
  assert combos.count_occurrences(core, "seed_fuel") > 0
  // The host-policy cell is present (deny-all under Safe) — node-safe pdict.
  assert combos.count_occurrences(core, "rt_host") > 0
}

// ─────────────────────────── PROOF 4 (c): non-vacuity — the grep can see what it forbids ───────────────────────────

/// PROOF 4 (c) (non-vacuity). A `ceiling`/`atomics` `.core` DOES name the tier-O `rt_mem_atomics`
/// module — proving proof (a)'s zero-count is a REAL audit (the grep can see the native/O(1) backend
/// when it is linked), not a grep that would pass on any input. The atomics build is what portable
/// deliberately excludes.
pub fn atomics_build_names_tier_o_module_test() {
  let core = core_of("mem", combos.cell_atomics)
  assert combos.count_occurrences(core, "rt_mem_atomics") > 0
  // And it genuinely LINKS the atomics backend (the tier→module coupling ran, not just a mention).
  assert combos.count_occurrences(core, "carder@runtime@rt_mem_atomics") > 0
}
