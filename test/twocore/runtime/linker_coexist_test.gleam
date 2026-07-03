//// Unit 10 — the coexistence proof (high-level §13: *the instance is the unit of policy*).
////
//// The headline property the whole Unsafe phase claims: a **Safe** instance and an **Unsafe**
//// instance of the *same source module* are alive on **one node**, concurrently, with correct
//// results and **no state or capability leakage** between them (F4, unit-doc §B / Verification
//// item 4). We prove it against the SPEC, not the emitter output:
////
//// - both builds return BYTE-IDENTICAL, spec-correct results for the same export/args (F2 —
////   the Unsafe posture never changes an observable answer; compared by bit pattern, D5/D7);
//// - a mutation of the Safe instance's linear memory / mutable global is INVISIBLE to the
////   Unsafe instance and vice versa (disjoint per-process cells, spec §4.2 per-instance store);
//// - `is_safe` still distinguishes the two live instances.
////
//// The two builds are DISTINCT `.beam` modules (distinct output atoms via `profiles.coexist_name`
//// on `ir.Module.name`) sharing the identical `twocore@runtime@rt_*` runtime modules. Each
//// instance runs in its OWN owned process (`pipeline.instantiate` spawns one per instance, E1),
//// so the per-process fuel budget + host policy each `instantiate/0` seeds cannot cross.

import gleam/list
import gleam/option
import twocore/ir
import twocore/pipeline
import twocore/runtime/instance.{type Binding}
import twocore/runtime/profiles

// ─────────────────────────────── fixture ───────────────────────────────

/// A STATEFUL source module (linear memory + a mutable global) exporting:
/// - `add(i32, i32) -> i32` — pure, for the byte-identical-result check;
/// - `store(addr, val) -> i32` — writes a 4-byte word to memory and returns `val`;
/// - `load(addr) -> i32` — reads a 4-byte word from memory;
/// - `setg(v) -> i32` — sets the mutable global `g0` and returns `v`;
/// - `getg() -> i32` — reads `g0`.
///
/// `name` is the output module atom (unique per build via `profiles.coexist_name`). The store/
/// set functions RETURN a value (rather than being void) so the run-ABI marshals a plain
/// integer back; the mutation is the point, the return is just a convenient handshake.
fn state_module(name: String) -> ir.Module {
  let functions = [
    ir.Function(
      name: "add",
      params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        ["r"],
        ir.Num(ir.IAdd(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
        ir.Return([ir.Var("r")]),
      ),
    ),
    ir.Function(
      name: "store",
      params: [ir.Local("addr", ir.TI32), ir.Local("val", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        [],
        ir.MemStore(0, ir.MemAccess(4, False), ir.Var("addr"), ir.Var("val"), 0),
        ir.Return([ir.Var("val")]),
      ),
    ),
    ir.Function(
      name: "load",
      params: [ir.Local("addr", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("addr"), 0, ir.TI32),
    ),
    ir.Function(
      name: "setg",
      params: [ir.Local("v", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        [],
        ir.GlobalSet("g0", ir.Var("v")),
        ir.Return([ir.Var("v")]),
      ),
    ),
    ir.Function(
      name: "getg",
      params: [],
      result: [ir.TI32],
      locals: [],
      body: ir.GlobalGet("g0"),
    ),
  ]
  ir.Module(
    name: name,
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(0)]))],
    imports: [],
    functions: functions,
    exports: list.map(functions, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// Compile `name`'s `state_module` under `binding` all the way to a loadable `.beam`
/// (`ir_to_core` → `core_to_beam`). `let assert Ok` is the test's success contract — a
/// compile/build failure is a genuine test failure, not an expected path.
fn build(name: String, binding: Binding) -> BitArray {
  let m = state_module(name)
  let assert Ok(core) = pipeline.ir_to_core(m, binding)
  let assert Ok(beam) = pipeline.core_to_beam(core, m.name)
  beam
}

// ─────────────────────────────── the coexistence proof ───────────────────────────────

/// **Coexistence + isolation (F4, Verification item 4).** One source module compiled twice —
/// under `profiles.safe()` and `profiles.unsafe()`, with DISTINCT output atoms — loaded and
/// instantiated on one node, each in its own owned process, alive concurrently:
///
/// 1. both instances return byte-identical, spec-correct results (`add(7,35)==42`, and the
///    two's-complement wrap `0x7FFFFFFF + 1 == 0x80000000`) — the Unsafe posture changes no
///    observable answer;
/// 2. a store into the Safe instance's memory is invisible to the Unsafe instance's memory and
///    vice versa (disjoint per-process cells);
/// 3. a `global.set` on the Safe instance is invisible to the Unsafe instance and vice versa;
/// 4. `is_safe` distinguishes the two live instances.
pub fn safe_and_unsafe_coexist_with_isolated_state_test() {
  let base = "twocore@coexist@statemod"
  let safe_name = profiles.coexist_name(base, profiles.safe())
  let unsafe_name = profiles.coexist_name(base, profiles.unsafe())
  // Precondition: the two builds have DISTINCT output atoms (else the second load hot-replaces
  // the first — no coexistence).
  assert safe_name != unsafe_name

  let safe_beam = build(safe_name, profiles.safe())
  let unsafe_beam = build(unsafe_name, profiles.unsafe())

  // Both load and instantiate on the node, each in its OWN owned process (E1) — alive together.
  let assert Ok(safe_proc) = pipeline.instantiate(safe_beam, safe_name)
  let assert Ok(unsafe_proc) = pipeline.instantiate(unsafe_beam, unsafe_name)

  // (1) Byte-identical, spec-correct results under both postures (F2 / D5).
  assert pipeline.invoke_instance(safe_proc, "add", [7, 35])
    == pipeline.Returned([42])
  assert pipeline.invoke_instance(unsafe_proc, "add", [7, 35])
    == pipeline.Returned([42])
  // i32.add wraps modulo 2^32 identically in both builds.
  assert pipeline.invoke_instance(safe_proc, "add", [2_147_483_647, 1])
    == pipeline.Returned([2_147_483_648])
  assert pipeline.invoke_instance(unsafe_proc, "add", [2_147_483_647, 1])
    == pipeline.Returned([2_147_483_648])

  // (2) Memory isolation — mutate Safe, Unsafe is unchanged, and vice versa.
  assert pipeline.invoke_instance(safe_proc, "store", [0, 111])
    == pipeline.Returned([111])
  assert pipeline.invoke_instance(safe_proc, "load", [0])
    == pipeline.Returned([111])
  // The Unsafe instance's memory at the same address is still the fresh zero fill.
  assert pipeline.invoke_instance(unsafe_proc, "load", [0])
    == pipeline.Returned([0])
  // Now mutate the Unsafe instance at a different address; the Safe instance stays zero there.
  assert pipeline.invoke_instance(unsafe_proc, "store", [4, 222])
    == pipeline.Returned([222])
  assert pipeline.invoke_instance(unsafe_proc, "load", [4])
    == pipeline.Returned([222])
  assert pipeline.invoke_instance(safe_proc, "load", [4])
    == pipeline.Returned([0])

  // (3) Mutable-global isolation — set on Safe, Unsafe still reads its own init (0).
  assert pipeline.invoke_instance(safe_proc, "setg", [99])
    == pipeline.Returned([99])
  assert pipeline.invoke_instance(safe_proc, "getg", [])
    == pipeline.Returned([99])
  assert pipeline.invoke_instance(unsafe_proc, "getg", [])
    == pipeline.Returned([0])
  // And the reverse: set on Unsafe, Safe keeps its own value (99).
  assert pipeline.invoke_instance(unsafe_proc, "setg", [7])
    == pipeline.Returned([7])
  assert pipeline.invoke_instance(unsafe_proc, "getg", [])
    == pipeline.Returned([7])
  assert pipeline.invoke_instance(safe_proc, "getg", [])
    == pipeline.Returned([99])

  // (4) The two live instances are still distinguished by their policy.
  assert profiles.is_safe(profiles.instantiate(profiles.safe()))
  assert !profiles.is_safe(profiles.instantiate(profiles.unsafe()))

  pipeline.stop_instance(safe_proc)
  pipeline.stop_instance(unsafe_proc)
}
