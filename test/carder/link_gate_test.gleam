//// Phase 11 · P11-04 — tests for the `--link` pre-link fail-closed gate (`cli.link_gate/2`).
////
//// These assert the DEFINED gate contract from `specs/phase-11/RECONCILIATION.md` (R13/R14) and
//// `04-cli-and-gate.md` (O4/O8) — NOT whatever the code happens to return. The gate is a PURE
//// predicate over the resolved `Binding` + the source `ir.Module`, so it is tested with no linker
//// body and no spawned process:
////   - tier-N (`Nif`) is rejected at the CLI/linker boundary under ANY mode (R13/O4) — and the
////     load-bearing R13 assertion is that `profiles.link/1` ADMITS the SAME Unsafe+Nif binding
////     (the tier gate is NOT folded into runtime instantiation);
////   - an import-bearing module is rejected (R14) — a bare node has no import providers;
////   - a tier-P (Safe/Paged) and a tier-O (Atomics) import-free module are admitted.

import carder/cli
import carder/ir
import carder/runtime/instance.{type Binding, Binding, Nif}
import carder/runtime/profiles
import gleam/option

// ───────────────────────────── fixtures ─────────────────────────────

/// A minimal numerics `ir.Module` carrying exactly `imports` — the only field the gate reads
/// besides `binding.mem_tier` (functions/exports left empty; the gate is import-shape-only).
fn module_with_imports(imports: List(ir.ImportDecl)) -> ir.Module {
  ir.Module(
    name: "gate_mod",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: imports,
    functions: [],
    exports: [],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// A coherent Unsafe + tier-N (`Nif`) binding: `resolve_tiers` couples `mem_module` to the `Nif`
/// tier, so `profiles.link/1` ADMITS it (Unsafe+Nif is a valid runtime binding). This is exactly
/// the binding whose `--link` build the gate must refuse (R13/O4) even though `link/1` accepts it.
fn unsafe_nif_binding() -> Binding {
  profiles.resolve_tiers(Binding(..profiles.unsafe(), mem_tier: Nif))
}

// ═══════════════════════ 1. tier-N (`Nif`) rejected — R13/O4 ═══════════════════════

/// R13/O4: `--link` + tier-N is a link-time rejection with the typed `LinkTierNif` error, and the
/// SAME Unsafe+Nif binding is `Ok` through `profiles.link/1` — proving the tier gate is the
/// CLI/linker-boundary enforcement point, NOT `link/1` (which legitimately admits Unsafe+Nif for
/// the ordinary non-linked build path). A NIF cannot be merged into a `.beam`.
pub fn gate_rejects_nif_tier_test() {
  let binding = unsafe_nif_binding()
  assert cli.link_gate(binding, module_with_imports([]))
    == Error(cli.LinkTierNif)
  // The load-bearing R13 pin: link/1 admits the identical binding (it is a valid runtime posture).
  let assert Ok(_) = profiles.link(binding)
}

// ═══════════════════════ 2. import-bearing rejected — R14 ═══════════════════════

/// R14: an import-bearing module is link-time rejected — it compiles to `instantiate/1(Imports)`,
/// which needs providers a bare node lacks. Both a function import and a non-function (global)
/// import trip the gate, each reporting the declared-import count. Checked under `safe()` (tier-P)
/// so the rejection is attributable to the import, not the tier.
pub fn gate_rejects_import_bearing_test() {
  let fn_import =
    module_with_imports([ir.ImportFn("env", "log", ir.FuncType([ir.TI32], []))])
  assert cli.link_gate(profiles.safe(), fn_import)
    == Error(cli.LinkImportBearing(1))

  let global_import =
    module_with_imports([ir.ImportGlobal("env", "g", ir.TI32, False)])
  assert cli.link_gate(profiles.safe(), global_import)
    == Error(cli.LinkImportBearing(1))
}

// ═══════════════════════ 3. tier-P / tier-O import-free admitted — O4/O8 ═══════════════════════

/// O4/O8: an import-free module is ADMITTED under both linkable tiers — tier-P (Safe/`Paged`) and
/// tier-O (`Atomics`, here a bounded-cap `ceiling`). The gate reads only `mem_tier` (≠ `Nif`) and
/// `imports` (empty), so both return `Ok(Nil)` and hand off to the linker.
pub fn gate_admits_import_free_tier_po_test() {
  // tier-P — the fail-closed default.
  assert cli.link_gate(profiles.safe(), module_with_imports([])) == Ok(Nil)
  // tier-O — Atomics, bounded cap (the cap is irrelevant to the gate, which only sees the tier).
  let tier_o = Binding(..profiles.ceiling(), safe_max_pages: 16)
  assert cli.link_gate(tier_o, module_with_imports([])) == Ok(Nil)
}
