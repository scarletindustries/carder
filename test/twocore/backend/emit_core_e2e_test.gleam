//// Unit 08 — end-to-end: hand-written IR → `.core` → loaded `.beam` → RUN on the BEAM.
////
//// The headline deliverable (overview §3): a hand-written IR `Module` compiles and runs
//// on the BEAM with SPEC-CORRECT results, proving the backend spine
//// (`08 emit_core` → `03 core_printer` → `04 build_beam`, with `06 rt_num` / `09 rt_trap`/
//// `rt_host`/`rt_meter`/`rt_stdlib` linked) before the WASM frontend exists. Results are
//// asserted against the WebAssembly spec (<https://webassembly.github.io/spec/core/>):
//// two's-complement wrap, shift-count masking, the div/rem zero & signed-overflow traps,
//// the deny-all capability boundary, and the resolved `own` stdlib.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import gleam/string
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/ir
import twocore/pipeline
import twocore/runtime/instance
import twocore/runtime/link
import twocore/runtime/rt_meter

// Test-only FFI (see `test/twocore_emit_test_ffi.erl`): apply `M:F(Args)` and capture a
// trap / capability-denial as `Error(text)` instead of crashing the test process.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

// The SAME `catch_apply/3` FFI, re-typed for `Dynamic` arguments/results — used to drive the
// `instantiate/1(Imports)` ABI of an import-bearing module (the single argument is the whole
// positional `[Provided ...]` list). `erlang:apply` is untyped at runtime, so this is sound.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply_dyn(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

// Coerce any Gleam value to `Dynamic` (identity at runtime) — to hand the `List(Provided)`
// import list to `instantiate/1` as a single opaque argument.
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

// ───────────────────────────── plumbing ─────────────────────────────

/// Emit `module` to Core text, compile it, and load it into the test VM; return the
/// loaded module atom. `let assert` here is the test's success contract — a failure to
/// emit/compile/load is a genuine test failure, not an expected path.
fn load(module: ir.Module) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(module, instance.safe_default())
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

/// Build a numerics-on, memory-off module wrapping `functions`, exporting each by name.
fn module(name: String, functions: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "twocore@e2e@" <> name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: functions,
    exports: list.map(functions, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

// ───────────────────────────── add(i32,i32) + two's-complement wrap ─────────────────────────────

fn binop_fn(name: String, op: ir.NumOp, ty: ir.ValType) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("p0", ty), ir.Local("p1", ty)],
    result: [ty],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.Num(op, [ir.Var("p0"), ir.Var("p1")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// `add(7, 35) == 42`; and i32 addition wraps two's-complement through codegen
/// (`0x7FFFFFFF + 1 == 0x80000000`, the unsigned bit pattern `2147483648`) — WASM `i32.add`
/// is modulo 2^32.
pub fn add_and_wrap_e2e_test() {
  let mod = load(module("add", [binop_fn("add", ir.IAdd(ir.W32), ir.TI32)]))
  assert catch_apply(mod, atom.create("add"), [7, 35]) == Ok(42)
  assert catch_apply(mod, atom.create("add"), [2_147_483_647, 1])
    == Ok(2_147_483_648)
}

/// `i32.shl` masks the shift count modulo 32 (WASM shift-count masking): `1 << 32 == 1`
/// (count 32 → 0) and `1 << 33 == 2` (count 33 → 1) — proven THROUGH codegen.
pub fn shift_count_masking_e2e_test() {
  let mod = load(module("shl", [binop_fn("shl", ir.IShl(ir.W32), ir.TI32)]))
  assert catch_apply(mod, atom.create("shl"), [1, 32]) == Ok(1)
  assert catch_apply(mod, atom.create("shl"), [1, 33]) == Ok(2)
}

// ───────────────────────────── sum_to(n) — constant-space loop ─────────────────────────────

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

/// `sum_to(n) == n*(n+1)/2`, and it runs in CONSTANT SPACE: the loop lowers to a `letrec`
/// whose back-edge is a tail `apply` (asserted structurally in `emit_core_test`), so 100k
/// iterations complete without growing the stack. `sum_to(100000) == 5000050000`.
pub fn sum_to_constant_space_e2e_test() {
  let mod = load(module("loop", [sum_to_fn()]))
  assert catch_apply(mod, atom.create("sum_to"), [10]) == Ok(55)
  assert catch_apply(mod, atom.create("sum_to"), [100_000]) == Ok(5_000_050_000)
}

// ───────────────────────────── fib / fac — if + direct self-call + recursion ─────────────────────────────

fn fib_fn() -> ir.Function {
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

fn fac_fn() -> ir.Function {
  ir.Function(
    name: "fac",
    params: [ir.Local("p0", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Let(
      ["c"],
      ir.Num(ir.ILtU(ir.W64), [ir.Var("p0"), ir.ConstI64(2)]),
      ir.If(
        cond: ir.Var("c"),
        result: [ir.TI64],
        then_branch: ir.Return([ir.ConstI64(1)]),
        else_branch: ir.Let(
          ["n1"],
          ir.Num(ir.ISub(ir.W64), [ir.Var("p0"), ir.ConstI64(1)]),
          ir.Let(
            ["f1"],
            ir.CallDirect("fac", [ir.Var("n1")]),
            ir.Let(
              ["r"],
              ir.Num(ir.IMul(ir.W64), [ir.Var("p0"), ir.Var("f1")]),
              ir.Return([ir.Var("r")]),
            ),
          ),
        ),
      ),
    ),
  )
}

/// `fib`/`fac` (if + direct self-call + recursion) produce spec-correct values.
/// `fib(10) == 55`, `fib(20) == 6765`, `fac(5) == 120`, `fac(10) == 3628800`.
pub fn fib_fac_recursion_e2e_test() {
  let fmod = load(module("fib", [fib_fn()]))
  assert catch_apply(fmod, atom.create("fib"), [10]) == Ok(55)
  assert catch_apply(fmod, atom.create("fib"), [20]) == Ok(6765)
  let gmod = load(module("fac", [fac_fn()]))
  assert catch_apply(gmod, atom.create("fac"), [5]) == Ok(120)
  assert catch_apply(gmod, atom.create("fac"), [10]) == Ok(3_628_800)
}

// ───────────────────────────── div traps (zero & signed overflow) ─────────────────────────────

/// `div_u(x, 0)` TRAPS (divide by zero) and `div_s(INT_MIN, -1)` TRAPS (signed overflow),
/// surfaced via `rt_trap` as a catchable `{wasm_trap, Kind}` error — not a wrong value, not
/// a silent `badarith`. (i32 `INT_MIN` = `0x80000000` = 2147483648; `-1` = `0xFFFFFFFF` =
/// 4294967295 as unsigned bit patterns.)
pub fn div_traps_e2e_test() {
  let mod =
    load(
      module("divtrap", [
        binop_fn("divu", ir.IDivU(ir.W32), ir.TI32),
        binop_fn("divs", ir.IDivS(ir.W32), ir.TI32),
      ]),
    )

  let assert Error(zero) = catch_apply(mod, atom.create("divu"), [10, 0])
  assert string.contains(zero, "wasm_trap")
  assert string.contains(zero, "int_div_by_zero")

  let assert Error(over) =
    catch_apply(mod, atom.create("divs"), [2_147_483_648, 4_294_967_295])
  assert string.contains(over, "wasm_trap")
  assert string.contains(over, "int_overflow")

  // A non-trapping division returns the value (sanity that the ok-arm works).
  assert catch_apply(mod, atom.create("divu"), [20, 5]) == Ok(4)
}

// ───────────────────────────── CallHost — deny-all import vs resolved stdlib ─────────────────────────────

fn host_import_fn() -> ir.Function {
  ir.Function(
    name: "useimport",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.CallHost("env", "forbidden", [ir.Var("p0")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

fn gcd_fn() -> ir.Function {
  ir.Function(
    name: "mygcd",
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

/// A genuine host import is REJECTED end-to-end under the Safe deny-all host:
/// `{capability_denied, Cap, Name}` (fail-closed, D9). The capability boundary fires.
pub fn host_import_denied_e2e_test() {
  let mod = load(module("hostdeny", [host_import_fn()]))
  let assert Error(reason) = catch_apply(mod, atom.create("useimport"), [123])
  assert string.contains(reason, "capability_denied")
}

/// A resolved `own`-stdlib call (`("std","gcd")`) reaches `rt_stdlib:gcd/2` and returns the
/// spec gcd: `gcd(48, 36) == 12`, `gcd(1071, 462) == 21`.
pub fn stdlib_gcd_e2e_test() {
  let mod = load(module("stdgcd", [gcd_fn()]))
  assert catch_apply(mod, atom.create("mygcd"), [48, 36]) == Ok(12)
  assert catch_apply(mod, atom.create("mygcd"), [1071, 462]) == Ok(21)
}

// ──────────────── multi-value & zero-result function boundaries (REGRESSION) ────────────────

/// `swap2(a, b)` returns TWO values `<b, a>` (a multi-value result).
fn swap2_fn() -> ir.Function {
  ir.Function(
    name: "swap2",
    params: [ir.Local("p0", ir.TI64), ir.Local("p1", ir.TI64)],
    result: [ir.TI64, ir.TI64],
    locals: [],
    body: ir.Values([ir.Var("p1"), ir.Var("p0")]),
  )
}

/// `caller(x)` calls the multi-value `swap2(x, 7)`, binds its two results `<lo, hi>`, and
/// returns `lo - hi`.
fn use_swap2_fn() -> ir.Function {
  ir.Function(
    name: "caller",
    params: [ir.Local("p0", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Let(
      ["lo", "hi"],
      ir.CallDirect("swap2", [ir.Var("p0"), ir.ConstI64(7)]),
      ir.Let(
        ["d"],
        ir.Num(ir.ISub(ir.W64), [ir.Var("lo"), ir.Var("hi")]),
        ir.Return([ir.Var("d")]),
      ),
    ),
  )
}

/// REGRESSION: a function with MORE than one result (multi-value) compiles and its results
/// round-trip through a call in order. A BEAM function returns exactly one value, so a
/// multi-value result is packaged as a tuple at the boundary and destructured at the call
/// site (the `fac-ssa` shape that previously emitted `ArityMismatch` then failed to build
/// with "return count mismatch").
///
/// `swap2(x, 7) == <7, x>`, so `caller(x) == 7 - x`: `caller(2) == 5`; `caller(10) == 7-10
/// == -3`, the i64 two's-complement bit pattern `2^64 - 3`. The asymmetric subtraction
/// would expose a swapped destructure (it would compute `x - 7` instead).
pub fn multi_value_call_e2e_test() {
  let mod = load(module("multival", [swap2_fn(), use_swap2_fn()]))
  assert catch_apply(mod, atom.create("caller"), [2]) == Ok(5)
  assert catch_apply(mod, atom.create("caller"), [10])
    == Ok(18_446_744_073_709_551_613)
}

/// `voiddiv(a, b)` computes signed `a / b` and DROPS it — a zero-result (`void`) function.
fn voiddiv_fn() -> ir.Function {
  ir.Function(
    name: "voiddiv",
    params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
    result: [],
    locals: [],
    body: ir.Let(
      ["x"],
      ir.Num(ir.IDivS(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
      ir.Values([]),
    ),
  )
}

/// REGRESSION: a zero-result function compiles and still traps. A BEAM function must yield
/// exactly one value, so the empty result list is packaged as a single unit value (the
/// `traps.wast` `no_dce` shape that previously failed to build with "return count
/// mismatch"). The dropped division is NOT eliminated, so its trap still fires:
/// `voiddiv(6, 2)` runs and returns (result discarded); `voiddiv(6, 0)` traps with
/// `int_div_by_zero`.
pub fn zero_result_fn_e2e_test() {
  let mod = load(module("voidfn", [voiddiv_fn()]))
  let assert Ok(_) = catch_apply(mod, atom.create("voiddiv"), [6, 2])
  let assert Error(trap) = catch_apply(mod, atom.create("voiddiv"), [6, 0])
  assert string.contains(trap, "wasm_trap")
  assert string.contains(trap, "int_div_by_zero")
}

// ════════════════════ Phase-2: stateful WASM end-to-end (load → instantiate → invoke) ════════════════════
//
// These are the headline Phase-2 proof: a hand-built IR2 `Module` with the generated
// `instantiate/0` compiles, instantiates (seeding the per-instance cell), and runs spec-
// correctly on the BEAM — memory round-trip, grow, mutable global, `call_indirect` + the 3
// faults, a trapping `trunc`, and float ops. The instance's cell is process-local; `gleeunit`
// runs each test synchronously in one process, so `instantiate` then `invoke` share it.

/// Build a full Phase-2 module (memory/globals/tables/elements/data/start), exporting each
/// function by its own name. `name` is namespaced; unique per test so loads don't clobber.
fn full(
  name: String,
  memory: option.Option(ir.MemoryDecl),
  globals: List(ir.GlobalDecl),
  functions: List(ir.Function),
  tables: List(ir.TableDecl),
  elements: List(ir.ElementSegment),
  data: List(ir.DataSegment),
  start: option.Option(String),
) -> ir.Module {
  ir.Module(
    name: "twocore@e2e@" <> name,
    uses_numerics: True,
    memories: case memory {
      option.Some(m) -> [m]
      option.None -> []
    },
    globals: globals,
    imports: [],
    functions: functions,
    exports: list.map(functions, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: data,
    tables: tables,
    elements: elements,
    start: start,
    tags: [],
  )
}

/// Run the generated `instantiate/0` (seeds the cell), asserting it succeeds.
fn instantiate(mod: Atom) -> Nil {
  let assert Ok(_) = catch_apply(mod, atom.create("instantiate"), [])
  Nil
}

fn store_fn(name: String, bytes: Int) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("addr", ir.TI32), ir.Local("val", ir.TI32)],
    result: [],
    locals: [],
    body: ir.Let(
      [],
      ir.MemStore(
        0,
        ir.MemAccess(bytes, False),
        ir.Var("addr"),
        ir.Var("val"),
        0,
      ),
      ir.Values([]),
    ),
  )
}

fn load_fn(
  name: String,
  bytes: Int,
  signed: Bool,
  result: ir.ValType,
) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("addr", ir.TI32)],
    result: [result],
    locals: [],
    body: ir.MemLoad(0, ir.MemAccess(bytes, signed), ir.Var("addr"), 0, result),
  )
}

/// MEMORY round-trip: `i32.store` then `i32.load` returns the stored bits; and the width
/// matrix sign-/zero-extends per `exec/memory` — a stored `0xFFFFFF80` reads back as itself
/// at i32.load, `load8_s` sign-extends the low byte `0x80` → `0xFFFFFF80`, and `load16_u`
/// zero-extends the low two bytes → `0xFF80`.
pub fn memory_store_load_roundtrip_e2e_test() {
  let mod =
    load(full(
      "mem",
      option.Some(ir.MemoryDecl(1, option.None, ir.Idx32)),
      [],
      [
        store_fn("store32", 4),
        load_fn("load32", 4, False, ir.TI32),
        load_fn("load8s", 1, True, ir.TI32),
        load_fn("load16u", 2, False, ir.TI32),
      ],
      [],
      [],
      [],
      option.None,
    ))
  instantiate(mod)
  // round-trip a full i32 word at address 0.
  let assert Ok(_) = catch_apply(mod, atom.create("store32"), [0, 305_419_896])
  assert catch_apply(mod, atom.create("load32"), [0]) == Ok(305_419_896)
  // little-endian + sign-/zero-extension on the width matrix.
  let assert Ok(_) =
    catch_apply(mod, atom.create("store32"), [0, 4_294_967_168])
  assert catch_apply(mod, atom.create("load8s"), [0]) == Ok(4_294_967_168)
  assert catch_apply(mod, atom.create("load16u"), [0]) == Ok(65_408)
}

/// MEMORY out-of-bounds load TRAPS (zero corruption): a load one byte past the single page
/// traps "out of bounds memory access" (`exec/memory` — strictly-greater bound).
pub fn memory_oob_load_traps_e2e_test() {
  let mod =
    load(full(
      "memoob",
      option.Some(ir.MemoryDecl(1, option.None, ir.Idx32)),
      [],
      [load_fn("load32", 4, False, ir.TI32)],
      [],
      [],
      [],
      option.None,
    ))
  instantiate(mod)
  // last in-bounds 4-byte word starts at 65532; 65533 ends at 65537 > 65536 → trap.
  assert catch_apply(mod, atom.create("load32"), [65_533]) |> is_trap
}

/// `memory.grow` grows + returns the OLD size, a load of the freshly-grown (zero-filled)
/// region returns `0`, and a grow past the declared max returns `-1` without allocating
/// (`memory.grow` semantics).
pub fn memory_grow_e2e_test() {
  let mod =
    load(full(
      "memgrow",
      option.Some(ir.MemoryDecl(1, option.Some(3), ir.Idx32)),
      [],
      [
        ir.Function(
          "grow",
          [ir.Local("d", ir.TI32)],
          [ir.TI32],
          [],
          ir.MemGrow(0, ir.Var("d")),
        ),
        ir.Function("size", [], [ir.TI32], [], ir.MemSize(0)),
        load_fn("load32", 4, False, ir.TI32),
      ],
      [],
      [],
      [],
      option.None,
    ))
  instantiate(mod)
  assert catch_apply(mod, atom.create("size"), []) == Ok(1)
  // grow(1) returns the OLD page count (1); the new region is in bounds and zero-filled.
  assert catch_apply(mod, atom.create("grow"), [1]) == Ok(1)
  assert catch_apply(mod, atom.create("size"), []) == Ok(2)
  assert catch_apply(mod, atom.create("load32"), [65_536]) == Ok(0)
  // grow past the declared max (2 + 5 > 3) returns -1 and does not allocate.
  assert catch_apply(mod, atom.create("grow"), [5]) == Ok(-1)
  assert catch_apply(mod, atom.create("size"), []) == Ok(2)
}

/// A mutable GLOBAL round-trips `global.set`/`global.get`, starting from its constant init.
pub fn mutable_global_e2e_test() {
  let mod =
    load(full(
      "global",
      option.None,
      [ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(7)]))],
      [
        ir.Function("get", [], [ir.TI32], [], ir.GlobalGet("g0")),
        ir.Function(
          "set",
          [ir.Local("v", ir.TI32)],
          [],
          [],
          ir.Let([], ir.GlobalSet("g0", ir.Var("v")), ir.Values([])),
        ),
      ],
      [],
      [],
      [],
      option.None,
    ))
  instantiate(mod)
  assert catch_apply(mod, atom.create("get"), []) == Ok(7)
  let assert Ok(_) = catch_apply(mod, atom.create("set"), [99])
  assert catch_apply(mod, atom.create("get"), []) == Ok(99)
}

/// `call_indirect` to the RIGHT type runs, and each of the three faults traps with the spec
/// reason (`UndefinedElement` for OOB index, `UninitializedElement` for a null slot,
/// `IndirectCallTypeMismatch` for a wrong type) — never via a data-driven `apply`.
pub fn call_indirect_e2e_test() {
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
      ir.CallIndirect("t0", ir.Var("idx"), ir.FuncType([ir.TI32], [ir.TI32]), [
        ir.ConstI32(41),
      ]),
    )
  let callwrong =
    ir.Function(
      "callwrong",
      [ir.Local("idx", ir.TI32)],
      [ir.TI64],
      [],
      ir.CallIndirect("t0", ir.Var("idx"), ir.FuncType([ir.TI64], [ir.TI64]), [
        ir.ConstI64(0),
      ]),
    )
  let mod =
    load(full(
      "ci",
      option.None,
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
      [],
      option.None,
    ))
  instantiate(mod)
  // slot 0 holds `inc` with type [i32]->[i32]: dispatch runs.
  assert catch_apply(mod, atom.create("callfn"), [0]) == Ok(42)
  // index past the table bound (size 4).
  let assert Error(undef) = catch_apply(mod, atom.create("callfn"), [10])
  assert string.contains(undef, "undefined_element")
  // in-bounds but null (uninitialised) slot.
  let assert Error(uninit) = catch_apply(mod, atom.create("callfn"), [2])
  assert string.contains(uninit, "uninitialized_element")
  // right slot, wrong expected type ([i64]->[i64] vs the stored [i32]->[i32]).
  let assert Error(mismatch) = catch_apply(mod, atom.create("callwrong"), [0])
  assert string.contains(mismatch, "indirect_call_type_mismatch")
}

/// A trapping `i32.trunc_f32_s`: in-range truncates toward zero; NaN traps "invalid
/// conversion to integer"; ±Inf and out-of-range trap "integer overflow" (`exec/numerics`).
pub fn trapping_trunc_e2e_test() {
  let mod =
    load(full(
      "trunc",
      option.None,
      [],
      [
        ir.Function(
          "trunc",
          [ir.Local("x", ir.TF32)],
          [ir.TI32],
          [],
          ir.Convert(ir.TruncS(ir.FW32, ir.W32), ir.Var("x")),
        ),
      ],
      [],
      [],
      [],
      option.None,
    ))
  instantiate(mod)
  // 3.7 → 3 (toward zero).
  assert catch_apply(mod, atom.create("trunc"), [1_080_452_301]) == Ok(3)
  // NaN → invalid conversion to integer.
  let assert Error(nan) =
    catch_apply(mod, atom.create("trunc"), [2_143_289_344])
  assert string.contains(nan, "invalid_conversion_to_integer")
  // 2^31 (just out of i32 range) → integer overflow.
  let assert Error(ov) = catch_apply(mod, atom.create("trunc"), [1_325_400_064])
  assert string.contains(ov, "int_overflow")
  // +Inf → integer overflow (NOT invalid conversion).
  let assert Error(inf) =
    catch_apply(mod, atom.create("trunc"), [2_139_095_040])
  assert string.contains(inf, "int_overflow")
}

/// Float ops through codegen: an ordered comparison (`f32.lt`) yields an i32 0/1, and
/// `f32.sqrt(4.0)` returns the bit pattern of `2.0`.
pub fn float_compare_and_sqrt_e2e_test() {
  let mod =
    load(full(
      "flt",
      option.None,
      [],
      [
        ir.Function(
          "lt",
          [ir.Local("a", ir.TF32), ir.Local("b", ir.TF32)],
          [ir.TI32],
          [],
          ir.Num(ir.FLt(ir.FW32), [ir.Var("a"), ir.Var("b")]),
        ),
        ir.Function(
          "sqrtf",
          [ir.Local("x", ir.TF32)],
          [ir.TF32],
          [],
          ir.Num(ir.FSqrt(ir.FW32), [ir.Var("x")]),
        ),
      ],
      [],
      [],
      [],
      option.None,
    ))
  instantiate(mod)
  // 1.0 < 2.0 → 1; 2.0 < 1.0 → 0 (f32 bit patterns).
  assert catch_apply(mod, atom.create("lt"), [1_065_353_216, 1_073_741_824])
    == Ok(1)
  assert catch_apply(mod, atom.create("lt"), [1_073_741_824, 1_065_353_216])
    == Ok(0)
  // sqrt(4.0) == 2.0  (0x40800000 → 0x40000000).
  assert catch_apply(mod, atom.create("sqrtf"), [1_082_130_432])
    == Ok(1_073_741_824)
}

/// An out-of-bounds active DATA segment traps AT INSTANTIATION (`instantiate/0` raises
/// "out of bounds memory access" — the cell is never left half-initialised).
pub fn oob_data_segment_traps_at_instantiation_e2e_test() {
  let mod =
    load(full(
      "dataoob",
      option.Some(ir.MemoryDecl(1, option.None, ir.Idx32)),
      [],
      [],
      [],
      [],
      [
        ir.DataSegment(ir.DataActive(0, ir.Values([ir.ConstI32(65_535)])), <<
          1,
          2,
          3,
        >>),
      ],
      option.None,
    ))
  let assert Error(reason) = catch_apply(mod, atom.create("instantiate"), [])
  assert string.contains(reason, "memory_out_of_bounds")
}

/// An out-of-bounds active ELEMENT segment traps AT INSTANTIATION (`instantiate/0` raises
/// "out of bounds table access").
pub fn oob_element_segment_traps_at_instantiation_e2e_test() {
  let target =
    ir.Function(
      "target",
      [ir.Local("p0", ir.TI32)],
      [ir.TI32],
      [],
      ir.Return([
        ir.Var("p0"),
      ]),
    )
  let mod =
    load(full(
      "elemoob",
      option.None,
      [],
      [target],
      [ir.TableDecl("t0", ir.FuncRef, 2, option.None)],
      [
        ir.ElementSegment(
          ir.ElemActive("t0", ir.Values([ir.ConstI32(1)])),
          ir.FuncRef,
          [
            ir.RefFunc("target"),
            ir.RefFunc("target"),
          ],
        ),
      ],
      [],
      option.None,
    ))
  let assert Error(reason) = catch_apply(mod, atom.create("instantiate"), [])
  assert string.contains(reason, "table_out_of_bounds")
}

/// True iff an invoke result is a trap (any `{wasm_trap, _}` error).
fn is_trap(r: Result(Int, String)) -> Bool {
  case r {
    Error(t) -> string.contains(t, "wasm_trap")
    Ok(_) -> False
  }
}

// ════════════════════ Phase-4 (P4-02): THREADED state end-to-end ════════════════════
//
// The headline P4-02 proof (unit-doc §"Verification" test 6): a hand-built stateful IR `Module`
// compiled under `state_strategy: Threaded` instantiates, runs, and traps BYTE-IDENTICALLY to
// the `Cell` build — but as a purely-functional record-threading `.core` (no process dictionary
// in the linked output). The run-ABI is HAND-DRIVEN here (unit 08 owns it in the pipeline): the
// generated `instantiate/0` RETURNS the `InstanceState`; each export takes it LEADING and
// returns `{Package, St'}`; the test threads `St'` across successive invokes via a small FFI.

// Test-only FFI (see `test/twocore_threaded_test_ffi.erl`): run the record-returning
// `instantiate/0`, and apply an export with the record leading, capturing traps as `Error`.
@external(erlang, "twocore_threaded_test_ffi", "instantiate")
fn t_instantiate(module: Atom) -> Result(Dynamic, String)

// Invoke a VALUE-returning export: `{IntResult, St'}` on success (the package is coerced to
// `Int` at the FFI boundary, as the cell `catch_apply` does), a trap text on `Error`.
@external(erlang, "twocore_threaded_test_ffi", "invoke")
fn t_invoke_int(
  module: Atom,
  function: Atom,
  st: Dynamic,
  args: List(Int),
) -> Result(#(Int, Dynamic), String)

// Invoke a ZERO-RESULT export (`store`/`set`): the package is the discardable `'ok'` atom, so
// it stays `Dynamic`; only the threaded-out record `St'` matters.
@external(erlang, "twocore_threaded_test_ffi", "invoke")
fn t_invoke_unit(
  module: Atom,
  function: Atom,
  st: Dynamic,
  args: List(Int),
) -> Result(#(Dynamic, Dynamic), String)

/// A Safe binding switched to the tier-P `Threaded` state strategy (the same fixed
/// `twocore@runtime@*` modules; only the codegen shape differs).
fn threaded_binding() -> instance.Binding {
  instance.Binding(..instance.safe_default(), state_strategy: instance.Threaded)
}

/// Emit `module` under `Threaded` to Core text, compile it, and load it; return the module atom.
fn load_threaded(module: ir.Module) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(module, threaded_binding())
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

/// THREADED memory round-trip: `instantiate/0` returns the record, `store32` threads the
/// UPDATED record forward, and `load32`/`load8s`/`load16u` read it back — sign-/zero-extending
/// per `exec/memory`. Diffed against the `Cell` oracle (same IR, `state_strategy: Cell`).
pub fn threaded_memory_store_load_roundtrip_e2e_test() {
  let m =
    full(
      "threadedmem",
      option.Some(ir.MemoryDecl(1, option.None, ir.Idx32)),
      [],
      [
        store_fn("store32", 4),
        load_fn("load32", 4, False, ir.TI32),
        load_fn("load8s", 1, True, ir.TI32),
        load_fn("load16u", 2, False, ir.TI32),
      ],
      [],
      [],
      [],
      option.None,
    )
  let mod = load_threaded(m)
  let assert Ok(st0) = t_instantiate(mod)
  // store a full i32 word at addr 0, threading the record forward, then load it back.
  let assert Ok(#(_, st1)) =
    t_invoke_unit(mod, atom.create("store32"), st0, [0, 305_419_896])
  let assert Ok(#(v, st2)) = t_invoke_int(mod, atom.create("load32"), st1, [0])
  assert v == 305_419_896
  // little-endian + sign-/zero-extension on the width matrix, still threading.
  let assert Ok(#(_, st3)) =
    t_invoke_unit(mod, atom.create("store32"), st2, [0, 4_294_967_168])
  let assert Ok(#(v8, st4)) = t_invoke_int(mod, atom.create("load8s"), st3, [0])
  assert v8 == 4_294_967_168
  let assert Ok(#(v16, _)) = t_invoke_int(mod, atom.create("load16u"), st4, [0])
  assert v16 == 65_408
  // diff vs the Cell oracle — byte-identical observable results (G7).
  let cmod = load(m)
  instantiate(cmod)
  let assert Ok(_) = catch_apply(cmod, atom.create("store32"), [0, 305_419_896])
  assert catch_apply(cmod, atom.create("load32"), [0]) == Ok(305_419_896)
}

/// THREADED `memory.grow`: returns the OLD page count and rebinds the record; a load of the
/// freshly-grown zero region returns `0`; a grow past the declared max returns `-1`.
pub fn threaded_memory_grow_e2e_test() {
  let m =
    full(
      "threadedgrow",
      option.Some(ir.MemoryDecl(1, option.Some(3), ir.Idx32)),
      [],
      [
        ir.Function(
          "grow",
          [ir.Local("d", ir.TI32)],
          [ir.TI32],
          [],
          ir.MemGrow(0, ir.Var("d")),
        ),
        ir.Function("size", [], [ir.TI32], [], ir.MemSize(0)),
        load_fn("load32", 4, False, ir.TI32),
      ],
      [],
      [],
      [],
      option.None,
    )
  let mod = load_threaded(m)
  let assert Ok(st0) = t_instantiate(mod)
  let assert Ok(#(s0, st1)) = t_invoke_int(mod, atom.create("size"), st0, [])
  assert s0 == 1
  // grow(1) returns the OLD page count (1) and rebinds the record.
  let assert Ok(#(old, st2)) = t_invoke_int(mod, atom.create("grow"), st1, [1])
  assert old == 1
  let assert Ok(#(s1, st3)) = t_invoke_int(mod, atom.create("size"), st2, [])
  assert s1 == 2
  // a load of the freshly-grown (zero-filled) region returns 0.
  let assert Ok(#(z, st4)) =
    t_invoke_int(mod, atom.create("load32"), st3, [65_536])
  assert z == 0
  // grow past the declared max (2 + 5 > 3) returns -1 and allocates nothing.
  let assert Ok(#(neg, st5)) = t_invoke_int(mod, atom.create("grow"), st4, [5])
  assert neg == -1
  let assert Ok(#(s2, _)) = t_invoke_int(mod, atom.create("size"), st5, [])
  assert s2 == 2
}

/// THE headline hand-driven proof: a mutable GLOBAL round-trips `global.set`/`global.get`, and
/// state PERSISTS across two invokes THROUGH THE THREADED RECORD (not a pdict cell). The OLD
/// record still reads the OLD value — purely-functional threading (immutable versions). Diffed
/// against the `Cell` oracle.
pub fn threaded_mutable_global_persists_across_invokes_e2e_test() {
  let m =
    full(
      "threadedglobal",
      option.None,
      [ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(7)]))],
      [
        ir.Function("get", [], [ir.TI32], [], ir.GlobalGet("g0")),
        ir.Function(
          "set",
          [ir.Local("v", ir.TI32)],
          [],
          [],
          ir.Let([], ir.GlobalSet("g0", ir.Var("v")), ir.Values([])),
        ),
      ],
      [],
      [],
      [],
      option.None,
    )
  let mod = load_threaded(m)
  let assert Ok(st0) = t_instantiate(mod)
  // get reads the constant init 7 (record unchanged).
  let assert Ok(#(v0, st1)) = t_invoke_int(mod, atom.create("get"), st0, [])
  assert v0 == 7
  // set 99 → thread the UPDATED record forward.
  let assert Ok(#(_, st2)) = t_invoke_unit(mod, atom.create("set"), st1, [99])
  // get on the threaded record sees 99 — state PERSISTED across invokes via the value.
  let assert Ok(#(v2, _)) = t_invoke_int(mod, atom.create("get"), st2, [])
  assert v2 == 99
  // the ORIGINAL record st0 STILL reads 7 — the old version was never mutated (functional).
  let assert Ok(#(v_old, _)) = t_invoke_int(mod, atom.create("get"), st0, [])
  assert v_old == 7
  // diff vs the Cell oracle — same observable round-trip (G7).
  let cmod = load(m)
  instantiate(cmod)
  assert catch_apply(cmod, atom.create("get"), []) == Ok(7)
  let assert Ok(_) = catch_apply(cmod, atom.create("set"), [99])
  assert catch_apply(cmod, atom.create("get"), []) == Ok(99)
}

/// THREADED `call_indirect`: dispatch to the right type runs (threading the record through the
/// invoked closure), and each of the three faults traps with the spec reason — never via a
/// data-driven `apply` (the closure `St` is a parameter, not a dispatch key).
pub fn threaded_call_indirect_e2e_test() {
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
      ir.CallIndirect("t0", ir.Var("idx"), ir.FuncType([ir.TI32], [ir.TI32]), [
        ir.ConstI32(41),
      ]),
    )
  let callwrong =
    ir.Function(
      "callwrong",
      [ir.Local("idx", ir.TI32)],
      [ir.TI64],
      [],
      ir.CallIndirect("t0", ir.Var("idx"), ir.FuncType([ir.TI64], [ir.TI64]), [
        ir.ConstI64(0),
      ]),
    )
  let m =
    full(
      "threadedci",
      option.None,
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
      [],
      option.None,
    )
  let mod = load_threaded(m)
  let assert Ok(st0) = t_instantiate(mod)
  // slot 0 holds `inc` [i32]->[i32]: dispatch runs, threading the record.
  let assert Ok(#(v, st1)) = t_invoke_int(mod, atom.create("callfn"), st0, [0])
  assert v == 42
  // index past the table bound (size 4).
  let assert Error(undef) = t_invoke_int(mod, atom.create("callfn"), st1, [10])
  assert string.contains(undef, "undefined_element")
  // in-bounds but null (uninitialised) slot.
  let assert Error(uninit) = t_invoke_int(mod, atom.create("callfn"), st1, [2])
  assert string.contains(uninit, "uninitialized_element")
  // right slot, wrong expected type ([i64]->[i64] vs the stored [i32]->[i32]).
  let assert Error(mismatch) =
    t_invoke_int(mod, atom.create("callwrong"), st1, [0])
  assert string.contains(mismatch, "indirect_call_type_mismatch")
}

/// An out-of-bounds active DATA segment traps AT INSTANTIATION under `Threaded` too
/// (`instantiate/0` raises "out of bounds memory access" — the record is abandoned).
pub fn threaded_oob_data_segment_traps_at_instantiation_e2e_test() {
  let m =
    full(
      "threadeddataoob",
      option.Some(ir.MemoryDecl(1, option.None, ir.Idx32)),
      [],
      [],
      [],
      [],
      [
        ir.DataSegment(ir.DataActive(0, ir.Values([ir.ConstI32(65_535)])), <<
          1,
          2,
          3,
        >>),
      ],
      option.None,
    )
  let mod = load_threaded(m)
  let assert Error(reason) = t_instantiate(mod)
  assert string.contains(reason, "memory_out_of_bounds")
}

/// An out-of-bounds active ELEMENT segment traps AT INSTANTIATION under `Threaded`
/// (`instantiate/0` raises "out of bounds table access").
pub fn threaded_oob_element_segment_traps_at_instantiation_e2e_test() {
  let target =
    ir.Function(
      "target",
      [ir.Local("p0", ir.TI32)],
      [ir.TI32],
      [],
      ir.Return([ir.Var("p0")]),
    )
  let m =
    full(
      "threadedelemoob",
      option.None,
      [],
      [target],
      [ir.TableDecl("t0", ir.FuncRef, 2, option.None)],
      [
        ir.ElementSegment(
          ir.ElemActive("t0", ir.Values([ir.ConstI32(1)])),
          ir.FuncRef,
          [
            ir.RefFunc("target"),
            ir.RefFunc("target"),
          ],
        ),
      ],
      [],
      option.None,
    )
  let mod = load_threaded(m)
  let assert Error(reason) = t_instantiate(mod)
  assert string.contains(reason, "table_out_of_bounds")
}

// ════════════════════ Phase-5 (P5-06): references / tables / bulk / multi-mem / imports ════════════════════
//
// The P5-06 payoff (unit-doc §"Verification" test 6): hand-built IR3 modules using the new
// reference/table/bulk/multi-memory/import surface compile, instantiate, and RUN spec-correctly on
// the BEAM, under BOTH `Cell` and `Threaded`, with every new trap fail-closing. Results are held
// to the WebAssembly spec (reference-types + bulk-memory proposals, now the living standard).

/// A reference/table module: a funcref table `t0` (size 3), `inc : [i32]->[i32]` placed at slot 0
/// by an active element segment (slots 1,2 null), and functions exercising `ref.func` /
/// `table.set` / `table.get` / `ref.is_null` / `table.grow` / `call_indirect`.
fn reftype_module(name: String) -> ir.Module {
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
  // `table.get $t0 i` then `ref.is_null` → i32 1 (null slot) / 0 (filled); an OOB index traps.
  let isnull =
    ir.Function(
      "isnull",
      [ir.Local("i", ir.TI32)],
      [ir.TI32],
      [],
      ir.Let(["r"], ir.TableGet("t0", ir.Var("i")), ir.RefIsNull(ir.Var("r"))),
    )
  // `call_indirect` through the pre-filled slot 0 (spec-correct dispatch).
  let call0 =
    ir.Function(
      "call0",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.CallIndirect("t0", ir.ConstI32(0), ir.FuncType([ir.TI32], [ir.TI32]), [
        ir.Var("x"),
      ]),
    )
  // `ref.func inc` → `table.set` slot 1 → `call_indirect` slot 1 (the set/get round-trip).
  let setcall =
    ir.Function(
      "setcall",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.Let(
        ["r"],
        ir.RefFunc("inc"),
        ir.Let(
          [],
          ir.TableSet("t0", ir.ConstI32(1), ir.Var("r")),
          ir.CallIndirect(
            "t0",
            ir.ConstI32(1),
            ir.FuncType([ir.TI32], [ir.TI32]),
            [ir.Var("x")],
          ),
        ),
      ),
    )
  // `call_indirect` through the null slot 2 → traps UninitializedElement (spec §4.4.6).
  let callnull =
    ir.Function(
      "callnull",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.CallIndirect("t0", ir.ConstI32(2), ir.FuncType([ir.TI32], [ir.TI32]), [
        ir.Var("x"),
      ]),
    )
  // `table.grow(+1, ref.func inc)` → the new slot (at the OLD size) is callable.
  let growcall =
    ir.Function(
      "growcall",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.Let(
        ["r"],
        ir.RefFunc("inc"),
        ir.Let(
          ["old"],
          ir.TableGrow("t0", ir.ConstI32(1), ir.Var("r")),
          ir.CallIndirect(
            "t0",
            ir.Var("old"),
            ir.FuncType([ir.TI32], [ir.TI32]),
            [ir.Var("x")],
          ),
        ),
      ),
    )
  ir.Module(
    name: "twocore@e2e@" <> name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [inc, isnull, call0, setcall, callnull, growcall],
    exports: [
      ir.ExportFn("isnull", "isnull"),
      ir.ExportFn("call0", "call0"),
      ir.ExportFn("setcall", "setcall"),
      ir.ExportFn("callnull", "callnull"),
      ir.ExportFn("growcall", "growcall"),
    ],
    data_segments: [],
    tables: [ir.TableDecl("t0", ir.FuncRef, 3, option.None)],
    elements: [
      ir.ElementSegment(
        ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
        ir.FuncRef,
        [ir.RefFunc("inc")],
      ),
    ],
    start: option.None,
    tags: [],
  )
}

/// REFERENCE/TABLE end-to-end (Cell): `ref.func`/`table.set`/`table.get`/`ref.is_null`/
/// `table.grow`/`call_indirect` run spec-correctly, and a null-slot `call_indirect` + an OOB
/// `table.get` fail-closed. Cite reference-types §4.4.6 (`table.get` OOB → `TableOutOfBounds`;
/// a null `call_indirect` slot → `UninitializedElement`; `table.grow` returns the old size).
pub fn reftype_table_e2e_test() {
  let mod = load(reftype_module("reftype"))
  instantiate(mod)
  // slot 0 = inc (not null); slot 1 = null; an OOB get traps.
  assert catch_apply(mod, atom.create("isnull"), [0]) == Ok(0)
  assert catch_apply(mod, atom.create("isnull"), [1]) == Ok(1)
  assert catch_apply(mod, atom.create("call0"), [41]) == Ok(42)
  let assert Error(uninit) = catch_apply(mod, atom.create("callnull"), [7])
  assert string.contains(uninit, "uninitialized_element")
  let assert Error(oob) = catch_apply(mod, atom.create("isnull"), [5])
  assert string.contains(oob, "table_out_of_bounds")
  // set slot 1 = inc, then call it; the slot is now non-null.
  assert catch_apply(mod, atom.create("setcall"), [5]) == Ok(6)
  assert catch_apply(mod, atom.create("isnull"), [1]) == Ok(0)
  // grow(+1, inc) and call the freshly-grown slot.
  assert catch_apply(mod, atom.create("growcall"), [9]) == Ok(10)
}

/// REFERENCE/TABLE end-to-end (Threaded): the SAME program threads the `InstanceState` record
/// through every table op — spec-correct results and the same fail-closed traps as `Cell` (G7).
pub fn reftype_table_threaded_e2e_test() {
  let mod = load_threaded(reftype_module("reftypethreaded"))
  let assert Ok(st0) = t_instantiate(mod)
  let assert Ok(#(a, st1)) = t_invoke_int(mod, atom.create("isnull"), st0, [0])
  assert a == 0
  let assert Ok(#(b, st2)) = t_invoke_int(mod, atom.create("isnull"), st1, [1])
  assert b == 1
  let assert Ok(#(c, st3)) = t_invoke_int(mod, atom.create("call0"), st2, [41])
  assert c == 42
  let assert Error(uninit) =
    t_invoke_int(mod, atom.create("callnull"), st3, [7])
  assert string.contains(uninit, "uninitialized_element")
  let assert Error(oob) = t_invoke_int(mod, atom.create("isnull"), st3, [5])
  assert string.contains(oob, "table_out_of_bounds")
  let assert Ok(#(d, st4)) = t_invoke_int(mod, atom.create("setcall"), st3, [5])
  assert d == 6
  // the threaded record carries the set — slot 1 is now non-null.
  let assert Ok(#(e, st5)) = t_invoke_int(mod, atom.create("isnull"), st4, [1])
  assert e == 0
  let assert Ok(#(g, _)) = t_invoke_int(mod, atom.create("growcall"), st5, [9])
  assert g == 10
}

/// A bulk-memory module: one memory + a PASSIVE data segment `<<1,2,3,4>>`, with
/// `memory.fill`/`memory.copy`/`memory.init`/`data.drop` + byte load/store.
fn bulk_module(name: String) -> ir.Module {
  let store8 = store_fn("store8", 1)
  let load8 = load_fn("load8", 1, False, ir.TI32)
  let fill =
    ir.Function(
      "fill",
      [ir.Local("d", ir.TI32), ir.Local("v", ir.TI32), ir.Local("n", ir.TI32)],
      [],
      [],
      ir.Let(
        [],
        ir.MemFill(0, ir.Var("d"), ir.Var("v"), ir.Var("n")),
        ir.Values([]),
      ),
    )
  let copy =
    ir.Function(
      "copy",
      [ir.Local("d", ir.TI32), ir.Local("s", ir.TI32), ir.Local("n", ir.TI32)],
      [],
      [],
      ir.Let(
        [],
        ir.MemCopy(0, 0, ir.Var("d"), ir.Var("s"), ir.Var("n")),
        ir.Values([]),
      ),
    )
  let meminit =
    ir.Function(
      "meminit",
      [ir.Local("d", ir.TI32), ir.Local("s", ir.TI32), ir.Local("n", ir.TI32)],
      [],
      [],
      ir.Let(
        [],
        ir.MemInit(0, 0, ir.Var("d"), ir.Var("s"), ir.Var("n")),
        ir.Values([]),
      ),
    )
  let dropdata =
    ir.Function(
      "dropdata",
      [],
      [],
      [],
      ir.Let([], ir.DataDrop(0), ir.Values([])),
    )
  ir.Module(
    name: "twocore@e2e@" <> name,
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [store8, load8, fill, copy, meminit, dropdata],
    exports: list.map(
      ["store8", "load8", "fill", "copy", "meminit", "dropdata"],
      fn(n) { ir.ExportFn(n, n) },
    ),
    data_segments: [ir.DataSegment(ir.DataPassive, <<1, 2, 3, 4>>)],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// BULK-MEMORY end-to-end (Cell): `memory.init` from a passive segment writes it; `memory.copy`
/// is overlap-correct; `memory.fill` writes a byte run; `data.drop` then `memory.init` from the
/// dropped segment with non-zero count TRAPS; an out-of-range `memory.fill` traps with no partial
/// write. Cite bulk-memory §4.4.7/§4.4.9 (eager bounds, dropped segment ⇒ length-0).
pub fn bulk_memory_e2e_test() {
  let mod = load(bulk_module("bulk"))
  instantiate(mod)
  // memory.init(dst=10, src=0, n=4) copies the passive segment <<1,2,3,4>> to offset 10.
  let assert Ok(_) = catch_apply(mod, atom.create("meminit"), [10, 0, 4])
  assert catch_apply(mod, atom.create("load8"), [10]) == Ok(1)
  assert catch_apply(mod, atom.create("load8"), [13]) == Ok(4)
  // memory.copy(dst=20, src=10, n=4) is memmove-correct.
  let assert Ok(_) = catch_apply(mod, atom.create("copy"), [20, 10, 4])
  assert catch_apply(mod, atom.create("load8"), [20]) == Ok(1)
  assert catch_apply(mod, atom.create("load8"), [23]) == Ok(4)
  // overlapping forward copy(dst=21, src=20, n=3): <<1,2,3>> → 21,22,23 (memmove, not a naive
  // forward loop which would smear 1s).
  let assert Ok(_) = catch_apply(mod, atom.create("copy"), [21, 20, 3])
  assert catch_apply(mod, atom.create("load8"), [21]) == Ok(1)
  assert catch_apply(mod, atom.create("load8"), [22]) == Ok(2)
  assert catch_apply(mod, atom.create("load8"), [23]) == Ok(3)
  // memory.fill(dest=30, value=0xAB, n=5) writes the low byte.
  let assert Ok(_) = catch_apply(mod, atom.create("fill"), [30, 0xAB, 5])
  assert catch_apply(mod, atom.create("load8"), [30]) == Ok(0xAB)
  assert catch_apply(mod, atom.create("load8"), [34]) == Ok(0xAB)
  // an out-of-range fill traps with no partial write (dest+n > 65536).
  let assert Error(fo) = catch_apply(mod, atom.create("fill"), [65_535, 0, 4])
  assert string.contains(fo, "memory_out_of_bounds")
  // data.drop then memory.init from the dropped (length-0) segment with n>0 traps.
  let assert Ok(_) = catch_apply(mod, atom.create("dropdata"), [])
  let assert Error(di) = catch_apply(mod, atom.create("meminit"), [0, 0, 4])
  assert string.contains(di, "memory_out_of_bounds")
  // n=0 from a dropped segment is a no-op (does NOT trap).
  let assert Ok(_) = catch_apply(mod, atom.create("meminit"), [0, 0, 0])
}

/// BULK-MEMORY end-to-end (Threaded): the SAME bulk ops thread the record; spec-correct writes +
/// the same fail-closed traps as `Cell` (G7).
pub fn bulk_memory_threaded_e2e_test() {
  let mod = load_threaded(bulk_module("bulkthreaded"))
  let assert Ok(st0) = t_instantiate(mod)
  let assert Ok(#(_, st1)) =
    t_invoke_unit(mod, atom.create("meminit"), st0, [10, 0, 4])
  let assert Ok(#(v1, st2)) = t_invoke_int(mod, atom.create("load8"), st1, [10])
  assert v1 == 1
  let assert Ok(#(_, st3)) =
    t_invoke_unit(mod, atom.create("copy"), st2, [20, 10, 4])
  let assert Ok(#(v2, st4)) = t_invoke_int(mod, atom.create("load8"), st3, [23])
  assert v2 == 4
  let assert Ok(#(_, st5)) =
    t_invoke_unit(mod, atom.create("fill"), st4, [30, 0xAB, 5])
  let assert Ok(#(v3, st6)) = t_invoke_int(mod, atom.create("load8"), st5, [34])
  assert v3 == 0xAB
  // data.drop threads the record; a later init from the dropped segment traps.
  let assert Ok(#(_, st7)) =
    t_invoke_unit(mod, atom.create("dropdata"), st6, [])
  let assert Error(di) =
    t_invoke_int(mod, atom.create("meminit"), st7, [0, 0, 4])
  assert string.contains(di, "memory_out_of_bounds")
}

/// A two-memory module: independent i32 store/load on memory 0 and memory 1 + each memory's size.
fn multimem_module(name: String) -> ir.Module {
  let store = fn(fname: String, mem: Int) {
    ir.Function(
      fname,
      [ir.Local("a", ir.TI32), ir.Local("v", ir.TI32)],
      [],
      [],
      ir.Let(
        [],
        ir.MemStore(mem, ir.MemAccess(4, False), ir.Var("a"), ir.Var("v"), 0),
        ir.Values([]),
      ),
    )
  }
  let load = fn(fname: String, mem: Int) {
    ir.Function(
      fname,
      [ir.Local("a", ir.TI32)],
      [ir.TI32],
      [],
      ir.MemLoad(mem, ir.MemAccess(4, False), ir.Var("a"), 0, ir.TI32),
    )
  }
  let fns = [
    store("store0", 0),
    load("load0", 0),
    store("store1", 1),
    load("load1", 1),
    ir.Function("size0", [], [ir.TI32], [], ir.MemSize(0)),
    ir.Function("size1", [], [ir.TI32], [], ir.MemSize(1)),
  ]
  ir.Module(
    name: "twocore@e2e@" <> name,
    uses_numerics: True,
    memories: [
      ir.MemoryDecl(1, option.None, ir.Idx32),
      ir.MemoryDecl(2, option.None, ir.Idx32),
    ],
    globals: [],
    imports: [],
    functions: fns,
    exports: list.map(fns, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// MULTI-MEMORY end-to-end (Cell): a store to memory 1 round-trips from memory 1 and does NOT
/// disturb memory 0; each memory's `memory.size` is independent (memory 0 = 1 page, memory 1 = 2
/// pages, from their distinct declared minimums). Cite H3 (every memory instruction carries a
/// memory index; the memories are independent regions).
pub fn multi_memory_e2e_test() {
  let mod = load(multimem_module("multimem"))
  instantiate(mod)
  // sizes reflect the distinct declared minimums (1 vs 2 pages) → routing is by index.
  assert catch_apply(mod, atom.create("size0"), []) == Ok(1)
  assert catch_apply(mod, atom.create("size1"), []) == Ok(2)
  // store to memory 1; read it back from memory 1; memory 0 at the same address is untouched.
  let assert Ok(_) = catch_apply(mod, atom.create("store1"), [0, 42])
  assert catch_apply(mod, atom.create("load1"), [0]) == Ok(42)
  assert catch_apply(mod, atom.create("load0"), [0]) == Ok(0)
  // store to memory 0; both memories now hold their own value independently.
  let assert Ok(_) = catch_apply(mod, atom.create("store0"), [0, 7])
  assert catch_apply(mod, atom.create("load0"), [0]) == Ok(7)
  assert catch_apply(mod, atom.create("load1"), [0]) == Ok(42)
}

/// MULTI-MEMORY end-to-end (Threaded): the two memories thread through one record independently.
pub fn multi_memory_threaded_e2e_test() {
  let mod = load_threaded(multimem_module("multimemthreaded"))
  let assert Ok(st0) = t_instantiate(mod)
  let assert Ok(#(s0, st1)) = t_invoke_int(mod, atom.create("size0"), st0, [])
  assert s0 == 1
  let assert Ok(#(s1, st2)) = t_invoke_int(mod, atom.create("size1"), st1, [])
  assert s1 == 2
  let assert Ok(#(_, st3)) =
    t_invoke_unit(mod, atom.create("store1"), st2, [0, 42])
  let assert Ok(#(v1, st4)) = t_invoke_int(mod, atom.create("load1"), st3, [0])
  assert v1 == 42
  let assert Ok(#(v0, _)) = t_invoke_int(mod, atom.create("load0"), st4, [0])
  assert v0 == 0
}

/// An import module: imports `spectest.global_i32 : i32` (= 666) and `spectest.memory (1 2)`.
/// The imported global is local name `g0`; the imported memory is memory index 0. Reads the
/// global; stores/loads the imported memory.
fn import_module(name: String) -> ir.Module {
  let read_global =
    ir.Function("read_global", [], [ir.TI32], [], ir.GlobalGet("g0"))
  let store = store_fn("store32", 4)
  let load = load_fn("load32", 4, False, ir.TI32)
  ir.Module(
    name: "twocore@e2e@" <> name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [
      ir.ImportGlobal("spectest", "global_i32", ir.TI32, False),
      ir.ImportMemory("spectest", "memory", 1, option.Some(2), ir.Idx32),
    ],
    functions: [read_global, store, load],
    exports: [
      ir.ExportFn("read_global", "read_global"),
      ir.ExportFn("store32", "store32"),
      ir.ExportFn("load32", "load32"),
    ],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// IMPORT end-to-end (Cell): a module importing a `spectest` global + memory is linked via
/// `link.link_imports` (fail-closed matching) and instantiated through the generated
/// `instantiate/1(Imports)`; it reads the provided global (`= 666`, the official `spectest`
/// value) and round-trips the provided memory. Cite H4 (imported globals/memories are provided
/// state, wired at the low indices) + R14 (`spectest.global_i32 = 666`).
pub fn import_spectest_e2e_test() {
  let m = import_module("import")
  let mod = load(m)
  let assert Ok(imports) = link.link_imports(m, [])
  let assert Ok(_) =
    catch_apply_dyn(mod, atom.create("instantiate"), [to_dynamic(imports)])
  // the imported global's value is the official spectest 666.
  assert catch_apply(mod, atom.create("read_global"), []) == Ok(666)
  // the imported memory round-trips a store/load.
  let assert Ok(_) = catch_apply(mod, atom.create("store32"), [0, 123_456])
  assert catch_apply(mod, atom.create("load32"), [0]) == Ok(123_456)
}

/// IMPORT end-to-end (Threaded): the same import wiring under `Threaded` — `instantiate/1(Imports)`
/// RETURNS the seeded record, then the reads thread it.
pub fn import_spectest_threaded_e2e_test() {
  let m = import_module("importthreaded")
  let mod = load_threaded(m)
  let assert Ok(imports) = link.link_imports(m, [])
  let assert Ok(st0) = t_instantiate_with(mod, to_dynamic(imports))
  let assert Ok(#(g, st1)) =
    t_invoke_int(mod, atom.create("read_global"), st0, [])
  assert g == 666
  let assert Ok(#(_, st2)) =
    t_invoke_unit(mod, atom.create("store32"), st1, [0, 123_456])
  let assert Ok(#(v, _)) = t_invoke_int(mod, atom.create("load32"), st2, [0])
  assert v == 123_456
}

// Test-only FFI: run `Mod:instantiate(Imports)` (the `instantiate/1` ABI), yielding the threaded
// record or a trap text.
@external(erlang, "twocore_threaded_test_ffi", "instantiate_with")
fn t_instantiate_with(module: Atom, imports: Dynamic) -> Result(Dynamic, String)

// ════════════════════ Phase-5 follow-up: multi-table call_indirect (Gap 1) ════════════════════
//
// Reference-types lifts the single-table restriction: `call_indirect` (and every table op) carries
// an explicit table index, so a module may declare MANY tables and dispatch through any of them
// (<https://webassembly.github.io/spec/core/exec/instructions.html#control-instructions>, the
// reference-types proposal). `emit_core` resolves the table NAME→index; index 0 keeps the
// byte-identical `call_indirect` head, a NON-zero table emits `call_indirect_at(Idx, …)` /
// `t_call_indirect_at(St, Idx, …)`, both running the SAME 3-fault fail-closed dispatch
// (bounds → null → exact FuncType). Proven end-to-end on the BEAM under BOTH Cell and Threaded.

/// A 2-table module whose targets live in the NON-default table `t1` (index 1). `call1` dispatches
/// `call_indirect $t1`; `call1_wrong` dispatches with a mismatched type; `t0` (index 0) is declared
/// but left empty to prove the dispatch reads the SELECTED table, not the default.
fn multi_table_ci_module(name: String) -> ir.Module {
  let add1 =
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
    )
  let call1 =
    ir.Function(
      "call1",
      [ir.Local("idx", ir.TI32)],
      [ir.TI32],
      [],
      ir.CallIndirect("t1", ir.Var("idx"), ir.FuncType([ir.TI32], [ir.TI32]), [
        ir.ConstI32(41),
      ]),
    )
  let call1_wrong =
    ir.Function(
      "call1_wrong",
      [ir.Local("idx", ir.TI32)],
      [ir.TI64],
      [],
      ir.CallIndirect("t1", ir.Var("idx"), ir.FuncType([ir.TI64], [ir.TI64]), [
        ir.ConstI64(0),
      ]),
    )
  full(
    name,
    option.None,
    [],
    [add1, call1, call1_wrong],
    [
      ir.TableDecl("t0", ir.FuncRef, 4, option.None),
      ir.TableDecl("t1", ir.FuncRef, 4, option.None),
    ],
    // Seed slot 0 of the NON-default table t1 with `add1` (an active reference segment on t1).
    [
      ir.ElementSegment(
        ir.ElemActive("t1", ir.Values([ir.ConstI32(0)])),
        ir.FuncRef,
        [ir.RefFunc("add1")],
      ),
    ],
    [],
    option.None,
  )
}

/// CELL: dispatch through table 1 — a filled slot runs (`add1(41) == 42`), an in-bounds null slot
/// traps `uninitialized element`, and a wrong expected type traps `indirect call type mismatch`
/// (the three distinct spec messages, on a NON-default table).
pub fn multi_table_call_indirect_cell_e2e_test() {
  let mod = load(multi_table_ci_module("mt_ci_cell"))
  instantiate(mod)
  assert catch_apply(mod, atom.create("call1"), [0]) == Ok(42)
  // In-bounds (size 4) but never-written slot 2 → uninitialized element.
  let assert Error(uninit) = catch_apply(mod, atom.create("call1"), [2])
  assert string.contains(uninit, "uninitialized_element")
  // Index past the bound → undefined element (bounds guard fires first).
  let assert Error(undef) = catch_apply(mod, atom.create("call1"), [9])
  assert string.contains(undef, "undefined_element")
  // Right slot, wrong expected type → indirect call type mismatch.
  let assert Error(mismatch) = catch_apply(mod, atom.create("call1_wrong"), [0])
  assert string.contains(mismatch, "indirect_call_type_mismatch")
}

/// THREADED: the SAME multi-table dispatch over the record-threading build — byte-identical
/// observable results to the Cell oracle (`t_call_indirect_at` reads `st`'s `tables` vector at
/// index 1).
pub fn multi_table_call_indirect_threaded_e2e_test() {
  let mod = load_threaded(multi_table_ci_module("mt_ci_threaded"))
  let assert Ok(st0) = t_instantiate(mod)
  let assert Ok(#(v, st1)) = t_invoke_int(mod, atom.create("call1"), st0, [0])
  assert v == 42
  let assert Error(uninit) = t_invoke_int(mod, atom.create("call1"), st1, [2])
  assert string.contains(uninit, "uninitialized_element")
  let assert Error(mismatch) =
    t_invoke_int(mod, atom.create("call1_wrong"), st1, [0])
  assert string.contains(mismatch, "indirect_call_type_mismatch")
}

// ════════════════════ Phase-5 follow-up: ref.func-of-declarative + global-init elem (Gap 2) ════════════════════
//
// The reference-types proposal makes a function reference-able by `ref.func` only if it is
// "declared" — e.g. by a DECLARATIVE element segment, which materialises NO table slots and only
// forward-declares its funcs (<https://webassembly.github.io/spec/core/valid/modules.html>, elem
// segments; the reference-types proposal). An element segment's init items may also be a
// `global.get` of an immutable reference global (a constant expression, spec §3.3.1 / §4.5.4),
// resolved at instantiate time from the seeded `ref_globals`. `emit_core` now emits both: a
// declarative segment is a no-op init, and a `global.get` element item reads the reference global.

/// A module exercising BOTH Gap-2 emit paths WITHOUT any (unsupported) cross-module import:
/// a declarative segment declares `$f`; a defined immutable funcref global `$g` is initialised
/// `ref.func $f`; an ACTIVE element segment seeds table slot 0 from `(global.get $g)`; and
/// `call0` dispatches `call_indirect $t0` into that global-initialised slot.
pub fn ref_func_declarative_and_global_init_elem_e2e_test() {
  let target =
    ir.Function(
      "f",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.Let(
        ["r"],
        ir.Num(ir.IMul(ir.W32), [ir.Var("x"), ir.ConstI32(2)]),
        ir.Return([ir.Var("r")]),
      ),
    )
  let call0 =
    ir.Function(
      "call0",
      [ir.Local("idx", ir.TI32)],
      [ir.TI32],
      [],
      ir.CallIndirect("t0", ir.Var("idx"), ir.FuncType([ir.TI32], [ir.TI32]), [
        ir.ConstI32(21),
      ]),
    )
  let m =
    ir.Module(
      name: "twocore@e2e@reffunc_decl_globalinit",
      uses_numerics: True,
      memories: [],
      // `$g : funcref = ref.func $f` (an immutable reference global, R8).
      globals: [ir.GlobalDecl("g", ir.TFuncRef, False, ir.RefFunc("f"))],
      imports: [],
      functions: [target, call0],
      exports: [ir.ExportFn("call0", "call0")],
      data_segments: [],
      tables: [ir.TableDecl("t0", ir.FuncRef, 4, option.None)],
      elements: [
        // Declarative segment: NO table slots, only declares `$f` for `ref.func` — a no-op init.
        ir.ElementSegment(ir.ElemDeclarative, ir.FuncRef, [ir.RefFunc("f")]),
        // Active segment whose init item is `(global.get $g)` — placed into t0 slot 0.
        ir.ElementSegment(
          ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
          ir.FuncRef,
          [ir.GlobalGet("g")],
        ),
      ],
      start: option.None,
      tags: [],
    )
  // The module EMITS (no `UnsupportedNode`) and instantiates, and the global-initialised slot is
  // the funcref of `$f`: `call0(21) == 42` (`f(x) = x*2`).
  let mod = load(m)
  instantiate(mod)
  assert catch_apply(mod, atom.create("call0"), [0]) == Ok(42)
}

// ════════════════════ Phase-6: SIMD + memory64 + cross-module, end-to-end ════════════════════
//
// The FIRST real runs of the Phase-6 surface on the BEAM (P6-06). Hand-built IR4 modules using
// `v128` arithmetic, the v128 memory family, a 64-bit-addressed memory, a `v128` global, and a
// cross-module `CallImport` compile → load → invoke, asserting SPEC-CORRECT results (the SIMD spec
// / memory64 proposal / spec §4.5.4). SIMD is emulated lane-wise via the completed `rt_simd`
// (faithful, I3); memory64 through the completed `rt_mem` seam (S4/S9); the cross-module dispatch
// through the frozen `link.call_import` closure capability (S5). Each result is the value the spec
// mandates, computed THROUGH the real codegen — not a re-derivation of the runtime.

// Raw `erlang:apply/3` (no trap capture) — builds the cross-module dispatch closure.
@external(erlang, "twocore_emit_test_ffi", "apply3")
fn apply3(module: Atom, function: Atom, args: List(Dynamic)) -> Dynamic

// Coerce a `Dynamic` result to the 16-byte `v128` `BitArray` it is at runtime (identity coercion).
@external(erlang, "gleam_stdlib", "identity")
fn coerce_bitarray(d: Dynamic) -> BitArray

/// Build a v128 `BitArray` from `lanes`, each `w` bits wide, little-endian (D5) — the wire form a
/// v128 crosses the invoke ABI as (S14). `w * len(lanes) == 128`.
fn v128_of(lanes: List(Int), w: Int) -> BitArray {
  list.fold(lanes, <<>>, fn(acc, lane) { <<acc:bits, lane:size(w)-little>> })
}

/// Invoke exported `name` on `mod` with 16-byte `v128` `BitArray` arguments, returning the 16-byte
/// `v128` result (or the trap text). The v128 invoke ABI is 16 raw little-endian bytes (S14).
fn call_v128(
  mod: Atom,
  name: String,
  args: List(BitArray),
) -> Result(BitArray, String) {
  case catch_apply_dyn(mod, atom.create(name), list.map(args, to_dynamic)) {
    Ok(d) -> Ok(coerce_bitarray(d))
    Error(e) -> Error(e)
  }
}

/// A pure two-v128 SIMD binary function `name(a, b) = Simd(op, [a, b])`, `TV128 → TV128`.
fn simd_binop_fn(name: String, op: ir.SimdOp) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("a", ir.TV128), ir.Local("b", ir.TV128)],
    result: [ir.TV128],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.Simd(op, [ir.Var("a"), ir.Var("b")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// `i32x4.add` wraps two's-complement AT THE LANE WIDTH (32), never 128-bit (§SIMD/§9.1): lane-wise
/// `[1,2,3,0x7FFFFFFF] + [10,20,30,1] = [11,22,33,0x80000000]` (the top lane overflows to INT_MIN,
/// the unsigned bit pattern `2147483648`), proven THROUGH codegen → `rt_simd:i32x4_add`.
pub fn simd_i32x4_add_e2e_test() {
  let mod = load(module("s0", [simd_binop_fn("add4", ir.SAdd(ir.I32x4))]))
  let a = v128_of([1, 2, 3, 2_147_483_647], 32)
  let b = v128_of([10, 20, 30, 1], 32)
  assert call_v128(mod, "add4", [a, b])
    == Ok(v128_of([11, 22, 33, 2_147_483_648], 32))
}

/// `i8x16.add` wraps at 8 bits per lane: `250 + 10 == 4` (mod 256), the classic lane-narrow-wrap
/// corner (a 128-bit add would carry across lanes — this proves it does NOT).
pub fn simd_i8x16_add_e2e_test() {
  let mod = load(module("s1", [simd_binop_fn("add16", ir.SAdd(ir.I8x16))]))
  let a = v128_of([250, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], 8)
  let b = v128_of([10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 8)
  assert call_v128(mod, "add16", [a, b])
    == Ok(v128_of([4, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], 8))
}

/// `f32x4.mul` is IEEE-754 f32-exact per lane (the raw bit patterns route straight to
/// `rt_num.f32_mul` via `rt_simd:f32x4_mul`): `[1.5,2.0,0.5,4.0] * [2.0,3.0,8.0,0.25] =
/// [3.0,6.0,4.0,1.0]`, asserted on the raw f32 bit patterns (D5).
pub fn simd_f32x4_mul_e2e_test() {
  let mod = load(module("s2", [simd_binop_fn("mul4", ir.SFMul(ir.F32x4))]))
  // f32 bit patterns: 1.5=0x3FC00000 2.0=0x40000000 0.5=0x3F000000 4.0=0x40800000
  let a = v128_of([0x3FC0_0000, 0x4000_0000, 0x3F00_0000, 0x4080_0000], 32)
  // 2.0 3.0=0x40400000 8.0=0x41000000 0.25=0x3E800000
  let b = v128_of([0x4000_0000, 0x4040_0000, 0x4100_0000, 0x3E80_0000], 32)
  // 3.0=0x40400000 6.0=0x40C00000 4.0=0x40800000 1.0=0x3F800000
  assert call_v128(mod, "mul4", [a, b])
    == Ok(v128_of([0x4040_0000, 0x40C0_0000, 0x4080_0000, 0x3F80_0000], 32))
}

/// `i8x16.shuffle` selects 16 bytes from `a ++ b` by 16 immediate indices (spec `shuffle`): the
/// identity-of-`a` indices `[0..15]` yield `a`; interleaving `[0,16,1,17,…]` picks alternating
/// bytes of `a` and `b`. Proven through the dedicated `SimdShuffle` node → `rt_simd:i8x16_shuffle`.
pub fn simd_shuffle_e2e_test() {
  let shuffle_fn =
    ir.Function(
      name: "shuf",
      params: [ir.Local("a", ir.TV128), ir.Local("b", ir.TV128)],
      result: [ir.TV128],
      locals: [],
      // interleave low bytes of a and b: out = [a0,b0,a1,b1,...,a7,b7]
      body: ir.Let(
        ["r"],
        ir.SimdShuffle(
          [0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23],
          ir.Var("a"),
          ir.Var("b"),
        ),
        ir.Return([ir.Var("r")]),
      ),
    )
  let mod = load(module("s3", [shuffle_fn]))
  let a = v128_of([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], 8)
  let b =
    v128_of(
      [
        100,
        101,
        102,
        103,
        104,
        105,
        106,
        107,
        108,
        109,
        110,
        111,
        112,
        113,
        114,
        115,
      ],
      8,
    )
  assert call_v128(mod, "shuf", [a, b])
    == Ok(v128_of(
      [0, 100, 1, 101, 2, 102, 3, 103, 4, 104, 5, 105, 6, 106, 7, 107],
      8,
    ))
}

/// `i8x16.swizzle` — dynamic byte select with the OOB-index → 0 corner (spec `swizzle`): index `20`
/// (≥ 16) yields a zero byte, index `3` yields `a[3]`. Proven through `Simd(SSwizzle, [a, idx])`.
pub fn simd_swizzle_oob_zero_e2e_test() {
  let mod = load(module("s4", [simd_binop_fn("swz", ir.SSwizzle)]))
  let a =
    v128_of([10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25], 8)
  // indices: pick a[3]=13, a[0]=10, then OOB 20→0, 200→0, rest 0
  let idx = v128_of([3, 0, 20, 200, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 8)
  assert call_v128(mod, "swz", [a, idx])
    == Ok(v128_of(
      [13, 10, 0, 0, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10],
      8,
    ))
}

/// `i32x4.extract_lane` yields the raw i32 lane (the immediate rides last, `extract_lane(vec,
/// lane)`); `i8x16.replace_lane` writes one lane (the immediate rides MIDDLE, `replace_lane(vec,
/// lane, x)` — the frozen rt_simd head order). Proven through the `simd_call_args` splice.
pub fn simd_extract_replace_lane_e2e_test() {
  let extract_fn =
    ir.Function(
      name: "ext2",
      params: [ir.Local("v", ir.TV128)],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        ["r"],
        ir.Simd(ir.SExtractLane(ir.I32x4, 2), [ir.Var("v")]),
        ir.Return([ir.Var("r")]),
      ),
    )
  let replace_fn =
    ir.Function(
      name: "rep3",
      params: [ir.Local("v", ir.TV128), ir.Local("x", ir.TI32)],
      result: [ir.TV128],
      locals: [],
      body: ir.Let(
        ["r"],
        ir.Simd(ir.SReplaceLane(ir.I8x16, 3), [ir.Var("v"), ir.Var("x")]),
        ir.Return([ir.Var("r")]),
      ),
    )
  let mod = load(module("s5", [extract_fn, replace_fn]))
  let v = v128_of([100, 200, 300, 400], 32)
  // extract lane 2 == 300
  assert catch_apply_dyn(mod, atom.create("ext2"), [to_dynamic(v)])
    == Ok(to_dynamic(300))
  // replace i8 lane 3 of an all-zero vec with the scalar 0xAB (a plain i32, not a v128)
  let z = v128_of([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 8)
  assert call_dyn_v128(mod, "rep3", [to_dynamic(z), to_dynamic(0xAB)])
    == Ok(v128_of([0, 0, 0, 0xAB, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 8))
}

/// Emit `module` under a custom `binding`, compile + load, return the module atom. Like `load/1`,
/// but lets a test pick the binding (e.g. `MeterOff` for a large memory64 grow whose fuel charge
/// would exceed the default budget — an orthogonal concern to the memory64 correctness under test).
fn load_binding(module: ir.Module, binding: instance.Binding) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(module, binding)
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

/// Invoke exported `name` with pre-built `Dynamic` args, coercing the result to the 16-byte v128.
fn call_dyn_v128(
  mod: Atom,
  name: String,
  args: List(Dynamic),
) -> Result(BitArray, String) {
  case catch_apply_dyn(mod, atom.create(name), args) {
    Ok(d) -> Ok(coerce_bitarray(d))
    Error(e) -> Error(e)
  }
}

/// A memory-bearing module (memory `idx_type`, `min` pages, no max) exporting `funcs`.
fn simd_mem_module(
  name: String,
  idx_type: ir.IdxType,
  min: Int,
  funcs: List(ir.Function),
) -> ir.Module {
  full(
    name,
    option.Some(ir.MemoryDecl(min, option.None, idx_type)),
    [],
    funcs,
    [],
    [],
    [],
    option.None,
  )
}

fn simd_store_v128_fn() -> ir.Function {
  ir.Function(
    name: "storev",
    params: [ir.Local("addr", ir.TI32), ir.Local("v", ir.TV128)],
    result: [],
    locals: [],
    body: ir.Let(
      [],
      ir.SimdStore(0, ir.Var("addr"), ir.Var("v"), 0),
      ir.Values([]),
    ),
  )
}

fn simd_load_v128_fn() -> ir.Function {
  ir.Function(
    name: "loadv",
    params: [ir.Local("addr", ir.TI32)],
    result: [ir.TV128],
    locals: [],
    body: ir.SimdLoad(0, ir.LoadV128, ir.Var("addr"), 0),
  )
}

/// `v128.store` then `v128.load` round-trips 16 bytes through the bounds-checked `rt_mem` byte-slice
/// seam (S4) — the stored little-endian lanes read back verbatim. Proven THROUGH codegen (the 16
/// bytes ARE the v128, no lane assembly).
pub fn simd_mem_store_load_roundtrip_e2e_test() {
  let mod =
    load(
      simd_mem_module("sm0", ir.Idx32, 1, [
        simd_store_v128_fn(),
        simd_load_v128_fn(),
      ]),
    )
  instantiate(mod)
  let v = v128_of([0xDEAD_BEEF, 0x0BAD_F00D, 0x1234_5678, 0x9ABC_DEF0], 32)
  let _ =
    catch_apply_dyn(mod, atom.create("storev"), [to_dynamic(16), to_dynamic(v)])
  assert call_dyn_v128(mod, "loadv", [to_dynamic(16)]) == Ok(v)
}

/// `v128.load32_splat` broadcasts a 4-byte scalar into every i32 lane (S4: scalar `rt_mem.load` +
/// `i32x4_splat`). Store `0x11223344` at byte 0, then `load32_splat` at 0 → `[0x11223344 × 4]`.
pub fn simd_load32_splat_e2e_test() {
  let splat_fn =
    ir.Function(
      name: "splat",
      params: [ir.Local("addr", ir.TI32)],
      result: [ir.TV128],
      locals: [],
      body: ir.SimdLoad(0, ir.LoadSplat(32), ir.Var("addr"), 0),
    )
  let store32 =
    ir.Function(
      name: "st32",
      params: [ir.Local("addr", ir.TI32), ir.Local("v", ir.TI32)],
      result: [],
      locals: [],
      body: ir.Let(
        [],
        ir.MemStore(0, ir.MemAccess(4, False), ir.Var("addr"), ir.Var("v"), 0),
        ir.Values([]),
      ),
    )
  let mod = load(simd_mem_module("sm1", ir.Idx32, 1, [splat_fn, store32]))
  instantiate(mod)
  let _ = catch_apply(mod, atom.create("st32"), [0, 0x1122_3344])
  assert call_dyn_v128(mod, "splat", [to_dynamic(0)])
    == Ok(v128_of([0x1122_3344, 0x1122_3344, 0x1122_3344, 0x1122_3344], 32))
}

/// `v128.load64_zero` places the low 8 bytes into lane 0 and ZEROES the high lane (S4: `load_bytes(8)`
/// + `v128_load_zero(_, 64)`). Store `0x00000000FFFFFFFF` at byte 0, `load64_zero` at 0 → that i64 in
/// the low lane, `0` in the high lane.
pub fn simd_load64_zero_e2e_test() {
  let zero_fn =
    ir.Function(
      name: "lz",
      params: [ir.Local("addr", ir.TI32)],
      result: [ir.TV128],
      locals: [],
      body: ir.SimdLoad(0, ir.LoadZero(64), ir.Var("addr"), 0),
    )
  let store64 =
    ir.Function(
      name: "st64",
      params: [ir.Local("addr", ir.TI32), ir.Local("v", ir.TI64)],
      result: [],
      locals: [],
      body: ir.Let(
        [],
        ir.MemStore(0, ir.MemAccess(8, False), ir.Var("addr"), ir.Var("v"), 0),
        ir.Values([]),
      ),
    )
  let mod = load(simd_mem_module("sm2", ir.Idx32, 1, [zero_fn, store64]))
  instantiate(mod)
  let _ = catch_apply(mod, atom.create("st64"), [0, 0x0000_0000_FFFF_FFFF])
  assert call_dyn_v128(mod, "lz", [to_dynamic(0)])
    == Ok(v128_of([0x0000_0000_FFFF_FFFF, 0], 64))
}

/// An out-of-range `v128.load` traps `MemoryOutOfBounds` (the `rt_mem` byte-slice seam owns the
/// bounds check, H6) — NO host escape, no partial read. A load at byte 65534 (last 2 bytes of a
/// 1-page memory) needs 16 bytes → `ea + 16 > 65536` → trap.
pub fn simd_mem_oob_load_traps_e2e_test() {
  let mod = load(simd_mem_module("sm3", ir.Idx32, 1, [simd_load_v128_fn()]))
  instantiate(mod)
  let assert Error(reason) =
    catch_apply_dyn(mod, atom.create("loadv"), [to_dynamic(65_534)])
  assert string.contains(reason, "wasm_trap")
  assert string.contains(reason, "memory_out_of_bounds")
}

/// `v128.store8_lane` writes exactly ONE byte (lane 2 of an i8x16, `v128_extract_lane_bits(v, 2, 8)`
/// then scalar `rt_mem.store(1)`), leaving neighbours untouched. Store lane 2 (byte value `0xAB`) at
/// address 3, then read byte 3 back → `0xAB`, byte 4 → `0`.
pub fn simd_store8_lane_e2e_test() {
  let store_lane =
    ir.Function(
      name: "stl",
      params: [ir.Local("addr", ir.TI32), ir.Local("v", ir.TV128)],
      result: [],
      locals: [],
      body: ir.Let(
        [],
        ir.SimdStoreLane(0, 8, ir.Var("addr"), 0, 2, ir.Var("v")),
        ir.Values([]),
      ),
    )
  let load8u =
    ir.Function(
      name: "l8",
      params: [ir.Local("addr", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.MemLoad(0, ir.MemAccess(1, False), ir.Var("addr"), 0, ir.TI32),
    )
  let mod = load(simd_mem_module("sm4", ir.Idx32, 1, [store_lane, load8u]))
  instantiate(mod)
  let v = v128_of([1, 2, 0xAB, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16], 8)
  let _ =
    catch_apply_dyn(mod, atom.create("stl"), [to_dynamic(3), to_dynamic(v)])
  assert catch_apply(mod, atom.create("l8"), [3]) == Ok(0xAB)
  assert catch_apply(mod, atom.create("l8"), [4]) == Ok(0)
}

// ──────────────────────────── memory64 (I4/S9) ────────────────────────────

fn mem64_store32_fn() -> ir.Function {
  ir.Function(
    name: "st",
    params: [ir.Local("addr", ir.TI64), ir.Local("v", ir.TI32)],
    result: [],
    locals: [],
    body: ir.Let(
      [],
      ir.MemStore(0, ir.MemAccess(4, False), ir.Var("addr"), ir.Var("v"), 0),
      ir.Values([]),
    ),
  )
}

fn mem64_load32u_fn() -> ir.Function {
  ir.Function(
    name: "ld",
    params: [ir.Local("addr", ir.TI64)],
    result: [ir.TI32],
    locals: [],
    body: ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("addr"), 0, ir.TI32),
  )
}

fn mem64_grow_fn() -> ir.Function {
  ir.Function(
    name: "grow",
    params: [ir.Local("d", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Let(["r"], ir.MemGrow(0, ir.Var("d")), ir.Return([ir.Var("r")])),
  )
}

fn mem64_size_fn() -> ir.Function {
  ir.Function(
    name: "size",
    params: [],
    result: [ir.TI64],
    locals: [],
    body: ir.Let(["r"], ir.MemSize(0), ir.Return([ir.Var("r")])),
  )
}

/// A 64-bit memory RUNS: after growing past 2³² bytes, a store+load at an address ≥ 2³² round-trips
/// (i64 addressing / 64-bit bounds — memory64 is transparent at the op sites, the width lives in the
/// `fresh64` handle, §D/S9), and `memory.size` returns the i64 page count. Runs under `MeterOff` so
/// the (necessarily large) grow's proportional fuel charge — orthogonal to the correctness under
/// test — does not trip the default budget. The paged backend grows the page count sparsely (it does
/// NOT allocate 2⁴⁸ bytes — I4).
pub fn memory64_large_address_e2e_test() {
  let binding =
    instance.Binding(..instance.safe_default(), meter: instance.MeterOff)
  let mod =
    load_binding(
      simd_mem_module("mm0", ir.Idx64, 1, [
        mem64_store32_fn(),
        mem64_load32u_fn(),
        mem64_grow_fn(),
        mem64_size_fn(),
      ]),
      binding,
    )
  instantiate(mod)
  // `rt_mem.grow` unconditionally charges fuel proportional to the pages added (a big grow is not
  // O(1)-cheap); gleeunit shares one process across test fns, so a PRIOR test's seeded fuel budget
  // could persist and trip the (large) grow below. Seed a generous budget so fuel — orthogonal to
  // the memory64 correctness under test — is a non-factor (and reset the counter).
  rt_meter.seed_fuel(1_000_000_000_000)
  // Grow from 1 to 65537 pages (byte 2³² is the first byte of page 65536 → need ≥ 65537 pages).
  assert catch_apply(mod, atom.create("grow"), [65_536]) == Ok(1)
  assert catch_apply(mod, atom.create("size"), []) == Ok(65_537)
  // Store/load at byte 2³² + 40 (address exceeds 2³²).
  let addr = 4_294_967_336
  let _ = catch_apply(mod, atom.create("st"), [addr, 0xCAFE_BABE])
  assert catch_apply(mod, atom.create("ld"), [addr]) == Ok(0xCAFE_BABE)
}

/// A 64-bit `memory.grow` beyond the documented page cap returns `-1` (NEVER a trap; nothing
/// allocated, S9), and an access beyond the CURRENT size traps `MemoryOutOfBounds` (I4/I6). Both are
/// `rt_mem`'s trap boundary; the default (MeterFuel) binding is used — a `-1` grow charges no fuel,
/// and an OOB access traps immediately.
pub fn memory64_grow_cap_and_oob_e2e_test() {
  let mod =
    load(
      simd_mem_module("mm1", ir.Idx64, 1, [
        mem64_load32u_fn(),
        mem64_grow_fn(),
      ]),
    )
  instantiate(mod)
  // Grow by more than the 2³²-page cap → -1 (no allocation).
  assert catch_apply(mod, atom.create("grow"), [4_294_967_296]) == Ok(-1)
  // Access beyond the current 1-page size traps.
  let assert Error(reason) =
    catch_apply(mod, atom.create("ld"), [4_294_967_296])
  assert string.contains(reason, "wasm_trap")
  assert string.contains(reason, "memory_out_of_bounds")
}

/// An `Idx32` memory op emits the SAME op-site Core as an `Idx64` one (memory64 is transparent at
/// the op sites — the width lives in the handle, §D): a 32-bit store/load module computes exactly as
/// the 64-bit one for an in-range address, confirming the byte-identity of the scalar op path.
pub fn memory64_op_sites_match_idx32_e2e_test() {
  let mk = fn(nm, idx) {
    load(simd_mem_module(nm, idx, 1, [mem64_store32_fn(), mem64_load32u_fn()]))
  }
  let m32 = mk("mm32", ir.Idx32)
  let m64 = mk("mm64", ir.Idx64)
  instantiate(m32)
  instantiate(m64)
  let _ = catch_apply(m32, atom.create("st"), [8, 0x1234_5678])
  let _ = catch_apply(m64, atom.create("st"), [8, 0x1234_5678])
  assert catch_apply(m32, atom.create("ld"), [8])
    == catch_apply(m64, atom.create("ld"), [8])
  assert catch_apply(m64, atom.create("ld"), [8]) == Ok(0x1234_5678)
}

// ──────────────────────────── v128 global (S6) ────────────────────────────

/// A `v128` global routes through the BOXED `ref_globals` accessor (S6), not the numeric raw-bit
/// map: `global.get` reads the const init, `global.set` updates it, and the raw 16 bytes survive
/// (D5). Proven through `emit_global_get`/`set`'s boxed routing + the `ConstV128` global-init render.
pub fn v128_global_e2e_test() {
  let init = v128_of([1, 2, 3, 4], 32)
  let g = ir.GlobalDecl("g", ir.TV128, True, ir.Values([ir.ConstV128(init)]))
  let get_g =
    ir.Function(
      name: "getg",
      params: [],
      result: [ir.TV128],
      locals: [],
      body: ir.GlobalGet("g"),
    )
  let set_g =
    ir.Function(
      name: "setg",
      params: [ir.Local("v", ir.TV128)],
      result: [],
      locals: [],
      body: ir.Let([], ir.GlobalSet("g", ir.Var("v")), ir.Values([])),
    )
  let mod =
    load(full("gv", option.None, [g], [get_g, set_g], [], [], [], option.None))
  instantiate(mod)
  assert call_dyn_v128(mod, "getg", []) == Ok(init)
  let v2 = v128_of([9, 8, 7, 6], 32)
  let _ = catch_apply_dyn(mod, atom.create("setg"), [to_dynamic(v2)])
  assert call_dyn_v128(mod, "getg", []) == Ok(v2)
}

// ──────────────────────── cross-module CallImport (S5) ────────────────────────

/// A cross-module WASM→WASM function call: module B imports and CALLS module A's exported `add1`
/// through a linker-built dispatch closure (the `link.call_import` capability, S5/D3a). Both modules
/// are 2core-compiled; B's `CallImport(0, …)` reads the closure from its seeded func-import vector
/// and applies it — the closure routes into A's loaded `add1` (a genuine cross-module call; A's
/// function is pure, so it runs in the same process). `caller(41) == 42`, computed ACROSS instances.
pub fn cross_module_call_import_e2e_test() {
  // Module A: pure `add1(x) = x + 1`.
  let mod_a =
    load(
      module("modA", [
        ir.Function(
          name: "add1",
          params: [ir.Local("x", ir.TI32)],
          result: [ir.TI32],
          locals: [],
          body: ir.Let(
            ["r"],
            ir.Num(ir.IAdd(ir.W32), [ir.Var("x"), ir.ConstI32(1)]),
            ir.Return([ir.Var("r")]),
          ),
        ),
      ]),
    )
  let ty = ir.FuncType([ir.TI32], [ir.TI32])
  // The linker-built capability: route the call into A's exported `add1` (D3a — a handed-in closure,
  // never a data-named `module:atom` in generated code).
  let closure = fn(args: List(Dynamic)) -> List(Dynamic) {
    [apply3(mod_a, atom.create("add1"), args)]
  }
  let provided = link.provided_func(ty, closure)
  // Module B: `caller(x) = CallImport(0, ty, [x])` — imports and CALLS A's `add1`.
  let mod_b =
    load(
      ir.Module(
        name: "twocore@e2e@modB",
        uses_numerics: True,
        memories: [],
        globals: [],
        imports: [ir.ImportFn("modA", "add1", ty)],
        functions: [
          ir.Function(
            name: "caller",
            params: [ir.Local("x", ir.TI32)],
            result: [ir.TI32],
            locals: [],
            body: ir.CallImport(0, ty, [ir.Var("x")]),
          ),
        ],
        exports: [ir.ExportFn("caller", "caller")],
        data_segments: [],
        tables: [],
        elements: [],
        start: option.None,
        tags: [],
      ),
    )
  // Instantiate B with the positional func-import vector `[provided]` (S5), then invoke.
  let assert Ok(_) =
    catch_apply_dyn(mod_b, atom.create("instantiate"), [to_dynamic([provided])])
  assert catch_apply(mod_b, atom.create("caller"), [41]) == Ok(42)
  // And a second value, to confirm it is the real function, not a constant.
  assert catch_apply(mod_b, atom.create("caller"), [100]) == Ok(101)
}

// ════════════════════ Phase-7: exception handling END-TO-END (RUN on the BEAM) ════════════════════
//
// Hand-built EH IR compiled + loaded + RUN, asserting spec (the exception-handling proposal +
// core-spec §4.4.9): a `throw` unwinds to the nearest matching handler carrying its payload; an
// uncaught exception surfaces DISTINCTLY from a trap (T8); `catch_all` catches WASM exceptions but
// a TRAP propagates through it (spec §4.4); a non-matching tag re-raises (stacktrace-preserving);
// and `throw_ref` re-raises a captured exception. EH ships CELL-only (T6). These are the FIRST time
// WASM/JS exception handling runs end-to-end on the BEAM.

/// A one-page-memory EH module: `functions` (exported by name) carrying `tags`, under Cell.
fn eh_module_full(
  name: String,
  memory: option.Option(ir.MemoryDecl),
  functions: List(ir.Function),
  tags: List(ir.TagDecl),
) -> ir.Module {
  ir.Module(
    name: "twocore@ehe2e@" <> name,
    uses_numerics: True,
    memories: case memory {
      option.Some(m) -> [m]
      option.None -> []
    },
    globals: [],
    imports: [],
    functions: functions,
    exports: list.map(functions, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: tags,
  )
}

/// Emit + compile `module` to an in-memory `.beam` (for the `pipeline.invoke` run-ABI, which splits
/// an uncaught `{wasm_exn,…}` from a trap — T8). `let assert` is the test's success contract.
fn to_beam(module: ir.Module) -> BitArray {
  let assert Ok(cm) = emit_core.emit_module(module, instance.safe_default())
  let core = core_printer.print_module(cm)
  let assert Ok(#(_atom, beam)) =
    build_beam.compile_core(bit_array.from_string(core))
  beam
}

/// A tag carrying one i32 operand at some index (the Porffor-ish shape, reduced to i32 for the ABI).
fn tag1_i32(name: String) -> ir.TagDecl {
  ir.TagDecl(name, [ir.TI32])
}

/// **Uncaught throw → `UncaughtException`, DISTINCT from a trap (T8).** `boom(p0)` unconditionally
/// `throw`s `tag0(p0, 195)`; nothing catches it, so it unwinds out of the export as a WASM
/// exception. The run-ABI reports `UncaughtException(0, [p0, 195])` — the module-local tag index +
/// the operand payload — NOT `Trapped` (`assert_exception` ≠ `assert_trap`, spec §4.4.9).
pub fn eh_uncaught_throw_reports_uncaught_exception_e2e_test() {
  let boom =
    ir.Function(
      "boom",
      [ir.Local("p0", ir.TI32)],
      [ir.TI32],
      [],
      ir.Throw("tag0", [ir.Var("p0"), ir.ConstI32(195)]),
    )
  let m =
    eh_module_full("uncaught", option.None, [boom], [
      ir.TagDecl("tag0", [ir.TI32, ir.TI32]),
    ])
  let beam = to_beam(m)
  assert pipeline.invoke(beam, m.name, "boom", [16])
    == pipeline.UncaughtException(0, [16, 195])
}

/// **A trap stays `Trapped`, NOT `UncaughtException`.** A genuine runtime trap (i32 div-by-zero →
/// `{wasm_trap, int_div_by_zero}`, ERROR class) is a DIFFERENT run-ABI outcome from a WASM
/// exception — the split rests on the term shape (`{wasm_trap,_}` vs `{wasm_exn,_,_}`, T8).
pub fn eh_trap_stays_trapped_not_exception_e2e_test() {
  let dz =
    ir.Function(
      "dz",
      [ir.Local("p0", ir.TI32)],
      [ir.TI32],
      [],
      ir.Let(
        ["r"],
        ir.Num(ir.IDivS(ir.W32), [ir.Var("p0"), ir.ConstI32(0)]),
        ir.Return([ir.Var("r")]),
      ),
    )
  let m = eh_module_full("trapdz", option.None, [dz], [])
  let assert pipeline.Trapped(reason) =
    pipeline.invoke(to_beam(m), m.name, "dz", [10])
  assert string.contains(reason, "wasm_trap")
}

/// **A caught legacy `try/catch` recovers the payload (the Porffor shape).** `f(p0)` runs
/// `try { throw tag0(p0) } catch tag0 (p) { return p + 1 }` — the throw unwinds to the matching
/// handler, the `(p)` operand round-trips through the catch, and the handler yields `p + 1`. So
/// `f(5) → 6` and `f(-2) → -1` (the §Porffor `f(5)=6`/`f(-2)=-1` shape). Runs on the BEAM.
pub fn eh_caught_legacy_trycatch_recovers_value_e2e_test() {
  let f =
    ir.Function(
      "f",
      [ir.Local("p0", ir.TI32)],
      [ir.TI32],
      [],
      ir.Try([ir.TI32], ir.Throw("tag0", [ir.Var("p0")]), [
        ir.CatchHandler(
          ir.OnTag("tag0"),
          ["p"],
          option.None,
          ir.Let(
            ["r"],
            ir.Num(ir.IAdd(ir.W32), [ir.Var("p"), ir.ConstI32(1)]),
            ir.Return([ir.Var("r")]),
          ),
        ),
      ]),
    )
  let mod = load(eh_module_full("caught", option.None, [f], [tag1_i32("tag0")]))
  assert catch_apply(mod, atom.create("f"), [5]) == Ok(6)
  // -2 as the unsigned i32 bit pattern 4294967294 → -1 (4294967295): the payload rode through.
  assert catch_apply(mod, atom.create("f"), [4_294_967_294])
    == Ok(4_294_967_295)
}

/// **`catch_all` catches a WASM exception.** `h(p0)` runs `try { throw tag0(p0) } catch_all
/// { return 42 }` — the thrown exception is caught by the catch-all and the handler's `42` is
/// yielded. Runs on the BEAM.
pub fn eh_catch_all_catches_wasm_exn_e2e_test() {
  let h =
    ir.Function(
      "h",
      [ir.Local("p0", ir.TI32)],
      [ir.TI32],
      [],
      ir.Try([ir.TI32], ir.Throw("tag0", [ir.Var("p0")]), [
        ir.CatchHandler(ir.OnAll, [], option.None, ir.Return([ir.ConstI32(42)])),
      ]),
    )
  let mod =
    load(eh_module_full("catchall", option.None, [h], [tag1_i32("tag0")]))
  assert catch_apply(mod, atom.create("h"), [7]) == Ok(42)
}

/// **A TRAP propagates through `catch_all` (spec §4.4 — the sandbox floor, T7).** `g(addr)` runs
/// `try { i32.load addr } catch_all { return 999 }` around a load that is OUT OF BOUNDS at
/// `addr = 0xFFFFFF00` (one page = 65536 bytes). The load traps `MemoryOutOfBounds`; `is_wasm_exn`
/// is false for a `{wasm_trap,_}`, so the trap PROPAGATES uncaught — it must NOT land at the
/// catch_all handler. The result is the trap, never `Ok(999)`.
pub fn eh_trap_propagates_through_catch_all_e2e_test() {
  let g =
    ir.Function(
      "g",
      [ir.Local("addr", ir.TI32)],
      [ir.TI32],
      [],
      ir.Try(
        [ir.TI32],
        ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("addr"), 0, ir.TI32),
        [
          ir.CatchHandler(
            ir.OnAll,
            [],
            option.None,
            ir.Return([ir.ConstI32(999)]),
          ),
        ],
      ),
    )
  let mod =
    load(
      eh_module_full(
        "trapthrutry",
        option.Some(ir.MemoryDecl(1, option.None, ir.Idx32)),
        [g],
        [tag1_i32("tag0")],
      ),
    )
  instantiate(mod)
  // an in-bounds load succeeds (proves the try body's normal path works) …
  assert catch_apply(mod, atom.create("g"), [0]) == Ok(0)
  // … but an OOB load TRAPS through the catch_all — never the handler's 999.
  let assert Error(reason) = catch_apply(mod, atom.create("g"), [4_294_967_040])
  assert string.contains(reason, "memory_out_of_bounds")
}

/// **A non-matching tag RE-RAISES (uncaught).** `r(p0)` runs `try { throw tag1(p0) } catch tag0 (p)
/// { return p }` — `tag1 ≠ tag0`, so the handler does not match and the exception re-raises past the
/// `try` (spec §4.4.9, stacktrace-preserving). Uncaught, it surfaces as `UncaughtException(1, [p0])`
/// — the RE-RAISED tag's index (1) + its payload, proving the re-raise carries the original exn.
pub fn eh_non_matching_tag_reraises_e2e_test() {
  let r =
    ir.Function(
      "r",
      [ir.Local("p0", ir.TI32)],
      [ir.TI32],
      [],
      ir.Try([ir.TI32], ir.Throw("tag1", [ir.Var("p0")]), [
        ir.CatchHandler(
          ir.OnTag("tag0"),
          ["p"],
          option.None,
          ir.Return([
            ir.Var("p"),
          ]),
        ),
      ]),
    )
  let m =
    eh_module_full("reraise", option.None, [r], [
      tag1_i32("tag0"),
      tag1_i32("tag1"),
    ])
  assert pipeline.invoke(to_beam(m), m.name, "r", [16])
    == pipeline.UncaughtException(1, [16])
}

/// **`throw_ref` re-raises a captured exnref (T9).** `tr(p0)` nests: the INNER `try { throw tag0(p0)
/// } catch_ref tag0 (as e) { throw_ref e }` captures the caught exception as an opaque `exnref` and
/// re-raises it; the OUTER `try … catch tag0 (p) { return p }` then catches the re-raised exception
/// by tag and recovers its payload. So `tr(9) → 9` — the captured exception round-tripped through
/// `capture`/`throw_ref`. (Porffor-inert modern surface; proves the exnref path on the BEAM.)
pub fn eh_throw_ref_reraises_captured_exn_e2e_test() {
  let inner =
    ir.Try([ir.TI32], ir.Throw("tag0", [ir.Var("p0")]), [
      ir.CatchHandler(
        ir.OnTag("tag0"),
        ["q"],
        option.Some("e"),
        ir.ThrowRef(ir.Var("e")),
      ),
    ])
  let tr =
    ir.Function(
      "tr",
      [ir.Local("p0", ir.TI32)],
      [ir.TI32],
      [],
      ir.Try([ir.TI32], inner, [
        ir.CatchHandler(
          ir.OnTag("tag0"),
          ["p"],
          option.None,
          ir.Return([
            ir.Var("p"),
          ]),
        ),
      ]),
    )
  let mod =
    load(eh_module_full("throwref", option.None, [tr], [tag1_i32("tag0")]))
  assert catch_apply(mod, atom.create("tr"), [9]) == Ok(9)
}
