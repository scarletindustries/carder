# Unit P6-11 — Capstone: PHASE 6 PROVEN (the complete standardized WebAssembly engine)

> **1–3 owners · Wave C (last) · depends on the four Phase-6 freezes AND the landed work of
> P6-01…P6-10.** Read [`00-overview.md`](00-overview.md) (decisions I1–I8), the
> [`PROVISIONAL-SURFACE.md`](PROVISIONAL-SURFACE.md) (the IR4/`rt_simd`/linker surface the phase
> builds against), then — the doc whose shape and rigor this one MATCHES — Phase-5
> [`12-capstone.md`](../phase-5/12-capstone.md) (the full-matrix `driver.pipeline_with` run, the
> `Outcome` normalization, the runs-anywhere proof, the skip-count-drop headline, and the honest
> close you extend). Cite the Phase-5 [`RECONCILIATION.md`](../phase-5/RECONCILIATION.md) decisions
> **R16** (greenness is MEASURED, never promised), **R17** (the value-list run-ABI), **R18**
> (host-constructible values for the harness) where they carry Phase-6 weight. Phases 1–5 are
> complete and green: **1212 tests, 0 warnings, conformance `fail == 0` under every shipped
> `(mode × state_strategy × mem_tier)` binding — Safe/Unsafe 21525 pass / 1257 skip / 0 fail** — the
> complete standardized WebAssembly surface **minus SIMD**, byte-identical by default, runs-anywhere.
> Phase 6 is the **second phase since Phase 2 to grow the IR** (`TV128` + `ConstV128` + the `SimdOp`
> enum + the SIMD `Expr` node(s)); it closes the last three deferrals — **SIMD**, the **memory64
> runtime**, and **cross-module function linking** — so the WASM frontend becomes **genuinely,
> completely conformant** to the standardized surface.

---

## Context

Phase 6 makes one claim only a capstone can prove: **the engine now executes the *complete*
standardized WebAssembly surface — reference types, bulk memory & table ops, multiple memories,
64-bit memories that actually *run*, non-function *and function* cross-module imports, the WAT text
format, and — the keystone of this phase — fixed-width SIMD: the `v128` value type and the ~236
standardized lane instructions — and it does so spec-correctly under *both* named modes and *every*
shipped `state_strategy × mem_tier` combination each feature is defined for, while the entire
Phase-1..5 corpus and previously-passing suite stay byte-identical (I7).** Like the Phase-5 capstone
(and unlike the Phase-3/4 capstones, which added no IR nodes and no spec files and so were pure
*re-drive-the-old-corpus-under-a-new-axis* proofs), this capstone **adds surface** — the single
largest surface addition in the project's history. The pinned suite's `pass` count **roughly doubles**
as `simd/*.wast` (the largest file set in the whole testsuite, ~24.3k execution assertions) lights up;
the measured Phase-5 residual — the ~1,088-assert `table_copy.wast` block (cross-module wasm→wasm
function imports + multi-table `call_indirect`) — **flips from skip to pass** as P6-08/P6-09 land; and
`fail` stays **0**.

So this capstone owns two things the prior capstones did not: (1) an **end-to-end green proof over
the new surface** (SIMD kernels, a 64-bit-addressed memory program, a cross-module function call)
under the full mode × tier matrix each feature is defined for, and (2) the **honest,
`R16`-disciplined skip-drop headline** — before/after numbers, `fail == 0`, a *categorized* residual,
and — the load-bearing honesty of this phase — the three explicit scope-limits stated in numbers, not
hidden: **SIMD is emulated lane-wise (no hardware vectorization, no speed claim — I3/I8)**; **memory64
ships a documented, spec-aligned page cap, not 2⁶⁴ allocation (I4)**; and the **cross-module drop is
measured, never promised (I5/R16)**.

Everything fine-grained — the per-lane SIMD op semantics (`rt_simd`, P6-07); the memory64 i64-address
runtime + the page-cap trap boundary (`rt_mem`, P6-08); the linker-built closure dispatch (P6-09); the
`.ir` round-trip of the SIMD surface (P6-02); the `wast2json`-convertibility + empirical residual
audit (P6-10); the differential vs `wasmtime` (P6-10) — is **owned by units 02–10**. This unit does
**not** re-derive them; it **confirms** they are green and committed, then adds the **whole-engine
headline checkpoints** that only the terminal unit can make: the deliberately-authored complete-surface
backstop under the full mode/tier matrix, the runs-anywhere re-confirmation for the new surface, the
conformance-neutrality proof, the SVG/docs refresh, and the honest close — **and it states that
Phase 7 (JS on the BEAM via Porffor) is now UNBLOCKED: the WASM surface is complete.** This **closes
Phase 6**.

The proof surface is six proofs + one image/docs refresh:

| # | Proof | Decision |
|---|---|---|
| 1 | **SIMD spec-correct end-to-end** — a `v128` kernel (an integer-lane dot-product + a float-lane transform + a shuffle/bitselect) runs spec-correct against its spec-sourced `.expected` **and** differentially against `wasmtime`, **and** byte-identical across **both** modes × **every** shipped `(state_strategy × mem_tier)` it is defined for | I1/I2/I3/I6/I7 |
| 2 | **memory64 runs** — a 64-bit-addressed linear-memory program executes (i64 address operands, offsets > 2³²); `memory.grow` beyond the **documented spec-aligned page cap** returns `-1`; an access beyond the current size **traps `MemoryOutOfBounds`** exactly where the spec's `assert_trap` expects; a 32-bit memory stays **byte-identical**; green under `paged` (+ `portable`) | I4 |
| 3 | **cross-module function linking** — a module importing another instance's exported **function** dispatches correctly through the **linker-built closure capability**; **`linking.wast` runs green under Safe/`cell`**; an unsatisfied/mismatched import fails closed at link time (`assert_unlinkable`); **no ambient `apply` of an attacker-chosen `module:atom`** (D3a, grep-confirmed) | I5/I6 |
| 4 | **conformance-neutral** — the whole Phase-1..5 acceptance corpus + previously-passing allowlist stay **byte-identical** under both profiles and every `(state_strategy × mem_tier)`; the defaults route the new surface away (no `v128`, a single 32-bit memory, no cross-module imports ⇒ Phase-5 code) | I7 |
| 5 | **the MEASURED skip-drop headline + runs-anywhere** — the pinned suite's `pass` ~doubles as `simd/*.wast` lights up, the Phase-5 `table_copy.wast` residual flips to pass, **`fail == 0`** under the matrix, residual **categorized honestly**; a SIMD kernel + a mem64 program are **runs-anywhere re-confirmed** (tier-P `portable`, grep-verified 0 native + executed byte-identical to the `cell`/`paged` oracle) | overview §1 headline / I3/I8 |
| 6 | **honest close** — emulated SIMD (no hardware claim, no speed claim — I3), the documented mem64 page cap (not 2⁶⁴ — I4), the measured cross-module drop (I5/R16); what is deferred (relaxed-SIMD, GC, EH, the B1 binding, a tier-N NIF); and the goal the complete surface now **unblocks: Phase 7 — JS on the BEAM via Porffor** | I8 |
| — | **image + docs refresh** — `docs/wasm-conformance.svg` regenerated to the new counts; footnote → Phase-6 scope; a short `docs/phase-6-surface.md` recording the measured before/after + the categorized residual | overview §1 |

---

## Deliverables & freeze milestones

**Consumes** (every Phase-6 freeze + landed unit):

- `«IR4-FROZEN»` (P6-01) — the **`TV128` `ValType`**; the **`ConstV128(bytes)` `Value`** (exactly 16
  raw little-endian bytes, D5); the SIMD `Expr` node(s) + the **`SimdOp` enum** (I2); the SIMD-memory
  node decision (`SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane` vs extended `MemLoad`/
  `MemStore` — whichever the keystone froze); and **any new `TrapReason` (expected: none** — SIMD is
  total, SIMD memory + memory64 reuse `MemoryOutOfBounds`, unlinkable is a link-time error not a
  runtime trap).
- `«RT-SIMD-SIG»` (P6-01) + the landed **`rt_simd`** (P6-07, three passes: 07a integer / 07b float +
  conversions/narrow/widen / 07c misc + memory + shuffle) — the ~236 lane ops, bit-exact, reusing
  `rt_num` per lane.
- `«MEM64-RUNTIME»` (P6-01) + the landed **rt_mem memory64** (P6-08) — `lower`/`link` accept `Idx64`;
  a 64-bit memory runs; the **documented page cap** (`Binding.mem64_max_pages`, spec-cited) is the
  trap boundary.
- `«XLINK»` (P6-01) + the landed **cross-module linking** (P6-09) — the `ProvidedFunc` closure
  dispatch; function `link_imports` (fail-closed); the `(register …)` multi-module registry.
- Units 02–10 (landed) — `.ir` round-trips the SIMD/mem64/cross-module surface (02); decode/validate/
  lower carry it through the frontend (03/04/05); `emit_core` lowers every SIMD node through the
  `rt_simd` seam, threads i64 addressing, and emits `apply(Closure, Args)` for imported functions
  (06); `rt_simd` (07) and `rt_mem` (08) implement the runtime; the linker (09) dispatches across
  instances; the conformance expansion (10) lit up `simd/*.wast`/`memory64.wast`/`linking.wast`, owns
  the **measured** pass/skip/fail + the R16 residual audit, and holds the new surface to `wasmtime`.

**Produces** (terminal — nothing downstream depends on it): the complete-surface matrix backstop + the
new-surface runs-anywhere proof under `test/twocore/conformance/**`; the refreshed conformance image +
the `docs/phase-6-surface.md` before/after headline; and the honest close-of-phase statement in
`state.md` **announcing Phase 7 unblocked**. No publish-day-1 stub — this unit consumes every freeze
and emits nothing others build on.

---

## Files owned

- `test/twocore/conformance/new_surface_test.gleam` *(extend, single-owner — the P5-12 file)* — the
  **complete-surface backstop** (proof 1) + the **mode-neutrality** half of proof 4. Add the
  capstone-authored SIMD kernels (`simddot`, `simdxform`), the mem64 program (`mem64`), and the
  cross-module program (`xlink`) to `new_surface_programs`; each is driven through
  `driver.pipeline_with` under the three **real shipped profiles** (`profiles.safe()` /
  `profiles.unsafe()` / `profiles.portable()`), asserted (1) spec-correct against its `.expected` and
  (2) byte-identical across all three (the MODE axis; the tier axis is P6-10's `simd_differential_test`).
  Extend the neutrality test to the Phase-1..**5** corpus (the SIMD/mem64/xlink defaults route away).
- `test/twocore/conformance/runs_anywhere_test.gleam` *(extend, single-owner — the P4-11/P5-12 file)*
  — the new-surface runs-anywhere checkpoint (proof 5, dynamic + static): the SIMD kernels + the mem64
  program compile under `profiles.portable()` with **zero** native primitives, name the SIMD/threaded
  runtime families **non-vacuously**, and execute byte-identical to the `cell`/`paged` oracle. Reuses
  the existing grep + execute harness; adds the new-surface programs to its local list.
- `test/twocore/conformance/corpus/*.wat` (+ `.wasm` / `.expected`) *(add — capstone-authored, +
  reuse P6-10's)* — `simddot.wat`, `simdxform.wat` (capstone-authored, deliberately exercising the
  integer-lane / float-lane / shuffle / bitselect / lane-access families with a **scalar-observable**
  result so the numeric `.expected` format applies). **Reuse** P6-10's `simdmem.wat` / `mem64.wat` /
  `xlink.wat` where they exist (confirm, do not re-author — see §H seam).
- `docs/wasm-conformance.svg` + `scripts/gen-conformance-svg.sh` footnote *(extend)* — regenerated to
  the **new** counts (the numbers **do** move — that is the point of a surface phase); footnote →
  Phase-6 scope ("complete standardized WebAssembly surface — SIMD, memory64, cross-module linking;
  `pass` ~doubled, `fail == 0`").
- `docs/phase-6-surface.md` *(new)* — the honest before/after headline: the 21525 / 1257 / 0 Phase-5
  baseline, the post-Phase-6 measured pass/skip/fail, the category breakdown of what lit up (SIMD /
  memory64 / cross-module function linking), the categorized residual (relaxed-SIMD / GC / module-
  linking / EH / exhaustion / cross-module mutable-state depth), and the three honest scope-limits.
- `specs/state.md` *(extend)* — the Phase-6 close row + the deferred set + **Phase 7 unblocked**.
- *(confirm, do **not** re-own)* — P6-10's `simd_conformance_test.gleam` / `residual_audit_test.gleam`
  / `simd_differential_test.gleam` / the re-pinned `skipcount_test.gleam` / the `wasmtime` differential
  (proof 5's measured half + the SIMD tier sweep); P6-10's whole-suite matrix run in
  `conformance_test.gleam` (see §A — **P6-10 owns that file in Phase 6**, a deliberate deviation from
  the P5-12 shape, argued below); P6-02's `.ir` round-trip; P6-06's `emit_core` byte-identity + the
  extended D3a security-invariant test; P6-08's memory64 oracle differential; P6-09's cross-module
  link + fail-closed + D3a tests. The capstone asserts they are green and committed; it does not
  re-derive them.

> `simddot.wat` / `simdxform.wat` are fresh — no ownership collision. `new_surface_test.gleam` and
> `runs_anywhere_test.gleam` are single-owner files the capstone already owns from P5-12/P4-11 and
> extends in place. The whole-suite SIMD/mem64/linking allowlist run + the SIMD headline roll-up +
> the residual audit belong to **P6-10**; this unit owns only the **deliberately-authored**
> complete-surface backstop, the **runs-anywhere** property, the **docs/SVG**, and the **close**.

---

## Depends on

- `«IR4-FROZEN»` / `«RT-SIMD-SIG»` / `«MEM64-RUNTIME»` / `«XLINK»` (P6-01) — the frozen surface every
  proof compiles against.
- Units 02–10 (landed) — a frontend that decodes/validates/lowers the SIMD/mem64/cross-module surface,
  an `emit_core` that lowers it through the seam, `rt_simd`/`rt_mem` runtime that executes it, a linker
  that dispatches across instances, and the conformance expansion that lit up the `.wast` files and
  measured the numbers.
- `driver.pipeline_with(binding: Binding) -> Driver` (Phase-3, verified in-tree; unchanged) — the
  single binding-parameterized `decode → validate → lower → ir_to_core(_, binding) → build →
  instantiate → invoke` path. The capstone re-uses it unchanged and only enumerates bindings — it
  re-implements no compiler logic, exactly the discipline of every prior capstone.
- `combos.gleam` (Phase-4, `test/twocore/tier/`) — `shipped` / `binding_for` / `evaluate` /
  `identity_across` / `count_occurrences` / `corpus_programs` / `read_wasm`. Consumed **read-only**
  (public, D1); the capstone adds its new-surface programs to a **capstone-local** list rather than
  editing `combos.corpus_programs` (a P4-09 const — see §H).
- The landed **v128 invoke marshalling** (P6-10 §C.3) — `driver.spec_to_term` assembles the 16 raw
  little-endian bytes for a `v128` argument and `tag_term` decodes a returned `<<_:128>>`. The capstone
  drives its SIMD kernels through this ABI; where a kernel's exported result is a **scalar**
  (`extract_lane` / `any_true` / `all_true` / `bitmask`), the existing numeric `.expected` path applies
  unchanged (§B.1).

---

## A. The matrix — one binding-parameterized driver, now over the v128 surface

Every proof here holds the *program* fixed and varies the *`Binding`*, exactly as Phases 3–5 did.
Phase 3 generalized the conformance driver to `driver.pipeline_with(binding)`; Phase 4 wired
`ir_to_core` to select the `state_strategy` codegen shape + the tier `mem_module`/`table_module` from
the binding; Phase 5 grew the *IR that flows through that path* (reftypes/bulk/multi-mem) without
touching the path; Phase 6 grows it again (`TV128` + `SimdOp` + i64 addressing + the cross-module
closure) but **not the path itself**. So the capstone re-uses `driver.pipeline_with` unchanged and only
enumerates the axis bindings.

The **shipped matrix** (from `combos.shipped`, unchanged):

```gleam
combos.cell_paged        // Cell × Paged     — the oracle
combos.threaded_paged    // Threaded × Paged — == the portable core (runs-anywhere)
combos.cell_atomics      // Cell × Atomics   — tier-O O(1) memory, pdict convention
combos.threaded_atomics  // Threaded × Atomics — record-threaded O(1) memory
combos.cell_nif          // Cell × Nif       — the tier-N skeleton (Unsafe-only)
```

Each run reduces to the Phase-3 normalized `Outcome` per `(export, args)` — raw bit pattern (D5); trap
collapsed to the spec phrase via `rt_trap.spec_trap_message`; `Rejected` for a fail-closed non-build —
so two bindings are compared by a single `==` over spec-observable behaviour, **never** over `.core`
text or IR shape (which the strategy/tier is *allowed* to change). Phase-6's new observable surface is
captured by this `Outcome` with **one extension already landed in P6-10**: a **`v128` value** crosses
the run-ABI as **16 raw little-endian bytes** (a BEAM binary, riding the term ABI, `use_term_abi`
fires on `TV128` — P6-10 §C.3), and is compared **lane-wise** by the oracle (integer lanes exact;
float lanes by bit-equality-or-NaN-class, per lane — P6-10 §C.2). So:

- **A `v128` result** is observed as its 16 bytes, decoded at the expected's `lane_type` and matched
  lane-by-lane — the *only* correct comparison, because a float lane may be a spec-legal NaN whose
  payload is implementation-chosen (a raw 16-byte `==` would wrongly reject a correct result). The
  capstone's kernels sidestep even this by exporting a **scalar** (an `extract_lane` reduction), so
  they ride the byte-identical numeric `Outcome` path while exercising the full lane surface (§B.1).
- **A memory64 address width** is invisible to `Outcome` by construction: a 64-bit-memory program
  observes i64 addressing only through the values it loads/stores and the trap it raises at the cap
  boundary — both already `Outcome`s.
- **A cross-module call** is observed as the imported function's result bits (or the `assert_unlinkable`
  → `Rejected` `Outcome` when the import is unsatisfied) — no new *kind* of observation.

So the same `==`-over-`Outcome` comparison that proved Phases 2–5 correct proves Phase 6 correct — the
new surface added observables (a 16-byte lane-typed value; an i64 address; a cross-instance result),
not a new *kind* of observation.

> **Ownership deviation (argued — see "Deviations from the provisional surface").** In P5-12 the
> capstone **co-owned** `conformance_test.gleam` (the whole-suite matrix run over the enlarged
> allowlist). In Phase 6, **P6-10 owns `conformance_test.gleam`** (its Files-owned table claims it
> explicitly: "add the SIMD files to the two-profile `run_suite` + the tier matrix `run_combo`; fix
> the stale module-doc; CI right-sizing for the ~24k SIMD asserts"). Single-owner-per-file (D1) is a
> hard invariant, so the capstone does **not** re-own it — it **confirms** P6-10's enlarged-allowlist
> matrix run is green and committed, and owns only the *deliberately-authored* backstop + runs-anywhere
> + docs. The whole-suite headline is thereby P6-10's `skip_count_dropped_and_residual_is_honest_test`
> + `simd_conformance_test`; the capstone's job is the **complete-surface** end-to-end proof over
> programs authored to exercise the new nodes on purpose, plus the phase close.

---

## B. Proof 1 — SIMD spec-correct end-to-end (the v128 kernel headline)

**The bar.** A `v128` kernel executes **spec-correctly** through `load → instantiate → invoke`, under
**both** `profiles.safe()`/`unsafe()`, byte-identical across the shipped `(state_strategy × mem_tier)`
combinations it is defined for, and differentially correct against `wasmtime`. SIMD is the keystone of
Phase 6 (I1) and the single largest conformance movement in the project; the capstone proves it two
ways, coarse and fine — the whole-suite roll-up (P6-10, confirmed) and a deliberately-authored kernel
(this unit, owned).

### B.0 The `v128` value & why lane-wise correctness is the whole game

Per the WebAssembly vector-value model
(<https://webassembly.github.io/spec/core/syntax/values.html#vectors>) and the vector types
(<https://webassembly.github.io/spec/core/syntax/types.html#vector-types>), `v128` is a **128-bit
value interpreted as a packed vector of lanes** in one of six shapes — `i8x16`, `i16x8`, `i32x4`,
`i64x2`, `f32x4`, `f64x2`. At runtime (I1/D5) it is a **16-byte binary** (`<<_:128>>`), little-endian
lane layout (lane 0 = the low-order bytes), and a `ConstV128` holds the exact 16 raw bytes — so lane
values, NaN payloads, and `-0.0` are byte-exact. A SIMD op is correct iff **every lane** is correct at
its shape's interpretation; the vector-instruction semantics
(<https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions>) are defined
lane-wise, and `rt_simd` implements each op by **decode → apply `rt_num` per lane → re-encode** (I3),
so lane-wise correctness *is* the whole proof. The capstone's kernels are authored to make a single
mis-lowered lane, a wrong lane order (endianness), a double-rounded `f32x4` lane, or a mis-propagated
NaN fail on a **named program** rather than diffusely in a 24k-assert file.

### B.1 The deliberately-authored kernels (owned)

The whole-suite SIMD run (P6-10) is broad but diffuse; the capstone drives a small set of kernels
authored to exercise a specific family, each with a **scalar-observable result** (an `extract_lane`
reduction, or `i32x4.all_true` → an i32) so the numeric `.expected` format applies and the kernel
rides the **byte-identical `Outcome`** path across modes/tiers. Each is run under both profiles ×
`portable` and asserted (1) spec-correct against its `.expected`, and (2) byte-identical across all
three:

| Program | Exercises (families — enumerated in §B.2) | Spec anchor | Result observed |
|---|---|---|---|
| `simddot` | **integer lanes**: `i16x8.splat` / `i16x8.replace_lane` (pack two vectors), `i32x4.dot_i16x8_s` (the pairwise-multiply-add dot product), `i32x4.add`, `i32x4.extract_lane` (reduce) — a real dot-product kernel | vector-instructions §, `i32x4.dot_i16x8_s` (SIMD integer arithmetic) | i32 scalar (the dot product) |
| `simdxform` | **float lanes**: `f32x4.splat`, `f32x4.mul`, `f32x4.add`, `f32x4.min`/`f32x4.max` (NaN/`-0.0` corners), `f32x4.sqrt`; **lanewise misc**: `i8x16.shuffle` (16 immediates), `v128.bitselect`, `i32x4.eq` (→ a mask), `f32x4.extract_lane` | vector-instructions §; IEEE-754 single-rounding + SIMD NaN propagation (I3) | f32 bits (a transformed lane) |
| `simdmem` *(reuse P6-10)* | **SIMD memory**: `v128.load` / `v128.store`, `v128.load32_splat`, `v128.load32_lane` / `v128.store32_lane`, an **OOB access → trap `out of bounds memory access`** (no host escape); little-endian lane layout | vector memory instructions; the bounds-checked `rt_mem` seam (I6) | i32 scalar (a loaded lane) + the trap phrase |

- **Every pure SIMD op is total (I3/I6).** `simddot`/`simdxform` never trap — integer lanes wrap
  two's-complement at the *lane* width; `dot_i16x8_s` is the exact `Σ (a_i·b_i)` over adjacent i16
  lane pairs into i32 lanes (spec-defined, no overflow trap); float lanes are IEEE-754 with `f32x4`
  rounded to single precision **after every op** and `min`/`max` returning the spec NaN/`-0.0` result.
  The **only** trap on the whole SIMD surface is `simdmem`'s out-of-bounds access, which routes through
  the **existing bounds-checked `rt_mem` seam** → `MemoryOutOfBounds` **before any partial effect**
  (no new `TrapReason` — I1/I6).
- **The scalar-observable discipline (why the kernels export scalars).** A `v128` argument/result rides
  the term ABI (16 raw bytes, P6-10 §C.3) and is judged lane-wise by the oracle — correct, but the
  capstone's backstop deliberately exports a **scalar** so the kernel rides the exact byte-identical
  numeric `Outcome` used since Phase 2 (`combos.evaluate` → `identity_across`). This makes a cross-mode
  or cross-tier divergence a plain `Int`/trap-phrase mismatch on a named program — the strongest,
  simplest failure signal — while the *internal* computation exercises splat/replace-lane/arith/dot/
  shuffle/bitselect/compare/extract-lane end to end. (The full `v128`-in / `v128`-out lane-wise path is
  proven by the ~24.3k `simd/*.wast` `assert_return`s P6-10 drives; the capstone need not re-derive it.)

### B.2 The SIMD op families the whole suite lights up (enumerated, spec-cited)

The capstone confirms P6-10's whole-suite SIMD run is green (`fail == 0`), which is the exhaustive
proof over the **59 `simd_*.wast` files** (~25,515 assertions, measured at the pin). For the close's
honesty and to name what "complete SIMD" means, the families — each held to the fixed-width SIMD
instruction set and executed lane-wise by `rt_simd` reusing `rt_num` (I3) — are:

- **Integer-lane arithmetic** (`i8x16`/`i16x8`/`i32x4`/`i64x2`): `add`, `sub`, `mul` (**no
  `i8x16.mul`** — the spec omits it), `neg`, `abs`, `min_s`/`min_u`/`max_s`/`max_u`, `avgr_u`
  (`i8x16`/`i16x8` only), `i8x16.popcnt` — two's-complement-exact at the **lane** width.
- **Integer-lane shifts** (`shl`/`shr_s`/`shr_u`): shift count is a scalar i32 **masked mod the lane
  bit-width** (`simd_bit_shift.wast`).
- **Comparisons** (all shapes, → a v128 all-ones/all-zeros mask per lane): `eq`, `ne`, `lt_s`/`lt_u`,
  `le_s`/`le_u`, `gt_s`/`gt_u`, `ge_s`/`ge_u` (integer); `eq`/`ne`/`lt`/`le`/`gt`/`ge` (float).
- **v128 bitwise** (shape-agnostic): `not`, `and`, `or`, `xor`, `andnot`, `bitselect`.
- **Boolean reductions / mask**: `v128.any_true`, `iNxM.all_true`, `iNxM.bitmask`.
- **Lane access / build**: `iNxM.splat` / `fNxM.splat`; `extract_lane_s`/`extract_lane_u` (where
  applicable) / `extract_lane`; `replace_lane` — the lane immediate is validated in range (P6-04).
- **Float-lane arithmetic** (`f32x4`/`f64x2`): `add`, `sub`, `mul`, `div`, `neg`, `abs`, `sqrt`,
  `min`, `max`, `pmin`, `pmax`, `ceil`, `floor`, `trunc`, `nearest` — **IEEE-754-exact with f32
  single-rounding + spec NaN propagation/canonicalization**; `min`/`max` vs `pmin`/`pmax` differ
  exactly on NaN & `-0.0` per spec.
- **Conversions / narrow / widen / extend**: `i32x4.trunc_sat_f32x4_s/u`,
  `i32x4.trunc_sat_f64x2_s/u_zero`, `f32x4.convert_i32x4_s/u`, `f32x4.demote_f64x2_zero`,
  `f64x2.convert_low_i32x4_s/u`, `f64x2.promote_low_f32x4`, `i8x16.narrow_i16x8_s/u`,
  `i16x8.narrow_i32x4_s/u` (saturating), `iNxM.extend_low/high_*_s/u` — saturating ops saturate
  exactly, no trap.
- **Extended / pairwise / dot / q15**: `iNxM.extmul_low/high_*_s/u`, `iNxM.extadd_pairwise_*_s/u`,
  `i32x4.dot_i16x8_s`, `i16x8.q15mulr_sat_s`.
- **Byte shuffle / swizzle**: `i8x16.shuffle` (16 immediate lane indices 0..31, validated by P6-04),
  `i8x16.swizzle` (dynamic v128 indices; OOB index → 0).
- **SIMD memory**: `v128.load`/`store`; `v128.load{8,16,32,64}_splat`; `v128.load{8x8,16x4,32x2}_{s,u}`
  (extending); `v128.load{32,64}_zero`; `v128.load/store{8,16,32,64}_lane` — all through the
  bounds-checked `rt_mem` seam → trap `MemoryOutOfBounds` on OOB; little-endian layout exact.

### B.3 Byte-identical across modes/tiers + the `wasmtime` differential

- **Mode axis (owned here).** `simddot`/`simdxform`/`simdmem` run under `profiles.safe()` (Baseline
  optimizer + enforcing fuel), `profiles.unsafe()` (Aggressive optimizer + open runtime), and
  `profiles.portable()` (Threaded/Paged/`bif`), and produce the **same `Outcome`** — because
  WebAssembly is deterministic and the mode/optimizer/tier changes no spec-observable answer (I7). A
  pure SIMD op is a candidate for const-fold/DCE (P6-01/effect.gleam classifies `Simd` as **pure**);
  an Aggressive-optimizer pass that mis-folded a lane, reordered an effectful `SimdStore`, or dropped
  a needed compute would diverge **here** on the exact program under the exact mode.
- **Tier axis (confirmed, P6-10).** The pure SIMD ops are **tier-invariant** (no instance state — they
  are `rt_simd` `bif` functions over binaries), like the pure-numeric files; the **SIMD-memory** ops
  are **tier-touching** (a mis-endianned `atomics` `v128.store` must still produce the byte-identical
  memory image). P6-10's `simd_differential_test` drives an authored SIMD corpus across every shipped
  `(state_strategy × mem_tier)` and asserts byte-identity; the capstone **confirms** it is green and
  its own mode-axis backstop is the orthogonal cross-check.
- **`wasmtime` differential (confirmed, P6-10 §F).** The kernels' expected values are, wherever
  `wasmtime 46.0.1` is on `PATH`, cross-checked against a conformant engine — not only against the
  baked `.wast`. Because the kernels export **scalars**, the existing scalar CLI marshalling suffices
  (a `v128` op is fully observed through a scalar lane read; the baked values remain the primary
  Tier-A oracle). It **skips gracefully** when `wasmtime` is absent. A `simddot` result that matched
  its baked `.expected` but diverged from `wasmtime` (a stale pin, a lane-order bug the baked value
  also encoded) would go red in P6-10's differential.

---

## C. Proof 2 — memory64 runs (the 64-bit program + the documented cap)

**The bar (I4, R12's deferred half).** Phase 5 shipped memory64 **decode + validate** and made
`lower`/`link` **reject** `Idx64` (`Memory64Unsupported`, a categorized skip). Phase 6 removes the
rejection and makes a 64-bit memory **run**. The capstone drives a deliberately-authored `mem64`
program (reused from P6-10's corpus) and asserts, spec-correct under the tiers memory64 is defined for:

- **i64 addressing executes.** `mem64` declares a `(memory i64 …)`, does `i64`-addressed loads/stores
  with an **offset > 2³²**, and observes the loaded value bits — the memory-index/address plumbing
  threads the i64 address width through the seam (`emit_core`), and a 32-bit memory in the same suite
  stays **byte-identical** (proof 4). Spec anchor: the memory64 proposal + the memory instructions
  (<https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions>) with an i64
  address type; `memory.size`/`memory.grow` take/return **i64** page counts.
- **The page cap is the load-bearing honesty point (I4).** We do **not** allocate 2⁶⁴ bytes. A
  **documented implementation limit** — `Binding.mem64_max_pages`, the exact constant pinned by P6-08
  against the memory64 spec (the standardized max is 2⁴⁸ bytes ⇒ 2³² pages; a real engine caps lower —
  P6-08 picks honestly with a citation, never a guess) — bounds a 64-bit memory. `mem64` asserts the
  **two spec-observable behaviours at the boundary**:
  - `memory.grow` beyond the cap returns **`-1`** (grow never traps — R-consistent with the 32-bit
    rule); the memory is unchanged.
  - An access beyond the **current** size **traps `MemoryOutOfBounds`** (the spec phrase
    `"out of bounds memory access"` via `rt_trap.spec_trap_message`) exactly where the spec's
    `assert_trap` expects — **before any partial write** (I6). The `paged` backend grows on demand, so
    the cap is a **trap boundary**, not a reservation.
- **Tier reach — honest (I4, argued §"Deviations").** memory64 ships on **`paged` (+ `portable`)**.
  `atomics`/`nif` keep their 32-bit reserve model and **fail closed** for a 64-bit memory whose
  effective size exceeds the reserve (no silent fallback — the existing atomics fail-closed gate). So
  the `mem64` backstop is asserted under `cell/paged`, `threaded/paged`, and `portable`; an over-cap
  64-bit `atomics` binding is a **categorized tier edge** (mirroring the P5-12 `spectest`-memory-under-
  atomics honesty + `matrix_skip_spectest_state`), reported honestly, never claimed. `memory64.wast`'s
  in-scope asserts run green via the WAT route (P6-10 §E — the file is un-`wast2json`-able at the pin,
  so its 9 in-scope `(module (memory i64 …))` modules run through **our own `parse_script`**; the one
  `(module definition …)` module-linking form → a categorized parse-skip).
- **Every access stays bounds-checked → trap (I6).** The worst case of a 64-bit bounds bug is a
  wrong/missing trap or a node-safe crash, **never a host escape** — the same invariant Phase 2 proved
  for 32-bit memory, now over i64 arithmetic (BEAM bignums; no native code — proof 4 re-confirms it
  under `portable`).

The capstone **confirms** P6-08's memory64 oracle differential (the op-by-op microscope) is green; it
adds only the end-to-end `mem64` backstop + the cap-boundary trap/grow assertions + the byte-identity
of the 32-bit path.

---

## D. Proof 3 — cross-module function linking (`linking.wast` green under Safe/cell)

**The bar (I5).** Phase 5 wired imported **state** (globals/tables/memories) + the `spectest` module,
and `link.gleam` already **matched** `ProvidedFunc(ty)` signatures — but generated code could not
*call* an imported function living in another module's instance (the measured ~1,088-assert Phase-5
residual, `table_copy.wast`). Phase 6 closes it, and the capstone proves it end-to-end:

- **The linker-built closure capability (D3a-clean).** A `ProvidedFunc` carries a first-class `fun`
  value the **linker** builds, capturing the target instance + its exported function (`fn(args){
  a_instance:f(args) }`, or the threaded-state analogue — P6-09). The generated caller lowers an
  imported-function call to **`apply(Closure, Args)` over the handed-in closure** — a **capability**,
  exactly like `externref` and `call_host`, held by its **positional import slot** (R4: positional,
  name-free), **NOT** an ambient `apply` of an attacker-chosen `module:atom`. The capstone drives
  `xlink` (module B imports module A's exported function and calls it across instances) and asserts the
  call result is spec-correct.
- **`linking.wast` green under Safe/cell (the explicit bar).** The capstone confirms P6-10's WAT-route
  run of `linking.wast` (133 asserts: 65 `assert_return` + 25 `assert_trap` + 43 `assert_unlinkable`)
  is **green under Safe/`cell`** — the honest first target (I5): cross-instance calls compose cleanly
  under `cell` (each instance owns its pdict/process state). The 28 typed-reference-global forms (GC
  syntax) stay a **categorized** parse-skip (P6-10 §E). Spec anchor: §7 embedding
  (<https://webassembly.github.io/spec/core/appendix/embedding.html>); the reference interpreter's
  `(register …)` mechanism.
- **Fail-closed on an unsatisfied/mismatched import (I6/H6).** `link_imports` extends to functions: an
  unsatisfied or signature-mismatched function import is a **link-time failure** → `assert_unlinkable`
  → a `Rejected` `Outcome`, reached identically under every binding. `xlink` includes an
  unsatisfied-import case asserting the `Rejected` outcome (a silent link would be ambient authority —
  the whole point of D3a). The capstone **confirms** P6-09's fail-closed + D3a security tests are green;
  proof 5's runs-anywhere grep is the structural cross-check (no `apply(` of a runtime-named atom in the
  generated `.core`; the closure comes from the positional import slot).
- **State-strategy reach — honest (I5, argued §"Deviations").** `cell` is the Safe default and the
  proven target for `linking.wast`. The `threaded` cross-instance case (calling into B means running
  B's functions against B's state record) is **categorized honestly** if it proves invasive under the
  E5 isolation model — a named tier edge, exactly as P5 categorized `spectest`-memory-under-atomics.
  Lighting up `linking.wast` under one profile is a **real** conformance win; the capstone reports the
  reach it measured, never a promised one (R16).
- **Per-instance policy (I6, §13).** A Safe instance importing an Unsafe instance's function is governed
  by the **existing per-instance policy** — the callee runs under its own linked runtime; the instance
  is the unit of policy. The capstone confirms P6-09 preserved this; it does not re-derive it.

---

## E. Proof 4 — conformance-neutral (the whole Phase-1..5 corpus byte-identical, I7)

**The bar (I7).** A module with **no `v128`**, a **single 32-bit memory**, and **no cross-module
imports** compiles **byte-identically** to Phase-5. The IR grew (`TV128`/`ConstV128`/`SimdOp`/the SIMD
`Expr` node(s)), but the *defaults* route the new surface away: no `Simd*` node is emitted; `memories =
[MemoryDecl(_, _, Idx32)]`; no `ProvidedFunc` closure is threaded. So the entire Phase-1..5 acceptance
corpus and every previously-passing allowlist assertion must produce the *same* `Outcome` under
Phase-6 code as they did before.

Two assertions carry it, and the point of proof 4 is that they did **not move**:

- **The mode-axis corpus neutrality (owned here).** `new_surface_test.gleam`'s
  `phase_1_to_5_corpus_conformance_neutral_test` (extended from the P5-12 Phase-1..4 version) re-runs
  `combos.corpus_programs` (the pure-numeric, memory, table, global, trap programs) **and** the Phase-5
  new-surface programs (`reftab`/`bulkmem`/`multimem`) under Safe and Unsafe Phase-6 code, asserting the
  **same `Outcome`** under both and each matching its spec-sourced `.expected`. A Phase-6 change that
  perturbed a Phase-5 result — a `TV128` arm leaking into a numeric match, an effect-analysis miss
  letting the Aggressive optimizer reorder a legacy state op now that `Simd` joined the pure set, an
  i64-address plumbing change touching the 32-bit path — would diverge **here**.
- **The prior allowlist counts are unchanged where the category is unchanged (confirmed).** The
  pure-numeric files and the Phase-2..5 memory/table/global/reftype/bulk files stay at their Phase-5
  pass counts under both profiles and every combo (their skips only *drop* where a formerly-skipped
  in-file assert lit up — never rise). P6-10's `skipcount_test` re-pin asserts `pass` **strictly rose**
  and no formerly-passing assert flipped to skip/fail; the capstone confirms it.

The strongest form of proof 4 is **byte-level, at the emitter**: for a Phase-5 module (no `v128`, one
32-bit memory, no cross-module imports), the Phase-6 `emit_core` output is **textually identical** to
what Phase-5 emitted. **Unit 06 owns that emitter-level byte-identity test** (the H7/I7
default-neutrality assertion — the provisional §H "assert this, H7-style"); the capstone **confirms**
it is green in `gleam test` and adds the whole-suite behavioural neutrality above. (The capstone does
not re-own an `emit_core` test — D1.)

---

## F. Proof 5 — the MEASURED skip-drop headline + runs-anywhere re-confirmed

### F.1 The headline — `pass` roughly doubles, `fail == 0`, residual categorized (MEASURED, R16)

Phase-6's headline is the largest one-shot conformance movement in the project: the pinned suite's
`pass` **roughly doubles** as the 59 `simd_*.wast` files light up, *and* the Phase-5 residual falls as
cross-module function linking + the memory64 runtime land. This is the honest measurement, reported
before/after with a categorized residual (R16 — greenness is measured, never promised). The **exact
post-Phase-6 integers are measured by P6-10's run and recorded by the capstone in
`docs/phase-6-surface.md`**; this proof pins the **shape and the invariants**, not magic constants.

**The baseline (measured, committed — Phase-5 close):**

| | pass | skip | fail |
|---|---|---|---|
| **Phase-5** (enlarged allowlist, Safe **and** Unsafe) | 21,525 | 1,257 | 0 |

The 1,257 residual is dominated by the **~1,088-assert `table_copy.wast` block** (cross-module wasm→wasm
function imports + multi-table `call_indirect`) + ~169 genuinely out-of-scope.

**The after (the measured shape P6-10 demonstrates, confirmed by the capstone):**

| Movement | Measured at the pin | Where it lands |
|---|---|---|
| **SIMD lights up** (59 files) | **+24,281 `assert_return`** + 54 `assert_trap` (SIMD-mem OOB) + 671 `assert_invalid` + 509 `assert_malformed` = **~25,515** | full pipeline → `Simd`/`SimdShuffle`/`SimdLoad*` through `rt_simd`/`rt_mem` |
| **cross-module fn linking + multi-table CI** | `table_copy.wast`'s **1,649 asserts** (443 return + 1,206 trap) flip **skip → pass** | P6-09 (closure dispatch) + the landed multi-table `call_indirect` |
| **memory64 runtime** | `memory64.wast`'s **45 `assert_return`** (+ 14 `assert_invalid`) via the WAT route | P6-08 (i64 addressing + the page-cap trap boundary) |
| **cross-module linking** | `linking.wast`'s in-scope function/table/memory asserts via the WAT route | P6-09 + P5-09 |

So **`pass` roughly doubles** (from 21,525) — the single largest conformance movement in the project's
history — and the **Phase-5 residual falls** as the `table_copy.wast` block flips to pass. The capstone
**confirms** P6-10's `skip_count_dropped_and_residual_is_honest_test` asserts, over the enlarged suite:

```gleam
assert total.fail == 0                     // the hard invariant — no category lit up wrong
assert total.pass > phase5_baseline_pass   // SIMD ~doubled the suite (measured, > 21525)
assert total.skip <= max_residual_skips    // re-pinned ceiling (measured)
assert list.filter(total.skips, is_cross_module_fn) == []   // the Phase-5 gap is GONE, not re-labelled
assert list.filter(total.skips, is_multi_table_ci) == []    // measured closed
// every residual skip matches one enumerated honest category (the closed-residual invariant, D9)
```

- **`fail == 0` is the hard invariant.** Lighting SIMD up is only real if it lights up *correct*: a
  mis-lowered `f32x4.mul` (double-rounded), a wrong `dot_i16x8_s`, a mis-endianned `v128.store`, or a
  wrong null-slot trap would flip a formerly-skipped assertion to **fail**, not pass. `fail == 0` over
  the enlarged suite is the whole-phase net.
- **The residual is categorized, honestly (I8, R16 — confirmed by P6-10's `residual_audit_test`).**
  Whatever still skips after Phase 6 is stated by category, never an opaque number: **relaxed-SIMD**
  (the separate non-deterministic proposal → later); **GC-proposal typed references** (`linking.wast`'s
  `(ref null func)` globals, arrayref-tainted asserts → later); **module-linking / component-model
  syntax** (`(module definition …)` → later); **exception-handling** (`(tag …)` → non-goal);
  **`assert_exhaustion`** (a BEAM/WASM stack-model mismatch, a categorized skip since Phase 1);
  **cross-module MUTABLE-state depth** (a later module importing a registered module's *mutable*
  table/memory, incl. `simd_linking.wast`'s `(mut v128)` global import — reported honestly if invasive
  under the E5 isolation model). Every one is a **named** category printed by `print_skip_reasons`,
  never a silent drop or a false green.

The honest reading: Phase 6 does **not** reach 0 skips (relaxed-SIMD/GC/EH are separate proposals) — it
reaches **"the complete standardized WebAssembly surface"**, and says so in numbers.

### F.2 Runs-anywhere re-confirmed for the new surface (I3/I6 — the runs-anywhere headline extends)

Phase 4 proved the tier-P `portable` build (`Threaded` state + `Paged` memory + `bif` numerics, Safe)
runs the Phase-4 corpus on a bare BEAM; Phase 5 re-confirmed it for reftypes/bulk/multi-mem. Phase 6
grew the surface again, so the property must be **re-confirmed for the SIMD + memory64 nodes**: a SIMD
kernel and a 64-bit-addressed memory program must *also* run under `portable` with no native code and
no crashable instance state. `runs_anywhere_test.gleam` extends its existing harness (unchanged shape)
with the new-surface programs `["simddot", "simdxform", "simdmem", "mem64"]`:

**(a) Grep-verified (static).** The `profiles.portable()` `.core` of each new-surface program links
**zero** native primitives and — for the pure SIMD kernels — emits **zero** `rt_state` instance-cell
seam, while **non-vacuously** naming the runtime families the new nodes route through:

```gleam
// The new nodes carry the SAME zero-native / zero-instance-cell property (G1/G6):
for name in ["simddot", "simdxform", "simdmem", "mem64"] {
  let core = portable_core(name)
  assert count(core, "atomics") == 0 && count(core, "ets") == 0
  assert count(core, "persistent_term") == 0 && count(core, "load_nif") == 0
}
// Non-vacuity: the new nodes DO route through the pure-BEAM runtime (a real replacement, not absence):
assert count(portable_core("simddot"),   "rt_simd") > 0    // SIMD lane ops are pure rt_simd bif fns
assert count(portable_core("simdxform"), "rt_simd") > 0
assert count(portable_core("simdmem"),   "rt_simd") > 0    // SIMD-memory: lane-assembly via rt_simd…
assert count(portable_core("simdmem"),   "rt_state") > 0   // …+ the memories vector in the record
assert count(portable_core("mem64"),     "rt_state") > 0   // i64 addressing threads the record
```

> **Seam note (P6-07/08 naming).** `rt_simd` (the module name) is the stable non-vacuity token for the
> pure SIMD path — the exact per-op function atoms (`i32x4_add`, `f32x4_mul`, `i32x4_dot_i16x8_s`, …)
> are **owned by P6-07**. The SIMD-memory threaded head + the memory64 threaded accessor are **owned by
> P6-07/08** (whether the SIMD-memory family reuses the P5 `'t_load'`/`'t_store'`/`'t_load_at'` family
> at a 16-byte width or gets a dedicated `'t_v128_load'` head is P6-01's SIMD-memory-node decision).
> The capstone greps for whatever names those units froze; the tokens above follow the frozen set,
> flagged in Open questions so the reconcile pass keeps them in sync (exactly the P5-12 seam note).
> **Crucially, the pure SIMD kernels (`simddot`/`simdxform`) have NO memory ⇒ NO instance cell at
> all** — the cleanest non-vacuity: `rt_simd` present, native zero, `rt_state` absent (a pure lane
> computation over `v128.const`/scalar-splat operands).

**(b) Executed (dynamic).** The new-surface corpus runs under `profiles.portable()` through
`load → instantiate → invoke` on a bare BEAM, **byte-identical** to the `cell`/`paged` oracle
(`profiles.safe()`) — values and traps alike. This re-confirms that the SIMD lane ops (pure `rt_simd`
over binaries), the SIMD-memory family (through the immutable-binary `rt_mem`), and the i64 addressing
(BEAM bignums, no native) all execute on a bare BEAM without a native backend.

**The security posture (I6, G6).** Because no native code is linked, the worst case of a lane/bounds
bug in the new surface under `portable` is a **wrong/missing trap or a node-safe process crash — never
a host escape**. A `v128` is an **opaque 16-byte value** in Safe mode — it cannot address memory except
through the checked `rt_mem` seam (I6); there is no SIMD division-trap and no partial effect. The i64
address arithmetic is exact bignum arithmetic bounded by the documented page cap. This is the same
"runs on a bare BEAM, provably unable to take over the VM" property (spec §7 *Embedding*), now covering
the **whole** standardized surface. The one honest caveat is unchanged: a Safe `portable` build keeps
the node-safe tier-O `rt_meter` fuel counter + `rt_host` policy cell (pdict, present on every BEAM) —
asserted *present*, exactly as the Phase-4 proof documents. **Fuel note (I3/R9):** SIMD ops are
per-instruction `charge`d like any op; a lane-wise loop over a large memory stays constant-space +
preemptible (no new unbounded loop — the ~236 ops are each a fixed-cost lane transform).

---

## G. Conformance refresh + the honest close (Phase 7 UNBLOCKED)

**Image refresh.** Regenerate `docs/wasm-conformance.svg`
(`RUN_VENDOR=1 scripts/gen-conformance-svg.sh`) to the **new** counts (the numbers **do** move — that
is the point of a surface phase; `pass` roughly doubles). Update the generator footnote from the
Phase-5 text to **"Phase 6: the complete standardized WebAssembly surface — fixed-width SIMD (`v128` +
the ~236 lane instructions, emulated lane-wise), the memory64 runtime (documented spec-aligned page
cap), and cross-module function linking; `pass` roughly doubled, `fail == 0` under every shipped tier.
Residual out of scope: relaxed-SIMD, GC-proposal typed references, module-linking, exception-handling
(each a separate proposal)."** The generator reads the `TOTAL` line from the same conformance test, so
the image tracks the enlarged allowlist automatically.

**The before/after doc (`docs/phase-6-surface.md`).** A short, honest artifact (companion to
phase-5-surface.md):

- the **21,525 / 1,257 / 0** Phase-5 baseline and the post-Phase-6 pass/skip/fail (**measured**);
- the **category breakdown** of what lit up (SIMD ~+24.3k `assert_return`; `table_copy.wast`'s
  cross-module-fn + multi-table block flipped to pass; memory64 via the WAT route; `linking.wast` via
  the WAT route), with the SIMD-attributable slice called out;
- the **categorized residual skips** (relaxed-SIMD / GC typed refs / module-linking / EH /
  `assert_exhaustion` / cross-module mutable-state depth);
- the **three honest scope-limits** (see below);
- one line per proof pointing at the test file that proves it.

**The honest close of Phase 6 (committed in `state.md`):**

- **Proved:** the engine executes the **complete standardized WebAssembly surface** — everything Phase 5
  proved (reference types, bulk memory & table ops, multiple memories, non-function imports + `spectest`
  + `(register …)`, the WAT text parser) **plus** the three Phase-6 closers: **fixed-width SIMD** (the
  `v128` value type + the ~236 standardized lane instructions — integer/float lane arithmetic,
  comparisons, bitwise, shifts, shuffle & swizzle, splat/extract/replace-lane, narrow/widen/extend/
  convert/trunc_sat, dot product, extended-multiply, pairwise, boolean reductions, bitmask, q15, and
  the v128 memory load/store family — **bit-exact and spec-differentially correct**); the **memory64
  runtime** (i64-addressed linear memory with a documented, spec-aligned page cap); and **cross-module
  function linking** (a module dispatching to another instance's exported function via a build-
  constructed closure capability, `linking.wast` green under Safe/`cell`). All **spec-differentially
  correct** (held to the baked `.wast` + `wasmtime`), under **both modes** and **every shipped
  `state_strategy × mem_tier`** each feature is defined for, **conformance-neutral by default** (I7),
  and **runs-anywhere** for the new surface (tier-P `portable`, grep-verified + executed). The
  **`pass` count roughly doubled** with `fail == 0`.
- **The three honest scope-limits (I8 — stated in the close, not hidden):**
  1. **SIMD is emulated lane-wise; there is no hardware SIMD and no speed claim (I3).** `rt_simd`
     decodes a 16-byte binary, applies the per-lane op reusing `rt_num`'s exact scalar semantics, and
     re-encodes — **faithful (bit-exact, spec-differentially correct) but not fast**. The BEAM has no
     vector unit; a real-SIMD **tier-N NIF** is deferred (the interface admits it, we do not build it).
     No performance claim beyond Phase 4's; the SIMD obligation is correctness, and the negative perf
     obligation (constant-space + preemption preserved, no regression) is carried by proofs 4–5.
  2. **memory64 ships a documented, spec-aligned page cap — not 2⁶⁴ allocation (I4).** We do not
     reserve 2⁶⁴ bytes; `Binding.mem64_max_pages` is a real constant with a spec citation (P6-08), a
     **trap boundary** not a reservation. `atomics`/`nif` fail closed for a genuinely-huge 64-bit
     memory (no silent fallback); memory64 ships on `paged` (+ `portable`). The over-cap 64-bit
     `atomics` binding is a **categorized tier edge**, not a spec divergence.
  3. **The cross-module drop is measured, never promised (I5/R16).** P6-10's residual audit **measured**
     that the Phase-5 ~1,088-assert residual is the `table_copy.wast` block (needing *both* cross-module
     function dispatch *and* multi-table `call_indirect`), and reports its **measured** flip to pass —
     not a promised one. The `threaded` cross-instance reach is reported as measured (`cell`-first for
     `linking.wast`); an invasive `threaded` edge is a **named** category, not a claim.
- **Deferred, stated not dropped (I8):** **relaxed-SIMD** (the separate non-deterministic proposal) →
  later; the **Erlang/Gleam frontend**; **exception-handling / GC** (incl. GC-proposal typed function
  references + `struct`/`array`/`i31`) **/ stack-switching / the component model**; the single-`.beam`
  runtime-dispatch **B1** binding; **tier-N numerics/SIMD** + a production **C NIF** (interface +
  skeleton ship, the C impl needs a native toolchain); the **memory optimizer** (its own performance
  phase — MemorySSA + alias analysis + BCE + LICM + store→load forwarding + DSE). **WASI** stays an
  `rt_host` implementation, out of core.
- **The goal the complete surface now UNBLOCKS — Phase 7: JS on the BEAM via Porffor.** With the WASM
  surface **complete** after Phase 6, *any Porffor application runs via 2core on the BEAM* becomes
  **buildable**. Porffor's JS→WASM output — which emits SIMD, bulk memory, reference types, and
  multi-value — is now fully runnable through `fe_wasm`; the remaining work is a **Porffor-ABI
  `rt_host` shim** (Porffor's own runtime ABI — its console/memory/string/intrinsic imports, not WASI)
  + a JS-subset conformance harness. Phase 6 is the **precondition that turns Phase 7 from
  "largely runnable" into a buildable phase.** The capstone states this explicitly in the close: the
  surface is complete; Phase 7 is unblocked.

---

## Effect / soundness / security note

- **No ambient authority survives the new surface (D3a/I6).** The SIMD seam emits fixed
  `twocore@runtime@rt_simd@*` module atoms with literal function names (the `SimdOp`→`rt_simd` binding
  chokepoint, exactly like `NumOp`→`rt_num`, D6 — neutral op names, never WASM opcode strings). The
  **cross-module function call is `apply(Closure, Args)` over a linker-built closure held by its
  positional import slot** — a capability supplied at link time, **never** an ambient `apply` of an
  attacker-named `module:atom` looked up at runtime. A `v128` is an **opaque 16-byte value** Safe code
  can hold/pass/compute-on but that can address memory only through the checked `rt_mem` seam. Unit 06
  extends the D3a security-invariant test to the SIMD nodes + the closure dispatch (the no-ambient-
  authority proof); proof 5's grep is the structural cross-check (no `apply(` of a runtime-named atom).
- **Every new op is bounds-/type-checked → trap or is total (I6).** SIMD lane ops are **pure/total** (no
  traps — saturation replaces overflow-trap; there is no SIMD division-trap); their **only** trap
  surface is the SIMD memory load/store → `MemoryOutOfBounds` **before any partial write**, via the
  existing bounds-checked `rt_mem` seam. memory64 keeps every access bounds-checked → trap, with the
  page cap as a hard trap boundary. An unsatisfied/mismatched cross-module import is a **link-time**
  `Rejected` outcome, not a runtime trap. The worst case of a lane/bounds/link bug is a wrong/missing
  trap, a `Rejected` build, or a node-safe crash — **never a host escape**. A tier cannot be unsound and
  pass: an unsound `v128.store` (wrong endianness, a partial write on a trap) or a wrong lane changes an
  `Outcome`, so "green" means *every observable was preserved across every tier and both modes*, not
  "it compiled." Proof 1's kernels + P6-10's whole-suite run are the net; units 07/08's oracle
  differentials are the op-by-op microscope behind it.
- **Floats-as-bits (D5) unchanged, now per lane.** A `v128` is stored as its raw 16 bytes; float lanes
  are compared by bit-equality-or-NaN-class per lane (the same authority as scalar floats, reused — not
  re-implemented). NaN payloads and `-0.0` stay byte-identical across `paged`/`atomics`/`threaded` for
  every SIMD-memory op, and a memory64 `i64` address / a loaded `f64` lane is still a raw bit pattern,
  never a BEAM-double round-trip.
- **Fail-closed default (D4).** Every run that does not name a tier-P/N posture or an Unsafe mode is
  `cell`/`paged`/Safe; the new surface adds observables, not a new default posture. **Safe forbids
  tier-N** as before (a real-SIMD or over-cap-memory NIF is Unsafe-only).

---

## Deviations from the provisional surface

The provisional surface ([`PROVISIONAL-SURFACE.md`](PROVISIONAL-SURFACE.md)) frozen the IR4/`rt_simd`/
linker shapes; the capstone builds against it and does not refine those types. Its deviations are
**structural/process** (how the terminal test-and-docs unit composes with P6-10 and the shipped tiers),
each argued so reconciliation can adjudicate:

1. **The capstone does NOT co-own `conformance_test.gleam` (deviation from the P5-12 shape it
   "matches").** P5-12's capstone co-owned the whole-suite matrix run. In Phase 6, **P6-10's Files-owned
   table explicitly claims `conformance_test.gleam`** (add SIMD to `run_suite`/`run_combo`, fix the
   stale module-doc, CI right-size the ~24k SIMD asserts). Single-owner-per-file (D1) is hard, so the
   capstone **confirms** P6-10's enlarged-allowlist matrix + `skip_count_dropped_and_residual_is_honest_
   test` are green and owns only the *deliberately-authored* backstop (`new_surface_test.gleam`),
   runs-anywhere (`runs_anywhere_test.gleam`), the docs, and the SVG. **Argument:** this is strictly
   *less* ownership overlap than P5-12 (which the P5 reconciliation had to untangle post-hoc); pinning
   the whole-suite run to P6-10 up front avoids the double-ownership hazard. **Reconciliation should
   confirm** the capstone references P6-10's headline test rather than re-deriving it.

2. **The capstone's SIMD backstop kernels export SCALARS (an `extract_lane` reduction), not `v128`.**
   The provisional/P6-10 §C.3 ABI carries a `v128` as 16 raw bytes over the term ABI, judged lane-wise.
   The capstone's `simddot`/`simdxform` deliberately export a **scalar** so they ride the exact
   byte-identical numeric `Outcome` used since Phase 2 (`combos.evaluate`/`identity_across`).
   **Argument:** a `v128` op is fully observed through a scalar lane read; a scalar result makes a
   cross-mode/cross-tier divergence a plain `Int`/trap-phrase mismatch on a named program (the strongest
   failure signal), while the ~24.3k `simd/*.wast` `assert_return`s (P6-10) carry the full
   `v128`-in/`v128`-out lane-wise proof. This is not a refinement of the ABI — it is a **test-authoring
   choice** that keeps the capstone's backstop on the simplest correct comparison. No adjudication
   needed beyond noting the corpus seam (#4).

3. **memory64's matrix rows are gated to the `paged` combos; the over-cap `atomics` edge is
   categorized.** The provisional §F states `atomics`/`nif` fail closed for an over-cap 64-bit memory;
   the capstone makes this concrete by driving the `mem64` backstop only under `cell/paged` /
   `threaded/paged` / `portable`, and categorizing the over-cap 64-bit `atomics` binding as a named tier
   edge (mirroring the P5 `matrix_skip_spectest_state` honesty). **Argument:** this is the honest
   reading of I4 ("memory64 ships on `paged` (+ `portable`)"); asserting `mem64` under a fail-closed
   `atomics` binding would either falsely claim it or force a silent fallback (forbidden). **Confirm in
   reconcile** that P6-08's fail-closed gate produces a categorizable outcome (a `Rejected`/`ImportError`,
   not a crash) so the edge is *categorized*, not a hang.

4. **Corpus ownership seam (the same seam P5-12 flagged as its Open Question #1).** The capstone's
   backstop + runs-anywhere need a handful of new-surface corpus modules. P6-10's Files-owned table adds
   `simdkernel.wat`/`simdmem.wat`/`mem64.wat`/`xlink.wat` under `corpus/`; the capstone authors
   `simddot.wat`/`simdxform.wat` and **reuses** P6-10's `simdmem`/`mem64`/`xlink`. **Argument:** the
   capstone owns its two fresh kernels (no collision) and *consumes* P6-10's three (confirm, don't
   re-author); neither reaches into `combos.corpus_programs` (a P4-09 const). **Reconciliation should
   pin** whether the capstone reuses P6-10's `simdkernel.wat` directly (renaming to `simddot`/`simdxform`
   is unnecessary if P6-10's covers the same families) or authors its own — a one-line ownership call so
   the module set is neither double-owned nor orphaned.

---

## Verification — Definition of Done (D8)

- **Proof 1 green (SIMD end-to-end):** `simddot`/`simdxform`/`simdmem` run spec-correct against their
  spec-sourced `.expected` and byte-identical across **both** profiles × `portable`; P6-10's whole-suite
  SIMD run is `fail == 0` and its `simd_differential_test` (the tier sweep) + `wasmtime` differential are
  green. Cites the vector-instruction semantics
  (<https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions>), the vector
  value/type model, and IEEE-754 single-rounding + SIMD NaN propagation (I3).
- **Proof 2 green (memory64):** the `mem64` backstop runs i64-addressed load/store with an offset > 2³²,
  `memory.grow` beyond `mem64_max_pages` → `-1`, an access beyond current size → trap
  `"out of bounds memory access"`, and a 32-bit memory stays byte-identical, under `cell/paged` /
  `threaded/paged` / `portable`; P6-08's memory64 oracle differential is green; `memory64.wast`'s
  in-scope asserts run via the WAT route. Cites the memory64 proposal + the memory instructions with i64
  address type.
- **Proof 3 green (cross-module linking):** `xlink` dispatches an imported function across instances via
  the closure capability and fails closed (`Rejected`) on an unsatisfied import; `linking.wast` is green
  under Safe/`cell`; P6-09's fail-closed + D3a tests are green; the runs-anywhere grep confirms no
  ambient `apply` of a runtime-named atom. Cites §7 embedding + `(register …)`.
- **Proof 4 confirmed (neutral):** the Phase-1..5 corpus + prior allowlist counts are unchanged where
  the category is unchanged (skips only drop, never rise; no formerly-passing assert flips); unit 06's
  emitter-level byte-identity test (a Phase-5 module ⇒ byte-identical `.core`) is green in `gleam test`.
- **Proof 5 green (headline + runs-anywhere):** P6-10's `skip_count_dropped_and_residual_is_honest_test`
  asserts `fail == 0`, `pass > phase5_baseline_pass` (SIMD ~doubled), the two Phase-5 gaps → 0, and the
  residual closed + categorized (`residual_audit_test` green); the SIMD kernels + `mem64` under
  `profiles.portable()` grep **zero** native primitives, name `rt_simd`/`rt_state` non-vacuously, and
  execute byte-identical to the `cell`/`paged` oracle.
- **Image + docs:** `docs/wasm-conformance.svg` regenerated to the new counts; footnote → Phase-6 scope;
  `docs/phase-6-surface.md` committed with the measured before/after + the categorized residual + the
  three honest scope-limits.
- **`gleam format --check src test` clean; `gleam build` ZERO warnings; `gleam test` stays green
  (≥ 1212, now higher); conformance `fail == 0` across every shipped combination.** Done = **the suites
  pass**, never "it compiles."
- Update `state.md`: announce **Phase 6 proven** — the complete standardized WebAssembly surface — with
  the honest close (§G), the three scope-limits, the deferred set, and **Phase 7 (JS on the BEAM via
  Porffor) explicitly UNBLOCKED**.

---

## What this unit leaves

Phase 6 is proven: the engine executes the **complete standardized WebAssembly surface**. Fixed-width
SIMD is real — the `v128` value type (a 16-byte binary, D5) + the ~236 standardized lane instructions
(integer/float lane arithmetic, comparisons, bitwise, shifts, shuffle & swizzle, splat/extract/replace-
lane, narrow/widen/extend/convert/trunc_sat, dot product, extended-multiply, pairwise, boolean
reductions, bitmask, q15, and the v128 memory load/store family) — **bit-exact and spec-differentially
correct**, emulated lane-wise (`rt_simd` reusing `rt_num`, faithful-over-fast, no hardware claim). The
memory64 runtime runs — i64 addressing + 64-bit bounds + a documented, spec-aligned page cap as the
trap boundary, on `paged` (+ `portable`), atomics/nif fail-closed for over-cap. Cross-module function
linking dispatches across instances through a linker-built closure capability (no ambient authority,
D3a), with `linking.wast` green under Safe/`cell` and fail-closed unlinkable at link time. All of it is
spec-differentially correct under both modes and every shipped `state_strategy × mem_tier` each feature
is defined for, **conformance-neutral by default** (I7 — a non-SIMD/32-bit/no-cross-import module is
byte-identical to Phase-5), and **runs-anywhere** for the new surface — and the pinned suite's **`pass`
count roughly doubled with `fail == 0`**, reported honestly with categorized residuals and the three
scope-limits stated in numbers.

**Deferred, stated not dropped (I8):** **relaxed-SIMD** (the separate non-deterministic proposal) →
later; **exception-handling / GC** (typed function refs + `struct`/`array`/`i31`) **/ stack-switching /
the component model**; the single-`.beam` runtime-dispatch **B1** binding; **tier-N numerics/SIMD** + a
production **C NIF** (interface + skeleton ship); the **memory optimizer** (its own performance phase);
the **Erlang/Gleam frontend**. **WASI** stays an `rt_host` impl, out of core.

**Phase 6 completes the *surface* — and, with the surface complete, PHASE 7 IS UNBLOCKED: JS on the
BEAM via Porffor.** Porffor's JS→WASM output (SIMD, bulk memory, reference types, multi-value) is now
fully runnable through `fe_wasm`; the remaining work is a Porffor-ABI `rt_host` shim + a JS-subset
conformance harness — a **buildable** Phase 7, no longer gated on surface completeness. The next move
is JS on the BEAM.

---

## Open questions (for the planner / cross-unit sync)

1. **Whole-suite-run ownership (`conformance_test.gleam`).** P6-10's Files-owned table claims
   `conformance_test.gleam` (SIMD in `run_suite`/`run_combo`, CI right-sizing). The capstone therefore
   **confirms** the enlarged-allowlist matrix + headline test rather than co-owning the file (unlike
   P5-12). **Proposal:** reconcile pins `conformance_test.gleam` + `skipcount_test.gleam` +
   `simd_conformance_test.gleam` + `residual_audit_test.gleam` to **P6-10**, and the capstone owns only
   `new_surface_test.gleam` + `runs_anywhere_test.gleam` + `corpus/simd{dot,xform}.wat` + the docs/SVG.
   Confirm so nothing is double-owned. (Deviation #1.)

2. **New-surface corpus ownership (the P5-12 §H seam, re-raised).** The backstop + runs-anywhere need
   `simddot`/`simdxform`/`simdmem`/`mem64`/`xlink`. P6-10 authors `simdkernel`/`simdmem`/`mem64`/`xlink`
   under `corpus/`; the capstone authors `simddot`/`simdxform` and reuses the other three.
   **Proposal:** the capstone owns its two fresh kernels; if reconcile would rather the capstone reuse
   P6-10's `simdkernel.wat` directly (instead of `simddot`+`simdxform`), that is a one-line P6-10/P6-11
   co-ownership call — flagged so the module set is neither double-owned nor orphaned. (Deviation #4.)

3. **The SIMD/mem64 threaded/`rt_simd` accessor names for the runs-anywhere grep (§F.2).** The
   runs-anywhere grep needs the exact runtime atoms P6-07/08 froze: `rt_simd` (stable — the module
   name), the SIMD-memory threaded head (the P6-01 SIMD-memory-node decision — reuse `'t_load'` at
   16-byte width vs a dedicated `'t_v128_load'`), and the memory64 threaded accessor (the P5 `_at`
   family at i64 width). **Proposal:** P6-07/08 publish these in their frozen signatures so the capstone
   greps a **documented** set, not a guessed one — the tokens must track whatever the units froze.
   (Seam note in §F.2.)

4. **memory64 in the matrix — the `paged`-only gate + the over-cap `atomics` edge (§C, Deviation #3).**
   The `mem64` backstop is asserted under the `paged` combos + `portable`; the over-cap 64-bit `atomics`
   binding is a categorized tier edge. **Proposal:** confirm P6-08's fail-closed gate produces a
   *categorizable* outcome (a `Rejected`/`ImportError`, not a crash/hang) so the edge is categorized, and
   pin the `mem64` matrix rows behind a single capstone predicate (`mem64_shipped: Bool`) so the close
   claims memory64 only when the rows are live (honest either way, like the P5-12 `mem64` gate).

5. **The `threaded` cross-instance reach for `linking.wast` (§D, I5).** `cell` is the proven target;
   the `threaded` cross-instance case (running B's functions against B's state record) is categorized if
   invasive. **Proposal:** confirm in reconcile whether P6-09 wired cross-instance dispatch through both
   strategies (record for `threaded`, pdict for `cell`) — the capstone's matrix sweep would catch a
   divergence, but the reach the close claims must be the one measured (R16). If `threaded` cross-instance
   is a named edge, the close says so; if it is green, the close claims it.
