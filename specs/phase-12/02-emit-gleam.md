# P12-02 — The Gleam emitter (the beautiful typed `.gleam` file)

> **Status:** scoped, awaiting review. **Owner:** P12-02 (Wave A, sibling of P12-03/-04/-05).
> **Depends on the freeze** `«IFACE-DESC-FROZEN»` (P12-01). Reads only the *frozen signatures* of
> `backend/iface.gleam`, never a sibling emitter's body. Implementer read order:
> [`00-overview.md`](00-overview.md) → this doc. All prior-phase invariants
> ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold.

---

## §1. Goal

Implement `emit_gleam(iface: Iface) -> List(GeneratedFile)` — the **headline** deliverable: from the
language-neutral `Iface` (P1), render a **typed, idiomatic `.gleam`** binding whose surface is native
Gleam types, plus the **tiny `.erl` catch shim** it needs to turn a BEAM trap into a `Result`. A
hand-written Gleam program `import`s the binding, calls a typed export, and gets the correct native value
— compiled by the *real* Gleam toolchain.

Implements: **P1** (renders `Iface`, never re-derives from IR); **P2** (native-type surface with the
frozen value-ABI conversions done *in Gleam*); **P3** (value-threaded `Instance`, pure, no process);
**P4** (a checked-in-able source companion, `.beam` untouched); **P5** (typed `pub fn` + `Result` +
`@external` + `///` docs); **P8** (threaded/tier-P, export-only, refs opaque).

---

## §2. Depends on / Produces

**Depends on** (`«IFACE-DESC-FROZEN»`, all from `backend/iface.gleam`): the `Iface`,
`ExportSig`, `GeneratedFile`, `StateModel` types; `ir.ValType`; and the uniform emitter signature
`emit_gleam(Iface) -> List(GeneratedFile)`. Also the run-ABI facts (`src/twocore/pipeline.gleam`,
`src/twocore_cli_ffi.erl`) that fix the emitted call shape.

**Produces** (D1 — this unit's only owned source file):
- `src/twocore/backend/emit_gleam_bindings.gleam` — the emitter.
- `test/twocore/backend/emit_gleam_bindings_test.gleam` — the unit's compile+call suite (§5).

Leaves to **P12-05** (CLI): the `emit_gleam/1` entry to invoke and the two-file list to write into `--out`.
Leaves to **P12-06** (capstone): the cross-language compile+call acceptance.

---

## §3. What it owns + design

### D1 file: `src/twocore/backend/emit_gleam_bindings.gleam`

**The two generated files.** `emit_gleam` returns **exactly two** `GeneratedFile`s (this is *why* the
signature returns a list):

1. `<module>_bindings.gleam` — the typed binding. **Its Gleam module name must differ from the compiled
   WASM `.beam` module atom** `iface.module_name` (a `foo.gleam` compiles to Erlang module `foo`, which
   would *collide* with the loaded `foo.beam`). We name it `<module_name>_bindings`.
2. `<module>_bindings_ffi.erl` — the catch shim (below). Gleam auto-discovers a sibling `.erl` for FFI,
   so both files land in the same `--out` dir and compile together.

**The catch shim (critical).** Gleam on this toolchain has *no in-language BEAM-exception rescue*
(`src/twocore_cli_ffi.erl` header + `pipeline.gleam` §ABI), so a trap raised by `rt_trap` cannot be
turned into a `Result` from Gleam alone. The emitted `.erl` is a **generic thunk-rescuer** — it never
does a data-driven `apply(Mod,Fun,_)` (D3a-clean: the module/function are static in the Gleam
`@external`s; the shim only *runs a fun the caller handed it*):

```erlang
%% <module>_bindings_ffi.erl — generated; do not edit.
-module('<module_name>_bindings_ffi').
-export([rescue/1]).

%% Run the 0-arity Thunk under try/catch. A normal return is {ok, V}; any raise
%% (a {wasm_trap,Kind} from rt_trap, a capability denial, any BEAM error) becomes
%% {error, Reason} with Reason rendered as a UTF-8 binary — exactly pipeline.gleam's
%% catch_apply contract, so a caller can substring-match the spec trap phrase.
rescue(Thunk) ->
    try Thunk() of
        Value -> {ok, Value}
    catch
        _Class:Reason -> {error, unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}
    end.
```

**The generated `.gleam` shape.** Header (opaque handle + trap type + shim `@external`):

```gleam
//// Typed bindings for the compiled WASM module `<module_name>`. Generated — do not edit.
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/result

/// A live instance: an opaque wrapper over the tier-P `InstanceState` record returned by
/// `<module_name>:instantiate/0`. Threaded purely by value — no process is spawned (P3).
pub opaque type Instance { Instance(state: Dynamic) }

/// A WASM trap surfaced as a value (P2). `reason` is the rendered BEAM error term, e.g.
/// `"{wasm_trap,int_div_by_zero}"` — the same string channel `pipeline.RunResult.Trapped` carries.
pub type Trap { Trap(reason: String) }

/// An opaque funcref/externref handle — passthrough of the runtime `rt_ref` box (P8: no
/// cross-language function construction this phase).
pub opaque type Ref { Ref(raw: Dynamic) }

@external(erlang, "<module_name>_bindings_ffi", "rescue")
fn rescue(thunk: fn() -> a) -> Result(a, String)
```

**Instance construction.** `instantiate/0` returns the raw record; we box it. Per frozen **P3** the
signature is `instantiate() -> Instance` (an instantiation-time trap — OOB active segment / trapping
`start` — *raises*; see §7 note):

```gleam
@external(erlang, "<module_name>", "instantiate")
fn raw_instantiate() -> Dynamic

/// Instantiate the module (seeds memory/globals/table). Pure value threading, no process.
pub fn instantiate() -> Instance { Instance(raw_instantiate()) }
```

**The uniform call convention (grounded).** Under `Threaded` (tier-P), `emit_core` emits **every**
export at arity `n+1` with a leading `InstanceState`, returning `{Package, St'}` — even pure functions
get an adapting wrapper `fun(St, A…) -> {Result, St}` (emit_core §A `emit_fn_export`). The `Package` is
(`emit_core.function_return`): `'ok'` for 0 results, the **bare value** for 1, an **N-tuple** for ≥2. So
every `@external` binds to `<module>:<export>` at arity `n+1` and returns `#(package, Dynamic)`; the
typed wrapper unpacks the pair, converts, and — per **P3** — threads the instance back **iff**
`export.touches_state`, else drops `St'`.

**Per-export rendering** (`ExportSig(name, params, results, touches_state)`):

```gleam
// add(i32,i32)->i32  — touches_state: False (pure): returns Result(Int, Trap), drops St'
@external(erlang, "<module_name>", "add")
fn raw_add(st: Dynamic, a: Int, b: Int) -> #(Int, Dynamic)

/// Call the exported `add` : (i32, i32) -> i32. Ints are presented **signed**.
pub fn add(inst: Instance, a: Int, b: Int) -> Result(Int, Trap) {
  let Instance(st) = inst
  rescue(fn() { raw_add(st, i32_to_raw(a), i32_to_raw(b)) })
  |> result.map(fn(pair) { let #(pkg, _st2) = pair  i32_from_raw(pkg) })
  |> result.map_error(Trap)
}
```

```gleam
// divmod(i32,i32)->(i32,i32) — multi-value + can TRAP (÷0). touches_state: False.
@external(erlang, "<module_name>", "divmod")
fn raw_divmod(st: Dynamic, a: Int, b: Int) -> #(#(Int, Int), Dynamic)

/// Call `divmod` : (i32,i32) -> (i32,i32). Traps (division by zero) become `Error(Trap)`.
pub fn divmod(inst: Instance, a: Int, b: Int) -> Result(#(Int, Int), Trap) {
  let Instance(st) = inst
  rescue(fn() { raw_divmod(st, i32_to_raw(a), i32_to_raw(b)) })
  |> result.map(fn(pair) {
    let #(pkg, _st2) = pair
    let #(q, r) = pkg
    #(i32_from_raw(q), i32_from_raw(r))
  })
  |> result.map_error(Trap)
}
```

```gleam
// push(i32)->i32 — writes memory, touches_state: True: threads the instance back.
@external(erlang, "<module_name>", "push")
fn raw_push(st: Dynamic, v: Int) -> #(Int, Dynamic)

/// Call `push` : (i32) -> i32. State-touching, so returns the new `Instance` alongside the result.
pub fn push(inst: Instance, v: Int) -> Result(#(Int, Instance), Trap) {
  let Instance(st) = inst
  rescue(fn() { raw_push(st, i32_to_raw(v)) })
  |> result.map(fn(pair) { let #(pkg, st2) = pair  #(i32_from_raw(pkg), Instance(st2)) })
  |> result.map_error(Trap)
}
```

A `scale(f64)->f64` export shows the float round-trip: params `f64_to_raw(x)`, result `f64_from_raw(pkg)`.

**The conversion helpers** (emitted once per file; mirror `rt_num`'s bit round-trips, lines 768/781):

```gleam
fn i32_to_raw(v: Int) -> Int { int.bitwise_and(v, 0xFFFFFFFF) }
fn i32_from_raw(raw: Int) -> Int {
  case raw >= 0x80000000 { True -> raw - 0x100000000  False -> raw }
}
fn i64_to_raw(v: Int) -> Int { int.bitwise_and(v, 0xFFFFFFFFFFFFFFFF) }
fn i64_from_raw(raw: Int) -> Int {
  case raw >= 0x8000000000000000 { True -> raw - 0x10000000000000000  False -> raw }
}
fn f64_to_raw(f: Float) -> Int { let assert <<bits:size(64)>> = <<f:float-size(64)>>  bits }
fn f64_from_raw(raw: Int) -> Float { let assert <<f:float-size(64)>> = <<raw:size(64)>>  f }
fn f32_to_raw(f: Float) -> Int { let assert <<bits:size(32)>> = <<f:float-size(32)>>  bits }
fn f32_from_raw(raw: Int) -> Float { let assert <<f:float-size(32)>> = <<raw:size(32)>>  f }
// v128: identity BitArray (16 bytes); Ref: Ref(x) / unwrap — no numeric conversion.
```

`int.bitwise_and` is Erlang `band` over bignums (two's-complement infinite width), so
`i32_to_raw(-1) == 0xFFFFFFFF` — the signed⇄raw round-trip is exact with no width loss (host ints are
bignums). `<<F:32/float>>` single-rounds an f64 to f32 (P2). **The emitter only emits the helpers a
module actually uses** (dead-code-free, `gleam build` zero-warning).

### Algorithm

1. Reject `iface.state_model != Threaded` is *not* this emitter's job — P12-01's `describe/2` already
   fails-closed (`CellUnsupported`/`ImportBearingUnsupported`); `emit_gleam` receives a valid `Iface`.
2. Emit the header, `Instance`, `Trap`, `Ref`, the shim `@external`, and `instantiate/0`.
3. For each `ExportSig` **in `iface.exports` order** (P1 fixes it deterministically): emit the `raw_*`
   `@external` (arity `n+1`, leading `st: Dynamic`, return `#(package_type, Dynamic)`) and the typed
   `pub fn` with param/result conversions, thread-or-drop `St'` per `touches_state`, `map_error(Trap)`.
4. Emit only the conversion helpers referenced. Build the `.erl` shim with `iface.module_name`.
5. Return `[GeneratedFile("<module>_bindings.gleam", …), GeneratedFile("<module>_bindings_ffi.erl", …)]`.

---

## §4. The work (ordered, buildable)

1. Module skeleton: `emit_gleam(Iface) -> List(GeneratedFile)` returning two hardcoded-shell files that
   `gleam build`; wire the header/`Instance`/`Trap`/shim `@external`/`instantiate`.
2. Value-ABI: `valtype_to_gleam_type(ValType) -> String` (`TI32/TI64 -> "Int"`, `TF32/TF64 -> "Float"`,
   `TV128 -> "BitArray"`, `TFuncRef/TExternRef/TExnRef -> "Ref"`) and the param/result *conversion*
   renderers (`native->raw`, `raw->native`) keyed on `ValType`.
3. Package typing: `package_type(results) -> String` (`[] -> "Dynamic"` ignored / `[t] -> raw t` /
   `_ -> #(…)`) and the result unpack renderer (bare vs tuple destructure).
4. Per-export renderer: signature (`touches_state` → `#(results, Instance)` vs `results`), body, docs.
5. The `.erl` shim renderer (module name from `iface.module_name`).
6. `gleam format`; doc-comment every public function; `gleam build` zero warnings.

---

## §5. Tests (`emit_gleam_bindings_test.gleam` — spec-cited + adversarial)

Per **P7**, tests are **compile + call differential**, *not* golden change-detectors (D8). Gleam is in
the tree, so this unit tests the Gleam path end-to-end. Each test: build a small module through the real
pipeline → `describe/2` → `emit_gleam` → write the two files into a scratch dir → invoke `gleam build` on
a tiny driver that `import`s the binding and calls the export → assert the native result **equals the
in-process `pipeline` oracle** (by native value). Cases:

- **Compile + call (headline):** `add(i32,i32)->i32` — driver calls `add(instantiate(), 2, -3)` and gets
  `Ok(-1)`; oracle (`pipeline.run_source`) returns raw `4294967295` → `i32_from_raw` = `-1`. The **signed
  presentation** is asserted against the spec's two's-complement interpretation of i32, not the raw bits.
- **Trap case:** `divmod(x, 0)` → `Error(Trap(reason))` with `reason` containing the spec phrase for
  integer division by zero — never a raw uncaught exception (acceptance "Traps surfaced").
- **Multi-value + float round-trip:** a `(i32,i32)`-returning export → `Ok(#(_, _))` tuple; an
  `f64`/`f32` export round-trips a value bit-identically to the oracle (f32 single-rounded), asserting
  the IEEE-bits mapping (D5). Adversarial floats: `-0.0`, a large magnitude.
- **State threading:** a memory-writing `push` returns `#(result, Instance)` and a *second* `push` on the
  returned `Instance` observes the persisted write (P3 value threading).
- **Adversarial / unit-level (pure, no toolchain):** i32/i64 boundary round-trips (`-1`, `INT_MIN`,
  `2^63`) through `*_to_raw`/`*_from_raw`; deterministic output (same `Iface` ⇒ byte-identical files);
  the generated Gleam module name `≠ iface.module_name` (no `.beam` collision).

---

## §6. Definition of Done ([`../03-phase-workflow.md`](../03-phase-workflow.md) §9, per unit)

1. Spec-cited compile+call tests above pass (the headline, a trap, a multi-value/float, state threading).
2. `///` doc comments on every public function (`emit_gleam` — contract, the two-file return, the shim
   requirement, determinism).
3. `gleam format --check src test` clean.
4. `gleam build` zero warnings — including that the *generated* `.gleam` builds warning-free (unused
   helpers pruned).
5. The unit suite passes ("done" = the suite passes, and the generated binding compiles + calls).

---

## §7. What it leaves (handoff)

- **To P12-05 (CLI):** `emit_gleam/1` and its two-`GeneratedFile` contract; the CLI writes both into
  `--out` verbatim and must not rename (the `_bindings`/`_bindings_ffi` names are load-bearing).
- **To P12-06 (capstone):** the Gleam row of the cross-language compile+call acceptance table.
- **Open items to flag upstream (P12-01 / reconciliation), NOT resolved here:**
  1. **Instantiation traps vs the frozen `instantiate() -> Instance`.** A trapping `start` / OOB active
     segment *raises* at `instantiate/0`; P3's signature has no `Result`, so this one trap escapes as a
     raw exception — inconsistent with "traps are Results everywhere else." Either `instantiate()` should
     return `Result(Instance, Trap)` (rescue the `raw_instantiate` call too) or the caveat is documented.
  2. **Non-finite floats.** `<<F:64/float>>` **raises `badarg` on NaN/±Inf bits** (see `rt_num.gleam`
     header, line 22), so `f*_from_raw` cannot present a NaN/Inf result as a Gleam `Float`. The P2
     "f64 -> Float via raw round-trip" mapping silently excludes non-finite results — needs a decision
     (return raw `Int` bits for floats? a `Float`-or-bits variant?). Flagged for P12-01.
