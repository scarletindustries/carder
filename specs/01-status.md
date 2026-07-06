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
JavaScript runs on the BEAM byte-identically to `porf run`. As of Phase 11 an optional **`--link`** flag
emits a **single self-contained `.beam`** — the generated module with its whole runtime closure merged
in — that loads and runs on a **bare Erlang/OTP node** (§5).

**Live metrics (authoritative, from `gleam test` on `main`):**

| | |
|---|---|
| Gleam tests | **2111 pass / 0 fail** |
| Build | `gleam build` **zero warnings**, `gleam format --check` clean |
| WASM spec conformance | **47,734 pass / 683 skip / 0 fail** — identical under Safe **and** Unsafe, and `fail=0` under every shipped `(state_strategy × mem_tier)` combo |
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

Every arrow is an independently-invokable stage with a CLI verb (§7). The IR (`src/twocore/ir.gleam`)
is the seam between frontend and middle-end and has a canonical, round-trippable `.ir` textual form
(`ir/printer.gleam` + `ir/parser.gleam`). **`emit_core` is the single binding chokepoint** — the only
place that knows which concrete runtime a build links (decision D3b).

---

## 3. What each phase delivered (condensed history)

All fifteen phases are **done and proven** on `main`. This is the compacted ledger; the per-phase decision
codes (`D/E/F/G/H/I/J/M/N/O/P/Q` and the `R/S/T` reconciliations) now live in the code and tests, with the
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
| **11 — Self-contained output (`--link`)** | A **whole-program Core-Erlang linker** behind an optional `--link` flag on `to-beam-wasm` (`beam_link.link_program` over the `cerl` FFI `twocore_linker_ffi.erl`, pinned OTP 29): acquire every `twocore@`/`gleam@`/FFI closure member's Core (`beam_lib` `debug_info(core_v1)`), reachability-DCE from the exports **+ `instantiate/N`** across calls/applies/**`fun M:F/A` captures**, mangle to local `'M__F'/A`, rewrite all in-closure remotes/captures to local, deterministic `from_core` → **one self-contained `.beam` that runs on a bare OTP node**. Prereq: a clean runtime/compiler **layer split** (`OptLevel`→leaf, runtime reaches zero compiler modules). tier-P/O only (tier-N/import-bearing/`on_load` are fail-closed link-time rejections); **D3a preserved** (no data-driven `apply`, no off-allowlist remote — structural `cerl` check refuses to emit); default output **byte-identical**. §5. | **1922 tests**; linked ≡ non-linked (bit/trap-identical) over corpus × mode × state × tier P/O, in-process **and** on an actually-booted bare `erl`; deterministic (link-twice byte-identical) |
| **12 — Typed host-language bindings (`--bindings`)** | Alongside the `.beam`, emit **companion typed source files** (`.gleam`/`.erl`/`.ex`) giving a native-typed API over a compiled module: one language-neutral **`Iface` descriptor** (`iface.describe` on the lowered+optimized module — the transitive state-reaching closure decides the host surface) rendered by three sibling emitters + the `--bindings <langs> --out <dir>` folder driver. Value ABI: i32/i64 ⇄ signed `Int`, f32/f64 ⇄ a `Finite|NonFinite` sum type (NaN/±Inf bit-exact), v128 ⇄ 16-byte binary, refs ⇄ opaque handle, multi-value ⇄ tuple, trap ⇄ `Result`/tagged-tuple caught structurally on `{wasm_trap,_}`. Two-shape API (Stateless pure file vs Threaded pure-value `Instance`); Gleam two-file drop + `.erl` catch-shim + README, Erlang/Elixir catch in-language (Elixir zero `Elixir.*` runtime deps, best-effort). Threaded/export-only/pure-value-tier this phase; the `.beam` is **unchanged** & default output **byte-identical**; composes with `--link` for a self-contained typed artifact. §5. | **1978 tests**; every binding **compiled by its real toolchain** (`gleam build`/`erlc`/`elixirc`) and **called**, bit-identical to the in-process oracle across the full type matrix + threaded state + a genuine trap; Elixir best-effort (skips cleanly if absent); determinism byte-checked; conformance unchanged 46,529/1,768/0 |
| **13 — WebAssembly tail calls (`return_call`/`return_call_indirect`)** | The tail-call proposal (`0x12`/`0x13`) end to end — decode + WAT + validate (result-type-equality rule, stack-polymorphic like `return`) + `Return`-shape bottom-transfer lowering + `emit_core` — lowered to **genuine constant-stack BEAM tail calls**: direct reuses the `KReturn` tail path; **indirect** goes through a new `rt_table.call_indirect_lookup` seam (the 3 ordered fail-closed guards, returning the target) then **tail-applies** the package-ABI target, D3a-clean; imports reuse the import path under `KReturn` (value-correct, **bounded frame** — not a cross-module constant-stack claim, Q8). The funcref stored closure became **package-ABI + tail-transparent** (the non-tail `call_indirect` re-wraps package→list inside `rt_table`), so funcref/`elem` modules are **result-identical**; non-funcref output stays **byte-identical**. No new trap, no optimizer/tier/state change. §9. | **2049 tests**; official `return_call.wast`+`return_call_indirect.wast` driven green (**+117** pass → 46,646/1,771/0); constant stack proven to **1,000,000** (direct + mutual + indirect, both table tiers); `OptNone ≡ Baseline ≡ Aggressive` + result-identical across every combo; the 2 `return_call`-blocked legacy EH files now **convert** (driving-green deferred on a deeper non-tail-call scope — measured, R16) |
| **14 — Cross-module funcref-in-`elem`-segment init** | `ref.func` of an **imported** function (the new `RefFuncImport(slot, ty)` IR distinction, produced by the `lower_call`-style import-split, a **pure barrier** in the optimizer) made a table-storable, `call_indirect`-able funcref that dispatches through the D3a import capability — an inline **adapter closure** capturing only the literal slot integer, routing `link.call_import(rt_state.func_import_at(slot), args)` (Cell) / threading `St` unchanged (Threaded), **never** `erlang:apply` on table data. Import-bearing detection became **one public predicate** (`emit_core.needs_func_imports`, extended to scan element segments) that `driver.module_calls_import` **delegates to**, so `instantiate/0`↔`instantiate/1` can't desync (R3). The funcref slot ABI `#(FuncType, closure)` is unchanged; a module with no imported `ref.func` compiles **byte-identically**, and modules driving the new surface are **result-identical** across `OptNone ≡ Baseline ≡ Aggressive` and the full state/tier matrix. No new trap, no runtime shape change, no optimizer/tier/state change; `link.gleam` untouched. §9. | **2080 tests**; flips the project's once-largest residual — `table_copy.wast` **569/~1,080 → 1,649/0/0** — for a headline **+1,088** pass → **47,734/683/0**; authored `corpus/xlink` backstop driven e2e across Cell/Threaded × `TablePaged`/`TableEts`/`TableAtomics` (`via_ci == direct`, cross-combo bit-identical, 3 ordered guards); D3a + arity-lockstep re-run green; audits tightened (`"UnknownFunction"`/`"call_indirect_table"` removed measure-then-remove, ceiling 1,900→750, pass floor 47,700 added) |
| **15 — Production tier-N C NIF for linear memory** | Filled the Phase-4 paged-delegating `rt_mem_nif` skeleton with a **real `erl_nif` C backend** (`c_src/twocore_rt_mem_nif.c`) over a **reserved raw byte buffer** via an ERTS resource — the raw O(1) native memory ceiling; **bit-identical to the paged reference for every access** (LE byte moves, f32/f64 raw IEEE-bit moves, sub-word signed sign-extension, no-wrap `ea`, trap-before-write, `grow` bumping the watermark within the reservation, never realloc'd) + identical traps (the corpus-wide `cell_nif` tier differential is the proof). The C bounds-check (overflow-safe guarded subtractions, memory64-safe via `enif_get_uint64`) is the **fuzz-tested security boundary** (a bug is a genuine host escape — no access escapes `[0, byte_len)`). Adds the `*_unchecked` tier-N fast path (the Phase-10 loop-versioned raw native deref; a one-line `emit_core` whitelist entry). **Native-when-loaded, paged-delegate-otherwise** (MF3 — every head dispatches on `nif_available()`, so a bare BEAM runs byte-identically with no NIF and no per-file gating). Unsafe-only, Safe-forbidden (the four gates preserved verbatim), un-`--link`-able (O8). Test-time `cc`-gated `.so` (production `priv/*.so` packaging a documented follow-on — Gleam has no native pre-build hook); default tier-P/O output **byte-identical**, conformance **unchanged**. No frontend/IR/optimizer-semantics change beyond the `rt_mem_nif` bodies, the unchecked heads, and the one-line whitelist. §4/§5. | **2111 tests** (`+31` over the S15-01…04 suites: the `nif_ping` build proof + gate categorization, the per-op `nif ≡ paged ≡ oracle` differential, the `emit_unchecked` flip, the C-bounds security fuzz incl. memory64 vectors, the native `cell_nif` matrix, the four Safe-forbidden re-assertions); conformance **47,734/683/0** unchanged; measured `nif` column in `docs/phase-4-benchmark.md` (native beats atomics/ceiling on all three kernels, most on store-heavy DEFLATE — the store-intensity prediction; the same-`.beam` native-vs-paged-delegate isolation is the clean proof) with the **honest ceiling, no hero number** (removes rebuild + unchecked bounds-check cost; the per-access seam floor + tier-P `bif` numerics remain — tier-N does NOT reach hand-written Erlang); native tier proven via differential + fuzz + corpus-differential (conformance `cell_nif` runs the bit-identical paged delegate for a documented test-harness-resource-lifecycle reason); `gleam build` zero warnings, `gleam format --check` clean |

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
| Memory | `rt_mem` `paged` (default) | `rt_mem_atomics` O(1), Safe-permitted, requires `--cap` | `rt_mem_nif` **real C NIF** over a reserved raw buffer (Unsafe-only; the raw O(1) native memory ceiling **when the `.so` is loaded**, paged-delegate fallback on a bare BEAM — MF3; test-time `cc`-gated, `priv/*.so` deployment a follow-on) |
| Tables | `rt_table` `TablePaged` (default) | `rt_table_ets` / `rt_table_atomics` | — |
| State | `rt_state` `threaded` (record, 0 native) | `rt_state` `cell` (pdict, default) | — |
| Numerics / SIMD | `rt_num` / `rt_simd` (always tier-P) | — | deferred |

Always-linked tier-P layers: `rt_num`, `rt_simd`, `rt_trap`, `rt_exn`, `rt_ref`, `rt_state`, `rt_meter`.
Capability boundary: `rt_host` (+ `rt_stdlib`, `link`). Build-time-only gate: `rt_bif` (despite the
`rt_` prefix, **not** a runtime layer, not in `Binding`).

---

## 5. Deployment model — how emitted code links to the runtime

**The runtime is *not* embedded in emitted modules.** A generated `.beam` is a thin module of
*inter-module calls* to a shared runtime that must already be resident in the target node. This is
deliberate (decisions D3a/D3d/D10) and load-bearing.

- **Every runtime reference is a module-qualified static call, never inlined.** `emit_core` lowers all
  runtime ops to `call '<twocore@runtime@rt_*>':'<fn>'(...)` — the module atom comes from the `Binding`
  (`emit_core.gleam` `runtime_call`/`seam_call`), e.g. a WASM `i32.add` emits
  `call 'twocore@runtime@rt_num':'i32_add'(...)`. Runtime bodies are *never* copied into generated code
  ("Never embedded in or threaded through generated code", D3d).
- **`build_beam` compiles exactly one `.core` into one `.beam`.** There is no linking, `beam_lib`
  chunk-merging, or bundling step — `to-beam`/`to-beam-wasm` write that single generated module to disk;
  `run`/`exec` load one module into the VM. So an emitted module is **not self-contained**.
- **Consequence:** to load/run an emitted `.beam`, the **compiled `twocore` OTP application** must be on
  the target node's code path — not just the `rt_*.beam` files, but their deps (`gleam_stdlib`,
  `gleam_erlang`) and the hand-written Erlang FFI shims (`twocore_codegen_ffi.erl`,
  `twocore_rt_state_ffi.erl`, …). A generated module copied to a bare node fails `undef` on its first
  `twocore@runtime@*` call. Today the whole flow is **in-process** (D10 — load into the current VM),
  which works because that VM *is* the running `twocore` app and already has the runtime loaded.

**Why it's this way:** it is what makes *"generated code is pure Core Erlang"* true while the runtime
underneath swaps per-tier native implementations — the emitted module is tier-agnostic and just calls
the shared `rt_*` names. It is also what makes **B3 monomorphization** cheap (Safe.beam ≠ Unsafe.beam ≠
threaded.beam are all tiny modules sharing one loaded runtime). The default shared-runtime artifact is
loaded in-process (D10), which works because that VM *is* the running `twocore` app.

**`--link` — the shipped, proven self-contained path (Phase 11).** For a genuinely standalone artifact
there is now an optional `--link` flag on `to-beam-wasm` that **merges the runtime dependency closure
into the generated module**, producing a **single `.beam` that loads and runs on a bare Erlang/OTP node**
with no `twocore@*`/`gleam@*` beams reachable. `--link` runs the same compile pipeline, then a
whole-program **Core Erlang merge** (`beam_link.link_program` over the `cerl` FFI `twocore_linker_ffi.erl`,
pinned OTP 29): acquire every closure member's Core (`beam_lib` `debug_info(core_v1)` from the resident
`.beam`s), compute reachability from the exports **+ `instantiate/N`** across calls, intra-module applies
and `fun M:F/A` captures, DCE the rest, mangle every discovered def to a local `'M__F'/A`, rewrite all
in-closure remotes/captures to local names, and deterministically `compile:forms([from_core,binary,
deterministic])`. The only remaining remote calls are to the **fixed 15-module OTP-ambient allowlist**
(`erlang, lists, maps, binary, math, ets, atomics, unicode, string, io, io_lib, io_lib_format, base64,
rand, uri_string`).

- **Default output is unchanged and byte-identical** — `--link` absent ⇒ today's thin module (proven).
- **Scope is tier-P/O, fail-closed.** tier-N (`nif`), import-bearing modules, and any `-on_load`/
  behaviour in the closure are **link-time rejections** (typed `LinkError`, non-zero exit) — a missing
  dependency surfaces at link time, never as a runtime `undef` on the target node.
- **D3a preserved.** No data-driven `apply`, no `erlang:apply`, no remote call off the ambient allowlist
  survives the merge — enforced by a built-in structural `cerl` check that refuses to emit, **and**
  independently asserted over the whole corpus by the capstone.
- **Behaviour-identical.** The linked artifact is a pure packaging transform: bit-pattern- and
  trap-identical to the in-process path across every pure-BEAM `(mode × state_strategy × mem_tier)`,
  proven in-process (L1) and by **actually booting** the merged `.beam` on a scrubbed isolated `erl`
  (L2). See [`../docs/phase-11-linking.md`](../docs/phase-11-linking.md) and the three-way `link`
  disambiguation (`profiles.link/1` = instantiation, `runtime/link.gleam` = import weaving,
  `beam_link.link_program` = whole-program merge).

The deferred **single-`.beam` runtime-dispatch binding (B1)** ([`02-roadmap.md`](02-roadmap.md) §D) is
distinct — it would let one module pick its runtime *at instance time* (runtime *selection*), whereas
`--link` bakes the chosen runtime *in* (runtime *inclusion*). An **OTP release** of the `twocore` app +
deps remains the alternative for the shared-runtime, hot-reloadable deployment.

**`--bindings` — typed host-language bindings, the shipped & proven ergonomic surface (Phase 12).** The
raw run-ABI above is correct but hostile (args/results are raw unsigned bit patterns — an i32 `-1`
arrives as `4294967295`, an f64 as its raw IEEE bits-in-an-integer, a trap as an uncaught exception).
`--bindings <langs> --out <dir>` on `to-beam-wasm` (comma list of `gleam`/`erlang`/`elixir`) emits,
alongside the compiled `.beam`, **companion typed source files** that present a **native-typed** API —
`Int`/`Float`/`BitArray`, traps as `Result`/tagged tuple, one typed function per export — over the same
`.beam` (which is **unchanged**; bindings are companions). Deterministic output; default (no-`--bindings`)
emission is byte-identical. See [`../docs/phase-12-bindings.md`](../docs/phase-12-bindings.md).

- **Value ABI (`iface.value_abi`, one source all emitters render).** i32/i64 ⇄ `Int` (signed
  two's-complement; host bignums, so i64 round-trips exactly); f32/f64 ⇄ a `Finite(Float) | NonFinite(BitArray)`
  sum type (a BEAM `float()` cannot hold NaN/±Inf, so non-finite values ride raw IEEE bytes — bit-exact,
  D5-safe); v128 ⇄ 16-byte `BitArray`/`binary()`; funcref/externref ⇄ an **opaque** handle; multi-value
  ⇄ a tuple; a trap ⇄ the language error idiom, caught **structurally** on `{wasm_trap, _}` (never a
  bare catch-all; a WASM `throw`/`exnref` is a distinct term class, out of the typed-error surface this
  phase).
- **Two-shape API.** A **Stateless** module (no export reaches instance state) is the beautiful pure
  file — no `Instance`, each export `fn(args) -> Result(T, Trap)`. A **Threaded** module exposes
  `instantiate() -> Result(Instance, Trap)` and threads the `Instance` as a **pure value** (no process;
  an old `Instance` observes no later write).
- **Per-language idioms.** Gleam = a two-file drop under `src/` (the typed `.gleam` + a tiny `.erl`
  catch-shim, since Gleam cannot rescue a BEAM exception in-language) + a README; Erlang = one `.erl`
  (`-spec`/`-doc`, catches in-language, no shim); Elixir = one `.ex` (`@spec`/`@doc`, **zero `Elixir.*`
  runtime deps** — Erlang-style catch, so it runs on a bare BEAM), best-effort (gated on `elixirc`).
- **Scope & composition.** Threaded (tier-P, pure-value `Paged`/`TablePaged`) + export-only this phase
  (`Cell`, import-bearing, and mutable tiers are typed `describe/2` rejections). `--bindings` **requires
  `--threaded`**. The un-linked `.beam` still needs the `twocore@`/`gleam@` runtime on the path — a
  **droppable self-contained** typed artifact = `--bindings` **+** Phase-11 `--link`.
- **Proven — compile + call, not golden strings.** Every emitted binding is compiled by its **real
  toolchain** (`gleam build` / in-VM `erlc` / `elixirc`) and an export is called through the compiled
  native surface, asserted **bit-identical** to the in-process pipeline oracle across the full type
  matrix + threaded state + a genuine trap. Files: `src/twocore/backend/{iface,bindings,
  emit_gleam_bindings,emit_erlang_bindings,emit_elixir_bindings}.gleam`; proof:
  `test/twocore/backend/bindings_compile_call_test.gleam` (the capstone compile+call differential).

---

## 6. The optimizer, as built (`ir_opt`)

`ir_opt.optimize/2` runs `pipeline(opt_level)` to a fixpoint. It sits **upstream of tier + mode
selection**, so a sound pass speeds up *every* tier and *both* modes with no per-tier code.

- **Baseline** (both modes — trust-neutral, trap-preserving): const-fold (bit-exact to `rt_num`) → copy/const-prop → algebraic identities (safe integer only) → const-if → block/label-simplify → DCE → dead-let, **plus** the memory passes: `forwarding_pass` (store→load + RLE), `dead_store_pass` (DSE), `licm_pass` (LICM), `bce_pass` (range-based BCE via loop versioning).
- **Aggressive** (Unsafe-only, strict superset = `baseline ++ aggressive`): `charge_elide` (sound only under `Aggressive ⟹ MeterOff`), `inline` (capture-avoiding, acyclic-guard, node-ceiling bounded).

Soundness rests on `ir/effect.gleam` (the conservative purity/effect classifier — E6) and absolute
**trap-preservation**; both are in the invariants list ([`03-phase-workflow.md`](03-phase-workflow.md) §4).

---

## 7. CLI (every stage is independently invokable)

`gleam run -- <verb>`. Stage verbs: `decode`, `validate`, `lower` (aliases `to-ir`/`ir`), `ir-lower`,
`opt`, `emit`, `to-core`, `to-beam` (alias `build`), `to-beam-wasm`. End-to-end: `run`, `exec`
(`-n/--repeat COUNT`).

Posture flags on `run`/`to-core`/`emit`/`to-beam-wasm`: base `--unsafe`|`--portable`|`--ceiling`, plus
`--threaded`, `--tier paged|atomics|nif`, `--table-tier paged|ets|atomics`, `--cap PAGES`. `opt` takes
`--unsafe` only. Incoherent postures (`Safe`+`nif`, uncapped `atomics`/`ceiling`) fail closed (non-zero
exit). Example: `gleam run -- run test/twocore/conformance/corpus/add.wasm add 3 5` → `8`.

---

## 8. Source-tree map

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

Docs (measured writeups, kept): `docs/phase-{3,4,9,10}-benchmark.md` (phase-4 now carries the measured
`nif` tier-N column), `docs/phase-{5,6,13,14}-surface.md`, `docs/phase-15-tier-n.md`,
`docs/js-on-the-beam.md`, `docs/wasm-conformance.svg`.

---

## 9. Conformance & the categorized residual

The pinned WASM spec suite runs differentially (Tier-A: expected values baked in the `.wast`; Tier-B:
a `wasmtime`/`wast2json`/rebuild-oracle engine), held across the full `(mode × state_strategy ×
mem_tier)` matrix — every combo byte-identical, `fail=0` everywhere. Toolchain pins: Porffor 0.61.13,
Node 22, wabt 1.0.41, wasmtime 46.0.1 (see `vendor.sh` + `PIN`).

The **683 skips are all categorized** (`residual_audit_test` fails red if any skip matches no
enumerated bucket). Phase 14 flipped the once-largest bucket — `table_copy.wast`'s cross-module
funcref-in-`elem` init — to **fully driven** (1,649/0/0, +1,088 pass), so its
`"UnknownFunction"`/`"call_indirect_table"` phrases are **removed** (a regression re-skipping those goes
red). Phase 13 folded the two official tail-call `.wast` into the driven allowlist, so
`return_call`/`return_call_indirect` are **no longer out-of-scope** — they run green (+117 pass). The
buckets map directly onto [`02-roadmap.md`](02-roadmap.md):

- **cross-module funcref-in-`elem` init** (`table_copy.wast` verifier) — **CLOSED in Phase 14**: `ref.func`
  of an *imported* function placed in a table and reached via `call_indirect` now builds + dispatches
  (the `RefFuncImport` distinction + the D3a import-adapter closure); `table_copy.wast` runs green
  (see `docs/phase-14-surface.md`).
- **~511** — SIMD *text-format* assertions the WAT parser can't read (the binary SIMD path proves them e2e).
- **+3** (Phase 13) — one host-import tail/direct call per tail-call file (`spectest.print_i32_f32`)
  **denied under the deny-all Safe host** (a categorized POLICY denial, not a spec trap — it passes
  under `unsafe`), plus one already-categorized text-format assert.
- **remainder** — genuinely out-of-scope proposals: GC-proposal reftypes, extended-const,
  `assert_exhaustion`. `memory64.wast`/`linking.wast` are file-level WAT-parser parse-skips (the
  features themselves are proven by authored in-scope backstops).
