# What's planned but not built

> The honest "not-yet" list for **carder, the compiler backend** — everything that was designed,
> scoped, or explicitly deferred across Phases 1–15 and is still open **at or below the IR**. Nothing
> here is a vague wish: each item names *what it is*, *why it was deferred*, and *what it needs*. Pick
> the next phase from this file, scope it per [`03-phase-workflow.md`](03-phase-workflow.md), and
> record it in [`state.md`](state.md).
>
> Companion to [`01-status.md`](01-status.md) (what *is* built) and [`00-high-level.md`](00-high-level.md)
> (the vision each item serves). **Last consolidated:** 2026-07-06 (after Phases 11 & 12 landed and as
> Phases 13–15 were scoped). **Re-cut for the carder/scribbler split:** 2026-08-16.

Rule of the house: **deferrals are categorized, never false-green.** Every item below corresponds to a
real, tested boundary — a categorized conformance skip, a `Memory64Unsupported`-style typed rejection,
a `todo`-free stub, or a documented single-owner gap. `fail=0` holds regardless.

---

## 0. Where the old list went (the split routing)

carder is now purely the **backend**: the shared IR, the middle-end, Core Erlang codegen and linking,
the BEAM runtime, the embedder API, and the shared CLI vocabulary. The WebAssembly frontend and the
entire official spec-test conformance suite live in **scribbler**
([`scarletindustries/scribbler`](https://github.com/scarletindustries/scribbler)); the JavaScript
frontend lives in **arc** (`alii/arc`). Nothing was dropped in the move — items that genuinely span
the seam are stated **as halves**, one in each repo.

| Old section | carder keeps | Moved / mirrored |
|---|---|---|
| **§A Frontends** | what the **IR/backend** must grow to accept a new frontend | the wasm-side items → scribbler `specs/02-roadmap.md` §A (scribbler repo); the JS frontend itself → arc |
| **§B WASM surface (post-2.0)** | only the IR/runtime half a proposal needs | the surface itself → scribbler §B (scribbler repo) |
| **§C Cross-module** | the IR/link/`--link` seam | the `.wast` coverage that proves it → scribbler §C (scribbler repo) |
| **§D / §D′ Runtime tiers & binding** | **all of it** | — |
| **§E Optimizer** | **all of it** | — |
| **§F JS / Porffor measured gaps** | — | scribbler §F (the Porffor guest is wasm-in) / arc |
| **§G Exception handling** | the EH **lowering** fixes | the 2 legacy EH `.wast` files → scribbler §G (scribbler repo) |
| **§H Tooling & out-of-core** | WASI's "stays out of core" posture, native packaging | the WAT-parser extensions → scribbler §H (scribbler repo) |

**A note on the numbers.** The headline **47,734 pass / 683 skip / 0 fail** WASM-conformance triple
cited throughout this file is the **pre-split historical baseline**, measured on the single repo up to
2026-08-16 (Safe ≡ Unsafe, every `state_strategy × mem_tier`). It is **scribbler's number now** —
carder's CI no longer vendors wabt / wast2json / the spec testsuite at all, and that absence is the
proof the extraction was clean. carder's own gleam-test count likewise **re-measure on the split
tree**; the pre-split figure (both halves together) was 2,111 → 2,221 tests / 0 fail.

**Recently completed — moved out of this list** (see [`01-status.md`](01-status.md) §3):
- ✅ **Phase 11 — `--link` self-contained output** (runtime *inclusion* → one `.beam` on a bare OTP node).
- ✅ **Phase 12 — typed host-language bindings** (companion `.gleam`/`.erl`/`.ex` typed API).
- ✅ **Phase 13 — WASM tail calls** (`return_call`/`return_call_indirect` → genuine constant-stack BEAM
  tail calls; +117 conformance pass, 46,646/1,771/0; constant stack proven to 1,000,000). *Measurement
  correction (R16): the 2 `return_call`-blocked legacy EH files now **convert** but do **not** run green —
  a deeper non-tail-call scope, newly deferred in §G.* (The IR/codegen half landed here; the wasm
  ingest and the `.wast` measurement are scribbler's.)
- ✅ **Phase 14 — cross-module funcref-in-`elem` init** (`RefFuncImport` + an inline D3a adapter over
  `link.call_import`; the `table_copy.wast` residual **fully flipped 569/1080 → 1649/0/0**, headline
  47,734/683/0, +1,088 pass — the single largest categorized residual, now CLOSED).
- ✅ **Phase 15 — production tier-N C NIF** (a real `erl_nif` backend over a reserved ERTS-resource
  buffer, bit-identical to paged by an ~800-step differential, node-safe by a 16-test C-bounds fuzz
  incl. memory64 overflow vectors; unchecked fast path wired; **3.10–5.73× faster than the paged
  delegate** on the same `.beam`, native-when-loaded / paged-otherwise). *Honest scope, §D: the
  conformance `cell_nif` point runs the bit-identical paged delegate (a test-harness resource-lifecycle
  constraint), imported-memory native load/store is a documented gap, and a prebuilt `priv/*.so`
  packaging step is a follow-on.*

---

## A. Frontends — what the IR/backend must grow to accept one

**Every frontend is its own repo.** scribbler (WebAssembly) and arc (JavaScript) both consume carder as
an ordinary Gleam package and emit a `carder/ir.Module`; the contract they build against is
[`FRONTEND-API.md`](FRONTEND-API.md), and the three seams that make it work are pinned in
[`00-high-level.md`](00-high-level.md) §8.4. **carder never takes a frontend as a phase** — what carder
takes is the IR/runtime work a frontend's *measured* workload asks for.

- **Native JS frontend + real `rt_js` — the arc track. NOT carder-team scope.** The IR value layer this
  project owns is built and shipped (native closures, maps/objects, boxing bridge, guarded arithmetic,
  the `rt_js` boundary) — that was Phase 8's payoff and it stays here. **The frontend itself
  (`emit_carder` reusing arc's parser + scope/capture analysis) and the real `rt_js` runtime holding JS
  semantics are the arc project's deliverable, built on the arc side against**
  [`FRONTEND-API.md`](FRONTEND-API.md) — not work carder picks up as a phase. The
  `src/carder/runtime/rt_js.gleam` boundary stub in this repo was **merged in by an arc maintainer**;
  leave it alone (it is arc's to grow, not ours to fill). This is the way past Porffor's ~⅓-of-ECMA
  ceiling and its closure wall, because targeting the BEAM makes closures/GC/maps/bignums native — but
  the carder side of that contract (the IR) is already met.
  - **Value-layer follow-ups (deferred from the Phase-8 IR work):** shaped-object inline caches (needs
    a `CMap` literal IR node), guarded division, first-class mutable cells, and generators/async/`eval`
    (the CPS/state-machine transform is the frontend's, but any IR node it needs is ours). These
    sharpen the term path **once arc's frontend exists and emits a workload** — carder would take them
    then, driven by measured object-heavy IR (see §E escape analysis, same gate). The split makes that
    gate *cleaner*, not looser: the workload arrives as a `.ir` file from another repo, which is
    exactly the corpus format carder's own IR freezes already use.
- **A typed import/provider surface, and host-constructible reference values.** See §D′ — both are
  frontend-facing gaps in carder's public API, surfaced by frontends supplying host namespaces, not
  source-language features.
- **Erlang/Gleam frontend (`fe_beam`, spec §8.4).** Ingest Core Erlang / Gleam, restrict unsafe
  functionality (the Safe allowlist as a *frontend* security boundary that fails closed), emit IR.
  Never taken by any phase — deferred since Phase 1. Post-split it would be **its own repo**, on the
  scribbler/arc precedent; **carder's half** is only whatever the IR + `ir_lower` Safe boundary must
  expose for a source-level restriction pass to be provable (today the BIF allowlist is enforced at
  `ir_lower`, which is the right place — confirm before scoping). The payoff: write Gleam, deploy
  sandboxed, provably unable to take over the VM.

---

## B. WASM surface (post-2.0 proposals) — scribbler's, with a backend half

WASM 2.0 fixed-width is **complete**. What's left is post-2.0 proposals, each a categorized skip today
— and **the surface itself is scribbler's**: see scribbler `specs/02-roadmap.md` §B (scribbler repo)
for the per-proposal state, the categorized skips, and the conformance impact.

What stays here: a proposal that needs **more than a decoder** is a two-repo job, and carder owns the
lower half. The backend halves currently in view:

- **GC proposal + GC reference types** (`anyref`, typed function refs, `struct`/`array`/`i31`, `(rec)`
  recursive types). Out of the funcref/externref scope shipped in Phase 5. The **IR value/type surface
  and the `rt_gc`-side runtime layer are carder's**; decode, validate and lowering are scribbler's.
  Porffor confirmed it does **not** need GC, so this is spec-completeness, not a JS blocker. (Also
  gates the `try_table` / `tag.wast` EH files, which are blocked on `(rec …)` + typed refs, not on an
  EH gap.)
- **Extended-const** (arithmetic in const-init expressions) — scribbler decodes the expression; carder
  must be able to represent and evaluate it at the IR/link seam.
- **Stack-switching**, **the component model**, **relaxed-SIMD**. All separate proposals, all deferred,
  all categorized. Only stack-switching plausibly reaches codegen/runtime; scope it from the scribbler
  side when the surface work is real.

✅ **Tail-call proposal (`return_call` / `return_call_indirect`). Done — Phase 13** (see
[`01-status.md`](01-status.md) §3, row 13). Genuine constant-stack BEAM tail calls: direct reuses the
`KReturn` tail path; indirect goes through the `rt_table.call_indirect_lookup` seam (3 ordered guards →
tail-apply the package-ABI target); imports are value-correct/bounded-frame (Q8 sub-case). Funcref/`elem`
modules became result-identical (the funcref closure is now package-ABI tail-transparent). *It did NOT
run the 2 legacy EH files green — measurement (R16) showed they need a deeper scope; see §G.*

---

## C. Cross-module (deeper than what Phase 6 landed) — the IR/link seam

carder's half is everything about how two modules' IR, imports, providers and `.beam` output compose.
The **`.wast` coverage that proves it** (`table_copy`, `linking`, the cross-module EH files) is
scribbler `specs/02-roadmap.md` §C (scribbler repo).

- ✅ **Cross-module funcref-in-elem-segment init.** **Done — Phase 14** (see
  [`01-status.md`](01-status.md) §3, row 14). `elem` segments initialized with `ref.func` of *imported*
  functions + `call_indirect`: the `table_copy.wast` residual **fully flipped 569/1080 → 1649/0/0** (the
  single largest categorized bucket, CLOSED). An imported `ref.func` lowers to a distinct `RefFuncImport`
  node → an inline D3a adapter funcref `#(FuncType, fun(Args) -> link:call_import(func_import_at(slot),
  Args))` (reshaped to the package-ABI the post-Phase-13 `rt_table` expects), tier/strategy-uniform.
- **`rt_table_ets` multi-table instances.** ⓘ **Found by Phase 14 (pre-existing, orthogonal).**
  `carder_rt_table_ets_ffi:new/0` uses a single process-dictionary slot for its
  delete-prior-on-reinstantiation discipline, so a module declaring **2+ tables** under `TableEts`
  deletes the first ETS table on the second `new` → `instantiate: badarg`. Independent of imported
  funcrefs (a plain two-table *defined*-funcref module fails identically); never surfaced before because
  no shipped combo used `TableEts` end-to-end. Fix belongs to the table-tier owner (per-table keyed
  storage) — **wholly inside carder**. Documented in `docs/phase-14-surface.md`; single-table `TableEts`
  is proven.
- **Cross-module EH tags** — a qualified `{module, idx}` tag identity across module boundaries. The
  **identity model in the IR + `link` is carder's**; the `.wast` files that exercise it are scribbler's
  (§G). Porffor-inert (single-module scope), deferred by Phase 7.
- **Threaded cross-instance linking** — Phase 6 proved cross-module linking under `cell`; the invasive
  threaded-state edge is a named category, not a claim.
- **`.core`-input `--link` on `to-beam`** (Phase-11 deferral, R13) — `--link` is scoped to inputs that
  carry a `Binding`, because a raw `.core` input carries none to gate tier-N/imports with.
- **Import-bearing bare-node linking** (Phase-11 deferral, R14) — `--link` rejects import-bearing
  modules; a provider-baking story (seed imports into the merged `instantiate/1`) is a follow-up. The
  split adds a design question worth answering first: providers are now **frontend-supplied**
  (`link.Provider.Namespace`), so "bake the providers in" means baking in a closure another repo owns —
  decide whether a linked artifact may carry one at all, or whether import-bearing modules stay a
  runtime-provided-only shape.
- **Multi-module `--link`** — merging several generated modules into one artifact (Phase-11 deferral).

---

## D. Runtime tiers & binding

- ✅ **Production C NIF for tier-N memory.** **Done — Phase 15** (see [`01-status.md`](01-status.md) §3,
  row 15). A real `erl_nif` C backend over a reserved ERTS-resource byte buffer, bit-identical to the
  paged reference (~800-step differential), node-safe (16-test C-bounds fuzz incl. memory64 overflow +
  cross-resource copy vectors — the C bounds-check is the tested trust boundary), with the unchecked
  fast path wired (§E). Unsafe-only, Safe-forbidden (4 gates preserved), un-`--link`-able. Built at test
  time via a `cc`-gated harness (`-undefined dynamic_lookup` mandatory on macOS; a robust `erts_include`
  resolver since `code:lib_dir(erts,include)` is header-less on homebrew OTP), proven on CI gcc + macOS
  clang. Measured **3.10–5.73× over the paged delegate** (store-heavy gains most); still 19.2× off
  hand-written Erlang (the inter-module seam-call floor + tier-P `bif` numeric floor remain).
  **Follow-ups (documented):** (1) a prebuilt per-platform `priv/*.so` so native is active without a
  test-time build (Gleam has no native pre-build hook — native-when-loaded, paged-delegate otherwise);
  (2) native `load`/`store`/`size`/`grow`/SIMD on an *imported* (paged) memory — currently delegated to
  `rt_mem` (only `init_data` on imported memory was exercised, and is fixed); (3) letting a conformance
  `cell_nif` matrix point run native (blocked by the keystone probe's `RT_CREATE`-only resource type +
  the conformance harness's orphan-spawn resource lifecycle — the native tier is proven via the
  differential + fuzz + corpus tier differential instead). Post-split, (1) and (2) are wholly carder's;
  (3) is **joint** — the resource-type change is carder's, the harness change is scribbler's.
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
  them); a typed `instantiate/1(Providers)` surface is a follow-up. Post-split this is the
  **frontend-facing gap most likely to be asked for**: a frontend that supplies host namespaces
  (scribbler's `spectest`/TeaVM/Porffor providers) has no typed way to hand them to a *bound* module.
- **Cross-language `funcref`/`externref` construction** — refs are opaque passthrough today, not
  host-constructible callable values. The same gap a `Namespace` resolver hits when it wants to
  *return* a reference-typed value rather than pass one through.
- **Async / streaming binding surfaces**, and additional binding languages (the
  `carder_bindings_ffi.erl` compile+call harness is reusable for any new emitter).

---

## E. The optimizer (`ir_opt`) — remaining speed work

The memory optimizer is complete (Phases 9–10). Remaining passes — all wholly carder's, since the
optimizer sits below the IR and sees no source language:

- **Escape analysis for the term/object value path.** *Not* a linear-memory lever (our process-local,
  one-instance-one-process design already pre-satisfies its linear-memory payoff). This is **object
  speed** — scalar-replace objects, avoid boxing closures — gated on **arc's frontend emitting
  object-heavy IR to measure against (coming soon).** carder takes this once that workload exists; until
  then there is nothing to measure and the pass would be speculative. Deferred by Phases 9 & 10 for want
  of a workload.
- **A general (polyhedral) range solver.** Phase-10 BCE handles the single-affine-induction-variable
  loop only; a real range solver would cover more.
- **Nested / multi-dimensional BCE.**
- ✅ **tier-N unchecked memory access.** **Done — Phase 15.** `rt_mem_nif` gained `*_unchecked` heads
  (native raw deref; paged-delegate fallback when the `.so` isn't loaded) and `Nif` was added to the
  `emit_core.mem_supports_unchecked` whitelist, so the Phase-10 loop-versioned BCE fast arm now runs
  unchecked on tier-N (trap-preservation held — the guard proves in-bounds before the unchecked arm).
- **Pure-call CSE.** Deferred since Phase 3 (loads deliberately never CSE'd until the memory optimizer;
  pure calls remain a candidate).

---

## F. JS / Porffor path — not carder's

The measured Porffor gaps — heap-typed run results, the two-profile (Safe/Unsafe) optimizer-soundness
roll-up over the JS corpus, and the 3 skips that are **Porffor's own bugs** (`-0` rendering + broken
lexical closures in 0.61.13, which Porffor's authors call the "closure wall") — moved with the Porffor
path itself: the guest is a `.wasm`, so it enters through the wasm frontend. See scribbler
`specs/02-roadmap.md` §F (scribbler repo). The native JS road forward is **arc** (`alii/arc`); carder's
half of that contract is §A's value-layer follow-ups and §E's escape analysis, both gated on arc
emitting a workload.

---

## G. Exception handling — remaining (the lowering half)

The **2 legacy EH `.wast` files** (`legacy/try_catch`, `legacy/try_delegate`) are scribbler's to drive
green and to count; the **fixes they need are mostly here**. ⓘ **Newly measured by Phase 13 (R16):** the
tail-call proposal *converts* both files (they now vendor + parse), but running them green needs a
**deeper, non-tail-call scope** than the roadmap assumed. Split by fix site:

- **carder — `return_call`-inside-`try` (the dynamic-scope bug).** A WASM tail call must abandon the
  enclosing handler, but BEAM `try/catch` is *dynamically scoped*, so a tail `apply` emitted inside it
  stays in scope. Needs an **EH-lowering fix in codegen**: escape the handler before the tail transfer.
  Unambiguously carder's.
- **carder — a cross-module EH function+tag import.** `try_catch`'s residual is an `(import "test" …)`
  dispatched via a plain `call`, not a tail call; it needs the qualified cross-module **tag identity**
  of §C.
- **Measure first, then assign — legacy-`delegate` label targeting.** `try_delegate` also carries
  pre-existing **wrong-handler-depth** bugs with no `return_call` involved. Whether the depth is
  resolved wrongly in the **wasm→IR lowering** (scribbler) or mis-modelled in carder's IR `Try` surface
  is a measurement, not an assumption — take it before scoping the unit.
- **Threaded + EH where state threads *through* a throw/catch.** The Phase-7 `cell`-only bound is
  retained *only* for this combination (state-free EH already runs under both cell and threaded).
  Wholly carder's (`rt_state` × `rt_exn`).
- **Modern `exnref` / `throw_ref` / `catch_ref` / `catch_all_ref` as a live/used feature.** Shipped as
  spec-conformance-only (Porffor-inert — 0.61.13 never emits it). The IR/runtime half is carder's, the
  surface half scribbler's.

Both files stay **categorized-deferred, fail=0** (never false-green) until an EH-lowering unit takes
them. Because the fix and the proof now live in different repos, scope it as a **paired unit**: land the
codegen fix here, bump the dependency in scribbler, and let scribbler's `.wast` count be the capstone.

---

## H. Tooling & out-of-core

- **WAT-parser extensions** (SIMD text format ~511 skips, plus the out-of-scope constructs in
  `memory64.wast`/`linking.wast`) moved with the parser — scribbler `specs/02-roadmap.md` §H (scribbler
  repo). All were file-level parse-skips; the *runtime* features they hide are proven by authored
  backstops.
- **WASI** stays deliberately **out of core**, and the split sharpened what that means: carder no longer
  hard-codes **any** host module by name, so WASI would be an ordinary `link.Provider.Namespace`
  supplied by a frontend or an embedder — exactly like scribbler's `spectest`/TeaVM/Porffor namespaces.
  carder's job is only to keep that seam expressive enough (see §D′ on reference-typed values and typed
  provider surfaces). The browser DOM is out of scope entirely.
- **Native packaging (`priv/*.so`)** — §D follow-up (1) is as much a *tooling* item as a runtime one:
  Gleam has no native pre-build hook, so shipping a prebuilt per-platform `.so` needs a release-pipeline
  decision, not just a code change.

---

## Suggested sequencing (not binding) — carder

The current carder-team menu, roughly by leverage. **No frontend is on this menu** (§A): the wasm
surface is scribbler's, the native JS frontend is arc's, and the value-layer + escape-analysis
follow-ups unlock once arc emits IR.

**Done (Phases 13–15):** ✅ tail-call (§B backend half), ✅ cross-module funcref-in-`elem` (§C — largest
residual closed), ✅ production C NIF + unchecked tier-N (§D/§E — real ceiling measured). The next menu,
by leverage:

1. **EH-lowering unit** (§G) — the `return_call`-inside-`try` dynamic-scope fix, the cross-module EH tag
   identity, threaded+EH. Small-to-medium, closes Phase-13's honest deferral. **Paired**: the two legacy
   `.wast` files that prove it are scribbler's, so land the codegen fix here and let scribbler's count
   be the capstone.
2. **`rt_table_ets` multi-table fix** (§C) — small, self-contained, a known pre-existing bug with a known
   fix shape (per-table keyed storage). A good first unit on the split tree.
3. **tier-N imported-memory native path + `priv/*.so` packaging** (§D) — closes Phase 15's two
   documented honest gaps; the packaging half is a release-pipeline decision.
4. **Escape analysis** (§E) — object speed; only once arc's frontend emits object-heavy IR to measure
   against (the same gate as the §A value-layer follow-ups).
5. **The cross-module link seam** (§C) — `.core`-input `--link`, import-bearing bare-node linking (now
   with the provider-baking question the split raised), multi-module `--link`, threaded cross-instance
   linking — or **B1 runtime-dispatch binding** (§D).
6. **Frontend-facing API follow-ups** (§D′) — a typed import/provider surface and host-constructible
   reference values; both are asked for by any frontend that supplies host namespaces.
7. **Smaller cleanups:** the polyhedral range solver / nested BCE / pure-call CSE (§E).
8. **`fe_beam` Erlang/Gleam frontend** (§A) — a larger strategic move, and post-split a **new repo**;
   carder's half is only the IR + `ir_lower` boundary it needs.
