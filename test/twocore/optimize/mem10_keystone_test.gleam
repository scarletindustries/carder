//// Phase-10 unit 01 (keystone) — tests for the shared analysis + the unchecked-access surface.
////
//// Pins the FROZEN contracts units 02–07 build on: `loop_analysis` (free vars + invariance +
//// bound names), `mem_clobber` (may-clobber / may-write, the cross-CF safety gate), the additive
//// `MemLoadUnchecked`/`MemStoreUnchecked` nodes (round-trip + effect + footprint + count), and the
//// FREEZE-SAFE emission (an unchecked node runs byte-identically to its checked twin on the BEAM,
//// because the freeze lowers it via the checked path). Spec-first (D8): each assertion is against
//// the analysis/soundness requirement, never a change-detector.

import gleam/option
import gleam/set
import twocore/ir
import twocore/ir/effect
import twocore/ir/parser
import twocore/ir/printer
import twocore/middle/ir_opt/loop_analysis
import twocore/middle/ir_opt/mem_clobber
import twocore/middle/ir_opt/mem_ssa
import twocore/pipeline
import twocore/runtime/profiles

// ─────────────────────────── loop_analysis: free vars + invariance ───────────────────────────

pub fn free_vars_collects_occurrences_test() {
  // let x = a + b in x * c  ⟹  {a, b, c, x}.
  let e =
    ir.Let(
      ["x"],
      ir.Num(ir.IAdd(ir.W32), [ir.Var("a"), ir.Var("b")]),
      ir.Num(ir.IMul(ir.W32), [ir.Var("x"), ir.Var("c")]),
    )
  assert loop_analysis.free_vars(e) == set.from_list(["a", "b", "c", "x"])
}

pub fn is_loop_invariant_positive_and_negative_test() {
  let bound = set.from_list(["i", "acc"])
  // a*b (a,b loop-external, pure) IS invariant.
  assert loop_analysis.is_loop_invariant(
    ir.Num(ir.IMul(ir.W32), [ir.Var("a"), ir.Var("b")]),
    bound,
  )
  // i+1 references the loop var i → NOT invariant.
  assert !loop_analysis.is_loop_invariant(
    ir.Num(ir.IAdd(ir.W32), [ir.Var("i"), ir.ConstI32(1)]),
    bound,
  )
  // a MemLoad is effectful → NOT invariant (even over loop-external addresses).
  assert !loop_analysis.is_loop_invariant(
    ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("a"), 0, ir.TI32),
    bound,
  )
  // a trapping div is not pure → NOT invariant.
  assert !loop_analysis.is_loop_invariant(
    ir.Num(ir.IDivS(ir.W32), [ir.Var("a"), ir.Var("b")]),
    bound,
  )
}

pub fn bound_names_includes_params_and_inner_lets_test() {
  let body =
    ir.Let(
      ["t"],
      ir.Num(ir.IAdd(ir.W32), [ir.Var("i"), ir.Var("k")]),
      ir.Values([
        ir.Var("t"),
      ]),
    )
  let params = [
    ir.LoopParam("i", ir.TI32, ir.ConstI32(0)),
    ir.LoopParam("acc", ir.TI32, ir.ConstI32(0)),
  ]
  assert loop_analysis.bound_names(params, body)
    == set.from_list(["i", "acc", "t"])
}

// ─────────────────────────── mem_clobber ───────────────────────────

fn store(base: ir.Value, off: Int) -> ir.Expr {
  ir.MemStore(0, ir.MemAccess(4, False), base, ir.ConstI32(1), off)
}

fn fp(base: ir.Value, off: Int) -> mem_ssa.Footprint {
  mem_ssa.Footprint(0, base, off, 4)
}

pub fn may_clobber_aliasing_store_is_true_test() {
  let f = fp(ir.Var("p"), 0)
  // a store to the SAME footprint clobbers.
  assert mem_clobber.may_clobber(store(ir.Var("p"), 0), f)
  // a store to a DIFFERENT base MayAliases → clobbers (conservative).
  assert mem_clobber.may_clobber(store(ir.Var("q"), 0), f)
}

pub fn may_clobber_disjoint_store_is_false_test() {
  let f = fp(ir.Var("p"), 0)
  // a store to a disjoint offset off the SAME base does NOT clobber (the cross-CF disambiguation).
  assert !mem_clobber.may_clobber(store(ir.Var("p"), 4), f)
}

pub fn may_clobber_recurses_into_control_flow_test() {
  let f = fp(ir.Var("p"), 0)
  // an If whose then-branch stores to p clobbers.
  let clobbering = ir.If(ir.Var("c"), [], store(ir.Var("p"), 0), ir.Values([]))
  assert mem_clobber.may_clobber(clobbering, f)
  // an If whose branches only store to a DISJOINT offset does NOT clobber p+0.
  let disjoint =
    ir.If(ir.Var("c"), [], store(ir.Var("p"), 4), store(ir.Var("p"), 8))
  assert !mem_clobber.may_clobber(disjoint, f)
  // a call in a branch clobbers everything.
  let calling =
    ir.If(ir.Var("c"), [], ir.CallHost("env", "f", []), ir.Values([]))
  assert mem_clobber.may_clobber(calling, f)
}

pub fn may_write_memory_covers_writes_calls_and_transfers_test() {
  assert mem_clobber.may_write_memory(store(ir.Var("p"), 0))
  assert mem_clobber.may_write_memory(ir.MemGrow(0, ir.ConstI32(1)))
  assert mem_clobber.may_write_memory(ir.CallHost("env", "f", []))
  // a non-local control transfer stops a DSE look-through.
  assert mem_clobber.may_write_memory(ir.Break("l", []))
  // a pure region does NOT write memory.
  assert !mem_clobber.may_write_memory(
    ir.Num(ir.IAdd(ir.W32), [
      ir.Var("a"),
      ir.Var("b"),
    ]),
  )
  // a load reads but does not write.
  assert !mem_clobber.may_write_memory(ir.MemLoad(
    0,
    ir.MemAccess(4, False),
    ir.Var("p"),
    0,
    ir.TI32,
  ))
}

// ─────────────────────────── the unchecked nodes: round-trip + effect + footprint ───────────────────────────

fn unchecked_load(base: ir.Value, off: Int) -> ir.Expr {
  ir.MemLoadUnchecked(0, ir.MemAccess(4, False), base, off, ir.TI32)
}

fn unchecked_store(base: ir.Value, off: Int, v: ir.Value) -> ir.Expr {
  ir.MemStoreUnchecked(0, ir.MemAccess(4, False), base, v, off)
}

pub fn unchecked_nodes_round_trip_test() {
  // parse(print(m)) == m for a module containing both unchecked nodes.
  let body =
    ir.Let(
      [],
      unchecked_store(ir.Var("p"), 4, ir.Var("v")),
      unchecked_load(ir.Var("p"), 4),
    )
  let m = one_fn_module([ir.Local("p", ir.TI32), ir.Local("v", ir.TI32)], body)
  let assert Ok(parsed) = parser.parse_module(printer.print_module(m))
  assert parsed == m
}

pub fn unchecked_nodes_are_barriers_test() {
  // classified exactly like the checked twins (they read/write mutable memory).
  assert effect.is_effectful_node(unchecked_load(ir.Var("p"), 0))
  assert effect.is_effectful_node(unchecked_store(ir.Var("p"), 0, ir.Var("v")))
  assert !effect.is_pure(unchecked_load(ir.Var("p"), 0))
  assert !effect.is_pure(unchecked_store(ir.Var("p"), 0, ir.Var("v")))
}

pub fn unchecked_nodes_have_footprints_and_count_test() {
  // same footprint as the checked twins.
  assert mem_ssa.footprint_of(unchecked_load(ir.Var("p"), 4))
    == Ok(mem_ssa.Footprint(0, ir.Var("p"), 4, 4))
  assert mem_ssa.footprint_of(unchecked_store(ir.Var("p"), 4, ir.Var("v")))
    == Ok(mem_ssa.Footprint(0, ir.Var("p"), 4, 4))
  // and NOT a blanket barrier (they are footprints, handled precisely).
  assert !mem_ssa.is_memory_barrier(unchecked_load(ir.Var("p"), 0))
  // counted as memory ops (the n_mem measure).
  let body =
    ir.Let(
      [],
      unchecked_store(ir.Var("p"), 0, ir.Var("v")),
      unchecked_load(ir.Var("p"), 0),
    )
  let m = one_fn_module([ir.Local("p", ir.TI32), ir.Local("v", ir.TI32)], body)
  assert mem_ssa.count_mem_ops(m) == 2
}

// ─────────────────────────── freeze-safe emission (runs like checked) ───────────────────────────

pub fn unchecked_nodes_run_like_checked_on_beam_test() {
  // At the freeze the unchecked nodes lower via the CHECKED path, so a module using them returns the
  // identical value as the checked equivalent (little-endian round-trip through memory).
  let m = unchecked_roundtrip_module()
  let assert Ok(cmod) = pipeline.ir_to_cmod(m, profiles.safe())
  let assert Ok(beam) = pipeline.cmod_to_beam(cmod)
  let assert Ok(proc) = pipeline.instantiate(beam, m.name)
  let out = pipeline.invoke_instance(proc, "rt", [0, 305_419_896])
  pipeline.stop_instance(proc)
  assert out == pipeline.Returned([305_419_896])
}

// ───────────────────────────── module helpers ─────────────────────────────

fn one_fn_module(slots: List(ir.Local), body: ir.Expr) -> ir.Module {
  ir.Module(
    name: "twocore@opt@mem10_keystone_test",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [ir.Function("f", slots, [], [], body)],
    exports: [],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// `rt(addr, val)` = unchecked-store `val` at `addr`, then unchecked-load it back.
fn unchecked_roundtrip_module() -> ir.Module {
  ir.Module(
    name: "twocore@opt@mem10_rt",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        "rt",
        [ir.Local("addr", ir.TI32), ir.Local("val", ir.TI32)],
        [ir.TI32],
        [],
        ir.Let(
          [],
          unchecked_store(ir.Var("addr"), 0, ir.Var("val")),
          unchecked_load(ir.Var("addr"), 0),
        ),
      ),
    ],
    exports: [ir.ExportFn("rt", "rt")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}
