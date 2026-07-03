//// Thin Gleam bindings over the unit-07 test FFI (`test/twocore_conformance_ffi.erl`).
////
//// These are the only host capabilities the conformance harness needs that Gleam's
//// stdlib does not provide: invoke-with-trap-catch, file IO, JSON parsing (OTP's
//// built-in `json`), directory listing, and shelling out to the Tier-B reference
//// engine. Keeping every `@external` here means the rest of the harness is plain
//// Gleam. All bindings are total — every failure mode is a typed `Result`.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}

/// Apply `module:function(args)` on the freshly-loaded generated BEAM module and
/// capture the outcome. `Ok(raw)` is a normal return whose `raw` is the function's
/// result rendered as an integer (the raw value / IEEE-754 bit pattern, per D5);
/// `Error(text)` is any trap / exit / throw with its reason rendered as text so the
/// caller can substring-match (e.g. `"int_div_by_zero"`). Never crashes the runner.
@external(erlang, "twocore_conformance_ffi", "catch_apply")
pub fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

/// Read a file's raw bytes. `Ok(bytes)` or `Error(reason)` (POSIX reason as text).
@external(erlang, "twocore_conformance_ffi", "read_file")
pub fn read_file(path: String) -> Result(BitArray, String)

/// Parse a JSON byte string into a `Dynamic` (maps keyed by binary strings, lists,
/// binaries, integers) via OTP's `json:decode/1`. `Error(reason)` on malformed JSON.
/// wast2json keeps every numeric value as a STRING, so no precision is lost here.
@external(erlang, "twocore_conformance_ffi", "parse_json")
pub fn parse_json(bytes: BitArray) -> Result(Dynamic, String)

/// List the entry names (not full paths) in `dir`. `Error(reason)` if it is not a
/// readable directory. Used to discover which `*.json` fixtures are present.
@external(erlang, "twocore_conformance_ffi", "list_dir")
pub fn list_dir(dir: String) -> Result(List(String), String)

/// Resolve `name` on `PATH`. `Ok(path)` if found, `Error(_)` otherwise — lets the
/// Tier-B adapter skip gracefully when the reference engine is not installed.
@external(erlang, "twocore_conformance_ffi", "find_executable")
pub fn find_executable(name: String) -> Result(String, String)

/// Run an external program with string `args`, returning `#(exit_code, combined
/// stdout+stderr)`. Tier-B only (never on the Tier-A path).
@external(erlang, "twocore_conformance_ffi", "run")
pub fn run(program: String, args: List(String)) -> #(Int, String)

/// A strictly-positive unique integer, used to make each generated module's name
/// unique so multi-module fixtures don't clobber one another on load.
@external(erlang, "twocore_conformance_ffi", "unique_int")
pub fn unique_int() -> Int

/// Start an OWNED process for a generated instance and run its `instantiate/0` IN
/// that process (one-instance-one-process, E1). `module` is the loaded BEAM module
/// atom. `Ok(pid)` means instantiation succeeded and the process is holding the
/// seeded cell, ready for `call_instance`; `Error(reason)` is an instantiation-time
/// trap (OOB active segment / trapping start), the reason rendered as text. The
/// cell is private to this process, so a (re)instantiation always starts fresh.
@external(erlang, "twocore_conformance_ffi", "start_instance")
pub fn start_instance(module: Atom) -> Result(Pid, String)

/// Invoke export `function` with raw integer `args` INSIDE the instance's owned
/// process (so it reads that instance's cell). `Ok(raw)` is a normal single result
/// (raw value / IEEE-754 bit pattern, D5); `Error(reason)` is a trap rendered as
/// text. Cross-invoke state persists because successive calls hit the same process.
@external(erlang, "twocore_conformance_ffi", "call_instance")
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
@external(erlang, "twocore_conformance_ffi", "start_instance_with")
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
@external(erlang, "twocore_conformance_ffi", "call_instance")
pub fn call_instance_terms(
  proc: Pid,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

/// Extract the host-identity payload of an externref term `{ref_extern, N}` (R18) — the `N` a
/// `ref.extern N` carried, so a returned externref is judged BY IDENTITY. Call only after
/// `rt_ref.classify_ref` reports `ExternRef`; returns the boxed `N` (an integer `Dynamic`).
@external(erlang, "twocore_conformance_ffi", "extern_payload")
pub fn extern_payload(ref: Dynamic) -> Dynamic

/// Unpack an invoke result `package` into a flat list of its `arity` values (R17 multi-value
/// run-ABI). `arity == 0` → `[]` (the unit placeholder is dropped); `arity == 1` → `[package]`;
/// `arity >= 2` → the N-tuple destructured with `tuple_to_list`. Each element is a raw numeric
/// bit pattern or a reference term, ready for `tag`/`classify_ref`. Total.
@external(erlang, "twocore_conformance_ffi", "result_list")
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
@external(erlang, "twocore_conformance_ffi", "stop_instance")
pub fn stop_instance(proc: Pid) -> Nil

/// Force a garbage collection on `proc`, then return its total memory in bytes. Used by the
/// constant-space store-loop test to assert the `cell` strategy does not accumulate memory
/// per iteration (after GC, a constant-space loop's live memory is bounded by the page-map,
/// independent of the iteration count).
@external(erlang, "twocore_conformance_ffi", "gc_and_memory")
pub fn gc_and_memory(proc: Pid) -> Int

/// Reset the routing-partition spy flag (per process).
@external(erlang, "twocore_conformance_ffi", "spy_reset")
pub fn spy_reset() -> Nil

/// Mark that a spy driver's `instantiate` was (wrongly) reached.
@external(erlang, "twocore_conformance_ffi", "spy_mark")
pub fn spy_mark() -> Nil

/// Whether the spy's `instantiate` was reached since the last `spy_reset`.
@external(erlang, "twocore_conformance_ffi", "spy_called")
pub fn spy_called() -> Bool
