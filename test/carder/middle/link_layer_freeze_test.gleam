//// `link_layer_freeze_test` — the `«RT-LAYER-FROZEN»` guard (Phase-11 P11-01, decision O1
//// "Clean layering").
////
//// This is the durable, structural proof that the runtime is a **clean layer**: no module under
//// `src/carder/runtime/` imports a compiler layer (`carder/frontend`, `carder/middle`, or
//// `carder/backend`). `--link` (P11-03) merges the runtime's transitive dependency closure into a
//// single self-contained `.beam`; that closure is only well-defined if the runtime drags in **zero**
//// compiler modules. Before Phase 11 the layering was inverted — `instance`/`profiles` imported
//// `carder/middle/ir_opt` solely for the `OptLevel` enum, which P11-01 relocated to the leaf
//// `carder/opt_level`. These tests encode the *invariant*, not the current file contents: they
//// would have **failed on the pre-P11-01 tree** (the two `ir_opt` imports) and fail again if any
//// future edit reintroduces a runtime→compiler import.
////
//// **Why a direct scan of `runtime/` is transitively sufficient.** A runtime module can only reach
//// a compiler layer either directly (caught by `runtime_reaches_zero_compiler_modules_test`) or
//// through the one non-runtime, non-compiler `carder` module the runtime references — `carder/ir`.
//// `ir_is_a_clean_leaf_test` pins `ir` to importing only `gleam/list` + `gleam/option` (R2 — `ir`
//// is a verified clean leaf, deliberately NOT split), so it can never be the bridge to a compiler
//// layer. With `ir` sealed, scanning the direct imports of `runtime/*` covers the whole transitive
//// closure.

import gleam/list
import gleam/string
import gleeunit/should
import simplifile

/// The compiler layers a clean runtime must never reach. A runtime module importing any of these
/// module roots — or any submodule beneath one (`carder/middle/ir_opt`, `carder/backend/emit_core`,
/// …) — is exactly the layering inversion Phase 11 removes and freezes shut.
const compiler_layers = [
  "carder/frontend",
  "carder/middle",
  "carder/backend",
]

/// Extract the imported module path from a single line of Gleam source.
///
/// - `line`: one physical source line (may carry indentation, a trailing `.{…}` exposing block,
///   or an ` as alias` suffix).
/// - Return: `Ok(path)` when `line` (ignoring leading whitespace) is an `import` statement — e.g.
///   `"  import carder/ir.{type Module}"` yields `Ok("carder/ir")` and
///   `"import gleam/list as l"` yields `Ok("gleam/list")`. Returns `Error(Nil)` for any non-import
///   line (blank, comment, code, or a continuation line of a multi-line exposing block), so a doc
///   comment that merely *names* a module (e.g. `//// …carder/middle…`) is never misread as an
///   import. Never panics.
fn import_path(line: String) -> Result(String, Nil) {
  let trimmed = string.trim_start(line)
  case string.starts_with(trimmed, "import ") {
    False -> Error(Nil)
    True -> {
      // Drop the leading `import ` (7 graphemes), then cut at the exposing block (`.{…}`) and any
      // ` as alias`; what remains is the module path.
      let after = string.drop_start(trimmed, 7)
      let before_dot = case string.split_once(after, ".") {
        Ok(#(path, _)) -> path
        Error(_) -> after
      }
      let before_space = case string.split_once(before_dot, " ") {
        Ok(#(path, _)) -> path
        Error(_) -> before_dot
      }
      Ok(string.trim(before_space))
    }
  }
}

/// The set of module paths `source` imports, in source order.
///
/// - `source`: the full text of a Gleam module.
/// - Return: every imported module path (e.g. `["gleam/list", "carder/ir", …]`); the empty list
///   for a module with no imports. Comment and continuation lines are ignored (see `import_path`).
fn imported_modules(source: String) -> List(String) {
  source
  |> string.split("\n")
  |> list.filter_map(import_path)
}

/// **The freeze (O1 "Clean layering").** No module under `src/carder/runtime/` imports any compiler
/// layer, directly or as a submodule. Scans every `*.gleam` file in the runtime directory tree and
/// collects `#(file, compiler_layer)` for each violation; the frozen invariant is that this list is
/// empty. Encoded against the invariant, not today's tree — it failed on the pre-P11-01 source
/// (`instance`/`profiles` importing `carder/middle/ir_opt`) and will fail again on any regression.
pub fn runtime_reaches_zero_compiler_modules_test() {
  let assert Ok(files) = simplifile.get_files("src/carder/runtime")
  let gleam_files = list.filter(files, string.ends_with(_, ".gleam"))

  // Guard against a vacuously-green test: the runtime tree must actually contain modules to scan.
  { gleam_files != [] }
  |> should.be_true

  let violations =
    gleam_files
    |> list.flat_map(fn(path) {
      let assert Ok(src) = simplifile.read(path)
      let modules = imported_modules(src)
      compiler_layers
      |> list.filter(fn(layer) {
        list.any(modules, fn(m) {
          m == layer || string.starts_with(m, layer <> "/")
        })
      })
      |> list.map(fn(layer) { #(path, layer) })
    })

  violations
  |> should.equal([])
}

/// **R2 lock — `carder/ir` is a clean leaf.** Asserts `ir.gleam` imports *exactly* `gleam/list` +
/// `gleam/option` and nothing else. This seals the one bridge by which a runtime module could reach
/// a compiler layer indirectly (the runtime references `ir`'s `TrapReason`/`FuncType`/`ValType`
/// types), making the direct `runtime/` scan transitively sufficient. A future edit that reaches a
/// compiler (or any other) module from `ir` breaks *this* test — pinning seam #2 closed at its
/// source, not downstream in the linker.
pub fn ir_is_a_clean_leaf_test() {
  let assert Ok(src) = simplifile.read("src/carder/ir.gleam")

  imported_modules(src)
  |> list.sort(string.compare)
  |> should.equal(["gleam/list", "gleam/option"])
}
