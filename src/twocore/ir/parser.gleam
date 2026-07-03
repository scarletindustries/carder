//// The `.ir` parser (Unit 02).
////
//// Parses the canonical `.ir` textual form (`specs/phase-1/ir-grammar.md`) back into
//// a `twocore/ir` `Module`. It is the load half of the inter-stage contract (D7): with
//// `twocore/ir/printer.print_module` it satisfies the round-trip `parse(print(m)) == m`.
////
//// ## Shape
////
//// A two-phase, hand-written **recursive-descent** parser:
//// 1. `lex` turns the source into a flat token stream, tracking 1-based `line`/`col`,
////    skipping whitespace and `;`-to-end-of-line comments, and decoding string escapes.
//// 2. The `parse_*` functions mirror the grammar's productions one-for-one.
////
//// ## Totality (a hard requirement — an untrusted-input panic is a sandbox hole)
////
//// `parse_module` is **total**: it never panics on malformed input. There is no
//// `let assert`/`panic`/`todo` on any path reachable from the source string; every
//// fault is reported as a typed `ParseError` carrying position info, propagated with
//// `result.try`. The lexer operates over UTF-8 graphemes (Gleam strings) — no Erlang
//// bit-syntax is needed or used here.
////
//// ## Grammar choices this parser fixes (where the seeded grammar was loose)
////
//// - **`;` is always a comment to end of line.** A `let`/`charge` continuation simply
////   follows its right-hand side; no separator token is required (every non-sequencing
////   expression is self-delimiting, so the body's start is unambiguous). This parses
////   the hand-authored goldens — whose `let … ;` line-endings are empty comments — and
////   the grammar's worked examples identically.
//// - **Trap reasons** are the snake_case of their constructor
////   (`indirect_call_type_mismatch`, `memory_out_of_bounds`).
//// - **Data segments** are written `data ( <offset-expr> ) = 0x<hexbytes>`.
//// These are flagged to unit 01 for reconciliation into `ir-grammar.md`.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import twocore/ir.{
  type ConvOp, type DataSegment, type ElementSegment, type ExportDecl, type Expr,
  type FloatWidth, type FuncType, type Function, type GlobalDecl,
  type ImportDecl, type IntWidth, type Local, type LoopParam, type MemAccess,
  type MemoryDecl, type Module, type NumOp, type SwitchArm, type TableDecl,
  type TermOp, type TrapReason, type ValType, type Value, Block, BoxFloat,
  BoxInt, Break, CallDirect, CallHost, CallIndirect, Charge, ConstF32, ConstF64,
  ConstI32, ConstI64, Continue, Convert, ConvertS, ConvertU, DataSegment,
  ElementSegment, ExportFn, F32DemoteF64, F64PromoteF32, FAbs, FAdd, FCeil,
  FCopysign, FDiv, FEq, FFloor, FGe, FGt, FLe, FLt, FMax, FMin, FMul, FNe,
  FNearest, FNeg, FSqrt, FSub, FTrunc, FW32, FW64, FuelExhausted, FuncType,
  Function, GlobalDecl, GlobalGet, GlobalSet, I32Extend16S, I32Extend8S,
  I32WrapI64, I64Extend16S, I64Extend32S, I64Extend8S, I64ExtendI32S,
  I64ExtendI32U, IAdd, IAnd, IClz, ICtz, IDivS, IDivU, IEq, IEqz, IGeS, IGeU,
  IGtS, IGtU, ILeS, ILeU, ILtS, ILtU, IMul, INe, IOr, IPopcnt, IRemS, IRemU,
  IRotl, IRotr, IShl, IShrS, IShrU, ISub, IXor, If, ImportFn,
  IndirectCallTypeMismatch, IntDivByZero, IntOverflow,
  InvalidConversionToInteger, Let, Local, Loop, LoopParam, MakeCons, MakeTuple,
  MemAccess, MemGrow, MemLoad, MemSize, MemStore, MemoryDecl, MemoryOutOfBounds,
  Module, Num, ReinterpretFToI, ReinterpretIToF, Return, Switch, SwitchArm, TF32,
  TF64, TI32, TI64, TTerm, TableDecl, TableOutOfBounds, TermOp, Trap, TruncS,
  TruncSatS, TruncSatU, TruncU, TupleGet, UnboxFloat, UnboxInt, UndefinedElement,
  UninitializedElement, Unreachable, Values, Var, W32, W64,
}

// ───────────────────────────── error type (D4 — this stage's own) ────────────────

/// This stage's OWN error type (D4 — there is no shared `StageError`; the pipeline
/// driver in unit 11 wraps this). Every variant carries enough position info to locate
/// the fault; `line`/`col` are 1-based.
///
/// - `UnexpectedToken(line, col, expected, found)`: a token of the wrong shape;
///   `expected` describes what the grammar required, `found` echoes the offending text.
/// - `UnexpectedEnd(expected)`: the input ended while `expected` was still required
///   (truncated module, unterminated block/list/string).
/// - `UnknownOp(line, col, op)`: an unrecognised numeric/conversion/term/trap spelling.
/// - `BadSigil(line, col, found)`: a sigil of the wrong kind (e.g. `%x` where `@x` was
///   required); `found` is the sigil that was seen.
/// - `BadNumberLiteral(line, col, lexeme)`: a malformed number / hex-bytes literal.
/// - `BadString(line, col, found)`: an invalid string escape sequence.
pub type ParseError {
  UnexpectedToken(line: Int, col: Int, expected: String, found: String)
  UnexpectedEnd(expected: String)
  UnknownOp(line: Int, col: Int, op: String)
  BadSigil(line: Int, col: Int, found: String)
  BadNumberLiteral(line: Int, col: Int, lexeme: String)
  BadString(line: Int, col: Int, found: String)
}

// ───────────────────────────── public entry point ─────────────────────────────

/// Parse `.ir` source text into a `Module`.
///
/// TOTAL — never panics on malformed input (no `let assert`/`panic` reachable from the
/// untrusted text). Accepts `;`-comments and free whitespace, both `0x`-hex and decimal
/// integer literals, and the standard string escapes. The parser checks **syntax** and
/// produces a well-formed `Module`; it does **not** validate IR semantics (type-checking,
/// label scoping, arity vs `FuncType`) — those belong to later stages.
///
/// Parameters:
/// - `source`: the `.ir` text (UTF-8).
///
/// Returns `Ok(module)` for a syntactically valid module, or `Error(ParseError)` —
/// with position info — on the first fault.
pub fn parse_module(source: String) -> Result(Module, ParseError) {
  use toks <- result.try(lex(source))
  use rest <- result.try(expect_word(toks, "module"))
  use #(name, rest) <- result.try(parse_at_name(rest))
  use rest <- result.try(expect(rest, TLBrace, "{"))
  use #(acc, rest) <- result.try(parse_module_items(
    rest,
    ModuleAcc(False, [], [], [], [], [], [], [], [], None),
  ))
  use rest <- result.try(expect(rest, TRBrace, "}"))
  case rest {
    [] -> Ok(build_module(name, acc))
    [PToken(t, l, c), ..] ->
      Error(UnexpectedToken(l, c, "end of input", describe(t)))
  }
}

// ───────────────────────────── tokens ─────────────────────────────

/// A lexical token. Sigil tokens carry the bare name (without the sigil); `TStr`
/// carries the *decoded* string contents; `TNumber` carries the parsed integer value
/// and the original lexeme (the lexeme preserves leading zeros for hex-byte segments).
type Token {
  TLParen
  TRParen
  TLBrace
  TRBrace
  TLBracket
  TRBracket
  TColon
  TComma
  TEquals
  TArrow
  TLocal(String)
  TLabel(String)
  TAt(String)
  TStr(String)
  TWord(String)
  TNumber(Int, String)
}

/// A token tagged with its 1-based source position.
type PToken {
  PToken(token: Token, line: Int, col: Int)
}

/// A human-readable echo of a token, for `found:` fields in error messages.
fn describe(t: Token) -> String {
  case t {
    TLParen -> "("
    TRParen -> ")"
    TLBrace -> "{"
    TRBrace -> "}"
    TLBracket -> "["
    TRBracket -> "]"
    TColon -> ":"
    TComma -> ","
    TEquals -> "="
    TArrow -> "->"
    TLocal(n) -> "%" <> n
    TLabel(n) -> "$" <> n
    TAt(n) -> "@" <> n
    TStr(s) -> "\"" <> s <> "\""
    TWord(w) -> w
    TNumber(_, lex) -> lex
  }
}

// ───────────────────────────── lexer ─────────────────────────────

/// Tokenises `source`, tracking 1-based line/col and skipping whitespace and
/// `;`-to-end-of-line comments. Returns the token list, or a `ParseError` for a stray
/// character, malformed number, bad string escape, or a sigil with no name.
fn lex(source: String) -> Result(List(PToken), ParseError) {
  do_lex(string.to_graphemes(source), 1, 1, [])
}

fn do_lex(
  chars: List(String),
  line: Int,
  col: Int,
  acc: List(PToken),
) -> Result(List(PToken), ParseError) {
  case chars {
    [] -> Ok(list.reverse(acc))
    [c, ..rest] ->
      case c {
        "\n" -> do_lex(rest, line + 1, 1, acc)
        " " | "\t" | "\r" -> do_lex(rest, line, col + 1, acc)
        ";" -> do_lex(drop_to_eol(rest), line, col, acc)
        "(" -> push(TLParen, rest, line, col, 1, acc)
        ")" -> push(TRParen, rest, line, col, 1, acc)
        "{" -> push(TLBrace, rest, line, col, 1, acc)
        "}" -> push(TRBrace, rest, line, col, 1, acc)
        "[" -> push(TLBracket, rest, line, col, 1, acc)
        "]" -> push(TRBracket, rest, line, col, 1, acc)
        ":" -> push(TColon, rest, line, col, 1, acc)
        "," -> push(TComma, rest, line, col, 1, acc)
        "=" -> push(TEquals, rest, line, col, 1, acc)
        "\"" ->
          case read_string(rest, line, col + 1, "") {
            Ok(#(str, rest2, line2, col2)) ->
              do_lex(rest2, line2, col2, [PToken(TStr(str), line, col), ..acc])
            Error(e) -> Error(e)
          }
        "-" ->
          case rest {
            [">", ..rest2] ->
              do_lex(rest2, line, col + 2, [PToken(TArrow, line, col), ..acc])
            _ -> read_num_token(rest, line, col, "-", acc)
          }
        "%" -> read_sigil(rest, line, col, TLocal, "%", acc)
        "$" -> read_sigil(rest, line, col, TLabel, "$", acc)
        "@" -> read_sigil(rest, line, col, TAt, "@", acc)
        _ ->
          case is_digit(c) {
            True -> read_num_token(chars, line, col, "", acc)
            False ->
              case is_word_start(c) {
                True -> {
                  let #(word, rest2) = take_while(chars, is_word_char)
                  do_lex(rest2, line, col + string.length(word), [
                    PToken(TWord(word), line, col),
                    ..acc
                  ])
                }
                False -> Error(UnexpectedToken(line, col, "token", c))
              }
          }
      }
  }
}

/// Pushes a fixed-width punctuation token and continues lexing.
fn push(
  tok: Token,
  rest: List(String),
  line: Int,
  col: Int,
  width: Int,
  acc: List(PToken),
) -> Result(List(PToken), ParseError) {
  do_lex(rest, line, col + width, [PToken(tok, line, col), ..acc])
}

/// Lexes a sigil token: `mk` wraps the name (e.g. `TLocal`); `sigil` is the leading
/// character (for a `BadSigil` error if no name follows).
fn read_sigil(
  rest: List(String),
  line: Int,
  col: Int,
  mk: fn(String) -> Token,
  sigil: String,
  acc: List(PToken),
) -> Result(List(PToken), ParseError) {
  let #(name, rest2) = take_while(rest, is_name_char)
  case name {
    "" -> Error(BadSigil(line, col, sigil))
    _ ->
      do_lex(rest2, line, col + 1 + string.length(name), [
        PToken(mk(name), line, col),
        ..acc
      ])
  }
}

/// Lexes a number token (decimal or `0x`-hex). `sign` is `"-"` for a negative literal
/// or `""` otherwise; `chars` starts at the first digit (after any sign). The original
/// lexeme is preserved on the token (significant for hex-byte segments' leading zeros).
fn read_num_token(
  chars: List(String),
  line: Int,
  col: Int,
  sign: String,
  acc: List(PToken),
) -> Result(List(PToken), ParseError) {
  case lex_number(chars) {
    Ok(#(lexeme, value, rest)) -> {
      let signed_value = case sign {
        "-" -> 0 - value
        _ -> value
      }
      let full = sign <> lexeme
      do_lex(rest, line, col + string.length(full), [
        PToken(TNumber(signed_value, full), line, col),
        ..acc
      ])
    }
    Error(_) -> Error(BadNumberLiteral(line, col, sign <> "?"))
  }
}

/// Consumes a maximal numeric lexeme from `chars`. Recognises `0x`/`0X` hex (zero or
/// more hex digits — empty hex is value 0, used by empty data segments) and decimal.
/// Returns `#(lexeme, value, rest)`, or `Error(Nil)` when no digits are present.
fn lex_number(
  chars: List(String),
) -> Result(#(String, Int, List(String)), Nil) {
  case chars {
    ["0", "x", ..rest] | ["0", "X", ..rest] -> {
      let #(digits, rest2) = take_while(rest, is_hex_digit)
      case digits {
        "" -> Ok(#("0x", 0, rest2))
        _ ->
          case int.base_parse(string.lowercase(digits), 16) {
            Ok(v) -> Ok(#("0x" <> digits, v, rest2))
            Error(_) -> Error(Nil)
          }
      }
    }
    _ -> {
      let #(digits, rest2) = take_while(chars, is_digit)
      case digits {
        "" -> Error(Nil)
        _ ->
          case int.parse(digits) {
            Ok(v) -> Ok(#(digits, v, rest2))
            Error(_) -> Error(Nil)
          }
      }
    }
  }
}

/// Lexes a `"…"` string body (the opening quote already consumed). Handles `\\`, `\"`,
/// `\n`, `\t`, `\r` escapes; tracks line/col across literal newlines. Returns the
/// decoded contents plus the position just past the closing quote.
fn read_string(
  chars: List(String),
  line: Int,
  col: Int,
  acc: String,
) -> Result(#(String, List(String), Int, Int), ParseError) {
  case chars {
    [] -> Error(UnexpectedEnd("closing quote"))
    ["\"", ..rest] -> Ok(#(acc, rest, line, col + 1))
    ["\\", esc, ..rest] ->
      case unescape(esc) {
        Ok(ch) -> read_string(rest, line, col + 2, acc <> ch)
        Error(_) -> Error(BadString(line, col, "\\" <> esc))
      }
    ["\\"] -> Error(UnexpectedEnd("escape character"))
    ["\n", ..rest] -> read_string(rest, line + 1, 1, acc <> "\n")
    [c, ..rest] -> read_string(rest, line, col + 1, acc <> c)
  }
}

/// Decodes a single escape character; `Error(Nil)` for an unknown escape.
fn unescape(c: String) -> Result(String, Nil) {
  case c {
    "n" -> Ok("\n")
    "t" -> Ok("\t")
    "r" -> Ok("\r")
    "\\" -> Ok("\\")
    "\"" -> Ok("\"")
    _ -> Error(Nil)
  }
}

/// Drops characters up to (but not including) the next newline (comment body).
fn drop_to_eol(chars: List(String)) -> List(String) {
  case chars {
    [] -> []
    ["\n", ..] -> chars
    [_, ..rest] -> drop_to_eol(rest)
  }
}

/// Splits off the maximal leading run of characters satisfying `pred`.
fn take_while(
  chars: List(String),
  pred: fn(String) -> Bool,
) -> #(String, List(String)) {
  do_take_while(chars, pred, "")
}

fn do_take_while(
  chars: List(String),
  pred: fn(String) -> Bool,
  acc: String,
) -> #(String, List(String)) {
  case chars {
    [c, ..rest] ->
      case pred(c) {
        True -> do_take_while(rest, pred, acc <> c)
        False -> #(acc, chars)
      }
    [] -> #(acc, chars)
  }
}

/// True for an ASCII decimal digit.
fn is_digit(c: String) -> Bool {
  string.contains("0123456789", c)
}

/// True for an ASCII hex digit (either case).
fn is_hex_digit(c: String) -> Bool {
  string.contains("0123456789abcdefABCDEF", c)
}

/// True for a character that may START a bareword (keyword / op / type): a letter or `_`.
fn is_word_start(c: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_", c)
}

/// True for a character that may CONTINUE a bareword: a letter, digit, `_`, or `.`
/// (so dotted op/const spellings like `i.add.32` and `i32.const` are a single token).
fn is_word_char(c: String) -> Bool {
  is_word_start(c) || is_digit(c) || c == "."
}

/// True for a character that may appear in a sigil name: anything but whitespace and the
/// structural delimiters. (Permits `@` so a dotted/at-laden module name round-trips.)
fn is_name_char(c: String) -> Bool {
  !string.contains("(){}[]:,=;\" \t\n\r", c)
}

// ───────────────────────────── token-level helpers ─────────────────────────────

/// Consumes a single token equal to `tok` (used for punctuation), else errors with
/// `desc` as the `expected` description.
fn expect(
  toks: List(PToken),
  tok: Token,
  desc: String,
) -> Result(List(PToken), ParseError) {
  case toks {
    [PToken(t, _, _), ..rest] if t == tok -> Ok(rest)
    [PToken(t, l, c), ..] -> Error(UnexpectedToken(l, c, desc, describe(t)))
    [] -> Error(UnexpectedEnd(desc))
  }
}

/// Consumes a `TWord` exactly equal to `w`.
fn expect_word(
  toks: List(PToken),
  w: String,
) -> Result(List(PToken), ParseError) {
  case toks {
    [PToken(TWord(x), _, _), ..rest] if x == w -> Ok(rest)
    [PToken(t, l, c), ..] -> Error(UnexpectedToken(l, c, w, describe(t)))
    [] -> Error(UnexpectedEnd(w))
  }
}

/// Consumes a `@name` token, returning the bare name. A wrong sigil yields `BadSigil`.
fn parse_at_name(
  toks: List(PToken),
) -> Result(#(String, List(PToken)), ParseError) {
  case toks {
    [PToken(TAt(n), _, _), ..rest] -> Ok(#(n, rest))
    [PToken(TLocal(_), l, c), ..] -> Error(BadSigil(l, c, "%"))
    [PToken(TLabel(_), l, c), ..] -> Error(BadSigil(l, c, "$"))
    [PToken(t, l, c), ..] -> Error(UnexpectedToken(l, c, "@name", describe(t)))
    [] -> Error(UnexpectedEnd("@name"))
  }
}

/// Consumes a `%name` token, returning the bare name. A wrong sigil yields `BadSigil`.
fn parse_local_name(
  toks: List(PToken),
) -> Result(#(String, List(PToken)), ParseError) {
  case toks {
    [PToken(TLocal(n), _, _), ..rest] -> Ok(#(n, rest))
    [PToken(TAt(_), l, c), ..] -> Error(BadSigil(l, c, "@"))
    [PToken(TLabel(_), l, c), ..] -> Error(BadSigil(l, c, "$"))
    [PToken(t, l, c), ..] -> Error(UnexpectedToken(l, c, "%name", describe(t)))
    [] -> Error(UnexpectedEnd("%name"))
  }
}

/// Consumes a `$name` token, returning the bare name. A wrong sigil yields `BadSigil`.
fn parse_label_name(
  toks: List(PToken),
) -> Result(#(String, List(PToken)), ParseError) {
  case toks {
    [PToken(TLabel(n), _, _), ..rest] -> Ok(#(n, rest))
    [PToken(TAt(_), l, c), ..] -> Error(BadSigil(l, c, "@"))
    [PToken(TLocal(_), l, c), ..] -> Error(BadSigil(l, c, "%"))
    [PToken(t, l, c), ..] -> Error(UnexpectedToken(l, c, "$label", describe(t)))
    [] -> Error(UnexpectedEnd("$label"))
  }
}

/// Consumes a string literal, returning its decoded contents.
fn parse_string(
  toks: List(PToken),
) -> Result(#(String, List(PToken)), ParseError) {
  case toks {
    [PToken(TStr(s), _, _), ..rest] -> Ok(#(s, rest))
    [PToken(t, l, c), ..] -> Error(UnexpectedToken(l, c, "string", describe(t)))
    [] -> Error(UnexpectedEnd("string"))
  }
}

/// Consumes a number token, returning its (possibly signed) integer value.
fn expect_number(
  toks: List(PToken),
) -> Result(#(Int, List(PToken)), ParseError) {
  case toks {
    [PToken(TNumber(v, _), _, _), ..rest] -> Ok(#(v, rest))
    [PToken(t, l, c), ..] -> Error(UnexpectedToken(l, c, "number", describe(t)))
    [] -> Error(UnexpectedEnd("number"))
  }
}

/// Parses a parenthesised, comma-separated list whose items are read by `item`.
/// Handles the empty list `()`.
fn parse_paren_list(
  toks: List(PToken),
  item: fn(List(PToken)) -> Result(#(a, List(PToken)), ParseError),
) -> Result(#(List(a), List(PToken)), ParseError) {
  use rest <- result.try(expect(toks, TLParen, "("))
  case rest {
    [PToken(TRParen, _, _), ..r] -> Ok(#([], r))
    _ -> parse_list_rest(rest, item, [])
  }
}

fn parse_list_rest(
  toks: List(PToken),
  item: fn(List(PToken)) -> Result(#(a, List(PToken)), ParseError),
  acc: List(a),
) -> Result(#(List(a), List(PToken)), ParseError) {
  use #(x, rest) <- result.try(item(toks))
  case rest {
    [PToken(TComma, _, _), ..r] -> parse_list_rest(r, item, [x, ..acc])
    [PToken(TRParen, _, _), ..r] -> Ok(#(list.reverse([x, ..acc]), r))
    [PToken(t, l, c), ..] -> Error(UnexpectedToken(l, c, ", or )", describe(t)))
    [] -> Error(UnexpectedEnd(", or )"))
  }
}

// ───────────────────────────── module assembly ─────────────────────────────

/// Mutable-ish accumulator for module declarations as they are parsed (lists are built
/// reversed and flipped back in `build_module`).
type ModuleAcc {
  ModuleAcc(
    numerics: Bool,
    memories: List(MemoryDecl),
    globals: List(GlobalDecl),
    imports: List(ImportDecl),
    exports: List(ExportDecl),
    data: List(DataSegment),
    functions: List(Function),
    tables: List(TableDecl),
    elements: List(ElementSegment),
    start: Option(String),
  )
}

/// Finalises a `Module` from the accumulator, restoring declaration order.
fn build_module(name: String, acc: ModuleAcc) -> Module {
  Module(
    name: name,
    uses_numerics: acc.numerics,
    memories: list.reverse(acc.memories),
    globals: list.reverse(acc.globals),
    imports: list.reverse(acc.imports),
    functions: list.reverse(acc.functions),
    exports: list.reverse(acc.exports),
    data_segments: list.reverse(acc.data),
    tables: list.reverse(acc.tables),
    elements: list.reverse(acc.elements),
    start: acc.start,
  )
}

/// Parses module-level declarations until the closing `}` (left for the caller).
///
/// Dispatches on the leading keyword: `numerics`/`memory`/`global`/`import`/`export`/`data`/
/// `func` (Phase-1) plus the Phase-2 `table`/`elem`/`start` (`«IR2-FROZEN»`). List-valued
/// items accumulate REVERSED (flipped in `build_module`); `start` overwrites (last wins).
/// Items may appear in any order. An unknown keyword is a typed `UnexpectedToken` — never a
/// panic.
fn parse_module_items(
  toks: List(PToken),
  acc: ModuleAcc,
) -> Result(#(ModuleAcc, List(PToken)), ParseError) {
  case toks {
    [PToken(TRBrace, _, _), ..] -> Ok(#(acc, toks))
    [PToken(TWord(kw), l, c), ..rest] ->
      case kw {
        "numerics" -> {
          use #(b, r) <- result.try(parse_bool(rest))
          parse_module_items(r, ModuleAcc(..acc, numerics: b))
        }
        "memory" -> {
          use #(mopt, r) <- result.try(parse_memory(rest))
          // Each `memory` line contributes at most one decl, PREPENDED (list order =
          // memory index, flipped in `build_module`). The legacy `memory none` sentinel
          // contributes nothing.
          let memories = case mopt {
            Some(m) -> [m, ..acc.memories]
            None -> acc.memories
          }
          parse_module_items(r, ModuleAcc(..acc, memories: memories))
        }
        "global" -> {
          use #(g, r) <- result.try(parse_global(rest))
          parse_module_items(r, ModuleAcc(..acc, globals: [g, ..acc.globals]))
        }
        "import" -> {
          use #(i, r) <- result.try(parse_import(rest))
          parse_module_items(r, ModuleAcc(..acc, imports: [i, ..acc.imports]))
        }
        "export" -> {
          use #(e, r) <- result.try(parse_export(rest))
          parse_module_items(r, ModuleAcc(..acc, exports: [e, ..acc.exports]))
        }
        "data" -> {
          use #(d, r) <- result.try(parse_data(rest))
          parse_module_items(r, ModuleAcc(..acc, data: [d, ..acc.data]))
        }
        "table" -> {
          use #(t, r) <- result.try(parse_table(rest))
          parse_module_items(r, ModuleAcc(..acc, tables: [t, ..acc.tables]))
        }
        "elem" -> {
          use #(el, r) <- result.try(parse_elem(rest))
          parse_module_items(
            r,
            ModuleAcc(..acc, elements: [el, ..acc.elements]),
          )
        }
        "start" -> {
          use #(fname, r) <- result.try(parse_at_name(rest))
          parse_module_items(r, ModuleAcc(..acc, start: Some(fname)))
        }
        "func" -> {
          use #(f, r) <- result.try(parse_func(rest))
          parse_module_items(
            r,
            ModuleAcc(..acc, functions: [f, ..acc.functions]),
          )
        }
        _ -> Error(UnexpectedToken(l, c, "module item", kw))
      }
    [PToken(t, l, c), ..] ->
      Error(UnexpectedToken(l, c, "module item or }", describe(t)))
    [] -> Error(UnexpectedEnd("module item or }"))
  }
}

/// Parses the `numerics` flag value (`true`/`false`).
fn parse_bool(toks: List(PToken)) -> Result(#(Bool, List(PToken)), ParseError) {
  case toks {
    [PToken(TWord("true"), _, _), ..rest] -> Ok(#(True, rest))
    [PToken(TWord("false"), _, _), ..rest] -> Ok(#(False, rest))
    [PToken(t, l, c), ..] ->
      Error(UnexpectedToken(l, c, "true or false", describe(t)))
    [] -> Error(UnexpectedEnd("true or false"))
  }
}

/// Parses one `memory` declaration (H3, §A.2.1). Returns `#(None, rest)` for the legacy
/// `memory none` sentinel (contributes no memory) and `#(Some(decl), rest)` for a sized
/// memory `[ i32 | i64 ] ( min N [max M] )`.
///
/// The optional leading address-width token selects the `IdxType`: `i64` marks a memory64
/// (`Idx64`) memory, `i32` is the explicit form of the default, and an omitted token is the
/// canonical `Idx32`. Errors (typed `ParseError`, never a panic) on a missing/malformed
/// `(min …)`. All faults flow from the total helpers.
fn parse_memory(
  toks: List(PToken),
) -> Result(#(Option(MemoryDecl), List(PToken)), ParseError) {
  case toks {
    [PToken(TWord("none"), _, _), ..rest] -> Ok(#(None, rest))
    _ -> {
      let #(idx, rest) = parse_opt_idxtype(toks)
      use #(decl, rest) <- result.try(parse_memory_sizing(rest, idx))
      Ok(#(Some(decl), rest))
    }
  }
}

/// Peeks an optional address-width token before a memory's parenthesised sizing: `i64` →
/// `Idx64`, `i32` → `Idx32` (explicit), anything else consumes nothing and defaults to
/// `Idx32`. Total — returns `#(idx_type, toks)` with `toks` advanced only if a token matched.
fn parse_opt_idxtype(toks: List(PToken)) -> #(ir.IdxType, List(PToken)) {
  case toks {
    [PToken(TWord("i64"), _, _), ..rest] -> #(ir.Idx64, rest)
    [PToken(TWord("i32"), _, _), ..rest] -> #(ir.Idx32, rest)
    _ -> #(ir.Idx32, toks)
  }
}

/// Parses a memory's parenthesised sizing `( min N [max M] )` at address-width `idx`, shared
/// by the module-level `memory` line and the `import … memory` clause. Returns the assembled
/// `MemoryDecl`, or a typed `ParseError` on a missing `(`/`min`/`)` or a malformed count.
fn parse_memory_sizing(
  toks: List(PToken),
  idx: ir.IdxType,
) -> Result(#(MemoryDecl, List(PToken)), ParseError) {
  use rest <- result.try(expect(toks, TLParen, "("))
  use rest <- result.try(expect_word(rest, "min"))
  use #(minp, rest) <- result.try(expect_number(rest))
  case rest {
    [PToken(TWord("max"), _, _), ..rest2] -> {
      use #(maxp, rest3) <- result.try(expect_number(rest2))
      use rest4 <- result.try(expect(rest3, TRParen, ")"))
      Ok(#(MemoryDecl(minp, Some(maxp), idx), rest4))
    }
    _ -> {
      use rest2 <- result.try(expect(rest, TRParen, ")"))
      Ok(#(MemoryDecl(minp, None, idx), rest2))
    }
  }
}

/// Parses `global @name : ty [mut] = <init-expr>`.
fn parse_global(
  toks: List(PToken),
) -> Result(#(GlobalDecl, List(PToken)), ParseError) {
  use #(name, rest) <- result.try(parse_at_name(toks))
  use rest <- result.try(expect(rest, TColon, ":"))
  use #(ty, rest) <- result.try(parse_valtype(rest))
  let #(mutable, rest) = case rest {
    [PToken(TWord("mut"), _, _), ..r] -> #(True, r)
    _ -> #(False, rest)
  }
  use rest <- result.try(expect(rest, TEquals, "="))
  use #(init, rest) <- result.try(parse_expr(rest))
  Ok(#(GlobalDecl(name, ty, mutable, init), rest))
}

/// Parses one import (H4, §A.2.3): `import "<a>" "<b>" <kind-clause>`.
///
/// The two leading strings are the `(module, name)` link key (for `ImportFn` the first is the
/// capability). The kind clause after them disambiguates the four variants:
/// - `: <functype>` → `ImportFn` (byte-identical to Phase-1);
/// - `global <valtype> [mut]` → `ImportGlobal`;
/// - `table <reftype> min N [max M]` → `ImportTable`;
/// - `memory [i64|i32] ( min N [max M] )` → `ImportMemory`.
/// Returns a typed `ParseError` (never a panic) on a missing string / unknown kind keyword /
/// malformed clause; the kind dispatch itself is total.
fn parse_import(
  toks: List(PToken),
) -> Result(#(ImportDecl, List(PToken)), ParseError) {
  use #(a, rest) <- result.try(parse_string(toks))
  use #(b, rest) <- result.try(parse_string(rest))
  case rest {
    [PToken(TColon, _, _), ..r] -> {
      use #(ty, r) <- result.try(parse_functype(r))
      Ok(#(ImportFn(a, b, ty), r))
    }
    [PToken(TWord("global"), _, _), ..r] -> {
      use #(ty, r) <- result.try(parse_valtype(r))
      let #(mutable, r) = case r {
        [PToken(TWord("mut"), _, _), ..r2] -> #(True, r2)
        _ -> #(False, r)
      }
      Ok(#(ir.ImportGlobal(a, b, ty, mutable), r))
    }
    [PToken(TWord("table"), _, _), ..r] -> {
      use #(ref_ty, r) <- result.try(parse_reftype(r))
      use r <- result.try(expect_word(r, "min"))
      use #(min, r) <- result.try(expect_number(r))
      let #(max, r) = parse_opt_max(r)
      Ok(#(ir.ImportTable(a, b, ref_ty, min, max), r))
    }
    [PToken(TWord("memory"), _, _), ..r] -> {
      let #(idx, r) = parse_opt_idxtype(r)
      use #(decl, r) <- result.try(parse_memory_sizing(r, idx))
      Ok(#(
        ir.ImportMemory(a, b, decl.min_pages, decl.max_pages, decl.idx_type),
        r,
      ))
    }
    [PToken(t, l, c), ..] ->
      Error(UnexpectedToken(
        l,
        c,
        "import kind (: / global / table / memory)",
        describe(t),
      ))
    [] -> Error(UnexpectedEnd("import kind"))
  }
}

/// Peeks an optional ` max M` clause. Returns `#(Some(M), rest)` when the next tokens are
/// `max <number>`, else `#(None, toks)` (unconsumed). Total — used by `table`/`import table`
/// sizings where the `min` was already read.
fn parse_opt_max(toks: List(PToken)) -> #(Option(Int), List(PToken)) {
  case toks {
    [PToken(TWord("max"), _, _), PToken(TNumber(m, _), _, _), ..rest] -> #(
      Some(m),
      rest,
    )
    _ -> #(None, toks)
  }
}

/// Parses one export (H4, §A.2.4): `export "<name>" = <target>`.
///
/// After `=`, the target disambiguates the four variants: a bare `@fn` → `ExportFn`
/// (byte-identical to Phase-1); `global @<g>` → `ExportGlobal`; `table @<t>` → `ExportTable`;
/// `memory <index>` → `ExportMemory` (a memory is named by its integer index in
/// `Module.memories`). Returns a typed `ParseError` (never a panic) on a missing name/`=` or
/// an unknown target form.
fn parse_export(
  toks: List(PToken),
) -> Result(#(ExportDecl, List(PToken)), ParseError) {
  use #(ename, rest) <- result.try(parse_string(toks))
  use rest <- result.try(expect(rest, TEquals, "="))
  case rest {
    [PToken(TAt(fname), _, _), ..r] -> Ok(#(ExportFn(ename, fname), r))
    [PToken(TWord("global"), _, _), ..r] -> {
      use #(g, r) <- result.try(parse_at_name(r))
      Ok(#(ir.ExportGlobal(ename, g), r))
    }
    [PToken(TWord("table"), _, _), ..r] -> {
      use #(t, r) <- result.try(parse_at_name(r))
      Ok(#(ir.ExportTable(ename, t), r))
    }
    [PToken(TWord("memory"), _, _), ..r] -> {
      use #(i, r) <- result.try(expect_number(r))
      Ok(#(ir.ExportMemory(ename, i), r))
    }
    [PToken(t, l, c), ..] ->
      Error(UnexpectedToken(
        l,
        c,
        "export target (@fn / global / table / memory)",
        describe(t),
      ))
    [] -> Error(UnexpectedEnd("export target"))
  }
}

/// Parses one data segment (H2, §A.2.5).
///
/// - `data passive = 0x<hex>` → `DataSegment(DataPassive, bytes)`;
/// - `data [mem=<i>] ( <offset-expr> ) = 0x<hex>` → `DataSegment(DataActive(i, offset), bytes)`
///   where the `mem=<i>` decorator defaults to `0` when omitted (byte-identical to Phase-2).
/// Returns a typed `ParseError` (never a panic) on a missing offset/`=`/hex payload.
fn parse_data(
  toks: List(PToken),
) -> Result(#(DataSegment, List(PToken)), ParseError) {
  case toks {
    [PToken(TWord("passive"), _, _), ..rest] -> {
      use rest <- result.try(expect(rest, TEquals, "="))
      use #(bytes, rest) <- result.try(parse_hexbytes(rest))
      Ok(#(DataSegment(ir.DataPassive, bytes), rest))
    }
    _ -> {
      let #(mem, rest) = parse_opt_kv(toks, "mem")
      use rest <- result.try(expect(rest, TLParen, "("))
      use #(offset, rest) <- result.try(parse_expr(rest))
      use rest <- result.try(expect(rest, TRParen, ")"))
      use rest <- result.try(expect(rest, TEquals, "="))
      use #(bytes, rest) <- result.try(parse_hexbytes(rest))
      Ok(#(DataSegment(ir.DataActive(mem, offset), bytes), rest))
    }
  }
}

/// Parses one reference table declaration (H1, §A.2.2):
/// `table @name [<reftype>] min <int> [max <int>]`.
///
/// The leading `table` keyword has already been consumed. The reference type after `@name` is
/// **optional** — an omitted reftype defaults to `FuncRef` (so the Phase-2 legacy form
/// `table @t0 min 2 max 8` still parses), while `funcref`/`externref` set it explicitly.
/// Returns `Ok(#(TableDecl, rest))` (`max` is `Some(M)` iff the `max <int>` clause is present),
/// or a typed `ParseError` (never a panic) on a missing `@name`/`min`/count.
fn parse_table(
  toks: List(PToken),
) -> Result(#(TableDecl, List(PToken)), ParseError) {
  use #(name, rest) <- result.try(parse_at_name(toks))
  let #(ref_ty, rest) = parse_opt_reftype(rest, ir.FuncRef)
  use rest <- result.try(expect_word(rest, "min"))
  use #(min, rest) <- result.try(expect_number(rest))
  let #(max, rest) = parse_opt_max(rest)
  Ok(#(TableDecl(name, ref_ty, min, max), rest))
}

/// Parses a reference type token (H1, §A.1): `funcref` → `FuncRef`, `externref` → `ExternRef`.
///
/// A dedicated, total helper accepting **only** the two reference types; any other token
/// (`i32`/`term`/…) is rejected with `UnexpectedToken(expected: "reftype")`. Used by
/// `table`/`elem`/`import table` and the reftype clauses; never panics.
fn parse_reftype(
  toks: List(PToken),
) -> Result(#(ir.RefType, List(PToken)), ParseError) {
  case toks {
    [PToken(TWord("funcref"), _, _), ..rest] -> Ok(#(ir.FuncRef, rest))
    [PToken(TWord("externref"), _, _), ..rest] -> Ok(#(ir.ExternRef, rest))
    [PToken(t, l, c), ..] ->
      Error(UnexpectedToken(l, c, "reftype", describe(t)))
    [] -> Error(UnexpectedEnd("reftype"))
  }
}

/// Peeks an OPTIONAL reference type token, defaulting to `default` when the next token is not a
/// reftype. Total — advances `toks` only if a `funcref`/`externref` token matched. Used where
/// the reftype is elided in the legacy spelling (`table`).
fn parse_opt_reftype(
  toks: List(PToken),
  default: ir.RefType,
) -> #(ir.RefType, List(PToken)) {
  case toks {
    [PToken(TWord("funcref"), _, _), ..rest] -> #(ir.FuncRef, rest)
    [PToken(TWord("externref"), _, _), ..rest] -> #(ir.ExternRef, rest)
    _ -> #(default, toks)
  }
}

/// Parses one element segment (H2, §A.2.6). Two spellings, both producing an
/// `ElementSegment(mode, ref_ty, init)`:
///
/// - **Legacy** — `elem @table ( <offset> ) [ <init>,* ]` starts with `@table`; the reftype
///   defaults to `FuncRef` and the mode is `ElemActive`. Keeps `mem_table.ir` parsing.
/// - **Canonical** — `elem <reftype> <mode> [ <init>,* ]` starts with a reftype keyword, then
///   the mode (`@table ( <offset> )` active / `passive` / `declare`).
///
/// The leading `elem` keyword has already been consumed; dispatch is on the token after it (a
/// reftype keyword ⇒ canonical, `@table` ⇒ legacy). The bracketed `init` list is read by
/// `parse_ref_init_list` (each item an `@name` funcidx abbreviation or a full ref-producing
/// expression). Returns a typed `ParseError` (never a panic) on any malformed piece.
fn parse_elem(
  toks: List(PToken),
) -> Result(#(ElementSegment, List(PToken)), ParseError) {
  case toks {
    [PToken(TWord("funcref"), _, _), ..]
    | [PToken(TWord("externref"), _, _), ..] -> {
      use #(ref_ty, rest) <- result.try(parse_reftype(toks))
      use #(mode, rest) <- result.try(parse_elem_mode(rest))
      use #(init, rest) <- result.try(parse_ref_init_list(rest))
      Ok(#(ElementSegment(mode, ref_ty, init), rest))
    }
    _ -> {
      // Legacy active-funcref form: `@table ( <offset> ) [ <init>,* ]`.
      use #(table, rest) <- result.try(parse_at_name(toks))
      use rest <- result.try(expect(rest, TLParen, "("))
      use #(offset, rest) <- result.try(parse_expr(rest))
      use rest <- result.try(expect(rest, TRParen, ")"))
      use #(init, rest) <- result.try(parse_ref_init_list(rest))
      Ok(#(ElementSegment(ir.ElemActive(table, offset), ir.FuncRef, init), rest))
    }
  }
}

/// Parses an element-segment mode (§A.2.6): `@table ( <offset-expr> )` → `ElemActive`,
/// `passive` → `ElemPassive`, `declare` → `ElemDeclarative`. Returns a typed `ParseError`
/// (never a panic) on a missing `@table`/offset-parens or an unrecognised mode token.
fn parse_elem_mode(
  toks: List(PToken),
) -> Result(#(ir.ElemMode, List(PToken)), ParseError) {
  case toks {
    [PToken(TWord("passive"), _, _), ..rest] -> Ok(#(ir.ElemPassive, rest))
    [PToken(TWord("declare"), _, _), ..rest] -> Ok(#(ir.ElemDeclarative, rest))
    [PToken(TAt(table), _, _), ..rest] -> {
      use rest <- result.try(expect(rest, TLParen, "("))
      use #(offset, rest) <- result.try(parse_expr(rest))
      use rest <- result.try(expect(rest, TRParen, ")"))
      Ok(#(ir.ElemActive(table, offset), rest))
    }
    [PToken(t, l, c), ..] ->
      Error(UnexpectedToken(
        l,
        c,
        "elem mode (@table / passive / declare)",
        describe(t),
      ))
    [] -> Error(UnexpectedEnd("elem mode"))
  }
}

/// Parses a bracketed, comma-separated element-init list `[ <item>,* ]` / `[]` (§A.2.6).
///
/// Each item is either an `@name` funcidx abbreviation (WAT-style — desugars to
/// `RefFunc(name)`) or a full ref-producing expression (`ref.func @f`, a null slot
/// `values (null.<reftype>)`, `global.get @g`, …). Returns `Ok(#(items, rest))` or a typed
/// `ParseError` (never a panic) on a missing `[`/`,`/`]`.
fn parse_ref_init_list(
  toks: List(PToken),
) -> Result(#(List(Expr), List(PToken)), ParseError) {
  use rest <- result.try(expect(toks, TLBracket, "["))
  case rest {
    [PToken(TRBracket, _, _), ..r] -> Ok(#([], r))
    _ -> parse_ref_init_rest(rest, [])
  }
}

/// Tail of `parse_ref_init_list`: reads one init item, then either a `,` (continue) or the
/// closing `]`. Accumulates reversed and flips at the close. Total.
fn parse_ref_init_rest(
  toks: List(PToken),
  acc: List(Expr),
) -> Result(#(List(Expr), List(PToken)), ParseError) {
  use #(item, rest) <- result.try(parse_ref_init(toks))
  case rest {
    [PToken(TComma, _, _), ..r] -> parse_ref_init_rest(r, [item, ..acc])
    [PToken(TRBracket, _, _), ..r] -> Ok(#(list.reverse([item, ..acc]), r))
    [PToken(t, l, c), ..] -> Error(UnexpectedToken(l, c, ", or ]", describe(t)))
    [] -> Error(UnexpectedEnd(", or ]"))
  }
}

/// Parses one element-init item: a bare `@name` (the funcidx abbreviation → `RefFunc(name)`)
/// or any full ref-producing expression via `parse_expr`. Total — a bad item surfaces as a
/// typed `ParseError` from the delegate.
fn parse_ref_init(
  toks: List(PToken),
) -> Result(#(Expr, List(PToken)), ParseError) {
  case toks {
    [PToken(TAt(name), _, _), ..rest] -> Ok(#(ir.RefFunc(name), rest))
    _ -> parse_expr(toks)
  }
}

/// Parses an `0x`-prefixed byte string into a `BitArray` (two hex digits per byte).
fn parse_hexbytes(
  toks: List(PToken),
) -> Result(#(BitArray, List(PToken)), ParseError) {
  case toks {
    [PToken(TNumber(_, lexeme), l, c), ..rest] ->
      case string.starts_with(lexeme, "0x") {
        True ->
          case hex_to_bytes(string.drop_start(lexeme, 2)) {
            Ok(b) -> Ok(#(b, rest))
            Error(_) -> Error(BadNumberLiteral(l, c, lexeme))
          }
        False -> Error(UnexpectedToken(l, c, "0x hexbytes", lexeme))
      }
    [PToken(t, l, c), ..] ->
      Error(UnexpectedToken(l, c, "0x hexbytes", describe(t)))
    [] -> Error(UnexpectedEnd("0x hexbytes"))
  }
}

/// Converts an even-length hex string into a `BitArray`; `Error(Nil)` on odd length or
/// a non-hex pair.
fn hex_to_bytes(hex: String) -> Result(BitArray, Nil) {
  do_hex_to_bytes(string.to_graphemes(hex), [])
}

fn do_hex_to_bytes(
  chars: List(String),
  acc: List(BitArray),
) -> Result(BitArray, Nil) {
  case chars {
    [] -> Ok(bit_array.concat(list.reverse(acc)))
    [a, b, ..rest] ->
      case int.base_parse(string.lowercase(a <> b), 16) {
        Ok(byte) -> do_hex_to_bytes(rest, [<<byte:8>>, ..acc])
        Error(_) -> Error(Nil)
      }
    [_] -> Error(Nil)
  }
}

/// Parses a whole function: `func @name (params) -> (results) { locals* body }`.
fn parse_func(
  toks: List(PToken),
) -> Result(#(Function, List(PToken)), ParseError) {
  use #(fname, rest) <- result.try(parse_at_name(toks))
  use #(params, rest) <- result.try(parse_paren_list(rest, parse_param))
  use rest <- result.try(expect(rest, TArrow, "->"))
  use #(results, rest) <- result.try(parse_paren_list(rest, parse_valtype))
  use rest <- result.try(expect(rest, TLBrace, "{"))
  use #(locals, rest) <- result.try(parse_locals(rest, []))
  use #(body, rest) <- result.try(parse_expr(rest))
  use rest <- result.try(expect(rest, TRBrace, "}"))
  Ok(#(Function(fname, params, results, locals, body), rest))
}

/// Parses zero or more `local %name : ty` declarations at a function's head.
fn parse_locals(
  toks: List(PToken),
  acc: List(Local),
) -> Result(#(List(Local), List(PToken)), ParseError) {
  case toks {
    [PToken(TWord("local"), _, _), ..rest] -> {
      use #(name, rest) <- result.try(parse_local_name(rest))
      use rest <- result.try(expect(rest, TColon, ":"))
      use #(ty, rest) <- result.try(parse_valtype(rest))
      parse_locals(rest, [Local(name, ty), ..acc])
    }
    _ -> Ok(#(list.reverse(acc), toks))
  }
}

/// Parses a named param slot: `%name : ty`.
fn parse_param(
  toks: List(PToken),
) -> Result(#(Local, List(PToken)), ParseError) {
  use #(name, rest) <- result.try(parse_local_name(toks))
  use rest <- result.try(expect(rest, TColon, ":"))
  use #(ty, rest) <- result.try(parse_valtype(rest))
  Ok(#(Local(name, ty), rest))
}

// ───────────────────────────── types & values ─────────────────────────────

/// Parses a value type token (`i32`/`i64`/`f32`/`f64`/`term`/`funcref`/`externref`). The two
/// reference types (H1) are legal in every valtype position (params/locals/globals/functype/
/// `mem.load` result); a `funcref`/`externref` maps to `TFuncRef`/`TExternRef`.
fn parse_valtype(
  toks: List(PToken),
) -> Result(#(ValType, List(PToken)), ParseError) {
  case toks {
    [PToken(TWord(w), l, c), ..rest] ->
      case w {
        "i32" -> Ok(#(TI32, rest))
        "i64" -> Ok(#(TI64, rest))
        "f32" -> Ok(#(TF32, rest))
        "f64" -> Ok(#(TF64, rest))
        "term" -> Ok(#(TTerm, rest))
        "funcref" -> Ok(#(ir.TFuncRef, rest))
        "externref" -> Ok(#(ir.TExternRef, rest))
        // Phase-6 SIMD value type (I1). Conformance-neutral; P6-02 owns the full round-trip.
        "v128" -> Ok(#(ir.TV128, rest))
        _ -> Error(UnexpectedToken(l, c, "valtype", w))
      }
    [PToken(t, l, c), ..] ->
      Error(UnexpectedToken(l, c, "valtype", describe(t)))
    [] -> Error(UnexpectedEnd("valtype"))
  }
}

/// Parses a nameless signature `(valtypes) -> (valtypes)`.
fn parse_functype(
  toks: List(PToken),
) -> Result(#(FuncType, List(PToken)), ParseError) {
  use #(params, rest) <- result.try(parse_paren_list(toks, parse_valtype))
  use rest <- result.try(expect(rest, TArrow, "->"))
  use #(results, rest) <- result.try(parse_paren_list(rest, parse_valtype))
  Ok(#(FuncType(params, results), rest))
}

/// Parses an atomic value operand: `%name`, or `<type>.const <number>`.
fn parse_value(
  toks: List(PToken),
) -> Result(#(Value, List(PToken)), ParseError) {
  case toks {
    [PToken(TLocal(name), _, _), ..rest] -> Ok(#(Var(name), rest))
    [PToken(TWord(w), l, c), ..rest] ->
      case w {
        "i32.const" -> {
          use #(n, rest) <- result.try(expect_number(rest))
          Ok(#(ConstI32(n), rest))
        }
        "i64.const" -> {
          use #(n, rest) <- result.try(expect_number(rest))
          Ok(#(ConstI64(n), rest))
        }
        "f32.const" -> {
          use #(n, rest) <- result.try(expect_number(rest))
          Ok(#(ConstF32(n), rest))
        }
        "f64.const" -> {
          use #(n, rest) <- result.try(expect_number(rest))
          Ok(#(ConstF64(n), rest))
        }
        // The null-reference literal, tagged by reftype (R1c): `null.funcref` / `null.externref`.
        "null.funcref" -> Ok(#(ir.ConstNull(ir.FuncRef), rest))
        "null.externref" -> Ok(#(ir.ConstNull(ir.ExternRef), rest))
        // The `v128.const` literal — 16 raw little-endian bytes as `0x` + hex (I1/D5). P6-02
        // owns the full round-trip + the `bit_size == 128` validation; the keystone just parses.
        "v128.const" -> {
          use #(bytes, rest) <- result.try(parse_hexbytes(rest))
          Ok(#(ir.ConstV128(bytes), rest))
        }
        _ -> Error(UnexpectedToken(l, c, "value", w))
      }
    [PToken(t, l, c), ..] -> Error(UnexpectedToken(l, c, "value", describe(t)))
    [] -> Error(UnexpectedEnd("value"))
  }
}

/// Parses a loop iteration variable: `%name : ty = <init-value>`.
fn parse_loopparam(
  toks: List(PToken),
) -> Result(#(LoopParam, List(PToken)), ParseError) {
  use #(name, rest) <- result.try(parse_local_name(toks))
  use rest <- result.try(expect(rest, TColon, ":"))
  use #(ty, rest) <- result.try(parse_valtype(rest))
  use rest <- result.try(expect(rest, TEquals, "="))
  use #(init, rest) <- result.try(parse_value(rest))
  Ok(#(LoopParam(name, ty, init), rest))
}

/// Parses a parenthesised value list `(v, …)`.
fn parse_value_list(
  toks: List(PToken),
) -> Result(#(List(Value), List(PToken)), ParseError) {
  parse_paren_list(toks, parse_value)
}

// ───────────────────────────── expressions ─────────────────────────────

/// Parses an expression, dispatching on the leading keyword. Recurses for the bodies of
/// the sequencing forms (`let`/`charge`) and the structured-control forms.
fn parse_expr(toks: List(PToken)) -> Result(#(Expr, List(PToken)), ParseError) {
  case toks {
    [PToken(TWord(kw), l, c), ..rest] ->
      case kw {
        "values" -> {
          use #(vs, rest) <- result.try(parse_value_list(rest))
          Ok(#(Values(vs), rest))
        }
        "num" -> parse_num(rest)
        "convert" -> parse_convert(rest)
        "term" -> parse_term(rest)
        // The four existing memory nodes accept a trailing `mem=<n>` decorator (§A.6),
        // defaulting to index 0 when omitted (byte-identical to Phase-4).
        "mem.size" -> {
          let #(mem, rest) = parse_opt_kv(rest, "mem")
          Ok(#(MemSize(mem), rest))
        }
        "mem.grow" -> {
          use #(delta, rest) <- result.try(parse_value(rest))
          let #(mem, rest) = parse_opt_kv(rest, "mem")
          Ok(#(MemGrow(mem, delta), rest))
        }
        "mem.load" -> parse_mem_load(rest)
        "mem.store" -> parse_mem_store(rest)
        // ── Phase-5 reference / table / bulk expressions (H2, §A.3–§A.5). ──
        "ref.func" -> {
          use #(n, rest) <- result.try(parse_at_name(rest))
          Ok(#(ir.RefFunc(n), rest))
        }
        "ref.is_null" -> {
          use #(v, rest) <- result.try(parse_value(rest))
          Ok(#(ir.RefIsNull(v), rest))
        }
        "table.get" -> {
          use #(t, rest) <- result.try(parse_at_name(rest))
          use #(i, rest) <- result.try(parse_value(rest))
          Ok(#(ir.TableGet(t, i), rest))
        }
        "table.set" -> {
          use #(t, rest) <- result.try(parse_at_name(rest))
          use #(i, rest) <- result.try(parse_value(rest))
          use #(v, rest) <- result.try(parse_value(rest))
          Ok(#(ir.TableSet(t, i, v), rest))
        }
        "table.size" -> {
          use #(t, rest) <- result.try(parse_at_name(rest))
          Ok(#(ir.TableSize(t), rest))
        }
        "table.grow" -> {
          use #(t, rest) <- result.try(parse_at_name(rest))
          use #(d, rest) <- result.try(parse_value(rest))
          use #(init, rest) <- result.try(parse_value(rest))
          Ok(#(ir.TableGrow(t, d, init), rest))
        }
        "table.fill" -> {
          use #(t, rest) <- result.try(parse_at_name(rest))
          use #(off, rest) <- result.try(parse_value(rest))
          use #(v, rest) <- result.try(parse_value(rest))
          use #(cnt, rest) <- result.try(parse_value(rest))
          Ok(#(ir.TableFill(t, off, v, cnt), rest))
        }
        "table.init" -> {
          use #(t, rest) <- result.try(parse_at_name(rest))
          use #(dst, rest) <- result.try(parse_value(rest))
          use #(src, rest) <- result.try(parse_value(rest))
          use #(cnt, rest) <- result.try(parse_value(rest))
          use #(seg, rest) <- result.try(parse_seg(rest))
          Ok(#(ir.TableInit(t, seg, dst, src, cnt), rest))
        }
        "table.copy" -> {
          use #(dt, rest) <- result.try(parse_at_name(rest))
          use #(st, rest) <- result.try(parse_at_name(rest))
          use #(dst, rest) <- result.try(parse_value(rest))
          use #(src, rest) <- result.try(parse_value(rest))
          use #(cnt, rest) <- result.try(parse_value(rest))
          Ok(#(ir.TableCopy(dt, st, dst, src, cnt), rest))
        }
        "elem.drop" -> {
          use #(seg, rest) <- result.try(parse_seg(rest))
          Ok(#(ir.ElemDrop(seg), rest))
        }
        "mem.fill" -> {
          use #(dst, rest) <- result.try(parse_value(rest))
          use #(v, rest) <- result.try(parse_value(rest))
          use #(cnt, rest) <- result.try(parse_value(rest))
          let #(mem, rest) = parse_opt_kv(rest, "mem")
          Ok(#(ir.MemFill(mem, dst, v, cnt), rest))
        }
        "mem.copy" -> {
          use #(dst, rest) <- result.try(parse_value(rest))
          use #(src, rest) <- result.try(parse_value(rest))
          use #(cnt, rest) <- result.try(parse_value(rest))
          let #(dst_mem, rest) = parse_opt_kv(rest, "dst_mem")
          let #(src_mem, rest) = parse_opt_kv(rest, "src_mem")
          Ok(#(ir.MemCopy(dst_mem, src_mem, dst, src, cnt), rest))
        }
        "mem.init" -> {
          use #(dst, rest) <- result.try(parse_value(rest))
          use #(src, rest) <- result.try(parse_value(rest))
          use #(cnt, rest) <- result.try(parse_value(rest))
          use #(seg, rest) <- result.try(parse_seg(rest))
          let #(mem, rest) = parse_opt_kv(rest, "mem")
          Ok(#(ir.MemInit(mem, seg, dst, src, cnt), rest))
        }
        "data.drop" -> {
          use #(seg, rest) <- result.try(parse_seg(rest))
          Ok(#(ir.DataDrop(seg), rest))
        }
        "global.get" -> {
          use #(name, rest) <- result.try(parse_at_name(rest))
          Ok(#(GlobalGet(name), rest))
        }
        "global.set" -> {
          use #(name, rest) <- result.try(parse_at_name(rest))
          use #(v, rest) <- result.try(parse_value(rest))
          Ok(#(GlobalSet(name, v), rest))
        }
        "call" -> {
          use #(fname, rest) <- result.try(parse_at_name(rest))
          use #(args, rest) <- result.try(parse_value_list(rest))
          Ok(#(CallDirect(fname, args), rest))
        }
        "call_indirect" -> parse_call_indirect(rest)
        "call_host" -> parse_call_host(rest)
        "let" -> parse_let(rest)
        "block" -> parse_block(rest)
        "loop" -> parse_loop(rest)
        "if" -> parse_if(rest)
        "switch" -> parse_switch(rest)
        "break" -> {
          use #(label, rest) <- result.try(parse_label_name(rest))
          use #(vs, rest) <- result.try(parse_value_list(rest))
          Ok(#(Break(label, vs), rest))
        }
        "continue" -> {
          use #(label, rest) <- result.try(parse_label_name(rest))
          use #(vs, rest) <- result.try(parse_value_list(rest))
          Ok(#(Continue(label, vs), rest))
        }
        "return" -> {
          use #(vs, rest) <- result.try(parse_value_list(rest))
          Ok(#(Return(vs), rest))
        }
        "trap" -> parse_trap(rest)
        "charge" -> {
          use #(cost, rest) <- result.try(expect_number(rest))
          use #(body, rest) <- result.try(parse_expr(rest))
          Ok(#(Charge(cost, body), rest))
        }
        _ -> Error(UnexpectedToken(l, c, "expression", kw))
      }
    [PToken(t, l, c), ..] ->
      Error(UnexpectedToken(l, c, "expression", describe(t)))
    [] -> Error(UnexpectedEnd("expression"))
  }
}

/// Parses `num <numop> (args)`.
fn parse_num(toks: List(PToken)) -> Result(#(Expr, List(PToken)), ParseError) {
  case toks {
    [PToken(TWord(w), l, c), ..rest] ->
      case string_to_numop(w) {
        Ok(op) -> {
          use #(args, rest) <- result.try(parse_value_list(rest))
          Ok(#(Num(op, args), rest))
        }
        Error(_) -> Error(UnknownOp(l, c, w))
      }
    [PToken(t, l, c), ..] ->
      Error(UnexpectedToken(l, c, "numeric op", describe(t)))
    [] -> Error(UnexpectedEnd("numeric op"))
  }
}

/// Parses `convert <convop> <value>`.
fn parse_convert(
  toks: List(PToken),
) -> Result(#(Expr, List(PToken)), ParseError) {
  case toks {
    [PToken(TWord(w), l, c), ..rest] ->
      case string_to_convop(w) {
        Ok(op) -> {
          use #(arg, rest) <- result.try(parse_value(rest))
          Ok(#(Convert(op, arg), rest))
        }
        Error(_) -> Error(UnknownOp(l, c, w))
      }
    [PToken(t, l, c), ..] ->
      Error(UnexpectedToken(l, c, "conversion op", describe(t)))
    [] -> Error(UnexpectedEnd("conversion op"))
  }
}

/// Parses `term <termop> (args)`.
fn parse_term(toks: List(PToken)) -> Result(#(Expr, List(PToken)), ParseError) {
  case toks {
    [PToken(TWord(w), l, c), ..rest] ->
      case string_to_termop(w) {
        Ok(op) -> {
          use #(args, rest) <- result.try(parse_value_list(rest))
          Ok(#(TermOp(op, args), rest))
        }
        Error(_) -> Error(UnknownOp(l, c, w))
      }
    [PToken(t, l, c), ..] ->
      Error(UnexpectedToken(l, c, "term op", describe(t)))
    [] -> Error(UnexpectedEnd("term op"))
  }
}

/// Parses `mem.load <result-valtype> <memaccess> <addr> offset=<int> [mem=<int>]`. The leading
/// result valtype disambiguates the loaded value's width/sign (e.g. `i32.load8_s` vs
/// `i64.load8_s`); the trailing `mem=<int>` memory-index decorator (§A.6) defaults to 0.
fn parse_mem_load(
  toks: List(PToken),
) -> Result(#(Expr, List(PToken)), ParseError) {
  use #(result, rest) <- result.try(parse_valtype(toks))
  use #(macc, rest) <- result.try(parse_memaccess(rest))
  use #(addr, rest) <- result.try(parse_value(rest))
  use rest <- result.try(expect_word(rest, "offset"))
  use rest <- result.try(expect(rest, TEquals, "="))
  use #(off, rest) <- result.try(expect_number(rest))
  let #(mem, rest) = parse_opt_kv(rest, "mem")
  Ok(#(MemLoad(mem, macc, addr, off, result), rest))
}

/// Parses `mem.store <memaccess> <addr> <value> offset=<int> [mem=<int>]`. The trailing
/// `mem=<int>` memory-index decorator (§A.6) defaults to 0 when omitted.
fn parse_mem_store(
  toks: List(PToken),
) -> Result(#(Expr, List(PToken)), ParseError) {
  use #(macc, rest) <- result.try(parse_memaccess(toks))
  use #(addr, rest) <- result.try(parse_value(rest))
  use #(val, rest) <- result.try(parse_value(rest))
  use rest <- result.try(expect_word(rest, "offset"))
  use rest <- result.try(expect(rest, TEquals, "="))
  use #(off, rest) <- result.try(expect_number(rest))
  let #(mem, rest) = parse_opt_kv(rest, "mem")
  Ok(#(MemStore(mem, macc, addr, val, off), rest))
}

/// Parses a memory-access descriptor: `<bytes>` optionally followed by `signed`.
fn parse_memaccess(
  toks: List(PToken),
) -> Result(#(MemAccess, List(PToken)), ParseError) {
  use #(bytes, rest) <- result.try(expect_number(toks))
  case rest {
    [PToken(TWord("signed"), _, _), ..r] -> Ok(#(MemAccess(bytes, True), r))
    _ -> Ok(#(MemAccess(bytes, False), rest))
  }
}

/// Peek-parses an OPTIONAL `<key>=<int>` decorator (§A.6) — the memory-index family
/// (`mem`/`dst_mem`/`src_mem`). Returns `#(value, rest)` when the next three tokens are exactly
/// `<key> = <number>`, else the default `#(0, toks)` (nothing consumed).
///
/// TOTAL and UNAMBIGUOUS: it matches only when a `TWord(key)` is IMMEDIATELY followed by `=`
/// (and a number). No IR expression keyword is a bare `mem`/`dst_mem`/`src_mem` word (they are
/// all dotted — `mem.size`, `mem.fill`, … — or distinct), so a following statement in a
/// `let`/`charge` continuation can never begin with `<key> =` and this peek cannot swallow it.
fn parse_opt_kv(toks: List(PToken), key: String) -> #(Int, List(PToken)) {
  case toks {
    [
      PToken(TWord(k), _, _),
      PToken(TEquals, _, _),
      PToken(TNumber(v, _), _, _),
      ..rest
    ]
      if k == key
    -> #(v, rest)
    _ -> #(0, toks)
  }
}

/// Parses a MANDATORY `seg=<int>` decorator (the passive-segment index into
/// `Module.elements` / `Module.data_segments`). Unlike `parse_opt_kv` a missing/malformed
/// `seg=` is an error (a segment index is never defaulted). Returns the index, or a typed
/// `ParseError` (never a panic) on a missing `seg`/`=`/number. Used by
/// `table.init`/`mem.init`/`elem.drop`/`data.drop`.
fn parse_seg(toks: List(PToken)) -> Result(#(Int, List(PToken)), ParseError) {
  use rest <- result.try(expect_word(toks, "seg"))
  use rest <- result.try(expect(rest, TEquals, "="))
  expect_number(rest)
}

/// Parses `call_indirect @table [<index>] : <functype> (args)`.
fn parse_call_indirect(
  toks: List(PToken),
) -> Result(#(Expr, List(PToken)), ParseError) {
  use #(table, rest) <- result.try(parse_at_name(toks))
  use rest <- result.try(expect(rest, TLBracket, "["))
  use #(index, rest) <- result.try(parse_value(rest))
  use rest <- result.try(expect(rest, TRBracket, "]"))
  use rest <- result.try(expect(rest, TColon, ":"))
  use #(ty, rest) <- result.try(parse_functype(rest))
  use #(args, rest) <- result.try(parse_value_list(rest))
  Ok(#(CallIndirect(table, index, ty, args), rest))
}

/// Parses `call_host "cap" "name" (args)`.
fn parse_call_host(
  toks: List(PToken),
) -> Result(#(Expr, List(PToken)), ParseError) {
  use #(cap, rest) <- result.try(parse_string(toks))
  use #(name, rest) <- result.try(parse_string(rest))
  use #(args, rest) <- result.try(parse_value_list(rest))
  Ok(#(CallHost(cap, name, args), rest))
}

/// Parses `let (%names) = <rhs-expr> <body-expr>` (the body simply follows the rhs;
/// any `;` between them is an empty comment).
fn parse_let(toks: List(PToken)) -> Result(#(Expr, List(PToken)), ParseError) {
  use #(names, rest) <- result.try(parse_paren_list(toks, parse_local_name))
  use rest <- result.try(expect(rest, TEquals, "="))
  use #(rhs, rest) <- result.try(parse_expr(rest))
  use #(body, rest) <- result.try(parse_expr(rest))
  Ok(#(Let(names, rhs, body), rest))
}

/// Parses `block $label : (results) { body }`.
fn parse_block(
  toks: List(PToken),
) -> Result(#(Expr, List(PToken)), ParseError) {
  use #(label, rest) <- result.try(parse_label_name(toks))
  use rest <- result.try(expect(rest, TColon, ":"))
  use #(result, rest) <- result.try(parse_paren_list(rest, parse_valtype))
  use rest <- result.try(expect(rest, TLBrace, "{"))
  use #(body, rest) <- result.try(parse_expr(rest))
  use rest <- result.try(expect(rest, TRBrace, "}"))
  Ok(#(Block(label, result, body), rest))
}

/// Parses `loop $label (loopparams) : (results) { body }`.
fn parse_loop(toks: List(PToken)) -> Result(#(Expr, List(PToken)), ParseError) {
  use #(label, rest) <- result.try(parse_label_name(toks))
  use #(params, rest) <- result.try(parse_paren_list(rest, parse_loopparam))
  use rest <- result.try(expect(rest, TColon, ":"))
  use #(result, rest) <- result.try(parse_paren_list(rest, parse_valtype))
  use rest <- result.try(expect(rest, TLBrace, "{"))
  use #(body, rest) <- result.try(parse_expr(rest))
  use rest <- result.try(expect(rest, TRBrace, "}"))
  Ok(#(Loop(label, params, result, body), rest))
}

/// Parses `if <value> : (results) { then } else { else }`.
fn parse_if(toks: List(PToken)) -> Result(#(Expr, List(PToken)), ParseError) {
  use #(cond, rest) <- result.try(parse_value(toks))
  use rest <- result.try(expect(rest, TColon, ":"))
  use #(result, rest) <- result.try(parse_paren_list(rest, parse_valtype))
  use rest <- result.try(expect(rest, TLBrace, "{"))
  use #(then_b, rest) <- result.try(parse_expr(rest))
  use rest <- result.try(expect(rest, TRBrace, "}"))
  use rest <- result.try(expect_word(rest, "else"))
  use rest <- result.try(expect(rest, TLBrace, "{"))
  use #(else_b, rest) <- result.try(parse_expr(rest))
  use rest <- result.try(expect(rest, TRBrace, "}"))
  Ok(#(If(cond, result, then_b, else_b), rest))
}

/// Parses `switch <value> : (results) { case N { … }* default { … } }`.
fn parse_switch(
  toks: List(PToken),
) -> Result(#(Expr, List(PToken)), ParseError) {
  use #(selector, rest) <- result.try(parse_value(toks))
  use rest <- result.try(expect(rest, TColon, ":"))
  use #(result, rest) <- result.try(parse_paren_list(rest, parse_valtype))
  use rest <- result.try(expect(rest, TLBrace, "{"))
  use #(arms, rest) <- result.try(parse_arms(rest, []))
  use rest <- result.try(expect_word(rest, "default"))
  use rest <- result.try(expect(rest, TLBrace, "{"))
  use #(default, rest) <- result.try(parse_expr(rest))
  use rest <- result.try(expect(rest, TRBrace, "}"))
  use rest <- result.try(expect(rest, TRBrace, "}"))
  Ok(#(Switch(selector, result, arms, default), rest))
}

/// Parses zero or more `case N { body }` arms until the `default` keyword.
fn parse_arms(
  toks: List(PToken),
  acc: List(SwitchArm),
) -> Result(#(List(SwitchArm), List(PToken)), ParseError) {
  case toks {
    [PToken(TWord("case"), _, _), ..rest] -> {
      use #(match, rest) <- result.try(expect_number(rest))
      use rest <- result.try(expect(rest, TLBrace, "{"))
      use #(body, rest) <- result.try(parse_expr(rest))
      use rest <- result.try(expect(rest, TRBrace, "}"))
      parse_arms(rest, [SwitchArm(match, body), ..acc])
    }
    _ -> Ok(#(list.reverse(acc), toks))
  }
}

/// Parses `trap <trapreason>`.
fn parse_trap(toks: List(PToken)) -> Result(#(Expr, List(PToken)), ParseError) {
  case toks {
    [PToken(TWord(w), l, c), ..rest] ->
      case string_to_trapreason(w) {
        Ok(r) -> Ok(#(Trap(r), rest))
        Error(_) -> Error(UnknownOp(l, c, w))
      }
    [PToken(t, l, c), ..] ->
      Error(UnexpectedToken(l, c, "trap reason", describe(t)))
    [] -> Error(UnexpectedEnd("trap reason"))
  }
}

// ───────────────────────────── op spelling tables (mirror of printer) ────────────

/// Parses a neutral, width-tagged numeric op spelling (`i.add.32`, `f.div.64`, …).
fn string_to_numop(w: String) -> Result(NumOp, Nil) {
  case string.split(w, ".") {
    ["i", mnem, ws] -> {
      use width <- result.try(parse_iwidth(ws))
      int_mnemonic(mnem, width)
    }
    ["f", mnem, ws] -> {
      use width <- result.try(parse_fwidth(ws))
      float_mnemonic(mnem, width)
    }
    _ -> Error(Nil)
  }
}

fn parse_iwidth(s: String) -> Result(IntWidth, Nil) {
  case s {
    "32" -> Ok(W32)
    "64" -> Ok(W64)
    _ -> Error(Nil)
  }
}

fn parse_fwidth(s: String) -> Result(FloatWidth, Nil) {
  case s {
    "32" -> Ok(FW32)
    "64" -> Ok(FW64)
    _ -> Error(Nil)
  }
}

fn int_mnemonic(m: String, w: IntWidth) -> Result(NumOp, Nil) {
  case m {
    "add" -> Ok(IAdd(w))
    "sub" -> Ok(ISub(w))
    "mul" -> Ok(IMul(w))
    "div_s" -> Ok(IDivS(w))
    "div_u" -> Ok(IDivU(w))
    "rem_s" -> Ok(IRemS(w))
    "rem_u" -> Ok(IRemU(w))
    "and" -> Ok(IAnd(w))
    "or" -> Ok(IOr(w))
    "xor" -> Ok(IXor(w))
    "shl" -> Ok(IShl(w))
    "shr_s" -> Ok(IShrS(w))
    "shr_u" -> Ok(IShrU(w))
    "rotl" -> Ok(IRotl(w))
    "rotr" -> Ok(IRotr(w))
    "clz" -> Ok(IClz(w))
    "ctz" -> Ok(ICtz(w))
    "popcnt" -> Ok(IPopcnt(w))
    "eqz" -> Ok(IEqz(w))
    "eq" -> Ok(IEq(w))
    "ne" -> Ok(INe(w))
    "lt_s" -> Ok(ILtS(w))
    "lt_u" -> Ok(ILtU(w))
    "gt_s" -> Ok(IGtS(w))
    "gt_u" -> Ok(IGtU(w))
    "le_s" -> Ok(ILeS(w))
    "le_u" -> Ok(ILeU(w))
    "ge_s" -> Ok(IGeS(w))
    "ge_u" -> Ok(IGeU(w))
    _ -> Error(Nil)
  }
}

/// Resolves a float mnemonic (the middle segment of `f.<mnemonic>.<W>`) to its `NumOp`
/// constructor at width `w`. Mirrors `printer.numop_to_string`'s float arms. The Phase-2
/// additions (`abs`/`neg`/`ceil`/`floor`/`trunc`/`nearest`/`sqrt`/`copysign` and the six
/// comparisons `eq`/`ne`/`lt`/`gt`/`le`/`ge`) are sign-agnostic (no `_s`/`_u`). `Error(Nil)`
/// for an unknown mnemonic (surfaced as `UnknownOp` by `parse_num`).
fn float_mnemonic(m: String, w: FloatWidth) -> Result(NumOp, Nil) {
  case m {
    "add" -> Ok(FAdd(w))
    "sub" -> Ok(FSub(w))
    "mul" -> Ok(FMul(w))
    "div" -> Ok(FDiv(w))
    "min" -> Ok(FMin(w))
    "max" -> Ok(FMax(w))
    "abs" -> Ok(FAbs(w))
    "neg" -> Ok(FNeg(w))
    "ceil" -> Ok(FCeil(w))
    "floor" -> Ok(FFloor(w))
    "trunc" -> Ok(FTrunc(w))
    "nearest" -> Ok(FNearest(w))
    "sqrt" -> Ok(FSqrt(w))
    "copysign" -> Ok(FCopysign(w))
    "eq" -> Ok(FEq(w))
    "ne" -> Ok(FNe(w))
    "lt" -> Ok(FLt(w))
    "gt" -> Ok(FGt(w))
    "le" -> Ok(FLe(w))
    "ge" -> Ok(FGe(w))
    _ -> Error(Nil)
  }
}

/// Parses a conversion op spelling (mirror of `printer.convop_to_string`).
///
/// Fixed strings (the width/sign changes and the Phase-2 `demote.f64`/`promote.f32`) match
/// first; the parametric forms (`trunc_sat_*`, `reinterpret_*`, `box`/`unbox`, and the
/// Phase-2 trapping `trunc_s`/`trunc_u` + `convert_s`/`convert_u`) are resolved by splitting
/// on `.`. The trapping `trunc_s`/`trunc_u` heads are DISTINCT from the saturating
/// `trunc_sat_s`/`trunc_sat_u` (no prefix collision). Operand order matches the printer:
/// trunc is `<from-float>.<to-int>`, convert is `<from-int>.<to-float>`. `Error(Nil)` for an
/// unknown spelling (surfaced as `UnknownOp` by `parse_convert`).
fn string_to_convop(w: String) -> Result(ConvOp, Nil) {
  case w {
    "i32.wrap_i64" -> Ok(I32WrapI64)
    "i64.extend_i32_s" -> Ok(I64ExtendI32S)
    "i64.extend_i32_u" -> Ok(I64ExtendI32U)
    "i32.extend8_s" -> Ok(I32Extend8S)
    "i32.extend16_s" -> Ok(I32Extend16S)
    "i64.extend8_s" -> Ok(I64Extend8S)
    "i64.extend16_s" -> Ok(I64Extend16S)
    "i64.extend32_s" -> Ok(I64Extend32S)
    "demote.f64" -> Ok(F32DemoteF64)
    "promote.f32" -> Ok(F64PromoteF32)
    _ ->
      case string.split(w, ".") {
        ["trunc_sat_s", f, i] -> {
          use from <- result.try(ty_fwidth(f))
          use to <- result.try(ty_iwidth(i))
          Ok(TruncSatS(from, to))
        }
        ["trunc_sat_u", f, i] -> {
          use from <- result.try(ty_fwidth(f))
          use to <- result.try(ty_iwidth(i))
          Ok(TruncSatU(from, to))
        }
        ["trunc_s", f, i] -> {
          use from <- result.try(ty_fwidth(f))
          use to <- result.try(ty_iwidth(i))
          Ok(TruncS(from, to))
        }
        ["trunc_u", f, i] -> {
          use from <- result.try(ty_fwidth(f))
          use to <- result.try(ty_iwidth(i))
          Ok(TruncU(from, to))
        }
        ["convert_s", i, f] -> {
          use from <- result.try(ty_iwidth(i))
          use to <- result.try(ty_fwidth(f))
          Ok(ConvertS(from, to))
        }
        ["convert_u", i, f] -> {
          use from <- result.try(ty_iwidth(i))
          use to <- result.try(ty_fwidth(f))
          Ok(ConvertU(from, to))
        }
        ["reinterpret_f2i", f] -> {
          use from <- result.try(ty_fwidth(f))
          Ok(ReinterpretFToI(from))
        }
        ["reinterpret_i2f", i] -> {
          use to <- result.try(ty_iwidth(i))
          Ok(ReinterpretIToF(to))
        }
        ["box", ty] -> box_op(ty, BoxInt, BoxFloat)
        ["unbox", ty] -> box_op(ty, UnboxInt, UnboxFloat)
        _ -> Error(Nil)
      }
  }
}

/// Resolves a `box`/`unbox` type token to the int- or float-flavoured constructor.
fn box_op(
  ty: String,
  int_ctor: fn(IntWidth) -> ConvOp,
  float_ctor: fn(FloatWidth) -> ConvOp,
) -> Result(ConvOp, Nil) {
  case ty {
    "i32" -> Ok(int_ctor(W32))
    "i64" -> Ok(int_ctor(W64))
    "f32" -> Ok(float_ctor(FW32))
    "f64" -> Ok(float_ctor(FW64))
    _ -> Error(Nil)
  }
}

fn ty_iwidth(s: String) -> Result(IntWidth, Nil) {
  case s {
    "i32" -> Ok(W32)
    "i64" -> Ok(W64)
    _ -> Error(Nil)
  }
}

fn ty_fwidth(s: String) -> Result(FloatWidth, Nil) {
  case s {
    "f32" -> Ok(FW32)
    "f64" -> Ok(FW64)
    _ -> Error(Nil)
  }
}

/// Parses a term-layer op spelling (`make_tuple`, `make_cons`, `tuple_get.<index>`).
fn string_to_termop(w: String) -> Result(TermOp, Nil) {
  case w {
    "make_tuple" -> Ok(MakeTuple)
    "make_cons" -> Ok(MakeCons)
    _ ->
      case string.split(w, ".") {
        ["tuple_get", idx] ->
          case int.parse(idx) {
            Ok(i) -> Ok(TupleGet(i))
            Error(_) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
  }
}

/// Parses a trap-reason spelling (snake_case of the constructor).
fn string_to_trapreason(w: String) -> Result(TrapReason, Nil) {
  case w {
    "int_div_by_zero" -> Ok(IntDivByZero)
    "int_overflow" -> Ok(IntOverflow)
    "unreachable" -> Ok(Unreachable)
    "indirect_call_type_mismatch" -> Ok(IndirectCallTypeMismatch)
    "memory_out_of_bounds" -> Ok(MemoryOutOfBounds)
    "invalid_conversion_to_integer" -> Ok(InvalidConversionToInteger)
    "undefined_element" -> Ok(UndefinedElement)
    "uninitialized_element" -> Ok(UninitializedElement)
    "table_out_of_bounds" -> Ok(TableOutOfBounds)
    "fuel_exhausted" -> Ok(FuelExhausted)
    _ -> Error(Nil)
  }
}
