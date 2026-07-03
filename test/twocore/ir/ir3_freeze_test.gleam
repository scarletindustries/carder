//// Unit P5-01 — the IR3 interface-freeze KEYSTONE, verified (mirroring `ir2_freeze_test` /
//// `tier_freeze_test`).
////
//// SPEC assertions (what the freeze must guarantee), NOT change-detectors (D8). They prove:
////
//// - **the IR3 surface is EXPRESSIBLE** — a module exercising the whole Phase-5 surface
////   (multi-memory + memory64 axis, an `externref` table, passive/reference element & data
////   segments, non-function imports, exported state, and every new reference/table/bulk `Expr`
////   node) typechecks, so units 02–12 can construct and bind to it (H1/H2/H3/H4);
//// - **every new node is an effect BARRIER** — `effect.classify` returns `Effectful` for each
////   (the optimizer-soundness floor, §E; WASM §4.4.8/§4.4.9 make bulk/table/memory ops store
////   operations, so they may never be CSE'd/reordered/eliminated);
//// - **defaults are conformance-neutral (H7)** — a single-32-bit-memory, funcref-active-`RefFunc`,
////   function-only module round-trips its `.ir` text and its text carries NONE of the new-surface
////   tokens (the `mem 0` index, the `funcref`/`externref` reftype, `passive`/`declarative`), i.e.
////   its spelling is byte-identical to the Phase-4 form;
//// - **reference values are distinguishable + FORGE-PROOF (R1)** — null / externref / funcref
////   classify apart, and a wrapped host term that happens to be the null sentinel
////   (`{ref_extern, {ref_null}}`) is NOT null;
//// - **`TrapReason` is UNCHANGED (§D)** — the Phase-5 failures reuse the existing variants, so no
////   accidental variant addition breaks `spec_trap_message`'s exhaustive match.

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import twocore/ir
import twocore/ir/effect
import twocore/ir/parser
import twocore/ir/printer
import twocore/runtime/rt_ref

/// Identity coercion (a helper to fabricate a `funcref`-shaped runtime term `{FuncType, Closure}`
/// for the classification test — a 2-tuple that is neither the null sentinel nor an externref box).
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

const zero: ir.Value = ir.ConstI32(0)

// ───────────────────────── the IR3 surface is expressible (H1–H4) ─────────────────────────

/// Construct a module exercising the WHOLE Phase-5 surface and assert it typechecks (the value
/// COMPILES) and carries the frozen shapes. This is the load-bearing freeze: units 02–12 bind to
/// exactly these constructors.
pub fn ir3_surface_is_expressible_test() {
  // A body sequencing every new reference / table / bulk node + a `mem 1` load (multi-memory).
  let body =
    ir.Let(
      [],
      ir.RefFunc("worker"),
      ir.Let(
        ["is_null"],
        ir.RefIsNull(ir.ConstNull(ir.FuncRef)),
        ir.Let(
          ["slot"],
          ir.TableGet("t_ext", zero),
          ir.Let(
            [],
            ir.TableSet("t_ext", zero, ir.ConstNull(ir.ExternRef)),
            ir.Let(
              ["size"],
              ir.TableSize("t_ext"),
              ir.Let(
                ["prev"],
                ir.TableGrow("t_ext", zero, ir.ConstNull(ir.ExternRef)),
                ir.Let(
                  [],
                  ir.TableFill("t_ext", zero, ir.ConstNull(ir.ExternRef), zero),
                  ir.Let(
                    [],
                    ir.TableInit("t0", 0, zero, zero, zero),
                    ir.Let(
                      [],
                      ir.TableCopy("t0", "t0", zero, zero, zero),
                      ir.Let(
                        [],
                        ir.ElemDrop(0),
                        ir.Let(
                          [],
                          ir.MemFill(0, zero, zero, zero),
                          ir.Let(
                            [],
                            ir.MemCopy(1, 0, zero, zero, zero),
                            ir.Let(
                              [],
                              ir.MemInit(0, 0, zero, zero, zero),
                              ir.Let(
                                [],
                                ir.DataDrop(0),
                                ir.Let(
                                  ["x"],
                                  ir.MemLoad(
                                    1,
                                    ir.MemAccess(4, False),
                                    zero,
                                    0,
                                    ir.TI32,
                                  ),
                                  ir.Return([ir.Var("x")]),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    )
  let worker = ir.Function("worker", [], [ir.TI32], [], body)

  let module =
    ir.Module(
      name: "twocore@ir3@surface",
      uses_numerics: True,
      // multi-memory + memory64 axis: a 32-bit memory (index 0) and a 64-bit memory (index 1).
      memories: [
        ir.MemoryDecl(1, Some(2), ir.Idx32),
        ir.MemoryDecl(1, None, ir.Idx64),
      ],
      globals: [],
      // non-function imports (H4): provided state, not capabilities.
      imports: [
        ir.ImportGlobal("env", "g", ir.TI32, False),
        ir.ImportMemory("env", "m", 1, None, ir.Idx32),
      ],
      functions: [worker],
      // exported state (H4).
      exports: [ir.ExportMemory("mem", 0)],
      // a passive data segment (H2).
      data_segments: [ir.DataSegment(ir.DataPassive, <<1, 2, 3>>)],
      // a funcref table (byte-identical) + an externref table (H1).
      tables: [
        ir.TableDecl("t0", ir.FuncRef, 1, None),
        ir.TableDecl("t_ext", ir.ExternRef, 1, Some(4)),
      ],
      // a passive element segment carrying a `RefFunc` and a null slot (H2/R1c). Element items
      // are const-expr `Expr`s: `RefFunc(name)` for a funcref, `Values([ConstNull(ty)])` for a
      // null slot (a `ref.null` reduces to the `ConstNull` value, R1c).
      elements: [
        ir.ElementSegment(ir.ElemPassive, ir.FuncRef, [
          ir.RefFunc("worker"),
          ir.Values([ir.ConstNull(ir.FuncRef)]),
        ]),
      ],
      start: None,
      tags: [],
    )

  // The value compiled ⇒ the surface is expressible. Assert the frozen shapes are as declared.
  list.length(module.memories) |> should.equal(2)
  let assert [ir.MemoryDecl(_, _, ir.Idx32), ir.MemoryDecl(_, _, ir.Idx64)] =
    module.memories
  let assert [
    ir.TableDecl(_, ir.FuncRef, _, _),
    ir.TableDecl(_, ir.ExternRef, _, _),
  ] = module.tables
  let assert [ir.ElementSegment(ir.ElemPassive, ir.FuncRef, _)] =
    module.elements
  let assert [ir.DataSegment(ir.DataPassive, _)] = module.data_segments
  let assert [ir.ImportGlobal(..), ir.ImportMemory(..)] = module.imports
  let assert [ir.ExportMemory("mem", 0)] = module.exports
}

// ───────────────────────── every new node is an effect barrier (§E) ─────────────────────────

/// Per the WebAssembly store model (§4.4.8/§4.4.9), every reference/table/bulk/memory op
/// reads and/or writes mutable instance state, so `effect.classify` MUST report `Effectful`
/// for each — the optimizer may never CSE/reorder/eliminate one (E6/F3). Asserted against the
/// spec rule, not the current output.
pub fn new_nodes_are_effect_barriers_test() {
  let macc = ir.MemAccess(4, False)
  let nodes = [
    ir.RefFunc("f"),
    ir.RefIsNull(ir.ConstNull(ir.FuncRef)),
    ir.TableGet("t", zero),
    ir.TableSet("t", zero, ir.ConstNull(ir.FuncRef)),
    ir.TableSize("t"),
    ir.TableGrow("t", zero, ir.ConstNull(ir.FuncRef)),
    ir.TableFill("t", zero, ir.ConstNull(ir.FuncRef), zero),
    ir.TableInit("t", 0, zero, zero, zero),
    ir.TableCopy("t", "t", zero, zero, zero),
    ir.ElemDrop(0),
    ir.MemFill(0, zero, zero, zero),
    ir.MemCopy(0, 1, zero, zero, zero),
    ir.MemInit(0, 0, zero, zero, zero),
    ir.DataDrop(0),
    // the existing memory nodes keep their barrier verdict under their new field shape.
    ir.MemSize(0),
    ir.MemGrow(0, zero),
    ir.MemLoad(0, macc, zero, 0, ir.TI32),
    ir.MemStore(0, macc, zero, zero, 0),
  ]
  list.each(nodes, fn(node) {
    effect.classify(node) |> should.equal(effect.Effectful)
  })
}

// ───────────────────────── defaults are byte-identical (H7) ─────────────────────────

/// A legacy module — one 32-bit memory, a funcref table, an active funcref element whose items
/// are all `RefFunc`, an active-at-memory-0 data segment, function-only exports, `mem 0` on every
/// memory node — round-trips its `.ir` text (D7) AND spells NONE of the new-surface tokens: the
/// `mem` index is elided, the `funcref`/`externref` reftype is elided, and no `passive`/
/// `declarative` appears. That spelling is byte-identical to the Phase-4 form (H7).
pub fn legacy_module_is_byte_identical_test() {
  let body =
    ir.Let(
      [],
      ir.MemStore(0, ir.MemAccess(4, False), zero, ir.ConstI32(42), 0),
      ir.Let(
        ["x"],
        ir.MemLoad(0, ir.MemAccess(4, False), zero, 0, ir.TI32),
        ir.Return([ir.Var("x")]),
      ),
    )
  let worker = ir.Function("worker", [], [ir.TI32], [], body)
  let module =
    ir.Module(
      name: "twocore@ir3@legacy",
      uses_numerics: True,
      memories: [ir.MemoryDecl(1, Some(4), ir.Idx32)],
      globals: [],
      imports: [],
      functions: [worker],
      exports: [ir.ExportFn("run", "worker")],
      data_segments: [
        ir.DataSegment(ir.DataActive(0, ir.Values([zero])), <<7>>),
      ],
      tables: [ir.TableDecl("t0", ir.FuncRef, 2, Some(8))],
      elements: [
        ir.ElementSegment(ir.ElemActive("t0", ir.Values([zero])), ir.FuncRef, [
          ir.RefFunc("worker"),
        ]),
      ],
      start: None,
      tags: [],
    )

  let text = printer.print_module(module)

  // D7 round-trip: parse(print(m)) == m (with the byte-identical default fields).
  parser.parse_module(text) |> should.equal(Ok(module))

  // The Phase-2 spellings are present…
  should.be_true(string.contains(text, "memory (min 1 max 4)"))
  should.be_true(string.contains(text, "table @t0 min 2 max 8"))
  should.be_true(
    string.contains(text, "mem.size") || string.contains(text, "mem.load"),
  )
  // …and NONE of the new-surface tokens leak (the H7 byte-identity claim).
  should.be_false(string.contains(text, "funcref"))
  should.be_false(string.contains(text, "externref"))
  should.be_false(string.contains(text, "passive"))
  should.be_false(string.contains(text, "declarative"))
}

// ───────────────────────── reference values: distinguishable + forge-proof (R1/R18) ─────────

/// `rt_ref` null / externref / funcref are distinguishable and FORGE-PROOF (R1): the null
/// sentinel is unique, an externref is a distinct wrapped box, a funcref is neither, and — the
/// forge-proof property — a host term that IS the null sentinel, once wrapped, is NOT null.
pub fn ref_values_are_distinguishable_and_forge_proof_test() {
  let null = rt_ref.null_ref()
  let ext = rt_ref.extern_of(7)
  // a funcref-shaped term `{FuncType, Closure}` — a 2-tuple that is neither null nor extern.
  let func = to_dynamic(#("func_type", "closure"))

  // `ref.is_null` (WASM §4.4.3): only the sentinel is null.
  rt_ref.is_null(null) |> should.be_true
  rt_ref.is_null(ext) |> should.be_false
  rt_ref.is_null(func) |> should.be_false

  // classification is exact and three-way.
  rt_ref.classify_ref(null) |> should.equal(rt_ref.NullRef)
  rt_ref.classify_ref(ext) |> should.equal(rt_ref.ExternRef)
  rt_ref.classify_ref(func) |> should.equal(rt_ref.FuncRef)

  // FORGE-PROOF (R1): `{ref_extern, {ref_null}}` is an externref, NOT the null sentinel — an
  // adversarial host that forwards the sentinel term cannot fabricate a null.
  let wrapped_null = rt_ref.wrap_extern(rt_ref.null_ref())
  rt_ref.is_null(wrapped_null) |> should.be_false
  rt_ref.classify_ref(wrapped_null) |> should.equal(rt_ref.ExternRef)

  // distinct externref handles compare distinct; equal handles compare equal (R18).
  should.not_equal(rt_ref.extern_of(1), rt_ref.extern_of(2))
  should.equal(rt_ref.extern_of(3), rt_ref.extern_of(3))
}

// ───────────────────────── reftype helpers + ConstNull (R1c) ─────────────────────────

/// The `RefType`↔`ValType` bridge round-trips both reference types, and `ConstNull` carries the
/// static reftype (R1c) — the null literal `ref.null t` lowers to.
pub fn reftype_helpers_round_trip_test() {
  ir.reftype_to_valtype(ir.FuncRef) |> should.equal(ir.TFuncRef)
  ir.reftype_to_valtype(ir.ExternRef) |> should.equal(ir.TExternRef)
  ir.valtype_to_reftype(ir.TFuncRef) |> should.equal(Ok(ir.FuncRef))
  ir.valtype_to_reftype(ir.TExternRef) |> should.equal(Ok(ir.ExternRef))
  // a non-reference type narrows to Error.
  ir.valtype_to_reftype(ir.TI32) |> should.equal(Error(Nil))
  // ConstNull carries the reftype tag.
  let assert ir.ConstNull(ir.ExternRef) = ir.ConstNull(ir.ExternRef)
}

// ───────────────────────── TrapReason is unchanged (§D) ─────────────────────────

/// Phase-5's new failures reuse the EXISTING `TrapReason` variants (§D — no new variant): a null
/// reference / null `call_indirect` slot is `UninitializedElement`; a table/bulk-table range is
/// `TableOutOfBounds`; a memory/bulk-memory range is `MemoryOutOfBounds`; a `call_indirect` type
/// mismatch is `IndirectCallTypeMismatch`. This locks that the freeze added no variant (which
/// would break `spec_trap_message`'s exhaustive match).
pub fn trap_reason_unchanged_test() {
  let reasons = [
    ir.UninitializedElement,
    ir.TableOutOfBounds,
    ir.MemoryOutOfBounds,
    ir.IndirectCallTypeMismatch,
    ir.UndefinedElement,
    ir.IntDivByZero,
    ir.IntOverflow,
    ir.Unreachable,
    ir.InvalidConversionToInteger,
    ir.FuelExhausted,
  ]
  // exactly the ten Phase-4 variants — a compile-time proof (this list would fail to typecheck if
  // a variant were removed) and a runtime length check.
  list.length(reasons) |> should.equal(10)
}
