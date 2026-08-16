//// `rt_meter` — the minimal fuel/metering seam (D9). Process-local; cannot crash the node.
////
//// The generated Core Erlang calls `charge` at run time for a `Charge(cost, body)` IR
//// node (inserted by unit 11's `ir_lower`): `call 'carder@runtime@rt_meter':'charge'(Cost)`
//// then the charged `body` (see the calling convention in `runtime/instance.gleam`). The
//// point of Phase 1 is that the **instrumentation seam exists and is exercised
//// end-to-end** — not that metering is complete.
////
//// ## Mechanism & trust tier (flagged choice — see `state.md`)
////
//// Phase 1 **accumulates** fuel into a **process-dictionary** counter. That is
//// process-local and node-safe, but the high-level §10 tier taxonomy classifies
//// process-dictionary state as **tier-O** (OTP-native state), not strict tier-P. Safe
//// permits tiers P *or* O (never N), so this is allowed. The pdict accumulator is chosen
//// over a pure no-op `charge` precisely because it makes the seam **observable** — a test
//// can assert `fuel_consumed()` equals the summed cost, proving the charge path executed.
//// A strict-tier-P no-op is the alternative but cannot be observed.
////
//// ## Phase-3 enforcing metering (F5) — LIVE as of unit 05
////
//// Phase 3 turns CPU fuel into a real bound, and unit 05 lands the enforcement body:
//// `seed_fuel/1` installs a finite per-instance budget (seeded from `default_fuel_budget`),
//// and `charge/1` now RAISES `FuelExhausted` (via `rt_trap.raise`, surfacing as the catchable
//// `{wasm_trap, fuel_exhausted}`) the moment a seeded budget is over-spent. The `charge/1` ABI
//// is UNCHANGED (arity 1, returns `Nil`), so generated code and the tail-`apply` loop
//// back-edge do not move a byte (E1). The budget and consumed counter are process-dictionary
//// state (like the Phase-2 cell), seeded once at instantiation and read/written only by
//// `charge`/`seed_fuel` — never threaded through generated function signatures — so a
//// tail-iterating loop stays constant-space and preemptible (get/put/compare cost ordinary
//// reductions; the scheduler still preempts a metered loop mid-flight).
////
//// ## The deterministic cost model (carder policy — spec-neutral)
////
//// WebAssembly defines NO notion of fuel or cost; the spec only permits an embedder to abort
//// on **resource exhaustion** (WebAssembly spec §7 Embedding / the suite's `assert_exhaustion`).
//// The cost model is therefore entirely carder policy. Costs are assigned at IR lowering
//// (`middle/ir_lower.gleam`, NOT here): `ir_lower.fn_cost` is charged once per function entry
//// (every function body is wrapped `Charge(fn_cost, body)`) and `ir_lower.loop_cost` once per
//// loop back-edge (every `Loop` body is wrapped `Charge(loop_cost, body)`). Both are `1` in
//// Phase 3 (any non-negative cost is legal); unit 08 owns the *values* and gates their
//// *insertion* on `binding.meter` (`MeterFuel` inserts the sites; `MeterOff` inserts none, so
//// Unsafe pays exactly nothing). This module owns their *enforcement meaning*.
////
//// - **Determinism property (the test target, F5).** Fuel consumed by an execution is a PURE
////   function of its control-flow trace — (function entries × `fn_cost`) + (loop iterations ×
////   `loop_cost`) — independent of wall-clock time, scheduler decisions, or BEAM reduction
////   counts. So the trap point is deterministic and reproducible: for budget `B` with
////   `fn_cost = loop_cost = 1`, a top-level counting loop consumes `1 + k` after `k`
////   iterations and raises `FuelExhausted` on the first iteration where `1 + k > B` — the
////   SAME count on every run, node, and schedule. A budget that depended on scheduling would
////   let a co-tenant influence another instance's trap point, so this is a security property.
//// - **Soundness property.** Every unbounded WASM 1.0 computation must pass through a loop
////   back-edge or a (recursive) call — both charged; straight-line code is bounded by program
////   size (charged once at entry). Hence any execution that consumes unbounded CPU also
////   consumes unbounded fuel, so a FINITE budget guarantees terminate-or-trap. The model need
////   not weight every opcode to be a sound CPU bound — only to charge every construct that can
////   iterate or recurse. `FuelExhausted` ABORTS; it never returns a wrong value (spec §7).
//// - **Honest scope — CPU-*time*, not space.** Fuel bounds *work* (reductions), NOT stack/heap
////   footprint; memory is bounded separately by `rt_mem`'s max-pages cap (E3). For tail
////   iteration (the loop back-edge template) the loop is constant-space, so a finite budget
////   bounds time AND space. For non-tail recursion each call charges `fn_cost ≥ 1`, so a
////   finite budget bounds recursion DEPTH (~`budget/fn_cost` frames) — but the node memory
////   held at that depth is `O(budget)`, not `O(1)` (a residual caveat). Fuel does NOT
////   unconditionally close every space gap.

import carder/ir.{FuelExhausted}
import carder/runtime/rt_trap
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode

/// The finite default CPU-fuel budget a Safe profile seeds (F5) — the SINGLE source of the
/// budget magnitude. `instance.safe_default()` reads this into `binding.fuel_budget`, and
/// `emit_core`'s `instantiate/0` bakes `seed_fuel(binding.fuel_budget)` under `MeterFuel`.
///
/// It is FINITE (so no metered artifact runs unbounded — fail-closed, D4) yet large enough
/// that the acceptance corpus + spec suite complete without tripping it. Unit 05 tunes the
/// magnitude against the real suite; a metered profile (`profiles.safe_metered(budget)`,
/// unit 10) may LOWER it, exactly as `safe_max_pages` bounds memory.
pub const default_fuel_budget: Int = 1_000_000_000

/// `erlang:put/2` — store `value` under `key` in the current process dictionary; returns
/// the previous value (or the atom `undefined` if unset), which callers here discard.
/// Direct BIF reference; process-local, cannot crash the node.
@external(erlang, "erlang", "put")
fn erlang_put(key: k, value: v) -> Dynamic

/// `erlang:get/1` — read `key` from the current process dictionary, or the atom
/// `undefined` if it was never set. Typed `Dynamic` because the result is either an
/// integer counter or `undefined`; callers decode it.
@external(erlang, "erlang", "get")
fn erlang_get(key: k) -> Dynamic

/// The process-dictionary keys `rt_meter` uses. Each 0-field Gleam constructor compiles to a
/// unique, namespace-hygienic atom, so neither can clash with another library's pdict keys.
///
/// - `CarderRtMeterFuel` (`carder_rt_meter_fuel`): the running fuel total charged so far.
/// - `CarderRtMeterBudget` (`carder_rt_meter_budget`): the seeded CPU budget (`seed_fuel`),
///   the finite bound `charge` will enforce against (unit 05).
type MeterKey {
  CarderRtMeterFuel
  CarderRtMeterBudget
}

/// Seed this instance's CPU-fuel BUDGET (F5), then reset the consumed total to 0.
///
/// Called once by the generated `instantiate/0` (synthesized by `emit_core`, unit 09), which
/// — as a documented exception to emit_core's posture-agnosticism — emits
/// `seed_fuel(binding.fuel_budget)` as `instantiate/0`'s FIRST effect under `MeterFuel`. It
/// runs inside the instance's OWNED process, so the budget lives in that process's dictionary
/// alongside the Phase-2 cell (one-instance-one-process, E1) — isolated per instance and GC'd
/// with the process.
///
/// - `budget`: the finite reduction-style fuel bound — `instantiate/0` passes
///   `binding.fuel_budget` (which `safe_default()` seeds from `default_fuel_budget`). The
///   numeric bound is a seed value on the `Binding`, NOT a field of `MeterMode`.
/// - Return: always `Nil`. Total; never raises.
/// - Effect: stores `budget` in the per-process budget cell and zeroes the consumed counter.
///   A (re)instantiation re-seeds ⇒ a FRESH budget; two seed cycles in one reused process
///   never observe each other's remaining fuel (the reset is atomic — one `put` per key).
///   Once seeded, `charge` ENFORCES this budget (unit 05): the first charge whose running
///   total exceeds `budget` raises `FuelExhausted`.
pub fn seed_fuel(budget: Int) -> Nil {
  let _ = erlang_put(CarderRtMeterBudget, budget)
  reset_fuel()
}

/// Charge `cost` fuel against the current process's running total (ABI UNCHANGED — arity 1,
/// returns `Nil`), enforcing the seeded budget.
///
/// - `cost`: a non-negative cost-model unit (§ module docs) for the work about to run.
///   (Negative values are added as-is; the contract assumes `cost >= 0` and codegen only ever
///   passes non-negative costs.)
/// - Effect: advance the consumed total by `cost`, RECORDING it FIRST (via `erlang:put`), so
///   `fuel_consumed()` stays accurate even at the trap. THEN, iff a budget was seeded and the
///   new total STRICTLY exceeds it (`consumed > budget`), raise `FuelExhausted` via
///   `rt_trap.raise` — surfacing as the catchable `{wasm_trap, fuel_exhausted}` the run-ABI
///   already catches (F5/F7). The comparison is strict, so a run that spends EXACTLY its
///   budget completes; the charge that would push it over traps. Process-local, so concurrent
///   processes meter independently.
/// - Return: `Nil` on a within-budget charge; DIVERGES (never returns) on exhaustion — typed
///   `-> Nil` because `rt_trap.raise` has bottom type `a`, which unifies with `Nil`.
///
/// **Un-seeded posture (legacy/test only).** If NO budget was seeded (`budget()` is
/// `Error(Nil)`), `charge` NEVER raises — it accumulates only. This is the Phase-1/2
/// observe-only behavior, retained solely for back-compat: the legacy suite (and any code)
/// that charges without seeding stays green. It is NOT the default of a metered build. A
/// `MeterFuel` artifact is fail-closed by construction (D4): its `instantiate/0` seeds the
/// budget as its FIRST effect and the run-ABI instantiates before every invoke, so NO charged
/// code in a Safe instance ever executes against an un-seeded budget; `MeterOff` inserts no
/// `Charge` sites at all. `charge` itself cannot distinguish "metered build that forgot to
/// seed" from "legacy test that charges without seeding" — both present as an absent budget
/// key — so hardening the un-seeded path to fail-closed here would break the legacy suite; the
/// fail-closed guarantee is instead enforced structurally by unit 09's seed-before-charge
/// ordering (a Verification item handed to units 09/11).
pub fn charge(cost: Int) -> Nil {
  let consumed = fuel_consumed() + cost
  let _ = erlang_put(CarderRtMeterFuel, consumed)
  case budget() {
    Ok(b) if consumed > b -> rt_trap.raise(FuelExhausted)
    _ -> Nil
  }
}

/// This process's seeded CPU-fuel budget, or `Error(Nil)` when un-seeded (the observe-only
/// sentinel). Private: the single chokepoint `charge` consults before enforcing.
///
/// - Return: `Ok(budget)` when `seed_fuel` has installed a budget in this process's
///   dictionary; `Error(Nil)` when the `CarderRtMeterBudget` key is absent (the BIF's
///   `undefined`, which fails to decode as an `Int`). Total; never raises.
fn budget() -> Result(Int, Nil) {
  case decode.run(erlang_get(CarderRtMeterBudget), decode.int) {
    Ok(b) -> Ok(b)
    Error(_) -> Error(Nil)
  }
}

/// The running fuel total charged in the **current process** so far.
///
/// - Return: the accumulated cost (`>= 0` in normal use), or `0` if `charge` has never
///   run in this process (the counter is absent — decoded from `undefined` to `0`).
///   Total; never raises. Reading it does not reset it.
/// - Use: test/observability support and the Phase-2 budget check; it is *not* part of
///   the generated-code calling convention.
pub fn fuel_consumed() -> Int {
  case decode.run(erlang_get(CarderRtMeterFuel), decode.int) {
    Ok(total) -> total
    Error(_) -> 0
  }
}

/// Zero the current process's fuel counter.
///
/// - Return: always `Nil`. Total; never raises.
/// - Use: test support (make a metering assertion independent of prior charges in this
///   process) and the future budget-reset hook. Not called by generated code.
pub fn reset_fuel() -> Nil {
  let _ = erlang_put(CarderRtMeterFuel, 0)
  Nil
}
