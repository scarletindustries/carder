//// State-pure `Block` let-case under the perf6 letrec-floating scope, run end
//// to end against a direct host: the anf.share shape (pure hit probe, `Mut`
//// kernel on miss) at arity 1 and 2, and the arity-0 shape whose leaves carry
//// no values at all. Hit and miss paths must both compile and yield the
//// values the plain (non-floating) lowering would.

import carder/backend/build_beam
import carder/backend/emit_core
import carder/ir
import carder/runtime/instance.{type Binding, DirectHost, HostOp, Mut, Read}
import carder/runtime/profiles
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/option.{None}

@external(erlang, "carder_threaded_test_ffi", "instantiate")
fn t_instantiate(module: Atom) -> Result(Dynamic, String)

@external(erlang, "carder_threaded_test_ffi", "invoke")
fn t_invoke(
  module: Atom,
  function: Atom,
  st: Dynamic,
  args: List(Int),
) -> Result(#(Int, Dynamic), String)

fn module(name: String, functions: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "carder@pbf@" <> name,
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
  )
}

fn fn1(name: String, body: ir.Expr) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("p0", ir.TTerm)],
    result: [ir.TTerm],
    locals: [],
    body: body,
  )
}

/// `rr` is the value-only probe (`miss` for 0, else the doubled key); `slow` is the
/// `Mut` kernel (`key + 100`, record threaded back).
fn binding() -> Binding {
  let ops =
    dict.from_list([
      #("rr", HostOp("carder_readmiss_test_ffi", "probe", Read)),
      #("slow", HostOp("carder_readmiss_test_ffi", "slow", Mut)),
    ])
  profiles.direct(DirectHost(capability: "cap", ops:))
}

fn run(name: String, body: ir.Expr, arg: Int) -> Int {
  let m = module(name, [fn1("f", body)])
  let assert Ok(cm) = emit_core.emit_module(m, binding())
  let assert Ok(mod) = build_beam.compile_and_load(cm)
  let assert Ok(st) = t_instantiate(mod)
  let assert Ok(#(v, _)) = t_invoke(mod, atom.create("f"), st, [arg])
  v
}

fn probe() -> ir.Expr {
  ir.CallHost("cap", "rr", [ir.Var("p0")])
}

/// `n` value-only reads ahead of `inner`, enough to push the cold cont past the
/// inline threshold so it materialises (and floats).
fn reads(n: Int, inner: ir.Expr) -> ir.Expr {
  case n {
    0 -> inner
    _ -> ir.Let(["c" <> int.to_string(n)], probe(), reads(n - 1, inner))
  }
}

/// The l_miss inner block: probe, `=:= miss` → break to l_miss, else break to l_join
/// with `hit`.
fn miss_block(result: List(ir.ValType), hit: List(ir.Value)) -> ir.Expr {
  ir.Block(
    "l_miss",
    result,
    ir.Let(
      ["v"],
      probe(),
      ir.Let(
        ["b"],
        ir.NumTerm(ir.NEq, ir.Var("v"), ir.ConstAtom("miss")),
        ir.If(
          ir.Var("b"),
          result,
          ir.Break("l_miss", list.map(result, fn(_) { ir.Var("v") })),
          ir.Break("l_join", hit),
        ),
      ),
    ),
  )
}

/// anf.share at arity `k`: `Let(rs, Block(l_join, Let(x, l_miss, cold)), sum rs)`.
fn share(k: Int) -> ir.Expr {
  let tys = list.repeat(ir.TTerm, k)
  let rs = list.index_map(tys, fn(_, i) { "r" <> int.to_string(i + 1) })
  let cold =
    reads(
      9,
      ir.Let(
        ["w"],
        ir.CallHost("cap", "slow", [ir.Var("p0")]),
        ir.Break("l_join", list.repeat(ir.Var("w"), k)),
      ),
    )
  let sum =
    list.fold(list.drop(rs, 1), ir.Values([ir.Var("r1")]), fn(acc, r) {
      ir.Let(["a"], acc, ir.NumTerm(ir.NAdd, ir.Var("a"), ir.Var(r)))
    })
  ir.Let(
    rs,
    ir.Block(
      "l_join",
      tys,
      ir.Let(["x"], miss_block([ir.TTerm], list.repeat(ir.Var("v"), k)), cold),
    ),
    sum,
  )
}

/// Arity-0 state-pure block: every leaf carries no values, the cold path is a read.
fn share0() -> ir.Expr {
  ir.Let(
    [],
    ir.Block(
      "l_join",
      [],
      ir.Let(
        [],
        miss_block([], []),
        ir.Let(["q"], probe(), ir.Break("l_join", [])),
      ),
    ),
    ir.Values([ir.Var("p0")]),
  )
}

pub fn share_arity1_hit_and_miss_test() {
  assert run("s1", share(1), 5) == 10
  assert run("s1", share(1), 0) == 100
}

pub fn share_arity2_hit_and_miss_test() {
  assert run("s2", share(2), 5) == 20
  assert run("s2", share(2), 0) == 200
}

pub fn pure_arity0_block_hit_and_miss_test() {
  assert run("s0", share0(), 5) == 5
  assert run("s0", share0(), 0) == 0
}
