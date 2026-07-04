# Phase 12 — Typed host-language bindings (Erlang / Elixir / Gleam)

> **Status:** scoped, awaiting review. No code yet. Follows the fixed skeleton in
> [`../03-phase-workflow.md`](../03-phase-workflow.md) §2. Decisions are `P1–P8` (the letter series
> continues from Phase 11's `O`; `P1` = keystone, `P8` = honest scope); **units** are `P12-01 … P12-06`
> (separately numbered).
>
> **All prior-phase decisions and the permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8)
> still hold.** Baseline entering: 1827 tests / 0 fail · `gleam build` zero warnings · `gleam format`
> clean · WASM conformance 46,529 / 1,768 / 0 (Safe ≡ Unsafe, every tier). *(Phase 11 `--link` is
> independent and may land before or after this.)*
>
> **⚠ [`RECONCILIATION.md`](RECONCILIATION.md) is AUTHORITATIVE and OVERRIDES this overview on conflict.**
> Two reconciliation passes (R1–R25). First pass (authoring): `StateModel = Stateless | Threaded` (R3);
> `instantiate -> Result` (R5); results are a **tuple** not a list (R4); `--bindings` requires `--threaded`
> (R12). Second pass (fan-out + critique, which **compiled + called all three languages** on OTP 29):
> `describe` on the **lowered** module (R17); non-finite floats are a **sum type** `Finite|NonFinite`, plain
> `Float` raises on NaN/Inf (R18); the **Stateless/Threaded two-shape API** (R19); the module atom is
> `twocore@wasm@<base>`, not the file stem (R14); host-name sanitization + cross-language atom collision
> (R15/R16); reject mutable tiers under `--bindings` (R20); un-linked bindings need the twocore runtime on
> the path — self-contained requires Phase-11 `--link` (R21). Read order: this overview →
> `RECONCILIATION.md` → the unit doc.

---

## §0. Where this phase sits

This is a **backend / developer-experience** phase. It does **not** touch the frontend, the IR, the
optimizer, or any runtime *semantics*. It adds a new backend capability: after compiling a module to a
`.beam`, emit **companion host-language source files** — a `.gleam`, an `.erl`, and an `.ex` — that give
a **typed, ergonomic API** to instantiate the module and call its exports from Erlang, Elixir, or Gleam.

Today the only way to call a compiled export is the raw run-ABI ([`../01-status.md`](../01-status.md) §5,
`pipeline.gleam`): **arguments and results are raw unsigned bit patterns as Erlang integers** — an i32
`-1` arrives as `4294967295`, an f64 arrives as its raw IEEE-754 bits-in-an-integer, multi-value results
are a bare list, and a trap is an uncaught BEAM exception. That is correct but hostile. Phase 12 wraps it
in **native types with conversion glue**: `Int`/`Float`/`BitArray`, traps as `Result`, one typed function
per export — the "beautiful `.gleam` file with the exports typed for me."

It **composes with Phase 11 `--link`** (a self-contained `.beam` + typed bindings = a portable artifact
you can drop into any BEAM project and call type-safely) but does not require it. It is the second half of
the deployment story `01-status.md` §5 describes.

---

## §1. Goal & acceptance

**Goal.** Given a compiled module, emit — into an output folder, one file per requested language — a
**typed binding** whose surface is native host types, that instantiates the module and calls each export
with WASM types mapped to host types, surfaces traps as language-idiomatic errors, and hides the
raw-bit-pattern value convention behind conversion glue. The `.beam` itself is **unchanged** (the
bindings are companions).

**Acceptance table** (owned by the capstone, P12-06):

| Area | Must demonstrate |
|---|---|
| Gleam headline | `to-beam-wasm --threaded --bindings gleam --out ./out math.wasm` writes the `.beam` (named after the baked module atom `twocore@wasm@<base>.beam`, R14) + a typed Gleam binding (host module name sanitized-legal, R15); a hand-written Gleam program `import`s it (both `.gleam` + the `.erl` catch-shim placed under its `src/`, R22), calls a typed export, and gets the correct native value — **compiled by the real Gleam toolchain**. (`--threaded` required — R12; the un-linked `.beam` needs the twocore runtime on the path — R21.) |
| Compile + call (per language) | For each emitted language, the binding **compiles** with that language's toolchain and calling an export through it returns a value **identical** (by native value, incl. trap behavior) to the in-process pipeline. |
| Type fidelity | i32/i64→native int, f32/f64→native float (round-tripped through raw IEEE bits, f32 single-rounded), v128→16-byte binary, funcref/externref→opaque, multi-value→tuple — verified for a program exercising each. |
| Traps surfaced | An export that traps returns the language's error idiom (`Result`/tagged tuple), never a raw uncaught exception leaking the internal `{wasm_trap,…}` term. |
| Default unaffected | Emitting bindings does not change the `.beam` or any existing output; `gleam test` + conformance stay green. |
| Deterministic | Identical input → byte-identical binding files (stable ordering, no timestamps). |

**Honest scope** (= decision P8, restated in §2):
- **Threaded (tier-P) modules only, this phase.** The value-threaded functional model needs no generated
  process infrastructure and is the "beautiful pure file." **Cell (tier-O, stateful) → a process-wrapped
  server binding is deferred** to a follow-up.
- **Export-only.** Import-bearing modules (`instantiate/1(Imports)`, needing providers at instance time)
  are **link-time rejected** this phase (as Phase 11 does) — a typed provider surface is a follow-up.
- **`funcref`/`externref` are opaque passthrough** — the binding exposes an opaque handle, not
  cross-language function construction.
- **Erlang + Gleam are tested in-tree** (both toolchains are present — Erlang *is* the BEAM, Gleam is the
  project's own); **Elixir is best-effort**, gated on `elixir` being on `PATH` (else its compile+call
  differential is a categorized skip, never a false green).
- Bindings expose the module's exports; they do **not** re-implement WASM semantics. No async/streaming.
- No change to default emission, the IR, the optimizer, or runtime semantics.

---

## §2. Decisions (P1–P8)

> Each decision is **frozen** for this phase. If you believe one is wrong, **raise it with the planner
> BEFORE building — do not silently diverge.** By convention P1 is the keystone; P8 is honest scope.

**P1 (keystone) — A language-neutral Interface Descriptor is the single source every emitter renders.**
From the IR `Module` + the runtime `Binding`, compute `Iface`: the module's atom name, the state model
(import-free / threaded — cell rejected this phase), and, per export, its name, its WASM `FuncType`
(param + result value-types), and whether it reads/mutates instance state (from `emit_core`'s
`expr_touches_state`). Emitters never re-derive from the IR; they render `Iface`. This is the
load-bearing new thing.

**P2 — The value-ABI is raw unsigned bit patterns; the binding presents native types with conversion
glue.** Verified (`pipeline.gleam`): the BEAM ABI is raw unsigned integers (floats as raw IEEE bits).
The frozen mapping + boundary conversion:

| WASM type | Gleam | Erlang `-spec` | Elixir `@spec` | Boundary conversion (native ⇄ raw-ABI) |
|---|---|---|---|---|
| i32 / i64 | `Int` | `integer()` | `integer()` | **signed** two's-complement ⇄ raw unsigned bit pattern (host ints are bignums, so no width loss) |
| f32 / f64 | `Float` | `float()` | `float()` | native float ⇄ raw IEEE bits via `<<F:32/float>>`/`<<F:64/float>>` (f32 single-rounded) |
| v128 | `BitArray` | `binary()` (16 B) | `binary()` | identity (16 raw little-endian bytes) |
| funcref / externref | opaque `Ref` | `term()` | `term()` | opaque passthrough (the `rt_ref` box) |
| multi-value results | tuple | tuple | tuple | positional, in declaration order |
| (a trap) | `Result(_, Trap)` | `{ok,_} | {error,Trap}` | `{:ok,_} | {:error,Trap}` | catch the `rt_trap` exception at the boundary |

Integers are presented **signed** (what a host programmer expects from "i32"), documented as a
presentation choice — the module itself is sign-agnostic on the bits.

**P3 — The instance model: value-threaded, typed, pure (threaded/tier-P).** `instantiate() -> Instance`
wraps the module's `instantiate/0` result (the tier-P `InstanceState` record). A **state-touching**
export threads the instance: `fn export(inst, args…) -> Result(#(results, Instance), Trap)`; a
**state-free** export is pure: `fn export(inst, args…) -> Result(results, Trap)` (or drops `inst`
entirely — see open seam). Traps become the language's error idiom (P2). No process is spawned — the
"beautiful pure functional file." (Cell's process-wrapped server model is P8-deferred.)

**P4 — Bindings are SOURCE files (companions), never embedded.** Human-readable, checked-in-able,
type-checked by the host toolchain; the `.beam` is untouched. Written into an output folder alongside
the `.beam`. Composes with Phase 11 `--link` (self-contained `.beam` + typed bindings).

**P5 — Each emitter is idiomatic and carries the full type surface.** Gleam: typed `pub fn` + `Result` +
`@external` declarations + `///` doc comments (the headline). Erlang: `-spec` + edoc `-doc`, exported
functions (+ an `.hrl` only if it earns its place). Elixir: `@spec` + `@doc`, a module with the conversion
glue. All three are Dialyzer/typespec-visible and carry the P2 conversions.

**P6 — CLI + folder output, deterministic.** `--bindings <langs>` (comma list of `gleam`/`erlang`/
`elixir`) + `--out <dir>` on `to-beam-wasm`; writes the `.beam` + one binding file per language into
`<dir>`. Absent ⇒ today's behavior unchanged. Output is deterministic (stable export ordering, no
timestamps/paths). Composes with `--link`.

**P7 — Correctness = COMPILE + CALL differential, not golden change-detectors.** For each language:
generate the binding → compile it with the real toolchain (`gleam build` / `erlc` / `elixirc`) → call an
export through it → assert the native result (and trap behavior) is identical to the in-process pipeline
oracle. Golden-string tests are explicitly avoided (they lock in output, not correctness — CLAUDE.md /
D8); a printer may keep a *small* spec-grounded golden but "done" is "it compiles and the call matches."

**P8 — Honest scope.** As §1: threaded/tier-P only (cell/process-wrapped deferred); export-only
(import-bearing rejected); refs opaque; Erlang+Gleam tested in-tree, Elixir best-effort (skip-if-absent,
categorized); no re-implementation of WASM semantics; no change to default emission/IR/optimizer/runtime.

---

## §3. Dependency DAG & freeze milestones

```
   P12-01 keystone ──«IFACE-DESC-FROZEN»──┬──▶ P12-02 Gleam emitter ─┐
   (Iface descriptor + value-ABI mapping   │──▶ P12-03 Erlang emitter ├─▶ P12-06 capstone
    + conversion-glue spec + emitter sig)   │──▶ P12-04 Elixir emitter │   (compile+call differential
                                            └──▶ P12-05 CLI + folder out ┘    × langs × types, docs)
```

**Freeze milestone:**

| Milestone | Produced by | Unblocks |
|---|---|---|
| `«IFACE-DESC-FROZEN»` — the `Iface`/`ExportSig`/value-type mapping types, `describe(module, binding) -> Iface`, the `GeneratedFile(path, content)` type, and the **uniform emitter signature** `emit_<lang>(Iface) -> List(GeneratedFile)` (so all three emitters + the CLI build against one contract) | P12-01 | P12-02, P12-03, P12-04, P12-05, P12-06 |

**Waves.** Wave 0: P12-01. Wave A: P12-02 / P12-03 / P12-04 (three sibling emitters, parallel) + P12-05
(CLI, against the frozen emitter sig). Wave B: P12-06.

**Open seams for the scoping fan-out / critique to resolve** (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §1 steps 2–3):
1. **State-free export shape:** does a pure export keep the `inst` parameter (uniform signature) or drop
   it (prettier, but a mixed API)? P3 leans "thread only when it touches state" — confirm ergonomics.
2. **The `Instance` handle for threaded builds:** is it an opaque wrapper around the `InstanceState`
   record (pure value threading), and how does each language type it (Gleam `opaque type`, Erlang opaque
   `term`, Elixir struct)? Confirm the record can be handed across the FFI boundary safely.
3. **`.beam` module-name coupling:** the binding calls `'<module>':'<export>'(…)`; must the binding know
   the exact loaded module atom (from `Iface.module_name`), and does that compose with Phase-11 `--link`
   renaming? (The `Iface` should carry the final module atom.)
4. **Elixir test gating** — confirm the skip-if-`elixir`-absent policy and how the harness detects it.
5. **Should the CLI also emit a tiny README / usage snippet per language?** (Nice-to-have; scope call.)

---

## §4. File-ownership map (one owner per file, D1)

| Unit | Owns / creates | Deliberate cross-file reaches |
|---|---|---|
| **P12-01** keystone | new `src/twocore/backend/iface.gleam` (`Iface`/`ExportSig`/`GeneratedFile`/value-type mapping + `describe/2` + the frozen `emit_<lang>` signature shape); `test/.../iface_freeze_test.gleam` | reads `ir` (FuncType/ValType), `runtime/instance` (Binding/state_strategy), and `emit_core`'s `expr_touches_state` (may need it exposed) |
| **P12-02** Gleam emitter | new `src/twocore/backend/emit_gleam_bindings.gleam` | — |
| **P12-03** Erlang emitter | new `src/twocore/backend/emit_erlang_bindings.gleam` | — |
| **P12-04** Elixir emitter | new `src/twocore/backend/emit_elixir_bindings.gleam` | — |
| **P12-05** CLI + driver | `src/twocore.gleam` (`--bindings`/`--out`); a folder-output entry in `backend/build_beam.gleam` (or a new `backend/bindings.gleam` orchestrator) | reads the three `emit_<lang>` entries; composes with the Phase-11 `--link` path if present |
| **P12-06** capstone | `test/.../bindings_compile_call_test.gleam` (the per-language compile+call harness + FFI to invoke `gleam build`/`erlc`/`elixirc`); `docs/phase-12-bindings.md`; updates `../01-status.md` §5 | the single status/wiring point only |

---

## §5. How to claim & complete

Standard loop ([`../03-phase-workflow.md`](../03-phase-workflow.md) §7 + §9): read
[`../state.md`](../state.md); claim a unit; for P12-01 freeze `«IFACE-DESC-FROZEN»` and land green with
no change to default output; build the emitters/CLI behind the frozen signatures; satisfy the per-unit
Definition of Done (spec-cited compile+call tests, doc comments, `gleam format --check` clean, `gleam
build` zero warnings, the unit's suite green); update `state.md`. The capstone (P12-06) proves the
acceptance table by compiling + calling each binding, then this phase is compacted into
[`../01-status.md`](../01-status.md) and `phase-12/` removed.

> **Next step (recommended, per the methodology):** a scoping fan-out + adversarial critique before
> freezing — the value-ABI conversions (signed/unsigned, f32 rounding, i64 boundary), the threaded
> `Instance` handoff across the FFI, and the per-language compile-harness are exactly the areas a
> critique should pressure-test (as the Phase-11 critique caught the `fun`-capture blocker).
