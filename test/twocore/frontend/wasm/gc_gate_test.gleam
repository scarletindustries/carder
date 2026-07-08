//// Gating test for the WasmGC runtime: the `rt_gc` arena seam is emitted **only**
//// when a module actually uses a GC instruction. Because the whole-program linker
//// discovers its closure by reachability, a seam that is never called is never
//// bundled — so this checks the emitted Core Erlang directly: a GC module's Core
//// references `twocore@runtime@rt_gc`, a plain core-WASM module's does not. Also
//// confirms the Safe profile admits a GC module (the arena is not policy-gated).

import gleam/string
import gleeunit/should
import simplifile
import twocore/pipeline
import twocore/runtime/profiles

fn core_of(path: String) -> String {
  let assert Ok(wasm) = simplifile.read_bits(path)
  let assert Ok(m) = pipeline.source_to_ir(wasm)
  let assert Ok(core) = pipeline.ir_to_core(m, profiles.safe())
  core
}

/// A GC module's generated Core calls the `rt_gc` seam — so the linker will bundle
/// the arena runtime for it. (Also proves Safe admits GC: `ir_to_core` returns Ok.)
pub fn gc_module_references_rt_gc_test() {
  core_of("test/twocore/frontend/wasm/gc_fixtures/gcrun.wasm")
  |> string.contains("rt_gc")
  |> should.be_true
}

/// A plain core-WASM module (`add`) never mentions the `rt_gc` seam, so the linker
/// drops the arena runtime entirely — the opt-in requirement.
pub fn plain_module_omits_rt_gc_test() {
  core_of("test/twocore/conformance/corpus/add.wasm")
  |> string.contains("rt_gc")
  |> should.be_false
}
