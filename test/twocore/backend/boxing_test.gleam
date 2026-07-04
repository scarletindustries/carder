//// Phase-8 unit 04 — the term↔numeric boxing bridge, end-to-end on the BEAM.
////
//// Spec-first (CLAUDE.md D8 / overview §Acceptance, `specs/phase-8/04-boxing-bridge.md`):
//// each test authors a small IR `Module` that crosses the ONLY bridge (K5) between the
//// unboxed numeric layer (`TI32`/`TI64`/`TF32`/`TF64`) and the term layer (`TTerm`) —
//// `BoxInt`/`UnboxInt`/`BoxFloat`/`UnboxFloat` — lowers it IR → `emit_core` → `build_beam`
//// → a loaded `.beam`, invokes an export with `erlang:apply`, and asserts the **value**,
//// never the emitted bytes.
////
//// The acceptance is the ROUND-TRIP: `Unbox∘Box` is the identity, bit-exactly. Because 2core
//// carries every scalar — floats INCLUDED — as its raw IEEE-754 / two's-complement bit pattern
//// (D5; an Erlang integer, per `rt_num`), a `TF64` at runtime is the integer bit pattern, and
//// the boxing bridge is a pure static-type retag. Two consequences this suite leans on:
////   1. NaN/±Inf round-trip bit-exactly — they are just integers here, so plain integer
////      equality is total (no `NaN /= NaN` pitfall, and no impossible bits→BEAM-`float()`
////      encode, which would `badmatch` on NaN/±Inf).
////   2. `Int` boxing never truncates — BEAM integers are arbitrary precision, so a >2^64
////      bignum survives the bridge unchanged.
////
//// The harness (`load`/`module`/`fnN`/`catch_apply_dyn`/`to_dynamic`) mirrors
//// `term_ops_test.gleam`.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/ir
import twocore/runtime/instance

// Test-only FFI: apply `M:F(Args)` capturing a raise as `Error(text)` (reused from the
// unit-08 shim). Re-typed for `Dynamic` args/results — sound because `erlang:apply` is
// untyped at run time.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply_dyn(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

// The raw 64-/32-bit IEEE-754 pattern of a finite native float (unit-04 test FFI), so the
// float constants read as decimal literals rather than hand-encoded hex.
@external(erlang, "twocore_boxing_test_ffi", "f64_bits")
fn f64_bits(f: Float) -> Int

@external(erlang, "twocore_boxing_test_ffi", "f32_bits")
fn f32_bits(f: Float) -> Int

// Coerce any Gleam value to `Dynamic` (identity at runtime) — to build `Dynamic` arg lists
// and expected-value comparisons.
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

// ───────────────────────────── plumbing ─────────────────────────────

/// Emit `module` to Core text, compile it, and load it into the test VM; return the loaded
/// module atom. `let assert` is the success contract — a failure to emit/compile/load is a
/// genuine test failure.
fn load(module: ir.Module) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(module, instance.safe_default())
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

/// Wrap `functions` in a numerics-on, memory-off module exporting each by name.
fn module(name: String, functions: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "twocore@boxing@" <> name,
    uses_numerics: True,
    memories: [],
    globals: [],
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

/// A one-parameter function `name(p0 : pty) -> rty` with body `body`.
fn fn1(
  name: String,
  pty: ir.ValType,
  rty: ir.ValType,
  body: ir.Expr,
) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("p0", pty)],
    result: [rty],
    locals: [],
    body: body,
  )
}

/// A two-parameter function `name(p0 : p0ty, p1 : p1ty) -> rty` with body `body`.
fn fn2(
  name: String,
  p0ty: ir.ValType,
  p1ty: ir.ValType,
  rty: ir.ValType,
  body: ir.Expr,
) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("p0", p0ty), ir.Local("p1", p1ty)],
    result: [rty],
    locals: [],
    body: body,
  )
}

/// The round-trip body `let boxed = Box(p0) in Unbox(boxed)` — the value crosses INTO the
/// term layer and back. The intermediate `boxed` is a genuine `TTerm`, so this exercises the
/// full Box→term→Unbox path, not a fused no-op.
fn roundtrip(box: ir.ConvOp, unbox: ir.ConvOp) -> ir.Expr {
  ir.Let(
    ["boxed"],
    ir.Convert(box, ir.Var("p0")),
    ir.Convert(unbox, ir.Var("boxed")),
  )
}

/// Assert every `#(label, input_bits)` in `cases` round-trips to itself through the export
/// `fn_name` of `mod`. The label is folded into the compared term so a failure names the
/// offending pattern.
fn assert_roundtrip(
  mod: Atom,
  fn_name: String,
  cases: List(#(String, Int)),
) -> Nil {
  list.each(cases, fn(c) {
    let #(label, bits) = c
    assert #(
        label,
        catch_apply_dyn(mod, atom.create(fn_name), [to_dynamic(bits)]),
      )
      == #(label, Ok(to_dynamic(bits)))
  })
}

// ───────────────────────────── floats: Unbox∘Box bit-exact ─────────────────────────────

/// `UnboxFloat(BoxFloat(x))` is the identity, bit-exactly, for every f64 bit pattern —
/// finite, signed zero, subnormal, and (the whole point of D5) NaN / ±Inf. The patterns are
/// integers here, so the round-trip is asserted with total integer equality.
pub fn unbox_box_f64_roundtrip_bit_exact_test() {
  let rt =
    fn1(
      "rt",
      ir.TF64,
      ir.TF64,
      roundtrip(ir.BoxFloat(ir.FW64), ir.UnboxFloat(ir.FW64)),
    )
  let mod = load(module("f64rt", [rt]))
  assert_roundtrip(mod, "rt", [
    #("+0.0", f64_bits(0.0)),
    #("1.5", f64_bits(1.5)),
    #("-2.25", f64_bits(-2.25)),
    #("large 1e300", f64_bits(1.0e300)),
    #("tiny 5e-324 (min subnormal)", 0x0000000000000001),
    #("max subnormal", 0x000FFFFFFFFFFFFF),
    #("-0.0", 0x8000000000000000),
    #("canonical quiet NaN", 0x7FF8000000000000),
    #("signaling-NaN payload", 0x7FF0000000000001),
    #("+Inf", 0x7FF0000000000000),
    #("-Inf", 0xFFF0000000000000),
  ])
}

/// `UnboxFloat(BoxFloat(x))` is the identity, bit-exactly, for f32 bit patterns — including
/// the 32-bit NaN / ±Inf / subnormal patterns.
pub fn unbox_box_f32_roundtrip_bit_exact_test() {
  let rt =
    fn1(
      "rt",
      ir.TF32,
      ir.TF32,
      roundtrip(ir.BoxFloat(ir.FW32), ir.UnboxFloat(ir.FW32)),
    )
  let mod = load(module("f32rt", [rt]))
  assert_roundtrip(mod, "rt", [
    #("+0.0", f32_bits(0.0)),
    #("1.5", f32_bits(1.5)),
    #("-2.25", f32_bits(-2.25)),
    #("large 1e30", f32_bits(1.0e30)),
    #("min subnormal", 0x00000001),
    #("max subnormal", 0x007FFFFF),
    #("-0.0", 0x80000000),
    #("canonical quiet NaN", 0x7FC00000),
    #("signaling-NaN payload", 0x7F800001),
    #("+Inf", 0x7F800000),
    #("-Inf", 0xFF800000),
  ])
}

// ───────────────────────────── ints: Unbox∘Box no truncation ─────────────────────────────

/// `UnboxInt(BoxInt(n))` is the identity for i32-range values — the signed extremes and the
/// raw unsigned bit pattern alike, with no loss.
pub fn unbox_box_i32_roundtrip_test() {
  let rt =
    fn1(
      "rt",
      ir.TI32,
      ir.TI32,
      roundtrip(ir.BoxInt(ir.W32), ir.UnboxInt(ir.W32)),
    )
  let mod = load(module("i32rt", [rt]))
  assert_roundtrip(mod, "rt", [
    #("0", 0),
    #("1", 1),
    #("-1", -1),
    #("2^31-1 (INT32_MAX)", 2_147_483_647),
    #("-2^31 (INT32_MIN)", -2_147_483_648),
    #("0xFFFFFFFF (u32 max bits)", 0xFFFFFFFF),
  ])
}

/// `UnboxInt(BoxInt(n))` is the identity for i64-range AND beyond: BEAM integers are
/// arbitrary precision, so a value past 2^64 survives the bridge with NO truncation — the
/// spec's explicit "verify no truncation" acceptance.
pub fn unbox_box_i64_roundtrip_no_truncation_test() {
  let rt =
    fn1(
      "rt",
      ir.TI64,
      ir.TI64,
      roundtrip(ir.BoxInt(ir.W64), ir.UnboxInt(ir.W64)),
    )
  let mod = load(module("i64rt", [rt]))
  assert_roundtrip(mod, "rt", [
    #("0", 0),
    #("1", 1),
    #("-1", -1),
    #("2^53 (f64 exact-int limit)", 9_007_199_254_740_992),
    #("2^63-1 (INT64_MAX)", 9_223_372_036_854_775_807),
    #("2^64-1 (u64 max bits)", 0xFFFFFFFFFFFFFFFF),
    #("2^70+123 (bignum)", 1_180_591_620_717_411_303_547),
    #("2^100 (>64-bit bignum)", 1_267_650_600_228_229_401_496_703_205_376),
    #("-2^80 (negative bignum)", -1_208_925_819_614_629_174_706_176),
  ])
}

// ───────────────────────────── the composed hot-arithmetic flow ─────────────────────────────

/// The frontend's fast-path pattern end-to-end: two UNBOXED f64s are added natively
/// (`Num(FAdd)`), the f64 sum is boxed into a `TTerm`, then unboxed back to an f64. Asserts
/// `1.5 + 2.5 == 4.0` bit-exactly — arithmetic stays in the unboxed layer and only crosses
/// the bridge at the boundary (K5), losing nothing.
pub fn hot_arith_box_then_unbox_e2e_test() {
  let body =
    ir.Let(
      ["sum"],
      ir.Num(ir.FAdd(ir.FW64), [ir.Var("p0"), ir.Var("p1")]),
      ir.Let(
        ["boxed"],
        ir.Convert(ir.BoxFloat(ir.FW64), ir.Var("sum")),
        ir.Convert(ir.UnboxFloat(ir.FW64), ir.Var("boxed")),
      ),
    )
  let hot = fn2("hot", ir.TF64, ir.TF64, ir.TF64, body)
  let mod = load(module("hot", [hot]))

  let a = f64_bits(1.5)
  let b = f64_bits(2.5)
  let expected = f64_bits(4.0)
  assert catch_apply_dyn(mod, atom.create("hot"), [
      to_dynamic(a),
      to_dynamic(b),
    ])
    == Ok(to_dynamic(expected))
}
