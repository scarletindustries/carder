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
import gleam/erlang/atom.{type Atom}
import gleam/string

@external(erlang, "erlang", "apply")
fn apply_int(module: Atom, function: Atom, args: List(Int)) -> Int

@external(erlang, "erlang", "apply")
fn apply_pair(
  module: Atom,
  function: Atom,
  args: List(#(Int, Int)),
) -> #(Int, Int)

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
