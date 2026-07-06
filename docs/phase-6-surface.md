# Phase 6 — the complete WebAssembly 2.0 surface: the before/after headline

> The honest, measured record of what Phase 6 lit up in the pinned WebAssembly spec suite, what is
> still deferred, and the test file that proves each claim. Companion to the conformance image
> (`docs/wasm-conformance.svg`) and the capstone (`specs/phase-6/11-capstone.md`). All numbers are
> **measured** by `gleam test` at the pin (`WebAssembly/testsuite @ 193e551`, wabt 1.0.41), never
> promised (R16/S11). Cross-checked against `wasmtime 46.0.1` where present.

---

## The headline (measured)

| | pass | skip | fail |
|---|---|---|---|
| **Phase-5 close** (enlarged allowlist, Safe **and** Unsafe) | 21,525 | 1,257 | 0 |
| **Phase-6** (full re-vendored allowlist **with** the SIMD file set) | **46,529** | 1,768 | **0** |
| **Δ** | **+25,004** | +511 | 0 |

**Read this honestly.** Phase 6 is the largest single conformance movement in the project's
history: the pinned suite's `pass` count **roughly doubled** (+25,004) as the **59 `simd_*.wast`
files** lit up — and `fail` stayed **0** under **both** named modes (Safe/Unsafe) **and** every
shipped `state_strategy × mem_tier` binding. The entire +25,004 is SIMD execution assertions; the
+511 skip rise is the SIMD **text-format** frontend assertions the WAT parser does not read (S13, a
categorized parser gap, not a runtime gap). This is a *surface* phase — no new performance claim
beyond Phase 4 (the negative obligation, constant-space loops + preemption preserved, holds; proofs
4–5).

The `fail == 0` invariant is the whole-phase net: lighting SIMD up is only real if it lights up
*correct* — a mis-lowered `f32x4.mul` (double-rounded), a wrong `i32x4.dot_i16x8_s`, a mis-endianned
`v128.store`, or a missing SIMD-memory OOB trap would flip a formerly-skipped assertion to **fail**,
not pass.

---

## What lit up (the +25,004, by category)

| Category | What it exercises | Where it lands |
|---|---|---|
| **fixed-width SIMD** (59 files, **+25,004**) | the `v128` value + ~236 lane instructions: integer-lane arithmetic/shifts/saturating add-sub, all comparisons (→ v128 masks), bitwise + `bitselect`, boolean reductions + `bitmask`, splat/extract/replace-lane, `f32x4`/`f64x2` arithmetic (single-rounded, spec NaN/`-0.0`), convert/narrow/widen/extend/`trunc_sat`, `dot_i16x8_s`, extended-multiply, `extadd_pairwise`, `q15mulr_sat`, `shuffle`/`swizzle`, and the `v128.load*`/`store*` memory family through the bounds-checked `rt_mem` seam | full pipeline → `Simd`/`SimdShuffle`/`SimdLoad*` through `rt_simd` (emulated lane-wise, `rt_num` per lane — I3) and `rt_mem` |

Measured per-family (Safe, 59 files): **int 3,585 · float 18,834 · mem 939 · other 1,646 = 25,004
pass / 511 skip / 0 fail** (`simd_conformance_test`).

### memory64 + cross-module linking — proven by AUTHORED in-scope backstops, not the official files

The two other Phase-6 closers do **not** add suite passes at the pin, because their **official
`.wast` files are parse-blocked categorized skips** — a *tooling / WAT-text* limitation, **not a
runtime gap**:

- **`memory64.wast`** — every 64-bit `assert_return` module uses the `(module definition …)`
  module-linking form, the 2⁴⁸ hex-with-underscore literal, and the `(memory i64 (data …))`
  inline-data form; neither `wast2json` nor our WAT parser reads them at the pin (`wat_route_test`).
  A categorized file-level parse-skip, `fail == 0`, never faked.
- **`linking.wast`** — its GC typed-reference-global modules (`(ref null func)`) are interleaved
  with the in-scope function-linking modules and abort our parser (GC reftype text is out of scope).
  A categorized file-level parse-skip.

The **memory64 runtime** and **cross-module function linking** are therefore proven the P5-12 way —
by programs authored **in scope** to exercise the new nodes on purpose, driven end-to-end through
the pipeline and cross-checked against `wasmtime`:

| Closer | Authored backstop | Proven |
|---|---|---|
| **memory64 runtime** | `corpus/mem64.wat` | a `(memory i64 1)` grown past the i32 4 GiB ceiling (O(1) sparse), an i64 store/load at byte 2³²+40, a fresh region past 2³² reading zero, a grow beyond the documented page cap (`mem64_max_pages` = 2³² pages, S9) → `-1`, an access beyond current size → trap — byte-identical across Safe/Cell, portable/Threaded, Unsafe |
| **cross-module function linking** | `corpus/xlink.wast` | module `$b` imports + **calls** module `$a`'s exported functions across instances via the linker-built closure (D3a); an unsatisfied import fails closed at link (`assert_unlinkable`) — green under Safe/`cell`, identical report under `unsafe`/`portable` |

---

## The residual, fully categorized (1,768 skips — every one honest, R16/S11/D9)

No opaque number and no uncategorized skip: `skipcount_test.gleam` / `residual_audit_test.gleam`
fail red if a skip matches none of the enumerated categories (the closed-residual invariant).

| Residual category | ≈ asserts | Disposition |
|---|---|---|
| **`table_copy.wast` cross-module funcref-in-`elem`-segment init** — the verifier imports module `a`'s functions and initialises `elem` segments with `ref.func` of those *imported* functions, then dispatches via `call_indirect` | **0** (was ~1,088) | **CLOSED in Phase 14** — `table_copy.wast` is now **fully driven, 1,649/0/0**. Phase 14 landed the `RefFuncImport` IR distinction + the D3a import-adapter closure (`link.call_import` over the func-import slot), so this cross-module feature builds + dispatches. See [`phase-14-surface.md`](phase-14-surface.md). (The Phase-6 "569 pass / 1,088 residual" framing is history — a positive movement, not a residual.) |
| **SIMD text-format frontend** — `assert_malformed`/`assert_invalid` whose module is `.wat` SIMD text | **~511** | The WAT parser rejects SIMD text (S13, out of scope); a categorized parse-skip. Every **binary** SIMD assert (24,281 `assert_return` + 54 `assert_trap`) passes. |
| **post-2.0 proposals + harness paths** — GC-proposal typed references, extended-const, `return_call*` (the tail-call proposal, S12), `assert_exhaustion` (a BEAM/WASM stack-model mismatch), cross-module **mutable-state** import depth, exception-handling `(tag …)`, module-linking `(module definition …)` | ~169 | Genuinely out of scope — each a separate proposal or a named coverage gap, printed by the audit, never false-green. |

---

## The three honest scope-limits (I8 — stated in numbers, not hidden)

1. **SIMD is emulated lane-wise; there is no hardware SIMD and no speed claim (I3).** `rt_simd`
   decodes the 16-byte binary into lanes, applies the per-lane op reusing `rt_num`'s exact scalar
   semantics, and re-encodes — **faithful** (bit-exact, spec-differentially correct) but **not
   fast**. The BEAM has no vector unit; a real-SIMD tier-N NIF is deferred (the interface admits it,
   we do not build it). No performance claim beyond Phase 4's.
2. **memory64 ships a documented, spec-aligned page cap — not 2⁶⁴ allocation (I4/S9).** The runtime
   cap `Binding.mem64_max_pages` = **2³² pages = 2⁴⁸ bytes = 256 TiB** is a **sparse trap boundary**
   the `paged` backend never allocates (it grows on demand). `grow` beyond it → `-1`; an access
   beyond current size → trap. The declarable type maximum is 2⁴⁸ pages (spec §2.5). `atomics`/`nif`
   keep their 32-bit reserve and **fail closed** for an over-cap 64-bit memory — a categorized tier
   edge, not a spec divergence. memory64 ships on `paged` (+ `portable`).
3. **The cross-module drop is measured, never promised (I5/R16).** P6-10's residual audit
   **measured** that the Phase-5 ~1,088-assert residual is `table_copy.wast`'s cross-module
   funcref-in-`elem`-segment init (a deeper feature than the landed `CallImport` dispatch), and
   reports its measured disposition — not a promised flip. `cell` is the proven `linking.wast`
   target; an invasive `threaded` cross-instance reach is a **named** category, never a claim.

---

## Deferred, stated not dropped (I8)

- **relaxed-SIMD** (the separate non-deterministic proposal) → later.
- **the tail-call proposal** (`return_call`/`return_call_indirect`, post-2.0) — categorized in the
  residual (S12); maps cleanly onto the BEAM's native tail calls, a plausible fast-follow, **not**
  folded into Phase 6.
- **exception-handling / GC** (typed function refs + `struct`/`array`/`i31`) **/ stack-switching /
  the component model** — separate proposals, later.
- **tier-N numerics/SIMD + a production C NIF** — the interface + skeleton ship; the C impl needs a
  native toolchain (documented-deferred).
- **the memory optimizer** (MemorySSA + alias analysis + BCE + LICM + store→load forwarding + DSE) —
  its own performance phase.
- **the single-`.beam` runtime-dispatch B1 binding**; the **Erlang/Gleam frontend**. **WASI** stays
  an `rt_host` implementation, out of core.

---

## Phase 7 is UNBLOCKED — JS on the BEAM via Porffor

With the WebAssembly **2.0 surface complete** after Phase 6, *any Porffor application runs via 2core
on the BEAM* becomes **buildable**. Porffor's JS→WASM output — SIMD, bulk memory, reference types,
multi-value — is now fully runnable through `fe_wasm`; the remaining work is a **Porffor-ABI
`rt_host` shim** (Porffor's own console/memory/string/intrinsic ABI, not WASI) + a JS-subset
conformance harness. Phase 6 is the precondition that turns Phase 7 from "largely runnable" into a
buildable phase. **The next move is JS on the BEAM.**

---

## One line per proof → the test that proves it

| Proof | Test |
|---|---|
| 1 — SIMD spec-correct end-to-end (integer/float/memory kernels, both modes + portable, byte-identical) | `test/twocore/conformance/new_surface_test.gleam` (`simd_kernels_*`) |
| 1 — SIMD whole-suite `fail == 0` (59 files, per-family) | `test/twocore/conformance/simd_conformance_test.gleam` (P6-10) |
| 1 — SIMD byte-identical across every `state_strategy × mem_tier` + `wasmtime` differential | `test/twocore/conformance/simd_differential_test.gleam` (P6-10) |
| 2 — memory64 runs (i64 addressing, page-cap grow → -1, OOB trap, byte-identical) | `test/twocore/conformance/new_surface_test.gleam` (`mem64_runtime_*`) |
| 2 — memory64 op-by-op oracle differential | `test/twocore/runtime/rt_mem_test.gleam` (P6-08) |
| 3 — cross-module function linking (call across instances + fail-closed unlinkable) | `test/twocore/conformance/new_surface_test.gleam` (`cross_module_linking_*`) |
| 4 — conformance-neutral: Phase-1..5 corpus byte-identical across modes | `test/twocore/conformance/new_surface_test.gleam` (`phase_1_to_5_corpus_*`) |
| 4 — emitter-level byte-identity (non-SIMD/32-bit/no-import module ⇒ Phase-5 `.core`) | `test/twocore/backend/emit_core_test.gleam` (P6-06) |
| 5 — the measured skip-drop headline (`fail == 0 && pass ~doubled`, closed residual) | `test/twocore/conformance/skipcount_test.gleam` (P6-10) |
| 5 — the R16 empirical residual audit (every skip categorized) | `test/twocore/conformance/residual_audit_test.gleam` (P6-10) |
| 5 — runs-anywhere re-confirmed for the SIMD + memory64 surface (grep + executed) | `test/twocore/conformance/runs_anywhere_test.gleam` (`portable_p6_surface_*`, `portable_simd_kernels_*`, `portable_mem64_*`) |
