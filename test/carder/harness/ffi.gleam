//// Thin Gleam bindings over the test FFI (`test/carder_harness_ffi.erl`).
////
//// These are the only host capabilities the harness needs that Gleam's stdlib does not
//// provide: invoke-with-trap-catch, running one instance in its OWN process over the
//// run-ABI, file IO for the `.ir` corpus, and probing a process's live memory. Keeping
//// every `@external` here means the rest of the harness is plain Gleam. All bindings
//// are total — every failure mode is a typed `Result`.
////
//// NOTE (the frontend split): the wast2json/Tier-B bindings (`parse_json`, `list_dir`,
//// `find_executable`, `run`) and the frontend-routing spy (`spy_reset`/`spy_mark`/
//// `spy_called`) went to scribbler with the WebAssembly conformance suite. carder has no
//// `.wast` fixtures and no reference-engine tier, so nothing here shells out or parses
//// JSON any more.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}

/// Apply `module:function(args)` on the freshly-loaded generated BEAM module and
/// capture the outcome. `Ok(raw)` is a normal return whose `raw` is the function's
/// result rendered as an integer (the raw value / IEEE-754 bit pattern, per D5);
/// `Error(text)` is any trap / exit / throw with its reason rendered as text so the
/// caller can substring-match (e.g. `"int_div_by_zero"`). Never crashes the runner.
@external(erlang, "carder_harness_ffi", "catch_apply")
pub fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

/// Read a file's raw bytes. `Ok(bytes)` or `Error(reason)` (POSIX reason as text).
@external(erlang, "carder_harness_ffi", "read_file")
pub fn read_file(path: String) -> Result(BitArray, String)

/// A strictly-positive unique integer, used to make each generated module's name
/// unique so multi-module fixtures don't clobber one another on load.
@external(erlang, "carder_harness_ffi", "unique_int")
pub fn unique_int() -> Int

/// Start an OWNED process for a generated instance and run its `instantiate/0` IN
/// that process (one-instance-one-process, E1). `module` is the loaded BEAM module
/// atom. `Ok(pid)` means instantiation succeeded and the process is holding the
/// seeded cell, ready for `call_instance`; `Error(reason)` is an instantiation-time
/// trap (OOB active segment / trapping start), the reason rendered as text. The
/// cell is private to this process, so a (re)instantiation always starts fresh.
@external(erlang, "carder_harness_ffi", "start_instance")
pub fn start_instance(module: Atom) -> Result(Pid, String)

/// Invoke export `function` with raw integer `args` INSIDE the instance's owned
/// process (so it reads that instance's cell). `Ok(raw)` is a normal single result
/// (raw value / IEEE-754 bit pattern, D5); `Error(reason)` is a trap rendered as
/// text. Cross-invoke state persists because successive calls hit the same process.
@external(erlang, "carder_harness_ffi", "call_instance")
pub fn call_instance(
  proc: Pid,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

/// Start an OWNED process for an IMPORT-BEARING instance and run its `instantiate/1(Imports)`
/// IN it (unit P5-11 / R4). `imports` is the positional `[Provided ...]` list `link.link_imports`
/// returned, handed over opaquely (Gleam cannot see the `Provided` list once it becomes the
/// generated ABI's single argument). Semantics otherwise identical to `start_instance` (cell /
/// threaded self-detected from `instantiate/1`'s return). `Ok(pid)` on success; `Error(reason)`
/// on an instantiation-time trap (OOB active segment / trapping start).
@external(erlang, "carder_harness_ffi", "start_instance_with")
pub fn start_instance_with(
  module: Atom,
  imports: Dynamic,
) -> Result(Pid, String)

/// Invoke export `function` with TERM (reference / integer) `args` INSIDE the instance's owned
/// process, returning the raw result PACKAGE as an opaque `Dynamic` (unit P5-11, the reference /
/// multi-value ABI). Bound to the SAME Erlang `call_instance/3` as the integer path (Erlang is
/// untyped), but typed for `Dynamic` in and out so a reference argument (`rt_ref` term) and a
/// reference / multi-value result survive. `Error(reason)` is a trap. Use `result_list` to
/// unpack the returned package into its value list.
@external(erlang, "carder_harness_ffi", "call_instance")
pub fn call_instance_terms(
  proc: Pid,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

/// Extract the host-identity payload of an externref term `{ref_extern, N}` (R18) — the `N` a
/// `ref.extern N` carried, so a returned externref is judged BY IDENTITY. Call only after
/// `rt_ref.classify_ref` reports `ExternRef`; returns the boxed `N` (an integer `Dynamic`).
@external(erlang, "carder_harness_ffi", "extern_payload")
pub fn extern_payload(ref: Dynamic) -> Dynamic

/// Classify a returned GC reference term into a coarse kind string (Phase-8 GC), for the
/// conformance oracle. Structural, harness-side (never dereferences the instance-process arena):
///   `{ref_null}` → `"null"`, `{i31, _}` → `"i31"`, `{gc, struct, _}` → `"gc_struct"`,
///   `{gc, array, _}` → `"gc_array"`, `{gc, _}` → `"gc_heap"` (coarse — struct-vs-array not
///   observable across the process copy, R-GC1), `{ref_extern, _}` → `"extern"`,
///   `{ref_exn, _}` → `"exn"`, anything else → `"func"`. Total.
@external(erlang, "carder_harness_ffi", "gc_classify")
pub fn gc_classify(term: Dynamic) -> String

/// Unpack an invoke result `package` into a flat list of its `arity` values (R17 multi-value
/// run-ABI). `arity == 0` → `[]` (the unit placeholder is dropped); `arity == 1` → `[package]`;
/// `arity >= 2` → the N-tuple destructured with `tuple_to_list`. Each element is a raw numeric
/// bit pattern or a reference term, ready for `tag`/`classify_ref`. Total.
@external(erlang, "carder_harness_ffi", "result_list")
pub fn result_list(arity: Int, package: Dynamic) -> List(Dynamic)

/// Raise `reason` as a BEAM error so a cross-module call PROPAGATES the callee instance's trap (S5 /
/// P6-10). When module B calls module A's exported function through the register-seam routing closure
/// and A traps, `call_instance_terms` returns `Error(rendered_reason)`; the routing closure re-raises
/// it here so B's own invoke surfaces a `Trapped` with A's phrase (a cross-module trap is a trap, not
/// a silent wrong value). Never returns (the type var unifies with the closure's result list).
@external(erlang, "erlang", "error")
pub fn raise_reason(reason: String) -> a

/// Construct the 16-byte binary a `v128` argument carries across the term ABI (P6-10 / S14).
/// Identity over the `BitArray` at runtime — a 16-byte Gleam `BitArray` IS the Erlang `<<_:128>>`
/// binary the generated code consumes as a `v128` operand, little-endian lane layout (lane 0 = the
/// low bytes). No decode/copy: the `Dynamic` is the same term.
@external(erlang, "gleam_stdlib", "identity")
pub fn mk_v128(bytes: BitArray) -> Dynamic

/// Stop an instance's owned process; its process-dictionary cell is GC'd with it.
@external(erlang, "carder_harness_ffi", "stop_instance")
pub fn stop_instance(proc: Pid) -> Nil

/// Force a garbage collection on `proc`, then return its total memory in bytes. Used by the
/// constant-space store-loop test to assert the `cell` strategy does not accumulate memory
/// per iteration (after GC, a constant-space loop's live memory is bounded by the page-map,
/// independent of the iteration count).
@external(erlang, "carder_harness_ffi", "gc_and_memory")
pub fn gc_and_memory(proc: Pid) -> Int
