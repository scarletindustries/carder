//// `twocore/frontend/js` — compile JavaScript to native BEAM, via arc's parser and
//// 2core's IR/backend.
////
//// Pipeline: arc `parser.parse` → `js/lower` (AST → 2core IR) → `emit_core` →
//// Core Erlang → `build_beam` → a loaded `.beam` whose exported functions are the
//// JS `function` declarations (plus `main/0` for top-level code), callable with
//// `erlang:apply` on native BEAM terms.
////
//// See `js/lower` for the supported subset and the speed model (guarded native
//// fast paths, ~20× an interpreter on numeric code).

import arc/parser
import gleam/erlang/atom.{type Atom}
import gleam/string
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/frontend/js/lower
import twocore/ir
import twocore/runtime/instance

/// A compilation failure.
pub type Error {
  /// arc rejected the source.
  ParseError(message: String)
  /// The lowering hit unsupported JS syntax.
  LowerError(message: String)
  /// The 2core backend failed to emit/load.
  BackendError(message: String)
}

/// Parse + lower a JS **script** to a 2core IR module named `module_name`
/// (a valid Erlang atom, e.g. `"twocore@js@app"`).
pub fn to_ir(source: String, module_name: String) -> Result(ir.Module, Error) {
  case parser.parse(source, parser.Script) {
    Error(e) -> Error(ParseError(parser.parse_error_to_string(e)))
    Ok(#(program, _sb)) ->
      case lower.program(program, module_name) {
        Ok(m) -> Ok(m)
        Error(lower.Unsupported(what)) ->
          Error(LowerError("unsupported: " <> what))
      }
  }
}

/// Compile a JS script and LOAD it into the running node; returns the loaded module
/// atom. Its exported functions are the JS `function` declarations by name (and
/// `main/0` for top-level code); apply them with `erlang:apply` on BEAM terms.
pub fn compile_and_load(
  source: String,
  module_name: String,
) -> Result(Atom, Error) {
  case to_ir(source, module_name) {
    Error(e) -> Error(e)
    Ok(m) ->
      case emit_core.emit_module(m, instance.safe_default()) {
        Error(e) -> Error(BackendError("emit_core: " <> string.inspect(e)))
        Ok(cm) -> {
          let core = core_printer.print_module(cm)
          case build_beam.compile_and_load(<<core:utf8>>) {
            Ok(module_atom) -> Ok(module_atom)
            Error(err) -> Error(BackendError("build: " <> string.inspect(err)))
          }
        }
      }
  }
}
