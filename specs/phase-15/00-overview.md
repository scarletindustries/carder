# Phase 15 — Production C NIF for tier-N linear memory

> **Status:** scoped, awaiting the scoping fan-out + critique. No code yet. Follows the fixed skeleton in
> [`../03-phase-workflow.md`](../03-phase-workflow.md) §2. Decisions are `S1–S8` (the letter series
> continues from Phase 14's `R`; `S1` = keystone, `S8` = honest scope); **units** are `S15-01 … S15-05`.
>
> **All prior-phase decisions and the permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8)
> still hold.** Baseline entering: ~1,978 tests / 0 fail · `gleam build` zero warnings · `gleam format`
> clean · WASM conformance 46,529 / 1,768 / 0 (Safe ≡ Unsafe, every `state_strategy × mem_tier`). The
> keystone re-confirms the exact running total on landing.
>
> Folds its reconciliation into this overview unless the fan-out + critique surface a genuine conflict.

---

## §0. Where this phase sits

Phase 4 shipped the uniform memory-tier interface and a **node-safe reference skeleton** for tier-N
(`rt_mem_nif` delegates every operation to the paged core: spec-correct by construction, but carrying
paged rebuild cost and never the raw native ceiling; the real C impl was deferred for want of a native
toolchain, [`../02-roadmap.md`](../02-roadmap.md) §D). This phase fills that skeleton with a real
`erl_nif` C backend over a reserved raw byte buffer — the **raw O(1) memory ceiling, Unsafe-only /
Safe-forbidden** — and adds the `*_unchecked` fast-path heads tier-N currently lacks (the Phase-10 lever,
[`../02-roadmap.md`](../02-roadmap.md) §E). It is a **runtime-tier** phase: no frontend, no IR, no
optimizer-semantics change; the tier stays a build-time module swap behind the `emit_core` seam.

The crucial constraint is the **build/test/CI story**, because the repo has *no* native-build
infrastructure and `gleam build` cannot compile C. The phase adopts the repo's own established pattern
(the Phase-12 binding harness): compile the NIF **at test time** via a toolchain-gated `cc -shared -fPIC`
into a tempdir and `erlang:load_nif`, **skip-categorized when no C toolchain is present** (exactly as the
Elixir binding arm skip-gates on `elixirc`). CI is `ubuntu-latest` (ships `gcc`/`cc`) so CI genuinely
builds and exercises the NIF; local macOS uses `clang` (as `cc`). A prebuilt per-platform `priv/*.so`
packaging step for *deployment* is a documented follow-on, not this phase.

---

## §1. Goal & acceptance

**Goal.** Replace the paged-delegating bodies of `rt_mem_nif` with a real C NIF managing a reserved raw
byte buffer via an ERTS resource — **bit-identical to the paged reference for every access** (the
differential is the proof) — and expose the tier-N unchecked fast path. The NIF is Unsafe-only,
Safe-forbidden (unchanged from Phase 4's four fail-closed gates), and un-`--link`-able (a NIF cannot be
merged). Default output is unchanged (tier-N is opt-in).

**Acceptance table** (owned by the capstone, S15-05):

| Area | Must demonstrate |
|---|---|
| Bit-identical tier | `rt_mem_nif` (real C NIF) produces **bit-pattern-identical** load/store/size/grow/`init_data`/`fill`/`copy`/`init`/`load_bytes`/`store_bytes` results and **identical traps** (`MemoryOutOfBounds`, all-or-nothing multi-byte stores) to the paged reference and the spec oracle — for both Cell and Threaded families — across the whole tier differential. |
| Unchecked ceiling | tier-N gains `load_unchecked`/`store_unchecked`/`t_*` heads (a raw deref, bounds compare elided) and is added to the `emit_core` unchecked whitelist; the Phase-10 loop-versioned fast arm now runs unchecked on tier-N (previously it fell back to checked). Loop-versioning correctness is preserved (the guard still proves in-bounds before entering the unchecked arm). |
| Security boundary | The C bounds-check (`ea + n <= byte_len`, no-wrap effective address) is exercised by a fuzz/adversarial test proving an out-of-bounds access **traps in C and never escapes** the buffer (a bug here is a genuine host escape — this is the tested trust boundary). |
| Safe-forbidden held | The four existing rejections stay: `validate_binding` `SafeForbidsNif`, the `instantiate` panic, type-unconstructibility, and the `--link` `LinkTierNif` gate. `Safe + nif` remains impossible to construct/link. |
| Toolchain-gated CI | The NIF **builds and runs under CI** (`ubuntu-latest` gcc) and macOS (clang); where no C toolchain is present the tier-N differential is a **categorized skip**, never a false green (the `cc`-absent path is explicitly tested to skip, mirroring the Elixir arm). |
| Benchmark honesty | `docs/phase-4-benchmark.md` gains the previously-missing **nif column** (measured); the write-up states the honest ceiling — the NIF removes paged rebuild cost and (via unchecked) the bounds-check cost, but the per-access inter-module seam-call floor remains. No hero number. |
| Default unaffected | tier-P/tier-O output is byte-identical; `MemTier`, `mem_module_for`, `validate_binding`, and every `emit_mem_*` seam are untouched (the tier is a build-time module swap); `gleam test` + conformance stay green. |

**Honest scope** (= decision S8, restated in §2):
- **tier-N linear memory only.** Not tier-N numerics, not hardware SIMD (still `../02-roadmap.md` §D).
- **Test-time compiled `.so`, gated.** The phase ships the C source + a toolchain-gated test-time build;
  a prebuilt per-platform `priv/*.so` deployment-packaging step is a documented follow-on (Gleam has no
  native pre-build hook).
- **Unsafe-only, un-`--link`-able.** The four fail-closed gates are preserved verbatim; tier-N stays
  excluded from the `--link` merge matrix (O8) and from any Safe posture.
- **No frontend/IR/optimizer-semantics change.** Only `rt_mem_nif` bodies, the new unchecked heads, and a
  one-line `emit_core` unchecked-whitelist entry.

---

## §2. Decisions (S1–S8)

> Each decision is **frozen** for this phase. Raise a disagreement with the planner BEFORE building. S1 is
> the keystone; S8 is honest scope.

**S1 (keystone) — Freeze the native toolchain path end-to-end *before* any memory logic.** The
load-bearing risk is not the memory algebra (the paged reference already defines it, bit-exact) — it is
**getting a C NIF to compile and load across CI (gcc) and dev (clang) under the repo's no-native-build
reality**. So the keystone ships: `c_src/twocore_rt_mem_nif.h` (the resource-struct layout + the
per-operation ABI contract the C core and Gleam heads both bind to), a new
`src/twocore_rt_mem_nif_ffi.erl` shim (the `-on_load` → `erlang:load_nif` bootstrap + one
`erlang:nif_error(nif_not_loaded)` stub per exported NIF, with the exact export names/arities the Gleam
`@external`s will call), and a new `test/twocore_rt_mem_nif_build_ffi.erl` (the `os:find_executable("cc")`
gate + a `run_port` `cc -shared -fPIC` compile-to-tempdir + `erlang:load_nif`, skip-categorized on
absence) — proven by a **trivial `nif_ping` NIF** that compiles + loads + returns on both platforms. This
freezes `«NIF-BUILD-FROZEN»`: the shim export table, the resource ABI, the `.so` name / `on_load` path
convention, and the build-gate signature the downstream units call. `rt_mem_nif.gleam` stays the
paged-delegate at this unit (byte-identical, untouched) — the keystone proves the *pipe*, not the water.

**S2 — The native backend is bit-identical to the paged reference; the differential is the proof.** The C
core (`c_src/twocore_rt_mem_nif.c`) implements the checked operations over an `enif_alloc`'d **reserved**
buffer (`struct { size_t byte_len, max_bytes; unsigned char data[]; }`), honoring the paged conventions
verbatim: little-endian byte moves (f32/f64 are raw IEEE-bit moves, never a BEAM double round-trip);
sub-word signed loads sign-extend to the result width and return the unsigned two's-complement bit
pattern; the effective address `ea = addr + offset` is a no-wrap value and the trap condition is exactly
`ea < 0 || ea + n > byte_len` → `MemoryOutOfBounds`; multi-byte stores are trap-before-write /
all-or-nothing; `grow` bumps the logical `byte_len` watermark within the reserved `max_bytes` (the tier
*reserves* — it cannot back a 2⁴⁸ sparse memory; it reuses the atomics reservation caps). The Gleam side
(`rt_mem_nif.gleam`) swaps its bodies to `@external` calls into the frozen shim, preserving **every
frozen head** (Cell + Threaded families, `_at` twins, bulk, SIMD byte seam) so `emit_core` routes to it
unchanged.

**S3 — The C bounds-check is the security boundary and is tested as one.** Under `mem_tier == Nif` the
resource is produced *solely* by this tier's `fresh`, so the `Dynamic` in the cell slot is always this
NIF's resource (coercion sound). Every checked op validates `ea + n <= byte_len` **in C** before touching
the buffer; a bug there is a real host escape, so it gets an adversarial fuzz test (random/edge addresses
+ counts, at and past the boundary, at `grow` watermarks) proving the trap fires and no read/write lands
outside `[0, byte_len)`.

**S4 — The unchecked fast path is the tier-N ceiling lever.** Add `load_unchecked`/`store_unchecked` (+
`t_` twins) to `rt_mem_nif` (Gleam heads + C bodies that skip the bounds compare — a raw deref) and add
`mem_module_for(Nif)` to `emit_core.mem_supports_unchecked` (a one-line whitelist entry). This is sound
because the Phase-10 loop-versioning guard has already proved the whole range in-bounds before entering
the unchecked arm (trap-preservation is absolute — never hoist-and-trap-early), and tier-N is a
BEAM-memory-*un*safe tier where the elided check is the whole point. The `emit_unchecked_test` case that
asserts "nif falls back to checked" flips to assert "nif emits unchecked."

**S5 — The four Safe-forbidden gates and the `--link` exclusion are preserved verbatim.** `Safe + nif` stays
rejected at `validate_binding` (`SafeForbidsNif`), at `instantiate` (node-safe panic), by
type-unconstructibility (no Safe profile names `Nif`), and by the CLI `--link` gate (`LinkTierNif`, a NIF
cannot be merged under any mode). tier-N stays excluded from the `--link` differential matrix (O8). This
phase adds capability; it does not widen posture.

**S6 — CI builds the NIF or categorizes the skip; never a false green.** The test-time build gates on a C
toolchain (`cc`, fallback `gcc`) resolved with `os:find_executable`, with `erl_nif.h` located via the frozen
`erts_include/0` candidate-list resolver (keystone §3.5 — not the bare `code:lib_dir(erts, include)`, which
returns a header-less path on some layouts). Present (CI ubuntu, dev macOS) ⇒ the tier-N differential runs against the
real NIF. Absent ⇒ every tier-N-native assertion is a **categorized skip** (the `cc`-absent path is
itself tested to skip, mirroring the Elixir binding arm), and the paged-delegate remains the fallback so
nothing regresses. The conformance `fail=0` gate holds regardless.

**S7 — Correctness is the tier differential + the security fuzz, not goldens.** The proof is: the
corpus-wide `(mode × state_strategy × mem_tier × table_tier)` differential with `cell_nif` now exercising
native memory returns bit-identical values + identical traps to paged/atomics/oracle; the security fuzz
proves the C bounds-check contains every access; and the benchmark measures the real nif column. No test
locks in C source or emitted Core text.

**S8 — Honest scope.** As §1: tier-N linear memory only; test-time-compiled gated `.so` (deployment
packaging deferred); Unsafe-only + un-`--link`-able (four gates preserved); no frontend/IR/optimizer
change beyond the `rt_mem_nif` bodies, the unchecked heads, and the one-line `emit_core` whitelist.

---

## §3. Dependency DAG & freeze milestone

```
   S15-01 keystone ──«NIF-BUILD-FROZEN»──┬──▶ S15-02 native backend (C core + Gleam @external ─┐
   (c_src/*.h + shim + build-gate FFI     │    + per-op nif≡paged differential, gated on cc)     ├─▶ S15-05 capstone
    + nif_ping proving the toolchain path) │──▶ S15-03 unchecked heads + emit_core whitelist ────┤   (real nif column
                                           └──▶ S15-04 node-safety fuzz + full cell_nif matrix ──┘    benchmark, docs, SVG)
```

**Freeze milestone:**

| Milestone | Produced by | Unblocks |
|---|---|---|
| `«NIF-BUILD-FROZEN»` — the `c_src/twocore_rt_mem_nif.h` resource-struct + op ABI, the `src/twocore_rt_mem_nif_ffi.erl` shim export table + `on_load`/`.so`-name convention, and the `test/twocore_rt_mem_nif_build_ffi.erl` `cc`-gated compile+`load_nif` harness signature — proven live by a `nif_ping` NIF that compiles+loads on CI gcc + macOS clang | S15-01 | S15-02, S15-03, S15-04, S15-05 |

**Waves.** Wave 0: S15-01 (proves the pipe). Wave A (behind the freeze): S15-02 (the native backend —
C core + Gleam bindings + the per-op differential; the heart), S15-03 (unchecked), S15-04 (node-safety
fuzz + full matrix). S15-03/04 build against the frozen shim + S15-02's ops (they may land after S15-02
lands green). Wave B: S15-05 capstone (benchmark + docs).

**Open seams for the scoping fan-out / critique to resolve:**
1. Whether S15-02 (C core) and the Gleam `@external` rewrite are one unit or two parallel units behind the
   frozen shim — the map leans one coherent "native backend" unit so the C exports and Gleam heads land
   together and the per-op differential proves them; confirm this is single-agent-sized.
2. The reserved-buffer sizing policy under `grow` (how `max_bytes` is chosen from `max_pages` / the
   reservation caps `fresh64` uses) — confirm it matches the atomics reservation semantics the tier reuses
   and cannot over-commit.
3. Whether the resource must survive `grow` via `enif_realloc` of the resource vs a fixed reservation with
   a moving watermark (reservation avoids invalidating outstanding pointers/resource identity — likely the
   safe choice; confirm).
4. The exact `cc` invocation portability (macOS clang vs Linux gcc flags, `-undefined dynamic_lookup` on
   macOS for NIF symbols vs Linux `-shared`) — the keystone's `nif_ping` must prove both before downstream
   work depends on it.
5. Whether the `.gitignore` needs a `c_src`-build-artifact entry (the tempdir `.so` should never be
   committed).

---

## §4. File-ownership map (one owner per file, D1)

| Unit | Owns / creates | Deliberate cross-file reaches |
|---|---|---|
| **S15-01** keystone | new `c_src/twocore_rt_mem_nif.h` · new `src/twocore_rt_mem_nif_ffi.erl` (shim) · new `test/twocore_rt_mem_nif_build_ffi.erl` (build-gate) · new `test/twocore/runtime/rt_mem_nif_build_test.gleam` (`nif_ping` proof) · `.gitignore` (tempdir artifacts) | — (`rt_mem_nif.gleam` stays the paged-delegate, untouched) |
| **S15-02** native backend (the heart) | new `c_src/twocore_rt_mem_nif.c` (the checked C core) · `src/twocore/runtime/rt_mem_nif.gleam` (swap bodies to `@external`, preserving every frozen head) · a per-op `nif ≡ paged ≡ oracle` differential in `test/twocore/runtime/rt_mem_nif_test.gleam` (gated on `cc`) | fills the shim NIF bodies frozen by S15-01 |
| **S15-03** unchecked | the new `load_unchecked`/`store_unchecked`/`t_*` heads (Gleam in `rt_mem_nif.gleam` **is owned by S15-02** → S15-03 adds them there only if D1-reassigned; otherwise the unchecked C bodies live in `c_src` owned via a clear split) + the one-line `src/twocore/backend/emit_core.gleam` `mem_supports_unchecked` whitelist entry + flip `test/twocore/backend/emit_unchecked_test.gleam` | coordinates with S15-02 on `rt_mem_nif.gleam` head additions (fan-out to resolve the split — open seam) |
| **S15-04** node-safety + matrix | the C bounds-check fuzz + full `cell_nif` corpus differential in `test/twocore/runtime/rt_mem_nif_safety_test.gleam` + `test/twocore/tier/combos.gleam` wiring so `cell_nif` exercises native memory | — |
| **S15-05** capstone | `docs/phase-4-benchmark.md` (add the measured nif column) + `docs/phase-15-tier-n.md` (methodology, ceiling, packaging follow-on) · `docs/wasm-conformance.svg` (regen) · `../01-status.md` | the single benchmark/status point only |

> **Note (open seam 1 & S15-03 ownership):** the cleanest split is likely **S15-02 owns all of
> `rt_mem_nif.gleam`** (checked + unchecked heads) and **all of `c_src/twocore_rt_mem_nif.c`** (checked +
> unchecked bodies), with **S15-03 owning only the one-line `emit_core` whitelist + the `emit_unchecked`
> test flip**. The fan-out should confirm and, if so, fold the unchecked heads into S15-02 (leaving S15-03
> a tiny wiring unit) to keep `rt_mem_nif.gleam`/`.c` single-owner.

---

## §5. How to claim & complete

Standard loop ([`../03-phase-workflow.md`](../03-phase-workflow.md) §7 + §9): read
[`../state.md`](../state.md); claim a unit; for S15-01 freeze `«NIF-BUILD-FROZEN»` by proving `nif_ping`
compiles + loads on both platforms and land green with `rt_mem_nif.gleam` still the byte-identical
paged-delegate; build S15-02/03/04 behind the frozen shim; satisfy the per-unit Definition of Done
(spec-cited/differential tests, doc comments, `gleam format --check src test` clean, `gleam build` zero
warnings, the unit's suite green **or categorized-skip when no `cc`**); update `state.md`. The capstone
(S15-05) proves the acceptance table (bit-identical tier, unchecked ceiling, security fuzz, benchmark),
regenerates the conformance SVG, then this phase is compacted into
[`../01-status.md`](../01-status.md) and `phase-15/` removed.

> **Next step (per the methodology):** a scoping fan-out + adversarial critique before freezing — the
> cross-platform `cc` invocation (open seam 4), the reserved-buffer/`grow` policy (open seams 2–3), and
> the S15-02/S15-03 ownership split (open seam 1) are exactly the areas a critique should pressure-test
> (as the Phase-11 critique caught the `fun`-capture blocker before any code).
