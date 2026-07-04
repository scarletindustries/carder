//// Phase-9 unit 04 (capstone) — the memory-optimizer wiring differential.
////
//// The whole-corpus/spec/tier `OptNone ≡ Baseline ≡ Aggressive` differential (semantics
//// preservation across every tier + both modes) lives in `differential_test.gleam` +
//// `tier_matrix_*` and is GREEN with the memory passes wired. THIS file adds the Phase-9-specific
//// evidence the corpus alone cannot give: that the memory passes actually **fire in the wired
//// `Baseline` pipeline** (a DETERMINISTIC, clock-independent `count_mem_ops` reduction), that the
//// fixpoint **converges** (no oscillation — M7), that the count is **monotone non-increasing** (the
//// passes never add a memory op), that `Aggressive ⊇ Baseline`, and that a program the passes
//// actually TRANSFORM runs byte-identically at `OptNone` and `Baseline` on real BEAM (M3/M6).

import gleam/option
import twocore/ir
import twocore/middle/ir_opt
import twocore/middle/ir_opt/mem_ssa
import twocore/pipeline
import twocore/runtime/instance.{Binding}
import twocore/runtime/profiles

// ─────────────────────────── the redundancy kernel ───────────────────────────
//
//   churn(p) {
//     store(p+4, 5)         // live
//     store(p+0, 111)       // DEAD  → dead-store elimination removes it
//     store(p+0, 222)       // live
//     x = load(p+0)         // → forwards 222      (store→load forwarding)
//     y = load(p+4)         // → forwards 5        (survives the disjoint p+0 stores)
//     z = load(p+4)         // → reuses y          (redundant-load elimination)
//     return x + y + z      // = 232
//   }
//
// Original memory ops: 3 stores + 3 loads = 6. After the Baseline pipeline (memory passes +
// baseline cleanup): store(p+0,111) is dead (DSE) and all 3 loads are forwarded away, leaving the
// two live stores = 2. So the passes eliminate EXACTLY 4 memory-op nodes — a deterministic metric.

fn i32_load(off: Int) -> ir.Expr {
  ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("p"), off, ir.TI32)
}

fn i32_store(off: Int, v: Int) -> ir.Expr {
  ir.MemStore(0, ir.MemAccess(4, False), ir.Var("p"), ir.ConstI32(v), off)
}

fn add(a: ir.Value, b: ir.Value) -> ir.Expr {
  ir.Num(ir.IAdd(ir.W32), [a, b])
}

fn churn_body() -> ir.Expr {
  ir.Let(
    [],
    i32_store(4, 5),
    ir.Let(
      [],
      i32_store(0, 111),
      ir.Let(
        [],
        i32_store(0, 222),
        ir.Let(
          ["x"],
          i32_load(0),
          ir.Let(
            ["y"],
            i32_load(4),
            ir.Let(
              ["z"],
              i32_load(4),
              ir.Let(
                ["s1"],
                add(ir.Var("x"), ir.Var("y")),
                ir.Let(
                  ["s2"],
                  add(ir.Var("s1"), ir.Var("z")),
                  ir.Values([ir.Var("s2")]),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  )
}

fn churn_module() -> ir.Module {
  ir.Module(
    name: "twocore@opt@mem_churn",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        "churn",
        [ir.Local("p", ir.TI32)],
        [ir.TI32],
        [],
        churn_body(),
      ),
    ],
    exports: [ir.ExportFn("churn", "churn")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

// ─────────────────────────── the passes FIRE (deterministic) ───────────────────────────

pub fn memory_passes_fire_in_baseline_pipeline_test() {
  let m = churn_module()
  // OptNone is the identity, so it holds the original count.
  let none = mem_ssa.count_mem_ops(ir_opt.optimize(m, ir_opt.OptNone))
  let base = mem_ssa.count_mem_ops(ir_opt.optimize(m, ir_opt.Baseline))
  assert none == 6
  // 1 dead store + 3 forwarded/RLE'd loads eliminated ⟹ 2 live stores remain.
  assert base == 2
}

pub fn aggressive_eliminates_at_least_as_much_as_baseline_test() {
  let m = churn_module()
  let base = mem_ssa.count_mem_ops(ir_opt.optimize(m, ir_opt.Baseline))
  let aggr = mem_ssa.count_mem_ops(ir_opt.optimize(m, ir_opt.Aggressive))
  // Aggressive is a strict superset of Baseline, so it never leaves MORE memory ops.
  assert aggr <= base
}

// ─────────────────────────── monotonicity + convergence (M7) ───────────────────────────

pub fn optimize_is_monotone_in_mem_ops_test() {
  // The passes NEVER add a memory op: count(optimize(m, Baseline)) <= count(m), for the kernel and
  // for a module with no redundancy (which is left unchanged).
  let churn = churn_module()
  assert mem_ssa.count_mem_ops(ir_opt.optimize(churn, ir_opt.Baseline))
    <= mem_ssa.count_mem_ops(churn)
  let plain = no_redundancy_module()
  // no redundant traffic ⟹ the count is unchanged (nothing to eliminate).
  assert mem_ssa.count_mem_ops(ir_opt.optimize(plain, ir_opt.Baseline))
    == mem_ssa.count_mem_ops(plain)
}

pub fn optimize_converges_to_a_fixpoint_test() {
  // Re-optimizing the optimized module is a no-op — the fixpoint is reached, no oscillation.
  let m = churn_module()
  let once = ir_opt.optimize(m, ir_opt.Baseline)
  let twice = ir_opt.optimize(once, ir_opt.Baseline)
  assert twice == once
}

// ─────────────────────────── semantics preserved end-to-end (M3/M6) ───────────────────────────

pub fn transformed_kernel_matches_optnone_on_beam_test() {
  // The kernel — which the memory passes DEMONSTRABLY transform (4 nodes removed) — returns the
  // SAME value at OptNone (optimizer bypassed) and Baseline (memory passes on), on real BEAM.
  let m = churn_module()
  let none = Binding(..profiles.safe(), opt_level: ir_opt.OptNone)
  let base = profiles.safe()
  // 222 + 5 + 5 = 232.
  assert run(m, none, "churn", [0]) == pipeline.Returned([232])
  assert run(m, base, "churn", [0]) == run(m, none, "churn", [0])
}

pub fn transformed_kernel_preserves_oob_trap_on_beam_test() {
  // At an OOB address the (surviving) stores still trap identically under both optimizer levels —
  // the passes never remove a trap.
  let m = churn_module()
  let none = Binding(..profiles.safe(), opt_level: ir_opt.OptNone)
  let base = profiles.safe()
  let none_out = run(m, none, "churn", [9_000_000])
  let base_out = run(m, base, "churn", [9_000_000])
  assert none_out == base_out
  let assert pipeline.Trapped(_) = base_out
}

// ─────────────────────────── helpers ───────────────────────────

/// A memory module with NO redundant traffic (each access is to a distinct live cell) — the
/// passes must leave its memory-op count unchanged.
fn no_redundancy_module() -> ir.Module {
  let body =
    ir.Let(
      [],
      i32_store(0, 1),
      ir.Let(["a"], i32_load(8), ir.Values([ir.Var("a")])),
    )
  ir.Module(
    name: "twocore@opt@mem_plain",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function("g", [ir.Local("p", ir.TI32)], [ir.TI32], [], body),
    ],
    exports: [ir.ExportFn("g", "g")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

fn run(
  m: ir.Module,
  binding: instance.Binding,
  export: String,
  args: List(Int),
) -> pipeline.RunResult {
  let assert Ok(core) = pipeline.ir_to_core(m, binding)
  let assert Ok(beam) = pipeline.core_to_beam(core, m.name)
  let assert Ok(proc) = pipeline.instantiate(beam, m.name)
  let out = pipeline.invoke_instance(proc, export, args)
  pipeline.stop_instance(proc)
  out
}
