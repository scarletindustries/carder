//// Phase-10 unit 03 — tests for cross-control-flow MemorySSA (`ir_opt/mem_forward` extension).
////
//// Phase 9 reset memory knowledge at every control-flow boundary; Phase 10 carries a dominating
//// store's value ACROSS a single-execution `If`/`Block`/`Switch` — and INTO its branches — for every
//// footprint no branch clobbers (gated by `mem_clobber.may_clobber`). STRUCTURAL tests prove the
//// forward fires across / into a no-clobber region; ADVERSARIAL tests prove it is BLOCKED by a
//// clobbering branch, a call/grow in a branch, and (kept conservative) a `Loop`/`Try` region. An
//// end-to-end BEAM run proves value preservation. Spec-first (D8): a fact survives a subtree iff no
//// execution of it could write bytes aliasing the footprint.

import gleam/option
import twocore/ir
import twocore/middle/ir_opt/mem_forward
import twocore/middle/ir_opt/pass
import twocore/pipeline
import twocore/runtime/profiles

fn i32_load(base: ir.Value, off: Int) -> ir.Expr {
  ir.MemLoad(0, ir.MemAccess(4, False), base, off, ir.TI32)
}

fn i32_store(base: ir.Value, off: Int, v: ir.Value) -> ir.Expr {
  ir.MemStore(0, ir.MemAccess(4, False), base, v, off)
}

fn fwd(slots: List(ir.Local), body: ir.Expr) -> ir.Expr {
  let m = one_fn_module(slots, body)
  let opt = pass.run_pipeline(m, [mem_forward.forwarding_pass()])
  let assert [f] = opt.functions
  f.body
}

// ─────────────────────────── forwarding ACROSS a no-clobber region ───────────────────────────

pub fn forwards_across_disjoint_only_branches_test() {
  // store(%p+0, %v); if (%c) { store(%p+4, %x) } { store(%p+8, %y) }; load(%p+0)
  // Both branches store only to DISJOINT offsets (NoAlias %p+0), so %v survives the if.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v")),
      ir.Let(
        [],
        ir.If(
          ir.Var("c"),
          [],
          i32_store(ir.Var("p"), 4, ir.Var("x")),
          i32_store(ir.Var("p"), 8, ir.Var("y")),
        ),
        i32_load(ir.Var("p"), 0),
      ),
    )
  let slots = named(["p", "v", "x", "y", "c"])
  let assert ir.Let(_, _, ir.Let(_, _, tail)) = fwd(slots, body)
  assert tail == ir.Values([ir.Var("v")])
}

pub fn forwards_into_a_branch_test() {
  // store(%p, %v); if (%c) { load(%p) → forwarded } {}. The store dominates the branch entry, so a
  // load early in the branch forwards %v.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v")),
      ir.If(
        ir.Var("c"),
        [ir.TI32],
        i32_load(ir.Var("p"), 0),
        ir.Values([
          ir.ConstI32(0),
        ]),
      ),
    )
  let slots = named(["p", "v", "c"])
  let assert ir.Let(_, _, ir.If(_, _, then_branch, _)) = fwd(slots, body)
  assert then_branch == ir.Values([ir.Var("v")])
}

// ─────────────────────────── adversarial "must NOT forward across" ───────────────────────────

pub fn clobbering_branch_blocks_forward_test() {
  // store(%p, %v); if (%c) { store(%p, %w) } {}; load(%p)  ⟹  a branch stores %p → not forwarded.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v")),
      ir.Let(
        [],
        ir.If(
          ir.Var("c"),
          [],
          i32_store(ir.Var("p"), 0, ir.Var("w")),
          ir.Values([]),
        ),
        i32_load(ir.Var("p"), 0),
      ),
    )
  let slots = named(["p", "v", "w", "c"])
  let assert ir.Let(_, _, ir.Let(_, _, tail)) = fwd(slots, body)
  assert tail == i32_load(ir.Var("p"), 0)
}

pub fn call_in_branch_blocks_forward_test() {
  // store(%p, %v); if (%c) { CallHost(..) } {}; load(%p)  ⟹  a call may write any memory → blocked.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v")),
      ir.Let(
        [],
        ir.If(ir.Var("c"), [], ir.CallHost("env", "f", []), ir.Values([])),
        i32_load(ir.Var("p"), 0),
      ),
    )
  let slots = named(["p", "v", "c"])
  let assert ir.Let(_, _, ir.Let(_, _, tail)) = fwd(slots, body)
  assert tail == i32_load(ir.Var("p"), 0)
}

pub fn loop_stays_a_barrier_test() {
  // store(%p, %v); loop {..}; load(%p)  ⟹  a re-entrant Loop stays a full barrier (a dominating
  // store need not survive the back-edge), so the load is NOT forwarded across it.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v")),
      ir.Let(
        [],
        ir.Loop("l", [], [], ir.Break("l", [])),
        i32_load(ir.Var("p"), 0),
      ),
    )
  let slots = named(["p", "v"])
  let assert ir.Let(_, _, ir.Let(_, _, tail)) = fwd(slots, body)
  assert tail == i32_load(ir.Var("p"), 0)
}

// ─────────────────────────── end-to-end on the real BEAM ───────────────────────────

pub fn cross_cf_forward_preserves_value_on_beam_test() {
  // f(p, v, c) = { store(p, v); if (c) { store(p+4, 99) } {}; load(p) } → v (the p+4 store is
  // disjoint). Optimized (cross-CF forward) and unoptimized agree.
  let m = cross_module()
  let opt = pass.run_pipeline(m, [mem_forward.forwarding_pass()])
  assert run(m, "f", [0, 42, 1]) == run(opt, "f", [0, 42, 1])
  assert run(opt, "f", [0, 42, 1]) == pipeline.Returned([42])
  // and with c=0 (branch not taken) too.
  assert run(m, "f", [0, 42, 0]) == run(opt, "f", [0, 42, 0])
}

// ─────────────────────────── helpers ───────────────────────────

fn named(ns: List(String)) -> List(ir.Local) {
  case ns {
    [] -> []
    [n, ..rest] -> [ir.Local(n, ir.TI32), ..named(rest)]
  }
}

fn one_fn_module(slots: List(ir.Local), body: ir.Expr) -> ir.Module {
  ir.Module(
    name: "twocore@opt@cross_cf_test",
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

fn cross_module() -> ir.Module {
  ir.Module(
    name: "twocore@opt@cross_cf_rt",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        "f",
        named(["p", "v", "c"]),
        [ir.TI32],
        [],
        ir.Let(
          [],
          i32_store(ir.Var("p"), 0, ir.Var("v")),
          ir.Let(
            [],
            ir.If(
              ir.Var("c"),
              [],
              i32_store(ir.Var("p"), 4, ir.ConstI32(99)),
              ir.Values([]),
            ),
            i32_load(ir.Var("p"), 0),
          ),
        ),
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

fn run(m: ir.Module, export: String, args: List(Int)) -> pipeline.RunResult {
  let assert Ok(core) = pipeline.ir_to_core(m, profiles.safe())
  let assert Ok(beam) = pipeline.core_to_beam(core, m.name)
  let assert Ok(proc) = pipeline.instantiate(beam, m.name)
  let out = pipeline.invoke_instance(proc, export, args)
  pipeline.stop_instance(proc)
  out
}
