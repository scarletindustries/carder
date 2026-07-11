//// EXPERIMENT (experiment/js-frontend): use arc's JS parser as a frontend that
//// emits 2core IR, so 2core AOT-COMPILES JavaScript to native BEAM instead of
//// interpreting it — then benchmark against arc's own bytecode VM.
////
//// The lowering targets 2core's term layer: a JS number is a BEAM number term,
//// `a + b` is `NumTerm(NAdd)` (→ `erlang:'+'`), a `for` loop is a 2core `Loop`
//// with loop-carried params (`Continue`/`Break`), so the compiled function is a
//// tight tail-recursive BEAM loop calling arithmetic BIFs directly — no opcode
//// dispatch, no operand stack. Scope: one function; number literals, identifiers,
//// `+ - * < <= > >= ===`, `let`, assignment, and a counted `for` loop. Enough for
//// the classic compiled-vs-interpreted hot loop.

import arc/engine
import arc/parser
import arc/parser/ast
import arc/vm/completion
import arc/vm/value
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/ir
import twocore/runtime/instance

// ── FFI (mirrors term_ops_test.gleam) ───────────────────────────────────────

/// Apply `M:F(Args)` in the test VM, capturing a raise as `Error(text)`. Args and
/// result are `Dynamic` (a compiled term function takes/returns BEAM terms).
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply_dyn(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

/// Identity at runtime — build `Dynamic` argument lists.
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

/// `erlang:monotonic_time(microsecond)` — a monotonic wall clock for timing.
@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Atom) -> Int

/// `erlang:float/1` — coerce a numeric BEAM term (int OR float) to a Float, so the
/// compiled result (an integer term) compares to arc's float result by value.
@external(erlang, "erlang", "float")
fn term_to_float(x: Dynamic) -> Float

fn now_us() -> Int {
  monotonic_time(atom.create("microsecond"))
}

// ── The lowering: arc AST → 2core IR ────────────────────────────────────────

/// A binding to emit as `Let([name], rhs, …)`, in evaluation order.
type Bind =
  #(String, ir.Expr)

/// Fold ordered bindings into nested `Let`s around `body` (first binding outermost).
fn emit_lets(binds: List(Bind), body: ir.Expr) -> ir.Expr {
  list.fold_right(binds, body, fn(acc, b) { ir.Let([b.0], b.1, acc) })
}

fn fresh(ctr: Int) -> #(String, Int) {
  #("t" <> int.to_string(ctr), ctr + 1)
}

/// A JS number literal as a BEAM number **term**: an integer term when it is
/// integral (the common counting case — exact, and `erlang:'+'` on integers is
/// fast), else a float term. Both are produced by boxing a raw numeric constant.
fn box_number(v: Float) -> ir.Expr {
  let truncated = float.truncate(v)
  case int.to_float(truncated) == v {
    True -> ir.Convert(ir.BoxInt(ir.W64), ir.ConstI64(truncated))
    False -> ir.Convert(ir.BoxFloat(ir.FW64), ir.ConstF64(float_bits(v)))
  }
}

/// IEEE-754 bit pattern of `v` as an Int (for `ConstF64`).
@external(erlang, "twocore@runtime@porffor_abi", "float_to_bits")
fn float_bits(v: Float) -> Int

/// Lower a JS binary operator on two already-atomic term operands to the native
/// BEAM number-term op. Arithmetic yields a number term; comparisons an i32 truth.
fn lower_binop(op: ast.BinaryOp, l: ir.Value, r: ir.Value) -> ir.Expr {
  case op {
    ast.Add -> ir.NumTerm(ir.NAdd, l, r)
    ast.Subtract -> ir.NumTerm(ir.NSub, l, r)
    ast.Multiply -> ir.NumTerm(ir.NMul, l, r)
    ast.LessThan -> ir.NumTerm(ir.NLt, l, r)
    ast.LessThanEqual -> ir.NumTerm(ir.NLe, l, r)
    ast.GreaterThan -> ir.NumTerm(ir.NGt, l, r)
    ast.GreaterThanEqual -> ir.NumTerm(ir.NGe, l, r)
    ast.StrictEqual -> ir.NumTerm(ir.NEq, l, r)
    _ -> panic as "js-spike: unsupported binary operator"
  }
}

/// Lower a JS expression to ANF: the ordered `Let` bindings its evaluation needs,
/// plus the atomic `Value` naming its result. `env` maps a live JS variable to the
/// IR `Value` holding its current SSA binding.
fn lower_expr(
  e: ast.Expression,
  env: Dict(String, ir.Value),
  ctr: Int,
) -> #(List(Bind), ir.Value, Int) {
  case e {
    ast.NumberLiteral(value: v, ..) -> {
      let #(name, ctr) = fresh(ctr)
      #([#(name, box_number(v))], ir.Var(name), ctr)
    }
    ast.Identifier(name: x, ..) ->
      case dict.get(env, x) {
        Ok(v) -> #([], v, ctr)
        Error(_) -> panic as { "js-spike: unbound identifier '" <> x <> "'" }
      }
    ast.BinaryExpression(operator: op, left: l, right: r, ..) -> {
      let #(bl, vl, ctr) = lower_expr(l, env, ctr)
      let #(br, vr, ctr) = lower_expr(r, env, ctr)
      let #(name, ctr) = fresh(ctr)
      let binds = list.flatten([bl, br, [#(name, lower_binop(op, vl, vr))]])
      #(binds, ir.Var(name), ctr)
    }
    _ -> panic as "js-spike: unsupported expression"
  }
}

/// Lower a statement list (a function/loop body) to a single IR expression. Each
/// `let`/assignment threads the updated `env` forward; a `for` loop and `return`
/// build structured control. The list is expected to end in `return`.
fn lower_stmts(
  stmts: List(ast.Statement),
  env: Dict(String, ir.Value),
  ctr: Int,
) -> #(ir.Expr, Int) {
  case stmts {
    [] -> #(ir.Values([]), ctr)
    [stmt, ..rest] ->
      case stmt {
        // `return e;` — the (fall-through) result of the enclosing function/loop.
        ast.ReturnStatement(argument: Some(e)) -> {
          let #(binds, val, ctr) = lower_expr(e, env, ctr)
          #(emit_lets(binds, ir.Values([val])), ctr)
        }

        // `let x = e;` — bind x to e's value; no IR local, just an env entry.
        ast.VariableDeclaration(
          declarations: [
            ast.VariableDeclarator(
              id: ast.IdentifierPattern(name: x, ..),
              init: Some(e),
            ),
          ],
          ..,
        ) -> {
          let #(binds, val, ctr) = lower_expr(e, env, ctr)
          let #(body, ctr) = lower_stmts(rest, dict.insert(env, x, val), ctr)
          #(emit_lets(binds, body), ctr)
        }

        // `x = e;` — reassign x (updates the env binding).
        ast.ExpressionStatement(
          expression: ast.AssignmentExpression(
            operator: ast.Assign,
            left: ast.Identifier(name: x, ..),
            right: e,
            ..,
          ),
          ..,
        ) -> {
          let #(binds, val, ctr) = lower_expr(e, env, ctr)
          let #(body, ctr) = lower_stmts(rest, dict.insert(env, x, val), ctr)
          #(emit_lets(binds, body), ctr)
        }

        ast.ForStatement(init:, condition:, update:, body:) ->
          lower_for(init, condition, update, body, rest, env, ctr)

        _ -> panic as "js-spike: unsupported statement"
      }
  }
}

/// Lower a counted `for (let iv = e0; cond; upd) { body }`. The loop-carried
/// variables are `iv` plus every variable the body/update reassigns that is live
/// on entry. Each becomes a `LoopParam`; `Continue` re-enters with their updated
/// values, `Break` exits yielding them, and the code after the loop rebinds them.
fn lower_for(
  init: option.Option(ast.ForInit),
  condition: option.Option(ast.Expression),
  update: option.Option(ast.Expression),
  body: ast.Statement,
  rest: List(ast.Statement),
  env: Dict(String, ir.Value),
  ctr: Int,
) -> #(ir.Expr, Int) {
  // Loop variable + its init expression, from `for (let iv = e0; …)`.
  let assert Some(ast.ForInitDeclaration(ast.VariableDeclaration(
    declarations: [
      ast.VariableDeclarator(
        id: ast.IdentifierPattern(name: iv, ..),
        init: Some(e0),
      ),
    ],
    ..,
  ))) = init
  let assert Some(cond_expr) = condition
  let assert Some(upd_expr) = update
  let body_stmts = block_stmts(body)

  // Carried set: iv first, then body/update-assigned vars already live in env.
  let extern =
    list.append(collect_assigned(body_stmts), assigned_of(upd_expr))
    |> list.unique
    |> list.filter(fn(v) { v != iv && dict.has_key(env, v) })
  let carried = [iv, ..extern]

  // Init values as atomic Values (iv's from e0; the rest from their current env).
  let #(iv_binds, iv_init, ctr) = lower_expr(e0, env, ctr)
  let inits =
    list.map(carried, fn(v) {
      case v == iv {
        True -> iv_init
        False -> dict_get(env, v)
      }
    })
  let params =
    list.map2(carried, inits, fn(v, initv) { ir.LoopParam(v, ir.TTerm, initv) })

  // Inside the loop each carried var reads its own param.
  let loop_env =
    list.fold(carried, env, fn(acc, v) { dict.insert(acc, v, ir.Var(v)) })
  let result_tys = list.map(carried, fn(_) { ir.TTerm })

  // Condition → an i32 truth Value feeding the `If`.
  let #(cond_binds, cond_val, ctr) = lower_expr(cond_expr, loop_env, ctr)

  // Loop body: run the JS body, then the update, then Continue with new carried.
  let #(body_env, body_lets, ctr) = lower_seq(body_stmts, loop_env, ctr)
  let #(upd_env, upd_lets, ctr) = lower_assign(upd_expr, body_env, ctr)
  let next_vals = list.map(carried, fn(v) { dict_get(upd_env, v) })
  let continue_expr =
    emit_lets(
      list.append(body_lets, upd_lets),
      ir.Continue("jsloop", next_vals),
    )
  let exit_expr = ir.Break("jsloop", list.map(carried, fn(v) { ir.Var(v) }))

  let loop =
    ir.Loop(
      label: "jsloop",
      params: params,
      result: result_tys,
      body: emit_lets(
        cond_binds,
        ir.If(
          cond: cond_val,
          result: result_tys,
          then_branch: continue_expr,
          else_branch: exit_expr,
        ),
      ),
    )

  // Bind the loop's carried results, rebind env, lower the rest (e.g. `return s`).
  let after = list.map(carried, fn(v) { v <> "_after" })
  let env_after =
    list.fold(list.zip(carried, after), env, fn(acc, pair) {
      dict.insert(acc, pair.0, ir.Var(pair.1))
    })
  let #(rest_expr, ctr) = lower_stmts(rest, env_after, ctr)
  #(emit_lets(iv_binds, ir.Let(after, loop, rest_expr)), ctr)
}

/// Lower a straight-line statement list (a loop body: `let`/assignments only, no
/// nested control), returning the final env, the ordered bindings, and the counter.
fn lower_seq(
  stmts: List(ast.Statement),
  env: Dict(String, ir.Value),
  ctr: Int,
) -> #(Dict(String, ir.Value), List(Bind), Int) {
  list.fold(stmts, #(env, [], ctr), fn(acc, stmt) {
    let #(env, binds, ctr) = acc
    case stmt {
      ast.ExpressionStatement(expression: a, ..) -> {
        let #(env, more, ctr) = lower_assign(a, env, ctr)
        #(env, list.append(binds, more), ctr)
      }
      ast.VariableDeclaration(
        declarations: [
          ast.VariableDeclarator(
            id: ast.IdentifierPattern(name: x, ..),
            init: Some(e),
          ),
        ],
        ..,
      ) -> {
        let #(more, val, ctr) = lower_expr(e, env, ctr)
        #(dict.insert(env, x, val), list.append(binds, more), ctr)
      }
      _ -> panic as "js-spike: unsupported statement in loop body"
    }
  })
}

/// Lower `x = e` — the ordered bindings for `e`, and env updated so `x` → e's value.
fn lower_assign(
  e: ast.Expression,
  env: Dict(String, ir.Value),
  ctr: Int,
) -> #(Dict(String, ir.Value), List(Bind), Int) {
  case e {
    ast.AssignmentExpression(
      operator: ast.Assign,
      left: ast.Identifier(name: x, ..),
      right: rhs,
      ..,
    ) -> {
      let #(binds, val, ctr) = lower_expr(rhs, env, ctr)
      #(dict.insert(env, x, val), binds, ctr)
    }
    _ -> panic as "js-spike: unsupported assignment"
  }
}

/// The variable names assigned by a statement list (`x = …` targets).
fn collect_assigned(stmts: List(ast.Statement)) -> List(String) {
  list.flat_map(stmts, fn(s) {
    case s {
      ast.ExpressionStatement(expression: a, ..) -> assigned_of(a)
      _ -> []
    }
  })
}

/// The variable assigned by an expression, if it is `x = …`.
fn assigned_of(e: ast.Expression) -> List(String) {
  case e {
    ast.AssignmentExpression(left: ast.Identifier(name: x, ..), ..) -> [x]
    _ -> []
  }
}

fn block_stmts(s: ast.Statement) -> List(ast.Statement) {
  case s {
    ast.BlockStatement(body:) -> list.map(body, fn(w) { w.statement })
    other -> [other]
  }
}

fn dict_get(env: Dict(String, ir.Value), x: String) -> ir.Value {
  case dict.get(env, x) {
    Ok(v) -> v
    Error(_) -> panic as { "js-spike: unbound '" <> x <> "'" }
  }
}

/// Parse one top-level `function name(params){ body }` and lower it to an IR module
/// exporting `name` (a term function: `TTerm` params, one `TTerm` result).
fn compile_js(src: String) -> #(ir.Module, String) {
  let assert Ok(#(program, _sb)) = parser.parse(src, parser.Script)
  let stmts = case program {
    ast.Script(body:) -> list.map(body, fn(w) { w.statement })
    ast.Module(..) -> panic as "js-spike: pass a script, not a module"
  }
  let assert Ok(ast.FunctionDeclaration(
    name: Some(fn_name),
    params: params,
    body: fn_body,
    ..,
  )) = list.find(stmts, is_function_decl)

  let param_names =
    list.map(params, fn(p) {
      let assert ast.IdentifierPattern(name: n, ..) = p
      n
    })
  let env0 =
    list.fold(param_names, dict.new(), fn(acc, n) {
      dict.insert(acc, n, ir.Var(n))
    })
  let #(body_expr, _ctr) = lower_stmts(block_stmts(fn_body), env0, 0)

  let func =
    ir.Function(
      name: fn_name,
      params: list.map(param_names, fn(n) { ir.Local(n, ir.TTerm) }),
      result: [ir.TTerm],
      locals: [],
      body: body_expr,
    )
  let m =
    ir.Module(
      name: "twocore@js@" <> fn_name,
      uses_numerics: True,
      memories: [],
      globals: [],
      imports: [],
      functions: [func],
      exports: [ir.ExportFn(fn_name, fn_name)],
      data_segments: [],
      tables: [],
      elements: [],
      start: None,
      tags: [],
    )
  #(m, fn_name)
}

fn is_function_decl(s: ast.Statement) -> Bool {
  case s {
    ast.FunctionDeclaration(..) -> True
    _ -> False
  }
}

/// Emit an IR module → Core → BEAM and load it; return its module atom.
fn load(m: ir.Module) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(m, instance.safe_default())
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(<<core:utf8>>)
  mod
}

/// Compile a JS function and return a callable: apply it with BEAM-term args.
fn jit(src: String) -> #(Atom, Atom) {
  let #(m, fn_name) = compile_js(src)
  #(load(m), atom.create(fn_name))
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// The whole pipeline on the simplest function: arc parses `add`, we lower it to
/// `NumTerm(NAdd)`, compile to BEAM, and it computes on real BEAM number terms.
pub fn add_compiles_and_runs_test() {
  let #(mod, f) = jit("function add(a, b) { return a + b; }")
  catch_apply_dyn(mod, f, [to_dynamic(2), to_dynamic(3)])
  |> should.equal(Ok(to_dynamic(5)))
  // Compiled arithmetic follows BEAM number-term rules (int+float → float).
  catch_apply_dyn(mod, f, [to_dynamic(2), to_dynamic(0.5)])
  |> should.equal(Ok(to_dynamic(2.5)))
}

/// The counted loop compiles and computes the right sum — proving loop-carried
/// params, `Continue`/`Break`, and the `<`/`+` term ops end-to-end.
pub fn sum_loop_compiles_and_runs_test() {
  let #(mod, f) =
    jit(
      "function sum(n) { let s = 0; for (let i = 0; i < n; i = i + 1) { s = s + i; } return s; }",
    )
  let assert Ok(r) = catch_apply_dyn(mod, f, [to_dynamic(10)])
  // 0+1+…+9 = 45.
  term_to_float(r) |> should.equal(45.0)
}

/// BENCHMARK: AOT-compiled `sum(n)` (this spike) vs arc's bytecode VM on the same
/// JS. Prints per-run microseconds and the speedup; asserts the results agree so
/// the comparison is honest. Times execution only (compile is done once, outside).
pub fn sum_vs_arc_benchmark_test() {
  let n = 1_000_000
  let src =
    "function sum(n) { let s = 0; for (let i = 0; i < n; i = i + 1) { s = s + i; } return s; }"
  let expected = 499_999_500_000.0

  // Compile once (excluded from timing).
  let #(mod, f) = jit(src)
  let arg = [to_dynamic(n)]

  // arc: build the engine once (excluded); each run re-parses+runs the IIFE.
  let eng = engine.new()
  let arc_src =
    "(function(n){let s=0;for(let i=0;i<n;i=i+1){s=s+i;}return s;})("
    <> int.to_string(n)
    <> ")"

  // Warm up.
  let _ = catch_apply_dyn(mod, f, arg)
  let _ = arc_eval(eng, arc_src)

  let reps = 5
  let compiled_us = best_us(reps, fn() { catch_apply_dyn(mod, f, arg) })
  let arc_us = best_us(reps, fn() { arc_eval(eng, arc_src) })

  // Correctness gate: both compute the same value.
  let assert Ok(r) = catch_apply_dyn(mod, f, arg)
  term_to_float(r) |> should.equal(expected)
  arc_eval(eng, arc_src) |> should.equal(expected)

  io.println("")
  io.println("── JS→2core-IR vs arc (sum 0..999999, best of 5) ──")
  io.println("  2core (AOT→BEAM): " <> int.to_string(compiled_us) <> " us")
  io.println("  arc  (bytecode VM): " <> int.to_string(arc_us) <> " us")
  io.println("  speedup: " <> ratio(arc_us, compiled_us) <> "x")
}

/// Run `f` `reps` times, returning the fastest wall time in microseconds.
fn best_us(reps: Int, f: fn() -> a) -> Int {
  case reps <= 0 {
    True -> 999_999_999
    False -> {
      let t0 = now_us()
      let _ = f()
      int.min(now_us() - t0, best_us(reps - 1, f))
    }
  }
}

fn arc_eval(eng: engine.Engine(Nil), src: String) -> Float {
  let assert Ok(#(completion.NormalCompletion(value: v, ..), _)) =
    engine.eval(eng, src)
  let assert value.JsNumber(value.Finite(f)) = v
  f
}

fn ratio(a: Int, b: Int) -> String {
  case b {
    0 -> "inf"
    _ -> float.to_string(int.to_float(a) /. int.to_float(b))
  }
}
