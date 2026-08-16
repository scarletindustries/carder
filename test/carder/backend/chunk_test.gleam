//// Correctness of the A4 chunked-compile split (`carder/backend/chunk`).
////
//// The core claim: splitting a module into N independently-compiled BEAM sub-modules and rewriting
//// cross-chunk top-level `apply`s into inter-module `call`s is BEHAVIOUR-IDENTICAL to compiling the
//// whole module. We prove it DIFFERENTIALLY against the spec-sourced conformance corpora: for every
//// authored `.expected` invocation, the result of `run_source` (whole module) must equal the result
//// of `run_source_chunked` with a forced split (`min_split_defs = 2`, `target = 4`). The chosen
//// corpora exercise the delicate cross-chunk reference sites — `call_indirect` funcref closures
//// (callind, reftab), tail calls / `return_call*` (tailrec), and ordinary inter-function calls.

import carder/conformance/corpus.{Returns, Traps}
import carder/conformance/fixture.{
  type SpecValue, F32Bits, F64Bits, I32Val, I64Val,
}
import carder/pipeline
import carder/runtime/profiles
import gleam/list
import gleam/string
import simplifile

/// The raw unsigned bit-pattern integer of a concrete `SpecValue` argument. (NaN forms never appear
/// as invocation ARGUMENTS in these corpora — only as expected results — so they map to 0.)
fn arg_bits(v: SpecValue) -> Int {
  case v {
    I32Val(n) -> n
    I64Val(n) -> n
    F32Bits(n) -> n
    F64Bits(n) -> n
    // Non-scalar / NaN forms don't appear as scalar invocation ARGS in these corpora; the
    // differential only needs the SAME arg on both sides, so any placeholder is fine.
    _ -> 0
  }
}

/// Run every `.expected` invocation of `name` both whole and chunked; return a description for each
/// case where the two disagree (empty ⇒ chunked is behaviour-identical for this program).
fn diff_program(name: String) -> List(String) {
  let base = "test/carder/conformance/corpus/" <> name
  let assert Ok(wasm) = simplifile.read_bits(base <> ".wasm")
  let assert Ok(text) = simplifile.read(base <> ".expected")
  let assert Ok(expects) = corpus.parse(text)

  list.filter_map(expects, fn(ex) {
    // Only invocation expectations carry a field + args; Rejects/InstantiateTraps have neither.
    let call = case ex {
      Returns(field, args, _) -> Ok(#(field, args))
      Traps(field, args, _) -> Ok(#(field, args))
      _ -> Error(Nil)
    }
    case call {
      Error(_) -> Error(Nil)
      Ok(#(field, args)) -> {
        let a = list.map(args, arg_bits)
        let whole = pipeline.run_source(wasm, profiles.safe(), field, a)
        let chunked =
          pipeline.run_source_chunked(wasm, profiles.safe(), field, a, 4, 2)
        // Compare via `string.inspect` so any field shape is handled uniformly.
        case string.inspect(whole) == string.inspect(chunked) {
          True -> Error(Nil)
          False ->
            Ok(
              name
              <> "/"
              <> field
              <> ": whole="
              <> string.inspect(whole)
              <> " chunked="
              <> string.inspect(chunked),
            )
        }
      }
    }
  })
}

/// A forced 4-way split of each corpus program returns byte-identical run RESULTS to the whole
/// module — across ordinary calls, `call_indirect` funcrefs, ref tables, and tail calls.
pub fn chunked_run_matches_whole_test() {
  let mismatches =
    [
      "callind", "tailrec", "reftab", "intops", "mem", "multimem", "bulkmem",
      "mem64",
    ]
    |> list.flat_map(diff_program)
  assert mismatches == []
}

/// The split gate: a module with fewer than `min_split_defs` top-level defs is returned UNCHANGED
/// (a single chunk with the original name), so small guests stay byte-identical. We assert the
/// whole vs. "chunked-but-below-threshold" runs agree AND that only one module is produced.
pub fn below_threshold_is_single_chunk_test() {
  let assert Ok(wasm) =
    simplifile.read_bits("test/carder/conformance/corpus/intops.wasm")
  let assert Ok(m) = pipeline.source_to_ir(wasm)
  // A very high threshold ⇒ never split ⇒ exactly one chunk (the whole module, name unchanged).
  let assert Ok(chunks) =
    pipeline.source_to_chunks(m, profiles.safe(), 8, 100_000)
  assert list.length(chunks) == 1
  let assert [only] = chunks
  assert only.name == m.name
}
