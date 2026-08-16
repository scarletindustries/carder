# Phase 5 — the complete WebAssembly surface (minus SIMD): the before/after headline

> The honest, measured record of what Phase 5 lit up in the pinned WebAssembly spec suite, what is
> still deferred, and the test file that proves each claim. Companion to the conformance image
> (`docs/wasm-conformance.svg`) and the capstone (`specs/phase-5/12-capstone.md`). All numbers are
> **measured** by `gleam test` at the pin (`WebAssembly/testsuite @ 193e551`, wabt 1.0.41), never
> promised (R16).

---

## The headline (measured)

| | pass | skip | fail |
|---|---|---|---|
| **Phase-4 baseline** (pinned allowlist) | 15,749 | 409 | 0 |
| **Phase-5** (enlarged allowlist, Safe **and** Unsafe — mode-neutral) | **21,525** | 1,257 | **0** |
| **Δ** | **+5,776** | +848 | 0 |

**Read this honestly.** Phase 5 is a *surface* phase, and its headline is the **pass rise (+5,776)
with `fail == 0`** — **not** a naive "skip dropped." The raw skip count *rose* (409 → 1,257)
because P5-11 **added ~30 previously-EXCLUDED `.wast` files** to the allowlist (reference-types,
bulk-memory, and `spectest`-importing files that were not counted *at all* under Phase 4). So most
of the 1,257 residual is assertions in files that never appeared in the Phase-4 denominator. The
material engine drop is visible once the categorized residual is set aside: the residual
**excluding** the cross-module function-import gap is **169**, well below the Phase-4 baseline of
409.

The suite is `fail == 0` under **both** named modes (Safe/Unsafe: 21,525 / 1,257 / 0 each) **and**
every shipped `state_strategy × mem_tier` binding (the filtered tier-matrix run, tier-touching
files only, is `fail == 0` per combo: cell/threaded × paged and cell × nif = 7,578 / 1,167 / 0;
cell/threaded × atomics = 7,544 / 1,167 / 0).

---

## What lit up (the +5,776, by category)

Whole `.wast` categories the Phase-1..4 engine skipped now run correctly:

| Category | What it exercises | Lit up by |
|---|---|---|
| **reference types** | `ref.null`/`ref.func`/`ref.is_null`, `table.get/set/size/grow/fill`, typed `select`, multiple tables incl. **multi-table `call_indirect`**, active + passive + declarative element segments, a null-slot `call_indirect` → trap *uninitialized element* | P5-03/04/05/06/07 |
| **bulk memory & table** | `memory.fill/copy/init`, `data.drop`, `table.init/copy`, `elem.drop` — spec-exact eager-bounds-trap (no partial write), memmove overlap, droppable passive segments, O(N) fuel | P5-03/04/05/06/07/08 |
| **multi-memory** | modules with >1 memory; every memory op carries a memory index; a cross-memory `memory.copy`; index-0 modules stay byte-identical to Phase-4 | P5-01/03/04/05/06/08 |
| **non-function imports + `spectest`** | imported globals/tables/memories as **provided state**; the full official `spectest` module (7 `print*` arms, `global_i32/i64/f32/f64`, `table 10 20`, `memory 1 2`); `(register …)`; fail-closed unsatisfied import at link time | P5-09 |
| **WAT text parser** | the previously **un-`wast2json`-able** files + text-format `assert_malformed`/`assert_invalid` fragments now run **from our own `parse_module`/`parse_script`** (e.g. `float_literals` +16 passes) — no external `wat2wasm` | P5-10a/10b |

The **WAT-parser-attributable slice** of the drop is the text-format assertions and un-convertible
files that only run because we now parse them ourselves (`float_literals`' text-format asserts and
the WAT-only fixtures via `wat_fixture.gleam`) — the concrete link between H5 (the parser is a
first-class frontend) and the pass rise.

---

## The residual, fully categorized (1,257 skips — every one honest, R16/D9)

No opaque number and no uncategorized skip: `skipcount_test.gleam` fails red if a skip matches none
of the enumerated categories (the closed-residual invariant).

| Residual category | ≈ asserts | Disposition |
|---|---|---|
| **cross-module wasm→wasm FUNCTION imports** — a module imports a *function* from another registered module and verifies it by calling through it (e.g. `table_copy` verifying non-zero-table copies via cross-module calls) | **~1,088** | **→ Phase 6.** A distinct cross-module function-linking feature Phase 5 **never scoped**: H4 scoped *non-function* imports (globals/tables/memories) as provided state + host functions via `spectest`; wasm→wasm *function* linking is a separate feature. Not claimed. |
| GC-proposal reference types (`anyref`/typed function refs/`arrayref`), the **extended-const** proposal, `assert_exhaustion`, cross-module **state** import, SIMD/GC out-of-scope text | ~169 | Genuinely out of scope — separate proposals / a BEAM-vs-WASM stack-model mismatch. Categorized, printed by `print_skip_reasons`, never false-green. |

---

## Deferred, stated not dropped (H8)

- **SIMD** — the `v128` value type + ~236 lane instructions, the single largest WebAssembly
  proposal → **Phase 6** (its own focused phase).
- **memory64 runtime** → **Phase 6.** The `IdxType` axis is frozen in the IR and a 64-bit memory
  **decodes + validates** (so `assert_invalid` still works and we never mis-parse a valid one), but
  lower/link **reject** it with a categorized `Memory64Unsupported` skip (R12) — no guessed page cap.
- **cross-module wasm→wasm function linking** → **Phase 6** (the ~1,088-assert residual above).
- **the Porffor JS→WASM bridge** → **Phase 7** ("JS on the BEAM").
- **GC-proposal reference types** (typed function refs + `struct`/`array`/`i31`) and the
  **extended-const** proposal — separate proposals, later.
- **a production C NIF** for tier-N memory stays documented-deferred (interface + skeleton ship).
- **the documented `spectest`-memory-under-atomics edge** — `link.spectest_export` builds the
  provided memory/table with the **paged** tier unconditionally, so a `spectest`-memory importer is
  proven under the paged combos + both full profiles (and tier-covered for bulk by the own-memory
  `memory_*` files), and excluded from the non-paged matrix combos (one file, `data.wast`) — a
  named, honest cross-unit gap, not a spec divergence.

---

## One line per proof → the test that proves it

| Proof | Test |
|---|---|
| 1 — complete new surface, green end-to-end (both modes + the portable posture) | `test/carder/conformance/new_surface_test.gleam` |
| 1 — new surface byte-identical across every `state_strategy × mem_tier` | `test/carder/conformance/refexpansion_differential_test.gleam` (P5-11) |
| 2 — the pass-rise headline (`fail == 0 && pass > baseline`) | `test/carder/conformance/conformance_test.gleam` (full Safe/Unsafe runs) |
| 2 — the closed-residual invariant (every skip categorized) | `test/carder/conformance/skipcount_test.gleam` (P5-11) |
| 2 — full-matrix `fail == 0` under every shipped binding | `test/carder/conformance/conformance_test.gleam` (matrix combos) |
| 3 — conformance-neutral: Phase-1..4 corpus byte-identical across modes | `test/carder/conformance/new_surface_test.gleam` |
| 3 — emitter-level byte-identity (index-0 module ⇒ Phase-4 `.core`) | `test/carder/backend/emit_core_test.gleam` (`mem_load_index_routing_test`) |
| 4 — runs-anywhere re-confirmed for the new surface (grep + executed) | `test/carder/conformance/runs_anywhere_test.gleam` |
| 5 — `wasmtime` differential (new surface, skips gracefully if absent) | `test/carder/conformance/refexpansion_wasmtime_test.gleam` (P5-11) |
| 5 — WAT `parse_module ≡ decode∘wat2wasm` / `parse_script ≡ wast2json` | `test/carder/frontend/wasm/wat*_test.gleam` (P5-10) |
