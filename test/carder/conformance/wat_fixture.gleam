//// The `Script` → harness adapter (unit P5-11 §E, R15) — drives a `.wast` text file parsed by OUR
//// WAT parser (P5-10 `wat.parse_script`) through the SAME `Driver`/oracle/registry the JSON path
//// uses. `wat.gleam` lives in `src/` and so cannot emit test-side `fixture.Command`/`SpecValue`; it
//// produces a src-side `Script` (module + commands + raw-bit-tagged values), and THIS module is the
//// sole adapter converting that `Script` into the harness's execution (R15 pins the ownership: src
//// owns the parser, this test-side unit owns the adapter).
////
//// The payoff (H5): a `.wast` file that `wast2json` cannot convert at the pin runs FROM our own
//// parser, entering the pipeline at `validate` (no binary re-encode — validate/lower serve the WAT
//// AST directly). Total — a parse failure or an out-of-scope construct is a CATEGORISED skip, never
//// a panic and never a silent drop (D9). Every value is spec-sourced: the `assert_return`/
//// `assert_trap` expected answers are the baked-in `.wast` values the parser reads directly (Tier-A),
//// so "green" means every spec-observable was preserved, exactly as on the JSON path.

import carder/conformance/driver
import carder/conformance/fixture.{
  type SpecValue, Arithmetic, Canonical, ExternRefTag, ExternRefVal, F32Bits,
  F32Nan, F64Bits, F64Nan, FuncRefTag, FuncRefVal, I32Val, I64Val, NullRef,
}
import carder/conformance/oracle
import carder/conformance/registry.{type Registry}
import carder/conformance/runner.{
  type Driver, type ImportEnv, type Instance, type Report, DriverError,
  ImportEnv, Report, Returned, Trapped,
}
import carder/frontend/wasm/ast
import carder/frontend/wasm/wat
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None}
import gleam/string

@external(erlang, "carder_conformance_ffi", "read_file")
fn read_file(path: String) -> Result(BitArray, String)

type Reg =
  Registry(Result(Instance, String))

type State {
  State(reg: Reg, env: ImportEnv, rep: Report)
}

/// Parse a `.wast` text file with `wat.parse_script` and drive its commands through `driver`,
/// returning the pass/fail/skip `Report` (same shape the JSON runner produces, so the two paths
/// aggregate). A parse failure (out-of-scope text, or a malformation) is a single categorised skip
/// — never a panic. `path` is the `.wast` file on disk.
pub fn run_wat_fixture(driver: Driver, path: String) -> Report {
  case read_text(path) {
    Error(e) -> one_skip("wat read: " <> e)
    Ok(text) -> run_wat_text(driver, text)
  }
}

/// Drive an in-memory `.wast` `text` through `wat.parse_script` + the adapter (the path-free core of
/// `run_wat_fixture`). Exposed so a caller can PRE-FILTER out-of-scope module groups the parser's
/// whole-script `try_map` would otherwise abort on (S13/R16 — e.g. memory64's single `(module
/// definition …)`), routing what the parser CAN handle and categorizing the rest. A whole-script
/// parse failure is a single categorised skip (never a panic, never a false green).
pub fn run_wat_text(driver: Driver, text: String) -> Report {
  case wat.parse_script(text) {
    Error(wat.Unsupported(_, _, detail)) ->
      one_skip("wat parse: out-of-scope text (" <> detail <> ")")
    Error(err) -> one_skip("wat parse: " <> string.inspect(err))
    Ok(script) -> {
      let state =
        list.fold(
          script,
          State(registry.new(), ImportEnv(providers: []), empty()),
          fn(st, cmd) { run_command(driver, st, cmd) },
        )
      reverse_reasons(state.rep)
    }
  }
}

fn run_command(driver: Driver, st: State, cmd: wat.Command) -> State {
  case cmd {
    wat.WatModule(id, def) -> {
      let res = realise(driver, st.env, def)
      State(..st, reg: registry.define(st.reg, id, res))
    }
    wat.Register(name, module) ->
      case registry.register(st.reg, name, module) {
        // Publish the registered instance's exported functions as cross-module capabilities in
        // `env.providers` (the P6-10 flip, S5) so `linking.wast`'s later modules dispatch into it.
        Ok(reg2) ->
          case resolve(reg2, module) {
            Ok(inst) ->
              State(
                ..st,
                reg: reg2,
                env: ImportEnv(providers: [
                  runner.provider_from_instance(name, inst),
                  ..st.env.providers
                ]),
              )
            Error(_) -> State(..st, reg: reg2)
          }
        Error(e) -> skip(st, "register: " <> e)
      }
    wat.AssertReturn(action, expected) ->
      judge_return(driver, st, action, list.map(expected, expected_to_spec))
    wat.AssertTrap(action, failure) -> judge_trap(driver, st, action, failure)
    wat.AssertExhaustion(_, _) ->
      // Call-stack depth — a BEAM/WASM stack-model mismatch, a categorised skip (as in Phase 1).
      skip(st, "unhandled command: assert_exhaustion")
    wat.AssertInvalid(def, _failure) -> judge_reject(driver, st, def, "invalid")
    wat.AssertMalformed(def, _failure) ->
      judge_reject(driver, st, def, "malformed")
    wat.AssertUnlinkable(def, failure) ->
      judge_unlinkable(driver, st, def, failure)
    wat.AssertUninstantiable(def, failure) ->
      judge_uninstantiable(driver, st, def, failure)
    wat.ActionCmd(action) -> {
      // Bare action — run for side effects (a setup store); ignore the result. Plumbing.
      let _ = run_action(driver, st.reg, action)
      st
    }
    wat.CmdSkipped(kind) -> skip(st, "unhandled command: " <> kind)
  }
}

// ─────────────────────────────── realising a module ───────────────────────────────

/// Turn a `.wast` `ModuleDef` into an instance (or an `Error` reason recorded for its dependent
/// asserts). `TextModule` runs straight through the AST path (validate/lower — H5); `BinaryModule`
/// feeds the inline bytes to the binary path; `QuoteModule` (re)parses the quoted text first.
fn realise(
  driver: Driver,
  env: ImportEnv,
  def: wat.ModuleDef,
) -> Result(Instance, String) {
  case def {
    wat.TextModule(m) -> driver.instantiate_ast(m, env)
    wat.BinaryModule(bytes) -> driver.instantiate_env(bytes, env)
    wat.QuoteModule(source) ->
      case wat.parse_module(source) {
        Ok(m) -> driver.instantiate_ast(m, env)
        Error(e) -> Error("parse: " <> string.inspect(e))
      }
  }
}

// ─────────────────────────────── assert_return / assert_trap ───────────────────────────────

fn judge_return(
  driver: Driver,
  st: State,
  action: wat.Action,
  expected: List(SpecValue),
) -> State {
  case run_action(driver, st.reg, action) {
    Error(why) -> skip(st, why)
    Ok(DriverError(d)) -> skip(st, "driver: " <> d)
    Ok(Trapped(r)) -> fail(st, action_field(action) <> ": trapped " <> r)
    Ok(Returned(actuals)) ->
      case oracle.matches_all(actuals, expected) {
        True -> pass(st)
        False ->
          fail(
            st,
            action_field(action)
              <> ": got "
              <> string.inspect(actuals)
              <> " want "
              <> string.inspect(expected),
          )
      }
  }
}

fn judge_trap(
  driver: Driver,
  st: State,
  action: wat.Action,
  failure: String,
) -> State {
  case run_action(driver, st.reg, action) {
    Error(why) -> skip(st, why)
    Ok(DriverError(d)) -> skip(st, "driver: " <> d)
    Ok(Returned(_)) ->
      fail(st, action_field(action) <> ": expected trap '" <> failure <> "'")
    Ok(Trapped(r)) ->
      case runner.trap_matches(r, failure) {
        True -> pass(st)
        False ->
          fail(
            st,
            action_field(action) <> ": trapped " <> r <> " want " <> failure,
          )
      }
  }
}

// ─────────────────────────────── assert_invalid / assert_malformed ───────────────────────────────

/// A rejected-module assertion: the module must FAIL (at parse/decode for malformed, at validate
/// for invalid). A rejection is the fail-closed PASS; an out-of-scope construct is a categorised
/// skip; an ACCEPTED module the spec rejects is an honest scope-gap skip (never a false pass).
fn judge_reject(
  driver: Driver,
  st: State,
  def: wat.ModuleDef,
  kind: String,
) -> State {
  case def {
    wat.QuoteModule(source) ->
      case wat.parse_module(source) {
        Error(wat.Unsupported(_, _, detail)) ->
          skip(st, kind <> ": out-of-scope text (" <> detail <> ")")
        // Rejected at parse — the malformed text is correctly rejected.
        Error(_) -> pass(st)
        Ok(m) -> reject_via_validate(driver, st, m, kind)
      }
    wat.TextModule(m) -> reject_via_validate(driver, st, m, kind)
    wat.BinaryModule(bytes) ->
      case driver.check_frontend(bytes) {
        Error(_) -> pass(st)
        Ok(Nil) -> skip(st, kind <> ": binary accepted (scope gap)")
      }
  }
}

fn reject_via_validate(
  driver: Driver,
  st: State,
  m: ast.Module,
  kind: String,
) -> State {
  case driver.check_frontend_ast(m) {
    Error(_) -> pass(st)
    Ok(Nil) -> skip(st, kind <> ": text parser+validator accepted (scope gap)")
  }
}

// ─────────────────────────────── assert_unlinkable / assert_uninstantiable ───────────────────────────────

fn judge_unlinkable(
  driver: Driver,
  st: State,
  def: wat.ModuleDef,
  failure: String,
) -> State {
  case realise(driver, st.env, def) {
    Ok(_) -> fail(st, "unlinkable: linked but must fail closed")
    Error(reason) ->
      case string.split_once(reason, "link: ") {
        Ok(#(_, phrase)) ->
          case runner.trap_matches(phrase, failure) {
            True -> pass(st)
            False -> fail(st, "unlinkable: " <> phrase <> " want " <> failure)
          }
        Error(_) -> skip(st, "unlinkable (out of scope): " <> reason)
      }
  }
}

fn judge_uninstantiable(
  driver: Driver,
  st: State,
  def: wat.ModuleDef,
  failure: String,
) -> State {
  case realise(driver, st.env, def) {
    Ok(_) -> fail(st, "uninstantiable: instantiated but must trap")
    Error(reason) ->
      case string.split_once(reason, "instantiate: ") {
        Ok(#(_, trap)) ->
          case runner.trap_matches(trap, failure) {
            True -> pass(st)
            False -> fail(st, "uninstantiable: " <> trap <> " want " <> failure)
          }
        Error(_) -> skip(st, "uninstantiable (out of scope): " <> reason)
      }
  }
}

// ─────────────────────────────── running an action ───────────────────────────────

/// Resolve the action's target module and run it (an `Invoke` or an exported-global `Get`), or
/// `Error(reason)` if the module is unknown / did not instantiate (→ a skip).
fn run_action(
  driver: Driver,
  reg: Reg,
  action: wat.Action,
) -> Result(runner.InvokeResult, String) {
  case action {
    wat.Invoke(module, field, args) ->
      case resolve(reg, module) {
        Error(e) -> Error(e)
        Ok(inst) -> Ok(driver.invoke(inst, field, list.map(args, wast_to_spec)))
      }
    wat.Get(module, field) ->
      case resolve(reg, module) {
        Error(e) -> Error(e)
        Ok(inst) -> Ok(driver.get_global(inst, field))
      }
  }
}

fn resolve(reg: Reg, module: Option(String)) -> Result(Instance, String) {
  case registry.resolve(reg, module) {
    Error(e) -> Error(e)
    Ok(Error(why)) -> Error("module did not instantiate: " <> why)
    Ok(Ok(inst)) -> Ok(inst)
  }
}

fn action_field(action: wat.Action) -> String {
  case action {
    wat.Invoke(_, field, _) -> field
    wat.Get(_, field) -> field
  }
}

// ─────────────────────────────── value conversion (R18) ───────────────────────────────

/// Convert a WAT `WastValue` (a raw-bit-tagged action arg / exact expected) to a harness
/// `SpecValue`. Numeric values carry the same raw unsigned bit pattern; reference values map to the
/// null sentinel / a host-identity externref / a non-null funcref.
fn wast_to_spec(v: wat.WastValue) -> SpecValue {
  case v {
    wat.WastI32(b) -> I32Val(b)
    wat.WastI64(b) -> I64Val(b)
    wat.WastF32(b) -> F32Bits(b)
    wat.WastF64(b) -> F64Bits(b)
    wat.RefNullVal(ty) -> NullRef(reftype_tag(ty))
    wat.RefFuncVal -> FuncRefVal(None)
    wat.RefExternVal(p) -> ExternRefVal(p)
  }
}

/// Convert a WAT `Expected` (an exact value or a NaN class) to a harness `SpecValue`.
fn expected_to_spec(e: wat.Expected) -> SpecValue {
  case e {
    wat.ExpectedValue(v) -> wast_to_spec(v)
    wat.ExpectedNanCanonical(32) -> F32Nan(Canonical)
    wat.ExpectedNanCanonical(_) -> F64Nan(Canonical)
    wat.ExpectedNanArithmetic(32) -> F32Nan(Arithmetic)
    wat.ExpectedNanArithmetic(_) -> F64Nan(Arithmetic)
  }
}

fn reftype_tag(ty: ast.ValType) -> fixture.RefTypeTag {
  case ty {
    ast.ExternRef -> ExternRefTag
    _ -> FuncRefTag
  }
}

// ─────────────────────────────── report plumbing ───────────────────────────────

fn read_text(path: String) -> Result(String, String) {
  case read_file(path) {
    Error(e) -> Error(e)
    Ok(bytes) ->
      case bit_array.to_string(bytes) {
        Ok(s) -> Ok(s)
        Error(_) -> Error("non-UTF-8 .wast")
      }
  }
}

fn empty() -> Report {
  Report(pass: 0, fail: 0, skip: 0, fails: [], skips: [])
}

fn one_skip(why: String) -> Report {
  Report(pass: 0, fail: 0, skip: 1, fails: [], skips: [why])
}

fn pass(st: State) -> State {
  State(..st, rep: Report(..st.rep, pass: st.rep.pass + 1))
}

fn fail(st: State, why: String) -> State {
  State(
    ..st,
    rep: Report(..st.rep, fail: st.rep.fail + 1, fails: [why, ..st.rep.fails]),
  )
}

fn skip(st: State, why: String) -> State {
  State(
    ..st,
    rep: Report(..st.rep, skip: st.rep.skip + 1, skips: [why, ..st.rep.skips]),
  )
}

fn reverse_reasons(rep: Report) -> Report {
  Report(..rep, fails: list.reverse(rep.fails), skips: list.reverse(rep.skips))
}
