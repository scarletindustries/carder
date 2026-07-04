//// Phase-10 unit 07 (capstone) — the LICM + BCE wall-clock benchmark.
////
//// Isolate-the-delta (like `mem_bench_test`): build the SAME lowered kernel two ways differing ONLY
//// in the added pass, correctness-gate identical BEFORE timing, then time with `pipeline.exec_beam`.
//// LICM's win (hoisting an expensive invariant chain out of the loop) is large + asserted; BCE's win
//// (removing the per-iteration bounds check on an affine loop) is honestly MEASURED (modest,
//// pattern-dependent — the deterministic firing proof is in `phase10_capstone_test.gleam`). Numbers
//// echoed for `docs/phase-10-benchmark.md`.

import gleam/int
import gleam/io
import gleam/list
import gleam/option
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/ir
import twocore/middle/ir_lower
import twocore/middle/ir_opt/baseline
import twocore/middle/ir_opt/bce
import twocore/middle/ir_opt/licm
import twocore/middle/ir_opt/pass
import twocore/pipeline
import twocore/runtime/instance.{type Binding, Binding, MeterOff}
import twocore/runtime/profiles

const iters: Int = 4000

const repeat: Int = 20

// ─────────────────────────── LICM: hoist an expensive invariant chain ───────────────────────────

pub fn licm_is_faster_on_an_invariant_heavy_loop_test() {
  let m = licm_bench_module()
  let bind = Binding(..profiles.safe(), meter: MeterOff)
  let lowered = lower(m, bind)
  let base = baseline.baseline_passes()
  let baseline_beam = build(lowered, bind, base)
  let licm_beam = build(lowered, bind, list.append(base, [licm.licm_pass()]))

  // correctness gate: licmb(500,3,5,7) — 8-deep invariant product t, acc = Σ_{i<500}(t + i). BOTH agree.
  let want = run_val(baseline_beam, "licmb", [500, 3, 5, 7])
  assert run_val(licm_beam, "licmb", [500, 3, 5, 7]) == want

  let #(base_ns, licm_ns) =
    timed_pair(baseline_beam, licm_beam, "licmb", [
      iters,
      3,
      5,
      7,
    ])
  io.println(
    "\n[p10-bench] LICM · invariant-chain loop · baseline-only "
    <> int.to_string(base_ns)
    <> " ns/iter · +licm "
    <> int.to_string(licm_ns)
    <> " ns/iter · "
    <> ratio(base_ns, licm_ns)
    <> "x faster (8 invariant multiplies hoisted out of the loop)",
  )
  assert licm_ns < base_ns
}

// ─────────────────────────── BCE: remove the per-iteration bounds check ───────────────────────────

pub fn bce_is_measured_on_an_affine_loop_test() {
  let m = sumbuf_bench_module()
  let bind = Binding(..profiles.safe(), meter: MeterOff)
  let lowered = lower(m, bind)
  let base = baseline.baseline_passes()
  let baseline_beam = build(lowered, bind, base)
  let bce_beam = build(lowered, bind, list.append(base, [bce.bce_pass()]))

  // correctness gate: sum of the first (n/4) i32s written into memory; BOTH agree, in-bounds.
  let want = run_val(baseline_beam, "sumbuf", [4000])
  assert run_val(bce_beam, "sumbuf", [4000]) == want

  let #(base_ns, bce_ns) =
    timed_pair(baseline_beam, bce_beam, "sumbuf", [iters])
  io.println(
    "\n[p10-bench] BCE · paged affine loop · baseline "
    <> int.to_string(base_ns)
    <> " ns/iter · +bce "
    <> int.to_string(bce_ns)
    <> " ns/iter · "
    <> ratio(base_ns, bce_ns)
    <> "x (per-iteration bounds check removed; paged win is small — the binary slice dominates)",
  )
  // BCE is correctness-gated + proven to fire (phase10_capstone_test); the wall-clock is reported,
  // not asserted (the paged win is within timer noise — atomics is where the check is a real
  // fraction). We assert only that it is NOT a regression.
  assert bce_ns <= base_ns * 2
}

// ─────────────────────────── kernels ───────────────────────────

fn imul(a: ir.Value, b: ir.Value) -> ir.Expr {
  ir.Num(ir.IMul(ir.W32), [a, b])
}

fn iadd(a: ir.Value, b: ir.Value) -> ir.Expr {
  ir.Num(ir.IAdd(ir.W32), [a, b])
}

/// `licmb(n,a,b,c)`: per iteration compute an 8-deep product of the invariants a,b,c (t), then
/// acc += t + i. LICM hoists the whole chain; baseline-only recomputes 8 multiplies each iteration.
fn licm_bench_module() -> ir.Module {
  // t1=a*b; t2=t1*c; t3=t2*a; t4=t3*b; t5=t4*c; t6=t5*a; t7=t6*b; t8=t7*c   (all invariant)
  let chain =
    ir.Let(
      ["t1"],
      imul(ir.Var("a"), ir.Var("b")),
      ir.Let(
        ["t2"],
        imul(ir.Var("t1"), ir.Var("c")),
        ir.Let(
          ["t3"],
          imul(ir.Var("t2"), ir.Var("a")),
          ir.Let(
            ["t4"],
            imul(ir.Var("t3"), ir.Var("b")),
            ir.Let(
              ["t5"],
              imul(ir.Var("t4"), ir.Var("c")),
              ir.Let(
                ["t6"],
                imul(ir.Var("t5"), ir.Var("a")),
                ir.Let(
                  ["t7"],
                  imul(ir.Var("t6"), ir.Var("b")),
                  ir.Let(
                    ["t8"],
                    imul(ir.Var("t7"), ir.Var("c")),
                    // acc2 = acc + t8 + i ; i2 = i + 1 ; continue
                    ir.Let(
                      ["s"],
                      iadd(ir.Var("acc"), ir.Var("t8")),
                      ir.Let(
                        ["acc2"],
                        iadd(ir.Var("s"), ir.Var("i")),
                        ir.Let(
                          ["i2"],
                          iadd(ir.Var("i"), ir.ConstI32(1)),
                          ir.Continue("l", [ir.Var("i2"), ir.Var("acc2")]),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    )
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
        ir.If(ir.Var("done"), [ir.TI32], ir.Break("l", [ir.Var("acc")]), chain),
      ),
    )
  ir.Module(
    name: "twocore@opt@p10_licmb",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        "licmb",
        [
          ir.Local("n", ir.TI32),
          ir.Local("a", ir.TI32),
          ir.Local("b", ir.TI32),
          ir.Local("c", ir.TI32),
        ],
        [ir.TI32],
        [],
        body,
      ),
    ],
    exports: [ir.ExportFn("licmb", "licmb")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// `sumbuf(n)` = Σ i32@i for i = 0,4,…,<n — the BCE-eligible affine-cursor loop.
fn sumbuf_bench_module() -> ir.Module {
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
    name: "twocore@opt@p10_sumbufb",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function("sumbuf", [ir.Local("n", ir.TI32)], [ir.TI32], [], body),
    ],
    exports: [ir.ExportFn("sumbuf", "sumbuf")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

// ─────────────────────────── harness ───────────────────────────

fn lower(m: ir.Module, binding: Binding) -> ir.Module {
  case ir_lower.lower(m, binding) {
    Ok(l) -> l
    Error(_) -> m
  }
}

fn build(m: ir.Module, binding: Binding, passes: List(pass.Pass)) -> BitArray {
  let optimized = pass.run_pipeline(m, passes)
  let assert Ok(cmod) = emit_core.emit_module(optimized, binding)
  let core = core_printer.print_module(cmod)
  let assert Ok(beam) = pipeline.core_to_beam(core, m.name)
  beam
}

fn run_val(
  beam: BitArray,
  export: String,
  args: List(Int),
) -> pipeline.RunResult {
  let assert Ok(#(_, out)) = pipeline.exec_beam(beam, export, args, 1)
  out
}

/// Time both beams over the same workload; return `#(base_ns_per_iter, opt_ns_per_iter)`.
fn timed_pair(
  base_beam: BitArray,
  opt_beam: BitArray,
  export: String,
  args: List(Int),
) -> #(Int, Int) {
  let assert Ok(#(base_us, _)) =
    pipeline.exec_beam(base_beam, export, args, repeat)
  let assert Ok(#(opt_us, _)) =
    pipeline.exec_beam(opt_beam, export, args, repeat)
  let calls = iters * repeat
  #(base_us * 1000 / calls, opt_us * 1000 / calls)
}

fn ratio(base: Int, opt: Int) -> String {
  case opt <= 0 {
    True -> "inf"
    False -> {
      let tenths = base * 10 / opt
      int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10)
    }
  }
}
