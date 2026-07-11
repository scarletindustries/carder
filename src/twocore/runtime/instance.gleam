//// The runtime binding — the second keystone (the calling convention, D3).
////
//// This file defines **how generated code reaches the runtime**. It is a BUILD-TIME
//// descriptor consumed by `emit_core`'s binding chokepoint (D3b): it carries the
//// Erlang MODULE NAME implementing each runtime layer. The `Binding` is **never
//// embedded in generated code** (D3d) — Phase-1 generated functions are pure and
//// thread no runtime record. See `specs/phase-1/00-overview.md` D2/D3.
////
//// ## The Phase-1 binding strategy: link-time-fixed binding (B2)
////
//// `emit_core` resolves each runtime op at codegen time into a **direct**
//// `call '<impl-module>':'<fn>'/<arity>(...)`, where `<impl-module>` is read from the
//// `Binding` chosen by the build profile. This is the fast path (no per-call
//// indirection, no runtime closure on hot numeric ops) and the simplest correct thing.
////
//// Two security invariants hold (and are tested in unit 08):
//// - **D3a — no ambient authority.** Generated code never performs a data-driven
////   `apply(Mod, F, Args)` where `Mod` comes from program/attacker data. Every runtime
////   reference resolves to a fixed, build-controlled `twocore@runtime@*` module.
//// - **D3b — one binding chokepoint.** Every runtime reference (numerics, traps,
////   host, charge — and later memory/tables/stdlib) is routed through this one table,
////   so switching later to per-instance dynamic dispatch (B1) or whole-program
////   monomorphisation (B3) is a localised change here, never scattered through the
////   emitter.
////
//// ## The Phase-1 calling convention (so units 08 and 09 agree exactly)
////
//// Module names below are the Gleam→Erlang-mangled names: a Gleam module path
//// `twocore/runtime/rt_num` maps to the Erlang module `twocore@runtime@rt_num`
//// (path `/` → `@`); public function names are emitted verbatim with arity = the
//// parameter count (D2).
////
//// | IR construct                | Emitted Core Erlang (schematic)                                                            |
//// |-----------------------------|--------------------------------------------------------------------------------------------|
//// | `Num(IAdd(W32), [a, b])`    | `call '<num_module>':'i32_add'(A, B)`                                                       |
//// | `Num(IDivS(W32), [a, b])`   | `call '<num_module>':'i32_div_s'(A, B)` → `{ok,X}`/`{error,R}`; emitter `case`s, raises on error |
//// | `Trap(IntDivByZero)`        | `call '<trap_module>':'raise'('int_div_by_zero')`                                           |
//// | `CallHost(cap, name, args)` | `call '<host_module>':'call_host'(Cap, Name, [Args…])` (the deny-all host raises)           |
//// | `Charge(cost, body)`        | `call '<meter_module>':'charge'(Cost)` then `body`                                          |
////
//// The mapping `NumOp → rt_num function name` is owned by unit 08 (the chokepoint) but
//// **must match the frozen `rt_num` signatures** — that is the whole point of freezing
//// them in `rt_num.gleam`.
////
//// ## The two fates of `CallHost` (resolved post-review)
////
//// `ir_lower` (unit 11) runs *before* `emit_core` and decides what each `CallHost`
//// becomes:
//// - a `CallHost` that resolves to an **`own` stdlib** function is rewritten by
////   `ir_lower` into a direct runtime call — `emit_core` emits
////   `call '<stdlib_module>':'<fn>'(Args…)`. A vetted stdlib call does **not** go
////   through the deny-all host.
//// - a `CallHost` to a **genuine host import** is left as-is — `emit_core` emits
////   `call '<host_module>':'call_host'(Cap, Name, [Args…])`, which under the Safe
////   profile's `deny_all` host raises (fail-closed).
////
//// ## `rt_bif` is a build-time gate, not a runtime layer
////
//// `rt_bif` (the BEAM-function allowlist) is consulted by `ir_lower` (unit 11) at
//// **build time** when resolving `CallHost`/BIF targets; it is **not** in the
//// `Binding` record and **not** called by generated code. Its gate shape is therefore
//// frozen with unit 11, not here — which is why `Binding` carries `stdlib_module` but
//// no `bif_module`.
////
//// ## Phase-3 policy extension (F7, `«UNSAFE-PROFILE-FROZEN»`)
////
//// `Binding` gains six explicit **policy** fields the middle-end and backend read to realise
//// Safe vs Unsafe: `opt_level` (which optimizer passes run), `meter` (enforcing fuel vs off),
//// `fuel_budget` (the CPU seed), `bif_gate`, `stdlib` (mode), and `host_policy`. `OptLevel`
//// is imported from `middle/ir_opt` (an acyclic edge — `ir_opt`/its leaf `ir_opt/pass` import
//// only `ir`); `fuel_budget`'s Safe default is read from `runtime/rt_meter` (also acyclic —
//// `rt_meter` imports neither `instance` nor `ir_opt`), the single source of the budget.

import twocore/opt_level.{type OptLevel, Baseline}
import twocore/runtime/rt_meter

/// The global execution mode (high-level §6). Phase 3 makes `Unsafe` real (the aggressive
/// optimizer + no metering + open gates + passthrough stdlib), realised via the `Binding`
/// policy fields below and constructed only by `profiles.unsafe()`.
///
/// - `Safe`: the fail-closed profile (deny-all host, full validation, allowlisted
///   BIFs, enforcing metering). Permits trust tiers P or O, never N.
/// - `Unsafe`: the aggressive/passthrough profile (Phase 3).
pub type Mode {
  Safe
  Unsafe
}

/// Whether CPU fuel metering ENFORCES a budget (F5).
///
/// - `MeterFuel`: enforcing — `charge` advances the seeded per-instance budget and raises
///   `FuelExhausted` on exhaustion (Safe). `ir_lower` inserts `Charge` nodes.
/// - `MeterOff`: no metering — `ir_lower` inserts NO `Charge` nodes at all (F5 zero-overhead;
///   the emitted `.core` has no charge calls, and no `seed_fuel` is emitted). Unsafe.
pub type MeterMode {
  MeterFuel
  MeterOff
}

/// The BEAM-function allowlist gate posture (F6).
///
/// - `BifAllowlist`: the build-time allowlist gate is enforced fail-closed (Safe).
/// - `BifOpen`: the allowlist gate is removed — full BUILD-CONTROLLED BEAM access (Unsafe).
///   Even open, generated code never does a data-driven `apply(Mod, F, Args)` with `Mod` from
///   program data (D3a): "open" widens the build-time allow-set, it adds no ambient authority.
pub type BifGate {
  BifAllowlist
  BifOpen
}

/// Which standard-library implementation shared stdlib calls resolve to (F6). This is the
/// *mode* — orthogonal to the `stdlib_module` field, which names the `own` impl module.
///
/// - `StdlibOwn`: the vetted `rt_stdlib` implementations, reached via `stdlib_module` (Safe).
/// - `StdlibPassthrough`: route shared functions to BEAM stdlib/BIFs where faster + trusted
///   (Unsafe) — OBSERVABLY IDENTICAL to `own` on every shared function (a differential unit 06
///   owns). Distinct from `stdlib_module`, which still names the module the call targets.
pub type StdlibMode {
  StdlibOwn
  StdlibPassthrough
}

/// The host/capability dispatch policy (F4/F7).
///
/// - `HostDenyAll`: every host import is denied at run time (Safe, fail-closed).
/// - `HostWhitelist(allow)`: only the listed `#(capability, name)` pairs are permitted.
/// - `HostOpen`: all host imports permitted (Unsafe). Still no ambient authority (D3a) — the
///   allow-set is build-controlled, never a data-driven module/atom from program input.
pub type HostPolicy {
  HostDenyAll
  HostWhitelist(allow: List(#(String, String)))
  HostOpen
}

/// How generated code reaches mutable instance state (the memory handle, mutable globals, the
/// table) — the tier-P/O state sub-axis (G1). A codegen-shape choice realised in `emit_core`'s
/// state-access seam (G5), NOT a module swap through the binding. Orthogonal to `mem_tier`: the
/// strategy picks the *function family* the seam calls (`store` vs `t_store`) and whether
/// generated functions thread a state record; the tier picks the *module*.
///
/// - `Cell`: tier-O, the Phase-2/3 default. The seam emits `call '<state/mem/table_module>':
///   '<op>'(...)` against the per-process **process-dictionary cell** (`rt_state`); generated
///   function arities are unchanged; `instantiate/0` seeds the cell and returns `'ok'`.
/// - `Threaded`: tier-P, new. The seam threads a purely-functional **instance-state record**
///   (`rt_state.InstanceState`) through generated code — every state-reaching function takes the
///   record as a parameter and RETURNS the (possibly updated) record (the uniform-threading rule
///   §10, §A.3). No process dictionary; no OTP-native state; the "runs-anywhere" build.
pub type StateStrategy {
  Cell
  Threaded
}

/// The linear-memory trust tier (G2). Selects which `rt_mem` backend the linker links, all
/// behind one uniform interface (§B.2). Orthogonal to `state_strategy` (above) and to policy (G3).
///
/// - `Paged`: tier-P (Phase-2). Immutable-binary rebuild-on-write; universal, sparse-friendly.
/// - `Atomics`: tier-O (new, unit 04). O(1) process-local mutation via Erlang `atomics` — no
///   custom native code, cannot crash the node. The shipped performance lever. `grow` is the
///   sharp edge (fixed size at creation → pre-allocate to the effective max; requires a bounded
///   max/cap — an uncapped no-max module is a fail-closed link-time rejection, never a silent
///   4 GiB pre-allocation or paged fallback, §B.2).
/// - `Nif`: tier-N (new, unit 05, **Unsafe-only**). Raw O(1) native memory; the ceiling;
///   **forbidden in Safe** (G6, §B.4). Interface + reference; the C impl may be documented-deferred.
pub type MemTier {
  Paged
  Atomics
  Nif
}

/// The funcref-table trust tier (G2). Every variant is node-safe (tier P or O) — there is no
/// `nif` table tier, so `table_tier` cannot violate Safe-forbids-nif.
///
/// - `TablePaged`: tier-P (Phase-2) — immutable sparse `Dict` table (the existing `rt_table`).
/// - `TableEts`: tier-O (new, unit 06) — an `ets`-backed table.
/// - `TableAtomics`: tier-O (new, unit 06) — an `atomics`-indexed table.
pub type TableTier {
  TablePaged
  TableEts
  TableAtomics
}

/// Which compiled runtime module implements each runtime layer.
///
/// Each field holds a Gleam→Erlang-mangled module name (e.g.
/// `"twocore@runtime@rt_num"`). `emit_core` emits `call '<field>':'<fn>'(...)` against
/// these. This record is a **build-time input** to the emitter, never embedded in or
/// threaded through generated code (D3d).
///
/// Fields:
/// - `mode`: the global execution mode this binding realises.
/// - `num_module`: implements the numeric ops (`rt_num`).
/// - `trap_module`: implements trap raising (`rt_trap`).
/// - `host_module`: implements the host/capability boundary (`rt_host`).
/// - `meter_module`: implements metering / fuel (`rt_meter`).
/// - `stdlib_module`: implements the `own` standard library (`rt_stdlib`).
/// - `mem_module`: implements linear memory — load/store/size/grow/init_data (`rt_mem`).
/// - `table_module`: implements funcref tables + `call_indirect` dispatch (`rt_table`).
/// - `state_module`: implements the per-instance cell holder + mutable globals
///   (`rt_state`). `GlobalGet`/`GlobalSet` route here; the cell ABI is
///   `«CELL-STATE-ABI-FROZEN»` (the tier-O process-dictionary convention).
/// - `js_runtime_module`: implements the JS runtime boundary (`rt_js`, Phase-8 unit 05, K6).
///   A `CallHost("js", op, args)` routes to a BUILD-FIXED function in THIS module via a literal
///   `case` in `emit_core` (never `apply(Mod,Fn,Args)` from data, D3a). Defaulted to the
///   `twocore@runtime@rt_js` stub; the real `rt_js` (all JS semantics) is the frontend team's
///   deliverable (see `specs/phase-8/HANDOFF-arc-frontend.md §4`). Inert for any module that
///   never emits a `"js"` `CallHost` (conformance-neutral, K7).
/// - `safe_max_pages`: the build-time Safe max-pages cap (E3) `emit_core` bakes into the
///   `instantiate/0` entry's `rt_mem:fresh(min, max, safe_cap)` call, so `memory.grow`
///   cannot allocate past it even when the module declares `max_pages: None`. A FINITE
///   default (`65536`, the i32 hard cap) makes the declared max govern for conformance;
///   unit 11 tunes it for the Safe profile's resource bound.
///
/// The Phase-3 **policy** fields (F7) the middle-end and backend read to realise Safe vs
/// Unsafe (each an EXPLICIT opt-in — the Safe posture is the fail-closed default):
/// - `opt_level`: which passes the optimizer driver runs (F1/F7) — read at the one
///   `optimize(module, binding.opt_level)` call site (unit 09).
/// - `meter`: enforcing fuel (`MeterFuel`) vs off (`MeterOff`) (F5). Under `MeterOff`,
///   `ir_lower` inserts no `Charge` nodes at all.
/// - `fuel_budget`: the seed for `rt_meter.seed_fuel` under `MeterFuel` (F5) — the instance's
///   CPU bound, the SINGLE budget channel `instantiate/0` bakes in. Ignored under `MeterOff`
///   (no seed emitted). Mirrors `safe_max_pages` as a per-instance resource bound.
/// - `bif_gate`: allowlist (fail-closed) vs open (F6).
/// - `stdlib`: `own` vs passthrough (F6) — the resolution *mode*, distinct from
///   `stdlib_module` (which names the `own` impl module the call still targets).
/// - `host_policy`: deny-all / whitelist / open (F4).
///
/// The Phase-4 **trust-tier** axes (G1/G2) — orthogonal to policy, composed by the linker:
/// - `state_strategy`: `Cell` (tier-O, the pdict cell — Phase-2/3 default) vs `Threaded`
///   (tier-P, the record-threading runs-anywhere build). A **codegen-shape** sub-axis realised
///   in `emit_core`'s state-access seam (G5), NOT a module swap through this record.
/// - `mem_tier`: the DECLARED linear-memory tier (`Paged`/`Atomics`/`Nif`) the linker (unit 07)
///   maps to `mem_module` via `resolve_tiers`. `emit_core` links `mem_module` (never `mem_tier`,
///   keeping it tier-agnostic, G5); `mem_tier` is the advisory the fail-closed gate checks
///   against `mem_module` (§B.4). `Nif` is Unsafe-only (G6).
/// - `table_tier`: the DECLARED funcref-table tier (`TablePaged`/`TableEts`/`TableAtomics`) the
///   linker maps to `table_module`. Every variant is node-safe (no `nif` table tier).
///
/// Phase-2 added the memory/table/instance-state module fields; because binding lives in this
/// one record, extending it with policy and the trust tiers is a clean addition, not a retrofit.
/// The cell↔threaded *state* tier is a codegen-shape sub-axis (`emit_core`'s state-access seam),
/// NOT a module swap through this record (overview E1).
pub type Binding {
  Binding(
    mode: Mode,
    num_module: String,
    trap_module: String,
    host_module: String,
    meter_module: String,
    stdlib_module: String,
    mem_module: String,
    table_module: String,
    state_module: String,
    js_runtime_module: String,
    safe_max_pages: Int,
    /// The documented, spec-aligned RUNTIME page cap for a 64-bit (`Idx64`) memory (memory64,
    /// I4/S9). We do NOT reserve 2^64 bytes: the `paged` backend grows on demand, so this is a
    /// **trap boundary**, not a reservation — `memory.grow` beyond it returns `-1`, and an
    /// access beyond the *current* size traps `MemoryOutOfBounds` (the spec's `assert_trap`).
    /// DISTINCT from validate's DECLARABLE type maximum of 2^48 pages (= 2^64 bytes, spec
    /// §2.5 / the memory64 proposal); this is the smaller IMPLEMENTATION cap. Default 2^32 pages
    /// = 2^48 bytes = 256 TiB (S9 — a sparse trap boundary the paged backend never allocates).
    /// Ignored for `Idx32` memories (so 32-bit output stays byte-identical). P6-08 pins the exact
    /// constant + `rt_mem` addressing; `atomics`/`nif` fail closed for an over-cap 64-bit memory.
    mem64_max_pages: Int,
    // ── Phase-3 policy fields (F7) ──────────────────────────────────────────
    opt_level: OptLevel,
    meter: MeterMode,
    fuel_budget: Int,
    bif_gate: BifGate,
    stdlib: StdlibMode,
    host_policy: HostPolicy,
    /// Opt-in UNCHECKED linear-memory trust (lever 3), a per-build performance toggle for a
    /// TRUSTED, self-contained guest (e.g. a JS engine) that never legitimately OOB-traps. When
    /// `True`, EVERY memory-0 load/store routes through the bounds-check-free `*_unchecked` seam
    /// instead of the checked/raising path — a large win on memory-heavy code — but ONLY on a
    /// BEAM-memory-SAFE tier (`Paged` or `Atomics`), where an out-of-bounds access is CONTAINED to
    /// a wrong value (an absent paged chunk reads zero; `atomics:get` is ERTS-bounds-checked). It is
    /// NEVER honored on `Nif` (tier-N): a raw C deref past the buffer could crash the node, so
    /// tier-N stays on the checked/raising path even when `trust_memory` is `True`.
    ///
    /// The documented, explicit tradeoff: under this mode an out-of-bounds access on a safe tier
    /// yields a WRONG VALUE instead of a `MemoryOutOfBounds` trap (spec-incorrect but node-safe).
    /// Default `False` (fail-closed) — the checked path is BYTE-IDENTICAL to a build without this
    /// field; engaging it requires explicitly naming `--trust-memory`. Orthogonal to the safety
    /// profile (composable with any base) and to `mem_tier` (it gates ON the tier, never swaps it).
    trust_memory: Bool,
    /// Opt-in Core-Erlang JOIN-INLINING pass (lever 6), a per-build compile-time toggle for a
    /// large guest whose lowered control flow is a deep nest of single-use `letrec` join
    /// functions. 2core lowers every wasm block/if/switch continuation to a
    /// `letrec 'J'/n = fun(P…) -> Fbody in Inner` entered by `apply 'J'/n(A…)`; a fall-through-only
    /// block yields a join reached from EXACTLY ONE exit, so the fun allocation + local call is pure
    /// overhead. When `True`, `emit_core` beta-reduces every NON-RECURSIVE, applied-EXACTLY-ONCE join
    /// away (splicing its body at the sole call site), shrinking the emitted Core and the resulting
    /// `.beam` (QuickJS's interpreter lowers to ~1096 such nested joins, ~280 deep). It is a
    /// SEMANTICS-PRESERVING transform (a standard single-use inline over fresh-SSA params — no
    /// capture, loops/multi-exit joins are left intact), NOT a policy or tier lever.
    ///
    /// Default `False` (fail-closed): the DEFAULT emitted Core is BYTE-IDENTICAL to a build without
    /// this field (the pass does not run), so the conformance/golden corpus is trivially unperturbed.
    /// Engaged only by NAMING `--inline-joins` or a profile that sets it (`engine()`).
    /// Orthogonal to the safety profile and every tier axis (composable with any base).
    inline_joins: Bool,
    // ── Phase-4 trust-tier axes (G1/G2) ─────────────────────────────────────
    state_strategy: StateStrategy,
    mem_tier: MemTier,
    table_tier: TableTier,
  )
}

/// The Phase-1 Safe profile binding: deny-all host, `bif` numerics, fuel metering, and
/// the `own` stdlib, all wired to the default `twocore@runtime@rt_*` modules.
///
/// This is the **fail-closed default** (D4/D9): the default profile IS the safe one —
/// there is no way to obtain an unsafe binding by omission. Its Phase-3 posture is the fully
/// Safe one: `Baseline` optimizer, enforcing `MeterFuel` with the finite
/// `rt_meter.default_fuel_budget`, allowlisted BIFs, `own` stdlib, and deny-all host.
///
/// Returns a fully-populated `Binding` with `mode: Safe`. Total — never fails.
pub fn safe_default() -> Binding {
  Binding(
    mode: Safe,
    num_module: "twocore@runtime@rt_num",
    trap_module: "twocore@runtime@rt_trap",
    host_module: "twocore@runtime@rt_host",
    meter_module: "twocore@runtime@rt_meter",
    stdlib_module: "twocore@runtime@rt_stdlib",
    mem_module: "twocore@runtime@rt_mem",
    table_module: "twocore@runtime@rt_table",
    state_module: "twocore@runtime@rt_state",
    // The JS runtime boundary (Phase-8 unit 05, K6). Defaulted to the `rt_js` STUB; a
    // `CallHost("js", op, args)` routes here via a build-fixed literal `case` in `emit_core`
    // (D3a — never `apply` from data). Inert unless the module emits a `"js"` CallHost (K7).
    js_runtime_module: "twocore@runtime@rt_js",
    // The finite Safe max-pages cap baked into `rt_mem:fresh` (E3). `65536` = the i32 hard
    // cap (2^16 pages = 4 GiB), so the module's DECLARED max governs for conformance; unit
    // 11 lowers it to a real Safe resource bound.
    safe_max_pages: 65_536,
    // The memory64 runtime page cap (S9/I4): 2^32 pages = 2^48 bytes = 256 TiB — a documented,
    // spec-aligned trap boundary the `paged` backend never allocates (it grows on demand), NOT a
    // reservation. Distinct from validate's 2^48-page DECLARABLE limit. No Phase-1..5 module uses
    // an `Idx64` memory, so this is conformance-neutral; P6-08 pins the exact constant + citation.
    mem64_max_pages: 4_294_967_296,
    // ── Phase-3 Safe posture (F7). Every field is the fail-closed choice. ──
    opt_level: Baseline,
    meter: MeterFuel,
    fuel_budget: rt_meter.default_fuel_budget,
    bif_gate: BifAllowlist,
    stdlib: StdlibOwn,
    host_policy: HostDenyAll,
    // Lever 3 opt-in, OFF by default (fail-closed): the checked/raising memory path stays
    // byte-identical to a build without this field. Set `True` only by naming `--trust-memory`.
    trust_memory: False,
    // Lever 6 opt-in, OFF by default (fail-closed): the join-inlining pass does not run, so the
    // emitted Core is byte-identical to a build without this field. Set `True` only by naming
    // `--inline-joins` or via `profiles.engine()`.
    inline_joins: False,
    // ── Phase-4 trust-tier posture (G1/G2). The maximally node-safe default (D4): the
    // tier-O `Cell` state strategy + the tier-P `Paged`/`TablePaged` backends — byte-identical
    // to Phase-2/3. Leaving it (tier-P `portable` / tier-N `ceiling`) requires NAMING a profile
    // (unit 07); tier-N (`Nif`) additionally requires Unsafe (§B.4).
    state_strategy: Cell,
    mem_tier: Paged,
    table_tier: TablePaged,
  )
}
