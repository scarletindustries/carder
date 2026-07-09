//// The WebAssembly **text-format** frontend, pass 1: the lexer and
//// `parse_module` (`«WAT-API-CORE»`, Phase-5 unit P5-10a).
////
//// This module sits BESIDE the binary decoder (`frontend/wasm/decode`) and
//// produces the **same** `frontend/wasm/ast` model (`«WASM-AST3»`), so the
//// unchanged `validate`/`lower` stages serve text and binary alike. Its
//// correctness bar is DIFFERENTIAL: for a well-formed Phase-5-scope `.wat`,
//// `parse_module(text)` yields a `Module` **structurally equal to
//// `decode(wat2wasm(text))`** (proven in the test suite against wabt 1.0.41).
////
//// THREAT MODEL: the input is untrusted text. Every function here is total —
//// any malformation returns a typed `WatError` (never a panic / `let assert` /
//// `todo` reachable from input). The parser is the **malformed** boundary only;
//// it does NOT typecheck (that is `validate`'s job — unit 04), so a well-formed
//// but ill-typed text still parses and is rejected downstream (this split is
//// what routes `assert_malformed` (text) here and `assert_invalid` (text)
//// through here into `validate`).
////
//// SCOPE (pass 1): the lexer (§A), number/float literals → raw bits (§B, the D5
//// discipline — hex-float + `nan:0x` payloads are bit-exact, decimal floats are
//// exact via a big-integer round-to-nearest-ties-even routine), and
//// `parse_module` over the full Phase-5 module surface (folded + flat
//// instructions, the standard abbreviations, `$id` resolution across the index
//// spaces, and `(type)` dedup). The `.wast` script layer (`parse_script`) is
//// pass 2 (unit P5-10b) and is intentionally NOT in this file.
////
//// OUT OF SCOPE (categorized, never silently mis-parsed): SIMD text
//// (`v128`/`i8x16.*` …) and GC text (`(ref $t)`, `struct`/`array` …) return a
//// `WatError.Unsupported(category, …)` rather than a wrong AST.
////
//// Spec references (WebAssembly core, text format):
////  - lexical:      https://webassembly.github.io/spec/core/text/lexical.html
////  - values:       https://webassembly.github.io/spec/core/text/values.html
////  - modules:      https://webassembly.github.io/spec/core/text/modules.html
////  - instructions: https://webassembly.github.io/spec/core/text/instructions.html

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import twocore/frontend/wasm/ast

// ===========================================================================
// Public types
// ===========================================================================

/// A 1-based source position (`line`/`col` count Unicode scalar values). Used
/// only for error messages; it does not affect the produced AST.
pub type Pos {
  Pos(line: Int, col: Int)
}

/// A lexical token (spec `text/lexical.html`). `Keyword` covers every bare atom
/// (dotted mnemonics like `i32.load8_u`, type keywords like `funcref`, field
/// heads like `func`, and the `offset=`/`align=` memarg atoms — `=` is an
/// idchar). Number lexemes are kept RAW (interpreted by the parser at the point
/// of use, since the same lexeme is different bits at different widths). `Str`
/// holds the DECODED bytes. `Reserved` is an idchar run that is neither a valid
/// number nor a keyword (it lets a value-position malformation be reported at
/// the parser rather than the lexer).
pub type Token {
  LParen(pos: Pos)
  RParen(pos: Pos)
  Keyword(pos: Pos, text: String)
  Id(pos: Pos, name: String)
  Num(pos: Pos, lexeme: String)
  Str(pos: Pos, bytes: BitArray)
  Reserved(pos: Pos, text: String)
}

/// The specific lexical failure inside a `LexError`.
pub type LexErrorKind {
  UnterminatedString
  UnterminatedComment
  BadEscape
  StrayChar
}

/// The category of an out-of-scope (deliberately deferred) construct. DISTINCT
/// from `UnknownMnemonic` (a genuine malformation): these are counted as
/// categorized skips by the conformance harness, never as parse failures of a
/// valid module.
pub type Category {
  Simd
  Gc
  Thread
}

/// Every reason WAT text is rejected. Untrusted input maps to EXACTLY one of
/// these — never a panic (D4). Each carries a `Pos` where sensible.
pub type WatError {
  LexError(pos: Pos, kind: LexErrorKind)
  UnexpectedToken(pos: Pos, want: String, got: String)
  UnexpectedEof(want: String)
  UnknownMnemonic(pos: Pos, keyword: String)
  UnboundIdentifier(pos: Pos, space: String, name: String)
  DuplicateIdentifier(pos: Pos, space: String, name: String)
  MismatchedLabel(pos: Pos, open: Option(String), close: Option(String))
  InlineTypeMismatch(pos: Pos)
  NumberOutOfRange(pos: Pos, lexeme: String)
  BadNanPayload(pos: Pos, lexeme: String)
  BadAlign(pos: Pos, value: Int)
  Unsupported(pos: Pos, category: Category, detail: String)
}

// ===========================================================================
// The `.wast` script command layer (pass 2, unit P5-10b) — public types
// ===========================================================================
//
// Spec: the reference interpreter's SCRIPT grammar (WebAssembly/spec
// `interpreter/README.md`, `test/core/`) — the command language `wast2json`
// consumes and the conformance harness drives. `parse_script` produces this
// SRC-side `Script`; unit 11's test-side adapter (`wat_fixture.gleam`) maps it
// onto `fixture.Command`/`fixture.Action`/`fixture.SpecValue` (src cannot emit
// test-side types). The two shapes are deliberately parallel so that adapter is
// a clean, total map.

/// A parsed `.wast` script: its commands in source order (`«WAT-API»`).
pub type Script =
  List(Command)

/// One `.wast` script command.
///
/// - `WatModule(id, module)`: a `(module …)` definition — `text`/`binary`/`quote`
///   (see `ModuleDef`). `id` is the optional `$name` (WITHOUT the leading `$`)
///   later actions/`register` target it by.
/// - `Register(name, module)`: `(register "name" $mod?)` — republishes `module`'s
///   (or the current module's) exports under import-namespace `name`.
/// - `AssertReturn(action, expected)`: the action's result list must match
///   `expected` (exact bits or a NaN class — see `Expected`).
/// - `AssertTrap(action, failure)` / `AssertExhaustion(action, failure)`: the
///   action must trap; `failure` is the expected trap-message SUBSTRING
///   (exhaustion is `"call stack exhausted"`).
/// - `AssertInvalid(module, failure)`: `module` PARSES but fails **validate**.
/// - `AssertMalformed(module, failure)`: `module` fails at **parse/decode**
///   (usually a `quote`/`binary` form).
/// - `AssertUnlinkable(module, failure)`: valid, but fails at **link**.
/// - `AssertUninstantiable(module, failure)`: links, but traps at instantiation.
/// - `ActionCmd(action)`: a bare `(invoke …)`/`(get …)` run for its effects.
/// - `CmdSkipped(kind)`: an out-of-scope command head (e.g. a thread command) —
///   CATEGORIZED, never silently dropped.
pub type Command {
  WatModule(id: Option(String), module: ModuleDef)
  Register(name: String, module: Option(String))
  AssertReturn(action: Action, expected: List(Expected))
  AssertTrap(action: Action, failure: String)
  AssertExhaustion(action: Action, failure: String)
  AssertInvalid(module: ModuleDef, failure: String)
  AssertMalformed(module: ModuleDef, failure: String)
  AssertUnlinkable(module: ModuleDef, failure: String)
  AssertUninstantiable(module: ModuleDef, failure: String)
  ActionCmd(action: Action)
  CmdSkipped(kind: String)
}

/// A module named in a script, in one of the `.wast`'s three forms. Which one a
/// command carries decides how unit 11 realises it into an instance.
///
/// - `TextModule(module)`: `(module <fields>)` — already parsed via
///   `parse_module` into an `ast.Module` (structurally equal to a decoded one),
///   so unit 11 runs it straight through `validate`/`lower`.
/// - `BinaryModule(bytes)`: `(module binary "…"*)` — the CONCATENATED
///   string-literal bytes; unit 11 feeds them to `decode` directly (this is how
///   the suite injects hand-crafted malformed/edge binaries).
/// - `QuoteModule(source)`: `(module quote "…"*)` — the concatenated text, to be
///   (re)parsed with `parse_module` when the command runs (used by
///   `assert_malformed (module quote …)`).
pub type ModuleDef {
  TextModule(module: ast.Module)
  BinaryModule(bytes: BitArray)
  QuoteModule(source: String)
}

/// A `.wast` action: invoke an exported function or read an exported global.
///
/// - `Invoke(module, field, args)`: call export `field` with `args`.
/// - `Get(module, field)`: read exported global `field`.
///
/// `module` is the TARGET module's script name (`$id`/registered name, WITHOUT
/// the `$`), or `None` for the current (most-recently-defined) module. Resolving
/// that name to an instance is unit 11's `registry` — this parser records the
/// NAME only (the cleaner seam: the parser holds no cross-module runtime state).
pub type Action {
  Invoke(module: Option(String), field: String, args: List(WastValue))
  Get(module: Option(String), field: String)
}

/// A concrete value: an action argument, or an EXACT-bits expected result.
/// Numeric values carry RAW bits (D5 — the same unsigned bit pattern the
/// conformance fixture stores, so BEAM doubles never destroy a NaN payload);
/// reference values carry their reftype / host payload (R18).
///
/// - `WastI32(bits)` / `WastI64(bits)`: unsigned integer bit pattern in
///   `[0, 2^32)` / `[0, 2^64)`.
/// - `WastF32(bits)` / `WastF64(bits)`: raw IEEE-754 binary32/binary64 bits.
/// - `RefNullVal(ty)`: `(ref.null func|extern)` — a null reference of reftype
///   `ty` (`FuncRef`/`ExternRef`).
/// - `RefFuncVal`: `(ref.func …)` — a (non-null) funcref (as an expected result,
///   "any non-null funcref").
/// - `RefExternVal(payload)`: `(ref.extern N)` — the host-constructible
///   externref carrying host int `N`.
pub type WastValue {
  WastI32(bits: Int)
  WastI64(bits: Int)
  WastF32(bits: Int)
  WastF64(bits: Int)
  RefNullVal(ty: ast.ValType)
  RefFuncVal
  RefExternVal(payload: Int)
}

/// An expected result in an `assert_return`: either an exact `WastValue` or a
/// NaN CLASS pattern. The two NaN forms are DISTINCT from an exact-bits expected
/// so unit 11's oracle class-matches (a canonical/arithmetic NaN never compares
/// by bit-equality — spec `assert_return_canonical_nan`/`_arithmetic_nan`).
/// `width` is `32` (f32) or `64` (f64).
///
/// - `ExpectedValue(value)`: an exact `WastValue` (bit-equal / ref match).
/// - `ExpectedNanCanonical(width)`: `(f32|f64.const nan:canonical)`.
/// - `ExpectedNanArithmetic(width)`: `(f32|f64.const nan:arithmetic)`.
pub type Expected {
  ExpectedValue(value: WastValue)
  ExpectedNanCanonical(width: Int)
  ExpectedNanArithmetic(width: Int)
}

// ===========================================================================
// A. The lexer
// ===========================================================================

/// Tokenise `source` into a flat token stream (spec `text/lexical.html`).
///
/// Whitespace and comments (line `;; …`, NESTING block `(; … ;)`) separate
/// tokens and are otherwise dropped. Returns `Ok(tokens)` or `Error(WatError)`
/// for any lexical malformation (unterminated string/comment, bad escape, stray
/// char), each with a `Pos`. Total over any `String`.
pub fn lex(source: String) -> Result(List(Token), WatError) {
  let cps =
    source
    |> string.to_utf_codepoints
    |> list.map(string.utf_codepoint_to_int)
  lex_go(cps, Pos(1, 1), [])
}

/// The codepoint for `(`, `)`, `;`, `"`, `$`, `\`.
const cp_lparen = 0x28

const cp_rparen = 0x29

const cp_semi = 0x3B

const cp_dquote = 0x22

const cp_dollar = 0x24

const cp_backslash = 0x5C

fn lex_go(
  cps: List(Int),
  pos: Pos,
  acc: List(Token),
) -> Result(List(Token), WatError) {
  case cps {
    [] -> Ok(list.reverse(acc))
    [c, ..rest] ->
      case is_whitespace(c) {
        True -> lex_go(rest, advance(pos, c), acc)
        False ->
          case c {
            _ if c == cp_semi ->
              // ";;" line comment, else a stray ';'.
              case rest {
                [c2, ..rest2] if c2 == cp_semi ->
                  lex_go(skip_line(rest2), bump_col(pos, 2), acc)
                _ -> Error(LexError(pos, StrayChar))
              }
            _ if c == cp_lparen ->
              // "(;" opens a (nesting) block comment; else a LParen.
              case rest {
                [c2, ..rest2] if c2 == cp_semi ->
                  case skip_block_comment(rest2, bump_col(pos, 2), 1) {
                    Ok(#(rest3, pos3)) -> lex_go(rest3, pos3, acc)
                    Error(e) -> Error(e)
                  }
                _ -> lex_go(rest, bump_col(pos, 1), [LParen(pos), ..acc])
              }
            _ if c == cp_rparen ->
              lex_go(rest, bump_col(pos, 1), [RParen(pos), ..acc])
            _ if c == cp_dquote ->
              case lex_string(rest, bump_col(pos, 1), <<>>) {
                Ok(#(bytes, rest2, pos2)) ->
                  lex_go(rest2, pos2, [Str(pos, bytes), ..acc])
                Error(e) -> Error(e)
              }
            _ if c == cp_dollar -> {
              let #(run, rest2) = take_idchars(rest, [])
              case run {
                [] -> Error(LexError(pos, StrayChar))
                _ ->
                  lex_go(rest2, bump_col(pos, 1 + list.length(run)), [
                    Id(pos, cps_to_string(run)),
                    ..acc
                  ])
              }
            }
            _ ->
              case is_idchar(c) {
                True -> {
                  let #(run, rest2) = take_idchars(rest, [c])
                  let text = cps_to_string(run)
                  lex_go(rest2, bump_col(pos, list.length(run)), [
                    classify_run(pos, text),
                    ..acc
                  ])
                }
                False -> Error(LexError(pos, StrayChar))
              }
          }
      }
  }
}

/// Classify a maximal idchar run: a valid number lexeme → `Num`; otherwise a run
/// starting with a lowercase ASCII letter → `Keyword`; otherwise `Reserved`.
fn classify_run(pos: Pos, text: String) -> Token {
  case is_number_lexeme(text) {
    True -> Num(pos, text)
    False ->
      case starts_lower(text) {
        True -> Keyword(pos, text)
        False -> Reserved(pos, text)
      }
  }
}

/// Whether a run looks like a number/float literal (integer, dec/hex float,
/// `inf`, `nan`, `nan:0x…`), i.e. after an optional sign it starts with a digit
/// or is one of the `inf`/`nan` forms. No keyword starts with a digit or is
/// spelled `inf`/`nan`, so this never steals a real keyword; a run that starts
/// with a digit but is not a valid number still classifies as `Num` and fails
/// at interpret time (a typed error, never a wrong AST).
fn is_number_lexeme(text: String) -> Bool {
  let body = drop_sign(text)
  case string.first(body) {
    Ok(ch) ->
      is_ascii_digit_str(ch)
      || body == "inf"
      || body == "nan"
      || string.starts_with(body, "nan:")
    Error(_) -> False
  }
}

fn drop_sign(text: String) -> String {
  case string.starts_with(text, "-") || string.starts_with(text, "+") {
    True -> string.drop_start(text, 1)
    False -> text
  }
}

fn starts_lower(text: String) -> Bool {
  case string.first(text) {
    Ok(ch) -> {
      let c = grapheme_cp(ch)
      c >= 0x61 && c <= 0x7A
    }
    Error(_) -> False
  }
}

fn is_ascii_digit_str(ch: String) -> Bool {
  let c = grapheme_cp(ch)
  c >= 0x30 && c <= 0x39
}

fn grapheme_cp(ch: String) -> Int {
  case string.to_utf_codepoints(ch) {
    [cp, ..] -> string.utf_codepoint_to_int(cp)
    [] -> -1
  }
}

fn is_whitespace(c: Int) -> Bool {
  c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
}

/// Whether `c` is an `idchar` (spec `text/lexical.html`): ASCII alphanumerics
/// plus the symbol set `! # $ % & ' * + - . / : < = > ? @ \ ^ _ ` | ~`.
fn is_idchar(c: Int) -> Bool {
  { c >= 0x30 && c <= 0x39 }
  || { c >= 0x41 && c <= 0x5A }
  || { c >= 0x61 && c <= 0x7A }
  || c == 0x21
  || c == 0x23
  || c == 0x24
  || c == 0x25
  || c == 0x26
  || c == 0x27
  || c == 0x2A
  || c == 0x2B
  || c == 0x2D
  || c == 0x2E
  || c == 0x2F
  || c == 0x3A
  || c == 0x3C
  || c == 0x3D
  || c == 0x3E
  || c == 0x3F
  || c == 0x40
  || c == 0x5C
  || c == 0x5E
  || c == 0x5F
  || c == 0x60
  || c == 0x7C
  || c == 0x7E
}

fn take_idchars(cps: List(Int), acc: List(Int)) -> #(List(Int), List(Int)) {
  case cps {
    [c, ..rest] ->
      case is_idchar(c) {
        True -> take_idchars(rest, [c, ..acc])
        False -> #(list.reverse(acc), cps)
      }
    [] -> #(list.reverse(acc), cps)
  }
}

fn cps_to_string(cps: List(Int)) -> String {
  cps
  |> list.filter_map(fn(c) {
    string.utf_codepoint(c) |> result.map_error(fn(_) { Nil })
  })
  |> string.from_utf_codepoints
}

fn skip_line(cps: List(Int)) -> List(Int) {
  case cps {
    [c, ..rest] ->
      case c == 0x0A {
        True -> rest
        False -> skip_line(rest)
      }
    [] -> []
  }
}

/// Skip a nesting block comment body, having already consumed the opening `(;`.
/// `depth` counts open comments; a nested `(;` deepens, a `;)` closes. Returns
/// the tail after the outermost `;)`, or `UnterminatedComment` at EOF.
fn skip_block_comment(
  cps: List(Int),
  pos: Pos,
  depth: Int,
) -> Result(#(List(Int), Pos), WatError) {
  case cps {
    [] -> Error(LexError(pos, UnterminatedComment))
    [c1, c2, ..rest] if c1 == cp_semi && c2 == cp_rparen ->
      case depth {
        1 -> Ok(#(rest, bump_col(pos, 2)))
        _ -> skip_block_comment(rest, bump_col(pos, 2), depth - 1)
      }
    [c1, c2, ..rest] if c1 == cp_lparen && c2 == cp_semi ->
      skip_block_comment(rest, bump_col(pos, 2), depth + 1)
    [c, ..rest] -> skip_block_comment(rest, advance(pos, c), depth)
  }
}

/// Lex a string literal body (the opening `"` already consumed), decoding
/// escapes into a byte `BitArray`. WAT strings are BYTE strings (arbitrary bytes
/// via `\NN`), not necessarily UTF-8.
fn lex_string(
  cps: List(Int),
  pos: Pos,
  acc: BitArray,
) -> Result(#(BitArray, List(Int), Pos), WatError) {
  case cps {
    [] -> Error(LexError(pos, UnterminatedString))
    [c, ..rest] ->
      case c {
        _ if c == cp_dquote -> Ok(#(acc, rest, bump_col(pos, 1)))
        _ if c == cp_backslash -> lex_escape(rest, bump_col(pos, 1), acc)
        _ -> lex_string(rest, advance(pos, c), append_cp(acc, c))
      }
  }
}

fn lex_escape(
  cps: List(Int),
  pos: Pos,
  acc: BitArray,
) -> Result(#(BitArray, List(Int), Pos), WatError) {
  case cps {
    [c, ..rest] ->
      case c {
        0x74 -> lex_string(rest, bump_col(pos, 1), <<acc:bits, 0x09>>)
        0x6E -> lex_string(rest, bump_col(pos, 1), <<acc:bits, 0x0A>>)
        0x72 -> lex_string(rest, bump_col(pos, 1), <<acc:bits, 0x0D>>)
        0x22 -> lex_string(rest, bump_col(pos, 1), <<acc:bits, 0x22>>)
        0x27 -> lex_string(rest, bump_col(pos, 1), <<acc:bits, 0x27>>)
        0x5C -> lex_string(rest, bump_col(pos, 1), <<acc:bits, 0x5C>>)
        0x75 -> lex_unicode_escape(rest, pos, acc)
        _ ->
          case hex_digit(c) {
            Ok(hi) ->
              case rest {
                [c2, ..rest2] ->
                  case hex_digit(c2) {
                    Ok(lo) ->
                      lex_string(rest2, bump_col(pos, 2), <<
                        acc:bits,
                        { hi * 16 + lo }:8,
                      >>)
                    Error(_) -> Error(LexError(pos, BadEscape))
                  }
                [] -> Error(LexError(pos, BadEscape))
              }
            Error(_) -> Error(LexError(pos, BadEscape))
          }
      }
    [] -> Error(LexError(pos, UnterminatedString))
  }
}

/// Decode a `\u{ H+ }` escape into UTF-8 bytes (reject `> 0x10FFFF` and
/// surrogates `0xD800..0xDFFF` → `BadEscape`).
fn lex_unicode_escape(
  cps: List(Int),
  pos: Pos,
  acc: BitArray,
) -> Result(#(BitArray, List(Int), Pos), WatError) {
  case cps {
    [0x7B, ..rest] -> {
      let #(hex, rest2) = take_hex(rest, [])
      case rest2 {
        [0x7D, ..rest3] ->
          case hex {
            [] -> Error(LexError(pos, BadEscape))
            _ ->
              case digits_to_int(hex, 16) {
                Ok(scalar) ->
                  case
                    scalar > 0x10FFFF
                    || { scalar >= 0xD800 && scalar <= 0xDFFF }
                  {
                    True -> Error(LexError(pos, BadEscape))
                    False ->
                      lex_string(
                        rest3,
                        bump_col(pos, 3 + list.length(hex)),
                        append_cp(acc, scalar),
                      )
                  }
                Error(_) -> Error(LexError(pos, BadEscape))
              }
          }
        _ -> Error(LexError(pos, BadEscape))
      }
    }
    _ -> Error(LexError(pos, BadEscape))
  }
}

fn take_hex(cps: List(Int), acc: List(Int)) -> #(List(Int), List(Int)) {
  case cps {
    [c, ..rest] ->
      case hex_digit(c) {
        Ok(_) -> take_hex(rest, [c, ..acc])
        Error(_) -> #(list.reverse(acc), cps)
      }
    [] -> #(list.reverse(acc), cps)
  }
}

/// Append the UTF-8 encoding of scalar `c` to `acc`.
fn append_cp(acc: BitArray, c: Int) -> BitArray {
  case string.utf_codepoint(c) {
    Ok(cp) ->
      bit_array.append(
        acc,
        bit_array.from_string(string.from_utf_codepoints([cp])),
      )
    Error(_) -> acc
  }
}

fn hex_digit(c: Int) -> Result(Int, Nil) {
  case c {
    _ if c >= 0x30 && c <= 0x39 -> Ok(c - 0x30)
    _ if c >= 0x41 && c <= 0x46 -> Ok(c - 0x41 + 10)
    _ if c >= 0x61 && c <= 0x66 -> Ok(c - 0x61 + 10)
    _ -> Error(Nil)
  }
}

fn digits_to_int(cps: List(Int), base: Int) -> Result(Int, Nil) {
  list.try_fold(cps, 0, fn(acc, c) {
    case hex_digit(c) {
      Ok(d) if d < base -> Ok(acc * base + d)
      _ -> Error(Nil)
    }
  })
}

fn advance(pos: Pos, c: Int) -> Pos {
  case c == 0x0A {
    True -> Pos(pos.line + 1, 1)
    False -> Pos(pos.line, pos.col + 1)
  }
}

fn bump_col(pos: Pos, n: Int) -> Pos {
  Pos(pos.line, pos.col + n)
}

// ===========================================================================
// B. Number literals → bits (the D5 discipline)
// ===========================================================================
//
// A `Num` lexeme is interpreted at the POINT OF USE, because width and
// int-vs-float are context-determined. Integers produce the raw two's-complement
// pattern re-signed to what the binary decoder stores; floats produce the raw
// IEEE-754 bit pattern (never a BEAM double — D5). Hex floats and `nan:0x…`
// payloads are BIT-EXACT; decimal floats are exact via a big-integer
// round-to-nearest-ties-even routine.

/// `2^n` for `n >= 0` (BEAM bignum). `1` for `n <= 0`.
fn pow2(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> int.bitwise_shift_left(1, n)
  }
}

/// `10^n` for `n >= 0` (BEAM bignum). `1` for `n <= 0`.
fn pow10(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> 10 * pow10(n - 1)
  }
}

/// The mathematical value of an integer lexeme (`sign`, `0x`-hex or decimal, `_`
/// digit separators), as a BEAM bignum (no overflow). `Error(Nil)` for a lexeme
/// that is not a well-formed integer.
fn int_math_value(lexeme: String) -> Result(Int, Nil) {
  let #(neg, body0) = case
    string.starts_with(lexeme, "-"),
    string.starts_with(lexeme, "+")
  {
    True, _ -> #(True, string.drop_start(lexeme, 1))
    _, True -> #(False, string.drop_start(lexeme, 1))
    _, _ -> #(False, lexeme)
  }
  let body = strip_underscores(body0)
  let base_result = case
    string.starts_with(body, "0x") || string.starts_with(body, "0X")
  {
    True -> #(16, string.drop_start(body, 2))
    False -> #(10, body)
  }
  let #(base, digits) = base_result
  case digits == "" {
    True -> Error(Nil)
    False ->
      case digits_to_int(string_to_cps(digits), base) {
        Ok(v) ->
          case neg {
            True -> Ok(-v)
            False -> Ok(v)
          }
        Error(_) -> Error(Nil)
      }
  }
}

/// Interpret an integer lexeme for `t.const` at bit `width` (32 or 64), returning
/// the SIGNED value the decoder stores (`I32Const`/`I64Const` carry the decoded
/// signed value). Accepts the combined signed∪unsigned range `[-2^(w-1), 2^w)`
/// then takes the two's-complement bits (spec: integer literals fold both ranges).
/// `NumberOutOfRange` outside that range or on a malformed lexeme.
fn const_int_value(
  lexeme: String,
  width: Int,
  pos: Pos,
) -> Result(Int, WatError) {
  case int_math_value(lexeme) {
    Ok(v) -> {
      let m = pow2(width)
      let half = pow2(width - 1)
      case v >= -half && v < m {
        True -> {
          let bits = { { v % m } + m } % m
          case bits >= half {
            True -> Ok(bits - m)
            False -> Ok(bits)
          }
        }
        False -> Error(NumberOutOfRange(pos, lexeme))
      }
    }
    Error(_) -> Error(NumberOutOfRange(pos, lexeme))
  }
}

/// Interpret a non-negative index/count lexeme as a `uN(width)` (dec/hex, `_`).
/// `NumberOutOfRange` if negative, `>= 2^width`, or malformed.
fn uint_value(lexeme: String, width: Int, pos: Pos) -> Result(Int, WatError) {
  case int_math_value(lexeme) {
    Ok(v) ->
      case v >= 0 && v < pow2(width) {
        True -> Ok(v)
        False -> Error(NumberOutOfRange(pos, lexeme))
      }
    Error(_) -> Error(NumberOutOfRange(pos, lexeme))
  }
}

fn strip_underscores(s: String) -> String {
  string.split(s, "_") |> string.concat
}

fn string_to_cps(s: String) -> List(Int) {
  s |> string.to_utf_codepoints |> list.map(string.utf_codepoint_to_int)
}

// --- Float literals → raw IEEE-754 bits -----------------------------------

/// IEEE-754 format parameters for `f32`/`f64`.
type FloatFmt {
  FloatFmt(mant_bits: Int, exp_bits: Int)
}

fn f32_fmt() -> FloatFmt {
  FloatFmt(mant_bits: 23, exp_bits: 8)
}

fn f64_fmt() -> FloatFmt {
  FloatFmt(mant_bits: 52, exp_bits: 11)
}

/// Interpret a float lexeme for `f32.const`/`f64.const` into the raw IEEE-754
/// bit pattern (an unsigned `Int`). Handles decimal floats, hex floats, integer
/// lexemes, `inf`, `nan`, and `nan:0x…` payloads. `BadNanPayload`/
/// `NumberOutOfRange` on malformation.
fn float_bits(
  lexeme: String,
  fmt: FloatFmt,
  pos: Pos,
) -> Result(Int, WatError) {
  let #(sign, body0) = case
    string.starts_with(lexeme, "-"),
    string.starts_with(lexeme, "+")
  {
    True, _ -> #(1, string.drop_start(lexeme, 1))
    _, True -> #(0, string.drop_start(lexeme, 1))
    _, _ -> #(0, lexeme)
  }
  let body = strip_underscores(body0)
  let exp_all_ones = pow2(fmt.exp_bits) - 1
  let sign_bit = int.bitwise_shift_left(sign, fmt.mant_bits + fmt.exp_bits)
  case body {
    "inf" -> Ok(sign_bit + int.bitwise_shift_left(exp_all_ones, fmt.mant_bits))
    "nan" ->
      Ok(
        sign_bit
        + int.bitwise_shift_left(exp_all_ones, fmt.mant_bits)
        + pow2(fmt.mant_bits - 1),
      )
    _ ->
      case string.starts_with(body, "nan:") {
        True -> nan_payload_bits(body, fmt, sign_bit, exp_all_ones, pos, lexeme)
        False ->
          case
            string.starts_with(body, "0x") || string.starts_with(body, "0X")
          {
            True ->
              hexfloat_bits(string.drop_start(body, 2), fmt, sign, pos, lexeme)
            False -> decimalfloat_bits(body, fmt, sign, pos, lexeme)
          }
      }
  }
}

fn nan_payload_bits(
  body: String,
  fmt: FloatFmt,
  sign_bit: Int,
  exp_all_ones: Int,
  pos: Pos,
  lexeme: String,
) -> Result(Int, WatError) {
  let rest = string.drop_start(body, 4)
  case string.starts_with(rest, "0x") || string.starts_with(rest, "0X") {
    True ->
      case digits_to_int(string_to_cps(string.drop_start(rest, 2)), 16) {
        Ok(payload) ->
          case payload >= 1 && payload < pow2(fmt.mant_bits) {
            True ->
              Ok(
                sign_bit
                + int.bitwise_shift_left(exp_all_ones, fmt.mant_bits)
                + payload,
              )
            False -> Error(BadNanPayload(pos, lexeme))
          }
        Error(_) -> Error(BadNanPayload(pos, lexeme))
      }
    False -> Error(BadNanPayload(pos, lexeme))
  }
}

/// Hex float (`h*(.h*)?(p[+-]d+)?`, the `0x` already stripped) → exact bits. A
/// hex float names a dyadic rational `significand * 2^binexp`; build the ratio
/// exactly and round the low mantissa bits.
fn hexfloat_bits(
  body: String,
  fmt: FloatFmt,
  sign: Int,
  pos: Pos,
  lexeme: String,
) -> Result(Int, WatError) {
  let #(mant_str, exp_str) = split_on_either(body, "p", "P")
  let #(int_str, frac_str) = split_on(body_of(mant_str), ".")
  let hex_digits = int_str <> frac_str
  case hex_digits == "" {
    True -> Error(NumberOutOfRange(pos, lexeme))
    False ->
      case digits_to_int(string_to_cps(hex_digits), 16) {
        Ok(significand) -> {
          let p_exp = case exp_str {
            Some(es) ->
              case int_math_value(es) {
                Ok(v) -> Ok(v)
                Error(_) -> Error(Nil)
              }
            None -> Ok(0)
          }
          case p_exp {
            Ok(pe) -> {
              let binexp = pe - 4 * string.length(frac_str)
              let num = significand * pow2(max_int(0, binexp))
              let den = pow2(max_int(0, -binexp))
              Ok(ieee_bits(sign, num, den, fmt))
            }
            Error(_) -> Error(NumberOutOfRange(pos, lexeme))
          }
        }
        Error(_) -> Error(NumberOutOfRange(pos, lexeme))
      }
  }
}

/// Decimal float (`d+(.d*)?(e[+-]d+)?`) or a plain decimal integer → correctly
/// rounded bits. `value = mant * 10^k`; build the exact rational and round with
/// ties-to-even (big-integer arithmetic — no BEAM double intermediate).
fn decimalfloat_bits(
  body: String,
  fmt: FloatFmt,
  sign: Int,
  pos: Pos,
  lexeme: String,
) -> Result(Int, WatError) {
  let #(mant_str, exp_str) = split_on_either(body, "e", "E")
  let #(int_str, frac_str) = split_on(body_of(mant_str), ".")
  let dec_digits = int_str <> frac_str
  case dec_digits == "" {
    True -> Error(NumberOutOfRange(pos, lexeme))
    False ->
      case digits_to_int(string_to_cps(dec_digits), 10) {
        Ok(mant) -> {
          let dexp = case exp_str {
            Some(es) ->
              case int_math_value(es) {
                Ok(v) -> Ok(v)
                Error(_) -> Error(Nil)
              }
            None -> Ok(0)
          }
          case dexp {
            Ok(de) -> {
              let k = de - string.length(frac_str)
              let num = mant * pow10(max_int(0, k))
              let den = pow10(max_int(0, -k))
              Ok(ieee_bits(sign, num, den, fmt))
            }
            Error(_) -> Error(NumberOutOfRange(pos, lexeme))
          }
        }
        Error(_) -> Error(NumberOutOfRange(pos, lexeme))
      }
  }
}

fn body_of(s: String) -> String {
  s
}

/// Split on the first occurrence of `sep`; the second element is `None` if the
/// separator is absent.
fn split_on(s: String, sep: String) -> #(String, String) {
  case string.split_once(s, sep) {
    Ok(#(a, b)) -> #(a, b)
    Error(_) -> #(s, "")
  }
}

fn split_on_either(
  s: String,
  sep1: String,
  sep2: String,
) -> #(String, Option(String)) {
  case string.split_once(s, sep1) {
    Ok(#(a, b)) -> #(a, Some(b))
    Error(_) ->
      case string.split_once(s, sep2) {
        Ok(#(a, b)) -> #(a, Some(b))
        Error(_) -> #(s, None)
      }
  }
}

fn max_int(a: Int, b: Int) -> Int {
  case a >= b {
    True -> a
    False -> b
  }
}

/// Correctly round the non-negative rational `num/den` (both integers, `den>0`)
/// to `fmt`, packing sign + exponent + mantissa into the raw bit pattern.
/// Round-to-nearest, ties-to-even; handles subnormals, zero, and overflow→inf.
fn ieee_bits(sign: Int, num: Int, den: Int, fmt: FloatFmt) -> Int {
  let mant_bits = fmt.mant_bits
  let exp_bits = fmt.exp_bits
  let p = mant_bits + 1
  let bias = pow2(exp_bits - 1) - 1
  let emin = 1 - bias
  let emax = bias
  let exp_all_ones = pow2(exp_bits) - 1
  let sign_bit = int.bitwise_shift_left(sign, mant_bits + exp_bits)
  let inf = sign_bit + int.bitwise_shift_left(exp_all_ones, mant_bits)
  case num == 0 {
    True -> sign_bit
    False -> {
      let q_min = emin - { p - 1 }
      let l = floor_log2_ratio(num, den)
      let e0 = l - { p - 1 }
      let e = max_int(e0, q_min)
      let m0 = scaled_round(num, den, e)
      // Rounding may carry the significand up to 2^p → renormalise.
      let #(m, ex) = case m0 >= pow2(p) {
        True -> #(pow2(p - 1), e + 1)
        False -> #(m0, e)
      }
      case m == 0 {
        True -> sign_bit
        False ->
          case m >= pow2(p - 1) {
            True -> {
              // Normal: value = m * 2^ex, unbiased exponent E = ex + (p-1).
              let big_e = ex + { p - 1 }
              case big_e > emax {
                True -> inf
                False -> {
                  let biased = big_e + bias
                  let mantissa = m - pow2(p - 1)
                  sign_bit
                  + int.bitwise_shift_left(biased, mant_bits)
                  + mantissa
                }
              }
            }
            // Subnormal: exponent field 0, mantissa = m.
            False -> sign_bit + m
          }
      }
    }
  }
}

/// `round_half_even(num / (den * 2^e))` as a non-negative integer (exact).
fn scaled_round(num: Int, den: Int, e: Int) -> Int {
  let #(n, d) = case e >= 0 {
    True -> #(num, den * pow2(e))
    False -> #(num * pow2(-e), den)
  }
  let q = n / d
  let r = n % d
  let twice = 2 * r
  case int.compare(twice, d) {
    order.Lt -> q
    order.Gt -> q + 1
    order.Eq ->
      case q % 2 == 0 {
        True -> q
        False -> q + 1
      }
  }
}

/// `floor(log2(num/den))` for positive integers `num`, `den` (exact).
fn floor_log2_ratio(num: Int, den: Int) -> Int {
  let a = msb(num)
  let b = msb(den)
  let l0 = a - b
  let lhs = num * pow2(max_int(0, -l0))
  let rhs = den * pow2(max_int(0, l0))
  case lhs >= rhs {
    True -> l0
    False -> l0 - 1
  }
}

/// `floor(log2(n))` for `n >= 1` (position of the most-significant bit).
fn msb(n: Int) -> Int {
  msb_go(n, 0)
}

fn msb_go(n: Int, acc: Int) -> Int {
  case n <= 1 {
    True -> acc
    False -> msb_go(n / 2, acc + 1)
  }
}

// ===========================================================================
// C. The module parser — index spaces & identifier resolution
// ===========================================================================
//
// The binary form never sees a name; the text form has one `$id → Int` map per
// index space, and the parser must resolve every `$id` to the exact numeric
// index the binary form carries (so the AST is structurally equal to
// `decode(wat2wasm)`). Parsing is TWO-PASS: pass A assigns every definition its
// index (imports first, in source order — wabt requires imports before
// definitions) and registers `$id → index` plus the EXPLICIT type list; pass B
// parses bodies, resolving `$id` uses against the completed environment and
// appending IMPLICIT types (from inline type-uses) in depth-first source order.

type NameMap =
  Dict(String, Int)

/// The per-module symbol environment: one `$name → index` map per index space.
/// `locals` is function-scoped (rebuilt per function); the rest are
/// module-scoped. Labels are a scoped relative space passed separately.
type Env {
  Env(
    types: NameMap,
    funcs: NameMap,
    tables: NameMap,
    mems: NameMap,
    globals: NameMap,
    elems: NameMap,
    datas: NameMap,
    locals: NameMap,
  )
}

/// Parse WAT `source` into an `ast.Module` (`«WASM-AST3»`), structurally equal
/// to `decode(wat2wasm(source))` for well-formed Phase-5-scope text.
///
/// Returns `Ok(module)` or a typed `WatError` for any malformation. Does NOT
/// typecheck — a well-formed but ill-typed module parses (it is `validate`'s job
/// to reject it). Total over any `String`.
pub fn parse_module(source: String) -> Result(ast.Module, WatError) {
  use tokens <- result.try(lex(source))
  parse_module_tokens(tokens)
}

/// Parse an already-lexed token stream into an `ast.Module` (the shared body of
/// `parse_module` and the script layer's text-module command). `tokens` must be
/// a `(module …)` group (or a bare field list). Same contract/failure modes as
/// `parse_module`; never panics.
fn parse_module_tokens(tokens: List(Token)) -> Result(ast.Module, WatError) {
  use fields0 <- result.try(extract_module_fields(tokens))
  let fields = list.filter(fields0, fn(f) { !is_annotation_field(f) })
  use #(env, types) <- result.try(phase_a(fields))
  phase_b(fields, env, types)
}

/// Whether a field group is a WAT annotation `(@name …)` — dropped structurally
/// (matching wabt), not an error.
fn is_annotation_field(field: List(Token)) -> Bool {
  case field {
    [Reserved(_, t), ..] -> string.starts_with(t, "@")
    _ -> False
  }
}

/// Unwrap `(module id? field*)` to the list of field token-groups (each group is
/// the tokens INSIDE its parens, starting with the field head keyword). Also
/// accepts a bare `field*` (no `(module)` wrapper). Trailing tokens after the
/// module → error.
fn extract_module_fields(
  tokens: List(Token),
) -> Result(List(List(Token)), WatError) {
  case tokens {
    [LParen(_), Keyword(_, "module"), ..rest] -> {
      let rest2 = case rest {
        [Id(_, _), ..r] -> r
        _ -> rest
      }
      use #(fields, after) <- result.try(collect_groups(rest2))
      case after {
        [RParen(_)] -> Ok(fields)
        [RParen(_), t, ..] ->
          Error(UnexpectedToken(tok_pos(t), "end of input", describe(t)))
        [] -> Error(UnexpectedEof("closing paren of (module)"))
        [t, ..] ->
          Error(UnexpectedToken(tok_pos(t), "module field or )", describe(t)))
      }
    }
    _ -> {
      use #(fields, after) <- result.try(collect_groups(tokens))
      case after {
        [] -> Ok(fields)
        [t, ..] ->
          Error(UnexpectedToken(tok_pos(t), "module field", describe(t)))
      }
    }
  }
}

/// Consume `toks` starting at `LParen`, returning the tokens strictly inside the
/// matching parens and the tail after the closing paren. `UnexpectedEof` on an
/// unbalanced group.
fn take_group(
  toks: List(Token),
) -> Result(#(List(Token), List(Token)), WatError) {
  case toks {
    [LParen(_), ..rest] -> take_group_go(rest, 0, [])
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "(", describe(t)))
    [] -> Error(UnexpectedEof("("))
  }
}

fn take_group_go(
  toks: List(Token),
  depth: Int,
  acc: List(Token),
) -> Result(#(List(Token), List(Token)), WatError) {
  case toks {
    [] -> Error(UnexpectedEof("closing paren"))
    [RParen(p), ..rest] ->
      case depth {
        0 -> Ok(#(list.reverse(acc), rest))
        _ -> take_group_go(rest, depth - 1, [RParen(p), ..acc])
      }
    [LParen(p), ..rest] -> take_group_go(rest, depth + 1, [LParen(p), ..acc])
    [t, ..rest] -> take_group_go(rest, depth, [t, ..acc])
  }
}

/// Collect consecutive `( … )` groups (their insides) until a non-`LParen`
/// token, returning the groups and the remaining tokens.
fn collect_groups(
  toks: List(Token),
) -> Result(#(List(List(Token)), List(Token)), WatError) {
  case toks {
    [LParen(_), ..] -> {
      use #(inside, rest) <- result.try(take_group(toks))
      use #(more, rest2) <- result.try(collect_groups(rest))
      Ok(#([inside, ..more], rest2))
    }
    _ -> Ok(#([], toks))
  }
}

fn tok_pos(t: Token) -> Pos {
  case t {
    LParen(p) -> p
    RParen(p) -> p
    Keyword(p, _) -> p
    Id(p, _) -> p
    Num(p, _) -> p
    Str(p, _) -> p
    Reserved(p, _) -> p
  }
}

fn describe(t: Token) -> String {
  case t {
    LParen(_) -> "("
    RParen(_) -> ")"
    Keyword(_, s) -> s
    Id(_, s) -> "$" <> s
    Num(_, s) -> s
    Str(_, _) -> "a string"
    Reserved(_, s) -> s
  }
}

fn list_at(l: List(a), i: Int) -> Result(a, Nil) {
  case l, i {
    [x, ..], 0 -> Ok(x)
    [_, ..rest], _ if i > 0 -> list_at(rest, i - 1)
    _, _ -> Error(Nil)
  }
}

/// Insert `name → idx` into `map`, or `DuplicateIdentifier` if already present.
fn register(
  map: NameMap,
  name: String,
  idx: Int,
  space: String,
  pos: Pos,
) -> Result(NameMap, WatError) {
  case dict.has_key(map, name) {
    True -> Error(DuplicateIdentifier(pos, space, name))
    False -> Ok(dict.insert(map, name, idx))
  }
}

fn drop_leading_id(toks: List(Token)) -> List(Token) {
  case toks {
    [Id(_, _), ..r] -> r
    _ -> toks
  }
}

// --- Phase A: assign indices, collect explicit types ----------------------

type AState {
  AState(
    env: Env,
    types: List(ast.FuncType),
    n_types: Int,
    nf: Int,
    nt: Int,
    nm: Int,
    ng: Int,
    ne: Int,
    nd: Int,
  )
}

fn empty_env() -> Env {
  Env(
    types: dict.new(),
    funcs: dict.new(),
    tables: dict.new(),
    mems: dict.new(),
    globals: dict.new(),
    elems: dict.new(),
    datas: dict.new(),
    locals: dict.new(),
  )
}

fn phase_a(
  fields: List(List(Token)),
) -> Result(#(Env, List(ast.FuncType)), WatError) {
  let st0 =
    AState(
      env: empty_env(),
      types: [],
      n_types: 0,
      nf: 0,
      nt: 0,
      nm: 0,
      ng: 0,
      ne: 0,
      nd: 0,
    )
  use st <- result.try(list.try_fold(fields, st0, a_field))
  Ok(#(st.env, st.types))
}

fn a_field(st: AState, field: List(Token)) -> Result(AState, WatError) {
  case field {
    [Keyword(_, "type"), ..rest] -> a_type(rest, st)
    [Keyword(p, "func"), ..rest] -> a_bump_func(rest, p, st)
    [Keyword(p, "table"), ..rest] -> a_bump_table(rest, p, st)
    [Keyword(p, "memory"), ..rest] -> a_bump_mem(rest, p, st)
    [Keyword(p, "global"), ..rest] -> a_bump_global(rest, p, st)
    [Keyword(p, "elem"), ..rest] -> a_bump_elem(rest, p, st)
    [Keyword(p, "data"), ..rest] -> a_bump_data(rest, p, st)
    [Keyword(_, "import"), ..rest] -> a_import(rest, st)
    [Keyword(_, "export"), ..] -> Ok(st)
    [Keyword(_, "start"), ..] -> Ok(st)
    [Keyword(p, kw), ..] -> Error(UnexpectedToken(p, "module field", kw))
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "module field", describe(t)))
    [] -> Error(UnexpectedEof("module field"))
  }
}

/// Register an explicit `(type $id? (func …))`, appending its signature.
fn a_type(rest: List(Token), st: AState) -> Result(AState, WatError) {
  let #(name, rest1) = case rest {
    [Id(_, n), ..r] -> #(Some(n), r)
    _ -> #(None, rest)
  }
  use #(ft, _) <- result.try(parse_functype_group(rest1))
  use types_map <- result.try(case name {
    Some(n) -> register(st.env.types, n, st.n_types, "type", header_pos(rest))
    None -> Ok(st.env.types)
  })
  Ok(
    AState(
      ..st,
      env: Env(..st.env, types: types_map),
      types: list.append(st.types, [ft]),
      n_types: st.n_types + 1,
    ),
  )
}

fn header_pos(rest: List(Token)) -> Pos {
  case rest {
    [t, ..] -> tok_pos(t)
    [] -> Pos(0, 0)
  }
}

fn a_bump_func(
  rest: List(Token),
  p: Pos,
  st: AState,
) -> Result(AState, WatError) {
  use m <- result.try(a_reg(st.env.funcs, rest, st.nf, "func", p))
  Ok(AState(..st, env: Env(..st.env, funcs: m), nf: st.nf + 1))
}

fn a_bump_table(
  rest: List(Token),
  p: Pos,
  st: AState,
) -> Result(AState, WatError) {
  use m <- result.try(a_reg(st.env.tables, rest, st.nt, "table", p))
  Ok(AState(..st, env: Env(..st.env, tables: m), nt: st.nt + 1))
}

fn a_bump_mem(
  rest: List(Token),
  p: Pos,
  st: AState,
) -> Result(AState, WatError) {
  use m <- result.try(a_reg(st.env.mems, rest, st.nm, "memory", p))
  Ok(AState(..st, env: Env(..st.env, mems: m), nm: st.nm + 1))
}

fn a_bump_global(
  rest: List(Token),
  p: Pos,
  st: AState,
) -> Result(AState, WatError) {
  use m <- result.try(a_reg(st.env.globals, rest, st.ng, "global", p))
  Ok(AState(..st, env: Env(..st.env, globals: m), ng: st.ng + 1))
}

fn a_bump_elem(
  rest: List(Token),
  p: Pos,
  st: AState,
) -> Result(AState, WatError) {
  use m <- result.try(a_reg(st.env.elems, rest, st.ne, "elem", p))
  Ok(AState(..st, env: Env(..st.env, elems: m), ne: st.ne + 1))
}

fn a_bump_data(
  rest: List(Token),
  p: Pos,
  st: AState,
) -> Result(AState, WatError) {
  use m <- result.try(a_reg(st.env.datas, rest, st.nd, "data", p))
  Ok(AState(..st, env: Env(..st.env, datas: m), nd: st.nd + 1))
}

/// Register the optional leading `$id` of a definition (if any) at `idx`.
fn a_reg(
  map: NameMap,
  rest: List(Token),
  idx: Int,
  space: String,
  _p: Pos,
) -> Result(NameMap, WatError) {
  case rest {
    [Id(idp, n), ..] -> register(map, n, idx, space, idp)
    _ -> Ok(map)
  }
}

/// Register the descriptor `$id` of an `(import "m" "n" (kind $id? …))` into the
/// matching index space and bump its counter (imports occupy the low indices).
fn a_import(rest: List(Token), st: AState) -> Result(AState, WatError) {
  case rest {
    [Str(_, _), Str(_, _), ..r2] -> {
      use #(desc, _) <- result.try(take_group(r2))
      case desc {
        [Keyword(p, "func"), ..dr] -> {
          use m <- result.try(a_reg(st.env.funcs, dr, st.nf, "func", p))
          Ok(AState(..st, env: Env(..st.env, funcs: m), nf: st.nf + 1))
        }
        [Keyword(p, "table"), ..dr] -> {
          use m <- result.try(a_reg(st.env.tables, dr, st.nt, "table", p))
          Ok(AState(..st, env: Env(..st.env, tables: m), nt: st.nt + 1))
        }
        [Keyword(p, "memory"), ..dr] -> {
          use m <- result.try(a_reg(st.env.mems, dr, st.nm, "memory", p))
          Ok(AState(..st, env: Env(..st.env, mems: m), nm: st.nm + 1))
        }
        [Keyword(p, "global"), ..dr] -> {
          use m <- result.try(a_reg(st.env.globals, dr, st.ng, "global", p))
          Ok(AState(..st, env: Env(..st.env, globals: m), ng: st.ng + 1))
        }
        [t, ..] -> Error(UnexpectedToken(tok_pos(t), "importdesc", describe(t)))
        [] -> Error(UnexpectedEof("importdesc"))
      }
    }
    _ -> Error(UnexpectedEof("import module/name strings"))
  }
}

// --- Phase B: full parse, resolving refs + appending implicit types --------

type BState {
  BState(
    env: Env,
    types: List(ast.FuncType),
    imports: List(ast.Import),
    tables: List(ast.TableType),
    memories: List(ast.MemType),
    globals: List(ast.Global),
    funcs: List(ast.Func),
    start: Option(Int),
    elements: List(ast.ElementSegment),
    data: List(ast.DataSegment),
    exports: List(ast.Export),
    cur_func: Int,
    cur_table: Int,
    cur_mem: Int,
    cur_global: Int,
    cur_elem: Int,
    cur_data: Int,
  )
}

fn phase_b(
  fields: List(List(Token)),
  env: Env,
  types: List(ast.FuncType),
) -> Result(ast.Module, WatError) {
  let st0 =
    BState(
      env: env,
      types: types,
      imports: [],
      tables: [],
      memories: [],
      globals: [],
      funcs: [],
      start: None,
      elements: [],
      data: [],
      exports: [],
      cur_func: 0,
      cur_table: 0,
      cur_mem: 0,
      cur_global: 0,
      cur_elem: 0,
      cur_data: 0,
    )
  use st <- result.try(list.try_fold(fields, st0, b_field))
  let imported_func_count =
    list.fold(st.imports, 0, fn(acc, imp) {
      case imp.desc {
        ast.ImportFunc(_) -> acc + 1
        _ -> acc
      }
    })
  // wat2wasm emits a datacount section iff a `memory.init`/`data.drop` is present
  // (R13 / spec §5.5.14); decode then records `Some(len(data))`. Match that so a
  // bulk-memory module is structurally equal to `decode(wat2wasm(text))`.
  let data_count = case
    list.any(st.funcs, fn(f) { list.any(f.body, uses_data_segment) })
  {
    True -> Some(list.length(st.data))
    False -> None
  }
  Ok(ast.Module(
    imported_func_count: imported_func_count,
    // The WAT parser only produces func types today; wrap each as a final,
    // supertype-less defined type for the unified type section.
    types: list.map(st.types, fn(ft) {
      ast.DefType(comp: ast.CtFunc(ft), supertype: option.None, final: True)
    }),
    // The WAT parser only produces func types (no rec groups / GC), so every type
    // is its own singleton group — the non-GC default is `[]`.
    rec_groups: [],
    imports: list.reverse(st.imports),
    tables: list.reverse(st.tables),
    memories: list.reverse(st.memories),
    globals: list.reverse(st.globals),
    tags: [],
    funcs: list.reverse(st.funcs),
    start: st.start,
    elements: list.reverse(st.elements),
    data: list.reverse(st.data),
    data_count: data_count,
    exports: list.reverse(st.exports),
  ))
}

/// Whether an instruction references a data-segment index (`memory.init`/
/// `data.drop`) — the two that force a datacount section (spec §5.5.14).
fn uses_data_segment(instr: ast.Instr) -> Bool {
  case instr {
    ast.MemoryInit(_, _) -> True
    ast.DataDrop(_) -> True
    _ -> False
  }
}

fn b_field(st: BState, field: List(Token)) -> Result(BState, WatError) {
  case field {
    [Keyword(_, "type"), ..] -> Ok(st)
    [Keyword(_, "func"), ..rest] -> b_func(rest, st)
    [Keyword(_, "table"), ..rest] -> b_table(rest, st)
    [Keyword(_, "memory"), ..rest] -> b_memory(rest, st)
    [Keyword(_, "global"), ..rest] -> b_global(rest, st)
    [Keyword(_, "elem"), ..rest] -> b_elem(rest, st)
    [Keyword(_, "data"), ..rest] -> b_data(rest, st)
    [Keyword(_, "import"), ..rest] -> b_import(rest, st)
    [Keyword(_, "export"), ..rest] -> b_export(rest, st)
    [Keyword(_, "start"), ..rest] -> b_start(rest, st)
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "module field", describe(t)))
    [] -> Error(UnexpectedEof("module field"))
  }
}

/// Fold source-order inline exports into the (reversed) export accumulator.
fn add_exports(
  acc: List(ast.Export),
  exports: List(ast.Export),
) -> List(ast.Export) {
  list.fold(exports, acc, fn(a, e) { [e, ..a] })
}

// --- func -----------------------------------------------------------------

fn b_func(rest: List(Token), st: BState) -> Result(BState, WatError) {
  let idx = st.cur_func
  let toks1 = drop_leading_id(rest)
  use #(exports, imp, toks2) <- result.try(parse_inout(
    toks1,
    ast.ExportFunc,
    idx,
  ))
  use #(opt_type, params, results, toks3) <- result.try(parse_typeuse_parts(
    toks2,
    st.env,
  ))
  use #(type_idx, param_types, types1) <- result.try(finalize_typeuse(
    opt_type,
    params,
    results,
    st.types,
    header_pos(rest),
  ))
  case imp {
    Some(#(m, n)) ->
      Ok(
        BState(
          ..st,
          types: types1,
          imports: [ast.Import(m, n, ast.ImportFunc(type_idx)), ..st.imports],
          exports: add_exports(st.exports, exports),
          cur_func: idx + 1,
        ),
      )
    None -> {
      use #(local_names, decl_locals, toks4) <- result.try(parse_locals(
        toks3,
        params,
        list.length(param_types),
      ))
      let fenv = Env(..st.env, locals: local_names)
      use #(body, leftover, types2) <- result.try(parse_seq(
        toks4,
        fenv,
        [],
        types1,
      ))
      case leftover {
        [] ->
          Ok(
            BState(
              ..st,
              types: types2,
              funcs: [
                ast.Func(type_idx, decl_locals, list.append(body, [ast.End])),
                ..st.funcs
              ],
              exports: add_exports(st.exports, exports),
              cur_func: idx + 1,
            ),
          )
        [t, ..] ->
          Error(UnexpectedToken(tok_pos(t), "instruction or )", describe(t)))
      }
    }
  }
}

/// Parse the leading inline `(export "n")*` and optional `(import "m" "n")`
/// abbreviations of a func/table/memory/global field (spec `text/modules.html`).
/// Returns the exports (source order), the optional import module/name, and the
/// remaining tokens.
fn parse_inout(
  toks: List(Token),
  kind: ast.ExportKind,
  idx: Int,
) -> Result(
  #(List(ast.Export), Option(#(String, String)), List(Token)),
  WatError,
) {
  parse_inout_go(toks, kind, idx, [], None)
}

fn parse_inout_go(
  toks: List(Token),
  kind: ast.ExportKind,
  idx: Int,
  exports: List(ast.Export),
  imp: Option(#(String, String)),
) -> Result(
  #(List(ast.Export), Option(#(String, String)), List(Token)),
  WatError,
) {
  case peek_group_head(toks) {
    Some("export") -> {
      use #(inside, rest) <- result.try(take_group(toks))
      case inside {
        [Keyword(_, "export"), Str(_, name_bytes)] -> {
          use name <- result.try(str_to_name(name_bytes, header_pos(inside)))
          parse_inout_go(
            rest,
            kind,
            idx,
            list.append(exports, [ast.Export(name, kind, idx)]),
            imp,
          )
        }
        _ -> Error(UnexpectedEof("export name"))
      }
    }
    Some("import") -> {
      use #(inside, rest) <- result.try(take_group(toks))
      case inside {
        [Keyword(_, "import"), Str(_, mb), Str(_, nb)] -> {
          use m <- result.try(str_to_name(mb, header_pos(inside)))
          use n <- result.try(str_to_name(nb, header_pos(inside)))
          parse_inout_go(rest, kind, idx, exports, Some(#(m, n)))
        }
        _ -> Error(UnexpectedEof("import module/name"))
      }
    }
    _ -> Ok(#(exports, imp, toks))
  }
}

fn str_to_name(bytes: BitArray, pos: Pos) -> Result(String, WatError) {
  case bit_array.to_string(bytes) {
    Ok(s) -> Ok(s)
    Error(_) -> Error(UnexpectedToken(pos, "utf-8 name", "invalid utf-8"))
  }
}

/// Parse the `(local …)*` declarations of a function body: build the combined
/// param+local name map (params occupy `0..p-1`, declared locals follow) and the
/// RLE-EXPANDED declared-local valtype list (matching `Func.locals`).
fn parse_locals(
  toks: List(Token),
  params: List(#(Option(String), ast.ValType)),
  param_count: Int,
) -> Result(#(NameMap, List(ast.ValType), List(Token)), WatError) {
  use base <- result.try(
    list.try_fold(index_list(params), dict.new(), fn(m, entry) {
      let #(i, #(name, _)) = entry
      case name {
        Some(nm) -> register(m, nm, i, "local", Pos(0, 0))
        None -> Ok(m)
      }
    }),
  )
  parse_locals_go(toks, base, [], param_count)
}

fn parse_locals_go(
  toks: List(Token),
  names: NameMap,
  acc: List(ast.ValType),
  next_idx: Int,
) -> Result(#(NameMap, List(ast.ValType), List(Token)), WatError) {
  case peek_group_head(toks) {
    Some("local") -> {
      use #(inside, rest) <- result.try(take_group(toks))
      let body = drop_head(inside)
      case body {
        [Id(idp, nm), vt] -> {
          use v <- result.try(parse_valtype(vt))
          use names2 <- result.try(register(names, nm, next_idx, "local", idp))
          parse_locals_go(rest, names2, list.append(acc, [v]), next_idx + 1)
        }
        _ -> {
          use vts <- result.try(parse_valtype_list(body))
          parse_locals_go(
            rest,
            names,
            list.append(acc, vts),
            next_idx + list.length(vts),
          )
        }
      }
    }
    _ -> Ok(#(names, acc, toks))
  }
}

fn index_list(l: List(a)) -> List(#(Int, a)) {
  list.index_map(l, fn(x, i) { #(i, x) })
}

// --- table ----------------------------------------------------------------

fn b_table(rest: List(Token), st: BState) -> Result(BState, WatError) {
  let idx = st.cur_table
  let toks1 = drop_leading_id(rest)
  use #(exports, imp, toks2) <- result.try(parse_inout(
    toks1,
    ast.ExportTable,
    idx,
  ))
  case imp {
    Some(#(m, n)) -> {
      use #(tt, _) <- result.try(parse_tabletype(toks2))
      Ok(
        BState(
          ..st,
          imports: [ast.Import(m, n, ast.ImportTable(tt)), ..st.imports],
          exports: add_exports(st.exports, exports),
          cur_table: idx + 1,
        ),
      )
    }
    None ->
      // Either `<limits> <reftype>` or the inline `<reftype> (elem …)` form.
      case toks2 {
        [Keyword(_, rk), ..] ->
          case is_reftype_kw(rk) {
            True -> b_table_inline_elem(toks2, idx, exports, st)
            False -> {
              use #(tt, _) <- result.try(parse_tabletype(toks2))
              Ok(
                BState(
                  ..st,
                  tables: [tt, ..st.tables],
                  exports: add_exports(st.exports, exports),
                  cur_table: idx + 1,
                ),
              )
            }
          }
        _ -> {
          use #(tt, _) <- result.try(parse_tabletype(toks2))
          Ok(
            BState(
              ..st,
              tables: [tt, ..st.tables],
              exports: add_exports(st.exports, exports),
              cur_table: idx + 1,
            ),
          )
        }
      }
  }
}

/// Desugar `(table $t <reftype> (elem …))` → a table sized `n..n` plus an active
/// element segment at offset 0 (spec `text/modules.html`).
fn b_table_inline_elem(
  toks: List(Token),
  idx: Int,
  exports: List(ast.Export),
  st: BState,
) -> Result(BState, WatError) {
  case toks {
    [Keyword(rp, rk), ..rest] -> {
      use ref_ty <- result.try(reftype_of(rk, rp))
      use #(inside, _) <- result.try(take_group(rest))
      case inside {
        [Keyword(_, "elem"), ..einit] -> {
          use init <- result.try(parse_elem_items(einit, ref_ty, st.env))
          let count = elem_init_len(init)
          let tt = ast.TableType(ref_ty, ast.Limits(count, Some(count)))
          let seg =
            ast.ElementSegment(
              ast.ElemActive(idx, [ast.I32Const(0)]),
              elem_ref_ty(init, ref_ty),
              init,
            )
          Ok(
            BState(
              ..st,
              tables: [tt, ..st.tables],
              elements: [seg, ..st.elements],
              exports: add_exports(st.exports, exports),
              cur_table: idx + 1,
              cur_elem: st.cur_elem + 1,
            ),
          )
        }
        _ -> Error(UnexpectedEof("(elem …) in inline table"))
      }
    }
    _ -> Error(UnexpectedEof("reftype in inline table"))
  }
}

fn elem_init_len(init: ast.ElemInit) -> Int {
  case init {
    ast.ElemFuncs(l) -> list.length(l)
    ast.ElemExprs(l) -> list.length(l)
  }
}

fn elem_ref_ty(init: ast.ElemInit, default: ast.ValType) -> ast.ValType {
  case init {
    ast.ElemFuncs(_) -> ast.FuncRef
    ast.ElemExprs(_) -> default
  }
}

/// Parse a `tabletype` = `<limits> <reftype>` (limits in entries). `funcref` is
/// the default only in the legacy 1-arg form; here the element keyword follows
/// the limits.
fn parse_tabletype(
  toks: List(Token),
) -> Result(#(ast.TableType, List(Token)), WatError) {
  use #(limits, rest) <- result.try(parse_limits(toks))
  case rest {
    [Keyword(rp, rk), ..rest2] -> {
      use ref_ty <- result.try(reftype_of(rk, rp))
      Ok(#(ast.TableType(ref_ty, limits), rest2))
    }
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "reftype", describe(t)))
    [] -> Error(UnexpectedEof("table element type"))
  }
}

// --- memory ---------------------------------------------------------------

fn b_memory(rest: List(Token), st: BState) -> Result(BState, WatError) {
  let idx = st.cur_mem
  let toks1 = drop_leading_id(rest)
  use #(exports, imp, toks2) <- result.try(parse_inout(
    toks1,
    ast.ExportMemory,
    idx,
  ))
  case imp {
    Some(#(m, n)) -> {
      use #(mt, _) <- result.try(parse_memtype(toks2))
      Ok(
        BState(
          ..st,
          imports: [ast.Import(m, n, ast.ImportMemory(mt)), ..st.imports],
          exports: add_exports(st.exports, exports),
          cur_mem: idx + 1,
        ),
      )
    }
    None ->
      case peek_group_head(toks2) {
        Some("data") -> b_memory_inline_data(toks2, idx, exports, st)
        _ -> {
          use #(mt, _) <- result.try(parse_memtype(toks2))
          Ok(
            BState(
              ..st,
              memories: [mt, ..st.memories],
              exports: add_exports(st.exports, exports),
              cur_mem: idx + 1,
            ),
          )
        }
      }
  }
}

/// Desugar `(memory $m (data "…"))` → a memory sized `ceil(len/65536)` pages plus
/// an active data segment at offset 0.
fn b_memory_inline_data(
  toks: List(Token),
  idx: Int,
  exports: List(ast.Export),
  st: BState,
) -> Result(BState, WatError) {
  use #(inside, _) <- result.try(take_group(toks))
  case inside {
    [Keyword(_, "data"), ..strs] -> {
      use bytes <- result.try(concat_strings(strs))
      let len = bit_array.byte_size(bytes)
      let pages = { len + 65_535 } / 65_536
      let mt = ast.MemType(ast.Limits(pages, Some(pages)), ast.Idx32)
      let seg = ast.DataSegment(ast.DataActive(idx, [ast.I32Const(0)]), bytes)
      Ok(
        BState(
          ..st,
          memories: [mt, ..st.memories],
          data: [seg, ..st.data],
          exports: add_exports(st.exports, exports),
          cur_mem: idx + 1,
          cur_data: st.cur_data + 1,
        ),
      )
    }
    _ -> Error(UnexpectedEof("(data …) in inline memory"))
  }
}

/// Parse a `memtype` = optional `i32`/`i64` index-type keyword then `<limits>`
/// (in 64KiB pages). Absent index-type keyword → `Idx32`.
fn parse_memtype(
  toks: List(Token),
) -> Result(#(ast.MemType, List(Token)), WatError) {
  let #(idx_type, toks1) = case toks {
    [Keyword(_, "i64"), ..r] -> #(ast.Idx64, r)
    [Keyword(_, "i32"), ..r] -> #(ast.Idx32, r)
    _ -> #(ast.Idx32, toks)
  }
  use #(limits, rest) <- result.try(parse_limits(toks1))
  Ok(#(ast.MemType(limits, idx_type), rest))
}

/// Parse `min:uN max:uN?` limits (min/max as `u32` for i32-indexed spaces; the
/// wider memory64 range is accepted here and range-checked by validate).
fn parse_limits(
  toks: List(Token),
) -> Result(#(ast.Limits, List(Token)), WatError) {
  case toks {
    [Num(p, minl), Num(_, maxl), ..rest] ->
      case uint_value(minl, 64, p) {
        Ok(mn) ->
          case uint_value(maxl, 64, p) {
            Ok(mx) -> Ok(#(ast.Limits(mn, Some(mx)), rest))
            Error(e) -> Error(e)
          }
        Error(e) -> Error(e)
      }
    [Num(p, minl), ..rest] -> {
      use mn <- result.try(uint_value(minl, 64, p))
      Ok(#(ast.Limits(mn, None), rest))
    }
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "limits min", describe(t)))
    [] -> Error(UnexpectedEof("limits"))
  }
}

// --- global ---------------------------------------------------------------

fn b_global(rest: List(Token), st: BState) -> Result(BState, WatError) {
  let idx = st.cur_global
  let toks1 = drop_leading_id(rest)
  use #(exports, imp, toks2) <- result.try(parse_inout(
    toks1,
    ast.ExportGlobal,
    idx,
  ))
  use #(ty, mutable, toks3) <- result.try(parse_globaltype(toks2))
  case imp {
    Some(#(m, n)) ->
      Ok(
        BState(
          ..st,
          imports: [
            ast.Import(m, n, ast.ImportGlobal(ty, mutable)),
            ..st.imports
          ],
          exports: add_exports(st.exports, exports),
          cur_global: idx + 1,
        ),
      )
    None -> {
      use #(init, leftover, types1) <- result.try(parse_seq(
        toks3,
        st.env,
        [],
        st.types,
      ))
      case leftover {
        [] ->
          Ok(
            BState(
              ..st,
              types: types1,
              globals: [ast.Global(ty, mutable, init), ..st.globals],
              exports: add_exports(st.exports, exports),
              cur_global: idx + 1,
            ),
          )
        [t, ..] -> Error(UnexpectedToken(tok_pos(t), ")", describe(t)))
      }
    }
  }
}

/// Parse a `globaltype` = `<valtype>` (const) or `(mut <valtype>)` (var).
fn parse_globaltype(
  toks: List(Token),
) -> Result(#(ast.ValType, Bool, List(Token)), WatError) {
  case peek_group_head(toks) {
    Some("mut") -> {
      use #(inside, rest) <- result.try(take_group(toks))
      case drop_head(inside) {
        [vt] -> {
          use v <- result.try(parse_valtype(vt))
          Ok(#(v, True, rest))
        }
        _ -> Error(UnexpectedEof("(mut <valtype>)"))
      }
    }
    _ ->
      case toks {
        [vt, ..rest] -> {
          use v <- result.try(parse_valtype(vt))
          Ok(#(v, False, rest))
        }
        [] -> Error(UnexpectedEof("global type"))
      }
  }
}

// --- import (explicit field) ----------------------------------------------

fn b_import(rest: List(Token), st: BState) -> Result(BState, WatError) {
  case rest {
    [Str(_, mb), Str(_, nb), ..r2] -> {
      use m <- result.try(str_to_name(mb, header_pos(rest)))
      use n <- result.try(str_to_name(nb, header_pos(rest)))
      use #(desc, _) <- result.try(take_group(r2))
      case desc {
        [Keyword(_, "func"), ..dr] -> {
          let dr1 = drop_leading_id(dr)
          use #(opt_type, params, results, _) <- result.try(parse_typeuse_parts(
            dr1,
            st.env,
          ))
          use #(type_idx, _, types1) <- result.try(finalize_typeuse(
            opt_type,
            params,
            results,
            st.types,
            header_pos(dr),
          ))
          Ok(
            BState(
              ..st,
              types: types1,
              imports: [
                ast.Import(m, n, ast.ImportFunc(type_idx)),
                ..st.imports
              ],
              cur_func: st.cur_func + 1,
            ),
          )
        }
        [Keyword(_, "table"), ..dr] -> {
          use #(tt, _) <- result.try(parse_tabletype(drop_leading_id(dr)))
          Ok(
            BState(
              ..st,
              imports: [ast.Import(m, n, ast.ImportTable(tt)), ..st.imports],
              cur_table: st.cur_table + 1,
            ),
          )
        }
        [Keyword(_, "memory"), ..dr] -> {
          use #(mt, _) <- result.try(parse_memtype(drop_leading_id(dr)))
          Ok(
            BState(
              ..st,
              imports: [ast.Import(m, n, ast.ImportMemory(mt)), ..st.imports],
              cur_mem: st.cur_mem + 1,
            ),
          )
        }
        [Keyword(_, "global"), ..dr] -> {
          use #(ty, mutable, _) <- result.try(
            parse_globaltype(drop_leading_id(dr)),
          )
          Ok(
            BState(
              ..st,
              imports: [
                ast.Import(m, n, ast.ImportGlobal(ty, mutable)),
                ..st.imports
              ],
              cur_global: st.cur_global + 1,
            ),
          )
        }
        [t, ..] -> Error(UnexpectedToken(tok_pos(t), "importdesc", describe(t)))
        [] -> Error(UnexpectedEof("importdesc"))
      }
    }
    _ -> Error(UnexpectedEof("import module/name strings"))
  }
}

// --- export (explicit field) ----------------------------------------------

fn b_export(rest: List(Token), st: BState) -> Result(BState, WatError) {
  case rest {
    [Str(sp, nb), ..r2] -> {
      use name <- result.try(str_to_name(nb, sp))
      use #(inside, _) <- result.try(take_group(r2))
      case inside {
        [Keyword(_, kind_kw), ref_tok] -> {
          use #(kind, map) <- result.try(export_kind(
            kind_kw,
            st.env,
            tok_pos(ref_tok),
          ))
          use index <- result.try(resolve_ref(ref_tok, map, kind_kw))
          Ok(
            BState(..st, exports: [ast.Export(name, kind, index), ..st.exports]),
          )
        }
        _ -> Error(UnexpectedEof("export descriptor"))
      }
    }
    _ -> Error(UnexpectedEof("export name"))
  }
}

fn export_kind(
  kw: String,
  env: Env,
  pos: Pos,
) -> Result(#(ast.ExportKind, NameMap), WatError) {
  case kw {
    "func" -> Ok(#(ast.ExportFunc, env.funcs))
    "table" -> Ok(#(ast.ExportTable, env.tables))
    "memory" -> Ok(#(ast.ExportMemory, env.mems))
    "global" -> Ok(#(ast.ExportGlobal, env.globals))
    _ -> Error(UnexpectedToken(pos, "export kind", kw))
  }
}

// --- start ----------------------------------------------------------------

fn b_start(rest: List(Token), st: BState) -> Result(BState, WatError) {
  case rest {
    [tok] -> {
      use idx <- result.try(resolve_ref(tok, st.env.funcs, "func"))
      Ok(BState(..st, start: Some(idx)))
    }
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "single funcidx", describe(t)))
    [] -> Error(UnexpectedEof("start funcidx"))
  }
}

// --- small token/group helpers --------------------------------------------

fn peek_group_head(toks: List(Token)) -> Option(String) {
  case toks {
    [LParen(_), Keyword(_, kw), ..] -> Some(kw)
    _ -> None
  }
}

fn drop_head(toks: List(Token)) -> List(Token) {
  case toks {
    [_, ..r] -> r
    [] -> []
  }
}

fn is_reftype_kw(kw: String) -> Bool {
  kw == "funcref" || kw == "externref" || kw == "anyfunc"
}

fn reftype_of(kw: String, pos: Pos) -> Result(ast.ValType, WatError) {
  case kw {
    "funcref" -> Ok(ast.FuncRef)
    "anyfunc" -> Ok(ast.FuncRef)
    "externref" -> Ok(ast.ExternRef)
    "v128" -> Error(Unsupported(pos, Simd, "v128"))
    _ -> Error(UnexpectedToken(pos, "reftype", kw))
  }
}

/// Parse one value type from a single token. `v128` → `Unsupported(Simd)`; a
/// group (e.g. a GC `(ref $t)`) → `Unsupported(Gc)`; any other → error.
fn parse_valtype(t: Token) -> Result(ast.ValType, WatError) {
  case t {
    Keyword(_, "i32") -> Ok(ast.I32)
    Keyword(_, "i64") -> Ok(ast.I64)
    Keyword(_, "f32") -> Ok(ast.F32)
    Keyword(_, "f64") -> Ok(ast.F64)
    Keyword(_, "funcref") -> Ok(ast.FuncRef)
    Keyword(_, "externref") -> Ok(ast.ExternRef)
    Keyword(_, "anyfunc") -> Ok(ast.FuncRef)
    Keyword(p, "v128") -> Error(Unsupported(p, Simd, "v128"))
    LParen(p) -> Error(Unsupported(p, Gc, "reference type"))
    _ -> Error(UnexpectedToken(tok_pos(t), "valtype", describe(t)))
  }
}

fn parse_valtype_list(
  toks: List(Token),
) -> Result(List(ast.ValType), WatError) {
  case toks {
    [] -> Ok([])
    [t, ..rest] -> {
      use v <- result.try(parse_valtype(t))
      use more <- result.try(parse_valtype_list(rest))
      Ok([v, ..more])
    }
  }
}

/// Resolve an index reference token (`Num` literal or `$id`) against `map`.
fn resolve_ref(
  tok: Token,
  map: NameMap,
  space: String,
) -> Result(Int, WatError) {
  case tok {
    Num(p, lex) -> uint_value(lex, 32, p)
    Id(p, name) ->
      case dict.get(map, name) {
        Ok(i) -> Ok(i)
        Error(_) -> Error(UnboundIdentifier(p, space, name))
      }
    _ -> Error(UnexpectedToken(tok_pos(tok), space <> " index", describe(tok)))
  }
}

fn resolve_type_ref(tok: Token, env: Env) -> Result(Int, WatError) {
  resolve_ref(tok, env.types, "type")
}

fn find_type_index(
  types: List(ast.FuncType),
  ft: ast.FuncType,
  i: Int,
) -> Option(Int) {
  case types {
    [] -> None
    [x, ..rest] ->
      case x == ft {
        True -> Some(i)
        False -> find_type_index(rest, ft, i + 1)
      }
  }
}

// --- functype / typeuse ---------------------------------------------------

/// Parse a `(func (param …)* (result …)*)` group into a `FuncType`.
fn parse_functype_group(
  toks: List(Token),
) -> Result(#(ast.FuncType, List(Token)), WatError) {
  use #(inside, rest) <- result.try(take_group(toks))
  case inside {
    [Keyword(_, "func"), ..body] -> {
      use #(params, r1) <- result.try(parse_params(body))
      use #(results, r2) <- result.try(parse_results(r1))
      case r2 {
        [] ->
          Ok(#(ast.FuncType(list.map(params, fn(p) { p.1 }), results), rest))
        [t, ..] -> Error(UnexpectedToken(tok_pos(t), ")", describe(t)))
      }
    }
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "func", describe(t)))
    [] -> Error(UnexpectedEof("(func …)"))
  }
}

fn parse_params(
  toks: List(Token),
) -> Result(#(List(#(Option(String), ast.ValType)), List(Token)), WatError) {
  case peek_group_head(toks) {
    Some("param") -> {
      use #(inside, rest) <- result.try(take_group(toks))
      use ps <- result.try(parse_param_body(drop_head(inside)))
      use #(more, rest2) <- result.try(parse_params(rest))
      Ok(#(list.append(ps, more), rest2))
    }
    _ -> Ok(#([], toks))
  }
}

fn parse_param_body(
  toks: List(Token),
) -> Result(List(#(Option(String), ast.ValType)), WatError) {
  case toks {
    [Id(_, n), vt] -> {
      use v <- result.try(parse_valtype(vt))
      Ok([#(Some(n), v)])
    }
    [Id(p, _), ..] ->
      Error(UnexpectedToken(p, "single valtype after named param", "extra"))
    _ -> {
      use vts <- result.try(parse_valtype_list(toks))
      Ok(list.map(vts, fn(v) { #(None, v) }))
    }
  }
}

fn parse_results(
  toks: List(Token),
) -> Result(#(List(ast.ValType), List(Token)), WatError) {
  case peek_group_head(toks) {
    Some("result") -> {
      use #(inside, rest) <- result.try(take_group(toks))
      use vts <- result.try(parse_valtype_list(drop_head(inside)))
      use #(more, rest2) <- result.try(parse_results(rest))
      Ok(#(list.append(vts, more), rest2))
    }
    _ -> Ok(#([], toks))
  }
}

fn parse_opt_type(
  toks: List(Token),
  env: Env,
) -> Result(#(Option(Int), List(Token)), WatError) {
  case peek_group_head(toks) {
    Some("type") -> {
      use #(inside, rest) <- result.try(take_group(toks))
      case inside {
        [Keyword(_, "type"), tok] -> {
          use idx <- result.try(resolve_type_ref(tok, env))
          Ok(#(Some(idx), rest))
        }
        [Keyword(p, "type"), ..] ->
          Error(UnexpectedToken(p, "single type index", "extra"))
        _ -> Error(UnexpectedEof("(type …)"))
      }
    }
    _ -> Ok(#(None, toks))
  }
}

/// Parse a type-use: optional `(type $x)` then inline `(param …)* (result …)*`.
fn parse_typeuse_parts(
  toks: List(Token),
  env: Env,
) -> Result(
  #(
    Option(Int),
    List(#(Option(String), ast.ValType)),
    List(ast.ValType),
    List(Token),
  ),
  WatError,
) {
  use #(opt, t1) <- result.try(parse_opt_type(toks, env))
  use #(params, t2) <- result.try(parse_params(t1))
  use #(results, t3) <- result.try(parse_results(t2))
  Ok(#(opt, params, results, t3))
}

/// Resolve a type-use to a concrete type index, deduping/appending an implicit
/// type when only inline `(param)/(result)` are given (spec type-use rules).
/// Returns the index, the parameter types (for local indexing), and the updated
/// type list.
fn finalize_typeuse(
  opt: Option(Int),
  params: List(#(Option(String), ast.ValType)),
  results: List(ast.ValType),
  types: List(ast.FuncType),
  pos: Pos,
) -> Result(#(Int, List(ast.ValType), List(ast.FuncType)), WatError) {
  let ptypes = list.map(params, fn(p) { p.1 })
  case opt {
    Some(idx) ->
      case list_at(types, idx) {
        Ok(ft) ->
          case params == [] && results == [] {
            True -> Ok(#(idx, ft.params, types))
            False ->
              case ft == ast.FuncType(ptypes, results) {
                True -> Ok(#(idx, ptypes, types))
                False -> Error(InlineTypeMismatch(pos))
              }
          }
        Error(_) ->
          case params == [] && results == [] {
            True -> Ok(#(idx, [], types))
            False -> Ok(#(idx, ptypes, types))
          }
      }
    None -> {
      let ft = ast.FuncType(ptypes, results)
      case find_type_index(types, ft, 0) {
        Some(i) -> Ok(#(i, ptypes, types))
        None -> Ok(#(list.length(types), ptypes, list.append(types, [ft])))
      }
    }
  }
}

/// Resolve a structured-control blocktype: `(type $x)` → `BlockTypeIdx`; a single
/// `(result t)` with no params/type → the `BlockVal(t)` shorthand; empty →
/// `BlockEmpty`; otherwise a type-use (dedup/append) → `BlockTypeIdx`.
fn finalize_blocktype(
  opt: Option(Int),
  params: List(#(Option(String), ast.ValType)),
  results: List(ast.ValType),
  types: List(ast.FuncType),
  pos: Pos,
) -> Result(#(ast.BlockType, List(ast.FuncType)), WatError) {
  let ptypes = list.map(params, fn(p) { p.1 })
  case opt {
    Some(idx) ->
      case params == [] && results == [] {
        True -> Ok(#(ast.BlockTypeIdx(idx), types))
        False ->
          case list_at(types, idx) {
            Ok(ft) ->
              case ft == ast.FuncType(ptypes, results) {
                True -> Ok(#(ast.BlockTypeIdx(idx), types))
                False -> Error(InlineTypeMismatch(pos))
              }
            Error(_) -> Ok(#(ast.BlockTypeIdx(idx), types))
          }
      }
    None ->
      case ptypes, results {
        [], [] -> Ok(#(ast.BlockEmpty, types))
        [], [t] -> Ok(#(ast.BlockVal(t), types))
        _, _ -> {
          let ft = ast.FuncType(ptypes, results)
          case find_type_index(types, ft, 0) {
            Some(i) -> Ok(#(ast.BlockTypeIdx(i), types))
            None ->
              Ok(#(
                ast.BlockTypeIdx(list.length(types)),
                list.append(types, [ft]),
              ))
          }
        }
      }
  }
}

// --- elem / data segments -------------------------------------------------

fn concat_strings(toks: List(Token)) -> Result(BitArray, WatError) {
  list.try_fold(toks, <<>>, fn(acc, t) {
    case t {
      Str(_, b) -> Ok(bit_array.append(acc, b))
      _ -> Error(UnexpectedToken(tok_pos(t), "string literal", describe(t)))
    }
  })
}

/// Parse an element segment field (spec `text/modules.html#element-segments`):
/// passive / active (`(table …)?(offset …)|<expr>`) / declarative, with either a
/// `func`/bare funcidx list (`ElemFuncs`) or a `<reftype> (item …)*` /
/// bare-expr list (`ElemExprs`).
fn b_elem(rest: List(Token), st: BState) -> Result(BState, WatError) {
  let idx = st.cur_elem
  let toks1 = drop_leading_id(rest)
  case toks1 {
    [Keyword(_, "declare"), ..r] -> {
      use init <- result.try(parse_elem_items(r, ast.FuncRef, st.env))
      finish_elem(
        st,
        idx,
        ast.ElemDeclarative,
        elem_ref_ty(init, ast.FuncRef),
        init,
      )
    }
    _ -> {
      // Active if a (table …) or an offset expr / bare (instr) leads.
      case peek_group_head(toks1) {
        Some("table") -> {
          use #(inside, r1) <- result.try(take_group(toks1))
          use table <- result.try(case drop_head(inside) {
            [tok] -> resolve_ref(tok, st.env.tables, "table")
            _ -> Error(UnexpectedEof("(table idx)"))
          })
          use #(offset, r2) <- result.try(parse_elem_offset(
            r1,
            st.env,
            st.types,
          ))
          use init <- result.try(parse_elem_items(r2, ast.FuncRef, st.env))
          finish_elem(
            st,
            idx,
            ast.ElemActive(table, offset),
            elem_ref_ty(init, ast.FuncRef),
            init,
          )
        }
        Some("offset") -> {
          use #(offset, r2) <- result.try(parse_elem_offset(
            toks1,
            st.env,
            st.types,
          ))
          use init <- result.try(parse_elem_items(r2, ast.FuncRef, st.env))
          finish_elem(
            st,
            idx,
            ast.ElemActive(0, offset),
            elem_ref_ty(init, ast.FuncRef),
            init,
          )
        }
        Some(_) -> {
          // A bare folded `(instr)` offset (active table 0) — but NOT a reftype
          // item list. Distinguish: `funcref`/`externref` keyword or `func`/bare
          // funcidx begins the elemlist (passive); anything else is the offset.
          case toks1 {
            [Keyword(_, kw), ..] ->
              case kw == "func" || is_reftype_kw(kw) {
                True -> {
                  use init <- result.try(parse_elem_items(
                    toks1,
                    ast.FuncRef,
                    st.env,
                  ))
                  finish_elem(
                    st,
                    idx,
                    ast.ElemPassive,
                    elem_ref_ty(init, ast.FuncRef),
                    init,
                  )
                }
                False ->
                  Error(UnexpectedToken(header_pos(toks1), "elem list", kw))
              }
            _ -> {
              use #(offset, r2) <- result.try(parse_elem_offset(
                toks1,
                st.env,
                st.types,
              ))
              use init <- result.try(parse_elem_items(r2, ast.FuncRef, st.env))
              finish_elem(
                st,
                idx,
                ast.ElemActive(0, offset),
                elem_ref_ty(init, ast.FuncRef),
                init,
              )
            }
          }
        }
        None -> {
          // Passive: `func $f*` / bare `$f*` / `<reftype> (item …)*`.
          use init <- result.try(parse_elem_items(toks1, ast.FuncRef, st.env))
          finish_elem(
            st,
            idx,
            ast.ElemPassive,
            elem_ref_ty(init, ast.FuncRef),
            init,
          )
        }
      }
    }
  }
}

fn finish_elem(
  st: BState,
  idx: Int,
  mode: ast.ElemMode,
  ref_ty: ast.ValType,
  init: ast.ElemInit,
) -> Result(BState, WatError) {
  Ok(
    BState(
      ..st,
      elements: [ast.ElementSegment(mode, ref_ty, init), ..st.elements],
      cur_elem: idx + 1,
    ),
  )
}

/// Parse an element offset: `(offset <expr>)` or a bare folded `(<instr>)`.
fn parse_elem_offset(
  toks: List(Token),
  env: Env,
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token)), WatError) {
  case peek_group_head(toks) {
    Some("offset") -> {
      use #(inside, rest) <- result.try(take_group(toks))
      use #(instrs, leftover, _) <- result.try(parse_seq(
        drop_head(inside),
        env,
        [],
        types,
      ))
      case leftover {
        [] -> Ok(#(instrs, rest))
        [t, ..] -> Error(UnexpectedToken(tok_pos(t), ")", describe(t)))
      }
    }
    _ ->
      // A single bare folded instruction is the offset.
      case toks {
        [LParen(_), ..] -> {
          use #(inside, rest) <- result.try(take_group(toks))
          use #(instrs, leftover, _) <- result.try(parse_seq(
            reparen(inside),
            env,
            [],
            types,
          ))
          case leftover {
            [] -> Ok(#(instrs, rest))
            [t, ..] -> Error(UnexpectedToken(tok_pos(t), ")", describe(t)))
          }
        }
        [t, ..] ->
          Error(UnexpectedToken(tok_pos(t), "offset expression", describe(t)))
        [] -> Error(UnexpectedEof("offset expression"))
      }
  }
}

/// Re-wrap a group's inside tokens as a single folded expression so `parse_seq`
/// treats the whole `(instr …)` as one operand (used for bare-offset abbrevs).
fn reparen(inside: List(Token)) -> List(Token) {
  [LParen(Pos(0, 0)), ..list.append(inside, [RParen(Pos(0, 0))])]
}

/// Parse an element segment's init list. `func $f*` / bare `$f*` → `ElemFuncs`;
/// `<reftype> (item <expr>)* | (<instr>)*` → `ElemExprs`.
fn parse_elem_items(
  toks: List(Token),
  _default: ast.ValType,
  env: Env,
) -> Result(ast.ElemInit, WatError) {
  case toks {
    [Keyword(_, "func"), ..rest] -> {
      use funcs <- result.try(resolve_funcidx_list(rest, env))
      Ok(ast.ElemFuncs(funcs))
    }
    [Keyword(rp, rk), ..rest] ->
      case is_reftype_kw(rk) {
        True -> {
          use _reft <- result.try(reftype_of(rk, rp))
          use exprs <- result.try(parse_elem_exprs(rest, env))
          Ok(ast.ElemExprs(exprs))
        }
        False -> Error(UnexpectedToken(rp, "func or reftype", rk))
      }
    [Id(_, _), ..] -> {
      use funcs <- result.try(resolve_funcidx_list(toks, env))
      Ok(ast.ElemFuncs(funcs))
    }
    [Num(_, _), ..] -> {
      use funcs <- result.try(resolve_funcidx_list(toks, env))
      Ok(ast.ElemFuncs(funcs))
    }
    [] -> Ok(ast.ElemFuncs([]))
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "element items", describe(t)))
  }
}

fn resolve_funcidx_list(
  toks: List(Token),
  env: Env,
) -> Result(List(Int), WatError) {
  case toks {
    [] -> Ok([])
    [tok, ..rest] -> {
      use i <- result.try(resolve_ref(tok, env.funcs, "func"))
      use more <- result.try(resolve_funcidx_list(rest, env))
      Ok([i, ..more])
    }
  }
}

fn parse_elem_exprs(
  toks: List(Token),
  env: Env,
) -> Result(List(List(ast.Instr)), WatError) {
  case toks {
    [] -> Ok([])
    [LParen(_), ..] -> {
      use #(inside, rest) <- result.try(take_group(toks))
      use one <- result.try(case inside {
        [Keyword(_, "item"), ..body] -> parse_const_expr(body, env)
        _ -> parse_const_expr(reparen(inside), env)
      })
      use more <- result.try(parse_elem_exprs(rest, env))
      Ok([one, ..more])
    }
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "(item …)", describe(t)))
  }
}

fn parse_const_expr(
  toks: List(Token),
  env: Env,
) -> Result(List(ast.Instr), WatError) {
  use #(instrs, leftover, _) <- result.try(parse_seq(toks, env, [], []))
  case leftover {
    [] -> Ok(instrs)
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), ")", describe(t)))
  }
}

/// Parse a data segment field: active `(memory $m)?(offset …)|<expr>` or passive,
/// with the payload = concatenation of string literals.
fn b_data(rest: List(Token), st: BState) -> Result(BState, WatError) {
  let idx = st.cur_data
  let toks1 = drop_leading_id(rest)
  case peek_group_head(toks1) {
    Some("memory") -> {
      use #(inside, r1) <- result.try(take_group(toks1))
      use mem <- result.try(case drop_head(inside) {
        [tok] -> resolve_ref(tok, st.env.mems, "memory")
        _ -> Error(UnexpectedEof("(memory idx)"))
      })
      use #(offset, r2) <- result.try(parse_elem_offset(r1, st.env, st.types))
      use bytes <- result.try(concat_strings(r2))
      finish_data(st, idx, ast.DataActive(mem, offset), bytes)
    }
    Some("offset") -> {
      use #(offset, r2) <- result.try(parse_elem_offset(toks1, st.env, st.types))
      use bytes <- result.try(concat_strings(r2))
      finish_data(st, idx, ast.DataActive(0, offset), bytes)
    }
    Some(_) -> {
      // A bare folded `(instr)` offset (active mem 0).
      use #(offset, r2) <- result.try(parse_elem_offset(toks1, st.env, st.types))
      use bytes <- result.try(concat_strings(r2))
      finish_data(st, idx, ast.DataActive(0, offset), bytes)
    }
    None -> {
      use bytes <- result.try(concat_strings(toks1))
      finish_data(st, idx, ast.DataPassive, bytes)
    }
  }
}

fn finish_data(
  st: BState,
  idx: Int,
  mode: ast.DataMode,
  bytes: BitArray,
) -> Result(BState, WatError) {
  Ok(
    BState(
      ..st,
      data: [ast.DataSegment(mode, bytes), ..st.data],
      cur_data: idx + 1,
    ),
  )
}

// ===========================================================================
// F. Instructions — folded & flat, blocktypes, labels, the mnemonic map
// ===========================================================================
//
// A function body is a sequence of instructions in either notation, freely
// mixed. `parse_seq` consumes instructions until a non-instruction token (`)`,
// `end`, `else`, `then`, or EOF). A folded expression `(op operand*)` flattens
// post-order (operands first, then the head). Structured control pushes/pops the
// label stack so `$l` resolves to a relative depth. `types` threads through so
// inline type-uses (call_indirect / block-with-params) dedup/append in
// depth-first source order.

fn parse_seq(
  toks: List(Token),
  env: Env,
  labels: List(Option(String)),
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  case toks {
    [] -> Ok(#([], [], types))
    [RParen(_), ..] -> Ok(#([], toks, types))
    [Keyword(_, kw), ..] if kw == "end" || kw == "else" || kw == "then" ->
      Ok(#([], toks, types))
    [LParen(_), ..] -> {
      use #(inside, rest) <- result.try(take_group(toks))
      use #(finstrs, types1) <- result.try(parse_folded(
        inside,
        env,
        labels,
        types,
      ))
      use #(more, rest2, types2) <- result.try(parse_seq(
        rest,
        env,
        labels,
        types1,
      ))
      Ok(#(list.append(finstrs, more), rest2, types2))
    }
    [Keyword(pos, kw), ..rest] -> {
      use #(instrs, rest2, types1) <- result.try(parse_flat(
        kw,
        pos,
        rest,
        env,
        labels,
        types,
      ))
      use #(more, rest3, types2) <- result.try(parse_seq(
        rest2,
        env,
        labels,
        types1,
      ))
      Ok(#(list.append(instrs, more), rest3, types2))
    }
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "instruction", describe(t)))
  }
}

/// Parse the flattened instruction stream of a single folded expression (the
/// tokens INSIDE its parens, starting with the head keyword).
fn parse_folded(
  inside: List(Token),
  env: Env,
  labels: List(Option(String)),
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(ast.FuncType)), WatError) {
  case inside {
    [Keyword(pos, kw), ..rest] ->
      case kw {
        "block" -> parse_folded_block(ast.Block, pos, rest, env, labels, types)
        "loop" -> parse_folded_block(ast.Loop, pos, rest, env, labels, types)
        "if" -> parse_folded_if(pos, rest, env, labels, types)
        _ -> {
          use #(head, rest_imm, types1) <- result.try(parse_flat(
            kw,
            pos,
            rest,
            env,
            labels,
            types,
          ))
          use #(operands, leftover, types2) <- result.try(parse_seq(
            rest_imm,
            env,
            labels,
            types1,
          ))
          case leftover {
            [] -> Ok(#(list.append(operands, head), types2))
            [t, ..] -> Error(UnexpectedToken(tok_pos(t), ")", describe(t)))
          }
        }
      }
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "instruction", describe(t)))
    [] -> Error(UnexpectedEof("instruction"))
  }
}

fn parse_folded_block(
  ctor: fn(ast.BlockType) -> ast.Instr,
  _pos: Pos,
  rest: List(Token),
  env: Env,
  labels: List(Option(String)),
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(ast.FuncType)), WatError) {
  let #(label, r1) = take_label(rest)
  use #(bt, r2, types1) <- result.try(parse_blocktype(r1, env, types))
  use #(body, leftover, types2) <- result.try(parse_seq(
    r2,
    env,
    [label, ..labels],
    types1,
  ))
  case leftover {
    [] -> Ok(#(list.flatten([[ctor(bt)], body, [ast.End]]), types2))
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), ")", describe(t)))
  }
}

fn parse_folded_if(
  _pos: Pos,
  rest: List(Token),
  env: Env,
  labels: List(Option(String)),
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(ast.FuncType)), WatError) {
  let #(label, r1) = take_label(rest)
  use #(bt, r2, types1) <- result.try(parse_blocktype(r1, env, types))
  let labels2 = [label, ..labels]
  use #(cond, then_body_toks, else_toks, types2) <- result.try(
    parse_folded_if_tail(r2, env, labels, types1),
  )
  use #(then_body, _, types3) <- result.try(parse_seq(
    then_body_toks,
    env,
    labels2,
    types2,
  ))
  case else_toks {
    Some(et) -> {
      use #(else_body, _, types4) <- result.try(parse_seq(
        et,
        env,
        labels2,
        types3,
      ))
      Ok(#(
        list.flatten([
          cond,
          [ast.If(bt)],
          then_body,
          [ast.Else],
          else_body,
          [ast.End],
        ]),
        types4,
      ))
    }
    None ->
      Ok(#(list.flatten([cond, [ast.If(bt)], then_body, [ast.End]]), types3))
  }
}

/// Collect a folded-`if`'s condition operands until the `(then …)` clause,
/// returning the flattened condition, the `then` body tokens, and the optional
/// `else` body tokens.
fn parse_folded_if_tail(
  toks: List(Token),
  env: Env,
  labels: List(Option(String)),
  types: List(ast.FuncType),
) -> Result(
  #(List(ast.Instr), List(Token), Option(List(Token)), List(ast.FuncType)),
  WatError,
) {
  case peek_group_head(toks) {
    Some("then") -> {
      use #(then_group, rest) <- result.try(take_group(toks))
      let then_body = drop_head(then_group)
      case peek_group_head(rest) {
        Some("else") -> {
          use #(else_group, _) <- result.try(take_group(rest))
          Ok(#([], then_body, Some(drop_head(else_group)), types))
        }
        _ -> Ok(#([], then_body, None, types))
      }
    }
    Some(_) -> {
      use #(inside, rest) <- result.try(take_group(toks))
      use #(finstrs, types1) <- result.try(parse_folded(
        inside,
        env,
        labels,
        types,
      ))
      use #(more, tb, eb, types2) <- result.try(parse_folded_if_tail(
        rest,
        env,
        labels,
        types1,
      ))
      Ok(#(list.append(finstrs, more), tb, eb, types2))
    }
    None ->
      case toks {
        [] -> Error(UnexpectedEof("(then …) in folded if"))
        [Keyword(kpos, kw), ..krest] -> {
          use #(instrs, rest, types1) <- result.try(parse_flat(
            kw,
            kpos,
            krest,
            env,
            labels,
            types,
          ))
          use #(more, tb, eb, types2) <- result.try(parse_folded_if_tail(
            rest,
            env,
            labels,
            types1,
          ))
          Ok(#(list.append(instrs, more), tb, eb, types2))
        }
        [t, ..] -> Error(UnexpectedToken(tok_pos(t), "(then …)", describe(t)))
      }
  }
}

fn parse_blocktype(
  toks: List(Token),
  env: Env,
  types: List(ast.FuncType),
) -> Result(#(ast.BlockType, List(Token), List(ast.FuncType)), WatError) {
  use #(opt, params, results, rest) <- result.try(parse_typeuse_parts(toks, env))
  use #(bt, types1) <- result.try(finalize_blocktype(
    opt,
    params,
    results,
    types,
    header_pos(toks),
  ))
  Ok(#(bt, rest, types1))
}

fn take_label(toks: List(Token)) -> #(Option(String), List(Token)) {
  case toks {
    [Id(_, n), ..r] -> #(Some(n), r)
    _ -> #(None, toks)
  }
}

/// The flat mnemonic dispatch. Structured control (`block`/`loop`/`if`) is the
/// FLAT form (consuming to `end`); everything else routes through `parse_plain`.
fn parse_flat(
  kw: String,
  pos: Pos,
  toks: List(Token),
  env: Env,
  labels: List(Option(String)),
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  case kw {
    "block" -> flat_block(ast.Block, pos, toks, env, labels, types)
    "loop" -> flat_block(ast.Loop, pos, toks, env, labels, types)
    "if" -> flat_if(pos, toks, env, labels, types)
    "end" -> Error(UnexpectedToken(pos, "instruction", "end"))
    "else" -> Error(UnexpectedToken(pos, "instruction", "else"))
    _ -> parse_plain(kw, pos, toks, env, labels, types)
  }
}

fn flat_block(
  ctor: fn(ast.BlockType) -> ast.Instr,
  pos: Pos,
  toks: List(Token),
  env: Env,
  labels: List(Option(String)),
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  let #(label, r1) = take_label(toks)
  use #(bt, r2, types1) <- result.try(parse_blocktype(r1, env, types))
  use #(body, r3, types2) <- result.try(parse_seq(
    r2,
    env,
    [label, ..labels],
    types1,
  ))
  case r3 {
    [Keyword(_, "end"), ..r4] -> {
      let #(close_label, r5) = take_label(r4)
      use _ <- result.try(check_label_match(label, close_label, pos))
      Ok(#(list.flatten([[ctor(bt)], body, [ast.End]]), r5, types2))
    }
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "end", describe(t)))
    [] -> Error(UnexpectedEof("end"))
  }
}

fn flat_if(
  pos: Pos,
  toks: List(Token),
  env: Env,
  labels: List(Option(String)),
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  let #(label, r1) = take_label(toks)
  use #(bt, r2, types1) <- result.try(parse_blocktype(r1, env, types))
  let labels2 = [label, ..labels]
  use #(then_body, r3, types2) <- result.try(parse_seq(r2, env, labels2, types1))
  case r3 {
    [Keyword(_, "else"), ..r4] -> {
      let #(else_label, r5) = take_label(r4)
      use _ <- result.try(check_label_match(label, else_label, pos))
      use #(else_body, r6, types3) <- result.try(parse_seq(
        r5,
        env,
        labels2,
        types2,
      ))
      case r6 {
        [Keyword(_, "end"), ..r7] -> {
          let #(cl, r8) = take_label(r7)
          use _ <- result.try(check_label_match(label, cl, pos))
          Ok(#(
            list.flatten([
              [ast.If(bt)],
              then_body,
              [ast.Else],
              else_body,
              [ast.End],
            ]),
            r8,
            types3,
          ))
        }
        [t, ..] -> Error(UnexpectedToken(tok_pos(t), "end", describe(t)))
        [] -> Error(UnexpectedEof("end"))
      }
    }
    [Keyword(_, "end"), ..r4] -> {
      let #(cl, r5) = take_label(r4)
      use _ <- result.try(check_label_match(label, cl, pos))
      Ok(#(list.flatten([[ast.If(bt)], then_body, [ast.End]]), r5, types2))
    }
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "else or end", describe(t)))
    [] -> Error(UnexpectedEof("else or end"))
  }
}

fn check_label_match(
  open: Option(String),
  close: Option(String),
  pos: Pos,
) -> Result(Nil, WatError) {
  case close {
    None -> Ok(Nil)
    Some(c) ->
      case open {
        Some(o) if o == c -> Ok(Nil)
        _ -> Error(MismatchedLabel(pos, open, close))
      }
  }
}

fn parse_plain(
  kw: String,
  pos: Pos,
  toks: List(Token),
  env: Env,
  labels: List(Option(String)),
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  case simple_instr(kw) {
    Ok(instr) -> Ok(#([instr], toks, types))
    Error(_) -> parse_immediate_instr(kw, pos, toks, env, labels, types)
  }
}

fn one(
  i: ast.Instr,
  r: List(Token),
  t: List(ast.FuncType),
) -> #(List(ast.Instr), List(Token), List(ast.FuncType)) {
  #([i], r, t)
}

/// Parse an instruction that carries immediates (indices, labels, memargs,
/// consts, type-uses). Unknown mnemonics categorise as SIMD/GC or
/// `UnknownMnemonic`.
fn parse_immediate_instr(
  kw: String,
  pos: Pos,
  toks: List(Token),
  env: Env,
  labels: List(Option(String)),
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  case kw {
    "i32.const" -> const_instr(toks, types, pos, 32, ConstInt)
    "i64.const" -> const_instr(toks, types, pos, 64, ConstInt)
    "f32.const" -> const_instr(toks, types, pos, 32, ConstF32)
    "f64.const" -> const_instr(toks, types, pos, 64, ConstF64)
    "local.get" -> one_idx(toks, env.locals, "local", ast.LocalGet, types)
    "local.set" -> one_idx(toks, env.locals, "local", ast.LocalSet, types)
    "local.tee" -> one_idx(toks, env.locals, "local", ast.LocalTee, types)
    "global.get" -> one_idx(toks, env.globals, "global", ast.GlobalGet, types)
    "global.set" -> one_idx(toks, env.globals, "global", ast.GlobalSet, types)
    "call" -> one_idx(toks, env.funcs, "func", ast.Call, types)
    // tail-call proposal (Q13): `return_call`/`return_call_indirect` share the
    // exact index / typeuse resolution machinery of `call`/`call_indirect`.
    "return_call" -> one_idx(toks, env.funcs, "func", ast.ReturnCall, types)
    "ref.func" -> one_idx(toks, env.funcs, "func", ast.RefFunc, types)
    "br" -> label_instr(toks, labels, ast.Br, types)
    "br_if" -> label_instr(toks, labels, ast.BrIf, types)
    "br_table" -> br_table_instr(toks, labels, types)
    "call_indirect" ->
      call_indirect_instr(toks, env, types, pos, ast.CallIndirect)
    "return_call_indirect" ->
      call_indirect_instr(toks, env, types, pos, ast.ReturnCallIndirect)
    "select" -> select_instr(toks, types)
    "ref.null" -> ref_null_instr(toks, types)
    "memory.size" ->
      opt_idx_instr(toks, env.mems, "memory", ast.MemorySize, types)
    "memory.grow" ->
      opt_idx_instr(toks, env.mems, "memory", ast.MemoryGrow, types)
    "memory.fill" ->
      opt_idx_instr(toks, env.mems, "memory", ast.MemoryFill, types)
    "table.get" -> opt_idx_instr(toks, env.tables, "table", ast.TableGet, types)
    "table.set" -> opt_idx_instr(toks, env.tables, "table", ast.TableSet, types)
    "table.size" ->
      opt_idx_instr(toks, env.tables, "table", ast.TableSize, types)
    "table.grow" ->
      opt_idx_instr(toks, env.tables, "table", ast.TableGrow, types)
    "table.fill" ->
      opt_idx_instr(toks, env.tables, "table", ast.TableFill, types)
    "data.drop" -> one_idx(toks, env.datas, "data", ast.DataDrop, types)
    "elem.drop" -> one_idx(toks, env.elems, "elem", ast.ElemDrop, types)
    "memory.copy" ->
      two_opt_instr(toks, env.mems, env.mems, "memory", ast.MemoryCopy, types)
    "table.copy" ->
      two_opt_instr(toks, env.tables, env.tables, "table", ast.TableCopy, types)
    "memory.init" ->
      init_instr(toks, env.mems, env.datas, ast.MemoryInit, types)
    "table.init" ->
      init_instr(toks, env.tables, env.elems, tableinit_swap, types)
    _ ->
      case load_store(kw) {
        Ok(#(ctor, natural)) -> {
          use #(ma, r) <- result.try(parse_memarg(natural, toks, env))
          Ok(one(ctor(ma), r, types))
        }
        Error(_) -> unsupported_or_unknown(kw, pos)
      }
  }
}

/// `table.init` names elemidx-then-tableidx in the AST but the text is
/// `tableidx? elemidx`; `init_instr` supplies `(first, second)` as
/// `(space_a=table, space_b=elem)`, so swap into `TableInit(elem, table)`.
fn tableinit_swap(table: Int, elem: Int) -> ast.Instr {
  ast.TableInit(elem, table)
}

type ConstKind {
  ConstInt
  ConstF32
  ConstF64
}

fn const_instr(
  toks: List(Token),
  types: List(ast.FuncType),
  _pos: Pos,
  width: Int,
  kind: ConstKind,
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  case toks {
    [Num(np, lex), ..r] ->
      case kind {
        ConstInt ->
          case width {
            32 -> {
              use v <- result.try(const_int_value(lex, 32, np))
              Ok(one(ast.I32Const(v), r, types))
            }
            _ -> {
              use v <- result.try(const_int_value(lex, 64, np))
              Ok(one(ast.I64Const(v), r, types))
            }
          }
        ConstF32 -> {
          use b <- result.try(float_bits(lex, f32_fmt(), np))
          Ok(one(ast.F32Const(b), r, types))
        }
        ConstF64 -> {
          use b <- result.try(float_bits(lex, f64_fmt(), np))
          Ok(one(ast.F64Const(b), r, types))
        }
      }
    [t, ..] ->
      Error(UnexpectedToken(tok_pos(t), "numeric literal", describe(t)))
    [] -> Error(UnexpectedEof("numeric literal"))
  }
}

fn one_idx(
  toks: List(Token),
  map: NameMap,
  space: String,
  ctor: fn(Int) -> ast.Instr,
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  case toks {
    [tok, ..r] -> {
      use i <- result.try(resolve_ref(tok, map, space))
      Ok(one(ctor(i), r, types))
    }
    [] -> Error(UnexpectedEof(space <> " index"))
  }
}

fn opt_idx_instr(
  toks: List(Token),
  map: NameMap,
  space: String,
  ctor: fn(Int) -> ast.Instr,
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  let #(tok, r) = take_num_or_id(toks)
  case tok {
    Some(t) -> {
      use i <- result.try(resolve_ref(t, map, space))
      Ok(one(ctor(i), r, types))
    }
    None -> Ok(one(ctor(0), toks, types))
  }
}

fn label_instr(
  toks: List(Token),
  labels: List(Option(String)),
  ctor: fn(Int) -> ast.Instr,
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  case toks {
    [tok, ..r] -> {
      use d <- result.try(resolve_label_token(tok, labels))
      Ok(one(ctor(d), r, types))
    }
    [] -> Error(UnexpectedEof("label"))
  }
}

fn br_table_instr(
  toks: List(Token),
  labels: List(Option(String)),
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  let #(labtoks, rest) = take_labels(toks, [])
  use depths <- result.try(
    list.try_map(labtoks, fn(t) { resolve_label_token(t, labels) }),
  )
  case list.reverse(depths) {
    [def, ..rev_targets] ->
      Ok(one(ast.BrTable(list.reverse(rev_targets), def), rest, types))
    [] -> Error(UnexpectedEof("br_table labels"))
  }
}

/// Parse the shared `tableidx? typeuse` operand grammar of `call_indirect` /
/// `return_call_indirect` and build the instruction with `ctor`.
///
/// The text is `tableidx? (type $ft)? (param …)* (result …)*`: an optional table
/// index (name or number; absent → table `0`) followed by a typeuse that either
/// names an existing `(type $ft)` or is matched/appended by `finalize_typeuse`.
/// `ctor(type_idx, table)` selects which AST node is produced, so ONE
/// implementation backs BOTH `call_indirect` (`ast.CallIndirect`) and the
/// tail-call `return_call_indirect` (`ast.ReturnCallIndirect`) — the two forms
/// can never diverge. `type_idx` is the resolved/created typeidx; `table` the
/// resolved tableidx. Returns the single-instruction sequence, the unconsumed
/// tokens, and the possibly-extended `types`. Fails with the typeuse errors of
/// `finalize_typeuse` or an `UnboundIdentifier`/`UnexpectedToken` from an
/// unresolvable table reference.
fn call_indirect_instr(
  toks: List(Token),
  env: Env,
  types: List(ast.FuncType),
  pos: Pos,
  ctor: fn(Int, Int) -> ast.Instr,
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  let #(tbl_tok, r1) = take_num_or_id(toks)
  use table <- result.try(case tbl_tok {
    Some(t) -> resolve_ref(t, env.tables, "table")
    None -> Ok(0)
  })
  use #(opt, params, results, r2) <- result.try(parse_typeuse_parts(r1, env))
  use #(type_idx, _, types1) <- result.try(finalize_typeuse(
    opt,
    params,
    results,
    types,
    pos,
  ))
  Ok(one(ctor(type_idx, table), r2, types1))
}

fn select_instr(
  toks: List(Token),
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  case peek_group_head(toks) {
    Some("result") -> {
      use #(inside, rest) <- result.try(take_group(toks))
      use vts <- result.try(parse_valtype_list(drop_head(inside)))
      Ok(one(ast.SelectT(vts), rest, types))
    }
    _ -> Ok(one(ast.Select, toks, types))
  }
}

fn ref_null_instr(
  toks: List(Token),
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  case toks {
    [Keyword(_, "func"), ..r] -> Ok(one(ast.RefNull(ast.FuncRef), r, types))
    [Keyword(_, "extern"), ..r] -> Ok(one(ast.RefNull(ast.ExternRef), r, types))
    [t, ..] ->
      Error(UnexpectedToken(tok_pos(t), "heaptype func/extern", describe(t)))
    [] -> Error(UnexpectedEof("ref.null heaptype"))
  }
}

/// `memory.copy`/`table.copy`: 0 (both default 0) or 2 explicit indices.
fn two_opt_instr(
  toks: List(Token),
  map_a: NameMap,
  map_b: NameMap,
  space: String,
  ctor: fn(Int, Int) -> ast.Instr,
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  let #(idxs, rest) = take_index_toks(toks, 2, [])
  case idxs {
    [] -> Ok(one(ctor(0, 0), rest, types))
    [a, b] -> {
      use ai <- result.try(resolve_ref(a, map_a, space))
      use bi <- result.try(resolve_ref(b, map_b, space))
      Ok(one(ctor(ai, bi), rest, types))
    }
    [t, ..] ->
      Error(UnexpectedToken(
        tok_pos(t),
        "two or zero " <> space <> " indices",
        describe(t),
      ))
  }
}

/// `memory.init`/`table.init`: `<space_a_idx>? <space_b_idx>` (one → the second
/// operand with default-0 first). `ctor(first, second)`.
fn init_instr(
  toks: List(Token),
  map_a: NameMap,
  map_b: NameMap,
  ctor: fn(Int, Int) -> ast.Instr,
  types: List(ast.FuncType),
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  let #(idxs, rest) = take_index_toks(toks, 2, [])
  case idxs {
    [b] -> {
      use bi <- result.try(resolve_ref(b, map_b, "segment"))
      Ok(one(ctor(0, bi), rest, types))
    }
    [a, b] -> {
      use ai <- result.try(resolve_ref(a, map_a, "index"))
      use bi <- result.try(resolve_ref(b, map_b, "segment"))
      Ok(one(ctor(ai, bi), rest, types))
    }
    _ -> Error(UnexpectedEof("segment index"))
  }
}

fn take_num_or_id(toks: List(Token)) -> #(Option(Token), List(Token)) {
  case toks {
    [Num(_, _) as t, ..r] -> #(Some(t), r)
    [Id(_, _) as t, ..r] -> #(Some(t), r)
    _ -> #(None, toks)
  }
}

fn take_index_toks(
  toks: List(Token),
  max: Int,
  acc: List(Token),
) -> #(List(Token), List(Token)) {
  case max <= 0 {
    True -> #(list.reverse(acc), toks)
    False ->
      case toks {
        [Num(_, _) as t, ..r] -> take_index_toks(r, max - 1, [t, ..acc])
        [Id(_, _) as t, ..r] -> take_index_toks(r, max - 1, [t, ..acc])
        _ -> #(list.reverse(acc), toks)
      }
  }
}

fn take_labels(
  toks: List(Token),
  acc: List(Token),
) -> #(List(Token), List(Token)) {
  case toks {
    [Num(_, _) as t, ..r] -> take_labels(r, [t, ..acc])
    [Id(_, _) as t, ..r] -> take_labels(r, [t, ..acc])
    _ -> #(list.reverse(acc), toks)
  }
}

fn resolve_label_token(
  tok: Token,
  labels: List(Option(String)),
) -> Result(Int, WatError) {
  case tok {
    Num(p, lex) -> uint_value(lex, 32, p)
    Id(p, name) ->
      case label_depth(labels, name, 0) {
        Some(d) -> Ok(d)
        None -> Error(UnboundIdentifier(p, "label", name))
      }
    _ -> Error(UnexpectedToken(tok_pos(tok), "label", describe(tok)))
  }
}

fn label_depth(
  labels: List(Option(String)),
  name: String,
  i: Int,
) -> Option(Int) {
  case labels {
    [] -> None
    [Some(n), ..rest] ->
      case n == name {
        True -> Some(i)
        False -> label_depth(rest, name, i + 1)
      }
    [None, ..rest] -> label_depth(rest, name, i + 1)
  }
}

/// Parse a `memarg` = optional memidx (`Num`/`$id`) then `offset=`/`align=` atoms
/// in any order. `align=N` (N a power of two) → `log2(N)` exponent; the default
/// alignment is `natural`; the default offset is 0.
fn parse_memarg(
  natural: Int,
  toks: List(Token),
  env: Env,
) -> Result(#(ast.MemArg, List(Token)), WatError) {
  use #(mem, r1) <- result.try(case toks {
    [Num(mp, lex), ..r] -> {
      use m <- result.try(uint_value(lex, 32, mp))
      Ok(#(m, r))
    }
    [Id(ip, name), ..r] ->
      case dict.get(env.mems, name) {
        Ok(m) -> Ok(#(m, r))
        Error(_) -> Error(UnboundIdentifier(ip, "memory", name))
      }
    _ -> Ok(#(0, toks))
  })
  parse_memarg_opts(r1, natural, 0, mem)
}

fn parse_memarg_opts(
  toks: List(Token),
  align_exp: Int,
  offset: Int,
  mem: Int,
) -> Result(#(ast.MemArg, List(Token)), WatError) {
  case toks {
    [Keyword(kp, k), ..r] ->
      case string.starts_with(k, "offset=") {
        True -> {
          use o <- result.try(uint_value(string.drop_start(k, 7), 64, kp))
          parse_memarg_opts(r, align_exp, o, mem)
        }
        False ->
          case string.starts_with(k, "align=") {
            True -> {
              use n <- result.try(uint_value(string.drop_start(k, 6), 64, kp))
              use exp <- result.try(pow2_exp(n, kp))
              parse_memarg_opts(r, exp, offset, mem)
            }
            False -> Ok(#(ast.MemArg(align_exp, offset, mem), toks))
          }
      }
    _ -> Ok(#(ast.MemArg(align_exp, offset, mem), toks))
  }
}

/// `log2(n)` for a power-of-two `n`; `BadAlign` otherwise.
fn pow2_exp(n: Int, pos: Pos) -> Result(Int, WatError) {
  case n < 1 {
    True -> Error(BadAlign(pos, n))
    False ->
      case int.bitwise_and(n, n - 1) == 0 {
        True -> Ok(msb(n))
        False -> Error(BadAlign(pos, n))
      }
  }
}

fn unsupported_or_unknown(
  kw: String,
  pos: Pos,
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  case is_simd_kw(kw) {
    True -> Error(Unsupported(pos, Simd, kw))
    False ->
      case is_gc_kw(kw) {
        True -> Error(Unsupported(pos, Gc, kw))
        False -> Error(UnknownMnemonic(pos, kw))
      }
  }
}

fn is_simd_kw(kw: String) -> Bool {
  string.starts_with(kw, "v128.")
  || string.starts_with(kw, "i8x16.")
  || string.starts_with(kw, "i16x8.")
  || string.starts_with(kw, "i32x4.")
  || string.starts_with(kw, "i64x2.")
  || string.starts_with(kw, "f32x4.")
  || string.starts_with(kw, "f64x2.")
  || kw == "v128"
}

fn is_gc_kw(kw: String) -> Bool {
  string.starts_with(kw, "struct.")
  || string.starts_with(kw, "array.")
  || string.starts_with(kw, "i31.")
  || string.starts_with(kw, "ref.cast")
  || string.starts_with(kw, "ref.test")
  || string.starts_with(kw, "ref.as_")
  || string.starts_with(kw, "br_on_")
  || string.starts_with(kw, "any.")
  || string.starts_with(kw, "extern.")
  || kw == "ref.eq"
  || kw == "ref.i31"
}

/// A load/store mnemonic → `(constructor, natural-alignment-exponent)`.
fn load_store(kw: String) -> Result(#(fn(ast.MemArg) -> ast.Instr, Int), Nil) {
  case kw {
    "i32.load" -> Ok(#(ast.I32Load, 2))
    "i64.load" -> Ok(#(ast.I64Load, 3))
    "f32.load" -> Ok(#(ast.F32Load, 2))
    "f64.load" -> Ok(#(ast.F64Load, 3))
    "i32.load8_s" -> Ok(#(ast.I32Load8S, 0))
    "i32.load8_u" -> Ok(#(ast.I32Load8U, 0))
    "i32.load16_s" -> Ok(#(ast.I32Load16S, 1))
    "i32.load16_u" -> Ok(#(ast.I32Load16U, 1))
    "i64.load8_s" -> Ok(#(ast.I64Load8S, 0))
    "i64.load8_u" -> Ok(#(ast.I64Load8U, 0))
    "i64.load16_s" -> Ok(#(ast.I64Load16S, 1))
    "i64.load16_u" -> Ok(#(ast.I64Load16U, 1))
    "i64.load32_s" -> Ok(#(ast.I64Load32S, 2))
    "i64.load32_u" -> Ok(#(ast.I64Load32U, 2))
    "i32.store" -> Ok(#(ast.I32Store, 2))
    "i64.store" -> Ok(#(ast.I64Store, 3))
    "f32.store" -> Ok(#(ast.F32Store, 2))
    "f64.store" -> Ok(#(ast.F64Store, 3))
    "i32.store8" -> Ok(#(ast.I32Store8, 0))
    "i32.store16" -> Ok(#(ast.I32Store16, 1))
    "i64.store8" -> Ok(#(ast.I64Store8, 0))
    "i64.store16" -> Ok(#(ast.I64Store16, 1))
    "i64.store32" -> Ok(#(ast.I64Store32, 2))
    _ -> Error(Nil)
  }
}

/// Map a no-immediate mnemonic to its `ast.Instr` (comparisons, numeric,
/// conversions, sign-extension, saturating truncation, `ref.is_null`, the
/// parametric/control leaves). `Error(Nil)` for anything that carries an
/// immediate (handled by `parse_immediate_instr`) or is unknown.
fn simple_instr(kw: String) -> Result(ast.Instr, Nil) {
  case kw {
    "unreachable" -> Ok(ast.Unreachable)
    "nop" -> Ok(ast.Nop)
    "return" -> Ok(ast.Return)
    "drop" -> Ok(ast.Drop)
    "ref.is_null" -> Ok(ast.RefIsNull)
    // i32 comparisons
    "i32.eqz" -> Ok(ast.I32Eqz)
    "i32.eq" -> Ok(ast.I32Eq)
    "i32.ne" -> Ok(ast.I32Ne)
    "i32.lt_s" -> Ok(ast.I32LtS)
    "i32.lt_u" -> Ok(ast.I32LtU)
    "i32.gt_s" -> Ok(ast.I32GtS)
    "i32.gt_u" -> Ok(ast.I32GtU)
    "i32.le_s" -> Ok(ast.I32LeS)
    "i32.le_u" -> Ok(ast.I32LeU)
    "i32.ge_s" -> Ok(ast.I32GeS)
    "i32.ge_u" -> Ok(ast.I32GeU)
    // i64 comparisons
    "i64.eqz" -> Ok(ast.I64Eqz)
    "i64.eq" -> Ok(ast.I64Eq)
    "i64.ne" -> Ok(ast.I64Ne)
    "i64.lt_s" -> Ok(ast.I64LtS)
    "i64.lt_u" -> Ok(ast.I64LtU)
    "i64.gt_s" -> Ok(ast.I64GtS)
    "i64.gt_u" -> Ok(ast.I64GtU)
    "i64.le_s" -> Ok(ast.I64LeS)
    "i64.le_u" -> Ok(ast.I64LeU)
    "i64.ge_s" -> Ok(ast.I64GeS)
    "i64.ge_u" -> Ok(ast.I64GeU)
    // float comparisons
    "f32.eq" -> Ok(ast.F32Eq)
    "f32.ne" -> Ok(ast.F32Ne)
    "f32.lt" -> Ok(ast.F32Lt)
    "f32.gt" -> Ok(ast.F32Gt)
    "f32.le" -> Ok(ast.F32Le)
    "f32.ge" -> Ok(ast.F32Ge)
    "f64.eq" -> Ok(ast.F64Eq)
    "f64.ne" -> Ok(ast.F64Ne)
    "f64.lt" -> Ok(ast.F64Lt)
    "f64.gt" -> Ok(ast.F64Gt)
    "f64.le" -> Ok(ast.F64Le)
    "f64.ge" -> Ok(ast.F64Ge)
    // i32 numeric
    "i32.clz" -> Ok(ast.I32Clz)
    "i32.ctz" -> Ok(ast.I32Ctz)
    "i32.popcnt" -> Ok(ast.I32Popcnt)
    "i32.add" -> Ok(ast.I32Add)
    "i32.sub" -> Ok(ast.I32Sub)
    "i32.mul" -> Ok(ast.I32Mul)
    "i32.div_s" -> Ok(ast.I32DivS)
    "i32.div_u" -> Ok(ast.I32DivU)
    "i32.rem_s" -> Ok(ast.I32RemS)
    "i32.rem_u" -> Ok(ast.I32RemU)
    "i32.and" -> Ok(ast.I32And)
    "i32.or" -> Ok(ast.I32Or)
    "i32.xor" -> Ok(ast.I32Xor)
    "i32.shl" -> Ok(ast.I32Shl)
    "i32.shr_s" -> Ok(ast.I32ShrS)
    "i32.shr_u" -> Ok(ast.I32ShrU)
    "i32.rotl" -> Ok(ast.I32Rotl)
    "i32.rotr" -> Ok(ast.I32Rotr)
    // i64 numeric
    "i64.clz" -> Ok(ast.I64Clz)
    "i64.ctz" -> Ok(ast.I64Ctz)
    "i64.popcnt" -> Ok(ast.I64Popcnt)
    "i64.add" -> Ok(ast.I64Add)
    "i64.sub" -> Ok(ast.I64Sub)
    "i64.mul" -> Ok(ast.I64Mul)
    "i64.div_s" -> Ok(ast.I64DivS)
    "i64.div_u" -> Ok(ast.I64DivU)
    "i64.rem_s" -> Ok(ast.I64RemS)
    "i64.rem_u" -> Ok(ast.I64RemU)
    "i64.and" -> Ok(ast.I64And)
    "i64.or" -> Ok(ast.I64Or)
    "i64.xor" -> Ok(ast.I64Xor)
    "i64.shl" -> Ok(ast.I64Shl)
    "i64.shr_s" -> Ok(ast.I64ShrS)
    "i64.shr_u" -> Ok(ast.I64ShrU)
    "i64.rotl" -> Ok(ast.I64Rotl)
    "i64.rotr" -> Ok(ast.I64Rotr)
    // f32 numeric
    "f32.abs" -> Ok(ast.F32Abs)
    "f32.neg" -> Ok(ast.F32Neg)
    "f32.ceil" -> Ok(ast.F32Ceil)
    "f32.floor" -> Ok(ast.F32Floor)
    "f32.trunc" -> Ok(ast.F32Trunc)
    "f32.nearest" -> Ok(ast.F32Nearest)
    "f32.sqrt" -> Ok(ast.F32Sqrt)
    "f32.add" -> Ok(ast.F32Add)
    "f32.sub" -> Ok(ast.F32Sub)
    "f32.mul" -> Ok(ast.F32Mul)
    "f32.div" -> Ok(ast.F32Div)
    "f32.min" -> Ok(ast.F32Min)
    "f32.max" -> Ok(ast.F32Max)
    "f32.copysign" -> Ok(ast.F32Copysign)
    // f64 numeric
    "f64.abs" -> Ok(ast.F64Abs)
    "f64.neg" -> Ok(ast.F64Neg)
    "f64.ceil" -> Ok(ast.F64Ceil)
    "f64.floor" -> Ok(ast.F64Floor)
    "f64.trunc" -> Ok(ast.F64Trunc)
    "f64.nearest" -> Ok(ast.F64Nearest)
    "f64.sqrt" -> Ok(ast.F64Sqrt)
    "f64.add" -> Ok(ast.F64Add)
    "f64.sub" -> Ok(ast.F64Sub)
    "f64.mul" -> Ok(ast.F64Mul)
    "f64.div" -> Ok(ast.F64Div)
    "f64.min" -> Ok(ast.F64Min)
    "f64.max" -> Ok(ast.F64Max)
    "f64.copysign" -> Ok(ast.F64Copysign)
    // conversions
    "i32.wrap_i64" -> Ok(ast.I32WrapI64)
    "i32.trunc_f32_s" -> Ok(ast.I32TruncF32S)
    "i32.trunc_f32_u" -> Ok(ast.I32TruncF32U)
    "i32.trunc_f64_s" -> Ok(ast.I32TruncF64S)
    "i32.trunc_f64_u" -> Ok(ast.I32TruncF64U)
    "i64.extend_i32_s" -> Ok(ast.I64ExtendI32S)
    "i64.extend_i32_u" -> Ok(ast.I64ExtendI32U)
    "i64.trunc_f32_s" -> Ok(ast.I64TruncF32S)
    "i64.trunc_f32_u" -> Ok(ast.I64TruncF32U)
    "i64.trunc_f64_s" -> Ok(ast.I64TruncF64S)
    "i64.trunc_f64_u" -> Ok(ast.I64TruncF64U)
    "f32.convert_i32_s" -> Ok(ast.F32ConvertI32S)
    "f32.convert_i32_u" -> Ok(ast.F32ConvertI32U)
    "f32.convert_i64_s" -> Ok(ast.F32ConvertI64S)
    "f32.convert_i64_u" -> Ok(ast.F32ConvertI64U)
    "f32.demote_f64" -> Ok(ast.F32DemoteF64)
    "f64.convert_i32_s" -> Ok(ast.F64ConvertI32S)
    "f64.convert_i32_u" -> Ok(ast.F64ConvertI32U)
    "f64.convert_i64_s" -> Ok(ast.F64ConvertI64S)
    "f64.convert_i64_u" -> Ok(ast.F64ConvertI64U)
    "f64.promote_f32" -> Ok(ast.F64PromoteF32)
    "i32.reinterpret_f32" -> Ok(ast.I32ReinterpretF32)
    "i64.reinterpret_f64" -> Ok(ast.I64ReinterpretF64)
    "f32.reinterpret_i32" -> Ok(ast.F32ReinterpretI32)
    "f64.reinterpret_i64" -> Ok(ast.F64ReinterpretI64)
    // sign extension
    "i32.extend8_s" -> Ok(ast.I32Extend8S)
    "i32.extend16_s" -> Ok(ast.I32Extend16S)
    "i64.extend8_s" -> Ok(ast.I64Extend8S)
    "i64.extend16_s" -> Ok(ast.I64Extend16S)
    "i64.extend32_s" -> Ok(ast.I64Extend32S)
    // saturating truncation
    "i32.trunc_sat_f32_s" -> Ok(ast.I32TruncSatF32S)
    "i32.trunc_sat_f32_u" -> Ok(ast.I32TruncSatF32U)
    "i32.trunc_sat_f64_s" -> Ok(ast.I32TruncSatF64S)
    "i32.trunc_sat_f64_u" -> Ok(ast.I32TruncSatF64U)
    "i64.trunc_sat_f32_s" -> Ok(ast.I64TruncSatF32S)
    "i64.trunc_sat_f32_u" -> Ok(ast.I64TruncSatF32U)
    "i64.trunc_sat_f64_s" -> Ok(ast.I64TruncSatF64S)
    "i64.trunc_sat_f64_u" -> Ok(ast.I64TruncSatF64U)
    _ -> Error(Nil)
  }
}

// ===========================================================================
// H. The `.wast` script command parser (pass 2)
// ===========================================================================
//
// A `.wast` script is a flat sequence of top-level `(command …)` s-expressions
// (no outer wrapper). `parse_script` collects them and maps each head keyword to
// a `Command`. Nested modules inside `assert_*` are parsed to a `ModuleDef` but
// NOT type-checked (the parse-vs-validate split routes `assert_malformed` to
// parse/decode and `assert_invalid` through parse into validate). Every step
// returns `Result`; malformed script grammar → a typed `WatError`, never a panic
// (a malformed *asserted* module is still `Ok` — its `ModuleDef` is carried for
// the runner to reject at the right stage).

/// Parse a `.wast` script `source` into an ordered `Script` (`«WAT-API»`).
///
/// Each top-level `(command …)` becomes one `Command`, in source order:
/// `(module …)` in text/`binary`/`quote` form, `register`, the full `assert_*`
/// family, and bare `(invoke …)`/`(get …)` actions are recognised; any other
/// command head is a categorized `CmdSkipped(head)` (never dropped).
///
/// Returns `Ok(script)`, or a typed `WatError` for any malformation of the
/// SCRIPT grammar itself (trailing junk, a truncated command, a bad action).
/// Total over any `String`.
pub fn parse_script(source: String) -> Result(Script, WatError) {
  use tokens <- result.try(lex(source))
  use #(groups, after) <- result.try(collect_groups(tokens))
  case after {
    [] -> list.try_map(groups, parse_command)
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "script command", describe(t)))
  }
}

/// Dispatch one command group (the tokens INSIDE its parens, head keyword first).
fn parse_command(inside: List(Token)) -> Result(Command, WatError) {
  case inside {
    [Keyword(_, "module"), ..] -> {
      use #(id, def) <- result.try(parse_module_def(inside))
      Ok(WatModule(id, def))
    }
    [Keyword(_, "register"), ..rest] -> parse_register(rest)
    [Keyword(_, "invoke"), ..] -> parse_bare_action(inside)
    [Keyword(_, "get"), ..] -> parse_bare_action(inside)
    [Keyword(_, "assert_return"), ..rest] -> parse_assert_return(rest)
    [Keyword(_, "assert_trap"), ..rest] -> parse_assert_trap(rest)
    [Keyword(_, "assert_exhaustion"), ..rest] ->
      parse_assert_action_failure(rest, AssertExhaustion)
    [Keyword(_, "assert_invalid"), ..rest] ->
      parse_assert_module_failure(rest, AssertInvalid)
    [Keyword(_, "assert_malformed"), ..rest] ->
      parse_assert_module_failure(rest, AssertMalformed)
    [Keyword(_, "assert_unlinkable"), ..rest] ->
      parse_assert_module_failure(rest, AssertUnlinkable)
    [Keyword(_, "assert_uninstantiable"), ..rest] ->
      parse_assert_module_failure(rest, AssertUninstantiable)
    [Keyword(_, other), ..] -> Ok(CmdSkipped(other))
    [t, ..] -> Ok(CmdSkipped(describe(t)))
    [] -> Error(UnexpectedEof("script command"))
  }
}

fn parse_bare_action(inside: List(Token)) -> Result(Command, WatError) {
  use action <- result.try(parse_action(inside))
  Ok(ActionCmd(action))
}

/// Parse a `(module …)` group into `#(optional $id, ModuleDef)`. Detects the
/// `binary`/`quote` heads BEFORE falling through to a text module (whose fields
/// are reconstructed and handed to `parse_module_tokens`).
fn parse_module_def(
  inside: List(Token),
) -> Result(#(Option(String), ModuleDef), WatError) {
  case inside {
    [Keyword(hp, "module"), ..rest] -> {
      let #(id, rest1) = case rest {
        [Id(_, n), ..r] -> #(Some(n), r)
        _ -> #(None, rest)
      }
      case rest1 {
        [Keyword(_, "binary"), ..strs] -> {
          use bytes <- result.try(concat_strings(strs))
          Ok(#(id, BinaryModule(bytes)))
        }
        [Keyword(_, "quote"), ..strs] -> {
          use bytes <- result.try(concat_strings(strs))
          use src <- result.try(str_to_name(bytes, hp))
          Ok(#(id, QuoteModule(src)))
        }
        _ -> {
          // A text module: rebuild `(module <fields>)` and parse the fields.
          let toks = [
            LParen(hp),
            Keyword(hp, "module"),
            ..list.append(rest1, [RParen(hp)])
          ]
          use m <- result.try(parse_module_tokens(toks))
          Ok(#(id, TextModule(m)))
        }
      }
    }
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "(module …)", describe(t)))
    [] -> Error(UnexpectedEof("(module …)"))
  }
}

/// Parse a `(register "name" $mod?)` command's arguments (head already consumed).
fn parse_register(rest: List(Token)) -> Result(Command, WatError) {
  case rest {
    [Str(sp, nb), ..r] -> {
      use name <- result.try(str_to_name(nb, sp))
      let modname = case r {
        [Id(_, n), ..] -> Some(n)
        _ -> None
      }
      Ok(Register(name, modname))
    }
    [t, ..] ->
      Error(UnexpectedToken(tok_pos(t), "register name string", describe(t)))
    [] -> Error(UnexpectedEof("register name"))
  }
}

/// Parse an action group (the tokens inside a `(invoke …)`/`(get …)`).
fn parse_action(inside: List(Token)) -> Result(Action, WatError) {
  case inside {
    [Keyword(_, "invoke"), ..rest] -> {
      let #(modname, rest1) = take_action_module(rest)
      case rest1 {
        [Str(sp, fb), ..argtoks] -> {
          use field <- result.try(str_to_name(fb, sp))
          use args <- result.try(parse_wast_values(argtoks))
          Ok(Invoke(modname, field, args))
        }
        [t, ..] ->
          Error(UnexpectedToken(tok_pos(t), "invoke field name", describe(t)))
        [] -> Error(UnexpectedEof("invoke field name"))
      }
    }
    [Keyword(_, "get"), ..rest] -> {
      let #(modname, rest1) = take_action_module(rest)
      case rest1 {
        [Str(sp, fb), ..] -> {
          use field <- result.try(str_to_name(fb, sp))
          Ok(Get(modname, field))
        }
        [t, ..] ->
          Error(UnexpectedToken(tok_pos(t), "get field name", describe(t)))
        [] -> Error(UnexpectedEof("get field name"))
      }
    }
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "invoke or get", describe(t)))
    [] -> Error(UnexpectedEof("action"))
  }
}

/// A leading `$id` module reference in an action (before the field string).
fn take_action_module(toks: List(Token)) -> #(Option(String), List(Token)) {
  case toks {
    [Id(_, n), ..r] -> #(Some(n), r)
    _ -> #(None, toks)
  }
}

/// Parse the argument groups of an action into `WastValue`s.
fn parse_wast_values(toks: List(Token)) -> Result(List(WastValue), WatError) {
  use #(groups, after) <- result.try(collect_groups(toks))
  case after {
    [] -> list.try_map(groups, parse_wast_value)
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "value or )", describe(t)))
  }
}

/// Parse one value group (tokens inside a single `( … )`) into a `WastValue`.
/// Numeric consts reuse the pass-1 bit-exact number path (raw UNSIGNED bits for
/// integers); reference values map to the R18 variants.
fn parse_wast_value(inside: List(Token)) -> Result(WastValue, WatError) {
  case inside {
    [Keyword(_, "i32.const"), Num(p, lex)] -> {
      use b <- result.try(const_int_bits(lex, 32, p))
      Ok(WastI32(b))
    }
    [Keyword(_, "i64.const"), Num(p, lex)] -> {
      use b <- result.try(const_int_bits(lex, 64, p))
      Ok(WastI64(b))
    }
    [Keyword(_, "f32.const"), Num(p, lex)] -> {
      use b <- result.try(float_bits(lex, f32_fmt(), p))
      Ok(WastF32(b))
    }
    [Keyword(_, "f64.const"), Num(p, lex)] -> {
      use b <- result.try(float_bits(lex, f64_fmt(), p))
      Ok(WastF64(b))
    }
    [Keyword(_, "ref.null"), Keyword(_, "func")] -> Ok(RefNullVal(ast.FuncRef))
    [Keyword(_, "ref.null"), Keyword(_, "extern")] ->
      Ok(RefNullVal(ast.ExternRef))
    [Keyword(_, "ref.extern"), Num(p, lex)] -> {
      use v <- result.try(uint_value(lex, 32, p))
      Ok(RefExternVal(v))
    }
    [Keyword(_, "ref.func"), ..] -> Ok(RefFuncVal)
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "wast value", describe(t)))
    [] -> Error(UnexpectedEof("wast value"))
  }
}

/// Interpret an integer lexeme for a `t.const` value at bit `width` (32/64),
/// returning the RAW UNSIGNED bit pattern in `[0, 2^width)` — the representation
/// the conformance fixture stores. Accepts the combined signed∪unsigned range,
/// else `NumberOutOfRange`. (Twin of `const_int_value`, which returns the signed
/// value the AST stores.)
fn const_int_bits(
  lexeme: String,
  width: Int,
  pos: Pos,
) -> Result(Int, WatError) {
  case int_math_value(lexeme) {
    Ok(v) -> {
      let m = pow2(width)
      let half = pow2(width - 1)
      case v >= -half && v < m {
        True -> Ok({ { v % m } + m } % m)
        False -> Error(NumberOutOfRange(pos, lexeme))
      }
    }
    Error(_) -> Error(NumberOutOfRange(pos, lexeme))
  }
}

/// Parse the expected-result groups of an `assert_return`.
fn parse_expecteds(toks: List(Token)) -> Result(List(Expected), WatError) {
  use #(groups, after) <- result.try(collect_groups(toks))
  case after {
    [] -> list.try_map(groups, parse_expected)
    [t, ..] ->
      Error(UnexpectedToken(tok_pos(t), "expected value or )", describe(t)))
  }
}

/// Parse one expected-result group: a `nan:canonical`/`nan:arithmetic` float
/// pattern becomes a NaN CLASS; anything else is an exact `WastValue`.
fn parse_expected(inside: List(Token)) -> Result(Expected, WatError) {
  case inside {
    [Keyword(_, "f32.const"), Num(p, lex)] -> nan_or_value(lex, 32, p)
    [Keyword(_, "f64.const"), Num(p, lex)] -> nan_or_value(lex, 64, p)
    _ -> {
      use v <- result.try(parse_wast_value(inside))
      Ok(ExpectedValue(v))
    }
  }
}

fn nan_or_value(
  lex: String,
  width: Int,
  pos: Pos,
) -> Result(Expected, WatError) {
  case drop_sign(lex) {
    "nan:canonical" -> Ok(ExpectedNanCanonical(width))
    "nan:arithmetic" -> Ok(ExpectedNanArithmetic(width))
    _ -> {
      use b <- result.try(float_bits(lex, float_fmt_of(width), pos))
      Ok(ExpectedValue(float_val_of(width, b)))
    }
  }
}

fn float_fmt_of(width: Int) -> FloatFmt {
  case width {
    32 -> f32_fmt()
    _ -> f64_fmt()
  }
}

fn float_val_of(width: Int, bits: Int) -> WastValue {
  case width {
    32 -> WastF32(bits)
    _ -> WastF64(bits)
  }
}

/// `(assert_return <action> <result>*)`.
fn parse_assert_return(rest: List(Token)) -> Result(Command, WatError) {
  use #(action_toks, after) <- result.try(take_group(rest))
  use action <- result.try(parse_action(action_toks))
  use expected <- result.try(parse_expecteds(after))
  Ok(AssertReturn(action, expected))
}

/// `(assert_trap …)` — an ACTION that traps, OR (the reference interpreter's
/// overload) a MODULE whose instantiation traps → `AssertUninstantiable`.
fn parse_assert_trap(rest: List(Token)) -> Result(Command, WatError) {
  case peek_group_head(rest) {
    Some("module") -> parse_assert_module_failure(rest, AssertUninstantiable)
    _ -> parse_assert_action_failure(rest, AssertTrap)
  }
}

/// `(assert_* <action> "<failure>")` (trap / exhaustion).
fn parse_assert_action_failure(
  rest: List(Token),
  ctor: fn(Action, String) -> Command,
) -> Result(Command, WatError) {
  use #(action_toks, after) <- result.try(take_group(rest))
  use action <- result.try(parse_action(action_toks))
  use failure <- result.try(take_failure(after))
  Ok(ctor(action, failure))
}

/// `(assert_* <module> "<failure>")` (invalid / malformed / unlinkable /
/// uninstantiable). Any leading `$id` on the asserted module is discarded — an
/// asserted-reject module is never referenced by later commands.
fn parse_assert_module_failure(
  rest: List(Token),
  ctor: fn(ModuleDef, String) -> Command,
) -> Result(Command, WatError) {
  use #(mod_toks, after) <- result.try(take_group(rest))
  use #(_id, def) <- result.try(parse_module_def(mod_toks))
  use failure <- result.try(take_failure(after))
  Ok(ctor(def, failure))
}

/// The trailing failure-message string of an assert command. Tolerates its
/// absence (empty string) so a text-less assert is still total; a non-string
/// trailing token is a typed error.
fn take_failure(toks: List(Token)) -> Result(String, WatError) {
  case toks {
    [Str(sp, b), ..] -> str_to_name(b, sp)
    [] -> Ok("")
    [t, ..] -> Error(UnexpectedToken(tok_pos(t), "failure string", describe(t)))
  }
}
