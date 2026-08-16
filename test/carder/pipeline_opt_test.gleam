//// Unit 09 — pipeline optimizer-wiring + Unsafe-binding integration tests.
////
//// These prove the three plumbing jobs of unit 09 against the SPEC (F1/F5, not the current
//// emitter output — no change-detector tests):
////
//// 1. The optimizer is a wired, bypass-correct, independently-invokable stage threaded into
////    `ir_to_core` between `ir_lower` and `emit_core`, and both profiles drive a working
////    end-to-end chain (`add(2,3) == 5`).
//// 2. For a metered function, Safe and Unsafe `.core` differ by EXACTLY the `charge`
////    instrumentation (in bodies) PLUS the `instantiate/0` seed lines — every non-instantiate
////    body is structurally IDENTICAL across postures (A.1), the one documented exception being
////    the `instantiate/0` seeds (§A.4).
//// 3. `optimize_ir` is the observable identity at the freeze (empty pass pipelines) — the F2
////    differential baseline — at both the Safe (`Baseline`) and Unsafe (`Aggressive`) levels.

import carder/backend/core_erlang.{type CModule, type FunDef, FName, FunDef}
import carder/backend/core_printer
import carder/backend/emit_core
import carder/ir
import carder/pipeline
import carder/runtime/instance.{type Binding}
import carder/runtime/profiles
import gleam/list
import gleam/option
import gleam/string

// ─────────────────────────────── fixtures ───────────────────────────────

/// A pure `add(i32, i32) -> i32` IR module (pre-`ir_lower`, so it carries NO `Charge` — the
/// metering is inserted by `ir_lower` under `MeterFuel`, which is exactly what the differential
/// tests exercise).
fn add_module() -> ir.Module {
  ir.Module(
    name: "addmod",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        name: "add",
        params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
        result: [ir.TI32],
        locals: [],
        body: ir.Let(
          ["r"],
          ir.Num(ir.IAdd(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
          ir.Return([ir.Var("r")]),
        ),
      ),
    ],
    exports: [ir.ExportFn("add", "add")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// A single-function `f(i32) -> i32` module whose body is exactly `body` — the minimal emit
/// fixture for the `Charge`-faithfulness golden.
fn single_fn_module(body: ir.Expr) -> ir.Module {
  ir.Module(
    name: "chgmod",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        name: "f",
        params: [ir.Local("p0", ir.TI32)],
        result: [ir.TI32],
        locals: [],
        body: body,
      ),
    ],
    exports: [ir.ExportFn("f", "f")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

// ─────────────────────────────── helpers ───────────────────────────────

/// The module's function defs EXCLUDING the synthesized `instantiate/0` (the one documented
/// posture exception, §A.4). Structural `==` over this list is the byte-identical-bodies check.
fn non_instantiate_defs(m: CModule) -> List(FunDef) {
  list.filter(m.defs, fn(d) {
    let FunDef(FName(n, _), _) = d
    n != "instantiate"
  })
}

/// The synthesized `instantiate/0` def (as a `Result`, for a direct `==` comparison).
fn instantiate_def(m: CModule) -> Result(FunDef, Nil) {
  list.find(m.defs, fn(d) {
    let FunDef(FName(n, _), _) = d
    n == "instantiate"
  })
}

/// Count non-overlapping occurrences of `needle` in `haystack`.
fn count_substr(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

/// The number of `rt_meter:charge` calls in the emitted module (counted from the printed
/// `.core`; `'charge'` is emitted only by the metering seam, never by another op).
fn count_charge_calls(m: CModule) -> Int {
  count_substr(core_printer.print_module(m), "'charge'")
}

/// Compile `add_module()` through the WHOLE `.ir → .core → .beam → instantiate → invoke` chain
/// under `binding`, invoking `add(a, b)`. Exercises the optimizer-in-pipeline and the
/// per-instance seeds (the instance runs `instantiate/0`, which seeds fuel + host policy).
fn run_add(binding: Binding, a: Int, b: Int) -> pipeline.RunResult {
  let m = add_module()
  let assert Ok(cmod) = pipeline.ir_to_cmod(m, binding)
  let assert Ok(beam) = pipeline.cmod_to_beam(cmod)
  let assert Ok(proc) = pipeline.instantiate(beam, m.name)
  let result = pipeline.invoke_instance(proc, "add", [a, b])
  pipeline.stop_instance(proc)
  result
}

// ─────────────────────────────── 1. both profiles run end-to-end ───────────────────────────────

/// The pipeline runs end-to-end under BOTH profiles, returning the SAME spec-correct result
/// (`add(2,3) == 5`). Proves the optimizer is threaded (the chain runs through `optimize_ir`)
/// and both bindings — Safe (`Baseline`, `MeterFuel`) and Unsafe (`Aggressive`, `MeterOff`) —
/// drive a working chain whose `instantiate/0` seeds load and run (F2 identity at freeze;
/// the Unsafe binding names working runtime modules). (DoD 1.)
pub fn pipeline_runs_end_to_end_under_both_profiles_test() {
  assert run_add(profiles.safe(), 2, 3) == pipeline.Returned([5])
  assert run_add(profiles.unsafe(), 2, 3) == pipeline.Returned([5])
}

// ─────────────────────────── 2. Safe/Unsafe differ by exactly charge + seeds ───────────────────────────

/// Emitting the SAME (un-lowered, charge-free) IR under `safe()` and `unsafe()` produces
/// byte-identical NON-instantiate bodies (A.1 — `emit_core` reads no policy field in a body),
/// while the `instantiate/0` def DIFFERS (its seed lines) — proving the exception is real, not
/// vacuous. (DoD 5 — bodies posture-agnostic at the emit level.)
pub fn emit_bodies_are_posture_agnostic_test() {
  let m = add_module()
  let assert Ok(safe_m) = emit_core.emit_module(m, profiles.safe())
  let assert Ok(unsafe_m) = emit_core.emit_module(m, profiles.unsafe())
  // Every non-instantiate def is structurally IDENTICAL across postures.
  assert non_instantiate_defs(safe_m) == non_instantiate_defs(unsafe_m)
  // The one documented exception: instantiate/0 differs by its seed lines.
  assert instantiate_def(safe_m) != instantiate_def(unsafe_m)
}

/// A metered function's Safe vs Unsafe `.core` differs by EXACTLY the charge instrumentation
/// (in bodies) plus the `instantiate/0` seed lines (F5 / overview §1). Compares
/// `ir_to_core(m, safe())` (metered) with `ir_to_core(m, unsafe())` (metering-free):
/// - bodies: Safe carries `charge` calls, Unsafe carries ZERO (zero-overhead, not no-ops);
/// - `instantiate/0`: `seed_fuel` present under Safe/`MeterFuel`, absent under Unsafe/`MeterOff`;
/// - `seed_policy` ALWAYS present, the baked literal (`host_deny_all` vs `host_open`) its only
///   difference. (DoD 2.)
pub fn charge_and_seed_differential_test() {
  let m = add_module()
  let assert Ok(safe_core) = pipeline.ir_to_core(m, profiles.safe())
  let assert Ok(unsafe_core) = pipeline.ir_to_core(m, profiles.unsafe())
  // Bodies: metered under Safe, metering-free under Unsafe.
  assert count_substr(safe_core, "'charge'") > 0
  assert count_substr(unsafe_core, "'charge'") == 0
  // instantiate/0 seed differential (§A.4).
  assert string.contains(safe_core, "'seed_fuel'")
  assert !string.contains(unsafe_core, "'seed_fuel'")
  assert string.contains(safe_core, "'seed_policy'('host_deny_all')")
  assert string.contains(unsafe_core, "'seed_policy'('host_open')")
}

/// Emit-level golden (body-faithful, posture-blind): a single `Charge(cost, body)` IR node
/// emits EXACTLY ONE `rt_meter:charge` call wrapping `body`; the SAME IR WITHOUT the `Charge`
/// wrapper emits ZERO — proving `emit_core` maps metering faithfully and adds none on its own.
/// (DoD 2, self-contained backing.)
pub fn emit_charge_is_faithful_golden_test() {
  let charged = single_fn_module(ir.Charge(5, ir.Return([ir.Var("p0")])))
  let assert Ok(cm) = emit_core.emit_module(charged, profiles.safe())
  assert count_charge_calls(cm) == 1

  let plain = single_fn_module(ir.Return([ir.Var("p0")]))
  let assert Ok(cm2) = emit_core.emit_module(plain, profiles.safe())
  assert count_charge_calls(cm2) == 0
}

// ─────────────────────────────── 3. optimize_ir is identity at the freeze ───────────────────────────────

/// `optimize_ir` is the observable IDENTITY at the freeze (empty pass pipelines) — the F2
/// differential baseline — at BOTH the Safe (`Baseline`) and Unsafe (`Aggressive`) levels,
/// reading the level from `binding.opt_level` (F7). When units 03/04 register real passes this
/// relaxes to semantics-preserving (owned by 03/04/11); the wiring proven here stays. (DoD 3.)
pub fn optimize_ir_is_identity_at_freeze_test() {
  let m = add_module()
  assert pipeline.optimize_ir(m, profiles.safe()) == m
  assert pipeline.optimize_ir(m, profiles.unsafe()) == m
}
