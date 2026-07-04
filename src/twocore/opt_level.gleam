//// The optimizer's public opt-level enum, relocated to a dependency-free leaf.
////
//// This module exists so the **runtime** layer (`runtime/instance`, `runtime/profiles`) can
//// name the build profile's optimization level without importing a compiler module. Before
//// Phase 11 the enum lived in `middle/ir_opt`; `instance`/`profiles` imported it purely for the
//// type, which made the runtime's transitive dependency closure reach a `twocore/middle` module —
//// a source-layer inversion that fails the "runtime reaches zero compiler modules" invariant that
//// `--link` (Phase 11) relies on. Relocating the enum here (a leaf that imports nothing) removes
//// the runtime's last compiler-module import while `middle/ir_opt` continues to own `optimize/2`
//// and `pipeline/1`.
////
//// **This is a relocation of LOCATION, not behavior** (Phase-11 R3 / `«RT-LAYER-FROZEN»`). The
//// three constructors are no-argument, so they lower to the same unqualified Core Erlang atoms
//// regardless of which Gleam module defines the type — emitted `.core`/`.beam` output is
//// byte-identical to before the move.

/// The optimization level a build profile selects.
///
/// Gleam has no constructor re-export, so every use site imports the constructors directly from
/// this module. The constructors are collision-free with `gleam/option.None` — the identity level
/// is spelled `OptNone` (not `None`) precisely so the files that thread the level can also import
/// `gleam/option.None` unqualified without a clash (the original rationale from `middle/ir_opt`).
///
/// - `OptNone`: run no passes — the optimizer is bypassed and `optimize` is the exact identity
///   (the Phase-1/2 build path; the differential baseline against which `Baseline`/`Aggressive`
///   are proven semantics-preserving).
/// - `Baseline`: the trust-neutral pass set (safe under every tier and both modes).
/// - `Aggressive`: `Baseline` plus the Unsafe-only passes — a strict superset of `Baseline`.
///   Legal only over a metering-free module (`Aggressive ⟹ MeterOff`); no shipped profile
///   constructor pairs `Aggressive` with `MeterFuel`.
pub type OptLevel {
  OptNone
  Baseline
  Aggressive
}
