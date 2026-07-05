# `--bindings` — typed host-language bindings (Gleam / Erlang / Elixir)

> Phase 12 reference. `--bindings` is an optional flag on `to-beam-wasm` that, alongside the compiled
> `.beam`, emits **companion typed host-language source files** — a `.gleam`, an `.erl`, and/or an
> `.ex` — giving an ergonomic, native-typed API to instantiate the module and call its exports. The
> `.beam` itself is **unchanged**; the bindings are companions. The default (no-`--bindings`) output
> is byte-identical.

## 1. What it is (and is not)

The raw run-ABI ([`../specs/01-status.md`](../specs/01-status.md) §5) is correct but hostile:
arguments and results are **raw unsigned bit patterns as Erlang integers** — an i32 `-1` arrives as
`4294967295`, an f64 arrives as its raw IEEE-754 bits-in-an-integer, a multi-value result is a bare
tuple, and a trap is an uncaught BEAM exception. Phase 12 wraps that ABI in **native types with
conversion glue**: `Int`/`Float`/`BitArray`, traps as a `Result`/tagged tuple, one typed function per
export — the "beautiful `.gleam` file with the exports typed for me."

```
to-beam-wasm --threaded --bindings gleam --out ./out math.wasm
# → ./out/twocore@wasm@<base>.beam                     (the compiled module, unchanged)
#   ./out/twocore_wasm_<base>_bindings.gleam           (the typed API)
#   ./out/twocore_wasm_<base>_bindings_ffi.erl         (the trap catch-shim, Gleam only)
#   ./out/twocore_wasm_<base>_bindings_README.md       (usage note, Gleam only)
```

`--bindings <langs>` takes a comma list of `gleam`/`erlang`/`elixir`; `--out <dir>` is the output
folder. **`--bindings` requires a threaded build** (`--threaded`) — the default `Cell` binding has no
typed-binding surface this phase and yields a typed CLI error hinting to add `--threaded`. Output is
**deterministic** (stable export ordering, no timestamps/paths), so identical input ⇒ byte-identical
files.

It is **export-only** (import-bearing modules are link-rejected, as `--link` is), presents references
as **opaque handles** (no cross-language funcref construction), and does not touch the default
emission, the IR, the optimizer, or any runtime semantics — bindings are a pure developer-experience
addition that **composes with Phase-11 `--link`** (a self-contained `.beam` + typed bindings = a
portable, type-safe drop-in).

## 2. The value ABI (native ⇄ raw bit patterns)

The binding presents native host types and hides the raw-bit-pattern convention behind conversion
glue. The frozen mapping:

| WASM type | Gleam | Erlang `-spec` | Elixir `@spec` | Boundary conversion |
|---|---|---|---|---|
| i32 / i64 | `Int` | `integer()` | `integer()` | **signed** two's-complement ⇄ raw unsigned bit pattern (host ints are bignums — i64 round-trips exactly, no width loss) |
| f32 / f64 | `FloatVal` | `floatval()` | `floatval()` | native float ⇄ raw IEEE bits (`<<F:32/float>>`/`<<F:64/float>>`; f32 single-rounded) |
| v128 | `BitArray` | `binary()` (16 B) | `binary()` | identity (16 raw little-endian bytes) |
| funcref / externref | opaque `Ref` | `term()` | `term()` | opaque passthrough (the `rt_ref` box) |
| multi-value results | tuple | tuple | tuple | positional, in declaration order |
| 0 results | `Nil` | the atom `ok` | the atom `:ok` | the unit package |
| a trap | `Result(_, Trap)` | `{ok,_} | {error,trap()}` | `{:ok,_} | {:error,trap()}` | the trap is caught at the boundary |

Integers are presented **signed** (what a host programmer expects from "i32"); the module is
sign-agnostic on the bits.

### Non-finite floats (NaN / ±Inf) — the sum type

A BEAM `float()` **cannot represent NaN or ±Inf** (`<<F:64/float>>` raises on them), so f32/f64 are
NOT bare `Float`s. They are a small **sum type** — Gleam `FloatVal = Finite(Float) | NonFinite(BitArray)`,
Erlang/Elixir a `{finite, float()} | {nonfinite, binary()}` tagged tuple. Finite values present as a
native float (the beautiful default); a non-finite value carries its raw IEEE bytes so it is never
lost or crashed. Bidirectional raw-bits accessors round-trip bit-exact values:

- Gleam: `f32_of_bits`/`f64_of_bits` (build from raw bytes) and `f32_bits`/`f64_bits` (read raw bytes).
- Erlang/Elixir: the same conversions are the `enc_f*`/`dec_f*` (`f*_bits`/`f*_of_bits`) helpers.

The raw-bits ⇄ float conversion is guarded on the all-ones exponent and lives **outside** the
trap-catch, so a valid non-finite result is never mistaken for a trap and a conversion bug is never a
swallowed fake trap.

## 3. The two-shape host API

The `.beam` ABI is uniformly `n+1` under a threaded build (every export takes a leading
`InstanceState` and returns `{ResultPackage, St'}`, whether or not it touches state), so the binding
always threads state INTERNALLY. Whether the module reads/mutates instance state governs only the
HOST surface:

- **Stateless** (no export reaches instance state) — "the beautiful pure file": there is **no
  `Instance` and no `instantiate`** in the surface. Each export is `fn(args) -> Result(T, Trap)` and
  obtains a fresh state internally per call.
- **Threaded** (≥1 export reaches instance state): `instantiate() -> Result(Instance, Trap)`; every
  export takes `inst`; a state-reaching export returns `Result(#(T, Instance), Trap)` (thread the new
  instance back), the rest return `Result(T, Trap)`.

The `Instance` is threaded as a **pure value** (no process is spawned), so an old `Instance` observes
none of a later call's writes — result-equality, not shared mutable state.

## 4. Per-language idioms

- **Gleam (the headline)** — a **two-file drop**: `<base>_bindings.gleam` (the typed `pub fn`s + doc
  comments, prelude-only so it needs no `gleam_stdlib` dependency) **and** `<base>_bindings_ffi.erl`
  (a tiny catch-shim). Gleam cannot rescue a BEAM exception in-language, so each call routes the
  `.beam` export through the shim's `try/catch`, which matches `error:{wasm_trap, _}` **structurally**
  (never a bare catch-all). Both files go under the consuming project's `src/` (Gleam discovers `.erl`
  FFI tree-wide under `src/`), and a README explains the drop + the value-ABI cheat-sheet. The binding
  module is named `twocore_wasm_<base>_bindings` (legalized from the module atom), so it never
  collides with the loaded `.beam` module atom.
- **Erlang** — a **single `.erl`** with `-spec`/`-doc` on every function. Erlang catches the BEAM
  exception in-language (`try … catch error:{wasm_trap, _} -> {error, Trap}`), so there is **no
  companion shim**.
- **Elixir (best-effort)** — a **single `.ex`** with `@spec`/`@doc`. It catches the trap **Erlang-style**
  (`try … catch :error, {:wasm_trap, _}`) — NOT `rescue` — so the loaded binding runs with **zero
  `Elixir.*` runtime dependencies** (only `:erlang`/bit-syntax/guards) on a bare BEAM node. The Elixir
  module compiles to the distinct atom `Elixir.<Camelized>Bindings`. Elixir is gated on `elixirc`
  being installed; the compile+call proof is a categorized skip (never a false green) when it is
  absent.

## 5. The trap surface (and what is out of scope)

A WASM **trap** (integer divide-by-zero, an out-of-bounds memory/table access, `unreachable`, fuel
exhaustion, a capability denial) is caught at the boundary and surfaced as the language's error idiom:
Gleam `Error(Trap(reason))`, Erlang `{error, {wasm_trap, Kind}}`, Elixir `{:error, {:wasm_trap, kind}}`.
A trap **never** leaks the raw `{wasm_trap, _}` term as an uncaught exception. The catch is structural
on `{wasm_trap, _}`, so an emitter bug (a wrong arity ⇒ `undef`) crashes loudly instead of
masquerading as a fake trap.

**Out of scope this phase (R24):** a WASM `throw` (`exnref` / the exception-handling proposal) is a
**distinct term class** the `{wasm_trap, _}` catch does NOT intercept, so a throwing export escapes
the typed-error surface — it is documented, not modelled. The trap surface is genuine traps only.

## 6. Runtime dependency — the un-linked binding is NOT self-contained

**The compiled `.beam` the binding dispatches into is a thin module** of module-qualified calls into
the shared runtime (`twocore@runtime@*` + `gleam@*`). So an un-linked binding's call chain
transitively needs those ebins on the code path — the binding is **not portable on its own**. For a
**droppable, self-contained** artifact, compile the module with **Phase-11 `--link`** (which merges
the runtime closure into the one `.beam`); the typed binding then dispatches into that self-contained
module. Do not treat the un-linked `.beam` + binding as portable.

## 7. Correctness — compile + call, not golden strings

Each binding's correctness is proved by a **compile+call differential**, not golden change-detectors:
the emitter generates the binding, the **real toolchain** compiles it (`gleam build` / `erlc` /
`elixirc`), an export is called through the compiled native surface, and the native result — decoded
back to raw bits — is asserted **identical** to the in-process pipeline oracle across the full type
matrix (i32/i64 signed, f32/f64 finite and non-finite, v128, funcref/externref, multi-value, zero
result), plus a genuine trap → the language's error idiom, plus threaded-state accumulation with an
immutable old instance. Floats are compared by **raw IEEE bits**, so a sign/rounding/NaN divergence
would be caught. The proof lives in `test/twocore/backend/bindings_compile_call_test.gleam`.
