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
| `«CLOSURE-FROZEN»` — link-closure manifest (`src/twocore/backend/link_manifest.gleam`) + acquisition method + mechanically-derived OTP-ambient allowlist + mangle/mergeability invariants + drift test | P11-02 | `FROZEN ✓` | P11-03 |
| `«LINKER-IFACE-FROZEN»` — `beam_link.link_program`/`link_to_core` public signatures + `LinkError` variants | P11-03 | `FROZEN ✓` | P11-04, P11-06 |
| `«BARE-NODE-HARNESS-PROVEN»` — isolation harness proven against a hand-authored trivial `.beam` (gate: fails when a `twocore@` module is reachable) | P11-05 | `unclaimed` | P11-06 (L2) |

### Units

| Unit | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|
| **P11-01** Keystone: runtime layer split (`OptLevel`→leaf; `ir` not split, R2/R3) | `done` | — | Runtime reaches zero compiler modules (grep-verified); default output byte-identical; the ~10-file reach set repointed. |
| **P11-02** Link-closure manifest + allowlist + acquisition + invariants (R1/R7/R8/R12/R15) | `done` | `«RT-LAYER-FROZEN»` | Frozen closure set (16 runtime + 12 gleam + 7 FFI, incl. `gleam_stdlib`+`gleam_erlang_ffi`+5 `twocore_rt_*_ffi`), per-module Core-acquisition method, mechanically-derived allowlist (15), `__`-free + mergeability invariants + genuinely-recomputing drift test. |
| **P11-03** The `cerl` linker engine (R4/R5/R6/R9/R10/R11) | `done` | `«CLOSURE-FROZEN»` | `beam_link.link_program`/`link_to_core` + `twocore_linker_ffi.erl`: 3-node-class rewrite incl. fun-captures, funref+`instantiate` reachability roots, DCE, deterministic `from_core`, built-in fail-closed structural D3a check; in-process smoke differential green (built+loaded+called, bit/trap-identical). |
| **P11-04** CLI `--link` (`to-beam-wasm` only) + `build_beam` entry + fail-closed gate (R13/R14) | `done` | `«CLOSURE-FROZEN»` (ambient allowlist), `«LINKER-IFACE-FROZEN»` (sig) | `--link` default off (byte-identical); tier-N + import-bearing + `on_load` rejected at the CLI/linker boundary. |
| **P11-05** Bare-node isolation harness, proven first (test-first) | `unclaimed` | — | `twocore_linked_boot_ffi.erl`: scrubbed fresh `erl`, in-child `code:which` isolation gate; self-test proves the gate actually gates. |
| **P11-06** Capstone | `unclaimed` | all above | **PHASE 11 PROVEN.** L1 in-process linked≡non-linked differential (full corpus × mode × state × tier P/O) + L2 bare-node differential (import-free subset) + constant-space + determinism byte-check + D3a corpus assertion; `docs/phase-11-linking.md`; `01-status.md` §5. |

### Landing log

- **P11-04** — 1902 tests (was 1896, +6: 3 `link_gate_test` + 3 `cli_link_flag_test`), conformance unchanged (46,529/1,768/0), 0 new warnings (the 2 pre-existing `rt_js_test` remain), format clean, **default output byte-identical** (proven by `cli_link_flag_test.default_off_byte_identical_test`: the `--link`-absent CLI `.beam` bytes equal a fresh `pipeline.core_to_beam` over the identical `resolve_binding` binding). No new freeze (leaf wiring unit).
  - **CLI surface added:** a `--link: Bool` axis flag (default `False`) on the `to-beam-wasm` verb ONLY (R13). Added to the `Axes` record + parsed in `do_split_axis_flags`; threaded through `with_binding` (whose continuation now takes `(binding, link, positionals)`). Scoping is fail-closed: `emit`/`to-core`/`run` reject `--link` via `reject_link/3` (short-circuits before file IO) and `to-beam`/`build` reject a `--link` token explicitly (R13 deferral — no `Binding` to gate). New `build_beam` linked entry: `build_beam.link_beam(generated_core: BitArray, module_name: String) -> Result(#(Atom, BitArray), beam_link.LinkError)` — composes `link_manifest.ambient_allowlist()` with `beam_link.link_program/3` (single point binding the OTP-ambient set to a link; CLI never re-spells the allowlist).
  - **Three fail-closed rejections** (each a non-zero-exit CLI `Error`): (1) **tier-N** — `link_gate(binding, m) == Error(LinkTierNif)` iff `binding.mem_tier == Nif`, under ANY mode (Unsafe+Nif too); message "`--link cannot merge the nif memory tier … tier-P/O only`". Pinned distinct from `profiles.link/1` by asserting `profiles.link` returns `Ok` for the SAME Unsafe+Nif binding (R13). (2) **import-bearing** — `Error(LinkImportBearing(n))` iff `m.imports != []` (conservative superset incl. import-but-uncalled); message "`--link cannot link an import-bearing module (n import(s)) …`". (3) **`on_load`/unmergeable INSIDE the closure** is NOT the CLI gate's job (R13) — the linker discovers it structurally as `UnmergeableConstruct`; `describe_beam_link_error/1` renders all 7 `beam_link.LinkError` variants to stderr on the linked branch.
  - **Positive `--link` path proven:** `to-beam-wasm --unsafe --link add.wasm out.beam` writes ONE self-contained `.beam`; `exec` (load → spawn → `instantiate/0` → invoke) returns `add(2,3)==5`, equal to the non-linked build (`cli_link_flag_test.linked_build_smoke_test`).
  - **⚠ DISCOVERED-WRONG — signal for P11-06/P11-03 (a real P11-03 linker gap, NOT a P11-04 defect):** the default **Safe** pipeline's fuel metering (`ir_lower` → `charge` → `rt_meter`) reaches `gleam@dynamic@decode:decode_int/1` via a **fun-capture**; the linker REWRITES the capture to the local mangled call `gleam@dynamic@decode__decode_int/1` but does NOT pull that capture's target **DEF** into the merge, so a linked Safe `add` traps `undef` at runtime on the first `charge` (stacktrace: `…decode__run/2 → decode__decode_int/1` undefined). P11-03's `beam_link_test` never caught this because its `gen_core` uses `emit_core.emit_module` DIRECTLY (no `ir_lower`, so no `charge`/metering closure). The positive smoke therefore uses `--unsafe` (`MeterOff` ⇒ no `charge` ⇒ the metering closure is never emitted) — still a genuine tier-P (`Paged`), import-free linked build. **P11-06's Safe-mode corpus differential will fail until P11-03's reachability walk also seeds fun-capture *targets* as DCE roots (R4 edge (a)), not only rewrites them (R4/R5 edge (b)).**
  - **Files:** edited `src/twocore.gleam` (flag/scoping/gate/linked branch/usage) + `src/twocore/backend/build_beam.gleam` (`link_beam/2`); created `test/twocore/link_gate_test.gleam` + `test/twocore/cli_link_flag_test.gleam`. No default-path behavior changed.
- **P11-03** — 1896 tests (was 1881, +15 `beam_link_test`), conformance unchanged (46,529/1,768/0), 0 new warnings (the 2 pre-existing `rt_js_test` remain), format clean, byte-identical default output (the linker is a new emission path invoked by nothing yet). `«LINKER-IFACE-FROZEN» ✓`. The in-process smoke differential genuinely EXECUTED the merge: emit numerics IR → `.core` → `link_program` → load → call; linked ≡ in-process, value+trap identical (`i32.clz(1)=31`, `i32.clz(0)=32`, `i32.add(0x7FFFFFFF,1)=0x80000000`). Standalone de-risk also proved the critique's cross-module chain (`chain(100,6)=106`).
  - **FROZEN public interface** (`src/twocore/backend/beam_link.gleam`, P11-04/P11-06 build against this): `link_program(generated_core: BitArray, module_name: String, ambient: List(String)) -> Result(#(Atom, BitArray), LinkError)` and `link_to_core(generated_core: BitArray, module_name: String, ambient: List(String)) -> Result(#(Atom, String), LinkError)` (merged Core TEXT before compile — P11-06's independent-D3a seam). Guarantee: the returned `Atom` equals the module name declared inside the returned `.beam` (P11-05 resolves the child via `code:which`). `LinkError` variants (7): `OffAllowlistRemote(module, fun)`, `MissingClosureModule(module)`, `AmbientAuthorityFound(detail)`, `UnmergeableConstruct(detail)`, `MangleCollision(a, b)`, `MalformedCore(detail)`, `CoreAcquisitionFailed(module, reason)`.
  - **The `cerl` merge** (`src/twocore_linker_ffi.erl`, same pinned-OTP-29 trust boundary as `twocore_codegen_ffi`): acquire generated Core from TEXT (`core_scan`/`core_parse`) + discovered members from RESIDENT `.beam` `debug_info(core_v1)` (verified: `beam_lib:chunks` → `Backend:debug_info(core_v1,…)`); reachability worklist from the generated exports + `instantiate/N`, following 3 edge kinds (remote `#c_call`, intra-module `apply` on an `fname`, fun-capture literal); function-level DCE (only reached defs assembled); mangle every DISCOVERED module's def to `'M__F'/A` (the generated module is the IDENTITY so its public exports stay callable); rewrite 3 node classes via `cerl_trees:map`; synthesize one `module_info/{0,1}` + drop all source attrs; strip node annotations + sorted def order (R10) → `compile:forms([from_core,binary,deterministic])`; built-in fail-closed structural D3a check refuses to emit on `erlang:apply`/computed-module call/off-allowlist remote/residual off-closure capture.
  - **Load-bearing discovered facts for P11-04/P11-06:** (1) **Fun-captures (R4) reconstruct as a `literal` node wrapping an EXTERNAL `fun` VALUE** (not a `make_fun` call, not a distinct AST kind) — detected via `erlang:fun_info(V,type)==external`; `rt_simd:f32x4_add/2` captures `fun twocore@runtime@rt_num:f32_add/2` (the exact R4 example, tested). In THIS build ALL captures are external (Gleam fully-qualifies) — no `local`-type fun literals were found. (2) **`cerl_prettypr:format` CRASHES on an external-fun literal** (`case_clause`); the linker sidesteps this by rewriting every capture to an explicit `erlang:make_fun('MergedMod','M__F',A)` call (printable via `core_pp`, compilable, and D3a-safe: literal self-module + literal local name, explicitly NOT `erlang:apply`) and prints merged Core via `core_pp:format`. (3) **`code`/`net_kernel`/`timer` (`dce_only_remotes`) do NOT survive** — even though the numerics `instantiate` pulls `gleam_erlang_ffi`, function-level DCE never reaches its unused `connect_node`/`priv_directory`/`sleep` helpers (asserted). (4) **Design note**: the merged module's public exports are the generated module's ORIGINAL export names UNMANGLED (the generated module is mangle-identity); only DISCOVERED closure modules are `'M__F'`-mangled — so `core_lint`/`from_core` accept the export list unchanged and no re-export wrappers are synthesized. (5) **`OffAllowlistRemote` is a D3a backstop**: in practice a reached non-ambient module is acquired+merged (its remotes become local applies) or fails as `MissingClosureModule`/`CoreAcquisitionFailed`; a real non-ambient OTP module (e.g. `filelib`) fails closed on acquisition (no `core_v1` chunk, no source on the path).
  - **Deliberate cross-file reaches (P11-03-owned):** creates `src/twocore/backend/beam_link.gleam`, `src/twocore_linker_ffi.erl`, `test/twocore/backend/beam_link_test.gleam`, and the read-only synthetic-module installer `test/twocore_linker_test_ffi.erl` (test-dir, mirrors the `test/twocore_*_test_ffi.erl` convention — installs a `__`-bearing and an `-on_load` module on disk so the real acquisition path exercises `MangleCollision`/`UnmergeableConstruct`). Reuses `build_beam`'s `compile_and_load`/`load_module` and `twocore_emit_test_ffi:catch_apply` read-only. Touches no default-path source.
- **P11-02** — 1881 tests (was 1865, +16: 11 `link_manifest_test` + 5 `link_manifest_drift_test`), conformance unchanged, 0 new warnings, format clean, byte-identical default output (manifest is imported by nothing yet). `«CLOSURE-FROZEN» ✓`.
  - **Frozen manifest** — `src/twocore/backend/link_manifest.gleam` (stdlib-only leaf: `gleam/list`+`gleam/set`+`gleam/string`, zero project imports). Public API P11-03 consumes: `ambient_allowlist/0`+`is_ambient/1` (the 15-module DCE stop-set + fail-closed remote check), `Acquisition`+`primary_acquisition/1`+`fallback_acquisition/0` (R1 order: `GeneratedCoreText` for the wasm module, uniform `ResidentBeamCore` for discovered members, `CompileFileToCore` fallback), `mangle_separator`+`mangle_injective/1` (R12 precondition), and the `frozen_*` snapshots.
  - **Enumerated closure (measured mechanically from the shipped `.beam`s, module-level `beam_lib:imports` walk from `frozen_runtime_roots/0` — R4-complete: the `imports` chunk records `fun M:F/A` captures too):** 16 runtime (`link`,`porffor_abi`,`rt_exn`,`rt_host`,`rt_mem`,`rt_mem_atomics`,`rt_meter`,`rt_num`,`rt_ref`,`rt_simd`,`rt_state`,`rt_stdlib`,`rt_table`,`rt_table_atomics`,`rt_table_ets`,`rt_trap`) + 12 gleam (`bit_array`,`dict`,`dynamic`,`dynamic@decode`,`erlang@atom`,`float`,`int`,`list`,`result`,`set`,`string`,`string_tree`) + **7 FFI** (`gleam_stdlib`, `gleam_erlang_ffi`, + the 5 `twocore_rt_{exn,mem_atomics,ref,state,table_ets}_ffi`) = 35 mergeable modules. Allowlist = 15 (`erlang,lists,maps,binary,math,ets,atomics,unicode,string,io,io_lib,io_lib_format,base64,rand,uri_string`); `frozen_surviving_remotes/0` == the allowlist exactly. `__`-free ✓; no `-on_load`/behaviour/`persistent_term`/NIF/`gleam@@main` across the closure ✓.
  - **Spec-drift notes for downstream units (P11-03/P11-06):** (1) **The FFI bucket is 7, not the spec's 6** — the real closure includes **`gleam_erlang_ffi`** (reached `rt_host` → `gleam@erlang@atom:decoder/0` → `gleam_erlang_ffi:atom_from_string/identity`); the spec §3 `frozen_ffi_erl` list omitted it. (2) **A module-level walk over-approximates surviving remotes to 18** — merging `gleam_erlang_ffi` wholesale pulls `code`/`net_kernel`/`timer` via its *unused* `connect_node`/`priv_directory`/`sleep` helpers; these are eliminated by the linker's FUNCTION-level DCE (never reached from the atom path), so they are frozen as `dce_only_remotes/0` and kept OUT of `ambient_allowlist/0` (no D3a-weakening `code` widening). `frozen_surviving_remotes/0` (15) == module-level-ceiling (18) − `dce_only_remotes/0` (3), and equals R7's measured floor exactly — validating R7. (3) **`rt_js`/`twocore_rt_js_ffi` are correctly EXCLUDED** — only reachable via `CallHost("js",…)`, off the WASM `--link` path (and import-bearing per R14). (4) **`rt_bif` is EXCLUDED** — build-time gate consulted by `ir_lower`, not a runtime call target; `instance`/`profiles`/`rt_mem_nif` also correctly absent. The spec/overview's "runtime/rt_* + instance/profiles" phrasing is looser than the reachability truth.
  - **Deliberate cross-file reaches (P11-02-owned):** creates `src/twocore/backend/link_manifest.gleam`, `test/twocore/backend/link_manifest_test.gleam`, `test/twocore/backend/link_manifest_drift_test.gleam`, and the read-only introspection FFI `test/twocore_link_manifest_drift_ffi.erl` (test-dir, mirrors the existing `test/twocore_rt_*_test_ffi.erl` convention). Touches nothing else. Drift test proven non-vacuous (perturbing a frozen list makes `closure_drift_test` fail — it recomputes from the live build, not the frozen data).
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
