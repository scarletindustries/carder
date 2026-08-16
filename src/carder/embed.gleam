//// `embed` — the embedder API for running a compiled guest inside a host BEAM program with
//// host functions supplied as native Gleam closures.
////
//// This is the "coexistence seam": a host such as the `dance` platform compiles a guest
//// module once, then runs many instances, each provided a `host` dispatcher that implements
//// the guest's imported functions.
////
//// **IR-entry.** `compile_ir` takes a `carder/ir.Module`, not source bytes — carder is a
//// backend and knows no source language. A frontend (scribbler for WebAssembly, arc for
//// JavaScript) lowers its source and wraps this with a source-shaped `compile` of its own. The dispatcher runs in the
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

import carder/backend/build_beam
import carder/ir
import carder/pipeline
import carder/runtime/link
import carder/runtime/profiles
import carder/runtime/rt_mem
import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/result

/// Target sub-module count when a guest is large enough to split (see `chunk.split_module`). Splitting
/// a big guest into this many independently-compiled BEAM modules bounds the `compile:forms` peak to
/// ~1/N of the whole-module cost, while keeping the loaded-module count modest.
const chunk_target = 8

/// Only split a guest with at least this many top-level Core functions. A smaller guest compiles as a
/// SINGLE module — byte-identical to the pre-chunking output — so the vast majority of guests are
/// untouched and only the large ones (which are the ones that OOM) pay the multi-module path.
const min_split_defs = 64

/// A compiled guest: the loadable `.beam` bytes of its ENTRY module, the IR module whose `imports`
/// order drives the function-import wiring at instantiate, and any HELPER chunk modules a large guest
/// was split into. Produced by `compile`, consumed by `instantiate`.
///
/// - `beam`: the entry module's `.beam` (loads under `module.name`) — the module `instantiate` runs.
/// - `module`: the guest's IR (import metadata + the entry atom `module.name`).
/// - `extra`: `#(module_atom, beam)` for each additional chunk a large guest was split into (empty
///   for a small guest compiled as one module). `instantiate` loads these alongside `beam` so the
///   entry's cross-chunk `call`s resolve; they are pure code with no state of their own.
pub type Compiled {
  Compiled(beam: BitArray, module: ir.Module, extra: List(#(String, BitArray)))
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

/// **Compile** an already-lowered IR module to a loadable `Compiled` under the `Safe` profile —
/// the embedder's IR-ENTRY seam.
///
/// carder is a backend: it does not know how `m` was produced. A FRONTEND (scribbler's
/// WebAssembly decoder, arc's JS emitter) lowers its source into `carder/ir` and calls this; the
/// frontend then re-exports a source-shaped `compile(bytes)` wrapper of its own.
///
/// A large guest is split into balanced CHUNKS and compiled SEQUENTIALLY, bounding peak
/// `compile:forms` memory to ~the largest chunk instead of the whole module; a guest under
/// `min_split_defs` top-level Core functions compiles as a SINGLE module, byte-identical to the
/// unchunked path.
///
/// - `m`: the IR module. `m.name` becomes the loaded BEAM module atom verbatim — the caller owns
///   uniqueness. Two guests compiled under the SAME atom cannot coexist on one node (the second
///   `code:load_binary` overwrites the first), so an embedder deploying several guests must give
///   each a distinct `m.name` (e.g. `"carder@wasm@" <> deployment <> "_" <> slug`).
/// - `on_progress(percent, phase)`: coarse build progress, invoked as each phase is ENTERED —
///   `20` → "generating" (IR → Core Erlang), `45` → "compiling" (Core Erlang → BEAM, the long
///   pole, ~half the wall time and with no internal sub-progress, so a bar dwells at `45`). The
///   callback runs IN the compiling process — keep it cheap and node-safe (a crash there fails
///   the compile). Pass `no_progress` if you do not want it.
/// - Returns `Ok(Compiled)` (entry beam + IR + helper chunks), or `Error(text)` describing the
///   failing backend stage (ir-lower / emit / build). Total.
pub fn compile_ir(
  m: ir.Module,
  on_progress: fn(Int, String) -> Nil,
) -> Result(Compiled, String) {
  on_progress(20, "generating")
  // Emit + split into N balanced chunks (a large guest), or a single chunk (a small one). The
  // chunks are compiled SEQUENTIALLY, bounding peak compile memory to ~the largest chunk.
  case pipeline.ir_to_chunks(m, profiles.safe(), chunk_target, min_split_defs) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(chunks) -> {
      on_progress(45, "compiling")
      case pipeline.chunks_to_beams(chunks) {
        Error(e) -> Error(pipeline.describe(e))
        // Chunk 0 (name == `m.name`) is the entry module; the rest are helper modules.
        Ok([#(_entry_name, primary), ..extra]) ->
          Ok(Compiled(beam: primary, module: m, extra: extra))
        Ok([]) -> Error("codegen produced no output modules")
      }
    }
  }
}

/// The no-op progress callback — for callers of `compile_ir` that do not want progress.
pub fn no_progress(_percent: Int, _phase: String) -> Nil {
  Nil
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
  instantiate_with_providers(compiled, host, [])
}

/// `instantiate` plus caller-supplied `link.Provider`s — for a guest whose imports are not all
/// expressible over the numeric `host` ABI.
///
/// The `host` dispatcher is numeric (`List(Int) -> List(Int)`, D5) and cannot carry a BEAM term,
/// so a guest importing REFERENCE-typed host functions (externref / funcref / GC refs — e.g. a
/// TeaVM WASM GC guest's `teavmJso` namespace) or importing host STATE (a global/table/memory it
/// does not define) supplies those through `providers` instead. A capability no provider owns
/// still falls back to `host`.
///
/// This is the seam that keeps carder free of any producer-toolchain knowledge: the frontend
/// that understands TeaVM (or Porffor, or the spec suite's `spectest`) describes those namespaces
/// as `Provider`s in its OWN repo and passes them here (D3a — a handed-in closure is a
/// capability, never ambient authority).
///
/// - `compiled`/`host`: as `instantiate`.
/// - `providers`: term-native externval sources; `[]` reproduces `instantiate` exactly.
/// - Returns `Ok(Instance)` once seeded, or `Error(reason)`. Total.
pub fn instantiate_with_providers(
  compiled: Compiled,
  host: fn(String, String, List(Int)) -> List(Int),
  providers: List(link.Provider),
) -> Result(Instance, String) {
  let Compiled(beam:, module:, extra:) = compiled
  // Load the helper chunk modules FIRST (pure code, no per-instance state) so the entry module's
  // cross-chunk `call`s resolve, then start the entry instance in its own process.
  case load_helpers(extra) {
    Error(reason) -> Error(reason)
    Ok(Nil) ->
      pipeline.instantiate_with_host_providers(beam, module, host, providers)
      |> result.map(Instance)
  }
}

/// Load each helper chunk module into the node. They share the flat BEAM module namespace, but each
/// was compiled with a distinct `<entry>_c<i>` atom (baked into its `.core` header and every
/// intra/inter-chunk reference), so a load never clobbers the entry or a sibling. Idempotent-safe
/// (re-loading the same atom replaces it with identical code). Returns `Error(reason)` on the first
/// load rejection — fail-closed, since a missing helper would crash the entry's cross-chunk `call`
/// at runtime. Total.
fn load_helpers(extra: List(#(String, BitArray))) -> Result(Nil, String) {
  list.try_fold(extra, Nil, fn(_acc, nb) {
    let #(name, beam) = nb
    case build_beam.load_module(atom.create(name), "carder_embed", beam) {
      Ok(_) -> Ok(Nil)
      Error(reason) ->
        Error("load helper chunk " <> name <> " failed: " <> reason)
    }
  })
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

/// The Pid of the instance's owning process — the process that holds its linear memory,
/// globals and tables (one-instance-one-process isolation). An embedder uses this to
/// attribute the guest's real resource usage EXTERNALLY via `erlang:process_info`
/// (reductions, process memory, mailbox) without messaging the guest — e.g. a periodic
/// telemetry snapshot that must not stall behind an in-flight invoke. Total.
///
/// The Pid is only meaningful while the instance is live; after `stop` (or a guest
/// crash) it names a dead process and `process_info` returns `undefined`.
pub fn guest_pid(instance: Instance) -> Pid {
  let Instance(proc:) = instance
  pipeline.instance_pid(proc)
}

/// The guest's current linear-memory (memory 0) footprint, in BYTES — `memory.size`
/// pages × 64 KiB — read inside the guest's own process so it reflects the true
/// allocation (the dominant footprint of a WASM interpreter guest, which a host-side
/// `process_info` under-counts because a Paged memory is an off-heap binary).
///
/// - Returns the byte size, or `0` for a guest that declares no memory.
/// - This RPCs the guest process, so it serialises behind any in-flight invoke; use it
///   for an on-demand probe (e.g. a dashboard "measure" request), NOT a hot loop. For a
///   non-blocking periodic snapshot use `guest_pid` + `process_info` instead. Total.
pub fn mem_size(instance: Instance) -> Int {
  let Instance(proc:) = instance
  pipeline.mem_size_instance(proc) * 65_536
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
/// `carder_embed_ffi`.
@external(erlang, "carder_embed_ffi", "from_binary")
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
///   blob is malformed / truncated / not a carder artifact. Total — never panics.
pub fn from_artifact(bytes: BitArray) -> Result(Compiled, String) {
  ffi_from_binary(bytes)
}
