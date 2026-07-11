//// Tests for `twocore/frontend/wasm/lower` (Unit 10b).
////
//// Two kinds of assertion, both against the spec rather than the implementation:
////
//// 1. **Structural** — decode → validate → lower a real `wat2wasm` fixture and assert
////    the shared-IR shape the spec/IR demand: numerics on & memory off; a WASM `loop`
////    with mutable locals becomes an `ir.Loop` carrying `LoopParam`s; branches resolve
////    to NAMED labels (`Break`/`Continue`), never a numeric depth (D6); a self-`call`
////    becomes `CallDirect`.
//// 2. **End-to-end** — lower → `emit_core` → `build_beam` → RUN the export on the BEAM
////    and assert SPEC-CORRECT results (`add(2,3)=5`, two's-complement wrap,
////    `sum_to(100)=5050`, `fib(10)=55`). This exercises the whole frontend+backend chain
////    on real `.wasm` bytes.

import gleam/bit_array
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import gleam/set
import gleeunit/should
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/lower
import twocore/frontend/wasm/validate
import twocore/frontend/wasm/wat
import twocore/ir
import twocore/ir/parser
import twocore/ir/printer
import twocore/runtime/instance

// Test-only FFI (shared with the unit-08 e2e suite): apply `M:F(Args)` and capture a
// trap as `Error(text)` instead of crashing the runner.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

// ───────────────────────────── pipeline plumbing ─────────────────────────────

/// Decode → validate → lower `bytes` into a shared-IR module. Each stage must
/// succeed (these are valid fixtures); a failure is a genuine test failure.
fn build(bytes: BitArray) -> ir.Module {
  let assert Ok(m) = decode.decode(bytes)
  let assert Ok(typed) = validate.validate(m)
  let assert Ok(irm) = lower.lower(typed)
  irm
}

/// Emit `irm` to Core text, compile it, and load it into the test VM (D10).
fn load(irm: ir.Module) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(irm, instance.safe_default())
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

/// Every expression in `e`'s tree (itself plus all nested sub-expressions), for
/// structural inspection.
fn all_exprs(e: ir.Expr) -> List(ir.Expr) {
  let nested = case e {
    ir.Let(_, rhs, body) -> list.append(all_exprs(rhs), all_exprs(body))
    ir.Block(_, _, body) -> all_exprs(body)
    ir.Loop(_, _, _, body) -> all_exprs(body)
    ir.If(_, _, t, el) -> list.append(all_exprs(t), all_exprs(el))
    ir.Switch(_, _, arms, default) ->
      list.append(
        list.flat_map(arms, fn(a) { all_exprs(a.body) }),
        all_exprs(default),
      )
    ir.Charge(_, body) -> all_exprs(body)
    _ -> []
  }
  [e, ..nested]
}

/// The single defined function named `name`.
fn func(irm: ir.Module, name: String) -> ir.Function {
  let assert Ok(f) = list.find(irm.functions, fn(f) { f.name == name })
  f
}

/// A `BitArray` as a list of its bytes (for fuzz mutation).
fn ba_to_list(ba: BitArray) -> List(Int) {
  case ba {
    <<b:8, rest:bits>> -> [b, ..ba_to_list(rest)]
    _ -> []
  }
}

/// A list of bytes back into a `BitArray`.
fn list_to_ba(ints: List(Int)) -> BitArray {
  list.fold(ints, <<>>, fn(acc, b) { <<acc:bits, b:8>> })
}

/// Replace the byte at `idx` with `val` (a fresh list).
fn replace(ints: List(Int), idx: Int, val: Int) -> List(Int) {
  list.index_map(ints, fn(b, i) {
    case i == idx {
      True -> val
      False -> b
    }
  })
}

/// Inclusive integer range `[from, to]`.
fn int_range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..int_range(from + 1, to)]
  }
}

// ───────────────────────────── module-level shape ─────────────────────────────

/// A lowered WASM module turns numerics ON and links no memory (D5): the Phase-1
/// capability axes.
pub fn module_flags_test() {
  let irm = build(add_wasm)
  irm.uses_numerics |> should.equal(True)
  irm.memories |> should.equal([])
}

/// The export survives lowering: `add` is exported (resolving to the function's IR
/// name).
pub fn export_preserved_test() {
  let irm = build(add_wasm)
  list.any(irm.exports, fn(e) {
    case e {
      ir.ExportFn(export_name, _) -> export_name == "add"
      ir.ExportGlobal(..)
      | ir.ExportTable(..)
      | ir.ExportMemory(..)
      | ir.ExportTag(..) -> False
    }
  })
  |> should.equal(True)
}

// ───────────────────────────── add: a single neutral numeric op ─────────────────────────────

/// `add` lowers to a function with a single neutral, width-tagged `Num(IAdd(W32), …)`
/// (D6 — never a WASM opcode string), over the two params.
pub fn add_structure_test() {
  let irm = build(add_wasm)
  let f = func(irm, "f0")
  f.result |> should.equal([ir.TI32])
  list.length(f.params) |> should.equal(2)
  // The body contains exactly the i32 add (neutral op, width 32).
  let adds =
    all_exprs(f.body)
    |> list.filter(fn(e) {
      case e {
        ir.Num(ir.IAdd(ir.W32), _) -> True
        _ -> False
      }
    })
  list.length(adds) |> should.equal(1)
}

// ───────────────────────────── sum_to: loop with carried locals ─────────────────────────────

/// `sum_to`'s WASM `loop` with the mutable locals `i`,`acc` lowers to an `ir.Loop`
/// carrying TWO `LoopParam`s (the spec mutable-locals → SSA promotion). This is exactly
/// why a loop body that *writes* locals across the back-edge must thread them as
/// loop-carried values. Both are i32; `i`'s init is the absorbed `local.set $i 1`
/// (`ConstI32(1)`), `acc`'s init is its zero-init binding (a `Var` — declared locals are
/// zero-initialised by an explicit `Let`, since emit_core ignores `Function.locals`).
pub fn sum_to_loop_params_test() {
  let irm = build(sum_to_wasm)
  let f = func(irm, "f0")
  let loops =
    all_exprs(f.body)
    |> list.filter_map(fn(e) {
      case e {
        ir.Loop(_, params, _, _) -> Ok(params)
        _ -> Error(Nil)
      }
    })
  // Exactly one loop, carrying the two mutated locals (both i32).
  let assert [params] = loops
  list.length(params) |> should.equal(2)
  list.map(params, fn(p) { p.ty }) |> should.equal([ir.TI32, ir.TI32])
  let assert [i_param, acc_param] = params
  // i is initialised to 1 (the pre-loop `local.set` is absorbed into the loop init).
  i_param.init |> should.equal(ir.ConstI32(1))
  // acc threads its zero-init binding in (a named reference, not an inline const).
  case acc_param.init {
    ir.Var(_) -> True
    _ -> False
  }
  |> should.equal(True)
}

/// Branches are resolved to NAMED labels, not numeric depths (D6): the `br $cont`
/// back-edge is a `Continue` naming the loop's own label, and the `br_if $break` exit
/// is a `Break` naming the enclosing block's label. Every referenced label is a label
/// actually defined by a `Block`/`Loop` in the function (no dangling depth).
pub fn sum_to_named_labels_test() {
  let irm = build(sum_to_wasm)
  let f = func(irm, "f0")
  let exprs = all_exprs(f.body)

  let loop_labels =
    list.filter_map(exprs, fn(e) {
      case e {
        ir.Loop(label, _, _, _) -> Ok(label)
        _ -> Error(Nil)
      }
    })
  let block_labels =
    list.filter_map(exprs, fn(e) {
      case e {
        ir.Block(label, _, _) -> Ok(label)
        _ -> Error(Nil)
      }
    })
  let continue_labels =
    list.filter_map(exprs, fn(e) {
      case e {
        ir.Continue(label, _) -> Ok(label)
        _ -> Error(Nil)
      }
    })
  let break_labels =
    list.filter_map(exprs, fn(e) {
      case e {
        ir.Break(label, _) -> Ok(label)
        _ -> Error(Nil)
      }
    })

  // A back-edge Continue names the loop; an exit Break names the block.
  list.all(continue_labels, fn(l) { list.contains(loop_labels, l) })
  |> should.equal(True)
  list.all(break_labels, fn(l) { list.contains(block_labels, l) })
  |> should.equal(True)
  // Both transfers are actually present.
  { list.length(continue_labels) >= 1 } |> should.equal(True)
  { list.length(break_labels) >= 1 } |> should.equal(True)
}

// ───────────────────────────── fib: if + self-call ─────────────────────────────

/// `fib` lowers to an `If` (two arms, i32 result) and a direct self-`call` to its own
/// IR name (`CallDirect`, not a stack op).
pub fn fib_if_and_call_test() {
  let irm = build(fib_wasm)
  let f = func(irm, "f0")
  let exprs = all_exprs(f.body)
  // There is an If yielding a single i32.
  list.any(exprs, fn(e) {
    case e {
      ir.If(_, [ir.TI32], _, _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
  // Two direct self-calls fib(n-1), fib(n-2).
  let calls =
    list.filter(exprs, fn(e) {
      case e {
        ir.CallDirect("f0", _) -> True
        _ -> False
      }
    })
  list.length(calls) |> should.equal(2)
}

// ───────────────────────────── Phase-2: linear memory ─────────────────────────────

/// A memory program lowers each load/store opcode to a `MemLoad`/`MemStore` carrying the
/// SPEC-correct `MemAccess(bytes, signed)` and (for loads) `result` type — cite
/// binary/instructions. Crucially `i32.load8_s` and `i64.load8_s` share `MemAccess(1, True)`
/// but differ in `result` (`TI32` vs `TI64`) — exactly why `MemLoad` carries `result` (E2).
/// `f32.load` is byte-identical to `i32.load` (`MemAccess(4, False)`) but `result: TF32`
/// (raw bits, D5). `i32.store` is `MemAccess(4, False)` (sign irrelevant on a store).
pub fn mem_load_store_structure_test() {
  let irm = build(mem_wasm)
  let f = func(irm, "f0")
  let exprs = all_exprs(f.body)
  let loads =
    list.filter_map(exprs, fn(e) {
      case e {
        ir.MemLoad(_, op, _, _, result) -> Ok(#(op, result))
        _ -> Error(Nil)
      }
    })
  let stores =
    list.filter_map(exprs, fn(e) {
      case e {
        ir.MemStore(_, op, _, _, _) -> Ok(op)
        _ -> Error(Nil)
      }
    })
  // i32.load8_s ⇒ MemAccess(1, True) + TI32
  list.contains(loads, #(ir.MemAccess(1, True), ir.TI32)) |> should.equal(True)
  // i64.load8_s ⇒ MemAccess(1, True) + TI64 (same access bytes+sign, different result)
  list.contains(loads, #(ir.MemAccess(1, True), ir.TI64)) |> should.equal(True)
  // f32.load ⇒ MemAccess(4, False) + TF32
  list.contains(loads, #(ir.MemAccess(4, False), ir.TF32)) |> should.equal(True)
  // i32.load ⇒ MemAccess(4, False) + TI32
  list.contains(loads, #(ir.MemAccess(4, False), ir.TI32)) |> should.equal(True)
  // i32.store ⇒ MemAccess(4, False) (signed always False on a store)
  list.contains(stores, ir.MemAccess(4, False)) |> should.equal(True)
}

/// `memory.grow` lowers to a `MemGrow(delta)` (the delta carried as a value) and
/// `memory.size` to `MemSize` — cite binary/instructions (0x40 / 0x3F). The module also
/// declares its memory, so `Module.memory` is `Some`.
pub fn mem_size_grow_test() {
  let irm = build(grow_wasm)
  let f = func(irm, "f0")
  let exprs = all_exprs(f.body)
  list.any(exprs, fn(e) {
    case e {
      ir.MemGrow(_, _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
  list.any(exprs, fn(e) { e == ir.MemSize(0) }) |> should.equal(True)
  case irm.memories {
    [_, ..] -> True
    [] -> False
  }
  |> should.equal(True)
}

// ───────────────────────────── Phase-2: globals ─────────────────────────────

/// A global program lowers `global.set`/`global.get` to `GlobalSet`/`GlobalGet` referencing
/// the STABLE name `g<idx>` (here `g0`), and `Module.globals` is populated with bit-exact,
/// type-correct `GlobalDecl`s in index order (a mutable i32 init `100`, an immutable i64
/// init `7`). The `GlobalGet/Set` names match the declared global names.
pub fn globals_test() {
  let irm = build(global_wasm)
  let f = func(irm, "f0")
  let exprs = all_exprs(f.body)
  list.any(exprs, fn(e) {
    case e {
      ir.GlobalSet("g0", ir.ConstI32(5)) -> True
      _ -> False
    }
  })
  |> should.equal(True)
  list.any(exprs, fn(e) { e == ir.GlobalGet("g0") }) |> should.equal(True)
  // Module.globals populated, in declaration (= index) order, with the const-literal inits.
  irm.globals
  |> should.equal([
    ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(100)])),
    ir.GlobalDecl("g1", ir.TI64, False, ir.Values([ir.ConstI64(7)])),
  ])
}

// ───────────────────────────── Phase-2: tables + call_indirect ─────────────────────────────

/// `call_indirect (type $t) (i32.const 0)` lowers to a single `CallIndirect("t0", index, ty,
/// args)` whose `ty` is the STRUCTURAL `module.types[y]` (`FuncType([], [TI32])` here) — the
/// runtime does the per-call type check (E3). The table is named `"t0"` (the MVP reserved
/// table 0). `Module.tables` and `Module.elements` are populated; the element's target name is
/// `"f<funcidx>"` (`"f0"`), which resolves to a real `Function`.
pub fn call_indirect_structure_test() {
  let irm = build(ci_full_wasm)
  let f = func(irm, "f1")
  let exprs = all_exprs(f.body)
  list.any(exprs, fn(e) {
    case e {
      ir.CallIndirect("t0", ir.ConstI32(0), ir.FuncType([], [ir.TI32]), []) ->
        True
      _ -> False
    }
  })
  |> should.equal(True)
  // Table declared and named "t0".
  irm.tables |> should.equal([ir.TableDecl("t0", ir.FuncRef, 1, option.None)])
  // Active element segment into "t0" at offset 0, targeting function name "f0".
  irm.elements
  |> should.equal([
    ir.ElementSegment(
      ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
      ir.FuncRef,
      [ir.RefFunc("f0")],
    ),
  ])
  // The element target name resolves to a real defined function.
  list.any(irm.functions, fn(fn_) { fn_.name == "f0" }) |> should.equal(True)
}

// ───────────────────────────── Phase-2: select → If ─────────────────────────────

/// `select` (0x1B) lowers to the existing `If` (NO new IR node). Per exec/instructions the
/// result is `val1` when `cond ≠ 0`, else `val2`; so the lowered `If`'s then-branch is
/// `Values([val1])` (the first/deeper operand) and the else-branch is `Values([val2])`. The
/// operands are i32 here, so the `If` result arity is 1 and its type is `[TI32]`.
pub fn select_test() {
  let irm = build(select_wasm)
  let f = func(irm, "f0")
  let exprs = all_exprs(f.body)
  list.any(exprs, fn(e) {
    case e {
      ir.If(
        ir.Var("p2"),
        [ir.TI32],
        ir.Values([ir.Var("p0")]),
        ir.Values([ir.Var("p1")]),
      ) -> True
      _ -> False
    }
  })
  |> should.equal(True)
}

/// A `select` over i64 operands recovers `TI64` as the result type — proving the SSA
/// value-type tracking (a select's result type is operand-determined, not opcode-determined,
/// §5). The lowered `If` carries `[TI64]`.
pub fn select_i64_test() {
  let irm = build(select64_wasm)
  let f = func(irm, "f0")
  let exprs = all_exprs(f.body)
  list.any(exprs, fn(e) {
    case e {
      ir.If(_, [ir.TI64], _, _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
}

// ───────────────────────────── Phase-2: the conversion block ─────────────────────────────

/// The `0xA7–0xBF` conversion block lowers each opcode to its IR `ConvOp` (cite
/// binary/instructions): wrap/extend/reinterpret reuse the EXISTING ConvOps, and the TRAPPING
/// trunc maps to `TruncS/U` (DISTINCT from the saturating `TruncSat*`). lower does not mark
/// the trapping trunc — emit_core wires the trap.
pub fn conversions_test() {
  let irm = build(conv_wasm)
  let f = func(irm, "f0")
  let convs =
    list.filter_map(all_exprs(f.body), fn(e) {
      case e {
        ir.Convert(op, _) -> Ok(op)
        _ -> Error(Nil)
      }
    })
  // wrap / extend → existing ConvOps
  list.contains(convs, ir.I32WrapI64) |> should.equal(True)
  list.contains(convs, ir.I64ExtendI32S) |> should.equal(True)
  list.contains(convs, ir.I64ExtendI32U) |> should.equal(True)
  // the 4 reinterprets → existing ReinterpretFToI / ReinterpretIToF
  list.contains(convs, ir.ReinterpretFToI(ir.FW32)) |> should.equal(True)
  list.contains(convs, ir.ReinterpretIToF(ir.W32)) |> should.equal(True)
  list.contains(convs, ir.ReinterpretFToI(ir.FW64)) |> should.equal(True)
  // trapping trunc → TruncS/U (NOT TruncSat*)
  list.contains(convs, ir.TruncU(ir.FW64, ir.W32)) |> should.equal(True)
  list.contains(convs, ir.TruncS(ir.FW32, ir.W32)) |> should.equal(True)
  // None of these are the saturating family.
  list.any(convs, fn(op) {
    case op {
      ir.TruncSatS(_, _) | ir.TruncSatU(_, _) -> True
      _ -> False
    }
  })
  |> should.equal(False)
}

// ───────────────────────────── Phase-2: float arithmetic ─────────────────────────────

/// `f64.add` lowers to the neutral, width-tagged `Num(FAdd(FW64), …)` (D6) — the float
/// arith ops share the integer NumOp shape, just at a float width.
pub fn float_add_structure_test() {
  let irm = build(fadd_wasm)
  let f = func(irm, "f0")
  f.result |> should.equal([ir.TF64])
  list.any(all_exprs(f.body), fn(e) {
    case e {
      ir.Num(ir.FAdd(ir.FW64), _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
}

/// END-TO-END: `f64.add` runs spec-correctly through lower → emit_core → `rt_num` → BEAM.
/// Floats are raw IEEE-754 bit patterns end-to-end (D5): `1.5 + 2.5 == 4.0` is asserted on
/// the bit patterns (`0x3FF8…` + `0x4004…` == `0x4010…`). This proves the float-arith
/// lowering composes with the existing backend, not just that the IR shape is right.
pub fn float_add_e2e_test() {
  let mod = load(build(fadd_wasm))
  // 1.5 = 4609434218613702656, 2.5 = 4612811918334230528, 4.0 = 4616189618054758400
  catch_apply(mod, atom.create("fadd"), [
    4_609_434_218_613_702_656,
    4_612_811_918_334_230_528,
  ])
  |> should.equal(Ok(4_616_189_618_054_758_400))
}

// ───────────────────────────── Phase-2: module decls (memory/data/start) ─────────────────────────────

/// A module with a memory, an active data segment, and a `start` function populates
/// `Module.memory` (`Some`), `Module.data_segments` (the offset const-expr + raw bytes), and
/// `Module.start` (`Some("f<funcidx>")`). The data bytes are bit-exact (`"abc"`).
pub fn data_start_test() {
  let irm = build(data_start_wasm)
  irm.memories |> should.equal([ir.MemoryDecl(1, option.None, ir.Idx32)])
  irm.data_segments
  |> should.equal([
    ir.DataSegment(
      ir.DataActive(0, ir.Values([ir.ConstI32(0)])),
      bit_array.from_string("abc"),
    ),
  ])
  irm.start |> should.equal(option.Some("f0"))
}

// ───────────────────────────── Phase-2: .ir round-trip (unit 02) ─────────────────────────────

/// The lowered IR with the new Phase-2 variants round-trips through the `.ir` printer+parser
/// (D7, unit 02): `parse(print(m)) == m` (bit-exact, since the IR stores floats/ints as raw
/// bit patterns). Exercised over a memory module, a global module, a table+element module, and
/// a conversion module — covering `MemLoad`/`MemStore`/`MemSize`/`MemGrow`/`GlobalGet`/
/// `GlobalSet`/`CallIndirect`/`TableDecl`/`ElementSegment`/`GlobalDecl`/`DataSegment` and the
/// new ConvOps.
pub fn ir_roundtrip_test() {
  [mem_wasm, grow_wasm, global_wasm, ci_full_wasm, conv_wasm, data_start_wasm]
  |> list.each(fn(bytes) {
    let m = build(bytes)
    let assert Ok(reparsed) = parser.parse_module(printer.print_module(m))
    reparsed |> should.equal(m)
  })
}

// ───────────────────────────── Phase-2: fail-closed const-expr ─────────────────────────────

/// A non-constant init expression (an extended-const `i32.add` chain in a global) is rejected
/// with a typed `Error(NonConstInitExpr(_))`, never a panic (D4 fail-closed). Validation
/// already blocks this, so the case is reached by handing `lower` a `TypedModule` directly —
/// proving the constructive const-expr lowering is itself fail-closed (Phase-2 MVP accepts
/// only a single `t.const`; cite valid/instructions constant expressions).
pub fn nonconst_init_fail_closed_test() {
  let m =
    ast.Module(
      imported_func_count: 0,
      rec_groups: [],
      types: list.map([], ast.func_def),
      imports: [],
      tables: [],
      memories: [],
      globals: [
        ast.Global(ty: ast.I32, mutable: False, init: [
          ast.I32Const(1),
          ast.I32Const(2),
          ast.I32Add,
        ]),
      ],
      tags: [],
      funcs: [],
      start: option.None,
      elements: [],
      data: [],
      data_count: option.None,
      exports: [],
    )
  let tm =
    validate.TypedModule(
      module: m,
      imported_func_count: 0,
      imported_global_count: 0,
      imported_table_count: 0,
      imported_memory_count: 0,
      func_types: [],
      func_locals: [],
      global_types: [ast.I32],
      table_types: [],
      memory_idx_types: [],
      elem_types: [],
      refs: set.new(),
      imported_tag_count: 0,
      tag_types: [],
    )
  case lower.lower(tm) {
    Error(lower.NonConstInitExpr(_)) -> True
    _ -> False
  }
  |> should.equal(True)
}

// ───────────────────────────── fail-closed totality ─────────────────────────────

/// The whole frontend (decode → validate → lower) is TOTAL over hostile input: every
/// stage yields `Ok`/`Error`, never a panic (overview D4 fail-closed). Single-byte
/// mutations of a real fixture exercise malformed bytes, ill-typed modules, and
/// out-of-scope constructs alike — none may crash.
pub fn frontend_totality_test() {
  let base = ba_to_list(sum_to_wasm)
  let len = list.length(base)
  let positions = int_range(0, len - 1)
  // A spread of bytes: zero, a valtype/blocktype byte, all-ones, empty blocktype,
  // `end`, and an opcode — covering structural, typing and unknown-opcode faults.
  let values = [0x00, 0x7f, 0xff, 0x40, 0x0b, 0x6a]
  list.all(positions, fn(pos) {
    list.all(values, fn(v) { chain_total(list_to_ba(replace(base, pos, v))) })
  })
  |> should.equal(True)
}

/// Run decode → validate → lower, confirming each stage returns a `Result` (forces
/// evaluation). `True` always; a crash would fail the test by panicking.
fn chain_total(bytes: BitArray) -> Bool {
  case decode.decode(bytes) {
    Error(_) -> True
    Ok(m) ->
      case validate.validate(m) {
        Error(_) -> True
        Ok(t) ->
          case lower.lower(t) {
            Ok(_) -> True
            Error(_) -> True
          }
      }
  }
}

// ───────────────────────────── END-TO-END on the BEAM ─────────────────────────────

/// `add(2,3) == 5`; and i32 addition wraps two's-complement through the whole chain
/// (`0x7FFFFFFF + 1 == 0x80000000 == 2147483648` unsigned) — WASM `i32.add` is mod 2^32.
pub fn add_e2e_test() {
  let mod = load(build(add_wasm))
  catch_apply(mod, atom.create("add"), [2, 3]) |> should.equal(Ok(5))
  catch_apply(mod, atom.create("add"), [2_147_483_647, 1])
  |> should.equal(Ok(2_147_483_648))
}

/// `sum_to(n) == n*(n+1)/2` running through the lowered `Loop`: `sum_to(100) == 5050`,
/// `sum_to(10) == 55`, `sum_to(0) == 0`.
pub fn sum_to_e2e_test() {
  let mod = load(build(sum_to_wasm))
  catch_apply(mod, atom.create("sum_to"), [100]) |> should.equal(Ok(5050))
  catch_apply(mod, atom.create("sum_to"), [10]) |> should.equal(Ok(55))
  catch_apply(mod, atom.create("sum_to"), [0]) |> should.equal(Ok(0))
}

/// `fib(10) == 55` via the lowered `If` + recursive `CallDirect`; boundary `fib(0)==0`,
/// `fib(1)==1`.
pub fn fib_e2e_test() {
  let mod = load(build(fib_wasm))
  catch_apply(mod, atom.create("fib"), [10]) |> should.equal(Ok(55))
  catch_apply(mod, atom.create("fib"), [0]) |> should.equal(Ok(0))
  catch_apply(mod, atom.create("fib"), [1]) |> should.equal(Ok(1))
}

/// REGRESSION (spec: a structured branch may target an `if`). A `br 0` inside an `if`
/// arm exits the `if` itself — `f` is `(i32.add (if (result i32) (local.get 0)
///   (then (br 0 (i32.const 100)) …dead…) (else (i32.const 5))) (i32.const 1))`.
///
/// Per the WASM spec a label index counts the enclosing structured blocks, and an `if`
/// IS one of them; `br 0` from a then/else arm forwards out of the `if` carrying its
/// result. So `f(1) == 101` (then taken: the `br` yields 100, then `+1`) and `f(0) == 6`
/// (else: 5, then `+1`). The IR `If` carries no label, so the frontend hosts the `if`'s
/// label in a wrapping `ir.Block`; before that fix this module failed to emit with
/// `UnboundLabel`.
pub fn br_to_if_e2e_test() {
  let mod = load(build(br_to_if_wasm))
  catch_apply(mod, atom.create("f"), [1]) |> should.equal(Ok(101))
  catch_apply(mod, atom.create("f"), [0]) |> should.equal(Ok(6))
}

// ═════════════════════════ Phase 5 (P5-05): reference / table / bulk ═════════════════════════

// ── reference instructions (spec exec/instructions §reference-instructions) ──

/// `ref.null t` reduces to the null-reference VALUE `ConstNull(t)` (R1c — no separate
/// `Expr`), pushed like a numeric const; a function returning it yields `Values([ConstNull(
/// t)])` typed to the reftype. `ref.null func` ⇒ `ConstNull(FuncRef)`/`TFuncRef`;
/// `ref.null extern` ⇒ `ConstNull(ExternRef)`/`TExternRef` (spec: the null reference of the
/// given reftype).
pub fn ref_null_test() {
  let irm = build(ref_wasm)
  let rn = func(irm, "f1")
  rn.result |> should.equal([ir.TFuncRef])
  rn.body |> should.equal(ir.Values([ir.ConstNull(ir.FuncRef)]))
  let ren = func(irm, "f2")
  ren.result |> should.equal([ir.TExternRef])
  ren.body |> should.equal(ir.Values([ir.ConstNull(ir.ExternRef)]))
}

/// `ref.func $f` ⇒ a value-producing `RefFunc("f<abs_funcidx>")` of type `TFuncRef`; the
/// name equals the target function's IR name (`"f0"` here), so the reference resolves to a
/// real `Function` (spec: `ref.func x` pushes a funcref to function `x`).
pub fn ref_func_test() {
  let irm = build(ref_wasm)
  let rf = func(irm, "f3")
  rf.result |> should.equal([ir.TFuncRef])
  list.any(all_exprs(rf.body), fn(e) { e == ir.RefFunc("f0") })
  |> should.equal(True)
  // the target name resolves to a real defined function.
  list.any(irm.functions, fn(g) { g.name == "f0" }) |> should.equal(True)
}

/// `ref.is_null` ⇒ `RefIsNull(arg)` of type `TI32` (spec: pops a reference, pushes i32 `1`
/// iff it is null). The argument is the reference operand (here the externref param `p0`).
pub fn ref_is_null_test() {
  let irm = build(ref_wasm)
  let isn = func(irm, "f4")
  isn.result |> should.equal([ir.TI32])
  list.any(all_exprs(isn.body), fn(e) { e == ir.RefIsNull(ir.Var("p0")) })
  |> should.equal(True)
}

/// Tables carry their element reference type (H1): a `funcref` table and an `externref`
/// table lower to `TableDecl`s tagged `FuncRef`/`ExternRef` respectively (spec
/// binary/types reftype). A declarative element segment (only makes `ref.func` targets
/// valid) lowers to `ElemDeclarative` with no active table write.
pub fn ref_tables_test() {
  let irm = build(ref_wasm)
  irm.tables
  |> should.equal([
    ir.TableDecl("t0", ir.FuncRef, 2, option.None),
    ir.TableDecl("t1", ir.ExternRef, 1, option.None),
  ])
  irm.elements
  |> should.equal([
    ir.ElementSegment(ir.ElemDeclarative, ir.FuncRef, [ir.RefFunc("f0")]),
  ])
}

// ── table instructions (spec exec/instructions §table-instructions + 0xFC 12..17) ──

/// `table.get x` ⇒ `TableGet("t<x>", i)` typed to the table's element reftype (here
/// `funcref` → `TFuncRef`); `table.set x` ⇒ the zero-result effect `TableSet("t<x>", i, v)`
/// (index then value, spec stack `[i32 t] → []`).
pub fn table_get_set_test() {
  let irm = build(table_ops_wasm)
  let tget = func(irm, "f1")
  tget.result |> should.equal([ir.TFuncRef])
  list.any(all_exprs(tget.body), fn(e) { e == ir.TableGet("t0", ir.Var("p0")) })
  |> should.equal(True)
  let tset = func(irm, "f2")
  list.any(all_exprs(tset.body), fn(e) {
    e == ir.TableSet("t0", ir.Var("p0"), ir.Var("p1"))
  })
  |> should.equal(True)
}

/// `table.size x` ⇒ `TableSize("t<x>")` (i32); `table.grow x` ⇒ `TableGrow("t<x>", delta,
/// init)` where `delta` is the i32 count (top of stack) and `init` the reference filled into
/// new slots (deeper) — the spec stack is `[t i32] → [i32]`; `table.fill x` ⇒ `TableFill(
/// "t<x>", offset, value, count)` (spec `[i32 t i32] → []`).
pub fn table_size_grow_fill_test() {
  let irm = build(table_ops_wasm)
  list.any(all_exprs(func(irm, "f3").body), fn(e) { e == ir.TableSize("t0") })
  |> should.equal(True)
  // tgrow(param0: funcref, param1: i32): delta = p1 (i32), init = p0 (funcref).
  list.any(all_exprs(func(irm, "f4").body), fn(e) {
    e == ir.TableGrow("t0", ir.Var("p1"), ir.Var("p0"))
  })
  |> should.equal(True)
  list.any(all_exprs(func(irm, "f5").body), fn(e) {
    e == ir.TableFill("t0", ir.Var("p0"), ir.Var("p1"), ir.Var("p2"))
  })
  |> should.equal(True)
}

/// `table.init x y` ⇒ `TableInit("t<x>", <seg y>, dst, src, count)` — the IR takes the target
/// table FIRST then the element-segment index (R3, anti-swap): the AST wire order is
/// `TableInit(elem, table)`, so the passive elem `$pe` (elemidx 1) becomes `seg = 1` and the
/// target `$t` becomes `"t0"`. `table.copy x y` ⇒ `TableCopy("t<x>", "t<y>", …)`; `elem.drop
/// y` ⇒ the zero-result effect `ElemDrop(y)`.
pub fn table_init_copy_elemdrop_test() {
  let irm = build(table_ops_wasm)
  list.any(all_exprs(func(irm, "f6").body), fn(e) {
    e == ir.TableInit("t0", 1, ir.Var("p0"), ir.Var("p1"), ir.Var("p2"))
  })
  |> should.equal(True)
  list.any(all_exprs(func(irm, "f7").body), fn(e) {
    e == ir.TableCopy("t0", "t0", ir.Var("p0"), ir.Var("p1"), ir.Var("p2"))
  })
  |> should.equal(True)
  list.any(all_exprs(func(irm, "f8").body), fn(e) { e == ir.ElemDrop(1) })
  |> should.equal(True)
}

// ── bulk memory (spec exec/instructions §memory + 0xFC 8..11) ──

/// `memory.init x` ⇒ `MemInit(mem, <seg x>, dst, src, count)` (mem index FIRST then the
/// data-segment index, R3; here mem 0, passive data seg 0); `data.drop x` ⇒ `DataDrop(x)`;
/// `memory.copy` ⇒ `MemCopy(dst_mem, src_mem, dst, src, count)`; `memory.fill` ⇒ `MemFill(
/// mem, dest, value, count)`. All zero-result effects; the passive data segment lowers to
/// `DataPassive`.
pub fn bulk_memory_test() {
  let irm = build(bulk_wasm)
  list.any(all_exprs(func(irm, "f0").body), fn(e) {
    e == ir.MemInit(0, 0, ir.Var("p0"), ir.Var("p1"), ir.Var("p2"))
  })
  |> should.equal(True)
  list.any(all_exprs(func(irm, "f1").body), fn(e) { e == ir.DataDrop(0) })
  |> should.equal(True)
  list.any(all_exprs(func(irm, "f2").body), fn(e) {
    e == ir.MemCopy(0, 0, ir.Var("p0"), ir.Var("p1"), ir.Var("p2"))
  })
  |> should.equal(True)
  list.any(all_exprs(func(irm, "f3").body), fn(e) {
    e == ir.MemFill(0, ir.Var("p0"), ir.Var("p1"), ir.Var("p2"))
  })
  |> should.equal(True)
  irm.data_segments
  |> should.equal([
    ir.DataSegment(ir.DataPassive, bit_array.from_string("abcd")),
  ])
}

// ── multi-memory + memory64 (H3/I4) ──

/// Multi-memory (H3): a module with two memories lowers each memory-touching node with the
/// SPEC memory index. A store/copy/fill/load against memory `$b` (index 1) carries `mem: 1`;
/// the copy's source memory `$a` is index 0 (`MemCopy(1, 0, …)`). Two `MemoryDecl`s are
/// declared. (Cite the multi-memory proposal: every memory instruction carries a memidx.)
pub fn multimemory_test() {
  let irm = build(multimem_wasm)
  list.length(irm.memories) |> should.equal(2)
  let exprs = all_exprs(func(irm, "f0").body)
  // store into memory 1
  list.any(exprs, fn(e) {
    case e {
      ir.MemStore(1, _, _, _, _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
  // copy dst=mem1, src=mem0
  list.any(exprs, fn(e) {
    case e {
      ir.MemCopy(1, 0, _, _, _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
  // fill + load against memory 1
  list.any(exprs, fn(e) {
    case e {
      ir.MemFill(1, _, _, _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
  list.any(exprs, fn(e) {
    case e {
      ir.MemLoad(1, _, _, _, _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
}

/// memory64 (I4): a module declaring a 64-bit memory now LOWERS (Phase 6 deleted the
/// `Memory64Unsupported` rejection). The declared memory carries `Idx64`
/// (`MemoryDecl(1, None, Idx64)`), and an `i64.load` against it forwards the i64 address
/// operand unchanged — there is no width branch in the memory arm (spec: a 64-bit memory's
/// address operand is `i64`; the runtime does the 64-bit bounds arithmetic — P6-08).
pub fn memory64_lowers_test() {
  let irm = build(mem64_wasm)
  irm.memories |> should.equal([ir.MemoryDecl(1, option.None, ir.Idx64)])
  // the `i64.load (local.get 0)` forwards `p0` (the i64 address) with no truncation/mask.
  list.any(all_exprs(func(irm, "f0").body), fn(e) {
    case e {
      ir.MemLoad(0, ir.MemAccess(8, False), ir.Var("p0"), 0, ir.TI64) -> True
      _ -> False
    }
  })
  |> should.equal(True)
}

// ── typed select (spec exec/instructions §select) ──

/// Typed `select t` (0x1C) lowers to the SAME `If` value-merge as untyped `select` (no new
/// IR node), taking its result type from the immediate. `select (result funcref) v1 v2 c`
/// over two funcrefs ⇒ `If(c, [TFuncRef], Values([v1]), Values([v2]))` — then-arm `v1` (the
/// result when `c ≠ 0`, spec), else-arm `v2`. A numeric `select (result i32)` ⇒ `[TI32]`.
pub fn select_t_test() {
  let irm = build(select_t_wasm)
  list.any(all_exprs(func(irm, "f0").body), fn(e) {
    e
    == ir.If(
      ir.Var("p2"),
      [ir.TFuncRef],
      ir.Values([ir.Var("p0")]),
      ir.Values([ir.Var("p1")]),
    )
  })
  |> should.equal(True)
  list.any(all_exprs(func(irm, "f1").body), fn(e) {
    case e {
      ir.If(_, [ir.TI32], _, _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
}

// ── grown module shape: segment modes + ref-init ──

/// Element and data segments preserve every mode + reference-typed init (spec
/// syntax/modules): a declarative + a passive-with-expr-init + an active-into-funcref +
/// an active-into-externref element segment, and a passive + an active data segment. A
/// passive elem's items are ref-producing `Expr`s (`RefFunc` / `Values([ConstNull(_)])` for
/// `ref.null`); an active externref segment carries a null-reference item.
pub fn segments_modes_test() {
  let irm = build(segments_wasm)
  irm.elements
  |> should.equal([
    ir.ElementSegment(ir.ElemDeclarative, ir.FuncRef, [ir.RefFunc("f0")]),
    ir.ElementSegment(ir.ElemPassive, ir.FuncRef, [
      ir.RefFunc("f0"),
      ir.Values([ir.ConstNull(ir.FuncRef)]),
    ]),
    ir.ElementSegment(
      ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
      ir.FuncRef,
      [ir.RefFunc("f0")],
    ),
    ir.ElementSegment(
      ir.ElemActive("t1", ir.Values([ir.ConstI32(0)])),
      ir.ExternRef,
      [ir.Values([ir.ConstNull(ir.ExternRef)])],
    ),
  ])
  irm.data_segments
  |> should.equal([
    ir.DataSegment(ir.DataPassive, bit_array.from_string("xy")),
    ir.DataSegment(
      ir.DataActive(0, ir.Values([ir.ConstI32(0)])),
      bit_array.from_string("hi"),
    ),
  ])
}

// ── non-function imports & exports + index spaces (H4/§G.5) ──

/// Non-function imports become the provided-state variants `ImportGlobal`/`ImportTable`/
/// `ImportMemory`; exports of state become `ExportGlobal`/`ExportTable`/`ExportMemory` (spec
/// syntax/modules imports/exports). The index spaces are `imports ++ defined`: the imported
/// global/table occupy indices 0, so the DEFINED global/table are named `g1`/`t1`; the
/// imported global's `global.get` resolves to `g0` (the same absolute-index naming).
pub fn nonfunction_imports_exports_test() {
  let irm = build(imports_wasm)
  irm.imports
  |> should.equal([
    ir.ImportGlobal("spectest", "global_i32", ir.TI32, False),
    ir.ImportTable("spectest", "table", ir.FuncRef, 10, option.Some(20)),
    ir.ImportMemory("spectest", "memory", 1, option.Some(2), ir.Idx32),
  ])
  // defined global/table named at their ABSOLUTE index (after the imports).
  irm.globals
  |> should.equal([
    ir.GlobalDecl("g1", ir.TI32, True, ir.Values([ir.ConstI32(3)])),
  ])
  irm.tables
  |> should.equal([ir.TableDecl("t1", ir.FuncRef, 2, option.None)])
  // `global.get` of the imported global resolves to g0 (imported globalidx 0).
  list.any(all_exprs(func(irm, "f0").body), fn(e) { e == ir.GlobalGet("g0") })
  |> should.equal(True)
  // state exports of all three kinds, naming the exported item at its absolute index.
  list.contains(irm.exports, ir.ExportGlobal("g", "g1")) |> should.equal(True)
  list.contains(irm.exports, ir.ExportTable("t", "t1")) |> should.equal(True)
  list.contains(irm.exports, ir.ExportMemory("m", 1)) |> should.equal(True)
}

/// Reference-typed global inits (spec: a global's const-expr may be `ref.func`/`ref.null`):
/// a `funcref` global initialised to `ref.func $f` ⇒ `GlobalDecl("g0", TFuncRef, _,
/// RefFunc("f0"))`; a `mut externref` global initialised to `ref.null extern` ⇒
/// `GlobalDecl("g1", TExternRef, True, Values([ConstNull(ExternRef)]))` (R1c). `global.get`
/// of the funcref global lowers to `GlobalGet("g0")`.
pub fn ref_global_init_test() {
  let irm = build(globals_ref_wasm)
  irm.globals
  |> should.equal([
    ir.GlobalDecl("g0", ir.TFuncRef, False, ir.RefFunc("f0")),
    ir.GlobalDecl(
      "g1",
      ir.TExternRef,
      True,
      ir.Values([ir.ConstNull(ir.ExternRef)]),
    ),
  ])
  list.any(all_exprs(func(irm, "f1").body), fn(e) { e == ir.GlobalGet("g0") })
  |> should.equal(True)
}

/// Reference-typed DECLARED locals default to the null reference (spec exec/instructions
/// local initialization: a reference local defaults to `ref.null` of its type). A function
/// with a declared `funcref` local zero-inits it to `Values([ConstNull(FuncRef)])` at entry.
pub fn ref_local_zero_init_test() {
  let irm = build(ref_local_wasm)
  let f = func(irm, "f0")
  // The zero-init `Let` for the declared funcref local binds `ConstNull(FuncRef)`.
  list.any(all_exprs(f.body), fn(e) {
    case e {
      ir.Let([_], ir.Values([ir.ConstNull(ir.FuncRef)]), _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
}

// ═════════════════════════ Phase 6 (P6-05): SIMD / memory64 / imports ═════════════════════════
//
// SIMD text is out of scope for the WAT parser (S13) and hand-baking `0xFD` bytes is
// error-prone, so these focused lower tests build the `ast.Module` directly and run it through
// the REAL validate → lower chain — asserting the exact IR4 node the spec/keystone demand.

/// A single defined-function module (funcidx 0 → `"f0"`): one function of the given signature +
/// declared locals + body, plus the given memories. No imports, tables, globals, or segments.
fn one_func_module(
  params: List(ast.ValType),
  results: List(ast.ValType),
  locals: List(ast.ValType),
  body: List(ast.Instr),
  memories: List(ast.MemType),
) -> ast.Module {
  ast.Module(
    imported_func_count: 0,
    rec_groups: [],
    types: list.map([ast.FuncType(params, results)], ast.func_def),
    imports: [],
    tables: [],
    memories: memories,
    globals: [],
    tags: [],
    funcs: [ast.Func(0, locals, body)],
    start: option.None,
    elements: [],
    data: [],
    data_count: option.None,
    exports: [ast.Export("f", ast.ExportFunc, 0)],
  )
}

/// Validate then lower an AST module (both must succeed — these are valid fixtures).
fn lower_ast(m: ast.Module) -> ir.Module {
  let assert Ok(typed) = validate.validate(m)
  let assert Ok(irm) = lower.lower(typed)
  irm
}

/// `True` if any expression in `f0`'s body satisfies `pred`.
fn f0_has(irm: ir.Module, pred: fn(ir.Expr) -> Bool) -> Bool {
  list.any(all_exprs(func(irm, "f0").body), pred)
}

/// A 32-bit memory of one page (for the SIMD-memory fixtures).
fn mem32() -> List(ast.MemType) {
  [ast.MemType(ast.Limits(1, option.None), ast.Idx32)]
}

/// Lower a single pure lane op `op` over `arity` locals of types `param_types`, returning the
/// produced `ir.Simd` node. The op's single result is `drop`ped so the declared function result
/// is `[]` regardless of the op's result type (so one helper serves every op).
fn simd_of(param_types: List(ast.ValType), op: ast.SimdOp) -> ir.Expr {
  let n = list.length(param_types)
  let getters = list.map(int_range(0, n - 1), ast.LocalGet)
  let body = list.append(getters, [ast.Simd(op), ast.Drop, ast.End])
  let irm = lower_ast(one_func_module(param_types, [], [], body, []))
  let nodes =
    list.filter(all_exprs(func(irm, "f0").body), fn(e) {
      case e {
        ir.Simd(_, _) -> True
        _ -> False
      }
    })
  let assert [node] = nodes
  node
}

/// Observe lower's COMPUTED result type for a pure lane op (not validate's): produce the op's
/// result twice, `select` between the two copies, and read the resulting `If`'s result-type
/// list. `select` types itself from the SSA-recorded type of its first operand (`value_type`),
/// so the `If`'s result type is exactly what lower recorded for the op. `spec_result` is the
/// op's spec result type (the declared function result — validate rejects a wrong one).
fn simd_result_type(
  param_types: List(ast.ValType),
  op: ast.SimdOp,
  spec_result: ast.ValType,
) -> List(ir.ValType) {
  let n = list.length(param_types)
  let getters = list.map(int_range(0, n - 1), ast.LocalGet)
  let body =
    list.append(getters, [ast.Simd(op)])
    |> list.append(getters)
    |> list.append([ast.Simd(op), ast.I32Const(0), ast.Select, ast.End])
  let irm = lower_ast(one_func_module(param_types, [spec_result], [], body, []))
  let assert Ok(rt) =
    list.find_map(all_exprs(func(irm, "f0").body), fn(e) {
      case e {
        ir.If(_, rt, _, _) -> Ok(rt)
        _ -> Error(Nil)
      }
    })
  rt
}

// ── B. v128 value & const (spec exec/instructions §vector const) ──

/// `v128.const` lowers to a pushed `ConstV128(bytes)` VALUE literal (like a numeric const — no
/// `Let`, no `Expr`), holding the 16 raw little-endian bytes UNCHANGED (D5: a `-0.0` lane and a
/// NaN-payload lane survive bit-for-bit — no lane decoding). The function's result type is
/// `TV128`.
pub fn v128_const_lowers_test() {
  // lane 0 = -0.0f (0x80000000 LE); lane 1 = a NaN-ish 0x7FFFFFFF; lanes 2/3 = 0.
  let bytes = <<0, 0, 0, 128, 255, 255, 255, 127, 0, 0, 0, 0, 0, 0, 0, 0>>
  let irm =
    lower_ast(
      one_func_module([], [ast.V128], [], [ast.V128Const(bytes), ast.End], []),
    )
  let f = func(irm, "f0")
  f.result |> should.equal([ir.TV128])
  f.body |> should.equal(ir.Values([ir.ConstV128(bytes)]))
}

/// A declared `v128` local zero-initialises to the all-zero 16-byte vector `ConstV128(<<0:128>>)`
/// (spec local initialisation — a numeric zero).
pub fn v128_local_zero_init_test() {
  let irm =
    lower_ast(
      one_func_module(
        [],
        [ast.V128],
        [ast.V128],
        [ast.LocalGet(0), ast.End],
        [],
      ),
    )
  f0_has(irm, fn(e) {
    case e {
      ir.Let([_], ir.Values([ir.ConstV128(bytes)]), _) ->
        bytes == <<0:size(128)>>
      _ -> False
    }
  })
  |> should.equal(True)
}

/// A `v128` global initialised by `v128.const` lowers to `GlobalDecl("g0", TV128, _,
/// Values([ConstV128(bytes)]))` (spec: `v128.const` is a constant instruction).
pub fn v128_global_init_test() {
  let bytes = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>
  let m =
    ast.Module(
      imported_func_count: 0,
      rec_groups: [],
      types: list.map([ast.FuncType([], [ast.V128])], ast.func_def),
      imports: [],
      tables: [],
      memories: [],
      globals: [ast.Global(ast.V128, False, [ast.V128Const(bytes)])],
      tags: [],
      funcs: [ast.Func(0, [], [ast.GlobalGet(0), ast.End])],
      start: option.None,
      elements: [],
      data: [],
      data_count: option.None,
      exports: [],
    )
  lower_ast(m).globals
  |> should.equal([
    ir.GlobalDecl("g0", ir.TV128, False, ir.Values([ir.ConstV128(bytes)])),
  ])
}

// ── C. integer-lane ops → Simd(op, args) (spec exec/instructions §vector) ──

/// A representative integer op from each family relabels to the exact neutral `Simd(op, args)`
/// with the right shape, arity, and PUSH-order operands (`[a, b]` deepest-first): add/sub/mul,
/// neg/abs/popcnt, the saturating add/sub family, min/max, avgr, shifts (`[v, count]`),
/// comparisons (→ a v128 mask), the whole v128 bitwise + reduction set, and dot/q15.
pub fn simd_integer_ops_test() {
  let vv = [ast.V128, ast.V128]
  simd_of(vv, ast.SAdd(ast.I32x4))
  |> should.equal(ir.Simd(ir.SAdd(ir.I32x4), [ir.Var("p0"), ir.Var("p1")]))
  simd_of(vv, ast.SMul(ast.I16x8))
  |> should.equal(ir.Simd(ir.SMul(ir.I16x8), [ir.Var("p0"), ir.Var("p1")]))
  simd_of([ast.V128], ast.SNeg(ast.I64x2))
  |> should.equal(ir.Simd(ir.SNeg(ir.I64x2), [ir.Var("p0")]))
  simd_of([ast.V128], ast.SPopcnt(ast.I8x16))
  |> should.equal(ir.Simd(ir.SPopcnt(ir.I8x16), [ir.Var("p0")]))
  // saturating add/sub family (S3 — the eight `i8x16`/`i16x8` ops)
  simd_of(vv, ast.SAddSatS(ast.I8x16))
  |> should.equal(ir.Simd(ir.SAddSatS(ir.I8x16), [ir.Var("p0"), ir.Var("p1")]))
  simd_of(vv, ast.SSubSatU(ast.I16x8))
  |> should.equal(ir.Simd(ir.SSubSatU(ir.I16x8), [ir.Var("p0"), ir.Var("p1")]))
  simd_of(vv, ast.SMinS(ast.I32x4))
  |> should.equal(ir.Simd(ir.SMinS(ir.I32x4), [ir.Var("p0"), ir.Var("p1")]))
  simd_of(vv, ast.SAvgrU(ast.I8x16))
  |> should.equal(ir.Simd(ir.SAvgrU(ir.I8x16), [ir.Var("p0"), ir.Var("p1")]))
  // shift: `[v128 i32] → [v128]`, operands `[v, count]`
  simd_of([ast.V128, ast.I32], ast.SShl(ast.I16x8))
  |> should.equal(ir.Simd(ir.SShl(ir.I16x8), [ir.Var("p0"), ir.Var("p1")]))
  // comparison → the operands unchanged (the mask-ness is the RESULT type — asserted below)
  simd_of(vv, ast.SLtU(ast.I32x4))
  |> should.equal(ir.Simd(ir.SLtU(ir.I32x4), [ir.Var("p0"), ir.Var("p1")]))
  // v128 bitwise + reductions
  simd_of([ast.V128], ast.VNot)
  |> should.equal(ir.Simd(ir.VNot, [ir.Var("p0")]))
  simd_of([ast.V128, ast.V128, ast.V128], ast.VBitselect)
  |> should.equal(
    ir.Simd(ir.VBitselect, [ir.Var("p0"), ir.Var("p1"), ir.Var("p2")]),
  )
  simd_of([ast.V128], ast.VAnyTrue)
  |> should.equal(ir.Simd(ir.VAnyTrue, [ir.Var("p0")]))
  simd_of([ast.V128], ast.SAllTrue(ast.I8x16))
  |> should.equal(ir.Simd(ir.SAllTrue(ir.I8x16), [ir.Var("p0")]))
  simd_of([ast.V128], ast.SBitmask(ast.I32x4))
  |> should.equal(ir.Simd(ir.SBitmask(ir.I32x4), [ir.Var("p0")]))
  // dot / q15
  simd_of(vv, ast.SDotI16x8S)
  |> should.equal(ir.Simd(ir.SDotI16x8S, [ir.Var("p0"), ir.Var("p1")]))
  simd_of(vv, ast.SQ15MulrSatS)
  |> should.equal(ir.Simd(ir.SQ15MulrSatS, [ir.Var("p0"), ir.Var("p1")]))
}

/// Comparison ops yield a v128 MASK, not i32 (the classic pitfall); reductions yield i32. Both
/// are observed via lower's recorded result type (§simd_result_type).
pub fn simd_result_types_test() {
  // `i32x4.lt_u` → a v128 mask (NOT i32)
  simd_result_type([ast.V128, ast.V128], ast.SLtU(ast.I32x4), ast.V128)
  |> should.equal([ir.TV128])
  // `f32x4.eq` → a v128 mask
  simd_result_type([ast.V128, ast.V128], ast.FEq(ast.F32x4), ast.V128)
  |> should.equal([ir.TV128])
  // `i8x16.all_true` / `v128.any_true` / `i16x8.bitmask` → i32
  simd_result_type([ast.V128], ast.SAllTrue(ast.I8x16), ast.I32)
  |> should.equal([ir.TI32])
  simd_result_type([ast.V128], ast.VAnyTrue, ast.I32)
  |> should.equal([ir.TI32])
  simd_result_type([ast.V128], ast.SBitmask(ast.I16x8), ast.I32)
  |> should.equal([ir.TI32])
  // `i64x2.extract_lane` → i64; `f64x2.extract_lane` → f64 (the lane's scalar type)
  simd_result_type([ast.V128], ast.SExtractLane(ast.I64x2, 0), ast.I64)
  |> should.equal([ir.TI64])
  simd_result_type([ast.V128], ast.SExtractLane(ast.F64x2, 0), ast.F64)
  |> should.equal([ir.TF64])
}

// ── D. float-lane ops → Simd(SF*, args) (F-prefixed AST → SF-prefixed IR, S3) ──

/// The float lane ops relabel `F*` (AST) → `SF*` (IR) — the S3 spelling delta — keeping shape,
/// arity, and operand order; `pmin`/`pmax` stay DISTINCT from `min`/`max`.
pub fn simd_float_ops_test() {
  let vv = [ast.V128, ast.V128]
  simd_of(vv, ast.FAdd(ast.F32x4))
  |> should.equal(ir.Simd(ir.SFAdd(ir.F32x4), [ir.Var("p0"), ir.Var("p1")]))
  simd_of(vv, ast.FDiv(ast.F64x2))
  |> should.equal(ir.Simd(ir.SFDiv(ir.F64x2), [ir.Var("p0"), ir.Var("p1")]))
  simd_of(vv, ast.FPMin(ast.F32x4))
  |> should.equal(ir.Simd(ir.SFPMin(ir.F32x4), [ir.Var("p0"), ir.Var("p1")]))
  simd_of(vv, ast.FMax(ast.F64x2))
  |> should.equal(ir.Simd(ir.SFMax(ir.F64x2), [ir.Var("p0"), ir.Var("p1")]))
  simd_of([ast.V128], ast.FSqrt(ast.F32x4))
  |> should.equal(ir.Simd(ir.SFSqrt(ir.F32x4), [ir.Var("p0")]))
  simd_of(vv, ast.FEq(ast.F32x4))
  |> should.equal(ir.Simd(ir.SFEq(ir.F32x4), [ir.Var("p0"), ir.Var("p1")]))
}

// ── E. lane access, splat, shuffle, swizzle ──

/// `extract_lane`/`replace_lane` carry the static lane immediate inside the `SimdOp`; `splat`
/// builds a v128 from a scalar; `i8x16.shuffle` is the dedicated `SimdShuffle(lanes, a, b)` node
/// (16 indices verbatim); `i8x16.swizzle` rides the op table (`SSwizzle`, operands `[a, idx]`).
pub fn simd_lane_and_shuffle_test() {
  // extract (lane immediate threaded); replace_lane operands `[vec, x]`
  simd_of([ast.V128], ast.SExtractLaneS(ast.I8x16, 3))
  |> should.equal(ir.Simd(ir.SExtractLaneS(ir.I8x16, 3), [ir.Var("p0")]))
  simd_of([ast.V128], ast.SExtractLane(ast.I32x4, 2))
  |> should.equal(ir.Simd(ir.SExtractLane(ir.I32x4, 2), [ir.Var("p0")]))
  simd_of([ast.V128, ast.I32], ast.SReplaceLane(ast.I32x4, 2))
  |> should.equal(
    ir.Simd(ir.SReplaceLane(ir.I32x4, 2), [ir.Var("p0"), ir.Var("p1")]),
  )
  // splat from the lane scalar (i32 for i8x16/i16x8/i32x4, i64/f32/f64 for the others)
  simd_of([ast.I32], ast.SSplat(ast.I8x16))
  |> should.equal(ir.Simd(ir.SSplat(ir.I8x16), [ir.Var("p0")]))
  simd_of([ast.F64], ast.SSplat(ast.F64x2))
  |> should.equal(ir.Simd(ir.SSplat(ir.F64x2), [ir.Var("p0")]))
  // swizzle (dynamic; operands `[a, idx]`)
  simd_of([ast.V128, ast.V128], ast.SSwizzle)
  |> should.equal(ir.Simd(ir.SSwizzle, [ir.Var("p0"), ir.Var("p1")]))
  // shuffle — the dedicated node with its 16 indices verbatim + operands `[a, b]`
  let lanes = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  let irm =
    lower_ast(
      one_func_module(
        [ast.V128, ast.V128],
        [],
        [],
        [
          ast.LocalGet(0),
          ast.LocalGet(1),
          ast.I8x16Shuffle(lanes),
          ast.Drop,
          ast.End,
        ],
        [],
      ),
    )
  f0_has(irm, fn(e) { e == ir.SimdShuffle(lanes, ir.Var("p0"), ir.Var("p1")) })
  |> should.equal(True)
}

// ── C.5 / D.4 shape-changing families (parametric relabel copies from/half/signed — S3) ──

/// The parametric widen/narrow/extmul/pairwise families copy their `from` (source shape),
/// `half`, and `signed` fields (at least one low + one high + one signed + one unsigned); the
/// named conversions copy 1:1. (spec exec/instructions §vector narrow/extend/convert.)
pub fn simd_shape_changing_ops_test() {
  let vv = [ast.V128, ast.V128]
  // narrow (saturating): signed + unsigned
  simd_of(vv, ast.SNarrow(ast.I16x8, True))
  |> should.equal(
    ir.Simd(ir.SNarrow(ir.I16x8, True), [ir.Var("p0"), ir.Var("p1")]),
  )
  simd_of(vv, ast.SNarrow(ast.I32x4, False))
  |> should.equal(
    ir.Simd(ir.SNarrow(ir.I32x4, False), [ir.Var("p0"), ir.Var("p1")]),
  )
  // extend: low+signed and high+unsigned
  simd_of([ast.V128], ast.SExtend(ast.I8x16, ast.Low, True))
  |> should.equal(ir.Simd(ir.SExtend(ir.I8x16, ir.Low, True), [ir.Var("p0")]))
  simd_of([ast.V128], ast.SExtend(ast.I16x8, ast.High, False))
  |> should.equal(ir.Simd(ir.SExtend(ir.I16x8, ir.High, False), [ir.Var("p0")]))
  // extmul: high+unsigned and low+signed
  simd_of(vv, ast.SExtMul(ast.I8x16, ast.High, False))
  |> should.equal(
    ir.Simd(ir.SExtMul(ir.I8x16, ir.High, False), [ir.Var("p0"), ir.Var("p1")]),
  )
  simd_of(vv, ast.SExtMul(ast.I32x4, ast.Low, True))
  |> should.equal(
    ir.Simd(ir.SExtMul(ir.I32x4, ir.Low, True), [ir.Var("p0"), ir.Var("p1")]),
  )
  // extadd_pairwise
  simd_of([ast.V128], ast.SExtAddPairwise(ast.I16x8, True))
  |> should.equal(ir.Simd(ir.SExtAddPairwise(ir.I16x8, True), [ir.Var("p0")]))
  // named conversions (copied 1:1)
  simd_of([ast.V128], ast.STruncSatF32x4S)
  |> should.equal(ir.Simd(ir.STruncSatF32x4S, [ir.Var("p0")]))
  simd_of([ast.V128], ast.SConvertF32x4I32x4U)
  |> should.equal(ir.Simd(ir.SConvertF32x4I32x4U, [ir.Var("p0")]))
  simd_of([ast.V128], ast.SDemoteF64x2Zero)
  |> should.equal(ir.Simd(ir.SDemoteF64x2Zero, [ir.Var("p0")]))
  simd_of([ast.V128], ast.SPromoteLowF32x4)
  |> should.equal(ir.Simd(ir.SPromoteLowF32x4, [ir.Var("p0")]))
}

// ── F. SIMD memory (spec exec/instructions §vector memory) ──

/// The plain/splat/extend/zero loads lower to `SimdLoad(mem, kind, addr, offset)` with the kind
/// discriminant, the memidx, the static offset, and the address operand forwarded. Bit widths
/// on `LoadSplat`/`LoadExtend`/`LoadZero` are BITS (S2), copied verbatim.
pub fn simd_load_test() {
  let load = fn(kind: ast.SimdLoadKind, offset: Int) {
    lower_ast(one_func_module(
      [ast.I32],
      [],
      [],
      [
        ast.LocalGet(0),
        ast.SimdLoad(kind, ast.MemArg(0, offset, 0)),
        ast.Drop,
        ast.End,
      ],
      mem32(),
    ))
  }
  f0_has(load(ast.LoadV128, 0), fn(e) {
    e == ir.SimdLoad(0, ir.LoadV128, ir.Var("p0"), 0)
  })
  |> should.equal(True)
  // splat: lane_bits in BITS; a non-zero static offset threaded
  f0_has(load(ast.LoadSplat(32), 16), fn(e) {
    e == ir.SimdLoad(0, ir.LoadSplat(32), ir.Var("p0"), 16)
  })
  |> should.equal(True)
  // extending load (8-bit source lanes, unsigned)
  f0_has(load(ast.LoadExtend(8, False), 0), fn(e) {
    e == ir.SimdLoad(0, ir.LoadExtend(8, False), ir.Var("p0"), 0)
  })
  |> should.equal(True)
  // load64_zero → LoadZero(64)
  f0_has(load(ast.LoadZero(64), 0), fn(e) {
    e == ir.SimdLoad(0, ir.LoadZero(64), ir.Var("p0"), 0)
  })
  |> should.equal(True)
}

/// `v128.store` lowers to `SimdStore(mem, addr, value, offset)` — a ZERO-result effect
/// (`Let([], SimdStore(..), ..)`, never dropped), operands `[addr, value]` (address deeper).
pub fn simd_store_test() {
  let irm =
    lower_ast(one_func_module(
      [ast.I32, ast.V128],
      [],
      [],
      [
        ast.LocalGet(0),
        ast.LocalGet(1),
        ast.SimdStore(ast.MemArg(0, 8, 0)),
        ast.End,
      ],
      mem32(),
    ))
  f0_has(irm, fn(e) {
    case e {
      ir.Let([], store, _) ->
        store == ir.SimdStore(0, ir.Var("p0"), ir.Var("p1"), 8)
      _ -> False
    }
  })
  |> should.equal(True)
}

/// `v128.loadN_lane`/`storeN_lane` thread the memidx, static offset, BITS width (S2), lane
/// immediate, and the input vector. The load yields a v128; the store is a zero-result effect.
/// Operands are `[addr, vec]` (address deeper).
pub fn simd_lane_memory_test() {
  // load32_lane 2 → SimdLoadLane(mem, 32 BITS, addr, offset, 2, vec)
  let load_irm =
    lower_ast(one_func_module(
      [ast.I32, ast.V128],
      [],
      [],
      [
        ast.LocalGet(0),
        ast.LocalGet(1),
        ast.SimdLoadLane(32, ast.MemArg(0, 0, 0), 2),
        ast.Drop,
        ast.End,
      ],
      mem32(),
    ))
  f0_has(load_irm, fn(e) {
    e == ir.SimdLoadLane(0, 32, ir.Var("p0"), 0, 2, ir.Var("p1"))
  })
  |> should.equal(True)
  // store64_lane 1 → SimdStoreLane(mem, 64 BITS, addr, offset, 1, vec), a zero-result effect
  let store_irm =
    lower_ast(one_func_module(
      [ast.I32, ast.V128],
      [],
      [],
      [
        ast.LocalGet(0),
        ast.LocalGet(1),
        ast.SimdStoreLane(64, ast.MemArg(0, 0, 0), 1),
        ast.End,
      ],
      mem32(),
    ))
  f0_has(store_irm, fn(e) {
    case e {
      ir.Let([], store, _) ->
        store == ir.SimdStoreLane(0, 64, ir.Var("p0"), 0, 1, ir.Var("p1"))
      _ -> False
    }
  })
  |> should.equal(True)
}

/// A SIMD load against a non-zero memidx (multi-memory) carries `mem: 1` (byte-identical memidx
/// threading, exactly like scalar loads).
pub fn simd_multimemory_test() {
  let irm =
    lower_ast(
      one_func_module(
        [ast.I32],
        [],
        [],
        [
          ast.LocalGet(0),
          ast.SimdLoad(ast.LoadV128, ast.MemArg(0, 0, 1)),
          ast.Drop,
          ast.End,
        ],
        [
          ast.MemType(ast.Limits(1, option.None), ast.Idx32),
          ast.MemType(ast.Limits(1, option.None), ast.Idx32),
        ],
      ),
    )
  f0_has(irm, fn(e) { e == ir.SimdLoad(1, ir.LoadV128, ir.Var("p0"), 0) })
  |> should.equal(True)
}

// ── G. memory64 (imported) — the width axis flows onto ImportMemory ──

/// An IMPORTED 64-bit memory lowers to `ImportMemory(module, name, min, max, Idx64)` — the
/// address-width axis rides onto the import decl (no rejection; I4).
pub fn memory64_imported_test() {
  let m =
    ast.Module(
      imported_func_count: 0,
      rec_groups: [],
      types: list.map([ast.FuncType([], [])], ast.func_def),
      imports: [
        ast.Import(
          "env",
          "mem",
          ast.ImportMemory(ast.MemType(ast.Limits(1, option.Some(3)), ast.Idx64)),
        ),
      ],
      tables: [],
      memories: [],
      globals: [],
      tags: [],
      funcs: [ast.Func(0, [], [ast.End])],
      start: option.None,
      elements: [],
      data: [],
      data_count: option.None,
      exports: [],
    )
  lower_ast(m).imports
  |> should.equal([
    ir.ImportMemory("env", "mem", 1, option.Some(3), ir.Idx64),
  ])
}

// ── H. cross-module / imported-function calls → CallImport (S5) ──

/// A `call` of an imported function lowers to `CallImport(slot, ty, args)` — `slot` the
/// positional function-import index (= the funcidx), `ty` the import's IR signature, args in
/// push order. A void import is sequenced as a zero-result effect (`Let([], CallImport(..), ..)`).
/// A same-module call stays `CallDirect("f<idx>", args)`.
pub fn imported_call_test() {
  let m =
    ast.Module(
      imported_func_count: 2,
      rec_groups: [],
      types: list.map(
        [ast.FuncType([ast.I32], [ast.I32]), ast.FuncType([ast.I32], [])],
        ast.func_def,
      ),
      imports: [
        ast.Import("host", "inc", ast.ImportFunc(0)),
        ast.Import("host", "log", ast.ImportFunc(1)),
      ],
      tables: [],
      memories: [],
      globals: [],
      tags: [],
      funcs: [
        // funcidx 2 — a same-module function ("f2")
        ast.Func(0, [], [ast.I32Const(5), ast.End]),
        // funcidx 3 ("f3") — calls import 0 (result), import 1 (void), then defined func 2
        ast.Func(0, [], [
          ast.LocalGet(0),
          ast.Call(0),
          ast.Drop,
          ast.LocalGet(0),
          ast.Call(1),
          ast.LocalGet(0),
          ast.Call(2),
          ast.End,
        ]),
      ],
      start: option.None,
      elements: [],
      data: [],
      data_count: option.None,
      exports: [ast.Export("test", ast.ExportFunc, 3)],
    )
  let irm = lower_ast(m)
  let caller = func(irm, "f3")
  let has = fn(pred) { list.any(all_exprs(caller.body), pred) }
  // import 0 (has a result) → CallImport(slot=0, ty=[i32]->[i32], [p0])
  has(fn(e) {
    e == ir.CallImport(0, ir.FuncType([ir.TI32], [ir.TI32]), [ir.Var("p0")])
  })
  |> should.equal(True)
  // import 1 (void) → CallImport(slot=1, ty=[i32]->[], [p0]) sequenced as a zero-result effect
  has(fn(e) {
    case e {
      ir.Let([], call, _) ->
        call == ir.CallImport(1, ir.FuncType([ir.TI32], []), [ir.Var("p0")])
      _ -> False
    }
  })
  |> should.equal(True)
  // same-module call → CallDirect (unchanged)
  has(fn(e) { e == ir.CallDirect("f2", [ir.Var("p0")]) })
  |> should.equal(True)
}

// ─────────────── lever 5: liveness narrowing of the carried-local set ───────────────
//
// Objective (spec) property: the frontend threads a block/loop/if's mutated locals out as extra
// results / loop params. WASM semantics say a local NOT read on any path after the exit (before its
// next write) is dead there — its outgoing value is unobservable. Under `narrow_carried`, such a
// local must NOT be carried; a local read after the exit MUST be. And an end-to-end run under
// narrowing must return the SPEC-CORRECT result (the analysis only removes provably-dead locals).

/// Parse WAT → validate → frontend-lower, with liveness narrowing on/off. Each stage must succeed
/// (these are valid fixtures); a failure is a genuine test failure.
fn lower_wat(source: String, narrow: Bool) -> ir.Module {
  let assert Ok(m) = wat.parse_module(source)
  let assert Ok(tm) = validate.validate(m)
  let assert Ok(irm) = lower.lower_with(tm, narrow)
  irm
}

/// The single defined function of a one-function fixture (the frontend names it by funcidx, e.g.
/// `"f0"`, not by its export name).
fn single_func(irm: ir.Module) -> ir.Function {
  let assert [f] = irm.functions
  f
}

/// Every `ir.Loop`'s param list in `f`'s body (structural inspection of loop-carried vars).
fn loop_params(f: ir.Function) -> List(List(ir.LoopParam)) {
  list.filter_map(all_exprs(f.body), fn(e) {
    case e {
      ir.Loop(_, params, _, _) -> Ok(params)
      _ -> Error(Nil)
    }
  })
}

/// Every `ir.Block`'s result-type list in `f`'s body. A block has no stack results in these fixtures
/// (empty blocktype), so its result list length == its carried-local count.
fn block_results(f: ir.Function) -> List(List(ir.ValType)) {
  list.filter_map(all_exprs(f.body), fn(e) {
    case e {
      ir.Block(_, result, _) -> Ok(result)
      _ -> Error(Nil)
    }
  })
}

// `(func (export "f") (param i32) (result i32) (local $dead i32) (local $live i32)
//    (block (local.set $dead (i32.const 7)) (local.set $live (i32.const 9)))
//    (local.get $live))`
// $dead and $live are BOTH set inside the block; only $live is read after it. So the block's
// carried locals are {$dead, $live} without narrowing, {$live} with narrowing.
const narrow_join_wat: String = "
  (module
    (func (export \"f\") (param i32) (result i32)
      (local $dead i32) (local $live i32)
      (block
        (local.set $dead (i32.const 7))
        (local.set $live (i32.const 9)))
      (local.get $live)))"

/// Objective: a local set inside a `block` but DEAD after it (never read before its next write) is
/// NOT threaded out under narrowing, while one read after the block IS. The block yields no stack
/// value, so its `ir.Block` result-list length equals its carried-local count: 2 without narrowing
/// (both `$dead` and `$live`), exactly 1 with it (only `$live`).
pub fn narrow_drops_dead_join_local_test() {
  let f_wide = single_func(lower_wat(narrow_join_wat, False))
  let f_narrow = single_func(lower_wat(narrow_join_wat, True))
  // Default (no narrowing): the block carries BOTH mutated locals — the over-approximation.
  let assert [wide] = block_results(f_wide)
  list.length(wide) |> should.equal(2)
  // Narrowed: only the local live at the exit (`$live`) survives; `$dead` is dropped.
  let assert [narrow] = block_results(f_narrow)
  list.length(narrow) |> should.equal(1)
}

// `(func (export "sumloop") (param $n i32) (result i32)
//    (local $i i32) (local $acc i32) (local $tmp i32)
//    (block $break (loop $cont
//      (br_if $break (i32.ge_s (local.get $i) (local.get $n)))
//      (local.set $tmp (i32.mul (local.get $i) (i32.const 2)))
//      (local.set $acc (i32.add (local.get $acc) (local.get $tmp)))
//      (local.set $i (i32.add (local.get $i) (i32.const 1)))
//      (br $cont)))
//    (local.get $acc)))`
// $tmp is written then read WITHIN one iteration — dead at the back-edge (rewritten before read
// each pass) and never read after the loop; $i and $acc are read on the next iteration / after.
const narrow_loop_wat: String = "
  (module
    (func (export \"sumloop\") (param $n i32) (result i32)
      (local $i i32) (local $acc i32) (local $tmp i32)
      (block $break
        (loop $cont
          (br_if $break (i32.ge_s (local.get $i) (local.get $n)))
          (local.set $tmp (i32.mul (local.get $i) (i32.const 2)))
          (local.set $acc (i32.add (local.get $acc) (local.get $tmp)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $cont)))
      (local.get $acc)))"

/// Objective: a loop temp written-then-read within a single iteration (`$tmp`) is dead at BOTH the
/// back-edge and the exit, so narrowing drops it from the loop parameters — while `$i`/`$acc`, live
/// across iterations / after the loop, are kept. Without narrowing all three locals are loop params.
pub fn narrow_drops_dead_loop_local_test() {
  let assert [wide] =
    loop_params(single_func(lower_wat(narrow_loop_wat, False)))
  // Default: the loop carries all three mutated locals ($i, $acc, $tmp).
  list.length(wide) |> should.equal(3)
  let assert [narrow] =
    loop_params(single_func(lower_wat(narrow_loop_wat, True)))
  // Narrowed: $tmp — dead at the back-edge AND the exit — is dropped; $i and $acc remain.
  list.length(narrow) |> should.equal(2)
}

/// Objective: narrowing is BEHAVIOUR-PRESERVING. Compile+run `sumloop` (which mutates $i/$acc/$tmp
/// per iteration) with narrowing ON and OFF; both return the SPEC-CORRECT result. `sumloop(n)` sums
/// `i*2` for `i` in `[0, n)` = `n*(n-1)`: `sumloop(5)=20`, `sumloop(10)=90`, `sumloop(0)=0`.
pub fn narrow_preserves_loop_semantics_e2e_test() {
  list.each([False, True], fn(narrow) {
    let mod = load(lower_wat(narrow_loop_wat, narrow))
    catch_apply(mod, atom.create("sumloop"), [5]) |> should.equal(Ok(20))
    catch_apply(mod, atom.create("sumloop"), [10]) |> should.equal(Ok(90))
    catch_apply(mod, atom.create("sumloop"), [0]) |> should.equal(Ok(0))
  })
}

/// Objective: narrowing NEVER perturbs the DEFAULT lowering — `lower/1` (narrowing off) is
/// byte-identical to `lower_with(_, False)`, and the existing `sum_to` fixture lowers identically
/// either way (its only carried locals, `$i`/`$acc`, are both live). This pins the fail-closed
/// default the conformance corpus relies on.
pub fn narrow_off_is_default_test() {
  // The public `lower/1` is exactly `lower_with(_, False)`.
  let assert Ok(tm) =
    validate.validate({
      let assert Ok(m) = decode.decode(sum_to_wasm)
      m
    })
  lower.lower(tm) |> should.equal(lower.lower_with(tm, False))
  // A loop whose carried locals are all live is unchanged BY narrowing (nothing to drop).
  let default = single_func(build(sum_to_wasm))
  let narrowed = single_func(lower_wat(sum_to_wat, True))
  loop_params(default)
  |> list.map(list.length)
  |> should.equal(loop_params(narrowed) |> list.map(list.length))
}

// `(func (export "carry") (param $n i32) (result i32)
//    (local $i i32) (local $prev i32) (local $sum i32)
//    (block $break (loop $cont
//      (br_if $break (i32.ge_s (local.get $i) (local.get $n)))
//      (local.set $sum (i32.add (local.get $sum) (local.get $prev)))   ;; reads $prev at the TOP
//      (local.set $prev (local.get $i))                                ;; writes $prev for NEXT iter
//      (local.set $i (i32.add (local.get $i) (i32.const 1)))
//      (br $cont)))
//    (local.get $sum)))`
// $prev is written near the END of the body and read at the START of the NEXT iteration, so it is
// LIVE at the back-edge and MUST be kept as a loop param — a wrongly-dropped $prev would read 0
// every pass. This pins the loop back-edge soundness the fixpoint captures.
const carry_wat: String = "
  (module
    (func (export \"carry\") (param $n i32) (result i32)
      (local $i i32) (local $prev i32) (local $sum i32)
      (block $break
        (loop $cont
          (br_if $break (i32.ge_s (local.get $i) (local.get $n)))
          (local.set $sum (i32.add (local.get $sum) (local.get $prev)))
          (local.set $prev (local.get $i))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $cont)))
      (local.get $sum)))"

/// Objective: a local written late in a loop body and read at the TOP of the next iteration is live
/// at the back-edge — narrowing MUST keep it (the fixpoint's raison d'être). Structurally `$prev`
/// stays a loop param (all three locals kept), and end-to-end the result is spec-correct under
/// narrowing: `carry(n) = sum of prev_i = (n-2)(n-1)/2` for `n>=2` — `carry(5)=6`, `carry(10)=36`.
/// A dropped `$prev` would return 0.
pub fn narrow_keeps_backedge_live_local_test() {
  // $i, $prev, $sum are all live (at the back-edge or after) — nothing is dropped.
  let assert [params] = loop_params(single_func(lower_wat(carry_wat, True)))
  list.length(params) |> should.equal(3)
  // And the run is spec-correct under narrowing (and identically without it).
  list.each([False, True], fn(narrow) {
    let mod = load(lower_wat(carry_wat, narrow))
    catch_apply(mod, atom.create("carry"), [5]) |> should.equal(Ok(6))
    catch_apply(mod, atom.create("carry"), [10]) |> should.equal(Ok(36))
    catch_apply(mod, atom.create("carry"), [1]) |> should.equal(Ok(0))
  })
}

// `sum_to` as WAT (matches the `sum_to_wasm` byte fixture): both carried locals ($i, $acc) are live.
const sum_to_wat: String = "
  (module
    (func (export \"sum_to\") (param $n i32) (result i32)
      (local $i i32) (local $acc i32)
      (local.set $i (i32.const 1))
      (block $break
        (loop $cont
          (br_if $break (i32.gt_s (local.get $i) (local.get $n)))
          (local.set $acc (i32.add (local.get $acc) (local.get $i)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $cont)))
      (local.get $acc)))"

// ───────────────────────────── fixtures ─────────────────────────────

const add_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60, 0x02,
  0x7f, 0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x61,
  0x64, 0x64, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01,
  0x6a, 0x0b,
>>

const sum_to_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x73, 0x75,
  0x6d, 0x5f, 0x74, 0x6f, 0x00, 0x00, 0x0a, 0x29, 0x01, 0x27, 0x01, 0x02, 0x7f,
  0x41, 0x01, 0x21, 0x01, 0x02, 0x40, 0x03, 0x40, 0x20, 0x01, 0x20, 0x00, 0x4a,
  0x0d, 0x01, 0x20, 0x02, 0x20, 0x01, 0x6a, 0x21, 0x02, 0x20, 0x01, 0x41, 0x01,
  0x6a, 0x21, 0x01, 0x0c, 0x00, 0x0b, 0x0b, 0x20, 0x02, 0x0b,
>>

const fib_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x66, 0x69,
  0x62, 0x00, 0x00, 0x0a, 0x1e, 0x01, 0x1c, 0x00, 0x20, 0x00, 0x41, 0x02, 0x48,
  0x04, 0x7f, 0x20, 0x00, 0x05, 0x20, 0x00, 0x41, 0x01, 0x6b, 0x10, 0x00, 0x20,
  0x00, 0x41, 0x02, 0x6b, 0x10, 0x00, 0x6a, 0x0b, 0x0b,
>>

// `(func (export "f") (param i32) (result i32)
//    (i32.add
//      (if (result i32) (local.get 0)
//        (then (br 0 (i32.const 100)) (i32.const 999))
//        (else (i32.const 5)))
//      (i32.const 1)))` — produced with wat2wasm. The `br 0` targets the `if`.
const br_to_if_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00,
  0x00, 0x0a, 0x17, 0x01, 0x15, 0x00, 0x20, 0x00, 0x04, 0x7f, 0x41, 0xe4, 0x00,
  0x0c, 0x00, 0x41, 0xe7, 0x07, 0x05, 0x41, 0x05, 0x0b, 0x41, 0x01, 0x6a, 0x0b,
>>

// ── Phase-2 fixtures (all produced with wat2wasm; the WAT is in the doc comment) ──

// `(memory 1 2) (func (export "m") (param i32) (result i32)
//    (i32.store (local.get 0) (i32.const 42))
//    (drop (i32.load8_s (local.get 0))) (drop (i64.load8_s (local.get 0)))
//    (drop (f32.load (local.get 0))) (i32.load (local.get 0)))`
const mem_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 3, 2, 1, 0, 5, 4, 1,
  1, 1, 2, 7, 5, 1, 1, 109, 0, 0, 10, 34, 1, 32, 0, 32, 0, 65, 42, 54, 2, 0, 32,
  0, 44, 0, 0, 26, 32, 0, 48, 0, 0, 26, 32, 0, 42, 2, 0, 26, 32, 0, 40, 2, 0, 11,
>>

// `(memory 1) (func (export "g") (result i32)
//    (drop (memory.grow (i32.const 1))) (memory.size))`
const grow_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127, 3, 2, 1, 0, 5, 3, 1, 0, 1,
  7, 5, 1, 1, 103, 0, 0, 10, 11, 1, 9, 0, 65, 1, 64, 0, 26, 63, 0, 11,
>>

// `(global $g (mut i32) (i32.const 100)) (global $h i64 (i64.const 7))
//  (func (export "gg") (result i32) (global.set $g (i32.const 5)) (global.get $g))`
const global_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127, 3, 2, 1, 0, 6, 12, 2, 127,
  1, 65, 228, 0, 11, 126, 0, 66, 7, 11, 7, 6, 1, 2, 103, 103, 0, 0, 10, 10, 1, 8,
  0, 65, 5, 36, 0, 35, 0, 11,
>>

// `(type $t (func (result i32))) (table 1 funcref) (elem (i32.const 0) $f)
//  (func $f (type $t) (result i32) (i32.const 42))
//  (func (export "ci") (result i32) (call_indirect (type $t) (i32.const 0)))`
const ci_full_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127, 3, 3, 2, 0, 0, 4, 4, 1,
  112, 0, 1, 7, 6, 1, 2, 99, 105, 0, 1, 9, 7, 1, 0, 65, 0, 11, 1, 0, 10, 14, 2,
  4, 0, 65, 42, 11, 7, 0, 65, 0, 17, 0, 0, 11,
>>

// `(func (export "s") (param i32 i32 i32) (result i32)
//    (select (local.get 0) (local.get 1) (local.get 2)))`
const select_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 8, 1, 96, 3, 127, 127, 127, 1, 127, 3, 2, 1, 0,
  7, 5, 1, 1, 115, 0, 0, 10, 11, 1, 9, 0, 32, 0, 32, 1, 32, 2, 27, 11,
>>

// `(func (export "s64") (param i64 i64 i32) (result i64)
//    (select (local.get 0) (local.get 1) (local.get 2)))`
const select64_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 8, 1, 96, 3, 126, 126, 127, 1, 126, 3, 2, 1, 0,
  7, 7, 1, 3, 115, 54, 52, 0, 0, 10, 11, 1, 9, 0, 32, 0, 32, 1, 32, 2, 27, 11,
>>

// `(func (export "c") (param i64 i32 f32 f64) (result i32)
//    (drop (i32.wrap_i64 (local.get 0))) (drop (i64.extend_i32_s (local.get 1)))
//    (drop (i64.extend_i32_u (local.get 1))) (drop (i32.reinterpret_f32 (local.get 2)))
//    (drop (f32.reinterpret_i32 (local.get 1))) (drop (i64.reinterpret_f64 (local.get 3)))
//    (drop (i32.trunc_f64_u (local.get 3))) (i32.trunc_f32_s (local.get 2)))`
const conv_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 9, 1, 96, 4, 126, 127, 125, 124, 1, 127, 3, 2,
  1, 0, 7, 5, 1, 1, 99, 0, 0, 10, 35, 1, 33, 0, 32, 0, 167, 26, 32, 1, 172, 26,
  32, 1, 173, 26, 32, 2, 188, 26, 32, 1, 190, 26, 32, 3, 189, 26, 32, 3, 171, 26,
  32, 2, 168, 11,
>>

// `(memory 1) (data (i32.const 0) "abc") (start $init) (func $init)`
const data_start_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 5, 3, 1, 0, 1, 8,
  1, 0, 10, 4, 1, 2, 0, 11, 11, 9, 1, 0, 65, 0, 11, 3, 97, 98, 99,
>>

// `(func (export "fadd") (param f64 f64) (result f64) (f64.add (local.get 0) (local.get 1)))`
const fadd_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 124, 124, 1, 124, 3, 2, 1, 0, 7,
  8, 1, 4, 102, 97, 100, 100, 0, 0, 10, 9, 1, 7, 0, 32, 0, 32, 1, 160, 11,
>>

// ── Phase-5 (P5-05) fixtures (produced with wat2wasm; the WAT is in the doc comment) ──

// `(table 2 funcref) (table $e 1 externref) (elem declare func $f)
//  (func $f (result i32) (i32.const 42))
//  (func (export "rn") (result funcref) (ref.null func))
//  (func (export "ren") (result externref) (ref.null extern))
//  (func (export "rf") (result funcref) (ref.func $f))
//  (func (export "isn") (param externref) (result i32) (ref.is_null (local.get 0)))`
const ref_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 18, 4, 96, 0, 1, 127, 96, 0, 1, 112, 96, 0, 1,
  111, 96, 1, 111, 1, 127, 3, 6, 5, 0, 1, 2, 1, 3, 4, 7, 2, 112, 0, 2, 111, 0, 1,
  7, 23, 4, 2, 114, 110, 0, 1, 3, 114, 101, 110, 0, 2, 2, 114, 102, 0, 3, 3, 105,
  115, 110, 0, 4, 9, 5, 1, 3, 0, 1, 0, 10, 27, 5, 4, 0, 65, 42, 11, 4, 0, 208,
  112, 11, 4, 0, 208, 111, 11, 4, 0, 210, 0, 11, 5, 0, 32, 0, 209, 11,
>>

// `(table $t 3 funcref) (table $x 2 externref) (elem declare func $g)
//  (elem $pe funcref (ref.func $g)) (func $g (result i32) (i32.const 1))
//  (func (export "tget") (param i32) (result funcref) (table.get $t (local.get 0)))
//  (func (export "tset") (param i32 funcref) (table.set $t (local.get 0) (local.get 1)))
//  (func (export "tsize") (result i32) (table.size $t))
//  (func (export "tgrow") (param funcref i32) (result i32) (table.grow $t ...))
//  (func (export "tfill") (param i32 funcref i32) (table.fill $t ...))
//  (func (export "tinit") (param i32 i32 i32) (table.init $t $pe ...))
//  (func (export "tcopy") (param i32 i32 i32) (table.copy $t $t ...))
//  (func (export "edrop") (elem.drop $pe))`
const table_ops_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 36, 7, 96, 0, 1, 127, 96, 1, 127, 1, 112, 96,
  2, 127, 112, 0, 96, 2, 112, 127, 1, 127, 96, 3, 127, 112, 127, 0, 96, 3, 127,
  127, 127, 0, 96, 0, 0, 3, 10, 9, 0, 1, 2, 0, 3, 4, 5, 5, 6, 4, 7, 2, 112, 0, 3,
  111, 0, 2, 7, 63, 8, 4, 116, 103, 101, 116, 0, 1, 4, 116, 115, 101, 116, 0, 2,
  5, 116, 115, 105, 122, 101, 0, 3, 5, 116, 103, 114, 111, 119, 0, 4, 5, 116,
  102, 105, 108, 108, 0, 5, 5, 116, 105, 110, 105, 116, 0, 6, 5, 116, 99, 111,
  112, 121, 0, 7, 5, 101, 100, 114, 111, 112, 0, 8, 9, 9, 2, 3, 0, 1, 0, 1, 0, 1,
  0, 10, 82, 9, 4, 0, 65, 1, 11, 6, 0, 32, 0, 37, 0, 11, 8, 0, 32, 0, 32, 1, 38,
  0, 11, 5, 0, 252, 16, 0, 11, 9, 0, 32, 0, 32, 1, 252, 15, 0, 11, 11, 0, 32, 0,
  32, 1, 32, 2, 252, 17, 0, 11, 12, 0, 32, 0, 32, 1, 32, 2, 252, 12, 1, 0, 11,
  12, 0, 32, 0, 32, 1, 32, 2, 252, 14, 0, 0, 11, 5, 0, 252, 13, 1, 11,
>>

// `(memory 1) (data $pd "abcd")
//  (func (export "minit") (param i32 i32 i32) (memory.init $pd ...))
//  (func (export "ddrop") (data.drop $pd))
//  (func (export "mcopy") (param i32 i32 i32) (memory.copy ...))
//  (func (export "mfill") (param i32 i32 i32) (memory.fill ...))`
const bulk_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 10, 2, 96, 3, 127, 127, 127, 0, 96, 0, 0, 3, 5,
  4, 0, 1, 0, 0, 5, 3, 1, 0, 1, 7, 33, 4, 5, 109, 105, 110, 105, 116, 0, 0, 5,
  100, 100, 114, 111, 112, 0, 1, 5, 109, 99, 111, 112, 121, 0, 2, 5, 109, 102,
  105, 108, 108, 0, 3, 12, 1, 1, 10, 45, 4, 12, 0, 32, 0, 32, 1, 32, 2, 252, 8,
  0, 0, 11, 5, 0, 252, 9, 0, 11, 12, 0, 32, 0, 32, 1, 32, 2, 252, 10, 0, 0, 11,
  11, 0, 32, 0, 32, 1, 32, 2, 252, 11, 0, 11, 11, 7, 1, 1, 4, 97, 98, 99, 100,
>>

// `(memory $a 1) (memory $b 1)
//  (func (export "mm") (param i32) (result i32)
//    (i32.store $b (i32.const 0) (i32.const 7))
//    (memory.copy $b $a (i32.const 0) (i32.const 0) (i32.const 4))
//    (memory.fill $b (i32.const 0) (i32.const 0) (i32.const 1))
//    (i32.load $b (local.get 0)))` — wat2wasm --enable-multi-memory
const multimem_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 3, 2, 1, 0, 5, 5, 2,
  0, 1, 0, 1, 7, 6, 1, 2, 109, 109, 0, 0, 10, 37, 1, 35, 0, 65, 0, 65, 7, 54, 66,
  1, 0, 65, 0, 65, 0, 65, 4, 252, 10, 1, 0, 65, 0, 65, 0, 65, 1, 252, 11, 1, 32,
  0, 40, 66, 1, 0, 11,
>>

// `(memory i64 1) (func (export "m64") (param i64) (result i64) (i64.load (local.get 0)))`
// — wat2wasm --enable-memory64. Lower now ACCEPTS this (I4): the memory carries `Idx64`
// and the i64 address flows through unchanged (`memory64_lowers_test`).
const mem64_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 126, 1, 126, 3, 2, 1, 0, 5, 3, 1,
  4, 1, 7, 7, 1, 3, 109, 54, 52, 0, 0, 10, 9, 1, 7, 0, 32, 0, 41, 3, 0, 11,
>>

// `(func (export "sf") (param funcref funcref i32) (result funcref)
//    (select (result funcref) (local.get 0) (local.get 1) (local.get 2)))
//  (func (export "si") (param i32 i32 i32) (result i32)
//    (select (result i32) (local.get 0) (local.get 1) (local.get 2)))`
const select_t_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 15, 2, 96, 3, 112, 112, 127, 1, 112, 96, 3,
  127, 127, 127, 1, 127, 3, 3, 2, 0, 1, 7, 11, 2, 2, 115, 102, 0, 0, 2, 115, 105,
  0, 1, 10, 25, 2, 11, 0, 32, 0, 32, 1, 32, 2, 28, 1, 112, 11, 11, 0, 32, 0, 32,
  1, 32, 2, 28, 1, 127, 11,
>>

// `(table $t 4 funcref) (table $x 4 externref) (memory 1) (elem declare func $a)
//  (elem $pe funcref (ref.func $a) (ref.null func))
//  (elem (table $t) (offset (i32.const 0)) func $a)
//  (elem $xe (table $x) (offset (i32.const 0)) externref (ref.null extern))
//  (data $pd "xy") (data (i32.const 0) "hi") (func $a (result i32) (i32.const 5))`
// — wat2wasm --enable-multi-memory
const segments_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127, 3, 2, 1, 0, 4, 7, 2, 112,
  0, 4, 111, 0, 4, 5, 3, 1, 0, 1, 9, 30, 4, 3, 0, 1, 0, 5, 112, 2, 210, 0, 11,
  208, 112, 11, 0, 65, 0, 11, 1, 0, 6, 1, 65, 0, 11, 111, 1, 208, 111, 11, 10, 6,
  1, 4, 0, 65, 5, 11, 11, 12, 2, 1, 2, 120, 121, 0, 65, 0, 11, 2, 104, 105,
>>

// `(import "spectest" "global_i32" (global $ig i32))
//  (import "spectest" "table" (table $it 10 20 funcref))
//  (import "spectest" "memory" (memory $im 1 2))
//  (global $dg (mut i32) (i32.const 3)) (table $dt 2 funcref) (memory $dm 1)
//  (func (export "getg") (result i32) (global.get $ig))
//  (export "g" (global $dg)) (export "t" (table $dt)) (export "m" (memory $dm))`
// — wat2wasm --enable-multi-memory
const imports_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127, 2, 64, 3, 8, 115, 112,
  101, 99, 116, 101, 115, 116, 10, 103, 108, 111, 98, 97, 108, 95, 105, 51, 50,
  3, 127, 0, 8, 115, 112, 101, 99, 116, 101, 115, 116, 5, 116, 97, 98, 108, 101,
  1, 112, 1, 10, 20, 8, 115, 112, 101, 99, 116, 101, 115, 116, 6, 109, 101, 109,
  111, 114, 121, 2, 1, 1, 2, 3, 2, 1, 0, 4, 4, 1, 112, 0, 2, 5, 3, 1, 0, 1, 6, 6,
  1, 127, 1, 65, 3, 11, 7, 20, 4, 4, 103, 101, 116, 103, 0, 0, 1, 103, 3, 1, 1,
  116, 1, 1, 1, 109, 2, 1, 10, 6, 1, 4, 0, 35, 0, 11,
>>

// `(elem declare func $f) (func $f (result i32) (i32.const 9))
//  (global $gf funcref (ref.func $f)) (global $gn (mut externref) (ref.null extern))
//  (func (export "gg") (result funcref) (global.get $gf))`
const globals_ref_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 9, 2, 96, 0, 1, 127, 96, 0, 1, 112, 3, 3, 2, 0,
  1, 6, 11, 2, 112, 0, 210, 0, 11, 111, 1, 208, 111, 11, 7, 6, 1, 2, 103, 103, 0,
  1, 9, 5, 1, 3, 0, 1, 0, 10, 11, 2, 4, 0, 65, 9, 11, 4, 0, 35, 0, 11,
>>

// `(func (export "loc") (result funcref) (local funcref) (local.get 0))` — a declared
// funcref local defaults to the null reference (spec local initialization).
const ref_local_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 112, 3, 2, 1, 0, 7, 7, 1, 3,
  108, 111, 99, 0, 0, 10, 8, 1, 6, 1, 1, 112, 32, 0, 11,
>>

// ═══════════════════════════════ Phase 7 — exception handling ═══════════════════════════════
//
// Spec-cited against the WebAssembly exception-handling proposal (legacy `try`/`catch`/
// `catch_all`/`delegate`/`rethrow` + modern `throw`/`throw_ref`/`try_table`), NOT the code.
// BOTH wire encodings must structure into the ONE inline-handler `ir.Try` (T1): a legacy
// `try…catch` maps 1:1 (the handler is the `CatchHandler.handler`), a modern `try_table`
// clause maps to a TRANSFER (`Break`/`Continue`/`Return`) to the resolved enclosing frame.
// Fixtures are hand-built well-typed `ast.Module`s (each validated first, exactly as the
// P7-04 acceptance fixtures) plus the MEASURED 331-byte real Porffor 0.61.13 module.

/// A function type `params -> results`.
fn eh_ft(
  params: List(ast.ValType),
  results: List(ast.ValType),
) -> ast.FuncType {
  ast.FuncType(params, results)
}

/// A defined function of `types[type_idx]`, with declared `locals` and `body`.
fn eh_func(
  type_idx: Int,
  locals: List(ast.ValType),
  body: List(ast.Instr),
) -> ast.Func {
  ast.Func(type_idx: type_idx, locals: locals, body: body)
}

/// An otherwise-empty EH module (only the fields the EH tests exercise).
fn eh_module(
  types types: List(ast.FuncType),
  imports imports: List(ast.Import),
  tags tags: List(ast.Tag),
  funcs funcs: List(ast.Func),
  exports exports: List(ast.Export),
) -> ast.Module {
  ast.Module(
    imported_func_count: 0,
    rec_groups: [],
    types: list.map(types, ast.func_def),
    imports: imports,
    tables: [],
    memories: [],
    globals: [],
    tags: tags,
    funcs: funcs,
    start: option.None,
    elements: [],
    data: [],
    data_count: option.None,
    exports: exports,
  )
}

/// Validate + lower an EH module (both must succeed — these are valid fixtures).
fn eh_lower(m: ast.Module) -> ir.Module {
  let assert Ok(typed) = validate.validate(m)
  let assert Ok(irm) = lower.lower(typed)
  irm
}

/// Every sub-expression of `e`, recursing THROUGH `Try` bodies AND handlers (the base
/// `all_exprs` stops at `Try`, which has no non-EH sub-expressions).
fn all_exprs_eh(e: ir.Expr) -> List(ir.Expr) {
  let nested = case e {
    ir.Let(_, rhs, body) -> list.append(all_exprs_eh(rhs), all_exprs_eh(body))
    ir.Block(_, _, body) -> all_exprs_eh(body)
    ir.Loop(_, _, _, body) -> all_exprs_eh(body)
    ir.If(_, _, t, el) -> list.append(all_exprs_eh(t), all_exprs_eh(el))
    ir.Switch(_, _, arms, default) ->
      list.append(
        list.flat_map(arms, fn(a) { all_exprs_eh(a.body) }),
        all_exprs_eh(default),
      )
    ir.Charge(_, body) -> all_exprs_eh(body)
    ir.Try(_, body, handlers) ->
      list.append(
        all_exprs_eh(body),
        list.flat_map(handlers, fn(h) { all_exprs_eh(h.handler) }),
      )
    _ -> []
  }
  [e, ..nested]
}

/// The first `Try` node in function `name`.
fn find_try(irm: ir.Module, name: String) -> ir.Expr {
  let assert Ok(t) =
    list.find(all_exprs_eh(func(irm, name).body), fn(e) {
      case e {
        ir.Try(_, _, _) -> True
        _ -> False
      }
    })
  t
}

/// The label of the first `Block` node in function `name`.
fn first_block_label(irm: ir.Module, name: String) -> String {
  let assert Ok(ir.Block(label, _, _)) =
    list.find(all_exprs_eh(func(irm, name).body), fn(e) {
      case e {
        ir.Block(_, _, _) -> True
        _ -> False
      }
    })
  label
}

/// Every sub-expression across every defined function of `irm`.
fn all_module_exprs(irm: ir.Module) -> List(ir.Expr) {
  list.flat_map(irm.functions, fn(f) { all_exprs_eh(f.body) })
}

// ── the tag section → Module.tags / ImportTag / ExportTag (spec: tag section id 13) ──

/// A defined `(tag (param f64 i32))` lowers to `TagDecl("tag0", [TF64, TI32])` — the tag's
/// PARAMS are the exception operand types (its results are `[]`, so `TagDecl` stores only
/// params). The Porffor-ABI tag shape.
pub fn tag_section_lowers_to_tagdecl_test() {
  let irm =
    eh_lower(
      eh_module(
        types: [eh_ft([ast.F64, ast.I32], [])],
        imports: [],
        tags: [ast.Tag(0)],
        funcs: [],
        exports: [],
      ),
    )
  irm.tags |> should.equal([ir.TagDecl("tag0", [ir.TF64, ir.TI32])])
}

/// An IMPORTED tag lowers to `ImportTag(module, name, params)` at the low tagidx; the
/// module then declares NO defined tags (`Module.tags == []`). (Imports precede defined
/// tags in the index space, exactly like globals.)
pub fn imported_tag_lowers_to_importtag_test() {
  let irm =
    eh_lower(
      eh_module(
        types: [eh_ft([ast.F64, ast.I32], [])],
        imports: [ast.Import("host", "e", ast.ImportTag(0))],
        tags: [],
        funcs: [],
        exports: [],
      ),
    )
  irm.tags |> should.equal([])
  irm.imports
  |> list.contains(ir.ImportTag("host", "e", [ir.TF64, ir.TI32]))
  |> should.equal(True)
}

/// An exported tag lowers to `ExportTag(export_name, "tag<idx>")` — measured: Porffor emits
/// `(export "0" (tag 0))`.
pub fn exported_tag_lowers_to_exporttag_test() {
  let irm =
    eh_lower(
      eh_module(
        types: [eh_ft([], [])],
        imports: [],
        tags: [ast.Tag(0)],
        funcs: [],
        exports: [ast.Export("0", ast.ExportTag, 0)],
      ),
    )
  irm.exports
  |> list.contains(ir.ExportTag("0", "tag0"))
  |> should.equal(True)
}

/// The NEGATIVE obligation (J6): a module with no tag section lowers `Module.tags = []` —
/// conformance-neutral, byte-identical to Phase-6.
pub fn tag_free_module_has_no_tags_test() {
  build(add_wasm).tags |> should.equal([])
}

// ── throw → ir.Throw (a bottom transfer; spec exec §control `throw`) ──

/// `(tag $e (param i32)) … i32.const 7 (throw $e)` lowers to `Throw("tag0", [ConstI32(7)])`,
/// and — being a bottom transfer — is the function body VERBATIM (no `Let` binds a throw
/// result, and the code after it is consumed as dead, exactly like `Return`/`Unreachable`).
pub fn throw_lowers_to_throw_node_test() {
  let irm =
    eh_lower(eh_module(
      types: [eh_ft([ast.I32], []), eh_ft([], [])],
      imports: [],
      tags: [ast.Tag(0)],
      funcs: [
        eh_func(1, [], [
          ast.I32Const(7),
          ast.Throw(0),
          // dead code after a bottom `throw` — must NOT survive
          ast.I32Const(99),
          ast.Drop,
          ast.End,
        ]),
      ],
      exports: [],
    ))
  func(irm, "f0").body |> should.equal(ir.Throw("tag0", [ir.ConstI32(7)]))
}

/// A multi-operand `throw` carries its operands in TAG-PARAM order (deepest-first push
/// order): `(param i32 i64) … i32.const 1 i64.const 2 throw` → `Throw("tag0", [ConstI32(1),
/// ConstI64(2)])` — the payload list is built in the tag's declared operand order.
pub fn throw_multi_operand_order_test() {
  let irm =
    eh_lower(
      eh_module(
        types: [eh_ft([ast.I32, ast.I64], []), eh_ft([], [])],
        imports: [],
        tags: [ast.Tag(0)],
        funcs: [
          eh_func(1, [], [
            ast.I32Const(1),
            ast.I64Const(2),
            ast.Throw(0),
            ast.End,
          ]),
        ],
        exports: [],
      ),
    )
  func(irm, "f0").body
  |> should.equal(ir.Throw("tag0", [ir.ConstI32(1), ir.ConstI64(2)]))
}

// ── LEGACY try/catch → the inline-handler ir.Try (T1; Porffor's headline path) ──

/// `try (result i32) (i32.const 10) catch $e (drop) (i32.const 20) end` lowers 1:1 to
/// `Try([TI32], Values([ConstI32(10)]), [CatchHandler(OnTag("tag0"), [name], None,
/// Values([ConstI32(20)]))])`: the body and the inline handler are alternatives yielding the
/// try's result; the handler binds the tag's operand to a fresh `payload` name it consumes;
/// `exnref = None` (no `rethrow`). This is the exact legacy → IR shape 06 emits against.
pub fn legacy_try_catch_lowers_to_try_test() {
  let irm =
    eh_lower(
      eh_module(
        types: [eh_ft([ast.I32], []), eh_ft([], [ast.I32])],
        imports: [],
        tags: [ast.Tag(0)],
        funcs: [
          eh_func(1, [], [
            ast.TryLegacy(ast.BlockVal(ast.I32)),
            ast.I32Const(10),
            ast.LegacyCatch(0),
            ast.Drop,
            ast.I32Const(20),
            ast.End,
            ast.End,
          ]),
        ],
        exports: [],
      ),
    )
  let assert ir.Try(result, body, handlers) = find_try(irm, "f0")
  result |> should.equal([ir.TI32])
  body |> should.equal(ir.Values([ir.ConstI32(10)]))
  let assert [ir.CatchHandler(on, payload, exnref, handler)] = handlers
  on |> should.equal(ir.OnTag("tag0"))
  list.length(payload) |> should.equal(1)
  exnref |> should.equal(option.None)
  handler |> should.equal(ir.Values([ir.ConstI32(20)]))
}

/// Legacy `try [] catch_all end` → `CatchHandler(OnAll, [], None, …)`: a `catch_all` matches
/// ANY exception and binds no payload (spec: it pushes no operands).
pub fn legacy_catch_all_lowers_to_onall_test() {
  let irm =
    eh_lower(
      eh_module(
        types: [eh_ft([], [])],
        imports: [],
        tags: [],
        funcs: [
          eh_func(0, [], [
            ast.TryLegacy(ast.BlockEmpty),
            ast.LegacyCatchAll,
            ast.End,
            ast.End,
          ]),
        ],
        exports: [],
      ),
    )
  let assert ir.Try(result, body, [handler]) = find_try(irm, "f0")
  result |> should.equal([])
  body |> should.equal(ir.Values([]))
  handler
  |> should.equal(ir.CatchHandler(ir.OnAll, [], option.None, ir.Values([])))
}

/// Legacy `delegate` → a catch-and-re-raise handler (`CatchHandler(OnAll, [], Some(e),
/// ThrowRef(Var(e)))`), forwarding an uncaught exception to the enclosing region (§A.4).
pub fn legacy_delegate_lowers_to_reraise_test() {
  let irm =
    eh_lower(
      eh_module(
        types: [eh_ft([], [])],
        imports: [],
        tags: [],
        funcs: [
          eh_func(0, [], [
            ast.Block(ast.BlockEmpty),
            ast.TryLegacy(ast.BlockEmpty),
            ast.LegacyDelegate(0),
            ast.End,
            ast.End,
          ]),
        ],
        exports: [],
      ),
    )
  let assert ir.Try(_, _, [ir.CatchHandler(on, payload, exnref, handler)]) =
    find_try(irm, "f0")
  on |> should.equal(ir.OnAll)
  payload |> should.equal([])
  let assert option.Some(e) = exnref
  handler |> should.equal(ir.ThrowRef(ir.Var(e)))
}

// ── MODERN try_table → ir.Try with a TRANSFER to the resolved enclosing label (spec:
//    catch labels are resolved in the ENCLOSING context) ──

/// `block $h (result i32 i64) { try_table (catch $e $h) end  i32.const  i64.const }`: the
/// `catch $e $h` clause resolves `$h` to the ENCLOSING BLOCK's label (the parent frame, NOT
/// the try_table's own body label), so its handler is `Break(<block-label>, [payload…])`
/// carrying the tag operands. Proves the frame resolution + Break/Continue/Return-by-kind.
pub fn modern_try_table_catch_resolves_enclosing_label_test() {
  let irm =
    eh_lower(
      eh_module(
        types: [
          eh_ft([ast.I32, ast.I64], []),
          eh_ft([], [ast.I32, ast.I64]),
          eh_ft([], [ast.I32, ast.I64]),
        ],
        imports: [],
        tags: [ast.Tag(0)],
        funcs: [
          eh_func(1, [], [
            ast.Block(ast.BlockTypeIdx(2)),
            ast.TryTable(ast.BlockEmpty, [ast.Catch(0, 0)]),
            ast.End,
            ast.I32Const(0),
            ast.I64Const(0),
            ast.End,
            ast.End,
          ]),
        ],
        exports: [],
      ),
    )
  let assert ir.Try(_, _, [ir.CatchHandler(on, payload, exnref, handler)]) =
    find_try(irm, "f0")
  on |> should.equal(ir.OnTag("tag0"))
  list.length(payload) |> should.equal(2)
  exnref |> should.equal(option.None)
  // the handler is a Break to the ENCLOSING block's label, carrying the payload
  let assert ir.Break(brk_label, brk_vals) = handler
  brk_label |> should.equal(first_block_label(irm, "f0"))
  brk_vals |> should.equal(list.map(payload, ir.Var))
}

/// `catch_ref $e $h` → `CatchHandler(OnTag(...), [payload…], Some(exnref), Break(L, [payload…
/// ++ exnref]))`: the ref-capturing form binds an `exnref` AND delivers it (after the
/// operands) to the label (spec: operands then exnref on top).
pub fn modern_try_table_catch_ref_captures_exnref_test() {
  let irm =
    eh_lower(
      eh_module(
        types: [
          eh_ft([ast.I32, ast.I64], []),
          eh_ft([], [ast.I32, ast.I64, ast.ExnRef]),
          eh_ft([], [ast.I32, ast.I64, ast.ExnRef]),
        ],
        imports: [],
        tags: [ast.Tag(0)],
        funcs: [
          eh_func(1, [], [
            ast.Block(ast.BlockTypeIdx(2)),
            ast.TryTable(ast.BlockEmpty, [ast.CatchRef(0, 0)]),
            ast.End,
            ast.I32Const(0),
            ast.I64Const(0),
            ast.RefNull(ast.ExnRef),
            ast.End,
            ast.End,
          ]),
        ],
        exports: [],
      ),
    )
  let assert ir.Try(_, _, [ir.CatchHandler(on, payload, exnref, handler)]) =
    find_try(irm, "f0")
  on |> should.equal(ir.OnTag("tag0"))
  list.length(payload) |> should.equal(2)
  let assert option.Some(e) = exnref
  let assert ir.Break(_, brk_vals) = handler
  // Break carries [payload ++ exnref]
  brk_vals
  |> should.equal(list.append(list.map(payload, ir.Var), [ir.Var(e)]))
}

/// `catch_all $l` → `CatchHandler(OnAll, [], None, Break(L, []))` — matches any exception,
/// no payload, no exnref.
pub fn modern_try_table_catch_all_test() {
  let irm =
    eh_lower(
      eh_module(
        types: [eh_ft([], [])],
        imports: [],
        tags: [],
        funcs: [
          eh_func(0, [], [
            ast.Block(ast.BlockEmpty),
            ast.TryTable(ast.BlockEmpty, [ast.CatchAll(0)]),
            ast.End,
            ast.End,
            ast.End,
          ]),
        ],
        exports: [],
      ),
    )
  let assert ir.Try(_, _, [ir.CatchHandler(on, payload, exnref, _handler)]) =
    find_try(irm, "f0")
  on |> should.equal(ir.OnAll)
  payload |> should.equal([])
  exnref |> should.equal(option.None)
}

/// A `try_table` whose BODY `br`s to its own label is `Block`-wrapped (arity-transparent),
/// exactly like a branched-to `if` — so the body's `Break` has a home. `try_table (result
/// i32) { i32.const 5  br 0 }`.
pub fn modern_try_table_body_break_is_block_wrapped_test() {
  let irm =
    eh_lower(
      eh_module(
        types: [eh_ft([], [ast.I32])],
        imports: [],
        tags: [],
        funcs: [
          eh_func(0, [], [
            ast.TryTable(ast.BlockVal(ast.I32), []),
            ast.I32Const(5),
            ast.Br(0),
            ast.End,
            ast.End,
          ]),
        ],
        exports: [],
      ),
    )
  // Some Block directly wraps a Try, and the Try's body breaks to that block's label.
  let wrapped =
    list.any(all_module_exprs(irm), fn(e) {
      case e {
        ir.Block(label, _, ir.Try(_, body, _)) -> expr_body_breaks(body, label)
        _ -> False
      }
    })
  wrapped |> should.equal(True)
}

/// True iff `body` is (directly) a `Break` to `label` — a tiny local check for the wrapper.
fn expr_body_breaks(body: ir.Expr, label: String) -> Bool {
  case body {
    ir.Break(l, _) -> l == label
    _ -> False
  }
}

// ── throw_ref / exnref (spec exec §control `throw_ref`; the exnref reference layer) ──

/// `(param exnref) (result i32) local.get 0 throw_ref` → `ThrowRef(Var("p0"))` — a bottom
/// transfer forwarding the exnref value unchanged (the null-exnref trap + re-raise are 07's).
pub fn throw_ref_lowers_to_throwref_test() {
  let irm =
    eh_lower(
      eh_module(
        types: [eh_ft([ast.ExnRef], [ast.I32])],
        imports: [],
        tags: [],
        funcs: [eh_func(0, [], [ast.LocalGet(0), ast.ThrowRef, ast.End])],
        exports: [],
      ),
    )
  func(irm, "f0").body |> should.equal(ir.ThrowRef(ir.Var("p0")))
}

/// `ref.null exn` lowers to the `ConstNull(ExnRef)` VALUE (R1c — like any null literal), and
/// an `exnref` function param/result maps to `ir.TExnRef`.
pub fn ref_null_exn_and_exnref_valtype_test() {
  let irm =
    eh_lower(
      eh_module(
        types: [eh_ft([], [ast.ExnRef])],
        imports: [],
        tags: [],
        funcs: [eh_func(0, [], [ast.RefNull(ast.ExnRef), ast.End])],
        exports: [],
      ),
    )
  let f = func(irm, "f0")
  f.result |> should.equal([ir.TExnRef])
  f.body |> should.equal(ir.Values([ir.ConstNull(ir.ExnRef)]))
}

/// A declared `exnref` LOCAL zero-initialises to `ConstNull(ExnRef)` (spec: a reftype local
/// inits to its null) — the same discipline as funcref/externref locals.
pub fn exnref_local_zero_inits_to_null_test() {
  let irm =
    eh_lower(
      eh_module(
        types: [eh_ft([], [ast.ExnRef])],
        imports: [],
        tags: [],
        funcs: [eh_func(0, [ast.ExnRef], [ast.LocalGet(0), ast.End])],
        exports: [],
      ),
    )
  let assert ir.Let([name], init, _body) = func(irm, "f0").body
  init |> should.equal(ir.Values([ir.ConstNull(ir.ExnRef)]))
  // the body then forwards that zero-initialised local
  name |> should.not_equal("")
}

// ── fail-closed (no panic; validation is the real boundary — this is insurance) ──

/// An out-of-range tagidx in `throw` (only reachable on an UNVALIDATED module) fails closed
/// with `Error(UnknownTagIndex(_))`, never a panic. Built directly as a `TypedModule` with an
/// empty tag space so validate's rejection is bypassed.
pub fn throw_unknown_tag_fails_closed_test() {
  let m =
    ast.Module(
      imported_func_count: 0,
      rec_groups: [],
      types: list.map([ast.FuncType([], [])], ast.func_def),
      imports: [],
      tables: [],
      memories: [],
      globals: [],
      tags: [],
      funcs: [ast.Func(0, [], [ast.Throw(0), ast.End])],
      start: option.None,
      elements: [],
      data: [],
      data_count: option.None,
      exports: [],
    )
  let tm =
    validate.TypedModule(
      module: m,
      imported_func_count: 0,
      imported_global_count: 0,
      imported_table_count: 0,
      imported_memory_count: 0,
      func_types: [ast.FuncType([], [])],
      func_locals: [[]],
      global_types: [],
      table_types: [],
      memory_idx_types: [],
      elem_types: [],
      refs: set.new(),
      imported_tag_count: 0,
      // empty tag space → tagidx 0 is out of range
      tag_types: [],
    )
  lower.lower(tm) |> should.equal(Error(lower.UnknownTagIndex(0)))
}

// ── the MEASURED real Porffor module lowers to Try IR (§A.4; the headline) ──

/// The FULL 331-byte `npx porffor wasm trycatch.js` (Porffor 0.61.13) output — legacy
/// `try`/`catch`/`throw` + `(tag (param f64 i32))` + `(export "0" (tag 0))` — decodes,
/// validates AND LOWERS: `Module.tags = [TagDecl("tag0", [TF64, TI32])]`, an `ExportTag`, at
/// least one inline-handler `Try` with an `OnTag("tag0")` handler, and a `Throw("tag0", _)`
/// site. The measured proof that the real Porffor legacy path structures into the Try IR.
pub fn real_porffor_legacy_module_lowers_to_try_test() {
  let irm = build(to_bytes(porffor_legacy_eh_module))
  irm.tags |> should.equal([ir.TagDecl("tag0", [ir.TF64, ir.TI32])])
  irm.exports
  |> list.contains(ir.ExportTag("0", "tag0"))
  |> should.equal(True)
  let exprs = all_module_exprs(irm)
  // an inline-handler Try catching the module's tag
  list.any(exprs, fn(e) {
    case e {
      ir.Try(_, _, handlers) ->
        list.any(handlers, fn(h) { h.on == ir.OnTag("tag0") })
      _ -> False
    }
  })
  |> should.equal(True)
  // a throw of the module's tag
  list.any(exprs, fn(e) {
    case e {
      ir.Throw("tag0", _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
}

/// A raw byte list → `BitArray`.
fn to_bytes(xs: List(Int)) -> BitArray {
  list.fold(xs, <<>>, fn(acc, b) { <<acc:bits, b:size(8)>> })
}

// The FULL 331-byte output of `npx porffor wasm trycatch.js` (Porffor 0.61.13), a JS
// `try { throw } catch {}` — legacy `try`/`catch`/`throw` + `(tag (param f64 i32))` + tag
// export. Copied verbatim from the P7-03/P7-04 decode/validate fixtures (measured bytes).
const porffor_legacy_eh_module: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x1C, 0x04, 0x60, 0x00,
  0x02, 0x7C, 0x7F, 0x60, 0x06, 0x7C, 0x7F, 0x7C, 0x7F, 0x7C, 0x7F, 0x02, 0x7C,
  0x7F, 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F, 0x60, 0x02, 0x7C, 0x7F, 0x00, 0x03,
  0x04, 0x03, 0x00, 0x01, 0x02, 0x05, 0x03, 0x01, 0x00, 0x01, 0x0D, 0x03, 0x01,
  0x00, 0x03, 0x07, 0x0D, 0x03, 0x01, 0x24, 0x02, 0x00, 0x01, 0x30, 0x04, 0x00,
  0x01, 0x6D, 0x00, 0x00, 0x0A, 0x80, 0x02, 0x03, 0x29, 0x01, 0x01, 0x7F, 0x44,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x41, 0x00, 0x44, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x41, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x14, 0x40, 0x41, 0x01, 0x10, 0x01, 0x22, 0x00, 0x0B, 0xB0, 0x01,
  0x06, 0x01, 0x7C, 0x01, 0x7F, 0x01, 0x7C, 0x01, 0x7F, 0x01, 0x7C, 0x01, 0x7F,
  0x06, 0x40, 0x20, 0x04, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x64, 0xB8, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x62, 0x04,
  0x40, 0x20, 0x04, 0x20, 0x05, 0x08, 0x00, 0x1A, 0x0B, 0x44, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0xF0, 0x3F, 0x21, 0x06, 0x41, 0x01, 0x21, 0x07, 0x20, 0x00,
  0xFC, 0x03, 0x04, 0x40, 0x20, 0x06, 0xFC, 0x02, 0x20, 0x07, 0x10, 0x02, 0x45,
  0x04, 0x40, 0x20, 0x02, 0x20, 0x03, 0x0F, 0x0B, 0x0B, 0x20, 0x06, 0x20, 0x07,
  0x0F, 0x1A, 0x07, 0x00, 0x21, 0x09, 0x22, 0x08, 0x21, 0x0A, 0x20, 0x09, 0x21,
  0x0B, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x21, 0x06, 0x41,
  0x01, 0x21, 0x07, 0x20, 0x00, 0xFC, 0x03, 0x04, 0x40, 0x20, 0x06, 0xFC, 0x02,
  0x20, 0x07, 0x10, 0x02, 0x45, 0x04, 0x40, 0x20, 0x02, 0x20, 0x03, 0x0F, 0x0B,
  0x0B, 0x20, 0x06, 0x20, 0x07, 0x0F, 0x1A, 0x0B, 0x20, 0x00, 0xFC, 0x03, 0x04,
  0x40, 0x20, 0x02, 0x20, 0x03, 0x0F, 0x0B, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x41, 0x00, 0x0F, 0x0B, 0x22, 0x01, 0x01, 0x7F, 0x20, 0x01,
  0x21, 0x02, 0x20, 0x00, 0x41, 0x00, 0x47, 0x20, 0x02, 0x41, 0x05, 0x4A, 0x71,
  0x20, 0x02, 0x41, 0xC3, 0x00, 0x47, 0x71, 0x20, 0x02, 0x41, 0xC3, 0x01, 0x47,
  0x71, 0x0F, 0x0B, 0x0B, 0x01, 0x00,
]
