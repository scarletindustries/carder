# Phase 8 · Unit 01 — Term construction & destructuring

> Read [`00-overview.md`](00-overview.md) first (K1, K2, K8). This unit turns the IR's stubbed term
> layer into a working BEAM-term construction/destructuring surface — the foundation every other
> Phase-8 unit builds on. **Owner: one implementer.** Files: `src/twocore/ir.gleam`,
> `src/twocore/backend/emit_core.gleam`, `src/twocore/ir/effect.gleam`, `src/twocore/ir/printer.gleam`,
> `src/twocore/ir/parser.gleam`, `test/twocore/…` (new). No JS semantics here — general BEAM terms.

## Goal

Make it possible to build and take apart the BEAM terms a dynamic frontend needs: **tuples**, **cons
lists**, **atoms**, and **binaries**. Today `TermOp` has only `MakeTuple`/`TupleGet`/`MakeCons` and
`emit_core` returns `Error(UnsupportedNode("term_op"))` for all of them. Ship real lowering + the few
extra constructors, all `Pure` (K8).

## IR delta

1. **`Value` — add two constant terms** (constants belong in `Value`, like `ConstI32`):
   - `ConstAtom(name: String)` — a literal atom (e.g. booleans `true`/`false`, a frontend sentinel).
   - `ConstBinary(bytes: BitArray)` — a literal binary (e.g. a JS string literal).
   > ⚠ Blast radius: every exhaustive match on `Value` (emit_core `emit_value`, `collect_values`,
   > printer, parser, and the WASM `validate` surface which must **reject** these — K7) gains two arms.
   > Grep `emit_value`, and every `case … { Var\|ConstI32 … }`. This is the only invasive part; do it
   > carefully and let the compiler's exhaustiveness checker drive completeness.

2. **`TermOp` — extend** (it is already commented "extend in Phase 2"):
   - Keep `MakeTuple`, `TupleGet(index)`, `MakeCons`.
   - Add `TupleSize`, `ListHead`, `ListTail`, `IsEmptyList`.
   > `TermOp(op, args)`: `MakeTuple` takes N `args`; `TupleGet(i)`/`TupleSize`/`ListHead`/`ListTail`/
   > `IsEmptyList` take exactly 1; `MakeCons` takes 2.

## Semantics & Core Erlang lowering (in `emit_core`, replacing the `Error` arm)

| IR | args | result type | Core Erlang |
|---|---|---|---|
| `MakeTuple` | v₁…vₙ | `TTerm` | `{V₁,…,Vₙ}` (`CTuple`) |
| `TupleGet(i)` | t | `TTerm` | `call 'erlang':'element'(i+1, T)` (IR index is **0-based**; `element/2` is 1-based) |
| `TupleSize` | t | `TI32` | `call 'erlang':'tuple_size'(T)` |
| `MakeCons` | h, t | `TTerm` | `[H\|T]` (`CCons`) |
| `ListHead` | l | `TTerm` | `call 'erlang':'hd'(L)` |
| `ListTail` | l | `TTerm` | `call 'erlang':'tl'(L)` |
| `IsEmptyList` | l | `TI32` | `case L of [] -> 1; _ -> 0 end` (an **i32 truth value**, so it drops into `If`/`Switch`) |
| `ConstAtom(a)` | — | `TTerm` | `'a'` (`CAtom`) |
| `ConstBinary(b)` | — | `TTerm` | a Core binary literal of the bytes |

Result-type note: `TupleGet`/`ListHead`/`ListTail` produce a `TTerm` (opaque); `TupleSize`/
`IsEmptyList` produce `TI32`. The frontend tracks static types; the IR node's produced type is fixed as
above. Follow the existing `emit_num`/`emit_value` continuation-passing style (`Cont`/`StateChan`).

## Effect classification (`effect.gleam`, K8)

All of these are **`Pure`** non-barriers (construct/inspect immutable terms; never trap, never touch
mutable instance state) — `TermOp(_,_)` is already classified `Pure`; keep it, and add the two new
`Value` constants to whatever the pure-value predicate is. (Tuples/lists are immutable on the BEAM, so
even reads are pure.)

## Textual IR (`printer.gleam` + `parser.gleam`)

Extend the printer + round-trip parser for the new `TermOp` variants and the two `Value` constants so
`ir4_freeze`/textual-form tests still pass. Match the existing surface's naming (e.g. `tuple.size`,
`list.head`, `list.tail`, `list.is_empty`, `atom "…"`, `binary 0x…`); mirror however `make_tuple` /
`tuple.get` are already printed.

## Tests (spec-first — assert defined BEAM behavior, D8)

Author IR fragments, run them IR → `emit_core` → `build_beam` → BEAM, call via `erlang:apply`, assert
the **value**:
- `MakeTuple [1,2,3]` → the BEAM tuple `{1,2,3}`; `TupleGet(1)` of it → `2`; `TupleSize` → `3`.
- `MakeCons(1, MakeCons(2, ConstNil-ish))` → `[1,2]`; `ListHead` → `1`; `ListTail` → `[2]`;
  `IsEmptyList []` → `1`, `IsEmptyList [1]` → `0`.
- `ConstAtom("ok")` → the atom `ok`; `ConstBinary(<<"hi">>)` → the binary `<<"hi">>`.
- **Conformance-neutral:** a representative WASM module still lowers byte-identically (no Phase-8 node
  arises from WASM).

## Definition of Done

Full suite green (≥1694, 0 failures), `gleam format`/`gleam build` clean, WASM corpus byte-identical,
`00-overview.md` unit table stays accurate. Commit as `phase-8/01: term construction & destructuring`
and push.
