# S15-04 — the node-safety fuzz + the full `cell_nif` native matrix

> **Status:** scoped, awaiting build. **Owner:** S15-04 (Wave A — a leaf unit, behind the freeze).
> **Depends on:** `«NIF-BUILD-FROZEN»` (S15-01) **and** the real NIF (S15-02); builds behind S15-02
> and may land after S15-02 is green (DAG, [`00-overview.md`](00-overview.md) §3). **Read order:**
> [`00-overview.md`](00-overview.md) → the distilled codebase map (`brief-phase15-cnif.md`) → this doc.
> All prior-phase decisions and the permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md)
> §8) still hold. This unit **adds no source under `src/`** — it is two test-side artifacts: the C
> bounds-check **security fuzz** (the tested trust boundary) and the `combos.gleam` wiring that makes the
> shipped `cell_nif` combo drive **native** memory across the whole corpus differential. It is
> **gated on `cc`** — categorized-skip when no C toolchain is present, never a false green.
>
> **Honors:** **S3** (the C bounds-check is the security boundary and is tested as one — *primary*),
> **S5** (the four Safe-forbidden gates + the `--link` exclusion preserved verbatim), **S6** (CI builds
> the NIF or categorizes the skip), **S7** (correctness is the tier differential + the security fuzz, not
> goldens), **S8** (honest scope — Unsafe-only, un-`--link`-able).

---

## §1. Goal

Prove two things about the real C NIF (S15-02), and wire the corpus differential so the proof runs at
scale:

1. **The C bounds-check contains every access (S3).** The reserved-buffer backend validates the combined
   effective address with **overflow-safe guarded subtractions** (`ea > byte_len || n > byte_len - ea`,
   `ea = addr + offset` computed no-wrap Gleam-side, decoded `u64` in C — MF1/MF2) **before** touching the
   buffer. A bug there is a **genuine host escape** — a read or write outside `[0, byte_len)` corrupts arbitrary BEAM heap or
   segfaults the node. This is the tested trust boundary of the whole phase. The fuzz drives
   **random/edge addresses + counts AT and PAST `byte_len`, at `grow` watermarks**, and proves: (a) every
   out-of-bounds access **traps** (`Error(MemoryOutOfBounds)`, never a crash, never a value); and (b) **no
   read or write lands outside `[0, byte_len)`** — the containment property, proven differentially against
   the memory-safe paged reference + a post-`grow` zero-fill escape probe.

2. **The shipped matrix exercises native memory (S7).** The `cell_nif` combo
   (`combos.gleam:117` — Cell × Nif × TablePaged × Unsafe) today drives the paged **delegate**; after
   S15-02 swaps `rt_mem_nif`'s bodies to the real NIF, `cell_nif` must drive the **native** buffer across
   the whole `(state_strategy × mem_tier × table_tier)` corpus differential. This unit owns the one wiring
   change (in `combos.gleam`) that guarantees the NIF `.so` is compiled + loaded before `cell_nif` runs
   (via the S15-01 build-gate), so `whole_corpus_tier_differential_test` / `memory_programs_agree_across_
   tiers_test` genuinely compare **native ≡ paged ≡ atomics ≡ oracle** when `cc` is present.

And **confirm** (read-only, no edits to the owning files) that this phase widens no posture: the **four
Safe-forbidden gates** and the **Phase-11 L1 `--link` exclusion** still hold (S5).

---

## §2. Depends on / Produces

**Depends on (frozen/green upstream):**

- **`«NIF-BUILD-FROZEN»` (S15-01)** — the `cc`-gated build harness `test/twocore_rt_mem_nif_build_ffi.erl`
  (its `which("cc")` gate + `run_port cc -shared -fPIC` compile-to-tempdir + `erlang:load_nif`, the same
  shape as `test/twocore_bindings_ffi.erl:52-56`/`:158-159`), the `.so` name / `on_load` convention, and
  the shim export table `src/twocore_rt_mem_nif_ffi.erl`. **This unit binds to the frozen build-gate entry
  point** (the idempotent "ensure the NIF `.so` is built + loaded, or report no-`cc`" function S15-01
  freezes; referred to here as `ensure_nif_loaded()` / `nif_toolchain_available()` — the exact names are
  S15-01's to freeze, this unit consumes them). It does not add or edit the build harness.
- **The real NIF (S15-02)** — `src/twocore/runtime/rt_mem_nif.gleam` with `@external` bodies + the checked
  C core `c_src/twocore_rt_mem_nif.c` over the reserved buffer
  `struct { size_t byte_len, max_bytes; unsigned char data[]; }`, honoring the paged conventions verbatim
  (little-endian, no-wrap `ea`, sign/zero-extend, all-or-nothing multi-byte stores, `grow` bumps
  `byte_len` within reserved `max_bytes`). The fuzz drives this backend's frozen heads (`t_load`/`t_store`/
  `t_grow`/`t_init_data`/`fill`/`copy`/`init`/`t_load_bytes`/`t_store_bytes` + the `to_flat` differential
  hook, `rt_mem_nif.gleam:103-512`, `:255`). Read-only.
- **Read-only regression surface (S5 — do NOT weaken):** `profiles.validate_binding` rule 1
  (`profiles.gleam:507-508`, `:545` → `Safe, Nif, _, _ -> Error(SafeForbidsNif)`); `profiles.instantiate`
  node-safe panic (`profiles.gleam:261-264`); type-unconstructibility (every Safe profile names `Paged`);
  the CLI `--link` gate `link_gate` → `Error(LinkTierNif)` (`twocore.gleam:602`, `:611`, `:622-624`).

**Produces:** the security fuzz suite `test/twocore/runtime/rt_mem_nif_safety_test.gleam` (green against
the real NIF when `cc` present; categorized-skip when absent) and the `combos.gleam` native-matrix wiring.
**Unblocks:** the capstone **S15-05** cites this unit's green native `cell_nif` differential + the
security-fuzz containment proof as the "Bit-identical tier" and "Security boundary" acceptance rows.

---

## §3. What it owns + design

**Owned files (D1) — this unit is the sole substantive owner of each:**
`test/twocore/runtime/rt_mem_nif_safety_test.gleam` (new) · the Phase-15 wiring edit in
`test/twocore/tier/combos.gleam`.

> **Ownership note (D1 / overview §4 `S15-02`-vs-`S15-04` split).** `rt_mem_nif.gleam` and
> `c_src/twocore_rt_mem_nif.c` are **S15-02's** (checked + unchecked bodies both, per the overview's
> recommended split); `emit_core.mem_supports_unchecked` + the `emit_unchecked_test` flip are **S15-03's**.
> This unit touches **neither** — it is purely the test-side security proof + matrix wiring. It reads the
> S15-02 heads and the S15-01 build-gate; it does not add source, does not spell a `rt_mem_*` module atom
> (every tier→module coupling goes through `profiles`/`combos.binding_for`, mirroring `combos.gleam`'s D1),
> and does not edit the gate-owning files it confirms (§3.3).

### 3.1 `combos.gleam` — the `cell_nif` combo drives NATIVE memory (S7)

The combo already exists and already names `Nif`:

```
combos.gleam:117   pub const cell_nif = Combo("cell×nif", Cell, Nif, TablePaged, Unsafe)
combos.gleam:125   pub const shipped: List(Combo) = [ cell_paged, threaded_paged, cell_atomics,
combos.gleam:131                                       threaded_atomics, cell_nif ]
```

Because `emit_core` routes by **module atom** (`mem_module_for(Nif) = "twocore@runtime@rt_mem_nif"`),
routing to the native backend is **automatic** the moment S15-02 lands — no combo/`emit_core` change is
needed for *routing*. What S15-04 must guarantee is that, **when `cc` is present**, the NIF `.so` is
**compiled + loaded before any `cell_nif` invoke runs**, so the corpus differential genuinely exercises the
native buffer (not the fallback). If the `.so` is not loaded the heads do **not** crash — under MF3 each
head **delegates to the paged reference** (`nif_available()` is false), so `cell_nif` stays green via the
delegate; the `ensure_nif_loaded()` side-effect simply makes the native arm the one under test wherever a
toolchain exists.

**The wiring (the one edit).** `binding_for` (`combos.gleam:155-164`) is the single, effectful funnel every
tier proof uses to build a `Binding`. Add a `Nif`-only ensure-load side-effect there, so any suite that
builds a `cell_nif` driver transparently triggers the S15-01 build-gate exactly once (idempotent), before
`driver.pipeline_with` is used to invoke:

- `binding_for(c)`: when `c.mem == Nif`, first call the frozen `ensure_nif_loaded()` (S15-01). It compiles
  the `.so` + `load_nif`s the shim on first call (gated on `cc`), and is a cheap no-op thereafter. The
  returned `Binding` is **unchanged** either way (the module atom is identical), so **`tier_differential_
  test.gleam` needs no edit** (`:63`, `:75`) — it keeps calling `combos.shipped` / `combos.binding_for`,
  and now drives native memory. This confines the Phase-15 differential wiring to `combos.gleam` (D1).
- **`cc` present ⇒** the NIF is loaded; `cell_nif` drives the native buffer; the whole-corpus differential
  compares native ≡ paged ≡ atomics ≡ oracle (spec-`.expected`), byte-for-byte, per `Outcome`.
- **`cc` absent ⇒** `ensure_nif_loaded()` reports no-toolchain; the differential must **not** silently
  green on a native claim it did not test. The resolution is **the fallback, made real (MF3):** `rt_mem_nif`
  **retains its paged-delegate fallback** whenever the NIF is unloaded — each head dispatches
  native-if-`nif_available()`-else-`rt_mem` (an S15-02 design property, MF3), so `cell_nif` stays
  byte-identical via the delegate on a `cc`-absent / bare-BEAM host — **still green, no per-file gating, the
  matrix width constant** — and the *native*-specific proof is the categorized skip that lives in
  `rt_mem_nif_safety_test` (§3.2). This mirrors S6's "the paged-delegate remains the fallback so nothing
  regresses," and the **conformance `fail=0` gate holds regardless** (S6). This unit's doc-comment on
  `cell_nif` (`combos.gleam:113-117`) is updated: it no longer reads "the production C NIF is
  documented-deferred / a node-safe skeleton delegating to the paged core" — under `cc` (a loaded `.so`) it
  is the **real native ceiling**, still Unsafe-only (G6), still `TablePaged` (node-safe table axis); without
  `cc` it is the paged-delegate, byte-identical.

`metered` (`combos.gleam:133-141`) still **excludes** `cell_nif` (Nif is `MeterOff` — no fuel counter);
that list is unchanged.

### 3.2 `rt_mem_nif_safety_test.gleam` — the C bounds-check as a containment boundary (S3)

A new suite, distinct in intent from S15-02's general per-op differential (`rt_mem_nif_test.gleam:271-307`,
which proves *bit-identity* over a broad random trace). **This suite is adversarial and security-focused:**
it biases inputs to the boundary and proves the C check *contains* every access — i.e. it is the test S3
demands ("a bug here is a genuine host escape"). It runs against the **real NIF only**, gated on `cc`.

**The containment invariant, and how each check proves it.** Under `mem_tier == Nif` the resource is
produced solely by this tier's `fresh`, so the `Dynamic` in the cell slot is always this NIF's resource
(coercion sound, S3). The C trap condition is the overflow-safe `ea > byte_len || n > byte_len - ea →
MemoryOutOfBounds` (MF2), with `ea = addr + offset` a **no-wrap bignum** computed Gleam-side and decoded
`u64` in C (a failed `enif_get_uint64` — `ea ≥ 2^64` — is itself OOB), and `byte_len ≤ max_bytes`
(reserved). A read/write "escape" takes one of three forms; the suite catches each:

- **An escape into `[byte_len, max_bytes)`** (past the logical end but inside the reservation — *no
  segfault, invisible to `to_flat`*): caught by the **post-`grow` zero-fill probe** — after a trapping
  store near `byte_len`, `grow`, then assert every newly-addressable byte reads `0`. A stale write that a
  bounds bug let slip into the reserved-but-not-yet-logical region would surface here as a non-zero read
  (spec: freshly grown pages are zero-filled, `memory.wast`).
- **An escape into an in-bounds neighbor** (a straddling multi-byte store that writes its in-bounds prefix
  before trapping): caught by **all-or-nothing** assertions — seed a known pattern at `byte_len - k`,
  attempt a store straddling `byte_len`, assert it `Error(MemoryOutOfBounds)` **and** every seeded byte is
  unchanged (trap-before-write, spec exec/instructions "the store is not performed" on trap).
- **An escape past `max_bytes`** (genuine heap corruption / segfault): caught by the **differential** — the
  same adversarial op trace drives nif ≡ paged ≡ oracle with a **`to_flat` byte-image equality every
  step**; a C write outside the buffer either crashes the test process (→ red) or diverges the flat image
  from the memory-safe paged reference (→ red). The paged/oracle backends are memory-safe by construction,
  so the equality is a *sound* containment oracle.

**Inputs (S3: random/edge addresses + counts AT and PAST the boundary, at `grow` watermarks).**

- **Off-by-one at the boundary, every width** `n ∈ {1,2,4,8}` and bulk `count`: access ending exactly at
  `byte_len` is in-bounds (`ok`); `byte_len - n + 1` straddles by one (traps); `byte_len` (traps). Repeat
  at each `grow` watermark: `grow`, re-probe at the *new* `byte_len` and `old byte_len` (now in-bounds,
  reads `0`).
- **No-wrap `ea`:** `addr = 0xFFFFFFFF` with a large `offset` must **trap**, never wrap to a small
  in-bounds `ea` (spec: `ea` is not reduced mod 2³²; a wrap bug would compute an in-bounds address). Assert
  the byte the wrapped `ea` would have hit is untouched (`rt_mem_nif_test.gleam:132-140` is the shape;
  here biased and swept across widths/offsets).
- **memory64 boundary (MF2 — the overflow-safe-check proof).** Over a **`fresh64`-backed** resource, drive
  **64-bit addresses in `[2^64 - 32, 2^64 - 1]`** with assorted `offset`s (so the combined `ea = addr +
  offset` lands at, just below, and past `2^64`), asserting **nif == paged trap-for-trap**. These are the
  vectors a wrapping `(uint64)addr + (uint64)offset` / `ea + n` check would silently pass into an OOB
  `memcpy` (a host escape); the i32-range trace cannot reach them. **The "Security boundary" acceptance row
  (overview §1) is NOT proven until these memory64 vectors exist** — they are load-bearing, not optional.
- **A boundary-biased randomized trace** (deterministic LCG seed so a failure reproduces), heavily
  weighting addresses in `[byte_len - 16, byte_len + 16]`, plus occasional `0xFFFFFFFF`, plus `grow`s that
  move the watermark — driving nif ≡ paged ≡ oracle + `to_flat` identity every step (extending the
  `run_differential`/`gen_op` machinery of `rt_mem_nif_test.gleam:271-308` with a boundary-biased
  `pick_addr`). Multiple seeds.
- **Every mutator on the boundary:** `store`, `init_data`, and the **bulk** ops `fill`/`copy`/`init`
  (spec: `memory.fill/copy/init` trap **before any write** if `dest/src + count > byte_len`; all-or-nothing)
  and the **SIMD byte seam** `store_bytes`/`load_bytes` straddling `byte_len` (all-or-nothing). Each: assert
  the trap **and** that the flat image is unchanged. **Cross-resource `copy` (lesser-c):** one vector with
  `DstRes != SrcRes` (two distinct `fresh` memories) whose `dst`/`src`/`count` straddle **either** buffer's
  `byte_len` — asserting the trap fires, proving `nif_copy` validates **both** handles via
  `enif_get_resource` **before** the `memmove` (a bug that checks only one handle would corrupt or read the
  other memory).

Every OOB case asserts `Error(MemoryOutOfBounds)` (the tier module never calls `rt_trap`; the seam returns
`Error` — `rt_mem_nif.gleam:48-49`), i.e. the C returned the error term rather than crashing. The suite
exercises both families (Cell via `rt_state.seed` + `nif.store/load/...`, Threaded via `nif.t_*` on a
threaded `InstanceState`) so the boundary is proven under both calling conventions.

### 3.3 The four Safe-forbidden gates + the L1 exclusion — confirmed, read-only (S5)

S15-04 **confirms** (does not edit) that the phase widens no posture. The owning tests stay green; this
unit adds a compact **read-only** re-assertion block in `rt_mem_nif_safety_test.gleam` (all calls are pure
`profiles`/`twocore` reads — no ownership conflict) so the security suite is self-proving that `Safe + nif`
and `--link + nif` remain impossible:

1. **`validate_binding` `SafeForbidsNif`** — assert `profiles.validate_binding` of a hand-composed
   `Safe + Nif` binding is `Error(SafeForbidsNif)` (`profiles.gleam:507-508`, `:545`).
2. **`instantiate` node-safe panic** — the `Safe, Nif` panic arm (`profiles.gleam:261-264`) stands; asserted
   structurally by (3) since it is unreachable through the profile API (documented, not driven to panic).
3. **Type-unconstructibility** — every Safe profile constructor names `Paged`; re-use the existing shape of
   `safe_forbids_nif_is_unconstructible_test` (`rt_mem_nif_test.gleam:668-677`) as the invariant:
   `list.all([profiles.safe(), safe_capped(1), safe_metered(1000), instance.safe_default()], mem_tier != Nif)`.
4. **`--link` `LinkTierNif`** — assert `twocore.link_gate(resolve_tiers(Unsafe+Nif), m) == Error(LinkTierNif)`
   (`twocore.gleam:611`, `:622-624`) — a NIF is un-mergeable under **any** mode (the existing proof lives at
   `linked_selfcontained_test.gleam:913-914`; this re-assertion keeps the security suite self-contained).

And **Phase-11 L1 still excludes nif:** the L1 8-way posture matrix `{Safe,Unsafe}×{Cell,Threaded}×
{Paged,Atomics}` at `linked_selfcontained_test.gleam:334-335` **must not** gain a `Nif` row (O8: a NIF
cannot be merged). S15-04 does not touch that file; the DoD verifies the whole suite green so any accidental
widening is caught.

### 3.4 Skip-categorization — the `cc` gate (S6)

Both artifacts gate on `cc` via the S15-01 build-gate, mirroring the Elixir binding arm exactly. The
Gleam-side template is `bindings_compile_call_test.gleam:783-787`:

```
case which("cc") {          // frozen S15-01 gate (os:find_executable, fallback "gcc")
  Error(_) -> io.println("\n[p15-04] cc not on PATH — tier-N native fuzz + matrix SKIPPED "
                         <> "(categorized, S6) — paged-delegate fallback keeps conformance green")
  Ok(_)    -> { /* build+load the .so, run the fuzz + the native cell_nif differential */ }
}
```

The skip is a **categorized print + pass**, never a failure and never a false green (S6). CI
(`ubuntu-latest` gcc) and dev macOS (clang→`cc`) take the `Ok` arm and genuinely build + exercise the NIF;
a toolchain-less environment takes the `Error` arm. The **`cc`-absent path is itself proven to skip** — a
tiny test asserts that when the gate reports no-toolchain, the native assertions are skip-categorized and
the conformance `fail=0` gate is unaffected (S6: "the `cc`-absent path is explicitly tested to skip").

---

## §4. The work (ordered, buildable)

1. **`combos.gleam` (§3.1)** — add the `Nif`-only `ensure_nif_loaded()` side-effect to `binding_for`
   (`:155-164`) + rewrite the `cell_nif` doc-comment (`:113-117`) to describe the native ceiling (Unsafe,
   `TablePaged`) rather than the deferred skeleton. Do **not** edit `tier_differential_test.gleam`.
2. **`rt_mem_nif_safety_test.gleam` (§3.2)** — the `cc`-gated security fuzz: the boundary/no-wrap/grow-
   watermark adversarial cases + the boundary-biased randomized nif≡paged≡oracle `to_flat` differential +
   the post-`grow` zero-fill escape probe + the bulk/SIMD all-or-nothing straddle cases, both families.
3. **The gate re-assertions (§3.3)** — the four Safe-forbidden gates as read-only assertions in the safety
   suite; confirm (by running the whole suite) L1 still excludes nif.
4. **The skip-categorization test (§3.4)** — assert the `cc`-absent path is a categorized skip (not a
   false green).
5. `gleam format` → `gleam build` (**zero warnings**) → `gleam test` (whole suite green with `cc`; the
   native fuzz + native `cell_nif` are exercised — or categorized-skip without `cc`) → verify the
   conformance run is green and byte-identical to `.expected` under `cell_nif` (native when built).
6. Record completion in `state.md` behind S15-02.

---

## §5. Tests (`rt_mem_nif_safety_test.gleam`) — spec-cited + the escape proof

Objective tests against **WebAssembly linear-memory semantics** + the S3 containment contract, **not**
change-detectors (S7/D8). Spec anchors: exec/instructions (a memory access traps iff `ea + sizeof > length`,
`ea = i + offset` **no wraparound**; multi-byte store not performed on trap; `memory.fill/copy/init` trap
conditions), exec/modules (active-data / segment bounds), syntax/values (little-endian, IEEE bits).

1. **Off-by-one containment, every width, at every `grow` watermark.** Access ending exactly at `byte_len`
   is `ok`; `byte_len - n + 1` and `byte_len` trap (`Error(MemoryOutOfBounds)`); after `grow`, re-probe at
   the new/old watermarks. Cite exec/instructions bounds; `memory_size.wast`.
2. **No-wrap `ea` traps, never wraps — incl. the memory64 boundary (MF2).** `addr = 0xFFFFFFFF` + large
   `offset` traps across widths/offsets; the byte the wrapped `ea` would hit is untouched. **And, over a
   `fresh64`-backed resource, 64-bit addresses in `[2^64 - 32, 2^64 - 1]` with assorted offsets trap
   nif == paged, trap-for-trap** — the vectors that expose an overflow-wrapping C check as an OOB `memcpy`
   host escape (the i32 trace cannot reach them). **The "Security boundary" acceptance row is not proven
   until these exist.** Cite `address.wast` / exec/instructions no-wraparound + memory64 addressing.
3. **All-or-nothing on the boundary (the write-escape proof).** A straddling `store` / `init_data` /
   `fill` / `copy` / `init` / `store_bytes` traps **before any byte is written** — seeded in-bounds bytes
   stand. **Incl. a cross-resource `copy` (`DstRes != SrcRes`, lesser-c): a two-memory `copy` straddling
   either buffer's `byte_len` traps, proving `nif_copy` checks BOTH handles via `enif_get_resource` before
   the `memmove`.** Cite exec/instructions (store not performed on trap) + the bulk-op trap conditions.
4. **Post-`grow` zero-fill escape probe.** After trapping stores near `byte_len`, `grow`, then every
   newly-addressable byte reads `0` (a stale escaped write into the reserved region surfaces here). Cite
   `memory.wast` zero-fill.
5. **The boundary-biased differential (the containment oracle).** A deterministic-seed randomized trace,
   biased to `[byte_len±16]` + `0xFFFFFFFF` + `grow`s, drives nif ≡ paged ≡ oracle with `to_flat` equality
   **every step**; multiple seeds. This is S3's "no read/write lands outside `[0, byte_len)`" proof against
   the memory-safe reference — a C bounds bug crashes or diverges. Cite exec/instructions memory.
6. **The four Safe-forbidden gates (S5, read-only).** `validate_binding(Safe+Nif) == Error(SafeForbidsNif)`;
   every Safe profile's `mem_tier != Nif` (unconstructibility); `link_gate(Unsafe+Nif, m) ==
   Error(LinkTierNif)`. Cite G6/O8.
7. **The `cc`-absent path skips, never false-greens (S6).** When the gate reports no toolchain, the native
   assertions are categorized-skipped and the conformance `fail=0` gate is unaffected.

> The **general** per-op nif≡paged≡oracle bit-identity differential is **S15-02's** (`rt_mem_nif_test.gleam`
> against the real NIF); the **unchecked**-head correctness is **S15-03's** (`emit_unchecked_test`). This
> suite is the **security boundary** proof only, to keep each file single-substantive-owner.

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. Spec-cited security-fuzz tests (§5) green **against the real NIF when `cc` present** — the containment
   proof (off-by-one, no-wrap **incl. the memory64 boundary vectors (MF2)**, all-or-nothing **incl. the
   cross-resource two-memory `copy` (lesser-c)**, post-`grow` zero-fill, the boundary-biased differential); the
   `cell_nif` combo drives **native** memory across the whole corpus differential (`tier_differential_
   test.gleam:63`/`:75` green under native `cell_nif`) and equals the spec `.expected`. **Or a categorized
   skip when no `cc`** (§3.4) — never a false green; conformance `fail=0` holds either way.
2. `///` contract docs on every new function/type in `rt_mem_nif_safety_test.gleam` (each fuzz generator +
   invariant states what it upholds and what an escape would look like); the `combos.gleam` `cell_nif` doc
   + `binding_for` ensure-load side-effect documented.
3. `gleam format --check src test` clean.
4. `gleam build` **zero warnings** (no unused import/var; the ensure-load `@external`/wrapper wired clean).
5. The whole test suite passes (native `cell_nif` + native fuzz exercised with `cc`, or categorized-skip
   without); the four Safe-forbidden gates and the Phase-11 L1 exclusion (`linked_selfcontained_
   test.gleam:334-335`) **still hold** (verified by the suite staying green — no widening); default
   tier-P/O output byte-identical (this unit adds no `src/` change).
6. Completion recorded in `state.md` behind S15-02.

---

## §7. What it leaves (handoff to the capstone S15-05)

- **The "Bit-identical tier" acceptance row** — S15-05 cites this unit's green **native** `cell_nif` whole-
  corpus differential (native ≡ paged ≡ atomics ≡ oracle, both families) as the proof that the real C NIF
  is bit-pattern-identical to the paged reference for every access.
- **The "Security boundary" acceptance row** — S15-05 cites this unit's containment fuzz (the C bounds-check
  traps in C and never escapes `[0, byte_len)`), **including the memory64 boundary vectors (MF2) without
  which the row is not proven**, as the tested trust boundary.
- **The "Toolchain-gated CI" acceptance row** — S15-05 cites the `cc`-gated skip-categorization (§3.4) as
  the "builds+runs under CI, categorized-skip when absent, never a false green" evidence.
- **Left to the capstone (not this unit):** the measured **nif column** in `docs/phase-4-benchmark.md`, the
  `docs/phase-15-tier-n.md` methodology/ceiling/packaging-follow-on write-up, the `docs/wasm-conformance.svg`
  regen, and `../01-status.md` — S15-05's single benchmark/status point. This unit ships **no `docs/`**, no
  `src/`, and no benchmark; only the security proof + the native-matrix wiring that the capstone measures
  and reports.
