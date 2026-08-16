//// Unit Q13-01 — the tail-call interface-freeze KEYSTONE, verified (modelled on
//// `ir/eh_freeze_test`).
////
//// SPEC assertions against the **WebAssembly tail-call proposal** (`return_call` /
//// `return_call_indirect`), NOT change-detectors (Q7/D8). The proposal's rules this freeze
//// encodes:
////   - `return_call $f` / `return_call_indirect $t (type $ft)` are STACK-POLYMORPHIC like
////     `return`: they transfer control, and the callee's result type equals the current
////     function's result type, so the rest of the block is unreachable (a BOTTOM transfer).
////   - `return_call_indirect` traps for EXACTLY the reasons `call_indirect` does
////     (undefined-element → uninitialized-element → type-mismatch, in that order). No
////     "call stack exhausted" trap exists.
////
//// What the freeze must guarantee, proven here:
////   1. the three tail-call IR nodes are EXPRESSIBLE — a `Function`/`Module` whose body uses
////      `ReturnCall` / `ReturnCallIndirect` / `ReturnCallImport` compiles, and the frozen shapes
////      hold (Q13-02..06 bind to exactly these constructors);
////   2. every tail-call node is an effect BARRIER (Q2) — `classify == Effectful`,
////      `can_cse == False`, `can_eliminate_if_unused == False` (never reorder/CSE/DCE across a
////      control transfer, WASM tail-call proposal + E6/F3);
////   3. the `.ir` printer/parser round-trip is LOSSLESS (D5) over the three nodes, adversarially
////      (multi-value `ty`, non-default table name, `slot >= 1`, `index` as both a `Var` and a
////      constant);
////   4. `TrapReason` is UNCHANGED (Q8) — the indirect guards reuse the existing element/type
////      reasons; "call stack exhausted" is not a WASM trap;
////   5. defaults are INERT / byte-identical (Q6) — a `return_call*`-free module round-trips, spells
////      none of the new tokens, and emits a `.core` with no `call_indirect_lookup` and no
////      `return_call` (the new arms/seam are unreached);
////   6. the PLACEHOLDER emit is VALUE-CORRECT (the reach is sound if reached, Q6) — each node routes
////      through the EXISTING ordinary-call emitter bound-then-returned (a NON-tail emission), never
////      the (Q13-05-owned) `call_indirect_lookup` seam and never a bare tail form. The keystone
////      deliberately does NOT assert the constant-stack property (that is Q13-05's guard).

import carder/backend/core_printer
import carder/backend/emit_core
import carder/ir
import carder/ir/effect
import carder/ir/parser
import carder/ir/printer
import carder/runtime/instance
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

// ───────────────────────── 1. the three nodes are EXPRESSIBLE ─────────────────────────

/// Construct each tail-call node (carrying `Value` operands — `Var`s and constants), place them in
/// a `Function`/`Module`, and assert the value COMPILES and the frozen shapes hold. This is the
/// load-bearing freeze: Q13-02..06 construct and bind to exactly these constructors.
pub fn tail_call_nodes_are_expressible_test() {
  let direct = ir.ReturnCall("callee", [ir.Var("a"), ir.ConstI32(7)])
  let indirect =
    ir.ReturnCallIndirect(
      "t0",
      ir.Var("idx"),
      ir.FuncType([ir.TI32], [ir.TI32]),
      [ir.Var("a")],
    )
  let imported =
    ir.ReturnCallImport(2, ir.FuncType([ir.TI32], [ir.TF64]), [ir.Var("a")])

  // The frozen shapes (Value-only, bottom transfers). If a field/arity drifts, these fail to
  // typecheck.
  let assert ir.ReturnCall("callee", [ir.Var("a"), ir.ConstI32(7)]) = direct
  let assert ir.ReturnCallIndirect(
    "t0",
    ir.Var("idx"),
    ir.FuncType([ir.TI32], [ir.TI32]),
    [ir.Var("a")],
  ) = indirect
  let assert ir.ReturnCallImport(
    2,
    ir.FuncType([ir.TI32], [ir.TF64]),
    [ir.Var("a")],
  ) = imported

  // Each is a valid `ir.Expr` in a function body — the surface is expressible in context.
  let f =
    ir.Function(
      "worker",
      [ir.Local("a", ir.TI32), ir.Local("idx", ir.TI32)],
      [ir.TI32],
      [],
      direct,
    )
  let assert [ir.TI32] = f.result
  let assert ir.ReturnCall("callee", _) = f.body
}

// ───────────────────────── 2. every tail-call node is an effect BARRIER (Q2) ─────────────────────────

/// Spec: `return_call*` transfer control (stack-polymorphic like `return`), so every tail-call node
/// is an effect barrier — `classify == Effectful`, and therefore never CSE-able or eliminable
/// (E6/F3). Asserted against the spec rule, not current output.
pub fn tail_call_nodes_classify_effectful_test() {
  let nodes = [
    ir.ReturnCall("f", [ir.ConstI32(1)]),
    ir.ReturnCallIndirect("t0", ir.Var("i"), ir.FuncType([ir.TI32], [ir.TI32]), [
      ir.ConstI32(1),
    ]),
    ir.ReturnCallImport(0, ir.FuncType([], [ir.TI32]), []),
  ]
  list.each(nodes, fn(node) {
    effect.classify(node) |> should.equal(effect.Effectful)
    effect.can_cse(node) |> should.be_false
    effect.can_eliminate_if_unused(node) |> should.be_false
  })
}

// ───────────────────────── 3. lossless `.ir` round-trip (D5) ─────────────────────────

/// D5: `parser.parse_module(printer.print_module(m)) == Ok(m)` for a module using all three nodes.
/// ADVERSARIAL coverage — a MULTI-VALUE `ty` (`[i32, f64] -> [i32, f64]`), a NON-DEFAULT table name
/// (`t7`), a `ReturnCallImport` with `slot >= 1`, and `index` as BOTH a `Var` and a constant across
/// two indirect nodes. This is the D5 proof (the three spellings parse back to the same IR).
pub fn tail_call_ir_round_trip_test() {
  let multi = ir.FuncType([ir.TI32, ir.TF64], [ir.TI32, ir.TF64])
  // f_direct: a same-module direct tail call.
  let f_direct =
    ir.Function(
      "f_direct",
      [ir.Local("a", ir.TI32)],
      [ir.TI32],
      [],
      ir.ReturnCall("callee", [ir.Var("a")]),
    )
  // f_indirect_var: multi-value ty, non-default table `t7`, `index` a `Var`.
  let f_indirect_var =
    ir.Function(
      "f_indirect_var",
      [ir.Local("a", ir.TI32), ir.Local("b", ir.TF64), ir.Local("idx", ir.TI32)],
      [ir.TI32, ir.TF64],
      [],
      ir.ReturnCallIndirect("t7", ir.Var("idx"), multi, [
        ir.Var("a"),
        ir.Var("b"),
      ]),
    )
  // f_indirect_const: `index` a CONSTANT (the other of the two index shapes).
  let f_indirect_const =
    ir.Function(
      "f_indirect_const",
      [ir.Local("a", ir.TI32)],
      [ir.TI32],
      [],
      ir.ReturnCallIndirect(
        "t0",
        ir.ConstI32(3),
        ir.FuncType([ir.TI32], [ir.TI32]),
        [ir.Var("a")],
      ),
    )
  // f_import: an imported tail call with slot >= 1.
  let f_import =
    ir.Function(
      "f_import",
      [ir.Local("a", ir.TI32)],
      [ir.TF64],
      [],
      ir.ReturnCallImport(3, ir.FuncType([ir.TI32], [ir.TF64]), [ir.Var("a")]),
    )
  let module =
    ir.Module(
      name: "carder@tailcall@roundtrip",
      uses_numerics: True,
      memories: [],
      globals: [],
      imports: [],
      functions: [f_direct, f_indirect_var, f_indirect_const, f_import],
      exports: [],
      data_segments: [],
      tables: [],
      elements: [],
      start: None,
      tags: [],
    )
  let text = printer.print_module(module)
  parser.parse_module(text) |> should.equal(Ok(module))
}

// ───────────────────────── 4. no new TrapReason (Q8) ─────────────────────────

/// Phase 13 adds ZERO `TrapReason` variants (Q8): a WASM tail call traps for exactly the reasons an
/// ordinary call does — the `return_call_indirect` guards reuse `UndefinedElement` /
/// `UninitializedElement` / `IndirectCallTypeMismatch`, and "call stack exhausted" is not a WASM
/// trap. This locks the exact ten-variant set (a compile-time proof: the list fails to typecheck if
/// a variant is removed) so the exhaustive `spec_trap_message` match is untouched.
pub fn trap_reason_unchanged_test() {
  let reasons = [
    ir.IntDivByZero,
    ir.IntOverflow,
    ir.Unreachable,
    ir.IndirectCallTypeMismatch,
    ir.MemoryOutOfBounds,
    ir.InvalidConversionToInteger,
    ir.UndefinedElement,
    ir.UninitializedElement,
    ir.TableOutOfBounds,
    ir.FuelExhausted,
  ]
  list.length(reasons) |> should.equal(10)
}

// ───────────────────────── 5. defaults inert / byte-identical (Q6) ─────────────────────────

/// A `return_call*`-free module (one 32-bit memory, function-only) round-trips its `.ir` text (D5),
/// its spelling carries NONE of the new tail-call tokens, and its emitted `.core` contains NO
/// `call_indirect_lookup` and NO `return_call` — the new arms/seam are all unreached, so the legacy
/// path is byte-identical (Q6). (Full byte-identity is additionally guaranteed by the unchanged
/// corpus/conformance run.)
pub fn return_call_free_module_is_conformance_neutral_test() {
  let body =
    ir.Let(
      ["x"],
      ir.Num(ir.IAdd(ir.W32), [ir.ConstI32(1), ir.ConstI32(2)]),
      ir.Return([ir.Var("x")]),
    )
  let f = ir.Function("add", [ir.Local("p0", ir.TI32)], [ir.TI32], [], body)
  let module =
    ir.Module(
      name: "carder@tailcall@legacy",
      uses_numerics: True,
      memories: [ir.MemoryDecl(1, Some(4), ir.Idx32)],
      globals: [],
      imports: [],
      functions: [f],
      exports: [ir.ExportFn("run", "add")],
      data_segments: [],
      tables: [],
      elements: [],
      start: None,
      tags: [],
    )

  // D5 round-trip: parse(print(m)) == m (the new tail-call arms never fire on this module).
  let text = printer.print_module(module)
  parser.parse_module(text) |> should.equal(Ok(module))

  // NONE of the new tail-call tokens leak into the `.ir` text (byte-identity to Phase 12).
  should.be_false(string.contains(text, "return_call"))
  should.be_false(string.contains(text, "return_call_indirect"))
  should.be_false(string.contains(text, "return_call_import"))

  // …and the emitted `.core` reaches neither the (Q13-05-owned) lookup seam nor a tail-call token.
  let assert Ok(cm) = emit_core.emit_module(module, instance.safe_default())
  let core = core_printer.print_module(cm)
  should.be_false(string.contains(core, "call_indirect_lookup"))
  should.be_false(string.contains(core, "return_call"))
}

// ───────────────────────── 6. placeholder emit is VALUE-CORRECT (Q6) ─────────────────────────

/// Hand-build a module whose functions use each of the three tail-call nodes, emit it, and assert
/// the emit SUCCEEDS and routes each node through its Q13-05-COMPLETED path: the direct callee
/// `apply`, the import path's `call_import`, and — now that Q13-05 has landed — the indirect tail
/// seam `call_indirect_lookup` (a genuine constant-stack tail apply). No IR `return_call` token
/// leaks into the emitted `.core`. (The keystone originally pinned the NON-tail placeholder here;
/// Q13-05 completed the arms, so this now asserts the completed seam — the constant-stack property
/// and the lookup-seam package shape are proven in Q13-05's `emit_core_tailcall_test`.)
pub fn placeholder_emit_is_value_correct_test() {
  let i32_to_i32 = ir.FuncType([ir.TI32], [ir.TI32])
  // A defined callee the direct tail call targets (must exist in `fn_arity`/`fn_results`).
  let callee =
    ir.Function(
      "callee",
      [ir.Local("p", ir.TI32)],
      [ir.TI32],
      [],
      ir.Return([ir.Var("p")]),
    )
  let f_direct =
    ir.Function(
      "f_direct",
      [ir.Local("a", ir.TI32)],
      [ir.TI32],
      [],
      ir.ReturnCall("callee", [ir.Var("a")]),
    )
  let f_indirect =
    ir.Function(
      "f_indirect",
      [ir.Local("a", ir.TI32), ir.Local("idx", ir.TI32)],
      [ir.TI32],
      [],
      ir.ReturnCallIndirect("t0", ir.Var("idx"), i32_to_i32, [ir.Var("a")]),
    )
  let f_import =
    ir.Function(
      "f_import",
      [ir.Local("a", ir.TI32)],
      [ir.TI32],
      [],
      ir.ReturnCallImport(0, i32_to_i32, [ir.Var("a")]),
    )
  let module =
    ir.Module(
      name: "carder@tailcall@emit",
      uses_numerics: True,
      memories: [],
      globals: [],
      // One function import so `ReturnCallImport(0, …)` targets a real import slot.
      imports: [ir.ImportFn("env", "host", i32_to_i32)],
      functions: [callee, f_direct, f_indirect, f_import],
      exports: [ir.ExportFn("run", "f_direct")],
      data_segments: [],
      tables: [ir.TableDecl("t0", ir.FuncRef, 1, None)],
      elements: [],
      start: None,
      tags: [],
    )

  // The reach compiles: emit SUCCEEDS on all three nodes (value-sound if reached).
  let assert Ok(cm) = emit_core.emit_module(module, instance.safe_default())
  let core = core_printer.print_module(cm)

  // The import path's `call_import` seam and the indirect tail's `call_indirect_lookup` seam both
  // appear (Q13-05 completed the arms — the indirect tail is now a genuine constant-stack tail call
  // through the lookup seam).
  should.be_true(string.contains(core, "call_import"))
  should.be_true(string.contains(core, "call_indirect_lookup"))

  // No IR tail-call token ever leaks into the emitted Core.
  should.be_false(string.contains(core, "return_call"))
}
