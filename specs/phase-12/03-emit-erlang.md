# Phase 12 · P12-03 — The Erlang emitter (`emit_erlang`)

> **Status:** spec, unclaimed · **Owner:** one agent · **Depends on:** `«IFACE-DESC-FROZEN»` (P12-01) ·
> **Produces no freeze** (a sibling emitter, Wave A). Read order: `00-overview.md` (goal/shape) → this doc.
>
> All prior-phase decisions and the permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8)
> still hold. This unit is **additive** — a new backend module, no edit to the pipeline, no change to
> default emission (`gleam test` + conformance stay green; the `.beam` is untouched).

## §1 Goal

Implement `emit_erlang(iface: Iface) -> List(GeneratedFile)`: render one **hand-written-quality `.erl`
source file** that gives a typed, idiomatic Erlang API to instantiate a compiled module and call each of
its exports. The generated module exposes an opaque `instance()`, an `instantiate/0`, and one `-spec`'d +
`-doc`'d function per export, mapping WASM types to native Erlang types (P2) and surfacing a trap as a
tagged tuple `{ok, _} | {error, trap()}` (P2/P3).

Decisions this unit implements:
- **P1** — it is a pure *renderer of `Iface`* (`src/twocore/backend/iface.gleam`). It never re-derives
  anything from the IR; every fact it needs (module atom, per-export param/result `ir.ValType`s,
  `touches_state`) is already on the descriptor.
- **P2** — the frozen value-ABI mapping and boundary conversions (signed⇄raw-unsigned, float via
  `<<F:64/float>>`, v128 identity binary, refs opaque, multi-value→tuple, trap→`{error,_}`).
- **P3** — the value-threaded, pure instance model (tier-P / `Threaded` only): `instantiate/0` returns
  the opaque `instance()`; a state-touching export threads a new instance out, a state-free export does
  not. **No process is spawned** — the emitted code is a thin, pure functional wrapper.
- **P5** — idiomatic Erlang carrying the full type surface: `-spec` + edoc `-doc`/`-moduledoc` +
  `-opaque` on every export, Dialyzer-visible.
- **The catch-shim note (key differentiator):** unlike Gleam/Elixir, **Erlang catches a BEAM exception
  natively** (`try … catch error:… -> …`), so the trap→`{error,_}` mapping is done *in-language* inside
  the generated `.erl`. **No companion catch shim is emitted.** `emit_erlang` therefore returns a
  **single-element** `List(GeneratedFile)` — the list return is the *uniform* emitter signature (Gleam
  and Elixir need the second file), not a plurality this emitter uses.
- **P7 / P8** — correctness is proven by *compile-with-`erlc` + call* differential against the in-process
  oracle (not golden strings); scope is threaded/tier-P, export-only, import-free modules.

## §2 Depends on / Produces

**Depends on** (frozen signatures only, never sibling bodies):
- `«IFACE-DESC-FROZEN»` (P12-01, `src/twocore/backend/iface.gleam`): `Iface`, `StateModel`, `ExportSig`,
  `GeneratedFile`, and the emitter signature `pub fn emit_erlang(iface: Iface) -> List(GeneratedFile)`.
- `src/twocore/ir.gleam`: `ir.ValType` (`TI32 TI64 TF32 TF64 TV128 TFuncRef TExternRef TExnRef TTerm`) —
  read to pick a conversion per param/result.

**The run-ABI it targets is a FIXED CONTRACT** (grounded, do not re-invent):
- `src/twocore/pipeline.gleam` module doc + `src/twocore_cli_ffi.erl` `threaded_loop/2` — under `Threaded`
  every export is emitted at **arity `n+1`** with the `InstanceState` record threaded **leading** and
  returns the pair `{Package, St'}`. `instantiate/0` **returns** that record (a tuple tagged
  `instance_state`, matched by tag in `start_common/2`).
- `src/twocore/backend/emit_core.gleam` `function_return/1` (≈ line 4510) — the `Package` shape:
  `0` results → the atom `'ok'`; `1` result → the bare value; `N≥2` → an `N`-tuple `{V1,…,Vn}`. Even a
  **pure** export is exported at `n+1` via an adapting wrapper `fun(St, A…) -> {Value, St}` (emit_core
  §B.4, ≈ lines 417–432), so the binding *always* passes `St` leading and *always* destructures `{Pkg, St'}`.
- `src/twocore_rt_exn_ffi.erl` — a trap is raised at **error class** as `erlang:error({wasm_trap, Kind})`
  (`Kind` an atom). Import-free scope (P8) means no `{capability_denied,…}` and no host errors.

**Produces:** `src/twocore/backend/emit_erlang_bindings.gleam` (this unit's single owned file, D1) +
`test/twocore/backend/emit_erlang_bindings_test.gleam`. No freeze. Consumed by P12-05 (CLI wiring) and
P12-06 (the compile+call capstone).

## §3 What it owns + design

**D1 file:** `src/twocore/backend/emit_erlang_bindings.gleam`, sole public entry `emit_erlang/1`.

### The generated `.erl` shape

For `Iface(module_name, Threaded, exports)` the emitter renders **one** file. The binding module name is
derived deterministically from the `.beam` atom and **must differ** from it:
`base = last "@"-segment of module_name`; binding module = `base <> "_bindings"`; `path = <binding>.erl`.
All remote calls target the **real** `.beam` atom `module_name`, always **single-quoted** (it contains
`@`, e.g. `'twocore@math'`). Export names are arbitrary WASM strings → the binding function name and every
target function atom are **always single-quoted** (`'run-test'`), which also makes `-export`/head/`-spec`
legal for non-identifier names.

Sample: module atom `twocore@math` exporting `add : (i32,i32)->i32` (pure), `store : (i32,i32)->()`
(0-result, touches state), `divmod : (i32,i32)->(f64,i32)` (pure, multi-value + float):

```erlang
-module(math_bindings).
-moduledoc "Typed Erlang bindings for the compiled WASM module `twocore@math`.\n"
           "Generated by 2core (Phase 12). Values follow the WASM value-ABI (P2): integers are\n"
           "presented SIGNED, floats as native `float()`, v128 as a 16-byte binary.".

-export([instantiate/0, 'add'/3, 'store'/3, 'divmod'/3]).
-export_type([instance/0, trap/0]).

%% Opaque handle to a live instance: the module's `InstanceState` record, threaded as a value.
-opaque instance() :: tuple().
%% A WASM trap, surfaced as the raw error-class term so the caller can match the kind atom.
-type trap() :: {wasm_trap, atom()}.

-doc "Instantiate `twocore@math`: build a fresh instance (memory/globals/table). Pure — no process.".
-spec instantiate() -> instance().
instantiate() -> 'twocore@math':instantiate().

-doc "WASM export `add` : (i32, i32) -> i32. Pure (does not touch instance state).".
-spec 'add'(instance(), integer(), integer()) -> {ok, integer()} | {error, trap()}.
'add'(Inst, A0, A1) ->
    try 'twocore@math':'add'(Inst, enc_i32(A0), enc_i32(A1)) of
        {Pkg, _St} -> {ok, dec_i32(Pkg)}
    catch
        error:{wasm_trap, _} = Trap -> {error, Trap}
    end.

-doc "WASM export `store` : (i32, i32) -> (). Touches instance state: returns a NEW instance.".
-spec 'store'(instance(), integer(), integer()) -> {ok, instance()} | {error, trap()}.
'store'(Inst, A0, A1) ->
    try 'twocore@math':'store'(Inst, enc_i32(A0), enc_i32(A1)) of
        {_Pkg, St2} -> {ok, St2}
    catch
        error:{wasm_trap, _} = Trap -> {error, Trap}
    end.

-doc "WASM export `divmod` : (i32, i32) -> (f64, i32). Pure; multi-value result is a tuple.".
-spec 'divmod'(instance(), integer(), integer()) ->
    {ok, {float(), integer()}} | {error, trap()}.
'divmod'(Inst, A0, A1) ->
    try 'twocore@math':'divmod'(Inst, enc_i32(A0), enc_i32(A1)) of
        {{R0, R1}, _St} -> {ok, {dec_f64(R0), dec_i32(R1)}}
    catch
        error:{wasm_trap, _} = Trap -> {error, Trap}
    end.

%% ── value-ABI conversions (P2) — only the helpers the exports actually use are emitted ──
enc_i32(V) -> V band 16#FFFFFFFF.
dec_i32(B) when B >= 16#80000000 -> B - 16#100000000;
dec_i32(B) -> B.
dec_f64(B) -> <<F:64/float>> = <<B:64>>, F.
```

### The frozen conversions (P2), rendered as private helpers

| `ir.ValType` | arg encode (native→raw) | result decode (raw→native) | `-spec` type |
|---|---|---|---|
| `TI32` | `enc_i32(V) -> V band 16#FFFFFFFF.` | `dec_i32/1` (subtract `2^32` when `>= 2^31`) | `integer()` |
| `TI64` | `enc_i64(V) -> V band 16#FFFFFFFFFFFFFFFF.` | `dec_i64/1` (subtract `2^64` when `>= 2^63`) | `integer()` |
| `TF32` | `enc_f32(V) -> <<B:32>> = <<V:32/float>>, B.` (single-rounds) | `dec_f32(B) -> <<F:32/float>> = <<B:32>>, F.` | `float()` |
| `TF64` | `enc_f64(V) -> <<B:64>> = <<V:64/float>>, B.` | `dec_f64(B) -> <<F:64/float>> = <<B:64>>, F.` | `float()` |
| `TV128` | identity (bare `Ai`) | identity | `binary()` (16 B) |
| `TFuncRef`/`TExternRef`/`TExnRef` | identity (opaque box) | identity | `term()` |
| `TTerm` | identity | identity | `term()` |

Big-endian (`<<_:64>>` / `<<_:64/float>>` defaults) is deliberate: it yields the canonical IEEE-754
bit-pattern integer the runtime uses (`1.0` f64 ⇄ `16#3FF0000000000000`), and encode/decode are symmetric.
Only the helper set actually referenced by *some* export param/result is emitted (a private, unused
function is an `erlc` warning), in the fixed order `enc_i32,enc_i64,enc_f32,enc_f64,dec_i32,dec_i64,
dec_f32,dec_f64` — deterministic output (P6).

### Per-export result / return shape (algorithm)

Given `ExportSig(name, params, results, touches_state)` with `n = length(params)`:
1. Bind args `A0..A(n-1)`; the call is `'<module_name>':'<name>'(Inst, <enc>(A0), …)` — `Inst` leading.
2. Match `{Pkg, St'}`. Decode `Pkg` per `results`:
   `[]` → the value `ok` (match `{_Pkg, St'}`); `[t]` → `dec(Pkg)`; `[t0,…,tm]` → match
   `{{R0,…,Rm}, St'}` and rebuild `{dec_t0(R0), …}` (a native tuple in declaration order).
3. Return: **`touches_state = True`** → `{ok, {DecodedResults, St'}}` (thread the new instance out; for a
   0-result mutator this is simply `{ok, St'}`); **`False`** → `{ok, DecodedResults}` and discard `St'`
   (`_St`). *`Inst` is a parameter of both shapes* — the underlying `.beam` requires `St` leading even for
   a pure export (emit_core §B.4). This resolves overview §3 open-seam 1: thread the instance **out** only
   when the export touches state; always take it **in**.
4. Wrap the whole `try … of` with `catch error:{wasm_trap, _} = Trap -> {error, Trap}` — the native catch.

## §4 The work (ordered, buildable)

1. **Module skeleton.** `emit_erlang_bindings.gleam` importing `iface`, `ir`, `gleam/list`,
   `gleam/string`, `gleam/int`. `pub fn emit_erlang(iface: Iface) -> List(GeneratedFile)`.
2. **Name helpers.** `binding_module_name/1` (last `@`-segment + `_bindings`) and a `quote_atom/1`
   (wraps in `'…'`, escaping any embedded `'`/`\`) used for module + function atoms.
3. **Conversion tables.** `arg_encode(valtype, var) -> String` and `result_decode(valtype, var) -> String`;
   `helper_defs(used: Set) -> String` emitting only-needed helpers in fixed order.
4. **Per-export renderer.** `render_export(module_atom, sig) -> String` producing the `-doc` + `-spec` +
   clause per §3, plus a `spec_result_type(sig)` (`ok | integer() | float() | binary() | term() | {…}`,
   wrapped `{ok, …}`/`{ok, {…, instance()}}`).
5. **Assemble.** `-module`/`-moduledoc`/`-export`/`-export_type`/type decls/`instantiate/0`/exports (in
   `iface.exports` order)/used helpers. Reject a non-`Threaded` `state_model` at the type level (P12-01's
   `describe/2` already fails-closed on Cell/import-bearing, so `emit_erlang` only ever sees `Threaded`).
6. **Doc comments** (`///`) on every public function per DoD.2.
7. `gleam format` + `gleam build` (zero warnings) + the unit test suite.

## §5 Tests (`test/.../emit_erlang_bindings_test.gleam`)

Spec-cited (P2 / WASM value semantics) + adversarial, **compile+call** not golden (P7). Each builds an
`Iface` (directly, or via `iface.describe` on a tiny IR module), emits, writes the `.erl` to a temp dir,
compiles it with **real `erlc`** (via an FFI, alongside the actual `.beam` from the pipeline), calls an
export, and asserts the native result is **identical to the in-process `pipeline` oracle**:
- **Compile+call (headline).** `add : (i32,i32)->i32`: `add(Inst, -1, 1)` returns `{ok, 0}` — proves the
  binding compiles under `erlc` and the signed-int round-trip (`-1` ⇄ raw `4294967295`) matches the oracle.
- **Trap case.** An export that divides by zero (or an OOB `i32.load`) returns `{error, {wasm_trap, _}}` —
  never a raw uncaught exception; assert the kind atom equals the oracle's `TrapReason`.
- **Multi-value + float round-trip.** `divmod : (i32,i32)->(f64,i32)` returns `{ok, {F, I}}` with `F` a
  native `float()` bit-identical to the oracle's f64 and `I` signed — proves tuple assembly + IEEE round
  trip. Add an **f32 single-rounding** case (`0.1` f32) asserting the emitted `enc_f32/dec_f32` matches the
  runtime's single-rounded bits.
- **State threading.** A `store`/`load` pair: `store(Inst,0,7)` returns a new `Inst'`; `load(Inst',0)`
  returns `{ok, 7}` while `load(Inst, 0)` on the *old* handle still returns the pre-store value (proves the
  functional value-threading, no shared process).
- **Adversarial names / determinism.** An export named `"run-test"` compiles (quoting) and calling it
  works; emitting the same `Iface` twice is **byte-identical**; an f64 argument encodes big-endian
  (assert `enc_f64(1.0) == 16#3FF0000000000000` against the runtime's stored bits).

## §6 Definition of Done

Per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9: spec-cited compile+call tests green (not
change-detector goldens); `///` contract doc comments on every public function; `gleam format --check src
test` clean; `gleam build` zero warnings; the unit suite passes; default emission unchanged (no pipeline
edit). The emitted `.erl` must itself compile under `erlc` **warning-free** (only-needed helpers; every
function `-spec`'d or unused-safe).

## §7 What it leaves (handoff)

- **To P12-05 (CLI):** a pure `emit_erlang(Iface) -> List(GeneratedFile)` (a single `.erl`). The CLI joins
  `GeneratedFile.path` under `--out` and writes bytes; ordering/determinism are already guaranteed here.
- **To P12-06 (capstone):** the compile+call differential FFI (`erlc` invoke) this unit prototypes in its
  own suite is the pattern the capstone generalizes across languages/types.
- **Deferred (P8, unchanged):** Cell/process-wrapped stateful modules; import-bearing provider surfaces;
  cross-language ref construction (refs stay opaque `term()`).
