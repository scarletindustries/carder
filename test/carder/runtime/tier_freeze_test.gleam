//// Unit P4-01 — the two Phase-4 freeze contracts, verified.
////
//// The keystone's "strawman" (mirroring Phase-2's `ir2_freeze_test` / Phase-3's
//// `opt_iface_freeze_test`): it proves the frozen surface — `«STATE-STRATEGY-FROZEN»` and
//// `«MEM-TIER-FROZEN»` — typechecks and upholds its documented contracts. The assertions are
//// SPEC assertions (what the freeze must guarantee), NOT change-detectors (D8):
////
//// - the two new axes EXPRESS the Phase-4 surface: a `Threaded` state binding and an `Atomics`
////   memory binding both typecheck, so units 02/04 can construct and bind to them (§A.1/§B.1);
//// - the fail-closed defaults hold (D4/§B.4): `safe()`/`safe_default()`/`unsafe()` are all
////   `Cell`/`Paged`/`TablePaged` — the maximally node-safe posture, never reachable-by-omission;
//// - Safe+Nif is UNCONSTRUCTIBLE through the profile API (G6/§B.4) — a property of the type,
////   not a runtime check;
//// - the threaded box IS the existing `rt_state.InstanceState` — it round-trips its three
////   fields (mem/globals/table), pinning that units 02/03/04/06 share one record type (§A.2);
//// - `coexist_name` keys the output atom on the full build identity `(mode, state_strategy,
////   mem_tier)` (§B.5/B3) — the default is the canonical `base`, and any two distinct-identity
////   builds of one source derive distinct atoms (BEAM loads one module per atom).

import carder/runtime/instance.{
  type Binding, Atomics, Binding, Cell, Nif, Paged, TablePaged, Threaded,
}
import carder/runtime/profiles
import carder/runtime/rt_state.{InstanceState}
import gleam/dict
import gleam/dynamic
import gleam/list
import gleam/set

// ───────────────────────────── the axes express the surface ─────────────────────────────

/// `«STATE-STRATEGY-FROZEN»` / `«MEM-TIER-FROZEN»`: the two new axes EXPRESS the Phase-4 surface
/// — a `Threaded` state binding and an `Atomics` memory binding are both constructible (a
/// record-spread over `safe()` overriding exactly one axis) and typecheck, proving downstream
/// units 02/04 can build and bind to the frozen axes before any runtime body exists.
pub fn tier_axes_are_expressible_test() {
  let threaded = Binding(..profiles.safe(), state_strategy: Threaded)
  assert threaded.state_strategy == Threaded

  let atomics = Binding(..profiles.safe(), mem_tier: Atomics)
  assert atomics.mem_tier == Atomics
}

// ───────────────────────────── fail-closed tier defaults (D4) ─────────────────────────────

/// The fail-closed trust-tier default (D4/§B.4): the default `safe()`/`safe_default()` posture
/// is the maximally node-safe `Cell` state strategy + tier-P `Paged`/`TablePaged` backends
/// (byte-identical to Phase-2/3), and `unsafe()` INHERITS the same tiers (it overrides only
/// policy). The tier-P `portable` / tier-N `ceiling` postures are unit 07's, unreachable here by
/// omission — leaving the default requires NAMING a profile.
pub fn fail_closed_tier_defaults_test() {
  assert profiles.safe().state_strategy == Cell
  assert profiles.safe().mem_tier == Paged
  assert profiles.safe().table_tier == TablePaged

  assert instance.safe_default().state_strategy == Cell
  assert instance.safe_default().mem_tier == Paged
  assert instance.safe_default().table_tier == TablePaged

  // Unsafe inherits the same tier posture (the Phase-3 spread carries the tiers unchanged).
  assert profiles.unsafe().state_strategy == Cell
  assert profiles.unsafe().mem_tier == Paged
  assert profiles.unsafe().table_tier == TablePaged
}

// ───────────────────────────── Safe forbids nif, by construction (G6) ─────────────────────

/// The G6 fail-closed guarantee (§B.4), pinned as a property of the TYPE: NO `profiles.safe*`
/// constructor yields a tier-N (`Nif`) memory — enumerated over every Safe constructor
/// (`safe()`/`safe_capped(_)`/`safe_metered(_)`/`safe_default()`). Because Gleam has no default
/// field values every constructor NAMES `Paged`, so a `Safe + Nif` binding is unconstructible
/// through the profile API; only the Unsafe `ceiling` (unit 07) may ever set `Nif`.
pub fn safe_forbids_nif_is_unconstructible_test() {
  let safe_bindings = [
    profiles.safe(),
    profiles.safe_capped(1),
    profiles.safe_metered(1000),
    instance.safe_default(),
  ]
  assert list.all(safe_bindings, fn(b: Binding) { b.mem_tier != Nif })
}

// ───────────────────────────── the threaded box is the existing record (§A.2) ─────────────

/// The threaded instance-state record IS the `rt_state.InstanceState` box (§A.2). Phase 5 grew
/// it to a multi-region record (memory-index vector, table-index vector, passive drop-state,
/// reference globals — R5/R7/R8), but the DEFAULT (index-0) memory/table still round-trip
/// through the byte-identical Phase-4 aliases (`rt_state.mem`/`rt_state.table`), and globals are
/// still raw-bit-pattern `Int`s keyed by name. Pins that the `Threaded` strategy threads the SAME
/// box the `Cell` strategy stores — tier-orthogonal — so units 02/03/04/06 share this record.
pub fn threaded_box_round_trips_test() {
  let mem = dynamic.string("mem-handle")
  let table = dynamic.string("table-handle")
  let globals = dict.from_list([#("g0", 7), #("g1", 42)])
  let st =
    InstanceState(
      mems: [mem],
      globals: globals,
      tables: [table],
      dropped_data: set.new(),
      dropped_elem: set.new(),
      ref_globals: dict.new(),
      func_imports: [],
    )
  // The index-0 aliases project the default memory/table (byte-identical to Phase-4).
  assert rt_state.mem(st) == mem
  assert st.globals == globals
  assert rt_state.table(st) == table
}

// ───────────────────────────── coexistence keys on the full build identity (§B.5) ──────────

/// `coexist_name` keys the output atom on the FULL build identity `(mode, state_strategy,
/// mem_tier)` (§B.5/B3), so no two distinct `.beam`s of one source collide (BEAM loads one
/// module per atom → a collision hot-replaces the earlier module). The default `safe()`
/// (Safe/Cell/Paged) build is the canonical `base` — unchanged, conformance-neutral (G7); the
/// `safe()` (cell) and a `portable()`-shape (threaded) build — BOTH Safe — derive DISTINCT atoms
/// (separated by the `_threaded` suffix), as do `safe()` vs an `Atomics` build (`_atomics`).
pub fn coexist_name_keys_on_full_build_identity_test() {
  let base = "carder@wasm@tier_freeze"

  // Default Safe/Cell/Paged appends NOTHING — the canonical base (conformance-neutral).
  assert profiles.coexist_name(base, profiles.safe()) == base

  // safe() (cell) vs a portable()-shape (threaded) build, both Safe → distinct via `_threaded`.
  let threaded = Binding(..profiles.safe(), state_strategy: Threaded)
  assert profiles.coexist_name(base, threaded) == base <> "_threaded"
  assert profiles.coexist_name(base, profiles.safe())
    != profiles.coexist_name(base, threaded)

  // safe() vs an Atomics build → distinct via `_atomics`.
  let atomics = Binding(..profiles.safe(), mem_tier: Atomics)
  assert profiles.coexist_name(base, atomics) == base <> "_atomics"
  assert profiles.coexist_name(base, profiles.safe())
    != profiles.coexist_name(base, atomics)
}
