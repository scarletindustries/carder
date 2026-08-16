//// `Binding.direct_host`: a caller-supplied `DirectHost(capability, ops)` routes every
//// `CallHost(capability, op, args)` to the `HostOp` the table names, under that op's `OpKind`
//// state-threading convention. Structural checks on the emitted Core (the targets are arbitrary
//// atoms that need not exist), plus the fail-closed and `ir_lower` admit edges.

import carder/backend/core_printer
import carder/backend/emit_core
import carder/ir
import carder/middle/ir_lower
import carder/runtime/instance.{
  type Binding, Binding, DirectHost, HostOp, MeterOff, Mut, MutMiss, MutUnit,
  Pure, Read, Threaded,
}
import carder/runtime/profiles
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string

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
