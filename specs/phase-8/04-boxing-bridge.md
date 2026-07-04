# Phase 8 · Unit 04 — The term↔numeric boxing bridge

> Read [`00-overview.md`](00-overview.md) (K5) + unit 01. Implements the **only** crossing between the
> unboxed numeric layer (`TI32`/`TI64`/`TF32`/`TF64`) and the term layer (`TTerm`). The `ConvOp`
> variants already exist (`ir.gleam` `BoxInt`/`UnboxInt`/`BoxFloat`/`UnboxFloat`); today `emit_core`
> returns `Error("box_int")` etc. (lines ~5378-5381). Ship the lowering, **bit-exact** (D5). Files:
> `emit_core.gleam` (+ maybe `runtime/rt_num.gleam`), tests.

## Why it matters

The frontend keeps hot arithmetic **unboxed** (`f64` add is a native BEAM float op) and boxes only at
boundaries (storing into an object, returning a `TTerm`, calling `rt_js`). Without this bridge, every
number is a term and every op is an `rt_js` round-trip — negating the reason to compile. This is the
single most performance-load-bearing unit.

## The D5 subtlety — DO THIS FIRST

2core represents floats as **raw bit patterns** (D5), not BEAM floats. **Before writing anything,
determine how a `TF64`/`TF32` value is actually carried in the emitted Core Erlang** (read
`emit_value` for `ConstF64`, and `rt_num.gleam` — the float ops). Two possibilities, and the lowering
differs:
- If a `TF64` is carried as a **BEAM float** already → `BoxFloat`/`UnboxFloat` are (near-)identity at
  the value level, just a static-type retag.
- If a `TF64` is carried as a **raw `i64` bit pattern** → `BoxFloat` must reinterpret bits→float and
  `UnboxFloat` float→bits (`erlang:'-'`? no — use the bitstring reinterpret `<<B:64/integer>> =
  <<F:64/float>>`, i.e. the same reinterpret `ReinterpretIToF`/`ReinterpretFToI` already emit — reuse
  that machinery). **Get this from the code, not from assumption.**

## Semantics & lowering

| ConvOp | arg type | result | meaning |
|---|---|---|---|
| `BoxFloat(FW64)` | `TF64` | `TTerm` | the JS/BEAM float term for that f64 (a BEAM `float()`) |
| `UnboxFloat(FW64)` | `TTerm` | `TF64` | the raw f64 of a float term (frontend guarantees it *is* a float — see unit 06 guards) |
| `BoxFloat(FW32)` / `UnboxFloat(FW32)` | `TF32` ↔ `TTerm` | as above, 32-bit |
| `BoxInt(W32)` | `TI32` | `TTerm` | the BEAM integer for the i32 (frontend picks signed vs unsigned via width, consistent with existing conventions) |
| `UnboxInt(W32)` | `TTerm` | `TI32` | the i32 of an integer term |
| `BoxInt(W64)` / `UnboxInt(W64)` | `TI64` ↔ `TTerm` | as above, 64-bit |

`BoxFloat`/`BoxInt` are **`Pure`** (a value reinterpret, no effect, no trap). `UnboxFloat`/`UnboxInt`
are **`Pure`** too *given the frontend's type guarantee* (they assume the term is the right shape;
mis-typed unbox is a frontend bug, not a trap — mirror how the existing non-trapping `Convert`s
classify). If unsure, classify effectful — correctness first.

## Tests (spec-first — round-trip is the acceptance)

- `UnboxFloat(BoxFloat(x))` == `x` for `0.0`, `1.5`, `-2.25`, a large/denormal, `NaN`- and `Inf`-bit
  patterns **bit-exactly** (assert the f64 bits round-trip — D5 is the whole point).
- `UnboxInt(BoxInt(n))` == `n` for `0`, `1`, `-1`, `2^31-1`, `-2^31`, and (W64) `2^53`, a bignum-range
  value (BEAM integers are arbitrary precision — verify no truncation).
- A composed flow: two unboxed `f64`s → `Num(f64.add)` → `BoxFloat` → a `TTerm`, then `UnboxFloat` →
  `f64`, asserting the sum. This is the frontend's hot-arithmetic pattern end-to-end.
- Conformance-neutral: WASM byte-identical.

## Definition of Done

Suite green (≥1694, 0 failures), format/build clean, WASM byte-identical. Commit
`phase-8/04: term↔numeric boxing bridge` and push.
