//// Phase-10 unit 05 — tests for the unchecked-access lowering (`emit_core`).
////
//// STRUCTURAL: on paged/atomics the unchecked IR nodes lower to the `load_unchecked`/`store_unchecked`
//// seam; on nif they FALL BACK to the checked `load`/`store` (sound — the versioned fast loop's guard
//// proved the access in-bounds either way). END-TO-END: an in-bounds unchecked access returns the
//// identical value as the checked path, under cell (paged) and threaded (portable) state strategies.
//// Spec-first (D8): unchecked lowering is byte-identical in RESULT to checked for in-bounds accesses.

import gleam/option
import gleam/string
import twocore/ir
import twocore/pipeline
import twocore/runtime/instance.{type Binding, Atomics, Binding, Nif}
import twocore/runtime/profiles

fn unchecked_load(base: ir.Value, off: Int) -> ir.Expr {
  ir.MemLoadUnchecked(0, ir.MemAccess(4, False), base, off, ir.TI32)
}

fn unchecked_store(base: ir.Value, off: Int, v: ir.Value) -> ir.Expr {
  ir.MemStoreUnchecked(0, ir.MemAccess(4, False), base, v, off)
}

/// `rt(addr, val)` = unchecked-store `val` at `addr`, then unchecked-load it back → `val`.
/// (Module name deliberately AVOIDS the substring "unchecked" so the seam-name checks below are
/// about the emitted CALLS, not the module header.)
fn rt_module() -> ir.Module {
  ir.Module(
    name: "twocore@emit@ncheck_rt",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        "rt",
        [ir.Local("addr", ir.TI32), ir.Local("val", ir.TI32)],
        [ir.TI32],
        [],
        ir.Let(
          [],
          unchecked_store(ir.Var("addr"), 0, ir.Var("val")),
          unchecked_load(ir.Var("addr"), 0),
        ),
      ),
    ],
    exports: [ir.ExportFn("rt", "rt")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

fn core(binding: Binding) -> String {
  let assert Ok(c) = pipeline.ir_to_core(rt_module(), binding)
  c
}

// ─────────────────────────── structural: the seam selection ───────────────────────────

pub fn paged_emits_the_unchecked_seam_test() {
  let c = core(profiles.safe())
  assert string.contains(c, "load_unchecked")
  assert string.contains(c, "store_unchecked")
}

pub fn atomics_emits_the_unchecked_seam_test() {
  let atomics =
    profiles.resolve_tiers(Binding(..profiles.safe(), mem_tier: Atomics))
  let c = core(atomics)
  assert string.contains(c, "load_unchecked")
  assert string.contains(c, "store_unchecked")
}

pub fn nif_falls_back_to_the_checked_path_test() {
  // nif is Unsafe-only; it does NOT get unchecked entry points, so the lowering falls back to the
  // checked seam (no `_unchecked` in the emitted core).
  let nif = profiles.resolve_tiers(Binding(..profiles.unsafe(), mem_tier: Nif))
  let c = core(nif)
  assert !string.contains(c, "store_unchecked")
  assert !string.contains(c, "load_unchecked")
  // it uses the CHECKED nif seam instead.
  assert string.contains(c, "rt_mem_nif")
}

// ─────────────────────────── end-to-end: unchecked runs like checked ───────────────────────────

pub fn paged_cell_unchecked_runs_correctly_test() {
  // The REAL unchecked path (paged, cell) — an in-bounds round-trip returns the stored value.
  assert run(profiles.safe(), "rt", [0, 305_419_896])
    == pipeline.Returned([305_419_896])
}

pub fn threaded_unchecked_runs_correctly_test() {
  // The threaded twins (t_load_unchecked/t_store_unchecked) under `portable()` (threaded + paged).
  assert run(profiles.portable(), "rt", [4, 123_456])
    == pipeline.Returned([123_456])
}

// ─────────────────────────── helper ───────────────────────────

fn run(
  binding: Binding,
  export: String,
  args: List(Int),
) -> pipeline.RunResult {
  let m = rt_module()
  let assert Ok(c) = pipeline.ir_to_core(m, binding)
  let assert Ok(beam) = pipeline.core_to_beam(c, m.name)
  let assert Ok(proc) = pipeline.instantiate(beam, m.name)
  let out = pipeline.invoke_instance(proc, export, args)
  pipeline.stop_instance(proc)
  out
}
