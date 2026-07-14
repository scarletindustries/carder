//// End-to-end tests for `twocore/frontend/js`: compile real JS to BEAM and assert
//// the results against JS semantics. Each test compiles a small program, applies an
//// exported function, and checks the returned BEAM term.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/string
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

/// Compile `function f(){ return <expr>; }` and return the raw BEAM term (for
/// asserting string / boolean results against `dyn(...)`).
fn val(expr: String) -> Dynamic {
  let m = compile("function f() { return " <> expr <> "; }")
  call(m, "f", [])
}

/// True when `a` and `b` are within 1e-7 — for asserting transcendental results
/// (e.g. Math.cbrt) that are floating-point approximations.
fn float_close(a: Float, b: Float) -> Bool {
  let d = a -. b
  case d <. 0.0 {
    True -> 0.0 -. d <. 0.0000001
    False -> d <. 0.0000001
  }
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

pub fn array_constructor_length_test() {
  // new Array(n) / Array(n): a single number is the length — a sparse array of
  // holes (reads return undefined), NOT a one-element array.
  let m =
    compile(
      "function f() { let a = new Array(3); let b = Array(5); return a.length * 100 + b.length * 10 + (a[0] === undefined ? 1 : 0); }",
    )
  to_float(call(m, "f", [])) |> should.equal(351.0)
}

pub fn array_constructor_elements_test() {
  // Multiple args (or a single non-number) become the elements.
  let m =
    compile(
      "function f() { let a = new Array(1, 2, 3); let b = Array(\"x\"); return a.length * 1000 + a[2] * 100 + b.length * 10 + (b[0] === \"x\" ? 1 : 0); }",
    )
  // len 3, a[2]=3, b.length=1, b[0]==="x" → 3000 + 300 + 10 + 1 = 3311
  to_float(call(m, "f", [])) |> should.equal(3311.0)
}

pub fn array_constructor_empty_test() {
  let m =
    compile("function f() { return Array().length + new Array().length; }")
  to_float(call(m, "f", [])) |> should.equal(0.0)
}

pub fn first_class_top_level_fn_test() {
  // A bare reference to a top-level function is that function as a value —
  // assignable, and passable as a callback. (Used to panic in the emitter.)
  let m =
    compile(
      "function add(a, b) { return a + b; } function isBig(x) { return x > 10; } "
      <> "function f() { let g = add; return g(2, 3) * 100 + [5, 12, 3, 20].filter(isBig).length; }",
    )
  // add(2,3)=5 → 500; filter isBig over [5,12,3,20] → [12,20] length 2 → 502
  to_float(call(m, "f", [])) |> should.equal(502.0)
}

pub fn global_cross_function_test() {
  // A top-level `var` is a module-global: a setter function's write is visible to
  // another function that reads it (functions no longer have isolated scopes for
  // top-level names).
  let m =
    compile(
      "var flag = 0; function set() { flag = 42; } "
      <> "function f() { flag = 0; set(); return flag; }",
    )
  to_float(call(m, "f", [])) |> should.equal(42.0)
}

pub fn global_callback_flag_test() {
  // The ubiquitous test262 pattern: a callback mutates a top-level flag that the
  // caller then observes.
  let m =
    compile(
      "var accessed = false; function cb(v) { accessed = true; return true; } "
      <> "function f() { accessed = false; let r = [11].every(cb); return r && accessed ? 1 : 0; }",
    )
  to_float(call(m, "f", [])) |> should.equal(1.0)
}

pub fn global_increment_test() {
  // `++`/compound assignment on a global round-trips through the store.
  let m =
    compile(
      "var n = 0; function bump() { n++; } function addTwo() { n += 2; } "
      <> "function f() { n = 0; bump(); bump(); addTwo(); return n; }",
    )
  to_float(call(m, "f", [])) |> should.equal(4.0)
}

pub fn global_loop_counter_test() {
  // A global used as a `for` loop counter: the loop reads/writes it through the
  // store each iteration (it is not env-loop-carried), and must still terminate
  // and sum correctly.
  let m =
    compile(
      "var i = 0; var acc = 0; "
      <> "function f() { acc = 0; for (i = 0; i < 4; i = i + 1) { acc = acc + i; } return acc; }",
    )
  // 0 + 1 + 2 + 3 = 6
  to_float(call(m, "f", [])) |> should.equal(6.0)
}

pub fn global_shadow_test() {
  // A function-local of the same name SHADOWS the global (env wins).
  let m =
    compile("var x = 100; function f() { let x = 5; x = x + 1; return x; }")
  to_float(call(m, "f", [])) |> should.equal(6.0)
}

pub fn global_init_persists_test() {
  // A top-level `var x = init` initializes the store when main runs; a later call
  // to a reader function sees it (same process, so the store persists).
  let m = compile("var g = 7; function readG() { return g; }")
  let _ = call(m, "main", [])
  to_float(call(m, "readG", [])) |> should.equal(7.0)
}

pub fn first_class_fn_arity_fit_test() {
  // A named callback declared with FEWER params than the caller passes is fine —
  // the extra (index, array) arguments are dropped (JS ignores extras).
  let m =
    compile(
      "function dbl(x) { return x * 2; } "
      <> "function f() { return [1, 2, 3].map(dbl).reduce(function(a, b) { return a + b; }, 0); }",
    )
  // map dbl → [2,4,6], reduce sum → 12
  to_float(call(m, "f", [])) |> should.equal(12.0)
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

pub fn eval_function_aot_boundary_test() {
  // `eval` and the `Function` constructor need runtime code generation. This is an
  // ahead-of-time compiler, so they are a deliberate, permanent boundary — a clear
  // compile-time error, not an incidental "unknown identifier".
  let reject = fn(src) {
    let name = "twocore@jstest@aot" <> int.to_string(int_abs(unique()))
    case js.compile_and_load(src, name) {
      Error(_) -> Nil
      Ok(_) ->
        panic as "expected eval/Function to be rejected (AOT-only boundary)"
    }
  }
  reject("function f() { return eval(\"1 + 1\"); }")
  reject("function f() { return new Function(\"return 1\"); }")
  reject("function f() { return Function(\"a\", \"return a\")(1); }")
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

pub fn math_hypot_special_values_test() {
  // Per spec: any ±Infinity argument → +Infinity (even alongside NaN); otherwise a
  // NaN argument → NaN. (Regression: these inputs used to crash with badarith.)
  num("Math.hypot(Infinity, NaN) === Infinity ? 1 : 0") |> should.equal(1.0)
  num("Math.hypot(-Infinity, 5) === Infinity ? 1 : 0") |> should.equal(1.0)
  num("Number.isNaN(Math.hypot(NaN, 3)) ? 1 : 0") |> should.equal(1.0)
}

pub fn math_atan_special_values_test() {
  // atan is bounded by ±π/2, reached exactly at the infinities. (sin/cos/tan/
  // asin/acos are all NaN at ±∞ — see below — but atan is not.)
  num("Math.atan(Infinity) === Math.PI / 2 ? 1 : 0") |> should.equal(1.0)
  num("Math.atan(-Infinity) === -Math.PI / 2 ? 1 : 0") |> should.equal(1.0)
  num("Math.atan(0)") |> should.equal(0.0)
  num("Number.isNaN(Math.atan(NaN)) ? 1 : 0") |> should.equal(1.0)
  // Contrast: the other inverse/forward trig functions ARE NaN at infinity.
  num("Number.isNaN(Math.asin(Infinity)) ? 1 : 0") |> should.equal(1.0)
  num("Number.isNaN(Math.sin(Infinity)) ? 1 : 0") |> should.equal(1.0)
}

pub fn math_atan2_special_values_test() {
  // The ECMAScript atan2 special-value table for the infinities — these must be
  // EXACT (approximating ±∞ with the largest double gave a denormal, not ±0).
  // finite y, x = +∞ → a signed zero by y's sign.
  num("Math.atan2(1, Infinity) === 0 ? 1 : 0") |> should.equal(1.0)
  num("1 / Math.atan2(-1, Infinity) === -Infinity ? 1 : 0") |> should.equal(1.0)
  // finite y, x = −∞ → ±π by y's sign.
  num("Math.atan2(1, -Infinity) === Math.PI ? 1 : 0") |> should.equal(1.0)
  num("Math.atan2(-1, -Infinity) === -Math.PI ? 1 : 0") |> should.equal(1.0)
  // y = ±∞, x finite → ±π/2.
  num("Math.atan2(Infinity, 5) === Math.PI / 2 ? 1 : 0") |> should.equal(1.0)
  num("Math.atan2(-Infinity, 5) === -Math.PI / 2 ? 1 : 0") |> should.equal(1.0)
  // both infinite → an odd multiple of π/4.
  num("Math.atan2(Infinity, Infinity) === Math.PI / 4 ? 1 : 0")
  |> should.equal(1.0)
  num("Math.atan2(Infinity, -Infinity) === 3 * Math.PI / 4 ? 1 : 0")
  |> should.equal(1.0)
  num("Math.atan2(-Infinity, Infinity) === -Math.PI / 4 ? 1 : 0")
  |> should.equal(1.0)
  num("Math.atan2(-Infinity, -Infinity) === -3 * Math.PI / 4 ? 1 : 0")
  |> should.equal(1.0)
  // NaN in either argument → NaN.
  num("Number.isNaN(Math.atan2(NaN, 1)) ? 1 : 0") |> should.equal(1.0)
  num("Number.isNaN(Math.atan2(1, NaN)) ? 1 : 0") |> should.equal(1.0)
}

pub fn math_hyperbolic_test() {
  // ES2015 hyperbolics and inverses.
  num("Math.sinh(0)") |> should.equal(0.0)
  num("Math.cosh(0)") |> should.equal(1.0)
  num("Math.tanh(0)") |> should.equal(0.0)
  num("Math.asinh(0)") |> should.equal(0.0)
  num("Math.acosh(1)") |> should.equal(0.0)
  num("Math.atanh(0)") |> should.equal(0.0)
  // acosh's domain is [1, ∞); atanh's is (-1, 1) with ±1 → ±∞.
  num("Number.isNaN(Math.acosh(0)) ? 1 : 0") |> should.equal(1.0)
  num("Math.atanh(1) === Infinity ? 1 : 0") |> should.equal(1.0)
}

pub fn math_fround_clz32_test() {
  // fround rounds to single precision; 1.1 is not representable in float32.
  num("Math.fround(1)") |> should.equal(1.0)
  num("Math.fround(0)") |> should.equal(0.0)
  num("Math.fround(1.1) === 1.1 ? 1 : 0") |> should.equal(0.0)
  // clz32: ToUint32 then count 32-bit leading zeros. clz32(1)=31, clz32(0)=32.
  num("Math.clz32(1)") |> should.equal(31.0)
  num("Math.clz32(0)") |> should.equal(32.0)
  num("Math.clz32(1000)") |> should.equal(22.0)
  num("Math.clz32(NaN)") |> should.equal(32.0)
}

pub fn math_imul_test() {
  // C-like 32-bit integer multiply, result reinterpreted as signed int32.
  num("Math.imul(3, 4)") |> should.equal(12.0)
  num("Math.imul(-5, 12)") |> should.equal(-60.0)
  // 0xffffffff is -1 as int32, so imul(0xffffffff, 5) = -5.
  num("Math.imul(0xffffffff, 5)") |> should.equal(-5.0)
  num("Math.imul(0xfffffffe, 5)") |> should.equal(-10.0)
}

pub fn math_expm1_log1p_test() {
  num("Math.expm1(0)") |> should.equal(0.0)
  num("Math.log1p(0)") |> should.equal(0.0)
  num("Math.log1p(-1) === -Infinity ? 1 : 0") |> should.equal(1.0)
  num("Number.isNaN(Math.log1p(-2)) ? 1 : 0") |> should.equal(1.0)
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

pub fn array_index_of_from_index_test() {
  // indexOf(x, fromIndex) searches forward from fromIndex; lastIndexOf(x, fromIndex)
  // searches backward from it. Negatives count from the end.
  num("[1, 2, 3, 2, 1].indexOf(2)") |> should.equal(1.0)
  num("[1, 2, 3, 2, 1].indexOf(2, 2)") |> should.equal(3.0)
  num("[1, 2, 3, 2, 1].indexOf(1, -2)") |> should.equal(4.0)
  num("[1, 2, 3].indexOf(1, 5)") |> should.equal(-1.0)
  num("[1, 2, 3, 2, 1].lastIndexOf(2)") |> should.equal(3.0)
  num("[1, 2, 3, 2, 1].lastIndexOf(2, 2)") |> should.equal(1.0)
  num("[1, 2, 3, 2, 1].lastIndexOf(1, -3)") |> should.equal(0.0)
}

pub fn array_includes_from_index_test() {
  // includes(element, fromIndex): searches from fromIndex (negatives from the end);
  // no argument searches for undefined.
  num("[1, 2, 3, 2].includes(2, 2) ? 1 : 0") |> should.equal(1.0)
  num("[1, 2, 3].includes(1, 1) ? 1 : 0") |> should.equal(0.0)
  num("[1, 2, 3].includes(3, -1) ? 1 : 0") |> should.equal(1.0)
  num("[1, 2, 3].includes(1, 5) ? 1 : 0") |> should.equal(0.0)
  num("[].includes() ? 1 : 0") |> should.equal(0.0)
  num("[undefined, 1].includes() ? 1 : 0") |> should.equal(1.0)
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

// ── Array iteration methods: live re-read + hole semantics (spec-driven) ──────
// These encode ES2023 23.1.3 rules that a mid-iteration callback observes:
//   * the range of indices is fixed at entry (LengthOfArrayLike is read once);
//   * each step re-reads the live object (Get) — so element writes are seen;
//   * reduce/reduceRight/some/every/flatMap skip holes (per-step HasProperty)
//     but visit an explicit `undefined`;
//   * find/findIndex/findLast/findLastIndex visit EVERY index (a hole reads as
//     undefined).
// Mirrored from test262 built-ins/Array/prototype/{reduce,some,every,find,...}.

pub fn array_reduce_spec_test() {
  // Live re-read (test262 15.4.4.21-9-2): the callback overwrites later elements
  // and the fold observes them → [1,2,3,4,5].reduce(cb) === 3.
  let live =
    compile(
      "var ra = []; function racb(p, c) { ra[3] = -2; ra[4] = -1; return p + c; } "
      <> "function f() { ra = [1, 2, 3, 4, 5]; return ra.reduce(racb); }",
    )
  to_float(call(live, "f", [])) |> should.equal(3.0)

  // Holes are skipped, a hole the callback FILLS is visited, and an element
  // appended beyond the starting length is not (range fixed at entry).
  // (test262 15.4.4.21-9-1 / 9-10 shape.)
  let holes =
    compile(
      "var ha = []; function hacb(p, c) { ha[5] = 100; ha[2] = 3; return p + c; } "
      <> "function f() { ha = [1, 2, 3, 4, 5]; delete ha[2]; return ha.reduce(hacb, 0); }",
    )
  // 0 +1 +2 +3(filled) +4 +5 = 15; index 5 (≥ len 5) is never visited.
  to_float(call(holes, "f", [])) |> should.equal(15.0)

  // An all-holes array WITH an initial value returns the initial value and never
  // calls the callback (test262 15.4.4.21-9-b-1).
  num("new Array(10).reduce((a, b) => a + b, 5)") |> should.equal(5.0)

  // No initial value and no present element → TypeError (ES 23.1.3.24 step 8.c).
  let empty =
    compile("function f() { return new Array(3).reduce((a, b) => a + b); }")
  let threw = case catch_apply(empty, atom.create("f"), []) {
    Error(_) -> True
    Ok(_) -> False
  }
  threw |> should.equal(True)

  // reduceRight folds right-to-left, skipping holes and re-reading live: deleting
  // a not-yet-visited index removes it from the fold (test262 15.4.4.22-9-3 shape).
  let rr =
    compile(
      "var rr = []; function rrcb(p, c) { delete rr[0]; return p + c; } "
      <> "function f() { rr = [1, 2, 3, 4]; return rr.reduceRight(rrcb); }",
    )
  // seed 4 (k=3), +3, +2, then k=0 was deleted → skipped ⇒ 4+3+2 = 9.
  to_float(call(rr, "f", [])) |> should.equal(9.0)
}

pub fn array_some_every_spec_test() {
  // some/every skip holes but visit an explicit `undefined`: a `new Array(10)`
  // with only index 1 assigned calls the callback exactly once
  // (test262 15.4.4.17-7-b-1 / 15.4.4.16-7-b-1).
  let holes =
    compile(
      "var sc = 0; function scb(v) { sc = sc + 1; return false; } "
      <> "function f() { sc = 0; let a = new Array(10); a[1] = undefined; a.some(scb); return sc; }",
    )
  to_float(call(holes, "f", [])) |> should.equal(1.0)

  // some re-reads the live array: writing a later index is observed
  // (test262 15.4.4.17-7-2).
  let live =
    compile(
      "var la = []; function lcb(v) { la[4] = 6; return v >= 6; } "
      <> "function f() { la = [1, 2, 3, 4, 5]; return la.some(lcb) ? 1 : 0; }",
    )
  to_float(call(live, "f", [])) |> should.equal(1.0)
}

pub fn array_find_spec_test() {
  // find/findIndex visit EVERY index and re-read live: reassigning a not-yet-
  // visited index changes what the next step sees (find/array-altered-during-loop).
  let fi =
    compile(
      "var ga = []; function gcb(kv) { if (ga[1] !== 9) { ga[1] = 9; } return kv === 9; } "
      <> "function f() { ga = [1, 2, 3]; return ga.findIndex(gcb); }",
    )
  to_float(call(fi, "f", [])) |> should.equal(1.0)

  // findLast walks from the end, likewise visiting every index and reading live.
  let fl =
    compile(
      "var da = []; function dcb(kv) { if (da[0] !== 7) { da[0] = 7; } return kv === 7; } "
      <> "function f() { da = [1, 2, 3]; return da.findLast(dcb); }",
    )
  to_float(call(fl, "f", [])) |> should.equal(7.0)
}

pub fn array_sort_undefined_spec_test() {
  // sort moves `undefined` to the end regardless of order (SortCompare: an
  // undefined x sorts after everything) and never passes it to a comparator
  // (ES 23.1.3.30). Default (ToString) order.
  let d =
    compile(
      "function f() { return [\"z\", undefined, \"a\"].sort().join(\",\"); }",
    )
  call(d, "f", []) |> should.equal(dyn(<<"a,z,">>))

  // With a comparator, undefined still sorts last and is not compared.
  let c =
    compile(
      "function f() { return [3, undefined, 1].sort((a, b) => a - b).join(\",\"); }",
    )
  call(c, "f", []) |> should.equal(dyn(<<"1,3,">>))

  // Holes sort after every present element; the trailing slots stay holes.
  let h =
    compile(
      "function f() { let a = new Array(4); a[0] = 3; a[1] = 1; return a.sort().join(\",\"); }",
    )
  call(h, "f", []) |> should.equal(dyn(<<"1,3,,">>))
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

pub fn string_code_point_at_test() {
  // codePointAt returns the code point, or undefined when out of range (unlike
  // charCodeAt, which is NaN).
  num("'abc'.codePointAt(0)") |> should.equal(97.0)
  num("'abc'.codePointAt(2)") |> should.equal(99.0)
  num("'abc'.codePointAt(3) === undefined ? 1 : 0") |> should.equal(1.0)
  num("'abc'.codePointAt(-1) === undefined ? 1 : 0") |> should.equal(1.0)
  // an omitted position defaults to 0.
  num("'A'.codePointAt()") |> should.equal(65.0)
}

pub fn string_pad_infinity_test() {
  // padStart/padEnd with -Infinity (or NaN/undefined) target leaves the string
  // unchanged; it must not crash.
  let m =
    compile(
      "function f() { return 'abc'.padStart(-Infinity, 'x') + '|' + 'abc'.padEnd(NaN, 'x') + '|' + 'abc'.padStart(5, 'x'); }",
    )
  call(m, "f", []) |> should.equal(dyn(<<"abc|abc|xxabc">>))
}

pub fn string_normalize_test() {
  // Unicode normalization: composed vs decomposed forms of "é".
  let m =
    compile(
      "function f() { let composed = '\\u00E9'; let decomposed = 'e\\u0301'; "
      <> "return (composed.normalize('NFC') === decomposed.normalize('NFC') ? 1 : 0) * 10 + "
      <> "(composed.normalize('NFD').length === 2 ? 1 : 0); }",
    )
  to_float(call(m, "f", [])) |> should.equal(11.0)
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

pub fn string_char_at_coercion_test() {
  // §22.1.3.1/§22.1.3.2: `pos` is ToIntegerOrInfinity — ToNumber then truncate
  // toward zero. A numeric string is coerced (not treated as index 0), and a
  // fraction is truncated toward zero.
  val("'abcd'.charAt('   +00200.0000E-0002   ')")
  |> should.equal(dyn(<<"c">>))
  val("'abc'.charAt(1.99999)") |> should.equal(dyn(<<"b">>))
  val("'abc'.charAt(0.99999)") |> should.equal(dyn(<<"a">>))
  val("'abc'.charAt(-0.99999)") |> should.equal(dyn(<<"a">>))
  // Out of range (negative, past the end, or ±Infinity) → "".
  val("'abc'.charAt(-1)") |> should.equal(dyn(<<"">>))
  val("'abc'.charAt(3)") |> should.equal(dyn(<<"">>))
  val("'abc'.charAt(Infinity)") |> should.equal(dyn(<<"">>))
  // Omitted argument → position 0.
  val("'abc'.charAt()") |> should.equal(dyn(<<"a">>))

  // charCodeAt shares the coercion; out of range is NaN (so x !== x).
  num("'abcd'.charCodeAt('   +00200.0000E-0002   ')")
  |> should.equal(99.0)
  num("'abc'.charCodeAt(1.99999)") |> should.equal(98.0)
  num("'abc'.charCodeAt()") |> should.equal(97.0)
  val("'abc'.charCodeAt(5) !== 'abc'.charCodeAt(5)")
  |> should.equal(dyn(True))
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

pub fn string_trim_whitespace_set_test() {
  // ECMAScript §12.2/12.3: the trim whitespace set includes NBSP (U+00A0) and
  // the ZWNBSP/BOM (U+FEFF), which Erlang's default `string:trim` does not
  // treat as whitespace. Leading/trailing runs of these must be removed.
  let a = compile("function f() { return '\\u00A0\\u00A0abc\\uFEFF'.trim(); }")
  call(a, "f", []) |> should.equal(dyn(<<"abc">>))
  let b = compile("function f() { return '\\uFEFF\\u00A0'.trim(); }")
  call(b, "f", []) |> should.equal(dyn(<<"">>))
  // trimStart / trimEnd only strip one side.
  let s = compile("function f() { return '\\u00A0x\\u00A0'.trimStart(); }")
  call(s, "f", []) |> should.equal(dyn(<<"x\u{00A0}">>))
  let e = compile("function f() { return '\\u00A0x\\u00A0'.trimEnd(); }")
  call(e, "f", []) |> should.equal(dyn(<<"\u{00A0}x">>))
  // An interior NBSP is preserved (code-point length stays 3).
  num("'a\\u00A0b'.trim().length") |> should.equal(3.0)
}

pub fn string_index_of_position_test() {
  // indexOf(sub, position): position is ToIntegerOrInfinity, clamped to
  // [0, len]; the empty string is found at the clamped start.
  num("\"aaaa\".indexOf(\"aa\", 0)") |> should.equal(0.0)
  num("\"aaaa\".indexOf(\"aa\", 1)") |> should.equal(1.0)
  num("\"aaaa\".indexOf(\"aa\", 2)") |> should.equal(2.0)
  num("\"aaaa\".indexOf(\"aa\", 3)") |> should.equal(-1.0)
  // truncate toward zero
  num("\"aaaa\".indexOf(\"aa\", 1.9)") |> should.equal(1.0)
  num("\"aaaa\".indexOf(\"aa\", -0.9)") |> should.equal(0.0)
  // NaN => 0, +Infinity => len (no match)
  num("\"aaaa\".indexOf(\"aa\", NaN)") |> should.equal(0.0)
  num("\"aaaa\".indexOf(\"aa\", Infinity)") |> should.equal(-1.0)
  // empty search string: min(position, len)
  num("\"abc\".indexOf(\"\", 2)") |> should.equal(2.0)
  num("\"abc\".indexOf(\"\", 10)") |> should.equal(3.0)
}

pub fn string_last_index_of_test() {
  // lastIndexOf must be able to return -1.
  num("\"abc\".lastIndexOf(\"d\")") |> should.equal(-1.0)
  // Default position is +Infinity: search the whole string.
  num("\"canal\".lastIndexOf(\"a\")") |> should.equal(3.0)
  // Overlapping matches count.
  num("\"aaa\".lastIndexOf(\"aa\")") |> should.equal(1.0)
  num("\"abcabc\".lastIndexOf(\"abc\")") |> should.equal(3.0)
  // position bounds the START of the match.
  num("\"canal\".lastIndexOf(\"a\", 2)") |> should.equal(1.0)
  num("\"aaa\".lastIndexOf(\"aa\", 0)") |> should.equal(0.0)
  // empty search string is found at min(position, len).
  num("\"abc\".lastIndexOf(\"\")") |> should.equal(3.0)
  num("\"abc\".lastIndexOf(\"\", 1)") |> should.equal(1.0)
}

pub fn string_includes_position_test() {
  // includes(sub, position): search only at or after `position`.
  num("\"The future is cool!\".includes(\"The future\", 1) ? 1 : 0")
  |> should.equal(0.0)
  num("\"The future is cool!\".includes(\"future\", 4) ? 1 : 0")
  |> should.equal(1.0)
  // out-of-bounds position never matches.
  num("\"abc\".includes(\"c\", 3) ? 1 : 0") |> should.equal(0.0)
  num("\"abc\".includes(\"c\", 100) ? 1 : 0") |> should.equal(0.0)
  num("\"abc\".includes(\"c\", Infinity) ? 1 : 0") |> should.equal(0.0)
}

pub fn string_starts_with_position_test() {
  // startsWith(prefix, position): matches only when `prefix` starts exactly at
  // the clamped `position`.
  num("\"The future\".startsWith(\"future\", 4) ? 1 : 0") |> should.equal(1.0)
  num("\"abc\".startsWith(\"b\", 1) ? 1 : 0") |> should.equal(1.0)
  num("\"abc\".startsWith(\"a\", 1) ? 1 : 0") |> should.equal(0.0)
  // NaN / undefined position coerce to 0.
  num("\"abc\".startsWith(\"a\", NaN) ? 1 : 0") |> should.equal(1.0)
  num("\"abc\".startsWith(\"a\") ? 1 : 0") |> should.equal(1.0)
  // 1.4 truncates to 1.
  num("\"abc\".startsWith(\"a\", 1.4) ? 1 : 0") |> should.equal(0.0)
}

pub fn string_ends_with_position_test() {
  // endsWith(suffix, endPosition): the string is treated as if it ended at
  // `endPosition` (default: its length).
  num("\"word\".endsWith(\"r\", 3) ? 1 : 0") |> should.equal(1.0)
  num("\"word\".endsWith(\"d\", 3) ? 1 : 0") |> should.equal(0.0)
  num("\"The future is cool!\".endsWith(\"future\", 10) ? 1 : 0")
  |> should.equal(1.0)
  // no endPosition: default to the full length.
  num("\"hello\".endsWith(\"lo\") ? 1 : 0") |> should.equal(1.0)
  num("\"hello\".endsWith(\"he\") ? 1 : 0") |> should.equal(0.0)
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

pub fn primitive_wrapper_test() {
  // `new Number/String/Boolean(x)` build a WRAPPER object boxing the coerced
  // primitive (§21.1.1.1 / §22.1.1.1 / §20.3.1.1). It is an object: `typeof` "object".
  val("typeof (new Number(5))") |> should.equal(dyn(<<"object">>))
  val("typeof (new String('hi'))") |> should.equal(dyn(<<"object">>))
  val("typeof (new Boolean(false))") |> should.equal(dyn(<<"object">>))

  // valueOf unwraps to the boxed primitive (§21.1.3.7 / §22.1.3.28 / §20.3.3.3).
  num("(new Number(5)).valueOf()") |> should.equal(5.0)
  val("(new String('hi')).valueOf()") |> should.equal(dyn(<<"hi">>))
  val("(new Boolean(false)).valueOf()") |> should.equal(dyn(False))
  val("(new Boolean('x')).valueOf()") |> should.equal(dyn(True))

  // toString unwraps to the primitive's string form.
  val("(new String('hi')).toString()") |> should.equal(dyn(<<"hi">>))
  val("(new Number(5)).toString()") |> should.equal(dyn(<<"5">>))

  // The argument is coerced: ToNumber / ToString / ToBoolean.
  num("(new Number('3.5')).valueOf()") |> should.equal(3.5)
  val("(new String(42)).valueOf()") |> should.equal(dyn(<<"42">>))
  val("(new Boolean(0)).valueOf()") |> should.equal(dyn(False))

  // A no-argument call boxes the type's default: 0 / "" / false.
  num("(new Number()).valueOf()") |> should.equal(0.0)
  val("(new String()).valueOf()") |> should.equal(dyn(<<"">>))
  val("(new Boolean()).valueOf()") |> should.equal(dyn(False))

  // A String wrapper exposes `.length` and index access from the boxed string.
  num("new String('abc').length") |> should.equal(3.0)
  val("new String('abc')[0]") |> should.equal(dyn(<<"a">>))

  // String-coercion of a wrapper unwraps to its primitive (ToPrimitive → ToString).
  val("'v' + new Number(5)") |> should.equal(dyn(<<"v5">>))

  // A wrapper is an OBJECT, so it is never strict-equal to the boxed primitive.
  val("(new Number(5)) === 5") |> should.equal(dyn(False))

  // REGRESSION GUARD: `Number/String/Boolean(x)` WITHOUT `new` still return PRIMITIVES.
  val("typeof Number(5)") |> should.equal(dyn(<<"number">>))
  val("typeof String(5)") |> should.equal(dyn(<<"string">>))
  val("typeof Boolean(1)") |> should.equal(dyn(<<"boolean">>))
  num("Number('3.5')") |> should.equal(3.5)
  val("String(42)") |> should.equal(dyn(<<"42">>))
  val("Boolean('')") |> should.equal(dyn(False))
}

pub fn number_string_whitespace_test() {
  // ToNumber(String) strips the full ES WhiteSpace + LineTerminator set from both
  // ends; a string of only whitespace is 0 (not NaN).
  num("Number('   ')") |> should.equal(0.0)
  num("Number('\\t\\n\\r')") |> should.equal(0.0)
  num("Number('\\u000B\\u000C')") |> should.equal(0.0)
  // Unicode whitespace: NBSP, line/paragraph separators, ideographic space.
  num("Number('\\u00A0')") |> should.equal(0.0)
  num("Number('\\u2028')") |> should.equal(0.0)
  num("Number('\\u3000')") |> should.equal(0.0)
  // Whitespace around a value is stripped, leaving the number.
  num("Number('  \\t 42 \\n ')") |> should.equal(42.0)
  num("Number('\\u00A0-3.5\\u00A0')") |> should.equal(-3.5)
}

pub fn number_to_exponential_test() {
  // Exponential notation with a given fraction-digit count; JS uses a minimal
  // exponent ("e+2", not "e+02").
  let m =
    compile(
      "function f() { return (123.456).toExponential(2) + '|' + (123.456).toExponential(0) + '|' + (-123.456).toExponential(1) + '|' + (0.00042).toExponential(2) + '|' + (123.456).toExponential(); }",
    )
  call(m, "f", [])
  |> should.equal(dyn(<<"1.23e+2|1e+2|-1.2e+2|4.20e-4|1.23456e+2">>))
}

pub fn number_to_precision_test() {
  // Significant-digit formatting: fixed when the exponent is in [-6, p), else
  // exponential; no argument is ToString.
  let m =
    compile(
      "function f() { return (123.456).toPrecision(5) + '|' + (123.456).toPrecision(2) + '|' + (0.0042).toPrecision(2) + '|' + (123456).toPrecision(3) + '|' + (123.456).toPrecision(); }",
    )
  call(m, "f", [])
  |> should.equal(dyn(<<"123.46|1.2e+2|0.0042|1.23e+5|123.456">>))
}

pub fn number_string_radix_test() {
  // ToNumber(String) parses 0x/0o/0b integer literals (no sign after the prefix).
  num("Number('0x5')") |> should.equal(5.0)
  num("Number('0X0')") |> should.equal(0.0)
  num("Number('0xFF')") |> should.equal(255.0)
  num("Number('0o17')") |> should.equal(15.0)
  num("Number('0b101')") |> should.equal(5.0)
  num("+('0xff')") |> should.equal(255.0)
  // A sign after the prefix, or empty digits, is NaN.
  num("Number('0x') !== Number('0x') ? 1 : 0") |> should.equal(1.0)
  num("Number('0x-5') !== Number('0x-5') ? 1 : 0") |> should.equal(1.0)
}

pub fn array_static_test() {
  let a = compile("function f() { return Array.isArray([1, 2]); }")
  call(a, "f", []) |> should.equal(dyn(True))
  let n = compile("function f() { return Array.isArray(5); }")
  call(n, "f", []) |> should.equal(dyn(False))
  num("Array.of(1, 2, 3).length") |> should.equal(3.0)
}

// ── Array.from edge cases (ES 23.1.2.1) ──────────────────────────────────────

pub fn array_from_arraylike_test() {
  // From an array-like object: read `length`, then indices 0..len-1 as own props.
  let m =
    compile(
      "function f() { var o = { length: 4, 0: 2, 1: 4, 2: 0, 3: 16 }; return Array.from(o).join(\",\"); }",
    )
  call(m, "f", []) |> should.equal(dyn(<<"2,4,0,16">>))
  // An absent index reads as undefined (rendered "" by join).
  let hole =
    compile(
      "function f() { var o = { length: 3, 0: 2, 2: 16 }; return Array.from(o).join(\",\"); }",
    )
  call(hole, "f", []) |> should.equal(dyn(<<"2,,16">>))
  // `{ length }` with no indices → an array of that many undefined holes.
  num("Array.from({ length: 5 }).length") |> should.equal(5.0)
  // A non-object, non-string source yields an empty array.
  num("Array.from(5).length") |> should.equal(0.0)
  // From a string: one element per code point.
  let s = compile("function f() { return Array.from(\"abc\").join(\"-\"); }")
  call(s, "f", []) |> should.equal(dyn(<<"a-b-c">>))
}

pub fn array_from_map_live_test() {
  // Array.from(array, mapFn) reads each element FRESH: a mapFn that overwrites a
  // not-yet-visited index makes the next step observe the new value
  // (test262 Array/from/elements-updated-after).
  let m =
    compile(
      "var fa = []; function famap(v, i) { if (i + 1 < fa.length) fa[i + 1] = 1; return v; } "
      <> "function f() { fa = [1, 0, 0]; return Array.from(fa, famap).join(\",\"); }",
    )
  call(m, "f", []) |> should.equal(dyn(<<"1,1,1">>))
  // The map callback receives (element, index).
  let idx =
    compile(
      "function f() { return Array.from([9, 9, 9], function(v, i) { return i; }).join(\",\"); }",
    )
  call(idx, "f", []) |> should.equal(dyn(<<"0,1,2">>))
}

pub fn instanceof_array_test() {
  // Every array is an Array instance; a plain object is not.
  let a = compile("function f() { return [1, 2] instanceof Array; }")
  call(a, "f", []) |> should.equal(dyn(True))
  let b = compile("function f() { return Array.from([1]) instanceof Array; }")
  call(b, "f", []) |> should.equal(dyn(True))
  let n = compile("function f() { var o = {}; return o instanceof Array; }")
  call(n, "f", []) |> should.equal(dyn(False))
}

// ── ES2023 immutable (change-array-by-copy) methods ──────────────────────────

pub fn array_to_reversed_test() {
  // Returns a new reversed array; the receiver is unchanged.
  let m =
    compile(
      "function f() { var a = [1, 2, 3]; var r = a.toReversed(); return r.join(\",\") + \"|\" + a.join(\",\"); }",
    )
  call(m, "f", []) |> should.equal(dyn(<<"3,2,1|1,2,3">>))
  // Holes read through as undefined (dense result).
  let h = compile("function f() { return [1, , 3].toReversed().join(\",\"); }")
  call(h, "f", []) |> should.equal(dyn(<<"3,,1">>))
}

pub fn array_to_sorted_test() {
  // Default order is by ToString; the receiver is unchanged.
  let d =
    compile(
      "function f() { var a = [3, 1, 2]; var s = a.toSorted(); return s.join(\",\") + \"|\" + a.join(\",\"); }",
    )
  call(d, "f", []) |> should.equal(dyn(<<"1,2,3|3,1,2">>))
  // Default (lexicographic) vs numeric comparator differ for multi-digit numbers.
  let lex =
    compile("function f() { return [10, 2, 1].toSorted().join(\",\"); }")
  call(lex, "f", []) |> should.equal(dyn(<<"1,10,2">>))
  let cmp =
    compile(
      "function f() { return [10, 2, 1].toSorted(function(a, b) { return a - b; }).join(\",\"); }",
    )
  call(cmp, "f", []) |> should.equal(dyn(<<"1,2,10">>))
  // Holes read through as undefined and sort after every defined element.
  let h = compile("function f() { return [3, , 1].toSorted().join(\",\"); }")
  call(h, "f", []) |> should.equal(dyn(<<"1,3,">>))
}

pub fn array_with_test() {
  // Replace at a positive index; the receiver is unchanged.
  let m =
    compile(
      "function f() { var a = [1, 2, 3]; var w = a.with(1, 9); return w.join(\",\") + \"|\" + a.join(\",\"); }",
    )
  call(m, "f", []) |> should.equal(dyn(<<"1,9,3|1,2,3">>))
  // A negative index counts from the end.
  let neg =
    compile("function f() { return [1, 2, 3].with(-1, 9).join(\",\"); }")
  call(neg, "f", []) |> should.equal(dyn(<<"1,2,9">>))
  // Index is ToIntegerOrInfinity: 1.2 truncates to 1.
  let co =
    compile("function f() { return [0, 4, 16].with(1.2, 7).join(\",\"); }")
  call(co, "f", []) |> should.equal(dyn(<<"0,7,16">>))
  // An out-of-range index raises a RangeError (surfaces as an Error).
  let oob = compile("function f() { return [1, 2, 3].with(5, 0); }")
  let threw = case catch_apply(oob, atom.create("f"), []) {
    Error(_) -> True
    Ok(_) -> False
  }
  threw |> should.equal(True)
}

pub fn array_to_spliced_test() {
  // Insert without deleting; the receiver is unchanged.
  let ins =
    compile(
      "function f() { var a = [1, 2, 3]; var s = a.toSpliced(1, 0, 9); return s.join(\",\") + \"|\" + a.join(\",\"); }",
    )
  call(ins, "f", []) |> should.equal(dyn(<<"1,9,2,3|1,2,3">>))
  // A missing deleteCount deletes through the end.
  let del =
    compile(
      "function f() { return [\"a\", \"b\", \"c\"].toSpliced(1).join(\",\"); }",
    )
  call(del, "f", []) |> should.equal(dyn(<<"a">>))
  // No arguments → a full copy.
  num("[1, 2, 3].toSpliced().length") |> should.equal(3.0)
  // A start past the end clamps to length (the items are appended).
  let big =
    compile(
      "function f() { return [0, 1].toSpliced(10, 1, 5, 6).join(\",\"); }",
    )
  call(big, "f", []) |> should.equal(dyn(<<"0,1,5,6">>))
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

// ── object spread + object methods ───────────────────────────────────────────

pub fn object_spread_test() {
  let m =
    compile(
      "function f() { let o = { a: 1, b: 2 }; let p = { ...o, c: 3 }; return p.a + p.b + p.c; }",
    )
  to_float(call(m, "f", [])) |> should.equal(6.0)
  // a later property overrides the spread
  let ov =
    compile(
      "function f() { let o = { a: 1 }; let p = { ...o, a: 99 }; return p.a; }",
    )
  to_float(call(ov, "f", [])) |> should.equal(99.0)
  // a spread overrides an earlier property
  let sp =
    compile(
      "function f() { let o = { a: 5 }; let p = { a: 1, ...o }; return p.a; }",
    )
  to_float(call(sp, "f", [])) |> should.equal(5.0)
}

pub fn object_method_test() {
  let m =
    compile(
      "function f() { let o = { double(x) { return x * 2; } }; return o.double(21); }",
    )
  to_float(call(m, "f", [])) |> should.equal(42.0)
}

// ── class inheritance ────────────────────────────────────────────────────────

const animal_src = "class Animal { constructor(name) { this.name = name; } speak() { return this.name + \" makes a sound\"; } } "

pub fn class_inherit_override_test() {
  let m =
    compile(
      animal_src
      <> "class Dog extends Animal { constructor(name) { super(name); this.legs = 4; } speak() { return this.name + \" barks\"; } } function f() { let d = new Dog(\"Rex\"); return d.speak(); }",
    )
  call(m, "f", []) |> should.equal(dyn(<<"Rex barks">>))
}

pub fn class_inherit_fields_test() {
  let m =
    compile(
      animal_src
      <> "class Dog extends Animal { constructor(name) { super(name); this.legs = 4; } info() { return this.name + \" has \" + this.legs; } } function f() { let d = new Dog(\"Rex\"); return d.info(); }",
    )
  call(m, "f", []) |> should.equal(dyn(<<"Rex has 4">>))
}

pub fn class_inherit_method_test() {
  // Cat inherits speak() from Animal
  let m =
    compile(
      animal_src
      <> "class Cat extends Animal { constructor(name) { super(name); } } function f() { let c = new Cat(\"Tom\"); return c.speak(); }",
    )
  call(m, "f", []) |> should.equal(dyn(<<"Tom makes a sound">>))
}

pub fn class_super_method_test() {
  let m =
    compile(
      animal_src
      <> "class Loud extends Animal { constructor(name) { super(name); } speak() { return super.speak() + \"!!!\"; } } function f() { let l = new Loud(\"X\"); return l.speak(); }",
    )
  call(m, "f", []) |> should.equal(dyn(<<"X makes a sound!!!">>))
}

// ── more builtins (from/flat/fill/at, pad, fromCharCode, Date.now) ────────────

pub fn array_from_flat_test() {
  num("Array.from(\"abc\").length") |> should.equal(3.0)
  num("[1, [2, 3], 4].flat().length") |> should.equal(4.0)
  num("[1, [2, 3], 4].flat()[2]") |> should.equal(3.0)
}

pub fn array_splice_test() {
  // splice removes deleteCount elements at start, inserts items, returns the
  // removed elements; it mutates the array in place.
  let m =
    compile(
      "function f() { let a = ['a', 'b', 'c', 'd']; let removed = a.splice(1, 2, 'x', 'y', 'z'); "
      <> "let b = ['first', 'second', 'third']; let r2 = b.splice(1); "
      <> "return a.join('') + '/' + removed.join('') + '/' + b.join('') + '/' + r2.join('') + '/' + r2.length; }",
    )
  // a → [a,x,y,z,d]="axyzd", removed=[b,c]="bc"; b → ["first"], r2=["second","third"] len 2
  call(m, "f", [])
  |> should.equal(dyn(<<"axyzd/bc/first/secondthird/2">>))
}

pub fn array_copy_within_test() {
  // copyWithin(target, start, end): copies [start,end) to target, in place;
  // negatives count from the end; omitted end is the length.
  let m =
    compile(
      "function f() { let a = [1, 2, 3, 4, 5].copyWithin(0, 3); "
      <> "let b = [1, 2, 3, 4, 5].copyWithin(1, 3, 4); "
      <> "let c = [1, 2, 3, 4, 5].copyWithin(-2, -3, -1); "
      <> "return a.join('') + '/' + b.join('') + '/' + c.join(''); }",
    )
  // a: copy [3,5)=[4,5] to 0 → [4,5,3,4,5]; b: copy [3,4)=[4] to 1 → [1,4,3,4,5];
  // c: target 3, [2,4)=[3,4] → [1,2,3,3,4]
  call(m, "f", []) |> should.equal(dyn(<<"45345/14345/12334">>))
}

pub fn array_flat_depth_test() {
  // flat honours a depth argument; Infinity fully flattens, and the default is 1.
  let m =
    compile(
      "function f() { let a = [1, [2, [3, [4]]]]; "
      <> "return a.flat(Infinity).join('') + '/' + a.flat(2).length + '/' + a.flat().length; }",
    )
  // full flatten → "1234"; depth 2 → [1,2,3,[4]] length 4; depth 1 → [1,2,[3,[4]]] length 3
  call(m, "f", []) |> should.equal(dyn(<<"1234/4/3">>))
}

pub fn array_fill_at_test() {
  let m = compile("function f() { let a = [1, 2, 3]; a.fill(0); return a[1]; }")
  to_float(call(m, "f", [])) |> should.equal(0.0)
  num("[10, 20, 30].at(-1)") |> should.equal(30.0)
}

pub fn array_fill_range_test() {
  // fill(value, start, end): only [start, end) is filled; negatives count from
  // the end; omitted end is the length.
  let m =
    compile(
      "function f() { let a = [0, 0, 0].fill(8, 1, 2); let b = [0, 0, 0, 0, 0].fill(8, -3, 4); "
      <> "let c = [1, 2, 3, 4].fill(9, 2); "
      <> "return a[0]*100 + a[1]*10 + a[2] + '/' + b.join('') + '/' + c.join(''); }",
    )
  // a=[0,8,0]→080; b=[0,0,8,8,0]; c=[1,2,9,9]
  call(m, "f", []) |> should.equal(dyn(<<"80/00880/1299">>))
}

pub fn string_pad_test() {
  let s = compile("function f() { return \"5\".padStart(3, \"0\"); }")
  call(s, "f", []) |> should.equal(dyn(<<"005">>))
  let e = compile("function f() { return \"5\".padEnd(3, \"0\"); }")
  call(e, "f", []) |> should.equal(dyn(<<"500">>))
  let a = compile("function f() { return \"abc\".at(-1); }")
  call(a, "f", []) |> should.equal(dyn(<<"c">>))
}

pub fn string_from_char_code_test() {
  let m = compile("function f() { return String.fromCharCode(72, 105); }")
  call(m, "f", []) |> should.equal(dyn(<<"Hi">>))
}

pub fn date_now_test() {
  let m = compile("function f() { return Date.now() > 0; }")
  call(m, "f", []) |> should.equal(dyn(True))
}

// ── Date: constructor + getters + toISOString ────────────────────────────────
// Spec: ECMA-262 §21.4 (a Date is a number of ms since the Unix epoch). This
// implementation treats local time as UTC, so getX == getUTCX and the component
// constructor / Date.UTC build a UTC instant (documented deviation).

pub fn date_get_time_test() {
  // §21.4.5.10 getTime / thisTimeValue — the stored ms round-trips exactly.
  num("new Date(0).getTime()") |> should.equal(0.0)
  num("new Date(-0).getTime()") |> should.equal(0.0)
  num("new Date(-1).getTime()") |> should.equal(-1.0)
  num("new Date(1).getTime()") |> should.equal(1.0)
  num("new Date(8640000000000000).getTime()")
  |> should.equal(8_640_000_000_000_000.0)
  num("new Date(-8640000000000000).getTime()")
  |> should.equal(-8_640_000_000_000_000.0)
  // valueOf is the same time value (§21.4.5.11).
  num("new Date(1483142400000).valueOf()")
  |> should.equal(1_483_142_400_000.0)
}

pub fn date_out_of_range_is_nan_test() {
  // A time value beyond ±8.64e15 clips to NaN (§21.4.1.31 TimeClip); NaN !== NaN, so
  // the getTime result is the only value not strictly-equal to itself.
  let m =
    compile(
      "function f() { var t = new Date(8640000000000001).getTime(); return t !== t; }",
    )
  call(m, "f", []) |> should.equal(dyn(True))
}

pub fn date_get_utc_full_year_test() {
  // From test262 built-ins/Date/prototype/getUTCFullYear/this-value-valid-date.js:
  // dec31 = 1483142400000 is 2016-12-31T00:00:00Z.
  num("new Date(1483142400000).getUTCFullYear()") |> should.equal(2016.0)
  num("new Date(1483142400000 - 1).getUTCFullYear()") |> should.equal(2016.0)
  num("new Date(1483142400000 + 86400000 - 1).getUTCFullYear()")
  |> should.equal(2016.0)
  num("new Date(1483142400000 + 86400000).getUTCFullYear()")
  |> should.equal(2017.0)
  // The epoch is 1970 (and getFullYear == getUTCFullYear here).
  num("new Date(0).getUTCFullYear()") |> should.equal(1970.0)
  num("new Date(0).getFullYear()") |> should.equal(1970.0)
}

pub fn date_get_utc_fields_test() {
  // 2016-12-31T00:00:00Z: month is 0-based (11 = December), date 31, Saturday (6).
  num("new Date(1483142400000).getUTCMonth()") |> should.equal(11.0)
  num("new Date(1483142400000).getUTCDate()") |> should.equal(31.0)
  num("new Date(1483142400000).getUTCDay()") |> should.equal(6.0)
  // The epoch 1970-01-01 was a Thursday (getUTCDay 4).
  num("new Date(0).getUTCDay()") |> should.equal(4.0)
  num("new Date(0).getUTCMonth()") |> should.equal(0.0)
  num("new Date(0).getUTCDate()") |> should.equal(1.0)
}

pub fn date_get_utc_time_of_day_test() {
  // 01:02:03.004 UTC on the epoch day.
  let t = "(3600000 + 2 * 60000 + 3 * 1000 + 4)"
  num("new Date" <> "(" <> t <> ").getUTCHours()") |> should.equal(1.0)
  num("new Date" <> "(" <> t <> ").getUTCMinutes()") |> should.equal(2.0)
  num("new Date" <> "(" <> t <> ").getUTCSeconds()") |> should.equal(3.0)
  num("new Date" <> "(" <> t <> ").getUTCMilliseconds()") |> should.equal(4.0)
  // Negative times floor into the previous day correctly: -1ms is 1969-12-31T23:59:59.999Z.
  num("new Date(-1).getUTCFullYear()") |> should.equal(1969.0)
  num("new Date(-1).getUTCHours()") |> should.equal(23.0)
  num("new Date(-1).getUTCMinutes()") |> should.equal(59.0)
  num("new Date(-1).getUTCMilliseconds()") |> should.equal(999.0)
}

pub fn date_component_constructor_test() {
  // new Date(year, month, day, …) — treated as UTC here. 2016-12-31 == 1483142400000.
  num("new Date(2016, 11, 31).getTime()") |> should.equal(1_483_142_400_000.0)
  // Month overflow rolls into the year (month 12 → next January).
  num("new Date(2016, 12, 1).getUTCFullYear()") |> should.equal(2017.0)
  num("new Date(2016, 12, 1).getUTCMonth()") |> should.equal(0.0)
  // The two-digit-year rule: 0..99 → 1900+year (§21.4.1.14 MakeFullYear).
  num("new Date(99, 0, 1).getUTCFullYear()") |> should.equal(1999.0)
  num("new Date(0, 0, 1).getUTCFullYear()") |> should.equal(1900.0)
  // Full time components.
  num("new Date(1970, 0, 1, 1, 2, 3, 4).getUTCHours()") |> should.equal(1.0)
  num("new Date(1970, 0, 1, 1, 2, 3, 4).getTime()")
  |> should.equal(3_723_004.0)
}

pub fn date_utc_static_test() {
  // Date.UTC(2016, 11, 31) — a time value (number), not a Date (§21.4.3.4).
  num("Date.UTC(2016, 11, 31)") |> should.equal(1_483_142_400_000.0)
  num("Date.UTC(1970, 0, 1)") |> should.equal(0.0)
  // Missing year → NaN (§21.4.3.4 step 1: ToNumber(undefined) is NaN); NaN !== NaN.
  let m = compile("function f() { var t = Date.UTC(); return t !== t; }")
  call(m, "f", []) |> should.equal(dyn(True))
}

pub fn date_to_iso_string_test() {
  // §21.4.4.36 — the canonical ISO form.
  let m = compile("function f() { return new Date(0).toISOString(); }")
  call(m, "f", []) |> should.equal(dyn(<<"1970-01-01T00:00:00.000Z">>))
  let m2 =
    compile("function f() { return new Date(1483142400000).toISOString(); }")
  call(m2, "f", []) |> should.equal(dyn(<<"2016-12-31T00:00:00.000Z">>))
  // Milliseconds render with three digits.
  let m3 = compile("function f() { return new Date(-1).toISOString(); }")
  call(m3, "f", []) |> should.equal(dyn(<<"1969-12-31T23:59:59.999Z">>))
}

pub fn date_iso_round_trip_test() {
  // new Date(isoString) parses back to the same instant (Date.parse ∘ toISOString).
  num("new Date(\"1970-01-01T00:00:00.000Z\").getTime()") |> should.equal(0.0)
  num("new Date(\"2016-12-31T00:00:00.000Z\").getTime()")
  |> should.equal(1_483_142_400_000.0)
  // Date-only ISO string is UTC midnight.
  num("new Date(\"2016-12-31\").getTime()")
  |> should.equal(1_483_142_400_000.0)
  // Date.parse of an ISO string is the time value.
  num("Date.parse(\"1970-01-01T00:00:00.000Z\")") |> should.equal(0.0)
  // A timezone offset is applied: 01:00+01:00 == 00:00Z.
  num("Date.parse(\"1970-01-01T01:00:00.000+01:00\")") |> should.equal(0.0)
}

pub fn date_timezone_offset_test() {
  // Deviation: local == UTC, so getTimezoneOffset() is always 0.
  num("new Date(0).getTimezoneOffset()") |> should.equal(0.0)
}

pub fn date_parse_extended_year_test() {
  // §21.4.1.15.1 — year 0 is positive: `+000000` is valid, `-000000` (negative zero)
  // is invalid and parses to NaN. (test262 built-ins/Date/parse/year-zero.js.)
  num("Date.parse(\"+000000-01-01T00:00:00.000Z\")")
  |> should.equal(-62_167_219_200_000.0)
  let m =
    compile(
      "function f() { var t = Date.parse(\"-000000-03-31T00:45Z\"); return t !== t; }",
    )
  call(m, "f", []) |> should.equal(dyn(True))
}

// ── Date: setters (§21.4.4.20-30) ────────────────────────────────────────────

pub fn date_set_time_test() {
  // §21.4.4.27 — setTime replaces the time value and returns TimeClip(ToNumber).
  num("new Date(123).setTime(1000)") |> should.equal(1000.0)
  // The mutation is observable through getTime on the same object.
  let m =
    compile(
      "function f() { var d = new Date(123); d.setTime(1000); return d.getTime(); }",
    )
  to_float(call(m, "f", [])) |> should.equal(1000.0)
  // A non-finite argument clips to NaN.
  num(
    "(new Date(0).setTime(Infinity)) !== (new Date(0).setTime(Infinity)) ? 1 : 0",
  )
  |> should.equal(1.0)
}

pub fn date_set_utc_hours_test() {
  // §21.4.4.34 — setUTCHours(1) on the epoch → 01:00:00.000Z == 3_600_000 ms.
  num("new Date(0).setUTCHours(1)") |> should.equal(3_600_000.0)
  // Optional min/sec/ms are applied when supplied (1h 2m 3s 4ms).
  num("new Date(0).setUTCHours(1, 2, 3, 4)") |> should.equal(3_723_004.0)
  // setHours mirrors setUTCHours (local == UTC deviation).
  num("new Date(0).setHours(1)") |> should.equal(3_600_000.0)
}

pub fn date_set_full_year_test() {
  // §21.4.4.21 — setFullYear sets the year, keeping month/date/time-of-day.
  // new Date(0) is 1970-01-01T00:00:00Z, so setFullYear(2015) → 2015-01-01Z.
  num("new Date(0).setFullYear(2015) === Date.UTC(2015, 0, 1) ? 1 : 0")
  |> should.equal(1.0)
  // Optional month/date arguments are honoured.
  num("new Date(0).setFullYear(2015, 5, 10) === Date.UTC(2015, 5, 10) ? 1 : 0")
  |> should.equal(1.0)
  // On an Invalid Date the base time is treated as +0 (so the year still sets).
  num("new Date(NaN).setFullYear(1970) === Date.UTC(1970, 0, 1) ? 1 : 0")
  |> should.equal(1.0)
}

pub fn date_setters_invalid_stay_nan_test() {
  // §21.4.4 — every setter EXCEPT setFullYear leaves an Invalid Date as NaN.
  num("(new Date(NaN).setHours(0)) !== (new Date(NaN).setHours(0)) ? 1 : 0")
  |> should.equal(1.0)
  num("(new Date(NaN).setMonth(0)) !== (new Date(NaN).setMonth(0)) ? 1 : 0")
  |> should.equal(1.0)
}

pub fn date_set_month_overflow_test() {
  // §21.4.4.25 — MakeDay normalizes month overflow into the year: month 13 of
  // 2016 is February 2017, keeping the day-of-month.
  num(
    "new Date(Date.UTC(2016, 0, 15)).setUTCMonth(13) === Date.UTC(2017, 1, 15) ? 1 : 0",
  )
  |> should.equal(1.0)
}

pub fn date_set_date_test() {
  // §21.4.4.20 — setDate replaces the day-of-month; overflow rolls into the month.
  num(
    "new Date(Date.UTC(2016, 0, 1)).setUTCDate(32) === Date.UTC(2016, 1, 1) ? 1 : 0",
  )
  |> should.equal(1.0)
}

// ── Date: human-readable string forms (§21.4.4.35/.42/.43) ────────────────────

pub fn date_to_utc_string_test() {
  // §21.4.4.43 — "Www, DD Mon YYYY HH:mm:ss GMT" (timezone-independent).
  val("new Date(0).toUTCString()")
  |> should.equal(dyn(<<"Thu, 01 Jan 1970 00:00:00 GMT">>))
  // Weekday tracks the actual day (2014-03-23 was a Sunday).
  val("new Date(\"2014-03-23T00:00:00Z\").toUTCString()")
  |> should.equal(dyn(<<"Sun, 23 Mar 2014 00:00:00 GMT">>))
  // A negative (expanded) year is zero-padded to four digits with a leading '-'.
  val("new Date(\"-000001-07-01T00:00Z\").toUTCString()")
  |> should.equal(dyn(<<"Thu, 01 Jul -0001 00:00:00 GMT">>))
  // An Invalid Date renders as "Invalid Date".
  val("new Date(NaN).toUTCString()") |> should.equal(dyn(<<"Invalid Date">>))
}

pub fn date_to_date_and_time_string_test() {
  // §21.4.4.35 — toDateString is "Www Mon DD YYYY".
  val("new Date(0).toDateString()")
  |> should.equal(dyn(<<"Thu Jan 01 1970">>))
  // §21.4.4.42 — toTimeString is "HH:mm:ss GMT+0000" (local == UTC deviation).
  val("new Date(0).toTimeString()")
  |> should.equal(dyn(<<"00:00:00 GMT+0000">>))
  val("new Date(NaN).toDateString()")
  |> should.equal(dyn(<<"Invalid Date">>))
  val("new Date(NaN).toTimeString()")
  |> should.equal(dyn(<<"Invalid Date">>))
}

// ── array finishers + toFixed ────────────────────────────────────────────────

pub fn array_finishers_test() {
  num("[1, 2, 3].flatMap(x => [x, x * 10]).length") |> should.equal(6.0)
  num("[1, 2, 3, 4].findLast(x => x < 3)") |> should.equal(2.0)
  num("[1, 2, 3, 4].findLastIndex(x => x < 3)") |> should.equal(1.0)
  num("[1, 2, 1, 3].lastIndexOf(1)") |> should.equal(2.0)
}

pub fn to_fixed_test() {
  let m = compile("function f() { return (3.14159).toFixed(2); }")
  call(m, "f", []) |> should.equal(dyn(<<"3.14">>))
}

// ── Object.assign / fromEntries ──────────────────────────────────────────────

pub fn object_assign_test() {
  num("Object.assign({ a: 1 }, { b: 2 }, { a: 9 }).a") |> should.equal(9.0)
  num("Object.assign({ a: 1 }, { b: 2 }).b") |> should.equal(2.0)
  // Object.assign returns the (mutated) target itself.
  let ident =
    compile(
      "function f() { let t = {}; return Object.assign(t, { a: 1 }) === t; }",
    )
  call(ident, "f", []) |> should.equal(dyn(True))
}

pub fn object_assign_coerces_sources_test() {
  // Per spec each source is ToObject-coerced: a string source spreads its
  // indexed characters into the target.
  val("Object.assign({}, \"ab\")[0]") |> should.equal(dyn(<<"a">>))
  val("Object.assign({}, \"ab\")[1]") |> should.equal(dyn(<<"b">>))
  // null/undefined sources are skipped (no throw); numbers contribute no keys.
  num("Object.keys(Object.assign({}, null, undefined, 5)).length")
  |> should.equal(0.0)
  // A later source overrides an earlier one; mixed primitive + object sources.
  num("Object.assign({ a: 1 }, \"xy\", { a: 5 }).a") |> should.equal(5.0)
}

pub fn object_from_entries_test() {
  num("Object.fromEntries([[\"a\", 1], [\"b\", 2]]).a") |> should.equal(1.0)
  num("Object.fromEntries(Object.entries({ x: 5 })).x") |> should.equal(5.0)
}

pub fn object_get_own_property_names_test() {
  // getOwnPropertyNames returns the own string keys (like Object.keys here).
  let m =
    compile(
      "function f() { let names = Object.getOwnPropertyNames({ a: 1, b: 2, c: 3 }); return names.length * 100 + (names.indexOf(\"b\") >= 0 ? 1 : 0); }",
    )
  to_float(call(m, "f", [])) |> should.equal(301.0)
}

pub fn object_freeze_returns_object_test() {
  // Object.freeze(o) returns the SAME object (identity), still readable.
  let m =
    compile(
      "function f() { let o = { a: 1 }; let p = Object.freeze(o); return p.a + (o === p ? 100 : 0); }",
    )
  to_float(call(m, "f", [])) |> should.equal(101.0)
}

pub fn object_freeze_blocks_write_test() {
  // A frozen object silently ignores property writes (non-strict mode): the
  // existing prop keeps its value and a new prop is never added.
  let m =
    compile(
      "function f() { let o = Object.freeze({ a: 1 }); o.a = 99; o.b = 5; return o.a * 10 + (o.b === undefined ? 7 : 0); }",
    )
  to_float(call(m, "f", [])) |> should.equal(17.0)
}

pub fn object_freeze_blocks_array_and_delete_test() {
  // A frozen array ignores element writes; delete of a frozen prop is a no-op.
  let m =
    compile(
      "function f() { let a = Object.freeze([1, 2, 3]); a[0] = 9; let o = Object.freeze({ a: 1 }); delete o.a; return a[0] * 10 + o.a; }",
    )
  to_float(call(m, "f", [])) |> should.equal(11.0)
}

pub fn object_is_frozen_test() {
  // isFrozen reflects freeze state and returns a real boolean; a primitive is frozen.
  let m =
    compile(
      "function f() { let o = { a: 1 }; let before = Object.isFrozen(o) === false ? 100 : 0; Object.freeze(o); let after = Object.isFrozen(o) === true ? 10 : 0; let prim = Object.isFrozen(5) === true ? 1 : 0; return before + after + prim; }",
    )
  to_float(call(m, "f", [])) |> should.equal(111.0)
}

// ── Object.is (SameValue) ────────────────────────────────────────────────────

pub fn object_is_same_value_test() {
  // SameValue (ECMAScript §7.2.11): like === but NaN is same-value with NaN.
  val("Object.is(NaN, NaN)") |> should.equal(dyn(True))
  val("Object.is(1, 1)") |> should.equal(dyn(True))
  val("Object.is(1, 1.0)") |> should.equal(dyn(True))
  val("Object.is(1, 2)") |> should.equal(dyn(False))
  val("Object.is(\"a\", \"a\")") |> should.equal(dyn(True))
  val("Object.is(\"a\", \"b\")") |> should.equal(dyn(False))
  val("Object.is(true, true)") |> should.equal(dyn(True))
  val("Object.is(true, false)") |> should.equal(dyn(False))
  val("Object.is(null, null)") |> should.equal(dyn(True))
  val("Object.is(undefined, undefined)") |> should.equal(dyn(True))
  val("Object.is(null, undefined)") |> should.equal(dyn(False))
  // Different JS types are never same-value (no coercion).
  val("Object.is(0, \"0\")") |> should.equal(dyn(False))
  val("Object.is(0, false)") |> should.equal(dyn(False))
  val("Object.is(Infinity, Infinity)") |> should.equal(dyn(True))
  val("Object.is(Infinity, -Infinity)") |> should.equal(dyn(False))
}

pub fn object_is_arity_and_identity_test() {
  // Missing arguments are `undefined`: Object.is() is (undefined,undefined)=true,
  // Object.is(x) is (x,undefined) — false for any non-undefined x.
  val("Object.is()") |> should.equal(dyn(True))
  val("Object.is(0)") |> should.equal(dyn(False))
  // Objects compare by reference identity, never structural equality.
  let same = compile("function f() { let o = {}; return Object.is(o, o); }")
  call(same, "f", []) |> should.equal(dyn(True))
  val("Object.is({}, {})") |> should.equal(dyn(False))
}

pub fn object_is_negative_zero_test() {
  // §7.2.11: +0 and -0 are NOT same-value, but each IS same-value with itself.
  // The integral literal `0.0` collapses to +0 in this model, so a genuine IEEE
  // -0.0 is derived by division (1 / -Infinity → -0, 1 / Infinity → +0).
  let m =
    compile(
      "function f() {"
      <> " let nz = 1 / -Infinity; let pz = 1 / Infinity;"
      <> " return (Object.is(nz, pz) === false ? 1 : 0)"
      <> " + (Object.is(nz, nz) === true ? 10 : 0)"
      <> " + (Object.is(pz, pz) === true ? 100 : 0)"
      <> " + (Object.is(nz, 0) === false ? 1000 : 0);"
      <> " }",
    )
  to_float(call(m, "f", [])) |> should.equal(1111.0)
}

// ── Object.prototype.hasOwnProperty ──────────────────────────────────────────

pub fn object_has_own_property_test() {
  // Returns a real boolean for own vs absent data properties.
  val("({ a: 1 }).hasOwnProperty(\"a\")") |> should.equal(dyn(True))
  val("({ a: 1 }).hasOwnProperty(\"b\")") |> should.equal(dyn(False))
  val("({}).hasOwnProperty(\"x\")") |> should.equal(dyn(False))
  // An accessor (getter) property is still an OWN property.
  val("({ get foo() { return 42; } }).hasOwnProperty(\"foo\")")
  |> should.equal(dyn(True))
  // The argument is ToString-coerced: a number key names the same property.
  val("({ 5: 1 }).hasOwnProperty(5)") |> should.equal(dyn(True))
}

pub fn object_has_own_property_string_receiver_test() {
  // ToObject(string): a String wrapper owns its character indices and "length".
  val("\"abc\".hasOwnProperty(\"0\")") |> should.equal(dyn(True))
  val("\"abc\".hasOwnProperty(\"2\")") |> should.equal(dyn(True))
  val("\"abc\".hasOwnProperty(\"3\")") |> should.equal(dyn(False))
  val("\"abc\".hasOwnProperty(\"length\")") |> should.equal(dyn(True))
}

// ── Object.keys/values/entries — ToObject primitive coercion (ES2015+) ────────

pub fn object_keys_string_coercion_test() {
  // Object.keys("abc") → the index keys "0","1","2" (String exotic object).
  num("Object.keys(\"abc\").length") |> should.equal(3.0)
  val("Object.keys(\"ab\")[0]") |> should.equal(dyn(<<"0">>))
  val("Object.values(\"abc\")[0]") |> should.equal(dyn(<<"a">>))
  val("Object.values(\"abc\")[2]") |> should.equal(dyn(<<"c">>))
  // entries: [["0","a"], ["1","b"]] — check the second pair.
  val("Object.entries(\"ab\")[1][0]") |> should.equal(dyn(<<"1">>))
  val("Object.entries(\"ab\")[1][1]") |> should.equal(dyn(<<"b">>))
  num("Object.getOwnPropertyNames(\"abc\").length") |> should.equal(3.0)
}

pub fn object_keys_number_boolean_coercion_test() {
  // Numbers and booleans coerce to wrappers with no own enumerable keys (not a
  // TypeError, per ES2015+): Object.keys/values return an empty array.
  num("Object.keys(0).length") |> should.equal(0.0)
  num("Object.keys(true).length") |> should.equal(0.0)
  num("Object.values(42).length") |> should.equal(0.0)
  num("Object.entries(false).length") |> should.equal(0.0)
}

// ── integration: many features combined ──────────────────────────────────────

pub fn integration_store_test() {
  // class + method chaining + this + push + object literals + reduce/filter/map
  // closures (capturing a method param) + join + string length
  let m =
    compile(
      "class Store { constructor() { this.items = []; } add(name, price) { this.items.push({ name: name, price: price }); return this; } total() { return this.items.reduce((sum, it) => sum + it.price, 0); } names(threshold) { return this.items.filter(it => it.price > threshold).map(it => it.name).join(\",\"); } } function run() { let s = new Store(); s.add(\"apple\", 3).add(\"laptop\", 1000).add(\"book\", 15); return s.total() * 10000 + s.names(10).length; }",
    )
  // total = 1018 → 10180000; names = "laptop,book" (length 11) → 10180011
  to_float(call(m, "run", [])) |> should.equal(10_180_011.0)
}

pub fn integration_pipeline_test() {
  // for-loop + array building + filter/map/reduce chain with closures
  let m =
    compile(
      "function run() { let nums = []; for (let i = 1; i <= 10; i++) { nums.push(i); } return nums.filter(n => n % 2 === 0).map(n => n * n).reduce((a, b) => a + b, 0); }",
    )
  // evens 2,4,6,8,10 → squares → 4+16+36+64+100 = 220
  to_float(call(m, "run", [])) |> should.equal(220.0)
}

pub fn integration_closure_object_test() {
  // a factory returning an object of arrows sharing a captured mutable object
  let m =
    compile(
      "function makeCounter() { let state = { n: 0 }; return { inc: () => { state.n = state.n + 1; return state.n; }, get: () => state.n }; } function run() { let c = makeCounter(); c.inc(); c.inc(); c.inc(); return c.get(); }",
    )
  to_float(call(m, "run", [])) |> should.equal(3.0)
}

pub fn integration_json_roundtrip_test() {
  // build data, stringify, parse back, and read through it
  let m =
    compile(
      "function run() { let people = [{ name: \"Ann\", age: 30 }, { name: \"Bob\", age: 25 }]; let json = JSON.stringify(people); let back = JSON.parse(json); return back[0].age + back[1].age; }",
    )
  to_float(call(m, "run", [])) |> should.equal(55.0)
}

// ── static class methods ─────────────────────────────────────────────────────

pub fn class_static_test() {
  let m =
    compile(
      "class MathUtils { static square(x) { return x * x; } static add(a, b) { return a + b; } } function f() { return MathUtils.square(5) + MathUtils.add(2, 3); }",
    )
  to_float(call(m, "f", [])) |> should.equal(30.0)
}

pub fn class_static_calls_static_test() {
  let m =
    compile(
      "class C { static base() { return 10; } static compute(x) { return C.base() + x; } } function f() { return C.compute(5); }",
    )
  to_float(call(m, "f", [])) |> should.equal(15.0)
}

// ── comma / in / delete / instanceof ─────────────────────────────────────────

pub fn comma_operator_test() {
  num("(1, 2, 3)") |> should.equal(3.0)
}

pub fn in_operator_test() {
  let m = compile("function f() { let o = { a: 1 }; return \"a\" in o; }")
  call(m, "f", []) |> should.equal(dyn(True))
  let n = compile("function f() { let o = { a: 1 }; return \"b\" in o; }")
  call(n, "f", []) |> should.equal(dyn(False))
}

pub fn delete_test() {
  let m =
    compile(
      "function f() { let o = { a: 1, b: 2 }; delete o.a; return \"a\" in o; }",
    )
  call(m, "f", []) |> should.equal(dyn(False))
}

const ab_src = "class A { constructor() {} } class B extends A { constructor() { super(); } } "

pub fn instanceof_test() {
  let b =
    compile(
      ab_src <> "function f() { let x = new B(); return x instanceof B; }",
    )
  call(b, "f", []) |> should.equal(dyn(True))
  // instanceof a superclass is true
  let a =
    compile(
      ab_src <> "function f() { let x = new B(); return x instanceof A; }",
    )
  call(a, "f", []) |> should.equal(dyn(True))
}

// ── labeled break / continue ─────────────────────────────────────────────────

pub fn labeled_break_test() {
  let m =
    compile(
      "function f() { let count = 0; outer: for (let i = 0; i < 5; i++) { for (let j = 0; j < 5; j++) { if (i * j >= 6) { break outer; } count++; } } return count; }",
    )
  to_float(call(m, "f", [])) |> should.equal(13.0)
}

pub fn labeled_continue_test() {
  let m =
    compile(
      "function f() { let count = 0; outer: for (let i = 0; i < 3; i++) { for (let j = 0; j < 3; j++) { if (j === 1) { continue outer; } count++; } } return count; }",
    )
  to_float(call(m, "f", [])) |> should.equal(3.0)
}

// ── toString ─────────────────────────────────────────────────────────────────

pub fn to_string_test() {
  let h = compile("function f() { return (255).toString(16); }")
  call(h, "f", []) |> should.equal(dyn(<<"ff">>))
  let n = compile("function f() { return (5).toString(); }")
  call(n, "f", []) |> should.equal(dyn(<<"5">>))
  let a = compile("function f() { return [1, 2, 3].toString(); }")
  call(a, "f", []) |> should.equal(dyn(<<"1,2,3">>))
  // a user-defined toString() method wins
  let c =
    compile(
      "class C { toString() { return \"custom\"; } } function f() { let o = new C(); return o.toString(); }",
    )
  call(c, "f", []) |> should.equal(dyn(<<"custom">>))
}

// ── regex ────────────────────────────────────────────────────────────────────

pub fn regex_test_test() {
  let m = compile("function f() { return /\\d+/.test(\"abc123\"); }")
  call(m, "f", []) |> should.equal(dyn(True))
  let n = compile("function f() { return /\\d+/.test(\"abc\"); }")
  call(n, "f", []) |> should.equal(dyn(False))
  // caseless flag
  let i = compile("function f() { return /foo/i.test(\"A FOO B\"); }")
  call(i, "f", []) |> should.equal(dyn(True))
}

pub fn regex_replace_test() {
  let m =
    compile("function f() { return \"hello world\".replace(/o/g, \"0\"); }")
  call(m, "f", []) |> should.equal(dyn(<<"hell0 w0rld">>))
  // backreference $1
  let b =
    compile(
      "function f() { return \"John Smith\".replace(/(\\w+) (\\w+)/, \"$2 $1\"); }",
    )
  call(b, "f", []) |> should.equal(dyn(<<"Smith John">>))
}

pub fn regex_match_split_test() {
  num("\"a1b2c3\".match(/\\d/g).length") |> should.equal(3.0)
  num("\"a,b;c\".split(/[,;]/).length") |> should.equal(3.0)
}

// ── RegExp.prototype.exec (test262 built-ins/RegExp/prototype/exec) ───────────
// §22.2.7.2 RegExpBuiltinExec: exec returns `[matched, cap1…capN]` with own
// `index`/`input`/`groups`, or `null`.
pub fn regex_exec_test() {
  // No match → null.
  val("/x/.exec(\"abc\") === null") |> should.equal(dyn(True))
  // Leftmost match; array holds the whole match; index/input are own props.
  num("/1|12/.exec(\"123\").length") |> should.equal(1.0)
  num("/1|12/.exec(\"123\").index") |> should.equal(0.0)
  val("/1|12/.exec(\"123\")[0]") |> should.equal(dyn(<<"1">>))
  val("/1|12/.exec(\"123\").input") |> should.equal(dyn(<<"123">>))
  // Capture groups populate indices 1..N; index is the match start.
  val("/(a)(b)/.exec(\"zab\")[1]") |> should.equal(dyn(<<"a">>))
  val("/(a)(b)/.exec(\"zab\")[2]") |> should.equal(dyn(<<"b">>))
  num("/(a)(b)/.exec(\"zab\").index") |> should.equal(1.0)
  // A trailing optional group that did not participate is `undefined` but still
  // occupies its slot, so `length` reflects the total group count (here 3).
  num("/(a)(b)?/.exec(\"a\").length") |> should.equal(3.0)
  val("/(a)(b)?/.exec(\"a\")[2] === undefined") |> should.equal(dyn(True))
  // Named captures land in `groups`; absent when the pattern has none.
  val("/(?<y>a)/.exec(\"a\").groups.y") |> should.equal(dyn(<<"a">>))
  val("/a/.exec(\"a\").groups === undefined") |> should.equal(dyn(True))
}

// exec/test update `lastIndex` for a global or sticky regex (to the code-point
// index past the match), and leave it untouched otherwise (§22.2.7.2 step 15).
pub fn regex_lastindex_test() {
  // Non-global: lastIndex is never written.
  let a =
    compile("function f() { var r = /a/; r.exec(\"a\"); return r.lastIndex; }")
  to_float(call(a, "f", [])) |> should.equal(0.0)
  // Global: advanced to the end of the match.
  let g =
    compile(
      "function f() { var r = /a/g; r.exec(\"aXa\"); return r.lastIndex; }",
    )
  to_float(call(g, "f", [])) |> should.equal(1.0)
  // Sticky test() also sets lastIndex to the match end.
  let y =
    compile(
      "function f() { var r = /abc/y; r.test(\"abc\"); return r.lastIndex; }",
    )
  to_float(call(y, "f", [])) |> should.equal(3.0)
  // A user-assigned lastIndex is honoured as the search start (global).
  let s =
    compile(
      "function f() { var r = /a/g; r.lastIndex = 2; return r.exec(\"aaa\").index; }",
    )
  to_float(call(s, "f", [])) |> should.equal(2.0)
  // Global test() walks matches then resets on failure: /a/g over "aa" is
  // true, true, false → 2 successes.
  let t =
    compile(
      "function f() { var r = /a/g; var n = 0; if (r.test(\"aa\")) n++; if (r.test(\"aa\")) n++; if (r.test(\"aa\")) n++; return n; }",
    )
  to_float(call(t, "f", [])) |> should.equal(2.0)
}

// The RegExp flag getters (test262 built-ins/RegExp/prototype/{global,sticky,…}).
pub fn regex_getters_test() {
  val("/abc/.source") |> should.equal(dyn(<<"abc">>))
  val("/a/g.global") |> should.equal(dyn(True))
  val("/a/.global") |> should.equal(dyn(False))
  val("/a/i.ignoreCase") |> should.equal(dyn(True))
  val("/a/m.multiline") |> should.equal(dyn(True))
  val("/a/s.dotAll") |> should.equal(dyn(True))
  val("/a/y.sticky") |> should.equal(dyn(True))
  val("/a/u.unicode") |> should.equal(dyn(True))
  val("/a/d.hasIndices") |> should.equal(dyn(True))
  val("/a/.sticky") |> should.equal(dyn(False))
}

// String.prototype.search (test262 built-ins/String/prototype/search): the
// code-point index of the first match, or -1.
pub fn regex_search_test() {
  num("\"abcdef\".search(/cd/)") |> should.equal(2.0)
  num("\"hello\".search(/l/)") |> should.equal(2.0)
  num("\"abc\".search(/x/)") |> should.equal(-1.0)
}

// String.prototype.match, non-global: returns the exec array (with captures and
// `index`); global: an array of every matched substring, else null.
pub fn regex_match_more_test() {
  num("\"abc123\".match(/(\\d)(\\d)/).length") |> should.equal(3.0)
  num("\"abc123\".match(/\\d+/).index") |> should.equal(3.0)
  val("\"abc\".match(/x/) === null") |> should.equal(dyn(True))
  val("\"a1b2\".match(/\\d/g)[1]") |> should.equal(dyn(<<"2">>))
}

// String.prototype.split with a regex (test262 .../split/separator-regexp):
// capturing groups are spliced into the output and empty matches follow the JS
// (not PCRE) rules.
pub fn regex_split_more_test() {
  // Captures appear between the surrounding pieces.
  num("\"a1b2c\".split(/(\\d)/).length") |> should.equal(5.0)
  val("\"a1b2c\".split(/(\\d)/)[1]") |> should.equal(dyn(<<"1">>))
  // A zero-width match at the start is not a split point: "x".split(/^/) → ["x"].
  num("\"x\".split(/^/).length") |> should.equal(1.0)
  // "xx".split(/a*/) → ["x","x"] (empty matches between characters).
  num("\"xx\".split(/a*/).length") |> should.equal(2.0)
}

// String.prototype.replace with a regex (test262 .../replace/*): GetSubstitution
// expands `$&`, `` $` ``, `$'`, `$$`, `$n`/`$nn`, and `$<name>`; a function
// replacer receives (match, …captures, position, string).
pub fn regex_replace_substitution_test() {
  val("\"abc\".replace(/b/, \"[$&]\")") |> should.equal(dyn(<<"a[b]c">>))
  val("\"abc\".replace(/b/, \"$`\")") |> should.equal(dyn(<<"aac">>))
  val("\"abc\".replace(/b/, \"$'\")") |> should.equal(dyn(<<"acc">>))
  val("\"abc\".replace(/b/, \"$$\")") |> should.equal(dyn(<<"a$c">>))
  // `$0` is a literal (not a capture index); `$1`/`$2` are captures.
  val("\"foo-x-bar\".replace(/x/, \"|$0|\")")
  |> should.equal(dyn(<<"foo-|$0|-bar">>))
  // Named-group substitution.
  val("\"2024-01\".replace(/(?<y>\\d+)-(?<m>\\d+)/, \"$<m>/$<y>\")")
  |> should.equal(dyn(<<"01/2024">>))
  // Function replacer over a global regex.
  let f =
    compile(
      "function f() { return \"a1b2\".replace(/\\d/g, function(m){ return \"[\" + m + \"]\"; }); }",
    )
  call(f, "f", []) |> should.equal(dyn(<<"a[1]b[2]">>))
  // replaceAll requires a global regex; a global one replaces every match.
  val("\"a.b.c\".replaceAll(/\\./g, \"-\")") |> should.equal(dyn(<<"a-b-c">>))
  // A non-global regex passed to replaceAll is a TypeError (§22.1.3.20).
  let bad = compile("function f() { return \"a\".replaceAll(/a/, \"b\"); }")
  catch_apply(bad, atom.create("f"), []) |> should.be_error
}

// ── Map / Set ────────────────────────────────────────────────────────────────

pub fn map_test() {
  let m =
    compile(
      "function f() { let m = new Map(); m.set(\"a\", 1); m.set(\"b\", 2); return m.get(\"a\") + m.size; }",
    )
  to_float(call(m, "f", [])) |> should.equal(3.0)
  // has / delete
  let d =
    compile(
      "function f() { let m = new Map(); m.set(\"x\", 5); let h1 = m.has(\"x\"); m.delete(\"x\"); let h2 = m.has(\"x\"); return h1 && !h2; }",
    )
  call(d, "f", []) |> should.equal(dyn(True))
  // seeded from pairs
  let s =
    compile(
      "function f() { let m = new Map([[\"a\", 1], [\"b\", 2]]); return m.get(\"b\"); }",
    )
  to_float(call(s, "f", [])) |> should.equal(2.0)
}

pub fn set_test() {
  let m =
    compile(
      "function f() { let s = new Set(); s.add(1); s.add(2); s.add(1); return s.size; }",
    )
  to_float(call(m, "f", [])) |> should.equal(2.0)
  let seed =
    compile("function f() { let s = new Set([1, 2, 2, 3]); return s.size; }")
  to_float(call(seed, "f", [])) |> should.equal(3.0)
}

pub fn set_foreach_test() {
  let m =
    compile(
      "function f() { let out = []; new Set([1, 2, 3]).forEach(v => out.push(v)); return out.length; }",
    )
  to_float(call(m, "f", [])) |> should.equal(3.0)
}

pub fn method_delegation_test() {
  // a user object's own `set` method isn't clobbered by the Map dispatch
  let m =
    compile("function f() { let o = { set: x => x * 2 }; return o.set(21); }")
  to_float(call(m, "f", [])) |> should.equal(42.0)
}

pub fn map_delete_returns_boolean_test() {
  // 24.1.3.3 Map.prototype.delete returns `true` only when it actually removes an
  // entry; a key that is absent (or was already deleted) yields `false`.
  let m =
    compile(
      "function f() { let m = new Map([[\"a\", 1]]); return m.delete(\"a\") === true && m.delete(\"a\") === false && m.delete(\"z\") === false; }",
    )
  call(m, "f", []) |> should.equal(dyn(True))
}

pub fn set_delete_returns_boolean_test() {
  // 24.2.3.4 Set.prototype.delete returns `true` only when it removes a value.
  let m =
    compile(
      "function f() { let s = new Set([1]); return s.delete(1) === true && s.delete(1) === false && s.delete(9) === false; }",
    )
  call(m, "f", []) |> should.equal(dyn(True))
}

pub fn map_foreach_insertion_order_test() {
  // 24.1.3.5 forEach visits entries in insertion order. Re-`set`ting an existing key
  // keeps its position (only the value changes); a delete-then-re-insert appends it.
  let m =
    compile(
      "function f() { let m = new Map(); m.set(\"a\", 1); m.set(\"b\", 2); m.set(\"c\", 3); m.set(\"a\", 9); m.delete(\"b\"); m.set(\"b\", 5); let out = []; m.forEach((v, k) => out.push(k + v)); return out.join(\",\"); }",
    )
  call(m, "f", []) |> should.equal(dyn("a9,c3,b5"))
}

pub fn map_foreach_deleted_during_test() {
  // 24.1.3.5 an entry deleted before it is reached during iteration is not visited.
  let m =
    compile(
      "function f() { let m = new Map(); m.set(\"a\", 0); m.set(\"b\", 1); let out = []; m.forEach((v, k) => { if (k === \"a\") { m.delete(\"b\"); } out.push(k); }); return out.join(\",\"); }",
    )
  call(m, "f", []) |> should.equal(dyn("a"))
}

pub fn map_foreach_added_during_test() {
  // 24.1.3.5 an entry appended during iteration IS visited before forEach returns.
  let m =
    compile(
      "function f() { let m = new Map(); m.set(\"a\", 1); let out = []; m.forEach((v, k) => { if (k === \"a\") { m.set(\"b\", 2); } out.push(k); }); return out.join(\",\"); }",
    )
  call(m, "f", []) |> should.equal(dyn("a,b"))
}

pub fn map_samevaluezero_keys_test() {
  // 24.1.3 Map keys compare with SameValueZero: NaN keys coincide, -0 and +0 are one
  // key, and 1 and 1.0 are the same numeric key (there is one JS Number type).
  let nan =
    compile(
      "function f() { let m = new Map(); m.set(NaN, \"x\"); return m.get(NaN) + \",\" + m.size; }",
    )
  call(nan, "f", []) |> should.equal(dyn("x,1"))
  let zero =
    compile(
      "function f() { let m = new Map(); m.set(-0, \"a\"); m.set(0, \"b\"); return m.get(-0) + \",\" + m.size; }",
    )
  call(zero, "f", []) |> should.equal(dyn("b,1"))
  let int_float =
    compile(
      "function f() { let m = new Map(); m.set(1, \"i\"); return m.get(1.0) + \",\" + m.has(1.0); }",
    )
  call(int_float, "f", []) |> should.equal(dyn("i,true"))
}

pub fn map_iterators_test() {
  // 24.1.3.8/.10/.4 keys()/values()/entries() return an iterator whose .next() yields
  // {value, done} in insertion order, then {value: undefined, done: true} when spent.
  let keys =
    compile(
      "function f() { let m = new Map([[\"a\", 1], [\"b\", 2]]); let it = m.keys(); let r1 = it.next(); let r2 = it.next(); let r3 = it.next(); return r1.value + r2.value + \",\" + r3.done + \",\" + r3.value; }",
    )
  call(keys, "f", []) |> should.equal(dyn("ab,true,undefined"))
  let values =
    compile(
      "function f() { let m = new Map([[\"a\", 10], [\"b\", 20]]); let out = 0; let it = m.values(); let r = it.next(); while (!r.done) { out += r.value; r = it.next(); } return out; }",
    )
  to_float(call(values, "f", [])) |> should.equal(30.0)
  let entries =
    compile(
      "function f() { let m = new Map([[\"a\", 1]]); let it = m.entries(); let r = it.next(); return r.value[0] + \"=\" + r.value[1]; }",
    )
  call(entries, "f", []) |> should.equal(dyn("a=1"))
}

pub fn set_values_iterator_test() {
  // 24.2.3.10 Set.prototype.values iterates the set's values in insertion order.
  let m =
    compile(
      "function f() { let s = new Set([3, 1, 2]); let it = s.values(); let out = \"\"; let r = it.next(); while (!r.done) { out += r.value; r = it.next(); } return out; }",
    )
  call(m, "f", []) |> should.equal(dyn("312"))
}

pub fn set_foreach_order_test() {
  // 24.2.3.6 Set.prototype.forEach visits values in insertion order and calls back
  // with (value, value, set) — a Set's key is its value.
  let m =
    compile(
      "function f() { let s = new Set(); s.add(2); s.add(1); s.add(2); let out = []; s.forEach((v, k) => out.push(v + \":\" + k)); return out.join(\",\"); }",
    )
  call(m, "f", []) |> should.equal(dyn("2:2,1:1"))
}

// ── call spread ──────────────────────────────────────────────────────────────

pub fn call_spread_test() {
  num("Math.max(...[3, 1, 4, 1, 5])") |> should.equal(5.0)
  let m =
    compile(
      "function add3(a, b, c) { return a + b + c; } function run() { let args = [10, 20, 30]; return add3(...args); }",
    )
  to_float(call(m, "run", [])) |> should.equal(60.0)
  // mixed regular arg + spread
  let x =
    compile(
      "function f(a, b, c) { return a * 100 + b * 10 + c; } function run() { return f(1, ...[2, 3]); }",
    )
  to_float(call(x, "run", [])) |> should.equal(123.0)
  // spread into a closure
  let c =
    compile(
      "function run() { let f = (a, b, c) => a + b + c; return f(...[1, 2, 3]); }",
    )
  to_float(call(c, "run", [])) |> should.equal(6.0)
}

// ── rest parameters ──────────────────────────────────────────────────────────

pub fn rest_params_test() {
  let m =
    compile(
      "function sum(...nums) { let t = 0; for (let n of nums) { t += n; } return t; } function run() { return sum(1, 2, 3, 4); }",
    )
  to_float(call(m, "run", [])) |> should.equal(10.0)
  // a fixed param followed by rest
  let f =
    compile(
      "function g(a, ...rest) { return a * 100 + rest.length; } function run() { return g(1, 2, 3, 4); }",
    )
  to_float(call(f, "run", [])) |> should.equal(103.0)
  // empty rest
  let e =
    compile(
      "function g(...args) { return args.length; } function run() { return g(); }",
    )
  to_float(call(e, "run", [])) |> should.equal(0.0)
}

pub fn rest_spread_forward_test() {
  // collect args with rest, forward them with spread
  let m =
    compile(
      "function inner(a, b) { return a + b; } function wrap(...args) { return inner(...args); } function run() { return wrap(5, 7); }",
    )
  to_float(call(m, "run", [])) |> should.equal(12.0)
}

// ── nested destructuring ─────────────────────────────────────────────────────

pub fn nested_destructure_test() {
  let m =
    compile("function f() { let [[a, b], c] = [[1, 2], 3]; return a + b + c; }")
  to_float(call(m, "f", [])) |> should.equal(6.0)
  let o =
    compile("function f() { let { p: { q } } = { p: { q: 7 } }; return q; }")
  to_float(call(o, "f", [])) |> should.equal(7.0)
  // object with a nested array value
  let x =
    compile(
      "function f() { let { arr: [a, b] } = { arr: [10, 20] }; return a + b; }",
    )
  to_float(call(x, "f", [])) |> should.equal(30.0)
}

// ── lowering correctness (spec regressions) ─────────────────────────────────

pub fn ssa_name_collision_test() {
  // A user identifier shaped like a compiler temp (v0, v1, L0) must not be
  // shadowed by a generated SSA temporary or label. Regression: a parameter
  // named `v0` used to collapse into the first generated temp and return 2.
  let a = compile("function f(v0) { return v0 + 1; }")
  to_float(call(a, "f", [dyn(5)])) |> should.equal(6.0)

  let b = compile("function f(v0, v1) { return v0 * v1; }")
  to_float(call(b, "f", [dyn(3), dyn(4)])) |> should.equal(12.0)

  // v0 stays live across many generated temps (each `+` mints a guard temp).
  let c =
    compile(
      "function f(v0) { let s = 0; for (let i = 0; i < 4; i++) { s = s + v0; } return s; }",
    )
  to_float(call(c, "f", [dyn(2)])) |> should.equal(8.0)

  // A user variable named like a label temp.
  let d = compile("function f() { let L0 = 1; let L1 = 4; return L0 + L1; }")
  to_float(call(d, "f", [])) |> should.equal(5.0)
}

pub fn global_constants_test() {
  // NaN and Infinity are number-typed global constants.
  val("typeof NaN") |> should.equal(dyn(<<"number">>))
  val("typeof Infinity") |> should.equal(dyn(<<"number">>))
  // NaN is not equal to itself.
  val("NaN === NaN") |> should.equal(dyn(False))
  val("NaN !== NaN") |> should.equal(dyn(True))
  // Infinity is the value of 1/0 and exceeds any finite double.
  val("Infinity === 1 / 0") |> should.equal(dyn(True))
  val("Infinity > 1e308") |> should.equal(dyn(True))
  val("isNaN(NaN)") |> should.equal(dyn(True))
  val("isFinite(Infinity)") |> should.equal(dyn(False))
  // NaN is now usable as a literal in expressions.
  val("[NaN, 1].includes(NaN)") |> should.equal(dyn(True))
  // A local binding shadows the global.
  num("(function(){ let NaN = 5; return NaN + 1; })()") |> should.equal(6.0)
}

pub fn super_method_arity_test() {
  // super.pick(10) where the parent method takes (a, b): b defaults to undefined
  // and is unused, so the result is 10. Regression: an under-applied super call
  // used to fail to compile with an arity mismatch.
  let m =
    compile(
      "class A { constructor() {} pick(a, b) { return a; } } "
      <> "class B extends A { constructor() { super(); } pick() { return super.pick(10); } } "
      <> "function f() { let b = new B(); return b.pick(); }",
    )
  to_float(call(m, "f", [])) |> should.equal(10.0)

  // Over-application: the extra arguments are dropped.
  let n =
    compile(
      "class A { constructor() {} one(a) { return a; } } "
      <> "class B extends A { constructor() { super(); } one() { return super.one(3, 9, 27); } } "
      <> "function f() { let b = new B(); return b.one(); }",
    )
  to_float(call(n, "f", [])) |> should.equal(3.0)
}

pub fn tagged_template_test() {
  // The tag receives the cooked strings array plus the substitutions in order.
  let m =
    compile(
      "function tag(s, a, b) { return s[0] + a + s[1] + b + s[2]; } "
      <> "function f() { let x = 2, y = 3; return tag`sum ${x} and ${y}!`; }",
    )
  call(m, "f", []) |> should.equal(dyn(<<"sum 2 and 3!">>))

  // s.raw is the verbatim source of each quasi (keeps the backslash).
  let n =
    compile(
      "function tag(s) { return s.raw[0]; } function f() { return tag`line\\n`; }",
    )
  call(n, "f", []) |> should.equal(dyn(<<"line\\n">>))

  // Cooked decodes the \n escape (5 code points); raw keeps the backslash (6).
  let c =
    compile(
      "function tag(s) { return s[0].length + \",\" + s.raw[0].length; } function f() { return tag`line\\n`; }",
    )
  call(c, "f", []) |> should.equal(dyn(<<"5,6">>))

  // A tag can be a local closure, and a no-substitution template works.
  let d =
    compile("function f() { let t = (s) => s[0].toUpperCase(); return t`hi`; }")
  call(d, "f", []) |> should.equal(dyn(<<"HI">>))
}

pub fn string_raw_test() {
  // String.raw is the default tag: it keeps the backslash escapes verbatim.
  let m = compile("function f() { return String.raw`a\\nb`; }")
  call(m, "f", []) |> should.equal(dyn(<<"a\\nb">>))
  // Substitutions are interleaved between the raw segments.
  let n = compile("function f() { let x = 5; return String.raw`v=${x}\\t!`; }")
  call(n, "f", []) |> should.equal(dyn(<<"v=5\\t!">>))
}

pub fn reduce_right_test() {
  // reduceRight folds from the right; order matters for subtraction.
  // no init: ((4 - 3) - 2) - 1 = -2
  num("[1, 2, 3, 4].reduceRight(function(a, b) { return a - b; })")
  |> should.equal(-2.0)
  // with init: ((10 - 3) - 2) - 1 = 4
  num("[1, 2, 3].reduceRight(function(a, b) { return a - b; }, 10)")
  |> should.equal(4.0)
  // builds a string right-to-left.
  val("['a', 'b', 'c'].reduceRight(function(a, b) { return a + b; })")
  |> should.equal(dyn(<<"cba">>))
}

pub fn code_point_at_test() {
  num("'ABC'.codePointAt(0)") |> should.equal(65.0)
  num("'ABC'.codePointAt(2)") |> should.equal(67.0)
}

pub fn from_code_point_test() {
  val("String.fromCodePoint(65, 66, 67)") |> should.equal(dyn(<<"ABC">>))
  // fromCodePoint does NOT mask to 16 bits (unlike fromCharCode): astral char.
  num("String.fromCodePoint(128512).length") |> should.equal(1.0)
}

pub fn logical_assign_test() {
  // ||= assigns only when the current value is falsy.
  num("(function(){ let x = 0; x ||= 5; return x; })()") |> should.equal(5.0)
  num("(function(){ let x = 3; x ||= 5; return x; })()") |> should.equal(3.0)
  // &&= assigns only when truthy.
  num("(function(){ let x = 3; x &&= 7; return x; })()") |> should.equal(7.0)
  num("(function(){ let x = 0; x &&= 7; return x; })()") |> should.equal(0.0)
  // ??= assigns only when null/undefined — 0 is NOT nullish.
  num("(function(){ let x = 0; x ??= 5; return x; })()") |> should.equal(0.0)
  num("(function(){ let x; x ??= 5; return x; })()") |> should.equal(5.0)
  // short-circuit: the rhs is not evaluated when the guard fails.
  num("(function(){ let x = 1; let n = 0; x ||= (n = 9); return n; })()")
  |> should.equal(0.0)
  // member target: obj.p ??= v assigns once, then leaves the set value.
  num("(function(){ let o = {}; o.a ??= 10; o.a ??= 20; return o.a; })()")
  |> should.equal(10.0)
  // member ||= writes through when the current property value is falsy.
  num("(function(){ let o = { a: 0 }; o.a ||= 42; return o.a; })()")
  |> should.equal(42.0)
}

pub fn number_constants_test() {
  num("Number.MAX_SAFE_INTEGER") |> should.equal(9_007_199_254_740_991.0)
  num("Number.MIN_SAFE_INTEGER") |> should.equal(-9_007_199_254_740_991.0)
  val("Number.MAX_SAFE_INTEGER === 9007199254740991")
  |> should.equal(dyn(True))
  // MAX_SAFE_INTEGER is a boxed integer, so exact integer arithmetic applies.
  val("Number.MAX_SAFE_INTEGER + 1 === 9007199254740992")
  |> should.equal(dyn(True))
  val("Number.EPSILON > 0") |> should.equal(dyn(True))
  val("typeof Number.MAX_VALUE") |> should.equal(dyn(<<"number">>))
  val("Number.POSITIVE_INFINITY === Infinity") |> should.equal(dyn(True))
  val("Number.NEGATIVE_INFINITY === -Infinity") |> should.equal(dyn(True))
  val("Number.NaN !== Number.NaN") |> should.equal(dyn(True))
}

pub fn class_getter_test() {
  // A getter computes its value on property access.
  let m =
    compile(
      "class C { constructor(r) { this.r = r; } get area() { return this.r * this.r; } } "
      <> "function f() { let c = new C(3); return c.area; }",
    )
  to_float(call(m, "f", [])) |> should.equal(9.0)
}

pub fn class_setter_test() {
  // A setter runs on assignment; the paired getter reads it back.
  let m =
    compile(
      "class C { constructor() { this._v = 0; } get v() { return this._v; } set v(x) { this._v = x * 2; } } "
      <> "function f() { let c = new C(); c.v = 5; return c.v; }",
    )
  to_float(call(m, "f", [])) |> should.equal(10.0)
}

pub fn accessor_inheritance_test() {
  let base = "class A { get kind() { return \"A\"; } } "
  // a subclass inherits the parent's accessor…
  let m =
    compile(
      base
      <> "class B extends A { constructor() { super(); } } "
      <> "function f() { let b = new B(); return b.kind; }",
    )
  call(m, "f", []) |> should.equal(dyn(<<"A">>))
  // …and can override it.
  let n =
    compile(
      base
      <> "class B extends A { constructor() { super(); } get kind() { return \"B\"; } } "
      <> "function f() { let b = new B(); return b.kind; }",
    )
  call(n, "f", []) |> should.equal(dyn(<<"B">>))
}

pub fn getter_no_leak_test() {
  // Enumeration and JSON must INVOKE the getter (sentinel 777), never expose the
  // raw accessor marker — a leaked marker would fail these membership checks.
  let src = "class C { get magic() { return 777; } } "
  let m =
    compile(
      src <> "function f() { return Object.values(new C()).includes(777); }",
    )
  call(m, "f", []) |> should.equal(dyn(True))
  let n =
    compile(
      src
      <> "function f() { return JSON.stringify(new C()).includes(\"777\"); }",
    )
  call(n, "f", []) |> should.equal(dyn(True))
}

pub fn static_field_test() {
  // A static field initialised at the class's position (run when `main` runs).
  let m =
    compile("class C { static answer = 42; } function f() { return C.answer; }")
  call(m, "main", [])
  to_float(call(m, "f", [])) |> should.equal(42.0)
  // no initializer → undefined.
  let n = compile("class C { static x; } function f() { return typeof C.x; }")
  call(n, "main", [])
  call(n, "f", []) |> should.equal(dyn(<<"undefined">>))
}

pub fn static_field_mutation_test() {
  // A static method reads and writes the class's static field.
  let m =
    compile(
      "class Counter { static count = 0; static inc() { Counter.count = Counter.count + 1; return Counter.count; } } "
      <> "function f() { return Counter.inc() + Counter.inc(); } ",
    )
  call(m, "main", [])
  // inc() → 1, inc() → 2, so 1 + 2 = 3
  to_float(call(m, "f", [])) |> should.equal(3.0)
  // compound assignment on a static field.
  let n =
    compile(
      "class S { static total = 10; } function f() { S.total += 5; return S.total; }",
    )
  call(n, "main", [])
  to_float(call(n, "f", [])) |> should.equal(15.0)
}

pub fn do_while_continue_test() {
  // `continue` in a do/while jumps to the condition test (skips the rest of the
  // body but re-tests the loop condition). Sum the odd numbers 1..5.
  num(
    "(function(){ let i = 0, s = 0; do { i++; if (i % 2 === 0) continue; s += i; } while (i < 5); return s; })()",
  )
  |> should.equal(9.0)
  // A continue on the final iteration still exits when the condition is false.
  num(
    "(function(){ let i = 0, n = 0; do { i++; if (i === 3) continue; n++; } while (i < 3); return n; })()",
  )
  |> should.equal(2.0)
}

pub fn defaulted_destructure_test() {
  // A missing array element falls back to its default.
  num("(function(){ let [a, b = 9] = [1]; return a + b; })()")
  |> should.equal(10.0)
  // Explicit undefined triggers the default…
  num("(function(){ let [a = 5] = [undefined]; return a; })()")
  |> should.equal(5.0)
  // …but null does NOT (the default is only for undefined).
  val("(function(){ let [a = 5] = [null]; return a === null; })()")
  |> should.equal(dyn(True))
  // Object property default, and a present value overrides the default.
  num("(function(){ let { x, y = 7 } = { x: 1 }; return x + y; })()")
  |> should.equal(8.0)
  num("(function(){ let { x = 100 } = { x: 3 }; return x; })()")
  |> should.equal(3.0)
}

pub fn rest_destructure_test() {
  // Array rest binds the remaining elements as a fresh array.
  num(
    "(function(){ let [a, ...rest] = [1, 2, 3, 4]; return a * 10 + rest.length; })()",
  )
  |> should.equal(13.0)
  num(
    "(function(){ let [a, ...rest] = [1, 2, 3, 4]; return rest[0] + rest[1]; })()",
  )
  |> should.equal(5.0)
  // Rest of a fully-consumed array is empty.
  num("(function(){ let [a, ...rest] = [7]; return rest.length; })()")
  |> should.equal(0.0)
}

pub fn object_rest_destructure_test() {
  // Object rest binds the remaining own properties as a fresh object.
  num(
    "(function(){ let { a, ...rest } = { a: 1, b: 2, c: 3 }; return a + rest.b + rest.c; })()",
  )
  |> should.equal(6.0)
  // The destructured (excluded) key is absent from rest.
  val(
    "(function(){ let { a, ...rest } = { a: 1, b: 2 }; return typeof rest.a; })()",
  )
  |> should.equal(dyn(<<"undefined">>))
  // Several named properties are excluded.
  num(
    "(function(){ let { a, b, ...rest } = { a: 1, b: 2, c: 3, d: 4 }; return rest.c + rest.d; })()",
  )
  |> should.equal(7.0)
}

pub fn array_from_map_test() {
  // Array.from(x, mapFn) applies mapFn(element, index).
  num(
    "Array.from([1, 2, 3], function(x) { return x * 2; }).reduce(function(a, b) { return a + b; }, 0)",
  )
  |> should.equal(12.0)
  // the index is passed as the second argument.
  num(
    "Array.from([10, 20], function(x, i) { return x + i; }).reduce(function(a, b) { return a + b; }, 0)",
  )
  |> should.equal(31.0)
  // from a string with a map function.
  val("Array.from(\"ab\", function(c) { return c.toUpperCase(); }).join(\"\")")
  |> should.equal(dyn(<<"AB">>))
}

pub fn generator_basic_test() {
  // A straight-line generator: .next() advances through the yields.
  let m =
    compile(
      "function* g() { yield 1; yield 2; yield 3; } "
      <> "function f() { let it = g(); return it.next().value * 100 + it.next().value * 10 + it.next().value; }",
    )
  to_float(call(m, "f", [])) |> should.equal(123.0)
}

pub fn generator_sent_test() {
  // A yield expression evaluates to the value passed to the next .next(v).
  let m =
    compile(
      "function* g() { let a = yield 1; let b = yield a + 10; return a + b; } "
      <> "function f() { let it = g(); it.next(); let r2 = it.next(5); let r3 = it.next(7); return r2.value * 100 + r3.value; }",
    )
  // resume a=5 → yield 15 (r2.value); resume b=7 → return 12 (r3.value)
  to_float(call(m, "f", [])) |> should.equal(1512.0)
}

pub fn generator_for_loop_test() {
  // A generator with a for loop yielding each i (yield inside a flattened loop).
  let m =
    compile(
      "function* range(n) { for (let i = 0; i < n; i++) yield i; } "
      <> "function f() { let it = range(3); return it.next().value * 100 + it.next().value * 10 + it.next().value; }",
    )
  to_float(call(m, "f", [])) |> should.equal(12.0)
}

pub fn generator_while_if_test() {
  // A while loop with a conditional yield: yields the even numbers below n.
  let m =
    compile(
      "function* evens(n) { let i = 0; while (i < n) { if (i % 2 === 0) yield i; i++; } } "
      <> "function f() { let it = evens(5); return it.next().value * 100 + it.next().value * 10 + it.next().value; }",
    )
  to_float(call(m, "f", [])) |> should.equal(24.0)
}

pub fn generator_drive_to_done_test() {
  // Drive a generator to completion with a manual .next() loop, summing values.
  let m =
    compile(
      "function* range(n) { for (let i = 0; i < n; i++) yield i; } "
      <> "function f() { let it = range(5); let s = 0; let r = it.next(); while (!r.done) { s += r.value; r = it.next(); } return s; }",
    )
  to_float(call(m, "f", [])) |> should.equal(10.0)
}

pub fn generator_loop_invariant_local_test() {
  // A generator whose loop body reads a local assigned BEFORE the loop and never
  // re-assigned inside it must still see that value on every iteration. Regression
  // against a state-machine bug where such a loop-INVARIANT local was dropped
  // across the flattened loop's back-edge (the loop only carried mutated locals),
  // so the generator hung. Locals now round-trip through `%ctx` on every state
  // transition, so an invariant local survives.
  let m =
    compile(
      "function* g(n) { let step = 2; for (let i = 0; i < n; i++) yield i * step; } "
      <> "function f() { let it = g(4); return it.next().value * 1000 + it.next().value * 100 + it.next().value * 10 + it.next().value; }",
    )
  // yields 0, 2, 4, 6 → 0*1000 + 2*100 + 4*10 + 6 = 246
  to_float(call(m, "f", [])) |> should.equal(246.0)
}

pub fn generator_for_of_test() {
  // for-of iterates a finite generator, draining it element by element.
  let m =
    compile(
      "function* range(n) { for (let i = 0; i < n; i++) yield i * i; } "
      <> "function f() { let s = 0; for (const x of range(4)) s += x; return s; }",
    )
  // 0 + 1 + 4 + 9 = 14
  to_float(call(m, "f", [])) |> should.equal(14.0)
}

pub fn generator_spread_test() {
  // Spreading a generator into an array collects its yielded values.
  let m =
    compile(
      "function* g() { yield 10; yield 20; yield 30; } "
      <> "function f() { let a = [...g()]; return a[0] + a[1] * 10 + a[2] * 100 + a.length; }",
    )
  // 10 + 200 + 3000 + 3 = 3213
  to_float(call(m, "f", [])) |> should.equal(3213.0)
}

pub fn generator_done_test() {
  // .done is false while yielding, true once the body completes.
  let m =
    compile(
      "function* g() { yield 1; } "
      <> "function f() { let it = g(); let a = it.next(); let b = it.next(); return (a.done ? 1 : 0) * 10 + (b.done ? 1 : 0); }",
    )
  to_float(call(m, "f", [])) |> should.equal(1.0)
}

pub fn new_spread_test() {
  let cls =
    "class Point { constructor(x, y) { this.x = x; this.y = y; } sum() { return this.x + this.y; } } "
  // new C(...args) spreads the array as constructor arguments.
  let m =
    compile(
      cls
      <> "function f() { let args = [3, 4]; let p = new Point(...args); return p.sum(); }",
    )
  to_float(call(m, "f", [])) |> should.equal(7.0)
  // mixed: new C(a, ...rest).
  let n =
    compile(
      cls
      <> "function f() { let rest = [10]; let p = new Point(1, ...rest); return p.sum(); }",
    )
  to_float(call(n, "f", [])) |> should.equal(11.0)
}

pub fn try_finally_normal_test() {
  // finally runs on normal completion; its effect is visible afterward.
  num(
    "(function(){ let o = { n: 0 }; try { o.n = 1; } finally { o.n = o.n + 10; } return o.n; })()",
  )
  |> should.equal(11.0)
}

pub fn try_catch_finally_test() {
  // finally runs after the catch handler.
  num(
    "(function(){ let o = { log: 0 }; try { throw 5; } catch (e) { o.log = e; } finally { o.log = o.log + 100; } return o.log; })()",
  )
  |> should.equal(105.0)
}

pub fn try_finally_reraise_test() {
  // With no catch, finally runs and the exception propagates to an outer catch.
  num(
    "(function(){ let o = { cleaned: 0, caught: 0 }; try { try { throw 7; } finally { o.cleaned = 1; } } catch (e) { o.caught = e; } return o.cleaned * 10 + o.caught; })()",
  )
  |> should.equal(17.0)
}

pub fn try_finally_control_flow_unsupported_test() {
  // A return inside a try/finally would bypass finally, so it is a clean error.
  let assert Error(_) =
    js.compile_and_load(
      "function f() { try { return 1; } finally { } }",
      "twocore@jstest@tfctl",
    )
  Nil
}

pub fn member_update_test() {
  // obj.p++ reads and writes the property.
  num("(function(){ let o = { n: 5 }; o.n++; o.n++; return o.n; })()")
  |> should.equal(7.0)
  // computed member update a[i]++.
  num("(function(){ let a = [1, 2, 3]; a[1]++; return a[1]; })()")
  |> should.equal(3.0)
  // prefix decrement.
  num("(function(){ let o = { n: 5 }; --o.n; return o.n; })()")
  |> should.equal(4.0)
  // an update expression yields a value (the new value, per the deviation).
  num("(function(){ let o = { n: 5 }; return ++o.n; })()")
  |> should.equal(6.0)
}

pub fn object_rest_computed_key_test() {
  // A computed key is excluded from the rest object (by its runtime value).
  val(
    "(function(){ let k = \"x\"; let { [k]: a, ...rest } = { x: 1, y: 2 }; return \"x\" in rest; })()",
  )
  |> should.equal(dyn(False))
  num(
    "(function(){ let k = \"x\"; let { [k]: a, ...rest } = { x: 1, y: 2 }; return a + rest.y; })()",
  )
  |> should.equal(3.0)
}

pub fn object_default_reads_source_once_test() {
  // A destructuring default reads the source property ONCE, so a side-effecting
  // getter on that key runs a single time.
  num(
    "(function(){ let obj = { _n: 0, get x() { this._n = this._n + 1; return 0; } }; let { x = 99 } = obj; return x + obj._n; })()",
  )
  |> should.equal(1.0)
}

pub fn duplicate_object_getter_test() {
  // When a key has two getters, the last one wins.
  num(
    "(function(){ let o = { get v() { return 1; }, get v() { return 2; } }; return o.v; })()",
  )
  |> should.equal(2.0)
}

pub fn object_getter_test() {
  // An object-literal getter computes on access with dynamic `this` = the object.
  let m =
    compile(
      "function f() { let o = { y: 5, get x() { return this.y * 2; } }; return o.x; }",
    )
  to_float(call(m, "f", [])) |> should.equal(10.0)
}

pub fn object_setter_test() {
  // A getter/setter PAIR on one key; the setter mutates through `this`.
  let m =
    compile(
      "function f() { let o = { _v: 0, get v() { return this._v; }, set v(x) { this._v = x + 1; } }; o.v = 4; return o.v; }",
    )
  to_float(call(m, "f", [])) |> should.equal(5.0)
}

pub fn object_getter_no_leak_test() {
  // Object.values and JSON invoke the getter (sentinel 777), never leak the marker.
  let m =
    compile(
      "function f() { let o = { get magic() { return 777; } }; return Object.values(o).includes(777); }",
    )
  call(m, "f", []) |> should.equal(dyn(True))
  let n =
    compile(
      "function f() { let o = { get magic() { return 777; } }; return JSON.stringify(o).includes(\"777\"); }",
    )
  call(n, "f", []) |> should.equal(dyn(True))
}

pub fn static_field_call_test() {
  // A static field holding a function is callable via C.field(...).
  let m =
    compile(
      "class C { static make = () => 7; } function f() { return C.make(); }",
    )
  call(m, "main", [])
  to_float(call(m, "f", [])) |> should.equal(7.0)
}

pub fn static_field_inheritance_test() {
  // A subclass reads a static field declared on a parent (via C's storage key).
  let m =
    compile(
      "class A { static registry = 7; } class B extends A {} "
      <> "function f() { return B.registry; }",
    )
  call(m, "main", [])
  to_float(call(m, "f", [])) |> should.equal(7.0)
  // writing through the child creates the child's OWN static; the parent (and
  // siblings) are unaffected. A.n stays 1, B.n becomes 9 → 1*100 + 9 = 109.
  let n =
    compile(
      "class A { static n = 1; } class B extends A {} "
      <> "function f() { B.n = 9; return A.n * 100 + B.n; }",
    )
  call(n, "main", [])
  to_float(call(n, "f", [])) |> should.equal(109.0)
}

pub fn method_overrides_accessor_test() {
  let base = "class A { get value() { return \"getter\"; } } "
  let derived =
    "class B extends A { constructor() { super(); } value() { return \"method\"; } } "
  // A child method overriding a parent getter of the same name: the method wins.
  let m = compile(base <> derived <> "function f() { return new B().value(); }")
  call(m, "f", []) |> should.equal(dyn(<<"method">>))
  // reading it (not calling) yields the method function, not the getter value.
  let n =
    compile(base <> derived <> "function f() { return typeof new B().value; }")
  call(n, "f", []) |> should.equal(dyn(<<"function">>))
}

pub fn field_shadows_accessor_test() {
  // An instance field shadows a same-named accessor (own data property beats a
  // prototype accessor), so the field value wins.
  let m =
    compile(
      "class C { x = 5; get x() { return 42; } } "
      <> "function f() { let c = new C(); return c.x; }",
    )
  to_float(call(m, "f", [])) |> should.equal(5.0)
  // a field in the parent shadows an accessor declared in the child too.
  let n =
    compile(
      "class A { x = 1; } "
      <> "class B extends A { constructor() { super(); } get x() { return 2; } } "
      <> "function f() { let b = new B(); return b.x; }",
    )
  to_float(call(n, "f", [])) |> should.equal(1.0)
}

pub fn getter_only_assign_test() {
  // Assigning to a getter-only property is a silent no-op (sloppy mode).
  let m =
    compile(
      "class C { get x() { return 42; } } "
      <> "function f() { let c = new C(); c.x = 99; return c.x; }",
    )
  to_float(call(m, "f", [])) |> should.equal(42.0)
}

pub fn logical_assign_no_rebind_test() {
  // A short-circuited nested assignment must NOT rebind its target.
  // x truthy → `y = 5` never runs → y stays 0.
  num("(function(){ let x = 1, y = 0; x ||= y = 5; return y; })()")
  |> should.equal(0.0)
  // x falsy → `y = 5` never runs (&&=) → y stays 9.
  num("(function(){ let x = 0, y = 9; x &&= y = 5; return y; })()")
  |> should.equal(9.0)
  // x non-nullish → `y = 5` never runs (??=) → y stays 7.
  num("(function(){ let x = 1, y = 7; x ??= y = 5; return y; })()")
  |> should.equal(7.0)
  // sanity: a plain chain still rebinds both targets.
  num("(function(){ let x = 0, y = 0; x = y = 3; return x + y; })()")
  |> should.equal(6.0)
}

pub fn string_raw_missing_sub_test() {
  // A direct String.raw with fewer substitutions than gaps: a missing
  // substitution is the empty string, not "undefined".
  val("String.raw({ raw: [\"a\", \"b\"] })") |> should.equal(dyn(<<"ab">>))
  val("String.raw({ raw: [\"a\", \"b\", \"c\"] }, \"X\")")
  |> should.equal(dyn(<<"aXbc">>))
}

pub fn string_from_code_point_range_test() {
  // §22.1.2.2 steps 2a–2c: a non-integral, negative, or > 0x10FFFF code point is
  // a RangeError — not a TypeError. The runtime signals this as `range_error`.
  let is_range_error = fn(src: String) -> Bool {
    let m = compile("function f() { return " <> src <> "; }")
    case catch_apply(m, atom.create("f"), []) {
      Error(msg) -> string.contains(msg, "range_error")
      Ok(_) -> False
    }
  }
  is_range_error("String.fromCodePoint(1.5)") |> should.equal(True)
  is_range_error("String.fromCodePoint(-1)") |> should.equal(True)
  is_range_error("String.fromCodePoint(0x110000)") |> should.equal(True)
  is_range_error("String.fromCodePoint('x')") |> should.equal(True)
  // A valid code point still builds the string (0x41 = 'A', 0x1F600 astral).
  val("String.fromCodePoint(65)") |> should.equal(dyn(<<"A">>))
  val("String.fromCodePoint(0, 66)")
  |> should.equal(dyn(<<0, "B">>))
}

pub fn string_raw_arraylike_test() {
  // §22.1.2.4: `raw` is treated as an array-LIKE, not a dense array — read
  // raw.length via ToLength and each segment via Get(raw, ToString(i)). A plain
  // object with a `length` and integer-string keys must work, segments beyond
  // `length` are ignored, and non-string segments are ToString'd.
  val(
    "String.raw({ raw: { length: 5, 0: 'e', 1: '', 2: null, 3: undefined, 4: 123, 5: 'over' } })",
  )
  |> should.equal(dyn(<<"enullundefined123">>))
  // ToLength(length) <= 0 (missing, -Infinity, NaN, 0) → the empty string.
  val("String.raw({ raw: {} })") |> should.equal(dyn(<<"">>))
  val("String.raw({ raw: { length: -Infinity } })")
  |> should.equal(dyn(<<"">>))
  val("String.raw({ raw: { length: NaN, 0: 'a' } })")
  |> should.equal(dyn(<<"">>))
  // Substitutions are inserted between array-like segments and ToString'd.
  val("String.raw({ raw: { length: 2, 0: 'a', 1: 'b' } }, 42)")
  |> should.equal(dyn(<<"a42b">>))
}

// ── runtime correctness (spec regressions) ──────────────────────────────────

pub fn math_round_half_test() {
  // floor(x + 0.5) is WRONG for the largest double below 0.5: it rounds to 1,
  // but ECMAScript rounds x < 0.5 (and >= 0) down to 0.
  num("Math.round(0.49999999999999994)") |> should.equal(0.0)
  // ties round toward +Infinity, not toward zero.
  num("Math.round(2.5)") |> should.equal(3.0)
  num("Math.round(-2.5)") |> should.equal(-2.0)
  num("Math.round(-0.5)") |> should.equal(0.0)
  num("Math.round(2.4)") |> should.equal(2.0)
}

pub fn math_cbrt_negative_test() {
  // Math.cbrt of a negative number must not raise; cbrt(-8) = -2.
  float_close(num("Math.cbrt(-8)"), -2.0) |> should.equal(True)
  float_close(num("Math.cbrt(27)"), 3.0) |> should.equal(True)
}

pub fn array_includes_nan_test() {
  // Array.prototype.includes uses SameValueZero, so it finds NaN…
  val("[1, Number('x'), 3].includes(Number('x'))") |> should.equal(dyn(True))
  // …while indexOf uses === and does not.
  num("[1, Number('x'), 3].indexOf(Number('x'))") |> should.equal(-1.0)
  val("[1, 2, 3].includes(2)") |> should.equal(dyn(True))
  val("[1, 2, 3].includes(5)") |> should.equal(dyn(False))
}

pub fn json_stringify_control_chars_test() {
  // Control characters must be \u00XX-escaped so the output is valid JSON.
  val("JSON.stringify(String.fromCharCode(0))")
  |> should.equal(dyn(<<"\"\\u0000\"">>))
  val("JSON.stringify(String.fromCharCode(8))")
  |> should.equal(dyn(<<"\"\\b\"">>))
  val("JSON.stringify(String.fromCharCode(12))")
  |> should.equal(dyn(<<"\"\\f\"">>))
  val("JSON.stringify(String.fromCharCode(31))")
  |> should.equal(dyn(<<"\"\\u001f\"">>))
}

pub fn json_parse_exponent_test() {
  // JSON numbers may use an exponent with no decimal point.
  num("JSON.parse('1e3')") |> should.equal(1000.0)
  num("JSON.parse('2.5e1')") |> should.equal(25.0)
  num("JSON.parse('2E-2')") |> should.equal(0.02)
}

pub fn json_parse_escapes_test() {
  // \b and \f are single control chars (length 3, not 4); a surrogate pair is
  // one astral code point (length 1 under code-point counting).
  num("JSON.parse('\"a\\\\bc\"').length") |> should.equal(3.0)
  num("JSON.parse('\"\\\\uD83D\\\\uDE00\"').length") |> should.equal(1.0)
}

pub fn json_stringify_replacer_array_test() {
  // An Array replacer is a PropertyList: object serialization emits ONLY those
  // keys, in the ARRAY's order — independent of the object (sec-json.stringify
  // SerializeJSONObject step 5). An empty array collapses any object to `{}`.
  val("JSON.stringify({a: 1, b: 2}, [])") |> should.equal(dyn(<<"{}">>))
  val("JSON.stringify({b: 1, a: 2, c: 3}, [\"c\", \"b\", \"a\"])")
  |> should.equal(dyn(<<"{\"c\":3,\"b\":1,\"a\":2}">>))
  // undefined entries are ignored; a listed key absent from the object is dropped.
  val("JSON.stringify({key: 1, other: 2}, [undefined, \"key\"])")
  |> should.equal(dyn(<<"{\"key\":1}">>))
  // Number entries are coerced to their string key form.
  val("JSON.stringify({\"1\": \"x\"}, [1])")
  |> should.equal(dyn(<<"{\"1\":\"x\"}">>))
}

pub fn json_stringify_replacer_function_test() {
  // A whole-value replacer returning undefined makes stringify yield undefined;
  // per-property it omits object members and nulls array elements
  // (sec-serializejsonproperty step 3).
  val("JSON.stringify(1, function() {})")
  |> should.equal(dyn(atom.create("undefined")))
  val("JSON.stringify([1], function(k, v) { return v === 1 ? undefined : v; })")
  |> should.equal(dyn(<<"[null]">>))
  val(
    "JSON.stringify({prop: 1}, function(k, v) { return v === 1 ? undefined : v; })",
  )
  |> should.equal(dyn(<<"{}">>))
  // The replacer runs on the RESULT of toJSON (step 2 then step 3).
  val(
    "JSON.stringify({toJSON: function() { return \"toJSON\"; }}, function(k, v) { return v + \"|replacer\"; })",
  )
  |> should.equal(dyn(<<"\"toJSON|replacer\"">>))
}

pub fn json_stringify_tojson_test() {
  // A callable own toJSON is invoked and its result serialized; a non-callable
  // toJSON stays an ordinary own property (sec-serializejsonproperty step 2).
  val("JSON.stringify({toJSON: function() { return \"hi\"; }})")
  |> should.equal(dyn(<<"\"hi\"">>))
  val("JSON.stringify({toJSON: null})")
  |> should.equal(dyn(<<"{\"toJSON\":null}">>))
  val("JSON.stringify({toJSON: false})")
  |> should.equal(dyn(<<"{\"toJSON\":false}">>))
}

pub fn json_stringify_space_test() {
  // A numeric space indents each nesting level by that many spaces; a string
  // space uses the string itself as the gap; 0/empty means no whitespace and
  // members use `"k": v` with a single space after the colon (sec-json.stringify).
  val("JSON.stringify({a: 1}, null, 2)")
  |> should.equal(dyn(<<"{\n  \"a\": 1\n}">>))
  val("JSON.stringify([1, 2], null, 2)")
  |> should.equal(dyn(<<"[\n  1,\n  2\n]">>))
  val("JSON.stringify({a: 1}, null, \"\\t\")")
  |> should.equal(dyn(<<"{\n\t\"a\": 1\n}">>))
  val("JSON.stringify({a: 1}, null, 0)")
  |> should.equal(dyn(<<"{\"a\":1}">>))
}

pub fn json_parse_tostring_coercion_test() {
  // JSON.parse coerces its argument with ToString first; an object's own
  // toString supplies the text to parse (sec-json.parse step 1).
  val("JSON.parse({toString: function() { return '\"ok\"'; }})")
  |> should.equal(dyn(<<"ok">>))
}

pub fn parse_float_forms_test() {
  num("parseFloat('1e3')") |> should.equal(1000.0)
  num("parseFloat('.5')") |> should.equal(0.5)
  num("parseFloat('1.5e2')") |> should.equal(150.0)
  num("parseFloat('3.14abc')") |> should.equal(3.14)
  num("parseFloat('-2.5')") |> should.equal(-2.5)
}

pub fn from_char_code_mask_test() {
  // Each code is truncated to 16 bits (ToUint16): 65601 mod 65536 = 65 = "A".
  val("String.fromCharCode(65601)") |> should.equal(dyn(<<"A">>))
  val("String.fromCharCode(65)") |> should.equal(dyn(<<"A">>))
}

pub fn pad_start_edge_test() {
  // An empty pad string yields no filler; the default fill is a space.
  val("'5'.padStart(3, '')") |> should.equal(dyn(<<"5">>))
  val("'5'.padStart(3)") |> should.equal(dyn(<<"  5">>))
  val("'5'.padStart(3, '0')") |> should.equal(dyn(<<"005">>))
}

pub fn replace_dollar_test() {
  // $& is the match, $$ is a literal $, and $`/$' are the surrounding text.
  val("'a-b'.replace('-', '$&')") |> should.equal(dyn(<<"a-b">>))
  val("'a-b'.replace('-', '$$')") |> should.equal(dyn(<<"a$b">>))
  val("'xax'.replaceAll('a', '[$&]')") |> should.equal(dyn(<<"x[a]x">>))
  val("'abc'.replace('b', '<$`>')") |> should.equal(dyn(<<"a<a>c">>))
  val("'abc'.replace('b', '<$\\'>')") |> should.equal(dyn(<<"a<c>c">>))
}

pub fn array_string_key_test() {
  // A non-canonical numeric string ("01") is a property, not an index, so it
  // must not affect `length` and must not overwrite element 1.
  num("(function(){ let a = [1, 2]; a['01'] = 9; return a.length; })()")
  |> should.equal(2.0)
  num("(function(){ let a = [1, 2]; a['01'] = 9; return a[1]; })()")
  |> should.equal(2.0)
}

// ── top-level main ───────────────────────────────────────────────────────────

pub fn main_test() {
  let m = compile("let x = 10; let y = 20;")
  // main returns undefined; just assert it runs without error.
  call(m, "main", []) |> should.equal(dyn(atom.create("undefined")))
}

pub fn parse_int_whitespace_test() {
  // parseInt strips the leading ES StrWhiteSpaceChar run — the full WhiteSpace +
  // LineTerminator set, not just ASCII blanks (sec-parseint-string-radix).
  num("parseInt('\\u00A01')") |> should.equal(1.0)
  num("parseInt('\\u00A0\\u00A0-1')") |> should.equal(-1.0)
  num("parseInt('\\u1680\\u2003\\u3000\\t 42')") |> should.equal(42.0)
  // Whitespace only ⇒ no digits ⇒ NaN.
  num("Number.isNaN(parseInt('\\u00A0')) ? 1 : 0") |> should.equal(1.0)
}

pub fn parse_int_radix_toint32_test() {
  // The radix argument is coerced with ToInt32 (mod 2^32, wrapping).
  // 4294967298 ≡ 2, so this is base 2.
  num("parseInt('11', 4294967298)") |> should.equal(3.0)
  // 4294967296 ≡ 0, which means "unspecified" ⇒ base 10.
  num("parseInt('11', 4294967296)") |> should.equal(11.0)
  // -4294967294 ≡ 2.
  num("parseInt('11', -4294967294)") |> should.equal(3.0)
  // -2147483650 ≡ 2147483646, outside 2..36 ⇒ NaN.
  num("Number.isNaN(parseInt('11', -2147483650)) ? 1 : 0")
  |> should.equal(1.0)
}

pub fn parse_float_whitespace_test() {
  // parseFloat strips the same leading StrWhiteSpaceChar run.
  num("parseFloat('\\u00A03.14')") |> should.equal(3.14)
  num("parseFloat('\\u1680\\u3000-2.5')") |> should.equal(-2.5)
  num("Number.isNaN(parseFloat('\\u00A0')) ? 1 : 0") |> should.equal(1.0)
}

pub fn numeric_globals_no_arg_test() {
  // A missing argument is `undefined`: ToNumber(undefined) is NaN, so isNaN() is
  // true and isFinite() is false; ToString(undefined) is "undefined" (no numeric
  // prefix) so parseInt()/parseFloat() are NaN.
  let a = compile("function f() { return isNaN(); }")
  call(a, "f", []) |> should.equal(dyn(True))
  let b = compile("function f() { return isFinite(); }")
  call(b, "f", []) |> should.equal(dyn(False))
  num("Number.isNaN(parseInt()) ? 1 : 0") |> should.equal(1.0)
  num("Number.isNaN(parseFloat()) ? 1 : 0") |> should.equal(1.0)
}

pub fn number_is_safe_integer_test() {
  // Number.isSafeInteger(x): x is an integer-valued number with |x| ≤ 2^53 − 1
  // (9007199254740991) — no coercion (sec-number.issafeinteger).
  let a =
    compile("function f() { return Number.isSafeInteger(9007199254740991); }")
  call(a, "f", []) |> should.equal(dyn(True))
  // 2^53 itself is one past the safe range.
  let b =
    compile("function f() { return Number.isSafeInteger(9007199254740992); }")
  call(b, "f", []) |> should.equal(dyn(False))
  let c = compile("function f() { return Number.isSafeInteger(0); }")
  call(c, "f", []) |> should.equal(dyn(True))
  let n =
    compile("function f() { return Number.isSafeInteger(-9007199254740991); }")
  call(n, "f", []) |> should.equal(dyn(True))
  // Non-integers are false.
  let d = compile("function f() { return Number.isSafeInteger(1.1); }")
  call(d, "f", []) |> should.equal(dyn(False))
  // No coercion: numeric strings, booleans, NaN and the infinities are all false.
  let s = compile("function f() { return Number.isSafeInteger(\"1\"); }")
  call(s, "f", []) |> should.equal(dyn(False))
  let i = compile("function f() { return Number.isSafeInteger(Infinity); }")
  call(i, "f", []) |> should.equal(dyn(False))
  let m = compile("function f() { return Number.isSafeInteger(NaN); }")
  call(m, "f", []) |> should.equal(dyn(False))
}

pub fn number_tostring_radix_test() {
  // Integer-valued numbers render in the requested base whether they are held as
  // an Erlang integer (a literal) or an integral float (e.g. a division result).
  val("(255).toString(16)") |> should.equal(dyn(<<"ff">>))
  val("(510 / 2).toString(16)") |> should.equal(dyn(<<"ff">>))
  val("(1024 / 64).toString(2)") |> should.equal(dyn(<<"10000">>))
  // Dyadic fractions terminate exactly (0.5₁₀ = 0.1₂, 3.5₁₀ = 11.1₂).
  val("(3.5).toString(2)") |> should.equal(dyn(<<"11.1">>))
  val("(0.5).toString(2)") |> should.equal(dyn(<<"0.1">>))
  val("(0.25).toString(2)") |> should.equal(dyn(<<"0.01">>))
  val("(-3.5).toString(2)") |> should.equal(dyn(<<"-11.1">>))
  // Radix 10, and NaN / ±Infinity, use the default ToString.
  val("(255).toString(10)") |> should.equal(dyn(<<"255">>))
  val("(0 / 0).toString(2)") |> should.equal(dyn(<<"NaN">>))
  val("(1 / 0).toString(2)") |> should.equal(dyn(<<"Infinity">>))
}

// ── URI encode / decode globals (ECMAScript §19.2.6, RFC 3629) ────────────────

/// Compile+run `return <expr>;` and return the raw `catch_apply` Result: `Ok(v)`
/// on a normal return, or `Error(msg)` when the body raises (the BEAM reason
/// formatted to a binary — a URIError shows up as `{js_error,uri_error,…}`).
fn run_result(expr: String) -> Result(Dynamic, String) {
  let m = compile("function f() { return " <> expr <> "; }")
  catch_apply(m, atom.create("f"), [])
}

/// True when running `expr` raises the JS URIError convention
/// (`{js_error, uri_error, _}`) — the §19.2.6 "URIError" outcome.
fn is_uri_error(expr: String) -> Bool {
  case run_result(expr) {
    Error(msg) -> string.contains(msg, "uri_error")
    Ok(_) -> False
  }
}

pub fn encode_uri_component_unreserved_test() {
  // §19.2.6.5: the uriUnescaped set (A-Za-z0-9 and `- _ . ! ~ * ' ( )`) is left
  // literal by encodeURIComponent.
  val("encodeURIComponent(\"abcXYZ0189\")")
  |> should.equal(dyn(<<"abcXYZ0189">>))
  val("encodeURIComponent(\"-_.!~*'()\")")
  |> should.equal(dyn(<<"-_.!~*'()">>))
}

pub fn encode_uri_component_reserved_test() {
  // encodeURIComponent escapes the whole uriReserved set plus `#` (its
  // unescaped set does NOT contain them). Hex digits are uppercase.
  val("encodeURIComponent(\";/?:@&=+$,\")")
  |> should.equal(dyn(<<"%3B%2F%3F%3A%40%26%3D%2B%24%2C">>))
  val("encodeURIComponent(\"#\")") |> should.equal(dyn(<<"%23">>))
  // A space is not unescaped → %20.
  val("encodeURIComponent(\"a b\")") |> should.equal(dyn(<<"a%20b">>))
}

pub fn encode_uri_component_url_test() {
  // A whole URL: every reserved delimiter is escaped (unlike encodeURI).
  val("encodeURIComponent(\"http://unipro.ru/0123456789\")")
  |> should.equal(dyn(<<"http%3A%2F%2Funipro.ru%2F0123456789">>))
  // The empty string round-trips to the empty string.
  val("encodeURIComponent(\"\")") |> should.equal(dyn(<<"">>))
}

pub fn encode_uri_component_utf8_test() {
  // Non-ASCII characters are UTF-8 encoded then each octet percent-escaped
  // (RFC 3629). `Ю` = U+042E = 0xD0 0xAE; `н` = U+043D = 0xD0 0xBD.
  val("encodeURIComponent(\"Юн\")") |> should.equal(dyn(<<"%D0%AE%D0%BD">>))
}

pub fn encode_uri_test() {
  // encodeURI ADDITIONALLY leaves the uriReserved set and `#` literal.
  val("encodeURI(\";/?:@&=+$,#\")") |> should.equal(dyn(<<";/?:@&=+$,#">>))
  // Non-reserved characters (space, `\"`) are still escaped.
  val("encodeURI(\"a b\")") |> should.equal(dyn(<<"a%20b">>))
  // A full URL keeps its structural delimiters.
  val("encodeURI(\"http://unipro.ru/0123456789\")")
  |> should.equal(dyn(<<"http://unipro.ru/0123456789">>))
}

pub fn decode_uri_component_basic_test() {
  // decodeURIComponent has an EMPTY reserved set, so EVERY escape is decoded —
  // including the reserved characters (§19.2.6.2).
  val("decodeURIComponent(\"%3B%2F%3F%3A%40%26%3D%2B%24%2C%23\")")
  |> should.equal(dyn(<<";/?:@&=+$,#">>))
  // ASCII escapes decode to their byte; non-escaped chars pass through.
  val("decodeURIComponent(\"%41%42%43\")") |> should.equal(dyn(<<"ABC">>))
  val("decodeURIComponent(\"http://a/b\")")
  |> should.equal(dyn(<<"http://a/b">>))
}

pub fn decode_uri_component_utf8_test() {
  // A multi-octet escape run rebuilds the original UTF-8 character (RFC 3629).
  // %D0%AE%D0%BD → `Юн`.
  val("decodeURIComponent(\"%D0%AE%D0%BD\")")
  |> should.equal(dyn(<<"Юн">>))
}

pub fn decode_uri_reserved_preserved_test() {
  // decodeURI's reserved set (`; / ? : @ & = + $ , #`): an escape that decodes
  // to one of these is LEFT as its original escape, verbatim and case-preserved
  // (§19.2.6.1). Non-reserved escapes (e.g. %20 → space) still decode.
  val("decodeURI(\"%3B%2F%3F%3A%40%26%3D%2B%24%2C%23\")")
  |> should.equal(dyn(<<"%3B%2F%3F%3A%40%26%3D%2B%24%2C%23">>))
  val("decodeURI(\"%3b%2f\")") |> should.equal(dyn(<<"%3b%2f">>))
  // A non-reserved escape between reserved ones: %20 decodes, %23 is preserved.
  val("decodeURI(\"a%20b%23c\")") |> should.equal(dyn(<<"a b%23c">>))
  // A multi-octet character is never reserved, so it always decodes.
  val("decodeURI(\"%D0%AE\")") |> should.equal(dyn(<<"Ю">>))
}

pub fn decode_uri_malformed_escape_uri_error_test() {
  // §19.2.6: a truncated or non-hex %-escape is a URIError.
  is_uri_error("decodeURIComponent(\"%\")") |> should.equal(True)
  is_uri_error("decodeURIComponent(\"%A\")") |> should.equal(True)
  is_uri_error("decodeURIComponent(\"%1\")") |> should.equal(True)
  is_uri_error("decodeURIComponent(\"%GG\")") |> should.equal(True)
  is_uri_error("decodeURI(\"%\")") |> should.equal(True)
}

pub fn decode_uri_invalid_utf8_uri_error_test() {
  // RFC 3629 rejects: continuation byte as a lead (0x80–0xBF), overlong forms,
  // UTF-16 surrogates, and code points above U+10FFFF — each a URIError.
  is_uri_error("decodeURIComponent(\"%80\")") |> should.equal(True)
  // %C0%AF — overlong 2-byte encoding of `/`.
  is_uri_error("decodeURIComponent(\"%C0%AF\")") |> should.equal(True)
  // %ED%BF%BF — a UTF-16 low surrogate (U+DFFF).
  is_uri_error("decodeURIComponent(\"%ED%BF%BF\")") |> should.equal(True)
  // %ED%7F%BF — a non-continuation second octet.
  is_uri_error("decodeURIComponent(\"%ED%7F%BF\")") |> should.equal(True)
  // %ED%BF — a truncated 3-byte sequence.
  is_uri_error("decodeURIComponent(\"%ED%BF\")") |> should.equal(True)
  // %F4%90%80%80 — a code point above U+10FFFF.
  is_uri_error("decodeURIComponent(\"%F4%90%80%80\")") |> should.equal(True)
}

pub fn decode_uri_valid_utf8_boundaries_test() {
  // The just-valid boundaries must DECODE (not error): U+0800 (%E0%A0%80, the
  // minimum non-overlong 3-byte) and U+10000 (%F0%90%80%80, the minimum 4-byte).
  is_uri_error("decodeURIComponent(\"%E0%A0%80\")") |> should.equal(False)
  is_uri_error("decodeURIComponent(\"%F0%90%80%80\")") |> should.equal(False)
}

pub fn uri_round_trip_test() {
  // encode∘decode is the identity for a component containing reserved chars.
  val("decodeURIComponent(encodeURIComponent(\"a b/c?d=e&f#g\"))")
  |> should.equal(dyn(<<"a b/c?d=e&f#g">>))
  // Non-string arguments are coerced with ToString first.
  val("encodeURIComponent(123)") |> should.equal(dyn(<<"123">>))
  val("encodeURI(true)") |> should.equal(dyn(<<"true">>))
}

// ── negative zero (IEEE -0.0; §6.1.6.1.1 unary minus, §7.2.11 SameValue) ──────

pub fn negative_zero_object_is_test() {
  // Unary `-` on a zero yields the distinct IEEE value -0. SameValue (Object.is)
  // distinguishes -0 from +0 (§7.2.11), unlike Strict Equality which collapses
  // them.
  num("Object.is(-0, 0) ? 1 : 0") |> should.equal(0.0)
  num("Object.is(-0, -0) ? 1 : 0") |> should.equal(1.0)
  num("Object.is(0, 0) ? 1 : 0") |> should.equal(1.0)
  // Negating -0 restores +0; negating +0 gives -0.
  num("Object.is(-(-0), 0) ? 1 : 0") |> should.equal(1.0)
  num("Object.is(-(0), -0) ? 1 : 0") |> should.equal(1.0)
}

pub fn negative_zero_equality_and_coercion_test() {
  // Strict/loose equality collapse the signs (§7.2.15); -0 is falsy; ToString(-0)
  // is "0", not "-0" (§6.1.6.1.20 Number::toString).
  num("(-0 === 0) ? 1 : 0") |> should.equal(1.0)
  num("(-0 == 0) ? 1 : 0") |> should.equal(1.0)
  num("(-0) ? 1 : 0") |> should.equal(0.0)
  val("String(-0)") |> should.equal(dyn(<<"0">>))
}

pub fn negative_zero_division_sign_test() {
  // The sign bit of -0 propagates through division (§6.1.6.1.5): 1 / -0 is
  // -Infinity, whereas 1 / +0 is +Infinity.
  num("1 / -0 === -Infinity ? 1 : 0") |> should.equal(1.0)
  num("1 / 0 === Infinity ? 1 : 0") |> should.equal(1.0)
}
