# Unit P7-09 — the JS-subset conformance harness (Porffor → 2core → BEAM, measured differentially)

> **Owner: 1 agent · Wave A→B · depends on the whole Phase-7 EH pipeline + the Porffor host shim
> (P7-01 keystone, P7-03 decode, P7-04 validate, P7-05 lower, P7-06 emit_core, P7-07 rt_exn, P7-08 the
> Porffor-ABI `rt_host` shim + `(f64,i32)` value-ABI) and, transitively, the entire landed Phase-1..6
> engine + the Phase-5/6 conformance harness (`test/twocore/conformance/**`) whose *discipline* — not
> its files — this unit mirrors in a NEW sibling tree.** Read
> [`00-overview.md`](00-overview.md) (decisions **J1–J8**) and
> [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md) (the **measured** Porffor 0.61.13 facts) first,
> then — the doc whose shape and rigor this one MATCHES — Phase-6
> [`10-conformance-expansion.md`](../phase-6/10-conformance-expansion.md) (the differential
> reference-oracle model, the honest-skip / categorized-residual machinery, the Tier-A/Tier-B split,
> the two-profile × matrix roll-up, the `Report` pass/skip/fail counters) and the Phase-6
> [`RECONCILIATION.md`](../phase-6/RECONCILIATION.md) decision **S11** (greenness is **MEASURED**,
> never promised; every residual is categorized + closed, no false green). This unit owns a **test
> suite + a Porffor-driver + a corpus + a version pin**; **no production code** (`src/` is untouched).
> Its headline deliverable is a **number and a table**: *how many real JS programs, compiled by
> Porffor and run through 2core on the BEAM, produce output byte-identical to Porffor's own execution*
> — with every non-green program a **categorized** skip (Porffor-uncompilable / unprovided-intrinsic /
> 2core-gap / Porffor-vs-Node divergence), never a false green (**J4/J8**, S11). This is **the phase's
> proof that JS runs on the BEAM.**

---

## Context

Phase 7 reaches the platform's stated goal — *any Porffor application runs via 2core on the BEAM* (the
overview §0/§1, high-level §8.2). The EM homework ([`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md))
measured that **everything Porffor emits, 2core already runs after Phase 6 — with exactly one
exception: WASM exception handling** (Porffor throws pervasively; `try/catch` becomes
`try_table`/`catch`). P7-01..07 build EH → BEAM-native exceptions; P7-08 provides the Porffor-ABI
`rt_host` shim (the `("" "a")`/`("" "b")`… intrinsic imports + the `(f64,i32)` typed-value ABI). **This
unit is the phase's measuring instrument for the goal itself:** it takes a JS source, compiles it with
**Porffor** (`porf wasm`), runs the produced `.wasm` through the **full** 2core pipeline (decode →
validate → lower → optimize → emit → build_beam → load) onto the BEAM under the Porffor host posture,
captures the program's observable (its `console.log` byte-stream + optionally its completion value),
and judges it **differentially** against **Porffor's own execution** (`porf run`) and/or **Node** — the
same *differential-against-a-reference* discipline (§11) the WASM spec suite uses, transposed from
`wasmtime`-over-`.wast` to `porf run`/`node`-over-`.js`.

It adds **no engine behaviour**. It **proves** — honestly, against the reference implementation Porffor
*is* (and against Node as the ground-truth JS oracle) — that the JS Porffor can compile *runs correctly
as compiled, preemptive BEAM code*. And it **measures + reports coverage honestly**: a program Porffor
cannot compile, or that needs an intrinsic P7-08 does not provide, or that hits a 2core pipeline gap,
or where **Porffor itself disagrees with Node** (a Porffor bug we cannot hold 2core to), is a
**categorized skip** — visible in the ledger, never a false green (**J8**, S11).

> **Empirical grounding (measured on this machine — Porffor `0.61.13` via `npx porffor`, wasm-tools
> `1.252.0`, Node `v22.19.0`).** Every Porffor fact below (the entry export named after the JS
> basename, the `(f64,i32)` multi-value entry signature, the `("" "a")`/`("" "b")` `(param f64)`
> intrinsics, the pervasive `throw`/`try_table`, the in-band ANSI color in `console.log(number)`) was
> produced by compiling real JS through Porffor and inspecting the output. They are the load-bearing
> input the harness is built on; the *post-run pass/skip/fail* are **measured by the run** (S11), not
> asserted as magic integers here.

### Why this needs the whole EH pipeline (the dependency, stated)

A **trivial** Porffor program is saturated with exception handling: `add.js` (`function add(a,b){return
a+b} console.log(add(2,3))`) compiles to a module with a **`(tag (param f64 i32))`**, **58× `throw`**,
and — for `try/catch` sources — `try_table`/`catch` (measured). Porffor has **no mode** that avoids WASM
EH (both `--exception-mode=stack` and `lut` emit tag/throw/catch — ABI findings). So **no JS program
runs on the BEAM until EH works.** This unit is therefore built + self-tested against a **stub driver**
early (the temporal seam P5-11/P6-10 used), and its real assertions **go green as P7-03..07 land** and
**flip fully green at the P7-10 capstone** — exactly the Wave-A→Wave-B cadence the conformance harness
has always followed.

## Goal

> **Compile real JS with Porffor, run it through 2core onto the BEAM, and prove the output matches
> Porffor's own execution — measured, categorized, never a false green.** Author a `test/twocore/js/**`
> harness: a **Porffor driver** (`porf wasm src.js → .wasm`, then the full 2core pipeline → BEAM under
> the Porffor host posture, capturing `console.log`), a **JS corpus** grown from trivial (arithmetic,
> `console.log`) to real (control flow, functions/closures, recursion, strings, arrays, objects,
> `try/catch`), and a **differential judge** that compares the BEAM console byte-stream against
> `porf run` (byte-exact, Tier-B) and a normalized logical form against **Node** (the ground-truth JS
> oracle, Tier-B), with a **baked `.expected`** (Tier-A, captured from `porf run` at the pin +
> cross-checked vs Node) so the suite has a reference even when `porf`/`node` are absent. Every program
> lands in exactly one bucket — **pass** (BEAM ≡ Porffor), **fail** (BEAM ≠ Porffor: a real 2core bug),
> or a **named skip** (Porffor-uncompilable / unprovided-intrinsic / 2core-gap / Porffor-vs-Node
> divergence). **Measurable done:** the corpus reaches `fail == 0 && pass > 0` (a non-vacuous set of
> real JS programs runs on the BEAM and matches Porffor), every non-pass program is **categorized**
> (the ledger has **no uncategorized skip**, S11/D9), the coverage table is **printed + asserted**
> (a category silently going dark goes red), and the whole thing is **conformance-neutral** — the
> Phase-1..6 WASM corpus + spec suite stay byte-identical (a tag-free module is unchanged, **J6**).

## Files owned

All under `test/twocore/js/**` (D1 — this unit is the sole owner of the JS harness, its corpus, and
its Porffor pin; it **reuses** the generic `twocore_conformance_ffi.erl` shell/file helpers in place
without editing them, and **consumes** the P7-08 host-posture + capture seam). **Nothing in `src/` is
touched.**

| Path | Change | Purpose |
|---|---|---|
| `test/twocore/js/porffor.gleam` | **new** | The Porffor toolchain adapter: `compile(js_path) -> Result(BitArray, PorfforError)` (`npx porffor wasm src.js out.wasm`, read the bytes), `run(js_path) -> Result(RunOutput, String)` (`npx porffor run src.js`, the reference execution), `available() -> Bool` (skip gracefully when absent), `version() -> Result(String, _)` (the pin check). Shells out via the existing `twocore_conformance_ffi:run/2` / `find_executable/1` / `read_file/1` (generic, unowned) + a tmp-file helper. |
| `test/twocore/js/node.gleam` | **new** | The Node ground-truth oracle: `run(js_path) -> Result(String, String)` (`node src.js`), `available() -> Bool`. Same `run/2` shell-out; Tier-B secondary oracle (normalized logical comparison). |
| `test/twocore/js/driver.gleam` | **new** | The end-to-end JS driver: `js_to_beam_output(js_path, binding) -> JsOutcome` — compile with Porffor, run the `.wasm` through the SAME `decode → validate → lower → pipeline.ir_to_core(_, binding) → build_beam.compile_and_load → start_instance` chain the conformance `driver.gleam` uses, invoke the **entry export** (the JS basename), and **drain the captured `console.log`** via the P7-08 seam. Reuses the conformance `driver`'s pipeline sequencing rather than re-implementing it (D1 — imports it or mirrors its public tail). |
| `test/twocore/js/capture.gleam` | **new (thin)** | The console-capture Gleam binding over the **P7-08 seam** (`@external` to the shim's drain function): `drain(proc) -> String` reads the console bytes the Porffor intrinsics wrote into the instance process's buffer during the invoke. **Cross-unit seam — flagged §I / Open questions.** |
| `test/twocore/js/oracle.gleam` | **new** | The JS differential judge: `judge(beam: JsOutcome, porf: RunOutput, node: Option(String)) -> Verdict` — byte-exact `beam.console ≡ porf.stdout` (the strict form), a normalized (ANSI-stripped, trailing-newline-canonical) logical comparison vs Node, and the outcome-class match (a program that throws uncaught on both sides is a *matching* error, not a fail). The single comparison authority (D8) — no JS equality decided elsewhere. |
| `test/twocore/js/report.gleam` | **new** | The coverage ledger: `JsReport(pass, fail, skips_by_category, fails)` + `SkipCategory` (`PorfforUncompilable` / `UnprovidedIntrinsic` / `TwocoreGap(stage)` / `PorfforVsNodeDivergence` / `ReferenceUnavailable`). Prints the honest coverage table; the headline test asserts every skip is categorized (S11/D9). |
| `test/twocore/js/corpus/**.js` | **new** | The JS corpus, one file per program, grouped by category (`arith/`, `control/`, `functions/`, `closures/`, `recursion/`, `strings/`, `arrays/`, `objects/`, `trycatch/`, `console/`). Each program `console.log`s its observable(s). §C enumerates the starter set. |
| `test/twocore/js/corpus/**.expected` | **new** | The **baked Tier-A reference**: the normalized `porf run` output for each `.js`, captured at the pinned Porffor version and **cross-checked against Node** at bake time. Lets the suite judge without `porf`/`node` present; the live `porf run`/`node` differential (Tier-B) re-confirms it when they are. |
| `test/twocore/js/PIN` | **new** | The Porffor + Node version pin (`PORFFOR_VERSION=0.61.13`, `NODE_MAJOR=22`), mirroring `conformance/vendor/PIN`. A drift is a **reviewed** change (the baked `.expected` are only trustworthy against a known Porffor — the reference is a *reference*). |
| `test/twocore/js/vendor.sh` | **new** | Regenerate the `.wasm` (gitignored) from each `.js` via pinned `porf wasm`, and (re)bake `.expected` from `porf run` cross-checked against `node`. Mirrors `conformance/vendor/vendor.sh`. |
| `test/twocore/js/js_conformance_test.gleam` | **new** | **The headline.** Drives the whole corpus through `driver.js_to_beam_output` under the Porffor posture, judges each via `oracle.judge`, prints the coverage table, and asserts `fail == 0 && pass > 0` + every skip categorized (S11). The two-profile (Safe/Unsafe) roll-up: the SAME corpus is byte-identical under `profiles.safe()`/`profiles.unsafe()` (the optimizer-soundness proof extended to JS, **J6**). |
| `test/twocore/js/js_differential_test.gleam` | **new** | The live Tier-B differential: for each corpus program where `porf`/`node` are present, re-run `porf run`/`node` and re-confirm the baked `.expected` + the BEAM output agree; skip gracefully + record when absent (`porffor.available()`/`node.available()` guards). |
| `test/twocore/js/eh_smoke_test.gleam` | **new** | An authored **engine-level** EH proof at the JS surface (independent of Porffor's exact codegen): a hand-written `try/catch`/`throw` JS program whose observable (`console.log("caught", e)`) proves the EH → BEAM-exception mapping end-to-end through the JS path — a caught throw binds the payload, an uncaught throw surfaces as a matching error outcome. Cites the EH proposal semantics via the JS observable. |

> The generic host capabilities the harness needs (shell-out, file read, executable resolution, tmp
> dirs) already exist as **unowned** helpers in `test/twocore_conformance_ffi.erl` (`run/2`,
> `find_executable/1`, `read_file/1`, `unique_int/0`) — this unit **reuses them in place** (they touch
> no unit-owned source). The one genuinely new host capability — **draining the Porffor console-capture
> buffer** — is the **P7-08 seam** (§I): P7-08 owns the shim that *writes* the buffer; this unit binds
> the *drain* it exposes. If P7-08 does not expose a drain, this unit flags it (Open questions), never
> works around it.

## Deliverables & freeze milestones

**Consumes** (every Phase-7 freeze + the landed EH pipeline/runtime + the Porffor shim, plus the
Phase-6 harness discipline):
- `«EH-IR-FROZEN»` / `«RT-EXN-SIG»` (P7-01) + the **landed EH pipeline** (P7-03 decode of the tag
  section + `throw`/`throw_ref`/`try_table` opcodes, P7-04 EH typing, P7-05 EH lowering, P7-06 the
  `emit_core` BEAM-`try` mapping, P7-07 `rt_exn`). The harness never inspects these; it runs the
  *compiled JS module* and judges the observable. Until they land, every EH-bearing program (i.e.
  every Porffor program) skips `TwocoreGap` — the harness is stub-driven until the pipeline is real.
- `«PORFFOR-ABI»` (P7-01) + the **landed P7-08 shim** — (a) a **Porffor host posture**
  (`profiles.porffor()` / a `js` binding, P7-08) that admits the `("" "a")`/`("" "b")`/… intrinsics
  under the fail-closed capability model (D3a: a build-fixed literal `case`, no `apply/3`); (b) the
  **console-capture + drain** seam (the intrinsics write; the harness drains); (c) the `(f64,i32)`
  value-ABI decoder (P7-08) so the entry's completion value can be judged (§G). **Cross-unit seam —
  flagged.**
- The **landed conformance pipeline seam** (P6-10 / P5-11): `decode.decode` / `validate.validate` /
  `lower.lower` / `pipeline.ir_to_core(_, binding)` / `build_beam.compile_and_load` /
  `ffi.start_instance` / `ffi.call_instance_terms` / `ffi.result_list` — reused unchanged (the entry's
  `(f64,i32)` result rides the existing **multi-value TERM ABI**, since `use_term_abi` fires on `>1`
  result; §G). The `Report` counter pattern + the two-profile roll-up (`conformance_test.gleam`) are
  the template this unit's ledger mirrors.
- The **Porffor + Node toolchain** at the pinned versions (`porf` via `npx porffor`, `node`), skipped
  gracefully when absent (the `wasmtime.available()` precedent).

**Produces** (terminal for the JS axis — the **capstone P7-10** consumes this unit's measured
`pass/skip/fail` + the coverage table to write the phase's honest close and the "JS on the BEAM"
headline): the JS corpus, the Porffor/Node adapters, the end-to-end driver, the differential oracle,
the honest coverage ledger, and the two headline tests (`js_conformance_test`, `js_differential_test`)
+ the EH smoke proof. This unit publishes **no** freeze milestone.

**Depends on (freeze milestones):** `«EH-IR-FROZEN»` · `«RT-EXN-SIG»` · `«PORFFOR-ABI»` (all P7-01),
plus the *landed* P7-03..08. Like P5-11/P6-10, the harness machinery (the Porffor adapter, the corpus,
the oracle, the ledger) can be **built + self-tested against a stub driver** before the pipeline lands;
the compare-to-BEAM assertions go green as each upstream unit lands and flip fully green at P7-10.

---

## A. The headline metric — JS runs on the BEAM (measured, differential, categorized)

The one number Phase 7's goal turns on. State it as a **coverage table with a categorized residual**,
and pin it in a test so a regression (a program flipping pass→skip, a category silently going dark, a
false green) goes red.

### A.1 The shape (measured by the run — S11, not asserted here)

For each corpus program the harness records exactly one of:

| Bucket | Meaning | Judged by |
|---|---|---|
| **pass** | Porffor compiled it, 2core ran it on the BEAM, and the BEAM console output **matches Porffor's own execution** (byte-exact vs `porf run`, or the baked `.expected`) | §E oracle |
| **fail** | Porffor compiled it and 2core ran it, but the BEAM output **≠ Porffor's** — a real 2core bug (a mis-lowered op, a wrong EH unwind, a corrupted `(f64,i32)` decode) | §E oracle |
| **skip · `PorfforUncompilable`** | `porf wasm` errored / non-zero exit — the JS is outside Porffor's ~⅓-of-ECMA coverage (J8). *Not our gap.* | §B / §F |
| **skip · `UnprovidedIntrinsic`** | the `.wasm` imports an intrinsic P7-08's shim does not provide → link **fails closed** (`link:` phrase) | §D / §F |
| **skip · `TwocoreGap(stage)`** | decode/validate/lower/emit/build **rejected** a construct 2core does not yet handle (before EH lands: *every* program, `TwocoreGap(eh)`) | §D / §F |
| **skip · `PorfforVsNodeDivergence`** | Porffor's output **≠ Node's** — a *Porffor* bug; we cannot hold 2core to a wrong reference | §E / §F |
| **skip · `ReferenceUnavailable`** | neither a baked `.expected` nor a live `porf`/`node` reference is present — cannot judge | §B / §F |

The **honest reading (J8):** *pass* is the count of real JS programs proven to run correctly on the
BEAM; the skips are **not** 2core failures — they are Porffor's coverage bound, Porffor's own bugs, or
(pre-EH-landing) the engine work still in flight. The ledger keeps them **distinct** so "what runs" is
never conflated with "what 2core cannot do".

### A.2 The test that guards it (`js_conformance_test.gleam`)

```gleam
/// The Phase-7 headline (J4 acceptance "JS on the BEAM"). Drives the whole corpus through
/// Porffor → 2core → BEAM under the Porffor posture, judges each program DIFFERENTIALLY against
/// Porffor's own execution, prints the coverage table, and asserts:
///  (a) fail == 0            — no program where Porffor compiled + 2core ran but the BEAM output
///                             DIVERGED from Porffor's (a real 2core bug);
///  (b) pass > 0             — a NON-VACUOUS set of real JS programs runs on the BEAM and matches
///                             Porffor (arithmetic + control flow + functions + at least one
///                             try/catch — the engine + shim end-to-end);
///  (c) every non-pass program is CATEGORIZED — the skip ledger has NO uncategorized entry (S11/D9),
///      so a program silently going dark (a construct that used to run) cannot hide as a skip.
pub fn js_runs_on_beam_and_matches_porffor_test() {
  let report = run_corpus(driver.js_to_beam_output(_, profiles.porffor()))
  print_coverage(report)
  assert report.fail == 0
  assert report.pass > 0
  assert list.all(report.skips, is_categorized)   // every skip has a named SkipCategory
}
```

`is_categorized` is total by construction (a `SkipCategory` is a closed enum), so the invariant is
really "no program reaches the ledger without a decision" — the driver returns a `JsOutcome` that is
*always* one of pass/fail/`Skip(category)`, never a silent drop. **The assert direction (JS ↑ pass, 0
divergences, every residual categorized) is the spec-grounded invariant** (S11/D8), not an exact
integer — `pass` is **measured** by the run and recorded by the capstone.

### A.3 Conformance-neutrality (the WASM suite is untouched — J6)

This unit adds **no** `src/` code and **no** WASM fixtures, so the entire Phase-1..6 conformance suite
+ acceptance corpus are **byte-identical** — a fact this unit *relies on* (the EH additions upstream
are conformance-neutral for tag-free modules) but does not re-prove (that is P7-03..06 + the capstone's
job). The JS harness is a **new, isolated tree**; running it cannot perturb a single WASM assert.

---

## B. The Porffor toolchain — the compile/run reference (measured facts + the pin)

The reference implementation Phase 7 differentials against is **Porffor itself** — it is both the
*compiler* (`porf wasm`) whose output 2core consumes and the *reference executor* (`porf run`) whose
output 2core must match. Measured facts the adapter (`porffor.gleam`) is built on:

### B.1 The two invocations (measured)

- **`npx porffor wasm src.js out.wasm`** — AOT-compile `src.js` to a standalone `.wasm`. Exit 0 +
  `out.wasm` present ⇒ compilable; a non-zero exit / diagnostic ⇒ **`PorfforUncompilable`** (J8 — the
  JS is outside Porffor's coverage; *not our gap*). The adapter reads `out.wasm` via `read_file`.
- **`npx porffor run src.js`** — compile-and-execute in one shot; its **stdout** is the reference
  console output. Exit 1 with an `Error: …` line ⇒ the program **threw uncaught** (an outcome class,
  §E). This is the Tier-B primary oracle.

The adapter writes each corpus program to a tmp file with a **deterministic basename** (so the entry
export name is known — §D.1), runs both, and (for the vendor/bake step) records the normalized stdout
as the `.expected`.

### B.2 What Porffor emits (measured, load-bearing — from `PORFFOR-ABI-FINDINGS.md` + fresh probes)

Confirmed by compiling `add`/`fib`/`str`/`trycatch` probes and `wasm-tools print`:

- **The entry export is named after the JS basename.** `m.js` → `(export "m" (func 2))`; `add.js` →
  `(export "add" …)`. It is the module's top-level: calling it **runs the whole program** (top-level
  `console.log`s fire as side effects) and returns the completion value.
- **The entry (and every JS function) is multi-value `(result f64 i32)`** — Porffor's typed-value ABI:
  the `f64` is the value (a number directly, or an i32 memory pointer carried in the f64 for
  strings/objects/arrays), the `i32` is a **type tag** (number/string/object/boolean/undefined/…).
  Arguments are `(param f64 i32 …)` pairs. §G decodes this for value-level judging.
- **A `(tag (param f64 i32))` + pervasive `throw`** — even `add.js` carries the tag + **58× `throw`**
  (every JS error/type-check path); `try/catch` sources emit **`try_table`/`catch`** wrapping the body.
  The tag is exported (`(export "0" (tag 0))`). *This is why the whole EH pipeline is a prerequisite.*
- **The intrinsic imports are a tiny treeshaken set from module `""`.** Measured across probes:
  **`(import "" "a" (func (param f64)))`** = **print a JS number** (its decimal form) and
  **`(import "" "b" (func (param f64)))`** = **printChar** (the `f64` is a character code). `console.log`
  compiles to a sequence of `b`(char) calls for the text plus `a`(number) for numeric values.
  Treeshaking varies the set: a pure-string `console.log("a"+"b")` imports only **`b`**; a wider corpus
  pulls in more (P7-08 enumerates the full set). **P7-08 provides these; an unprovided one fails
  closed → `UnprovidedIntrinsic`.**
- **Memory is exported as `(export "$" (memory 0))`**; the entry is the sole *function* export besides
  the tag `"0"`. So the harness can identify the entry either by the known basename or as "the function
  export that is neither `0` (tag) nor `$` (memory)".

### B.3 In-band ANSI color (a measured differential fact — handled, not fought)

`console.log(7)` emits (measured) the **byte stream** `\x1b[33m` `7` `\x1b[0m` — the ANSI color escapes
are produced **by the compiled program** (via `printChar`/`b`), *not* by a terminal: they persist under
a pipe and under `NO_COLOR=1`, and `console.log("hi")` prints plain `hi`. **Consequence — this is a
gift, not a hazard for the primary oracle:** because the color is *in-band* (part of the compiled
`console.log`), the **same** escape bytes are produced whether the module runs under `porf run` or under
2core on the BEAM (both execute the identical `printChar` sequence). So **`beam.console ≡ porf.stdout`
is byte-exact including the color** — the strongest possible differential (same program, same reference
implementation). For the **Node** secondary oracle (whose `console.log` does *not* colorize), the
oracle strips ANSI escapes and compares the *logical* text (§E). The pin freezes the Porffor version so
the exact escape bytes are stable.

### B.4 The pin (`PIN`) + graceful absence

`PORFFOR_VERSION=0.61.13`, `NODE_MAJOR=22`. Bumping is a **reviewed** change (the baked `.expected` are
only trustworthy against a known Porffor — S11/B.3 precedent). When `porf`/`node` are absent
(`porffor.available()`/`node.available()` false, via `find_executable`), the **baked `.expected`**
(Tier-A) still judges every program; the live differential (`js_differential_test`) skips gracefully +
records — exactly the `wasmtime`-absent handling (P6-10 §F). CI installs the pinned toolchain so the
live differential runs there.

---

## C. The JS corpus — trivial → real, by category (enumerated, grows)

The corpus lives in `corpus/<category>/*.js`; each program is **self-contained** and prints its
observable(s) via `console.log`, so the observable is a deterministic byte-stream the oracle judges.
Start trivial (prove the plumbing), grow to real (prove the engine). The starter set — every entry a
program Porffor 0.61.13 compiles (verified for the trivial rows; the richer rows are added as measured,
a Porffor-uncompilable one becoming a categorized `PorfforUncompilable` skip, never a false green):

| Category | Starter programs (`console.log`ged observable) | Proves |
|---|---|---|
| `console/` | `console.log("hello, beam")`; `console.log(1); console.log(2)` | the intrinsic shim (`b` printChar) + capture end-to-end; multi-statement ordering |
| `arith/` | `console.log(2+3)`; `console.log(7*6-1)`; `console.log(10/4)`; `console.log(2**10)`; `console.log(-0)`; `console.log(0.1+0.2)` | number ABI (`a` print) + f64 arithmetic (IEEE, D5) — incl. `-0`/rounding corners judged by the exact reference bytes |
| `control/` | `if/else` → a branch; a `for` loop sum; a `while` countdown; `switch` | structured control → IR blocks/loops; **constant-space + preemption on the hot path** (J7) |
| `functions/` | a named `function`, an arrow fn, a fn returning a fn, default params, a fn passed as a callback | `call`/`call_indirect` (funcref, Phase 2/5) + multi-value `(f64,i32)` params |
| `closures/` | a counter closure (`let c = mk(); c(); c()`); a closure over a loop var | captured-environment semantics through Porffor's memory model |
| `recursion/` | `fib(10)`; `fact(5)`; mutual recursion (`isEven`/`isOdd`) | deep call chains as compiled BEAM tail/non-tail calls; the scheduler preempts (J7) |
| `strings/` | concat `"a"+"b"`; `.length`; `.toUpperCase()`; template literal; `.charCodeAt(0)` | string memory ops (bulk memory / SIMD string ops, Phase 5/6) via the `b`/`a` intrinsics |
| `arrays/` | `[1,2,3].length`; `.map(x=>x*2)`; `.reduce(...)`; `.join(",")`; index read/write | array-in-linear-memory + first-class fn callbacks (`call_indirect`) |
| `objects/` | `{x:1}.x`; a method call; `Object.keys(...)`; property mutation | object-in-linear-memory + the `(f64,i32)` pointer/tag ABI |
| `trycatch/` | `try{throw 42}catch(e){console.log("caught",e)}`; `try{JSON.parse("x")}catch(e){...}`; nested try; `finally`; re-throw | **the keystone — WASM `try_table`/`throw` → BEAM-native `try/catch`/`raise` (J1)**: the caught payload binds, an uncaught throw surfaces as a matching error outcome, `finally` runs |

Each `.js` has a sibling `.expected` (the normalized `porf run` reference, baked at the pin +
cross-checked vs Node). The corpus is **additive** — the capstone (P7-10) may grow it; a new program
that Porffor cannot compile or that diverges Porffor-vs-Node is added as a *categorized* row, widening
the measured picture without ever faking green.

> **Corpus discipline (spec-first, not change-detector — D8).** The `.expected` is **not** "whatever
> 2core printed"; it is **Porffor's own output** (`porf run`), independently **cross-checked against
> Node** (the ground-truth JS semantics) at bake time. If Porffor and Node disagree on a program, that
> program is a **`PorfforVsNodeDivergence` skip** (a Porffor bug — J8), not a corpus entry we hold 2core
> to. So "pass" always means *2core reproduced a reference that is itself correct JS*.

---

## D. The driver — Porffor → 2core → BEAM → capture (the seam, step by step)

`driver.js_to_beam_output(js_path, binding) -> JsOutcome` is the end-to-end pipeline. It **reuses** the
conformance `driver.gleam`'s public tail (the SAME `decode → validate → lower → pipeline.ir_to_core →
build_beam → start_instance` chain, D1 — no compiler logic re-implemented) and adds only the Porffor
front (compile) and the console back (capture). The steps, with the fail-closed decision at each:

1. **Compile with Porffor** — `porffor.compile(js_path)`. `Error` ⇒ `Skip(PorfforUncompilable)` (J8).
   `Ok(wasm_bytes)` continues.
2. **Full 2core pipeline under the Porffor posture** — `decode.decode(wasm_bytes)` → `validate.validate`
   → `lower.lower` → `pipeline.ir_to_core(irmod, binding)` → `build_beam.compile_and_load`. A rejection
   at **any** stage ⇒ `Skip(TwocoreGap(stage))` carrying the stage prefix (`decode:`/`validate:`/
   `lower:`/`emit:`/`build:` — the conformance driver's existing error channel). **Before EH lands, the
   decoder rejects the tag section / `throw` / `try_table` ⇒ every program is `TwocoreGap(eh)`** — the
   honest pre-EH state (the harness is real, the engine is in flight).
3. **Link the intrinsic imports** — `link.link_imports` + the P7-08 function-import closures resolve
   `("" "a")`/`("" "b")`/… against the Porffor shim. An **unprovided** intrinsic ⇒ the link fails closed
   (`link:` phrase) ⇒ `Skip(UnprovidedIntrinsic)` (J3/J5 — never a silent stub that corrupts
   semantics). This is the **same fail-closed link path** the conformance harness proves for
   `assert_unlinkable` (D3a: a handed-in closure vector, no ambient `apply`).
4. **Instantiate in an owned process** — `ffi.start_instance*` (E5, one-instance-one-process). An
   instantiation-time trap ⇒ recorded as an error outcome (§E — it may legitimately *match* a Porffor
   uncaught throw at top level).
5. **Invoke the entry export** — the JS basename (§D.1), with no arguments. Its `(result f64 i32)`
   rides the **existing multi-value TERM ABI** (`use_term_abi` fires on `>1` result — no new marshalling
   needed): `ffi.call_instance_terms` → `ffi.result_list(2, …)` → the `(f64_bits, type_tag)` pair. The
   invoke **runs the whole top-level program**, so the intrinsic calls (`console.log`) fire into the
   capture buffer during this call.
6. **Drain the console** — `capture.drain(proc)` reads the bytes the Porffor intrinsics wrote into the
   instance process's buffer during step 5 (**the P7-08 seam, §I**). This is the primary observable.
7. **Decode the completion value (optional, §G)** — for expression-level programs (a corpus entry whose
   observable is the *returned value* rather than `console.log`), decode the `(f64,i32)` pair into a JS
   value via the P7-08 value-ABI so the oracle can judge it too.

The result is a `JsOutcome`: `Ran(console: String, value: Option(JsValue))` | `Threw(reason: String)` |
`Skip(SkipCategory)`. **Total** — every path lands in exactly one, never a panic, never a silent drop.

### D.1 Identifying the entry export (robust)

The harness controls the tmp basename, so the entry export name is known (Porffor names it after the
basename — B.2). Defensively, if that export is absent, the driver picks **the sole function export
that is neither `"0"` (the tag) nor `"$"` (the memory)** from the lowered IR's export table (the
conformance `driver.export_types` already computes exports). Either is correct — the load-bearing fact
is that invoking the entry runs the whole program.

### D.2 The Porffor posture (`binding`)

`profiles.porffor()` (P7-08 — **cross-unit seam**) is the host posture that admits the Porffor
intrinsics under the fail-closed capability model: a `HostWhitelist`-style allow set naming `("" "a")`,
`("" "b")`, … whose handlers are the build-fixed shim (D3a — literal `case`, no `apply/3`). It is
otherwise the Safe binding (Baseline optimizer, enforcing fuel, `cell × paged`), so **preemption + fuel
still bite across a JS throw** (J5/J7). The two-profile roll-up (§H) also runs the corpus under a
`porffor()`-derived **Unsafe** posture (Aggressive optimizer) to prove the optimizer is JS-sound.

---

## E. The differential oracle — `porf run` (byte-exact) + Node (normalized) + outcome class

The oracle (`oracle.gleam`) is the **single comparison authority** (D8). A JS program's observable has
two parts — the **console byte-stream** and the **outcome class** (returned vs threw-uncaught) — and two
references — **Porffor** (the reference *implementation*) and **Node** (the ground-truth *semantics*).
The judge composes them:

### E.1 Primary: byte-exact against Porffor (Tier-A baked + Tier-B live)

**`beam.console ≡ reference`**, byte-for-byte, where `reference` is the baked `.expected` (Tier-A,
always present) and — when `porf` is installed — a **live** `porf run` (Tier-B, re-confirms the bake).
Because the ANSI color is **in-band** (B.3), the byte-exact match *includes* the color escapes: the
BEAM runs the identical compiled `console.log`, so a correct 2core reproduces the exact bytes Porffor
prints. **A single wrong character — a mis-decoded `(f64,i32)` number, a dropped `printChar`, a wrong
loop count — diverges here on the exact program.** This is the strict form and the primary judge.

### E.2 Secondary: normalized-logical against Node (the semantics oracle)

**`strip_ansi(beam.console) ≡ᴺ node.stdout`** (trailing-newline-canonical, ANSI-stripped), where Node
is the ground-truth JS executor. This catches the case where *Porffor itself is wrong*: if
`porf run ≠ node`, the program is a **`PorfforVsNodeDivergence` skip** (a Porffor bug we cannot hold
2core to — J8). If `porf run ≡ node` but `beam ≠ porf run`, that is a genuine **fail** (2core diverged
from a *correct* reference). So the Node oracle is what makes "pass" mean *2core reproduced correct JS*,
not merely *2core reproduced Porffor's (possibly buggy) output*. (Node runs the `.js` source directly —
it does not consume Porffor's `.wasm` — so it is a genuinely independent oracle.)

### E.3 The outcome class (a matching error is not a fail)

An **uncaught** JS `throw` at top level is a legitimate observable: `porf run` prints `Error: …` to
stderr and **exits 1**; on the BEAM the uncaught WASM exception surfaces as a BEAM exception the
instance boundary contains (J1/J5) — the driver records `Threw(reason)`. The oracle matches **outcome
class first**: *both threw uncaught* is a **pass on the class** (the exact BEAM reason text need not
equal Porffor's stderr message — different renderings of "the program threw" — but any prior
`console.log` output before the throw **must** still match byte-exact). *One threw and the other
returned* is a **fail**. This is the EH end-to-end proof at the JS surface: a `try/catch` that **catches**
must produce the caught-path console output (`"caught 42"`); a throw that **escapes** must be a matching
error on both sides. Cites the EH proposal's propagation semantics (an unhandled `throw` unwinds to the
top; `try_table`/`catch` transfers to the handler with the payload — the exec semantics P7-06/07 lower
to Core Erlang `try/catch`/`raise`).

> **The three-way logic, tabulated (the honest judge):**
>
> | `porf run` vs `node` | `beam` vs `porf run` | verdict |
> |---|---|---|
> | agree | agree (byte-exact / matching class) | **pass** |
> | agree | disagree | **fail** (2core bug — the target of the whole harness) |
> | disagree | — | **skip · `PorfforVsNodeDivergence`** (Porffor bug, J8) |
> | reference unavailable (no bake, no live) | — | **skip · `ReferenceUnavailable`** |

---

## F. The coverage ledger — categorized skips, never a false green (S11/D9)

`report.gleam` accumulates a `JsReport` exactly as the conformance `runner.Report` accumulates
pass/skip/fail — but bucketed by the **`SkipCategory` enum** so the residual is *typed*, not a free
string. The headline test (§A.2) asserts the ledger is **honest**: `fail == 0`, `pass > 0`, and every
skip carries a `SkipCategory`. The printed table (per the conformance runner's per-file report style)
makes coverage **visible**:

```
=== JS-on-the-BEAM conformance (Porffor 0.61.13 → 2core → BEAM) ===
  console/hello                 PASS   (beam ≡ porf ≡ node)
  arith/pow                     PASS   (beam ≡ porf ≡ node)
  trycatch/basic                PASS   (caught 42; beam ≡ porf ≡ node)
  objects/keys                  SKIP   PorfforVsNodeDivergence (porf≠node: key order)
  arrays/flat                   SKIP   PorfforUncompilable (porf wasm: unsupported)
  ...
  TOTAL   pass=NN  fail=0  skip=MM   [ Uncompilable=k  Unprovided=0  2coreGap=g  PorfVsNode=d  RefUnavail=0 ]
```

Each `SkipCategory` is **honest by construction** (S11):
- **`PorfforUncompilable`** — Porffor's ~⅓-of-ECMA bound (J8). The count *measures* Porffor's coverage,
  not 2core's. Never a false green.
- **`UnprovidedIntrinsic`** — a P7-08 shim gap; the link fails closed (never a silent stub). The set
  shrinks as P7-08 enumerates more intrinsics; a program needing one is a **named** skip, not a fail.
- **`TwocoreGap(stage)`** — a real 2core rejection, carrying the stage. **Before EH lands this is
  every program** (the honest pre-Wave-B state); after EH lands it should be **empty** for the corpus
  (if a program still gaps, it is a *named* engine gap the capstone owns, never faked green).
- **`PorfforVsNodeDivergence`** — a Porffor bug (Porffor ≠ Node). The program is skipped, the divergence
  *printed*, so the reader sees the true cause (never mislabelled as a 2core issue).
- **`ReferenceUnavailable`** — no baked `.expected` and no live reference; the honest "cannot judge".

The load-bearing invariant (S11/D9): **there is no bucket for "it didn't work and we don't know why".**
Every program the harness cannot turn green is turned into a *typed, printed* skip — the capstone quotes
these categories verbatim in the honest close.

---

## G. The `(f64, i32)` value-ABI decoding — for expression-level judging (J3)

Most corpus programs are judged by `console.log` output (§E), which needs no value decoding. But for
programs whose observable is the entry's **completion value** (or for future value-level assertions),
the harness decodes Porffor's typed-value pair via the **P7-08 value-ABI** (cross-unit seam):

- The entry returns `(f64, i32)` — the term ABI yields `[f64_bits, type_tag]` (§D.5). The **`i32` type
  tag** selects the interpretation (P7-08 owns the tag→kind table, measured from Porffor's source):
  a **number** tag ⇒ the `f64_bits` are the IEEE value (D5 — raw bits, NaN by class, `-0` distinct); a
  **string/object/array** tag ⇒ the `f64` carries an **i32 memory pointer** into the exported memory
  `"$"`, and the value is a *reference into linear memory* the harness reads through the module's memory
  (or, more simply, judges only via `console.log` — the recommended default, since decoding a heap
  object faithfully re-implements Porffor's memory layout).
- **Recommended scope (argued):** the harness judges **primarily via `console.log`** — the observable
  Porffor itself renders — so it never re-implements Porffor's heap layout (which would couple the test
  to Porffor internals). The `(f64,i32)` **number** decode is used only for the `arith/` value-return
  programs (where the value is a scalar, no heap walk). Heap-object value decoding is **deferred**
  (a categorized capability, not needed for the headline). This keeps the value ABI a **thin** consumer
  of P7-08's decoder, not a second memory model.

> **The value ABI lives in the frontend/host layer, not the IR (J6).** Porffor's `(f64,i32)` is a
> *WASM-level convention*, decoded by the harness/shim — it is **not** an IR node. The IR stays
> language-neutral (the overview #1 / J6 discipline); this unit consumes P7-08's decoder and asserts
> nothing about IR shape.

---

## H. The full matrix × both profiles — conformance-neutral + optimizer-sound over JS (J6/J7)

The JS path inherits the WASM engine's tier/profile matrix; the JS-specific obligations are two:

### H.1 Both named profiles (the optimizer-soundness proof, extended to JS)

The corpus runs under **`profiles.porffor()`** (Safe: Baseline optimizer + enforcing fuel + the shim
whitelist) **and** a **`porffor()`-derived Unsafe** posture (Aggressive optimizer + open runtime).
Both must produce **byte-identical** console output for every corpus program — the Phase-3..6
optimizer-soundness differential (F2), now over real JS. A JS observable the Aggressive optimizer
perturbs (e.g. an over-eager float const-fold that double-rounds `0.1+0.2`, a DCE that drops a
`console.log`) goes red on the exact program. This is the JS half of "the optimizer changes no
observable answer".

### H.2 Preemption + constant space across a throw (the thesis, J7)

At least one corpus program exercises a **hot loop** and one a **throw on the hot path**; the harness
asserts (reusing the conformance `ffi.gc_and_memory` precedent) that a constant-space JS loop stays
constant-space on the BEAM (the `cell` strategy accumulates no per-iteration memory) and that
**preemption + fuel still bite across a WASM exception** (an uncaught throw does not leak the fuel
budget or escape the instance's owned process — J5). This is the "compiled, preemptive, on the BEAM"
payoff made concrete at the JS surface.

### H.3 CI sizing (honest, bounded)

The JS corpus is **small** (tens of programs, not ~24k asserts), so it fits every profile without the
`matrix_skip_numeric` partition SIMD needed. The **cost** is the Porffor/Node shell-outs (one `porf
wasm` + one `porf run` + one `node` per program); the live differential (`js_differential_test`) is the
only shell-out-heavy test and runs the corpus **once** per reference (guarded by `available()`), while
the Tier-A `js_conformance_test` uses the **baked** `.expected` (no shell-out for the reference, only
the one `porf wasm` compile per program — which the vendor step can pre-cache the `.wasm` for). Flag
the exact CI budget (the `porf wasm` compile cost) as an Open question for the capstone's CI config.

---

## Effect / soundness / security note

- **The harness cannot make a broken JS path look green (D8/J4).** Every reference is
  **spec/reference-sourced**: the `.expected` is Porffor's own `porf run` output, **cross-checked
  against Node** (the ground-truth JS semantics) at bake time. "Pass" means *the BEAM reproduced a
  reference that is itself correct JS* — byte-exact console output (color in-band) + matching outcome
  class — **not** "it ran without crashing". A mis-lowered op, a wrong EH unwind, a corrupted
  `(f64,i32)` decode, a dropped `console.log`, or an optimizer that perturbs a float all turn a
  **specific program** red.
- **A thrown exception is a term, never authority (J1/J5, D3a).** The JS `throw` the harness exercises
  lowers (via P7-05/06/07) to a **build-controlled** BEAM exception term routed through `rt_exn`/
  `rt_trap` — there is **no ambient `apply` of an attacker-chosen target** on the path (the same D3a
  invariant the conformance harness greps for). A caught `exnref` is opaque (like `externref`). The
  harness observes the *effect* (the caught payload printed, or a matching uncaught-error outcome), and
  in doing so *proves* the exception never became authority — an uncaught JS throw is contained by the
  instance's one-owned-process boundary (E5), never escaping to another instance or the node.
- **The intrinsic shim is build-fixed + fail-closed (J3/J5, D3a).** The Porffor intrinsics
  (`("" "a")`/`("" "b")`/…) resolve through the P7-08 shim's **literal `case`** (no `apply/3`); an
  **unprovided** intrinsic **fails closed** at link (`UnprovidedIntrinsic`, never a silent stub that
  would corrupt semantics or fake a green). The harness *drives* this fail-closed path (a program
  needing an unprovided intrinsic is a *named* skip) — it is the JS-surface analogue of
  `assert_unlinkable`.
- **No WASI, no DOM (J8).** The only host surface is Porffor's own runtime intrinsics (its
  console/memory/string primitives). A program that needs a host API Porffor stubs/omits is out of
  scope — a categorized `PorfforUncompilable`/`UnprovidedIntrinsic`, never a fabricated result.
- **Floats as raw bits throughout (D5).** JS numbers are f64; the harness judges them via Porffor's own
  rendered decimal (the reference bytes), and the `arith/` value-return decode reads raw `f64` bits
  (NaN by class, `-0` distinct) — never a BEAM-double round-trip.
- **Conformance-neutral + isolated (J6).** The harness is a new tree touching no `src/` and no WASM
  fixture; it cannot perturb a single Phase-1..6 assert. A tag-free module is byte-identical (proven
  upstream); this unit relies on that, and proves the *JS* surface on top.

---

## Deviations from the overview / ABI-findings (ARGUED)

The overview (J4) and ABI findings sketch the harness at the *goal* level; the deviations are
*refinements* the measured facts forced, argued so reconcile can pin them:

1. **The primary oracle is byte-exact against `porf run`, WITH the in-band ANSI color — not a
   color-stripped compare.** *Argument:* measured (B.3) — Porffor's color escapes are emitted by the
   compiled `console.log` (`printChar`), so the BEAM runs the *identical* escape sequence; a byte-exact
   match including color is therefore both **achievable** and **stronger** than a stripped compare (it
   catches a mis-ordered/dropped `printChar`). The color-stripped form is the *Node* (semantics) oracle,
   not the Porffor one. The overview's "check the JS result" is realized as *two* comparisons (§E), not
   one.
2. **Node is a first-class second oracle (`porf run` alone is insufficient).** *Argument:* Porffor is an
   experimental compiler with real bugs (J8); differentialling 2core against Porffor **alone** would let
   a *Porffor* bug masquerade as a 2core pass (2core faithfully reproduces Porffor's wrong output). Node
   (the ground-truth JS semantics) is what distinguishes "2core reproduced correct JS" (pass) from
   "Porffor is wrong" (`PorfforVsNodeDivergence` skip). The overview names "`porf run`/Node"; this unit
   makes the **three-way logic** (§E.3 table) explicit.
3. **Value-level judging is via `console.log`, not heap-object decoding.** *Argument:* faithfully
   decoding a Porffor string/array/object from the `(f64,i32)` pointer + linear memory would
   re-implement Porffor's heap layout inside the test — a brittle coupling to Porffor internals. Judging
   via the observable Porffor *itself renders* (`console.log`) is spec-faithful and layout-independent;
   the `(f64,i32)` **number** decode is used only for scalar value-return programs. Heap-object value
   decode is a **deferred** categorized capability (§G) — not needed for the headline.
4. **The corpus needs no hand-written `.expected` semantics — the reference IS the oracle, baked +
   cross-checked.** *Argument:* differential discipline (§11) — the `.expected` is captured from
   `porf run` and cross-checked against Node, not authored by hand (which would risk a human transcribing
   Porffor's output and locking in its bugs). This is the JS analogue of the `.wast` files' baked
   `assert_return` values.

No deviation touches the IR / EH / shim *engine* surface — those are P7-01..08's. This unit's surface is
the **harness**, confined to `test/twocore/js/**`.

---

## Verification — Definition of Done (D8/J4)

- **JS-on-the-BEAM headline green (§A).** `js_conformance_test` reaches `fail == 0 && pass > 0` over the
  corpus under `profiles.porffor()`: a non-vacuous set of real JS programs (arithmetic + control flow +
  functions + recursion + at least one `try/catch`) compiled by Porffor **runs on the BEAM and matches
  Porffor's own execution**, byte-exact console output (color in-band) + matching outcome class. Every
  non-pass program is a **categorized** skip; the ledger has **no uncategorized entry** (S11/D9).
- **EH proven at the JS surface (§C `trycatch/`, §E.3, `eh_smoke_test`).** A `try/catch` that catches
  produces the caught-path output (`"caught 42"`, byte-exact vs `porf run` + Node); a throw that escapes
  is a **matching uncaught-error outcome** on both sides; a nested try unwinds correctly. This is the
  keystone (J1) proven through the JS path — WASM `try_table`/`throw` → BEAM-native `try/catch`/`raise`.
- **Differential green (§E, `js_differential_test`).** Where `porf`/`node` are present, the **live**
  `porf run`/`node` re-confirm the baked `.expected` **and** the BEAM output; a `porf run ≠ node` program
  is a printed `PorfforVsNodeDivergence` skip (Porffor bug), a `beam ≠ porf run` (with `porf ≡ node`) is
  a **fail**. Skips gracefully + records when a reference is absent (the `available()` guards).
- **Coverage honest + printed (§A/§F).** The coverage table is printed (per-program verdict + the
  category histogram); the residual is **typed** (`SkipCategory`) and **closed** (no uncategorized skip);
  a category silently going dark (a program that used to run) goes red. **Measured, never promised**
  (S11) — the exact `pass`/skip counts are recorded by the capstone P7-10, not baked here.
- **Optimizer-sound + preemptive over JS (§H).** The corpus is **byte-identical** under
  `profiles.porffor()` (Baseline) and its Unsafe (Aggressive) derivative; a constant-space JS loop stays
  constant-space on the BEAM; preemption + fuel bite across a throw (J7/J5).
- **Conformance-neutral (§A.3, J6).** This unit adds no `src/` code and no WASM fixture; the Phase-1..6
  conformance suite + acceptance corpus are byte-identical (a fact relied on, proven upstream).
- **Repo gate.** `gleam format --check src test` clean; `gleam build` **zero warnings**; `gleam test`
  green (the JS suite passing under real backends, or skipping-with-note when Porffor/Node absent + the
  baked `.expected` still judging); every new public function carries a contract doc comment.
  **Done = the corpus runs on the BEAM and matches Porffor**, measured + categorized, never "it compiles".

---

## What this unit leaves

The Phase-7 goal is **proven and measured at the JS surface**: real JavaScript — compiled by Porffor to
WASM, decoded/validated/lowered/optimized/emitted by 2core to Core Erlang and loaded onto the BEAM under
the Porffor host posture — **runs as compiled, preemptive BEAM code and produces the correct JS result**,
judged **differentially** against Porffor's own execution (byte-exact, color in-band) and cross-checked
against Node (the ground-truth semantics). The keystone (WASM EH → BEAM-native exceptions, J1) is proven
end-to-end through the JS `try/catch` path; the Porffor-ABI shim (J3) is proven by the intrinsic
console-capture + the fail-closed unprovided-intrinsic path; the compiled/preemptive thesis (J7) is
proven by constant-space loops + preemption across a throw. **Coverage is measured honestly** (J8/S11):
every non-green program is a *typed, printed* skip — Porffor-uncompilable (Porffor's ~⅓-of-ECMA bound),
unprovided-intrinsic (a named P7-08 gap), 2core-gap (a named engine gap — empty for the corpus once EH
lands), or Porffor-vs-Node divergence (a Porffor bug) — **never a false green**. This unit consumes the
whole Phase-7 EH pipeline + the Porffor shim and emits nothing downstream except **the number, the
coverage table, and the green**.

**Its sibling / consumer:** the **capstone P7-10** quotes this unit's measured `pass / fail /
skip-by-category`, writes the phase's honest close (*JS runs on the BEAM* — the count of programs
proven; the categorized residual bounded by Porffor), and refreshes the docs/SVG to the "JS on the
BEAM via Porffor" headline. Together with the EH engine green (the official EH `.wast` + the authored
proofs) and the conformance-neutral WASM suite, this is the phase's proof that the platform reached its
goal.

**Deferred (stated, not dropped, J8):** heap-object `(f64,i32)` value decoding (judged via `console.log`
instead — §G); a broader-than-Porffor JS surface (needs a native JS frontend, Phase 8+); the JS programs
Porffor cannot compile (its coverage bound — measured, not closed here); WASI/DOM host APIs (out of core
— J8); a performance claim beyond "it runs as compiled, preemptive BEAM code" (Phase 4's numbers stand;
the JS path inherits them). The measured JS coverage **is** the honest headline — exactly what runs, and
nothing more.

---

## Open questions (for the planner / cross-unit sync)

1. **The console-capture + drain seam (P7-08 — the load-bearing cross-unit contract, §D.6/§I).** The
   harness needs to read the bytes the Porffor `("" "a")`/`("" "b")` intrinsics wrote **during** an
   invoke. Those intrinsics run **inside the instance's owned process** (they write to *its* pdict), so
   the harness must drain *that* process's buffer. **Ask:** P7-08 exposes a drain — either (a) a
   `console_drain(proc)` FFI that messages the instance process (mirroring `call_instance`) and returns
   its accumulated buffer, or (b) the entry invoke returns the buffer alongside the `(f64,i32)` result,
   or (c) the intrinsics write to a test-visible collector the harness reads. Recommended: **(a)** — a
   pdict buffer drained via one small FFI message, symmetric with the existing `call_instance` loop,
   isolated per instance (E5). Confirm the exact API + shape in reconcile so `capture.gleam` binds it
   byte-for-byte.
2. **The Porffor host posture (`profiles.porffor()` / a `js` binding, P7-08).** The harness links the
   corpus under a posture that admits the intrinsics fail-closed (D3a). **Ask:** confirm P7-08 exposes
   a `profiles.porffor()` (Safe) + a way to derive its Unsafe (Aggressive-optimizer) twin for the §H.1
   optimizer-soundness roll-up, and that a non-whitelisted intrinsic **fails closed** at link (so an
   `UnprovidedIntrinsic` is a named skip, not a silent stub).
3. **The intrinsic set breadth (P7-08).** Measured: `a` (print number), `b` (printChar). A wider corpus
   (arrays/objects/`Math`) may pull in more intrinsics. **Ask:** confirm P7-08 enumerates the full
   treeshaken set the §C corpus exercises; a program needing an un-enumerated one is an
   `UnprovidedIntrinsic` skip (measured, categorized) until P7-08 adds it — never a false green.
4. **The pre-EH temporal seam.** Until P7-03..07 land, **every** Porffor program is `TwocoreGap(eh)`
   (the decoder rejects the tag section). **Ask:** confirm the harness lands stub-driven + self-tested
   in Wave A (the corpus, adapter, oracle, ledger all green against the stub), with the compare-to-BEAM
   assertions flipping green as the EH pipeline lands and fully green at P7-10 — the P5-11/P6-10 cadence.
5. **CI budget for the Porffor/Node shell-outs (§H.3).** Each program costs a `porf wasm` compile (+ a
   live `porf run`/`node` in the Tier-B test). **Ask:** confirm the plan — bake `.wasm` + `.expected`
   in the vendor step (Tier-A needs no shell-out beyond reading the cached `.wasm`), the live
   differential guarded by `available()` + run once per reference — and pin the exact CI budget with the
   capstone (P7-10) config.
6. **The Porffor version pin + `.expected` drift.** The baked `.expected` are Porffor-version-specific
   (the exact color bytes / number rendering, B.3). **Ask:** confirm `PORFFOR_VERSION=0.61.13` is the
   pin, a bump is a reviewed change that re-bakes + re-cross-checks the whole corpus, and CI installs the
   pinned Porffor (so the live differential is trustworthy) — the `vendor/PIN` discipline (S11/B.3).
