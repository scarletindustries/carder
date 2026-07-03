# Phase 7 — Overview & Shared Contracts ("JS on the BEAM via Porffor")

> **Read this after the Phase-1…Phase-6 overviews.** Every decision on those pages **still holds** —
> one owner per file, runtime layers reached through the binding chokepoint with **no ambient
> authority** (D3a), per-stage error types, floats/v128 as raw bit patterns (D5), named-label
> structured IR, the tier ladder, the two modes (Safe/Unsafe), spec-first tests, the strict
> Definition of Done. This page adds the Phase-7 decisions **J1–J8**. Phases 1–6 are complete and
> green: **1491 tests, 0 warnings, conformance 46,529 / 1,768 / 0** (Safe ≡ Unsafe, all 5 tier
> combos) — the **complete WebAssembly 2.0 surface** (reference types, bulk memory, multi-memory,
> memory64, **SIMD**, cross-module linking).
>
> **⚠ After the scoping fan-out + adversarial critique, the canonical decisions will be reconciled in
> [`RECONCILIATION.md`](RECONCILIATION.md). That file is AUTHORITATIVE. Implementer read order: this
> overview → [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md) → `RECONCILIATION.md` → the unit
> doc.** The findings doc is **measured** (real Porffor 0.61.13 output), not assumed.

---

## 0. Where Phase 7 sits (the platform, one paragraph)

Phases 1–6 built the **complete WebAssembly 2.0 engine** on the BEAM. That was always the means to an
end: the high-level spec's stated **goal** — *any Porffor application runs via 2core on the BEAM*
("JS on the BEAM", §8.2). Porffor (CanadaHonk) is a from-scratch AOT JS→WASM compiler; chaining
**Porffor (JS→WASM) → `fe_wasm` → IR → Core Erlang → BEAM** yields JS running as compiled, preemptive
BEAM code. Phase 7 is the phase that **reaches the goal**. The EM homework
([`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md)) measured Porffor's real output and found the
picture is remarkably clean: **everything Porffor emits, 2core already runs after Phase 6 — with
exactly one exception: WASM exception handling** (Porffor throws pervasively — 64× in a trivial
program — and `try/catch` JS becomes `try_table`/`catch`). So Phase 7's load-bearing engine work is
**WASM exception handling**, which maps *beautifully* onto BEAM-native `try`/`catch`/`throw` (the same
compile-to-Erlang elegance as tail calls and preemption). On top of that sits the **Porffor-ABI
`rt_host` shim** (Porffor's own runtime intrinsics — not WASI) and a **JS-subset conformance harness**
(compile JS with Porffor, run it through 2core, check the JS result), bounded by Porffor's
experimental coverage.

---

## 1. The Phase-7 goal (concrete and measurable)

> **JS on the BEAM.** A real, Porffor-compilable JavaScript program — compiled by Porffor to WASM,
> then decoded / validated / lowered / emitted by 2core to Core Erlang and loaded onto the BEAM —
> **runs and produces the correct JS result**, as compiled, preemptive BEAM code. The load-bearing
> new engine feature is **WASM exception handling** (tags, `throw`, `try_table`/`catch`, `throw_ref`)
> lowered to **BEAM-native exceptions**; the enabling glue is the **Porffor-ABI `rt_host` shim** (the
> intrinsic imports Porffor's output declares + the `(f64, i32)` typed-value ABI) and a **JS-subset
> conformance harness** that drives Porffor → 2core → BEAM over a JS corpus and checks results
> **differentially against Porffor's own execution** (`porf run`) / Node. Everything is compiled (not
> interpreted), constant-space loops + preemption are preserved, and the existing WASM corpus + spec
> suite stay **byte-identical** (EH is conformance-neutral by default — a module with no tags is
> unchanged).

### Acceptance (owned by the capstone)

| Area | Must demonstrate |
|---|---|
| **exception handling — engine** | a WASM module with a `(tag)`, `throw`, and `try_table`/`catch` executes spec-correctly: an uncaught `throw` propagates out as a trap/BEAM exception; a `try_table` **catches the matching tag**, binds its payload, and **re-raises a non-matching exception**; nested try/catch unwinds correctly; the official EH `.wast` (`throw.wast`/`try_table.wast`/`tag.wast`/`throw_ref.wast` where `wast2json`-able at the pin) run green (or an authored in-scope proof where not) |
| **EH ↔ BEAM mapping** | EH lowers to Core Erlang `try…catch`/`throw` (or `raise`); a caught exception is a BEAM catch, an uncaught one a BEAM raise; **constant-space loops + preemption survive** an exception on the hot path; the D3a security invariants hold (a thrown value is a term, never ambient authority) |
| **Porffor-ABI host shim** | the intrinsic imports Porffor declares (`("" "a")`, `("" "b")`, + whatever a wider corpus pulls in) are provided by a **build-fixed** `rt_host` Porffor shim (literal `case`, no `apply/3` — D3a); the `(f64, i32)` typed-value ABI is understood by the run-ABI so results can be decoded + judged; an unprovided intrinsic **fails closed** |
| **JS on the BEAM (the headline)** | a corpus of real JS programs (arithmetic, control flow, functions/closures, strings, arrays, objects, `try/catch`, `console.log`) **compiled by Porffor and run through 2core on the BEAM** produces output **matching Porffor's own execution / Node** — *measured*, with the JS-subset coverage reported honestly (bounded by Porffor) |
| **conformance-neutral + all-tier** | the entire Phase-1..6 WASM corpus + spec suite stay **byte-identical** under both profiles and every tier (a module with no tags/EH is unchanged); the JS/EH surface is green under the matrix it is defined for |

### Honest scope (J8 — do not overstate)

- **Bounded by Porffor's JS coverage.** Porffor is an experimental research compiler supporting on the
  order of **⅓ of ECMA-262**, tracking no particular spec version (§8.2). What reaches the BEAM is
  *the JS Porffor can compile*, not arbitrary JS. The JS-subset harness **measures** what runs; we
  claim exactly that — never "full JS".
- **Exception handling is the engine feature; it maps to BEAM exceptions, not emulated.** The BEAM's
  native `try/catch/throw` is the target — faithful and fast (no interpreter, no reified stack). We
  implement the standardized WASM EH proposal's surface Porffor uses (tags, `throw`, `try_table`/
  `catch` variants, `throw_ref`); the rarely-used corners Porffor never emits are scoped by what the
  EH `.wast` + Porffor's output actually exercise (measured, categorized).
- **No WASI, no browser DOM.** The shim is **Porffor's runtime ABI** (its console/memory/string
  intrinsics), not WASI and not a DOM. Programs that need host APIs Porffor stubs/omits are out of
  scope (a categorized gap).
- **This is a frontend/goal phase, not a speed phase.** Phase 4's performance numbers stand; the JS
  path inherits the WASM engine's performance (compiled, preemptive). No new perf claim beyond "it
  runs as compiled BEAM code."
- **The IR grows (EH nodes) language-neutrally.** Like the term layer, EH is a **generic structured-
  exception model** (throw a value / try-catch by tag), usable by a future native JS or Gleam
  frontend — not a WASM-ism. Conformance-neutral by default (no tag ⇒ byte-identical).
- **Deferred (state it):** GC-proposal reftypes (Porffor doesn't need them — confirmed); a native JS
  frontend (Porffor IS the JS frontend); the Erlang/Gleam frontend; stack-switching / the component
  model; the single-`.beam` B1 binding; tier-N; the memory optimizer. **WASI** stays an `rt_host`
  impl, out of core.

---

## 2. The Phase-7 decisions (J1–J8)

Frozen for Phase 7. If you believe one is wrong, raise it with the planner **before** building.

### J1 — The keystone is WASM exception handling lowered to BEAM-native exceptions

Phase 7's load-bearing new thing is **exception handling**. Measured: Porffor emits a `(tag (param
f64 i32))` (the exception type carrying the thrown JS value as a `(f64, i32)` pair), `throw <tagidx>`
pervasively, and `try_table`/`catch` for JS `try/catch`. The BEAM has first-class exceptions, so this
lowers **directly** (compile-to-Erlang gives us the machinery for free):
- a WASM **`(tag)`** → a distinguishable BEAM exception term (a build-controlled shape, e.g.
  `{wasm_exn, TagId, Payload}` where `Payload` is the tag's operand value list);
- **`throw t (vals…)`** → a BEAM `erlang:throw`/`raise` of that term (routed through `rt_trap`/a new
  `rt_exn`, never an ambient construct);
- **`try_table`** (with its `catch`/`catch_ref`/`catch_all`/`catch_all_ref` clauses) → a Core Erlang
  `try … of … catch …` that matches the tag, binds the payload to the clause's target label values,
  and **re-raises a non-matching exception** (spec §4.4.9 unwinding);
- **`throw_ref`** (re-throw a caught exnref) → re-raise the captured term.
Constant-space loops + preemption are preserved (BEAM unwinding is native). The keystone (**P7-01**)
freezes the EH IR nodes (J2), the BEAM-lowering contract, the `rt_exn`/`rt_trap` signatures, and the
`.ir` grammar delta; it lands green, byte-identical for tag-free modules.

### J2 — EH is a small, language-neutral IR surface (tags + throw + try-catch), not WASM opcodes

New IR (final names frozen by P7-01), all **effectful barriers**:
- **`Module.tags: List(TagDecl)`** — a tag is a name + a `FuncType`-style operand signature (the
  types the exception carries). Imported/exported tags follow the P5 import/export state pattern.
- **`Throw(tag, args)`** `Expr` — throw exception `tag` carrying `args` (does not return — bottom, like
  `Return`/`Trap`).
- **`TryTable(result, body, catches)`** `Expr` — evaluate `body`; each `catch` clause is `(tag |
  catch_all, label, ref?: Bool)` — on a matching thrown tag, transfer to `label` with the payload
  (and the exnref if `ref`); an unmatched exception propagates. Structured (named labels, D6), so it
  maps onto the existing block/label machinery + a Core Erlang `try`.
- **`ThrowRef(exnref)`** `Expr` — re-raise a caught exception reference; **`exnref`** is a new
  reference-layer value (a caught-exception handle, opaque like `externref`).
The design is a **generic structured-exception model** (throw a value, catch by class) — a future JS/
Gleam frontend reuses it; nothing WASM-specific leaks into the IR core (decision #1). `emit_core` maps
these onto Core Erlang `try/catch/throw`; the runtime term shape is the binding chokepoint.

### J3 — The Porffor-ABI host shim is a build-fixed `rt_host` implementation (Porffor's ABI, not WASI)

Porffor's output imports a tiny, treeshaken set of intrinsics from module `""` (measured: `("" "a")`,
`("" "b")`, both `(func (param f64))` — its console/print primitives; a wider corpus pulls in more).
Phase 7 ships a **Porffor-ABI `rt_host` shim**: a **build-fixed registry** (literal `case`, no
`apply/3`, D3a-clean — exactly like the `spectest` registry) implementing Porffor's runtime
intrinsics. The **value ABI** is Porffor's `(f64, i32)` typed pair (value + type tag) — the run-ABI +
harness understand it (decode a returned `(f64, i32)` into a JS value for judging; `console.log`
output captured). An **unprovided intrinsic fails closed** (a link-time / categorized error, never a
silent stub that corrupts semantics). WASI/DOM are out (J8).

### J4 — The JS-subset conformance harness drives Porffor → 2core → BEAM, measured differentially

A new harness compiles a JS corpus with **Porffor** (`porf wasm`), runs each through the full 2core
pipeline onto the BEAM, and checks the result **differentially against Porffor's own execution**
(`porf run` / Node) — the same "differential against a reference" discipline as the WASM spec suite.
The corpus grows from trivial (arithmetic, `console.log`) to real (closures, strings, arrays, objects,
`try/catch`). Coverage is **measured + reported honestly** (bounded by Porffor — a program Porffor
can't compile, or that needs an unprovided intrinsic, is a categorized skip, never a false green).
This is the phase's proof that *JS runs on the BEAM*.

### J5 — Security & fail-closed for the new surface

- **A thrown exception is a term, never authority.** The tag term shape is build-controlled; `throw`/
  `try_table`/`throw_ref` route through `rt_exn`/`rt_trap` (no ambient `apply` of an attacker term —
  D3a). A caught `exnref` is opaque (like `externref`) — Safe code can re-throw it but not forge/
  inspect the underlying BEAM term.
- **The Porffor shim is build-fixed** (literal `case`, no `apply/3`); an unprovided intrinsic fails
  closed. The Safe capability model is unchanged (the shim's IO intrinsics are explicit, auditable
  host functions).
- **EH does not weaken the sandbox.** An uncaught WASM exception becomes a BEAM exception that the
  instance boundary contains (one-instance-one-process); it cannot escape to other instances or the
  node. Metering/fuel still bites across a throw.

### J6 — The IR grows, but stays language-neutral & conformance-neutral by default

Phase 7 adds `Module.tags`, the `Throw`/`TryTable`/`ThrowRef` `Expr` nodes, an `exnref` reference
value, and a `.ir` grammar delta (owned + reconciled by P7-02). Discipline (decision #1): EH is a
**generic structured-exception model**, the value ABI stays out of the IR (it is a *frontend/host*
concern — Porffor's `(f64, i32)` is a WASM-level convention, not an IR node). **Defaults are
conformance-neutral:** a module with **no tags** decodes/validates/lowers/emits **byte-identically**
to Phase-6 under both modes and every tier.

### J7 — Compiled, preemptive, on the BEAM (the thesis, extended to JS)

JS reaches the BEAM as **compiled** Core Erlang (via Porffor→WASM→IR→Core), not an interpreter. The
BEAM scheduler preempts JS loops at reduction boundaries (the same fair-scheduling that makes "JS on
the BEAM" viable, §9.2). Exceptions use native BEAM unwinding. This is the payoff of every prior
decision: *any Porffor application becomes a well-behaved BEAM citizen.*

### J8 — Honest scope

See §1. Included: **WASM exception handling → BEAM exceptions**, the **Porffor-ABI `rt_host` shim**,
the **JS-subset conformance harness**. Bounded by Porffor's ⅓-of-ECMA coverage — **measured**, never
"full JS". EH is faithful (BEAM-native, not emulated), scoped to what Porffor + the EH `.wast`
exercise. No WASI/DOM. Conformance-neutral by default; no new perf claim (the JS path inherits the
WASM engine's compiled/preemptive performance). Deferred: GC (Porffor doesn't need it), a native JS
frontend (Porffor is it), the Erlang/Gleam frontend, stack-switching / component model, B1, tier-N,
the memory optimizer.

---

## 3. Dependency DAG — freeze milestones

```
WAVE 0   01 KEYSTONE (one owner; lands green):
            «EH-IR-FROZEN»   (Module.tags/TagDecl + Throw/TryTable/ThrowRef Expr + exnref value +
                              the BEAM-exception lowering contract + .ir grammar delta)
            «RT-EXN-SIG»      (rt_exn / rt_trap EH signatures — throw a tagged term, match/rethrow)
            «PORFFOR-ABI»     (the rt_host Porffor-shim contract + the (f64,i32) value-ABI run-ABI)
                 │
   ┌──────┬──────┬──────┬──────┬──────┬───────────────┐
   ▼EH-IR ▼AST   ▼AST   ▼EH-IR ▼EH-IR ▼RT-EXN         ▼PORFFOR-ABI
 ┌─────┐┌─────┐┌─────┐┌─────┐┌─────┐┌───────────────┐┌──────────────┐
 │02   ││03   ││04   ││05   ││06   ││07 rt_exn       ││08 Porffor    │
 │.ir  ││decode││valid ││lower ││emit ││ (EH runtime:  ││ ABI host     │
 │text ││(+AST)││ate  ││     ││core ││ throw/catch/  ││ shim + value ││
 │     ││      ││     ││     ││ (BEAM││ rethrow over  ││ ABI          ││
 │     ││      ││     ││     ││ try) ││ BEAM excs)    ││              ││
 └─────┘└─────┘└─────┘└─────┘└─────┘└───────────────┘└──────────────┘
                       ┌────────────────┐   ┌──────────────────────────────────┐
                       │09 JS-subset     │   │10 CAPSTONE: JS on the BEAM       │
                       │  conformance    │   │   proven; EH green; measured JS  │
                       │  (Porffor→2core)│   │   coverage; honest close          │
                       └────────────────┘   └──────────────────────────────────┘
```

- **Critical path:** the EH frontend 03 decode → 04 validate → 05 lower, then 06 emit (the BEAM `try`
  mapping) + 07 rt_exn (the runtime), then 08 the Porffor shim, then 09 the JS harness proves it.
- **08 (Porffor shim) + 09 (JS harness)** are the "reach the goal" tracks; they need the EH pipeline
  (03–07) because Porffor's output *uses* EH — a JS program won't run until EH works.
- **Conformance-neutral gate:** every EH addition is conformance-neutral by default (03–06 keep the
  no-tag path byte-identical).

*(Proposed unit split — the scoping fan-out may refine, as every prior phase. Open scoping questions:
**(a)** the exact EH IR node shapes (does `try_table` reuse the block/label machinery or a dedicated
node?); **(b)** whether `exnref` reuses the `rt_ref` forge-proof model; **(c)** the exact set of
Porffor intrinsic imports across a JS corpus + their semantics; **(d)** which EH `.wast` files are
`wast2json`-able at the pin vs authored proofs; **(e)** the `(f64, i32)` value-ABI decoding for the
harness.)*

---

## 4. File-ownership map (D1)

> Single owner per file; several units **extend** existing files (single-owner, additive). The
> keystone makes deliberate documented cross-file reaches (growing `Module`/`Expr`/the value layer
> breaks exhaustive matches — it must land green).

| Unit | File(s) | Notes |
|---|---|---|
| **01** keystone | `ir.gleam` (`Module.tags`/`TagDecl`, `Throw`/`TryTable`/`ThrowRef` `Expr`, `exnref` value) · **`runtime/rt_exn.gleam` (NEW — the tagged-exception runtime signatures)** · `ir/effect.gleam` (classify EH nodes as barriers) · `ir/printer.gleam`/`ir/parser.gleam`/`backend/emit_core.gleam`/`frontend/wasm/lower.gleam` (minimal compile-satisfying arms) · doc-freeze the `rt_exn`/`rt_trap` sigs + the Porffor-ABI contract | `«EH-IR-FROZEN»`/`«RT-EXN-SIG»`/`«PORFFOR-ABI»`. Land green, byte-identical (tag-free). |
| **02** `.ir` textual | `ir/printer.gleam`, `ir/parser.gleam` (extend) + `specs/phase-7/ir-grammar-delta.md` | Round-trip tags + throw + try_table/catch + throw_ref + exnref; legacy byte-identical. |
| **03** decode ext | `frontend/wasm/decode.gleam`, `frontend/wasm/ast.gleam` (extend) | The EH proposal: the tag section, `throw`/`try_table`/`throw_ref` opcodes + the catch-clause encoding; publishes the AST delta for 04/05. |
| **04** validate ext | `frontend/wasm/validate.gleam` (extend) | EH typing: tag operand types, `throw` operand match, `try_table` result + catch-clause label/tag typing, `exnref`. Fail-closed. |
| **05** lower ext | `frontend/wasm/lower.gleam` (extend) | WASM EH AST → IR EH nodes; the catch-clause → label mapping. |
| **06** emit_core ext | `backend/emit_core.gleam` (extend) | EH IR → Core Erlang `try…catch`/`throw`/`raise`; the tag term shape (binding chokepoint); constant-space preserved; extend the D3a test. |
| **07** rt_exn | `runtime/rt_exn.gleam` (+ `runtime/rt_trap.gleam` extend) | The tagged-exception runtime: throw a tagged term, match a tag in a catch, re-raise, `catch_all`, the `exnref` handle (forge-proof, reuse `rt_ref`). |
| **08** Porffor shim | `runtime/rt_host.gleam` (extend: the Porffor-ABI registry) + the `(f64,i32)` value-ABI in the run-ABI/`pipeline.gleam`/`profiles.gleam` | Build-fixed Porffor intrinsics (D3a); the typed-value ABI; a `profiles.porffor()`/`js` posture; fail-closed on an unprovided intrinsic. |
| **09** JS-subset conformance | `test/twocore/js/**` (new) + a Porffor-driver | Compile a JS corpus with Porffor, run through 2core on the BEAM, judge differentially vs `porf run`/Node; measured coverage. |
| **10** capstone | `test/**`, `docs/` | JS on the BEAM proven end-to-end; EH green under the matrix; measured JS coverage; SVG/docs; honest close. |

---

## 5. How to claim & complete (same as Phases 1–6)

Read this page → `PORFFOR-ABI-FINDINGS.md` → `RECONCILIATION.md` → your unit doc → `state.md`. Build to
the Definition of Done (spec-cited tests — the [WebAssembly EH proposal](https://github.com/WebAssembly/exception-handling)
for the engine, Porffor's real output + `porf run`/Node for the JS harness; doc comments; `gleam
format --check src test` clean; **zero warnings**; your suite passing — "done" = the suite passes).
Update `state.md`. The manager QA-gates + commits+pushes each unit to `main`.

---

## 6. Deferred to Phase 8+ (explicit)

GC-proposal reftypes (Porffor doesn't need them); a **native** JS frontend (Porffor is the JS
frontend); the Erlang/Gleam frontend; stack-switching / the component model; the single-`.beam` B1
binding; tier-N numerics/SIMD + a production C NIF; the memory optimizer (its own perf phase); WASI as
an `rt_host` impl; a broader-than-Porffor JS surface (needs a native frontend). **WASI** stays out of
core.
