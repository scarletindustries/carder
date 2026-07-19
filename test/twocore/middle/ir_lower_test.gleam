//// Unit 11a tests — the IR→IR Safe POLICY pass, asserted against the policy/spec, not the
//// emitter's output (D8). Two layers:
////   - IR-level: hand-written `ir.Module` fixtures prove the capability gate (fail-closed)
////     and the `Charge` insertion structurally;
////   - end-to-end: a fixture is lowered → emitted → built → loaded → run, proving metering
////     ACCUMULATES while results are UNCHANGED and the constant-space loop stays bounded
////     with metering on (overview §11a verification).

import gleam/list
import gleam/option
import gleam/set
import twocore/ir
import twocore/middle/ir_lower
import twocore/pipeline
import twocore/runtime/profiles
import twocore/runtime/rt_bif
import twocore/runtime/rt_meter

// ─────────────────────────────── fixtures ───────────────────────────────

fn module_with(
  fns: List(ir.Function),
  imports: List(ir.ImportDecl),
) -> ir.Module {
  ir.Module(
    name: "twocore@test@m",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: imports,
    functions: fns,
    exports: list.map(fns, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// A function whose body issues a single `CallHost(capability, name, args)`.
fn call_host_fn(
  fn_name: String,
  capability: String,
  name: String,
  args: List(ir.Value),
) -> ir.Function {
  ir.Function(
    name: fn_name,
    params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.CallHost(capability, name, args),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// A plain numeric function with NO `CallHost` (used to prove the function-body `Charge`).
fn add_fn() -> ir.Function {
  ir.Function(
    name: "add",
    params: [ir.Local("p0", ir.TI64), ir.Local("p1", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.Num(ir.IAdd(ir.W64), [ir.Var("p0"), ir.Var("p1")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// `sum_to(n) == n*(n+1)/2` via a loop/break/continue (the constant-space template).
fn sum_to_fn() -> ir.Function {
  ir.Function(
    name: "sum_to",
    params: [ir.Local("p0", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Loop(
      label: "go",
      params: [
        ir.LoopParam("i", ir.TI64, ir.ConstI64(1)),
        ir.LoopParam("acc", ir.TI64, ir.ConstI64(0)),
      ],
      result: [ir.TI64],
      body: ir.Let(
        ["cond"],
        ir.Num(ir.ILeU(ir.W64), [ir.Var("i"), ir.Var("p0")]),
        ir.If(
          cond: ir.Var("cond"),
          result: [ir.TI64],
          then_branch: ir.Let(
            ["acc1"],
            ir.Num(ir.IAdd(ir.W64), [ir.Var("acc"), ir.Var("i")]),
            ir.Let(
              ["i1"],
              ir.Num(ir.IAdd(ir.W64), [ir.Var("i"), ir.ConstI64(1)]),
              ir.Continue("go", [ir.Var("i1"), ir.Var("acc1")]),
            ),
          ),
          else_branch: ir.Break("go", [ir.Var("acc")]),
        ),
      ),
    ),
  )
}

// ─────────────────────────────── the capability gate (fail-closed) ───────────────────────────────

/// An allowlisted `own`-stdlib call (`("std","gcd")` at the right arity) is PERMITTED, and
/// the `CallHost` node is preserved unchanged (emit_core routes it) inside the inserted
/// `Charge`. Pinned triple — state.md.
pub fn stdlib_gcd_permitted_test() {
  let m =
    module_with(
      [call_host_fn("g", "std", "gcd", [ir.Var("p0"), ir.Var("p1")])],
      [],
    )
  let assert Ok(out) = ir_lower.lower(m, profiles.safe())
  let assert [f] = out.functions
  // body is wrapped in Charge; the CallHost survives unchanged within.
  let assert ir.Charge(_cost, ir.Let(["r"], rhs, _)) = f.body
  assert rhs == ir.CallHost("std", "gcd", [ir.Var("p0"), ir.Var("p1")])
}

/// A stdlib call to a name NOT on the `own` surface is rejected fail-closed with
/// `UnknownStdlibFn` (never a panic).
pub fn unknown_stdlib_fn_rejected_test() {
  let m =
    module_with([call_host_fn("g", "std", "frobnicate", [ir.Var("p0")])], [])
  assert ir_lower.lower(m, profiles.safe())
    == Error(ir_lower.UnknownStdlibFn("std", "frobnicate"))
}

/// A stdlib `gcd` call at the WRONG arity resolves to a target absent from the `rt_bif`
/// allowlist (`gcd/1`, not `gcd/2`) and is rejected fail-closed with `BifNotAllowed`.
pub fn stdlib_wrong_arity_rejected_test() {
  let m = module_with([call_host_fn("g", "std", "gcd", [ir.Var("p0")])], [])
  assert ir_lower.lower(m, profiles.safe())
    == Error(ir_lower.BifNotAllowed("gcd"))
}

/// A `CallHost` to a DECLARED host import (present in `module.imports`) is LEFT UNCHANGED —
/// it is rejected at RUN time by the deny-all host, not at build time (overview pitfall #3).
pub fn declared_host_import_permitted_test() {
  let imports = [
    ir.ImportFn("env", "log", ir.FuncType([ir.TI32], [ir.TI32])),
  ]
  let m =
    module_with([call_host_fn("u", "env", "log", [ir.Var("p0")])], imports)
  let assert Ok(out) = ir_lower.lower(m, profiles.safe())
  let assert [f] = out.functions
  let assert ir.Charge(_cost, ir.Let(["r"], rhs, _)) = f.body
  assert rhs == ir.CallHost("env", "log", [ir.Var("p0")])
}

/// A `CallHost` to a capability that is NEITHER the stdlib capability NOR a declared import
/// is rejected here, fail-closed, with `ForbiddenHost` (an un-allowlisted capability with no
/// provenance).
pub fn undeclared_host_rejected_test() {
  let m = module_with([call_host_fn("e", "evil", "run", [ir.Var("p0")])], [])
  assert ir_lower.lower(m, profiles.safe())
    == Error(ir_lower.ForbiddenHost("evil", "run"))
}

// ─────────────────────────────── metering insertion (the seam) ───────────────────────────────

/// Every function body gains a `Charge(_, _)` at its head (the metering seam exists, D9).
pub fn function_body_metered_test() {
  let m = module_with([add_fn()], [])
  let assert Ok(out) = ir_lower.lower(m, profiles.safe())
  let assert [f] = out.functions
  // the original body is now wrapped in a Charge; the inner body is unchanged.
  let assert ir.Charge(_cost, inner) = f.body
  assert inner == add_fn().body
}

/// A `Loop` body is wrapped in its own `Charge` so each iteration is metered, AND the
/// loop's label/params/result are untouched (so emit_core's constant-space lowering still
/// applies).
pub fn loop_body_metered_test() {
  let m = module_with([sum_to_fn()], [])
  let assert Ok(out) = ir_lower.lower(m, profiles.safe())
  let assert [f] = out.functions
  // function body: Charge(fn) wrapping the Loop, whose body is Charge(loop) wrapping the
  // original loop body.
  let assert ir.Charge(_fn_cost, ir.Loop(label, params, result, loop_body)) =
    f.body
  assert label == "go"
  assert params == sum_to_fn_params()
  assert result == [ir.TI64]
  let assert ir.Charge(_loop_cost, original_loop_body) = loop_body
  assert original_loop_body == sum_to_loop_body()
}

fn sum_to_fn_params() -> List(ir.LoopParam) {
  let assert ir.Loop(_, params, _, _) = sum_to_fn().body
  params
}

fn sum_to_loop_body() -> ir.Expr {
  let assert ir.Loop(_, _, _, body) = sum_to_fn().body
  body
}

// ─────────────────────────────── Phase-3 Unsafe posture (F5/F6/F7) ───────────────────────────────

/// Recursively count every `ir.Charge` node in `expr` (only `Charge`, `Let`, `Block`, `Loop`,
/// `If`, `Switch` bear sub-expressions; every other node is a leaf). Used to prove metering
/// PRESENCE (`MeterFuel`) / ABSENCE (`MeterOff`, F5 zero-overhead) structurally.
fn count_charge(expr: ir.Expr) -> Int {
  case expr {
    ir.Charge(_cost, body) -> 1 + count_charge(body)
    ir.Let(_, rhs, body) -> count_charge(rhs) + count_charge(body)
    ir.Block(_, _, body) -> count_charge(body)
    ir.Loop(_, _, _, body) -> count_charge(body)
    ir.If(_, _, then_b, else_b) -> count_charge(then_b) + count_charge(else_b)
    ir.Switch(_, _, arms, default) ->
      list.fold(arms, count_charge(default), fn(acc, arm) {
        acc + count_charge(arm.body)
      })
    _ -> 0
  }
}

/// Total `ir.Charge` nodes across every function body of `module`.
fn count_charge_module(module: ir.Module) -> Int {
  list.fold(module.functions, 0, fn(acc, f) { acc + count_charge(f.body) })
}

/// F5 zero-overhead: under the real `profiles.unsafe()` posture (`meter: MeterOff`) lowering a
/// module with a plain function AND a function containing a `Loop` inserts **no `ir.Charge`
/// node at all** — neither the function-entry wrapper nor the per-loop `Charge`. Absence, not
/// `Charge(0, …)`.
pub fn meter_off_inserts_zero_charge_test() {
  let m = module_with([add_fn(), sum_to_fn()], [])
  let assert Ok(out) = ir_lower.lower(m, profiles.unsafe())
  assert count_charge_module(out) == 0
}

/// The metering contract re-asserted (not a lock-in of magnitudes): under `profiles.safe()`
/// (`meter: MeterFuel`) each function body is wrapped in exactly one `Charge` and each `Loop`
/// body in exactly one `Charge`, so the total is `#functions + #loops` (here 2 + 1 == 3).
pub fn meter_fuel_inserts_phase2_charges_test() {
  let m = module_with([add_fn(), sum_to_fn()], [])
  let assert Ok(out) = ir_lower.lower(m, profiles.safe())
  assert count_charge_module(out) == 3
}

/// F6 passthrough resolution: a shared-stdlib `gcd/2` resolves to the SAME
/// `stdlib_module` target under BOTH postures (passthrough ≡ own for the Phase-3 corpus, since
/// `gcd` has no active passthrough route). The emitted module atom is invariably
/// `binding.stdlib_module`, never a raw BEAM module.
pub fn passthrough_resolution_picks_stdlib_module_target_test() {
  let safe = profiles.safe()
  let unsafe = profiles.unsafe()
  let own_target =
    rt_bif.BifTarget(module: safe.stdlib_module, function: "gcd", arity: 2)
  assert ir_lower.resolve_stdlib_fn("gcd", 2, safe) == Ok(own_target)
  assert ir_lower.resolve_stdlib_fn("gcd", 2, unsafe) == Ok(own_target)
}

/// The extended anti-drift cross-check (§C.3): the passthrough surface resolves to the SAME
/// targets as the `own` surface (F6: passthrough ≡ own; zero active routes) and both equal the
/// `rt_bif` allowlist — so own/passthrough resolution cannot silently drift from unit 06.
pub fn passthrough_targets_match_own_and_allowlist_test() {
  let own = set.from_list(ir_lower.resolved_stdlib_targets(profiles.safe()))
  let passthrough =
    set.from_list(ir_lower.resolved_stdlib_targets(profiles.unsafe()))
  let allowed = set.from_list(rt_bif.allowlist())
  assert passthrough == own
  assert passthrough == allowed
}

/// F6 open admits / allowlist rejects: a `gcd/1` `CallHost` resolves to `rt_stdlib:gcd/1`, a
/// build-controlled target that is OFF the allowlist (only `gcd/2` is on it). Under Safe
/// (`BifAllowlist`) the same call is rejected fail-closed; under Unsafe (`BifOpen`) it is
/// admitted (and, under `MeterOff`, no `Charge` is inserted, so the module is returned
/// unchanged).
pub fn open_admits_target_allowlist_rejects_test() {
  let m = module_with([call_host_fn("g", "std", "gcd", [ir.Var("p0")])], [])
  assert ir_lower.lower(m, profiles.safe())
    == Error(ir_lower.BifNotAllowed("gcd"))
  assert ir_lower.lower(m, profiles.unsafe()) == Ok(m)
}

/// D3a preserved under `open` (§A.3): the open BIF gate is NOT open provenance. An UNRESOLVED
/// stdlib name still fails `UnknownStdlibFn` (open admits only resolved targets), and an
/// UNDECLARED non-stdlib capability still fails `ForbiddenHost` (host provenance is fail-closed
/// under every posture).
pub fn open_still_rejects_unknown_and_undeclared_host_test() {
  let unknown =
    module_with([call_host_fn("g", "std", "frobnicate", [ir.Var("p0")])], [])
  assert ir_lower.lower(unknown, profiles.unsafe())
    == Error(ir_lower.UnknownStdlibFn("std", "frobnicate"))

  let undeclared =
    module_with([call_host_fn("e", "evil", "run", [ir.Var("p0")])], [])
  assert ir_lower.lower(undeclared, profiles.unsafe())
    == Error(ir_lower.ForbiddenHost("evil", "run"))
}

// ─────────────────────────────── anti-drift cross-check (policy == rt_bif) ───────────────────────────────

/// The `own`-stdlib surface this pass resolves to MUST equal the `rt_bif` allowlist, so the
/// policy here and the allowlist in unit 09 cannot silently diverge (overview §11a). Compare
/// as sets.
pub fn stdlib_surface_matches_rt_bif_allowlist_test() {
  let resolved =
    set.from_list(ir_lower.resolved_stdlib_targets(profiles.safe()))
  let allowed = set.from_list(rt_bif.allowlist())
  assert resolved == allowed
}

// ─────────────────────────────── end-to-end: metering + results unchanged ───────────────────────────────

/// Compile `m` through the Safe pipeline (ir_lower → emit → build) and invoke `export`,
/// returning the run result and the fuel charged DURING the call (the pdict counter is
/// per-process; gleeunit runs each test synchronously in one process).
fn run_metered(
  m: ir.Module,
  export: String,
  args: List(Int),
) -> #(pipeline.RunResult, Int) {
  let assert Ok(cmod) = pipeline.ir_to_cmod(m, profiles.safe())
  let assert Ok(beam) = pipeline.cmod_to_beam(cmod)
  rt_meter.reset_fuel()
  let result = pipeline.invoke(beam, m.name, export, args)
  #(result, rt_meter.fuel_consumed())
}

/// A no-loop function charges EXACTLY once (the function-body `Charge`) per call, and the
/// metering does NOT change the result: `add(7, 35) == 42`, fuel == 1.
pub fn function_charge_counts_and_result_unchanged_test() {
  let m =
    ir.Module(..module_with([add_fn()], []), name: "twocore@test@add_metered")
  let #(result, fuel) = run_metered(m, "add", [7, 35])
  assert result == pipeline.Returned([42])
  assert fuel == 1
}

/// The constant-space loop runs WITH metering on: `sum_to(10) == 55` and
/// `sum_to(100000) == 5000050000` (the large case completes without unbounded stack growth,
/// proving the loop back-edge stayed in tail position despite the inserted `Charge`). The
/// fuel ACCUMULATES proportionally to iterations: each extra iteration adds exactly one loop
/// charge, so `fuel(100000) - fuel(10) == 100000 - 10`.
pub fn loop_constant_space_with_metering_test() {
  let m =
    ir.Module(
      ..module_with([sum_to_fn()], []),
      name: "twocore@test@sum_metered",
    )
  let #(r10, fuel10) = run_metered(m, "sum_to", [10])
  let #(r_big, fuel_big) = run_metered(m, "sum_to", [100_000])
  assert r10 == pipeline.Returned([55])
  assert r_big == pipeline.Returned([5_000_050_000])
  // accumulation is proportional to loop work (slope exactly 1 charge / iteration).
  assert fuel_big - fuel10 == 100_000 - 10
  // and the function-entry + loop-entry model: fuel(n) == n + 2.
  assert fuel10 == 12
}
