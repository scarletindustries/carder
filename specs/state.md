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

### Phase-6 units (all **done** — PHASE 6 PROVEN: the complete WebAssembly 2.0 surface)

| Unit | Doc | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|---|
| **P6-01** Interface freeze (keystone) | [`01`](phase-6/01-interface-freeze.md) | **done** | — | IR4 landed GREEN + byte-identical: **1220 tests pass** (1212 baseline + 8 new `ir4_freeze_test`), **conformance 21525/1257/0 unchanged**, zero warnings, format-clean. Leaves: `TV128` ValType; `ConstV128(bytes)` Value; parametric `SimdOp` (SIMD-float ctors `SF`-prefixed to avoid `NumOp` collision — see deviation) + `SimdShape`/`SimdHalf`/`SimdLoadKind`; the 6 SIMD `Expr` nodes + `CallImport(slot,ty,args)`; `effect` PURE-lanewise (`Simd`/`SimdShuffle`) vs BARRIER (4 SIMD-mem + `CallImport`) split; `TrapReason` unchanged (S8); `rt_simd.gleam` (NEW — **217** pure heads + 4 memory helpers, `panic`-placeholder, todo-free, import-free); `Binding.mem64_max_pages=2³²` (S9); `ProvidedFunc.call` closure field (S5); printer/parser/emit_core/lower/ir_lower/ir_opt(baseline+aggressive+pass) land-green arms. Full impls: 02 (printer/parser round-trip), 05 (lower), 06 (emit), 07 (rt_simd bodies), 08 (mem64), 09 (linker). |
| **P6-02** `.ir` printer/parser ext | [`02`](phase-6/02-ir-textual-form.md) | **done** | `«IR4»` | `.ir` round-trips the FULL IR4 surface (`parse(print(m))==m`): `v128.const` byte-exact (NaN-payload/`-0.0`/`+Inf`/normal lanes, D5), EVERY `SimdOp` constructor × every `SimdShape` (the parser `string_to_simdop` is the exact inverse of the keystone's `<shape>.<op>` `simdop_to_string` scheme), `SimdShuffle`, the four SIMD-memory nodes (every `SimdLoadKind`/width/lane at mem 0 AND non-zero, BITS per S2), and `CallImport(slot,ty,args)`; `v128` valtype in every position; the 16-byte `v128.const` length check (`BadNumberLiteral`, no new `ParseError` variant); total parser (SIMD/`call_import` garbage battery, incl. non-16-byte const → typed error, no panic). New hand-authored `golden/simd.ir` + independent expected `Module`; memory64 + cross-module import DECL confirmed byte-identical (unchanged from P5). Grammar reconciled: **`specs/phase-6/ir-grammar-delta.md`** (documents the frozen `<shape>.<op>` scheme; cross-linked from `ir-grammar.md` + the P5 delta). **1236 tests pass (was 1220, +16), 0 warnings, format-clean, conformance 21525/1257/0 unchanged (byte-identical).** |
| **P6-03** decode ext (+ `«WASM-AST4»`) | [`03`](phase-6/03-decode.md) | **done** | — | **Landed GREEN + byte-identical: 1271 tests pass (1236 baseline + 35 new SIMD decode tests), conformance 21525/1257/0 unchanged, zero warnings, format-clean.** Published **`«WASM-AST4»`** in `ast.gleam` (S1 shape, S2 bits): `ValType` gains `V128` (0x7B, not a reftype); new types `SimdShape{I8x16 I16x8 I32x4 I64x2 F32x4 F64x2}`, `SimdHalf{Low High}`, a shape-tagged `SimdOp` (mirrors `ir.SimdOp` 1:1, float ctors **`F`-prefixed** since `ast` has no `NumOp` collision — `05` relabels `F*→SF*`; parametric `SNarrow/SExtend/SExtMul/SExtAddPairwise` per S3; the saturating **`SAddSatS/U`/`SSubSatS/U`** family; named conversions; lane-access carries `lane`), and `SimdLoadKind{LoadV128 LoadSplat(lane_bits) LoadExtend(source_bits,signed) LoadZero(lane_bits)}` (**all BITS**, S2). SEVEN SIMD `Instr`s: `Simd(op)` + `V128Const(bytes)` + `I8x16Shuffle(lanes)` + `SimdLoad(kind,arg)` + `SimdStore(arg)` + `SimdLoadLane(width,arg,lane)` + `SimdStoreLane(width,arg,lane)`. New `DecodeError.UnknownSimdOpcode(Int)` (only new variant). `decode.gleam` decodes the `0xFD` prefix + LEB `u32` sub-opcode + ALL 236 sub-opcodes (20 reserved gaps + `>=256` relaxed → `UnknownSimdOpcode`) → AST4; `v128.const` reads 16 raw LE bytes, `i8x16.shuffle` 16 lane bytes, extract/replace read a 1-byte lane, the v128-memory ops reuse Phase-5 `decode_memarg` (+ trailing lane byte for `*_lane`, memarg-THEN-lane wire order); `decode_valtype` accepts `0x7B→V128`, `decode_blocktype` the `-5` encoding. Total/fail-closed (truncation battery + single-byte-mutation fuzz + the spec-exhaustive 0..255 opcode-map audit: exactly 236 Ok + 20 gaps). Fail-CLOSED land-green arms in `validate.gleam` (all 7 SIMD `Instr`s → `Error(Unsupported)` BEFORE the fail-open `numeric_sig` fallthrough, S1) and `lower.gleam` (`ast.V128→ir.TV128` in `to_ir_vt`; SIMD instrs still `Unsupported`). memory64 decode unchanged (regression-tested). **Hands to:** 04 (types v128 stack, lane-index/shuffle/alignment bounds — the `Unsupported` arms are its intercept points), 05 (AST4→IR4: `ast.SimdOp→ir.SimdOp` near-1:1 relabel, `V128Const→ConstV128`, the SIMD-memory `Instr`s→IR nodes). |
| **P6-04** validate ext | [`04`](phase-6/04-validate.md) | **done** | `«WASM-AST4»` | **Landed GREEN + byte-identical: 1322 tests pass (1271 baseline + 51 new SIMD validate tests), conformance 21525/1257/0 unchanged, zero warnings, format-clean, no `twocore/ir` import (AST-only boundary).** Replaced P6-03's fail-closed `Unsupported` placeholders with real typing: all 7 SIMD `Instr`s intercepted BEFORE the `numeric_sig` fallthrough (S1). `validate_simd` (exhaustive on `SimdOp`) + `simd_sig` type every lane op — arithmetic/bitwise `[v128 v128]→[v128]` (unary `[v128]→[v128]`), **comparisons → v128 MASK `[v128 v128]→[v128]` (not i32)**, shifts `[v128 i32]→[v128]`, `splat [unpacked(shape)]→[v128]`, extract `[v128]→[unpacked]`, replace `[v128 scalar]→[v128]`, `any_true`/`all_true`/`bitmask [v128]→[i32]`, bitselect ternary, widen/narrow/extmul/pairwise/convert/dot/q15/swizzle; illegal `(op,shape)` combos rejected fail-closed via `require_shape`→`Unsupported`. The 6 dedicated `Instr`s: `V128Const [] →[v128]` (+ const-expr arm); `I8x16Shuffle` each index `<32`; `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane` reuse the scalar `mem_addr_type`/`check_align`/`check_offset` seam (memory64: `v128.load` on a 64-bit memory pops `i64`) — alignment `2^align≤N/8` (BITS, S2), lane `<128/N`. New `ValidateError.BadLaneIndex(index)` (only new variant; `BadAlignment`/`OffsetOutOfRange`/`TypeMismatch`/`Unsupported` reused). memory64 typing re-confirmed spec-complete (`2^48`-page validation limit distinct from P6-08's runtime cap); cross-module fn-import typing unchanged (call types against declared `FuncType`). **Leaves for P6-05:** the structurally-unchanged `TypedModule` (SIMD result types read off the op constructor — no new field; `func_types` imports-first for `CallImport` slots; `memory_idx_types` for i64 address width). |
| **P6-05** lower ext | [`05`](phase-6/05-lower.md) | **done** | `«WASM-AST4»`, `«IR4»` | **Landed GREEN + byte-identical: 1336 tests pass (1322 baseline + 14 new lower tests), conformance 21525/1257/0 unchanged (no category moved), zero warnings, format-clean.** AST4→IR4 for the full new surface: `ast.Simd(op)` → `ir.Simd(relabel(op), args)` via an explicit relabel table (shape-uniform copy; **`F*`→`SF*`** floats; parametric `SNarrow`/`SExtend`/`SExtMul`/`SExtAddPairwise` copy `from`/`half`/`signed`; named conversions + sat family + lane-access copy 1:1 — S3), routed through `emit_value_op_t` with the arity + result type derived from the neutral op (`simd_op_arity_result`: compares → v128 MASK, reductions → i32, extract-lane → the lane scalar). `ast.V128Const(bytes)` → the `ConstV128(bytes)` Value (pushed like a numeric const, no `Let`); `ast.I8x16Shuffle(lanes)` → the dedicated `SimdShuffle(lanes,a,b)` node; the four SIMD-memory `Instr`s → `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane` (loads bound via `emit_value_op_t`, stores are zero-result `emit_effect`s; memidx + BITS width (S2) + static offset + lane threaded). **memory64 (I4): DELETED `reject_memory64` + the `Memory64Unsupported` `LowerError` variant** — a 64-bit memory now lowers, carrying `Idx64` onto `MemoryDecl`/`ImportMemory`; the i64 address flows unchanged (no width branch). **Imported calls (S5): `lower_call` fetches the callee sig up front and emits `ir.CallImport(slot=funcidx, ty, args)` for `funcidx < imported`** (positional import slot), `CallDirect` for same-module; `lower_const_expr` gains the `v128.const` global-init arm. **Leaves for 06/07:** the IR4 nodes emit_core lowers through the `rt_simd`/`rt_mem`/`link.call_import` seams (emit still rejects the new nodes with typed `UnsupportedNode`, so SIMD/mem64/import modules produce IR but don't yet run e2e — a categorized skip, fail=0 preserved). |
| **P6-06** emit_core ext | [`06`](phase-6/06-emit-core.md) | **done** | `«IR4»`, `«RT-SIMD-SIG»`, `«XLINK»` | **Landed GREEN + byte-identical: 1479 tests (was 1446, +33), conformance 21525/1257/0 UNCHANGED (no category moved — the 48-fixture suite has no SIMD/mem64/linking files, so the new surface is exercised by this unit's own hand-built e2e; lighting the `.wast` suites is P6-10), zero warnings, format-clean.** **The Phase-6 surface now RUNS e2e on the BEAM** (the first real SIMD/mem64/cross-module runs). SIMD: `simd_op_name : SimdOp→rt_simd` chokepoint (every ctor → the exact frozen head, spec mnemonics; `SReplaceLane`'s lane rides MIDDLE per the real rt_simd sig, superseding the stale doc); `Simd`/`SimdShuffle` PURE + state-neutral (byte-identical Cell/Threaded, keeps Phase-1 pure arity — I7); `ConstV128` → the raw 16-byte binary literal. SIMD memory (the S4 compose table EXACTLY): `v128.load/store`→`load_bytes`/`store_bytes`(16); `loadNxM`→`load_bytes(8)`+`v128_load_extend`; `loadN_zero`→`load_bytes`+`v128_load_zero`; `loadN_splat`→scalar `load`+`iNxM_splat`; `loadN_lane`→scalar `load`+`v128_replace_lane_bits`; `storeN_lane`→`v128_extract_lane_bits`+scalar `store` (extract-pure-first); `rt_mem` owns the bounds trap, `rt_simd` the pure assembly. memory64: `mem_fresh_term` grows an `idx_type` branch (`Idx64`→`fresh64(Min,Max,mem64_max_pages)`; `Idx32`→byte-identical `fresh`), `needs_full_decl` routes `Idx64`/v128-globals/func-import-callers through `FullDecl`; op sites are TRANSPARENT (32-bit BYTE-IDENTICAL — proven). `CallImport(slot,ty,args)` → read the closure from `rt_state:func_import_at(slot)`/`t_func_import_at` then `link:call_import(closure,[args])` (S5 — the frozen 1-ary seam, NEVER `erlang:apply`; result LIST unpacked to `len(ty.results)`). v128 globals (S6): `emit_global_get`/`set` + `defined_globals`/`imported_slots`/`render_ref_global_init` route v128 (with reftypes) to the boxed `ref_global_get`/`set` accessor. Completed the S5 seam P6-09 left: added `rt_state.func_imports` vector field + `seed_func_imports`/`func_import_at` (cell) + `set_func_imports`/`t_func_import_at` (threaded), seeded at instantiate via `count_import_slots` (state imports ++ func-import closures; a module that imports-without-calling is byte-neutral — no `CallImport` ⇒ no seed ⇒ `instantiate/0`). **e2e (16, execute on the BEAM):** `i32x4.add`/`i8x16.add` lane-width wrap, `f32x4.mul` IEEE-exact, shuffle, swizzle-OOB→0, extract/replace-lane; `v128.store`/`load` roundtrip, `load32_splat`, `load64_zero`, OOB→trap, `store8_lane`; a 64-bit memory grown past 2³² with a store/load at byte 2³²+40, grow-beyond-cap→−1, access-beyond→trap, Idx32≡Idx64 op sites; a `v128` global get/set; a cross-module WASM→WASM `CallImport` (B calls A's exported fn through the linker closure). **D3a extended (Cell/Threaded/Unsafe):** allow-set + `rt_simd`; the surgical proof — NO `erlang:apply` anywhere (dispatch is `link:call_import` over a `func_import_at` closure); SIMD/mem64/global/import seams delegated to the runtime; SIMD-mem faults reach `rt_trap:raise`. Deviations (justified): the SIMD module is a fixed atom `twocore@runtime@rt_simd` (no `binding.simd_module` field — the keystone did not add one; like `rt_ref`/`link`); `link.call_import` (not `erlang:apply/2`, per S5, keeping a homogeneous twocore-only allow-set); func-import closures ride the positional `Imports` list (state ++ func) — the harness passes `link_imports ++ link_func_imports`. **Threaded cross-instance record-threading + the conformance `.wast` wiring stay P6-10.** |
| **P6-07** rt_simd (NEW; 07a–07d) | [`07`](phase-6/07-rt-simd.md) | **fully done (07a+07b+07c+07d) — rt_simd COMPLETE** | `«RT-SIMD-SIG»` | The ~214–224 lane heads over a 16-byte BitArray, bit-exact, reusing `rt_num`; the four memory lane-assembly helpers; **four balanced passes** (S10); differential vs oracle/wasmtime. **P6-07a landed GREEN + byte-identical: 1357 tests (was 1336, +21 spec-cited differential test fns), conformance 21525/1257/0 unchanged, zero warnings, format-clean.** Established the SHARED private lane codec 07b/07c/07d reuse — `decode_lanes(v: BitArray, w: Int) -> List(Int)` / `encode_lanes(lanes: List(Int), w: Int) -> BitArray` (little-endian, D5, `w ∈ {8,16,32,64}` bits) + `map2_lanes`/`map1_lanes` drivers + the integer width-core (`pow2`/`all_ones`/`mask_low`/`signed_of`(=`lane_signed`)/`shift_count`(mask mod lane width), each mirroring a `rt_num` private worker at an arbitrary lane width). Filled **54 heads**: `iNxM_add`/`sub` (all 4 shapes) + `mul` (i16x8/i32x4/i64x2, no i8x16.mul), `neg`/`abs` (all 4), saturating `add_sat_s/u`+`sub_sat_s/u` (i8x16/i16x8), `min_s/u`+`max_s/u` (i8x16/i16x8/i32x4), `avgr_u` (i8x16/i16x8), `shl`/`shr_s`/`shr_u` (all 4, count masked mod lane width), `i8x16_popcnt`. Arithmetic wrap + popcount CONSUMED from `rt_num` (`i32`/`i64_add/sub/mul`, `i32_popcnt`); `rt_num` never edited (D1). Tests are DIFFERENTIAL vs an independent flat-`List(Int)` oracle (`%`/`/`, not the impl's `band`) + hand-worked spec edges (two's-complement wrap, sat boundaries 127+1→127/−128−1→−128/255+1→255, avgr rounding, shift masking i32x4.shl 33≡1, popcnt, signed-vs-unsigned min/max, LE lane layout). **P6-07b landed GREEN + byte-identical: 1374 tests (was 1357, +17 spec-cited differential test fns in `rt_simd_cmp_test.gleam`), conformance 21525/1257/0 unchanged, zero warnings, format-clean.** Filled **65 heads** reusing the 07a codec: all integer comparisons → v128 MASK (`eq`/`ne`/`lt_s`/`lt_u`/`gt_s`/`gt_u`/`le_s`/`le_u`/`ge_s`/`ge_u` for i8x16/i16x8/i32x4 = 30; i64x2 `eq`/`ne`/`lt_s`/`gt_s`/`le_s`/`ge_s` = 6, signed-only ordering per spec), each lane→all-ones(`2^w-1`) if the relation holds else 0 (signed via `signed_of`, the sanctioned local mirror as in 07a min/max); shape-agnostic bitwise over the whole 128 bits (`not`/`and`/`or`/`xor`/`andnot(a AND ~b)`/`bitselect((a&m)|(b&~m))`) via a `bits128`/`from_bits128` whole-vector view = 6; boolean reductions `v128_any_true`+`iNxM_all_true`+`iNxM_bitmask` (sign-bit gather, lane 0→bit 0) = 9; lane access `splat`/`extract_lane(_s/_u)`/`replace_lane` for all six shapes = 20 (extract_s reuses `rt_num.i32_extend8_s`/`i32_extend16_s`). New private helpers: `cmp_mask`/`bits128`/`from_bits128`/`all_true`/`bitmask`/`lane_at`/`set_lane`/`splat`. Tests DIFFERENTIAL vs an independent oracle (`%`/`/` + arithmetic bit-decomposition, never `band`) + hand-worked spec edges (all-ones/all-zeros masks, the signed/unsigned split `lt_s(-1,0)=T` vs `lt_u(0xFFFFFFFF,0)=F`, i64x2 signed compares, bitselect identities + algebraic laws, all_true all-lanes-nonzero edge, bitmask `[neg,pos,neg,pos]→0b0101` & i8x16 lanes{0,15}→0x8001, sub-word `extract_lane_s` sign-extension 0xFF→0xFFFFFFFF, splat/extract/replace round-trips). **P6-07c landed GREEN + byte-identical: 1390 tests (was 1374, +16 spec-cited differential test fns in `rt_simd_float_test.gleam`), conformance 21525/1257/0 unchanged, zero warnings, format-clean.** Filled **52 heads** (the IEEE-754 pass) reusing the 07a codec + 07b `cmp_mask` — a float lane IS its raw 32/64-bit pattern, so each lane funnels straight to the matching `rt_num` f32/f64 head (f32 SINGLE-ROUNDING + the canonical-NaN lock + WASM min/max NaN & -0.0 rules all INHERITED from `rt_num`, never re-implemented; `rt_num` never edited, D1): `f32x4`/`f64x2` `add`/`sub`/`mul`/`div` (8) + `neg`/`abs`/`sqrt` (6) via `map1`/`map2_lanes`; `min`/`max` (4, direct `rt_num.f*_min`/`_max`) + `pmin`/`pmax` (4, the pseudo-form `(b<a)?b:a`/`(a<b)?b:a` built from `rt_num.f*_lt` — returns the non-forced operand VERBATIM, no NaN canonicalisation, asymmetric on ±0); `ceil`/`floor`/`trunc`/`nearest` (8); the six float compares → v128 MASK (12, NaN unordered: `eq/lt/le/gt/ge` false → all-zeros, `ne` true → all-ones) via a `fcmp` adapter over `cmp_mask`; the 10 conversions `convert_i32x4_s/u`→f32x4, `convert_low_i32x4_s/u`→f64x2 (low 2 lanes only), `trunc_sat_f32x4_s/u`, `trunc_sat_f64x2_s/u_zero` (2 lanes → i32 lanes 0,1; lanes 2,3 forced 0), `demote_f64x2_zero` (single-rounding narrow, top 2 lanes +0.0), `promote_low_f32x4` (exact widen of low 2). New private helpers: `pmin_lane`/`pmax_lane`/`fcmp`/`convert_low2`(4→2 lanes)/`narrow_zero`(2→4, zero top). Tests: hand-computed spec bit patterns built from Gleam `Float` literals via BEAM `<<x:float-size(32/64)>>` (an encoder DISTINCT from `rt_num`) + fixed special patterns (canonical NaN, ±Inf, ±0), PLUS a flat-`List` rebuild oracle (per-lane `rt_num` packed LE) proving the decode→dispatch→re-encode plumbing; corners pinned: f32 single-rounding (`1.0+2^-24`→`1.0` in f32 but `0x3FF0000010000000` in f64), NaN canonicalisation through add/mul/min/max vs pmin/pmax preserving the payload, `min(-0,+0)=-0`/`max(-0,+0)=+0`/`pmin(+0,-0)=+0`, abs/neg keep NaN payload, trunc_sat NaN→0 + INT_MIN/MAX/UINT_MAX saturation, convert_low ignores upper 2 lanes, `_zero` conversions zero lanes 2,3, demote overflow→±Inf. **P6-07d landed GREEN + byte-identical: 1407 tests (was 1390, +17 spec-cited differential test fns in `rt_simd_misc_test.gleam`), conformance 21525/1257/0 unchanged, zero warnings, format-clean.** Filled the final **40 heads** (the shape-CHANGING + memory pass) reusing the 07a codec (`decode_lanes`/`encode_lanes`/`signed_of`/`mask_low`/`sat_s`/`sat_u`) + 07b `set_lane`/`lane_at`: saturating `narrow_i16x8_s/u`+`narrow_i32x4_s/u` (4; source SIGNED → sat to the narrower SIGNED (`sat_s`) or UNSIGNED (`sat_u`, negative→0) range; `a`-lanes low, `b`-lanes high); `extend_low/high_i8x16_s/u`+`i16x8`+`i32x4` (12; low/high half select then sign/zero-widen to double width); `extmul_low/high` same three shape-triples s/u (12; extend the half then multiply pairwise — the product fits EXACTLY, no wrap); `extadd_pairwise_i8x16_s/u`+`i16x8_s/u` (4; sum ADJACENT (ext) pairs into the wider lane); `i32x4_dot_i16x8_s` (signed pairwise mul-add, i32 result WRAPS — all `-32768` → 2³⁰+2³⁰=2³¹ → `0x80000000`=INT_MIN, verified); `i16x8_q15mulr_sat_s` (`sat_s16((a·b+0x4000)>>15)`, the sole saturation `(-32768)²`→`0x7FFF`); `i8x16_shuffle` (16 immediates `0..31` gather from `a++b`) + `i8x16_swizzle` (dynamic byte select, OOB index `≥16`→0); and the **four v128-memory lane-assembly helpers (S4)** `v128_load_extend`(8-byte slice → 8/4/2 lanes sign/zero-extended, via `pad_low`+`extend`)/`v128_load_zero`(low `lane_bits` LE in lane 0, rest zero)/`v128_replace_lane_bits`(alias of `set_lane`)/`v128_extract_lane_bits`(alias of `lane_at`) + the PRIVATE `pad_low` worker (zero-extend a ≤16-byte LE slice to 16). New private dispatchers: `half`/`extend_lanes`/`pairwise`/`narrow`/`extend`/`interp_lane`/`extmul`/`extadd_pairwise`/`byte_at`/`pad_low`. Tests DIFFERENTIAL vs an independent flat-`List(Int)` oracle (`%`/`/`, never `band`) + hand-worked spec edges (narrow `_u` neg→0 / `>max`→max & `_s` clamp; extend low-vs-high + s-vs-u; extmul `(-128)²=0x4000` / `255²=0xFE01`; extadd adjacent-pair sums `255+255=0x01FE`; dot WRAPPING INT_MIN edge; q15 sole-saturation + `0.5·0.5=0x2000`; swizzle OOB→0 + in-range permute; shuffle `a++b` byte-select; load_extend s/u for 8/16/32 source bits; load_zero LE placement; replace/extract round-trip at 8/16/32/64 + LE extract). **rt_simd is COMPLETE — ZERO `panic as "rt_simd...` placeholder heads remain (only the module-doc mention + the sanctioned `decode_lanes` internal-invariant crash).** **Leaves:** 06 (emit_core) maps each `SimdOp`→one rt_simd head + composes the SIMD-memory family (bounds-checked `rt_mem` slice + the four pure lane-assembly helpers, S4); 06 is the last SIMD-runtime consumer. |
| **P6-08** rt_mem memory64 | [`08`](phase-6/08-rt-mem-memory64.md) | **done** | `«MEM64-RUNTIME»` | **Landed GREEN + byte-identical: 1435 tests (was 1407, +28), conformance 21525/1257/0 unchanged, zero warnings, format-clean.** memory64 RUNS + the v128-memory BitArray seam. **Additive-only** (the frozen Phase-2/4/5 heads untouched; 32-bit BYTE-IDENTICAL). Pinned the documented cap `rt_mem.mem64_hard_max_pages = 2³² pages = 256 TiB` (S9/§C — a sparse trap boundary, NOT a reservation; cited against the spec grow-may-fail licence + the 48-bit VA ceiling; invariant `hard_max_pages(65_536) < mem64_hard_max_pages <= validate.memory64_page_limit(2⁴⁸)`, single-sourced to `Binding.mem64_max_pages` in `safe_default`). New 64-bit ctors `fresh64`/`fresh_mem64`/`o_fresh64` folding the cap via the generalised `effective_max_for(max,cap,hard_cap)` (i32 `effective_max` delegates → byte-identical); `mem_grow`/`o_grow` drop the now-redundant `&& new <= hard_max_pages` conjunct (folded into `max`; proven behaviour-preserving for `Idx32`). **The v128-memory seam (S4, OWNED HERE):** `load_bytes(addr,offset,n)->Result(BitArray,TrapReason)` + `store_bytes(addr,bytes,offset)->Result(Nil,TrapReason)` — public checked wrappers over the private `read_bytes`/`write_bytes`, no-wrap bignum bounds → `MemoryOutOfBounds` trap-before-write, with the full scalar-mirrored family: pure core `mem_load_bytes`/`mem_store_bytes`, `_at` (index-routed) `load_bytes_at`/`store_bytes_at`, threaded `t_load_bytes`/`t_store_bytes`(+`_at`), oracle `o_load_bytes`/`o_store_bytes`. atomics gains idx-aware `reservation64`/`a_fresh64` (fail-closed gate: over-cap/unbounded 64-bit → `Error(Nil)`/node-safe `panic`; a TINY BOUNDED 64-bit memory admitted + runs); nif gains delegating `fresh64`(→`rt_mem.fresh64`). Tests SPEC-CITED + DIFFERENTIAL (`valid/types` `2^(|addrtype|-16)`; `exec/instructions` `ea=i+offset`, trap iff `ea+N>|mem.data|`, grow-may-fail→-1): byte-seam round-trip + OOB-trap-before-write (16/8/4-byte, mem-idx 0 and >0, cell + threaded + pure + oracle); 64-bit grow within an injected cap + `-1` beyond it; large-address round-trip at byte 2³²+40 (load8/16/32/64_u, i64-offset equivalence, no-wrap trap at byte_len−7/byte_len/ea near 2⁶⁴, bulk ops past 2³²); `mem_grow` Idx32 byte-identity battery (new rule ≡ old two-conjunct across the 65_536 boundary); the small-memory differential paged≡oracle AND atomics≡paged≡oracle over 64-bit op streams; the `mem64_hard_max_pages` constant + cross-unit invariants + the `Binding` single-source seam; atomics/nif fail-closed gate. **Leaves for 06:** seed an `Idx64` memory via `rt_mem:fresh64(Min,Max,binding.mem64_max_pages)`, box `memory.size`/`grow`/`-1` at i64 width; compose the v128-memory family from `load_bytes`/`store_bytes` + `rt_simd`'s lane-assembly helpers (S4 table). **For 09:** the idx-aware tier gate calls `rt_mem_atomics.reservation64` (fail-closed `assert_unlinkable` for an over-cap 64-bit atomics/nif binding). |
| **P6-09** cross-module linking | [`09`](phase-6/09-cross-module-linking.md) | **done** | `«XLINK»` | **Landed GREEN + byte-identical: 1446 tests (was 1435, +11), conformance 21525/1257/0 unchanged, zero warnings, format-clean.** The LINKER MACHINERY (proven in isolation; the full WASM→WASM e2e run is 06/10's). `link.gleam` grows: **`call_import(closure, args)`** — the frozen 1-ary dispatch seam 06 emits for a `CallImport` (just `closure(args)`; D3a — applies a HANDED-IN fun, never `erlang:apply(Mod,Atom,…)` nor the 2-arg apply-spread S5 fixes); **`provided_func(ty, call)`** constructor (register seam 10 publishes a cross-module export) + **`provided_func_call(p)`** extractor (06 pulls the closure into the dispatch vector, `panic` fail-closed on a non-function variant); **`link_func_imports(module, providers)`** — resolves the **function-import vector** (one `ProvidedFunc(ty,call)` per function import, function-import order) fail-closed (spec §3.2.7 equality → `UnknownImport`/`IncompatibleImportType` = `assert_unlinkable`): a `spectest`/host import → a closure wrapping `rt_host.call_host` under the instance's `HostPolicy` (deny-all/whitelist boundary preserved, value-list ABI), a `(register)`ed import → the register-seam-built routing closure (into the exporting instance's owning process). **v128/boxed globals (S6):** `rt_state.ref_globals` role WIDENED to hold `v128` globals (a 16-byte `BitArray` is a `Dynamic`) alongside reftype globals — seeded via `FullDecl.ref_globals`, routed by 06 to the SAME `ref_global_get`/`set` (+ `t_*`) accessors; numeric `globals` map byte-identical (D5). Doc-only in `rt_state` (the `Dynamic` map already accepts a BitArray). D3a grep-verified: NO `erlang:apply` BIF binding anywhere in `src` (link.gleam's only externals are `gleam_stdlib:identity` coercions). **DEVIATION (byte-identity, justified):** `link_imports` (the STATE positional list) stays state-only/byte-identical — the callables live in the SEPARATE `link_func_imports` vector (S5's "the instance's function-import vector"), NOT interleaved into the single `Imports` list (the doc's Deviation #2). Interleaving now would desync the driver's `provided==[]?0:1` arity dispatch + emit_core's state-only destructure from every already-instantiating `env`-fn-importing corpus module, since 06's `count_import_slots`/dispatch-vector seed isn't landed. 06 composes the two vectors when it lands. **Leaves:** the `call_import` seam + `provided_func`/`provided_func_call` + `link_func_imports` for **06** (emit the `CallImport→link.call_import` dispatch + seed the function-import vector via `count_import_slots` + route v128 global access to the boxed accessor); the full-pipeline cross-module `linking.wast` e2e run for **06/10**; the register-seam live-handle/`route`-FFI wiring + `env.providers` flip for **10**. Threaded cross-instance record-threading + imported-mutable-STATE aliasing stay categorized deferrals (§F.2). |
| **P6-10** conformance expansion | [`10`](phase-6/10-conformance-expansion.md) | **done** | 03–09 | **GREEN: 1483 tests (was 1479, +4: `simd_conformance_test`/`residual_audit_test`/`wat_route_test`×2), 0 warnings, format-clean.** **MEASURED headline (R16/S11) — the largest conformance movement in the project:** the 59 `simd_*.wast` files lit up, so the pinned suite's `pass` **rose +25004 (21525→46529)** under BOTH profiles (Safe/Unsafe identical — conformance-neutral), `fail == 0`, `skip = 1768`. SIMD alone: **25004 pass / 511 skip / 0 fail** (24281 binary `assert_return` + 54 SIMD-memory OOB `assert_trap` all PASS; the 511 skips are SIMD **text-format** `assert_malformed`/`assert_invalid` — SIMD text is out of scope for the WAT parser, S13, categorized). SIMD-memory files run **fail=0 under all 5 shipped tier combos** (cell/threaded×paged 8180, ×atomics 8146, cell×nif 8180). **v128 harness (S14/M3):** `fixture.V128Val(lane, lanes)` + the lane codec (`v128_pack`/`unpack`/`bytes_le`); the v128 rides the term invoke-ABI as **16 raw little-endian bytes**; the oracle judges **lane-wise** (integer lanes bit-exact; float lanes by bit-equality OR NaN-class — both `nan:canonical` & `nan:arithmetic` accept the canonical NaN rt_simd produces). **BUG FOUND + FIXED (integration proof):** `rt_mem_atomics`/`rt_mem_nif` were MISSING the v128-memory `load_bytes`/`store_bytes` seam P6-08 added only to `rt_mem` (paged) — so SIMD-memory files trapped `undef` under the atomics/nif tiers. Added the byte seam (atomics: `gather_bytes`/`write_data_loop` + `in_bounds`, trap-before-write; nif: delegates to `rt_mem`), so SIMD-memory now runs under EVERY tier (§G.1). Spec cite: WebAssembly SIMD memory instructions route through the bounds-checked mem seam → `MemoryOutOfBounds`. **Cross-module `(register)` flip (S5):** `runner.provider_from_instance` publishes a registered instance's exported FUNCTIONS as `link.ProvidedFunc` routing-closure capabilities (dispatch into the exporting instance's owning process via the term run-ABI, trap-propagating; D3a — a handed-in capability); the `Register` handler (runner + wat_fixture) flips `env.providers`; the driver weaves `link_func_imports` into the positional `Imports` (matching emit_core's `needs_func_imports` arity EXACTLY) only when every function import resolves to a real provider (spectest/registered) — a generic `env`/`wasi` host import under deny-all stays fail-closed at link, keeping the Phase-1..5 corpus (`hostimport`) + Safe≡Unsafe byte-identical. **Empirical residual audit (S11) — the honest measured composition:** `residual_audit_test` buckets every residual skip by `(file, cause)`; multi-table `call_indirect` = **0** (GONE — landed aa89228); `table_copy.wast` = **569 pass / 1080 skip** (its verifier inits `elem` segments with `ref.func` of IMPORTED functions + `call_indirect` — a DEEPER cross-module funcref-in-elem feature than the `CallImport` direct dispatch landed; categorized-deferred — resolves the impossible "1649 flip", S11); SIMD text-format = 511; rest = GC reftypes / assert_exhaustion / etc. ALL categorized (D9). **WAT route (§E, un-`wast2json`-able files) — FLAGGED BLOCKER, categorized honestly (never faked):** `memory64.wast` + `linking.wast` route through `wat.parse_script` (`run_wat_text`), but MEASURED at the pin the P5-10 WAT parser aborts the whole script on their out-of-scope constructs — memory64: `(module definition)` (module-linking) + the 2⁴⁸ hex-with-underscore literal + the `(memory i64 (data …))` inline-data form that EVERY memory64 `assert_return` uses; linking: interleaved GC `(ref null func)` typed-ref globals — so both are **named file-level categorized parse-skips** (Open Q #2; a WAT-parser extension is P6-02/03 territory, not P6-10), `fail == 0`, no false green. The `(register)` flip is landed + correct and lights up whenever a cross-module-function `.wast` becomes parseable. **wasmtime differential (§F):** not extended this unit (the baked `.wast` values are the primary Tier-A oracle + the existing `wasmtime.gleam` guard stands); the SIMD binary asserts are the differential (spec-baked). **Deviations:** memory64/linking are categorized WAT-parser blockers (measured, flagged); table_copy's 1080 cross-module funcref-elem is a categorized-deferred deeper feature (not the promised flip). ALLOWLIST extended (59 SIMD files); vendor.sh copies the two WAT-route targets. Only src touched: `rt_mem_atomics.gleam`/`rt_mem_nif.gleam` (the P6-08 v128-memory byte-seam gap — a genuine bug fix, spec-cited). |
| **P6-11** capstone | [`11`](phase-6/11-capstone.md) | **done** | all above | **PHASE 6 PROVEN. 1491 tests (was 1483, +8), 0 warnings, format clean, conformance `fail == 0`.** WASM-2.0 complete green: measured **46529/1768/0** (Safe **and** Unsafe, `pass` +25004 over the 21525 Phase-5 close — the 59 `simd_*.wast` files), `fail == 0` under all 5 shipped tier combos. Five capstone-authored backstops in `new_surface_test.gleam` — the SIMD kernels `simddot`/`simdxform`/`simdmem` (integer/float/memory lanes, scalar-observable, spec-correct + byte-identical across safe/unsafe/portable, cross-checked vs wasmtime), the `mem64` runtime program (i64 addressing past 2³², page-cap grow→−1, OOB trap, byte-identical across cell/threaded/unsafe with the fuel meter raised clear of the 65537-page grow — orthogonal to memory64 correctness, the P6-06 precedent), the cross-module `xlink.wast` (module B calls A's exports across instances + fail-closed `assert_unlinkable`, identical report under all three profiles), and the Phase-1..5 corpus mode-neutrality. `runs_anywhere_test.gleam` extended (the SIMD+mem64 surface: portable `.core` 0 native + 0 instance-cell seam, `rt_simd`/`rt_state`/`rt_mem` non-vacuous, executed byte-identical to the cell/paged oracle). `docs/wasm-conformance.svg` regenerated (46529/1768/0, Phase-6 footnote) + `docs/phase-6-surface.md` (measured before/after + categorized residual + the three honest scope-limits). Confirmed green (not re-derived): P6-10 skipcount/residual-audit/simd-conformance, P6-08 mem64 oracle, P6-06 emit byte-identity + D3a. The official `memory64.wast`/`linking.wast` stay categorized parse-skips (S13 — tooling/WAT-text, NOT a runtime gap); memory64 + cross-module proven by the authored in-scope backstops (the P5-12 precedent). **Honest close (S12):** the complete WebAssembly 2.0 surface; emulated SIMD (no hardware/speed claim); documented mem64 page cap; post-2.0 proposals (tail-call/GC/EH/stack-switching/component-model/relaxed-SIMD) categorized-deferred. **Phase 7 (JS on the BEAM via Porffor) UNBLOCKED.** One test-file maintenance edit outside the owned set: `wat_test.differential_acceptance_corpus_test` now skips the SIMD/mem64 corpus kernels (out of scope for the WAT parser, S13) — the binary path proves them e2e. |

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

## Phase 7 — "JS on the BEAM via Porffor" (WASM exception handling + the Porffor-ABI shim + a JS harness)

Goal & honest scope: see [`specs/phase-7/00-overview.md`](phase-7/00-overview.md) (decisions **J1–J8**),
the MEASURED [`specs/phase-7/PORFFOR-ABI-FINDINGS.md`](phase-7/PORFFOR-ABI-FINDINGS.md), and the
AUTHORITATIVE [`specs/phase-7/RECONCILIATION.md`](phase-7/RECONCILIATION.md) (decisions **T1–T14** —
override the unit docs on conflict). Phases 1–6 built the **complete WASM 2.0 engine**; Phase 7 reaches
the platform's stated goal (high-level §8.2): *any Porffor-compilable JS program runs via 2core on the
BEAM*. EM homework **measured** real Porffor 0.61.13 output: everything it emits, 2core already runs
after Phase 6 (multi-value, call_indirect/funcref, bulk memory, **v128/SIMD**) — **except WASM
exception handling** (Porffor throws pervasively; JS `try/catch` → the **legacy** `try`/`catch` block
form). So Phase 7 = **WASM exception handling** (→ BEAM-native `try`/`catch`/`throw`, the compile-to-
Erlang elegance — inline-handler IR mapping legacy 1:1, modern via transfer, Core Erlang 1:1, T1) +
the **Porffor-ABI `rt_host` shim** (its four `""`-module intrinsics a/b/c/d + the `(f64,i32)` typed-
value ABI, T11) + a **JS-subset conformance harness** (Porffor → 2core → BEAM, differential vs `porf
run`, T13), bounded by Porffor's ~⅓-ECMA coverage. Plan authored + adversarially critiqued (3 lenses,
**7 blockers + 10 majors** caught) + reconciled (T1–T14).

### Phase-7 freeze milestones (planned)

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«EH-IR-FROZEN»` — `ir.gleam` `Module.tags`/`TagDecl(name,params)` + the **inline-handler** `Try(result,body,handlers)`/`CatchHandler(on,payload,exnref,handler)` + `Throw(tag:String,args)`/`ThrowRef` + `TExnRef`/`RefType.ExnRef` (T1/T9); `ImportTag`/`ExportTag`; no new TrapReason (T8) | P7-01 | **done** (landed by P7-01) | 02,03,05,06,07,09 |
| `«RT-EXN-SIG»` — `runtime/rt_exn.gleam` heads (`throw_exn`/`match_tag`/`is_wasm_exn`/`reraise`/`capture_exnref`/`throw_ref`/`is_exnref`, T3), todo-free `panic` placeholders | P7-01 | **done** (landed by P7-01) | 06,07 |
| `«BEAM-EXN-LOWERING»` — the `{wasm_exn,TagId,Payload}` 3-tuple term (Cell-only, T6) + `Try`→Core Erlang `try…of…catch` via the helper-call chokepoint (T7) + `RunResult.UncaughtException` (T8) + the `CTry` Core-AST node (owner P7-06, T5) | P7-01/06 | **prose frozen by P7-01** (`CTry`/codegen → P7-06) | 06,07,09 |
| `«PORFFOR-ABI»` — the four intrinsics a/b/c/d + the `(f64,i32)` value ABI + entry `"m"`/mem `"$"`/tags `"0"…` + `porf run` oracle (T10–T13) | P7-01/08 | **done** (impl landed by P7-08 — `rt_host` shim + `porffor_abi` + `profiles.porffor()` + `pipeline.run_porffor`; EH-free JS e2e proven byte-identical to `porf run`) | 08,09 |
| `«WASM-AST5»` — `frontend/wasm/ast.gleam` (`Tag(type_idx)`, `ImportTag`, `Throw(tag:Int)`, `Catch`, legacy + modern EH `Instr`s, T2) | P7-03 (day 1) | **done** (published by P7-03) | 04,05 |

### Phase-7 units (all **done** — PHASE 7 PROVEN: JS ON THE BEAM via Porffor)

| Unit | Doc | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|---|
| **P7-01** Interface freeze (keystone) | [`01`](phase-7/01-interface-freeze.md) | **done** | — | Froze the EH-IR (inline-handler `Try(result,body,handlers)`/`CatchHandler(on,payload,exnref,handler)`/`CatchTag{OnTag/OnAll}`/`Throw(tag:String,args)`/`ThrowRef` + `Module.tags`/`TagDecl(name,params)`/`ImportTag`/`ExportTag` + `TExnRef`/`RefType.ExnRef`, T1/T2/T9), the `rt_exn` sig heads (T3, `panic`-placeholder, `gleam/dynamic`-only), the BEAM-lowering contract (prose; `CTry`→P7-06), and the Porffor-ABI head (prose; impl→P7-08). No new TrapReason (T8). Landed GREEN + byte-identical for tag-free modules: **1498 tests (+7 `eh_freeze_test`), 0 warnings, format clean, conformance 46529/1768/0** unchanged. **Leaves:** 02 `.ir` round-trip of the whole EH surface (incl. `Try`); 03 decode (tag section + legacy/modern opcodes); 04 validate; 05 lower (structure legacy+modern into `Try`); 06 emit (`CTry` + `try…catch` + `RunResult.UncaughtException`); 07 rt_exn bodies + `rt_ref.classify_ref` ExnRef arm; 08 Porffor shim; the emit_core/lower/printer EH arms are minimal land-green stubs (EH `emit`→`UnsupportedNode`; unreached until 05 lowers tags). |
| **P7-08** Porffor-ABI shim | [`08`](phase-7/08-porffor-shim.md) | **done** | `«PORFFOR-ABI»` | The four build-fixed intrinsics a/b/c/d (D3a literal-case: `a`=print→ECMAScript `Number::toString`, `b`=printChar→UTF-8 code unit, `c`/`d`=time/timeOrigin→deterministic `0.0`) in `rt_host`, appending to a per-instance pdict OUTPUT BUFFER drained via the `porffor_output` FFI seam; the pure `runtime/porffor_abi.gleam` `(f64,i32)` value ABI (type-tag decode → `PorfValue`, `porf_number_to_string`); `profiles.porffor()`/`js()` (Safe `HostWhitelist` of the four `""` intrinsics); `pipeline.run_porffor` (import-bearing `instantiate/1` link + invoke `"m"` + drain + decode). **PROVEN — real Porffor 0.61.13 JS runs e2e on the BEAM (T12 early headline), byte-identical to `porf run` (T13):** `console.log(42)`→`\x1b[33m42\x1b[0m\n`, `console.log("hello world")`→`hello world\n`, `console.log(Math.sqrt(16))`→`\x1b[33m4\x1b[0m\n`, `console.log(2+3*4)`→`\x1b[33m14\x1b[0m\n`, and `2+3`→decoded `PNumber(5.0)` — all EH-FREE (`wasm-tools validate` at the wasm-2.0 baseline, zero tags), so they run on the Phase-6 engine + this shim WITHOUT the EH pipeline. **1526 tests (+28), 0 warnings, format clean, conformance 46529/1768/0** unchanged. **Leaves:** 09 grows the JS corpus + owns the routed instance-memory reader (heap-typed string/object results decode) + the wider differential; the EH pipeline (03–07) extends this to `try/catch` programs; time-dependent + heap-typed results are categorized deferrals. |
| **P7-03** decode ext (+ `«WASM-AST5»`) | [`03`](phase-7/03-decode.md) | **done** | — | **Landed GREEN + byte-identical: 1572 tests (1526 baseline + 46 new EH decode tests), 0 warnings, format-clean, conformance 46529/1768/0 unchanged.** Published **`«WASM-AST5»`** in `ast.gleam`: `ValType` gains `ExnRef` (0x69, a reftype — `decode_reftype` accepts it, unlike v128; blocktype s33 −23); `Module` gains `tags: List(Tag)`; new `Tag(type_idx: Int)` (0x00 attribute checked-and-dropped); `ImportDesc` gains `ImportTag(type_idx)` (desc 0x04 0x00 typeidx); `ExportKind` gains `ExportTag` (desc 0x04); new `Catch{Catch(tag,label)|CatchRef(tag,label)|CatchAll(label)|CatchAllRef(label)}`; EH `Instr`s — modern `Throw(tag:Int)`/`ThrowRef`/`TryTable(bt,catches)`, legacy `TryLegacy(bt)`/`LegacyCatch(tag)`/`LegacyCatchAll`/`LegacyDelegate(label)`/`Rethrow(label)`; new `DecodeError` `BadTagAttribute`/`BadCatchKind`/`BadDelegate`. `decode.gleam` decodes the tag section (id 13, ranked memory(5) < TAG < global(6) via a re-expressed `section_rank`), import/export-tag (0x04), BOTH EH encodings (legacy 0x06/0x07/0x09/0x18/0x19 + modern 0x08/0x0A/0x1F + catch kinds 0x00–0x03), and 0x69→ExnRef in valtype/reftype/blocktype; `try`/`try_table` are block-openers, `delegate` a closer (depth-0 → `BadDelegate`), `throw`/`throw_ref` non-openers. VERIFIED against REAL Porffor 0.61.13 bytes (legacy `try` `06 40` / `catch` `07 00` / `throw` `08 00`, tag section `0d 03 01 00 03`, export-tag `04 00` — the full 331-byte `trycatch.js` module embedded + decoded e2e) AND wasm-tools-assembled modern fixtures (`try_table … 1f 7f 04 00 00 01 01 00 00 02 01 03 00`, `ref.null exn` `d0 69`, block-result-exnref `02 69`). Fail-closed (anti-swap catch/tag fixtures, truncation/mutation battery, the 8-opcode + 4-catch-kind audits, `BadDelegate` depth-0). Land-green fail-CLOSED arms in `validate.gleam` (all 8 EH `Instr`s → `Error(Unsupported)` BEFORE the fail-OPEN `numeric_sig` fallthrough (T2); `ExportTag` → `Unsupported`) and `lower.gleam` (`ast.ExnRef→ir.TExnRef` in `to_ir_vt`; `ImportTag`/`ExportTag` → `Unsupported`); `wat.gleam` threads `tags: []`. **Leaves for 04/05 (the AST5 shape):** `ValType.ExnRef`, `Module.tags: List(Tag)`, `Tag(type_idx)`, `ImportDesc.ImportTag(type_idx)`, `ExportKind.ExportTag`, `Catch{Catch/CatchRef/CatchAll/CatchAllRef}`, and the EH `Instr` set (modern `Throw`/`ThrowRef`/`TryTable`; legacy `TryLegacy`/`LegacyCatch`/`LegacyCatchAll`/`LegacyDelegate`/`Rethrow`) — 04 types both encodings (intercepting every EH ctor before `numeric_sig`), 05 structures legacy flat-stream + modern `try_table` into the one inline-handler `Try` IR. |
| **P7-04** validate ext | [`04`](phase-7/04-validate.md) | **done** | `«WASM-AST5»` | **Landed GREEN + byte-identical: 1607 tests (1572 baseline + 35 new EH validate tests), 0 warnings, format-clean, conformance 46529/1768/0 unchanged; AST-only (grep-asserted no `twocore/ir`).** Real EH typing for BOTH encodings, **fail-closed-COMPLETE** (T2): all 8 EH `Instr` ctors get real arms BEFORE the `numeric_sig` fail-OPEN fallthrough (grep-asserted the placeholder is gone + every arm precedes the fallthrough) — MODERN `throw x` (pop tag operands, stack-polymorphic) / `throw_ref` (pop `exnref`, polymorphic) / `try_table bt catch*` (block-like `KBlock` opener; each catch clause's target LABEL typed against the catch-type — `[t*]`/`[t* exnref]`/`[]`/`[exnref]` — resolved in the ENCLOSING label context BEFORE `push_ctrl`, §F.2); LEGACY `try`/`catch x` (handler pushes the tag operands)/`catch_all` (pushes nothing)/`delegate l` (closes the bare `try`, range-checks the delegate target)/`rethrow l` (polymorphic, label must name a catch handler) via three new `FrameKind`s `KTry`/`KCatch`/`KCatchAll` (all typed like `KBlock`, only distinguishing which region a marker may close). Tag index space (imports ++ defined) resolved at module setup with the `[t*] -> []` **empty-results** rule (`resolve_tag_type` → `BadTagType`; out-of-range typeidx → `UnknownType`); `is_reftype` gains `ExnRef` (untyped `select` of `exnref` → `BadSelectType`, `ref.is_null exnref` accepted); `ExportTag` range-checks the tag space. New `ValidateError`: `UnknownTag(index)` + `BadTagType`. **VERIFIED: the real 331-byte Porffor 0.61.13 `try/catch` module VALIDATES** (decoded + validated e2e). Tests spec-cited to the EH proposal (well-typed legacy+modern accept; tag-with-results / wrong throw operands / reversed operand order / wrong-arity or wrong-type catch label / missing-exnref catch_ref / unknown tag / out-of-range catch label / untyped-select-exnref / mis-nested delegate all REJECT). **Leaves for 05 (lower):** `TypedModule.tag_types: List(List(ast.ValType))` (operand types per tagidx, imports ++ defined, empty-results already validated away) + `imported_tag_count: Int` (the tagidx offset, imported tags precede defined) — 05 reads a tag's operands off `tag_types` (no re-derivation) and threads `imported_tag_count` for the imports-first tag space when structuring both legacy flat-stream + modern `try_table` into the one inline-handler `Try` IR. |
| **P7-05** lower ext | [`05`](phase-7/05-lower.md) | **done** | `«WASM-AST5»`, `«EH-IR»` | **Landed GREEN + byte-identical: 1625 tests (1607 baseline + 18 new EH lower tests), 0 warnings, format-clean, conformance 46529/1768/0 unchanged** (EH lowers to IR but nothing runs it yet — emit's EH arms stay `UnsupportedNode`; no result category moves). AST5 EH → the ONE inline-handler `ir.Try` (T1), structuring BOTH encodings. **Tag section → `Module.tags`:** defined `Tag(type_idx)` → `TagDecl("tag<abs>", params)` (name at absolute tagidx `imported_tag_count + i`, params from `types[type_idx].params`); imported tags → `ImportTag(module, name, params)`; `ExportTag` → `ExportTag(name, "tag<idx>")`. **`throw x` → `Throw(tagname(x), args)`** (operands popped in tag-param order, a BOTTOM transfer — dead tail consumed like `Return`); **`throw_ref` → `ThrowRef(exnref)`**; `ref.null exn` → `ConstNull(ExnRef)`, `exnref` valtype → `TExnRef` (via `to_ir_reftype`/`zero_value`). **LEGACY `try…catch…end`** structured 1:1 by SPLITTING the flat stream at the depth-0 `catch`/`catch_all`/`delegate`/`end` markers (`split_legacy_try`), then lowering body + each handler as its own block-body (synthetic `End`): `catch x H` → `CatchHandler(OnTag("tag<x>"), payload_names, None, lower(H))` (operands bound to the handler's incoming stack), `catch_all` → `CatchHandler(OnAll, [], None, …)`, `delegate` → `CatchHandler(OnAll, [], Some(e), ThrowRef(Var(e)))` (re-raise-to-enclosing), `rethrow` → `ThrowRef(Var(<innermost captured exnref>))`. **MODERN `try_table`** lowered like `block` (body under its own frame) + each catch clause → `CatchHandler(on, payload, exnref?, <transfer>)` where the transfer is `build_transfer(l, …)` over the payload (++exnref) resolved against the ENCLOSING frames → `Break`/`Continue`/`Return` by target-frame kind (resolves M4). `scan_modified`/`consume_dead`/`expr_breaks_to` extended for the EH openers/markers; `LCtx` gains `tag_types`/`catch_refs`; new `LowerError.UnknownTagIndex`. **VERIFIED: the real 331-byte Porffor 0.61.13 legacy module LOWERS** → `tags=[TagDecl("tag0",[TF64,TI32])]`, `ExportTag("0","tag0")`, an inline-handler `Try` with an `OnTag("tag0")` handler, and a `Throw("tag0",_)`. Tag-free modules byte-identical (`Module.tags=[]`, dead EH arms). **Deviations (flagged):** the SSA-locals-across-a-throw seam is resolved pragmatically (a handler runs with `locals` as of the try SITE; precise per-throw-point values → 01/06); legacy `delegate l` / `rethrow l` approximate the label `l` to the nearest-enclosing (Porffor emits neither). **Leaves for 06:** emit the `Try`/`Throw`/`ThrowRef` IR to Core Erlang `try…catch` + rt_exn (the exact legacy-vs-modern `Try` shapes are the emit contract). |
| **P7-07** rt_exn | [`07`](phase-7/07-rt-exn.md) | **done** | `«RT-EXN-SIG»` | **Landed GREEN + byte-identical: 1644 tests (1625 baseline + 19 new `rt_exn_test`), 0 warnings, format-clean, conformance 46529/1768/0 unchanged** (nothing emits `rt_exn` calls until 06). Filled the 7 frozen `rt_exn` heads over the new `twocore_rt_exn_ffi.erl` shim (Cell-only, T6): the **term `{wasm_exn, TagId, Payload}` raised ERROR class** (`erlang:error` — the SAME channel as `rt_trap`'s `{wasm_trap, Kind}`; the top-level run-ABI splits them by term shape — T8); `match_tag` = `{ok, Payload}` iff exact `TagId` (T4); **`is_wasm_exn` matches ONLY `{wasm_exn,_,_}` — FALSE for a real `rt_trap` trap term + a `FuelExhausted` raise** (the load-bearing `catch_all`≠trap invariant, T7/S8 — a trap propagates); `reraise` = `erlang:raise/3` (preserves class+reason+stack); the **reason-only forge-proof exnref box `{ref_exn, Reason}`** (T9) via `capture_exnref`(1-arg)/`throw_ref`(fresh ERROR raise of the unboxed reason; null exnref → `rt_trap.raise(Unreachable)`, PROVISIONAL reason per §G/S8, no new `TrapReason` — T8)/`is_exnref`. **rt_ref (T9):** added `RefKind.ExnRef` + the `classify_ref` `{ref_exn,_}`→`ExnRef` arm (before the by-elimination funcref arm) + a delegated `is_exnref` FFI (the one rt_ref edit; the conformance `driver.gleam` `tag_ref` gained the forced `ExnRef` arm → opaque ref, unreached in-corpus). D3a grep-proof (no `apply`/`*_to_atom`). **Leaves for 06:** emit `Try`→Core Erlang `try B of <Vs> -> <Vs> catch <C,R,S> -> H` (catches ALL classes, dispatches on term shape), lowering each catch to `match_tag`/`is_wasm_exn`/`capture_exnref` terminating in `reraise`, + the top-level `error:{wasm_exn,_,_}`→`UncaughtException` arm (T8). |
| **P7-06** emit_core ext | [`06`](phase-7/06-emit-core.md) | **done** | `«EH-IR»`,`«RT-EXN-SIG»`,`«BEAM-EXN-LOWERING»`,05,07 | **EH RUNS E2E ON THE BEAM — the Porffor `try/catch` JS program runs (JS exceptions as BEAM exceptions). Landed GREEN + byte-identical: 1663 tests (1644 baseline + 19 new), 0 warnings, format-clean, conformance 46529/1768/0 unchanged** (the EH `.wast` corpus expansion is P7-09/10). **Owns the `CTry` Core-AST node (T5):** added `core_erlang.CTry(arg, body_vars, body, evars, handler)` + the `core_printer` arm (the OTP-29-accepted `try <Arg> of <Vs> -> <Body> catch <C,R,S> -> <Handler>` — NO outer parens, NO `end`, empirically verified via `core_scan`/`core_parse`) + its D3a security-walk `children` arm. **Emit (T1/T7):** `Throw(tag,args)` → `rt_exn:throw_exn(<tag index>, [args])` (BOTTOM, resolves the NAME→module-local Int index from `Module.tags`, T4); `ThrowRef` → `rt_exn:throw_ref(exnref)`; `Try(result,body,handlers)` → a `CTry` with a TRANSPARENT `of <v> -> v` (every emitted expr is one packaged value, §C.1) whose handler dispatches a nested `case` per clause via the rt_exn CHOKEPOINT — `OnTag(t)`→`case rt_exn:match_tag(R,<t>) of {ok,[payload]} -> <handler> ; _ -> <next>`, `OnAll`→`case rt_exn:is_wasm_exn(R) of 'true' -> <handler> ; 'false' -> <next>`, the final next = `rt_exn:reraise(C,R,build_stacktrace(S))` (so traps + fuel + unmatched tags PROPAGATE, T7); `catch_ref`/`catch_all_ref` bind `capture_exnref(R)`. **Cell-only (T6):** no state threads through a throw. **`RunResult.UncaughtException(tag_id, payload)` (T8):** the run-ABI splits a `{wasm_exn,_,_}` (→ Uncaught) from a `{wasm_trap,_}` (→ Trapped). **Fix (empirical):** the try body is HOISTED into a local nullary function so the `Arg` is a single `apply` — a `case`-and-raise (trapping op) directly in a try `Arg` together with the handler's `case` else fails the BEAM validator (`ambiguous_catch_try_state`). **e2e (RUN on the BEAM):** uncaught throw → `UncaughtException(0,[16,195])` distinct from a trap; a caught legacy Porffor-shape `try/catch` recovers the payload (`f(5)=6`, `f(-2)=-1`); `catch_all` catches a wasm exn (→42) but a `MemoryOutOfBounds` trap PROPAGATES through it; a non-matching tag re-raises → `UncaughtException(1,[16])`; `throw_ref` re-raises a captured exnref caught by an enclosing `catch`; **and THE BIG ONE — a real Porffor 0.61.13 `try { throw new Error(…) } catch (e) { console.log("caught") }` runs through the full pipeline, output byte-identical to `porf run` ("caught\n") + a live differential.** D3a extended (Cell/Threaded/Unsafe): allow-set + `rt_exn`, no `erlang:*` emitted, the `children` walk descends into `CTry`. **Deviations:** `exn_module` a fixed atom (no `binding` field, like `rt_simd`); reraise rebuilds the stacktrace via `primop 'build_stacktrace'` (raw catch token → `badarg`); the transparent-`try` `br`-out-then-rethrow corner is categorized (D1, Porffor-inert). **Leaves:** P7-09 grows the JS/EH corpus + P7-10 the EH `.wast` conformance (the modern `exnref`/`throw_ref` surface is spec-only, Porffor-inert). |
| **P7-02** `.ir` printer/parser ext | [`02`](phase-7/02-ir-textual-form.md) | **done** | `«EH-IR»` | `.ir` round-trips the FULL EH-IR surface (`parse(print(m))==m`) over the FROZEN INLINE-HANDLER shape (T1): the tag decl space (`tag @name (params)` / `import "M" "n" tag (params)` / `export "n" = tag @name` — `TagDecl`/`ImportTag`/`ExportTag`), the `exnref` valtype + `ExnRef` reftype (in every valtype/reftype position — incl. exnref tables/elements) + the `null.exnref` `ConstNull(ExnRef)` value, `throw @tag (args)`, `throw_ref <value>`, and `try (results) { body } catch @tag (%p,*) [ref %e] {…} catch_all (%p,*) [ref %e] {…}` (`Try`/`CatchHandler(on,payload,exnref?,handler)`/`CatchTag{OnTag/OnAll}`). Parser was the gap (P7-01 landed the printer + `throw`/`throw_ref`): added the `try` arm + `parse_try`/`parse_catch_handlers`/`parse_catch_handler_tail`/`parse_opt_exnref`, and `exnref` arms to `parse_opt_reftype`/`parse_elem`. Total parser (EH garbage battery → typed `ParseError`, no panic; no new `ParseError` variant). New hand-authored `golden/exn.ir` + independent expected `Module` (2 tags + imported/exported tag + exnref param/result + `null.exnref` + `Throw` + a `Try` covering catch/catch_all/catch-ref/catch_all-ref + `ThrowRef`); 6 prior goldens still parse; **tag-free modules print byte-identically** (`tag_free_module_has_no_eh_token_test` + legacy goldens). Grammar reconciled: **`specs/phase-7/ir-grammar-delta.md` §A.4 rewritten to the frozen inline-handler `Try` form**. **1678 tests pass (was 1663, +15), 0 warnings, format clean, conformance 46529/1768/0 unchanged (byte-identical).** **Leaves:** none — the round-trip is a self-contained property gating nothing downstream (05/06/07 hand-author `.ir` fixtures against these §A.4 spellings). |
| **P7-09** JS-subset conformance | [`09`](phase-7/09-js-conformance.md) | **done** | 06,08 | **JS RUNS ON THE BEAM — MEASURED. 1682 tests (1678 baseline + 4 new), 0 warnings, format-clean, conformance 46529/1768/0 unchanged (byte-identical — the harness adds no `src/` code, a NEW isolated tree `test/twocore/js/**`).** A **55-program JS corpus** (11 categories: console/arith/control/functions/closures/recursion/strings/arrays/objects/booleans/trycatch), each a real `.js` compiled by **Porffor 0.61.13** to a vendored `.wasm` and run through the FULL 2core pipeline via `pipeline.run_porffor` under `profiles.porffor()`, judged DIFFERENTIALLY (byte-for-byte, ANSI in-band) against the baked `porf run` oracle (T13), cross-checked vs Node at vendor time (T12/§E). **MEASURED HEADLINE: 52 pass / 0 fail / 3 skip** — 52 real JS programs (arithmetic + precedence + Math; if/else/for/while/switch/ternary + a 1000-iter hot loop; named/arrow/default/callback functions; IIFE; fib/fact/mutual recursion; string concat/length/upper/template/charCodeAt/split/indexOf; array literals/index/map/filter/reduce/join/push/sort; object literals/property access/mutation/Object.keys; boolean/comparison/logical ops; **try/catch/throw incl. a caught value, a rethrow, a nested try, a runtime TypeError, finally, AND an uncaught top-level throw** — the EH keystone proven through the JS surface) run on the BEAM byte-identically to `porf run`; **fail == 0** (2core reproduces the wasm on EVERY program, including the 3 divergent ones). The **3 skips are all `PorfforVsNodeDivergence`** (measured Porffor BUGS, not 2core gaps — J8): `arith/negzero` (Porffor renders `-0` as `"0"`, Node `"-0"` — the T13 documented divergence), `closures/counter` (Porffor's broken lexical-closure capture → `NaN` vs Node `3`), `closures/adder` (same capture bug → `ReferenceError` vs Node `15`) — kept as DOCUMENTED, categorized skips (never deleted, DoD); 2core reproduces `porf run` byte-for-byte even on these, so they bound Porffor, not 2core. **Honest finding: Porffor 0.61.13 lexical closures that capture an enclosing var are BROKEN** (any capture throws/NaNs — measured across 6 closure variants; IIFE/global-counter/arrow-returning-constant work). Files (all new, `test/twocore/js/**`, `src/` untouched): `corpus.gleam` (the 55-program manifest — single source of truth, bakes each program's `porf run` outcome + optional `SkipCategory`), `report.gleam` (the typed coverage ledger — `Verdict`/`SkipCategory` closed enum + the printed histogram, S11/D9), `porffor.gleam` (the Porffor+Node toolchain adapter over the unowned conformance FFI, graceful-absence), `js_conformance_test.gleam` (**the headline** — Tier-A baked judge over all 55: asserts `fail == 0`, `pass > 0`, no silent drop `pass+fail+skip==total`; + a category-anchored keystone test), `js_differential_test.gleam` (the LIVE Tier-B — re-confirms `beam == porf run` + the porf-vs-node categorization over a breadth-spanning sample, guarded by `available()`, fits the per-test time budget), `corpus/**/*.{js,wasm,expected}` (vendored), `vendor.sh` + `PIN` (`PORFFOR_VERSION=0.61.13`/`NODE_MAJOR=22`). **Deviations (flagged):** the live differential runs a representative 6-program SAMPLE (not all 55 live) — each `npx porffor` shell-out is ~0.56s and 55 exceed the ~5s eunit per-test timeout; the baked Tier-A judges all 55 (§H.3). The two-profile (Safe/Unsafe) optimizer-soundness roll-up (§H.1) is deferred — `run_porffor` hardwires `profiles.porffor()` and the unit adds no `src/` code; a `run_porffor_with(binding)` seam is P7-08/10 territory. Heap-typed `(f64,i32)` value decode stays deferred (judged via `console.log`, §G). **Leaves:** P7-10 quotes this measured 52/0/3 for the honest close + SVG/docs. |
| **P7-10** capstone | [`10`](phase-7/10-capstone.md) | **done** | all above | **PHASE 7 PROVEN — JS ON THE BEAM via Porffor. 1690 tests (was 1682, +8), 0 warnings, format clean, main conformance `fail == 0` (46529/1768/0 — BYTE-IDENTICAL, EH driven separately).** **Proof 1 (EH engine, MEASURED):** authored `eh_conformance_test.gleam` drives the OFFICIAL WebAssembly EH `.wast` suite — empirically **4 of 8 convert at the pin** (`wast2json --enable-exceptions`): `throw`/`throw_ref` (modern) + `legacy/throw`/`legacy/rethrow` (the encoding Porffor emits) → **153 asserts pass / 0 skip / 0 fail across safe/unsafe/portable**, BOTH encodings through the one neutral IR; the 4 non-convertible (`tag`=`(rec)` GC, `try_table`=tail-call+`exn`-heaptype, `legacy/try_catch`+`legacy/try_delegate`=tail-call) categorized as Phase-8 features (NOT an EH gap). **Lighting up the modern files SURFACED + FIXED a real optimizer soundness bug:** the Baseline `block-label-simplify` `breaks_to`/`continues_to` scan did not descend into `Try` catch handlers, so it eliminated a block broken to ONLY from a modern `try_table`→enclosing-label transfer → dangling `Break` → `emit: UnboundLabel`; fixed (mirrors `lower`'s `expr_breaks_to`), regression-guarded fixture-independently in `baseline_test.gleam` (fails without the fix). **Proof 1 (fine-grained):** 5 authored EH backstop kernels in `new_surface_test.gleam` (`ehthrow` legacy · `ehcatch` modern try_table→label · `ehcatchall` catch_all+no-match-propagate · `ehnested` innermost-matching unwind · `ehrethrow` exnref/throw_ref), scalar-observable, differential vs wasmtime 46.0.1, byte-identical across safe/unsafe/portable. **Proof 2 (THE HEADLINE):** confirmed P7-09's measured **52 pass / 0 fail / 3 skip** (real Porffor 0.61.13 JS → 2core → BEAM, byte-identical to `porf run`) + the EH-through-JS proof (a real Porffor `try/catch` → `"caught\n"`). **Proof 3 (neutral):** main suite 46529/1768/0 BYTE-IDENTICAL (EH `.wast` in a `fixtures/eh/` subdir the main glob doesn't see). **Proof 4 (tier matrix):** `tier_matrix_eh_test.gleam` — the EH backstop byte-identical across `combos.shipped` (all 5 combos); EH is tier-invariant (a throw unwinds the native stack). **Proof 5 (runs-anywhere):** `runs_anywhere_test.gleam` extended — EH under `portable` links ZERO native, names `rt_exn`/`try` non-vacuously, executes byte-identical to the cell/paged oracle. **Measured tier nuance (sharpens T6):** the state-FREE EH surface runs byte-identically under Cell AND Threaded (153/0/0 × 3 profiles); the T6 Cell-only bound is retained only for state-threaded-THROUGH-a-throw (which the backstop + JS path do not exercise). **Docs:** authored `docs/js-on-the-beam.md` (the JS-on-BEAM story + measured coverage + honest scope + the pipeline + one line per proof); `docs/wasm-conformance.svg` footnote → Phase-7 EH+JS (main numbers unchanged). `runner.gleam`/`fixture.gleam` gained `assert_exception` support (T8 — a `{wasm_exn,…}` outcome ≠ a trap); `vendor.sh` gained an EH section; `wat_test` out-of-scope filter + `.gitignore` extended for `eh*`. **Honest close (T14):** JS on the BEAM reached — real JS (the Porffor-compilable subset) runs as compiled preemptive BEAM code with JS exceptions as BEAM exceptions, bounded by Porffor's ~⅓-ECMA (MEASURED, the 3 skips are Porffor's own -0/closure bugs); EH is BEAM-native + faithful; the modern exnref/throw_ref surface is spec-conformance-only (Porffor-inert); no WASI/DOM. **Phase 8+:** a native JS frontend (broader than Porffor, reusing this phase's generic EH IR), the tail-call proposal (unblocks the 4 EH files), GC, the Erlang/Gleam frontend, stack-switching/component-model, B1, tier-N, the memory optimizer. |

### High-level spec coverage this phase takes

| High-level item | Taken by | Notes |
|---|---|---|
| §8.2 JS on the BEAM via Porffor (the GOAL) | P7-08/09/10 | the Porffor-ABI shim + the JS harness; *any Porffor-compilable JS runs on the BEAM*. |
| WASM exception handling (proposal) | P7-01/03/04/05/06/07 | legacy + modern EH → BEAM-native try/catch/throw (Cell); the modern surface spec-conformance-only. |
| §9.2 compiled + preemptive JS | P7-06/07 | JS reaches the BEAM as compiled Core Erlang; native exception unwinding; preemption preserved. |

### Deferred to Phase 8+ (explicit)

A **native** JS frontend (Porffor is the JS frontend); a broader-than-Porffor JS surface; GC-proposal
reftypes (Porffor doesn't need them); the Erlang/Gleam frontend; Threaded+EH; cross-module tags;
heap-typed run results; stack-switching / the component model; the single-`.beam` **B1** binding;
tier-N; the memory optimizer; WASI as an `rt_host` impl.

---

## Phase 9 — "The Memory Optimizer" (MemorySSA + alias-aware load/store rewriting)

Goal & honest scope: see [`specs/phase-9/00-overview.md`](phase-9/00-overview.md) (decisions
**M1–M8**) — the realization of the design note
[`specs/future-work-memory-optimizer.md`](future-work-memory-optimizer.md) (the "memory optimizer"
deferred all the way back in Phase 3). A **middle-end (`ir_opt`) SPEED phase** attacking the
post-Phase-4 memory-access **residual** (fetch handle → bounds-compare+branch → O(1) access →
decode). It adds a **MemorySSA + linear-memory alias analysis** and three alias-aware rewrites —
**store→load forwarding**, **redundant-load elimination**, **dead-store elimination** — each
**trap-preserving** (the WASM load/store is *trap-or-access*, M3) and therefore **trust-neutral**:
they run at **`Baseline`** (Safe), so — because `ir_opt` sits upstream of tier + mode selection —
**every tier (`paged`/`atomics`/`nif`) and both modes (Safe/Unsafe) win**, and every present/future
frontend inherits them. **No new IR node types, no runtime touch** (M4): the passes only *remove* a
`MemStore` (DSE) or *replace* a `MemLoad` with an already-bound `Value` (forwarding/RLE), so the
phase is **result-identical** on the whole corpus (an optimized module legitimately has *fewer*
accesses). Baseline entering Phase 9: **1734 tests, 0 failures, 0 warnings**.

### Phase-9 freeze milestone

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«MEM-SSA-FROZEN»` — `middle/ir_opt/mem_ssa.gleam` (`Footprint` + `AliasResult` + `alias/2` + `is_memory_barrier/1` + `Avail` + `byte_width/1` + `count_mem_ops/1`; imports `ir` + `ir/effect` ONLY → no cycle) | P9-01 | **FROZEN ✓** | 02, 03, 04 |

### Phase-9 units

| Unit | Doc | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|---|
| **P9-01** MemorySSA + alias keystone | [`01`](phase-9/01-mem-ssa-keystone.md) | **done** | — | The frozen analysis surface (`mem_ssa.gleam`) + adversarial alias/barrier/truncation-guard fixtures. Lands GREEN with the pipeline STILL EMPTY (identity — corpus byte-identical). `alias` defaults `MayAlias`; `is_memory_barrier` defaults `True` (forgets memory on a call/grow/bulk/control/region-head; transparent for `MemLoad`/`MemStore`/`MemSize`/`Global*`/`Charge`/pure); `byte_width` rejects sub-width/truncating footprints; `count_mem_ops` = the `n_mem` measure. **Landed GREEN: 1752 tests (was 1734), 0 warnings, format clean, WASM byte-identical.** |
| **P9-02** store→load forward + RLE | [`02`](phase-9/02-store-load-forward.md) | **done** | `«MEM-SSA-FROZEN»` | `mem_forward.gleam` — **one** unified pass `forwarding_pass()` (a scope-aware region walk threading `avail`) realizing both store→load forwarding AND redundant-load elimination (a load is served from `avail` whether the entry came from a store or a prior load); the name→`ValType` env feeds the truncation guard (`store_writes_full_value`: width 8/16 always full, 1/2 always truncating, width 4 disambiguated by value type — excludes `i64.store32`). A store invalidates only ALIASING `avail` keys (disjoint offsets survive); a barrier clears the map; resets at every control-flow boundary. **Landed GREEN: 1766 tests (was 1752), 0 warnings, format clean, WASM byte-identical.** Adversarial fixtures (aliasing store / CallHost / MemGrow barrier / sub-width load / truncating-or-unknown store source / control boundary) + end-to-end BEAM value/trap preservation. NOT yet wired (corpus byte-identical). |
| **P9-03** dead-store elimination | [`03`](phase-9/03-dead-store-elim.md) | **done** | `«MEM-SSA-FROZEN»` | `mem_dse.gleam` — one pass `dead_store_pass()` (a look-ahead peephole: drop a store shadowed by a `MustAlias` later store with **only `ir/effect.is_pure` nodes between** — so a load or any barrier stops the peel, meaning DSE needs only `footprint_of`/`alias` from the keystone). The paged-tier headline (each eliminated store elides an O(page) rebuild). **Landed GREEN: 1776 tests (was 1766), 0 warnings, format clean, WASM byte-identical.** Adversarial fixtures (load between / MemGrow+CallHost barrier / MayAlias+NoAlias later store) + end-to-end BEAM value/trap preservation. NOT yet wired (corpus byte-identical). |
| **P9-04** wire pipeline + benchmark (capstone) | [`04`](phase-9/04-capstone.md) | **done** | 01, 02, 03 | **PHASE 9 PROVEN.** `ir_opt.pipeline/1` (the ONE registration point) now returns `baseline ++ memory_passes` for `Baseline` and `baseline ++ memory_passes ++ aggressive` for `Aggressive` (memory-before-aggressive keeps the superset; the fixpoint re-runs baseline so copy-prop cleans the forwarding rebindings + the memory passes re-sweep after inlining). **The whole Phase-1…8 corpus + WASM spec suite (`fail = 0`, 46 529 asserts) + tier matrix stay result-identical under both profiles and every `(state_strategy × mem_tier)` combo** (differential_test / tier-matrix, GREEN with the passes live — the memory passes changed no observable result). `count_mem_ops` monotonicity + convergence asserted. **Measured: ~3–4× faster on paged** (baseline-only ≈ 1.4 µs/iter → ≈ 0.38 µs/iter on a store-churn loop, correctness-gated) + the deterministic elimination-count metric (churn kernel 6→2, exactly 4 mem-ops removed). `docs/phase-9-benchmark.md` (honest, pattern-dependent ceiling). **1783 tests, 0 warnings, format clean.** |

### High-level spec coverage this phase takes

| High-level item | Taken by | Notes |
|---|---|---|
| §4 M2 optimizer (`ir_opt`) — memory dataflow | P9-01/02/03/04 | The Phase-3-deferred memory-dependence passes: MemorySSA-lite (forwarding/RLE) + DSE, trust-neutral (run in Safe), no LICM / standalone-BCE / cross-control-flow (§6 deferred). |
| §10 tier ladder speedup | P9-04 | One sound IR pass speeds up `paged`/`atomics`/`nif` + `cell`/`threaded` (runs upstream of tier selection); DSE disproportionately closes the `paged`/`portable` gap. |

### Deferred to a later phase (explicit)

Standalone range-based **bounds-check elimination** (needs an unchecked-access IR form + `rt_mem`
entry points); **LICM** of the loop-invariant handle fetch (needs the handle exposed as an IR
value); **MemorySSA across control flow** (Phase 9 is per straight-line region — resets at every
`If`/`Switch`/`Loop`/`Block`/`Try`); **escape analysis** for the term/object value path (object
speed, not linear-memory speed — the Phase-8 value layer's future speed unit). **→ The first three
(the linear-memory items) are Phase 10.**

---

## Phase 10 — The Memory Optimizer, completed (LICM + cross-CF MemorySSA + range-based BCE)

Goal & honest scope: see [`specs/phase-10/00-overview.md`](phase-10/00-overview.md) (decisions
**N1–N8**) — the direct sequel to Phase 9, building the three linear-memory optimizations Phase 9
deferred. **LICM** (hoist pure loop-invariant work — incl. invariant address arithmetic — to a
preheader) and **cross-control-flow MemorySSA** (let forwarding/RLE/DSE survive an `If`/`Block`/
`Switch` when no branch clobbers, via a may-clobber analysis) are **pure IR→IR**, trust-neutral,
all-tiers/both-modes (Phase-9 discipline). **Range-based BCE** is the first memory optimization since
Phase 4 to grow the runtime ABI (an *unchecked* memory access), made **sound + trust-neutral by loop
versioning** — a runtime range-guard picks the unchecked fast loop **only when it has proven the
whole range in-bounds**, else the original checked loop, so values **and traps** are exactly
preserved (N4). Baseline entering Phase 10: **1783 tests, 0 failures, 0 warnings**.

### Phase-10 freeze milestone

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«MEM10-FROZEN»` — `loop_analysis` (free-vars/invariance) + `mem_clobber` (may-clobber/may-write) leaf modules + the additive `MemLoadUnchecked`/`MemStoreUnchecked` IR nodes (ir/printer/parser/effect/mem_ssa/emit — **freeze-safe: lower like the checked nodes**) + the `rt_mem`/`rt_mem_atomics` unchecked signatures | P10-01 | **FROZEN ✓** | 02–07 |

### Phase-10 units

| Unit | Doc | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|---|
| **P10-01** Keystone | [`01`](phase-10/01-keystone.md) | **done** | — | `loop_analysis.gleam` (`free_vars`/`is_loop_invariant`/`bound_names`) + `mem_clobber.gleam` (`may_clobber`/`may_write_memory`) leaf modules; the additive `MemLoadUnchecked`/`MemStoreUnchecked` nodes wired freeze-safe across ir/printer/parser/effect/mem_ssa/pass/baseline/aggressive/ir_lower/emit_core (lower via the checked path → corpus byte-identical). **Landed GREEN: 1794 tests (was 1783), 0 warnings, format clean, conformance fail=0 (46529 byte-identical).** |
| **P10-02** LICM | [`02`](phase-10/02-licm.md) | **done** | `«MEM10-FROZEN»` | `licm.gleam` `licm_pass()` — hoist pure loop-invariant `Let`s to a preheader (moving-frontier drain; DESCENDS into `If`/`Switch`/`Block`/`Charge` since WASM-lowered loops put invariant work inside the condition-guarded branch; nested `Loop`/`Try` opaque). Pure IR, no pipeline edit (corpus byte-identical). **Landed GREEN: 1800 tests, 0 warnings.** |
| **P10-03** cross-CF MemorySSA | [`03`](phase-10/03-cross-cf-memoryssa.md) | **done** | `«MEM10-FROZEN»` | cross-CF edits to `mem_forward.gleam` (keep `avail[f]` across a single-execution `If`/`Block`/`Switch` when `!may_clobber(child,f)` on every branch, AND thread `avail` INTO the branches; `Loop`/`Try` stay barriers) + honest DSE scope (Phase-9 `is_pure` already looks through pure CF). Since `forwarding_pass` is already wired (Phase 9), this is LIVE — corpus byte-identical (fail=0). Updated the Phase-9 `no_forward_across_control_flow_boundary_test` (limit lifted). **Landed GREEN: 1807 tests.** |
| **P10-04** rt_mem unchecked | [`04`](phase-10/04-rt-mem-unchecked.md) | **done** | `«MEM10-FROZEN»` | `load_unchecked`/`store_unchecked` (+ `t_*` twins + `mem_/a_*_unchecked` cores) on `rt_mem` (paged) + `rt_mem_atomics` (atomics), each the checked op MINUS `in_bounds`; BEAM-safe on OOB (paged read_bytes=contained zeros, atomics gather/scatter=ERTS-checked `atomics:get/put`); nif excluded. Differential vs the checked oracle across width/sign/addr. **Landed GREEN: 1810 tests.** |
| **P10-05** emit unchecked | [`05`](phase-10/05-emit-unchecked.md) | **done** | 01, 04 | Flip `emit_core`'s unchecked-node lowering to the unchecked entry points on paged/atomics via a fail-closed `mem_module` name whitelist (`mem_supports_unchecked`, G5-clean); checked fallback for nif / `mem>0`. Fixed `expr_touches_state` to list the unchecked nodes (a Threaded unchecked-only fn now threads `St`). Conformance-neutral (fail=0). **Landed GREEN: 1815 tests.** |
| **P10-06** range-BCE | [`06`](phase-10/06-range-bce.md) | **done** | 01, 05, `loop_analysis` | `bce.gleam` `bce_pass()` — recognize the single-affine-cursor loop (`addr=Var(i)`, i a param, bound invariant, no grow/call), synthesize a pure i64 (overflow-safe) range guard, emit loop versioning (`if guard { unchecked fast } else { checked slow }`). Idempotent — guard vars keyed on the unique loop label (`$bce$…`), and a `$bce$` cond marks an already-versioned `If` the walk won't re-version. **Landed GREEN: 1822 tests** (recognition + in-bounds value + OOB trap + adversarial + idempotence). |
| **P10-07** capstone | [`07`](phase-10/07-capstone.md) | **done** | 02, 03, 06 | **PHASE 10 PROVEN.** Wired `[forwarding_pass, dead_store_pass, licm_pass, bce_pass]` into `ir_opt.pipeline` `Baseline` (inherited by `Aggressive`). **The whole Phase-1…9 corpus + WASM spec suite (fail=0, 46 529 asserts) + tier matrix stay result-identical under both profiles and every combo** with LICM + cross-CF + BCE live. LICM + BCE proven to FIRE through the full pipeline + fixpoint convergence (BCE node-adding but idempotent). **Measured: LICM ~3.5× faster** (invariant-chain loop, 39→11 ns/iter); **BCE ~1.1× on paged** (honest — the binary slice dominates; atomics is where the check matters). `docs/phase-10-benchmark.md`. **1827 tests, 0 warnings, format clean.** |

### High-level spec coverage this phase takes

| High-level item | Taken by | Notes |
|---|---|---|
| §4 M2 optimizer — loop optimizations + BCE | P10-02/06 | LICM + range-based bounds-check elimination (loop versioning), the Phase-9-deferred loop work. |
| §4 M2 optimizer — cross-block MemorySSA | P10-03 | forwarding/RLE survive control flow via a may-clobber analysis. |
| §10 tier ladder speedup | P10-04/05/06 | the unchecked runtime path (paged/atomics) + BCE — the bounds-check residual, largest on atomics. |

### Deferred to a later phase (explicit)

**Escape analysis** for the term/object value path (object speed, not linear memory — a future phase
gated on a frontend emitting object-heavy code); a general (polyhedral) **range solver** (Phase-10
BCE is single-affine-IV); nested/multi-dimensional BCE; **tier-N unchecked native** access (nif stays
checked; a real C NIF for tier-N is itself a Phase-4 deferral).

---

## Change log

- **P7-10 landed (capstone) — PHASE 7 PROVEN: JS ON THE BEAM via Porffor.** The platform reaches the
  goal it was always for: a real, Porffor-compiled JavaScript program runs through 2core (Porffor
  JS→WASM → `fe_wasm` → IR → Core Erlang → BEAM) and produces output **byte-identical to Porffor's own
  execution** (`porf run`), as **compiled, preemptive BEAM code**, with **JS exceptions as BEAM
  exceptions**. **1690 tests (was 1682, +8), 0 warnings, format clean; main conformance
  46529/1768/0 — BYTE-IDENTICAL** (proof 3 — the EH `.wast` are driven separately, so the Phase-1..6
  headline does not move).
  - **Proof 2 — JS on the BEAM (THE HEADLINE, MEASURED):** confirmed P7-09's **52 pass / 0 fail / 3
    skip** over a 55-program, 11-category JS corpus (arithmetic, control flow, functions/closures,
    recursion, strings, arrays, objects, booleans, `try/catch`) — every program byte-identical to
    `porf run`, `fail == 0`. The 3 skips are measured **Porffor** bugs (a `-0`→`"0"` render + broken
    lexical-closure capture), never 2core gaps. Plus the EH-through-JS proof: a real Porffor
    `try { throw new Error(…) } catch { console.log("caught") }` → `"caught\n"`.
  - **Proof 1 — EH engine spec-correct (MEASURED, both encodings):** authored
    `eh_conformance_test.gleam` drives the OFFICIAL WebAssembly EH `.wast` suite. Empirically **4 of the
    8 official files convert at the pin** (`wast2json --enable-exceptions`): `throw`/`throw_ref`
    (modern) + `legacy/throw`/`legacy/rethrow` (the encoding Porffor emits) → **153 asserts pass / 0
    skip / 0 fail across safe/unsafe/portable**, exercising BOTH encodings through the one neutral IR.
    The 4 non-convertible (`tag`, `try_table`, `legacy/try_catch`, `legacy/try_delegate`) are blocked
    by GC recursive types / the `exn` heap type / the tail-call proposal — categorized Phase-8
    features, NOT an EH gap. Backstopped by 5 deliberately-authored EH kernels in `new_surface_test`
    (differential vs wasmtime 46.0.1) across the mode axis, `tier_matrix_eh_test` across the tier axis,
    and `runs_anywhere_test` under `portable` (0 native, `rt_exn` non-vacuous, executed).
  - **A real optimizer soundness bug found + fixed by the EH `.wast` run:** the Baseline
    `block-label-simplify` `breaks_to`/`continues_to` scan did not descend into `Try` catch handlers,
    so it eliminated a block broken to only from a modern `try_table`→enclosing-label transfer → a
    dangling `Break` → `emit: UnboundLabel`. Fixed (mirroring `lower`'s `expr_breaks_to`), with a
    fixture-independent regression guard in `baseline_test.gleam` (fails without the fix). This is the
    only `src/` change — the capstone otherwise confirms, it does not re-derive.
  - **Measured tier nuance (sharpens T6):** the state-FREE EH surface runs byte-identically under Cell
    AND Threaded (`portable`) — 153/0/0 × 3 profiles. The T6 **Cell-only** bound is retained only for
    the state-threaded-THROUGH-a-throw combination (a program mutating threaded instance state across a
    throw/catch), which neither the official `.wast` nor the JS/Porffor path (Cell) exercises. So
    runs-anywhere holds for the EH surface, and transitively the JS surface.
  - **Docs + infra:** authored `docs/js-on-the-beam.md` (the JS-on-BEAM story, measured coverage, the
    pipeline, the honest scope, one line per proof → the test that proves it); updated
    `docs/wasm-conformance.svg` footnote to Phase-7 EH+JS (main numbers unchanged). Extended the shared
    spec-suite runner with `assert_exception` support (T8 — a `{wasm_exn,…}` outcome distinct from a
    trap), `vendor.sh` with an EH section (into `fixtures/eh/`), `wat_test`'s out-of-scope filter +
    `.gitignore` for `eh*`.
  - **Honest close (T14):** JS on the BEAM reached — real JS (the **Porffor-compilable subset**,
    MEASURED, bounded by Porffor's ~⅓-of-ECMA coverage — never "full JS") runs as compiled, preemptive
    BEAM code with JS exceptions as BEAM exceptions. EH is **BEAM-native + faithful** (native
    try/catch/raise, not emulated); the modern exnref/throw_ref surface is spec-conformance-only
    (Porffor-inert). No WASI, no DOM. **Phase 8+:** a **native JS frontend** (broader than Porffor,
    reusing this phase's generic structured-exception IR), the **tail-call proposal** (which unblocks
    the 4 remaining official EH files), GC-proposal reftypes, the Erlang/Gleam frontend,
    stack-switching / the component model, the single-`.beam` B1 binding, tier-N, the memory optimizer.
    WASI stays an `rt_host` impl, out of core.

- **Phase-7 plan authored + adversarially critiqued + reconciled.** Scope decision (EM): **Phase 7 =
  "JS on the BEAM via Porffor"** (the high-level goal, §8.2). EM homework MEASURED real Porffor 0.61.13
  output — its ONLY missing WASM feature is exception handling (everything else runs after Phase 6). So
  Phase 7 = **WASM exception handling** (→ BEAM-native try/catch/throw) + the **Porffor-ABI shim** + a
  **JS-subset harness**. Authored `phase-7/00-overview.md` (**J1–J8**) + the MEASURED
  `PORFFOR-ABI-FINDINGS.md`, then a 10-agent scoping fan-out + a **3-lens adversarial critique** (EH
  spec-fidelity, BEAM-lowering coherence, Porffor/JS realism) that caught **7 blockers + 10 majors**,
  all folded into the AUTHORITATIVE `phase-7/RECONCILIATION.md` (**T1–T14**):
  - **RE-MEASURED: Porffor emits the LEGACY EH encoding** (try 0x06/catch 0x07/throw 0x08), not
    try_table; and only ever one tag + throw + try/catch. Resolution (T1): freeze the EH IR
    **inline-handler-shaped** — maps legacy 1:1, modern try_table via a transfer, AND Core Erlang's
    try/catch 1:1 (no branch-renumbering; resolves the loop/function catch-target major too).
  - **B: the legacy path had no coherent owner + validate failed OPEN on the EH ctors** → T2: decode +
    validate + lower each handle BOTH encodings; validate intercepts every EH ctor before the
    numeric_sig fallthrough (fail-closed-complete).
  - **B: rt_exn ABI + IR Throw/Catch + tag-identity + CTry ownership + threaded-throw frozen 2–4 ways**
    → T3 (07's rt_exn head set), T4 (module-local Int TagId), T5 (CTry owner = P7-06; core_erlang has
    no try today), T6 (**EH is Cell-only**; Threaded+EH categorized), T7 (the catch term shape lives
    only in rt_exn — the chokepoint), T8 (a distinct `UncaughtException` run outcome, no new TrapReason).
  - **B: the Porffor entry export + intrinsic set were wrong** → T10 (entry = the fixed `"m"`, measured,
    not the basename), T11 (**four** intrinsics a/b/c/d verified vs Porffor source; in-band ANSI output;
    type tags). **T12: trivial JS is EH-FREE and runs on Phase-6 code TODAY** — the shim (08) proves
    "JS on the BEAM" EARLY, independent of EH (de-risk). T13: `porf run` is the fair, non-circular
    oracle. Implementation order: 01 → 08 (early headline) → 03/04/05/07/06 (EH) → 02 → 09 → 10.
    Plan internally consistent; implementation next, keystone-first.

  WebAssembly 2.0 surface** — everything Phase 5 proved **plus** fixed-width SIMD, the memory64
  runtime, and cross-module function linking — proven under both modes and every shipped tier.
  Capstone deliverables: the extended `test/twocore/conformance/new_surface_test.gleam` (the
  capstone-authored backstops — proofs 1–4), the extended
  `test/twocore/conformance/runs_anywhere_test.gleam` (proof 5, the SIMD+mem64 surface), five new
  `corpus/` programs (`simddot`/`simdxform`/`simdmem`/`mem64`.wat+.wasm+.expected, `xlink.wast`), the
  refreshed `docs/wasm-conformance.svg` (46529/1768/0, Phase-6 footnote) + generator, and the new
  `docs/phase-6-surface.md` (the measured before/after + categorized residual + the three scope-limits).
  - **Proof 1 — SIMD spec-correct end-to-end.** `simddot` (integer lanes: `v128.const`, `i16x8.splat`,
    `i32x4.dot_i16x8_s`, the saturating `add_sat_s` family, `i32x4.mul`/`max_s`, `extract_lane`),
    `simdxform` (float lanes: `f32x4.splat`/`mul`/`add`/`sqrt`/`min` single-rounded with the -0.0/NaN
    corners, plus `i8x16.shuffle`, `v128.bitselect`, `i32x4.eq` → a lane mask), and `simdmem`
    (`v128.load`/`store`, `load32_splat`, `store32_lane`/`load32_lane` through the bounds-checked
    `rt_mem` seam + an OOB `v128.load` → trap *out of bounds memory access*) each export a SCALAR
    (Deviation #2) so they ride the byte-identical numeric `Outcome`; spec-correct against their
    spec-sourced `.expected` (cross-checked vs wasmtime 46.0.1) and **byte-identical** across
    `safe`/`unsafe`/`portable`. The ~24.3k-assert whole-suite SIMD lane-wise proof is P6-10's
    (confirmed green, `fail == 0`).
  - **Proof 2 — memory64 runs (MEASURED, I4/S9).** `mem64` declares a `(memory i64 1)`, grows past the
    i32 4 GiB ceiling (O(1) sparse), stores/loads an i64 at byte 2³²+40, reads the fresh region past
    2³² as zero, grows beyond the documented page cap (`mem64_max_pages` = 2³² pages) → **−1**
    allocating nothing, and traps *out of bounds memory access* at `byte_len` — byte-identical across
    Safe/Cell, portable/Threaded, and Unsafe (the 65537-page grow's `delta*page_bytes` fuel charge
    exceeds the default budget, so the memory64 runtime is observed with the meter raised clear — the
    fuel bound is orthogonal, proven by the Phase-4 fuel suites, exactly the P6-06 e2e precedent). The
    official `memory64.wast` stays a categorized parse-skip at the pin (S13 — a WAT-text/tooling
    limitation, NOT a runtime gap).
  - **Proof 3 — cross-module function linking.** `xlink.wast` (driven through our own `parse_script`,
    since the official `linking.wast` is a categorized GC-typed-ref parse-skip): module `$a` exports
    two functions, `(register "a" $a)` publishes them as capabilities, module `$b` imports and CALLS
    them across instances via the linker-built closure (D3a — a handed-in capability, never an ambient
    `apply` of an attacker-named `module:atom`), and an unsatisfied import fails closed at link
    (`assert_unlinkable`). Green under Safe/`cell` (4/4 asserts pass), identical report under
    `unsafe`/`portable`.
  - **Proof 4 — conformance-neutral by default (I7).** The entire Phase-1..4 acceptance corpus AND the
    Phase-5 new-surface programs (`reftab`/`bulkmem`/`multimem`) produce the SAME `Outcome` under Safe
    and Unsafe Phase-6 code, and the Phase-5 surface is still spec-correct + byte-identical across
    `safe`/`unsafe`/`portable` — the IR grew (`TV128`/`ConstV128`/`SimdOp`/`CallImport`) but the
    defaults route the new surface away. Unit P6-06's emitter-level byte-identity is confirmed green.
  - **Proof 5 — the MEASURED headline + runs-anywhere (R16/S11).** Over the full re-vendored allowlist
    WITH the 59 `simd_*.wast` files, `pass` **rose to 46529 (+25004 over the 21525 Phase-5 close — the
    largest conformance movement in the project)**, `fail == 0`, `skip = 1768`, under BOTH profiles
    (Safe ≡ Unsafe) and `fail == 0` under all 5 shipped tier combos (P6-10's `skipcount_test` /
    `residual_audit_test` / `simd_conformance_test` — confirmed). The residual is fully categorized +
    closed: `table_copy.wast`'s ~1080 cross-module funcref-in-`elem`-segment asserts
    (categorized-deferred, a deeper feature than the landed `CallImport` dispatch), ~511 SIMD
    text-format frontend asserts (S13), ~169 genuinely out-of-scope (GC/extended-const/`return_call*`/
    exhaustion/cross-module mutable-state). Runs-anywhere RE-CONFIRMED for the SIMD+mem64 surface: the
    `portable` `.core` of `simddot`/`simdxform`/`simdmem`/`mem64` links **zero** native
    (`atomics`/`ets`/`persistent_term`/NIF) + emits **zero** instance-cell seam, non-vacuously names
    `rt_simd` (pure tier-P bif — native-free) / `rt_mem` / `rt_state`, and executes byte-identical to
    the cell/paged oracle on a bare BEAM.
  - **The honest close of Phase 6 (S12).** *PROVED* — the **complete standardized WebAssembly 2.0
    surface**: reference types + bulk memory + multi-memory + memory64 + **SIMD** + cross-module
    function linking, all **spec-differentially correct** (held to the baked `.wast` + wasmtime) under
    both modes and every shipped `state_strategy × mem_tier` each feature is defined for,
    **conformance-neutral by default** (I7), and **runs-anywhere** for the new surface. `pass` roughly
    doubled with `fail == 0`. *The three honest scope-limits (stated in numbers, not hidden):* SIMD is
    **emulated lane-wise** — no hardware SIMD, no speed claim beyond Phase 4 (I3); memory64 ships a
    **documented spec-aligned page cap** (2³² pages), not 2⁶⁴ allocation — atomics/nif fail-closed
    over-cap (I4); the cross-module drop is **measured, never promised** (I5/R16). *DEFERRED (stated,
    each):* **relaxed-SIMD** (the non-deterministic proposal) → later; the **tail-call** proposal
    (`return_call*`, post-2.0) categorized in the residual (maps cleanly onto BEAM tail calls, a
    plausible fast-follow); **exception-handling / GC** (typed refs + `struct`/`array`/`i31`) **/
    stack-switching / the component model**; **tier-N numerics/SIMD + a production C NIF** (interface +
    skeleton ship); the **memory optimizer** (its own perf phase); the single-`.beam` **B1** binding;
    the **Erlang/Gleam frontend**. **WASI** stays an `rt_host` impl, out of core. **PHASE 7 IS
    UNBLOCKED — JS on the BEAM via Porffor:** the WASM surface is complete, so any Porffor JS→WASM
    application (SIMD, bulk memory, reference types, multi-value) is now runnable through `fe_wasm`; the
    remaining work is a Porffor-ABI `rt_host` shim + a JS-subset harness — a buildable Phase 7. The next
    move is JS on the BEAM.
  - **1491 tests (was 1483), 0 warnings, `gleam format --check src test` clean, conformance
    `fail == 0` across both profiles + the full tier matrix.**
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
