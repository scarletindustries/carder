# Phase 12 — RECONCILIATION (authoritative)

> Contract corrections surfaced while authoring the six unit specs against the real code. **This file is
> AUTHORITATIVE: where it conflicts with the overview or a unit doc, this wins.** Implementer read order:
> `00-overview.md` → this file → unit doc. Decisions here are `R1–R13`.
>
> **Verdict: GO — with the corrections below.** The design (a language-neutral `Iface` + three sibling
> emitters + a compile-and-call differential) is sound and the 6-unit split stands. But grounding in
> `emit_core`/`pipeline` exposed several places where the pinned contract was wrong or under-specified.
> **R1, R2, R5, R6, R12 are correctness-critical** — apply them before freezing `«IFACE-DESC-FROZEN»`.
>
> **Second pass (R14–R25) — from the scoping fan-out (3 framings) + adversarial critique (5 lenses),
> which COMPILED AND CALLED all three languages against real `.beam`s on OTP 29.** No showstopper (every
> language's binding compiled and returned the correct value; R2/R4/R11 confirmed by experiment). But
> twelve further corrections are required — the must-fix-before-freeze ones are **R17** (describe on the
> *lowered* module), **R18** (non-finite floats must be a sum type — plain `Float` raises on NaN/Inf),
> **R19** (the Stateless/Threaded two-shape API, resolving the R2↔R3 contradiction), **R15/R16** (naming
> + cross-language atom collision), and **R20** (reject mutable tiers under `--bindings`).

---

## The corrections

### Descriptor correctness (P12-01)

**R1 — `describe/2` runs on the LOWERED + optimized module, and `touches_state` comes from the
TRANSITIVE state-reaching closure, not `expr_touches_state`.** `expr_touches_state` (emit_core ~L833) is a
*shallow* scan; emit_core sets each export's emitted arity from `ctx.fn_state_reaching` =
`state_reaching_closure` (the transitive `CallDirect` closure, ~L771–823). A pure-*bodied* export that
calls a `MemStore` helper is emitted at **n+1** and threads `St`, yet the shallow predicate reports
`False` → the binding would present `fn(args)` and disagree with the `.beam` ABI (arity mismatch → `undef`
at call time). **Fix:** promote `state_reaching_closure` to `pub`; `describe/2` derives `touches_state`
from it, computed on the **same lowered/optimized `ir.Module` `emit_core` consumes**. The CLI (P12-05)
lowers once (`ir_lower` → `ir_opt`) and hands that one module to **both** `emit_core` and `describe`.

**R2 — The emitted per-export arity + return shape is authoritatively `emit_core`'s; `ExportSig` must
mirror it exactly.** The two emitter authors disagreed on whether, under `state_strategy = Threaded`, a
*non-state-reaching* export is emitted at arity `n` or `n+1` (one saw the `state_reaching_closure` gate →
`n`; another saw a uniform adapting wrapper → `n+1`). **The code decides, not the spec.** P12-01 MUST read
`emit_fn_export` (emit_core ~L508–580) and set `ExportSig` (arity, leading-`St`, `{Package, St'}` return)
to the *actual* emitted shape, and every emitter MUST match it byte-for-byte. Add an `iface_freeze_test`
case that asserts, for a mixed module (a pure export + a memory-mutating export), the `ExportSig` arities
equal the arities in the emitted `.core`.

**R3 — Rename `StateModel { ImportFree Threaded }` → `StateModel { Stateless Threaded }`.** Import-bearing
modules are rejected outright (P8), so *every* accepted module is import-free — "ImportFree" cannot be the
distinguishing axis. The real distinction is **`Stateless`** (no export threads state → a pure host API,
no `Instance` at all) vs **`Threaded`** (≥1 export threads state → `instantiate` returns a real
`InstanceState`, threaded exports expose `Instance`). Derive it from whether the transitive
state-reaching closure is non-empty (R1).

**R13 — `describe/2` surfaces ONLY `ExportFn` exports.** `ExportGlobal`/`ExportTable`/`ExportMemory`/
`ExportTag` are skipped this phase (exported state is not a typed callable). `IfaceError` has exactly
`CellUnsupported` + `ImportBearingUnsupported`; an unresolved `ExportFn.fn_name` post-validation is an
impossible state (a documented `let assert`, not a third error variant).

### Value ABI (all emitters + P12-01)

**R4 — Result encoding, pinned exactly:** the `.beam` export's result package is **0 results → the atom
`ok`; 1 result → the bare value; N≥2 → an N-tuple `{V1,…,Vn}`** in declaration order. (The grounding
"multi-value results are a bare list" was WRONG at the direct-call layer — `pipeline.invoke` re-wraps to a
list, but the binding calls the export directly and sees the tuple, per `function_return` ~L4510.) All
three emitters destructure this shape.

**R6 — Floats + NaN/Inf: native `Float` for finite values, raw-bits path for non-finite (D5).** A BEAM
`float()` (Erlang/Elixir/Gleam) **cannot represent NaN or ±Inf** — `<<Bits:64>> = <<F:64/float>>` raises
`badarg`. So presenting f32/f64 purely as native `Float` is lossy *and*, inside a trap-catch, would
mis-surface a valid NaN result as a fake trap (and it collides with D5's bit-exact invariant). **Fix:**
present f32/f64 as native `Float` for the finite case (the beautiful default) **but always provide a
raw-bits accessor** (`f64_bits`/`f64_of_bits`, `f32_*`) so non-finite/bit-exact values are never lost or
crashed; the raw-bits→float conversion is guarded (detects the non-finite exponent pattern) and **lives
OUTSIDE the trap-catch** (R7). *Open seam for the critique:* the exact non-finite native presentation —
raw-bits passthrough vs a `Finite(Float) | NonFinite(BitArray)` sum type. The P12-06 differential compares
by **raw bits** (so non-finite divergence is caught) and exercises both a finite native-float export and a
non-finite (NaN/Inf) export via the raw-bits path.

**R7 — The trap-catch boundary is narrow.** Only the *call into the `.beam` export* sits inside the
language's try/catch; the native⇄raw conversions (especially the float bit round-trip) are OUTSIDE it. So
a conversion problem is a bug (not a swallowed fake trap), and a valid non-finite result is never mistaken
for a trap. Traps are matched structurally (`error:{wasm_trap,_}` / the `rt_exn` shape), never a bare
catch-all.

**R9 — Export-name sanitization.** WASM export names are arbitrary strings (`run-test`, `_start`,
`foo.bar`, even control bytes). **The dispatch target uses the exact atom `emit_core` exports** (never
sanitized — correctness). **The host-facing function name is a deterministic sanitized identifier** per
language (Gleam needs a valid lowercase identifier; Erlang/Elixir quote the atom). P12-01 defines the
sanitization + collision-avoidance rule (and preserves the original name in a doc comment); a name with no
valid host identifier maps deterministically. This especially constrains the Gleam emitter (P12-02).

### Instance model (P3 → emitters)

**R5 — `instantiate` returns a `Result`.** A threaded module with a trapping `start` or an OOB active
data/element segment traps *inside* `instantiate/0`; the frozen `instantiate() -> Instance` would leak a
raw uncaught exception (violating the acceptance "never a raw uncaught exception"). **Fix:** every emitter
generates `instantiate() -> Result(Instance, Trap)` (`{ok,inst}|{error,trap}` / `{:ok,…}|{:error,…}`).

**R11 — The `Instance` handoff is a pure value; assert result-equality, not mechanism-equality.** The
generated binding threads the `InstanceState` record as a pure value (no process spawned); the P12-06
oracle uses the process-wrapped `InstanceProc`. Different mechanisms, identical results. The capstone
asserts **result**-equality. P12-01 confirms the `InstanceState` record round-trips (can be handed back
into a subsequent same-VM binding call) — the load-bearing precondition for pure value threading.

### Module identity & CLI (P12-05, P12-06)

**R8 — `Iface.module_name` is the FINAL loaded module atom.** It must equal the atom `emit_core` bakes
(`module.name` verbatim, ~L356/403). P12-01 must NOT normalize it. If Phase-11 `--link` renames, the CLI
renames `ir.Module.name` **before both** codegen and `describe`, so the binding's static
`'<atom>':export(…)` call and the loaded `.beam` agree (else `undef` at call time). The two must be proven
identical (a P12-06 smoke assertion).

**R10 — The capstone oracle uses the term-ABI for non-Int results.** `pipeline.invoke_instance` is
Int-typed (`Result(Int,_)`, `Returned(List(Int))`) — it cannot carry a v128 binary, a reference term, or a
multi-value tuple. For those matrix rows P12-06 uses the **term-ABI FFI the conformance harness already
has** (`call_instance_terms` / `result_list`), comparing by decoded raw bits.

**R12 — `--bindings` requires a threaded build; fix the acceptance example.** The default binding is
`Cell`, which `describe/2` rejects (`CellUnsupported`) — so the overview's headline
`to-beam-wasm --bindings gleam --out ./out app.wasm` fails non-zero as written. **Fix:** `--bindings`
requires `--threaded` (or `--portable`); a `Cell` binding yields a typed CLI error with a hint to add
`--threaded`. The overview's acceptance example is corrected to
`to-beam-wasm --threaded --bindings gleam --out ./out app.wasm`.

---

## Unchanged

- The **6-unit split** and the single freeze `«IFACE-DESC-FROZEN»` (P12-01) stand.
- The uniform emitter signature `emit_<lang>(Iface) -> List(GeneratedFile)` stands (the list is what lets
  the Gleam emitter ship its `.erl` catch shim; Erlang/Elixir catch in-language and return a single file).
- P7 (compile-and-call differential, not golden change-detectors) and P8 honest scope (threaded-only,
  export-only, refs opaque, Elixir best-effort) stand.

## Verified de-risking facts (do not re-investigate)

- Erlang and Elixir catch BEAM exceptions in-language (`try/catch error:{wasm_trap,_}` / `try/rescue`) →
  **no catch shim** for those two; only **Gleam** needs the tiny companion `.erl` shim.
- The `rt_trap` error class is `error:{wasm_trap, Kind}` (grounded in `rt_trap`/`rt_exn`), so traps are
  matched structurally (R7).
- Host integers are bignums in all three languages → i64 (and unsigned 64-bit) round-trip without loss.

---

## Second-pass corrections (R14–R25)

> From the fan-out + 5-lens critique. Each is grounded in a VERIFIED experiment or file:line. These
> supersede the first-pass text where they conflict. Confirmations: **R4** (result tuple), **R11** (pure
> value threading works with no process — sequenced direct calls kept old/new state correctly) are
> CONFIRMED by experiment; **R2** resolves to *uniformly n+1* (see R19).

**R14 — Module identity is `twocore@wasm@<base>`, not the file stem.** `lower.gleam:284` bakes
`name = "twocore@wasm@" <> sanitize(first-func-export)` (or `…@anon`); `emit_core` bakes it verbatim;
`core_to_beam` **ignores its `mod` arg** (the atom is the `.core` header). So the `.beam` is written as
`<module.name>.beam` = `twocore@wasm@<base>.beam` (so it auto-loads by module name on the code path), the
binding dispatches to that exact atom, and `Iface.module_name` carries it unnormalized. **Every concrete
name in the specs is wrong** ("app.beam", "twocore@math", ":app", "my_mod") — fix the examples. (Phase-11
`--link` can rename the module for a cleaner/self-contained artifact — R8/R21.)

**R15 — Host names are sanitized, collision-resolved DATA in the keystone.** `ExportSig` gains two
fields: `dispatch_atom` (exact `ExportFn.export_name`, used verbatim in `@external`/`apply`) and
`host_name` (a deterministic language-legal identifier). The rule (owned by P12-01, not emitter-local):
(a) sanitize to each language's identifier grammar — Gleam is `[a-z][a-z0-9_]*`, no `@`, no leading
digit, no keyword (a WASM base can be `"0"`, e.g. Porffor `(export "0")`); (b) **reserve** the generated
API/helper/type names (`instantiate`, `rescue`, `raw_instantiate`, `Instance`, `Trap`, `i32_to_raw`, …)
so an export literally named `instantiate` is disambiguated; (c) resolve inter-export collisions
deterministically. The binding **module** name is derived legally too (NOT `twocore@wasm@add_bindings` —
illegal Gleam). *Verified: keyword/dash/leading-digit/uppercase/duplicate names all fail `gleam build`.*

**R16 — Cross-language binding-module atoms must be distinct (or purged).** The Erlang binding
`divs_bindings` and a Gleam binding sanitized to `divs_bindings` are the SAME BEAM atom; the capstone
loads all three into ONE VM → the second load clobbers the first → the wrong-language binding runs
silently (false green — *observed*). Fix: language-tag the binding module atoms
(`<base>_gleam_bindings` / `<base>_erl_bindings` / an Elixir namespace) **or** the capstone
`code:purge`/`code:delete`s each binding module between per-language differential runs.

**R17 — `describe/2` runs on the LOWERED + OPTIMIZED module (fixes P12-05; sharpens R1).** P12-05's flow
feeds `describe` the un-lowered `source_to_ir` module, but `emit_core` computes `fn_state_reaching` on the
module `ir_to_core` lowers+optimizes internally. A divergence misclassifies a mutation-carrying export as
pure → the binding drops `St'` (lost writes) with **no crash** (arity is n+1 either way). Fix: the CLI
does `lower_ir → optimize_ir` **once** and hands that ONE module to BOTH `describe` AND
`emit_module`/`print_module`/`core_to_beam` (do **not** also call `ir_to_core`, which re-lowers) — add a
pipeline seam returning `#(lowered_module, core_text)`. P12-05's ownership must add
`lower_ir`/`optimize_ir`/`emit_module`/`print_module`. **R2's arity freeze-test is insufficient** to
catch a `touches_state` error (pure and stateful are both n+1) — test the *return shape* / a value-level
dropped-mutation differential instead.

**R18 — Non-finite floats: the default float result is a SUM TYPE, not plain `Float`.** `<<F:64/float>>
= <<Bits:64>>` **raises** on NaN/±Inf (verified, OTP 29), and per R7 that decode is *outside* the
trap-catch → an uncaught host exception + a D5 bit-identity violation. Fix: float results present as
`Finite(Float) | NonFinite(BitArray)` (Gleam) / a tagged tuple (Erlang/Elixir), guarded on the all-ones
exponent. Native `Float` is used only on the guaranteed-finite path. The raw-bits accessors are
**bidirectional** (`f32_of_bits`/`f64_of_bits` for args; `f32_bits`/`f64_bits` for results). The codec
width comes from the `ExportSig` `ValType` (TF32⇒32, TF64⇒64), **never** `host_types` (both say `Float`).
*Verified D5-safe, no change needed:* `-0.0` sign preserved, signed-int round-trip, v128 16-byte LE, refs
opaque.

**R19 — The Stateless/Threaded two-shape host API (resolves R2 ↔ R3/P3).** The `.beam` ABI is
**uniformly n+1** under a Threaded build — even a genuinely-pure export gets a `fun(St,A…) -> {apply
'g'/n(A…), St}` adapter (verified: `pure_t` exports `[{add,3},{instantiate,0}]`). So the binding *always*
threads `St` internally; `StateModel`/`touches_state` govern only the HOST surface:
- **`StateModel = Stateless`** (whole-module state-reaching closure empty): **no `Instance`, no
  `instantiate`** in the surface — each export is `fn(args) -> Result(T, Trap)`, internally
  re-instantiating per call (cheap and correct for a stateless module). *The beautiful pure file.*
- **`StateModel = Threaded`**: `instantiate() -> Result(Instance, Trap)`; every export takes `inst`;
  `touches_state` exports return `Result(#(T, Instance), Trap)`, others return `Result(T, Trap)` (take
  `inst`, discard the unchanged `St'`). This confines the `#(T, Instance)` noise to state-reaching calls.

**R20 — Reject mutable memory/table tiers under `--bindings`.** A Threaded build with `Atomics`/`Nif`/
`Ets` (reachable via `--threaded --tier atomics --cap N`; `link/1` does not reject it) emits a
"pure-value-threaded" binding over **aliased mutable** memory — the value semantics is a lie (an old
`Instance` observes new writes). Fix: `describe/2` gains `MutableTierUnsupported`; `--bindings` requires a
pure-value tier (`Paged`/`TablePaged`) this phase. The common `--threaded --bindings` default is `Paged`
(safe), so this is an unguarded sharp edge, not a default-path bug.

**R21 — The un-linked binding is NOT self-contained (docs + hard tie to Phase 11).** The compiled `.beam`
transitively calls `twocore@runtime@*` + `gleam@*` (verified undef chain: `seed_fuel` → `gleam@int:min`
→ works only with `twocore` + `gleam_stdlib` + `gleam_erlang` ebins on the path). `docs/phase-12-bindings.md`
must state the hard runtime dependency; a **droppable, self-contained** artifact requires Phase-11
`--link`. Do not claim "portable" for the un-linked artifact.

**R22 — Gleam is a two-file drop, both under the consuming project's `src/`; emit a usage README.** Gleam
discovers native `.erl` FFI tree-wide under `src/` (not sibling-based); `--out` is a staging folder, not a
source root. `<base>_bindings.gleam` **and** `<base>_bindings_ffi.erl` both go under the user's `src/`.
The Gleam catch-shim matches `error:{wasm_trap,_}` structurally (R7), never a bare catch-all (a catch-all
masks an arity/undef emitter bug as a fake trap). Resolves overview open-seam #5 = **yes, emit a README**.

**R23 — Elixir avoids the Elixir-runtime dependency.** Catch `:error, {:wasm_trap, kind}` (Erlang-style),
NOT `rescue e in ErlangError` (which pulls `Elixir.Exception:normalize/3` — verified it `undef`s without
the Elixir stdlib ebin on the VM). Generate Elixir bindings with zero `Elixir.*` runtime deps where
possible; the capstone's Elixir arm adds the resolved Elixir ebin to the code path when loading.

**R24 — Narrow trap-catch; WASM `throw` is out-of-surface this phase.** `RunResult` has a third variant
`UncaughtException(tag_id, payload)` (Phase-7 WASM `throw`, a distinct term class) that a `{wasm_trap,_}`
catch does **not** intercept → it escapes the binding. Honest-scope: WASM-exception-throwing exports are
outside the typed-error surface this phase (document it); the trap differential uses a genuine trap
(div-by-zero / OOB), not a `throw`.

**R25 — Process/harness.** (a) Determinism asserts byte-identity of `GeneratedFile.content` **in memory**
(not compiled `build/` outputs, which carry metadata); helpers emitted only-when-referenced in canonical
order; export order = `Iface` declaration order; language order Gleam < Erlang < Elixir; no Set-derived
iteration. (b) Pull the shared shell-out+load FFI **forward** (a small P12-01 companion) so the Wave-A
emitter units can compile+call in their own DoD (not duplicate mini-FFIs, not block on the capstone);
compile **once** per (language × module), call many exports (toolchain spawn is slow). (c) **R10 sharpen:**
`call_instance_terms` does **not** exist — the term-ABI oracle is `start_instance/1` + `call_instance/3` +
`result_list/2` + `stop_instance/1` in `test/twocore_conformance_ffi.erl`.
