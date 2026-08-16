//// Phase-10 unit 02 — tests for loop-invariant code motion (`ir_opt/licm`).
////
//// STRUCTURAL tests assert an invariant binding is hoisted to a preheader (including the load-bearing
//// case where the invariant work sits INSIDE the condition-guarded `If` branch — the WASM-lowered
//// loop shape), the moving frontier (a binding depending on an already-hoisted one hoists too), and
//// the ADVERSARIAL cases (a loop-var-dependent or effectful/trapping binding is NOT hoisted).
//// END-TO-END tests run the loop on the BEAM and assert value + trap are unchanged. Spec-first (D8):
//// LICM hoists only PURE invariant work, so hoisting is value-exact + speculation/zero-trip-safe.

import carder/ir
import carder/middle/ir_opt/licm
import carder/middle/ir_opt/pass
import carder/pipeline
import carder/runtime/profiles
import gleam/list
import gleam/option

fn imul(a: ir.Value, b: ir.Value) -> ir.Expr {
  ir.Num(ir.IMul(ir.W32), [a, b])
}

fn iadd(a: ir.Value, b: ir.Value) -> ir.Expr {
  ir.Num(ir.IAdd(ir.W32), [a, b])
}

/// Run `licm_pass()` (in isolation) over a one-function module and return the optimized body.
fn licm(slots: List(ir.Local), body: ir.Expr) -> ir.Expr {
  let m = one_fn_module(slots, body)
  let opt = pass.run_pipeline(m, [licm.licm_pass()])
  let assert [f] = opt.functions
  f.body
}

// The kernel: sumk(n,a,b) = { acc=0; for i in 0..n: acc += a*b; return acc } = a*b*n.
// The invariant `k = a*b` lives INSIDE the loop's condition-guarded body branch.
fn sumk_body() -> ir.Expr {
  ir.Loop(
    "l",
    [
      ir.LoopParam("i", ir.TI32, ir.ConstI32(0)),
      ir.LoopParam("acc", ir.TI32, ir.ConstI32(0)),
    ],
    [ir.TI32],
    ir.Let(
      ["done"],
      ir.Num(ir.IGeU(ir.W32), [ir.Var("i"), ir.Var("n")]),
      ir.If(
        ir.Var("done"),
        [ir.TI32],
        ir.Break("l", [ir.Var("acc")]),
        ir.Let(
          ["k"],
          imul(ir.Var("a"), ir.Var("b")),
          ir.Let(
            ["acc2"],
            iadd(ir.Var("acc"), ir.Var("k")),
            ir.Let(
              ["i2"],
              iadd(ir.Var("i"), ir.ConstI32(1)),
              ir.Continue("l", [ir.Var("i2"), ir.Var("acc2")]),
            ),
          ),
        ),
      ),
    ),
  )
}

fn sumk_slots() -> List(ir.Local) {
  [
    ir.Local("n", ir.TI32),
    ir.Local("a", ir.TI32),
    ir.Local("b", ir.TI32),
  ]
}

// ─────────────────────────── the hoist fires (from inside the If branch) ───────────────────────────

pub fn invariant_binding_is_hoisted_to_a_preheader_test() {
  // The invariant `k = a*b` (inside the guarded branch) is lifted to a preheader wrapping the loop.
  let out = licm(sumk_slots(), sumk_body())
  let assert ir.Let(["k"], rhs, ir.Loop(_, _, _, loop_body)) = out
  assert rhs == imul(ir.Var("a"), ir.Var("b"))
  // and `k` is no longer bound INSIDE the loop body (it survives only as a reference).
  assert !binds_name(loop_body, "k")
}

pub fn moving_frontier_hoists_dependent_invariant_test() {
  // let k = a*b (invariant); let m = k + c (depends on the hoisted k + external c) — BOTH hoist.
  let body =
    ir.Loop(
      "l",
      [ir.LoopParam("i", ir.TI32, ir.ConstI32(0))],
      [ir.TI32],
      ir.Let(
        ["k"],
        imul(ir.Var("a"), ir.Var("b")),
        ir.Let(
          ["m"],
          iadd(ir.Var("k"), ir.Var("c")),
          ir.Break("l", [ir.Var("m")]),
        ),
      ),
    )
  let slots = [
    ir.Local("a", ir.TI32),
    ir.Local("b", ir.TI32),
    ir.Local("c", ir.TI32),
  ]
  // both k and m are hoisted, in dependency order: Let(k, .., Let(m, .., Loop)).
  let assert ir.Let(["k"], _, ir.Let(["m"], _, ir.Loop(_, _, _, loop_body))) =
    licm(slots, body)
  assert !binds_name(loop_body, "k")
  assert !binds_name(loop_body, "m")
}

// ─────────────────────────── adversarial "must NOT hoist" ───────────────────────────

pub fn loop_variant_binding_is_not_hoisted_test() {
  // `x = i + 1` references the loop variable i → NOT invariant, stays in the loop.
  let body =
    ir.Loop(
      "l",
      [ir.LoopParam("i", ir.TI32, ir.ConstI32(0))],
      [ir.TI32],
      ir.Let(
        ["x"],
        iadd(ir.Var("i"), ir.ConstI32(1)),
        ir.Break("l", [ir.Var("x")]),
      ),
    )
  // unchanged — no preheader introduced (the outermost node is still the Loop).
  let assert ir.Loop(_, _, _, loop_body) = licm([], body)
  assert binds_name(loop_body, "x")
}

pub fn effectful_binding_is_not_hoisted_test() {
  // `v = load(p)` is effectful (reads memory) → NOT hoisted even though p is loop-external.
  let body =
    ir.Loop(
      "l",
      [ir.LoopParam("i", ir.TI32, ir.ConstI32(0))],
      [ir.TI32],
      ir.Let(
        ["v"],
        ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("p"), 0, ir.TI32),
        ir.Break("l", [ir.Var("v")]),
      ),
    )
  let assert ir.Loop(_, _, _, loop_body) = licm([ir.Local("p", ir.TI32)], body)
  assert binds_name(loop_body, "v")
}

pub fn trapping_binding_is_not_hoisted_test() {
  // `q = a / b` is a trapping div (not pure) → NOT hoisted (hoisting could add/move a trap).
  let body =
    ir.Loop(
      "l",
      [ir.LoopParam("i", ir.TI32, ir.ConstI32(0))],
      [ir.TI32],
      ir.Let(
        ["q"],
        ir.Num(ir.IDivS(ir.W32), [ir.Var("a"), ir.Var("b")]),
        ir.Break("l", [ir.Var("q")]),
      ),
    )
  let slots = [ir.Local("a", ir.TI32), ir.Local("b", ir.TI32)]
  let assert ir.Loop(_, _, _, loop_body) = licm(slots, body)
  assert binds_name(loop_body, "q")
}

// ─────────────────────────── end-to-end on the real BEAM ───────────────────────────

pub fn licm_preserves_the_loop_result_on_beam_test() {
  // sumk(10, 3, 4) = 3*4*10 = 120 — the same under LICM and unoptimized.
  let m = sumk_module()
  let opt = pass.run_pipeline(m, [licm.licm_pass()])
  assert run(m, "sumk", [10, 3, 4]) == run(opt, "sumk", [10, 3, 4])
  assert run(opt, "sumk", [10, 3, 4]) == pipeline.Returned([120])
}

// ─────────────────────────── helpers ───────────────────────────

/// Does `e` (recursively) BIND `name` at a `Let`/`Loop`-param position (i.e. is the binding still
/// inside the loop body)? Used to check a hoisted binding was removed from the loop.
fn binds_name(e: ir.Expr, name: String) -> Bool {
  case e {
    ir.Let(names, rhs, body) ->
      list.contains(names, name)
      || binds_name(rhs, name)
      || binds_name(body, name)
    ir.Loop(_, params, _, body) ->
      list.any(params, fn(p) { p.name == name }) || binds_name(body, name)
    ir.Block(_, _, body) -> binds_name(body, name)
    ir.Charge(_, body) -> binds_name(body, name)
    ir.If(_, _, t, el) -> binds_name(t, name) || binds_name(el, name)
    ir.Switch(_, _, arms, def) ->
      binds_name(def, name)
      || list.any(arms, fn(a) { binds_name(a.body, name) })
    ir.Try(_, body, hs) ->
      binds_name(body, name)
      || list.any(hs, fn(h) { binds_name(h.handler, name) })
    _ -> False
  }
}

fn one_fn_module(slots: List(ir.Local), body: ir.Expr) -> ir.Module {
  ir.Module(
    name: "carder@opt@licm_test",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [ir.Function("f", slots, [ir.TI32], [], body)],
    exports: [],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

fn sumk_module() -> ir.Module {
  ir.Module(
    name: "carder@opt@licm_sumk",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [ir.Function("sumk", sumk_slots(), [ir.TI32], [], sumk_body())],
    exports: [ir.ExportFn("sumk", "sumk")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

fn run(m: ir.Module, export: String, args: List(Int)) -> pipeline.RunResult {
  let assert Ok(cmod) = pipeline.ir_to_cmod(m, profiles.safe())
  let assert Ok(beam) = pipeline.cmod_to_beam(cmod)
  let assert Ok(proc) = pipeline.instantiate(beam, m.name)
  let out = pipeline.invoke_instance(proc, export, args)
  pipeline.stop_instance(proc)
  out
}
