//// Unit 08 — `emit_core` boundary tests.
////
//// These assert the IR→`.core` lowering against the high-level §5 mapping / the unit-08
//// doc's per-construct table and the two VERIFIED grounded facts — NOT against "whatever
//// the code currently emits" (no change-detector goldens). Each test pattern-matches the
//// emitted `core_erlang` AST and asserts the structural shape the spec/doc requires:
//// a `Loop` is a `letrec` whose body tail-applies the loop head; an `If` is a `case`
//// matching the i32 condition with `when 'true'` on every clause; a trapping `Num` is the
//// `{ok,_}`/`{error,_}`-`case`-and-`raise`; `Trap`/`CallHost`/`Charge` route through the
//// fixed `Binding` modules; and the `NumOp → rt_num` name table actually names functions
//// `rt_num` exports.

import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import twocore/backend/core_erlang.{
  type CExpr, CApply, CAtom, CBinary, CCall, CCase, CClause, CCons, CFun, CInt,
  CLet, CLetrec, CNil, CTuple, CValues, CVar, FName, FunDef, PAtom, PCons, PInt,
  PNil, PTuple, PVar,
}
import twocore/backend/emit_core
import twocore/ir
import twocore/runtime/instance
import twocore/runtime/rt_num

// `erlang:function_exported/3` — True iff `Module:Function/Arity` is a loaded export. Used
// to tie the `NumOp → rt_num` name table and the Gleam→Erlang mangling to the real
// artefact (verified fact 1): a mangling/name drift makes the export vanish and fails here.
@external(erlang, "erlang", "function_exported")
fn function_exported(module: Atom, function: Atom, arity: Int) -> Bool

// ───────────────────────────── helpers ─────────────────────────────

/// The Phase-1 Safe binding (the fixed `twocore@runtime@*` module table).
fn binding() -> instance.Binding {
  instance.safe_default()
}

/// Wrap a single function in a numerics-on, memory-off module exporting it by its own name.
fn module_with(f: ir.Function) -> ir.Module {
  ir.Module(
    name: "twocore@test@" <> f.name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [f],
    exports: [ir.ExportFn(f.name, f.name)],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// Emit `module` and return the Core body expression of function `name`.
fn body_of(module: ir.Module, name: String) -> CExpr {
  let assert Ok(m) = emit_core.emit_module(module, binding())
  let assert Ok(FunDef(_, CFun(_, body))) =
    list.find(m.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == name
    })
  body
}

/// True iff `e` (recursively) contains an `apply` of the function atom `name`.
fn applies_to(e: CExpr, name: String) -> Bool {
  case e {
    CApply(FName(n, _), args) ->
      n == name || list.any(args, applies_to(_, name))
    CCall(m, f, args) ->
      applies_to(m, name)
      || applies_to(f, name)
      || list.any(args, applies_to(_, name))
    CLet(_, arg, body) -> applies_to(arg, name) || applies_to(body, name)
    CLetrec(defs, body) ->
      list.any(defs, fn(d) {
        let FunDef(_, v) = d
        applies_to(v, name)
      })
      || applies_to(body, name)
    CCase(arg, clauses) ->
      applies_to(arg, name)
      || list.any(clauses, fn(c) {
        let CClause(_, g, b) = c
        applies_to(g, name) || applies_to(b, name)
      })
    CFun(_, b) -> applies_to(b, name)
    CCons(h, t) -> applies_to(h, name) || applies_to(t, name)
    CTuple(xs) -> list.any(xs, applies_to(_, name))
    _ -> False
  }
}

// ───────────────────────────── Let / Return / Num (add) ─────────────────────────────

fn add_fn() -> ir.Function {
  ir.Function(
    name: "add",
    params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.Num(ir.IAdd(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// `Let(names, rhs, body)` → `let <names> = <rhs> in <body>`; `Num(IAdd(W32))` routes
/// through `num_module:i32_add`; tail `Return([r])` is the bare value (a 1-value list).
pub fn let_num_return_test() {
  let b = binding()
  let assert CLet(
    ["r"],
    CCall(CAtom(num), CAtom("i32_add"), [CVar("p0"), CVar("p1")]),
    CVar("r"),
  ) = body_of(module_with(add_fn()), "add")
  assert num == b.num_module
}

// ───────────────────────────── If → case on i32 ─────────────────────────────

fn if_fn() -> ir.Function {
  ir.Function(
    name: "pick",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.If(
      cond: ir.Var("p0"),
      result: [ir.TI32],
      then_branch: ir.Return([ir.ConstI32(1)]),
      else_branch: ir.Return([ir.ConstI32(0)]),
    ),
  )
}

/// `If(cond, _, t, e)` → `case Cond of <0> -> e; <_> -> t end`, every clause guarded by
/// `when 'true'`. (cond is an i32 truth value; matching `0` = false → else, else → then.)
pub fn if_to_case_test() {
  let assert CCase(
    CVar("p0"),
    [
      CClause([PInt(0)], CAtom("true"), CInt(0)),
      CClause([PVar(_)], CAtom("true"), CInt(1)),
    ],
  ) = body_of(module_with(if_fn()), "pick")
}

// ───────────────────────────── Loop + Continue + Break (sum_to) ─────────────────────────────

fn sum_to_fn() -> ir.Function {
  ir.Function(
    name: "sum_to",
    params: [ir.Local("p0", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Loop(
      label: "go",
      params: [
        ir.LoopParam("i", ir.TI64, ir.ConstI64(1)),
        ir.LoopParam("acc", ir.TI64, ir.ConstI64(0)),
      ],
      result: [ir.TI64],
      body: ir.Let(
        ["cond"],
        ir.Num(ir.ILeU(ir.W64), [ir.Var("i"), ir.Var("p0")]),
        ir.If(
          cond: ir.Var("cond"),
          result: [ir.TI64],
          then_branch: ir.Let(
            ["acc1"],
            ir.Num(ir.IAdd(ir.W64), [ir.Var("acc"), ir.Var("i")]),
            ir.Let(
              ["i1"],
              ir.Num(ir.IAdd(ir.W64), [ir.Var("i"), ir.ConstI64(1)]),
              ir.Continue("go", [ir.Var("i1"), ir.Var("acc1")]),
            ),
          ),
          else_branch: ir.Break("go", [ir.Var("acc")]),
        ),
      ),
    ),
  )
}

/// `Loop` → the verified §5 template: `letrec 'L'/arity = fun(params…) -> <body>` applied
/// to the inits; `Continue` is a tail `apply 'L'` (the back-edge → constant space); the
/// fall-through/`Break` exit (here, in tail position) yields the bare value list.
pub fn loop_is_tail_recursive_letrec_test() {
  let assert CLetrec(
    [FunDef(FName(lname, 2), CFun(["i", "acc"], lbody))],
    CApply(FName(entry, 2), [CInt(1), CInt(0)]),
  ) = body_of(module_with(sum_to_fn()), "sum_to")
  // The letrec head is what `apply` enters.
  assert entry == lname
  // The body's `continue` is a tail self-apply of the same head → constant space.
  assert applies_to(lbody, lname)
  // The body computes the loop condition, then `case`s on it: `<0>` (false) breaks with the
  // bare accumulator (no join point, since the exit is in tail position / KReturn).
  let assert CLet(
    ["cond"],
    CCall(_, CAtom("i64_le_u"), _),
    CCase(
      CVar("cond"),
      [
        CClause([PInt(0)], CAtom("true"), CVar("acc")),
        CClause([PVar(_)], CAtom("true"), _),
      ],
    ),
  ) = lbody
}

// ───────────────────────────── Block + Break → forward join point ─────────────────────────────

fn block_fn() -> ir.Function {
  ir.Function(
    name: "blk",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    // bind the block result so the continuation is non-trivial → materialised join point.
    body: ir.Let(
      ["x"],
      ir.Block("b", [ir.TI32], ir.Break("b", [ir.Var("p0")])),
      ir.Return([ir.Var("x")]),
    ),
  )
}

/// `Block(label, _, body)` → a forward continuation: the code after the block becomes a
/// `letrec` join point, and `Break(label, vs)` tail-applies it.
pub fn block_break_is_join_point_test() {
  let assert CLetrec(
    [FunDef(FName(jname, 1), CFun(["x"], CVar("x")))],
    CApply(FName(target, 1), [CVar("p0")]),
  ) = body_of(module_with(block_fn()), "blk")
  assert target == jname
}

// ───────────────────────────── Switch → case + default ─────────────────────────────

fn switch_fn() -> ir.Function {
  ir.Function(
    name: "sw",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Switch(
      selector: ir.Var("p0"),
      result: [ir.TI32],
      arms: [
        ir.SwitchArm(0, ir.Return([ir.ConstI32(10)])),
        ir.SwitchArm(1, ir.Return([ir.ConstI32(11)])),
      ],
      default: ir.Return([ir.ConstI32(99)]),
    ),
  )
}

/// `Switch(sel, _, arms, default)` → `case Sel of` one `<match>` clause per arm and a
/// trailing wildcard default clause; every clause guarded by `when 'true'`.
pub fn switch_to_case_test() {
  let assert CCase(
    CVar("p0"),
    [
      CClause([PInt(0)], CAtom("true"), CInt(10)),
      CClause([PInt(1)], CAtom("true"), CInt(11)),
      CClause([PVar(_)], CAtom("true"), CInt(99)),
    ],
  ) = body_of(module_with(switch_fn()), "sw")
}

// ───────────────────────────── CallDirect → apply ─────────────────────────────

fn call_direct_fn() -> ir.Function {
  ir.Function(
    name: "rec",
    params: [ir.Local("p0", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.CallDirect("rec", [ir.Var("p0")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// `CallDirect(fn, args)` → `apply 'fn'/arity(args)` of the program's own static function
/// name (D3a-safe — an `apply`, never a runtime `call` of program data).
pub fn call_direct_to_apply_test() {
  let assert CLet(["r"], CApply(FName("rec", 1), [CVar("p0")]), CVar("r")) =
    body_of(module_with(call_direct_fn()), "rec")
}

// ───────────────────────────── CallHost — two fates ─────────────────────────────

fn host_import_fn() -> ir.Function {
  ir.Function(
    name: "useimport",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.CallHost("env", "log", [ir.Var("p0")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// A genuine host import → `call '<host_module>':'call_host'(Cap, Name, [Args…])`. `Cap`/`Name`
/// are emitted as BINARY STRINGS — the exact type `rt_host.call_host` consumes — so its
/// `resolve_handler`/`HostWhitelist` `String` pattern-matching actually fires under a permissive
/// posture (F4). Emitting them as atoms would silently deny every handler (an atom never matches
/// a `String` pattern), so this asserts the representation, not just the call shape. Args are a
/// proper Core list.
pub fn call_host_import_is_deny_all_test() {
  let b = binding()
  let assert CLet(
    ["r"],
    CCall(
      CAtom(host),
      CAtom("call_host"),
      [CBinary(_), CBinary(_), CCons(CVar("p0"), CNil)],
    ),
    CVar("r"),
  ) = body_of(module_with(host_import_fn()), "useimport")
  assert host == b.host_module
}

fn stdlib_fn() -> ir.Function {
  ir.Function(
    name: "g",
    params: [ir.Local("p0", ir.TI64), ir.Local("p1", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.CallHost("std", "gcd", [ir.Var("p0"), ir.Var("p1")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// A resolved `own`-stdlib triple (`("std","gcd")`) → a DIRECT
/// `call '<stdlib_module>':'gcd'(Args…)` (args spread; does not pass through the host).
pub fn call_host_stdlib_is_direct_test() {
  let b = binding()
  let assert CLet(
    ["r"],
    CCall(CAtom(std), CAtom("gcd"), [CVar("p0"), CVar("p1")]),
    CVar("r"),
  ) = body_of(module_with(stdlib_fn()), "g")
  assert std == b.stdlib_module
}

// ───────────────────────────── Trap → raise ─────────────────────────────

fn trap_fn() -> ir.Function {
  ir.Function(
    name: "boom",
    params: [],
    result: [ir.TI32],
    locals: [],
    body: ir.Trap(ir.Unreachable),
  )
}

/// `Trap(reason)` → `call '<trap_module>':'raise'(<snake_atom>)`.
pub fn trap_to_raise_test() {
  let b = binding()
  let assert CCall(CAtom(trap), CAtom("raise"), [CAtom("unreachable")]) =
    body_of(module_with(trap_fn()), "boom")
  assert trap == b.trap_module
}

// ───────────────────────────── trapping Num → case + raise ─────────────────────────────

fn div_fn() -> ir.Function {
  ir.Function(
    name: "d",
    params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Let(
      ["q"],
      ir.Num(ir.IDivS(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
      ir.Return([ir.Var("q")]),
    ),
  )
}

/// A trapping `Num` (`IDivS`) → `let <R> = case call '<num>':'i32_div_s'(A,B) of
/// <{'ok',X}> -> X <{'error',E}> -> call '<trap>':'raise'(E) end in …` — the
/// Result-`case`-and-`raise` shape, reduced to ONE bound value and threaded on.
///
/// Both `case` arms yield exactly one value (the unwrapped `X`, or the never-returning
/// `raise`), so the shape is arity-correct in *any* surrounding context — including a
/// 0-result function, where inlining the continuation into only the `ok` arm would make
/// the two arms disagree on value-list arity (a Core "return count mismatch").
pub fn trapping_num_is_case_and_raise_test() {
  let b = binding()
  let assert CLet(
    [_r],
    CCase(
      CCall(CAtom(num), CAtom("i32_div_s"), [CVar("p0"), CVar("p1")]),
      [
        CClause([PTuple([PAtom("ok"), PVar(x)])], CAtom("true"), CVar(x2)),
        CClause(
          [PTuple([PAtom("error"), PVar(e)])],
          CAtom("true"),
          CCall(CAtom(trap), CAtom("raise"), [CVar(e2)]),
        ),
      ],
    ),
    _threaded,
  ) = body_of(module_with(div_fn()), "d")
  assert num == b.num_module
  assert trap == b.trap_module
  // the `{'ok', X}` arm yields exactly the matched value X (the unwrapped result).
  assert x == x2
  // the raised payload is exactly the matched `{'error', E}` value.
  assert e == e2
}

// ───────────────────────────── Charge → metering seam ─────────────────────────────

fn charge_fn() -> ir.Function {
  ir.Function(
    name: "metered",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Charge(7, ir.Return([ir.Var("p0")])),
  )
}

/// `Charge(cost, body)` → `let _ = call '<meter_module>':'charge'(Cost) in <body>` (the
/// seam exists; the impl is unit 09's fuel counter).
pub fn charge_is_metering_seam_test() {
  let b = binding()
  let assert CLet(
    [_],
    CCall(CAtom(meter), CAtom("charge"), [CInt(7)]),
    CVar("p0"),
  ) = body_of(module_with(charge_fn()), "metered")
  assert meter == b.meter_module
}

// ───────────────────────────── Gleam→Erlang mangling golden (fact 1) ─────────────────────────────

/// VERIFIED fact 1: the Gleam module `twocore/runtime/rt_num` compiles to Erlang module
/// `twocore@runtime@rt_num` and exports `i32_add/2`. The `Binding` already carries that
/// mangled name, and `emit_core` emits it verbatim — so a future Gleam mangling change
/// that breaks this assertion would be caught here BEFORE it silently poisons codegen.
pub fn gleam_mangling_golden_test() {
  // Force the module to be loaded so `function_exported` can see it.
  assert rt_num.i32_add(40, 2) == 42
  assert instance.safe_default().num_module == "twocore@runtime@rt_num"
  assert function_exported(
      atom.create("twocore@runtime@rt_num"),
      atom.create("i32_add"),
      2,
    )
    == True
}

/// VERIFIED fact 2: the PascalCase→snake_case wrapper (the spelling Gleam gives a 0-field
/// constructor's runtime atom). A wrong spelling here produces a `raise`/`case` that never
/// matches and fails silently at run time, so it is pinned with a golden.
pub fn pascal_to_snake_golden_test() {
  assert emit_core.pascal_to_snake("IntDivByZero") == "int_div_by_zero"
  assert emit_core.pascal_to_snake("IntOverflow") == "int_overflow"
  assert emit_core.pascal_to_snake("Unreachable") == "unreachable"
  assert emit_core.pascal_to_snake("MemoryOutOfBounds")
    == "memory_out_of_bounds"
  assert emit_core.pascal_to_snake("IndirectCallTypeMismatch")
    == "indirect_call_type_mismatch"
}

/// `trap_reason_atom` maps every `TrapReason` to the atom `rt_trap:raise/1` receives.
pub fn trap_reason_atom_golden_test() {
  assert emit_core.trap_reason_atom(ir.IntDivByZero) == "int_div_by_zero"
  assert emit_core.trap_reason_atom(ir.IntOverflow) == "int_overflow"
  assert emit_core.trap_reason_atom(ir.Unreachable) == "unreachable"
  assert emit_core.trap_reason_atom(ir.IndirectCallTypeMismatch)
    == "indirect_call_type_mismatch"
  assert emit_core.trap_reason_atom(ir.MemoryOutOfBounds)
    == "memory_out_of_bounds"
  // Phase-3 runtime-only policy reason (F5): its atom is `fuel_exhausted`.
  assert emit_core.trap_reason_atom(ir.FuelExhausted) == "fuel_exhausted"
}

// ───────────────────────────── NumOp → rt_num name table (tied to rt_num) ─────────────────────────────

/// Every `NumOp` name `emit_core` emits MUST name a function `rt_num` actually exports
/// (with the right arity). This ties the chokepoint table objectively to the frozen
/// `rt_num` signatures (the spec for this seam), not to the emitter's own output: a
/// spelling drift on either side fails here.
pub fn num_op_name_matches_rt_num_test() {
  // Force `rt_num` loaded.
  assert rt_num.i32_add(1, 1) == 2
  let m = atom.create("twocore@runtime@rt_num")
  // #(op, arity) — a representative spread covering binary, unary, trapping, i64, floats.
  let cases = [
    #(ir.IAdd(ir.W32), 2),
    #(ir.ISub(ir.W64), 2),
    #(ir.IMul(ir.W32), 2),
    #(ir.IDivS(ir.W32), 2),
    #(ir.IDivU(ir.W64), 2),
    #(ir.IRemS(ir.W32), 2),
    #(ir.IRemU(ir.W64), 2),
    #(ir.IAnd(ir.W32), 2),
    #(ir.IOr(ir.W64), 2),
    #(ir.IXor(ir.W32), 2),
    #(ir.IShl(ir.W32), 2),
    #(ir.IShrS(ir.W64), 2),
    #(ir.IShrU(ir.W64), 2),
    #(ir.IRotl(ir.W32), 2),
    #(ir.IRotr(ir.W64), 2),
    #(ir.IClz(ir.W32), 1),
    #(ir.ICtz(ir.W64), 1),
    #(ir.IPopcnt(ir.W32), 1),
    #(ir.IEqz(ir.W64), 1),
    #(ir.IEq(ir.W32), 2),
    #(ir.INe(ir.W64), 2),
    #(ir.ILtS(ir.W32), 2),
    #(ir.ILtU(ir.W64), 2),
    #(ir.IGtS(ir.W32), 2),
    #(ir.IGtU(ir.W64), 2),
    #(ir.ILeS(ir.W32), 2),
    #(ir.ILeU(ir.W64), 2),
    #(ir.IGeS(ir.W32), 2),
    #(ir.IGeU(ir.W64), 2),
    #(ir.FAdd(ir.FW32), 2),
    #(ir.FSub(ir.FW64), 2),
    #(ir.FMul(ir.FW32), 2),
    #(ir.FDiv(ir.FW64), 2),
    #(ir.FMin(ir.FW32), 2),
    #(ir.FMax(ir.FW64), 2),
  ]
  list.each(cases, fn(c) {
    let #(op, arity) = c
    assert function_exported(m, atom.create(emit_core.num_op_name(op)), arity)
      == True
  })
}

// ───────────────────────────── Phase-2 stateful-op goldens (the seam) ─────────────────────────────

/// Build a single-function module whose body is exactly `body` (tail position), with the
/// given params/result, exported by name. Lets the stateful-op shape be asserted directly.
fn op_module(
  name: String,
  params: List(ir.Local),
  result: List(ir.ValType),
  body: ir.Expr,
) -> ir.Module {
  module_with(ir.Function(
    name: name,
    params: params,
    result: result,
    locals: [],
    body: body,
  ))
}

/// `MemSize` → a bare `call '<mem_module>':'size'()` (an i32; no trap).
pub fn mem_size_is_bare_call_test() {
  let b = binding()
  let assert CCall(CAtom(mem), CAtom("size"), []) =
    body_of(op_module("f", [], [ir.TI32], ir.MemSize(0)), "f")
  assert mem == b.mem_module
}

/// `MemGrow(delta)` → a bare `call '<mem_module>':'grow'(Delta)` (i32; effectful).
pub fn mem_grow_is_bare_call_test() {
  let b = binding()
  let assert CCall(CAtom(mem), CAtom("grow"), [CVar("d")]) =
    body_of(
      op_module(
        "f",
        [ir.Local("d", ir.TI32)],
        [ir.TI32],
        ir.MemGrow(0, ir.Var("d")),
      ),
      "f",
    )
  assert mem == b.mem_module
}

/// `MemLoad(MemAccess(bytes,signed), addr, off, result)` → a trapping `Result`: a `case`
/// over `call '<mem_module>':'load'(Bytes, Signed, ResultWidth, Addr, Off)` raising on
/// `{error,_}`. `i32.load8_s` walks to `Signed='true'` + `ResultWidth=32`.
pub fn mem_load_is_trapping_case_test() {
  let b = binding()
  let assert CLet(
    [r],
    CCase(
      CCall(
        CAtom(mem),
        CAtom("load"),
        [CInt(1), CAtom("true"), CInt(32), CVar("a"), CInt(8)],
      ),
      [
        CClause([PTuple([PAtom("ok"), PVar(x)])], CAtom("true"), CVar(x2)),
        CClause(
          [PTuple([PAtom("error"), PVar(e)])],
          CAtom("true"),
          CCall(CAtom(trap), CAtom("raise"), [CVar(e2)]),
        ),
      ],
    ),
    CVar(r2),
  ) =
    body_of(
      op_module(
        "f",
        [ir.Local("a", ir.TI32)],
        [ir.TI32],
        ir.MemLoad(0, ir.MemAccess(1, True), ir.Var("a"), 8, ir.TI32),
      ),
      "f",
    )
  assert mem == b.mem_module
  assert trap == b.trap_module
  assert x == x2
  assert e == e2
  assert r == r2
}

/// `i64.load8_s` differs from `i32.load8_s` ONLY in the emitted `ResultWidth` (64 vs 32) —
/// same `bytes`+`signed` — confirming `result` disambiguates the sign-extension width (E2).
pub fn mem_load_result_width_disambiguates_test() {
  let assert CLet(_, CCase(CCall(_, _, [_, _, CInt(w32), ..]), _), _) =
    body_of(
      op_module(
        "f",
        [ir.Local("a", ir.TI32)],
        [ir.TI32],
        ir.MemLoad(0, ir.MemAccess(1, True), ir.Var("a"), 0, ir.TI32),
      ),
      "f",
    )
  let assert CLet(_, CCase(CCall(_, _, [_, _, CInt(w64), ..]), _), _) =
    body_of(
      op_module(
        "f",
        [ir.Local("a", ir.TI32)],
        [ir.TI64],
        ir.MemLoad(0, ir.MemAccess(1, True), ir.Var("a"), 0, ir.TI64),
      ),
      "f",
    )
  assert w32 == 32
  assert w64 == 64
}

/// `MemStore` → a ZERO-RESULT ordered effect: `let <_> = <case over
/// call '<mem_module>':'store'(Bytes, Addr, Val, Off)> in <rest>`, the `case` reduced to a
/// single discardable value (`{ok,_}`→`'ok'`, `{error,E}`→`raise`). The store sequences
/// before the rest (non-DCE) with eval order addr → value → store.
pub fn mem_store_is_ordered_effect_test() {
  let b = binding()
  let assert CLet(
    [_g],
    CCase(
      CCall(
        CAtom(mem),
        CAtom("store"),
        [CInt(4), CVar("a"), CVar("v"), CInt(0)],
      ),
      [
        CClause([PTuple([PAtom("ok"), PVar(_)])], CAtom("true"), CAtom("ok")),
        CClause(
          [PTuple([PAtom("error"), PVar(e)])],
          CAtom("true"),
          CCall(CAtom(trap), CAtom("raise"), [CVar(e2)]),
        ),
      ],
    ),
    CAtom("ok"),
  ) =
    body_of(
      op_module(
        "f",
        [ir.Local("a", ir.TI32), ir.Local("v", ir.TI32)],
        [],
        ir.MemStore(0, ir.MemAccess(4, False), ir.Var("a"), ir.Var("v"), 0),
      ),
      "f",
    )
  assert mem == b.mem_module
  assert trap == b.trap_module
  assert e == e2
}

/// `GlobalGet(name)` → a bare `call '<state_module>':'global_get'(NameBin)` where `NameBin`
/// is a Core binary STRING literal (`<<"g0">>`), not an atom (the frozen `rt_state` head
/// takes a `String`/binary).
pub fn global_get_is_binary_name_call_test() {
  let b = binding()
  let assert CCall(CAtom(state), CAtom("global_get"), [CBinary(_)]) =
    body_of(op_module("f", [], [ir.TI32], ir.GlobalGet("g0")), "f")
  assert state == b.state_module
}

/// `GlobalSet(name, value)` → a ZERO-RESULT ordered effect: `let <_> =
/// call '<state_module>':'global_set'(NameBin, Val) in <rest>` (pure — no trap `case`).
pub fn global_set_is_ordered_effect_test() {
  let b = binding()
  let assert CLet(
    [_g],
    CCall(CAtom(state), CAtom("global_set"), [CBinary(_), CVar("v")]),
    CAtom("ok"),
  ) =
    body_of(
      op_module(
        "f",
        [ir.Local("v", ir.TI32)],
        [],
        ir.GlobalSet("g0", ir.Var("v")),
      ),
      "f",
    )
  assert state == b.state_module
}

/// `CallIndirect(table, index, ty, args)` → a `case` over `call '<table_module>':
/// 'call_indirect'(Idx, TypeTag, ArgList)` raising on `{error,_}`, where `TypeTag` is the
/// compile-time canonical `{[params],[results]}` term and `ArgList` is a proper Core list.
/// The `{ok,V}` result list is then unpacked (here r=1 → `[V]`).
pub fn call_indirect_is_seam_dispatch_test() {
  let b = binding()
  let assert CLet(
    [lv],
    CCase(
      CCall(
        CAtom(table),
        CAtom("call_indirect"),
        [
          CVar("i"),
          CTuple([CCons(CAtom("i32"), CNil), CCons(CAtom("i32"), CNil)]),
          CCons(CVar("x"), CNil),
        ],
      ),
      [
        CClause([PTuple([PAtom("ok"), PVar(_)])], CAtom("true"), CVar(_)),
        CClause(
          [PTuple([PAtom("error"), PVar(_)])],
          CAtom("true"),
          CCall(CAtom(trap), CAtom("raise"), [CVar(_)]),
        ),
      ],
    ),
    CCase(CVar(lv2), [CClause([PCons(PVar(n), PNil)], CAtom("true"), CVar(n2))]),
  ) =
    body_of(
      op_module(
        "f",
        [ir.Local("i", ir.TI32), ir.Local("x", ir.TI32)],
        [ir.TI32],
        ir.CallIndirect("t0", ir.Var("i"), ir.FuncType([ir.TI32], [ir.TI32]), [
          ir.Var("x"),
        ]),
      ),
      "f",
    )
  assert table == b.table_module
  assert trap == b.trap_module
  assert lv == lv2
  assert n == n2
}

/// A TRAPPING `Convert` (`TruncS`) → the `case`-and-`raise` shape over
/// `call '<num_module>':'i32_trunc_f32_s'(A)` (NOT a bare call) — `trunc_f*` traps NaN/±Inf/
/// out-of-range (`exec/numerics`).
pub fn trapping_trunc_is_case_and_raise_test() {
  let b = binding()
  let assert CLet(
    [r],
    CCase(
      CCall(CAtom(num), CAtom("i32_trunc_f32_s"), [CVar("x")]),
      [
        CClause([PTuple([PAtom("ok"), PVar(_)])], CAtom("true"), CVar(_)),
        CClause(
          [PTuple([PAtom("error"), PVar(_)])],
          CAtom("true"),
          CCall(CAtom(_), CAtom("raise"), [CVar(_)]),
        ),
      ],
    ),
    CVar(r2),
  ) =
    body_of(
      op_module(
        "f",
        [ir.Local("x", ir.TF32)],
        [ir.TI32],
        ir.Convert(ir.TruncS(ir.FW32, ir.W32), ir.Var("x")),
      ),
      "f",
    )
  assert num == b.num_module
  assert r == r2
}

/// A TOTAL `Convert` (`ConvertS`/`F32DemoteF64`/`F64PromoteF32`) → a bare `num_module` call
/// (never wrapped in a trap `case` — these conversions never trap).
pub fn total_convert_is_bare_call_test() {
  let b = binding()
  let assert CCall(CAtom(num), CAtom("f32_convert_i32_s"), [CVar("x")]) =
    body_of(
      op_module(
        "f",
        [ir.Local("x", ir.TI32)],
        [ir.TF32],
        ir.Convert(ir.ConvertS(ir.W32, ir.FW32), ir.Var("x")),
      ),
      "f",
    )
  assert num == b.num_module
  let assert CCall(CAtom(_), CAtom("f32_demote_f64"), [CVar("x")]) =
    body_of(
      op_module(
        "f",
        [ir.Local("x", ir.TF64)],
        [ir.TF32],
        ir.Convert(ir.F32DemoteF64, ir.Var("x")),
      ),
      "f",
    )
  let assert CCall(CAtom(_), CAtom("f64_promote_f32"), [CVar("x")]) =
    body_of(
      op_module(
        "f",
        [ir.Local("x", ir.TF32)],
        [ir.TF64],
        ir.Convert(ir.F64PromoteF32, ir.Var("x")),
      ),
      "f",
    )
}

/// A float comparison (`FLt`) → a bare `call '<num_module>':'f32_lt'(A,B)` (an i32 0/1).
pub fn float_compare_is_bare_call_test() {
  let b = binding()
  let assert CCall(CAtom(num), CAtom("f32_lt"), [CVar("a"), CVar("b")]) =
    body_of(
      op_module(
        "f",
        [ir.Local("a", ir.TF32), ir.Local("b", ir.TF32)],
        [ir.TI32],
        ir.Num(ir.FLt(ir.FW32), [ir.Var("a"), ir.Var("b")]),
      ),
      "f",
    )
  assert num == b.num_module
}

// ───────────────────────────── the instantiate/0 entry golden ─────────────────────────────

/// A module exercising the whole instantiation contract: a memory + an active data segment,
/// a table + an active element segment (referencing `elemfn`), a global with a constant
/// init, and a `start` function.
fn full_module() -> ir.Module {
  let elemfn =
    ir.Function(
      name: "elemfn",
      params: [ir.Local("p0", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Return([ir.Var("p0")]),
    )
  let initfn =
    ir.Function(
      name: "init",
      params: [],
      result: [],
      locals: [],
      body: ir.Values([]),
    )
  ir.Module(
    name: "twocore@test@full",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.Some(2), ir.Idx32)],
    globals: [ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(42)]))],
    imports: [],
    functions: [elemfn, initfn],
    exports: [],
    data_segments: [
      ir.DataSegment(ir.DataActive(0, ir.Values([ir.ConstI32(0)])), <<1, 2, 3>>),
    ],
    tables: [ir.TableDecl("t0", ir.FuncRef, 4, option.None)],
    elements: [
      ir.ElementSegment(
        ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
        ir.FuncRef,
        [ir.RefFunc("elemfn")],
      ),
    ],
    start: option.Some("init"),
    tags: [],
  )
}

/// True iff `e` (recursively) contains a `call '<module>':'<fn>'(…)`.
fn contains_call(e: CExpr, module: String, fun: String) -> Bool {
  case e {
    CCall(CAtom(m), CAtom(f), args) ->
      { m == module && f == fun }
      || list.any(args, contains_call(_, module, fun))
    CCall(m, f, args) ->
      contains_call(m, module, fun)
      || contains_call(f, module, fun)
      || list.any(args, contains_call(_, module, fun))
    CLet(_, a, b) ->
      contains_call(a, module, fun) || contains_call(b, module, fun)
    CLetrec(defs, b) ->
      list.any(defs, fn(d) {
        let FunDef(_, v) = d
        contains_call(v, module, fun)
      })
      || contains_call(b, module, fun)
    CCase(a, cs) ->
      contains_call(a, module, fun)
      || list.any(cs, fn(c) {
        let CClause(_, g, bd) = c
        contains_call(g, module, fun) || contains_call(bd, module, fun)
      })
    CFun(_, b) -> contains_call(b, module, fun)
    CCons(h, t) ->
      contains_call(h, module, fun) || contains_call(t, module, fun)
    CTuple(xs) -> list.any(xs, contains_call(_, module, fun))
    _ -> False
  }
}

/// THE `instantiate/0` golden: it is exported, and its body sequences (in order) the
/// per-instance seeds `seed_fuel` (Safe/MeterFuel, FIRST) → `seed_policy` (always) then
/// `seed` → `init_elem` → `init_data` → `apply 'init'/0` → `'ok'`, each init step a
/// trap-at-instantiation `case`, with the element entry a `CFun`-wrapped STATIC `apply` of
/// `elemfn` (no dynamic apply). The two seed lines are the one documented policy-field read
/// (§A.4): `seed_fuel(fuel_budget)` arms the fail-closed CPU bound before any `charge`, and
/// `seed_policy(host_deny_all)` bakes the Safe host posture as a Core literal.
pub fn instantiate_entry_golden_test() {
  let b = binding()
  let assert Ok(cm) = emit_core.emit_module(full_module(), b)
  // Exported as `instantiate/0`.
  assert list.contains(cm.exports, FName("instantiate", 0))
  let assert Ok(FunDef(_, CFun([], body))) =
    list.find(cm.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == "instantiate"
    })
  // Step 0a: `seed_fuel` FIRST under MeterFuel — the CPU bound is armed before any charge
  // (§A.4/F5); the baked budget is `binding.fuel_budget`.
  let assert CLet([_], fuel_rhs, after_fuel) = body
  let assert CCall(CAtom(meter), CAtom("seed_fuel"), [CInt(budget)]) = fuel_rhs
  assert meter == b.meter_module
  assert budget == b.fuel_budget
  // Step 0b: `seed_policy` ALWAYS — Safe bakes the `host_deny_all` atom literal (§A.4/F4).
  let assert CLet([_], policy_rhs, after_policy) = after_fuel
  let assert CCall(CAtom(host), CAtom("seed_policy"), [CAtom("host_deny_all")]) =
    policy_rhs
  assert host == b.host_module
  // Step 1: seed — `{state_decl, fresh(...), [{<<"g0">>,42}], new(...)}`.
  let assert CLet([_], seed_rhs, rest1) = after_policy
  let assert CCall(
    CAtom(state),
    CAtom("seed"),
    [CTuple([CAtom("state_decl"), mem_fresh, globals, table_new])],
  ) = seed_rhs
  assert state == b.state_module
  let assert CCall(CAtom(_), CAtom("fresh"), [CInt(1), _, CInt(65_536)]) =
    mem_fresh
  let assert CCall(CAtom(_), CAtom("new"), [CInt(4), _]) = table_new
  let assert CCons(CTuple([CBinary(_), CInt(42)]), CNil) = globals
  // Step 2: element segment BEFORE data segment, each a trap `case` over its seam call.
  let assert CLet([_], elem_rhs, rest2) = rest1
  assert contains_call(elem_rhs, b.table_module, "init_elem")
  // The element entry is a build-controlled closure that STATICALLY applies `elemfn`.
  assert applies_to(elem_rhs, "elemfn")
  // Step 3: data segment.
  let assert CLet([_], data_rhs, rest3) = rest2
  assert contains_call(data_rhs, b.mem_module, "init_data")
  // Step 4: the start function, applied statically, then `'ok'`.
  let assert CLet([_], CApply(FName("init", 0), []), CAtom("ok")) = rest3
}

// ───────────────────────────── fail-closed error paths (never panic) ─────────────────────────────

/// The remaining out-of-scope IR nodes return a typed `EmitError` — never a panic (D4
/// fail-closed). Phase 2 lowers the stateful ops + numeric `Convert`s, so only the term
/// layer (`TermOp`) and the four term↔numeric boxing `Convert`s stay unsupported.
pub fn out_of_scope_nodes_error_test() {
  assert emit_one(ir.TermOp(ir.MakeTuple, [ir.Var("a")]))
    == Error(emit_core.UnsupportedNode("term_op"))
  assert emit_one(ir.Convert(ir.BoxInt(ir.W32), ir.Var("a")))
    == Error(emit_core.UnsupportedNode("box_int"))
  assert emit_one(ir.Convert(ir.UnboxInt(ir.W32), ir.Var("a")))
    == Error(emit_core.UnsupportedNode("unbox_int"))
  assert emit_one(ir.Convert(ir.BoxFloat(ir.FW32), ir.Var("a")))
    == Error(emit_core.UnsupportedNode("box_float"))
  assert emit_one(ir.Convert(ir.UnboxFloat(ir.FW32), ir.Var("a")))
    == Error(emit_core.UnsupportedNode("unbox_float"))
}

/// A `CallDirect` to an undefined function is `Error(UnknownFunction)`.
pub fn unknown_function_error_test() {
  let f =
    ir.Function(
      name: "caller",
      params: [],
      result: [ir.TI32],
      locals: [],
      body: ir.CallDirect("nope", []),
    )
  assert emit_core.emit_module(module_with(f), binding())
    == Error(emit_core.UnknownFunction("nope"))
}

/// When an `ExportFn`'s external `export_name` differs from the internal `fn_name`, the
/// export list references `export_name` and a forwarding wrapper `'export_name'/arity =
/// fun(A…) -> apply 'fn_name'/arity(A…)` is emitted (Core Erlang exports a function by its
/// own name).
pub fn export_alias_wrapper_test() {
  let f =
    ir.Function(
      name: "f3",
      params: [ir.Local("p0", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Return([ir.Var("p0")]),
    )
  let m =
    ir.Module(
      name: "twocore@test@alias",
      uses_numerics: True,
      memories: [],
      globals: [],
      imports: [],
      functions: [f],
      exports: [ir.ExportFn("main", "f3")],
      data_segments: [],
      tables: [],
      elements: [],
      start: option.None,
      tags: [],
    )
  let assert Ok(cm) = emit_core.emit_module(m, binding())
  // The external name/arity is exported …
  assert list.contains(cm.exports, FName("main", 1))
  // … via a wrapper that forwards to the internal function.
  let assert Ok(FunDef(
    FName("main", 1),
    CFun([_], CApply(FName("f3", 1), [CVar(_)])),
  )) =
    list.find(cm.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == "main"
    })
}

/// Emit a one-function module whose body is `expr`, returning the module-level result.
fn emit_one(expr: ir.Expr) -> Result(core_erlang.CModule, emit_core.EmitError) {
  let f =
    ir.Function(
      name: "f",
      params: [ir.Local("a", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: expr,
    )
  emit_core.emit_module(module_with(f), binding())
}

// ════════════════════ Phase-4 (P4-02): threaded-seam AST goldens ════════════════════
//
// These assert the `state_strategy: Threaded` codegen SHAPE against the keystone
// (`01-interface-freeze.md` §A) and the unit doc (`02-emit-threaded-seam.md` §B–§E) — the
// uniform-threading rule (a state-reaching `'f'/(n+1)` returning `{Package, St'}`), the per-op
// record threading (rebind on write, read-through on read), the G4 constant-space loop
// back-edge, the record-returning `instantiate/0`, and the §B.4 export-collision fix. They are
// structural (pattern-match the AST), not change-detectors: each cites the frozen decision.

/// A Safe binding switched to the tier-P `Threaded` state strategy (keystone §A) — same fixed
/// `twocore@runtime@*` modules, only the codegen SHAPE differs (the strategy is the sole switch).
fn threaded_binding() -> instance.Binding {
  instance.Binding(..instance.safe_default(), state_strategy: instance.Threaded)
}

/// A single-function module WITH memory/global/table declared (so every stateful op has a
/// backing decl), exported by its own name — for asserting a state-reaching function's shape.
fn st_module(f: ir.Function) -> ir.Module {
  ir.Module(
    name: "twocore@test@" <> f.name,
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(0)]))],
    imports: [],
    functions: [f],
    exports: [ir.ExportFn(f.name, f.name)],
    data_segments: [],
    tables: [ir.TableDecl("t0", ir.FuncRef, 4, option.None)],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// Emit `module` under `Threaded` and return the FIRST def whose function atom is `name`.
fn threaded_def(module: ir.Module, name: String) -> core_erlang.FunDef {
  let assert Ok(m) = emit_core.emit_module(module, threaded_binding())
  let assert Ok(def) =
    list.find(m.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == name
    })
  def
}

/// A state-reaching `store(addr,val)` becomes `'store'/3 = fun(St, addr, val) -> {…, St'}`:
/// the `InstanceState` is the LEADING param, `MemStore` REBINDS it via
/// `let St2 = case t_store(St,…) of {ok,S}->S; {error,E}->raise`, and the zero-result body
/// returns `{'ok', St2}` — the outgoing REBOUND record (keystone §10 / unit-doc §B.1, §C).
pub fn threaded_store_rebinds_record_test() {
  let b = threaded_binding()
  let store =
    ir.Function(
      name: "store",
      params: [ir.Local("addr", ir.TI32), ir.Local("val", ir.TI32)],
      result: [],
      locals: [],
      body: ir.Let(
        [],
        ir.MemStore(0, ir.MemAccess(4, False), ir.Var("addr"), ir.Var("val"), 0),
        ir.Values([]),
      ),
    )
  let assert FunDef(FName("store", 3), CFun([st, "addr", "val"], body)) =
    threaded_def(st_module(store), "store")
  let assert CLet(
    [newst],
    CCase(
      CCall(
        CAtom(mem),
        CAtom("t_store"),
        [CVar(st_arg), CInt(4), CVar("addr"), CVar("val"), CInt(0)],
      ),
      [
        CClause([PTuple([PAtom("ok"), PVar(s)])], CAtom("true"), CVar(s2)),
        CClause(
          [PTuple([PAtom("error"), PVar(_)])],
          CAtom("true"),
          CCall(CAtom(_), CAtom("raise"), [CVar(_)]),
        ),
      ],
    ),
    tail,
  ) = body
  assert mem == b.mem_module
  // the store reads the LEADING record param and the `{ok,S}` arm yields the REBOUND record.
  assert st_arg == st
  assert s == s2
  // the zero-result function returns `{'ok', St2}` — the rebound record, NOT the incoming St.
  let assert CLet([], CValues([]), CTuple([CAtom("ok"), CVar(ret)])) = tail
  assert ret == newst
}

/// A state-reaching `load(addr)` becomes `'load'/2 = fun(St, addr) -> {V, St}`: `MemLoad`
/// reads through `t_load(St,…)` and threads the SAME record on UNCHANGED (read-only, §C).
pub fn threaded_load_reads_without_rebind_test() {
  let load =
    ir.Function(
      name: "load",
      params: [ir.Local("addr", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("addr"), 0, ir.TI32),
    )
  let assert FunDef(FName("load", 2), CFun([st, "addr"], body)) =
    threaded_def(st_module(load), "load")
  let assert CLet(
    [rvar],
    CCase(
      CCall(
        CAtom(_),
        CAtom("t_load"),
        [CVar(st_arg), CInt(4), CAtom("false"), CInt(32), CVar("addr"), CInt(0)],
      ),
      _clauses,
    ),
    CTuple([CVar(rv2), CVar(ret)]),
  ) = body
  assert st_arg == st
  assert rv2 == rvar
  // read-only: the record threaded out is the SAME leading param St.
  assert ret == st
}

/// `MemSize` reads through `t_size(St)` and threads the SAME record on (read-only, §C):
/// `'size'/1 = fun(St) -> {t_size(St), St}`.
pub fn threaded_size_reads_without_rebind_test() {
  let size =
    ir.Function(
      name: "size",
      params: [],
      result: [ir.TI32],
      locals: [],
      body: ir.MemSize(0),
    )
  let assert FunDef(FName("size", 1), CFun([st], body)) =
    threaded_def(st_module(size), "size")
  let assert CTuple([
    CCall(CAtom(_), CAtom("t_size"), [CVar(st_arg)]),
    CVar(ret),
  ]) = body
  assert st_arg == st
  assert ret == st
}

/// `MemGrow(delta)` binds `{V, St2} = t_grow(St, Delta)` — the old page count `V` paired with
/// the REBOUND record `St2` (§C): `'grow'/2 = fun(St, d) -> {V, St2}`.
pub fn threaded_grow_binds_value_and_rebinds_test() {
  let grow =
    ir.Function(
      name: "grow",
      params: [ir.Local("d", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.MemGrow(0, ir.Var("d")),
    )
  let assert FunDef(FName("grow", 2), CFun([st, "d"], body)) =
    threaded_def(st_module(grow), "grow")
  let assert CCase(
    CCall(CAtom(_), CAtom("t_grow"), [CVar(st_arg), CVar("d")]),
    [
      CClause(
        [PTuple([PVar(v), PVar(st2)])],
        CAtom("true"),
        CTuple([CVar(v2), CVar(ret)]),
      ),
    ],
  ) = body
  assert st_arg == st
  assert v == v2
  // the REBOUND record (St2) is threaded out — distinct from the incoming leading St.
  assert ret == st2
  assert st2 != st
}

/// `GlobalGet(name)` reads through `t_global_get(St, NameBin)` and threads the SAME record on
/// (read-only, §C): `'get'/1 = fun(St) -> {t_global_get(St, <<"g0">>), St}`.
pub fn threaded_global_get_reads_without_rebind_test() {
  let b = threaded_binding()
  let get =
    ir.Function(
      name: "get",
      params: [],
      result: [ir.TI32],
      locals: [],
      body: ir.GlobalGet("g0"),
    )
  let assert FunDef(FName("get", 1), CFun([st], body)) =
    threaded_def(st_module(get), "get")
  let assert CTuple([
    CCall(CAtom(state), CAtom("t_global_get"), [CVar(st_arg), CBinary(_)]),
    CVar(ret),
  ]) = body
  assert state == b.state_module
  assert st_arg == st
  assert ret == st
}

/// `GlobalSet(name, value)` REBINDS the record via the non-trapping `t_global_set(St, …)`
/// (returns the record directly, §C): `'set'/2 = fun(St, v) -> …{'ok', St2}`.
pub fn threaded_global_set_rebinds_record_test() {
  let set =
    ir.Function(
      name: "set",
      params: [ir.Local("v", ir.TI32)],
      result: [],
      locals: [],
      body: ir.Let([], ir.GlobalSet("g0", ir.Var("v")), ir.Values([])),
    )
  let assert FunDef(FName("set", 2), CFun([st, "v"], body)) =
    threaded_def(st_module(set), "set")
  let assert CLet(
    [newst],
    CCall(
      CAtom(_),
      CAtom("t_global_set"),
      [CVar(st_arg), CBinary(_), CVar("v")],
    ),
    CLet([], CValues([]), CTuple([CAtom("ok"), CVar(ret)])),
  ) = body
  assert st_arg == st
  assert ret == newst
}

/// `CallIndirect` binds `{Rs, St2}` from `t_call_indirect(St, …)` — the results LIST `Rs`
/// (unpacked to `len(ty.results)` values) with the REBOUND record `St2` (§C, §G).
pub fn threaded_call_indirect_binds_results_and_rebinds_test() {
  let b = threaded_binding()
  let f =
    ir.Function(
      name: "f",
      params: [ir.Local("i", ir.TI32), ir.Local("x", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.CallIndirect(
        "t0",
        ir.Var("i"),
        ir.FuncType([ir.TI32], [ir.TI32]),
        [ir.Var("x")],
      ),
    )
  let assert FunDef(FName("f", 3), CFun([st, "i", "x"], body)) =
    threaded_def(st_module(f), "f")
  let assert CLet(
    [pbound],
    CCase(
      CCall(
        CAtom(table),
        CAtom("t_call_indirect"),
        [CVar(st_arg), CVar("i"), CTuple(_ty), CCons(CVar("x"), CNil)],
      ),
      _reduce,
    ),
    CCase(
      CVar(pb2),
      [CClause([PTuple([PVar(rs), PVar(st2)])], CAtom("true"), inner)],
    ),
  ) = body
  assert table == b.table_module
  assert st_arg == st
  assert pbound == pb2
  // the results list is unpacked (r=1 → `[V]`) and returned with the REBOUND record.
  let assert CCase(
    CVar(rs2),
    [
      CClause(
        [PCons(PVar(vn), PNil)],
        CAtom("true"),
        CTuple([CVar(vn2), CVar(ret)]),
      ),
    ],
  ) = inner
  assert rs == rs2
  assert vn == vn2
  assert ret == st2
}

/// A PURE function under `Threaded` keeps its Phase-1 `'g'/n` shape (no `St`, no return
/// tuple) — byte-identical to `Cell`. So pure numeric leaves pay NOTHING (§B.1, §D).
pub fn threaded_pure_function_keeps_phase1_shape_test() {
  let b = threaded_binding()
  let assert FunDef(
    FName("add", 2),
    CFun(
      ["p0", "p1"],
      CLet(
        ["r"],
        CCall(CAtom(num), CAtom("i32_add"), [CVar("p0"), CVar("p1")]),
        CVar("r"),
      ),
    ),
  ) = threaded_def(module_with(add_fn()), "add")
  assert num == b.num_module
}

/// A tail `CallDirect` to a STATE-REACHING callee stays a TAIL CALL: `apply 'g'/(n+1)(St, x)`
/// straight through — `{Package, St'}` is already what the caller returns, so cross-function
/// tail recursion keeps constant stack (§B.3). No wrapping `case`/`let`.
pub fn threaded_tail_call_to_state_reaching_stays_tail_test() {
  let g =
    ir.Function(
      name: "g",
      params: [ir.Local("x", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("x"), 0, ir.TI32),
    )
  let f =
    ir.Function(
      name: "f",
      params: [ir.Local("x", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.CallDirect("g", [ir.Var("x")]),
    )
  let m =
    ir.Module(
      name: "twocore@test@tailcall",
      uses_numerics: True,
      memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
      globals: [],
      imports: [],
      functions: [g, f],
      exports: [ir.ExportFn("g", "g"), ir.ExportFn("f", "f")],
      data_segments: [],
      tables: [],
      elements: [],
      start: option.None,
      tags: [],
    )
  let assert FunDef(FName("f", 2), CFun([st, "x"], body)) = threaded_def(m, "f")
  // the whole body IS the tail apply — {Package, St'} passed straight through.
  let assert CApply(FName("g", 2), [CVar(st_arg), CVar("x")]) = body
  assert st_arg == st
}

/// A state-reaching `Loop` carries `St` as the LEADING loop param and the `Continue`
/// back-edge is a TAIL `apply 'L'(St', vs…)` — the G4 constant-space template (unit-doc §D).
pub fn threaded_loop_is_constant_space_template_test() {
  let run =
    ir.Function(
      name: "run",
      params: [],
      result: [],
      locals: [],
      body: ir.Loop(
        label: "go",
        params: [ir.LoopParam("i", ir.TI32, ir.ConstI32(0))],
        result: [],
        body: ir.Let(
          [],
          ir.MemStore(0, ir.MemAccess(4, False), ir.Var("i"), ir.Var("i"), 0),
          ir.Continue("go", [ir.Var("i")]),
        ),
      ),
    )
  let assert FunDef(FName("run", 1), CFun([st], body)) =
    threaded_def(st_module(run), "run")
  // `letrec 'L'/2 = fun(St, i) -> …` applied to `apply 'L'(St_entry, 0)`.
  let assert CLetrec(
    [FunDef(FName(lname, 2), CFun([st_loop, "i"], lbody))],
    CApply(FName(entry, 2), [CVar(st_entry), CInt(0)]),
  ) = body
  assert entry == lname
  // the loop is entered with the function's LEADING record param.
  assert st_entry == st
  // the back-edge is a TAIL apply of the loop head, prepending the LIVE (rebound) record. The
  // store's `let St2 = <case>` rebinds the record; the `Let([], …, Continue)` interposes only a
  // trivial zero-value `let <> = <>` (identical to the cell path), then the `apply` is in TAIL
  // position — no `case`/wrapping between it and the loop head, so the loop is constant space.
  let assert CLet(
    [st2],
    _store_case,
    CLet([], CValues([]), CApply(FName(back, 2), [CVar(st2b), CVar("i")])),
  ) = lbody
  assert back == lname
  assert st2b == st2
  // St2 is the store's rebound record, threaded on the loop param slot (not `st_loop`).
  assert st2 != st_loop
}

/// §B.4 export collision: a state-reaching `ExportFn(f, f)` (`export_name == fn_name`) yields
/// EXACTLY ONE `'f'/(n+1)` def — the internal one, exported DIRECTLY, with NO self-applying
/// wrapper. Without the fix, a second `'f'/(n+1)` (self-applying → duplicate def + infinite
/// recursion) would be emitted (unit-doc §B.4 / the `emit_core.gleam:315` name-equality mirror).
pub fn threaded_export_name_equals_fn_no_duplicate_test() {
  let store =
    ir.Function(
      name: "f",
      params: [ir.Local("addr", ir.TI32)],
      result: [],
      locals: [],
      body: ir.Let(
        [],
        ir.MemStore(
          0,
          ir.MemAccess(4, False),
          ir.Var("addr"),
          ir.Var("addr"),
          0,
        ),
        ir.Values([]),
      ),
    )
  let assert Ok(m) = emit_core.emit_module(st_module(store), threaded_binding())
  let fdefs =
    list.filter(m.defs, fn(d) {
      let FunDef(FName(n, a), _) = d
      n == "f" && a == 2
    })
  // exactly one `'f'/2` def, exported directly at arity n+1, and it is the REAL body …
  assert list.length(fdefs) == 1
  assert list.contains(m.exports, FName("f", 2))
  let assert [FunDef(_, CFun(_, fbody))] = fdefs
  // … not a self-applying forwarder (`fun(St,A) -> apply 'f'/2(St,A)`).
  assert applies_to(fbody, "f") == False
}

/// §B.4: a state-reaching `ExportFn(main, f)` with DISTINCT names emits a separate forwarder
/// `'main'/(n+1) = fun(St, A…) -> apply 'f'/(n+1)(St, A…)` (already `{Package, St'}`).
pub fn threaded_export_alias_forwards_at_plus_one_test() {
  let store =
    ir.Function(
      name: "f",
      params: [ir.Local("addr", ir.TI32)],
      result: [],
      locals: [],
      body: ir.Let(
        [],
        ir.MemStore(
          0,
          ir.MemAccess(4, False),
          ir.Var("addr"),
          ir.Var("addr"),
          0,
        ),
        ir.Values([]),
      ),
    )
  let m =
    ir.Module(
      name: "twocore@test@threadedalias",
      uses_numerics: True,
      memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
      globals: [],
      imports: [],
      functions: [store],
      exports: [ir.ExportFn("main", "f")],
      data_segments: [],
      tables: [],
      elements: [],
      start: option.None,
      tags: [],
    )
  let assert Ok(cm) = emit_core.emit_module(m, threaded_binding())
  assert list.contains(cm.exports, FName("main", 2))
  let assert Ok(FunDef(
    FName("main", 2),
    CFun([mst, ma], CApply(FName("f", 2), [CVar(mst2), CVar(ma2)])),
  )) =
    list.find(cm.defs, fn(d) {
      let FunDef(FName(n, a), _) = d
      n == "main" && a == 2
    })
  assert mst == mst2
  assert ma == ma2
}

/// §B.4: a PURE export gets an `'export'/(n+1)` adapter `fun(St, A…) -> {apply 'g'/n(A…), St}`
/// that COEXISTS with the internal `'g'/n` (distinct arity, no collision).
pub fn threaded_pure_export_adapter_test() {
  let assert Ok(cm) =
    emit_core.emit_module(module_with(add_fn()), threaded_binding())
  // the uniform threaded export ABI is arity n+1.
  assert list.contains(cm.exports, FName("add", 3))
  // the internal `'add'/2` still exists (a pure def; internal callers use it) …
  assert list.any(cm.defs, fn(d) {
    let FunDef(FName(n, a), _) = d
    n == "add" && a == 2
  })
  // … and the `'add'/3` adapter threads St straight through: `{apply 'add'/2(A0,A1), St}`.
  let assert Ok(FunDef(
    FName("add", 3),
    CFun(
      [ast, a0, a1],
      CTuple([CApply(FName("add", 2), [CVar(a0b), CVar(a1b)]), CVar(ast2)]),
    ),
  )) =
    list.find(cm.defs, fn(d) {
      let FunDef(FName(n, a), _) = d
      n == "add" && a == 3
    })
  assert ast == ast2
  assert a0 == a0b
  assert a1 == a1b
}

/// The `Threaded` `instantiate/0` (§E) BUILDS the record via `fresh(Decl)` (not `seed`),
/// threads it through element → data → start in WASM order (each a record-rebinding step), and
/// RETURNS the `InstanceState` (not `'ok'`). The `Decl` term is BIT-IDENTICAL to the `Cell`
/// `seed` decl, and `seed_fuel`/`seed_policy` still lead (spec instantiation order; keystone §A.3).
pub fn threaded_instantiate_builds_and_returns_record_test() {
  let tb = threaded_binding()
  let assert Ok(cm) = emit_core.emit_module(full_module(), tb)
  assert list.contains(cm.exports, FName("instantiate", 0))
  let assert Ok(FunDef(_, CFun([], body))) =
    list.find(cm.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == "instantiate"
    })
  // seed_fuel FIRST (MeterFuel), then seed_policy — UNCHANGED discards (§E 0a/0b).
  let assert CLet([_], CCall(CAtom(meter), CAtom("seed_fuel"), [CInt(_)]), af) =
    body
  assert meter == tb.meter_module
  let assert CLet(
    [_],
    CCall(CAtom(host), CAtom("seed_policy"), [CAtom("host_deny_all")]),
    ap,
  ) = af
  assert host == tb.host_module
  // St0 = fresh(Decl) — BUILDS the record (not `seed`); Decl bit-identical to the Cell decl.
  let assert CLet([st0], CCall(CAtom(state), CAtom("fresh"), [decl]), a_fresh) =
    ap
  assert state == tb.state_module
  assert decl == cell_seed_decl(full_module())
  // element segment BEFORE data segment — each a record-rebinding `case`.
  let assert CLet([st1], elem_case, a_elem) = a_fresh
  assert contains_call(elem_case, tb.table_module, "t_init_elem")
  assert applies_to(elem_case, "elemfn")
  let assert CLet([st2], data_case, a_data) = a_elem
  assert contains_call(data_case, tb.mem_module, "t_init_data")
  // start (`init` is pure `[]→[]`): `let _ = apply 'init'/0() in <return the record>`.
  let assert CLet([_], CApply(FName("init", 0), []), CVar(final)) = a_data
  // RETURNS the threaded `InstanceState` (the final record), NOT `'ok'`.
  assert final == st2
  assert st0 != st1
  assert st1 != st2
}

/// Extract the `Decl` term the `Cell` `instantiate/0` passes to `rt_state:seed(Decl)` — so the
/// threaded `fresh(Decl)` can be asserted BIT-IDENTICAL to it (G7: both strategies materialise
/// identical state).
fn cell_seed_decl(module: ir.Module) -> CExpr {
  let assert Ok(cm) = emit_core.emit_module(module, binding())
  let assert Ok(FunDef(_, CFun([], body))) =
    list.find(cm.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == "instantiate"
    })
  find_seed_decl(body)
}

/// Walk the `Cell` `instantiate/0` body's `let`-chain to the `rt_state:seed(Decl)` call and
/// return its `Decl` argument. Panics if no `seed` call is present (an internal test invariant).
fn find_seed_decl(e: CExpr) -> CExpr {
  case e {
    CLet(_, CCall(_, CAtom("seed"), [decl]), _) -> decl
    CLet(_, _, rest) -> find_seed_decl(rest)
    _ ->
      panic as "find_seed_decl: no rt_state:seed call in the Cell instantiate body"
  }
}

// ════════════════════ Phase-5 (P5-06): reference / table / bulk / multi-mem goldens ════════════════════

/// A Safe binding switched to the tier-P `Threaded` state strategy.
fn threaded() -> instance.Binding {
  instance.Binding(..instance.safe_default(), state_strategy: instance.Threaded)
}

/// A module with a `target : [i32]->[i32]` function, one memory, one passive `<<1,2,3,4>>` data
/// segment, and a funcref table `t0` (size 4) — wrapping `f(p0)` with body `body`/result `result`.
fn p5_module(body: ir.Expr, result: List(ir.ValType)) -> ir.Module {
  let target =
    ir.Function(
      "target",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.Return([ir.Var("x")]),
    )
  let f = ir.Function("f", [ir.Local("p0", ir.TI32)], result, [], body)
  ir.Module(
    name: "twocore@test@p5",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [target, f],
    exports: [],
    data_segments: [ir.DataSegment(ir.DataPassive, <<1, 2, 3, 4>>)],
    tables: [ir.TableDecl("t0", ir.FuncRef, 4, option.None)],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// The `f` `FunDef` emitted from `p5_module(body, result)` under `binding`.
fn p5_fdef(
  body: ir.Expr,
  result: List(ir.ValType),
  b: instance.Binding,
) -> core_erlang.FunDef {
  let assert Ok(m) = emit_core.emit_module(p5_module(body, result), b)
  let assert Ok(def) =
    list.find(m.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == "f"
    })
  def
}

/// `ConstNull(ty)` lowers to the SHARED null sentinel literal `{ref_null}` (R1) — a pure literal
/// (no `call`), reftype-agnostic. Cite §4.4.2 (`ref.null`).
pub fn const_null_is_sentinel_test() {
  let assert FunDef(_, CFun(_, CTuple([CAtom("ref_null")]))) =
    p5_fdef(ir.Values([ir.ConstNull(ir.FuncRef)]), [ir.TFuncRef], binding())
}

/// `RefIsNull(arg)` delegates the sentinel test to `rt_ref:is_null` and maps the `'true'`/`'false'`
/// result to the i32 `1`/`0` the spec requires — a bare pure value (no state threading). §4.4.2.
pub fn ref_is_null_test() {
  let assert FunDef(
    _,
    CFun(
      _,
      CCase(
        CCall(CAtom("twocore@runtime@rt_ref"), CAtom("is_null"), [CVar("p0")]),
        [
          CClause([PAtom("true")], CAtom("true"), CInt(1)),
          CClause([PVar(_)], CAtom("true"), CInt(0)),
        ],
      ),
    ),
  ) = p5_fdef(ir.RefIsNull(ir.Var("p0")), [ir.TI32], binding())
}

/// `RefFunc($target)` lowers to the `{TypeTag, Closure}` funcref entry — the SAME `{FuncType,
/// CFun}` shape an element segment stores (§B): a `funcref` value *is* a table-entry shape (R1).
pub fn ref_func_is_entry_test() {
  let assert FunDef(
    _,
    CFun(_, CTuple([CTuple([_params, _results]), CFun(_, _)])),
  ) = p5_fdef(ir.RefFunc("target"), [ir.TFuncRef], binding())
}

/// `TableGet(t0, i)` (Cell) → a trapping-value `case`-and-`raise` over `rt_table:get(0, i)` — an
/// in-bounds unfilled slot returns the null sentinel (a value); an OOB index traps. §4.4.6.
pub fn table_get_test() {
  let assert FunDef(
    _,
    CFun(
      _,
      CLet(
        [_],
        CCase(
          CCall(CAtom(_), CAtom("get"), [CInt(0), CVar("p0")]),
          [
            CClause([PTuple([PAtom("ok"), _])], _, _),
            CClause([PTuple([PAtom("error"), _])], _, _),
          ],
        ),
        _,
      ),
    ),
  ) = p5_fdef(ir.TableGet("t0", ir.Var("p0")), [ir.TFuncRef], binding())
}

/// `TableSize(t0)` → a bare `rt_table:size(0)` (never traps). §4.4.6.
pub fn table_size_test() {
  let assert FunDef(_, CFun(_, CCall(CAtom(_), CAtom("size"), [CInt(0)]))) =
    p5_fdef(ir.TableSize("t0"), [ir.TI32], binding())
}

/// `TableGrow(t0, delta, init)` (Cell) → a bare `rt_table:grow(0, Delta, Init)` returning the old
/// size / `-1` (never traps). §4.4.6 (grow returns `-1` on failure).
pub fn table_grow_test() {
  let assert FunDef(
    _,
    CFun(
      _,
      CCall(
        CAtom(_),
        CAtom("grow"),
        [CInt(0), CInt(1), CTuple([CAtom("ref_null")])],
      ),
    ),
  ) =
    p5_fdef(
      ir.TableGrow("t0", ir.ConstI32(1), ir.ConstNull(ir.FuncRef)),
      [ir.TI32],
      binding(),
    )
}

/// The memory-index ROUTING (H3/H7): `MemLoad(0, …)` emits the byte-identical Phase-4 `rt_mem:load`
/// (NO index arg); `MemLoad(1, …)` emits `rt_mem:load_at(1, …)` (a leading memidx). A single-memory
/// index-0 module is unchanged from Phase-4.
pub fn mem_load_index_routing_test() {
  // index 0 → the un-indexed head.
  let load0 = ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("p0"), 0, ir.TI32)
  let assert FunDef(
    _,
    CFun(
      _,
      CLet(
        [_],
        CCase(
          CCall(CAtom(_), CAtom("load"), [CInt(4), _, _, CVar("p0"), CInt(0)]),
          _,
        ),
        _,
      ),
    ),
  ) = p5_fdef(load0, [ir.TI32], binding())
  // index 1 → the `_at` head with a leading memory index.
  let load1 = ir.MemLoad(1, ir.MemAccess(4, False), ir.Var("p0"), 0, ir.TI32)
  let assert FunDef(
    _,
    CFun(
      _,
      CLet(
        [_],
        CCase(
          CCall(
            CAtom(_),
            CAtom("load_at"),
            [CInt(1), CInt(4), _, _, CVar("p0"), CInt(0)],
          ),
          _,
        ),
        _,
      ),
    ),
  ) = p5_fdef(load1, [ir.TI32], binding())
}

/// `MemFill(0, …)` → an eager trapping `rt_mem:fill(0, D, V, N)`; `MemCopy(1, 0, …)` →
/// `rt_mem:copy(1, 0, D, S, N)` (the memory indices lead). §4.4.7.
pub fn mem_bulk_test() {
  let fill =
    ir.Let(
      [],
      ir.MemFill(0, ir.ConstI32(0), ir.ConstI32(0xAB), ir.Var("p0")),
      ir.Values([]),
    )
  let assert FunDef(_, CFun(_, CLet([_], fill_case, _))) =
    p5_fdef(fill, [], binding())
  let assert CCase(
    CCall(CAtom(_), CAtom("fill"), [CInt(0), CInt(0), CInt(0xAB), CVar("p0")]),
    _,
  ) = fill_case
  let copy =
    ir.Let(
      [],
      ir.MemCopy(1, 0, ir.ConstI32(0), ir.ConstI32(0), ir.Var("p0")),
      ir.Values([]),
    )
  let assert FunDef(_, CFun(_, CLet([_], copy_case, _))) =
    p5_fdef(copy, [], binding())
  let assert CCase(
    CCall(
      CAtom(_),
      CAtom("copy"),
      [CInt(1), CInt(0), CInt(0), CInt(0), CVar("p0")],
    ),
    _,
  ) = copy_case
}

/// `MemInit(0, 0, …)` DROP-GATES the segment payload (R2): the bytes are
/// `case rt_state:data_dropped(0) of 'true' -> <<>>; _ -> <<1,2,3,4>> end`, so a dropped segment
/// behaves as length-0 (a later init with `count > 0` traps on the source bound). §4.4.9.
pub fn mem_init_drop_gate_test() {
  let init =
    ir.Let(
      [],
      ir.MemInit(0, 0, ir.ConstI32(0), ir.ConstI32(0), ir.Var("p0")),
      ir.Values([]),
    )
  // the drop-gate binds the payload, which is empty when dropped and the literal bytes otherwise.
  let assert FunDef(_, CFun(_, CLet([seg], gate, _))) =
    p5_fdef(init, [], binding())
  let assert CCase(
    CCall(CAtom(_), CAtom("data_dropped"), [CInt(0)]),
    [
      CClause([PAtom("true")], CAtom("true"), CBinary([])),
      CClause([PVar(_)], CAtom("true"), CBinary([_, _, _, _])),
    ],
  ) = gate
  // …then the gated payload feeds `rt_mem:init(0, Seg, …)`.
  assert seg != ""
}

/// H7 threading-neutrality of REFERENCES (§A.2): under `Threaded`, a REFERENCE-only function keeps
/// its pure Phase-1 arity `f/1` (a `ref.func` alone does NOT force record threading), while a
/// TABLE-op function is state-reaching and threads the record at `f/2`.
pub fn reference_only_stays_pure_under_threaded_test() {
  // ref.func only → still `f/1` (pure), no leading `InstanceState`.
  let assert FunDef(FName("f", 1), _) =
    p5_fdef(ir.RefFunc("target"), [ir.TFuncRef], threaded())
  // a table op → `f/2` (state-reaching), the record threaded as the leading parameter.
  let assert FunDef(FName("f", 2), _) =
    p5_fdef(ir.TableSize("t0"), [ir.TI32], threaded())
}

// ══════════════════════ Phase-6 SIMD + memory64 + cross-module (P6-06) ══════════════════════
//
// Structural goldens for the new IR4 nodes, asserted against the fixed-width-SIMD spec (§5.4.9) /
// the memory64 proposal (S9) / spec §4.5.4 + S5 — NOT change-detectors: the `rt_simd` names ARE the
// spec instruction mnemonics; the compose shapes ARE the S4 table; the closure dispatch IS the D3a
// capability form. Each pattern-matches the emitted `core_erlang` AST.

/// Emit `module` under `b` and return function `name`'s Core body.
fn body_of_b(module: ir.Module, name: String, b: instance.Binding) -> CExpr {
  let assert Ok(m) = emit_core.emit_module(module, b)
  let assert Ok(FunDef(_, CFun(_, body))) =
    list.find(m.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == name
    })
  body
}

/// The FunDef of function `name` in `module` emitted under `b` (to inspect its arity).
fn fdef_of(
  module: ir.Module,
  name: String,
  b: instance.Binding,
) -> core_erlang.FunDef {
  let assert Ok(m) = emit_core.emit_module(module, b)
  let assert Ok(def) =
    list.find(m.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == name
    })
  def
}

/// True iff `e` (recursively) contains a `call '<mod>':'<fun>'(...)`.
fn has_call(e: CExpr, mod: String, fun: String) -> Bool {
  case e {
    CCall(CAtom(m), CAtom(f), args) ->
      { m == mod && f == fun } || list.any(args, has_call(_, mod, fun))
    CCall(m, f, args) ->
      has_call(m, mod, fun)
      || has_call(f, mod, fun)
      || list.any(args, has_call(_, mod, fun))
    CLet(_, arg, body) -> has_call(arg, mod, fun) || has_call(body, mod, fun)
    CLetrec(defs, body) ->
      list.any(defs, fn(d) {
        let FunDef(_, v) = d
        has_call(v, mod, fun)
      })
      || has_call(body, mod, fun)
    CCase(arg, clauses) ->
      has_call(arg, mod, fun)
      || list.any(clauses, fn(c) {
        let CClause(_, g, b) = c
        has_call(g, mod, fun) || has_call(b, mod, fun)
      })
    CApply(_, args) -> list.any(args, has_call(_, mod, fun))
    CFun(_, b) -> has_call(b, mod, fun)
    CCons(h, t) -> has_call(h, mod, fun) || has_call(t, mod, fun)
    CTuple(xs) -> list.any(xs, has_call(_, mod, fun))
    CValues(xs) -> list.any(xs, has_call(_, mod, fun))
    _ -> False
  }
}

const rt_simd_atom = "twocore@runtime@rt_simd"

/// A single 2-v128-param SIMD binary function `f(a, b) = Simd(op, [a, b])`.
fn simd_binop_module(op: ir.SimdOp) -> ir.Module {
  module_with(ir.Function(
    name: "f",
    params: [ir.Local("a", ir.TV128), ir.Local("b", ir.TV128)],
    result: [ir.TV128],
    locals: [],
    body: ir.Simd(op, [ir.Var("a"), ir.Var("b")]),
  ))
}

/// The `SimdOp → rt_simd` chokepoint names EXPORTED `rt_simd` heads (the fixed-width-SIMD spec
/// mnemonics, §5.4.9) — a representative spread across every family. A name/family drift makes the
/// export vanish and fails here (ties the table to the real artefact, like `num_op_name`).
pub fn simd_op_name_matches_rt_simd_test() {
  // Force `rt_simd` loaded.
  assert rt_simd_reachable()
  let m = atom.create(rt_simd_atom)
  let cases = [
    #(ir.SAdd(ir.I32x4), 2),
    #(ir.SSub(ir.I8x16), 2),
    #(ir.SMul(ir.I16x8), 2),
    #(ir.SNeg(ir.I64x2), 1),
    #(ir.SAddSatS(ir.I8x16), 2),
    #(ir.SSubSatU(ir.I16x8), 2),
    #(ir.SMinS(ir.I32x4), 2),
    #(ir.SMaxU(ir.I8x16), 2),
    #(ir.SAvgrU(ir.I16x8), 2),
    #(ir.SShl(ir.I32x4), 2),
    #(ir.SShrS(ir.I64x2), 2),
    #(ir.SPopcnt(ir.I8x16), 1),
    #(ir.SEq(ir.I32x4), 2),
    #(ir.SLtS(ir.I16x8), 2),
    #(ir.SGeU(ir.I8x16), 2),
    #(ir.VNot, 1),
    #(ir.VBitselect, 3),
    #(ir.VAnyTrue, 1),
    #(ir.SAllTrue(ir.I32x4), 1),
    #(ir.SBitmask(ir.I8x16), 1),
    #(ir.SSplat(ir.F64x2), 1),
    #(ir.SExtractLane(ir.I32x4, 0), 2),
    #(ir.SExtractLaneS(ir.I8x16, 0), 2),
    #(ir.SReplaceLane(ir.I16x8, 0), 3),
    #(ir.SFAdd(ir.F32x4), 2),
    #(ir.SFMul(ir.F64x2), 2),
    #(ir.SFPMin(ir.F32x4), 2),
    #(ir.SFSqrt(ir.F64x2), 1),
    #(ir.SFEq(ir.F32x4), 2),
    #(ir.SNarrow(ir.I16x8, True), 2),
    #(ir.SExtend(ir.I8x16, ir.Low, True), 1),
    #(ir.SExtend(ir.I32x4, ir.High, False), 1),
    #(ir.SExtMul(ir.I16x8, ir.Low, False), 2),
    #(ir.SExtAddPairwise(ir.I8x16, True), 1),
    #(ir.STruncSatF32x4S, 1),
    #(ir.STruncSatF64x2UZero, 1),
    #(ir.SConvertF32x4I32x4U, 1),
    #(ir.SConvertF64x2LowI32x4S, 1),
    #(ir.SDemoteF64x2Zero, 1),
    #(ir.SPromoteLowF32x4, 1),
    #(ir.SDotI16x8S, 2),
    #(ir.SQ15MulrSatS, 2),
    #(ir.SSwizzle, 2),
  ]
  list.each(cases, fn(c) {
    let #(op, arity) = c
    assert function_exported(m, atom.create(emit_core.simd_op_name(op)), arity)
      == True
  })
}

/// Force `rt_simd` module-loaded (any call does it); returns True.
fn rt_simd_reachable() -> Bool {
  function_exported(atom.create(rt_simd_atom), atom.create("i32x4_add"), 2)
}

/// A pure SIMD op → a BARE `call '<rt_simd>':'<name>'(args…)` (no `case`, no `raise` — I3 total),
/// and BYTE-IDENTICAL under Cell vs Threaded (a v128 op is state-neutral, §A.3). Cite §5.4.
pub fn simd_pure_op_is_bare_call_test() {
  let cell = body_of_b(simd_binop_module(ir.SAdd(ir.I32x4)), "f", binding())
  let assert CCall(CAtom(m), CAtom("i32x4_add"), [CVar("a"), CVar("b")]) = cell
  assert m == rt_simd_atom
  // State-neutral: identical body under Threaded.
  let threaded =
    body_of_b(simd_binop_module(ir.SAdd(ir.I32x4)), "f", threaded())
  assert cell == threaded
}

/// A SIMD-arithmetic-only function stays PURE `'f'/n` under Threaded (NOT `'f'/(n+1)`) — `Simd` is
/// not a state-reaching seed (the I7-neutral classification, §A.3). A memory op WOULD widen it.
pub fn simd_arith_is_state_neutral_test() {
  let assert FunDef(FName("f", 2), _) =
    fdef_of(simd_binop_module(ir.SAdd(ir.I32x4)), "f", threaded())
}

/// `SimdShuffle(lanes, a, b)` → `call '<rt_simd>':'i8x16_shuffle'(A, B, [l0,…,l15])` — the 16
/// immediates as a proper Core list AFTER the two operands (spec `i8x16.shuffle`).
pub fn simd_shuffle_golden_test() {
  let lanes = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  let m =
    module_with(ir.Function(
      name: "f",
      params: [ir.Local("a", ir.TV128), ir.Local("b", ir.TV128)],
      result: [ir.TV128],
      locals: [],
      body: ir.SimdShuffle(lanes, ir.Var("a"), ir.Var("b")),
    ))
  let assert CCall(
    CAtom(mod),
    CAtom("i8x16_shuffle"),
    [CVar("a"), CVar("b"), lane_list],
  ) = body_of_b(m, "f", binding())
  assert mod == rt_simd_atom
  // The lane list has exactly 16 CInt elements.
  assert core_list_ints(lane_list) == lanes
}

/// Extract the `Int`s from a Core proper list of `CInt`s (for the shuffle-immediate assertion).
fn core_list_ints(e: CExpr) -> List(Int) {
  case e {
    CNil -> []
    CCons(CInt(n), t) -> [n, ..core_list_ints(t)]
    _ -> panic as "not a list of CInt"
  }
}

/// The lane immediate rides where the FROZEN `rt_simd` head expects: `extract_lane(vec, lane)` (last)
/// vs `replace_lane(vec, lane, x)` (MIDDLE — the actual rt_simd signature, superseding the stale doc).
pub fn simd_lane_immediate_placement_test() {
  // extract: [vec, lane]
  let ext =
    module_with(ir.Function(
      name: "f",
      params: [ir.Local("v", ir.TV128)],
      result: [ir.TI32],
      locals: [],
      body: ir.Simd(ir.SExtractLane(ir.I32x4, 2), [ir.Var("v")]),
    ))
  let assert CCall(CAtom(_), CAtom("i32x4_extract_lane"), [CVar("v"), CInt(2)]) =
    body_of_b(ext, "f", binding())
  // replace: [vec, lane, x]
  let rep =
    module_with(ir.Function(
      name: "f",
      params: [ir.Local("v", ir.TV128), ir.Local("x", ir.TI32)],
      result: [ir.TV128],
      locals: [],
      body: ir.Simd(ir.SReplaceLane(ir.I8x16, 3), [ir.Var("v"), ir.Var("x")]),
    ))
  let assert CCall(
    CAtom(_),
    CAtom("i8x16_replace_lane"),
    [CVar("v"), CInt(3), CVar("x")],
  ) = body_of_b(rep, "f", binding())
}

/// `v128.const` → a pure 16-byte binary literal (the raw LE bytes, D5) — NOT a `call` (const-
/// foldable, D3a-trivially-clean, like `ConstF32`).
pub fn const_v128_is_binary_literal_test() {
  let m =
    module_with(ir.Function(
      name: "f",
      params: [],
      result: [ir.TV128],
      locals: [],
      body: ir.Return([
        ir.ConstV128(<<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>),
      ]),
    ))
  let assert CBinary(segs) = body_of_b(m, "f", binding())
  assert list.length(segs) == 16
}

/// `SimdStore` (`v128.store`) → an EAGER trapping `store_bytes(Addr, V, Off)` zero-effect (the 16
/// bytes ARE the run; no partial write, H6). Cell: `{ok,_}`→discard, `{error,E}`→raise, sequenced.
pub fn simd_store_is_trapping_effect_test() {
  let b = binding()
  let m =
    op_module(
      "f",
      [ir.Local("a", ir.TI32), ir.Local("v", ir.TV128)],
      [],
      ir.Let([], ir.SimdStore(0, ir.Var("a"), ir.Var("v"), 0), ir.Values([])),
    )
  let body = body_of_b(m, "f", b)
  assert has_call(body, b.mem_module, "store_bytes")
  // No lane assembly on a plain store (the v128 is the bytes).
  assert has_call(body, rt_simd_atom, "i8x16_shuffle") == False
}

/// `SimdLoad(V128)` (`v128.load`) → a trapping `load_bytes(Addr, Off, 16)` value (the slice IS the
/// v128) — the `{ok, B}`/`{error, E}`-`case`-and-`raise`, read-only.
pub fn simd_load_v128_is_trapping_value_test() {
  let b = binding()
  let m =
    op_module(
      "f",
      [ir.Local("a", ir.TI32)],
      [ir.TV128],
      ir.SimdLoad(0, ir.LoadV128, ir.Var("a"), 0),
    )
  let assert CLet([_r], CCase(load_call, _clauses), _rest) =
    body_of_b(m, "f", b)
  let assert CCall(
    CAtom(mem),
    CAtom("load_bytes"),
    [CVar("a"), CInt(0), CInt(16)],
  ) = load_call
  assert mem == b.mem_module
}

/// `SimdLoad(Splat(32))` composes the bounds-checked scalar `rt_mem.load(4, …)` with the pure
/// `rt_simd:i32x4_splat` (S4) — the splat is on the `{ok,_}` path (unreachable if the load faults).
pub fn simd_load_splat_composes_test() {
  let b = binding()
  let m =
    op_module(
      "f",
      [ir.Local("a", ir.TI32)],
      [ir.TV128],
      ir.SimdLoad(0, ir.LoadSplat(32), ir.Var("a"), 0),
    )
  let body = body_of_b(m, "f", b)
  assert has_call(body, b.mem_module, "load")
  assert has_call(body, rt_simd_atom, "i32x4_splat")
}

/// `SimdStoreLane(8)` runs the PURE `rt_simd:v128_extract_lane_bits(v, lane, 8)` FIRST, then the
/// trapping scalar `rt_mem.store(1, …)` (S4) — the extract is pure, so ordering it before the
/// bounds-checked store is sound (no observable effect precedes the trap, H6).
pub fn simd_store_lane_extract_then_store_test() {
  let b = binding()
  let m =
    op_module(
      "f",
      [ir.Local("a", ir.TI32), ir.Local("v", ir.TV128)],
      [],
      ir.Let(
        [],
        ir.SimdStoreLane(0, 8, ir.Var("a"), 0, 2, ir.Var("v")),
        ir.Values([]),
      ),
    )
  let body = body_of_b(m, "f", b)
  assert has_call(body, rt_simd_atom, "v128_extract_lane_bits")
  assert has_call(body, b.mem_module, "store")
}

/// An `Idx64` memory seeds `fresh64(Min, Max, Mem64Cap)` at `instantiate` (§D/S9); an `Idx32` memory
/// seeds the BYTE-IDENTICAL Phase-5 `fresh(Min, Max, SafeCap)`. The op sites are unchanged either way.
pub fn mem64_fresh64_in_instantiate_test() {
  let b = binding()
  let mk = fn(idx) {
    ir.Module(
      name: "twocore@test@m",
      uses_numerics: True,
      memories: [ir.MemoryDecl(1, option.None, idx)],
      globals: [],
      imports: [],
      functions: [],
      exports: [],
      data_segments: [],
      tables: [],
      elements: [],
      start: option.None,
      tags: [],
    )
  }
  let inst = fn(idx) {
    let assert Ok(m) = emit_core.emit_module(mk(idx), b)
    let assert Ok(FunDef(_, CFun(_, body))) =
      list.find(m.defs, fn(d) {
        let FunDef(FName(n, _), _) = d
        n == "instantiate"
      })
    body
  }
  // Idx64 → fresh64 with the mem64 cap; NO plain `fresh` for the 64-bit memory.
  assert has_call(inst(ir.Idx64), b.mem_module, "fresh64")
  // Idx32 → the byte-identical `fresh`; NO fresh64.
  assert has_call(inst(ir.Idx32), b.mem_module, "fresh")
  assert has_call(inst(ir.Idx32), b.mem_module, "fresh64") == False
}

/// memory64 is transparent at the op sites (§D): a `MemLoad` on an `Idx64` memory emits the SAME
/// Core as on an `Idx32` memory (the width lives in the handle, not an op argument).
pub fn mem64_op_sites_byte_identical_test() {
  let b = binding()
  let mk = fn(idx) {
    ir.Module(
      name: "twocore@test@m",
      uses_numerics: True,
      memories: [ir.MemoryDecl(1, option.None, idx)],
      globals: [],
      imports: [],
      functions: [
        ir.Function(
          name: "f",
          params: [ir.Local("a", ir.TI64)],
          result: [ir.TI32],
          locals: [],
          body: ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("a"), 0, ir.TI32),
        ),
      ],
      exports: [],
      data_segments: [],
      tables: [],
      elements: [],
      start: option.None,
      tags: [],
    )
  }
  assert body_of_b(mk(ir.Idx32), "f", b) == body_of_b(mk(ir.Idx64), "f", b)
}

/// `CallImport(slot, ty, args)` → read the closure from `rt_state:func_import_at(slot)`, then
/// dispatch via `link:call_import(Closure, [Args…])` (S5/D3a) — a HANDED-IN capability, and NO
/// `erlang:apply` anywhere on the path. The result LIST is unpacked to `len(ty.results)` values.
pub fn call_import_closure_dispatch_test() {
  let b = binding()
  let ty = ir.FuncType([ir.TI32], [ir.TI32])
  let m =
    module_with_import(
      ir.Function(
        name: "f",
        params: [ir.Local("x", ir.TI32)],
        result: [ir.TI32],
        locals: [],
        body: ir.CallImport(0, ty, [ir.Var("x")]),
      ),
      ir.ImportFn("modA", "g", ty),
    )
  let body = body_of_b(m, "f", b)
  // The closure is read from the state seam, and dispatched through `link.call_import`.
  assert has_call(body, b.state_module, "func_import_at")
  assert has_call(body, "twocore@runtime@link", "call_import")
  // NEVER an `erlang:apply` (the S5 arity-safe seam, not the forbidden 2-/3-arg apply).
  assert has_call(body, "erlang", "apply") == False
}

/// A cross-module-function-import module seeds its func-import vector at `instantiate`:
/// `rt_state:seed_func_imports([link:provided_func_call(Imp0)])` (S5), and the `instantiate` entry
/// is arity 1 (the positional `Imports` list carries the closure).
pub fn call_import_seeds_func_import_vector_test() {
  let b = binding()
  let ty = ir.FuncType([ir.TI32], [ir.TI32])
  let m =
    module_with_import(
      ir.Function(
        name: "f",
        params: [ir.Local("x", ir.TI32)],
        result: [ir.TI32],
        locals: [],
        body: ir.CallImport(0, ty, [ir.Var("x")]),
      ),
      ir.ImportFn("modA", "g", ty),
    )
  let assert Ok(cm) = emit_core.emit_module(m, b)
  let assert Ok(FunDef(FName("instantiate", 1), CFun(_, inst_body))) =
    list.find(cm.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == "instantiate"
    })
  assert has_call(inst_body, b.state_module, "seed_func_imports")
  assert has_call(inst_body, "twocore@runtime@link", "provided_func_call")
}

/// A module importing a function it NEVER calls stays byte-neutral (no `CallImport` ⇒ no
/// func-import vector, `instantiate/0`) — the I7 neutrality that keeps the whole Phase-1..5 corpus
/// unchanged through the func-import surface.
pub fn import_without_call_is_byte_neutral_test() {
  let b = binding()
  let ty = ir.FuncType([ir.TI32], [ir.TI32])
  let m =
    module_with_import(
      ir.Function(
        name: "f",
        params: [ir.Local("x", ir.TI32)],
        result: [ir.TI32],
        locals: [],
        body: ir.Return([ir.Var("x")]),
      ),
      ir.ImportFn("modA", "g", ty),
    )
  let assert Ok(cm) = emit_core.emit_module(m, b)
  // No CallImport ⇒ `instantiate/0` (not /1) and no func-import seed.
  let assert Ok(FunDef(FName("instantiate", 0), CFun(_, inst_body))) =
    list.find(cm.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == "instantiate"
    })
  assert has_call(inst_body, b.state_module, "seed_func_imports") == False
}

/// A `v128` global routes `global.get`/`global.set` through the BOXED `ref_global_get`/`set`
/// accessor (S6), NOT the numeric raw-bit `global_get`/`set` (which stays byte-identical for D5).
pub fn v128_global_routes_boxed_test() {
  let b = binding()
  let g =
    ir.GlobalDecl(
      "gv",
      ir.TV128,
      True,
      ir.Values([
        ir.ConstV128(<<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>),
      ]),
    )
  let mk = fn(body, result, params) {
    ir.Module(
      name: "twocore@test@gv",
      uses_numerics: True,
      memories: [],
      globals: [g],
      imports: [],
      functions: [
        ir.Function(
          name: "f",
          params: params,
          result: result,
          locals: [],
          body: body,
        ),
      ],
      exports: [],
      data_segments: [],
      tables: [],
      elements: [],
      start: option.None,
      tags: [],
    )
  }
  // get → ref_global_get, NOT global_get
  let get_body = body_of_b(mk(ir.GlobalGet("gv"), [ir.TV128], []), "f", b)
  assert has_call(get_body, b.state_module, "ref_global_get")
  assert has_call(get_body, b.state_module, "global_get") == False
  // set → ref_global_set
  let set_body =
    body_of_b(
      mk(ir.Let([], ir.GlobalSet("gv", ir.Var("v")), ir.Values([])), [], [
        ir.Local("v", ir.TV128),
      ]),
      "f",
      b,
    )
  assert has_call(set_body, b.state_module, "ref_global_set")
}

/// A single-function module importing `imp`, exporting `f` — for the `CallImport` goldens.
fn module_with_import(f: ir.Function, imp: ir.ImportDecl) -> ir.Module {
  ir.Module(
    name: "twocore@test@" <> f.name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [imp],
    functions: [f],
    exports: [ir.ExportFn(f.name, f.name)],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}
