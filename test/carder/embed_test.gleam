//// Tests for `carder/embed` — the embedder host-injection seam.
////
//// These assert the CONTRACT an embedder (e.g. `dance`) relies on, not incidental output:
//// (1) an embedder-supplied host function is invoked for a guest's `dance.poke` import, and
//// (2) that host function, running in the instance's process, can read the guest's linear memory
//// over the pointer/length the guest passed. Together these prove the `Dance.*` host APIs can be
//// delivered to a compiled guest.
////
//// `embed` is **IR-entry**: `compile_ir(module, on_progress)` takes an already-lowered
//// `carder/ir.Module`, because carder is a backend and knows no source language. So these read
//// the committed `.ir` corpus and parse it with `pipeline.parse_ir` — the `.ir` files are
//// byte-for-byte equivalent compiler input to the `.wasm` fixtures these originally used.

import carder/embed
import carder/ir
import carder/pipeline
import carder/runtime/link
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleeunit/should
import simplifile

/// The 35-program `.ir` corpus.
const corpus = "test/carder/ir/corpus"

/// Read a committed `.ir` file and parse it into the `ir.Module` `embed.compile_ir` consumes.
/// `let assert` is used throughout: a corrupt committed corpus file is a genuinely-impossible
/// state for these tests and should abort loudly rather than be silently skipped.
fn read_ir(name: String) -> ir.Module {
  let assert Ok(text) = simplifile.read(corpus <> "/" <> name)
  let assert Ok(m) = pipeline.parse_ir(text)
  m
}

/// Compile a corpus `.ir` under the embedder's Safe IR-entry path, with progress suppressed.
fn compile(name: String) -> embed.Compiled {
  let assert Ok(compiled) = embed.compile_ir(read_ir(name), embed.no_progress)
  compiled
}

/// A host dispatcher that provides nothing — for guests with no imports.
fn no_host(_capability: String, _name: String, _args: List(Int)) -> List(Int) {
  []
}

/// Coerce one raw WASM argument from a `Provided` function closure's `List(Dynamic)` to an `Int`
/// (the D5 raw bit-pattern convention). `let assert`: an i32 import argument is always an integer.
fn dyn_int(d: Dynamic) -> Int {
  let assert Ok(n) = decode.run(d, decode.int)
  n
}

/// An embedder host function is called for a guest import AND can marshal over the guest's
/// linear memory. The `poke` fixture writes "ABC" to memory then calls `dance.poke(0, 3)`; the
/// host closure reads those 3 bytes back and forwards them to the test process.
pub fn host_import_reads_guest_memory_test() {
  let compiled = compile("poke.ir")

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

/// `instantiate_with_providers` — the general host-namespace seam. A caller-supplied
/// `link.Namespace` provider OWNS the whole `dance` namespace and therefore takes precedence over
/// the numeric `host` dispatcher for `dance.poke`: the provider's term-native closure runs (and,
/// like `host`, runs in the instance's process, so it too can read guest linear memory), while the
/// `host` dispatcher — which here would send a distinguishable marker — is never consulted.
///
/// This is the contract a frontend relies on to describe a producer-toolchain namespace (TeaVM's
/// `teavmJso`, the spec suite's `spectest`) that carder itself knows nothing about.
pub fn provider_namespace_takes_precedence_over_host_test() {
  let compiled = compile("poke.ir")

  let captured = process.new_subject()
  // The provider answers `dance.*` term-natively, accepting the DECLARED signature (so the
  // fail-closed `link_func_imports` signature match succeeds by construction).
  let provider =
    link.Namespace(
      link_name: "dance",
      func: fn(name, ty) {
        case name {
          "poke" ->
            Ok(
              link.provided_func(ty, fn(args) {
                let assert [ptr, len] = list.map(args, dyn_int)
                let assert Ok(bytes) = embed.mem_read(ptr, len)
                process.send(captured, #("provider", bytes))
                []
              }),
            )
          _ -> Error(Nil)
        }
      },
      state: fn(_name) { Error(Nil) },
    )

  // A `host` that would report itself distinguishably if it were (wrongly) consulted.
  let host = fn(_capability, _name, _args) {
    process.send(captured, #("host", <<>>))
    []
  }

  let assert Ok(instance) =
    embed.instantiate_with_providers(compiled, host, [provider])
  embed.invoke(instance, "run", []) |> should.equal(Ok([3]))
  // The PROVIDER's closure ran — not the numeric host dispatcher — and read guest memory.
  process.receive(captured, 1000)
  |> should.equal(Ok(#("provider", <<65, 66, 67>>)))
  embed.stop(instance)
}

/// `instantiate_with_providers(compiled, host, [])` reproduces `instantiate` exactly (the
/// documented "`[]` reproduces `instantiate`" clause): with no provider owning `dance`, the import
/// falls back to the numeric `host` dispatcher.
pub fn empty_providers_fall_back_to_host_test() {
  let compiled = compile("poke.ir")

  let captured = process.new_subject()
  let host = fn(_capability, _name, args: List(Int)) -> List(Int) {
    let assert [ptr, len] = args
    let assert Ok(bytes) = embed.mem_read(ptr, len)
    process.send(captured, bytes)
    []
  }

  let assert Ok(instance) = embed.instantiate_with_providers(compiled, host, [])
  embed.invoke(instance, "run", []) |> should.equal(Ok([3]))
  process.receive(captured, 1000) |> should.equal(Ok(<<65, 66, 67>>))
  embed.stop(instance)
}

/// The host dispatcher can WRITE the guest's linear memory too, and the guest observes the
/// mutation: the host overwrites the "ABC" the guest just wrote, then reads it back — proving
/// `mem_write` lands in the instance's own memory cell (the marshalling direction an embedder
/// needs to return a buffer to the guest).
pub fn host_import_writes_guest_memory_test() {
  let compiled = compile("poke.ir")

  let captured = process.new_subject()
  let host = fn(_capability, _name, args: List(Int)) -> List(Int) {
    let assert [ptr, len] = args
    let assert Ok(Nil) = embed.mem_write(ptr, <<88, 89, 90>>)
    let assert Ok(bytes) = embed.mem_read(ptr, len)
    process.send(captured, bytes)
    []
  }

  let assert Ok(instance) = embed.instantiate(compiled, host)
  embed.invoke(instance, "run", []) |> should.equal(Ok([3]))
  process.receive(captured, 1000) |> should.equal(Ok(<<88, 89, 90>>))
  embed.stop(instance)
}

/// An out-of-bounds `mem_read` from a host dispatcher is a bounds-checked `Error(Nil)`, never a
/// node crash — the guard an embedder relies on when the guest hands it a bad pointer.
pub fn host_mem_read_out_of_bounds_is_error_test() {
  let compiled = compile("poke.ir")

  let captured = process.new_subject()
  let host = fn(_capability, _name, _args: List(Int)) -> List(Int) {
    // One page is 65536 bytes; reading past the end must fail closed.
    process.send(captured, embed.mem_read(65_530, 16))
    []
  }

  let assert Ok(instance) = embed.instantiate(compiled, host)
  embed.invoke(instance, "run", []) |> should.equal(Ok([3]))
  process.receive(captured, 1000) |> should.equal(Ok(Error(Nil)))
  embed.stop(instance)
}

/// `mem_size` reports the guest's real linear-memory footprint in BYTES, and `guest_pid`
/// names the live owning process. The `poke` fixture declares one 64 KiB page (`memory (min 1)`)
/// so `mem_size` is exactly 65536, and its owning process is alive until `stop`.
/// This is the contract the `dance` metrics path relies on to attribute a guest instance's
/// footprint instead of reporting 0.
pub fn mem_size_reports_guest_linear_memory_test() {
  let compiled = compile("poke.ir")
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
  let compiled = compile("add.ir")
  let assert Ok(instance) = embed.instantiate(compiled, no_host)
  embed.mem_size(instance) |> should.equal(0)
  embed.stop(instance)
}

/// A guest with NO imports compiles, instantiates, and invokes through the embed API — the
/// non-import path stays intact (regression). Uses the canonical `add` corpus module.
pub fn no_import_guest_invokes_test() {
  let compiled = compile("add.ir")
  let assert Ok(instance) = embed.instantiate(compiled, no_host)
  embed.invoke(instance, "add", [3, 5]) |> should.equal(Ok([8]))
  embed.stop(instance)
}

/// Compile-once caching: a `Compiled` serializes to an artifact blob and reloads
/// into a working instance WITHOUT recompiling (no access to the original source).
/// This is the deploy-time-compile / boot-from-cache contract an embedder relies on.
pub fn artifact_round_trip_reinstantiates_test() {
  let compiled = compile("add.ir")

  // Serialize (deploy time) and reload (boot time) — no recompile.
  let blob = embed.to_artifact(compiled)
  let assert Ok(reloaded) = embed.from_artifact(blob)

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
@external(erlang, "carder_embed_compat_ffi", "legacy_artifact")
fn legacy_artifact(beam: BitArray, module: ir.Module) -> BitArray

/// Back-compat: a durable artifact cached by a PRE-chunking compiler must still load + boot after a
/// compiler upgrade. `from_artifact` upgrades the legacy 3-field shape to the current 4-field record
/// (no helper chunks), and the reloaded guest instantiates + runs unchanged.
pub fn legacy_artifact_upgrades_and_instantiates_test() {
  let compiled = compile("add.ir")

  let legacy = legacy_artifact(compiled.beam, compiled.module)
  let assert Ok(upgraded) = embed.from_artifact(legacy)

  let assert Ok(instance) = embed.instantiate(upgraded, no_host)
  embed.invoke(instance, "add", [3, 5]) |> should.equal(Ok([8]))
  embed.stop(instance)
}

/// `compile_ir`'s progress callback is invoked as each phase is ENTERED, with the documented
/// coarse checkpoints — `20`/"generating" then `45`/"compiling" — in that order. An embedder's
/// deploy UI renders these, so the sequence is part of the contract (not just that it compiles).
pub fn compile_ir_reports_progress_phases_test() {
  let seen = process.new_subject()
  let assert Ok(_) =
    embed.compile_ir(read_ir("add.ir"), fn(percent, phase) {
      process.send(seen, #(percent, phase))
      Nil
    })
  process.receive(seen, 1000) |> should.equal(Ok(#(20, "generating")))
  process.receive(seen, 1000) |> should.equal(Ok(#(45, "compiling")))
}
