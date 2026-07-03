//// Unit 11d — the Phase-1 GOAL PROOF, now WITH the Safe policy pass (`ir_lower`) in the
//// chain. It drives unit 07's acceptance corpus (`test/twocore/conformance/corpus/*`)
//// through decode → validate → lower → **ir_lower(Safe)** → emit_core → build_beam → invoke
//// on the BEAM, and diffs against the spec-sourced `.expected` values — reusing 07's
//// `corpus`/`oracle`/`runner`/`ffi` UNCHANGED (this file never edits a unit-07 file).
////
//// The only difference from 07's own `corpus_test` is that the policy pass is now in the
//// pipeline (`pipeline.ir_to_core(_, profiles.safe())` runs `ir_lower` before `emit_core`),
//// so the proof is that the corpus stays green *through the Safe policy pass* — numeric
//// edges, traps, the constant-space loop, AND the `call_host` capability boundary now gated
//// by `ir_lower`:
////   - an allowlisted `("std","gcd")` stdlib call compiles and runs;
////   - a non-allowlisted `CallHost` is REJECTED fail-closed at BUILD time by `ir_lower`;
////   - a DECLARED host import is left to run time and REJECTED by the deny-all host.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import twocore/backend/build_beam
import twocore/conformance/corpus.{type Expect, Rejects, Returns, Traps}
import twocore/conformance/ffi
import twocore/conformance/fixture.{
  type SpecValue, F32Bits, F32Nan, F64Bits, F64Nan, I32Val, I64Val,
}
import twocore/conformance/oracle
import twocore/conformance/runner.{type Instance}
import twocore/ir
import twocore/middle/ir_lower
import twocore/pipeline
import twocore/runtime/profiles

const corpus_dir = "test/twocore/conformance/corpus"

// ─────────────────────────────── the corpus, THROUGH ir_lower(Safe) ───────────────────────────────

/// `add` — direct numeric op + i32 two's-complement WRAP — green through the Safe pass.
pub fn add_through_safe_test() {
  assert check_program("add") == []
}

/// `intops` — signed/unsigned divide pair, `div_s(INT_MIN,-1)` & `div_u(_,0)` TRAPS, and
/// shift-count masking — all hold through codegen with the Safe pass in the chain.
pub fn intops_through_safe_test() {
  assert check_program("intops") == []
}

/// `sum_to` — the loop/break/continue program stays a CONSTANT-SPACE BEAM loop with the
/// metering `Charge` inserted by `ir_lower` (the corpus drives `sum_to(100)`; the large-n
/// constant-space proof lives in `ir_lower_test`).
pub fn sum_to_through_safe_test() {
  assert check_program("sum_to") == []
}

/// `fib` — if + direct self-call + recursion — green through the Safe pass.
pub fn fib_through_safe_test() {
  assert check_program("fib") == []
}

/// `fac` — if + direct self-call + recursion — green through the Safe pass.
pub fn fac_through_safe_test() {
  assert check_program("fac") == []
}

/// `floatops` — f32/f64 value path (raw IEEE-754 bits, D5) — green through the Safe pass.
pub fn floatops_through_safe_test() {
  assert check_program("floatops") == []
}

/// `hostimport` — a host import the Phase-1 frontend cannot faithfully model is REJECTED
/// end-to-end (the `.expected` is `reject`); the Safe pass does not change that outcome.
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

// ─────────────────────────────── driving machinery (reuses 07's corpus/oracle/ffi) ───────────────────────────────

/// Compile + run a `corpus/<name>` program through the FULL Safe pipeline (with `ir_lower`)
/// and return the list of failure descriptions (empty ⇒ every `.expected` line held). A
/// `reject` program asserts the module fails to instantiate; otherwise it instantiates once
/// and every expectation is invoked and compared via 07's oracle.
fn check_program(name: String) -> List(String) {
  let assert Ok(bytes) = read_bytes(name <> ".wasm")
  let assert Ok(text) = read_text(name <> ".expected")
  let assert Ok(expects) = corpus.parse(text)

  case expects {
    [Rejects] ->
      case instantiate_safe(bytes) {
        Error(_) -> []
        Ok(_) -> [name <> ": expected REJECT, but the module instantiated"]
      }
    _ ->
      case instantiate_safe(bytes) {
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

/// Decode → validate → lower → **ir_lower(Safe)** → emit_core → build → load `bytes`, then
/// **instantiate** it in its own owned process (E5, one-instance-one-process): `start_instance`
/// runs the generated `instantiate/0` in that process, seeding its cell. Each module gets a
/// unique name so loads do not clobber. Returns `Error(reason)` — never a panic — for any
/// stage that rejects, or `Error("instantiate: …")` for an instantiation-time trap.
fn instantiate_safe(bytes: BitArray) -> Result(Instance, String) {
  use m0 <- result.try(
    pipeline.source_to_ir(bytes)
    |> result.map_error(pipeline.describe),
  )
  let m = ir.Module(..m0, name: uniquify(m0.name))
  // `ir_to_core` runs the Safe policy pass (ir_lower) BEFORE emit_core — the proof point.
  use core <- result.try(
    pipeline.ir_to_core(m, profiles.safe())
    |> result.map_error(pipeline.describe),
  )
  use mod_atom <- result.try(
    build_beam.compile_and_load(bit_array.from_string(core))
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

/// Check one `.expected` line against the running instance via 07's oracle / trap matcher.
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
/// (mirrors 07's `driver.invoke`, here driving the Safe-pass instance). Single-result only
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
/// to 0). Mirrors 07's `driver.spec_to_raw`.
fn spec_to_raw(v: SpecValue) -> Int {
  case v {
    I32Val(b) | I64Val(b) | F32Bits(b) | F64Bits(b) -> b
    F32Nan(_) | F64Nan(_) -> 0
    // Reference values carry no raw bits (the acceptance corpus is numeric); 0 stays total.
    fixture.NullRef(_) | fixture.ExternRefVal(_) | fixture.FuncRefVal(_) -> 0
    // A v128 is compared lane-wise, never as a scalar; the acceptance corpus is numeric.
    fixture.V128Val(_, _) -> 0
  }
}

/// Tag a raw result integer as a `SpecValue` at the export's declared width (mirrors 07's
/// `driver.tag`). `TTerm` (never produced by the WASM numeric path) falls back to an i32 tag
/// so the function is total.
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

fn numeric_module(name: String, fns: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "twocore@acceptance@"
      <> name
      <> "_"
      <> int.to_string(ffi.unique_int()),
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
  use core <- result.try(
    pipeline.ir_to_core(m, profiles.safe())
    |> result.map_error(pipeline.describe),
  )
  build_beam.compile_and_load(bit_array.from_string(core))
  |> result.map_error(fn(e) { "build: " <> string.inspect(e) })
}

// ─────────────────────────────── value marshalling (mirrors 07's driver) ───────────────────────────────

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

fn uniquify(name: String) -> String {
  name <> "_" <> int.to_string(ffi.unique_int())
}

fn read_bytes(file: String) -> Result(BitArray, String) {
  ffi.read_file(corpus_dir <> "/" <> file)
}

fn read_text(file: String) -> Result(String, String) {
  use bytes <- result.try(ffi.read_file(corpus_dir <> "/" <> file))
  bit_array.to_string(bytes) |> result.replace_error("non-UTF8 .expected")
}
