//// Phase-9 unit 04 (capstone) — the memory-optimizer WALL-CLOCK benchmark.
////
//// Isolates the memory-pass delta cleanly: it builds the SAME lowered kernel two ways — with the
//// Phase-3 `baseline` passes ONLY, and with `baseline ++ [forwarding_pass(), dead_store_pass()]` —
//// on the `paged` tier (DSE's headline: each store is an O(page) rebuild), metering OFF (so the hot
//// loop is not fuel-bounded). Both are correctness-gated (identical result) BEFORE timing (a fast
//// wrong number is not a number), then timed with `pipeline.exec_beam`. The DETERMINISTIC
//// clock-independent "the passes fire" proof is in `memory_differential_test.gleam`; this test
//// reports the wall-clock and asserts the memory build is genuinely faster (the paged DSE win is
//// large, so the margin is generous — not a flaky micro-difference). Numbers are echoed for
//// `docs/phase-9-benchmark.md`.

import gleam/int
import gleam/io
import gleam/list
import gleam/option
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/ir
import twocore/middle/ir_lower
import twocore/middle/ir_opt/baseline
import twocore/middle/ir_opt/mem_dse
import twocore/middle/ir_opt/mem_forward
import twocore/middle/ir_opt/pass
import twocore/pipeline
import twocore/runtime/instance.{type Binding, Binding, MeterOff}
import twocore/runtime/profiles

/// Iterations per invocation of the kernel loop, and how many invocations to time. Kept modest so
/// the suite stays fast; large enough that the paged DSE delta dominates timer noise.
const iters: Int = 4000

const repeat: Int = 20

pub fn memory_optimizer_is_faster_on_paged_test() {
  let m = bench_module()
  // The paged, metering-off benchmark binding (bypass opt_level — the pass lists are explicit).
  let bind = Binding(..profiles.safe(), meter: MeterOff)
  let lowered = case ir_lower.lower(m, bind) {
    Ok(l) -> l
    Error(_) -> m
  }

  // Two builds differing ONLY in the memory passes.
  let base_passes = baseline.baseline_passes()
  let mem_passes = [mem_forward.forwarding_pass(), mem_dse.dead_store_pass()]
  let baseline_beam = build_beam(lowered, bind, base_passes)
  let memory_beam =
    build_beam(lowered, bind, list.append(base_passes, mem_passes))

  // Correctness gate: bench(500) = 7 * sum(0..499) = 7 * 499*500/2 = 873250. BOTH builds agree.
  let want = pipeline.Returned([873_250])
  let assert Ok(#(_, base_chk)) =
    pipeline.exec_beam(baseline_beam, "bench", [500], 1)
  let assert Ok(#(_, mem_chk)) =
    pipeline.exec_beam(memory_beam, "bench", [500], 1)
  assert base_chk == want
  assert mem_chk == want

  // Time both (identical workload).
  let assert Ok(#(base_us, _)) =
    pipeline.exec_beam(baseline_beam, "bench", [iters], repeat)
  let assert Ok(#(mem_us, _)) =
    pipeline.exec_beam(memory_beam, "bench", [iters], repeat)

  let calls = iters * repeat
  let base_ns = base_us * 1000 / calls
  let mem_ns = mem_us * 1000 / calls
  io.println(
    "\n[mem-bench] paged tier, "
    <> int.to_string(calls)
    <> " loop iterations · baseline-only "
    <> int.to_string(base_ns)
    <> " ns/iter · +memory-passes "
    <> int.to_string(mem_ns)
    <> " ns/iter · "
    <> ratio(base_us, mem_us)
    <> "x faster (DSE: 4 paged stores/iter → 1; +1 load forwarded)",
  )

  // The memory build MUST be faster. On paged the win is multi-fold (each eliminated store is an
  // O(page) rebuild), so this is not a flaky micro-difference.
  assert mem_us < base_us
}

/// A one-decimal `base/mem` speedup string, guarding against a zero denominator.
fn ratio(base_us: Int, mem_us: Int) -> String {
  case mem_us <= 0 {
    True -> "inf"
    False -> {
      let tenths = base_us * 10 / mem_us
      int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10)
    }
  }
}

// ─────────────────────────── the benchmark kernel ───────────────────────────
//
//   bench(n):
//     loop (i=0, acc=0):
//       if i >= n: return acc
//       store(0, i)          // dead  ┐
//       store(0, i+1)        // dead  ├─ 3 stores DSE removes (each shadowed, pure between)
//       store(0, i+2)        // dead  ┘
//       store(0, i*7 + acc)  // live
//       v = load(0)          // → forwarded away (store→load forwarding)
//       continue(i+1, v)
//
// Per iteration: 4 paged stores + 1 load unoptimized → 1 store, 0 loads optimized. On the paged
// tier each store is an O(page) rebuild, so DSE alone is a ~4× reduction in the dominant cost.

fn i32_store(off: Int, v: ir.Value) -> ir.Expr {
  ir.MemStore(0, ir.MemAccess(4, False), ir.ConstI32(0), v, off)
}

fn bench_body() -> ir.Expr {
  let churn =
    ir.Let(
      [],
      i32_store(0, ir.Var("i")),
      ir.Let(
        ["t2"],
        ir.Num(ir.IAdd(ir.W32), [ir.Var("i"), ir.ConstI32(1)]),
        ir.Let(
          [],
          i32_store(0, ir.Var("t2")),
          ir.Let(
            ["t3"],
            ir.Num(ir.IAdd(ir.W32), [ir.Var("i"), ir.ConstI32(2)]),
            ir.Let(
              [],
              i32_store(0, ir.Var("t3")),
              ir.Let(
                ["prod"],
                ir.Num(ir.IMul(ir.W32), [ir.Var("i"), ir.ConstI32(7)]),
                ir.Let(
                  ["live"],
                  ir.Num(ir.IAdd(ir.W32), [ir.Var("prod"), ir.Var("acc")]),
                  ir.Let(
                    [],
                    i32_store(0, ir.Var("live")),
                    ir.Let(
                      ["v"],
                      ir.MemLoad(
                        0,
                        ir.MemAccess(4, False),
                        ir.ConstI32(0),
                        0,
                        ir.TI32,
                      ),
                      ir.Let(
                        ["ni"],
                        ir.Num(ir.IAdd(ir.W32), [ir.Var("i"), ir.ConstI32(1)]),
                        ir.Continue("l", [ir.Var("ni"), ir.Var("v")]),
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
      ir.If(ir.Var("done"), [ir.TI32], ir.Break("l", [ir.Var("acc")]), churn),
    ),
  )
}

fn bench_module() -> ir.Module {
  ir.Module(
    name: "twocore@opt@mem_bench",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        "bench",
        [ir.Local("n", ir.TI32)],
        [ir.TI32],
        [],
        bench_body(),
      ),
    ],
    exports: [ir.ExportFn("bench", "bench")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

// ─────────────────────────── build helper ───────────────────────────

/// Lower-free build: apply `passes` to the already-lowered `m`, emit Core Erlang under `binding`,
/// and compile to a loadable `.beam`. Both benchmark builds share this so they differ ONLY in the
/// pass list.
fn build_beam(
  m: ir.Module,
  binding: Binding,
  passes: List(pass.Pass),
) -> BitArray {
  let optimized = pass.run_pipeline(m, passes)
  let assert Ok(cmod) = emit_core.emit_module(optimized, binding)
  let core = core_printer.print_module(cmod)
  let assert Ok(beam) = pipeline.core_to_beam(core, m.name)
  beam
}
