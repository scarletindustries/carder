//// Tests for the Core Erlang pretty-printer (Unit 03).
////
//// These assert the produced TEXT against the Core Erlang grammar and OTP's
//// AUTHORITATIVE reference behaviour — never against "whatever the printer
//// happens to emit" (no change-detector tests, D8). Concretely:
////
////  - Atom escaping is checked against OTP's own `io_lib:write_string(_, $')`
////    (the exact routine `core_pp.erl` uses) via an FFI oracle, so the printer
////    is proven byte-identical to the reference over a wide codepoint range.
////  - Variable legalization is checked against the Core Erlang lexical rules
////    (leading char `A`–`Z`/`_`, the legal charset) and the injectivity contract
////    the printer guarantees — a property test, not a fixed-output check.
////  - The mandatory-guard, value-list-pattern, value-list-`let`-arity, and
////    `FName` rules are checked as grammar invariants (the required token is
////    PRESENT), citing facts 5–7 of the unit doc.
////  - End-to-end: hand-built ASTs are printed and fed through the real OTP-29
////    compiler (`build_beam`, Unit 04), loaded, and `apply`-ed — the integers /
////    atoms returned are asserted by ordinary arithmetic / the documented guard
////    arms, proving the printer's output is compiler-accepted (D8/D10).
////
//// Canonical references: the Core Erlang language specification and OTP's
//// `compiler` app (`core_scan`/`core_parse`/`core_lint`, `core_pp.erl`,
//// `io_lib:write_string/2`).

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/string
import gleam/string_tree
import twocore/backend/build_beam
import twocore/backend/core_erlang.{
  CApply, CAtom, CCall, CCase, CClause, CFun, CInt, CLet, CModule, CValues, CVar,
  FName, FunDef, PInt, PVar,
}
import twocore/backend/core_printer

// ───────────────────────── reference oracles (FFI) ─────────────────────────
//
// The authoritative escaping is OTP's `io_lib:write_string(Chars, $')`. We
// compose three stock OTP functions (no extra `.erl` needed) into an oracle and
// assert the printer matches it byte-for-byte. This is "assert against the
// standard", not against our own code.

/// `unicode:characters_to_list/1` — a UTF-8 `String` to its codepoint list.
@external(erlang, "unicode", "characters_to_list")
fn to_charlist(s: String) -> List(Int)

/// `io_lib:write_string(Chars, Quote)` — escapes a codepoint list and wraps it
/// in `Quote`. Returns a deep char list, kept opaque as `Dynamic`.
@external(erlang, "io_lib", "write_string")
fn io_lib_write_string(chars: List(Int), quote: Int) -> Dynamic

/// `unicode:characters_to_binary/1` — flattens a deep char list to a UTF-8
/// binary (a Gleam `String`).
@external(erlang, "unicode", "characters_to_binary")
fn chars_to_binary(d: Dynamic) -> String

/// The reference quoting of an atom: exactly OTP's `io_lib:write_string(_, $')`
/// (`$'` is codepoint 39). This is the behaviour `print_atom` must match.
fn oracle_quote(s: String) -> String {
  chars_to_binary(io_lib_write_string(to_charlist(s), 39))
}

/// `erlang:apply/3` for exports returning an integer.
@external(erlang, "erlang", "apply")
fn apply_int(module: Atom, function: Atom, args: List(Int)) -> Int

/// `erlang:apply/3` for exports returning an atom.
@external(erlang, "erlang", "apply")
fn apply_atom(module: Atom, function: Atom, args: List(Int)) -> Atom

// ──────────────────────────── small test helpers ────────────────────────────

/// Render `print_atom` to a plain `String` for assertions.
fn print_atom_str(s: String) -> String {
  string_tree.to_string(core_printer.print_atom(s))
}

/// The inclusive ascending integer list `[from, …, to]` (stdlib 1.0.3 has no
/// `list.range`). Tail-recursive.
fn seq(from: Int, to: Int) -> List(Int) {
  seq_loop(to, from, [])
}

fn seq_loop(current: Int, from: Int, acc: List(Int)) -> List(Int) {
  case current < from {
    True -> acc
    False -> seq_loop(current - 1, from, [current, ..acc])
  }
}

/// The single-grapheme string for codepoint `i`, or `Error` for invalid
/// codepoints (e.g. UTF-16 surrogates), which are simply skipped by callers.
fn codepoint_string(i: Int) -> Result(String, Nil) {
  case string.utf_codepoint(i) {
    Ok(cp) -> Ok(string.from_utf_codepoints([cp]))
    Error(_) -> Error(Nil)
  }
}

// ═══════════════════════ 1. atoms are ALWAYS quoted ═══════════════════════

/// Fact 1: there is no unquoted-atom form. Every atom — including reserved
/// keywords like `true`/`module`, operators like `+`, and ordinary words — must
/// be single-quoted. (Asserting the quotes are present, per the grammar.)
pub fn atoms_always_quoted_test() {
  assert print_atom_str("true") == "'true'"
  assert print_atom_str("false") == "'false'"
  // `module` is a Core Erlang keyword, still quoted as an atom.
  assert print_atom_str("module") == "'module'"
  assert print_atom_str("of") == "'of'"
  assert print_atom_str("ok") == "'ok'"
  assert print_atom_str("+") == "'+'"
  assert print_atom_str("erlang") == "'erlang'"
  // Even the empty atom is quoted.
  assert print_atom_str("") == "''"
}

// ═══════════════════════ 2. atom escaping (fact 4) ═══════════════════════

/// Fact 4: escaping follows `io_lib:write_string(_, $')`. The specific cases the
/// unit doc enumerates: `'`→`\'`, `\`→`\\`, tab/nl/cr→`\t`/`\n`/`\r`, NUL→octal
/// `\000`, printable Unicode passes through. The expected strings here are the
/// values that rule produces (independently confirmed against OTP).
pub fn atom_escaping_specific_cases_test() {
  // ' -> \'
  assert print_atom_str("'") == "'\\''"
  // \ -> \\
  assert print_atom_str("\\") == "'\\\\'"
  // TAB / LF / CR -> \t \n \r
  assert print_atom_str("\t") == "'\\t'"
  assert print_atom_str("\n") == "'\\n'"
  assert print_atom_str("\r") == "'\\r'"
  // NUL -> octal \000
  assert print_atom_str("\u{0}") == "'\\000'"
  // a printable Unicode char passes through unchanged
  assert print_atom_str("λ") == "'λ'"
  // a higher control byte (0x01) -> octal \001
  assert print_atom_str("\u{1}") == "'\\001'"
  // mixed content keeps printable bytes and escapes the control byte
  assert print_atom_str("a\u{0}b") == "'a\\000b'"
}

/// The strongest escaping check: the printer must be BYTE-IDENTICAL to OTP's
/// `io_lib:write_string(_, $')` across a broad codepoint range — ASCII, the
/// named control escapes (`\b \t \n \v \f \r \e \d`), the octal control ranges
/// (0–31, 127–159), and the pass-through ranges (32–126, ≥160 incl. 2-byte
/// UTF-8). Asserts against the authoritative reference, not against itself.
pub fn print_atom_matches_io_lib_oracle_test() {
  seq(0, 767)
  |> list.each(fn(i) {
    case codepoint_string(i) {
      Ok(s) -> {
        assert print_atom_str(s) == oracle_quote(s)
        Nil
      }
      Error(_) -> Nil
    }
  })
}

/// The oracle must also agree on multi-codepoint, adversarial atom names
/// (operators, keywords, embedded quotes/backslashes/controls, Unicode).
pub fn print_atom_matches_oracle_on_words_test() {
  [
    "ok", "erlang", "module", "let", "+", "-", "=<", "twocore@runtime@rt_num",
    "a'b", "x\\y", "tab\there", "λ-fn", "nul\u{0}byte", "ctrl\u{1}\u{1f}end",
    "del\u{7f}x", "esc\u{1b}", "hi\u{80}lo", "ff\u{c}vt\u{b}bs\u{8}",
  ]
  |> list.each(fn(s) {
    assert print_atom_str(s) == oracle_quote(s)
    Nil
  })
}

// ═══════════════════ 3. variable legalization (fact 3) ═══════════════════

/// The spec's worked example: `%` is byte `0x25`, so `legalize_var("%p0")` is
/// `"V_25p0"`.
pub fn legalize_var_spec_example_test() {
  assert core_printer.legalize_var("%p0") == "V_25p0"
}

/// Contract (a)+(b): every legalized token starts with `A`–`Z` or `_` (fact 3)
/// and contains only legal Core variable characters `[A-Za-z0-9_]`.
pub fn legalize_var_is_lexically_legal_test() {
  [
    "%p0", "$loop0", "x", "", "a b", "λ", "_under", "...", "9start",
    "MixedCase_1", "tab\there", "\u{0}\u{1f}",
  ]
  |> list.each(fn(name) {
    let out = core_printer.legalize_var(name)
    let assert Ok(first) = string.first(out)
    // (a) leading char is uppercase A–Z or underscore.
    assert is_var_start(first)
    // (b) every char is a legal Core variable character.
    assert list.all(string.to_graphemes(out), is_legal_var_char)
    Nil
  })
}

/// Contract (c): `legalize_var` is INJECTIVE, so upstream per-scope uniqueness
/// survives legalization. Sampled over every valid codepoint 0–300 as a
/// single-char name (all distinct inputs) plus adversarial multi-char names that
/// a naive scheme could collapse (`"%p0"` vs `"_25p0"`, `"ab"` vs `"a_b"`):
/// distinct inputs ⟹ distinct outputs.
pub fn legalize_var_injective_test() {
  let single =
    seq(0, 300)
    |> list.filter_map(codepoint_string)
  let adversarial = ["%p0", "_25p0", "ab", "a_b", "_5fab", "Va", "AB"]
  let inputs = list.append(single, adversarial)

  let outs = list.map(inputs, core_printer.legalize_var)
  // Inputs are pairwise distinct…
  assert list.length(list.unique(inputs)) == list.length(inputs)
  // …and injectivity means the outputs are too.
  assert list.length(list.unique(outs)) == list.length(outs)
}

/// True iff `c` (a single grapheme) is a legal Core variable START character:
/// uppercase `A`–`Z` or `_`.
fn is_var_start(c: String) -> Bool {
  string.contains("_ABCDEFGHIJKLMNOPQRSTUVWXYZ", c)
}

/// True iff `c` (a single grapheme) is a legal Core variable character.
fn is_legal_var_char(c: String) -> Bool {
  string.contains(
    "_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
    c,
  )
}

// ═══════════════════════ 4. FName form (fact 5) ═══════════════════════

/// Fact 5: a function name prints `'atom'/arity` in all three positions — the
/// export list, a def's LHS, and an `apply` operand.
pub fn fname_form_test() {
  let m =
    CModule(
      name: "twocore@fname",
      exports: [FName("fact", 1)],
      attributes: [],
      defs: [
        FunDef(
          FName("fact", 1),
          CFun(["n"], CApply(FName("fact", 1), [CVar("n")])),
        ),
      ],
    )
  let text = core_printer.print_module(m)
  // export list
  assert string.contains(text, "['fact'/1]")
  // def LHS
  assert string.contains(text, "'fact'/1 =")
  // apply operand
  assert string.contains(text, "apply 'fact'/1(")
}

/// Inter-module / BIF calls print `call 'Mod':'Fun'(Args)` with both names
/// quoted (fact 5).
pub fn call_form_test() {
  let m =
    CModule("twocore@call", [FName("f", 2)], [], [
      FunDef(
        FName("f", 2),
        CFun(
          ["a", "b"],
          CCall(CAtom("erlang"), CAtom("+"), [CVar("a"), CVar("b")]),
        ),
      ),
    ])
  let text = core_printer.print_module(m)
  assert string.contains(text, "call 'erlang':'+'(")
}

// ═══════════════ 5. mandatory guard + value-list pattern (fact 6) ═══════════════

/// Fact 6: every `case` clause has a MANDATORY guard (`when 'true'` for an
/// unconditional arm), and a single-value scrutinee uses a 1-element value-list
/// pattern `<P>`. A guard may also be a call expression.
pub fn mandatory_guard_and_value_list_pattern_test() {
  let clause_call =
    CClause(
      [PVar("x")],
      CCall(CAtom("erlang"), CAtom("<"), [CVar("x"), CInt(10)]),
      CAtom("small"),
    )
  let clause_true = CClause([PInt(0)], CAtom("true"), CAtom("zero"))
  let m =
    CModule("twocore@guard", [FName("f", 1)], [], [
      FunDef(
        FName("f", 1),
        CFun(["n"], CCase(CVar("n"), [clause_call, clause_true])),
      ),
    ])
  let text = core_printer.print_module(m)
  // An unconditional arm emits `when 'true'`.
  assert string.contains(text, "when 'true' ->")
  // The single pattern is wrapped in a value list `<…>`.
  assert string.contains(text, "<0> when 'true'")
  // A guard expression is emitted verbatim after `when`.
  assert string.contains(text, "when call 'erlang':'<'(")
}

// ═══════════════════ 6. `let` value-list arity (fact 7) ═══════════════════

/// Fact 7: a single binder prints `let X = …` (bare var); any other arity prints
/// `let <V…> = …` (value list), so the binder arity matches the RHS.
pub fn let_value_list_arity_test() {
  // 1 binder → bare variable.
  let one = CLet(["x"], CInt(1), CVar("x"))
  let t1 =
    core_printer.print_module(
      CModule("twocore@let1", [FName("f", 0)], [], [
        FunDef(FName("f", 0), CFun([], one)),
      ]),
    )
  assert string.contains(t1, "let Vx = 1")
  // …and is NOT wrapped in an angle-bracket value list.
  assert !string.contains(t1, "let <")

  // 2 binders → angle-bracketed value list.
  let two = CLet(["x", "y"], CValues([CInt(1), CInt(2)]), CVar("x"))
  let t2 =
    core_printer.print_module(
      CModule("twocore@let2", [FName("f", 0)], [], [
        FunDef(FName("f", 0), CFun([], two)),
      ]),
    )
  assert string.contains(t2, "let <Vx,Vy> = <1, 2>")
}

// ═══════ 7. end-to-end: printed AST compiles, loads, and runs (D8/D10) ═══════

/// Build the minimal `add/2` module (fact 8) as an AST, print it, and run it
/// through the REAL OTP-29 compiler (Unit 04). `add(2,3)` is `5` and `add(-4,4)`
/// is `0` by integer arithmetic — proving the printer emits compiler-accepted,
/// runnable text (also exercises negative integer literals).
pub fn integration_add_compiles_loads_runs_test() {
  let m =
    CModule("twocore@test@printer_add", [FName("add", 2)], [], [
      FunDef(
        FName("add", 2),
        CFun(
          ["a", "b"],
          CCall(CAtom("erlang"), CAtom("+"), [CVar("a"), CVar("b")]),
        ),
      ),
    ])
  let assert Ok(mod) = build_beam.compile_and_load(m)
  assert atom.to_string(mod) == "twocore@test@printer_add"
  let add = atom.create("add")
  assert apply_int(mod, add, [2, 3]) == 5
  assert apply_int(mod, add, [-4, 4]) == 0
}

/// A self-recursive `fac/1` (a `case` with a mandatory true guard, nested `let`s,
/// and an intra-module `apply`) must compile, load, and compute factorials —
/// proving `apply 'fac'/1(…)`, `let`, and guarded `case` all print correctly.
/// `fac(0)=1`, `fac(5)=120`, `fac(6)=720` by definition of factorial.
pub fn integration_factorial_recursion_test() {
  let body =
    CCase(CVar("n"), [
      CClause(
        [PVar("x")],
        CCall(CAtom("erlang"), CAtom("=<"), [CVar("x"), CInt(0)]),
        CInt(1),
      ),
      CClause(
        [PVar("x")],
        CAtom("true"),
        CLet(
          ["m"],
          CCall(CAtom("erlang"), CAtom("-"), [CVar("x"), CInt(1)]),
          CLet(
            ["r"],
            CApply(FName("fac", 1), [CVar("m")]),
            CCall(CAtom("erlang"), CAtom("*"), [CVar("x"), CVar("r")]),
          ),
        ),
      ),
    ])
  let m =
    CModule("twocore@test@printer_fac", [FName("fac", 1)], [], [
      FunDef(FName("fac", 1), CFun(["n"], body)),
    ])
  let assert Ok(mod) = build_beam.compile_and_load(m)
  let fac = atom.create("fac")
  assert apply_int(mod, fac, [0]) == 1
  assert apply_int(mod, fac, [5]) == 120
  assert apply_int(mod, fac, [6]) == 720
}

/// A `classify/1` with two guarded arms plus an unconditional catch-all,
/// returning atoms, must compile/load/run and land each input in the documented
/// arm — proving multi-clause `case`, real BIF guards, the mandatory `when
/// 'true'` catch-all, and atom-literal results all print correctly.
pub fn integration_classify_guards_test() {
  let body =
    CCase(CVar("n"), [
      CClause(
        [PVar("x")],
        CCall(CAtom("erlang"), CAtom("=<"), [CVar("x"), CInt(0)]),
        CAtom("zero_or_neg"),
      ),
      CClause(
        [PVar("x")],
        CCall(CAtom("erlang"), CAtom("<"), [CVar("x"), CInt(10)]),
        CAtom("small"),
      ),
      CClause([PVar("y")], CAtom("true"), CAtom("big")),
    ])
  let m =
    CModule("twocore@test@printer_classify", [FName("classify", 1)], [], [
      FunDef(FName("classify", 1), CFun(["n"], body)),
    ])
  let assert Ok(mod) = build_beam.compile_and_load(m)
  let c = atom.create("classify")
  assert apply_atom(mod, c, [-3]) == atom.create("zero_or_neg")
  assert apply_atom(mod, c, [0]) == atom.create("zero_or_neg")
  assert apply_atom(mod, c, [5]) == atom.create("small")
  assert apply_atom(mod, c, [9]) == atom.create("small")
  assert apply_atom(mod, c, [50]) == atom.create("big")
}
