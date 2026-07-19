//// The Core Erlang pretty-printer (Unit 03) — now an INSPECTION-ONLY surface.
////
//// Turns a `twocore/backend/core_erlang` AST into `.core` source text for the
//// CLI's `to-core`/`emit` dumps and the text-shape tests. The COMPILE path no
//// longer goes through this text: `twocore/backend/eaf` lowers the same AST to
//// Erlang Abstract Format terms and `build_beam` compiles them in-process with
//// `compile:forms/2`. The printed text is never re-parsed (the historical
//// `core_scan` → `core_parse` → `from_core` round trip is gone); the lexical
//// rules below are kept verbatim so the dump remains faithful `.core`.
////
//// The printer is small and has no algorithmic cleverness — it is a recursive
//// walk emitting a `gleam/string_tree`. Its hard part is purely *lexical*, and
//// every lexical rule below is pinned to a VERIFIED OTP-29 fact (see the unit
//// doc `specs/phase-1/03-core-erlang-backend.md`):
////
////  - **Atoms are ALWAYS single-quoted and escaped.** There is no unquoted-atom
////    form; a bare lowercase word scans as a keyword. `print_atom` quotes and
////    escapes every atom EXACTLY as OTP's `io_lib:write_string(Chars, $')` does
////    (which is what OTP's own `core_pp.erl` uses), so the compiler reads back
////    precisely what it would have written.
////  - **Variables must start with `A`–`Z` or `_` and be unique per scope.**
////    Upstream (IR/WASM) names violate this, so `legalize_var` maps every raw
////    name to a legal, injective token.
////  - **Every `case` clause has a mandatory guard** (`when 'true'` for an
////    unconditional arm) and uses a value-list pattern `<P…>`.
////  - **`let` value-list arity**: one binder prints `let X = …`, otherwise
////    `let <V…> = …`.
////
//// All functions here are TOTAL and never panic: the printer handles every
//// `CExpr`/`CPat` constructor and the legalization/escaping helpers have total
//// fallbacks on the (unreachable) invalid-codepoint branches.

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import gleam/string
import gleam/string_tree.{type StringTree}
import twocore/backend/core_erlang.{
  type CBitSeg, type CClause, type CExpr, type CModule, type CPat, type FName,
  type FunDef, CApply, CApplyExpr, CAtom, CBinary, CCall, CCase, CCons, CFloat,
  CFun, CInt, CLet, CLetrec, CNil, CPrimop, CTry, CTuple, CValues, CVar, PAtom,
  PCons, PInt, PNil, PTuple, PVar,
}

/// One indentation step. Whitespace is insignificant to the Core Erlang scanner,
/// so this only affects readability of the emitted text, never its validity.
const indent_unit = "    "

/// Maximum accumulated indentation, in bytes. Indentation is for HUMAN readability
/// only (the scanner ignores it), but a large guest lowers to functions nested
/// HUNDREDS of `let`/`letrec` deep — so unbounded per-level indentation makes the
/// emitted `.core` almost entirely leading spaces (a ~277 KB guest → ~85 MB, ~94%
/// whitespace), ballooning emit memory + time. We cap the depth: shallow code (the
/// common case, and every printer test) indents normally; pathologically deep
/// nesting stops accumulating here. The compile path also strips leading
/// indentation before scanning (`twocore_codegen_ffi`), so this is belt-and-braces
/// for the emit side.
const max_indent = 48

/// `ind` deepened by one `indent_unit`, capped at `max_indent` bytes so deeply
/// nested constructs stop growing the per-line indentation.
fn deepen(ind: String) -> String {
  case string.byte_size(ind) >= max_indent {
    True -> ind
    False -> ind <> indent_unit
  }
}

// ───────────────────────────── small helpers ─────────────────────────────

/// Shorthand: a `StringTree` from a literal string.
fn st(s: String) -> StringTree {
  string_tree.from_string(s)
}

// ───────────────────────────── module printer ─────────────────────────────

/// Render a whole Core Erlang module to `.core` text.
///
/// `m`: the module AST. Returns the complete module source as a `String`:
/// ```text
/// module 'Name' [Exports]
///     attributes [Attrs]
/// Def…
/// end
/// ```
/// Total; never panics. The result is accepted by `compile:from_core` whenever
/// the AST is well-formed (e.g. `FName` arities match their `CFun`s and `case`
/// clause arities match their scrutinees — invariants `emit_core` upholds; the
/// printer does not validate them, it faithfully prints what it is given).
pub fn print_module(m: CModule) -> String {
  let defs = list.map(m.defs, print_def) |> string_tree.join("\n")
  string_tree.concat([
    st("module "),
    print_atom(m.name),
    st(" "),
    print_export_list(m.exports),
    st("\n" <> indent_unit <> "attributes "),
    print_attributes(m.attributes),
    st("\n"),
    defs,
    st("\nend\n"),
  ])
  |> string_tree.to_string
}

/// Print the export list `['a'/0, 'b'/2, …]`.
fn print_export_list(exports: List(FName)) -> StringTree {
  string_tree.concat([
    st("["),
    list.map(exports, print_fname) |> string_tree.join(", "),
    st("]"),
  ])
}

/// Print the module attribute list `['k' = V, …]` (Phase 1: always `[]`).
fn print_attributes(attrs: List(#(String, CExpr))) -> StringTree {
  let pairs =
    list.map(attrs, fn(kv) {
      let #(k, v) = kv
      string_tree.concat([print_atom(k), st(" = "), print_expr(v, indent_unit)])
    })
  string_tree.concat([st("["), string_tree.join(pairs, ", "), st("]")])
}

/// Print a function name as `'atom'/arity` (e.g. `'fact'/1`). Used in the export
/// list, on a def's LHS, and as the operand of `apply`.
fn print_fname(f: FName) -> StringTree {
  string_tree.concat([print_atom(f.name), st("/"), st(int.to_string(f.arity))])
}

/// Print a top-level function definition `'name'/arity = fun (…) -> body`.
fn print_def(def: FunDef) -> StringTree {
  print_def_at(def, "")
}

/// Print a definition whose LHS line begins at indentation `ind` (used both for
/// top-level defs, `ind = ""`, and for `letrec` defs at a nested indent).
fn print_def_at(def: FunDef, ind: String) -> StringTree {
  let inner = deepen(ind)
  string_tree.concat([
    st(ind),
    print_fname(def.name),
    st(" =\n"),
    st(inner),
    print_expr(def.value, inner),
  ])
}

// ─────────────────────────── expression printer ───────────────────────────

/// Print an expression. `ind` is the indentation prefix for any *continuation*
/// lines this expression emits; nested constructs use `deepen(ind)` (capped).
/// Inline literals/calls ignore `ind`. Total; handles every `CExpr` constructor.
fn print_expr(e: CExpr, ind: String) -> StringTree {
  case e {
    CVar(name) -> st(legalize_var(name))
    CInt(value) -> st(int.to_string(value))
    CFloat(value) -> st(float.to_string(value))
    CAtom(name) -> print_atom(name)
    CNil -> st("[]")
    CCons(head, tail) ->
      string_tree.concat([
        st("["),
        print_expr(head, ind),
        st("|"),
        print_expr(tail, ind),
        st("]"),
      ])
    CTuple(elements) ->
      string_tree.concat([
        st("{"),
        list.map(elements, print_expr(_, ind)) |> string_tree.join(", "),
        st("}"),
      ])
    CValues(values) ->
      string_tree.concat([
        st("<"),
        list.map(values, print_expr(_, ind)) |> string_tree.join(", "),
        st(">"),
      ])
    CBinary(segments) ->
      string_tree.concat([
        st("#{"),
        list.map(segments, print_bitseg(_, ind)) |> string_tree.join(", "),
        st("}#"),
      ])
    CFun(vars, body) -> print_fun(vars, body, ind)
    CLet(vars, arg, body) -> print_let(vars, arg, body, ind)
    CLetrec(defs, body) -> print_letrec(defs, body, ind)
    CCase(arg, clauses) -> print_case(arg, clauses, ind)
    CApply(name, args) ->
      string_tree.concat([
        st("apply "),
        print_fname(name),
        st("("),
        list.map(args, print_expr(_, ind)) |> string_tree.join(", "),
        st(")"),
      ])
    // `apply Op(Args)` applied to a fun VALUE (Phase-8 `CallClosure`). `Op` is an arbitrary
    // expression (a `CVar` bound to a `fun`, or an inline `fun`) rather than a static `'f'/N`.
    CApplyExpr(op, args) ->
      string_tree.concat([
        st("apply "),
        print_expr(op, ind),
        st("("),
        list.map(args, print_expr(_, ind)) |> string_tree.join(", "),
        st(")"),
      ])
    CCall(module, function, args) ->
      string_tree.concat([
        st("call "),
        print_expr(module, ind),
        st(":"),
        print_expr(function, ind),
        st("("),
        list.map(args, print_expr(_, ind)) |> string_tree.join(", "),
        st(")"),
      ])
    CPrimop(name, args) ->
      string_tree.concat([
        st("primop "),
        print_atom(name),
        st("("),
        list.map(args, print_expr(_, ind)) |> string_tree.join(", "),
        st(")"),
      ])
    CTry(arg, body_vars, body, evars, handler) ->
      print_try(arg, body_vars, body, evars, handler, ind)
  }
}

/// Print a Core Erlang `try … of … catch …` (T5). The OTP-29-accepted form has NO outer
/// parentheses and NO `end` (verified against `core_scan`/`core_parse`):
/// ```text
/// try
///     <Arg>
/// of <V1,…> ->
///     <Body>
/// catch <Ec,Er,Es> ->
///     <Handler>
/// ```
/// The `of`/`catch` variable lists are ALWAYS value-list-wrapped `<…>` (matching the
/// `arg`/raise arity, exactly like a `case` clause pattern). `ind` is the `try` keyword's
/// own indentation; `arg`/`body`/`handler` continue at `deepen(ind)` (capped).
fn print_try(
  arg: CExpr,
  body_vars: List(String),
  body: CExpr,
  evars: List(String),
  handler: CExpr,
  ind: String,
) -> StringTree {
  let inner = deepen(ind)
  string_tree.concat([
    st("try\n"),
    st(inner),
    print_expr(arg, inner),
    st("\n" <> ind <> "of "),
    print_var_list(body_vars),
    st(" ->\n"),
    st(inner),
    print_expr(body, inner),
    st("\n" <> ind <> "catch "),
    print_var_list(evars),
    st(" ->\n"),
    st(inner),
    print_expr(handler, inner),
  ])
}

/// Print a Core value-list of variable binders `<V1,V2,…>` (legalized), used for a `try`'s
/// `of`/`catch` variable lists. A single binder is still wrapped `<V>` (the `try` grammar
/// requires the value-list brackets, like a `case` clause pattern).
fn print_var_list(vars: List(String)) -> StringTree {
  string_tree.concat([
    st("<"),
    list.map(vars, fn(v) { st(legalize_var(v)) }) |> string_tree.join(", "),
    st(">"),
  ])
}

/// Print `fun (V1, V2) -> Body`, with the body on its own indented line.
fn print_fun(vars: List(String), body: CExpr, ind: String) -> StringTree {
  let inner = deepen(ind)
  string_tree.concat([
    st("fun ("),
    list.map(vars, fn(v) { st(legalize_var(v)) }) |> string_tree.join(", "),
    st(") ->\n"),
    st(inner),
    print_expr(body, inner),
  ])
}

/// Print a `let`. Per fact 7, one binder uses the bare form `let X = Arg in …`
/// and any other arity (0 or ≥ 2) uses the value-list form `let <V…> = Arg in …`
/// so the binder arity matches what `Arg` produces.
fn print_let(
  vars: List(String),
  arg: CExpr,
  body: CExpr,
  ind: String,
) -> StringTree {
  let inner = deepen(ind)
  let binder = case vars {
    [single] -> st(legalize_var(single))
    _ ->
      string_tree.concat([
        st("<"),
        list.map(vars, fn(v) { st(legalize_var(v)) }) |> string_tree.join(","),
        st(">"),
      ])
  }
  string_tree.concat([
    st("let "),
    binder,
    st(" = "),
    print_expr(arg, ind),
    st(" in\n"),
    st(inner),
    print_expr(body, inner),
  ])
}

/// Print `letrec Defs… in Body`.
fn print_letrec(defs: List(FunDef), body: CExpr, ind: String) -> StringTree {
  let inner = deepen(ind)
  let defs_tree =
    list.map(defs, fn(d) { print_def_at(d, inner) }) |> string_tree.join("\n")
  string_tree.concat([
    st("letrec\n"),
    defs_tree,
    st("\n" <> ind <> "in\n" <> inner),
    print_expr(body, inner),
  ])
}

/// Print `case Arg of Clauses… end`, with `end` aligned to the `case`.
fn print_case(arg: CExpr, clauses: List(CClause), ind: String) -> StringTree {
  let inner = deepen(ind)
  let cls =
    list.map(clauses, fn(c) { print_clause(c, inner) })
    |> string_tree.join("\n")
  string_tree.concat([
    st("case "),
    print_expr(arg, ind),
    st(" of\n"),
    cls,
    st("\n" <> ind <> "end"),
  ])
}

/// Print one `case` clause `<P1,P2,…> when Guard -> Body`.
///
/// The pattern list is ALWAYS wrapped in a value-list `<…>` (even a single
/// pattern) so it matches the scrutinee's value-list shape, and the guard is
/// ALWAYS printed (`CAtom("true")` ⇒ `when 'true'`) — both are mandatory in Core
/// Erlang (fact 6). `ind` is the clause's own indentation.
fn print_clause(c: CClause, ind: String) -> StringTree {
  let inner = deepen(ind)
  string_tree.concat([
    st(ind),
    st("<"),
    list.map(c.pats, print_pat) |> string_tree.join(","),
    st("> when "),
    print_expr(c.guard, ind),
    st(" ->\n"),
    st(inner),
    print_expr(c.body, inner),
  ])
}

/// Print a pattern. Total; handles every `CPat` constructor.
fn print_pat(p: CPat) -> StringTree {
  case p {
    PVar(name) -> st(legalize_var(name))
    PInt(value) -> st(int.to_string(value))
    PAtom(name) -> print_atom(name)
    PNil -> st("[]")
    PCons(head, tail) ->
      string_tree.concat([
        st("["),
        print_pat(head),
        st("|"),
        print_pat(tail),
        st("]"),
      ])
    PTuple(elements) ->
      string_tree.concat([
        st("{"),
        list.map(elements, print_pat) |> string_tree.join(", "),
        st("}"),
      ])
  }
}

/// Print a binary segment `#<Value>(Size, Unit, 'Type', ['Flag', …])`. Minimal
/// (lock-now placeholder); the Phase-1 integer corpus does not exercise it.
fn print_bitseg(seg: CBitSeg, ind: String) -> StringTree {
  string_tree.concat([
    st("#<"),
    print_expr(seg.value, ind),
    st(">("),
    print_expr(seg.size, ind),
    st(","),
    st(int.to_string(seg.unit)),
    st(","),
    print_atom(seg.segtype),
    st(",["),
    list.map(seg.flags, print_atom) |> string_tree.join(","),
    st("])"),
  ])
}

// ─────────────────────────────── atom printer ───────────────────────────────

/// Quote and escape an atom EXACTLY as OTP's `io_lib:write_string(Chars, $')`
/// does, wrapping the result in single quotes. This is the same routine OTP's
/// reference printer (`core_pp.erl`) uses for every atom, so the produced text
/// round-trips through `core_scan` unchanged.
///
/// `name`: the atom's logical characters (any UTF-8 string, including keywords
/// like `"true"`, operators like `"+"`, or names with control bytes). There is
/// NO unquoted-atom path — the result is always wrapped in `'…'`.
///
/// Escaping (per codepoint, in OTP's clause order): `'` → `\'`; `\` → `\\`;
/// printable ASCII (32–126) and codepoints ≥ 160 pass through unchanged;
/// `\n \r \t \v \b \f \e \d` (LF CR TAB VT BS FF ESC DEL) use their named
/// escapes; any other control codepoint (< 160) becomes a 3-digit octal escape
/// `\NNN`. Returns a `StringTree`; total and panic-free.
pub fn print_atom(name: String) -> StringTree {
  let body =
    string.to_utf_codepoints(name)
    |> list.fold(string_tree.new(), fn(acc, cp) {
      string_tree.append_tree(
        acc,
        escape_atom_char(string.utf_codepoint_to_int(cp), cp),
      )
    })
  string_tree.concat([st("'"), body, st("'")])
}

/// Escape a single atom codepoint per `io_lib:write_string(_, $')`. `c` is the
/// integer codepoint and `cp` is the same codepoint as a `UtfCodepoint` (used to
/// re-emit pass-through characters verbatim). Clause order mirrors OTP's
/// `string_char/4` so behaviour is byte-identical.
fn escape_atom_char(c: Int, cp: UtfCodepoint) -> StringTree {
  case c {
    // Quote and backslash are checked first.
    39 -> st("\\'")
    92 -> st("\\\\")
    // Printable ASCII and high (≥ 160) codepoints pass through unchanged.
    _ if c >= 32 && c <= 126 -> st(string.from_utf_codepoints([cp]))
    _ if c >= 160 -> st(string.from_utf_codepoints([cp]))
    // Named control escapes.
    10 -> st("\\n")
    13 -> st("\\r")
    9 -> st("\\t")
    11 -> st("\\v")
    8 -> st("\\b")
    12 -> st("\\f")
    27 -> st("\\e")
    127 -> st("\\d")
    // Any other control codepoint (< 160) → 3-digit octal.
    _ -> octal_escape(c)
  }
}

/// Render a control codepoint `c` (0 ≤ c < 160) as a 3-digit octal escape
/// `\NNN`, matching OTP's `string_char/4` final clause. For `c < 160` the high
/// octal digit is always 0–2, so exactly three digits are produced.
fn octal_escape(c: Int) -> StringTree {
  let d1 = c / 64 % 8
  let d2 = c / 8 % 8
  let d3 = c % 8
  st("\\" <> oct_digit(d1) <> oct_digit(d2) <> oct_digit(d3))
}

/// Map an octal digit value 0–7 to its character. Total: any out-of-range input
/// (impossible here) maps to `"0"`.
fn oct_digit(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    _ -> "0"
  }
}

// ────────────────────────── variable legalization ──────────────────────────

/// Map a raw IR/WASM variable name to a Core-Erlang-legal variable token.
///
/// CONTRACT:
/// - **(a) leading char**: the result always starts with the uppercase letter
///   `V`, satisfying Core's "variable starts with `A`–`Z` or `_`" rule.
/// - **(b) charset**: the result contains only `[A-Za-z0-9_]`, all of which are
///   legal Core variable characters.
/// - **(c) injective**: distinct inputs give distinct outputs. The encoding
///   walks the input's UTF-8 *bytes* and maps each byte to a self-delimiting
///   token — an ASCII alphanumeric byte to itself, any other byte to `_` plus
///   two fixed-width lowercase hex digits — so the byte stream (and hence the
///   string) is recoverable. Because the map is injective, upstream
///   per-scope uniqueness of names is preserved in the printed tokens, *provided
///   the SAME function is applied to every binder AND every reference* (the
///   printer does this).
///
/// Example: `legalize_var("%p0") == "V_25p0"` (`%` is byte `0x25`).
///
/// `raw`: any string (UTF-8). Returns the legal token. Total; never panics.
pub fn legalize_var(raw: String) -> String {
  let body =
    string_to_bytes(raw)
    |> list.fold(string_tree.new(), fn(acc, b) {
      string_tree.append_tree(acc, legalize_byte(b))
    })
  string_tree.concat([st("V"), body]) |> string_tree.to_string
}

/// Encode one input byte for `legalize_var`: an ASCII alphanumeric byte renders
/// as itself; every other byte renders as `_` followed by two lowercase hex
/// digits. Total — the only way the codepoint render can fail is an invalid
/// codepoint, which alphanumeric bytes never are, so that branch falls through
/// to the (still-injective) escaped form.
fn legalize_byte(b: Int) -> StringTree {
  case is_alnum(b), string.utf_codepoint(b) {
    True, Ok(cp) -> st(string.from_utf_codepoints([cp]))
    _, _ -> st("_" <> hex_digit(b / 16) <> hex_digit(b % 16))
  }
}

/// True iff byte `b` is an ASCII digit, uppercase, or lowercase letter — the
/// characters `legalize_var` may pass through verbatim.
fn is_alnum(b: Int) -> Bool {
  { b >= 48 && b <= 57 } || { b >= 65 && b <= 90 } || { b >= 97 && b <= 122 }
}

/// Map a hex nibble value 0–15 to its lowercase character. Total: any
/// out-of-range input (impossible here) maps to `"0"`.
fn hex_digit(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    9 -> "9"
    10 -> "a"
    11 -> "b"
    12 -> "c"
    13 -> "d"
    14 -> "e"
    15 -> "f"
    _ -> "0"
  }
}

/// Decode a string to its UTF-8 byte values (0–255), in order. Total.
fn string_to_bytes(s: String) -> List(Int) {
  bytes_loop(bit_array.from_string(s), [])
}

/// Tail-recursive accumulator for `string_to_bytes`. Consumes one byte per step;
/// a non-byte-aligned tail (impossible for a `String`'s UTF-8 bytes) ends the
/// loop, yielding the bytes collected so far.
fn bytes_loop(ba: BitArray, acc: List(Int)) -> List(Int) {
  case ba {
    <<b:8, rest:bits>> -> bytes_loop(rest, [b, ..acc])
    _ -> list.reverse(acc)
  }
}
