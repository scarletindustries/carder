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

// ── exponentiation ───────────────────────────────────────────────────────────

pub fn exponentiation_test() {
  num("2 ** 10") |> should.equal(1024.0)
  num("2 ** 0") |> should.equal(1.0)
  num("2 ** -1") |> should.equal(0.5)
  num("9 ** 0.5") |> should.equal(3.0)
  // right-associative: 2 ** 3 ** 2 == 2 ** 9 == 512
  num("2 ** 3 ** 2") |> should.equal(512.0)
  let m = compile("function f() { let x = 3; x **= 2; return x; }")
  to_float(call(m, "f", [])) |> should.equal(9.0)
  // Negative base with a non-integer exponent is NaN (NaN !== NaN).
  let n = compile("function f() { let r = (-8) ** (1 / 3); return r !== r; }")
  call(n, "f", []) |> should.equal(dyn(True))
}

// ── arrays ───────────────────────────────────────────────────────────────────

pub fn array_literal_test() {
  let m = compile("function f() { let a = [10, 20, 30]; return a[0] + a[2]; }")
  to_float(call(m, "f", [])) |> should.equal(40.0)
}

pub fn array_length_test() {
  let m = compile("function f() { let a = [1, 2, 3]; return a.length; }")
  to_float(call(m, "f", [])) |> should.equal(3.0)
  // empty array
  let e = compile("function f() { let a = []; return a.length; }")
  to_float(call(e, "f", [])) |> should.equal(0.0)
}

pub fn array_index_assign_test() {
  let m = compile("function f() { let a = [1, 2, 3]; a[1] = 99; return a[1]; }")
  to_float(call(m, "f", [])) |> should.equal(99.0)
  // assigning past the end grows length.
  let g = compile("function f() { let a = []; a[2] = 5; return a.length; }")
  to_float(call(g, "f", [])) |> should.equal(3.0)
}

pub fn array_push_pop_test() {
  // push returns the new length.
  let p = compile("function f() { let a = [1]; return a.push(9); }")
  to_float(call(p, "f", [])) |> should.equal(2.0)
  // pop returns the removed element and shrinks length.
  let m =
    compile(
      "function f() { let a = [1, 2, 3]; let x = a.pop(); return x * 10 + a.length; }",
    )
  to_float(call(m, "f", [])) |> should.equal(32.0)
}

pub fn array_build_loop_test() {
  let m =
    compile(
      "function f(n) { let a = []; for (let i = 0; i < n; i++) { a.push(i * i); } let s = 0; for (let j = 0; j < a.length; j++) { s += a[j]; } return s; }",
    )
  // sum of squares 0..4 = 0+1+4+9+16 = 30
  to_float(call(m, "f", [dyn(5)])) |> should.equal(30.0)
}

pub fn array_nested_test() {
  let m = compile("function f() { let a = [[1, 2], [3, 4]]; return a[1][0]; }")
  to_float(call(m, "f", [])) |> should.equal(3.0)
}

pub fn array_typeof_and_string_test() {
  // typeof [] is "object"
  let t = compile("function f() { return typeof [1, 2]; }")
  call(t, "f", []) |> should.equal(dyn(<<"object">>))
  // String(array) joins with commas
  let s = compile("function f() { let a = [1, 2, 3]; return \"\" + a; }")
  call(s, "f", []) |> should.equal(dyn(<<"1,2,3">>))
}

// ── closures / first-class functions ─────────────────────────────────────────

pub fn arrow_no_capture_test() {
  let m = compile("function f() { let g = x => x * 2; return g(21); }")
  to_float(call(m, "f", [])) |> should.equal(42.0)
}

pub fn function_expression_test() {
  let m =
    compile(
      "function f() { let add = function(a, b) { return a + b; }; return add(3, 4); }",
    )
  to_float(call(m, "f", [])) |> should.equal(7.0)
}

pub fn arrow_capture_test() {
  // captures the immutable parameter `n`
  let m = compile("function f(n) { let g = x => x + n; return g(10); }")
  to_float(call(m, "f", [dyn(5)])) |> should.equal(15.0)
}

pub fn higher_order_test() {
  // pass a closure to another function that applies it twice
  let m =
    compile(
      "function twice(f, x) { return f(f(x)); } function run() { return twice(n => n + 3, 10); }",
    )
  to_float(call(m, "run", [])) |> should.equal(16.0)
}

pub fn iife_test() {
  let m = compile("function f() { return (x => x + 1)(41); }")
  to_float(call(m, "f", [])) |> should.equal(42.0)
}

pub fn returned_closure_test() {
  // `adder` returns a closure capturing its parameter
  let m =
    compile(
      "function adder(n) { return x => x + n; } function run() { let add5 = adder(5); return add5(10); }",
    )
  to_float(call(m, "run", [])) |> should.equal(15.0)
}

pub fn nested_closure_test() {
  // curried: f(1)(2)(3) === 6
  let m =
    compile(
      "function f(a) { return b => (c => a + b + c); } function run() { return f(1)(2)(3); }",
    )
  to_float(call(m, "run", [])) |> should.equal(6.0)
}

pub fn closure_over_mutable_object_test() {
  // capturing an array (a stable ref) is fine — the ref is shared, so pushes through
  // the closure are visible. Only reassigning a captured VARIABLE is rejected.
  let m =
    compile(
      "function f() { let acc = []; let add = x => acc.push(x); add(1); add(2); add(3); return acc.length; }",
    )
  to_float(call(m, "f", [])) |> should.equal(3.0)
}

pub fn closure_rejects_reassigned_capture_test() {
  // value-capture of a reassigned variable would be unsound, so it is rejected.
  let r =
    js.compile_and_load(
      "function f() { let n = 0; let g = () => n; n = 5; return g(); }",
      "twocore@jstest@rej" <> int.to_string(int_abs(unique())),
    )
  case r {
    Error(_) -> Nil
    Ok(_) -> panic as "expected closure over reassigned variable to be rejected"
  }
}

// ── for-of ───────────────────────────────────────────────────────────────────

pub fn for_of_test() {
  let m =
    compile(
      "function f() { let s = 0; for (let x of [10, 20, 30]) { s += x; } return s; }",
    )
  to_float(call(m, "f", [])) |> should.equal(60.0)
}

pub fn for_of_break_continue_test() {
  let b =
    compile(
      "function f() { let s = 0; for (let x of [1, 2, 3, 4, 5]) { if (x > 3) { break; } s += x; } return s; }",
    )
  to_float(call(b, "f", [])) |> should.equal(6.0)
  let c =
    compile(
      "function f() { let s = 0; for (let x of [1, 2, 3, 4]) { if (x % 2 === 0) { continue; } s += x; } return s; }",
    )
  to_float(call(c, "f", [])) |> should.equal(4.0)
}

pub fn for_of_build_test() {
  let m =
    compile(
      "function f() { let arr = [1, 2, 3]; let out = []; for (let x of arr) { out.push(x * x); } return out[2]; }",
    )
  to_float(call(m, "f", [])) |> should.equal(9.0)
}

pub fn for_of_nested_test() {
  let m =
    compile(
      "function f() { let s = 0; for (let a of [1, 2]) { for (let b of [10, 20]) { s += a * b; } } return s; }",
    )
  to_float(call(m, "f", [])) |> should.equal(90.0)
}

// ── switch ───────────────────────────────────────────────────────────────────

pub fn switch_basic_test() {
  let m =
    compile(
      "function f(x) { let r = 0; switch (x) { case 1: r = 10; break; case 2: r = 20; break; default: r = -1; } return r; }",
    )
  to_float(call(m, "f", [dyn(1)])) |> should.equal(10.0)
  to_float(call(m, "f", [dyn(2)])) |> should.equal(20.0)
  to_float(call(m, "f", [dyn(9)])) |> should.equal(-1.0)
}

pub fn switch_fallthrough_test() {
  let m =
    compile(
      "function f(x) { let r = 0; switch (x) { case 1: r += 1; case 2: r += 10; break; case 3: r += 100; } return r; }",
    )
  // 1 falls through into 2 then breaks
  to_float(call(m, "f", [dyn(1)])) |> should.equal(11.0)
  to_float(call(m, "f", [dyn(2)])) |> should.equal(10.0)
  to_float(call(m, "f", [dyn(3)])) |> should.equal(100.0)
}

pub fn switch_default_in_middle_test() {
  let m =
    compile(
      "function f(x) { let r = 0; switch (x) { case 1: r = 1; break; default: r = 99; break; case 2: r = 2; break; } return r; }",
    )
  to_float(call(m, "f", [dyn(1)])) |> should.equal(1.0)
  to_float(call(m, "f", [dyn(2)])) |> should.equal(2.0)
  to_float(call(m, "f", [dyn(5)])) |> should.equal(99.0)
}

pub fn switch_in_loop_break_test() {
  // `break` exits the switch, NOT the enclosing loop.
  let m =
    compile(
      "function f() { let s = 0; for (let i = 0; i < 5; i++) { switch (i) { case 2: break; default: s += i; } } return s; }",
    )
  // default runs for i = 0,1,3,4 → 0+1+3+4 = 8 (i=2 breaks the switch)
  to_float(call(m, "f", [])) |> should.equal(8.0)
}

pub fn switch_string_test() {
  let m =
    compile(
      "function f(s) { switch (s) { case \"a\": return 1; case \"b\": return 2; default: return 0; } }",
    )
  to_float(call(m, "f", [dyn(<<"a">>)])) |> should.equal(1.0)
  to_float(call(m, "f", [dyn(<<"b">>)])) |> should.equal(2.0)
  to_float(call(m, "f", [dyn(<<"z">>)])) |> should.equal(0.0)
}

// ── Math builtins ────────────────────────────────────────────────────────────

pub fn math_rounding_test() {
  num("Math.floor(3.7)") |> should.equal(3.0)
  num("Math.ceil(3.2)") |> should.equal(4.0)
  num("Math.trunc(-3.7)") |> should.equal(-3.0)
  // JS Math.round is round-half-toward-+Infinity (differs from Erlang's round/1).
  num("Math.round(2.5)") |> should.equal(3.0)
  num("Math.round(-2.5)") |> should.equal(-2.0)
}

pub fn math_functions_test() {
  num("Math.abs(-5)") |> should.equal(5.0)
  num("Math.sign(-3)") |> should.equal(-1.0)
  num("Math.sqrt(16)") |> should.equal(4.0)
  num("Math.cbrt(27)") |> should.equal(3.0)
  num("Math.pow(2, 10)") |> should.equal(1024.0)
}

pub fn math_variadic_test() {
  num("Math.max(1, 5, 3)") |> should.equal(5.0)
  num("Math.min(1, 5, 3)") |> should.equal(1.0)
  num("Math.hypot(3, 4)") |> should.equal(5.0)
}

pub fn math_constants_test() {
  num("Math.PI") |> should.equal(3.141592653589793)
  num("Math.E") |> should.equal(2.718281828459045)
}

pub fn math_random_test() {
  let m =
    compile("function f() { let r = Math.random(); return r >= 0 && r < 1; }")
  call(m, "f", []) |> should.equal(dyn(True))
}

// ── array iteration methods ──────────────────────────────────────────────────

pub fn array_map_filter_test() {
  let m =
    compile("function f() { return [1, 2, 3].map(x => x * 2).join(\",\"); }")
  call(m, "f", []) |> should.equal(dyn(<<"2,4,6">>))
  let g =
    compile(
      "function f() { return [1, 2, 3, 4].filter(x => x % 2 === 0).length; }",
    )
  to_float(call(g, "f", [])) |> should.equal(2.0)
}

pub fn array_reduce_test() {
  num("[1, 2, 3, 4].reduce((a, b) => a + b, 0)") |> should.equal(10.0)
  num("[1, 2, 3, 4].reduce((a, b) => a + b)") |> should.equal(10.0)
  num("[1, 2, 3, 4].reduce((a, b) => a * b, 1)") |> should.equal(24.0)
}

pub fn array_query_test() {
  num("[10, 20, 30].indexOf(20)") |> should.equal(1.0)
  num("[10, 20, 30].indexOf(99)") |> should.equal(-1.0)
  num("[1, 2, 3, 4].find(x => x > 2)") |> should.equal(3.0)
  num("[1, 2, 3, 4].findIndex(x => x > 2)") |> should.equal(2.0)
  let c = compile("function f() { return [1, 2, 3].includes(2); }")
  call(c, "f", []) |> should.equal(dyn(True))
}

pub fn array_some_every_test() {
  let s = compile("function f() { return [1, 2, 3].some(x => x > 2); }")
  call(s, "f", []) |> should.equal(dyn(True))
  let e = compile("function f() { return [2, 4, 6].every(x => x % 2 === 0); }")
  call(e, "f", []) |> should.equal(dyn(True))
  let n = compile("function f() { return [1, 2, 3].every(x => x > 1); }")
  call(n, "f", []) |> should.equal(dyn(False))
}

pub fn array_slice_join_test() {
  let m =
    compile("function f() { return [1, 2, 3, 4, 5].slice(1, 3).join(\",\"); }")
  call(m, "f", []) |> should.equal(dyn(<<"2,3">>))
  let neg =
    compile("function f() { return [1, 2, 3, 4, 5].slice(-2).join(\",\"); }")
  call(neg, "f", []) |> should.equal(dyn(<<"4,5">>))
}

pub fn array_concat_reverse_test() {
  num("[1, 2].concat([3, 4], 5).length") |> should.equal(5.0)
  num("[1, 2, 3].reverse()[0]") |> should.equal(3.0)
}

pub fn array_shift_unshift_test() {
  let m =
    compile(
      "function f() { let a = [1, 2, 3]; let x = a.shift(); return x * 10 + a.length; }",
    )
  to_float(call(m, "f", [])) |> should.equal(12.0)
  let u = compile("function f() { let a = [2, 3]; a.unshift(1); return a[0]; }")
  to_float(call(u, "f", [])) |> should.equal(1.0)
}

pub fn array_sort_test() {
  // default sort is by string
  let d = compile("function f() { return [3, 1, 2].sort().join(\",\"); }")
  call(d, "f", []) |> should.equal(dyn(<<"1,2,3">>))
  // numeric comparator
  num("[3, 1, 2].sort((a, b) => a - b)[0]") |> should.equal(1.0)
  num("[1, 2, 3].sort((a, b) => b - a)[0]") |> should.equal(3.0)
}

pub fn array_foreach_test() {
  // forEach mutating a shared array is fine (variable-accumulation would be rejected)
  let m =
    compile(
      "function f() { let out = []; [1, 2, 3].forEach(x => out.push(x * 10)); return out.length; }",
    )
  to_float(call(m, "f", [])) |> should.equal(3.0)
}

// ── string methods ───────────────────────────────────────────────────────────

pub fn string_length_index_test() {
  num("\"hello\".length") |> should.equal(5.0)
  let m = compile("function f() { return \"hello\"[1]; }")
  call(m, "f", []) |> should.equal(dyn(<<"e">>))
}

pub fn string_case_test() {
  let u = compile("function f() { return \"abc\".toUpperCase(); }")
  call(u, "f", []) |> should.equal(dyn(<<"ABC">>))
  let l = compile("function f() { return \"ABC\".toLowerCase(); }")
  call(l, "f", []) |> should.equal(dyn(<<"abc">>))
}

pub fn string_search_test() {
  num("\"hello\".indexOf(\"ll\")") |> should.equal(2.0)
  num("\"hello\".indexOf(\"z\")") |> should.equal(-1.0)
  let m = compile("function f() { return \"hello\".includes(\"ell\"); }")
  call(m, "f", []) |> should.equal(dyn(True))
  let s = compile("function f() { return \"hello\".startsWith(\"he\"); }")
  call(s, "f", []) |> should.equal(dyn(True))
  let e = compile("function f() { return \"hello\".endsWith(\"lo\"); }")
  call(e, "f", []) |> should.equal(dyn(True))
}

pub fn string_slice_substring_test() {
  let m = compile("function f() { return \"hello\".slice(1, 3); }")
  call(m, "f", []) |> should.equal(dyn(<<"el">>))
  let n = compile("function f() { return \"hello\".slice(-2); }")
  call(n, "f", []) |> should.equal(dyn(<<"lo">>))
  // substring swaps args when start > end
  let s = compile("function f() { return \"hello\".substring(3, 1); }")
  call(s, "f", []) |> should.equal(dyn(<<"el">>))
}

pub fn string_split_test() {
  num("\"a,b,c\".split(\",\").length") |> should.equal(3.0)
  let j = compile("function f() { return \"a,b,c\".split(\",\")[1]; }")
  call(j, "f", []) |> should.equal(dyn(<<"b">>))
}

pub fn string_trim_repeat_test() {
  let t = compile("function f() { return \"  hi  \".trim(); }")
  call(t, "f", []) |> should.equal(dyn(<<"hi">>))
  let r = compile("function f() { return \"ab\".repeat(3); }")
  call(r, "f", []) |> should.equal(dyn(<<"ababab">>))
}

pub fn string_replace_test() {
  let m = compile("function f() { return \"a-b-c\".replace(\"-\", \"+\"); }")
  call(m, "f", []) |> should.equal(dyn(<<"a+b-c">>))
  let a = compile("function f() { return \"a-b-c\".replaceAll(\"-\", \"+\"); }")
  call(a, "f", []) |> should.equal(dyn(<<"a+b+c">>))
}

pub fn string_charcode_test() {
  num("\"A\".charCodeAt(0)") |> should.equal(65.0)
  let c = compile("function f() { return \"hi\".charAt(1); }")
  call(c, "f", []) |> should.equal(dyn(<<"i">>))
}

pub fn string_for_of_test() {
  // for-of over a string iterates its characters (via .length + indexing)
  let m =
    compile(
      "function f() { let out = \"\"; for (let c of \"abc\") { out = out + c + \".\"; } return out; }",
    )
  call(m, "f", []) |> should.equal(dyn(<<"a.b.c.">>))
}

// ── global functions + statics ───────────────────────────────────────────────

pub fn parse_int_test() {
  num("parseInt(\"42\")") |> should.equal(42.0)
  num("parseInt(\"ff\", 16)") |> should.equal(255.0)
  num("parseInt(\"0x1A\", 16)") |> should.equal(26.0)
  num("parseInt(\"101\", 2)") |> should.equal(5.0)
  num("parseInt(\"12px\")") |> should.equal(12.0)
  // non-numeric → NaN
  let m = compile("function f() { let r = parseInt(\"abc\"); return r !== r; }")
  call(m, "f", []) |> should.equal(dyn(True))
}

pub fn parse_float_test() {
  num("parseFloat(\"3.14\")") |> should.equal(3.14)
  num("parseFloat(\"3.14abc\")") |> should.equal(3.14)
  num("parseFloat(\"42\")") |> should.equal(42.0)
}

pub fn isnan_isfinite_test() {
  let a = compile("function f() { return isNaN(0 / 0); }")
  call(a, "f", []) |> should.equal(dyn(True))
  let b = compile("function f() { return isNaN(5); }")
  call(b, "f", []) |> should.equal(dyn(False))
  // global isNaN coerces
  let c = compile("function f() { return isNaN(\"abc\"); }")
  call(c, "f", []) |> should.equal(dyn(True))
  let d = compile("function f() { return isFinite(1 / 0); }")
  call(d, "f", []) |> should.equal(dyn(False))
}

pub fn coercion_globals_test() {
  let s = compile("function f() { return String(42); }")
  call(s, "f", []) |> should.equal(dyn(<<"42">>))
  num("Number(\"3.5\")") |> should.equal(3.5)
  num("Number(true)") |> should.equal(1.0)
  let b = compile("function f() { return Boolean(\"\"); }")
  call(b, "f", []) |> should.equal(dyn(False))
  let t = compile("function f() { return Boolean(\"x\"); }")
  call(t, "f", []) |> should.equal(dyn(True))
}

pub fn array_static_test() {
  let a = compile("function f() { return Array.isArray([1, 2]); }")
  call(a, "f", []) |> should.equal(dyn(True))
  let n = compile("function f() { return Array.isArray(5); }")
  call(n, "f", []) |> should.equal(dyn(False))
  num("Array.of(1, 2, 3).length") |> should.equal(3.0)
}

pub fn object_static_test() {
  num("Object.keys({ a: 1, b: 2 }).length") |> should.equal(2.0)
  num("Object.values({ a: 1, b: 2, c: 3 }).length") |> should.equal(3.0)
  // entries: [[key, value], ...] — check a single-key object's pair
  let e = compile("function f() { return Object.entries({ a: 7 })[0][1]; }")
  to_float(call(e, "f", [])) |> should.equal(7.0)
}

pub fn number_static_test() {
  let i = compile("function f() { return Number.isInteger(5); }")
  call(i, "f", []) |> should.equal(dyn(True))
  let d = compile("function f() { return Number.isInteger(5.5); }")
  call(d, "f", []) |> should.equal(dyn(False))
  // no coercion: a numeric string is not an integer
  let s = compile("function f() { return Number.isInteger(\"5\"); }")
  call(s, "f", []) |> should.equal(dyn(False))
}

// ── try / catch / throw ──────────────────────────────────────────────────────

pub fn try_catch_test() {
  let m =
    compile("function f() { try { throw \"boom\"; } catch (e) { return e; } }")
  call(m, "f", []) |> should.equal(dyn(<<"boom">>))
}

pub fn try_throw_number_test() {
  let m =
    compile("function f() { try { throw 42; } catch (e) { return e * 2; } }")
  to_float(call(m, "f", [])) |> should.equal(84.0)
}

pub fn try_no_throw_test() {
  let m =
    compile(
      "function f() { let x = 1; try { x = 2; } catch (e) { x = 3; } return x; }",
    )
  to_float(call(m, "f", [])) |> should.equal(2.0)
}

pub fn try_throw_skips_rest_test() {
  let m =
    compile(
      "function f() { let x = 1; try { throw 0; x = 99; } catch (e) { x = 5; } return x; }",
    )
  to_float(call(m, "f", [])) |> should.equal(5.0)
}

pub fn try_return_in_body_test() {
  // a `return` inside a try body returns from the function (it is NOT caught)
  let m =
    compile(
      "function f() { try { return \"early\"; } catch (e) { return \"caught\"; } }",
    )
  call(m, "f", []) |> should.equal(dyn(<<"early">>))
}

pub fn try_catch_from_callee_test() {
  // a throw propagates across a call and is caught
  let m =
    compile(
      "function boom() { throw \"err\"; } function f() { try { boom(); return \"no\"; } catch (e) { return e; } }",
    )
  call(m, "f", []) |> should.equal(dyn(<<"err">>))
}

pub fn try_catch_in_loop_test() {
  // try/catch nested in a loop, mutating a loop-carried variable
  let m =
    compile(
      "function f() { let s = 0; for (let i = 0; i < 5; i++) { try { if (i === 2) { throw 0; } s += i; } catch (e) { s += 100; } } return s; }",
    )
  // i=0→s0, i=1→s1, i=2→throw s101, i=3→s104, i=4→s108
  to_float(call(m, "f", [])) |> should.equal(108.0)
}

// ── nullish coalescing + for-in ──────────────────────────────────────────────

pub fn nullish_coalescing_test() {
  let a = compile("function f() { let x = null; return x ?? 5; }")
  to_float(call(a, "f", [])) |> should.equal(5.0)
  // 0 is NOT nullish (differs from ||)
  let b = compile("function f() { let x = 0; return x ?? 99; }")
  to_float(call(b, "f", [])) |> should.equal(0.0)
  let c = compile("function f() { let x = undefined; return x ?? 7; }")
  to_float(call(c, "f", [])) |> should.equal(7.0)
  // empty string is NOT nullish
  let d = compile("function f() { return \"\" ?? \"x\"; }")
  call(d, "f", []) |> should.equal(dyn(<<"">>))
}

pub fn for_in_test() {
  let m =
    compile(
      "function f() { let o = { a: 1, b: 2, c: 3 }; let n = 0; for (let k in o) { n++; } return n; }",
    )
  to_float(call(m, "f", [])) |> should.equal(3.0)
  let s =
    compile(
      "function f() { let o = { a: 10, b: 20 }; let s = 0; for (let k in o) { s += o[k]; } return s; }",
    )
  to_float(call(s, "f", [])) |> should.equal(30.0)
}

// ── optional chaining ────────────────────────────────────────────────────────

pub fn optional_member_test() {
  let m = compile("function f() { let o = { a: 5 }; return o?.a; }")
  to_float(call(m, "f", [])) |> should.equal(5.0)
  let n = compile("function f() { let o = null; return o?.a === undefined; }")
  call(n, "f", []) |> should.equal(dyn(True))
}

pub fn optional_chain_test() {
  let m = compile("function f() { let o = { a: { b: 7 } }; return o?.a?.b; }")
  to_float(call(m, "f", [])) |> should.equal(7.0)
  // missing middle link → undefined, no crash
  let n = compile("function f() { let o = {}; return o?.a?.b === undefined; }")
  call(n, "f", []) |> should.equal(dyn(True))
}

pub fn optional_computed_test() {
  let m =
    compile("function f() { let o = { x: 9 }; let k = \"x\"; return o?.[k]; }")
  to_float(call(m, "f", [])) |> should.equal(9.0)
}

pub fn optional_call_test() {
  let m = compile("function f() { let g = x => x * 2; return g?.(5); }")
  to_float(call(m, "f", [])) |> should.equal(10.0)
  let n = compile("function f() { let g = null; return g?.(5) === undefined; }")
  call(n, "f", []) |> should.equal(dyn(True))
}

pub fn optional_with_nullish_test() {
  let m = compile("function f() { let o = null; return o?.a ?? \"default\"; }")
  call(m, "f", []) |> should.equal(dyn(<<"default">>))
}

// ── default parameters + arity fitting ───────────────────────────────────────

pub fn default_params_test() {
  let m =
    compile(
      "function greet(name = \"world\") { return \"hi \" + name; } function run0() { return greet(); }",
    )
  // explicit arg
  call(m, "greet", [dyn(<<"bob">>)]) |> should.equal(dyn(<<"hi bob">>))
  // omitted arg → default (internal under-application, padded with undefined)
  call(m, "run0", []) |> should.equal(dyn(<<"hi world">>))
}

pub fn default_params_second_test() {
  let m =
    compile(
      "function add(a, b = 10) { return a + b; } function run1(a) { return add(a); }",
    )
  to_float(call(m, "run1", [dyn(5)])) |> should.equal(15.0)
  to_float(call(m, "add", [dyn(5), dyn(2)])) |> should.equal(7.0)
}

pub fn default_refs_earlier_param_test() {
  let m =
    compile(
      "function f(a, b = a * 2) { return b; } function run(a) { return f(a); }",
    )
  to_float(call(m, "run", [dyn(3)])) |> should.equal(6.0)
  to_float(call(m, "f", [dyn(3), dyn(100)])) |> should.equal(100.0)
}

pub fn under_over_application_test() {
  // missing arg arrives as undefined
  let u =
    compile(
      "function f(a, b) { return b === undefined; } function run(a) { return f(a); }",
    )
  call(u, "run", [dyn(5)]) |> should.equal(dyn(True))
  // extra args are dropped
  let o =
    compile(
      "function f(a) { return a; } function run(a) { return f(a, 99, 99); }",
    )
  to_float(call(o, "run", [dyn(1)])) |> should.equal(1.0)
}

// ── destructuring ────────────────────────────────────────────────────────────

pub fn array_destructure_test() {
  let m = compile("function f() { let [a, b] = [1, 2]; return a + b; }")
  to_float(call(m, "f", [])) |> should.equal(3.0)
  // holes are skipped
  let h = compile("function f() { let [, b, c] = [10, 20, 30]; return b + c; }")
  to_float(call(h, "f", [])) |> should.equal(50.0)
}

pub fn object_destructure_test() {
  let m =
    compile("function f() { let { x, y } = { x: 5, y: 7 }; return x + y; }")
  to_float(call(m, "f", [])) |> should.equal(12.0)
  // rename: { x: a }
  let r = compile("function f() { let { x: a } = { x: 9 }; return a; }")
  to_float(call(r, "f", [])) |> should.equal(9.0)
}

pub fn destructure_from_call_test() {
  let m =
    compile(
      "function pair() { return [1, 2]; } function f() { let [a, b] = pair(); return a * 10 + b; }",
    )
  to_float(call(m, "f", [])) |> should.equal(12.0)
}

// ── array spread ─────────────────────────────────────────────────────────────

pub fn array_spread_test() {
  let m =
    compile(
      "function f() { let a = [1, 2]; let b = [...a, 3]; return b.length * 10 + b[2]; }",
    )
  to_float(call(m, "f", [])) |> should.equal(33.0)
  let c =
    compile(
      "function f() { let a = [1, 2]; let b = [3, 4]; let d = [...a, ...b]; return d[3]; }",
    )
  to_float(call(c, "f", [])) |> should.equal(4.0)
  // leading element then spread
  let lead =
    compile("function f() { let a = [2, 3]; let b = [1, ...a]; return b[0]; }")
  to_float(call(lead, "f", [])) |> should.equal(1.0)
  // spread a string into chars
  let s = compile("function f() { let c = [...\"abc\"]; return c.length; }")
  to_float(call(s, "f", [])) |> should.equal(3.0)
}

// ── classes ──────────────────────────────────────────────────────────────────

pub fn class_basic_test() {
  let m =
    compile(
      "class Point { constructor(x, y) { this.x = x; this.y = y; } } function f() { let p = new Point(3, 4); return p.x + p.y; }",
    )
  to_float(call(m, "f", [])) |> should.equal(7.0)
}

pub fn class_methods_test() {
  let m =
    compile(
      "class Counter { constructor() { this.n = 0; } inc() { this.n = this.n + 1; } get() { return this.n; } } function f() { let c = new Counter(); c.inc(); c.inc(); c.inc(); return c.get(); }",
    )
  to_float(call(m, "f", [])) |> should.equal(3.0)
}

pub fn class_method_args_test() {
  let m =
    compile(
      "class Adder { constructor(base) { this.base = base; } add(x) { return this.base + x; } } function f() { let a = new Adder(10); return a.add(5); }",
    )
  to_float(call(m, "f", [])) |> should.equal(15.0)
}

pub fn class_field_test() {
  let m =
    compile(
      "class C { count = 5; get() { return this.count; } } function f() { let c = new C(); return c.get(); }",
    )
  to_float(call(m, "f", [])) |> should.equal(5.0)
}

pub fn class_method_calls_method_test() {
  let m =
    compile(
      "class C { constructor() { this.n = 5; } double() { return this.n * 2; } quad() { return this.double() * 2; } } function f() { let c = new C(); return c.quad(); }",
    )
  to_float(call(m, "f", [])) |> should.equal(20.0)
}

pub fn class_this_in_closure_test() {
  let m =
    compile(
      "class C { constructor() { this.n = 10; } compute() { return [1, 2, 3].map(x => x + this.n); } } function f() { let c = new C(); return c.compute()[1]; }",
    )
  to_float(call(m, "f", [])) |> should.equal(12.0)
}

// ── JSON ─────────────────────────────────────────────────────────────────────

pub fn json_stringify_test() {
  let m = compile("function f() { return JSON.stringify(42); }")
  call(m, "f", []) |> should.equal(dyn(<<"42">>))
  let a = compile("function f() { return JSON.stringify([1, 2, 3]); }")
  call(a, "f", []) |> should.equal(dyn(<<"[1,2,3]">>))
  let o = compile("function f() { return JSON.stringify({ a: 1 }); }")
  call(o, "f", []) |> should.equal(dyn(<<"{\"a\":1}">>))
  let s = compile("function f() { return JSON.stringify(\"hi\"); }")
  call(s, "f", []) |> should.equal(dyn(<<"\"hi\"">>))
}

pub fn json_parse_test() {
  num("JSON.parse(\"42\")") |> should.equal(42.0)
  num("JSON.parse(\"[1, 2, 3]\").length") |> should.equal(3.0)
  let m = compile("function f() { return JSON.parse('{\"a\":5}').a; }")
  to_float(call(m, "f", [])) |> should.equal(5.0)
  let s = compile("function f() { return JSON.parse('\"hello\"'); }")
  call(s, "f", []) |> should.equal(dyn(<<"hello">>))
}

pub fn json_roundtrip_test() {
  num("JSON.parse(JSON.stringify([10, 20, 30]))[1]") |> should.equal(20.0)
  let m =
    compile(
      "function f() { let o = { name: \"x\", n: 7 }; let s = JSON.stringify(o); return JSON.parse(s).n; }",
    )
  to_float(call(m, "f", [])) |> should.equal(7.0)
}

// ── top-level main ───────────────────────────────────────────────────────────

pub fn main_test() {
  let m = compile("let x = 10; let y = 20;")
  // main returns undefined; just assert it runs without error.
  call(m, "main", []) |> should.equal(dyn(atom.create("undefined")))
}
