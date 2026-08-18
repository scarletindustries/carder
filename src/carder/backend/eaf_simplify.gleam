//// Shape rewrites on a Core-shaped function body before it is printed as
//// Erlang: the same program, spelled the way a person would. Every rewrite
//// here is a local identity that the Erlang compiler would otherwise have to
//// discover itself, so the compiled code is the same or smaller.
////
//// The frontends test truth as an i32 (`0` is false, WASM style), which
//// leaves the Erlang full of `T = case X =:= Y of true -> 1; false -> 0 end`
//// followed by `case T of 0 -> ...`. Those pairs become `case X =:= Y of
//// false -> ...; true -> ...`.

import carder/backend/core_erlang.{
  type CClause, type CExpr, type CPat, CApply, CApplyExpr, CAtom, CBinary,
  CBitSeg, CCall, CCase, CClause, CCons, CFun, CFunRef, CInt, CLet, CLetrec,
  CPrimop, CTry, CTuple, CValues, CVar, FunDef, PAtom, PInt, PTuple, PVar,
}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
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
      case read_once(uses, t), truth_source(arg) {
        True, Some(cond) ->
          case rewrite_test(body, t, cond, uses) {
            Some(rewritten) -> r(rewritten)
            None -> let1(t, arg, body, ctx)
          }
        _, _ -> let1(t, arg, body, ctx)
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
      case truth_source(arg), zero_test(clauses, uses) {
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
      }
    CLet(vars, arg, body) -> CLet(vars, r(arg), r(body))
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
