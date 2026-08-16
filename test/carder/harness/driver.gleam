//// The real pipeline `Driver` — composes the public stages of carder into the seam the
//// harness drives, plus a `stub` driver for testing the harness with no compiler.
////
//// ## THE ONE SURPRISING THING: a `Driver`'s `BitArray` is `.ir` TEXT
////
//// This driver was forked from the WebAssembly conformance harness, where a `Driver`'s bytes
//// were a `.wasm` BINARY and the chain opened `decode → validate → lower`. carder no longer has
//// a WebAssembly frontend (it moved to the `scribbler` repo); carder is the BACKEND. The seam's
//// SHAPE is unchanged and only the meaning of its bytes moved one layer down:
////
////   **a `BitArray` handed to a `Driver` is UTF-8 `.ir` SOURCE TEXT, not a wasm binary.**
////
//// The whole amputation is the first stage: `decode → validate → lower` (three wasm-frontend
//// stages producing an `ir.Module`) becomes `bit_array.to_string → pipeline.parse_ir` (one
//// parse producing the SAME `ir.Module`). EVERYTHING BELOW THE PARSE IS UNCHANGED — the link
//// contract, `pipeline.ir_to_cmod(_, binding)`, `build_beam.compile_and_load`, the
//// `instantiate/0`-vs-`instantiate/1` dispatch and the whole invoke ABI are byte-for-byte the
//// code they always were. Each `.ir` corpus fixture was generated from the corresponding
//// `.wasm` by the pre-split `to-ir`, and `wasm → .beam` was measured byte-identical to
//// `wasm → .ir text → .beam`, so a test rebased onto `.ir` drives the exact same artifact.
////
//// `pipeline()` wires the committed stages: parse → link (imports) → `ir_to_cmod(_, binding)`
//// → `compile_and_load` → dispatch `instantiate/0` vs `instantiate/1(Imports)` → invoke.
//// Nothing here re-implements compiler logic; it only sequences the public APIs and adapts
//// their per-stage error types (D4) into the harness's `String` channel:
////  - **Imports + linking (H4/R4).** `link.link_imports(irmod, providers)` resolves every
////    non-function import against the caller's providers; an import-free module keeps
////    `instantiate/0`, an import-bearing one gets `instantiate/1(Imports)`. A link failure
////    surfaces as `Error("link: <phrase>")` so `assert_unlinkable` can prove fail-closed (H6).
////  - **The reference / multi-value invoke ABI (R17/R18).** A call touching a reference value
////    or a multi-result function marshals TERMS (not `Int`s) through `ffi.call_instance_terms`
////    and unpacks the result package into a value list; reference results are judged via
////    `rt_ref.classify_ref`. A single-numeric-result call keeps the integer path (byte-identical).
////  - **Exported-state `get` (D.1).** An exported global's generated accessor is a 0-arg export,
////    so `get_global` reuses the invoke path (tagged at the global's declared value type).
////
//// The WAT/AST entries (`instantiate_ast`/`check_frontend_ast`) left with the frontend —
//// `ast.Module` no longer exists in carder.
////
//// Invoke convention (D5/D10): a generated export returns its result as an Erlang integer (the
//// raw value / IEEE-754 bit pattern) for the numeric case, or a reference term / result tuple for
//// the reference / multi-value case; `invoke` tags each back to a typed `SpecValue` for the oracle.

import carder/backend/build_beam
import carder/backend/emit_core
import carder/harness/ffi
import carder/harness/fixture.{
  type SpecValue, ArrayRefK, ExternRefTag, ExternRefVal, F32Bits, F32Nan,
  F64Bits, F64Nan, FuncRefTag, FuncRefVal, GcHeapK, GcRef, I31RefK, I32Val,
  I64Val, LaneI8, NullRef, StructRefK, V128Val,
}
import carder/harness/runner.{
  type Driver, type ImportEnv, type Instance, type InvokeResult, ImportEnv,
}
import carder/ir
import carder/pipeline
import carder/runtime/instance.{type Binding}
import carder/runtime/link
import carder/runtime/profiles
import carder/runtime/rt_ref
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
/// It reuses `pipeline.ir_to_cmod(_, binding)` — which composes `ir_lower →
/// ir_opt.optimize(_, binding.opt_level) → emit_core` — so the driver never re-implements
/// compiler logic; the `.ir` parse (`pipeline.parse_ir`), the link contract
/// (`link.link_imports`), the instantiate seam (`ffi.start_instance`/`start_instance_with`), and
/// `invoke` are all unchanged. ONLY the linked `Binding` differs, which is the whole point of a
/// differential.
pub fn pipeline_with(binding: Binding) -> Driver {
  runner.Driver(
    check_frontend: check_frontend,
    instantiate: fn(bytes) { instantiate_under(binding, bytes, empty_env()) },
    invoke: invoke,
    instantiate_env: fn(bytes, env) { instantiate_under(binding, bytes, env) },
    get_global: get_global,
  )
}

/// A do-nothing driver: every entry point reports failure. Lets the harness, fixtures,
/// parser, oracle and routing be tested with NO compiler in play (the temporal seam).
/// `check_frontend` returns `Error` (so a stub-driven "must be rejected" case still "passes" by
/// rejection) while `instantiate` fails, proving the partition.
pub fn stub() -> Driver {
  runner.Driver(
    check_frontend: fn(_bytes) { Error("stub: not implemented") },
    instantiate: fn(_bytes) { Error("stub: not implemented") },
    invoke: fn(_inst, _field, _args) {
      runner.DriverError("stub: not implemented")
    },
    instantiate_env: fn(_bytes, _env) { Error("stub: not implemented") },
    get_global: fn(_inst, _field) {
      runner.DriverError("stub: not implemented")
    },
  )
}

/// The empty import environment — NO providers at all. carder hard-codes no host module by name,
/// so under this env a module's imports are satisfied only if it has none: a state import fails
/// closed at link, and a called function import is a generic host capability, rejected by
/// `instantiate_under` under the deny-all host. Add a `link.Registered` (see
/// `runner.provider_from_instance`) or a `link.Namespace` provider to satisfy one.
pub fn empty_env() -> ImportEnv {
  ImportEnv(providers: [])
}

// ─────────────────────────────── check_frontend ───────────────────────────────

/// PARSE ONLY — carder's front gate (the "must be rejected" partition). `bytes` is UTF-8 `.ir`
/// SOURCE TEXT (see the module doc), not a wasm binary.
///
/// Returns `Ok(Nil)` iff the bytes are valid UTF-8 AND `pipeline.parse_ir` accepts them;
/// otherwise `Error("parse .ir: <detail>")` (fail-closed, D4) — `<detail>` is the inspected
/// `ir/parser.ParseError`, or a non-UTF-8 note. Never instantiates / runs anything, and never
/// panics.
pub fn check_frontend(bytes: BitArray) -> Result(Nil, String) {
  parse(bytes)
  |> result.map(fn(_m) { Nil })
}

/// Decode `bytes` as UTF-8 `.ir` source text and parse it into an `ir.Module` — the single
/// amputation point where the departed wasm frontend's `decode → validate → lower` used to sit.
///
/// - `bytes`: UTF-8 `.ir` source (the text `carder to-ir` emits / `ir_printer.print_module`
///   round-trips). Any encoding that is not valid UTF-8 is rejected.
/// - Returns `Ok(module)` — the SAME `ir.Module` the wasm frontend used to lower to — or
///   `Error("parse .ir: <detail>")`. Total; the `.ir` parser never panics on malformed input.
///
/// Public so a test that needs to interpose its own tail (e.g. the self-contained-link
/// differential) shares this exact front half instead of re-implementing it.
pub fn parse(bytes: BitArray) -> Result(ir.Module, String) {
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error("parse .ir: input is not valid UTF-8 text"),
  )
  pipeline.parse_ir(text)
  |> result.map_error(fn(e) { "parse .ir: " <> string.inspect(e) })
}

// ─────────────────────────────── instantiate ───────────────────────────────

/// Compile `.ir` source text to a loaded BEAM module (D10) under the Safe posture, then
/// instantiate it in its own owned process — `instantiate_under(profiles.safe(), _, empty_env())`.
pub fn instantiate(bytes: BitArray) -> Result(Instance, String) {
  instantiate_under(profiles.safe(), bytes, empty_env())
}

/// Parse `.ir` source text, compile it to a loaded BEAM module under `binding` (D10), LINK its
/// imports against `env`, then **instantiate** it in its own OWNED PROCESS (E5:
/// one-instance-one-process). Each module gets a UNIQUE name so loading many modules in one test
/// cannot clobber one another.
///
/// The chain is the REAL pipeline under `binding`: `parse` → `link.link_imports` →
/// `pipeline.ir_to_cmod(_, binding)` → `build_beam.compile_and_load` → start through the matching
/// ABI (`instantiate/0` import-free, `instantiate/1` import-bearing).
///
/// - `binding`: the build-time posture (mode × tiers × strategy × opt level).
/// - `bytes`: UTF-8 `.ir` source text (NOT a wasm binary — see the module doc).
/// - `env`: the providers imports resolve against; `empty_env()` for none.
/// - Returns `Error(reason)` — never a panic — for any stage that rejects: a parse rejection
///   (`parse .ir: …`), a compile-stage rejection (`emit:`/`build:`), a LINK failure
///   (`link: <phrase>` — the `assert_unlinkable` case, H6), or an INSTANTIATION-TIME TRAP
///   (`instantiate: <phrase>` — OOB active segment / trapping `start`). Callers use the prefix
///   to tell them apart.
pub fn instantiate_under(
  binding: Binding,
  bytes: BitArray,
  env: ImportEnv,
) -> Result(Instance, String) {
  use m <- result.try(parse(bytes))
  instantiate_module(binding, m, env)
}

/// Compile + link + instantiate an already-parsed `ir.Module` — the tail shared by every
/// instantiate path, below the `.ir` parse.
///
/// - `binding`: the build-time posture. `irmod0`: the parsed module (its name is uniquified here
///   so concurrent instances never share a BEAM module name). `env`: the import providers.
/// - Returns `Ok(Instance)` (a live, owned process) or the same prefixed `Error(reason)` channel
///   `instantiate_under` documents (minus the parse prefix, which cannot arise here).
///
/// Public so a test can enter below the parse (e.g. after building an `ir.Module` in code).
pub fn instantiate_module(
  binding: Binding,
  irmod0: ir.Module,
  env: ImportEnv,
) -> Result(Instance, String) {
  let irmod = ir.Module(..irmod0, name: uniquify(irmod0.name))
  use provided <- result.try(resolve_provided(irmod, env))
  use cmod <- result.try(
    pipeline.ir_to_cmod(irmod, binding)
    |> result.map_error(pipeline.describe),
  )
  use mod_atom <- result.try(
    build_beam.compile_and_load(cmod)
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

/// Resolve `module`'s imports against `env` into the positional `link.Provided` vector the
/// generated `instantiate/1` consumes — the FAIL-CLOSED link step (H6, spec §4.5.4), run BEFORE
/// anything is compiled or started.
///
/// Two seams, in the order emit_core lays them out:
///  1. `link.link_imports` resolves every STATE import (global/table/memory) in declaration order.
///  2. The FUNCTION-import dispatch vector (S5/P6-09) is APPENDED — but only when the module
///     actually calls an import (`module_calls_import`, which delegates to
///     `emit_core.needs_func_imports`, the single source of truth for the emitted arity) AND
///     every function import resolves to a REAL provider. A GENERIC host capability (e.g.
///     `env`/`wasi`) has no provider under the deny-all Safe host, so calling one is rejected
///     fail-closed here — exactly what the acceptance corpus's `hostimport` expects, and what
///     keeps the Safe≡Unsafe differential byte-identical (conformance-neutral, I7). Cross-module
///     imports resolve to `(register)`ed providers, so THEY light up.
///
/// - `module`: the lowered IR module (its name should already be uniquified).
/// - `env`: the providers to resolve against.
/// - Returns `Ok(provided)` — state slots then function slots, positionally matching emit's
///   `Imports` destructure — or `Error("link: <spec phrase>")` for the first unsatisfied /
///   mismatched import (no instance is created). Total.
///
/// Public so a test that swaps only the compile tail (e.g. the self-contained-link differential)
/// shares this exact link contract rather than re-implementing it and drifting.
pub fn resolve_provided(
  module: ir.Module,
  env: ImportEnv,
) -> Result(List(link.Provided), String) {
  use state_provided <- result.try(
    link.link_imports(module, env.providers)
    |> result.map_error(fn(e) { "link: " <> link.import_error_phrase(e) }),
  )
  case module_calls_import(module) {
    False -> Ok(state_provided)
    True ->
      case func_imports_all_provided(module, env.providers) {
        False ->
          Error(
            "link: unknown import (host capability not provided under the deny-all host)",
          )
        True ->
          link.link_func_imports(module, env.providers)
          |> result.map(fn(fp) { list.append(state_provided, fp) })
          |> result.map_error(fn(e) { "link: " <> link.import_error_phrase(e) })
      }
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

/// True iff EVERY function import of `module` resolves to a REAL provider — a `(register)`ed
/// instance or a caller-supplied host `Namespace` in `providers`. carder hard-codes NO host module
/// by name, so a function import whose link name has NO provider is a GENERIC host capability
/// (`env`, `wasi`, …): not a real provider under the deny-all Safe host, so a module calling one is
/// rejected fail-closed (see `resolve_provided`), preserving the acceptance corpus's `hostimport`
/// rejection. A module with no function imports is vacuously True.
fn func_imports_all_provided(
  module: ir.Module,
  providers: List(link.Provider),
) -> Bool {
  list.all(module.imports, fn(imp) {
    case imp {
      ir.ImportFn(capability, _name, _ty) -> has_provider(capability, providers)
      _ -> True
    }
  })
}

/// True iff some provider — `Registered` (a cross-module `(register)`) or `Namespace` (a
/// caller-supplied host module) — carries the link-name `capability`.
fn has_provider(capability: String, providers: List(link.Provider)) -> Bool {
  list.any(providers, fn(p) {
    case p {
      link.Registered(link_name, _exports) -> link_name == capability
      link.Namespace(link_name, _func, _state) -> link_name == capability
    }
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
