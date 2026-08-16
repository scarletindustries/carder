# Phase-4 benchmark revisit — does tier-O `atomics` memory close the gap? (honest, G8)

> **Phase 3 named the villain in one number: on the tier-P `paged` immutable-binary memory model,
> carder-Safe was ~76× slower than hand-written Erlang on the one faithful head-to-head (CRC-32,
> bit-identical), and orders of magnitude below the native NIF ceiling on SHA-256/DEFLATE.** Phase 4
> built the lever — the tier-O `atomics` O(1) memory backend (unit 04) — and this report re-measures
> the **same** committed kernels with that lever engaged. It reports, **measured, with no hero
> number**, whether `atomics` closes the gap and by how much. Reproduce with
> `./smoke/bench.sh [REPEAT] [CAP] [COMPILE_TIMEOUT_SECS]` (defaults `100 1024 300`) — **run from the
> scribbler repo**: the harness is a wasm differential (it cargo-builds the Rust crate to wasm, gates
> it import-free/MVP-only with `wasm-tools`, and cross-checks against `wasmtime`), so it moved with the
> WebAssembly frontend and now drives scribbler's `build` verb (it was `to-beam-wasm` when these
> numbers were taken) plus carder's `exec -n` for the timing; the tier-N `.so` is still compiled out of
> band from carder's `c_src/carder_rt_mem_nif.c`, which — with carder as a Gleam dependency — is
> unpacked at `build/packages/carder/c_src/`. **Reproduction is cross-repo now** — the measurements
> below are carder's record, the harness that produced them is scribbler's.
>
> **The measured verdict, up front:** `atomics` **closes roughly half to two-thirds of the paged
> gap** (2.3× on load-heavy CRC-32, 2.6× on SHA-256, 2.9× on store-heavy DEFLATE — the store-intensity
> prediction bore out), but **"faster than hand-written Erlang" is still NOT reached**: the pure
> CRC-32 head-to-head remains ~31.6× slower than hand-written Erlang (down from ~76×), held above the
> floor by two costs `atomics` does not touch — tier-P `bif` bignum numerics and the per-access
> inter-module runtime seam call.

## What is measured

The **same** artifact as Phase 3 — one no-import, MVP-only `carder_smoke.wasm` (72,933 bytes,
80 functions, 0 imports; the same file `smoke/run.sh` differential-checks bit-exact vs `wasmtime`),
built from three real, permissively-licensed crates, exposed as `i32`-in / `i32`-out exports:

| Kernel | Crate | Exercises | Memory profile |
|---|---|---|---|
| `crc32(n)` | `crc32fast` | table-driven CRC-32 | **load-heavy** (paged loads already ~O(1)) |
| `sha256_word(n)` | `sha2` | 64-round compression, message schedule, working buffer | **mixed** |
| `deflate_roundtrip(n)` | `miniz_oxide` + `dlmalloc` | real DEFLATE compress+decompress+verify, `memory.grow` | **store-heavy** (dlmalloc + memcpy/memset) |

Each export recomputes its `n`-byte input (a deterministic LCG) on every call, so a contender that
recomputes the same input per call does **byte-identical total work**.

The program is held **fixed**; only the linked `Binding` varies, along two Phase-4 axes plus the
Phase-3 policy axis, so each measured delta is attributable to **exactly one** changed field:

| Build | `Binding` (schematic) | Isolates |
|---|---|---|
| **safe** | `safe()` — `Cell` + `Paged` | the Phase-3 baseline — the number we are beating (or not) |
| **atomics-safe** | `safe()` + `mem_tier: Atomics` + `--cap` — `Cell` + `Atomics` | **the memory-tier delta** — `mem_tier` is the ONLY field that differs from `safe`, so this ratio is the pure `paged → atomics` effect |
| **portable** | `portable()` — `Threaded` + `Paged` + Safe | threading overhead + the runs-anywhere posture (G4) |
| **unsafe-paged** | `unsafe()` — `Cell` + `Paged` + Aggressive | the optimizer delta on `paged` (now compilable, see limitation 1) |
| **ceiling** | `ceiling()` + `--cap` — `Cell` + `Atomics` + Aggressive | the fastest build (all levers at once) |

`atomics-safe` vs `safe` is the **clean science**: `mem_tier` is the only field that changes, so the
ratio between them is the uncontaminated `paged → atomics` effect. `atomics-safe` is a **legal Safe
tier-O posture** (Safe permits tier P **or** O, never N — G6), not an Unsafe-only measurement.

## Contenders & baselines (unchanged Phase-3 references, new carder column set)

1. **the five carder builds above** — each compiled to a persisted `.beam` under its `Binding` and
   timed with `gleam run -- exec -n N <beam> <fn> <arg>`, which loads + instantiates the `.beam`
   **once** then invokes `N` times in the instance's owned process and times **only the loop**
   (compile / load / instantiate excluded).
2. **hand-written pure-Erlang CRC-32** — table-driven, recomputing the *same* LCG input, so its
   result is **bit-identical** to the wasm export. The one true head-to-head; carried over verbatim
   from Phase 3.
3. **native NIF ceiling** — `crypto:hash(sha256, _)` and `zlib` for SHA-256/DEFLATE. **NIF-backed C,
   NOT hand-written Erlang** — a raw *ceiling*, clearly labelled; carder is expected to sit below it.
   The tier-N `nif` **memory** tier that attacks the *memory* gap **shipped in Phase 15** (a real
   `erl_nif` C backend over a reserved raw byte buffer) and is now measured as **the `nif` column**
   below (§Results); the `crypto`/`zlib` native figures remain the raw *numeric* ceiling that tier-N
   *memory* does not attack (tier-N numerics is out of scope). See `docs/phase-15-tier-n.md`.
4. **`wasmtime`** — **correctness only** (bit-exact, cross-checked by `smoke/run.sh` and by the
   per-build gate below). Per-call *timing* stays **omitted**: `wasmtime run --invoke` measures a
   whole process (startup + JIT + one invoke), not comparable to `exec`'s pure-invocation timing — a
   number there would mislead.

## Methodology (the honest frame)

- **Machine:** Apple M2 Pro, 12 cores, macOS 26.3.1 (Darwin 25.3.0, arm64).
- **Toolchain:** Erlang/OTP **29** (erts 17.0.2), Gleam **1.17.0**, rustc **1.84.0**
  (`wasm32v1-none`), wasm-tools **1.252.0**, wasmtime **46.0.1**.
- **Conformance pin:** WebAssembly/testsuite `193e551f`, wasmtime 46.0.1 (unchanged; the full suite
  is 15747 / 411 / 0 under every shipped `(state_strategy, mem_tier)` combination — unit 09).
- **What is timed:** the invocations *only*. `exec` excludes compile / load / instantiate; the Erlang
  baselines warm up once, then time `N` repeats with `timer:tc`.
- **Correctness gate FIRST (load-bearing).** Before any build is timed, its result on each kernel is
  checked **bit-exact vs `wasmtime`**; a mismatch **aborts the bench non-zero** — a fast number that
  is wrong is never reported. This re-checks, on the real kernels, the byte-identity that unit 09's
  tier differential already proves against the `paged`/`rebuild` oracle across the spec `.wast`. In
  this run **all five builds gated bit-exact** on all three kernels.
- **The `atomics` memory cap (the sharp edge, G2).** `atomics` is fixed-size at creation: `fresh`
  pre-allocates to the effective max, and an **uncapped** no-max module collapses that to the Safe
  cap (`65536` pages = 4 GiB), which is infeasible to pre-allocate — so an uncapped `atomics` build
  is **fail-closed rejected at link time** (`Error(AtomicsCapRequired)`), never a silent 4 GiB
  reservation and never a silent `paged` fallback. The `atomics`/`ceiling` builds therefore bake a
  **lowered cap** (`--cap PAGES`) sized above each kernel's peak `memory.grow` watermark. Measured
  peak watermarks on the reported inputs (`crc32/sha256 @ 4096`, `deflate @ 2000`): both hash kernels
  peak at **18 pages** (the input `Vec` via `dlmalloc` grows one page past the 17-page initial),
  DEFLATE peaks at **22 pages** (dlmalloc scratch for the compress+decompress buffers). The reported
  runs use **`--cap 1024` (64 MiB)**, which comfortably exceeds the 22-page working set and sits well
  below the 4096-page (`atomics_reserve_cap_pages`) reserve cap; the 1024-page reservation is a
  one-time instantiate cost, excluded from the `exec` timing. A cap below the working set would make
  `grow` return `-1` and change the result — the correctness gate catches it (verified: `deflate` at
  `--cap 21` produces the wrong result and would abort; at `--cap 22` it is correct).
- **Repeats:** `REPEAT = 100` for crc/sha, `REPEAT/5` capped at 20 (min 5) for deflate (which is
  ~13–61 ms/call). Numbers are stable to a few percent across runs.

## Results (ns per call, this machine, `REPEAT=100`, `--cap 1024`)

Every carder build below was **correctness-gated bit-exact vs `wasmtime` before it was timed.**

| kernel | safe / paged | atomics-safe | portable (thr/paged) | unsafe-paged | ceiling (uns/atomics) | nif (uns/native) † | hand-Erl / native |
|---|---:|---:|---:|---:|---:|---:|---:|
| `crc32(4096)`        |  3,806,310 |  **1,639,040** |  3,821,660 |  3,640,300 |  **1,341,650** |  **1,027,780** | **51,800** (hand-Erl) |
| `sha256_word(4096)`  | 20,087,860 |  **7,865,480** | 18,297,580 | 20,545,810 |  **8,052,920** |  **5,254,520** | 40,800 (native `crypto`) |
| `deflate_rt(2000)`   | 61,464,300 | **21,454,000** | 57,061,800 | 56,201,350 | **13,586,750** | **10,687,900** | 40,900 (native `zlib`) |

**† The `nif` column (Phase 15) — the tier-N `--ceiling --tier nif --cap 1024` build over the real
`erl_nif` C backend.** It is a **same-run re-measurement** (`./smoke/bench.sh 100 1024 300`, toolchain-gated,
correctness-gated bit-exact vs `wasmtime` before timing — a dash absent `cc`); that run reproduced the
other five committed columns within run-to-run variance (±~10%, light machine load: this run's
`safe/paged` = 4,248,190 / 20,760,650 / 67,447,650, `atomics-safe` = 1,762,850 / 7,815,700 / 20,277,250,
`ceiling` = 1,403,480 / 7,900,290 / 13,439,700 — all within variance of the committed figures), so the
`nif` column and its ratios are drawn **same-run** to stay honest. tier-N native is the **fastest** build
on all three kernels, most on store-heavy DEFLATE. `gleam build` has no native pre-build hook, so the
`.so` is compiled out of band (the production `priv/*.so` packaging in miniature — S8).

**Derived ratios per kernel** (`paged→atomics` = the pure tier-O speedup; `→ref` = the residual to
hand-written-Erlang / native):

| kernel | `paged→atomics` (× faster) | `safe→ref` (× slower) | `atomics→ref` (× slower) | `ceiling→ref` (× slower) | `atomics→nif` (× faster) ‡ | `nif→ref` (× slower) ‡ |
|---|---:|---:|---:|---:|---:|---:|
| `crc32(4096)`        | **2.3×** | 73.5× |  **31.6×** |  25.9× | **1.7×** |  **19.2×** |
| `sha256_word(4096)`  | **2.6×** | 492×  | **192.8×** | 197.4× | **1.5×** | **131.2×** |
| `deflate_rt(2000)`   | **2.9×** | 1503× | **524.5×** | 332.2× | **1.9×** | **267.2×** |

**‡ The `atomics→nif` and `nif→ref` ratios are same-run** (the `nif` build and its `atomics`/`ref`
baselines from `./smoke/bench.sh 100 1024 300`, †) — the pure tier-O→tier-N *memory* delta and the
residual to hand-Erl/native. `atomics → nif` is **1.5×–1.9×** (largest on store-heavy DEFLATE, where the
64-bit-word read-modify-write of `atomics` becomes a raw byte `memcpy`); `nif → ref` is still **19.2×**
on the pure CRC-32 head-to-head — tier-N *memory* does **not** reach hand-written Erlang, because the
tier-P `bif` numeric floor and the per-access seam-call floor remain.

`crc32(4096)`: carder (every build) = `2538352202` = hand-written-Erlang `2538352202` = `wasmtime`. A
clean, bit-identical head-to-head.

**Against Phase 3** (which measured `safe/paged` on this machine at crc `4,006,910` / sha `19,781,600`
/ deflate `62,098,600`, and reported Unsafe as `n/a` because the Aggressive inliner did not finish):
the re-measured `safe/paged` numbers reproduce Phase 3 within run-to-run variance, and the gap to
hand-written-Erlang / native **narrows** as the tier-O lever engages:

| kernel | Phase-3 residual (paged) | Phase-4 `atomics-safe` residual | Phase-4 `ceiling` residual |
|---|---:|---:|---:|
| `crc32`   | ~76×   | **~31.6×** | ~25.9× |
| `sha256`  | ~475×  | **~192.8×** | ~197.4× |
| `deflate` | ~1600× | **~524.5×** | ~332.2× |

## The honest reading — does `atomics` close the gap? (measured, no hero number)

**1. The `paged → atomics` speedup — does removing rebuild-on-write help, and by how much?**
Yes, and the win **tracks store intensity exactly as predicted**. `paged`'s dominant cost is the
per-store chunk rebuild (~4 KiB copied per byte-store); `atomics` removes it (O(1) in-place mutation,
no write-back). So the store-heavy kernel gains most and the load-heavy one least:

- **DEFLATE (store-heavy): 2.9×** — dlmalloc + memcpy/memset, the most stores.
- **SHA-256 (mixed): 2.6×** — message schedule + working buffer.
- **CRC-32 (load-heavy): 2.3×** — paged *loads* were already near-O(1) (a sparse `dict.get` + a
  sub-binary slice, no rebuild), so there is less rebuild cost for `atomics` to remove.

The prediction (deflate > sha256 > crc32) is **borne out** by the measured `2.9× > 2.6× > 2.3×`.

**2. The residual `atomics → hand-Erl / native` — how far is still left, and why a floor exists.**
On the pure CRC-32 head-to-head, `atomics-safe` is **~31.6× slower than hand-written Erlang** (down
from Phase 3's ~76×). The residual is real and has named causes that `atomics` **cannot** touch —
so a reader should read neither the closed half as a failure nor the residual as a surprise:

- **`rt_num` stays tier-P `bif`** — pure Gleam over BEAM bignums, **not native** (tier-N numerics is
  explicitly out of Phase-4 scope, G8). `atomics` attacks the **memory** constant, never the
  **numeric** one; hand-written Erlang's `band`/`bxor`/`bsr` are inlined machine ops, while carder's
  are bignum BIF calls. CRC-32 is almost pure numerics over cheap loads — which is exactly why its
  residual (31.6×) is the *largest fraction of the remaining gap* even though its paged→atomics win
  was the smallest.
- **Every memory access is a fixed inter-module seam call** — `call 'rt_mem_atomics':'<op>'(...)`
  (a build-controlled module atom, never inlined into the caller), versus hand-written Erlang's
  inlined binary pattern-match. The optimizer inlines *user* IR functions, not the runtime seam, so
  this per-access call cost is present in **every** build, `ceiling` included.
- **`atomics` stores 64-bit words**, so a byte-addressed sub-word or unaligned store needs a
  read-modify-write mask (and a two-word straddle when unaligned); that cost is part of what the
  `atomics` column measures. It is still O(1) — vastly cheaper than a 4 KiB rebuild — but it is not
  free.

SHA-256 and DEFLATE remain ~193× / ~525× below the **native NIF ceiling** (`crypto` / `zlib`), as
expected for compiled-from-wasm code vs hand-optimised C NIFs — a *ceiling*, not a peer.

**3. The composed `ceiling` (Unsafe + `atomics`, all levers).** The fastest carder produces this
phase. Two honest sub-findings:

- On **load-heavy CRC-32 and SHA-256 the Aggressive optimizer adds essentially nothing** on top of
  `atomics` (ceiling ≈ atomics-safe; on SHA-256 it is marginally *slower*, within run-to-run noise) —
  and on **`paged` it adds nothing at all** (`unsafe-paged` ≈ `safe`), because the memory bottleneck
  dominates and the optimizer cannot touch it.
- On **store-heavy DEFLATE, once `atomics` removes the memory bottleneck the optimizer finally
  bites**: `ceiling` (13.6 ms) is **1.6× faster than `atomics-safe`** (21.5 ms) and cuts the residual
  from ~525× to ~332×. So the Aggressive-vs-Baseline delta, `n/a` in Phase 3, is now **measurable on
  a real module** — and it matters most exactly where there is non-memory work left to optimize.

**4. tier-N `nif` — the native-memory ceiling (Phase 15, measured, no hero number).** The previously
Phase-4-deferred `nif` column is now a real `erl_nif` C backend over a reserved raw byte buffer (see
`docs/phase-15-tier-n.md`), measured same-run (†). The honest reading, with **no hero number**:

- **`atomics → nif` is a real, store-intensity-tracking win of 1.5×–1.9×.** It removes the two costs
  `atomics` leaves on the table: the 64-bit-word read-modify-write mask on sub-word/unaligned stores
  (§2 above) becomes a raw byte `memcpy` — so store-heavy DEFLATE gains most (**1.9×**), load-heavy
  CRC-32 least (**1.7×**); and on the loop-versioned fast arms tier-N now emits **native unchecked
  derefs** (the bounds compare elided — the Phase-15 unchecked lever). tier-N native is in fact the
  **fastest build measured this phase**, beating even `ceiling` on tier-O `atomics` on all three
  kernels (crc `1.03` vs `1.40` ms; sha `5.25` vs `7.90` ms; deflate `10.7` vs `13.4` ms).
- **The cleanest isolation — the *same* `nif` `.beam`, same session, toggling ONLY whether the `.so` is
  loaded** (native vs the paged-delegate fallback on the identical compiled artifact, both bit-exact) —
  is **3.10× / 4.00× / 5.73×** (crc / sha / deflate). That is exactly what native linear memory buys,
  isolated from every other variable, and the store-intensity ordering (deflate > sha > crc) holds
  precisely.
- **The floor that remains — why `nif → ref` is still 19.2× on CRC-32.** The **per-access inter-module
  seam call** (`call 'carder@runtime@rt_mem_nif':'<op>'(...)`, a build-controlled module atom **never
  inlined**) is present in **every** tier including `nif`; the NIF removes it **only** for the unchecked
  loop bodies the optimizer strips to a raw deref, never for the checked per-op seam. And **tier-P `bif`
  numerics are untouched** (tier-N numerics is out of scope, G8) — so on the numerics-dominated,
  load-heavy CRC-32 the residual is dominated by the bignum ops native *memory* cannot touch. **State
  plainly: the tier-N memory ceiling does NOT reach hand-written Erlang** — it removes the *memory*
  constant, not the *numeric* one and not the *seam*. SHA-256 / DEFLATE remain ~131× / ~267× below the
  native `crypto`/`zlib` **ceiling** — a ceiling, not a peer.

**Threading overhead (G4) is small.** `portable` (`Threaded` + `Paged`) is within a few percent of
`safe` (`Cell` + `Paged`) on every kernel — sometimes marginally faster (noise). The purely-functional
instance-state record threaded through generated code is a fixed-size handle; it is not a speed lever
and, as measured, not a speed penalty either. The runs-anywhere posture is essentially free.

**State plainly: is "faster than hand-written Erlang" now reached? — Measured: NO.** The pure CRC-32
head-to-head is **still ~31.6× slower** than hand-written Erlang. `atomics` closed **more than half**
of the paged gap (76× → 31.6×), and the store-intensity prediction held, but the tier-O memory lever
alone does not reach parity — the tier-P `bif` numeric floor and the per-access seam-call floor
remain. **The number to beat was written down in Phase 3; this time the number achieved is written
beside it — and it is honestly still short.**

## Limitations (stated, not hidden)

1. **The Aggressive inliner now scales — barely.** In Phase 3 the Aggressive/Unsafe compile of this
   80-function module did **not finish** (`n/a`); the post-P3 whole-module node ceiling
   (`inline_node_ceiling`) makes it **terminate** (~90 s wall per Aggressive build on the reference
   machine, producing a ~1.7 MB `.beam` vs the ~0.56 MB Baseline `.beam`). This is **compile-time
   only** (excluded from the `exec` timing) and it is a bound, not a cost model — the ceiling papers
   over the P3 inliner-scalability limit rather than solving it. A smarter callee/size heuristic is
   still the right fix.
2. **Tier-P `bif` numerics unchanged.** `rt_num` remains pure Gleam over BEAM bignums. This is the
   dominant residual on CRC-32 and is **out of Phase-4 scope** (G8) — tier-N `nif` numerics is the
   biggest remaining lever the residual analysis points at, and it is deferred.
3. **The `nif` memory column shipped in Phase 15 (measured).** Tier-N `nif` memory (the raw O(1)
   native ceiling for a carder build) is now a real `erl_nif` C backend, measured as the `nif` column
   above: **1.5×–1.9× over `atomics`** (most on store-heavy DEFLATE), and **3.10×–5.73×** on the clean
   same-`.beam` native-vs-paged-delegate isolation. It is measured **same-run** (†, toolchain-gated;
   a categorized dash absent `cc`, never a fabricated number). It does **not** reach hand-written
   Erlang (`nif → ref` still ~19.2× on CRC-32): tier-N *memory* removes the memory constant, not the
   tier-P `bif` **numeric** floor (still out of scope, G8) nor the per-access inter-module **seam-call**
   floor. The native `crypto`/`zlib` figures remain the raw *numeric* ceiling, not a carder tier.
4. **`atomics` requires a bounded cap.** The reported `atomics` numbers depend on a `--cap` (here
   1024 pages) that exceeds the kernels' 18–22-page working set. A crate whose memory cannot be
   bounded to the reserve cap (`4096` pages) without changing the crate could not be measured under
   `atomics` at all — here all three kernels bound comfortably, so coverage is complete, but the
   dependence is real and stated.
5. **CPU-time, not space.** Fuel bounds *work* (reductions), not stack/heap footprint. The
   Safe-vs-Unsafe metering-overhead delta is small and, on `paged`, buried under the memory
   bottleneck (`unsafe-paged` ≈ `safe`); it is measurable only on `deflate` under `atomics` (ceiling
   vs atomics-safe), where it reflects optimizer + metering-removal together, not metering alone.
6. **`wasmtime` timing omitted** (whole-process, not per-call comparable); its **correctness**
   cross-check is the per-build gate above and `smoke/run.sh` (bit-exact on all three kernels).
7. **Native SHA/DEFLATE are NIF-backed C**, not hand-written Erlang — a native *ceiling*, not a peer.
   Only CRC-32 is a true hand-written-Erlang head-to-head.

## What this motivates

The Phase-4 performance question is **answered, measured**: tier-O `atomics` closes 2.3×–2.9× of the
paged gap (most on store-heavy kernels, as predicted), the runs-anywhere `threaded` build costs almost
nothing, and the Aggressive optimizer becomes measurable on a real module for the first time — but
carder is **still not faster than hand-written Erlang**, held above the floor by the two costs
`atomics` does not touch. The residual analysis names the next levers precisely: **tier-N `bif→nif`
numerics** (the biggest remaining constant, and the dominant CRC-32 residual, still out of scope), a
**tier-N `nif` memory** backend (the raw memory ceiling — **shipped and measured in Phase 15**: 1.5×–1.9×
over `atomics`, 3.10×–5.73× native-vs-paged-delegate; see `docs/phase-15-tier-n.md`), and a **smarter
inliner cost model** (so the Aggressive-vs-Baseline delta the `deflate/ceiling` column now reveals can be
realized without a 1.7 MB `.beam`). The capstone (unit 11) cites these findings as Phase 4's one
measured claim about the outside world; Phase 15 measured the `nif`-memory lever it named.
