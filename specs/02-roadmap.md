# What's planned but not built

> The honest "not-yet" list — everything that was designed, scoped, or explicitly deferred across
> Phases 1–12 and is still open. Nothing here is a vague wish: each item names *what it is*, *why it
> was deferred*, and *what it needs*. Pick the next phase from this file, scope it per
> [`03-phase-workflow.md`](03-phase-workflow.md), and record it in [`state.md`](state.md).
>
> Companion to [`01-status.md`](01-status.md) (what *is* built) and [`00-high-level.md`](00-high-level.md)
> (the vision each item serves). **Last consolidated:** 2026-07-06 (after Phases 11 & 12 landed and as
> Phases 13–15 were scoped).

Rule of the house: **deferrals are categorized, never false-green.** Every item below corresponds to a
real, tested boundary — a categorized conformance skip, a `Memory64Unsupported`-style typed rejection,
a `todo`-free stub, or a documented single-owner gap. `fail=0` holds regardless.

**Recently completed — moved out of this list** (see [`01-status.md`](01-status.md) §3):
- ✅ **Phase 11 — `--link` self-contained output** (runtime *inclusion* → one `.beam` on a bare OTP node).
- ✅ **Phase 12 — typed host-language bindings** (companion `.gleam`/`.erl`/`.ex` typed API).
- ✅ **Phase 13 — WASM tail calls** (`return_call`/`return_call_indirect` → genuine constant-stack BEAM
  tail calls; +117 conformance pass, 46,646/1,771/0; constant stack proven to 1,000,000). *Measurement
  correction (R16): the 2 `return_call`-blocked legacy EH files now **convert** but do **not** run green —
  a deeper non-tail-call scope, newly deferred in §G.*
- ✅ **Phase 14 — cross-module funcref-in-`elem` init** (`RefFuncImport` + an inline D3a adapter over
  `link.call_import`; the `table_copy.wast` residual **fully flipped 569/1080 → 1649/0/0**, headline
  47,734/683/0, +1,088 pass — the single largest categorized residual, now CLOSED).
- ⏳ **Phase 15 in flight** — production C NIF for tier-N memory (§D). Still listed below, tagged **in
  flight**, until its capstone proves out.

---

## A. Frontends (the biggest strategic moves)

- **Native JS frontend + real `rt_js` — the arc track. NOT 2core-team scope.** The IR value layer this
  project owns is built and shipped (native closures, maps/objects, boxing bridge, guarded arithmetic,
  the `rt_js` boundary) — that was Phase 8's payoff and it stays here. **The frontend itself
  (`emit_2core` reusing arc's parser + scope/capture analysis) and the real `rt_js` runtime holding JS
  semantics are the arc project's deliverable, built on the arc side against**
  [`HANDOFF-arc-frontend.md`](HANDOFF-arc-frontend.md) — not work 2core picks up as a phase. The
  `src/twocore/runtime/rt_js.gleam` boundary stub in this repo was **merged in by an arc maintainer**;
  leave it alone (it is arc's to grow, not ours to fill). This is the way past Porffor's ~⅓-of-ECMA
  ceiling and its closure wall, because targeting the BEAM makes closures/GC/maps/bignums native — but
  the 2core side of that contract (the IR) is already met.
  - **Value-layer follow-ups (deferred from the Phase-8 IR work):** shaped-object inline caches (needs
    a `CMap` literal IR node), guarded division, first-class mutable cells, and generators/async/`eval`.
    These sharpen the term path **once arc's frontend exists and emits a workload** — 2core would take
    them then, driven by measured object-heavy IR (see §E escape analysis, same gate).
- **Erlang/Gleam frontend (`fe_beam`, spec §8.3).** Ingest Core Erlang / Gleam, restrict unsafe
  functionality (the Safe allowlist as a *frontend* security boundary that fails closed), emit IR.
  Never taken by any phase — deferred since Phase 1. The payoff: write Gleam, deploy sandboxed,
  provably unable to take over the VM. (2core scope, when prioritized.)

---

## B. WASM surface (post-2.0 proposals)

WASM 2.0 fixed-width is **complete**. What's left is post-2.0 proposals, each a categorized skip today:

- ✅ **Tail-call proposal (`return_call` / `return_call_indirect`).** **Done — Phase 13** (see
  [`01-status.md`](01-status.md) §3, row 13). Genuine constant-stack BEAM tail calls: direct reuses the
  `KReturn` tail path; indirect goes through the new `rt_table.call_indirect_lookup` seam (3 ordered
  guards → tail-apply the package-ABI target); imports are value-correct/bounded-frame (Q8 sub-case).
  Funcref/`elem` modules became result-identical (the funcref closure is now package-ABI tail-transparent).
  *It did NOT run the 2 EH files green — measurement (R16) showed they need a deeper scope; see §G.*
- **GC proposal + GC reference types** (`anyref`, typed function refs, `struct`/`array`/`i31`, `(rec)`
  recursive types). Out of the funcref/externref scope shipped in Phase 5. Porffor confirmed it does
  **not** need GC, so this is spec-completeness, not a JS blocker. (Also gates the `try_table` /
  `tag.wast` EH files, which are blocked on `(rec …)` + typed refs, not on an EH gap.)
- **Stack-switching**, **the component model**, **relaxed-SIMD**, **extended-const** (arithmetic in
  const-init expressions). All separate proposals, all deferred, all categorized.

---

## C. Cross-module (deeper than what Phase 6 landed)

- ✅ **Cross-module funcref-in-elem-segment init.** **Done — Phase 14** (see
  [`01-status.md`](01-status.md) §3, row 14). `elem` segments initialized with `ref.func` of *imported*
  functions + `call_indirect`: the `table_copy.wast` residual **fully flipped 569/1080 → 1649/0/0** (the
  single largest categorized bucket, CLOSED). An imported `ref.func` lowers to a distinct `RefFuncImport`
  node → an inline D3a adapter funcref `#(FuncType, fun(Args) -> link:call_import(func_import_at(slot),
  Args))` (reshaped to the package-ABI the post-Phase-13 `rt_table` expects), tier/strategy-uniform.
- **`rt_table_ets` multi-table instances.** ⓘ **Newly found by Phase 14 (pre-existing, orthogonal).**
  `twocore_rt_table_ets_ffi:new/0` uses a single process-dictionary slot for its
  delete-prior-on-reinstantiation discipline, so a module declaring **2+ tables** under `TableEts`
  deletes the first ETS table on the second `new` → `instantiate: badarg`. Independent of imported
  funcrefs (a plain two-table *defined*-funcref module fails identically); never surfaced before because
  no shipped combo used `TableEts` end-to-end. Fix belongs to the table-tier owner (per-table keyed
  storage). Documented in `docs/phase-14-surface.md`; single-table `TableEts` is proven.
- **Cross-module EH tags** — a qualified `{module, idx}` tag identity across module boundaries.
  Porffor-inert (single-module scope), deferred by Phase 7.
- **Threaded cross-instance linking** — Phase 6 proved cross-module linking under `cell`; the invasive
  threaded-state edge is a named category, not a claim.
- **`.core`-input `--link` on `to-beam`** (Phase-11 deferral, R13) — `--link` is scoped to
  `to-beam-wasm` because a raw `.core` input carries no `Binding` to gate tier-N/imports.
- **Import-bearing bare-node linking** (Phase-11 deferral, R14) — `--link` rejects import-bearing
  modules; a provider-baking story (seed imports into the merged `instantiate/1`) is a follow-up.
- **Multi-module `--link`** — merging several generated WASM modules into one artifact (Phase-11
  deferral).

---

## D. Runtime tiers & binding

- **Production C NIF for tier-N memory.** ⏳ **Now Phase 15, in flight** — see
  [`phase-15/00-overview.md`](phase-15/00-overview.md). Phase 4 shipped the uniform interface + a
  node-safe reference skeleton (`rt_mem_nif` delegates to paged today); this phase fills it with a real
  `erl_nif` C backend over a reserved raw byte buffer — the raw O(1) memory ceiling (Unsafe-only,
  Safe-forbidden), **plus** the unchecked fast path tier-N currently lacks (§E). The C source ships with
  a test-time compile-gate (`cc -shared -fPIC` → `load_nif`, skip-categorized when no toolchain, like
  the Elixir binding arm); a prebuilt per-platform `priv/*.so` packaging step is a documented follow-on
  (Gleam has no native pre-build hook).
- **tier-N numerics / tier-N SIMD (real hardware SIMD).** `rt_num`/`rt_simd` are tier-P only; SIMD is
  emulated lane-wise (faithful, no hardware/speed claim). A hardware-SIMD NIF is deferred.
- **Single-`.beam` runtime-dispatch binding (B1).** Perpetually deferred (Phases 3–7, restated by
  Phase 11). Today coexistence is **B3 monomorphization** only — Safe.beam ≠ Unsafe.beam, threaded ≠
  cell, nif ≠ paged, distinct atoms sharing identical `rt_*` names. B1 would let one `.beam` pick its
  runtime at instance time (the instance-as-unit-of-policy at runtime rather than build time). Distinct
  from Phase-11 `--link` (runtime *inclusion*, now landed) — B1 is runtime *selection*.

---

## D′. Typed bindings — deferred follow-ups (Phase 12 landed export-only/threaded)

Phase 12 shipped typed `.gleam`/`.erl`/`.ex` bindings for **threaded (tier-P), export-only** modules.
Deferred (each a categorized rejection today, not a false green):

- **Cell / tier-O process-wrapped *server* bindings** — a stateful module exposed as a generated
  process/server API (the value-threaded model needs no process; the cell model does).
- **A typed import/provider surface** — import-bearing modules are binding-rejected (as `--link` rejects
  them); a typed `instantiate/1(Providers)` surface is a follow-up.
- **Cross-language `funcref`/`externref` construction** — refs are opaque passthrough today, not
  host-constructible callable values.
- **Async / streaming binding surfaces**, and additional binding languages (the
  `twocore_bindings_ffi.erl` compile+call harness is reusable for any new emitter).

---

## E. The optimizer (`ir_opt`) — remaining speed work

The memory optimizer is complete (Phases 9–10). Remaining passes:

- **Escape analysis for the term/object value path.** *Not* a linear-memory lever (our process-local,
  one-instance-one-process design already pre-satisfies its linear-memory payoff). This is **object
  speed** — scalar-replace objects, avoid boxing closures — gated on **arc's frontend emitting
  object-heavy IR to measure against (coming soon).** 2core takes this once that workload exists; until
  then there is nothing to measure and the pass would be speculative. Deferred by Phases 9 & 10 for want
  of a workload.
- **A general (polyhedral) range solver.** Phase-10 BCE handles the single-affine-induction-variable
  loop only; a real range solver would cover more.
- **Nested / multi-dimensional BCE.**
- **tier-N unchecked memory access.** The Phase-10 unchecked path ships on paged/atomics only; `nif`
  stays checked — **being lifted by Phase 15** (§D), which adds `*_unchecked` heads to `rt_mem_nif` and
  the one-line `emit_core` whitelist entry.
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
  byte-for-byte on them — they bound Porffor, and are the reason the **arc frontend (§A, arc-owned)** is
  the real JS road forward.

---

## G. Exception handling — remaining

- **Drive the 2 legacy EH `.wast` files green (`legacy/try_catch`, `legacy/try_delegate`).** ⓘ **Newly
  measured by Phase 13 (R16).** The tail-call proposal *converts* both files (they now vendor + parse),
  but running them green needs a **deeper, non-tail-call scope** than the roadmap assumed:
  - `try_catch` — a **cross-module EH function+tag import** (`(import "test" …)` dispatched via a plain
    `call`, not a tail call). Relates to "Cross-module EH tags" below + §C cross-module.
  - `try_delegate` — **(a)** pre-existing **legacy-`delegate` label-targeting** bugs (wrong handler
    depth, no `return_call` involved) and **(b)** the **`return_call`-inside-`try` interaction**: a WASM
    tail call must abandon the enclosing handler, but BEAM `try/catch` is *dynamically scoped*, so a tail
    `apply` emitted inside it stays in scope. Needs an EH-lowering fix (escape the handler before the
    tail transfer). Both files stay **categorized-deferred, fail=0** (never false-green) until an
    EH-lowering unit takes them.
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

The current 2core-team menu, roughly by leverage. **The native JS frontend is arc's, not on this menu**
(§A); the value-layer + escape-analysis follow-ups unlock once arc emits IR.

1. **Tail-call proposal** (§B) — ⏳ Phase 13. Small, high-yield: BEAM-native fit + clears the 2
   pure-`return_call` EH files.
2. **Cross-module funcref-in-elem init** (§C) — ⏳ Phase 14. Closes the single biggest conformance
   residual (~1,080).
3. **Production C NIF** (§D) — ⏳ Phase 15. Establishes the real tier-N ceiling + unchecked tier-N, and
   makes the benchmark story honest (the missing nif column).
4. **Escape analysis** (§E) — only once arc's frontend emits object-heavy IR to measure against.
5. **`fe_beam` Erlang/Gleam frontend** (§A) or **B1 runtime-dispatch binding** (§D) — larger strategic
   moves when prioritized.
