# Where we are today

> The single "current state" reference. This replaces the per-phase folders (`phase-1/` … `phase-10/`),
> which have been removed — their decisions are now in the code, the tests, and the invariants in
> [`03-phase-workflow.md`](03-phase-workflow.md). For the architecture & vision read
> [`00-high-level.md`](00-high-level.md); for what's *not* built read [`02-roadmap.md`](02-roadmap.md);
> for the live work ledger read [`state.md`](state.md).
>
> **Last consolidated:** 2026-07-04, after Phase 10.

---

## 1. One-paragraph summary

2core is a **working** multi-frontend compiler that lowers WebAssembly into a shared, language-neutral
IR and emits **Core Erlang**, so the result runs **compiled and preemptively on the BEAM** — not
interpreted. As of Phase 10 it covers the **complete WebAssembly 2.0 fixed-width surface** (WASM 1.0 +
reference types + bulk memory + multiple memories + memory64 + SIMD + cross-module function linking +
exception handling), runs in two named modes (**Safe** sandbox / **Unsafe** near-native), across a
**trust-tier ladder** (tier-P pure "runs-anywhere", tier-O OTP-native, tier-N NIF-skeleton), carries a
**trust-neutral IR memory optimizer**, and **reaches the JS-on-the-BEAM goal**: real Porffor-compiled
JavaScript runs on the BEAM byte-identically to `porf run`.

**Live metrics (authoritative, from `gleam test` on `main`):**

| | |
|---|---|
| Gleam tests | **1827 pass / 0 fail** |
| Build | `gleam build` **zero warnings**, `gleam format --check` clean |
| WASM spec conformance | **46,529 pass / 1,768 skip / 0 fail** — identical under Safe **and** Unsafe, and `fail=0` under every shipped `(state_strategy × mem_tier)` combo |
| JS-on-BEAM (Porffor 0.61.13 → 2core → BEAM) | **52 pass / 0 fail / 3 skip** over a 55-program corpus (all 3 skips are Porffor's own `-0`/closure bugs, reproduced byte-for-byte — they bound Porffor, not 2core) |
| Every skip | categorized (never false-green); `fail=0` is an absolute invariant |

---

## 2. The pipeline, as built

```
 SOURCE                       FRONTEND (fe_wasm)              SHARED IR            MIDDLE-END                 BACKEND                    RUNTIME (linked)
 .wasm  ─┐                 ┌ decode ─┐                      ┌───────────┐   ┌ ir_lower (policy) ─┐   ┌ emit_core ──────┐        ┌ rt_num / rt_simd / rt_trap ┐
 .wat   ─┼──▶ frontend/wasm┤ wat     ├─▶ validate ─▶ lower ─▶│   ir.gleam │──▶│ ir_opt (optimizer) │──▶│ core_erlang AST │──▶ .core │ rt_exn / rt_ref / rt_state │──▶ .beam (loaded)
 (Porffor JS→.wasm)        └ (text)  ┘   (security)          │  (ANF, D6) │   └────────────────────┘   │ core_printer    │        │ rt_mem[_atomics|_nif]      │
                                                             └───────────┘                            └ build_beam ─────┘        │ rt_table[_ets|_atomics]    │
                                                                                                        (binding chokepoint)     │ rt_host / rt_stdlib / link  │
                                                                                                                                 └ rt_meter / rt_bif (build)  ┘
```

Every arrow is an independently-invokable stage with a CLI verb (§6). The IR (`src/twocore/ir.gleam`)
is the seam between frontend and middle-end and has a canonical, round-trippable `.ir` textual form
(`ir/printer.gleam` + `ir/parser.gleam`). **`emit_core` is the single binding chokepoint** — the only
place that knows which concrete runtime a build links (decision D3b).

---

## 3. What each phase delivered (condensed history)

All ten phases are **done and proven** on `main`. This is the compacted ledger; the per-phase decision
codes (`D/E/F/G/H/I/J/M/N` and the `R/S/T` reconciliations) now live in the code and tests, with the
*permanent* ones lifted into [`03-phase-workflow.md`](03-phase-workflow.md) §4.

| Phase | Delivered | Proven at close |
|---|---|---|
| **1 — Core platform** | The keystones: the language-neutral IR + `.ir` textual form; the Core-Erlang AST + pretty-printer + `build_beam` FFI driver; the WASM decoder; `rt_num` (90-fn tier-P numeric-fidelity reference); `full` WASM validation + stack-elim/SSA lowering; `emit_core`; `ir_lower` + the Safe profile + the per-stage CLI. Real `.wasm` → BEAM end-to-end (add/sum_to/fib), 100k-iter tail loop in constant space. | Acceptance corpus green; spec runner 1699/1400/0 |
| **2 — Complete WASM 1.0** | Linear memory (`rt_mem` `paged` + `rebuild` oracle), tables + `call_indirect` (3-fault fail-closed), mutable globals, full floats/conversions, and **mutable instance state** via the tier-O **`cell`** (process-dictionary) strategy. `load→instantiate→invoke` run-ABI; Safe max-pages cap. | ~509 tests; conformance image refreshed |
| **3 — "Fast"** | The shared IR optimizer `ir_opt` (`baseline` both-modes + `aggressive` Unsafe-only: const-fold/prop/DCE/inline), the **Unsafe** profile (passthrough stdlib, open BIF gate, no metering), and **enforcing** CPU fuel (`FuelExhausted`). B3 monomorphization (Safe.beam ≠ Unsafe.beam). Honest benchmark: Safe was **~76× slower** than hand-written Erlang → motivated Phase 4. | 674 tests; 15,747/411/0 under both modes |
| **4 — "Free-standing"** | The **trust-tier ladder**: tier-P **`threaded`** state (a purely-functional instance record — the runs-anywhere build, 0 native + 0 pdict), tier-O memory (`atomics` O(1)) + tables (`ets`/`atomics`), tier-N memory (`nif` interface + skeleton, Safe-forbidden). `link/1` as the sole validated Binding→Instance seam. | 906 tests; `fail=0` for every `(strategy × tier)` |
| **5 — "The complete WASM engine"** | The full standardized surface **minus SIMD**: reference types (funcref/externref, `rt_ref` forge-proof values), bulk memory/table ops, multiple memories, **memory64 decode+validate only**, non-function imports + the `spectest` host + `link.gleam` fail-closed instantiation, and a first-class **WAT text parser**. First IR growth since Phase 2, kept language-neutral & byte-identical by default. | 1195 tests; pass **+5,776** → 21,525/1,257/0 |
| **6 — "Complete WASM 2.0"** | The three Phase-5 deferrals: **SIMD** (`rt_simd`, ~236 lane ops emulated bit-exact lane-wise — faithful, not hardware, no speed claim), the **memory64 runtime** (i64 addressing, documented 2³²-page/256-TiB cap), and **cross-module wasm→wasm function linking** (`CallImport` node dispatching through a build-constructed closure capability — never `erlang:apply`). | 1491 tests; pass **+25,004** → 46,529/1,768/0 (largest movement in project history: the 59 `simd_*.wast` lit up) |
| **7 — "JS on the BEAM via Porffor"** | **WASM exception handling** lowered to BEAM-native `try/catch/raise` (`rt_exn`, both legacy & modern encodings → one neutral inline-handler IR), the **Porffor-ABI `rt_host` shim** (4 build-fixed intrinsics), and a **JS-subset conformance harness** judged differentially vs `porf run`. Reached the platform's original goal — bounded & measured by Porffor's ~⅓-of-ECMA coverage. | 1690 tests; JS 52/0/3; EH 153 asserts ×3 profiles |
| **8 — Native JS IR (arc frontend track)** | The **second road to JS-on-BEAM**: a BEAM-native value layer in the IR (term construction, native closures `MakeClosure`/`CallClosure`, maps/objects, the term↔numeric boxing bridge, the `rt_js` fail-closed boundary, guarded native arithmetic) so a from-scratch JS frontend (reusing arc's parser + scope analysis) can emit 2core IR directly — making closures/GC/maps/bignums *native* and bypassing Porffor's closure wall. IR value-layer units shipped; the frontend + real `rt_js` are a **separate team's** deliverable per [`HANDOFF-arc-frontend.md`](HANDOFF-arc-frontend.md). *(Not tracked in the old `state.md`; kept in project memory.)* | ~1734 tests; WASM byte-identical |
| **9 — The memory optimizer** | The middle-end memory-dataflow passes (deferred all the way from Phase 3): **MemorySSA + linear-memory alias analysis** (`mem_ssa`), **store→load forwarding + redundant-load elimination** (`mem_forward`), **dead-store elimination** (`mem_dse`). Trap-preserving ⇒ trust-neutral ⇒ run at Baseline ⇒ every tier & both modes win. No new IR nodes, no runtime touch. | 1783 tests; ~3–4× faster on paged |
| **10 — The memory optimizer, completed** | The three Phase-9 deferrals: **LICM** (hoist pure loop-invariant work to a preheader), **cross-control-flow MemorySSA** (forwarding/RLE/DSE survive `If`/`Block`/`Switch` via a may-clobber gate), and **range-based bounds-check elimination via loop versioning** (an unchecked fast loop guarded by a runtime range-proof, else the checked slow loop — values *and* traps preserved). First memory opt since Phase 4 to grow the runtime ABI (unchecked access, paged+atomics; nif stays checked). | **1827 tests**; LICM ~3.5×, BCE ~1.1× on paged |

---

## 4. The runtime surface, as built

Two orthogonal axes, both realized at **compile time** via **B3 monomorphization** (distinct `.beam`s
sharing identical `twocore@runtime@rt_*` module names; the single-`.beam` runtime-dispatch **B1** is
still deferred — see [`02-roadmap.md`](02-roadmap.md)). `profiles.gleam` exposes
`safe()` / `unsafe()` / `portable()` / `ceiling()`; **Safe is the fail-closed default**.

**Mode axis (security):**
- **Safe** — sandbox: `own` vetted stdlib + a tiny BIF allowlist, `deny_all` host by default, metering **on**, tiers **P or O only** (tier-N is a link-time rejection), `baseline` optimizer only.
- **Unsafe** — near-native: `passthrough` stdlib, `open` BIF gate, metering **off**, tiers may be O/N, `baseline`+`aggressive` optimizer.

**Trust-tier axis (whose native code runs / can it crash the node):**

| Layer | tier-P (pure, runs-anywhere) | tier-O (OTP-native) | tier-N (NIF) |
|---|---|---|---|
| Memory | `rt_mem` `paged` (default) | `rt_mem_atomics` O(1), Safe-permitted, requires `--cap` | `rt_mem_nif` (interface + skeleton; Unsafe-only; **C impl deferred**) |
| Tables | `rt_table` `TablePaged` (default) | `rt_table_ets` / `rt_table_atomics` | — |
| State | `rt_state` `threaded` (record, 0 native) | `rt_state` `cell` (pdict, default) | — |
| Numerics / SIMD | `rt_num` / `rt_simd` (always tier-P) | — | deferred |

Always-linked tier-P layers: `rt_num`, `rt_simd`, `rt_trap`, `rt_exn`, `rt_ref`, `rt_state`, `rt_meter`.
Capability boundary: `rt_host` (+ `rt_stdlib`, `link`). Build-time-only gate: `rt_bif` (despite the
`rt_` prefix, **not** a runtime layer, not in `Binding`).

---

## 5. The optimizer, as built (`ir_opt`)

`ir_opt.optimize/2` runs `pipeline(opt_level)` to a fixpoint. It sits **upstream of tier + mode
selection**, so a sound pass speeds up *every* tier and *both* modes with no per-tier code.

- **Baseline** (both modes — trust-neutral, trap-preserving): const-fold (bit-exact to `rt_num`) → copy/const-prop → algebraic identities (safe integer only) → const-if → block/label-simplify → DCE → dead-let, **plus** the memory passes: `forwarding_pass` (store→load + RLE), `dead_store_pass` (DSE), `licm_pass` (LICM), `bce_pass` (range-based BCE via loop versioning).
- **Aggressive** (Unsafe-only, strict superset = `baseline ++ aggressive`): `charge_elide` (sound only under `Aggressive ⟹ MeterOff`), `inline` (capture-avoiding, acyclic-guard, node-ceiling bounded).

Soundness rests on `ir/effect.gleam` (the conservative purity/effect classifier — E6) and absolute
**trap-preservation**; both are in the invariants list ([`03-phase-workflow.md`](03-phase-workflow.md) §4).

---

## 6. CLI (every stage is independently invokable)

`gleam run -- <verb>`. Stage verbs: `decode`, `validate`, `lower` (aliases `to-ir`/`ir`), `ir-lower`,
`opt`, `emit`, `to-core`, `to-beam` (alias `build`), `to-beam-wasm`. End-to-end: `run`, `exec`
(`-n/--repeat COUNT`).

Posture flags on `run`/`to-core`/`emit`/`to-beam-wasm`: base `--unsafe`|`--portable`|`--ceiling`, plus
`--threaded`, `--tier paged|atomics|nif`, `--table-tier paged|ets|atomics`, `--cap PAGES`. `opt` takes
`--unsafe` only. Incoherent postures (`Safe`+`nif`, uncapped `atomics`/`ceiling`) fail closed (non-zero
exit). Example: `gleam run -- run test/twocore/conformance/corpus/add.wasm add 3 5` → `8`.

---

## 7. Source-tree map

```
src/twocore.gleam                         CLI dispatch (arg parsing + file IO only)
src/twocore/pipeline.gleam                top-level driver glue; per-stage error mapping
src/twocore/ir.gleam                      the shared language-neutral IR (ANF) — the keystone
src/twocore/ir/effect.gleam               purity/effect classifier (optimizer soundness rests here)
src/twocore/ir/printer.gleam              canonical lossless .ir printer (inter-stage contract D7)
src/twocore/ir/parser.gleam              .ir textual parser (round-trips with the printer)
src/twocore/frontend/wasm/decode.gleam    untrusted .wasm bytes → AST
src/twocore/frontend/wasm/wat.gleam       WASM text-format frontend (lexer + parse_module/parse_script)
src/twocore/frontend/wasm/validate.gleam  full WASM validation — the security boundary
src/twocore/frontend/wasm/lower.gleam     validated WASM → shared IR (stack-elim/SSA)
src/twocore/frontend/wasm/ast.gleam       decoded WASM module model
src/twocore/middle/ir_lower.gleam         the one middle-end POLICY pass (capability/stdlib/metering)
src/twocore/middle/ir_opt.gleam           optimizer entry (optimize/2 + pipeline/1)
src/twocore/middle/ir_opt/pass.gleam      Pass type, combinators, fixpoint driver (leaf module)
src/twocore/middle/ir_opt/baseline.gleam  trust-neutral Baseline passes
src/twocore/middle/ir_opt/aggressive.gleam Unsafe-only passes
src/twocore/middle/ir_opt/mem_ssa.gleam   MemorySSA + linear-memory alias analysis (Phase 9)
src/twocore/middle/ir_opt/mem_forward.gleam store→load forwarding + RLE (Phase 9)
src/twocore/middle/ir_opt/mem_dse.gleam    dead-store elimination (Phase 9)
src/twocore/middle/ir_opt/loop_analysis.gleam loop-invariance primitives (Phase 10)
src/twocore/middle/ir_opt/mem_clobber.gleam memory-clobber oracle for cross-CF MemorySSA (Phase 10)
src/twocore/middle/ir_opt/licm.gleam       loop-invariant code motion (Phase 10)
src/twocore/middle/ir_opt/bce.gleam        range-based bounds-check elimination (Phase 10)
src/twocore/backend/emit_core.gleam       IR → Core Erlang AST — the binding chokepoint
src/twocore/backend/core_erlang.gleam     Gleam-native Core Erlang AST
src/twocore/backend/core_printer.gleam    Core Erlang pretty-printer → .core text
src/twocore/backend/build_beam.gleam      .core text → in-memory .beam, loaded into the VM
src/twocore/runtime/instance.gleam        the Binding (calling-convention descriptor, D3)
src/twocore/runtime/profiles.gleam        named profiles + the link/1 Binding→Instance seam
src/twocore/runtime/link.gleam            fail-closed instantiation/import contract
src/twocore/runtime/rt_num.gleam          numeric fidelity chokepoint (tier-P bif)
src/twocore/runtime/rt_simd.gleam         SIMD lane-op chokepoint (tier-P, emulated lane-wise)
src/twocore/runtime/rt_trap.gleam         Safe-mode trap surface (tier-P, cannot crash node)
src/twocore/runtime/rt_exn.gleam          tagged-exception runtime (Phase-7 EH; raises, never crashes)
src/twocore/runtime/rt_ref.gleam          forge-proof reference value model (term-layer)
src/twocore/runtime/rt_state.gleam        instance state (cell pdict default; threaded record tier-P)
src/twocore/runtime/rt_meter.gleam        fuel/metering seam (process-local charge)
src/twocore/runtime/rt_mem.gleam          linear memory — paged (tier-P default) + rebuild oracle
src/twocore/runtime/rt_mem_atomics.gleam  linear memory — atomics (tier-O)
src/twocore/runtime/rt_mem_nif.gleam      linear memory — nif (tier-N; skeleton; Unsafe-only)
src/twocore/runtime/rt_table.gleam        funcref table + call_indirect dispatch (paged default)
src/twocore/runtime/rt_table_ets.gleam    funcref table — ETS (tier-O)
src/twocore/runtime/rt_table_atomics.gleam funcref table — atomics (tier-O)
src/twocore/runtime/rt_host.gleam         per-instance capability boundary for host imports
src/twocore/runtime/rt_stdlib.gleam       minimal Safe own standard library
src/twocore/runtime/rt_bif.gleam          Safe BIF allowlist gate (BUILD-TIME only; not a runtime layer)
src/twocore/runtime/rt_js.gleam           JS runtime boundary — STUB (real impl is the frontend team's)
src/twocore/runtime/porffor_abi.gleam     pure Porffor (f64,i32) typed-value ABI
```

Docs (measured writeups, kept): `docs/phase-{3,4,9,10}-benchmark.md`, `docs/phase-{5,6}-surface.md`,
`docs/js-on-the-beam.md`, `docs/wasm-conformance.svg`.

---

## 8. Conformance & the categorized residual

The pinned WASM spec suite runs differentially (Tier-A: expected values baked in the `.wast`; Tier-B:
a `wasmtime`/`wast2json`/rebuild-oracle engine), held across the full `(mode × state_strategy ×
mem_tier)` matrix — every combo byte-identical, `fail=0` everywhere. Toolchain pins: Porffor 0.61.13,
Node 22, wabt 1.0.41, wasmtime 46.0.1 (see `vendor.sh` + `PIN`).

The **1,768 skips are all categorized** (`residual_audit_test` fails red if any skip matches no
enumerated bucket). The buckets map directly onto [`02-roadmap.md`](02-roadmap.md):

- **~1,088** — cross-module funcref-in-elem-segment init (`table_copy.wast` verifier): a deeper
  cross-module feature than the `CallImport` direct dispatch Phase 6 landed.
- **~511** — SIMD *text-format* assertions the WAT parser can't read (the binary SIMD path proves them e2e).
- **remainder** — genuinely out-of-scope proposals: GC-proposal reftypes, extended-const,
  `assert_exhaustion`, and post-2.0 proposal text. `memory64.wast`/`linking.wast` are file-level
  WAT-parser parse-skips (the features themselves are proven by authored in-scope backstops).
