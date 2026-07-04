# What's planned but not built

> The honest "not-yet" list — everything that was designed, scoped, or explicitly deferred across
> Phases 1–10 and is still open. Nothing here is a vague wish: each item names *what it is*, *why it
> was deferred*, and *what it needs*. Pick the next phase from this file, scope it per
> [`03-phase-workflow.md`](03-phase-workflow.md), and record it in [`state.md`](state.md).
>
> Companion to [`01-status.md`](01-status.md) (what *is* built) and [`00-high-level.md`](00-high-level.md)
> (the vision each item serves). **Last consolidated:** 2026-07-04.

Rule of the house: **deferrals are categorized, never false-green.** Every item below corresponds to a
real, tested boundary — a categorized conformance skip, a `Memory64Unsupported`-style typed rejection,
a `todo`-free stub, or a documented single-owner gap. `fail=0` holds regardless.

---

## A. Frontends (the biggest strategic moves)

- **Native JS frontend (the arc track — Phase 8's payoff).** The IR value layer is built (native
  closures, maps/objects, boxing bridge, guarded arithmetic, the `rt_js` boundary). What remains is the
  **frontend itself** (`emit_2core` reusing arc's parser + scope/capture analysis) and the **real
  `rt_js` runtime** holding JS semantics — both are a *separate team's* deliverable against
  [`HANDOFF-arc-frontend.md`](HANDOFF-arc-frontend.md). This is the way past Porffor's ~⅓-of-ECMA
  ceiling and its closure wall, because targeting the BEAM makes closures/GC/maps/bignums native.
  *De-risk first:* Milestone 0 — benchmark hand-written IR vs arc's interpreter before the frontend
  invests. `rt_js` is currently a **stub** in `src/twocore/runtime/rt_js.gleam`.
  - **Value-layer follow-ups (deferred from the Phase-8 IR work):** shaped-object inline caches (needs
    a `CMap` literal IR node), guarded division, first-class mutable cells (currently `rt_js`'s job),
    and generators/async/`eval` (frontend CPS transform or an arc-VM hybrid). These sharpen the term
    path once the frontend exists and has a workload.
- **Erlang/Gleam frontend (`fe_beam`, spec §8.3).** Ingest Core Erlang / Gleam, restrict unsafe
  functionality (the Safe allowlist as a *frontend* security boundary that fails closed), emit IR.
  Never taken by any phase — deferred since Phase 1. The payoff: write Gleam, deploy sandboxed,
  provably unable to take over the VM.

---

## B. WASM surface (post-2.0 proposals)

WASM 2.0 fixed-width is **complete**. What's left is post-2.0 proposals, each a categorized skip today:

- **Tail-call proposal (`return_call` / `return_call_indirect`).** Flagged a *plausible fast-follow* —
  it maps cleanly onto BEAM native tail calls, and it **unblocks the 4 non-convertible official EH
  `.wast` files** (they're blocked on tail-call + GC types, not on an EH gap). Deferred by Phases 6 & 7.
- **GC proposal + GC reference types** (`anyref`, typed function refs, `struct`/`array`/`i31`, `(rec)`
  recursive types). Out of the funcref/externref scope shipped in Phase 5. Porffor confirmed it does
  **not** need GC, so this is spec-completeness, not a JS blocker.
- **Stack-switching**, **the component model**, **relaxed-SIMD**, **extended-const** (arithmetic in
  const-init expressions). All separate proposals, all deferred, all categorized.

---

## C. Cross-module (deeper than what Phase 6 landed)

- **Cross-module funcref-in-elem-segment init** — elem segments initialized with `ref.func` of
  *imported* functions + `call_indirect` (the `table_copy.wast` verifier, **~1,088 skips**). Deeper
  than the `CallImport` *direct* dispatch Phase 6 shipped. This is the single largest categorized
  residual bucket.
- **Cross-module EH tags** — a qualified `{module, idx}` tag identity across module boundaries.
  Porffor-inert (single-module scope), deferred by Phase 7.
- **Threaded cross-instance linking** — Phase 6 proved cross-module linking under `cell`; the invasive
  threaded-state edge is a named category, not a claim.

---

## D. Runtime tiers & binding

- **Production C NIF for tier-N memory.** Phase 4 shipped the uniform interface + a reference
  *skeleton*; the real C impl needs a native toolchain. This is the raw O(1) ceiling (Unsafe-only,
  Safe-forbidden). Its absence is honest — tier-N is *not* currently the measured ceiling.
- **tier-N numerics / tier-N SIMD (real hardware SIMD).** `rt_num`/`rt_simd` are tier-P only; SIMD is
  emulated lane-wise (faithful, no hardware/speed claim). A hardware-SIMD NIF is deferred.
- **Single-`.beam` runtime-dispatch binding (B1).** Perpetually deferred (Phases 3–7). Today
  coexistence is **B3 monomorphization** only — Safe.beam ≠ Unsafe.beam, threaded ≠ cell, nif ≠ paged,
  distinct atoms sharing identical `rt_*` names. B1 would let one `.beam` pick its runtime at instance
  time (the instance-as-unit-of-policy at runtime rather than build time).
- **Self-contained output — `--link` (runtime *inclusion*).** ⏳ **Now Phase 11, in flight** — see
  [`phase-11/00-overview.md`](phase-11/00-overview.md). An optional flag that merges the runtime
  dependency closure into the generated module (whole-program Core-Erlang merge + DCE) → a single
  `.beam` that runs on a bare Erlang/OTP node. Distinct from B1 (which is runtime *selection*).
  Requires a clean runtime/compiler layer split first (the runtime currently imports `twocore/ir` and
  `twocore/middle/ir_opt`). tier-P/O only.

---

## E. The optimizer (`ir_opt`) — remaining speed work

The memory optimizer is complete (Phases 9–10). Remaining passes:

- **Escape analysis for the term/object value path.** *Not* a linear-memory lever (our process-local,
  one-instance-one-process design already pre-satisfies its linear-memory payoff). This is **object
  speed** — scalar-replace objects, avoid boxing closures — gated on a frontend (JS/Gleam) that emits
  object-heavy code. Deferred by Phases 9 & 10 for want of a workload.
- **A general (polyhedral) range solver.** Phase-10 BCE handles the single-affine-induction-variable
  loop only; a real range solver would cover more.
- **Nested / multi-dimensional BCE.**
- **tier-N unchecked memory access.** The Phase-10 unchecked path ships on paged/atomics only; `nif`
  stays checked (and is itself gated on the deferred C NIF, §D).
- **Pure-call CSE.** Deferred since Phase 3 (loads deliberately never CSE'd until the memory optimizer;
  pure calls remain a candidate).

---

## F. JS / Porffor path (measured gaps, not 2core bugs)

- **Heap-typed run results.** The JS harness observes via `console.log` (Porffor's `printChar` emits
  bytes in-band). Decoding heap-typed `(f64,i32)` return values (string/object/array results from
  routed instance memory) is best-effort/deferred.
- **Two-profile (Safe/Unsafe) optimizer-soundness roll-up over the JS corpus.** `run_porffor`
  hardwires `profiles.porffor()`; a `run_porffor_with(binding)` seam is left to a later phase.
- **The 3 JS skips are Porffor's own bugs** (measured: `-0` rendering + broken lexical closures in
  0.61.13, which Porffor's authors call the "closure wall" / "terminal"). 2core reproduces `porf run`
  byte-for-byte on them — they bound Porffor, and are the reason the arc frontend (§A) is the real JS
  road forward.

---

## G. Exception handling — remaining

- **Threaded + EH where state threads *through* a throw/catch.** The Phase-7 `cell`-only bound is
  retained *only* for this combination (state-free EH already runs under both cell and threaded).
- **Modern `exnref` / `throw_ref` / `catch_ref` / `catch_all_ref` as a live/used feature.** Shipped as
  spec-conformance-only (Porffor-inert — 0.61.13 never emits it).

---

## H. Tooling & out-of-core

- **WAT-parser extensions:** SIMD text format (~511 skips; the binary path proves SIMD e2e), plus the
  out-of-scope constructs in `memory64.wast`/`linking.wast` (`(module definition)` module-linking,
  2⁴⁸ hex-with-underscore literals, `(memory i64 (data …))` inline data, interleaved GC typed-ref
  globals). All file-level parse-skips; the *runtime* features are proven by authored backstops.
- **WASI** stays an `rt_host` implementation, deliberately **out of core**. The browser DOM is out of
  scope entirely.

---

## Suggested sequencing (not binding)

A reasonable next-phase menu, roughly by leverage:

1. **Native JS frontend + real `rt_js`** (§A) — the strategic unlock; the IR is ready and the handoff
   is written. Biggest payoff, largest effort, needs the separate frontend team.
2. **Tail-call proposal** (§B) — small, high-yield: BEAM-native fit + clears the last 4 EH files.
3. **Cross-module funcref-in-elem init** (§C) — closes the single biggest conformance residual (~1,088).
4. **Production C NIF** (§D) — establishes the real tier-N ceiling and makes the benchmark story honest.
5. **Escape analysis** (§E) — only once a frontend emits object-heavy code to measure against.
