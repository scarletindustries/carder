//// Phase-10 unit 07 (capstone) — the wiring proof.
////
//// The whole-corpus/spec/tier `OptNone ≡ Baseline ≡ Aggressive` differential (semantics preservation
//// across every tier + both modes) lives in `differential_test.gleam` + the tier-matrix suites and is
//// GREEN with LICM + cross-CF + BCE wired. THIS file adds the Phase-10-specific evidence: that LICM
//// and BCE actually FIRE in the wired `Baseline` pipeline, that the fixpoint CONVERGES (BCE is
//// node-adding but idempotent — N7), and that a program each pass transforms runs byte-identically at
//// `OptNone` and `Baseline` on real BEAM (value + trap).

import carder/ir
import carder/middle/ir_opt
import carder/opt_level.{type OptLevel, Baseline, OptNone}
import carder/pipeline
import carder/runtime/instance.{Binding}
import carder/runtime/profiles
import gleam/list
import gleam/option

// ─────────────────────────── LICM fires in the wired pipeline ───────────────────────────

pub fn licm_fires_in_baseline_pipeline_test() {
  // sumk(n,a,b): acc += a*b each iteration. The invariant a*b is hoisted out of the loop, so the
  // optimized module has NO `IMul` node left inside the loop body.
  let m = sumk_module()
  let opt = ir_opt.optimize(m, Baseline)
  let assert [f] = opt.functions
  assert imuls_inside_loops(f.body) == 0
  // it also runs correctly + identically to OptNone: sumk(10,3,4) = 3*4*10 = 120.
  assert run(m, OptNone, "sumk", [10, 3, 4]) == pipeline.Returned([120])
  assert run(m, Baseline, "sumk", [10, 3, 4])
    == run(m, OptNone, "sumk", [10, 3, 4])
}

// ─────────────────────────── BCE fires in the wired pipeline ───────────────────────────

pub fn bce_fires_in_baseline_pipeline_test() {
  // The affine-cursor sumbuf loop is versioned: the optimized module contains an unchecked access.
  let m = sumbuf_module()
  let opt = ir_opt.optimize(m, Baseline)
  let assert [f] = opt.functions
  assert contains_unchecked(f.body)
  // value preserved (sumbuf over [1,2,3,4] with n=16 → 10) and OOB trap preserved.
  assert run(m, Baseline, "sumbuf", [16]) == pipeline.Returned([10])
  assert run(m, Baseline, "sumbuf", [16]) == run(m, OptNone, "sumbuf", [16])
  let base_oob = run(m, Baseline, "sumbuf", [9_000_000])
  assert base_oob == run(m, OptNone, "sumbuf", [9_000_000])
  let assert pipeline.Trapped(_) = base_oob
}

// ─────────────────────────── the fixpoint converges (N7) ───────────────────────────

pub fn optimize_converges_on_licm_and_bce_kernels_test() {
  // BCE is node-adding but idempotent; re-optimizing the optimized module is a no-op.
  let a = ir_opt.optimize(sumk_module(), Baseline)
  assert ir_opt.optimize(a, Baseline) == a
  let b = ir_opt.optimize(sumbuf_module(), Baseline)
  assert ir_opt.optimize(b, Baseline) == b
}

// ─────────────────────────── kernels ───────────────────────────

fn iadd(a: ir.Value, b: ir.Value) -> ir.Expr {
  ir.Num(ir.IAdd(ir.W32), [a, b])
}

fn sumk_module() -> ir.Module {
  let body =
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
            ir.Num(ir.IMul(ir.W32), [ir.Var("a"), ir.Var("b")]),
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
  ir.Module(
    name: "carder@opt@p10_sumk",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        "sumk",
        [
          ir.Local("n", ir.TI32),
          ir.Local("a", ir.TI32),
          ir.Local("b", ir.TI32),
        ],
        [ir.TI32],
        [],
        body,
      ),
    ],
    exports: [ir.ExportFn("sumk", "sumk")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

fn sumbuf_module() -> ir.Module {
  let body =
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
            ["x"],
            ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("i"), 0, ir.TI32),
            ir.Let(
              ["acc2"],
              iadd(ir.Var("acc"), ir.Var("x")),
              ir.Let(
                ["i2"],
                iadd(ir.Var("i"), ir.ConstI32(4)),
                ir.Continue("l", [ir.Var("i2"), ir.Var("acc2")]),
              ),
            ),
          ),
        ),
      ),
    )
  ir.Module(
    name: "carder@opt@p10_sumbuf",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function("sumbuf", [ir.Local("n", ir.TI32)], [ir.TI32], [], body),
    ],
    exports: [ir.ExportFn("sumbuf", "sumbuf")],
    data_segments: [
      ir.DataSegment(ir.DataActive(0, ir.Values([ir.ConstI32(0)])), <<
        1,
        0,
        0,
        0,
        2,
        0,
        0,
        0,
        3,
        0,
        0,
        0,
        4,
        0,
        0,
        0,
      >>),
    ],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

// ─────────────────────────── scans + run ───────────────────────────

/// Count `IMul` nodes that appear INSIDE a `Loop` body (LICM should hoist a loop-invariant multiply
/// out, leaving zero).
fn imuls_inside_loops(e: ir.Expr) -> Int {
  case e {
    ir.Loop(_, _, _, body) -> count_imuls(body)
    ir.Let(_, rhs, body) -> imuls_inside_loops(rhs) + imuls_inside_loops(body)
    ir.Block(_, _, body) -> imuls_inside_loops(body)
    ir.Charge(_, body) -> imuls_inside_loops(body)
    ir.If(_, _, t, el) -> imuls_inside_loops(t) + imuls_inside_loops(el)
    ir.Switch(_, _, arms, def) ->
      list.fold(arms, imuls_inside_loops(def), fn(a, arm) {
        a + imuls_inside_loops(arm.body)
      })
    ir.Try(_, body, hs) ->
      list.fold(hs, imuls_inside_loops(body), fn(a, h) {
        a + imuls_inside_loops(h.handler)
      })
    _ -> 0
  }
}

fn count_imuls(e: ir.Expr) -> Int {
  let here = case e {
    ir.Num(ir.IMul(_), _) -> 1
    _ -> 0
  }
  here
  + case e {
    ir.Let(_, rhs, body) -> count_imuls(rhs) + count_imuls(body)
    ir.Block(_, _, body) -> count_imuls(body)
    ir.Loop(_, _, _, body) -> count_imuls(body)
    ir.Charge(_, body) -> count_imuls(body)
    ir.If(_, _, t, el) -> count_imuls(t) + count_imuls(el)
    ir.Switch(_, _, arms, def) ->
      list.fold(arms, count_imuls(def), fn(a, arm) { a + count_imuls(arm.body) })
    ir.Try(_, body, hs) ->
      list.fold(hs, count_imuls(body), fn(a, h) { a + count_imuls(h.handler) })
    _ -> 0
  }
}

fn contains_unchecked(e: ir.Expr) -> Bool {
  case e {
    ir.MemLoadUnchecked(_, _, _, _, _) | ir.MemStoreUnchecked(_, _, _, _, _) ->
      True
    ir.Let(_, rhs, body) -> contains_unchecked(rhs) || contains_unchecked(body)
    ir.Block(_, _, body) -> contains_unchecked(body)
    ir.Loop(_, _, _, body) -> contains_unchecked(body)
    ir.Charge(_, body) -> contains_unchecked(body)
    ir.If(_, _, t, el) -> contains_unchecked(t) || contains_unchecked(el)
    ir.Switch(_, _, arms, def) ->
      contains_unchecked(def)
      || list.any(arms, fn(a) { contains_unchecked(a.body) })
    ir.Try(_, body, hs) ->
      contains_unchecked(body)
      || list.any(hs, fn(h) { contains_unchecked(h.handler) })
    _ -> False
  }
}

fn run(
  m: ir.Module,
  level: OptLevel,
  export: String,
  args: List(Int),
) -> pipeline.RunResult {
  let binding = Binding(..profiles.safe(), opt_level: level)
  let assert Ok(cmod) = pipeline.ir_to_cmod(m, binding)
  let assert Ok(beam) = pipeline.cmod_to_beam(cmod)
  let assert Ok(proc) = pipeline.instantiate(beam, m.name)
  let out = pipeline.invoke_instance(proc, export, args)
  pipeline.stop_instance(proc)
  out
}
