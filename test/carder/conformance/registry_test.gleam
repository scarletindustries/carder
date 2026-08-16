//// Self-tests for the module registry (run NOW — no compiler needed).
////
//// Proves the PITFALL the registry exists to avoid: when a file defines several
//// modules, an invoke that NAMES one must bind to that module — NOT to the
//// most-recently-defined one — and a `register` alias resolves too.

import carder/conformance/registry
import gleam/option.{None, Some}

/// `None` resolves to the current (most-recent) module; a NAME resolves to that exact
/// module even when a later module became current (no mis-binding to "most recent").
pub fn named_vs_current_test() {
  let reg =
    registry.new()
    |> registry.define(Some("$a"), "module-A")
    |> registry.define(Some("$b"), "module-B")

  // current = the most recently defined.
  assert registry.resolve(reg, None) == Ok("module-B")
  // a named invoke binds to the named module, not the most-recent one.
  assert registry.resolve(reg, Some("$a")) == Ok("module-A")
  assert registry.resolve(reg, Some("$b")) == Ok("module-B")
  // an unknown name is a typed error.
  assert registry.resolve(reg, Some("$nope")) == Error("unknown module: $nope")
}

/// `register` aliases a module under a link-name resolvable later; with `None` it
/// aliases the current module.
pub fn register_alias_test() {
  let assert Ok(reg) =
    registry.new()
    |> registry.define(Some("$a"), "module-A")
    |> registry.define(Some("$b"), "module-B")
    |> registry.register("lib", Some("$a"))
  assert registry.resolve(reg, Some("lib")) == Ok("module-A")

  let assert Ok(reg2) = registry.register(reg, "cur", None)
  assert registry.resolve(reg2, Some("cur")) == Ok("module-B")
}

/// Resolving before any module is defined is a typed error, not a panic.
pub fn empty_registry_test() {
  let reg: registry.Registry(String) = registry.new()
  let assert Error(_) = registry.resolve(reg, None)
  assert registry.register(reg, "x", Some("$missing"))
    == Error("unknown module: $missing")
}
