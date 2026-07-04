# P12-01 — The keystone: the Interface Descriptor (`Iface`) + value-ABI mapping

> **Status:** scoped, awaiting build. **Owner:** P12-01 (the keystone — goes first and alone).
> **Freeze:** produces `«IFACE-DESC-FROZEN»`. **Read order:** [`00-overview.md`](00-overview.md) →
> this doc. All prior-phase decisions and the permanent invariants
> ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold. This unit lands **green with
> default emission byte-identical** — it adds a new module + one documented cross-file reach, and
> changes no emitted `.beam`.

---

## §1. Goal

Freeze the **single language-neutral descriptor** every Phase-12 emitter renders, and the **value-ABI
type mapping** they all obey. Concretely: create `src/twocore/backend/iface.gleam` carrying `Iface` /
`ExportSig` / `StateModel` / `GeneratedFile` / `IfaceError`, the `describe(module, binding)` derivation,
the canonical WASM→host type table, and the **uniform emitter signature shape**
`emit_<lang>(Iface) -> List(GeneratedFile)`.

Implements:
- **P1 (keystone)** — the Interface Descriptor: emitters never re-derive from the IR; they render `Iface`.
- **P2** — the raw-bit-pattern value-ABI and its native-type mapping (the full table, §3).
- **P8 (fail-closed scope)** — `describe/2` **rejects** Cell (`CellUnsupported`) and import-bearing
  modules (`ImportBearingUnsupported`) up front.

The emitter *bodies* (P12-02/03/04), the CLI (P12-05), and the compile+call harness (P12-06) all build
against the frozen shapes here, never against each other.

---

## §2. Depends on / Produces

**Depends on (read-only, frozen upstream):**
- `src/twocore/ir.gleam` — `Module.name`, `Module.functions`, `Module.exports`, `Module.imports`;
  `ExportDecl` (`ExportFn`/`ExportGlobal`/`ExportTable`/`ExportMemory`/`ExportTag`); `Function`;
  `ValType` (`TI32 TI64 TF32 TF64 TTerm TFuncRef TExternRef TV128 TExnRef`); `FuncType(params, results)`;
  `signature(f) -> FuncType` (derives a function's `FuncType` from its named params — line 449).
- `src/twocore/runtime/instance.gleam` — `Binding`, its `state_strategy` field, and
  `StateStrategy` (`Cell`/`Threaded`).
- `src/twocore/backend/emit_core.gleam` — the state-reaching classifier (see §3, the cross-file reach).

**Produces `«IFACE-DESC-FROZEN»`:** the five public types + `describe/2` + `host_types/1` + the documented
uniform emitter signature. Unblocks P12-02, P12-03, P12-04, P12-05, P12-06.

---

## §3. What it owns + design

**Owned files (D1):**
- **D1** new `src/twocore/backend/iface.gleam` (all types + `describe/2` + `host_types/1`).
- new `test/twocore/backend/iface_freeze_test.gleam`.
- **One documented cross-file reach** into `src/twocore/backend/emit_core.gleam`: promote the
  state-reaching classifier to `pub` (see below). Recorded in `state.md`.

### 3.1 The frozen types (copy verbatim)

```gleam
import twocore/ir
import twocore/runtime/instance

/// The language-neutral Interface Descriptor (P1). Computed once from the IR `Module` + the
/// runtime `Binding`; every emitter RENDERS this and never re-derives from the IR.
pub type Iface {
  Iface(
    module_name: String,          // the FINAL loaded BEAM module atom the binding calls into
    state_model: StateModel,      // whether the host API threads an Instance
    exports: List(ExportSig),     // one per callable (ExportFn) export, in declaration order
  )
}

/// How the host API presents instance state. Cell (tier-O) is REJECTED this phase (P8).
/// - `ImportFree`: NO exported function threads instance state → the "beautiful pure file":
///    exports are `export(args…) -> Result(results, Trap)`, no `Instance` in the surface.
/// - `Threaded`: ≥1 exported function threads the `InstanceState` record → the binding exposes
///    `instantiate() -> Instance` and threads it through state-touching exports.
pub type StateModel {
  ImportFree
  Threaded
}

/// One callable export's typed surface.
/// - `name`: the export name (the symbol the host calls; = `ExportFn.export_name`).
/// - `params` / `results`: its WASM `FuncType`, derived via `ir.signature`.
/// - `touches_state`: whether it reads/mutates instance state — the TRANSITIVE state-reaching
///    closure (see §3.3), matching emit_core's `ctx.fn_state_reaching`. Governs the host-facing
///    return shape (thread the `Instance` back or not).
pub type ExportSig {
  ExportSig(
    name: String,
    params: List(ir.ValType),
    results: List(ir.ValType),
    touches_state: Bool,
  )
}

/// One emitted companion source file (P4). `path` is relative to the CLI `--out` dir;
/// `content` is the full UTF-8 source. Deterministic — no timestamps, stable ordering (P6).
pub type GeneratedFile {
  GeneratedFile(path: String, content: String)
}

/// The fail-closed rejections `describe/2` can return (P8). Deliberately only two variants —
/// this phase either produces a valid `Iface` or rejects for one of these two reasons.
pub type IfaceError {
  CellUnsupported            // state_strategy == Cell (process-wrapped server binding deferred)
  ImportBearingUnsupported   // the module needs providers at instantiate/1 (typed provider surface deferred)
}
```

### 3.2 `describe/2` — the derivation

```gleam
/// Derive the `Iface` from a compiled module + its build binding (P1). Fail-closed (P8).
///
/// - `module`: the (validated) IR module about to be emitted. `module.name` MUST already be the
///    final loaded BEAM module atom (the CLI passes the Phase-11 `--link`-renamed module, if any).
/// - `binding`: the build binding; only `state_strategy` is consulted here.
/// - Returns `Ok(Iface)` for a threaded, import-free module; `Error(CellUnsupported)` if the build
///    is Cell; `Error(ImportBearingUnsupported)` if the module has ANY import (`ImportFn`/
///    `ImportGlobal`/`ImportTable`/`ImportMemory`/`ImportTag`).
/// Assumes a validated module: every `ExportFn.fn_name` resolves to a defined function (guaranteed
/// by the pipeline's validate stage; an unresolved name is an impossible state, `let assert`).
pub fn describe(
  module: ir.Module,
  binding: instance.Binding,
) -> Result(Iface, IfaceError)
```

Algorithm (checks in this order — reject before building):
1. `binding.state_strategy == instance.Cell` → `Error(CellUnsupported)`.
2. `module.imports != []` → `Error(ImportBearingUnsupported)`. (Import-bearing ⇒ `instantiate/1`
   needs providers — deferred, P8.)
3. Compute `reaching = state_reaching_exports(module.functions)` (the transitive closure — §3.3).
4. For each `ir.ExportFn(export_name, fn_name)` in `module.exports` (in order), look up its
   `Function`, `let sig = ir.signature(fn)`, and build
   `ExportSig(name: export_name, params: sig.params, results: sig.results,
   touches_state: set.contains(reaching, fn_name))`. **Skip** `ExportGlobal`/`ExportTable`/
   `ExportMemory`/`ExportTag` — exported *state* is not a callable this phase (documented handoff, §7).
5. `state_model = case list.any(exports, fn(e) { e.touches_state }) { True -> Threaded; False -> ImportFree }`.
6. `Ok(Iface(module_name: module.name, state_model:, exports:))`.

### 3.3 The `touches_state` source — the cross-file reach (correctness crux)

`touches_state` **must be the transitive `CallDirect` closure**, not a shallow scan of the export's own
body. `emit_core` decides each export's emitted arity from `ctx.fn_state_reaching` — the fixpoint
`state_reaching_closure` (emit_core lines 771–823): a function is state-reaching iff its body contains a
stateful node **or it transitively `CallDirect`s one that does**. A *pure-looking* export that calls a
memory-touching helper is emitted at arity `n+1` and threads `St`. If `ExportSig.touches_state` used the
shallow `expr_touches_state` (line 833) instead, the binding would present a pure `fn(args)` for an
export the runtime actually threads — the host API would disagree with the emitted ABI.

Therefore this unit **promotes `state_reaching_closure` to `pub`** (rename it
`state_reaching_exports(functions: List(Function)) -> Set(String)` if clearer) and `describe/2` reuses
that exact function — single source of truth, guaranteed to match the emitted arity. The shallow
`expr_touches_state` stays private; it is *not* the descriptor's input. (This is the deliberate,
documented keystone cross-file reach; recorded in `state.md`.)

> **ABI note for the emitters (freeze this):** under `state_strategy: Threaded`, **every** exported
> symbol is emitted at arity `param_count + 1` — a leading `InstanceState` param, returning
> `{ResultPackage, NewState}` (emit_core `emit_exports`, threaded arm: state-reaching exports export
> directly at `n+1`; *pure* exports get an adapting wrapper `fun(St, A…) -> {apply fn/n(A…), St}`, also
> `n+1`). `ResultPackage` follows the run-ABI: a single raw value, or a **bare list** for multi-value.
> So the binding **always** supplies `St` at the boundary; `touches_state` governs only whether the
> *host-facing* signature threads the `Instance` back. An `ImportFree` binding obtains `St` from
> `instantiate/0` internally and discards the unchanged `NewState`.

### 3.4 The value-ABI mapping (P2, the full table — frozen)

The run-ABI is raw unsigned bit patterns as Erlang integers (i32 `-1` ⇒ `4294967295`; floats as raw
IEEE-754 bits, also an integer; multi-value ⇒ a bare list; a trap ⇒ a BEAM exception from `rt_trap`).
The binding presents native types with boundary conversion. This unit owns the canonical table and
exposes it as one shared function so the three emitters cannot drift:

```gleam
/// The frozen per-language type names + conversion note for one WASM `ValType` (P2).
pub type HostTypeNames {
  HostTypeNames(gleam: String, erlang: String, elixir: String)
}

/// The canonical WASM→host type mapping (P2). Total over every `ir.ValType`.
pub fn host_types(vt: ir.ValType) -> HostTypeNames
```

| `ir.ValType` | Gleam | Erlang `-spec` | Elixir `@spec` | Boundary conversion (native ⇄ raw-ABI) |
|---|---|---|---|---|
| `TI32` / `TI64` | `Int` | `integer()` | `integer()` | **signed** two's-complement ⇄ raw unsigned bit pattern (host ints are bignums — no width loss) |
| `TF32` / `TF64` | `Float` | `float()` | `float()` | native float ⇄ raw IEEE bits via `<<F:32/float>>` / `<<F:64/float>>` (f32 single-rounded) |
| `TV128` | `BitArray` | `binary()` | `binary()` | identity — 16 raw little-endian bytes |
| `TFuncRef` / `TExternRef` / `TExnRef` | opaque `Ref` | `term()` | `term()` | opaque passthrough (the `rt_ref` box) |
| `TTerm` | opaque `Ref` | `term()` | `term()` | opaque passthrough (the boxed term layer) |
| multi-value results | tuple | tuple | tuple | positional, declaration order |
| a trap | `Result(_, Trap)` | `{ok,_}｜{error,Trap}` | `{:ok,_}｜{:error,_}` | catch the `rt_trap` exception at the boundary |

Integers are presented **signed** (what a host programmer expects from "i32") — a documented
presentation choice; the module itself is sign-agnostic on the bits.

### 3.5 The uniform emitter signature (frozen shape; bodies live in sibling units)

`iface.gleam`'s module docs freeze — and P12-02/03/04 each implement, in their own module — exactly:

```gleam
pub fn emit_gleam(iface: Iface)  -> List(GeneratedFile)
pub fn emit_erlang(iface: Iface) -> List(GeneratedFile)
pub fn emit_elixir(iface: Iface) -> List(GeneratedFile)
```

The return is a **`List`** (not one file) because Gleam and Elixir **cannot catch a BEAM exception
in-language**: surfacing a trap as a `Result` requires a tiny `.erl` catch shim, emitted as an
*additional* `GeneratedFile` (or FFI'd to one). Erlang catches natively and returns a single file.
P12-01 does not emit shims — it fixes *why* the signature returns a list, so all four downstream units
agree.

---

## §4. The work (ordered, buildable)

1. Create `src/twocore/backend/iface.gleam`; declare the five types (§3.1) with full `///` contract docs
   and a `////` module header that states the P1/P2 role and freezes the §3.5 emitter signature shape.
2. Promote `emit_core.state_reaching_closure` to `pub` (as `state_reaching_exports/1`); add its `///`
   contract. Record the cross-file reach in `state.md`. Confirm no emitted output changes.
3. Implement `host_types/1` (§3.4) — an exhaustive `case` over every `ValType` constructor (no `_`
   catch-all, so a future `ValType` forces a decision here).
4. Implement `describe/2` (§3.2) with the fail-closed order (Cell → import-bearing → build). Import
   `twocore/runtime/instance` and `twocore/backend/emit_core`.
5. `gleam format` → `gleam build` (zero warnings) → write the freeze tests (§5) → `gleam test`.
6. Verify default emission is byte-identical (no pipeline edit; run the existing corpus/conformance
   suite unchanged). Announce `«IFACE-DESC-FROZEN»` in `state.md`.

---

## §5. Tests (`iface_freeze_test.gleam`) — spec-cited + adversarial

Objective tests against the frozen contract + P2/P8, **not** change-detectors:

1. **Cell rejected (P8):** `describe(any_module, threaded_binding_with_state_strategy=Cell)` ⇒
   `Error(CellUnsupported)`. (Use `instance.safe_default()` — its `state_strategy` is `Cell` — as the
   ready-made witness.)
2. **Import-bearing rejected (P8):** a module with an `ImportFn` (and separately, one with
   `ImportGlobal`) under a `Threaded` binding ⇒ `Error(ImportBearingUnsupported)`.
3. **Pure module ⇒ `ImportFree`:** a module of side-effect-free functions ⇒ `Ok`, `state_model:
   ImportFree`, every `ExportSig.touches_state == False`, `params`/`results` equal to `ir.signature` of
   the target function.
4. **State-touching ⇒ `Threaded`:** an exported function whose body has `GlobalGet`/`MemStore` ⇒
   `touches_state == True`, `state_model: Threaded`.
5. **Adversarial — transitive closure (the §3.3 crux):** an exported PURE-bodied function that
   `CallDirect`s a `MemStore` helper ⇒ `touches_state == True`. (A shallow `expr_touches_state` would
   wrongly report `False`; this test is what enforces agreement with the emitted `n+1` arity.)
6. **Value-ABI mapping (P2):** assert `host_types/1` for **all nine** `ValType`s across all three
   languages exactly as the §3.4 table (`TI32`→`Int`/`integer()`/`integer()`; `TF64`→`Float`/`float()`/
   `float()`; `TV128`→`BitArray`/`binary()`/`binary()`; `TFuncRef`/`TExternRef`/`TExnRef`/`TTerm` →
   opaque `Ref`/`term()`/`term()`).
7. **Multi-value + float coexistence:** a module with an export returning `[TI32, TF64]` ⇒ `results`
   preserved in order (the emitters' tuple + float-round-trip cases build on this).
8. **Export ordering deterministic (P6):** exports appear in declaration order; a re-`describe` of the
   same module is equal.
9. **State exports skipped:** a module with an `ExportMemory`/`ExportGlobal` alongside an `ExportFn` ⇒
   `exports` contains only the function (documented §7 scope).

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. Spec-cited freeze tests (§5) green, including the adversarial transitive-closure case (added as a
   failing test first if the initial `describe` used the shallow predicate).
2. `///` contract docs on every public type/function (what / params-meaning / `Ok`-`Error` semantics /
   failure modes — incl. the documented `let assert` on the impossible unresolved-`fn_name` state).
3. `gleam format --check src test` clean.
4. `gleam build` zero warnings.
5. The unit suite passes; **default emission byte-identical** (no `.beam` changed — the only source edit
   outside the new module is promoting one private fn to `pub`, which changes no emitted code) and the
   existing corpus/conformance stay green.
6. `«IFACE-DESC-FROZEN»` announced in `state.md` with the cross-file reach recorded.

---

## §7. What it leaves (handoff to downstream)

- **P12-02/03/04 (emitters):** implement `emit_<lang>(Iface) -> List(GeneratedFile)` against the frozen
  types + `host_types/1`. They own: rendering syntax, the `.erl` catch shim (Gleam/Elixir), the
  `Instance` handle type (Gleam `opaque type` / Elixir struct / Erlang opaque `term`), and the
  state-free-export ergonomics (open seam #1 — drop `inst` under `ImportFree`; thread it under
  `Threaded`). They **must** honor the §3.3 ABI note: call every export at arity `param_count + 1`
  under `Threaded`, marshal `{ResultPackage, NewState}`, and treat multi-value `ResultPackage` as a
  bare list.
- **P12-05 (CLI):** call `describe/2`, fan out to the emitters, write `GeneratedFile`s under `--out`.
  Must pass a `module` whose `name` is the **final** loaded atom (compose with Phase-11 `--link`
  renaming — open seam #3). Absent flags ⇒ today's behavior unchanged.
- **P12-06 (capstone):** the compile+call differential (§P7) — the only unit that proves native results
  equal the in-process oracle.
- **Deferred (not this unit):** exported *state* (globals/tables/memories) as a typed surface;
  import-bearing provider surfaces; the Cell process-wrapped server binding — all P8-deferred.
