//// EXPERIMENT (experiment/js-frontend): use arc's JS parser as a frontend that
//// emits 2core IR, so 2core AOT-COMPILES JavaScript to native BEAM instead of
//// interpreting it — then benchmark against arc's own bytecode VM.
////
//// The lowering (arc AST → 2core IR) is parameterised by a `Backend` so we can
//// compile the SAME JS three ways and race them against arc:
////   - term-int : JS numbers → BEAM integer terms, `+`→`NumTerm(NAdd)`
////     (`erlang:'+'`). Fast + exact for JS integers, but integer semantics.
////   - num-f64  : JS numbers → unboxed IEEE-754 doubles, `+`→`Num(FAdd)` via
////     `rt_num` (2core's conformance-tested wasm float path). This is the
////     apples-to-apples double-vs-double comparison with arc.
//// (A term-layer *float* path is intentionally absent: 2core represents floats as
//// raw bit patterns even when boxed — see emit_core `is_boxing_conv` — so a
//// `BoxFloat` term is a bit-pattern integer that `NumTerm`'s `erlang:'+'` would
//// add as an integer. Real doubles must go through the numeric layer.)
////
//// A `for` loop lowers to a 2core `Loop` with loop-carried params (`Continue`/
//// `Break`): a tight tail-recursive BEAM loop, no opcode dispatch, no operand
//// stack. Scope: one function; number literals, identifiers, `+ - * < <= > >=
//// ===`, `let`, assignment, a counted `for` loop.

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

// ── FFI (harness mirrors term_ops_test.gleam) ───────────────────────────────

/// Apply `M:F(Args)` in the test VM, capturing a raise as `Error(text)`. Args and
/// result are `Dynamic` (a compiled function takes/returns raw BEAM terms).
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

/// `erlang:float/1` — coerce a numeric BEAM term (int OR float) to a Float.
@external(erlang, "erlang", "float")
fn term_to_float(x: Dynamic) -> Float

/// IEEE-754 bit pattern of `v` as an Int (a `TF64` argument / `ConstF64`).
@external(erlang, "twocore@runtime@porffor_abi", "float_to_bits")
fn float_bits(v: Float) -> Int

/// Decode an f64 bit pattern (a `TF64` result term) back to a Float.
@external(erlang, "twocore@runtime@porffor_abi", "f64_from_bits")
fn f64_from_bits(bits: Dynamic) -> Float

fn now_us() -> Int {
  monotonic_time(atom.create("microsecond"))
}

// ── Backends: how a JS number is represented + arithmetic lowered ────────────

/// A binding to emit as `Let([name], rhs, …)`, in evaluation order.
type Bind =
  #(String, ir.Expr)

/// A lowering target: the IR value type carrying a JS number, how a number literal
/// becomes a `Value` (possibly with `Let` bindings), and how a binary op lowers.
/// `binop` threads the fresh-name counter (the dynamic backend needs fresh guard
/// names) and returns the op expression + the advanced counter.
type Backend {
  Backend(
    ty: ir.ValType,
    lit: fn(Float, Int) -> #(List(Bind), ir.Value, Int),
    binop: fn(ast.BinaryOp, ir.Value, ir.Value, Int) -> #(ir.Expr, Int),
  )
}

/// Number-term path: an integer literal → a BEAM integer term (exact + fast); a
/// fractional literal → a float term. Arithmetic is `NumTerm` (`erlang:'+'` …).
fn term_backend() -> Backend {
  Backend(ty: ir.TTerm, lit: term_lit, binop: term_binop)
}

fn term_lit(v: Float, ctr: Int) -> #(List(Bind), ir.Value, Int) {
  let #(name, ctr) = fresh(ctr)
  let boxed = case int.to_float(float.truncate(v)) == v {
    True -> ir.Convert(ir.BoxInt(ir.W64), ir.ConstI64(float.truncate(v)))
    False -> ir.Convert(ir.BoxFloat(ir.FW64), ir.ConstF64(float_bits(v)))
  }
  #([#(name, boxed)], ir.Var(name), ctr)
}

fn term_binop(
  op: ast.BinaryOp,
  l: ir.Value,
  r: ir.Value,
  ctr: Int,
) -> #(ir.Expr, Int) {
  let e = case op {
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
  #(e, ctr)
}

/// Numeric f64 path: every JS number → an unboxed IEEE-754 double (`TF64`, a raw
/// bit pattern). A literal is a direct `ConstF64` value (no `Let`). Arithmetic is
/// `Num(F…(FW64))` via `rt_num` — real double semantics, exactly like arc.
fn numeric_backend() -> Backend {
  Backend(ty: ir.TF64, lit: numeric_lit, binop: numeric_binop)
}

fn numeric_lit(v: Float, ctr: Int) -> #(List(Bind), ir.Value, Int) {
  #([], ir.ConstF64(float_bits(v)), ctr)
}

fn numeric_binop(
  op: ast.BinaryOp,
  l: ir.Value,
  r: ir.Value,
  ctr: Int,
) -> #(ir.Expr, Int) {
  let e = case op {
    ast.Add -> ir.Num(ir.FAdd(ir.FW64), [l, r])
    ast.Subtract -> ir.Num(ir.FSub(ir.FW64), [l, r])
    ast.Multiply -> ir.Num(ir.FMul(ir.FW64), [l, r])
    ast.LessThan -> ir.Num(ir.FLt(ir.FW64), [l, r])
    ast.LessThanEqual -> ir.Num(ir.FLe(ir.FW64), [l, r])
    ast.GreaterThan -> ir.Num(ir.FGt(ir.FW64), [l, r])
    ast.GreaterThanEqual -> ir.Num(ir.FGe(ir.FW64), [l, r])
    ast.StrictEqual -> ir.Num(ir.FEq(ir.FW64), [l, r])
    _ -> panic as "js-spike: unsupported binary operator"
  }
  #(e, ctr)
}

/// Native-float-term path (the hypothesis): a JS number literal → a NATIVE BEAM
/// `float()` term (the new `ir.ConstFloatTerm`), so `NumTerm`'s `erlang:'+'` does
/// native double arithmetic — no per-op bit box/unbox. Real doubles, and (if the
/// hypothesis holds) as fast as the integer-term path.
fn native_float_backend() -> Backend {
  Backend(ty: ir.TTerm, lit: native_float_lit, binop: term_binop)
}

fn native_float_lit(v: Float, ctr: Int) -> #(List(Bind), ir.Value, Int) {
  #([], ir.ConstFloatTerm(v), ctr)
}

/// Dynamic path — polymorphic JS. Each `+`/`-`/`*` compiles to a GUARDED dispatch:
/// `if IsNumber(a) && IsNumber(b) then NumTerm(fast native arithmetic) else
/// CallHost("js", op, [a, b])` — the `rt_js` cold path with REAL JS semantics
/// (string concat, coercion, NaN/Infinity). Number literals are native BEAM floats
/// (so the both-number path is the native-float fast path); the guard is a cheap
/// `erlang:is_number` BIF. Comparisons stay on the numeric fast path (a loop
/// condition is numeric, and both arms of a guarded compare would be i32).
fn dynamic_backend() -> Backend {
  Backend(ty: ir.TTerm, lit: native_float_lit, binop: dynamic_binop)
}

fn dynamic_binop(
  op: ast.BinaryOp,
  l: ir.Value,
  r: ir.Value,
  ctr: Int,
) -> #(ir.Expr, Int) {
  case op {
    // `+`/`-`/`*` are polymorphic in JS (`+` also concatenates): guard them.
    ast.Add | ast.Subtract | ast.Multiply -> {
      let #(ga, ctr) = fresh(ctr)
      let #(gb, ctr) = fresh(ctr)
      let #(fast, ctr) = term_binop(op, l, r, ctr)
      let slow = ir.CallHost("js", js_op_name(op), [l, r])
      let guarded =
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
      #(guarded, ctr)
    }
    // Comparisons: the numeric fast path (→ i32 truth for the loop `If`).
    _ -> term_binop(op, l, r, ctr)
  }
}

/// The `rt_js` cold-path op name for a guarded arithmetic operator.
fn js_op_name(op: ast.BinaryOp) -> String {
  case op {
    ast.Add -> "add"
    ast.Subtract -> "sub"
    ast.Multiply -> "mul"
    _ -> panic as "js-spike: no rt_js op for this operator"
  }
}

// ── The lowering: arc AST → 2core IR ────────────────────────────────────────

/// Fold ordered bindings into nested `Let`s around `body` (first binding outermost).
fn emit_lets(binds: List(Bind), body: ir.Expr) -> ir.Expr {
  list.fold_right(binds, body, fn(acc, b) { ir.Let([b.0], b.1, acc) })
}

fn fresh(ctr: Int) -> #(String, Int) {
  #("t" <> int.to_string(ctr), ctr + 1)
}

/// Lower a JS expression to ANF: the ordered `Let` bindings its evaluation needs,
/// plus the atomic `Value` naming its result. `env` maps a live JS variable to the
/// IR `Value` holding its current SSA binding.
fn lower_expr(
  be: Backend,
  e: ast.Expression,
  env: Dict(String, ir.Value),
  ctr: Int,
) -> #(List(Bind), ir.Value, Int) {
  case e {
    ast.NumberLiteral(value: v, ..) -> be.lit(v, ctr)
    ast.Identifier(name: x, ..) ->
      case dict.get(env, x) {
        Ok(v) -> #([], v, ctr)
        Error(_) -> panic as { "js-spike: unbound identifier '" <> x <> "'" }
      }
    ast.BinaryExpression(operator: op, left: l, right: r, ..) -> {
      let #(bl, vl, ctr) = lower_expr(be, l, env, ctr)
      let #(br, vr, ctr) = lower_expr(be, r, env, ctr)
      let #(op_expr, ctr) = be.binop(op, vl, vr, ctr)
      let #(name, ctr) = fresh(ctr)
      let binds = list.flatten([bl, br, [#(name, op_expr)]])
      #(binds, ir.Var(name), ctr)
    }
    _ -> panic as "js-spike: unsupported expression"
  }
}

/// Lower a statement list (a function body) to a single IR expression. Each
/// `let`/assignment threads the updated `env` forward; a `for` loop and `return`
/// build structured control. The list is expected to end in `return`.
fn lower_stmts(
  be: Backend,
  stmts: List(ast.Statement),
  env: Dict(String, ir.Value),
  ctr: Int,
) -> #(ir.Expr, Int) {
  case stmts {
    [] -> #(ir.Values([]), ctr)
    [stmt, ..rest] ->
      case stmt {
        ast.ReturnStatement(argument: Some(e)) -> {
          let #(binds, val, ctr) = lower_expr(be, e, env, ctr)
          #(emit_lets(binds, ir.Values([val])), ctr)
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
          let #(binds, val, ctr) = lower_expr(be, e, env, ctr)
          let #(body, ctr) =
            lower_stmts(be, rest, dict.insert(env, x, val), ctr)
          #(emit_lets(binds, body), ctr)
        }

        ast.ExpressionStatement(
          expression: ast.AssignmentExpression(
            operator: ast.Assign,
            left: ast.Identifier(name: x, ..),
            right: e,
            ..,
          ),
          ..,
        ) -> {
          let #(binds, val, ctr) = lower_expr(be, e, env, ctr)
          let #(body, ctr) =
            lower_stmts(be, rest, dict.insert(env, x, val), ctr)
          #(emit_lets(binds, body), ctr)
        }

        ast.ForStatement(init:, condition:, update:, body:) ->
          lower_for(be, init, condition, update, body, rest, env, ctr)

        _ -> panic as "js-spike: unsupported statement"
      }
  }
}

/// Lower a counted `for (let iv = e0; cond; upd) { body }`. The loop-carried
/// variables are `iv` plus every variable the body/update reassigns that is live
/// on entry. Each becomes a `LoopParam`; `Continue` re-enters with their updated
/// values, `Break` exits yielding them, and the code after the loop rebinds them.
fn lower_for(
  be: Backend,
  init: option.Option(ast.ForInit),
  condition: option.Option(ast.Expression),
  update: option.Option(ast.Expression),
  body: ast.Statement,
  rest: List(ast.Statement),
  env: Dict(String, ir.Value),
  ctr: Int,
) -> #(ir.Expr, Int) {
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

  let extern =
    list.append(collect_assigned(body_stmts), assigned_of(upd_expr))
    |> list.unique
    |> list.filter(fn(v) { v != iv && dict.has_key(env, v) })
  let carried = [iv, ..extern]

  let #(iv_binds, iv_init, ctr) = lower_expr(be, e0, env, ctr)
  let inits =
    list.map(carried, fn(v) {
      case v == iv {
        True -> iv_init
        False -> dict_get(env, v)
      }
    })
  let params =
    list.map2(carried, inits, fn(v, initv) { ir.LoopParam(v, be.ty, initv) })

  let loop_env =
    list.fold(carried, env, fn(acc, v) { dict.insert(acc, v, ir.Var(v)) })
  let result_tys = list.map(carried, fn(_) { be.ty })

  let #(cond_binds, cond_val, ctr) = lower_expr(be, cond_expr, loop_env, ctr)

  let #(body_env, body_lets, ctr) = lower_seq(be, body_stmts, loop_env, ctr)
  let #(upd_env, upd_lets, ctr) = lower_assign(be, upd_expr, body_env, ctr)
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

  let after = list.map(carried, fn(v) { v <> "_after" })
  let env_after =
    list.fold(list.zip(carried, after), env, fn(acc, pair) {
      dict.insert(acc, pair.0, ir.Var(pair.1))
    })
  let #(rest_expr, ctr) = lower_stmts(be, rest, env_after, ctr)
  #(emit_lets(iv_binds, ir.Let(after, loop, rest_expr)), ctr)
}

/// Lower a straight-line loop body (`let`/assignments only), returning the final
/// env, the ordered bindings, and the counter.
fn lower_seq(
  be: Backend,
  stmts: List(ast.Statement),
  env: Dict(String, ir.Value),
  ctr: Int,
) -> #(Dict(String, ir.Value), List(Bind), Int) {
  list.fold(stmts, #(env, [], ctr), fn(acc, stmt) {
    let #(env, binds, ctr) = acc
    case stmt {
      ast.ExpressionStatement(expression: a, ..) -> {
        let #(env, more, ctr) = lower_assign(be, a, env, ctr)
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
        let #(more, val, ctr) = lower_expr(be, e, env, ctr)
        #(dict.insert(env, x, val), list.append(binds, more), ctr)
      }
      _ -> panic as "js-spike: unsupported statement in loop body"
    }
  })
}

/// Lower `x = e` — the ordered bindings for `e`, and env updated so `x` → e's value.
fn lower_assign(
  be: Backend,
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
      let #(binds, val, ctr) = lower_expr(be, rhs, env, ctr)
      #(dict.insert(env, x, val), binds, ctr)
    }
    _ -> panic as "js-spike: unsupported assignment"
  }
}

fn collect_assigned(stmts: List(ast.Statement)) -> List(String) {
  list.flat_map(stmts, fn(s) {
    case s {
      ast.ExpressionStatement(expression: a, ..) -> assigned_of(a)
      _ -> []
    }
  })
}

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

/// Parse one top-level `function name(params){ body }` and lower it under `be` to
/// an IR module exporting `name`. `tag` uniquely names the emitted BEAM module
/// (two compiles of the same function must NOT collide on `twocore@js@name`).
fn compile_js(be: Backend, tag: String, src: String) -> #(ir.Module, String) {
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
  let #(body_expr, _ctr) = lower_stmts(be, block_stmts(fn_body), env0, 0)

  let func =
    ir.Function(
      name: fn_name,
      params: list.map(param_names, fn(n) { ir.Local(n, be.ty) }),
      result: [be.ty],
      locals: [],
      body: body_expr,
    )
  let m =
    ir.Module(
      name: "twocore@js@" <> tag,
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

/// Compile a JS function under a backend; return #(module_atom, fn_atom).
fn jit(be: Backend, tag: String, src: String) -> #(Atom, Atom) {
  let #(m, fn_name) = compile_js(be, tag, src)
  #(load(m), atom.create(fn_name))
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// The whole pipeline on the simplest function: arc parses `add`, we lower it to
/// `NumTerm(NAdd)`, compile to BEAM, and it computes on real BEAM number terms.
pub fn add_compiles_and_runs_test() {
  let #(mod, f) =
    jit(term_backend(), "add", "function add(a, b) { return a + b; }")
  catch_apply_dyn(mod, f, [to_dynamic(2), to_dynamic(3)])
  |> should.equal(Ok(to_dynamic(5)))
  // Compiled arithmetic follows BEAM number-term rules (int + float → float).
  catch_apply_dyn(mod, f, [to_dynamic(2), to_dynamic(0.5)])
  |> should.equal(Ok(to_dynamic(2.5)))
}

/// The counted loop compiles on BOTH backends and computes the right sum — proving
/// loop-carried params, `Continue`/`Break`, and the `<`/`+` ops end-to-end for the
/// integer-term path AND the numeric f64 path (real doubles).
pub fn sum_loop_compiles_and_runs_test() {
  let src =
    "function sum(n) { let s = 0; for (let i = 0; i < n; i = i + 1) { s = s + i; } return s; }"

  let #(imod, i_f) = jit(term_backend(), "sumt", src)
  let assert Ok(ir_) = catch_apply_dyn(imod, i_f, [to_dynamic(10)])
  term_to_float(ir_) |> should.equal(45.0)

  let #(fmod, f_f) = jit(numeric_backend(), "sumn", src)
  let assert Ok(fr) = catch_apply_dyn(fmod, f_f, [to_dynamic(float_bits(10.0))])
  f64_from_bits(fr) |> should.equal(45.0)

  // Native-float term path: a real BEAM float() result, via NumTerm on native doubles.
  let #(nmod, n_f) = jit(native_float_backend(), "sumnfc", src)
  let assert Ok(nr) = catch_apply_dyn(nmod, n_f, [to_dynamic(10.0)])
  term_to_float(nr) |> should.equal(45.0)
}

/// POLYMORPHISM: the dynamic backend compiles ONE `a + b` that dispatches at
/// runtime — the native fast path for numbers, and the `rt_js` cold path (REAL JS
/// semantics: concat, coercion) for strings / mixed operands. Proves 2core compiles
/// dynamic JS, not just monomorphic numeric kernels.
pub fn dynamic_polymorphism_test() {
  let #(mod, f) =
    jit(dynamic_backend(), "poly", "function poly(a, b) { return a + b; }")

  // both numbers → guard true → native NumTerm(NAdd) fast path.
  let assert Ok(nn) =
    catch_apply_dyn(mod, f, [to_dynamic(2.0), to_dynamic(3.0)])
  term_to_float(nn) |> should.equal(5.0)

  // both strings → guard false → rt_js cold path → real JS string concat.
  catch_apply_dyn(mod, f, [to_dynamic(<<"a">>), to_dynamic(<<"b">>)])
  |> should.equal(Ok(to_dynamic(<<"ab">>)))

  // number + string → cold path → rt_js coercion (`2 + "x"` → `"2x"`).
  catch_apply_dyn(mod, f, [to_dynamic(2.0), to_dynamic(<<"x">>)])
  |> should.equal(Ok(to_dynamic(<<"2x">>)))
}

/// BENCHMARK: AOT-compiled `sum(n)` vs arc's bytecode VM on the same JS. Compiles
/// TWO paths — integer-term and numeric f64 (arc's own double semantics) — so the
/// f64 row is a clean apples-to-apples compiled-vs-interpreted comparison. Asserts
/// every path computes the same value. Times execution only (compile done once).
pub fn sum_vs_arc_benchmark_test() {
  let n = 1_000_000
  let nf = int.to_float(n)
  let src =
    "function sum(n) { let s = 0; for (let i = 0; i < n; i = i + 1) { s = s + i; } return s; }"
  let expected = 499_999_500_000.0

  let #(imod, i_f) = jit(term_backend(), "sumi", src)
  let #(fmod, f_f) = jit(numeric_backend(), "sumf", src)
  let #(nmod, n_f) = jit(native_float_backend(), "sumnf", src)
  let #(dmod, d_f) = jit(dynamic_backend(), "sumd", src)
  let int_arg = [to_dynamic(n)]
  let f64_arg = [to_dynamic(float_bits(nf))]
  let nf_arg = [to_dynamic(nf)]
  let dyn_arg = [to_dynamic(nf)]

  let eng = engine.new()
  let arc_src =
    "(function(n){let s=0;for(let i=0;i<n;i=i+1){s=s+i;}return s;})("
    <> int.to_string(n)
    <> ")"

  // Warm up.
  let _ = catch_apply_dyn(imod, i_f, int_arg)
  let _ = catch_apply_dyn(fmod, f_f, f64_arg)
  let _ = catch_apply_dyn(nmod, n_f, nf_arg)
  let _ = catch_apply_dyn(dmod, d_f, dyn_arg)
  let _ = arc_eval(eng, arc_src)

  let reps = 25
  let int_us = best_us(reps, fn() { catch_apply_dyn(imod, i_f, int_arg) })
  let f64_us = best_us(reps, fn() { catch_apply_dyn(fmod, f_f, f64_arg) })
  let nf_us = best_us(reps, fn() { catch_apply_dyn(nmod, n_f, nf_arg) })
  let dyn_us = best_us(reps, fn() { catch_apply_dyn(dmod, d_f, dyn_arg) })
  let arc_us = best_us(reps, fn() { arc_eval(eng, arc_src) })

  // Correctness gate: every path computes the same value.
  let assert Ok(ir_) = catch_apply_dyn(imod, i_f, int_arg)
  let assert Ok(fr) = catch_apply_dyn(fmod, f_f, f64_arg)
  let assert Ok(nr) = catch_apply_dyn(nmod, n_f, nf_arg)
  let assert Ok(dr) = catch_apply_dyn(dmod, d_f, dyn_arg)
  term_to_float(ir_) |> should.equal(expected)
  f64_from_bits(fr) |> should.equal(expected)
  term_to_float(nr) |> should.equal(expected)
  term_to_float(dr) |> should.equal(expected)
  arc_eval(eng, arc_src) |> should.equal(expected)

  io.println("")
  io.println("── JS→2core-IR vs arc (sum 0..999999, best of 25) ──")
  io.println("  2core int-term     : " <> int.to_string(int_us) <> " us")
  io.println("  2core f64 (raw-bit): " <> int.to_string(f64_us) <> " us")
  io.println("  2core native-float : " <> int.to_string(nf_us) <> " us")
  io.println(
    "  2core DYNAMIC      : "
    <> int.to_string(dyn_us)
    <> " us  (polymorphic: IsNumber guard → native, else rt_js)",
  )
  io.println("  arc bytecode VM    : " <> int.to_string(arc_us) <> " us")
  io.println("  speedup int          : " <> ratio(arc_us, int_us) <> "x")
  io.println("  speedup native-float : " <> ratio(arc_us, nf_us) <> "x")
  io.println(
    "  speedup DYNAMIC      : "
    <> ratio(arc_us, dyn_us)
    <> "x   <- polymorphic JS vs arc",
  )
  io.println("  guard overhead (dyn/native) : " <> ratio(dyn_us, nf_us) <> "x")
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
