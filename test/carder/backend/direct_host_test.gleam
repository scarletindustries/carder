//// `Binding.direct_host`: a caller-supplied `DirectHost(capability, ops)` routes every
//// `CallHost(capability, op, args)` to the `HostOp` the table names, under that op's `OpKind`
//// state-threading convention. Structural checks on the emitted Core (the targets are arbitrary
//// atoms that need not exist), plus the fail-closed and `ir_lower` admit edges, and a
//// differential run of the `ReadMiss` kind against the plain `Read` lowering.

import carder/backend/build_beam
import carder/backend/core_printer
import carder/backend/emit_core
import carder/ir
import carder/middle/ir_lower
import carder/runtime/instance.{
  type Binding, Binding, DirectHost, HostOp, MeterOff, Mut, MutMiss, MutUnit,
  Pure, Read, ReadMiss, Threaded,
}
import carder/runtime/profiles
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// Test-only FFI (see `test/carder_threaded_test_ffi.erl`): the record-returning
// `instantiate/0` and a threaded export invoke, traps captured as `Error`.
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
    name: "carder@dh@" <> name,
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

/// A `Threaded` binding whose direct host is capability `"cap"` with one op per `OpKind`,
/// each on its own made-up module so the emitted target is unambiguous.
fn binding() -> Binding {
  let ops =
    dict.from_list([
      #("p", HostOp("dh_pure_mod", "pf", Pure)),
      #("r", HostOp("dh_read_mod", "rf", Read)),
      #("rm", HostOp("dh_rmiss_mod", "rmf", ReadMiss)),
      #("m", HostOp("dh_mut_mod", "mf", Mut)),
      #("mm", HostOp("dh_miss_mod", "mmf", MutMiss)),
      #("u", HostOp("dh_unit_mod", "uf", MutUnit)),
    ])
  Binding(
    ..profiles.portable(),
    direct_host: Some(DirectHost(capability: "cap", ops:)),
  )
}

fn core_for(op: String) -> String {
  let body = case op {
    // MutUnit yields no value: discard it and return the parameter.
    "u" -> ir.Let(["_r"], ir.CallHost("cap", op, []), ir.Values([ir.Var("p0")]))
    _ -> ir.CallHost("cap", op, [ir.Var("p0")])
  }
  let m = module("m_" <> op, [fn1("f", body)])
  let assert Ok(cm) = emit_core.emit_module(m, binding())
  core_printer.print_module(cm)
}

/// Each kind emits a direct `call 'M':'F'` to exactly the table's target. `Pure` passes only
/// the args; every other kind prepends the threaded state, so its call has one more argument.
pub fn each_kind_calls_its_table_target_test() {
  assert string.contains(core_for("p"), "'dh_pure_mod':'pf'")
  assert string.contains(core_for("r"), "'dh_read_mod':'rf'")
  assert string.contains(core_for("rm"), "'dh_rmiss_mod':'rmf'")
  assert string.contains(core_for("m"), "'dh_mut_mod':'mf'")
  assert string.contains(core_for("mm"), "'dh_miss_mod':'mmf'")
  assert string.contains(core_for("u"), "'dh_unit_mod':'uf'")
  // No legacy `rt_js` routing and no generic host call for a direct-host capability.
  assert !string.contains(core_for("p"), "rt_js")
  assert !string.contains(core_for("m"), "'call_host'")
}

/// An op absent from the table fails closed with `UnknownDirectOp` (no call is emitted).
pub fn unknown_op_fails_closed_test() {
  let m = module("unk", [fn1("f", ir.CallHost("cap", "nope", []))])
  let assert Error(e) = emit_core.emit_module(m, binding())
  assert e == emit_core.UnknownDirectOp("cap", "nope")
}

/// A capability other than the direct host's is untouched by it: `"js"` still takes the
/// legacy `js_runtime_module` path, and an undeclared capability is still `ForbiddenHost`.
pub fn other_capabilities_unchanged_test() {
  let js = module("js", [fn1("f", ir.CallHost("js", "truthy", [ir.Var("p0")]))])
  let assert Ok(cm) = emit_core.emit_module(js, binding())
  assert string.contains(
    core_printer.print_module(cm),
    "'carder@runtime@rt_js':'truthy'",
  )
  let evil = module("evil", [fn1("f", ir.CallHost("evil", "op", []))])
  let assert Error(e) = ir_lower.lower(evil, binding())
  assert e == ir_lower.ForbiddenHost("evil", "op")
}

/// `ir_lower` admits the direct host's capability (op validity is `emit_core`'s job), and only
/// when a direct host is bound.
pub fn ir_lower_admits_direct_capability_test() {
  let m = module("adm", [fn1("f", ir.CallHost("cap", "whatever", []))])
  let assert Ok(_) = ir_lower.lower(m, binding())
  let assert Error(e) = ir_lower.lower(m, profiles.portable())
  assert e == ir_lower.ForbiddenHost("cap", "whatever")
}

/// `profiles.direct(host)` carries the caller's `DirectHost` verbatim on a `Threaded`,
/// `MeterOff` binding; a direct host on `"js"` takes precedence over the legacy
/// `js_runtime_module` path for that capability.
pub fn direct_profile_routes_through_direct_host_test() {
  let host =
    DirectHost(
      capability: "js",
      ops: dict.from_list([#("to_number", HostOp("dh_js_mod", "to_num", Mut))]),
    )
  let b = profiles.direct(host)
  assert b.direct_host == Some(host)
  assert b.state_strategy == Threaded
  assert b.meter == MeterOff
  let m =
    module("jsd", [fn1("f", ir.CallHost("js", "to_number", [ir.Var("p0")]))])
  let assert Ok(cm) = emit_core.emit_module(m, b)
  let core = core_printer.print_module(cm)
  assert string.contains(core, "'dh_js_mod':'to_num'")
  assert !string.contains(core, "'carder@runtime@rt_js':")
}

// ───────────────────────────── ReadMiss differential ─────────────────────────────

/// The IR shape arc uses for "inline hit probe, kernel on miss": bind the probe, test it
/// `=:= miss`, fall to the `Mut` kernel on the sentinel, else yield the probe's value.
fn probe_then_slow(probe: String) -> ir.Expr {
  ir.Let(
    ["v"],
    ir.CallHost("cap", probe, [ir.Var("p0")]),
    ir.Let(
      ["b"],
      ir.NumTerm(ir.NEq, ir.Var("v"), ir.ConstAtom("miss")),
      ir.If(
        ir.Var("b"),
        [ir.TTerm],
        ir.CallHost("cap", "slow", [ir.Var("p0")]),
        ir.Values([ir.Var("v")]),
      ),
    ),
  )
}

/// A direct host on the real `carder_readmiss_test_ffi`: the same probe under `ReadMiss`
/// (`rm`) and under plain `Read` (`rr`), plus the `Mut` kernel it falls to.
fn readmiss_binding() -> Binding {
  let ops =
    dict.from_list([
      #("rm", HostOp("carder_readmiss_test_ffi", "probe", ReadMiss)),
      #("rr", HostOp("carder_readmiss_test_ffi", "probe", Read)),
      #("slow", HostOp("carder_readmiss_test_ffi", "slow", Mut)),
    ])
  profiles.direct(DirectHost(capability: "cap", ops:))
}

/// Emit, compile, load `probe_then_slow(probe)` and run it on `arg`; return the value and
/// the printed Core.
fn run_probe(probe: String, arg: Int) -> #(Int, String) {
  let m = module("rmdiff_" <> probe, [fn1("f", probe_then_slow(probe))])
  let assert Ok(cm) = emit_core.emit_module(m, readmiss_binding())
  let assert Ok(mod) = build_beam.compile_and_load(cm)
  let assert Ok(st) = t_instantiate(mod)
  let assert Ok(#(v, _)) = t_invoke(mod, atom.create("f"), st, [arg])
  #(v, core_printer.print_module(cm))
}

/// `ReadMiss` runs identically to the `Read` + `NEq` + `If` lowering on both the hit path
/// (probe value, kernel not called) and the miss path (kernel value), while its Core is the
/// single `case V of 'miss' -> …` — no `=:=` compare and no i32 truth binder.
pub fn readmiss_runs_like_read_neq_if_test() {
  let #(hit_rm, core_rm) = run_probe("rm", 5)
  let #(hit_rr, core_rr) = run_probe("rr", 5)
  assert hit_rm == 10
  assert hit_rm == hit_rr
  let #(miss_rm, _) = run_probe("rm", 0)
  let #(miss_rr, _) = run_probe("rr", 0)
  assert miss_rm == 100
  assert miss_rm == miss_rr
  assert string.contains(core_rm, "'miss'")
  assert !string.contains(core_rm, "'=:='")
  assert string.contains(core_rr, "'=:='")
}
