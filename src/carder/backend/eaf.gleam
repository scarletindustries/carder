//// Erlang Abstract Format (EAF) backend — the Core-AST → abstract-forms
//// translator that replaced the textual `.core` print → `core_scan`/`core_parse`
//// re-parse round trip.
////
//// `emit_core` still produces the Gleam-native Core-shaped AST (`CModule`, the
//// binding chokepoint), but instead of printing it to `.core` TEXT and driving
//// the compiler-internal `core_scan`/`core_parse` modules plus the undocumented
//// textual `from_core` entry, this module lowers the AST directly to the
//// **documented** Erlang Abstract Format (`erts/absform`) as in-memory Erlang
//// terms, which `compile:forms/2` consumes natively (see
//// `carder_codegen_ffi:compile_forms/1`). From Gleam an EAF node is just a
//// plain tuple (`{integer, Anno, 42}`), so the forms are built with ordinary
//// tuple literals coerced into the opaque `Form` type — no cerl records, no
//// text, no re-parse.
////
//// The two Core-Erlang-isms Erlang source semantics does not have are lowered
//// here:
////
//// 1. **Scoping/shadowing.** Core Erlang binders shadow freely and `emit_core`
////    reuses raw names (`%p0`, `$loop0`) across sibling scopes, while Erlang
////    variables are function-scoped, single-assignment, and a bound variable in
////    a pattern means an equality CHECK, not a fresh binding. Every binder is
////    therefore alpha-renamed to a globally-fresh name
////    (`<legalized>@<counter>`, the Elixir-style counter-suffix scheme —
////    `@` is legal in an Erlang variable), so every EAF pattern variable is
////    provably unbound at its binding site and Core's shadowing semantics are
////    preserved exactly.
//// 2. **`letrec`.** Erlang has no expression-level `letrec`; a single-def
////    `letrec 'f'/n = fun … in Body` (the shape `emit_core` produces for loops,
////    join points, and try bodies) lowers to a **named fun**
////    `F = fun F(…) -> … end` — self-recursion via the fun's own name variable
////    (a proper tail call on the BEAM), outer references via the bound `F`
////    (both are the same fun value, so one name serves both). A multi-def
////    (mutually recursive) `letrec` — not currently emitted, but handled for
////    totality — lowers to ONE dispatching named fun
////    `R = fun R(Tag, Args) -> …` whose clauses match `(tag_i, [arg…])`, with
////    every intra-group apply rewritten to `R(tag_j, [args…])` (still a tail
////    call).
////
//// Value lists (`<…>` / multi-binder `let`) only ever appear as the RHS of a
//// same-arity multi-binder `let` (see `emit_core.value_list`), so they lower to
//// a sequence of matches; `primop 'build_stacktrace'` disappears entirely
//// because an Erlang `catch C:R:S` binds the ALREADY-BUILT stacktrace.
////
//// Annotations: the IR carries no source positions (WASM offsets are not
//// tracked), so annos are synthetic — every form in the n-th top-level function
//// is annotated with line `n+1`, which makes BEAM stacktrace lines identify the
//// generated function even without names.

import carder/backend/core_erlang.{
  type CBitSeg, type CClause, type CExpr, type CModule, type CPat, type FunDef,
  CApply, CApplyExpr, CAtom, CBinary, CBitSeg, CBytes, CCall, CCase, CClause,
  CCons, CFloat, CFun, CFunRef, CInt, CLet, CLetrec, CNil, CPrimop, CTry, CTuple,
  CValues, CVar, FName, FunDef, PAtom, PCons, PInt, PNil, PTuple, PVar,
}
import carder/backend/core_printer
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set.{type Set}

/// An opaque Erlang Abstract Format term — a form, expression, pattern, or
/// annotation node exactly as `compile:forms/2` / `erl_lint` consume it
/// (documented in `erts/absform`). Constructed only by this module (plain
/// tuples coerced via the identity FFI); never inspected from Gleam.
pub type Form

/// A Gleam-side atom handle used inside EAF nodes (node tags, atom literals,
/// variable names). Opaque here; created with `atom_of`.
type EAtom

/// Identity coercion: any Gleam value → an opaque `Form`. A Gleam tuple IS an
/// Erlang tuple and a Gleam `List` IS an Erlang list, so building an EAF node
/// is building the corresponding Gleam literal and forgetting its type.
@external(erlang, "carder_codegen_ffi", "id")
fn raw(term: a) -> Form

/// `erlang:binary_to_atom/2 (utf8)` — the atom for a node tag / atom literal /
/// variable name. Same total contract as `gleam/erlang/atom.create`, typed to
/// this module's private `EAtom` so raw atoms never leak.
@external(erlang, "erlang", "binary_to_atom")
fn atom_of(name: String) -> EAtom

/// `erlang:binary_to_list/1` — a whole-byte binary as its byte list (each
/// 0..255), the payload of a `{string, Anno, Bytes}` segment value.
@external(erlang, "erlang", "binary_to_list")
fn bytes_to_list(bytes: BitArray) -> List(Int)

/// Why the Core-shaped AST could not be lowered to abstract forms. Every
/// variant is an `emit_core` INVARIANT violation (the shapes `emit_core`
/// guarantees never to produce), surfaced as a typed error rather than a panic
/// so the pipeline stays total (D8 — fail closed, never crash).
pub type EafError {
  /// A top-level (or `letrec`) definition whose RHS is not a `CFun` literal —
  /// Core requires a `fun` on a def RHS, so this is unreachable from
  /// `emit_core`. `name` is the offending def's function name.
  NonFunDef(name: String)
  /// A `primop` other than `'build_stacktrace'` (the only one emitted).
  UnsupportedPrimop(name: String)
  /// A multi-binder `let` whose RHS is a literal value list of a different
  /// arity. `binders`/`values` are the mismatched arities.
  BadValueBinding(binders: Int, values: Int)
  /// A bare value list (`CValues`) in single-value expression position.
  BareValueList(arity: Int)
  /// A `case` clause with pattern arity ≠ 1 (multi-value scrutinees are never
  /// emitted).
  BadClauseArity(arity: Int)
  /// A `try` whose binder shape is not 1 body var + 3 exception vars (the only
  /// shape `emit_try` produces).
  BadTryShape(body_vars: Int, evars: Int)
  /// A module attribute whose value is not a literal term. `key` names it.
  UnsupportedAttribute(key: String)
  /// A `CFunRef` naming a `letrec` def lowered to the multi-def DISPATCH shape.
  /// That def is reachable only as `R(tag, [Args…])`, so no plain `'f'/N` fun
  /// value with the ref's arity exists to hand out. `emit_core` only funrefs
  /// top-level `jsf_K` functions, so this is unreachable — it is rejected
  /// rather than mis-lowered to a callable with the wrong ABI.
  DispatchFunRef(name: String, arity: Int)
}

/// A short human-readable rendering of an `EafError` for CLI/diagnostic text.
/// Total. Programmatic callers should match the variant, not parse this.
pub fn describe(error: EafError) -> String {
  case error {
    NonFunDef(name) -> "definition of '" <> name <> "' is not a fun literal"
    UnsupportedPrimop(name) -> "unsupported primop '" <> name <> "'"
    BadValueBinding(b, v) ->
      "let binds "
      <> int.to_string(b)
      <> " names to "
      <> int.to_string(v)
      <> " values"
    BareValueList(n) ->
      "value list of arity " <> int.to_string(n) <> " in single-value position"
    BadClauseArity(n) -> "case clause with pattern arity " <> int.to_string(n)
    BadTryShape(bv, ev) ->
      "try with "
      <> int.to_string(bv)
      <> " body vars / "
      <> int.to_string(ev)
      <> " exception vars"
    UnsupportedAttribute(key) ->
      "attribute '" <> key <> "' has a non-literal value"
    DispatchFunRef(name, arity) ->
      "fun reference to dispatch-lowered '"
      <> name
      <> "'/"
      <> int.to_string(arity)
  }
}

// ─────────────────────────────── translation state ───────────────────────────────

/// How an in-scope `letrec`-bound function is called at an `apply` site:
/// `DirectFun` — the common single-def lowering — calls the named-fun variable
/// directly (`F(Args…)`); `DispatchFun` — the multi-def lowering — calls the
/// shared dispatcher with the def's tag and a packed argument list
/// (`R(tag, [Args…])`).
type LocalFun {
  DirectFun(var: String)
  DispatchFun(var: String, tag: String)
}

/// The per-function translation environment: `ln` is the function's synthetic
/// anno line (constant for the whole body); `vars` maps a raw Core variable
/// name to its unique renamed Erlang variable; `funs` maps an in-scope
/// `letrec`-bound `'name'/arity` to its lowering. An `FName` absent from
/// `funs` is a top-level module function (a plain local call). `uses` counts
/// how many times each raw variable is READ anywhere in the function (fixed
/// for the whole body); `local_defs` is the module's own `name/arity` set, so
/// an `erlang:` BIF is only spelled as a local call when no module function
/// shadows it (each entry is `#(reads, fun depth of the last read)`). `subst`
/// holds the binders whose `let` was dropped because the value is read exactly
/// once and is a literal, a variable, or a pure
/// constructor: the already-translated RHS form, spliced in at that one read.
/// `depth` counts the enclosing `fun`s, so a constructor is only spliced at a
/// read in the same fun (moving an allocation into a closure body would
/// re-run it per call). `consts` maps each constant term (a byte string, or a
/// tuple / list built only from literals) that occurs more than once in the
/// function to the variable bound to it at the top of the body — every
/// occurrence is then a variable read; `sys_core_fold` substitutes a
/// literal-bound variable back at each read, so the compiled code is the same
/// and the form carries the literal once.
type Env {
  Env(
    ln: Int,
    vars: Dict(String, String),
    funs: Dict(#(String, Int), LocalFun),
    uses: Dict(String, #(Int, Int)),
    local_defs: Set(#(String, Int)),
    subst: Dict(String, Form),
    depth: Int,
    consts: Dict(CExpr, String),
  )
}

/// The fresh-name counter, threaded through the whole translation of one
/// top-level function (each function restarts at 0 — Erlang variables are
/// function-scoped, so cross-function uniqueness is not needed).
type St {
  St(counter: Int)
}

/// Mint a fresh (within the current function) Erlang variable name: `V` plus
/// the counter. The raw Core name is deliberately NOT part of it — every
/// distinct variable atom is interned permanently by `compile:forms`, and
/// origin-tagged names (`Vg3010@7`) are unique per module, so a large guest
/// interned tens of thousands of atoms. Counter-only names repeat across
/// functions and modules, so the whole atom cost is one atom per counter
/// value ever reached. `_raw_name` stays in the signature so a debug build
/// can switch the naming back without touching the call sites.
fn fresh(st: St, _raw_name: String) -> #(String, St) {
  #("V" <> int.to_string(st.counter), St(st.counter + 1))
}

/// Bind `raw_name` to a fresh Erlang variable: mint the name and extend the
/// environment so later references (and only references made under the
/// returned env — Core scoping) resolve to it.
fn bind_var(env: Env, st: St, raw_name: String) -> #(String, Env, St) {
  let #(name, st2) = fresh(st, raw_name)
  #(
    name,
    Env(
      ..env,
      vars: dict.insert(env.vars, raw_name, name),
      subst: dict.delete(env.subst, raw_name),
    ),
    st2,
  )
}

// ─────────────────────────────── node constructors ───────────────────────────────
//
// Each helper builds exactly the tuple `erts/absform` documents, with the
// enclosing function's synthetic line as the anno. Patterns share the
// expression shapes (`{var,…}`, `{tuple,…}`, …) exactly as in the format.

fn e_atom(ln: Int, name: String) -> Form {
  raw(#(atom_of("atom"), ln, atom_of(name)))
}

fn e_int(ln: Int, value: Int) -> Form {
  raw(#(atom_of("integer"), ln, value))
}

fn e_float(ln: Int, value: Float) -> Form {
  raw(#(atom_of("float"), ln, value))
}

fn e_var(ln: Int, name: String) -> Form {
  raw(#(atom_of("var"), ln, atom_of(name)))
}

fn e_nil(ln: Int) -> Form {
  raw(#(atom_of("nil"), ln))
}

fn e_cons(ln: Int, head: Form, tail: Form) -> Form {
  raw(#(atom_of("cons"), ln, head, tail))
}

fn e_tuple(ln: Int, elements: List(Form)) -> Form {
  raw(#(atom_of("tuple"), ln, elements))
}

fn e_match(ln: Int, pattern: Form, value: Form) -> Form {
  raw(#(atom_of("match"), ln, pattern, value))
}

fn e_block(ln: Int, body: List(Form)) -> Form {
  raw(#(atom_of("block"), ln, body))
}

fn e_case(ln: Int, arg: Form, clauses: List(Form)) -> Form {
  raw(#(atom_of("case"), ln, arg, clauses))
}

/// `{clause, Anno, Pats, Guards, Body}`. `guards` is `[]` for a guardless
/// clause or `[[G]]` for a single guard test (the only shapes emitted).
fn e_clause(
  ln: Int,
  pats: List(Form),
  guards: List(List(Form)),
  body: List(Form),
) -> Form {
  raw(#(atom_of("clause"), ln, pats, guards, body))
}

fn e_call(ln: Int, target: Form, args: List(Form)) -> Form {
  raw(#(atom_of("call"), ln, target, args))
}

fn e_remote(ln: Int, module: Form, function: Form) -> Form {
  raw(#(atom_of("remote"), ln, module, function))
}

/// `{op, Anno, Op, A}` — a unary operator expression (`-A`, `bnot A`, …).
fn e_op1(ln: Int, op: String, a: Form) -> Form {
  raw(#(atom_of("op"), ln, atom_of(op), a))
}

/// `{op, Anno, Op, A, B}` — a binary operator expression (`A + B`, `A =:= B`, …).
fn e_op2(ln: Int, op: String, a: Form, b: Form) -> Form {
  raw(#(atom_of("op"), ln, atom_of(op), a, b))
}

/// The `erlang` functions Erlang source spells as binary operators.
const binary_ops = [
  "+", "-", "*", "/", "==", "/=", "=:=", "=/=", "<", "=<", ">", ">=", "band",
  "bor", "bxor", "bsl", "bsr", "div", "rem", "and", "or", "xor",
]

/// The auto-imported `erlang` BIFs a generated module calls, as `name/arity`.
/// A call to one is a plain local call unless the module defines a function
/// of the same name and arity (then the qualified form is kept — an
/// unqualified call would be rejected as ambiguous).
const auto_bifs = [
  #("is_atom", 1),
  #("is_binary", 1),
  #("is_bitstring", 1),
  #("is_boolean", 1),
  #("is_float", 1),
  #("is_function", 1),
  #("is_function", 2),
  #("is_integer", 1),
  #("is_list", 1),
  #("is_map", 1),
  #("is_number", 1),
  #("is_pid", 1),
  #("is_port", 1),
  #("is_reference", 1),
  #("is_tuple", 1),
  #("hd", 1),
  #("tl", 1),
  #("element", 2),
  #("setelement", 3),
  #("tuple_size", 1),
  #("map_size", 1),
  #("byte_size", 1),
  #("bit_size", 1),
  #("length", 1),
  #("size", 1),
  #("abs", 1),
  #("trunc", 1),
  #("round", 1),
  #("float", 1),
  #("max", 2),
  #("min", 2),
]

/// `erlang:F(Args)` as a local call when `F/n` is an auto-imported BIF the
/// module does not shadow, else the qualified remote call.
fn erlang_call(
  ln: Int,
  f: String,
  n: Int,
  argfs: List(Form),
  env: Env,
) -> Form {
  let local =
    list.contains(auto_bifs, #(f, n)) && !set.contains(env.local_defs, #(f, n))
  case local {
    True -> e_call(ln, e_atom(ln, f), argfs)
    False ->
      e_call(ln, e_remote(ln, e_atom(ln, "erlang"), e_atom(ln, f)), argfs)
  }
}

fn e_fun(ln: Int, clauses: List(Form)) -> Form {
  raw(#(atom_of("fun"), ln, #(atom_of("clauses"), clauses)))
}

fn e_named_fun(ln: Int, name: String, clauses: List(Form)) -> Form {
  raw(#(atom_of("named_fun"), ln, atom_of(name), clauses))
}

/// `{'fun', Anno, {function, Name, Arity}}` — a bare reference to a local
/// top-level function as a VALUE (`fun 'f'/N`), not a call.
fn e_fun_ref(ln: Int, name: String, arity: Int) -> Form {
  raw(#(atom_of("fun"), ln, #(atom_of("function"), atom_of(name), arity)))
}

/// `{'try', Anno, Body, CaseClauses, CatchClauses, After=[]}`.
fn e_try(
  ln: Int,
  body: List(Form),
  case_clauses: List(Form),
  catch_clauses: List(Form),
) -> Form {
  let after: List(Form) = []
  raw(#(atom_of("try"), ln, body, case_clauses, catch_clauses, after))
}

fn e_bin(ln: Int, elements: List(Form)) -> Form {
  raw(#(atom_of("bin"), ln, elements))
}

/// One `{bin_element, Anno, Value, Size, TSL}` segment; `tsl` is the
/// type-specifier list (`[integer, {unit,1}, unsigned, big]`-style).
fn e_bin_element(ln: Int, value: Form, size: Form, tsl: List(Form)) -> Form {
  raw(#(atom_of("bin_element"), ln, value, size, tsl))
}

/// One `{bin_element, Anno, {string, Anno, Bytes}, default, default}` segment
/// holding a whole byte string: the default 8-bit integer type is byte-exact for
/// bytes 0..255, so the binary is `Bytes` verbatim in ONE segment.
fn e_bytes_element(ln: Int, bytes: BitArray) -> Form {
  let default = atom_of("default")
  let value = #(atom_of("string"), ln, bytes_to_list(bytes))
  raw(#(atom_of("bin_element"), ln, value, default, default))
}

/// A proper-list EAF term `[E1, E2, …]` (a `{cons,…}` chain ending `{nil,…}`)
/// — used for the packed argument list of a multi-def `letrec` dispatch call,
/// and as the matching list PATTERN (same shape) on the receiving clause.
fn e_list(ln: Int, elements: List(Form)) -> Form {
  list.fold_right(elements, e_nil(ln), fn(acc, e) { e_cons(ln, e, acc) })
}

// ─────────────────────────────── expression translation ───────────────────────────────

/// Translate a list of single-value expressions in order, threading the fresh
/// counter. Returns the forms in the input order.
fn tr_exprs(
  exprs: List(CExpr),
  env: Env,
  st: St,
) -> Result(#(List(Form), St), EafError) {
  use #(rev, st2) <- result.try(
    list.try_fold(exprs, #([], st), fn(acc, e) {
      let #(forms, st0) = acc
      use #(f, st1) <- result.try(tr_expr(e, env, st0))
      Ok(#([f, ..forms], st1))
    }),
  )
  Ok(#(list.reverse(rev), st2))
}

/// Translate one single-value Core expression to an EAF expression.
///
/// Returns the form plus the advanced counter, or the `EafError` describing
/// which `emit_core` invariant the input broke. `let`/`letrec` chains are
/// routed through `tr_body` and wrapped in a `begin … end` block only when the
/// chain has more than one statement.
fn tr_expr(expr: CExpr, env: Env, st: St) -> Result(#(Form, St), EafError) {
  let ln = env.ln
  case expr {
    CVar(name) -> {
      // A reference must resolve to an in-scope binder. The fallback (raw
      // legalized name under a prefix no `fresh` name can wear) is
      // defensively deterministic for an unbound reference — erl_lint then
      // reports it as unbound, fail-closed.
      case dict.get(env.subst, name) {
        Ok(spliced) -> Ok(#(spliced, st))
        Error(Nil) -> {
          let v = case dict.get(env.vars, name) {
            Ok(n) -> n
            Error(Nil) -> "Unbound@" <> core_printer.legalize_var(name)
          }
          Ok(#(e_var(ln, v), st))
        }
      }
    }
    CInt(v) -> Ok(#(e_int(ln, v), st))
    CFloat(v) -> Ok(#(e_float(ln, v), st))
    CAtom(name) -> Ok(#(e_atom(ln, name), st))
    CNil -> Ok(#(e_nil(ln), st))
    CCons(head, tail) ->
      case dict.get(env.consts, expr) {
        Ok(v) -> Ok(#(e_var(ln, v), st))
        Error(Nil) -> {
          use #(h, st1) <- result.try(tr_expr(head, env, st))
          use #(t, st2) <- result.try(tr_expr(tail, env, st1))
          Ok(#(e_cons(ln, h, t), st2))
        }
      }
    CTuple(elements) ->
      case dict.get(env.consts, expr) {
        Ok(v) -> Ok(#(e_var(ln, v), st))
        Error(Nil) -> {
          use #(es, st1) <- result.try(tr_exprs(elements, env, st))
          Ok(#(e_tuple(ln, es), st1))
        }
      }
    CBinary(segments) -> {
      use #(rev, st1) <- result.try(
        list.try_fold(segments, #([], st), fn(acc, seg) {
          let #(fs, st0) = acc
          use #(f, stn) <- result.try(tr_bitseg(seg, env, st0))
          Ok(#([f, ..fs], stn))
        }),
      )
      Ok(#(e_bin(ln, list.reverse(rev)), st1))
    }
    CBytes(bytes) ->
      case dict.get(env.consts, expr) {
        Ok(v) -> Ok(#(e_var(ln, v), st))
        Error(Nil) -> Ok(#(e_bin(ln, [e_bytes_element(ln, bytes)]), st))
      }
    CValues(values) -> Error(BareValueList(list.length(values)))
    CFun(vars, body) -> {
      let #(params, env2, st1) =
        bind_params(vars, Env(..env, depth: env.depth + 1), st)
      use #(bodyf, st2) <- result.try(tr_body(body, env2, st1))
      Ok(#(e_fun(ln, [e_clause(ln, params, [], bodyf)]), st2))
    }
    CLet(_, _, _) | CLetrec(_, _) -> {
      use #(stmts, st1) <- result.try(tr_body(expr, env, st))
      case stmts {
        [single] -> Ok(#(single, st1))
        _ -> Ok(#(e_block(ln, stmts), st1))
      }
    }
    CCase(arg, clauses) -> {
      use #(argf, st1) <- result.try(tr_expr(arg, env, st))
      use #(rev, st2) <- result.try(
        list.try_fold(clauses, #([], st1), fn(acc, cl) {
          let #(fs, st0) = acc
          use #(f, stn) <- result.try(tr_clause(cl, env, st0))
          Ok(#([f, ..fs], stn))
        }),
      )
      Ok(#(e_case(ln, argf, list.reverse(rev)), st2))
    }
    CApply(FName(name, arity), args) -> {
      use #(argfs, st1) <- result.try(tr_exprs(args, env, st))
      case dict.get(env.funs, #(name, arity)) {
        Ok(DirectFun(v)) -> Ok(#(e_call(ln, e_var(ln, v), argfs), st1))
        Ok(DispatchFun(v, tag)) ->
          Ok(#(
            e_call(ln, e_var(ln, v), [e_atom(ln, tag), e_list(ln, argfs)]),
            st1,
          ))
        Error(_) -> Ok(#(e_call(ln, e_atom(ln, name), argfs), st1))
      }
    }
    // A funref names an `FName` as a VALUE rather than calling it. Resolution
    // mirrors `CApply`: a `letrec` def lowered to a named-fun variable IS the
    // fun value, so hand out the variable; an `FName` absent from `env.funs` is
    // a top-level module function, so emit `fun 'name'/Arity`. The dispatch
    // lowering has no such value (see `DispatchFunRef`).
    CFunRef(FName(name, arity)) ->
      case dict.get(env.funs, #(name, arity)) {
        Ok(DirectFun(v)) -> Ok(#(e_var(ln, v), st))
        Ok(DispatchFun(_, _)) -> Error(DispatchFunRef(name, arity))
        Error(_) -> Ok(#(e_fun_ref(ln, name, arity), st))
      }
    CApplyExpr(op, args) -> {
      use #(opf, st1) <- result.try(tr_expr(op, env, st))
      use #(argfs, st2) <- result.try(tr_exprs(args, env, st1))
      Ok(#(e_call(ln, opf, argfs), st2))
    }
    // An `erlang:` operator or auto-imported BIF is spelled the way Erlang
    // source spells it — `A + B` / `is_integer(X)` — instead of a fully
    // qualified remote call. `v3_core` lowers both spellings to the same
    // `call 'erlang':'f'`, so the compiled code is identical; the abstract
    // form is 9–16 words smaller per site (a `remote` node and two atoms).
    CCall(CAtom("erlang"), CAtom(f), args) -> {
      use #(argfs, st1) <- result.try(tr_exprs(args, env, st))
      let n = list.length(args)
      case argfs {
        [a] if f == "-" || f == "+" || f == "bnot" || f == "not" ->
          Ok(#(e_op1(ln, f, a), st1))
        [a, b] -> {
          let is_op = list.contains(binary_ops, f)
          case is_op {
            True -> Ok(#(e_op2(ln, f, a, b), st1))
            False -> Ok(#(erlang_call(ln, f, n, argfs, env), st1))
          }
        }
        _ -> Ok(#(erlang_call(ln, f, n, argfs, env), st1))
      }
    }
    CCall(module, function, args) -> {
      use #(mf, st1) <- result.try(tr_expr(module, env, st))
      use #(ff, st2) <- result.try(tr_expr(function, env, st1))
      use #(argfs, st3) <- result.try(tr_exprs(args, env, st2))
      Ok(#(e_call(ln, e_remote(ln, mf, ff), argfs), st3))
    }
    // `primop 'build_stacktrace'(RawS)` exists in Core because the caught
    // stacktrace token is raw there; an Erlang `catch C:R:S` binds the
    // already-built stacktrace, so the primop is the identity here.
    CPrimop("build_stacktrace", [arg]) -> tr_expr(arg, env, st)
    CPrimop(name, _) -> Error(UnsupportedPrimop(name))
    CTry(arg, body_vars, body, evars, handler) ->
      case body_vars, evars {
        [bv], [ec, er, es] -> {
          use #(argf, st1) <- result.try(tr_expr(arg, env, st))
          let #(bvn, benv, st2) = bind_var(env, st1, bv)
          use #(bodyf, st3) <- result.try(tr_body(body, benv, st2))
          let #(ecn, henv1, st4) = bind_var(env, st3, ec)
          let #(ern, henv2, st5) = bind_var(henv1, st4, er)
          let #(esn, henv3, st6) = bind_var(henv2, st5, es)
          use #(handlerf, st7) <- result.try(tr_body(handler, henv3, st6))
          Ok(#(
            e_try(ln, [argf], [e_clause(ln, [e_var(ln, bvn)], [], bodyf)], [
              e_clause(
                ln,
                [
                  e_tuple(ln, [
                    e_var(ln, ecn),
                    e_var(ln, ern),
                    e_var(ln, esn),
                  ]),
                ],
                [],
                handlerf,
              ),
            ]),
            st7,
          ))
        }
        _, _ -> Error(BadTryShape(list.length(body_vars), list.length(evars)))
      }
  }
}

/// One binary segment: `#<V>(Size, Unit, Type, Flags)` →
/// `{bin_element, Anno, V, Size, [Type, {unit,Unit}, Flags…]}`.
fn tr_bitseg(seg: CBitSeg, env: Env, st: St) -> Result(#(Form, St), EafError) {
  let ln = env.ln
  let CBitSeg(value, size, unit, segtype, flags) = seg
  use #(vf, st1) <- result.try(tr_expr(value, env, st))
  use #(sf, st2) <- result.try(tr_expr(size, env, st1))
  let tsl =
    list.append(
      [raw(atom_of(segtype)), raw(#(atom_of("unit"), unit))],
      list.map(flags, fn(f) { raw(atom_of(f)) }),
    )
  Ok(#(e_bin_element(ln, vf, sf, tsl), st2))
}

/// Bind a fun/def parameter list to fresh Erlang variables, in order.
/// Returns the parameter pattern forms, the extended environment, and the
/// advanced counter.
fn bind_params(
  params: List(String),
  env: Env,
  st: St,
) -> #(List(Form), Env, St) {
  let #(rev, env2, st2) =
    list.fold(params, #([], env, st), fn(acc, p) {
      let #(fs, env0, st0) = acc
      let #(n, env1, st1) = bind_var(env0, st0, p)
      #([e_var(env.ln, n), ..fs], env1, st1)
    })
  #(list.reverse(rev), env2, st2)
}

/// Translate one `case` clause. The pattern list is always singleton (the
/// value-list wrapper the printer used was cosmetic — every emitted scrutinee
/// is single-valued); pattern variables are fresh binders extending the
/// clause-local environment, exactly Core's shadowing semantics.
fn tr_clause(cl: CClause, env: Env, st: St) -> Result(#(Form, St), EafError) {
  let ln = env.ln
  let CClause(pats, guard, body) = cl
  case pats {
    [p] -> {
      let #(pf, env2, st1) = tr_pat(p, env, st)
      use #(guards, st2) <- result.try(case guard {
        CAtom("true") -> Ok(#([], st1))
        _ -> {
          use #(gf, stg) <- result.try(tr_expr(guard, env2, st1))
          Ok(#([[gf]], stg))
        }
      })
      use #(bodyf, st3) <- result.try(tr_body(body, env2, st2))
      Ok(#(e_clause(ln, [pf], guards, bodyf), st3))
    }
    _ -> Error(BadClauseArity(list.length(pats)))
  }
}

/// Translate a Core pattern. Every `PVar` is a FRESH binder (alpha-renamed),
/// so in the produced EAF it is guaranteed unbound — i.e. it always binds,
/// never degenerates into Erlang's bound-variable equality check, preserving
/// Core's binding semantics. Total (patterns contain no failing shapes).
fn tr_pat(pat: CPat, env: Env, st: St) -> #(Form, Env, St) {
  let ln = env.ln
  case pat {
    PVar(name) -> {
      let #(n, env2, st2) = bind_var(env, st, name)
      #(e_var(ln, n), env2, st2)
    }
    PInt(v) -> #(e_int(ln, v), env, st)
    PAtom(name) -> #(e_atom(ln, name), env, st)
    PNil -> #(e_nil(ln), env, st)
    PCons(head, tail) -> {
      let #(hf, env1, st1) = tr_pat(head, env, st)
      let #(tf, env2, st2) = tr_pat(tail, env1, st1)
      #(e_cons(ln, hf, tf), env2, st2)
    }
    PTuple(elements) -> {
      let #(rev, env2, st2) =
        list.fold(elements, #([], env, st), fn(acc, p) {
          let #(fs, env0, st0) = acc
          let #(f, env1, st1) = tr_pat(p, env0, st0)
          #([f, ..fs], env1, st1)
        })
      #(e_tuple(ln, list.reverse(rev)), env2, st2)
    }
  }
}

// ─────────────────────────────── body (statement-list) translation ───────────────────────────────

/// Translate an expression into a NON-EMPTY statement list — the body of a
/// clause/fun. `let` and `letrec` chains flatten into sequential `match`
/// statements instead of nesting `begin … end` blocks hundreds deep (large
/// guests chain thousands of `let`s):
///
/// - `let X = A in B`         → `X@n = A′, B′…`
/// - `let <X,Y> = <A,B> in C` → `X@n = A′, Y@m = B′, C′…` (RHS values are
///   translated in the OUTER scope first — Core evaluates the whole value
///   list before binding — then bound pairwise; the binders are fresh, so the
///   interleaved match order is observationally identical).
/// - `let <> = <> in B`       → `B′…` (the vacuous zero-binder let).
/// - `letrec 'f'/n = fun … in B` → `F@n = fun F@n(…) -> … end, B′…`.
fn tr_body(
  expr: CExpr,
  env: Env,
  st: St,
) -> Result(#(List(Form), St), EafError) {
  let ln = env.ln
  case expr {
    CLet([], CValues([]), body) -> tr_body(body, env, st)
    CLet([], arg, body) -> {
      // A zero-binder let over a non-empty RHS: evaluate for effect, discard.
      use #(argf, st1) <- result.try(tr_expr(arg, env, st))
      use #(rest, st2) <- result.try(tr_body(body, env, st1))
      Ok(#([argf, ..rest], st2))
    }
    // `let G = A in case G of <{V, St}> -> B` where `G` is read nowhere but
    // in that scrutinee is a destructuring bind spelled through a temporary
    // (the shape `emit_core`'s let-case tail emits); it lowers to the single
    // match `{V, St} = A′` — `v3_core` binds a case-valued match through a
    // fresh variable anyway, so the compiled code is the same and the form is
    // one match and two variables smaller.
    CLet(
      [g],
      arg,
      CCase(CVar(g2), [CClause([pat], CAtom("true"), cbody)]) as body,
    )
      if g == g2
    -> {
      case binder_pat(pat) && read_once(env, g) {
        True -> {
          use #(argf, st1) <- result.try(tr_expr(arg, env, st))
          let #(pf, env2, st2) = tr_pat(pat, env, st1)
          use #(rest, st3) <- result.try(tr_body(cbody, env2, st2))
          Ok(#([e_match(ln, pf, argf), ..rest], st3))
        }
        False -> tr_let1(g, arg, body, env, st)
      }
    }
    CLet([x], arg, body) -> tr_let1(x, arg, body, env, st)
    CLet(vars, CValues(vals), body) -> {
      let nv = list.length(vars)
      case nv == list.length(vals) {
        False -> Error(BadValueBinding(nv, list.length(vals)))
        True -> {
          // Translate every RHS value in the OUTER scope first (Core
          // evaluates the full value list before any binder is in scope)…
          use #(valfs, st1) <- result.try(tr_exprs(vals, env, st))
          // …then bind the names and pair them up as sequential matches.
          let #(rev_names, env2, st2) =
            list.fold(vars, #([], env, st1), fn(acc, v) {
              let #(ns, env0, st0) = acc
              let #(n, env1, stn) = bind_var(env0, st0, v)
              #([n, ..ns], env1, stn)
            })
          let matches =
            list.map2(list.reverse(rev_names), valfs, fn(n, vf) {
              e_match(ln, e_var(ln, n), vf)
            })
          use #(rest, st3) <- result.try(tr_body(body, env2, st2))
          Ok(#(list.append(matches, rest), st3))
        }
      }
    }
    CLet(vars, arg, body) -> {
      // A multi-binder let over a computed RHS (a `case`/`let` chain whose
      // leaves are value lists). Erlang has no multi-value expressions, so
      // every leaf becomes a tuple and the binders match against it:
      // `let <X,Y> = E in B` → `{X@n, Y@m} = E′, B′…`.
      use #(argf, st1) <- result.try(tr_expr(tuple_leaves(arg), env, st))
      let #(pat, env2, st2) = tr_pat(PTuple(list.map(vars, PVar)), env, st1)
      use #(rest, st3) <- result.try(tr_body(body, env2, st2))
      Ok(#([e_match(ln, pat, argf), ..rest], st3))
    }
    CLetrec(defs, inner) -> tr_letrec(defs, inner, env, st)
    // A one-clause unguarded `case` in tail position whose pattern is a
    // variable or a (nested) tuple of variables is Core's spelling of a
    // destructuring bind (`case E of <{V, St}> when 'true' -> B`); it lowers
    // to `{V, St} = E′, B′…` — one match statement, no clause list, and the
    // clause body flattens into the enclosing statement list.
    CCase(arg, [CClause([pat], CAtom("true"), body)]) -> {
      case binder_pat(pat) {
        True -> {
          use #(argf, st1) <- result.try(tr_expr(arg, env, st))
          let #(pf, env2, st2) = tr_pat(pat, env, st1)
          use #(rest, st3) <- result.try(tr_body(body, env2, st2))
          Ok(#([e_match(ln, pf, argf), ..rest], st3))
        }
        False -> {
          use #(f, st1) <- result.try(tr_expr(expr, env, st))
          Ok(#([f], st1))
        }
      }
    }
    _ -> {
      use #(f, st1) <- result.try(tr_expr(expr, env, st))
      Ok(#([f], st1))
    }
  }
}

/// `let X = A in B` → `X@n = A′, B′…` — unless `X` is read exactly once and
/// `A` is a literal, a variable, or a pure constructor (`splice_kind`), in
/// which case the match is dropped and `A′` is spliced in at that read.
fn tr_let1(
  x: String,
  arg: CExpr,
  body: CExpr,
  env: Env,
  st: St,
) -> Result(#(List(Form), St), EafError) {
  let ln = env.ln
  use #(argf, st1) <- result.try(tr_expr(arg, env, st))
  let splice = case dict.get(env.uses, x), splice_kind(arg) {
    Ok(#(1, _)), Anywhere -> True
    Ok(#(1, d)), SameFun -> d == env.depth
    _, _ -> False
  }
  case splice {
    True -> {
      let env2 = Env(..env, subst: dict.insert(env.subst, x, argf))
      tr_body(body, env2, st1)
    }
    False -> {
      let #(xn, env2, st2) = bind_var(env, st1, x)
      use #(rest, st3) <- result.try(tr_body(body, env2, st2))
      Ok(#([e_match(ln, e_var(ln, xn), argf), ..rest], st3))
    }
  }
}

/// Is `x` read exactly once in the function?
fn read_once(env: Env, x: String) -> Bool {
  case dict.get(env.uses, x) {
    Ok(#(1, _)) -> True
    _ -> False
  }
}

/// How a `let` RHS may be spliced into its single read: `Anywhere` for a
/// literal / variable / fun reference (no evaluation to move — a variable
/// read inside a nested fun is an ordinary closure capture, and the spliced
/// form is the already-renamed variable, so a later shadowing rebinding of
/// the raw name cannot capture it); `SameFun` for a tuple / cons of such
/// values (a pure allocation that must not move into a closure body);
/// `NoSplice` for anything else (calls, cases, …).
type Splice {
  Anywhere
  SameFun
  NoSplice
}

fn splice_kind(arg: CExpr) -> Splice {
  case arg {
    CVar(_) | CInt(_) | CFloat(_) | CAtom(_) | CNil | CBytes(_) | CFunRef(_) ->
      Anywhere
    CTuple(es) ->
      case list.all(es, fn(e) { splice_kind(e) != NoSplice }) {
        True -> SameFun
        False -> NoSplice
      }
    CCons(h, t) ->
      case splice_kind(h) != NoSplice && splice_kind(t) != NoSplice {
        True -> SameFun
        False -> NoSplice
      }
    _ -> NoSplice
  }
}

/// How many times each raw variable name is READ (a `CVar` in expression
/// position; binders and pattern variables do not count) across `expr`,
/// paired with the fun depth of its LAST read (`depth` = enclosing `fun`s /
/// `letrec` bodies; only meaningful for a variable read once).
fn count_uses(
  expr: CExpr,
  depth: Int,
  acc: Dict(String, #(Int, Int)),
) -> Dict(String, #(Int, Int)) {
  let go = fn(a, e) { count_uses(e, depth, a) }
  case expr {
    CVar(name) ->
      dict.upsert(acc, name, fn(prev) {
        case prev {
          option.Some(#(n, _)) -> #(n + 1, depth)
          option.None -> #(1, depth)
        }
      })
    CInt(_) | CFloat(_) | CAtom(_) | CNil | CBytes(_) | CFunRef(_) -> acc
    CCons(h, t) -> go(go(acc, h), t)
    CTuple(es) | CValues(es) | CPrimop(_, es) -> list.fold(es, acc, go)
    CBinary(segs) ->
      list.fold(segs, acc, fn(a, seg) { go(go(a, seg.value), seg.size) })
    CFun(_, body) -> count_uses(body, depth + 1, acc)
    CLet(_, arg, body) -> go(go(acc, arg), body)
    CLetrec(defs, body) ->
      list.fold(defs, go(acc, body), fn(a, d) { count_uses(d.value, depth, a) })
    CCase(arg, clauses) ->
      list.fold(clauses, go(acc, arg), fn(a, cl) {
        go(go(a, cl.guard), cl.body)
      })
    CApply(_, args) -> list.fold(args, acc, go)
    CApplyExpr(op, args) -> list.fold(args, go(acc, op), go)
    CCall(m, f, args) -> list.fold(args, go(go(acc, m), f), go)
    CTry(arg, _, body, _, handler) -> go(go(go(acc, arg), body), handler)
  }
}

/// How many times each constant term worth sharing (`is_const_term`) occurs
/// across `expr`. A constant nested inside a larger constant counts only as
/// part of the larger one.
fn count_consts(expr: CExpr, acc: Dict(CExpr, Int)) -> Dict(CExpr, Int) {
  let go = fn(a, e) { count_consts(e, a) }
  case is_const_term(expr) {
    True -> dict.upsert(acc, expr, fn(n) { option.unwrap(n, 0) + 1 })
    False ->
      case expr {
        CVar(_)
        | CInt(_)
        | CFloat(_)
        | CAtom(_)
        | CNil
        | CFunRef(_)
        | CBytes(_) -> acc
        CCons(h, t) -> go(go(acc, h), t)
        CTuple(es) | CValues(es) | CPrimop(_, es) -> list.fold(es, acc, go)
        CBinary(segs) ->
          list.fold(segs, acc, fn(a, seg) { go(go(a, seg.value), seg.size) })
        CFun(_, body) -> go(acc, body)
        CLet(_, arg, body) -> go(go(acc, arg), body)
        CLetrec(defs, body) ->
          list.fold(defs, go(acc, body), fn(a, d) { go(a, d.value) })
        CCase(arg, clauses) ->
          list.fold(clauses, go(acc, arg), fn(a, cl) {
            go(go(a, cl.guard), cl.body)
          })
        CApply(_, args) -> list.fold(args, acc, go)
        CApplyExpr(op, args) -> list.fold(args, go(acc, op), go)
        CCall(m, f, args) -> list.fold(args, go(go(acc, m), f), go)
        CTry(arg, _, body, _, handler) -> go(go(go(acc, arg), body), handler)
      }
  }
}

/// A byte string, or a tuple / cons cell whose parts are all literals — a
/// term the compiler turns into one literal, and one whose form is bigger
/// than a variable read (an atom / integer / `[]` alone is not).
fn is_const_term(expr: CExpr) -> Bool {
  case expr {
    CBytes(_) -> True
    CTuple(es) -> list.all(es, is_literal)
    CCons(h, t) -> is_literal(h) && is_literal(t)
    _ -> False
  }
}

fn is_literal(expr: CExpr) -> Bool {
  case expr {
    CInt(_) | CFloat(_) | CAtom(_) | CNil | CBytes(_) -> True
    CTuple(es) -> list.all(es, is_literal)
    CCons(h, t) -> is_literal(h) && is_literal(t)
    _ -> False
  }
}

/// Is `pat` a variable or a tuple whose leaves are all variables?
fn binder_pat(pat: CPat) -> Bool {
  case pat {
    PVar(_) -> True
    PTuple(elements) -> list.all(elements, binder_pat)
    PInt(_) | PAtom(_) | PNil | PCons(_, _) -> False
  }
}

/// Rewrite every value-list leaf of `expr` (in tail position through `let`,
/// `letrec`, `case` clauses and `try` arms) into a tuple, so a multi-value
/// expression can be bound by a single tuple match.
fn tuple_leaves(expr: CExpr) -> CExpr {
  case expr {
    CValues(values) -> CTuple(values)
    CLet(vars, arg, body) -> CLet(vars, arg, tuple_leaves(body))
    CLetrec(defs, body) -> CLetrec(defs, tuple_leaves(body))
    CCase(arg, clauses) ->
      CCase(
        arg,
        list.map(clauses, fn(cl) {
          CClause(cl.pats, cl.guard, tuple_leaves(cl.body))
        }),
      )
    CTry(arg, body_vars, body, evars, handler) ->
      CTry(arg, body_vars, tuple_leaves(body), evars, tuple_leaves(handler))
    _ -> expr
  }
}

/// Lower a `letrec` (see the module doc): a single def becomes a named fun
/// bound to a variable of the same name (`F = fun F(…) -> … end` — the outer
/// `F` and the fun-name `F` are the same fun value, so one name serves both
/// the letrec body and the recursive calls); multiple defs become one
/// tag-dispatching named fun.
fn tr_letrec(
  defs: List(FunDef),
  inner: CExpr,
  env: Env,
  st: St,
) -> Result(#(List(Form), St), EafError) {
  let ln = env.ln
  case defs {
    [FunDef(FName(name, arity), CFun(params, fbody))] -> {
      let #(fvar, st1) = fresh(st, name)
      let env2 =
        Env(..env, funs: dict.insert(env.funs, #(name, arity), DirectFun(fvar)))
      let #(pforms, env3, st2) =
        bind_params(params, Env(..env2, depth: env2.depth + 1), st1)
      use #(bodyf, st3) <- result.try(tr_body(fbody, env3, st2))
      let named = e_named_fun(ln, fvar, [e_clause(ln, pforms, [], bodyf)])
      use #(rest, st4) <- result.try(tr_body(inner, env2, st3))
      Ok(#([e_match(ln, e_var(ln, fvar), named), ..rest], st4))
    }
    [FunDef(FName(name, _), _)] -> Error(NonFunDef(name))
    _ -> {
      // Mutually recursive group → one dispatcher. Not currently emitted
      // (emit_core always produces singleton letrecs) but lowered for
      // totality: R = fun R(tag_i, [P…]) -> body_i end, calls become
      // R(tag_j, [args…]) — still tail calls.
      let #(rvar, st1) = fresh(st, "letrec")
      let env2 =
        list.fold(defs, env, fn(acc, def) {
          let FunDef(FName(name, arity), _) = def
          let tag = name <> "/" <> int.to_string(arity)
          Env(
            ..acc,
            funs: dict.insert(acc.funs, #(name, arity), DispatchFun(rvar, tag)),
          )
        })
      use #(clauses_rev2, st2) <- result.try(
        list.try_fold(defs, #([], st1), fn(acc, def) {
          let #(cls, st0) = acc
          case def {
            FunDef(FName(name, arity), CFun(params, fbody)) -> {
              let tag = name <> "/" <> int.to_string(arity)
              let #(pforms, env3, stp) =
                bind_params(params, Env(..env2, depth: env2.depth + 1), st0)
              use #(bodyf, stb) <- result.try(tr_body(fbody, env3, stp))
              Ok(#(
                [
                  e_clause(ln, [e_atom(ln, tag), e_list(ln, pforms)], [], bodyf),
                  ..cls
                ],
                stb,
              ))
            }
            FunDef(FName(name, _), _) -> Error(NonFunDef(name))
          }
        }),
      )
      let named = e_named_fun(ln, rvar, list.reverse(clauses_rev2))
      use #(rest, st4) <- result.try(tr_body(inner, env2, st2))
      Ok(#([e_match(ln, e_var(ln, rvar), named), ..rest], st4))
    }
  }
}

// ─────────────────────────────── module translation ───────────────────────────────

/// Convert a literal Core expression into a plain-term EAF ATTRIBUTE value
/// (attribute values are terms, not expression nodes). Only literal shapes are
/// convertible; anything else is `Error(Nil)` (the caller maps it to
/// `UnsupportedAttribute`).
fn lit_term(expr: CExpr) -> Result(Form, Nil) {
  case expr {
    CInt(v) -> Ok(raw(v))
    CFloat(v) -> Ok(raw(v))
    CAtom(name) -> Ok(raw(atom_of(name)))
    CNil -> Ok(raw(empty_term_list()))
    CCons(_, _) -> {
      // A literal PROPER list (a Gleam `List(Form)` IS the Erlang list term);
      // an improper tail is not emitted and falls out as `Error(Nil)`.
      use elements <- result.try(lit_list(expr, []))
      Ok(raw(elements))
    }
    CTuple(els) -> {
      use fs <- result.try(list.try_map(els, lit_term))
      Ok(term_tuple(fs))
    }
    _ -> Error(Nil)
  }
}

/// The empty list as a plain term (typed helper so `raw` sees a `List(Form)`).
fn empty_term_list() -> List(Form) {
  []
}

/// Walk a literal `CCons` chain into a `List(Form)` of element terms;
/// `Error(Nil)` on an improper tail or a non-literal element.
fn lit_list(expr: CExpr, acc: List(Form)) -> Result(List(Form), Nil) {
  case expr {
    CNil -> Ok(list.reverse(acc))
    CCons(h, t) -> {
      use hf <- result.try(lit_term(h))
      lit_list(t, [hf, ..acc])
    }
    _ -> Error(Nil)
  }
}

/// `erlang:list_to_tuple/1` — build a plain tuple TERM from element terms
/// (attribute values only; expression nodes never go through here).
@external(erlang, "erlang", "list_to_tuple")
fn term_tuple(elements: List(Form)) -> Form

/// Translate one top-level definition `'name'/arity = fun (…) -> …` into a
/// `{function, Line, Name, Arity, [Clause]}` form. `idx` (0-based def
/// position) supplies the synthetic line (`idx + 1`) annotating every node in
/// the function, so runtime stacktrace lines identify the generated function.
fn tr_def(
  def: FunDef,
  idx: Int,
  local_defs: Set(#(String, Int)),
) -> Result(Form, EafError) {
  let FunDef(FName(name, arity), value) = def
  case value {
    CFun(params, body) -> {
      let ln = idx + 1
      let env =
        Env(
          ln: ln,
          vars: dict.new(),
          funs: dict.new(),
          uses: count_uses(body, 0, dict.new()),
          local_defs: local_defs,
          subst: dict.new(),
          depth: 0,
          consts: dict.new(),
        )
      let st = St(0)
      let #(pforms, env2, st1) = bind_params(params, env, st)
      // Bind each constant term that occurs more than once to a variable
      // ahead of the body (see `Env.consts`).
      let repeated =
        count_consts(body, dict.new())
        |> dict.filter(fn(_, n) { n > 1 })
        |> dict.keys
      use #(hoisted, env3, st2) <- result.try(
        list.try_fold(repeated, #([], env2, st1), fn(acc, term) {
          let #(ms, env0, st0) = acc
          use #(tf, stt) <- result.try(tr_expr(term, env0, st0))
          let #(v, stn) = fresh(stt, "const")
          Ok(#(
            [e_match(ln, e_var(ln, v), tf), ..ms],
            Env(..env0, consts: dict.insert(env0.consts, term, v)),
            stn,
          ))
        }),
      )
      use #(bodyf, _st3) <- result.try(tr_body(body, env3, st2))
      Ok(
        raw(
          #(atom_of("function"), ln, atom_of(name), arity, [
            e_clause(ln, pforms, [], list.append(list.reverse(hoisted), bodyf)),
          ]),
        ),
      )
    }
    _ -> Error(NonFunDef(name))
  }
}

/// Lower a whole Core-shaped module to its Erlang Abstract Format form list:
/// `-module` and `-export` attributes, any literal module attributes, then one
/// `{function,…}` form per definition (def order preserved; the n-th function
/// is annotated line `n+1`).
///
/// The result is exactly what `compile:forms/2` consumes
/// (`carder_codegen_ffi:compile_forms/1` / the linker's `to_core` entry) —
/// `module_info/0,1` are NOT emitted (the compiler adds them itself on the
/// abstract-forms path, unlike `from_core`).
///
/// Returns `Ok(forms)` or the first `EafError` (each variant marks an
/// `emit_core` invariant violation — see the type). Total — never panics.
pub fn module_forms(m: CModule) -> Result(List(Form), EafError) {
  let mod_attr =
    raw(#(atom_of("attribute"), 1, atom_of("module"), atom_of(m.name)))
  let exports =
    list.map(m.exports, fn(f) {
      let FName(name, arity) = f
      raw(#(atom_of(name), arity))
    })
  let exp_attr = raw(#(atom_of("attribute"), 1, atom_of("export"), exports))
  use attrs <- result.try(
    list.try_map(m.attributes, fn(kv) {
      let #(key, value) = kv
      case lit_term(value) {
        Ok(term) -> Ok(raw(#(atom_of("attribute"), 1, atom_of(key), term)))
        Error(Nil) -> Error(UnsupportedAttribute(key))
      }
    }),
  )
  let local_defs =
    list.map(m.defs, fn(def) {
      let FName(name, arity) = def.name
      #(name, arity)
    })
    |> set.from_list
  use defs <- result.try(
    list.index_map(m.defs, fn(def, idx) { #(def, idx) })
    |> list.try_map(fn(pair) { tr_def(pair.0, pair.1, local_defs) }),
  )
  Ok(list.flatten([[mod_attr, exp_attr], attrs, defs]))
}
