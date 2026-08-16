//// Unit P4-09 — PROOF 1b: the `memory.grow` fuel-charge trap parity (§B.1, G7 / keystone §B.2).
////
//// `memory.grow` is the ONE runtime-side DYNAMIC fuel charge in the whole system: every other
//// cost is a static IR `Charge` node the emitter plants at a known count, but grow fuel is
//// PER-ACTUAL-DELTA (`delta * page_bytes` newly-committed bytes) and the delta is only known at
//// run time — so the charge lives in the runtime (`rt_mem.grow` / `t_grow` charge
//// `rt_meter.charge(delta * page_bytes)` on the SUCCESS path), not the emitter. Therefore the
//// threaded `t_grow` MUST replicate Cell's charge, or `metered × threaded` out-runs
//// `metered × cell` — which (a) violates the G7 byte-identical-traps bar and (b) opens a
//// resource-bound hole (an untrusted `portable` module could allocate to its page cap with ZERO
//// CPU accounting). This proof pins that `t_grow`'s charge equals `grow`'s, END-TO-END through
//// the compiled code + run-ABI, across `cell×paged`, `threaded×paged`, and BOTH `atomics` rows.
////
//// `FuelExhausted` is a carder Safe resource bound, not a WASM spec trap (keystone C.1), so this
//// is a pure cross-strategy differential with no `.expected` — exactly what pins `t_grow == grow`.
//// The discriminator (measured): the `memgrow` `grow(1)` call costs ~464 static fuel + the
//// dynamic `65536` grow charge. A GENEROUS budget (200000 » 66000) lets the grow SUCCEED (proving
//// the trap below is caused by the grow's dynamic charge, not merely by reaching the grow); a
//// TIGHT budget (40000 — comfortably above the static cost, below the 65536 grow charge) traps
//// FuelExhausted ON THE GROW. If the threaded `t_grow` dropped the charge, `threaded×…` would
//// SUCCEED at the tight budget (~464 « 40000) and diverge from `cell×…` — turning this red.
////
//// Process hygiene (units 05/07): each seeding instance runs `instantiate/0` (which seeds fuel)
//// in its OWN spawned process via the driver's `ffi.start_instance`, so the budget lives in that
//// process's dictionary, never the shared eunit runner process — no cross-test pdict leak.

import carder/harness/driver
import carder/harness/fixture.{I32Val}
import carder/harness/runner.{type InvokeResult, DriverError, Returned, Trapped}
import carder/tier/combos.{type Combo, type Outcome, Trap, Value}
import gleam/list
import gleam/string

/// A generous budget that comfortably exceeds the whole `grow(1)` cost (static + the 65536
/// dynamic grow charge), so the grow SUCCEEDS — the control that proves the tight-budget trap is
/// caused by the grow's dynamic charge, not by reaching the grow at all.
const generous: Int = 200_000

/// A tight budget: above the static cost (~464) so the function REACHES and executes the grow,
/// but below the 65536 dynamic grow charge — so the grow itself is the deciding trap.
const tight: Int = 40_000

/// Compile `memgrow` under `c` metered at `budget`, instantiate it in its own owned process
/// (driver → `ffi.start_instance`), invoke `grow(1)`, and reduce the outcome to a normalized
/// `Outcome`. `grow(1)` grows page 0→1 (within the declared max 1) and returns the OLD size (0)
/// on success, or traps `FuelExhausted` when the dynamic grow charge over-spends `budget`.
fn grow_outcome(c: Combo, budget: Int) -> Outcome {
  let d = driver.pipeline_with(combos.binding_for_metered(c, budget))
  let assert Ok(bytes) = combos.read_ir("memgrow")
  let assert Ok(inst) = d.instantiate(bytes)
  to_outcome(d.invoke(inst, "grow", [I32Val(1)]))
}

/// Reduce an `InvokeResult` to the normalized `Outcome` (raw bits per D7, or the raw trap reason).
fn to_outcome(r: InvokeResult) -> Outcome {
  case r {
    Returned(vs) -> Value(list.map(vs, combos.raw_of))
    Trapped(reason) -> Trap(reason)
    DriverError(e) -> Trap("driver-error: " <> e)
  }
}

// ─────────────────────────── PROOF 1b: grow fuel parity ───────────────────────────

/// PROOF 1b (a) — under a TIGHT `safe_metered` budget every metered strategy exhausts fuel ON THE
/// GROW: `cell×paged`, `threaded×paged`, `cell×atomics`, `threaded×atomics` all trap
/// `FuelExhausted` at the byte-identical grow. The threaded `t_grow` charging the SAME per-delta
/// fuel as Cell's `grow` is exactly what makes this hold (drop the charge and the threaded rows
/// would not trap).
pub fn grow_traps_fuel_exhausted_under_tight_budget_test() {
  let outcomes = list.map(combos.metered, fn(c) { grow_outcome(c, tight) })
  // Every metered strategy traps FuelExhausted (the {wasm_trap,fuel_exhausted} reason).
  let all_fuel =
    list.all(outcomes, fn(o) {
      case o {
        Trap(reason) -> string.contains(reason, "fuel_exhausted")
        _ -> False
      }
    })
  assert all_fuel
}

/// PROOF 1b (b) — that trap is BYTE-IDENTICAL across strategies (same reason, same grow): the
/// per-delta charge is independent of the calling convention (cell vs threaded) AND of the memory
/// backend (paged vs atomics). Identity across all four `metered` rows.
pub fn grow_trap_is_identical_across_strategies_test() {
  let labelled =
    list.map(combos.metered, fn(c) { #(c.label, [grow_outcome(c, tight)]) })
  assert combos.identity_across("memgrow:grow(1)@tight", labelled) == []
}

/// PROOF 1b (control) — under a GENEROUS budget the SAME `grow(1)` SUCCEEDS (returns the old size
/// 0) on every metered strategy, byte-identically. This proves the tight-budget trap above is
/// caused by the grow's DYNAMIC charge (65536), not merely by reaching the grow: at the generous
/// budget the whole call (static + dynamic) fits, so it returns; at the tight budget only the
/// dynamic grow charge can be the difference. Together (control succeeds, tight traps) this pins
/// that the grow's per-delta charge is present and equal under every strategy.
pub fn grow_succeeds_under_generous_budget_across_strategies_test() {
  let outcomes = list.map(combos.metered, fn(c) { grow_outcome(c, generous) })
  // Each strategy returns the OLD size 0 (grow 0→1 succeeded within the declared max 1).
  assert list.all(outcomes, fn(o) { o == Value([0]) })
  // …and byte-identically across strategies.
  let labelled =
    list.map(combos.metered, fn(c) { #(c.label, [grow_outcome(c, generous)]) })
  assert combos.identity_across("memgrow:grow(1)@generous", labelled) == []
}
