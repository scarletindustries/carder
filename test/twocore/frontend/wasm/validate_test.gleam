//// Spec-based conformance tests for `twocore/frontend/wasm/validate` (Unit 10a).
////
//// Assertions target the WebAssembly core spec's VALIDATION rules
//// (<https://webassembly.github.io/spec/core/valid/>) and the abstract stack-typing
//// algorithm (<https://webassembly.github.io/spec/core/appendix/algorithm.html>) — NOT
//// whatever the implementation happens to emit. Each negative case cites the rule it
//// violates. This suite has **no IR dependency**: it gates the security boundary
//// independently of lowering/backend.
////
//// Fixtures are `.wasm` bytes. The valid ones are produced by `wat2wasm`; the invalid
//// ones by `wat2wasm --no-check` (so the bytes decode cleanly but must be REJECTED by
//// validation). Each invalid module decodes successfully — the failure is a typing
//// fault, exactly what `validate` must catch.

import gleam/option.{None, Some}
import gleam/set
import gleeunit/should
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/validate

// ───────────────────────────── helper ─────────────────────────────

/// Decode then validate `bytes`. The decode must succeed (these fixtures are
/// structurally well-formed); the returned `Result` is the validation outcome.
fn validated(
  bytes: BitArray,
) -> Result(validate.TypedModule, validate.ValidateError) {
  let assert Ok(m) = decode.decode(bytes)
  validate.validate(m)
}

/// Assert a module is accepted (well-typed).
fn accept(bytes: BitArray) {
  case validated(bytes) {
    Ok(_) -> True
    Error(_) -> False
  }
  |> should.equal(True)
}

// ── hand-built `ast.Module` helpers (for the Phase-2 rejection cases) ──
// The unit's negative tests target the *typing rule* directly, so they construct
// ill-typed `ast.Module` values (each decodes from valid bytes in principle, but
// hand-building lets us hit out-of-range indices / multi-memory / bad limits / start
// signatures that `wat2wasm` would refuse to emit) and validate them in isolation.

/// A function type `params -> results`.
fn ft(params: List(ast.ValType), results: List(ast.ValType)) -> ast.FuncType {
  ast.FuncType(params, results)
}

/// A defined function with `type_idx`, no extra declared locals, and `body` (whose
/// trailing `ast.End` closes the implicit function frame).
fn func_(type_idx: Int, body: List(ast.Instr)) -> ast.Func {
  ast.Func(type_idx: type_idx, locals: [], body: body)
}

/// A memory type with `min` pages and optional `max`.
fn mem(min: Int, max: option.Option(Int)) -> ast.MemType {
  ast.MemType(ast.Limits(min, max), ast.Idx32)
}

/// A (funcref) table type with `min` entries and optional `max`.
fn tbl(min: Int, max: option.Option(Int)) -> ast.TableType {
  ast.TableType(ast.FuncRef, ast.Limits(min, max))
}

/// A reference-typed table with element reftype `ref_ty` (`FuncRef`/`ExternRef`).
fn rtbl(ref_ty: ast.ValType, min: Int) -> ast.TableType {
  ast.TableType(ref_ty, ast.Limits(min, option.None))
}

/// A 64-bit (memory64) memory type with `min` pages and optional `max`.
fn mem64(min: Int, max: option.Option(Int)) -> ast.MemType {
  ast.MemType(ast.Limits(min, max), ast.Idx64)
}

/// An otherwise-empty module; callers override the fields they exercise.
fn module(
  types types: List(ast.FuncType),
  tables tables: List(ast.TableType),
  memories memories: List(ast.MemType),
  globals globals: List(ast.Global),
  funcs funcs: List(ast.Func),
  start start: option.Option(Int),
  elements elements: List(ast.ElementSegment),
  data data: List(ast.DataSegment),
) -> ast.Module {
  ast.Module(
    imported_func_count: 0,
    types: types,
    imports: [],
    tables: tables,
    memories: memories,
    globals: globals,
    tags: [],
    funcs: funcs,
    start: start,
    elements: elements,
    data: data,
    data_count: None,
    exports: [],
  )
}

// ───────────────────────────── valid acceptance ─────────────────────────────
// Spec: a module is valid iff every function body type-checks. The Phase-1 corpus
// and a few tricky-but-legal shapes must all be ACCEPTED.

/// `add(i32,i32)->i32` is well-typed.
pub fn accept_add_test() {
  accept(add_wasm)
}

/// `sum_to` (block + loop + br_if/br + mutable locals) is well-typed — exercises
/// `loop` label = INPUT types and a `br_if` to an enclosing block.
pub fn accept_sum_to_test() {
  accept(sum_to_wasm)
}

/// `fib` (an `if (result i32)` with `else` + a direct self-`call`) is well-typed.
pub fn accept_fib_test() {
  accept(fib_wasm)
}

/// An `if` with NO `else` whose blocktype params==results (here empty) is valid
/// (spec: an else-less `if` is valid when its inputs and results coincide).
pub fn accept_elseless_balanced_test() {
  accept(elseless_valid_wasm)
}

/// A `block` with a multi-value result type (`() -> (i32, i32)`, a `typeidx`
/// blocktype) is valid (spec: multi-value blocks).
pub fn accept_multivalue_block_test() {
  accept(mv_wasm)
}

/// An `if`/`else` that both yield i32 (`abs`) is valid.
pub fn accept_if_else_test() {
  accept(abs_wasm)
}

// ── polymorphic stack (the algorithm's hard part) ──
// Spec: after `unreachable` the operand stack is polymorphic; `Unknown` unifies with
// any expected type, so these are valid.

/// `(func (result i32) unreachable)` — `unreachable` makes the stack polymorphic, so
/// the missing i32 result unifies (spec: stack-polymorphic `unreachable`).
pub fn accept_unreachable_result_test() {
  accept(poly_unreachable_wasm)
}

/// `(func (result i32) unreachable i32.add)` — a stack-polymorphic `i32.add` after
/// `unreachable` validates (its operands come from the polymorphic `Unknown`).
pub fn accept_unreachable_then_op_test() {
  accept(poly_after_wasm)
}

// ───────────────────────────── invalid rejection ─────────────────────────────
// Each must be REJECTED with a typed ValidateError (never accepted, never a panic).

/// Operand-stack underflow: `i32.add` with no operands (spec: the operand stack must
/// provide the instruction's inputs).
pub fn reject_underflow_test() {
  validated(underflow_wasm)
  |> should.equal(Error(validate.Underflow))
}

/// Result type mismatch: a function declared `-> i32` whose body leaves an i64 (spec:
/// the body's result types must match the function type).
pub fn reject_result_mismatch_test() {
  validated(resultmismatch_wasm)
  |> should.equal(Error(validate.TypeMismatch))
}

/// Operand type mismatch: `i64.add` applied to i32 operands (spec: numeric typing
/// rule — operands must be the op's width).
pub fn reject_operand_mismatch_test() {
  validated(operandmismatch_wasm)
  |> should.equal(Error(validate.TypeMismatch))
}

/// Branch to an out-of-range label: `br 5` with only the function frame in scope
/// (spec: the branch label must reference an enclosing control frame).
pub fn reject_bad_label_test() {
  validated(badlabel_wasm)
  |> should.equal(Error(validate.UnknownLabel(5)))
}

/// Out-of-range local: `local.get 9` in a function with no locals (spec: the local
/// index must be in range).
pub fn reject_bad_local_test() {
  validated(badlocal_wasm)
  |> should.equal(Error(validate.UnknownLocal(9)))
}

/// `if`/`else` arms with different result types (then i32, else i64) — rejected
/// because the else arm does not produce the block's result type (spec: both arms of
/// an `if` share the blocktype results).
pub fn reject_if_else_mismatch_test() {
  validated(ifelsemismatch_wasm)
  |> should.equal(Error(validate.TypeMismatch))
}

/// Else-less `if` whose params differ from results (`if (result i32)` with no else):
/// only valid when params==results (spec: else-less `if`).
pub fn reject_elseless_unbalanced_test() {
  validated(elseless_wasm)
  |> should.equal(Error(validate.IfElseMismatch))
}

/// Call signature mismatch: `call` to a function expecting i64 with an i32 on the
/// stack (spec: a `call`'s operands must match the callee's parameter types).
pub fn reject_call_signature_test() {
  validated(callsig_wasm)
  |> should.equal(Error(validate.TypeMismatch))
}

/// Call to an out-of-range funcidx: `call 7` in a single-function module (spec: the
/// funcidx must be in range).
pub fn reject_bad_func_test() {
  validated(badfunc_wasm)
  |> should.equal(Error(validate.UnknownFunc(7)))
}

// ═════════════════════════ Phase-2 (unit 08) acceptance ═════════════════════════
// Spec `valid/instructions` + `valid/modules`: well-typed modules that use memory,
// globals, tables, floats, the conversion block, and `select` must be ACCEPTED, and
// the `TypedModule` must carry the typing facts lowering needs. Fixtures are real
// `wat2wasm` output (so they also exercise decode→validate).

/// `i32.store` then `i32.load` round-trip (spec: load pops an i32 address & pushes the
/// result; store pops value then address) — accepted with a declared memory.
pub fn accept_mem_roundtrip_test() {
  accept(mem_roundtrip_wasm)
}

/// `i32.load8_s` / `i32.load16_u` (the narrow-load width matrix) are accepted; each
/// pops an i32 address and pushes i32 (spec load typing).
pub fn accept_load_widths_test() {
  accept(load_widths_wasm)
}

/// `f64.add` (`[f64,f64]->[f64]`), `f32.sqrt` (`[f32]->[f32]`), `f32.eq`
/// (`[f32,f32]->[i32]`) — the float arith/unary/compare signatures (spec numeric
/// typing) are accepted.
pub fn accept_floats_test() {
  accept(floats_wasm)
}

/// A mutable global round-trips through `global.set` (valid only on a `var` global)
/// and `global.get` (spec `valid/instructions` global rules).
pub fn accept_mutable_global_test() {
  accept(mutable_global_wasm)
}

/// `call_indirect (type 0)` with a declared funcref table and an in-range typeidx
/// is accepted: it pops the i32 table index then the type's params and pushes its
/// results (spec `valid/instructions` call_indirect).
pub fn accept_call_indirect_test() {
  accept(call_indirect_wasm)
}

/// `i32.wrap_i64` (`[i64]->[i32]`), `f64.convert_i32_s` (`[i32]->[f64]`),
/// `i32.reinterpret_f32` (`[f32]->[i32]`) — representatives of the `0xA7–0xBF`
/// conversion block (width-only typing) are accepted.
pub fn accept_conversions_test() {
  accept(conversions_wasm)
}

/// `select` of two i32s with an i32 condition (`t t i32 -> t`) is accepted (spec
/// parametric `select`).
pub fn accept_select_i32_test() {
  accept(select_i32_wasm)
}

/// The `TypedModule` carries the value type of each global by index — here a single
/// mutable `i32` global → `global_types == [I32]` (the one fact lowering cannot
/// re-derive; deliverable §2).
pub fn typed_module_carries_global_types_test() {
  let assert Ok(tm) = validated(mutable_global_wasm)
  tm.global_types
  |> should.equal([ast.I32])
}

/// Active data + element segments with `i32.const` offsets and an in-range funcidx
/// are accepted (spec `valid/modules`: offsets are i32 const-exprs, elem funcidx in
/// range). Hand-built so we control both segments.
pub fn accept_active_segments_test() {
  module(
    types: [ft([], [])],
    tables: [tbl(1, None)],
    memories: [mem(1, None)],
    globals: [],
    funcs: [func_(0, [ast.End])],
    start: None,
    elements: [
      ast.ElementSegment(
        ast.ElemActive(0, [ast.I32Const(0)]),
        ast.FuncRef,
        ast.ElemFuncs([0]),
      ),
    ],
    data: [
      ast.DataSegment(ast.DataActive(0, [ast.I32Const(0)]), <<1, 2, 3>>),
    ],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

// ═════════════════════════ Phase-2 (unit 08) rejection ═════════════════════════
// Each rejects with the spec-cited `ValidateError`. Modules are hand-built so we can
// target the exact rule (out-of-range indices / multi-memory / bad limits / start
// signature) that `wat2wasm` would refuse to emit.

/// Alignment too large: `i32.load align=3` (`2^3 = 8 > 4` natural bytes) — spec memarg
/// rule "`2^align` must not be larger than `N/8`" (`align.wast`).
pub fn reject_bad_align_i32_load_test() {
  module(
    types: [ft([ast.I32], [ast.I32])],
    tables: [],
    memories: [mem(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.LocalGet(0),
        ast.I32Load(ast.MemArg(align: 3, offset: 0, mem: 0)),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.BadAlignment))
}

/// Alignment too large on a narrow load: `i32.load8_s align=1` (`2^1 = 2 > 1`) — spec
/// memarg rule (`align.wast`).
pub fn reject_bad_align_load8_test() {
  module(
    types: [ft([ast.I32], [ast.I32])],
    tables: [],
    memories: [mem(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.LocalGet(0),
        ast.I32Load8S(ast.MemArg(align: 1, offset: 0, mem: 0)),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.BadAlignment))
}

/// `global.set` on a `const` (immutable) global is a validation error (spec
/// `valid/instructions` global.set rule; `global.wast`).
pub fn reject_immutable_global_set_test() {
  module(
    types: [ft([], [])],
    tables: [],
    memories: [],
    globals: [ast.Global(ty: ast.I32, mutable: False, init: [ast.I32Const(0)])],
    funcs: [func_(0, [ast.I32Const(5), ast.GlobalSet(0), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.ImmutableGlobal(0)))
}

/// An extended-const global init (`i32.const 0 i32.const 1 i32.add`) is NOT a Phase-2
/// constant expression — MVP permits only a single `t.const` (extended-const proposal;
/// `global.wast` `$z3`).
pub fn reject_extended_const_init_test() {
  module(
    types: [],
    tables: [],
    memories: [],
    globals: [
      ast.Global(ty: ast.I32, mutable: False, init: [
        ast.I32Const(0),
        ast.I32Const(1),
        ast.I32Add,
      ]),
    ],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.NonConstantExpr))
}

/// A `global.get` init expr has no valid referent in Phase 2 (only immutable imported
/// globals qualify, and there are none) — rejected (`global.wast` `$z5`;
/// extended-const proposal).
pub fn reject_global_get_init_test() {
  module(
    types: [],
    tables: [],
    memories: [],
    globals: [
      ast.Global(ty: ast.I32, mutable: False, init: [ast.I32Const(1)]),
      ast.Global(ty: ast.I32, mutable: False, init: [ast.GlobalGet(0)]),
    ],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.NonConstantExpr))
}

/// `i64.store` fed an `f32` value: the store pops its value type (i64) but the operand
/// is f32 (spec store typing).
pub fn reject_store_value_mismatch_test() {
  module(
    types: [ft([ast.I32, ast.F32], [])],
    tables: [],
    memories: [mem(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.LocalGet(0),
        ast.LocalGet(1),
        ast.I64Store(ast.MemArg(align: 0, offset: 0, mem: 0)),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.TypeMismatch))
}

/// `i32.load` with an `f64` address: the load pops an i32 address but the operand is
/// f64 (spec load typing).
pub fn reject_load_address_mismatch_test() {
  module(
    types: [ft([ast.F64], [ast.I32])],
    tables: [],
    memories: [mem(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.LocalGet(0),
        ast.I32Load(ast.MemArg(align: 0, offset: 0, mem: 0)),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.TypeMismatch))
}

/// `select` of an i32 and an i64: the two values must share a type (spec parametric
/// `select`).
pub fn reject_select_type_mismatch_test() {
  module(
    types: [ft([ast.I32, ast.I64, ast.I32], [ast.I32])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        ast.LocalGet(0),
        ast.LocalGet(1),
        ast.LocalGet(2),
        ast.Select,
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.TypeMismatch))
}

/// A global init whose const is the wrong type (`f32.const` for an `i64` global) —
/// the const-expr type must equal the global's declared type (spec const-exprs).
pub fn reject_global_init_type_mismatch_test() {
  module(
    types: [],
    tables: [],
    memories: [],
    globals: [ast.Global(ty: ast.I64, mutable: False, init: [ast.F32Const(0)])],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.TypeMismatch))
}

/// `call_indirect` with a typeidx past the type section — the static typeidx must be
/// in range (spec `valid/instructions`; `call_indirect.wast`).
pub fn reject_call_indirect_bad_type_test() {
  module(
    types: [ft([], [])],
    tables: [tbl(1, None)],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.I32Const(0), ast.CallIndirect(5, 0), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownType(5)))
}

/// `call_indirect` in a module with no table — a table must exist (spec
/// `valid/instructions`).
pub fn reject_call_indirect_no_table_test() {
  module(
    types: [ft([], [])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.I32Const(0), ast.CallIndirect(0, 0), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownTable(0)))
}

/// An `i32.load` in a module with no memory — a memory must exist (spec
/// `valid/instructions`).
pub fn reject_load_no_memory_test() {
  module(
    types: [ft([ast.I32], [ast.I32])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        ast.LocalGet(0),
        ast.I32Load(ast.MemArg(align: 0, offset: 0, mem: 0)),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownMemory(0)))
}

/// `memory.size` in a module with no memory — a memory must exist (spec
/// `valid/instructions`).
pub fn reject_memory_size_no_memory_test() {
  module(
    types: [ft([], [ast.I32])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.MemorySize(0), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownMemory(0)))
}

/// `global.get` out of range — the globalidx must be in range (spec
/// `valid/instructions`).
pub fn reject_global_get_out_of_range_test() {
  module(
    types: [ft([], [ast.I32])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.GlobalGet(3), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownGlobal(3)))
}

/// `global.set` out of range — the globalidx must be in range (spec
/// `valid/instructions`).
pub fn reject_global_set_out_of_range_test() {
  module(
    types: [ft([], [])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.I32Const(0), ast.GlobalSet(2), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownGlobal(2)))
}

/// More than one memory is now VALID (H3 lifts the Phase-2 `≤1 memory` MVP cap — the
/// multi-memory proposal is merged into the core spec). Each memory's limits are still
/// validated (spec `valid/modules`).
pub fn accept_multiple_memories_test() {
  module(
    types: [],
    tables: [],
    memories: [mem(1, None), mem(1, None)],
    globals: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// More than one table is now VALID (H3 lifts the Phase-2 `≤1 table` MVP cap — the
/// reference-types proposal permits multiple tables). Each table's limits are still
/// validated (spec `valid/modules`).
pub fn accept_multiple_tables_test() {
  module(
    types: [],
    tables: [tbl(1, None), tbl(1, None)],
    memories: [],
    globals: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// A memory limit with `min > max` is invalid (spec `valid/types`: `min <= max`).
pub fn reject_memory_min_gt_max_test() {
  module(
    types: [],
    tables: [],
    memories: [mem(2, Some(1))],
    globals: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.BadLimits))
}

/// A memory whose `min` exceeds the `2^16`-page range is invalid (spec `valid/types`:
/// memory limit range is `2^16`).
pub fn reject_memory_over_range_test() {
  module(
    types: [],
    tables: [],
    memories: [mem(70_000, None)],
    globals: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.BadLimits))
}

/// A `start` function whose type is not `[] -> []` is invalid (spec `valid/modules`
/// start rule).
pub fn reject_bad_start_type_test() {
  module(
    types: [ft([ast.I32], [])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.End])],
    start: Some(0),
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.BadStartType))
}

/// An active element segment whose funcidx is out of the function index space is
/// invalid (spec `valid/modules` elements: every funcidx in range).
pub fn reject_element_func_out_of_range_test() {
  module(
    types: [ft([], [])],
    tables: [tbl(1, None)],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.End])],
    start: None,
    elements: [
      ast.ElementSegment(
        ast.ElemActive(0, [ast.I32Const(0)]),
        ast.FuncRef,
        ast.ElemFuncs([5]),
      ),
    ],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownFunc(5)))
}

// ═════════════════════════ Phase-5 (unit P5-04) acceptance ═════════════════════════
// Spec `valid/instructions` + `valid/modules` + the reference-types / bulk-memory /
// multi-memory / memory64 proposals. Well-typed modules over the completed surface
// must be ACCEPTED. Hand-built so we control reftypes / index spaces / segment modes.

/// `ref.null func` / `ref.null extern` each push their reftype; `ref.is_null` pops a
/// reference and pushes `i32` (spec `valid/instructions` §reference; `ref_null.wast`,
/// `ref_is_null.wast`). Body: `ref.null func; ref.is_null; ref.null extern; ref.is_null;
/// i32.add` → `i32`.
pub fn accept_ref_null_is_null_test() {
  module(
    types: [ft([], [ast.I32])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        ast.RefNull(ast.FuncRef),
        ast.RefIsNull,
        ast.RefNull(ast.ExternRef),
        ast.RefIsNull,
        ast.I32Add,
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// `ref.func x` of a **declared** function (declared via a function export → `C.refs`)
/// is valid and pushes `funcref` (spec `valid/instructions` ref.func; `ref_func.wast`).
pub fn accept_ref_func_declared_test() {
  ast.Module(
    imported_func_count: 0,
    types: [ft([], [ast.FuncRef])],
    imports: [],
    tables: [],
    memories: [],
    globals: [],
    tags: [],
    funcs: [func_(0, [ast.RefFunc(0), ast.End])],
    start: None,
    elements: [],
    data: [],
    data_count: None,
    exports: [ast.Export("f", ast.ExportFunc, 0)],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// A `ref.func` declared by a **declarative** element segment is in `C.refs` even
/// though the segment materializes no table entry (spec: declarative segments exist
/// solely to add funcidxs to `C.refs`; `elem.wast`).
pub fn accept_ref_func_via_declarative_elem_test() {
  module(
    types: [ft([], [ast.FuncRef])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.RefFunc(0), ast.End])],
    start: None,
    elements: [
      ast.ElementSegment(ast.ElemDeclarative, ast.FuncRef, ast.ElemFuncs([0])),
    ],
    data: [],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// Typed `select (result funcref)` of two `funcref`s: annotation length 1, signature
/// `[t t i32] → [t]` (spec parametric typed-select; `select.wast`). Reference operands
/// are LEGAL for the typed form (unlike untyped `select`).
pub fn accept_select_t_funcref_test() {
  module(
    types: [ft([], [ast.FuncRef])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        ast.RefNull(ast.FuncRef),
        ast.RefNull(ast.FuncRef),
        ast.I32Const(0),
        ast.SelectT([ast.FuncRef]),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// `table.get`/`table.set` on a `funcref` table AND on an `externref` table, routed by
/// index — a module with TWO tables of DIFFERENT reftypes. `table.get x` pushes table
/// x's reftype; `table.set x` pops it (spec `valid/instructions` §table;
/// `table_get.wast`/`table_set.wast`).
pub fn accept_table_get_set_two_reftypes_test() {
  module(
    types: [ft([], [])],
    tables: [rtbl(ast.FuncRef, 1), rtbl(ast.ExternRef, 1)],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        // table 0 (funcref): get then set back
        ast.I32Const(0),
        ast.TableGet(0),
        ast.Drop,
        ast.I32Const(0),
        ast.RefNull(ast.FuncRef),
        ast.TableSet(0),
        // table 1 (externref): get then set back
        ast.I32Const(0),
        ast.TableGet(1),
        ast.Drop,
        ast.I32Const(0),
        ast.RefNull(ast.ExternRef),
        ast.TableSet(1),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// `table.size`/`table.grow`/`table.fill` with the correct init reftype (spec
/// `valid/instructions` §table; `table_grow.wast`/`table_fill.wast`/`table_size.wast`).
pub fn accept_table_size_grow_fill_test() {
  module(
    types: [ft([], [])],
    tables: [rtbl(ast.ExternRef, 1)],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        ast.TableSize(0),
        ast.Drop,
        // table.grow: [externref i32] -> [i32]
        ast.RefNull(ast.ExternRef),
        ast.I32Const(1),
        ast.TableGrow(0),
        ast.Drop,
        // table.fill: [i32 externref i32] -> []
        ast.I32Const(0),
        ast.RefNull(ast.ExternRef),
        ast.I32Const(1),
        ast.TableFill(0),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// `memory.init`/`data.drop`/`memory.copy`/`memory.fill` on a 32-bit memory with a
/// passive data segment (spec `valid/instructions` §memory; `bulk.wast`,
/// `memory_init/copy/fill.wast`). All address/count operands are `i32`.
pub fn accept_bulk_memory_32_test() {
  module(
    types: [ft([], [])],
    tables: [],
    memories: [mem(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        // memory.init d=0 m=0 : [i32 i32 i32] -> []
        ast.I32Const(0),
        ast.I32Const(0),
        ast.I32Const(0),
        ast.MemoryInit(0, 0),
        ast.DataDrop(0),
        // memory.copy : [i32 i32 i32] -> []
        ast.I32Const(0),
        ast.I32Const(0),
        ast.I32Const(0),
        ast.MemoryCopy(0, 0),
        // memory.fill : [i32 i32 i32] -> []
        ast.I32Const(0),
        ast.I32Const(0),
        ast.I32Const(0),
        ast.MemoryFill(0),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [ast.DataSegment(ast.DataPassive, <<1, 2, 3>>)],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// `table.init`/`elem.drop`/`table.copy` with matching reftypes (spec
/// `valid/instructions` §table; `table_init.wast`/`table_copy.wast`). All operands
/// `i32`; the passive element segment's reftype matches the target table.
pub fn accept_bulk_table_matching_reftypes_test() {
  module(
    types: [ft([], [])],
    tables: [rtbl(ast.FuncRef, 1), rtbl(ast.FuncRef, 1)],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        // table.init e=0 t=0 : [i32 i32 i32] -> []
        ast.I32Const(0),
        ast.I32Const(0),
        ast.I32Const(0),
        ast.TableInit(0, 0),
        ast.ElemDrop(0),
        // table.copy dst=0 src=1 : [i32 i32 i32] -> []
        ast.I32Const(0),
        ast.I32Const(0),
        ast.I32Const(0),
        ast.TableCopy(0, 1),
        ast.End,
      ]),
    ],
    start: None,
    elements: [
      ast.ElementSegment(ast.ElemPassive, ast.FuncRef, ast.ElemFuncs([])),
    ],
    data: [],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// A module with **two memories** uses `memidx 1` on a load (spec/multi-memory
/// proposal; `memory.wast`). The single-memory case is byte-identical (H7); routing
/// by index is what multi-memory adds.
pub fn accept_multi_memory_memidx1_test() {
  module(
    types: [ft([], [])],
    tables: [],
    memories: [mem(1, None), mem(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.I32Const(0),
        ast.I32Load(ast.MemArg(align: 2, offset: 0, mem: 1)),
        ast.Drop,
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// A **memory64** module: `i64.load`, `memory.size`/`memory.grow` all use `i64`
/// addresses (spec/memory64 proposal). Validate ACCEPTS a valid memory64 module even
/// though its runtime is deferred (R12).
pub fn accept_memory64_i64_addressing_test() {
  module(
    types: [ft([], [])],
    tables: [],
    memories: [mem64(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        // i64.load : address is i64 on a 64-bit memory
        ast.I64Const(0),
        ast.I64Load(ast.MemArg(align: 3, offset: 0, mem: 0)),
        ast.Drop,
        // memory.size : [] -> [i64]
        ast.MemorySize(0),
        ast.Drop,
        // memory.grow : [i64] -> [i64]
        ast.I64Const(1),
        ast.MemoryGrow(0),
        ast.Drop,
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// A `memory.copy` between a 64-bit (dst) and a 32-bit (src) memory: the count is typed
/// as the **minimum** index type (`i32`), dst address `i64`, src address `i32`
/// (spec/memory64 copy rule). Operand order bottom→top: dest(i64), src(i32), count(i32).
pub fn accept_memory64_copy_min_index_type_test() {
  module(
    types: [ft([], [])],
    tables: [],
    memories: [mem64(1, None), mem(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.I64Const(0),
        ast.I32Const(0),
        ast.I32Const(0),
        ast.MemoryCopy(0, 1),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// A 64-bit memory limit of exactly `2^48` pages is in range (spec/memory64 limit
/// range is `2^48` pages = `2^64` bytes ÷ 64 KiB).
pub fn accept_memory64_limit_at_max_test() {
  module(
    types: [],
    tables: [],
    memories: [mem64(281_474_976_710_656, None)],
    globals: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// A passive element segment and a passive data segment type-check (only their
/// reftype / const-init are checked; they carry no table/memory/offset — spec
/// `valid/modules`).
pub fn accept_passive_segments_test() {
  module(
    types: [ft([], [])],
    tables: [rtbl(ast.FuncRef, 1)],
    memories: [mem(1, None)],
    globals: [],
    funcs: [func_(0, [ast.End])],
    start: None,
    elements: [
      ast.ElementSegment(
        ast.ElemPassive,
        ast.ExternRef,
        ast.ElemExprs([[ast.RefNull(ast.ExternRef)]]),
      ),
    ],
    data: [ast.DataSegment(ast.DataPassive, <<9>>)],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

/// A module importing a global/table/memory validates; the index spaces resolve
/// imports-first, and a `global.get` of an **imported immutable** global is a legal
/// constant expression in a later global's init (spec `valid/modules`/const-exprs;
/// `imports.wast`, `global.wast`). The `TypedModule` carries the imports-first counts.
pub fn accept_non_function_imports_test() {
  let assert Ok(tm) =
    ast.Module(
      imported_func_count: 0,
      types: [],
      imports: [
        ast.Import("env", "g", ast.ImportGlobal(ast.I32, False)),
        ast.Import("env", "t", ast.ImportTable(rtbl(ast.FuncRef, 1))),
        ast.Import("env", "m", ast.ImportMemory(mem(1, None))),
      ],
      tables: [],
      memories: [],
      // a defined global whose init reads the imported immutable global 0
      globals: [
        ast.Global(ty: ast.I32, mutable: False, init: [ast.GlobalGet(0)]),
      ],
      tags: [],
      funcs: [],
      start: None,
      elements: [],
      data: [],
      data_count: None,
      exports: [],
    )
    |> validate.validate()
  tm.imported_global_count
  |> should.equal(1)
}

// ── TypedModule facts lowering consumes ──

/// The `TypedModule` carries the reftype of each table by tableidx and each memory's
/// address width — the facts lowering (P5-05) cannot cheaply re-derive (deliverable §2).
pub fn typed_module_carries_table_and_mem_facts_test() {
  let assert Ok(tm) =
    module(
      types: [],
      tables: [rtbl(ast.FuncRef, 1), rtbl(ast.ExternRef, 1)],
      memories: [mem(1, None), mem64(1, None)],
      globals: [],
      funcs: [],
      start: None,
      elements: [],
      data: [],
    )
    |> validate.validate()
  tm.table_types
  |> should.equal([ast.FuncRef, ast.ExternRef])
  tm.memory_idx_types
  |> should.equal([ast.Idx32, ast.Idx64])
}

/// `C.refs` collects funcidxs declared by function exports and element segments (spec
/// appendix `funcidx(module)`); `start` does NOT join. Here func 0 is exported → `refs`
/// contains 0.
pub fn typed_module_refs_from_export_test() {
  let assert Ok(tm) =
    ast.Module(
      imported_func_count: 0,
      types: [ft([], [])],
      imports: [],
      tables: [],
      memories: [],
      globals: [],
      tags: [],
      funcs: [func_(0, [ast.End])],
      start: None,
      elements: [],
      data: [],
      data_count: None,
      exports: [ast.Export("f", ast.ExportFunc, 0)],
    )
    |> validate.validate()
  set.contains(tm.refs, 0)
  |> should.equal(True)
}

/// Conformance-neutral (H7): a Phase-1 module (no tables/memories/segments/imports)
/// validates with all the new `TypedModule` fields empty/zero — a Phase-4 module is
/// byte-identical.
pub fn typed_module_phase4_neutral_test() {
  let assert Ok(tm) = validated(add_wasm)
  tm.imported_global_count
  |> should.equal(0)
  tm.imported_table_count
  |> should.equal(0)
  tm.imported_memory_count
  |> should.equal(0)
  tm.table_types
  |> should.equal([])
  tm.memory_idx_types
  |> should.equal([])
  tm.elem_types
  |> should.equal([])
}

// ═════════════════════════ Phase-5 (unit P5-04) rejection ═════════════════════════
// Each rejects with the spec-cited `ValidateError` (never accepted, never a panic).

/// `ref.func x` where `x` is a valid funcidx but NOT in `C.refs` (not exported, not in
/// any segment or global) → `UndeclaredFunctionRef` (spec ref.func rule; `ref_func.wast`
/// `assert_invalid`).
pub fn reject_ref_func_undeclared_test() {
  module(
    types: [ft([], [ast.FuncRef])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.RefFunc(0), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UndeclaredFunctionRef(0)))
}

/// `ref.func x` past the funcidx space → `UnknownFunc` (spec ref.func rule).
pub fn reject_ref_func_out_of_range_test() {
  module(
    types: [ft([], [ast.FuncRef])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.RefFunc(7), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownFunc(7)))
}

/// `ref.is_null` on an `i32` operand → `TypeMismatch` (spec: it accepts only a
/// reference type; `ref_is_null.wast`).
pub fn reject_ref_is_null_on_i32_test() {
  module(
    types: [ft([], [ast.I32])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.I32Const(0), ast.RefIsNull, ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.TypeMismatch))
}

/// Untyped `select` (0x1B) of two `funcref`s → `BadSelectType` (spec: untyped select is
/// number-typed only; `select.wast` `assert_invalid`).
pub fn reject_untyped_select_of_refs_test() {
  module(
    types: [ft([], [ast.FuncRef])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        ast.RefNull(ast.FuncRef),
        ast.RefNull(ast.FuncRef),
        ast.I32Const(0),
        ast.Select,
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.BadSelectType))
}

/// Typed `select t` whose annotation vector is not length 1 → `BadSelectType` (spec:
/// the current core spec fixes the annotation at length 1; `select.wast`).
pub fn reject_select_t_bad_arity_test() {
  module(
    types: [ft([], [ast.I32])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        ast.I32Const(1),
        ast.I32Const(2),
        ast.I32Const(0),
        ast.SelectT([ast.I32, ast.I32]),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.BadSelectType))
}

/// `table.set` fed the WRONG reftype (an `externref` into a `funcref` table) — an
/// operand-stack mismatch → `TypeMismatch` (spec `valid/instructions` table.set).
pub fn reject_table_set_wrong_reftype_test() {
  module(
    types: [ft([], [])],
    tables: [rtbl(ast.FuncRef, 1)],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        ast.I32Const(0),
        ast.RefNull(ast.ExternRef),
        ast.TableSet(0),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.TypeMismatch))
}

/// `table.get` past the table space → `UnknownTable(tableidx)` with the REAL index
/// (spec `valid/instructions` table.get).
pub fn reject_table_get_out_of_range_test() {
  module(
    types: [ft([], [])],
    tables: [rtbl(ast.FuncRef, 1)],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.I32Const(0), ast.TableGet(3), ast.Drop, ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownTable(3)))
}

/// `call_indirect` through an `externref` table → `RefTypeMismatch` (an externref
/// table cannot back an indirect call; spec `valid/instructions` call_indirect).
pub fn reject_call_indirect_externref_table_test() {
  module(
    types: [ft([], [])],
    tables: [rtbl(ast.ExternRef, 1)],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.I32Const(0), ast.CallIndirect(0, 0), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.RefTypeMismatch))
}

/// `memory.init` with a `dataidx` past the data segments → `UnknownData` (spec
/// `valid/instructions`; `bulk.wast`). The anti-swap test below confirms the `data`
/// field is checked against the DATA space, not the memory space (R3).
pub fn reject_memory_init_bad_data_test() {
  module(
    types: [ft([], [])],
    tables: [],
    memories: [mem(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.I32Const(0),
        ast.I32Const(0),
        ast.I32Const(0),
        ast.MemoryInit(5, 0),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownData(5)))
}

/// R3 anti-swap: `MemoryInit(data: 1, mem: 0)` with **1 data segment** and **1 memory**
/// must be rejected as `UnknownData(1)` — the `data` field (1) is bounds-checked
/// against the DATA space (size 1 → out of range), NOT the memory space. A field swap
/// would instead reject `mem: 1` as `UnknownMemory`, so this pins the wire order.
pub fn reject_memory_init_immediate_order_test() {
  module(
    types: [ft([], [])],
    tables: [],
    memories: [mem(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.I32Const(0),
        ast.I32Const(0),
        ast.I32Const(0),
        ast.MemoryInit(1, 0),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [ast.DataSegment(ast.DataPassive, <<0>>)],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownData(1)))
}

/// R3 anti-swap for `table.init`: `TableInit(elem: 1, table: 0)` with **1 element
/// segment** and **2 tables** must reject `UnknownElem(1)` — the `elem` field is checked
/// against the ELEMENT space (size 1 → out of range), NOT the table space (size 2, where
/// index 1 would be valid). A swap would have accepted it.
pub fn reject_table_init_immediate_order_test() {
  module(
    types: [ft([], [])],
    tables: [rtbl(ast.FuncRef, 1), rtbl(ast.FuncRef, 1)],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        ast.I32Const(0),
        ast.I32Const(0),
        ast.I32Const(0),
        ast.TableInit(1, 0),
        ast.End,
      ]),
    ],
    start: None,
    elements: [
      ast.ElementSegment(ast.ElemPassive, ast.FuncRef, ast.ElemFuncs([])),
    ],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownElem(1)))
}

/// `table.init` across mismatched reftypes (an `externref` segment into a `funcref`
/// table) → `RefTypeMismatch` (spec `valid/instructions` table.init; `table_init.wast`).
pub fn reject_table_init_reftype_mismatch_test() {
  module(
    types: [ft([], [])],
    tables: [rtbl(ast.FuncRef, 1)],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        ast.I32Const(0),
        ast.I32Const(0),
        ast.I32Const(0),
        ast.TableInit(0, 0),
        ast.End,
      ]),
    ],
    start: None,
    elements: [
      ast.ElementSegment(
        ast.ElemPassive,
        ast.ExternRef,
        ast.ElemExprs([[ast.RefNull(ast.ExternRef)]]),
      ),
    ],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.RefTypeMismatch))
}

/// `table.copy` across mismatched reftypes (`funcref` dst, `externref` src) →
/// `RefTypeMismatch` (spec `valid/instructions` table.copy; `table_copy.wast`).
pub fn reject_table_copy_reftype_mismatch_test() {
  module(
    types: [ft([], [])],
    tables: [rtbl(ast.FuncRef, 1), rtbl(ast.ExternRef, 1)],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        ast.I32Const(0),
        ast.I32Const(0),
        ast.I32Const(0),
        ast.TableCopy(0, 1),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.RefTypeMismatch))
}

/// A load with a `memidx` past the memories → `UnknownMemory(memidx)` with the real
/// index (spec/multi-memory; `memory.wast`).
pub fn reject_load_bad_memidx_test() {
  module(
    types: [ft([], [])],
    tables: [],
    memories: [mem(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.I32Const(0),
        ast.I32Load(ast.MemArg(align: 2, offset: 0, mem: 1)),
        ast.Drop,
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownMemory(1)))
}

/// A memory64 `i32.load` address on a 64-bit memory (which wants `i64`) → `TypeMismatch`
/// (spec/memory64 address typing).
pub fn reject_memory64_i32_address_test() {
  module(
    types: [ft([], [ast.I64])],
    tables: [],
    memories: [mem64(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.I32Const(0),
        ast.I64Load(ast.MemArg(align: 3, offset: 0, mem: 0)),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.TypeMismatch))
}

/// A 64-bit memory limit above `2^48` pages → `BadLimits` (spec/memory64 limit range).
pub fn reject_memory64_over_range_test() {
  module(
    types: [],
    tables: [],
    memories: [mem64(281_474_976_710_657, None)],
    globals: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.BadLimits))
}

/// An active element segment whose reftype ≠ its target table's → `RefTypeMismatch`
/// (spec `valid/modules` elements; `elem.wast`).
pub fn reject_active_elem_reftype_mismatch_test() {
  module(
    types: [ft([], [])],
    tables: [rtbl(ast.FuncRef, 1)],
    memories: [],
    globals: [],
    funcs: [],
    start: None,
    elements: [
      ast.ElementSegment(
        ast.ElemActive(0, [ast.I32Const(0)]),
        ast.ExternRef,
        ast.ElemExprs([[ast.RefNull(ast.ExternRef)]]),
      ),
    ],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.RefTypeMismatch))
}

/// A `table.init`/`elem.drop` with an `elemidx` past the element segments →
/// `UnknownElem` (spec `valid/instructions`).
pub fn reject_elem_drop_out_of_range_test() {
  module(
    types: [ft([], [])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.ElemDrop(2), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownElem(2)))
}

/// A `global.get` of a defined/mutable global in a global init is NOT constant →
/// `NonConstantExpr` (spec constant expressions). Here the imported global 0 is
/// **mutable**, so referencing it is not a constant expression.
pub fn reject_const_global_get_mutable_import_test() {
  ast.Module(
    imported_func_count: 0,
    types: [],
    imports: [ast.Import("env", "g", ast.ImportGlobal(ast.I32, True))],
    tables: [],
    memories: [],
    globals: [ast.Global(ty: ast.I32, mutable: False, init: [ast.GlobalGet(0)])],
    tags: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
    data_count: None,
    exports: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.NonConstantExpr))
}

/// Duplicate export names are forbidden (spec `valid/modules`) → the chosen
/// `UnknownImportKind("duplicate export")` rejection.
pub fn reject_duplicate_export_test() {
  ast.Module(
    imported_func_count: 0,
    types: [ft([], [])],
    imports: [],
    tables: [],
    memories: [],
    globals: [],
    tags: [],
    funcs: [func_(0, [ast.End])],
    start: None,
    elements: [],
    data: [],
    data_count: None,
    exports: [
      ast.Export("dup", ast.ExportFunc, 0),
      ast.Export("dup", ast.ExportFunc, 0),
    ],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownImportKind("duplicate export")))
}

/// An export whose index is out of range of the space its kind selects → the matching
/// `Unknown*` (spec `valid/modules` exports). Here a memory export past the memories.
pub fn reject_export_out_of_range_test() {
  ast.Module(
    imported_func_count: 0,
    types: [],
    imports: [],
    tables: [],
    memories: [],
    globals: [],
    tags: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
    data_count: None,
    exports: [ast.Export("m", ast.ExportMemory, 0)],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownMemory(0)))
}

// ═════════════════════════ Phase-6 (unit P6-04) SIMD typing ═════════════════════════
// Spec: <https://webassembly.github.io/spec/core/valid/instructions.html#vector-instructions>.
// Modules are hand-built (decode of SIMD is P6-03's; here we exercise the *typing rule*
// directly). `v128` flows through the abstract stack as an ordinary value type; the
// SIMD-specific rules under test are the per-op signatures (comparisons → v128 MASK),
// the static lane-immediate bounds (`BadLaneIndex`), and the v128 memory family's memarg
// alignment (`BadAlignment`) / offset (`OffsetOutOfRange`) / address-width (memory64)
// checks. SIMD lane ops never trap (I3) — every check here is a static validation rule.

/// Sixteen opaque bytes for a `v128.const` immediate (validate never inspects lanes —
/// D5). Any 16-byte value serves the typing tests.
fn v128b() -> BitArray {
  <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
}

/// A single-function module with one 32-bit memory (index 0): type `ty`, body `body`.
fn simd_mod(ty: ast.FuncType, body: List(ast.Instr)) -> ast.Module {
  module(
    types: [ty],
    tables: [],
    memories: [mem(1, None)],
    globals: [],
    funcs: [func_(0, body)],
    start: None,
    elements: [],
    data: [],
  )
}

/// Assert a hand-built module validates (well-typed).
fn accept_mod(m: ast.Module) {
  validate.validate(m)
  |> is_ok()
  |> should.equal(True)
}

/// Assert a hand-built module is rejected with exactly `err`.
fn reject_mod(m: ast.Module, err: validate.ValidateError) {
  validate.validate(m)
  |> should.equal(Error(err))
}

// ── acceptance: v128 as a value type + const ──

/// `v128.const` has type `[] → [v128]` (spec `t.const`; `simd_const.wast`).
pub fn accept_v128_const_test() {
  accept_mod(simd_mod(ft([], [ast.V128]), [ast.V128Const(v128b()), ast.End]))
}

/// A `v128` global initialized by `v128.const` is valid (`v128.const` is a constant
/// instruction — spec constant expressions; `simd_const.wast`).
pub fn accept_v128_global_init_test() {
  module(
    types: [],
    tables: [],
    memories: [],
    globals: [
      ast.Global(ty: ast.V128, mutable: False, init: [
        ast.V128Const(v128b()),
      ]),
    ],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> accept_mod()
}

/// `v128` flows through params, results, and declared locals like any value type (spec
/// value types — §C.1/§C.2): `(func (param v128) (local v128) (result v128) local.get 1)`.
pub fn accept_v128_params_locals_test() {
  module(
    types: [ft([ast.V128], [ast.V128])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [
      ast.Func(type_idx: 0, locals: [ast.V128], body: [
        ast.LocalGet(1),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> accept_mod()
}

// ── acceptance: one op per signature class (spec vector-instruction signatures) ──

/// `i32x4.add : [v128 v128] → [v128]` (vector binary; `simd_i32x4_arith.wast`).
pub fn accept_i32x4_add_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.V128Const(v128b()),
      ast.V128Const(v128b()),
      ast.Simd(ast.SAdd(ast.I32x4)),
      ast.End,
    ]),
  )
}

/// `f64x2.sqrt : [v128] → [v128]` (vector unary; `simd_f64x2.wast`).
pub fn accept_f64x2_sqrt_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.V128Const(v128b()),
      ast.Simd(ast.FSqrt(ast.F64x2)),
      ast.End,
    ]),
  )
}

/// `i16x8.shl : [v128 i32] → [v128]` — the shift count is an `i32`, not a v128 (spec
/// `vshiftop`; `simd_bit_shift.wast`).
pub fn accept_i16x8_shl_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.V128Const(v128b()),
      ast.I32Const(3),
      ast.Simd(ast.SShl(ast.I16x8)),
      ast.End,
    ]),
  )
}

/// `v128.any_true : [v128] → [i32]` (vector test; `simd_boolean.wast`).
pub fn accept_v128_any_true_test() {
  accept_mod(
    simd_mod(ft([], [ast.I32]), [
      ast.V128Const(v128b()),
      ast.Simd(ast.VAnyTrue),
      ast.End,
    ]),
  )
}

/// `i8x16.bitmask : [v128] → [i32]` (bitmask; `simd_boolean.wast`).
pub fn accept_i8x16_bitmask_test() {
  accept_mod(
    simd_mod(ft([], [ast.I32]), [
      ast.V128Const(v128b()),
      ast.Simd(ast.SBitmask(ast.I8x16)),
      ast.End,
    ]),
  )
}

/// `v128.bitselect : [v128 v128 v128] → [v128]` (vector ternary; `simd_bitwise.wast`).
pub fn accept_v128_bitselect_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.V128Const(v128b()),
      ast.V128Const(v128b()),
      ast.V128Const(v128b()),
      ast.Simd(ast.VBitselect),
      ast.End,
    ]),
  )
}

/// `i32x4.splat : [i32] → [v128]` (spec `shape.splat`; `simd_splat.wast`).
pub fn accept_i32x4_splat_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.I32Const(0),
      ast.Simd(ast.SSplat(ast.I32x4)),
      ast.End,
    ]),
  )
}

/// `i64x2.splat : [i64] → [v128]` — a 64-bit lane splats from an `i64` (`simd_splat.wast`).
pub fn accept_i64x2_splat_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.I64Const(0),
      ast.Simd(ast.SSplat(ast.I64x2)),
      ast.End,
    ]),
  )
}

/// `f32x4.splat : [f32] → [v128]` — a float lane splats from an `f32` (`simd_splat.wast`).
pub fn accept_f32x4_splat_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.F32Const(0),
      ast.Simd(ast.SSplat(ast.F32x4)),
      ast.End,
    ]),
  )
}

/// A comparison yields a `v128` lane MASK, not `i32`: `i8x16.eq : [v128 v128] → [v128]`
/// (spec `vrelop`; `simd_i8x16_cmp.wast`). Accepting it with a `v128` result pins the
/// mask typing; the companion reject test (`reject_cmp_not_i32_test`) proves it is NOT
/// `i32`.
pub fn accept_i8x16_eq_mask_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.V128Const(v128b()),
      ast.V128Const(v128b()),
      ast.Simd(ast.SEq(ast.I8x16)),
      ast.End,
    ]),
  )
}

// ── acceptance: lane-access at a valid lane (spec lane rule `lane < dim`) ──

/// `i8x16.extract_lane_s 15 : [v128] → [i32]`, lane 15 < 16 (`simd_lane.wast`).
pub fn accept_extract_lane_s_valid_test() {
  accept_mod(
    simd_mod(ft([], [ast.I32]), [
      ast.V128Const(v128b()),
      ast.Simd(ast.SExtractLaneS(ast.I8x16, 15)),
      ast.End,
    ]),
  )
}

/// `i64x2.extract_lane 1 : [v128] → [i64]`, lane 1 < 2 (`simd_lane.wast`).
pub fn accept_extract_lane_i64_valid_test() {
  accept_mod(
    simd_mod(ft([], [ast.I64]), [
      ast.V128Const(v128b()),
      ast.Simd(ast.SExtractLane(ast.I64x2, 1)),
      ast.End,
    ]),
  )
}

/// `f32x4.replace_lane 3 : [v128 f32] → [v128]`, lane 3 < 4, consuming an `f32`
/// (`simd_lane.wast`).
pub fn accept_replace_lane_f32_valid_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.V128Const(v128b()),
      ast.F32Const(0),
      ast.Simd(ast.SReplaceLane(ast.F32x4, 3)),
      ast.End,
    ]),
  )
}

/// `i8x16.shuffle` with 16 indices all `< 32` is valid (spec `i8x16.shuffle`;
/// `simd_lane.wast`). `[v128 v128] → [v128]`.
pub fn accept_shuffle_valid_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.V128Const(v128b()),
      ast.V128Const(v128b()),
      ast.I8x16Shuffle([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 31]),
      ast.End,
    ]),
  )
}

/// `i8x16.swizzle : [v128 v128] → [v128]` (dynamic indices; OOB→0 is runtime, not
/// validation — §D.6; `simd_lane.wast`).
pub fn accept_swizzle_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.V128Const(v128b()),
      ast.V128Const(v128b()),
      ast.Simd(ast.SSwizzle),
      ast.End,
    ]),
  )
}

// ── acceptance: the v128 memory family at a valid alignment (spec `2^align ≤ N/8`) ──

/// `v128.load align=4 : [i32] → [v128]` (128-bit access, `2^4 = 16` bytes; `simd_load.wast`).
pub fn accept_v128_load_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.I32Const(0),
      ast.SimdLoad(ast.LoadV128, ast.MemArg(align: 4, offset: 0, mem: 0)),
      ast.End,
    ]),
  )
}

/// `v128.load32_splat align=2 : [i32] → [v128]` (32-bit access; `simd_load_splat.wast`).
pub fn accept_v128_load32_splat_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.I32Const(0),
      ast.SimdLoad(ast.LoadSplat(32), ast.MemArg(align: 2, offset: 0, mem: 0)),
      ast.End,
    ]),
  )
}

/// `v128.load8x8_s align=3 : [i32] → [v128]` (8-byte access; `simd_load_extend.wast`).
pub fn accept_v128_load8x8_s_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.I32Const(0),
      ast.SimdLoad(
        ast.LoadExtend(8, True),
        ast.MemArg(align: 3, offset: 0, mem: 0),
      ),
      ast.End,
    ]),
  )
}

/// `v128.load64_zero align=3 : [i32] → [v128]` (64-bit access; `simd_load_zero.wast`).
pub fn accept_v128_load64_zero_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.I32Const(0),
      ast.SimdLoad(ast.LoadZero(64), ast.MemArg(align: 3, offset: 0, mem: 0)),
      ast.End,
    ]),
  )
}

/// `v128.store align=4 : [i32 v128] → []` (address deeper, value on top; `simd_store.wast`).
pub fn accept_v128_store_test() {
  accept_mod(
    simd_mod(ft([], []), [
      ast.I32Const(0),
      ast.V128Const(v128b()),
      ast.SimdStore(ast.MemArg(align: 4, offset: 0, mem: 0)),
      ast.End,
    ]),
  )
}

/// `v128.load32_lane align=2 lane=3 : [i32 v128] → [v128]`, lane 3 < 4
/// (`simd_load32_lane.wast`).
pub fn accept_v128_load32_lane_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.I32Const(0),
      ast.V128Const(v128b()),
      ast.SimdLoadLane(32, ast.MemArg(align: 2, offset: 0, mem: 0), 3),
      ast.End,
    ]),
  )
}

/// `v128.store8_lane align=0 lane=15 : [i32 v128] → []`, lane 15 < 16
/// (`simd_store8_lane.wast`).
pub fn accept_v128_store8_lane_test() {
  accept_mod(
    simd_mod(ft([], []), [
      ast.I32Const(0),
      ast.V128Const(v128b()),
      ast.SimdStoreLane(8, ast.MemArg(align: 0, offset: 0, mem: 0), 15),
      ast.End,
    ]),
  )
}

/// Untyped `select` of two `v128`s is valid — `v128` is a *vector* type, accepted by
/// untyped select (spec parametric rule: `t` is a number OR vector type; `simd_select.wast`).
pub fn accept_select_v128_test() {
  accept_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.V128Const(v128b()),
      ast.V128Const(v128b()),
      ast.I32Const(1),
      ast.Select,
      ast.End,
    ]),
  )
}

// ── acceptance: memory64 (v128 memory ops share the mem_addr_type seam) ──

/// `v128.load` on a **64-bit** memory pops an `i64` address (memory64 seam — §E/§F;
/// `memory64.wast`). The identical op on a 32-bit memory pops `i32` (accept_v128_load_test).
pub fn accept_v128_load_mem64_test() {
  module(
    types: [ft([], [ast.V128])],
    tables: [],
    memories: [mem64(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.I64Const(0),
        ast.SimdLoad(ast.LoadV128, ast.MemArg(align: 4, offset: 0, mem: 0)),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> accept_mod()
}

/// A 64-bit memory whose limit is exactly `2^48` pages validates (the spec/memory64
/// abstract limit range for an `i64` memory — §F; `memory64.wast`). The smaller *runtime*
/// cap (P6-08) is NOT a validation rejection.
pub fn accept_mem64_limit_max_test() {
  module(
    types: [],
    tables: [],
    memories: [mem64(281_474_976_710_656, None)],
    globals: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> accept_mod()
}

// ── acceptance: cross-module function-import typing (declared FuncType — §G) ──

/// A module importing `(func (param i32) (result i32))` and calling it type-checks the
/// `call` against the import's DECLARED signature (imports occupy the low funcidx range —
/// spec imports; `linking.wast`). The link-time *satisfaction* is P6-09's, not validate's.
pub fn accept_imported_func_call_test() {
  ast.Module(
    imported_func_count: 1,
    types: [ft([ast.I32], [ast.I32]), ft([], [])],
    imports: [ast.Import("env", "f", ast.ImportFunc(0))],
    tables: [],
    memories: [],
    globals: [],
    tags: [],
    funcs: [
      ast.Func(type_idx: 1, locals: [], body: [
        ast.I32Const(0),
        ast.Call(0),
        ast.Drop,
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
    data_count: None,
    exports: [],
  )
  |> accept_mod()
}

// ── rejection: comparison mask is NOT i32 ──

/// `i8x16.eq` yields a `v128` mask, so declaring the function `-> i32` and leaving the
/// mask leaves a `v128` where the result wants `i32` → `TypeMismatch`. Guards against the
/// classic mis-typing of a SIMD comparison to `i32` (spec `vrelop`; `simd_i8x16_cmp.wast`).
pub fn reject_cmp_not_i32_test() {
  reject_mod(
    simd_mod(ft([], [ast.I32]), [
      ast.V128Const(v128b()),
      ast.V128Const(v128b()),
      ast.Simd(ast.SEq(ast.I8x16)),
      ast.End,
    ]),
    validate.TypeMismatch,
  )
}

// ── rejection: BadLaneIndex (static lane immediate out of range) ──

/// `i8x16.extract_lane_s 16` — lane `16 ≥ dim = 16` (spec lane rule `x < dim`;
/// `simd_lane.wast`).
pub fn reject_extract_lane_oob_test() {
  reject_mod(
    simd_mod(ft([], [ast.I32]), [
      ast.V128Const(v128b()),
      ast.Simd(ast.SExtractLaneS(ast.I8x16, 16)),
      ast.End,
    ]),
    validate.BadLaneIndex(16),
  )
}

/// `i32x4.replace_lane 4` — lane `4 ≥ dim = 4` (`simd_lane.wast`).
pub fn reject_replace_lane_oob_test() {
  reject_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.V128Const(v128b()),
      ast.I32Const(0),
      ast.Simd(ast.SReplaceLane(ast.I32x4, 4)),
      ast.End,
    ]),
    validate.BadLaneIndex(4),
  )
}

/// `i64x2.extract_lane 2` — lane `2 ≥ dim = 2` (`simd_lane.wast`).
pub fn reject_extract_lane_i64_oob_test() {
  reject_mod(
    simd_mod(ft([], [ast.I64]), [
      ast.V128Const(v128b()),
      ast.Simd(ast.SExtractLane(ast.I64x2, 2)),
      ast.End,
    ]),
    validate.BadLaneIndex(2),
  )
}

/// `i8x16.shuffle` with an index `≥ 32` — the shuffle indices select bytes from the
/// 32-byte concatenation, so each must be `< 32` (spec `i8x16.shuffle`; `simd_lane.wast`).
pub fn reject_shuffle_oob_test() {
  reject_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.V128Const(v128b()),
      ast.V128Const(v128b()),
      ast.I8x16Shuffle([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 32]),
      ast.End,
    ]),
    validate.BadLaneIndex(32),
  )
}

/// `v128.load8_lane lane=16` — lane `16 ≥ 128/8 = 16` (spec vector memory lane rule
/// `lane < 128/N`; `simd_load8_lane.wast`).
pub fn reject_load_lane_oob_test() {
  reject_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.I32Const(0),
      ast.V128Const(v128b()),
      ast.SimdLoadLane(8, ast.MemArg(align: 0, offset: 0, mem: 0), 16),
      ast.End,
    ]),
    validate.BadLaneIndex(16),
  )
}

/// `v128.store64_lane lane=2` — lane `2 ≥ 128/64 = 2` (`simd_store64_lane.wast`).
pub fn reject_store_lane_oob_test() {
  reject_mod(
    simd_mod(ft([], []), [
      ast.I32Const(0),
      ast.V128Const(v128b()),
      ast.SimdStoreLane(64, ast.MemArg(align: 0, offset: 0, mem: 0), 2),
      ast.End,
    ]),
    validate.BadLaneIndex(2),
  )
}

// ── rejection: BadAlignment (memarg alignment > natural access width) ──

/// `v128.load align=5` — `2^5 = 32 > 16` bytes (spec memarg `2^align ≤ N/8`;
/// `simd_align.wast`).
pub fn reject_v128_load_overalign_test() {
  reject_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.I32Const(0),
      ast.SimdLoad(ast.LoadV128, ast.MemArg(align: 5, offset: 0, mem: 0)),
      ast.End,
    ]),
    validate.BadAlignment,
  )
}

/// `v128.load32_splat align=3` — `2^3 = 8 > 4` bytes for a 32-bit access
/// (`simd_align.wast`).
pub fn reject_load32_splat_overalign_test() {
  reject_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.I32Const(0),
      ast.SimdLoad(ast.LoadSplat(32), ast.MemArg(align: 3, offset: 0, mem: 0)),
      ast.End,
    ]),
    validate.BadAlignment,
  )
}

/// `v128.load8_lane align=1` — `2^1 = 2 > 1` byte for an 8-bit access (`simd_align.wast`).
pub fn reject_load8_lane_overalign_test() {
  reject_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.I32Const(0),
      ast.V128Const(v128b()),
      ast.SimdLoadLane(8, ast.MemArg(align: 1, offset: 0, mem: 0), 0),
      ast.End,
    ]),
    validate.BadAlignment,
  )
}

/// `v128.store align=5` — `2^5 = 32 > 16` bytes (`simd_align.wast`).
pub fn reject_v128_store_overalign_test() {
  reject_mod(
    simd_mod(ft([], []), [
      ast.I32Const(0),
      ast.V128Const(v128b()),
      ast.SimdStore(ast.MemArg(align: 5, offset: 0, mem: 0)),
      ast.End,
    ]),
    validate.BadAlignment,
  )
}

// ── rejection: TypeMismatch (wrong operand type) ──

/// `i32x4.add` fed non-`v128` operands (two `f32`s) → `TypeMismatch` (spec vector-binary
/// typing; `simd_i32x4_arith.wast`).
pub fn reject_add_wrong_operand_test() {
  reject_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.F32Const(0),
      ast.F32Const(0),
      ast.Simd(ast.SAdd(ast.I32x4)),
      ast.End,
    ]),
    validate.TypeMismatch,
  )
}

/// `i64x2.splat` fed an `i32` (wants `i64`) → `TypeMismatch` (spec `shape.splat`;
/// `simd_splat.wast`).
pub fn reject_splat_wrong_scalar_test() {
  reject_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.I32Const(0),
      ast.Simd(ast.SSplat(ast.I64x2)),
      ast.End,
    ]),
    validate.TypeMismatch,
  )
}

/// `i8x16.replace_lane` fed an `i64` (wants `i32`, the unpacked type) → `TypeMismatch`
/// (spec `shape.replace_lane`; `simd_lane.wast`).
pub fn reject_replace_lane_wrong_scalar_test() {
  reject_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.V128Const(v128b()),
      ast.I64Const(0),
      ast.Simd(ast.SReplaceLane(ast.I8x16, 0)),
      ast.End,
    ]),
    validate.TypeMismatch,
  )
}

/// `f32x4.replace_lane` fed an `i32` (wants `f32`) → `TypeMismatch` (`simd_lane.wast`).
pub fn reject_replace_lane_wrong_float_test() {
  reject_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.V128Const(v128b()),
      ast.I32Const(0),
      ast.Simd(ast.SReplaceLane(ast.F32x4, 0)),
      ast.End,
    ]),
    validate.TypeMismatch,
  )
}

/// `ref.is_null` on a `v128` → `TypeMismatch` — `v128` is NOT a reference type
/// (`ref.is_null` accepts only references; spec reference instructions — §C.4).
pub fn reject_ref_is_null_v128_test() {
  reject_mod(
    simd_mod(ft([], [ast.I32]), [
      ast.V128Const(v128b()),
      ast.RefIsNull,
      ast.End,
    ]),
    validate.TypeMismatch,
  )
}

/// `v128.store` whose value operand is an `i32`, not a `v128` → `TypeMismatch` (spec
/// vector store typing; `simd_store.wast`).
pub fn reject_store_wrong_value_test() {
  reject_mod(
    simd_mod(ft([], []), [
      ast.I32Const(0),
      ast.I32Const(0),
      ast.SimdStore(ast.MemArg(align: 4, offset: 0, mem: 0)),
      ast.End,
    ]),
    validate.TypeMismatch,
  )
}

/// A scalar `i32.load` on a **64-bit** memory has an `i32` address but wants `i64` →
/// `TypeMismatch` (memory64 address typing — §F; `memory64.wast`).
pub fn reject_scalar_load_mem64_wrong_addr_test() {
  module(
    types: [ft([], [ast.I32])],
    tables: [],
    memories: [mem64(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.I32Const(0),
        ast.I32Load(ast.MemArg(align: 2, offset: 0, mem: 0)),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> reject_mod(validate.TypeMismatch)
}

// ── rejection: memory / limit / const-expr ──

/// `v128.load` with a `memidx` past the module's memories → `UnknownMemory` (spec
/// `C.mems[memidx]`; `simd_memory-multi.wast`).
pub fn reject_v128_load_bad_memidx_test() {
  reject_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.I32Const(0),
      ast.SimdLoad(ast.LoadV128, ast.MemArg(align: 4, offset: 0, mem: 1)),
      ast.End,
    ]),
    validate.UnknownMemory(1),
  )
}

/// A v128 memory op with a static offset `≥ 2^32` on a 32-bit memory → `OffsetOutOfRange`
/// (spec memarg offset rule; `simd_address.wast`).
pub fn reject_v128_load_offset_oob_test() {
  reject_mod(
    simd_mod(ft([], [ast.V128]), [
      ast.I32Const(0),
      ast.SimdLoad(
        ast.LoadV128,
        ast.MemArg(align: 4, offset: 4_294_967_296, mem: 0),
      ),
      ast.End,
    ]),
    validate.OffsetOutOfRange,
  )
}

/// A 64-bit memory whose limit exceeds `2^48` pages (`2^48 + 1`) → `BadLimits` (spec/
/// memory64 limit range; `memory64.wast`).
pub fn reject_mem64_limit_over_test() {
  module(
    types: [],
    tables: [],
    memories: [mem64(281_474_976_710_657, None)],
    globals: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> reject_mod(validate.BadLimits)
}

/// A `v128` global initialized by a non-const SIMD op (`i32x4.add`) → `NonConstantExpr`
/// — only `v128.const` is a constant SIMD instruction (spec constant expressions — §C.4).
pub fn reject_v128_global_nonconst_test() {
  module(
    types: [],
    tables: [],
    memories: [],
    globals: [
      ast.Global(ty: ast.V128, mutable: False, init: [
        ast.V128Const(v128b()),
        ast.V128Const(v128b()),
        ast.Simd(ast.SAdd(ast.I32x4)),
      ]),
    ],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> reject_mod(validate.NonConstantExpr)
}

/// `True` if a `Result` is `Ok`, discarding both payloads (for acceptance asserts on
/// hand-built modules where the exact `TypedModule` is not under test).
fn is_ok(r: Result(a, b)) -> Bool {
  case r {
    Ok(_) -> True
    Error(_) -> False
  }
}

// ───────────────────────────── fixtures ─────────────────────────────
// Valid (wat2wasm) and invalid (wat2wasm --no-check) `.wasm` byte literals.

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

const elseless_valid_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x01,
  0x7f, 0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x0a, 0x01, 0x08, 0x00, 0x20, 0x00, 0x04, 0x40, 0x01, 0x0b, 0x0b,
>>

// () -> (i32, i32) block (multi-value typeidx blocktype).
const mv_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x00,
  0x02, 0x7f, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x06, 0x01, 0x02, 0x6d, 0x76,
  0x00, 0x00, 0x0a, 0x0b, 0x01, 0x09, 0x00, 0x02, 0x00, 0x41, 0x01, 0x41, 0x02,
  0x0b, 0x0b,
>>

// abs(i32)->i32 via `if (result i32) ... else ... end`.
const abs_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x61, 0x62,
  0x73, 0x00, 0x00, 0x0a, 0x14, 0x01, 0x12, 0x00, 0x20, 0x00, 0x41, 0x00, 0x48,
  0x04, 0x7f, 0x41, 0x00, 0x20, 0x00, 0x6b, 0x05, 0x20, 0x00, 0x0b, 0x0b,
>>

const poly_unreachable_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b,
>>

const poly_after_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x06, 0x01, 0x04, 0x00, 0x00, 0x6a, 0x0b,
>>

const underflow_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x05, 0x01, 0x03, 0x00, 0x6a, 0x0b,
>>

const resultmismatch_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x06, 0x01, 0x04, 0x00, 0x42, 0x01, 0x0b,
>>

const operandmismatch_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7f, 0x01, 0x7e, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00,
  0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x00, 0x7c, 0x0b,
>>

const badlabel_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a,
  0x06, 0x01, 0x04, 0x00, 0x0c, 0x05, 0x0b,
>>

const badlocal_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x06, 0x01, 0x04, 0x00, 0x20, 0x09, 0x0b,
>>

const ifelsemismatch_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x0e, 0x01, 0x0c, 0x00, 0x41, 0x01, 0x04, 0x7f, 0x41, 0x05, 0x05, 0x42,
  0x07, 0x0b, 0x0b,
>>

const elseless_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x0b, 0x01, 0x09, 0x00, 0x41, 0x01, 0x04, 0x7f, 0x41, 0x05, 0x0b, 0x0b,
>>

const callsig_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60, 0x01,
  0x7e, 0x00, 0x60, 0x00, 0x00, 0x03, 0x03, 0x02, 0x00, 0x01, 0x07, 0x05, 0x01,
  0x01, 0x67, 0x00, 0x01, 0x0a, 0x0b, 0x02, 0x02, 0x00, 0x0b, 0x06, 0x00, 0x41,
  0x01, 0x10, 0x00, 0x0b,
>>

const badfunc_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a,
  0x06, 0x01, 0x04, 0x00, 0x10, 0x07, 0x0b,
>>

// ── Phase-2 acceptance fixtures (valid `wat2wasm` output) ──

const mem_roundtrip_wasm: BitArray = <<
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  6,
  1,
  96,
  1,
  127,
  1,
  127,
  3,
  2,
  1,
  0,
  5,
  3,
  1,
  0,
  1,
  7,
  5,
  1,
  1,
  102,
  0,
  0,
  10,
  16,
  1,
  14,
  0,
  32,
  0,
  65,
  42,
  54,
  2,
  0,
  32,
  0,
  40,
  2,
  0,
  11,
>>

const load_widths_wasm: BitArray = <<
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  6,
  1,
  96,
  1,
  127,
  1,
  127,
  3,
  2,
  1,
  0,
  5,
  3,
  1,
  0,
  1,
  7,
  5,
  1,
  1,
  102,
  0,
  0,
  10,
  15,
  1,
  13,
  0,
  32,
  0,
  44,
  0,
  0,
  32,
  0,
  47,
  1,
  0,
  106,
  11,
>>

const floats_wasm: BitArray = <<
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  7,
  1,
  96,
  2,
  125,
  124,
  1,
  127,
  3,
  2,
  1,
  0,
  7,
  5,
  1,
  1,
  102,
  0,
  0,
  10,
  16,
  1,
  14,
  0,
  32,
  1,
  32,
  1,
  160,
  26,
  32,
  0,
  145,
  32,
  0,
  91,
  11,
>>

const mutable_global_wasm: BitArray = <<
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  5,
  1,
  96,
  0,
  1,
  127,
  3,
  2,
  1,
  0,
  6,
  6,
  1,
  127,
  1,
  65,
  7,
  11,
  7,
  5,
  1,
  1,
  102,
  0,
  0,
  10,
  11,
  1,
  9,
  0,
  65,
  227,
  0,
  36,
  0,
  35,
  0,
  11,
>>

const call_indirect_wasm: BitArray = <<
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  6,
  1,
  96,
  1,
  127,
  1,
  127,
  3,
  2,
  1,
  0,
  4,
  4,
  1,
  112,
  0,
  1,
  7,
  5,
  1,
  1,
  102,
  0,
  0,
  10,
  11,
  1,
  9,
  0,
  32,
  0,
  65,
  0,
  17,
  0,
  0,
  11,
>>

const conversions_wasm: BitArray = <<
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  8,
  1,
  96,
  3,
  126,
  127,
  125,
  1,
  127,
  3,
  2,
  1,
  0,
  7,
  5,
  1,
  1,
  102,
  0,
  0,
  10,
  15,
  1,
  13,
  0,
  32,
  1,
  183,
  26,
  32,
  2,
  188,
  26,
  32,
  0,
  167,
  11,
>>

const select_i32_wasm: BitArray = <<
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  8,
  1,
  96,
  3,
  127,
  127,
  127,
  1,
  127,
  3,
  2,
  1,
  0,
  7,
  5,
  1,
  1,
  102,
  0,
  0,
  10,
  11,
  1,
  9,
  0,
  32,
  0,
  32,
  1,
  32,
  2,
  27,
  11,
>>
