# P12-04 — Elixir emitter (`emit_elixir`)

> **Status:** scoped, awaiting review. **Owner:** P12-04 (Wave A, parallel with P12-02 / P12-03 / P12-05).
> **Depends on freeze:** `«IFACE-DESC-FROZEN»` (P12-01). **Freezes:** nothing new — it renders the frozen
> `Iface` behind the frozen `emit_elixir(Iface) -> List(GeneratedFile)` signature. All prior-phase decisions
> and the permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold.

---

## §1. Goal

Emit one idiomatic **Elixir** source file (`<module>.ex`) that gives a typed, ergonomic API to instantiate a
compiled (threaded / tier-P) module and call each of its exports — WASM value-types mapped to native Elixir
types, traps surfaced as `{:error, _}`, and the raw-bit-pattern run-ABI hidden behind private conversion glue.
The `.beam` is untouched; this is a companion source file the user compiles with `elixirc`/`mix`.

Decisions it implements: **P1** (render `Iface`, never re-derive from the IR); **P2** (the Elixir column of the
frozen value-ABI mapping + boundary conversion); **P3** (the value-threaded, pure, tier-P instance model);
**P5** (idiomatic Elixir: `defmodule` + `@spec` + `@typedoc`/`@doc` + `@opaque` instance type, Dialyzer-visible);
**P8** (threaded-only, export-only, refs opaque; **Elixir compile+call is best-effort — skip if `elixir` absent**).

**Catch-shim question, answered.** Gleam (P12-02) cannot catch a BEAM exception in-language, so it must ship an
accompanying `.erl` shim. **Elixir can** — `try/catch` with a `:error` class clause catches the error-class
exception `rt_trap` raises (`erlang:error({wasm_trap, Kind})`, see `src/twocore/runtime/rt_trap.gleam:56`).
**Therefore `emit_elixir` needs no separate shim and returns a single-element list** `[GeneratedFile("<module>.ex", …)]`.
The `List` return type is uniform with the other emitters; Elixir simply never populates a second element.

---

## §2. Depends on / Produces

**Depends on** (frozen signatures only, not bodies):
- `src/twocore/backend/iface.gleam` (P12-01): `Iface`, `StateModel` (`ImportFree`/`Threaded`; `Cell` rejected),
  `ExportSig(name, params, results, touches_state)`, `GeneratedFile(path, content)`, and the emitter signature.
- `twocore/ir.{ValType}` — `TI32 TI64 TF32 TF64 TV128 TFuncRef TExternRef TTerm` (`src/twocore/ir.gleam:317`).

**Produces:** `src/twocore/backend/emit_elixir_bindings.gleam` exporting
`pub fn emit_elixir(iface: Iface) -> List(GeneratedFile)`, plus its test module. Consumed by **P12-05** (CLI wiring)
and **P12-06** (the compile+call differential capstone).

---

## §3. What it owns + design

**Owns (D1):** `src/twocore/backend/emit_elixir_bindings.gleam` (+ `test/twocore/backend/emit_elixir_bindings_test.gleam`).

### The run-ABI this binding drives (grounded, not re-derived)

Under `state_strategy: Threaded`, `emit_core` (`src/twocore/backend/emit_core.gleam:508-580`, `emit_fn_export`)
emits **every** export at arity **n+1**, taking a leading `InstanceState` record and returning the 2-tuple
`{Package, St'}` — *including pure functions*, which get the adapting wrapper `fun(St, A…) -> {apply g/n(A…), St}`.
`instantiate/0` returns the `InstanceState` record itself. `Package` is `function_return`'s shape
(`emit_core.gleam:4510`): **0 results → the atom `:ok`; 1 result → the bare raw value; N≥2 → an N-tuple
`{V1,…,Vn}`** (all lanes still raw bit patterns). A trap is `erlang:error({wasm_trap, Kind})` (error class).

So the binding, for `:"<module_name>".<export>`, must: hold the record from `instantiate/0`; convert native args →
raw bit patterns; call `:"<mod>".export(state, raw1, …)`; receive `{package, st'}`; convert each lane raw → native;
and — per **P3** — return the threaded instance only when `touches_state` (a pure export drops the unchanged `st'`).

### Value-ABI (P2, Elixir column) — private conversion glue

```
i32:  to_raw(v) = Bitwise.band(v, 0xFFFFFFFF)                       # signed native → raw unsigned
      from_raw(r) = if r >= 0x80000000, do: r - 0x100000000, else: r   # raw unsigned → signed native
i64:  to/from with mask 0xFFFF...(16 F) and sign pivot 0x8000_0000_0000_0000  (host ints are bignums)
f64:  to_raw(f)  ->  <<bits::64>> = <<f::float-size(64)>>; bits
      from_raw(b) ->  <<f::float-size(64)>> = <<b::64>>; f
f32:  to_raw(f)  ->  <<bits::32>> = <<f::float-size(32)>>; bits    # single-rounded on construction
      from_raw(b) ->  <<f::float-size(32)>> = <<b::32>>; f
v128:              identity — a 16-byte binary (Elixir binary == BitArray)
funcref/externref: identity — opaque `term()` passthrough (the `rt_ref` box)
```

Integers are presented **signed** (a documented presentation choice — the module is sign-agnostic on the bits).
`band(-1, 0xFFFFFFFF) == 4294967295` in Elixir, so the negative→raw direction is exact for bignums.

### Type mapping and the generated shape

| WASM | Elixir `@spec` type | multi-value | trap |
|---|---|---|---|
| i32/i64 | `integer()` | results become an Elixir **tuple** in declaration order | error-class `{:wasm_trap, atom}` → `{:error, _}` |
| f32/f64 | `float()` | | |
| v128 | `binary()` | | |
| funcref/externref | `term()` | | |

`emit_elixir` produces `[GeneratedFile(path: "<module_name>.ex", content: <the defmodule>)]`. The path filename is
the raw `module_name` (deterministic, no timestamps); the `defmodule` alias is a camelized form of it
(`"my_mod"` → `MyMod`) so the Elixir module (compiled to `Elixir.MyMod`) never collides with the wasm BEAM module
(`:"my_mod"`) it calls. Exports render **in `Iface.exports` order** (P12-01 fixes the order; the emitter preserves it).

**Sample generated file** for `module_name: "app"` with exports `add(i32,i32)->i32` (state-touching),
`sq(f64)->f64` (pure), `divmod(i32,i32)->(i32,i32)` (state-touching, multi-value):

```elixir
defmodule App do
  @moduledoc """
  Typed bindings for the WebAssembly module `:app`, generated by 2core (Phase 12). Do not edit.
  Values are native Elixir types; the raw run-ABI (unsigned bit patterns) is hidden. Traps are `{:error, _}`.
  """
  import Bitwise

  @opaque t :: %__MODULE__{state: term()}
  @enforce_keys [:state]
  defstruct [:state]

  @typedoc "A WebAssembly trap, surfaced as the error-class reason `{:wasm_trap, kind}` (or any BEAM error term)."
  @type trap :: {:wasm_trap, atom()} | term()

  @doc "Instantiate the module (fresh memory/globals/tables, active segments, `start`). Pure; spawns no process."
  @spec instantiate() :: t()
  def instantiate(), do: %__MODULE__{state: :app.instantiate()}

  @doc "Exported `add`. Reads/mutates instance state, so it threads the instance."
  @spec add(t(), integer(), integer()) :: {:ok, {integer(), t()}} | {:error, trap()}
  def add(%__MODULE__{state: st}, a, b) do
    try do
      {pkg, st2} = :app.add(st, band(a, 0xFFFFFFFF), band(b, 0xFFFFFFFF))
      {:ok, {from_i32(pkg), %__MODULE__{state: st2}}}
    catch
      :error, reason -> {:error, reason}
    end
  end

  @doc "Exported `sq`. State-free: the instance is unchanged, so it is not returned."
  @spec sq(t(), float()) :: {:ok, float()} | {:error, trap()}
  def sq(%__MODULE__{state: st}, x) do
    try do
      {pkg, _st} = :app.sq(st, to_f64(x))
      {:ok, from_f64(pkg)}
    catch
      :error, reason -> {:error, reason}
    end
  end

  @doc "Exported `divmod`. Multi-value: results are a tuple in declaration order."
  @spec divmod(t(), integer(), integer()) :: {:ok, {{integer(), integer()}, t()}} | {:error, trap()}
  def divmod(%__MODULE__{state: st}, a, b) do
    try do
      {{q, r}, st2} = :app.divmod(st, band(a, 0xFFFFFFFF), band(b, 0xFFFFFFFF))
      {:ok, {{from_i32(q), from_i32(r)}, %__MODULE__{state: st2}}}
    catch
      :error, reason -> {:error, reason}
    end
  end

  @spec from_i32(integer()) :: integer()
  defp from_i32(r), do: if(r >= 0x80000000, do: r - 0x100000000, else: r)
  defp to_f64(f), do: (<<b::64>> = <<f::float-size(64)>>; b)
  defp from_f64(b), do: (<<f::float-size(64)>> = <<b::64>>; f)
end
```

**Result shape rules** (from `Package` × `touches_state`): 0 results → present `:ok` (pure) / `{:ok, t()}`
(state-touching, instance only); 1 result → the converted value; N≥2 → an Elixir tuple of converted lanes.
State-touching ⇒ `{:ok, {results, t()}}`; state-free ⇒ `{:ok, results}` (the unchanged `st'` is bound to `_st`
and discarded — but is **still supplied** to the call, because the Core export is arity n+1 regardless, §run-ABI).

### Emit algorithm

```
emit_elixir(iface):
  guard iface.state_model == Threaded   # ImportFree is a threaded module with no state seed; still fine.
  header  = defmodule <camelize(name)> + @moduledoc + import Bitwise + @opaque t + defstruct + @type trap
  instify = instantiate/0  (wraps :"<name>".instantiate())
  bodies  = for each ExportSig in iface.exports (order preserved): render_export(sig, name)
  glue    = only the conversion helpers actually referenced (dedup: from_i32/to_i32/…/to_f64/…)
  content = header <> instify <> bodies <> glue <> "end\n"
  [GeneratedFile(path: name <> ".ex", content: content)]
```

`render_export` chooses the `@spec` from `params`/`results`, wraps args in `to_raw` per param type, destructures
`{pkg, st'}`, converts `pkg` per `results`, and assembles the `{:ok, …}` shape per `touches_state`. Every generated
public function has an `@spec` and a `@doc`; every helper an `@spec`. Deterministic: no timestamps, stable ordering,
helpers emitted in a fixed canonical order.

---

## §4. The work (ordered, buildable)

1. New module `emit_elixir_bindings.gleam` with `import twocore/backend/iface` + `twocore/ir`; stub
   `emit_elixir(iface) -> List(GeneratedFile)` returning `[]` — compiles green against the frozen keystone.
2. Elixir-type renderer `valtype_spec(ValType) -> String` (`integer()`/`float()`/`binary()`/`term()`), and
   `results_spec(results) -> String` (0 → `:ok`; 1 → the lane type; N → `{t1, …}`).
3. Conversion glue: pure Gleam functions that render the Elixir source for `to_i32/from_i32/to_i64/from_i64/
   to_f32/from_f32/to_f64/from_f64` (v128/refs are identity — no helper). Emit **only referenced** helpers.
4. `render_export(sig, module_name)`: build the `@spec`, the arg-conversion call `:"<mod>".<name>(st, …)`,
   the `{pkg, st'}` destructure, the per-lane result conversion, the `try/catch :error, reason` wrapper, and the
   `{:ok, …}` assembly keyed on `touches_state`.
5. Header/`instantiate`/assembly + `camelize(module_name)` (deterministic; sanitize non-ident chars to `_`).
6. Doc comments (`////` module, `///` every public fn) per DoD #2; `gleam format`; wire nothing into the pipeline
   (that is P12-05). Land green.

---

## §5. Tests (spec-cited + adversarial)

Per **P7**: correctness is **compile + call differential**, never golden change-detectors (D8). The emitter is a
pure Gleam function, so structure can be asserted without Elixir; the *authoritative* compile+call proof is
gated on `elixir` being on `PATH` (**P8** — categorized skip, never a false green). P12-06 owns the full matrix;
P12-04 ships focused cases:

- **Emitter contract (no toolchain):** `emit_elixir` returns **exactly one** `GeneratedFile` (no shim, §1);
  its path is `"<module_name>.ex"`; the content contains `defmodule`, an `@opaque t`, `instantiate`, and one
  `@spec` + `@doc` per export. These assert the *contract*, not a byte-for-byte body.
- **Compile + call (gated on `elixir`):** generate for a real threaded module, `elixirc` it, call an export, and
  assert the native result equals the in-process pipeline oracle (`pipeline.run_source` decoded per P2). Skip
  (categorized) if `elixir` is absent — mirror P12-06's detection.
- **Trap case:** an export that traps (e.g. `i32.div_s` by 0 → `erlang:error({wasm_trap, int_div_by_zero})`)
  must return `{:error, {:wasm_trap, :integer_divide_by_zero}}`-shaped, **never** a raw uncaught exception — the
  `catch :error` clause is exercised. Spec cite: WebAssembly integer division trap.
- **Multi-value + float round-trip:** an export returning `(i32, i32)` yields a two-tuple with **signed** lanes
  (assert `-1` arrives as `-1`, not `4294967295`); an f32 export round-trips a value single-rounded
  (`3.14` in f32 precision) and an f64 export round-trips exactly; verified against the oracle.
- **Adversarial — signed boundary:** i32 `0xFFFFFFFF` → `-1`, i64 `0x8000_0000_0000_0000` → the min i64
  (host bignum, no width loss); the module still sees the raw pattern (differential proves both directions).

---

## §6. Definition of Done ([`../03-phase-workflow.md`](../03-phase-workflow.md) §9, per unit)

1. Spec-cited tests (above) — the trap kind and integer/float semantics cite the WebAssembly spec; not
   change-detectors. A found bug gets a failing test first.
2. `///`/`////` doc comments on every public function stating the contract (what / params-meaning / the
   `List(GeneratedFile)` semantics / that Elixir compile is best-effort).
3. `gleam format --check src test` clean.
4. `gleam build` zero warnings.
5. The unit's suite passes (with the Elixir compile+call case skipped-categorized when `elixir` is absent — a
   skip, never a fail).
6. **Default output unchanged:** this unit wires nothing into the pipeline; emitting a binding never touches the
   `.beam` (that guarantee is P12-05/P12-06's to exercise; P12-04 only ships the pure emitter).

---

## §7. What it leaves (handoff)

- **To P12-05 (CLI):** a pure `emit_elixir(iface) -> List(GeneratedFile)` to call when `--bindings` includes
  `elixir`; write each `GeneratedFile` under `--out`. One file (`<module>.ex`), no shim.
- **To P12-06 (capstone):** the Elixir arm of the compile+call differential — `elixirc` the file, call an
  export, compare to the pipeline oracle across the type matrix; gate the arm on `elixir` presence (categorized
  skip). Confirm the `{pkg, st'}` destructure and the signed/float conversions against real Elixir output.
- **Open items flagged upward (P12-01 / capstone):**
  1. **NaN/Inf floats break the round-trip.** `<<f::float-size(64)>> = <<bits::64>>` raises `badarg` for a NaN/Inf
     bit pattern (BEAM floats cannot represent NaN/Inf). Placed inside `try`, such a *valid* result would be
     mis-surfaced as `{:error, :badarg}` — a trap that isn't one. The P2 float mapping (owned by P12-01) needs a
     ruling: either exclude NaN/Inf-returning float exports from the differential, or present such results as raw
     bits. This affects the Gleam and Erlang emitters identically. Until resolved, the differential corpus should
     avoid NaN/Inf float returns.
  2. **`function_return` is a tuple, not a list.** The N≥2 multi-value package is an Erlang **N-tuple**
     `{V1,…,Vn}` (`emit_core.gleam:4510`), so the binding destructures a tuple (identity for shape; per-lane
     conversion only) — *not* the "bare list" some prose describes. Confirmed against source; recorded so P12-02/03
     use the same shape.
