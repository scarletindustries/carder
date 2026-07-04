//// Phase-10 unit 06 — tests for range-based bounds-check elimination via loop versioning (`ir_opt/bce`).
////
//// STRUCTURAL: an eligible affine-cursor loop becomes `let guard in if guard { fast (unchecked) }
//// else { slow (checked, original) }`. END-TO-END (the load-bearing soundness proof): the versioned
//// loop returns the IDENTICAL value as the unversioned loop for an in-bounds run, AND an out-of-range
//// run TRAPS `MemoryOutOfBounds` (the guard fails → the checked slow loop runs → same trap).
//// ADVERSARIAL: a loop with a grow/call, a non-`Var(i)` address, or the wrong shape is NOT versioned.
//// Idempotence: versioning twice == once. Spec-first (D8): loop versioning preserves values + traps.

import gleam/list
import gleam/option
import twocore/ir
import twocore/middle/ir_opt/bce
import twocore/middle/ir_opt/pass
import twocore/pipeline
import twocore/runtime/profiles

fn iadd(a: ir.Value, b: ir.Value) -> ir.Expr {
  ir.Num(ir.IAdd(ir.W32), [a, b])
}

/// `sumbuf(n)` = Σ i32@i for i = 0,4,…,<n. The loads are addressed by the induction cursor `i`.
fn sumbuf_body() -> ir.Expr {
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
}

fn bce(body: ir.Expr) -> ir.Expr {
  let m = sumbuf_module(body)
  let opt = pass.run_pipeline(m, [bce.bce_pass()])
  let assert [f] = opt.functions
  f.body
}

// ─────────────────────────── recognition / versioning ───────────────────────────

pub fn eligible_loop_is_versioned_test() {
  // The whole loop becomes a guard chain: `let bce_sz = memory.size … if bce_guard { fast } { slow }`.
  let out = bce(sumbuf_body())
  // the outermost node is now a guard `let <g> = memory.size in …` wrapping the loop.
  let assert ir.Let([_], ir.MemSize(0), _) = out
  // the fast arm uses UNCHECKED loads; the slow arm keeps the CHECKED original.
  let assert ir.If(_, _, fast, slow) = innermost_if(out)
  assert contains_unchecked(fast)
  assert !contains_unchecked(slow)
}

// ─────────────────────────── end-to-end soundness on the BEAM ───────────────────────────

pub fn versioning_preserves_the_in_bounds_value_test() {
  // memory[0..16] = i32 [1,2,3,4]; sumbuf(16) = 1+2+3+4 = 10 — the SAME versioned and unversioned.
  let m = sumbuf_module(sumbuf_body())
  let opt = pass.run_pipeline(m, [bce.bce_pass()])
  assert run(m, "sumbuf", [16]) == run(opt, "sumbuf", [16])
  assert run(opt, "sumbuf", [16]) == pipeline.Returned([10])
}

pub fn versioning_preserves_the_oob_trap_test() {
  // sumbuf(9_000_000) over a 1-page (65536 B) memory traps `MemoryOutOfBounds` at i = 65536 — the
  // guard fails (9_000_004 > 65536), so the CHECKED slow loop runs and traps, exactly as unversioned.
  let m = sumbuf_module(sumbuf_body())
  let opt = pass.run_pipeline(m, [bce.bce_pass()])
  let unopt_out = run(m, "sumbuf", [9_000_000])
  let opt_out = run(opt, "sumbuf", [9_000_000])
  assert unopt_out == opt_out
  let assert pipeline.Trapped(_) = opt_out
}

// ─────────────────────────── adversarial "must NOT version" ───────────────────────────

pub fn grow_in_loop_blocks_versioning_test() {
  // A `memory.grow` in the loop could change memory.size mid-loop → NOT versioned.
  let body = with_extra_in_work(ir.MemGrow(0, ir.ConstI32(1)))
  assert !contains_unchecked(bce(body))
  let assert ir.Loop(_, _, _, _) = bce(body)
}

pub fn call_in_loop_blocks_versioning_test() {
  // A call could grow memory → NOT versioned.
  let body = with_extra_in_work(ir.CallHost("env", "f", []))
  assert !contains_unchecked(bce(body))
  let assert ir.Loop(_, _, _, _) = bce(body)
}

pub fn non_cursor_address_is_not_versioned_test() {
  // A loop whose load is addressed by a FIXED base (not the induction cursor `i`) has no recognized
  // affine access → NOT versioned.
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
            // addressed by %p (a fixed base), NOT %i.
            ["x"],
            ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("p"), 0, ir.TI32),
            ir.Let(
              ["i2"],
              iadd(ir.Var("i"), ir.ConstI32(4)),
              ir.Continue("l", [ir.Var("i2"), ir.Var("x")]),
            ),
          ),
        ),
      ),
    )
  assert !contains_unchecked(bce(body))
}

pub fn versioning_is_idempotent_test() {
  let once = bce(sumbuf_body())
  let m = sumbuf_module(once)
  let twice = pass.run_pipeline(m, [bce.bce_pass()])
  let assert [f] = twice.functions
  assert f.body == once
}

// ─────────────────────────── helpers ───────────────────────────

/// A `sumbuf`-shaped loop with `extra` spliced into the work branch (before the load) — to make it
/// contain a grow/call.
fn with_extra_in_work(extra: ir.Expr) -> ir.Expr {
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
          ["_e"],
          extra,
          ir.Let(
            ["x"],
            ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("i"), 0, ir.TI32),
            ir.Let(
              ["i2"],
              iadd(ir.Var("i"), ir.ConstI32(4)),
              ir.Continue("l", [ir.Var("i2"), ir.Var("x")]),
            ),
          ),
        ),
      ),
    ),
  )
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

/// Peel the guard `Let`-chain to the versioning `If`.
fn innermost_if(e: ir.Expr) -> ir.Expr {
  case e {
    ir.If(_, _, _, _) -> e
    ir.Let(_, _, body) -> innermost_if(body)
    _ -> e
  }
}

fn sumbuf_module(body: ir.Expr) -> ir.Module {
  ir.Module(
    name: "twocore@opt@bce_sumbuf",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function("sumbuf", [ir.Local("n", ir.TI32)], [ir.TI32], [], body),
    ],
    exports: [ir.ExportFn("sumbuf", "sumbuf")],
    // memory[0..16) = i32 little-endian [1, 2, 3, 4].
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

fn run(m: ir.Module, export: String, args: List(Int)) -> pipeline.RunResult {
  let assert Ok(core) = pipeline.ir_to_core(m, profiles.safe())
  let assert Ok(beam) = pipeline.core_to_beam(core, m.name)
  let assert Ok(proc) = pipeline.instantiate(beam, m.name)
  let out = pipeline.invoke_instance(proc, export, args)
  pipeline.stop_instance(proc)
  out
}
