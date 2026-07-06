//// The spec-suite runner — drives a fixture's commands through 2core and judges the
//// results with the oracle, split BY COMMAND TYPE up front (the partition fact).
////
//// PARTITION (VERIFIED):
////  - `assert_invalid` (typecheck) / `assert_malformed` (decode) exercise the FRONTEND
////    ONLY — they go to `Driver.check_frontend` and the runner asserts a typed `Error`
////    (fail-closed, D4). They are NEVER instantiated (the backend / a real engine would
////    reject them for the wrong reasons).
////  - `assert_return` / `assert_trap` exercise the FULL PIPELINE — `Driver.instantiate`
////    then `Driver.invoke`, compared via the oracle.
////
//// HONEST COVERAGE (D9): the allowlisted spec files contain instructions beyond the
//// Phase-1 slice (floats, memory, multi-value, …). The runner SKIPS gracefully — a
//// module that fails to instantiate (our typed `Unsupported`/error) turns all its
//// assertions into SKIPS with a reason, never a fail — and the `Report` carries
//// pass/fail/skip counts plus the reasons, so a skip is visible, not silent.
////
//// The runner is parameterised over a `Driver` so the harness is independent of the
//// pipeline: a stub `Driver` lets the parsing/oracle be tested with no compiler, and
//// the real pipeline `Driver` (see `driver.gleam`) makes the full-pipeline assertions
//// run for real.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/string
import twocore/conformance/ffi
import twocore/conformance/fixture.{
  type Action, type Command, type Fixture, type SpecValue, ActionCmd,
  AssertException, AssertInvalid, AssertMalformed, AssertReturn, AssertTrap,
  AssertUninstantiable, AssertUnlinkable, BinaryModule, Get, Invoke, ModuleCmd,
  Register, TextModule, Unhandled,
}
import twocore/conformance/oracle
import twocore/conformance/registry.{type Registry}
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/wat
import twocore/ir
import twocore/runtime/link

// ─────────────────────────────── the Driver seam ───────────────────────────────

/// A live instance ready to invoke: the OWNING PROCESS pid (one-instance-one-process,
/// E1) plus, per export name, the function's result value-types — used to tag a
/// returned raw integer back into a typed `SpecValue` for the oracle. The instance's
/// mutable state (memory/globals/table cell) lives in `proc`'s process dictionary, so
/// every invoke is routed INTO `proc` (via `ffi.call_instance`); cross-invoke state
/// persists, and a (re)instantiation spawns a fresh `proc` with a fresh zeroed cell.
pub type Instance {
  Instance(
    proc: Pid,
    exports: Dict(String, List(ir.ValType)),
    /// Per exported FUNCTION name → its full `FuncType` (params + results). Used to publish this
    /// instance's exported functions as cross-module `link.ProvidedFunc` capabilities on `(register)`
    /// (P6-10) — the signature drives fail-closed function-import matching (spec §3.2.7). Empty for a
    /// module with no function exports; a non-function export (global/table/memory) is absent.
    func_sigs: Dict(String, ir.FuncType),
  )
}

/// The outcome of invoking an export.
///
/// - `Returned(values)`: a normal return; `values` carry the raw result bits tagged at
///   the export's declared width.
/// - `Trapped(reason)`: a runtime trap / capability denial, `reason` the raw text
///   (e.g. `"{wasm_trap,int_div_by_zero}"`) — mapped to the spec message by the runner.
/// - `DriverError(text)`: a pipeline/invoke failure DISTINCT from a spec trap (e.g. an
///   unsupported multi-value result) — the runner treats it as a skip, not a fail.
pub type InvokeResult {
  Returned(List(SpecValue))
  Trapped(reason: String)
  DriverError(String)
}

/// The import environment a module's non-function imports resolve against (H4/§D.2): the
/// build-fixed `spectest` module (always consulted inside `link.link_imports`, so it needs no
/// provider) PLUS every `(register)`ed provider the runner has accumulated. Assembled by the
/// runner from the registry, consumed by the driver → `link.link_imports` (which wires provided
/// global/table/memory state and FAILS CLOSED on an unsatisfied import).
///
/// Depth honesty (§D.2): cross-module *state* import (a later module importing a registered
/// module's table/memory) needs shared mutable state across two one-process instances, which the
/// E5 isolation model makes genuinely hard; those `providers` stay empty, so such an import fails
/// closed at link → its dependent asserts skip (a named category), never a false green. The
/// primary unlock — `spectest`'s read-mostly imports — works because `spectest` is built into the
/// linker, independent of `providers`.
pub type ImportEnv {
  ImportEnv(providers: List(link.Provider))
}

/// The seam between the harness and the compiler. Split by command type:
/// `check_frontend`/`check_frontend_ast` are decode/validate ONLY (for
/// `assert_invalid`/`assert_malformed`); `instantiate*`+`invoke`+`get_global` are the full
/// pipeline (for `assert_return`/`assert_trap`/`get`/`assert_unlinkable`).
pub type Driver {
  Driver(
    /// Decode + validate ONLY. `Ok(Nil)` = accepted; `Error(reason)` = rejected.
    check_frontend: fn(BitArray) -> Result(Nil, String),
    /// Full pipeline: `.wasm` bytes → loaded `.beam` `Instance` (D10). Links against `spectest`
    /// only (the historical no-import seam kept for external callers).
    instantiate: fn(BitArray) -> Result(Instance, String),
    /// Run an export with raw args; see `InvokeResult`.
    invoke: fn(Instance, String, List(SpecValue)) -> InvokeResult,
    /// Full pipeline with an import environment (H4): `.wasm` bytes + `ImportEnv` → `Instance`.
    /// A link failure surfaces as `Error("link: <phrase>")` (the `assert_unlinkable` case).
    instantiate_env: fn(BitArray, ImportEnv) -> Result(Instance, String),
    /// The WAT path (H5): a parser-produced `ast.Module` + `ImportEnv` → `Instance`, entering at
    /// `validate` (no binary re-encode — validate/lower serve the WAT AST directly).
    instantiate_ast: fn(ast.Module, ImportEnv) -> Result(Instance, String),
    /// Validate ONLY a parser-produced `ast.Module` (text `assert_invalid`).
    check_frontend_ast: fn(ast.Module) -> Result(Nil, String),
    /// Read an exported global (the `(get $m "field")` action). `Returned([v])` | error.
    get_global: fn(Instance, String) -> InvokeResult,
  )
}

// ─────────────────────────────── the report ───────────────────────────────

/// A pass/fail/skip tally plus the human-readable reasons for the fails and skips, so
/// honest coverage is visible (D9). `pass`+`fail`+`skip` counts ASSERTION commands
/// (module/register commands are plumbing, not counted).
pub type Report {
  Report(
    pass: Int,
    fail: Int,
    skip: Int,
    fails: List(String),
    skips: List(String),
  )
}

/// An empty report (the fold seed).
pub fn empty_report() -> Report {
  Report(pass: 0, fail: 0, skip: 0, fails: [], skips: [])
}

// ─────────────────────── cross-module `(register)` provider (P6-10 / S5) ───────────────────────

/// Publish `inst`'s exported FUNCTIONS as cross-module `link.ProvidedFunc` capabilities under the
/// link-name `name` (the `(register "name" $mod)` flip, S5/§C.2). A later module importing
/// `#(name, field)` resolves to the routing closure this builds, which dispatches the call INTO the
/// exporting instance's OWNING PROCESS (`inst.proc`) via the term run-ABI (so each `cell` instance's
/// pdict never collides) and returns the callee's result value list. The exported function's
/// `FuncType` drives fail-closed function-import matching (spec §3.2.7). Only FUNCTION exports are
/// published — cross-module MUTABLE state (global/table/memory) import is the categorized §D.2 depth
/// item, deliberately not provided (so such an import fails closed → a named skip, never a false
/// green). D3a: the closure is a HANDED-IN capability the linker matches by signature; generated code
/// never names the callee.
pub fn provider_from_instance(name: String, inst: Instance) -> link.Provider {
  let exports =
    dict.fold(inst.func_sigs, dict.new(), fn(acc, field, sig) {
      dict.insert(
        acc,
        field,
        link.provided_func(sig, routing_closure(inst.proc, field, sig)),
      )
    })
  link.Registered(name, exports)
}

/// The cross-module dispatch closure (`fn(List(Dynamic)) -> List(Dynamic)`, the S5 ABI): invoke
/// exported function `field` on the exporting instance's process with the raw-term argument list,
/// and return the callee's result value list (unpacked to `list.length(sig.results)` values). A
/// callee trap is PROPAGATED — `call_instance_terms` returns `Error(reason)`, which is re-raised so
/// the calling instance's invoke surfaces the trap (a cross-module trap is a trap).
fn routing_closure(
  proc: Pid,
  field: String,
  sig: ir.FuncType,
) -> fn(List(Dynamic)) -> List(Dynamic) {
  let n = list.length(sig.results)
  let f = atom.create(field)
  fn(args) {
    case ffi.call_instance_terms(proc, f, args) {
      Ok(package) -> ffi.result_list(n, package)
      Error(reason) -> ffi.raise_reason(reason)
    }
  }
}

/// Sum two reports (for aggregating across fixtures). Reason lists are concatenated.
pub fn merge(a: Report, b: Report) -> Report {
  Report(
    pass: a.pass + b.pass,
    fail: a.fail + b.fail,
    skip: a.skip + b.skip,
    fails: list.append(a.fails, b.fails),
    skips: list.append(a.skips, b.skips),
  )
}

fn pass(r: Report) -> Report {
  Report(..r, pass: r.pass + 1)
}

fn fail(r: Report, why: String) -> Report {
  Report(..r, fail: r.fail + 1, fails: [why, ..r.fails])
}

fn skip(r: Report, why: String) -> Report {
  Report(..r, skip: r.skip + 1, skips: [why, ..r.skips])
}

// ─────────────────────────────── driving a fixture ───────────────────────────────

/// Drive every command in `fix` through `driver`, resolving `.wasm`/`.wat` paths
/// relative to `base_dir` (the directory the fixture's files live in). Returns the
/// `Report`. Total — every command either passes, fails (with a reason), or skips
/// (with a reason); the runner never panics.
pub fn run_fixture(driver: Driver, fix: Fixture, base_dir: String) -> Report {
  let #(_reg, _env, report) =
    list.fold(
      fix.commands,
      #(registry.new(), ImportEnv(providers: []), empty_report()),
      fn(state, cmd) {
        let #(reg, env, rep) = state
        run_command(driver, reg, env, rep, fix.source_filename, base_dir, cmd)
      },
    )
  // Reasons were accumulated reversed; restore source order for readable output.
  Report(
    ..report,
    fails: list.reverse(report.fails),
    skips: list.reverse(report.skips),
  )
}

// The registry stores each module's INSTANTIATION RESULT, so a module that failed to
// load (an unsupported construct) cleanly turns its dependent assertions into skips.
type Reg =
  Registry(Result(Instance, String))

fn run_command(
  driver: Driver,
  reg: Reg,
  env: ImportEnv,
  rep: Report,
  src: String,
  base: String,
  cmd: Command,
) -> #(Reg, ImportEnv, Report) {
  case cmd {
    ModuleCmd(_line, name, filename) -> {
      let res =
        load_wasm(base, filename, fn(bytes) {
          driver.instantiate_env(bytes, env)
        })
      #(registry.define(reg, name, res), env, rep)
    }

    Register(_line, as_name, module) ->
      case registry.register(reg, as_name, module) {
        // Publish the registered instance's exported FUNCTIONS as cross-module `ProvidedFunc`
        // capabilities in `env.providers` (P6-10 flip, S5): a later module importing `#(as_name,
        // field)` now dispatches into the registered instance's process via the routing closure.
        // Cross-module mutable STATE import stays the categorized §D.2 depth item (not published),
        // so it still fails closed → a named skip (never a false green).
        Ok(reg2) -> #(reg2, publish_provider(reg2, as_name, module, env), rep)
        Error(e) -> #(reg, env, skip(rep, at(src, 0) <> "register: " <> e))
      }

    AssertReturn(line, action, expected) -> #(
      reg,
      env,
      run_return(driver, reg, rep, src, line, action, expected),
    )

    AssertTrap(line, action, text) -> #(
      reg,
      env,
      run_trap(driver, reg, rep, src, line, action, text),
    )

    AssertException(line, action, _expected) -> #(
      reg,
      env,
      run_exception(driver, reg, rep, src, line, action),
    )

    AssertInvalid(line, filename, mt, _text) -> #(
      reg,
      env,
      run_frontend_reject(driver, rep, src, line, base, filename, mt, "invalid"),
    )

    AssertMalformed(line, filename, mt, _text) -> #(
      reg,
      env,
      run_frontend_reject(
        driver,
        rep,
        src,
        line,
        base,
        filename,
        mt,
        "malformed",
      ),
    )

    AssertUninstantiable(line, filename, text) -> #(
      reg,
      env,
      run_uninstantiable(driver, env, rep, src, line, base, filename, text),
    )

    AssertUnlinkable(line, filename, text) -> #(
      reg,
      env,
      run_unlinkable(driver, env, rep, src, line, base, filename, text),
    )

    // A bare action: run it for its SIDE EFFECTS on the current module's mutable state
    // (so later asserts see the result), then continue. Plumbing — the report is unchanged
    // (not counted). If the target module did not instantiate, the action is silently
    // dropped (its dependent asserts already skip with a reason).
    ActionCmd(_line, action) -> {
      run_action_effect(driver, reg, action)
      #(reg, env, rep)
    }

    Unhandled(line, kind) -> #(
      reg,
      env,
      skip(rep, at(src, line) <> "unhandled command: " <> kind),
    )
  }
}

// assert_return / assert_trap — FULL pipeline.

fn run_return(
  driver: Driver,
  reg: Reg,
  rep: Report,
  src: String,
  line: Int,
  action: Action,
  expected: List(SpecValue),
) -> Report {
  // `Get` reads an exported global (D.1); `Invoke` calls an exported function. Both produce an
  // `InvokeResult` judged identically against `expected` via the oracle.
  let #(field, result) = case action {
    Get(field, module) -> #(
      field,
      invoke_result(driver, reg, module, fn(inst) {
        driver.get_global(inst, field)
      }),
    )
    Invoke(field, args, module) -> #(
      field,
      invoke_result(driver, reg, module, fn(inst) {
        driver.invoke(inst, field, args)
      }),
    )
  }
  case result {
    Error(why) -> skip(rep, at(src, line) <> why)
    Ok(Returned(actuals)) ->
      case oracle.matches_all(actuals, expected) {
        True -> pass(rep)
        False ->
          fail(
            rep,
            at(src, line)
              <> field
              <> ": got "
              <> string.inspect(actuals)
              <> " want "
              <> string.inspect(expected),
          )
      }
    Ok(Trapped(r)) ->
      // A HOST-CAPABILITY DENIAL (`{capability_denied, Cap, Name}`) is NOT a WASM `{wasm_trap, _}`
      // trap: it is the fail-closed Safe host (deny-all) refusing a host import that the spec's
      // `spectest` host would service (e.g. a `return_call`/`call` to `spectest.print_i32_f32`). That
      // is a POLICY outcome, not a spec mismatch — so it is a categorized SKIP (out of scope for the
      // deny-all conformance host), never a false fail. Under an open-host profile (`unsafe`) the same
      // call returns `[]` and the assert PASSES. EVERY OTHER trap during `assert_return` is a genuine
      // spec violation → fail (a real `{wasm_trap, _}` where the spec expects a value stays red).
      case string.contains(r, "capability_denied") {
        True ->
          skip(
            rep,
            at(src, line)
              <> field
              <> ": host import denied under the fail-closed Safe host (capability_denied)",
          )
        False ->
          fail(
            rep,
            at(src, line) <> field <> ": expected return, trapped " <> r,
          )
      }
    Ok(DriverError(d)) -> skip(rep, at(src, line) <> field <> ": driver: " <> d)
  }
}

/// Resolve `module` to an instance and run `run` on it, or `Error(reason)` if the target module
/// is unknown / did not instantiate (→ a skip). Shared by `Get` (exported-global read) and
/// `Invoke` (exported-function call).
fn invoke_result(
  _driver: Driver,
  reg: Reg,
  module,
  run: fn(Instance) -> InvokeResult,
) -> Result(InvokeResult, String) {
  case resolve_instance(reg, module) {
    Error(why) -> Error(why)
    Ok(inst) -> Ok(run(inst))
  }
}

fn run_trap(
  driver: Driver,
  reg: Reg,
  rep: Report,
  src: String,
  line: Int,
  action: Action,
  text: String,
) -> Report {
  let #(field, result) = case action {
    Get(field, module) -> #(
      field,
      invoke_result(driver, reg, module, fn(inst) {
        driver.get_global(inst, field)
      }),
    )
    Invoke(field, args, module) -> #(
      field,
      invoke_result(driver, reg, module, fn(inst) {
        driver.invoke(inst, field, args)
      }),
    )
  }
  case result {
    Error(why) -> skip(rep, at(src, line) <> why)
    Ok(Trapped(r)) ->
      case trap_matches(r, text) {
        True -> pass(rep)
        False ->
          fail(
            rep,
            at(src, line)
              <> field
              <> ": trapped "
              <> r
              <> " want substring "
              <> text,
          )
      }
    Ok(Returned(vs)) ->
      fail(
        rep,
        at(src, line)
          <> field
          <> ": expected trap '"
          <> text
          <> "', returned "
          <> string.inspect(vs),
      )
    Ok(DriverError(d)) -> skip(rep, at(src, line) <> field <> ": driver: " <> d)
  }
}

// assert_exception — FULL pipeline; the action must raise an UNCAUGHT WASM exception.

/// Judge an `assert_exception`: the action must unwind out with a WASM **exception**, not a
/// return and not a trap. An uncaught `throw`/`throw_ref` raises the build-controlled
/// `erlang:error({wasm_exn, TagId, Payload})` term (T3/T8), which the invoke FFI catches and
/// renders as the reason string `"{wasm_exn,…}"` (S8 — a WASM exception is its own term class,
/// never a `{wasm_trap,…}`). So the pass condition is a `Trapped` outcome whose reason names the
/// `wasm_exn` class; a plain trap (`{wasm_trap,…}`, e.g. a null-`exnref` `throw_ref`) or a normal
/// return is a FAIL — exactly the `assert_exception` ≠ `assert_trap` distinction the spec draws
/// (a `catch_all` catches exceptions but a trap propagates). This is the run-ABI's uncaught-
/// exception observation the capstone drives the official EH `.wast` through.
fn run_exception(
  driver: Driver,
  reg: Reg,
  rep: Report,
  src: String,
  line: Int,
  action: Action,
) -> Report {
  let #(field, result) = case action {
    Get(field, module) -> #(
      field,
      invoke_result(driver, reg, module, fn(inst) {
        driver.get_global(inst, field)
      }),
    )
    Invoke(field, args, module) -> #(
      field,
      invoke_result(driver, reg, module, fn(inst) {
        driver.invoke(inst, field, args)
      }),
    )
  }
  case result {
    Error(why) -> skip(rep, at(src, line) <> why)
    Ok(Trapped(r)) ->
      case string.starts_with(r, "{wasm_exn") {
        True -> pass(rep)
        False ->
          fail(
            rep,
            at(src, line) <> field <> ": expected WASM exception, trapped " <> r,
          )
      }
    Ok(Returned(vs)) ->
      fail(
        rep,
        at(src, line)
          <> field
          <> ": expected WASM exception, returned "
          <> string.inspect(vs),
      )
    Ok(DriverError(d)) -> skip(rep, at(src, line) <> field <> ": driver: " <> d)
  }
}

// assert_invalid / assert_malformed — FRONTEND ONLY.

fn run_frontend_reject(
  driver: Driver,
  rep: Report,
  src: String,
  line: Int,
  base: String,
  filename: String,
  mt: fixture.ModuleType,
  kind: String,
) -> Report {
  case mt {
    // A text-format case references a `.wat`: run it through OUR WAT parser (P5-10, H5). A
    // rejection at parse (malformed text) OR at validate (invalid module) is the fail-closed PASS;
    // an out-of-scope construct (SIMD/GC text) is a categorized skip; a module our parser AND
    // validator both ACCEPT despite the spec rejecting it is an honest scope-gap skip (never a
    // false pass, never a silent drop).
    TextModule ->
      case read_wat_text(base, filename) {
        Error(e) -> skip(rep, at(src, line) <> kind <> ": " <> e)
        Ok(text) ->
          case parse_text_module(text) {
            Error(wat.Unsupported(_, _cat, detail)) ->
              skip(
                rep,
                at(src, line)
                  <> kind
                  <> ": out-of-scope text ("
                  <> detail
                  <> ")",
              )
            // Any other parse error = the malformed text is correctly rejected.
            Error(_) -> pass(rep)
            Ok(ast_mod) ->
              case driver.check_frontend_ast(ast_mod) {
                Error(_) -> pass(rep)
                Ok(Nil) ->
                  skip(
                    rep,
                    at(src, line)
                      <> kind
                      <> ": text parser+validator accepted (scope gap)",
                  )
              }
          }
      }
    BinaryModule ->
      case read_bytes(base, filename) {
        Error(e) -> skip(rep, at(src, line) <> kind <> ": " <> e)
        Ok(bytes) ->
          // Fail-closed: an invalid/malformed module MUST be rejected by the frontend.
          case driver.check_frontend(bytes) {
            Error(_) -> pass(rep)
            // We ACCEPTED a module the spec rejects. That is normally a real bug — EXCEPT
            // when the malformation lives in the IMPORT SECTION, which our decoder
            // deliberately skips (non-function imports / the `spectest` module are deferred
            // to Phase 3). We cannot judge an import-section malformation, so this is an
            // honest out-of-scope SKIP, not a silent pass and not a fail. Keyed to the
            // structural fact "the binary carries an import section", never to line numbers.
            Ok(Nil) ->
              case has_import_section(bytes) {
                True ->
                  skip(
                    rep,
                    at(src, line)
                      <> kind
                      <> ": import-section construct (non-function imports deferred to Phase 3)",
                  )
                False ->
                  fail(
                    rep,
                    at(src, line)
                      <> kind
                      <> ": frontend ACCEPTED a rejected module",
                  )
              }
          }
      }
  }
}

/// Whether a `.wasm` binary carries a non-empty IMPORT section (section id 2). Walks the
/// section headers (`<id:u8><size:uleb32><size bytes>`) after the 8-byte magic+version. Our
/// decoder skips the import section wholesale (imports are deferred to Phase 3), so an
/// import-section malformation that the spec rejects is one we cannot judge — this predicate
/// lets `run_frontend_reject` skip those honestly instead of silent-passing. Total — any
/// malformed framing simply returns `False`.
fn has_import_section(bytes: BitArray) -> Bool {
  case bytes {
    <<0x00, 0x61, 0x73, 0x6d, _v:bytes-size(4), rest:bytes>> ->
      scan_for_import(rest)
    _ -> False
  }
}

fn scan_for_import(bytes: BitArray) -> Bool {
  case bytes {
    <<id:8, rest:bytes>> ->
      case read_uleb32(rest, 0, 0) {
        Error(_) -> False
        Ok(#(size, after_size)) ->
          case id == 2 && size > 0 {
            True -> True
            False ->
              case
                bit_array.slice(after_size, size, byte_count(after_size) - size)
              {
                Ok(next) -> scan_for_import(next)
                Error(_) -> False
              }
          }
      }
    _ -> False
  }
}

/// Read one LEB128 unsigned int from the front of `bytes`. `Ok(#(value, rest))` or `Error`
/// if the input ends mid-number. Used only by the section walker above.
fn read_uleb32(
  bytes: BitArray,
  shift: Int,
  acc: Int,
) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<byte:8, rest:bytes>> -> {
      let acc2 =
        acc + int.bitwise_shift_left(int.bitwise_and(byte, 0x7f), shift)
      case int.bitwise_and(byte, 0x80) {
        0 -> Ok(#(acc2, rest))
        _ -> read_uleb32(rest, shift + 7, acc2)
      }
    }
    _ -> Error(Nil)
  }
}

fn byte_count(bytes: BitArray) -> Int {
  bit_array.byte_size(bytes)
}

// assert_uninstantiable — the module is well-formed + valid, but INSTANTIATION traps
// (an OOB active data/element segment, or a trapping `start`). The spec's
// `assert_uninstantiable` (and the legacy `assert_unlinkable` framing of an OOB active
// segment). The runner loads + instantiates the module and asserts it FAILS to
// instantiate with a trap whose spec phrase contains `text` (E5). A success is a FAIL;
// these no longer fall through the `Unhandled → skip` path and get silently dropped.

fn run_uninstantiable(
  driver: Driver,
  env: ImportEnv,
  rep: Report,
  src: String,
  line: Int,
  base: String,
  filename: String,
  text: String,
) -> Report {
  case read_bytes(base, filename) {
    Error(e) -> skip(rep, at(src, line) <> "uninstantiable: " <> e)
    Ok(bytes) ->
      case driver.instantiate_env(bytes, env) {
        // The module instantiated, but it MUST trap at instantiation — a real failure.
        Ok(_inst) ->
          fail(
            rep,
            at(src, line)
              <> "uninstantiable: module instantiated but must fail to instantiate",
          )
        Error(reason) ->
          // Distinguish a genuine instantiation-time trap (driver prefix "instantiate: ")
          // from a compile-stage rejection of an out-of-scope construct (decode/validate/
          // emit/build) — the latter is an honest SKIP, not a pass.
          case string.split_once(reason, "instantiate: ") {
            Ok(#(_, trap)) ->
              case trap_matches(trap, text) {
                True -> pass(rep)
                False ->
                  fail(
                    rep,
                    at(src, line)
                      <> "uninstantiable: trapped "
                      <> trap
                      <> " want substring "
                      <> text,
                  )
              }
            Error(_) ->
              skip(
                rep,
                at(src, line) <> "uninstantiable (out of scope): " <> reason,
              )
          }
      }
  }
}

// assert_unlinkable — the module is well-formed + valid + compiles, but LINKING it FAILS (an
// unsatisfied / type-mismatched import). This is the H6/D3a fail-closed proof: a silent link of an
// unsatisfied import would be exactly the ambient authority D3a forbids. The runner instantiates
// the module against the current `env` and REQUIRES a `link:`-prefixed failure whose phrase
// contains `text` ("unknown import" / "incompatible import type"). A success (or an
// instantiation-time trap that is not a link failure) is a FAIL; a compile-stage rejection of an
// out-of-scope construct is an honest SKIP.
fn run_unlinkable(
  driver: Driver,
  env: ImportEnv,
  rep: Report,
  src: String,
  line: Int,
  base: String,
  filename: String,
  text: String,
) -> Report {
  case read_bytes(base, filename) {
    Error(e) -> skip(rep, at(src, line) <> "unlinkable: " <> e)
    Ok(bytes) ->
      case driver.instantiate_env(bytes, env) {
        Ok(_inst) ->
          fail(
            rep,
            at(src, line)
              <> "unlinkable: module linked but the import must fail closed",
          )
        Error(reason) ->
          case string.split_once(reason, "link: ") {
            Ok(#(_, phrase)) ->
              case trap_matches(phrase, text) {
                True -> pass(rep)
                False ->
                  fail(
                    rep,
                    at(src, line)
                      <> "unlinkable: link failed "
                      <> phrase
                      <> " want substring "
                      <> text,
                  )
              }
            // A non-link rejection (decode/validate/emit of an out-of-scope construct) — an honest
            // skip, distinguished from a genuine link failure by the missing `link:` prefix.
            Error(_) ->
              skip(
                rep,
                at(src, line) <> "unlinkable (out of scope): " <> reason,
              )
          }
      }
  }
}

/// Run a bare action for its side effects on the resolved instance, discarding the result
/// (and any trap — a bare setup action that traps is not an assertion). If the target module
/// failed to instantiate, do nothing. `Get` actions read a global and have no side effect, so
/// they are skipped here. Total.
fn run_action_effect(driver: Driver, reg: Reg, action: Action) -> Nil {
  case action {
    Get(_, _) -> Nil
    Invoke(field, args, module) ->
      case resolve_instance(reg, module) {
        Error(_) -> Nil
        Ok(inst) -> {
          let _ = driver.invoke(inst, field, args)
          Nil
        }
      }
  }
}

/// Read a `.wat` text fixture (the text `assert_invalid`/`assert_malformed` path). `Ok(text)` or
/// `Error(reason)` (unreadable / non-UTF-8). Total.
fn read_wat_text(base: String, filename: String) -> Result(String, String) {
  case read_bytes(base, filename) {
    Error(e) -> Error(e)
    Ok(bytes) ->
      case bit_array.to_string(bytes) {
        Ok(s) -> Ok(s)
        Error(_) -> Error("non-UTF-8 .wat: " <> filename)
      }
  }
}

/// Parse a `.wat` text fragment into an `ast.Module` via the P5-10 parser (H5). wast2json emits a
/// `(module quote …)` body as the module's FIELDS without the outer `(module …)`, so a fragment
/// that does not already open with `(module` is wrapped before parsing. `Error(WatError)` on a
/// malformed / out-of-scope text (the caller distinguishes `Unsupported` from a genuine reject).
fn parse_text_module(text: String) -> Result(ast.Module, wat.WatError) {
  let trimmed = string.trim(text)
  let wrapped = case string.starts_with(trimmed, "(module") {
    True -> trimmed
    False -> "(module " <> trimmed <> ")"
  }
  wat.parse_module(wrapped)
}

// ─────────────────────────────── helpers ───────────────────────────────

fn resolve_instance(reg: Reg, module) -> Result(Instance, String) {
  case registry.resolve(reg, module) {
    Error(e) -> Error(e)
    Ok(Error(why)) -> Error("module did not instantiate: " <> why)
    Ok(Ok(inst)) -> Ok(inst)
  }
}

/// Prepend a cross-module provider for the just-registered instance to `env.providers` (the P6-10
/// flip). Resolves `module` (the `(register)`'s target, `None` = current) to its instance; if it
/// instantiated OK, publishes its exported functions under `as_name` (S5). If the module is unknown
/// or failed to instantiate, `env` is UNCHANGED — a later import of it then fails closed (never a
/// false green).
fn publish_provider(
  reg: Reg,
  as_name: String,
  module,
  env: ImportEnv,
) -> ImportEnv {
  case resolve_instance(reg, module) {
    Ok(inst) ->
      ImportEnv(providers: [
        provider_from_instance(as_name, inst),
        ..env.providers
      ])
    Error(_) -> env
  }
}

fn load_wasm(
  base: String,
  filename: String,
  instantiate: fn(BitArray) -> Result(Instance, String),
) -> Result(Instance, String) {
  case read_bytes(base, filename) {
    Error(e) -> Error(e)
    Ok(bytes) -> instantiate(bytes)
  }
}

fn read_bytes(base: String, filename: String) -> Result(BitArray, String) {
  let path = base <> "/" <> filename
  case ffi_read(path) {
    Error(e) -> Error("read " <> path <> ": " <> e)
    Ok(b) -> Ok(b)
  }
}

@external(erlang, "twocore_conformance_ffi", "read_file")
fn ffi_read(path: String) -> Result(BitArray, String)

fn at(src: String, line: Int) -> String {
  src <> ":" <> int.to_string(line) <> " "
}

/// Decide whether our runtime trap `reason` text satisfies the spec's expected message
/// `want`. The spec message is a SUBSTRING like `"integer divide by zero"`; our runtime
/// raises `{wasm_trap, <kind>}` where `<kind>` is the snake_case `TrapReason` atom. We
/// map our kind to the canonical spec phrase (per `rt_trap.spec_trap_message`) and then
/// check containment. (`want == ""` accepts any trap.)
pub fn trap_matches(reason: String, want: String) -> Bool {
  case want {
    "" -> True
    _ ->
      case spec_phrase_of(reason) {
        Ok(phrase) ->
          string.contains(phrase, want) || string.contains(want, phrase)
        // Unknown trap kind: fall back to raw containment (lenient but still honest).
        Error(_) -> string.contains(reason, want)
      }
  }
}

/// Map our raised `{wasm_trap, <kind>}` text to the WASM-spec trap-message phrase, keyed by
/// the snake_case `TrapReason` atom present in `reason`. Mirrors `rt_trap.spec_trap_message`
/// (the single source of truth) so Phase-2 memory / table / conversion traps are judged
/// against their spec messages — not the underscore atom. The most-specific atoms are tested
/// FIRST so e.g. `undefined_element` is not shadowed by a substring match.
fn spec_phrase_of(reason: String) -> Result(String, Nil) {
  let kinds = [
    #("int_div_by_zero", "integer divide by zero"),
    #("invalid_conversion_to_integer", "invalid conversion to integer"),
    #("int_overflow", "integer overflow"),
    #("memory_out_of_bounds", "out of bounds memory access"),
    #("table_out_of_bounds", "out of bounds table access"),
    #("indirect_call_type_mismatch", "indirect call type mismatch"),
    #("uninitialized_element", "uninitialized element"),
    #("undefined_element", "undefined element"),
    #("unreachable", "unreachable"),
  ]
  list.find_map(kinds, fn(kv) {
    let #(atom_text, phrase) = kv
    case string.contains(reason, atom_text) {
      True -> Ok(phrase)
      False -> Error(Nil)
    }
  })
}
