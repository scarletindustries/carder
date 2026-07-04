//// Phase-8 unit 01 — term construction & destructuring, end-to-end on the BEAM.
////
//// Spec-first (CLAUDE.md D8 / overview §Acceptance): each test authors a small IR
//// `Module` that builds or takes apart a BEAM term via the Phase-8 `TermOp` layer + the
//// two new `Value` term literals (`ConstAtom`/`ConstBinary`), lowers it IR → `emit_core`
//// → `build_beam` → a loaded `.beam`, invokes an export with `erlang:apply`, and asserts
//// the **value** — never the emitted bytes. Results are asserted against defined BEAM
//// semantics (a tuple `{1,2,3}`, a list `[1,2]`, `erlang:element/hd/tl/tuple_size`, an
//// atom, a binary), matching the unit-01 spec's Tests section.
////
//// The harness (`load`/`module`/`catch_apply_dyn`/`to_dynamic`) mirrors
//// `emit_core_e2e_test.gleam` exactly — an IR module is compiled, loaded, and its exports
//// applied; term results are compared as `Dynamic` (BEAM term equality).

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/ir
import twocore/runtime/instance

// Test-only FFI (see `test/twocore_emit_test_ffi.erl`): apply `M:F(Args)` and capture a
// raise as `Error(text)`. Re-typed for `Dynamic` args/results (a term may be a tuple, list,
// atom, or binary), which is sound because `erlang:apply` is untyped at runtime.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply_dyn(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

// Coerce any Gleam value to `Dynamic` (identity at runtime) — to build `Dynamic` arg lists
// and expected-value comparisons.
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

// ───────────────────────────── plumbing ─────────────────────────────

/// Emit `module` to Core text, compile it, and load it into the test VM; return the loaded
/// module atom. `let assert` is the success contract — a failure to emit/compile/load is a
/// genuine test failure.
fn load(module: ir.Module) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(module, instance.safe_default())
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

/// Build a term-layer module wrapping `functions`, exporting each by name. `uses_numerics`
/// is on (the term functions carry i32 constants); no memory is linked.
fn module(name: String, functions: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "twocore@term@" <> name,
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

/// A zero-parameter function named `name` returning one `ty`-typed value produced by `body`.
fn fn0(name: String, ty: ir.ValType, body: ir.Expr) -> ir.Function {
  ir.Function(name: name, params: [], result: [ty], locals: [], body: body)
}

/// A one-parameter (`p0 : TTerm`) function named `name` returning one `ty`-typed value
/// produced by `body`. Used where the test supplies a BEAM term (e.g. the empty list `[]` or
/// a list `[1,2]`) as the operand.
fn fn1(name: String, ty: ir.ValType, body: ir.Expr) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("p0", ir.TTerm)],
    result: [ty],
    locals: [],
    body: body,
  )
}

fn i32(n: Int) -> ir.Value {
  ir.ConstI32(n)
}

// A typed empty list `[]` (a BEAM term), passed to `fn1` exports as the nil tail / operand.
fn empty_list() -> List(Int) {
  []
}

// ───────────────────────────── tuples: make / get / size ─────────────────────────────

/// `MakeTuple [1,2,3]` builds the exact BEAM tuple `{1,2,3}`; `TupleGet(1)` of it is `2`
/// (0-based IR index → `erlang:element(2, T)`); `TupleSize` of it is `3`
/// (`erlang:tuple_size/1`). Asserted as values, never bytes.
pub fn tuple_make_get_size_e2e_test() {
  // build_tuple() -> {1,2,3}   (fall-through yields the constructed tuple)
  let build =
    fn0("build", ir.TTerm, ir.TermOp(ir.MakeTuple, [i32(1), i32(2), i32(3)]))
  // get1() -> element(2, {1,2,3}) == 2
  let get1 =
    fn0(
      "get1",
      ir.TTerm,
      ir.Let(
        ["t"],
        ir.TermOp(ir.MakeTuple, [i32(1), i32(2), i32(3)]),
        ir.TermOp(ir.TupleGet(1), [ir.Var("t")]),
      ),
    )
  // size3() -> tuple_size({1,2,3}) == 3
  let size3 =
    fn0(
      "size3",
      ir.TI32,
      ir.Let(
        ["t"],
        ir.TermOp(ir.MakeTuple, [i32(1), i32(2), i32(3)]),
        ir.TermOp(ir.TupleSize, [ir.Var("t")]),
      ),
    )
  let mod = load(module("tuple", [build, get1, size3]))

  assert catch_apply_dyn(mod, atom.create("build"), [])
    == Ok(to_dynamic(#(1, 2, 3)))
  assert catch_apply_dyn(mod, atom.create("get1"), []) == Ok(to_dynamic(2))
  assert catch_apply_dyn(mod, atom.create("size3"), []) == Ok(to_dynamic(3))
}

// ───────────────────────────── lists: cons / head / tail / is_empty ─────────────────────────────

/// `MakeCons(1, MakeCons(2, []))` builds the BEAM list `[1,2]`; `ListHead [1,2]` is `1`
/// (`erlang:hd`); `ListTail [1,2]` is `[2]` (`erlang:tl`); `IsEmptyList` is the i32 truth
/// value `1` for `[]` and `0` for a non-empty list. The empty-list tail/operand is supplied
/// as the export argument `p0` (the IR has no nil literal — spec "ConstNil-ish").
pub fn list_cons_head_tail_is_empty_e2e_test() {
  // cons2(p0) -> [1 | [2 | p0]]  ; call with [] to get [1,2]
  let cons2 =
    fn1(
      "cons2",
      ir.TTerm,
      ir.Let(
        ["inner"],
        ir.TermOp(ir.MakeCons, [i32(2), ir.Var("p0")]),
        ir.TermOp(ir.MakeCons, [i32(1), ir.Var("inner")]),
      ),
    )
  // head(p0) -> hd(p0)
  let head = fn1("head", ir.TTerm, ir.TermOp(ir.ListHead, [ir.Var("p0")]))
  // tail(p0) -> tl(p0)
  let tail = fn1("tail", ir.TTerm, ir.TermOp(ir.ListTail, [ir.Var("p0")]))
  // is_empty(p0) -> 1 if p0 == [] else 0
  let is_empty =
    fn1("is_empty", ir.TI32, ir.TermOp(ir.IsEmptyList, [ir.Var("p0")]))
  let mod = load(module("list", [cons2, head, tail, is_empty]))

  // MakeCons builds [1,2] from the passed-in nil tail.
  assert catch_apply_dyn(mod, atom.create("cons2"), [to_dynamic(empty_list())])
    == Ok(to_dynamic([1, 2]))
  // ListHead / ListTail destructure a supplied [1,2].
  assert catch_apply_dyn(mod, atom.create("head"), [to_dynamic([1, 2])])
    == Ok(to_dynamic(1))
  assert catch_apply_dyn(mod, atom.create("tail"), [to_dynamic([1, 2])])
    == Ok(to_dynamic([2]))
  // IsEmptyList: [] -> 1, [1] -> 0 (an i32 truth value).
  assert catch_apply_dyn(mod, atom.create("is_empty"), [
      to_dynamic(empty_list()),
    ])
    == Ok(to_dynamic(1))
  assert catch_apply_dyn(mod, atom.create("is_empty"), [to_dynamic([1])])
    == Ok(to_dynamic(0))
}

// ───────────────────────────── term literals: atom / binary ─────────────────────────────

/// `ConstAtom("ok")` yields the BEAM atom `ok`; `ConstBinary(<<"hi">>)` yields the BEAM
/// binary `<<"hi">>`. Both are forwarded through `Values` and returned unchanged.
pub fn atom_and_binary_literal_e2e_test() {
  let get_atom = fn0("get_atom", ir.TTerm, ir.Values([ir.ConstAtom("ok")]))
  let get_bin = fn0("get_bin", ir.TTerm, ir.Values([ir.ConstBinary(<<"hi">>)]))
  let mod = load(module("lit", [get_atom, get_bin]))

  assert catch_apply_dyn(mod, atom.create("get_atom"), [])
    == Ok(to_dynamic(atom.create("ok")))
  assert catch_apply_dyn(mod, atom.create("get_bin"), [])
    == Ok(to_dynamic(<<"hi">>))
}

/// `IsEmptyList` produces a genuine i32 truth value that drops into `If`: an `IsEmptyList`
/// result used as an `If` condition selects the then-branch for `[]` and the else-branch for
/// a non-empty list. Proves the "i32 truth value" contract (spec's IsEmptyList row) end to
/// end, not just the raw `1`/`0`.
pub fn is_empty_list_drives_if_e2e_test() {
  // classify(p0) -> if is_empty(p0) then 111 else 222
  let classify =
    fn1(
      "classify",
      ir.TI32,
      ir.Let(
        ["c"],
        ir.TermOp(ir.IsEmptyList, [ir.Var("p0")]),
        ir.If(
          cond: ir.Var("c"),
          result: [ir.TI32],
          then_branch: ir.Values([i32(111)]),
          else_branch: ir.Values([i32(222)]),
        ),
      ),
    )
  let mod = load(module("cond", [classify]))

  assert catch_apply_dyn(mod, atom.create("classify"), [
      to_dynamic(empty_list()),
    ])
    == Ok(to_dynamic(111))
  assert catch_apply_dyn(mod, atom.create("classify"), [to_dynamic([9])])
    == Ok(to_dynamic(222))
}
