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
