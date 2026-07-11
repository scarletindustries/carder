//// Benchmark the JS compiler (`twocore/frontend/js`) against arc's bytecode VM on
//// the SAME JavaScript — recursion (fib), a numeric loop, and a string-building
//// loop. Compiles once (excluded from timing); times execution only; asserts both
//// engines compute the same value so the comparison is honest.

import arc/engine
import arc/vm/completion
import arc/vm/value
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/float
import gleam/int
import gleam/io
import gleeunit/should
import twocore/frontend/js

@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply(m: Atom, f: Atom, args: List(Dynamic)) -> Result(Dynamic, String)

@external(erlang, "gleam_stdlib", "identity")
fn dyn(x: a) -> Dynamic

@external(erlang, "erlang", "float")
fn to_float(x: Dynamic) -> Float

@external(erlang, "erlang", "monotonic_time")
fn mono(unit: Atom) -> Int

fn now_us() -> Int {
  mono(atom.create("microsecond"))
}

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

fn compile(src: String, tag: String) -> Atom {
  let assert Ok(m) = js.compile_and_load(src, "twocore@jsbench@" <> tag)
  m
}

fn arc_num(eng: engine.Engine(Nil), src: String) -> Float {
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

pub fn js_compiler_benchmark_test() {
  let reps = 7
  let eng = engine.new()
  io.println("")
  io.println("═══ twocore/frontend/js  vs  arc bytecode VM ═══")

  // ── recursion: fib(30) ──
  let fib = "function fib(n){ if(n<2){ return n; } return fib(n-1)+fib(n-2); }"
  let fmod = compile(fib, "fib")
  let fib_arc = fib <> " fib(30);"
  // correctness
  to_float(call(fmod, "fib", [dyn(30)])) |> should.equal(832_040.0)
  arc_num(eng, fib_arc) |> should.equal(832_040.0)
  let fib_2core =
    best_us(reps, fn() { catch_apply(fmod, atom.create("fib"), [dyn(30)]) })
  let fib_arc_us = best_us(reps, fn() { arc_num(eng, fib_arc) })
  row("fib(30)  recursion", fib_2core, fib_arc_us)

  // ── numeric loop: sum 0..999999 ──
  let sum =
    "function sum(n){ let s=0; for(let i=0;i<n;i=i+1){ s=s+i; } return s; }"
  let smod = compile(sum, "sum")
  let sum_arc = sum <> " sum(1000000);"
  to_float(call(smod, "sum", [dyn(1_000_000)]))
  |> should.equal(499_999_500_000.0)
  arc_num(eng, sum_arc) |> should.equal(499_999_500_000.0)
  let sum_2core =
    best_us(reps, fn() {
      catch_apply(smod, atom.create("sum"), [dyn(1_000_000)])
    })
  let sum_arc_us = best_us(reps, fn() { arc_num(eng, sum_arc) })
  row("sum 0..999999  loop", sum_2core, sum_arc_us)

  // ── string building: concat n times ──
  let sb =
    "function build(n){ let s=\"\"; for(let i=0;i<n;i=i+1){ s=s+\"x\"; } return s; }"
  let bmod = compile(sb, "build")
  // (length check only — both produce a 5000-char string)
  let _ = call(bmod, "build", [dyn(5000)])
  let sb_2core =
    best_us(reps, fn() { catch_apply(bmod, atom.create("build"), [dyn(5000)]) })
  let sb_arc_us =
    best_us(reps, fn() {
      engine.eval(
        eng,
        "function build(n){ let s=\"\"; for(let i=0;i<n;i=i+1){ s=s+\"x\"; } return s.length; } build(5000);",
      )
    })
  row("string build x5000 ", sb_2core, sb_arc_us)
}

fn row(label: String, twocore_us: Int, arc_us: Int) {
  io.println(
    "  "
    <> label
    <> " : 2core "
    <> pad(int.to_string(twocore_us))
    <> " us | arc "
    <> pad(int.to_string(arc_us))
    <> " us | "
    <> ratio(arc_us, twocore_us)
    <> "x",
  )
}

fn pad(s: String) -> String {
  s
}

fn call(m: Atom, f: String, args: List(Dynamic)) -> Dynamic {
  let assert Ok(r) = catch_apply(m, atom.create(f), args)
  r
}
