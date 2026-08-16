//// Lever 3 — opt-in UNCHECKED linear memory (`trust_memory`) — emit-routing + end-to-end tests.
////
//// `trust_memory` routes ALL memory-0 loads/stores through the bounds-check-free `*_unchecked`
//// seam INSTEAD of the checked `*_raising` seam, but ONLY on a BEAM-memory-SAFE tier (`Paged` or
//// `Atomics`). Two invariants this module pins:
////
////  - DEFAULT UNCHANGED: with `trust_memory: False` (the fail-closed default) a checked
////    `MemLoad`/`MemStore` still lowers to the lever-2 bare-`*_raising` seam — byte-identical to a
////    build without the field. (This is the conformance-preserving property.)
////  - NIF STAYS CHECKED: tier-N is BEAM-memory-UNSAFE (a raw C deref past the buffer could crash
////    the node), so `trust_memory` is NOT honored there — the nif binding keeps the checked/raising
////    seam even with `trust_memory: True`.
////
//// Spec-first note (D8): under `trust_memory` an OUT-OF-BOUNDS access yields a WRONG VALUE instead
//// of a `MemoryOutOfBounds` trap — the documented, explicit tradeoff. An IN-BOUNDS access is
//// BIT-IDENTICAL to the checked path (eliding the compare changes only speed), which the
//// end-to-end run below asserts against the checked reference.

import carder/ir
import carder/pipeline
import carder/runtime/instance.{type Binding, Binding, Nif}
import carder/runtime/profiles
import gleam/option
import gleam/string

/// A module built from CHECKED `MemLoad`/`MemStore` nodes (NOT the BCE `*Unchecked` nodes) — the
/// exact fixture the `trust_memory` lever must transform. Three exports:
///
///  - `ld(addr) -> i32`: a LOAD-ONLY function. With no preceding store, store-to-load forwarding
///    cannot elide it, so its `MemLoad` genuinely survives into the emitted `.core` — this is what
///    lets the structural tests observe the load seam (`load_unchecked` vs `load_raising`).
///  - `st(addr, val) -> i32`: a STORE-ONLY function (returns 0); its `MemStore` is an observable
///    effect the optimizer keeps, so the store seam (`store_unchecked` vs `store_raising`) survives.
///  - `rt(addr, val) -> i32`: store `val` at `addr` then load it back — the end-to-end round-trip.
///    (Here forwarding may replace the load with the stored value; that is semantics-preserving, so
///    the run still returns the stored value.)
fn rt_module() -> ir.Module {
  ir.Module(
    name: "carder@emit@trustmem_rt",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        "ld",
        [ir.Local("addr", ir.TI32)],
        [ir.TI32],
        [],
        ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("addr"), 0, ir.TI32),
      ),
      ir.Function(
        "st",
        [ir.Local("addr", ir.TI32), ir.Local("val", ir.TI32)],
        [ir.TI32],
        [],
        ir.Let(
          [],
          ir.MemStore(
            0,
            ir.MemAccess(4, False),
            ir.Var("addr"),
            ir.Var("val"),
            0,
          ),
          ir.Values([ir.ConstI32(0)]),
        ),
      ),
      ir.Function(
        "rt",
        [ir.Local("addr", ir.TI32), ir.Local("val", ir.TI32)],
        [ir.TI32],
        [],
        ir.Let(
          [],
          ir.MemStore(
            0,
            ir.MemAccess(4, False),
            ir.Var("addr"),
            ir.Var("val"),
            0,
          ),
          ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("addr"), 0, ir.TI32),
        ),
      ),
    ],
    exports: [
      ir.ExportFn("ld", "ld"),
      ir.ExportFn("st", "st"),
      ir.ExportFn("rt", "rt"),
    ],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// Emit `rt_module` to Core Erlang text under `binding` (never runs it).
fn core(binding: Binding) -> String {
  let assert Ok(c) = pipeline.ir_to_core(rt_module(), binding)
  c
}

// ── structural: trust_memory routes checked accesses to the unchecked seam on a safe tier ──

/// Paged + Cell + `trust_memory: True` → BOTH the checked load and the checked store lower to the
/// BARE `*_unchecked` seam, and NEITHER `*_raising` seam survives.
pub fn trust_memory_paged_routes_to_unchecked_seam_test() {
  let c = core(Binding(..profiles.safe(), trust_memory: True))
  assert string.contains(c, "load_unchecked")
  assert string.contains(c, "store_unchecked")
  assert !string.contains(c, "load_raising")
  assert !string.contains(c, "store_raising")
}

/// Atomics + Cell + `trust_memory: True` → the other BEAM-memory-SAFE tier routes to the unchecked
/// seam too (`atomics:get` is ERTS-bounds-checked, so an OOB access stays contained).
pub fn trust_memory_atomics_routes_to_unchecked_seam_test() {
  let atomics =
    profiles.resolve_tiers(
      Binding(..profiles.safe(), mem_tier: instance.Atomics, trust_memory: True),
    )
  let c = core(atomics)
  assert string.contains(c, "load_unchecked")
  assert string.contains(c, "store_unchecked")
  assert !string.contains(c, "load_raising")
  assert !string.contains(c, "store_raising")
}

/// The DEFAULT (`trust_memory: False`) is UNCHANGED — the lever-2 bare-`*_raising` path, with NO
/// unchecked seam. This is the conformance-preserving invariant: default output is byte-identical
/// to a build without the field.
pub fn trust_memory_off_keeps_raising_seam_test() {
  let c = core(profiles.safe())
  assert string.contains(c, "load_raising")
  assert string.contains(c, "store_raising")
  assert !string.contains(c, "load_unchecked")
  assert !string.contains(c, "store_unchecked")
}

/// Tier-N is BEAM-memory-UNSAFE: `trust_memory` must NOT elide the bounds check there (a raw C
/// deref past the buffer could crash the node). So even with `trust_memory: True` the nif binding
/// keeps the checked/raising seam and emits NO unchecked seam for these plain (non-BCE) accesses.
pub fn trust_memory_nif_stays_checked_test() {
  let nif =
    profiles.resolve_tiers(
      Binding(..profiles.unsafe(), mem_tier: Nif, trust_memory: True),
    )
  let c = core(nif)
  assert string.contains(c, "load_raising")
  assert string.contains(c, "store_raising")
  assert !string.contains(c, "load_unchecked")
  assert !string.contains(c, "store_unchecked")
  // …and it is genuinely linked to the nif backend (proving the tier really is tier-N).
  assert string.contains(c, "rt_mem_nif")
}

// ── end-to-end: an in-bounds unchecked access returns the identical value ──

/// The REAL unchecked path (paged, cell) under `trust_memory` — an in-bounds round-trip returns the
/// stored value, BIT-IDENTICAL to the checked (`trust_memory: False`) reference; eliding the bounds
/// compare changes only speed, never an in-bounds result.
pub fn trust_memory_in_bounds_runs_correctly_test() {
  let trusted = Binding(..profiles.safe(), trust_memory: True)
  assert run(trusted, "rt", [0, 305_419_896])
    == pipeline.Returned([305_419_896])
  assert run(trusted, "rt", [0, 305_419_896])
    == run(profiles.safe(), "rt", [0, 305_419_896])
}

// ── helpers ──

/// Compile `rt_module` under `binding` and invoke `export` with `args` on the BEAM.
fn run(
  binding: Binding,
  export: String,
  args: List(Int),
) -> pipeline.RunResult {
  let m = rt_module()
  let assert Ok(c) = pipeline.ir_to_cmod(m, binding)
  let assert Ok(beam) = pipeline.cmod_to_beam(c)
  let assert Ok(proc) = pipeline.instantiate(beam, m.name)
  let out = pipeline.invoke_instance(proc, export, args)
  pipeline.stop_instance(proc)
  out
}
