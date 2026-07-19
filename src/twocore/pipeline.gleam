//// Top-level driver glue (unit 11c completes unit 01's stub). Per-stage errors (D4)
//// compose **here**, at the driver boundary; there is **no single shared `StageError`**.
////
//// Each pipeline stage owns its own error type (`decode.DecodeError`,
//// `validate.ValidateError`, `lower.LowerError`, `ir_lower.LowerError`,
//// `emit_core.EmitError`, `build_beam.BuildError`). This module maps each into a
//// `PipelineError` variant at exactly ONE seam, and exposes the composable stage-driver
//// functions the CLI (`twocore.gleam`) and the acceptance harness (`11d`) both call — so
//// the error mapping and stage wiring live in one place, not scattered.
////
//// ## The run/invoke ABI (FIXED CONTRACT — `07`'s oracle marshals to it)
////
//// `RunResult`/`invoke` are how a compiled export is called from the BEAM (D10):
//// - **Arguments and results are raw unsigned bit patterns as Erlang integers** — an i32
////   in `[0, 2^32)`, an i64 in `[0, 2^64)` (an i64 is an ordinary BEAM bignum; nothing
////   special past 60 bits). Floats marshal as their raw IEEE-754 bit pattern, also an
////   integer (D5 — never a BEAM double).
//// - A **trap** surfaces as a BEAM exception raised by `rt_trap`; `invoke` catches it (via
////   the `twocore_cli_ffi` catching-apply seam) and returns `Trapped(reason)`. The deny-all
////   host rejection surfaces the same way (a catchable `{capability_denied, …}`), so an
////   acceptance test asserts a *rejection*, not a normal return.
////
//// > **Deviation from the frozen doc, flagged:** the doc's `RunResult.Trapped` carried an
//// > `ir.TrapReason`. Unit 07 actually landed with a String-reason trap channel
//// > (`runner.InvokeResult.Trapped(reason: String)`), and a deny-all capability denial is
//// > NOT an `ir.TrapReason`. To reuse 07 unchanged AND represent both wasm traps and
//// > capability denials honestly, `Trapped` here carries the raw reason **String** (the
//// > spec-phrase match is done by `07`'s `runner.trap_matches`). The argument/result
//// > integer-bit-pattern contract is unchanged.
////
//// See `specs/phase-1/00-overview.md` D4 and `specs/phase-1/11-ir-lower-linker-cli.md`.
////
//// ## Phase-4 binding-threading LOCK (unit P4-08 §A.1 — no new stage, no new axis reach)
////
//// Phase 4 adds **no new pipeline stage, no new IR node, and no new `PipelineError`
//// variant** (G7). The two Phase-4 axes — `state_strategy` (`Cell`/`Threaded`) and
//// `mem_tier`/`table_tier` (`Paged`/`Atomics`/`Nif` · …) — are **build-time fields on the
//// one `Binding`** that already threads through every stage. The pipeline runs the **same
//// five stages in the same order** regardless of them:
////   `source_to_ir → lower_ir → optimize_ir → ir_to_cmod (emit_core) → cmod_to_beam`.
//// **No stage branches on a Phase-4 axis.** The axes are consumed at exactly two points, both
//// downstream of the stage graph:
////   - **codegen** — `emit_core` reads `binding.state_strategy` (the one codegen-shape switch:
////     the `Cell` pdict seam vs the `Threaded` record-threading seam) and the linker-resolved
////     `binding.mem_module`/`table_module`/`state_module` **module names** (never `mem_tier`/
////     `table_tier` — the tier is a build-time module swap the emitter never sees, G5); and
////   - **run time** — the linked `twocore@runtime@rt_*` module implements the chosen tier.
//// A tier/strategy **mismatch** is a *linker* rejection (`profiles.validate_binding`/`link`),
//// surfaced **before** the pipeline runs (at the CLI's `resolve_binding`, `twocore.gleam`) —
//// **not** a pipeline-stage error. So adding a tier is a runtime-module + `Binding`-field job,
//// **never a pipeline edit**; this module threads the chosen `Binding` unchanged.
////
//// ## The strategy-aware run-ABI (unit P4-08 §C — signature-stable, self-detecting)
////
//// `instantiate`/`invoke_instance`/`run_source` do **not** gain a `Binding` parameter. The
//// owned process (`twocore_cli_ffi.erl`) discriminates the state strategy from
//// `instantiate/0`'s **return value** (unambiguous by the keystone shapes): the atom `'ok'`
//// → the `Cell` loop (apply `Fun(Args)`, state in the pdict cell); the `InstanceState` record
//// `{instance_state,_,_,_}` → the `Threaded` loop (apply `Fun(St, Args…) -> {Package, St'}`,
//// threading `St'` across invokes as a value). The `Cell` path is byte-identical to Phase 2/3;
//// a `Threaded`/`atomics` build runs the SAME driver code end-to-end (G7).

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import twocore/backend/build_beam
import twocore/backend/chunk
import twocore/backend/core_erlang.{type CModule}
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/lower
import twocore/frontend/wasm/validate
import twocore/ir
import twocore/ir/parser as ir_parser
import twocore/middle/ir_lower
import twocore/middle/ir_opt
import twocore/runtime/instance.{type Binding}
import twocore/runtime/link
import twocore/runtime/porffor_abi.{type PorfValue}
import twocore/runtime/profiles
import twocore/runtime/rt_js_builtins
import twocore/runtime/rt_js_store
import twocore/runtime/rt_js_types.{type HostHooks}
import twocore/runtime/rt_state.{type InstanceState}
import twocore/runtime/rt_teavm

// ─────────────────────────────── composed error type (D4) ───────────────────────────────

/// The union of every stage's error, assembled at the driver boundary. Each variant WRAPS
/// the failing stage's OWN error type (D4) — there is no shared `StageError`. A
/// `Result(_, PipelineError)` is `Error(variant)` iff that named stage rejected the input
/// (fail-closed) — never a panic.
///
/// Variants (in pipeline order):
/// - `DecodeFailed`: the WASM binary decoder rejected the bytes (unit 05).
/// - `ValidateFailed`: the `full` validator rejected the module (unit 10a).
/// - `FrontendLowerFailed`: WASM-AST → IR lowering failed (unit 10b).
/// - `IrLowerFailed`: the IR→IR Safe policy pass rejected a `CallHost` (unit 11a).
/// - `EmitFailed`: `emit_core` could not produce Core Erlang (unit 08).
/// - `BuildFailed`: the Core Erlang → `.beam` build/load step failed (unit 04).
pub type PipelineError {
  DecodeFailed(ast.DecodeError)
  ValidateFailed(validate.ValidateError)
  FrontendLowerFailed(lower.LowerError)
  IrLowerFailed(ir_lower.LowerError)
  EmitFailed(emit_core.EmitError)
  BuildFailed(build_beam.BuildError)
}

/// A short, human-readable rendering of a `PipelineError` (which stage + the wrapped error)
/// for CLI stderr. Total — never panics. The text is diagnostic only; programmatic callers
/// should match the variant, not parse this string.
pub fn describe(error: PipelineError) -> String {
  case error {
    DecodeFailed(e) -> "decode: " <> string.inspect(e)
    ValidateFailed(e) -> "validate: " <> string.inspect(e)
    FrontendLowerFailed(e) -> "lower: " <> string.inspect(e)
    IrLowerFailed(e) -> "ir-lower: " <> string.inspect(e)
    EmitFailed(e) -> "emit: " <> string.inspect(e)
    BuildFailed(e) -> "build: " <> string.inspect(e)
  }
}

// ─────────────────────────────── the run/invoke ABI ───────────────────────────────

/// The outcome of invoking a compiled export on the BEAM.
///
/// - `Returned(values)`: a normal return; `values` are the raw result bit patterns as
///   integers (Phase-1 exports are single-result, so length 1).
/// - `Trapped(reason)`: a runtime trap or capability denial — the catchable BEAM error
///   reason rendered as text (e.g. `"{wasm_trap,int_div_by_zero}"`,
///   `"{capability_denied,env,forbidden}"`). The caller maps it to the spec phrase.
/// - `UncaughtException(tag_id, payload)`: a WASM **exception** that unwound out of the
///   export uncaught (Phase-7, T8) — DISTINCT from a trap (`assert_exception` ≠ `assert_trap`).
///   `tag_id` is the throwing module's module-local tag index (T4); `payload` is the operand
///   value list (raw bit-pattern integers). Split from a `{wasm_exn, TagId, Payload}` BEAM
///   error term (raised by `rt_exn`) at the run-ABI boundary; a `{wasm_trap, Kind}` stays
///   `Trapped`. NOT a `TrapReason` (a WASM exception rides its own term class — S8/T8).
pub type RunResult {
  Returned(values: List(Int))
  Trapped(reason: String)
  UncaughtException(tag_id: Int, payload: List(Int))
}

/// Split a rendered BEAM error `reason` (from `twocore_cli_ffi`'s `render_reason`, i.e.
/// `io_lib:format("~0p", [Reason])`) into the distinct run-ABI outcome (T8): a
/// `{wasm_exn, TagId, Payload}` term (an uncaught WASM exception raised by `rt_exn`) becomes
/// `UncaughtException(tag_id, payload)`; ANY other reason — a `{wasm_trap, Kind}` trap, a
/// `{capability_denied, …}` host denial, a fuel raise, or any incidental BEAM error — stays
/// `Trapped(reason)`. The tag id is always recovered; the payload is best-effort (a payload of
/// all-printable bytes that `~0p` rendered as a string decodes to `[]`, harmless — the tag id is
/// the load-bearing discriminant). Total — never panics.
fn classify_run_error(reason: String) -> RunResult {
  case string.starts_with(reason, "{wasm_exn,") {
    False -> Trapped(reason)
    True -> {
      // "{wasm_exn,<tag>,<payload>}" → drop the tag atom + trailing "}", split off <tag>.
      let inner =
        reason
        |> string.drop_start(string.length("{wasm_exn,"))
        |> string.drop_end(1)
      case string.split_once(inner, ",") {
        Error(_) -> Trapped(reason)
        Ok(#(tag_str, payload_str)) ->
          case int.parse(tag_str) {
            Error(_) -> Trapped(reason)
            Ok(tag_id) -> UncaughtException(tag_id, parse_payload(payload_str))
          }
      }
    }
  }
}

/// Best-effort parse of a `~0p`-rendered payload list `"[16,195]"` into `List(Int)`. Returns
/// `[]` when the payload is not a bracketed integer list (e.g. `~0p` rendered an all-printable
/// byte list as a quoted string) — the tag id remains the reliable discriminant. Total.
fn parse_payload(s: String) -> List(Int) {
  case string.starts_with(s, "[") && string.ends_with(s, "]") {
    False -> []
    True ->
      case string.drop_start(s, 1) |> string.drop_end(1) {
        "" -> []
        body ->
          list.try_map(string.split(body, ","), fn(e) {
            int.parse(string.trim(e))
          })
          |> result.unwrap([])
      }
  }
}

/// Load `beam` into the build VM (D10) and apply `export`/`length(args)` IN THE CALLING
/// PROCESS, catching any trap. This is the same-process one-shot: the apply runs in the
/// caller's process, so a process-dictionary effect (e.g. `rt_meter` fuel) is observable by
/// the caller afterwards. It does NOT call `instantiate/0`, so it is only correct for PURE
/// modules (no memory/globals/tables); stateful modules must go through the
/// `instantiate → invoke_instance` process ABI below (E5). Retained for the fuel-measuring
/// `ir_lower` tests, which require same-process execution.
///
/// - `beam`: the compiled `.beam` binary (from `cmod_to_beam`).
/// - `mod`: the module's atom NAME (the name baked into the `.core`, i.e. `ir.Module.name`).
/// - `export`: the exported function name to apply.
/// - `args`: the call arguments as raw unsigned bit-pattern integers (see the ABI above).
///
/// Returns `Returned([value])` on a normal single-result return, or `Trapped(reason)` if the
/// call raises (a trap or a deny-all capability denial), or if loading the binary fails
/// (`Trapped("load failed: …")`). Total — never panics.
pub fn invoke(
  beam: BitArray,
  mod: String,
  export: String,
  args: List(Int),
) -> RunResult {
  case build_beam.load_module(atom.create(mod), "twocore_cli", beam) {
    Error(reason) -> Trapped("load failed: " <> reason)
    Ok(mod_atom) ->
      case ffi_catch_apply(mod_atom, atom.create(export), args) {
        Ok(value) -> Returned([value])
        Error(reason) -> classify_run_error(reason)
      }
  }
}

/// A live instance: the OWNING PROCESS that ran `instantiate/0` and holds this instance's
/// per-instance state (one-instance-one-process, E1). Every `invoke_instance` is routed into
/// it, so each invoke reads this instance's state and cross-invoke state persists.
///
/// The process holds the state per the build's `state_strategy` (self-detected by the shim,
/// unit P4-08 §C.2): under `Cell` in its **process-dictionary cell**; under `Threaded` as the
/// **`InstanceState` record carried as a loop variable** (threaded across invokes as a value,
/// never in the pdict). This handle is opaque to that choice — the run-ABI signature is the
/// same for both.
pub opaque type InstanceProc {
  InstanceProc(proc: Pid)
}

/// **Instantiate** a loaded module in its own OWNED PROCESS (the run-ABI's middle step,
/// E5: `load → instantiate → invoke`). Loads `beam` ONCE into the build VM, then spawns a
/// process and runs the generated `instantiate/0` IN it — building that process's fresh
/// per-instance state (memory/table/globals + active element/data segments + `start`).
///
/// **Strategy-aware, signature-stable (unit P4-08 §C):** the shim discriminates the build's
/// `state_strategy` from `instantiate/0`'s return — the atom `'ok'` (`Cell`, seeds the pdict
/// cell) vs the `InstanceState` record (`Threaded`, held as the process's loop variable) — so
/// this function needs **no** `Binding` parameter and both strategies share one code path.
///
/// - `beam`: the compiled `.beam` binary (from `cmod_to_beam`).
/// - `mod`: the module's atom NAME (must match the name baked into the `.core`).
/// - Returns `Ok(InstanceProc)` once the state is seeded and the process is ready for
///   `invoke_instance`; `Error("load failed: …")` if the binary will not load; or
///   `Error(reason)` for an INSTANTIATION-TIME TRAP (an OOB active segment / trapping
///   `start`) — surfaced identically to a runtime trap. Total — never panics.
pub fn instantiate(
  beam: BitArray,
  mod: String,
) -> Result(InstanceProc, String) {
  case build_beam.load_module(atom.create(mod), "twocore_cli", beam) {
    Error(reason) -> Error("load failed: " <> reason)
    Ok(mod_atom) ->
      case ffi_start_instance(mod_atom) {
        Ok(proc) -> Ok(InstanceProc(proc))
        Error(reason) -> Error(reason)
      }
  }
}

/// **Invoke** an export on a live instance (the run-ABI's last step). Routes the call INTO
/// the instance's owned process via `call_instance`, so it reads that instance's state.
///
/// **Strategy-aware, signature-stable (unit P4-08 §C):** under `Cell` the process applies
/// `Module:export(Args)` against its pdict cell; under `Threaded` it applies
/// `Module:export(St, Args…)`, unpacks the returned `{Package, St'}`, and threads `St'` into
/// the next invoke (so a mutation observed here persists into the following `invoke_instance`
/// on the same handle). Either way this returns the unpacked result `Package`, so the caller
/// sees one uniform shape.
///
/// - `proc`: a live `InstanceProc` (from `instantiate`).
/// - `export`: the exported function name to apply.
/// - `args`: raw unsigned bit-pattern integer arguments (the D5 ABI).
/// - Returns `Returned([value])` on a normal single-result return or `Trapped(reason)` on a
///   trap / capability denial. Total — never panics.
pub fn invoke_instance(
  proc: InstanceProc,
  export: String,
  args: List(Int),
) -> RunResult {
  let InstanceProc(pid) = proc
  case ffi_call_instance(pid, atom.create(export), args) {
    Ok(value) -> Returned([value])
    Error(reason) -> classify_run_error(reason)
  }
}

/// Stop a live instance's owned process (its pdict cell is GC'd with it). Call when an
/// instance is no longer needed; total.
pub fn stop_instance(proc: InstanceProc) -> Nil {
  let InstanceProc(pid) = proc
  ffi_stop_instance(pid)
}

/// The Pid of an instance's owned process — the process that holds its linear memory,
/// globals and tables (one-instance-one-process). Exposed so an embedder can attribute
/// the guest's real resource usage (`erlang:process_info` — reductions, memory, mailbox)
/// EXTERNALLY, without messaging the guest. Total.
pub fn instance_pid(proc: InstanceProc) -> Pid {
  let InstanceProc(pid) = proc
  pid
}

/// Ask an instance's owned process for memory 0's current size, in 64 KiB pages
/// (`memory.size`), read IN that process so it reflects the guest's real linear-memory
/// footprint (the per-instance memory cell/record is process-local). A guest with no
/// memory reports 0. This RPCs the guest process (it serialises behind any in-flight
/// invoke), so prefer `instance_pid` + `process_info` for a periodic external snapshot
/// and reserve this for an on-demand probe. Total.
pub fn mem_size_instance(proc: InstanceProc) -> Int {
  let InstanceProc(pid) = proc
  ffi_mem_size(pid)
}

/// **Embedder host injection** — instantiate `beam` (whose IR is `m`) with the EMBEDDER's own
/// function-import closures, so a host BEAM program (e.g. the `dance` platform) provides the
/// guest's `(import "cap" "name" (func …))` imports as native Gleam behaviour.
///
/// This reuses the existing, D3a-clean `CallImport` seam (the same path a cross-module or
/// `spectest` function import travels): every `ImportFn(cap, name, ty)` in `m` is wired to a
/// `link.provided_func(ty, …)` whose dispatch closure calls `host(cap, name, args)`. The closure
/// runs IN the instance's owned process, so `host` may read/write THIS instance's linear memory
/// via `rt_mem` (exposed as `embed.mem_read`/`embed.mem_write`). No `rt_host`, `emit_core`, or
/// frozen ABI is touched — this is purely additive over `link`/`pipeline`.
///
/// Safety: the injected closures are supplied by the trusted embedder at instantiate time, never
/// derived from guest data (D3a); generated code still names no callee. State imports (globals/
/// tables/memories) are resolved by `link.link_imports` against the built-in providers only (an
/// embedder host-function guest is expected to import functions, not state) — an unsatisfied
/// state import fails closed here (`Error`), never a silent default (spec §4.5.4).
///
/// - `beam`: the compiled module (from `cmod_to_beam` / `embed.compile`).
/// - `m`: that module's IR — its `imports` order drives the woven function-import vector.
/// - `host`: the embedder's dispatcher. Receives `(capability, name, args)` where `args` are the
///   call's raw WASM argument bit patterns (D5); returns the raw result bit patterns (`[]` for a
///   `() ->` host function). `host` MUST be total + node-safe (a host handler that crashes the
///   node is a sandbox hole — the embedder's contract, mirroring `rt_host.HostHandler`).
/// - Returns `Ok(InstanceProc)` once the instance is seeded in its owned process, or
///   `Error(reason)` on an unsatisfied/mismatched state import, a load failure, or an
///   instantiation-time trap. Total — never panics.
pub fn instantiate_with_host(
  beam: BitArray,
  m: ir.Module,
  host: fn(String, String, List(Int)) -> List(Int),
) -> Result(InstanceProc, String) {
  case link.link_imports(m, []) {
    Error(e) -> Error(link.import_error_phrase(e))
    Ok(state) -> {
      // Mirror `link_porffor_imports`: append the function-import dispatch vector ONLY when the
      // module actually calls an imported function, so the woven `Imports` arity matches the
      // generated `instantiate/1` byte-for-byte (an import-but-never-called module stays
      // state-only). The func vector is one closure per `ImportFn`, in declaration order.
      let provided = case module_calls_import(m) {
        False -> state
        True -> list.append(state, host_func_vector(m, host))
      }
      start_provided_instance(beam, m.name, provided)
    }
  }
}

/// Build the positional function-import dispatch vector for `instantiate_with_host`: one
/// `link.provided_func(ty, closure)` per `ImportFn` in `m.imports` declaration order (the exact
/// order `link.link_func_imports` and `emit_core`'s dispatch-vector seed use). Each closure
/// coerces the raw WASM argument list to `Int`s (D5), calls the embedder `host`, and coerces the
/// results back — the 1-ary `List(Dynamic) -> List(Dynamic)` shape `link.call_import` applies.
fn host_func_vector(
  m: ir.Module,
  host: fn(String, String, List(Int)) -> List(Int),
) -> List(link.Provided) {
  list.filter_map(m.imports, fn(imp) {
    case imp {
      ir.ImportFn(capability:, name:, ty:) ->
        case rt_teavm.is_teavm_capability(capability) {
          // A TeaVM WASM GC runtime import (teavmJso/wasm:js-string/teavmMemory/teavmDate/teavm) is
          // REFERENCE-typed (externref/funcref/GC refs), which the numeric `host` ABI cannot carry.
          // Resolve it to `rt_teavm`'s TERM-native handler, exactly as `link.resolve_func_provided`
          // does — so a Java/TeaVM guest instantiates while the embedder's `host` still services the
          // (i32-only) `dance.*`/`env`/… imports numerically.
          True ->
            Ok(link.provided_func(ty, rt_teavm.dispatch(capability, name)))
          False ->
            Ok(
              link.provided_func(ty, fn(args) {
                host(capability, name, list.map(args, dyn_to_int))
                |> list.map(to_dynamic)
              }),
            )
        }
      _ -> Error(Nil)
    }
  })
}

/// **Exec** a PREBUILT `.beam` (the run-ABI on an already-compiled module — NO compile step).
/// Reads the module name baked into `beam`, loads + instantiates it in an owned process, then
/// invokes `export(args)` `repeat` times in that process, timing ONLY the invocations
/// (excludes compile, load, and instantiate — for benchmarking the emitted BEAM code).
///
/// - `beam`: a compiled `.beam` binary (e.g. from `to-beam`).
/// - `export`/`args`: as `run` (raw bit-pattern integer args).
/// - `repeat`: number of invocations (>= 1); the timing covers all of them.
/// - Returns `Ok(#(micros, RunResult))` — `micros` is the total wall time for the calls,
///   `RunResult` the LAST call's outcome. `Error(reason)` if the `.beam` is unreadable / won't
///   load; an instantiation/runtime trap is `Ok(#(0, Trapped(reason)))`. Total — never panics.
pub fn exec_beam(
  beam: BitArray,
  export: String,
  args: List(Int),
  repeat: Int,
) -> Result(#(Int, RunResult), String) {
  case ffi_module_name(beam) {
    Error(reason) -> Error("not a .beam: " <> reason)
    Ok(mod) ->
      case instantiate(beam, mod) {
        Error(reason) -> Ok(#(0, Trapped(reason)))
        Ok(proc) -> {
          let InstanceProc(pid) = proc
          let out = case
            ffi_bench_instance(pid, atom.create(export), args, repeat)
          {
            Ok(#(micros, value)) -> #(micros, Returned([value]))
            Error(reason) -> #(0, Trapped(reason))
          }
          stop_instance(proc)
          Ok(out)
        }
      }
  }
}

/// Apply `module:function(args)` IN THE CALLING PROCESS, capturing a trap as `Error(text)`
/// (the same-process catching-apply seam). See `src/twocore_cli_ffi.erl`.
@external(erlang, "twocore_cli_ffi", "catch_apply")
fn ffi_catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

/// Spawn an instance's owned process and run `module:instantiate()` in it (the
/// one-instance-one-process seam). `Ok(pid)` once seeded; `Error(reason)` on an
/// instantiation-time trap. See `src/twocore_cli_ffi.erl`.
@external(erlang, "twocore_cli_ffi", "start_instance")
fn ffi_start_instance(module: Atom) -> Result(Pid, String)

/// Spawn an IMPORT-BEARING instance's owned process and run `module:instantiate/1(Imports)` in
/// it (P7-08 / R4). `imports` is the positional `[Provided ...]` list `link.link_imports` +
/// `link.link_func_imports` returned, handed over opaquely. `Ok(pid)` once seeded; `Error(reason)`
/// on an instantiation-time trap. See `src/twocore_cli_ffi.erl`.
@external(erlang, "twocore_cli_ffi", "start_instance_with")
fn ffi_start_instance_with(
  module: Atom,
  imports: Dynamic,
) -> Result(Pid, String)

/// Identity coercion of any Gleam value to `Dynamic` (identity at runtime) — used to hand the
/// positional `List(Provided)` import list to the generated `instantiate/1` as one opaque
/// argument (the same shape ABI the conformance driver uses).
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

/// Identity coercion of a raw WASM argument (`Dynamic`) to `Int`. Sound: a `CallImport`
/// argument is always a raw i32/i64/f32/f64 bit pattern rendered as an Erlang integer (D5), so
/// the runtime term IS an integer. Used by `host_func_vector` to hand the embedder `host` a
/// `List(Int)` (the same raw-bit ABI `invoke_instance`/`rt_host.HostHandler` use).
@external(erlang, "gleam_stdlib", "identity")
fn dyn_to_int(x: Dynamic) -> Int

/// Apply `function(args)` inside an instance's owned process. `Ok(v)` / `Error(reason)`.
@external(erlang, "twocore_cli_ffi", "call_instance")
fn ffi_call_instance(
  proc: Pid,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

/// Apply `function(args)` inside an instance's owned process, typed for a **2-value** result
/// package (P7-08). Bound to the SAME Erlang `call_instance/3` as `ffi_call_instance` (Erlang is
/// untyped), but typed `Result(#(Int, Int), String)` so a Porffor `m : () -> (f64 i32)` return —
/// packaged as the 2-tuple `{f64_bits, type_tag}` (emit_core's `r >= 2` packaging, R17) — is
/// received directly as `Ok(#(f64_bits, type_tag))`. `Error(reason)` on a trap / uncaught throw.
@external(erlang, "twocore_cli_ffi", "call_instance")
fn ffi_call_instance_pair(
  proc: Pid,
  function: Atom,
  args: List(Int),
) -> Result(#(Int, Int), String)

/// Drain an instance's Porffor console output buffer (P7-08 §E/§H.2) — routes into the
/// instance's owned process and reads `rt_host:porffor_output/0` THERE (the buffer is
/// process-local). Returns the raw byte stream (`<<>>` if the program never printed).
@external(erlang, "twocore_cli_ffi", "porffor_output")
fn ffi_porffor_output(proc: Pid) -> BitArray

/// Ask an instance's owned process to exit (cell GC'd with it).
@external(erlang, "twocore_cli_ffi", "stop_instance")
fn ffi_stop_instance(proc: Pid) -> Nil

/// Ask an instance's owned process for memory 0's size in 64 KiB pages, read THERE (the
/// memory cell/record is process-local). `0` for a memory-less guest. Backs
/// `mem_size_instance`.
@external(erlang, "twocore_cli_ffi", "mem_size")
fn ffi_mem_size(proc: Pid) -> Int

/// Read the module name baked into a `.beam` binary (so a prebuilt `.beam` can be loaded even
/// when its filename differs from its module name). `Ok(name)` / `Error(reason)`.
@external(erlang, "twocore_cli_ffi", "module_name")
fn ffi_module_name(beam: BitArray) -> Result(String, String)

/// Invoke `function(args)` `repeat` times inside an instance's owned process, returning
/// `Ok(#(total_micros, last_value))` / `Error(reason)`. Times only the invocations.
@external(erlang, "twocore_cli_ffi", "bench_instance")
fn ffi_bench_instance(
  proc: Pid,
  function: Atom,
  args: List(Int),
  repeat: Int,
) -> Result(#(Int, Int), String)

// ─────────────────────────────── composable stage drivers ───────────────────────────────

/// Decode → validate → frontend-lower a `.wasm` binary into the shared IR (the unit-10
/// frontend slice). Each stage's typed error is mapped to its `PipelineError` variant.
///
/// - `wasm`: untrusted `.wasm` bytes.
/// - Return: `Ok(ir.Module)` or the first failing stage's `Error(PipelineError)`. No policy
///   pass or codegen is run here (use `ir_to_cmod` for those). Total — never panics.
pub fn source_to_ir(wasm: BitArray) -> Result(ir.Module, PipelineError) {
  source_to_ir_with(wasm, False)
}

/// As `source_to_ir`, but `narrow_carried` selects the frontend liveness narrowing (lever 5). Pass
/// `binding.narrow_carried` from a binding-carrying compile path (e.g. `run_source`); `False` (the
/// `source_to_ir/1` default) reproduces the byte-identical no-narrowing lowering. The narrowing only
/// ever removes a carried local it can PROVE dead at its construct's exit, so `True` is behaviour-
/// preserving.
pub fn source_to_ir_with(
  wasm: BitArray,
  narrow_carried: Bool,
) -> Result(ir.Module, PipelineError) {
  case decode.decode(wasm) {
    Error(e) -> Error(DecodeFailed(e))
    Ok(m) ->
      case validate.validate(m) {
        Error(e) -> Error(ValidateFailed(e))
        Ok(tm) ->
          case lower.lower_with(tm, narrow_carried) {
            Error(e) -> Error(FrontendLowerFailed(e))
            Ok(irmod) -> Ok(irmod)
          }
      }
  }
}

/// Run the IR→IR Safe policy pass (`ir_lower`, unit 11a) over `m` under `binding`.
///
/// - `m`: the IR module (e.g. from `source_to_ir` or `ir/parser`).
/// - `binding`: the build-time runtime binding (its `mode`/`stdlib_module` drive policy).
/// - Return: `Ok(rewritten_module)` (CallHosts gated, metering inserted), or
///   `Error(IrLowerFailed(_))` on the first policy violation (fail-closed). Total.
pub fn lower_ir(
  m: ir.Module,
  binding: Binding,
) -> Result(ir.Module, PipelineError) {
  case ir_lower.lower(m, binding) {
    Error(e) -> Error(IrLowerFailed(e))
    Ok(lowered) -> Ok(lowered)
  }
}

/// Run the shared IR→IR optimizer over `m` at the level carried by the profile (F1/F7).
///
/// The optimizer sits BETWEEN `ir_lower` and `emit_core`: `source_to_ir → ir_lower →
/// optimize_ir → emit_core`. The level is read from `binding.opt_level` (F7 — the profile is
/// the single source of truth), so `profiles.safe()` optimizes at `Baseline` (trust-neutral
/// passes) and `profiles.unsafe()` at `Aggressive` (baseline + Unsafe-only passes).
///
/// - `m`: the IR module (post-`ir_lower`, so `Charge` metering nodes are already present under
///   `MeterFuel` and absent under `MeterOff` — the optimizer must PRESERVE the charges it sees,
///   F3, and only the `Aggressive` charge-elision pass may remove them, unit 04).
/// - `binding`: the build-time profile; only `binding.opt_level` is read here.
/// - Return: a semantics-preserving rewrite of `m` (F2). `OptNone` is the identity, so a
///   profile with `opt_level: OptNone` BYPASSES the optimizer (the Phase-1/2 build path / F2
///   differential baseline). TOTAL — `ir_opt.optimize` never fails, so this returns a bare
///   `ir.Module`, not a `Result` (no new `PipelineError` variant, F7).
pub fn optimize_ir(m: ir.Module, binding: Binding) -> ir.Module {
  ir_opt.optimize(m, binding.opt_level)
}

/// IR → `#(lowered_optimized_module, cmod)`: run `lower_ir` (Safe policy pass / metering)
/// then `optimize_ir` (level from `binding.opt_level`) ONCE, then `emit_core`, returning BOTH
/// the exact `ir.Module` `emit_core` consumed AND the Core-shaped `CModule` it produced.
///
/// This is the **lower-ONCE seam** (Phase-12 · R17) for any consumer that must run a second
/// analysis over the module the `.beam` is generated from — chiefly the bindings driver, which
/// hands the returned module to `iface.describe` while the returned `CModule` becomes the `.beam`
/// (`cmod_to_beam`). Because both see the IDENTICAL lowered+optimized function bodies, a derived
/// property (`touches_state`, emitted arity) can never diverge from the `.beam` ABI — the failure
/// mode R17 guards against (a mutation-carrying export misclassified pure, silently dropping `St'`).
/// `ir_to_cmod/2` is exactly this seam with the module discarded.
///
/// - `m`: the IR module to compile (e.g. from `source_to_ir` or `ir/parser`).
/// - `binding`: the build-time runtime binding (chokepoint module names + policy mode + the
///   optimizer level).
/// - Return: `Ok(#(lowered_optimized_module, cmod))`, or `Error(IrLowerFailed/EmitFailed)`.
///   The module's `.name` (the compiled atom, `twocore@wasm@<base>`) is preserved by `lower_ir`/
///   `optimize_ir` — it is the atom the `.beam` loads under and the binding dispatches into. Total.
pub fn ir_to_lowered_cmod(
  m: ir.Module,
  binding: Binding,
) -> Result(#(ir.Module, CModule), PipelineError) {
  case lower_ir(m, binding) {
    Error(e) -> Error(e)
    Ok(lowered) -> {
      let optimized = optimize_ir(lowered, binding)
      case emit_core.emit_module(optimized, binding) {
        Error(e) -> Error(EmitFailed(e))
        Ok(cmod) -> Ok(#(optimized, cmod))
      }
    }
  }
}

/// IR → the backend `CModule`: `ir_lower` (Safe policy pass / metering) → `ir_opt` (level from
/// `binding.opt_level`, F1) → `emit_core`. The canonical "IR → backend" seam the CLI's
/// `run`/`to-beam-wasm` and the test drivers compile through (`cmod_to_beam` /
/// `build_beam.compile_and_load` consume the result directly — no textual round trip).
///
/// Delegates to `ir_to_lowered_cmod/2` (the same three stages) and discards the module.
///
/// - `m`: the IR module to compile.
/// - `binding`: the build-time runtime binding.
/// - Return: `Ok(cmod)`, or `Error(IrLowerFailed/EmitFailed)`. Total — never panics.
pub fn ir_to_cmod(
  m: ir.Module,
  binding: Binding,
) -> Result(CModule, PipelineError) {
  ir_to_lowered_cmod(m, binding)
  |> result.map(fn(pair) { pair.1 })
}

/// IR → `.core` text: the same three stages as `ir_to_cmod`, pretty-printed by
/// `core_printer`. This is now a pure INSPECTION surface (the CLI's `to-core` dump and the
/// text-shape tests) — the compile path consumes the `CModule` directly (`cmod_to_beam`);
/// the printed text is never re-parsed.
///
/// - `m`: the IR module to compile.
/// - `binding`: the build-time runtime binding (chokepoint module names + policy mode + the
///   optimizer level).
/// - Return: `Ok(core_text)`, or `Error(IrLowerFailed/EmitFailed)`. Total — never panics.
pub fn ir_to_core(
  m: ir.Module,
  binding: Binding,
) -> Result(String, PipelineError) {
  ir_to_cmod(m, binding)
  |> result.map(core_printer.print_module)
}

/// Compile a backend `CModule` to an in-memory `.beam` binary (unit 04), WITHOUT loading it:
/// lower to Erlang Abstract Format (`eaf.module_forms`) and compile in-process via
/// `compile:forms/2` (`build_beam.compile_module`).
///
/// - `cmod`: the emitted Core-shaped module (its `.name` is the atom baked into the `.beam`).
/// - Return: `Ok(beam_bytes)` or `Error(BuildFailed(_))` (lowering/compile diagnostics).
///   Total — never panics on a malformed module (it becomes `Error`).
pub fn cmod_to_beam(cmod: CModule) -> Result(BitArray, PipelineError) {
  case build_beam.compile_module(cmod) {
    Error(e) -> Error(BuildFailed(e))
    Ok(#(_atom, beam)) -> Ok(beam)
  }
}

/// Lower + optimize + emit + **split** an IR module into N balanced Core sub-modules (chunk 0 first).
///
/// Same three stages as `ir_to_lowered_cmod` up to `emit_core.emit_module`, then `chunk.split_module`
/// partitions the whole-module `CModule` so the downstream `compile:forms` peak is bounded to
/// O(largest chunk) instead of O(whole module). `target <= 1` or a module with fewer than
/// `min_split_defs` defs returns a SINGLE chunk (the whole module), whose printed `.core` is
/// byte-identical to the unchunked path.
///
/// - `m`: the IR module. `binding`: the build-time binding. `target`: desired chunk count.
///   `min_split_defs`: don't split a module smaller than this (keeps small guests untouched).
/// - Return: `Ok([CModule])` (chunk order), or `Error(IrLowerFailed/EmitFailed)`. Total.
pub fn source_to_chunks(
  m: ir.Module,
  binding: Binding,
  target: Int,
  min_split_defs: Int,
) -> Result(List(CModule), PipelineError) {
  case lower_ir(m, binding) {
    Error(e) -> Error(e)
    Ok(lowered) -> {
      let optimized = optimize_ir(lowered, binding)
      case emit_core.emit_module(optimized, binding) {
        Error(e) -> Error(EmitFailed(e))
        Ok(cmod) -> Ok(chunk.split_module(cmod, target, min_split_defs))
      }
    }
  }
}

/// Compile chunk `CModule`s to loadable `.beam`s, **sequentially** — this is what bounds the peak
/// (each chunk's compile transients are reclaimed before the next starts).
///
/// - `chunks`: from `source_to_chunks` (chunk 0 first).
/// - Return: `Ok([#(module_atom, beam)])` in chunk order — chunk 0's atom is the guest's run-ABI
///   module name; the rest are its `_c<i>` helper modules that must be loaded alongside it. Or the
///   first chunk's `Error(BuildFailed(_))`. Total — never panics.
pub fn chunks_to_beams(
  chunks: List(CModule),
) -> Result(List(#(String, BitArray)), PipelineError) {
  list.try_map(chunks, fn(c) {
    case cmod_to_beam(c) {
      Error(e) -> Error(e)
      Ok(beam) -> Ok(#(c.name, beam))
    }
  })
}

/// IR → in-memory `.beam` binary: composes `ir_to_cmod` → `cmod_to_beam`, discarding the
/// intermediate lowered module. The one-call "compile an already-built `ir.Module`" seam for
/// callers that produce IR directly (e.g. the JS emit_2core frontend, SPEC§19.8) rather than
/// going through the `.wasm` → IR path.
///
/// - `m`: the IR module to compile; `m.name` rides on the emitted `CModule` and is the atom
///   the `.beam` loads under.
/// - `binding`: the build-time runtime binding (policy mode, optimizer level, chokepoints).
/// - Return: `Ok(beam_bytes)` or the first failing stage's `Error(IrLowerFailed/EmitFailed/
///   BuildFailed)`. Total — never panics.
pub fn compile_ir(
  m: ir.Module,
  binding: Binding,
) -> Result(BitArray, PipelineError) {
  ir_to_cmod(m, binding)
  |> result.try(cmod_to_beam)
}

/// Parse `.ir` text into an `ir.Module` (unit 02's parser). A convenience wrapper used by
/// the CLI's `.ir`-consuming subcommands; the `ir.parser.ParseError` is NOT a pipeline
/// stage error (it parses the inter-stage textual form), so it is surfaced as its own type.
///
/// - `text`: `.ir` source text.
/// - Return: `Ok(ir.Module)` or `Error(ir_parser.ParseError)`. Total.
pub fn parse_ir(text: String) -> Result(ir.Module, ir_parser.ParseError) {
  ir_parser.parse_module(text)
}

/// End-to-end: `.wasm` bytes → result on the BEAM, through the Phase-2 run-ABI
/// `load → instantiate → invoke` with one-instance-one-process isolation (E5).
///
/// Composes `source_to_ir` → `ir_to_cmod(binding)` → `cmod_to_beam` → `instantiate` (spawn
/// the instance's owned process + run `instantiate/0`) → `invoke_instance` → `stop_instance`.
/// This is the CLI `run` subcommand's engine and the shape the acceptance corpus proves
/// green. The raw-bit-pattern argument/result ABI (D5) is unchanged.
///
/// **Posture-agnostic (unit P4-08 §C.3):** `binding` carries the chosen `state_strategy` and
/// tiers **unchanged** through every stage. `emit_core` links the tier via `binding.mem_module`
/// and picks the state seam via `binding.state_strategy`; the run-ABI self-detects the strategy
/// (§C.2). So a `Threaded`/`atomics` binding runs the SAME driver code as `Cell`/`paged` and
/// returns **byte-identical** results (G7) — the difference is confined to the loaded `.beam`
/// (calling convention) and the linked runtime module. The caller is expected to pass a binding
/// already validated through `profiles.link/1` (the CLI does so via `resolve_binding`); a
/// tier/strategy incoherence is a linker rejection surfaced there, not a `PipelineError` here.
///
/// - `wasm`: the `.wasm` bytes.
/// - `binding`: the build-time runtime binding (e.g. `profiles.safe()`/`portable()`, or a
///   `resolve_binding`-validated composition).
/// - `export`: the exported function name to invoke.
/// - `args`: raw unsigned bit-pattern integer arguments.
/// - Return: `Ok(Returned(_))` on a normal return; `Ok(Trapped(reason))` for an
///   INSTANTIATION-TIME trap (OOB active segment / trapping `start`) OR a runtime trap —
///   both are runtime outcomes, surfaced identically; or the first compile-stage
///   `Error(PipelineError)`. Total — never panics.
pub fn run_source(
  wasm: BitArray,
  binding: Binding,
  export: String,
  args: List(Int),
) -> Result(RunResult, PipelineError) {
  case source_to_ir_with(wasm, binding.narrow_carried) {
    Error(e) -> Error(e)
    Ok(m) ->
      case ir_to_cmod(m, binding) {
        Error(e) -> Error(e)
        Ok(cmod) ->
          case cmod_to_beam(cmod) {
            Error(e) -> Error(e)
            Ok(beam) ->
              case instantiate(beam, m.name) {
                // An instantiation-time trap / uncaught throw (e.g. a throwing `start`) is a
                // runtime outcome, not a compile error — split exn vs trap identically (T8).
                Error(reason) -> Ok(classify_run_error(reason))
                Ok(proc) -> {
                  let result = invoke_instance(proc, export, args)
                  stop_instance(proc)
                  Ok(result)
                }
              }
          }
      }
  }
}

/// Like `run_source`, but compiles the guest as N balanced CHUNKS (see `source_to_chunks`), loads
/// every chunk beam, then instantiates + invokes the entry (chunk 0). Used to prove chunked
/// compilation is behaviour-identical to the whole-module path (a chunked guest must return
/// byte-identical results / traps), and it is the shape the memory-bounded server path uses.
///
/// - `wasm`/`binding`/`export`/`args`: as `run_source`. `target`/`min_split_defs`: chunk controls
///   (a small `min_split_defs` forces a split even on a small guest, for testing).
/// - Return: identical to `run_source` (`Ok(Returned/Trapped/…)` or the first compile `Error`). The
///   helper chunks are inter-module `call` targets of the entry, so they are loaded FIRST; a helper
///   that fails to load surfaces as an instantiation error. Total — never panics.
pub fn run_source_chunked(
  wasm: BitArray,
  binding: Binding,
  export: String,
  args: List(Int),
  target: Int,
  min_split_defs: Int,
) -> Result(RunResult, PipelineError) {
  case source_to_ir_with(wasm, binding.narrow_carried) {
    Error(e) -> Error(e)
    Ok(m) ->
      case source_to_chunks(m, binding, target, min_split_defs) {
        Error(e) -> Error(e)
        Ok(chunks) ->
          case chunks_to_beams(chunks) {
            Error(e) -> Error(e)
            // Unreachable: `source_to_chunks` always yields at least one chunk.
            Ok([]) ->
              Error(
                BuildFailed(
                  build_beam.CompileFailed([
                    "chunking produced no output modules",
                  ]),
                ),
              )
            Ok([#(name, beam), ..extras]) -> {
              // Load the helper chunks first so the entry's cross-chunk `call`s resolve.
              list.each(extras, fn(nb) {
                let _ =
                  build_beam.load_module(atom.create(nb.0), "twocore_cli", nb.1)
                Nil
              })
              case instantiate(beam, name) {
                Error(reason) -> Ok(classify_run_error(reason))
                Ok(proc) -> {
                  let result = invoke_instance(proc, export, args)
                  stop_instance(proc)
                  Ok(result)
                }
              }
            }
          }
      }
  }
}

// ─────────────────────────────── Phase-7: the Porffor JS-on-BEAM run path (P7-08) ───────────────────────────────

/// The outcome of running a Porffor-compiled JS program on the BEAM under `profiles.porffor()`
/// (P7-08 §C/§E). The **console output is the primary observable** (T12).
///
/// - `output`: the captured `console.log` byte stream (§E) — the exact bytes `print`/`printChar`
///   produced, ANSI escapes in-band; compared byte-for-byte against `porf run` (T13).
/// - `result`: the decoded completion value of the exported entry (§D) — a scalar
///   (`PNumber`/`PBool`/`PUndefined`) for the common case; a heap-typed result (string/object)
///   is `POpaque` here (its memory read is P7-09's FFI, §H.2 — but a `console.log` of a string
///   still appears in `output`).
/// - `trapped`: `Some(reason)` if the program trapped (an uncaught throw surfaced as a BEAM
///   exception, a denied/unprovided intrinsic, an instantiation-time trap, or a WASM trap) —
///   the rendered BEAM reason; `None` on a clean completion.
pub type PorfforRun {
  PorfforRun(output: BitArray, result: PorfValue, trapped: Option(String))
}

/// A fail-closed `porffor_abi.MemReader` for `run_porffor`: every read is denied, so a
/// heap-typed (pointer) completion value decodes to `POpaque` (T12 — scalar + console only in
/// this unit; the routed instance-memory reader that lets pointer results decode is P7-09's,
/// §H.2). Scalars (number/boolean/undefined) need no memory, so they decode precisely.
fn no_mem_reader(_addr: Int, _len: Int) -> Result(BitArray, Nil) {
  Error(Nil)
}

/// Compile + run a Porffor-emitted `.wasm` on the BEAM under `profiles.porffor()` and collect
/// its console output + decoded completion value (the JS-on-BEAM run path, P7-08 §C/§E). This
/// is the headline seam: `source_to_ir` → `ir_to_cmod(porffor())` → `cmod_to_beam` →
/// `instantiate` (owned process) → invoke the entry `main` (multi-value `(f64, i32)` return via
/// `ffi_call_instance_pair`) → drain the console buffer (`ffi_porffor_output`) → decode the pair
/// (`porffor_abi.porf_decode`). Conformance-neutral: a non-Porffor module never reaches this
/// path (the four `""` intrinsics, the buffer, and `porffor()` are inert for it).
///
/// - `wasm`: the Porffor-emitted `.wasm` bytes (EH-free subset for this unit; the EH pipeline
///   P7-03..07 extends it to `try/catch` programs).
/// - `main`: the entry export name — Porffor's top-level `#main` is always `"m"` (T10).
/// - Return: `Ok(PorfforRun)` with the captured output + decoded result (+ `trapped`), or a
///   compile-stage `Error(PipelineError)`. A runtime trap / uncaught throw is a `PorfforRun`
///   with `trapped: Some(_)` (still `Ok`), so a thrown program is judgeable distinctly from a
///   clean one. Total — never panics.
pub fn run_porffor(
  wasm: BitArray,
  main: String,
) -> Result(PorfforRun, PipelineError) {
  case source_to_ir(wasm) {
    Error(e) -> Error(e)
    Ok(m) ->
      // Resolve the import vector (state + function-import closures) under the porffor()
      // posture, where the four `""` intrinsics resolve to host closures (the "genuine host
      // capability" branch of link_func_imports — gated at call time by the HostWhitelist).
      case link_porffor_imports(m) {
        Error(reason) ->
          Ok(PorfforRun(<<>>, porffor_abi.PUndefined, Some("link: " <> reason)))
        Ok(provided) ->
          case ir_to_cmod(m, profiles.porffor()) {
            Error(e) -> Error(e)
            Ok(cmod) ->
              case cmod_to_beam(cmod) {
                Error(e) -> Error(e)
                Ok(beam) ->
                  case start_provided_instance(beam, m.name, provided) {
                    Error(reason) ->
                      Ok(PorfforRun(<<>>, porffor_abi.PUndefined, Some(reason)))
                    Ok(proc) -> {
                      let InstanceProc(pid) = proc
                      let outcome =
                        ffi_call_instance_pair(pid, atom.create(main), [])
                      // Drain AFTER the invoke: print/printChar wrote the instance's
                      // process-local buffer during the call (any partial output before a trap
                      // is still captured).
                      let output = ffi_porffor_output(pid)
                      let run = case outcome {
                        Ok(#(f64_bits, type_tag)) ->
                          PorfforRun(
                            output,
                            porffor_abi.porf_decode(
                              f64_bits,
                              type_tag,
                              no_mem_reader,
                            ),
                            None,
                          )
                        Error(reason) ->
                          PorfforRun(
                            output,
                            porffor_abi.PUndefined,
                            Some(reason),
                          )
                      }
                      stop_instance(proc)
                      Ok(run)
                    }
                  }
              }
          }
      }
  }
}

/// Resolve the full positional import vector for a Porffor module under `profiles.porffor()`:
/// the STATE imports (`link.link_imports` — empty for a typical Porffor module, which imports
/// only functions) followed by the function-import dispatch closures (`link.link_func_imports`,
/// appended in emit_core's order) when the module CALLS an imported function. Porffor's `""`
/// intrinsics are NOT link-checked (the "genuine host capability" branch); they resolve to host
/// closures gated at call time by the instance's `HostWhitelist`. Returns `Error(phrase)` on the
/// first link failure (spec §4.5.4), rendered by `link.import_error_phrase`. Total.
fn link_porffor_imports(m: ir.Module) -> Result(List(link.Provided), String) {
  case link.link_imports(m, []) {
    Error(e) -> Error(link.import_error_phrase(e))
    Ok(state) ->
      case module_calls_import(m) {
        False -> Ok(state)
        True ->
          case link.link_func_imports(m, []) {
            Error(e) -> Error(link.import_error_phrase(e))
            Ok(funcs) -> Ok(list.append(state, funcs))
          }
      }
  }
}

/// Load `beam` and start the instance's owned process with the matching instantiate ABI (R4): a
/// module with NO positional imports keeps `instantiate/0` (`ffi_start_instance`); an
/// import-bearing one gets `instantiate/1(Imports)` (`ffi_start_instance_with`), where `Imports`
/// is the positional `Provided` vector. Returns `Ok(InstanceProc)` once seeded, or
/// `Error(reason)` for a load failure / instantiation-time trap. Total.
fn start_provided_instance(
  beam: BitArray,
  mod: String,
  provided: List(link.Provided),
) -> Result(InstanceProc, String) {
  case build_beam.load_module(atom.create(mod), "twocore_cli", beam) {
    Error(reason) -> Error("load failed: " <> reason)
    Ok(mod_atom) -> {
      let started = case provided {
        [] -> ffi_start_instance(mod_atom)
        _ -> ffi_start_instance_with(mod_atom, to_dynamic(provided))
      }
      case started {
        Ok(pid) -> Ok(InstanceProc(pid))
        Error(reason) -> Error(reason)
      }
    }
  }
}

/// `True` iff `m` CALLS an imported function anywhere (its IR contains a `CallImport` node) — the
/// exact condition `emit_core`'s `needs_func_imports` uses to seed the function-import dispatch
/// vector at `instantiate`. The run-ABI mirrors it so the woven `Imports` arity matches the
/// generated `instantiate/1` byte-for-byte. Total.
fn module_calls_import(m: ir.Module) -> Bool {
  list.any(m.functions, fn(f) { expr_calls_import(f.body) })
}

// ─────────────────────────────── JS run-ABI (SPEC §19.8) ───────────────────────────────

/// The M20 differential-test observable for a compiled-JS run: what `console.*` printed
/// (byte-exact, in emission order) and how the top-level completed. `stdout` is
/// `rt_js_store.t_console_bytes(st')` — the deterministic in-store buffer, never real stdio.
/// `result` is `Ok(v)` for a normal `js_main` return (v is the raw `Dynamic` completion value,
/// typically JS `undefined`), or `Error(reason)` for a load failure, an uncaught JS throw
/// (rendered via `string.inspect`), or a trap/engine crash. The harness compares `stdout`
/// byte-for-byte across the interpreter and compiled paths.
pub type DiffRun {
  DiffRun(stdout: BitArray, result: Result(Dynamic, String))
}

/// The three outcomes of `apply_js_main` (wire terms from `twocore_rt_js_exec_ffi`).
/// `JsReturned`/`JsThrew` carry the recovered `InstanceState` alongside; `JsCrashed`
/// carries only the rendered reason (no recoverable state — the FFI returns the input st).
type JsExecOutcome {
  JsReturned(value: Dynamic)
  JsThrew(exn: Dynamic)
  JsCrashed(reason: String)
}

/// Apply the loaded module's `js_main(St, Frame, [])` under a `try…catch`, wrapping the
/// outcome as `#(JsExecOutcome, st')`. See `src/twocore_rt_js_exec_ffi.erl`.
@external(erlang, "twocore_rt_js_exec_ffi", "apply_js_main")
fn ffi_apply_js_main(
  module: Atom,
  st: InstanceState,
) -> #(JsExecOutcome, InstanceState)

/// **Run a compiled JS module on the BEAM from a fresh threaded state** (SPEC §19.8 — the
/// M20 harness's compiled-path driver). Builds the minimal empty `InstanceState`
/// (`fresh_full` with no memories/tables/globals — a JS unit uses none), seeds it with a
/// fresh `JsStore` (from `hooks`) + a full `Realm` (`init_realm`), then delegates to
/// `run_js_beam_in`. Total — never panics; a load failure or crash surfaces in
/// `DiffRun.result` as `Error`.
///
/// - `beam`: the compiled `.beam` binary (from `compile_ir` under `profiles.js_direct()`).
/// - `mod`: the module's atom NAME (must match `ir.Module.name` baked into the `.core`).
/// - `hooks`: the deterministic embedder capabilities (Date/Math.random/console sink).
/// - Returns `#(st', DiffRun)` — `st'` is the final threaded state (for further inspection
///   e.g. `rt_js_store.t_console_read`); `DiffRun` is the harness observable.
pub fn run_js_beam(
  beam: BitArray,
  mod: String,
  hooks: HostHooks,
) -> #(InstanceState, DiffRun) {
  let st =
    rt_state.fresh_full(
      rt_state.FullDecl(mems: [], globals: [], tables: [], ref_globals: []),
    )
  let st = rt_state.t_with_js_store(st, rt_js_store.t_store_new(hooks))
  let #(_realm, st) = rt_js_builtins.init_realm(st)
  run_js_beam_in(st, beam, mod)
}

/// **Run a compiled JS module on the BEAM in an already-seeded state** (SPEC §19.8). Loads
/// `beam`, applies `js_main(st, {undefined,undefined,undefined,undefined}, [])` in the
/// CALLING process under a protected apply, and packages the outcome as a `DiffRun`.
/// `st` must already carry `js_store: Some(_)` and `js_realm: Some(_)` (the caller ran
/// `t_store_new`/`init_realm`; `run_js_beam` does this). An uncaught JS throw is caught here
/// (R2 `{wasm_exn,0,[St',E]}`) — its mutated `st'` is recovered so `stdout` includes lines
/// printed before the throw. Total — never panics.
///
/// - `st`: the pre-seeded threaded instance state.
/// - `beam`/`mod`: as `run_js_beam`.
/// - Returns `#(st', DiffRun)`; on a load failure, `st' = st` and `stdout = <<>>`.
pub fn run_js_beam_in(
  st: InstanceState,
  beam: BitArray,
  mod: String,
) -> #(InstanceState, DiffRun) {
  case build_beam.load_module(atom.create(mod), "twocore_cli", beam) {
    Error(reason) -> #(
      st,
      DiffRun(stdout: <<>>, result: Error("load failed: " <> reason)),
    )
    Ok(mod_atom) -> {
      let #(outcome, st) = ffi_apply_js_main(mod_atom, st)
      let stdout = rt_js_store.t_console_bytes(st)
      let result = case outcome {
        JsReturned(v) -> Ok(v)
        JsThrew(e) -> Error("uncaught: " <> string.inspect(e))
        JsCrashed(reason) -> Error(reason)
      }
      #(st, DiffRun(stdout:, result:))
    }
  }
}

/// `True` iff `expr` (recursively, through the control-flow containers holding sub-`Expr`s)
/// contains a `CallImport` node. Mirrors `emit_core`'s private `expr_has_call_import`. Total.
fn expr_calls_import(expr: ir.Expr) -> Bool {
  case expr {
    ir.CallImport(..) -> True
    ir.Let(_, rhs, body) -> expr_calls_import(rhs) || expr_calls_import(body)
    ir.If(_, _, t, e) -> expr_calls_import(t) || expr_calls_import(e)
    ir.Switch(_, _, arms, default) ->
      list.any(arms, fn(a) {
        let ir.SwitchArm(_, b) = a
        expr_calls_import(b)
      })
      || expr_calls_import(default)
    ir.Block(_, _, body) -> expr_calls_import(body)
    ir.Loop(_, _, _, body) -> expr_calls_import(body)
    ir.Charge(_, body) -> expr_calls_import(body)
    _ -> False
  }
}
