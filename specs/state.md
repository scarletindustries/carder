# Implementation State — what's taken, by whom, and what it leaves

> The swarm's shared ledger. Before claiming work, read it; after finishing, update it.
> It maps the canonical spec ([`00-high-level.md`](00-high-level.md)) onto concrete work
> units and tracks their status. The detailed unit specs live in
> [`phase-1/`](phase-1/). Read [`phase-1/00-overview.md`](phase-1/00-overview.md) first.

**Legend — status:** `unclaimed` · `in-progress (name)` · `blocked (on …)` · `done`
**Legend — freeze milestone:** a published, compiling type stub that unblocks downstream
units (see overview §3). Announce milestones here the moment they land.

---

## Freeze milestones (the real scheduling gates)

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«IR-FROZEN»` — `ir.gleam` + `ir-grammar.md` | 01 | **FROZEN ✓** | 02, 08, 10, 11 |
| `«ABI-FROZEN»` — `instance.gleam` (Binding + convention) | 01 | **FROZEN ✓** | 08, 09, 11 |
| `«RTNUM-SIG-FROZEN»` — `rt_num.gleam` signatures (90 fns) | 01 | **FROZEN ✓** | 06, 08 |
| `«CORE-AST»` — `backend/core_erlang.gleam` types | 03 | **published ✓** | 08 |
| `«WASM-AST»` — `frontend/wasm/ast.gleam` types + `DecodeError` | 05 | **published ✓** | 10 (validate) |
| `«FFI-SHIM»` — `twocore_codegen_ffi.erl` (compile+load) | 04 | **published ✓** | 03 (verify), 08/10 (e2e tests) |

---

## Phase 1 — units

Phase-1 goal & honest scope: see [`phase-1/00-overview.md`](phase-1/00-overview.md) §1.

| Unit | Doc | Owner / status | Depends on (freeze) | What it leaves when `done` |
|---|---|---|---|---|
| **01** Interface freeze | [`01`](phase-1/01-interface-freeze.md) | **done** | — | IR types, `.ir` grammar, runtime ABI, rt_num signatures (90 fns, `todo` bodies → 06), PipelineError stub all frozen; neutrality review signed off; 3 golden `.ir` + strawman test green. The keystones exist. |
| **02** `.ir` printer & parser | [`02`](phase-1/02-ir-textual-form.md) | **done** | `«IR-FROZEN»` | `.ir` round-trips the full surface (`parse(print(m))==m`, incl. NaN payloads/`-0.0`/±Inf); total parser; 3 goldens parse; `ir-grammar.md` reconciled to the implementation. |
| **03** Core Erlang AST & printer | [`03`](phase-1/03-core-erlang-backend.md) | **done** | — | `.core` AST (`«CORE-AST»`) + pretty-printer; printed ASTs compile+run on real OTP-29 (add/fac/classify); atom escaping proven byte-identical to OTP `io_lib:write_string`. |
| **04** `build_beam` driver & FFI | [`04`](phase-1/04-build-beam-driver.md) | **done** | — | `.core` text → loaded `.beam` proven (hand-written `.core` compiled, loaded, ran on BEAM); the `«FFI-SHIM»`; `gleam_erlang` added. |
| **05** WASM decoder & AST | [`05`](phase-1/05-wasm-decoder.md) | **done** | — | `.wasm` → WASM AST (`«WASM-AST»`); LEB128 (spec vectors) + fail-closed/fuzz-proven decoding (no `let assert`/`panic`); 54 tests. |
| **06** `rt_num` numerics (`bif`) | [`06`](phase-1/06-rt-num-numerics.md) | **done** | `«RTNUM-SIG-FROZEN»` | All 90 bodies implemented; the numeric-fidelity reference (tier-P), 40 spec-corner/property tests. Build now **zero-warning**. |
| **07** Conformance harness & corpus | [`07`](phase-1/07-conformance-harness.md) | **done** | pipeline (committed) | Acceptance corpus green end-to-end (the Phase-1 goal proof); spec-suite runner **1699 pass / 1400 skip / 0 fail** (18 files, honest skip categories); oracle/registry/`driver.pipeline()` reusable by unit 11. |
| **08** `emit_core` (IR → Core) | [`08`](phase-1/08-emit-core.md) | **done** | `«IR-FROZEN»`,`«CORE-AST»`,`«ABI-FROZEN»`,`«RTNUM-SIG-FROZEN»` | **The backend works end-to-end:** hand-written IR → Core Erlang → loaded `.beam` → correct results (add/wrap/shift, `sum_to(100k)` constant-space, fib/fac, div traps, deny-all host, stdlib gcd); binding chokepoint + security-invariant test pass. |
| **09** Runtime defaults | [`09`](phase-1/09-runtime-defaults.md) | **done** | `«ABI-FROZEN»` | `rt_trap.raise/1`, `rt_host.call_host/3` (deny-all), `rt_meter.charge/1` (tier-O pdict fuel), `rt_stdlib.gcd/2` (own), `rt_bif` (build-time allowlist). 34 fail-closed/security tests. |
| **10** WASM validate & lower | [`10`](phase-1/10-wasm-validate-and-lower.md) | **done** | `«WASM-AST»`, `«IR-FROZEN»` | `full` validation (spec abstract-stack algorithm + local cap) rejects ill-typed; lower does stack-elim/SSA (mutable locals → `LoopParam`) with named labels. **Real `.wasm` → BEAM proven** (add/sum_to/fib via the full pipeline). |
| **11** ir_lower, linker, Safe profile, CLI (capstone) | [`11`](phase-1/11-ir-lower-linker-cli.md) | **done** | all of the above | `ir_lower` (fail-closed allowlist + metering insertion), the Safe profile/linker, the per-stage CLI (decision #5; `gleam run -- run add.wasm add 2 3` → `5`), and the acceptance corpus green **with ir_lower(Safe) in the chain**. Phase-1 goal proven. |

---

## High-level spec coverage — which §/decision each unit "takes"

> So nothing in the canonical spec is silently dropped, and so two units don't claim the
> same ground. "Taken" = an owning Phase-1 unit exists. "Deferred" = explicitly Phase-2+.

| High-level spec item | Taken by | Notes |
|---|---|---|
| §3 IR core types | 01 | Full surface frozen now (lock-now decisions #1/#2/#4). |
| §3 `.ir` textual form | 01 (grammar), 02 (impl) | The inter-stage contract (D7). |
| §3 dual value model + explicit conversions | 01 (types), 06 (numeric semantics) | Floats as bits (D5). Term layer is lock-now placeholder. |
| §3 optional linear memory | 01 (IR models it) | **Runtime deferred** — no `rt_mem` in Phase 1 (corpus has no memory). |
| §3 `call_host` capability node | 01 (IR), 08 (lowering), 09 (deny-all) | Exercised end-to-end (D9). |
| §3 `trap` / `charge` effects | 01 (IR), 08 (emit), 06 (trap raise), 09 (rt_meter) | Metering **seam** wired now (D9). |
| §4 FW WASM frontend (decode/validate/ssa/structure) | 05 (decode), 10 (validate+lower) | `full` validator only; `subset`/`assume_valid` deferred. |
| §4 M1 IR core + textual form | 01, 02 | |
| §4 M2 optimizer (`ir_opt`) | — | **Deferred to Phase 2.** |
| §4 M3 stdlib + capability lowering (`ir_lower`) | 11 (ir_lower) | Minimal: capability/stdlib resolution + `charge` insertion. |
| §4 B1 emitter (`emit_core`) | 08 | `core_text` format; `cerl_ast` alt deferred. |
| §4 B2 driver (`build_beam`) | 04 | `forms`/in-memory path (via `core_scan`/`core_parse`); `file` fallback. |
| §4 R-num numerics (`bif`) | 06 | tier-P reference impl; `nif` deferred. |
| §4 R-trap traps | 09 | `error` impl. |
| §4 R-state instance state | 01/08 (calling convention) | tier-P; **no threaded record in Phase 1** (D3d) — no mutable state. |
| §4 R-host host/capability dispatch | 09 | `deny_all` (default); `whitelist`/`open` deferred. |
| §4 R-meter metering | 09 | minimal `fuel`; `none` is the Unsafe default (deferred). |
| §4 R-std standard library | 09 (runtime), 11 (resolution) | `own` minimal (1–2 fns); breadth + `passthrough` deferred. |
| §4 R-bif BEAM-function gate | 09 | `allowlist` (enforced minimal); `open` deferred. |
| §4 R-mem / R-tab linear-memory subsystem | — | **Deferred to Phase 2.** |
| §4 I instantiation (`rt_instance`) | 11 (linker) | Safe profile only; Unsafe deferred. |
| §5 backend lowering (letrec/tail-calls, calls, numerics, traps) | 08 | Verified loop template in the unit doc. |
| §5 codegen security invariants | 08 (test) | No ambient-authority `apply` (D3a); asserted structurally. |
| §6 Safe mode | 09 + 11 (seams) | **Seams wired & exercised, not a full sandbox (D9).** |
| §6 Unsafe mode | — | **Deferred to Phase 2.** |
| §9.1 numeric fidelity invariants | 06 | Property-tested + end-to-end via the corpus. |
| §9.2 preemptive/compiled execution | 08 (tail-calls) + 04 (it's real BEAM code) | Verified: a `letrec` tail loop ran 100k iters in constant space on OTP 29. |
| §11 differential testing (spec `.wast`) | 07 | Tier-A (expected baked in `.wast`) + Tier-B (engine oracle). |
| §11 interface-conformance suites | each unit's "Verification" | Done = suite passes, not "compiles" (D8). |
| §8.2 Porffor JS→WASM bridge | — | **Deferred to Phase 2+.** |
| §8.3 Gleam/Erlang frontend | — | **Deferred (later phase).** |
| §12 WAT text parser | — | **Deferred to Phase 2** (use `wat2wasm` for fixtures). |
| §12 bulk memory / reftypes / SIMD / tail-call proposal / threads | — | Deferred / non-goal per §12/§26. |

---

## Phase 2 — complete WASM 1.0 (linear memory, tables, globals, full floats, mutable state)

Goal & honest scope: see [`specs/phase-2/00-overview.md`](phase-2/00-overview.md). The
load-bearing new thing is **mutable instance state** via the tier-O **`cell`**
(process-dictionary) strategy (E1); the tier-P `threaded` build, non-function imports,
reference types, bulk memory, multi-memory, SIMD, the WAT parser, the optimizer, and the
Unsafe profile are all **Phase 3** (deferred, not dropped).

### Phase-2 freeze milestones

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«IR2-FROZEN»` — `ir.gleam` tables/elem + MemSize/MemGrow + load result-width + float NumOp/ConvOp + 3 TrapReasons + grammar delta | P2-01 | **FROZEN ✓** | 02, 08, 09, 10 |
| `«CELL-STATE-ABI-FROZEN»` — Binding (mem/table/state) + rt_state/rt_mem/rt_table stub sigs + the emit_core state-access seam + the instantiation contract | P2-01 | **FROZEN ✓** | 03, 04, 05, 10, 11 |
| `«RTNUM2-SIG-FROZEN»` — new rt_num float/convert signatures (`todo`) | P2-01 | **FROZEN ✓** | 06, 10 |
| `«WASM-AST2»` — extended `frontend/wasm/ast.gleam` types | P2-07 (day 1) | **published ✓** | 08 (validate) |

### Phase-2 units

| Unit | Doc | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|---|
| **P2-01** Interface freeze (keystone) | [`01`](phase-2/01-interface-freeze.md) | **done** | — | IR2 + cell ABI + instantiation contract + rt_num float sigs frozen, build green. |
| **P2-02** `.ir` printer/parser ext | [`02`](phase-2/02-ir-textual-form.md) | **done** | `«IR2-FROZEN»` | `.ir` round-trips the new variants (fast-follow, off critical path). |
| **P2-03** rt_state + globals + lifecycle | [`03`](phase-2/03-rt-state-lifecycle.md) | **done** | `«CELL-STATE-ABI-FROZEN»` | The per-instance pdict cell (opaque, fresh/reset, fail-closed) + mutable globals + one-instance-one-process. |
| **P2-04** rt_mem (paged + oracle) | [`04`](phase-2/04-rt-mem.md) | **done** | `«CELL-STATE-ABI-FROZEN»` | Bounds-checked (no-wrap, trap-before-write) LE load/store/size/grow + data-init + Safe max-pages cap; rebuild-oracle differential + memory_trap/address/endianness `.wast`. |
| **P2-05** rt_table + call_indirect | [`05`](phase-2/05-rt-table.md) | **done** | `«CELL-STATE-ABI-FROZEN»` | 3-fault fail-closed indirect dispatch (build-controlled, no ambient apply) + element-init. |
| **P2-06** rt_num float ext | [`06`](phase-2/06-rt-num-floats.md) | **done** | `«RTNUM2-SIG-FROZEN»` | The remaining float bodies (unary, copysign, comparisons, trapping trunc, convert, demote/promote), spec-corner tested. |
| **P2-07** decode ext (+ `«WASM-AST2»`) | [`07`](phase-2/07-decode.md) | **done** | — | Decode table/memory/global/element/data/start sections + the full opcode set (load/store matrix, size/grow, 0xA7–0xBF conversions, floats, select, global/table ops). |
| **P2-08** validate ext | [`08`](phase-2/08-validate.md) | **done** | `«WASM-AST2»` | Typing for all new ops + memarg alignment + const-expr validation (AST-only security boundary). |
| **P2-09** lower ext | [`09`](phase-2/09-lower.md) | **done** | `«WASM-AST2»`, `«IR2-FROZEN»` | WASM AST → IR2 for memory/table/global/float/select/conversions + active data/element/global-init. |
| **P2-10** emit_core ext + instantiate entry | [`10`](phase-2/10-emit-core.md) | **done** | `«IR2-FROZEN»`,`«CELL-STATE-ABI-FROZEN»`,`«RTNUM2-SIG-FROZEN»` (∥ 03–06) | Lower the stateful ops via the seam + trapping converts + the generated `instantiate/N`; extended security-invariant test. |
| **P2-11** capstone (run-ABI + linker + conformance) | [`11`](phase-2/11-capstone.md) | **done** | all above | `load→instantiate→invoke` run-ABI + harness isolation; Safe profile (mem/table/state + max-pages cap); Phase-2 `.wast` allowlist + acceptance; refresh the conformance image. |

### High-level spec coverage this phase takes (additions to the §-coverage table)

| High-level item | Taken by | Notes |
|---|---|---|
| §3 optional linear memory (runtime) | P2-04 (`rt_mem`) | `paged` + `rebuild` oracle; `atomics`/`nif` tiers deferred. |
| §4 R-mem / R-tab subsystem | P2-04 / P2-05 | Bounds-/type-checked → trap (security boundary). |
| §4 R-state instance state | P2-03 | tier-O **`cell`** (pdict); tier-P `threaded` deferred. |
| §9.1 full float/conversion fidelity | P2-06 | Remaining unary/cmp/trapping-trunc/convert/promote/demote. |
| §10 mutable-state calling convention | P2-01 (E1) | `state_strategy = cell`; the emit_core state-access seam. |
| §6 Safe-mode memory resource bound | P2-01/P2-04/P2-11 (E3) | Hard max-pages cap + proportional grow charge. |
| §12 Phase-1 (full WASM 1.0) | P2-* | Completes what high-level §12 calls "Phase 1"; §12 "Phase 2" proposals stay deferred. |

### Deferred to Phase 3 (explicit)

tier-P `threaded` state build; `rt_mem` `atomics`/`nif` tiers; non-function imports + the
`spectest` module; reference types (externref/funcref, `table.get/set/copy/fill`, `select_t`,
`elem.wast`); bulk memory (`memory.fill/copy/init`, `data.drop`); multi-memory (`memory.wast`/
`table.wast`/`memory_grow.wast` are un-convertible/multi-memory at the pin); SIMD; memory64;
GC; the WAT text parser; the `baseline`/`aggressive` optimizer; the Unsafe profile; CPU-fuel
enforcement (still observe-only); the Porffor JS→WASM bridge.

---

## Phase 3 — "Fast": the shared optimizer + the Unsafe profile + real CPU metering

Goal & honest scope: see [`specs/phase-3/00-overview.md`](phase-3/00-overview.md) (decisions
**F1–F8**). Phases 1–2 proved the platform *correct & sandboxed*; Phase 3 builds the *speed &
second-mode* half. The load-bearing new thing is the **shared IR-level optimizer** (`ir_opt`,
high-level §4 M2) plus the **Unsafe** profile (§6) and **enforcing** CPU fuel. **No new frontend
surface, no new IR node types** — a middle-end + runtime + linker phase whose correctness bar is
that **both profiles stay green** on the existing corpus + spec suite. The keystone (`ir_opt`
interface + the Unsafe `Binding` policy extension + the enforcing `rt_meter` contract) is P3-01.
Coexistence is **B3 monomorphization** (Safe.beam ≠ Unsafe.beam — metering compiled in/out,
optimizer at build time; identical `twocore@runtime@rt_*` names) + **per-instance seeded runtime
policy** (fuel budget + host policy seeded by the generated `instantiate/0`); the single-`.beam`
runtime-dispatch B1 is **Phase 4**.

### Phase-3 freeze milestones (planned)

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«IROPT-IFACE-FROZEN»` — `middle/ir_opt.gleam` (`OptLevel`, `optimize/2`) + `middle/ir_opt/pass.gleam` (leaf `Pass` combinators, imports `ir` only → no cycle) + `ir/effect.gleam` signatures | P3-01 | **FROZEN ✓** | 02, 03, 04, 09 |
| `«UNSAFE-PROFILE-FROZEN»` — `Binding` policy fields (`opt_level`/`meter`/`bif_gate`/`stdlib`/`host_policy`/`fuel_budget`) + 5 policy enums + `profiles.unsafe()` green + the `Aggressive ⟹ MeterOff` coupling test | P3-01 | **FROZEN ✓** | 06, 07, 08, 09, 10 |
| `«METER-ENFORCE-FROZEN»` — `FuelExhausted` TrapReason (+`spec_trap_message`) + `rt_meter.seed_fuel/1` + enforcing `charge/1` (ABI unchanged) | P3-01 | **FROZEN ✓** | 05, 09, 11 |

### Phase-3 units (specs authored + critiqued + reconciled; implementation `unclaimed`)

| Unit | Doc | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|---|
| **P3-01** Interface freeze (keystone) | [`01`](phase-3/01-interface-freeze.md) | **done** | — | `ir_opt`/`pass`/`effect` sigs + `Binding` policy ext (incl. `fuel_budget`) + `profiles.unsafe()` + `FuelExhausted`/`seed_fuel` frozen; leaf `pass.gleam` (no import cycle); `Aggressive⟹MeterOff` coupling. **Landed GREEN: 525 tests (was 509), 0 warnings, conformance fail=0.** Reaches: `ir.TrapReason`+`FuelExhausted`; `rt_trap.spec_trap_message`; printer/parser/emit_core exhaustive `TrapReason` arms; `instance.safe_default` Safe posture; `rt_meter.default_fuel_budget`+`seed_fuel/1`; `rt_host.seed_policy/1` stub. Freeze bodies conservative-sound (effect→Effectful/False/True/False; empty pipeline = identity), never `todo`. |
| **P3-02** IR effect & purity analysis | [`02`](phase-3/02-effect-analysis.md) | **done** | `«IROPT-IFACE-FROZEN»` | `ir/effect.gleam` real conservative classifier (E6 state ops + calls + `Charge`/`Trap`/control/`Loop` + trapping Num/Convert subsets are barriers; deep-purity `classify`/`is_pure`/`can_reorder`/`can_cse`/`can_eliminate_if_unused`/`function_is_pure`); loads never CSE'd (strongest sound under-approx); 13 adversarial "must-not" fixtures (trap-bearers asserted vs a test-side spec reimpl). 538 tests. |
| **P3-03** `ir_opt` baseline passes | [`03`](phase-3/03-ir-opt-baseline.md) | **done** | `«IROPT»`, 02 | `middle/ir_opt/baseline.gleam` + `baseline_passes() -> List(Pass)` (order: const-fold→copy/const-prop→algebraic→const-if→block/label→DCE→dead-let); const-fold dispatches to `rt_num` bit-exact (trapping ops→`Trap`; boxing ConvOps unfolded); dead-let gated on `effect.is_pure`; only safe integer algebraic identities (floats + `x/-1` excluded). `pipeline(Baseline)`=`pipeline(Aggressive)`=baseline (04 appends aggressive). 583 tests (+45). Not yet wired into the run path (09). |
| **P3-04** `ir_opt` aggressive passes | [`04`](phase-3/04-ir-opt-aggressive.md) | **done** | `«IROPT»`, 03 | `middle/ir_opt/aggressive.gleam` + `aggressive_passes()=[charge_elide, inline]`; `pipeline(Aggressive)=baseline++aggressive`. Inlining: capture-avoiding α-rename, acyclic-call-graph guard, `B_remaining` termination, single-exit `Block`+`Return→Break`, orphan-delete (exports retained); charge-elision sound only under `Aggressive⟹MeterOff` (no-op on real input). 22 tests (value+trap preservation, capture-avoidance, recursion guard, emittable via `profiles.unsafe()`). 605 tests. |
| **P3-05** `rt_meter` enforce + cost model | [`05`](phase-3/05-rt-meter-enforce.md) | **done** | `«METER-ENFORCE-FROZEN»` | Enforcing `charge/1` (ABI unchanged — arity 1, `Nil`): records consumed FIRST, then iff a budget was seeded and `consumed > budget` (strict) raises `FuelExhausted` via `rt_trap.raise` (`{wasm_trap,fuel_exhausted}`); private `budget()` reads the pdict cell. `seed_fuel` installs the per-process budget + resets the counter (re-seed = fresh cycle). Cost-model determinism + soundness + honest CPU-time-not-space scope documented in `rt_meter` module docs; the cost **values** `fn_cost`/`loop_cost` (both `1`) stay in `ir_lower` (unit 08's). **Landed GREEN: 615 tests (was 605), 0 warnings, format clean, conformance fail=0.** Unseeded path kept **observe-only** (Phase-1/2 back-compat) — `charge` cannot distinguish "forgot-to-seed" from "legacy test" in-process, so fail-closed is provided **structurally** by unit 09's seed-before-charge; documented as such. Fixed a test-isolation hazard enforcement surfaced: `opt_iface_freeze_test.rt_meter_seam_is_callable_test` seeded a budget directly in eunit's shared per-run process, leaking into later fuel-charging tests — now runs its seed in a fresh spawned process. |
| **P3-06** passthrough stdlib + widened BIF gate | [`06`](phase-3/06-passthrough-stdlib-open-bif.md) | **done** | `«UNSAFE-PROFILE-FROZEN»` | `rt_stdlib.{shared_surface/0, passthrough_route/2, resolve/4}` (single source of truth; unit 08 adopts, retiring its local copy — **note `resolve` keys on name AND arity**) — passthrough is a shim behind `stdlib_module` (emit target invariant, zero active routes; gcd stays in-house). `rt_bif.check_gated/2` (`BifAllowlist`≡`check`; `BifOpen` no-op admit of build-fixed targets, D3a intact). `passthrough≡own` differential (own≡passthrough≡mathematical gcd) + non-vacuity self-test. 630 tests (+15). |
| **P3-07** `rt_host` whitelist / open | [`07`](phase-3/07-rt-host-whitelist-open.md) | **done** | `«UNSAFE-PROFILE-FROZEN»` | `seed_policy/1`+`current_policy/0` (pdict, **fail-closed `HostDenyAll` when unseeded**) + `call_host/3` (refined `List(Int)→List(Int)`) as a fail-closed conjunction (policy-admits AND build-fixed handler exists). Build-fixed handler registry (literal `case`, no `apply/3`, D3a grep-verified); representative `("env","identity")` handler. 638 tests (+8, policy-seeding tests run per-process). Unit 09 emits `seed_policy(binding.host_policy)` in `instantiate/0`. |
| **P3-08** `ir_lower` Unsafe policy | [`08`](phase-3/08-ir-lower-unsafe.md) | **done** | `«UNSAFE-PROFILE-FROZEN»`, 06 | Posture-aware `lower/2` reads `meter`/`stdlib`/`bif_gate` (retires the `mode` dispatch). `MeterOff`→zero `Charge` (absence, not `Charge(0)`); `MeterFuel`→Phase-2 insertion (`fn_cost`/`loop_cost`=1 here). Adopts `rt_stdlib.shared_surface`/`resolve` (single source; name-then-arity mapping preserves `UnknownStdlibFn` vs `BifNotAllowed`); `rt_bif.check_gated`. **Safe byte-identical** (conformance 15747/0). Seam for 09: `pub resolve_stdlib_fn(name, arity, binding) -> Result(BifTarget, Nil)`. 643 tests. |
| **P3-09** emit_core Unsafe + pipeline opt + CLI | [`09`](phase-3/09-emit-pipeline-opt.md) | **done** | `«IROPT»`, `«UNSAFE»`, `«METER»`, 08 | Pipeline is now `source_to_ir → lower_ir → optimize_ir → emit_core` (`ir_opt.optimize` at `binding.opt_level`; `OptNone` bypass). **Optimizer runs the baseline passes over the whole corpus end-to-end — conformance `fail=0`, no discrepancy.** `emit_instantiate` prepends the seed exception (`seed_fuel` first under MeterFuel, `seed_policy` always; fixed atoms → D3a-safe); hot bodies posture-agnostic. CLI `opt` verb + `--unsafe` (default Safe). D3a-under-`open` security test added. Safe/Unsafe `.core` differs by exactly charge + seed lines. 654 tests (+11). |
| **P3-10** linker: `profiles.unsafe()` + coexistence | [`10`](phase-3/10-linker-unsafe-profile.md) | **done** | `«UNSAFE-PROFILE-FROZEN»`, 08, 09 | `unsafe()` first-class (field-by-field F4) + `unsafe_instance()` + `safe_metered(budget)` (Safe-only budget channel) + `coexist_name/2` (Safe→base, Unsafe→base_unsafe, distinct atoms). **B3 coexistence proof**: one stateful source compiled twice → distinct `.beam` atoms sharing `rt_*` → both on one node, each in its own process → byte-identical results + memory/global isolation both directions. `instance.gleam` untouched (D1). 659 tests (+5). |
| **P3-11** capstone | [`11`](phase-3/11-capstone.md) | **done** | all above | **PHASE 3 PROVEN.** Optimizer-soundness differential (`OptNone`≡`Baseline`≡`Aggressive`, byte-identical + spec-correct across the whole corpus — **no discrepancy**), Safe≡Unsafe (B3) differential, zero-overhead-Unsafe (0 `charge`/`rt_meter` in the Unsafe `.core`), real-metering trap (tail `spin` constant-space + non-tail `recurse` under `safe_metered`, deterministic `fuel_exhausted`), Safe+Unsafe coexistence (real `iso.wasm` state isolation **and** host capability isolation), conformance `fail=0` **under both profiles** (15747/411/0), SVG refreshed. Honest benchmark committed (`smoke/bench.sh`, `docs/phase-3-benchmark.md`). **673 tests (was 659), 0 warnings, format clean.** Deviations (all justified, flagged): (a) `emit_core` now emits `call_host` cap/name as BINARY strings (was atoms) so `HostOpen`/`HostWhitelist` dispatch actually fires — a documented-deferred gap the F4 capability proof surfaced; the one structural `emit_core_test` arm updated. (b) `driver.pipeline()` now = `pipeline_with(profiles.safe())` (full `ir_lower→optimize→emit` chain), conformance still 15747/0. (c) CLI `to-beam-wasm [--unsafe]` verb added (the bench compile path unit 09 flagged). **Benchmark findings (honest, F8):** 2core-Safe is currently SLOWER than hand-written Erlang (CRC-32, ~76×) and the native NIF ceiling (SHA-256/DEFLATE, 100s-1000s×) on the tier-O memory model — "faster than hand-written Erlang" is measured as NOT-YET, motivating the Phase-4 tier ladder; and the **Aggressive inliner** originally did not scale to the 80-function smoke module (compile-time explosion) — a compile-time-only limitation, NOT a soundness bug. **Fixed (post-capstone):** an absolute whole-module node ceiling (`inline_node_ceiling = 65536`, clamping `budget = max(0, min(8·nodes+4096, ceiling−nodes))`) makes the inliner degrade gracefully (fills to the ceiling then cleanly stops; small/corpus modules unchanged; root cause was `run_pipeline` recomputing the input-scaled budget each fixpoint round over the enlarged module). 674 tests. |

### High-level spec coverage this phase takes

| High-level item | Taken by | Notes |
|---|---|---|
| §4 M2 optimizer (`ir_opt`) | P3-02/03/04 | `baseline` (both modes) + `aggressive` (Unsafe-only); breadth bounded (no LICM/BCE/SIMD). |
| §6 Unsafe mode | P3-06/07/08/09/10 | Aggressive opt + passthrough stdlib + widened BIF + no metering + host whitelist/open; B3 coexistence. |
| §6 Safe-mode CPU resource bound | P3-05 | Enforcing fuel (FuelExhausted), fail-closed-armed; closes the CPU-time gap (memory was Phase-2). |
| §4 R-std `passthrough` / R-bif `open` | P3-06 | Mechanism shipped (zero active routes; gcd in-house); passthrough behind `stdlib_module`. |
| §4 R-host `whitelist`/`open` | P3-07 | Per-instance seeded; deny-all default preserved. |
| §10 binding models B1/B3 | P3-10 | Phase-3 realizes **B3** (per-profile builds) + per-instance seeded policy; single-`.beam` B1 deferred. |

### Deferred to Phase 4+ (explicit)

**Phase 4** (trust-tier ladder & runs-anywhere): tier-P `threaded` state; tier-O/N `rt_mem`
(`atomics`/`nif`); `rt_table` tiers; single-`.beam` runtime-dispatch B1. **Phase 5** (complete
WASM engine): reference types; bulk memory; multi-memory; `memory64`; the WAT text parser;
non-function imports + `spectest`. **Phase 6+**: the Porffor JS→WASM bridge; Gleam/Erlang frontends;
exception-handling / GC / stack-switching / component model. *(Also deferred within Phase 3: LICM,
range-based bounds-check elimination, SIMD vectorization, pure-call CSE.)*

---

## Phase 4 — "Free-standing": the trust-tier ladder (tier-P threaded state + tier-O/N memory)

Goal & honest scope: see [`specs/phase-4/00-overview.md`](phase-4/00-overview.md) (decisions
**G1–G8**). Phase 3's honest benchmark measured tier-O paged memory as **~76× slower than
hand-written Erlang**, and the platform's "no OTP, no NIF, runs-anywhere" headline was still
unbuilt. Phase 4 makes the **trust-tier axis** (high-level §10) real: the tier-P **`threaded`**
state strategy (a purely-functional instance-state record threaded through generated code — the
runs-anywhere build) and the tier-O/N **memory & table backends** (`atomics` O(1) process-local;
`nif` the raw ceiling). The keystone is the **`state_strategy` axis** — the `emit_core` seam
*expansion* Phase-2 E1 promised (the IR is tier-agnostic, so the retrofit is confined to
`emit_core` + the runtime). **No new frontend surface, no new IR node types.** `state_strategy` &
`mem_tier` are compile-time (**B3** — a threaded build and a cell build are different `.beam`s).

### Phase-4 freeze milestones

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«STATE-STRATEGY-FROZEN»` — `Binding.state_strategy: {Cell,Threaded}` + the threaded `InstanceState` record (reuses the Phase-2 box) + tier-P `rt_state` threaded sigs + the `emit_core` seam-expansion contract (uniform-threading rule; St as leading LoopParam; record-returning `instantiate`) + `coexist_name` keyed on `(mode,state_strategy,mem_tier)` | P4-01 | **FROZEN ✓** | 02, 03, 08, 09, 11 |
| `«MEM-TIER-FROZEN»` — `Binding.mem_tier: {Paged,Atomics,Nif}` + `table_tier` + the uniform `rt_mem`/`rt_table` backend interface + the tier→module link map + `link/1` (validate+resolve_tiers+instantiate) as the SOLE seam + Safe-forbids-nif fail-closed | P4-01 | **FROZEN ✓** | 04, 05, 06, 07, 08 |

### Phase-4 units (specs authored + critiqued + reconciled; implementation `unclaimed`)

| Unit | Doc | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|---|
| **P4-01** Interface freeze (keystone) | [`01`](phase-4/01-interface-freeze.md) | **done** | — | **Landed GREEN: 679 tests (was 674), 0 warnings, format clean, conformance 15747/411/0.** `instance.gleam`: 3 enums (`StateStrategy{Cell,Threaded}`/`MemTier{Paged,Atomics,Nif}`/`TableTier{TablePaged,TableEts,TableAtomics}`) + 3 `Binding` fields `state_strategy`/`mem_tier`/`table_tier` (safe_default = `Cell`/`Paged`/`TablePaged`, Phase-2/3 posture byte-identical). `mem_module`/`table_module`/`state_module` stay on `Binding` (the load-bearing fields `emit_core` links; unit 07's `resolve_tiers` couples tier→module). **`coexist_name` signature changed** `(base, mode)`→**`(base, binding)`**, keyed on `(mode,state_strategy,mem_tier)` in fixed order `_unsafe`/`_threaded`/`_atomics`|`_nif` (default Safe/Cell/Paged appends nothing = canonical base, conformance-neutral). Reaches landed: `safe_default()` (the ONE full constructor; all else record-spreads absorb the new fields); 3 `coexist_name` callers (`coexistence_test`/`linker_coexist_test`/`profiles_test`) → new sig (unused `Safe`/`Unsafe` imports dropped from the two coexist tests). New `test/twocore/runtime/tier_freeze_test.gleam` (5 spec tests: axes expressible; fail-closed Cell/Paged/TablePaged defaults incl. unsafe(); Safe+Nif unconstructible; threaded box round-trips; coexist keys on full build identity). **DOC-frozen only (no stub bodies → no warnings):** the threaded `rt_state`/`rt_mem`/`rt_table` `t_*` sigs, tier→module map, `resolve_tiers`/`validate_binding`/`link/1`, `portable`/`ceiling` — units 02–07 implement. No IR/`TrapReason`/grammar change (G7). **Flag (per §B.1):** each mem/table tier is its OWN new module (D1 single-owner), NOT `rt_mem.gleam (extend)` — supersedes overview §4's shorthand. |
| **P4-02** emit_core threaded seam | [`02`](phase-4/02-emit-threaded-seam.md) | **done** | `«STATE-STRATEGY»` | Seam expansion: state-reaching fns thread `St` (`f(St,args)→{Pkg,St'}`); St a leading LoopParam (constant-space back-edge, G4); record-returning `instantiate`; **export_name==fn_name exports the internal def directly (no colliding wrapper)**; Cell byte-identical; D3a test extended. |
| **P4-03** rt_state threaded (tier-P) | [`03`](phase-4/03-rt-state-threaded.md) | **done** | `«STATE-STRATEGY»` | **Landed GREEN: 687 tests (was 679), 0 warnings, format clean, conformance fail=0.** The purely-functional tier-P surface added to `rt_state.gleam` (additive; the cell surface untouched): `fresh(decl)→InstanceState` (returns the record, no pdict), `t_global_get(st,name)→Int` (fail-closed on undeclared), `t_global_set(st,name,value)→InstanceState` (rebind one field), + the record field seam `mem`/`with_mem`/`table`/`with_table` (opaque `Dynamic` in/out — NO rt_mem/rt_table import, opacity preserved). `seed`→`build` refactor: `seed` and `fresh` share ONE private `build(decl)` constructor so a `Cell` and a `Threaded` build materialise BYTE-IDENTICAL state (G7); `seed`'s behaviour unchanged (the only edit to a frozen fn). Runs-anywhere proven: the tier-P sub-graph reaches NONE of the module's 3 pdict externals (`erlang_put`/`erlang_erase`/`read_cell` — all cell-path), grep- + behaviourally-confirmed (a tier-P op sequence leaves the cell un-seeded). 8 spec-grounded tests (fresh round-trip; fresh≡seed parity; pure global set/get value semantics; float bit-exact D5; two records never share; no-pdict; field-seam opacity). **Hands off to:** 02 (emits `t_global_get`/`t_global_set` + `fresh`-returning `instantiate`), 04/06 (compose the `mem`/`with_mem`/`table`/`with_table` seam with the pure `mem_*`/table core). Constant-space-under-threaded-loop is unit 09's (mechanism = fixed-size 3-tuple box). |
| **P4-04** rt_mem_atomics (tier-O) + paged t_* | [`04`](phase-4/04-rt-mem-atomics.md) | **done** | `«MEM-TIER»` | NEW `rt_mem_atomics.gleam` (O(1) LE, engages only when eff max ≤ reserve cap else fail-closed) + (additive to `rt_mem.gleam`) the paged threaded wrappers `t_load/t_store/t_size/t_grow/t_init_data` (**`t_grow` charges `rt_meter` fuel like Cell**) + `to_flat(Dynamic)` + a public `Dynamic→Mem` coercion. Differential vs the oracle. |
| **P4-05** rt_mem_nif (tier-N) | [`05`](phase-4/05-rt-mem-nif.md) | **done** | `«MEM-TIER»` | NEW `rt_mem_nif.gleam` (uniform interface, **Safe-forbidden**) + reference skeleton (production C NIF documented-deferred — no native toolchain; honest, not the ceiling). |
| **P4-06** rt_table tiers (tier-O) + paged t_* | [`06`](phase-4/06-rt-table-tiers.md) | **done** | `«MEM-TIER»` | NEW `rt_table_ets.gleam`/`rt_table_atomics.gleam` (3-fault fail-closed dispatch, no ambient authority) + (additive to `rt_table.gleam`) the paged threaded `t_init_elem`/`t_call_indirect`. |
| **P4-07** linker + profiles compose | [`07`](phase-4/07-linker-profiles-compose.md) | **done** | `«MEM-TIER»` | `resolve_tiers` (single source: sets `mem_module`/`table_module` from tier) + `validate_binding` fail-closed + `link/1` sole seam; `portable()` (tier-P instance state; fuel/host are node-safe tier-O overlays) + `ceiling()` (Unsafe+Atomics, requires a cap). Owns `profiles.gleam` only. |
| **P4-08** pipeline + CLI tier select | [`08`](phase-4/08-pipeline-cli-tier-select.md) | **done** | `«STATE»`,`«MEM-TIER»` | Run-ABI/CLI route EVERY binding→Instance through `link/1`; CLI flags (`--portable`/`--tier`/`--threaded`, default Safe/Cell/Paged fail-closed) run `resolve_tiers` so `--tier atomics` actually links atomics; threaded run-ABI threads the record across invokes. |
| **P4-09** tier differential | [`09`](phase-4/09-tier-differential.md) | **done** | 02–08 | Every shipped `(state_strategy × mem_tier)` gives byte-identical corpus results + spec-expected; **constant-space-under-threaded** proof; **memory.grow trap-parity** across strategies (proves `t_grow` fuel); the runs-anywhere grep (0 native + 0 rt_state cell seam; fuel/host pdict exempt). |
| **P4-10** benchmark revisit | [`10`](phase-4/10-benchmark-revisit.md) | **done** | 04, 08 | Honest re-measure of CRC-32/SHA-256/DEFLATE with tier-O `atomics` (capped so it engages) vs paged/hand-written/native; real numbers + methodology; `docs/phase-4-benchmark.md`. |
| **P4-11** capstone | [`11`](phase-4/11-capstone.md) | **done** | all above | **PHASE 4 PROVEN.** Full-matrix conformance `fail=0` under every shipped `(state_strategy × mem_tier)` combo (15747/411/0 each); the **runs-anywhere headline** (tier-P `portable` grep-verified 0 native + 0 instance-cell seam AND executed byte-identical to the cell/paged oracle); tier differential (09) + benchmark (10) confirmed green; SVG refreshed to Phase-4 scope; honest close (atomics shipped; C NIF deferred). **906 tests (was 894), 0 warnings, format clean.** |

### High-level spec coverage this phase takes

| High-level item | Taken by | Notes |
|---|---|---|
| §10 trust tiers P/O/N (state) | P4-01/02/03 | tier-P `threaded` state (runs-anywhere) alongside the Phase-2 tier-O `cell`. |
| §10 `rt_mem` tier ladder | P4-04/05 | `atomics` (O, O(1), shipped) + `nif` (N, interface + skeleton, Safe-forbidden; C deferred). |
| §10 `rt_table` tiers | P4-06 | `ets`/`atomics` (tier-O). |
| §10 binding models | P4-07/08 | Phase-4 realizes **B3** monomorphization (per-tier builds) + `link/1` sole validated seam; single-`.beam` B1 still deferred. |
| §6 Safe forbids tier N | P4-01/07 | fail-closed: `Safe + nif` unconstructible + `validate_binding` gate on the sole seam. |
| §11 tiered interface-conformance + differential oracle | P4-09 | every tier held to the `rebuild` oracle; every `(strategy×tier)` byte-identical. |

### Deferred to Phase 5+ (explicit)

**Phase 5** (complete WASM engine): reference types; bulk memory; multi-memory; `memory64`; the
WAT text parser; non-function imports + `spectest`; SIMD. **Phase 6**: the Porffor JS→WASM bridge.
**Later**: Gleam/Erlang frontends; exception-handling / GC / stack-switching / component model; the
single-`.beam` runtime-dispatch **B1**; tier-N numerics; a production C NIF for tier-N memory.

---

## Phase 5 — "The complete WASM engine" (reference types + bulk memory + multi-memory + non-function imports/spectest + the WAT parser)

Goal & honest scope: see [`specs/phase-5/00-overview.md`](phase-5/00-overview.md) (decisions
**H1–H8**) and the AUTHORITATIVE [`specs/phase-5/RECONCILIATION.md`](phase-5/RECONCILIATION.md)
(decisions **R1–R18** — override the unit docs on conflict). Phases 1–4 built a correct, sandboxed,
fast, runs-anywhere platform for a **partial** WASM surface; Phase 5 grows it to the **complete
standardized surface minus SIMD**. It is the **first phase since Phase 2 to grow the IR** (the
reference value layer + the effectful table/bulk nodes + the memory-index axis), kept
language-neutral (H7) and conformance-neutral by default. **SIMD → Phase 6; memory64's runtime →
Phase 6 (R12 — the IR axis stays, decode/validate only).** With the surface complete, *JS on the
BEAM via Porffor* becomes a reachable **goal** (not a future phase): the WASM Porffor emits is
largely runnable through `fe_wasm` today — the remaining work is a Porffor-ABI host shim (§8.2).

### Phase-5 freeze milestones (planned)

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«IR3-FROZEN»` — `ir.gleam` reftype `ValType`s + `ConstNull`/`RefFunc`/`RefIsNull` + table/bulk `Expr` nodes + `Module.memories`/mem-index + `IdxType` + import/export state variants + `TableDecl.ref_ty` + passive/droppable segment model + `.ir` grammar delta; **`runtime/rt_ref.gleam`** (forge-proof ref values, R1) | P5-01 | **FROZEN ✓** | 02, 05, 06, 07, 09, 10 |
| `«RT3-SIG-FROZEN»` — extended `rt_state` (record + stub accessors, R5) / `rt_mem` / `rt_table` signatures (todo-free) + the `rt_ref` helpers | P5-01 | **FROZEN ✓** (rt_state record + index/drop/ref accessors + `rt_ref` landed; rt_mem/rt_table bulk/ref heads doc-frozen §G for 07/08) | 06, 07, 08, 09 |
| `«INSTANTIATE3»` — `instantiate/0 | instantiate/1(List(Provided))` + `link_imports` fail-closed contract (R4) + the `spectest` provider (R14) | P5-01 (sig) / P5-09 (impl) | **sig FROZEN ✓** (IR `ImportGlobal/Table/Memory` + `ExportGlobal/Table/Memory` + arity-0/1 rule frozen; `Provided`/`link.gleam`/`spectest` → P5-09 per R4) | 06, 09, 11 |
| `«WASM-AST3»` — extended `frontend/wasm/ast.gleam` (reftypes, ref/table/bulk instrs, memarg memidx, `IdxType`, segment modes, non-function imports/exports, datacount) | P5-03 | **PUBLISHED ✓** (types + full decode landed; see P5-03 row for the exact shapes) | 04, 05, 10 |

### Phase-5 units (specs authored + critiqued + reconciled; implementation `unclaimed`)

| Unit | Doc | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|---|
| **P5-01** Interface freeze (keystone) | [`01`](phase-5/01-interface-freeze.md) | **done** | — | IR3 (`ir.gleam`: reftypes/`ConstNull`/ref+table+bulk `Expr` nodes/`Module.memories`+mem-index/`IdxType`/`TableDecl.ref_ty`/`Elem`+`DataMode`/import+export state variants; `TrapReason` reused) + **`runtime/rt_ref.gleam`** (forge-proof R1) + `rt_state` grown record (memories/tables vectors, drop-state sets, `ref_globals`) with todo-free index/drop/ref accessors + Phase-4 index-0 aliases (R5–R8) + `effect.gleam` barrier classification + minimal compile-satisfying arms in printer/parser/emit_core/lower/ir_lower/ir_opt. **Lands GREEN, byte-identical: 912 tests pass (906 + 6 new `ir3_freeze_test`), 0 warnings, format clean, conformance 15747/411/0.** |
| **P5-02** `.ir` printer/parser ext | [`02`](phase-5/02-ir-textual-form.md) | **done** | `«IR3»` | `.ir` round-trips the FULL IR3 surface (`parse(print(m))==m`): reftype valtypes + `RefType`, the `null.<reftype>` `ConstNull` value (R1c — no `ref.null` `Expr`), `ref.func`/`ref.is_null`, every `table.*`/`elem.drop`/`mem.fill`/`mem.copy`/`mem.init`/`data.drop`, the omit-when-zero `mem=`/`dst_mem=`/`src_mem=` decorators + mandatory `seg=`, multi-memory + `memory i64` (memory64), the import/export state variants, and passive/declarative segments with ref-init items. Total parser (garbage battery, incl. new malformed forms, returns typed `ParseError`, no panic). New hand-authored `golden/refs_bulk.ir` + independent expected `Module`; 4 existing goldens still parse; **legacy modules print byte-identically** (asserted). Grammar reconciled: **`specs/phase-5/ir-grammar-delta.md`** (cross-linked from `ir-grammar.md`). **1212 tests pass (was 1195), 0 warnings, format clean, conformance 21525/1257/0 unchanged.** |
| **P5-03** decode ext (+ `«WASM-AST3»`) | [`03`](phase-5/03-decode.md) | **done** | — | **`«WASM-AST3»` PUBLISHED + full decode landed GREEN: 948 tests (912 + 36 new decode tests), 0 warnings, format clean, conformance fail=0 (local 1892/229/0-shape unchanged; matrix fail=0).** `ast.gleam` delta for 04/05/10: `ValType` gains `FuncRef`/`ExternRef` (no separate AST `RefType` — the funcref/externref subset; narrow to IR3 `RefType` at lower); `IdxType{Idx32,Idx64}`; `MemType(limits, idx_type)`; `TableType(elem_type, limits)`; `MemArg(align, offset, mem)` (offset now **u64**); `Import(module,name,desc)` + `ImportDesc{ImportFunc(type_idx)|ImportTable(TableType)|ImportMemory(MemType)|ImportGlobal(ty,mutable)}`; `ElementSegment(mode, ref_ty, init)` + `ElemMode{ElemActive(table,offset)|ElemPassive|ElemDeclarative}` + `ElemInit{ElemFuncs(List(Int))|ElemExprs(List(List(Instr)))}`; `DataSegment(mode, bytes)` + `DataMode{DataActive(mem,offset)|DataPassive}`; `Module` gains `imports`/`data_count` (`imported_func_count` now COMPUTED); new `Instr`: `RefNull(ref_ty)`/`RefIsNull`/`RefFunc(func)`/`TableGet(table)`/`TableSet(table)`/`SelectT(types)`/`MemoryInit(data,mem)`/`DataDrop(data)`/`MemoryCopy(dst_mem,src_mem)`/`MemoryFill(mem)`/`TableInit(elem,table)`/`ElemDrop(elem)`/`TableCopy(dst_table,src_table)`/`TableGrow(table)`/`TableSize(table)`/`TableFill(table)`; `MemorySize`/`MemoryGrow` now carry `mem: Int`. **Field order is WIRE order (R3):** `MemoryInit(data, mem)`, `TableInit(elem, table)` — anti-swap fixtures included. `DecodeError`: +`BadHeapType`/`BadImportKind`/`DataCountMissing`/`DataCountMismatch`, −`BadRefType`/`BadMemoryIndex` (now unreachable). Owns the datacount wellformedness check (R13 + `data_count==length(data)`). **Keystone-reach compile fixes** (P5-04/05 replace): validate/lower fail-closed on new shapes + a new `validate.OffsetOutOfRange` (u64 memarg offset → i32-memory `>= 2^32` reject, restores `align.wast` "offset out of range"). |
| **P5-04** validate ext | [`04`](phase-5/04-validate.md) | **done** | `«WASM-AST3»` | **Landed GREEN: 986 tests (+38), conformance 15749/409/0 fail=0, conformance-neutral.** Real typing for the full surface (ref instrs + `C.refs`; typed `select` arity-1; reftype multi-tables; bulk mem/table wire-order immediates R3 + reftype-match; multi-memory memidx; memory64 i64-address typing accept-but-runtime-deferred R12; passive/declarative segments; non-function import shapes). `ValidateError` +`UnknownData`/`UnknownElem`/`UndeclaredFunctionRef`/`RefTypeMismatch`/`BadSelectType`/`UnknownImportKind`. **`TypedModule` for 05:** `imported_{global,table,memory}_count`, `func_types`/`global_types` (imports++defined), `table_types`, `memory_idx_types`, `elem_types`, `refs: Set(Int)` (C.refs). Import *satisfaction* → P5-09; lower rejects `Idx64` (R12). |
| **P5-05** lower ext | [`05`](phase-5/05-lower.md) | **done** | `«WASM-AST3»`, `«IR3»` | **Landed GREEN: 1001 tests (+15), conformance 15749/409/0 + 1894/227/0, byte-identical.** AST3→IR3 for the full surface: `ref.null`→`ConstNull` Value (R1c), `ref.func`→`RefFunc`, tables→`Table*`, bulk R3 field-remap (`MemoryInit(data,mem)`→`MemInit(mem,seg=data)`; `TableInit(elem,table)`→`TableInit(table,seg=elem)`), `SelectT`→`If` merge, multi-memory index threaded, mode-aware element/data + reftype tables + non-function imports/exports. **Rejects `Idx64` (`Memory64Unsupported`, R12).** **Naming for 06 (R7):** tables `t<imported+i>`, globals `g<imported+j>`, memories absolute; `Module.memories` = defined-only. **Left:** imported-memory vector wiring (imported++defined) + imported-fn calls → P5-09. |
| **P5-06** emit_core ext | [`06`](phase-5/06-emit-core.md) | **done** | `«IR3»`, `«RT3-SIG»` | **GREEN + BYTE-IDENTICAL: 1121 tests (+19), conformance 15749/409/0 + 1894/227/0 unchanged.** Emits all new IR3 nodes through the seam: refs (ConstNull sentinel/RefFunc entry/RefIsNull — PURE, fixed keystone mis-classification), tables (idx-based rt_table + drop-gate R2 + init_elem/init_elem_ref split), bulk mem (fill/copy/init + drop-gate + DataDrop/ElemDrop→rt_state), multi-mem routing (mem==0 frozen head byte-identical, mem>0 `_at`), `instantiate/1` weaving Provided→FullDecl + export-of-state. State-reaching new nodes thread St under Threaded; D3a test extended (rt_ref/link allow-set). **e2e reftype/bulk/multi-mem/import programs run on the BEAM under Cell+Threaded.** **Gaps (categorized skips):** multi-table `call_indirect` (needs a `call_indirect_at` head), imported-global element-init — assess at 11. |
| **P5-07** rt_table ext | [`07`](phase-5/07-rt-table.md) | **done** | `«RT3-SIG»` | **GREEN: 1045 tests (+44).** Typed ref tables (null=slot-absence → call_indirect byte-identical); idx-based get/set/size/grow(-1)/fill/table.init/table.copy + `init_elem_ref`, cell + threaded twins, all tiers; eager-bounds R10, memmove R11, O(N) fuel in the shared op-core R9, payload-as-arg R2. emit_core (06) calls the idx-based sigs + the drop gate. |
| **P5-08** rt_mem ext | [`08`](phase-5/08-rt-mem.md) | **done** | `«RT3-SIG»` | **GREEN: 1076 tests (+31).** Bulk memory fill/copy/init (paged/atomics/nif-skel), cell + threaded twins, differential vs oracle; exact eager-bounds R10, memmove incl. cross-memory R11, O(N) wrapper fuel R9, payload-as-arg R2. Frozen non-indexed heads byte-identical (index-0); `_at`/bulk heads route multi-mem via rt_state. memory64 runtime deferred R12. |
| **P5-09** imports + spectest + linker | [`09`](phase-5/09-imports-spectest-linker.md) | **done** | `«RT3-SIG»`, `«INSTANTIATE3»` | **GREEN: 1102 tests (+26).** `link.gleam` (NEW): `Provided`/`ImportError`/`link_imports` fail-closed §3.2 matching (R4). Full `spectest` in rt_host (7 print arms + globals 666/666.6-bits + table(10,20) + memory(1,2), D3a literal case, R14). `rt_state` general seeding via `FullDecl`+`seed_full`/`fresh_full` (StateDecl kept byte-identical; imported-first index order R7; ref_globals R8) + export-of-state reads. `profiles.safe_spectest`. **06 emits instantiate/1 + weaves Provided→FullDecl; 11 drives link_imports.** |
| **P5-10a** WAT parser (lexer + parse_module) | [`10`](phase-5/10-wat-parser.md) | **done** | `«WASM-AST3»` | **GREEN: +34 tests (1154 total), 0 warnings, format clean, conformance unchanged 15749/409/0 + 1894/227/0.** `frontend/wasm/wat.gleam` (NEW): publishes `«WAT-API-CORE»` — `lex`, `parse_module`, `WatError`/`Token`/`Pos`/`LexErrorKind`/`Category`. Full Phase-5 module surface (folded+flat instrs, abbreviations, `$id` resolution across all index spaces, `(type)` dedup in depth-first source order matching wabt, inline import/export, inline table+elem / memory+data, reftype/bulk/table/multi-mem/memory64 text, datacount rule R13). Number→bits (D5/R15): hex-float + `nan:0x` bit-exact; decimal floats exact via big-int round-ties-even (float-torture diffed vs wabt). Totality (D4): typed errors + truncation fuzz, no panic. **Differential proven** `parse_module ≡ decode∘wat2wasm` (wabt 1.0.41, flags `--enable-multi-memory --enable-memory64`; NOT `--enable-all` → that enables non-standard compact-imports) over a curated Phase-5 corpus + the acceptance corpus; ~300 malformed spec fixtures exercise totality. **Leaves for 10b:** `parse_script`/`Script`/`WastValue` (builds on `lex`+`parse_module`). **Leaves for 11:** the `Script`→fixture adapter. |
| **P5-10b** WAT script layer (`parse_script`) | [`10`](phase-5/10-wat-parser.md) | **done** | P5-10a (`«WAT-API-CORE»`) | **GREEN: +16 tests (1170 total), conformance unchanged.** `parse_script → Script` in `wat.gleam`: `Command` (WatModule/Register/AssertReturn/Trap/Exhaustion/Invalid/Malformed/Unlinkable/Uninstantiable/ActionCmd/CmdSkipped), `ModuleDef` (Text/Binary/Quote), `Action` (Invoke/Get), `WastValue` (i32/i64/f32/f64 raw bits + `RefNullVal`/`RefFuncVal`/`RefExternVal` R18), `Expected` (Value/NanCanonical/NanArithmetic). `$id` recorded as name only (11's `registry.resolve` resolves). Differential vs `wast2json` (command count+kind parity); `(module binary)` round-trips + decodes, `(module quote)` re-parses; total. **11 writes the `Script`→`fixture` adapter + `SpecValue` ref variants + deletes the "no WAT parser" skip.** |
| **P5-11** conformance expansion | [`11`](phase-5/11-conformance-expansion.md) | **done** | 03–10 | **GREEN: 1180 tests (was 1170), 0 warnings, format clean; conformance `fail=0` under BOTH profiles (Safe/Unsafe each 21512 pass / 1270 skip / 0 fail) + the full tier matrix (cell/threaded × paged 7565/1180/0; × atomics 7532/1179/0; cell×nif 7565/1180/0).** MEASURED headline (R16): **pass rose +5763 (15749→21512)** as reftype+bulk categories lit up; new files added via wast2json DEFAULT flags at the pin (empirically re-verified): `ref_func table_get table_set table_size table_grow table_fill table_copy bulk memory_fill memory_copy memory_init data`. Reference values wired through `fixture.SpecValue` (`NullRef`/`ExternRefVal`/`FuncRefVal` R18) + oracle (null-by-type / externref-by-identity / funcref-any-nonnull) + a term invoke-ABI (`ffi.call_instance_terms`/`result_list`/`extern_payload`, `rt_ref`) that also delivers the **multi-value run-ABI (R17)** — the numeric single-result path stays byte-identical. Imports/spectest/link driven via `link.link_imports` (spectest built-in → import-free `instantiate/0` vs `instantiate/1(Imports)` dispatched by import-presence); `Get`→exported-global accessor; `assert_unlinkable`→fail-closed `link:` phrase. WAT-only path: text `assert_malformed`/`assert_invalid` fragments now route through `wat.parse_module` (deleted the "no WAT parser" skip; float_literals +16 passes); new `wat_fixture.gleam` adapter (`Script`→drive, sole consumer of `parse_script`, R15) proven on an authored in-scope `.wast` (6/6). New-surface tier differential `refexpansion_differential_test` (reftab/bulkmem/multimem `.wat` — reference/table, bulk memmove+eager-bounds, **multi-memory execution+cross-mem copy** — spec-correct AND byte-identical across all 5 shipped combos) + a guarded `wasmtime` differential (§F.2). `skipcount_test` guards fail=0, pass↑, residual closed+categorised. **Residual honesty (D9): skip 1270 = the two KNOWN EMIT GAPS (multi-table `call_indirect` 1092 asserts — `table_copy` verifies via non-zero-table calls; imported-global/ref.func element-init 9) + 169 categorised out-of-scope (GC-proposal reftypes, extended-const, cross-module state import, exhaustion, out-of-scope text). Residual EXCLUDING the two emit gaps = 169 < the Phase-4 baseline 409 — the material drop once the engine gaps are set aside (a follow-up for 12/emit-owner).** **Categorized/deferred (never false-green, R16):** GC-proposal reftype files (`ref_null`/`ref_is_null`/`elem`/`select`/`table_init` — `anyref`/typed-refs/array un-`wast2json`-able AND out of our funcref/externref scope), EH (`imports.wast` `tag`), module-linking (`memory`/`table` `(module definition)`), multi-memory `memory_grow` (spectest-interp 0/50 at pin). **Cross-unit finding (P5-09):** `link.spectest_export` builds provided memory/table with the PAGED tier unconditionally → importing spectest memory under an `atomics` binding hands a paged handle to atomics code (`badarg`); handled honestly by excluding the one spectest-state importer (`data.wast`) from the non-paged matrix combos (green under paged + both full profiles; its bulk semantics tier-covered by own-memory `memory_*`). No src touched. |
| **P5-12** capstone | [`12`](phase-5/12-capstone.md) | **done** | all above | **PHASE 5 PROVEN. 1195 tests (was 1189), 0 warnings, format clean.** Full surface green end-to-end under both modes × every shipped `state_strategy × mem_tier`; conformance `fail == 0` (Safe/Unsafe 21525/1257/0; matrix cell/threaded×paged + cell×nif 7578/1167/0, ×atomics 7544/1167/0). Pass rose **+5776** (15749→21525) with the residual **fully categorized + closed** (skipcount guard). New `new_surface_test.gleam` (reftab/bulkmem/multimem spec-correct + byte-identical across safe/unsafe/portable; Phase-1..4 corpus mode-neutral) + extended `runs_anywhere_test.gleam` (new-surface portable: 0 native + 0 instance-cell seam, threaded families non-vacuous, executed byte-identical to the cell/paged oracle) + `conformance_test.gleam` (the two full-profile runs now carry the surface headline `pass > baseline`). `docs/wasm-conformance.svg` regenerated (21525/1257/0, Phase-5 footnote) + `docs/phase-5-surface.md` (before/after + categorized residual). Confirmed green (not re-derived): P5-11 skipcount/refexpansion/wasmtime, P5-10 WAT differential, unit 06 emitter byte-identity. |

### High-level spec coverage this phase takes

| High-level item | Taken by | Notes |
|---|---|---|
| §12 reference types | P5-01/03/04/05/06/07 | `funcref`/`externref` (term-layer values, R1); `table.*`; typed `select`; multi-table; passive/declarative elements. GC-proposal reftypes deferred. |
| §12 bulk memory | P5-03/04/05/06/07/08 | `memory.*`/`table.*` bulk + passive/droppable segments; exact eager-bounds + memmove + O(N) fuel. |
| §12 multiple memories | P5-01/03/04/05/06/08 | memory-index axis; `memories: List`; index-0 byte-identical. |
| §12 `memory64` | P5-03/04 (front only) | decode/validate only; **runtime → Phase 6 (R12)**. |
| §8/§13 non-function imports + WASI-adjacent host | P5-09 | imported globals/tables/memories as provided state; the `spectest` host module; fail-closed link. |
| §12 WAT text parser | P5-10 | text → `«WASM-AST3»` + `.wast` script layer; differential vs `wat2wasm`. |
| §11 differential + interface conformance | P5-11 | the new surface held to `wasmtime` + the `rebuild` oracle under the full matrix. |

### Deferred to Phase 6+ (explicit)

**Phase 6**: SIMD (`v128` + ~236 lane ops); memory64 runtime. **Goal — JS on the BEAM via Porffor**
(a stated direction, *not* a future phase): *any Porffor application runs via 2core on the BEAM*.
The completed WASM 2.0-minus-SIMD surface makes the WASM Porffor emits largely runnable through
`fe_wasm`; the work remaining to reach the goal is a **Porffor-ABI `rt_host` shim** (Porffor's own
runtime ABI, not WASI) — not yet built or tested. **Later**: a Gleam/Erlang frontend;
exception-handling / GC (incl. GC-proposal reftypes) / stack-switching / component model; the
single-`.beam` **B1** binding; tier-N numerics; a production C NIF; the extended-const proposal.

**A dedicated performance/optimizer phase (sequel to Phase 3, distinct from Phase 6's surface work)**
is where the **memory optimizer** lands — MemorySSA + linear-memory alias analysis + range-based
bounds-check elimination + LICM + store→load forwarding + dead-store elimination, to close the
per-access residual (`atomics` fixed the O(page) headline; this attacks the seam-fetch + bounds-check
overhead, trust-neutrally so Safe benefits, across every tier). Design note captured now while fresh:
[`future-work-memory-optimizer.md`](future-work-memory-optimizer.md) (esp. the trap-preservation
soundness lever + the "keep the IR analyzable" invariants).

---

## Phase 6 — "Complete the WebAssembly 2.0 standard" (SIMD + memory64 runtime + cross-module linking)

Goal & honest scope: see [`specs/phase-6/00-overview.md`](phase-6/00-overview.md) (decisions **I1–I8**)
and the AUTHORITATIVE [`specs/phase-6/RECONCILIATION.md`](phase-6/RECONCILIATION.md) (decisions
**S1–S15** — override the unit docs on conflict). Phases 1–5 built the complete standardized surface
**minus SIMD**; Phase 6 closes the last three deferred features so the engine covers **the whole
WebAssembly 2.0 fixed-width surface**: **SIMD** (`v128` + ~236 lane ops, emulated lane-wise via a new
**`rt_simd`** mirroring `rt_num` — faithful, not hardware-accelerated, I3), the **memory64 runtime**
(R12's deferred half — lower/link accept `Idx64`, i64 addressing, a documented spec-aligned page cap:
declarable type-max 2⁴⁸ pages, runtime cap 2³² pages/256 TiB, S9), and **cross-module wasm→wasm
function linking** (the greenfield imported-function-call path — `lower` rejects it today — via the new
`CallImport` node + a linker-built closure capability, D3a-clean, S5). The IR grows again
(language-neutrally, I7) — `TV128` + `ConstV128` + a compact `SimdOp` enum + the `CallImport` node —
conformance-neutral by default. Post-2.0 proposals (tail-call/`return_call*`, GC, EH, stack-switching,
component model, relaxed-SIMD) stay **categorized-deferred** (S12). Completing Phase 6 **unblocks
Phase 7** (Porffor / JS-on-the-BEAM). Plan authored + adversarially critiqued (4 lenses, **8 blockers
+ 7 majors** caught) + reconciled (S1–S15).

### Phase-6 freeze milestones (planned)

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«IR4-FROZEN»` — `ir.gleam` `TV128` ValType + `ConstV128` Value + the parametric `SimdOp` enum (incl. the saturating add/sub family, S3) + `Simd`/`SimdShuffle`/`SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane` Expr nodes (bits, S2) + **`CallImport(slot,ty,args)`** (S5) + `effect` classification (pure lanewise / barrier memory, S7) + no new `TrapReason` (S8) + `.ir` grammar-delta pointer | P6-01 | **frozen (done)** | 02, 03, 05, 06, 07, 09 |
| `«RT-SIMD-SIG»` — `runtime/rt_simd.gleam` (NEW) 217 pure lane heads + the four v128 memory lane-assembly helpers (S4), doc-frozen todo-free, import-free | P6-01 | **frozen (done)** | 06, 07 |
| `«MEM64-RUNTIME»` — `Binding.mem64_max_pages` cap field = 2³² pages (S9) + the `lower`/`link` accept-`Idx64` contract (prose; removal is 05/08); `rt_mem.load_bytes`/`store_bytes` heads are 08's | P6-01 | **frozen (done)** | 05, 08 |
| `«XLINK»` — the `CallImport` node + `ProvidedFunc(ty, call: fn(List(Dynamic))->Dynamic)` closure field + the `link.call_import` seam contract (prose; 09 builds the closures + widens the return ABI if needed, S5) | P6-01 | **frozen (done)** | 06, 09 |
| `«WASM-AST4»` — extended `frontend/wasm/ast.gleam` (`V128` valtype, shape-tagged `Simd(op)` + the 6 dedicated SIMD `Instr`s, S1) | P6-03 (day 1) | **frozen (done)** | 04, 05 |

### Phase-6 units (specs authored + critiqued + reconciled; implementation `unclaimed`)

| Unit | Doc | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|---|
| **P6-01** Interface freeze (keystone) | [`01`](phase-6/01-interface-freeze.md) | **done** | — | IR4 landed GREEN + byte-identical: **1220 tests pass** (1212 baseline + 8 new `ir4_freeze_test`), **conformance 21525/1257/0 unchanged**, zero warnings, format-clean. Leaves: `TV128` ValType; `ConstV128(bytes)` Value; parametric `SimdOp` (SIMD-float ctors `SF`-prefixed to avoid `NumOp` collision — see deviation) + `SimdShape`/`SimdHalf`/`SimdLoadKind`; the 6 SIMD `Expr` nodes + `CallImport(slot,ty,args)`; `effect` PURE-lanewise (`Simd`/`SimdShuffle`) vs BARRIER (4 SIMD-mem + `CallImport`) split; `TrapReason` unchanged (S8); `rt_simd.gleam` (NEW — **217** pure heads + 4 memory helpers, `panic`-placeholder, todo-free, import-free); `Binding.mem64_max_pages=2³²` (S9); `ProvidedFunc.call` closure field (S5); printer/parser/emit_core/lower/ir_lower/ir_opt(baseline+aggressive+pass) land-green arms. Full impls: 02 (printer/parser round-trip), 05 (lower), 06 (emit), 07 (rt_simd bodies), 08 (mem64), 09 (linker). |
| **P6-02** `.ir` printer/parser ext | [`02`](phase-6/02-ir-textual-form.md) | **done** | `«IR4»` | `.ir` round-trips the FULL IR4 surface (`parse(print(m))==m`): `v128.const` byte-exact (NaN-payload/`-0.0`/`+Inf`/normal lanes, D5), EVERY `SimdOp` constructor × every `SimdShape` (the parser `string_to_simdop` is the exact inverse of the keystone's `<shape>.<op>` `simdop_to_string` scheme), `SimdShuffle`, the four SIMD-memory nodes (every `SimdLoadKind`/width/lane at mem 0 AND non-zero, BITS per S2), and `CallImport(slot,ty,args)`; `v128` valtype in every position; the 16-byte `v128.const` length check (`BadNumberLiteral`, no new `ParseError` variant); total parser (SIMD/`call_import` garbage battery, incl. non-16-byte const → typed error, no panic). New hand-authored `golden/simd.ir` + independent expected `Module`; memory64 + cross-module import DECL confirmed byte-identical (unchanged from P5). Grammar reconciled: **`specs/phase-6/ir-grammar-delta.md`** (documents the frozen `<shape>.<op>` scheme; cross-linked from `ir-grammar.md` + the P5 delta). **1236 tests pass (was 1220, +16), 0 warnings, format-clean, conformance 21525/1257/0 unchanged (byte-identical).** |
| **P6-03** decode ext (+ `«WASM-AST4»`) | [`03`](phase-6/03-decode.md) | **done** | — | **Landed GREEN + byte-identical: 1271 tests pass (1236 baseline + 35 new SIMD decode tests), conformance 21525/1257/0 unchanged, zero warnings, format-clean.** Published **`«WASM-AST4»`** in `ast.gleam` (S1 shape, S2 bits): `ValType` gains `V128` (0x7B, not a reftype); new types `SimdShape{I8x16 I16x8 I32x4 I64x2 F32x4 F64x2}`, `SimdHalf{Low High}`, a shape-tagged `SimdOp` (mirrors `ir.SimdOp` 1:1, float ctors **`F`-prefixed** since `ast` has no `NumOp` collision — `05` relabels `F*→SF*`; parametric `SNarrow/SExtend/SExtMul/SExtAddPairwise` per S3; the saturating **`SAddSatS/U`/`SSubSatS/U`** family; named conversions; lane-access carries `lane`), and `SimdLoadKind{LoadV128 LoadSplat(lane_bits) LoadExtend(source_bits,signed) LoadZero(lane_bits)}` (**all BITS**, S2). SEVEN SIMD `Instr`s: `Simd(op)` + `V128Const(bytes)` + `I8x16Shuffle(lanes)` + `SimdLoad(kind,arg)` + `SimdStore(arg)` + `SimdLoadLane(width,arg,lane)` + `SimdStoreLane(width,arg,lane)`. New `DecodeError.UnknownSimdOpcode(Int)` (only new variant). `decode.gleam` decodes the `0xFD` prefix + LEB `u32` sub-opcode + ALL 236 sub-opcodes (20 reserved gaps + `>=256` relaxed → `UnknownSimdOpcode`) → AST4; `v128.const` reads 16 raw LE bytes, `i8x16.shuffle` 16 lane bytes, extract/replace read a 1-byte lane, the v128-memory ops reuse Phase-5 `decode_memarg` (+ trailing lane byte for `*_lane`, memarg-THEN-lane wire order); `decode_valtype` accepts `0x7B→V128`, `decode_blocktype` the `-5` encoding. Total/fail-closed (truncation battery + single-byte-mutation fuzz + the spec-exhaustive 0..255 opcode-map audit: exactly 236 Ok + 20 gaps). Fail-CLOSED land-green arms in `validate.gleam` (all 7 SIMD `Instr`s → `Error(Unsupported)` BEFORE the fail-open `numeric_sig` fallthrough, S1) and `lower.gleam` (`ast.V128→ir.TV128` in `to_ir_vt`; SIMD instrs still `Unsupported`). memory64 decode unchanged (regression-tested). **Hands to:** 04 (types v128 stack, lane-index/shuffle/alignment bounds — the `Unsupported` arms are its intercept points), 05 (AST4→IR4: `ast.SimdOp→ir.SimdOp` near-1:1 relabel, `V128Const→ConstV128`, the SIMD-memory `Instr`s→IR nodes). |
| **P6-04** validate ext | [`04`](phase-6/04-validate.md) | **done** | `«WASM-AST4»` | **Landed GREEN + byte-identical: 1322 tests pass (1271 baseline + 51 new SIMD validate tests), conformance 21525/1257/0 unchanged, zero warnings, format-clean, no `twocore/ir` import (AST-only boundary).** Replaced P6-03's fail-closed `Unsupported` placeholders with real typing: all 7 SIMD `Instr`s intercepted BEFORE the `numeric_sig` fallthrough (S1). `validate_simd` (exhaustive on `SimdOp`) + `simd_sig` type every lane op — arithmetic/bitwise `[v128 v128]→[v128]` (unary `[v128]→[v128]`), **comparisons → v128 MASK `[v128 v128]→[v128]` (not i32)**, shifts `[v128 i32]→[v128]`, `splat [unpacked(shape)]→[v128]`, extract `[v128]→[unpacked]`, replace `[v128 scalar]→[v128]`, `any_true`/`all_true`/`bitmask [v128]→[i32]`, bitselect ternary, widen/narrow/extmul/pairwise/convert/dot/q15/swizzle; illegal `(op,shape)` combos rejected fail-closed via `require_shape`→`Unsupported`. The 6 dedicated `Instr`s: `V128Const [] →[v128]` (+ const-expr arm); `I8x16Shuffle` each index `<32`; `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane` reuse the scalar `mem_addr_type`/`check_align`/`check_offset` seam (memory64: `v128.load` on a 64-bit memory pops `i64`) — alignment `2^align≤N/8` (BITS, S2), lane `<128/N`. New `ValidateError.BadLaneIndex(index)` (only new variant; `BadAlignment`/`OffsetOutOfRange`/`TypeMismatch`/`Unsupported` reused). memory64 typing re-confirmed spec-complete (`2^48`-page validation limit distinct from P6-08's runtime cap); cross-module fn-import typing unchanged (call types against declared `FuncType`). **Leaves for P6-05:** the structurally-unchanged `TypedModule` (SIMD result types read off the op constructor — no new field; `func_types` imports-first for `CallImport` slots; `memory_idx_types` for i64 address width). |
| **P6-05** lower ext | [`05`](phase-6/05-lower.md) | **done** | `«WASM-AST4»`, `«IR4»` | **Landed GREEN + byte-identical: 1336 tests pass (1322 baseline + 14 new lower tests), conformance 21525/1257/0 unchanged (no category moved), zero warnings, format-clean.** AST4→IR4 for the full new surface: `ast.Simd(op)` → `ir.Simd(relabel(op), args)` via an explicit relabel table (shape-uniform copy; **`F*`→`SF*`** floats; parametric `SNarrow`/`SExtend`/`SExtMul`/`SExtAddPairwise` copy `from`/`half`/`signed`; named conversions + sat family + lane-access copy 1:1 — S3), routed through `emit_value_op_t` with the arity + result type derived from the neutral op (`simd_op_arity_result`: compares → v128 MASK, reductions → i32, extract-lane → the lane scalar). `ast.V128Const(bytes)` → the `ConstV128(bytes)` Value (pushed like a numeric const, no `Let`); `ast.I8x16Shuffle(lanes)` → the dedicated `SimdShuffle(lanes,a,b)` node; the four SIMD-memory `Instr`s → `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane` (loads bound via `emit_value_op_t`, stores are zero-result `emit_effect`s; memidx + BITS width (S2) + static offset + lane threaded). **memory64 (I4): DELETED `reject_memory64` + the `Memory64Unsupported` `LowerError` variant** — a 64-bit memory now lowers, carrying `Idx64` onto `MemoryDecl`/`ImportMemory`; the i64 address flows unchanged (no width branch). **Imported calls (S5): `lower_call` fetches the callee sig up front and emits `ir.CallImport(slot=funcidx, ty, args)` for `funcidx < imported`** (positional import slot), `CallDirect` for same-module; `lower_const_expr` gains the `v128.const` global-init arm. **Leaves for 06/07:** the IR4 nodes emit_core lowers through the `rt_simd`/`rt_mem`/`link.call_import` seams (emit still rejects the new nodes with typed `UnsupportedNode`, so SIMD/mem64/import modules produce IR but don't yet run e2e — a categorized skip, fail=0 preserved). |
| **P6-06** emit_core ext | [`06`](phase-6/06-emit-core.md) | **unclaimed** | `«IR4»`, `«RT-SIMD-SIG»`, `«XLINK»` | Emit SIMD via the `rt_simd` seam; the pinned SIMD-memory compose table (S4); memory64 i64 addressing; `CallImport → link.call_import` closure dispatch (never apply-spread); extend the D3a test. Deepest codegen. |
| **P6-07** rt_simd (NEW; 07a–07d) | [`07`](phase-6/07-rt-simd.md) | **07a+07b done; 07c/07d unclaimed** | `«RT-SIMD-SIG»` | The ~214–224 lane heads over a 16-byte BitArray, bit-exact, reusing `rt_num`; the four memory lane-assembly helpers; **four balanced passes** (S10); differential vs oracle/wasmtime. **P6-07a landed GREEN + byte-identical: 1357 tests (was 1336, +21 spec-cited differential test fns), conformance 21525/1257/0 unchanged, zero warnings, format-clean.** Established the SHARED private lane codec 07b/07c/07d reuse — `decode_lanes(v: BitArray, w: Int) -> List(Int)` / `encode_lanes(lanes: List(Int), w: Int) -> BitArray` (little-endian, D5, `w ∈ {8,16,32,64}` bits) + `map2_lanes`/`map1_lanes` drivers + the integer width-core (`pow2`/`all_ones`/`mask_low`/`signed_of`(=`lane_signed`)/`shift_count`(mask mod lane width), each mirroring a `rt_num` private worker at an arbitrary lane width). Filled **54 heads**: `iNxM_add`/`sub` (all 4 shapes) + `mul` (i16x8/i32x4/i64x2, no i8x16.mul), `neg`/`abs` (all 4), saturating `add_sat_s/u`+`sub_sat_s/u` (i8x16/i16x8), `min_s/u`+`max_s/u` (i8x16/i16x8/i32x4), `avgr_u` (i8x16/i16x8), `shl`/`shr_s`/`shr_u` (all 4, count masked mod lane width), `i8x16_popcnt`. Arithmetic wrap + popcount CONSUMED from `rt_num` (`i32`/`i64_add/sub/mul`, `i32_popcnt`); `rt_num` never edited (D1). Tests are DIFFERENTIAL vs an independent flat-`List(Int)` oracle (`%`/`/`, not the impl's `band`) + hand-worked spec edges (two's-complement wrap, sat boundaries 127+1→127/−128−1→−128/255+1→255, avgr rounding, shift masking i32x4.shl 33≡1, popcnt, signed-vs-unsigned min/max, LE lane layout). **P6-07b landed GREEN + byte-identical: 1374 tests (was 1357, +17 spec-cited differential test fns in `rt_simd_cmp_test.gleam`), conformance 21525/1257/0 unchanged, zero warnings, format-clean.** Filled **65 heads** reusing the 07a codec: all integer comparisons → v128 MASK (`eq`/`ne`/`lt_s`/`lt_u`/`gt_s`/`gt_u`/`le_s`/`le_u`/`ge_s`/`ge_u` for i8x16/i16x8/i32x4 = 30; i64x2 `eq`/`ne`/`lt_s`/`gt_s`/`le_s`/`ge_s` = 6, signed-only ordering per spec), each lane→all-ones(`2^w-1`) if the relation holds else 0 (signed via `signed_of`, the sanctioned local mirror as in 07a min/max); shape-agnostic bitwise over the whole 128 bits (`not`/`and`/`or`/`xor`/`andnot(a AND ~b)`/`bitselect((a&m)|(b&~m))`) via a `bits128`/`from_bits128` whole-vector view = 6; boolean reductions `v128_any_true`+`iNxM_all_true`+`iNxM_bitmask` (sign-bit gather, lane 0→bit 0) = 9; lane access `splat`/`extract_lane(_s/_u)`/`replace_lane` for all six shapes = 20 (extract_s reuses `rt_num.i32_extend8_s`/`i32_extend16_s`). New private helpers: `cmp_mask`/`bits128`/`from_bits128`/`all_true`/`bitmask`/`lane_at`/`set_lane`/`splat`. Tests DIFFERENTIAL vs an independent oracle (`%`/`/` + arithmetic bit-decomposition, never `band`) + hand-worked spec edges (all-ones/all-zeros masks, the signed/unsigned split `lt_s(-1,0)=T` vs `lt_u(0xFFFFFFFF,0)=F`, i64x2 signed compares, bitselect identities + algebraic laws, all_true all-lanes-nonzero edge, bitmask `[neg,pos,neg,pos]→0b0101` & i8x16 lanes{0,15}→0x8001, sub-word `extract_lane_s` sign-extension 0xFF→0xFFFFFFFF, splat/extract/replace round-trips). **Leaves for 07c/07d:** reuse the codec; the float/conversion (07c) and narrow/widen/extend/extmul/extadd_pairwise/dot/q15/swizzle/shuffle + the four v128-memory lane-assembly helpers (07d) heads remain `panic`-placeholders. |
| **P6-08** rt_mem memory64 | [`08`](phase-6/08-rt-mem-memory64.md) | **unclaimed** | `«MEM64-RUNTIME»` | i64 addressing + 64-bit bounds + the documented cap (S9) + `load_bytes`/`store_bytes` (S4); paged (+portable); atomics/nif fail-closed over-cap; 32-bit byte-identical. |
| **P6-09** cross-module linking | [`09`](phase-6/09-cross-module-linking.md) | **unclaimed** | `«XLINK»` | `link_imports` extended to functions (fail-closed → `assert_unlinkable`); the host + cross-module closures (host reuses `rt_host`; cross-module routes into the exporting instance's process); `(register …)` end-to-end; v128/boxed globals in `rt_state` (S6); cell-first (S5). |
| **P6-10** conformance expansion | [`10`](phase-6/10-conformance-expansion.md) | **unclaimed** | 03–09 | Light up `simd/*.wast` + `memory64.wast` + `linking.wast`; the **empirical residual audit** (S11); the v128-lane-aware NaN-pattern value judge (M3); v128 invoke ABI (S14); differential vs `wasmtime`; measured skip-drop. |
| **P6-11** capstone | [`11`](phase-6/11-capstone.md) | **unclaimed** | all above | WASM-2.0 complete green under the matrix; measured skip-drop headline + fail=0; conformance-neutral proof; SVG refresh; honest close (emulated SIMD, documented mem64 cap, post-2.0 deferred, S12); Phase 7 unblocked. |

### High-level spec coverage this phase takes

| High-level item | Taken by | Notes |
|---|---|---|
| §12 SIMD (fixed-width `v128`) | P6-01/03/04/05/06/07 | ~236 lane ops, emulated lane-wise via `rt_simd` (tier-P `bif`, reuses `rt_num`); faithful, not hardware-accelerated (I3). |
| §12 `memory64` (runtime) | P6-01/05/06/08 | R12's deferred half — i64 addressing + documented page cap; `paged`/`portable` (atomics/nif fail-closed over-cap). |
| §8/§10 cross-module wasm linking | P6-01/05/06/09 | The greenfield imported-function-call path via `CallImport` + linker-built closure capability (D3a-clean, S5); `(register …)`. |
| §11 differential + interface conformance | P6-10 | the new surface held to `wasmtime` + the `rebuild` oracle; measured residual (S11). |

### Deferred to Phase 7+ (explicit)

**Phase 7 — "JS on the BEAM" via Porffor (now unblocked):** the Porffor-ABI `rt_host` shim + a
JS-subset conformance harness. **Post-2.0 proposals (categorized-deferred, S12):** the **tail-call**
proposal (`return_call*` — a plausibly-cheap BEAM-native fast-follow, EM-flagged), **GC** (incl.
GC-proposal reftypes), **exception-handling**, **stack-switching**, the **component model**,
**relaxed-SIMD**. **Later:** the Erlang/Gleam frontend; the single-`.beam` **B1** binding; tier-N
numerics; a production **C NIF** for tier-N memory *or* real hardware **tier-N SIMD**; SIMD text in the
WAT parser (S13); the **memory optimizer** (its own perf phase); the extended-const proposal.

---

## Change log

- **Phase-6 plan authored + adversarially critiqued + reconciled.** Scope decision (EM): **Phase 6 =
  "complete the WebAssembly 2.0 standard"** — SIMD (`v128` + ~236 lane ops via a new `rt_simd`
  mirroring `rt_num`), the memory64 runtime (R12's deferred half), and cross-module wasm→wasm function
  linking (the greenfield imported-call path). Authored `phase-6/00-overview.md` (**I1–I8**) + an
  EM-provided provisional IR4/AST4/rt_simd/linker surface, then an 11-agent scoping fan-out (each unit
  doc built against the provisional surface for coherence) + a **4-lens adversarial critique**
  (frontend-fidelity, runtime-semantics, security-consistency, scope-realism) that caught **8 blockers
  + 7 majors**, all folded into the AUTHORITATIVE `phase-6/RECONCILIATION.md` (**S1–S15**):
  - **B: the SIMD AST surface was frozen 3 incompatible ways** (03 shape-tagged + dedicated Instrs; 04
    a flat sub-enum; 05 flat per-op) → pin 03's shape (the `ast.gleam` owner); 04/05 conform; **and
    harden validate's `numeric_sig` fallthrough (a fail-OPEN hole) to intercept every SIMD Instr** (S1).
  - **B: SIMD-memory width fields frozen bits-vs-bytes** (silent 8× mis-sizing) → pin BITS (S2).
  - **B: `ir.SimdOp` frozen 2 ways** (keystone parametric vs 05 fully-named, which don't exist) → the
    keystone's parametric taxonomy wins; 05 relabels; the saturating add/sub family (~392 asserts) is
    IN the enum (S3).
  - **B: the v128 load/store seam frozen 3 ways + `load_bytes`/`store_bytes` owned by nobody** → pin
    rt_mem `load_bytes`/`store_bytes` (owner 08) + rt_simd's four lane-assembly helpers (owner 07) + a
    pinned per-variant compose table (emitted by 06) (S4).
  - **B: the cross-module closure ABI frozen 2 ways** (list-taking vs `erlang:apply`-spread crash) +
    **the `CallImport` seam 3 ways** → pin the `CallImport(slot,ty,args)` node + a
    `fn(List)->List(Dynamic)` closure invoked 1-ary via `link.call_import` (never apply-spread) +
    uniform link-time host/cross-module resolution (host reuses `rt_host`; the imported-call path is
    greenfield — `lower` rejects it today) (S5).
  - **Majors folded:** 05's IR relabel (S3); v128/boxed globals reuse `rt_state.ref_globals` (owner 09,
    S6); pure-lanewise-SIMD effect classification ratified sound (S7); TrapReason unchanged (S8); the
    memory64 numbers corrected (declarable 2⁴⁸ pages / runtime cap 2³² pages, S9); rt_simd re-split
    into **four** balanced passes (S10); the conformance residual/`table_copy` number MEASURED not
    overstated (S11); the close qualified to **"WASM 2.0 complete"** with post-2.0 proposals
    (tail-call/GC/EH/stack-switching/component-model/relaxed-SIMD) categorized-deferred — `return_call*`
    added to the residual (S12); the SIMD-wat differential dropped (WAT parser has no SIMD text, S13);
    the v128 invoke ABI (16 LE bytes) ratified (S14). Plan is now internally consistent; implementation
    next, keystone-first.



- **P5-12 landed (capstone) — PHASE 5 PROVEN.** The engine now executes the **complete standardized
  WebAssembly surface except SIMD**, proven under both modes and every shipped tier. Capstone
  deliverables: `test/twocore/conformance/new_surface_test.gleam` (new — proof 1/3), an extended
  `test/twocore/conformance/runs_anywhere_test.gleam` (proof 4, new surface) and
  `conformance_test.gleam` (the surface headline `pass > baseline` on the two full-profile runs),
  the refreshed `docs/wasm-conformance.svg` (21525/1257/0, Phase-5 footnote) + generator, and the
  new `docs/phase-5-surface.md` (the measured before/after + categorized residual).
  - **Proof 1 — complete surface, green end-to-end.** `reftab` (reference & table: `ref.*`, the full
    `table.*` surface, a null-slot `call_indirect` → trap *uninitialized element*, an OOB
    `table.get` → *out of bounds table access*), `bulkmem` (bulk memory: fill/copy/init + `data.drop`,
    memmove overlap, eager-bounds trap with **no partial write**, dropped-segment = length-0), and
    `multimem` (two independent memories + a cross-memory `memory.copy`) are spec-correct against
    their spec-sourced `.expected` under `safe`/`unsafe`/`portable` and **byte-identical** across
    them — plus the P5-11 tier-sweep already proves byte-identity across every `state_strategy ×
    mem_tier`.
  - **Proof 2 — the surface-phase headline (MEASURED, R16).** Over the enlarged allowlist, `fail == 0`
    and `pass` **strictly rose to 21525 (+5776 over the 15749 baseline)** under both full profiles;
    the filtered tier-matrix run is `fail == 0` per combo (7578/1167/0 paged+nif, 7544/1167/0
    atomics). Framed **honestly**: the raw skip count *rose* (409→1257) only because P5-11 added ~30
    previously-EXCLUDED files to the allowlist — the headline is the pass-RISE + `fail == 0` with a
    **fully-categorized, closed residual** (`skipcount_test`: every skip matches an enumerated
    category or the test goes red). Residual = ~1088 **cross-module wasm→wasm function imports**
    (a distinct cross-module function-linking feature Phase 5 never scoped) + 169 genuinely
    out-of-scope; the residual *excluding* that gap is 169 < the Phase-4 baseline of 409.
  - **Proof 3 — conformance-neutral by default (H7).** The entire Phase-1..4 acceptance corpus
    produces the SAME `Outcome` under Safe and Unsafe Phase-5 code (new-surface test), the
    `portable`-vs-oracle corpus neutrality (Phase-4 runs-anywhere) stays green, and unit 06's
    emitter-level byte-identity (`MemLoad(0,…)` ⇒ the un-indexed Phase-4 `rt_mem:load` head) is
    confirmed green — the IR grew but the defaults route the new surface away.
  - **Proof 4 — runs-anywhere RE-CONFIRMED for the new surface (grep + executed).** The
    `profiles.portable()` `.core` of `reftab`/`bulkmem`/`multimem` links **zero**
    `atomics`/`ets`/`persistent_term`/NIF and emits **zero** `rt_state` pdict instance-cell seam,
    while non-vacuously naming the threaded families the new nodes route through (`'t_get'`/
    `'t_call_indirect'`/`'t_init_elem'`/`rt_ref` for reftab; `'t_copy'`/`'t_init'` for bulkmem;
    `'t_load_at'`/`'t_store_at'`/`rt_state` for multimem); all three execute byte-identical to the
    `cell`/`paged` oracle on a bare BEAM.
  - **Proof 5 — confirmed, not re-derived.** P5-11's `wasmtime` differential (skips gracefully when
    absent) + P5-10's `parse_module ≡ decode∘wat2wasm` / `parse_script ≡ wast2json` suites are green
    and committed; the previously-un-`wast2json`-able files run from our own `parse_script`.
  - **The honest close of Phase 5.** *PROVED* — the **complete standardized WebAssembly engine minus
    SIMD**: reference types (funcref/externref, ref ops, `table.get/set/size/grow/fill`, typed
    `select`, multiple tables incl. **multi-table `call_indirect`**, passive/declarative elements),
    bulk memory & table ops (spec-exact eager-bounds + memmove + O(N) fuel + droppable segments),
    multiple memories, non-function imports + the full `spectest` module + `(register …)`, and a
    first-class WAT text parser — all **spec-differentially correct** (held to the baked `.wast` +
    `wasmtime`) under **both modes** and **every shipped `state_strategy × mem_tier`**,
    **byte-identical by default** (H7), **constant-space loops + preemption preserved**, and
    **runs-anywhere** for the new surface. *DEFERRED (stated, each):* **SIMD → Phase 6** (the single
    largest proposal); **memory64 runtime → Phase 6** (the `IdxType` IR axis + decode/validate ship;
    lower/link reject a 64-bit memory with a categorized skip — no guessed page cap, R12);
    **cross-module wasm→wasm function linking → Phase 6** (the ~1088-assert residual, stated not
    claimed); the **Porffor JS→WASM bridge → Phase 7** ("JS on the BEAM"); **GC-proposal reftypes**
    (typed function refs + `struct`/`array`/`i31`) + the **extended-const** proposal → later; a
    **production C NIF** for tier-N memory stays documented-deferred; and the documented
    **`spectest`-memory-under-atomics** edge (the fixed `spectest` provider is paged; the imported
    `spectest` memory is proven under the paged/both profiles and tier-covered for bulk by the
    own-memory `memory_*` tests). No performance claim beyond Phase 4's — Phase 5 is a surface phase;
    its only performance obligation is negative (no regression), which proofs 3–4 carry.
  - **1195 tests (was 1189), 0 warnings, `gleam format --check src test` clean, conformance
    `fail == 0` across both profiles + the full tier matrix.**
- **Phase-5 plan authored + adversarially critiqued + reconciled.** Scope decision (EM): **Phase 5 =
  "the complete WASM engine"** — reference types + bulk memory + multi-memory + non-function imports/
  `spectest` + the WAT text parser (+ memory64 decode/validate only). **SIMD promoted to a dedicated
  Phase 6** (the single largest proposal; high-level §12 brackets it "large; defer"); the Porffor
  bridge moves to Phase 7. Authored `phase-5/00-overview.md` (**H1–H8**) + 12 unit docs via a
  12-agent scoping fan-out (each scoping against an EM-provided provisional IR3/AST3 surface for
  coherence), then a **4-lens adversarial critique** (frontend spec-fidelity, runtime semantics,
  security+consistency, scope-realism) refuted the drafts. The critique **cleared** the bulk of the
  surface (all opcode bytes / `0xFC` sub-opcodes / element+data flags / datacount ordering / memarg
  bits / `C.refs` membership / eager-bounds+memmove+`grow -1` / index-0 byte-identity — checked
  against the spec and correct) and caught **4 blockers + 8 majors**, all folded into the
  AUTHORITATIVE `phase-5/RECONCILIATION.md` (**R1–R18**):
  - **B: `table.init`/`memory.init` immediate order** was self-contradictory across 03/04/05 (a swap
    silently validates the wrong bound — security-relevant) → pinned wire order (elemidx-then-tableidx)
    + an anti-swap fixture (R3).
  - **B: the `memory.init` seam ABI** was frozen two incompatible ways (unbuildable) and passive-
    segment payload ownership clashed (07 vs 01/08) → one model: `rt_state` holds only the drop flag,
    the payload is an emit-supplied argument, symmetric for data/elem (R2).
  - **B: the null-sentinel/externref representation** was frozen bare-atom (forgeable) vs tagged →
    pinned the forge-proof `{ref_null}` / `{ref_extern,_}` / unchanged funcref, in a new shared
    `runtime/rt_ref.gleam` (R1).
  - **B: the `Provided`/instantiate contract** was frozen incompatibly and 01's dict-keyed-by-name
    shape couldn't do fail-closed matching (a D3a smell) → adopted 09's typed positional
    `instantiate/1(List(Provided))` + `link_imports` (R4).
  - **Majors folded:** `rt_state.gleam` single-owner (01 shape+stubs → 09 bodies; not 08 — R5) + seam
    naming (R6) + dense index-keyed table store (R7); reference-typed globals via a parallel
    `ref_globals` map (R8); **O(N) fuel on ALL bulk ops** (else the Safe CPU bound is defeated — R9);
    the exact `d+n>size ⇒ trap` rule incl. `n==0` (R10); **memory64 runtime deferred to Phase 6**
    (unverified page cap; decode/validate only — R12); the datacount wellformedness owner (R13); the
    full `spectest` set incl. `print_i64` (R14); the WAT parser as two implementation passes + float
    honesty (R15); measured-not-promised conformance greenness (R16); a multi-value run-ABI so
    residual skips stay closed (R17); host-constructible reference values for the harness (R18). Plan
    is now internally consistent; implementation next, keystone-first.


- **P4-11 landed (capstone) — PHASE 4 PROVEN.** The trust-tier ladder is real and the
  runs-anywhere headline is concrete + true. Two capstone deliverables:
  `test/twocore/conformance/conformance_test.gleam` (extended — the full-matrix run) and
  `test/twocore/conformance/runs_anywhere_test.gleam` (new — the headline). Plus the refreshed
  `docs/wasm-conformance.svg` (footnote → Phase-4 scope) and generator.
  - **Proof 2 — full-matrix conformance (G2/G7).** The pinned spec suite is `fail == 0 && pass > 0`
    under EVERY shipped `(state_strategy × mem_tier[× table_tier])` binding — `cell×paged`,
    `threaded×paged`, `cell×atomics`, `threaded×atomics`, and the `cell×nif` skeleton — each
    reporting the identical 15747 / 411 / 0 as the two Phase-3 profiles. Byte-identical because
    WebAssembly is deterministic (D5 pins NaN payloads as raw bits). Each binding is built through
    `combos.binding_for` (the unit-07 linker surface) with `safe_max_pages` widened to a dedicated
    `matrix_cap_pages = 512`: the `combos.cap_pages` (16) sized for the small acceptance corpus is
    too tight for the whole suite — `call`/`call_indirect`'s `as-memory.grow-value` grows a no-max
    `(memory 1)` by **306 pages** and expects SUCCESS (old size 1), so 16 forced a spurious `-1` on
    exactly 2 assertions. `512` sits in `[307, 4096]`: above every in-scope footprint (so no spec
    result moves, conformance-neutral) and below the `atomics` reserve cap (so every atomics combo
    links). (Deviation, justified — the tighter corpus cap was surfaced as insufficient for the full
    suite; the fix is a local, documented conformance cap that leaves unit 09's `combos.cap_pages`
    untouched.)
  - **Proof 1 — the runs-anywhere HEADLINE (G1/G3/G6), grep-verified AND executed.** Over the REAL,
    shipped `profiles.portable()` (not a test-capped variant): (a) **grep** — the emitted `.core` of
    every state-heavy module (`mem`/`gvar`/`callind`/`memgrow`) links **zero**
    `atomics`/`ets`/`persistent_term`/NIF and emits **zero** `rt_state` pdict instance-cell seam
    (`'seed'`/`'mem_get'`/`'global_get'`/…), while genuinely routing state through the threaded
    record (`'t_load'`/`'t_store'`/`'t_global_get'` present — non-vacuous); the node-safe tier-O
    `rt_meter` fuel counter + `rt_host` policy cell are asserted PRESENT (the documented, exempt
    pdict overlays Safe mandates — `MeterOff`-under-Safe is rejected). (b) **executed** — the whole
    acceptance corpus runs through `load → instantiate → invoke` on a bare BEAM byte-identical to the
    `cell`/`paged` oracle (`sum_to(100000)` and the memory/global/table programs included, so unit
    09's constant-space-under-`threaded` property is re-confirmed in the real `portable`
    composition).
  - **Proofs 3/4/5 confirmed (not re-derived).** Unit 09's tier differential + constant-space +
    memory.grow trap-parity suites and unit 10's `docs/phase-4-benchmark.md` (+`smoke/bench.sh`) are
    green and committed; the fail-closed composition (`validate_binding(Safe+Nif) == SafeForbidsNif`,
    uncapped `ceiling()` == `AtomicsCapRequired`, `portable()` == `Ok`) is exhaustively owned by unit
    07's `profiles_test` — the capstone adds one end-to-end headline checkpoint over the two named
    profiles rather than duplicating it. (Deviation, justified — the unit-doc §E example
    `is_ok(validate_binding(ceiling()))` is superseded by the frozen unit-07 rule that an UNCAPPED
    `ceiling()` fails closed `AtomicsCapRequired`; the capstone asserts the true frozen behaviour.)
  - **Image + counts.** `docs/wasm-conformance.svg` regenerated — one-line footnote change ("Phase 4:
    green under every shipped tier … conformance-neutral"); counts unchanged (15747 / 411 / 0, G7).
  - **The honest close of Phase 4.** *Proved:* runs-anywhere — the tier-P `portable` build runs the
    corpus + suite on a bare BEAM with **no native code and no crashable instance state**
    (grep-verified + executed), byte-identical to the tier-O oracle; every shipped
    `state_strategy × mem_tier` combination is spec-correct and conformance-neutral; constant-space
    loops survive state threading (G4); tier-O `atomics` gives a **measured** O(1) memory win
    (~2.3–2.9× over `paged`) with threading essentially free (unit 10). *Did NOT prove / deferred:* a
    **production C NIF** — tier-N ships as an interface + Safe-forbidden status + node-safe skeleton
    (the C impl is documented-deferred where a native toolchain is required, G8); 2core is **not yet
    faster than hand-written Erlang** on every kernel — `atomics` closes most of the ~76× `paged` gap
    but the residual is tier-P `bif` numerics + the state-seam call, reported as the measured number,
    not asserted. Threads / shared memory stay a hard non-goal (`atomics` process-local); the
    single-`.beam` runtime-dispatch **B1** stays deferred (`state_strategy`/`mem_tier` are
    compile-time, B3). SIMD / reference types / bulk memory / multi-memory / `memory64` / the WAT
    parser / non-function imports are **Phase 5**; the Porffor JS→WASM bridge is **Phase 6**.
  - **906 tests (was 894), 0 warnings, `gleam format --check src test` clean, conformance `fail == 0`
    under every shipped combination.**
- **P4-03 landed (rt_state tier-P threaded surface).** `rt_state.gleam` gains its purely-
  functional tier-P surface (additive; the Phase-2 pdict cell surface untouched and parallel):
  `fresh(decl: StateDecl) -> InstanceState` (the threaded analogue of `seed` — returns the
  record instead of writing the pdict), `t_global_get(st, name) -> Int` / `t_global_set(st,
  name, value) -> InstanceState` (pure value-threaded globals), and the record field seam
  `mem(st) -> Dynamic` / `with_mem(st, Dynamic) -> InstanceState` / `table(st) -> Dynamic` /
  `with_table(st, Dynamic) -> InstanceState` (opaque `Dynamic` in/out so `rt_state` never
  imports `rt_mem`/`rt_table` — the opacity / no-circular-import invariant units 04/06 sit on).
  **`seed`→`build` refactor:** `seed` and `fresh` now share ONE private `build(decl)`
  constructor, guaranteeing a `Cell` build and a `Threaded` build materialise BYTE-IDENTICAL
  state (G7); `seed`'s behaviour is unchanged (the sole edit to a frozen function). The tier-P
  sub-graph reaches NONE of the module's three pdict externals (`erlang_put`/`erlang_erase`/
  `read_cell`, all cell-path) — the runs-anywhere property (G6), grep- and behaviourally-
  confirmed. **687 tests (was 679), 0 warnings, format clean, conformance fail=0.** 8 spec-
  grounded tests added (fresh round-trip; fresh≡seed parity; pure set/get value semantics;
  float bit-exact D5; two records never share; no-pdict; field-seam opacity). Leaves the
  `emit_core` threaded seam (02), the paged/atomics/ets `t_*` wrappers over this seam (04/06),
  and the constant-space-under-threaded-loop proof (09).
- **Phase-4 plan authored + adversarially critiqued + reconciled.** Scope decision (EM):
  **Phase 4 = "Free-standing" — the trust-tier ladder** (tier-P `threaded` runs-anywhere state +
  tier-O/N memory & table backends), motivated by Phase 3's benchmark (tier-O paged memory ~76×
  slower than hand-written Erlang). Overview (**G1–G8**) + 11 units via an 11-agent scoping fan-out,
  then a 3-lens critique. The critique **cleared** several worries (atomics endianness/unaligned
  mapping correct + differentially tested; grow-under-atomics sound; tier-N NIF honesty well-hedged)
  and caught **2 blockers + several certain majors**, folded via a 6-agent reconciliation (P1–P7):
  - **The paged threaded `t_*` wrappers had no owner and didn't exist** → `portable()` wouldn't link.
    Pinned: unit 04 owns `rt_mem.gleam` paged `t_*` (additive) + `rt_mem_atomics`; unit 06 owns
    `rt_table.gleam` paged `t_*` + the tiers; tiers are **separate modules** (D1 + distinct atoms).
  - **Threaded `memory.grow` dropped the dynamic fuel charge** → resource-bound hole + trap
    divergence. Fixed: `t_grow` charges like Cell; unit 09 adds a grow trap-parity differential.
  - **The uniform export wrapper collided when `export_name == fn_name`** → duplicate `FunDef` /
    infinite recursion. Fixed: export the internal def directly when names match.
  - **The runs-anywhere/tier-P claim was literally false** (Safe `portable` mandatorily carries the
    `rt_meter` pdict fuel counter). Resolved (honest): runs-anywhere = zero native + zero `rt_state`
    pdict **instance** cell, **exempting** the node-safe tier-O `rt_meter`/`rt_host` policy overlays.
  - **Tier coherence was unenforced** → `link/1` is the SOLE validated seam, `instantiate/1`
    self-validates, `resolve_tiers` couples `mem_module := mem_module_for(mem_tier)`.
  - **Atomics-grow contract conflict** → one contract: fail-closed on an uncapped no-max module (no
    silent fallback); `coexist_name` keys on `(mode, state_strategy, mem_tier)`. Implementation next.
- **P3-11 landed (capstone) — PHASE 3 PROVEN.** The five differentials + benchmark all green.
  **Headline finding: the optimizer changes nothing observable** — `OptNone`≡`Baseline`≡
  `Aggressive` produce byte-identical results/traps AND each equals the spec-sourced `.expected`
  across the whole Phase-1+2 acceptance corpus; Safe≡Unsafe likewise; the spec suite is
  `fail=0` under BOTH profiles (15747/411/0, conformance-neutral, F7). Real CPU fuel now BITES:
  a tail `spin` traps `fuel_exhausted` deterministically in constant space, a non-tail `recurse`
  bounds recursion depth (node memory `O(budget)`, documented). Safe+Unsafe coexistence proven at
  corpus scale (real `iso.wasm` state isolation + host capability isolation). New tests under
  `test/twocore/optimize/**` (+`corpus/spin,recurse`); `driver.pipeline_with(binding)` seam;
  conformance runs both profiles; `smoke/bench.sh` + `docs/phase-3-benchmark.md`; SVG refreshed
  (Phase-3 footnote). **673 tests (was 659), 0 warnings, format clean.** Deviations (justified):
  (1) **`emit_core` fix** — `call_host` cap/name now emitted as BINARY strings (were atoms) so
  `rt_host`'s `HostOpen`/`HostWhitelist` `String` matching fires (deny-all was faithful; a
  permissive host silently denied every handler). Surfaced by the F4 capability-coexistence proof;
  the one structural `emit_core_test` arm updated to assert the binary form. (2) `driver.pipeline()`
  = `pipeline_with(profiles.safe())` (full chain). (3) CLI `to-beam-wasm [--unsafe]` verb (the
  bench compile path). **Benchmark (F8, honest):** on the tier-O runtime 2core-Safe is SLOWER than
  hand-written Erlang for CRC-32 (~76×, bit-identical head-to-head) and far below the native NIF
  ceiling for SHA-256/DEFLATE — so "faster than hand-written Erlang" is *measured as not-yet*,
  motivating Phase-4's `rt_mem`/threaded tiers. The **Aggressive inliner does not scale** to the
  80-function smoke module (compile-time code explosion → Unsafe smoke numbers N/A) — a
  compile-time-only, NON-soundness limitation (the corpus differentials prove the optimizer sound),
  motivating a real inliner cost model. Both written up as limitations, not hidden.
- **Phase-3 plan authored + adversarially critiqued + reconciled.** Scope decision (EM):
  **Phase 3 = "Fast" — the shared optimizer (`ir_opt`) + the Unsafe profile + real CPU metering**
  (the speed/second-mode half of the high-level thesis), leaving the trust-tier ladder for Phase 4,
  WASM-surface completion for Phase 5, and the Porffor JS bridge for Phase 6. Authored
  `phase-3/00-overview.md` (decisions **F1–F8**) + 11 unit docs (`01`–`11`) via an 11-agent scoping
  fan-out, then a 4-lens adversarial critique (+ a security re-run) refuted the drafts. The
  critique caught **3 blockers** and several majors, all folded in via a 6-agent reconciliation
  against a canonical decisions block:
  - **Safe metering was never actually wired** (no unit owned emitting the fuel seed, and emit_core
    was locked posture-agnostic) → **emit_core (09) owns the `instantiate/0` seeds** (`seed_fuel`
    under `MeterFuel` + `seed_policy` always) as a documented exception; hot function bodies stay
    posture-agnostic (F5 zero-overhead intact).
  - **No fuel-budget channel** (the runaway-loop trap proof was unconstructible) → added
    **`fuel_budget: Int` on `Binding`** (mirrors `safe_max_pages`) + **`profiles.safe_metered(budget)`**;
    single channel, no fallback.
  - **Import cycle** (`ir_opt` ↔ `aggressive`) → keystone hosts the `Pass` combinators in a **leaf
    `middle/ir_opt/pass.gleam`** (imports `ir` only).
  - **F4 corrected**: Safe/Unsafe are **different B3-monomorphized builds** (metering compiled
    in/out; optimizer at build time) sharing identical `rt_*` names, + per-instance seeded runtime
    policy — not "same code, swapped runtime" (that single-`.beam` B1 is Phase 4).
  - **Fail-open metering closed** (D4): a `MeterFuel` artifact is bounded by default (always seeds;
    run-ABI instantiates before invoke); unseeded-accumulate is an explicit legacy/test posture.
  - **06/08-vs-09 passthrough contradiction resolved**: passthrough is a shim **behind
    `stdlib_module`** so the emit target is invariant — preserving the D3a structural test *and* the
    F5 differential permanently. **Honesty**: Phase-3 speed comes from the **optimizer alone**
    (passthrough/widened-BIF ship as a zero-active-route mechanism); "faster than hand-written
    Erlang" is a *measured* question (hand-written baseline is CRC-32-only). Termination measures
    fixed (baseline μ=(n_loops,…); inlining on `B_remaining`); `Aggressive ⟹ MeterOff` coupling +
    test added. The security lens verified D3a (no ambient authority) and per-instance isolation
    **hold** under Unsafe. Plan is now internally consistent (seams grepped); implementation next,
    keystone-first.
- **Phase-2 plan authored + reconciled.** Grounded (5 topics) + adversarially critiqued (4
  lenses); the keystone decision (mutable state = tier-O **pdict `cell`**) was verified to
  preserve constant-space loops + preemption. Foundation docs (`phase-2/00-overview.md`,
  `01-interface-freeze.md`) + 10 unit docs (`02`–`11`) authored. Post-authoring reconciliations
  folded into the keystone (flagged by the unit agents):
  - **Cell access without circular imports:** `rt_state` holds the per-layer values **opaquely
    as `Dynamic`** under one fixed namespaced key and exposes typed `mem_get/mem_put`/
    `table_get/table_put`; fresh `mem`/`table` are built by `rt_mem:fresh`/`rt_table:new` (not
    rt_state) and assembled into the cell by the generated `instantiate` entry via `StateDecl`.
  - Added **`start: Option(String)`** to the IR Module (instantiation needs it) and a
    **`TableOutOfBounds`** TrapReason ("out of bounds table access") for active-element OOB.
  - `rt_table` gains **`new`** + **type-tagged entries** (`#(FuncType, closure)`) so
    `call_indirect`'s structural type check has a tag and rt_state needn't construct the table.
  - Instantiation order corrected to the spec's **element → data** (then start).
  - The Safe **max-pages cap** is enforced in `rt_mem:grow` (single-sourced value baked into the
    Mem at `fresh`), not threaded through generated code.
  - `get()` on an un-seeded cell is an **internal** invariant error (node-safe crash), not a WASM
    `TrapReason`. The keystone's "land green" list now includes the `Module`/`MemLoad`
    constructor reach across the tree (incl. unit-02's `roundtrip_test.gleam`).
- **Robustness fix-pass — the 3 conformance-surfaced codegen gaps are FIXED** (no IR/ABI
  change needed; entirely in `emit_core.gleam` + `lower.gleam`). Root causes & fixes:
  (1) **multi-result calls** (the `ArityMismatch` — actual trigger was `fac-ssa`'s 3-result
  helper, not loop-params) → emit_core now binds a multi-result call as a value list and
  unpacks per the callee's result arity; (2) **a BEAM function returns exactly one value**
  → a function-boundary packager (0 results → `'ok'`, 1 → bare, N → N-tuple) + the
  trapping-op `case` arms unified to one value each; (3) **`UnboundLabel` on a branch-target
  `if`** → lower wraps an `If` that is a `br` target in a label-bearing `Block` (only when
  needed). 3 end-to-end regression tests added. **Conformance: 1699→1740 pass (+41),
  1400→1359 skip (−41), fail still 0** (fac 0→6, labels 3→28, traps 0→10). Remaining skips
  on those files are genuinely out of Phase-1 scope (`assert_exhaustion`, trapping
  float→int `trunc_*`, memory `load`). 313 tests, zero warnings.
- **Unit 11 landed (capstone) — PHASE 1 COMPLETE.** A real WASM binary now compiles
  through decode→validate→lower→**ir_lower(Safe)**→emit→build→run on the BEAM, driven by a
  CLI. `ir_lower` enforces the `rt_bif` allowlist fail-closed (allowlisted `("std","gcd")`
  runs; an un-allowlisted/undeclared `CallHost` → build-time `ForbiddenHost`; a declared
  host import passes to run-time deny-all) and inserts `Charge` metering (fuel accumulates
  per the cost model without changing results; `sum_to(100000)` stays constant-space with
  metering on). `profiles.safe()` + linker (fail-closed). The CLI (`src/twocore.gleam`)
  exposes every stage independently (decision #5): `decode`/`validate`/`lower`/`ir`/
  `ir-lower`/`emit`/`to-core`/`build`/`run` — verified e.g. `gleam run -- run add.wasm add
  2 3` → `5`. `pipeline.gleam` completed with the real per-stage `PipelineError`. 310 tests;
  the embedded spec-suite stays 1699/1400/0. Deps `argv` + `simplifile` added (CLI). Minor:
  `RunResult.Trapped` carries a `String` reason (reuses unit 07's trap channel + represents
  capability denials); `LowerError` gained a `ForbiddenHost` variant; a `twocore_cli_ffi.erl`
  catching-apply shim was added (unit 04's FFI is single-owned).
- **Unit 07 landed (conformance harness, oracle & corpus).** The Phase-1 acceptance
  corpus passes end-to-end through decode→validate→lower→emit→build→invoke (the goal
  proof: add/wrap, signed&unsigned div pair, INT_MIN/-1 & /0 traps, shift-mask, sum_to,
  fib/fac, an f32/f64 program, host-import deny). The Tier-A spec-suite runner over the
  pinned testsuite allowlist reports **1699 pass / 1400 skip / 0 fail** with categorized
  skips (no silent truncation). Bit-pattern/NaN-class oracle; multi-module registry; uses
  OTP `json:decode` (no new Hex dep). Pinned: testsuite SHA
  `193e551ff22663995b1ac95dc62344133669e14b`, wabt 1.0.41, wasmtime 46.0.1. **wasmtime v46
  invoke syntax** (differs from the doc's v14 assumption): `wasmtime run --invoke <fn>
  <module.wasm> <args…>` (flags+fn before the module, call args after). `driver.pipeline()`
  is a working `runner.Driver` the capstone (11) reuses unchanged. Bulk testsuite is
  gitignored; a 6-file curated fixture subset is committed (fresh-checkout CI: 466/156/0).
  - **KNOWN ISSUES surfaced by conformance (correctly SKIPPED, fail=0 — not false passes;
    follow-up fix-pass after unit 11):** (a) `emit_core` `ArityMismatch(3,1)` on
    `fac-iter`-style multi-arg calls; (b) zero-result functions → `build: return count
    mismatch`; (c) some nested control → `emit: UnboundLabel`. These are beyond the Phase-1
    acceptance corpus but are real robustness gaps in units 08/10 worth fixing.
  - 5 allowlist files (`local_tee, br_if, br_table, select, func`) are un-`wast2json`-able
    at the pinned HEAD (reference-type proposal syntax); `vendor.sh` skips them — recover
    with a wabt bump or an MVP-clean pin later.
- **Unit 02 landed (`.ir` printer & parser).** Canonical printer (floats as raw hex bits)
  + a total recursive-descent parser with its own positioned `ParseError`; round-trip
  `parse(print(m))==m` over the full IR surface (all 68 NumOps, 26 ConvOps, every Expr
  variant, NaN payloads/`-0.0`/±Inf bit-exact); the 3 hand-authored goldens parse; 25-input
  garbage battery returns typed errors without panic. 237 tests. **`ir-grammar.md`
  reconciled** to the (now-tested) implementation — notably `;` is a comment, not a
  `let`/`charge` separator (fixing a conflict in the seeded grammar), trap-reason spellings
  match the `TrapReason` ctor snake_case, and `data`/`ConvOp`/`TermOp` spellings finalized.
- **Unit 10 landed (WASM validate & lower) — FULL `.wasm` → BEAM PIPELINE WORKS.** Real
  `wat2wasm` fixtures decode → validate → lower → emit_core → build_beam → run on the
  BEAM with spec-correct results: `add(2,3)=5` (+ wrap), `sum_to(100)=5050`, `fib(10)=55`.
  212 tests, zero warnings, fail-closed (no panic on hostile input).
  - **10a validate** is a faithful transcription of the spec abstract-stack algorithm
    (vals+ctrls stacks, polymorphic-after-`unreachable`, loop label = input types, full
    br/br_table/call/index checks, else-less-`if` rule, per-function local cap 50000);
    rejects every ill-typed fixture with a spec-cited `ValidateError`; imports only
    `ast.gleam` (gates independently of the IR).
  - **10b lower**: stack-elim to compile-time `ir.Value` list (no runtime stack); WASM
    branch DEPTHS resolved to NAMED IR labels (D6); mutable locals threaded as
    `LoopParam` (loops) / block result values via a sound syntactic over-approximation
    (locals assigned anywhere in a construct); declared locals zero-init'd via `Let`.
  - **Notes for unit 11:** lower names a defined function at funcidx `f` as `"f<funcidx>"`
    (offset by `imported_func_count`); `ExportFn(export_name, "f<idx>")` (emit_core emits a
    forwarding wrapper when names differ); IR module name `"twocore@wasm@<sanitized>"`.
    `call_indirect` is rejected at validation (and guarded in lower). Rename in lower if
    the CLI/linker wants different names.
- **Unit 05 landed (WASM decoder & AST).** `decode/1`, generic `decode_u_n`/`decode_s_n`
  LEB128 (all spec vectors incl. overflow/too-long), the worked `add` fixture decodes to
  the exact AST, `wat2wasm` fixtures (loop/if/call/locals/multi-value), and a fail-closed
  fuzz suite (256×41 single-byte mutations + truncations never crash). 54 tests; the
  decoder code has no `let assert`/`panic`/`todo`. **`«WASM-AST»` published** with
  `Module(imported_func_count, types, funcs, exports)`, `Func(type_idx, locals, body)`,
  the Phase-1 `Instr` set, `ValType`, `BlockType`, and `DecodeError`. **Notes for unit 10:**
  `Func.locals` are RLE-expanded **declared-only** (params are indices 0..k-1, declared
  locals follow) — lower must zero-init each declared local as an IR `Let` (emit_core
  ignores `ir.Function.locals`); use `Module.imported_func_count` as the funcidx offset
  (don't assume funcidx==defined index); and put a **per-function local-count cap** in the
  validator (the spec sets that limit in validation — guards against RLE over-allocation).
- **Unit 08 landed (emit_core) — BACKEND PROVEN END-TO-END.** Hand-written IR compiles to
  Core Erlang and runs on the real BEAM: `add(7,35)=42`, i32 wrap & shift-masking,
  `sum_to(100000)=5000050000` in **constant space** (letrec tail-`apply` back-edge),
  `fib(20)=6765`, `fac(10)=3628800`; `div_u(_,0)`/`div_s(INT_MIN,-1)` trap as
  `{wasm_trap,…}`; a host import is rejected `{capability_denied,…}` (deny-all); and
  `CallHost("std","gcd")` → `rt_stdlib:gcd`. Binding chokepoint + the structural codegen
  security-invariant test pass. 130 tests, zero warnings. **Pinned notes for downstream:**
  - **Unit 10 (lower):** emit_core IGNORES `Function.locals` (Phase-1 corpus has none).
    Lowering must make WASM locals flow through `Let`/`LoopParam`/params — i.e. emit an
    explicit zero-init `Let` for each declared WASM local at function entry, and turn
    mutable locals that are live across control flow into `LoopParam` (SSA). Numeric
    `Convert` ops (wrap/extend/reinterpret/trunc_sat) ALREADY lower in emit_core; only the
    four term↔numeric **boxing** Converts are `UnsupportedNode` (not needed for the WASM
    numeric path).
  - **Unit 11 (ir_lower):** the `("std","gcd")→rt_stdlib:gcd` resolution currently also
    lives as a small `resolve_stdlib` table in emit_core; ir_lower's allowlist
    (`rt_bif`) must stay ALIGNED with it (same triple). `CallHost` cap/name are emitted
    as atoms (faithful for deny-all; revisit only if a permissive host needs binaries).
  - Added a test-only `test/twocore_emit_test_ffi.erl` (`catch_apply/3`) so Gleam tests
    can rescue an error-class trap without crashing the runner (gleam_erlang 1.3 has no
    generic rescue).
- **Unit 09 landed (Safe-mode runtime defaults).** `rt_trap`/`rt_host`/`rt_meter`/
  `rt_stdlib`/`rt_bif` + 34 security/fail-closed tests; zero warnings. **Pinned
  cross-unit conventions** (units 08 & 11 must follow):
  - Runtime ABI the generated code calls: `rt_trap:raise/1` (reason = the snake_case
    atom of the `TrapReason` ctor; raises error-class `{wasm_trap, Kind}`),
    `rt_host:call_host/3` (deny-all, raises `{capability_denied, Cap, Name}`),
    `rt_meter:charge/1`.
  - **`rt_meter` is tier-O** (process-dictionary fuel counter, observable via
    `fuel_consumed/0`) — confirmed in-bounds for Safe (P or O, never N).
  - **`call_host` → own-stdlib triple (PINNED):** IR `CallHost(capability:"std",
    name:"gcd")` resolves (by `ir_lower`, unit 11) to `rt_stdlib:gcd/2`; the `rt_bif`
    allowlist contains exactly `("twocore@runtime@rt_stdlib","gcd",2)`. Unit 08 emits
    the direct call; unit 11 does the rewrite.
  - `rt_trap.spec_trap_message/1` maps each `TrapReason` → the WASM spec trap-message
    substring (for the unit-07 harness): int_div_by_zero→"integer divide by zero",
    int_overflow→"integer overflow", unreachable→"unreachable".
- **Unit 06 landed (rt_num bodies).** All 90 frozen signatures implemented in pure Gleam
  over BEAM bignums + bit syntax; the numeric-fidelity reference (high-level §9.1).
  40 spec-corner/property tests (div_s INT_MIN/-1 overflow trap, rem_s INT_MIN/-1 == 0,
  /0 traps, shift-count mod N, sign-fill, extend/wrap, reinterpret, canonical-NaN,
  signed-zero min/max, trunc_sat clamps). **Build is now zero-warning** (the 90 `todo`
  warnings are gone). Verified correction to the doc: f32 bit-build *saturates* to ±Inf
  on OTP 29 (does not raise `badarith`); only f64 overflow needs the guard, handled
  exactly via the IEEE round-to-nearest threshold.
- **Unit 04 landed (build_beam + FFI shim).** A hand-written `.core` module compiled,
  loaded via `code:load_binary`, and ran on the BEAM with correct results (incl.
  hot-replace), and malformed `.core` returns a typed `BuildError` (no panic).
  `gleam_erlang v1.3.0` added. Two real bugs were corrected in the unit-doc's "verified"
  shim (they only surface when called *from Gleam*, not from an Erlang shell): the
  scan/parse error branches returned a bare binary instead of a `[Binary]` list, and
  `load_module`'s filename must be an Erlang charlist (`unicode:characters_to_list`), not
  a Gleam-`String` binary. Both fixed + documented inline in `twocore_codegen_ffi.erl`.
- **Unit 01 landed (interface freeze).** IR types, runtime `Binding` ABI + calling
  convention, the complete 90-function `rt_num` signature set (`todo` bodies, owned next
  by unit 06), and `PipelineError` are frozen. `gleam build` clean except the 90
  sanctioned `todo` warnings; `gleam test` green (7); neutrality review (D6) passed.
  Two notes for downstream: (a) the seeded `ir-grammar.md`/golden examples were corrected
  to **strict ANF** (the original nested `num` exprs in `return`/`if` operand positions,
  which the `Value`-typed fields forbid); (b) `rt_num` stub args are underscore-prefixed
  (`_a`,`_b`) to keep the build warning-free — unit 06 restores `a`/`b` with the bodies.
- **Planning, post-review reconciliation (initial drafting):** after the unit docs were
  drafted, these refinements were folded back into the frozen foundations so the
  contracts are internally consistent:
  - `Function` carries **named params** (`params: List(Local)` + `result`), with
    `signature/1` deriving the `FuncType` — closing the `%p0`/`%p1` round-trip gap
    between `ir.gleam` and `ir-grammar.md` (flagged by unit 02). Grammar updated.
  - `«RTNUM-SIG-FROZEN»` now requires the **complete** Phase-1 `rt_num` name list
    (integers + i64 mirror + conversions + floats), by a fixed naming rule — so units 06
    and 08 don't race on spellings (flagged by 06/08).
  - `CallHost` has **two fates**: `ir_lower` (11) rewrites a resolved `own`-stdlib call
    into a direct `rt_stdlib` call; a genuine host import stays a deny-all `call_host`.
    `rt_bif` is a **build-time** gate consulted by `ir_lower`, not a `Binding` field /
    runtime call — its gate shape freezes with unit 11 (flagged by 09/11).
  - Tier framing corrected: Phase-1 compute is tier-P; the **metering** counter may be
    tier-O (pdict), which Safe permits (P or O, never N) — unit 09 may instead ship a
    pure no-op `charge` (flagged by 09).
  - `ir_lower` reads `ir.gleam` **+ the `Binding` type** (for `mode`/policy); the
    ownership note was relaxed accordingly (flagged by 11).
  - Dependency note added: units 04/08/09 will `gleam add gleam_erlang` (flagged by 04).
  - `00-overview` §3 DAG/prose numbering corrected (decoder = 05, build_beam = 04,
    validate+lower = 10; `«WASM-AST»` unblocks 10) (flagged by 05).
