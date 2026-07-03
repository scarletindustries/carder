# Phase 7 — JS on the BEAM via Porffor: the measured coverage report

> The honest, measured record of Phase 7 — the phase that reaches the platform's stated goal: **a
> real JavaScript program runs on the BEAM, as compiled preemptive code.** Companion to the
> conformance image (`docs/wasm-conformance.svg`) and the capstone (`specs/phase-7/10-capstone.md`).
> Every number is **measured** by `gleam test` at the pin (Porffor 0.61.13, Node 22,
> `WebAssembly/testsuite @ 193e551`, wabt 1.0.41, wasmtime 46.0.1) — never promised (R16/S11).

---

## The headline (measured)

**JS on the BEAM.** A corpus of **55** real JavaScript programs, each compiled by **Porffor**
(JS → WASM) and then decoded / validated / lowered / emitted by **2core** to Core Erlang and loaded
onto the **BEAM**, runs and produces output **byte-identical to Porffor's own execution** (`porf
run`):

| JS-on-the-BEAM corpus (Porffor 0.61.13 → 2core → BEAM) | pass | fail | skip |
|---|---:|---:|---:|
| **55 programs, 11 categories** | **52** | **0** | **3** |

**`fail == 0`** — 2core reproduces the compiled WASM byte-for-byte on **every** program, including
the 3 that diverge. The **3 skips are all `PorfforVsNodeDivergence`** — measured *Porffor* bugs, not
2core gaps (see "Bounded by Porffor" below). This is the goal proof: **the JS Porffor can compile
runs on the BEAM as compiled, preemptive code**, with JS exceptions as BEAM exceptions.

### The pipeline

```
foo.js  ──porf wasm──▶  foo.wasm  ──2core fe_wasm──▶  IR  ──emit_core──▶  Core Erlang  ──▶  BEAM
                                    (decode/validate/lower/emit,          (compiled,
                                     incl. exception handling)             preemptive)
```

The value ABI is Porffor's `(f64, i32)` typed pair; the intrinsic imports (`print`/`printChar`/time)
are a build-fixed `rt_host` Porffor shim (literal `case`, no `apply/3` — D3a); the entry export is
`"m"`. `console.log` output is captured **in-band** (ANSI-colored, exactly as `porf run` emits it)
and compared byte-for-byte against the `porf run` oracle — a **fair, non-circular** differential (it
runs the *same* `.wasm` 2core consumes, so a divergence is a 2core bug, not a compiler difference).

---

## What runs (the 52, by category)

| Category | JS exercised | on the BEAM |
|---|---|---|
| **console / arithmetic** | `console.log`, number formatting, precedence, `Math.*` | ✓ (often EH-free — const-folded) |
| **control flow** | `if`/`else`/`for`/`while`/`switch`/ternary, a 1000-iteration hot loop | ✓ (preemptive) |
| **functions / closures** | declarations, arrows, defaults, callbacks, IIFE, first-class fns | ✓ |
| **recursion** | fib, factorial, mutual recursion | ✓ |
| **strings** | concat, `.length`, upper, template, `charCodeAt`, `split`, `indexOf` | ✓ |
| **arrays** | literals, index, `map`/`filter`/`reduce`/`join`/`push`/`sort` | ✓ |
| **objects** | literals, property access + mutation, `Object.keys` | ✓ |
| **booleans** | comparison + logical operators | ✓ |
| **try / catch** | caught value, rethrow, nested try, runtime `TypeError`, `finally`, **an uncaught top-level throw** | ✓ — **the EH keystone, through the JS surface** |

Every one runs byte-identically to `porf run`. The `try/catch` row is the load-bearing one: it is
**JS exceptions becoming BEAM exceptions**, the engine feature Phase 7 added (below).

**Proven by:** `test/twocore/js/js_conformance_test.gleam` (the baked Tier-A judge over all 55) +
`js_differential_test.gleam` (the live `beam == porf run` re-check over a representative sample) +
`test/twocore/porffor/e2e_test.gleam` (a real Porffor `try { throw new Error(…) } catch { console.log("caught") }`
runs → `"caught\n"`, byte-identical to `porf run`).

---

## The load-bearing engine feature: WASM exception handling → BEAM-native try/catch

Everything Porffor emits, 2core already ran after Phase 6 — with **one** exception: **WASM exception
handling** (Porffor throws pervasively — 58–64× in a trivially-typed program — and JS `try/catch`
becomes WASM `try`/`catch`). Phase 7 added it, and it maps *directly* onto the BEAM's native
exceptions:

| WASM EH | → BEAM |
|---|---|
| `(tag t)` | a build-controlled term `{wasm_exn, TagId, Payload}` (no ambient authority — D3a) |
| `throw t (vals…)` | `rt_exn:throw_exn` → `erlang:error({wasm_exn, …})` (bottom; never returns) |
| `try_table` / legacy `try`-`catch` | a native Core Erlang `try … catch` matching the tag + binding the payload |
| *no matching clause* | `erlang:raise` — re-raise, preserving class + stacktrace (spec §4.4.9) |
| `catch_all` | catches WASM exceptions but **not** traps — a `MemoryOutOfBounds`/`FuelExhausted` propagates through |
| `throw_ref` / `rethrow` | re-raise the captured `exnref` (an opaque `{ref_exn, _}` box) |

Constant-space loops + scheduler preemption survive a throw (native BEAM unwinding); fuel/metering
still bites across it. The `rt_exn` runtime is **native-free** (BEAM tuples + `raise`, no NIF), so the
EH surface is **runs-anywhere-compatible**.

### The official EH `.wast` suite (measured, both encodings)

The capstone drives the official WebAssembly exception-handling `.wast` suite. **Measured at the pin**
(`wast2json --enable-exceptions`): **4 of the 8** official EH files convert; the 4 that do not are
blocked by features 2core defers (**not** an EH gap), each categorized:

| official EH `.wast` | encoding | at the pin | result |
|---|---|---|---|
| `throw.wast` | modern (`try_table`/`throw`) | ✅ converts | **green** |
| `throw_ref.wast` | modern (`catch_ref`/`throw_ref`/`exnref`) | ✅ converts | **green** |
| `legacy/throw.wast` | **legacy** (`try`/`catch` — Porffor's) | ✅ converts | **green** |
| `legacy/rethrow.wast` | legacy (`rethrow`) | ✅ converts | **green** |
| `tag.wast` | modern | ❌ | GC recursive types `(rec …)` — Phase 8 |
| `try_table.wast` | modern | ❌ | tail-call `return_call` + typed-ref/`exn` heap type — Phase 8 |
| `legacy/try_catch.wast` | legacy | ❌ | tail-call `return_call` — Phase 8 |
| `legacy/try_delegate.wast` | legacy | ❌ | tail-call `return_call` — Phase 8 |

The 4 convertible files run **green under all three shipped profiles** (safe / unsafe / portable):

| EH-engine conformance | pass | skip | fail |
|---|---:|---:|---:|
| `throw` + `throw_ref` + `legacy_throw` + `legacy_rethrow` × safe/unsafe/portable | **153** | 0 | **0** |

They exercise **both** encodings 2core decodes into the one neutral IR: the modern `try_table` /
`throw_ref` / `exnref` surface **and** the legacy `try` / `catch` / `rethrow` form Porffor actually
emits. **Proven by:** `test/twocore/conformance/eh_conformance_test.gleam`.

> **A bug the capstone found and fixed.** Lighting up the modern `throw.wast` / `throw_ref.wast`
> surfaced a real **optimizer soundness bug**: the Baseline `block-label-simplify` pass's `breaks_to`
> scan did not descend into `Try` catch handlers, so it eliminated a block that *was* broken to — but
> only from inside a catch handler (the modern `try_table`→enclosing-label transfer) — leaving a
> dangling `Break` → `emit: UnboundLabel`. Fixed by making `breaks_to`/`continues_to` descend into
> `Try` bodies + handlers (mirroring `lower`'s `expr_breaks_to`). Regression-guarded by
> `test/twocore/optimize/baseline_test.gleam` (fixture-independent) — it fails without the fix.

### The deliberately-authored EH backstop

Five scalar-observable kernels exercise one EH behaviour each on a **named** program, driven across
the mode axis (safe/unsafe/portable) and the full tier matrix (`combos.shipped`), differential vs
`wasmtime 46.0.1`:

- `ehthrow` — the **legacy** `try`/`catch` Porffor emits;
- `ehcatch` — the modern `try_table` catch→enclosing-label transfer (the exact IR shape of the fixed
  optimizer bug — a fixture-independent regression guard);
- `ehcatchall` — `catch_all` + a non-matching catch's no-match propagation (spec §4.4.9);
- `ehnested` — nested unwinding to the innermost *matching* handler;
- `ehrethrow` — `exnref` capture + `throw_ref` re-raise.

**Proven by:** `new_surface_test.gleam` (mode axis) + `tier_matrix_eh_test.gleam` (tier axis) +
`runs_anywhere_test.gleam` (portable, zero native, `rt_exn` non-vacuous, executed byte-identical).

---

## Conformance-neutral by default (the Phase-1..6 suite is byte-identical)

The IR grew (`Module.tags` + `Throw`/`Try`/`ThrowRef` + `exnref`), but a module with **no tags**
compiles byte-identically to Phase 6. The whole Phase-1..6 WebAssembly spec suite is **unchanged**:

| | pass | skip | fail |
|---|---:|---:|---:|
| **Phase-6 close** | 46,529 | 1,768 | 0 |
| **Phase-7 close** (main suite) | **46,529** | **1,768** | **0** |

The EH `.wast` run is a **separate** track (a subdirectory the main glob does not see), so the
headline number does not move — EH added an engine feature and a JS goal, not a change to the
existing surface. **Proven by:** `conformance_test.gleam` (unchanged) + `new_surface_test.gleam`'s
corpus-neutrality test.

---

## The honest scope (measured, not overstated)

1. **Bounded by Porffor's JS coverage — measured, never "full JS."** Porffor is an experimental
   research compiler supporting on the order of **⅓ of ECMA-262**. What reaches the BEAM is *the JS
   Porffor can compile*; the harness **measures** what runs and we claim exactly that. The 3 skips
   are measured **Porffor** bugs (not 2core): `arith/negzero` (Porffor renders `-0` as `"0"`, Node
   `"-0"`); `closures/counter` and `closures/adder` (Porffor 0.61.13's lexical closures that capture
   an enclosing variable are **broken** — measured across 6 variants: any capture throws/NaNs, while
   IIFE / global-counter / arrow-returning-a-constant work). 2core reproduces `porf run` byte-for-byte
   even on these, so they bound Porffor, not 2core — a **categorized** skip, never a false green.

2. **EH is BEAM-native and faithful — not emulated.** The BEAM's `try`/`catch`/`raise` *is* the
   target: no interpreter, no reified stack, native constant-space unwinding, preemption + fuel
   preserved across a throw. Both the modern `try_table` form (the official suite) and the **legacy**
   form Porffor 0.61.13 actually emits decode into the one neutral IR + BEAM mapping. **Tier reach
   (measured):** the state-free EH surface runs byte-identically under Cell **and** Threaded
   (`portable`) — 153/0/0 across safe/unsafe/portable. The T6 **Cell-only** bound is retained for
   exactly one combination it names: a program that mutates *threaded* instance state and relies on
   it *surviving* a throw/catch (under `threaded` the state travels as a data-threaded value a throw
   unwinds past). The official `.wast` suite and the JS/Porffor path (which is Cell) do not exercise
   it. The modern `exnref`/`throw_ref`/`catch_ref` surface is **Porffor-inert** — spec-conformance
   only (Porffor never emits it), bounded by which EH `.wast` are `wast2json`-able at the pin.

3. **No WASI, no browser DOM.** The host shim is **Porffor's runtime ABI** (its console/time
   intrinsics), a build-fixed `rt_host` registry — not WASI and not a DOM. Programs that need host
   APIs Porffor stubs/omits are a categorized gap; an unprovided intrinsic **fails closed**.

---

## One line per proof → the test that proves it

| Proof | Test |
|---|---|
| JS on the BEAM (the headline, measured 52/0/3) | `test/twocore/js/js_conformance_test.gleam`, `js_differential_test.gleam` |
| JS exceptions → BEAM exceptions (real Porffor try/catch → `"caught\n"`) | `test/twocore/porffor/e2e_test.gleam` |
| EH engine spec-correct (official `.wast`, both encodings, 153/0/0) | `test/twocore/conformance/eh_conformance_test.gleam` |
| EH backstop (5 authored kernels, mode axis) | `test/twocore/conformance/new_surface_test.gleam` |
| EH green under the tier matrix (byte-identical across `combos.shipped`) | `test/twocore/conformance/tier_matrix_eh_test.gleam` |
| EH runs-anywhere (portable, 0 native, `rt_exn` non-vacuous, executed) | `test/twocore/conformance/runs_anywhere_test.gleam` |
| Optimizer block-elimination regression (the fixed bug) | `test/twocore/optimize/baseline_test.gleam` |
| Conformance-neutral (46,529/1,768/0 unchanged) | `test/twocore/conformance/conformance_test.gleam` |

---

## Phase 8+ — the next frontier (the goal is reached; this is what's next)

With JS on the BEAM proven, the deferred work becomes the *next phase*, not a gap in this one:

- **A native JS frontend** — Porffor *is* the JS frontend today; a native ECMA-262 frontend (broader
  than Porffor's ⅓, tracking a spec version) is the largest Phase-8 candidate, and it reuses the
  **generic structured-exception IR** this phase built (`Throw`/`Try`/`ThrowRef` are not WASM-isms — a
  native JS `throw`/`try`/`finally` lowers straight onto them).
- **A broader-than-Porffor JS surface** (needs the native frontend); **GC-proposal reftypes**
  (`struct`/`array`/`i31`/typed refs — Porffor doesn't need them, confirmed); the **tail-call
  proposal** (`return_call*` — maps cleanly onto BEAM native tail calls, a plausible fast-follow, and
  the thing blocking 4 of the official EH files); the **Erlang/Gleam frontend**; **stack-switching /
  the component model**; the single-`.beam` binding; **tier-N** numerics/SIMD + a production C NIF;
  the **memory optimizer** (its own performance phase). **WASI** stays an `rt_host` implementation,
  out of core; the **browser DOM** is out of scope entirely.

**Phase 7 reaches the goal the platform was always for: any Porffor application becomes a
well-behaved, compiled, preemptive BEAM citizen. The next move is a native JS frontend — broader JS,
on the same engine.**
