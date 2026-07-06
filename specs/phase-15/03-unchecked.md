# S15-03 — Unchecked fast-path wiring: the `emit_core` whitelist add + the `emit_unchecked` flip

> **Status:** scoped, awaiting build. **Owner:** S15-03 (a tiny wiring unit — the S4 lever's `emit_core`
> half). **Behind S15-02** (Wave A, DAG §3): binds to the frozen shim (`«NIF-BUILD-FROZEN»`, S15-01) and
> to S15-02's `load_unchecked`/`store_unchecked`/`t_*` heads — it routes to them, it does not create them.
> **Read order:** [`00-overview.md`](00-overview.md) → the distilled codebase map
> (`brief-phase15-cnif.md`) → this doc. All prior-phase decisions and the permanent invariants
> ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold. **Honors S4** (the tier-N ceiling
> lever), **S3/S7** (the unchecked path is bit-identical to checked for in-bounds accesses; the security
> boundary is untouched), **S5** (adds capability, not posture — no Safe widening), **S8** (honest scope:
> the *only* `emit_core` change this phase is one whitelist disjunct). Produces **no** freeze. Per the
> overview §4 ownership note, S15-03 owns **only** the one-line `mem_supports_unchecked` whitelist entry
> (plus the doc corrections it forces) and the `emit_unchecked_test` flip; **`rt_mem_nif.gleam` and
> `c_src/twocore_rt_mem_nif.c` stay single-owner under S15-02** (checked *and* unchecked heads/bodies).

---

## §1. Goal

Flip tier-N from **"falls back to the checked path"** to **"emits unchecked"** on the Phase-10
loop-versioned fast arm, by adding the single whitelist disjunct that makes `emit_core` route a
single-memory nif unchecked node to the `rt_mem_nif` `*_unchecked` seam — and prove the wiring: the
versioned **fast arm runs unchecked** while the **slow arm stays checked**, and the unchecked path is
**bit-identical to checked for in-bounds accesses**. Concretely:

- **One disjunct** into `emit_core.mem_supports_unchecked`: `|| mem_module == profiles.mem_module_for(Nif)`
  (brief `emit_core.gleam:1765`; live: the function body at `1781–1782`).
- **The forced doc corrections** in the same file — three `///` comments currently assert "nif falls back /
  is NOT whitelisted"; they become stale the instant nif is whitelisted and must be corrected (DoD #2).
- **The `emit_unchecked_test` flip** — `nif_falls_back_to_the_checked_path_test`
  (`test/twocore/backend/emit_unchecked_test.gleam:77`) becomes `nif_emits_unchecked_test`, plus a
  versioned-loop routing test (fast=unchecked, slow=checked) and a cc-gated end-to-end bit-identity test.

This implements the **`emit_core` half of S4** (the C `*_unchecked` bodies + the Gleam `@external` heads
are S4's other half — **owned by S15-02**). It is deliberately the smallest possible unit: after S15-02
lands its heads, tier-N gains the unchecked ceiling by adding **one term to one boolean**.

**What it does NOT do:** it touches neither `rt_mem_nif.gleam` nor any `c_src/*` — those heads/bodies are
S15-02's, so both files stay single-owner (overview §4 note). It adds no new `TrapReason`, no frontend/IR
change, and does not touch the checked seam, the four Safe-forbidden gates, or the `--link` exclusion (S5).

---

## §2. Depends on / Produces

**Depends on (read-only, frozen upstream):**

- **S15-01 `«NIF-BUILD-FROZEN»`** — the shim (`src/twocore_rt_mem_nif_ffi.erl`) and the cc-gated build
  harness `test/twocore_rt_mem_nif_build_ffi.erl` (`os:find_executable("cc")` → `cc -shared -fPIC` →
  `erlang:load_nif`, skip-categorized on absence). This unit's **end-to-end** test (§5 test 3) reaches
  that build gate to load the real NIF; the two **structural** tests do not.
- **S15-02 — the native backend (the heart).** Adds to `src/twocore/runtime/rt_mem_nif.gleam` the
  `load_unchecked` / `store_unchecked` / `t_load_unchecked` / `t_store_unchecked` heads (`@external` into
  the shim) and their C bodies (`c_src/twocore_rt_mem_nif.c`, a raw deref with the bounds compare elided).
  **S15-03 routes to these; they MUST exist first** (§3.4 ordering — this is why S15-03 sits *behind*
  S15-02, not merely beside it).
- `src/twocore/backend/emit_core.gleam` — `mem_supports_unchecked` (live `1780–1783`; brief `:1765`),
  `emit_mem_load_unchecked` (live `1691`; brief `:1676`), `emit_mem_store_unchecked` (live `1729`), both
  guarding on `mem == 0 && mem_supports_unchecked(ctx.binding.mem_module)` (brief `emit_core.gleam:1676–1768`).
- `src/twocore/runtime/profiles.gleam` — `mem_module_for(Nif) = "twocore@runtime@rt_mem_nif"`
  (`358–364`), the frozen module-name map the whitelist compares against (G5 — by name, never by enum).
- `src/twocore/middle/ir_opt/bce.gleam` — the loop-versioning pass (module doc `4–15`; `try_version`
  `112–159`; `to_unchecked` `268+`): `guard ? <fast, i-accesses UNCHECKED> : <original checked loop>`.
  **Read-only** — it already emits `ir.MemLoadUnchecked`/`ir.MemStoreUnchecked`; this unit only makes
  `emit_core` lower those to the nif unchecked seam. The soundness of the elided check comes from *here*.

**Produces:** no freeze milestone — a wiring delta. It **completes the `emit_core` half of the S4 lever**;
after it lands, the Phase-10 versioned fast arm runs unchecked on tier-N. It unblocks nothing that S15-02
did not already unblock; the resulting ceiling is **measured by S15-05** (the capstone's "Unchecked
ceiling" acceptance row + the nif benchmark column) and the corpus-wide bit-identity of the fast arm is
**additionally covered by S15-04** (the `cell_nif` matrix now exercises the versioned fast arm on native
memory).

---

## §3. What it owns + design

**Owned edits (D1 — the sole substantive changes S15-03 makes):**

- `src/twocore/backend/emit_core.gleam` — the whitelist disjunct + the `Nif` import it needs + the three
  forced doc corrections (§3.1, §3.2). **No logic changes anywhere else in this file.**
- `test/twocore/backend/emit_unchecked_test.gleam` — the flip + two new tests (§5).

**Explicitly NOT owned** (S15-01/S15-02): `src/twocore/runtime/rt_mem_nif.gleam`, `c_src/twocore_rt_mem_nif.c`,
`c_src/twocore_rt_mem_nif.h`, `src/twocore_rt_mem_nif_ffi.erl`, `test/twocore_rt_mem_nif_build_ffi.erl`.
S15-03 *calls* the last of these (a deliberate cross-file test reach, recorded in `state.md`) but does not
edit it.

### 3.1 The whitelist disjunct — `mem_supports_unchecked` (live `1780–1783`; brief `:1765`)

The fail-closed name whitelist today is exactly paged + atomics:

```gleam
fn mem_supports_unchecked(mem_module: String) -> Bool {
  mem_module == profiles.mem_module_for(Paged)
  || mem_module == profiles.mem_module_for(Atomics)
}
```

Add the third disjunct (the entire code change of this unit):

```gleam
  mem_module == profiles.mem_module_for(Paged)
  || mem_module == profiles.mem_module_for(Atomics)
  || mem_module == profiles.mem_module_for(Nif)
```

**The `Nif` scope gotcha (this "one-liner" is a one-liner *plus one import term*).** The `instance`
import at `emit_core.gleam:109–112` brings `Atomics, Paged, Threaded` unqualified but **not** `Nif`
(verified: `Nif` does not currently appear anywhere in `emit_core.gleam`). So `profiles.mem_module_for(Nif)`
does not compile as written. Fix: add `Nif` to the `instance.{…}` import list (matching the existing
`Paged`/`Atomics` style) — it is used immediately, so DCE-clean, zero warning. (Alternative: write
`profiles.mem_module_for(instance.Nif)` and touch no import; the import form is preferred for consistency
with the two sibling disjuncts.)

**Routing consequence.** `emit_mem_load_unchecked`/`emit_mem_store_unchecked` (live `1691`/`1729`) both
branch on `mem == 0 && mem_supports_unchecked(ctx.binding.mem_module)`:

- With nif now whitelisted, a **single-memory** (`mem == 0`) nif `MemLoadUnchecked`/`MemStoreUnchecked`
  takes the **True** arm → `seam_call(rt_mem_nif, "load_unchecked" | "store_unchecked" | "t_load_unchecked"
  | "t_store_unchecked", …)` (S15-02's heads), binding directly via `apply_cont` (loads) /
  `emit_zero_effect` (cell stores) / the threaded `CLet` (threaded stores) — exactly the paged/atomics
  shape, no `Result` reducer.
- **Multi-memory** (`mem != 0`) nif accesses **still fall back to checked** — the `mem == 0` guard is
  unchanged (nif multi-memory has no `*_unchecked_at` twin; the checked `*_at` seam is always sound).
- **G5 preserved** — the emitter branches on the module *name*, never on `MemTier` the enum. Paged/atomics
  routing is byte-identical (the disjunct only adds a name that was previously false).

### 3.2 Forced doc corrections (required — DoD #2)

Three `///` comments in `emit_core.gleam` become factually wrong the moment nif is whitelisted. Correcting
them is prose-only (no logic in those functions changes) and is part of this unit — leaving them would ship
a doc that contradicts the code:

- **`mem_supports_unchecked` doc (`1776–1779`)** — currently: *"exactly the paged + atomics runtime
  modules. An unknown/future module (or nif) is NOT whitelisted."* → **paged + atomics + nif**; drop the
  "(or nif)" counter-example; keep the fail-closed framing (an *unknown/future* module is still not
  whitelisted → checked fallback, always sound).
- **`emit_mem_load_unchecked` doc (`1686–1690`)** — currently: *"On nif / multi-memory it falls back to
  the CHECKED `emit_mem_load`."* → *"On **multi-memory** (`mem != 0`) or an unknown module it falls back to
  the checked path; paged/atomics/**nif** single-memory lower to the `load_unchecked`/`t_load_unchecked`
  seam."*
- **`emit_mem_store_unchecked` doc (`1725–1728`)** — the same correction for the store seam
  (`store_unchecked`/`t_store_unchecked`).

### 3.3 Soundness — why eliding the check is safe on a memory-*unsafe* tier (S4 + bce)

The unchecked arm is only ever reached inside a **bce-versioned loop's fast branch**, and bce has already
proved the whole `i`-range in-bounds before control enters it. From `bce.gleam` (module doc `4–15`):
BCE **does not hoist-and-trap-early** — it *versions*: `let guard = <pure i64 range check> in if guard {
<loop, i-accesses UNCHECKED> } else { <original checked loop> }`. *"When the guard passes, every
iteration's recognized access is provably in-bounds, so the unchecked fast loop behaves identically to the
checked loop; when it fails, the original checked loop runs — identical values, identical trap at the
identical point."* **Trap-preservation is absolute.** So on the fast arm the C bounds compare is redundant,
and **tier-N is precisely the BEAM-memory-*unsafe* tier where eliding it is the whole point** (S4) — the
raw deref is the ceiling lever the checked seam's per-access compare otherwise blocks.

**The security boundary is untouched (S3).** The C bounds check that S3 fuzzes lives on the **checked**
seam (`load`/`store`, S15-02) — used by the slow arm, by every non-versioned access, and by multi-memory.
S15-03 does not touch it and does not weaken it: the whitelist add only reroutes nodes the optimizer had
*already* proved in-bounds. The `*_unchecked` C bodies' in-bounds correctness (raw deref, LE assembly,
sign/zero extension identical to checked) is **S15-02's** to prove — via its per-op differential — and
S15-04's fuzz/matrix; this unit inherits that proof, it does not re-litigate it.

### 3.4 Ordering (load-bearing) — behind S15-02, not beside it

The whitelist flip is **runtime-sound only once S15-02's `*_unchecked` heads exist.** If S15-03 landed
first, `emit_core` would emit `call 'rt_mem_nif':'load_unchecked'/5` into a module that has no such export
→ an `undef` at run time. Crucially the **structural** emit tests (§5 tests 1–2) inspect emitted Core text
only and would pass anyway — a *false green* that hides a runtime break. Therefore S15-03 lands **behind
S15-02** (DAG §3, Wave A: "S15-03/04 … may land after S15-02 lands green"), and `state.md` records the
dependency explicitly.

---

## §4. The work (ordered, buildable)

1. **`emit_core.gleam`** — add `Nif` to the `instance.{…}` import (`109–112`); add the third disjunct to
   `mem_supports_unchecked` (`1781–1782`); correct the three doc comments (§3.2). `gleam build` — zero
   warnings (import used immediately; boolean stays total).
2. **`emit_unchecked_test.gleam`** — flip `nif_falls_back_to_the_checked_path_test` (`:77`) →
   `nif_emits_unchecked_test` (§5 test 1); add the versioned-loop routing test (test 2); add the cc-gated
   end-to-end bit-identity test (test 3, reaching S15-01's build gate).
3. `gleam format` → `gleam build` (zero warnings) → `gleam test -- emit_unchecked` → full `gleam test`
   (corpus + conformance still green; tier-P/O byte-identical — the disjunct only *adds* nif).
4. **Confirm the skip path:** with no `cc`, test 3 skip-categorizes (never false green); tests 1–2 (emit-text
   only) still run. Record the S15-02 ordering dependency + the build-gate reach in `state.md`.

---

## §5. Tests (`test/twocore/backend/emit_unchecked_test.gleam`) — spec-cited + the wiring proof

Objective against the WebAssembly linear-memory semantics + the Phase-10/S4 contract, **not**
change-detectors (S7/D8): a versioned access is *trap-or-access*; the fast arm may elide the compare only
because the guard proved it in-bounds, and the elided path must be **bit-identical** to the checked one.
The module fixture `rt_module()` (store-then-load-back, already in the file) and the `run` helper are
reused.

1. **`nif_emits_unchecked_test`** — REPLACES `nif_falls_back_to_the_checked_path_test` (`:77`). Under
   `profiles.resolve_tiers(Binding(..profiles.unsafe(), mem_tier: Nif))`, emit `rt_module()` via
   `pipeline.ir_to_core` and assert the core **now contains** `"load_unchecked"` **and** `"store_unchecked"`
   and routes to `"rt_mem_nif"` — the exact inverse of the current `assert !string.contains(...)`.
   *Structural* (emit-text only; no NIF loaded) → runs with **and** without `cc`. Cite: S4 (nif joins the
   fail-closed unchecked whitelist).

2. **`nif_versioned_loop_emits_unchecked_fast_checked_slow_test`** — NEW, the load-bearing wiring proof.
   Hand-build a minimal versionable affine-cursor loop (`Loop` whose body has a `MemLoad`/`MemStore` at
   `ir.Var(i)`, the byte cursor — the shape `bce.try_version` accepts), lower it through the pipeline under
   the Nif binding, emit, and assert **both**: the **fast arm** contains the nif `*_unchecked` seam
   (`load_unchecked`/`store_unchecked`) **and** the **slow arm** still contains the **checked** nif seam
   (`rt_mem_nif` `load`/`store` with **no** `_unchecked`). This proves the lever fires on the guarded arm
   **without weakening the pristine checked fallback** — bce's `guard ? fast : original-checked` structure
   (module doc `4–15`; `try_version` `112–159`) is preserved end-to-end through `emit_core.gleam:1676–1768`.
   *Structural* → runs everywhere. Construction note: build the versionable loop **locally** in this test
   module (do not import test-internals across files); mirror the fixture shape used by `bce`'s own tests.

3. **`nif_unchecked_is_bit_identical_to_checked_test`** — NEW, **cc-GATED / skip-categorized**. END-TO-END:
   the unchecked fast path returns the **identical bit pattern** the checked path returns for an in-bounds
   access (S3/S7). Requires the real NIF loaded, so it first invokes S15-01's build gate
   (`test/twocore_rt_mem_nif_build_ffi.erl` — `os:find_executable("cc")` → `cc -shared -fPIC` →
   `erlang:load_nif`); **`cc` absent ⇒ categorized SKIP** (mirrors the Elixir-binding arm + S15-02's
   differential gating, never a false green). Assert
   `run(nif_binding, "rt", [0, 305_419_896]) == pipeline.Returned([305_419_896])` **and** that it equals
   `run(profiles.safe(), "rt", [0, 305_419_896])` (paged checked) — nif-unchecked ≡ paged-checked for the
   in-bounds round-trip. Add a threaded twin under `Binding(..profiles.unsafe(), state_strategy: Threaded,
   mem_tier: Nif)` (exercising `t_load_unchecked`/`t_store_unchecked`). Cross-file reach (S15-01 build FFI)
   recorded in `state.md`. Cite: WASM `t.load`/`t.store` are byte-exact LE moves; the differential is the
   proof (S7).
   > The **corpus-wide** bit-identity of the nif fast arm is *additionally* guaranteed by **S15-04**'s
   > `cell_nif` matrix differential (nif ≡ paged ≡ oracle across the whole corpus, now exercising the
   > versioned fast arm on native memory). Test 3 is the focused unit-level proof; S15-04 is the
   > belt-and-suspenders corpus proof.

4. **Defaults unaffected (no new test — the existing pair is the guard).** `paged_emits_the_unchecked_seam_test`
   and `atomics_emits_the_unchecked_seam_test` (`:63`, `:69`) stay green **verbatim**: the disjunct only
   adds nif, so paged/atomics routing is unchanged. Asserted implicitly by keeping both green (DoD #3).

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. `gleam format --check src test` **clean**.
2. `gleam build` **zero warnings** — the added `Nif` import is used immediately (no unused import/var); the
   `mem_supports_unchecked` boolean stays total; no other arm forced.
3. The unit suite (`gleam test -- emit_unchecked`) **green**: tests 1 and 2 run everywhere; test 3 runs
   under `cc` and **categorized-skips** without `cc` (verified on the `cc`-absent path — no false green).
   Full `gleam test` + WASM conformance stay green; **tier-P/tier-O output byte-identical** (the two
   default-unaffected tests unchanged; the disjunct never alters paged/atomics routing).
4. **Doc comments accurate (DoD #2):** the three stale "nif falls back / is NOT whitelisted" `///` comments
   (§3.2) corrected so no doc contradicts the new routing; the corrected `mem_supports_unchecked` doc keeps
   the fail-closed framing (unknown/future modules still → checked).
5. `state.md` updated: the whitelist disjunct + the `emit_unchecked` flip recorded; the **S15-02 ordering
   dependency** (§3.4) and the **cross-file reach** to S15-01's build gate (test 3) both noted.

---

## §7. What it leaves (handoff to downstream)

- **S15-04 (node-safety + matrix):** its `cell_nif` corpus differential now automatically exercises the
  **versioned fast arm on native memory** (the whitelist reroutes it), generalizing this unit's focused
  test 3 to the corpus-wide `nif ≡ paged ≡ oracle` proof. No further wiring needed from S15-03.
- **S15-05 (capstone):** proves the acceptance table's **"Unchecked ceiling"** row — *the Phase-10
  loop-versioned fast arm now runs unchecked on tier-N (previously it fell back to checked); loop-versioning
  correctness preserved (the guard still proves in-bounds before the unchecked arm)* — and measures the
  **nif benchmark column**. The honest ceiling to state: unchecked removes the bounds-check cost on the fast
  arm, but the per-access **inter-module seam-call floor** (`call 'rt_mem_nif':'load_unchecked'`, never
  inlined across the module seam) remains — no hero number.
- **Nothing left in `emit_core`.** The S4 lever's `emit_core` half is **complete at this unit**: one
  whitelist term, no further entries, no `*_unchecked` head/body work (that is, and stays, S15-02's, keeping
  `rt_mem_nif.gleam`/`.c` single-owner). The four Safe-forbidden gates and the `--link` exclusion (S5) are
  untouched — this unit adds capability to the Unsafe path only.
