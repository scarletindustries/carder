//// Strawman acceptance test for the frozen IR (unit 01).
////
//// This constructs the three Phase-1 acceptance programs — `add`, `sum_to` (a loop),
//// and `fib` (an `if` + direct self-call + recursion) — as hand-written `ir.gleam`
//// VALUES (full `Module`/`Function`/`Expr` trees). It exists to PROVE that the frozen
//// types can express the Phase-1 slice cleanly *before* any other unit builds on them
//// (this is open question #4 from the unit doc, walked by hand). It mirrors the
//// hand-authored golden `.ir` fixtures under `test/carder/ir/golden/`.
////
//// The assertions are against the documented contract of `ir.signature/1` (the derived
//// nameless signature of each function) and the capability axes of each `Module`
//// (D5) — not against any printer output, so this is not a change-detector test.

import carder/ir
import gleam/option

// ───────────────────────── add(i32, i32) -> i32 ─────────────────────────

/// Builds `add`: `return (i.add.32(%p0, %p1))`, in strict ANF (the op is `let`-bound).
fn add_function() -> ir.Function {
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

/// Builds the `add` module: numerics on, memory off (D5), exporting `add`.
fn add_module() -> ir.Module {
  ir.Module(
    name: "add",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [add_function()],
    exports: [ir.ExportFn("add", "add")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

pub fn add_signature_test() {
  // signature/1 derives the nameless FuncType from the named params + result.
  assert ir.signature(add_function())
    == ir.FuncType(params: [ir.TI32, ir.TI32], results: [ir.TI32])
}

pub fn add_module_capabilities_test() {
  let m = add_module()
  // Numerics opt-in is on; linear memory is a SEPARATE Option and is off (D5).
  assert m.uses_numerics == True
  assert m.memories == []
  assert m.exports == [ir.ExportFn(export_name: "add", fn_name: "add")]
}

// ───────────────────────── sum_to(n) -> i64 (loop) ─────────────────────────

/// Builds `sum_to`: a `Loop` carrying named iteration vars `%i`/`%acc`. Each iteration
/// compares, then either `continue`s (rebinding the loop vars) or `break`s with the
/// accumulator — a constant-space tail-recursive shape.
fn sum_to_function() -> ir.Function {
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

/// Builds the `sum_to` module (the grammar's `@loop` example).
fn sum_to_module() -> ir.Module {
  ir.Module(
    name: "loop",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [sum_to_function()],
    exports: [ir.ExportFn("sum_to", "sum_to")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

pub fn sum_to_signature_test() {
  assert ir.signature(sum_to_function())
    == ir.FuncType(params: [ir.TI64], results: [ir.TI64])
}

pub fn sum_to_module_capabilities_test() {
  let m = sum_to_module()
  assert m.uses_numerics == True
  assert m.memories == []
  assert m.exports == [ir.ExportFn(export_name: "sum_to", fn_name: "sum_to")]
}

// ───────────────────────── fib(n) -> i64 (if + recursion) ─────────────────────────

/// Builds `fib`: `if n < 2 { return n } else { return fib(n-1) + fib(n-2) }`, using a
/// direct self-`CallDirect("fib", ..)` to prove recursion is expressible in the IR.
fn fib_function() -> ir.Function {
  ir.Function(
    name: "fib",
    params: [ir.Local("p0", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Let(
      ["c"],
      ir.Num(ir.ILtU(ir.W64), [ir.Var("p0"), ir.ConstI64(2)]),
      ir.If(
        cond: ir.Var("c"),
        result: [ir.TI64],
        then_branch: ir.Return([ir.Var("p0")]),
        else_branch: ir.Let(
          ["n1"],
          ir.Num(ir.ISub(ir.W64), [ir.Var("p0"), ir.ConstI64(1)]),
          ir.Let(
            ["f1"],
            ir.CallDirect("fib", [ir.Var("n1")]),
            ir.Let(
              ["n2"],
              ir.Num(ir.ISub(ir.W64), [ir.Var("p0"), ir.ConstI64(2)]),
              ir.Let(
                ["f2"],
                ir.CallDirect("fib", [ir.Var("n2")]),
                ir.Let(
                  ["r"],
                  ir.Num(ir.IAdd(ir.W64), [ir.Var("f1"), ir.Var("f2")]),
                  ir.Return([ir.Var("r")]),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  )
}

/// Builds the `fib` module.
fn fib_module() -> ir.Module {
  ir.Module(
    name: "fib",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [fib_function()],
    exports: [ir.ExportFn("fib", "fib")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

pub fn fib_signature_test() {
  assert ir.signature(fib_function())
    == ir.FuncType(params: [ir.TI64], results: [ir.TI64])
}

pub fn fib_module_capabilities_test() {
  let m = fib_module()
  assert m.uses_numerics == True
  assert m.memories == []
  assert m.exports == [ir.ExportFn(export_name: "fib", fn_name: "fib")]
}
