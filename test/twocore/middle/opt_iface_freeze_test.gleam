//// Unit P3-01 — the three Phase-3 freeze contracts, verified.
////
//// This is the freeze's "strawman", mirroring Phase-2's `ir2_freeze_test`: it proves the
//// frozen surface (`«IROPT-IFACE-FROZEN»` / `«UNSAFE-PROFILE-FROZEN»` /
//// `«METER-ENFORCE-FROZEN»`) typechecks and upholds its documented contracts. The assertions
//// are SPEC assertions (what the freeze must guarantee), not change-detectors:
////
//// - the empty freeze pipeline is the exact identity at every `OptLevel` (F1) — units 03/04
////   replace this with the F2 semantics-preserving differential;
//// - the Unsafe `Binding` is the aggressive posture and the Safe one is fail-closed (F4/F7);
//// - the `Aggressive ⟹ MeterOff` coupling holds over EVERY shipped constructor (F4/§B.5);
//// - the metered default is BOUNDED (D4) — `MeterFuel` is never seeded unbounded;
//// - the effect classifier's SOUND direction holds now and forever (E6): `MemStore` is
////   effectful, never pure — never a lock-in of the conservative stub's output;
//// - the `FuelExhausted` policy trap carries its non-spec message and the `rt_meter` seam is
////   callable (F5).

import gleam/erlang/process
import gleam/list
import gleam/option
import twocore/ir
import twocore/ir/effect
import twocore/middle/ir_opt.{Aggressive, Baseline, OptNone}
import twocore/middle/ir_opt/pass
import twocore/runtime/instance.{
  type Binding, BifAllowlist, BifOpen, HostDenyAll, HostOpen, MeterFuel,
  MeterOff, Safe, StdlibOwn, StdlibPassthrough, Unsafe,
}
import twocore/runtime/profiles
import twocore/runtime/rt_meter
import twocore/runtime/rt_trap

// ───────────────────────────── sample IR ─────────────────────────────

/// An `Expr` nesting every structured-control / sequencing form (`Charge`/`Let`/`Block`/
/// `Loop`/`If`/`Switch`) around a `trap` leaf, so a traversal test can prove `map_expr`
/// recurses into ALL six control forms (and both `Switch` positions), not just the outermost.
fn deep_expr(trap: ir.Expr) -> ir.Expr {
  ir.Charge(
    1,
    ir.Let(
      ["x"],
      ir.MemSize(0),
      ir.Block(
        "b",
        [],
        ir.Loop(
          "l",
          [],
          [],
          ir.If(
            ir.ConstI32(1),
            [],
            ir.Switch(ir.ConstI32(0), [], [ir.SwitchArm(0, trap)], trap),
            trap,
          ),
        ),
      ),
    ),
  )
}

/// A small but non-trivial `Module` whose single function body is `deep_expr(Trap(...))` — the
/// subject of the `optimize` identity assertions and the pass-machinery tests.
fn sample_module() -> ir.Module {
  ir.Module(
    name: "twocore@wasm@opt_freeze",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        name: "f",
        params: [],
        result: [],
        locals: [],
        body: deep_expr(ir.Trap(ir.Unreachable)),
      ),
    ],
    exports: [],
    data_segments: [],
    tables: [],
    elements: [],
    start: option_none(),
    tags: [],
  )
}

/// `option.None`, named once so `sample_module` reads cleanly.
fn option_none() -> option.Option(a) {
  option.None
}

// ───────────────────────────── «IROPT-IFACE-FROZEN» ─────────────────────────────

/// `OptNone` is the EXACT identity, forever (F1) — the F2 differential baseline. `Baseline` and
/// `Aggressive` now carry unit-03's real passes, so they are semantics-preserving but NOT
/// structurally the identity: const-`if`/`switch` reduce this sample's constant `If(1, …)` and
/// `Switch(0, …)` to their taken arms. Here we assert the durable properties — `OptNone`
/// identity, and that the optimizer reaches a FIXPOINT (idempotent) at `Baseline`/`Aggressive`;
/// the per-pass F2 differential lives in `test/twocore/optimize/baseline_test.gleam`.
pub fn optimize_none_identity_and_fixpoint_test() {
  let m = sample_module()
  assert ir_opt.optimize(m, OptNone) == m
  assert ir_opt.optimize(ir_opt.optimize(m, Baseline), Baseline)
    == ir_opt.optimize(m, Baseline)
  assert ir_opt.optimize(ir_opt.optimize(m, Aggressive), Aggressive)
    == ir_opt.optimize(m, Aggressive)
}

/// `run_pipeline` with no passes is a fixpoint immediately — it returns the module unchanged.
pub fn run_pipeline_empty_is_identity_test() {
  let m = sample_module()
  assert pass.run_pipeline(m, []) == m
}

/// `map_expr` is the shared bottom-up traversal: it recurses into EVERY structured-control /
/// sequencing sub-expression (proven by rewriting a `trap` leaf buried under all six control
/// forms), preserves the surrounding shape, and applies `rewrite` to every node. The
/// exhaustive full match (no wildcard) is what guarantees this coverage.
pub fn map_expr_recurses_into_every_control_form_test() {
  let swap = fn(e: ir.Expr) -> ir.Expr {
    case e {
      ir.Trap(ir.Unreachable) -> ir.Trap(ir.IntOverflow)
      other -> other
    }
  }
  assert pass.map_expr(deep_expr(ir.Trap(ir.Unreachable)), swap)
    == deep_expr(ir.Trap(ir.IntOverflow))
}

/// `map_expr` with the identity rewrite leaves a leaf untouched — coverage of a leaf variant
/// returns it faithfully (no drop/duplicate).
pub fn map_expr_identity_on_leaf_test() {
  let id = fn(e: ir.Expr) -> ir.Expr { e }
  assert pass.map_expr(ir.MemSize(0), id) == ir.MemSize(0)
}

/// A `per_expr` pass built from a real rewrite is applied across the whole function body by
/// `run_pipeline`, and the pipeline runs to a fixpoint (a second round is a no-op). Proves the
/// registration/driver machinery works end-to-end (units 03/04 register the real passes).
pub fn run_pipeline_applies_a_real_pass_to_fixpoint_test() {
  let swap = fn(e: ir.Expr) -> ir.Expr {
    case e {
      ir.Trap(ir.Unreachable) -> ir.Trap(ir.IntOverflow)
      other -> other
    }
  }
  let p = pass.per_expr("swap_trap", swap)
  let expected =
    ir.Module(..sample_module(), functions: [
      ir.Function(
        name: "f",
        params: [],
        result: [],
        locals: [],
        body: deep_expr(ir.Trap(ir.IntOverflow)),
      ),
    ])
  assert pass.run_pipeline(sample_module(), [p]) == expected
}

/// A `Pass` remembers the name it was built with (used by pipeline logging / per-pass tests).
pub fn pass_name_round_trips_test() {
  let p = pass.pass("noop", fn(m) { m })
  assert pass.pass_name(p) == "noop"
}

// ───────────────────────────── «UNSAFE-PROFILE-FROZEN» ─────────────────────────────

/// `profiles.unsafe()` is the aggressive posture across all six policy fields (F4/F7): mode
/// `Unsafe`, `Aggressive` optimizer, `MeterOff`, `BifOpen`, `StdlibPassthrough`, `HostOpen`.
pub fn unsafe_profile_is_aggressive_posture_test() {
  let b = profiles.unsafe()
  assert b.mode == Unsafe
  assert b.opt_level == Aggressive
  assert b.meter == MeterOff
  assert b.bif_gate == BifOpen
  assert b.stdlib == StdlibPassthrough
  assert b.host_policy == HostOpen
}

/// `profiles.safe()` is the fail-closed Safe posture across all six policy fields (D4/D9):
/// mode `Safe`, `Baseline` optimizer, `MeterFuel`, `BifAllowlist`, `StdlibOwn`, `HostDenyAll`.
pub fn safe_profile_is_fail_closed_posture_test() {
  let b = profiles.safe()
  assert b.mode == Safe
  assert b.opt_level == Baseline
  assert b.meter == MeterFuel
  assert b.bif_gate == BifAllowlist
  assert b.stdlib == StdlibOwn
  assert b.host_policy == HostDenyAll
}

/// The `Aggressive ⟹ MeterOff` coupling (§B.5): NO shipped constructor yields
/// `opt_level == Aggressive` together with `meter == MeterFuel`. The illegal pairing is
/// unrepresentable in a profile, so unit 04's `charge_elide` runs only over a provably
/// metering-free module.
pub fn aggressive_implies_meter_off_over_all_constructors_test() {
  let shipped = [
    profiles.safe(),
    profiles.safe_capped(1),
    profiles.safe_capped(1_000_000),
    instance.safe_default(),
    profiles.safe_instance().binding,
    profiles.unsafe(),
  ]
  assert list.all(shipped, fn(b: Binding) {
    !{ b.opt_level == Aggressive && b.meter == MeterFuel }
  })
}

/// The bounded metered default (D4): `safe()` is `MeterFuel` with the FINITE
/// `rt_meter.default_fuel_budget` (a metered profile is never seeded unbounded), and
/// `unsafe()` inherits that same `fuel_budget` (harmless under `MeterOff`).
pub fn metered_default_is_bounded_test() {
  assert profiles.safe().meter == MeterFuel
  assert profiles.safe().fuel_budget == rt_meter.default_fuel_budget
  assert profiles.unsafe().fuel_budget == rt_meter.default_fuel_budget
}

// ───────────────────────────── effect soundness (E6) ─────────────────────────────

/// The effect classifier's SOUND direction — pinned now AND forever (never a lock-in of the
/// conservative stub's output): a `MemStore` is effectful, never pure. Unit 02 may only ever
/// narrow `Effectful → Pure` with proof; it may never flip this. (E6: misclassifying an
/// effectful node as pure is a memory-corruption bug.)
pub fn memstore_is_effectful_forever_test() {
  let store =
    ir.MemStore(
      0,
      ir.MemAccess(bytes: 4, signed: False),
      ir.ConstI32(0),
      ir.ConstI32(42),
      0,
    )
  assert effect.is_pure(store) == False
  assert effect.is_effectful_node(store) == True
}

// ───────────────────────────── «METER-ENFORCE-FROZEN» ─────────────────────────────

/// The `FuelExhausted` policy trap carries its NON-spec message "fuel exhausted" (F5) —
/// deliberately distinct from every WASM spec trap-message substring so the conformance
/// harness can never mis-map it.
pub fn fuel_exhausted_message_test() {
  assert rt_trap.spec_trap_message(ir.FuelExhausted) == "fuel exhausted"
}

/// The `rt_meter` seam is callable with its frozen ABI: `seed_fuel` seeds the budget and zeros
/// the consumed total, and `charge` (arity 1, returns `Nil`) charges against it — so
/// `fuel_consumed()` reads the charged total (5, well within the 1000 budget, so no trap).
///
/// Enforcement is LIVE as of unit 05, so a seeded budget now bounds `charge`. This runs the
/// seed inside a FRESH process (the one-instance-one-process posture) so the small budget does
/// not leak into eunit's shared per-run process dictionary and trap later fuel-charging tests;
/// the observed total is marshalled back.
pub fn rt_meter_seam_is_callable_test() {
  let reply = process.new_subject()
  let _ =
    process.spawn(fn() {
      rt_meter.seed_fuel(1000)
      rt_meter.charge(5)
      process.send(reply, rt_meter.fuel_consumed())
    })
  let assert Ok(total) = process.receive(reply, within: 5000)
  assert total == 5
}
