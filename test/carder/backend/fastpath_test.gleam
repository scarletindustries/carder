//// Phase-8 unit 06 — term classification + native number arithmetic (guarded fast paths),
//// end-to-end on the BEAM.
////
//// Spec-first (CLAUDE.md D8 / `specs/phase-8/06-numeric-fastpath.md`): each test authors a small
//// IR `Module` that classifies a BEAM term (`TermTest`/`TermTag`) or does native BEAM arithmetic
//// on number terms (`NumTerm`), lowers it IR → `emit_core` → `build_beam` → a loaded `.beam`,
//// invokes an export with `erlang:apply`, and asserts the **value** — never the emitted bytes.
//// Results are asserted against defined BEAM semantics (`erlang:is_*` type tests, `erlang:'+'`/`-`/
//// `*`, and `</=</>/>=/=:=`): a guard is `1` for a matching term and `0` otherwise, `TermTag`
//// returns the documented dense code per type, and `NumTerm` computes native sums/products/compares
//// (int, float, and BEAM-promoted mixed).
////
//// The headline is the **composed guarded `a + b`** (`guarded_add`/`guarded_tag`): a number-guarded
//// `If` routes two BEAM floats to the NATIVE `NumTerm(NAdd)` fast path (→ `4.0`, no `rt_js`), and a
//// non-number argument to the SLOW `CallHost("js","add",…)` cold path (the unit-05 `rt_js` stub) —
//// demonstrating Phase 8's thesis: hot arithmetic compiled to native BEAM, dynamic only on the cold
//// path. The harness (`load`/`module`/`fnN`/`catch_apply_dyn`/`to_dynamic`) mirrors
//// `term_ops_test.gleam` + `rt_js_boundary_test.gleam`.

import carder/backend/build_beam
import carder/backend/emit_core
import carder/ir
import carder/runtime/instance
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option

// Test-only FFI (see `test/carder_emit_test_ffi.erl`): apply `M:F(Args)` and capture a raise as
// `Error(text)`. Re-typed for `Dynamic` args/results (a term may be an int/float/atom/binary/tuple/
// map/fun/list), sound because `erlang:apply` is untyped at runtime.
@external(erlang, "carder_emit_test_ffi", "catch_apply")
fn catch_apply_dyn(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

// Coerce any Gleam value to `Dynamic` (identity at runtime) — to build `Dynamic` arg lists and
// expected-value comparisons.
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

// ───────────────────────────── plumbing ─────────────────────────────

/// Emit `module` to Core text under the Safe default binding (whose `js_runtime_module` is the
/// `rt_js` stub — the composed proof's slow path routes there), compile it, and load it into the
/// test VM; return the loaded module atom. `let assert` is the success contract.
fn load(module: ir.Module) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(module, instance.safe_default())
  let assert Ok(mod) = build_beam.compile_and_load(cm)
  mod
}

/// Wrap `functions` in a numerics-on, memory-off module exporting each by name (`uses_numerics` is
/// on — the classifiers/arithmetic carry i32 results and the composed guard ANDs i32 truth values).
fn module(name: String, functions: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "carder@fastpath@" <> name,
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

/// A zero-parameter function `name() -> ty` with body `body`.
fn fn0(name: String, ty: ir.ValType, body: ir.Expr) -> ir.Function {
  ir.Function(name: name, params: [], result: [ty], locals: [], body: body)
}

/// A one-parameter function `name(p0 : TTerm) -> ty` with body `body`. Used where the test supplies
/// the classified/operated term (a native BEAM float, the empty-list tail, or a non-binary
/// bitstring) as the export argument `p0`.
fn fn1(name: String, ty: ir.ValType, body: ir.Expr) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("p0", ir.TTerm)],
    result: [ty],
    locals: [],
    body: body,
  )
}

/// A two-parameter function `name(a : TTerm, b : TTerm) -> ty` with body `body`. Used for `NumTerm`
/// on two supplied number terms and for the composed guarded `a + b`.
fn fn2(name: String, ty: ir.ValType, body: ir.Expr) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("a", ir.TTerm), ir.Local("b", ir.TTerm)],
    result: [ty],
    locals: [],
    body: body,
  )
}

/// The identity-of-one function `id1(p0) -> p0` — the `MakeClosure` target used to build a genuine
/// BEAM `fun` term for the `IsFun`/`TermTag`-fun representatives (`MakeClosure("id1", [], 1)` → a
/// `fun/1`).
fn id1() -> ir.Function {
  ir.Function(
    name: "id1",
    params: [ir.Local("p0", ir.TTerm)],
    result: [ir.TTerm],
    locals: [],
    body: ir.Values([ir.Var("p0")]),
  )
}

fn i32(n: Int) -> ir.Value {
  ir.ConstI32(n)
}

/// A typed empty list `[]` (a BEAM term), passed to `fn1` exports as the cons tail.
fn empty_list() -> List(Int) {
  []
}

// ───────────────────────────── TermTest: 1 for a match, 0 otherwise ─────────────────────────────

/// Each `TermTest(kind, …)` returns the i32 truth value `1` for a term whose runtime shape matches
/// `kind` (per `erlang:is_*`): an integer for `IsInt`, a native float for `IsFloat`, either for
/// `IsNumber`, an atom for `IsAtom`, a binary for `IsBinary`, a `MakeTuple` for `IsTuple`, a
/// `MapNew` for `IsMap`, a `MakeClosure` for `IsFun`, and a `MakeCons` for `IsList`. The structural
/// representatives are built with the unit-01/02/03 constructors, proving those nodes produce terms
/// the guards recognise. Floats are supplied as `p0` (a JS `number` is a native BEAM `float()`, not
/// a `ConstF64` bit pattern — the corrected numeric model).
pub fn term_test_matches_e2e_test() {
  let fns = [
    id1(),
    fn0("tt_int", ir.TI32, ir.TermTest(ir.IsInt, i32(42))),
    fn1("tt_float", ir.TI32, ir.TermTest(ir.IsFloat, ir.Var("p0"))),
    fn0("tt_number_int", ir.TI32, ir.TermTest(ir.IsNumber, i32(42))),
    fn1("tt_number_float", ir.TI32, ir.TermTest(ir.IsNumber, ir.Var("p0"))),
    fn0("tt_atom", ir.TI32, ir.TermTest(ir.IsAtom, ir.ConstAtom("ok"))),
    fn0(
      "tt_binary",
      ir.TI32,
      ir.TermTest(ir.IsBinary, ir.ConstBinary(<<"hi">>)),
    ),
    fn0(
      "tt_tuple",
      ir.TI32,
      ir.Let(
        ["v"],
        ir.TermOp(ir.MakeTuple, [i32(1), i32(2)]),
        ir.TermTest(ir.IsTuple, ir.Var("v")),
      ),
    ),
    fn0(
      "tt_map",
      ir.TI32,
      ir.Let(["v"], ir.MapOp(ir.MapNew, []), ir.TermTest(ir.IsMap, ir.Var("v"))),
    ),
    fn0(
      "tt_fun",
      ir.TI32,
      ir.Let(
        ["v"],
        ir.MakeClosure("id1", [], 1),
        ir.TermTest(ir.IsFun, ir.Var("v")),
      ),
    ),
    fn1(
      "tt_list",
      ir.TI32,
      ir.Let(
        ["v"],
        ir.TermOp(ir.MakeCons, [i32(1), ir.Var("p0")]),
        ir.TermTest(ir.IsList, ir.Var("v")),
      ),
    ),
  ]
  let mod = load(module("ttmatch", fns))
  let one = Ok(to_dynamic(1))

  assert catch_apply_dyn(mod, atom.create("tt_int"), []) == one
  assert catch_apply_dyn(mod, atom.create("tt_float"), [to_dynamic(1.5)]) == one
  assert catch_apply_dyn(mod, atom.create("tt_number_int"), []) == one
  assert catch_apply_dyn(mod, atom.create("tt_number_float"), [to_dynamic(2.5)])
    == one
  assert catch_apply_dyn(mod, atom.create("tt_atom"), []) == one
  assert catch_apply_dyn(mod, atom.create("tt_binary"), []) == one
  assert catch_apply_dyn(mod, atom.create("tt_tuple"), []) == one
  assert catch_apply_dyn(mod, atom.create("tt_map"), []) == one
  assert catch_apply_dyn(mod, atom.create("tt_fun"), []) == one
  assert catch_apply_dyn(mod, atom.create("tt_list"), [to_dynamic(empty_list())])
    == one
}

/// Each `TermTest(kind, …)` returns the i32 truth value `0` for a term of the WRONG shape — the
/// complement of the match test. Covers every kind against a non-matching representative (a float
/// is not an int, an int is not a float/atom/binary/tuple/map/fun/list, an atom is not a number),
/// so `is_*` genuinely discriminates, not vacuously returns `1`.
pub fn term_test_mismatches_e2e_test() {
  let fns = [
    fn1("tt_int_of_float", ir.TI32, ir.TermTest(ir.IsInt, ir.Var("p0"))),
    fn0("tt_float_of_int", ir.TI32, ir.TermTest(ir.IsFloat, i32(42))),
    fn0(
      "tt_number_of_atom",
      ir.TI32,
      ir.TermTest(ir.IsNumber, ir.ConstAtom("ok")),
    ),
    fn0("tt_atom_of_int", ir.TI32, ir.TermTest(ir.IsAtom, i32(42))),
    fn0("tt_binary_of_int", ir.TI32, ir.TermTest(ir.IsBinary, i32(42))),
    fn0("tt_tuple_of_int", ir.TI32, ir.TermTest(ir.IsTuple, i32(42))),
    fn0("tt_map_of_int", ir.TI32, ir.TermTest(ir.IsMap, i32(42))),
    fn0("tt_fun_of_int", ir.TI32, ir.TermTest(ir.IsFun, i32(42))),
    fn0("tt_list_of_int", ir.TI32, ir.TermTest(ir.IsList, i32(42))),
  ]
  let mod = load(module("ttmiss", fns))
  let zero = Ok(to_dynamic(0))

  assert catch_apply_dyn(mod, atom.create("tt_int_of_float"), [to_dynamic(1.5)])
    == zero
  assert catch_apply_dyn(mod, atom.create("tt_float_of_int"), []) == zero
  assert catch_apply_dyn(mod, atom.create("tt_number_of_atom"), []) == zero
  assert catch_apply_dyn(mod, atom.create("tt_atom_of_int"), []) == zero
  assert catch_apply_dyn(mod, atom.create("tt_binary_of_int"), []) == zero
  assert catch_apply_dyn(mod, atom.create("tt_tuple_of_int"), []) == zero
  assert catch_apply_dyn(mod, atom.create("tt_map_of_int"), []) == zero
  assert catch_apply_dyn(mod, atom.create("tt_fun_of_int"), []) == zero
  assert catch_apply_dyn(mod, atom.create("tt_list_of_int"), []) == zero
}

// ───────────────────────────── TermTag: the documented dense code per type ─────────────────────────────

/// `TermTag(arg)` returns the DOCUMENTED dense i32 code for the argument's runtime shape:
/// `0=int 1=float 2=atom 3=binary 4=tuple 5=map 6=fun 7=list 8=other` (the frontend's one-shot
/// `Switch` ABI). Each representative is built with the unit-01/02/03 constructors (float supplied
/// as `p0`); `other` is a non-byte-aligned bitstring `<<0:1>>` — none of the eight `is_*` tests
/// match it, so it falls through to `8`.
pub fn term_tag_codes_e2e_test() {
  let fns = [
    id1(),
    fn0("tag_int", ir.TI32, ir.TermTag(i32(42))),
    fn1("tag_float", ir.TI32, ir.TermTag(ir.Var("p0"))),
    fn0("tag_atom", ir.TI32, ir.TermTag(ir.ConstAtom("ok"))),
    fn0("tag_binary", ir.TI32, ir.TermTag(ir.ConstBinary(<<"hi">>))),
    fn0(
      "tag_tuple",
      ir.TI32,
      ir.Let(
        ["v"],
        ir.TermOp(ir.MakeTuple, [i32(1), i32(2)]),
        ir.TermTag(ir.Var("v")),
      ),
    ),
    fn0(
      "tag_map",
      ir.TI32,
      ir.Let(["v"], ir.MapOp(ir.MapNew, []), ir.TermTag(ir.Var("v"))),
    ),
    fn0(
      "tag_fun",
      ir.TI32,
      ir.Let(["v"], ir.MakeClosure("id1", [], 1), ir.TermTag(ir.Var("v"))),
    ),
    fn1(
      "tag_list",
      ir.TI32,
      ir.Let(
        ["v"],
        ir.TermOp(ir.MakeCons, [i32(1), ir.Var("p0")]),
        ir.TermTag(ir.Var("v")),
      ),
    ),
    fn1("tag_other", ir.TI32, ir.TermTag(ir.Var("p0"))),
  ]
  let mod = load(module("tag", fns))

  assert catch_apply_dyn(mod, atom.create("tag_int"), []) == Ok(to_dynamic(0))
  assert catch_apply_dyn(mod, atom.create("tag_float"), [to_dynamic(1.5)])
    == Ok(to_dynamic(1))
  assert catch_apply_dyn(mod, atom.create("tag_atom"), []) == Ok(to_dynamic(2))
  assert catch_apply_dyn(mod, atom.create("tag_binary"), [])
    == Ok(to_dynamic(3))
  assert catch_apply_dyn(mod, atom.create("tag_tuple"), []) == Ok(to_dynamic(4))
  assert catch_apply_dyn(mod, atom.create("tag_map"), []) == Ok(to_dynamic(5))
  assert catch_apply_dyn(mod, atom.create("tag_fun"), []) == Ok(to_dynamic(6))
  assert catch_apply_dyn(mod, atom.create("tag_list"), [
      to_dynamic(empty_list()),
    ])
    == Ok(to_dynamic(7))
  assert catch_apply_dyn(mod, atom.create("tag_other"), [to_dynamic(<<0:1>>)])
    == Ok(to_dynamic(8))
}

// ───────────────────────────── NumTerm: native BEAM arithmetic + compare ─────────────────────────────

/// `NumTerm` arithmetic lowers to native BEAM `erlang:'+'/'-'/'*'` on number terms: `2 + 3 = 5`,
/// `2 - 3 = -1`, `2 * 3 = 6` (integers); `1.5 + 2.5 = 4.0` (two native floats supplied as params);
/// and `2 + 2.5 = 4.5` (BEAM PROMOTES the integer to float in mixed arithmetic). The result is a
/// number term (`TTerm`), asserted as the BEAM value.
pub fn num_term_arithmetic_e2e_test() {
  let fns = [
    fn0("n_add", ir.TTerm, ir.NumTerm(ir.NAdd, i32(2), i32(3))),
    fn0("n_sub", ir.TTerm, ir.NumTerm(ir.NSub, i32(2), i32(3))),
    fn0("n_mul", ir.TTerm, ir.NumTerm(ir.NMul, i32(2), i32(3))),
    fn2("n_add_float", ir.TTerm, ir.NumTerm(ir.NAdd, ir.Var("a"), ir.Var("b"))),
    fn1("n_add_mixed", ir.TTerm, ir.NumTerm(ir.NAdd, i32(2), ir.Var("p0"))),
  ]
  let mod = load(module("numarith", fns))

  assert catch_apply_dyn(mod, atom.create("n_add"), []) == Ok(to_dynamic(5))
  assert catch_apply_dyn(mod, atom.create("n_sub"), []) == Ok(to_dynamic(-1))
  assert catch_apply_dyn(mod, atom.create("n_mul"), []) == Ok(to_dynamic(6))
  assert catch_apply_dyn(mod, atom.create("n_add_float"), [
      to_dynamic(1.5),
      to_dynamic(2.5),
    ])
    == Ok(to_dynamic(4.0))
  assert catch_apply_dyn(mod, atom.create("n_add_mixed"), [to_dynamic(2.5)])
    == Ok(to_dynamic(4.5))
}

/// `NumTerm` comparisons lower to `case A </=</>/>=/=:= B of 'true' -> 1; 'false' -> 0 end` — an i32
/// truth value. Each relational op is asserted `1` when it holds and `0` when it does not, over
/// integer operands: `2 < 3`, `2 =< 2`, `3 > 2`, `3 >= 3`, `2 =:= 2` (true → 1) and their false
/// counterparts (→ 0). (`NEq` is BEAM exact-equal on numbers, the guarded numeric compare.)
pub fn num_term_compare_e2e_test() {
  let fns = [
    fn0("n_lt_t", ir.TI32, ir.NumTerm(ir.NLt, i32(2), i32(3))),
    fn0("n_lt_f", ir.TI32, ir.NumTerm(ir.NLt, i32(3), i32(2))),
    fn0("n_le_t", ir.TI32, ir.NumTerm(ir.NLe, i32(2), i32(2))),
    fn0("n_le_f", ir.TI32, ir.NumTerm(ir.NLe, i32(3), i32(2))),
    fn0("n_gt_t", ir.TI32, ir.NumTerm(ir.NGt, i32(3), i32(2))),
    fn0("n_gt_f", ir.TI32, ir.NumTerm(ir.NGt, i32(2), i32(3))),
    fn0("n_ge_t", ir.TI32, ir.NumTerm(ir.NGe, i32(3), i32(3))),
    fn0("n_ge_f", ir.TI32, ir.NumTerm(ir.NGe, i32(2), i32(3))),
    fn0("n_eq_t", ir.TI32, ir.NumTerm(ir.NEq, i32(2), i32(2))),
    fn0("n_eq_f", ir.TI32, ir.NumTerm(ir.NEq, i32(2), i32(3))),
  ]
  let mod = load(module("numcmp", fns))
  let one = Ok(to_dynamic(1))
  let zero = Ok(to_dynamic(0))

  assert catch_apply_dyn(mod, atom.create("n_lt_t"), []) == one
  assert catch_apply_dyn(mod, atom.create("n_lt_f"), []) == zero
  assert catch_apply_dyn(mod, atom.create("n_le_t"), []) == one
  assert catch_apply_dyn(mod, atom.create("n_le_f"), []) == zero
  assert catch_apply_dyn(mod, atom.create("n_gt_t"), []) == one
  assert catch_apply_dyn(mod, atom.create("n_gt_f"), []) == zero
  assert catch_apply_dyn(mod, atom.create("n_ge_t"), []) == one
  assert catch_apply_dyn(mod, atom.create("n_ge_f"), []) == zero
  assert catch_apply_dyn(mod, atom.create("n_eq_t"), []) == one
  assert catch_apply_dyn(mod, atom.create("n_eq_f"), []) == zero
}

// ───────────────────────────── the composed guarded `a + b` (the acceptance) ─────────────────────────────

/// The composed guarded `a + b` — TWO `TermTest(IsNumber)` guards combined with a nested `If`
/// selecting either the NATIVE `NumTerm(NAdd)` fast path or the `CallHost("js","add",…)` slow path
/// (`rt_js` stub). Body:
/// ```
/// let ga = term_test.is_number a
/// let gb = term_test.is_number b
/// if ga then (if gb then num_term.add a b else call_host "js" "add" (a, b))
///       else call_host "js" "add" (a, b)
/// ```
fn guarded_add() -> ir.Function {
  let slow = ir.CallHost("js", "add", [ir.Var("a"), ir.Var("b")])
  let fast = ir.NumTerm(ir.NAdd, ir.Var("a"), ir.Var("b"))
  fn2(
    "guarded_add",
    ir.TTerm,
    ir.Let(
      ["ga"],
      ir.TermTest(ir.IsNumber, ir.Var("a")),
      ir.Let(
        ["gb"],
        ir.TermTest(ir.IsNumber, ir.Var("b")),
        ir.If(
          cond: ir.Var("ga"),
          result: [ir.TTerm],
          then_branch: ir.If(
            cond: ir.Var("gb"),
            result: [ir.TTerm],
            then_branch: fast,
            else_branch: slow,
          ),
          else_branch: slow,
        ),
      ),
    ),
  )
}

/// A branch-selection witness with the SAME guard as `guarded_add`, but each branch returns a marker
/// atom (`'fast'`/`'slow'`) instead of computing — so the selected path is observable WITHOUT the
/// slow-path stub's raise obscuring it. Proves the guard routes numbers to the fast branch and a
/// non-number to the slow branch.
fn guarded_tag() -> ir.Function {
  let slow = ir.Values([ir.ConstAtom("slow")])
  let fast = ir.Values([ir.ConstAtom("fast")])
  fn2(
    "guarded_tag",
    ir.TTerm,
    ir.Let(
      ["ga"],
      ir.TermTest(ir.IsNumber, ir.Var("a")),
      ir.Let(
        ["gb"],
        ir.TermTest(ir.IsNumber, ir.Var("b")),
        ir.If(
          cond: ir.Var("ga"),
          result: [ir.TTerm],
          then_branch: ir.If(
            cond: ir.Var("gb"),
            result: [ir.TTerm],
            then_branch: fast,
            else_branch: slow,
          ),
          else_branch: slow,
        ),
      ),
    ),
  )
}

/// THE composed fast/slow proof (the acceptance — Phase 8's thesis). `guarded_add(1.5, 2.5)` takes
/// the FAST path: both args are numbers → the guard is true → native `NumTerm(NAdd)` → `4.0`, with
/// NO `rt_js` round-trip (`guarded_tag(1.5, 2.5) == 'fast'` witnesses that the native branch, not
/// the slow one, ran). `guarded_add(2, 3) == 5` shows the integer fast path. A NON-number argument
/// (`guarded_add('undefined', 3)`) takes the SLOW path: the guard is false → `guarded_tag` witnesses
/// `'slow'`, and `CallHost("js","add",…)` reaches the unit-05 `rt_js` stub — whose integer-only
/// `add` (this is a STUB; the real `rt_js` coerces) raises on the non-number, surfaced as `Error`.
/// Together: hot arithmetic compiled to native BEAM, dynamic only on the cold path.
pub fn composed_guarded_add_fast_slow_e2e_test() {
  let mod = load(module("guarded", [id1(), guarded_add(), guarded_tag()]))
  let g_add = atom.create("guarded_add")
  let g_tag = atom.create("guarded_tag")
  let undefined = to_dynamic(atom.create("undefined"))

  // FAST path: two native BEAM floats → guard true → native NumTerm add → 4.0 (no rt_js).
  assert catch_apply_dyn(mod, g_add, [to_dynamic(1.5), to_dynamic(2.5)])
    == Ok(to_dynamic(4.0))
  // ...and the fast/native branch (not the slow one) is the one that ran.
  assert catch_apply_dyn(mod, g_tag, [to_dynamic(1.5), to_dynamic(2.5)])
    == Ok(to_dynamic(atom.create("fast")))
  // FAST path also for integers: native NumTerm add → 5.
  assert catch_apply_dyn(mod, g_add, [to_dynamic(2), to_dynamic(3)])
    == Ok(to_dynamic(5))

  // SLOW path: a non-number arg → guard false → the slow branch is selected (witnessed by 'slow')...
  assert catch_apply_dyn(mod, g_tag, [undefined, to_dynamic(3)])
    == Ok(to_dynamic(atom.create("slow")))
  // ...and it routes to the rt_js stub's `add`, whose integer-only sum raises on the non-number —
  // the stub's result on the cold path (the REAL rt_js would coerce), surfaced as an Error.
  let assert Error(_) = catch_apply_dyn(mod, g_add, [undefined, to_dynamic(3)])
}
