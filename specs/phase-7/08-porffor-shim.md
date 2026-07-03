# Unit P7-08 — The Porffor-ABI host shim + the `(f64, i32)` typed-value ABI (J3)

> **One owner · Wave A (leaf under `«PORFFOR-ABI»`, keystone P7-01) · depends on the frozen
> Phase-6 imported-function-CALL machinery (S5 — `ir.CallImport`, `link.call_import`,
> `link.link_func_imports`, the `host_func_closure` that wraps `rt_host.call_host`) and CONSUMES the
> Phase-3/5 `rt_host` capability boundary (`resolve_handler/2`, `call_host/3`, `seed_policy/1`,
> `current_policy/0`, the `HostPolicy` gate) + the Phase-5/6 `profiles` link surface
> (`safe()`/`safe_spectest()`/`HostWhitelist`/`link/1`) + the Phase-1..6 owned-process run-ABI
> (`pipeline.instantiate`/`invoke_instance` and the conformance term ABI
> `ffi.call_instance_terms`/`ffi.result_list`, R17/R18).** Read [`00-overview.md`](00-overview.md)
> (decisions **J1–J8**, esp. **J3/J5/J7**) first, then **[`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md)**
> (the measured Porffor output this unit realises), then `RECONCILIATION.md` **once it lands**
> (**its decisions win over this doc where they conflict**), then the keystone
> [`01-...`](.) (§ the `«PORFFOR-ABI»` seam), then the Phase-5 provider unit this one extends —
> [`09-imports-spectest-linker.md`](../phase-5/09-imports-spectest-linker.md) (the build-fixed
> `spectest` registry, the fail-closed link resolver, the `Provided` externval model) — and the
> Phase-6 [`09-cross-module-linking.md`](../phase-6/09-cross-module-linking.md) (the `ProvidedFunc`
> dispatch closure + the `host_func_closure` → `call_host` seam this unit's intrinsics ride).
> Phases 1–6 are complete and green: **1491 tests, 0 warnings, conformance 46,529 / 1,768 / 0**
> (Safe ≡ Unsafe, all 5 tier combos) — the complete WebAssembly 2.0 surface.
>
> **This unit's facts are MEASURED, not assumed.** Every Porffor claim below was probed against
> **Porffor 0.61.13** (`npx porffor wasm foo.js foo.wasm` + `wasm-tools print`), and the intrinsic
> set was read directly from Porffor's source (`compiler/builtins.js` `createImport`,
> `compiler/precompile.js`, `compiler/wrap.js`, `compiler/builtins/console.ts`, `compiler/types.js`,
> `compiler/wrap.js` `porfToJSValue`). §A records the probe methodology so a later agent can
> re-measure at a version bump.

---

## Context

Phase 6 (S5) made the imported-function **CALL** real: `lower` emits `ir.CallImport(slot, ty, args)`,
`emit_core` emits `link.call_import(closure, args)` against the caller's function-import slot, and
`link.link_func_imports` resolves each function import to a dispatch closure — for a **genuine host
capability** (module neither `spectest` nor a `(register)`ed instance) the closure wraps
`rt_host.call_host(cap, name, _)`, **not link-checked**, gated fail-closed by the instance's
`HostPolicy` at call time (`link.gleam:258–260`). That is exactly the seam a Porffor intrinsic call
needs — Porffor imports its runtime intrinsics from module **`""`**, which is "neither `spectest`
nor registered", so it resolves to a host closure with no change to `link.gleam`.

What is **missing** is everything the *host side* of that closure needs to actually run a Porffor
program and judge its result:

1. **No `rt_host` handler for Porffor's intrinsics.** `resolve_handler/2` knows `env.identity` and
   the seven `spectest.print*` — but nothing under module `""`. A Porffor `call $a` (its `print`
   primitive) resolves to `call_host("", "a", [bits])`, hits the `_ , _ -> Error(Nil)` fall-through,
   and is **denied** — a `{capability_denied, "", "a"}` trap. So today *every* Porffor program traps
   at its first `console.log`. This unit adds the build-fixed Porffor registry.
2. **No console-output capture.** Porffor's `print`/`printChar` are *side-effecting* host calls
   (they write to stdout). The current `HostHandler` (`fn(List(Int)) -> List(Int)`) is pure. To
   *judge* a Porffor program we must capture what it printed — a per-instance output buffer the
   harness reads after the run.
3. **No `(f64, i32)` value-ABI decode.** Porffor represents every JS value as a `(f64, i32)` pair
   (value + type tag) and returns the program's completion value from an exported `m : () → (f64
   i32)`. To judge a program's *result* (not just its printed output) the harness must decode that
   pair into a JS value — number / string-pointer / boolean / undefined / object / … — by the type
   tag, reading the instance's linear memory for pointer types.
4. **No Porffor posture.** `spectest`-importing modules link under `safe_spectest()`; Porffor
   modules need the analogous fail-closed `HostWhitelist` that admits exactly Porffor's `""`
   intrinsics and nothing else.

This unit ships all four — **the glue that lets Porffor's output run on the BEAM and be judged**
(J3). It is conformance-neutral by construction (additive `resolve_handler` arms + a new profile +
a new pure value-ABI module; no existing `.beam` changes), fail-closed (an intrinsic 2core does not
provide is *denied*, never a silent stub), and D3a-clean (a literal `case` registry, no `apply/3`).
The EH engine that Porffor's *control flow* needs is P7-01..07; **this unit is the runtime/IO glue
that sits on top of it** — a Porffor program will not run until *both* the EH pipeline *and* this
shim are green (§Depends on).

## Goal

> **The intrinsic imports Porffor's output declares from module `""` are provided by a build-fixed
> `rt_host` Porffor shim (a literal `case`, no `apply/3` — D3a); the `(f64, i32)` typed-value ABI is
> understood by the run-ABI so a returned value can be decoded into a JS value for judging; Porffor's
> `console.log` output is captured byte-exactly; an unprovided intrinsic FAILS CLOSED (a denial, a
> categorized skip — never a silent stub that corrupts semantics). A real Porffor-compiled JS program
> runs on the BEAM under `profiles.porffor()` and its printed output + completion value are judgeable
> differentially against `porf run` / Node.**

Concretely: (1) `rt_host.resolve_handler` gains **exactly four** arms under capability `""` —
`print` / `printChar` / `time` / `timeOrigin`, keyed on Porffor's build-fixed ident **letter**
(§A) — implementing each intrinsic's measured Porffor semantics (§B); (2) a **per-instance output
buffer** in the process dictionary captures `print`/`printChar` output byte-exactly, read by a
routed `porffor_output/0` seam (§E); (3) a new pure `runtime/porffor_abi.gleam` module defines the
`(f64, i32)` value model — the type-tag table, `porf_decode` (a returned pair → a judgeable
`PorfValue`, reading linear memory for pointer types through a handed-in reader capability), and
`porf_number_to_string` (ECMAScript `Number::toString`, shared with `print`) (§C/§D/§F); (4)
`profiles.porffor()` (aliased `js`) is a **Safe** `HostWhitelist` admitting exactly the four `""`
intrinsics (§G); (5) an unprovided intrinsic is **denied** and surfaced as a categorized skip, never
a stub (§B.4/§Effect); (6) it is **conformance-neutral** — a non-Porffor module (any Phase-1..6
WASM) never touches the new arms/buffer/profile and is byte-identical (§Effect).

## Files owned (single-owner / additive — D1)

- **`src/twocore/runtime/rt_host.gleam`** *(extend, single-owner-additive — Phase-3/5 own it)* — the
  charter of this unit:
  - **Four new `resolve_handler/2` arms** under capability `""` (§B.1): `"", "print_letter"` → the
    `print` handler, etc. **Keyed on the *default* ident letters `a`/`b`/`c`/`d`** (§A.3), with the
    letter→builtin mapping named by a build-fixed constant so the pin is legible.
  - The **per-instance output buffer** pdict seam (§E): `porffor_seed_output/0` (clear at
    instantiate), a private `append_output/1` the `print`/`printChar` handlers call, and
    `porffor_output/0` (read the accumulated `BitArray`, for the harness).
  - The **build-fixed intrinsic `FuncType` table** `porffor_func_type/1` (§B.5) — the link-time
    signature face of the four intrinsics (analogue of `spectest_func_type/1`), so a Porffor import
    with a wrong declared signature is a categorizable mismatch, not a silent accept.
  - **No change to `call_host/3`, `dispatch/3`, `deny/2`, `resolve_handler`'s dispatch shape, or the
    `HostPolicy` gate** — the four arms plug into the *existing* Phase-3 registry exactly as
    `spectest` did (F8's "one new arm each, no dispatch change").
- **`src/twocore/runtime/porffor_abi.gleam`** *(NEW — single-owned by this unit)* — the pure
  `(f64, i32)` value ABI (§C/§D/§F): the `TypeTag` constants, the `PorfValue` judged-value type,
  `porf_decode(f64_bits, type_tag, read) -> PorfValue`, the `MemReader` capability alias,
  `porf_number_to_string(f64_bits) -> String` (ECMAScript `Number::toString`), and the
  bits↔double helpers. **Pure, no `rt_host`/`pipeline` dependency** (so `rt_host` imports it for
  number formatting and the harness imports it for decode, with no cycle). *This is the "(f64,i32)
  value-ABI" the overview's file map places "in the run-ABI"; homing it in a dedicated pure module
  rather than `pipeline.gleam` is argued in §Deviations — it keeps the decode testable in isolation
  and shared cleanly between the shim and the harness.*
- **`src/twocore/runtime/profiles.gleam`** *(extend, single-owner-additive — Phase-4/5 own it)* — the
  link surface (§G): `porffor_allow/0` (the literal four-pair allow-set) + `porffor/0` (the Safe
  `HostWhitelist(porffor_allow())` binding) + the `js/0` alias.
- **`src/twocore/pipeline.gleam`** *(extend, single-owner-additive)* — a thin **run convenience**
  (§H): `run_porffor(wasm, main, ...) -> Result(PorfforRun, PipelineError)` that runs the exported
  `m` under `porffor()`, returns the captured output bytes + the decoded completion `PorfValue`. The
  raw `(f64,i32)` return already crosses the existing multi-value term ABI (`result_list(2, pkg)`);
  this function only *packages* it. The **memory-read seam** the pointer decode needs is flagged as
  **P7-09's** FFI (§H.2), not owned here.

> **No new stub-day-1 freeze is produced here** — this unit is a leaf under `«PORFFOR-ABI»`. It
> **coordinates**: the intrinsic-call *lowering/emit* with the EH-pipeline units (a Porffor `call $a`
> reaches `call_host` only once decode→lower→emit_core handle Porffor's module end-to-end, incl. its
> pervasive EH — P7-03..07, §Depends on); the memory-read + differential judging with **P7-09** (the
> harness owns the FFI + the `porf run`/Node oracle, §H.2/§Verification). It flags — never claims —
> those files (D1).

## Deliverables & freeze milestones

**Consumes (frozen upstream):**

- **Phase-6 S5** — `ir.CallImport(slot, ty, args)`, `link.call_import(closure, args)`,
  `link.link_func_imports(module, providers)` (a `#(other, name)` host import → a host closure
  wrapping `call_host`, **not link-checked**, `link.gleam:258–260`), and `link.host_func_closure`'s
  `coerce_args_to_ints`/`coerce_ints_to_dynamics` D5 marshalling. **This is the path that carries a
  Porffor `call $intrinsic` to `rt_host.call_host("", letter, [bits])`** — consumed **unchanged**.
- **Phase-3/5 `rt_host`** — `resolve_handler/2`, `call_host/3`, `dispatch/3`, `deny/2`,
  `seed_policy/1`, `current_policy/0`, the `HostHandler = fn(List(Int)) -> List(Int)` shape, the
  pdict-key pattern (`HostKey`), the `{capability_denied, Cap, Name}` deny term.
- **Phase-4/5 `profiles`** — `safe()`, `safe_spectest()`, `HostWhitelist(_)`, the `Binding`
  `host_policy` field, `link/1`, `spectest_allow/0` (the literal-list precedent this unit mirrors).
- **The owned-process run-ABI (E1/P4-08)** — `pipeline.instantiate`/`invoke_instance` and the
  conformance term ABI `ffi.call_instance_terms`/`ffi.result_list(arity, package)` (R17/R18): the
  `(f64, i32)` return of `m` crosses as a **2-element result list** `[f64_raw_bits, type_tag]`.
- **The EH pipeline (P7-03..07)** — decode/validate/lower/emit_core/rt_exn for Porffor's `(tag)` +
  `throw` + `try_table`, so a Porffor module *compiles and runs at all* (Porffor throws pervasively —
  measured 58× in a trivial `try/catch` probe). This unit is only exercised once the EH pipeline
  makes a Porffor module runnable; the intrinsic shim is orthogonal to EH but downstream of it in the
  end-to-end path.

**Produces (this unit):**

- The four `rt_host` Porffor intrinsic arms + `porffor_func_type/1` + the output-buffer seam
  (`porffor_seed_output/0`, `porffor_output/0`, private `append_output/1`).
- `runtime/porffor_abi.gleam`: `TypeTag`/`PorfValue`, `porf_decode/3`, `MemReader`,
  `porf_number_to_string/1`, `f64_from_bits/1`.
- `profiles.porffor/0` + `js/0` + `porffor_allow/0`.
- `pipeline.run_porffor/…` + `PorfforRun`.
- The spec/Porffor-cited tests (§Verification): the intrinsic-dispatch differential, the number
  formatter against `porf run` edge values, the `(f64,i32)` decode across type tags, the console
  byte-exact capture, the fail-closed unprovided-intrinsic denial, and conformance-neutral
  byte-identity for every non-Porffor prior module.

**Freeze:** produces no new milestone; it is a prerequisite (with the EH pipeline P7-03..07) for the
JS-subset conformance harness (P7-09) and the capstone (P7-10).

## Depends on

| Needs | From | Why |
|---|---|---|
| `«PORFFOR-ABI»` (the shim contract + the `(f64,i32)` run-ABI shape) | P7-01 | freezes the intrinsic-registry ABI, the `PorfValue`/`porf_decode` head, and the `porffor()` posture name so P7-09 composes against real signatures |
| `ir.CallImport` + `link.call_import` + `link.link_func_imports` + `host_func_closure` | Phase-6 S5 | the path that carries a Porffor `call $intrinsic` to `rt_host.call_host("", letter, args)` — consumed unchanged |
| `rt_host` registry + `call_host`/`HostPolicy` gate | Phase-3/5 | the boundary the four arms plug into (the F8 "one arm each, no dispatch change") |
| `profiles.HostWhitelist`/`link/1`/`spectest_allow` | Phase-4/5 | the literal-list posture pattern `porffor()` mirrors |
| the term multi-value run-ABI (`call_instance_terms`/`result_list`) | R17/R18 (P5-11/P6-10) | delivers the `(f64,i32)` return as a 2-element list `[f64_bits, type_tag]` |
| the EH pipeline (decode/validate/lower/emit/rt_exn) | P7-03..07 | a Porffor module compiles/runs at all (it throws pervasively) — the intrinsic shim is downstream of it end-to-end |
| the instance memory-read FFI + the `porf run`/Node oracle | **P7-09** | the pointer-decode memory reader + the differential judge (flagged, not owned) |

---

## A. The measured Porffor intrinsic import ABI (the enumeration + the naming scheme)

### A.1 The probe methodology (reproducible at a version bump)

Compile a JS corpus and grep the imports:

```
npx porffor wasm foo.js foo.wasm         # Porffor 0.61.13
wasm-tools print foo.wasm | grep '(import '
```

Across an 18-program corpus (`hello`, number, arithmetic, loops, booleans, strings, arrays, objects,
`try/catch`, `Math`, closures, `JSON.stringify`, `Date.now`, `String.fromCharCode`, `parseInt`,
regex, …) **every** import is from module **`""`** and is one of the letters `a`/`b`/`c`/`d`, each a
`(func (param f64))` or `(func (result f64))`. The source of truth is Porffor's `createImport`
registry, not the probe — the probe merely *confirms* it.

### A.2 The registry — exactly four intrinsics (source-verified, exhaustive)

Porffor's importable host functions are created by `createImport(name, params, returns, js, c)`
(`compiler/builtins.js:26`). An **exhaustive** grep of the whole package finds exactly these call
sites; the normal `porffor wasm` path (`compiler/precompile.js:6–9`, JS impls in
`compiler/wrap.js:502–505`) registers **four**, in this fixed order:

| # | `createImport` | WASM type | Native impl (`wrap.js`) | Semantics |
|---|---|---|---|---|
| 0 | `print`, 1, 0 | `(func (param f64))` | `i => print(i.toString())` | write the number's ECMAScript decimal string to stdout |
| 1 | `printChar`, 1, 0 | `(func (param f64))` | `i => print(String.fromCharCode(i))` | write **one UTF-16 code unit** to stdout |
| 2 | `time`, 0, 1 | `(func (result f64))` | `() => performance.now()` | monotonic clock, milliseconds (fractional) |
| 3 | `timeOrigin`, 0, 1 | `(func (result f64))` | `() => performance.timeOrigin` | epoch-ms of process start |

A fifth, `profileLocalSet` (`compiler/pgo.js:19`), exists **only** under profile-guided
optimisation (`--pgo`) and is **never** in a normal build — **out of scope** (a categorized skip if
it ever appears). There is **no other import mechanism**: the commented-out `debugger`
(`codegen.js:412`) is not emitted, and no code path assigns `importedFuncs[...]` outside
`createImport`. So the Phase-7 shim's universe is **these four** — small, closed, and audited.

> **Value-ABI note (load-bearing):** the intrinsics take a **bare `f64`**, *not* the full
> `(f64, i32)` pair. `print(f64)` gets only the numeric value; `printChar(f64)` gets only the char
> code. The `(f64, i32)` typed-value pair is the ABI at the **exported-function** boundary (§C), not
> at the intrinsic-import boundary. Under 2core's D5 an `f64` argument crosses as its **raw IEEE-754
> 64-bit pattern, an Erlang integer** — so `print`'s handler receives `[raw_f64_bits]` (one `Int`)
> and must reconstruct the double before formatting (§F).

### A.3 The naming scheme — the ident LETTER is the stable identity, the func-index is NOT

`createImport` assigns each intrinsic an import **name** (the "letter"):

```js
const ident = String.fromCharCode(97 + importedFuncs.length);   // 'a' + creation index
```

So by creation order (§A.2): **`print → "a"`, `printChar → "b"`, `time → "c"`, `timeOrigin → "d"`**.
The module name is always `""`.

**The letter is the *stable* identity of the builtin; the wasm func-index is treeshake-order and is
NOT.** The assembler (`compiler/assemble.js:16–41`) tree-shakes unused imports and **re-orders the
survivors by first-use** — so the func *index* is unstable — but it emits each survivor's **original
ident letter** verbatim (`assemble.js:184`: `byte(x.import.charCodeAt(0))`). Two measured proofs:

- `console.log(42)` (`02_number`): `(import "" "b" (func (;0;) ...))`, `(import "" "a" (func (;1;)
  ...))` — func-index 0 is `"b"` (printChar, called first for the newline) and func-index 1 is `"a"`
  (print). The **letter** still identifies the builtin; the **index** does not.
- `Date.now()` (`14_date`): imports `"b"`, `"c"`, `"d"` — **no `"a"`**. `time`/`timeOrigin` keep
  their creation-order letters `c`/`d` **even though `a` (print) is absent and unused**. If letters
  were compacted on treeshake, `time` would become `"a"`; it does not. **Confirmed: the letters are
  the creation-order idents, never renumbered.**

**Consequence for the shim:** key the registry on the **`#(module="", name=letter)` pair** with the
build-fixed mapping `a→print, b→printChar, c→time, d→timeOrigin`, pinned to Porffor 0.61.13. This is
exactly how `resolve_handler` already keys `spectest` — a literal `case`, no data-driven dispatch.

> **Version-pin honesty (J8).** The letter↔builtin map is stable *for a fixed Porffor version*
> because it is the fixed creation order in `precompile.js`. A Porffor upgrade that inserts a new
> intrinsic *before* these would shift the letters. The map is therefore **pinned to 0.61.13** and
> named by a legible constant; a version bump is a deliberate re-measure (§Open questions Q1). A
> Porffor module whose `""` import is *not* one of `a`/`b`/`c`/`d` fails closed (§B.4) — never a
> silent mis-dispatch.

---

## B. The build-fixed `rt_host` Porffor shim (the four arms, fail-closed)

### B.1 The four `resolve_handler` arms (the F8 "one arm each, no dispatch change")

The four intrinsics are new arms in the **existing** `resolve_handler/2`, under capability `""`,
following the `spectest` precedent exactly (a literal `case`, no `apply/3`). Each is a build-fixed
closure written in `rt_host`, invoked directly by `dispatch/3` (`handler(args)`):

```gleam
fn resolve_handler(capability: String, name: String) -> Result(HostHandler, Nil) {
  case capability, name {
    "env", "identity" -> Ok(fn(args) { args })
    // ── Phase-5 spectest print family (unchanged) ──
    "spectest", "print" -> Ok(fn(_args) { [] })
    // … the seven spectest arms …
    // ── Phase-7: the Porffor runtime intrinsics (module ""), keyed on the build-fixed
    //    creation-order ident LETTER (§A.3, Porffor 0.61.13). SIDE-EFFECTING (print/printChar
    //    append to this instance's output buffer, §E) or CLOCK-READING (time/timeOrigin) — but
    //    each is TOTAL and node-safe (tier-P/O), so it perturbs no optimizer differential beyond
    //    the CallHost barrier the optimizer already respects.
    "", "a" -> Ok(porffor_print)        // print      : (param f64) -> ()  — a number
    "", "b" -> Ok(porffor_print_char)   // printChar  : (param f64) -> ()  — one UTF-16 code unit
    "", "c" -> Ok(porffor_time)         // time       : () -> (result f64) — performance.now()
    "", "d" -> Ok(porffor_time_origin)  // timeOrigin : () -> (result f64) — performance.timeOrigin
    _, _ -> Error(Nil)
  }
}
```

The letters are named by a legible pin constant so the mapping is self-documenting and a version bump
is a one-line change:

```gleam
/// The build-fixed Porffor-0.61.13 intrinsic ident letters (module ""), in `createImport`
/// creation order (§A.3). Named so the pin is legible and a Porffor version bump is a conscious
/// one-line re-measure, never a silent mis-dispatch. `#(letter, builtin)`.
const porffor_intrinsics: List(#(String, String)) = [
  #("a", "print"), #("b", "printChar"), #("c", "time"), #("d", "timeOrigin"),
]
```

### B.2 The handler contracts (measured Porffor semantics)

```gleam
/// `print` (Porffor `""."a"`, `i => print(i.toString())`). Appends the number's ECMAScript
/// decimal string to THIS instance's output buffer (§E). `args` is `[raw_f64_bits]` (D5 — the
/// f64 argument as its raw IEEE-754 64-bit pattern, an Erlang integer). Returns `[]` (WASM
/// result type `[]`). Total; node-safe. NaN/±Infinity/±0 handled per §F.
fn porffor_print(args: List(Int)) -> List(Int) {
  case args {
    [bits, ..] -> { append_output(porffor_abi.number_to_string_bytes(bits)) [] }
    [] -> []   // defensive: a 0-arg call cannot arise post-validation
  }
}

/// `printChar` (Porffor `""."b"`, `i => print(String.fromCharCode(i))`). Appends the single UTF-16
/// code unit `truncate(f64) & 0xFFFF`, UTF-8-encoded to match Node's `stdout.write(String
/// .fromCharCode(i))` bytes, to the output buffer (§E). ALL Porffor static text (string literals,
/// the console `\n`, ANSI color escapes) flows through printChar (`compiler/codegen.js`
/// `printStaticStr` inlines `printChar` calls) — so capturing print + printChar captures the
/// COMPLETE console byte stream (§E.2). Returns `[]`. Total; node-safe.
fn porffor_print_char(args: List(Int)) -> List(Int) { … }

/// `time` (Porffor `""."c"`, `() => performance.now()`). Returns `[raw_f64_bits]` of a monotonic
/// millisecond clock. NON-DETERMINISTIC — a time-dependent program's output is a categorized
/// non-judgeable skip in the harness (§Effect, §Open Q3), NOT a false green. Total; node-safe.
fn porffor_time(_args: List(Int)) -> List(Int) { … }

/// `timeOrigin` (Porffor `""."d"`, `() => performance.timeOrigin`). Returns `[raw_f64_bits]` of the
/// process-start epoch-ms. Same non-determinism caveat as `time`. Total; node-safe.
fn porffor_time_origin(_args: List(Int)) -> List(Int) { … }
```

`print`/`printChar` return **`[]`** (WASM result type `[]`), so `link.host_func_closure`'s
`coerce_ints_to_dynamics([])` yields the empty value list `call_import` returns — exactly the `[]`
`spectest.print*` returns. `time`/`timeOrigin` return **`[raw_f64_bits]`** (one f64 result), which
`emit_core`'s single-result unpack consumes as the caller's `f64` value.

### B.3 Why `print`/`printChar` are side-effecting handlers (a bounded, argued extension)

The Phase-3 `HostHandler` is `fn(List(Int)) -> List(Int)` — nominally pure. `spectest.print*` bodies
are `fn(_) { [] }` (the suite never observes their output). Porffor's `print`/`printChar` **are
observed** — the whole point of `console.log`. So their handlers **write** to a per-instance output
buffer (§E). This is an *effect*, but a **bounded, node-safe, D3a-clean** one:

- It writes **only** to this process's pdict output-buffer cell (process-local, GC'd with the
  instance, isolated per instance — like the `HostPolicy` seed). No file, socket, or node authority.
- The optimizer already treats a `CallHost`/`CallImport` as an **effectful barrier** (F2/S7), so a
  `print` cannot be reordered/CSE'd/elided — the effect ordering is preserved. No differential
  perturbation beyond the barrier that already exists.
- It changes **no** existing handler: `spectest.print*` still return `[]` and write nothing.

`time`/`timeOrigin` **read** a clock — impure (non-deterministic) but authority-free. The optimizer
barrier again isolates them; the non-determinism is a *judging* concern, categorized (§Effect).

### B.4 Fail-closed on an unprovided intrinsic (J3/J5 — never a stub)

An `""` import that is **not** `a`/`b`/`c`/`d` (e.g. a future Porffor intrinsic, or the PGO
`profileLocalSet`) hits `resolve_handler`'s `_ , _ -> Error(Nil)` → `dispatch` denies →
`call_host` raises `{capability_denied, "", name}` (the existing deny channel). This is
**fail-closed**: the program traps at the unprovided call, the harness sees a trap, and P7-09
records a **categorized skip** ("Porffor pulled an intrinsic 2core does not implement: `""."e"`") —
**never a silent stub that returns a wrong value and green-passes** a corrupted program. There is no
arm that fabricates a result for an unknown `""` name; the closed universe of four is the whole
authority surface. This is the exact fail-closed discipline of the Phase-5 link resolver, applied to
the call-site.

### B.5 The intrinsic `FuncType` table (the signature face, for categorization)

Mirroring `spectest_func_type/1`, a build-fixed `porffor_func_type/1` records the four intrinsics'
declared signatures, so a Porffor import whose declared type disagrees (a version drift, a corrupted
module) is a *categorizable* mismatch rather than a silent accept:

```gleam
/// The build-fixed `FuncType` of a Porffor intrinsic (module "", keyed on the ident letter, §A.3).
/// A literal `case` (D3a). `Ok(ty)` for a known letter, `Error(Nil)` otherwise. Total.
/// print/printChar : [f64] -> [] ; time/timeOrigin : [] -> [f64].
pub fn porffor_func_type(letter: String) -> Result(FuncType, Nil) {
  case letter {
    "a" | "b" -> Ok(FuncType(params: [TF64], results: []))
    "c" | "d" -> Ok(FuncType(params: [], results: [TF64]))
    _ -> Error(Nil)
  }
}
```

> **Why this is *not* wired into `link_func_imports` as a hard link check.** Phase-6 resolves a
> `#(other, name)` host import (module `""` is "other") to a host closure **without** link-checking
> its signature (its fate is the call-site `HostPolicy`, `link.gleam:258–260`). Adding a hard
> `""`-link-check would change that Phase-6 posture (and risk rejecting a validly-Porffor module on
> a signature nuance). So `porffor_func_type/1` is a **diagnostic/categorization** aid P7-09 may
> consult (to label a mismatch precisely) — not a new fail-closed gate. The fail-closed guarantee is
> already the **call-site** denial (§B.4). Flagged for reconciliation (§Open Q2).

---

## C. The `(f64, i32)` typed-value ABI (the value model)

### C.1 The measured value representation

Porffor represents **every JS value as a `(f64, i32)` pair** (`compiler/wrap.js` "typed values", no
NaN-boxing): the `f64` is the value (a JS number *directly*; for a string/object/array/etc. an
**i32 pointer** into linear memory, carried in the f64's integer value), and the `i32` is a **type
tag** from `compiler/types.js`. So a JS function `(a, b) => …` compiles to a WASM function of type
`(param f64 i32 f64 i32) (result f64 i32)` — **multi-value** in and out
([`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md), confirmed across probes).

**The program entry point.** Porffor compiles a top-level program into a `main` function **exported
as `"m"`** with type `() → (result f64 i32)` (measured across every probe). It runs the whole program
(side effects via `print`/`printChar`) and returns the **completion value** as a `(f64, i32)` pair
(usually `undefined` = `(0.0, 0x00)` for a statement program). The **memory** is exported as `"$"`
(the pointer-decode reads it, §D). Exception **tags** are exported as `"0"`, `"1"`, … and each
carries the thrown JS value as `(param f64 i32)` (measured: `03_arith` `(tag (;0;) (param f64 i32))`)
— consistent with the value ABI; the EH engine (P7-01..07) owns the tag, this unit owns the value.

### C.2 How the run-ABI passes/returns a Porffor value (no new primitive)

Under 2core's D5, an `f64` crosses the run-ABI as its **raw IEEE-754 64-bit pattern (an Erlang
integer)** and an `i32` as its integer value. The exported `m : () → (f64, i32)` therefore returns a
**2-element value package**, delivered by the **existing** multi-value term ABI unchanged:

```
ffi.call_instance_terms(proc, "m", [])   →  Ok(package)
ffi.result_list(2, package)              →  [f64_raw_bits, type_tag]   %% element 0 = f64 bits, 1 = tag
```

**No new run-ABI primitive is invented** — the `(f64, i32)` return is an ordinary 2-value multi-value
result (R17/R18), and a Porffor function taking arguments (e.g. a directly-invoked exported JS
function) marshals `(f64_bits, type_tag, …)` as an ordinary term argument list. The only *new* thing
is the **interpretation** of that 2-element list as a typed JS value — §D.

### C.3 The type-tag table (the i32 tag → JS kind)

From `compiler/types.js` (`TYPE_FLAGS.parity = 0x80`, `length = 0x40`), the load-bearing tags:

| Tag (i32) | Kind | Decode (§D) |
|---|---|---|
| `0x00` | `undefined` | `undefined` |
| `0x01` | `number` | the f64 value (reconstructed from bits) |
| `0x02` | `boolean` | `false` if the f64 value is `0.0`, else `true` |
| `0x04` | `bigint` | (rare in the corpus; categorized) |
| `0x05` | `symbol` | opaque; judged by description (categorized) |
| `0x06` | `function` | opaque function handle (judged by identity/arity — categorized) |
| `0x07` | `object` | `null` if the pointer is `0`, else read the object from memory |
| `0x43` | `string` (`0x03\|length`) | UTF-16 string read from memory |
| `0xC3` | `bytestring` (`string\|parity`) | Latin-1 byte-string read from memory |
| `0x48` | `array` (`0x08\|length`) | read the element vector from memory |
| `0x0A` | `date` | epoch-ms number read from memory |

The **primitive** tags (`0x00`–`0x07`, `0x43`, `0xC3`) cover the bulk of the JS-subset corpus and
are decoded *precisely* here; the **extended** internal types (`array`, `date`, `regexp`, typed
arrays, `Map`/`Set`, …) are Porffor's build-fixed `types.js` constants (version-pinned) — the
harness's decoder **mirrors `porfToJSValue`** (`compiler/wrap.js`) and sources the exact extended
constants from the pin, never re-deriving them (so a wrong constant cannot mis-judge). The pin is
Porffor 0.61.13 (§Open Q1).

---

## D. Decoding a returned `(f64, i32)` into a judgeable JS value (`porffor_abi`)

### D.1 `PorfValue` — the judged-value type

```gleam
/// A judged JS value decoded from a Porffor `(f64, i32)` pair (§C). The harness (P7-09) compares
/// a `PorfValue` against the `porf run`/Node oracle. PRIMITIVES are decoded exactly; pointer types
/// are read from linear memory; genuinely-opaque kinds (function/symbol) are judged structurally
/// (arity/description) and flagged so the harness categorizes them rather than false-greening.
pub type PorfValue {
  PUndefined
  PNull
  PBool(Bool)
  PNumber(bits: Int)          // the raw f64 bits (D5) — compared bit-exactly, NaN/±0 aware
  PString(String)             // UTF-16 (tag 0x43) or Latin-1 (tag 0xC3), decoded to a Gleam String
  PArray(List(PorfValue))     // tag 0x48
  PObject(List(#(String, PorfValue)))   // tag 0x07 (non-null)
  POpaque(kind: String)       // function/symbol/bigint/date/… — judged structurally, categorized
}
```

### D.2 `porf_decode` — the pure decoder over a handed-in memory reader (D3a)

```gleam
/// A read capability over the instance's exported linear memory `"$"` (§C.1): read `len` bytes at
/// byte address `addr`. HANDED IN by the harness (built from the instance's memory via an FFI,
/// §H.2) — a capability, never ambient authority (D3a): `porf_decode` cannot reach memory it was
/// not given, and reads are bounds-checked (`Error(Nil)` out of range → a categorized decode
/// failure, never a crash).
pub type MemReader = fn(Int, Int) -> Result(BitArray, Nil)

/// Decode a returned Porffor `(f64_bits, type_tag)` pair into a judgeable `PorfValue`, mirroring
/// Porffor's own `porfToJSValue` (`compiler/wrap.js`). PURE — all memory access goes through the
/// handed-in `read` capability (§D.1). Total: an unknown/opaque tag or an out-of-range pointer
/// yields `POpaque`/a categorized value, NEVER a panic (so a malformed value is a reported skip,
/// not a runner crash).
///
/// - `f64_bits`: element 0 of `result_list(2, pkg)` — the value (a number's raw f64 bits, or a
///   pointer carried as the f64's integer value for a pointer type).
/// - `type_tag`: element 1 — the i32 type tag (§C.3).
/// - `read`: the memory-read capability (§D.1).
pub fn porf_decode(
  f64_bits: Int,
  type_tag: Int,
  read: MemReader,
) -> PorfValue
```

Decode rules (mirroring `porfToJSValue`, primitives exact):

- **`0x00`** → `PUndefined`.
- **`0x01`** → `PNumber(f64_bits)` (compared bit-exactly by the harness — NaN and `-0.0` distinct
  from `+0.0`, D5).
- **`0x02`** → `PBool(f64_from_bits(f64_bits) != 0.0)` (Porffor: `Boolean(value)`).
- **`0x07`** → the pointer `ptr = trunc(f64_from_bits(f64_bits))`; `ptr == 0 → PNull`, else read the
  object property table from memory (`porfToJSValue` object layout: a `u16` entry count at `ptr`,
  then 18-byte entries at `ptr + 8 + i*18` — a `u32` key (top 2 bits select bytestring/string/symbol
  key kind), an `f64` value at `+4`, a `u16` tail at `+12` whose high byte is the value's type tag);
  each `#(key, PorfValue)` decoded recursively.
- **`0x43` (string)** → `ptr`; read `u32` length at `ptr`, then `2*length` bytes at `ptr+4`, each a
  little-endian `u16` code unit → `String.fromCharCode` → `PString`.
- **`0xC3` (bytestring)** → `ptr`; read `u32` length at `ptr`, then `length` Latin-1 bytes at `ptr+4`
  → `PString`.
- **`0x48` (array)** → read the element vector (each element a `(f64, tag)` pair) → `PArray`.
- other tags → `POpaque(type_name)` (function/symbol/bigint/date/regexp/typed-array/…) — the harness
  judges these structurally where it can and **categorizes** the rest (never false-green).

The exact byte offsets for the object/array/date layouts are transcribed from `porfToJSValue` (the
*canonical* Porffor decoder) and pinned; the tests assert the **primitive** decodes against `porf
run` (which uses `porfToJSValue`), so any transcription error surfaces as a differential failure, not
a silent mis-judge (§Verification #4).

---

## E. `console.log` output capture (byte-exact, differential-ready)

### E.1 The per-instance output buffer (a pdict seam, like the policy seed)

`print`/`printChar` accumulate into a **per-instance output buffer** — a second `rt_host` pdict cell,
distinct from the `HostPolicy` key, seeded empty at instantiate and GC'd with the process:

```gleam
/// The pdict key for THIS instance's Porffor console output buffer. As a 0-field constructor it
/// compiles to a unique atom (`twocore_rt_porffor_output`), disjoint from the host-policy key,
/// `rt_meter`'s fuel, and `rt_state`'s cell.
type PorfOutKey { TwocoreRtPorfforOutput }

/// Clear this instance's output buffer to `<<>>`. Emitted by `instantiate/…` alongside
/// `seed_policy`/`seed_fuel` for a Porffor build (a no-op cost for a non-Porffor build — it just
/// seeds an empty binary a non-printing module never reads). Total; process-local.
pub fn porffor_seed_output() -> Nil

/// Append `bytes` to this instance's output buffer (the print/printChar sink, §B). Private — only
/// the two handlers call it. Total; process-local; cannot crash the node.
fn append_output(bytes: BitArray) -> Nil

/// Read this instance's accumulated console output as a raw `BitArray` (the exact byte stream
/// `print`/`printChar` produced). Runs IN the instance's process (state is process-local, E1), so
/// the harness routes an `invoke porffor_output` into the instance to collect it (§H.2). Returns
/// `<<>>` for a never-printed (or unseeded) instance — fail-safe empty, never a crash. Total.
pub fn porffor_output() -> BitArray
```

Because the buffer is a **pdict cell in the instance's owned process** (E1), it is naturally
per-instance and isolated; the harness reads it by routing a call into that process (the same
mechanism export accessors use, P5-09 §E.1) — flagged as P7-09's FFI (§H.2).

### E.2 Why capturing print + printChar captures the COMPLETE console stream (measured)

Porffor lowers **all** console text through these two intrinsics, so the buffer is byte-complete:

- **Numeric values** → `print` (the decimal string, §F).
- **Everything else — string chars, the trailing `\n`, ANSI color escapes, `[`/`]`/`,` structure**
  → `printChar`, because `Porffor.printStatic(str)` inlines one `printChar` per char
  (`compiler/codegen.js` `printStaticStr`).

Measured, byte-for-byte:

- `console.log("hello world")` → `printChar` for each of `h e l l o … d` then `printChar(10)` →
  bytes `hello world\n` (top-level strings print **raw**, no quotes/colors — `__Porffor_consolePrint`
  → `__Porffor_printString`).
- `console.log(42)` → `printChar` `ESC [ 3 3 m` (yellow), `print` `"42"`, `printChar` `ESC [ 0 m`,
  `printChar(10)` → bytes `\x1b[33m42\x1b[0m\n` (non-string values go through `__Porffor_print` with
  `colors=true`, ANSI baked in). Verified with `od -c` on `porf run` piped output.

**The differential is byte-exact and colors are a non-issue**: `porf run` (the oracle) and 2core both
drive the *identical* `print`/`printChar` sequence with the *same* baked-in ANSI escapes, so the
captured byte streams are equal **iff** our `print` (number formatting, §F) and `printChar`
(code-unit → UTF-8 bytes) reproduce Porffor's bytes. The harness compares the raw buffer against
`porf run`'s stdout bytes (§Verification #5); a `--no-color` normalization is an *optional*
convenience, not a correctness requirement.

> `printChar`'s UTF-8 encoding: Node's `stdout.write(String.fromCharCode(i))` writes the UTF-8
> encoding of the code unit `i & 0xFFFF` as a code point. The handler appends the same UTF-8 bytes
> (identity for ASCII; a 2–3-byte sequence for code units ≥ 0x80). Lone surrogates (0xD800–0xDFFF)
> follow Node's WTF-8-ish behaviour; a program emitting them is rare and categorized if it diverges.

---

## F. Number formatting — ECMAScript `Number::toString` (`porffor_abi`)

`print` is `i => print(i.toString())`, so it must reproduce **ECMAScript `Number::toString(x, 10)`**
([ECMA-262 §6.1.6.1.20](https://tc39.es/ecma262/#sec-numeric-types-number-tostring)) exactly. This
is *not* Erlang's default float formatting — the exponential thresholds and integer/`-0` rules
differ. Measured ground truth (`porf run`, stripped of ANSI):

| JS | `Number::toString` | note |
|---|---|---|
| `0`, `-0` | `0` | `-0` prints `0` |
| `42` | `42` | integer, no `.0` |
| `3.14159` | `3.14159` | shortest round-trip |
| `0.1 + 0.2` | `0.30000000000000004` | shortest round-trip (17 sig digits here) |
| `1e21` | `1e+21` | exponential at/above `1e21` |
| `1e-7` | `1e-7` | exponential below `1e-6` |
| `1e20` | `100000000000000000000` | full digits below `1e21` |
| `1/0`, `-1/0`, `0/0` | `Infinity`, `-Infinity`, `NaN` | |

```gleam
/// Format the f64 whose raw IEEE-754 bits are `bits` as ECMAScript `Number::toString(x, 10)`
/// (ECMA-262 §6.1.6.1.20) — the exact bytes Porffor's `print` (`i.toString()`) writes. Handles
/// the special bit patterns FIRST (before reconstructing an Erlang float, which cannot represent
/// them), then applies the ECMAScript digit/exponent rules to the SHORTEST round-tripping decimal.
///
/// Special bit patterns (checked on `bits` directly, §C.2):
///   +0.0 (0x0000000000000000) / -0.0 (0x8000000000000000)         -> "0"
///   +Inf (0x7FF0000000000000)                                     -> "Infinity"
///   -Inf (0xFFF0000000000000)                                     -> "-Infinity"
///   NaN  (exponent == 0x7FF && mantissa != 0)                     -> "NaN"
///
/// Otherwise: reconstruct the double `x`; let `s` (k digits) × 10^(n-k) == x with k minimal (the
/// shortest round-tripping digits — Erlang `float_to_binary(x, [short])` is the digit oracle);
/// then (ECMA-262 §6.1.6.1.20 steps 6–9), with a leading "-" for x < 0:
///   k ≤ n ≤ 21   -> the k digits then (n-k) zeros                       (integer form)
///   0 < n ≤ 21   -> first n digits, ".", remaining (k-n) digits         (fixed with point)
///   -6 < n ≤ 0   -> "0.", (-n) zeros, the k digits                      (leading-zero fixed)
///   n > 21 or n ≤ -6 -> exponential: d1 ["." d2..dk] "e" ("+"/"-") |n-1|  (JS thresholds)
///
/// Returns the JS-exact string. Total — never panics.
pub fn porf_number_to_string(bits: Int) -> String

/// The same, as the UTF-8 `BitArray` the `print` handler appends (§B.2/§E) — `porf_number_to_string`
/// then `bit_array.from_string`.
pub fn number_to_string_bytes(bits: Int) -> BitArray
```

> **Why the ECMAScript rules, not `float_to_binary(x, [short])` alone.** `float_to_binary/2 [short]`
> gives the shortest digit sequence + decimal position, but its *rendering* (when it emits `e`
> notation, whether it prints `1.0e21`) differs from JS. The `k`/`n` from the short digits feed the
> ECMAScript steps 6–9 above to get JS-exact bytes. The tests assert the whole table against `porf
> run` (§Verification #2), so any rule error is caught, not assumed.

---

## G. `profiles.porffor()` / `js` — the JS-on-BEAM posture

Porffor modules link under a **Safe** `HostWhitelist` admitting exactly the four `""` intrinsics —
never `HostOpen`, so no unrelated capability is reachable:

```gleam
/// The build-fixed allow-set for Porffor's runtime intrinsics (§A) — exactly the four
/// `#("", letter)` pairs, nothing more. A LITERAL list (D3a — no data-driven allow-set); every
/// other capability stays denied. Mirrors `spectest_allow/0`. Total.
pub fn porffor_allow() -> List(#(String, String)) {
  [#("", "a"), #("", "b"), #("", "c"), #("", "d")]
}

/// The **Safe** binding that admits Porffor's `""` runtime intrinsics (§A) — a `HostWhitelist`,
/// NEVER `HostOpen`. Identical to `safe()` except `host_policy: HostWhitelist(porffor_allow())`;
/// every non-Porffor capability stays denied (the fail-closed whitelist conjunction), and an
/// unprovided `""` intrinsic (`""."e"`, PGO `profileLocalSet`, …) is denied too (§B.4). It is a
/// **Safe** posture (mode `Safe`) — NOT an Unsafe opt-out, so the fail-closed enumeration is
/// unperturbed (`unsafe()`/`ceiling()` stay the only `mode: Unsafe` constructors). Changes only
/// `host_policy`, so it composes with `link/1` exactly as `safe()`/`safe_spectest()`. Total.
pub fn porffor() -> Binding {
  Binding(..safe(), host_policy: HostWhitelist(porffor_allow()))
}

/// The JS-on-BEAM posture name — an alias for `porffor()` (the headline "run JS via Porffor" build).
/// Provided so callers name the *intent* (`profiles.js()`) not the *toolchain*; identical binding.
pub fn js() -> Binding { porffor() }
```

`porffor()` is a **Safe** posture: the four intrinsics are explicit, auditable host functions with
**bounded authority** (append to an output buffer / read a monotonic clock — no file, socket, or node
authority, §Effect). The Safe capability model is therefore unchanged (J5). `link(porffor())` is
`Ok` (it changes only `host_policy`), and it threads through the pipeline exactly as `safe()`.

> **Why not reuse `safe_spectest()`.** A Porffor module imports from `""`, not `spectest`; its allow
> set is disjoint. Composing the two (a `spectest`+Porffor whitelist) is a trivial list concat if a
> future corpus needs both, but the shipped Porffor posture is the four-pair set only (least
> authority).

---

## H. The run-ABI seam — `pipeline.run_porffor` (+ the memory-read FFI, cross-unit)

### H.1 The run convenience (owned here)

```gleam
/// The outcome of running a Porffor-compiled program on the BEAM under `porffor()` (§C/§E).
///
/// - `output`: the captured `console.log` byte stream (§E) — compared against `porf run`/Node.
/// - `result`: the decoded completion value of the exported `m` (§D) — for expression-valued
///   programs; usually `PUndefined` for a statement program.
/// - `trapped`: `Some(reason)` if the program trapped (an uncaught throw surfaced as a BEAM
///   exception, a denied/unprovided intrinsic, a WASM trap) — surfaced identically to any run-ABI
///   trap, so the harness can assert a *thrown/uncaught* program.
pub type PorfforRun {
  PorfforRun(output: BitArray, result: PorfValue, trapped: Option(String))
}

/// Compile+run a Porffor `.wasm` on the BEAM under `porffor()` and collect its console output +
/// decoded completion value (the JS-on-BEAM run path, §C/§E). Composes `source_to_ir` →
/// `ir_to_core(porffor())` → `core_to_beam` → instantiate → invoke the exported `main` → read the
/// output buffer + decode the `(f64,i32)` return. `main` defaults to `"m"` (Porffor's entry, §C.1).
///
/// - `wasm`: the Porffor-emitted `.wasm` bytes.
/// - `main`: the entry export (Porffor uses `"m"`).
/// - Return: `Ok(PorfforRun)` (output + decoded result [+ trap]); or a compile-stage
///   `Error(PipelineError)`. Total — never panics.
pub fn run_porffor(wasm: BitArray, main: String) -> Result(PorfforRun, PipelineError)
```

`run_porffor` reuses the **existing** run-ABI: `instantiate` (owned process), a multi-value
`invoke`-with-terms of `m` (returning the `(f64, i32)` package via `result_list(2, _)`), and a routed
`porffor_output` read. The `(f64,i32)` interpretation is `porffor_abi.porf_decode` (§D); the console
comparison is P7-09's.

### H.2 The instance memory reader (flagged — P7-09's FFI)

`porf_decode`'s `MemReader` (§D.1) reads the instance's exported memory `"$"`. There is **no** direct
memory-read FFI today (`ffi.gc_and_memory` returns only a byte count). P7-09 (the harness/FFI owner)
adds a routed reader — e.g. `read_instance_memory(proc, addr, len) -> BitArray` that runs
`rt_mem.load_bytes` inside the instance process against memory 0 — from which the harness builds the
`MemReader` capability it hands `porf_decode`. **This unit specifies the capability's shape and the
byte layout it reads (§C.1/§D.2); P7-09 owns the FFI + the routing.** (For unit-testing `porf_decode`
in isolation, a test supplies a `BitArray`-backed `MemReader` — no FFI needed, §Verification #4.)

---

## Effect / soundness / security note

- **No ambient authority survives the shim (D3a) — the full trace.** A Porffor intrinsic call
  reaches the host as: (1) generated caller — `link.call_import(ImpFun_slot, Args)`, a 1-ary
  application of a **fun value** read from the instance's function-import vector at the **static**
  slot (baked by `emit_core` from the import order), never `apply/3` on a data-derived name (Phase-6
  §Effect, unchanged); (2) the host closure `host_func_closure("", letter)` — `""`/`letter` are
  **build-controlled strings** captured at link time; (3) `rt_host.call_host("", letter, args)` →
  `resolve_handler("", letter)` a **literal `case`** selecting a build-fixed closure written in
  `rt_host`, invoked directly (`handler(args)`), never a data-derived module atom. The letter
  *selects among* four build-fixed handlers; it never *constructs* a target. Grep-verifiable (the
  Phase-3/5/6 D3a structural test extends): the Porffor path contains **only** the four literal-case
  arms + closure application, and **zero** `apply/3` on a name from module data.
- **Bounded, auditable IO authority (J5).** The four intrinsics' *only* effects are: append to a
  **process-local output buffer** (`print`/`printChar` — GC'd with the instance, isolated per
  instance, no file/socket/node authority) and **read a monotonic clock** (`time`/`timeOrigin` — no
  authority to affect the world). No intrinsic writes memory, spawns, links, or reaches another
  instance. `porffor()` is therefore a genuinely **Safe** posture: least authority, explicit
  whitelist, fail-closed on anything else.
- **Fail-closed on an unprovided intrinsic (J3/J5).** An `""` name outside `{a,b,c,d}` is **denied**
  (`{capability_denied, "", name}`) — the program traps, and the harness records a **categorized
  skip** ("unimplemented Porffor intrinsic"), never a silent stub returning a wrong value. There is
  no arm that fabricates a result for an unknown name; the closed universe of four is the whole
  surface (spec §4.5.4 posture — an unprovided import is not callable).
- **Non-determinism is a *judging* concern, categorized (never a false green).** `time`/`timeOrigin`
  are non-deterministic; a program whose output depends on them is a **categorized non-judgeable
  skip** in P7-09's differential, not a false pass. The optimizer's `CallHost` barrier already
  prevents the non-determinism from perturbing other code (F2/S7). A deterministic-clock build
  option (a fixed origin + a monotonic counter) is a future convenience (§Open Q3).
- **The `(f64,i32)` decode is a read-only, pure judge.** `porf_decode` reads build-controlled linear
  memory through a **handed-in, bounds-checked** `MemReader`; it cannot reach memory it was not given,
  cannot forge a value, and an out-of-range/unknown value is a **categorized `POpaque`/decode
  failure**, never a crash. Decoding an opaque function/symbol yields `POpaque` (structural judge),
  never a callable capability — no `externref`-style authority is minted.
- **Conformance-neutral (J6/H7).** The shim is purely additive: four `resolve_handler` arms under a
  new capability `""`, a new pdict output cell (seeded empty; a non-printing module never reads it),
  a new pure `porffor_abi` module (imported only where used), a new profile, and a `pipeline`
  convenience. **No existing `.beam` changes** — `resolve_handler`/`call_host`/`emit_core` codegen
  are untouched for a non-Porffor module. The entire Phase-1..6 corpus + spec suite stay
  **byte-identical** under both modes and every tier (assert it, §Verification #6). A module that
  imports nothing from `""` never reaches an arm; a module that never prints never touches the buffer.

## Verification — Definition of Done (D8)

Tests assert **the measured Porffor 0.61.13 behaviour** (its intrinsic set + semantics from
`compiler/precompile.js`/`wrap.js`/`types.js`, and the `porf run`/Node differential), and the
**ECMAScript spec** for number formatting ([ECMA-262 §6.1.6.1.20](https://tc39.es/ecma262/#sec-numeric-types-number-tostring)) —
never "whatever the code emits" (no change-detector tests). **"Done" = a Porffor-compiled JS program
runs on the BEAM under `porffor()` and its output + result are judgeable**, never "it compiles."

1. **Intrinsic dispatch, keyed on the letter (§A/§B).** Under `porffor()`,
   `rt_host.call_host("", "a", [f64_bits(42.0)])` returns `[]` **and** the instance's
   `porffor_output()` gained the bytes `"42"`; `call_host("", "b", [f64_bits(65.0)])` returns `[]`
   and the buffer gained `"A"` (`String.fromCharCode(65)`); `call_host("", "c", [])` /
   `("", "d", [])` return a one-element `[bits]` list (a valid f64). Assert the **fail-closed** case:
   `call_host("", "e", [f64_bits(0.0)])` and `call_host("", "a", [_])` under `safe()` (deny-all)
   both **deny** (`{capability_denied, "", _}`). (Sourced from Porffor's `createImport` order,
   `precompile.js`.)
2. **`porf_number_to_string` == ECMAScript `Number::toString` (§F).** For the §F table
   (`0`, `-0`, `42`, `3.14159`, `0.1+0.2`→`0.30000000000000004`, `1e20`→`100000000000000000000`,
   `1e21`→`1e+21`, `1e-7`, `Infinity`, `-Infinity`, `NaN`) assert `porffor_abi.porf_number_to_string(
   f64_bits(x)) == expected`, where `expected` is the **ECMAScript spec** string (cross-checked
   against `porf run`). Include the special-bit-pattern cases from the raw bits (NaN via a
   non-canonical mantissa, `-0.0` via `0x8000000000000000`). This is the load-bearing formatter.
3. **`(f64, i32)` value ABI end-to-end (§C).** Compile a trivial Porffor program via `porffor wasm`
   whose completion value is a number (e.g. `2 + 3`), run it through `run_porffor`, and assert the
   decoded `result == PNumber(f64_bits(5.0))`. Assert the exported entry is `"m"` with a
   `(result f64 i32)` type (a decode/validate structural check on the Porffor `.wasm`).
4. **`porf_decode` across tags (§D), memory-backed by a fixture reader.** With a `MemReader` backed
   by a fixed `BitArray`, assert: `porf_decode(bits, 0x00, _) == PUndefined`;
   `(f64_bits(3.5), 0x01) == PNumber`; `(f64_bits(0.0), 0x02) == PBool(False)` and
   `(f64_bits(1.0), 0x02) == PBool(True)`; `(0.0, 0x07) == PNull`; a `0x43` string pointer whose
   memory holds `[len=3][UTF-16 'a','b','c']` decodes to `PString("abc")`; a `0xC3` bytestring
   likewise (Latin-1). Cross-check the primitive decodes against `porf run` on a program that
   *returns* each kind (so the fixture layout is validated against Porffor's real `porfToJSValue`).
5. **Byte-exact console capture, differential (§E).** Compile `console.log("hello world")` and
   `console.log(42)` with `porffor wasm`, run via `run_porffor`, and assert `output` equals the raw
   bytes `porf run` writes to stdout — `hello world\n` and `\x1b[33m42\x1b[0m\n` respectively (the
   ANSI escapes are identical on both sides, §E.2). Assert a multi-`console.log` program's output is
   the concatenation in order (the buffer preserves effect order — the `CallImport` barrier).
6. **Conformance-neutral byte-identity (J6/H7).** For a representative Phase-1..6 module (no `""`
   import, non-printing), assert the emitted `.core` and `.beam` are **byte-identical** to Phase-6
   (the four new arms, the output cell, `porffor_abi`, and `porffor()` are unreachable for it). Run
   the full Phase-1..6 conformance under `safe()` and assert `46,529 / 1,768 / 0` unchanged.
7. **The JS-on-BEAM headline, honestly (§C/§E, with P7-09).** A small corpus of real Porffor-
   compilable JS (arithmetic, control flow, a function, a string, `console.log`) compiled by Porffor
   and run through `run_porffor` produces `output` **matching `porf run`/Node**; a program pulling an
   **unprovided** intrinsic is a **categorized skip** (§B.4), and a **time-dependent** program is a
   categorized non-judgeable (§Effect) — measured, never a false green. (The corpus + the differential
   oracle are P7-09's; this unit provides the run path + decode + capture it drives.)
8. **Gate.** `gleam format --check src test` clean; `gleam build` **zero warnings** (no `todo`, no
   unused params); **every public function doc-commented** with contract + failure modes (D8);
   `gleam test` green before and after (1491 → 1491 + the new cases). Done = a Porffor program runs
   + is judgeable.

## What this unit leaves downstream

- **P7-09 (JS-subset conformance harness)** — owns the JS corpus, the `porffor wasm` driver, the
  `porf run`/Node **differential oracle**, the **instance memory-read FFI** (§H.2) + the routed
  `porffor_output` read, and the categorization of skips (unprovided intrinsic, time-dependent,
  Porffor-uncompilable). It **consumes** this unit's `run_porffor`, `porf_decode`, `porffor()`, and
  the captured output. This unit provides the run path + the value ABI + the capture; P7-09 judges.
- **The EH pipeline (P7-01..07)** — a Porffor module runs at all only once decode/validate/lower/
  emit_core/rt_exn handle Porffor's `(tag)`/`throw`/`try_table` (it throws pervasively). This unit is
  orthogonal to EH but downstream of it end-to-end; flagged as a hard co-requisite for §Verification
  #3/#5/#7.
- **Deferred, stated (J8):** a **deterministic clock** build option for reproducible time-dependent
  judging (§Open Q3); the **PGO `profileLocalSet`** intrinsic (never in a normal build — a
  categorized skip if it appears); the full **extended type-tag** decode fidelity (objects/arrays/
  `Map`/`Set`/typed arrays beyond the corpus — mirrored from `porfToJSValue`, extended as the corpus
  grows); WASI/DOM (out of core, J8); a **native** JS frontend (Porffor *is* the frontend).

## Open questions / cross-unit seams (for the planner / reconcile)

1. **The letter↔builtin pin (recommend the named constant + a re-measure gate).** The map
   `a/b/c/d → print/printChar/time/timeOrigin` is Porffor 0.61.13's fixed `createImport` order
   (§A.3). Pin it via `porffor_intrinsics` and gate a version bump on a re-probe. **Alternative
   (more robust, more work):** key on the *arity/signature* + first-use heuristic instead of the
   letter — rejected as brittle (two `(param f64)` intrinsics are indistinguishable by signature).
   Keystone to ratify the letter-keyed registry.
2. **`porffor_func_type/1` — diagnostic vs. a hard link check (recommend diagnostic).** §B.5 makes it
   a *categorization* aid, not a fail-closed gate, to preserve Phase-6's "host imports are call-site
   gated, not link-checked" posture for module `""`. If reconciliation prefers a hard `""`-link check
   (rejecting a signature-mismatched Porffor import at link, like `spectest`), that is a small
   addition to `link_func_imports` — flagged, not assumed.
3. **A deterministic clock for judging (recommend a future `porffor_deterministic()` variant).**
   `time`/`timeOrigin` return the real BEAM monotonic clock; time-dependent programs are categorized
   non-judgeable. A deterministic variant (fixed origin + a per-call monotonic counter) would make
   them reproducibly judgeable — deferred, flagged.
4. **`porffor_abi` home (recommend the new pure module).** The overview's file map places the
   `(f64,i32)` value-ABI "in the run-ABI / `pipeline.gleam`". This doc homes the *pure* decode +
   number formatter in a dedicated `runtime/porffor_abi.gleam` (imported by `rt_host` for formatting
   and by the harness for decode, no cycle) and keeps only the thin `run_porffor` convenience in
   `pipeline.gleam`. Argued in §Deviations; keystone to ratify the module boundary (D1 — exactly one
   owner either way).
5. **The memory-read FFI ownership (P7-09).** `porf_decode`'s `MemReader` needs a routed instance-
   memory read (§H.2). This doc specifies the capability shape + byte layout; P7-09 owns the FFI +
   routing. Confirm the split (this unit's `porf_decode` is FFI-free and unit-testable with a
   fixture reader).
