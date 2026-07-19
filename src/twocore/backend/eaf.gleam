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
//// `twocore_codegen_ffi:compile_forms/1`). From Gleam an EAF node is just a
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

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import twocore/backend/core_erlang.{
  type CBitSeg, type CClause, type CExpr, type CModule, type CPat, type FunDef,
  CApply, CApplyExpr, CAtom, CBinary, CBitSeg, CCall, CCase, CClause, CCons,
  CFloat, CFun, CInt, CLet, CLetrec, CNil, CPrimop, CTry, CTuple, CValues, CVar,
  FName, FunDef, PAtom, PCons, PInt, PNil, PTuple, PVar,
}
import twocore/backend/core_printer

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
@external(erlang, "twocore_codegen_ffi", "id")
fn raw(term: a) -> Form

/// `erlang:binary_to_atom/2 (utf8)` — the atom for a node tag / atom literal /
/// variable name. Same total contract as `gleam/erlang/atom.create`, typed to
/// this module's private `EAtom` so raw atoms never leak.
@external(erlang, "erlang", "binary_to_atom")
fn atom_of(name: String) -> EAtom

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
  /// A multi-binder `let` whose RHS is not a same-arity literal value list —
  /// `emit_core.value_list` is the single producer, so this is unreachable.
  /// `binders`/`values` are the mismatched arities (`values` is `-1` for a
  /// non-value-list RHS).
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
/// `funs` is a top-level module function (a plain local call).
type Env {
  Env(ln: Int, vars: Dict(String, String), funs: Dict(#(String, Int), LocalFun))
}

/// The fresh-name counter, threaded through the whole translation of one
/// top-level function (each function restarts at 0 — Erlang variables are
/// function-scoped, so cross-function uniqueness is not needed).
type St {
  St(counter: Int)
}

/// Mint a globally-fresh (within the current function) Erlang variable name
/// for the raw Core name `raw_name`: the printer's injective legalization
/// (`V…`) plus an `@<counter>` suffix, so the name is simultaneously legal,
/// traceable to its Core origin, and provably unbound at its binding site.
fn fresh(st: St, raw_name: String) -> #(String, St) {
  #(
    core_printer.legalize_var(raw_name) <> "@" <> int.to_string(st.counter),
    St(st.counter + 1),
  )
}

/// Bind `raw_name` to a fresh Erlang variable: mint the name and extend the
/// environment so later references (and only references made under the
/// returned env — Core scoping) resolve to it.
fn bind_var(env: Env, st: St, raw_name: String) -> #(String, Env, St) {
  let #(name, st2) = fresh(st, raw_name)
  #(name, Env(..env, vars: dict.insert(env.vars, raw_name, name)), st2)
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

fn e_fun(ln: Int, clauses: List(Form)) -> Form {
  raw(#(atom_of("fun"), ln, #(atom_of("clauses"), clauses)))
}

fn e_named_fun(ln: Int, name: String, clauses: List(Form)) -> Form {
  raw(#(atom_of("named_fun"), ln, atom_of(name), clauses))
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
      // legalized name) is defensively deterministic for an unbound
      // reference — erl_lint then reports it as unbound, fail-closed.
      let v = case dict.get(env.vars, name) {
        Ok(n) -> n
        Error(_) -> core_printer.legalize_var(name)
      }
      Ok(#(e_var(ln, v), st))
    }
    CInt(v) -> Ok(#(e_int(ln, v), st))
    CFloat(v) -> Ok(#(e_float(ln, v), st))
    CAtom(name) -> Ok(#(e_atom(ln, name), st))
    CNil -> Ok(#(e_nil(ln), st))
    CCons(head, tail) -> {
      use #(h, st1) <- result.try(tr_expr(head, env, st))
      use #(t, st2) <- result.try(tr_expr(tail, env, st1))
      Ok(#(e_cons(ln, h, t), st2))
    }
    CTuple(elements) -> {
      use #(es, st1) <- result.try(tr_exprs(elements, env, st))
      Ok(#(e_tuple(ln, es), st1))
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
    CValues(values) -> Error(BareValueList(list.length(values)))
    CFun(vars, body) -> {
      let #(params, env2, st1) = bind_params(vars, env, st)
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
    CApplyExpr(op, args) -> {
      use #(opf, st1) <- result.try(tr_expr(op, env, st))
      use #(argfs, st2) <- result.try(tr_exprs(args, env, st1))
      Ok(#(e_call(ln, opf, argfs), st2))
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
    CLet([x], arg, body) -> {
      use #(argf, st1) <- result.try(tr_expr(arg, env, st))
      let #(xn, env2, st2) = bind_var(env, st1, x)
      use #(rest, st3) <- result.try(tr_body(body, env2, st2))
      Ok(#([e_match(ln, e_var(ln, xn), argf), ..rest], st3))
    }
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
    CLet(vars, _, _) -> Error(BadValueBinding(list.length(vars), -1))
    CLetrec(defs, inner) -> tr_letrec(defs, inner, env, st)
    _ -> {
      use #(f, st1) <- result.try(tr_expr(expr, env, st))
      Ok(#([f], st1))
    }
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
      let #(pforms, env3, st2) = bind_params(params, env2, st1)
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
              let #(pforms, env3, stp) = bind_params(params, env2, st0)
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
fn tr_def(def: FunDef, idx: Int) -> Result(Form, EafError) {
  let FunDef(FName(name, arity), value) = def
  case value {
    CFun(params, body) -> {
      let ln = idx + 1
      let env = Env(ln: ln, vars: dict.new(), funs: dict.new())
      let st = St(0)
      let #(pforms, env2, st1) = bind_params(params, env, st)
      use #(bodyf, _st2) <- result.try(tr_body(body, env2, st1))
      Ok(
        raw(
          #(atom_of("function"), ln, atom_of(name), arity, [
            e_clause(ln, pforms, [], bodyf),
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
/// (`twocore_codegen_ffi:compile_forms/1` / the linker's `to_core` entry) —
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
  use defs <- result.try(
    list.index_map(m.defs, fn(def, idx) { #(def, idx) })
    |> list.try_map(fn(pair) { tr_def(pair.0, pair.1) }),
  )
  Ok(list.flatten([[mod_attr, exp_attr], attrs, defs]))
}
