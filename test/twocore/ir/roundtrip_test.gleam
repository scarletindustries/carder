//// Round-trip + golden suite for the `.ir` printer & parser (Unit 02).
////
//// Proves the D7 inter-stage contract three ways, none of which is a change-detector
//// test:
////
//// 1. **Round-trip property** `parse(print(m)) == m` over a corpus that hand-builds the
////    FULL IR surface (every `Expr`/`Value`/`NumOp`/`ConvOp`/`TermOp`/`TrapReason`,
////    memory ops, globals, multi-value, and float consts including NaN payloads and
////    `-0.0`). Because the frozen IR stores float constants as raw `Int` bits, plain
////    structural `==` on `ir.Module` already compares them BIT-EXACTLY — so `==` (and
////    hence `module_equal`) is the correct equality here (NaN ≠ NaN under native float
////    `==`, but the IR never uses native floats). This is the D7 invariant.
//// 2. **Golden suite** (the INDEPENDENT oracle): the HAND-AUTHORED `.ir` files under
////    `golden/` — the three Phase-1 programs (`add`/`sum_to`/`fib`) plus the Phase-2
////    `mem_table` (table/elem/start, mem.size/grow, a result-typed sign-extending load, a
////    float comparison, a trapping convert) — written by reading the grammar, never
////    printer-generated — parse to the expected `Module` values, and those values re-print
////    + re-parse stably. Hand authoring is what defeats a printer+parser that collude on
////    the same wrong grammar.
//// 3. **Negative corpus**: truncated input, a wrong sigil, an unknown op spelling, a
////    missing `(`, an unterminated block, a bad escape, a stray char — each returns a
////    typed `ParseError` (asserted by variant) and NONE panics (totality, D4).

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import twocore/ir
import twocore/ir/parser
import twocore/ir/printer

// ───────────────────────────── module_equal (deliverable) ─────────────────────────

/// Bit-pattern numeric equality for IR modules.
///
/// Because D5 stores float constants as raw `Int` bit patterns (`ConstF32(bits)` /
/// `ConstF64(bits)`), comparing the stored `Int` bits IS the correct, exact comparison
/// — NaN payloads and `-0.0` are preserved and distinguished, and `+0.0`/`-0.0` are NOT
/// conflated (unlike a native-float `==`, where `NaN != NaN` and `-0.0 == 0.0`). Gleam's
/// structural `==` on `ir.Module` therefore already compares modules bit-exactly; this
/// function is that comparison, named for clarity and so callers cannot accidentally
/// reach for a float `==`. Use THIS (or `==`) anywhere two IR modules are compared.
///
/// Parameters: `a`, `b` — the two modules. Returns `True` iff they are structurally
/// (and hence bit-pattern) equal. Total — never fails, never panics.
pub fn module_equal(a: ir.Module, b: ir.Module) -> Bool {
  a == b
}

// ───────────────────────────── golden module builders ─────────────────────────────
// The expected `Module` values for the three hand-authored goldens, built INDEPENDENTLY
// of the printer (mirroring `test/twocore/ir/strawman_test.gleam`).

/// Expected `Module` for `golden/add.ir`.
fn add_module() -> ir.Module {
  ir.Module(
    name: "add",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [
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
      ),
    ],
    exports: [ir.ExportFn("add", "add")],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
    tags: [],
  )
}

/// Expected `Module` for `golden/sum_to.ir` (the grammar's `@loop` example).
fn sum_to_module() -> ir.Module {
  ir.Module(
    name: "loop",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [
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
      ),
    ],
    exports: [ir.ExportFn("sum_to", "sum_to")],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
    tags: [],
  )
}

/// Expected `Module` for `golden/fib.ir`.
fn fib_module() -> ir.Module {
  ir.Module(
    name: "fib",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [
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
      ),
    ],
    exports: [ir.ExportFn("fib", "fib")],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
    tags: [],
  )
}

// ───────────────────────────── golden file reading ─────────────────────────────

/// Reads a file as a binary. `file:read_file/1` returns `{ok, Binary}` / `{error, _}`,
/// which is exactly Gleam's `Ok`/`Error` representation. (Test-only; `let assert` here is
/// fine — it asserts the fixture exists, and is not on the parser's untrusted-input path.)
@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

/// Reads a golden `.ir` fixture (relative to the project root, the `gleam test` cwd).
fn read_golden(name: String) -> String {
  let assert Ok(bits) = read_file("test/twocore/ir/golden/" <> name)
  let assert Ok(text) = bit_array.to_string(bits)
  text
}

// ───────────────────────────── round-trip helpers ─────────────────────────────

/// Wraps an expression as the body of a minimal 0-arg function in a minimal module, so a
/// single `Expr` can be exercised through the full module printer/parser.
fn expr_module(name: String, body: ir.Expr) -> ir.Module {
  ir.Module(
    name: name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [
      ir.Function(name: "f", params: [], result: [], locals: [], body: body),
    ],
    exports: [],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
    tags: [],
  )
}

/// Asserts the D7 round-trip property for one module: `parse(print(m)) == Ok(m)`. Uses
/// structural `==` (i.e. `module_equal`) so float constants are compared bit-exactly.
fn check_roundtrip(m: ir.Module) -> Nil {
  assert parser.parse_module(printer.print_module(m)) == Ok(m)
}

// ───────────────────────────── op corpora ─────────────────────────────

/// Every integer `NumOp` constructor at width `w`.
fn int_ops(w: ir.IntWidth) -> List(ir.NumOp) {
  [
    ir.IAdd(w),
    ir.ISub(w),
    ir.IMul(w),
    ir.IDivS(w),
    ir.IDivU(w),
    ir.IRemS(w),
    ir.IRemU(w),
    ir.IAnd(w),
    ir.IOr(w),
    ir.IXor(w),
    ir.IShl(w),
    ir.IShrS(w),
    ir.IShrU(w),
    ir.IRotl(w),
    ir.IRotr(w),
    ir.IClz(w),
    ir.ICtz(w),
    ir.IPopcnt(w),
    ir.IEqz(w),
    ir.IEq(w),
    ir.INe(w),
    ir.ILtS(w),
    ir.ILtU(w),
    ir.IGtS(w),
    ir.IGtU(w),
    ir.ILeS(w),
    ir.ILeU(w),
    ir.IGeS(w),
    ir.IGeU(w),
  ]
}

/// Every float `NumOp` constructor at width `w` — the Phase-1 binary arithmetic plus the
/// Phase-2 unary ops and the six comparisons (`«IR2-FROZEN»`).
fn float_ops(w: ir.FloatWidth) -> List(ir.NumOp) {
  [
    ir.FAdd(w),
    ir.FSub(w),
    ir.FMul(w),
    ir.FDiv(w),
    ir.FMin(w),
    ir.FMax(w),
    ir.FAbs(w),
    ir.FNeg(w),
    ir.FCeil(w),
    ir.FFloor(w),
    ir.FTrunc(w),
    ir.FNearest(w),
    ir.FSqrt(w),
    ir.FCopysign(w),
    ir.FEq(w),
    ir.FNe(w),
    ir.FLt(w),
    ir.FGt(w),
    ir.FLe(w),
    ir.FGe(w),
  ]
}

/// Every `NumOp` constructor at both widths (29 integer + 20 float per width = 98 in total).
fn all_numops() -> List(ir.NumOp) {
  list.flatten([
    int_ops(ir.W32),
    int_ops(ir.W64),
    float_ops(ir.FW32),
    float_ops(ir.FW64),
  ])
}

/// Every `ConvOp` constructor, covering each width/sign combination.
fn all_convops() -> List(ir.ConvOp) {
  [
    ir.I32WrapI64,
    ir.I64ExtendI32S,
    ir.I64ExtendI32U,
    ir.I32Extend8S,
    ir.I32Extend16S,
    ir.I64Extend8S,
    ir.I64Extend16S,
    ir.I64Extend32S,
    ir.TruncSatS(ir.FW32, ir.W32),
    ir.TruncSatS(ir.FW64, ir.W64),
    ir.TruncSatS(ir.FW32, ir.W64),
    ir.TruncSatS(ir.FW64, ir.W32),
    ir.TruncSatU(ir.FW32, ir.W32),
    ir.TruncSatU(ir.FW64, ir.W64),
    ir.ReinterpretFToI(ir.FW32),
    ir.ReinterpretFToI(ir.FW64),
    ir.ReinterpretIToF(ir.W32),
    ir.ReinterpretIToF(ir.W64),
    ir.BoxInt(ir.W32),
    ir.BoxInt(ir.W64),
    ir.UnboxInt(ir.W32),
    ir.UnboxInt(ir.W64),
    ir.BoxFloat(ir.FW32),
    ir.BoxFloat(ir.FW64),
    ir.UnboxFloat(ir.FW32),
    ir.UnboxFloat(ir.FW64),
    // Phase-2 (`«IR2-FROZEN»`): trapping float→int truncation, int→float convert (both
    // signs, both widths each), and the two float-width changes.
    ir.TruncS(ir.FW32, ir.W32),
    ir.TruncS(ir.FW64, ir.W32),
    ir.TruncS(ir.FW32, ir.W64),
    ir.TruncS(ir.FW64, ir.W64),
    ir.TruncU(ir.FW32, ir.W32),
    ir.TruncU(ir.FW64, ir.W32),
    ir.TruncU(ir.FW32, ir.W64),
    ir.TruncU(ir.FW64, ir.W64),
    ir.ConvertS(ir.W32, ir.FW32),
    ir.ConvertS(ir.W64, ir.FW32),
    ir.ConvertS(ir.W32, ir.FW64),
    ir.ConvertS(ir.W64, ir.FW64),
    ir.ConvertU(ir.W32, ir.FW32),
    ir.ConvertU(ir.W64, ir.FW32),
    ir.ConvertU(ir.W32, ir.FW64),
    ir.ConvertU(ir.W64, ir.FW64),
    ir.F32DemoteF64,
    ir.F64PromoteF32,
  ]
}

/// Every `TrapReason` constructor (Phase-1 five + the four Phase-2 additions, `«IR2-FROZEN»`,
/// + the Phase-3 runtime-only `FuelExhausted`). Including `FuelExhausted` here proves the new
/// printer/parser arms round-trip; a real lowering never emits `Trap(FuelExhausted)`, but the
/// printer/parser handle every `TrapReason` exhaustively.
fn all_trapreasons() -> List(ir.TrapReason) {
  [
    ir.IntDivByZero,
    ir.IntOverflow,
    ir.Unreachable,
    ir.IndirectCallTypeMismatch,
    ir.MemoryOutOfBounds,
    ir.InvalidConversionToInteger,
    ir.UndefinedElement,
    ir.UninitializedElement,
    ir.TableOutOfBounds,
    ir.FuelExhausted,
  ]
}

/// A representative instance of (nearly) every `Expr` variant, for the round-trip.
fn expr_corpus() -> List(ir.Expr) {
  [
    // Values: empty (multi-value 0) and a mixed multi-value list with float consts.
    ir.Values([]),
    ir.Values([
      ir.ConstI32(1),
      ir.ConstI64(2),
      ir.ConstF32(0x7fc00000),
      ir.ConstF64(0x8000000000000000),
    ]),
    // term ops (Phase-8 unit 01: the full TermOp surface round-trips textually)
    ir.TermOp(ir.MakeTuple, [ir.Var("a"), ir.Var("b")]),
    ir.TermOp(ir.TupleGet(3), [ir.Var("t")]),
    ir.TermOp(ir.MakeCons, [ir.Var("h"), ir.Var("t")]),
    ir.TermOp(ir.TupleSize, [ir.Var("t")]),
    ir.TermOp(ir.ListHead, [ir.Var("l")]),
    ir.TermOp(ir.ListTail, [ir.Var("l")]),
    ir.TermOp(ir.IsEmptyList, [ir.Var("l")]),
    // map ops (Phase-8 unit 03: the full MapOp surface round-trips textually — the dotted
    // keyword spellings `map.new`/`map.get`/… plus the map-first operand order).
    ir.MapOp(ir.MapNew, []),
    ir.MapOp(ir.MapGet, [ir.Var("m"), ir.ConstAtom("k"), ir.ConstI32(0)]),
    ir.MapOp(ir.MapPut, [ir.Var("m"), ir.ConstAtom("k"), ir.Var("v")]),
    ir.MapOp(ir.MapHas, [ir.Var("m"), ir.ConstAtom("k")]),
    ir.MapOp(ir.MapRemove, [ir.Var("m"), ir.ConstAtom("k")]),
    ir.MapOp(ir.MapSize, [ir.Var("m")]),
    // Phase-8 term literals as forwarded values: a literal atom and a literal binary.
    ir.Values([ir.ConstAtom("ok"), ir.ConstBinary(<<"hi">>)]),
    ir.Values([ir.ConstAtom("true"), ir.ConstBinary(<<>>)]),
    // memory: size/grow (Phase-2), a plain i32.load and a sign-extending i64.load8_s
    // (distinct result widths prove the new `result` field round-trips and discriminates
    // i32.load8_s vs i64.load8_s — same bytes+sign, different result type).
    ir.MemSize(0),
    ir.MemGrow(0, ir.ConstI32(1)),
    ir.MemGrow(0, ir.Var("delta")),
    ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("a"), 0, ir.TI32),
    ir.MemLoad(0, ir.MemAccess(1, True), ir.Var("a"), 8, ir.TI64),
    ir.MemStore(0, ir.MemAccess(8, False), ir.Var("a"), ir.Var("v"), 16),
    // globals
    ir.GlobalGet("g"),
    ir.GlobalSet("g", ir.ConstI32(5)),
    // Phase-8 native closures (unit 02): both nodes round-trip textually. `make_closure`
    // spells the target `@fn`, the capture value list, and the mandatory `arity=<n>` decorator
    // (incl. the empty-captures and `arity=0` edges); `call_closure` spells the fun value + args.
    ir.MakeClosure("f", [ir.Var("c")], 1),
    ir.MakeClosure("add", [ir.ConstI32(10), ir.ConstI32(20)], 2),
    ir.MakeClosure("k", [ir.Var("c")], 0),
    ir.MakeClosure("g", [], 3),
    ir.CallClosure(ir.Var("g"), [ir.Var("x")]),
    ir.CallClosure(ir.Var("g"), []),
    // Phase-8 term classification + native number arithmetic (unit 06): all three nodes round-trip
    // textually. `term_test.<kind>` spans every `TermKind` (9); `term_tag` takes one value;
    // `num_term.<op>` spans every `NumTermOp` (8 — arithmetic + compare), each with two operands.
    ir.TermTest(ir.IsInt, ir.Var("x")),
    ir.TermTest(ir.IsFloat, ir.Var("x")),
    ir.TermTest(ir.IsNumber, ir.Var("x")),
    ir.TermTest(ir.IsAtom, ir.Var("x")),
    ir.TermTest(ir.IsBinary, ir.Var("x")),
    ir.TermTest(ir.IsTuple, ir.Var("x")),
    ir.TermTest(ir.IsMap, ir.Var("x")),
    ir.TermTest(ir.IsFun, ir.Var("x")),
    ir.TermTest(ir.IsList, ir.Var("x")),
    ir.TermTag(ir.Var("x")),
    ir.TermTag(ir.ConstI32(7)),
    ir.NumTerm(ir.NAdd, ir.Var("a"), ir.Var("b")),
    ir.NumTerm(ir.NSub, ir.Var("a"), ir.ConstI32(1)),
    ir.NumTerm(ir.NMul, ir.Var("a"), ir.Var("b")),
    ir.NumTerm(ir.NLt, ir.Var("a"), ir.Var("b")),
    ir.NumTerm(ir.NLe, ir.Var("a"), ir.Var("b")),
    ir.NumTerm(ir.NGt, ir.Var("a"), ir.Var("b")),
    ir.NumTerm(ir.NGe, ir.Var("a"), ir.Var("b")),
    ir.NumTerm(ir.NEq, ir.Var("a"), ir.Var("b")),
    // calls
    ir.CallDirect("foo", [ir.Var("a"), ir.Var("b")]),
    ir.CallIndirect(
      "tbl",
      ir.Var("i"),
      ir.FuncType([ir.TI32, ir.TI64], [ir.TF32]),
      [ir.Var("a")],
    ),
    ir.CallHost("env", "print", [ir.Var("a")]),
    // sequencing: multi-binder let + a block used as the let rhs (open question #4)
    ir.Let(
      ["a", "b"],
      ir.Values([ir.ConstI32(1), ir.ConstI32(2)]),
      ir.Return([ir.Var("a"), ir.Var("b")]),
    ),
    ir.Let(
      ["x"],
      ir.Block("blk", [ir.TI32], ir.Break("blk", [ir.ConstI32(1)])),
      ir.Return([ir.Var("x")]),
    ),
    // loop with several carried vars + continue
    ir.Loop(
      "lp",
      [
        ir.LoopParam("i", ir.TI32, ir.ConstI32(0)),
        ir.LoopParam("acc", ir.TI64, ir.ConstI64(0)),
      ],
      [ir.TI64],
      ir.Continue("lp", [ir.ConstI32(1), ir.ConstI64(2)]),
    ),
    // if
    ir.If(
      ir.Var("c"),
      [ir.TI32],
      ir.Return([ir.ConstI32(1)]),
      ir.Return([ir.ConstI32(0)]),
    ),
    // switch with arms + default, and a switch with NO arms (default only)
    ir.Switch(
      ir.Var("s"),
      [ir.TI32],
      [
        ir.SwitchArm(0, ir.Return([ir.ConstI32(10)])),
        ir.SwitchArm(255, ir.Return([ir.ConstI32(20)])),
      ],
      ir.Return([ir.ConstI32(30)]),
    ),
    ir.Switch(ir.Var("s"), [], [], ir.Return([])),
    // transfers
    ir.Break("blk", [ir.Var("x")]),
    ir.Continue("lp", [ir.Var("x")]),
    ir.Return([]),
    ir.Return([ir.Var("x")]),
    // metering effect, nested with a let
    ir.Charge(1000, ir.Return([ir.ConstI32(1)])),
    ir.Charge(
      0,
      ir.Let(["z"], ir.Values([ir.ConstI32(7)]), ir.Return([ir.Var("z")])),
    ),
  ]
}

/// A "kitchen-sink" module exercising every MODULE-LEVEL feature: numerics on, sized
/// memory, mutable + immutable globals, a host import, two exports + two functions, and
/// two data segments (one of them EMPTY, to exercise the `0x` empty-bytes form).
fn kitchen_sink_module() -> ir.Module {
  ir.Module(
    name: "twocore@wasm@sink",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, Some(4), ir.Idx32)],
    globals: [
      ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(0)])),
      ir.GlobalDecl(
        "g1",
        ir.TF64,
        False,
        ir.Values([ir.ConstF64(0x3ff0000000000000)]),
      ),
    ],
    imports: [ir.ImportFn("env", "log", ir.FuncType([ir.TI32], []))],
    functions: [
      ir.Function(
        name: "f0",
        params: [ir.Local("p0", ir.TI32)],
        result: [ir.TI32],
        locals: [ir.Local("tmp", ir.TI64)],
        body: ir.Let(["r"], ir.GlobalGet("g0"), ir.Return([ir.Var("r")])),
      ),
      ir.Function(
        name: "f1",
        params: [],
        result: [],
        locals: [],
        body: ir.Trap(ir.Unreachable),
      ),
    ],
    exports: [ir.ExportFn("main", "f0"), ir.ExportFn("aux", "f1")],
    data_segments: [
      ir.DataSegment(ir.DataActive(0, ir.Values([ir.ConstI32(0)])), <<
        0xde,
        0xad,
        0xbe,
        0xef,
        0x00,
      >>),
      ir.DataSegment(ir.DataActive(0, ir.Values([ir.ConstI32(16)])), <<>>),
    ],
    tables: [],
    elements: [],
    start: None,
    tags: [],
  )
}

/// Expected `Module` for the Phase-2 golden `golden/mem_table.ir` (hand-built, independent
/// of the printer). Exercises the new IR2 surface in one module: a funcref `table` decl, an
/// active `elem` segment, a `start` function, `mem.size`/`mem.grow`, a sign-extending
/// `mem.load` (i64 result), a float comparison (`f.lt.64`), and a TRAPPING float→int convert
/// (`trunc_s.f64.i32`).
fn mem_table_module() -> ir.Module {
  ir.Module(
    name: "mem_table",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, Some(4), ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        name: "worker",
        params: [ir.Local("x", ir.TF64), ir.Local("y", ir.TF64)],
        result: [ir.TI32],
        locals: [],
        body: ir.Let(
          ["lt"],
          ir.Num(ir.FLt(ir.FW64), [ir.Var("x"), ir.Var("y")]),
          ir.Let(
            ["n"],
            ir.Convert(ir.TruncS(ir.FW64, ir.W32), ir.Var("x")),
            ir.Let(
              ["hi"],
              ir.MemLoad(0, ir.MemAccess(1, True), ir.Var("n"), 8, ir.TI64),
              ir.Return([ir.Var("lt")]),
            ),
          ),
        ),
      ),
      ir.Function(
        name: "setup",
        params: [],
        result: [],
        locals: [],
        body: ir.Let(
          ["sz"],
          ir.MemSize(0),
          ir.Let(["prev"], ir.MemGrow(0, ir.ConstI32(1)), ir.Return([])),
        ),
      ),
    ],
    exports: [],
    data_segments: [],
    tables: [ir.TableDecl("t0", ir.FuncRef, 2, Some(8))],
    elements: [
      ir.ElementSegment(
        ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
        ir.FuncRef,
        [ir.RefFunc("worker"), ir.RefFunc("setup")],
      ),
    ],
    start: Some("setup"),
    tags: [],
  )
}

/// The worker function body of `refs_bulk_module` — a `let`-chain exercising every new
/// reference / table / bulk-memory / multi-memory `Expr` once. Built independently of the
/// printer (mirrors `golden/refs_bulk.ir`), so agreement is an oracle, not collusion.
fn refs_bulk_worker_body() -> ir.Expr {
  ir.Let(
    ["r0"],
    ir.RefFunc("worker"),
    ir.Let(
      ["isn"],
      ir.RefIsNull(ir.Var("r0")),
      ir.Let(
        [],
        ir.TableSet("funcs", ir.Var("t"), ir.Var("r0")),
        ir.Let(
          ["g"],
          ir.TableGet("funcs", ir.Var("t")),
          ir.Let(
            ["sz"],
            ir.TableSize("funcs"),
            ir.Let(
              ["grew"],
              ir.TableGrow("hosts", ir.ConstI32(1), ir.ConstNull(ir.ExternRef)),
              ir.Let(
                [],
                ir.TableFill(
                  "hosts",
                  ir.ConstI32(0),
                  ir.ConstNull(ir.ExternRef),
                  ir.ConstI32(1),
                ),
                ir.Let(
                  [],
                  ir.TableInit(
                    "funcs",
                    2,
                    ir.ConstI32(0),
                    ir.ConstI32(0),
                    ir.ConstI32(2),
                  ),
                  ir.Let(
                    [],
                    ir.TableCopy(
                      "funcs",
                      "funcs",
                      ir.ConstI32(0),
                      ir.ConstI32(0),
                      ir.ConstI32(1),
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
                          ir.ConstI32(4),
                        ),
                        ir.Let(
                          [],
                          ir.MemCopy(
                            1,
                            0,
                            ir.ConstI32(0),
                            ir.ConstI32(0),
                            ir.ConstI32(4),
                          ),
                          ir.Let(
                            [],
                            ir.MemInit(
                              0,
                              2,
                              ir.ConstI32(0),
                              ir.ConstI32(0),
                              ir.ConstI32(2),
                            ),
                            ir.Let(
                              [],
                              ir.DataDrop(2),
                              ir.Let(
                                ["big"],
                                ir.MemLoad(
                                  1,
                                  ir.MemAccess(8, False),
                                  ir.Var("t"),
                                  0,
                                  ir.TI64,
                                ),
                                ir.Let(
                                  [],
                                  ir.MemStore(
                                    1,
                                    ir.MemAccess(4, False),
                                    ir.Var("t"),
                                    ir.ConstI32(7),
                                    0,
                                  ),
                                  ir.Let(
                                    ["pages"],
                                    ir.MemSize(1),
                                    ir.Return([ir.Var("g")]),
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
}

/// Expected `Module` for the Phase-5 golden `golden/refs_bulk.ir` (hand-built, independent of
/// the printer). Exercises the FULL IR3 surface in one module: two memories (32-bit + memory64),
/// a funcref + an externref table, a reftype-typed global with a `ref.null` init, the six
/// import/export state variants, active / mem-tagged-active / passive data, active (legacy) /
/// canonical-active / passive / declarative element segments with `ref.func` and `ref.null`
/// items, and every reference / table / bulk / multi-memory expression.
fn refs_bulk_module() -> ir.Module {
  ir.Module(
    name: "refs_bulk",
    uses_numerics: True,
    memories: [
      ir.MemoryDecl(1, Some(4), ir.Idx32),
      ir.MemoryDecl(2, None, ir.Idx64),
    ],
    globals: [
      ir.GlobalDecl(
        "gref",
        ir.TFuncRef,
        False,
        ir.Values([ir.ConstNull(ir.FuncRef)]),
      ),
    ],
    imports: [
      ir.ImportGlobal("spectest", "global_i32", ir.TI32, False),
      ir.ImportGlobal("env", "counter", ir.TI64, True),
      ir.ImportTable("spectest", "table", ir.FuncRef, 10, Some(20)),
      ir.ImportMemory("spectest", "memory", 1, Some(2), ir.Idx32),
      ir.ImportMemory("env", "mem64", 1, None, ir.Idx64),
      ir.ImportFn("env", "log", ir.FuncType([ir.TI32], [])),
    ],
    functions: [
      ir.Function(
        name: "worker",
        params: [ir.Local("t", ir.TI32)],
        result: [ir.TFuncRef],
        locals: [],
        body: refs_bulk_worker_body(),
      ),
      ir.Function(
        name: "setup",
        params: [],
        result: [],
        locals: [],
        body: ir.Return([]),
      ),
    ],
    exports: [
      ir.ExportTable("funcs", "funcs"),
      ir.ExportMemory("mem2", 1),
      ir.ExportGlobal("g", "gref"),
      ir.ExportFn("worker", "worker"),
    ],
    data_segments: [
      ir.DataSegment(ir.DataActive(0, ir.Values([ir.ConstI32(0)])), <<
        0xde, 0xad, 0xbe, 0xef,
      >>),
      ir.DataSegment(ir.DataActive(1, ir.Values([ir.ConstI32(8)])), <<
        0x01, 0x02,
      >>),
      ir.DataSegment(ir.DataPassive, <<0x03, 0x04>>),
    ],
    tables: [
      ir.TableDecl("funcs", ir.FuncRef, 2, Some(8)),
      ir.TableDecl("hosts", ir.ExternRef, 1, None),
    ],
    elements: [
      ir.ElementSegment(
        ir.ElemActive("funcs", ir.Values([ir.ConstI32(0)])),
        ir.FuncRef,
        [ir.RefFunc("worker"), ir.RefFunc("worker")],
      ),
      ir.ElementSegment(
        ir.ElemActive("funcs", ir.Values([ir.ConstI32(1)])),
        ir.FuncRef,
        [ir.RefFunc("worker"), ir.Values([ir.ConstNull(ir.FuncRef)])],
      ),
      ir.ElementSegment(ir.ElemPassive, ir.FuncRef, [
        ir.RefFunc("worker"),
        ir.Values([ir.ConstNull(ir.FuncRef)]),
      ]),
      ir.ElementSegment(ir.ElemDeclarative, ir.ExternRef, [
        ir.Values([ir.ConstNull(ir.ExternRef)]),
      ]),
    ],
    start: Some("setup"),
    tags: [],
  )
}

// ───────────────────────────── round-trip tests ─────────────────────────────

pub fn numop_roundtrip_test() {
  list.each(all_numops(), fn(op) {
    check_roundtrip(expr_module("nm", ir.Num(op, [ir.Var("a"), ir.Var("b")])))
  })
}

pub fn convop_roundtrip_test() {
  list.each(all_convops(), fn(op) {
    check_roundtrip(expr_module("cv", ir.Convert(op, ir.Var("a"))))
  })
}

pub fn trapreason_roundtrip_test() {
  list.each(all_trapreasons(), fn(r) {
    check_roundtrip(expr_module("tr", ir.Trap(r)))
  })
}

pub fn expr_surface_roundtrip_test() {
  list.each(expr_corpus(), fn(e) { check_roundtrip(expr_module("ex", e)) })
}

pub fn module_level_roundtrip_test() {
  check_roundtrip(kitchen_sink_module())
}

/// The Phase-2 module-level surface (`«IR2-FROZEN»`): a module carrying a `table`, an active
/// `elem` segment, and a `start` function round-trips losslessly.
pub fn module_level_phase2_roundtrip_test() {
  check_roundtrip(mem_table_module())
}

/// The `mem.load` result `ValType` (`«IR2-FROZEN»`) is NOT dropped: two loads with identical
/// `MemAccess(1, signed)` but different result types (`i32.load8_s` vs `i64.load8_s`) are
/// distinct `Module`s, and each round-trips. A printer/parser that ignored `result` would
/// collapse them — this test fails closed on that bug.
pub fn mem_load_result_type_discrimination_test() {
  let m_i32 =
    expr_module(
      "ld",
      ir.MemLoad(0, ir.MemAccess(1, True), ir.Var("a"), 0, ir.TI32),
    )
  let m_i64 =
    expr_module(
      "ld",
      ir.MemLoad(0, ir.MemAccess(1, True), ir.Var("a"), 0, ir.TI64),
    )
  assert module_equal(m_i32, m_i64) == False
  check_roundtrip(m_i32)
  check_roundtrip(m_i64)
}

pub fn acceptance_programs_roundtrip_test() {
  check_roundtrip(add_module())
  check_roundtrip(sum_to_module())
  check_roundtrip(fib_module())
}

pub fn empty_module_roundtrip_test() {
  let m =
    ir.Module(
      name: "empty",
      uses_numerics: False,
      memories: [],
      globals: [],
      imports: [],
      functions: [],
      exports: [],
      data_segments: [],
      tables: [],
      elements: [],
      start: None,
      tags: [],
    )
  check_roundtrip(m)
}

// ───────────────────────────── float fidelity (D5) ─────────────────────────────

pub fn float_bit_fidelity_roundtrip_test() {
  // Quiet NaN, a signaling-NaN bit pattern, +Inf, -0.0, and assorted f32/f64 patterns.
  let m =
    expr_module(
      "fl",
      ir.Values([
        ir.ConstF32(0x7fc00000),
        // f32 quiet NaN
        ir.ConstF32(0x7f800001),
        // f32 signaling NaN payload
        ir.ConstF32(0x80000000),
        // f32 -0.0
        ir.ConstF32(0x7f800000),
        // f32 +Inf
        ir.ConstF64(0x7ff8000000000000),
        // f64 quiet NaN
        ir.ConstF64(0x7ff0000000000001),
        // f64 signaling NaN payload
        ir.ConstF64(0x8000000000000000),
        // f64 -0.0
        ir.ConstF64(0x0000000000000000),
        // f64 +0.0
      ]),
    )
  check_roundtrip(m)
}

pub fn nan_payloads_are_distinct_test() {
  // module_equal must distinguish two different NaN bit patterns and +0.0 from -0.0,
  // which a native-float comparison would WRONGLY conflate.
  let qnan = expr_module("x", ir.Values([ir.ConstF64(0x7ff8000000000000)]))
  let snan = expr_module("x", ir.Values([ir.ConstF64(0x7ff0000000000001)]))
  let pos_zero = expr_module("x", ir.Values([ir.ConstF64(0x0000000000000000)]))
  let neg_zero = expr_module("x", ir.Values([ir.ConstF64(0x8000000000000000)]))
  assert module_equal(qnan, snan) == False
  assert module_equal(pos_zero, neg_zero) == False
  assert module_equal(qnan, qnan) == True
}

// ───────────────────────────── golden suite (independent oracle) ─────────────

pub fn golden_add_parses_to_expected_test() {
  assert parser.parse_module(read_golden("add.ir")) == Ok(add_module())
}

pub fn golden_sum_to_parses_to_expected_test() {
  assert parser.parse_module(read_golden("sum_to.ir")) == Ok(sum_to_module())
}

pub fn golden_fib_parses_to_expected_test() {
  assert parser.parse_module(read_golden("fib.ir")) == Ok(fib_module())
}

/// The Phase-2 golden parses to its hand-built expected `Module` — the independent oracle
/// proving the printer and parser agree on the IR2 grammar additions (table/elem/start,
/// mem.size/grow, the result-typed sign-extending load, the float comparison, and the
/// trapping convert), not merely with each other.
pub fn golden_mem_table_parses_to_expected_test() {
  assert parser.parse_module(read_golden("mem_table.ir"))
    == Ok(mem_table_module())
}

/// The Phase-5 golden parses to its hand-built expected `Module` — the independent oracle
/// proving the printer and parser agree on the IR3 grammar delta (reftype valtypes, the
/// reference/table/bulk expressions, the memory index, multi-memory + memory64, the
/// import/export state variants, and the passive/declarative segments with ref-init items),
/// not merely with each other.
pub fn golden_refs_bulk_parses_to_expected_test() {
  assert parser.parse_module(read_golden("refs_bulk.ir"))
    == Ok(refs_bulk_module())
}

pub fn goldens_reprint_and_reparse_stably_test() {
  // print(parse(golden)) need not match the golden BYTES (the goldens carry hand
  // comments/whitespace), but the parsed Module must round-trip through the canonical
  // printer: parse(print(M)) == M.
  check_roundtrip(add_module())
  check_roundtrip(sum_to_module())
  check_roundtrip(fib_module())
  check_roundtrip(mem_table_module())
  check_roundtrip(refs_bulk_module())
}

// ───────────────────────────── module_equal tests ─────────────────────────────

pub fn module_equal_reflexive_test() {
  assert module_equal(fib_module(), fib_module()) == True
}

pub fn module_equal_distinguishes_programs_test() {
  assert module_equal(add_module(), fib_module()) == False
}

// ───────────────────────────── Phase-5 IR3 surface (round-trip) ─────────────────

/// A representative instance of every NEW Phase-5 `Expr`, plus the reftype-null `Value`, for
/// the round-trip. Derived from the WASM reference-types / bulk-memory / multi-memory
/// constructs (what forms must exist), not from the printer's output. Covers: the memory index
/// at 0 (omitted) and non-zero; `mem.copy` both-zero and with distinct `dst_mem`/`src_mem`;
/// `table.copy` with two distinct table names; `table.init`/`mem.init`/`elem.drop`/`data.drop`
/// segment indices; and `ConstNull` at both reftypes in `Value` position.
fn phase5_expr_corpus() -> List(ir.Expr) {
  [
    // reference expressions
    ir.RefFunc("f"),
    ir.RefIsNull(ir.Var("x")),
    ir.RefIsNull(ir.ConstNull(ir.FuncRef)),
    // null literals flowing as ordinary values
    ir.Values([ir.ConstNull(ir.FuncRef)]),
    ir.Values([ir.ConstNull(ir.ExternRef)]),
    ir.GlobalSet("g", ir.ConstNull(ir.ExternRef)),
    // table expressions
    ir.TableGet("t", ir.Var("i")),
    ir.TableSet("t", ir.Var("i"), ir.Var("v")),
    ir.TableSize("t"),
    ir.TableGrow("t", ir.Var("d"), ir.ConstNull(ir.FuncRef)),
    ir.TableGrow("t", ir.ConstI32(1), ir.Var("init")),
    ir.TableFill("t", ir.Var("o"), ir.Var("v"), ir.Var("c")),
    ir.TableInit("t", 3, ir.Var("d"), ir.Var("s"), ir.Var("c")),
    ir.TableCopy("dst", "src", ir.Var("d"), ir.Var("s"), ir.Var("c")),
    ir.TableCopy("t", "t", ir.ConstI32(0), ir.ConstI32(0), ir.ConstI32(1)),
    ir.ElemDrop(0),
    ir.ElemDrop(5),
    // bulk-memory expressions (memory index at 0 = omitted, and non-zero)
    ir.MemFill(0, ir.Var("d"), ir.Var("v"), ir.Var("c")),
    ir.MemFill(2, ir.Var("d"), ir.Var("v"), ir.Var("c")),
    ir.MemCopy(0, 0, ir.Var("d"), ir.Var("s"), ir.Var("c")),
    ir.MemCopy(2, 1, ir.Var("d"), ir.Var("s"), ir.Var("c")),
    ir.MemInit(0, 1, ir.Var("d"), ir.Var("s"), ir.Var("c")),
    ir.MemInit(3, 1, ir.Var("d"), ir.Var("s"), ir.Var("c")),
    ir.DataDrop(0),
    ir.DataDrop(7),
    // the memory index on the existing memory ops, at 0 (omitted) and non-zero
    ir.MemSize(0),
    ir.MemSize(1),
    ir.MemGrow(0, ir.Var("d")),
    ir.MemGrow(2, ir.Var("d")),
    ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("a"), 0, ir.TI32),
    ir.MemLoad(1, ir.MemAccess(1, True), ir.Var("a"), 8, ir.TI64),
    ir.MemStore(0, ir.MemAccess(4, False), ir.Var("a"), ir.Var("v"), 0),
    ir.MemStore(3, ir.MemAccess(8, False), ir.Var("a"), ir.Var("v"), 16),
  ]
}

pub fn phase5_expr_surface_roundtrip_test() {
  list.each(phase5_expr_corpus(), fn(e) {
    check_roundtrip(expr_module("p5", e))
  })
}

/// Both reference `ValType`s are legal — and round-trip — in every valtype position:
/// param, local, function result, a `FuncType` (via `call_indirect`), and a global's type.
fn reftype_valtype_module() -> ir.Module {
  ir.Module(
    name: "rt",
    uses_numerics: True,
    memories: [],
    globals: [
      ir.GlobalDecl(
        "gf",
        ir.TFuncRef,
        True,
        ir.Values([ir.ConstNull(ir.FuncRef)]),
      ),
      ir.GlobalDecl(
        "ge",
        ir.TExternRef,
        False,
        ir.Values([ir.ConstNull(ir.ExternRef)]),
      ),
    ],
    imports: [],
    functions: [
      ir.Function(
        name: "f",
        params: [ir.Local("a", ir.TFuncRef), ir.Local("b", ir.TExternRef)],
        result: [ir.TFuncRef, ir.TExternRef],
        locals: [ir.Local("l1", ir.TFuncRef), ir.Local("l2", ir.TExternRef)],
        body: ir.Let(
          ["x"],
          ir.CallIndirect(
            "t",
            ir.Var("i"),
            ir.FuncType([ir.TFuncRef], [ir.TExternRef]),
            [ir.Var("a")],
          ),
          ir.Return([ir.Var("a"), ir.Var("b")]),
        ),
      ),
    ],
    exports: [],
    data_segments: [],
    tables: [ir.TableDecl("t", ir.FuncRef, 1, None)],
    elements: [],
    start: None,
    tags: [],
  )
}

pub fn reftype_valtype_positions_roundtrip_test() {
  check_roundtrip(reftype_valtype_module())
}

/// The full IR3 module-level surface round-trips (the hand-built oracle also drives the golden
/// test); asserting it here keeps the property green independently of golden-file reading.
pub fn phase5_module_level_roundtrip_test() {
  check_roundtrip(refs_bulk_module())
}

/// A zero-memory, a one-memory, and a two-memory module (including a memory64) each round-trip
/// — the `Module.memories` list is carried losslessly at every cardinality.
pub fn memories_cardinality_roundtrip_test() {
  let zero = expr_module("m0", ir.Return([]))
  let one =
    ir.Module(..zero, name: "m1", memories: [ir.MemoryDecl(1, None, ir.Idx32)])
  let two =
    ir.Module(..zero, name: "m2", memories: [
      ir.MemoryDecl(1, Some(3), ir.Idx32),
      ir.MemoryDecl(2, None, ir.Idx64),
    ])
  check_roundtrip(zero)
  check_roundtrip(one)
  check_roundtrip(two)
}

// ───────────────────────────── Phase-5 discrimination (no field dropped) ────────

/// A `funcref` table and an `externref` table with the SAME name/min/max are DISTINCT modules
/// and each round-trips — the `TableDecl.ref_ty` field is not dropped by print→parse.
pub fn table_reftype_discrimination_test() {
  let f =
    ir.Module(..reftype_valtype_module(), tables: [
      ir.TableDecl("t", ir.FuncRef, 1, Some(2)),
    ])
  let e =
    ir.Module(..reftype_valtype_module(), tables: [
      ir.TableDecl("t", ir.ExternRef, 1, Some(2)),
    ])
  assert module_equal(f, e) == False
  check_roundtrip(f)
  check_roundtrip(e)
}

/// A `mem.load` at memory index 0 vs index 1 (same access/addr/offset/result) are DISTINCT and
/// each round-trips — the `mem=` decorator is not dropped.
pub fn mem_index_discrimination_test() {
  let m0 =
    expr_module(
      "mi",
      ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("a"), 0, ir.TI32),
    )
  let m1 =
    expr_module(
      "mi",
      ir.MemLoad(1, ir.MemAccess(4, False), ir.Var("a"), 0, ir.TI32),
    )
  assert module_equal(m0, m1) == False
  check_roundtrip(m0)
  check_roundtrip(m1)
}

/// An `Idx32` vs an `Idx64` memory (same min/max) are DISTINCT modules and each round-trips —
/// the `MemoryDecl.idx_type` (memory64 axis) is not dropped.
pub fn idxtype_discrimination_test() {
  let base = expr_module("ix", ir.Return([]))
  let m32 = ir.Module(..base, memories: [ir.MemoryDecl(2, Some(4), ir.Idx32)])
  let m64 = ir.Module(..base, memories: [ir.MemoryDecl(2, Some(4), ir.Idx64)])
  assert module_equal(m32, m64) == False
  check_roundtrip(m32)
  check_roundtrip(m64)
}

/// Active vs passive vs declarative element segments (same reftype + init) are pairwise DISTINCT
/// and each round-trips — the `ElemMode` is not collapsed.
pub fn elem_mode_discrimination_test() {
  let init = [ir.RefFunc("w")]
  let base = expr_module("em", ir.Return([]))
  let active =
    ir.Module(..base, elements: [
      ir.ElementSegment(
        ir.ElemActive("t", ir.Values([ir.ConstI32(0)])),
        ir.FuncRef,
        init,
      ),
    ])
  let passive =
    ir.Module(..base, elements: [
      ir.ElementSegment(ir.ElemPassive, ir.FuncRef, init),
    ])
  let declarative =
    ir.Module(..base, elements: [
      ir.ElementSegment(ir.ElemDeclarative, ir.FuncRef, init),
    ])
  assert module_equal(active, passive) == False
  assert module_equal(passive, declarative) == False
  assert module_equal(active, declarative) == False
  check_roundtrip(active)
  check_roundtrip(passive)
  check_roundtrip(declarative)
}

/// A `ConstNull(FuncRef)` vs a `ConstNull(ExternRef)` are DISTINCT and each round-trips — the
/// null literal's static reftype is not dropped (`ref.null t` is the `ConstNull(t)` value, R1c).
pub fn constnull_reftype_discrimination_test() {
  let f = expr_module("cn", ir.Values([ir.ConstNull(ir.FuncRef)]))
  let e = expr_module("cn", ir.Values([ir.ConstNull(ir.ExternRef)]))
  assert module_equal(f, e) == False
  check_roundtrip(f)
  check_roundtrip(e)
}

/// A reftype-typed global with a `ref.null` initialiser coexists — and round-trips — alongside
/// NaN-payload / `-0.0` / ±Inf float globals, proving the new reference surface does not disturb
/// the D5 bit-exact float encoding.
pub fn reftype_global_and_nan_coexist_roundtrip_test() {
  let m =
    ir.Module(..expr_module("co", ir.Return([])), globals: [
      ir.GlobalDecl(
        "gnull",
        ir.TFuncRef,
        False,
        ir.Values([ir.ConstNull(ir.FuncRef)]),
      ),
      ir.GlobalDecl(
        "gqnan",
        ir.TF64,
        False,
        ir.Values([ir.ConstF64(0x7ff8000000000000)]),
      ),
      ir.GlobalDecl(
        "gnzero",
        ir.TF32,
        True,
        ir.Values([ir.ConstF32(0x80000000)]),
      ),
      ir.GlobalDecl(
        "ginf",
        ir.TF32,
        False,
        ir.Values([ir.ConstF32(0x7f800000)]),
      ),
    ])
  check_roundtrip(m)
}

// ───────────────────────────── Phase-5 byte-identity (H7) ───────────────────────

/// A Phase-4-shaped (legacy) module prints byte-identically: one 32-bit memory (no idx token),
/// a funcref table (reftype elided), memory ops at index 0 (no `mem=`), an active data segment
/// at memory 0 (no `mem=`), and function-only import/export. This asserts the EXACT canonical
/// text (the Phase-4 spelling derived from the grammar), so a regression that leaked a new token
/// into legacy output fails closed.
pub fn legacy_module_byte_identical_test() {
  let m =
    ir.Module(
      name: "leg",
      uses_numerics: True,
      memories: [ir.MemoryDecl(1, Some(2), ir.Idx32)],
      globals: [],
      imports: [ir.ImportFn("env", "log", ir.FuncType([ir.TI32], []))],
      functions: [
        ir.Function(
          name: "f",
          params: [ir.Local("p", ir.TI32)],
          result: [ir.TI32],
          locals: [],
          body: ir.Let(
            ["v"],
            ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("p"), 0, ir.TI32),
            ir.Let(["sz"], ir.MemSize(0), ir.Return([ir.Var("v")])),
          ),
        ),
      ],
      exports: [ir.ExportFn("main", "f")],
      data_segments: [
        ir.DataSegment(ir.DataActive(0, ir.Values([ir.ConstI32(0)])), <<0x01>>),
      ],
      tables: [ir.TableDecl("t", ir.FuncRef, 1, None)],
      elements: [],
      start: None,
      tags: [],
    )
  let expected =
    "module @leg {\n"
    <> "  numerics true\n"
    <> "  memory (min 1 max 2)\n"
    <> "  table @t min 1\n"
    <> "  import \"env\" \"log\" : (i32) -> ()\n"
    <> "  export \"main\" = @f\n"
    <> "  data (values (i32.const 0)) = 0x01\n"
    <> "  func @f (%p:i32) -> (i32) {\n"
    <> "    let (%v) = mem.load i32 4 %p offset=0\n"
    <> "    let (%sz) = mem.size\n"
    <> "    return (%v)\n"
    <> "  }\n"
    <> "}\n"
  assert printer.print_module(m) == expected
  // And the empty (numerics-only) module still prints the legacy `memory none` line.
  assert printer.print_module(
      ir.Module("e", False, [], [], [], [], [], [], [], [], None, tags: []),
    )
    == "module @e {\n  numerics false\n  memory none\n}\n"
}

// ───────────────────────────── negative corpus (totality, D4) ─────────────────

/// `True` iff parsing `source` yields some `ParseError` (and, by completing, did not
/// panic).
fn rejects(source: String) -> Bool {
  case parser.parse_module(source) {
    Error(_) -> True
    Ok(_) -> False
  }
}

pub fn negative_truncated_module_test() {
  // Input ends after the opening brace.
  let r = parser.parse_module("module @m {")
  assert case r {
    Error(parser.UnexpectedEnd(_)) -> True
    _ -> False
  }
}

pub fn negative_bad_sigil_test() {
  // `func %f ...` — a function name must use the `@` sigil, not `%`.
  let r = parser.parse_module("module @m { func %f () -> () { return () } }")
  assert case r {
    Error(parser.BadSigil(_, _, _)) -> True
    _ -> False
  }
}

pub fn negative_unknown_op_test() {
  // `i.bogus.32` is not a real numeric-op spelling.
  let r =
    parser.parse_module("module @m { func @f () -> () { num i.bogus.32 () } }")
  assert case r {
    Error(parser.UnknownOp(_, _, "i.bogus.32")) -> True
    _ -> False
  }
}

pub fn negative_unknown_trapreason_test() {
  let r = parser.parse_module("module @m { func @f () -> () { trap kaboom } }")
  assert case r {
    Error(parser.UnknownOp(_, _, "kaboom")) -> True
    _ -> False
  }
}

pub fn negative_missing_paren_test() {
  // Missing `(` before the argument list of `num`.
  let r =
    parser.parse_module("module @m { func @f () -> () { num i.add.32 %a) } }")
  assert case r {
    Error(parser.UnexpectedToken(_, _, _, _)) -> True
    _ -> False
  }
}

pub fn negative_unterminated_block_test() {
  // The block (and the enclosing func/module) is never closed.
  let r =
    parser.parse_module(
      "module @m { func @f () -> () { block $b : (i32) { return (i32.const 1) }",
    )
  assert case r {
    Error(parser.UnexpectedEnd(_)) -> True
    _ -> False
  }
}

pub fn negative_odd_hexbytes_test() {
  // A data segment with an odd number of hex digits cannot be byte-decoded.
  let r =
    parser.parse_module("module @m { data (values (i32.const 0)) = 0xabc }")
  assert case r {
    Error(parser.BadNumberLiteral(_, _, "0xabc")) -> True
    _ -> False
  }
}

pub fn negative_bad_string_escape_test() {
  let r = parser.parse_module("module @m { export \"\\q\" = @f }")
  assert case r {
    Error(parser.BadString(_, _, _)) -> True
    _ -> False
  }
}

pub fn negative_stray_char_test() {
  assert rejects("module @m { ! }")
}

pub fn negative_mem_load_missing_valtype_test() {
  // The result valtype is REQUIRED (`«IR2-FROZEN»`): `mem.load 4 %a …` (no leading
  // valtype) must fail where the valtype is expected — `4` is a number, not a valtype.
  let r =
    parser.parse_module(
      "module @m { func @f () -> () { mem.load 4 %a offset=0 } }",
    )
  assert case r {
    Error(parser.UnexpectedToken(_, _, "valtype", _)) -> True
    _ -> False
  }
}

pub fn negative_unknown_float_op_test() {
  // `f.bogus.32` is not a real float-op spelling → UnknownOp (via float_mnemonic Error).
  let r =
    parser.parse_module(
      "module @m { func @f () -> () { num f.bogus.32 (%a) } }",
    )
  assert case r {
    Error(parser.UnknownOp(_, _, "f.bogus.32")) -> True
    _ -> False
  }
}

pub fn negative_unknown_convert_op_test() {
  // `trunc_q.f64.i32` is not a real convert-op spelling → UnknownOp.
  let r =
    parser.parse_module(
      "module @m { func @f () -> () { convert trunc_q.f64.i32 %a } }",
    )
  assert case r {
    Error(parser.UnknownOp(_, _, "trunc_q.f64.i32")) -> True
    _ -> False
  }
}

pub fn negative_malformed_elem_test() {
  // An `elem` whose offset parentheses are missing (`[` where `(` is required).
  let r = parser.parse_module("module @m { elem @t0 [ @a ] }")
  assert case r {
    Error(parser.UnexpectedToken(_, _, "(", _)) -> True
    _ -> False
  }
}

pub fn negative_new_trapreasons_roundtrip_test() {
  // The three new trap reasons are accepted by the parser (positive coverage paired with
  // the negative `kaboom` case) so a dropped arm is caught.
  assert rejects("module @m { func @f () -> () { trap not_a_reason } }")
}

pub fn negative_bad_reftype_test() {
  // `table @t <bad>reftype` — a `min` keyword is required after the (optional) reftype; a bogus
  // token where the reftype/`min` is expected must error (never panic).
  let r = parser.parse_module("module @m { table @t bogus min 1 }")
  assert rejects("module @m { table @t bogus min 1 }") == True
  assert case r {
    Error(_) -> True
    _ -> False
  }
}

pub fn negative_unknown_import_kind_test() {
  // `import "m" "n" widget` — `widget` is not a valid import kind (`:`/global/table/memory).
  let r = parser.parse_module("module @m { import \"m\" \"n\" widget }")
  assert case r {
    Error(parser.UnexpectedToken(_, _, _, "widget")) -> True
    _ -> False
  }
}

pub fn negative_unknown_export_target_test() {
  // `export "e" = frob @x` — `frob` is not a valid export target (@fn/global/table/memory).
  let r = parser.parse_module("module @m { export \"e\" = frob @x }")
  assert case r {
    Error(parser.UnexpectedToken(_, _, _, "frob")) -> True
    _ -> False
  }
}

pub fn negative_ref_null_is_not_an_expr_test() {
  // R1c dropped `RefNull` as an `Expr`; a null reference is the `ConstNull` VALUE (`null.<t>`),
  // so `ref.null …` in expression position is an unknown expression, not a valid statement.
  let r =
    parser.parse_module("module @m { func @f () -> () { ref.null funcref } }")
  assert case r {
    Error(parser.UnexpectedToken(_, _, "expression", "ref.null")) -> True
    _ -> False
  }
}

pub fn negative_missing_seg_test() {
  // `mem.init` requires a mandatory `seg=<int>`; omitting it must error (never panic).
  let r =
    parser.parse_module(
      "module @m { func @f () -> () { mem.init i32.const 0 i32.const 0 i32.const 1 } }",
    )
  assert case r {
    Error(_) -> True
    _ -> False
  }
}

// ───────────────────────────── Phase-6 SIMD / v128 (IR4 surface) ────────────────
//
// The full IR4 round-trip: every `SimdOp` constructor and every `SimdShape`, `SimdShuffle`,
// the four SIMD-memory nodes with every `SimdLoadKind`/width/lane at memory index 0 AND
// non-zero, `CallImport`, the `TV128` valtype in every position, and `v128.const` with
// NaN-payload / `-0.0` / `±Inf` / normal lanes (byte-exact, D5). Built from the IR types (what
// forms must exist), never from the printer's output.

/// The six standardized `SimdShape` lane geometries (used to spread coverage across shapes).
fn all_simd_shapes() -> List(ir.SimdShape) {
  [ir.I8x16, ir.I16x8, ir.I32x4, ir.I64x2, ir.F32x4, ir.F64x2]
}

/// Every shape-tagged (`fn(SimdShape) -> SimdOp`) lane-uniform SIMD op — the integer and float
/// families whose `.ir` mnemonic is `<shape>.<mnemonic>` (§F.3–§F.5, §F.8–§F.9). Mapped over
/// `all_simd_shapes()` this exercises each constructor at every shape (round-trip holds even for
/// spec-illegal shape combos — the parser is a syntax layer, not a validator).
fn shape_tagged_simdops() -> List(fn(ir.SimdShape) -> ir.SimdOp) {
  [
    ir.SAdd,
    ir.SSub,
    ir.SMul,
    ir.SNeg,
    ir.SAbs,
    ir.SAddSatS,
    ir.SAddSatU,
    ir.SSubSatS,
    ir.SSubSatU,
    ir.SMinS,
    ir.SMinU,
    ir.SMaxS,
    ir.SMaxU,
    ir.SAvgrU,
    ir.SShl,
    ir.SShrS,
    ir.SShrU,
    ir.SPopcnt,
    ir.SEq,
    ir.SNe,
    ir.SLtS,
    ir.SLtU,
    ir.SLeS,
    ir.SLeU,
    ir.SGtS,
    ir.SGtU,
    ir.SGeS,
    ir.SGeU,
    ir.SAllTrue,
    ir.SBitmask,
    ir.SSplat,
    ir.SFAdd,
    ir.SFSub,
    ir.SFMul,
    ir.SFDiv,
    ir.SFNeg,
    ir.SFAbs,
    ir.SFSqrt,
    ir.SFMin,
    ir.SFMax,
    ir.SFPMin,
    ir.SFPMax,
    ir.SFCeil,
    ir.SFFloor,
    ir.SFTrunc,
    ir.SFNearest,
    ir.SFEq,
    ir.SFNe,
    ir.SFLt,
    ir.SFLe,
    ir.SFGt,
    ir.SFGe,
  ]
}

/// EVERY `SimdOp` constructor, spread across shapes/halves/signs so every constructor AND every
/// `SimdShape` appears at least once: the shape-tagged ops over all six shapes, the four
/// lane-access ops over all six shapes (with lane immediates), the shape-agnostic bitwise/boolean
/// ops, the tagged narrow/extend/extmul/pairwise families over their source shapes × half × sign,
/// and the singular conversion/dot/q15/swizzle ops. The exhaustive `case` in
/// `printer.simdop_to_string` fails to compile if a constructor is added later, and this list
/// fails a round-trip if the parser's inverse drops one.
fn all_simdops() -> List(ir.SimdOp) {
  let shape_tagged =
    list.flat_map(shape_tagged_simdops(), fn(mk) {
      list.map(all_simd_shapes(), mk)
    })
  let lane_access =
    list.flat_map(all_simd_shapes(), fn(s) {
      [
        ir.SExtractLane(s, 0),
        ir.SExtractLaneS(s, 1),
        ir.SExtractLaneU(s, 2),
        ir.SReplaceLane(s, 3),
      ]
    })
  let bitwise = [
    ir.VNot,
    ir.VAnd,
    ir.VOr,
    ir.VXor,
    ir.VAndNot,
    ir.VBitselect,
    ir.VAnyTrue,
  ]
  let narrow =
    list.flat_map([ir.I16x8, ir.I32x4], fn(s) {
      [ir.SNarrow(s, True), ir.SNarrow(s, False)]
    })
  let ext =
    list.flat_map([ir.I8x16, ir.I16x8, ir.I32x4], fn(s) {
      list.flat_map([ir.Low, ir.High], fn(h) {
        [
          ir.SExtend(s, h, True),
          ir.SExtend(s, h, False),
          ir.SExtMul(s, h, True),
          ir.SExtMul(s, h, False),
        ]
      })
    })
  let pairwise =
    list.flat_map([ir.I8x16, ir.I16x8], fn(s) {
      [ir.SExtAddPairwise(s, True), ir.SExtAddPairwise(s, False)]
    })
  let singular = [
    ir.STruncSatF32x4S,
    ir.STruncSatF32x4U,
    ir.STruncSatF64x2SZero,
    ir.STruncSatF64x2UZero,
    ir.SConvertF32x4I32x4S,
    ir.SConvertF32x4I32x4U,
    ir.SConvertF64x2LowI32x4S,
    ir.SConvertF64x2LowI32x4U,
    ir.SDemoteF64x2Zero,
    ir.SPromoteLowF32x4,
    ir.SDotI16x8S,
    ir.SQ15MulrSatS,
    ir.SSwizzle,
  ]
  list.flatten([
    shape_tagged,
    lane_access,
    bitwise,
    narrow,
    ext,
    pairwise,
    singular,
  ])
}

/// Every `SimdOp` constructor round-trips through `Simd(op, args)`. Arity is irrelevant to the
/// round-trip (the parser does not arity-check), so a fixed 2-arg list is used throughout.
pub fn simdop_roundtrip_test() {
  list.each(all_simdops(), fn(op) {
    check_roundtrip(expr_module("so", ir.Simd(op, [ir.Var("a"), ir.Var("b")])))
  })
}

/// The 16-byte v128 constant used by `golden/simd.ir` — four f32 lanes laid out little-endian:
/// lane0 `0x7fc00001` (qNaN + payload), lane1 `0x80000000` (`-0.0`), lane2 `0x7f800000` (`+Inf`),
/// lane3 `0x3f800000` (`1.0`). The raw bytes are what `ConstV128` stores (D5).
fn v128_nan_neg0_inf_one() -> BitArray {
  <<
    0x01, 0x00, 0xc0, 0x7f, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x80, 0x7f, 0x00,
    0x00, 0x80, 0x3f,
  >>
}

/// A `v128.const` whose lanes are a qNaN-with-payload, a `-0.0`, a `+Inf`, and a normal `1.0`
/// round-trips byte-exact — the D5 fidelity `ConstF32`/`ConstF64` already have, one level wider.
/// A lossy v128 spelling (e.g. one that re-parsed a NaN payload through a float) would corrupt
/// exactly the bit patterns the SIMD conformance oracle checks; this fails closed on that.
pub fn v128_const_bit_fidelity_roundtrip_test() {
  check_roundtrip(expr_module(
    "vc",
    ir.Values([ir.ConstV128(v128_nan_neg0_inf_one())]),
  ))
}

/// Two `v128.const`s that differ by a SINGLE bit (a NaN-payload low bit) are DISTINCT modules and
/// each round-trips — no byte is dropped or normalised by print→parse. Also covers the all-zero
/// and all-ones (every bit set) 16-byte patterns.
pub fn v128_const_byte_discrimination_test() {
  let a = ir.ConstV128(v128_nan_neg0_inf_one())
  // flip the low payload bit of lane0: 0x01 -> 0x00
  let b =
    ir.ConstV128(<<
      0x00, 0x00, 0xc0, 0x7f, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x80, 0x7f,
      0x00, 0x00, 0x80, 0x3f,
    >>)
  let zeros = ir.ConstV128(<<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>)
  let ones =
    ir.ConstV128(<<
      0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
      0xff, 0xff, 0xff, 0xff,
    >>)
  assert module_equal(
      expr_module("d", ir.Values([a])),
      expr_module("d", ir.Values([b])),
    )
    == False
  check_roundtrip(expr_module("d", ir.Values([a])))
  check_roundtrip(expr_module("d", ir.Values([b])))
  check_roundtrip(expr_module("d", ir.Values([zeros])))
  check_roundtrip(expr_module("d", ir.Values([ones])))
}

/// A representative instance of every SIMD-memory node, `SimdShuffle`, and `CallImport`, covering:
/// each `SimdLoadKind` (v128 / splat{8,16,32,64} / extend{8,16,32}×{s,u} / zero{32,64}); the
/// memory-index decorator at 0 (omitted) and non-zero; every `load_lane`/`store_lane` bit width
/// (8/16/32/64) and a spread of lane immediates; an empty and a full shuffle lane list; and
/// `CallImport` at several slots/signatures incl. an empty arg/result list.
fn simd_expr_corpus() -> List(ir.Expr) {
  [
    // every SimdLoadKind at memory 0 (mem= omitted)
    ir.SimdLoad(0, ir.LoadV128, ir.Var("a"), 0),
    ir.SimdLoad(0, ir.LoadSplat(8), ir.Var("a"), 0),
    ir.SimdLoad(0, ir.LoadSplat(16), ir.Var("a"), 4),
    ir.SimdLoad(0, ir.LoadSplat(32), ir.Var("a"), 8),
    ir.SimdLoad(0, ir.LoadSplat(64), ir.Var("a"), 16),
    ir.SimdLoad(0, ir.LoadExtend(8, True), ir.Var("a"), 0),
    ir.SimdLoad(0, ir.LoadExtend(8, False), ir.Var("a"), 0),
    ir.SimdLoad(0, ir.LoadExtend(16, True), ir.Var("a"), 0),
    ir.SimdLoad(0, ir.LoadExtend(16, False), ir.Var("a"), 0),
    ir.SimdLoad(0, ir.LoadExtend(32, True), ir.Var("a"), 0),
    ir.SimdLoad(0, ir.LoadExtend(32, False), ir.Var("a"), 0),
    ir.SimdLoad(0, ir.LoadZero(32), ir.Var("a"), 0),
    ir.SimdLoad(0, ir.LoadZero(64), ir.Var("a"), 0),
    // memory index non-zero (mem= present)
    ir.SimdLoad(2, ir.LoadV128, ir.Var("a"), 0),
    ir.SimdLoad(1, ir.LoadSplat(32), ir.Var("a"), 4),
    // store, at memory 0 and non-zero
    ir.SimdStore(0, ir.Var("a"), ir.Var("v"), 0),
    ir.SimdStore(3, ir.Var("a"), ir.Var("v"), 16),
    // load_lane / store_lane, every width, mem 0 and non-zero, varied lanes
    ir.SimdLoadLane(0, 8, ir.Var("a"), 0, 0, ir.Var("v")),
    ir.SimdLoadLane(0, 16, ir.Var("a"), 2, 3, ir.Var("v")),
    ir.SimdLoadLane(0, 32, ir.Var("a"), 4, 1, ir.Var("v")),
    ir.SimdLoadLane(0, 64, ir.Var("a"), 8, 0, ir.Var("v")),
    ir.SimdLoadLane(2, 32, ir.Var("a"), 0, 2, ir.Var("v")),
    ir.SimdStoreLane(0, 8, ir.Var("a"), 0, 15, ir.Var("v")),
    ir.SimdStoreLane(0, 16, ir.Var("a"), 0, 7, ir.Var("v")),
    ir.SimdStoreLane(0, 32, ir.Var("a"), 0, 3, ir.Var("v")),
    ir.SimdStoreLane(0, 64, ir.Var("a"), 0, 1, ir.Var("v")),
    ir.SimdStoreLane(1, 8, ir.Var("a"), 0, 4, ir.Var("v")),
    // shuffle: a full 16-index list and an empty list (parser does not length-check)
    ir.SimdShuffle(
      [0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23],
      ir.Var("a"),
      ir.Var("b"),
    ),
    ir.SimdShuffle([], ir.Var("a"), ir.Var("b")),
    // call_import: several slots/signatures, incl. empty arg/result lists
    ir.CallImport(0, ir.FuncType([ir.TI32], [ir.TI32]), [ir.Var("a")]),
    ir.CallImport(5, ir.FuncType([ir.TV128, ir.TF64], []), [
      ir.Var("a"),
      ir.Var("b"),
    ]),
    ir.CallImport(2, ir.FuncType([], []), []),
    // a v128-result mem.load (the vestigial valtype position — the token must be legal)
    ir.MemLoad(0, ir.MemAccess(16, False), ir.Var("a"), 0, ir.TV128),
  ]
}

pub fn simd_expr_surface_roundtrip_test() {
  list.each(simd_expr_corpus(), fn(e) { check_roundtrip(expr_module("se", e)) })
}

/// The SIMD-memory memory-index decorator is NOT dropped: a `simd.load` at memory 0 vs memory 1
/// (else identical) are DISTINCT modules and each round-trips.
pub fn simd_mem_index_discrimination_test() {
  let m0 = expr_module("sm", ir.SimdLoad(0, ir.LoadV128, ir.Var("a"), 0))
  let m1 = expr_module("sm", ir.SimdLoad(1, ir.LoadV128, ir.Var("a"), 0))
  assert module_equal(m0, m1) == False
  check_roundtrip(m0)
  check_roundtrip(m1)
}

/// The `SimdLoadKind` bit width is NOT dropped: `load8_splat` vs `load16_splat` (bits 8 vs 16)
/// are DISTINCT, and a signed vs unsigned extend load are DISTINCT — each round-trips.
pub fn simd_loadkind_discrimination_test() {
  let s8 = expr_module("lk", ir.SimdLoad(0, ir.LoadSplat(8), ir.Var("a"), 0))
  let s16 = expr_module("lk", ir.SimdLoad(0, ir.LoadSplat(16), ir.Var("a"), 0))
  let es =
    expr_module("lk", ir.SimdLoad(0, ir.LoadExtend(8, True), ir.Var("a"), 0))
  let eu =
    expr_module("lk", ir.SimdLoad(0, ir.LoadExtend(8, False), ir.Var("a"), 0))
  assert module_equal(s8, s16) == False
  assert module_equal(es, eu) == False
  check_roundtrip(s8)
  check_roundtrip(s16)
  check_roundtrip(es)
  check_roundtrip(eu)
}

/// The `lane=` immediate and the access `width` are NOT dropped: two `load_lane`s differing only
/// in lane, and two differing only in width, are DISTINCT and each round-trips.
pub fn simd_lane_and_width_discrimination_test() {
  let l1 =
    expr_module("ll", ir.SimdLoadLane(0, 32, ir.Var("a"), 0, 1, ir.Var("v")))
  let l2 =
    expr_module("ll", ir.SimdLoadLane(0, 32, ir.Var("a"), 0, 2, ir.Var("v")))
  let w8 =
    expr_module("ll", ir.SimdLoadLane(0, 8, ir.Var("a"), 0, 1, ir.Var("v")))
  let w16 =
    expr_module("ll", ir.SimdLoadLane(0, 16, ir.Var("a"), 0, 1, ir.Var("v")))
  assert module_equal(l1, l2) == False
  assert module_equal(w8, w16) == False
  check_roundtrip(l1)
  check_roundtrip(l2)
  check_roundtrip(w8)
  check_roundtrip(w16)
}

/// The `TV128` valtype is legal — and round-trips — in EVERY valtype position: a param, a local, a
/// function result, a `FuncType` (via `call_indirect`), an imported global's type, and a module
/// global's declared type (with a `v128.const` initialiser).
fn v128_valtype_module() -> ir.Module {
  ir.Module(
    name: "v128pos",
    uses_numerics: True,
    memories: [],
    globals: [
      ir.GlobalDecl(
        "gv",
        ir.TV128,
        True,
        ir.Values([ir.ConstV128(v128_nan_neg0_inf_one())]),
      ),
    ],
    imports: [ir.ImportGlobal("env", "iv", ir.TV128, False)],
    functions: [
      ir.Function(
        name: "f",
        params: [ir.Local("a", ir.TV128)],
        result: [ir.TV128],
        locals: [ir.Local("l", ir.TV128)],
        body: ir.Let(
          ["x"],
          ir.CallIndirect(
            "t",
            ir.Var("i"),
            ir.FuncType([ir.TV128], [ir.TV128]),
            [ir.Var("a")],
          ),
          ir.Return([ir.Var("a")]),
        ),
      ),
    ],
    exports: [],
    data_segments: [],
    tables: [ir.TableDecl("t", ir.FuncRef, 1, None)],
    elements: [],
    start: None,
    tags: [],
  )
}

pub fn v128_valtype_positions_roundtrip_test() {
  check_roundtrip(v128_valtype_module())
}

/// A `funcref` where a reftype is required rejects `v128` (`v128` is NOT a reftype): a `table`
/// declared `v128` must error (never panic), proving `parse_reftype` does not admit `v128`.
pub fn v128_is_not_a_reftype_test() {
  assert rejects("module @m { table @t v128 min 1 }")
}

// ─── memory64 & cross-module import — confirmed unchanged from Phase-5 (§A.7) ───

/// A memory64 memory + an `i64`-addressed load/store still round-trips — the `.ir` spelling of
/// `Idx64` is UNCHANGED (Phase 6 unfreezes only the memory64 RUNTIME, 05/08). A regression here
/// would surface only at conformance, so confirm it at the text layer.
pub fn memory64_ir_unchanged_roundtrip_test() {
  let m =
    ir.Module(
      ..expr_module("m64", ir.Return([])),
      memories: [ir.MemoryDecl(1, None, ir.Idx64)],
      functions: [
        ir.Function(
          name: "f",
          params: [ir.Local("a", ir.TI64)],
          result: [],
          locals: [],
          body: ir.Let(
            ["v"],
            ir.MemLoad(0, ir.MemAccess(8, False), ir.Var("a"), 0, ir.TI64),
            ir.Let(
              [],
              ir.MemStore(
                0,
                ir.MemAccess(8, False),
                ir.Var("a"),
                ir.Var("v"),
                0,
              ),
              ir.Return([]),
            ),
          ),
        ),
      ],
    )
  check_roundtrip(m)
}

/// A cross-module function import prints BYTE-IDENTICALLY to a host import (`import "A" "f" :
/// (…) -> (…)`) — the linker-built dispatch closure is a `runtime/link.gleam` value, not an IR
/// field, so there is no `.ir` change for cross-module linking (§A.7). A module that both imports
/// a function AND calls it via `CallImport` round-trips.
pub fn cross_module_import_and_callimport_roundtrip_test() {
  let m =
    ir.Module(
      name: "xmod",
      uses_numerics: True,
      memories: [],
      globals: [],
      imports: [ir.ImportFn("A", "f", ir.FuncType([ir.TI32], [ir.TI32]))],
      functions: [
        ir.Function(
          name: "caller",
          params: [ir.Local("p", ir.TI32)],
          result: [ir.TI32],
          locals: [],
          body: ir.Let(
            ["r"],
            ir.CallImport(0, ir.FuncType([ir.TI32], [ir.TI32]), [ir.Var("p")]),
            ir.Return([ir.Var("r")]),
          ),
        ),
      ],
      exports: [ir.ExportFn("caller", "caller")],
      data_segments: [],
      tables: [],
      elements: [],
      start: None,
      tags: [],
    )
  // Byte-identity of the import DECL spelling (the A.7 invariant).
  assert printer.print_module(m)
    == "module @xmod {\n"
    <> "  numerics true\n"
    <> "  memory none\n"
    <> "  import \"A\" \"f\" : (i32) -> (i32)\n"
    <> "  export \"caller\" = @caller\n"
    <> "  func @caller (%p:i32) -> (i32) {\n"
    <> "    let (%r) = call_import 0 : (i32) -> (i32) (%p)\n"
    <> "    return (%r)\n"
    <> "  }\n"
    <> "}\n"
  check_roundtrip(m)
}

// ─── the hand-authored Phase-6 golden (independent oracle) ───

/// Expected `Module` for the Phase-6 golden `golden/simd.ir` (hand-built, independent of the
/// printer). Exercises `v128.const` (NaN-payload / `-0.0` / `+Inf` / normal lanes), a spread of
/// `SimdOp`s, a `SimdShuffle`, the v128-memory family, and a `CallImport` in one module.
fn simd_module() -> ir.Module {
  ir.Module(
    name: "simd",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, None, ir.Idx32)],
    globals: [],
    imports: [ir.ImportFn("env", "sink", ir.FuncType([ir.TV128], []))],
    functions: [
      ir.Function(
        name: "run",
        params: [ir.Local("p", ir.TI32)],
        result: [ir.TV128],
        locals: [],
        body: ir.Let(
          ["k"],
          ir.Values([ir.ConstV128(v128_nan_neg0_inf_one())]),
          ir.Let(
            ["spl"],
            ir.Simd(ir.SSplat(ir.I32x4), [ir.Var("p")]),
            ir.Let(
              ["sum"],
              ir.Simd(ir.SAdd(ir.I32x4), [ir.Var("spl"), ir.Var("k")]),
              ir.Let(
                ["prod"],
                ir.Simd(ir.SFMul(ir.F32x4), [ir.Var("k"), ir.Var("k")]),
                ir.Let(
                  ["lane"],
                  ir.Simd(ir.SExtractLaneS(ir.I8x16, 3), [ir.Var("sum")]),
                  ir.Let(
                    ["wide"],
                    ir.Simd(ir.SExtend(ir.I8x16, ir.Low, True), [ir.Var("sum")]),
                    ir.Let(
                      ["narr"],
                      ir.Simd(ir.SNarrow(ir.I16x8, True), [
                        ir.Var("sum"),
                        ir.Var("prod"),
                      ]),
                      ir.Let(
                        ["sel"],
                        ir.Simd(ir.VBitselect, [
                          ir.Var("sum"),
                          ir.Var("prod"),
                          ir.Var("k"),
                        ]),
                        ir.Let(
                          ["dot"],
                          ir.Simd(ir.SDotI16x8S, [ir.Var("sum"), ir.Var("prod")]),
                          ir.Let(
                            ["swz"],
                            ir.Simd(ir.SSwizzle, [ir.Var("sum"), ir.Var("narr")]),
                            ir.Let(
                              ["shuf"],
                              ir.SimdShuffle(
                                [
                                  0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6,
                                  22, 7, 23,
                                ],
                                ir.Var("sum"),
                                ir.Var("swz"),
                              ),
                              ir.Let(
                                ["ld"],
                                ir.SimdLoad(0, ir.LoadV128, ir.Var("p"), 0),
                                ir.Let(
                                  ["splatld"],
                                  ir.SimdLoad(
                                    0,
                                    ir.LoadSplat(32),
                                    ir.Var("p"),
                                    4,
                                  ),
                                  ir.Let(
                                    [],
                                    ir.SimdStore(
                                      0,
                                      ir.Var("p"),
                                      ir.Var("ld"),
                                      16,
                                    ),
                                    ir.Let(
                                      ["ldl"],
                                      ir.SimdLoadLane(
                                        0,
                                        32,
                                        ir.Var("p"),
                                        0,
                                        1,
                                        ir.Var("ld"),
                                      ),
                                      ir.Let(
                                        [],
                                        ir.SimdStoreLane(
                                          0,
                                          8,
                                          ir.Var("p"),
                                          0,
                                          2,
                                          ir.Var("ldl"),
                                        ),
                                        ir.Let(
                                          [],
                                          ir.CallImport(
                                            0,
                                            ir.FuncType([ir.TV128], []),
                                            [ir.Var("shuf")],
                                          ),
                                          ir.Return([ir.Var("ldl")]),
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
      ),
    ],
    exports: [ir.ExportFn("run", "run")],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
    tags: [],
  )
}

/// The Phase-6 golden parses to its hand-built expected `Module` — the INDEPENDENT oracle proving
/// the printer and parser agree on the IR4 grammar delta (`v128.const`, the `SimdOp` mnemonics,
/// `SimdShuffle`, the v128-memory forms, and `CallImport`), not merely with each other (D7).
pub fn golden_simd_parses_to_expected_test() {
  assert parser.parse_module(read_golden("simd.ir")) == Ok(simd_module())
}

/// The Phase-6 golden's parsed `Module` re-prints + re-parses stably (`parse(print(m)) == m`).
pub fn golden_simd_reprint_stably_test() {
  check_roundtrip(simd_module())
}

// ─── Phase-6 negative corpus (totality, D4) ───

/// A `v128.const` whose payload is not EXACTLY 16 bytes is rejected `BadNumberLiteral` (the
/// structural well-formedness check, §A.2) — both too short and too long, and an odd-length hex
/// (rejected earlier by `hex_to_bytes`).
pub fn negative_v128_const_wrong_length_test() {
  let short =
    parser.parse_module(
      "module @m { func @f () -> () { values (v128.const 0x00) } }",
    )
  assert case short {
    Error(parser.BadNumberLiteral(_, _, _)) -> True
    _ -> False
  }
  let long =
    parser.parse_module(
      "module @m { func @f () -> () { values (v128.const 0x000000000000000000000000000000000000) } }",
    )
  assert case long {
    Error(parser.BadNumberLiteral(_, _, _)) -> True
    _ -> False
  }
  // odd-length hex → BadNumberLiteral (via hex_to_bytes), never a panic
  assert rejects("module @m { func @f () -> () { values (v128.const 0xabc) } }")
}

/// An unrecognised SIMD mnemonic is `UnknownOp` (via `string_to_simdop` Error) — a bad shape, a
/// bad op suffix, and a bad half/sign each surface as `UnknownOp`, never a panic.
pub fn negative_simd_unknown_op_test() {
  let r =
    parser.parse_module(
      "module @m { func @f () -> () { simd i32x4.bogus (%a) } }",
    )
  assert case r {
    Error(parser.UnknownOp(_, _, "i32x4.bogus")) -> True
    _ -> False
  }
  assert rejects("module @m { func @f () -> () { simd bogus.i32x4 (%a) } }")
  assert rejects(
    "module @m { func @f () -> () { simd extend.i8x16.sideways.s (%a) } }",
  )
  assert rejects("module @m { func @f () -> () { simd narrow.i16x8.q (%a) } }")
}

/// A battery of malformed SIMD / `call_import` forms: each returns a typed `Error` (never a
/// panic). Reaching the end without crashing the runner IS the totality proof for the new surface.
pub fn negative_simd_garbage_never_panic_test() {
  let garbage = [
    "module @m { func @f () -> () { simd } }",
    "module @m { func @f () -> () { simd i32x4.add } }",
    "module @m { func @f () -> () { simd i32x4.add ( } }",
    "module @m { func @f () -> () { simd.shuffle %a %b } }",
    "module @m { func @f () -> () { simd.shuffle [0, 1 %a %b } }",
    "module @m { func @f () -> () { simd.shuffle [0] %a } }",
    "module @m { func @f () -> () { simd.load } }",
    "module @m { func @f () -> () { simd.load bogus %a offset=0 } }",
    "module @m { func @f () -> () { simd.load v128 %a } }",
    "module @m { func @f () -> () { simd.load v128 %a offset= } }",
    "module @m { func @f () -> () { simd.load splat %a offset=0 } }",
    "module @m { func @f () -> () { simd.load extend 8 %a offset=0 } }",
    "module @m { func @f () -> () { simd.load extend 8 x %a offset=0 } }",
    "module @m { func @f () -> () { simd.store %a offset=0 } }",
    "module @m { func @f () -> () { simd.store %a %v } }",
    "module @m { func @f () -> () { simd.load_lane 32 %a offset=0 %v } }",
    "module @m { func @f () -> () { simd.load_lane 32 %a offset=0 lane= %v } }",
    "module @m { func @f () -> () { simd.load_lane %a offset=0 lane=0 %v } }",
    "module @m { func @f () -> () { simd.store_lane 8 %a offset=0 lane=0 } }",
    "module @m { func @f () -> () { call_import } }",
    "module @m { func @f () -> () { call_import 0 } }",
    "module @m { func @f () -> () { call_import 0 : } }",
    "module @m { func @f () -> () { call_import 0 : (i32) -> (i32) } }",
    "module @m { func @f () -> () { call_import x : (i32) -> () (%a) } }",
  ]
  assert list.all(garbage, rejects)
}

pub fn negative_garbage_inputs_never_panic_test() {
  // A battery of malformed inputs: each must return Error (never panic). Reaching the
  // end of this list without crashing the runner IS the totality proof.
  let garbage = [
    "",
    "   ",
    "module",
    "module @",
    "module @m",
    "module @m {",
    "module @m }",
    "@m { }",
    "module @m { numerics }",
    "module @m { numerics maybe }",
    "module @m { memory ( }",
    "module @m { memory (min) }",
    "module @m { func @f }",
    "module @m { func @f () }",
    "module @m { func @f () -> () }",
    "module @m { func @f () -> () { } }",
    "module @m { func @f () -> () { let } }",
    "module @m { func @f () -> () { let (%x) } }",
    "module @m { func @f () -> () { if } }",
    "module @m { func @f () -> () { return (%a,) } }",
    "module @m { func @f () -> () { convert i32.wrap_i64 } }",
    "module @m { func @f () -> () { call_host \"a\" } }",
    "}{}{}{",
    "module @m { func @f ( %p ) -> () { return () } }",
    "module @m { func @f ( %p : ) -> () { return () } }",
    // Phase-2 malformed forms (`«IR2-FROZEN»`): each must return Error, never panic.
    "module @m { table }",
    "module @m { table @t0 }",
    "module @m { table @t0 min }",
    "module @m { table @t0 min 2 max }",
    "module @m { elem }",
    "module @m { elem @t0 }",
    "module @m { elem @t0 ( values (i32.const 0) ) }",
    "module @m { elem @t0 ( values (i32.const 0) ) [ @a }",
    "module @m { elem @t0 ( values (i32.const 0) ) [ %a ] }",
    "module @m { start }",
    "module @m { start %f }",
    "module @m { func @f () -> () { mem.grow } }",
    "module @m { func @f () -> () { mem.load } }",
    "module @m { func @f () -> () { mem.load i32 } }",
    "module @m { func @f () -> () { convert trunc_s.f64 %a } }",
    "module @m { func @f () -> () { convert convert_s.f64.i32 %a } }",
    // Phase-5 malformed forms (IR3 surface): each must return Error, never panic.
    "module @m { memory i128 (min 1) }",
    "module @m { memory i64 }",
    "module @m { memory (min ) }",
    "module @m { table @t externref }",
    "module @m { elem funcref }",
    "module @m { elem funcref @t }",
    "module @m { elem funcref @t (values (i32.const 0)) }",
    "module @m { elem funcref passive }",
    "module @m { elem bogus passive [ @a ] }",
    "module @m { import \"m\" \"n\" }",
    "module @m { import \"m\" \"n\" table }",
    "module @m { import \"m\" \"n\" memory }",
    "module @m { import \"m\" \"n\" global }",
    "module @m { export \"e\" = }",
    "module @m { export \"e\" = memory }",
    "module @m { data passive }",
    "module @m { data mem=1 }",
    "module @m { func @f () -> () { ref.func } }",
    "module @m { func @f () -> () { ref.is_null } }",
    "module @m { func @f () -> () { table.get @t } }",
    "module @m { func @f () -> () { table.init @t %a %b %c } }",
    "module @m { func @f () -> () { table.copy @t %a %b %c } }",
    "module @m { func @f () -> () { elem.drop } }",
    "module @m { func @f () -> () { elem.drop seg=x } }",
    "module @m { func @f () -> () { data.drop } }",
    "module @m { func @f () -> () { mem.fill i32.const 0 } }",
    "module @m { func @f () -> () { mem.copy i32.const 0 i32.const 0 } }",
    "module @m { func @f () -> () { mem.init i32.const 0 i32.const 0 i32.const 1 } }",
    "module @m { func @f () -> () { mem.size mem= } }",
    "module @m { func @f () -> () { values (null.i32) } }",
  ]
  assert list.all(garbage, rejects)
}

// ───────────────────────────── Phase-7 EH (exception-handling IR surface) ────────
//
// The full EH-IR round-trip over the FROZEN INLINE-HANDLER shape (T1): the `Module.tags`
// declaration space (`TagDecl`, `ImportTag`, `ExportTag`), the `TExnRef` valtype + `ExnRef`
// reftype + `null.exnref` value, `Throw(tag, args)`, `ThrowRef(exnref)`, and `Try(result, body,
// handlers)` with `CatchHandler(on, payload, exnref?, handler)` over `CatchTag` (`OnTag`/`OnAll`).
// Built from the IR types + the grammar delta (specs/phase-7/ir-grammar-delta.md), never from the
// printer's output — an independent oracle, not a change-detector.

/// A representative instance of every NEW Phase-7 EH `Expr`, plus the `null.exnref` value, for the
/// round-trip. Covers: `Throw` with zero / one / many args; `ThrowRef` of a `%var` and of the
/// `null.exnref` literal; `Try` with an EMPTY handler list (a plain protected region); a `Try`
/// with each single handler kind (`catch` by tag, `catch_all`, ref-capturing `catch`/`catch_all`);
/// a `Try` combining ALL four handler kinds; a nested `try` (a `Try` inside another `Try`'s body);
/// and multi-name payload binders.
fn eh_expr_corpus() -> List(ir.Expr) {
  [
    // Throw: zero / one / many operands (arity is the tag's business, not the parser's)
    ir.Throw("stop", []),
    ir.Throw("exc", [ir.Var("a")]),
    ir.Throw("exc", [ir.Var("x"), ir.Var("xt"), ir.ConstI32(3)]),
    // ThrowRef of a caught handle and of the null exnref literal
    ir.ThrowRef(ir.Var("e")),
    ir.ThrowRef(ir.ConstNull(ir.ExnRef)),
    // null.exnref flowing as an ordinary value (opacity: the ONLY exnref literal)
    ir.Values([ir.ConstNull(ir.ExnRef)]),
    ir.Return([ir.ConstNull(ir.ExnRef)]),
    // Try with an EMPTY handler list — a bare protected region (every exception propagates)
    ir.Try([ir.TI32], ir.Values([ir.ConstI32(1)]), []),
    ir.Try([], ir.Return([]), []),
    // Try with a single `catch @tag` handler binding a multi-name payload
    ir.Try([ir.TI32], ir.Throw("exc", [ir.Var("x"), ir.Var("xt")]), [
      ir.CatchHandler(
        ir.OnTag("exc"),
        ["p0", "p1"],
        None,
        ir.Return([
          ir.Var("p0"),
        ]),
      ),
    ]),
    // Try with a single `catch_all` (no payload)
    ir.Try([], ir.Throw("stop", []), [
      ir.CatchHandler(ir.OnAll, [], None, ir.Return([])),
    ]),
    // Try with a ref-capturing `catch @tag` (`catch_ref`) — binds the exnref, re-throws it
    ir.Try([ir.TExnRef], ir.Throw("exc", [ir.Var("x")]), [
      ir.CatchHandler(
        ir.OnTag("exc"),
        ["p0"],
        Some("e"),
        ir.ThrowRef(ir.Var("e")),
      ),
    ]),
    // Try with a ref-capturing `catch_all` (`catch_all_ref`)
    ir.Try([ir.TExnRef], ir.Throw("stop", []), [
      ir.CatchHandler(ir.OnAll, [], Some("e"), ir.Return([ir.Var("e")])),
    ]),
    // Try combining ALL four handler kinds in one region (order preserved)
    ir.Try([ir.TI32], ir.Throw("exc", [ir.Var("x"), ir.Var("xt")]), [
      ir.CatchHandler(
        ir.OnTag("exc"),
        ["p0", "p1"],
        None,
        ir.Return([
          ir.Var("p1"),
        ]),
      ),
      ir.CatchHandler(
        ir.OnTag("exc"),
        ["q0", "q1"],
        Some("e0"),
        ir.ThrowRef(ir.Var("e0")),
      ),
      ir.CatchHandler(ir.OnAll, [], None, ir.Return([ir.ConstI32(0)])),
      ir.CatchHandler(ir.OnAll, [], Some("e1"), ir.ThrowRef(ir.Var("e1"))),
    ]),
    // nested try: a `Try` whose body is itself a `Try` (and whose handler is a `Try`)
    ir.Try(
      [ir.TI32],
      ir.Try([ir.TI32], ir.Throw("exc", [ir.Var("x"), ir.Var("xt")]), [
        ir.CatchHandler(
          ir.OnTag("exc"),
          ["p0", "p1"],
          None,
          ir.Return([
            ir.Var("p0"),
          ]),
        ),
      ]),
      [ir.CatchHandler(ir.OnAll, [], None, ir.Return([ir.ConstI32(9)]))],
    ),
  ]
}

pub fn eh_expr_surface_roundtrip_test() {
  list.each(eh_expr_corpus(), fn(e) { check_roundtrip(expr_module("eh", e)) })
}

/// The `TExnRef` value type is legal — and round-trips — in EVERY valtype position: a param, a
/// local, a function result, a `FuncType` (via `call_indirect`), an imported global's type, and a
/// module global's declared type (with a `null.exnref` initialiser). Mirrors the funcref/externref
/// and v128 positional round-trips.
fn exnref_valtype_module() -> ir.Module {
  ir.Module(
    name: "exnpos",
    uses_numerics: True,
    memories: [],
    globals: [
      ir.GlobalDecl(
        "ge",
        ir.TExnRef,
        True,
        ir.Values([ir.ConstNull(ir.ExnRef)]),
      ),
    ],
    imports: [ir.ImportGlobal("env", "ie", ir.TExnRef, False)],
    functions: [
      ir.Function(
        name: "f",
        params: [ir.Local("a", ir.TExnRef)],
        result: [ir.TExnRef],
        locals: [ir.Local("l", ir.TExnRef)],
        body: ir.Let(
          ["x"],
          ir.CallIndirect(
            "t",
            ir.Var("i"),
            ir.FuncType([ir.TExnRef], [ir.TExnRef]),
            [ir.Var("a")],
          ),
          ir.Return([ir.Var("a")]),
        ),
      ),
    ],
    exports: [],
    data_segments: [],
    tables: [ir.TableDecl("t", ir.FuncRef, 1, None)],
    elements: [],
    start: None,
    tags: [],
  )
}

pub fn exnref_valtype_positions_roundtrip_test() {
  check_roundtrip(exnref_valtype_module())
}

/// The tag declaration space round-trips at every shape: a multi-param module tag (the Porffor
/// `(f64, i32)` carrier), a NULLARY (`()`) module tag, an imported tag, and an exported tag — all
/// in one module.
fn tag_space_module() -> ir.Module {
  ir.Module(
    name: "tags",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [ir.ImportTag("env", "host_exc", [ir.TI32])],
    functions: [],
    exports: [ir.ExportTag("exc", "exc")],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
    tags: [ir.TagDecl("exc", [ir.TF64, ir.TI32]), ir.TagDecl("stop", [])],
  )
}

pub fn tag_space_roundtrip_test() {
  check_roundtrip(tag_space_module())
}

/// `ExnRef` is a full `RefType`: an `exnref`-typed table and an `exnref` element segment (with a
/// `null.exnref` slot) round-trip — the reftype/null machinery carries the new reference type in
/// every reftype position (spec-conformance surface, T9). Porffor never emits these, but the IR is
/// capable and the printer/parser must not drop them.
fn exnref_reftype_module() -> ir.Module {
  ir.Module(
    ..expr_module("exnrt", ir.Return([])),
    tables: [ir.TableDecl("et", ir.ExnRef, 1, Some(4))],
    elements: [
      ir.ElementSegment(ir.ElemPassive, ir.ExnRef, [
        ir.Values([ir.ConstNull(ir.ExnRef)]),
      ]),
    ],
  )
}

pub fn exnref_reftype_positions_roundtrip_test() {
  check_roundtrip(exnref_reftype_module())
}

// ─── the hand-authored Phase-7 golden (independent oracle) ───

/// Expected `Module` for the Phase-7 golden `golden/exn.ir` (hand-built, INDEPENDENT of the
/// printer). Exercises the full EH-IR surface in one module: two module tags (multi-param +
/// nullary), an imported tag, an exported tag, the exnref value type (param + result), the
/// `null.exnref` literal, `Throw`, a `Try` whose handlers cover `catch` / `catch_all` /
/// ref-capturing `catch` / ref-capturing `catch_all`, and `ThrowRef`.
fn exn_module() -> ir.Module {
  ir.Module(
    name: "exn",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [ir.ImportTag("env", "host_exc", [ir.TI32])],
    functions: [
      ir.Function(
        name: "guarded",
        params: [ir.Local("x", ir.TF64), ir.Local("xt", ir.TI32)],
        result: [ir.TI32],
        locals: [],
        body: ir.Try([ir.TI32], ir.Throw("exc", [ir.Var("x"), ir.Var("xt")]), [
          ir.CatchHandler(
            ir.OnTag("exc"),
            ["p0", "p1"],
            None,
            ir.Return([
              ir.Var("p1"),
            ]),
          ),
          ir.CatchHandler(ir.OnAll, [], None, ir.Return([ir.ConstI32(0)])),
        ]),
      ),
      ir.Function(
        name: "capture",
        params: [ir.Local("x", ir.TF64), ir.Local("xt", ir.TI32)],
        result: [ir.TExnRef],
        locals: [],
        body: ir.Try(
          [ir.TExnRef],
          ir.Throw("exc", [ir.Var("x"), ir.Var("xt")]),
          [
            ir.CatchHandler(
              ir.OnTag("exc"),
              ["p0", "p1"],
              Some("e"),
              ir.Return([ir.Var("e")]),
            ),
            ir.CatchHandler(ir.OnAll, [], Some("e"), ir.Return([ir.Var("e")])),
          ],
        ),
      ),
      ir.Function(
        name: "rethrow",
        params: [ir.Local("e", ir.TExnRef)],
        result: [],
        locals: [],
        body: ir.ThrowRef(ir.Var("e")),
      ),
      ir.Function(
        name: "nullexn",
        params: [],
        result: [ir.TExnRef],
        locals: [],
        body: ir.Return([ir.ConstNull(ir.ExnRef)]),
      ),
    ],
    exports: [ir.ExportTag("exc", "exc")],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
    tags: [ir.TagDecl("exc", [ir.TF64, ir.TI32]), ir.TagDecl("stop", [])],
  )
}

/// The Phase-7 golden parses to its hand-built expected `Module` — the INDEPENDENT oracle proving
/// the printer and parser agree on the EH grammar delta (the tag space, exnref/null.exnref, Throw,
/// the inline-handler Try + its catch-handler list, and ThrowRef), not merely with each other (D7).
pub fn golden_exn_parses_to_expected_test() {
  assert parser.parse_module(read_golden("exn.ir")) == Ok(exn_module())
}

/// The Phase-7 golden's parsed `Module` re-prints + re-parses stably (`parse(print(m)) == m`).
pub fn golden_exn_reprint_stably_test() {
  check_roundtrip(exn_module())
}

// ─── Phase-7 discrimination (no EH field dropped) ───

/// A `catch @tag` (`OnTag`) handler vs a `catch_all` (`OnAll`) handler, else identical, are
/// DISTINCT modules and each round-trips — the `CatchTag` selector is not collapsed.
pub fn catch_tag_vs_catch_all_discrimination_test() {
  let on_tag =
    expr_module(
      "ct",
      ir.Try([], ir.Throw("t", []), [
        ir.CatchHandler(ir.OnTag("t"), [], None, ir.Return([])),
      ]),
    )
  let on_all =
    expr_module(
      "ct",
      ir.Try([], ir.Throw("t", []), [
        ir.CatchHandler(ir.OnAll, [], None, ir.Return([])),
      ]),
    )
  assert module_equal(on_tag, on_all) == False
  check_roundtrip(on_tag)
  check_roundtrip(on_all)
}

/// A ref-capturing handler (`exnref: Some(name)`) vs a non-capturing one (`None`), else identical,
/// are DISTINCT modules and each round-trips — the `_ref` capture flag (` ref %e`) is not dropped.
pub fn catch_capture_ref_discrimination_test() {
  let capturing =
    expr_module(
      "cr",
      ir.Try([], ir.Throw("t", []), [
        ir.CatchHandler(ir.OnTag("t"), [], Some("e"), ir.Return([])),
      ]),
    )
  let plain =
    expr_module(
      "cr",
      ir.Try([], ir.Throw("t", []), [
        ir.CatchHandler(ir.OnTag("t"), [], None, ir.Return([])),
      ]),
    )
  assert module_equal(capturing, plain) == False
  check_roundtrip(capturing)
  check_roundtrip(plain)
}

/// Two `Throw`s that differ only in their tag NAME are DISTINCT modules and each round-trips — the
/// `Throw.tag` string is not dropped (tag identity, T4).
pub fn throw_tag_name_discrimination_test() {
  let a = expr_module("tn", ir.Throw("alpha", [ir.Var("x")]))
  let b = expr_module("tn", ir.Throw("beta", [ir.Var("x")]))
  assert module_equal(a, b) == False
  check_roundtrip(a)
  check_roundtrip(b)
}

/// Two module tags with the same NAME but different operand type lists are DISTINCT and each
/// round-trips — the `TagDecl.params` list is carried losslessly (a tag's operand signature).
pub fn tag_params_discrimination_test() {
  let base = expr_module("tp", ir.Return([]))
  let i32_tag = ir.Module(..base, tags: [ir.TagDecl("t", [ir.TI32])])
  let i64_tag = ir.Module(..base, tags: [ir.TagDecl("t", [ir.TI64])])
  let nullary = ir.Module(..base, tags: [ir.TagDecl("t", [])])
  assert module_equal(i32_tag, i64_tag) == False
  assert module_equal(i32_tag, nullary) == False
  check_roundtrip(i32_tag)
  check_roundtrip(i64_tag)
  check_roundtrip(nullary)
}

/// A `ConstNull(ExnRef)` (`null.exnref`) is DISTINCT from `ConstNull(FuncRef)` / `ConstNull(
/// ExternRef)` and each round-trips — the null literal's static reftype is not dropped, and the
/// new exnref reftype does not collide with the existing two.
pub fn null_exnref_discrimination_test() {
  let ex = expr_module("ne", ir.Values([ir.ConstNull(ir.ExnRef)]))
  let fr = expr_module("ne", ir.Values([ir.ConstNull(ir.FuncRef)]))
  let er = expr_module("ne", ir.Values([ir.ConstNull(ir.ExternRef)]))
  assert module_equal(ex, fr) == False
  assert module_equal(ex, er) == False
  check_roundtrip(ex)
}

// ─── Phase-7 conformance-neutrality (J6): a tag-free module carries NO EH token ───

/// A Phase-1..6-shaped module (no tag, no `exnref`, no EH node) prints with NONE of the EH
/// keywords, so an EH regression that leaked a token into legacy output fails closed. The control
/// module deliberately uses names/ops that do not themselves contain an EH substring.
pub fn tag_free_module_has_no_eh_token_test() {
  let m =
    ir.Module(
      name: "plain",
      uses_numerics: True,
      memories: [],
      globals: [],
      imports: [ir.ImportFn("env", "log", ir.FuncType([ir.TI32], []))],
      functions: [
        ir.Function(
          name: "f",
          params: [ir.Local("p", ir.TI32)],
          result: [ir.TI32],
          locals: [],
          body: ir.Return([ir.Var("p")]),
        ),
      ],
      exports: [ir.ExportFn("main", "f")],
      data_segments: [],
      tables: [],
      elements: [],
      start: None,
      tags: [],
    )
  let text = printer.print_module(m)
  assert string.contains(text, "tag") == False
  assert string.contains(text, "exnref") == False
  assert string.contains(text, "throw") == False
  assert string.contains(text, "try") == False
  assert string.contains(text, "catch") == False
  // and it still round-trips
  check_roundtrip(m)
}

// ─── Phase-7 negative corpus (totality, D4) ───

/// A malformed `throw` — a `%local` where the `@tag` name is required — is a typed error
/// (`BadSigil`), never a panic (the `@tag`/`%local`/`$label` sigils are checked, J1/J5).
pub fn negative_throw_local_for_tag_test() {
  let r =
    parser.parse_module("module @m { func @f () -> () { throw %x (%a) } }")
  assert case r {
    Error(parser.BadSigil(_, _, _)) -> True
    _ -> False
  }
}

/// An unknown catch word inside a `try` handler list surfaces as a typed error, never a panic —
/// `catch`/`catch_all` are the only recognised clause words.
pub fn negative_unknown_catch_word_test() {
  let r =
    parser.parse_module(
      "module @m { func @f () -> () { try (i32) { return (i32.const 0) } grab @t (%p) { return (%p) } } }",
    )
  // The `grab` word is not a catch clause, so the handler list ends and the `try` completes; the
  // stray `grab` is then rejected where the function body's `}` is expected — a typed error.
  assert case r {
    Error(_) -> True
    _ -> False
  }
}

/// A battery of malformed EH forms: each returns a typed `Error` (never a panic). Reaching the end
/// without crashing the runner IS the totality proof for the new EH surface.
pub fn negative_eh_garbage_never_panic_test() {
  let garbage = [
    // throw
    "module @m { func @f () -> () { throw } }",
    "module @m { func @f () -> () { throw @t } }",
    "module @m { func @f () -> () { throw (%a) } }",
    "module @m { func @f () -> () { throw @t (%a } }",
    // throw_ref
    "module @m { func @f () -> () { throw_ref } }",
    "module @m { func @f () -> () { throw_ref @t } }",
    // try: missing result list / brace / body
    "module @m { func @f () -> () { try } }",
    "module @m { func @f () -> () { try (i32) } }",
    "module @m { func @f () -> () { try (i32) return (i32.const 0) } }",
    "module @m { func @f () -> () { try (i32) { } }",
    "module @m { func @f () -> () { try (i32) { return (i32.const 0) } }",
    // catch: missing tag / payload / body
    "module @m { func @f () -> () { try (i32) { return (i32.const 0) } catch (%p) { return (%p) } } }",
    "module @m { func @f () -> () { try (i32) { return (i32.const 0) } catch @t { return () } } }",
    "module @m { func @f () -> () { try (i32) { return (i32.const 0) } catch @t (%p) } }",
    // catch_all does not take a tag
    "module @m { func @f () -> () { try (i32) { return (i32.const 0) } catch_all @t (%p) { return () } } }",
    // ref clause without a name
    "module @m { func @f () -> () { try (i32) { return (i32.const 0) } catch @t (%p) ref { return () } } }",
    // module-level tag / import-tag / export-tag malformed
    "module @m { tag }",
    "module @m { tag @t }",
    "module @m { tag @t (bogus) }",
    "module @m { import \"a\" \"b\" tag }",
    "module @m { export \"e\" = tag }",
    // exnref where a non-reference position is required (a bad table sizing after it)
    "module @m { table @t exnref }",
  ]
  assert list.all(garbage, rejects)
}
