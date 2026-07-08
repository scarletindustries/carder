//// `embed` — the embedder API for running a WASM guest inside a host BEAM program with
//// host functions supplied as native Gleam closures.
////
//// This is the "coexistence seam": a host such as the `dance` platform compiles a guest
//// module once, then runs many instances, each provided a `host` dispatcher that implements
//// the guest's imported `(import "cap" "name" (func …))` functions. The dispatcher runs in the
//// instance's own process and may marshal arguments/results over the guest's linear memory via
//// `mem_read`/`mem_write`.
////
//// It is a thin, additive wrapper over `pipeline` + `link` + `rt_mem`: it introduces NO new
//// runtime authority. Host functions travel the existing D3a-clean `CallImport` path (a
//// first-class closure supplied by the trusted embedder, never a data-derived target), and the
//// guest is compiled under the `Safe` profile (fail-closed host policy, `Nif` tier forbidden,
//// enforcing fuel), so an embedder cannot accidentally widen the sandbox.
////
//// ## Contract for the `host` dispatcher
////
//// `host(capability, name, args) -> results`, where `args`/`results` are raw WASM bit patterns
//// (each an `Int`; `[]` for a `() ->` host function). The dispatcher MUST be total and
//// node-safe — a host handler that crashes the node is a sandbox hole (the embedder's
//// obligation, mirroring `rt_host.HostHandler`). It may call `mem_read`/`mem_write` on the
//// pointers it is passed; a bad guest pointer is a bounds-checked `Error`, never a node crash.

import gleam/int
import gleam/result
import twocore/ir
import twocore/pipeline
import twocore/runtime/profiles
import twocore/runtime/rt_mem

/// A compiled guest: its loadable `.beam` bytes plus the IR module whose `imports` order drives
/// the function-import wiring at instantiate. Produced by `compile`, consumed by `instantiate`.
pub type Compiled {
  Compiled(beam: BitArray, module: ir.Module)
}

/// A live guest instance — an opaque handle to its owning BEAM process (one-instance-one-process
/// isolation). Its linear memory / globals / tables are GC'd with the process when `stop`ped or
/// when the process dies.
pub opaque type Instance {
  Instance(proc: pipeline.InstanceProc)
}

/// The outcome of invoking a guest export: `Ok(values)` are the raw result bit patterns of a
/// normal return; `Error(reason)` is a WASM trap or a capability denial (the catchable BEAM
/// error rendered as text — the same channel `pipeline.RunResult.Trapped` carries).
pub type InvokeResult =
  Result(List(Int), String)

/// **Compile** WASM guest bytes to a loadable module under the `Safe` profile.
///
/// - `wasm`: the guest's binary `.wasm` bytes.
/// - Returns `Ok(Compiled)` (beam + IR), or `Error(text)` describing the failing pipeline stage
///   (decode / validate / lower / codegen). Total.
pub fn compile(wasm: BitArray) -> Result(Compiled, String) {
  case pipeline.source_to_ir(wasm) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(m) ->
      case pipeline.ir_to_core(m, profiles.safe()) {
        Error(e) -> Error(pipeline.describe(e))
        Ok(core) ->
          case pipeline.core_to_beam(core, m.name) {
            Error(e) -> Error(pipeline.describe(e))
            Ok(beam) -> Ok(Compiled(beam:, module: m))
          }
      }
  }
}

/// **Instantiate** a compiled guest in its own process, wiring every imported function to the
/// embedder `host` dispatcher (see the module doc for the dispatcher contract).
///
/// - `compiled`: from `compile`.
/// - `host`: the embedder's `(capability, name, args) -> results` dispatcher.
/// - Returns `Ok(Instance)` once seeded, or `Error(reason)` on an unsatisfied state import, a
///   load failure, or an instantiation-time trap. Total.
pub fn instantiate(
  compiled: Compiled,
  host: fn(String, String, List(Int)) -> List(Int),
) -> Result(Instance, String) {
  let Compiled(beam:, module:) = compiled
  pipeline.instantiate_with_host(beam, module, host)
  |> result.map(Instance)
}

/// **Invoke** an exported function on a live instance, routed into its owning process (so it
/// reads that instance's state, and cross-invoke mutation persists).
///
/// - `instance`: a live `Instance`.
/// - `export`: the exported function name.
/// - `args`: raw WASM argument bit patterns.
/// - Returns `Ok(result_values)` on a normal return, or `Error(reason)` on a trap / capability
///   denial. Total — never panics.
pub fn invoke(
  instance: Instance,
  export: String,
  args: List(Int),
) -> InvokeResult {
  let Instance(proc:) = instance
  case pipeline.invoke_instance(proc, export, args) {
    pipeline.Returned(values) -> Ok(values)
    pipeline.Trapped(reason) -> Error(reason)
    // A guest `throw` that escaped the export surfaces as an uncaught exception; the embedder
    // sees it as an error outcome carrying the thrown tag id.
    pipeline.UncaughtException(tag_id:, payload: _) ->
      Error("uncaught_exception:tag=" <> int.to_string(tag_id))
  }
}

/// Stop a live instance, ending its owning process (its memory/state is GC'd). Total.
pub fn stop(instance: Instance) -> Nil {
  let Instance(proc:) = instance
  pipeline.stop_instance(proc)
}

/// Read `len` bytes at `ptr` from the CURRENT instance's linear memory (memory 0). Call ONLY
/// from inside a `host` dispatcher (it reads the calling process's memory cell).
///
/// - Returns `Ok(bytes)`, or `Error(Nil)` if `[ptr, ptr+len)` is out of bounds (bounds-checked;
///   never a node crash). Total.
pub fn mem_read(ptr: Int, len: Int) -> Result(BitArray, Nil) {
  rt_mem.load_bytes(ptr, 0, len)
  |> result.replace_error(Nil)
}

/// Write `bytes` at `ptr` into the CURRENT instance's linear memory (memory 0). Call ONLY from
/// inside a `host` dispatcher.
///
/// - Returns `Ok(Nil)` on success, or `Error(Nil)` if `[ptr, ptr+len)` is out of bounds
///   (bounds-checked trap-before-write; zero mutation on failure; never a node crash). Total.
pub fn mem_write(ptr: Int, bytes: BitArray) -> Result(Nil, Nil) {
  rt_mem.store_bytes(ptr, bytes, 0)
  |> result.replace_error(Nil)
}

// ── Compile-once artifact caching ──────────────────────────────────────────
//
// `compile` is the expensive stage (`wasm → IR → Core Erlang → .beam`) and can
// take a long time for a large guest. An embedder should run it ONCE — at deploy
// time — and cache the result, then `instantiate` cheaply per instance. These
// two functions turn a `Compiled` into an opaque blob and back, so the cache can
// live in object storage (S3, disk, …). The blob carries the loadable `.beam`
// AND the import metadata `instantiate` needs, so a reloaded artifact needs no
// recompilation and no access to the original `.wasm`.

/// `erlang:term_to_binary/1` — serialize any term to its external binary form.
@external(erlang, "erlang", "term_to_binary")
fn term_to_binary(term: a) -> BitArray

/// Catching `erlang:binary_to_term/2` (`[safe]`) — `Ok(Compiled)` for a valid
/// artifact, `Error(message)` for a malformed / foreign blob. See
/// `twocore_embed_ffi`.
@external(erlang, "twocore_embed_ffi", "from_binary")
fn ffi_from_binary(bytes: BitArray) -> Result(Compiled, String)

/// Serialize a compiled guest to a single cacheable blob.
///
/// Store this (keyed by e.g. deployment + module) so a guest is compiled ONCE
/// and reloaded cheaply. The blob carries the loadable `.beam` plus the module
/// metadata `instantiate` needs — reloading it requires neither recompilation
/// nor the original `.wasm`. Total.
pub fn to_artifact(compiled: Compiled) -> BitArray {
  term_to_binary(compiled)
}

/// Reload a compiled guest from a blob produced by `to_artifact`.
///
/// - Returns `Ok(Compiled)` ready for `instantiate`, or `Error(reason)` if the
///   blob is malformed / truncated / not a 2core artifact. Total — never panics.
pub fn from_artifact(bytes: BitArray) -> Result(Compiled, String) {
  ffi_from_binary(bytes)
}
