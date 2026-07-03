# Unit P7-10 — Capstone: PHASE 7 PROVEN (JS on the BEAM via Porffor)

> **1–3 owners · Wave 2 (last) · depends on the three Phase-7 freezes AND the landed work of
> P7-01…P7-09.** Read [`00-overview.md`](00-overview.md) (decisions J1–J8) and
> [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md) (the **measured** Porffor 0.61.13 output),
> then — the doc whose shape and rigor this one MATCHES — Phase-6
> [`11-capstone.md`](../phase-6/11-capstone.md) (the full-matrix `driver.pipeline_with` run, the
> `Outcome` normalization, the runs-anywhere proof, the measured skip-drop headline, the
> conformance-neutrality proof, and the honest close you extend). Cite the Phase-6
> [`RECONCILIATION.md`](../phase-6/RECONCILIATION.md) decisions **S8** (`TrapReason` unchanged — EH
> is not a trap; it is BEAM control flow), **S11** (greenness is MEASURED, never promised), **S12**
> (the close names exactly the surface it proved, post-2.0 proposals categorized-deferred), and the
> Phase-5 R16/R17/R18 (measured greenness · the value-list run-ABI · host-constructible values for
> the harness) where they carry Phase-7 weight. Phases 1–6 are complete and green: **1491 tests, 0
> warnings, conformance 46,529 / 1,768 / 0** (Safe ≡ Unsafe, every shipped `state_strategy × mem_tier`)
> — the **complete WebAssembly 2.0 surface**. Phase 7 is the **fourth phase since Phase 2 to grow the
> IR** (`Module.tags` + `Throw`/`TryTable`/`ThrowRef` `Expr` + the `exnref` reference value); it adds
> the one WASM feature Phase 6 left uncovered — **exception handling** — and, on top of it, the
> **Porffor-ABI `rt_host` shim** and the **JS-subset conformance harness**, so the platform reaches
> the goal it was always for: *any Porffor-compilable JavaScript program runs, as compiled preemptive
> BEAM code, on the BEAM.*

---

## Context

Phase 7 makes one claim only a capstone can prove: **a real, Porffor-compiled JavaScript program —
compiled by Porffor to WASM, then decoded / validated / lowered / emitted by 2core to Core Erlang and
loaded onto the BEAM — runs and produces the correct JS result (differentially, against Porffor's own
execution / Node), as compiled preemptive BEAM code; the load-bearing new engine feature is WASM
exception handling lowered to BEAM-native `try`/`catch`/`raise`, it is spec-correct against the
official EH `.wast` suite under both named modes and every shipped `state_strategy × mem_tier`, and
the entire Phase-1..6 WASM corpus + spec suite stay byte-identical (J6 — a module with no tags is
unchanged).** Like the Phase-5/6 capstones (and unlike the Phase-3/4 capstones, which added no IR
nodes), this capstone **adds surface** — the `(tag)`/`throw`/`try_table`/`throw_ref` EH surface — but
its headline is not a conformance-count movement: it is the **goal proof**, *JS on the BEAM*, measured
honestly against Porffor's ~⅓-of-ECMA coverage.

So this capstone owns two things the Phase-6 capstone did not: (1) an **end-to-end goal proof** — a
corpus of real Porffor-compiled JS programs runs through the full pipeline onto the BEAM and matches
`porf run`/Node, with the JS-subset coverage **measured and reported honestly** (bounded by Porffor,
never "full JS"); and (2) the **EH-engine proof** — the official modern EH `.wast` files
(`tag.wast`/`throw.wast`/`try_table.wast`/`throw_ref.wast`, present in the vendored suite) run green,
byte-identical across modes/tiers, backstopped by deliberately-authored in-scope proofs of the four
EH behaviours (an uncaught `throw` propagates; a `try_table`/`try` **catches, binds, and re-raises** a
non-matching exception; `catch_all`; `throw_ref`/`rethrow`; nested unwinding).

Everything fine-grained — the EH IR nodes + the BEAM-exception lowering contract (P7-01); the `.ir`
round-trip of the EH surface (P7-02); the decode of the tag section + the EH opcodes (P7-03); the EH
typing (P7-04); the WASM-EH-AST → IR-EH lowering (P7-05); the `emit_core` Core-Erlang `try`/`catch`
mapping (P7-06); the `rt_exn` tagged-exception runtime (P7-07); the Porffor-ABI `rt_host` shim + the
`(f64,i32)` value ABI (P7-08); and the JS-subset conformance harness's **measured** JS coverage
(P7-09) — is **owned by units 01–09**. This unit does **not** re-derive them; it **confirms** they are
green and committed, then adds the **whole-goal headline checkpoints** only the terminal unit can
make: the deliberately-authored EH backstop under the full mode/tier matrix, the runs-anywhere
re-confirmation for the EH surface, the conformance-neutrality proof, the SVG/docs refresh, and the
honest close — **and it states that the platform has reached its goal (JS on the BEAM) and what Phase
8+ is.** This **closes Phase 7**.

### A load-bearing empirical correction (measured — see §H "Deviations")

`PORFFOR-ABI-FINDINGS.md` states that `try/catch` JS "becomes `try_table`/`catch`." **Measured against
real Porffor 0.61.13, that is wrong: Porffor emits the *legacy* exception-handling encoding, not
`try_table`.** Verified by `wasm-tools dump`/`print` of `porffor wasm` output and by Porffor's own
`compiler/wasmSpec.js` opcode table:

| Construct | Opcode (measured) | Porffor emits it |
|---|---|---|
| tag section | id **13** (`0x0d`) | ✓ `(tag (param f64 i32))` — the JS value as an `(f64,i32)` pair |
| `throw <tag>` | **0x08** | ✓ pervasively (**58–64×** in a trivial typed program — every type-check error path) |
| `try` (block) | **0x06** | ✓ (user `try {…}`) |
| `catch <tag>` | **0x07** | ✓ (user `catch (e) {…}`) |
| `catch_all` | **0x19** | ✓ (finalizer / bare catch) |
| `delegate <label>` | **0x18** | available in Porffor's opcode table |
| `rethrow <label>` | **0x09** | available in Porffor's opcode table |
| `try_table` | 0x1F | **✗ never emitted** — no `try_table`/`throw_ref`/`exnref` anywhere in Porffor's source |

The overview (J1/J2) and this orchestrator target the **modern** proposal (`try_table` 0x1F, catch
clauses `0x00 catch`/`0x01 catch_ref`/`0x02 catch_all`/`0x03 catch_all_ref`, `throw_ref` 0x0A, the
`exnref` heap type). Both encodings share the tag section (id 13) and `throw` (0x08). The resolution
is the *elegant* consequence of J2's insistence that the IR be a **generic, language-neutral
structured-exception model** (not WASM opcodes): **both the modern `try_table` form and the legacy
`try/catch/catch_all/delegate/rethrow` form lower to the *same* neutral IR (`Throw`/`TryTable`/
`ThrowRef`), which lowers to the *same* BEAM-native `try`/`catch`/`raise`.** So the phase targets the
**modern proposal as the standardized EH surface (the official `.wast` suite, J1/J2)** *and* decodes
the **legacy form Porffor actually emits (measured)** — the JS headline would not run otherwise. This
is the #1 cross-unit seam (P7-03 decode, §I / Open questions), and the capstone's two proofs
deliberately exercise both encodings against the one BEAM mapping.

The proof surface is five proofs + one image/docs refresh:

| # | Proof | Decision |
|---|---|---|
| 1 | **EH engine spec-correct end-to-end** — the official modern EH `.wast` (`tag.wast`/`throw.wast`/`try_table.wast`/`throw_ref.wast`, where `wast2json`-able at the pin) run green, PLUS deliberately-authored in-scope proofs: an uncaught `throw` **propagates** out as a BEAM exception; a `try_table`/`try` **catches the matching tag, binds its payload, and re-raises a non-matching exception**; `catch_all` catches any; `throw_ref`/`rethrow` re-raises a caught exception; **nested** try/catch unwinds correctly — byte-identical across **both** modes × **every** shipped `(state_strategy × mem_tier)` | J1/J2/J5/J6 |
| 2 | **JS on the BEAM (THE HEADLINE, MEASURED)** — a corpus of real JS programs (arithmetic, control flow, functions/closures, strings, arrays, objects, `try/catch`, `console.log`) **compiled by Porffor and run through 2core on the BEAM** produces output **matching `porf run` (Porffor's own execution) / Node** — measured differentially, with the JS-subset coverage **reported honestly** (bounded by Porffor; an uncompilable program or an unprovided intrinsic is a categorized skip, never a false green) | J4/J7/J8 |
| 3 | **conformance-neutral** — the whole Phase-1..6 WASM acceptance corpus + spec suite stay **byte-identical** under both profiles and every `(state_strategy × mem_tier)`; a module with **no tags** decodes/validates/lowers/emits exactly as Phase-6 did (a const-folded Porffor program with no error paths is EH-free — measured — and runs on Phase-6 code unchanged) | J6 |
| 4 | **EH green under the tier matrix** — an EH program (a throw across a loop's hot path, caught outside) is byte-identical across `cell/paged`, `threaded/paged`, `cell/atomics`, `threaded/atomics`, `cell/nif`; **constant-space loops + preemption survive a throw**; **fuel/metering still bites across a throw** (J5); a caught `exnref` is opaque; **no ambient authority** (the thrown term is build-controlled — D3a, grep-confirmed) | J5/J6 |
| 5 | **runs-anywhere for the EH surface** — the EH backstop programs compile under `profiles.portable()` with **zero** native primitives, name the `rt_exn` runtime **non-vacuously**, and execute byte-identical to the `cell`/`paged` oracle; an uncaught WASM exception is contained by the instance boundary (one-instance-one-process) and cannot escape to another instance or the node | J5/J7 |
| — | **image + docs refresh** — `docs/js-on-the-beam.svg` (the measured JS-coverage / EH-conformance visual) + `docs/js-on-the-beam.md` (the JS coverage report + the honest close); `docs/wasm-conformance.svg` footnote → the EH `.wast` files lit up, `fail == 0`; the non-EH Phase-1..6 slice unchanged | overview §1 |

---

## Deliverables & freeze milestones

**Consumes** (every Phase-7 freeze + landed unit):

- `«EH-IR-FROZEN»` (P7-01) — `Module.tags: List(TagDecl)` (a tag = a name + a `FuncType`-style operand
  signature, imported/exported like P5 state); the `Throw(tag, args)` / `TryTable(result, body,
  catches)` / `ThrowRef(exnref)` `Expr` nodes (all **effectful barriers**, §effect); the `exnref`
  reference value (a caught-exception handle, opaque like `externref`); the `.ir` grammar delta; and
  **the BEAM-exception lowering contract** — a `(tag)` → a build-controlled BEAM exception term shape
  (`{wasm_exn, TagId, Payload}`), `throw` → an `rt_exn` raise of that term, `try_table`/`try` → a Core
  Erlang `try…catch` matching the tag + re-raising a non-match, `throw_ref`/`rethrow` → re-raise the
  captured term. **Expected: NO new `TrapReason` (S8 — EH is control flow, not a trap; the one EH trap
  is `throw_ref` on a null `exnref`, which reuses an existing trap channel).**
- `«RT-EXN-SIG»` (P7-01) + the landed **`rt_exn`** (P7-07) — the tagged-exception runtime: `throw` a
  tagged term, `match`/rebind a tag in a catch, `catch_all`, re-raise (preserving BEAM
  class+stacktrace so unwinding continues), and the forge-proof `exnref` handle (reuse the `rt_ref`
  model — an opaque `{ref_exn, …}` box).
- `«PORFFOR-ABI»` (P7-01) + the landed **Porffor-ABI `rt_host` shim** (P7-08) — the build-fixed
  registry (literal `case`, no `apply/3`, D3a) implementing Porffor's intrinsic imports (measured:
  `("" "a")`, `("" "b")`, both `(func (param f64))` — the console/print primitives; a wider corpus
  pulls in more, enumerated by P7-08), plus the `(f64,i32)` typed-value ABI in the run-ABI so a
  returned pair decodes into a JS value for judging.
- Units 02–09 (landed) — `.ir` round-trips the EH surface (02); decode reads the tag section (id 13) +
  the EH opcodes for **both** the modern `try_table`/`throw`/`throw_ref` and the legacy `try`/`catch`/
  `catch_all`/`delegate`/`rethrow` forms (03); validate types tag operands / `throw` operand match /
  the `try_table` result + catch-clause label/tag typing / `exnref`, fail-closed (04); lower maps the
  WASM-EH AST → the neutral IR EH nodes for both encodings (05); `emit_core` lowers the EH IR onto Core
  Erlang `try…catch`/`raise`, byte-identical for tag-free modules (06); `rt_exn` implements the runtime
  (07); the Porffor shim + value ABI land (08); and the JS-subset harness compiles a JS corpus with
  Porffor, runs it through 2core on the BEAM, and **measures** JS coverage differentially vs `porf
  run`/Node (09).

**Produces** (terminal — nothing downstream depends on it): the deliberately-authored EH backstop +
the runs-anywhere proof under `test/twocore/conformance/**`; the new `docs/js-on-the-beam.svg` +
`docs/js-on-the-beam.md` (the JS-coverage report + honest close); and the close-of-phase statement in
`state.md` **announcing the goal reached (JS on the BEAM) and Phase 8+ scope**. No publish-day-1 stub —
this unit consumes every freeze and emits nothing others build on.

---

## Files owned

- `test/twocore/conformance/new_surface_test.gleam` *(extend, single-owner — the P5-12/P6-11 file)* —
  the **EH backstop** (proof 1) + the **mode-neutrality** half of proof 3. Add the capstone-authored EH
  programs (`ehthrow`, `ehcatch`, `ehcatchall`, `ehrethrow`, `ehnested`) to the new-surface program
  list; each is driven through `driver.pipeline_with` under the three real shipped profiles
  (`profiles.safe()` / `profiles.unsafe()` / `profiles.portable()`), asserted (1) spec-correct against
  its `.expected` and (2) byte-identical across all three (the MODE axis; the tier axis is proof 4).
  Extend the neutrality test to the Phase-1..**6** corpus (a tag-free module routes away).
- `test/twocore/conformance/eh_conformance_test.gleam` *(NEW, single-owner)* — drives the official
  modern EH `.wast` files (`tag.wast`/`throw.wast`/`try_table.wast`/`throw_ref.wast`) + the
  `legacy/throw.wast`/`legacy/rethrow.wast` files (which validate the encoding Porffor emits) through
  the two-profile run + the shipped tier matrix, asserting `fail == 0` and every skip categorized
  (R16/S11). Analogue of P6-10's `simd_conformance_test.gleam`. *(See §I / Open-question 1: whether an
  EH-conformance sub-unit should own this instead — a one-line reconcile call.)*
- `test/twocore/conformance/tier_matrix_eh_test.gleam` *(NEW, single-owner — proof 4)* — an EH program
  with a throw on a loop's hot path, caught outside, driven across `combos.shipped`; asserts identical
  `Outcome`, constant-space (reuses the Phase-4 `constant_space_threaded` harness), and that fuel is
  charged across the throw (reuses `rt_meter.fuel_consumed/0`).
- `test/twocore/conformance/runs_anywhere_test.gleam` *(extend, single-owner — the P4-11/P5-12/P6-11
  file)* — the EH runs-anywhere checkpoint (proof 5, dynamic + static): the EH backstop programs
  compile under `profiles.portable()` with **zero** native primitives, name the `rt_exn` runtime
  **non-vacuously**, and execute byte-identical to the `cell`/`paged` oracle. Reuses the existing grep +
  execute harness; adds the EH programs to its local list.
- `test/twocore/conformance/corpus/*.wat` (+ `.wasm` / `.expected`) *(add — capstone-authored)* —
  `ehthrow.wat`, `ehcatch.wat`, `ehcatchall.wat`, `ehrethrow.wat`, `ehnested.wat` (each authored to
  exercise one EH behaviour with a **scalar-observable** result so the numeric `.expected` format
  applies — see §B.1).
- `docs/js-on-the-beam.svg` + a small generator note *(new)* — the measured JS-coverage / EH-conformance
  visual (the Phase-7 companion to `docs/wasm-conformance.svg`).
- `docs/js-on-the-beam.md` *(new)* — the honest JS coverage report: the measured JS-subset pass/skip by
  category, the EH `.wast` before/after, the categorized residual, the three honest scope-limits, and
  one line per proof → the test that proves it.
- `docs/wasm-conformance.svg` + `scripts/gen-conformance-svg.sh` footnote *(extend)* — the EH `.wast`
  files light up as new passes (a real, small conformance win); footnote → Phase-7 scope; the non-EH
  Phase-1..6 slice **unchanged** (proof 3).
- `specs/state.md` *(extend)* — the Phase-7 close row + the deferred set + **the goal reached; Phase 8+
  scope**.
- *(confirm, do **not** re-own)* — P7-09's JS-subset harness + its **measured** JS coverage report;
  P7-06's `emit_core` byte-identity + the extended D3a security-invariant test; P7-07's `rt_exn`
  throw/catch/rethrow unit tests + the forge-proof `exnref` test; P7-08's Porffor-shim registry +
  fail-closed-on-unprovided-intrinsic test + the `(f64,i32)` decode test. The capstone asserts they are
  green and committed; it does not re-derive them.

> `ehthrow`/`ehcatch`/`ehcatchall`/`ehrethrow`/`ehnested` `.wat` are fresh — no ownership collision.
> `new_surface_test.gleam` and `runs_anywhere_test.gleam` are single-owner files the capstone already
> owns and extends in place. The whole-JS-corpus **measured** coverage belongs to **P7-09** (the
> analogue of P6-10's whole-suite SIMD run); this unit owns only the deliberately-authored EH backstop,
> the EH `.wast` run, the tier-matrix EH proof, the runs-anywhere property, the docs/SVG, and the close.

---

## Depends on

- `«EH-IR-FROZEN»` / `«RT-EXN-SIG»` / `«PORFFOR-ABI»` (P7-01) — the frozen surface every proof compiles
  against.
- Units 02–09 (landed) — a frontend that decodes/validates/lowers **both** EH encodings into the neutral
  IR, an `emit_core` that lowers it onto Core Erlang `try`/`catch`/`raise`, an `rt_exn` runtime, the
  Porffor-ABI `rt_host` shim + the `(f64,i32)` value ABI, and the JS-subset harness that **measures** JS
  coverage.
- `driver.pipeline_with(binding: Binding) -> Driver` (Phase-3, verified in-tree; unchanged) — the single
  binding-parameterized `decode → validate → lower → ir_to_core(_, binding) → build → instantiate →
  invoke` path. The capstone re-uses it unchanged and only enumerates bindings — it re-implements no
  compiler logic, exactly the discipline of every prior capstone.
- `combos.gleam` (Phase-4, `test/twocore/tier/`) — `shipped` (`cell_paged`/`threaded_paged`/
  `cell_atomics`/`threaded_atomics`/`cell_nif`) · `evaluate` · `identity_across` · `count_occurrences` ·
  `Outcome`. Consumed **read-only** (public, D1); the capstone adds its EH programs to a
  **capstone-local** list, not `combos.corpus_programs` (a P4-09 const — see §H).
- `profiles.gleam` — `safe()` / `unsafe()` / `portable()` (+ a `porffor()`/`js` posture from P7-08, if
  it lands as a named profile — see §I / Open-question 3).
- **The run-ABI's EH observation** (a cross-unit seam, §I) — the driver must normalize an **uncaught**
  WASM exception (a top-level `{wasm_exn, TagId, Payload}`) into a comparable `Outcome`, the way it
  already normalizes a `{wasm_trap, Kind}` into `Trap(reason)` (`combos.Outcome`). The EH `.wast`
  files test this with the reference `(assert_exception …)` action (a caught return is an ordinary
  `assert_return`). The capstone drives its backstop through this ABI; the exact `Outcome`
  variant/spelling is owned by whoever owns the driver's EH path (P7-06/09), flagged so the capstone
  greps a documented shape.

---

## A. The matrix — one binding-parameterized driver, now over the EH surface

Every proof here holds the *program* fixed and varies the *`Binding`*, exactly as Phases 3–6 did.
Phase 3 generalized the conformance driver to `driver.pipeline_with(binding)`; Phase 4 wired
`ir_to_core` to select the `state_strategy` codegen shape + the tier `mem_module`/`table_module`;
Phases 5–6 grew the *IR that flows through that path* (reftypes/bulk/multi-mem; `TV128`/SIMD/mem64/
cross-module) without touching the path. Phase 7 grows it again (`Module.tags` + `Throw`/`TryTable`/
`ThrowRef` + `exnref`) but **not the path itself**. So the capstone re-uses `driver.pipeline_with`
unchanged and only enumerates the axis bindings.

The **shipped matrix** (from `combos.shipped`, unchanged):

```gleam
combos.cell_paged        // Cell × Paged     — the oracle
combos.threaded_paged    // Threaded × Paged — == the portable core (runs-anywhere)
combos.cell_atomics      // Cell × Atomics   — tier-O O(1) memory, pdict convention
combos.threaded_atomics  // Threaded × Atomics — record-threaded O(1) memory
combos.cell_nif          // Cell × Nif       — the tier-N skeleton (Unsafe-only)
```

Each run reduces to the Phase-3 normalized `Outcome` per `(export, args)` — raw bit pattern (D5); a
trap collapsed to the spec phrase via `rt_trap.spec_trap_message`; `Rejected` for a fail-closed
non-build — so two bindings are compared by a single `==` over spec-observable behaviour, **never**
over `.core` text or IR shape (which the strategy/tier is *allowed* to change). Phase-7's new
observable surface is captured by this `Outcome` with **one addition** (owned by the driver/harness
seam, §I): an **uncaught WASM exception** crosses the run-ABI as its build-controlled term
(`{wasm_exn, TagId, Payload}`) and is normalized to a distinguished `Outcome` (the reference
`assert_exception` case). So:

- **A caught exception is invisible to the axis by construction.** A `try_table`/`try` that catches,
  binds, and yields values is observed only through the values it returns — already an `Outcome`. The
  EH is BEAM-native control flow: it neither reads nor writes instance state, so it is **tier-invariant**
  by construction (an exception unwinds the process's native stack, not the `state_strategy` record/cell
  or the `mem_tier` memory). This is why proof 4 expects **byte-identity across every combo**, like the
  pure-numeric files — not a per-tier caveat.
- **An uncaught exception is observed as the `{wasm_exn, TagId, Payload}` outcome**, decoded to its
  tag + payload bits for comparison — the same authority the harness already applies to a trap term.
- **The tag identity + payload are build-controlled (D3a).** `TagId` is a build-assigned per-module
  identity; `Payload` is the tag's operand value list (for Porffor: `[f64_bits, type_tag]`, raw bits —
  D5). No program data selects a module/function to apply — the term is a *value*, never an ambient
  authority (the whole point of J5, grep-verified in proof 4).

So the same `==`-over-`Outcome` comparison that proved Phases 2–6 correct proves Phase 7 correct — EH
added one observable (an uncaught-exception term), not a new *kind* of observation.

---

## B. Proof 1 — EH engine spec-correct end-to-end (the keystone)

**The bar.** A WASM module with a `(tag)`, `throw`, and `try_table`/`try`-`catch` executes
**spec-correctly** through `load → instantiate → invoke`, under **both** `profiles.safe()`/`unsafe()`,
byte-identical across the shipped combos, and matches the official EH `.wast` suite. EH is the keystone
of Phase 7 (J1); the capstone proves it two ways, coarse and fine — the official `.wast` run
(`eh_conformance_test`, this unit) and a deliberately-authored backstop (`new_surface_test`, this unit).

### B.0 The EH surface & why the neutral IR + BEAM mapping is the whole game

Per the WebAssembly exception-handling proposal
([`WebAssembly/exception-handling`](https://github.com/WebAssembly/exception-handling), integrated into
the core spec §2.5.9 tags / §4.4 control instructions), the surface the phase targets is:

- **The tag section** (id **13**, `0x0d`) declares exception **tags**, each a `FuncType`-style operand
  signature (spec §2.5.9). Encoding: an attribute byte (`0x00` = exception) + a `typeidx`. Measured:
  Porffor emits exactly one `(tag (param f64 i32))` — the exception type carrying the thrown JS value as
  an `(f64, i32)` pair — and exports it (tag externkind **4**).
- **`throw x`** (`0x08`, `x`:tagidx) pops the tag's operand values, creates an exception carrying them +
  the tag, and throws it. It does not return — bottom (like `Return`/`Trap`). Spec §4.4.
- **`try_table bt catch* … end`** (`0x1F`, **modern**) executes its body; on a propagating exception it
  matches the catch clauses **in order** — `0x00 catch tag label` (matching tag → branch to `label` with
  the tag's values), `0x01 catch_ref tag label` (+ push an `exnref`), `0x02 catch_all label` (any
  exception → branch, no values), `0x03 catch_all_ref label` (any → branch + push an `exnref`); **no
  matching clause ⇒ the exception keeps propagating** (spec §4.4.9 unwinding).
- **`throw_ref`** (`0x0A`) pops an `exnref`; a null `exnref` **traps**; otherwise it re-throws the
  referenced exception.
- **`exnref`** is a nullable reference to a caught exception (a heap type in the reference-types/GC
  unification).
- **The legacy form Porffor emits** (measured — §Context) is the semantically-equivalent
  `try bt … catch <tag> … catch_all … end` (`try` `0x06` / `catch` `0x07` / `catch_all` `0x19`), with
  `delegate` `0x18` (re-raise to an outer label) and `rethrow <label>` `0x09` (re-raise the exception
  caught by the addressed enclosing catch). Validated by the vendored `legacy/throw.wast` +
  `legacy/rethrow.wast`.

**The load-bearing idea (J1) is that all of this lowers to BEAM-native exceptions** — the same
compile-to-Erlang elegance as tail calls → BEAM tail calls and preemption → the scheduler. The keystone
(P7-01) freezes the mapping; the capstone's proofs *certify* it:

| WASM EH | Neutral IR (J2) | Core Erlang / `rt_exn` (P7-06/07) |
|---|---|---|
| `(tag t)` | `TagDecl(name, sig)` in `Module.tags` | a build-controlled term shape `{wasm_exn, TagId, Payload}` (`TagId` build-assigned; `Payload` = the operand value list) |
| `throw t (vals…)` | `Throw(tag, args)` | `rt_exn:throw` → `erlang:error({wasm_exn, TagId, Vals})` (error-class, catchable, node-safe — the `rt_trap` channel discipline); never returns (bottom) |
| `try_table`/`try … catch t → L` | `TryTable(result, body, [Catch(tag, L, ref?)])` | Core Erlang `try Body of … catch error:{wasm_exn, TagId, P} -> bind P to L's values …` |
| `catch_all → L` | `Catch(catch_all, L, ref?)` | `catch error:{wasm_exn, _, _} -> branch to L` |
| *no matching clause* | (propagation) | `catch Class:Reason:Stk -> erlang:raise(Class, Reason, Stk)` — **re-raise, preserving class+stacktrace** so unwinding continues (spec §4.4.9) |
| `throw_ref e` / `rethrow` | `ThrowRef(exnref)` | re-raise the captured term (from the opaque `exnref` handle) |
| `exnref` | a new reference value | an opaque `{ref_exn, ExnTerm}` box (reuse `rt_ref`'s forge-proof model — J5 / scoping-q (b)) |

The capstone's backstop kernels are authored so a single mis-lowered arm — a `throw` that returns
instead of diverging, a `try_table` that fails to re-raise a non-matching tag (a **fail-open** unwinding
bug), a `catch` that binds the wrong payload, a lost `exnref`, or a nested handler that catches the
wrong level — fails on a **named program** rather than diffusely in the `.wast` suite.

### B.1 The deliberately-authored EH backstop (owned)

Each kernel exercises one EH behaviour and exports a **scalar** (an `i32`) so it rides the exact
byte-identical numeric `Outcome` used since Phase 2 (`combos.evaluate` → `identity_across`) — the
strongest, simplest failure signal (a plain `Int`/outcome mismatch on a named program). Each is run under
both profiles × `portable` and asserted (1) spec-correct against its `.expected`, and (2) byte-identical
across all three:

| Program | Exercises | Spec anchor | Result observed |
|---|---|---|---|
| `ehthrow` | a `(tag)` + an unconditional `throw` reaching the top of the invoke — **propagation** | §2.5.9 tag, §4.4 `throw`, §4.4.9 (uncaught → embedder) | the **uncaught-exception `Outcome`** (`{wasm_exn, TagId, Payload}`), payload decoded |
| `ehcatch` | `throw` inside a `try_table`/`try` with a `catch <tag> → L` that **binds the payload** and returns it; a sibling path that does **not** throw returns a distinct value (the two-way discrimination) | `try_table` §4.4 catch-clause match + bind; §4.4.9 | i32 scalar (the bound payload vs the no-throw value) |
| `ehcatchall` | `throw` of tag A caught by a `catch_all` (no operand binding); AND a **non-matching** `catch <tag B>` that lets tag A **propagate** past it to an outer `catch_all` — the **re-raise** path | catch clause ordering; `catch_all` `0x02`/`0x19`; **no-match ⇒ propagate** | i32 scalar (which handler fired) |
| `ehrethrow` | catch an exception, then re-raise it (`throw_ref`/`rethrow`) to an outer handler that observes it — the **`exnref`/re-raise** surface (the modern `.wast` route; Porffor's legacy `rethrow` route separately) | `throw_ref` `0x0A` / `rethrow` `0x09`; the `exnref` heap type | i32 scalar (observed by the outer handler) |
| `ehnested` | two nested `try_table`/`try` blocks; an inner throw of tag B is **not** caught by the inner `catch <tag A>`, propagates to the outer `catch <tag B>` — **nested unwinding to the correct level** | §4.4.9 innermost-matching-handler unwinding | i32 scalar (the level that caught) |

- **The one EH trap is `throw_ref` on a null `exnref`** (spec: a null `exnref` traps). It reuses an
  existing trap channel (no new `TrapReason` — S8). Every other EH construct is control flow, not a
  trap: an uncaught exception is an *exception*, not a `{wasm_trap, _}`, and is observed as the distinct
  uncaught-exception `Outcome`.
- **The re-raise is the load-bearing correctness point (fail-closed unwinding).** A `try_table`/`try`
  that catches an exception whose tag it does **not** match — instead of re-raising it — is a silent
  semantic corruption (the spec §4.4.9 requires propagation). `ehcatchall` and `ehnested` make that a
  red test on a named program; the `emit_core` mapping's `catch Class:Reason:Stk -> raise(Class,
  Reason, Stk)` arm (preserving the stacktrace) is what upholds it, and P7-06 owns the byte-identity
  test that the tag-matching `case` re-raises on the default.
- **The scalar-observable discipline** keeps a cross-mode/cross-tier divergence a plain outcome mismatch;
  the full payload-carrying `(f64,i32)` path is proven by the JS headline (proof 2, where the payload is a
  real thrown JS value) and by the official EH `.wast` (which carry i32/i64 tag operands + `exnref`
  values). The backstop need not re-derive them.

### B.2 The official EH `.wast` suite (owned via `eh_conformance_test`)

The vendored suite (`WebAssembly/testsuite` at the pin) contains the modern EH files —
`tag.wast`, `throw.wast`, `try_table.wast`, `throw_ref.wast` — **and** a `legacy/` subdirectory
(`legacy/throw.wast`, `legacy/rethrow.wast`). The capstone drives them, `wast2json`-verified per file at
the pin (R16/S11 discipline; `wabt` supports `try_table` from ≥ 1.0.34, so the modern files convert; a
genuinely un-convertible file → a **categorized** parse-skip, never a false green), and asserts, over the
two-profile run + the shipped tier matrix:

```gleam
assert eh_total.fail == 0                         // no EH assertion lit up wrong
assert eh_total.pass > 0                           // the EH files DID light up (non-vacuous)
// every residual skip matches one enumerated honest category (the closed-residual invariant, D9/S11)
```

- **`tag.wast`** — tag declaration + import/export matching (link-time; a mismatched tag import fails
  closed → `assert_unlinkable` → `Rejected`).
- **`throw.wast`** / **`legacy/throw.wast`** — `throw` propagation + catch; the legacy file validates the
  encoding Porffor emits (the same neutral IR + BEAM mapping).
- **`try_table.wast`** — the four modern catch clauses (`catch`/`catch_ref`/`catch_all`/`catch_all_ref`),
  binding, and the no-match propagation.
- **`throw_ref.wast`** — `exnref` capture + re-throw; a null `exnref` `throw_ref` **traps**.
- **`legacy/rethrow.wast`** — legacy `rethrow` (re-raise the caught exception at an addressed depth).

`fail == 0` over these is the whole-EH-engine net: a lowering that dropped the re-raise, mis-bound a
payload, mis-ordered catch clauses, or mishandled a null `exnref` would flip an assertion to **fail**,
not pass.

### B.3 Byte-identical across modes/tiers

`ehthrow`/`ehcatch`/`ehcatchall`/`ehrethrow`/`ehnested` run under `profiles.safe()` (Baseline optimizer +
enforcing fuel), `profiles.unsafe()` (Aggressive optimizer + open runtime), and `profiles.portable()`
(Threaded/Paged/`bif`), and produce the **same `Outcome`** — because WebAssembly EH is deterministic and
the mode/optimizer/tier changes no spec-observable answer (J6). The EH nodes are **effectful barriers**
(§effect / J2), so the optimizer must **not** reorder a `Throw` past an effect, hoist a `MemStore` across
a `TryTable` boundary, or DCE a `try_table` body with an observable throw — an Aggressive-optimizer pass
that did any of these would diverge **here** on the exact program under the exact mode. The tier axis is
proof 4 (a throw across a loop under every `state_strategy × mem_tier`).

---

## C. Proof 2 — JS on the BEAM (THE HEADLINE, MEASURED)

**The bar (J4/J7/J8, the goal).** A corpus of real JS programs, **compiled by Porffor** (`porf wasm`)
and run through the full 2core pipeline onto the BEAM, produces output **matching Porffor's own
execution** (`porf run`) / Node — measured differentially, with the JS-subset coverage reported
**honestly**. This is the phase's reason to exist; the capstone **confirms** P7-09's measured coverage
(the whole-corpus number — the analogue of P6-10's SIMD roll-up) and owns the **honest close** that
states exactly what runs.

### C.1 The pipeline (measured, end-to-end)

```
foo.js  ──porf wasm──▶  foo.wasm  ──2core fe_wasm──▶  IR  ──emit_core──▶  Core Erlang  ──BEAM──▶  output
                                     (decode/validate/lower/emit,        (compiled,
                                      incl. EH — J1)                       preemptive)
```

Measured facts the harness relies on (verified against Porffor 0.61.13, `wasm-tools`):

- **The value ABI is `(f64, i32)`** — the `f64` is the value (a JS number directly; for objects/strings/
  arrays, an i32 pointer into linear memory carried in the f64), the `i32` a **type tag**. A JS `main`
  compiles to a WASM function `(func (result f64 i32))` (multi-value out); a JS function `(a,b)=>…` to
  `(param f64 i32 f64 i32) (result f64 i32)`. The run-ABI (R17 value-list) already carries multi-value,
  so a returned `(f64, i32)` is a two-element value list; P7-08's decoder reads `(f64_bits, type_tag)`
  into a JS value for judging (D5 — raw bits, no double round-trip).
- **The intrinsic imports** are a tiny treeshaken set from module `""` — measured: `("" "a")` and
  `("" "b")`, both `(func (param f64))`, Porffor's console/print primitives. P7-08's build-fixed
  `rt_host` Porffor registry provides them (literal `case`, no `apply/3` — D3a); `console.log` output is
  **captured** for judging. An unprovided intrinsic **fails closed** (a categorized link-time error).
- **The entry point** is the exported `main` (measured export name `"m"`; the memory is exported `"$"`;
  a present tag is exported `"0"`). The harness invokes it and observes both the captured `console.log`
  stream and the decoded `(f64,i32)` return.
- **EH density varies (measured — important for honesty + proof 3):** a fully const-folded trivial
  program (`console.log(2+3)`) compiles to **no tag section, zero throws** — it is EH-free and runs on
  Phase-6 code unchanged. A program with a runtime type check (`function f(a,b){return a+b;}`) emits a
  tag section + **58 throws** (the type-check error paths) but **no** `try`/`catch` unless the user wrote
  one. A user `try/catch` emits the legacy `try`/`catch`/`end`. So Porffor throws **pervasively** but
  catches only where the source does — exactly the surface J1 targets.

### C.2 The differential oracle — `porf run` first, Node cross-check (the honesty spine)

The judgement is **differential against Porffor's own execution** (`porf run` — Porffor JITing the same
WASM), cross-checked against Node where they agree. This is the correct oracle because *JS on the BEAM
via Porffor* means **faithfully reproducing what Porffor computes**, not idealized ECMA-262. Measured
illustration (verified): the `try/catch` probe `trycatch.js` prints `10` then `-1` under **both** `porf
run` **and** `node` — they agree, so the expected output is `10\n-1` and 2core must reproduce it
byte-for-byte. Where `porf run` and Node **disagree** (a Porffor bound), the primary oracle is `porf
run` (what 2core faithfully re-runs) and the divergence is a **categorized honest note**, never a 2core
"bug" and never a false green. A program Porffor cannot compile, or that needs an unprovided intrinsic,
is a **categorized skip** (J4/J8) — the same "differential against a reference, measured, categorized"
discipline as the WASM spec suite (R16/S11).

### C.3 The corpus (grows trivial → real; coverage MEASURED, never promised)

P7-09 owns the corpus + the measured number; the capstone **confirms** it and records it honestly. The
corpus grows across the JS features Porffor supports:

| Tier | JS exercised | EH surface hit |
|---|---|---|
| **arithmetic / `console.log`** | `2+3`, number formatting, `console.log` | often EH-free (const-folded) — proof 3 |
| **control flow** | `if`/`for`/`while`, comparisons, `&&`/`||` | type-check `throw`s (uncaught, never reached) |
| **functions / closures** | declarations, arrows, first-class fns (`call_indirect`), recursion | pervasive `throw`s |
| **strings / arrays / objects** | indexing, `.length`, `.push`, property access, iteration | `throw`s + bounds/type paths |
| **`try/catch`** | user `try { … } catch (e) { … }`, `throw new Error(…)`, finally | the legacy `try`/`catch`/`catch_all` — the headline EH path |

The measured claim is exactly *"these N programs, run through 2core on the BEAM, match `porf run`"* —
with the skips categorized (uncompilable-by-Porffor / unprovided-intrinsic / a `porf`≠Node divergence
noted). **Bounded by Porffor's ~⅓-of-ECMA coverage (§8.2) — we claim what runs, never "full JS".**

---

## D. Proof 3 — conformance-neutral (the whole Phase-1..6 corpus + spec suite byte-identical, J6)

**The bar (J6).** A module with **no tags** compiles **byte-identically** to Phase-6. The IR grew
(`Module.tags` + `Throw`/`TryTable`/`ThrowRef` + `exnref`), but the *defaults* route the new surface
away: `tags = []`; no `Throw`/`TryTable`/`ThrowRef` node is emitted; no `exnref` value flows. So the
entire Phase-1..6 acceptance corpus and every previously-passing allowlist assertion must produce the
*same* `Outcome` under Phase-7 code as before, and the whole non-EH WASM spec suite stays at its
Phase-6 counts (46,529 / 1,768 / 0). Two assertions carry it, and the point is that they did **not
move**:

- **The mode-axis corpus neutrality (owned here).** `new_surface_test.gleam`'s
  `phase_1_to_6_corpus_conformance_neutral_test` (extended from the Phase-6 Phase-1..5 version) re-runs
  `combos.corpus_programs` **and** the Phase-5/6 new-surface programs (`reftab`/`bulkmem`/`multimem`/
  `simddot`/`simdxform`/`mem64`/`xlink`) under Safe and Unsafe Phase-7 code, asserting the **same
  `Outcome`** under both and each matching its `.expected`. A Phase-7 change that perturbed a Phase-6
  result — a `TryTable` arm leaking into a control-flow match, an effect-analysis miss letting the
  optimizer reorder a state op now that an EH barrier joined the set, an `emit_core` `try` wrapper
  emitted around a tag-free body — would diverge **here**.
- **The prior spec-suite counts are unchanged where the category is unchanged (confirmed).** The
  Phase-1..6 files stay at their Phase-6 pass counts under both profiles and every combo; the EH
  `.wast` files (`tag`/`throw`/`try_table`/`throw_ref` + `legacy/*`) are the **only** new passes. The
  strongest form is **byte-level, at the emitter**: for a tag-free module the Phase-7 `emit_core` output
  is **textually identical** to Phase-6's — **P7-06 owns that emitter-level byte-identity test** (the
  default-neutrality assertion); the capstone **confirms** it is green and adds the whole-suite
  behavioural neutrality above. (The capstone does not re-own an `emit_core` test — D1.)

Measured neutrality nuance (§C.1): a const-folded Porffor program (`console.log(2+3)`) is **already
tag-free** and runs on Phase-6 code unchanged — a concrete witness that "no tags ⇒ byte-identical" is
not merely a spec corpus property but holds for real JS output.

---

## E. Proof 4 — EH green under the tier matrix (constant-space + preemption + fuel across a throw)

**The bar (J5/J6).** EH is BEAM-native control flow; it neither reads nor writes instance state, so it
must be **byte-identical across every shipped `state_strategy × mem_tier`** and must not break the two
properties the whole platform rests on. `tier_matrix_eh_test.gleam` drives an EH program authored to
put a throw on a loop's hot path (a loop that, on iteration K, throws a tag caught by a handler outside
the loop, then returns a scalar reduction) across `combos.shipped` and asserts:

- **Byte-identical `Outcome` across all five combos** (`cell/paged`, `threaded/paged`, `cell/atomics`,
  `threaded/atomics`, `cell/nif`). EH is tier-invariant by construction — a throw unwinds the process's
  native BEAM stack, not the `state_strategy` record/cell or the `mem_tier` memory. A divergence would
  mean the lowering entangled EH with instance state (a bug).
- **Constant-space loops + preemption survive a throw (J5/J7).** The loop body is emitted as a
  constant-space Core Erlang tail-recursive `letrec` (Phase-3), and the enclosing `try` does **not**
  grow the stack per iteration; the throw unwinds natively (constant space, no reified stack). Reuses
  the Phase-4 `constant_space_threaded` harness to assert the process heap/stack stays bounded across the
  throwing loop. The scheduler still preempts at reduction boundaries (the throw does not monopolise a
  scheduler).
- **Fuel/metering still bites across a throw (J5).** Each op on the path is `Charge`d (D9) before the
  throw; a `safe_metered` binding with a budget below the loop's cost still runs out of fuel and raises
  `FuelExhausted` *before* the throw completes — the metering is not bypassed by unwinding. Reuses
  `rt_meter.fuel_consumed/0` to assert fuel was consumed up to the throw point.
- **No ambient authority survives a throw (D3a, grep-confirmed).** The thrown term is the
  build-controlled `{wasm_exn, TagId, Payload}` — the generated `.core` contains no `apply(` of a
  data-derived `module:atom` on the EH path; `Throw` emits a fixed `twocore@runtime@rt_exn:throw` module
  atom with a build-assigned `TagId`, and the re-raise is `erlang:raise` of a *captured* term, never a
  program-chosen apply. A caught `exnref` is **opaque** (an `{ref_exn, …}` box — J5): Safe code can
  hold/re-throw it but cannot forge or inspect the underlying BEAM term. The capstone confirms P7-06's
  extended D3a security-invariant test (EH arms) is green and proof 5's grep is the structural
  cross-check.

**The containment property (J5).** An **uncaught** WASM exception becomes a BEAM exception that the
instance boundary **contains** (one-instance-one-process, E1): it propagates to the top of *this
instance's* invoke and no further — it cannot escape to another instance or crash the node. A Safe
instance is node-safe under a throw exactly as it is under a trap (tier-P: `erlang:error`/`raise`
raise, they do not crash the VM — the `rt_trap`/`rt_exn` channel discipline).

---

## F. Proof 5 — runs-anywhere for the EH surface (J5/J7)

Phase 4 proved the tier-P `portable` build (`Threaded` state + `Paged` memory + `bif` numerics, Safe)
runs the corpus on a bare BEAM; Phases 5–6 re-confirmed it for reftypes/bulk/multi-mem and
SIMD/memory64. Phase 7 grew the surface again, so the property must be **re-confirmed for the EH
nodes**: the EH backstop programs must *also* run under `portable` with no native code.
`runs_anywhere_test.gleam` extends its existing harness (unchanged shape) with the EH programs
`["ehthrow", "ehcatch", "ehcatchall", "ehrethrow", "ehnested"]`:

**(a) Grep-verified (static).** The `profiles.portable()` `.core` of each EH program links **zero**
native primitives, while **non-vacuously** naming the runtime the EH nodes route through:

```gleam
for name in ["ehthrow", "ehcatch", "ehcatchall", "ehrethrow", "ehnested"] {
  let core = portable_core(name)
  assert count(core, "atomics") == 0 && count(core, "ets") == 0
  assert count(core, "persistent_term") == 0 && count(core, "load_nif") == 0
}
// Non-vacuity: the EH nodes DO route through the pure-BEAM rt_exn runtime + native try/catch:
assert count(portable_core("ehthrow"),    "rt_exn") > 0    // throw → rt_exn raise
assert count(portable_core("ehcatch"),    "'try'")  > 0    // catch → Core Erlang try
assert count(portable_core("ehrethrow"),  "rt_exn") > 0    // rethrow/throw_ref → rt_exn re-raise
```

> **Seam note (P7-06/07 naming).** `rt_exn` (the module name) is the stable non-vacuity token for the
> EH runtime; the exact function atoms (`throw`/`match`/`reraise`/the `exnref` box) are **owned by
> P7-07**, and whether `emit_core` emits a literal Core Erlang `try`/`catch`/`raise` or routes the
> match through an `rt_exn` helper is **P7-06's** lowering decision. The capstone greps for whatever
> names those units froze — the tokens above follow the frozen set, flagged in Open questions so the
> reconcile keeps them in sync (exactly the Phase-6 §F.2 seam note).

**(b) Executed (dynamic).** The EH corpus runs under `profiles.portable()` through `load → instantiate →
invoke` on a bare BEAM, **byte-identical** to the `cell`/`paged` oracle (`profiles.safe()`) — caught
values, uncaught exceptions, and traps alike. This re-confirms that the EH lowering (a throw → `rt_exn`
raise; a catch → a native Core Erlang `try`) executes on a bare BEAM without a native backend.

**The security posture (J5/J7).** Because no native code is linked, the worst case of an EH-lowering bug
under `portable` is a **wrong-catch / lost-payload / a node-safe process exception — never a host
escape**. An uncaught exception is contained by the instance boundary; a caught `exnref` is opaque;
fuel still bites (§E). This is the same "runs on a bare BEAM, provably unable to take over the VM"
property (spec §7 *Embedding*), now covering the EH surface — and, transitively, **the JS surface**,
since Porffor's output is *this* WASM surface.

---

## G. Conformance/docs refresh + the honest close (the goal reached; Phase 8+ scope)

**Image refresh.** `docs/wasm-conformance.svg` (`RUN_VENDOR=1 scripts/gen-conformance-svg.sh`) picks up
the EH `.wast` files as new passes automatically (the generator reads the `TOTAL` line from the same
conformance test). The movement is **small** (the four modern EH files + `legacy/*` — a few hundred
assertions, not the SIMD ~+25k) and, crucially, the non-EH Phase-1..6 slice is **unchanged** (proof 3).
Update the footnote from the Phase-6 text to **"Phase 7: WebAssembly exception handling (tags, `throw`,
`try_table`/`try`-`catch`/`catch_all`, `throw_ref`/`rethrow`, `exnref`) lowered to BEAM-native
`try`/`catch`/`raise`; `fail == 0`. This is the engine feature that unlocks *JS on the BEAM via
Porffor* — a real Porffor-compiled JS corpus runs on the BEAM matching `porf run`/Node (measured,
bounded by Porffor's ~⅓ ECMA coverage). Residual out of scope: GC, stack-switching, the component
model, WASI/DOM, a native JS frontend."**

**The Phase-7 deliverable image + doc (`docs/js-on-the-beam.svg` + `docs/js-on-the-beam.md`).** The
Phase-7 headline is *JS on the BEAM*, so its primary artifact is a JS-coverage visual + report
(companion to the WASM conformance image), honest and measured (R16/S11):

- **`docs/js-on-the-beam.svg`** — the measured JS-subset coverage (pass/skip per corpus category) + the
  EH `.wast` before/after, self-contained inline-styled SVG (README-renderable, no external
  fonts/links).
- **`docs/js-on-the-beam.md`** — the JS coverage report: the measured JS-subset pass/skip by category,
  the EH `.wast` counts (`fail == 0`), the categorized residual (uncompilable-by-Porffor / unprovided-
  intrinsic / `porf`≠Node divergences noted), the three honest scope-limits, and one line per proof →
  the test that proves it.

**The honest close of Phase 7 (committed in `state.md`):**

- **Proved:** the platform reaches its goal — **JS on the BEAM via Porffor**. A real, Porffor-compiled
  JavaScript program runs through 2core (Porffor JS→WASM → `fe_wasm` → IR → Core Erlang → BEAM) and
  produces output matching Porffor's own execution / Node, as **compiled, preemptive BEAM code**
  (constant-space loops + scheduler preemption preserved, J7). The load-bearing new engine feature is
  **WebAssembly exception handling** (tags, `throw`, `try_table`/`try`-`catch`/`catch_all`,
  `throw_ref`/`rethrow`, `exnref`) lowered to **BEAM-native `try`/`catch`/`raise`** — a `(tag)` is a
  build-controlled BEAM exception term, `throw` raises it, a `try_table`/`try` catches the matching tag,
  binds its payload, and re-raises a non-match (spec §4.4.9), `throw_ref`/`rethrow` re-raises a caught
  `exnref` — spec-correct against the official EH `.wast` suite under **both modes** and **every shipped
  `state_strategy × mem_tier`**, **conformance-neutral by default** (J6 — a tag-free module is
  byte-identical to Phase-6), and **runs-anywhere** for the EH surface.
- **The three honest scope-limits (J8 — stated in the close, not hidden):**
  1. **Bounded by Porffor's JS coverage — measured, never "full JS" (J8).** Porffor is an experimental
     research compiler supporting on the order of **⅓ of ECMA-262** (§8.2). What reaches the BEAM is
     *the JS Porffor can compile*; the JS-subset harness **measures** what runs and we claim exactly
     that. A program Porffor cannot compile, or that needs an unprovided intrinsic, is a **categorized
     skip**, never a false green. Where `porf run` diverges from Node (a Porffor bound), the differential
     is against `porf run` (what 2core faithfully re-runs) and the divergence is a categorized note.
  2. **EH is BEAM-native and faithful — not emulated (J1).** The BEAM's `try`/`catch`/`raise` *is* the
     target: no interpreter, no reified stack, native constant-space unwinding, preemption + fuel
     preserved across a throw. We implement the standardized surface Porffor uses (and the modern
     `try_table` form of the official suite); the rarely-used corners Porffor never emits are scoped by
     what the EH `.wast` + Porffor's output exercise (measured, categorized). **Measured caveat
     (honest):** Porffor 0.61.13 emits the **legacy** EH encoding (`try`/`catch`/`catch_all`), not
     `try_table`; the frontend decodes **both** the modern and legacy forms into the one neutral IR +
     BEAM mapping, so the official `.wast` suite (modern) and real Porffor output (legacy) both run.
  3. **No WASI, no browser DOM (J8).** The host shim is **Porffor's runtime ABI** (its console/memory/
     string/intrinsic imports — `("" "a")`/`("" "b")` + whatever a wider corpus pulls in), a
     **build-fixed** `rt_host` registry (literal `case`, no `apply/3` — D3a), **not** WASI and **not** a
     DOM. Programs that need host APIs Porffor stubs/omits are a categorized gap. An unprovided intrinsic
     **fails closed**.
- **The goal is reached; Phase 8+ is the next frontier (explicit).** With JS on the BEAM proven, the
  deferred work becomes the *next phase*, not a gap in *this* one:
  - **A native JS frontend** — Porffor IS the JS frontend today; a native ECMA-262 frontend (broader than
    Porffor's ⅓ coverage, tracking a spec version) is the largest Phase-8 candidate, and it reuses the
    **generic structured-exception IR** this phase built (J2 — `Throw`/`TryTable`/`ThrowRef` are not
    WASM-isms; a native JS `throw`/`try`/`finally` lowers straight onto them).
  - **A broader-than-Porffor JS surface** — needs the native frontend (or a newer Porffor).
  - **GC-proposal reftypes** (`struct`/`array`/`i31`/typed refs) — Porffor doesn't need them (confirmed
    empty); deferred until a frontend does.
  - **The Erlang/Gleam frontend** (another language onto the same IR + EH model), **stack-switching /
    the component model**, the **single-`.beam` B1 binding**, **tier-N numerics/SIMD + a production C
    NIF**, the **memory optimizer** (its own performance phase), and the **tail-call proposal**
    (`return_call*`, deferred since Phase-6 S12 — maps cleanly onto BEAM native tail calls, a plausible
    fast-follow). **WASI** stays an `rt_host` implementation, out of core.

---

## Effect / soundness / security note

- **No ambient authority survives the EH surface (D3a/J5).** A thrown exception is a **term**, never
  authority: the tag term shape is build-controlled (`{wasm_exn, TagId, Payload}`, `TagId`
  build-assigned, `Payload` the operand value list). `Throw` emits a fixed `twocore@runtime@rt_exn:throw`
  module atom; the catch is a literal Core Erlang `try`/`case` on the tag; the re-raise is
  `erlang:raise` of a **captured** term. **Nowhere** does the EH path `apply` a data-derived
  `module:atom`. A caught `exnref` is an **opaque** `{ref_exn, ExnTerm}` box (reusing `rt_ref`'s
  forge-proof model — Safe code holds/re-throws but cannot forge/inspect the BEAM term). Unit 06 extends
  the D3a security-invariant test to the EH nodes; proof 5's grep is the structural cross-check (no
  `apply(` of a runtime-named atom).
- **The Porffor shim is build-fixed; an unprovided intrinsic fails closed (J3/J5).** The Porffor-ABI
  `rt_host` registry is a literal `case` (like `spectest`/`resolve_handler`) — no `apply/3`. An intrinsic
  the shim does not implement is **denied** (a categorized link-time / fail-closed error, never a silent
  stub that corrupts JS semantics). The Safe capability model is unchanged: the shim's IO intrinsics are
  explicit, auditable host functions gated by the instance's `HostPolicy`.
- **EH does not weaken the sandbox (J5).** An uncaught WASM exception becomes a BEAM exception the
  instance boundary contains (one-instance-one-process); it cannot escape to another instance or the
  node. Metering/fuel still bites across a throw (§E). The one EH trap — `throw_ref` on a null `exnref` —
  reuses an existing trap channel; **no new `TrapReason`** (S8).
- **Floats-as-bits (D5) unchanged.** A thrown JS value's `(f64, i32)` payload is carried as raw bits (the
  f64 bit pattern + the i32 type tag), never a BEAM-double round-trip; the value ABI is a
  *frontend/host* concern (Porffor's convention), kept **out of the IR** (J6 — the IR's exception model
  is generic; the `(f64,i32)` shape lives in P7-08's run-ABI, not an IR node).
- **Fail-closed default (D4).** Every run that does not name a tier-P/N posture or an Unsafe mode is
  `cell`/`paged`/Safe; the EH surface adds observables, not a new default posture. **Safe forbids
  tier-N** as before.

---

## H. Deviations from the overview / ABI findings (argued)

Each deviation is argued so reconciliation can adjudicate before code.

1. **The measured EH encoding is LEGACY, not `try_table` (the load-bearing correction — §Context).**
   `PORFFOR-ABI-FINDINGS.md` and the overview J1/J2 say Porffor's `try/catch` "becomes `try_table`/
   `catch`." **Measured (Porffor 0.61.13, `wasm-tools` + Porffor's `wasmSpec.js`): Porffor emits the
   legacy `try`(0x06)/`catch`(0x07)/`catch_all`(0x19)/`throw`(0x08) form and NEVER `try_table`(0x1F)/
   `throw_ref`(0x0A)/`exnref`.** **Argument:** J2's neutral-IR discipline turns this from a blocker into
   a non-issue — both encodings lower to the same `Throw`/`TryTable`/`ThrowRef` IR and the same BEAM
   mapping — but it forces a scope call on **decode (P7-03)**: to run the official `.wast` suite (modern)
   **and** real Porffor output (legacy), P7-03 must decode **both**. The capstone's proofs therefore
   exercise both (the modern `.wast` in §B.2, Porffor's legacy output in §C), and the reconcile must pin
   P7-03's dual-encoding scope. This is the #1 cross-unit seam (Open-question 1). The capstone claims
   the **modern proposal** as the standardized EH surface (per J1/J2 + the official suite) and the
   **legacy form** as the measured Porffor input — honest either way.

2. **The capstone's EH backstop kernels export SCALARS (an i32), not the `(f64,i32)` payload.** The
   headline (proof 2) carries the full `(f64,i32)` payload (a real thrown JS value). The backstop's
   `eh*` kernels deliberately export a **scalar** so they ride the exact byte-identical numeric `Outcome`
   used since Phase 2. **Argument:** a scalar result makes a cross-mode/cross-tier divergence a plain
   outcome mismatch on a named program (the strongest failure signal), while the JS headline + the EH
   `.wast` carry the payload-bearing path. A test-authoring choice, not an ABI refinement.

3. **The capstone owns the EH `.wast` run (`eh_conformance_test.gleam`), not a separate conformance-
   expansion unit.** Phase 6 had a dedicated P6-10 owning the whole-suite SIMD run; the Phase-7 DAG has
   **no** dedicated EH-conformance unit (P7-09 owns the *JS* corpus, not the EH `.wast` files).
   **Argument:** the EH `.wast` files are new and unowned, and the capstone is the natural home for the
   "engine spec-correct" proof (proof 1); this is *less* ownership overlap than a co-owned whole-suite
   file. **Reconcile should confirm** — or, if it prefers a P7-04.5 "EH conformance" sub-unit, that is a
   one-line ownership move (Open-question 1).

4. **The `Outcome` gains an uncaught-exception case (owned by the driver/harness seam, not the
   capstone).** An uncaught WASM exception needs a normalized `Outcome` (the reference `assert_exception`
   action), the way a trap normalizes to `Trap(reason)`. **Argument:** this is a driver-ABI change
   (P7-06/09 own the driver's EH path), not compiler logic; the capstone consumes a documented shape and
   flags it (Open-question 2). Adding one `Outcome` variant does not change the `==`-over-`Outcome`
   comparison (it adds a case, not a kind).

---

## Verification — Definition of Done (D8)

- **Proof 1 green (EH engine):** `ehthrow`/`ehcatch`/`ehcatchall`/`ehrethrow`/`ehnested` run spec-correct
  against their `.expected` and byte-identical across **both** profiles × `portable`; `eh_conformance_
  test` runs `tag.wast`/`throw.wast`/`try_table.wast`/`throw_ref.wast` + `legacy/throw.wast`/`legacy/
  rethrow.wast` with `fail == 0`, `pass > 0`, and every skip categorized. Cites the EH proposal
  ([`WebAssembly/exception-handling`](https://github.com/WebAssembly/exception-handling)): tag section
  id 13, `throw` 0x08, `try_table` 0x1F + catch clauses 0x00–0x03, `throw_ref` 0x0A, `exnref`; the legacy
  `try` 0x06/`catch` 0x07/`catch_all` 0x19/`delegate` 0x18/`rethrow` 0x09; spec §4.4/§4.4.9 unwinding.
- **Proof 2 green (JS on the BEAM — MEASURED):** P7-09's JS corpus runs through 2core on the BEAM and
  matches `porf run`/Node (differential), with the JS-subset coverage measured + categorized. The
  capstone confirms the measured number and records it honestly in `docs/js-on-the-beam.md`. Cites the
  measured Porffor ABI: the `(f64,i32)` value ABI, the `("" "a")`/`("" "b")` intrinsic imports, the `"m"`
  entry export.
- **Proof 3 confirmed (neutral):** the Phase-1..6 corpus + prior spec-suite counts are unchanged where
  the category is unchanged (only the EH `.wast` files add passes; nothing formerly-passing flips); unit
  06's emitter-level byte-identity test (a tag-free module ⇒ byte-identical `.core`) is green in `gleam
  test`.
- **Proof 4 green (tier matrix):** an EH program with a throw on a loop's hot path is byte-identical
  across `combos.shipped`; constant-space + preemption survive the throw; fuel is charged across it;
  P7-06's extended D3a test is green; the runs-anywhere grep confirms no ambient `apply` of a
  runtime-named atom on the EH path.
- **Proof 5 green (runs-anywhere):** the EH programs under `profiles.portable()` grep **zero** native
  primitives, name `rt_exn`/`try` non-vacuously, and execute byte-identical to the `cell`/`paged` oracle.
- **Image + docs:** `docs/js-on-the-beam.svg` + `docs/js-on-the-beam.md` committed (measured JS coverage
  + EH `.wast` + the three scope-limits + one line per proof); `docs/wasm-conformance.svg` footnote →
  Phase-7 scope, the non-EH slice unchanged.
- **`gleam format --check src test` clean; `gleam build` ZERO warnings; `gleam test` stays green
  (≥ 1491, now higher); conformance `fail == 0` across every shipped combination.** Done = **the suites
  pass**, never "it compiles."
- Update `state.md`: announce **Phase 7 proven — JS on the BEAM via Porffor** — with the honest close
  (§G), the three scope-limits, the measured legacy-EH correction, and the **Phase 8+ scope (native JS
  frontend / broader surface / GC / Erlang-Gleam frontend / stack-switching / component model / B1 /
  tier-N / memory optimizer / tail calls; WASI out of core)**.

---

## What this unit leaves

Phase 7 is proven: **JS runs on the BEAM.** A real, Porffor-compiled JavaScript program is decoded /
validated / lowered / emitted by 2core to Core Erlang and runs on the BEAM as **compiled, preemptive
code**, producing output matching Porffor's own execution / Node — measured honestly, bounded by
Porffor's ~⅓-of-ECMA coverage. The load-bearing engine feature, **WebAssembly exception handling**, is
real and **BEAM-native**: tags → build-controlled BEAM exception terms; `throw`/`throw_ref`/`rethrow` →
`erlang:error`/`raise`; `try_table`/`try`-`catch`/`catch_all` → Core Erlang `try…catch` that matches the
tag, binds the payload, and re-raises a non-match (spec §4.4.9) — spec-correct against the official EH
`.wast` suite under both modes and every shipped `state_strategy × mem_tier`, **conformance-neutral by
default** (J6 — a tag-free module is byte-identical to Phase-6, witnessed by a const-folded EH-free
Porffor program), and **runs-anywhere** for the EH surface. The IR grew **language-neutrally** — the
`Throw`/`TryTable`/`ThrowRef` nodes + the `exnref` value are a **generic structured-exception model**, so
a future native JS or Erlang/Gleam frontend reuses them unchanged. The measured honest correction stands
recorded: Porffor 0.61.13 emits the **legacy** EH encoding, decoded alongside the modern `try_table`
form into the one neutral IR + BEAM mapping.

**Deferred, stated not dropped (J8) — this is Phase 8+:** a **native JS frontend** (broader than
Porffor's ⅓ coverage — the largest candidate, reusing this phase's generic EH IR); a **broader-than-
Porffor JS surface**; **GC-proposal reftypes** (`struct`/`array`/`i31`/typed refs — Porffor doesn't need
them, confirmed); the **Erlang/Gleam frontend**; **stack-switching / the component model**; the
single-`.beam` **B1** binding; **tier-N numerics/SIMD + a production C NIF**; the **memory optimizer**
(its own performance phase); the **tail-call proposal** (`return_call*` — maps cleanly onto BEAM native
tail calls, a plausible fast-follow). **WASI** stays an `rt_host` implementation, out of core; **the
browser DOM** is out of scope entirely.

**Phase 7 reaches the goal the platform was always for: *any Porffor application becomes a well-behaved,
compiled, preemptive BEAM citizen.* The next move is a native JS frontend — broader JS, on the same
engine.**

---

## Open questions (for the planner / cross-unit sync)

1. **EH-encoding scope + `.wast`-run ownership (the load-bearing seam, §H-1/H-3).** Measured: Porffor
   0.61.13 emits the **legacy** EH encoding, not `try_table`; the official `.wast` suite uses **modern**
   `try_table`. **Proposal:** P7-03 decodes **both** forms into the one neutral IR (both are cheap — the
   legacy `try`/`catch`/`end` maps directly onto the existing block/label machinery); the capstone owns
   `eh_conformance_test.gleam` (the modern `.wast` + `legacy/*`). Confirm P7-03's dual-encoding scope and
   the capstone's `.wast` ownership (or split an EH-conformance sub-unit — a one-line call).

2. **The uncaught-exception `Outcome` shape (§A / §H-4).** The driver must normalize a top-level
   `{wasm_exn, TagId, Payload}` into a comparable `Outcome` (the reference `assert_exception` action).
   **Proposal:** P7-06/09 (the driver's EH path) publish the exact `Outcome` variant + the tag/payload
   decode so the capstone greps a **documented** shape, not a guessed one. Pin whether a caught return
   (an ordinary `assert_return`) and an uncaught throw (`assert_exception`) are the two EH observations,
   and how a null-`exnref` `throw_ref` trap (an existing trap channel, no new `TrapReason` — S8) is
   distinguished.

3. **The `rt_exn` / Core-Erlang-`try` atom names for the runs-anywhere grep (§F).** The grep needs the
   exact runtime atoms P7-06/07 froze: `rt_exn` (stable — the module name), the throw/match/reraise
   function atoms, and whether `emit_core` emits a literal Core Erlang `try`/`catch`/`raise` or an
   `rt_exn` helper for the match. **Proposal:** P7-06/07 publish these in their frozen signatures so the
   capstone greps a documented set; the tokens in §F follow the frozen set, flagged so reconcile keeps
   them in sync. Also pin whether P7-08 ships a named `profiles.porffor()`/`js` posture (the capstone's
   JS-corpus runs would name it) or reuses `safe_spectest()`-style whitelisting for the `("" "a")`/
   `("" "b")` intrinsics.

4. **The Porffor intrinsic set across a wider JS corpus (§C.1, scoping-q (c)).** Measured: a trivial
   program imports exactly `("" "a")`/`("" "b")`; a wider corpus pulls in more. **Proposal:** P7-08
   enumerates the full intrinsic set its corpus exercises + their semantics (build-fixed `case`, no
   `apply/3`); the capstone's headline (proof 2) claims exactly the corpus that runs, and an unprovided
   intrinsic is a **categorized skip** (fail-closed), so the measured JS coverage is honest.

5. **The `porf run` vs Node oracle disagreements (§C.2).** Measured: `porf run` and Node agree on the
   probes tried (`console.log(2+3)` → `5`; the `trycatch` probe → `10\n-1` under both), but Porffor is
   experimental and will diverge somewhere in a wider corpus. **Proposal:** P7-09 pins the primary oracle
   as `porf run` (what 2core faithfully re-runs) with Node as a cross-check, and every `porf`≠Node
   divergence is a **categorized honest note** in `docs/js-on-the-beam.md`, never a 2core "bug" and never
   a false green (R16/S11). The capstone confirms the categorization is closed.
