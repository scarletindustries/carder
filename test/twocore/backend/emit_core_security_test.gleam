//// Unit 08 — codegen security-invariant test (high-level §5 / D3a).
////
//// STRUCTURAL, not by string inspection: it walks the emitted `core_erlang` AST and
//// asserts the no-ambient-authority invariant property-style. Two things must hold for
//// EVERY generated module:
////
//// 1. Every inter-module `call` (`CCall`) targets a FIXED `twocore@runtime@*` module
////    drawn from the `Binding` — there is no data-driven `call Mod:Fun(...)` of a
////    program/attacker-chosen module, and the function position is always a literal atom.
//// 2. `CallHost`/`CallIndirect`/(memory/table ops) never lower to a bare `apply` of a
////    non-runtime module atom: `CallHost` becomes a runtime `call` (deny-all host or the
////    resolved stdlib), and the out-of-scope nodes return a typed `Error` rather than
////    emitting anything. (`CApply` is structurally a same-module static call — its target
////    is an `FName`, never a computed/dynamic module — so the IR cannot synthesise an
////    ambient-authority `apply(Mod, F, Args)` at all.)
////
//// The corpus here deliberately mixes numerics, a trap, metering, a host import, a stdlib
//// call, a direct self-call, and a loop, so every kind of emitted `call` is covered.

import gleam/list
import gleam/option
import gleam/set.{type Set}
import twocore/backend/core_erlang.{
  type CExpr, type CModule, CApply, CAtom, CCall, CCase, CClause, CCons, CFun,
  CLet, CLetrec, CPrimop, CTry, CTuple, CValues, FunDef,
}
import twocore/backend/emit_core
import twocore/ir
import twocore/runtime/instance
import twocore/runtime/profiles

/// The set of fixed runtime module names the `Binding` permits a `call` to target. Extended
/// in Phase 2 with the memory/table/state modules, and in Phase 5 with the two build-controlled
/// atoms `emit_core` reaches WITHOUT a `Binding` field (R1/R4): `rt_ref` (`RefIsNull`'s
/// `is_null`) and `link` (the `instantiate/1` `provided_*` externval extractors). Both are fixed
/// literal atoms, admitted here exactly like a `binding.*_module` (D3a — still no ambient
/// authority: a larger allow-set is more permissive, but every atom in it is build-controlled).
fn runtime_modules(b: instance.Binding) -> Set(String) {
  set.from_list([
    b.num_module,
    b.trap_module,
    b.host_module,
    b.meter_module,
    b.stdlib_module,
    b.mem_module,
    b.table_module,
    b.state_module,
    // Phase-8 (P8-05): the JS runtime boundary chokepoint (K6). A `CallHost("js", op, args)`
    // emits `call '<js_runtime_module>':'<fn>'(args)` where `<fn>` is a build-fixed literal atom
    // from `emit_core.resolve_js` (never derived from `op`/`args` data, D3a) — admitted here
    // exactly like any other `binding.*_module`.
    b.js_runtime_module,
    "twocore@runtime@rt_ref",
    "twocore@runtime@link",
    // Phase-6 (P6-06): the SIMD lane-op chokepoint — a fixed build-controlled atom `emit_core`
    // reaches WITHOUT a `Binding` field (like `rt_ref`/`link`), admitted here exactly like a
    // `binding.*_module` (D3a). The cross-module closure dispatch adds NO new module: it routes
    // through the already-admitted `link.call_import` (S5 — a homogeneous twocore-only allow-set;
    // there is deliberately NO `erlang` entry, since no `erlang:apply` is emitted).
    "twocore@runtime@rt_simd",
    // Phase-7 (P7-06): the tagged-exception chokepoint — a fixed build-controlled atom `emit_core`
    // reaches WITHOUT a `Binding` field (like `rt_ref`/`link`/`rt_simd`), admitted here exactly
    // like a `binding.*_module` (D3a). `erlang:throw`/`erlang:raise/3` live INSIDE `rt_exn`, never
    // in generated code, so there is still deliberately NO `erlang` entry (homogeneous, S5).
    "twocore@runtime@rt_exn",
  ])
}

/// Collect every `#(module_expr, function_expr)` of every `CCall` in `e` (recursively).
fn calls_in(e: CExpr) -> List(#(CExpr, CExpr)) {
  let here = case e {
    CCall(m, f, _) -> [#(m, f)]
    _ -> []
  }
  list.append(here, list.flat_map(children(e), calls_in))
}

/// The direct sub-expressions of a Core node (enough to reach every `CCall`).
fn children(e: CExpr) -> List(CExpr) {
  case e {
    CCall(m, f, args) -> [m, f, ..args]
    CApply(_, args) -> args
    CLet(_, arg, body) -> [arg, body]
    CLetrec(defs, body) -> [
      body,
      ..list.map(defs, fn(d) {
        let FunDef(_, v) = d
        v
      })
    ]
    CCase(arg, clauses) -> [
      arg,
      ..list.flat_map(clauses, fn(c) {
        let CClause(_, g, b) = c
        [g, b]
      })
    ]
    CFun(_, body) -> [body]
    CCons(h, t) -> [h, t]
    CTuple(xs) -> xs
    CValues(xs) -> xs
    // Phase-7 (P7-06): the `try…catch` node MUST be walked — a `CCall` inside the protected `arg`,
    // the success `body`, or the catch `handler` would otherwise ESCAPE the D3a walk (a fail-OPEN
    // hole in the security test itself, §G). The `body_vars`/`evars` are binders (no sub-exprs).
    CTry(arg, _, body, _, handler) -> [arg, body, handler]
    // A compiler primop's args are ordinary sub-exprs (the re-raise's `build_stacktrace(S)`) —
    // walked defensively so a future `CCall` inside a primop arg is reached too.
    CPrimop(_, args) -> args
    _ -> []
  }
}

/// Every `call` in `m` targets a fixed runtime module atom (drawn from `binding`) and a
/// literal function atom.
fn assert_calls_are_runtime(m: CModule, binding: instance.Binding) {
  let allowed = runtime_modules(binding)
  let calls =
    list.flat_map(m.defs, fn(d) {
      let FunDef(_, v) = d
      calls_in(v)
    })
  list.each(calls, fn(pair) {
    let #(mod, fun) = pair
    // module position: a literal atom that is one of the binding's runtime modules.
    let assert CAtom(mod_name) = mod
    assert set.contains(allowed, mod_name) == True
    // function position: a literal atom (never program-chosen/computed).
    let assert CAtom(_) = fun
  })
}

/// A module exercising every emitted `call` kind plus a direct call and a loop.
fn mixed_module() -> ir.Module {
  let kitchen_sink =
    ir.Function(
      name: "f",
      params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Charge(
        3,
        ir.Let(
          ["s"],
          ir.Num(ir.IAdd(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
          ir.Let(
            ["q"],
            // trapping num → case + raise (trap_module call)
            ir.Num(ir.IDivS(ir.W32), [ir.Var("s"), ir.Var("p1")]),
            ir.Let(
              ["h"],
              // host import → deny-all host_module call
              ir.CallHost("env", "log", [ir.Var("q")]),
              ir.Let(
                ["g"],
                // resolved stdlib → stdlib_module call
                ir.CallHost("std", "gcd", [ir.Var("q"), ir.Var("h")]),
                ir.Let(
                  ["d"],
                  // direct self-call → apply (NOT a call)
                  ir.CallDirect("f", [ir.Var("g"), ir.Var("p1")]),
                  ir.Return([ir.Var("d")]),
                ),
              ),
            ),
          ),
        ),
      ),
    )
  ir.Module(
    name: "twocore@test@sink",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [kitchen_sink],
    exports: [ir.ExportFn("f", "f")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// THE security-invariant test: every runtime `call` in a busy module targets a fixed
/// `twocore@runtime@*` module from the `Binding`, with a literal function atom — no
/// ambient authority (D3a).
pub fn no_ambient_authority_in_calls_test() {
  let binding = instance.safe_default()
  let assert Ok(m) = emit_core.emit_module(mixed_module(), binding)
  assert_calls_are_runtime(m, binding)
}

/// Collect every `CApply` target `FName` in `e` (recursively). A `CApply`'s module/function
/// is structurally an `FName` (a literal atom + arity) — there is NO `apply(Mod, F, Args)`
/// form in the AST — so the IR cannot synthesise an ambient-authority dynamic apply.
fn applies_in(e: CExpr) -> List(core_erlang.FName) {
  let here = case e {
    CApply(name, _) -> [name]
    _ -> []
  }
  list.append(here, list.flat_map(children(e), applies_in))
}

/// A module exercising `call_indirect` AND every memory/global/table op + size/grow, plus a
/// table/memory/global declaration with active element/data segments and a start — so the
/// security walk covers the whole new stateful authority and the generated `instantiate/0`.
fn stateful_module() -> ir.Module {
  let target =
    ir.Function(
      name: "target",
      params: [ir.Local("p0", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Return([ir.Var("p0")]),
    )
  let f =
    ir.Function(
      name: "f",
      params: [ir.Local("p0", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        [],
        ir.MemStore(0, ir.MemAccess(4, False), ir.Var("p0"), ir.Var("p0"), 0),
        ir.Let(
          ["g"],
          ir.GlobalGet("g0"),
          ir.Let(
            [],
            ir.GlobalSet("g0", ir.Var("g")),
            ir.Let(
              ["ld"],
              ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("p0"), 0, ir.TI32),
              ir.Let(
                ["sz"],
                ir.MemSize(0),
                ir.Let(
                  ["gr"],
                  ir.MemGrow(0, ir.Var("sz")),
                  ir.CallIndirect(
                    "t0",
                    ir.Var("ld"),
                    ir.FuncType([ir.TI32], [ir.TI32]),
                    [ir.Var("gr")],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    )
  ir.Module(
    name: "twocore@test@stateful",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(0)]))],
    imports: [],
    functions: [target, f],
    exports: [ir.ExportFn("f", "f")],
    data_segments: [
      ir.DataSegment(ir.DataActive(0, ir.Values([ir.ConstI32(0)])), <<9, 9>>),
    ],
    tables: [ir.TableDecl("t0", ir.FuncRef, 4, option.None)],
    elements: [
      ir.ElementSegment(
        ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
        ir.FuncRef,
        [ir.RefFunc("target")],
      ),
    ],
    start: option.None,
    tags: [],
  )
}

/// EXTENDED security invariant: a module using `call_indirect` + every memory/global/table
/// op (and the generated `instantiate/0`) still has NO ambient authority — every emitted
/// `call` targets a fixed `Binding` runtime module with a literal function atom (a).
pub fn stateful_ops_have_no_ambient_authority_test() {
  let binding = instance.safe_default()
  let assert Ok(m) = emit_core.emit_module(stateful_module(), binding)
  assert_calls_are_runtime(m, binding)
}

/// (b) No data-driven `apply`: every `CApply` in the whole module (including the
/// `call_indirect` lowering and the `instantiate/0` element closures) targets a literal
/// `FName` whose module-LOCAL function name is NEVER one of the runtime module atoms — the
/// dispatch is a closed set of compile-time-fixed `f<idx>` applies selected by a runtime
/// integer, never `apply(Mod, F, Args)` of program/runtime data.
pub fn call_indirect_dispatch_is_ambient_safe_test() {
  let binding = instance.safe_default()
  let allowed = runtime_modules(binding)
  let assert Ok(m) = emit_core.emit_module(stateful_module(), binding)
  let applies =
    list.flat_map(m.defs, fn(d) {
      let core_erlang.FunDef(_, v) = d
      applies_in(v)
    })
  // Every apply is a static local FName — its name is never a runtime module atom (an
  // apply can only reach a same-module function, never a cross-module/data-driven target).
  list.each(applies, fn(name) {
    let core_erlang.FName(n, _arity) = name
    assert set.contains(allowed, n) == False
  })
  // (c) The three call_indirect faults are DELEGATED to `rt_table` via the seam call: the
  // dispatch is one `call '<table_module>':'call_indirect'(Idx, TypeTag, Args)` whose
  // `{error,E}` arm raises via `rt_trap` — emit_core emits no per-fault branching itself.
  assert has_call(m, binding.table_module, "call_indirect")
  assert has_call(m, binding.table_module, "init_elem")
  assert has_call(m, binding.trap_module, "raise")
}

/// D3a holds under the UNSAFE posture (F6): with `open` BIF gate + `open` host + passthrough
/// stdlib, the emitted module STILL targets only fixed `Binding` runtime atoms with literal
/// function atoms, and every `apply` is a compile-time-local `FName`. "Open" is a RUNTIME gate
/// posture (rt_host/rt_bif bodies), NOT an emit-time capability — emit_core is posture-agnostic
/// (A.1), so the identical no-ambient-authority walk that guards Safe must pass here. Uses the
/// SAME `stateful_module()` fixture (call_indirect + every mem/global/table op + the
/// `instantiate/0` seed lines) as the Safe walk. Because `runtime_modules(profiles.unsafe())`
/// is the same fixed set as under Safe (identical `*_module` names), passing the walk IS the
/// proof: an Unsafe caller cannot coax emit_core into a program-driven module dispatch.
pub fn no_ambient_authority_under_unsafe_test() {
  let binding = profiles.unsafe()
  let allowed = runtime_modules(binding)
  let assert Ok(m) = emit_core.emit_module(stateful_module(), binding)
  // (a) Every `call` — INCLUDING the `instantiate/0` `seed_policy` line, a fixed
  // `host_module` call baking the `host_open` atom under the open posture — targets a fixed
  // runtime module atom with a literal function atom.
  assert_calls_are_runtime(m, binding)
  // The open-host seed is proven to be a fixed-atom call, not an ambient capability.
  assert has_call(m, binding.host_module, "seed_policy")
  // (b) No data-driven `apply`: every `CApply` is a static local `FName`, never a runtime
  // module atom — the same closed-set dispatch as Safe.
  let applies =
    list.flat_map(m.defs, fn(d) {
      let core_erlang.FunDef(_, v) = d
      applies_in(v)
    })
  list.each(applies, fn(name) {
    let core_erlang.FName(n, _arity) = name
    assert set.contains(allowed, n) == False
  })
  // (c) The three call_indirect faults still delegate to `rt_table`/`rt_trap` (no emit-time
  // per-fault branching) — the open posture widens no emit-site authority.
  assert has_call(m, binding.table_module, "call_indirect")
  assert has_call(m, binding.trap_module, "raise")
}

/// D3a holds under the THREADED posture (P4-02): with `state_strategy: Threaded`, generated
/// code threads the `InstanceState` record as an ordinary VALUE, yet the emitted module STILL
/// targets only fixed `Binding` runtime atoms with literal function atoms, and every `apply` is
/// a compile-time-local `FName`. The threaded seam emits the `t_*`/`fresh` family on the SAME
/// fixed `twocore@runtime@*` modules; `St` is an ordinary argument (a Core var), never a
/// module/function selector; the `call_indirect` index is still the sole runtime-data input to
/// a control transfer and the closures are build-controlled captures of literal `f<idx>` names.
/// Because `runtime_modules(threaded)` is the same fixed set (identical `*_module` names),
/// passing the identical walk IS the proof (keystone §note, unit-doc §"Effect note"). Uses the
/// SAME `stateful_module()` fixture (call_indirect + every mem/global/table op + the record-
/// returning `instantiate/0`).
pub fn no_ambient_authority_under_threaded_test() {
  let binding =
    instance.Binding(
      ..instance.safe_default(),
      state_strategy: instance.Threaded,
    )
  let allowed = runtime_modules(binding)
  let assert Ok(m) = emit_core.emit_module(stateful_module(), binding)
  // (a) Every `call` — INCLUDING the threaded `t_*` seam and the record-BUILDING
  // `rt_state:fresh` in `instantiate/0` — targets a fixed runtime module atom with a literal
  // function atom.
  assert_calls_are_runtime(m, binding)
  // The threaded seam calls the `t_*`/`fresh` family on the fixed `Binding` modules, never a
  // program-chosen module/function.
  assert has_call(m, binding.mem_module, "t_store")
  assert has_call(m, binding.mem_module, "t_load")
  assert has_call(m, binding.state_module, "t_global_get")
  assert has_call(m, binding.state_module, "t_global_set")
  assert has_call(m, binding.table_module, "t_call_indirect")
  assert has_call(m, binding.state_module, "fresh")
  // (b) No data-driven `apply`: every `CApply` is a static local `FName`, never a runtime
  // module atom — the same closed-set dispatch as Cell (the threaded `St` is a closure/function
  // PARAMETER, not a dispatch key).
  let applies =
    list.flat_map(m.defs, fn(d) {
      let core_erlang.FunDef(_, v) = d
      applies_in(v)
    })
  list.each(applies, fn(name) {
    let core_erlang.FName(n, _arity) = name
    assert set.contains(allowed, n) == False
  })
  // (c) The three call_indirect faults still delegate to `rt_table`/`rt_trap` (no emit-time
  // per-fault branching) — threading the record widens no emit-site authority.
  assert has_call(m, binding.trap_module, "raise")
}

/// A Phase-5 module exercising the WHOLE new authority surface (§Verification test 5):
/// `ref.func`/`ref.is_null`, every table op (`get`/`set`/`size`/`grow`/`fill`/`init`/`copy`),
/// every bulk-memory op (`fill`/`copy`/`init`/`data.drop`/`elem.drop`), a SECOND memory (memidx
/// 1, `_at` routing), a passive data + passive element segment (drop-gated payloads), a
/// `table.copy` between two tables, a non-function import (a `spectest` global + an `env` memory
/// → the `link.provided_*` weaving in `instantiate/1`), a reference-typed global (the
/// `ref_globals` path), and exported STATE (global/table/memory accessors).
fn phase5_module() -> ir.Module {
  let target =
    ir.Function(
      name: "target",
      params: [ir.Local("p0", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Return([ir.Var("p0")]),
    )
  let f =
    ir.Function(
      name: "f",
      params: [ir.Local("p0", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        ["ref"],
        ir.RefFunc("target"),
        ir.Let(
          ["nn"],
          ir.RefIsNull(ir.Var("ref")),
          ir.Let(
            [],
            ir.TableSet("t0", ir.ConstI32(0), ir.Var("ref")),
            ir.Let(
              ["g"],
              ir.TableGet("t0", ir.ConstI32(0)),
              ir.Let(
                ["_sz"],
                ir.TableSize("t0"),
                ir.Let(
                  ["_og"],
                  ir.TableGrow("t0", ir.ConstI32(1), ir.Var("ref")),
                  ir.Let(
                    [],
                    ir.TableFill(
                      "t0",
                      ir.ConstI32(0),
                      ir.Var("ref"),
                      ir.ConstI32(1),
                    ),
                    ir.Let(
                      [],
                      ir.TableInit(
                        "t0",
                        2,
                        ir.ConstI32(0),
                        ir.ConstI32(0),
                        ir.ConstI32(0),
                      ),
                      ir.Let(
                        [],
                        ir.TableCopy(
                          "t0",
                          "t1",
                          ir.ConstI32(0),
                          ir.ConstI32(0),
                          ir.ConstI32(0),
                        ),
                        ir.Let(
                          [],
                          ir.ElemDrop(2),
                          ir.Let(
                            [],
                            ir.MemFill(
                              0,
                              ir.ConstI32(0),
                              ir.ConstI32(0),
                              ir.ConstI32(0),
                            ),
                            ir.Let(
                              [],
                              ir.MemCopy(
                                0,
                                1,
                                ir.ConstI32(0),
                                ir.ConstI32(0),
                                ir.ConstI32(0),
                              ),
                              ir.Let(
                                [],
                                ir.MemInit(
                                  0,
                                  0,
                                  ir.ConstI32(0),
                                  ir.ConstI32(0),
                                  ir.ConstI32(0),
                                ),
                                ir.Let(
                                  [],
                                  ir.DataDrop(0),
                                  ir.Let(
                                    [],
                                    ir.MemStore(
                                      1,
                                      ir.MemAccess(4, False),
                                      ir.ConstI32(0),
                                      ir.Var("p0"),
                                      0,
                                    ),
                                    ir.Let(
                                      ["ld"],
                                      ir.MemLoad(
                                        1,
                                        ir.MemAccess(4, False),
                                        ir.ConstI32(0),
                                        0,
                                        ir.TI32,
                                      ),
                                      ir.CallIndirect(
                                        "t0",
                                        ir.Var("ld"),
                                        ir.FuncType([ir.TI32], [ir.TI32]),
                                        [ir.Var("p0")],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    )
  ir.Module(
    name: "twocore@test@phase5",
    uses_numerics: True,
    // Imported memory (env) at memidx 0; defined memory at memidx 1.
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [
      ir.GlobalDecl(
        "gref",
        ir.TFuncRef,
        False,
        ir.Values([
          ir.ConstNull(ir.FuncRef),
        ]),
      ),
    ],
    imports: [
      ir.ImportGlobal("spectest", "global_i32", ir.TI32, False),
      ir.ImportMemory("env", "mem", 1, option.None, ir.Idx32),
    ],
    functions: [target, f],
    exports: [
      ir.ExportFn("f", "f"),
      ir.ExportGlobal("eg", "g0"),
      ir.ExportGlobal("egref", "gref"),
      ir.ExportTable("et", "t0"),
      ir.ExportMemory("em", 1),
    ],
    data_segments: [ir.DataSegment(ir.DataPassive, <<1, 2>>)],
    tables: [
      ir.TableDecl("t0", ir.FuncRef, 4, option.None),
      ir.TableDecl("t1", ir.FuncRef, 4, option.None),
    ],
    elements: [
      ir.ElementSegment(
        ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
        ir.FuncRef,
        [ir.RefFunc("target")],
      ),
      // active at table 1 → routes through `init_elem_ref` (non-zero table).
      ir.ElementSegment(
        ir.ElemActive("t1", ir.Values([ir.ConstI32(0)])),
        ir.FuncRef,
        [ir.RefFunc("target")],
      ),
      // passive → consumed by `table.init`, dropped by `elem.drop` (seg index 2).
      ir.ElementSegment(ir.ElemPassive, ir.FuncRef, [ir.RefFunc("target")]),
    ],
    start: option.None,
    tags: [],
  )
}

/// EXTENDED D3a walk over the WHOLE Phase-5 authority (references/tables/bulk/multi-mem/passive
/// segments/imports/exported state), under Cell, Threaded, AND Unsafe — all three must pass with
/// the same allow-set: (a) every `call` targets a fixed runtime-module atom (a `binding.*_module`
/// OR the fixed `rt_ref`/`link` atoms) with a literal function atom; (b) every `apply` is a static
/// local `FName` (the `ref.func`/element closures are literal captures — no data-driven apply);
/// (c) the new seam calls are delegated to the runtime, and the import weaving/exports/drops go
/// through fixed `link`/`rt_state` calls — never a program-driven dispatch (D3a).
pub fn phase5_ops_have_no_ambient_authority_test() {
  let cell = instance.safe_default()
  let threaded =
    instance.Binding(
      ..instance.safe_default(),
      state_strategy: instance.Threaded,
    )
  let unsafe = profiles.unsafe()
  list.each([cell, threaded, unsafe], fn(binding) {
    let assert Ok(m) = emit_core.emit_module(phase5_module(), binding)
    // (a) every call → a fixed runtime module + literal function atom.
    assert_calls_are_runtime(m, binding)
    // (b) every apply → a static local FName, never a runtime-module atom.
    let allowed = runtime_modules(binding)
    let applies =
      list.flat_map(m.defs, fn(d) {
        let core_erlang.FunDef(_, v) = d
        applies_in(v)
      })
    list.each(applies, fn(name) {
      let core_erlang.FName(n, _arity) = name
      assert set.contains(allowed, n) == False
    })
    // (c) the new authority is delegated to fixed runtime calls (a representative sample).
    // `has_op` accepts either the cell op or its `t_`-prefixed threaded twin, so the same
    // structural assertions hold across `Cell`/`Threaded`/`Unsafe`.
    assert has_call(m, "twocore@runtime@rt_ref", "is_null")
    assert has_op(m, binding.table_module, "fill")
    assert has_op(m, binding.table_module, "table_copy")
    assert has_op(m, binding.table_module, "init_elem_ref")
    assert has_op(m, binding.mem_module, "copy")
    assert has_op(m, binding.state_module, "drop_data")
    assert has_op(m, binding.state_module, "drop_elem")
    assert has_call(m, "twocore@runtime@link", "provided_memory_value")
    assert has_call(m, "twocore@runtime@link", "provided_global_bits")
    // the import-bearing module builds its state via `seed_full`/`fresh_full`.
    assert has_call(m, binding.state_module, "seed_full")
      || has_call(m, binding.state_module, "fresh_full")
  })
}

/// True iff `m` contains either the cell op `fun` or its `t_`-prefixed threaded twin on `module`.
fn has_op(m: CModule, module: String, fun: String) -> Bool {
  has_call(m, module, fun) || has_call(m, module, "t_" <> fun)
}

/// True iff some def in `m` contains a `call '<module>':'<fun>'(…)`.
fn has_call(m: CModule, module: String, fun: String) -> Bool {
  list.any(m.defs, fn(d) {
    let core_erlang.FunDef(_, v) = d
    list.any(calls_in(v), fn(pair) {
      let #(mod, f) = pair
      mod == CAtom(module) && f == CAtom(fun)
    })
  })
}

/// A Phase-6 module exercising the WHOLE new authority surface (P6-06 §Verification test 7):
/// pure SIMD arithmetic + a shuffle, every SIMD-memory node (`v128.store`/`load`/`storeN_lane`), a
/// SECOND memory that is 64-bit (`Idx64` → `fresh64` + the mem64 cap), a `v128` global
/// (`ref_globals` routing), and a cross-module `CallImport` (the linker-built closure capability).
fn p6_module() -> ir.Module {
  let ty = ir.FuncType([ir.TI32], [ir.TI32])
  // Pure lane arithmetic (state-neutral).
  let simd_arith =
    ir.Function(
      name: "simd_arith",
      params: [ir.Local("a", ir.TV128), ir.Local("b", ir.TV128)],
      result: [ir.TV128],
      locals: [],
      body: ir.Simd(ir.SAdd(ir.I32x4), [ir.Var("a"), ir.Var("b")]),
    )
  // A busy function: SIMD memory (store/load/store-lane) + shuffle + a v128 global get/set + a
  // cross-module CallImport.
  let busy =
    ir.Function(
      name: "busy",
      params: [
        ir.Local("addr", ir.TI32),
        ir.Local("v", ir.TV128),
        ir.Local("x", ir.TI32),
      ],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        [],
        ir.SimdStore(0, ir.Var("addr"), ir.Var("v"), 0),
        ir.Let(
          ["loaded"],
          ir.SimdLoad(0, ir.LoadV128, ir.Var("addr"), 0),
          ir.Let(
            [],
            ir.SimdStoreLane(0, 8, ir.Var("addr"), 0, 2, ir.Var("loaded")),
            ir.Let(
              ["shuf"],
              ir.SimdShuffle(
                [0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23],
                ir.Var("v"),
                ir.Var("loaded"),
              ),
              ir.Let(
                [],
                ir.GlobalSet("gv", ir.Var("shuf")),
                ir.CallImport(0, ty, [ir.Var("x")]),
              ),
            ),
          ),
        ),
      ),
    )
  ir.Module(
    name: "twocore@test@p6",
    uses_numerics: True,
    memories: [
      ir.MemoryDecl(1, option.None, ir.Idx32),
      ir.MemoryDecl(1, option.None, ir.Idx64),
    ],
    globals: [
      ir.GlobalDecl(
        "gv",
        ir.TV128,
        True,
        ir.Values([
          ir.ConstV128(<<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>),
        ]),
      ),
    ],
    imports: [ir.ImportFn("modA", "g", ty)],
    functions: [simd_arith, busy],
    exports: [
      ir.ExportFn("busy", "busy"),
      ir.ExportFn("simd_arith", "simd_arith"),
    ],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// EXTENDED D3a security invariant for the Phase-6 surface (P6-06): SIMD arithmetic + SIMD memory +
/// an `Idx64` memory + a `v128` global + a cross-module `CallImport`, under Cell, Threaded, AND the
/// Unsafe posture — all still ambient-free. (a) every `call` targets a fixed `Binding`/allow-set
/// runtime atom with a literal function; (b) every `apply` is a static local `FName`; (c) the
/// SURGICAL closure-dispatch proof: the ONLY `erlang:*` call is NONE (no `erlang:apply` anywhere —
/// the dispatch is `link:call_import` over a closure read from `rt_state:func_import_at`); (d) the
/// new seams are delegated to the runtime.
pub fn phase6_ops_have_no_ambient_authority_test() {
  let cell = instance.safe_default()
  let threaded =
    instance.Binding(
      ..instance.safe_default(),
      state_strategy: instance.Threaded,
    )
  let unsafe = profiles.unsafe()
  list.each([cell, threaded, unsafe], fn(binding) {
    let assert Ok(m) = emit_core.emit_module(p6_module(), binding)
    // (a) every call → a fixed runtime/allow-set module + literal function atom (the allow-set now
    // includes `rt_simd`; the closure dispatch uses the already-admitted `link`).
    assert_calls_are_runtime(m, binding)
    // (b) every apply → a static local FName, never a runtime-module atom.
    let allowed = runtime_modules(binding)
    let applies =
      list.flat_map(m.defs, fn(d) {
        let core_erlang.FunDef(_, v) = d
        applies_in(v)
      })
    list.each(applies, fn(name) {
      let core_erlang.FName(n, _arity) = name
      assert set.contains(allowed, n) == False
    })
    // (c) THE surgical closure-dispatch assertion: NO `erlang:apply` (nor any `erlang:*`) is emitted
    // anywhere — the S5 model dispatches via `link:call_import` over a HANDED-IN closure read from
    // the instance's positional func-import slot, never an ambient `apply` of a data-named target.
    assert has_call(m, "erlang", "apply") == False
    assert erlang_calls(m) == []
    assert has_call(m, "twocore@runtime@link", "call_import")
    assert has_call(m, binding.state_module, "func_import_at")
      || has_call(m, binding.state_module, "t_func_import_at")
    // (d) the new seams are delegated to the runtime: the SIMD chokepoint, the bounds-checked
    // byte-slice seam, the mem64 fresh64 handle, the func-import vector seed, and — on a SIMD-memory
    // fault — `rt_trap:raise`.
    assert has_call(m, "twocore@runtime@rt_simd", "i32x4_add")
    assert has_call(m, "twocore@runtime@rt_simd", "i8x16_shuffle")
    assert has_op(m, binding.mem_module, "store_bytes")
    assert has_op(m, binding.mem_module, "load_bytes")
    assert has_call(m, binding.mem_module, "fresh64")
    // The func-import vector is seeded via `seed_func_imports` (cell) / `set_func_imports` (threaded).
    assert has_call(m, binding.state_module, "seed_func_imports")
      || has_call(m, binding.state_module, "set_func_imports")
    assert has_call(m, "twocore@runtime@link", "provided_func_call")
    // the v128 global routes to the BOXED accessor, not the numeric one.
    assert has_op(m, binding.state_module, "ref_global_set")
    assert has_call(m, binding.trap_module, "raise")
  })
}

/// A Phase-8 module exercising the WHOLE JS runtime boundary surface (P8-05 §Tests, K6/D3a): all
/// three build-fixed `rt_js` stub ops — `add/2` (two args), `type_of/1` (the `add` result), and
/// `undefined_sentinel/0` (zero args) — chained so every emitted `"js"` `CallHost` is covered by
/// the D3a walk, including the 0-arg dispatch.
fn js_module() -> ir.Module {
  let f =
    ir.Function(
      name: "f",
      params: [ir.Local("p0", ir.TTerm), ir.Local("p1", ir.TTerm)],
      result: [ir.TTerm],
      locals: [],
      body: ir.Let(
        ["s"],
        ir.CallHost("js", "add", [ir.Var("p0"), ir.Var("p1")]),
        ir.Let(
          ["t"],
          ir.CallHost("js", "type_of", [ir.Var("s")]),
          ir.Let(
            ["u"],
            ir.CallHost("js", "undefined_sentinel", []),
            ir.Return([ir.Var("u")]),
          ),
        ),
      ),
    )
  ir.Module(
    name: "twocore@test@p8js",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [f],
    exports: [ir.ExportFn("f", "f")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// EXTENDED D3a security invariant for the Phase-8 JS runtime boundary (P8-05 §Tests, K6): three
/// `CallHost("js", op, args)` (`add`/`type_of`/`undefined_sentinel`), under Cell, Threaded, AND
/// the Unsafe posture — all still ambient-free. (a) every `call` targets a fixed allow-set runtime
/// atom (now including `js_runtime_module`) with a literal function atom; (b) every `apply` is a
/// static local `FName`; (c) NO `erlang:*` call is emitted — the boundary is a `call` to the
/// build-fixed `rt_js` atom, never `apply` from data; (d) each op routes to its build-fixed
/// `rt_js` function (`resolve_js`), proving the `op` string is a selector among a CLOSED set of
/// literal function atoms, never an MFA constructor. Because the boundary is bound to
/// `binding.js_runtime_module`, the walk holds under every posture (the atom is identical across
/// them, so passing IS the proof no posture coaxes a program-driven dispatch).
pub fn js_runtime_boundary_has_no_ambient_authority_test() {
  let cell = instance.safe_default()
  let threaded =
    instance.Binding(
      ..instance.safe_default(),
      state_strategy: instance.Threaded,
    )
  let unsafe = profiles.unsafe()
  list.each([cell, threaded, unsafe], fn(binding) {
    let assert Ok(m) = emit_core.emit_module(js_module(), binding)
    // (a) every call → a fixed runtime/allow-set module + literal function atom.
    assert_calls_are_runtime(m, binding)
    // (b) every apply → a static local FName, never a runtime-module atom.
    let allowed = runtime_modules(binding)
    let applies =
      list.flat_map(m.defs, fn(d) {
        let core_erlang.FunDef(_, v) = d
        applies_in(v)
      })
    list.each(applies, fn(name) {
      let core_erlang.FName(n, _arity) = name
      assert set.contains(allowed, n) == False
    })
    // (c) NO `erlang:*` is emitted — the JS boundary is a fixed-atom `call`, never `apply` of data.
    assert has_call(m, "erlang", "apply") == False
    assert erlang_calls(m) == []
    // (d) each op routes to its build-fixed `rt_js` function on the bound `js_runtime_module`.
    assert has_call(m, binding.js_runtime_module, "add")
    assert has_call(m, binding.js_runtime_module, "type_of")
    assert has_call(m, binding.js_runtime_module, "undefined_sentinel")
  })
}

/// A Phase-14 module exercising the IMPORTED-`ref.func` adapter surface (R14-02 §5.5): an
/// `ImportFn` (funcidx 0) placed into a `FuncRef` table via an active `elem` `RefFuncImport`
/// segment, dispatched by `call_indirect`. The generated instantiate builds the D3a adapter closure
/// for the imported slot — the exact new authority this test must certify is ambient-free.
fn imported_funcref_module() -> ir.Module {
  let ty = ir.FuncType([ir.TI32], [ir.TI32])
  let dispatch =
    ir.Function(
      name: "dispatch",
      params: [ir.Local("k", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.CallIndirect("t0", ir.ConstI32(0), ty, [ir.Var("k")]),
    )
  ir.Module(
    name: "twocore@test@rfi",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [ir.ImportFn("a", "ef", ty)],
    functions: [dispatch],
    exports: [ir.ExportFn("dispatch", "dispatch")],
    data_segments: [],
    tables: [ir.TableDecl("t0", ir.FuncRef, 2, option.None)],
    elements: [
      ir.ElementSegment(
        ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
        ir.FuncRef,
        [ir.RefFuncImport(0, ty)],
      ),
    ],
    start: option.None,
    tags: [],
  )
}

/// EXTENDED D3a security invariant for the Phase-14 imported-`ref.func` adapter (R14-02 §5.5), under
/// Cell, Threaded, AND Unsafe — all ambient-free with NO new module atom or allow-set entry. (a)
/// every `call` targets a fixed `Binding`/allow-set runtime atom with a literal function; (b) every
/// `apply` is a static local `FName`; (c) THE surgical assertion: the adapter captures only the
/// LITERAL slot — its ONLY calls are `link:call_import` over a closure read from
/// `rt_state:func_import_at` / `t_func_import_at`, and NO `erlang:*` (never `erlang:apply` of a
/// data-named target). The adapter routes through the already-admitted `link.call_import` seam — no
/// new allow-set entry is required.
pub fn imported_funcref_adapter_has_no_ambient_authority_test() {
  let cell = instance.safe_default()
  let threaded =
    instance.Binding(
      ..instance.safe_default(),
      state_strategy: instance.Threaded,
    )
  let unsafe = profiles.unsafe()
  list.each([cell, threaded, unsafe], fn(binding) {
    let assert Ok(m) = emit_core.emit_module(imported_funcref_module(), binding)
    // (a) every call → a fixed runtime/allow-set module + literal function atom.
    assert_calls_are_runtime(m, binding)
    // (b) every apply → a static local FName, never a runtime-module atom.
    let allowed = runtime_modules(binding)
    let applies =
      list.flat_map(m.defs, fn(d) {
        let core_erlang.FunDef(_, v) = d
        applies_in(v)
      })
    list.each(applies, fn(name) {
      let core_erlang.FName(n, _arity) = name
      assert set.contains(allowed, n) == False
    })
    // (c) NO `erlang:*` is emitted — the adapter dispatch is a `call` to the fixed `link`/`rt_state`
    // atoms over a HANDED-IN closure read from the func-import slot, never `apply` of program data.
    assert has_call(m, "erlang", "apply") == False
    assert erlang_calls(m) == []
    // The adapter's dispatch: `link:call_import` over the slot closure read via
    // `rt_state:func_import_at` (cell) / `t_func_import_at` (threaded). The ONLY program-derived
    // operand is the literal integer slot.
    assert has_call(m, "twocore@runtime@link", "call_import")
    assert has_call(m, binding.state_module, "func_import_at")
      || has_call(m, binding.state_module, "t_func_import_at")
  })
}

/// Every `#(module, fun)` `CCall` whose module position is the literal atom `'erlang'` — the D3a
/// forbidden ambient-authority surface. Must be EMPTY: the Phase-6 dispatch names no `erlang:*`.
fn erlang_calls(m: CModule) -> List(#(CExpr, CExpr)) {
  list.flat_map(m.defs, fn(d) {
    let FunDef(_, v) = d
    calls_in(v)
  })
  |> list.filter(fn(pair) {
    let #(mod, _f) = pair
    mod == CAtom("erlang")
  })
}

/// A Phase-7 module exercising the WHOLE new EH authority surface (P7-06 §G): a `throw` (the raise
/// chokepoint), a MULTI-clause `try` (`catch $t0` + `catch_ref $t1` + `catch_all` + the implicit
/// re-raise), and a `throw_ref` (re-raise a captured exnref) — so every emitted EH `call` is
/// covered under the D3a walk, INCLUDING calls buried inside the try body + handler dispatch.
fn p7_eh_module() -> ir.Module {
  let handlers = [
    // catch $t0 — recover the payload.
    ir.CatchHandler(
      ir.OnTag("tag0"),
      ["p"],
      option.None,
      ir.Return([ir.Var("p")]),
    ),
    // catch_ref $t1 — capture an exnref, then throw_ref it (re-raise).
    ir.CatchHandler(
      ir.OnTag("tag1"),
      ["q"],
      option.Some("e"),
      ir.ThrowRef(ir.Var("e")),
    ),
    // catch_all — recover a constant (catches any wasm exn, NOT a trap).
    ir.CatchHandler(ir.OnAll, [], option.None, ir.Return([ir.ConstI32(0)])),
  ]
  let f =
    ir.Function(
      "f",
      [ir.Local("a", ir.TI32)],
      [ir.TI32],
      [],
      ir.Try([ir.TI32], ir.Throw("tag0", [ir.Var("a")]), handlers),
    )
  ir.Module(
    name: "twocore@test@p7eh",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [f],
    exports: [ir.ExportFn("f", "f")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [ir.TagDecl("tag0", [ir.TI32]), ir.TagDecl("tag1", [ir.TI32])],
  )
}

/// EXTENDED D3a security invariant for the Phase-7 EH surface (P7-06 §G): a `throw`, a multi-clause
/// `try` (`catch` + `catch_ref` + `catch_all` + re-raise), and a `throw_ref`, under Cell, Threaded,
/// AND the Unsafe posture — all still ambient-free. (a) every `call` targets a fixed allow-set
/// runtime atom (now including `rt_exn`) with a literal function; (b) every `apply` is a static
/// local `FName`; (c) NO `erlang:*` call is emitted — the raise / catch-dispatch / re-raise /
/// exnref-capture ALL route through `rt_exn` (`erlang:throw`/`raise/3` live inside it, homogeneous
/// allow-set, S5); (d) the EH seams are delegated to `rt_exn`. Because the `throw_exn` lives in the
/// try's protected ARG and `capture_exnref`/`reraise` live INSIDE the catch handler, asserting them
/// present is also the regression guard that the `children` walk descends into the `CTry` (§G).
pub fn phase7_eh_ops_have_no_ambient_authority_test() {
  let cell = instance.safe_default()
  let threaded =
    instance.Binding(
      ..instance.safe_default(),
      state_strategy: instance.Threaded,
    )
  let unsafe = profiles.unsafe()
  list.each([cell, threaded, unsafe], fn(binding) {
    let assert Ok(m) = emit_core.emit_module(p7_eh_module(), binding)
    // (a) every call → a fixed runtime/allow-set module + literal function atom.
    assert_calls_are_runtime(m, binding)
    // (b) every apply → a static local FName, never a runtime-module atom.
    let allowed = runtime_modules(binding)
    let applies =
      list.flat_map(m.defs, fn(d) {
        let core_erlang.FunDef(_, v) = d
        applies_in(v)
      })
    list.each(applies, fn(name) {
      let core_erlang.FName(n, _arity) = name
      assert set.contains(allowed, n) == False
    })
    // (c) NO `erlang:*` is emitted — the whole EH authority routes through `rt_exn` (S5).
    assert has_call(m, "erlang", "apply") == False
    assert erlang_calls(m) == []
    // (d) the EH seams are delegated to `rt_exn` — reached INSIDE the CTry arg + handler (the
    // `children`-walk regression guard: a missing `CTry` arm makes these `has_call`s FALSE).
    assert has_call(m, "twocore@runtime@rt_exn", "throw_exn")
    assert has_call(m, "twocore@runtime@rt_exn", "match_tag")
    assert has_call(m, "twocore@runtime@rt_exn", "is_wasm_exn")
    assert has_call(m, "twocore@runtime@rt_exn", "reraise")
    assert has_call(m, "twocore@runtime@rt_exn", "capture_exnref")
    assert has_call(m, "twocore@runtime@rt_exn", "throw_ref")
  })
}
