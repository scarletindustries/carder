# S15-05 — The capstone: Phase 15 proven (production tier-N C NIF, end-to-end)

> **Status:** scoped, awaiting build. **Owner:** S15-05 (the capstone — Wave B, goes last and alone).
> **Depends on:** the whole DAG behind `«NIF-BUILD-FROZEN»` — S15-01 (keystone: `c_src/twocore_rt_mem_nif.h`
> resource-struct + op ABI, the `src/twocore_rt_mem_nif_ffi.erl` shim export table + `on_load`/`.so`-name
> convention, the `test/twocore_rt_mem_nif_build_ffi.erl` `cc`-gated compile+`load_nif` harness, proven live
> by `nif_ping`), S15-02 (the native backend: `c_src/twocore_rt_mem_nif.c` checked core + the
> `rt_mem_nif.gleam` `@external` rewrite + the per-op `nif ≡ paged ≡ oracle` differential — **and, per the
> overview §4 D1 note, the whole `rt_mem_nif.gleam` + `.c` including the `*_unchecked` heads/bodies**),
> S15-03 (the one-line `emit_core.mem_supports_unchecked` whitelist entry + the `emit_unchecked_test` flip),
> S15-04 (the C bounds-check fuzz + the full `cell_nif` corpus differential + the `combos.gleam` wiring so
> `cell_nif` exercises native memory). **Read order:** [`00-overview.md`](00-overview.md) → the distilled
> codebase map (`brief-phase15-cnif.md`) → this doc.
>
> **A capstone CONFIRMS green; it does not re-derive prior units.** S15-01…04 each shipped their own
> spec-cited / differential suite (the `nif_ping` build proof; the per-op `nif ≡ paged ≡ oracle`
> differential; the `emit`-emits-unchecked-on-`nif` flip; the C-bounds-check fuzz + the full `cell_nif`
> matrix). This unit ties the tier end-to-end, **re-runs those suites green and cites them**, adds the one
> proof only it can — the **measured `nif` benchmark column** — regenerates the conformance SVG, writes the
> surface doc, and compacts the phase into [`../01-status.md`](../01-status.md). It writes **no new Gleam
> `src/` or test code**; its only artifacts are docs, the benchmark-harness reach, the regenerated SVG, and
> the status compaction.
>
> **Honors S2** (bit-identical to the paged reference — the differential is the proof), **S3** (the C
> bounds-check is the tested security boundary), **S4** (the unchecked fast path is the tier-N ceiling
> lever), **S5** (the four Safe-forbidden gates + the `--link` exclusion preserved verbatim), **S6** (CI
> builds the NIF under `gcc`, categorized-skip when no `cc` — never a false green), **S7** (correctness =
> the tier differential + the security fuzz + the measured benchmark, never goldens), and **S8** (honest
> scope: tier-N linear memory only; test-time-compiled gated `.so`; the production `priv/*.so` packaging is
> a documented follow-on). It is the single unit that **owns the benchmark / docs / status surface** (D1)
> and the sole point that **proves the §1 acceptance table**.
>
> All prior-phase decisions and the permanent invariants
> ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold. Entering baseline (from
> [`00-overview.md`](00-overview.md) §0, the phase-15 reference): **~1,978 Gleam tests / 0 fail**,
> `gleam build` zero warnings, `gleam format --check` clean, WASM conformance **46,529 / 1,768 / 0** (Safe ≡
> Unsafe, every `state_strategy × mem_tier`). This unit re-confirms the exact measured running totals on
> landing.

---

## §1. Goal

Turn "the pipe compiles, the native backend is bit-identical, the unchecked lever fires, the bounds-check
is fuzzed" into "**the phase is proven**". Concretely:

1. **Fill the previously-missing `nif` benchmark column (MEASURED).** Re-run `docs/phase-4-benchmark.md`
   with a real tier-N build in the contender set — `--tier nif --unsafe --cap` (nif is Unsafe-only, and it
   *reserves* like atomics, so a cap is required). The `.so` is compiled **out of band** first (`gleam build`
   has no native pre-build hook — the exact constraint the phase turns on), toolchain-gated on `cc`; where
   no `cc` is present the column is a **categorized dash**, never a fabricated number. The write-up states
   the **honest ceiling**: the NIF removes paged rebuild cost and — via the unchecked loop-versioned arm —
   the bounds-check cost, but the **per-access inter-module seam-call floor remains** (`call
   'twocore@runtime@rt_mem_nif':'<op>'` is never inlined), and tier-P `bif` numerics are untouched. **No
   hero number**: the honest expected win is atomics-or-better on stores + unchecked O(1) native loads, NOT
   automatic parity with hand-written Erlang (`docs/phase-4-benchmark.md` limitation 3, `:204–206`;
   residual analysis `:145–166` / `:222–232`).

2. **Write `docs/phase-15-tier-n.md`** — the surface writeup: the methodology (bit-identical tier, the
   differential-is-the-proof discipline, the C-build/test/CI story), the measured ceiling, and the **production
   `priv/*.so` packaging follow-on** (deployment-time per-platform prebuilt `.so`, deferred because Gleam
   has no native pre-build hook — S8).

3. **Regenerate `docs/wasm-conformance.svg`** — tier-N is a **runtime tier swap, not new instructions**, so
   the headline `pass / skip / fail` is **unchanged** (`46,529 / 1,768 / 0`, `fail == 0`); the only edit is
   a short Phase-15 footnote line noting that the `cell_nif` differential now exercises a real native memory
   backend bit-identically.

4. **Prove the §1 acceptance table** end-to-end by re-running the S15-01…04 suites green and mapping each
   acceptance row to its owning proof (§4): bit-identical tier, unchecked ceiling, security fuzz,
   Safe-forbidden held, toolchain-gated CI (the `cc`-absent path itself tested to skip), benchmark honesty,
   default unaffected.

5. **Update [`../01-status.md`](../01-status.md)** — live metrics (the tier-N row goes from "skeleton; C
   impl deferred" to "production C NIF"), a Phase-15 history row, the residual/docs lists, and the measured
   running totals.

This unit writes **no Gleam source in `src/`** and **no test that locks in C source or emitted Core text**
(S7). Its only source-shaped reach is the toolchain-gated `nif` build added to the benchmark harness it owns.

---

## §2. Depends on / Produces

**Depends on (frozen upstream — must all be landed + green before this unit claims):**
- S15-01 `«NIF-BUILD-FROZEN»`: the `c_src/twocore_rt_mem_nif.h` resource-struct (`struct { size_t byte_len,
  max_bytes; unsigned char data[]; }`) + per-op ABI; the `src/twocore_rt_mem_nif_ffi.erl` shim export table
  + `-on_load`→`erlang:load_nif` + `.so`-name convention; the `test/twocore_rt_mem_nif_build_ffi.erl`
  `os:find_executable("cc")`-gated `cc -shared -fPIC` compile-to-tempdir + `load_nif` harness — proven by
  `nif_ping` compiling + loading on CI `gcc` and dev `clang`.
- S15-02: the real C core (`c_src/twocore_rt_mem_nif.c`, checked + unchecked over an `enif_alloc`'d reserved
  buffer, LE + no-wrap bounds in C) + the `rt_mem_nif.gleam` `@external` rewrite preserving **every frozen
  head** (Cell + Threaded, `_at` twins, bulk, SIMD byte seam, and — per overview §4 D1 — the `*_unchecked`
  heads) + the per-op `nif ≡ paged ≡ oracle` differential (`rt_mem_nif_test.gleam`, the existing 3-way
  differential `:271–307` now run against the REAL NIF, gated on `cc`).
- S15-03: `|| mem_module == profiles.mem_module_for(Nif)` added to `mem_supports_unchecked`
  (`emit_core.gleam:1765–1768`), and `emit_unchecked_test.gleam:77–85`
  (`nif_falls_back_to_the_checked_path_test`) flipped to assert **nif emits unchecked**.
- S15-04: the C-bounds-check fuzz (`test/twocore/runtime/rt_mem_nif_safety_test.gleam`, random/edge
  addresses + counts at and past `byte_len` and at `grow` watermarks, proving the trap fires and no
  read/write lands outside `[0, byte_len)`); the full `cell_nif` corpus differential + the `combos.gleam`
  wiring so `cell_nif` (`combos.gleam:117` — Cell, Nif, TablePaged, Unsafe) exercises native memory instead
  of the paged-delegate; the four Safe-forbidden re-assertions (incl.
  `safe_forbids_nif_is_unconstructible_test :668–677`).
- The toolchain gate is the phase's own (`cc`/`gcc` via `os:find_executable`, `erl_nif.h` from the frozen
  `erts_include/0` candidate-list resolver — keystone §3.5, **not** the bare `code:lib_dir(erts, include)`);
  CI is `ubuntu-latest` (ships `gcc`/`cc`), dev macOS uses `clang` as `cc`.

**Produces:** the phase proof (§4 acceptance table, all rows green + the benchmark column measured), the
re-measured `docs/phase-4-benchmark.md`, the new `docs/phase-15-tier-n.md`, the regenerated
`docs/wasm-conformance.svg`, and the [`../01-status.md`](../01-status.md) compaction. After this unit lands,
`phase-15/` is removed per [`../03-phase-workflow.md`](../03-phase-workflow.md) §1.

---

## §3. What it owns + the exact edits (D1 — the single benchmark / docs / status owner)

Every file below is assigned to S15-05 by the [`00-overview.md`](00-overview.md) §4 ownership map. No other
unit touches these; this unit touches no `src/` module, no `c_src/*` file, and no upstream unit's test file.
Its one reach outside the doc/status set is the **benchmark harness** `smoke/bench.sh` (the "single
benchmark point" the map assigns) — adding the toolchain-gated `nif` build.

### 3.1 The benchmark reach — add the toolchain-gated `nif` build to `smoke/bench.sh`

`smoke/bench.sh` holds the build/`Binding` matrix as parallel arrays (`BUILDS` / `FLAGS`, `:65–66`):

```
BUILDS=(   "safe"  "atomics-safe"                    "portable"    "unsafe-paged" "ceiling" )
FLAGS=(    ""      "--tier atomics --cap $CAP"       "--portable"  "--unsafe"     "--ceiling --cap $CAP" )
```

Add one column, the **tier-N analogue of `ceiling`** (all levers at once: native memory + Unsafe +
Aggressive + the unchecked loop-versioned arm S15-03 enables on tier-N):

```
BUILDS=(   … "ceiling"                       "nif" )
FLAGS=(    … "--ceiling --cap $CAP"          "--ceiling --tier nif --cap $CAP" )
```

`nif` is Unsafe-only (G6), so it rides `--ceiling` (Unsafe + Aggressive) with `--tier nif` overriding the
memory tier; the `--cap` is mandatory (tier-N *reserves*, like atomics — it reuses the atomics reservation
caps, `fresh64` doc / `rt_mem_atomics` reservation gates). This build exercises **both** ceiling levers on
native memory; an optional Baseline-nif column (`--unsafe --tier nif --cap $CAP`) isolates the unchecked
contribution if the write-up wants the decomposition.

**The out-of-band `.so` step (the load-bearing bit — and the miniature of the packaging follow-on).**
Because `gleam build` compiles `src/*.erl` but **not** `c_src/*.c`, the `nif` build needs its `.so` compiled
and placed where the shim's `-on_load` looks, *before* `gleam run -- exec` loads the `.beam`. Add a gated
pre-step mirroring the test-time build-gate (`test/twocore_rt_mem_nif_build_ffi.erl`) and the atomics
`--cap` gate pattern (`bench.sh:65–66`, `HAVE[i]` correctness-gate discipline `:88–103`):

- Resolve `cc` (`os:find_executable("cc")`, fallback `"gcc"`) and the include dir by **reusing the keystone's
  frozen `erts_include/0` resolver** (the candidate-list-and-pick-first-with-`erl_nif.h` logic, keystone
  §3.5) — **NOT** the bare `code:lib_dir(erts, include)`, which the keystone proved returns a **header-less**
  path on homebrew OTP 29 (MF4).
- `cc -shared -fPIC -o <on_load_path>/twocore_rt_mem_nif.so c_src/twocore_rt_mem_nif.c -I<erts_include>`,
  carrying **`-undefined dynamic_lookup` on darwin (MANDATORY on macOS**, not "may need" — the keystone's
  `nif_ping` proved the exact per-platform flag vector, open seam #4; reuse the frozen `cflags/0` verbatim).
- **`cc` absent ⇒ `HAVE[nif]=0`**: the column prints a **dash** and the write-up categorizes it exactly as
  the phase-4 report categorized the missing nif column (`:60–61`, `:204–206`) — never a fabricated number.
- **`cc` present ⇒** the `nif` build is compiled to a persisted `.beam` and **correctness-gated bit-exact vs
  `wasmtime`** like every other build (`:88–103`); because the NIF is bit-identical to paged (S2), it gates
  clean or the bench aborts non-zero (a wrong fast number is never reported).

> **Honest reach note.** `smoke/bench.sh` is not a `src/`/test file; it is the benchmark harness the map
> assigns as S15-05's "single benchmark point". The `.so` pre-step here is the *deployment* concern in
> miniature — it demonstrates precisely what the production `priv/*.so` packaging follow-on (§7) will
> generalize per-platform. Record it as a deliberate reach in `state.md`.

### 3.2 `docs/phase-4-benchmark.md` — add the measured `nif` column + the honest reading

The phase-4 report currently states there is **no `nif` column** (`:60–61`: "unit 05 ships the interface +
Safe-forbidden status only… so there is **no `nif` column**"; limitation 3, `:204–206`: "Tier-N `nif`
memory… needs a native build toolchain and is **documented-deferred**"). Un-defer it:

- **Results table (`:102–106`)** — add a `nif` column beside `ceiling`, filled with the MEASURED ns/call
  for `crc32(4096)` / `sha256_word(4096)` / `deflate_rt(2000)` under `--ceiling --tier nif --cap 1024`
  (or a dash + a categorized note if `cc` is absent on the reporting machine).
- **Derived-ratios table (`:111–115`)** — add `atomics→nif` (the pure tier-O→tier-N memory delta) and
  `nif→ref` (the residual to hand-Erl/native) rows/columns.
- **Rewrite limitation 3 (`:204–206`)** from "No `nif` memory column… documented-deferred" to the MEASURED
  finding, keeping the frame honest.
- **The honest reading (a new subsection under "The honest reading", beside the existing `atomics` analysis
  `:131–190`)** — state, MEASURED, no hero number:
  - **`atomics → nif`** removes the two costs `atomics` leaves on the table: the 64-bit-word
    read-modify-write mask on sub-word/unaligned stores (`:160–163`) is replaced by a raw byte `memcpy`, so
    the store-heavy DEFLATE kernel gains most; and on the loop-versioned fast arms tier-N now emits
    **native unchecked derefs** (the bounds compare elided — the S15-03/S4 lever), which `atomics` could
    also do but only over its word-masking path.
  - **The floor that remains** — the **per-access inter-module seam call** (`call
    'twocore@runtime@rt_mem_nif':'<op>'(...)`, a build-controlled module atom **never inlined** into the
    caller, `:157–159`, `:222–232`) is present in **every** tier including `nif`; the NIF removes it **only**
    for the unchecked loop bodies the optimizer strips to a raw deref, never for the checked per-op seam.
    And **tier-P `bif` numerics are untouched** (tier-N numerics is out of scope, S8 / G8) — so on the
    numerics-dominated, load-heavy CRC-32, `nif ≈ atomics` (both O(1) loads; the residual is the seam + the
    bignum ops, neither of which native *memory* touches), whereas on store-heavy DEFLATE the raw-`memcpy`
    win is real and measurable. **State plainly: the tier-N memory ceiling does NOT reach hand-written
    Erlang** — it removes the memory constant, not the numeric one and not the seam.

Everything else in `docs/phase-4-benchmark.md` is UNCHANGED (the other five builds' numbers, the
methodology, the `atomics` findings) — the edit is purely additive (one column + one honest subsection +
the limitation-3 rewrite).

### 3.3 `docs/phase-15-tier-n.md` — the surface writeup (new)

New surface doc (mirrors `docs/phase-{5,6}-surface.md` and `docs/phase-{11,12}-*.md`). Contents:

- **What shipped** — a real `erl_nif` C backend (`c_src/twocore_rt_mem_nif.c`) over a reserved raw byte
  buffer via an ERTS resource, replacing the paged-delegating skeleton; **bit-identical to the paged
  reference for every access** (LE byte moves, f32/f64 raw IEEE-bit moves, sub-word signed sign-extension,
  no-wrap `ea`, trap-before-write multi-byte stores, `grow` bumping the logical `byte_len` watermark within
  the reserved `max_bytes`); the `*_unchecked` fast-path heads tier-N previously lacked, now on the
  `emit_core` unchecked whitelist (the Phase-10 loop-versioned arm runs unchecked on tier-N).
- **The trust boundary** — Unsafe-only, Safe-forbidden (the four gates), un-`--link`-able; the C
  bounds-check (overflow-safe guarded subtractions `ea > byte_len || n > byte_len - ea`, combined no-wrap
  `ea` decoded `u64` — MF2) is the tested security boundary (the fuzz, incl. the memory64 boundary vectors,
  proves no access escapes `[0, byte_len)`).
- **The C-build / test / CI story (methodology)** — the repo has **no native-build infrastructure**;
  `gleam build` cannot compile C (no native pre-build hook), so the `.so` is out of band. The phase adopts
  the repo's own Phase-12 binding-harness pattern: compile the NIF **at test time** via a `cc`-gated
  `cc -shared -fPIC` into a tempdir + `erlang:load_nif`, **skip-categorized when no `cc`** (exactly as the
  Elixir binding arm skip-gates on `elixirc`). CI (`ubuntu-latest`) ships `gcc`/`cc`, so CI **genuinely
  builds and exercises the NIF** with **no `.github/workflows/test.yml` edit** (the build-gate resolves `cc`
  via `os:find_executable`); dev macOS uses `clang`. The `cc`-absent path is itself tested to skip — never a
  false green.
- **Native-when-loaded, paged-delegate-otherwise (the honest deployment story, MF3).** tier-N is the raw
  native ceiling **only when the `.so` is present** — CI and packaged deployments load it and get native
  memory; a **bare BEAM** with no NIF (no `cc`, no `priv/*.so`) transparently **falls back to the paged
  delegate** per head (`nif_available()` false → `rt_mem`), so it still runs, byte-identical, with **no
  per-file gating**. This is **not a regression** but the deployment contract: the tier `runs_anywhere`
  (Phase-11), native where the `.so` is loaded, paged everywhere else. The corpus differential proves
  `native == paged` wherever `cc` is present.
- **The measured ceiling** — cite the `docs/phase-4-benchmark.md` `nif` column and the honest reading (§3.2):
  native memory removes rebuild + (unchecked) bounds-check cost; the per-access seam-call floor and tier-P
  `bif` numerics remain; no hero number.
- **The production packaging FOLLOW-ON (S8, explicit).** The test-time build is proof, not deployment. A
  real deployment ships a **prebuilt per-platform `priv/twocore_rt_mem_nif.so`** loaded by the shim's
  `-on_load` from `priv/` — a build step Gleam cannot hook natively, so it is out of scope this phase and
  documented as the next unit of work (compile-per-target-triple + `priv/` packaging + a load-path
  resolution convention). The benchmark's out-of-band `.so` step (§3.1) is this follow-on in miniature.
- **Honest scope (S8)** — tier-N linear memory only (NOT tier-N numerics, NOT hardware SIMD —
  [`../02-roadmap.md`](../02-roadmap.md) §D); Unsafe-only + un-`--link`-able; no frontend/IR/optimizer-
  semantics change beyond the `rt_mem_nif` bodies, the unchecked heads, and the one-line `emit_core`
  whitelist. MEASURED, never promised.

### 3.4 `docs/wasm-conformance.svg` — regenerate (headline unchanged, footnote gains a Phase-15 line)

Regenerate via `RUN_VENDOR=1 scripts/gen-conformance-svg.sh`. Because tier-N is a **runtime tier swap, not
new instructions**, **no new `.wast` fixture is vendored** and the headline `pass / skip / fail` is
**unchanged** (`46,529 / 1,768 / 0`, `fail == 0` — the absolute invariant holds). The conformance corpus is
identical; only the memory backend under the `cell_nif` differential changed (paged-delegate → native).

The one edit is the **hardcoded footnote** in the awk program (`scripts/gen-conformance-svg.sh` ~`:257`):
append a short Phase-15 note — "Phase 15: production tier-N C NIF for linear memory — a real `erl_nif` C
backend over a reserved raw byte buffer, bit-identical to the paged reference for every access (Unsafe-only,
Safe-forbidden, un-`--link`-able); the `cell_nif` tier differential now exercises native memory, `fail = 0`;
toolchain-gated (builds under CI `gcc`, categorized-skip when no `cc`)." **Do not** add tier-N to the
"Residual out of scope" list — it is a shipped tier, not a residual. If the Phase-13/14 capstones already
rewrote this footnote (they land first, in sequence 13 → 14 → 15), **append** the Phase-15 line without
disturbing theirs. Regenerate and commit the new SVG.

### 3.5 `../01-status.md` — the compaction

- **§1 Live metrics table (`:29–34`)** — bump "Gleam tests" to the measured `N pass / 0 fail` (§6); the
  "WASM spec conformance" row is **unchanged** (`46,529 / 1,768 / 0` — tier-N does not move it); keep the
  "identical under Safe and Unsafe, every combo" clause.
- **§3 condensed history (`:63–76`)** — add a **Phase 15** row: "Production tier-N C NIF for linear memory —
  a real `erl_nif` C backend (`c_src/twocore_rt_mem_nif.c`) over a reserved raw byte buffer via an ERTS
  resource, replacing the Phase-4 paged-delegating skeleton; bit-identical to the paged reference for every
  access (the corpus-wide `cell_nif` differential is the proof) + identical traps; the C bounds-check is the
  fuzz-tested security boundary; adds the `*_unchecked` tier-N fast path (loop-versioned raw deref);
  Unsafe-only, Safe-forbidden (four gates preserved), un-`--link`-able (O8); test-time `cc`-gated `.so`
  (production `priv/*.so` packaging a documented follow-on); default tier-P/O output byte-identical,
  conformance unchanged." with the "Proven at close" measured totals.
- **§4 runtime-surface table (`:93–98`)** — change the tier-N Memory cell from "`rt_mem_nif` (interface +
  skeleton; Unsafe-only; **C impl deferred**)" to "`rt_mem_nif` **real C NIF** over a reserved raw buffer
  (Unsafe-only; the raw O(1) native memory ceiling **when the `.so` is loaded**, paged-delegate fallback on
  a bare BEAM — MF3; test-time `cc`-gated, `priv/*.so` deployment a follow-on)".
- **§8 docs line (`:281–282`)** — add `docs/phase-15-tier-n.md` and note `docs/phase-4-benchmark.md` now
  carries the `nif` column.
- **§9 residual** — no tier-N entry to add or remove (it was never a conformance residual; it is a tier).
  The residual buckets are unchanged by this phase.

---

## §4. The acceptance table — how each row is proven (the capstone's contract)

The capstone **owns** the overview §1 acceptance table. Each row maps to a concrete, MEASURED proof; where a
prior unit owns the proof, the capstone **re-runs it green and cites it** rather than restating it.

| Row | Proven by | Gate |
|---|---|---|
| **Bit-identical tier** | S15-02's per-op `nif ≡ paged ≡ oracle` differential (`rt_mem_nif_test.gleam:271–307`, now vs the REAL NIF, gated on `cc`) **and** S15-04's full `cell_nif` corpus differential (`combos.gleam:117` `cell_nif` now native; `tier_differential_test.gleam:63 whole_corpus_tier_differential_test` across `combos.shipped :125–131` = `cell_paged`/`threaded_paged`/`cell_atomics`/`threaded_atomics`/`cell_nif`) — for both Cell and Threaded families, every op (`load`/`store`/`size`/`grow`/`init_data`/`fill`/`copy`/`init`/`load_bytes`/`store_bytes`), identical traps | bit-pattern-identical values + identical traps (`MemoryOutOfBounds`, all-or-nothing multi-byte stores) to paged/oracle; `fail == 0` under `cc`, categorized-skip without |
| **Unchecked ceiling** | S15-03's `emit_unchecked_test.gleam:77–85` flip (nif **emits** unchecked, no longer falls back to checked) + the `mem_supports_unchecked` whitelist entry (`emit_core.gleam:1765–1768`); the Phase-10 loop-versioned fast arm runs unchecked on tier-N with the guard still proving in-bounds before the unchecked arm | `emit` on `mem_module_for(Nif)` emits `MemLoadUnchecked`/`MemStoreUnchecked`; loop-versioning correctness preserved; re-run green |
| **Security boundary** | S15-04's C-bounds-check fuzz (`rt_mem_nif_safety_test.gleam`: random/edge addresses + counts at and past `byte_len`, at `grow` watermarks, **and the memory64 boundary vectors — MF2, without which this row is not proven**) proving the trap fires **in C** and no read/write lands outside `[0, byte_len)` | the adversarial fuzz (incl. memory64) is green; a bug here is a genuine host escape — this is the tested trust boundary (S3) |
| **Safe-forbidden held** | S15-04's re-assertion of the four gates: `validate_binding` `SafeForbidsNif` (`profiles.gleam:545`), the `instantiate` node-safe panic (`profiles.gleam:261–267`), type-unconstructibility (`safe_forbids_nif_is_unconstructible_test :668–677`), and the CLI `--link` `LinkTierNif` gate (`twocore.gleam:598–624/637–638`); tier-N stays excluded from the `--link` matrix (`linked_selfcontained_test.gleam:334–335`, O8) | `Safe + nif` un-constructible / un-instantiable / un-linkable; all four re-run green |
| **Toolchain-gated CI** | the test-time `cc`-gated build-gate (`test/twocore_rt_mem_nif_build_ffi.erl`) — CI `ubuntu-latest` `gcc` **builds and runs** the NIF (no workflow edit; `cc` resolved via `os:find_executable`), macOS `clang` likewise; where no `cc` is present the tier-N-native assertions are a **categorized skip**, and **the `cc`-absent path is itself tested to skip** (mirroring the Elixir arm) | native differential green under `cc`; categorized-skip without; never a false green; conformance `fail = 0` regardless |
| **Benchmark honesty** | **THIS unit** — the measured `nif` column in `docs/phase-4-benchmark.md` (§3.1–§3.2) + the honest reading (removes rebuild + unchecked bounds-check cost; the per-access seam floor + tier-P `bif` numerics remain; no hero number) | the column is MEASURED (a real correctness-gated ns/call, or a categorized dash when no `cc`), never promised |
| **Default unaffected** | the full conformance run UNCHANGED (`46,529 / 1,768 / 0`); tier-P/O output byte-identical; `MemTier`/`mem_module_for`/`validate_binding`/every `emit_mem_*` seam untouched (the tier is a build-time module swap) | `gleam test` + conformance green; the SVG headline unchanged (§3.4) |

"Green" here always means **MEASURED** (a count printed and asserted, or a categorized skip), never "it
compiled" (S7/S11).

---

## §5. The work (ordered, buildable)

1. **Confirm the tier is frozen + green.** `gleam test` on `main` with S15-01…04 landed: 0 fail (native
   rows green under `cc`, categorized-skip without), `gleam build` zero warnings, `gleam format --check src
   test` clean. Re-run the S15-02 differential, S15-03 emit-flip, and S15-04 fuzz/matrix/Safe-forbidden
   suites green — the capstone builds on their guarantees and cites them (§4).
2. **Benchmark the `nif` column.** Add the toolchain-gated `nif` build + the out-of-band `.so` pre-step to
   `smoke/bench.sh` (§3.1). Run `./smoke/bench.sh 100 1024 300` on the reference machine (Apple M2 Pro / dev
   `clang`, per the phase-4 methodology `:69–71`). Confirm the `nif` build **gates bit-exact vs `wasmtime`**
   before it is timed (S2); if `cc` is absent, confirm the column categorizes a dash cleanly. Record the
   MEASURED ns/call for all three kernels.
3. **Re-measure `docs/phase-4-benchmark.md`.** Fill the `nif` column + the `atomics→nif` / `nif→ref` ratios;
   rewrite limitation 3; write the honest-reading subsection (§3.2). Every number MEASURED or a categorized
   dash.
4. **Write `docs/phase-15-tier-n.md`** (§3.3) — methodology, the C-build/test/CI story, the measured
   ceiling, the production `priv/*.so` packaging follow-on, the honest scope.
5. **Regenerate the SVG.** Edit the footnote (§3.4, append the Phase-15 line; do not touch the residual
   list). `RUN_VENDOR=1 scripts/gen-conformance-svg.sh`. Confirm the headline is **unchanged**
   (`46,529 / 1,768 / 0`, `fail == 0`). Commit `docs/wasm-conformance.svg`.
6. **Update `../01-status.md`** (§3.5) — live metrics (Gleam-test total; conformance row unchanged), the
   Phase-15 history row, the tier-N runtime-surface cell, the docs line.
7. **Final gate.** `gleam format` → `gleam format --check src test` clean → `gleam build` zero warnings →
   full `gleam test`; record the exact measured `N pass / 0 fail` (and the pass/skip split's `cc`-dependence,
   §6). Update `state.md`; announce **PHASE 15 PROVEN**; compact per
   [`../03-phase-workflow.md`](../03-phase-workflow.md) §1 and remove `phase-15/`.

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. **Bit-identical tier proven (MEASURED).** S15-02's per-op differential + S15-04's full `cell_nif` corpus
   differential re-run green against the REAL NIF (values bit-pattern-identical + traps identical to
   paged/oracle, both families, every op); `fail == 0` under `cc`, **categorized-skip when no `cc`** (never a
   false green). The unchecked ceiling (S15-03 emit-flip) and the security fuzz (S15-04) re-run green and
   are cited.
2. **Safe-forbidden held.** The four gates + the `--link` exclusion (O8) re-run green (§4) — `Safe + nif`
   remains impossible to construct / instantiate / link.
3. **Benchmark column measured.** `docs/phase-4-benchmark.md` carries the `nif` column, correctness-gated
   bit-exact vs `wasmtime` before timing (or a categorized dash when no `cc`); the honest reading states the
   ceiling with **no hero number** (removes rebuild + unchecked bounds-check cost; per-access seam floor +
   tier-P `bif` numerics remain).
4. **Docs current.** `docs/phase-15-tier-n.md` written (methodology, the C-build/test/CI story, the measured
   ceiling, the production `priv/*.so` packaging follow-on, the honest scope);
   `docs/wasm-conformance.svg` regenerated with the headline **unchanged** (`46,529 / 1,768 / 0`,
   `fail == 0`) and the footnote gaining the Phase-15 line; `../01-status.md` metrics, history row, tier-N
   runtime-surface cell, and docs list updated.
5. **Toolchain-gated CI honest.** CI `ubuntu-latest` `gcc` builds and exercises the NIF (no workflow edit);
   the `cc`-absent path is tested to skip (cited to S15-01/04); conformance `fail = 0` regardless.
6. **Clean build.** `gleam format --check src test` clean; `gleam build` **zero warnings**; the full
   `gleam test` suite green with the exact measured running total recorded. Entering baseline (overview §0):
   **~1,978 / 0 fail** (Phase-12 close, the phase-15 reference); + the S15-01…04 suites (the `nif_ping` build
   proof; the per-op `nif ≡ paged ≡ oracle` differential; the `emit_unchecked` flip; the C-bounds fuzz + the
   full `cell_nif` matrix + the four Safe-forbidden re-assertions). Report the measured **`N pass / 0 fail`**;
   the pass/skip split is **`cc`-dependent** (CI `gcc` / dev `clang`: the native-differential rows pass;
   no `cc`: they categorized-skip) — state which the reporting run saw. This unit authors **no new gleeunit
   test** (its proof is re-running the S15-01…04 suites green + the measured benchmark), so the running total
   is the sum of the upstream suites over the entering baseline (projected **~1,995–2,005 / 0 fail** under
   `cc`; the exact figure re-confirmed on landing).
7. **`///` / `//` doc comments** — no new public `src/` surface is added by this unit; the doc/status prose
   itself is the deliverable and must be MEASURED-honest (S11), every number a real count or a categorized
   dash.

---

## §7. What it leaves

- **Nothing downstream in-phase.** S15-05 is the terminal unit; after it lands, `phase-15/` is removed and
  its decisions live in the code (`c_src/twocore_rt_mem_nif.{h,c}`, `src/twocore_rt_mem_nif_ffi.erl`,
  `src/twocore/runtime/rt_mem_nif.gleam`), the tests, and [`../01-status.md`](../01-status.md).
- **The production `priv/*.so` packaging FOLLOW-ON (documented, S8).** This phase ships the C source + a
  toolchain-gated **test-time** build; a **prebuilt per-platform `priv/twocore_rt_mem_nif.so`** loaded by the
  shim's `-on_load` from `priv/` — the deployment-packaging step — is deferred **because Gleam has no native
  pre-build hook**, and is the next unit of work (compile-per-target-triple + `priv/` packaging + a
  load-path resolution convention). The benchmark's out-of-band `.so` step (§3.1) is this follow-on in
  miniature. Recorded in `docs/phase-15-tier-n.md` and [`../02-roadmap.md`](../02-roadmap.md).
- **Categorized-deferred, unchanged (honest — noted, not closed):** **tier-N numerics** (`rt_num` stays
  tier-P `bif` — the biggest remaining lever the phase-4 residual points at, `:201–203` / `:227–228`) and
  **hardware SIMD** (`rt_simd` stays emulated) remain out of scope ([`../02-roadmap.md`](../02-roadmap.md)
  §D). tier-N stays **Unsafe-only + un-`--link`-able** (a NIF cannot be merged, O8) and excluded from any
  Safe posture — this phase added capability, not posture (S5).
- **No frontend / IR / optimizer-semantics change** (S8). The tier remains a **build-time module swap**
  behind the `emit_core` seam (`mem_module = "twocore@runtime@rt_mem_nif"`); `MemTier`, `mem_module_for`,
  `validate_binding`, and every `emit_mem_*` seam are untouched — which is exactly why default tier-P/O
  output stays byte-identical and conformance stays `46,529 / 1,768 / 0`.
