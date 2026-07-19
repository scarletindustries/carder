//// Phase-9 unit 03 — tests for dead-store elimination (`ir_opt/mem_dse`).
////
//// STRUCTURAL tests assert the peephole removes a store shadowed by a MustAlias later store (with
//// only pure nodes between) and — the load-bearing ADVERSARIAL half — LEAVES a store alone whenever
//// removing it would change an observable (an intervening load that observes its value, a barrier,
//// a MayAlias/NoAlias later store). END-TO-END tests compile to real BEAM and assert value + trap
//// behaviour is byte-identical to the unoptimized module. Spec anchor: WASM exec/instructions (a
//// store bounds-checks then writes; OOB traps before any write), so a MustAlias shadowing store
//// preserves both the final memory state and the exact `MemoryOutOfBounds` trap.

import gleam/option
import twocore/ir
import twocore/middle/ir_opt/mem_dse
import twocore/middle/ir_opt/pass
import twocore/pipeline
import twocore/runtime/profiles

// ─────────────────────────── shared builders ───────────────────────────

fn i32_load(base: ir.Value, off: Int) -> ir.Expr {
  ir.MemLoad(0, ir.MemAccess(4, False), base, off, ir.TI32)
}

fn i32_store(base: ir.Value, off: Int, v: ir.Value) -> ir.Expr {
  ir.MemStore(0, ir.MemAccess(4, False), base, v, off)
}

fn add(a: ir.Value, b: ir.Value) -> ir.Expr {
  ir.Num(ir.IAdd(ir.W32), [a, b])
}

/// Run `dead_store_pass()` (in isolation, via the fixpoint driver) over a one-function module and
/// return the optimized body.
fn dse(slots: List(ir.Local), body: ir.Expr) -> ir.Expr {
  let m = one_fn_module(slots, body)
  let opt = pass.run_pipeline(m, [mem_dse.dead_store_pass()])
  let assert [f] = opt.functions
  f.body
}

// ─────────────────────────── dead stores removed ───────────────────────────

pub fn adjacent_shadowed_store_is_removed_test() {
  // store(%p, %v1); store(%p, %v2); ()  ⟹  store1 is DEAD (fully overwritten), removed.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v1")),
      ir.Let([], i32_store(ir.Var("p"), 0, ir.Var("v2")), ir.Values([])),
    )
  let expected =
    ir.Let([], i32_store(ir.Var("p"), 0, ir.Var("v2")), ir.Values([]))
  let slots = [
    ir.Local("p", ir.TI32),
    ir.Local("v1", ir.TI32),
    ir.Local("v2", ir.TI32),
  ]
  assert dse(slots, body) == expected
}

pub fn store_shadowed_with_pure_between_is_removed_test() {
  // store(%p, %v1); let x = %a + %b; store(%p, %v2)  ⟹  pure computation between is harmless →
  // store1 removed.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v1")),
      ir.Let(
        ["x"],
        add(ir.Var("a"), ir.Var("b")),
        ir.Let([], i32_store(ir.Var("p"), 0, ir.Var("v2")), ir.Values([])),
      ),
    )
  let expected =
    ir.Let(
      ["x"],
      add(ir.Var("a"), ir.Var("b")),
      ir.Let([], i32_store(ir.Var("p"), 0, ir.Var("v2")), ir.Values([])),
    )
  let slots = [
    ir.Local("p", ir.TI32),
    ir.Local("a", ir.TI32),
    ir.Local("b", ir.TI32),
    ir.Local("v1", ir.TI32),
    ir.Local("v2", ir.TI32),
  ]
  assert dse(slots, body) == expected
}

pub fn chain_of_stores_keeps_only_the_last_test() {
  // store(%p, a); store(%p, b); store(%p, c); ()  ⟹  only the LAST survives.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("a")),
      ir.Let(
        [],
        i32_store(ir.Var("p"), 0, ir.Var("b")),
        ir.Let([], i32_store(ir.Var("p"), 0, ir.Var("c")), ir.Values([])),
      ),
    )
  let expected =
    ir.Let([], i32_store(ir.Var("p"), 0, ir.Var("c")), ir.Values([]))
  let slots = [
    ir.Local("p", ir.TI32),
    ir.Local("a", ir.TI32),
    ir.Local("b", ir.TI32),
    ir.Local("c", ir.TI32),
  ]
  assert dse(slots, body) == expected
}

// ─────────────────────────── adversarial "must NOT eliminate" ───────────────────────────

pub fn load_between_keeps_the_store_test() {
  // store(%p, %v1); let x = load(%p); store(%p, %v2)  ⟹  the load OBSERVES %v1, so store1 is NOT
  // dead — it must stay.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v1")),
      ir.Let(
        ["x"],
        i32_load(ir.Var("p"), 0),
        ir.Let(
          [],
          i32_store(ir.Var("p"), 0, ir.Var("v2")),
          ir.Values([ir.Var("x")]),
        ),
      ),
    )
  let slots = [
    ir.Local("p", ir.TI32),
    ir.Local("v1", ir.TI32),
    ir.Local("v2", ir.TI32),
  ]
  // unchanged — store1 preserved.
  assert dse(slots, body) == body
}

pub fn memgrow_between_keeps_the_store_test() {
  // store(%p, %v1); memory.grow(1); store(%p, %v2)  ⟹  grow can CHANGE the in-bounds status, so
  // removing store1 could remove a trap — store1 must stay.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v1")),
      ir.Let(
        ["_g"],
        ir.MemGrow(0, ir.ConstI32(1)),
        ir.Let([], i32_store(ir.Var("p"), 0, ir.Var("v2")), ir.Values([])),
      ),
    )
  let slots = [
    ir.Local("p", ir.TI32),
    ir.Local("v1", ir.TI32),
    ir.Local("v2", ir.TI32),
  ]
  assert dse(slots, body) == body
}

pub fn callhost_between_keeps_the_store_test() {
  // store(%p, %v1); CallHost(...); store(%p, %v2)  ⟹  the call may observe/modify memory — keep.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v1")),
      ir.Let(
        [],
        ir.CallHost("env", "f", []),
        ir.Let([], i32_store(ir.Var("p"), 0, ir.Var("v2")), ir.Values([])),
      ),
    )
  let slots = [
    ir.Local("p", ir.TI32),
    ir.Local("v1", ir.TI32),
    ir.Local("v2", ir.TI32),
  ]
  assert dse(slots, body) == body
}

pub fn mayalias_later_store_keeps_the_store_test() {
  // store(%p, %v1); store(%q, %v2)  ⟹  a DIFFERENT base %q only MayAliases %p — it does not
  // PROVABLY overwrite %p, so store1 is not shadowed — keep.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v1")),
      ir.Let([], i32_store(ir.Var("q"), 0, ir.Var("v2")), ir.Values([])),
    )
  let slots = [
    ir.Local("p", ir.TI32),
    ir.Local("q", ir.TI32),
    ir.Local("v1", ir.TI32),
    ir.Local("v2", ir.TI32),
  ]
  assert dse(slots, body) == body
}

pub fn noalias_later_store_keeps_the_store_test() {
  // store(%p+0, %v1); store(%p+4, %v2)  ⟹  the later store is NoAlias (disjoint offset), so it does
  // NOT shadow store1 — keep (store1's bytes are still live).
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v1")),
      ir.Let([], i32_store(ir.Var("p"), 4, ir.Var("v2")), ir.Values([])),
    )
  let slots = [
    ir.Local("p", ir.TI32),
    ir.Local("v1", ir.TI32),
    ir.Local("v2", ir.TI32),
  ]
  assert dse(slots, body) == body
}

// ─────────────────────────── end-to-end on the real BEAM (M3, F2) ───────────────────────────

pub fn dse_preserves_final_memory_on_beam_test() {
  // f(addr, v1, v2) = { store(addr, v1); store(addr, v2); load(addr) } → v2. DSE removes store1;
  // optimized and unoptimized must return the same value (and it is v2).
  let m = double_store_module()
  let opt = pass.run_pipeline(m, [mem_dse.dead_store_pass()])
  assert run(m, "f", [0, 11, 22]) == run(opt, "f", [0, 11, 22])
  assert run(opt, "f", [0, 11, 22]) == pipeline.Returned([22])
}

pub fn dse_preserves_the_oob_trap_on_beam_test() {
  // An OOB address traps at the shadowing store in BOTH programs (removing store1 does not remove
  // the trap — store2 bounds-checks the same address).
  let m = double_store_module()
  let opt = pass.run_pipeline(m, [mem_dse.dead_store_pass()])
  let unopt_out = run(m, "f", [9_000_000, 11, 22])
  let opt_out = run(opt, "f", [9_000_000, 11, 22])
  assert unopt_out == opt_out
  let assert pipeline.Trapped(_) = opt_out
}

// ─────────────────────────── module + run helpers ───────────────────────────

fn one_fn_module(slots: List(ir.Local), body: ir.Expr) -> ir.Module {
  ir.Module(
    name: "twocore@opt@mem_dse_test",
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

/// `f(addr, v1, v2)` = store `v1` at `addr`, store `v2` at `addr`, load `addr` and return it.
fn double_store_module() -> ir.Module {
  ir.Module(
    name: "twocore@opt@mem_dse_rt",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        "f",
        [
          ir.Local("addr", ir.TI32),
          ir.Local("v1", ir.TI32),
          ir.Local("v2", ir.TI32),
        ],
        [ir.TI32],
        [],
        ir.Let(
          [],
          i32_store(ir.Var("addr"), 0, ir.Var("v1")),
          ir.Let(
            [],
            i32_store(ir.Var("addr"), 0, ir.Var("v2")),
            i32_load(ir.Var("addr"), 0),
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

/// Compile `m` under `profiles.safe()` through the whole run-ABI and invoke `export(args)`.
fn run(m: ir.Module, export: String, args: List(Int)) -> pipeline.RunResult {
  let assert Ok(cmod) = pipeline.ir_to_cmod(m, profiles.safe())
  let assert Ok(beam) = pipeline.cmod_to_beam(cmod)
  let assert Ok(proc) = pipeline.instantiate(beam, m.name)
  let out = pipeline.invoke_instance(proc, export, args)
  pipeline.stop_instance(proc)
  out
}
