//// Milestone 0 (specs/HANDOFF-arc-frontend.md §7) — de-risk the arc→carder perf premise.
////
//// Hand-constructs the `ir.Module` a JS→carder emitter WOULD produce for two hot kernels
//// (a numeric summation loop, and the closure headliner `makeAdder`), runs each through the
//// unchanged pipeline (`ir_lower → optimize → emit_core → build_beam → BEAM`), and benchmarks
//// against a native-Gleam baseline. Correctness-gated first, then wall-clock.
////
//// The point being proved: `Loop` + `NumTerm` compile to native BEAM tail-recursion + native
//// `erlang:'+'`, and `MakeClosure`/`CallClosure` compile to a native BEAM `fun`/`apply` — no
//// arc VM dispatch, no heap environments (Porffor's wall does not exist). See the report at
//// the end of the run for the numbers.

import carder/ir
import carder/pipeline
import carder/runtime/profiles
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/io
import gleam/option
import gleam/string

// ───────────────────────────── configuration ─────────────────────────────

/// Loop iterations per invocation. 1_000_000 matches the JS the emitter would target.
const n: Int = 1_000_000

/// How many invocations `exec_beam` times (excludes compile/load/instantiate).
const repeat: Int = 100

// ───────────────────────────── shared IR helpers ─────────────────────────────

/// A `TTerm`-typed integer constant, via the identity `BoxInt` bridge (K5 — a static-type retag;
/// `ConstI64(v)` and its boxed term are the SAME Erlang value).
fn term_int(name: String, v: Int, then: ir.Expr) -> ir.Expr {
  ir.Let([name], ir.Convert(ir.BoxInt(ir.W64), ir.ConstI64(v)), then)
}

fn empty_module(
  name: String,
  fns: List(ir.Function),
  export: String,
) -> ir.Module {
  ir.Module(
    name: name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: fns,
    exports: [ir.ExportFn(export, export)],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

// ───────────────────────────── kernel 1: sum(n) ─────────────────────────────
//
// JS:  function sum(n){ let s=0; for(let i=0;i<n;i++) s+=i; return s }
// IR:  a `Loop` carrying `i`/`s` as `TTerm` number terms; `NumTerm(NLt)` guards,
//      `NumTerm(NAdd)` accumulates. This is exactly what emit_carder would emit for the
//      guarded fast path (§3 unit 06 — `TermTest(IsNumber)` elided: both operands are known
//      integers here).

fn sum_body() -> ir.Expr {
  term_int(
    "zero",
    0,
    term_int(
      "one",
      1,
      ir.Loop(
        label: "L",
        params: [
          ir.LoopParam("i", ir.TTerm, ir.Var("zero")),
          ir.LoopParam("s", ir.TTerm, ir.Var("zero")),
        ],
        result: [ir.TTerm],
        body: ir.Let(
          ["c"],
          ir.NumTerm(ir.NLt, ir.Var("i"), ir.Var("n")),
          ir.If(
            cond: ir.Var("c"),
            result: [ir.TTerm],
            then_branch: ir.Let(
              ["s1"],
              ir.NumTerm(ir.NAdd, ir.Var("s"), ir.Var("i")),
              ir.Let(
                ["i1"],
                ir.NumTerm(ir.NAdd, ir.Var("i"), ir.Var("one")),
                ir.Continue("L", [ir.Var("i1"), ir.Var("s1")]),
              ),
            ),
            else_branch: ir.Break("L", [ir.Var("s")]),
          ),
        ),
      ),
    ),
  )
}

pub fn sum_module() -> ir.Module {
  empty_module(
    "carder@m0@sum",
    [
      ir.Function("sum", [ir.Local("n", ir.TTerm)], [ir.TTerm], [], sum_body()),
    ],
    "sum",
  )
}

// ───────────────────────────── kernel 2: makeAdder (THE CLOSURE CASE) ─────────────────────────────
//
// JS:  function makeAdder(x){ return y => x+y }
//      let add5 = makeAdder(5); let s=0; for(let i=0;i<n;i++) s += add5(i);
//
// IR:  `adder_impl(x, y)` is a same-module function (captures FIRST, K3). `make_adder(x)`
//      returns `MakeClosure("adder_impl", [x], arity=1)` — a native BEAM `fun(y) ->
//      apply 'adder_impl'/2(x, y)`. The driver calls `make_adder` ONCE, then `CallClosure`s
//      the returned fun in the hot loop. This proves the closure survives being returned and
//      called through a `TTerm` (the fun IS a term).

fn adder_impl() -> ir.Function {
  ir.Function(
    "adder_impl",
    [ir.Local("x", ir.TTerm), ir.Local("y", ir.TTerm)],
    [ir.TTerm],
    [],
    ir.Let(
      ["r"],
      ir.NumTerm(ir.NAdd, ir.Var("x"), ir.Var("y")),
      ir.Return([ir.Var("r")]),
    ),
  )
}

fn make_adder() -> ir.Function {
  ir.Function(
    "make_adder",
    [ir.Local("x", ir.TTerm)],
    [ir.TTerm],
    [],
    ir.Let(
      ["f"],
      ir.MakeClosure("adder_impl", [ir.Var("x")], 1),
      ir.Return([ir.Var("f")]),
    ),
  )
}

fn closure_body() -> ir.Expr {
  term_int(
    "five",
    5,
    ir.Let(
      ["add5"],
      ir.CallDirect("make_adder", [ir.Var("five")]),
      term_int(
        "zero",
        0,
        term_int(
          "one",
          1,
          ir.Loop(
            label: "L",
            params: [
              ir.LoopParam("i", ir.TTerm, ir.Var("zero")),
              ir.LoopParam("s", ir.TTerm, ir.Var("zero")),
            ],
            result: [ir.TTerm],
            body: ir.Let(
              ["c"],
              ir.NumTerm(ir.NLt, ir.Var("i"), ir.Var("n")),
              ir.If(
                cond: ir.Var("c"),
                result: [ir.TTerm],
                then_branch: ir.Let(
                  ["r"],
                  ir.CallClosure(ir.Var("add5"), [ir.Var("i")]),
                  ir.Let(
                    ["s1"],
                    ir.NumTerm(ir.NAdd, ir.Var("s"), ir.Var("r")),
                    ir.Let(
                      ["i1"],
                      ir.NumTerm(ir.NAdd, ir.Var("i"), ir.Var("one")),
                      ir.Continue("L", [ir.Var("i1"), ir.Var("s1")]),
                    ),
                  ),
                ),
                else_branch: ir.Break("L", [ir.Var("s")]),
              ),
            ),
          ),
        ),
      ),
    ),
  )
}

pub fn closure_module() -> ir.Module {
  empty_module(
    "carder@m0@closure",
    [
      adder_impl(),
      make_adder(),
      ir.Function(
        "run",
        [ir.Local("n", ir.TTerm)],
        [ir.TTerm],
        [],
        closure_body(),
      ),
    ],
    "run",
  )
}

// ───────────────────────────── native baselines ─────────────────────────────
// These are what a hand-written Gleam program compiles to on the BEAM — the ceiling.

fn native_sum(i: Int, s: Int, lim: Int) -> Int {
  case i < lim {
    True -> native_sum(i + 1, s + i, lim)
    False -> s
  }
}

fn native_closure(i: Int, s: Int, lim: Int, f: fn(Int) -> Int) -> Int {
  case i < lim {
    True -> native_closure(i + 1, s + f(i), lim, f)
    False -> s
  }
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Atom) -> Int

fn time_us(f: fn() -> a) -> #(Int, a) {
  let unit = atom.create("microsecond")
  let t0 = monotonic_time(unit)
  let r = f()
  let t1 = monotonic_time(unit)
  #(t1 - t0, r)
}

fn repeat_call(times: Int, f: fn() -> a, last: a) -> a {
  case times {
    0 -> last
    _ -> repeat_call(times - 1, f, f())
  }
}

// ───────────────────────────── the benchmark ─────────────────────────────

fn compile(m: ir.Module) -> BitArray {
  let assert Ok(beam) = pipeline.compile_ir(m, profiles.unsafe())
  beam
}

pub fn milestone0_sum_correctness_test() {
  let beam = compile(sum_module())
  let assert Ok(#(_, r)) = pipeline.exec_beam(beam, "sum", [n], 1)
  assert r == pipeline.Returned([499_999_500_000])
}

pub fn milestone0_closure_correctness_test() {
  let beam = compile(closure_module())
  // Σ (i+5) for i=0..n-1 = Σ i + 5n = 499_999_500_000 + 5_000_000
  let assert Ok(#(_, r)) = pipeline.exec_beam(beam, "run", [n], 1)
  assert r == pipeline.Returned([500_004_500_000])
}

pub fn milestone0_closure_lowering_test() {
  // Prove the shape: MakeClosure → a Core `fun (Y) -> apply 'adder_impl'/2(X, Y)`,
  // CallClosure → `apply <Var> (Args…)`.
  let assert Ok(core) = pipeline.ir_to_core(closure_module(), profiles.unsafe())
  assert string.contains(core, "'adder_impl'/2")
  assert string.contains(core, "fun (")
  assert string.contains(core, "'erlang':'+'")
}

pub fn milestone0_bench_test() {
  let sum_beam = compile(sum_module())
  let clo_beam = compile(closure_module())

  // Compiled carder IR → BEAM (times `repeat` invocations, `n` iterations each).
  let assert Ok(#(sum_us, sum_r)) =
    pipeline.exec_beam(sum_beam, "sum", [n], repeat)
  let assert Ok(#(clo_us, clo_r)) =
    pipeline.exec_beam(clo_beam, "run", [n], repeat)
  assert sum_r == pipeline.Returned([499_999_500_000])
  assert clo_r == pipeline.Returned([500_004_500_000])

  // Native Gleam/Erlang baseline (same workload, same repeat).
  let #(nat_sum_us, nat_sum_r) =
    time_us(fn() { repeat_call(repeat, fn() { native_sum(0, 0, n) }, 0) })
  let add5 = fn(y) { 5 + y }
  let #(nat_clo_us, nat_clo_r) =
    time_us(fn() {
      repeat_call(repeat, fn() { native_closure(0, 0, n, add5) }, 0)
    })
  assert nat_sum_r == 499_999_500_000
  assert nat_clo_r == 500_004_500_000

  let per = fn(us) { int.to_string(us / repeat) }
  io.println("")
  io.println(
    "[m0] sum(n=" <> int.to_string(n) <> ") x" <> int.to_string(repeat),
  )
  io.println(
    "[m0]   carder-compiled : "
    <> per(sum_us)
    <> " µs/call  ("
    <> ratio(sum_us, nat_sum_us)
    <> "x native)",
  )
  io.println("[m0]   native gleam   : " <> per(nat_sum_us) <> " µs/call")
  io.println("[m0] makeAdder closure loop x" <> int.to_string(repeat))
  io.println(
    "[m0]   carder-compiled : "
    <> per(clo_us)
    <> " µs/call  ("
    <> ratio(clo_us, nat_clo_us)
    <> "x native)",
  )
  io.println("[m0]   native gleam   : " <> per(nat_clo_us) <> " µs/call")
  io.println(
    "[m0]   MakeClosure/CallClosure: OK — closure captured "
    <> "x=5, returned as TTerm, called "
    <> int.to_string(n)
    <> "x in hot loop",
  )

  // The compiled loop must be within an order of magnitude of native (both are BEAM
  // tail-recursion + native `erlang:'+'`; the delta is emit_core's `case` around each op).
  assert sum_us < nat_sum_us * 10
  assert clo_us < nat_clo_us * 10
}

fn ratio(us: Int, base_us: Int) -> String {
  case base_us <= 0 {
    True -> "?"
    False -> {
      let tenths = us * 10 / base_us
      int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10)
    }
  }
}
