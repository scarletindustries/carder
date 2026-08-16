//// Unit 11d — the **Safe policy pass** (`ir_lower`) acceptance proofs.
////
//// carder is a compiler BACKEND, so this drives `.ir` (not source bytes): it reads the committed
//// `test/carder/ir/corpus/*.ir` programs, parses them with `pipeline.parse_ir`, and runs them
//// through **ir_lower(Safe)** → emit_core → build_beam → invoke on the BEAM, diffing against the
//// spec-sourced `.expected` values — reusing the harness's `corpus`/`oracle`/`runner`/`ffi`
//// unchanged. Each `.ir` was generated from the corresponding acceptance `.wasm` and is
//// byte-for-byte equivalent compiler input, so the artifact under test is unchanged.
////
//// What this file asserts is the **policy pass and the capability boundary**, not source decoding:
////   - the metered/constant-space program stays spec-green *through* `ir_lower`'s `Charge`
////     insertion (`sum_to`);
//// - an allowlisted `("std","gcd")` stdlib call compiles and runs;
//// - a non-allowlisted `CallHost` is REJECTED fail-closed at BUILD time by `ir_lower`;
//// - a DECLARED host import is left to run time and REJECTED by the deny-all host, and an
////   unprovided host import cannot become a runnable instance at all (`hostimport`).
////
//// The broad "every corpus program is spec-green under every posture" sweep is NOT here: it is
//// `test/carder/tier/combos.gleam` + the `tier/*` suites, which drive the SAME `.ir` corpus
//// against the SAME `.expected` oracles across the whole `(strategy × tier × policy)` matrix.

import carder/backend/build_beam
import carder/harness/corpus.{type Expect, Rejects, Returns, Traps}
import carder/harness/ffi
import carder/harness/fixture.{
  type SpecValue, F32Bits, F32Nan, F64Bits, F64Nan, I32Val, I64Val,
}
import carder/harness/oracle
import carder/harness/runner.{type Instance}
import carder/ir
import carder/middle/ir_lower
import carder/pipeline
import carder/runtime/profiles
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string

/// The committed `.ir` acceptance corpus + its spec-sourced `.expected` oracles.
const corpus_dir = "test/carder/ir/corpus"

// ─────────────────────────────── the Safe policy pass, end-to-end ───────────────────────────────

/// `sum_to` — the loop/break/continue program stays spec-green AND a CONSTANT-SPACE BEAM loop
/// with the metering `Charge` inserted by `ir_lower` (the corpus drives `sum_to(100)`; the
/// large-n constant-space proof lives in `ir_lower_test`). This is the end-to-end evidence that
/// the Safe policy pass does not change an observable answer.
pub fn sum_to_through_safe_test() {
  assert check_program("sum_to") == []
}

/// `hostimport` — a module declaring a host import NOBODY provides cannot become a runnable
/// instance (its `.expected` is `reject`): the generated module takes `instantiate/1(Imports)`,
/// so the no-provider `instantiate/0` boot fails closed rather than silently running with an
/// ambient host. The Safe pass does not change that outcome.
pub fn hostimport_rejected_through_safe_test() {
  assert check_program("hostimport") == []
}

// ─────────────────────────────── the call_host capability boundary, gated by ir_lower ───────────────────────────────

/// (A) The allowlisted `own`-stdlib call WORKS through the Safe pass: `ir_lower` permits
/// `CallHost("std","gcd")` (its `rt_stdlib:gcd/2` target is on the `rt_bif` allowlist) and
/// `emit_core` routes it to a direct `rt_stdlib:gcd` call. `gcd(12,18) == 6`.
pub fn allowlisted_stdlib_call_runs_test() {
  let assert Ok(mod_atom) = load_ir(gcd_module())
  assert ffi.catch_apply(mod_atom, atom.create("g"), [12, 18]) == Ok(6)
}

/// (B) A NON-allowlisted `CallHost` (a capability that is neither the stdlib capability nor a
/// declared host import) is REJECTED FAIL-CLOSED AT BUILD TIME by `ir_lower` — the module
/// never becomes a runnable instance (`Error(IrLowerFailed(ForbiddenHost(_)))`).
pub fn non_allowlisted_call_host_rejected_at_build_test() {
  assert pipeline.ir_to_core(forbidden_module(), profiles.safe())
    == Error(pipeline.IrLowerFailed(ir_lower.ForbiddenHost("evil", "run")))
}

/// (C) A DECLARED host import is NOT rejected at build time — `ir_lower` leaves it for the
/// deny-all host, which REJECTS it AT RUN TIME with a catchable `{capability_denied, …}`
/// (the capability boundary exercised end-to-end, overview pitfall #3).
pub fn declared_host_import_rejected_at_runtime_test() {
  let assert Ok(mod_atom) = load_ir(declared_host_module())
  let assert Error(reason) =
    ffi.catch_apply(mod_atom, atom.create("useimport"), [123])
  assert string.contains(reason, "capability_denied")
}

// ─────────────────────────────── driving machinery (reuses the harness corpus/oracle/ffi) ───────────────────────────────

/// Compile + run a `corpus/<name>.ir` program through the FULL Safe pipeline (with `ir_lower`)
/// and return the list of failure descriptions (empty ⇒ every `.expected` line held). A
/// `reject` program asserts the module fails to instantiate; otherwise it instantiates once
/// and every expectation is invoked and compared via the harness oracle.
fn check_program(name: String) -> List(String) {
  let assert Ok(text) = read_text(name <> ".ir")
  let assert Ok(expected_text) = read_text(name <> ".expected")
  let assert Ok(expects) = corpus.parse(expected_text)

  case expects {
    [Rejects] ->
      case instantiate_safe(text) {
        Error(_) -> []
        Ok(_) -> [name <> ": expected REJECT, but the module instantiated"]
      }
    _ ->
      case instantiate_safe(text) {
        Error(e) -> [name <> ": module failed to instantiate: " <> e]
        Ok(inst) ->
          list.filter_map(expects, fn(ex) {
            case run_expect(inst, ex) {
              Ok(Nil) -> Error(Nil)
              Error(msg) -> Ok(name <> ": " <> msg)
            }
          })
      }
  }
}

/// parse `.ir` → **ir_lower(Safe)** → emit_core → build → load `text`, then **instantiate** it in
/// its own owned process (E5, one-instance-one-process): `start_instance` runs the generated
/// `instantiate/0` in that process, seeding its cell. Each module gets a unique name so loads do
/// not clobber. Returns `Error(reason)` — never a panic — for any stage that rejects, or
/// `Error("instantiate: …")` for an instantiation-time trap / a missing-provider boot.
fn instantiate_safe(text: String) -> Result(Instance, String) {
  use m0 <- result.try(
    pipeline.parse_ir(text)
    |> result.map_error(fn(e) { "parse .ir: " <> string.inspect(e) }),
  )
  let m = ir.Module(..m0, name: uniquify(m0.name))
  // `ir_to_cmod` runs the Safe policy pass (ir_lower) BEFORE emit_core — the proof point.
  use cmod <- result.try(
    pipeline.ir_to_cmod(m, profiles.safe())
    |> result.map_error(pipeline.describe),
  )
  use mod_atom <- result.try(
    build_beam.compile_and_load(cmod)
    |> result.map_error(fn(e) { "build: " <> string.inspect(e) }),
  )
  use proc <- result.try(
    ffi.start_instance(mod_atom)
    |> result.map_error(fn(t) { "instantiate: " <> t }),
  )
  // The acceptance corpus is single-module (no cross-module `(register)`), so it publishes no
  // function capabilities — an empty `func_sigs` (P6-10).
  Ok(runner.Instance(
    proc: proc,
    exports: export_types(m),
    func_sigs: dict.new(),
  ))
}

/// Check one `.expected` line against the running instance via the harness oracle / trap matcher.
fn run_expect(inst: Instance, ex: Expect) -> Result(Nil, String) {
  case ex {
    Rejects -> Error("unexpected 'reject' among value expectations")
    corpus.InstantiateTraps(_) ->
      Error("unexpected 'instantiate' among value expectations")
    Returns(field, args, results) ->
      case invoke(inst, field, args) {
        runner.Returned(actual) ->
          case oracle.matches_all(actual, results) {
            True -> Ok(Nil)
            False ->
              Error(
                field
                <> ": got "
                <> string.inspect(actual)
                <> " want "
                <> string.inspect(results),
              )
          }
        runner.Trapped(r) -> Error(field <> ": expected return, trapped " <> r)
        runner.DriverError(x) -> Error(field <> ": driver error " <> x)
      }
    Traps(field, args, text) ->
      case invoke(inst, field, args) {
        runner.Trapped(r) ->
          case runner.trap_matches(r, text) {
            True -> Ok(Nil)
            False ->
              Error(
                field <> ": trapped " <> r <> " want substring '" <> text <> "'",
              )
          }
        runner.Returned(v) ->
          Error(
            field
            <> ": expected trap '"
            <> text
            <> "', returned "
            <> string.inspect(v),
          )
        runner.DriverError(x) -> Error(field <> ": driver error " <> x)
      }
  }
}

/// Invoke export `field` with `args`, tagging the raw result at the export's declared width
/// (mirrors the harness `driver.invoke`, here driving the Safe-pass instance). Single-result only
/// (the Phase-1 corpus); a trap / capability denial becomes `Trapped`.
fn invoke(
  inst: Instance,
  field: String,
  args: List(SpecValue),
) -> runner.InvokeResult {
  case dict.get(inst.exports, field) {
    Error(_) -> runner.DriverError("no such export: " <> field)
    Ok(results) -> {
      let arg_ints = list.map(args, spec_to_raw)
      // Route the invoke INTO the instance's owned process so it reads that instance's cell.
      case results {
        [ty] ->
          case ffi.call_instance(inst.proc, atom.create(field), arg_ints) {
            Ok(raw) -> runner.Returned([tag(ty, raw)])
            Error(t) -> runner.Trapped(t)
          }
        [] ->
          case ffi.call_instance(inst.proc, atom.create(field), arg_ints) {
            Ok(_) -> runner.Returned([])
            Error(t) -> runner.Trapped(t)
          }
        _ -> runner.DriverError("multi-value result unsupported")
      }
    }
  }
}

/// The raw integer bits an argument carries (NaN args, which the corpus never passes, map
/// to 0). Mirrors the harness `driver.spec_to_raw`.
fn spec_to_raw(v: SpecValue) -> Int {
  case v {
    I32Val(b) | I64Val(b) | F32Bits(b) | F64Bits(b) -> b
    F32Nan(_) | F64Nan(_) -> 0
    // Reference values carry no raw bits (the acceptance corpus is numeric); 0 stays total.
    fixture.NullRef(_) | fixture.ExternRefVal(_) | fixture.FuncRefVal(_) -> 0
    // A GC ref carries no raw bits either (this corpus is numeric); 0 stays total.
    fixture.GcRef(_) -> 0
    // A v128 is compared lane-wise, never as a scalar; the acceptance corpus is numeric.
    fixture.V128Val(_, _) -> 0
  }
}

/// Tag a raw result integer as a `SpecValue` at the export's declared width (mirrors the harness
/// `driver.tag`). `TTerm` (never produced by the numeric path) falls back to an i32 tag so the
/// function is total.
fn tag(ty: ir.ValType, raw: Int) -> SpecValue {
  case ty {
    ir.TI32 -> I32Val(raw)
    ir.TI64 -> I64Val(raw)
    ir.TF32 -> F32Bits(raw)
    ir.TF64 -> F64Bits(raw)
    ir.TTerm -> I32Val(raw)
    ir.TFuncRef -> I32Val(raw)
    ir.TExternRef -> I32Val(raw)
    // A `v128` result is 16 raw little-endian bytes (S14); the numeric acceptance corpus never
    // produces one, so this arm is unreachable — an i32 fallback keeps the function total.
    ir.TV128 -> I32Val(raw)
    // An `exnref` (Phase-7) is a reference; the acceptance corpus never returns one — an i32
    // fallback keeps the function total.
    ir.TExnRef -> I32Val(raw)
  }
}

// ─────────────────────────────── hand-built IR fixtures (call_host scenarios) ───────────────────────────────

/// A memoryless, import-free numeric `ir.Module` named uniquely (so repeated loads never clobber),
/// exporting every function in `fns` under its own name.
fn numeric_module(name: String, fns: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "carder@acceptance@" <> name <> "_" <> int.to_string(ffi.unique_int()),
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: fns,
    exports: list.map(fns, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// A module that calls the allowlisted `("std","gcd")` stdlib entry.
fn gcd_module() -> ir.Module {
  let f =
    ir.Function(
      name: "g",
      params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        ["r"],
        ir.CallHost("std", "gcd", [ir.Var("p0"), ir.Var("p1")]),
        ir.Return([ir.Var("r")]),
      ),
    )
  numeric_module("gcd", [f])
}

/// A module whose `CallHost` names an un-allowlisted capability with no declared import.
fn forbidden_module() -> ir.Module {
  let f =
    ir.Function(
      name: "e",
      params: [ir.Local("p0", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        ["r"],
        ir.CallHost("evil", "run", [ir.Var("p0")]),
        ir.Return([ir.Var("r")]),
      ),
    )
  numeric_module("forbidden", [f])
}

/// A module with a DECLARED host import that the deny-all host rejects at run time.
fn declared_host_module() -> ir.Module {
  let f =
    ir.Function(
      name: "useimport",
      params: [ir.Local("p0", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        ["r"],
        ir.CallHost("env", "forbidden", [ir.Var("p0")]),
        ir.Return([ir.Var("r")]),
      ),
    )
  ir.Module(..numeric_module("declared", [f]), imports: [
    ir.ImportFn("env", "forbidden", ir.FuncType([ir.TI32], [ir.TI32])),
  ])
}

/// Compile a hand-built IR module through the Safe pipeline (ir_lower → emit → build) and
/// load it, returning the module atom (or the pipeline error as text).
fn load_ir(m: ir.Module) -> Result(Atom, String) {
  use cmod <- result.try(
    pipeline.ir_to_cmod(m, profiles.safe())
    |> result.map_error(pipeline.describe),
  )
  build_beam.compile_and_load(cmod)
  |> result.map_error(fn(e) { "build: " <> string.inspect(e) })
}

// ─────────────────────────────── value marshalling (mirrors the harness driver) ───────────────────────────────

/// Build the `export name → result value-types` table from the IR module.
fn export_types(m: ir.Module) -> Dict(String, List(ir.ValType)) {
  let by_fn =
    list.fold(m.functions, dict.new(), fn(acc, f) {
      dict.insert(acc, f.name, f.result)
    })
  list.fold(m.exports, dict.new(), fn(acc, e) {
    case e {
      ir.ExportFn(export_name, fn_name) ->
        case dict.get(by_fn, fn_name) {
          Ok(results) -> dict.insert(acc, export_name, results)
          Error(_) -> acc
        }
      ir.ExportGlobal(..)
      | ir.ExportTable(..)
      | ir.ExportMemory(..)
      | ir.ExportTag(..) -> acc
    }
  })
}

/// Suffix a module name with a process-unique integer so repeated loads never clobber.
fn uniquify(name: String) -> String {
  name <> "_" <> int.to_string(ffi.unique_int())
}

/// Read a corpus file as UTF-8 text (`.ir` source or a `.expected` oracle).
fn read_text(file: String) -> Result(String, String) {
  use bytes <- result.try(ffi.read_file(corpus_dir <> "/" <> file))
  bit_array.to_string(bytes) |> result.replace_error("non-UTF8 corpus file")
}
