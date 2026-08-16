//// The harness's **Driver seam** and result vocabulary — the boundary between a test and
//// the carder backend it drives.
////
//// ## THE ONE SURPRISING THING: what a `BitArray` MEANS here
////
//// This module was forked from the WebAssembly conformance harness, where the `Driver`'s
//// `BitArray` was a `.wasm` BINARY and `check_frontend` meant "decode + validate". carder no
//// longer has a WebAssembly frontend (it moved to the `scribbler` repo); carder is the BACKEND —
//// the shared IR, the middle-end, Core Erlang codegen and the BEAM runtime.
////
//// So the seam's SHAPE is unchanged and only the meaning of its bytes moved one layer down:
////
////   **a `BitArray` handed to a `Driver` is now UTF-8 `.ir` SOURCE TEXT, not a wasm binary.**
////
//// - `check_frontend(bytes)` = "does this `.ir` text parse?" — `pipeline.parse_ir` on the decoded
////   UTF-8, `Ok(Nil)` iff it parses, `Error("parse .ir: …")` otherwise. It is still the
////   *front* gate that never instantiates or runs anything; it is just that carder's front gate
////   is the `.ir` parser rather than a wasm decoder+validator.
//// - `instantiate(bytes)` / `instantiate_env(bytes, env)` = parse the `.ir` text, then the
////   UNCHANGED compile → link → start chain under the driver's `Binding`.
////
//// Every carder `.ir` corpus fixture is byte-for-byte the same artifact the old `.wasm` fixture
//// lowered to (it was measured that `wasm → .beam` and `wasm → .ir text → .beam` are identical),
//// so a test rebased from `read .wasm` onto `read .ir` proves exactly what it proved before.
////
//// ## What is NOT here any more
////
//// The `.wast`-script runner (`run_fixture` and its per-command judges), the WAT-text `Driver`
//// entries (`instantiate_ast`/`check_frontend_ast`) and everything that consumed a
//// `wast2json` `Fixture` left with the frontend. What remains is the seam plus the pieces
//// carder's own tests judge results with: `Instance`, `InvokeResult`, `ImportEnv`, `Driver`,
//// the `Report` tally, the cross-module `(register)` provider, and the spec trap-phrase
//// matcher `trap_matches`.

import carder/harness/ffi
import carder/harness/fixture.{type SpecValue}
import carder/ir
import carder/runtime/link
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/string

// ─────────────────────────────── the Driver seam ───────────────────────────────

/// A live instance ready to invoke: the OWNING PROCESS pid (one-instance-one-process,
/// E1) plus, per export name, the function's result value-types — used to tag a
/// returned raw integer back into a typed `SpecValue` for the oracle. The instance's
/// mutable state (memory/globals/table cell) lives in `proc`'s process dictionary, so
/// every invoke is routed INTO `proc` (via `ffi.call_instance`); cross-invoke state
/// persists, and a (re)instantiation spawns a fresh `proc` with a fresh zeroed cell.
pub type Instance {
  Instance(
    proc: Pid,
    exports: Dict(String, List(ir.ValType)),
    /// Per exported FUNCTION name → its full `FuncType` (params + results). Used to publish this
    /// instance's exported functions as cross-module `link.ProvidedFunc` capabilities on `(register)`
    /// (P6-10) — the signature drives fail-closed function-import matching (spec §3.2.7). Empty for a
    /// module with no function exports; a non-function export (global/table/memory) is absent.
    func_sigs: Dict(String, ir.FuncType),
  )
}

/// The outcome of invoking an export.
///
/// - `Returned(values)`: a normal return; `values` carry the raw result bits tagged at
///   the export's declared width.
/// - `Trapped(reason)`: a runtime trap / capability denial, `reason` the raw text
///   (e.g. `"{wasm_trap,int_div_by_zero}"`) — mapped to the spec message by `trap_matches`.
/// - `DriverError(text)`: a pipeline/invoke failure DISTINCT from a spec trap (e.g. an
///   unsupported multi-value result) — callers treat it as a skip, not a fail.
pub type InvokeResult {
  Returned(List(SpecValue))
  Trapped(reason: String)
  DriverError(String)
}

/// The import environment a module's imports resolve against (H4/§D.2): every provider the
/// caller has accumulated. Consumed by the driver → `link.link_imports` (which wires provided
/// global/table/memory state and FAILS CLOSED on an unsatisfied import).
///
/// carder hard-codes NO host module by name: a link name is satisfied only by a
/// `link.Registered` provider (a cross-module `(register)`, published by
/// `provider_from_instance`) or a `link.Namespace` provider the caller supplies. A link name
/// with NO provider is a GENERIC HOST CAPABILITY — not link-checked, gated instead at its call
/// site by the `HostPolicy` (fail-closed deny by default).
///
/// Depth honesty (§D.2): a cross-module *state* import (a later module importing a registered
/// module's table/memory) needs shared mutable state across two one-process instances, which the
/// E5 isolation model makes genuinely hard; `provider_from_instance` publishes FUNCTION exports
/// only, so such an import fails closed at link → its dependent asserts skip (a named category),
/// never a false green.
pub type ImportEnv {
  ImportEnv(providers: List(link.Provider))
}

/// The seam between a test and the carder backend.
///
/// **`BitArray` = UTF-8 `.ir` SOURCE TEXT** (see the module doc): carder's front gate is the
/// `.ir` parser, not a wasm decoder. `check_frontend` is parse-only (it never instantiates or
/// runs anything); `instantiate`/`instantiate_env` are the full parse → compile → link → start
/// pipeline; `invoke`/`get_global` run a loaded instance.
pub type Driver {
  Driver(
    /// Parse ONLY. `Ok(Nil)` = the `.ir` text parses; `Error(reason)` = it does not.
    check_frontend: fn(BitArray) -> Result(Nil, String),
    /// Full pipeline: `.ir` text → loaded `.beam` `Instance` (D10), with NO import providers
    /// (the historical no-import seam kept for external callers).
    instantiate: fn(BitArray) -> Result(Instance, String),
    /// Run an export with raw args; see `InvokeResult`.
    invoke: fn(Instance, String, List(SpecValue)) -> InvokeResult,
    /// Full pipeline with an import environment (H4): `.ir` text + `ImportEnv` → `Instance`.
    /// A link failure surfaces as `Error("link: <phrase>")` (the `assert_unlinkable` case).
    instantiate_env: fn(BitArray, ImportEnv) -> Result(Instance, String),
    /// Read an exported global (the `(get $m "field")` action). `Returned([v])` | error.
    get_global: fn(Instance, String) -> InvokeResult,
  )
}

// ─────────────────────────────── the report ───────────────────────────────

/// A pass/fail/skip tally plus the human-readable reasons for the fails and skips, so
/// honest coverage is visible (D9). `pass`+`fail`+`skip` count ASSERTIONS (plumbing
/// commands are not counted).
pub type Report {
  Report(
    pass: Int,
    fail: Int,
    skip: Int,
    fails: List(String),
    skips: List(String),
  )
}

/// An empty report (the fold seed): all three counters `0` and both reason lists empty.
pub fn empty_report() -> Report {
  Report(pass: 0, fail: 0, skip: 0, fails: [], skips: [])
}

/// Sum two reports (for aggregating across suites). Counters add; the `fails`/`skips`
/// reason lists are concatenated in `a`-then-`b` order. Associative with `empty_report()`
/// as the identity.
pub fn merge(a: Report, b: Report) -> Report {
  Report(
    pass: a.pass + b.pass,
    fail: a.fail + b.fail,
    skip: a.skip + b.skip,
    fails: list.append(a.fails, b.fails),
    skips: list.append(a.skips, b.skips),
  )
}

// ─────────────────────── cross-module `(register)` provider (P6-10 / S5) ───────────────────────

/// Publish `inst`'s exported FUNCTIONS as cross-module `link.ProvidedFunc` capabilities under the
/// link-name `name` (the `(register "name" $mod)` flip, S5/§C.2). A later module importing
/// `#(name, field)` resolves to the routing closure this builds, which dispatches the call INTO the
/// exporting instance's OWNING PROCESS (`inst.proc`) via the term run-ABI (so each `cell` instance's
/// pdict never collides) and returns the callee's result value list. The exported function's
/// `FuncType` drives fail-closed function-import matching (spec §3.2.7). Only FUNCTION exports are
/// published — cross-module MUTABLE state (global/table/memory) import is the categorized §D.2 depth
/// item, deliberately not provided (so such an import fails closed → a named skip, never a false
/// green). D3a: the closure is a HANDED-IN capability the linker matches by signature; generated code
/// never names the callee.
pub fn provider_from_instance(name: String, inst: Instance) -> link.Provider {
  let exports =
    dict.fold(inst.func_sigs, dict.new(), fn(acc, field, sig) {
      dict.insert(
        acc,
        field,
        link.provided_func(sig, routing_closure(inst.proc, field, sig)),
      )
    })
  link.Registered(name, exports)
}

/// The cross-module dispatch closure (`fn(List(Dynamic)) -> List(Dynamic)`, the S5 ABI): invoke
/// exported function `field` on the exporting instance's process with the raw-term argument list,
/// and return the callee's result value list (unpacked to `list.length(sig.results)` values). A
/// callee trap is PROPAGATED — `call_instance_terms` returns `Error(reason)`, which is re-raised so
/// the calling instance's invoke surfaces the trap (a cross-module trap is a trap).
fn routing_closure(
  proc: Pid,
  field: String,
  sig: ir.FuncType,
) -> fn(List(Dynamic)) -> List(Dynamic) {
  let n = list.length(sig.results)
  let f = atom.create(field)
  fn(args) {
    case ffi.call_instance_terms(proc, f, args) {
      Ok(package) -> ffi.result_list(n, package)
      Error(reason) -> ffi.raise_reason(reason)
    }
  }
}

// ─────────────────────────────── trap judging ───────────────────────────────

/// Decide whether our runtime trap `reason` text satisfies the spec's expected message
/// `want`. The spec message is a SUBSTRING like `"integer divide by zero"`; our runtime
/// raises `{wasm_trap, <kind>}` where `<kind>` is the snake_case `TrapReason` atom. We
/// map our kind to the canonical spec phrase (per `rt_trap.spec_trap_message`) and then
/// check containment in EITHER direction (so a shortened expectation still matches).
///
/// - `reason`: the raw raised text, e.g. `"{wasm_trap,int_div_by_zero}"`.
/// - `want`: the spec's expected message substring. `want == ""` accepts ANY trap.
/// - Returns `True` iff the trap satisfies the expectation. An unrecognised trap kind falls
///   back to raw substring containment (lenient, but never silently true). Total.
pub fn trap_matches(reason: String, want: String) -> Bool {
  case want {
    "" -> True
    _ ->
      case spec_phrase_of(reason) {
        Ok(phrase) ->
          string.contains(phrase, want) || string.contains(want, phrase)
        // Unknown trap kind: fall back to raw containment (lenient but still honest).
        Error(_) -> string.contains(reason, want)
      }
  }
}

/// Map our raised `{wasm_trap, <kind>}` text to the WASM-spec trap-message phrase, keyed by
/// the snake_case `TrapReason` atom present in `reason`. Mirrors `rt_trap.spec_trap_message`
/// (the single source of truth) so Phase-2 memory / table / conversion traps are judged
/// against their spec messages — not the underscore atom. The most-specific atoms are tested
/// FIRST so e.g. `undefined_element` is not shadowed by a substring match.
fn spec_phrase_of(reason: String) -> Result(String, Nil) {
  let kinds = [
    #("int_div_by_zero", "integer divide by zero"),
    #("invalid_conversion_to_integer", "invalid conversion to integer"),
    #("int_overflow", "integer overflow"),
    #("memory_out_of_bounds", "out of bounds memory access"),
    #("table_out_of_bounds", "out of bounds table access"),
    #("indirect_call_type_mismatch", "indirect call type mismatch"),
    #("uninitialized_element", "uninitialized element"),
    #("undefined_element", "undefined element"),
    // Phase-8 GC trap phrases. `array.new_data`/`new_elem` reuse the already-mapped
    // memory_/table_out_of_bounds atoms (a data/element-segment span over-run); the array-index
    // space is its own `array_out_of_bounds`. The null-dereference message is space-specific
    // (structure/array/i31), with the bare `null_reference` for `ref.as_non_null`. No atom here is
    // a substring of another (the specific null_* kinds do NOT contain the bare `null_reference`),
    // so first-match ordering is safe.
    #("array_out_of_bounds", "out of bounds array access"),
    #("null_structure_reference", "null structure reference"),
    #("null_array_reference", "null array reference"),
    #("null_i31_reference", "null i31 reference"),
    #("null_reference", "null reference"),
    #("cast_failure", "cast failure"),
    #("unreachable", "unreachable"),
  ]
  list.find_map(kinds, fn(kv) {
    let #(atom_text, phrase) = kv
    case string.contains(reason, atom_text) {
      True -> Ok(phrase)
      False -> Error(Nil)
    }
  })
}
