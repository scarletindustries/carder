# Phase 8 · Unit 03 — Maps (the object substrate)

> Read [`00-overview.md`](00-overview.md) (K4, K8) + unit 01. Ships the **immutable functional BEAM
> map** primitive — the substrate a frontend builds JS objects on. Files: `ir.gleam`, `emit_core.gleam`,
> `effect.gleam`, `printer.gleam`, `parser.gleam`, tests.

## Design (K1, K4)

JS objects are **mutable with identity**; BEAM maps are **immutable** (functional update returns a new
map). So the IR ships the *immutable map* primitive (a general BEAM value), and the **frontend** builds
mutable JS objects on top (an object = an `rt_js` cell holding a map; `obj.x = v` = `cell_set(c,
map_put(cell_get(c), k, v))`). Do **not** put mutable-object identity or prototype semantics in the IR
(K1). Because maps are immutable, **every map op is `Pure`** (K8) — CSE/DCE/reorder are sound.

## IR delta

One new `Expr` variant grouping the ops (mirrors `TermOp`, minimal blast radius):
`MapOp(op: MapOp, args: List(Value))` with

```
pub type MapOp { MapNew  MapGet  MapPut  MapHas  MapRemove  MapSize }
```

| MapOp | args | result | Core Erlang |
|---|---|---|---|
| `MapNew` | — | `TTerm` | `~{}~` (empty map literal) |
| `MapGet` | m, k, default | `TTerm` | `call 'maps':'get'(K, M, Default)` (missing ⇒ frontend sentinel) |
| `MapPut` | m, k, v | `TTerm` | `call 'maps':'put'(K, V, M)` (returns a **new** map) |
| `MapHas` | m, k | `TI32` | `case call 'maps':'is_key'(K,M) of 'true'->1; 'false'->0 end` (i32 truth → `If`/`Switch`) |
| `MapRemove` | m, k | `TTerm` | `call 'maps':'remove'(K, M)` (new map) |
| `MapSize` | m | `TI32` | `call 'maps':'size'(M)` |

`MapGet` takes an explicit `default` so a missing key deterministically yields the frontend's
`undefined` sentinel — no BEAM `badkey`. Keys/values are any `TTerm` (atoms, binaries, ints…).

## Effect (K8)

All six are **`Pure`** non-barriers (immutable maps; no trap, no shared mutable state). Add `MapOp(_,_)`
to the pure/non-barrier classification beside `TermOp`.

## Textual IR

Printer + round-trip parser for `MapOp` (e.g. `map.new`, `map.get`, `map.put`, `map.has`,
`map.remove`, `map.size`), matching the `TermOp` textual style.

## Tests (spec-first)

- `MapPut(MapNew, atom "x", 1)` → `#{x => 1}`; `MapGet(that, atom "x", 0)` → `1`;
  `MapGet(that, atom "y", 999)` → `999` (default); `MapHas(_, x)` → `1`, `MapHas(_, y)` → `0`;
  `MapSize` → `1`; `MapRemove(_, x)` then `MapSize` → `0`.
- Chained puts build the expected map; put over an existing key overwrites.
- Conformance-neutral: WASM byte-identical.

## Definition of Done

Suite green (≥1694, 0 failures), format/build clean, WASM byte-identical. Commit
`phase-8/03: maps (object substrate)` and push.
