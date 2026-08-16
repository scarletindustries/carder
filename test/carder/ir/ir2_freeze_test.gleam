//// Unit 01 — `«IR2-FROZEN»` verification (Phase-2 keystone).
////
//// This is the freeze's "strawman": it hand-builds ONE IR2 `Module` exercising every gap
//// the Phase-2 interface freeze closed — module `tables`/`elements`/`start`, the
//// `MemSize`/`MemGrow` expr nodes, a sign-extending `MemLoad` carrying a result `ValType`,
//// a float comparison (`FLt`), and a TRAPPING `TruncS` conversion — to PROVE the frozen
//// types can express the Phase-2 surface before any downstream unit builds on them.
////
//// The assertions are against the documented contract of the types (and the WASM-spec
//// trap-message substrings via `rt_trap`), not against any printer output — so this is a
//// spec test (D8), not a change-detector. Construction alone proves the types typecheck;
//// the assertions pin the load-bearing distinctions the freeze introduced.

import carder/ir
import carder/runtime/rt_trap
import gleam/option.{Some}

// ───────────────────────────── the IR2 module under test ─────────────────────────────

/// Builds an IR2 module that uses the full Phase-2 gap surface:
/// - a funcref `table` + an active `element` segment + a `start` function;
/// - a body with `MemSize`, `MemGrow`, a sign-extending `MemLoad` (`i64.load8_s`), an
///   `FLt` float comparison, and a trapping `TruncS` (f32 → i32) conversion.
fn ir2_module() -> ir.Module {
  ir.Module(
    name: "carder@wasm@ir2_freeze",
    uses_numerics: True,
    memories: [
      ir.MemoryDecl(min_pages: 1, max_pages: Some(4), idx_type: ir.Idx32),
    ],
    globals: [],
    imports: [],
    functions: [worker_function(), init_function()],
    exports: [ir.ExportFn("run", "worker")],
    data_segments: [],
    // NEW Phase-2 module fields:
    tables: [ir.TableDecl(name: "t0", ref_ty: ir.FuncRef, min: 2, max: Some(8))],
    elements: [
      ir.ElementSegment(
        mode: ir.ElemActive(table: "t0", offset: ir.Values([ir.ConstI32(0)])),
        ref_ty: ir.FuncRef,
        init: [ir.RefFunc("worker"), ir.RefFunc("init")],
      ),
    ],
    start: Some("init"),
    tags: [],
  )
}

/// The body exercising `MemSize`/`MemGrow`/sign-extending `MemLoad`/`FLt`/trapping `TruncS`.
fn worker_function() -> ir.Function {
  ir.Function(
    name: "worker",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI64],
    locals: [],
    body: ir.Let(
      ["sz"],
      ir.MemSize(0),
      ir.Let(
        ["prev"],
        ir.MemGrow(0, ir.ConstI32(1)),
        ir.Let(
          // i64.load8_s: 1 byte, sign-extended, RESULT TI64 (distinct from i32.load8_s).
          ["x"],
          ir.MemLoad(
            0,
            ir.MemAccess(bytes: 1, signed: True),
            ir.Var("p0"),
            0,
            ir.TI64,
          ),
          ir.Let(
            // a float comparison: 1.0 < 2.0 → i32 truth value.
            ["cmp"],
            ir.Num(ir.FLt(ir.FW32), [
              ir.ConstF32(0x3f80_0000),
              ir.ConstF32(0x4000_0000),
            ]),
            ir.Let(
              // a TRAPPING float→int truncation: trunc_f32_s(3.14).
              ["t"],
              ir.Convert(ir.TruncS(ir.FW32, ir.W32), ir.ConstF32(0x4049_0fdb)),
              ir.Return([ir.Var("x")]),
            ),
          ),
        ),
      ),
    ),
  )
}

/// A trivial start function (run once at instantiation, per the contract).
fn init_function() -> ir.Function {
  ir.Function(
    name: "init",
    params: [],
    result: [],
    locals: [],
    body: ir.Values([]),
  )
}

// ───────────────────────────── tests ─────────────────────────────

/// The module typechecks and its new module-level fields hold the expected declarations.
pub fn ir2_module_typechecks_test() {
  let m = ir2_module()
  assert m.tables
    == [ir.TableDecl(name: "t0", ref_ty: ir.FuncRef, min: 2, max: Some(8))]
  assert m.elements
    == [
      ir.ElementSegment(
        mode: ir.ElemActive(table: "t0", offset: ir.Values([ir.ConstI32(0)])),
        ref_ty: ir.FuncRef,
        init: [ir.RefFunc("worker"), ir.RefFunc("init")],
      ),
    ]
  assert m.start == Some("init")
  // The start name resolves to a defined function.
  assert ir.signature(init_function()) == ir.FuncType(params: [], results: [])
}

/// An `i64.load8_s` / `i32.load8_s` builder: same `MemAccess(1, signed)`, parametric on the
/// result valtype (so the distinction lives entirely in the `result` field).
fn load8s(result: ir.ValType) -> ir.Expr {
  ir.MemLoad(0, ir.MemAccess(bytes: 1, signed: True), ir.Var("a"), 0, result)
}

/// The `MemLoad` result `ValType` discriminates `i32.load8_s` from `i64.load8_s` — same
/// `MemAccess(1, signed: True)`, different result type. This is exactly why the freeze added
/// the `result` field (the two were indistinguishable before). Destructure each load and
/// confirm it carries the expected result valtype.
pub fn memload_result_discriminates_test() {
  let assert ir.MemLoad(_, ir.MemAccess(1, True), _, _, r32) = load8s(ir.TI32)
  let assert ir.MemLoad(_, ir.MemAccess(1, True), _, _, r64) = load8s(ir.TI64)
  assert r32 == ir.TI32
  assert r64 == ir.TI64
}

/// Classify a `ConvOp` as a TRAPPING float→int truncation (vs the saturating family).
fn is_trapping_trunc(op: ir.ConvOp) -> Bool {
  case op {
    ir.TruncS(_, _) | ir.TruncU(_, _) -> True
    _ -> False
  }
}

/// The trapping `TruncS`/`TruncU` are DISTINCT `ConvOp`s from the saturating
/// `TruncSatS`/`TruncSatU` — same widths, different trapping behaviour (the spec's two
/// truncation families). The freeze must keep them separable.
pub fn trapping_trunc_distinct_from_saturating_test() {
  assert is_trapping_trunc(ir.TruncS(ir.FW32, ir.W32)) == True
  assert is_trapping_trunc(ir.TruncU(ir.FW64, ir.W64)) == True
  assert is_trapping_trunc(ir.TruncSatS(ir.FW32, ir.W32)) == False
  assert is_trapping_trunc(ir.TruncSatU(ir.FW64, ir.W64)) == False
}

/// The four new `TrapReason`s map to the exact WASM-spec `assert_trap` message substrings
/// (the suite matches these). Cited from the WebAssembly spec test expectations.
pub fn new_trap_messages_match_spec_test() {
  assert rt_trap.spec_trap_message(ir.InvalidConversionToInteger)
    == "invalid conversion to integer"
  assert rt_trap.spec_trap_message(ir.UndefinedElement) == "undefined element"
  assert rt_trap.spec_trap_message(ir.UninitializedElement)
    == "uninitialized element"
  assert rt_trap.spec_trap_message(ir.TableOutOfBounds)
    == "out of bounds table access"
}
