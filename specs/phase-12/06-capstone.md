# P12-06 — Capstone: the compile+call differential (PHASE 12 PROVEN)

> **Status:** scoped, awaiting review. **Owner:** P12-06 (the capstone — the LAST unit; the only one that
> edits the single status/wiring point). **Depends on freeze:** `«IFACE-DESC-FROZEN»` (P12-01) + all three
> emitters (P12-02/03/04) + the CLI (P12-05) landed green. **Freezes nothing** (capstones prove, they do
> not publish interfaces). Read order: [`00-overview.md`](00-overview.md) → this doc. All prior-phase
> decisions and the permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) hold.

---

## §1. Goal

Prove the [`00-overview.md`](00-overview.md) **§1 acceptance table** empirically, by the **compile+call
differential** decision **P7**: for each emitted language, *generate* the binding → *compile* it with the
**real toolchain** (`gleam build` / `erlc` / `elixirc`, shelled out) → *call* representative exports
through the compiled native surface → assert the native result **and trap behavior** are **identical** to
the in-process pipeline **oracle** (`pipeline.run_source` / `instantiate` + `invoke_instance`). This is the
step §5 of the workflow calls "PHASE N PROVEN": not golden-string change-detectors (D8), but "it compiles
with that language's own compiler *and* the call matches the oracle."

Implements / proves: **P2** (the value-ABI mapping — signed int round-trip, f32/f64 raw-IEEE round-trip,
v128 binary, multi-value tuple, trap→error idiom), **P3** (the threaded/tier-P `Instance` value-threading
model), **P5** (each emitter is toolchain-valid, not just string-plausible), **P6** (deterministic folder
output composing with `--link`), **P7** (this differential *is* the correctness definition), **P8** (Erlang
+ Gleam in-tree; Elixir best-effort skip-if-absent, categorized — never a false green). The `.beam` and all
existing output stay **byte-identical**; the whole prior suite + WASM conformance stay green.

---

## §2. Depends on / Produces

**Depends on (frozen signatures only, never sibling bodies):**
- `iface.describe(module, binding) -> Result(Iface, IfaceError)` and the `GeneratedFile(path, content)`
  type (P12-01, `src/twocore/backend/iface.gleam`).
- `iface.emit_gleam/emit_erlang/emit_elixir(Iface) -> List(GeneratedFile)` (P12-02/03/04).
- The P12-05 CLI/orchestrator entry (whatever `backend/bindings.gleam` exposes to write the file set) — the
  capstone drives generation through the **same** entry the CLI uses, so it proves the shipped path.
- **The oracle:** `pipeline.run_source(wasm, binding, export, args)`, and the lower-level
  `pipeline.core_to_beam` / `instantiate` / `invoke_instance` / `stop_instance` (`src/twocore/pipeline.gleam`).
- `profiles.portable()` — the tier-P `Threaded` runs-anywhere `Binding` (this phase's only state model).

**Produces (owned files, D1):**
- `test/twocore/backend/bindings_compile_call_test.gleam` — the per-language compile+call harness.
- `test/twocore_bindings_ffi.erl` — a small **test-only** shell-out/loader FFI (namespaced `twocore_`,
  hand-written Erlang, under `test/`), mirroring `twocore_conformance_ffi.erl`'s port pattern.
- `docs/phase-12-bindings.md` — the phase's user-facing "how to emit + use a typed binding" doc.
- The `../01-status.md` §5 update: fold the phase in, then **remove `specs/phase-12/`** on proof.

**Leaves:** nothing downstream — this is the phase's terminal unit.

---

## §3. What it owns + design

### D1 — files & the toolchain shell-out FFI

`twocore_conformance_ffi.erl` already gives the exact port-spawn pattern to shell out (`run/2`:
`open_port({spawn_executable, Exe}, [{args,_}, exit_status, stderr_to_stdout, binary, hide])` →
`collect/2`) and `find_executable/1` (graceful skip when a tool is absent). We **do not** touch that
file (D1); we own a sibling `twocore_bindings_ffi.erl` with just the extra host capabilities the harness
needs beyond the conformance FFI:

```erlang
%% test/twocore_bindings_ffi.erl  (test-only; twocore_ prefix; touches no unit-owned source)
-module(twocore_bindings_ffi).
-export([mkdtemp/0, write_file/2, run/3, find_executable/1, load_beam_file/2]).

mkdtemp() -> ...            %% unique scratch dir under the OS temp root -> {ok, DirBin}
write_file(Path, Bytes) -> file:write_file(Path, Bytes)      %% ok | {error, Reason}
run(Program, Args, Cwd) -> ...   %% like conformance run/2 but with a {cd, Cwd} port opt;
                                 %% -> #{exit := Int, output := Bin} as {Int, Bin}
find_executable(Name) -> ...     %% {ok, PathBin} | {error, <<"not found">>}
load_beam_file(ModAtom, Path) -> %% read Path, code:load_binary(ModAtom, ..., Bytes)
    ... -> {ok, ModAtom} | {error, RenderedReason}
```

Thin Gleam bindings live in the test module (or a tiny `bindings_ffi.gleam` helper); every binding is
total, returning a typed `Result`. **Why a shell-out FFI at all:** compiling a `.gleam`/`.erl`/`.ex` with
its *own* compiler is the only honest proof that the emitter's type surface (P5: `-spec`/`@spec`/typed
`pub fn`) is real — an in-process string check cannot catch a mistyped spec.

### The oracle vs. the native call (the differential)

For one `(wasm_fixture, export, args)` case the harness computes two values and asserts equality:

```
ORACLE (in-process, the D5 raw-bit ABI):
  pipeline.run_source(wasm, profiles.portable(), export, raw_args) -> RunResult
    Returned(values)  -- raw unsigned bit-pattern integers (i32 -1 => 4294967295; f64 => IEEE bits)
    Trapped(reason)   -- rendered BEAM error text

NATIVE (through the compiled binding, the P2 native ABI):
  1. wasm -> ir (source_to_ir) -> iface.describe(ir, profiles.portable())   [Threaded => ok]
  2. core_to_beam(ir_to_core(ir, portable())) -> the module .beam; load it (module_name = ir.name)
  3. generate files = emit_<lang>(iface); write them into a fresh mkdtemp scratch project
  4. compile with the real toolchain (see §4); load the binding .beam (+ the catch-shim .erl .beam)
  5. apply the binding's typed export fn with NATIVE args -> a native Result term (read as Dynamic)

ASSERT: decode the native term back to raw bits and compare to the oracle bit-for-bit (D5/D7):
  - native Ok(int)      => two's-complement re-encode to unsigned  == oracle Returned([bits])
  - native Ok(float)    => <<F:32/float>> / <<F:64/float>> re-encode == oracle Returned([bits]) (f32 1-rounded)
  - native Ok(binary)   => the 16 bytes                             == oracle v128 bytes
  - native Ok({a,b,..}) => each element re-encoded, positional      == oracle multi-value list
  - native Error(trap)  => oracle is Trapped(_)  (both trap; neither leaks a raw {wasm_trap,_} exception)
```

The equality is **by bit pattern** (invariant D5/D7), so any sign, rounding, or width divergence in a
conversion is caught. The native side is where P2's conversion glue is exercised *round-trip* (native→raw
by the harness re-encode, raw→native by the binding), so a wrong `<<F:32/float>>` on either side fails.

### Threaded state model (P3)

For a **state-touching** export the binding surface threads the instance:
`export(inst, args…) -> Result(#(results, Instance), Trap)`. The harness: `inst0 = <lang>.instantiate()`
→ call the export → assert `Ok(#(results, inst1))`, then optionally call again on `inst1` and assert
state persisted — compared against the oracle driving the **same** two invokes through one live
`InstanceProc` (`instantiate` once, two `invoke_instance` calls). A **state-free** export need not thread
(per P3 / open-seam-1, whatever P12-01 froze) — the harness reads `ExportSig.touches_state` to pick the
expected shape, so it tests exactly the surface the emitter produced.

### Elixir gating (P8, open-seam-4)

`find_executable("elixir")` / `find_executable("elixirc")`: `Error(_)` ⇒ the Elixir cases are a
**categorized skip** (counted + reported as "skipped: elixir absent"), **never** silently passing and
never asserting `True`. Erlang (`erlc`, always present — it *is* the BEAM) and Gleam (`gleam`, the
project's own toolchain) are **required** in-tree.

---

## §4. The work (ordered, buildable)

1. **Own the FFI.** Write `test/twocore_bindings_ffi.erl` (§3 D1) + total Gleam bindings. Reuse the
   conformance port pattern verbatim; add `{cd, Cwd}` so each toolchain runs in its own scratch dir.
2. **Case fixtures.** Curate a small `.wasm` corpus (reuse `test/twocore/conformance/corpus/` +
   hand-authored `.wat`→`.wasm` where a type is missing) covering the **type matrix**: i32 signed
   incl. **negative** (e.g. `sub` yielding `-1`), i64 (a value > 2^32), f32 **and** f64 round-trip
   (incl. `-0.0` and a NaN payload — D5), v128 (16-byte identity), a **multi-value** export (a
   `(i32,i32)` or Porffor-style `(f64,i32)` return → tuple), and a **trapping** export
   (`i32.div_s` by 0 / an OOB load). Plus one **state-touching** export (a global-mutating counter or a
   memory store+load) for the threaded model.
3. **Oracle helper.** `oracle(wasm, export, raw_args) -> RunResult` via `pipeline.run_source(_,
   profiles.portable(), _, _)` — the single source of truth (never re-derive expected bits by hand except
   for the spec-anchored sanity assertions).
4. **Per-language compile step** (one function each, all behind `find_executable` gating):
   - **Gleam:** write a minimal scratch project (`gleam.toml` + `src/<binding>.gleam` + a tiny
     `src/<probe>.gleam` that calls the export and returns its result), `run("gleam", ["build"], Dir)`,
     then load the compiled `build/dev/erlang/<pkg>/ebin/*.beam` (the binding + probe). The binding's
     `@external` module + the runtime are already resident in the test VM.
   - **Erlang:** `run("erlc", ["-o", Out, BindingErl, CatchShimErl], Dir)`; load both `.beam`; apply
     `'<binding_mod>':'<export>'(...)`.
   - **Elixir:** `run("elixirc", ["-o", Out, BindingEx], Dir)` (skip-if-absent); load + `apply`.
   Each returns `Error` with the captured compiler stderr on a non-zero exit (a compile failure is a
   **test failure**, not a skip — that is P5's teeth).
5. **The differential assertions** (§3): one gleeunit `_test` per (language × matrix-type), plus the
   threaded-model test and the trap test. Decode native → raw, compare to oracle bit-for-bit.
6. **Determinism test** (P6): generate the file set **twice** for the same input; assert the `content`
   of every `GeneratedFile` is **byte-identical** (stable export ordering, no timestamps/paths).
7. **Composition-with-`--link` smoke** (P6, if Phase-11 `--link` is present): generate bindings for a
   linked/renamed module and assert the binding calls the **final** module atom (`Iface.module_name`),
   so the call still resolves. If `--link` is absent in the tree, note it and skip.
8. **Regression gate.** Run the full `gleam test` + WASM conformance; assert the default `.beam` is
   unaffected (no binding = no files; §1 "Default unaffected"). Capstones **confirm** green, they don't
   re-derive prior units.
9. **Docs + status.** Write `docs/phase-12-bindings.md` (emit + use a typed binding, per language, with
   the P2 mapping table and the P3 threaded shape). Update `../01-status.md` §5 to add the typed-binding
   deployment story, compact the phase into §3, and **remove `specs/phase-12/`** on proof.

---

## §5. Tests (spec-cited + adversarial)

Every test is a **compile+call differential** (P7), not a golden. Spec anchors: the value semantics come
from the [WebAssembly spec](https://webassembly.github.io/spec/) numeric/reference sections; the boundary
mapping from P2; equality by bit pattern from D5/D7.

- **Compile+call, per language × per type** (the matrix): i32 negative (`f(2,3) with sub == -1`; native
  `Ok(-1)` re-encodes to `4294967295` == oracle), i64 (> 2^32 survives — host bignum), **f32** and **f64**
  round-trip (native `Float` re-encoded via `<<F:32/float>>`/`<<F:64/float>>` equals oracle IEEE bits; f32
  is single-rounded), v128 (16-byte binary identity), multi-value (native tuple, positional, == oracle
  list). Each: the binding **compiles** with its own toolchain (fail ⇒ test fail) **and** the call matches.
- **Trap case** (P2 trap idiom): a trapping export returns the language error idiom — Gleam
  `Error(_)` / Erlang `{error,_}` / Elixir `{:error,_}` — and **never** leaks a raw uncaught
  `{wasm_trap,_}` term (assert the returned term is the tagged error, not an exception escaping the
  binding). Oracle is `Trapped(_)`. This is what makes the Gleam/Elixir **catch-shim** (`.erl`) load-bearing:
  the test proves those bindings actually catch the BEAM exception at the boundary.
- **Threaded state model** (P3): a state-touching export, called twice, threads `Instance` and observes
  persisted state; compared to two `invoke_instance` calls on one oracle `InstanceProc`.
- **Determinism** (P6): generate twice ⇒ byte-identical `content` for every file.
- **Adversarial / must-NOT:**
  - **f32 double-rounding trap:** a value that differs under single- vs double-rounding — asserts the
    binding does **not** re-round an already-f32 value (bit divergence would be caught).
  - **Signed/unsigned boundary:** `0x8000_0000` (i32 most-negative as unsigned) round-trips to native
    `-2147483648` and back — proves the two's-complement presentation, not a raw pass-through.
  - **Trap must not become a value:** the trapping export must **not** return `Ok(garbage)` (a silent
    wrong value is the dangerous failure — assert it is an `Error`).
  - **Elixir-absent is a categorized skip, not a pass:** when `elixirc` is missing the Elixir cases are
    reported skipped, and the *Erlang+Gleam* cases still run and assert — no branch returns green without
    an assertion.
- **Regression:** the prior gleeunit suite + conformance stay green; the default (no-`--bindings`) `.beam`
  is byte-identical (spot-check one module's bytes with and without binding emission).

---

## §6. Definition of Done ([`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

**Per unit:** spec-cited compile+call tests (above), not change-detectors; `///` doc comments on every
public function + `////` on the FFI-binding module and the harness module (contract, not name-restatement);
`gleam format --check src test` clean; `gleam build` zero warnings; `bindings_compile_call_test` **passes**
(Erlang + Gleam required-green; Elixir green-or-categorized-skip).

**Per phase (the capstone bar):** the whole prior acceptance corpus + WASM spec suite stay green and
**result-identical** (by bit pattern, same traps) under both profiles and every `(state_strategy × mem_tier)`;
conformance `fail=0` with honest categorized skips; the §1 acceptance table demonstrated end-to-end (real
toolchain compile + matching call, per language); default output byte-identical; determinism proven. Report
the running gleeunit total. Then compact Phase 12 into `../01-status.md` and remove `specs/phase-12/`.

---

## §7. What it leaves (handoff)

Nothing to a downstream unit — Phase 12 closes here. It hands to the **project**: (1) a proven typed-binding
deployment path documented in `01-status.md` §5 and `docs/phase-12-bindings.md`; (2) the P8 **deferrals**
now moved into [`../02-roadmap.md`](../02-roadmap.md) — Cell/tier-O process-wrapped **server** bindings, a
typed **import/provider** surface (import-bearing modules are still link-rejected), cross-language
**funcref/externref construction** (still opaque passthrough), and async/streaming; (3) the reusable
`twocore_bindings_ffi.erl` compile+call harness pattern for any future emitter (a follow-up language, or the
deferred server binding, plugs into the same differential).
