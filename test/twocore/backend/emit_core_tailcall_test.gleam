//// Q13-05 — `emit_core` constant-stack TAIL-CALL emission tests.
////
//// Two layers, both spec-cited (WASM tail-call proposal) and objective — NOT emitted-text
//// change-detectors:
////
//// **Structural** (pattern-match the emitted `core_erlang` AST): a `ReturnCall` is a BARE tail
//// `apply` (no wrapping `let`/`case`/tuple between it and the function boundary); a
//// `ReturnCallIndirect` is the `rt_table.call_indirect_lookup` seam as the WHOLE `case`, whose
//// ok-arm tail-applies the target and whose error-arm re-raises the seam's `TrapReason`; a
//// `ReturnCallImport` routes through the EXISTING import path under `KReturn` (a bounded frame, not
//// a bare tail apply — the honest Q8 sub-case).
////
//// **Behavioral** (compile → load → RUN on the BEAM): the honest "is it really a tail call" test —
//// a `return_call` self-loop and a `return_call_indirect` self-loop each to 1,000,000 complete in
//// CONSTANT SPACE (a wrapped/non-tail emission would exhaust the process), even/odd mutual recursion
//// via `return_call` computes the right parity at 1,000,000, the three indirect fail-closed traps
//// fire in order, an imported `return_call` is value-correct, and an even/odd program compiles +
//// runs correctly under the AGGRESSIVE inliner (proving the inliner excludes tail-call bodies).

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import twocore/backend/build_beam
import twocore/backend/core_erlang.{
  type CExpr, type FunDef, CApply, CApplyExpr, CAtom, CCall, CCase, CClause,
  CCons, CFun, CInt, CLet, CNil, CTuple, CVar, FName, FunDef, PAtom, PTuple,
  PVar,
}
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/ir
import twocore/middle/ir_opt
import twocore/opt_level.{Aggressive, Baseline, OptNone}
import twocore/runtime/instance
import twocore/runtime/link

// ── test-only FFI (shared `twocore_emit_test_ffi`, see the e2e suite) ──────────────

@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply_dyn(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

@external(erlang, "erlang", "apply")
fn apply3(module: Atom, function: Atom, args: List(Dynamic)) -> Dynamic

// ── harness ────────────────────────────────────────────────────────────────────────

fn binding() -> instance.Binding {
  instance.safe_default()
}

/// A Safe binding switched to the tier-P `Threaded` state strategy.
fn threaded_binding() -> instance.Binding {
  instance.Binding(..instance.safe_default(), state_strategy: instance.Threaded)
}

/// A numerics-on module wrapping `functions` (exporting each by name) with `imports` + `tables`.
fn hand_module(
  name: String,
  imports: List(ir.ImportDecl),
  functions: List(ir.Function),
  tables: List(ir.TableDecl),
  elements: List(ir.ElementSegment),
) -> ir.Module {
  ir.Module(
    name: "twocore@tc@" <> name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: imports,
    functions: functions,
    exports: list.map(functions, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: tables,
    elements: elements,
    start: option.None,
    tags: [],
  )
}

/// Emit `module` under `binding` and return the def named `name`.
fn def_of(module: ir.Module, b: instance.Binding, name: String) -> FunDef {
  let assert Ok(cm) = emit_core.emit_module(module, b)
  let assert Ok(d) =
    list.find(cm.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == name
    })
  d
}

/// Emit `module` under `binding` and return the Core BODY of function `name`.
fn body_of(module: ir.Module, b: instance.Binding, name: String) -> CExpr {
  let assert FunDef(_, CFun(_, body)) = def_of(module, b, name)
  body
}

/// Emit `module` (under `b`), compile it, and load it; return the loaded module atom.
fn load(module: ir.Module, b: instance.Binding) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(module, b)
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

fn instantiate(mod: Atom) -> Nil {
  let assert Ok(_) = catch_apply(mod, atom.create("instantiate"), [])
  Nil
}

/// The `func_type_term` a call site / element entry renders for `[i32]->[i32]` — a compile-time
/// canonical Core term `{[i32], [i32]}` (so `rt_table`'s guard-3 `==` holds). Built by hand to tie
/// the tail seam's `TypeTag` to the SAME renderer the non-tail seam uses.
fn i32_i32_tag() -> CExpr {
  CTuple([CCons(CAtom("i32"), CNil), CCons(CAtom("i32"), CNil)])
}

// ══════════════════════════ STRUCTURAL — genuine tail apply ══════════════════════════

/// `ReturnCall("g", [x])` (both pure, `NoState`) emits as the WHOLE body `apply 'g'/1(x)` — a bare
/// BEAM tail call, no wrapping `let`/`case`/tuple.
pub fn direct_return_call_is_bare_tail_apply_test() {
  let g =
    ir.Function(
      "g",
      [ir.Local("p", ir.TI32)],
      [ir.TI32],
      [],
      ir.Return([ir.Var("p")]),
    )
  let f =
    ir.Function(
      "f",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.ReturnCall("g", [ir.Var("x")]),
    )
  body_of(hand_module("direct", [], [g, f], [], []), binding(), "f")
  |> should.equal(CApply(FName("g", 1), [CVar("x")]))
}

/// `ReturnCall("g", [x])` to a STATE-REACHING callee under `Threaded` emits the bare tail
/// `apply 'g'/(n+1)(St, x)` returning `{Package, St'}` straight through — the threaded return shape
/// reached THROUGH a tail node. Also proves the `direct_callees` `ReturnCall` edge: the pure-bodied
/// `f` is classified state-reaching (so it is emitted at `f/2` and threads `St`).
pub fn threaded_direct_return_call_to_state_reaching_is_tail_apply_test() {
  // `g` touches memory → state-reaching; `f` only tail-calls it.
  let g =
    ir.Function(
      "g",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("x"), 0, ir.TI32),
    )
  let f =
    ir.Function(
      "f",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.ReturnCall("g", [ir.Var("x")]),
    )
  let m =
    ir.Module(
      name: "twocore@tc@threaded_direct",
      uses_numerics: True,
      memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
      globals: [],
      imports: [],
      functions: [g, f],
      exports: [ir.ExportFn("f", "f")],
      data_segments: [],
      tables: [],
      elements: [],
      start: option.None,
      tags: [],
    )
  let assert FunDef(FName("f", 2), CFun([st, "x"], body)) =
    def_of(m, threaded_binding(), "f")
  // the whole body IS the tail apply — no wrapping, {Package, St'} straight through.
  let assert CApply(FName("g", 2), [CVar(st_arg), CVar("x")]) = body
  assert st_arg == st
}

/// `ReturnCallIndirect("t0", idx, [i32]->[i32], [x])` (`NoState`, default table) emits the
/// `call_indirect_lookup` seam as the WHOLE `case`, whose ok-arm TAIL-APPLIES the target over the
/// args list (no `let`/unpack) and whose error-arm re-raises the seam's `TrapReason`.
pub fn indirect_return_call_ok_arm_is_tail_apply_test() {
  let callfn =
    ir.Function(
      "callfn",
      [ir.Local("idx", ir.TI32), ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.ReturnCallIndirect(
        "t0",
        ir.Var("idx"),
        ir.FuncType([ir.TI32], [ir.TI32]),
        [ir.Var("x")],
      ),
    )
  let m =
    hand_module(
      "indirect",
      [],
      [callfn],
      [ir.TableDecl("t0", ir.FuncRef, 4, option.None)],
      [],
    )
  let assert CCase(
    CCall(CAtom(tmod), CAtom("call_indirect_lookup"), [CVar("idx"), tag]),
    clauses,
  ) = body_of(m, binding(), "callfn")
  // the un-indexed head (byte-identity, single-table), and guard-3 TypeTag identical to non-tail.
  assert tmod == "twocore@runtime@rt_table"
  assert tag == i32_i32_tag()
  let assert [
    CClause([PTuple([PAtom("ok"), PVar(t)])], CAtom("true"), ok_body),
    CClause([PTuple([PAtom("error"), PVar(e)])], CAtom("true"), err_body),
  ] = clauses
  // the ok-arm is EXACTLY the tail apply of the target over the args LIST — no CLet/unpack/case.
  let assert CApplyExpr(CVar(t2), [CCons(CVar("x"), CNil)]) = ok_body
  assert t2 == t
  // the error-arm re-raises the seam's TrapReason verbatim.
  let assert CCall(CAtom(_trap), CAtom("raise"), [CVar(e2)]) = err_body
  assert e2 == e
}

/// A multi-table module selects the `_at` head with a leading `CInt(idx)` (idx ≥ 1); the ok/error
/// arms are otherwise identical.
pub fn indirect_return_call_multi_table_uses_at_head_test() {
  let callfn =
    ir.Function(
      "callfn",
      [ir.Local("idx", ir.TI32), ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.ReturnCallIndirect(
        "t1",
        ir.Var("idx"),
        ir.FuncType([ir.TI32], [ir.TI32]),
        [ir.Var("x")],
      ),
    )
  let m =
    hand_module(
      "indirect_multi",
      [],
      [callfn],
      [
        ir.TableDecl("t0", ir.FuncRef, 1, option.None),
        ir.TableDecl("t1", ir.FuncRef, 4, option.None),
      ],
      [],
    )
  let assert CCase(
    CCall(
      CAtom(_),
      CAtom("call_indirect_lookup_at"),
      [CInt(1), CVar("idx"), tag],
    ),
    _clauses,
  ) = body_of(m, binding(), "callfn")
  assert tag == i32_i32_tag()
}

/// Under `Threaded`, the indirect tail call threads the read-only `cur` into BOTH the lookup and
/// the 2-ary target apply (the SAME `cur`, no rebind); the target returns `{Package, St'}`.
pub fn threaded_indirect_return_call_threads_cur_test() {
  let callfn =
    ir.Function(
      "callfn",
      [ir.Local("idx", ir.TI32), ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.ReturnCallIndirect(
        "t0",
        ir.Var("idx"),
        ir.FuncType([ir.TI32], [ir.TI32]),
        [ir.Var("x")],
      ),
    )
  let m =
    hand_module(
      "indirect_threaded",
      [],
      [callfn],
      [ir.TableDecl("t0", ir.FuncRef, 4, option.None)],
      [],
    )
  let assert FunDef(FName("callfn", 3), CFun([st, "idx", "x"], body)) =
    def_of(m, threaded_binding(), "callfn")
  let assert CCase(
    CCall(
      CAtom(_),
      CAtom("t_call_indirect_lookup"),
      [CVar(st_lookup), CVar("idx"), _tag],
    ),
    [
      CClause([PTuple([PAtom("ok"), PVar(t)])], CAtom("true"), ok_body),
      CClause([PTuple([PAtom("error"), PVar(_e)])], CAtom("true"), _err),
    ],
  ) = body
  assert st_lookup == st
  // the target apply threads the SAME cur, then the args list — returns {Package, St'}.
  let assert CApplyExpr(CVar(t2), [CVar(st_apply), CCons(CVar("x"), CNil)]) =
    ok_body
  assert t2 == t
  assert st_apply == st
}

/// `ReturnCallImport(0, [i32]->[i32], [x])` routes through the EXISTING import path under `KReturn`:
/// it reads the closure from `func_import_at(0)`, applies `link.call_import`, and re-packages the
/// value LIST under a BOUNDED `let` frame (value-correct, NOT a bare tail apply — the honest Q8
/// sub-case). No `link` tail variant is emitted.
pub fn import_return_call_routes_through_import_path_test() {
  let ty = ir.FuncType([ir.TI32], [ir.TI32])
  let f =
    ir.Function(
      "f",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.ReturnCallImport(0, ty, [ir.Var("x")]),
    )
  let m = hand_module("import", [ir.ImportFn("env", "host", ty)], [f], [], [])
  // reads `func_import_at(0)`, then `link:call_import(Closure, [x])` inside a `let` (the bounded
  // list→package re-package frame) — NOT a bare tail `apply`, NOT the indirect lookup seam.
  let assert CLet(
    [_cvar],
    CCall(CAtom(_state), CAtom("func_import_at"), [CInt(0)]),
    CLet(
      [_lvar],
      CCall(
        CAtom(lmod),
        CAtom("call_import"),
        [CVar(_c2), CCons(CVar("x"), CNil)],
      ),
      _repackage,
    ),
  ) = body_of(m, binding(), "f")
  // the linker seam is the FROZEN `call_import` — no tail variant, no `link` change this phase.
  assert lmod == "twocore@runtime@link"
}

// ══════════════════════════ BEHAVIORAL — the constant-stack property ══════════════════════════

/// A pure accumulator `count(n, acc) = if n == 0 then acc else count(n-1, acc+1)` written with
/// `return_call`. `count(1_000_000, 0) == 1_000_000` — it RUNS: a genuine tail call is constant
/// space, whereas a wrapped/non-tail emission would exhaust the process at this depth.
pub fn direct_return_call_is_constant_stack_e2e_test() {
  let mod = load(hand_module("count", [], [count_fn()], [], []), binding())
  assert catch_apply(mod, atom.create("count"), [10, 0]) == Ok(10)
  assert catch_apply(mod, atom.create("count"), [1_000_000, 0]) == Ok(1_000_000)
}

/// The SAME accumulator, but the self-recursion goes through a table slot via
/// `return_call_indirect` (slot 0 holds `count_i` itself, via a `ref.func` element segment).
/// `count_i(1_000_000, 0) == 1_000_000` in constant space — the deep-indirect constant-stack proof
/// (overview open seam #3): the `call_indirect_lookup` + tail-apply seam is genuinely tail, not just
/// structurally shaped.
pub fn indirect_return_call_is_constant_stack_e2e_test() {
  let mod =
    load(
      hand_module(
        "count_i",
        [],
        [count_i_fn()],
        [ir.TableDecl("t0", ir.FuncRef, 1, option.None)],
        [
          ir.ElementSegment(
            ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
            ir.FuncRef,
            [ir.RefFunc("count_i")],
          ),
        ],
      ),
      binding(),
    )
  instantiate(mod)
  assert catch_apply(mod, atom.create("count_i"), [10, 0]) == Ok(10)
  assert catch_apply(mod, atom.create("count_i"), [1_000_000, 0])
    == Ok(1_000_000)
}

/// Even/odd mutual recursion via `return_call` — the value-shape invariant across a MIXED function
/// (one arm a normal `Return`, one arm a `return_call`): if the tail arm returned a list where the
/// normal arm returns a bare value, the two would disagree. `is_even(1_000_000) == 1` (even) and
/// `is_even(999_999) == 0` (odd) prove the shapes agree AND the mutual loop is constant space.
pub fn mutual_even_odd_return_call_is_constant_stack_e2e_test() {
  let mod =
    load(
      hand_module("evenodd", [], [is_even_fn(), is_odd_fn()], [], []),
      binding(),
    )
  assert catch_apply(mod, atom.create("is_even"), [1_000_000]) == Ok(1)
  assert catch_apply(mod, atom.create("is_even"), [999_999]) == Ok(0)
  assert catch_apply(mod, atom.create("is_odd"), [7]) == Ok(1)
}

/// The three `return_call_indirect` fail-closed traps fire IN ORDER — identical to `call_indirect`
/// (bounds → null → type). Proves the tail emission wires the error-arm `raise` and preserves the
/// guard order end to end.
pub fn indirect_return_call_traps_fire_in_order_e2e_test() {
  let inc =
    ir.Function(
      "inc",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.Let(
        ["r"],
        ir.Num(ir.IAdd(ir.W32), [ir.Var("x"), ir.ConstI32(1)]),
        ir.Return([ir.Var("r")]),
      ),
    )
  let callfn =
    ir.Function(
      "callfn",
      [ir.Local("idx", ir.TI32)],
      [ir.TI32],
      [],
      ir.ReturnCallIndirect(
        "t0",
        ir.Var("idx"),
        ir.FuncType([ir.TI32], [ir.TI32]),
        [ir.ConstI32(41)],
      ),
    )
  let callwrong =
    ir.Function(
      "callwrong",
      [ir.Local("idx", ir.TI32)],
      [ir.TI64],
      [],
      ir.ReturnCallIndirect(
        "t0",
        ir.Var("idx"),
        ir.FuncType([ir.TI64], [ir.TI64]),
        [ir.ConstI64(0)],
      ),
    )
  let mod =
    load(
      hand_module(
        "ci_tail",
        [],
        [inc, callfn, callwrong],
        [ir.TableDecl("t0", ir.FuncRef, 4, option.None)],
        [
          ir.ElementSegment(
            ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
            ir.FuncRef,
            [ir.RefFunc("inc")],
          ),
        ],
      ),
      binding(),
    )
  instantiate(mod)
  // slot 0 = inc [i32]->[i32]: the tail dispatch runs and returns inc(41) = 42.
  assert catch_apply(mod, atom.create("callfn"), [0]) == Ok(42)
  // guard 1 — index past the bound.
  let assert Error(undef) = catch_apply(mod, atom.create("callfn"), [10])
  assert string.contains(undef, "undefined_element")
  // guard 2 — in-bounds but null (uninitialised) slot.
  let assert Error(uninit) = catch_apply(mod, atom.create("callfn"), [2])
  assert string.contains(uninit, "uninitialized_element")
  // guard 3 — right slot, wrong expected type.
  let assert Error(mismatch) = catch_apply(mod, atom.create("callwrong"), [0])
  assert string.contains(mismatch, "indirect_call_type_mismatch")
}

/// An imported `return_call` is VALUE-CORRECT (the list→package re-package under `KReturn` is
/// faithful). Per Q8 this is value-correctness with a BOUNDED frame — NOT a constant-stack claim —
/// so it is asserted at small depth. `caller(41) == 42` computed ACROSS instances.
pub fn imported_return_call_is_value_correct_e2e_test() {
  let ty = ir.FuncType([ir.TI32], [ir.TI32])
  // Module A: pure `add1(x) = x + 1`.
  let mod_a =
    load(
      hand_module(
        "modA_tc",
        [],
        [
          ir.Function(
            "add1",
            [ir.Local("x", ir.TI32)],
            [ir.TI32],
            [],
            ir.Let(
              ["r"],
              ir.Num(ir.IAdd(ir.W32), [ir.Var("x"), ir.ConstI32(1)]),
              ir.Return([ir.Var("r")]),
            ),
          ),
        ],
        [],
        [],
      ),
      binding(),
    )
  let closure = fn(args: List(Dynamic)) -> List(Dynamic) {
    [apply3(mod_a, atom.create("add1"), args)]
  }
  let provided = link.provided_func(ty, closure)
  // Module B: `caller(x) = return_call_import add1(x)`.
  let mod_b =
    load(
      hand_module(
        "modB_tc",
        [ir.ImportFn("modA", "add1", ty)],
        [
          ir.Function(
            "caller",
            [ir.Local("x", ir.TI32)],
            [ir.TI32],
            [],
            ir.ReturnCallImport(0, ty, [ir.Var("x")]),
          ),
        ],
        [],
        [],
      ),
      binding(),
    )
  let assert Ok(_) =
    catch_apply_dyn(mod_b, atom.create("instantiate"), [to_dynamic([provided])])
  assert catch_apply(mod_b, atom.create("caller"), [41]) == Ok(42)
  assert catch_apply(mod_b, atom.create("caller"), [100]) == Ok(101)
}

// ══════════════════════════ the Aggressive-inliner interaction ══════════════════════════

/// A `return_call` even/odd program with a `run(n) = CallDirect(is_even, [n])` entry, compiled under
/// the AGGRESSIVE optimizer, computes the right parity — proving the inliner does NOT inline a
/// tail-call-containing callee (`is_even` looks non-recursive to the `CallDirect`-only recursion
/// detector, and would corrupt if inlined). `OptNone ≡ Baseline ≡ Aggressive` at every level.
pub fn even_odd_return_call_under_aggressive_e2e_test() {
  let run =
    ir.Function(
      "run",
      [ir.Local("n", ir.TI32)],
      [ir.TI32],
      [],
      ir.Let(
        ["r"],
        ir.CallDirect("is_even", [ir.Var("n")]),
        ir.Return([ir.Var("r")]),
      ),
    )
  let m =
    hand_module("agg_evenodd", [], [run, is_even32_fn(), is_odd32_fn()], [], [])
  // Same correct answers at every optimization level (the differential proves the inliner fix).
  let check = fn(level) {
    let mod = load(ir_opt.optimize(m, level), binding())
    assert catch_apply(mod, atom.create("run"), [1000]) == Ok(1)
    assert catch_apply(mod, atom.create("run"), [1001]) == Ok(0)
    // still constant space after aggressive rewriting.
    assert catch_apply(mod, atom.create("run"), [200_000]) == Ok(1)
  }
  check(OptNone)
  check(Baseline)
  check(Aggressive)
}

// ── IR fixtures for the behavioral tests ────────────────────────────────────────────

/// `count(n, acc) = if n <= 0 then Return[acc] else return_call count(n-1, acc+1)` (i64).
fn count_fn() -> ir.Function {
  ir.Function(
    "count",
    [ir.Local("n", ir.TI64), ir.Local("acc", ir.TI64)],
    [ir.TI64],
    [],
    countdown_body(fn(n1, acc1) { ir.ReturnCall("count", [n1, acc1]) }),
  )
}

/// `count_i` — the accumulator whose self-recursion is a `return_call_indirect` through table slot 0.
fn count_i_fn() -> ir.Function {
  ir.Function(
    "count_i",
    [ir.Local("n", ir.TI64), ir.Local("acc", ir.TI64)],
    [ir.TI64],
    [],
    countdown_body(fn(n1, acc1) {
      ir.ReturnCallIndirect(
        "t0",
        ir.ConstI32(0),
        ir.FuncType([ir.TI64, ir.TI64], [ir.TI64]),
        [n1, acc1],
      )
    }),
  )
}

/// The shared countdown body: `if n <= 0 then Return[acc] else <tail>(n-1, acc+1)`, where `tail`
/// builds the recursive tail transfer from the decremented `n1` and incremented `acc1` values.
fn countdown_body(tail: fn(ir.Value, ir.Value) -> ir.Expr) -> ir.Expr {
  ir.Let(
    ["z"],
    ir.Num(ir.ILeU(ir.W64), [ir.Var("n"), ir.ConstI64(0)]),
    ir.If(
      cond: ir.Var("z"),
      result: [ir.TI64],
      then_branch: ir.Return([ir.Var("acc")]),
      else_branch: ir.Let(
        ["n1"],
        ir.Num(ir.ISub(ir.W64), [ir.Var("n"), ir.ConstI64(1)]),
        ir.Let(
          ["acc1"],
          ir.Num(ir.IAdd(ir.W64), [ir.Var("acc"), ir.ConstI64(1)]),
          tail(ir.Var("n1"), ir.Var("acc1")),
        ),
      ),
    ),
  )
}

/// `is_even(n) = if n <= 0 then Return[1] else return_call is_odd(n-1)` (i64).
fn is_even_fn() -> ir.Function {
  parity_fn("is_even", "is_odd", 1)
}

/// `is_odd(n) = if n <= 0 then Return[0] else return_call is_even(n-1)` (i64).
fn is_odd_fn() -> ir.Function {
  parity_fn("is_odd", "is_even", 0)
}

fn parity_fn(name: String, other: String, base: Int) -> ir.Function {
  ir.Function(
    name,
    [ir.Local("n", ir.TI64)],
    [ir.TI64],
    [],
    ir.Let(
      ["z"],
      ir.Num(ir.ILeU(ir.W64), [ir.Var("n"), ir.ConstI64(0)]),
      ir.If(
        cond: ir.Var("z"),
        result: [ir.TI64],
        then_branch: ir.Return([ir.ConstI64(base)]),
        else_branch: ir.Let(
          ["n1"],
          ir.Num(ir.ISub(ir.W64), [ir.Var("n"), ir.ConstI64(1)]),
          ir.ReturnCall(other, [ir.Var("n1")]),
        ),
      ),
    ),
  )
}

/// i32 parity fns for the Aggressive test (`run` returns i32).
fn is_even32_fn() -> ir.Function {
  parity32_fn("is_even", "is_odd", 1)
}

fn is_odd32_fn() -> ir.Function {
  parity32_fn("is_odd", "is_even", 0)
}

fn parity32_fn(name: String, other: String, base: Int) -> ir.Function {
  ir.Function(
    name,
    [ir.Local("n", ir.TI32)],
    [ir.TI32],
    [],
    ir.Let(
      ["z"],
      ir.Num(ir.ILeU(ir.W32), [ir.Var("n"), ir.ConstI32(0)]),
      ir.If(
        cond: ir.Var("z"),
        result: [ir.TI32],
        then_branch: ir.Return([ir.ConstI32(base)]),
        else_branch: ir.Let(
          ["n1"],
          ir.Num(ir.ISub(ir.W32), [ir.Var("n"), ir.ConstI32(1)]),
          ir.ReturnCall(other, [ir.Var("n1")]),
        ),
      ),
    ),
  )
}
