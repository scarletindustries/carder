# Phase 8 — A BEAM-native value layer for the IR ("native JS on the BEAM")

> **Read after the Phase-1…7 overviews.** Every prior decision **still holds** — one owner per file,
> runtime layers reached only through the binding chokepoint with **no ambient authority** (D3a),
> per-stage error types, floats/v128 as raw bit patterns (D5), named-label structured IR, the tier
> ladder, the two modes (Safe/Unsafe), **spec-first tests** (assert defined behavior, never
> change-detector output — D8), `gleam format`/`gleam build` clean, the strict Definition of Done.
> Baseline entering Phase 8: **1694 tests, 0 failures, 0 warnings**; the complete WASM 2.0 surface +
> the Phase-7 Porffor→BEAM JS path are green.
>
> This page adds the Phase-8 decisions **K1–K9**. **The authoritative interface for the frontend team
> is [`HANDOFF-arc-frontend.md`](HANDOFF-arc-frontend.md)** — the full IR spec they compile JavaScript
> to. Implementer read order: this overview → the unit doc you own → `HANDOFF-arc-frontend.md`.

---

## 0. Where Phase 8 sits (the second road to JS-on-BEAM)

Phase 7 reached JS-on-BEAM the **Porffor** way: `JS → Porffor → WASM → fe_wasm → IR → Core Erlang →
BEAM`. That road works but is bounded by Porffor's ⅓-of-ECMA-262 coverage **and** — as the vendored
self-hosting effort proved — by Porffor's missing **closures over enclosing-function locals** (a
foundational gap in a WASM-target compiler: WASM has no closures, so Porffor must hand-build heap
environments, and stalls). See `vendor/porffor/FINDINGS.md §8b`.

Phase 8 opens the **second road**, which *inverts that difficulty*: a **from-scratch JavaScript
frontend** — reusing a mature JS **parser + scope/capture analysis** (the `arc` engine, MIT, written
in Gleam) — that emits **2core IR directly**, bypassing WASM entirely. Because the target is the
**BEAM**, the four things Porffor had to synthesize in linear memory are **native primitives**:

| JS needs | Porffor (WASM target) | Phase-8 IR (BEAM target) |
|---|---|---|
| closures | hand-built heap environments (**the wall**) | a **BEAM `fun`** — the backend already has `CFun`/`CLetrec` |
| GC | none (linear memory + manual) | **BEAM GC**, free |
| objects | linear-memory structs + hidden classes | **BEAM maps** (dictionary) + shaped tuples (fast path) |
| bignums / strings | hand-coded | **BEAM bignums / binaries**, free |

**Phase 8 is IR-only.** The frontend (parser → scope → a new `emit_2core` backend) is being written by
a separate team against `HANDOFF-arc-frontend.md`. *Our* job is to grow 2core's IR + `emit_core`
backend from a WASM-lowering target into one that can host a **compiled dynamic language** on the
BEAM, as fast as possible — a general **BEAM-native value layer**: term construction, native closures,
maps, the term↔numeric boxing bridge, and a fixed, capability-safe **runtime-call boundary**. We add
*general* primitives; **JS semantics live in the frontend + its `rt_js` runtime, never in the IR**
(the IR stays a clean, source-agnostic lowering target — the same discipline as the WASM road).

---

## 1. The Phase-8 goal (concrete and measurable)

> **A BEAM-native value layer in the IR.** After Phase 8, a program expressed in 2core IR can
> construct and destructure BEAM terms (tuples/lists/atoms/binaries), create and apply **native BEAM
> closures**, build and mutate **maps**, move values across the **term↔numeric boxing bridge**
> (unboxed `i32`/`f64` fast paths ↔ boxed terms), and call a **fixed, allow-listed runtime module**
> (`rt_js`, the frontend's JS runtime) through the existing capability chokepoint — all lowering to
> idiomatic, preemptive, GC'd Core Erlang. The complete WASM 2.0 corpus + spec suite stay
> **byte-identical** (every Phase-8 node is *additive*; a WASM module never emits one).

### Acceptance (owned by the capstone unit)

| Area | Must demonstrate (spec-first, run on the real BEAM) |
|---|---|
| **term layer** | IR that builds `{a,b,c}` / `[h\|t]` / an atom / a binary, and reads them back, produces the exact BEAM term and round-trips (`erlang:apply` asserts the value, not bytes) |
| **closures (headline)** | IR that `MakeClosure`s over a captured value and later `CallClosure`s it returns the captured value — i.e. **a closure over an enclosing local works**, the exact thing Porffor cannot do; a boxed (mutable) capture observes writes made after capture |
| **objects / maps** | `MapNew`/`MapPut`/`MapGet`/`MapHas`/`MapRemove`/`MapSize` behave as a dictionary; missing-key `MapGet` yields the frontend's sentinel; insertion mutates functionally-correctly |
| **boxing bridge** | `BoxFloat`∘`UnboxFloat` and `BoxInt`∘`UnboxInt` round-trip for representative values incl. edge bit-patterns; a value flows `f64` → box → term → unbox → `f64` unchanged |
| **runtime boundary** | a `CallHost("js", op, args)` reaches a **build-fixed** `rt_js` dispatch (literal `case`, **no `apply/3`** — D3a); an unknown op **fails closed**; results decode |
| **conformance-neutral + all-tier** | the entire Phase-1…7 corpus + spec suite stay **byte-identical** under both profiles and every tier; a module with no Phase-8 nodes is unchanged |

### Honest scope (K9 — do not overstate)

- **IR + backend only.** We do **not** write the JS frontend, the `rt_js` runtime, or any JS semantics.
  We ship the IR primitives + their Core-Erlang lowering + tests, and the handoff spec. "JS runs" is
  the *frontend team's* acceptance, gated on these primitives.
- **General, not JS-shaped.** No node encodes JS coercion/prototype/`this` semantics. If a proposed
  node only makes sense for JS, it belongs in the frontend or `rt_js`, not the IR (K1).
- **Fast paths are opt-in.** The IR *enables* speed (unboxed numerics, direct closures, shaped
  objects) but does not force it; a naive frontend that boxes everything and calls `rt_js` per op is
  correct, just slow. Real speed is the frontend's job using these primitives.

---

## 2. Decisions K1–K9

- **K1 — The IR stays source-agnostic.** Phase-8 nodes are *general BEAM-value* primitives (terms,
  funs, maps, boxing, a runtime chokepoint), reusable by any dynamic-language frontend. No JS
  semantics in the IR. (Rationale: same discipline that kept the WASM road clean.)
- **K2 — Values are BEAM-native, not linear-memory.** A dynamic value is a **BEAM term** carried in
  `TTerm`; a number on a proven fast path is an unboxed `TI32`/`TF64`. Objects are maps; closures are
  funs; strings are binaries; bignums are BEAM integers. We lean on the BEAM runtime, not linear
  memory. (This is *why the BEAM road beats the WASM road for a dynamic language*.)
- **K3 — Closures are native `fun`s.** `MakeClosure(fn, captures)` lowers to a Core Erlang `fun`
  closing over `captures` and tail-forwarding to `fn`; `CallClosure(f, args)` lowers to `apply`.
  Captured **mutable** locals are shared via a one-cell ref (a mutable capture = capture the cell, not
  the value). No heap environments, no relooping — the BEAM owns closure lifetime + GC.
- **K4 — Objects are BEAM maps first, shaped tuples later.** Phase 8 ships the **map** primitive
  (dictionary correctness). A monomorphic **shape/hidden-class** fast path (shaped tuple + shape-id
  guard + `CallHost` deopt) is specified for a later unit but **not required** for the milestone.
- **K5 — The boxing bridge is the only crossing.** `BoxInt`/`UnboxInt`/`BoxFloat`/`UnboxFloat` are the
  sole IR nodes moving a value between the unboxed numeric layer (`TI32`/`TI64`/`TF32`/`TF64`) and the
  term layer (`TTerm`). The frontend keeps hot arithmetic unboxed and boxes only at boundaries. (D5
  raw-bit-pattern floats: the bridge must be bit-exact — round-trip is a hard test.)
- **K6 — The runtime boundary is the capability chokepoint, fail-closed.** JS-semantic ops (property
  get with prototypes, coercion, `+` with `ToPrimitive`, builtins) are **not** IR nodes; the frontend
  emits `CallHost("js", op, args)` reaching a **build-fixed `rt_js` shim** — a literal `case` per op,
  **never `apply(Mod,Fn,Args)` from data** (D3a). Unknown op ⇒ typed failure, closed. This mirrors the
  Phase-7 Porffor `rt_host` shim exactly.
- **K7 — Additive + conformance-neutral.** Every Phase-8 node is new; `decode`/`validate`/`lower`
  (the WASM frontend) never produce one, so the WASM corpus is byte-identical. New nodes are rejected
  by the WASM validator surface (they cannot arise from WASM) and accepted by the direct-IR path.
- **K8 — Effect honesty.** Pure constructors (`MakeTuple`, `MakeCons`, `Box*`/`Unbox*`, `MapNew`,
  `MakeClosure`) classify **`Pure`** (CSE/DCE/reorder OK); anything that reads/writes shared mutable
  state or calls out (`CallClosure`, `CallHost`, map *reads that can observe mutation if maps become
  mutable* — see unit 03) classifies **`Effectful`/barrier**. Default to `Effectful`; narrow only with
  a structural proof (the existing `effect.gleam` posture).
- **K9 — Ship IR only; measure honestly.** See §1 honest scope.

---

## 3. The value model (one diagram)

```
        unboxed fast layer                     boxed dynamic layer (a BEAM term, TTerm)
        ─────────────────                      ───────────────────────────────────────
        TI32  (JS bitwise / smi)   ──Box*──▶   integer term            (BEAM bignum-safe)
        TF64  (JS number)          ──Box*──▶   float term
                                   ◀─Unbox─
                                               atom / boolean          ConstAtom, rt_js sentinels
                                               binary                  JS string (rt_js owns encoding)
                                               tuple {tag, …}          shaped object / JS internal record
                                               map #{key => val}       JS object (dictionary)
                                               fun/N                    JS closure  ← MakeClosure/CallClosure
                                               cons [h|t]               arg lists, iterables

   The frontend keeps arithmetic in the fast layer; crosses via the boxing bridge (K5);
   builds/reads terms with the term layer (unit 01); objects with maps (unit 03);
   functions with native closures (unit 02); and reaches JS semantics only through
   CallHost("js", …) → rt_js (unit 05). rt_js and all JS semantics are the frontend's, not ours.
```

---

## 4. The units (implementation order = dependency order)

| # | Unit | Ships | Depends |
|---|---|---|---|
| 01 | [`01-term-construction.md`](01-term-construction.md) | `TermOp` buildout (tuples/lists/atoms/binaries) + `ConstAtom`; `emit_core` lowering; effect; textual IR | — |
| 02 | [`02-closures.md`](02-closures.md) | `MakeClosure`/`CallClosure` → Core `fun`/`apply`; mutable-capture cells | 01 |
| 03 | [`03-objects-maps.md`](03-objects-maps.md) | map ops (JS objects) → Core maps | 01 |
| 04 | [`04-boxing-bridge.md`](04-boxing-bridge.md) | `Box/Unbox Int/Float` lowering (bit-exact, D5) | 01 |
| 05 | [`05-js-runtime-boundary.md`](05-js-runtime-boundary.md) | the fixed `rt_js` `CallHost("js",…)` shim (D3a fail-closed) | — |
| 06 | [`06-numeric-fastpath.md`](06-numeric-fastpath.md) | JS-number fast-path helpers (classify/guarded arith) built from 01/04 | 01, 04 |
| — | [`HANDOFF-arc-frontend.md`](HANDOFF-arc-frontend.md) | **the full IR spec the frontend compiles JS to** (all nodes + JS-construct mapping + the compiled-code↔`rt_js` ABI) | all |

**Every unit's Definition of Done:** spec-first tests that run IR → `emit_core` → `build_beam` → BEAM
and assert *defined behavior* (never bytes); `gleam format` clean; `gleam build` 0 warnings; the full
suite stays green (≥1694, 0 failures); the WASM corpus byte-identical; committed as one focused unit
and pushed.

---

## 5. Status — shipped

**All six IR units are implemented, tested, and on `main` (green: 1734 tests, 0 failures, 0 warnings,
WASM byte-identical throughout).**

| # | Unit | Commit | Adds |
|---|---|---|---|
| 01 | term construction | `phase-8/01` | `Value` `ConstAtom`/`ConstBinary`; `TermOp` `TupleSize`/`ListHead`/`ListTail`/`IsEmptyList` (+ real lowering for the pre-existing `MakeTuple`/`TupleGet`/`MakeCons`) |
| 02 | native closures | `phase-8/02` | `Expr` `MakeClosure`/`CallClosure` → Core `fun`/`apply` (new `CApplyExpr`) — **closures over enclosing locals, Porffor's wall gone** |
| 03 | maps | `phase-8/03` | `Expr` `MapOp{New,Get,Put,Has,Remove,Size}` → BEAM maps (object substrate) |
| 04 | boxing bridge | `phase-8/04` | `BoxInt/UnboxInt/BoxFloat/UnboxFloat` lowering — a **lossless identity retag** (2core scalars are raw bit patterns, D5; the only NaN/Inf-safe representation) |
| 05 | `rt_js` boundary | `phase-8/05` | `Binding.js_runtime_module` + the fixed, fail-closed `CallHost("js",…)` dispatch (D3a, no apply-from-data) + an `rt_js` stub |
| 06 | classification + native arithmetic | `phase-8/06` | `Expr` `TermTest`/`TermTag` (guards) + `NumTerm` (native BEAM `+`/`-`/`*`/compare) — the **guarded fast path**, with the composed `a+b` fast/slow proof |

The mid-phase reconciliation (`61eae06`) corrected the numeric model after unit 04's bit-pattern
finding: a **JS number is a native BEAM `float()`/`integer()`** (so `TermTest(IsNumber)` guards + native
`NumTerm` arithmetic work), while `Box/UnboxFloat` is the *separate* raw-f64↔term bridge (typed arrays /
wasm interop). See [`HANDOFF-arc-frontend.md`](HANDOFF-arc-frontend.md) §2 (the "number note").

## 6. Future work (NOT in Phase 8 — for a later IR unit or the frontend)

- **Shaped-object inline caches (K4, a real speed unit).** A monomorphic hidden-class fast path: a
  shaped **tuple** (`{shape_id, slot₀, slot₁, …}`) + a `TermTag`/shape-id guard + a fixed-offset
  `TupleGet`, deopting to `rt_js.get_prop` on a shape miss. Needs a `CMap`/non-empty-map Core literal
  node (unit 03 used `maps:new/0` + `maps:put` chains; a shaped path wants a real map/tuple literal).
- **Guarded division** (`NumTerm` omits `/`,`%` because BEAM `/0` traps but JS `1/0=Infinity`): a
  divisor≠0 guard + native op with an Infinity-producing deopt, if profiling shows `rt_js` div is hot.
- **Mutable cells** for captured-and-mutated locals + object storage: deliberately left to `rt_js`
  (K1 — no general IR meaning). If they prove a bottleneck, revisit a first-class `Cell` primitive.
- **Generators / async / direct `eval`:** the frontend's problem (CPS/state-machine transform or an
  arc-VM hybrid) — see `HANDOFF-arc-frontend.md` §6. No IR support is owed; the sync subset is
  fully served by units 01–06.
- **Milestone 0 (de-risk the perf premise):** hand-write IR for one hot function (unboxed/native path
  + a `MakeClosure` + one `CallHost`), run to BEAM, benchmark vs arc's interpreter — the load-bearing
  unknown before the frontend invests. Owned by whoever starts the frontend.
