//// Top-level driver glue (unit 11c completes unit 01's stub). Per-stage errors (D4)
//// compose **here**, at the driver boundary; there is **no single shared `StageError`**.
////
//// Each pipeline stage owns its own error type (`decode.DecodeError`,
//// `validate.ValidateError`, `lower.LowerError`, `ir_lower.LowerError`,
//// `emit_core.EmitError`, `build_beam.BuildError`). This module maps each into a
//// `PipelineError` variant at exactly ONE seam, and exposes the composable stage-driver
//// functions the CLI (`carder.gleam`) and the acceptance harness (`11d`) both call — so
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
////   the `carder_cli_ffi` catching-apply seam) and returns `Trapped(reason)`. The deny-all
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
////   `parse_ir → lower_ir → optimize_ir → ir_to_cmod (emit_core) → cmod_to_beam`.
//// **No stage branches on a Phase-4 axis.** The axes are consumed at exactly two points, both
//// downstream of the stage graph:
////   - **codegen** — `emit_core` reads `binding.state_strategy` (the one codegen-shape switch:
////     the `Cell` pdict seam vs the `Threaded` record-threading seam) and the linker-resolved
////     `binding.mem_module`/`table_module`/`state_module` **module names** (never `mem_tier`/
////     `table_tier` — the tier is a build-time module swap the emitter never sees, G5); and
////   - **run time** — the linked `carder@runtime@rt_*` module implements the chosen tier.
//// A tier/strategy **mismatch** is a *linker* rejection (`profiles.validate_binding`/`link`),
//// surfaced **before** the pipeline runs (at the CLI's `resolve_binding`, `carder.gleam`) —
//// **not** a pipeline-stage error. So adding a tier is a runtime-module + `Binding`-field job,
//// **never a pipeline edit**; this module threads the chosen `Binding` unchanged.
////
//// ## The strategy-aware run-ABI (unit P4-08 §C — signature-stable, self-detecting)
////
//// `instantiate`/`invoke_instance`/`run_ir` do **not** gain a `Binding` parameter. The
//// owned process (`carder_cli_ffi.erl`) discriminates the state strategy from
//// `instantiate/0`'s **return value** (unambiguous by the keystone shapes): the atom `'ok'`
//// → the `Cell` loop (apply `Fun(Args)`, state in the pdict cell); the `InstanceState` record
//// `{instance_state,_,_,_}` → the `Threaded` loop (apply `Fun(St, Args…) -> {Package, St'}`,
//// threading `St'` across invokes as a value). The `Cell` path is byte-identical to Phase 2/3;
//// a `Threaded`/`atomics` build runs the SAME driver code end-to-end (G7).

import carder/backend/build_beam
import carder/backend/chunk
import carder/backend/core_erlang.{type CModule}
import carder/backend/core_printer
import carder/backend/emit_core
import carder/ir
import carder/ir/parser as ir_parser
import carder/middle/ir_lower
import carder/middle/ir_opt
import carder/runtime/instance.{type Binding}
import carder/runtime/link
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

// ─────────────────────────────── composed error type (D4) ───────────────────────────────

/// The union of every stage's error, assembled at the driver boundary. Each variant WRAPS
/// the failing stage's OWN error type (D4) — there is no shared `StageError`. A
/// `Result(_, PipelineError)` is `Error(variant)` iff that named stage rejected the input
/// (fail-closed) — never a panic.
///
/// These are the IR-ENTRY stages only. A frontend (scribbler's WebAssembly decoder, arc's JS
/// emitter) owns its own source→IR error type and wraps this one for the backend half, so the
/// combined diagnostic reads end-to-end without carder knowing any source language.
///
/// Variants (in pipeline order):
/// - `IrLowerFailed`: the IR→IR Safe policy pass rejected a `CallHost` (unit 11a).
/// - `EmitFailed`: `emit_core` could not produce Core Erlang (unit 08).
/// - `BuildFailed`: the Core Erlang → `.beam` build/load step failed (unit 04).
pub type PipelineError {
  IrLowerFailed(ir_lower.LowerError)
  EmitFailed(emit_core.EmitError)
  BuildFailed(build_beam.BuildError)
}

/// A short, human-readable rendering of a `PipelineError` (which stage + the wrapped error)
/// for CLI stderr. Total — never panics. The text is diagnostic only; programmatic callers
/// should match the variant, not parse this string.
pub fn describe(error: PipelineError) -> String {
  case error {
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

/// Split a rendered BEAM error `reason` (from `carder_cli_ffi`'s `render_reason`, i.e.
/// `io_lib:format("~0p", [Reason])`) into the distinct run-ABI outcome (T8): a
/// `{wasm_exn, TagId, Payload}` term (an uncaught WASM exception raised by `rt_exn`) becomes
/// `UncaughtException(tag_id, payload)`; ANY other reason — a `{wasm_trap, Kind}` trap, a
/// `{capability_denied, …}` host denial, a fuel raise, or any incidental BEAM error — stays
/// `Trapped(reason)`. The tag id is always recovered; the payload is best-effort (a payload of
/// all-printable bytes that `~0p` rendered as a string decodes to `[]`, harmless — the tag id is
/// the load-bearing discriminant). Total — never panics.
///
/// PUBLIC because a frontend that composes its own `load → instantiate → invoke` loop (rather
/// than calling `run_ir`) must classify an INSTANTIATION-time failure identically — otherwise an
/// uncaught exception thrown by a `start` function is silently reported as a trap, a wrong
/// ANSWER rather than a compile error.
pub fn classify_run_error(reason: String) -> RunResult {
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
  case build_beam.load_module(atom.create(mod), "carder_cli", beam) {
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
  case build_beam.load_module(atom.create(mod), "carder_cli", beam) {
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
  instantiate_with_host_providers(beam, m, host, [])
}

/// `instantiate_with_host` plus caller-supplied `link.Provider`s — the entry point for a guest
/// whose imports are NOT all expressible over the numeric `host` ABI.
///
/// The embedder `host` dispatcher is numeric (`List(Int) -> List(Int)`, D5), which cannot carry a
/// BEAM term, so a guest importing REFERENCE-typed host functions (externref / funcref / GC refs
/// — e.g. a TeaVM WASM GC guest's `teavmJso` namespace) or importing host STATE (a global, table
/// or memory it does not define) needs a term-native source. That source is a `Provider`, handed
/// in by the frontend/embedder: `providers` is consulted FIRST for both the state imports
/// (`link.link_imports`) and each function import, and only a capability no provider owns falls
/// back to the numeric `host` dispatcher.
///
/// This is why carder needs no knowledge of any producer toolchain: the namespaces a TeaVM or
/// Porffor guest imports from are described entirely by the caller's `Provider` list (D3a — a
/// handed-in closure is a capability, never ambient authority).
///
/// - `beam`/`m`/`host`: as `instantiate_with_host`.
/// - `providers`: term-native externval sources (see `link.Provider`). `[]` reproduces
///   `instantiate_with_host` exactly.
/// - Returns `Ok(InstanceProc)`, or `Error(reason)` on an unsatisfied/mismatched state import, a
///   load failure, or an instantiation-time trap. Total — never panics.
pub fn instantiate_with_host_providers(
  beam: BitArray,
  m: ir.Module,
  host: fn(String, String, List(Int)) -> List(Int),
  providers: List(link.Provider),
) -> Result(InstanceProc, String) {
  case link.link_imports(m, providers) {
    Error(e) -> Error(link.import_error_phrase(e))
    Ok(state) -> {
      // Append the function-import dispatch vector ONLY when the module actually USES an
      // imported function, so the woven `Imports` arity matches the generated `instantiate/1`
      // byte-for-byte (an import-but-never-used module stays state-only). `emit_core` decides
      // that arity, so its `needs_func_imports` is the SINGLE predicate both sides read (R3) —
      // a second, weaker copy here would desync the two on a `return_call`/`ref.func`-only use.
      let provided = case emit_core.needs_func_imports(m) {
        False -> state
        True -> list.append(state, host_func_vector(m, host, providers))
      }
      instantiate_with_provided(beam, m.name, provided)
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
  providers: List(link.Provider),
) -> List(link.Provided) {
  list.filter_map(m.imports, fn(imp) {
    case imp {
      ir.ImportFn(capability:, name:, ty:) ->
        // A provider-owned capability resolves TERM-natively (it may carry references / GC refs
        // the numeric `host` ABI cannot express); anything else is serviced numerically by the
        // embedder's dispatcher. `link.link_func_imports` applies the identical precedence, so
        // both instantiate paths agree on which closure a given import gets.
        case link.link_func_imports(one_import_module(m, imp), providers) {
          Ok([resolved]) if providers != [] -> Ok(resolved)
          _ ->
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

/// A single-import projection of `m` — the same module with `imports` narrowed to just `imp`.
/// Lets `host_func_vector` reuse `link.link_func_imports` (the ONE definition of function-import
/// matching) per import, instead of re-implementing provider precedence. Total.
fn one_import_module(m: ir.Module, imp: ir.ImportDecl) -> ir.Module {
  ir.Module(..m, imports: [imp])
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
/// (the same-process catching-apply seam). See `src/carder_cli_ffi.erl`.
@external(erlang, "carder_cli_ffi", "catch_apply")
fn ffi_catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

/// Spawn an instance's owned process and run `module:instantiate()` in it (the
/// one-instance-one-process seam). `Ok(pid)` once seeded; `Error(reason)` on an
/// instantiation-time trap. See `src/carder_cli_ffi.erl`.
@external(erlang, "carder_cli_ffi", "start_instance")
fn ffi_start_instance(module: Atom) -> Result(Pid, String)

/// Spawn an IMPORT-BEARING instance's owned process and run `module:instantiate/1(Imports)` in
/// it (P7-08 / R4). `imports` is the positional `[Provided ...]` list `link.link_imports` +
/// `link.link_func_imports` returned, handed over opaquely. `Ok(pid)` once seeded; `Error(reason)`
/// on an instantiation-time trap. See `src/carder_cli_ffi.erl`.
@external(erlang, "carder_cli_ffi", "start_instance_with")
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
@external(erlang, "carder_cli_ffi", "call_instance")
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
@external(erlang, "carder_cli_ffi", "call_instance")
fn ffi_call_instance_pair(
  proc: Pid,
  function: Atom,
  args: List(Int),
) -> Result(#(Int, Int), String)

/// Drain an instance's host console output buffer (P7-08 §E/§H.2) — routes into the
/// instance's owned process and reads `rt_host:host_output/0` THERE (the buffer is
/// process-local). Returns the raw byte stream (`<<>>` if the program never printed).
@external(erlang, "carder_cli_ffi", "host_output")
fn ffi_host_output(proc: Pid) -> BitArray

/// Ask an instance's owned process to exit (cell GC'd with it).
@external(erlang, "carder_cli_ffi", "stop_instance")
fn ffi_stop_instance(proc: Pid) -> Nil

/// Ask an instance's owned process for memory 0's size in 64 KiB pages, read THERE (the
/// memory cell/record is process-local). `0` for a memory-less guest. Backs
/// `mem_size_instance`.
@external(erlang, "carder_cli_ffi", "mem_size")
fn ffi_mem_size(proc: Pid) -> Int

/// Read the module name baked into a `.beam` binary (so a prebuilt `.beam` can be loaded even
/// when its filename differs from its module name). `Ok(name)` / `Error(reason)`.
@external(erlang, "carder_cli_ffi", "module_name")
fn ffi_module_name(beam: BitArray) -> Result(String, String)

/// Invoke `function(args)` `repeat` times inside an instance's owned process, returning
/// `Ok(#(total_micros, last_value))` / `Error(reason)`. Times only the invocations.
@external(erlang, "carder_cli_ffi", "bench_instance")
fn ffi_bench_instance(
  proc: Pid,
  function: Atom,
  args: List(Int),
  repeat: Int,
) -> Result(#(Int, Int), String)

// ─────────────────────────────── composable stage drivers ───────────────────────────────

/// Run the IR→IR Safe policy pass (`ir_lower`, unit 11a) over `m` under `binding`.
///
/// - `m`: the IR module (e.g. from `parse_ir`, or handed in by a frontend package).
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
/// The optimizer sits BETWEEN `ir_lower` and `emit_core`: `parse_ir → ir_lower →
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
/// - `m`: the IR module to compile (e.g. from `parse_ir`, or handed in by a frontend package).
/// - `binding`: the build-time runtime binding (chokepoint module names + policy mode + the
///   optimizer level).
/// - Return: `Ok(#(lowered_optimized_module, cmod))`, or `Error(IrLowerFailed/EmitFailed)`.
///   The module's `.name` (the compiled atom, `carder@wasm@<base>`) is preserved by `lower_ir`/
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
/// `run`/`to-beam` and the test drivers compile through (`cmod_to_beam` /
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
pub fn ir_to_chunks(
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
/// - `chunks`: from `ir_to_chunks` (chunk 0 first).
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
/// callers that produce IR directly (e.g. arc's JS frontend, `arc/aot`) rather than going
/// through the `.wasm` → IR path.
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

/// Load `beam` and start the instance's owned process with the matching instantiate ABI (R4): a
/// module with NO positional imports keeps `instantiate/0` (`ffi_start_instance`); an
/// import-bearing one gets `instantiate/1(Imports)` (`ffi_start_instance_with`), where `Imports`
/// is the positional `Provided` vector.
///
/// PUBLIC because the `instantiate/0`-vs-`instantiate/1` choice must match `emit_core`'s emitted
/// arity byte-for-byte — a frontend that resolved its own `Provided` vector (e.g. scribbler
/// linking a Porffor guest's `""` intrinsics) must NOT re-implement this decision.
///
/// - `beam`: the compiled module. `mod`: the atom name baked into it.
/// - `provided`: the positional externval vector (`[]` ⇒ the `instantiate/0` path).
/// - Returns `Ok(InstanceProc)` once seeded, or `Error(reason)` for a load failure /
///   instantiation-time trap. Total.
pub fn instantiate_with_provided(
  beam: BitArray,
  mod: String,
  provided: List(link.Provided),
) -> Result(InstanceProc, String) {
  case build_beam.load_module(atom.create(mod), "carder_cli", beam) {
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

// ─────────────────────────── the IR-entry run drivers (the frontend seam) ───────────────────────────

/// End-to-end from an **IR module**: compile → load → instantiate → invoke → stop, through the
/// run-ABI's `load → instantiate → invoke` with one-instance-one-process isolation (E5). This is
/// the single call a frontend makes to *run* what it lowered — carder's half of `wasm → BEAM`,
/// `js → BEAM`, or any other frontend's end-to-end path.
///
/// **Posture-agnostic:** `binding` carries the chosen `state_strategy` and tiers UNCHANGED
/// through every stage. `emit_core` links the tier via `binding.mem_module` and picks the state
/// seam via `binding.state_strategy`; the run-ABI self-detects the strategy from `instantiate/0`'s
/// return. So a `Threaded`/`atomics` binding runs the SAME driver code as `Cell`/`paged` and
/// returns byte-identical results (G7) — the difference is confined to the loaded `.beam`. The
/// caller is expected to pass a binding already validated through `profiles.link/1` (`carder/cli`'s
/// `resolve_binding` does so); a tier/strategy incoherence is a linker rejection surfaced there,
/// not a `PipelineError` here.
///
/// - `m`: the IR module to compile and run; `m.name` is the atom the `.beam` loads under.
/// - `binding`: the build-time runtime binding.
/// - `export`: the exported function name to invoke.
/// - `args`: raw unsigned bit-pattern integer arguments (D5).
/// - Return: `Ok(Returned(_))` on a normal return; `Ok(Trapped(_))`/`Ok(UncaughtException(_,_))`
///   for an INSTANTIATION-time or RUNTIME trap/throw — both are runtime outcomes, classified
///   identically by `classify_run_error` (T8); or the first compile-stage `Error(PipelineError)`.
///   The instance is always stopped before returning. Total — never panics.
pub fn run_ir(
  m: ir.Module,
  binding: Binding,
  export: String,
  args: List(Int),
) -> Result(RunResult, PipelineError) {
  case compile_ir(m, binding) {
    Error(e) -> Error(e)
    Ok(beam) ->
      case instantiate(beam, m.name) {
        // An instantiation-time trap / uncaught throw (e.g. a throwing `start`) is a runtime
        // outcome, not a compile error — split exn vs trap identically (T8).
        Error(reason) -> Ok(classify_run_error(reason))
        Ok(proc) -> {
          let result = invoke_instance(proc, export, args)
          stop_instance(proc)
          Ok(result)
        }
      }
  }
}

/// Like `run_ir`, but compiles the module as N balanced CHUNKS (see `ir_to_chunks`), loads every
/// chunk beam, then instantiates + invokes the entry (chunk 0). Proves chunked compilation is
/// behaviour-identical to the whole-module path (a chunked guest must return byte-identical
/// results / traps), and it is the shape the memory-bounded server path uses.
///
/// - `m`/`binding`/`export`/`args`: as `run_ir`. `target`/`min_split_defs`: chunk controls (a
///   small `min_split_defs` forces a split even on a small module, for testing).
/// - Return: identical to `run_ir`. The helper chunks are inter-module `call` targets of the
///   entry, so they are loaded FIRST; a helper that fails to load surfaces as an instantiation
///   error. Total — never panics.
pub fn run_ir_chunked(
  m: ir.Module,
  binding: Binding,
  export: String,
  args: List(Int),
  target: Int,
  min_split_defs: Int,
) -> Result(RunResult, PipelineError) {
  case ir_to_chunks(m, binding, target, min_split_defs) {
    Error(e) -> Error(e)
    Ok(chunks) ->
      case chunks_to_beams(chunks) {
        Error(e) -> Error(e)
        // Unreachable: `ir_to_chunks` always yields at least one chunk.
        Ok([]) ->
          Error(
            BuildFailed(
              build_beam.CompileFailed(["chunking produced no output modules"]),
            ),
          )
        Ok([#(name, beam), ..extras]) -> {
          // Load the helper chunks first so the entry's cross-chunk `call`s resolve.
          list.each(extras, fn(nb) {
            let _ =
              build_beam.load_module(atom.create(nb.0), "carder_cli", nb.1)
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

/// Invoke `export(args)` inside `proc` and return its **two-value** result package — the shape
/// `emit_core` emits for an export whose result arity is ≥ 2 (R17). `invoke_instance` returns a
/// single value and cannot express it.
///
/// A frontend needs this when its source language's calling convention returns a pair — e.g. a
/// Porffor-compiled JS entry returns `(f64, i32)`: the value and its type tag.
///
/// - `proc`: the live instance. `export`: the exported function name. `args`: raw bit patterns.
/// - Return: `Ok(#(first, second))` on a normal return, or `Error(rendered_reason)` if the call
///   raised (pass it through `classify_run_error` to split trap vs uncaught exception). Total.
pub fn invoke_instance_pair(
  proc: InstanceProc,
  export: String,
  args: List(Int),
) -> Result(#(Int, Int), String) {
  let InstanceProc(pid) = proc
  ffi_call_instance_pair(pid, atom.create(export), args)
}

/// Drain `proc`'s accumulated **host output** — the exact byte stream this instance's
/// `print`-style host handlers appended via `rt_host.append_output`, including any ANSI escapes
/// (in-band).
///
/// The buffer is process-local to the instance's owned process (E1), so this routes a call INTO
/// that process to collect it. **Order matters:** drain AFTER the invoke and BEFORE
/// `stop_instance`, so partial output written before a trap is still captured.
///
/// - `proc`: the live instance.
/// - Return: the captured bytes, or `<<>>` for an instance that never printed. Total.
pub fn host_output(proc: InstanceProc) -> BitArray {
  let InstanceProc(pid) = proc
  ffi_host_output(pid)
}
