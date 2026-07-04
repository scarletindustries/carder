//// `middle/ir_opt` — the shared IR→IR optimizer entry point (F1). Owns `optimize/2` +
//// `pipeline/1`; the `Pass` type, its combinators, and the fixpoint driver (`run_pipeline`)
//// live in the leaf module `middle/ir_opt/pass` (imports `ir` ONLY). The import chain stays
//// acyclic — `pass → ir`; `ir_opt → {ir, pass}`; `instance → ir_opt`; `ir_lower → instance`
//// — so nothing here depends on the runtime binding.
////
//// `ir_opt` is a new shared **middle-end** stage between `ir_lower` and `emit_core`. It
//// rewrites the language-neutral IR (frontend-agnostic), so every future frontend inherits it.
//// Its public surface is one entry point (`optimize/2`) plus the ordered pass list per level
//// (`pipeline/1`), the single point units 03/04 register real passes into.

import gleam/list
import twocore/ir.{type Module}
import twocore/middle/ir_opt/aggressive
import twocore/middle/ir_opt/baseline
import twocore/middle/ir_opt/mem_dse
import twocore/middle/ir_opt/mem_forward
import twocore/middle/ir_opt/pass.{type Pass, run_pipeline}

/// The optimization level a build profile selects (F1). `OptNone` is the identity (the
/// Phase-1/2 build path with the optimizer bypassed — the differential baseline of F2).
///
/// **Naming (settled decision).** F1's prose calls the identity level `None`; it is frozen
/// here as the constructor `OptNone` to avoid colliding with `gleam/option.None`, which the
/// files that thread the level (`instance`, `emit_core`, `pipeline`) all import. `Baseline`
/// and `Aggressive` are collision-free and importable unqualified.
///
/// - `OptNone`: run no passes — `optimize` is the exact identity.
/// - `Baseline`: the trust-neutral passes (unit 03).
/// - `Aggressive`: `baseline ++` the Unsafe-only passes (unit 04); a strict superset of
///   `Baseline`. Legal only over a metering-free module (`Aggressive ⟹ MeterOff`, see
///   `optimize`).
pub type OptLevel {
  OptNone
  Baseline
  Aggressive
}

/// Optimize `module` at `level` (F1) — the single public entry point of the stage.
///
/// - `module`: the IR module from `ir_lower`.
/// - `level`: `OptNone` (identity), `Baseline` (trust-neutral passes), or `Aggressive`
///   (baseline + Unsafe-only passes). Read from `binding.opt_level` by the driver (F7).
/// - Return: a **semantics-preserving** rewrite of `module` (F2 — identical returned values by
///   bit pattern per D7, and identical traps, over the whole acceptance corpus + spec suite).
///   Total; never fails and never introduces an unsound rewrite.
///
/// **Precondition (`Aggressive ⟹ MeterOff`).** Calling `optimize` with `Aggressive` over a
/// `Charge`-bearing module is illegal: `Aggressive` may only pair with `MeterOff`, the posture
/// under which `ir_lower` inserts no `Charge` nodes (F5). So a module reaching the `Aggressive`
/// pipeline is provably metering-free — which is what makes unit 04's `Charge`-elision /
/// inlining sound. No shipped profile constructor yields `Aggressive` + `MeterFuel`.
///
/// FREEZE BODY: `run_pipeline(module, pipeline(level))`. At the freeze `pipeline(level)` is
/// empty for every level, so `optimize` is the observable identity; units 03/04 register the
/// real passes (single-owner-additive on `pipeline/1`).
pub fn optimize(module: Module, level: OptLevel) -> Module {
  run_pipeline(module, pipeline(level))
}

/// The ordered pass list for `level` — the ONE registration point (units 03/04 and Phase-9 unit 04
/// append here).
///
/// `OptNone` stays `[]` forever (F1) — the exact identity, the F2 differential baseline.
/// `Baseline` runs the Phase-3 trust-neutral pass set (`baseline.baseline_passes()`) **followed by
/// the Phase-9 memory passes** (`memory_passes()` — store→load forwarding + redundant-load
/// elimination + dead-store elimination). Those same passes ALSO run at `Aggressive`, which is kept
/// a superset of `Baseline` (keystone A.2): the `Aggressive` arm is
/// `baseline.baseline_passes() ++ memory_passes() ++ aggressive.aggressive_passes()`.
///
/// **Ordering rationale (Phase-9 M2).** The memory passes run AFTER the baseline set — so
/// const-fold + copy/const-prop have already propagated and folded constant addresses, unifying
/// bases and improving the alias analysis's disambiguation — and BEFORE the Unsafe-only aggressive
/// passes. The `run_pipeline` fixpoint re-runs the whole arm over the transformed bodies, so
/// baseline copy-prop cleans up the `Let([y], Values([v]), …)` bindings forwarding leaves behind,
/// and the memory passes get another sweep after aggressive inlining exposes new adjacencies. The
/// Phase-9 passes are **trust-neutral** (they preserve WASM's trap-or-access semantics exactly), so
/// running them at `Baseline` means Safe gets them too — every tier and both modes win (M2), and
/// they never touch `Charge` nodes, so the deterministic fuel bound is unchanged (F5). Total.
fn pipeline(level: OptLevel) -> List(Pass) {
  case level {
    OptNone -> []
    Baseline -> list.append(baseline.baseline_passes(), memory_passes())
    Aggressive ->
      list.append(
        list.append(baseline.baseline_passes(), memory_passes()),
        aggressive.aggressive_passes(),
      )
  }
}

/// The Phase-9 memory-optimizer passes, in order (M2/M4): store→load forwarding + redundant-load
/// elimination (`mem_forward.forwarding_pass()`), then dead-store elimination
/// (`mem_dse.dead_store_pass()`). Each is trap-preserving and trust-neutral, consumes the frozen
/// `mem_ssa` alias analysis, and only *removes* a `MemStore` or *replaces* a `MemLoad` with an
/// already-bound value — never adds a node or reorders an effect. Total.
fn memory_passes() -> List(Pass) {
  [mem_forward.forwarding_pass(), mem_dse.dead_store_pass()]
}
