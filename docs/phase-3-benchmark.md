# Phase-3 benchmark — carder on the BEAM vs hand-written Erlang & the native ceiling

> **The one claim Phase 3 makes about the outside world — "the fastest possible code, potentially
> faster than hand-written Erlang" — is *measured here, not asserted*.** This is a committed
> artifact with real numbers, methodology, and stated limitations. There is **no hero number**.
> Reproduce with `./smoke/bench.sh [REPEAT] [UNSAFE_TIMEOUT_SECS]` — **run from the scribbler repo**:
> the harness is a wasm differential (it cargo-builds the Rust crate to wasm, gates it
> import-free/MVP-only with `wasm-tools`, and cross-checks against `wasmtime`), so it moved with the
> WebAssembly frontend and now drives scribbler's `build` verb (it was `to-beam-wasm` when these
> numbers were taken) plus carder's `exec -n` for the timing. **Reproduction is cross-repo now** — the
> measurements below are carder's record, the harness that produced them is scribbler's.

## What is measured

Three real, external, permissively-licensed crates, compiled to a single **no-import, MVP-only**
`carder_smoke.wasm` (72,933 bytes, 80 functions, 0 imports — the same artifact `smoke/run.sh`
already differential-checks **bit-exact vs `wasmtime`**), exposed as `i32`-in / `i32`-out exports:

| Kernel | Crate | Exercises |
|---|---|---|
| `crc32(n)` | `crc32fast` | table-driven CRC-32, memory loads |
| `sha256_word(n)` | `sha2` | 64-round compression, rotations, message schedule |
| `deflate_roundtrip(n)` | `miniz_oxide` + `dlmalloc` | real DEFLATE compress+decompress+verify, `memory.grow`, heavy memory traffic |

Each export recomputes its `n`-byte input (a deterministic LCG) on every call, so a contender that
recomputes the same input per call does the same total work.

## Contenders

1. **carder-Unsafe** — compiled under `profiles.unsafe()` (Aggressive optimizer, `MeterOff`,
   passthrough stdlib, open BIF/host), `.beam` timed with `gleam run -- exec -n N` (times **only**
   the invocations — the ABI already exists).
2. **carder-Safe** — compiled under `profiles.safe()` (Baseline optimizer, enforcing fuel,
   allowlist, own stdlib), same `exec -n N` timing.
3. **hand-written Erlang** — a **pure-Erlang, table-driven CRC-32** (the honest hand-written
   baseline; recomputes the *same* input, so its result is **bit-identical** to the wasm export).
   For SHA-256 and DEFLATE this column instead reports the **native NIF ceiling** — `crypto:hash/2`
   and `zlib` — which are **NIF-backed C, NOT hand-written Erlang**; carder is expected to sit below
   them, and does. Clearly labelled as such.
4. **`wasmtime`** — bit-exact **correctness** is already cross-checked by `smoke/run.sh`. A
   per-call *timing* comparison is deliberately **omitted**: `wasmtime run --invoke` measures a
   whole process (VM startup + JIT + one invoke), which is not comparable to `exec`'s
   pure-invocation timing, so a number here would mislead rather than inform.

## Methodology

- **Machine:** Apple M2 Pro, 12 cores, macOS (Darwin 25.3.0, arm64).
- **Toolchain:** Erlang/OTP **29** (erts 17.0.2), Gleam **1.17.0**, rustc **1.84.0**
  (`wasm32v1-none`), wabt **1.0.41**, wasmtime **46.0.1**.
- **Conformance pin:** WebAssembly/testsuite `193e551f`, wabt 1.0.41, wasmtime 46.0.1.
- **What is timed:** the invocations *only*. `exec` loads + instantiates the prebuilt `.beam`
  **once**, then invokes the export `N` times in the instance's owned process and times the loop —
  so **compile, load, and instantiate are excluded**. The Erlang baselines warm up once, then time
  `N` repeats with `timer:tc`.
- **Inputs:** `crc32(4096)`, `sha256_word(4096)`, `deflate_roundtrip(2000)`. Contenders 1/2 and the
  hand-written CRC run **byte-identical work**; the native SHA/zlib ceilings are a *different
  implementation over equivalent-size input* (a labelled caveat — zlib's compressed stream differs
  from miniz_oxide's, so only the *work size* matches).
- **Repeats:** `REPEAT` for crc/sha (default 100), `REPEAT/5` (min 5) for deflate (which is ~60 ms
  a call). Numbers below are from `REPEAT=100`; they are stable to a few percent across runs.

## Results (ns per call, this machine)

| kernel | carder-Unsafe | carder-Safe | hand-Erl / native | notes |
|---|---:|---:|---:|---|
| `crc32(4096)` | n/a¹ | 4,006,910 | **52,800** (hand-written Erlang) | Erlang ~**76× faster**; results **bit-identical** (`2538352202`) |
| `sha256_word(4096)` | n/a¹ | 19,781,600 | 41,620 (native `crypto`) | native NIF ceiling ~**475×** faster |
| `deflate_roundtrip(2000)` | n/a¹ | 62,098,600 | 38,650 (native `zlib`) | native NIF ceiling ~**1600×** faster |

¹ **carder-Unsafe = n/a on these crates** — see limitation (1). The Aggressive optimizer's inliner
does not finish compiling this 80-function module in practical time.

`crc32(4096)`: carder = `2538352202` = hand-written-Erlang `2538352202` = wasmtime (`run.sh`). A
clean, bit-identical head-to-head.

## The honest reading

- **"Faster than hand-written Erlang?" — measured: NO, on the current tier-O runtime.** For the one
  faithful head-to-head (CRC-32, bit-identical), pure hand-written Erlang is ~**76×** faster than
  carder-Safe. Against the native-NIF ceiling (SHA-256, DEFLATE) carder is two-to-three orders of
  magnitude slower — as expected for compiled-from-wasm code vs hand-optimized C NIFs. **The high-
  level aspiration is therefore *not yet* met by Phase 3, and this benchmark says so plainly.**
- **Why:** the dominant cost is the **tier-O memory model** — `rt_mem`'s paged *immutable-binary*
  linear memory rebuilds a chunk on every store, so memory-heavy kernels (all three here) pay a
  large per-access constant; and `rt_num` is pure-Gleam over BEAM bignums, not native. Both are
  Phase-2 tier-O choices Phase 3 does not change (it is the *policy/optimizer* axis, not the
  *trust-tier* axis — F8).
- **Where the speed in Phase 3 comes from:** the **optimizer alone** (Baseline vs Aggressive
  passes). The passthrough/open-BIF path ships as a **mechanism with zero active routes** (every
  shared stdlib function stays in-house under *both* profiles), so it contributes **no** speedup
  here — as designed (F8). Correctness under the optimizer is proven byte-for-byte by the capstone
  differentials (`test/carder/optimize/differential_test.gleam`): `OptNone` ≡ `Baseline` ≡
  `Aggressive`, and `Safe` ≡ `Unsafe`, on the whole acceptance corpus.

## Limitations (stated, not hidden)

1. **The Aggressive inliner does not scale to large real modules.** Compiling the 80-function smoke
   wasm under `profiles.unsafe()` does not finish within minutes (code explosion — the inliner's
   size budget is recomputed per fixpoint round, so inlining feeds itself on a deep call graph). On
   the *small* acceptance corpus it compiles instantly and is behaviorally identical to Safe (the
   capstone's proof-1/proof-2 differentials), so this is a **compile-time scalability** limit on the
   Aggressive pass, **not** a correctness or run-time problem — and it is **compile-only** (the
   `exec` timing excludes compile). It motivates a smarter inliner cost model (a real callee/size
   heuristic and a global expansion cap), consistent with F8's deliberately-bounded optimizer scope.
2. **Tier-O runtime.** Phase 3 runs on Phase-2's `cell` state + `paged` immutable-binary memory. The
   trust-tier ladder — a NIF-backed / atomics `rt_mem`, threaded "no-OTP" state — is **Phase 4**,
   and is exactly what would close the gap this report measures against the native ceiling.
3. **CPU-time, not space.** Fuel bounds *work* (reductions), not stack/heap footprint (measured
   separately by the max-pages cap). The Safe column carries the fuel instrumentation; the
   Safe-vs-Unsafe delta on an identical kernel (the instrumentation cost) is **not** measurable here
   because the Unsafe build did not compile (limitation 1).
4. **`wasmtime` timing omitted** (whole-process, not per-call comparable); its **correctness**
   cross-check is in `smoke/run.sh` (bit-exact on all three kernels).
5. **Native SHA/DEFLATE are NIF-backed C**, not hand-written Erlang — a native *ceiling*, not a
   peer. Only CRC-32 is a true hand-written-Erlang head-to-head.

## What this motivates

The findings are the Phase-4 case: a NIF-backed / atomics `rt_mem` and threaded state would attack
the tier-O memory constant that dominates every kernel here, and a scalable inliner would let the
Aggressive-vs-Baseline optimizer delta be measured on real modules. Phase 3's claim was that the
generated code is **correct** under both profiles and the optimizer changes **nothing observable**
— which the capstone proves — and that the "faster than hand-written Erlang" question is a
**measured** one. Measured, on tier-O: not yet. The number to beat is written down.
