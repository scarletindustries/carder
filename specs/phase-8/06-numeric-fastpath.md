# Phase 8 · Unit 06 — Term classification (guarded fast paths)

> Read [`00-overview.md`](00-overview.md) (K2) + units 01/04. Ships the **term type-tests** that let the
> frontend write monomorphic *guarded* fast paths — the enabler for real speed. Files: `ir.gleam`,
> `emit_core.gleam`, `effect.gleam`, `printer.gleam`, `parser.gleam`, tests.

## Why (the speed story)

A JS `a + b` becomes: *if both are numbers → unbox → native `f64.add` → box (the fast path, units
04+`Num`); else → `CallHost("js","add",…)` (the slow path)*. The **guard** — "is this term a number?"
— needs a cheap `TTerm → i32` type test. Likewise property-access ICs guard on shape. These are
general BEAM `erlang:is_*` tests; provide them as first-class IR nodes so guards compile to native
type checks, not `rt_js` round-trips.

## IR delta

One new `Expr` variant:
`TermTest(kind: TermKind, arg: Value)` → **`TI32`** (0/1), so it drops straight into `If`/`Switch`.

```
pub type TermKind {
  IsInt  IsFloat  IsNumber  IsAtom  IsBinary  IsTuple  IsMap  IsFun  IsList
}
```

| kind | Core Erlang | note |
|---|---|---|
| `IsInt` | `erlang:is_integer(X)` | JS smi / bitwise |
| `IsFloat` | `erlang:is_float(X)` | JS non-integer number |
| `IsNumber` | `erlang:is_number(X)` | the `a+b` guard |
| `IsAtom` | `erlang:is_atom(X)` | booleans / sentinels |
| `IsBinary` | `erlang:is_binary(X)` | JS string |
| `IsTuple` | `erlang:is_tuple(X)` | shaped object / internal record |
| `IsMap` | `erlang:is_map(X)` | JS object (dictionary) |
| `IsFun` | `erlang:is_function(X)` | JS callable |
| `IsList` | `erlang:is_list(X)` | cons/args |

Each lowers to `case 'erlang':'is_*'(X) of 'true' -> 1; 'false' -> 0 end` (an i32 truth value). Also add
a convenience `TermTag(arg) → TI32` returning a small dense classification code (one `case`/`if` over
the `is_*` tests) so a frontend can `Switch` on term type in one node instead of a chain of `If`s — pick
a fixed encoding and **document it in the handoff** (e.g. `0=int 1=float 2=atom 3=binary 4=tuple 5=map
6=fun 7=list 8=other`).

## Effect

`TermTest` and `TermTag` are **`Pure`** non-barriers (pure inspection, no trap, no state).

## Composed fast-path proof (the acceptance)

Author the frontend's `a+b` fast path *in IR* end-to-end and test it:
```
If( TermTest(IsNumber, a)  &&  TermTest(IsNumber, b),
    result := Box(Num(f64.add, [Unbox a, Unbox b])),          // fast
    result := CallHost("js","add",[a,b]) )                    // slow (stub from unit 05)
```
Assert `1.5 + 2.5` via the fast path → `4.0` (boxed), and that a non-number argument takes the slow
path and still returns the stub's result. This demonstrates the whole point of Phase 8: **hot
arithmetic compiled to native BEAM, dynamic only on the cold path.**

## Tests (spec-first)

- Each `TermTest(kind, …)` returns `1` for a matching term and `0` otherwise (int vs float vs atom vs
  binary vs tuple vs map vs fun vs list — cover the matrix).
- `TermTag` returns the documented code per type.
- The composed `a+b` fast/slow proof above.
- Conformance-neutral: WASM byte-identical.

## Definition of Done

Suite green (≥1694, 0 failures), format/build clean, WASM byte-identical. Commit
`phase-8/06: term classification (guarded fast paths)` and push.
