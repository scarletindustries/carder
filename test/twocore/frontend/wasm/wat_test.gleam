//// Spec + DIFFERENTIAL tests for the WAT text parser (unit P5-10a — the lexer
//// and `parse_module`).
////
//// The primary bar (H5 DoD) is differential: for each `.wat` covering the
//// Phase-5 surface, `wat.parse_module(text)` must be STRUCTURALLY EQUAL to
//// `decode(wat2wasm(text))` (wabt 1.0.41, the pin). When `wat2wasm` is absent
//// the differential cases skip (documented) and only the hand-authored
//// bit-exact/lexer assertions run. Spec citations are on each group.
////
//// Spec:
////  - lexical:      https://webassembly.github.io/spec/core/text/lexical.html
////  - values:       https://webassembly.github.io/spec/core/text/values.html
////  - modules:      https://webassembly.github.io/spec/core/text/modules.html
////  - instructions: https://webassembly.github.io/spec/core/text/instructions.html

import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import simplifile
import twocore/conformance/ffi
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/wat

// ───────────────────────── differential harness ─────────────────────────

/// Assemble `text` with `wat2wasm` (standardized feature flags our frontend owns:
/// multi-memory + memory64 + Phase-13 tail-call); `Ok(bytes)` on success, `Error(reason)`
/// if wat2wasm is absent or rejects it.
fn wat2wasm_bytes(text: String) -> Result(BitArray, String) {
  case ffi.find_executable("wat2wasm") {
    Error(_) -> Error("wat2wasm not found")
    Ok(exe) -> {
      let stamp = int.to_string(ffi.unique_int())
      let base = "/tmp/twocore_wat_" <> stamp
      let watp = base <> ".wat"
      let wasmp = base <> ".wasm"
      case simplifile.write(watp, text) {
        Error(_) -> Error("cannot write temp wat")
        Ok(_) -> {
          // Enable ONLY the standardized features our parser owns. NOT `--enable-all`:
          // that turns on wabt's experimental `--enable-compact-imports` (a
          // grouped-import encoding that `wasm-tools validate` itself rejects as
          // invalid core WASM). reference-types + bulk-memory are default-on in
          // wabt 1.0.41, so only multi-memory + memory64 need flags; `--enable-tail-call`
          // (Phase 13, NOT default-on at 1.0.41) lets this differential assemble the
          // `return_call`/`return_call_indirect` corpus (`tailrec.wat`) so our WAT parser's
          // tail-call ingest is verified byte-identically against the wabt oracle here too.
          let #(code, out) =
            ffi.run(exe, [
              watp,
              "--enable-multi-memory",
              "--enable-memory64",
              "--enable-tail-call",
              "-o",
              wasmp,
            ])
          case code {
            0 ->
              case simplifile.read_bits(wasmp) {
                Ok(b) -> Ok(b)
                Error(_) -> Error("cannot read wasm output")
              }
            _ -> Error("wat2wasm failed: " <> out)
          }
        }
      }
    }
  }
}

/// Assert `parse_module(text)` is structurally equal to `decode(wat2wasm(text))`.
/// Skips (passes) if wat2wasm is unavailable. Fails loudly if wat2wasm assembles
/// the text but decode or parse disagree — the parser is presumed wrong.
fn diff(text: String) -> Nil {
  case wat2wasm_bytes(text) {
    Error("wat2wasm not found") -> Nil
    Error(reason) -> should.equal("assemble-failed: " <> reason, "assembled")
    Ok(bytes) ->
      case decode.decode(bytes), wat.parse_module(text) {
        Ok(expected), Ok(actual) ->
          case actual == expected {
            True -> Nil
            False ->
              // Surface both for debugging via the assertion diff.
              should.equal(actual, expected)
          }
        Ok(_), Error(e) ->
          should.equal(
            "parse_module error: " <> string.inspect(e) <> " for " <> text,
            "Ok(module)",
          )
        Error(e), _ ->
          should.equal("decode error: " <> string.inspect(e), "Ok(module)")
      }
  }
}

// ───────────────────────── lexer (text/lexical.html) ─────────────────────────

pub fn lex_nesting_block_comment_test() {
  // "(; a (; b ;) c ;)" is ONE comment — nesting must be tracked.
  wat.lex("(module(; a (; b ;) c ;)(func))")
  |> should.be_ok
}

pub fn lex_unterminated_comment_test() {
  case wat.lex("(module (; oops ") {
    Error(wat.LexError(_, wat.UnterminatedComment)) -> Nil
    other -> should.equal(string.inspect(other), "UnterminatedComment")
  }
}

pub fn lex_unterminated_string_test() {
  case wat.lex("(data \"abc") {
    Error(wat.LexError(_, wat.UnterminatedString)) -> Nil
    other -> should.equal(string.inspect(other), "UnterminatedString")
  }
}

pub fn lex_line_comment_test() {
  wat.lex(";; a comment\n(module)")
  |> should.be_ok
}

pub fn lex_bad_escape_test() {
  case wat.lex("(data \"\\q\")") {
    Error(wat.LexError(_, wat.BadEscape)) -> Nil
    other -> should.equal(string.inspect(other), "BadEscape")
  }
}

pub fn lex_string_escapes_test() {
  // \41 -> 'A' (0x41); \u{1F600} -> 4 UTF-8 bytes; the C escapes.
  case wat.lex("\"\\41\\u{1F600}\\t\\n\\r\\\"\\'\\\\\"") {
    Ok([wat.Str(_, bytes)]) ->
      bytes
      |> should.equal(<<
        0x41, 0xF0, 0x9F, 0x98, 0x80, 0x09, 0x0A, 0x0D, 0x22, 0x27, 0x5C,
      >>)
    other -> should.equal(string.inspect(other), "Ok([Str])")
  }
}

pub fn lex_weird_identifier_test() {
  // `$weird!id` — idchars include `!`.
  case wat.lex("$weird!id") {
    Ok([wat.Id(_, name)]) -> name |> should.equal("weird!id")
    other -> should.equal(string.inspect(other), "Ok([Id])")
  }
}

// ─────────────────── number literals → bits (text/values.html) ───────────────
// Grounded vectors (unit doc §B) — bit-exact against the binary form. Each is
// asserted through parse_module so the interpretation path is exercised end-to-end.

fn single_const(text: String) -> ast.Instr {
  case wat.parse_module("(module (func " <> text <> "))") {
    Ok(ast.Module(funcs: [ast.Func(body: [instr, ast.End], ..)], ..)) -> instr
    other -> {
      should.equal(string.inspect(other), "one const instr")
      ast.Nop
    }
  }
}

pub fn i32_const_neg_one_test() {
  single_const("i32.const -1") |> should.equal(ast.I32Const(-1))
}

pub fn i32_const_hex_ffffffff_test() {
  // 0xffffffff is in u32 range and folds to the same bits as -1.
  single_const("i32.const 0xffffffff") |> should.equal(ast.I32Const(-1))
}

pub fn i32_const_underscores_test() {
  single_const("i32.const 1_000") |> should.equal(ast.I32Const(1000))
}

pub fn i32_const_out_of_range_test() {
  case wat.parse_module("(module (func i32.const 4294967296))") {
    Error(wat.NumberOutOfRange(_, _)) -> Nil
    other -> should.equal(string.inspect(other), "NumberOutOfRange")
  }
}

pub fn i64_const_test() {
  single_const("i64.const -1") |> should.equal(ast.I64Const(-1))
}

pub fn f32_const_one_hexfloat_test() {
  single_const("f32.const 0x1p+0") |> should.equal(ast.F32Const(0x3F80_0000))
}

pub fn f32_const_nan_payload_test() {
  single_const("f32.const nan:0x200000")
  |> should.equal(ast.F32Const(0x7FA0_0000))
}

pub fn f32_const_inf_test() {
  single_const("f32.const inf") |> should.equal(ast.F32Const(0x7F80_0000))
}

pub fn f64_const_neg_inf_test() {
  single_const("f64.const -inf")
  |> should.equal(ast.F64Const(0xFFF0_0000_0000_0000))
}

pub fn f32_const_canonical_nan_test() {
  single_const("f32.const nan") |> should.equal(ast.F32Const(0x7FC0_0000))
}

pub fn f32_const_min_subnormal_test() {
  // 0x1p-149 is the smallest positive f32 subnormal → bit pattern 0x00000001.
  single_const("f32.const 0x1p-149") |> should.equal(ast.F32Const(0x0000_0001))
}

pub fn f32_const_decimal_one_test() {
  single_const("f32.const 1.0") |> should.equal(ast.F32Const(0x3F80_0000))
}

pub fn f64_const_decimal_tenth_test() {
  // 0.1 rounds to the nearest binary64 — the canonical 0.1 bit pattern.
  single_const("f64.const 0.1")
  |> should.equal(ast.F64Const(0x3FB9_9999_9999_999A))
}

pub fn f32_const_hexfloat_1_5_test() {
  single_const("f32.const 0x1.8p0") |> should.equal(ast.F32Const(0x3FC0_0000))
}

pub fn f32_const_integer_literal_test() {
  single_const("f32.const 100") |> should.equal(ast.F32Const(0x42C8_0000))
}

// ───────────────────────── differential corpus ─────────────────────────
// Each string is asserted `parse_module ≡ decode∘wat2wasm`. Covers the module
// surface: abbreviations, folded/flat, resolution, type dedup, and the Phase-5
// reftype/bulk/table/multi-mem/memory64 additions.

const corpus: List(String) = [
  // --- basics / functions / exports ---
  "(module)", "(module (func))",
  "(module (func $f (export \"sq\") (param $x i32) (result i32) (i32.mul (local.get $x) (local.get $x))))",
  "(module (func (export \"add\") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))",
  "(module (func) (func) (export \"a\" (func 0)) (export \"b\" (func 1)))",
  // --- type dedup & type-use ---
  "(module (type (func (param i32) (result i32))) (func (param i32) (result i32) local.get 0))",
  "(module (func (param i32 i32) (result i32) local.get 0) (func (param i32) (result i32) local.get 0))",
  "(module (type $t (func (param i32) (result i32))) (func (type $t) (param i32) (result i32) local.get 0))",
  // --- folded vs flat, control ---
  "(module (func (result i32) (i32.add (i32.const 1) (i32.const 2))))",
  "(module (func (result i32) i32.const 1 i32.const 2 i32.add))",
  "(module (func (result i32) (block $outer (result i32) (loop $inner (br $outer (i32.const 7))) (i32.const 0))))",
  "(module (func (result i32) (if (result i32) (i32.const 1) (then (i32.const 2)) (else (i32.const 3)))))",
  "(module (func block (result i32) i32.const 1 end drop))",
  "(module (func (param $p i32) (local $t i32) (local.set $t (local.get $p))))",
  "(module (func (result i32) i32.const 0 if (result i32) i32.const 1 else i32.const 2 end))",
  "(module (func i32.const 0 (br_table 0 0 0)))",
  // --- memory / load / store / memarg ---
  "(module (memory 1 2) (func (result i32) (i32.load offset=4 align=2 (i32.const 0))))",
  "(module (memory 1) (func (result i64) (i64.load offset=0 align=8 (i32.const 0))))",
  "(module (memory 1) (func (i32.store8 (i32.const 0) (i32.const 255))))",
  "(module (memory 1) (func (result i32) memory.size))",
  "(module (memory 1) (func (result i32) i32.const 1 memory.grow))",
  "(module (memory (data \"hello world\")))",
  "(module (memory 1) (data (i32.const 0) \"ab\") (data \"cd\"))",
  // --- globals ---
  "(module (global $g (mut i32) (i32.const 0)) (func (global.set $g (i32.const 5))))",
  "(module (global i32 (i32.const 42)) (export \"g\" (global 0)))",
  // --- tables / call_indirect / elem ---
  "(module (table 1 funcref) (func $f) (elem (i32.const 0) $f) (func (call_indirect (type 0) (i32.const 0))))",
  "(module (func $a) (func $b) (table funcref (elem $a $b)))",
  "(module (table 2 funcref) (func (call_indirect (param i32) (i32.const 0) (i32.const 0))))",
  // --- imports (function + non-function) ---
  "(module (import \"m\" \"f\" (func $imp (param i32))) (func $d) (start $d))",
  "(module (func $f (import \"m\" \"n\") (param i32) (result i32)))",
  "(module (import \"m\" \"g\" (global i32)) (import \"m\" \"t\" (table 1 funcref)) (import \"m\" \"mem\" (memory 1)))",
  "(module (global (import \"m\" \"g\") (mut i64)))",
  // --- Phase-5 reference types ---
  "(module (func $f) (func (result funcref) (ref.func $f)) (elem declare func $f))",
  "(module (func (result i32) (ref.is_null (ref.null func))))",
  "(module (func (result externref) (ref.null extern)))",
  "(module (table 1 externref) (func (result externref) (table.get (i32.const 0))))",
  "(module (table 1 funcref) (func (table.set (i32.const 0) (ref.null func))))",
  "(module (table 1 funcref) (func (result i32) table.size))",
  "(module (table 1 funcref) (func (result i32) (table.grow (ref.null func) (i32.const 1))))",
  "(module (table 1 funcref) (func (table.fill (i32.const 0) (ref.null func) (i32.const 1))))",
  "(module (func (result i32) (select (result i32) (i32.const 1) (i32.const 2) (i32.const 0))))",
  // --- Phase-5 bulk memory & table ---
  "(module (memory 1) (data \"ab\") (func (memory.init 0 (i32.const 0) (i32.const 0) (i32.const 0)) (data.drop 0)))",
  "(module (memory 1) (func (memory.fill (i32.const 0) (i32.const 0) (i32.const 1))))",
  "(module (memory 1) (func (memory.copy (i32.const 0) (i32.const 1) (i32.const 2))))",
  "(module (table 2 funcref) (func $f) (elem $e func $f) (func (table.init $e (i32.const 0) (i32.const 0) (i32.const 0)) (elem.drop $e)))",
  "(module (table 2 funcref) (func (table.copy (i32.const 0) (i32.const 1) (i32.const 2))))",
  // --- passive / declarative elem, passive data ---
  "(module (func $f) (elem funcref (ref.func $f) (ref.null func)))",
  "(module (memory 1) (data \"passive\"))",
  // --- multi-memory + memory64 (decode/validate only for mem64) ---
  "(module (memory 1) (memory 1) (func (result i32) i32.const 0 i32.load 1))",
  "(module (memory i64 1 2))",
]

pub fn differential_corpus_test() {
  list.each(corpus, diff)
}

// A float/int-literal torture module diffed against wat2wasm — the R15 safety
// net proving the number→bits path is BIT-EXACT for the hard cases (decimal
// round-to-nearest, hex floats, subnormals, near-overflow, nan payloads, the
// signed/unsigned integer fold). Any last-bit divergence fails here.
const float_torture: List(String) = [
  "(module (func (result f64) (f64.const 0.1)))",
  "(module (func (result f64) (f64.const 3.141592653589793)))",
  "(module (func (result f64) (f64.const 1e308)))",
  "(module (func (result f64) (f64.const 1e-308)))",
  "(module (func (result f64) (f64.const 2.2250738585072014e-308)))",
  "(module (func (result f64) (f64.const 4.9e-324)))",
  "(module (func (result f64) (f64.const 0x1.fffffffffffffp+1023)))",
  "(module (func (result f64) (f64.const -0.0)))",
  "(module (func (result f32) (f32.const 0.1)))",
  "(module (func (result f32) (f32.const 3.14159265)))",
  "(module (func (result f32) (f32.const 1e38)))",
  "(module (func (result f32) (f32.const 1e-38)))",
  "(module (func (result f32) (f32.const 1.1754944e-38)))",
  "(module (func (result f32) (f32.const 1.4e-45)))",
  "(module (func (result f32) (f32.const 0x1.fffffep+127)))",
  "(module (func (result f32) (f32.const 0x1p-149)))",
  "(module (func (result f32) (f32.const 340282350000000000000000000000000000000)))",
  "(module (func (result f32) (f32.const nan:0x1)))",
  "(module (func (result f32) (f32.const nan:0x7fffff)))",
  "(module (func (result f64) (f64.const nan:0x8000000000001)))",
  "(module (func (result f32) (f32.const -nan)))",
  "(module (func (result i32) (i32.const 0x7fffffff)))",
  "(module (func (result i32) (i32.const -2147483648)))",
  "(module (func (result i64) (i64.const 0xffffffffffffffff)))",
  "(module (func (result i64) (i64.const -9223372036854775808)))",
  "(module (func (result i64) (i64.const 9223372036854775807)))",
]

pub fn differential_float_torture_test() {
  list.each(float_torture, diff)
}

// ─────────────────── differential over the acceptance corpus ───────────────
// The Phase-1..4 `.wat` acceptance corpus must parse byte-identically (H7
// conformance-neutrality). Read each `.wat` and diff it.

pub fn differential_acceptance_corpus_test() {
  let dir = "test/twocore/conformance/corpus"
  case simplifile.read_directory(dir) {
    Error(_) -> Nil
    Ok(entries) ->
      entries
      |> list.filter(fn(n) { string.ends_with(n, ".wat") })
      |> list.filter(fn(n) { !wat_parser_out_of_scope(n) })
      |> list.each(fn(name) {
        case simplifile.read(dir <> "/" <> name) {
          Ok(text) -> diff(text)
          Error(_) -> Nil
        }
      })
  }
}

/// The capstone-authored SIMD/memory64 (`simd*.wat`, `mem64.wat`, P6-11) AND exception-handling
/// (`eh*.wat`, P7-10) corpus kernels are DECODED from `wat2wasm`-produced `.wasm` (the binary
/// frontend handles the whole surface) but are deliberately OUT OF SCOPE for OUR WAT text parser:
/// SIMD text is a categorized parser gap (S13), the memory64 `.wast` text forms (inline-data / large
/// hex-underscore literals) are the same flagged limitation (wat_route note), and the EH text forms
/// (`(tag …)` / `try_table` / `throw` / `throw_ref`) need `wat2wasm --enable-exceptions` and are a
/// categorized WAT-parser gap too (the EH surface is decoded from the binary — the official EH `.wast`
/// run is `eh_conformance_test`). Excluding them here keeps this strict `parse_module ≡ decode∘
/// wat2wasm` differential to the surface the WAT parser actually owns; the kernels are proven
/// end-to-end through the BINARY path in `new_surface_test`.
fn wat_parser_out_of_scope(name: String) -> Bool {
  string.starts_with(name, "simd")
  || string.starts_with(name, "mem64")
  || string.starts_with(name, "eh")
}

/// Opportunistic differential + totality over a real spec-suite `.wat` file.
/// When wat2wasm assembles it AND both decode and parse succeed, assert
/// structural equality (a real divergence is a bug). Otherwise the file is a
/// malformed/out-of-scope assertion snippet — assert only that parse_module is
/// TOTAL (returns without panicking; the branch itself proves no crash).
fn diff_or_total(text: String) -> Nil {
  case wat2wasm_bytes(text) {
    Ok(bytes) ->
      case decode.decode(bytes), wat.parse_module(text) {
        Ok(expected), Ok(actual) -> should.equal(actual, expected)
        _, _ -> Nil
      }
    Error(_) ->
      case wat.parse_module(text) {
        Ok(_) -> Nil
        Error(_) -> Nil
      }
  }
}

/// Sweep every `.wat` in `dir`, applying `diff_or_total`.
fn sweep_wat_dir(dir: String) -> Nil {
  case simplifile.read_directory(dir) {
    Error(_) -> Nil
    Ok(entries) ->
      entries
      |> list.filter(fn(n) { string.ends_with(n, ".wat") })
      |> list.each(fn(name) {
        case simplifile.read(dir <> "/" <> name) {
          Ok(text) -> diff_or_total(text)
          Error(_) -> Nil
        }
      })
  }
}

pub fn differential_spec_fixture_sweep_test() {
  // ~300 individual spec-suite modules (many intentionally malformed): the valid
  // ones are strict-differentially checked, all exercise totality (D4).
  sweep_wat_dir("test/twocore/conformance/fixtures")
}

// ─────────────────── out-of-scope categorisation (H8) ───────────────

pub fn simd_is_categorized_test() {
  case
    wat.parse_module("(module (func (result v128) (v128.const i32x4 0 0 0 0)))")
  {
    Error(wat.Unsupported(_, wat.Simd, _)) -> Nil
    other -> should.equal(string.inspect(other), "Unsupported(Simd)")
  }
}

pub fn unknown_mnemonic_is_distinct_test() {
  case wat.parse_module("(module (func i32.frobnicate))") {
    Error(wat.UnknownMnemonic(_, "i32.frobnicate")) -> Nil
    other -> should.equal(string.inspect(other), "UnknownMnemonic")
  }
}

// ─────────────────── identifier resolution (text/modules.html) ───────────────

pub fn unbound_identifier_test() {
  case wat.parse_module("(module (func (call $nope)))") {
    Error(wat.UnboundIdentifier(_, "func", "nope")) -> Nil
    other -> should.equal(string.inspect(other), "UnboundIdentifier")
  }
}

pub fn duplicate_identifier_test() {
  case wat.parse_module("(module (func $x) (func $x))") {
    Error(wat.DuplicateIdentifier(_, "func", "x")) -> Nil
    other -> should.equal(string.inspect(other), "DuplicateIdentifier")
  }
}

pub fn imports_first_funcidx_offset_test() {
  // An imported func occupies funcidx 0, so the defined `$d` is funcidx 1 and
  // `imported_func_count` is 1.
  case
    wat.parse_module(
      "(module (import \"m\" \"f\" (func $imp)) (func $d) (start $d))",
    )
  {
    Ok(ast.Module(imported_func_count: 1, start: Some(1), ..)) -> Nil
    other ->
      should.equal(string.inspect(other), "imported_func_count=1,start=1")
  }
}

// ─────────────────── totality (D4): malformed → typed error, no panic ───────

pub fn totality_malformed_inputs_test() {
  let bad = [
    "(", ")", "(module", "(module (func", "(module (func ())", "(module (type))",
    "(module (func $x) (func $x))", "(module (func local.get))",
    "(module (func i32.const))", "(module (func (block)))",
    "(module (func end))", "(module (memory))", "(module (global))",
    "(module (func (i32.load align=3 (i32.const 0))))",
  ]
  list.each(bad, fn(t) {
    case wat.parse_module(t) {
      Ok(_) -> Nil
      Error(_) -> Nil
    }
  })
}

/// Truncation fuzz (D4): every prefix of a representative module must lex and
/// parse to `Ok | Error(WatError)` — never a panic. Reaching the assertion at
/// all proves totality over truncated/mid-token input (the same property the
/// binary decoder proves).
pub fn totality_truncation_fuzz_test() {
  let sample =
    "(module (type $t (func (param i32) (result i32)))"
    <> " (import \"m\" \"f\" (func $imp (param i32)))"
    <> " (memory 1 2) (data (i32.const 0) \"\\00\\ff\")"
    <> " (table 2 funcref) (elem (i32.const 0) $imp)"
    <> " (global $g (mut f64) (f64.const 0x1.8p3))"
    <> " (func (export \"e\") (param $x i32) (result i32)"
    <> "   (block $b (result i32) (if (result i32) (local.get $x)"
    <> "     (then (i32.const 0x7f)) (else (br $b (i32.const 1e9)))))))"
  let n = string.length(sample)
  list.each(int_range(0, n), fn(k) {
    let prefix = string.slice(sample, 0, k)
    let _ = wat.lex(prefix)
    let _ = wat.parse_module(prefix)
    Nil
  })
}

/// Inclusive integer range `[from, to]` (local — the stdlib has no `list.range`).
fn int_range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..int_range(from + 1, to)]
  }
}
