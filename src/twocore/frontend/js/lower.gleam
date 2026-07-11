//// `twocore/frontend/js/lower` — lower an arc JavaScript AST to a 2core IR module.
////
//// This is the middle of a JS AOT compiler: arc parses JS → this lowers the AST to
//// `twocore/ir` → 2core's backend emits native BEAM. JS values are **native BEAM
//// terms** (numbers as int/float, strings as binaries, booleans/null/undefined as
//// atoms, objects as `rt_js` refs), so arithmetic runs on `erlang:'+'` etc.
////
//// SPEED: every polymorphic operator compiles to a GUARDED dispatch —
//// `if IsNumber(a) && IsNumber(b) then NumTerm(native +) else CallHost("js",op)` —
//// so hot numeric code is native BEAM arithmetic and only non-number operands take
//// the `rt_js` cold path (real JS concat/coercion/NaN). Benchmarks put this ~20×
//// over an interpreter with the guards essentially free (BEAM's JIT specialises the
//// guarded arithmetic).
////
//// Supported subset (v1): top-level `function` declarations (recursion, mutual
//// recursion, calls); number/string/boolean/null/undefined/template literals;
//// `+ - * / %`, all comparisons, `&& || !`, bitwise/shift `& | ^ ~ << >> >>>`, unary
//// `- + ! ~ typeof void`, `?:`; `let/const/var`, `= += -= *= /= %= &= |= ^= <<= >>=
//// >>>=`, and `++`/`--`; `if/else`, `while`, `do/while`, `for`, `break/continue`,
//// `return`, blocks; objects `{}` with `.prop`/`[k]` get/set; `console.log`. Control
//// flow threads mutated variables as loop-carried params / phi-merged `If` results.
////
//// Not yet (a clean `Unsupported` error / panic): first-class functions & closures,
//// arrays, classes, `try/catch/throw`, `switch`, `for-in/of`, regex, and `continue`
//// inside a `do/while`. Scope is one flat function scope per JS function (block-scoped
//// `let` is treated as function-scoped).
////
//// Known v1 deviations from the spec (intentional, for speed / simplicity):
////   * Integers are native BEAM integers, so `+ - *` on values beyond 2^53 stay exact
////     (arbitrary precision) instead of rounding to the nearest IEEE-754 double. Within
////     the safe-integer range results match JS exactly; this is the price of native
////     arithmetic. (`/ %` always take the `rt_js` double path.)
////   * An assignment that is NOT the outermost expression of a statement (nor a direct
////     `x = y = e` chain) — e.g. `f(x = 1)`, `(x = 1) + 1`, `while ((l = next()) != null)`
////     — computes the right value but does not rebind its target in the env, so a later
////     read of that target sees the old value. Top-level and chained assignments are fine.
////   * A POSTFIX `x++`/`x--` yields the NEW value (not the pre-increment value) when its
////     result is used inside a larger expression. As a statement or a `for` update — where
////     the value is discarded — it is exact.

import arc/parser/ast
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import twocore/ir

/// A lowering failure for unsupported syntax.
pub type Error {
  Unsupported(what: String)
}

/// JS variable name → its current IR `Value` (SSA binding).
type Env =
  Dict(String, ir.Value)

/// The enclosing loop (for `break`/`continue`): its IR label, the ordered set of
/// loop-carried variable names (so a transfer re-supplies them), the `for`-loop
/// update expression that a `continue` must run before looping (`None` for
/// `while`/`do-while`), and whether it is a `do-while` (whose back-edge re-tests the
/// condition, which our top-of-loop model can't express for an explicit `continue`).
type Loop {
  Loop(
    label: String,
    carried: List(String),
    update: Option(ast.Expression),
    do_while: Bool,
  )
}

/// Ordered `Let` bindings to emit around a continuation, in evaluation order.
type Bind =
  #(String, ir.Expr)

/// Immutable per-function context: the set of top-level function names (a call to
/// one is a `CallDirect`) and the current loop, if any.
type Ctx {
  Ctx(funcs: List(String), loop: Option(Loop))
}

// ── entry ───────────────────────────────────────────────────────────────────

/// Lower a parsed JS program to an IR module named `module_name`. Each top-level
/// `function` declaration becomes an exported IR function; the remaining top-level
/// statements become an exported `main/0`.
pub fn program(
  program: ast.Program,
  module_name: String,
) -> Result(ir.Module, Error) {
  let stmts = case program {
    ast.Script(body:) -> list.map(body, fn(w) { w.statement })
    ast.Module(..) -> []
  }
  let decls = list.filter_map(stmts, as_function_decl)
  let fn_names = list.map(decls, fn(d) { d.0 })
  let top = list.filter(stmts, fn(s) { as_function_decl(s) == Error(Nil) })
  let ctx = Ctx(funcs: fn_names, loop: None)

  use funcs <- result_try(
    list.try_map(decls, fn(d) {
      let #(name, params, body) = d
      lower_function(name, params, body, ctx)
    }),
  )
  use main <- result_try(lower_main(top, ctx))

  let functions = [main, ..funcs]
  Ok(
    ir.Module(
      name: module_name,
      uses_numerics: True,
      memories: [],
      globals: [],
      imports: [],
      functions: functions,
      exports: list.map(functions, fn(f) { ir.ExportFn(f.name, f.name) }),
      data_segments: [],
      tables: [],
      elements: [],
      start: None,
      tags: [],
    ),
  )
}

fn as_function_decl(
  s: ast.Statement,
) -> Result(#(String, List(ast.Pattern), ast.Statement), Nil) {
  case s {
    ast.FunctionDeclaration(name: Some(name), params:, body:, ..) ->
      Ok(#(name, params, body))
    _ -> Error(Nil)
  }
}

fn lower_function(
  name: String,
  params: List(ast.Pattern),
  body: ast.Statement,
  ctx: Ctx,
) -> Result(ir.Function, Error) {
  use param_names <- result_try(
    list.try_map(params, fn(p) {
      case p {
        ast.IdentifierPattern(name: n, ..) -> Ok(n)
        _ -> Error(Unsupported("non-identifier parameter pattern"))
      }
    }),
  )
  let env =
    list.fold(param_names, dict.new(), fn(acc, n) {
      dict.insert(acc, n, ir.Var(n))
    })
  use #(body_expr, _ctr) <- result_try(lower_body(
    block_stmts(body),
    env,
    ctx,
    0,
  ))
  Ok(ir.Function(
    name: name,
    params: list.map(param_names, fn(n) { ir.Local(n, ir.TTerm) }),
    result: [ir.TTerm],
    locals: [],
    body: body_expr,
  ))
}

fn lower_main(
  stmts: List(ast.Statement),
  ctx: Ctx,
) -> Result(ir.Function, Error) {
  use #(body, _ctr) <- result_try(lower_body(stmts, dict.new(), ctx, 0))
  Ok(ir.Function(
    name: "main",
    params: [],
    result: [ir.TTerm],
    locals: [],
    body:,
  ))
}

/// Lower a function/program body: a statement list whose fall-through yields
/// `undefined` (JS functions with no `return`).
fn lower_body(
  stmts: List(ast.Statement),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(ir.Expr, Int), Error) {
  lower_stmts(stmts, env, ctx, ctr, fn(_env, ctr) {
    Ok(#(ir.Values([undefined()]), ctr))
  })
}

// ── statements (CPS: `k` is the continuation given the resulting env) ─────────

type Cont =
  fn(Env, Int) -> Result(#(ir.Expr, Int), Error)

fn lower_stmts(
  stmts: List(ast.Statement),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  case stmts {
    [] -> k(env, ctr)
    [s, ..rest] ->
      lower_stmt(s, env, ctx, ctr, fn(env2, ctr2) {
        lower_stmts(rest, env2, ctx, ctr2, k)
      })
  }
}

fn lower_stmt(
  s: ast.Statement,
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  case s {
    ast.EmptyStatement -> k(env, ctr)
    ast.BlockStatement(body:) ->
      lower_stmts(list.map(body, fn(w) { w.statement }), env, ctx, ctr, k)

    // `return e;` — terminates (the continuation is dead).
    ast.ReturnStatement(argument: arg) -> {
      let #(e, ctr2) = case arg {
        Some(e) -> #(e, ctr)
        None -> #(ast.UndefinedExpression(span: ast.Span(0, 0)), ctr)
      }
      use #(binds, v, ctr3) <- result_try(lower_expr(e, env, ctx, ctr2))
      Ok(#(emit_lets(binds, ir.Return([v])), ctr3))
    }

    // `let/const/var x = e;` (flat scope) — extend env, continue.
    ast.VariableDeclaration(declarations:, ..) ->
      lower_var_decls(declarations, env, ctx, ctr, k)

    // A bare expression (assignment, call, …) — evaluate for effect, continue. An
    // assignment `x = e` rebinds `x` to the ACTUAL rhs value in the env.
    ast.ExpressionStatement(expression: e, ..) -> {
      use #(binds, v, ctr2) <- result_try(lower_expr(e, env, ctx, ctr))
      use #(rest, ctr3) <- result_try(k(env_after_effect(e, v, env), ctr2))
      Ok(#(emit_lets(binds, rest), ctr3))
    }

    ast.IfStatement(condition:, consequent:, alternate:) ->
      lower_if(condition, consequent, alternate, env, ctx, ctr, k)

    ast.WhileStatement(condition:, body:) ->
      lower_while(condition, body, False, env, ctx, ctr, k)
    ast.DoWhileStatement(condition:, body:) ->
      lower_while(condition, body, True, env, ctx, ctr, k)
    ast.ForStatement(init:, condition:, update:, body:) ->
      lower_for(init, condition, update, body, env, ctx, ctr, k)

    ast.BreakStatement(label: None) ->
      case ctx.loop {
        Some(Loop(label:, carried:, ..)) ->
          Ok(#(ir.Break(label, carried_vals(env, carried)), ctr))
        None -> Error(Unsupported("break outside a loop"))
      }
    ast.ContinueStatement(label: None) ->
      case ctx.loop {
        // A do/while back-edge re-tests the condition; our loop's `Continue` re-enters
        // the top of the body, which can't express that for an explicit `continue`.
        Some(Loop(do_while: True, ..)) ->
          Error(Unsupported("`continue` inside a do/while loop"))
        // `for`-loop `continue` must run the update; `continue_edge` handles both it
        // and the plain `while` case.
        Some(loop) -> continue_edge(loop, env, ctx, ctr)
        None -> Error(Unsupported("continue outside a loop"))
      }

    ast.FunctionDeclaration(..) -> k(env, ctr)
    // hoisted at the top level
    _ -> Error(Unsupported("statement: " <> string_tag(s)))
  }
}

fn lower_var_decls(
  decls: List(ast.VariableDeclarator),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  case decls {
    [] -> k(env, ctr)
    [
      ast.VariableDeclarator(id: ast.IdentifierPattern(name: x, ..), init:),
      ..rest
    ] -> {
      let #(e, _) = case init {
        Some(e) -> #(e, Nil)
        None -> #(ast.UndefinedExpression(span: ast.Span(0, 0)), Nil)
      }
      use #(binds, v, ctr2) <- result_try(lower_expr(e, env, ctx, ctr))
      use #(more, ctr3) <- result_try(lower_var_decls(
        rest,
        dict.insert(env, x, v),
        ctx,
        ctr2,
        k,
      ))
      Ok(#(emit_lets(binds, more), ctr3))
    }
    _ -> Error(Unsupported("destructuring declaration"))
  }
}

/// The env after evaluating an expression whose value is `v`: if it is an assignment
/// `x = …` to an identifier, rebind `x` to `v` (the assignment's value, which
/// `lower_expr` already returned). For a chain `x = y = e`, every target receives the
/// same value `v`, so we recurse into the RHS to rebind `y` as well.
///
/// LIMITATION (v1): only the outermost assignment and a direct assignment chain are
/// rebound. An assignment buried in a larger expression (`f(x = 1)`, `(x = 1) + 1`,
/// `while ((line = next()) != null)`) computes the right value but its target's env
/// rebind is not threaded here, so a later read of that target sees the old value.
fn env_after_effect(e: ast.Expression, v: ir.Value, env: Env) -> Env {
  case e {
    ast.AssignmentExpression(left: ast.Identifier(name: x, ..), right: rhs, ..) ->
      env_after_effect(rhs, v, dict.insert(env, x, v))
    // `x++` / `++x` (and `--`): `v` is the new value, so rebind `x` to it.
    ast.UpdateExpression(argument: ast.Identifier(name: x, ..), ..) ->
      dict.insert(env, x, v)
    _ -> env
  }
}

// ── if / else (phi-merge mutated variables) ──────────────────────────────────

fn lower_if(
  cond: ast.Expression,
  consequent: ast.Statement,
  alternate: Option(ast.Statement),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  use #(cbinds, cval, ctr) <- result_try(lower_cond(cond, env, ctx, ctr))
  let then_stmts = block_stmts(consequent)
  let else_stmts = case alternate {
    Some(a) -> block_stmts(a)
    None -> []
  }
  // Variables assigned in either branch (and already in scope) are phi-merged.
  let mutated =
    list.append(assigned_in(then_stmts), assigned_in(else_stmts))
    |> list.unique
    |> list.filter(dict.has_key(env, _))

  use #(then_expr, ctr) <- result_try(lower_branch(
    then_stmts,
    env,
    ctx,
    ctr,
    mutated,
  ))
  use #(else_expr, ctr) <- result_try(lower_branch(
    else_stmts,
    env,
    ctx,
    ctr,
    mutated,
  ))

  let #(after, ctr) = fresh_n(list.length(mutated), ctr)
  let env2 =
    list.fold(list.zip(mutated, after), env, fn(acc, p) {
      dict.insert(acc, p.0, ir.Var(p.1))
    })
  use #(rest, ctr) <- result_try(k(env2, ctr))
  let tys = list.map(mutated, fn(_) { ir.TTerm })
  Ok(#(
    emit_lets(
      cbinds,
      ir.Let(
        after,
        ir.If(
          cond: cval,
          result: tys,
          then_branch: then_expr,
          else_branch: else_expr,
        ),
        rest,
      ),
    ),
    ctr,
  ))
}

/// Lower a branch body; on fall-through it yields the `mutated` variables' current
/// values (the phi inputs). A `return`/`break`/`continue` inside terminates instead.
fn lower_branch(
  stmts: List(ast.Statement),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  mutated: List(String),
) -> Result(#(ir.Expr, Int), Error) {
  lower_stmts(stmts, env, ctx, ctr, fn(env2, ctr2) {
    Ok(#(ir.Values(carried_vals(env2, mutated)), ctr2))
  })
}

// ── loops (loop-carried mutated variables) ───────────────────────────────────

fn lower_while(
  cond: ast.Expression,
  body: ast.Statement,
  do_while: Bool,
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  let body_stmts = block_stmts(body)
  let carried =
    assigned_in(body_stmts) |> list.unique |> list.filter(dict.has_key(env, _))
  let #(label, ctr) = fresh_label(ctr)
  lower_loop(
    label,
    carried,
    None,
    do_while,
    fn(loop_env, ctx2, ctr) {
      lower_loop_step(
        cond,
        body_stmts,
        None,
        do_while,
        loop_env,
        ctx2,
        label,
        carried,
        ctr,
      )
    },
    env,
    ctx,
    ctr,
    k,
  )
}

fn lower_for(
  init: Option(ast.ForInit),
  condition: Option(ast.Expression),
  update: Option(ast.Expression),
  body: ast.Statement,
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  // `for (init; cond; upd) body` — run init in the current scope, then loop.
  use #(env, init_binds, ctr) <- result_try(lower_for_init(init, env, ctx, ctr))
  let body_stmts = block_stmts(body)
  let upd_assigned = case update {
    Some(u) -> assigned_of_expr(u)
    None -> []
  }
  let carried =
    list.append(assigned_in(body_stmts), upd_assigned)
    |> list.unique
    |> list.filter(dict.has_key(env, _))
  let #(label, ctr) = fresh_label(ctr)
  let cond = option.unwrap(condition, ast.BooleanLiteral(ast.Span(0, 0), True))
  use #(loop_expr, ctr) <- result_try(lower_loop(
    label,
    carried,
    update,
    False,
    fn(loop_env, ctx2, ctr) {
      lower_loop_step(
        cond,
        body_stmts,
        update,
        False,
        loop_env,
        ctx2,
        label,
        carried,
        ctr,
      )
    },
    env,
    ctx,
    ctr,
    k,
  ))
  Ok(#(emit_lets(init_binds, loop_expr), ctr))
}

fn lower_for_init(
  init: Option(ast.ForInit),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(Env, List(Bind), Int), Error) {
  case init {
    None -> Ok(#(env, [], ctr))
    Some(ast.ForInitDeclaration(ast.VariableDeclaration(declarations:, ..))) ->
      lower_init_decls(declarations, env, ctx, ctr, [])
    Some(ast.ForInitExpression(e)) -> {
      use #(binds, v, ctr) <- result_try(lower_expr(e, env, ctx, ctr))
      Ok(#(env_after_effect(e, v, env), binds, ctr))
    }
    _ -> Error(Unsupported("for-init pattern"))
  }
}

fn lower_init_decls(
  decls: List(ast.VariableDeclarator),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  acc: List(Bind),
) -> Result(#(Env, List(Bind), Int), Error) {
  case decls {
    [] -> Ok(#(env, acc, ctr))
    [
      ast.VariableDeclarator(
        id: ast.IdentifierPattern(name: x, ..),
        init: Some(e),
      ),
      ..rest
    ] -> {
      use #(binds, v, ctr) <- result_try(lower_expr(e, env, ctx, ctr))
      lower_init_decls(
        rest,
        dict.insert(env, x, v),
        ctx,
        ctr,
        list.append(acc, binds),
      )
    }
    _ -> Error(Unsupported("for-init declaration"))
  }
}

/// Shared loop skeleton: bind the carried vars' entry values, run the `Loop`, then
/// rebind them and continue. `step` builds the per-iteration body in the loop env.
fn lower_loop(
  label: String,
  carried: List(String),
  update: Option(ast.Expression),
  do_while: Bool,
  step: fn(Env, Ctx, Int) -> Result(#(ir.Expr, Int), Error),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  let inits = carried_vals(env, carried)
  let params =
    list.map2(carried, inits, fn(v, initv) { ir.LoopParam(v, ir.TTerm, initv) })
  let loop_env =
    list.fold(carried, env, fn(acc, v) { dict.insert(acc, v, ir.Var(v)) })
  let loop_ctx = Ctx(..ctx, loop: Some(Loop(label, carried, update, do_while)))
  use #(body, ctr) <- result_try(step(loop_env, loop_ctx, ctr))
  let tys = list.map(carried, fn(_) { ir.TTerm })

  let #(after, ctr) = fresh_n(list.length(carried), ctr)
  let env2 =
    list.fold(list.zip(carried, after), env, fn(acc, p) {
      dict.insert(acc, p.0, ir.Var(p.1))
    })
  use #(rest, ctr) <- result_try(k(env2, ctr))
  Ok(#(
    ir.Let(
      after,
      ir.Loop(label: label, params: params, result: tys, body: body),
      rest,
    ),
    ctr,
  ))
}

/// A loop back-edge for a fall-through or an explicit `for`-loop `continue`: run the
/// `for` update (if any) in `env`, then `Continue` the loop with the carried vars'
/// post-update values. Per JS, `continue` in a `for` loop runs the update, so both
/// the body's fall-through and an explicit `continue` route through here.
fn continue_edge(
  loop: Loop,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(ir.Expr, Int), Error) {
  case loop.update {
    None -> Ok(#(ir.Continue(loop.label, carried_vals(env, loop.carried)), ctr))
    Some(u) -> {
      use #(ubinds, uv, ctr) <- result_try(lower_expr(u, env, ctx, ctr))
      let env2 = env_after_effect(u, uv, env)
      Ok(#(
        emit_lets(
          ubinds,
          ir.Continue(loop.label, carried_vals(env2, loop.carried)),
        ),
        ctr,
      ))
    }
  }
}

/// One loop iteration. For `while`/`for`: `if (cond) { body; update?; continue }
/// else break` — the guard runs first, so the body is skipped when `cond` is false.
/// For `do/while`: `body; if (cond) continue else break` — the body runs first
/// (unconditionally), then the condition is tested at the bottom, so the body always
/// executes at least once (an explicit `continue` inside a do/while is rejected by
/// the statement layer, since our top-of-loop `Continue` can't jump to the bottom test).
fn lower_loop_step(
  cond: ast.Expression,
  body_stmts: List(ast.Statement),
  update: Option(ast.Expression),
  do_while: Bool,
  loop_env: Env,
  loop_ctx: Ctx,
  label: String,
  carried: List(String),
  ctr: Int,
) -> Result(#(ir.Expr, Int), Error) {
  let loop = Loop(label, carried, update, do_while)
  let tys = list.map(carried, fn(_) { ir.TTerm })
  case do_while {
    // do/while: body runs first, then the guard decides continue-vs-break.
    True -> {
      let bottom: Cont = fn(env2, ctr2) {
        use #(cbinds, cval, ctr2) <- result_try(lower_cond(
          cond,
          env2,
          loop_ctx,
          ctr2,
        ))
        use #(cont_expr, ctr2) <- result_try(continue_edge(
          loop,
          env2,
          loop_ctx,
          ctr2,
        ))
        let brk = ir.Break(label, carried_vals(env2, carried))
        Ok(#(
          emit_lets(
            cbinds,
            ir.If(
              cond: cval,
              result: tys,
              then_branch: cont_expr,
              else_branch: brk,
            ),
          ),
          ctr2,
        ))
      }
      lower_stmts(body_stmts, loop_env, loop_ctx, ctr, bottom)
    }
    // while/for: guard first; the body (then update, then continue) runs only if true.
    False -> {
      use #(cbinds, cval, ctr) <- result_try(lower_cond(
        cond,
        loop_env,
        loop_ctx,
        ctr,
      ))
      let cont: Cont = fn(env2, ctr2) {
        continue_edge(loop, env2, loop_ctx, ctr2)
      }
      use #(then_expr, ctr) <- result_try(lower_stmts(
        body_stmts,
        loop_env,
        loop_ctx,
        ctr,
        cont,
      ))
      let else_expr = ir.Break(label, carried_vals(loop_env, carried))
      Ok(#(
        emit_lets(
          cbinds,
          ir.If(
            cond: cval,
            result: tys,
            then_branch: then_expr,
            else_branch: else_expr,
          ),
        ),
        ctr,
      ))
    }
  }
}

// ── expressions (ANF: return ordered Lets + the atomic result Value) ─────────

fn lower_expr(
  e: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case e {
    ast.ParenthesizedExpression(expression: inner, ..) ->
      lower_expr(inner, env, ctx, ctr)

    ast.NumberLiteral(value: v, ..) -> Ok(number_literal(v, ctr))
    ast.StringExpression(value: s, ..) ->
      Ok(#([], ir.ConstBinary(<<s:utf8>>), ctr))
    ast.BooleanLiteral(value: b, ..) ->
      Ok(#([], ir.ConstAtom(bool_to_string(b)), ctr))
    ast.NullLiteral(..) -> Ok(#([], ir.ConstAtom("null"), ctr))
    ast.UndefinedExpression(..) -> Ok(#([], undefined(), ctr))
    ast.TemplateLiteral(quasis:, expressions:, ..) ->
      lower_template(quasis, expressions, env, ctx, ctr)

    ast.Identifier(name: x, ..) ->
      case dict.get(env, x) {
        Ok(v) -> Ok(#([], v, ctr))
        // A bare reference to a top-level function is that function as a value.
        Error(_) ->
          case list.contains(ctx.funcs, x) {
            True -> Ok(bind1(ir.MakeClosure(x, [], fn_arity_unknown(x)), ctr))
            False -> Error(Unsupported("unbound identifier '" <> x <> "'"))
          }
      }

    ast.BinaryExpression(operator: op, left:, right:, ..) ->
      lower_binary(op, left, right, env, ctx, ctr)
    ast.LogicalExpression(operator: op, left:, right:, ..) ->
      lower_logical(op, left, right, env, ctx, ctr)
    ast.UnaryExpression(operator: op, argument:, ..) ->
      lower_unary(op, argument, env, ctx, ctr)
    ast.ConditionalExpression(condition:, consequent:, alternate:, ..) ->
      lower_ternary(condition, consequent, alternate, env, ctx, ctr)

    ast.AssignmentExpression(operator: op, left:, right:, ..) ->
      lower_assign(op, left, right, env, ctx, ctr)
    ast.UpdateExpression(operator: uop, argument:, ..) ->
      lower_update(uop, argument, env, ctr)

    ast.CallExpression(callee:, arguments:, ..) ->
      lower_call(callee, arguments, env, ctx, ctr)
    ast.MemberExpression(object:, property:, computed:, ..) ->
      lower_member(object, property, computed, env, ctx, ctr)
    ast.ObjectExpression(properties:, ..) ->
      lower_object(properties, env, ctx, ctr)

    _ -> Error(Unsupported("expression: " <> string_tag_expr(e)))
  }
}

/// Lower an expression to an **i32 truth value** for a condition position
/// (`if`/`while`/`?:`/`&&`). Comparisons specialise to a guarded i32 compare (no
/// bool-term round-trip); everything else goes through `truthy`.
fn lower_cond(
  e: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case e {
    ast.ParenthesizedExpression(expression: inner, ..) ->
      lower_cond(inner, env, ctx, ctr)
    ast.BinaryExpression(operator: op, left:, right:, ..) ->
      case compare_op(op) {
        Some(_) -> lower_compare_i32(op, left, right, env, ctx, ctr)
        None -> truthy_of(e, env, ctx, ctr)
      }
    ast.UnaryExpression(operator: ast.LogicalNot, argument:, ..) -> {
      // !x as a condition: truthy(x) == 0
      use #(binds, t, ctr) <- result_try(truthy_of(argument, env, ctx, ctr))
      Ok(bind_after(binds, ir.Num(ir.IEqz(ir.W32), [t]), ctr))
    }
    _ -> truthy_of(e, env, ctx, ctr)
  }
}

fn truthy_of(
  e: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(binds, v, ctr) <- result_try(lower_expr(e, env, ctx, ctr))
  Ok(bind_after(binds, ir.CallHost("js", "truthy", [v]), ctr))
}

// ── operators ────────────────────────────────────────────────────────────────

fn lower_binary(
  op: ast.BinaryOp,
  left: ast.Expression,
  right: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(bl, l, ctr) <- result_try(lower_expr(left, env, ctx, ctr))
  use #(br, r, ctr) <- result_try(lower_expr(right, env, ctx, ctr))
  let pre = list.append(bl, br)
  case op {
    // `+ - *` — guarded native fast path, rt_js cold path (concat/coerce).
    ast.Add -> Ok(guarded_arith("add", ir.NAdd, l, r, pre, ctr))
    ast.Subtract -> Ok(guarded_arith("sub", ir.NSub, l, r, pre, ctr))
    ast.Multiply -> Ok(guarded_arith("mul", ir.NMul, l, r, pre, ctr))
    // `/ %` — no native NumTerm op; always rt_js (real JS `/0`=Infinity etc.).
    ast.Divide -> Ok(bind_after(pre, ir.CallHost("js", "div", [l, r]), ctr))
    ast.Modulo -> Ok(bind_after(pre, ir.CallHost("js", "mod", [l, r]), ctr))
    // bitwise / shift — always rt_js (JS coerces both sides to int32 first).
    ast.BitwiseAnd ->
      Ok(bind_after(pre, ir.CallHost("js", "bit_and", [l, r]), ctr))
    ast.BitwiseOr ->
      Ok(bind_after(pre, ir.CallHost("js", "bit_or", [l, r]), ctr))
    ast.BitwiseXor ->
      Ok(bind_after(pre, ir.CallHost("js", "bit_xor", [l, r]), ctr))
    ast.LeftShift -> Ok(bind_after(pre, ir.CallHost("js", "shl", [l, r]), ctr))
    ast.RightShift -> Ok(bind_after(pre, ir.CallHost("js", "shr", [l, r]), ctr))
    ast.UnsignedRightShift ->
      Ok(bind_after(pre, ir.CallHost("js", "ushr", [l, r]), ctr))
    // `**` — always rt_js (Number::exponentiate).
    ast.Exponentiation ->
      Ok(bind_after(pre, ir.CallHost("js", "pow", [l, r]), ctr))
    // comparisons in value position → a JS boolean term.
    _ ->
      case compare_op(op) {
        Some(_) -> {
          use #(cbinds, i32v, ctr) <- result_try(lower_compare_i32(
            op,
            left,
            right,
            env,
            ctx,
            ctr,
          ))
          Ok(bind_after(cbinds, bool_term(i32v), ctr))
        }
        None -> Error(Unsupported("binary operator " <> string_binop(op)))
      }
  }
}

/// A comparison lowered to an i32 truth value: guarded native `NumTerm` compare for
/// numbers, else the `rt_js` op (real JS ordering/equality). `!==`/`!=` negate.
fn lower_compare_i32(
  op: ast.BinaryOp,
  left: ast.Expression,
  right: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(bl, l, ctr) <- result_try(lower_expr(left, env, ctx, ctr))
  use #(br, r, ctr) <- result_try(lower_expr(right, env, ctx, ctr))
  let pre = list.append(bl, br)
  let assert Some(#(js_op, num_op, negate)) = compare_op(op)
  case num_op {
    // ordering: guarded native compare; else rt_js.
    Some(nop) -> {
      let #(res, ctr) = guarded_compare(js_op, nop, l, r, pre, ctr)
      case negate {
        False -> Ok(#(res.0, res.1, ctr))
        True -> Ok(bind_after(res.0, ir.Num(ir.IEqz(ir.W32), [res.1]), ctr))
      }
    }
    // equality: rt_js eq/strict_eq (no cheap native form across types).
    None -> {
      let #(bs, i, ctr) = bind_after(pre, ir.CallHost("js", js_op, [l, r]), ctr)
      case negate {
        False -> Ok(#(bs, i, ctr))
        True -> Ok(bind_after(bs, ir.Num(ir.IEqz(ir.W32), [i]), ctr))
      }
    }
  }
}

/// `js_op`, the native `NumTermOp` (for orderings), and whether to negate the i32.
fn compare_op(
  op: ast.BinaryOp,
) -> Option(#(String, Option(ir.NumTermOp), Bool)) {
  case op {
    ast.LessThan -> Some(#("lt", Some(ir.NLt), False))
    ast.LessThanEqual -> Some(#("le", Some(ir.NLe), False))
    ast.GreaterThan -> Some(#("gt", Some(ir.NGt), False))
    ast.GreaterThanEqual -> Some(#("ge", Some(ir.NGe), False))
    ast.StrictEqual -> Some(#("strict_eq", None, False))
    ast.StrictNotEqual -> Some(#("strict_eq", None, True))
    ast.Equal -> Some(#("eq", None, False))
    ast.NotEqual -> Some(#("eq", None, True))
    _ -> None
  }
}

/// `a <op> b` guarded: `if IsNumber(a) && IsNumber(b) then NumTerm(nop) else
/// CallHost("js", js_op)`. Returns a `TTerm` (arithmetic) result.
fn guarded_arith(
  js_op: String,
  nop: ir.NumTermOp,
  l: ir.Value,
  r: ir.Value,
  pre: List(Bind),
  ctr: Int,
) -> #(List(Bind), ir.Value, Int) {
  let fast = ir.NumTerm(nop, l, r)
  let slow = ir.CallHost("js", js_op, [l, r])
  guarded(l, r, fast, slow, pre, ctr)
}

/// A guarded numeric COMPARISON → i32 truth on both arms.
fn guarded_compare(
  js_op: String,
  nop: ir.NumTermOp,
  l: ir.Value,
  r: ir.Value,
  pre: List(Bind),
  ctr: Int,
) -> #(#(List(Bind), ir.Value), Int) {
  let fast = ir.NumTerm(nop, l, r)
  let slow = ir.CallHost("js", js_op, [l, r])
  let #(binds, v, ctr) = guarded(l, r, fast, slow, pre, ctr)
  #(#(binds, v), ctr)
}

/// The shared `if IsNumber(l) && IsNumber(r) then fast else slow` builder.
fn guarded(
  l: ir.Value,
  r: ir.Value,
  fast: ir.Expr,
  slow: ir.Expr,
  pre: List(Bind),
  ctr: Int,
) -> #(List(Bind), ir.Value, Int) {
  let #(ga, ctr) = fresh(ctr)
  let #(gb, ctr) = fresh(ctr)
  let expr =
    ir.Let(
      [ga],
      ir.TermTest(ir.IsNumber, l),
      ir.Let(
        [gb],
        ir.TermTest(ir.IsNumber, r),
        ir.If(
          cond: ir.Var(ga),
          result: [ir.TTerm],
          then_branch: ir.If(
            cond: ir.Var(gb),
            result: [ir.TTerm],
            then_branch: fast,
            else_branch: slow,
          ),
          else_branch: slow,
        ),
      ),
    )
  bind_after(pre, expr, ctr)
}

fn lower_logical(
  op: ast.BinaryOp,
  left: ast.Expression,
  right: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  // Short-circuit: the rhs is evaluated only in the branch that yields it.
  // `a && b` → truthy(a) ? b : a ; `a || b` → truthy(a) ? a : b.
  use #(bl, l, ctr) <- result_try(lower_expr(left, env, ctx, ctr))
  use #(br, r, ctr) <- result_try(lower_expr(right, env, ctx, ctr))
  let #(tvar, ctr) = fresh(ctr)
  let l_branch = ir.Values([l])
  // rhs bindings live INSIDE its branch, so a side-effecting rhs isn't run eagerly.
  let r_branch = emit_lets(br, ir.Values([r]))
  let #(then_b, else_b) = case op {
    ast.LogicalAnd -> #(r_branch, l_branch)
    _ -> #(l_branch, r_branch)
  }
  let expr =
    ir.Let(
      [tvar],
      ir.CallHost("js", "truthy", [l]),
      ir.If(
        cond: ir.Var(tvar),
        result: [ir.TTerm],
        then_branch: then_b,
        else_branch: else_b,
      ),
    )
  // Only the lhs bindings are unconditional; rhs is inside its branch.
  Ok(bind_after(bl, expr, ctr))
}

/// `x++` / `++x` / `x--` / `--x` on a local variable: `x` becomes `x ± 1`. Yields the
/// NEW value; the statement layer rebinds `x` (via `env_after_effect`). The spec value
/// of a POSTFIX update is the OLD value — a documented deviation that only shows when
/// the result is used inside a larger expression (loop counters / update statements
/// discard it, so those are exact). The `± 1` reuses the guarded native arithmetic path.
fn lower_update(
  uop: ast.UpdateOp,
  argument: ast.Expression,
  env: Env,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case argument {
    ast.Identifier(name: x, ..) ->
      case dict.get(env, x) {
        Error(Nil) ->
          Error(Unsupported("update of unbound identifier '" <> x <> "'"))
        Ok(cur) -> {
          let #(bone, one, ctr) = number_literal(1.0, ctr)
          let #(js_op, nop) = case uop {
            ast.Increment -> #("add", ir.NAdd)
            ast.Decrement -> #("sub", ir.NSub)
          }
          Ok(guarded_arith(js_op, nop, cur, one, bone, ctr))
        }
      }
    _ -> Error(Unsupported("update of a non-identifier target"))
  }
}

fn lower_unary(
  op: ast.UnaryOp,
  argument: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(binds, v, ctr) <- result_try(lower_expr(argument, env, ctx, ctr))
  case op {
    ast.Negate -> Ok(bind_after(binds, ir.CallHost("js", "neg", [v]), ctr))
    ast.TypeOf -> Ok(bind_after(binds, ir.CallHost("js", "type_of", [v]), ctr))
    ast.LogicalNot -> {
      // !x → (truthy(x) == 0) as a boolean term.
      let #(binds2, t, ctr) =
        bind_after(binds, ir.CallHost("js", "truthy", [v]), ctr)
      let #(binds3, i0, ctr) =
        bind_after(binds2, ir.Num(ir.IEqz(ir.W32), [t]), ctr)
      Ok(bind_after(binds3, bool_expr(i0), ctr))
    }
    // `+x` is ToNumber(x): `+"5"`→5, `+"x"`→NaN, `+true`→1, `+""`→0. (The arithmetic
    // `neg` type-errors on non-numbers, so this needs the dedicated coercion op.)
    ast.UnaryPlus ->
      Ok(bind_after(binds, ir.CallHost("js", "to_number", [v]), ctr))
    // `void x` evaluates x for its effects (keep `binds`) and yields `undefined`.
    ast.Void -> Ok(#(binds, undefined(), ctr))
    // `~x` — bitwise NOT of ToInt32(x).
    ast.BitwiseNot ->
      Ok(bind_after(binds, ir.CallHost("js", "bit_not", [v]), ctr))
    _ -> Error(Unsupported("unary operator"))
  }
}

fn lower_ternary(
  cond: ast.Expression,
  consequent: ast.Expression,
  alternate: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(cbinds, cval, ctr) <- result_try(lower_cond(cond, env, ctx, ctr))
  use #(tbinds, tv, ctr) <- result_try(lower_expr(consequent, env, ctx, ctr))
  use #(ebinds, ev, ctr) <- result_try(lower_expr(alternate, env, ctx, ctr))
  let expr =
    ir.If(
      cond: cval,
      result: [ir.TTerm],
      then_branch: emit_lets(tbinds, ir.Values([tv])),
      else_branch: emit_lets(ebinds, ir.Values([ev])),
    )
  Ok(bind_after(cbinds, expr, ctr))
}

fn lower_assign(
  op: ast.AssignmentOp,
  left: ast.Expression,
  right: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case left {
    // `x op= e` desugars to `x = x op e`; `x` is a pure identifier, so the doubled
    // read in the desugared rhs is harmless. The rhs value IS the assignment's value;
    // the env rebind of `x` is applied by the statement layer (via `env_after_effect`).
    ast.Identifier(..) -> {
      use rhs <- result_try(desugar_compound(op, left, right))
      lower_expr(rhs, env, ctx, ctr)
    }
    // `obj.p op= e` / `obj[k] op= e`. Evaluate the object and key EXACTLY ONCE so a
    // compound assignment (or a side-effecting/computed `getObj()[k()] += e`) doesn't
    // re-run them, then read/write the property through those bound values.
    ast.MemberExpression(object:, property:, computed:, ..) -> {
      use #(bo, o, ctr) <- result_try(lower_expr(object, env, ctx, ctr))
      use #(bk, key, ctr) <- result_try(member_key(
        property,
        computed,
        env,
        ctx,
        ctr,
      ))
      case op {
        // plain `obj.p = e` → set_prop(o, key, e), returns e.
        ast.Assign -> {
          use #(bv, v, ctr) <- result_try(lower_expr(right, env, ctx, ctr))
          let pre = list.flatten([bo, bk, bv])
          Ok(bind_after(pre, ir.CallHost("js", "set_prop", [o, key, v]), ctr))
        }
        // compound `obj.p op= e` → set_prop(o, key, get_prop(o, key) op e). Order:
        // object, key, read, rhs — matching JS reference/GetValue/rhs evaluation.
        _ -> {
          let #(bcur, cur, ctr) =
            bind_after(
              list.flatten([bo, bk]),
              ir.CallHost("js", "get_prop", [o, key]),
              ctr,
            )
          use #(brv, rv, ctr) <- result_try(lower_expr(right, env, ctx, ctr))
          use #(bres, resv, ctr) <- result_try(apply_compound(
            op,
            cur,
            rv,
            list.append(bcur, brv),
            ctr,
          ))
          Ok(bind_after(
            bres,
            ir.CallHost("js", "set_prop", [o, key, resv]),
            ctr,
          ))
        }
      }
    }
    _ -> Error(Unsupported("assignment target"))
  }
}

/// Apply a compound-assignment arithmetic operator (`+= -= *= /= %=`) to two lowered
/// operand Values, emitting the SAME guarded native/`rt_js` dispatch as `lower_binary`.
fn apply_compound(
  op: ast.AssignmentOp,
  l: ir.Value,
  r: ir.Value,
  pre: List(Bind),
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case op {
    ast.AddAssign -> Ok(guarded_arith("add", ir.NAdd, l, r, pre, ctr))
    ast.SubtractAssign -> Ok(guarded_arith("sub", ir.NSub, l, r, pre, ctr))
    ast.MultiplyAssign -> Ok(guarded_arith("mul", ir.NMul, l, r, pre, ctr))
    ast.DivideAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "div", [l, r]), ctr))
    ast.ModuloAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "mod", [l, r]), ctr))
    ast.BitwiseAndAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "bit_and", [l, r]), ctr))
    ast.BitwiseOrAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "bit_or", [l, r]), ctr))
    ast.BitwiseXorAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "bit_xor", [l, r]), ctr))
    ast.LeftShiftAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "shl", [l, r]), ctr))
    ast.RightShiftAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "shr", [l, r]), ctr))
    ast.UnsignedRightShiftAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "ushr", [l, r]), ctr))
    ast.ExponentiationAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "pow", [l, r]), ctr))
    _ -> Error(Unsupported("compound assignment operator"))
  }
}

fn desugar_compound(
  op: ast.AssignmentOp,
  left: ast.Expression,
  right: ast.Expression,
) -> Result(ast.Expression, Error) {
  let sp = ast.Span(0, 0)
  case op {
    ast.Assign -> Ok(right)
    ast.AddAssign -> Ok(ast.BinaryExpression(sp, ast.Add, left, right))
    ast.SubtractAssign ->
      Ok(ast.BinaryExpression(sp, ast.Subtract, left, right))
    ast.MultiplyAssign ->
      Ok(ast.BinaryExpression(sp, ast.Multiply, left, right))
    ast.DivideAssign -> Ok(ast.BinaryExpression(sp, ast.Divide, left, right))
    ast.ModuloAssign -> Ok(ast.BinaryExpression(sp, ast.Modulo, left, right))
    ast.BitwiseAndAssign ->
      Ok(ast.BinaryExpression(sp, ast.BitwiseAnd, left, right))
    ast.BitwiseOrAssign ->
      Ok(ast.BinaryExpression(sp, ast.BitwiseOr, left, right))
    ast.BitwiseXorAssign ->
      Ok(ast.BinaryExpression(sp, ast.BitwiseXor, left, right))
    ast.LeftShiftAssign ->
      Ok(ast.BinaryExpression(sp, ast.LeftShift, left, right))
    ast.RightShiftAssign ->
      Ok(ast.BinaryExpression(sp, ast.RightShift, left, right))
    ast.UnsignedRightShiftAssign ->
      Ok(ast.BinaryExpression(sp, ast.UnsignedRightShift, left, right))
    ast.ExponentiationAssign ->
      Ok(ast.BinaryExpression(sp, ast.Exponentiation, left, right))
    _ -> Error(Unsupported("compound assignment operator"))
  }
}

// ── calls / members / objects ────────────────────────────────────────────────

fn lower_call(
  callee: ast.Expression,
  arguments: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case callee {
    // console.log(...) → rt_js console_log(cons-list of args).
    ast.MemberExpression(
      object: ast.Identifier(name: "console", ..),
      property: ast.Identifier(name: "log", ..),
      computed: False,
      ..,
    ) -> {
      use #(binds, argvals, ctr) <- result_try(lower_args(
        arguments,
        env,
        ctx,
        ctr,
      ))
      let #(binds2, listv, ctr) = build_list(argvals, binds, ctr)
      Ok(bind_after(binds2, ir.CallHost("js", "console_log", [listv]), ctr))
    }
    // f(args) where f is a top-level function → direct call.
    ast.Identifier(name: fname, ..) ->
      case list.contains(ctx.funcs, fname) {
        True -> {
          use #(binds, argvals, ctr) <- result_try(lower_args(
            arguments,
            env,
            ctx,
            ctr,
          ))
          Ok(bind_after(binds, ir.CallDirect(fname, argvals), ctr))
        }
        // f is a value (a closure in a variable) → CallClosure.
        False ->
          case dict.get(env, fname) {
            Ok(fv) -> {
              use #(binds, argvals, ctr) <- result_try(lower_args(
                arguments,
                env,
                ctx,
                ctr,
              ))
              Ok(bind_after(binds, ir.CallClosure(fv, argvals), ctr))
            }
            Error(_) -> Error(Unsupported("call to unknown '" <> fname <> "'"))
          }
      }
    _ -> Error(Unsupported("call of a computed/other callee"))
  }
}

fn lower_args(
  args: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), List(ir.Value), Int), Error) {
  list.try_fold(args, #([], [], ctr), fn(acc, a) {
    let #(binds, vals, ctr) = acc
    use #(b, v, ctr) <- result_try(lower_expr(a, env, ctx, ctr))
    Ok(#(list.append(binds, b), list.append(vals, [v]), ctr))
  })
}

/// Build a BEAM cons list from `empty_list()` and `MakeCons`, for `console.log`.
fn build_list(
  vals: List(ir.Value),
  pre: List(Bind),
  ctr: Int,
) -> #(List(Bind), ir.Value, Int) {
  let #(binds, nilv, ctr) =
    bind_after(pre, ir.CallHost("js", "empty_list", []), ctr)
  list.fold_right(vals, #(binds, nilv, ctr), fn(acc, v) {
    let #(binds, tail, ctr) = acc
    bind_after(binds, ir.TermOp(ir.MakeCons, [v, tail]), ctr)
  })
}

fn lower_member(
  object: ast.Expression,
  property: ast.Expression,
  computed: Bool,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(bo, o, ctr) <- result_try(lower_expr(object, env, ctx, ctr))
  use #(bk, key, ctr) <- result_try(member_key(
    property,
    computed,
    env,
    ctx,
    ctr,
  ))
  Ok(bind_after(
    list.append(bo, bk),
    ir.CallHost("js", "get_prop", [o, key]),
    ctr,
  ))
}

fn member_key(
  property: ast.Expression,
  computed: Bool,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case computed {
    // obj[k] — k is any expression.
    True -> lower_expr(property, env, ctx, ctr)
    // obj.prop — the property is an identifier used as a string key.
    False ->
      case property {
        ast.Identifier(name: p, ..) ->
          Ok(#([], ir.ConstBinary(<<p:utf8>>), ctr))
        _ -> Error(Unsupported("member property"))
      }
  }
}

fn lower_object(
  properties: List(ast.Property),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  let #(binds, obj, ctr) =
    bind_after([], ir.CallHost("js", "new_object", []), ctr)
  list.try_fold(properties, #(binds, obj, ctr), fn(acc, prop) {
    let #(binds, obj, ctr) = acc
    case prop {
      ast.Property(key:, value:, computed:, ..) -> {
        use #(bk, key, ctr) <- result_try(object_key(
          key,
          computed,
          env,
          ctx,
          ctr,
        ))
        use #(bv, v, ctr) <- result_try(lower_expr(value, env, ctx, ctr))
        // set_prop returns the value; we thread the object handle forward (it is a
        // stable ref — set mutates it), so `obj` stays the result.
        let pre = list.flatten([binds, bk, bv])
        let #(binds2, _r, ctr) =
          bind_after(pre, ir.CallHost("js", "set_prop", [obj, key, v]), ctr)
        Ok(#(binds2, obj, ctr))
      }
      _ -> Error(Unsupported("object spread / getter / setter"))
    }
  })
}

fn object_key(
  key: ast.Expression,
  computed: Bool,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case computed, key {
    True, _ -> lower_expr(key, env, ctx, ctr)
    False, ast.Identifier(name: p, ..) ->
      Ok(#([], ir.ConstBinary(<<p:utf8>>), ctr))
    False, ast.StringExpression(value: s, ..) ->
      Ok(#([], ir.ConstBinary(<<s:utf8>>), ctr))
    False, ast.NumberLiteral(value: v, ..) ->
      Ok(#([], ir.ConstBinary(<<num_key(v):utf8>>), ctr))
    _, _ -> Error(Unsupported("object key"))
  }
}

fn lower_template(
  quasis: List(String),
  expressions: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  // `q0 ${e0} q1 ${e1} q2` → q0 + str(e0) + q1 + str(e1) + q2 (rt_js add concat).
  case quasis {
    [] -> Ok(#([], ir.ConstBinary(<<>>), ctr))
    [first, ..rest_q] -> {
      let acc0 = #([], ir.ConstBinary(<<first:utf8>>), ctr)
      use #(binds, acc, ctr) <- result_try(
        list.try_fold(list.zip(expressions, rest_q), acc0, fn(state, pair) {
          let #(binds, acc, ctr) = state
          let #(e, q) = pair
          use #(be, ev, ctr) <- result_try(lower_expr(e, env, ctx, ctr))
          // acc + String(e) + q
          let #(b1, s, ctr) =
            bind_after(
              list.append(binds, be),
              ir.CallHost("js", "to_string", [ev]),
              ctr,
            )
          let #(b2, acc1, ctr) =
            bind_after(b1, ir.CallHost("js", "add", [acc, s]), ctr)
          let #(b3, acc2, ctr) =
            bind_after(
              b2,
              ir.CallHost("js", "add", [acc1, ir.ConstBinary(<<q:utf8>>)]),
              ctr,
            )
          Ok(#(b3, acc2, ctr))
        }),
      )
      Ok(#(binds, acc, ctr))
    }
  }
}

// ── literals / small helpers ─────────────────────────────────────────────────

/// A JS number literal → a native BEAM number term: an integer term when integral
/// (exact + fast fixnum arithmetic), else a native float term.
fn number_literal(v: Float, ctr: Int) -> #(List(Bind), ir.Value, Int) {
  case is_integral(v) {
    True -> {
      let #(name, ctr) = fresh(ctr)
      #(
        [#(name, ir.Convert(ir.BoxInt(ir.W64), ir.ConstI64(float.truncate(v))))],
        ir.Var(name),
        ctr,
      )
    }
    False -> #([], ir.ConstFloatTerm(v), ctr)
  }
}

fn is_integral(v: Float) -> Bool {
  int.to_float(float.truncate(v)) == v
}

/// The JS `undefined` value — the `rt_js` sentinel atom.
fn undefined() -> ir.Value {
  ir.ConstAtom("undefined")
}

fn bool_to_string(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

/// An i32 truth `Value` → a JS boolean **term** (`'true'`/`'false'`).
fn bool_term(i32v: ir.Value) -> ir.Expr {
  bool_expr(i32v)
}

fn bool_expr(i32v: ir.Value) -> ir.Expr {
  ir.If(
    cond: i32v,
    result: [ir.TTerm],
    then_branch: ir.Values([ir.ConstAtom("true")]),
    else_branch: ir.Values([ir.ConstAtom("false")]),
  )
}

/// A conservative arity for a bare top-level-function reference used as a value.
/// We don't track arities here (v1), so a plain reference is unsupported precisely.
fn fn_arity_unknown(name: String) -> Int {
  // A closure over a top-level function needs its arity; not tracked in v1.
  panic as {
    "js: first-class use of function '" <> name <> "' not supported yet"
  }
}

fn num_key(v: Float) -> String {
  case is_integral(v) {
    True -> int.to_string(float.truncate(v))
    False -> float.to_string(v)
  }
}

// ── the assigned-variable analysis (mutated set for control flow) ────────────

/// Variable names ASSIGNED (`x = …`, `x += …`, `x++`) anywhere in a statement list,
/// recursing through nested control flow but NOT into nested functions. Declarations
/// (`let x`) are not assignments.
fn assigned_in(stmts: List(ast.Statement)) -> List(String) {
  list.flat_map(stmts, assigned_in_stmt)
}

fn assigned_in_stmt(s: ast.Statement) -> List(String) {
  case s {
    ast.ExpressionStatement(expression: e, ..) -> assigned_of_expr(e)
    ast.BlockStatement(body:) ->
      assigned_in(list.map(body, fn(w) { w.statement }))
    ast.IfStatement(consequent:, alternate:, ..) ->
      list.append(assigned_in_stmt(consequent), case alternate {
        Some(a) -> assigned_in_stmt(a)
        None -> []
      })
    ast.WhileStatement(body:, ..) -> assigned_in_stmt(body)
    ast.DoWhileStatement(body:, ..) -> assigned_in_stmt(body)
    ast.ForStatement(update:, body:, ..) ->
      list.append(assigned_in_stmt(body), case update {
        Some(u) -> assigned_of_expr(u)
        None -> []
      })
    _ -> []
  }
}

fn assigned_of_expr(e: ast.Expression) -> List(String) {
  case e {
    ast.AssignmentExpression(left: ast.Identifier(name: x, ..), ..) -> [x]
    ast.UpdateExpression(argument: ast.Identifier(name: x, ..), ..) -> [x]
    ast.SequenceExpression(expressions:, ..) ->
      list.flat_map(expressions, assigned_of_expr)
    _ -> []
  }
}

// ── plumbing ──────────────────────────────────────────────────────────────────

fn block_stmts(s: ast.Statement) -> List(ast.Statement) {
  case s {
    ast.BlockStatement(body:) -> list.map(body, fn(w) { w.statement })
    other -> [other]
  }
}

fn carried_vals(env: Env, names: List(String)) -> List(ir.Value) {
  list.map(names, fn(n) {
    case dict.get(env, n) {
      Ok(v) -> v
      Error(_) -> undefined()
    }
  })
}

fn emit_lets(binds: List(Bind), body: ir.Expr) -> ir.Expr {
  list.fold_right(binds, body, fn(acc, b) { ir.Let([b.0], b.1, acc) })
}

/// Append one fresh `Let`-binding of `expr` to `pre`, returning the result `Value`.
fn bind_after(
  pre: List(Bind),
  expr: ir.Expr,
  ctr: Int,
) -> #(List(Bind), ir.Value, Int) {
  let #(name, ctr) = fresh(ctr)
  #(list.append(pre, [#(name, expr)]), ir.Var(name), ctr)
}

fn bind1(expr: ir.Expr, ctr: Int) -> #(List(Bind), ir.Value, Int) {
  bind_after([], expr, ctr)
}

fn fresh(ctr: Int) -> #(String, Int) {
  #("v" <> int.to_string(ctr), ctr + 1)
}

fn fresh_n(n: Int, ctr: Int) -> #(List(String), Int) {
  case n {
    0 -> #([], ctr)
    _ -> {
      let #(name, ctr) = fresh(ctr)
      let #(rest, ctr) = fresh_n(n - 1, ctr)
      #([name, ..rest], ctr)
    }
  }
}

fn fresh_label(ctr: Int) -> #(String, Int) {
  #("L" <> int.to_string(ctr), ctr + 1)
}

fn result_try(r: Result(a, e), k: fn(a) -> Result(b, e)) -> Result(b, e) {
  case r {
    Ok(v) -> k(v)
    Error(e) -> Error(e)
  }
}

fn string_tag(_s: ast.Statement) -> String {
  "unsupported"
}

fn string_tag_expr(_e: ast.Expression) -> String {
  "unsupported"
}

fn string_binop(_op: ast.BinaryOp) -> String {
  "unsupported"
}
