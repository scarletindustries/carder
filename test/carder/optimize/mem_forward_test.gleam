//// Phase-9 unit 02 — tests for store→load forwarding + redundant-load elimination
//// (`ir_opt/mem_forward`).
////
//// Two layers, both spec-first (D8): STRUCTURAL tests assert the transfer function rewrites the IR
//// exactly as the trap-preservation argument (M3) licenses — and, crucially, the ADVERSARIAL
//// "must-NOT forward" fixtures assert the pass LEAVES a load alone whenever forwarding would be
//// unsound (an aliasing store between, a barrier between, a sub-width load, a truncating store
//// source). END-TO-END tests compile the optimized module to real BEAM and assert value + trap
//// behaviour is byte-identical to the unoptimized module. Spec anchor: WASM exec/instructions
//// (a load/store bounds-checks then accesses; OOB traps), exec/memory (little-endian round-trip).

import carder/ir
import carder/middle/ir_opt/mem_forward
import carder/middle/ir_opt/pass
import carder/pipeline
import carder/runtime/profiles
import gleam/option

// ─────────────────────────── shared builders ───────────────────────────

fn i32_load(base: ir.Value, off: Int) -> ir.Expr {
  ir.MemLoad(0, ir.MemAccess(4, False), base, off, ir.TI32)
}

fn i32_store(base: ir.Value, off: Int, v: ir.Value) -> ir.Expr {
  ir.MemStore(0, ir.MemAccess(4, False), base, v, off)
}

/// Run `forwarding_pass()` (in isolation, via the fixpoint driver) over a one-function module whose
/// params/locals are `slots` and whose body is `body`; return the optimized body.
fn fwd(slots: List(ir.Local), body: ir.Expr) -> ir.Expr {
  let m = one_fn_module(slots, body)
  let opt = pass.run_pipeline(m, [mem_forward.forwarding_pass()])
  let assert [f] = opt.functions
  f.body
}

// ─────────────────────────── store → load forwarding ───────────────────────────

pub fn store_then_load_forwards_the_stored_value_test() {
  // store(%p, %v); let x = load(%p); return x  ⟹  the load's rhs becomes Values([%v]).
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v")),
      ir.Let(["x"], i32_load(ir.Var("p"), 0), ir.Values([ir.Var("x")])),
    )
  let expected =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v")),
      ir.Let(["x"], ir.Values([ir.Var("v")]), ir.Values([ir.Var("x")])),
    )
  assert fwd([ir.Local("p", ir.TI32), ir.Local("v", ir.TI32)], body) == expected
}

pub fn tail_load_forwards_from_store_test() {
  // store(%p, %v); load(%p)  (the load is the region TAIL)  ⟹  Values([%v]).
  let body =
    ir.Let([], i32_store(ir.Var("p"), 0, ir.Var("v")), i32_load(ir.Var("p"), 0))
  let expected =
    ir.Let([], i32_store(ir.Var("p"), 0, ir.Var("v")), ir.Values([ir.Var("v")]))
  assert fwd([ir.Local("p", ir.TI32), ir.Local("v", ir.TI32)], body) == expected
}

// ─────────────────────────── redundant-load elimination ───────────────────────────

pub fn two_loads_collapse_to_one_test() {
  // let x = load(%p); let y = load(%p); return [x, y]  ⟹  the SECOND load reuses %x.
  let body =
    ir.Let(
      ["x"],
      i32_load(ir.Var("p"), 0),
      ir.Let(
        ["y"],
        i32_load(ir.Var("p"), 0),
        ir.Values([ir.Var("x"), ir.Var("y")]),
      ),
    )
  let expected =
    ir.Let(
      ["x"],
      i32_load(ir.Var("p"), 0),
      ir.Let(
        ["y"],
        ir.Values([ir.Var("x")]),
        ir.Values([ir.Var("x"), ir.Var("y")]),
      ),
    )
  assert fwd([ir.Local("p", ir.TI32)], body) == expected
}

// ─────────────────────────── the disjoint-offset disambiguation (Array-SSA) ───────────────────────────

pub fn disjoint_offset_store_does_not_clobber_test() {
  // store(%p+0, %a); store(%p+4, %b); load(%p+0)  ⟹  load(%p+0) STILL forwards %a: the store to
  // %p+4 is NoAlias with %p+0, so avail[%p+0] survives.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("a")),
      ir.Let(
        [],
        i32_store(ir.Var("p"), 4, ir.Var("b")),
        i32_load(ir.Var("p"), 0),
      ),
    )
  let slots = [
    ir.Local("p", ir.TI32),
    ir.Local("a", ir.TI32),
    ir.Local("b", ir.TI32),
  ]
  // the tail load forwards %a.
  let assert ir.Let(_, _, ir.Let(_, _, tail)) = fwd(slots, body)
  assert tail == ir.Values([ir.Var("a")])
}

// ─────────────────────────── adversarial "must NOT forward" ───────────────────────────

pub fn no_forward_across_aliasing_store_test() {
  // store(%p, %v); store(%q, %w); load(%p)  ⟹  the store to a DIFFERENT base %q MayAliases %p, so
  // avail[%p] is invalidated — the load is NOT forwarded (it stays a MemLoad).
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v")),
      ir.Let(
        [],
        i32_store(ir.Var("q"), 0, ir.Var("w")),
        i32_load(ir.Var("p"), 0),
      ),
    )
  let slots = [
    ir.Local("p", ir.TI32),
    ir.Local("q", ir.TI32),
    ir.Local("v", ir.TI32),
    ir.Local("w", ir.TI32),
  ]
  let assert ir.Let(_, _, ir.Let(_, _, tail)) = fwd(slots, body)
  assert tail == i32_load(ir.Var("p"), 0)
}

pub fn no_forward_across_callhost_barrier_test() {
  // store(%p, %v); CallHost(...); load(%p)  ⟹  the call may write any memory (a barrier), so the
  // load is NOT forwarded.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v")),
      ir.Let([], ir.CallHost("env", "f", []), i32_load(ir.Var("p"), 0)),
    )
  let slots = [ir.Local("p", ir.TI32), ir.Local("v", ir.TI32)]
  let assert ir.Let(_, _, ir.Let(_, _, tail)) = fwd(slots, body)
  assert tail == i32_load(ir.Var("p"), 0)
}

pub fn no_forward_across_memgrow_barrier_test() {
  // store(%p, %v); memory.grow(1); load(%p)  ⟹  grow reallocates memory (a barrier), NOT forwarded.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v")),
      ir.Let(["_g"], ir.MemGrow(0, ir.ConstI32(1)), i32_load(ir.Var("p"), 0)),
    )
  let slots = [ir.Local("p", ir.TI32), ir.Local("v", ir.TI32)]
  let assert ir.Let(_, _, ir.Let(_, _, tail)) = fwd(slots, body)
  assert tail == i32_load(ir.Var("p"), 0)
}

pub fn no_forward_sub_width_load_test() {
  // i32.store(%p, %v) [4B]; i32.load8_u(%p) [1B]  ⟹  the sub-width load zero-extends one byte, so it
  // is a TRANSFORMATION of the bytes, not their content — never forwarded.
  let load8 = ir.MemLoad(0, ir.MemAccess(1, False), ir.Var("p"), 0, ir.TI32)
  let body = ir.Let([], i32_store(ir.Var("p"), 0, ir.Var("v")), load8)
  let slots = [ir.Local("p", ir.TI32), ir.Local("v", ir.TI32)]
  let assert ir.Let(_, _, tail) = fwd(slots, body)
  assert tail == load8
}

pub fn truncating_store_is_not_a_forward_source_test() {
  // i64.store32(%p, %v) [4B store of an i64 value] then i32.load(%p): the store wrote only the low
  // 4 bytes of the 8-byte %v, so forwarding the whole i64 into an i32 slot would be WRONG — the
  // store must NOT be a forward source, so the load stays a MemLoad.
  let store32 =
    ir.MemStore(0, ir.MemAccess(4, False), ir.Var("p"), ir.Var("v"), 0)
  let body = ir.Let([], store32, i32_load(ir.Var("p"), 0))
  // %v is declared i64 → the 4-byte store is truncating.
  let slots = [ir.Local("p", ir.TI32), ir.Local("v", ir.TI64)]
  let assert ir.Let(_, _, tail) = fwd(slots, body)
  assert tail == i32_load(ir.Var("p"), 0)
}

pub fn store_of_unknown_typed_value_is_not_a_source_test() {
  // A 4-byte store of a value whose type is NOT known (an unrecorded name) is conservatively NOT a
  // forward source — it might be an i64.store32. So the load stays a MemLoad.
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("mystery")),
      i32_load(ir.Var("p"), 0),
    )
  // "mystery" is not in params/locals → unknown type.
  let slots = [ir.Local("p", ir.TI32)]
  let assert ir.Let(_, _, tail) = fwd(slots, body)
  assert tail == i32_load(ir.Var("p"), 0)
}

pub fn forwards_across_no_clobber_control_flow_test() {
  // store(%p, %v); if (%c) {} {}; load(%p)  ⟹  Phase-10 cross-CF MemorySSA (N3): neither branch
  // clobbers %p, so the load NOW forwards %v across the if. (Phase 9 reset at every boundary; this
  // was that scope limit, lifted in Phase 10.)
  let body =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v")),
      ir.Let(
        [],
        ir.If(ir.Var("c"), [], ir.Values([]), ir.Values([])),
        i32_load(ir.Var("p"), 0),
      ),
    )
  let slots = [
    ir.Local("p", ir.TI32),
    ir.Local("v", ir.TI32),
    ir.Local("c", ir.TI32),
  ]
  let assert ir.Let(_, _, ir.Let(_, _, tail)) = fwd(slots, body)
  assert tail == ir.Values([ir.Var("v")])
}

pub fn no_forward_across_clobbering_branch_test() {
  // store(%p, %v); if (%c) { store(%p, %w) } {}; load(%p)  ⟹  a branch that stores %p CLOBBERS the
  // fact, so the load is NOT forwarded (the may-clobber analysis is the safety gate).
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
  let slots = [
    ir.Local("p", ir.TI32),
    ir.Local("v", ir.TI32),
    ir.Local("w", ir.TI32),
    ir.Local("c", ir.TI32),
  ]
  let assert ir.Let(_, _, ir.Let(_, _, tail)) = fwd(slots, body)
  assert tail == i32_load(ir.Var("p"), 0)
}

// ─────────────────────────── forwarding INSIDE a control-flow region ───────────────────────────

pub fn forwards_inside_a_loop_body_region_test() {
  // A store→load in a Loop body IS forwarded (the interior is a fresh region), proving control heads
  // are recursed into rather than skipped.
  let inner =
    ir.Let(
      [],
      i32_store(ir.Var("p"), 0, ir.Var("v")),
      ir.Let(["x"], i32_load(ir.Var("p"), 0), ir.Break("l", [ir.Var("x")])),
    )
  let body = ir.Loop("l", [], [ir.TI32], inner)
  let slots = [ir.Local("p", ir.TI32), ir.Local("v", ir.TI32)]
  let assert ir.Loop(_, _, _, ir.Let(_, _, ir.Let(_, rhs, _))) =
    fwd(slots, body)
  assert rhs == ir.Values([ir.Var("v")])
}

// ─────────────────────────── end-to-end on the real BEAM (M3, F2) ───────────────────────────

pub fn forwarding_preserves_the_value_on_beam_test() {
  // roundtrip(addr, val) = { store(addr, val); load(addr) }. Optimized (load forwarded) and
  // unoptimized must return the SAME value for an in-bounds address.
  let m = roundtrip_module()
  let opt = pass.run_pipeline(m, [mem_forward.forwarding_pass()])
  assert run(m, "roundtrip", [0, 305_419_896])
    == run(opt, "roundtrip", [0, 305_419_896])
  // and the value is actually correct (little-endian round-trip).
  assert run(opt, "roundtrip", [0, 305_419_896])
    == pipeline.Returned([305_419_896])
}

pub fn forwarding_preserves_the_oob_trap_on_beam_test() {
  // An OOB address traps at the STORE in BOTH programs (forwarding removes the load, not the store).
  let m = roundtrip_module()
  let opt = pass.run_pipeline(m, [mem_forward.forwarding_pass()])
  let unopt_out = run(m, "roundtrip", [9_000_000, 1])
  let opt_out = run(opt, "roundtrip", [9_000_000, 1])
  assert unopt_out == opt_out
  let assert pipeline.Trapped(_) = opt_out
}

// ─────────────────────────── module + run helpers ───────────────────────────

fn one_fn_module(slots: List(ir.Local), body: ir.Expr) -> ir.Module {
  ir.Module(
    name: "carder@opt@mem_forward_test",
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

/// `roundtrip(addr, val)` = store `val` at `addr`, then load it back and return it.
fn roundtrip_module() -> ir.Module {
  ir.Module(
    name: "carder@opt@mem_forward_rt",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        "roundtrip",
        [ir.Local("addr", ir.TI32), ir.Local("val", ir.TI32)],
        [ir.TI32],
        [],
        ir.Let(
          [],
          i32_store(ir.Var("addr"), 0, ir.Var("val")),
          i32_load(ir.Var("addr"), 0),
        ),
      ),
    ],
    exports: [ir.ExportFn("roundtrip", "roundtrip")],
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
