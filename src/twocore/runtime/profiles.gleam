//// Unit 11b — named runtime **profiles** + the thin `rt_instance` linker (high-level
//// §6/§13). The **Safe** profile is the fail-closed default; Phase 3 adds the **Unsafe**
//// profile (`unsafe()`) as an EXPLICIT, TESTED opt-in (F4). There is no path to an Unsafe
//// posture by omission (D4/D9): `safe()`/`safe_capped()`/`safe_default()`/`safe_instance()`
//// all stay Safe, and only `unsafe()` yields `mode: Unsafe` (the aggressive optimizer, no
//// metering, open BIF gate, passthrough stdlib, open host).
////
//// A *profile* is a build-time `Binding` (the calling convention, `runtime/instance.gleam`)
//// carrying the vetted `twocore@runtime@rt_*` impl module names. A *linker* assembles a
//// runnable `Instance` from a profile. Phase 1 is thin: a Phase-1 instance carries only its
//// binding because generated functions are pure and thread no mutable state (D3d); Phase 2
//// adds memory/table/global handles here, a clean extension because the binding chokepoint
//// already exists.
////
//// ## Single-owner rule (D1)
////
//// This module **imports** `instance.gleam` and never edits it. The vetted impl module
//// names live in exactly one place — `instance.safe_default()` — so the `twocore@runtime@*`
//// strings are never re-spelled here.
////
//// ## Honest scope (D9)
////
//// `instantiate` records the chosen binding; it is the *seam* a Phase-2 linker will grow
//// into (loading/resolving the runtime modules, allocating memory/tables). Phase 1 does not
//// claim a full sandbox — it wires and exercises the Safe-mode seams end-to-end.
////
//// ## Phase-4 — the linker: compose the tier axes + the two named profiles (G3/G6, unit 07)
////
//// Phase 4 makes this module the **linker** that composes the three orthogonal build axes —
//// `state_strategy × mem_tier × policy` (G3) — into two headline deployment profiles and
//// resolves each declared trust tier to the runtime module `emit_core` links (keeping codegen
//// tier-agnostic, G5):
////
//// - **`portable()`** — the runs-anywhere headline: tier-P on every axis (`Threaded` state,
////   `Paged` memory, `TablePaged` table, `bif` numerics) over the fail-closed **Safe** policy.
////   No OTP-native state, no NIF, cannot crash the node; loads on a bare BEAM.
//// - **`ceiling()`** — the perf posture: the `Unsafe` policy composed with tier-O `Atomics`
////   memory (O(1), no native code) over `Cell` state and a `TableAtomics` table. The fastest
////   build that ships today, engaged only over a **bounded** memory cap (§ `validate_binding`).
////
//// The tier→module coupling lives in one place: `mem_module_for`/`table_module_for` map a
//// declared tier to its `rt_*` module atom (the sole home of the new tier atoms), and
//// `resolve_tiers` is the single source that copies those atoms onto a binding's `mem_module`/
//// `table_module` — so a declared tier can never diverge from the module the seam links.
//// `compose` builds an axis point over a policy base; `validate_binding` is the fail-closed gate
//// (Safe forbids the tier-N `Nif` memory, G6; the linked module must agree with the declared
//// tier; an atomics build needs a bounded reservation cap); `link` is the **sole** validated
//// `Binding → Instance` seam.

import gleam/int
import gleam/option.{None}
import gleam/result
import twocore/opt_level.{Aggressive}
import twocore/runtime/instance.{
  type Binding, type MemTier, type Mode, type StateStrategy, type TableTier,
  Atomics, BifOpen, Binding, Cell, HostOpen, HostWhitelist, MeterOff, Nif, Paged,
  Safe, StdlibPassthrough, TableAtomics, TableEts, TablePaged, Threaded, Unsafe,
  safe_default,
}
import twocore/runtime/rt_mem_atomics

/// The Safe-profile **hard cap** on linear-memory pages (E3) — the single source of the
/// Safe max-pages policy. A FINITE value that applies even when a module declares
/// `max_pages: None`, so untrusted code cannot allocate unboundedly: `memory.grow` past the
/// effective max returns `-1` and allocates nothing, and `grow` charges fuel proportional to
/// the bytes allocated. The effective memory max baked at seed time is
/// `min(declared_max ?? safe_max_pages(), safe_max_pages(), 65536)`.
///
/// Returns `65536` (= 2¹⁶ pages = the i32 4 GiB address-space cap). At this value the
/// module's DECLARED max governs for the spec suite (so conformance `memory.grow` semantics
/// match the spec); `profiles.safe()` uses exactly this. The acceptance `grow`-cap proof
/// uses `safe_capped` to LOWER it (never above this hard cap — fail-closed). Total.
pub fn safe_max_pages() -> Int {
  65_536
}

/// The named **Safe** profile: the build-time `Binding` carrying the vetted
/// `twocore@runtime@rt_*` impl module names (units 09/10) — memory/table/state layers wired
/// + the Safe max-pages cap (`safe_max_pages()`). This is the fail-closed default (deny-all
/// host, allowlisted BIFs, metering, bounds-checked memory). Total — never fails. There is
/// deliberately no `unsafe()` here: a caller cannot obtain an unsafe posture from this
/// module (D4/D9), and `safe_capped` can only LOWER the page cap, never lift it.
pub fn safe() -> Binding {
  safe_default()
}

/// A Safe `Binding` whose linear-memory cap is LOWERED to `max_pages` pages — used to prove
/// the resource bound fires (a module declaring no max that grows past `max_pages` gets `-1`
/// from `memory.grow` and allocates nothing, E3).
///
/// - `max_pages`: the desired cap in 64 KiB pages. **Fail-closed:** it is clamped to
///   `[0, safe_max_pages()]`, so a value above the 65536-page hard cap cannot LIFT the cap —
///   `profiles` exposes no way to exceed `safe_max_pages()`. A value `≤ 0` clamps to `0` (no
///   growth at all).
/// - Returns a `Safe`-mode `Binding` identical to `safe()` except for the lower
///   `safe_max_pages` field (which `emit_core` bakes into the `rt_mem:fresh` seed). Total.
pub fn safe_capped(max_pages: Int) -> Binding {
  let capped = int.max(0, int.min(max_pages, safe_max_pages()))
  Binding(..safe_default(), safe_max_pages: capped)
}

/// A Safe profile with a LOWERED per-instance CPU-fuel budget (F5) — the CPU analogue of
/// `safe_capped(max_pages)`. `instantiate/0` bakes `seed_fuel(binding.fuel_budget)` (unit 09
/// §A.4), so a smaller `budget` traps a runaway loop sooner with `FuelExhausted`. This is the
/// single per-instance channel for the CPU bound (unit 11's runaway-loop trap proof passes a
/// SMALL budget through here).
///
/// - `budget`: the per-instance CPU-fuel seed, in `charge` units. Any `Int`; a smaller value
///   exhausts sooner. Passed VERBATIM (no clamping) — it is a resource bound the caller
///   chooses, never a way to WIDEN the posture. A non-positive budget seeds an already-
///   exhausted instance (it traps on the first `charge`); that is a caller choice, not a
///   posture change.
/// - Returns a `Safe`-mode `Binding` identical to `safe()` except for the lowered
///   `fuel_budget` field — `mode: Safe` and all five Safe policy fields
///   (`Baseline`/`MeterFuel`/`BifAllowlist`/`StdlibOwn`/`HostDenyAll`) are unchanged.
///
/// Fail-closed (D4/D9): it can only set the budget on a Safe posture. There is deliberately no
/// `unsafe_metered` — `MeterOff` seeds no budget, so there is nothing to lower. Total — never
/// fails.
pub fn safe_metered(budget: Int) -> Binding {
  Binding(..safe(), fuel_budget: budget)
}

/// The build-fixed allow-set for the official `spectest` host functions (§G, R14) — exactly the
/// seven `#("spectest", print*)` pairs, nothing more. A LITERAL list in this module (D3a — no
/// data-driven allow-set); every other capability stays denied. Used to build the import-capable
/// Safe binding (`safe_spectest()`) the conformance harness links `spectest`-importing modules
/// under. The seven names match `rt_host`'s `spectest` handler arms exactly.
///
/// Returns the seven `#(capability, name)` pairs. Total — never fails.
pub fn spectest_allow() -> List(#(String, String)) {
  [
    #("spectest", "print"),
    #("spectest", "print_i32"),
    #("spectest", "print_i64"),
    #("spectest", "print_f32"),
    #("spectest", "print_f64"),
    #("spectest", "print_i32_f32"),
    #("spectest", "print_f64_f64"),
  ]
}

/// The **Safe** binding that admits the `spectest` host functions (§G, R14) — a `HostWhitelist`,
/// NEVER `HostOpen`. Identical to `safe()` except `host_policy: HostWhitelist(spectest_allow())`;
/// every non-`spectest` capability stays denied (the fail-closed whitelist conjunction, Phase-3),
/// and an unlisted `spectest` pair (nothing here) is denied too. The conformance harness links
/// `spectest`-importing modules under this posture.
///
/// It is a **Safe** posture (`mode: Safe`) — NOT an Unsafe opt-out, so the fail-closed enumeration
/// is unperturbed (`unsafe()`/`ceiling()` remain the only `mode: Unsafe` constructors). It changes
/// only `host_policy`, so it composes with `link/1` exactly as `safe()`. Total — never fails.
pub fn safe_spectest() -> Binding {
  Binding(..safe(), host_policy: HostWhitelist(spectest_allow()))
}

/// The build-fixed allow-set for Porffor's runtime intrinsics (P7-08 §A/§G) — exactly the four
/// `#("", letter)` pairs Porffor imports from module `""` (`a`=print, `b`=printChar, `c`=time,
/// `d`=timeOrigin), nothing more. A LITERAL list in this module (D3a — no data-driven
/// allow-set); every other capability stays denied. Mirrors `spectest_allow/0`; the four names
/// match `rt_host`'s Porffor handler arms exactly.
///
/// Returns the four `#(capability, name)` pairs. Total — never fails.
pub fn porffor_allow() -> List(#(String, String)) {
  [#("", "a"), #("", "b"), #("", "c"), #("", "d")]
}

/// The **Safe** binding that admits Porffor's `""` runtime intrinsics (P7-08 §G) — the
/// JS-on-BEAM posture. A `HostWhitelist`, NEVER `HostOpen`. Identical to `safe()` except
/// `host_policy: HostWhitelist(porffor_allow())`; every non-Porffor capability stays denied
/// (the fail-closed whitelist conjunction), and an unprovided `""` intrinsic (`""."e"`, the PGO
/// `profileLocalSet`, …) is denied too (§B.4). The four intrinsics are explicit, auditable host
/// functions with BOUNDED authority (append to a process-local output buffer / read a
/// deterministic clock — no file/socket/node authority), so this stays a genuinely **Safe**
/// posture (`mode: Safe`), NOT an Unsafe opt-out — the fail-closed enumeration is unperturbed
/// (`unsafe()`/`ceiling()` remain the only `mode: Unsafe` constructors). Changes only
/// `host_policy`, so it composes with `link/1` exactly as `safe()`/`safe_spectest()`. Total.
pub fn porffor() -> Binding {
  Binding(..safe(), host_policy: HostWhitelist(porffor_allow()))
}

/// The JS-on-BEAM posture name — an alias for `porffor()` (the headline "run JS via Porffor"
/// build). Provided so callers name the *intent* (`profiles.js()`) not the *toolchain*;
/// identical binding. Total.
pub fn js() -> Binding {
  porffor()
}

/// The named **Unsafe** profile (F4) — the platform's second named mode, the aggressive
/// posture in one value: the aggressive optimizer, no CPU metering, the open BIF gate,
/// passthrough stdlib, and the open host, while keeping the **identical**
/// `twocore@runtime@rt_*` runtime module names as `safe()` (the runtime CODE is shared; the two
/// profiles are distinct B3 builds and the instance is the unit of policy).
///
/// Posture, field by field (asserted against F4, not against this body):
/// - `mode: Unsafe` — the ONLY constructor here that yields it.
/// - `opt_level: Aggressive` — baseline + Unsafe-only passes (unit 04).
/// - `meter: MeterOff` — `ir_lower` inserts NO `Charge` nodes (F5 zero-overhead), so
///   `FuelExhausted` is unreachable in an Unsafe instance.
/// - `bif_gate: BifOpen` — admits the resolver's build-controlled targets (never arbitrary
///   ambient BIFs, D3a).
/// - `stdlib: StdlibPassthrough` — routes shared functions to BEAM stdlib where trusted;
///   observably identical to `own` (unit 06).
/// - `host_policy: HostOpen` — all host imports permitted (still no data-driven `apply`, D3a).
///
/// The `Aggressive ⟹ MeterOff` coupling holds (only `Baseline`/`OptNone` may pair with
/// `MeterFuel`), so the Unsafe-only passes run over a provably metering-free module.
///
/// **Inherited unchanged from `safe_default()` (the spread carries them):**
/// - `safe_max_pages: 65536` — the i32 4 GiB address-space bound (2¹⁶ pages) is a **WASM
///   invariant** (spec §2.5.4 / §4.2.8), NOT a sandbox lever. Unsafe keeps it: there is
///   deliberately no `unsafe_capped`, and `memory.grow` past 2¹⁶ pages still returns `-1`.
///   Unsafe does not grant unbounded memory (that is the deferred Phase-4 `rt_mem` tier).
/// - `fuel_budget` — harmless under `MeterOff` (no `Charge`, no `seed_fuel` emitted).
///
/// **Fail-closed (D4/D9):** this is the ONLY constructor in `profiles` yielding `mode: Unsafe`.
/// `safe()`/`safe_capped(_)`/`safe_metered(_)`/`safe_default()`/`safe_instance()` are all fully
/// Safe; Gleam has no default field values, so an Unsafe posture requires NAMING this
/// constructor. Total — never fails.
pub fn unsafe() -> Binding {
  Binding(
    ..safe_default(),
    mode: Unsafe,
    opt_level: Aggressive,
    meter: MeterOff,
    bif_gate: BifOpen,
    stdlib: StdlibPassthrough,
    host_policy: HostOpen,
  )
}

/// A runnable instance assembled by the linker (`rt_instance`, high-level §13).
///
/// Phase 1 is intentionally thin: it carries only the `binding` (the resolved runtime
/// layer module names). There is **no mutable instance state** in Phase 1 — no memory,
/// tables, or mutable globals in the op set — so generated functions are pure and thread
/// nothing (D3d). Phase 2 grows this record with memory/table/global handles.
///
/// - `binding`: the build-time `Binding` this instance runs against.
pub type Instance {
  Instance(binding: Binding)
}

/// Assemble a runnable `Instance` from a `binding` (the linker step).
///
/// - `binding`: the build-time profile (e.g. `safe()`). Its `*_module` fields name the
///   `twocore@runtime@*` modules generated code will call; they are loaded into the build
///   VM as ordinary BEAM modules (overview D10), so no per-instance resolution is needed in
///   Phase 1.
///
/// Returns an `Instance` wrapping `binding`. Retains its total `Binding -> Instance`
/// signature (the Phase-1/2/3 contract — every existing caller relies on it), but is
/// **self-validating** as defense-in-depth (P5): the *unconstructible* `Safe + Nif`
/// composition (§D.1 — no profile constructor names it, and a hand-built one is rejected
/// gracefully by `link/1`) is asserted fail-closed here, so even a *direct* `instantiate/1`
/// call cannot silently yield a `rt_mem_nif`-linked `Instance` under the Safe policy. The
/// graceful `Result` path is `link/1` (`Error(SafeForbidsNif)`); this assertion is the
/// last-resort node-safe backstop for the ungated path.
///
/// Panics (node-safe) on `mode == Safe && mem_tier == Nif` — a state that cannot arise from
/// any profile constructor. Total for every constructible binding.
pub fn instantiate(binding: Binding) -> Instance {
  case binding.mode, binding.mem_tier {
    Safe, Nif ->
      panic as "profiles.instantiate: Safe forbids the tier-N Nif memory (G6, unconstructible via the profile API; route hand-built bindings through link/1 for a graceful Error(SafeForbidsNif))"
    _, _ -> Instance(binding: binding)
  }
}

/// Convenience: the runnable Safe instance — `instantiate(safe())`. The one-call path the
/// CLI/acceptance use to link the default profile. Total.
pub fn safe_instance() -> Instance {
  instantiate(safe())
}

/// Convenience: the runnable Unsafe instance — `instantiate(unsafe())`. The one-call path a
/// caller uses to link the Unsafe profile, mirroring `safe_instance()`.
///
/// Being the SOLE Unsafe convenience keeps the fail-closed guarantee legible: an author must
/// NAME `unsafe`/`unsafe_instance` to leave Safe (`is_safe(unsafe_instance()) == False`,
/// `mode(unsafe_instance()) == Unsafe`). `instantiate/1`/`mode/1`/`is_safe/1` are unchanged —
/// they read the binding, so they carry the Unsafe posture through with no edit. Total — never
/// fails.
pub fn unsafe_instance() -> Instance {
  instantiate(unsafe())
}

/// The execution `Mode` an instance realises (`Safe` for every Phase-1 instance).
///
/// - `inst`: the instance to inspect.
/// - Return: `inst.binding.mode`. Provided so a fail-closed test can assert an instance is
///   Safe without reaching into the binding record. Total.
pub fn mode(inst: Instance) -> Mode {
  inst.binding.mode
}

/// Whether `inst` is in the fail-closed Safe posture.
///
/// - `inst`: the instance to inspect.
/// - Return: `True` iff `inst.binding.mode == Safe`. Phase 1 always returns `True` (the
///   only profile is Safe); the predicate exists so the Phase-2 Unsafe profile is an
///   explicit, tested opt-out rather than an accident. Total.
pub fn is_safe(inst: Instance) -> Bool {
  inst.binding.mode == Safe
}

/// Derive a DISTINCT output module name for a coexisting build of the same source module
/// (§B.5/B3), so any two `.beam`s of ONE source that differ in build identity can load together
/// on one node without an atom clash. Two `.beam`s cannot load under the same module atom, and a
/// name collision hot-replaces (clobbers) the earlier module; the generated atom is
/// `ir.Module.name`, so the linker gives the builds distinct names before `emit_core`.
///
/// A build's identity is the triple `(mode, state_strategy, mem_tier)` — two builds that differ
/// in ANY of these are different `.beam`s (the calling convention and the linked `rt_*` module
/// differ, G1/B3), so `safe()` (cell) and `portable()` (threaded) — **both `Safe`** — must NOT
/// collide. The atom keys on all three, appending suffixes in a FIXED order:
///
/// - `mode`: `Unsafe` appends `_unsafe`; `Safe` appends nothing.
/// - `state_strategy`: `Threaded` appends `_threaded`; `Cell` appends nothing.
/// - `mem_tier`: `Atomics` appends `_atomics`, `Nif` appends `_nif`; `Paged` appends nothing.
///
/// The default posture (`Safe`/`Cell`/`Paged`) appends NOTHING — the atom is the canonical
/// `base`, byte-identical to Phase-2/3 (conformance-neutral, G7), so every existing coexistence
/// assertion still holds. Any two distinct-identity builds derive distinct atoms.
///
/// - `base`: the source module's canonical name (its `ir.Module.name`).
/// - `binding`: the build's `Binding`; only `mode`/`state_strategy`/`mem_tier` are read.
/// - Returns the derived module-name string. PURE string derivation — introduces no policy.
///   Total — never fails.
pub fn coexist_name(base: String, binding: Binding) -> String {
  let mode_suffix = case binding.mode {
    Safe -> ""
    Unsafe -> "_unsafe"
  }
  let state_suffix = case binding.state_strategy {
    Cell -> ""
    Threaded -> "_threaded"
  }
  let tier_suffix = case binding.mem_tier {
    Paged -> ""
    Atomics -> "_atomics"
    Nif -> "_nif"
  }
  base <> mode_suffix <> state_suffix <> tier_suffix
}

// ───────────────────────────── Phase-4: the tier → module map (§A.1, G5) ─────────────────────────────

/// Resolve a linear-memory trust tier (`MemTier`, keystone §B.1) to the `rt_mem` backend module
/// `emit_core` links for it. Keeping this map here — not in the codegen seam — is what makes a
/// tier a build-time module swap the emitter never sees (G5): `emit_core` reads only
/// `binding.mem_module`, never `mem_tier`.
///
/// - `tier`: the declared memory tier.
/// - Returns the Gleam→Erlang-mangled module name. `Paged` returns `safe_default().mem_module`
///   (D1 — the existing vetted `twocore@runtime@rt_mem` atom keeps its single home, never
///   re-spelled here); `Atomics`/`Nif` name the new tier modules (units 04/05), whose single home
///   is this map. Total — never fails.
pub fn mem_module_for(tier: MemTier) -> String {
  case tier {
    Paged -> safe_default().mem_module
    Atomics -> "twocore@runtime@rt_mem_atomics"
    Nif -> "twocore@runtime@rt_mem_nif"
  }
}

/// Resolve a funcref-table trust tier (`TableTier`) to its `rt_table` backend module (keystone
/// §B.1). There is no `nif` table tier, so no `table_module_for` result can violate
/// Safe-forbids-nif.
///
/// - `tier`: the declared table tier.
/// - Returns the Gleam→Erlang-mangled module name. `TablePaged` returns
///   `safe_default().table_module` (D1 — the vetted `twocore@runtime@rt_table` atom keeps its
///   single home); `TableEts`/`TableAtomics` name the new tier modules (unit 06), whose single
///   home is this map. Total — never fails.
pub fn table_module_for(tier: TableTier) -> String {
  case tier {
    TablePaged -> safe_default().table_module
    TableEts -> "twocore@runtime@rt_table_ets"
    TableAtomics -> "twocore@runtime@rt_table_atomics"
  }
}

// ───────────────────────────── Phase-4: tier→module coupling + the axis constructor (§A.2) ─────────────────────────────

/// Couple a binding's declared tiers to the runtime modules `emit_core` links (P5, G5). Sets
/// `mem_module := mem_module_for(mem_tier)` and `table_module := table_module_for(table_tier)` —
/// nothing else. This is the **single source** of that coupling: `compose` applies it and `link`
/// re-applies it, so the atom `emit_core` reads is always derived from the declared tier, never a
/// stale hand-set string.
///
/// - `binding`: any binding (its `*_tier` fields are authoritative; the `mem_module`/
///   `table_module` fields are (re)derived from them).
/// - Returns the binding with `mem_module`/`table_module` made coherent with the tiers.
///   Idempotent (`resolve_tiers(resolve_tiers(b)) == resolve_tiers(b)`) and total; touches no
///   policy field (`mode`, the five policy enums, `fuel_budget`, `safe_max_pages`, the non-tier
///   `*_module` names are all left unchanged).
pub fn resolve_tiers(binding: Binding) -> Binding {
  Binding(
    ..binding,
    mem_module: mem_module_for(binding.mem_tier),
    table_module: table_module_for(binding.table_tier),
  )
}

/// Compose the three build axes over a policy `base` (keystone §B.1, G3). Overrides
/// `state_strategy`/`mem_tier`/`table_tier` and — via `resolve_tiers` (the single coupler) — the
/// matching `mem_module`/`table_module`, so the declared tier and the linked module never diverge.
/// `compose` is the sanctioned path; a hand-build that sets only `mem_tier` and skips
/// `resolve_tiers` leaves `mem_module` stale and is caught by `validate_binding`. Every POLICY
/// field (`mode`, the five policy enums, `fuel_budget`, `safe_max_pages`, the non-tier `*_module`
/// names) is inherited from `base` unchanged — composition never mutates policy.
///
/// - `base`: the policy binding (`safe()`/`unsafe()`) whose posture is inherited.
/// - `state_strategy`/`mem_tier`/`table_tier`: the tier choices.
/// - Returns the composed `Binding`. Total; policy COHERENCE (Safe-forbids-nif, the atomics
///   reservation cap) is checked separately by `validate_binding/1`, so `compose` can express a
///   hand-built incoherent point for the gate to reject.
pub fn compose(
  base: Binding,
  state_strategy: StateStrategy,
  mem_tier: MemTier,
  table_tier: TableTier,
) -> Binding {
  resolve_tiers(
    Binding(
      ..base,
      state_strategy: state_strategy,
      mem_tier: mem_tier,
      table_tier: table_tier,
    ),
  )
}

// ───────────────────────────── Phase-4: the two headline profiles (§B/§C, G3) ─────────────────────────────

/// The **`portable`** profile (G3) — the runs-anywhere headline: tier-P on every axis over the
/// fail-closed Safe policy. `Threaded` instance-state (a purely-functional record threaded through
/// generated code, G1 — no process-dictionary instance-state cell, no OTP-native state), `Paged`
/// linear memory (immutable-binary, no native code), `TablePaged` table, and the Safe posture's
/// `bif` numerics (`num_module` inherited from `safe()`, tier-P). No `atomics`, no `ets`, no
/// `persistent_term`, no NIF, and no pdict *instance-state* cell — the Safe CPU-fuel counter and
/// host-policy cell (`MeterFuel` + `HostDenyAll`) are node-safe, process-local **tier-O policy
/// overlays** (BEAM builtins on every BEAM, not instance state; Safe permits tier P or O, never N
/// — P4), NOT the instance-state cell and deliberately NOT `MeterOff` (which would drop the CPU
/// bound). So a `portable` build links **zero** OTP-native or native-code state, is provably unable
/// to crash the node (G6), and loads on a bare BEAM.
///
/// The only difference from `safe()` is `state_strategy: Cell → Threaded` (the codegen-shape
/// switch unit 02 realises); `Paged`/`TablePaged` resolve to `safe_default()`'s own atoms, so
/// `mem_module`/`table_module`/`num_module` and all five Safe policy fields are byte-identical to
/// `safe()`. `validate_binding(portable())` is `Ok(portable())` (Safe + tier-P is coherent and
/// carries no atomics reservation). Total — never fails.
pub fn portable() -> Binding {
  compose(safe(), Threaded, Paged, TablePaged)
}

/// The **`ceiling`** profile (G3) — the performance posture: the `Unsafe` policy (aggressive
/// optimizer, `MeterOff`, open BIF/host gates, passthrough stdlib) composed with the tier-O
/// `Atomics` linear memory (O(1) process-local mutation, no custom native code, cannot crash the
/// node — the shipped performance lever, G8) over the `Cell` state strategy (the pdict cell — no
/// per-function record-threading overhead on the hot path) and a tier-O `TableAtomics` table.
///
/// **Requires a bounded cap (P6/§C).** `atomics` `fresh` pre-allocates to the effective max, so it
/// engages **only when the effective max ≤ the reserve cap** (`atomics_reserve_cap_pages`). On an
/// uncapped no-max module the eager reservation is 4 GiB, so the build is a **fail-closed
/// rejection** — `validate_binding`/`link` return `Error(AtomicsCapRequired)`, never a silent 4 GiB
/// pre-allocation and never a silent `paged` fallback. `ceiling()` inherits the default
/// `safe_max_pages` (`65536`), whose worst-case no-max reservation exceeds the reserve cap, so
/// `link(ceiling())` is **rejected until a bounded cap is supplied** — via `Binding(..ceiling(),
/// safe_max_pages: p)` with `p ≤ atomics_reserve_cap_pages`, or a module whose own declared `max`
/// is small enough (enforced at instantiate, where the module max is known). Defaulting to
/// `Atomics` (not the tier-N `Nif`, which *can* crash the node) keeps `ceiling` node-safe; the
/// absolute `Nif` ceiling is one Unsafe composition away — `compose(ceiling(), Cell, Nif,
/// TableAtomics)` — admitted precisely because the base is already `Unsafe`.
///
/// `validate_binding(Binding(..ceiling(), safe_max_pages: p))` (bounded `p`) is `Ok` (Unsafe admits
/// tier-O over a bounded memory). Total — never fails as a *constructor* (the cap is a link-gate
/// concern, not a construction failure).
pub fn ceiling() -> Binding {
  compose(unsafe(), Cell, Atomics, TableAtomics)
}

// ───────────────────────────── Phase-4: the fail-closed link gate + the sole seam (§D) ─────────────────────────────

/// The linker's fail-closed link errors (G6, P5, P6).
///
/// - `SafeForbidsNif`: a `Safe` binding named a tier-N (`Nif`) memory. Tier-N runs custom native
///   code that can crash the node, so it is Unsafe-only — the one hard constraint on the
///   otherwise-orthogonal `state_strategy × mem_tier × policy` space (G3/G6).
/// - `TierModuleMismatch`: the binding's `mem_module` disagrees with `mem_module_for(mem_tier)`
///   (P5) — the load-bearing field `emit_core` actually links was hand-set stale/incoherent with
///   the declared tier. Rejected fail-closed rather than silently linked, so a declared `mem_tier`
///   can never degrade to advisory-only while the seam links a different backend.
/// - `AtomicsCapRequired`: an `Atomics` binding whose Safe cap (`safe_max_pages`) is not bounded to
///   the node-safe reserve cap (`rt_mem_atomics.atomics_reserve_cap_pages`), so a no-max module
///   under it would eagerly pre-allocate past the ceiling (P6/§C). The atomics tier needs a
///   bounded max/cap; an uncapped one is rejected at link, never silently degraded or pre-allocated
///   at 4 GiB.
pub type LinkError {
  SafeForbidsNif
  TierModuleMismatch
  AtomicsCapRequired
}

/// Reject an incoherent binding fail-closed (G6/P5/P6, keystone §B.4), guarding the
/// **load-bearing** fields `emit_core` links. Three checks, in priority order:
/// 1. `Error(SafeForbidsNif)` iff the binding is `Safe` AND names a tier-N memory
///    (`b.mode == Safe && b.mem_tier == Nif`) — the one hard policy constraint (G6).
/// 2. `Error(TierModuleMismatch)` iff `b.mem_module != mem_module_for(b.mem_tier)` — a
///    stale/hand-set module that would let the declared tier be advisory-only while the seam links
///    a different backend (P5).
/// 3. `Error(AtomicsCapRequired)` iff `b.mem_tier == Atomics` and the tier-O reservation would
///    exceed the node-safe reserve cap for the worst-case no-max module — i.e.
///    `rt_mem_atomics.reservation(0, None, b.safe_max_pages, atomics_reserve_cap_pages)` is
///    `Error` (P6/§C). This is the link-decidable half of the atomics cap: the binding carries
///    `safe_max_pages` but NOT the compiled module's declared `min`/`max`, so this rejects an
///    over-cap *binding* (a `safe_max_pages` too large to bound a no-max module) and **defers** the
///    per-module refinement (a small declared `max` under a large Safe cap) to instantiate, where
///    `rt_mem_atomics.a_fresh` fail-closes on the actual reservation.
///
/// Every other composition of `state_strategy × mem_tier × policy` is admitted `Ok(b)` unchanged —
/// Safe+`Paged`, Safe+`Atomics` (bounded cap), Unsafe+any tier (Nif included, over a bounded
/// atomics cap where applicable), either state strategy, any table tier (there is no `Nif` table
/// tier). Pure predicate — no runtime dispatch, no ambient authority (D3a); reads only build-time
/// fields.
///
/// - `b`: the binding to validate (its `*_module` fields should be `resolve_tiers`-derived).
/// - Return: `Ok(b)` for a coherent binding, else the first failing `LinkError` above. Total.
pub fn validate_binding(b: Binding) -> Result(Binding, LinkError) {
  let module_coherent = b.mem_module == mem_module_for(b.mem_tier)
  let atomics_capped = case b.mem_tier {
    Atomics ->
      // Worst-case no-max module (min 0, max None) against the binding's Safe cap: if even that
      // fits the reserve cap the binding is admissible; the per-module refinement is enforced at
      // instantiate by `rt_mem_atomics.a_fresh` (documented above).
      result.is_ok(rt_mem_atomics.reservation(
        0,
        None,
        b.safe_max_pages,
        rt_mem_atomics.atomics_reserve_cap_pages,
      ))
    _ -> True
  }
  case b.mode, b.mem_tier, module_coherent, atomics_capped {
    Safe, Nif, _, _ -> Error(SafeForbidsNif)
    _, _, False, _ -> Error(TierModuleMismatch)
    _, _, _, False -> Error(AtomicsCapRequired)
    _, _, _, _ -> Ok(b)
  }
}

/// The **sole** `Binding → Instance` seam (P5): validate `binding` fail-closed (`validate_binding`),
/// re-derive its tier modules with `resolve_tiers` (the single coherent coupling, so `emit_core`
/// links the atom the declared tier names), then assemble the `Instance`. Every run-ABI/CLI/profile
/// caller routes through here; there is no other sanctioned path from a `Binding` to an `Instance`.
///
/// The Safe/tier-P profile constructors are structurally valid, so `link(safe())`/`link(portable())`
/// always succeed. `link(ceiling())` is `Error(AtomicsCapRequired)` until a bounded cap is supplied
/// (P6/§C — `link(Binding(..ceiling(), safe_max_pages: p))` with bounded `p` succeeds); a hand-built
/// `Safe + Nif` is `Error(SafeForbidsNif)`; a stale `mem_module` is `Error(TierModuleMismatch)`.
///
/// - `binding`: the build-time profile to link.
/// - Return: `Ok(Instance)` for a coherent binding, else the `LinkError` from `validate_binding`.
///   `instantiate/1` keeps its total `Binding -> Instance` signature (Phase-1/2/3 contract) but is
///   self-validating, so even a direct call cannot fail open. Total in the `Result` sense.
pub fn link(binding: Binding) -> Result(Instance, LinkError) {
  binding
  |> validate_binding
  |> result.map(resolve_tiers)
  |> result.map(instantiate)
}
