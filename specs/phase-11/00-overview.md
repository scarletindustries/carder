# Phase 11 — Self-contained output (`--link`)

> **Status:** scoped + critiqued + reconciled, awaiting review. No code yet. This overview follows the
> fixed skeleton in [`../03-phase-workflow.md`](../03-phase-workflow.md) §2. Decisions are `O1–O8` (the
> letter series continues from Phase 10's `N`; `O1` = keystone, `O8` = honest scope); **units** are
> `P11-01 … P11-06` (separately numbered).
>
> **⚠ [`RECONCILIATION.md`](RECONCILIATION.md) is AUTHORITATIVE and OVERRIDES this overview on conflict.**
> The scoping fan-out (3 framings) + adversarial critique (5 lenses) verified the approach by *executing
> the merge on OTP 29* and corrected the linker algorithm (the biggest: `fun M:F/A` function-value
> captures are first-class — R4/R5). Read order: this overview (for the goal/shape) → `RECONCILIATION.md`
> (for the binding decisions R1–R17 + the revised 6-unit split) → the unit doc.
>
> **All prior-phase decisions and the permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8)
> still hold.** Baseline entering: 1827 tests / 0 fail · `gleam build` zero warnings · `gleam format`
> clean · WASM conformance 46,529 / 1,768 / 0 (Safe ≡ Unsafe, every tier).

---

## §0. Where this phase sits

This is a **backend / packaging** phase. It does **not** touch the frontend, the IR, the optimizer, or
any runtime *semantics*. It adds one new backend capability — a **whole-program Core-Erlang linker** —
behind an optional `--link` flag, plus the architectural prerequisite that makes linking well-defined:
a **clean runtime/compiler layer split**. It realizes the deployment story that
[`../01-status.md`](../01-status.md) §5 currently records as *not self-contained*: today an emitted
`.beam` is a thin module of `call 'twocore@runtime@rt_*':…` references that only run on a node where the
whole `twocore` app is already loaded. `--link` merges the runtime dependency closure into the generated
module and strips dead code, yielding a **single `.beam` that loads and runs on a bare Erlang/OTP node**.

It is distinct from — and complementary to — the deferred single-`.beam` runtime-dispatch binding
(**B1**, [`../02-roadmap.md`](../02-roadmap.md) §D): **B1 is about runtime *selection*** (one module
picks its tier at instance time); **`--link` is about runtime *inclusion*** (bake the chosen runtime
into the artifact). This phase does B1-independent inclusion for a single chosen build.

---

## §1. Goal & acceptance

**Goal.** Add an optional `--link` mode to the compile-to-BEAM path that produces a **single
self-contained `.beam`** — the generated module with its entire runtime dependency closure merged in and
dead code eliminated — loadable and `apply`-able on a bare Erlang/OTP install with nothing else on the
code path. The **default (non-`--link`) output is unchanged and byte-identical** to today (D3d — thin
module + external runtime).

**Acceptance table** (owned by the capstone, unit 04):

| Area | Must demonstrate |
|---|---|
| Single artifact | `to-beam-wasm --link app.wasm app.beam` produces **one** `.beam`; loading it via `erl -pa <dir containing only that file>` and calling `app:<export>(args)` returns the correct result — on a node with **no** `twocore@*`/`gleam@*` beams reachable. |
| Bare-node proof | The capstone **actually boots** a clean `erl` (isolated `-pa`) and runs the linked module — measured, not asserted (mirrors the "runs 100k iters in constant space" precedent). |
| Default unchanged | Without `--link`, emitted `.core`/`.beam` is **byte-identical** to the current pipeline. |
| Result-identical | Linked output is value-identical (by bit pattern) and trap-identical to the in-process path, across every **pure-BEAM** `(mode × state_strategy × mem_tier)` (`--link` supports tier P/O; tier-N excluded, §O4). |
| Conformance neutral | The full spec suite stays `fail=0`; the linker is exercised as an alternate emission path over a representative corpus, result-identical. |
| Clean layering | The runtime's transitive dependency closure reaches **zero** compiler modules (grep-verified: no `twocore/frontend`, `twocore/middle`, `twocore/backend` reachable from any `rt_*`). |
| D3a preserved | The merged `.core` contains **no** data-driven `apply` and **no** remote call outside the fixed OTP-ambient allowlist (§O3). |

**Honest scope** (= decision O8, stated here and restated in §2):
- **tier-P and tier-O only.** `--link` + tier-N (`nif`) is a link-time rejection — a NIF cannot be
  merged into a `.beam`, and its C ceiling doesn't exist yet.
- **"Bare node" = a standard Erlang/OTP install.** The linker merges only the `twocore`/`gleam`
  closure; calls to OTP/ERTS modules (`erlang`, `lists`, `maps`, `binary`, `math`, `ets`, `atomics`, …)
  stay as remote calls — those are present on every node by definition and are **not** inlined.
- **Single generated module + runtime only.** Linking several generated WASM modules into one artifact
  (multi-module link) is a follow-up, not this phase.
- **Not an escript, not an OTP release** — specifically the single-`.beam` form (the two bundle forms
  were considered and declined for this phase).
- **No change** to the default emission, the IR, the optimizer, or runtime semantics.

---

## §2. Decisions (O1–O8)

> Each decision is **frozen** for this phase. If you believe one is wrong, **raise it with the planner
> BEFORE building — do not silently diverge.** By convention O1 is the keystone; O8 is honest scope.

**O1 (keystone) — The runtime becomes a clean, self-contained layer with a well-defined link closure.**
Today the layering is inverted: at least one `rt_*`/`instance`/`profiles` module imports
`twocore/middle/ir_opt` (for `OptLevel`), and runtime modules import `twocore/ir` (for
`TrapReason`/`FuncType`/`ValType`). The keystone (a) **relocates the middle/backend types the runtime
references** (starting with `OptLevel`) into a low-dependency module so **no runtime module imports
`twocore/frontend|middle|backend`**; (b) establishes whether `twocore/ir` is already a clean leaf the
runtime may depend on, or must be split into `ir/types` (shared) + `ir` (compiler-only) — see the open
seam in §3; (c) **freezes the *link-closure manifest*** — the deterministic, enumerated set of modules
`--link` pulls (`runtime/rt_*` + `instance`/`profiles`/`link`/`porffor_abi` + the reachable `gleam@*` +
the runtime FFI `.erl` shims) — and the **OTP-ambient allowlist** (the modules left as remote calls).
This is the load-bearing new thing; everything downstream builds against the frozen manifest.

**O2 — The linker works at the Core Erlang level: merge into one module by function-name mangling +
reachability DCE.** Obtain Core for every closure module (our generated module: `.core` text →
`core_scan`/`core_parse` we already FFI; Gleam/FFI modules: `compile:file(F,[to_core,…])`). Compute
reachability from the generated module's exports across the closure, **stopping at the OTP-ambient
allowlist**. Mangle every in-closure `M:F/A` to a fresh local `'M__F'/A` (full module atom in the name ⇒
no collisions), rewrite in-closure remote calls to local calls, concatenate the reachable defs into one
module named for the generated module, and export only the original public exports (+ synthesized
`module_info`). Unreached functions are simply never included (that **is** the DCE).

**O3 — No ambient authority survives the merge (D3a).** The merge must neither introduce nor leave any
data-driven `apply(Var, …)`; every in-closure call becomes a static local call, and the only remote
calls remaining are to the fixed OTP-ambient allowlist. A structural test greps the merged `.core` to
prove it. This is the security invariant of the new path and extends the existing codegen-security test.

**O4 — `--link` is tier-restricted and fail-closed.** `--link` + `mem_tier = nif` is rejected at link
time (typed error, non-zero exit). Atomics/ETS shims **are** mergeable (they are pure Erlang calling the
OTP-ambient `atomics:`/`ets:`). Any `-on_load`/NIF-load directive in the closure is a hard error
(there are none in tier P/O). All existing posture fail-closed rules (uncapped atomics, `Safe`+`nif`,
etc.) are unchanged and still apply *before* linking.

**O5 — The linked artifact is behavior-identical to the in-process path.** Same values (by bit
pattern), same traps, same `TrapReason`. The merge is a pure packaging transform; if a linked module
ever diverges from the normal pipeline on any corpus input, the linker is wrong. Proven by the capstone
differential on a bare node.

**O6 — One new `build_beam` entry + a `--link` CLI flag; default off.** A new `build_beam` function
takes the generated Core + the resolved link closure and returns the merged `.beam`. `--link` is a flag
on the `.beam`-producing verbs (`to-beam-wasm`, and `to-beam` for a `.core` input); **absent ⇒ today's
behavior** (fail-closed toward the unchanged default). `--link` is orthogonal to the posture/tier flags.

**O7 — Deterministic, reproducible output.** Merge order, the mangling scheme, and DCE are deterministic
so identical input yields an identical `.beam` (byte-stable for diffing/testing). No wall-clock/random
inputs to the merge.

**O8 — Honest scope.** As stated in §1: tier P/O only (tier-N rejected); "bare node" = standard OTP,
OTP modules stay remote; single generated module + runtime; a `.beam`, not an escript/release; no change
to default emission, IR, optimizer, or semantics.

---

## §3. Dependency DAG & freeze milestones

```
        O1 keystone ──«RT-LAYER-FROZEN»──┬──▶ O2 linker ──«LINKER-IFACE-FROZEN»──┬──▶ O3 CLI + build_beam
        (layer split + manifest          │    (merge + mangle + DCE + D3a)        │
         + OTP-ambient allowlist)        │                                        └──▶ O4 capstone (bare-node
                                         └────────────────────────────────────────────  proof + differential + docs)
```

**Freeze milestones:**

| Milestone | Produced by | Unblocks |
|---|---|---|
| `«RT-LAYER-FROZEN»` — the clean runtime layer boundary + the enumerated **link-closure manifest** + the **OTP-ambient allowlist** (compiling, runtime reaches zero compiler modules, byte-identical default output) | O1 | O2, O3, O4 |
| `«LINKER-IFACE-FROZEN»` — the linker's public signature (`link(generated_core, closure) -> Result(merged_core/beam, LinkError)`) so the CLI and capstone build against it in parallel | O2 | O3, O4 |

**Waves:** Wave 0 = O1 (lands green, default byte-identical). Wave A = O2 (the engine) with O3 (CLI)
building against the frozen signature. Wave B = O4 (capstone).

**Open seams — ALL RESOLVED by the critique** (see [`RECONCILIATION.md`](RECONCILIATION.md)):
1. **Core-surgery mechanism (the crux) → `cerl` FFI, CONFIRMED BY EXECUTION** (R1). Acquire Core from the
   shipped `.beam` via `beam_lib` `debug_info(core_v1)` (primary), `to_core` fallback. Not a Gleam reader.
2. **Split `twocore/ir`? → NO, FROZEN** (R2). It imports only `gleam/list` + `gleam/option` (clean leaf,
   94 importers); the runtime depends on it directly and DCE strips the unused machinery.
3. **OTP-ambient allowlist → mechanically derived + fail-closed against a fixed OTP set** (R7). Measured
   floor is larger than the sketch below (the merged `gleam_stdlib` adds `string`/`io`/`io_lib`/
   `io_lib_format`/`base64`/`rand`/`uri_string`).

---

## §4. File-ownership map (one owner per file, D1)

| Unit | Owns / creates | Deliberate cross-file reaches (documented in `state.md`) |
|---|---|---|
| **O1** keystone | new low-dep types module (relocated `OptLevel` etc.); new `link_manifest.gleam` (closure set + ambient allowlist); new `test/.../link_layer_freeze_test.gleam` | `middle/ir_opt.gleam` + `runtime/instance.gleam` (move `OptLevel`); possibly split `ir.gleam` → `ir/types.gleam` (seam #2) |
| **O2** linker | new `backend/beam_link.gleam` (orchestration) + `src/twocore_linker_ffi.erl` (the `cerl` merge, if seam #1 = FFI) | reuses `backend/build_beam.gleam` FFI helpers (read-only) |
| **O3** CLI + driver | `src/twocore.gleam` (the `--link` flag); a new linked entry in `backend/build_beam.gleam` | `runtime/profiles.gleam` (tier-N + `--link` fail-closed check) |
| **O4** capstone | `test/.../linked_selfcontained_test.gleam` (bare-node harness) + the corpus differential; `docs/phase-11-linking.md`; updates `../01-status.md` §5 | the single registration/wiring point only |

`backend/beam_link.gleam` is named to avoid clashing with the existing `runtime/link.gleam` (imports).

---

## §5. How to claim & complete

Standard loop ([`../03-phase-workflow.md`](../03-phase-workflow.md) §7 + §9): read
[`../state.md`](../state.md); claim a unit (set `in-progress (name)`); for O1 freeze the milestone and
land green with default output byte-identical; build behind the frozen signatures; satisfy the
per-unit Definition of Done (spec-cited tests, doc comments, `gleam format --check` clean, `gleam build`
zero warnings, the unit's suite green); update `state.md` with what the unit leaves; the manager
QA-gates and commits. The capstone (O4) proves the acceptance table on a bare node, then this phase is
compacted into [`../01-status.md`](../01-status.md) §3 and `phase-11/` is removed.
