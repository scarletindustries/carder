//// End-to-end tests for `twocore/frontend/js`: compile real JS to BEAM and assert
//// the results against JS semantics. Each test compiles a small program, applies an
//// exported function, and checks the returned BEAM term.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleeunit/should
import twocore/frontend/js

@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply(m: Atom, f: Atom, args: List(Dynamic)) -> Result(Dynamic, String)

@external(erlang, "gleam_stdlib", "identity")
fn dyn(x: a) -> Dynamic

@external(erlang, "erlang", "float")
fn to_float(x: Dynamic) -> Float

// A monotonically-increasing tag so each compiled program gets a unique module atom.
@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

fn compile(src: String) -> Atom {
  let name = "twocore@jstest@m" <> int.to_string(int_abs(unique()))
  let assert Ok(m) = js.compile_and_load(src, name)
  m
}

fn int_abs(n: Int) -> Int {
  case n < 0 {
    True -> 0 - n
    False -> n
  }
}

fn call(m: Atom, f: String, args: List(Dynamic)) -> Dynamic {
  let assert Ok(r) = catch_apply(m, atom.create(f), args)
  r
}

/// Compile `function f(){ return <expr>; }` and evaluate it, as a Float.
fn num(expr: String) -> Float {
  let m = compile("function f() { return " <> expr <> "; }")
  to_float(call(m, "f", []))
}

// ── arithmetic + precedence ──────────────────────────────────────────────────

pub fn arithmetic_test() {
  num("2 + 3") |> should.equal(5.0)
  num("2 * 3 + 4") |> should.equal(10.0)
  num("2 + 3 * 4") |> should.equal(14.0)
  num("(2 + 3) * 4") |> should.equal(20.0)
  num("10 - 3 - 2") |> should.equal(5.0)
  num("7 / 2") |> should.equal(3.5)
  num("7 % 3") |> should.equal(1.0)
  num("-5 + 2") |> should.equal(-3.0)
  num("1.5 + 2.5") |> should.equal(4.0)
}

pub fn args_test() {
  let m = compile("function add(a, b) { return a + b; }")
  to_float(call(m, "add", [dyn(2), dyn(3)])) |> should.equal(5.0)
  to_float(call(m, "add", [dyn(2.5), dyn(0.5)])) |> should.equal(3.0)
}

// ── strings + coercion (the rt_js cold path) ─────────────────────────────────

pub fn strings_test() {
  let m = compile("function cat(a, b) { return a + b; }")
  call(m, "cat", [dyn(<<"a">>), dyn(<<"b">>)])
  |> should.equal(dyn(<<"ab">>))
  // number + string → coercion
  call(m, "cat", [dyn(2), dyn(<<"x">>)])
  |> should.equal(dyn(<<"2x">>))
}

pub fn string_literal_test() {
  let m = compile("function f() { return \"hello\"; }")
  call(m, "f", []) |> should.equal(dyn(<<"hello">>))
}

pub fn template_literal_test() {
  let m = compile("function greet(n) { return `hi ${n}!`; }")
  call(m, "greet", [dyn(<<"bob">>)]) |> should.equal(dyn(<<"hi bob!">>))
  call(m, "greet", [dyn(3)]) |> should.equal(dyn(<<"hi 3!">>))
}

// ── booleans / comparisons / logical ─────────────────────────────────────────

pub fn comparisons_test() {
  let m = compile("function lt(a, b) { return a < b; }")
  call(m, "lt", [dyn(1), dyn(2)]) |> should.equal(dyn(True))
  call(m, "lt", [dyn(2), dyn(1)]) |> should.equal(dyn(False))
}

pub fn equality_test() {
  let m = compile("function eq(a, b) { return a === b; }")
  call(m, "eq", [dyn(1), dyn(1)]) |> should.equal(dyn(True))
  call(m, "eq", [dyn(1), dyn(2)]) |> should.equal(dyn(False))
  let n = compile("function ne(a, b) { return a !== b; }")
  call(n, "ne", [dyn(1), dyn(2)]) |> should.equal(dyn(True))
}

pub fn logical_test() {
  // && / || return operands (JS value semantics)
  let m = compile("function f(a, b) { return a && b; }")
  to_float(call(m, "f", [dyn(1), dyn(5)])) |> should.equal(5.0)
  let o = compile("function f(a, b) { return a || b; }")
  to_float(call(o, "f", [dyn(0), dyn(7)])) |> should.equal(7.0)
}

pub fn unary_test() {
  let m = compile("function f(x) { return !x; }")
  call(m, "f", [dyn(0)]) |> should.equal(dyn(True))
  call(m, "f", [dyn(1)]) |> should.equal(dyn(False))
  let t = compile("function ty(x) { return typeof x; }")
  call(t, "ty", [dyn(1)]) |> should.equal(dyn(<<"number">>))
  call(t, "ty", [dyn(<<"s">>)]) |> should.equal(dyn(<<"string">>))
}

pub fn ternary_test() {
  let m = compile("function f(x) { return x > 0 ? 1 : -1; }")
  to_float(call(m, "f", [dyn(5)])) |> should.equal(1.0)
  to_float(call(m, "f", [dyn(-5)])) |> should.equal(-1.0)
}

// ── control flow with mutation ───────────────────────────────────────────────

pub fn if_mutation_test() {
  let m =
    compile(
      "function f(x) { let y = 0; if (x > 0) { y = 1; } else { y = 2; } return y; }",
    )
  to_float(call(m, "f", [dyn(5)])) |> should.equal(1.0)
  to_float(call(m, "f", [dyn(-5)])) |> should.equal(2.0)
}

pub fn while_test() {
  let m =
    compile(
      "function sum(n) { let s = 0; let i = 0; while (i < n) { s = s + i; i = i + 1; } return s; }",
    )
  to_float(call(m, "sum", [dyn(5)])) |> should.equal(10.0)
  to_float(call(m, "sum", [dyn(100)])) |> should.equal(4950.0)
}

pub fn for_test() {
  let m =
    compile(
      "function sum(n) { let s = 0; for (let i = 0; i < n; i = i + 1) { s = s + i; } return s; }",
    )
  to_float(call(m, "sum", [dyn(5)])) |> should.equal(10.0)
}

pub fn for_compound_assign_test() {
  let m =
    compile(
      "function sum(n) { let s = 0; for (let i = 0; i < n; i += 1) { s += i; } return s; }",
    )
  to_float(call(m, "sum", [dyn(10)])) |> should.equal(45.0)
}

pub fn break_continue_test() {
  // sum evens below n, break at 20
  let m =
    compile(
      "function f(n) { let s = 0; let i = 0; while (i < n) { i = i + 1; if (i > 20) { break; } if (i % 2 === 1) { continue; } s = s + i; } return s; }",
    )
  // evens 2..20 = 2+4+...+20 = 110
  to_float(call(m, "f", [dyn(1000)])) |> should.equal(110.0)
}

pub fn nested_loop_test() {
  let m =
    compile(
      "function f(n) { let t = 0; let i = 0; while (i < n) { let j = 0; while (j < n) { t = t + 1; j = j + 1; } i = i + 1; } return t; }",
    )
  to_float(call(m, "f", [dyn(4)])) |> should.equal(16.0)
}

// ── functions: recursion + mutual recursion ──────────────────────────────────

pub fn recursion_test() {
  let m =
    compile(
      "function fib(n) { if (n < 2) { return n; } return fib(n - 1) + fib(n - 2); }",
    )
  to_float(call(m, "fib", [dyn(10)])) |> should.equal(55.0)
  to_float(call(m, "fib", [dyn(20)])) |> should.equal(6765.0)
}

pub fn mutual_recursion_test() {
  let m =
    compile(
      "function isEven(n) { if (n === 0) { return true; } return isOdd(n - 1); } function isOdd(n) { if (n === 0) { return false; } return isEven(n - 1); }",
    )
  call(m, "isEven", [dyn(10)]) |> should.equal(dyn(True))
  call(m, "isEven", [dyn(7)]) |> should.equal(dyn(False))
}

pub fn call_between_functions_test() {
  let m =
    compile(
      "function square(x) { return x * x; } function sumSquares(a, b) { return square(a) + square(b); }",
    )
  to_float(call(m, "sumSquares", [dyn(3), dyn(4)])) |> should.equal(25.0)
}

// ── objects ──────────────────────────────────────────────────────────────────

pub fn object_test() {
  let m = compile("function f() { let o = { a: 1, b: 2 }; return o.a + o.b; }")
  to_float(call(m, "f", [])) |> should.equal(3.0)
}

pub fn object_mutate_test() {
  let m =
    compile(
      "function f() { let o = { x: 1 }; o.x = 10; o.y = 5; return o.x + o.y; }",
    )
  to_float(call(m, "f", [])) |> should.equal(15.0)
}

pub fn object_computed_test() {
  let m =
    compile(
      "function get(o, k) { return o[k]; } function f() { let o = { a: 42 }; return get(o, \"a\"); }",
    )
  to_float(call(m, "f", [])) |> should.equal(42.0)
}

// ── correctness regressions (from the lowering review) ───────────────────────

pub fn for_continue_runs_update_test() {
  // JS `continue` in a `for` loop MUST run the update — otherwise `i` never advances
  // and the loop spins forever. Sum the ODD `i` in [0, n).
  let m =
    compile(
      "function f(n) { let s = 0; for (let i = 0; i < n; i = i + 1) { if (i % 2 === 0) { continue; } s = s + i; } return s; }",
    )
  // 1 + 3 + 5 + 7 + 9 = 25
  to_float(call(m, "f", [dyn(10)])) |> should.equal(25.0)
}

pub fn unary_plus_coercion_test() {
  // `+x` is ToNumber(x): "5"→5, true→1, ""→0; and its type is "number".
  num("+\"5\" + 1") |> should.equal(6.0)
  num("+true") |> should.equal(1.0)
  num("+\"\"") |> should.equal(0.0)
  let t = compile("function ty(x) { return typeof +x; }")
  call(t, "ty", [dyn(<<"5">>)]) |> should.equal(dyn(<<"number">>))
}

pub fn chained_assignment_test() {
  // `x = y = 5` assigns 5 to BOTH x and y (every target in the chain).
  let m =
    compile("function f() { let x = 0; let y = 0; x = y = 5; return x + y; }")
  to_float(call(m, "f", [])) |> should.equal(10.0)
  let y = compile("function f() { let x = 0; let y = 0; x = y = 5; return y; }")
  to_float(call(y, "f", [])) |> should.equal(5.0)
}

pub fn do_while_runs_once_test() {
  // The body runs once even when the condition is initially false.
  let m =
    compile(
      "function f() { let x = 0; do { x = x + 1; } while (x < 0); return x; }",
    )
  to_float(call(m, "f", [])) |> should.equal(1.0)
  // …and iterates normally otherwise: sum 0..n-1.
  let s =
    compile(
      "function f(n) { let s = 0; let i = 0; do { s = s + i; i = i + 1; } while (i < n); return s; }",
    )
  to_float(call(s, "f", [dyn(5)])) |> should.equal(10.0)
}

pub fn compound_member_assign_test() {
  // `o.p op= e` and computed `o[k] op= e` compute correctly.
  let m = compile("function f() { let o = { x: 10 }; o.x += 5; return o.x; }")
  to_float(call(m, "f", [])) |> should.equal(15.0)
  let c =
    compile("function f() { let o = { a: 3 }; o[\"a\"] *= 4; return o.a; }")
  to_float(call(c, "f", [])) |> should.equal(12.0)
}

pub fn compound_member_single_eval_test() {
  // The object/computed key of a compound member assignment is evaluated EXACTLY
  // once — a side-effecting key must not run twice (double-eval would yield 2015).
  let m =
    compile(
      "function bump(c) { c.n = c.n + 1; return \"v\"; } function f() { let c = { n: 0 }; let o = { v: 10 }; o[bump(c)] += 5; return c.n * 1000 + o.v; }",
    )
  to_float(call(m, "f", [])) |> should.equal(1015.0)
}

// ── increment / decrement / void ─────────────────────────────────────────────

pub fn increment_decrement_test() {
  // As statements: x is updated in the env.
  let m = compile("function f() { let x = 5; x++; x++; return x; }")
  to_float(call(m, "f", [])) |> should.equal(7.0)
  let d = compile("function f() { let x = 5; x--; return x; }")
  to_float(call(d, "f", [])) |> should.equal(4.0)
  // Prefix as a value yields the NEW value.
  let p = compile("function f() { let x = 5; return ++x; }")
  to_float(call(p, "f", [])) |> should.equal(6.0)
}

pub fn for_loop_increment_test() {
  // The idiomatic `i++` for-loop update.
  let m =
    compile(
      "function sum(n) { let s = 0; for (let i = 0; i < n; i++) { s += i; } return s; }",
    )
  to_float(call(m, "sum", [dyn(5)])) |> should.equal(10.0)
  to_float(call(m, "sum", [dyn(100)])) |> should.equal(4950.0)
}

pub fn void_test() {
  let m = compile("function f() { return void 5; }")
  call(m, "f", []) |> should.equal(dyn(atom.create("undefined")))
}

// ── bitwise / shift (int32 semantics) ────────────────────────────────────────

pub fn bitwise_test() {
  num("5 & 3") |> should.equal(1.0)
  num("5 | 2") |> should.equal(7.0)
  num("5 ^ 1") |> should.equal(4.0)
  num("~5") |> should.equal(-6.0)
  // ToInt32 coercion of a string operand.
  num("\"5\" & 3") |> should.equal(1.0)
}

pub fn shift_test() {
  num("1 << 4") |> should.equal(16.0)
  num("1 << 31") |> should.equal(-2_147_483_648.0)
  num("-8 >> 1") |> should.equal(-4.0)
  // `>>>` is a zero-fill shift on a uint32.
  num("-1 >>> 28") |> should.equal(15.0)
  num("-1 >>> 0") |> should.equal(4_294_967_295.0)
}

pub fn bitwise_compound_test() {
  let m = compile("function f() { let x = 12; x &= 10; return x; }")
  to_float(call(m, "f", [])) |> should.equal(8.0)
  let s = compile("function f() { let x = 1; x <<= 5; return x; }")
  to_float(call(s, "f", [])) |> should.equal(32.0)
}

// ── top-level main ───────────────────────────────────────────────────────────

pub fn main_test() {
  let m = compile("let x = 10; let y = 20;")
  // main returns undefined; just assert it runs without error.
  call(m, "main", []) |> should.equal(dyn(atom.create("undefined")))
}
