//// Unit 11b tests — the Safe profile + thin linker, asserted FAIL-CLOSED (D4/D9): the only
//// profile is Safe, it carries exactly the vetted `carder@runtime@rt_*` modules, and there
//// is no API here that yields an unsafe posture.

import carder/opt_level.{Aggressive, Baseline}
import carder/runtime/instance.{
  Atomics, BifAllowlist, BifOpen, Binding, Cell, HostDenyAll, HostOpen,
  HostWhitelist, MeterFuel, MeterOff, Nif, Paged, Safe, StdlibOwn,
  StdlibPassthrough, TableAtomics, TableEts, TablePaged, Threaded, Unsafe,
}
import carder/runtime/profiles
import carder/runtime/rt_mem_atomics
import gleam/list

/// The Safe profile is in `Safe` mode — the fail-closed posture (D9).
pub fn safe_profile_is_safe_mode_test() {
  assert profiles.safe().mode == Safe
}

/// The Safe profile carries EXACTLY the vetted `carder@runtime@rt_*` impl module names
/// (the single source of truth is `instance.safe_default()`; this profile must not re-spell
/// or diverge from it — D1).
pub fn safe_profile_modules_are_vetted_test() {
  assert profiles.safe() == instance.safe_default()
}

/// The Safe profile's chokepoint module names are the pinned `carder@runtime@*` set (the
/// Gleam→Erlang-mangled names generated code calls — D2). Asserted explicitly so a typo in
/// `safe_default` would be caught here too.
pub fn safe_profile_module_names_test() {
  let b = profiles.safe()
  assert b.num_module == "carder@runtime@rt_num"
  assert b.trap_module == "carder@runtime@rt_trap"
  assert b.host_module == "carder@runtime@rt_host"
  assert b.meter_module == "carder@runtime@rt_meter"
  assert b.stdlib_module == "carder@runtime@rt_stdlib"
}

/// The linker assembles a runnable instance from the Safe profile, and that instance is in
/// the Safe posture (`is_safe`/`mode`). Phase-1 instances are thin — they carry only the
/// binding (no mutable state, D3d).
pub fn instantiate_links_safe_instance_test() {
  let inst = profiles.instantiate(profiles.safe())
  assert inst.binding == instance.safe_default()
  assert profiles.is_safe(inst)
  assert profiles.mode(inst) == Safe
}

/// `safe_instance()` is the one-call linker path and is equivalent to
/// `instantiate(safe())`.
pub fn safe_instance_convenience_test() {
  assert profiles.safe_instance() == profiles.instantiate(profiles.safe())
}

/// Fail-closed (the negative property): the linker cannot be coaxed into an unsafe posture
/// through this module's API — every instance it produces is Safe. (The Unsafe profile is
/// Phase 2; there is deliberately no constructor for it here.)
pub fn linker_cannot_produce_unsafe_test() {
  // The only profile constructor is `safe()`, and the only linker entry is `instantiate`.
  assert profiles.is_safe(profiles.instantiate(profiles.safe()))
  assert profiles.is_safe(profiles.safe_instance())
}

/// The Safe max-pages cap is FINITE and never exceeds the 65536-page (4 GiB) i32 hard cap
/// (E3): untrusted code cannot allocate unboundedly. `profiles.safe()` bakes exactly this
/// value into its `Binding`, so the module's declared max governs for the spec suite.
pub fn safe_max_pages_is_finite_test() {
  assert profiles.safe_max_pages() > 0
  assert profiles.safe_max_pages() <= 65_536
  assert profiles.safe().safe_max_pages == profiles.safe_max_pages()
}

/// `safe_capped` can only LOWER the cap (fail-closed): a request ABOVE the hard cap is
/// clamped DOWN to `safe_max_pages()` — there is no way to lift the cap above the hard
/// limit. A negative request clamps to 0 (no growth). The posture stays Safe.
pub fn safe_capped_cannot_lift_cap_test() {
  // A low request is honoured verbatim (the resource-bound use).
  assert profiles.safe_capped(1).safe_max_pages == 1
  // An over-cap request is clamped to the hard cap — never lifted above it.
  assert profiles.safe_capped(1_000_000).safe_max_pages
    == profiles.safe_max_pages()
  // A negative request clamps to 0.
  assert profiles.safe_capped(-5).safe_max_pages == 0
  // Every capped Binding remains Safe (fail-closed) and otherwise identical to `safe()`.
  assert profiles.safe_capped(1).mode == Safe
  assert profiles.safe_capped(1).num_module == profiles.safe().num_module
}

// ───────────────────────────── Phase-3 fail-closed opt-in (F4/§B.4) ─────────────────────────────

/// Every Safe-family constructor (`safe`, `safe_capped`, `safe_default`, `safe_instance`) is
/// the FULL fail-closed Safe posture across the Phase-3 policy fields (D4/D9): mode `Safe`,
/// `Baseline` optimizer, `MeterFuel`, `BifAllowlist`, `StdlibOwn`, `HostDenyAll`. There is no
/// path to an Unsafe field by omission.
pub fn safe_family_is_full_safe_posture_test() {
  let bindings = [
    profiles.safe(),
    profiles.safe_capped(3),
    profiles.safe_metered(1000),
    instance.safe_default(),
    profiles.safe_instance().binding,
  ]
  list.each(bindings, fn(b) {
    assert b.mode == Safe
    assert b.opt_level == Baseline
    assert b.meter == MeterFuel
    assert b.bif_gate == BifAllowlist
    assert b.stdlib == StdlibOwn
    assert b.host_policy == HostDenyAll
  })
}

/// `unsafe()` is the ONLY constructor that yields `mode: Unsafe`, and it is the full aggressive
/// posture (`Aggressive`/`MeterOff`/`BifOpen`/`StdlibPassthrough`/`HostOpen`). Unsafe-by-
/// accident is impossible — it is an explicit, tested opt-in (F4).
pub fn unsafe_is_the_only_unsafe_opt_in_test() {
  // The Safe family is never Unsafe.
  assert profiles.safe().mode != Unsafe
  assert profiles.safe_capped(3).mode != Unsafe
  assert profiles.safe_instance().binding.mode != Unsafe
  // `unsafe()` is Unsafe with the full aggressive posture.
  let u = profiles.unsafe()
  assert u.mode == Unsafe
  assert u.opt_level == Aggressive
  assert u.meter == MeterOff
  assert u.bif_gate == BifOpen
  assert u.stdlib == StdlibPassthrough
  assert u.host_policy == HostOpen
}

/// The `Aggressive ⟹ MeterOff` coupling (§B.5): no shipped constructor pairs `Aggressive`
/// with `MeterFuel` — the illegal pairing is unrepresentable in a profile.
pub fn no_constructor_pairs_aggressive_with_meter_fuel_test() {
  let shipped = [
    profiles.safe(),
    profiles.safe_capped(3),
    profiles.safe_metered(1000),
    instance.safe_default(),
    profiles.safe_instance().binding,
    profiles.unsafe(),
  ]
  list.each(shipped, fn(b) {
    assert !{ b.opt_level == Aggressive && b.meter == MeterFuel }
  })
}

// ───────────────────────────── Unit 10: first-class Unsafe + coexistence seams ─────────────────────────────

/// `unsafe()` has the EXACT aggressive posture asserted field-by-field against F4 (the spec,
/// not the constructor body), AND its shared/inherited fields are IDENTICAL to `safe()`: the
/// `carder@runtime@rt_*` module names (the runtime code is shared), `safe_max_pages` (the i32
/// hard cap is a WASM invariant, not a sandbox lever — Unsafe keeps it), and `fuel_budget`
/// (inherited but unused under `MeterOff`). Only the six policy fields differ — the instance is
/// the unit of policy.
pub fn unsafe_posture_and_inherited_fields_test() {
  let u = profiles.unsafe()
  let s = profiles.safe()
  // The aggressive posture (F4), field by field.
  assert u.mode == Unsafe
  assert u.opt_level == Aggressive
  assert u.meter == MeterOff
  assert u.bif_gate == BifOpen
  assert u.stdlib == StdlibPassthrough
  assert u.host_policy == HostOpen
  // Inherited-from-safe fields are BYTE-IDENTICAL to `safe()` (shared runtime + WASM caps).
  assert u.num_module == s.num_module
  assert u.trap_module == s.trap_module
  assert u.host_module == s.host_module
  assert u.meter_module == s.meter_module
  assert u.stdlib_module == s.stdlib_module
  assert u.mem_module == s.mem_module
  assert u.table_module == s.table_module
  assert u.state_module == s.state_module
  assert u.safe_max_pages == s.safe_max_pages
  assert u.fuel_budget == s.fuel_budget
}

/// `safe_metered(budget)` lowers ONLY the `fuel_budget` on a Safe posture (F5, the CPU analogue
/// of `safe_capped`): the result equals `safe()` with just `fuel_budget` replaced, so `mode`
/// stays `Safe`, every policy field stays the fail-closed Safe choice, and `safe_max_pages` is
/// unchanged. There is no `unsafe_metered` — the budget can only be set on a Safe posture.
pub fn safe_metered_lowers_only_the_budget_test() {
  // The budget is threaded verbatim.
  assert profiles.safe_metered(1000).fuel_budget == 1000
  assert profiles.safe_metered(0).fuel_budget == 0
  // ONLY the budget changes: equal to `safe()` with `fuel_budget` replaced.
  assert profiles.safe_metered(1000)
    == Binding(..profiles.safe(), fuel_budget: 1000)
  // And it stays fully Safe (posture + page cap unchanged).
  assert profiles.safe_metered(1000).mode == Safe
  assert profiles.safe_metered(1000).meter == MeterFuel
  assert profiles.safe_metered(1000).safe_max_pages
    == profiles.safe().safe_max_pages
}

/// `is_safe` distinguishes at the instance level (§B): `safe_instance()` is Safe,
/// `unsafe_instance()` is not, and `unsafe_instance()` is `Unsafe`. `unsafe_instance()` is
/// equivalent to `instantiate(unsafe())` and is the SOLE Unsafe convenience path.
pub fn is_safe_distinguishes_instances_test() {
  assert profiles.is_safe(profiles.safe_instance())
  assert !profiles.is_safe(profiles.unsafe_instance())
  assert profiles.mode(profiles.unsafe_instance()) == Unsafe
  assert profiles.unsafe_instance() == profiles.instantiate(profiles.unsafe())
  // The instance carries the full Unsafe binding through the linker unchanged.
  assert profiles.unsafe_instance().binding == profiles.unsafe()
}

/// `coexist_name` derives DISTINCT output atoms for builds of one source that differ in build
/// identity (§B.5): the default `safe()` (Safe/Cell/Paged) keeps the canonical `base`, while
/// `unsafe()` appends `_unsafe` — always distinct, the load-time precondition for coexistence
/// (two `.beam`s cannot load under one atom). Pure derivation; no policy.
pub fn coexist_name_gives_distinct_output_atoms_test() {
  assert profiles.coexist_name("m", profiles.safe()) == "m"
  assert profiles.coexist_name("m", profiles.unsafe()) == "m_unsafe"
  // Always distinct for any base.
  assert profiles.coexist_name("m", profiles.safe())
    != profiles.coexist_name("m", profiles.unsafe())
  assert profiles.coexist_name("carder@x@mod", profiles.safe())
    != profiles.coexist_name("carder@x@mod", profiles.unsafe())
}

// ───────────────────────────── Unit 07: the linker — compose the tier axes (§A–§D, G3/G6) ─────────────────────────────

/// The tier → runtime-module map (§A.1, G5, keystone §B.1). Each tier maps to the frozen
/// `carder@runtime@*` atom, and the tier-P arms REUSE `safe_default()`'s vetted strings (D1 — no
/// re-spelling). Asserted against the keystone table, not the constructor body.
pub fn tier_module_map_matches_keystone_table_test() {
  // Memory tiers.
  assert profiles.mem_module_for(Paged) == instance.safe_default().mem_module
  assert profiles.mem_module_for(Paged) == "carder@runtime@rt_mem"
  assert profiles.mem_module_for(Atomics) == "carder@runtime@rt_mem_atomics"
  assert profiles.mem_module_for(Nif) == "carder@runtime@rt_mem_nif"
  // Table tiers (no `nif` table tier — none can violate Safe-forbids-nif).
  assert profiles.table_module_for(TablePaged)
    == instance.safe_default().table_module
  assert profiles.table_module_for(TablePaged) == "carder@runtime@rt_table"
  assert profiles.table_module_for(TableEts) == "carder@runtime@rt_table_ets"
  assert profiles.table_module_for(TableAtomics)
    == "carder@runtime@rt_table_atomics"
}

/// `portable()` is tier-P on EVERY axis over the Safe policy (G3, §B). Its state strategy is the
/// only difference from `safe()` — `Threaded` (tier-P, no OTP-native cell); the memory/table
/// modules and every Safe policy field are byte-identical to `safe()` (the tier-P memory backends
/// resolve to `safe_default()`'s own atoms). Crucially it KEEPS `MeterFuel` (P4): the CPU-fuel
/// counter is a node-safe tier-O policy overlay, NOT instance state, so `portable` must not drop
/// the CPU bound to `MeterOff`.
pub fn portable_is_tier_p_everything_test() {
  let p = profiles.portable()
  let s = profiles.safe()
  // Tier-P on every axis, Safe policy.
  assert p.mode == Safe
  assert p.state_strategy == Threaded
  assert p.mem_tier == Paged
  assert p.table_tier == TablePaged
  // Memory/table/num modules byte-identical to `safe()` (tier-P reuses the vetted atoms).
  assert p.mem_module == s.mem_module
  assert p.table_module == s.table_module
  assert p.num_module == s.num_module
  // All five Safe policy fields inherited from `safe()`.
  assert p.opt_level == Baseline
  assert p.meter == MeterFuel
  assert p.bif_gate == BifAllowlist
  assert p.stdlib == StdlibOwn
  assert p.host_policy == HostDenyAll
  // P4: portable KEEPS the CPU bound — MeterFuel, never MeterOff.
  assert p.meter != MeterOff
  // Safe + tier-P is coherent and carries no atomics reservation → admitted.
  assert profiles.validate_binding(p) == Ok(p)
}

/// `ceiling()` is the performance posture (G3/G8, §C): `Unsafe` policy + tier-O `Atomics` memory +
/// `TableAtomics` + `Cell` state, with the full aggressive posture inherited from `unsafe()`. Its
/// resolved `mem_module` is the atomics backend (`mem_module_for(Atomics)`), asserted against the
/// keystone table.
pub fn ceiling_is_the_perf_posture_test() {
  let c = profiles.ceiling()
  // Perf posture on the tier axes.
  assert c.mode == Unsafe
  assert c.state_strategy == Cell
  assert c.mem_tier == Atomics
  assert c.mem_module == profiles.mem_module_for(Atomics)
  assert c.mem_module == "carder@runtime@rt_mem_atomics"
  assert c.table_tier == TableAtomics
  assert c.table_module == "carder@runtime@rt_table_atomics"
  // The full aggressive posture inherited from `unsafe()`.
  assert c.opt_level == Aggressive
  assert c.meter == MeterOff
  assert c.bif_gate == BifOpen
  assert c.stdlib == StdlibPassthrough
  assert c.host_policy == HostOpen
}

/// `ceiling()` requires a BOUNDED cap to engage `atomics` (P6/§C). Its default `safe_max_pages`
/// (the 65536-page hard cap) would eagerly pre-allocate past the node-safe reserve cap for a no-max
/// module, so the uncapped `ceiling()` is a fail-closed link rejection (`AtomicsCapRequired`), NOT
/// a silent 4 GiB pre-allocation or a paged fallback. Supplying a bounded cap ≤ the reserve cap
/// makes it a real, runnable artifact.
pub fn ceiling_requires_a_bounded_cap_test() {
  // Uncapped default is fail-closed rejected at both the gate and the seam.
  assert profiles.validate_binding(profiles.ceiling())
    == Error(profiles.AtomicsCapRequired)
  assert profiles.link(profiles.ceiling()) == Error(profiles.AtomicsCapRequired)
  // A bounded cap ≤ the reserve cap engages atomics and links cleanly.
  assert 100 <= rt_mem_atomics.atomics_reserve_cap_pages
  let capped = Binding(..profiles.ceiling(), safe_max_pages: 100)
  assert profiles.validate_binding(capped) == Ok(capped)
  assert profiles.link(capped) == Ok(profiles.instantiate(capped))
}

/// Safe + Nif is UNCONSTRUCTIBLE through the profile API and REJECTED if hand-built (G6, §D). Every
/// Safe constructor names `Paged` (never `Nif`); a hand-built `Binding(..safe(), mem_tier: Nif)`
/// fails closed at the gate and the seam with `SafeForbidsNif`.
pub fn safe_plus_nif_is_unconstructible_and_rejected_test() {
  // No Safe constructor names Nif.
  let safe_constructors = [
    profiles.safe(),
    profiles.safe_capped(3),
    profiles.safe_capped(999_999),
    profiles.safe_metered(1000),
    instance.safe_default(),
    profiles.portable(),
  ]
  list.each(safe_constructors, fn(b) {
    assert b.mode == Safe
    assert b.mem_tier != Nif
  })
  // The defensive gate rejects a hand-built Safe+Nif.
  let hand = Binding(..profiles.safe(), mem_tier: Nif)
  assert profiles.validate_binding(hand) == Error(profiles.SafeForbidsNif)
  assert profiles.link(hand) == Error(profiles.SafeForbidsNif)
}

/// Every P/O composition is admitted; only Safe+Nif (and an uncapped atomics binding) are rejected
/// (§D.2). Asserts Safe+`Paged`, Unsafe+`Paged`, Safe+`Atomics` (bounded — the node-safe O(1) win
/// in Safe), Unsafe+`Atomics` (bounded), and Unsafe+`Nif` (the tier-N ceiling, one Unsafe
/// composition away) all validate `Ok`.
pub fn every_p_o_composition_is_admitted_test() {
  let cap = 100
  // Safe + Paged, Unsafe + Paged.
  assert profiles.validate_binding(profiles.safe()) == Ok(profiles.safe())
  assert profiles.validate_binding(profiles.unsafe()) == Ok(profiles.unsafe())
  // Safe + Atomics (bounded) — tier-O admitted in Safe.
  let safe_atomics =
    profiles.resolve_tiers(
      Binding(..profiles.safe(), mem_tier: Atomics, safe_max_pages: cap),
    )
  assert profiles.validate_binding(safe_atomics) == Ok(safe_atomics)
  // Unsafe + Atomics (bounded).
  let unsafe_atomics = Binding(..profiles.ceiling(), safe_max_pages: cap)
  assert profiles.validate_binding(unsafe_atomics) == Ok(unsafe_atomics)
  // Unsafe + Nif — the tier-N ceiling, admitted precisely because the base is Unsafe.
  let unsafe_nif = profiles.compose(profiles.unsafe(), Cell, Nif, TableAtomics)
  assert profiles.validate_binding(unsafe_nif) == Ok(unsafe_nif)
}

/// `resolve_tiers` is the SINGLE coherent coupler (P5, §A.2): it derives `mem_module`/`table_module`
/// from the declared tiers, is idempotent, and leaves every policy field untouched. `compose` and
/// `link` both funnel through it, so a composed/linked binding's module always equals
/// `mem_module_for(mem_tier)`.
pub fn resolve_tiers_is_the_single_coherent_coupler_test() {
  // Derives the module from the tier.
  let b =
    profiles.resolve_tiers(Binding(..profiles.unsafe(), mem_tier: Atomics))
  assert b.mem_module == profiles.mem_module_for(Atomics)
  assert b.mem_module == "carder@runtime@rt_mem_atomics"
  // Idempotent.
  assert profiles.resolve_tiers(b) == b
  // Policy fields of the source are untouched.
  let src =
    Binding(..profiles.unsafe(), mem_tier: Atomics, table_tier: TableEts)
  let once = profiles.resolve_tiers(src)
  assert once.mode == src.mode
  assert once.opt_level == src.opt_level
  assert once.meter == src.meter
  assert once.fuel_budget == src.fuel_budget
  assert once.bif_gate == src.bif_gate
  assert once.stdlib == src.stdlib
  assert once.host_policy == src.host_policy
  assert once.safe_max_pages == src.safe_max_pages
  assert once.state_strategy == src.state_strategy
  assert once.mem_tier == src.mem_tier
  assert once.table_tier == src.table_tier
  // compose funnels through resolve_tiers.
  let composed =
    profiles.compose(profiles.unsafe(), Cell, Atomics, TableAtomics)
  assert composed.mem_module == profiles.mem_module_for(composed.mem_tier)
  assert composed.table_module == profiles.table_module_for(composed.table_tier)
}

/// The gate guards the LOAD-BEARING field (P5, §D.2): a stale hand-build that declares `Atomics`
/// but leaves `mem_module` at the paged atom is `Error(TierModuleMismatch)` — a declared tier can
/// never be advisory-only while the seam links a different backend. `resolve_tiers` repairs it, and
/// it then validates `Ok`. (A bounded cap is used so the mismatch, not the atomics cap, is the
/// surfaced error.)
pub fn tier_module_mismatch_guards_the_load_bearing_field_test() {
  let stale =
    Binding(..profiles.unsafe(), mem_tier: Atomics, safe_max_pages: 100)
  // mem_module is still the inherited paged atom — stale relative to the declared Atomics tier.
  assert stale.mem_module == "carder@runtime@rt_mem"
  assert profiles.validate_binding(stale) == Error(profiles.TierModuleMismatch)
  // resolve_tiers makes the module coherent → validates Ok.
  let fixed = profiles.resolve_tiers(stale)
  assert profiles.validate_binding(fixed) == Ok(fixed)
}

/// `compose` builds the two profiles and is POLICY-PRESERVING (§A.2, D4/D9): it changes only the
/// three tier axes (and their resolved modules), never a policy field of the base.
pub fn compose_builds_the_profiles_and_preserves_policy_test() {
  // The two profiles ARE compositions over their policy base.
  assert profiles.compose(profiles.safe(), Threaded, Paged, TablePaged)
    == profiles.portable()
  assert profiles.compose(profiles.unsafe(), Cell, Atomics, TableAtomics)
    == profiles.ceiling()
  // compose leaves every policy field of the base unchanged.
  let base = profiles.unsafe()
  let c = profiles.compose(base, Threaded, Atomics, TableEts)
  assert c.mode == base.mode
  assert c.opt_level == base.opt_level
  assert c.meter == base.meter
  assert c.fuel_budget == base.fuel_budget
  assert c.bif_gate == base.bif_gate
  assert c.stdlib == base.stdlib
  assert c.host_policy == base.host_policy
  assert c.safe_max_pages == base.safe_max_pages
  // Only the tier axes changed.
  assert c.state_strategy == Threaded
  assert c.mem_tier == Atomics
  assert c.table_tier == TableEts
}

/// `link/1` is the SOLE `Binding → Instance` seam (P5, §D.3): `validate_binding ∘ resolve_tiers ∘
/// instantiate`. It succeeds for the structurally-valid profiles, fails closed on a hand-built
/// Safe+Nif, and every instance it yields has a `mem_module` coherent with its `mem_tier`.
pub fn link_is_the_sole_fail_closed_seam_test() {
  // The composition it implements.
  assert profiles.link(profiles.safe())
    == Ok(profiles.instantiate(profiles.resolve_tiers(profiles.safe())))
  assert profiles.link(profiles.portable())
    == Ok(profiles.instantiate(profiles.portable()))
  // Fail-closed: a hand-built Safe+Nif never reaches instantiate.
  assert profiles.link(Binding(..profiles.safe(), mem_tier: Nif))
    == Error(profiles.SafeForbidsNif)
  // A linked instance's binding is always tier↔module coherent.
  let assert Ok(inst) =
    profiles.link(Binding(..profiles.ceiling(), safe_max_pages: 100))
  assert inst.binding.mem_module
    == profiles.mem_module_for(inst.binding.mem_tier)
}

/// No accidental Unsafe or Nif by omission (D4/D9, §E). Every safe-family constructor + `portable()`
/// is Safe + `Paged`; the ONLY `Unsafe` constructors are `unsafe()` and `ceiling()`; no constructor
/// names `Nif` (tier-N needs an explicit Unsafe composition).
pub fn no_accidental_unsafe_or_nif_by_omission_test() {
  let node_safe_family = [
    profiles.safe(),
    profiles.safe_capped(3),
    profiles.safe_metered(1000),
    instance.safe_default(),
    profiles.portable(),
  ]
  list.each(node_safe_family, fn(b) {
    assert b.mode == Safe
    assert b.mem_tier == Paged
  })
  // The only two Unsafe constructors.
  assert profiles.unsafe().mode == Unsafe
  assert profiles.ceiling().mode == Unsafe
  // No shipped constructor names the tier-N Nif memory.
  list.each(
    [
      profiles.safe(),
      profiles.unsafe(),
      profiles.portable(),
      profiles.ceiling(),
    ],
    fn(b) {
      assert b.mem_tier != Nif
    },
  )
}

// ── Phase-5: the `spectest` import-capable Safe binding (§G, R14) ──────────────────

/// `spectest_allow()` is EXACTLY the seven `#("spectest", print*)` pairs — the official host
/// module's function set (spec's `imports.wast`), a literal build-fixed list (D3a), nothing more.
pub fn spectest_allow_is_the_seven_prints_test() {
  assert profiles.spectest_allow()
    == [
      #("spectest", "print"),
      #("spectest", "print_i32"),
      #("spectest", "print_i64"),
      #("spectest", "print_f32"),
      #("spectest", "print_f64"),
      #("spectest", "print_i32_f32"),
      #("spectest", "print_f64_f64"),
    ]
}

/// `safe_spectest()` is a **Safe** posture that whitelists exactly the `spectest` prints — a
/// `HostWhitelist(spectest_allow())`, NEVER `HostOpen`. It differs from `safe()` ONLY in
/// `host_policy`; mode and every other policy field are the Safe defaults (fail-closed — it is not
/// an Unsafe opt-out).
pub fn safe_spectest_is_safe_whitelist_test() {
  let b = profiles.safe_spectest()
  assert b.mode == Safe
  assert b.host_policy == HostWhitelist(profiles.spectest_allow())
  // Identical to safe() apart from the host policy.
  assert b
    == Binding(
      ..profiles.safe(),
      host_policy: HostWhitelist(profiles.spectest_allow()),
    )
  // Not HostOpen — a spectest-importing module stays fail-closed for everything else.
  assert b.host_policy != HostOpen
  // It links cleanly (only host_policy changed, no tier/module divergence).
  assert profiles.link(b) == Ok(profiles.instantiate(b))
}
