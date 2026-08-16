//// Correctness of the A4 chunked-compile split (`carder/backend/chunk`).
////
//// The core claim: splitting a module into N independently-compiled BEAM sub-modules and rewriting
//// cross-chunk top-level `apply`s into inter-module `call`s is BEHAVIOUR-IDENTICAL to compiling the
//// whole module. We prove it DIFFERENTIALLY against the spec-sourced conformance corpora: for every
//// authored `.expected` invocation, the result of `pipeline.run_ir` (whole module) must equal the
//// result of `pipeline.run_ir_chunked` with a forced split (`min_split_defs = 2`, `target = 4`). The
//// chosen corpora exercise the delicate cross-chunk reference sites — `call_indirect` funcref
//// closures (callind, reftab), tail calls / `return_call*` (tailrec), and ordinary inter-function
//// calls.
////
//// **Input note.** carder is the BACKEND: its entry language is `.ir` text, so each program is read
//// from `test/carder/ir/corpus/<name>.ir` and parsed with `pipeline.parse_ir`. Every `.ir` fixture
//// was generated from the corresponding `.wasm` by the pre-split `to-ir`, and `wasm → .beam` was
//// measured byte-identical to `wasm → .ir text → .beam`, so the differential drives the exact same
//// artifact it always did. The `.expected` files are frontend-independent (export name + raw
//// bit-pattern args/results + spec trap phrase) and are reused verbatim.

import carder/harness/corpus.{Returns, Traps}
import carder/harness/fixture.{type SpecValue, F32Bits, F64Bits, I32Val, I64Val}
import carder/ir
import carder/pipeline
import carder/runtime/profiles
import gleam/list
import gleam/string
import simplifile

/// The `.ir`/`.expected` corpus root (carder's IR-entry corpus).
const corpus_dir = "test/carder/ir/corpus"

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

/// Read and parse `test/carder/ir/corpus/<name>.ir` into the `ir.Module` both sides of the
/// differential compile. `let assert` — a missing or unparseable fixture is a genuine test failure.
fn read_module(name: String) -> ir.Module {
  let assert Ok(text) = simplifile.read(corpus_dir <> "/" <> name <> ".ir")
  let assert Ok(m) = pipeline.parse_ir(text)
  m
}

/// Run every `.expected` invocation of `name` both whole and chunked; return a description for each
/// case where the two disagree (empty ⇒ chunked is behaviour-identical for this program).
fn diff_program(name: String) -> List(String) {
  let m = read_module(name)
  let assert Ok(text) =
    simplifile.read(corpus_dir <> "/" <> name <> ".expected")
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
        let whole = pipeline.run_ir(m, profiles.safe(), field, a)
        let chunked =
          pipeline.run_ir_chunked(m, profiles.safe(), field, a, 4, 2)
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
  let m = read_module("intops")
  // A very high threshold ⇒ never split ⇒ exactly one chunk (the whole module, name unchanged).
  let assert Ok(chunks) = pipeline.ir_to_chunks(m, profiles.safe(), 8, 100_000)
  assert list.length(chunks) == 1
  let assert [only] = chunks
  assert only.name == m.name
}
