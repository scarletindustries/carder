//// Shape rewrites on a Core-shaped function body before it is printed as
//// Erlang: the same program, spelled the way a person would. Every rewrite
//// here is a local identity that the Erlang compiler would otherwise have to
//// discover itself, so the compiled code is the same or smaller.
////
//// A chain of `case X =:= <literal> of true -> ...; false -> ...` on one
//// variable (how a `switch` on strings arrives) becomes one flat `case X of`
//// with a clause per literal, and a local function called from exactly one
//// place is inlined there.
////
//// The frontends test truth as an i32 (`0` is false, WASM style), which
//// leaves the Erlang full of `T = case X =:= Y of true -> 1; false -> 0 end`
//// followed by `case T of 0 -> ...`. Those pairs become `case X =:= Y of
//// false -> ...; true -> ...`.

import carder/backend/core_erlang.{
  type CClause, type CExpr, type CPat, type FName, CApply, CApplyExpr, CAtom,
  CBinary, CBitSeg, CBytes, CCall, CCase, CClause, CCons, CFun, CFunRef, CInt,
  CLet, CLetrec, CNil, CPrimop, CTry, CTuple, CValues, CVar, FunDef, PAtom,
  PBytes, PCons, PInt, PNil, PTuple, PVar,
}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}

/// Simplify a function body. `uses` is how many times each variable is read
/// in the whole body (`eaf.count_uses`), so a temporary can be folded away
/// only when this is its one read.
pub fn simplify(body: CExpr, uses: Dict(String, #(Int, Int))) -> CExpr {
  go(body, Ctx(uses:, bools: set.new()))
}

/// `uses`: reads per variable (see `simplify`). `bools`: variables bound to
/// an expression that always yields a boolean atom, so `to_boolean(V)` on
/// one of them is `V`.
type Ctx {
  Ctx(uses: Dict(String, #(Int, Int)), bools: Set(String))
}

fn go(e: CExpr, ctx: Ctx) -> CExpr {
  let uses = ctx.uses
  let r = fn(x) { go(x, ctx) }
  case e {
    // to_boolean(V) for a V known to be a boolean is V.
    CCall(CAtom("arc_rt_val_ffi"), CAtom("to_boolean"), [CVar(v)]) ->
      case set.contains(ctx.bools, v) {
        True -> CVar(v)
        False -> e
      }
    CCall(CAtom("arc_rt_val_ffi"), CAtom("to_boolean_i32"), [CVar(v)]) ->
      case set.contains(ctx.bools, v) {
        True ->
          CCase(CVar(v), [
            CClause([PAtom("true")], CAtom("true"), CInt(1)),
            CClause([PAtom("false")], CAtom("true"), CInt(0)),
          ])
        False -> e
      }
    // let T = <i32 truth of B> in ... case T of 0 -> E; _ -> A ...
    //   ==> ... case B of false -> E; true -> A ...
    // where the `case T` is the immediate body, or the RHS of the immediate
    // let, or the scrutinee of a let-case wrap. `T` must have that one read.
    CLet([t], arg, body) -> {
      case empty_test(arg) |> option.then(list_split(t, _, body, uses)) {
        Some(split) -> r(split)
        None -> truth_let(t, arg, body, ctx)
      }
    }
    // case X of <{A, B}> -> {A, B}  ==>  X   (destructure then rebuild)
    CCase(arg, [CClause([PTuple(pats)], CAtom("true"), CTuple(es))]) ->
      case rebuilds(pats, es, uses) {
        True -> r(arg)
        False ->
          CCase(r(arg), [
            CClause([PTuple(pats)], CAtom("true"), CTuple(list.map(es, r))),
          ])
      }
    // case <i32 truth of B> of 0 -> E; _ -> A  (no temp at all)
    CCase(arg, clauses) ->
      flat_switch(case truth_source(arg), zero_test(clauses, uses) {
        Some(cond), Some(#(else_arm, then_arm)) ->
          CCase(r(cond), [
            CClause([PAtom("false")], CAtom("true"), r(else_arm)),
            CClause([PAtom("true")], CAtom("true"), r(then_arm)),
          ])
        _, _ ->
          // case 0 of 0 -> A; _ -> B  ==> A   (a constant scrutinee)
          case arg, clauses {
            CInt(n), [CClause([PInt(m)], CAtom("true"), body), ..] if n == m ->
              r(body)
            CInt(n),
              [
                CClause([PInt(m)], CAtom("true"), _),
                CClause([PVar(_)], CAtom("true"), body),
              ]
              if n != m
            -> r(body)
            _, _ -> CCase(r(arg), list.map(clauses, clause(_, ctx)))
          }
      })
    CLet(vars, arg, body) -> CLet(vars, r(arg), r(body))
    // letrec 'j'/n = fun (Ps) -> B in ... apply 'j'/n(As) ...
    //   ==> ... let <Ps> = <As> in B ...   (the one call, not inside a try)
    // Only a small B: a big one is usually the rest of the function, and
    // moving it into a deep branch only buries it further to the right.
    CLetrec([FunDef(name, CFun(params, fbody))], body) ->
      case
        calls(fbody, name, 0, False),
        calls(body, name, 0, False),
        size(fbody, 0) <= inline_limit
      {
        0, 1, True -> r(inline_call(body, name, params, fbody))
        _, _, _ -> CLetrec([FunDef(name, CFun(params, r(fbody)))], r(body))
      }
    CLetrec(defs, body) ->
      CLetrec(
        list.map(defs, fn(d) {
          let FunDef(name, value) = d
          FunDef(name, r(value))
        }),
        r(body),
      )
    CFun(vars, body) -> CFun(vars, r(body))
    CTry(arg, bv, body, ev, handler) ->
      CTry(r(arg), bv, r(body), ev, r(handler))
    CApply(name, args) -> CApply(name, list.map(args, r))
    CApplyExpr(op, args) -> CApplyExpr(r(op), list.map(args, r))
    CCall(m, f, args) -> CCall(r(m), r(f), list.map(args, r))
    CPrimop(name, args) -> CPrimop(name, list.map(args, r))
    CTuple(es) -> CTuple(list.map(es, r))
    CValues(es) -> CValues(list.map(es, r))
    CCons(h, t) -> CCons(r(h), r(t))
    CBinary(segs) ->
      CBinary(
        list.map(segs, fn(s) {
          let CBitSeg(value, size, unit, ty, flags) = s
          CBitSeg(r(value), r(size), unit, ty, flags)
        }),
      )
    CVar(_)
    | CInt(_)
    | core_erlang.CFloat(_)
    | CAtom(_)
    | core_erlang.CNil
    | core_erlang.CBytes(_)
    | CFunRef(_) -> e
  }
}

/// `let t = arg in body` where `case t` may be an i32 truth test to turn
/// into a boolean one (see `rewrite_test`).
fn truth_let(t: String, arg: CExpr, body: CExpr, ctx: Ctx) -> CExpr {
  let uses = ctx.uses
  let r = fn(x) { go(x, ctx) }
  case read_once(uses, t), truth_source(arg) {
    True, Some(cond) ->
      case rewrite_test(body, t, cond, uses) {
        Some(rewritten) -> r(rewritten)
        None -> let1(t, arg, body, ctx)
      }
    _, _ -> let1(t, arg, body, ctx)
  }
}

/// `let t = arg in body`, simplifying `arg` first and recording `t` as a
/// known boolean for `body` when the simplified `arg` yields one.
fn let1(t: String, arg: CExpr, body: CExpr, ctx: Ctx) -> CExpr {
  let arg2 = go(arg, ctx)
  let ctx2 = case is_boolean(arg2, ctx) {
    True -> Ctx(..ctx, bools: set.insert(ctx.bools, t))
    False -> ctx
  }
  CLet([t], arg2, go(body, ctx2))
}

/// An expression that always yields a boolean atom.
fn is_boolean(e: CExpr, ctx: Ctx) -> Bool {
  case e {
    CAtom("true") | CAtom("false") -> True
    CVar(v) -> set.contains(ctx.bools, v)
    CCall(CAtom("arc_rt_val_ffi"), CAtom("to_boolean"), [_]) -> True
    CCall(CAtom("erlang"), CAtom("not"), [_]) -> True
    CCall(CAtom("erlang"), CAtom(f), [_]) -> list.contains(type_tests, f)
    CCall(CAtom("erlang"), CAtom(f), [_, _]) -> list.contains(compare_ops, f)
    CCase(_, clauses) ->
      list.all(clauses, fn(cl) {
        let CClause(_, _, body) = cl
        is_boolean(body, ctx)
      })
    _ -> False
  }
}

const type_tests = [
  "is_integer", "is_float", "is_number", "is_atom", "is_binary", "is_tuple",
  "is_map", "is_function", "is_list", "is_boolean",
]

const compare_ops = ["<", "=<", ">", ">=", "=:=", "=/=", "==", "/="]

fn clause(cl: CClause, ctx: Ctx) -> CClause {
  let CClause(pats, guard, body) = cl
  CClause(pats, go(guard, ctx), go(body, ctx))
}

/// The pattern binds fresh variables that the tuple rebuilds in the same
/// order, each read only there.
fn rebuilds(
  pats: List(CPat),
  es: List(CExpr),
  uses: Dict(String, #(Int, Int)),
) -> Bool {
  list.length(pats) == list.length(es)
  && list.zip(pats, es)
  |> list.all(fn(pair) {
    case pair {
      #(PVar(a), CVar(b)) -> a == b && read_once(uses, a)
      _ -> False
    }
  })
}

fn read_once(uses: Dict(String, #(Int, Int)), x: String) -> Bool {
  case dict.get(uses, x) {
    Ok(#(1, _)) -> True
    _ -> False
  }
}

/// The one read of `t` in `body` turned from a zero test into a boolean
/// test on `cond`, when it sits where the emitter puts it: `body` is the
/// `case t`, or `let vars = case t in rest`, or `case (case t) of ...`.
fn rewrite_test(
  body: CExpr,
  t: String,
  cond: CExpr,
  uses: Dict(String, #(Int, Int)),
) -> Option(CExpr) {
  case body {
    CCase(CVar(t2), clauses) if t2 == t ->
      option.map(zero_test(clauses, uses), fn(arms) { bool_case(cond, arms) })
    CLet(vars, CCase(CVar(t2), clauses), rest) if t2 == t ->
      option.map(zero_test(clauses, uses), fn(arms) {
        CLet(vars, bool_case(cond, arms), rest)
      })
    CCase(CCase(CVar(t2), clauses), outer) if t2 == t ->
      option.map(zero_test(clauses, uses), fn(arms) {
        CCase(bool_case(cond, arms), outer)
      })
    // let U = case T of 0 -> false; _ -> true in rest  ==>  let U = B in rest
    CLet([u], CCase(CVar(t2), clauses), rest) if t2 == t ->
      case bool_of_zero_test(clauses, uses) {
        Some(True) -> Some(CLet([u], cond, rest))
        Some(False) -> Some(CLet([u], bool_not(cond), rest))
        None -> None
      }
    // case T =:= 0 of true -> E; false -> A  ==>  case B of false -> E; true -> A
    CCase(
      CCall(CAtom("erlang"), CAtom("=:="), [CVar(t2), CInt(0)]),
      [
        CClause([PAtom("true")], CAtom("true"), e),
        CClause([PAtom("false")], CAtom("true"), a),
      ],
    )
      if t2 == t
    -> Some(bool_case(cond, #(e, a)))
    CLet(
      vars,
      CCase(
        CCall(CAtom("erlang"), CAtom("=:="), [CVar(t2), CInt(0)]),
        [
          CClause([PAtom("true")], CAtom("true"), e),
          CClause([PAtom("false")], CAtom("true"), a),
        ],
      ),
      rest,
    )
      if t2 == t
    -> Some(CLet(vars, bool_case(cond, #(e, a)), rest))
    _ -> None
  }
}

/// `Some(True)` for `0 -> false; _ -> true`, `Some(False)` for the negation,
/// with the catch-all variable unread.
fn bool_of_zero_test(
  clauses: List(CClause),
  uses: Dict(String, #(Int, Int)),
) -> Option(Bool) {
  case zero_test(clauses, uses) {
    Some(#(CAtom("false"), CAtom("true"))) -> Some(True)
    Some(#(CAtom("true"), CAtom("false"))) -> Some(False)
    _ -> None
  }
}

fn bool_not(b: CExpr) -> CExpr {
  CCall(CAtom("erlang"), CAtom("not"), [b])
}

fn bool_case(cond: CExpr, arms: #(CExpr, CExpr)) -> CExpr {
  let #(else_arm, then_arm) = arms
  CCase(cond, [
    CClause([PAtom("false")], CAtom("true"), else_arm),
    CClause([PAtom("true")], CAtom("true"), then_arm),
  ])
}

/// `Some(B)` when `e` is an i32 truth value computed from a boolean `B`:
/// `case B of true -> 1; false -> 0` (either clause order), or a JS
/// truthiness kernel call `arc_rt_val_ffi:to_boolean_i32(X)`, which has a
/// boolean twin `to_boolean/1`.
fn truth_source(e: CExpr) -> Option(CExpr) {
  case e {
    CCase(
      b,
      [
        CClause([PAtom("true")], CAtom("true"), CInt(1)),
        CClause([PAtom("false")], CAtom("true"), CInt(0)),
      ],
    )
    | CCase(
        b,
        [
          CClause([PAtom("false")], CAtom("true"), CInt(0)),
          CClause([PAtom("true")], CAtom("true"), CInt(1)),
        ],
      ) -> Some(b)
    // case B of true -> 1; false -> <truth of C>  ==>  B orelse C
    // case B of true -> <truth of C>; false -> 0  ==>  B andalso C
    CCase(
      b,
      [
        CClause([PAtom("true")], CAtom("true"), CInt(1)),
        CClause([PAtom("false")], CAtom("true"), rest),
      ],
    )
    | CCase(
        b,
        [
          CClause([PAtom("false")], CAtom("true"), rest),
          CClause([PAtom("true")], CAtom("true"), CInt(1)),
        ],
      ) -> option.map(truth_source(rest), fn(c) { bool_or(b, c) })
    CCase(
      b,
      [
        CClause([PAtom("true")], CAtom("true"), rest),
        CClause([PAtom("false")], CAtom("true"), CInt(0)),
      ],
    )
    | CCase(
        b,
        [
          CClause([PAtom("false")], CAtom("true"), CInt(0)),
          CClause([PAtom("true")], CAtom("true"), rest),
        ],
      ) -> option.map(truth_source(rest), fn(c) { bool_and(b, c) })
    CCall(CAtom("arc_rt_val_ffi"), CAtom("to_boolean_i32"), [x]) ->
      Some(CCall(CAtom("arc_rt_val_ffi"), CAtom("to_boolean"), [x]))
    _ -> None
  }
}

/// `b orelse c`, in the Core shape `eaf.short_circuit` prints as the operator.
fn bool_or(b: CExpr, c: CExpr) -> CExpr {
  case c {
    CAtom("false") -> b
    _ ->
      CCase(b, [
        CClause([PAtom("true")], CAtom("true"), CAtom("true")),
        CClause([PAtom("false")], CAtom("true"), c),
      ])
  }
}

fn bool_and(b: CExpr, c: CExpr) -> CExpr {
  case c {
    CAtom("true") -> b
    _ ->
      CCase(b, [
        CClause([PAtom("true")], CAtom("true"), c),
        CClause([PAtom("false")], CAtom("true"), CAtom("false")),
      ])
  }
}

/// `Some(#(else, then))` when `clauses` test an i32 for zero: `0 -> else`
/// and a catch-all `V -> then` (either order) whose `V` the arm never reads,
/// so dropping the binding changes nothing.
fn zero_test(
  clauses: List(CClause),
  uses: Dict(String, #(Int, Int)),
) -> Option(#(CExpr, CExpr)) {
  case clauses {
    [CClause([PInt(0)], CAtom("true"), e), CClause([PVar(v)], CAtom("true"), t)]
    | [
        CClause([PVar(v)], CAtom("true"), t),
        CClause([PInt(0)], CAtom("true"), e),
      ] ->
      case dict.has_key(uses, v) {
        True -> None
        False -> Some(#(e, t))
      }
    _ -> None
  }
}

/// `case X =:= L1 of true -> A1; false -> case X =:= L2 of ... end` (two or
/// more literal tests on the same variable) ==> `case X of L1 -> A1; L2 ->
/// ...; _ -> Default`. `=:=` against a literal is exactly what matching the
/// literal pattern tests, and the first matching clause wins in both.
fn flat_switch(e: CExpr) -> CExpr {
  case literal_test(e) {
    Some(#(x, pat, hit, miss)) ->
      case switch_clauses(miss, x) {
        Some(rest) ->
          CCase(CVar(x), [CClause([pat], CAtom("true"), hit), ..rest])
        None -> e
      }
    None -> e
  }
}

/// The clauses of `e` as a flat switch on `x`: either a single literal test
/// on `x`, or an already flattened `case x of`.
fn switch_clauses(e: CExpr, x: String) -> Option(List(CClause)) {
  case literal_test(e), e {
    Some(#(x2, pat, hit, miss)), _ if x2 == x ->
      Some([
        CClause([pat], CAtom("true"), hit),
        CClause([PVar(wildcard)], CAtom("true"), miss),
      ])
    _, CCase(CVar(x2), [_, _, ..] as clauses) if x2 == x ->
      case is_flat_switch(clauses) {
        True -> Some(clauses)
        False -> None
      }
    _, _ -> None
  }
}

/// Literal clauses ending in the catch-all `flat_switch` adds.
fn is_flat_switch(clauses: List(CClause)) -> Bool {
  case clauses {
    [CClause([PVar(w)], CAtom("true"), _)] -> w == wildcard
    [CClause([PBytes(_)], CAtom("true"), _), ..rest]
    | [CClause([PAtom(_)], CAtom("true"), _), ..rest]
    | [CClause([PInt(_)], CAtom("true"), _), ..rest] -> is_flat_switch(rest)
    _ -> False
  }
}

/// emit_core's never-read binder name (printed `_W`).
const wildcard = "w"

/// `Some(#(x, L, hit, miss))` for `case X =:= L of true -> hit; false ->
/// miss` (either clause order, either operand order) with `L` a literal
/// that has a pattern form.
fn literal_test(e: CExpr) -> Option(#(String, CPat, CExpr, CExpr)) {
  case e {
    CCase(
      CCall(CAtom("erlang"), CAtom("=:="), [a, b]),
      [
        CClause([PAtom(t1)], CAtom("true"), arm1),
        CClause([PAtom(t2)], CAtom("true"), arm2),
      ],
    ) -> {
      let arms = case t1, t2 {
        "true", "false" -> Some(#(arm1, arm2))
        "false", "true" -> Some(#(arm2, arm1))
        _, _ -> None
      }
      let operands = case a, literal_pat(b), literal_pat(a), b {
        CVar(x), Some(pat), _, _ -> Some(#(x, pat))
        _, _, Some(pat), CVar(x) -> Some(#(x, pat))
        _, _, _, _ -> None
      }
      case arms, operands {
        Some(#(hit, miss)), Some(#(x, pat)) -> Some(#(x, pat, hit, miss))
        _, _ -> None
      }
    }
    _ -> None
  }
}

fn literal_pat(e: CExpr) -> Option(CPat) {
  case e {
    CBytes(b) -> Some(PBytes(b))
    CAtom(a) -> Some(PAtom(a))
    CInt(n) -> Some(PInt(n))
    _ -> None
  }
}

/// How many times `e` applies `f`. A call inside a `try`, or any use of `f`
/// as a value, counts as many so the caller leaves `f` alone: inlining into
/// a `try` would put `f`'s body under its handler.
fn calls(e: CExpr, f: FName, n: Int, in_try: Bool) -> Int {
  let go = fn(acc, x) { calls(x, f, acc, in_try) }
  case e {
    CApply(g, args) if g == f ->
      case in_try {
        True -> 2
        False -> list.fold(args, n + 1, go)
      }
    CFunRef(g) if g == f -> 2
    CApply(_, args) | CPrimop(_, args) | CTuple(args) | CValues(args) ->
      list.fold(args, n, go)
    CApplyExpr(op, args) -> list.fold(args, go(n, op), go)
    CCall(m, fun, args) -> list.fold(args, go(go(n, m), fun), go)
    CCons(h, t) -> go(go(n, h), t)
    CBinary(segs) ->
      list.fold(segs, n, fn(acc, s) { go(go(acc, s.value), s.size) })
    CFun(_, body) -> go(n, body)
    CLet(_, arg, body) -> go(go(n, arg), body)
    CLetrec(defs, body) ->
      list.fold(defs, go(n, body), fn(acc, d) { go(acc, d.value) })
    CCase(arg, clauses) ->
      list.fold(clauses, go(n, arg), fn(acc, cl) {
        go(go(acc, cl.guard), cl.body)
      })
    CTry(arg, _, body, _, handler) ->
      calls(handler, f, calls(body, f, calls(arg, f, n, True), True), True)
    CVar(_)
    | CInt(_)
    | core_erlang.CFloat(_)
    | CAtom(_)
    | core_erlang.CNil
    | CBytes(_)
    | CFunRef(_) -> n
  }
}

/// `let P1 = A1 in ... body`, with a variable or literal argument put
/// straight in place of its parameter (names are unique, so nothing in
/// `body` rebinds one).
fn bind_params(
  params: List(String),
  args: List(CExpr),
  body: CExpr,
  sub: Dict(String, CExpr),
) -> CExpr {
  case params, args {
    [p, ..ps], [a, ..as_] ->
      case a {
        CVar(_) | CInt(_) | CAtom(_) | core_erlang.CNil | CBytes(_) ->
          bind_params(ps, as_, body, dict.insert(sub, p, a))
        _ -> CLet([p], a, bind_params(ps, as_, body, sub))
      }
    _, _ ->
      case dict.is_empty(sub) {
        True -> body
        False -> substitute(body, sub)
      }
  }
}

/// `e` with each variable in `sub` replaced by its expression.
fn substitute(e: CExpr, sub: Dict(String, CExpr)) -> CExpr {
  let r = fn(x) { substitute(x, sub) }
  case e {
    CVar(v) -> dict.get(sub, v) |> result.unwrap(e)
    CApply(g, args) -> CApply(g, list.map(args, r))
    CPrimop(name, args) -> CPrimop(name, list.map(args, r))
    CTuple(es) -> CTuple(list.map(es, r))
    CValues(es) -> CValues(list.map(es, r))
    CApplyExpr(op, args) -> CApplyExpr(r(op), list.map(args, r))
    CCall(m, fun, args) -> CCall(r(m), r(fun), list.map(args, r))
    CCons(h, t) -> CCons(r(h), r(t))
    CBinary(segs) ->
      CBinary(
        list.map(segs, fn(s) {
          let CBitSeg(value, size, unit, ty, flags) = s
          CBitSeg(r(value), r(size), unit, ty, flags)
        }),
      )
    CFun(vars, b) -> CFun(vars, r(b))
    CLet(vars, arg, b) -> CLet(vars, r(arg), r(b))
    CLetrec(defs, b) ->
      CLetrec(
        list.map(defs, fn(d) {
          let FunDef(name, value) = d
          FunDef(name, r(value))
        }),
        r(b),
      )
    CCase(arg, clauses) ->
      CCase(
        r(arg),
        list.map(clauses, fn(cl) {
          let CClause(pats, guard, b) = cl
          CClause(pats, r(guard), r(b))
        }),
      )
    CTry(arg, bv, b, ev, handler) -> CTry(r(arg), bv, r(b), ev, r(handler))
    CInt(_)
    | core_erlang.CFloat(_)
    | CAtom(_)
    | core_erlang.CNil
    | CBytes(_)
    | CFunRef(_) -> e
  }
}

/// `e` with its one `apply f(As)` replaced by `let <Ps> = <As> in body`.
fn inline_call(e: CExpr, f: FName, params: List(String), body: CExpr) -> CExpr {
  let r = fn(x) { inline_call(x, f, params, body) }
  case e {
    CApply(g, args) if g == f -> bind_params(params, args, body, dict.new())
    CApply(g, args) -> CApply(g, list.map(args, r))
    CPrimop(name, args) -> CPrimop(name, list.map(args, r))
    CTuple(es) -> CTuple(list.map(es, r))
    CValues(es) -> CValues(list.map(es, r))
    CApplyExpr(op, args) -> CApplyExpr(r(op), list.map(args, r))
    CCall(m, fun, args) -> CCall(r(m), r(fun), list.map(args, r))
    CCons(h, t) -> CCons(r(h), r(t))
    CBinary(segs) ->
      CBinary(
        list.map(segs, fn(s) {
          let CBitSeg(value, size, unit, ty, flags) = s
          CBitSeg(r(value), r(size), unit, ty, flags)
        }),
      )
    CFun(vars, b) -> CFun(vars, r(b))
    CLet(vars, arg, b) -> CLet(vars, r(arg), r(b))
    CLetrec(defs, b) ->
      CLetrec(
        list.map(defs, fn(d) {
          let FunDef(name, value) = d
          FunDef(name, r(value))
        }),
        r(b),
      )
    CCase(arg, clauses) ->
      CCase(
        r(arg),
        list.map(clauses, fn(cl) {
          let CClause(pats, guard, b) = cl
          CClause(pats, r(guard), r(b))
        }),
      )
    CTry(arg, bv, b, ev, handler) -> CTry(r(arg), bv, r(b), ev, r(handler))
    CVar(_)
    | CInt(_)
    | core_erlang.CFloat(_)
    | CAtom(_)
    | core_erlang.CNil
    | CBytes(_)
    | CFunRef(_) -> e
  }
}

/// Node budget for inlining a local function's body at its one call.
const inline_limit = 40

/// Expression nodes in `e`, counting stops once past `inline_limit`.
fn size(e: CExpr, n: Int) -> Int {
  let go = fn(acc, x) {
    case acc > inline_limit {
      True -> acc
      False -> size(x, acc)
    }
  }
  let n = n + 1
  case e {
    CApply(_, args) | CPrimop(_, args) | CTuple(args) | CValues(args) ->
      list.fold(args, n, go)
    CApplyExpr(op, args) -> list.fold(args, go(n, op), go)
    CCall(m, fun, args) -> list.fold(args, go(go(n, m), fun), go)
    CCons(h, t) -> go(go(n, h), t)
    CBinary(segs) -> list.fold(segs, n, fn(acc, s) { go(acc, s.value) })
    CFun(_, body) -> go(n, body)
    CLet(_, arg, body) -> go(go(n, arg), body)
    CLetrec(defs, body) ->
      list.fold(defs, go(n, body), fn(acc, d) { go(acc, d.value) })
    CCase(arg, clauses) ->
      list.fold(clauses, go(n, arg), fn(acc, cl) {
        go(go(acc, cl.guard), cl.body)
      })
    CTry(arg, _, body, _, handler) -> go(go(go(n, arg), body), handler)
    CVar(_)
    | CInt(_)
    | core_erlang.CFloat(_)
    | CAtom(_)
    | core_erlang.CNil
    | CBytes(_)
    | CFunRef(_) -> n
  }
}

/// `Some(x)` for emit_core's list emptiness test `case X of [] -> 1; W -> 0`.
fn empty_test(e: CExpr) -> Option(String) {
  case e {
    CCase(
      CVar(x),
      [
        CClause([PNil], CAtom("true"), CInt(1)),
        CClause([PVar(_)], CAtom("true"), CInt(0)),
      ],
    ) -> Some(x)
    _ -> None
  }
}

/// `let t = <X is []> in body` where `body` only uses `t` to pick `hd(X)` /
/// `tl(X)` or a fallback, rewritten as one match on `[H | T]` / `[]`:
///
/// - `case t of 0 -> let H = hd(X) in let T = tl(X) in E; _ -> A`
///   ==> `case X of [H | T] -> E; [] -> A`
/// - `let A = case t of 0 -> hd(X); _ -> D in let B = case t of 0 -> tl(X);
///   _ -> X in rest`
///   ==> `let <A, B> = case X of [Hd | Tl] -> <Hd, Tl>; [] -> <D, []> in rest`
///
/// A non-list `X` fails a `case_clause` here where `hd` failed `badarg`.
fn list_split(
  t: String,
  x: String,
  body: CExpr,
  uses: Dict(String, #(Int, Int)),
) -> Option(CExpr) {
  let reads = dict.get(uses, t) |> result.map(fn(u) { u.0 }) |> result.unwrap(0)
  split_pair(t, x, body, reads, uses)
  |> option.lazy_or(fn() { split_head(t, x, body, reads, uses) })
  |> option.lazy_or(fn() { split_branch(t, x, body, reads, uses) })
}

/// `let A = case t of 0 -> hd(X); _ -> D in let B = case t of 0 -> tl(X);
/// _ -> X in rest`
fn split_pair(
  t: String,
  x: String,
  body: CExpr,
  reads: Int,
  uses: Dict(String, #(Int, Int)),
) -> Option(CExpr) {
  case body {
    CLet(
      [a],
      CCase(CVar(t2), hd_clauses),
      CLet([b], CCase(CVar(t3), tl_clauses), rest),
    )
      if t2 == t && t3 == t && reads == 2
    ->
      case zero_test(hd_clauses, uses), zero_test(tl_clauses, uses) {
        Some(#(CCall(CAtom("erlang"), CAtom("hd"), [CVar(x1)]), default)),
          Some(#(CCall(CAtom("erlang"), CAtom("tl"), [CVar(x2)]), CVar(x3)))
          if x1 == x && x2 == x && x3 == x
        ->
          Some(CLet(
            [a, b],
            CCase(CVar(x), [
              CClause(
                [PCons(PVar(head_var), PVar(tail_var))],
                CAtom("true"),
                CValues([CVar(head_var), CVar(tail_var)]),
              ),
              CClause([PNil], CAtom("true"), CValues([default, CNil])),
            ]),
            rest,
          ))
        _, _ -> None
      }
    _ -> None
  }
}

/// `let A = case t of 0 -> hd(X); _ -> D in rest` (the tail is not needed)
fn split_head(
  t: String,
  x: String,
  body: CExpr,
  reads: Int,
  uses: Dict(String, #(Int, Int)),
) -> Option(CExpr) {
  case body {
    CLet([a], CCase(CVar(t2), hd_clauses), rest) if t2 == t && reads == 1 ->
      case zero_test(hd_clauses, uses) {
        Some(#(CCall(CAtom("erlang"), CAtom("hd"), [CVar(x1)]), default))
          if x1 == x
        ->
          Some(CLet(
            [a],
            CCase(CVar(x), [
              CClause(
                [PCons(PVar(head_var), PVar(tail_wildcard))],
                CAtom("true"),
                CVar(head_var),
              ),
              CClause([PNil], CAtom("true"), default),
            ]),
            rest,
          ))
        _ -> None
      }
    _ -> None
  }
}

/// `case t of 0 -> let H = hd(X) in let T = tl(X) in E; _ -> A`, directly
/// or as the right-hand side of a `let`.
fn split_branch(
  t: String,
  x: String,
  body: CExpr,
  reads: Int,
  uses: Dict(String, #(Int, Int)),
) -> Option(CExpr) {
  case body {
    CCase(CVar(t2), clauses) if t2 == t && reads == 1 ->
      zero_test(clauses, uses)
      |> option.then(fn(arms) { split_case(x, arms.0, arms.1, fn(e) { e }) })
    CLet(vars, CCase(CVar(t2), clauses), rest) if t2 == t && reads == 1 ->
      zero_test(clauses, uses)
      |> option.then(fn(arms) {
        split_case(x, arms.0, arms.1, fn(e) { CLet(vars, e, rest) })
      })
    _ -> None
  }
}

/// `case X of [H | T] -> nonempty; [] -> empty`, taking `H` / `T` from the
/// leading `let H = hd(X)` / `let T = tl(X)` of `nonempty`. `None` when
/// `nonempty` still reads `hd(X)` / `tl(X)` without such a binding.
fn split_case(
  x: String,
  nonempty: CExpr,
  empty: CExpr,
  wrap: fn(CExpr) -> CExpr,
) -> Option(CExpr) {
  let #(h, tl, rest) = leading_split(nonempty, x, None, None)
  let sub =
    [#("hd", h), #("tl", tl)]
    |> list.filter_map(fn(p) {
      option.map(p.1, fn(v) { #(p.0, CVar(v)) }) |> option.to_result(Nil)
    })
    |> dict.from_list
  let rest = replace_list_ops(rest, x, sub)
  case reads_list_op(rest, x) {
    True -> None
    False ->
      Some(
        wrap(
          CCase(CVar(x), [
            CClause(
              [
                PCons(
                  PVar(option.unwrap(h, head_wildcard)),
                  PVar(option.unwrap(tl, tail_wildcard)),
                ),
              ],
              CAtom("true"),
              rest,
            ),
            CClause([PNil], CAtom("true"), empty),
          ]),
        ),
      )
  }
}

/// Peel `let H = hd(X)` / `let T = tl(X)` off the front of `e`.
fn leading_split(
  e: CExpr,
  x: String,
  h: Option(String),
  tl: Option(String),
) -> #(Option(String), Option(String), CExpr) {
  case e, h, tl {
    CLet([v], CCall(CAtom("erlang"), CAtom("hd"), [CVar(x2)]), body), None, _
      if x2 == x
    -> leading_split(body, x, Some(v), tl)
    CLet([v], CCall(CAtom("erlang"), CAtom("tl"), [CVar(x2)]), body), _, None
      if x2 == x
    -> leading_split(body, x, h, Some(v))
    _, _, _ -> #(h, tl, e)
  }
}

/// `e` with `hd(X)` / `tl(X)` replaced from `sub` (keyed `"hd"` / `"tl"`).
fn replace_list_ops(e: CExpr, x: String, sub: Dict(String, CExpr)) -> CExpr {
  case dict.is_empty(sub) {
    True -> e
    False ->
      map_expr(e, fn(n) {
        case n {
          CCall(CAtom("erlang"), CAtom(f), [CVar(x2)]) if x2 == x ->
            dict.get(sub, f) |> result.unwrap(n)
          _ -> n
        }
      })
  }
}

fn reads_list_op(e: CExpr, x: String) -> Bool {
  let found =
    map_expr(e, fn(n) {
      case n {
        CCall(CAtom("erlang"), CAtom("hd"), [CVar(x2)])
          | CCall(CAtom("erlang"), CAtom("tl"), [CVar(x2)])
          if x2 == x
        -> CAtom(list_op_marker)
        _ -> n
      }
    })
  found != e
}

const list_op_marker = "$list_op"

/// Pattern variables minted by `list_split` (printed `Hd`, `Tl`, `_W`).
const head_var = "hd_0"

const tail_var = "tl_0"

const head_wildcard = "w_0"

const tail_wildcard = "w_1"

/// `e` rebuilt bottom-up with `f` applied to every node.
fn map_expr(e: CExpr, f: fn(CExpr) -> CExpr) -> CExpr {
  let r = fn(x) { map_expr(x, f) }
  f(case e {
    CApply(g, args) -> CApply(g, list.map(args, r))
    CPrimop(name, args) -> CPrimop(name, list.map(args, r))
    CTuple(es) -> CTuple(list.map(es, r))
    CValues(es) -> CValues(list.map(es, r))
    CApplyExpr(op, args) -> CApplyExpr(r(op), list.map(args, r))
    CCall(m, fun, args) -> CCall(r(m), r(fun), list.map(args, r))
    CCons(h, t) -> CCons(r(h), r(t))
    CBinary(segs) ->
      CBinary(
        list.map(segs, fn(s) {
          let CBitSeg(value, size, unit, ty, flags) = s
          CBitSeg(r(value), r(size), unit, ty, flags)
        }),
      )
    CFun(vars, b) -> CFun(vars, r(b))
    CLet(vars, arg, b) -> CLet(vars, r(arg), r(b))
    CLetrec(defs, b) ->
      CLetrec(
        list.map(defs, fn(d) {
          let FunDef(name, value) = d
          FunDef(name, r(value))
        }),
        r(b),
      )
    CCase(arg, clauses) ->
      CCase(
        r(arg),
        list.map(clauses, fn(cl) {
          let CClause(pats, guard, b) = cl
          CClause(pats, r(guard), r(b))
        }),
      )
    CTry(arg, bv, b, ev, handler) -> CTry(r(arg), bv, r(b), ev, r(handler))
    CVar(_)
    | CInt(_)
    | core_erlang.CFloat(_)
    | CAtom(_)
    | CNil
    | CBytes(_)
    | CFunRef(_) -> e
  })
}
