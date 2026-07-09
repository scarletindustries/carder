//// Spec-based tests for `twocore/frontend/wasm/decode` (Unit 05).
////
//// Assertions target the WebAssembly core spec's BINARY FORMAT, not whatever the
//// implementation happens to emit:
////  - integers/LEB128: https://webassembly.github.io/spec/core/binary/values.html#integers
////  - modules/sections: https://webassembly.github.io/spec/core/binary/modules.html
////  - types:            https://webassembly.github.io/spec/core/binary/types.html
////  - instructions:     https://webassembly.github.io/spec/core/binary/instructions.html
////
//// The `.wasm` fixtures (`add` hand-derived from the unit doc; the rest —
//// `sum_to`/`abs`/`fib`/`mv` and the Phase-2 `mem`/`ci`/`glob`/`conv`/`startdata`
//// fixtures — produced by `wat2wasm`) are embedded as byte literals so the suite
//// needs no external tool at run time. The fail-closed suite proves every
//// malformation (Phase-1 and the new Phase-2 sections/opcodes) yields a typed
//// `DecodeError` (never a panic), and the fuzz tests prove TOTALITY over
//// single-byte mutations and truncations of the `add`, `mem`, and `conv`
//// fixtures.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import simplifile
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/decode

// ───────────────────────────── helpers ─────────────────────────────

/// Build a `BitArray` from a list of byte values (each truncated to 8 bits),
/// in order. Used to author fixtures and craft malformed inputs.
fn bytes(ints: List(Int)) -> BitArray {
  list.fold(ints, <<>>, fn(acc, b) { <<acc:bits, b:8>> })
}

/// Inclusive integer range `[from, to]` (empty if `from > to`). Local helper so
/// the suite does not depend on a stdlib range function.
fn int_range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..int_range(from + 1, to)]
  }
}

/// Replace the byte at index `idx` of `ints` with `val` (a fresh list).
fn replace(ints: List(Int), idx: Int, val: Int) -> List(Int) {
  list.index_map(ints, fn(b, i) {
    case i == idx {
      True -> val
      False -> b
    }
  })
}

// The worked `add(i32,i32)->i32` fixture from the unit doc (section 05), as raw
// bytes. Kept as a List(Int) so the fuzz/negative tests can mutate it.
const add_fixture: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60, 0x02,
  0x7F, 0x7F, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x61,
  0x64, 0x64, 0x00, 0x00, 0x0A, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01,
  0x6A, 0x0B,
]

// ──────────────────────── LEB128 unsigned vectors ────────────────────────
// Spec: https://webassembly.github.io/spec/core/binary/values.html#integers

pub fn uleb_zero_test() {
  decode.decode_u_n(<<0x00>>, 32)
  |> should.equal(Ok(#(0, <<>>)))
}

pub fn uleb_127_test() {
  decode.decode_u_n(<<0x7F>>, 32)
  |> should.equal(Ok(#(127, <<>>)))
}

pub fn uleb_128_test() {
  decode.decode_u_n(<<0x80, 0x01>>, 32)
  |> should.equal(Ok(#(128, <<>>)))
}

pub fn uleb_624485_test() {
  decode.decode_u_n(<<0xE5, 0x8E, 0x26>>, 32)
  |> should.equal(Ok(#(624_485, <<>>)))
}

pub fn uleb_u32_max_test() {
  decode.decode_u_n(<<0xFF, 0xFF, 0xFF, 0xFF, 0x0F>>, 32)
  |> should.equal(Ok(#(4_294_967_295, <<>>)))
}

pub fn uleb_overflow_test() {
  // Terminal byte 0x1F sets bit 4, exceeding the 32-bit width.
  decode.decode_u_n(<<0xFF, 0xFF, 0xFF, 0xFF, 0x1F>>, 32)
  |> should.equal(Error(ast.LebOverflow))
}

pub fn uleb_too_long_test() {
  // Six bytes for a 32-bit value (max is ceil(32/7) = 5).
  decode.decode_u_n(<<0x80, 0x80, 0x80, 0x80, 0x80, 0x00>>, 32)
  |> should.equal(Error(ast.LebTooLong))
}

pub fn uleb_truncated_test() {
  // Continuation bit set but no following byte.
  decode.decode_u_n(<<0x80>>, 32)
  |> should.equal(Error(ast.Truncated))
}

pub fn uleb_leaves_rest_test() {
  decode.decode_u_n(<<0x01, 0xAA, 0xBB>>, 32)
  |> should.equal(Ok(#(1, <<0xAA, 0xBB>>)))
}

// u64 boundary: the maximum 64-bit value is ten bytes (nine 0xFF + 0x01).
pub fn uleb_u64_max_test() {
  decode.decode_u_n(
    <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01>>,
    64,
  )
  |> should.equal(Ok(#(18_446_744_073_709_551_615, <<>>)))
}

pub fn uleb_u64_overflow_test() {
  // Terminal byte 0x02 sets a bit above the 64-bit width.
  decode.decode_u_n(
    <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02>>,
    64,
  )
  |> should.equal(Error(ast.LebOverflow))
}

// ──────────────────────── LEB128 signed vectors ────────────────────────

pub fn sleb_neg1_test() {
  decode.decode_s_n(<<0x7F>>, 32)
  |> should.equal(Ok(#(-1, <<>>)))
}

pub fn sleb_neg64_test() {
  decode.decode_s_n(<<0x40>>, 32)
  |> should.equal(Ok(#(-64, <<>>)))
}

pub fn sleb_neg128_test() {
  decode.decode_s_n(<<0x80, 0x7F>>, 32)
  |> should.equal(Ok(#(-128, <<>>)))
}

pub fn sleb_neg123456_test() {
  decode.decode_s_n(<<0xC0, 0xBB, 0x78>>, 32)
  |> should.equal(Ok(#(-123_456, <<>>)))
}

pub fn sleb_i32_max_test() {
  decode.decode_s_n(<<0xFF, 0xFF, 0xFF, 0xFF, 0x07>>, 32)
  |> should.equal(Ok(#(2_147_483_647, <<>>)))
}

pub fn sleb_i32_min_test() {
  decode.decode_s_n(<<0x80, 0x80, 0x80, 0x80, 0x78>>, 32)
  |> should.equal(Ok(#(-2_147_483_648, <<>>)))
}

pub fn sleb_overflow_test() {
  // Negative terminal byte 0x4F whose sign-fill bits don't all equal the sign.
  decode.decode_s_n(<<0xFF, 0xFF, 0xFF, 0xFF, 0x4F>>, 32)
  |> should.equal(Error(ast.LebOverflow))
}

pub fn sleb_positive_small_test() {
  decode.decode_s_n(<<0x00>>, 32)
  |> should.equal(Ok(#(0, <<>>)))
}

// s64 boundary: INT64_MIN encodes as nine 0x80 then 0x7F.
pub fn sleb_i64_min_test() {
  decode.decode_s_n(
    <<0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7F>>,
    64,
  )
  |> should.equal(Ok(#(-9_223_372_036_854_775_808, <<>>)))
}

pub fn sleb_i64_max_test() {
  decode.decode_s_n(
    <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00>>,
    64,
  )
  |> should.equal(Ok(#(9_223_372_036_854_775_807, <<>>)))
}

// ──────────── s33 blocktype boundary (spec binary/instructions) ────────────
// A blocktype is one s33: >= 0 is a typeidx, the small negatives are
// valtype/empty encodings.

pub fn s33_zero_is_typeidx_test() {
  decode.decode_s_n(<<0x00>>, 33)
  |> should.equal(Ok(#(0, <<>>)))
}

pub fn s33_positive_typeidx_test() {
  decode.decode_s_n(<<0x05>>, 33)
  |> should.equal(Ok(#(5, <<>>)))
}

pub fn s33_valtype_i32_test() {
  // 0x7F is the valtype byte for i32; as an s33 it is -1.
  decode.decode_s_n(<<0x7F>>, 33)
  |> should.equal(Ok(#(-1, <<>>)))
}

pub fn s33_valtype_f64_test() {
  // 0x7C is the valtype byte for f64; as an s33 it is -4.
  decode.decode_s_n(<<0x7C>>, 33)
  |> should.equal(Ok(#(-4, <<>>)))
}

pub fn s33_empty_test() {
  // 0x40 is the empty blocktype; as an s33 it is -64.
  decode.decode_s_n(<<0x40>>, 33)
  |> should.equal(Ok(#(-64, <<>>)))
}

// ───────────────────── worked `add` fixture: exact AST ─────────────────────

pub fn decode_add_fixture_test() {
  decode.decode(bytes(add_fixture))
  |> should.equal(
    Ok(
      ast.Module(
        imported_func_count: 0,
        rec_groups: [],
        types: list.map(
          [ast.FuncType(params: [ast.I32, ast.I32], results: [ast.I32])],
          ast.func_def,
        ),
        imports: [],
        tables: [],
        memories: [],
        globals: [],
        tags: [],
        funcs: [
          ast.Func(type_idx: 0, locals: [], body: [
            ast.LocalGet(0),
            ast.LocalGet(1),
            ast.I32Add,
            ast.End,
          ]),
        ],
        start: None,
        elements: [],
        data: [],
        data_count: None,
        exports: [ast.Export(name: "add", kind: ast.ExportFunc, index: 0)],
      ),
    ),
  )
}

// ───────────────────── wat2wasm fixtures: structure ─────────────────────

// sum_to: a `block`/`loop` with EMPTY blocktypes, two declared i32 locals
// (RLE count=2), `br_if`/`br` with labels, and the trailing function `End`.
const sum_to_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7F, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x0A, 0x01, 0x06, 0x73, 0x75,
  0x6D, 0x5F, 0x74, 0x6F, 0x00, 0x00, 0x0A, 0x25, 0x01, 0x23, 0x01, 0x02, 0x7F,
  0x02, 0x40, 0x03, 0x40, 0x20, 0x02, 0x20, 0x00, 0x4E, 0x0D, 0x01, 0x20, 0x01,
  0x20, 0x02, 0x6A, 0x21, 0x01, 0x20, 0x02, 0x41, 0x01, 0x6A, 0x21, 0x02, 0x0C,
  0x00, 0x0B, 0x0B, 0x20, 0x01, 0x0B,
>>

pub fn decode_sum_to_test() {
  let assert Ok(m) = decode.decode(sum_to_wasm)
  m.exports
  |> should.equal([ast.Export(name: "sum_to", kind: ast.ExportFunc, index: 0)])
  let assert [func] = m.funcs
  // Two i32 locals, RLE-expanded from a single (count=2, i32) group.
  func.locals
  |> should.equal([ast.I32, ast.I32])
  func.body
  |> should.equal([
    ast.Block(ast.BlockEmpty),
    ast.Loop(ast.BlockEmpty),
    ast.LocalGet(2),
    ast.LocalGet(0),
    ast.I32GeS,
    ast.BrIf(1),
    ast.LocalGet(1),
    ast.LocalGet(2),
    ast.I32Add,
    ast.LocalSet(1),
    ast.LocalGet(2),
    ast.I32Const(1),
    ast.I32Add,
    ast.LocalSet(2),
    ast.Br(0),
    ast.End,
    ast.End,
    ast.LocalGet(1),
    ast.End,
  ])
}

// abs: an `if (result i32)` — a single-valtype blocktype — with an `else`.
const abs_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7F, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x61, 0x62,
  0x73, 0x00, 0x00, 0x0A, 0x14, 0x01, 0x12, 0x00, 0x20, 0x00, 0x41, 0x00, 0x48,
  0x04, 0x7F, 0x41, 0x00, 0x20, 0x00, 0x6B, 0x05, 0x20, 0x00, 0x0B, 0x0B,
>>

pub fn decode_abs_if_else_test() {
  let assert Ok(m) = decode.decode(abs_wasm)
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.LocalGet(0),
    ast.I32Const(0),
    ast.I32LtS,
    ast.If(ast.BlockVal(ast.I32)),
    ast.I32Const(0),
    ast.LocalGet(0),
    ast.I32Sub,
    ast.Else,
    ast.LocalGet(0),
    ast.End,
    ast.End,
  ])
}

// fib: a direct self-`call` (Call index 0).
const fib_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7F, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x66, 0x69,
  0x62, 0x00, 0x00, 0x0A, 0x1E, 0x01, 0x1C, 0x00, 0x20, 0x00, 0x41, 0x02, 0x48,
  0x04, 0x7F, 0x20, 0x00, 0x05, 0x20, 0x00, 0x41, 0x01, 0x6B, 0x10, 0x00, 0x20,
  0x00, 0x41, 0x02, 0x6B, 0x10, 0x00, 0x6A, 0x0B, 0x0B,
>>

pub fn decode_fib_call_test() {
  let assert Ok(m) = decode.decode(fib_wasm)
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.LocalGet(0),
    ast.I32Const(2),
    ast.I32LtS,
    ast.If(ast.BlockVal(ast.I32)),
    ast.LocalGet(0),
    ast.Else,
    ast.LocalGet(0),
    ast.I32Const(1),
    ast.I32Sub,
    ast.Call(0),
    ast.LocalGet(0),
    ast.I32Const(2),
    ast.I32Sub,
    ast.Call(0),
    ast.I32Add,
    ast.End,
    ast.End,
  ])
}

// mv: a `block (type $t)` whose blocktype is the POSITIVE s33 typeidx branch
// (multi-value). `$t` is type index 0, so the blocktype byte 0x00 decodes to
// BlockTypeIdx(0).
const mv_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x00,
  0x02, 0x7F, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x06, 0x01, 0x02, 0x6D, 0x76,
  0x00, 0x00, 0x0A, 0x0B, 0x01, 0x09, 0x00, 0x02, 0x00, 0x41, 0x01, 0x41, 0x02,
  0x0B, 0x0B,
>>

pub fn decode_mv_blocktype_idx_test() {
  let assert Ok(m) = decode.decode(mv_wasm)
  // type 0 is () -> (i32, i32).
  m.types
  |> should.equal([
    ast.func_def(ast.FuncType(params: [], results: [ast.I32, ast.I32])),
  ])
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.Block(ast.BlockTypeIdx(0)),
    ast.I32Const(1),
    ast.I32Const(2),
    ast.End,
    ast.End,
  ])
}

// ─────────────── Phase-2 worked fixtures (wat2wasm): exact AST ───────────────
// Each `.wasm` is produced by `wat2wasm` and asserted against the binary-format
// spec: memory/limits (binary/types.html §limits, §memtype), load/store + memarg
// (binary/instructions.html §memory), table/element (binary/modules.html §elem),
// global (binary/types.html §globaltype), the 0xA7..0xBF conversion block, and
// start + active data (binary/modules.html §start, §data).

// (memory 1) + i32.store/i32.load. Natural alignment of i32 is log2(4) = 2.
// Kept as `List(Int)` so the fail-closed fuzz sweep can mutate it.
const mem_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60, 0x02,
  0x7F, 0x7F, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01,
  0x07, 0x07, 0x01, 0x03, 0x6D, 0x65, 0x6D, 0x00, 0x00, 0x0A, 0x10, 0x01, 0x0E,
  0x00, 0x20, 0x00, 0x20, 0x01, 0x36, 0x02, 0x00, 0x20, 0x00, 0x28, 0x02, 0x00,
  0x0B,
]

pub fn decode_memory_store_load_test() {
  let assert Ok(m) = decode.decode(bytes(mem_ints))
  // Memory section: one memory, limits flag 0x00 → min 1 page, no max, Idx32.
  m.memories
  |> should.equal([ast.MemType(ast.Limits(min: 1, max: None), ast.Idx32)])
  let assert [func] = m.funcs
  // store/load carry the natural-alignment memarg (align = log2(4) = 2, offset 0,
  // default memory index 0 — byte-identical to Phase 4).
  func.body
  |> should.equal([
    ast.LocalGet(0),
    ast.LocalGet(1),
    ast.I32Store(ast.MemArg(align: 2, offset: 0, mem: 0)),
    ast.LocalGet(0),
    ast.I32Load(ast.MemArg(align: 2, offset: 0, mem: 0)),
    ast.End,
  ])
}

// (table 1 funcref) + (elem (i32.const 0) $f) + call_indirect (type 0).
const ci_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7F, 0x01, 0x7F, 0x03, 0x03, 0x02, 0x00, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00,
  0x01, 0x07, 0x06, 0x01, 0x02, 0x63, 0x69, 0x00, 0x01, 0x09, 0x07, 0x01, 0x00,
  0x41, 0x00, 0x0B, 0x01, 0x00, 0x0A, 0x10, 0x02, 0x04, 0x00, 0x20, 0x00, 0x0B,
  0x09, 0x00, 0x20, 0x00, 0x41, 0x00, 0x11, 0x00, 0x00, 0x0B,
>>

pub fn decode_table_elem_call_indirect_test() {
  let assert Ok(m) = decode.decode(ci_wasm)
  // Table section: one funcref table, limits min 1, no max.
  m.tables
  |> should.equal([ast.TableType(ast.FuncRef, ast.Limits(min: 1, max: None))])
  // Active (flag-0) element segment: table 0, constant offset i32.const 0, funcidx
  // list [0] ($f) — the byte-identical Phase-4 shape.
  m.elements
  |> should.equal([
    ast.ElementSegment(
      ast.ElemActive(0, [ast.I32Const(0)]),
      ast.FuncRef,
      ast.ElemFuncs([0]),
    ),
  ])
  // The exported `ci` function is the SECOND defined function (funcidx 1).
  let assert [_f, ci] = m.funcs
  // call_indirect binary immediates are typeidx-then-tableidx (0x11 y x).
  ci.body
  |> should.equal([
    ast.LocalGet(0),
    ast.I32Const(0),
    ast.CallIndirect(type_idx: 0, table: 0),
    ast.End,
  ])
}

// (global (mut i32) (i32.const 42)) — a mutable i32 global with a const init.
const glob_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x06, 0x06, 0x01, 0x7F, 0x01, 0x41, 0x2A,
  0x0B, 0x07, 0x05, 0x01, 0x01, 0x67, 0x00, 0x00, 0x0A, 0x06, 0x01, 0x04, 0x00,
  0x23, 0x00, 0x0B,
>>

pub fn decode_global_test() {
  let assert Ok(m) = decode.decode(glob_wasm)
  // mut byte 0x01 → mutable; init is the structurally-decoded const-expr
  // (terminating End consumed), a single i32.const 42 (0x2A).
  m.globals
  |> should.equal([
    ast.Global(ty: ast.I32, mutable: True, init: [ast.I32Const(42)]),
  ])
}

// The 0xA7..0xBF conversion block: INT conversions (wrap/extend/reinterpret) AND
// FLOAT conversions (trunc f→i, convert i→f) — proving the block is not read as
// float-only (E7). Five functions: wrap/ext/trunc/conv/reint.
const conv_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x1A, 0x05, 0x60, 0x01,
  0x7E, 0x01, 0x7F, 0x60, 0x01, 0x7F, 0x01, 0x7E, 0x60, 0x01, 0x7C, 0x01, 0x7F,
  0x60, 0x01, 0x7F, 0x01, 0x7D, 0x60, 0x01, 0x7D, 0x01, 0x7F, 0x03, 0x06, 0x05,
  0x00, 0x01, 0x02, 0x03, 0x04, 0x07, 0x25, 0x05, 0x04, 0x77, 0x72, 0x61, 0x70,
  0x00, 0x00, 0x03, 0x65, 0x78, 0x74, 0x00, 0x01, 0x05, 0x74, 0x72, 0x75, 0x6E,
  0x63, 0x00, 0x02, 0x04, 0x63, 0x6F, 0x6E, 0x76, 0x00, 0x03, 0x05, 0x72, 0x65,
  0x69, 0x6E, 0x74, 0x00, 0x04, 0x0A, 0x1F, 0x05, 0x05, 0x00, 0x20, 0x00, 0xA7,
  0x0B, 0x05, 0x00, 0x20, 0x00, 0xAC, 0x0B, 0x05, 0x00, 0x20, 0x00, 0xAA, 0x0B,
  0x05, 0x00, 0x20, 0x00, 0xB2, 0x0B, 0x05, 0x00, 0x20, 0x00, 0xBC, 0x0B,
]

pub fn decode_conversion_block_int_and_float_test() {
  let assert Ok(m) = decode.decode(bytes(conv_ints))
  let bodies = list.map(m.funcs, fn(f) { f.body })
  bodies
  |> should.equal([
    // i32.wrap_i64 (0xA7) — integer conversion
    [ast.LocalGet(0), ast.I32WrapI64, ast.End],
    // i64.extend_i32_s (0xAC) — integer conversion
    [ast.LocalGet(0), ast.I64ExtendI32S, ast.End],
    // i32.trunc_f64_s (0xAA) — trapping float→int
    [ast.LocalGet(0), ast.I32TruncF64S, ast.End],
    // f32.convert_i32_s (0xB2) — int→float
    [ast.LocalGet(0), ast.F32ConvertI32S, ast.End],
    // i32.reinterpret_f32 (0xBC) — integer (bit) reinterpret
    [ast.LocalGet(0), ast.I32ReinterpretF32, ast.End],
  ])
}

// (start $s) + active (data (i32.const 0) "hi").
const startdata_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x08, 0x01, 0x00,
  0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B, 0x0B, 0x08, 0x01, 0x00, 0x41, 0x00, 0x0B,
  0x02, 0x68, 0x69,
>>

pub fn decode_start_and_active_data_test() {
  let assert Ok(m) = decode.decode(startdata_wasm)
  // Start section: funcidx 0.
  m.start
  |> should.equal(Some(0))
  // Active data segment (flag 0): mem 0, const offset i32.const 0, "hi" payload —
  // the byte-identical Phase-4 shape.
  m.data
  |> should.equal([
    ast.DataSegment(ast.DataActive(0, [ast.I32Const(0)]), <<0x68, 0x69>>),
  ])
}

// A couple of leaf opcodes (no immediates) decoded precisely via a hand-built
// `() -> ()` body, locking the float/conversion `leaf_instr` rows.
// Spot-check representative + BOUNDARY opcodes of every new no-immediate
// `leaf_instr` range, decoded via a hand-built body (decode is structural, so
// type-validity is irrelevant). A wrong row in the opcode table mismatches here.
pub fn decode_float_leaf_test() {
  // float compares 0x5B/0x66; f32 numeric 0x8B/0x92/0x98; f64 numeric 0x99/0xA6;
  // conversion block 0xA7/0xBD/0xBF (range ends + a midpoint each).
  let body = [0x5B, 0x66, 0x8B, 0x92, 0x98, 0x99, 0xA6, 0xA7, 0xBD, 0xBF, 0x0B]
  let assert Ok(m) = decode.decode(bytes(module_with_body(body)))
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.F32Eq,
    ast.F64Ge,
    ast.F32Abs,
    ast.F32Add,
    ast.F32Copysign,
    ast.F64Abs,
    ast.F64Copysign,
    ast.I32WrapI64,
    ast.I64ReinterpretF64,
    ast.F64ReinterpretI64,
    ast.End,
  ])
}

// ───────────────── hand-built modules: 0xFC family + br_table ─────────────────

// Minimal module `() -> ()` whose body is `<instr> end`.
fn module_with_body(body: List(Int)) -> List(Int) {
  let type_section = [0x01, 0x04, 0x01, 0x60, 0x00, 0x00]
  let function_section = [0x03, 0x02, 0x01, 0x00]
  let code_entry_body = list.append([0x00], body)
  let code_entry = list.append([list.length(code_entry_body)], code_entry_body)
  let code_vec = list.append([0x01], code_entry)
  let code_section = list.append([0x0A, list.length(code_vec)], code_vec)
  list.flatten([
    [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
    type_section,
    function_section,
    code_section,
  ])
}

pub fn decode_trunc_sat_ok_test() {
  // 0xFC sub-opcode 0 = i32.trunc_sat_f32_s.
  let assert Ok(m) = decode.decode(bytes(module_with_body([0xFC, 0x00, 0x0B])))
  let assert [func] = m.funcs
  func.body
  |> should.equal([ast.I32TruncSatF32S, ast.End])
}

pub fn decode_trunc_sat_unknown_sub_test() {
  // 0xFC sub-opcode 32 is outside the known range (0..7 sat, 8..17 bulk). (Sub 8 is
  // now `memory.init`, so the old sub-8 rejection no longer applies.)
  decode.decode(bytes(module_with_body([0xFC, 0x20, 0x0B])))
  |> should.equal(Error(ast.UnknownSatOpcode(32)))
}

pub fn decode_br_table_test() {
  // br_table [0,1,2] default 3, then end.
  let assert Ok(m) =
    decode.decode(
      bytes(module_with_body([0x0E, 0x03, 0x00, 0x01, 0x02, 0x03, 0x0B])),
    )
  let assert [func] = m.funcs
  func.body
  |> should.equal([ast.BrTable(targets: [0, 1, 2], default: 3), ast.End])
}

// ───────────────── section skipping (custom + out-of-scope) ─────────────────

pub fn skip_custom_section_test() {
  // Insert a custom section (id 0, size 3, contents "abc") right after the
  // preamble; decode must ignore it and yield the same AST as `add`.
  let with_custom =
    list.flatten([
      list.take(add_fixture, 8),
      [0x00, 0x03, 0x61, 0x62, 0x63],
      list.drop(add_fixture, 8),
    ])
  decode.decode(bytes(with_custom))
  |> should.equal(decode.decode(bytes(add_fixture)))
}

pub fn empty_import_section_neutral_test() {
  // The import section (id 2) is now DECODED (Phase 5). An EMPTY import section
  // (count 0) adds no imports, so the AST is identical to `add` (imports == [],
  // imported_func_count == 0) — the neutrality property. Insert `[0x02, 0x01, 0x00]`
  // (id 2, size 1, count 0) between type(1, 17 bytes in) and function(3).
  let with_import =
    list.flatten([
      list.take(add_fixture, 17),
      [0x02, 0x01, 0x00],
      list.drop(add_fixture, 17),
    ])
  decode.decode(bytes(with_import))
  |> should.equal(decode.decode(bytes(add_fixture)))
}

// ─────────────────────── fail-closed negative suite ───────────────────────
// Every malformation must return a typed DecodeError (never a panic).

pub fn bad_magic_test() {
  decode.decode(<<0x00, 0x61, 0x73, 0x6C, 0x01, 0x00, 0x00, 0x00>>)
  |> should.equal(Error(ast.BadMagic))
}

pub fn bad_magic_short_test() {
  decode.decode(<<0x00, 0x61>>)
  |> should.equal(Error(ast.BadMagic))
}

pub fn empty_input_test() {
  decode.decode(<<>>)
  |> should.equal(Error(ast.BadMagic))
}

pub fn bad_version_test() {
  decode.decode(<<0x00, 0x61, 0x73, 0x6D, 0x02, 0x00, 0x00, 0x00>>)
  |> should.equal(Error(ast.BadVersion))
}

pub fn truncated_version_test() {
  decode.decode(<<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00>>)
  |> should.equal(Error(ast.Truncated))
}

pub fn truncated_section_size_test() {
  // Type section declares size 7 but no contents follow.
  decode.decode(<<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07>>)
  |> should.equal(Error(ast.Truncated))
}

pub fn overflow_section_size_test() {
  // Section size LEB overflows u32.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0x1F],
      ]),
    ),
  )
  |> should.equal(Error(ast.LebOverflow))
}

pub fn section_size_mismatch_test() {
  // Type section size 5, but the functype only consumes 4 bytes, leaving 1.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x05, 0x01, 0x60, 0x00, 0x00, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.SectionSizeMismatch))
}

pub fn section_order_test() {
  // Two type sections: the second's id (1) is not strictly greater.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.SectionOrder))
}

pub fn bad_functype_form_test() {
  // functype must begin with 0x60; here it is 0x61.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x02, 0x01, 0x61],
      ]),
    ),
  )
  |> should.equal(Error(ast.BadCompositeType))
}

pub fn bad_valtype_test() {
  // A param valtype byte 0x00 is not a value type.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x05, 0x01, 0x60, 0x01, 0x00, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.BadValType))
}

pub fn unknown_opcode_test() {
  // Replace the I32Add (0x6A) byte of `add` with 0x27 (unassigned).
  decode.decode(bytes(replace(add_fixture, 39, 0x27)))
  |> should.equal(Error(ast.UnknownOpcode(0x27)))
}

pub fn bad_export_kind_test() {
  // Replace the export kind byte (index 28, 0x00=func) with 0x05.
  decode.decode(bytes(replace(add_fixture, 28, 0x05)))
  |> should.equal(Error(ast.BadExportKind))
}

pub fn invalid_utf8_name_test() {
  // Replace the first byte of the "add" export name (index 25) with 0xFF, which
  // can never begin a valid UTF-8 sequence.
  decode.decode(bytes(replace(add_fixture, 25, 0xFF)))
  |> should.equal(Error(ast.InvalidUtf8))
}

pub fn func_code_count_mismatch_test() {
  // function section declares 1 function but there is no code section.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
        [0x03, 0x02, 0x01, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.FuncCodeCountMismatch))
}

pub fn code_entry_size_mismatch_test() {
  // A code entry whose declared size leaves trailing bytes after the expr's End.
  // body = locals(00) + nop(01) + end(0B) = 3 bytes, but declare size 4 with an
  // extra trailing byte inside the entry.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
        [0x03, 0x02, 0x01, 0x00],
        [0x0A, 0x06, 0x01, 0x04, 0x00, 0x01, 0x0B, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.SectionSizeMismatch))
}

// ───────────── fail-closed negative suite: NEW Phase-2 surface ─────────────
// Each malformation of a new section/opcode returns a SPECIFIC typed DecodeError
// (binary/types.html limits/reftype/globaltype; binary/modules.html elem/data;
// binary/instructions.html memarg, memory.size/grow, select_t). Never a panic.

/// Wrap a single non-custom section (its raw bytes) right after the preamble.
fn module_with_section(section: List(Int)) -> List(Int) {
  list.flatten([[0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00], section])
}

pub fn memarg_truncated_test() {
  // i32.load (0x28) with the input ending before its memarg's align LEB.
  decode.decode(bytes(module_with_body([0x28])))
  |> should.equal(Error(ast.Truncated))
}

// Phase 5: memory.size/grow now carry a `u32` memidx (was a reserved 0x00 byte);
// any index decodes (multi-memory). Spec binary/instructions §memory.
pub fn memory_grow_memidx_test() {
  let assert Ok(m) = decode.decode(bytes(module_with_body([0x40, 0x00, 0x0B])))
  let assert [func] = m.funcs
  func.body
  |> should.equal([ast.MemoryGrow(0), ast.End])
}

pub fn memory_size_memidx_test() {
  let assert Ok(m) = decode.decode(bytes(module_with_body([0x3F, 0x00, 0x0B])))
  let assert [func] = m.funcs
  func.body
  |> should.equal([ast.MemorySize(0), ast.End])
}

pub fn bad_limits_flag_test() {
  // Memory section: limits flag 0x02 (shared/threads) is out of scope. (0x04/0x05
  // are now accepted memory64 forms; shared is not — spec/threads proposal.)
  decode.decode(bytes(module_with_section([0x05, 0x02, 0x01, 0x02])))
  |> should.equal(Error(ast.BadLimitsFlag))
}

pub fn table_limits_bad_flag_test() {
  // Table section: a table limits flag with the index-type bit (0x04) is out of
  // scope (table64) → BadLimitsFlag. Section 4, count 1, funcref (0x70), flag 0x04.
  decode.decode(bytes(module_with_section([0x04, 0x03, 0x01, 0x70, 0x04])))
  |> should.equal(Error(ast.BadLimitsFlag))
}

pub fn externref_table_accepted_test() {
  // Table section: element-type byte 0x6F (externref) is now a valid reftype (was
  // BadRefType in Phase 2). Section 4, count 1, externref (0x6F), limits min 1.
  let assert Ok(m) =
    decode.decode(
      bytes(module_with_section([0x04, 0x04, 0x01, 0x6F, 0x00, 0x01])),
    )
  m.tables
  |> should.equal([ast.TableType(ast.ExternRef, ast.Limits(min: 1, max: None))])
}

pub fn bad_heap_type_table_test() {
  // Table section: element-type byte 0x7B (v128, SIMD) is not a reftype →
  // BadHeapType (reftype-only position). Section 4, count 1, byte 0x7B.
  decode.decode(bytes(module_with_section([0x04, 0x02, 0x01, 0x7B])))
  |> should.equal(Error(ast.BadHeapType))
}

pub fn bad_mutability_test() {
  // Global section: i32 global with mut byte 0x02 (not 0x00/0x01).
  decode.decode(bytes(module_with_section([0x06, 0x03, 0x01, 0x7F, 0x02])))
  |> should.equal(Error(ast.BadMutability))
}

pub fn bad_elem_kind_flag_test() {
  // Element section: a leading flag 0x08 is beyond the 0..7 grammar → BadElemKind.
  decode.decode(bytes(module_with_section([0x09, 0x02, 0x01, 0x08])))
  |> should.equal(Error(ast.BadElemKind))
}

pub fn bad_elemkind_byte_test() {
  // Element flag 1 (passive funcidx) with an elemkind byte 0x01 (not 0x00 funcref)
  // → BadElemKind. Section 9, count 1, flag 0x01, elemkind 0x01.
  decode.decode(bytes(module_with_section([0x09, 0x03, 0x01, 0x01, 0x01])))
  |> should.equal(Error(ast.BadElemKind))
}

pub fn bad_data_kind_test() {
  // Data section: a leading flag 0x03 is outside the 0/1/2 grammar → BadDataKind.
  decode.decode(bytes(module_with_section([0x0B, 0x02, 0x01, 0x03])))
  |> should.equal(Error(ast.BadDataKind))
}

pub fn oversized_vec_count_test() {
  // Element section whose funcidx vector declares a ~4-billion count but supplies
  // no entries: the first element read hits EOF → Truncated (no loop, no panic).
  decode.decode(
    bytes(
      module_with_section([
        0x09, 0x0A, 0x01, 0x00, 0x41, 0x00, 0x0B, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F,
      ]),
    ),
  )
  |> should.equal(Error(ast.Truncated))
}

pub fn truncated_data_payload_test() {
  // Data segment (form 0x00, offset i32.const 0) declaring 5 payload bytes but
  // supplying only 2 → Truncated (the byte-vector slice never over-reads).
  decode.decode(
    bytes(
      module_with_section([
        0x0B, 0x08, 0x01, 0x00, 0x41, 0x00, 0x0B, 0x05, 0x68, 0x69,
      ]),
    ),
  )
  |> should.equal(Error(ast.Truncated))
}

// ─────────────────────────── totality / fuzz ───────────────────────────
// The decoder must be TOTAL over untrusted input: every byte sequence yields
// Ok(_) or Error(_), never a crash/panic (overview D4).

/// Forces full evaluation of a decode result and confirms it is a Result value.
fn is_total(r: Result(ast.Module, ast.DecodeError)) -> Bool {
  case r {
    Ok(_) -> True
    Error(_) -> True
  }
}

pub fn fuzz_single_byte_mutations_test() {
  let len = list.length(add_fixture)
  // For every byte position, replace it with every value 0..255 and decode.
  let positions = int_range(0, len - 1)
  let values = int_range(0, 255)
  let all_total =
    list.all(positions, fn(pos) {
      list.all(values, fn(v) {
        is_total(decode.decode(bytes(replace(add_fixture, pos, v))))
      })
    })
  all_total
  |> should.equal(True)
}

pub fn fuzz_truncation_test() {
  // Every prefix of the fixture decodes to a Result (never crashes); the full
  // fixture is Ok and every shorter prefix is an Error.
  let len = list.length(add_fixture)
  let prefixes = int_range(0, len)
  list.all(prefixes, fn(n) {
    let r = decode.decode(bytes(list.take(add_fixture, n)))
    case n == len {
      True -> r == decode.decode(bytes(add_fixture))
      False -> is_total(r) && r != decode.decode(bytes(add_fixture))
    }
  })
  |> should.equal(True)
}

/// Single-byte-mutation totality sweep over an arbitrary fixture (every position
/// × every byte value 0..255 → a Result, never a panic). Shared by the new-surface
/// fuzz tests.
fn sweep_single_byte_mutations(fixture: List(Int)) -> Bool {
  let positions = int_range(0, list.length(fixture) - 1)
  let values = int_range(0, 255)
  list.all(positions, fn(pos) {
    list.all(values, fn(v) {
      is_total(decode.decode(bytes(replace(fixture, pos, v))))
    })
  })
}

pub fn fuzz_mem_fixture_mutations_test() {
  // The memory fixture exercises a new SECTION (5) and new opcodes (load/store +
  // memarg). Every single-byte mutation stays total (fail-closed, never panics).
  sweep_single_byte_mutations(mem_ints)
  |> should.equal(True)
}

pub fn fuzz_conv_fixture_mutations_test() {
  // The conversion fixture exercises the full 0xA7..0xBF block. Every single-byte
  // mutation stays total.
  sweep_single_byte_mutations(conv_ints)
  |> should.equal(True)
}

pub fn fuzz_mem_fixture_truncation_test() {
  // Every prefix of the memory fixture decodes to a Result (never a crash); the
  // full fixture is Ok, every shorter prefix is an Error.
  let len = list.length(mem_ints)
  list.all(int_range(0, len), fn(n) {
    let r = decode.decode(bytes(list.take(mem_ints, n)))
    case n == len {
      True -> r == decode.decode(bytes(mem_ints))
      False -> is_total(r) && r != decode.decode(bytes(mem_ints))
    }
  })
  |> should.equal(True)
}

// ═══════════════════ Phase 5 («WASM-AST3») worked fixtures ═══════════════════
// Each `.wasm` is produced by `wat2wasm --enable-multi-memory --enable-memory64`
// and asserted against the binary-format spec (cited per fixture). Reference types
// and bulk memory are default-on in this wat2wasm; `--enable-all` is deliberately
// AVOIDED (it would turn on the experimental compact-import encoding). Bytes are
// embedded so the suite needs no external tool at run time.

// (global externref (ref.null extern)) — binary/types.html §reftype/globaltype,
// binary/instructions.html §reference (ref.null 0xD0 <heaptype>).
const glob_extern_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x06, 0x06, 0x01, 0x6F, 0x00,
  0xD0, 0x6F, 0x0B,
]

pub fn decode_global_externref_test() {
  let assert Ok(m) = decode.decode(bytes(glob_extern_ints))
  m.globals
  |> should.equal([
    ast.Global(ty: ast.ExternRef, mutable: False, init: [
      ast.RefNull(ast.ExternRef),
    ]),
  ])
}

// (func $f) (global funcref (ref.func $f)) — ref.func (0xD2 <funcidx>).
const glob_funcref_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x06, 0x06, 0x01, 0x70, 0x00, 0xD2, 0x00, 0x0B,
  0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B,
]

pub fn decode_global_funcref_test() {
  let assert Ok(m) = decode.decode(bytes(glob_funcref_ints))
  m.globals
  |> should.equal([
    ast.Global(ty: ast.FuncRef, mutable: False, init: [ast.RefFunc(0)]),
  ])
}

// (table 1 externref) + table.set 0 (0x26) / table.get 0 (0x25).
// binary/types.html §tabletype, binary/instructions.html §table.
const tableops_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x09, 0x02, 0x60, 0x01,
  0x6F, 0x00, 0x60, 0x00, 0x01, 0x6F, 0x03, 0x03, 0x02, 0x00, 0x01, 0x04, 0x04,
  0x01, 0x6F, 0x00, 0x01, 0x0A, 0x11, 0x02, 0x08, 0x00, 0x41, 0x00, 0x20, 0x00,
  0x26, 0x00, 0x0B, 0x06, 0x00, 0x41, 0x00, 0x25, 0x00, 0x0B,
]

pub fn decode_externref_table_and_table_get_set_test() {
  let assert Ok(m) = decode.decode(bytes(tableops_ints))
  m.tables
  |> should.equal([ast.TableType(ast.ExternRef, ast.Limits(min: 1, max: None))])
  let assert [setter, getter] = m.funcs
  setter.body
  |> should.equal([
    ast.I32Const(0),
    ast.LocalGet(0),
    ast.TableSet(0),
    ast.End,
  ])
  getter.body
  |> should.equal([ast.I32Const(0), ast.TableGet(0), ast.End])
}

// ref.null func (0xD0 0x70), ref.is_null (0xD1), ref.func $f (0xD2).
const ref_instrs_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0C, 0x03, 0x60, 0x00,
  0x00, 0x60, 0x00, 0x01, 0x7F, 0x60, 0x00, 0x01, 0x70, 0x03, 0x04, 0x03, 0x00,
  0x01, 0x02, 0x0A, 0x0F, 0x03, 0x02, 0x00, 0x0B, 0x05, 0x00, 0xD0, 0x70, 0xD1,
  0x0B, 0x04, 0x00, 0xD2, 0x00, 0x0B,
]

pub fn decode_reference_instructions_test() {
  let assert Ok(m) = decode.decode(bytes(ref_instrs_ints))
  let assert [_f, isnull, reffunc] = m.funcs
  isnull.body
  |> should.equal([ast.RefNull(ast.FuncRef), ast.RefIsNull, ast.End])
  reffunc.body
  |> should.equal([ast.RefFunc(0), ast.End])
}

// select (result i32) — typed select 0x1C with a one-element valtype vector.
// binary/instructions.html §parametric.
const select_t_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x01, 0x60, 0x03,
  0x7F, 0x7F, 0x7F, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x0A, 0x0D, 0x01, 0x0B,
  0x00, 0x20, 0x00, 0x20, 0x01, 0x20, 0x02, 0x1C, 0x01, 0x7F, 0x0B,
]

pub fn decode_typed_select_test() {
  let assert Ok(m) = decode.decode(bytes(select_t_ints))
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.LocalGet(0),
    ast.LocalGet(1),
    ast.LocalGet(2),
    ast.SelectT([ast.I32]),
    ast.End,
  ])
}

pub fn decode_untyped_select_still_test() {
  // The untyped `select` (0x1B) still decodes to the nullary `Select`.
  let assert Ok(m) = decode.decode(bytes(module_with_body([0x1B, 0x0B])))
  let assert [func] = m.funcs
  func.body
  |> should.equal([ast.Select, ast.End])
}

// (memory 1) + two passive data + memory.init/data.drop/memory.copy/memory.fill.
// binary/instructions.html §bulk; datacount section (id 12) present.
// ANTI-SWAP (R3): memory.init here is `FC 08 01 00` = dataidx 1 THEN memidx 0, so
// the decode MUST be MemoryInit(data: 1, mem: 0). A field swap would give data 0.
const mem_bulk_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x0C, 0x01, 0x02,
  0x0A, 0x24, 0x01, 0x22, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x02, 0xFC, 0x08,
  0x01, 0x00, 0xFC, 0x09, 0x00, 0x41, 0x00, 0x41, 0x04, 0x41, 0x02, 0xFC, 0x0A,
  0x00, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x04, 0xFC, 0x0B, 0x00, 0x0B, 0x0B,
  0x09, 0x02, 0x01, 0x02, 0x68, 0x69, 0x01, 0x02, 0x79, 0x6F,
]

pub fn decode_memory_bulk_ops_test() {
  let assert Ok(m) = decode.decode(bytes(mem_bulk_ints))
  // datacount == length(data) == 2; both data segments passive.
  m.data_count
  |> should.equal(Some(2))
  m.data
  |> should.equal([
    ast.DataSegment(ast.DataPassive, <<0x68, 0x69>>),
    ast.DataSegment(ast.DataPassive, <<0x79, 0x6F>>),
  ])
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.I32Const(0),
    ast.I32Const(0),
    ast.I32Const(2),
    // ANTI-SWAP: dataidx(1) decoded first, memidx(0) second.
    ast.MemoryInit(data: 1, mem: 0),
    ast.DataDrop(0),
    ast.I32Const(0),
    ast.I32Const(4),
    ast.I32Const(2),
    ast.MemoryCopy(dst_mem: 0, src_mem: 0),
    ast.I32Const(0),
    ast.I32Const(0),
    ast.I32Const(4),
    ast.MemoryFill(0),
    ast.End,
  ])
}

// Two funcref tables + one passive elem + the six table ops.
// ANTI-SWAP (R3): table.init here is `FC 0C 00 01` = elemidx 0 THEN tableidx 1, so
// the decode MUST be TableInit(elem: 0, table: 1). table.copy `FC 0E 00 01` is
// dst-table 0 THEN src-table 1 → TableCopy(dst_table: 0, src_table: 1).
const table_bulk_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x03, 0x02, 0x00, 0x00, 0x04, 0x07, 0x02, 0x70, 0x00, 0x01, 0x70,
  0x00, 0x02, 0x09, 0x05, 0x01, 0x01, 0x00, 0x01, 0x00, 0x0A, 0x33, 0x02, 0x02,
  0x00, 0x0B, 0x2E, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0xFC, 0x0C, 0x00,
  0x01, 0xFC, 0x0D, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0xFC, 0x0E, 0x00,
  0x01, 0xD0, 0x70, 0x41, 0x01, 0xFC, 0x0F, 0x00, 0x1A, 0xFC, 0x10, 0x00, 0x1A,
  0x41, 0x00, 0xD0, 0x70, 0x41, 0x00, 0xFC, 0x11, 0x00, 0x0B,
]

pub fn decode_table_bulk_ops_test() {
  let assert Ok(m) = decode.decode(bytes(table_bulk_ints))
  m.tables
  |> should.equal([
    ast.TableType(ast.FuncRef, ast.Limits(min: 1, max: None)),
    ast.TableType(ast.FuncRef, ast.Limits(min: 2, max: None)),
  ])
  // Passive funcidx element segment.
  m.elements
  |> should.equal([
    ast.ElementSegment(ast.ElemPassive, ast.FuncRef, ast.ElemFuncs([0])),
  ])
  let assert [_f, ops] = m.funcs
  ops.body
  |> should.equal([
    ast.I32Const(0),
    ast.I32Const(0),
    ast.I32Const(0),
    // ANTI-SWAP: elemidx(0) decoded first, tableidx(1) second.
    ast.TableInit(elem: 0, table: 1),
    ast.ElemDrop(0),
    ast.I32Const(0),
    ast.I32Const(0),
    ast.I32Const(0),
    ast.TableCopy(dst_table: 0, src_table: 1),
    ast.RefNull(ast.FuncRef),
    ast.I32Const(1),
    ast.TableGrow(0),
    ast.Drop,
    ast.TableSize(0),
    ast.Drop,
    ast.I32Const(0),
    ast.RefNull(ast.FuncRef),
    ast.I32Const(0),
    ast.TableFill(0),
    ast.End,
  ])
}

// (memory 1)(memory 1) + i32.store into memory 1 — the bit-6 memarg memidx.
// The store's flags byte is 0x42 (bit 6 set): align = 0x42 ^ 0x40 = 2, memidx 1.
const multimem_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x05, 0x05, 0x02, 0x00, 0x01, 0x00, 0x01, 0x0A,
  0x0C, 0x01, 0x0A, 0x00, 0x41, 0x00, 0x41, 0x2A, 0x36, 0x42, 0x01, 0x00, 0x0B,
]

pub fn decode_multi_memory_memarg_test() {
  let assert Ok(m) = decode.decode(bytes(multimem_ints))
  // Two memories declared (section 5).
  list.length(m.memories)
  |> should.equal(2)
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.I32Const(0),
    ast.I32Const(42),
    ast.I32Store(ast.MemArg(align: 2, offset: 0, mem: 1)),
    ast.End,
  ])
}

// (memory i64 1) — memory64 limits flag 0x04 → Idx64. binary/types.html §limits.
const mem64_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x05, 0x03, 0x01, 0x04, 0x01,
]

pub fn decode_memory64_test() {
  let assert Ok(m) = decode.decode(bytes(mem64_ints))
  m.memories
  |> should.equal([ast.MemType(ast.Limits(min: 1, max: None), ast.Idx64)])
}

pub fn decode_memory32_idx_type_test() {
  // An i32 memory decodes Idx32 (neutrality): (memory 1) flag 0x00.
  let assert Ok(m) = decode.decode(bytes(mem_ints))
  m.memories
  |> should.equal([ast.MemType(ast.Limits(min: 1, max: None), ast.Idx32)])
}

// Element-segment flag grammar (binary/modules.html §element-section).
const elem_passive_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x09, 0x05, 0x01, 0x01, 0x00, 0x01, 0x00, 0x0A,
  0x04, 0x01, 0x02, 0x00, 0x0B,
]

const elem_declarative_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x09, 0x05, 0x01, 0x03, 0x00, 0x01, 0x00, 0x0A,
  0x04, 0x01, 0x02, 0x00, 0x0B,
]

const elem_flag2_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x04, 0x07, 0x02, 0x70, 0x00, 0x01, 0x70, 0x00,
  0x01, 0x09, 0x09, 0x01, 0x02, 0x01, 0x41, 0x00, 0x0B, 0x00, 0x01, 0x00, 0x0A,
  0x04, 0x01, 0x02, 0x00, 0x0B,
]

const elem_flag4_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00, 0x01, 0x09, 0x0C,
  0x01, 0x04, 0x41, 0x00, 0x0B, 0x02, 0xD2, 0x00, 0x0B, 0xD0, 0x70, 0x0B, 0x0A,
  0x04, 0x01, 0x02, 0x00, 0x0B,
]

const elem_flag5_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x09, 0x07, 0x01, 0x05, 0x6F,
  0x01, 0xD0, 0x6F, 0x0B,
]

const elem_flag6_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x04, 0x07, 0x02, 0x70, 0x00, 0x01, 0x70, 0x00,
  0x01, 0x09, 0x0B, 0x01, 0x06, 0x01, 0x41, 0x00, 0x0B, 0x70, 0x01, 0xD0, 0x70,
  0x0B, 0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B,
]

pub fn decode_element_flag1_passive_funcidx_test() {
  let assert Ok(m) = decode.decode(bytes(elem_passive_ints))
  m.elements
  |> should.equal([
    ast.ElementSegment(ast.ElemPassive, ast.FuncRef, ast.ElemFuncs([0])),
  ])
}

pub fn decode_element_flag3_declarative_test() {
  let assert Ok(m) = decode.decode(bytes(elem_declarative_ints))
  m.elements
  |> should.equal([
    ast.ElementSegment(ast.ElemDeclarative, ast.FuncRef, ast.ElemFuncs([0])),
  ])
}

pub fn decode_element_flag2_active_tableidx_funcidx_test() {
  // Flag 2: active into an EXPLICIT table index (1) via a funcidx list.
  let assert Ok(m) = decode.decode(bytes(elem_flag2_ints))
  m.elements
  |> should.equal([
    ast.ElementSegment(
      ast.ElemActive(1, [ast.I32Const(0)]),
      ast.FuncRef,
      ast.ElemFuncs([0]),
    ),
  ])
}

pub fn decode_element_flag4_active_expr_test() {
  // Flag 4: active into table 0 with an EXPRESSION-list init (ref.func / ref.null).
  let assert Ok(m) = decode.decode(bytes(elem_flag4_ints))
  m.elements
  |> should.equal([
    ast.ElementSegment(
      ast.ElemActive(0, [ast.I32Const(0)]),
      ast.FuncRef,
      ast.ElemExprs([[ast.RefFunc(0)], [ast.RefNull(ast.FuncRef)]]),
    ),
  ])
}

pub fn decode_element_flag5_passive_externref_expr_test() {
  // Flag 5: passive, EXPLICIT reftype (externref), expression init.
  let assert Ok(m) = decode.decode(bytes(elem_flag5_ints))
  m.elements
  |> should.equal([
    ast.ElementSegment(
      ast.ElemPassive,
      ast.ExternRef,
      ast.ElemExprs([[ast.RefNull(ast.ExternRef)]]),
    ),
  ])
}

pub fn decode_element_flag6_active_tableidx_expr_test() {
  // Flag 6: active into an explicit table index (1), reftype + expression init.
  let assert Ok(m) = decode.decode(bytes(elem_flag6_ints))
  m.elements
  |> should.equal([
    ast.ElementSegment(
      ast.ElemActive(1, [ast.I32Const(0)]),
      ast.FuncRef,
      ast.ElemExprs([[ast.RefNull(ast.FuncRef)]]),
    ),
  ])
}

// Data-segment flag grammar (binary/modules.html §data-section).
const data_passive_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x0C, 0x01, 0x01,
  0x0A, 0x07, 0x01, 0x05, 0x00, 0xFC, 0x09, 0x00, 0x0B, 0x0B, 0x05, 0x01, 0x01,
  0x02, 0x78, 0x78,
]

const data_active_memidx_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x05, 0x05, 0x02, 0x00, 0x01,
  0x00, 0x01, 0x0B, 0x09, 0x01, 0x02, 0x01, 0x41, 0x00, 0x0B, 0x02, 0x68, 0x69,
]

pub fn decode_data_flag1_passive_test() {
  // Passive data (flag 1) + a datacount section (count 1) + a data.drop.
  let assert Ok(m) = decode.decode(bytes(data_passive_ints))
  m.data_count
  |> should.equal(Some(1))
  m.data
  |> should.equal([ast.DataSegment(ast.DataPassive, <<0x78, 0x78>>)])
}

pub fn decode_data_flag2_active_memidx_test() {
  // Flag 2: active into an EXPLICIT memory index (1, multi-memory), offset i32 0.
  let assert Ok(m) = decode.decode(bytes(data_active_memidx_ints))
  list.length(m.memories)
  |> should.equal(2)
  m.data
  |> should.equal([
    ast.DataSegment(ast.DataActive(1, [ast.I32Const(0)]), <<0x68, 0x69>>),
  ])
}

// Non-function imports (binary/modules.html §import-section): func/global/table/mem.
const imports_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x02, 0x1F, 0x04, 0x01, 0x6D, 0x01, 0x66, 0x00, 0x00, 0x01, 0x6D, 0x01,
  0x67, 0x03, 0x7F, 0x00, 0x01, 0x6D, 0x01, 0x74, 0x01, 0x70, 0x00, 0x01, 0x01,
  0x6D, 0x03, 0x6D, 0x65, 0x6D, 0x02, 0x00, 0x01,
]

pub fn decode_non_function_imports_test() {
  let assert Ok(m) = decode.decode(bytes(imports_ints))
  m.imports
  |> should.equal([
    ast.Import("m", "f", ast.ImportFunc(0)),
    ast.Import("m", "g", ast.ImportGlobal(ast.I32, False)),
    ast.Import(
      "m",
      "t",
      ast.ImportTable(ast.TableType(ast.FuncRef, ast.Limits(min: 1, max: None))),
    ),
    ast.Import(
      "m",
      "mem",
      ast.ImportMemory(ast.MemType(ast.Limits(min: 1, max: None), ast.Idx32)),
    ),
  ])
  // imported_func_count is COMPUTED = number of func imports (1 of 4).
  m.imported_func_count
  |> should.equal(1)
}

pub fn decode_import_section_neutral_func_count_test() {
  // Neutrality: a module with NO import section keeps imported_func_count == 0.
  let assert Ok(m) = decode.decode(bytes(add_fixture))
  m.imported_func_count
  |> should.equal(0)
}

// ═══════════════════ Phase 5: fail-closed negative suite ═══════════════════
// Each malformation of the NEW surface returns a SPECIFIC typed DecodeError, never
// a panic/loop. Spec: binary/types.html, binary/instructions.html, §5.5.14.

pub fn ref_null_bad_heaptype_test() {
  // ref.null with a heaptype byte 0x7F (i32, not a reftype) → BadHeapType.
  decode.decode(bytes(module_with_body([0xD0, 0x7F, 0x0B])))
  |> should.equal(Error(ast.BadHeapType))
}

pub fn bulk_unknown_sub_opcode_test() {
  // A 0xFC sub-opcode 18 is outside the 0..17 range → UnknownSatOpcode(18).
  decode.decode(bytes(module_with_body([0xFC, 0x12, 0x0B])))
  |> should.equal(Error(ast.UnknownSatOpcode(18)))
}

pub fn memory_init_truncated_test() {
  // memory.init with dataidx present but memidx at EOF → Truncated.
  decode.decode(bytes(module_with_body([0xFC, 0x08, 0x00])))
  |> should.equal(Error(ast.Truncated))
}

pub fn memarg_memidx_truncated_test() {
  // i32.load whose memarg flags set bit 6 (0x42) but the memidx LEB is missing.
  decode.decode(bytes(module_with_body([0x28, 0x42])))
  |> should.equal(Error(ast.Truncated))
}

pub fn bad_import_kind_test() {
  // importdesc kind byte 0x05 (not 0x00..0x04 — Phase 7 added 0x04 = tag, but 0x05 is
  // still out of range) → BadImportKind. Import "a" "b" 0x05.
  decode.decode(
    bytes(module_with_section([0x02, 0x06, 0x01, 0x01, 0x61, 0x01, 0x62, 0x05])),
  )
  |> should.equal(Error(ast.BadImportKind))
}

pub fn select_t_overrun_test() {
  // A typed-select vec count of ~4 billion with no valtypes → Truncated (no loop).
  decode.decode(bytes(module_with_body([0x1C, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F])))
  |> should.equal(Error(ast.Truncated))
}

pub fn datacount_missing_test() {
  // R13 / spec §5.5.14: memory.init present but NO datacount section → malformed.
  decode.decode(bytes(module_with_body([0xFC, 0x08, 0x00, 0x00, 0x0B])))
  |> should.equal(Error(ast.DataCountMissing))
}

pub fn data_drop_missing_datacount_test() {
  // R13: data.drop also requires a datacount section.
  decode.decode(bytes(module_with_body([0xFC, 0x09, 0x00, 0x0B])))
  |> should.equal(Error(ast.DataCountMissing))
}

pub fn datacount_mismatch_test() {
  // spec §5.5.14: a datacount section (count 1) with NO data section (length 0) is
  // malformed. type + func + datacount(1) + code, no data section.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
        [0x03, 0x02, 0x01, 0x00],
        [0x0C, 0x01, 0x01],
        [0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B],
      ]),
    ),
  )
  |> should.equal(Error(ast.DataCountMismatch))
}

pub fn datacount_after_code_section_order_test() {
  // The datacount section (12) must precede code (10); placed AFTER code its
  // canonical rank (10) is <= code's rank (11) → SectionOrder.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
        [0x03, 0x02, 0x01, 0x00],
        [0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B],
        [0x0C, 0x01, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.SectionOrder))
}

// ═══════════════════ Phase 5: totality sweeps over new fixtures ═══════════════════
// Every single-byte mutation and every truncation of a new-surface fixture yields a
// Result (never a crash). The property is TOTALITY (overview D4/H6).

pub fn fuzz_new_surface_mutations_test() {
  [
    glob_extern_ints,
    tableops_ints,
    ref_instrs_ints,
    select_t_ints,
    mem_bulk_ints,
    table_bulk_ints,
    multimem_ints,
    elem_flag4_ints,
    data_passive_ints,
    imports_ints,
  ]
  |> list.all(sweep_single_byte_mutations)
  |> should.equal(True)
}

pub fn fuzz_new_surface_truncation_test() {
  [mem_bulk_ints, table_bulk_ints, imports_ints, elem_flag4_ints]
  |> list.all(fn(fixture) {
    let full = decode.decode(bytes(fixture))
    let len = list.length(fixture)
    list.all(int_range(0, len), fn(n) {
      let r = decode.decode(bytes(list.take(fixture, n)))
      case n == len {
        True -> r == full
        False -> is_total(r) && r != full
      }
    })
  })
  |> should.equal(True)
}

// The decoder must contain no partial constructs (D4/H6): no `let assert`, `panic`,
// or `todo` is reachable from untrusted input. We assert their textual absence in the
// CODE (comment-only lines, which may name them in prose, are stripped first).
pub fn decode_has_no_partial_constructs_test() {
  let assert Ok(src) = simplifile.read("src/twocore/frontend/wasm/decode.gleam")
  let code =
    src
    |> string.split("\n")
    |> list.filter(fn(line) {
      !string.starts_with(string.trim_start(line), "//")
    })
    |> string.join("\n")
  string.contains(code, "let assert")
  |> should.equal(False)
  string.contains(code, "panic")
  |> should.equal(False)
  string.contains(code, "todo")
  |> should.equal(False)
}

// ═══════════════════ Phase 6: SIMD (the 0xFD family, «WASM-AST4») ═══════════════════
// Assertions target the WebAssembly SIMD BINARY ENCODING, cited per fixture — never
// "whatever decode emits":
//  - the 0xFD sub-opcode table:  binary/instructions.html#vector-instructions
//                              + appendix/index-instructions.html (authoritative index)
//  - the single-byte laneidx, 16-byte v128.const, 16-byte shuffle:
//                                binary/instructions.html#binary-laneidx
//  - the v128 valtype byte 0x7B: binary/types.html#value-types
//  - the -5 v128 blocktype:      binary/instructions.html#binary-blocktype

// ───────────────────────────── SIMD helpers ─────────────────────────────

/// Encode `n` as an unsigned LEB128 `u32` (the wire form of a 0xFD sub-opcode). Used so
/// that a multi-byte sub-opcode such as `i32x4.add = 174` becomes `[0xAE, 0x01]`.
fn uleb(n: Int) -> List(Int) {
  case n < 0x80 {
    True -> [n]
    False -> [n % 0x80 + 0x80, ..uleb(n / 0x80)]
  }
}

/// A minimal module whose single function has signature `functype` (raw functype bytes,
/// e.g. `[0x60, 0x01, 0x7B, 0x01, 0x7B]` for `(param v128)(result v128)`), the given raw
/// `locals_bytes` (a full `vec(locals)`, e.g. `[0x00]` for none, `[0x01, 0x01, 0x7B]` for
/// one `v128` local), and the given `body` (already including its terminating `0x0B`).
fn module_with_locals_body(
  functype: List(Int),
  locals_bytes: List(Int),
  body: List(Int),
) -> List(Int) {
  let type_body = list.append([0x01], functype)
  let type_section = list.append([0x01, list.length(type_body)], type_body)
  let function_section = [0x03, 0x02, 0x01, 0x00]
  let code_entry_body = list.append(locals_bytes, body)
  let code_entry = list.append([list.length(code_entry_body)], code_entry_body)
  let code_vec = list.append([0x01], code_entry)
  let code_section = list.append([0x0A, list.length(code_vec)], code_vec)
  list.flatten([
    [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
    type_section,
    function_section,
    code_section,
  ])
}

/// `module_with_locals_body` with no declared locals.
fn module_with_sig_body(functype: List(Int), body: List(Int)) -> List(Int) {
  module_with_locals_body(functype, [0x00], body)
}

/// Decode a single `0xFD` instruction (sub-opcode `sub` + raw `imms` immediate bytes)
/// placed as the whole body of a `() -> ()` function, returning the FIRST decoded
/// instruction (the SIMD one) or the `DecodeError`. The trailing `End` is appended
/// automatically. `imms` is the exact wire immediate (a memarg, 16 const bytes, a lane
/// byte, …); pass `[]` for a pure lane op.
fn simd_first(sub: Int, imms: List(Int)) -> Result(ast.Instr, ast.DecodeError) {
  let body = list.flatten([[0xFD], uleb(sub), imms, [0x0B]])
  case decode.decode(bytes(module_with_body(body))) {
    Ok(m) ->
      case m.funcs {
        [f] ->
          case f.body {
            [i, ..] -> Ok(i)
            _ -> Error(ast.Truncated)
          }
        _ -> Error(ast.Truncated)
      }
    Error(e) -> Error(e)
  }
}

/// `simd_first`, asserting a successful decode. Panics (test failure) if decode errored —
/// used only for the OK worked-fixtures where the wire is well-formed.
fn simd_ok(sub: Int, imms: List(Int)) -> ast.Instr {
  let assert Ok(i) = simd_first(sub, imms)
  i
}

// ───────────────── the v128 value type in every valtype position ─────────────────

pub fn decode_v128_param_result_test() {
  // (func (param v128) (result v128) local.get 0). functype 0x60 01 7B 01 7B.
  let assert Ok(m) =
    decode.decode(
      bytes(
        module_with_sig_body([0x60, 0x01, 0x7B, 0x01, 0x7B], [0x20, 0x00, 0x0B]),
      ),
    )
  m.types
  |> should.equal([ast.func_def(ast.FuncType([ast.V128], [ast.V128]))])
  let assert [func] = m.funcs
  func.body
  |> should.equal([ast.LocalGet(0), ast.End])
}

pub fn decode_v128_local_test() {
  // (func) with one (local v128): locals vec = [0x01 group][0x01 count][0x7B v128].
  let assert Ok(m) =
    decode.decode(
      bytes(
        module_with_locals_body([0x60, 0x00, 0x00], [0x01, 0x01, 0x7B], [0x0B]),
      ),
    )
  let assert [func] = m.funcs
  func.locals
  |> should.equal([ast.V128])
}

pub fn decode_v128_global_test() {
  // (global v128 (v128.const i32x4 0 0 0 0)) — v128 valtype + a v128.const const-expr.
  // global = [0x7B valtype][0x00 const][0xFD 0x0C <16 bytes>][0x0B end].
  let global_bytes =
    list.flatten([[0x7B, 0x00, 0xFD, 0x0C], list.repeat(0x00, 16), [0x0B]])
  let seg = list.append([0x01], global_bytes)
  let section = list.append([0x06, list.length(seg)], seg)
  let assert Ok(m) = decode.decode(bytes(module_with_section(section)))
  m.globals
  |> should.equal([
    ast.Global(ty: ast.V128, mutable: False, init: [
      ast.V128Const(bytes(list.repeat(0x00, 16))),
    ]),
  ])
}

pub fn decode_v128_select_t_test() {
  // select (result v128): typed-select 0x1C, a vec(valtype) of one v128 (0x7B).
  let assert Ok(m) =
    decode.decode(bytes(module_with_body([0x1C, 0x01, 0x7B, 0x0B])))
  let assert [func] = m.funcs
  func.body
  |> should.equal([ast.SelectT([ast.V128]), ast.End])
}

pub fn decode_v128_blocktype_test() {
  // (block (result v128) …): 0x02 blocktype-byte 0x7B (s33 = -5) → BlockVal(V128).
  let assert Ok(m) =
    decode.decode(bytes(module_with_body([0x02, 0x7B, 0x0B, 0x0B])))
  let assert [func] = m.funcs
  func.body
  |> should.equal([ast.Block(ast.BlockVal(ast.V128)), ast.End, ast.End])
}

pub fn decode_v128_reftype_still_bad_test() {
  // v128 (0x7B) is NOT a reftype: ref.null with heaptype 0x7B → BadHeapType (a
  // reftype-only position), while `bad_heap_type_table_test` covers the tabletype
  // position. Contrast: a (param v128) — a valtype position — is ACCEPTED (above).
  decode.decode(bytes(module_with_body([0xD0, 0x7B, 0x0B])))
  |> should.equal(Error(ast.BadHeapType))
}

// ───────────────── v128.const + i8x16.shuffle immediates (anti-swap) ─────────────────

pub fn decode_v128_const_anti_swap_test() {
  // v128.const (sub 12) reads 16 RAW little-endian bytes verbatim. Bytes 00 01 … 0F must
  // decode to exactly <<0,1,…,15>> — proving byte order is preserved (not reversed).
  simd_ok(12, int_range(0, 15))
  |> should.equal(ast.V128Const(bytes(int_range(0, 15))))
}

pub fn decode_shuffle_anti_swap_test() {
  // i8x16.shuffle (sub 13) reads 16 lane bytes; lanes 0..15 → [0,…,15] (lanes[0] is
  // result lane 0 — not reversed).
  simd_ok(13, int_range(0, 15))
  |> should.equal(ast.I8x16Shuffle(int_range(0, 15)))
}

pub fn decode_shuffle_permutation_test() {
  // A distinct permutation proves each byte lands at its result-lane position and the
  // a/b halves are not swapped: [16,0,17,1,18,2,…,23,7].
  let lanes = [16, 0, 17, 1, 18, 2, 19, 3, 20, 4, 21, 5, 22, 6, 23, 7]
  simd_ok(13, lanes)
  |> should.equal(ast.I8x16Shuffle(lanes))
}

// ───────────────── splat / swizzle / extract-replace lane ─────────────────

pub fn decode_swizzle_and_splat_test() {
  // i8x16.swizzle (14) → SSwizzle; i32x4.splat (17) → SSplat(I32x4);
  // f64x2.splat (20) → SSplat(F64x2).
  simd_ok(14, [])
  |> should.equal(ast.Simd(ast.SSwizzle))
  simd_ok(17, [])
  |> should.equal(ast.Simd(ast.SSplat(ast.I32x4)))
  simd_ok(20, [])
  |> should.equal(ast.Simd(ast.SSplat(ast.F64x2)))
}

pub fn decode_extract_replace_lane_test() {
  // i8x16.extract_lane_s 3 (21) → SExtractLaneS(I8x16, 3);
  // i32x4.replace_lane 2 (28) → SReplaceLane(I32x4, 2);
  // f64x2.extract_lane 1 (33) → SExtractLane(F64x2, 1). The lane byte is the immediate.
  simd_ok(21, [3])
  |> should.equal(ast.Simd(ast.SExtractLaneS(ast.I8x16, 3)))
  simd_ok(28, [2])
  |> should.equal(ast.Simd(ast.SReplaceLane(ast.I32x4, 2)))
  simd_ok(33, [1])
  |> should.equal(ast.Simd(ast.SExtractLane(ast.F64x2, 1)))
}

// ───────────────── per-shape arithmetic (multi-byte LEB disambiguation) ─────────────────

pub fn decode_simd_arith_disambiguation_test() {
  // i8x16.add (110, one-byte sub) → SAdd(I8x16);
  // i32x4.add (174, TWO-byte LEB 0xAE 0x01) → SAdd(I32x4);
  // i64x2.mul (213, 0xD5 0x01) → SMul(I64x2). Proves multi-byte sub-opcode + shape.
  simd_ok(110, [])
  |> should.equal(ast.Simd(ast.SAdd(ast.I8x16)))
  simd_ok(174, [])
  |> should.equal(ast.Simd(ast.SAdd(ast.I32x4)))
  simd_ok(213, [])
  |> should.equal(ast.Simd(ast.SMul(ast.I64x2)))
  // sanity: the multi-byte sub-opcode really is [0xAE, 0x01] for 174.
  uleb(174)
  |> should.equal([0xAE, 0x01])
}

pub fn decode_simd_float_lanes_test() {
  // f32x4.mul (230) → FMul(F32x4); f64x2.pmin (246) → FPMin(F64x2);
  // f32x4.sqrt (227) → FSqrt(F32x4).
  simd_ok(230, [])
  |> should.equal(ast.Simd(ast.FMul(ast.F32x4)))
  simd_ok(246, [])
  |> should.equal(ast.Simd(ast.FPMin(ast.F64x2)))
  simd_ok(227, [])
  |> should.equal(ast.Simd(ast.FSqrt(ast.F32x4)))
}

pub fn decode_simd_comparison_order_test() {
  // i32x4.eq (55) → SEq(I32x4); f64x2.gt (74) → FGt(F64x2) [asserting gt is 74, NOT le];
  // i64x2.lt_s (216) → SLtS(I64x2) [the i64x2 compares live at 214..219, not 35..76].
  simd_ok(55, [])
  |> should.equal(ast.Simd(ast.SEq(ast.I32x4)))
  simd_ok(74, [])
  |> should.equal(ast.Simd(ast.FGt(ast.F64x2)))
  simd_ok(216, [])
  |> should.equal(ast.Simd(ast.SLtS(ast.I64x2)))
}

pub fn decode_simd_bitwise_order_test() {
  // v128.andnot (79) → VAndNot [asserting 79 is andnot, NOT or]; v128.bitselect (82) →
  // VBitselect; v128.any_true (83) → VAnyTrue.
  simd_ok(79, [])
  |> should.equal(ast.Simd(ast.VAndNot))
  simd_ok(82, [])
  |> should.equal(ast.Simd(ast.VBitselect))
  simd_ok(83, [])
  |> should.equal(ast.Simd(ast.VAnyTrue))
}

pub fn decode_simd_narrow_widen_dot_extmul_test() {
  // One representative of each non-uniform family:
  //  i8x16.narrow_i16x8_s (101) → SNarrow(I16x8, True)
  //  i16x8.extend_low_i8x16_u (137) → SExtend(I8x16, Low, False)
  //  i32x4.dot_i16x8_s (186) → SDotI16x8S
  //  i64x2.extmul_high_i32x4_u (223) → SExtMul(I32x4, High, False)
  //  i32x4.extadd_pairwise_i16x8_s (126) → SExtAddPairwise(I16x8, True)
  //  i16x8.q15mulr_sat_s (130) → SQ15MulrSatS ; i8x16.popcnt (98) → SPopcnt(I8x16)
  simd_ok(101, [])
  |> should.equal(ast.Simd(ast.SNarrow(ast.I16x8, True)))
  simd_ok(137, [])
  |> should.equal(ast.Simd(ast.SExtend(ast.I8x16, ast.Low, False)))
  simd_ok(186, [])
  |> should.equal(ast.Simd(ast.SDotI16x8S))
  simd_ok(223, [])
  |> should.equal(ast.Simd(ast.SExtMul(ast.I32x4, ast.High, False)))
  simd_ok(126, [])
  |> should.equal(ast.Simd(ast.SExtAddPairwise(ast.I16x8, True)))
  simd_ok(130, [])
  |> should.equal(ast.Simd(ast.SQ15MulrSatS))
  simd_ok(98, [])
  |> should.equal(ast.Simd(ast.SPopcnt(ast.I8x16)))
}

pub fn decode_simd_saturating_add_sub_test() {
  // The saturating add/sub family (RECONCILIATION S3): i8x16.add_sat_s (111),
  // i8x16.add_sat_u (112), i16x8.sub_sat_s (146), i16x8.sub_sat_u (147).
  simd_ok(111, [])
  |> should.equal(ast.Simd(ast.SAddSatS(ast.I8x16)))
  simd_ok(112, [])
  |> should.equal(ast.Simd(ast.SAddSatU(ast.I8x16)))
  simd_ok(146, [])
  |> should.equal(ast.Simd(ast.SSubSatS(ast.I16x8)))
  simd_ok(147, [])
  |> should.equal(ast.Simd(ast.SSubSatU(ast.I16x8)))
}

pub fn decode_simd_conversions_test() {
  // i32x4.trunc_sat_f32x4_s (248) → STruncSatF32x4S; f64x2.promote_low_f32x4 (95) →
  // SPromoteLowF32x4; f32x4.demote_f64x2_zero (94) → SDemoteF64x2Zero;
  // f32x4.convert_i32x4_s (250) → SConvertF32x4I32x4S.
  simd_ok(248, [])
  |> should.equal(ast.Simd(ast.STruncSatF32x4S))
  simd_ok(95, [])
  |> should.equal(ast.Simd(ast.SPromoteLowF32x4))
  simd_ok(94, [])
  |> should.equal(ast.Simd(ast.SDemoteF64x2Zero))
  simd_ok(250, [])
  |> should.equal(ast.Simd(ast.SConvertF32x4I32x4S))
}

// ───────────────── v128 memory (load / store / splat / extend / zero) ─────────────────

pub fn decode_simd_memory_loads_test() {
  // v128.load (0) align=4 offset=0 → SimdLoad(LoadV128, MemArg(4,0,0));
  // v128.load8_splat (7) → SimdLoad(LoadSplat(8), …);
  // v128.load32x2_u (6) → SimdLoad(LoadExtend(32, False), …);
  // v128.load64_zero (93) → SimdLoad(LoadZero(64), …). memarg = [align, offset].
  simd_ok(0, [0x04, 0x00])
  |> should.equal(ast.SimdLoad(ast.LoadV128, ast.MemArg(4, 0, 0)))
  simd_ok(7, [0x00, 0x00])
  |> should.equal(ast.SimdLoad(ast.LoadSplat(8), ast.MemArg(0, 0, 0)))
  simd_ok(6, [0x03, 0x00])
  |> should.equal(ast.SimdLoad(ast.LoadExtend(32, False), ast.MemArg(3, 0, 0)))
  simd_ok(93, [0x03, 0x00])
  |> should.equal(ast.SimdLoad(ast.LoadZero(64), ast.MemArg(3, 0, 0)))
}

pub fn decode_simd_store_and_memidx_test() {
  // v128.store (11) → SimdStore(MemArg); a (memory 1) form sets MemArg.mem == 1 (the
  // bit-6 memidx flag: align byte 0x44 = 4 | 0x40, then memidx 0x01, then offset 0x00).
  simd_ok(11, [0x04, 0x00])
  |> should.equal(ast.SimdStore(ast.MemArg(4, 0, 0)))
  simd_ok(0, [0x44, 0x01, 0x00])
  |> should.equal(ast.SimdLoad(ast.LoadV128, ast.MemArg(4, 0, 1)))
}

pub fn decode_simd_load_store_lane_anti_swap_test() {
  // load/store-lane read a memarg THEN a lane byte (§E.4). v128.load8_lane (84) with
  // align=0 offset=4 lane=3 → SimdLoadLane(8, MemArg(0,4,0), 3): a swap would read
  // align=4 and take 0 as the lane. v128.store64_lane (91) → the store form.
  simd_ok(84, [0x00, 0x04, 0x03])
  |> should.equal(ast.SimdLoadLane(8, ast.MemArg(0, 4, 0), 3))
  simd_ok(91, [0x00, 0x04, 0x03])
  |> should.equal(ast.SimdStoreLane(64, ast.MemArg(0, 4, 0), 3))
  // (memory 1) lane form: memidx-then-offset-then-lane all exercised.
  simd_ok(85, [0x40, 0x01, 0x00, 0x02])
  |> should.equal(ast.SimdLoadLane(16, ast.MemArg(0, 0, 1), 2))
}

// ───────────────── memory64 decode is unchanged after AST4 (§F regression) ─────────────────

pub fn decode_memory64_still_idx64_test() {
  // (memory i64 1): limits flag 0x04 (Idx64, no max), min 1 → MemType(Limits(1,None), Idx64).
  let mem64 = [0x05, 0x03, 0x01, 0x04, 0x01]
  let assert Ok(m) = decode.decode(bytes(module_with_section(mem64)))
  m.memories
  |> should.equal([ast.MemType(ast.Limits(1, None), ast.Idx64)])
  // (memory 1): flag 0x00 → Idx32 (unchanged).
  let mem32 = [0x05, 0x03, 0x01, 0x00, 0x01]
  let assert Ok(m2) = decode.decode(bytes(module_with_section(mem32)))
  m2.memories
  |> should.equal([ast.MemType(ast.Limits(1, None), ast.Idx32)])
}

// ───────────────── neutrality: a non-SIMD module is unchanged ─────────────────

pub fn decode_simd_neutrality_test() {
  // The `add` fixture (no 0xFD, no v128) decodes to the SAME AST as before the SIMD
  // additions — no `Simd*`/`V128Const` node, no `V128` valtype appears.
  let assert Ok(m) = decode.decode(bytes(add_fixture))
  m.types
  |> should.equal([ast.func_def(ast.FuncType([ast.I32, ast.I32], [ast.I32]))])
  let assert [func] = m.funcs
  func.body
  |> should.equal([ast.LocalGet(0), ast.LocalGet(1), ast.I32Add, ast.End])
}

// ───────────────── fail-closed: reserved gaps + relaxed-SIMD ─────────────────

pub fn decode_simd_reserved_gaps_test() {
  // The reserved gaps in 0..255 are UnknownSimdOpcode — sample one from each block:
  // 154 (i16x8), 162 (i32x4), 226 (f32x4), 238 (f64x2).
  [154, 162, 226, 238]
  |> list.each(fn(sub) {
    simd_first(sub, [])
    |> should.equal(Error(ast.UnknownSimdOpcode(sub)))
  })
}

pub fn decode_simd_relaxed_out_of_scope_test() {
  // Relaxed-SIMD sub-opcodes (>= 256) are deferred → UnknownSimdOpcode. 256 encodes as
  // [0x80, 0x02], 300 as [0xAC, 0x02].
  simd_first(256, [])
  |> should.equal(Error(ast.UnknownSimdOpcode(256)))
  simd_first(300, [])
  |> should.equal(Error(ast.UnknownSimdOpcode(300)))
}

// ───────────────── fail-closed: truncated immediates ─────────────────

pub fn decode_simd_truncated_const_test() {
  // v128.const (12) with only 10 immediate bytes (needs 16) → Truncated.
  simd_first(12, list.repeat(0x00, 10))
  |> should.equal(Error(ast.Truncated))
}

pub fn decode_simd_truncated_shuffle_test() {
  // i8x16.shuffle (13) with only 8 lane bytes (needs 16) → Truncated.
  simd_first(13, list.repeat(0x00, 8))
  |> should.equal(Error(ast.Truncated))
}

pub fn decode_simd_truncated_lane_byte_test() {
  // i8x16.extract_lane_s (21) with the lane byte absent (EOF) → Truncated. Building the
  // body directly (no auto-appended End) so nothing supplies the missing byte.
  decode.decode(bytes(module_with_body([0xFD, 0x15])))
  |> should.equal(Error(ast.Truncated))
}

pub fn decode_simd_truncated_load_lane_test() {
  // v128.load8_lane (84) with the memarg present but the lane byte at EOF → Truncated.
  // Body [0xFD, 84, align=0, offset=0] and then EOF (no lane byte, no End).
  decode.decode(bytes(module_with_body([0xFD, 84, 0x00, 0x00])))
  |> should.equal(Error(ast.Truncated))
}

pub fn decode_simd_truncated_memidx_test() {
  // v128.load (0) whose memarg sets the bit-6 memidx flag (0x40) but whose memidx LEB is
  // truncated (a lone continuation byte 0x80 at EOF) → Truncated.
  decode.decode(bytes(module_with_body([0xFD, 0x00, 0x40, 0x80])))
  |> should.equal(Error(ast.Truncated))
}

pub fn decode_simd_truncated_subopcode_test() {
  // A 0xFD whose sub-opcode LEB is a lone continuation byte at EOF → Truncated.
  decode.decode(bytes(module_with_body([0xFD, 0x80])))
  |> should.equal(Error(ast.Truncated))
  // An over-wide sub-opcode LEB (five continuation bytes exceed the u32 width) →
  // LebTooLong (a fail-closed LEB rejection, never a silent wrap).
  decode.decode(bytes(module_with_body([0xFD, 0x80, 0x80, 0x80, 0x80, 0x80])))
  |> should.equal(Error(ast.LebTooLong))
}

// ───────────────── totality: fuzz over a SIMD fixture ─────────────────

/// A packed SIMD fixture (all sizes computed by `module_with_body`): v128.const,
/// i8x16.shuffle, i32x4.add, v128.load, v128.load8_lane. Built by function rather than a
/// hand-sized `const` so the code-section length fields are always correct.
fn simd_fixture() -> List(Int) {
  module_with_body(
    list.flatten([
      [0xFD, 0x0C],
      int_range(0, 15),
      // v128.const 00..0F
      [0xFD, 0x0D],
      int_range(0, 15),
      // i8x16.shuffle 00..0F
      [0xFD, 0xAE, 0x01],
      // i32x4.add
      [0xFD, 0x00, 0x04, 0x00],
      // v128.load align=4 offset=0
      [0xFD, 0x54, 0x00, 0x04, 0x03],
      // v128.load8_lane align=0 offset=4 lane=3
      [0x0B],
    ]),
  )
}

pub fn decode_simd_fixture_decodes_test() {
  // The packed SIMD fixture decodes cleanly to the five expected instructions — proving
  // the byte layout is well-formed (so the fuzz/truncation sweeps are meaningful).
  let assert Ok(m) = decode.decode(bytes(simd_fixture()))
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.V128Const(bytes(int_range(0, 15))),
    ast.I8x16Shuffle(int_range(0, 15)),
    ast.Simd(ast.SAdd(ast.I32x4)),
    ast.SimdLoad(ast.LoadV128, ast.MemArg(4, 0, 0)),
    ast.SimdLoadLane(8, ast.MemArg(0, 4, 0), 3),
    ast.End,
  ])
}

pub fn fuzz_simd_fixture_mutations_test() {
  // Every single-byte mutation of the SIMD fixture stays TOTAL (a Result, never a
  // panic/crash) — the fail-closed property over the whole 0xFD surface (D4/H6).
  sweep_single_byte_mutations(simd_fixture())
  |> should.equal(True)
}

pub fn fuzz_simd_fixture_truncation_test() {
  // Every prefix of the SIMD fixture decodes to a Result; the full fixture is Ok and
  // every shorter prefix is an Error (never a crash).
  let fixture = simd_fixture()
  let full = decode.decode(bytes(fixture))
  let len = list.length(fixture)
  list.all(int_range(0, len), fn(n) {
    let r = decode.decode(bytes(list.take(fixture, n)))
    case n == len {
      True -> r == full
      False -> is_total(r) && r != full
    }
  })
  |> should.equal(True)
}

// ───────────────── the opcode-map audit (spec-exhaustive over 0..255) ─────────────────

pub fn decode_simd_opcode_map_audit_test() {
  // Derived from the spec's 0xFD opcode table, NOT the implementation: sweep every
  // sub-opcode 0..255 (each wrapped as a 0xFD instruction with a generous zero-immediate
  // pad) and assert EXACTLY the 236 assigned sub-opcodes decode Ok and EXACTLY the 20
  // reserved gaps decode UnknownSimdOpcode(sub). A mis-transcribed opcode fails this.
  let gaps = [
    154, 162, 165, 166, 175, 176, 178, 179, 180, 187, 194, 197, 198, 207, 208,
    210, 211, 212, 226, 238,
  ]
  // Sanity: the spec's audit says 236 assigned + 20 gaps = 256.
  list.length(gaps)
  |> should.equal(20)
  let pad = list.repeat(0x00, 20)
  let misbehaving =
    list.filter(int_range(0, 255), fn(sub) {
      let body = list.flatten([[0xFD], uleb(sub), pad, [0x0B]])
      let result = decode.decode(bytes(module_with_body(body)))
      case list.contains(gaps, sub) {
        // a gap must report UnknownSimdOpcode(sub)
        True -> result != Error(ast.UnknownSimdOpcode(sub))
        // an assigned sub must decode Ok
        False ->
          case result {
            Ok(_) -> False
            Error(_) -> True
          }
      }
    })
  // No sub misbehaves (the list names any offender for a legible failure).
  misbehaving
  |> should.equal([])
  // And exactly 236 subs are assigned (non-gap).
  list.length(int_range(0, 255)) - list.length(gaps)
  |> should.equal(236)
}

// ═════════════════ Phase 7: exception handling (the EH surface, «WASM-AST5») ═════════════════
// Assertions target the WebAssembly exception-handling proposal's BINARY ENCODING (and,
// for the LEGACY surface, the MEASURED bytes of real Porffor 0.61.13 output), cited per
// fixture — never "whatever decode emits":
//  - tag section (id 13; `tag ::= 0x00 typeidx`):   binary/modules.html#tag-section
//  - tag import/export descriptor (kind 0x04):      binary/modules.html#import/#export
//  - throw=0x08 / throw_ref=0x0A / try_table=0x1F + catch kinds 0x00..0x03:
//                                                    binary/instructions.html
//  - legacy try=0x06 / catch=0x07 / rethrow=0x09 / delegate=0x18 / catch_all=0x19:
//                                                    measured Porffor 0.61.13 (03-decode.md §F)
//  - exnref/exn heaptype byte 0x69; blocktype -23:  binary/types.html + #binary-blocktype
// Every worked-AST fixture below is a byte sequence VERIFIED against `wasm-tools parse`
// (modern surface) or against `npx porffor wasm` raw bytes (legacy surface).

// The 8-byte module preamble (`\0asm` + version 1).
const preamble: List(Int) = [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

/// The FIRST function's body of a `module_with_body`-shaped module, or a panic-free
/// failure surfaced as the assertion diff.
fn only_body(module_bytes: List(Int)) -> List(ast.Instr) {
  let assert Ok(m) = decode.decode(bytes(module_bytes))
  let assert [func] = m.funcs
  func.body
}

// ───────────────────────────── §B exnref valtype / heaptype / blocktype ─────────────────────────────

pub fn exnref_param_result_test() {
  // `(func (param exnref) (result exnref) local.get 0)` — exnref valtype byte 0x69 in
  // both the param and result vectors (verified: wasm-tools functype `60 01 69 01 69`).
  let assert Ok(m) =
    decode.decode(
      bytes(
        module_with_sig_body([0x60, 0x01, 0x69, 0x01, 0x69], [0x20, 0x00, 0x0B]),
      ),
    )
  m.types
  |> should.equal([
    ast.func_def(ast.FuncType(params: [ast.ExnRef], results: [ast.ExnRef])),
  ])
}

pub fn exnref_local_test() {
  // `(local exnref)` — the RLE local group `01 01 69` expands to one ExnRef local.
  let assert Ok(m) =
    decode.decode(
      bytes(
        module_with_locals_body([0x60, 0x00, 0x00], [0x01, 0x01, 0x69], [0x0B]),
      ),
    )
  let assert [func] = m.funcs
  func.locals
  |> should.equal([ast.ExnRef])
}

pub fn ref_null_exn_test() {
  // `ref.null exn` = `d0 69` — decode_reftype accepts 0x69 (exn IS a heaptype), unlike
  // v128 (verified: wasm-tools assembles `ref.null exn` to exactly `d0 69`).
  only_body(module_with_body([0xD0, 0x69, 0x0B]))
  |> should.equal([ast.RefNull(ast.ExnRef), ast.End])
}

pub fn select_t_exnref_test() {
  // `select (result exnref)` = `1c 01 69` — a typed-select whose valtype vec is [exnref].
  only_body(module_with_body([0x1C, 0x01, 0x69, 0x0B]))
  |> should.equal([ast.SelectT([ast.ExnRef]), ast.End])
}

pub fn block_result_exnref_test() {
  // `(block (result exnref) …)` — opener `02 69`, blocktype s33 = -23 (verified:
  // wasm-tools assembles `block (result exnref)` to opener bytes `02 69`).
  only_body(module_with_body([0x02, 0x69, 0x0B, 0x0B]))
  |> should.equal([ast.Block(ast.BlockVal(ast.ExnRef)), ast.End, ast.End])
}

pub fn byte_0x69_instruction_is_popcnt_test() {
  // Context disambiguation: 0x69 in an INSTRUCTION position is `i32.popcnt`, NOT exnref
  // (exactly as the SIMD spec disambiguates 0x7B). Only the type/heaptype/blocktype
  // positions read 0x69 as exnref.
  only_body(module_with_body([0x69, 0x0B]))
  |> should.equal([ast.I32Popcnt, ast.End])
}

// ───────────────────────────── §C the tag section (id 13) ─────────────────────────────

pub fn tag_section_one_tag_test() {
  // A module with `(tag (type 0))` where types[0] = `(func (param f64 i32))`.
  // Type section `01 06 01 60 02 7c 7f 00`; tag section `0d 03 01 00 00` (id 13, size 3,
  // count 1, attribute 0x00, typeidx 0) → `Module.tags == [Tag(0)]`.
  let assert Ok(m) =
    decode.decode(
      bytes(
        list.flatten([
          preamble,
          [0x01, 0x06, 0x01, 0x60, 0x02, 0x7C, 0x7F, 0x00],
          [0x0D, 0x03, 0x01, 0x00, 0x00],
        ]),
      ),
    )
  m.tags
  |> should.equal([ast.Tag(type_idx: 0)])
}

pub fn tag_section_two_tags_in_order_test() {
  // Two tags decode in order. Two empty functypes; tag section `0d 05 02 00 00 00 01`
  // (count 2, [attr 0x00, typeidx 0], [attr 0x00, typeidx 1]).
  let assert Ok(m) =
    decode.decode(
      bytes(
        list.flatten([
          preamble,
          [0x01, 0x07, 0x02, 0x60, 0x00, 0x00, 0x60, 0x00, 0x00],
          [0x0D, 0x05, 0x02, 0x00, 0x00, 0x00, 0x01],
        ]),
      ),
    )
  m.tags
  |> should.equal([ast.Tag(0), ast.Tag(1)])
}

pub fn tag_attribute_before_typeidx_test() {
  // Anti-swap: the attribute (0x00) is read BEFORE the typeidx. A tag `00 05` must
  // decode `Tag(5)` (attribute 0x00, typeidx 5) — NOT `Tag(0)` with a stray 5. Decode
  // does not range-check the typeidx, so a distinct value proves the read order.
  let assert Ok(m) =
    decode.decode(
      bytes(
        list.flatten([
          preamble,
          [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
          [0x0D, 0x03, 0x01, 0x00, 0x05],
        ]),
      ),
    )
  m.tags
  |> should.equal([ast.Tag(5)])
}

pub fn tag_section_before_global_ok_test() {
  // Section ORDER: the tag section (13) sits between memory (5) and global (6). A tag
  // section BEFORE the global section decodes Ok (proving `section_rank` ranks tag < global).
  let assert Ok(m) =
    decode.decode(
      bytes(
        list.flatten([
          preamble,
          [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
          [0x0D, 0x03, 0x01, 0x00, 0x00],
          [0x06, 0x06, 0x01, 0x7F, 0x00, 0x41, 0x00, 0x0B],
        ]),
      ),
    )
  m.tags
  |> should.equal([ast.Tag(0)])
}

pub fn tag_section_after_global_rejected_test() {
  // The SAME sections with the tag section AFTER the global section → SectionOrder
  // (tag's canonical rank 6 is not strictly greater than global's rank 7).
  decode.decode(
    bytes(
      list.flatten([
        preamble,
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
        [0x06, 0x06, 0x01, 0x7F, 0x00, 0x41, 0x00, 0x0B],
        [0x0D, 0x03, 0x01, 0x00, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.SectionOrder))
}

pub fn tag_section_porffor_bytes_test() {
  // The REAL Porffor 0.61.13 tag section `0d 03 01 00 03` (id 13, size 3, count 1,
  // attribute 0x00, typeidx 3 = `(func (param f64 i32))`) → `[Tag(3)]`. Verified byte-
  // for-byte from `npx porffor wasm`. Four functypes so typeidx 3 exists (decode does
  // not require it, but this mirrors the real module).
  let assert Ok(m) =
    decode.decode(
      bytes(
        list.flatten([
          preamble,
          [
            0x01, 0x0F, 0x04, 0x60, 0x00, 0x00, 0x60, 0x00, 0x00, 0x60, 0x00,
            0x00, 0x60, 0x02, 0x7C, 0x7F, 0x00,
          ],
          [0x0D, 0x03, 0x01, 0x00, 0x03],
        ]),
      ),
    )
  m.tags
  |> should.equal([ast.Tag(3)])
}

// ───────────────────────────── §D tag import / export descriptors ─────────────────────────────

pub fn import_tag_test() {
  // `(import "m" "t" (tag (type 0)))` — importdesc `04 00 00` (kind 0x04, attribute 0x00,
  // typeidx 0). Verified: `01 01 6d 01 74 04 00 00` = one import "m"/"t" desc tag.
  let assert Ok(m) =
    decode.decode(
      bytes(
        list.flatten([
          preamble,
          [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
          [0x02, 0x08, 0x01, 0x01, 0x6D, 0x01, 0x74, 0x04, 0x00, 0x00],
        ]),
      ),
    )
  m.imports
  |> should.equal([ast.Import("m", "t", ast.ImportTag(0))])
}

pub fn export_tag_test() {
  // `(export "e" (tag 0))` — export desc kind 0x04, tagidx 0. Section `07 05 01 01 65 04 00`.
  let assert Ok(m) =
    decode.decode(
      bytes(module_with_section([0x07, 0x05, 0x01, 0x01, 0x65, 0x04, 0x00])),
    )
  m.exports
  |> should.equal([ast.Export(name: "e", kind: ast.ExportTag, index: 0)])
}

pub fn export_tag_porffor_bytes_test() {
  // The REAL Porffor export byte pair `04 00` (kind 0x04 = tag, tagidx 0) — the tag
  // export named "0" (0x30). Verified from `npx porffor wasm`.
  let assert Ok(m) =
    decode.decode(
      bytes(module_with_section([0x07, 0x05, 0x01, 0x01, 0x30, 0x04, 0x00])),
    )
  m.exports
  |> should.equal([ast.Export(name: "0", kind: ast.ExportTag, index: 0)])
}

// ───────────────────────────── §E modern EH opcodes ─────────────────────────────

pub fn throw_test() {
  // `throw 0` = `08 00` (Porffor emits exactly this; shared with the modern surface).
  only_body(module_with_body([0x08, 0x00, 0x0B]))
  |> should.equal([ast.Throw(0), ast.End])
}

pub fn throw_multibyte_tagidx_test() {
  // `throw 128` = `08 80 01` — proves the tagidx is a LEB u32, not a single raw byte.
  only_body(module_with_body([0x08, 0x80, 0x01, 0x0B]))
  |> should.equal([ast.Throw(128), ast.End])
}

pub fn throw_ref_test() {
  // `throw_ref` = `0a` (no immediate).
  only_body(module_with_body([0x0A, 0x0B]))
  |> should.equal([ast.ThrowRef, ast.End])
}

pub fn try_table_four_catch_kinds_test() {
  // Ground truth (wasm-tools `try_table (result i32) (catch 0 1) (catch_ref 0 0)
  // (catch_all 1) (catch_all_ref 0)`): immediate `1f 7f 04 | 00 00 01 | 01 00 00 |
  // 02 01 | 03 00`. Body then `41 07` (i32.const 7) `0b` (close try_table) `0b` (func end).
  only_body(
    module_with_body([
      0x1F, 0x7F, 0x04, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x02, 0x01, 0x03,
      0x00, 0x41, 0x07, 0x0B, 0x0B,
    ]),
  )
  |> should.equal([
    ast.TryTable(ast.BlockVal(ast.I32), [
      ast.Catch(0, 1),
      ast.CatchRef(0, 0),
      ast.CatchAll(1),
      ast.CatchAllRef(0),
    ]),
    ast.I32Const(7),
    ast.End,
    ast.End,
  ])
}

pub fn catch_clause_anti_swap_test() {
  // Anti-swap: a `catch` clause with DISTINCT tag/label (`00 01 03` = kind 0, tag 1,
  // label 3) must decode `Catch(1, 3)` — NOT `Catch(3, 1)`. The tag is read before the
  // label; a swap mis-decodes both.
  only_body(module_with_body([0x1F, 0x40, 0x01, 0x00, 0x01, 0x03, 0x0B, 0x0B]))
  |> should.equal([
    ast.TryTable(ast.BlockEmpty, [ast.Catch(1, 3)]),
    ast.End,
    ast.End,
  ])
}

pub fn try_table_empty_catch_vec_test() {
  // An empty catch vector `1f 40 00` → `TryTable(BlockEmpty, [])`.
  only_body(module_with_body([0x1F, 0x40, 0x00, 0x0B, 0x0B]))
  |> should.equal([ast.TryTable(ast.BlockEmpty, []), ast.End, ast.End])
}

pub fn try_table_exnref_blocktype_test() {
  // `try_table (result exnref)` — blocktype 0x69 (s33 -23) decodes as BlockVal(ExnRef).
  only_body(module_with_body([0x1F, 0x69, 0x00, 0x0B, 0x0B]))
  |> should.equal([ast.TryTable(ast.BlockVal(ast.ExnRef), []), ast.End, ast.End])
}

pub fn try_table_is_block_opener_test() {
  // `try_table` is a block-opener: a nested `block…end` inside its body, then the
  // try_table's OWN `end`, must nest correctly (its body's `end` is not read as the
  // function terminator). Body `1f 40 00 | 02 40 0b | 0b | 0b`.
  only_body(module_with_body([0x1F, 0x40, 0x00, 0x02, 0x40, 0x0B, 0x0B, 0x0B]))
  |> should.equal([
    ast.TryTable(ast.BlockEmpty, []),
    ast.Block(ast.BlockEmpty),
    ast.End,
    ast.End,
    ast.End,
  ])
}

// ───────────────────────────── §F legacy EH opcodes (measured Porffor) ─────────────────────────────

pub fn legacy_try_catch_porffor_bytes_test() {
  // The REAL Porffor legacy encoding: `try` `06 40` (blocktype empty), `throw 0` `08 00`,
  // `catch 0` `07 00`, `end` `0b`. The whole `try …/catch 0 …/end` decodes with the
  // catch marker at the SAME depth as the body and the final `end` closing the try.
  only_body(module_with_body([0x06, 0x40, 0x08, 0x00, 0x07, 0x00, 0x0B, 0x0B]))
  |> should.equal([
    ast.TryLegacy(ast.BlockEmpty),
    ast.Throw(0),
    ast.LegacyCatch(0),
    ast.End,
    ast.End,
  ])
}

pub fn legacy_catch_all_test() {
  // Authored (Porffor omits it): `catch_all` = `19` — a legacy in-block handler marker.
  only_body(module_with_body([0x06, 0x40, 0x19, 0x0B, 0x0B]))
  |> should.equal([
    ast.TryLegacy(ast.BlockEmpty),
    ast.LegacyCatchAll,
    ast.End,
    ast.End,
  ])
}

pub fn legacy_delegate_closes_try_test() {
  // Authored: `delegate 1` = `18 01` TERMINATES its enclosing (inner) try — a block-
  // closer replacing that try's `end`. Outer try, inner try, delegate 1 (closes inner),
  // `0b` (closes outer), `0b` (func end).
  only_body(module_with_body([0x06, 0x40, 0x06, 0x40, 0x18, 0x01, 0x0B, 0x0B]))
  |> should.equal([
    ast.TryLegacy(ast.BlockEmpty),
    ast.TryLegacy(ast.BlockEmpty),
    ast.LegacyDelegate(1),
    ast.End,
    ast.End,
  ])
}

pub fn legacy_rethrow_test() {
  // Authored: `rethrow 0` = `09 00` — re-throw the exception caught by the 0-th enclosing
  // catch. Not a block-opener.
  only_body(module_with_body([0x06, 0x40, 0x09, 0x00, 0x0B, 0x0B]))
  |> should.equal([
    ast.TryLegacy(ast.BlockEmpty),
    ast.Rethrow(0),
    ast.End,
    ast.End,
  ])
}

// ───────────────────────── real Porffor end-to-end module ─────────────────────────

// The FULL 331-byte output of `npx porffor wasm trycatch.js` (Porffor 0.61.13) — a JS
// `try { … throw … } catch { … }` compiled to WASM. Carries the tag section `0d 03 01
// 00 03`, the tag export `04 00`, and the legacy `try`/`catch`/`throw` control. Embedded
// verbatim as the concrete proof that decode accepts REAL Porffor output.
const porffor_eh_module: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x1C, 0x04, 0x60, 0x00,
  0x02, 0x7C, 0x7F, 0x60, 0x06, 0x7C, 0x7F, 0x7C, 0x7F, 0x7C, 0x7F, 0x02, 0x7C,
  0x7F, 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F, 0x60, 0x02, 0x7C, 0x7F, 0x00, 0x03,
  0x04, 0x03, 0x00, 0x01, 0x02, 0x05, 0x03, 0x01, 0x00, 0x01, 0x0D, 0x03, 0x01,
  0x00, 0x03, 0x07, 0x0D, 0x03, 0x01, 0x24, 0x02, 0x00, 0x01, 0x30, 0x04, 0x00,
  0x01, 0x6D, 0x00, 0x00, 0x0A, 0x80, 0x02, 0x03, 0x29, 0x01, 0x01, 0x7F, 0x44,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x41, 0x00, 0x44, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x41, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x14, 0x40, 0x41, 0x01, 0x10, 0x01, 0x22, 0x00, 0x0B, 0xB0, 0x01,
  0x06, 0x01, 0x7C, 0x01, 0x7F, 0x01, 0x7C, 0x01, 0x7F, 0x01, 0x7C, 0x01, 0x7F,
  0x06, 0x40, 0x20, 0x04, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x64, 0xB8, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x62, 0x04,
  0x40, 0x20, 0x04, 0x20, 0x05, 0x08, 0x00, 0x1A, 0x0B, 0x44, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0xF0, 0x3F, 0x21, 0x06, 0x41, 0x01, 0x21, 0x07, 0x20, 0x00,
  0xFC, 0x03, 0x04, 0x40, 0x20, 0x06, 0xFC, 0x02, 0x20, 0x07, 0x10, 0x02, 0x45,
  0x04, 0x40, 0x20, 0x02, 0x20, 0x03, 0x0F, 0x0B, 0x0B, 0x20, 0x06, 0x20, 0x07,
  0x0F, 0x1A, 0x07, 0x00, 0x21, 0x09, 0x22, 0x08, 0x21, 0x0A, 0x20, 0x09, 0x21,
  0x0B, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x21, 0x06, 0x41,
  0x01, 0x21, 0x07, 0x20, 0x00, 0xFC, 0x03, 0x04, 0x40, 0x20, 0x06, 0xFC, 0x02,
  0x20, 0x07, 0x10, 0x02, 0x45, 0x04, 0x40, 0x20, 0x02, 0x20, 0x03, 0x0F, 0x0B,
  0x0B, 0x20, 0x06, 0x20, 0x07, 0x0F, 0x1A, 0x0B, 0x20, 0x00, 0xFC, 0x03, 0x04,
  0x40, 0x20, 0x02, 0x20, 0x03, 0x0F, 0x0B, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x41, 0x00, 0x0F, 0x0B, 0x22, 0x01, 0x01, 0x7F, 0x20, 0x01,
  0x21, 0x02, 0x20, 0x00, 0x41, 0x00, 0x47, 0x20, 0x02, 0x41, 0x05, 0x4A, 0x71,
  0x20, 0x02, 0x41, 0xC3, 0x00, 0x47, 0x71, 0x20, 0x02, 0x41, 0xC3, 0x01, 0x47,
  0x71, 0x0F, 0x0B, 0x0B, 0x01, 0x00,
]

pub fn porffor_eh_module_decodes_test() {
  // The real Porffor EH module decodes Ok, with the tag section (`[Tag(3)]`), the tag
  // export ("0" → ExportTag 0), and its legacy `try`/`catch`/`throw` nodes present in a
  // function body.
  let assert Ok(m) = decode.decode(bytes(porffor_eh_module))
  m.tags
  |> should.equal([ast.Tag(3)])
  list.contains(m.exports, ast.Export("0", ast.ExportTag, 0))
  |> should.equal(True)
  // Some function body carries the legacy try opener, a legacy catch marker, and a throw.
  let has = fn(pred) { list.any(m.funcs, fn(f) { list.any(f.body, pred) }) }
  has(fn(i) { i == ast.TryLegacy(ast.BlockEmpty) })
  |> should.equal(True)
  has(fn(i) { i == ast.LegacyCatch(0) })
  |> should.equal(True)
  has(fn(i) { i == ast.Throw(0) })
  |> should.equal(True)
}

// ───────────────────────── neutrality (tag-free byte-identical) ─────────────────────────

pub fn non_eh_module_has_empty_tags_test() {
  // A non-EH module (the `add` fixture) decodes with `tags == []` — the new field's
  // empty default, so the AST is structurally unchanged.
  let assert Ok(m) = decode.decode(bytes(add_fixture))
  m.tags
  |> should.equal([])
}

// ───────────────────────── §Verification 2: fail-closed fuzz ─────────────────────────

pub fn tag_bad_attribute_test() {
  // A tag with a non-0x00 attribute (`0d 03 01 01 00`) → BadTagAttribute.
  decode.decode(
    bytes(
      list.flatten([
        preamble,
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
        [0x0D, 0x03, 0x01, 0x01, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.BadTagAttribute))
}

pub fn imported_tag_bad_attribute_test() {
  // An imported tag with a non-0x00 attribute (`04 01 00`) → BadTagAttribute.
  decode.decode(
    bytes(
      list.flatten([
        preamble,
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
        [0x02, 0x08, 0x01, 0x01, 0x6D, 0x01, 0x74, 0x04, 0x01, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.BadTagAttribute))
}

pub fn catch_kind_out_of_range_test() {
  // A try_table catch clause with a kind byte >= 0x04 (`1f 40 01 04 …`) → BadCatchKind.
  decode.decode(
    bytes(module_with_body([0x1F, 0x40, 0x01, 0x04, 0x00, 0x0B, 0x0B])),
  )
  |> should.equal(Error(ast.BadCatchKind))
}

pub fn tag_section_truncated_test() {
  // A truncated tag section (attribute present, typeidx at EOF) → Truncated.
  decode.decode(
    bytes(
      list.flatten([
        preamble,
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
        [0x0D, 0x02, 0x01, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.Truncated))
}

pub fn catch_vector_truncated_test() {
  // A truncated catch vector (count says 2, one clause present) → Truncated.
  decode.decode(bytes(module_with_body([0x1F, 0x40, 0x02, 0x00, 0x00, 0x01])))
  |> should.equal(Error(ast.Truncated))
}

pub fn throw_tagidx_truncated_test() {
  // `throw` with the tagidx LEB truncated (opcode at EOF) → Truncated.
  decode.decode(bytes(module_with_body([0x08])))
  |> should.equal(Error(ast.Truncated))
}

pub fn throw_tagidx_too_long_test() {
  // `throw` with an over-wide tagidx LEB (6 bytes for a u32) → LebTooLong.
  decode.decode(
    bytes(module_with_body([0x08, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00, 0x0B])),
  )
  |> should.equal(Error(ast.LebTooLong))
}

pub fn try_table_bad_blocktype_test() {
  // A try_table whose blocktype byte is a bad negative s33 (`0x78` = -8) → BadBlockType.
  decode.decode(bytes(module_with_body([0x1F, 0x78, 0x00, 0x0B, 0x0B])))
  |> should.equal(Error(ast.BadBlockType))
}

pub fn exnref_tabletype_accepted_test() {
  // 0x69 in a tabletype element position is ACCEPTED as ExnRef (exn IS a heaptype).
  // Table section `04 04 01 69 00 01` (count 1, elem 0x69, limits min 1).
  let assert Ok(m) =
    decode.decode(
      bytes(module_with_section([0x04, 0x04, 0x01, 0x69, 0x00, 0x01])),
    )
  m.tables
  |> should.equal([ast.TableType(ast.ExnRef, ast.Limits(min: 1, max: None))])
}

pub fn v128_tabletype_still_rejected_test() {
  // But 0x7B (v128) in a tabletype element position is STILL BadHeapType (unchanged —
  // v128 is not a reftype; the exnref addition did not widen this).
  decode.decode(
    bytes(module_with_section([0x04, 0x04, 0x01, 0x7B, 0x00, 0x01])),
  )
  |> should.equal(Error(ast.BadHeapType))
}

pub fn legacy_delegate_depth_zero_rejected_test() {
  // A legacy `delegate 0` with no open try (block depth 0) is mis-nested → BadDelegate
  // (a dedicated error, never a negative-depth loop, never a crash).
  decode.decode(bytes(module_with_body([0x18, 0x00, 0x0B])))
  |> should.equal(Error(ast.BadDelegate))
}

// A packed fixture exercising the whole EH surface (modern + legacy) in one body, so
// the mutation/truncation sweeps cover every EH sub-decoder. `try_table` (empty, no
// catches) opens; a legacy `try`/`catch`/`throw`/`throw_ref`/`rethrow`/`catch_all`
// interleave; two ends close the legacy try and the try_table; a final end terminates.
fn eh_fixture() -> List(Int) {
  module_with_body([
    0x1F, 0x40, 0x00, 0x08, 0x00, 0x0A, 0x06, 0x40, 0x09, 0x00, 0x19, 0x07, 0x00,
    0x0B, 0x0B, 0x0B,
  ])
}

pub fn eh_fixture_decodes_test() {
  // The packed EH fixture decodes cleanly to the expected instructions (so the fuzz
  // sweeps below are meaningful).
  only_body(eh_fixture())
  |> should.equal([
    ast.TryTable(ast.BlockEmpty, []),
    ast.Throw(0),
    ast.ThrowRef,
    ast.TryLegacy(ast.BlockEmpty),
    ast.Rethrow(0),
    ast.LegacyCatchAll,
    ast.LegacyCatch(0),
    ast.End,
    ast.End,
    ast.End,
  ])
}

pub fn fuzz_eh_fixture_mutations_test() {
  // Every single-byte mutation of the EH fixture stays TOTAL (a Result, never a panic) —
  // the fail-closed property over the whole EH surface (D4/H6).
  sweep_single_byte_mutations(eh_fixture())
  |> should.equal(True)
}

pub fn fuzz_eh_fixture_truncation_test() {
  // Every prefix of the EH fixture decodes to a Result; the full fixture is Ok and every
  // shorter prefix is an Error (never a crash / never a negative-depth loop).
  let fixture = eh_fixture()
  let full = decode.decode(bytes(fixture))
  let len = list.length(fixture)
  list.all(int_range(0, len), fn(n) {
    let r = decode.decode(bytes(list.take(fixture, n)))
    case n == len {
      True -> r == full
      False -> is_total(r) && r != full
    }
  })
  |> should.equal(True)
}

pub fn fuzz_porffor_eh_module_mutations_test() {
  // Every single-byte mutation of the REAL Porffor EH module stays TOTAL — decode is
  // fail-closed over hostile mutations of genuine legacy-EH output.
  sweep_single_byte_mutations(porffor_eh_module)
  |> should.equal(True)
}

// ───────────────────── §Verification 3: the EH opcode-map audit ─────────────────────

pub fn eh_opcode_map_audit_test() {
  // Derived from the spec/measured EH opcode tables, NOT the implementation: each of the
  // eight assigned EH opcodes decodes Ok to its §E/§F node with a minimal well-formed
  // immediate. A mis-transcribed opcode fails this. (delegate 0x18 is exercised inside a
  // try so it is not depth-0-rejected.)
  let cases = [
    #([0x06, 0x40, 0x0B, 0x0B], ast.TryLegacy(ast.BlockEmpty)),
    #([0x07, 0x00, 0x0B], ast.LegacyCatch(0)),
    #([0x08, 0x00, 0x0B], ast.Throw(0)),
    #([0x09, 0x00, 0x0B], ast.Rethrow(0)),
    #([0x0A, 0x0B], ast.ThrowRef),
    #([0x19, 0x0B], ast.LegacyCatchAll),
    #([0x1F, 0x40, 0x00, 0x0B, 0x0B], ast.TryTable(ast.BlockEmpty, [])),
  ]
  let bad =
    list.filter(cases, fn(c) {
      let #(body, expected) = c
      case decode.decode(bytes(module_with_body(body))) {
        Ok(m) ->
          case m.funcs {
            [f] -> !list.contains(f.body, expected)
            _ -> True
          }
        Error(_) -> True
      }
    })
  bad
  |> should.equal([])
  // `delegate 1` inside a try must decode to LegacyDelegate(1) (block-closer path).
  only_body(module_with_body([0x06, 0x40, 0x18, 0x01, 0x0B]))
  |> should.equal([
    ast.TryLegacy(ast.BlockEmpty),
    ast.LegacyDelegate(1),
    ast.End,
  ])
}

pub fn catch_kind_dispatch_audit_test() {
  // The four catch-clause kinds 0x00..0x03 each decode Ok to the right clause shape,
  // while 0x04 → BadCatchKind. Derived from the spec's catch grammar.
  let kinds = [
    #([0x00, 0x02, 0x03], ast.Catch(2, 3)),
    #([0x01, 0x02, 0x03], ast.CatchRef(2, 3)),
    #([0x02, 0x03], ast.CatchAll(3)),
    #([0x03, 0x03], ast.CatchAllRef(3)),
  ]
  let bad =
    list.filter(kinds, fn(c) {
      let #(clause, expected) = c
      let body = list.flatten([[0x1F, 0x40, 0x01], clause, [0x0B, 0x0B]])
      case decode.decode(bytes(module_with_body(body))) {
        Ok(m) ->
          case m.funcs {
            [f] ->
              f.body
              != [ast.TryTable(ast.BlockEmpty, [expected]), ast.End, ast.End]
            _ -> True
          }
        Error(_) -> True
      }
    })
  bad
  |> should.equal([])
  // kind 0x04 is out of range → BadCatchKind.
  decode.decode(
    bytes(module_with_body([0x1F, 0x40, 0x01, 0x04, 0x00, 0x0B, 0x0B])),
  )
  |> should.equal(Error(ast.BadCatchKind))
}
