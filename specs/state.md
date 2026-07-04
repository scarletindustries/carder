# Implementation State — the live ledger

> The swarm's shared ledger for **the phase currently in flight**. Before claiming work, read it;
> after finishing, update it. It is a *working* file, not a history archive — completed phases are
> compacted into [`01-status.md`](01-status.md) once proven, and this file resets to the template
> below for the next phase.
>
> **How to use this file:** [`03-phase-workflow.md`](03-phase-workflow.md) §7.
> **Where we are:** [`01-status.md`](01-status.md) · **What's next:** [`02-roadmap.md`](02-roadmap.md)
> · **Architecture:** [`00-high-level.md`](00-high-level.md)

**Legend — unit status:** `unclaimed` · `in-progress (name)` · `blocked (on …)` · `done`
**Legend — freeze milestone:** a published, compiling type/signature stub that unblocks downstream
units. Announce it here the moment it lands (`FROZEN ✓` / `published ✓`).

---

## Current phase

**Two phases scoped, neither in flight yet — awaiting review; no code.** Phase 11 (`--link`) and Phase 12
(typed bindings) are **independent** (11 = runtime *inclusion* into one `.beam`; 12 = typed host-language
*access* to a `.beam`); either may land first, and they compose (a linked `.beam` + typed bindings).
Recommended order: **Phase 11 first** (it settles the runtime/compiler layer split), then Phase 12.

---

### ▶ Phase 11 — Self-contained output (`--link`) — *scoped + critiqued + reconciled*

Overview: [`phase-11/00-overview.md`](phase-11/00-overview.md). **AUTHORITATIVE:**
[`phase-11/RECONCILIATION.md`](phase-11/RECONCILIATION.md) (decisions `R1–R17`; overrides the overview on
conflict). Goal: an optional `--link` flag on `to-beam-wasm` that merges the runtime dependency closure
into the generated module (whole-program Core-Erlang merge via `cerl` FFI + DCE), producing a **single
self-contained `.beam`** that runs on a bare Erlang/OTP node. Default output stays byte-identical.
Decisions `O1–O8`; units `P11-01 … P11-06`.

The fan-out + 5-lens adversarial critique **executed the merge on OTP 29** (feasible, GO) and corrected
the linker algorithm — chiefly that `fun M:F/A` function-value captures (332 remote + 43 local in the
closure) are first-class for both reachability and rewrite (R4/R5), the `instantiate/N` seed is a DCE
root (R6), the manifest must include `gleam_stdlib.erl` (R8), the allowlist is mechanically derived
(R7), and the D3a check is structural over `cerl` not a text grep (R9).

Phases 1–10 are complete and proven on `main` — see [`01-status.md`](01-status.md) §3.

**Baseline entering Phase 11:** 1827 gleam tests / 0 fail · `gleam build` zero warnings · `gleam format`
clean · WASM conformance **46,529 pass / 1,768 skip / 0 fail** (Safe ≡ Unsafe, every
`state_strategy × mem_tier`) · JS-on-BEAM 52 / 0 / 3.

### Freeze milestones

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«RT-LAYER-FROZEN»` — runtime reaches zero compiler modules (`OptLevel` relocated to the leaf `twocore/opt_level`; `ir` NOT split) | P11-01 | `FROZEN ✓` | P11-02 |
| `«CLOSURE-FROZEN»` — link-closure manifest + acquisition method + mechanically-derived OTP-ambient allowlist + mangle/mergeability invariants + drift test | P11-02 | `unclaimed` | P11-03 |
| `«LINKER-IFACE-FROZEN»` — `beam_link.link_program` public signature + `LinkError` variants | P11-03 | `unclaimed` | P11-04, P11-06 |
| `«BARE-NODE-HARNESS-PROVEN»` — isolation harness proven against a hand-authored trivial `.beam` (gate: fails when a `twocore@` module is reachable) | P11-05 | `unclaimed` | P11-06 (L2) |

### Units

| Unit | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|
| **P11-01** Keystone: runtime layer split (`OptLevel`→leaf; `ir` not split, R2/R3) | `done` | — | Runtime reaches zero compiler modules (grep-verified); default output byte-identical; the ~10-file reach set repointed. |
| **P11-02** Link-closure manifest + allowlist + acquisition + invariants (R1/R7/R8/R12/R15) | `unclaimed` | `«RT-LAYER-FROZEN»` | Frozen closure set (incl. `gleam_stdlib.erl`), per-module Core-acquisition method, mechanically-derived allowlist, `__`-free + mergeability invariants + drift test. |
| **P11-03** The `cerl` linker engine (R4/R5/R6/R9/R10/R11) | `unclaimed` | `«CLOSURE-FROZEN»` | `beam_link.link_program` + `twocore_linker_ffi.erl`: 3-node-class rewrite incl. fun-captures, funref+`instantiate` reachability roots, DCE, deterministic `from_core`, built-in fail-closed structural D3a check; in-process smoke differential green. |
| **P11-04** CLI `--link` (`to-beam-wasm` only) + `build_beam` entry + fail-closed gate (R13/R14) | `unclaimed` | `«CLOSURE-FROZEN»` (ambient allowlist), `«LINKER-IFACE-FROZEN»` (sig) | `--link` default off (byte-identical); tier-N + import-bearing + `on_load` rejected at the CLI/linker boundary. |
| **P11-05** Bare-node isolation harness, proven first (test-first) | `unclaimed` | — | `twocore_linked_boot_ffi.erl`: scrubbed fresh `erl`, in-child `code:which` isolation gate; self-test proves the gate actually gates. |
| **P11-06** Capstone | `unclaimed` | all above | **PHASE 11 PROVEN.** L1 in-process linked≡non-linked differential (full corpus × mode × state × tier P/O) + L2 bare-node differential (import-free subset) + constant-space + determinism byte-check + D3a corpus assertion; `docs/phase-11-linking.md`; `01-status.md` §5. |

### Landing log

- **P11-01** — 1865 tests (was 1863, +2 `link_layer_freeze_test`), conformance unchanged, 0 new warnings, format clean, byte-identical default output. `OptLevel { OptNone Baseline Aggressive }` relocated to the dependency-free leaf **`twocore/opt_level`** (type now at `twocore/opt_level.OptLevel`); `ir` NOT split (R2). `«RT-LAYER-FROZEN» ✓`.
  - **Deliberate cross-file reaches (P11-01-owned):** `src/twocore/middle/ir_opt.gleam` (deleted the `OptLevel` type block, now imports it from `twocore/opt_level`), `src/twocore/runtime/instance.gleam:74` + `src/twocore/runtime/profiles.gleam:53` (repointed imports — removes the runtime's last compiler-module import), and the 7 test files that name the constructors (`opt_iface_freeze_test`, `profiles_test`, `differential_test`, `phase10_capstone_test`, `baseline_test`, `memory_differential_test`, `aggressive_test`).
  - **Spec-drift note for downstream units:** the unit doc's per-file table for `phase10_capstone_test` omitted a `ir_opt.OptLevel` **type** reference (line 259, `level: ir_opt.OptLevel`); its `opt_level` import needed `type OptLevel` in addition to the `Baseline`/`OptNone` constructors. All other files matched the doc.

---

### ▶ Phase 12 — Typed host-language bindings (Erlang / Elixir / Gleam) — *scoped + critiqued + reconciled*

Overview: [`phase-12/00-overview.md`](phase-12/00-overview.md). **AUTHORITATIVE:**
[`phase-12/RECONCILIATION.md`](phase-12/RECONCILIATION.md) (decisions `R1–R25`; overrides the overview on
conflict). Goal: emit companion typed source files (`.gleam`/`.erl`/`.ex`) giving a native-typed API to
instantiate a compiled module and call its exports — hiding the raw-bit-pattern run-ABI behind
`Int`/`Float`/`BitArray`, traps as `Result`. The `.beam` is unchanged; a **self-contained** droppable
artifact requires Phase-11 `--link` (R21). Decisions `P1–P8`; units `P12-01 … P12-06`. **Threaded
(tier-P, Paged) + export-only this phase** (Cell, import-bearing, mutable tiers deferred).

The fan-out + 5-lens critique **compiled + called all three languages on OTP 29** (GO, no showstopper) and
added R14–R25 — must-fix before freeze: `describe` on the **lowered** module (R17); non-finite floats are a
**sum type** `Finite|NonFinite` (plain `Float` raises on NaN/Inf — R18); the **Stateless/Threaded
two-shape API** resolving the arity-vs-Instance tension (R19); module atom is `twocore@wasm@<base>` not the
file stem (R14); host-name sanitization + cross-language binding-atom collision (R15/R16); reject mutable
mem/table tiers under `--bindings` (R20). Confirmed by experiment: R4 (tuple), R11 (pure value threading,
no process).

### Freeze milestone

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«IFACE-DESC-FROZEN»` — `Iface`/`ExportSig`/`StateModel`/`GeneratedFile`/`IfaceError` + `describe/2` (on the lowered module, transitive state-reaching) + the uniform `emit_<lang>(Iface) -> List(GeneratedFile)` signature | P12-01 | P12-02, P12-03, P12-04, P12-05, P12-06 |

### Units

| Unit | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|
| **P12-01** Keystone: the `Iface` descriptor + value-ABI mapping (R1–R4, R9, R13) | `unclaimed` | — | `backend/iface.gleam`; `describe/2` fail-closed on Cell/import-bearing; `ExportSig` arity mirrors `emit_core` exactly; default output unchanged. |
| **P12-02** Gleam emitter — the headline (R5–R9) | `unclaimed` | `«IFACE-DESC-FROZEN»` | `emit_gleam_bindings.gleam`: a typed `.gleam` + a tiny `.erl` catch shim (Gleam can't catch in-language). |
| **P12-03** Erlang emitter (R4–R9) | `unclaimed` | `«IFACE-DESC-FROZEN»` | `emit_erlang_bindings.gleam`: one `-spec`'d `.erl`, traps caught in-language (no shim). |
| **P12-04** Elixir emitter (R4–R9) | `unclaimed` | `«IFACE-DESC-FROZEN»` | `emit_elixir_bindings.gleam`: one `@spec`'d `.ex`, `try/rescue` (no shim). |
| **P12-05** CLI `--bindings`/`--out` + folder driver (R8, R12) | `unclaimed` | `«IFACE-DESC-FROZEN»` | `--bindings <langs> --out <dir>` on `to-beam-wasm` (requires `--threaded`); default off ⇒ byte-identical; lowers once, hands one module to `emit_core`+`describe`. |
| **P12-06** Capstone (R6, R10, R11) | `unclaimed` | all above | **PHASE 12 PROVEN.** Per-language compile+call differential (real toolchains) across the type matrix + threaded state; term-ABI oracle for non-Int results; Elixir best-effort skip; `docs/phase-12-bindings.md`; `01-status.md` §5. |

### Landing log

_(none yet)_

---

## Template (copy this block when the next phase starts)

> Phase N — «title». Goal & honest scope: see the phase overview. Decisions: `Q1–Q8` (continue the
> letter series — Phase 12 used `P`; `Q1` = keystone, `Q8` = honest scope). All prior-phase decisions
> and the invariants in [`03-phase-workflow.md`](03-phase-workflow.md) §8 still hold.

### Freeze milestones

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«X-FROZEN»` — … | 01 | `unclaimed` | … |

### Units

| Unit | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|
| **01** Interface freeze (keystone) | `unclaimed` | — | … |
| **…** | `unclaimed` | … | … |
| **N** Capstone | `unclaimed` | all above | **PHASE N PROVEN.** … |

### Landing log

_(one line per landing: `unit — N tests (was M, +K), conformance p/s/f, 0 warnings, format clean, byte-identical`)_
