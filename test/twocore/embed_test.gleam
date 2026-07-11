//// Tests for `twocore/embed` — the embedder host-injection seam.
////
//// These assert the CONTRACT an embedder (e.g. `dance`) relies on, not incidental output:
//// (1) an embedder-supplied host function is invoked for a guest's `(import "dance" "poke"
//// (func …))` call, and (2) that host function, running in the instance's process, can read the
//// guest's linear memory over the pointer/length the guest passed. Together these prove the
//// `Dance.*` host APIs can be delivered to a compiled WASM guest.

import gleam/erlang/process
import gleeunit/should
import simplifile
import twocore/embed
import twocore/ir

/// An embedder host function is called for a guest import AND can marshal over the guest's
/// linear memory. The `poke` fixture writes "ABC" to memory then calls `dance.poke(0, 3)`; the
/// host closure reads those 3 bytes back and forwards them to the test process.
pub fn host_import_reads_guest_memory_test() {
  let assert Ok(wasm) = simplifile.read_bits("test/twocore/fixtures/poke.wasm")
  let assert Ok(compiled) = embed.compile(wasm)

  let captured = process.new_subject()
  let host = fn(capability: String, name: String, args: List(Int)) -> List(Int) {
    case capability, name, args {
      "dance", "poke", [ptr, len] -> {
        let assert Ok(bytes) = embed.mem_read(ptr, len)
        process.send(captured, bytes)
        []
      }
      _, _, _ -> []
    }
  }

  let assert Ok(instance) = embed.instantiate(compiled, host)
  // `run` writes the bytes, calls the host, and returns the byte count.
  embed.invoke(instance, "run", []) |> should.equal(Ok([3]))
  // The host closure ran in the instance's process and read its linear memory.
  process.receive(captured, 1000) |> should.equal(Ok(<<65, 66, 67>>))
  embed.stop(instance)
}

/// `mem_size` reports the guest's real linear-memory footprint in BYTES, and `guest_pid`
/// names the live owning process. The `poke` fixture declares `(memory 1)` — one 64 KiB
/// page — so `mem_size` is exactly 65536, and its owning process is alive until `stop`.
/// This is the contract the `dance` metrics path relies on to attribute a WASM instance's
/// footprint instead of reporting 0.
pub fn mem_size_reports_guest_linear_memory_test() {
  let assert Ok(wasm) = simplifile.read_bits("test/twocore/fixtures/poke.wasm")
  let assert Ok(compiled) = embed.compile(wasm)
  let no_host = fn(_capability, _name, _args) { [] }
  let assert Ok(instance) = embed.instantiate(compiled, no_host)

  // One declared page of linear memory → 64 KiB, read from inside the guest process.
  embed.mem_size(instance) |> should.equal(65_536)
  // The owning process is live while the instance is.
  embed.guest_pid(instance) |> process.is_alive |> should.be_true

  embed.stop(instance)
}

/// A guest that declares NO memory reports a `mem_size` of 0 (rather than crashing) — the
/// memory-less path the RPC guards. Uses the canonical `add` corpus module.
pub fn mem_size_zero_for_memoryless_guest_test() {
  let assert Ok(wasm) =
    simplifile.read_bits("test/twocore/conformance/corpus/add.wasm")
  let assert Ok(compiled) = embed.compile(wasm)
  let no_host = fn(_capability, _name, _args) { [] }
  let assert Ok(instance) = embed.instantiate(compiled, no_host)
  embed.mem_size(instance) |> should.equal(0)
  embed.stop(instance)
}

/// A guest with NO imports compiles, instantiates, and invokes through the embed API — the
/// non-import path stays intact (regression). Uses the canonical `add` corpus module.
pub fn no_import_guest_invokes_test() {
  let assert Ok(wasm) =
    simplifile.read_bits("test/twocore/conformance/corpus/add.wasm")
  let assert Ok(compiled) = embed.compile(wasm)
  let no_host = fn(_capability, _name, _args) { [] }
  let assert Ok(instance) = embed.instantiate(compiled, no_host)
  embed.invoke(instance, "add", [3, 5]) |> should.equal(Ok([8]))
  embed.stop(instance)
}

/// Compile-once caching: a `Compiled` serializes to an artifact blob and reloads
/// into a working instance WITHOUT recompiling (no access to the original
/// `.wasm`). This is the deploy-time-compile / boot-from-cache contract an
/// embedder relies on.
pub fn artifact_round_trip_reinstantiates_test() {
  let assert Ok(wasm) =
    simplifile.read_bits("test/twocore/conformance/corpus/add.wasm")
  let assert Ok(compiled) = embed.compile(wasm)

  // Serialize (deploy time) and reload (boot time) — no recompile.
  let blob = embed.to_artifact(compiled)
  let assert Ok(reloaded) = embed.from_artifact(blob)

  let no_host = fn(_capability, _name, _args) { [] }
  let assert Ok(instance) = embed.instantiate(reloaded, no_host)
  embed.invoke(instance, "add", [3, 5]) |> should.equal(Ok([8]))
  embed.stop(instance)
}

/// A malformed artifact blob fails closed, never crashes.
pub fn artifact_malformed_is_error_test() {
  embed.from_artifact(<<"not a real artifact">>)
  |> should.be_error
}

/// Fabricate the 3-field `{compiled, Beam, Module}` artifact an OLDER compiler produced (before the
/// `extra` helper-chunk field), bypassing `to_artifact`.
@external(erlang, "twocore_embed_compat_ffi", "legacy_artifact")
fn legacy_artifact(beam: BitArray, module: ir.Module) -> BitArray

/// Back-compat: a durable artifact cached by a PRE-chunking compiler must still load + boot after a
/// compiler upgrade. `from_artifact` upgrades the legacy 3-field shape to the current 4-field record
/// (no helper chunks), and the reloaded guest instantiates + runs unchanged.
pub fn legacy_artifact_upgrades_and_instantiates_test() {
  let assert Ok(wasm) =
    simplifile.read_bits("test/twocore/conformance/corpus/add.wasm")
  let assert Ok(compiled) = embed.compile(wasm)

  let legacy = legacy_artifact(compiled.beam, compiled.module)
  let assert Ok(upgraded) = embed.from_artifact(legacy)

  let no_host = fn(_capability, _name, _args) { [] }
  let assert Ok(instance) = embed.instantiate(upgraded, no_host)
  embed.invoke(instance, "add", [3, 5]) |> should.equal(Ok([8]))
  embed.stop(instance)
}
