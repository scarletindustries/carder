//// Tests for `rt_meter` — the CPU-fuel metering seam and its Phase-3 enforcement (F5).
////
//// Metering is a *policy* seam, not a WASM-spec concept (WebAssembly defines no fuel; the
//// spec only permits an embedder to abort on **resource exhaustion**, spec §7 Embedding /
//// `assert_exhaustion`). So these assert OUR documented contract and its determinism/soundness
//// PROPERTIES, never "what the code currently emits" (D8):
////
//// - **Observe-only (Phase-1/2, back-compat).** With NO budget seeded, `charge` accumulates
////   the summed cost into a process-local counter and never raises.
//// - **Enforcement (Phase-3, F5).** Once `seed_fuel(b)` installs a budget, the first charge
////   whose running total STRICTLY exceeds `b` raises `FuelExhausted` (surfacing as the
////   catchable `{wasm_trap, fuel_exhausted}`), and the trap point is a DETERMINISTIC pure
////   function of the control-flow trace — the same bound on every run and every schedule.
//// - **Per-process isolation (E1).** The budget + counter are process-dictionary state, so two
////   processes meter independently and neither sees the other's fuel.
////
//// eunit shares one process dictionary across the tests of a module, so every test that seeds
//// a budget runs inside a FRESH spawned process (`metered`), giving each metering assertion an
//// isolated pdict (the one-instance-one-process posture) and keeping a seeded budget from
//// leaking into the observe-only accumulate tests. Exceptions are caught via the
//// namespace-hygienic `carder_rt_state_test_ffi` helper (pure Gleam cannot `catch`).

import carder/ir.{
  IndirectCallTypeMismatch, IntDivByZero, IntOverflow,
  InvalidConversionToInteger, MemoryOutOfBounds, TableOutOfBounds,
  UndefinedElement, UninitializedElement, Unreachable,
}
import carder/runtime/rt_meter
import carder/runtime/rt_state.{StateDecl}
import carder/runtime/rt_trap
import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import gleeunit/should

/// Run `thunk`, reporting whether it raised: `Ok(value)` on a normal return, `Error(text)` on
/// any raise/exit/throw (the reason rendered as text). Shared test-only catch shim; pure Gleam
/// cannot `catch`. See `carder_rt_state_test_ffi`.
@external(erlang, "carder_rt_state_test_ffi", "catch_thunk")
fn catch_thunk(thunk: fn() -> a) -> Result(a, String)

// ── helpers ────────────────────────────────────────────────────────────────────

/// Run `work` in a FRESH BEAM process and return `catch_thunk(work)` — `Ok(v)` on a normal
/// return, `Error(text)` if it raised. A fresh process gives the metering assertion an ISOLATED
/// process dictionary (its own budget + fuel counter): the one-instance-one-process posture
/// (E1), and it keeps a seeded budget from leaking into eunit's shared per-module process.
fn metered(work: fn() -> a) -> Result(a, String) {
  let reply = process.new_subject()
  let _ = process.spawn(fn() { process.send(reply, catch_thunk(work)) })
  let assert Ok(caught) = process.receive(reply, within: 5000)
  caught
}

/// Charge `1` fuel `n` times (a top-level counting loop; §C.2). Returns `Nil` if all `n`
/// charges stay within budget; DIVERGES via `FuelExhausted` on the first charge that pushes the
/// running total over a seeded budget.
fn charge_ones(n: Int) -> Nil {
  case n <= 0 {
    True -> Nil
    False -> {
      rt_meter.charge(1)
      charge_ones(n - 1)
    }
  }
}

/// Assert a caught result is the fuel trap `{wasm_trap, fuel_exhausted}` (as the catch shim
/// renders it), i.e. `charge` raised `FuelExhausted` — not a normal return, not another raise.
fn assert_fuel_trap(caught: Result(a, String)) -> Nil {
  let text = should.be_error(caught)
  should.be_true(string.contains(text, "wasm_trap"))
  should.be_true(string.contains(text, "fuel_exhausted"))
}

// ── Observe-only accumulator (Phase-1/2 contract; un-seeded ⇒ never raises) ──────

/// A fresh counter reads 0, and `charge` accumulates the *sum* of its costs.
pub fn charge_accumulates_test() {
  rt_meter.reset_fuel()
  rt_meter.fuel_consumed() |> should.equal(0)
  rt_meter.charge(5)
  rt_meter.charge(7)
  rt_meter.charge(0)
  rt_meter.fuel_consumed() |> should.equal(12)
}

/// `charge` returns `Nil` (the emitter discards it before the charged expression).
pub fn charge_returns_nil_test() {
  rt_meter.charge(3) |> should.equal(Nil)
}

/// `charge(0)` is total and a no-op on the running total.
pub fn charge_zero_is_total_test() {
  rt_meter.reset_fuel()
  rt_meter.charge(0)
  rt_meter.fuel_consumed() |> should.equal(0)
}

/// `reset_fuel` zeroes a non-empty counter.
pub fn reset_zeroes_counter_test() {
  rt_meter.charge(100)
  rt_meter.reset_fuel()
  rt_meter.fuel_consumed() |> should.equal(0)
}

/// A single large charge is recorded exactly (no overflow — BEAM bignums).
pub fn charge_large_cost_test() {
  rt_meter.reset_fuel()
  rt_meter.charge(1_000_000)
  rt_meter.charge(2_345_678)
  rt_meter.fuel_consumed() |> should.equal(3_345_678)
}

/// Un-seeded (no `seed_fuel`) is the observe-only sentinel (§A.2): `charge` NEVER raises even
/// far past any plausible budget, and `fuel_consumed()` accumulates exactly the summed cost —
/// the Phase-1/2 back-compat behavior the keystone froze.
pub fn unseeded_is_observe_only_test() {
  metered(fn() {
    rt_meter.charge(1_000_000)
    rt_meter.charge(2_345_678)
    rt_meter.fuel_consumed()
  })
  |> should.equal(Ok(3_345_678))
}

// ── Enforcement: a seeded budget bounds CPU-time and traps on exhaustion (F5) ────

/// A runaway loop under a seeded budget TRAPS: charging `1`s past a budget of `5` raises
/// `FuelExhausted`, surfacing as the catchable `{wasm_trap, fuel_exhausted}` (F5 soundness;
/// WebAssembly spec §7 — an embedder aborts on resource exhaustion, never returns a wrong
/// value). The unbounded loop passes a charged back-edge, so a finite budget forces
/// terminate-or-trap.
pub fn runaway_loop_traps_fuel_exhausted_test() {
  metered(fn() {
    rt_meter.seed_fuel(5)
    charge_ones(1_000_000)
  })
  |> assert_fuel_trap
}

/// The exhaustion bound is DETERMINISTIC (§C.2): with budget `5`, charging `1`s trips over on
/// the 6th charge (consumed `6 > 5`), which records `6` THEN raises — so `fuel_consumed()` at
/// the trap is `6` on EVERY run. Two independent runs with the same budget trap after the same
/// count: the bound is a pure function of the trace, independent of scheduling.
pub fn exhaustion_bound_is_deterministic_test() {
  let run = fn() {
    metered(fn() {
      rt_meter.seed_fuel(5)
      let trap = catch_thunk(fn() { charge_ones(1_000_000) })
      #(result.is_error(trap), rt_meter.fuel_consumed())
    })
  }
  let first = run()
  first |> should.equal(Ok(#(True, 6)))
  first |> should.equal(run())
}

/// Spending EXACTLY the budget completes: a total `== b` never raises and `fuel_consumed() ==
/// b`. Pins the strict `>` boundary — a program that spends its whole budget still returns.
pub fn spends_exactly_budget_completes_test() {
  metered(fn() {
    rt_meter.seed_fuel(5)
    charge_ones(5)
    rt_meter.fuel_consumed()
  })
  |> should.equal(Ok(5))
}

/// The FIRST charge over budget traps (no off-by-one): under budget `5`, the 6th unit charge
/// (`6 > 5`) raises `FuelExhausted`. Together with `spends_exactly_budget_completes_test` this
/// pins the strict `>` comparison.
pub fn next_charge_over_budget_traps_test() {
  metered(fn() {
    rt_meter.seed_fuel(5)
    charge_ones(6)
  })
  |> assert_fuel_trap
}

/// `fuel_consumed()` stays OBSERVABLE at exhaustion (F5): after a `FuelExhausted` raise (caught
/// in-process), it reflects the over-budget total `6` — the consumed count is recorded BEFORE
/// the raise.
pub fn fuel_consumed_observable_at_exhaustion_test() {
  metered(fn() {
    rt_meter.seed_fuel(5)
    let trap = catch_thunk(fn() { charge_ones(1_000_000) })
    #(result.is_error(trap), rt_meter.fuel_consumed())
  })
  |> should.equal(Ok(#(True, 6)))
}

/// Re-seeding installs a FRESH budget (per (re)instantiation; WASM instantiation installs fresh
/// state, exec/modules). After exhausting budget `5`, `seed_fuel(3)` resets the consumed
/// counter to `0` and enforces at `3` (three charges complete; the 4th, `4 > 3`, traps) — no
/// leakage from the prior cycle.
pub fn reseed_installs_fresh_budget_test() {
  metered(fn() {
    rt_meter.seed_fuel(5)
    let _ = catch_thunk(fn() { charge_ones(1_000_000) })
    // Fresh cycle: budget 3, consumed reset to 0.
    rt_meter.seed_fuel(3)
    let consumed_after_reseed = rt_meter.fuel_consumed()
    let spends_three = catch_thunk(fn() { charge_ones(3) })
    let fourth_charge = catch_thunk(fn() { rt_meter.charge(1) })
    #(
      consumed_after_reseed,
      result.is_ok(spends_three),
      result.is_error(fourth_charge),
    )
  })
  |> should.equal(Ok(#(0, True, True)))
}

/// Two instances meter INDEPENDENTLY (process isolation, E1): metered in two separate
/// processes with different budgets, each traps at its OWN bound (over-budget totals `6` and
/// `11`) and neither sees the other's consumed/budget — pdict is strictly per-process.
pub fn two_processes_meter_independently_test() {
  let a =
    metered(fn() {
      rt_meter.seed_fuel(5)
      let _ = catch_thunk(fn() { charge_ones(1_000_000) })
      rt_meter.fuel_consumed()
    })
  let b =
    metered(fn() {
      rt_meter.seed_fuel(10)
      let _ = catch_thunk(fn() { charge_ones(1_000_000) })
      rt_meter.fuel_consumed()
    })
  a |> should.equal(Ok(6))
  b |> should.equal(Ok(11))
}

/// `FuelExhausted` maps to the POLICY message `"fuel exhausted"`, and that message is DISTINCT
/// from every WASM-spec trap message — not a substring of any, nor any of them a substring of
/// it — so the conformance harness can never mis-map a real WASM trap to the fuel trap or vice
/// versa (keystone §C.1).
pub fn fuel_exhausted_message_is_distinct_test() {
  rt_trap.spec_trap_message(ir.FuelExhausted)
  |> should.equal("fuel exhausted")

  let fuel = "fuel exhausted"
  let others = [
    IntDivByZero,
    IntOverflow,
    Unreachable,
    IndirectCallTypeMismatch,
    MemoryOutOfBounds,
    InvalidConversionToInteger,
    UndefinedElement,
    UninitializedElement,
    TableOutOfBounds,
  ]
  list.each(others, fn(reason) {
    let msg = rt_trap.spec_trap_message(reason)
    should.be_false(string.contains(msg, fuel))
    should.be_false(string.contains(fuel, msg))
  })
}

/// `rt_meter` and `rt_state` share no pdict key (D3a key hygiene): interleaving
/// `seed_fuel`/`charge` with `rt_state.seed`/`global_set` in one process, a charge never
/// changes a global and a global write never changes `fuel_consumed()`. Proves
/// `carder_rt_meter_budget`/`_fuel` are distinct from `carder_rt_state`.
pub fn interleaved_with_rt_state_no_key_collision_test() {
  metered(fn() {
    rt_meter.seed_fuel(1000)
    rt_state.seed(StateDecl(
      mem: dynamic.nil(),
      globals: [#("g", 7)],
      table: dynamic.nil(),
    ))
    rt_meter.charge(3)
    // A charge did not disturb the global.
    let g_after_charge = rt_state.global_get("g")
    rt_state.global_set("g", 42)
    // A global write did not disturb the fuel counter.
    let fuel_after_global_set = rt_meter.fuel_consumed()
    #(g_after_charge, fuel_after_global_set, rt_state.global_get("g"))
  })
  |> should.equal(Ok(#(7, 3, 42)))
}
