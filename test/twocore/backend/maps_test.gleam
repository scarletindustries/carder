//// Phase-8 unit 03 — maps (the object substrate), end-to-end on the BEAM.
////
//// Spec-first (CLAUDE.md D8 / overview §Acceptance "objects / maps"): each test authors a
//// small IR `Module` that builds / queries / functionally-updates a BEAM map via the Phase-8
//// `MapOp` layer, lowers it IR → `emit_core` → `build_beam` → a loaded `.beam`, invokes an
//// export with `erlang:apply`, and asserts the **value** — never the emitted bytes. Results
//// are asserted against defined BEAM `maps` semantics (`maps:put`/`get`/`is_key`/`remove`/
//// `size`): a missing-key `MapGet` yields the supplied default (no `badkey`), `MapPut` returns
//// a NEW map, `MapHas`/`MapSize` yield i32 truth/count, chained puts build the expected map,
//// and a put over an existing key overwrites — matching the unit-03 spec's Tests section.
////
//// The `#{…}` oracle is a native `gleam/dict` (a BEAM map at runtime), built independently of
//// the ops under test. The harness (`load`/`module`/`catch_apply_dyn`/`to_dynamic`) mirrors
//// `term_ops_test.gleam`.

import gleam/bit_array
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/ir
import twocore/runtime/instance

// Test-only FFI (see `test/twocore_emit_test_ffi.erl`): apply `M:F(Args)` and capture a raise as
// `Error(text)`. Re-typed for `Dynamic` args/results (a term may be a map, atom, or int), sound
// because `erlang:apply` is untyped at runtime.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply_dyn(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

// Coerce any Gleam value to `Dynamic` (identity at runtime) — for expected-value comparisons.
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

/// Build a map-layer module wrapping `functions`, exporting each by name. `uses_numerics` is on
/// (the map functions carry i32 constants); no memory is linked.
fn module(name: String, functions: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "twocore@maps@" <> name,
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

fn i32(n: Int) -> ir.Value {
  ir.ConstI32(n)
}

fn key(name: String) -> ir.Value {
  ir.ConstAtom(name)
}

/// Body: bind `%m` to `#{x => 1}` (`MapPut` over `MapNew` — the empty map is bound to `%e`
/// first, since a `MapOp` operand must be an atomic `Value`), then evaluate `body` (which refers
/// to `%m`). The common fixture for the single-entry-map read/query tests.
fn with_map_x1(body: ir.Expr) -> ir.Expr {
  ir.Let(
    ["e"],
    ir.MapOp(ir.MapNew, []),
    ir.Let(["m"], ir.MapOp(ir.MapPut, [ir.Var("e"), key("x"), i32(1)]), body),
  )
}

/// The oracle `#{x => 1}` as a native BEAM map (a `gleam/dict`), built independently of the ops
/// under test.
fn map_x1() -> dict.Dict(Atom, Int) {
  dict.from_list([#(atom.create("x"), 1)])
}

// ───────────────────────────── build / get (+ default) ─────────────────────────────

/// `MapPut(MapNew, atom "x", 1)` builds the exact BEAM map `#{x => 1}`; `MapGet(that, atom "x",
/// 0)` is `1` (present ⇒ the stored value); `MapGet(that, atom "y", 999)` is `999` — a MISSING
/// key deterministically yields the supplied default, never a BEAM `badkey`. Asserted as values.
pub fn map_build_and_read_e2e_test() {
  // build() -> #{x => 1}
  let build = fn0("build", ir.TTerm, with_map_x1(ir.Values([ir.Var("m")])))
  // get_x() -> maps:get(x, #{x=>1}, 0) == 1
  let get_x =
    fn0(
      "get_x",
      ir.TTerm,
      with_map_x1(ir.MapOp(ir.MapGet, [ir.Var("m"), key("x"), i32(0)])),
    )
  // get_y() -> maps:get(y, #{x=>1}, 999) == 999  (default: missing key)
  let get_y =
    fn0(
      "get_y",
      ir.TTerm,
      with_map_x1(ir.MapOp(ir.MapGet, [ir.Var("m"), key("y"), i32(999)])),
    )
  let mod = load(module("read", [build, get_x, get_y]))

  assert catch_apply_dyn(mod, atom.create("build"), [])
    == Ok(to_dynamic(map_x1()))
  assert catch_apply_dyn(mod, atom.create("get_x"), []) == Ok(to_dynamic(1))
  assert catch_apply_dyn(mod, atom.create("get_y"), []) == Ok(to_dynamic(999))
}

// ───────────────────────────── has / size ─────────────────────────────

/// `MapHas(#{x=>1}, atom "x")` is the i32 truth value `1` (present); `MapHas(_, atom "y")` is `0`
/// (absent); `MapSize(#{x=>1})` is `1`. `MapHas`/`MapSize` produce genuine i32 values (spec: the
/// `is_key`→`1`/`0` case and `maps:size`).
pub fn map_has_and_size_e2e_test() {
  let has_x =
    fn0(
      "has_x",
      ir.TI32,
      with_map_x1(ir.MapOp(ir.MapHas, [ir.Var("m"), key("x")])),
    )
  let has_y =
    fn0(
      "has_y",
      ir.TI32,
      with_map_x1(ir.MapOp(ir.MapHas, [ir.Var("m"), key("y")])),
    )
  let size1 =
    fn0("size1", ir.TI32, with_map_x1(ir.MapOp(ir.MapSize, [ir.Var("m")])))
  let mod = load(module("query", [has_x, has_y, size1]))

  assert catch_apply_dyn(mod, atom.create("has_x"), []) == Ok(to_dynamic(1))
  assert catch_apply_dyn(mod, atom.create("has_y"), []) == Ok(to_dynamic(0))
  assert catch_apply_dyn(mod, atom.create("size1"), []) == Ok(to_dynamic(1))
}

// ───────────────────────────── remove ─────────────────────────────

/// `MapRemove(#{x=>1}, atom "x")` then `MapSize` is `0` (the key was removed — a NEW, now-empty
/// map). Removing an ABSENT key (`atom "y"`) is a no-op: `MapSize` is still `1`.
pub fn map_remove_e2e_test() {
  // remove_x() -> size(remove(x, #{x=>1})) == 0
  let remove_x =
    fn0(
      "remove_x",
      ir.TI32,
      with_map_x1(ir.Let(
        ["m2"],
        ir.MapOp(ir.MapRemove, [ir.Var("m"), key("x")]),
        ir.MapOp(ir.MapSize, [ir.Var("m2")]),
      )),
    )
  // remove_absent() -> size(remove(y, #{x=>1})) == 1  (no-op)
  let remove_absent =
    fn0(
      "remove_absent",
      ir.TI32,
      with_map_x1(ir.Let(
        ["m2"],
        ir.MapOp(ir.MapRemove, [ir.Var("m"), key("y")]),
        ir.MapOp(ir.MapSize, [ir.Var("m2")]),
      )),
    )
  let mod = load(module("remove", [remove_x, remove_absent]))

  assert catch_apply_dyn(mod, atom.create("remove_x"), []) == Ok(to_dynamic(0))
  assert catch_apply_dyn(mod, atom.create("remove_absent"), [])
    == Ok(to_dynamic(1))
}

// ───────────────────────────── chained puts / overwrite ─────────────────────────────

/// Chained `MapPut`s build the expected multi-entry map `#{x=>1, y=>2, z=>3}` (each put returns a
/// NEW map threaded into the next). A put over an EXISTING key overwrites: `put(put(new,x,1),x,2)`
/// is `#{x=>2}`, and `MapGet(_, x, 0)` reads back `2` (the later binding).
pub fn map_chained_puts_and_overwrite_e2e_test() {
  // build3() -> #{x=>1, y=>2, z=>3}
  let build3 =
    fn0(
      "build3",
      ir.TTerm,
      ir.Let(
        ["e"],
        ir.MapOp(ir.MapNew, []),
        ir.Let(
          ["m1"],
          ir.MapOp(ir.MapPut, [ir.Var("e"), key("x"), i32(1)]),
          ir.Let(
            ["m2"],
            ir.MapOp(ir.MapPut, [ir.Var("m1"), key("y"), i32(2)]),
            ir.MapOp(ir.MapPut, [ir.Var("m2"), key("z"), i32(3)]),
          ),
        ),
      ),
    )
  // overwrite() -> #{x=>2}   (second put over key x wins)
  let overwrite =
    fn0(
      "overwrite",
      ir.TTerm,
      ir.Let(
        ["e"],
        ir.MapOp(ir.MapNew, []),
        ir.Let(
          ["m1"],
          ir.MapOp(ir.MapPut, [ir.Var("e"), key("x"), i32(1)]),
          ir.MapOp(ir.MapPut, [ir.Var("m1"), key("x"), i32(2)]),
        ),
      ),
    )
  // overwrite_get() -> maps:get(x, #{x=>2}, 0) == 2
  let overwrite_get =
    fn0(
      "overwrite_get",
      ir.TTerm,
      ir.Let(
        ["e"],
        ir.MapOp(ir.MapNew, []),
        ir.Let(
          ["m1"],
          ir.MapOp(ir.MapPut, [ir.Var("e"), key("x"), i32(1)]),
          ir.Let(
            ["m2"],
            ir.MapOp(ir.MapPut, [ir.Var("m1"), key("x"), i32(2)]),
            ir.MapOp(ir.MapGet, [ir.Var("m2"), key("x"), i32(0)]),
          ),
        ),
      ),
    )
  let mod = load(module("chain", [build3, overwrite, overwrite_get]))

  let three =
    dict.from_list([
      #(atom.create("x"), 1),
      #(atom.create("y"), 2),
      #(atom.create("z"), 3),
    ])
  assert catch_apply_dyn(mod, atom.create("build3"), [])
    == Ok(to_dynamic(three))
  assert catch_apply_dyn(mod, atom.create("overwrite"), [])
    == Ok(to_dynamic(dict.from_list([#(atom.create("x"), 2)])))
  assert catch_apply_dyn(mod, atom.create("overwrite_get"), [])
    == Ok(to_dynamic(2))
}

// ───────────────────────────── MapHas drives If (i32 truth end to end) ─────────────────────────────

/// `MapHas` produces a genuine i32 truth value that drops into `If`: used as the condition it
/// selects the then-branch for a present key and the else-branch for an absent one. Proves the
/// "i32 truth value" contract (spec's `MapHas` row) end to end, not just the raw `1`/`0`.
pub fn map_has_drives_if_e2e_test() {
  let classify =
    fn0(
      "classify_x",
      ir.TI32,
      with_map_x1(ir.Let(
        ["c"],
        ir.MapOp(ir.MapHas, [ir.Var("m"), key("x")]),
        ir.If(
          cond: ir.Var("c"),
          result: [ir.TI32],
          then_branch: ir.Values([i32(111)]),
          else_branch: ir.Values([i32(222)]),
        ),
      )),
    )
  let classify_absent =
    fn0(
      "classify_y",
      ir.TI32,
      with_map_x1(ir.Let(
        ["c"],
        ir.MapOp(ir.MapHas, [ir.Var("m"), key("y")]),
        ir.If(
          cond: ir.Var("c"),
          result: [ir.TI32],
          then_branch: ir.Values([i32(111)]),
          else_branch: ir.Values([i32(222)]),
        ),
      )),
    )
  let mod = load(module("cond", [classify, classify_absent]))

  assert catch_apply_dyn(mod, atom.create("classify_x"), [])
    == Ok(to_dynamic(111))
  assert catch_apply_dyn(mod, atom.create("classify_y"), [])
    == Ok(to_dynamic(222))
}
