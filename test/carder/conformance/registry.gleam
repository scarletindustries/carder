//// The module registry — tracks the *current*, *named*, and *registered* modules a
//// `.wast` file builds up as it interleaves `(module …)` definitions with commands.
////
//// PITFALL this exists to avoid (VERIFIED): a `.wast` file defines MULTIPLE modules,
//// and an `assert_*`/`invoke` targets the **most-recently-defined** module unless it
//// names one. A one-module-per-file assumption mis-binds invokes (e.g. `call.wast`
//// defines several modules). So the registry models all three bindings from the start.
////
//// It is generic over the instance value `a` (a loaded BEAM module, a test spy, …) so
//// it is fully testable without the pipeline.

import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import gleam/result

/// The live module bindings.
///
/// - `current`: the most-recently-defined module (the default invoke target). `None`
///   before any module is defined.
/// - `named`: modules bound by their definition `$name` (an action's `module` field
///   references this name).
/// - `registered`: modules bound by a `register` link-name (kept distinct from `named`).
pub opaque type Registry(a) {
  Registry(
    current: Option(a),
    named: Dict(String, a),
    registered: Dict(String, a),
  )
}

/// An empty registry — no current module, nothing named or registered.
pub fn new() -> Registry(a) {
  Registry(current: None, named: dict.new(), registered: dict.new())
}

/// Record a freshly-defined module `inst`: it becomes the new `current`, and — if the
/// `module` command carried a `$name` — is also bound under that name. Total.
pub fn define(reg: Registry(a), name: Option(String), inst: a) -> Registry(a) {
  let named = case name {
    Some(n) -> dict.insert(reg.named, n, inst)
    None -> reg.named
  }
  Registry(..reg, current: Some(inst), named: named)
}

/// Apply a `register` command: alias a module under the link-name `as_name`. `module`
/// names the module to alias (by `$name`), or `None` for the current module. Returns
/// `Error` if the referenced module is unknown / there is no current module.
pub fn register(
  reg: Registry(a),
  as_name: String,
  module: Option(String),
) -> Result(Registry(a), String) {
  use inst <- result.try(resolve(reg, module))
  Ok(Registry(..reg, registered: dict.insert(reg.registered, as_name, inst)))
}

/// Resolve the module an action targets. `None` → the current module; `Some(n)` → the
/// module bound under name `n`, looked up first among `named` (definition `$name`) then
/// `registered` (link-name). Returns `Error(reason)` when there is no current module or
/// the named module is unknown — so a mis-bound invoke is a typed failure, not a panic.
pub fn resolve(reg: Registry(a), who: Option(String)) -> Result(a, String) {
  case who {
    None ->
      case reg.current {
        Some(inst) -> Ok(inst)
        None ->
          Error("no current module (an action ran before any module loaded)")
      }
    Some(n) ->
      case dict.get(reg.named, n) {
        Ok(inst) -> Ok(inst)
        Error(_) ->
          case dict.get(reg.registered, n) {
            Ok(inst) -> Ok(inst)
            Error(_) -> Error("unknown module: " <> n)
          }
      }
  }
}
