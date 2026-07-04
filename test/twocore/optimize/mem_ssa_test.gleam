//// Phase-9 unit 01 — tests for the MemorySSA + linear-memory alias analysis (`ir_opt/mem_ssa`).
////
//// These pin the ANALYSIS behaviour AND the safety invariants (M5). Per D8 every assertion is
//// against the soundness requirement, never a change-detector: `alias` must default to `MayAlias`
//// and only prove `MustAlias`/`NoAlias` structurally; `is_memory_barrier` must FORGET memory on a
//// call/grow/bulk/control node; `byte_width` must reject sub-width/truncating footprints. A false
//// `NoAlias` or a false "transparent" is silent memory corruption — the adversarial fixtures are
//// the tripwires against it. Spec anchor: WASM §4.2 (memories are disjoint stores), §4.4.7 (a
//// memarg access touches `[addr+offset, addr+offset+width)`).

import gleam/list
import gleam/option
import twocore/ir
import twocore/middle/ir_opt/mem_ssa.{
  type Footprint, Footprint, MayAlias, MustAlias, NoAlias, alias, byte_width,
  count_mem_ops, footprint_of, is_memory_barrier,
}

// ───────────────────────────── shared fixtures ─────────────────────────────

/// `i32.load %p + off` (natural-width, 4 bytes).
fn load_i32(base: ir.Value, off: Int) -> ir.Expr {
  ir.MemLoad(0, ir.MemAccess(4, False), base, off, ir.TI32)
}

/// `i32.store %v at %p + off` (natural-width, 4 bytes).
fn store_i32(base: ir.Value, off: Int, v: ir.Value) -> ir.Expr {
  ir.MemStore(0, ir.MemAccess(4, False), base, v, off)
}

/// A footprint at memory `mem`, base `base`, `off`, `bytes` — for direct `alias` tests.
fn fp(mem: Int, base: ir.Value, off: Int, bytes: Int) -> Footprint {
  Footprint(mem: mem, addr: base, offset: off, bytes: bytes)
}

// ─────────────────────────── footprint_of ───────────────────────────

pub fn footprint_of_load_and_store_test() {
  assert footprint_of(load_i32(ir.Var("p"), 8))
    == Ok(Footprint(0, ir.Var("p"), 8, 4))
  assert footprint_of(store_i32(ir.Var("p"), 8, ir.Var("v")))
    == Ok(Footprint(0, ir.Var("p"), 8, 4))
}

pub fn footprint_of_non_access_is_error_test() {
  // MemSize / a bulk op / a pure op are NOT scalar footprints.
  assert footprint_of(ir.MemSize(0)) == Error(Nil)
  assert footprint_of(ir.MemFill(0, ir.Var("d"), ir.ConstI32(0), ir.Var("n")))
    == Error(Nil)
  assert footprint_of(ir.Num(ir.IAdd(ir.W32), [ir.Var("a"), ir.Var("b")]))
    == Error(Nil)
}

// ─────────────────────────── alias — positive proofs ───────────────────────────

pub fn alias_identical_footprint_is_must_test() {
  // Same mem, same base Value, same offset, same width → the exact same bytes.
  assert alias(fp(0, ir.Var("p"), 0, 4), fp(0, ir.Var("p"), 0, 4)) == MustAlias
  assert alias(fp(0, ir.ConstI32(16), 4, 8), fp(0, ir.ConstI32(16), 4, 8))
    == MustAlias
}

pub fn alias_different_memory_is_noalias_test() {
  // Memories are disjoint address spaces (multi-memory) — even at the same base/offset.
  assert alias(fp(0, ir.Var("p"), 0, 4), fp(1, ir.Var("p"), 0, 4)) == NoAlias
}

pub fn alias_same_base_disjoint_offsets_is_noalias_test() {
  // The Array-SSA element disambiguation: base+0/4B and base+4/4B do NOT overlap.
  assert alias(fp(0, ir.Var("p"), 0, 4), fp(0, ir.Var("p"), 4, 4)) == NoAlias
  // symmetric
  assert alias(fp(0, ir.Var("p"), 4, 4), fp(0, ir.Var("p"), 0, 4)) == NoAlias
  // a gap between them is still disjoint
  assert alias(fp(0, ir.Var("p"), 0, 4), fp(0, ir.Var("p"), 100, 8)) == NoAlias
}

// ─────────────────────────── alias — adversarial "must be MayAlias" ───────────────────────────
// These are the tripwires: a future "optimization" that narrows any of them to NoAlias/MustAlias
// is silent memory corruption and MUST break a test here.

pub fn alias_different_var_bases_is_may_test() {
  // Two distinct dynamic bases: UNDECIDABLE (they might hold the same address). Never NoAlias.
  assert alias(fp(0, ir.Var("p"), 0, 4), fp(0, ir.Var("q"), 0, 4)) == MayAlias
}

pub fn alias_var_vs_const_base_is_may_test() {
  // A dynamic base vs a constant address: also undecidable (the Var might equal the constant).
  assert alias(fp(0, ir.Var("p"), 0, 4), fp(0, ir.ConstI32(0), 0, 4))
    == MayAlias
}

pub fn alias_same_base_partial_overlap_is_may_test() {
  // base+0/4B vs base+2/4B: overlapping bytes [2,4), not identical → MayAlias.
  assert alias(fp(0, ir.Var("p"), 0, 4), fp(0, ir.Var("p"), 2, 4)) == MayAlias
}

pub fn alias_same_base_same_offset_different_width_is_may_test() {
  // base+0/4B vs base+0/8B: the 4-byte range is contained in the 8-byte one → overlap, not
  // identical → MayAlias (NOT MustAlias — they do not touch the SAME bytes).
  assert alias(fp(0, ir.Var("p"), 0, 4), fp(0, ir.Var("p"), 0, 8)) == MayAlias
}

// ─────────────────────────── alias — soundness properties ───────────────────────────

/// A curated representative set of footprints exercising every lattice case.
fn footprint_zoo() -> List(Footprint) {
  [
    fp(0, ir.Var("p"), 0, 4),
    fp(0, ir.Var("p"), 4, 4),
    fp(0, ir.Var("p"), 2, 4),
    fp(0, ir.Var("p"), 0, 8),
    fp(0, ir.Var("q"), 0, 4),
    fp(0, ir.ConstI32(16), 0, 4),
    fp(1, ir.Var("p"), 0, 4),
    fp(0, ir.Var("p"), 8, 1),
  ]
}

pub fn alias_is_symmetric_test() {
  // alias(a,b) == alias(b,a) for every pair — the relation is order-independent.
  let zoo = footprint_zoo()
  list.each(zoo, fn(a) {
    list.each(zoo, fn(b) {
      assert alias(a, b) == alias(b, a)
    })
  })
}

pub fn must_alias_implies_equal_footprint_test() {
  // A MustAlias is returned ONLY for identical footprints — never a lie.
  let zoo = footprint_zoo()
  list.each(zoo, fn(a) {
    list.each(zoo, fn(b) {
      let ok = case alias(a, b) {
        MustAlias -> a == b
        _ -> True
      }
      assert ok
    })
  })
}

pub fn noalias_implies_genuinely_disjoint_test() {
  // A NoAlias is returned ONLY when the byte intervals are genuinely disjoint (re-derived here,
  // not trusting the oracle) — so a NoAlias is never a false claim of independence.
  let zoo = footprint_zoo()
  list.each(zoo, fn(a) {
    list.each(zoo, fn(b) {
      let ok = case alias(a, b) {
        NoAlias -> ranges_disjoint(a, b)
        _ -> True
      }
      assert ok
    })
  })
}

/// Test-side ground truth: two footprints touch genuinely disjoint bytes iff they are in different
/// memories, OR (same memory) their bases are syntactically equal AND the byte intervals do not
/// overlap. (Different bases can NEVER be proven disjoint here — matching the analysis' ceiling.)
fn ranges_disjoint(a: Footprint, b: Footprint) -> Bool {
  case a.mem != b.mem {
    True -> True
    False ->
      a.addr == b.addr
      && { a.offset + a.bytes <= b.offset || b.offset + b.bytes <= a.offset }
  }
}

// ─────────────────────────── is_memory_barrier ───────────────────────────

pub fn barriers_forget_memory_test() {
  // MUST forget: grow (reallocates), a call (may write any memory), a bulk write, and every
  // control-flow / region head.
  assert is_memory_barrier(ir.MemGrow(0, ir.ConstI32(1))) == True
  assert is_memory_barrier(ir.CallHost("env", "f", [])) == True
  assert is_memory_barrier(ir.CallDirect("g", [])) == True
  assert is_memory_barrier(ir.MemFill(
      0,
      ir.Var("d"),
      ir.ConstI32(0),
      ir.Var("n"),
    ))
    == True
  assert is_memory_barrier(ir.Return([])) == True
  assert is_memory_barrier(ir.Trap(ir.Unreachable)) == True
  assert is_memory_barrier(ir.Loop("l", [], [], ir.Values([]))) == True
  assert is_memory_barrier(ir.If(ir.Var("c"), [], ir.Values([]), ir.Values([])))
    == True
}

pub fn transparent_nodes_keep_memory_test() {
  // MUST keep memory knowledge: the footprints themselves (handled precisely by the walkers),
  // read-only / disjoint-state ops, and pure value ops.
  assert is_memory_barrier(load_i32(ir.Var("p"), 0)) == False
  assert is_memory_barrier(store_i32(ir.Var("p"), 0, ir.Var("v"))) == False
  assert is_memory_barrier(ir.MemSize(0)) == False
  assert is_memory_barrier(ir.GlobalGet("g")) == False
  assert is_memory_barrier(ir.GlobalSet("g", ir.ConstI32(1))) == False
  assert is_memory_barrier(ir.Charge(1, ir.Values([]))) == False
  assert is_memory_barrier(ir.Num(ir.IAdd(ir.W32), [ir.Var("a"), ir.Var("b")]))
    == False
  assert is_memory_barrier(ir.Values([ir.Var("x")])) == False
}

// ─────────────────────────── byte_width + the truncation guard ───────────────────────────

pub fn byte_width_of_value_types_test() {
  assert byte_width(ir.TI32) == Ok(4)
  assert byte_width(ir.TF32) == Ok(4)
  assert byte_width(ir.TI64) == Ok(8)
  assert byte_width(ir.TF64) == Ok(8)
  assert byte_width(ir.TV128) == Ok(16)
  // reference / term types are not linear-memory-representable.
  assert byte_width(ir.TTerm) == Error(Nil)
  assert byte_width(ir.TFuncRef) == Error(Nil)
  assert byte_width(ir.TExternRef) == Error(Nil)
  assert byte_width(ir.TExnRef) == Error(Nil)
}

pub fn natural_width_recognises_sub_width_and_truncating_accesses_test() {
  // A natural-width access has `op.bytes == byte_width(type)`.
  // i32.load (4 bytes, result TI32/width 4) IS natural.
  let assert Ok(w_i32) = byte_width(ir.TI32)
  assert w_i32 == 4
  // i32.load8_u (1 byte, result TI32/width 4) is NOT natural — a forward target would zero-extend.
  let load8 = ir.MemLoad(0, ir.MemAccess(1, False), ir.Var("p"), 0, ir.TI32)
  let assert Ok(f8) = footprint_of(load8)
  assert f8.bytes != w_i32
  // i64.store32 (4 bytes, value type TI64/width 8) is NOT natural — a forward source would drop
  // the high 4 bytes of the i64 value.
  let assert Ok(w_i64) = byte_width(ir.TI64)
  let store32 =
    ir.MemStore(0, ir.MemAccess(4, False), ir.Var("p"), ir.Var("v"), 0)
  let assert Ok(f32) = footprint_of(store32)
  assert f32.bytes != w_i64
}

// ─────────────────────────── count_mem_ops (the n_mem measure) ───────────────────────────

pub fn count_mem_ops_counts_loads_and_stores_test() {
  // Body: let a = load; store; if (nested load in each arm); charge(store).
  let body =
    ir.Let(
      ["a"],
      load_i32(ir.Var("p"), 0),
      ir.Let(
        [],
        store_i32(ir.Var("p"), 4, ir.Var("a")),
        ir.If(
          ir.Var("c"),
          [],
          load_i32(ir.Var("p"), 8),
          ir.Charge(1, store_i32(ir.Var("p"), 12, ir.ConstI32(0))),
        ),
      ),
    )
  // 1 load + 1 store + 1 load (then-arm) + 1 store (charge/else-arm) = 4.
  assert count_mem_ops(mod_with_body(body)) == 4
}

pub fn count_mem_ops_zero_on_memory_free_module_test() {
  let body = ir.Num(ir.IAdd(ir.W32), [ir.Var("a"), ir.Var("b")])
  assert count_mem_ops(mod_with_body(body)) == 0
}

// ───────────────────────────── module helper ─────────────────────────────

/// A one-function module whose body is `body`.
fn mod_with_body(body: ir.Expr) -> ir.Module {
  ir.Module(
    name: "twocore@opt@mem_ssa_test",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function(name: "f", params: [], result: [], locals: [], body: body),
    ],
    exports: [],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}
