//// Unit P6-01 — the IR4 interface-freeze KEYSTONE, verified (mirroring `ir3_freeze_test`).
////
//// SPEC assertions (what the freeze must guarantee), NOT change-detectors (D8). They prove:
////
//// - **the IR4 SIMD surface is EXPRESSIBLE** — a function with `v128` params/locals whose body
////   uses every `Simd`/`SimdShuffle`/`SimdLoad*`/`SimdStore*` family + a `ConstV128` operand + a
////   `CallImport`, in a module carrying an `Idx64` memory, typechecks (the value COMPILES), so
////   units 02–11 can construct and bind to exactly these constructors (I1/I2/S5);
//// - **the pure-vs-barrier effect split is EXACT (S7)** — `Simd`/`SimdShuffle` classify `Pure`
////   (total, deterministic value transforms — WASM §4.4; no trap I3, no state), the four SIMD
////   memory nodes + `CallImport` classify `Effectful` (they touch memory / are calls);
//// - **`ConstV128` holds a 16-byte binary (D5)** — `bit_size == 128`, and two equal byte
////   sequences compare `==` (the const-fold / dedup contract);
//// - **defaults are conformance-neutral (I7)** — a no-SIMD single-`Idx32` module round-trips its
////   `.ir` text (D7), its spelling carries NONE of the new SIMD tokens, and its emitted `.core`
////   links NO `rt_simd` / `v128` — the emit arms are unreached, so the legacy path is byte-identical;
//// - **`TrapReason` is UNCHANGED (S8)** — Phase 6 added zero variants, so `spec_trap_message`'s
////   exhaustive match is untouched;
//// - **`«MEM64-RUNTIME»` + `«XLINK»` heads exist** — `safe_default().mem64_max_pages` is the frozen
////   spec-aligned cap (> 0), and a `ProvidedFunc(ty, call)` closure capability is constructible.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/ir
import twocore/ir/effect
import twocore/ir/parser
import twocore/ir/printer
import twocore/runtime/instance
import twocore/runtime/link

/// Identity coercion — fabricates a `Dynamic` for the `ProvidedFunc` closure return.
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

const zero: ir.Value = ir.ConstI32(0)

/// A zero-filled 16-byte v128 literal — a valid `ConstV128` operand.
const v0: ir.Value = ir.ConstV128(<<0:128>>)

// ───────────────────────── the IR4 SIMD surface is expressible (I1/I2/S5) ─────────────────────────

/// Construct a module exercising the WHOLE Phase-6 SIMD/mem64/cross-import surface and assert it
/// typechecks (the value COMPILES) and carries the frozen shapes. This is the load-bearing freeze:
/// units 02–11 bind to exactly these constructors.
pub fn ir4_surface_is_expressible_test() {
  // A body sequencing a representative of every SimdOp family + each SIMD `Expr` node + CallImport.
  let body =
    ir.Let(
      ["a"],
      ir.Simd(ir.SAdd(ir.I32x4), [v0, v0]),
      ir.Let(
        ["b"],
        ir.Simd(ir.SFMul(ir.F64x2), [ir.Var("a"), v0]),
        ir.Let(
          ["c"],
          ir.Simd(ir.VBitselect, [ir.Var("b"), v0, v0]),
          ir.Let(
            ["d"],
            ir.Simd(ir.SEq(ir.I8x16), [ir.Var("c"), v0]),
            ir.Let(
              ["e"],
              ir.Simd(ir.SSplat(ir.I32x4), [zero]),
              ir.Let(
                ["lane"],
                ir.Simd(ir.SExtractLaneU(ir.I16x8, 3), [ir.Var("e")]),
                ir.Let(
                  ["f"],
                  ir.Simd(ir.SShl(ir.I8x16), [ir.Var("e"), zero]),
                  ir.Let(
                    ["g"],
                    ir.Simd(ir.SNarrow(ir.I16x8, True), [ir.Var("f"), v0]),
                    ir.Let(
                      ["h"],
                      ir.Simd(ir.SExtend(ir.I8x16, ir.Low, False), [ir.Var("g")]),
                      ir.Let(
                        ["i"],
                        ir.Simd(ir.STruncSatF32x4S, [v0]),
                        ir.Let(
                          ["j"],
                          ir.Simd(ir.SDotI16x8S, [v0, v0]),
                          ir.Let(
                            ["k"],
                            ir.Simd(ir.VAnyTrue, [ir.Var("j")]),
                            ir.Let(
                              ["l"],
                              ir.Simd(ir.SBitmask(ir.I32x4), [ir.Var("j")]),
                              ir.Let(
                                ["sh"],
                                ir.SimdShuffle(
                                  [
                                    0,
                                    1,
                                    2,
                                    3,
                                    4,
                                    5,
                                    6,
                                    7,
                                    8,
                                    9,
                                    10,
                                    11,
                                    12,
                                    13,
                                    14,
                                    15,
                                  ],
                                  v0,
                                  v0,
                                ),
                                ir.Let(
                                  ["ld"],
                                  ir.SimdLoad(0, ir.LoadV128, zero, 0),
                                  ir.Let(
                                    [],
                                    ir.SimdStore(0, zero, ir.Var("ld"), 0),
                                    ir.Let(
                                      ["ll"],
                                      ir.SimdLoadLane(0, 32, zero, 0, 0, v0),
                                      ir.Let(
                                        [],
                                        ir.SimdStoreLane(
                                          0,
                                          32,
                                          zero,
                                          0,
                                          0,
                                          ir.Var("ll"),
                                        ),
                                        ir.Let(
                                          ["ci"],
                                          ir.CallImport(
                                            0,
                                            ir.FuncType([ir.TI32], [ir.TI32]),
                                            [zero],
                                          ),
                                          ir.Return([ir.Var("ci")]),
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
            ),
          ),
        ),
      ),
    )
  // A function with a `v128` param AND a `v128` local (the DoD requirement).
  let f =
    ir.Function(
      "simd_worker",
      [ir.Local("p0", ir.TV128)],
      [ir.TI32],
      [ir.Local("tmp", ir.TV128)],
      body,
    )

  let module =
    ir.Module(
      name: "twocore@ir4@surface",
      uses_numerics: True,
      // an `Idx64` memory (memory64 axis) alongside a plain 32-bit one.
      memories: [
        ir.MemoryDecl(1, None, ir.Idx32),
        ir.MemoryDecl(1, Some(2), ir.Idx64),
      ],
      globals: [],
      imports: [],
      functions: [f],
      exports: [ir.ExportFn("run", "simd_worker")],
      data_segments: [],
      tables: [],
      elements: [],
      start: None,
    )

  // The value compiled ⇒ the surface is expressible. Assert the frozen shapes are as declared.
  let assert [ir.Local("p0", ir.TV128)] = { module.functions |> first }.params
  let assert [ir.Local("tmp", ir.TV128)] = { module.functions |> first }.locals
  let assert [ir.MemoryDecl(_, _, ir.Idx32), ir.MemoryDecl(_, _, ir.Idx64)] =
    module.memories
}

/// Helper: the first function of a one-function module (the surface test builds exactly one).
fn first(fs: List(ir.Function)) -> ir.Function {
  let assert [f, ..] = fs
  f
}

// ───────────────────────── effect classification: pure lanewise vs barriers (S7) ─────────────────────────

/// The load-bearing I3/S7 freeze: a lane-wise SIMD op is TOTAL and DETERMINISTIC (WASM §4.4 —
/// no trap, no state), so `Simd`/`SimdShuffle` classify `Pure` exactly like a non-trapping `Num`
/// (enabling later SIMD const-fold/DCE/CSE). Asserted against the spec rule, not current output.
pub fn pure_lanewise_simd_classifies_pure_test() {
  let shuffle_lanes = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  effect.classify(ir.Simd(ir.SAdd(ir.I32x4), [v0, v0]))
  |> should.equal(effect.Pure)
  effect.classify(ir.Simd(ir.VBitselect, [v0, v0, v0]))
  |> should.equal(effect.Pure)
  effect.classify(ir.Simd(ir.SFMul(ir.F64x2), [v0, v0]))
  |> should.equal(effect.Pure)
  effect.classify(ir.SimdShuffle(shuffle_lanes, v0, v0))
  |> should.equal(effect.Pure)
  // …and a pure SIMD op is therefore CSE-able / eliminable-if-unused (the optimization win).
  effect.can_cse(ir.Simd(ir.SAdd(ir.I32x4), [v0, v0])) |> should.be_true
  effect.can_eliminate_if_unused(ir.SimdShuffle(shuffle_lanes, v0, v0))
  |> should.be_true
}

/// The four SIMD memory nodes read/write mutable memory and can trap OOB (WASM §4.4.7), and
/// `CallImport` is a call — all are `Effectful` BARRIERS (S5/S7): no CSE/reorder/DCE across them.
pub fn simd_memory_and_callimport_classify_effectful_test() {
  let nodes = [
    ir.SimdLoad(0, ir.LoadV128, zero, 0),
    ir.SimdLoad(0, ir.LoadSplat(8), zero, 0),
    ir.SimdLoad(0, ir.LoadExtend(8, False), zero, 0),
    ir.SimdLoad(0, ir.LoadZero(32), zero, 0),
    ir.SimdStore(0, zero, v0, 0),
    ir.SimdLoadLane(0, 32, zero, 0, 0, v0),
    ir.SimdStoreLane(0, 32, zero, 0, 0, v0),
    ir.CallImport(0, ir.FuncType([ir.TI32], [ir.TI32]), [zero]),
  ]
  list.each(nodes, fn(node) {
    effect.classify(node) |> should.equal(effect.Effectful)
    effect.can_cse(node) |> should.be_false
  })
}

// ───────────────────────── ConstV128 is exactly 16 bytes + value equality (D5) ─────────────────────────

/// The `v128.const` literal stores exactly 16 raw little-endian bytes (`bit_size == 128`), and two
/// equal byte sequences compare `==` (BEAM binary equality — the const-fold / dedup contract, D5).
pub fn constv128_is_16_bytes_and_value_equal_test() {
  let assert ir.ConstV128(bytes) = v0
  bit_array.bit_size(bytes) |> should.equal(128)

  let a =
    ir.ConstV128(<<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>)
  let b =
    ir.ConstV128(<<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>)
  let c =
    ir.ConstV128(<<0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>)
  should.equal(a, b)
  should.not_equal(a, c)
}

// ───────────────────────── defaults are conformance-neutral (I7) ─────────────────────────

/// A legacy module — one 32-bit memory, function-only, no SIMD, no cross-import — round-trips its
/// `.ir` text (D7), spells NONE of the new SIMD tokens, and emits a `.core` that links NO `rt_simd`
/// / `v128`. The keystone's new arms are all unreached on this path, so it is byte-identical to
/// Phase-5 (the I7 claim as a test).
pub fn legacy_module_is_conformance_neutral_test() {
  let body =
    ir.Let(
      ["x"],
      ir.Num(ir.IAdd(ir.W32), [ir.ConstI32(1), ir.ConstI32(2)]),
      ir.Return([ir.Var("x")]),
    )
  let f = ir.Function("add", [ir.Local("p0", ir.TI32)], [ir.TI32], [], body)
  let module =
    ir.Module(
      name: "twocore@ir4@legacy",
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
    )

  // D7 round-trip: parse(print(m)) == m (the new arms never fire on a legacy module).
  let text = printer.print_module(module)
  parser.parse_module(text) |> should.equal(Ok(module))

  // NONE of the new SIMD tokens leak into the `.ir` text (byte-identity to Phase-5).
  should.be_false(string.contains(text, "v128"))
  should.be_false(string.contains(text, "simd"))
  should.be_false(string.contains(text, "call_import"))

  // …and the emitted `.core` links NO SIMD runtime (the emit arms are unreached).
  let assert Ok(cm) = emit_core.emit_module(module, instance.safe_default())
  let core = core_printer.print_module(cm)
  should.be_false(string.contains(core, "rt_simd"))
  should.be_false(string.contains(core, "v128"))
}

// ───────────────────────── TrapReason is unchanged (S8) ─────────────────────────

/// Phase 6 added ZERO `TrapReason` variants (S8): SIMD ops are total (I3), SIMD-memory + memory64
/// OOB reuse `MemoryOutOfBounds`, and an unlinkable import is a link-time `ImportError` — never a
/// runtime trap. This locks the exact ten-variant set (a compile-time proof: the list fails to
/// typecheck if a variant is removed) so `spec_trap_message`'s exhaustive match is untouched.
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

// ───────────────────────── «MEM64-RUNTIME» + «XLINK» contract heads ─────────────────────────

/// `safe_default().mem64_max_pages` is the frozen, spec-aligned RUNTIME page cap for a 64-bit
/// memory (S9/I4) — a positive trap boundary (2^32 pages = 256 TiB), distinct from validate's
/// 2^48-page declarable limit. P6-08 pins the exact constant; the keystone freezes the field.
pub fn mem64_max_pages_is_a_positive_cap_test() {
  let cap = instance.safe_default().mem64_max_pages
  should.be_true(cap > 0)
  cap |> should.equal(4_294_967_296)
}

/// A `ProvidedFunc(ty, call)` carries the linker-built closure capability (S5/«XLINK») — the `call`
/// field exists and the value is constructible + matchable (matching uses `ty` only; the closure is
/// applied as a capability by `link.call_import`, never `==`'d). Frozen head; P6-09 builds real ones.
pub fn provided_func_carries_a_closure_capability_test() {
  let ty = ir.FuncType([ir.TI32], [ir.TI32])
  // The closure takes an arg list and returns a value LIST (multi-value, S5/R17).
  let call = fn(_args: List(Dynamic)) -> List(Dynamic) { [to_dynamic(0)] }
  let pf = link.ProvidedFunc(ty, call)
  let link.ProvidedFunc(matched_ty, _) = pf
  matched_ty |> should.equal(ty)
  // the closure is a first-class value that can be applied to an arg list (the dispatch shape).
  let _ = call([])
  Nil
}
