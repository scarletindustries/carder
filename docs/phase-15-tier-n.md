# Phase 15 — production tier-N C NIF for linear memory

> The tier-N `nif` memory backend, deferred since Phase 4 for want of a native toolchain, is now a
> **real `erl_nif` C backend** (`c_src/twocore_rt_mem_nif.c`) over a **reserved raw byte buffer**
> managed by an ERTS resource — the raw `O(1)` native memory ceiling — replacing the paged-delegating
> skeleton. It is **bit-identical to the paged reference for every access** (the differential is the
> proof), **Unsafe-only / Safe-forbidden** (the four fail-closed gates, unchanged), and
> **un-`--link`-able** (a NIF cannot be merged into a self-contained `.beam`). It also fills the
> `*_unchecked` fast-path heads tier-N previously lacked, so the Phase-10 loop-versioned arm now runs a
> **raw native deref** on tier-N. Default output is unchanged (tier-N is opt-in); conformance is
> unchanged (`47,734 / 683 / 0`, `fail == 0`). MEASURED, never promised — **no hero number**.

---

## What shipped

A runtime-tier phase: **no frontend, no IR, no optimizer-semantics change**. The tier stays a
build-time module swap behind the `emit_core` seam (`mem_module = "twocore@runtime@rt_mem_nif"`), so
`emit_core` routes to it unchanged the moment `binding.mem_tier == Nif`.

| Piece | What landed |
|---|---|
| **The native C core** (`c_src/twocore_rt_mem_nif.c`, S15-02) | The 16 frozen ops — `load`/`store`/`size`/`grow`/`init_data`/`load_bytes`/`store_bytes`/`fill`/`copy`/`init` (+ `_unchecked` twins, `nif_available`, `nif_ping`, `to_flat`) — over a `twocore_mem_t { size_t byte_len; size_t max_bytes; unsigned char data[]; }` reserved buffer via an ERTS resource. Little-endian byte moves; f32/f64 raw IEEE-bit moves (never a BEAM `double` round-trip); sub-word signed sign-extension to the result width; `grow` bumps `byte_len` within the reserved `max_bytes` (a moving watermark, **never** `enif_realloc`'d — the resource identity is stable). |
| **The Gleam heads** (`src/twocore/runtime/rt_mem_nif.gleam`, S15-02) | Every frozen head (Cell + Threaded, `_at` twins, bulk, SIMD byte seam, `*_unchecked`) dispatches on `nif_available()`: native `@external` when the `.so` is attached, else the byte-identical paged delegate (`rt_mem`). The Gleam keeps the pdict/record/mem-index plumbing **and the `rt_meter` fuel charges** (metering byte-identical to paged/atomics); the C owns only the pure `mem_*` algebra. The combined no-wrap effective address `ea = addr + offset` is computed Gleam-side as a BEAM bignum — the C never re-adds. |
| **The unchecked lever** (S15-03) | `Nif` added to `emit_core.mem_supports_unchecked` (a one-line fail-closed whitelist entry) + the `emit_unchecked_test` flip (`nif_emits_unchecked_test`). The Phase-10 BCE fast arm now emits `nif_load_unchecked`/`nif_store_unchecked` on tier-N; the slow arm keeps the **checked** native seam — trap-preservation is absolute (the range guard proves the whole span in-bounds before the unchecked arm runs). |
| **The security fuzz + native matrix** (S15-04) | The C bounds-check fuzz (`rt_mem_nif_safety_test.gleam`) + `combos.cell_nif` driving the **real native buffer** across the corpus tier differential. |

---

## The trust boundary (the tested security boundary, S3)

tier-N is **Unsafe-only** and **Safe-forbidden** at four fail-closed gates, all re-confirmed
(read-only) by the capstone:

1. `profiles.validate_binding` → `Error(SafeForbidsNif)` (`Safe + Nif` rejected at link).
2. `profiles.instantiate` → a node-safe panic on `Safe, Nif`.
3. **Type-unconstructibility** — no Safe profile names `Nif` (every Safe profile names `Paged`).
4. The CLI `--link` gate → `LinkTierNif` — a NIF cannot be merged into a self-contained `.beam` under
   any mode; tier-N stays excluded from the `--link` differential matrix (O8).

The **C bounds-check is the security boundary and is tested as one** — a bug there is a genuine *host
escape* (an out-of-bounds read/write past the ERTS-owned buffer), which is exactly why tier-N is
Unsafe-only. It is **overflow-safe for memory64** (MF2): every address/count operand is decoded with
`enif_get_uint64` (a failed decode — negative or `>= 2^64` — is itself out-of-bounds), then checked
with **guarded subtractions that cannot wrap** —

```c
if (ea > byte_len)      -> MemoryOutOfBounds   /* no add; cannot overflow    */
if (n  > byte_len - ea) -> MemoryOutOfBounds   /* byte_len - ea >= 0 here     */
```

— never the wrap-prone `ea + n > byte_len` (a 64-bit `ea` could overflow-wrap past it into an OOB
`memcpy`), always against `byte_len` (the live watermark), never `max_bytes` (the reservation
ceiling). Multi-byte stores / `fill` / `copy` / `init` are **trap-before-write / all-or-nothing**. The
adversarial fuzz (`rt_mem_nif_safety_test.gleam`) — off-by-one at every width and at `grow`
watermarks, the no-wrap `ea` vectors, the **memory64 `[2^64-32, 2^64-1]` overflow vectors** (without
which this row is not proven), all-or-nothing straddles, a **cross-resource** `copy` proving *both*
handles are checked, and a post-`grow` zero-fill escape probe — proves the trap fires **in C** and no
access lands outside `[0, byte_len)`.

---

## The C-build / test / CI story (methodology)

The repo has **no native-build infrastructure**: `gleam build` compiles `src/*.erl` but **not**
`c_src/*.c` (Gleam has **no native pre-build hook**) — so the `.so` is built **out of band**. Rather
than invent a build system, the phase adopts the repo's own **Phase-12 binding-harness pattern**:
compile the NIF **at test time** via a `cc`-gated `cc -shared -fPIC` into a tempdir and
`erlang:load_nif`, **skip-categorized when no `cc`** (exactly as the Elixir binding arm skip-gates on
`elixirc`).

- **Toolchain gate.** `cc` (fallback `gcc`) is resolved with `os:find_executable`; `erl_nif.h` is
  located via a **candidate-list resolver** that picks the first path actually holding the header —
  **not** the bare `code:lib_dir(erts, include)`, which returns a *header-less* path on homebrew OTP 29.
- **Per-platform flags.** darwin carries **`-undefined dynamic_lookup`** (MANDATORY — a NIF's `enif_*`
  symbols are undefined at link time and resolved from the host beam at load; macOS `ld` rejects them
  without it: `Undefined symbols … _enif_make_atom`); Linux `-shared` suffices.
- **CI genuinely builds and exercises the NIF, with no workflow edit.** CI (`ubuntu-latest`) ships
  `gcc`/`cc`, so the build-gate resolves `cc` and the tier-N native differential + fuzz **run** there;
  dev macOS uses `clang`. Where no `cc` is present, every tier-N-native assertion is a **categorized
  skip**, and the `cc`-absent path is **itself tested to skip** (`build_gate_is_categorized_not_false_green_test`)
  — never a false green. The conformance `fail == 0` gate holds regardless.

---

## Native-when-loaded, paged-delegate-otherwise (the honest deployment story, MF3)

tier-N is the raw native ceiling **only when the `.so` is present**. Every `rt_mem_nif` head dispatches
on `nif_available()` (a cheap cached-atom read, `true` only when the `.so` is attached):

- **loaded** (CI ubuntu gcc, dev macOS clang, a packaged deployment) → the native arm sources the ERTS
  resource handle and calls the `nif_`-prefixed `@external`s — real native memory.
- **not loaded** (a bare BEAM, no `cc`, no `priv/*.so`) → the *same* head transparently delegates to
  the paged core `rt_mem`, byte-identical by construction, with **no per-file gating**.

This is **not a regression** — it is the deployment contract: the tier `runs_anywhere` (Phase-11),
native where the `.so` is loaded, paged everywhere else. The corpus differential proves
`native == paged` wherever `cc` is present.

> **Honest scope note (the conformance point runs the delegate).** The whole-corpus **tier
> differential** (`combos.cell_nif`) and the dedicated **security fuzz** drive the **real native
> buffer** (verified: 33 `cell_nif` bindings saw `nif_available == true`). The conformance
> `cell_nif` point, however, runs the **bit-identical paged delegate** — a documented
> test-harness-resource-lifecycle reason, not a semantics gap: the S15-01 keystone probe opens its
> resource type `ERL_NIF_RT_CREATE`-only (no `TAKEOVER`), so a shim reload fails while any NIF
> resource is live, and the conformance harness spawns each instance in an unlinked orphan process that
> holds its memory forever. Force-loading the `.so` during the pre-probe conformance matrix would
> permanently break the probe. The resolution (honest, `fail == 0`): `combos.binding_for` **reuses** an
> already-attached `.so` but never force-loads, so the corpus tier differential runs native while the
> conformance `cell_nif` point stays the byte-identical paged delegate. **The native tier is proven via
> the S15-02 per-op differential + the S15-04 security fuzz + the corpus tier differential** (all
> self-asserting against the real `.so`), not via the conformance point.

**Imported-memory native load/store is a documented gap.** A module may `(import "spectest" "memory"
…)`, and `link.spectest_export` builds that memory with the **paged** tier unconditionally — so under a
loaded `.so` the `mem` slot can hold a paged `Mem` even though `nif_available()` is `true`. The
instantiation-time **segment + bulk writers** (`init_data*`/`fill`/`copy`/`init` + `t_*` twins)
discriminate on the handle shape (`is_native_mem`) and **delegate an imported paged handle to
`rt_mem`** (byte-identical, so an OOB active-data segment returns `Error(MemoryOutOfBounds)`, not a
`badarg`). Native load/store *directly on an imported memory* is out of scope this phase — imported
memories run paged.

---

## The measured ceiling (honest, no hero number)

Measured on the Phase-4 reference machine (Apple M2 Pro, macOS, OTP 29 / erts 17.0.2, dev `clang`),
the smoke `twocore_smoke.wasm` (CRC-32 / SHA-256 / DEFLATE real crates) held **fixed**, only the linked
`Binding` varied, each build **correctness-gated bit-exact vs `wasmtime` before it was timed**.
Reproduce with `./smoke/bench.sh 100 1024 300` (the `nif` column is compiled out of band and gated;
absent `cc` it is a categorized dash). See `docs/phase-4-benchmark.md` for the full frame. The figures
below are a single same-run measurement, which reproduced the committed Phase-4 columns within
run-to-run variance (±~10%, light machine load).

**ns / call (same run, `--ceiling --tier nif --cap 1024`):**

| kernel | safe / paged | atomics-safe | ceiling (atomics) | **nif (tier-N native)** | hand-Erl / native |
|---|---:|---:|---:|---:|---:|
| `crc32(4096)` (load-heavy) | 4,248,190 | 1,762,850 | 1,403,480 | **1,027,780** | 53,480 |
| `sha256_word(4096)` (mixed) | 20,760,650 | 7,815,700 | 7,900,290 | **5,254,520** | 40,050 |
| `deflate_rt(2000)` (store-heavy) | 67,447,650 | 20,277,250 | 13,439,700 | **10,687,900** | 40,000 |

Same-run derived ratios: `atomics → nif` = **1.7× / 1.5× / 1.9×** (crc / sha / deflate); `nif → ref`
(the residual to hand-written-Erlang / native) = **19.2× / 131.2× / 267.2×**. tier-N native is the
**fastest** build on all three kernels (it beats even `ceiling` on tier-O atomics), most on store-heavy
DEFLATE.

**The cleanest isolation — the *same* `nif` `.beam`, same session, toggling ONLY whether the `.so` is
loaded** (native vs the paged-delegate fallback on the identical compiled artifact; both bit-exact):

| kernel | native (.so loaded) | paged-delegate (no .so) | **native speedup** |
|---|---:|---:|---:|
| `crc32(4096)` (load-heavy) | 1,248,260 | 3,869,300 | **3.10×** |
| `sha256_word(4096)` (mixed) | 5,273,630 | 21,116,200 | **4.00×** |
| `deflate_rt(2000)` (store-heavy) | 10,542,400 | 60,376,350 | **5.73×** |

The win **tracks store intensity exactly as predicted**: store-heavy DEFLATE gains most, load-heavy
CRC-32 least. That is the honest ceiling:

- **`atomics → nif` removes two costs `atomics` leaves on the table.** The 64-bit-word
  read-modify-write mask on sub-word/unaligned stores becomes a raw byte `memcpy` (so the store-heavy
  DEFLATE kernel gains most), and on the loop-versioned fast arms tier-N now emits **native unchecked
  derefs** (the bounds compare elided — the S15-03/S4 lever).
- **The floor that remains.** The **per-access inter-module seam call** (`call
  'twocore@runtime@rt_mem_nif':'<op>'(...)`, a build-controlled module atom **never inlined** into the
  caller) is present in **every** tier including `nif`; the NIF removes it **only** for the unchecked
  loop bodies the optimizer strips to a raw deref, never for the checked per-op seam. And **tier-P
  `bif` numerics are untouched** (tier-N numerics is out of scope, S8) — so on the numerics-dominated,
  load-heavy CRC-32 the residual is dominated by the bignum ops native *memory* cannot touch, whereas
  on store-heavy DEFLATE the raw-`memcpy` win is real and measurable.
- **State plainly: the tier-N memory ceiling does NOT reach hand-written Erlang.** It removes the
  *memory* constant, not the *numeric* one and not the *seam*. `nif → ref` on the pure CRC-32
  head-to-head is still **~19× slower** than hand-written Erlang (whose `band`/`bxor`/`bsr` are inlined
  machine ops, while 2core's are tier-P bignum BIF calls); SHA-256 / DEFLATE remain ~131× / ~267× below
  the native `crypto`/`zlib` **ceiling** (compiled-from-wasm code vs hand-optimised C NIFs — a ceiling,
  not a peer). No hero number.

---

## The production `priv/*.so` packaging follow-on (S8, explicit)

The test-time build is **proof, not deployment**. A real deployment ships a **prebuilt per-platform
`priv/twocore_rt_mem_nif.so`** loaded by the shim's `-on_load` from `priv/` — a build step **Gleam
cannot hook natively**, so it is out of scope this phase and documented as the next unit of work:
compile-per-target-triple + `priv/` packaging + a load-path resolution convention. The benchmark's
out-of-band `.so` step (`smoke/bench.sh` §0.5) is this follow-on **in miniature** — it demonstrates
precisely what production packaging will generalize per-platform. Until then, the shim resolves the
`.so` via the `TWOCORE_RT_MEM_NIF_SO` env override (test/bench time) else `priv/twocore_rt_mem_nif`
(deployment), and falls back to the paged delegate on a bare BEAM.

---

## Honest scope (S8 — stated, not hidden)

- **tier-N linear memory only.** **Not** tier-N numerics (`rt_num` stays tier-P `bif` — the biggest
  remaining lever the Phase-4 residual points at) and **not** hardware SIMD (`rt_simd` stays emulated).
- **Test-time compiled `.so`, gated.** The production `priv/*.so` packaging is the documented follow-on
  above.
- **Unsafe-only + un-`--link`-able.** The four fail-closed gates are preserved verbatim; tier-N stays
  excluded from the `--link` merge matrix and from any Safe posture. This phase added **capability**,
  not posture.
- **No frontend / IR / optimizer-semantics change** beyond the `rt_mem_nif` bodies, the `*_unchecked`
  heads, and the one-line `emit_core` whitelist entry — which is exactly why default tier-P/O output
  stays byte-identical and conformance stays `47,734 / 683 / 0`.

---

## Reproduce

```
gleam test -- twocore/runtime/rt_mem_nif_test         # per-op nif ≡ paged ≡ oracle differential (gated on cc)
gleam test -- twocore/runtime/rt_mem_nif_safety_test  # the C bounds-check security fuzz (incl. memory64 vectors)
gleam test -- twocore/backend/emit_unchecked          # tier-N emits unchecked (the S15-03 flip)
gleam test -- twocore/tier/tier_differential          # the whole-corpus cell_nif tier differential (native)
gleam test                                            # the full suite (native rows under cc; categorized-skip without)
./smoke/bench.sh 100 1024 300                         # the measured nif column (out-of-band .so; dash without cc)
```

The native-differential rows are **`cc`-dependent**: under CI `gcc` / dev `clang` they run against the
real `.so`; with no `cc` they categorized-skip. The conformance headline (`47,734 / 683 / 0`,
`fail == 0`) is unchanged either way.
</content>
</invoke>
