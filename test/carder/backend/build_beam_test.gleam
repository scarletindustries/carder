//// Tests for the `build_beam` driver + the «FFI-SHIM» (Unit 04).
////
//// These assert against the *defined behavior* of the Erlang Abstract Format
//// and the Erlang compiler, and against ordinary integer arithmetic — NOT
//// against whatever bytes the compiler happens to emit (no change-detector
//// tests, D8). `5` is asserted for `add(2, 3)` because integer addition says
//// so; the `.beam` byte layout is never inspected.
////
//// Canonical references: the Erlang Abstract Format reference
//// (`erts/absform`) and the OTP `compiler` application docs. This unit is what
//// proves high-level §9.2 (compiled output is real, preemptible BEAM code) and
//// D10 (it loads into and runs in the current VM).
////
//// The fixtures are hand-built backend `CModule` values (the same AST
//// `emit_core` produces), lowered to abstract forms by `eaf.module_forms`
//// inside `build_beam` — keeping the tests self-contained with no file-reading
//// dependency and exercising the exact seam the pipeline compiles through.

import carder/backend/build_beam.{CompileFailed}
import carder/backend/core_erlang.{
  type CModule, CApply, CAtom, CCall, CCase, CClause, CFun, CInt, CModule, CVar,
  FName, FunDef, PVar,
}
import gleam/bit_array
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/string

// ───────────────────────── test-only externals ─────────────────────────
//
// Calling a loaded export from a Gleam test needs a raw `erlang:apply`. Gleam
// cannot type-check FFI returns, so we keep two narrowly-typed, private wrappers
// — one per result shape we assert (integer arithmetic vs. an atom guard arm).

/// `erlang:apply(Module, Function, Args)` for exports that return an integer.
@external(erlang, "erlang", "apply")
fn apply_int(module: Atom, function: Atom, args: List(Int)) -> Int

/// `erlang:apply(Module, Function, Args)` for exports that return an atom.
@external(erlang, "erlang", "apply")
fn apply_atom(module: Atom, function: Atom, args: List(Int)) -> Atom

// ───────────────────────────── fixtures ─────────────────────────────

/// A valid hand-built module: `id/1`, `add/2` (via `erlang:'+'`), and
/// `classify/1` (a `case` with two guard clauses + a catch-all). Module name is
/// `carder@test@fixture` — `carder@…`-namespaced so it cannot clobber OTP.
fn fixture_module() -> CModule {
  CModule(
    name: "carder@test@fixture",
    exports: [FName("add", 2), FName("classify", 1), FName("id", 1)],
    attributes: [],
    defs: [
      FunDef(FName("id", 1), CFun(["X"], CVar("X"))),
      FunDef(
        FName("add", 2),
        CFun(
          ["A", "B"],
          CCall(CAtom("erlang"), CAtom("+"), [CVar("A"), CVar("B")]),
        ),
      ),
      FunDef(
        FName("classify", 1),
        CFun(
          ["N"],
          CCase(CVar("N"), [
            CClause(
              [PVar("X")],
              CCall(CAtom("erlang"), CAtom("=<"), [CVar("X"), CInt(0)]),
              CAtom("zero_or_neg"),
            ),
            CClause(
              [PVar("Y")],
              CCall(CAtom("erlang"), CAtom("<"), [CVar("Y"), CInt(10)]),
              CAtom("small"),
            ),
            CClause([PVar("W")], CAtom("true"), CAtom("big")),
          ]),
        ),
      ),
    ],
  )
}

/// One version of a hot-swappable module `carder@test@hotswap`: `val/0`
/// returns `value`. Loaded twice with different values in the hot-replace test
/// to prove the loaded code is genuinely resident (D10), not a static artifact.
fn hotswap_module(value: Int) -> CModule {
  CModule(
    name: "carder@test@hotswap",
    exports: [FName("val", 0)],
    attributes: [],
    defs: [FunDef(FName("val", 0), CFun([], CInt(value)))],
  )
}

/// A structurally broken module: `oops/0`'s body references an UNBOUND
/// variable. The AST lowers to forms fine, but `erl_lint` inside
/// `compile:forms` rejects it — exercising the compiler's error path (an
/// unbound variable is the forms-level analog of the old scanner's `@@@`).
fn broken_unbound_module() -> CModule {
  CModule(
    name: "carder@test@broken",
    exports: [FName("oops", 0)],
    attributes: [],
    defs: [FunDef(FName("oops", 0), CFun([], CVar("never_bound")))],
  )
}

/// A semantically broken module: `go/0` applies an undefined local function
/// `missing/0`. Lowers fine, but `compile:forms` rejects it (undefined
/// function) — a differently-shaped compiler diagnostic than the unbound-var
/// case.
fn broken_semantic_module() -> CModule {
  CModule(
    name: "carder@test@badsem",
    exports: [FName("go", 0)],
    attributes: [],
    defs: [FunDef(FName("go", 0), CFun([], CApply(FName("missing", 0), [])))],
  )
}

// ───────────────────── 1. happy path, numeric assertion ─────────────────────

/// Compiling, loading, and running the valid fixture must yield the spec-defined
/// arithmetic / guard results: `add(2,3) == 5`, `id(42) == 42`, and each
/// `classify` input lands in the documented guard arm. Proves the full
/// AST → forms → `.beam` → loaded → `apply` seam (D10, §9.2).
pub fn compile_load_run_happy_path_test() {
  let assert Ok(mod) = build_beam.compile_and_load(fixture_module())

  // The loaded module name comes from the `-module` attribute.
  assert atom.to_string(mod) == "carder@test@fixture"

  // add/2 is integer addition; 2 + 3 is 5.
  assert apply_int(mod, atom.create("add"), [2, 3]) == 5
  assert apply_int(mod, atom.create("add"), [-4, 4]) == 0
  // id/1 is the identity.
  assert apply_int(mod, atom.create("id"), [42]) == 42
  // classify/1 guard arms.
  let classify = atom.create("classify")
  assert apply_atom(mod, classify, [0]) == atom.create("zero_or_neg")
  assert apply_atom(mod, classify, [-5]) == atom.create("zero_or_neg")
  assert apply_atom(mod, classify, [7]) == atom.create("small")
  assert apply_atom(mod, classify, [9]) == atom.create("small")
  assert apply_atom(mod, classify, [10]) == atom.create("big")
  assert apply_atom(mod, classify, [100]) == atom.create("big")
}

// ───────────────── 2. malformed input → typed Error, no crash ─────────────────

/// A module whose body references an unbound variable must produce
/// `Error(CompileFailed(lines))` with non-empty, human-readable
/// `"<loc>: <message>"` lines — never a panic (fail-closed, D4). The result is
/// captured normally (no `let assert`), so a panic would fail the test rather
/// than be silently caught.
pub fn malformed_unbound_yields_typed_error_test() {
  let result = build_beam.compile_module(broken_unbound_module())

  let assert Error(CompileFailed(lines)) = result
  assert lines != []
  // Each line is a non-empty rendered diagnostic of the form "<loc>: <msg>".
  assert list.all(lines, fn(l) { l != "" && string.contains(l, ": ") })
}

/// A module applying an undefined local function lowers to forms but is
/// rejected by `compile:forms`. It must ALSO surface as
/// `Error(CompileFailed(lines))` with non-empty lines — proving the shim
/// normalizes every compiler diagnostic into the same flat list. No panic.
pub fn malformed_semantic_yields_typed_error_test() {
  let result = build_beam.compile_module(broken_semantic_module())

  let assert Error(CompileFailed(lines)) = result
  assert lines != []
  assert list.all(lines, fn(l) { l != "" })
}

// ───────────────────────── 3. FFI shape validation ─────────────────────────

/// Trust-boundary check (Gleam cannot type-check the `.erl` return): on success
/// `compile_module` must hand back the expected module atom AND a non-empty
/// `beam` binary.
pub fn ffi_success_shape_test() {
  let assert Ok(#(mod, beam)) = build_beam.compile_module(fixture_module())
  assert atom.to_string(mod) == "carder@test@fixture"
  // A real `.beam` binary is non-empty.
  assert bit_array.byte_size(beam) > 0
}

/// Trust-boundary check: on failure `compile_module` must hand back a non-empty
/// `List(String)` (every element a non-empty string), regardless of which stage
/// failed.
pub fn ffi_failure_shape_test() {
  let assert Error(CompileFailed(lines)) =
    build_beam.compile_module(broken_unbound_module())
  assert lines != []
  assert list.all(lines, fn(l) { string.length(l) > 0 })
}

// ──────────────── 4. round-trippable VM behavior (hot-replace) ────────────────

/// Loading the same module name twice must succeed both times and the SECOND
/// load must hot-replace the first — demonstrating that the loaded module is
/// genuinely resident BEAM code, not a static artifact. After loading v1,
/// `val/0` returns `1`; after loading v2 (same module name), `val/0` returns
/// `2`. (OTP code-loading semantics: `code:load_binary` replaces current code
/// with the new version.)
pub fn hot_replace_resident_module_test() {
  let val = atom.create("val")

  let assert Ok(mod1) = build_beam.compile_and_load(hotswap_module(1))
  assert atom.to_string(mod1) == "carder@test@hotswap"
  assert apply_int(mod1, val, []) == 1

  let assert Ok(mod2) = build_beam.compile_and_load(hotswap_module(2))
  assert atom.to_string(mod2) == "carder@test@hotswap"
  // The resident module was hot-replaced: the export now returns v2's value.
  assert apply_int(mod2, val, []) == 2
}

// ───────────────── split-surface: compile_module then load_module ─────────────────

/// `compile_module` and `load_module` compose: compiling separately, then
/// loading the returned binary under its own module atom, yields a callable
/// module — the same outcome as `compile_and_load`, but via the granular
/// two-step API. `load_module` returns the module atom on success.
pub fn split_compile_then_load_test() {
  let assert Ok(#(mod, beam)) = build_beam.compile_module(fixture_module())
  let assert Ok(loaded) = build_beam.load_module(mod, "fixture.forms", beam)
  assert loaded == mod
  assert apply_int(loaded, atom.create("add"), [40, 2]) == 42
}
