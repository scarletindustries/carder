//// The `embed` API (what host platforms like Dance use) must run TeaVM WASM GC guests: it resolves
//// the reference-typed `teavm.*` runtime imports via `rt_teavm` (term-native) while the embedder's
//// numeric `host` dispatcher services the i32-only imports, and it exposes the guest's imported
//// linear memory through `mem_read`/`mem_write`. Two fixtures prove it:
////   - compute.wasm — object allocation + virtual dispatch (call_ref) → 46 (instantiation + teavm imports)
////   - memtest.wasm — org.teavm.interop.Address raw linear-memory r/w → 49 (the IMPORTED memory works)
//// A stub `host` (never called — neither fixture imports a non-teavm function) stands in for the embedder.

import gleam/io
import gleam/string
import twocore/conformance/ffi
import twocore/embed

fn run_embed(fixture: String, export: String) -> embed.InvokeResult {
  let assert Ok(bytes) = ffi.read_file("test/twocore/teavm/" <> fixture)
  let assert Ok(compiled) = embed.compile(bytes)
  // The embedder's host dispatcher; unused here (both fixtures import only teavm.* + memory).
  let host = fn(_capability, _name, _args) { [] }
  let assert Ok(instance) = embed.instantiate(compiled, host)
  embed.invoke(instance, export, [])
}

/// A TeaVM guest instantiates + runs through `embed` (object allocation + `call_ref` dispatch → 46).
pub fn embed_runs_teavm_compute_test() {
  let r = run_embed("compute.wasm", "compute")
  io.println("\n[embed] compute() = " <> string.inspect(r))
  assert r == Ok([46])
}

/// The IMPORTED linear memory works through `embed` — `Address` writes/reads bytes (42 + 7 = 49).
pub fn embed_teavm_imported_memory_test() {
  let r = run_embed("memtest.wasm", "memtest")
  io.println("\n[embed] memtest() = " <> string.inspect(r))
  assert r == Ok([49])
}

/// Full SDK-generated TeaVM guests compile through 2core. Both fixtures are the Dance Java SDK's
/// per-module WASM GC output (a `Counter` and a record-rich `Channel` service — sources in the SDK's
/// example). They exercise **GC constant expressions** beyond a single allocator instruction — in
/// particular `global.get` of a PRECEDING immutable DEFINED global feeding a `struct.new` in a
/// global initializer — which the function-references/GC proposal admits as constant and which
/// `wasm-tools validate` accepts. A guest smaller than these (the hand-written `echo`) never emitted
/// such an init, so this is the regression guard for that const-expr rule end to end.
pub fn embed_compiles_sdk_guests_test() {
  let assert Ok(counter) = ffi.read_file("test/twocore/teavm/counter_java.wasm")
  let assert Ok(_) = embed.compile(counter)
  let assert Ok(channel) = ffi.read_file("test/twocore/teavm/channel_java.wasm")
  let assert Ok(_) = embed.compile(channel)
}

/// The SDK guests also INSTANTIATE — which seeds their ~450 static GC globals. One global's init
/// reads a preceding immutable global to build a `struct.new`; that read is only valid once the
/// instance cell exists, so the seed must install such globals in declaration order AFTER the cell
/// (not while building the seed decl). Instantiation succeeding is the regression guard for that
/// ordered seeding (a stub host suffices — neither guest touches a `dance.*` import at start).
pub fn embed_instantiates_sdk_guests_test() {
  let host = fn(_capability, _name, _args) { [] }
  let assert Ok(counter) = ffi.read_file("test/twocore/teavm/counter_java.wasm")
  let assert Ok(counter_c) = embed.compile(counter)
  let assert Ok(_) = embed.instantiate(counter_c, host)
  let assert Ok(channel) = ffi.read_file("test/twocore/teavm/channel_java.wasm")
  let assert Ok(channel_c) = embed.compile(channel)
  let assert Ok(_) = embed.instantiate(channel_c, host)
}
