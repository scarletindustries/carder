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

import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import twocore/backend/build_beam
import twocore/ir
import twocore/pipeline
import twocore/runtime/profiles
import twocore/runtime/rt_mem

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

/// **Compile** WASM guest bytes to a loadable module under the `Safe` profile.
///
/// - `wasm`: the guest's binary `.wasm` bytes.
/// - Returns `Ok(Compiled)` (beam + IR), or `Error(text)` describing the failing pipeline stage
///   (decode / validate / lower / codegen). Total.
///
/// The generated BEAM module atom is derived from the guest's first exported function
/// (`twocore@wasm@<firstexport>`). NOTE: two guests that share that first export name (e.g. any
/// two TeaVM/Java modules, which all export `teavm.stringToJs` first) compile to the SAME atom
/// and CANNOT be loaded into one node together — the second `code:load_binary` overwrites the
/// first. An embedder deploying MULTIPLE guests to one node (e.g. a Dance app with several WASM
/// modules) must give each a distinct atom via `compile_named`.
pub fn compile(wasm: BitArray) -> Result(Compiled, String) {
  compile_with_name(wasm, None, no_progress)
}

/// The no-op progress callback for `compile`/`compile_named` (callers that don't want progress).
fn no_progress(_percent: Int, _phase: String) -> Nil {
  Nil
}

/// **Compile** WASM guest bytes like `compile`, but OVERRIDE the generated BEAM module atom with
/// `name` verbatim (it becomes the `.core`/`.beam` module header AND every intra-module qualified
/// reference, so the override is fully self-consistent — indirect calls, funcref tables and the
/// `rt_table` seam all resolve against the same atom).
///
/// - `name`: the module atom to bake in. MUST be a valid Erlang atom string and UNIQUE across the
///   guests an embedder loads into one node (e.g. `"twocore@wasm@" <> deployment <> "_" <> slug`).
///   Passing a colliding name reintroduces the load-overwrite hazard `compile` warns about.
/// - Returns `Ok(Compiled)` whose `module.name` is `name`, or `Error(text)` (same failure modes as
///   `compile`; an atom-invalid `name` surfaces as a codegen `Error` from `cmod_to_beam`). Total.
pub fn compile_named(wasm: BitArray, name: String) -> Result(Compiled, String) {
  compile_with_name(wasm, Some(name), no_progress)
}

/// Like `compile_named`, but reports coarse build PROGRESS through `on_progress(percent, phase)` as
/// it enters each compiler phase — so an embedder (e.g. Dance) can drive a build progress bar.
///
/// - `percent` is the work COMPLETED before the phase begins: `0` → analyze (decode/validate/lower),
///   `20` → generate (IR → Core Erlang), `45` → compile (Core Erlang → BEAM). The last is the long
///   pole (~half the wall time) and has no internal sub-progress, so the bar dwells at `45` during
///   it; the embedder owns the tail (its own caching → `100`).
/// - `phase` is a short EMBEDDER-FACING label ("analyzing"/"generating"/"compiling"); compiler
///   internals stay internal.
/// - The callback runs IN the compiling process — keep it cheap and node-safe (a crash there fails
///   the compile). Returns exactly as `compile_named`.
pub fn compile_progress(
  wasm: BitArray,
  name: String,
  on_progress: fn(Int, String) -> Nil,
) -> Result(Compiled, String) {
  compile_with_name(wasm, Some(name), on_progress)
}

/// Shared compile path for `compile`/`compile_named`/`compile_progress`. When `name_override` is
/// `Some`, the IR module's `name` (set by `lower` to `twocore@wasm@<firstexport>`) is replaced
/// BEFORE `ir_to_core` so `emit_core` (which reads the emitted-module atom solely from
/// `ir.Module.name`, and every downstream stage after `lower` has no wasm to re-derive it from)
/// threads the override everywhere. `on_progress` is invoked as each phase is ENTERED.
fn compile_with_name(
  wasm: BitArray,
  name_override: Option(String),
  on_progress: fn(Int, String) -> Nil,
) -> Result(Compiled, String) {
  on_progress(0, "analyzing")
  case pipeline.source_to_ir(wasm) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(m0) -> {
      let m = case name_override {
        Some(name) -> ir.Module(..m0, name: name)
        None -> m0
      }
      on_progress(20, "generating")
      // Emit + split into N balanced chunks (a large guest), or a single chunk (a small one). The
      // chunks are compiled SEQUENTIALLY, bounding peak compile memory to ~the largest chunk.
      case
        pipeline.source_to_chunks(
          m,
          profiles.safe(),
          chunk_target,
          min_split_defs,
        )
      {
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
  let Compiled(beam:, module:, extra:) = compiled
  // Load the helper chunk modules FIRST (pure code, no per-instance state) so the entry module's
  // cross-chunk `call`s resolve, then start the entry instance in its own process.
  case load_helpers(extra) {
    Error(reason) -> Error(reason)
    Ok(Nil) ->
      pipeline.instantiate_with_host(beam, module, host)
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
    case build_beam.load_module(atom.create(name), "twocore_embed", beam) {
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
