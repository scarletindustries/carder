//// The real pipeline `Driver` — composes the public stages of 2core into the seam the
//// runner drives, plus a `stub` driver for testing the harness with no compiler.
////
//// `pipeline()` wires the EXISTING, committed stages (units 04–10): decode → validate
//// → lower → link (imports) → `emit_module(_, safe_default())` → `compile_and_load` →
//// dispatch `instantiate/0` vs `instantiate/1(Imports)` → invoke. Nothing here
//// re-implements compiler logic; it only sequences the public APIs and adapts their
//// per-stage error types (D4) into the runner's `String` channel.
////
//// Phase-5 (unit 11) additions, all ADDITIVE — the numeric path stays byte-identical:
////  - **Imports + spectest + linking (H4/R4).** After lowering, `link.link_imports(irmod,
////    providers)` resolves every non-function import against the build-fixed `spectest` module
////    (always consulted) plus any `(register)`ed providers; an import-free module keeps
////    `instantiate/0`, an import-bearing one gets `instantiate/1(Imports)`. A link failure
////    surfaces as `Error("link: <phrase>")` so `assert_unlinkable` can prove fail-closed (H6).
////  - **The reference / multi-value invoke ABI (R17/R18).** A call touching a reference value
////    or a multi-result function marshals TERMS (not `Int`s) through `ffi.call_instance_terms`
////    and unpacks the result package into a value list; reference results are judged via
////    `rt_ref.classify_ref`. A single-numeric-result call keeps the integer path (byte-identical).
////  - **The AST path (H5).** `instantiate_ast` / `check_frontend_ast` enter at `validate` with a
////    WAT-parser-produced `ast.Module`, so the un-`wast2json`-able suite files run from our own
////    parser through the SAME validate/lower/emit chain the binary path uses.
////  - **Exported-state `get` (D.1).** An exported global's generated accessor is a 0-arg export,
////    so `get_global` reuses the invoke path (tagged at the global's declared value type).
////
//// Invoke convention (D5/D10): a generated export returns its result as an Erlang integer (the
//// raw value / IEEE-754 bit pattern) for the numeric case, or a reference term / result tuple for
//// the reference / multi-value case; `invoke` tags each back to a typed `SpecValue` for the oracle.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode as dyn_decode
import gleam/erlang/atom
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import twocore/backend/build_beam
import twocore/backend/emit_core
import twocore/conformance/ffi
import twocore/conformance/fixture.{
  type SpecValue, ArrayRefK, ExternRefTag, ExternRefVal, F32Bits, F32Nan,
  F64Bits, F64Nan, FuncRefTag, FuncRefVal, GcHeapK, GcRef, I31RefK, I32Val,
  I64Val, LaneI8, NullRef, StructRefK, V128Val,
}
import twocore/conformance/runner.{
  type Driver, type ImportEnv, type Instance, type InvokeResult, ImportEnv,
}
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/lower
import twocore/frontend/wasm/validate
import twocore/ir
import twocore/pipeline
import twocore/runtime/instance.{type Binding}
import twocore/runtime/link
import twocore/runtime/profiles
import twocore/runtime/rt_ref

/// Coerce any Gleam value to `Dynamic` (identity at runtime). Used to hand the positional
/// `List(Provided)` import list to the generated `instantiate/1` as one opaque argument.
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

/// The real pipeline driver in the default fail-closed **Safe** posture — exactly
/// `pipeline_with(profiles.safe())`. The historical entry point the Phase-1/2 corpus and
/// conformance suites drive.
pub fn pipeline() -> Driver {
  pipeline_with(profiles.safe())
}

/// Build a `runner.Driver` that compiles + instantiates every module under `binding` (E5,
/// one-instance-one-process), so the capstone can drive the SAME corpus/spec-suite under any
/// policy posture from ONE code path: the three optimizer levels (spread `opt_level` over
/// `profiles.safe()`) and the two named modes (`profiles.safe()` / `profiles.unsafe()`).
///
/// It reuses `pipeline.ir_to_core(_, binding)` — which composes `ir_lower →
/// ir_opt.optimize(_, binding.opt_level) → emit_core` — so the driver never re-implements
/// compiler logic; the frontend (decode/validate/lower), the link contract (`link.link_imports`),
/// the instantiate seam (`ffi.start_instance`/`start_instance_with`), and `invoke` are all
/// unchanged. ONLY the linked `Binding` differs, which is the whole point of a differential.
pub fn pipeline_with(binding: Binding) -> Driver {
  runner.Driver(
    check_frontend: check_frontend,
    instantiate: fn(bytes) { instantiate_under(binding, bytes, empty_env()) },
    invoke: invoke,
    instantiate_env: fn(bytes, env) { instantiate_under(binding, bytes, env) },
    instantiate_ast: fn(m, env) { instantiate_ast_under(binding, m, env) },
    check_frontend_ast: check_frontend_ast,
    get_global: get_global,
  )
}

/// A do-nothing driver: every entry point reports failure. Lets the harness, fixtures,
/// parser, oracle and routing be tested with NO compiler in play (the temporal seam).
/// `check_frontend` returns `Error` (so a stub-driven `assert_invalid` still "passes" by
/// rejection) while `instantiate` fails, proving the partition.
pub fn stub() -> Driver {
  runner.Driver(
    check_frontend: fn(_bytes) { Error("stub: not implemented") },
    instantiate: fn(_bytes) { Error("stub: not implemented") },
    invoke: fn(_inst, _field, _args) {
      runner.DriverError("stub: not implemented")
    },
    instantiate_env: fn(_bytes, _env) { Error("stub: not implemented") },
    instantiate_ast: fn(_m, _env) { Error("stub: not implemented") },
    check_frontend_ast: fn(_m) { Error("stub: not implemented") },
    get_global: fn(_inst, _field) {
      runner.DriverError("stub: not implemented")
    },
  )
}

/// The empty import environment — `spectest` only (it is built into `link.link_imports`, so no
/// provider is needed). Every module links against it unless a `(register)`ed provider is added.
pub fn empty_env() -> ImportEnv {
  ImportEnv(providers: [])
}

// ─────────────────────────────── check_frontend ───────────────────────────────

/// Decode + validate ONLY (the `assert_invalid`/`assert_malformed` partition). Returns
/// `Ok(Nil)` iff the bytes decode AND validate; otherwise `Error(reason)` carrying the
/// rejecting stage's typed error (fail-closed, D4). Never instantiates / runs anything.
pub fn check_frontend(bytes: BitArray) -> Result(Nil, String) {
  use m <- result.try(
    decode.decode(bytes)
    |> result.map_error(fn(e) { "decode: " <> string.inspect(e) }),
  )
  use _tm <- result.try(
    validate.validate(m)
    |> result.map_error(fn(e) { "validate: " <> string.inspect(e) }),
  )
  Ok(Nil)
}

/// Validate ONLY a WAT-parser-produced `ast.Module` (the text `assert_invalid` partition, H5).
/// Decode is skipped — the parser already produced the AST; validation is the sole gate. `Ok(Nil)`
/// iff it validates, else `Error("validate: …")` (fail-closed).
pub fn check_frontend_ast(m: ast.Module) -> Result(Nil, String) {
  validate.validate(m)
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { "validate: " <> string.inspect(e) })
}

// ─────────────────────────────── instantiate ───────────────────────────────

/// Compile `.wasm` bytes to a loaded BEAM module (D10) under the Safe posture, then
/// instantiate it in its own owned process — `instantiate_under(profiles.safe(), _, empty)`.
pub fn instantiate(bytes: BitArray) -> Result(Instance, String) {
  instantiate_under(profiles.safe(), bytes, empty_env())
}

/// Compile `.wasm` bytes to a loaded BEAM module under `binding` (D10), LINK its imports against
/// `env` (+ the build-fixed `spectest`), then **instantiate** it in its own OWNED PROCESS (E5:
/// one-instance-one-process). Each module gets a UNIQUE name so loading many modules from one
/// fixture cannot clobber one another.
///
/// The compile chain is the REAL pipeline under `binding`: decode → validate → frontend-lower →
/// `pipeline.ir_to_core(_, binding)` → build; then `link.link_imports` resolves the imports and
/// the instance is started through the matching ABI (`instantiate/0` import-free, `instantiate/1`
/// import-bearing).
///
/// Returns `Error(reason)` — never a panic — for any stage that rejects: a compile-stage rejection
/// (`decode:`/`validate:`/`lower:`/`emit:`/`build:`), a LINK failure (`link: <phrase>` — the
/// `assert_unlinkable` case, H6), or an INSTANTIATION-TIME TRAP (`instantiate: <phrase>` — OOB
/// active segment / trapping `start`). The runner uses the prefix to tell them apart.
pub fn instantiate_under(
  binding: Binding,
  bytes: BitArray,
  env: ImportEnv,
) -> Result(Instance, String) {
  use m <- result.try(
    decode.decode(bytes)
    |> result.map_error(fn(e) { "decode: " <> string.inspect(e) }),
  )
  instantiate_typed(binding, m, env)
}

/// Compile + link + instantiate a WAT-parser-produced `ast.Module` (H5) — the un-`wast2json`-able
/// path. Enters at `validate` (decode is skipped: the parser produced the AST), then shares the
/// EXACT validate → lower → ir_to_core → build → link → start chain with the binary path.
pub fn instantiate_ast_under(
  binding: Binding,
  m: ast.Module,
  env: ImportEnv,
) -> Result(Instance, String) {
  instantiate_typed(binding, m, env)
}

/// The shared tail of both instantiate paths (binary + AST): validate → lower → compile → link →
/// start. `m` is the decoded/parsed AST; `env` supplies the `(register)`ed providers.
fn instantiate_typed(
  binding: Binding,
  m: ast.Module,
  env: ImportEnv,
) -> Result(Instance, String) {
  use tm <- result.try(
    validate.validate(m)
    |> result.map_error(fn(e) { "validate: " <> string.inspect(e) }),
  )
  use irmod0 <- result.try(
    lower.lower(tm)
    |> result.map_error(fn(e) { "lower: " <> string.inspect(e) }),
  )
  let irmod = ir.Module(..irmod0, name: uniquify(irmod0.name))
  // Fail-closed link (H6, spec §4.5.4): resolve every non-function import against `spectest` +
  // the `(register)`ed providers BEFORE compiling; a link failure is the `assert_unlinkable` case.
  use state_provided <- result.try(
    link.link_imports(irmod, env.providers)
    |> result.map_error(fn(e) { "link: " <> link.import_error_phrase(e) }),
  )
  // The function-import dispatch vector (S5/P6-09). emit_core weaves the function-import closures
  // into the positional `Imports` list — AFTER the state imports — exactly when the module CALLS an
  // imported function (`needs_func_imports`); the driver must match that arity byte-for-byte.
  //
  // We weave the closures (→ `instantiate/1`) only when the module calls an import AND EVERY
  // function import resolves to a REAL provider — the whitelisted `spectest` host module or a
  // `(register)`ed instance. A GENERIC host capability (e.g. `env`/`wasi`) under the deny-all Safe
  // host is UNSATISFIED: the module is rejected fail-closed at link, exactly as the Phase-1..5
  // acceptance corpus (`hostimport`) expects — so the corpus + the Safe≡Unsafe differential stay
  // byte-identical (conformance-neutral, I7). Cross-module `linking.wast`/`table_copy.wast` imports
  // resolve to registered providers, so THEY light up.
  use provided <- result.try(case module_calls_import(irmod) {
    False -> Ok(state_provided)
    True ->
      case func_imports_all_provided(irmod, env.providers) {
        False ->
          Error(
            "link: unknown import (host capability not provided under the deny-all host)",
          )
        True ->
          link.link_func_imports(irmod, env.providers)
          |> result.map(fn(fp) { list.append(state_provided, fp) })
          |> result.map_error(fn(e) { "link: " <> link.import_error_phrase(e) })
      }
  })
  use core_text <- result.try(
    pipeline.ir_to_core(irmod, binding)
    |> result.map_error(pipeline.describe),
  )
  use mod_atom <- result.try(
    build_beam.compile_and_load(bit_array.from_string(core_text))
    |> result.map_error(fn(e) { "build: " <> string.inspect(e) }),
  )
  // Dispatch the instantiate ABI by import-presence (R4): an import-free module keeps the
  // byte-identical `instantiate/0`; a module with ≥1 STATE import gets `instantiate/1(Imports)`,
  // where `Imports` is the positional `Provided` list `link_imports` returned.
  let started = case provided {
    [] -> ffi.start_instance(mod_atom)
    _ -> ffi.start_instance_with(mod_atom, to_dynamic(provided))
  }
  case started {
    Ok(proc) ->
      Ok(runner.Instance(
        proc: proc,
        exports: export_types(irmod),
        func_sigs: export_func_sigs(irmod),
      ))
    Error(trap) -> Error("instantiate: " <> trap)
  }
}

/// Build `export name → FuncType` for the module's exported FUNCTIONS (P6-10 / S5). Used to publish
/// a `(register)`ed instance's functions as cross-module capabilities: the `FuncType` (params +
/// results) drives fail-closed function-import matching. Non-function exports (globals/tables/
/// memories) contribute no entry. An `ExportFn` whose target is an IMPORTED function is skipped (its
/// signature lives in the import, and re-exporting an import across modules is out of this unit's
/// scope — a categorized edge).
fn export_func_sigs(m: ir.Module) -> Dict(String, ir.FuncType) {
  let by_fn =
    list.fold(m.functions, dict.new(), fn(acc, f) {
      dict.insert(acc, f.name, ir.signature(f))
    })
  list.fold(m.exports, dict.new(), fn(acc, e) {
    case e {
      ir.ExportFn(export_name, fn_name) ->
        case dict.get(by_fn, fn_name) {
          Ok(sig) -> dict.insert(acc, export_name, sig)
          Error(_) -> acc
        }
      _ -> acc
    }
  })
}

/// Append a process-unique suffix to a module name so concurrent fixtures' modules do
/// not share a single BEAM module name (which `code:load_binary` would overwrite).
fn uniquify(name: String) -> String {
  name <> "_" <> int.to_string(ffi.unique_int())
}

/// True iff EVERY function import of `module` resolves to a REAL provider — the whitelisted
/// `spectest` host module or a `(register)`ed instance in `providers`. A function import to a
/// generic host capability (`env`, `wasi`, …) is NOT a real provider under the deny-all Safe host,
/// so a module calling one is rejected fail-closed (see `instantiate_typed`), preserving the
/// Phase-1..5 corpus's `hostimport` rejection. A module with no function imports is vacuously True.
fn func_imports_all_provided(
  module: ir.Module,
  providers: List(link.Provider),
) -> Bool {
  list.all(module.imports, fn(imp) {
    case imp {
      ir.ImportFn(capability, _name, _ty) ->
        capability == "spectest" || is_registered(capability, providers)
      _ -> True
    }
  })
}

/// True iff some `Registered` provider carries the link-name `capability`.
fn is_registered(capability: String, providers: List(link.Provider)) -> Bool {
  list.any(providers, fn(p) {
    let link.Registered(link_name, _exports) = p
    link_name == capability
  })
}

/// True iff `module` is IMPORT-BEARING for the func-import dispatch vector — the driver's decision
/// to append the positional `link.Provided` function-import closures to the `Imports` list handed to
/// `instantiate/1`. It DELEGATES to `emit_core.needs_func_imports`, the SINGLE SOURCE OF TRUTH (R3,
/// Phase-14): emit uses that exact predicate over the identical lowered `irmod` to decide whether the
/// generated `instantiate/1` destructures the func-import closures, so the driver's supplied
/// `Imports` length and emit's arity are the SAME function of the SAME module and CANNOT desync (the
/// arity bug Phase 13's capstone had to hand-fix). This covers both a body-level `CallImport` /
/// `ReturnCallImport` AND a `ref.func` of an imported function in an element segment or body (a
/// module that merely imports a function without using it stays byte-neutral → `instantiate/0`, I7).
/// Public so the arity-lockstep test can assert the driver and emit agree by construction (R3).
pub fn module_calls_import(module: ir.Module) -> Bool {
  emit_core.needs_func_imports(module)
}

/// Build the `export name → result value-types` table from the lowered IR module. Function
/// exports map to their result value-types; EXPORTED GLOBALS map to a single-element list of the
/// global's declared type (the generated exported-global accessor is a 0-arg "function" returning
/// that one value — so `get_global` reuses the invoke path). Exported tables/memories are opaque
/// handles, never read as values here, so they are omitted.
fn export_types(m: ir.Module) -> Dict(String, List(ir.ValType)) {
  let by_fn =
    list.fold(m.functions, dict.new(), fn(acc, f) {
      dict.insert(acc, f.name, f.result)
    })
  let by_global =
    list.fold(m.globals, dict.new(), fn(acc, g) {
      dict.insert(acc, g.name, g.ty)
    })
  // Imported globals are also readable/exportable — map their declared type too.
  let by_global =
    list.fold(m.imports, by_global, fn(acc, imp) {
      case imp {
        ir.ImportGlobal(_, name, ty, _) -> dict.insert(acc, name, ty)
        _ -> acc
      }
    })
  list.fold(m.exports, dict.new(), fn(acc, e) {
    case e {
      ir.ExportFn(export_name, fn_name) ->
        case dict.get(by_fn, fn_name) {
          Ok(results) -> dict.insert(acc, export_name, results)
          Error(_) -> acc
        }
      ir.ExportGlobal(export_name, global_name) ->
        case dict.get(by_global, global_name) {
          Ok(ty) -> dict.insert(acc, export_name, [ty])
          Error(_) -> acc
        }
      ir.ExportTable(..) | ir.ExportMemory(..) | ir.ExportTag(..) -> acc
    }
  })
}

// ─────────────────────────────── invoke ───────────────────────────────

/// Read exported global `field` on `inst` (the `(get $m "field")` action, D.1). The generated
/// exported-global accessor is a 0-arg export, so this is exactly a 0-argument invoke tagged at
/// the global's declared value type (including a reference-typed global → §C). `Returned([v])` on
/// success, `DriverError`/`Trapped` on failure.
pub fn get_global(inst: Instance, field: String) -> InvokeResult {
  invoke(inst, field, [])
}

/// Invoke export `field` on `inst` with `args`. Chooses the ABI by value shape:
///  - a call whose args are ALL numeric AND whose single result is numeric uses the integer path
///    (unchanged — the numeric corpus stays byte-identical, conformance-neutral);
///  - a call touching a reference value OR a multi-value result marshals TERMS through
///    `ffi.call_instance_terms` and unpacks the result package into a value list (R17/R18).
/// A trap / capability denial surfaces as `Trapped(reason)`.
pub fn invoke(
  inst: Instance,
  field: String,
  args: List(SpecValue),
) -> InvokeResult {
  case dict.get(inst.exports, field) {
    Error(_) -> runner.DriverError("no such export: " <> field)
    Ok(results) ->
      case use_term_abi(args, results) {
        False -> invoke_numeric(inst, field, args, results)
        True -> invoke_terms(inst, field, args, results)
      }
  }
}

/// The integer fast-path (byte-identical to Phase-1..4): args → raw ints, a single numeric result
/// tagged at its declared width. 0-result and 1-result only reach here.
fn invoke_numeric(
  inst: Instance,
  field: String,
  args: List(SpecValue),
  results: List(ir.ValType),
) -> InvokeResult {
  let arg_ints = list.map(args, spec_to_raw)
  case results {
    [] ->
      case ffi.call_instance(inst.proc, atom.create(field), arg_ints) {
        Ok(_) -> runner.Returned([])
        Error(t) -> runner.Trapped(t)
      }
    [ty] ->
      case ffi.call_instance(inst.proc, atom.create(field), arg_ints) {
        Ok(raw) -> runner.Returned([tag(ty, raw)])
        Error(t) -> runner.Trapped(t)
      }
    _ -> runner.DriverError("multi-value result unsupported (numeric path)")
  }
}

/// The reference / multi-value TERM path (R17/R18): each arg maps to a BEAM term, the result
/// package is unpacked into `list.length(results)` values, and each is tagged at its declared
/// value type — numeric by raw bits, reference by `rt_ref.classify_ref`.
fn invoke_terms(
  inst: Instance,
  field: String,
  args: List(SpecValue),
  results: List(ir.ValType),
) -> InvokeResult {
  let arg_terms = list.map(args, spec_to_term)
  case ffi.call_instance_terms(inst.proc, atom.create(field), arg_terms) {
    Error(t) -> runner.Trapped(t)
    Ok(package) -> {
      let values = ffi.result_list(list.length(results), package)
      // `result_list` guarantees `values` has exactly `list.length(results)` elements.
      let tagged =
        list.map2(results, values, fn(ty, term) { tag_term(ty, term) })
      runner.Returned(tagged)
    }
  }
}

/// Whether the reference / v128 / multi-value TERM ABI is required (else the integer fast-path).
/// True iff any argument is a reference or a `v128`, any result is a reference type or `v128`, or
/// there is more than one result. A `v128` is a BEAM binary (`<<_:128>>`, S14) — a term, not an
/// integer — so it rides the SAME term ABI as references. A pure numeric call stays byte-identical.
fn use_term_abi(args: List(SpecValue), results: List(ir.ValType)) -> Bool {
  let term_arg = list.any(args, is_term_value)
  let term_result =
    list.any(results, fn(ty) {
      case ty {
        // `ir.TTerm` is a GC heap reference result (Phase-8 GC — every GC ref lowers to `TTerm`).
        // Route it through the term ABI so the returned `{gc, Id}`/`{i31, _}` term is classified,
        // not coerced to a garbage int on the numeric path. GC refs do not appear in the main
        // (non-GC) allowlist suite, so this is inert for the headline (verified by re-run).
        ir.TFuncRef | ir.TExternRef | ir.TV128 | ir.TTerm -> True
        _ -> False
      }
    })
  let multi = case results {
    [] | [_] -> False
    _ -> True
  }
  term_arg || term_result || multi
}

/// True iff `v` must ride the term ABI as an argument — a reference (null/externref/funcref) or a
/// `v128` (16-byte binary), none of which is an Erlang integer.
fn is_term_value(v: SpecValue) -> Bool {
  case v {
    NullRef(_) | ExternRefVal(_) | FuncRefVal(_) | V128Val(_, _) -> True
    _ -> False
  }
}

/// The raw integer bits a numeric argument carries (NaN args, which the spec never uses, map to
/// 0). Reference args never reach here (they take the term path).
fn spec_to_raw(v: SpecValue) -> Int {
  case v {
    I32Val(b) | I64Val(b) | F32Bits(b) | F64Bits(b) -> b
    F32Nan(_) | F64Nan(_) -> 0
    NullRef(_) | ExternRefVal(_) | FuncRefVal(_) -> 0
    // A GC ref never appears as a numeric argument (the suite passes GC refs only as host
    // anyref/externref, and never on the integer path); defensive 0.
    GcRef(_) -> 0
    // A v128 argument never reaches the integer path (it forces the term ABI, S14).
    V128Val(_, _) -> 0
  }
}

/// Map a `SpecValue` argument to the BEAM term the generated code expects (R18): a numeric value
/// is its raw integer (identity as a `Dynamic`); a reference is built through `rt_ref` — a null
/// sentinel, or the host-constructible `ref.extern N` externref. A `FuncRefVal` argument never
/// occurs (wast2json never passes a non-null funcref as an argument), but is mapped to null
/// defensively.
fn spec_to_term(v: SpecValue) -> Dynamic {
  case v {
    I32Val(b) | I64Val(b) | F32Bits(b) | F64Bits(b) -> to_dynamic(b)
    F32Nan(_) | F64Nan(_) -> to_dynamic(0)
    NullRef(_) -> rt_ref.null_ref()
    ExternRefVal(id) -> rt_ref.extern_of(id)
    FuncRefVal(_) -> rt_ref.null_ref()
    // A GC ref never occurs as a script argument (wast2json/wasm-tools never pass a struct/array/i31
    // ref as an invoke arg); map to null defensively so the arg path stays total.
    GcRef(_) -> rt_ref.null_ref()
    // A v128 argument IS its 16 raw little-endian bytes (S14): pack the lanes into the 128-bit
    // image, emit the 16-byte binary the generated code consumes as a `<<_:128>>` operand.
    V128Val(lane, lanes) ->
      ffi.mk_v128(fixture.v128_bytes_le(fixture.v128_pack(lanes, lane)))
  }
}

/// Tag a raw result integer as a `SpecValue` at the export's declared width (integer path). A
/// reference-typed result never reaches here (it takes the term path); it falls back to i32 to
/// stay total.
fn tag(ty: ir.ValType, raw: Int) -> SpecValue {
  case ty {
    ir.TI32 -> I32Val(raw)
    ir.TI64 -> I64Val(raw)
    ir.TF32 -> F32Bits(raw)
    ir.TF64 -> F64Bits(raw)
    ir.TTerm -> I32Val(raw)
    ir.TFuncRef | ir.TExternRef -> I32Val(raw)
    // A `v128` result forces the term ABI (`use_term_abi`), so the integer path never tags one.
    // Defensive fallback keeps this total.
    ir.TV128 -> I32Val(raw)
    // An `exnref` (Phase-7) is a reference; the integer path never tags one. Defensive fallback.
    ir.TExnRef -> I32Val(raw)
  }
}

/// Tag a returned BEAM TERM at its declared value type (R18). Numeric types read the raw integer
/// bits out of the term; `TFuncRef`/`TExternRef` classify the reference via `rt_ref.classify_ref`
/// — a null becomes a typed `NullRef`, an externref an `ExternRefVal` carrying its round-tripped
/// host identity, a funcref a `FuncRefVal` (identity not compared).
fn tag_term(ty: ir.ValType, term: Dynamic) -> SpecValue {
  case ty {
    ir.TI32 -> I32Val(term_to_int(term))
    ir.TI64 -> I64Val(term_to_int(term))
    ir.TF32 -> F32Bits(term_to_int(term))
    ir.TF64 -> F64Bits(term_to_int(term))
    // A GC heap reference result (Phase-8 GC): classify the returned term into a GC-kind
    // `SpecValue` for the oracle's lattice comparison, instead of the old i32 coercion.
    ir.TTerm -> tag_gc(term)
    ir.TFuncRef -> tag_ref(term, FuncRefTag)
    ir.TExternRef -> tag_ref(term, ExternRefTag)
    // A `v128` result is the 16 raw little-endian bytes the generated code returned (S14). Read the
    // binary back, decode to its 128-bit image, and tag it at the finest lane (`LaneI8`); the oracle
    // re-decodes at the EXPECTED's lane type for the lane-wise comparison (M3). The load-bearing
    // fact is that the 16 bytes round-trip byte-exact — a differing lane fails the assert.
    ir.TV128 ->
      V128Val(
        LaneI8,
        fixture.v128_unpack(
          fixture.v128_from_bytes(term_to_bytes(term)),
          LaneI8,
        ),
      )
    // An `exnref` (Phase-7, T9) is a caught-exception handle; the conformance corpus never returns
    // one as a scalar. Classify it via a defensive reference tag (its identity is not compared).
    ir.TExnRef -> tag_ref(term, ExternRefTag)
  }
}

/// Read a returned `v128` term as its 16-byte binary. A non-binary term (never expected for a
/// `v128` result) yields empty bytes, which decode to an all-zero image.
fn term_to_bytes(term: Dynamic) -> BitArray {
  case dyn_decode.run(term, dyn_decode.bit_array) {
    Ok(b) -> b
    Error(_) -> <<>>
  }
}

/// Classify a returned reference term into the harness's value model, tagged at the declared
/// reftype `t` (used only to tag a null — a null's reftype is not observable at the value layer).
fn tag_ref(term: Dynamic, t: fixture.RefTypeTag) -> SpecValue {
  case rt_ref.classify_ref(term) {
    rt_ref.NullRef -> NullRef(t)
    rt_ref.ExternRef -> ExternRefVal(term_to_int(ffi.extern_payload(term)))
    // A Phase-7 caught-exception handle `{ref_exn, _}` (T9). Opaque like a funcref at the value
    // layer; the harness has no distinct exnref `SpecValue` yet (P7-09 refines this if a `.wast`
    // ever RETURNS an exnref — Porffor never does, so this arm is unreached in the current corpus,
    // keeping conformance byte-identical). Tag it as an opaque non-null reference for now.
    rt_ref.ExnRef -> FuncRefVal(None)
    rt_ref.FuncRef -> FuncRefVal(None)
  }
}

/// Classify a returned GC heap reference term (Phase-8 GC) into a `SpecValue` for the oracle. Uses
/// the structural harness FFI `ffi.gc_classify` (never dereferences the instance-process arena,
/// R-GC1): a null → `NullRef`, an `i31` → `GcRef(I31RefK)` (precise, self-describing), a `{gc, Id}`
/// heap handle → `GcRef(GcHeapK)` (coarse — struct-vs-array not observable across the process copy;
/// refined to `StructRefK`/`ArrayRefK` if the handle self-describes), a host `extern`/any-ref →
/// `ExternRefVal` by identity, else an opaque non-null funcref/exn. Total.
fn tag_gc(term: Dynamic) -> SpecValue {
  case ffi.gc_classify(term) {
    "null" -> NullRef(FuncRefTag)
    "i31" -> GcRef(I31RefK)
    "gc_struct" -> GcRef(StructRefK)
    "gc_array" -> GcRef(ArrayRefK)
    "gc_heap" -> GcRef(GcHeapK)
    "extern" -> ExternRefVal(term_to_int(ffi.extern_payload(term)))
    _ -> FuncRefVal(None)
  }
}

/// Read the raw integer a numeric result term carries (D5 — floats are raw bits, i.e. integers).
/// A non-integer term (never expected on the numeric path) yields 0.
fn term_to_int(term: Dynamic) -> Int {
  case dyn_decode.run(term, dyn_decode.int) {
    Ok(n) -> n
    Error(_) -> 0
  }
}
