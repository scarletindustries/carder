//// Tests for the two `eaf` peepholes that shrink the abstract forms without
//// changing what the compiler sees after `v3_core`:
////
//// - an `erlang:` operator / auto-imported BIF call is spelled as Erlang
////   source spells it (`A + B`, `is_integer(X)`), unless the module defines a
////   function of the same name and arity — then the qualified call is kept,
////   because Erlang rejects an unqualified call to a shadowed BIF;
//// - `let G = E in case G of <{A, B}> when 'true' -> Body` with `G` read
////   nowhere else lowers to the single match `{A, B} = E`.
////
//// Each test asserts the printed forms AND that the compiled module still
//// evaluates per Erlang's own semantics (the reference is the Erlang
//// language: `hd/1` is the list head, `+` is integer addition, …).

import carder/backend/build_beam
import carder/backend/core_erlang.{
  type CModule, CAtom, CCall, CCase, CClause, CCons, CFun, CInt, CLet, CModule,
  CNil, CTuple, CVar, FName, FunDef, PTuple, PVar,
}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/string

@external(erlang, "erlang", "apply")
fn apply_int(module: Atom, function: Atom, args: List(Int)) -> Int

@external(erlang, "erlang", "apply")
fn apply_pair(module: Atom, function: Atom, args: List(a)) -> #(Int, Int)

@external(erlang, "erlang", "apply")
fn apply_triple(
  module: Atom,
  function: Atom,
  args: List(#(Int, Int)),
) -> #(Int, Int, #(Int, Int))

fn erlang(f: String, args: List(core_erlang.CExpr)) -> core_erlang.CExpr {
  CCall(CAtom("erlang"), CAtom(f), args)
}

/// `add/2` = `erlang:'+'`, `is_int/1` = `erlang:is_integer` as an i32 truth
/// value, `neg/1` = unary `erlang:'-'`.
fn bif_module() -> CModule {
  CModule(
    name: "carder@test@eaf_bifs",
    exports: [FName("add", 2), FName("is_int", 1), FName("neg", 1)],
    attributes: [],
    defs: [
      FunDef(
        FName("add", 2),
        CFun(["X", "Y"], erlang("+", [CVar("X"), CVar("Y")])),
      ),
      FunDef(
        FName("is_int", 1),
        CFun(
          ["X"],
          CCase(erlang("is_integer", [CVar("X")]), [
            CClause([core_erlang.PAtom("true")], CAtom("true"), CInt(1)),
            CClause([core_erlang.PAtom("false")], CAtom("true"), CInt(0)),
          ]),
        ),
      ),
      FunDef(FName("neg", 1), CFun(["X"], erlang("-", [CVar("X")]))),
    ],
  )
}

pub fn erlang_operators_and_bifs_spell_as_source_test() {
  let assert Ok(erl) = build_beam.module_to_erl(bif_module())
  assert string.contains(erl, " + ")
  assert string.contains(erl, "-V0")
  let assert Ok(mod) = build_beam.compile_and_load(bif_module())
  assert apply_int(mod, atom.create("add"), [40, 2]) == 42
  assert apply_int(mod, atom.create("is_int"), [7]) == 1
  assert apply_int(mod, atom.create("neg"), [7]) == -7
}

/// The module defines its own `hd/1` (returns 42); `first/1` calls
/// `erlang:hd` and must still get the BIF — the list head, not 42.
fn shadow_module() -> CModule {
  CModule(
    name: "carder@test@eaf_shadow",
    exports: [FName("hd", 1), FName("first", 1)],
    attributes: [],
    defs: [
      FunDef(FName("hd", 1), CFun(["X"], CInt(42))),
      FunDef(
        FName("first", 1),
        CFun(["X"], erlang("hd", [CCons(CVar("X"), CNil)])),
      ),
    ],
  )
}

/// (An unqualified `hd(X)` next to a local `hd/1` calls the LOCAL function —
/// Erlang resolves the clash in favour of the module — so `first` returning
/// the list head proves the call stayed qualified.)
pub fn shadowed_bif_keeps_qualified_call_test() {
  let assert Ok(mod) = build_beam.compile_and_load(shadow_module())
  assert apply_int(mod, atom.create("first"), [5]) == 5
  assert apply_int(mod, atom.create("hd"), [5]) == 42
}

/// `swap/1`: `let G = element(1, {X}) in case G of <{A, B}> -> {B, A}`;
/// `keep/1` is the same but also returns `G`, so the temporary is live.
fn temp_module() -> CModule {
  let bind = fn(body: core_erlang.CExpr) {
    CLet(
      ["G"],
      erlang("element", [CInt(1), CTuple([CVar("X")])]),
      CCase(CVar("G"), [
        CClause([PTuple([PVar("A"), PVar("B")])], CAtom("true"), body),
      ]),
    )
  }
  CModule(
    name: "carder@test@eaf_temp",
    exports: [FName("swap", 1), FName("keep", 1)],
    attributes: [],
    defs: [
      FunDef(
        FName("swap", 1),
        CFun(["X"], bind(CTuple([CVar("B"), CVar("A")]))),
      ),
      FunDef(
        FName("keep", 1),
        CFun(["X"], bind(CTuple([CVar("B"), CVar("A"), CVar("G")]))),
      ),
    ],
  )
}

pub fn single_use_temporary_folds_into_match_test() {
  let assert Ok(erl) = build_beam.module_to_erl(temp_module())
  let assert Ok(#(swap_src, keep_src)) = string.split_once(erl, "keep(")
  // `swap`: one match binding the pair straight from the call — no
  // `V1 = element(...)` temporary, no `case`.
  assert !string.contains(swap_src, "case")
  assert !string.contains(swap_src, "= V1")
  // `keep`: the temporary is read again, so it stays bound.
  assert string.contains(keep_src, "= V1")
  let assert Ok(mod) = build_beam.compile_and_load(temp_module())
  assert apply_pair(mod, atom.create("swap"), [#(1, 2)]) == #(2, 1)
  assert apply_triple(mod, atom.create("keep"), [#(1, 2)]) == #(2, 1, #(1, 2))
}

/// `pair/1`: `let T = {X, 1} in let U = {T} in element(1, U)` — both
/// temporaries are read once, so both splice into the call; `twice/1` reads
/// `T` twice, so it stays bound; `closure/1` reads `T` inside a nested fun,
/// so the allocation stays outside the fun.
fn splice_module() -> CModule {
  let t = CTuple([CVar("X"), CInt(1)])
  CModule(
    name: "carder@test@eaf_splice",
    exports: [FName("pair", 1), FName("twice", 1), FName("closure", 1)],
    attributes: [],
    defs: [
      FunDef(
        FName("pair", 1),
        CFun(
          ["X"],
          CLet(
            ["T"],
            t,
            CLet(
              ["U"],
              CTuple([CVar("T")]),
              erlang("element", [CInt(1), CVar("U")]),
            ),
          ),
        ),
      ),
      FunDef(
        FName("twice", 1),
        CFun(["X"], CLet(["T"], t, CTuple([CVar("T"), CVar("T")]))),
      ),
      FunDef(
        FName("closure", 1),
        CFun(
          ["X"],
          CLet(["T"], t, core_erlang.CApplyExpr(CFun([], CVar("T")), [])),
        ),
      ),
    ],
  )
}

pub fn single_read_constructor_splices_into_its_use_test() {
  let assert Ok(erl) = build_beam.module_to_erl(splice_module())
  let assert Ok(#(pair_src, rest)) = string.split_once(erl, "twice(")
  let assert Ok(#(twice_src, closure_src)) = string.split_once(rest, "closure(")
  // `pair`: no match at all — `element(1, {{V0, 1}})`.
  assert !string.contains(pair_src, " = ")
  assert string.contains(pair_src, "{{V0, 1}}")
  // `twice`: read twice → bound once, referenced twice.
  assert string.contains(twice_src, "V1 = {V0, 1}")
  // `closure`: the tuple is built outside the fun, not inside it.
  assert string.contains(closure_src, "V1 = {V0, 1}")
  let assert Ok(mod) = build_beam.compile_and_load(splice_module())
  assert apply_pair(mod, atom.create("pair"), [7]) == #(7, 1)
  assert apply_pair(mod, atom.create("closure"), [7]) == #(7, 1)
}

@external(erlang, "erlang", "apply")
fn apply_bins(
  module: Atom,
  function: Atom,
  args: List(BitArray),
) -> #(BitArray, BitArray, BitArray, #(Int, BitArray), #(Int, BitArray))

/// `mix/1` builds `{<<"ab">>, <<"ab">>, X, {1, <<"cd">>}, {1, <<"cd">>}}`: the
/// repeated byte string and the repeated constant tuple are each bound once
/// at the top of the function and read twice.
fn consts_module() -> CModule {
  let ab = core_erlang.CBytes(<<"ab">>)
  let cd = CTuple([CInt(1), core_erlang.CBytes(<<"cd">>)])
  CModule(
    name: "carder@test@eaf_consts",
    exports: [FName("mix", 1)],
    attributes: [],
    defs: [
      FunDef(FName("mix", 1), CFun(["X"], CTuple([ab, ab, CVar("X"), cd, cd]))),
    ],
  )
}

pub fn repeated_constant_terms_are_bound_once_test() {
  let assert Ok(erl) = build_beam.module_to_erl(consts_module())
  assert list.length(string.split(erl, "<<\"ab\">>")) == 2
  assert list.length(string.split(erl, "{1, <<\"cd\">>}")) == 2
  assert string.contains(erl, "= <<\"ab\">>")
  assert string.contains(erl, "= {1, <<\"cd\">>}")
  let assert Ok(mod) = build_beam.compile_and_load(consts_module())
  assert apply_bins(mod, atom.create("mix"), [<<"x">>])
    == #(<<"ab">>, <<"ab">>, <<"x">>, #(1, <<"cd">>), #(1, <<"cd">>))
}

/// `both/2`: `case is_integer(X) of 'true' -> is_integer(Y); 'false' ->
/// 'false'` under a further `case … of 'true' -> 1; 'false' -> 0`; `either/2`
/// the `orelse` twin; `keep/1` a two-clause `case` whose scrutinee is not a
/// test (a plain variable) — it must stay a `case`.
fn short_circuit_module() -> CModule {
  let bool_case = fn(scrutinee, t, e) {
    CCase(scrutinee, [
      CClause([core_erlang.PAtom("true")], CAtom("true"), t),
      CClause([core_erlang.PAtom("false")], CAtom("true"), e),
    ])
  }
  let to_i32 = fn(b) { bool_case(b, CInt(1), CInt(0)) }
  let is_int = fn(v) { erlang("is_integer", [CVar(v)]) }
  CModule(
    name: "carder@test@eaf_short_circuit",
    exports: [FName("both", 2), FName("either", 2), FName("keep", 1)],
    attributes: [],
    defs: [
      FunDef(
        FName("both", 2),
        CFun(
          ["X", "Y"],
          to_i32(bool_case(is_int("X"), is_int("Y"), CAtom("false"))),
        ),
      ),
      FunDef(
        FName("either", 2),
        CFun(
          ["X", "Y"],
          to_i32(bool_case(is_int("X"), CAtom("true"), is_int("Y"))),
        ),
      ),
      FunDef(
        FName("keep", 1),
        CFun(["X"], to_i32(bool_case(CVar("X"), CAtom("true"), CAtom("false")))),
      ),
    ],
  )
}

pub fn short_circuit_case_spells_as_operator_test() {
  let assert Ok(erl) = build_beam.module_to_erl(short_circuit_module())
  // erl_pp wraps long operator expressions, so compare with whitespace squeezed.
  let flat =
    string.split(erl, "\n") |> list.map(string.trim) |> string.join(" ")
  let assert Ok(#(both_src, rest)) = string.split_once(flat, "either(")
  let assert Ok(#(either_src, keep_src)) = string.split_once(rest, "keep(")
  assert string.contains(both_src, "is_integer(V0) andalso is_integer(V1)")
  assert string.contains(either_src, "is_integer(V0) orelse is_integer(V1)")
  assert !string.contains(keep_src, "andalso")
  assert !string.contains(keep_src, "orelse")
  let assert Ok(mod) = build_beam.compile_and_load(short_circuit_module())
  let both = atom.create("both")
  let either = atom.create("either")
  assert apply_int(mod, both, [1, 2]) == 1
  assert apply_int(mod, both, [1, 0]) == 1
  let a = to_dynamic(atom.create("a"))
  let one = to_dynamic(1)
  assert apply_any_int(mod, both, [one, a]) == 0
  assert apply_any_int(mod, both, [a, one]) == 0
  assert apply_any_int(mod, either, [a, one]) == 1
  assert apply_any_int(mod, either, [a, a]) == 0
  assert apply_int(mod, either, [1, 2]) == 1
}

@external(erlang, "erlang", "apply")
fn apply_any_int(module: Atom, function: Atom, args: List(Dynamic)) -> Int

@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic
