//// Unit P3-11 capstone — instance = the unit of policy (proof 5 of the unit doc; F4/B3).
////
//// The headline of F4: a **Safe** instance and an **Unsafe** instance of the SAME module run on
//// ONE node, concurrently, with correct results and no state OR capability leakage between them.
//// The Instance/Binding API presents this uniformly ("the instance is the unit of policy"), but
//// the realization is B3 MONOMORPHIZATION — Safe and Unsafe are distinct compiled `.beam`s (Safe
//// has charge sites + allowlist; Unsafe has neither) from the same source, given DISTINCT output
//// atoms (`profiles.coexist_name`), both linking the shared `twocore@runtime@rt_*` modules. Each
//// instantiates in its own owned process (E1), which seeds that instance's runtime policy.
////
//// Two dimensions, at the profile boundary:
////   - STATE isolation, at corpus scale: two instances of the REAL `iso.wasm` corpus module
////     (linear memory + a mutable global), one Safe / one Unsafe, on one node — a `global.set` +
////     `i32.store` in one is INVISIBLE to the other, and each still sees its own writes. This
////     reuses `corpus_test.cross_instance_isolation_test`'s pattern, but ACROSS profiles.
////   - CAPABILITY isolation: the Safe instance's `HostDenyAll` still REJECTS a host import while
////     an `HostOpen` Unsafe instance ADMITS the same import on the same node — the policy lives on
////     the instance (host policy seeded per instance at instantiation), never in ambient node
////     state (D3a/D9). `iso.wasm` is import-free, so this is asserted with a hand-built
////     host-import fixture (mirroring `acceptance_test`), run under each profile.
////
//// Unit 10's `linker_coexist_test` proves the same for a hand-built stateful module; this
//// capstone confirms it at CORPUS scale and adds the capability-isolation dimension.

import gleam/bit_array
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/option
import gleam/string
import twocore/backend/build_beam
import twocore/conformance/ffi
import twocore/ir
import twocore/pipeline
import twocore/runtime/instance.{type Binding}
import twocore/runtime/profiles

// ─────────────────────────── state isolation (real iso.wasm, across profiles) ───────────────────────────

/// STATE ISOLATION at corpus scale (F4/B3). The real `iso.wasm` corpus module — linear memory +
/// a mutable global — compiled twice from ONE source: under `profiles.safe()` (name `base`) and
/// `profiles.unsafe()` (name `base_unsafe`, via `coexist_name`). Both load and instantiate on one
/// node, each in its own owned process, alive together. A `global.set` + `i32.store` in the Safe
/// instance is INVISIBLE to the Unsafe instance and vice versa (disjoint per-process cells), and
/// each still sees its own writes.
pub fn safe_unsafe_iso_state_coexist_test() {
  let assert Ok(bytes) =
    ffi.read_file("test/twocore/conformance/corpus/iso.wasm")
  let assert Ok(m0) = pipeline.source_to_ir(bytes)
  let base = m0.name <> "_" <> int.to_string(ffi.unique_int())
  let safe_name = profiles.coexist_name(base, profiles.safe())
  let unsafe_name = profiles.coexist_name(base, profiles.unsafe())
  // Precondition for coexistence: the two builds have DISTINCT output atoms (else the second
  // load hot-replaces the first — no coexistence).
  assert safe_name != unsafe_name

  let s = load_named(m0, safe_name, profiles.safe())
  let u = load_named(m0, unsafe_name, profiles.unsafe())
  let assert Ok(sp) = ffi.start_instance(s)
  let assert Ok(up) = ffi.start_instance(u)

  // Mutate ONLY the Safe instance's global + memory.
  let assert Ok(_) = ffi.call_instance(sp, atom.create("set_global"), [111])
  let assert Ok(_) = ffi.call_instance(sp, atom.create("store"), [0, 333])
  // The Unsafe instance never observes the Safe writes (fresh zero cell).
  assert ffi.call_instance(up, atom.create("get_global"), []) == Ok(0)
  assert ffi.call_instance(up, atom.create("load"), [0]) == Ok(0)

  // Now mutate ONLY the Unsafe instance; the Safe instance keeps its own writes.
  let assert Ok(_) = ffi.call_instance(up, atom.create("set_global"), [222])
  let assert Ok(_) = ffi.call_instance(up, atom.create("store"), [0, 444])
  assert ffi.call_instance(up, atom.create("get_global"), []) == Ok(222)
  assert ffi.call_instance(up, atom.create("load"), [0]) == Ok(444)
  // The Safe instance still sees exactly its own writes (no cross-leak from Unsafe).
  assert ffi.call_instance(sp, atom.create("get_global"), []) == Ok(111)
  assert ffi.call_instance(sp, atom.create("load"), [0]) == Ok(333)

  ffi.stop_instance(sp)
  ffi.stop_instance(up)
}

// ─────────────────────────── capability isolation (host import, across profiles) ───────────────────────────

/// CAPABILITY ISOLATION (F4/D3a/D9): the Safe instance's `HostDenyAll` REJECTS a declared host
/// import while an `HostOpen` Unsafe instance ADMITS the same import — on one node, concurrently.
/// One hand-built source (a declared `("env","identity")` import) compiled under each profile to
/// DISTINCT atoms: the Safe instance denies with `{capability_denied, env, identity}`, the Unsafe
/// instance dispatches the vetted handler and returns normally. The policy is per-instance (host
/// policy seeded at instantiation), never ambient — no build-fixed handler and no argument turns
/// `HostDenyAll` into a return, and `HostOpen` is reachable only through `profiles.unsafe()`.
pub fn safe_unsafe_host_capability_isolation_test() {
  let base = "twocore@coexist@hostmod_" <> int.to_string(ffi.unique_int())
  let safe_name = profiles.coexist_name(base, profiles.safe())
  let unsafe_name = profiles.coexist_name(base, profiles.unsafe())
  assert safe_name != unsafe_name

  let s = compile_load(host_module(safe_name), profiles.safe())
  let u = compile_load(host_module(unsafe_name), profiles.unsafe())
  let assert Ok(sp) = ffi.start_instance(s)
  let assert Ok(up) = ffi.start_instance(u)

  // Safe instance: deny-all rejects the host import (fail-closed).
  let assert Error(reason) =
    ffi.call_instance(sp, atom.create("useimport"), [123])
  assert string.contains(reason, "capability_denied")

  // Unsafe instance of the SAME source, on the SAME node: HostOpen DISPATCHES the vetted
  // `("env","identity")` handler, so the call returns normally (the module runs the host call for
  // effect and returns the constant 7) — NOT a denial. Same node, two postures, no leakage: the
  // policy lives on the instance, not in ambient node state.
  assert ffi.call_instance(up, atom.create("useimport"), [123]) == Ok(7)

  ffi.stop_instance(sp)
  ffi.stop_instance(up)
}

// ─────────────────────────── fixtures / build helpers ───────────────────────────

/// A hand-built module with a DECLARED `("env","identity")` host import and an exported
/// `useimport(i32) -> i32` that calls it for effect (discarding the result) and returns `0`. The
/// import is declared so `ir_lower`'s provenance gate leaves the `CallHost` to be decided at run
/// time by the instance's `HostPolicy` (deny-all under Safe, open under Unsafe) — not rejected at
/// build time. `name` is the output atom (unique per build via `coexist_name`).
fn host_module(name: String) -> ir.Module {
  ir.Module(
    name: name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [ir.ImportFn("env", "identity", ir.FuncType([ir.TI32], [ir.TI32]))],
    functions: [
      ir.Function(
        name: "useimport",
        params: [ir.Local("p0", ir.TI32)],
        result: [ir.TI32],
        locals: [],
        // Run the host call and return a constant `7`: under Safe the `CallHost` raises
        // `capability_denied` BEFORE the return (deny-all), so the export never returns; under
        // Unsafe (`HostOpen`) the vetted `("env","identity")` handler is dispatched and the export
        // returns 7. Binding the result to `r` (unused) sidesteps the host-result-marshalling
        // path (a host handler returns a LIST of results); the point here is admit-vs-deny.
        body: ir.Let(
          ["r"],
          ir.CallHost("env", "identity", [ir.Var("p0")]),
          ir.Return([ir.ConstI32(7)]),
        ),
      ),
    ],
    exports: [ir.ExportFn("useimport", "useimport")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// Compile IR module `m` through the full pipeline under `binding` and LOAD it, returning its
/// BEAM atom. `let assert Ok` is the success contract — a compile/build failure is a genuine test
/// failure, not an expected path.
fn compile_load(m: ir.Module, binding: Binding) -> Atom {
  let assert Ok(core) = pipeline.ir_to_core(m, binding)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

/// Compile the frontend-lowered `m0` under `binding` after renaming it to `name` (its output
/// atom), and LOAD it. Used to give one source's Safe and Unsafe builds distinct coexisting atoms.
fn load_named(m0: ir.Module, name: String, binding: Binding) -> Atom {
  compile_load(ir.Module(..m0, name: name), binding)
}
