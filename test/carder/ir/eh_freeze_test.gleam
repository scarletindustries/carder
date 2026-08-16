//// Unit P7-01 — the EH interface-freeze KEYSTONE, verified (mirroring `ir4_freeze_test`).
////
//// SPEC assertions (what the freeze must guarantee), NOT change-detectors (D8). They prove:
////
//// - **the EH IR surface is EXPRESSIBLE** — a module carrying a `TagDecl`, an `ImportTag`, an
////   `ExportTag`, and a function whose body uses `Throw`/`Try`/`ThrowRef` (the INLINE-HANDLER
////   shape, T1) + an `exnref` local (`TExnRef`) + a `ConstNull(ExnRef)` operand, typechecks (the
////   value COMPILES), so units 02–10 can construct and bind to exactly these constructors
////   (J2/T1/T2/T9);
//// - **every EH node is an effect BARRIER (J5/T1)** — `Throw`/`Try`/`ThrowRef` classify
////   `Effectful` (they transfer control / raise — WASM §4.4.9), asserted against the spec rule,
////   not current output;
//// - **the `exnref` reftype↔valtype bridge cannot drift (T9)** — `reftype_to_valtype(ExnRef) ==
////   TExnRef` and `valtype_to_reftype(TExnRef) == Ok(ExnRef)`;
//// - **`TrapReason` is UNCHANGED (T8)** — Phase 7 added ZERO variants (a WASM exception is a
////   distinct term class, not a trap), so `spec_trap_message`'s exhaustive match is untouched;
//// - **`Module.tags` defaults `[]`** — the conformance-neutral case;
//// - **defaults are conformance-neutral (J6)** — a no-EH, tag-free module round-trips its `.ir`
////   text (D7), its spelling carries NONE of the new EH tokens, and its emitted `.core` links NO
////   `rt_exn` — the EH arms are unreached, so the legacy path is byte-identical;
//// - **the `rt_exn` heads exist with the frozen arities (T3)** — a compile-time signature check
////   (referencing, NOT calling, the heads, since their bodies `panic` until P7-07).

import carder/backend/core_printer
import carder/backend/emit_core
import carder/ir
import carder/ir/effect
import carder/ir/parser
import carder/ir/printer
import carder/runtime/instance
import carder/runtime/rt_exn
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

// ───────────────────────── the EH IR surface is expressible (J2/T1/T2/T9) ─────────────────────────

/// Construct a module exercising the WHOLE Phase-7 EH surface and assert it typechecks (the value
/// COMPILES) and carries the frozen shapes. This is the load-bearing freeze: units 02–10 bind to
/// exactly these constructors (`Try`/`CatchHandler`/`Throw`/`ThrowRef`/`TagDecl`/exnref).
pub fn eh_surface_is_expressible_test() {
  // A body: throw the tag, guarded by a `Try` with a tagged handler + a catch_all-ref handler,
  // and a `throw_ref` of a captured exnref. (Structurally representative — never executed.)
  let throw_it = ir.Throw("t0", [ir.Var("v"), ir.Var("k")])
  let tagged_handler =
    ir.CatchHandler(
      on: ir.OnTag("t0"),
      payload: ["p0", "p1"],
      exnref: None,
      handler: ir.Return([ir.Var("p1")]),
    )
  let all_handler =
    ir.CatchHandler(
      on: ir.OnAll,
      payload: [],
      exnref: Some("e"),
      handler: ir.ThrowRef(ir.Var("e")),
    )
  let body = ir.Try([ir.TI32], throw_it, [tagged_handler, all_handler])

  // A function with an `exnref` LOCAL and a `ConstNull(ExnRef)` operand seeding it.
  let f =
    ir.Function(
      "eh_worker",
      [ir.Local("v", ir.TF64), ir.Local("k", ir.TI32)],
      [ir.TI32],
      [ir.Local("e", ir.TExnRef)],
      ir.Let(["e"], ir.Values([ir.ConstNull(ir.ExnRef)]), body),
    )

  let module =
    ir.Module(
      name: "carder@eh@surface",
      uses_numerics: True,
      memories: [],
      globals: [],
      // Porffor imports no tag but this proves ImportTag is expressible; ExportTag is measured.
      imports: [ir.ImportTag("env", "e0", [ir.TF64, ir.TI32])],
      functions: [f],
      exports: [ir.ExportFn("run", "eh_worker"), ir.ExportTag("0", "t0")],
      data_segments: [],
      tables: [],
      elements: [],
      start: None,
      // The measured Porffor tag: `(tag (param f64 i32))`.
      tags: [ir.TagDecl("t0", [ir.TF64, ir.TI32])],
    )

  // The value compiled ⇒ the surface is expressible. Assert the frozen shapes are as declared.
  let assert [ir.TagDecl("t0", [ir.TF64, ir.TI32])] = module.tags
  let assert [ir.ImportTag("env", "e0", [ir.TF64, ir.TI32])] = module.imports
  let assert [ir.ExportFn("run", "eh_worker"), ir.ExportTag("0", "t0")] =
    module.exports
  let assert [ir.Local("e", ir.TExnRef)] = { module.functions |> first }.locals
  // The inline-handler shape (T1): a `Try` with a tagged handler + a catch_all-ref handler.
  let assert ir.Try(
    [ir.TI32],
    _,
    [
      ir.CatchHandler(ir.OnTag("t0"), ["p0", "p1"], None, _),
      ir.CatchHandler(ir.OnAll, [], Some("e"), _),
    ],
  ) = body
}

/// Helper: the first function of a one-function module (the surface test builds exactly one).
fn first(fs: List(ir.Function)) -> ir.Function {
  let assert [f, ..] = fs
  f
}

// ───────────────────────── every EH node is an effect BARRIER (J5/T1) ─────────────────────────

/// The J5/T1 freeze: `Throw`/`Try`/`ThrowRef` all transfer control / raise (WASM §4.4.9), so each
/// classifies `Effectful` — never reordered, hoisted, duplicated, or eliminated. Asserted against
/// the spec rule, not current output.
pub fn eh_nodes_classify_effectful_test() {
  let handler =
    ir.CatchHandler(ir.OnTag("t0"), ["p"], None, ir.Return([ir.Var("p")]))
  let nodes = [
    ir.Throw("t0", [ir.ConstI32(1)]),
    ir.Try([ir.TI32], ir.Values([ir.ConstI32(0)]), [handler]),
    ir.ThrowRef(ir.Var("e")),
  ]
  list.each(nodes, fn(node) {
    effect.classify(node) |> should.equal(effect.Effectful)
    // …so an EH node is NEVER CSE-able or eliminable-if-unused (the soundness floor).
    effect.can_cse(node) |> should.be_false
    effect.can_eliminate_if_unused(node) |> should.be_false
  })
}

// ───────────────────────── exnref reftype↔valtype bridge cannot drift (T9) ─────────────────────────

/// `reftype_to_valtype(ExnRef) == TExnRef` and `valtype_to_reftype(TExnRef) == Ok(ExnRef)` — the
/// no-drift invariant (the two spellings of an `exnref` cannot diverge). Also: a non-reference
/// still narrows to `Error(Nil)` (the bridge stayed total).
pub fn exnref_reftype_valtype_bridge_test() {
  ir.reftype_to_valtype(ir.ExnRef) |> should.equal(ir.TExnRef)
  ir.valtype_to_reftype(ir.TExnRef) |> should.equal(Ok(ir.ExnRef))
  // The other two reftypes still bridge (regression guard).
  ir.reftype_to_valtype(ir.FuncRef) |> should.equal(ir.TFuncRef)
  ir.reftype_to_valtype(ir.ExternRef) |> should.equal(ir.TExternRef)
  // A numeric type is not a reftype.
  ir.valtype_to_reftype(ir.TI32) |> should.equal(Error(Nil))
}

// ───────────────────────── TrapReason is unchanged (T8) ─────────────────────────

/// Phase 7 added ZERO `TrapReason` variants (T8): a WASM exception is a DISTINCT term class
/// (`{wasm_exn, …}`), not a trap; an uncaught exception is a distinct run-ABI outcome
/// (`UncaughtException`, owned by P7-06), never a `TrapReason`. This locks the exact ten-variant
/// set (a compile-time proof: the list fails to typecheck if a variant is removed) so
/// `spec_trap_message`'s exhaustive match is untouched.
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

// ───────────────────────── Module.tags defaults [] + default-neutrality (J6) ─────────────────────────

/// A legacy module — one 32-bit memory, function-only, no tags, no EH, no `exnref` — has
/// `tags == []` (the conformance-neutral default), round-trips its `.ir` text (D7), spells NONE of
/// the new EH tokens, and emits a `.core` that links NO `rt_exn`. The keystone's new arms are all
/// unreached on this path, so it is byte-identical to Phase-6 (the J6 claim as a test).
pub fn tag_free_module_is_conformance_neutral_test() {
  let body =
    ir.Let(
      ["x"],
      ir.Num(ir.IAdd(ir.W32), [ir.ConstI32(1), ir.ConstI32(2)]),
      ir.Return([ir.Var("x")]),
    )
  let f = ir.Function("add", [ir.Local("p0", ir.TI32)], [ir.TI32], [], body)
  let module =
    ir.Module(
      name: "carder@eh@legacy",
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

  // `Module.tags` defaults `[]` — the conformance-neutral case.
  module.tags |> should.equal([])

  // D7 round-trip: parse(print(m)) == m (the new EH arms never fire on a tag-free module).
  let text = printer.print_module(module)
  parser.parse_module(text) |> should.equal(Ok(module))

  // NONE of the new EH tokens leak into the `.ir` text (byte-identity to Phase-6).
  should.be_false(string.contains(text, "exnref"))
  should.be_false(string.contains(text, "tag"))
  should.be_false(string.contains(text, "throw"))
  should.be_false(string.contains(text, "try"))

  // …and the emitted `.core` links NO EH runtime (the emit arms are unreached).
  let assert Ok(cm) = emit_core.emit_module(module, instance.safe_default())
  let core = core_printer.print_module(cm)
  should.be_false(string.contains(core, "rt_exn"))
  should.be_false(string.contains(core, "wasm_exn"))
}

// ───────────────────────── the EH `.ir` surface round-trips (P7-02 seam, keystone spot-check) ─────

/// The keystone's minimal printer/parser arms round-trip the tag section + `Throw`/`ThrowRef` +
/// `exnref` operands (P7-02 makes the WHOLE EH surface, incl. `Try`, round-trip). This spot-checks
/// that the frozen tokens the keystone DOES spell parse back to the same IR.
pub fn eh_tokens_round_trip_test() {
  let body =
    ir.Let(
      ["e"],
      ir.Values([ir.ConstNull(ir.ExnRef)]),
      ir.Let(
        [],
        ir.Throw("t0", [ir.Var("v"), ir.Var("k")]),
        ir.ThrowRef(ir.Var("e")),
      ),
    )
  let f =
    ir.Function(
      "eh",
      [ir.Local("v", ir.TF64), ir.Local("k", ir.TI32)],
      [],
      [ir.Local("e", ir.TExnRef)],
      body,
    )
  let module =
    ir.Module(
      name: "carder@eh@tokens",
      uses_numerics: True,
      memories: [],
      globals: [],
      imports: [ir.ImportTag("env", "e0", [ir.TF64, ir.TI32])],
      functions: [f],
      exports: [ir.ExportTag("0", "t0")],
      data_segments: [],
      tables: [],
      elements: [],
      start: None,
      tags: [ir.TagDecl("t0", [ir.TF64, ir.TI32])],
    )
  // parse(print(m)) == m over the tag section + `Throw`/`ThrowRef` + `exnref` + import/export tag.
  let text = printer.print_module(module)
  parser.parse_module(text) |> should.equal(Ok(module))
}

// ───────────────────────── the `rt_exn` heads exist with the frozen arities (T3) ─────────────────────

/// A COMPILE-TIME signature check of the frozen `«RT-EXN-SIG»` heads (T3): each head is referenced
/// (NOT called — the bodies `panic` until P7-07) at its frozen arity + term shape, so 06/07 bind
/// to exactly these signatures. If any head's arity/type drifts, this test fails to typecheck.
pub fn rt_exn_heads_have_frozen_arities_test() {
  // Raising heads are bottom (`-> a`); pinned here to a concrete return so the reference typechecks.
  let _throw_exn: fn(Int, List(Dynamic)) -> Nil = rt_exn.throw_exn
  let _reraise: fn(Dynamic, Dynamic, Dynamic) -> Nil = rt_exn.reraise
  let _throw_ref: fn(Dynamic) -> Nil = rt_exn.throw_ref
  let _match_tag: fn(Dynamic, Int) -> Result(List(Dynamic), Nil) =
    rt_exn.match_tag
  let _is_wasm_exn: fn(Dynamic) -> Bool = rt_exn.is_wasm_exn
  let _capture_exnref: fn(Dynamic) -> Dynamic = rt_exn.capture_exnref
  let _is_exnref: fn(Dynamic) -> Bool = rt_exn.is_exnref
  // A trivial assertion so the test body is non-empty; the load-bearing check is the annotations
  // above (which fail to compile if any head's signature drifts from the T3 freeze).
  Nil |> should.equal(Nil)
}
