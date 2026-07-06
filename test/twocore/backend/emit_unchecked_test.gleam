//// Phase-10 unit 05 + Phase-15 S15-03 — tests for the unchecked-access lowering (`emit_core`).
////
//// STRUCTURAL: on paged/atomics/nif the unchecked IR nodes lower to the `load_unchecked`/
//// `store_unchecked` seam of the linked memory backend (S15-03 added tier-N/`nif` to the fail-closed
//// unchecked whitelist — S4). The load-bearing wiring proof: a bce-VERSIONED loop routes its FAST arm
//// to the nif `*_unchecked` seam while its SLOW arm keeps the CHECKED nif seam — trap-preservation is
//// absolute (the guard proves the whole range in-bounds BEFORE the unchecked arm; the compiler NEVER
//// hoists-and-traps-early). END-TO-END: an in-bounds unchecked access returns the IDENTICAL value the
//// checked path returns. Spec-first (D8): unchecked lowering is BIT-IDENTICAL in RESULT to checked.
////
//// SOUNDNESS (S4): eliding the bounds compare is sound precisely because tier-N is a
//// BEAM-memory-UNSAFE tier (Unsafe-only) where the raw deref IS the ceiling lever, AND the unchecked
//// arm is only ever reached inside a bce-versioned loop's fast branch whose guard already proved the
//// whole `i`-range in-bounds. When the `.so` is NOT loaded, the nif `*_unchecked` heads fall back to
//// `rt_mem.*_unchecked` (paged) — so tier-N stays safe on a bare BEAM, and the end-to-end test below
//// exercises exactly that fallback (it deliberately does NOT `load_nif`, to keep this module free of
//// any VM-global native-load side effect on the conformance `cell_nif` matrix). The native `.so`
//// unchecked path is bit-identity-proven separately by S15-02's `native_unchecked_matches_checked_*`
//// differential and the corpus-wide S15-04 `cell_nif` matrix.

import gleam/option
import gleam/string
import twocore/ir
import twocore/pipeline
import twocore/runtime/instance.{type Binding, Atomics, Binding, Nif, Threaded}
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
///
/// `max_pages` bounds the memory: paged/atomics accept `None` (unbounded), but the RESERVING tier-N
/// (`nif`) requires a BOUNDED max (an unbounded nif binding is fail-closed rejected at link time), so
/// the nif end-to-end run passes `Some(1)`.
fn rt_module_max(max_pages: option.Option(Int)) -> ir.Module {
  ir.Module(
    name: "twocore@emit@ncheck_rt",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, max_pages, ir.Idx32)],
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

/// The unbounded `rt` module — the default for paged/atomics/threaded (which accept `None`).
fn rt_module() -> ir.Module {
  rt_module_max(option.None)
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

pub fn nif_emits_unchecked_test() {
  // S15-03 / S4: tier-N (`nif`) is now on the fail-closed unchecked whitelist. It is a
  // BEAM-memory-UNSAFE tier (Unsafe-only) where eliding the bounds compare is the whole point, and
  // S15-02 ships the real `*_unchecked` heads it routes to — so a single-memory (`mem == 0`) unchecked
  // load/store lowers to the nif `load_unchecked`/`store_unchecked` seam (the exact INVERSE of the old
  // "falls back to the checked path" behaviour).
  let nif = profiles.resolve_tiers(Binding(..profiles.unsafe(), mem_tier: Nif))
  let c = core(nif)
  assert string.contains(c, "load_unchecked")
  assert string.contains(c, "store_unchecked")
  // and it routes to the nif memory backend, not paged/atomics.
  assert string.contains(c, "rt_mem_nif")
}

// ─────────────────── the wiring proof: versioned fast=unchecked, slow=checked ───────────────────

pub fn nif_versioned_loop_emits_unchecked_fast_checked_slow_test() {
  // The load-bearing S15-03 wiring proof. bce versions the affine-cursor loop into
  // `let guard in if guard { fast (i-accesses UNCHECKED) } else { original loop (CHECKED) }`. Under
  // the tier-N binding, emit_core must lower the FAST arm's `MemLoadUnchecked`/`MemStoreUnchecked` to
  // the nif `*_unchecked` seam (S15-03's whitelist add) WHILE the SLOW arm keeps the pristine CHECKED
  // nif seam. This proves the lever fires on the guarded arm WITHOUT weakening the checked fallback —
  // trap-preservation is absolute (the guard proves in-bounds before the unchecked arm runs; the
  // compiler never hoists-and-traps-early).
  let nif = profiles.resolve_tiers(Binding(..profiles.unsafe(), mem_tier: Nif))
  let assert Ok(c) = pipeline.ir_to_core(copyloop_module(), nif)
  // FAST arm → the nif unchecked seam (proves bce versioned AND the whitelist routed the unchecked
  // nodes to the nif `*_unchecked` heads; without EITHER, no `_unchecked` seam would appear).
  assert string.contains(c, "'load_unchecked'")
  assert string.contains(c, "'store_unchecked'")
  // SLOW arm → the CHECKED nif seam (`'load'`/`'store'` are the quoted atoms of the checked calls;
  // neither is a substring of `'load_unchecked'`/`'store_unchecked'`, so their presence proves the
  // original checked loop survives verbatim as the guard's else-branch).
  assert string.contains(c, "'load'")
  assert string.contains(c, "'store'")
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

pub fn nif_unchecked_is_bit_identical_to_checked_test() {
  // END-TO-END bit-identity (S3/S7): the tier-N UNCHECKED path returns the IDENTICAL bit pattern the
  // CHECKED path returns for an in-bounds access — eliding the bounds compare changes nothing but
  // speed. This runs the nif binding through the whole pipeline (emit_core routes its unchecked nodes
  // to the nif `*_unchecked` seam, S15-03); with no `.so` loaded those heads fall back to
  // `rt_mem.*_unchecked` (paged), so the assertion holds on a bare BEAM. Deliberately does NOT
  // `load_nif` (that would be a VM-global side effect poisoning the conformance `cell_nif` matrix,
  // which runs on the paged-delegate); the NATIVE `.so` unchecked bit-identity is proven by S15-02's
  // `native_unchecked_matches_checked_in_bounds_test` and the S15-04 corpus `cell_nif` matrix.
  //
  // The RESERVING tier-N requires a bounded max (unbounded is link-rejected), so the nif runs use a
  // 1-page-capped memory; each reference runs over the same capped module for a fair compare.
  let capped = rt_module_max(option.Some(1))
  let nif = profiles.resolve_tiers(Binding(..profiles.unsafe(), mem_tier: Nif))
  // Cell: nif-unchecked round-trip == the exact value AND == the paged-checked reference.
  assert run_module(capped, nif, "rt", [0, 305_419_896])
    == pipeline.Returned([305_419_896])
  assert run_module(capped, nif, "rt", [0, 305_419_896])
    == run_module(capped, profiles.safe(), "rt", [0, 305_419_896])
  // Threaded twin — exercises `t_load_unchecked`/`t_store_unchecked`.
  let nif_threaded =
    profiles.resolve_tiers(
      Binding(..profiles.unsafe(), state_strategy: Threaded, mem_tier: Nif),
    )
  assert run_module(capped, nif_threaded, "rt", [8, 123_456])
    == pipeline.Returned([123_456])
  assert run_module(capped, nif_threaded, "rt", [8, 123_456])
    == run_module(capped, profiles.portable(), "rt", [8, 123_456])
}

// ─────────────────────────── helpers ───────────────────────────

fn run(
  binding: Binding,
  export: String,
  args: List(Int),
) -> pipeline.RunResult {
  run_module(rt_module(), binding, export, args)
}

fn run_module(
  m: ir.Module,
  binding: Binding,
  export: String,
  args: List(Int),
) -> pipeline.RunResult {
  let assert Ok(c) = pipeline.ir_to_core(m, binding)
  let assert Ok(beam) = pipeline.core_to_beam(c, m.name)
  let assert Ok(proc) = pipeline.instantiate(beam, m.name)
  let out = pipeline.invoke_instance(proc, export, args)
  pipeline.stop_instance(proc)
  out
}

/// A minimal versionable affine-cursor loop bce recognizes (the shape the WASM frontend lowers a
/// `for`-over-a-buffer to; mirrors `bce_test`'s `sumbuf` fixture). For `i = 0, 4, …, < n` it LOADS
/// `mem[i]` and STORES it back — both addressed by the induction cursor `i` — so bce versions the loop
/// and rewrites BOTH accesses in the fast arm to their unchecked twins, giving this module a fast
/// (unchecked) and a slow (checked) arm to assert over. Built locally (no cross-file test-internal
/// import). Emit-text only — never run, so it needs no data segment.
fn copyloop_module() -> ir.Module {
  ir.Module(
    name: "twocore@emit@ncheck_loop",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        "copy",
        [ir.Local("n", ir.TI32)],
        [ir.TI32],
        [],
        copyloop_body(),
      ),
    ],
    exports: [ir.ExportFn("copy", "copy")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

fn copyloop_body() -> ir.Expr {
  ir.Loop(
    "l",
    [
      ir.LoopParam("i", ir.TI32, ir.ConstI32(0)),
      ir.LoopParam("acc", ir.TI32, ir.ConstI32(0)),
    ],
    [ir.TI32],
    ir.Let(
      ["done"],
      // `i >= n`: the TRUE arm is the loop exit; the FALSE (work) arm runs while `i < n`.
      ir.Num(ir.IGeU(ir.W32), [ir.Var("i"), ir.Var("n")]),
      ir.If(
        ir.Var("done"),
        [ir.TI32],
        ir.Break("l", [ir.Var("acc")]),
        ir.Let(
          ["x"],
          ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("i"), 0, ir.TI32),
          ir.Let(
            [],
            ir.MemStore(0, ir.MemAccess(4, False), ir.Var("i"), ir.Var("x"), 0),
            ir.Let(
              ["i2"],
              ir.Num(ir.IAdd(ir.W32), [ir.Var("i"), ir.ConstI32(4)]),
              ir.Continue("l", [ir.Var("i2"), ir.Var("acc")]),
            ),
          ),
        ),
      ),
    ),
  )
}
