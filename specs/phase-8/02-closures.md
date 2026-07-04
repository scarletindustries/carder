# Phase 8 · Unit 02 — Native closures (the headline)

> Read [`00-overview.md`](00-overview.md) (K3) + unit 01. This is the unit that makes the BEAM road
> *win*: a closure over an enclosing-function local — **the exact thing Porffor cannot do** (its WASM
> target has no closures; see `vendor/porffor/FINDINGS.md §8b`) — is here just a **BEAM `fun`**, which
> the backend can already emit (`CFun`/`CLetrec`). Files: `ir.gleam`, `emit_core.gleam`, `effect.gleam`,
> `printer.gleam`, `parser.gleam`, tests.

## Goal

Two new `Expr` nodes: create a native closure over already-evaluated captured values, and apply a
closure value. The BEAM owns the closure's environment, lifetime, and GC. No heap environments, no
relooping, no linear memory.

## IR delta (`Expr`)

- `MakeClosure(fn_name: String, captures: List(Value), arity: Int)` — build a fun of runtime arity
  `arity` that closes over `captures` and forwards to the same-module function `fn_name`. `fn_name`
  **must be a defined `Function` of arity `list.length(captures) + arity`** (add to the same
  `UnknownFunction` resolution `CallDirect`/`ExportFn` already use). Result type: `TTerm` (a fun is a
  term). **`Pure`** (K8): building a fun over evaluated values has no effect and cannot trap.
- `CallClosure(callee: Value, args: List(Value))` — apply the fun value `callee` to `args`. Result
  type: `TTerm`. **`Effectful` + barrier** (K8): it transfers to arbitrary code (same class as
  `CallIndirect`/`CallHost`).

> **Calling convention is the frontend's** (K1): the IR fixes only "captures come first, then the
> `arity` runtime args." A JS frontend will, e.g., compile every JS function to arity-2 `(This,
> ArgsList)` and emit `MakeClosure(f, caps, 2)` / `CallClosure(fv, [this, args])`. The IR does not
> know or care.

## Core Erlang lowering (`emit_core`)

- `MakeClosure(f, [C₁…Cₘ], n)` →
  ```
  fun (A_1, …, A_n) -> apply 'f'/(m+n) (C₁, …, Cₘ, A_1, …, A_n)
  ```
  i.e. a `CFun` of arity `n` whose body is a **same-module direct call** to `f` (reuse the exact
  local-call form `CallDirect` already emits — do **not** invent a new call shape) with the captured
  values textually prepended. Because captures are ordinary already-emitted `Value`s, the `CFun` closes
  over them by BEAM value capture — nothing else to do.
- `CallClosure(F, [A₁…Aₙ])` → `apply F (A₁, …, Aₙ)` (Core Erlang `apply` of a fun value). Thread state
  like the other barrier calls (`CallIndirect`) — under `Threaded` state it is a barrier; the result
  is one value.

Edge cases the implementer must handle: `arity = 0` (nullary fun; body is `f(C₁…Cₘ)`); `captures = []`
(a plain `fun` forwarding all args — still valid, just no closed-over values); arity/`fn_name`-arity
agreement is a **validate**-time / resolution error, not a panic (typed error like `UnknownFunction`).

## Effect (`effect.gleam`, K8)

`MakeClosure` → `Pure` non-barrier (CSE/DCE/hoist OK — a fun literal over pure values is inert).
`CallClosure` → `Effectful` **barrier** (list it beside `CallIndirect`/`CallHost` in
`is_effectful_node` and the barrier set). Default-effectful discipline: if unsure, effectful.

## Mutable captures — explicitly out of the IR (K1)

A JS closure that captures a **mutated** `let` needs a shared mutable cell. That is **not** an IR
concern: the frontend captures a *cell handle* (an opaque `TTerm`) and does reads/writes through
`rt_js` (`CallHost("js","cell_get",…)` / `"cell_set"` — unit 05 / the frontend's runtime). `MakeClosure`
captures the handle's **value** (the handle), exactly like any other capture. Do **not** add mutable
cells to the IR — they carry no general meaning and would leak a runtime policy into the source-agnostic
IR. (Immutable captures — the common case, and the whole headline — are fully covered here.)

## Tests (spec-first, run on the BEAM)

- **The headline.** A helper function `f(Cap, A) = Cap` (returns its capture). IR:
  `Let([c], <make cap = 42>, MakeClosure("f", [Var c], 1))` bound to `g`, then
  `CallClosure(Var g, [<anything>])` → **`42`**. This proves a closure sees an enclosing local — the
  Porffor wall, gone.
- **Closure carries data past its creator's return.** Build the closure in one exported function,
  return it (a `TTerm`), then in the test apply it via `erlang:apply` → still returns the captured
  value. (BEAM funs outlive their creating frame — free.)
- **Multiple captures + non-zero arity.** `add(C1, C2, X) = C1+C2+X`; `MakeClosure("add",[10,20],1)`;
  `CallClosure(_, [5])` → `35`.
- **`arity=0`.** `k(C)=C`; `MakeClosure("k",[7],0)`; `CallClosure(_, [])` → `7`.
- Conformance-neutral: WASM corpus byte-identical.

## Definition of Done

Suite green (≥1694, 0 failures), format/build clean, WASM byte-identical. Commit
`phase-8/02: native closures (MakeClosure/CallClosure)` and push.
