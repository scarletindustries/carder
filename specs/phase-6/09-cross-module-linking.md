# Unit P6-09 — Cross-module wasm→wasm function linking (the linker-built closure capability, I5)

> **One owner · Wave A · depends on `«XLINK»` (keystone P6-01 — the cross-module `ProvidedFunc`
> closure-dispatch contract head) and CONSUMES the frozen Phase-5 `runtime/link.gleam` substrate
> (`Provided`/`Provider`/`ImportError`/`link_imports`, R4), the test-side multi-instance
> `registry.gleam` + the `(register …)` command (P5-10b parses it), and the owned-process run-ABI
> (`pipeline.instantiate`/`invoke_instance`, E1/P4-08).** Read [`00-overview.md`](00-overview.md)
> (decisions **I1–I8**, esp. **I5/I6/I7**) first, then [`RECONCILIATION.md`](RECONCILIATION.md) once
> it lands (**S-decisions win over this doc where they conflict**), then the keystone
> [`01-keystone.md`](01-keystone.md) (§ the `«XLINK»` seam), then the Phase-5 unit this one extends —
> [`09-imports-spectest-linker.md`](../phase-5/09-imports-spectest-linker.md) (the provided-state /
> capability split H4, the fail-closed link resolver §B, the `Provided` externval model §A) — and the
> Phase-5 reconciliation **R4** (positional, typed, fail-closed instantiate contract), **R8**
> (reference globals). Phases 1–5 are complete and green: **1212 tests, 0 warnings, conformance
> `fail == 0`** under every shipped `(mode × state_strategy × mem_tier)` binding; the measured residual
> this unit closes is the **~1088-assert cross-module wasm→wasm FUNCTION-import** category
> (`test/twocore/conformance/conformance_test.gleam` §49–52).

---

## Context

Phase 5 made **non-function imports** run as provided state and shipped the fail-closed
instantiation/link contract (`runtime/link.gleam`, R4): an imported global/table/memory is wired
into the new instance's cell/record exactly like a defined one, and an unsatisfied / type-mismatched
import is a fail-closed link error (`assert_unlinkable`). It also shipped the official `spectest`
module (R14) and the `(register …)` command (P5-10b's `Script`). But it left **one thing measured
and deliberately unscoped**: a module that imports another module's **function** cannot *call* it.

Two facts pin the gap precisely, in the committed code:

1. **`link.gleam` already carries `ProvidedFunc(ty: FuncType)`** (P5-09 §A / `runtime/link.gleam`
   L100), but it is used **only for signature matching** — `resolve_fn_import` checks that a
   registered/`spectest` function import's declared type matches and then returns `Ok(None)` (**no
   positional element, no callable value**). There is no cross-instance dispatch value anywhere: the
   `ProvidedFunc` variant carries a type and nothing you can *invoke*.

2. **The WASM frontend cannot lower an imported-function call at all.** `lower.gleam`'s `lower_call`
   rejects every `call $f` whose `funcidx < imported` with `Error(Unsupported("imported call"))`
   (`frontend/wasm/lower.gleam` L1197–1198). No `CallHost` and no imported-function call node is
   ever produced by decode→lower; the only `CallHost` nodes in the tree come from hand-built `.ir`
   (the acceptance corpus). So *no generated WASM code today calls any imported function* — host or
   cross-module.

3. **The conformance harness keeps `env.providers` empty** on `(register)` (`runner.gleam` L200–207:
   "Registry aliasing is enough for a cross-module INVOKE … cross-module state IMPORT needs shared
   mutable state we do not thread"). So a later module importing a registered module's exports fails
   closed at link → its dependent assertions **skip** (a named category), never a false green. That
   skip set is the **~1088-assert residual**: `linking.wast`'s function-import call / re-export / trap
   assertions, and every `.wast` that imports and *calls* another module's function.

The load-bearing distinction this unit makes real is **the imported-function CALL is a capability,
delivered as a build-constructed closure** (I5): the WebAssembly spec instantiates a module against a
vector of external values, one per import; a **function** external value is a *function address* into
the store ([§4.5.4 instantiation](https://webassembly.github.io/spec/core/exec/modules.html#instantiation),
[§7.5 embedding](https://webassembly.github.io/spec/core/appendix/embedding.html#embed-module-instantiate)).
In 2core the store is per-instance and process-local (E1, one-instance-one-process), so a function
address is a **closure that routes a call into the exporting instance** — a capability the linker
hands the importer at link time, dispatched by `apply(Closure, Args)`, **never** an ambient
`apply(module, atom)` reconstructed from program data (D3a). An **unsatisfied or signature-mismatched**
function import is a fail-closed link error exactly as for state imports (`assert_unlinkable`, H6/I6).

The second thing this unit makes real is the **multi-instance registry composition**: `(register
"A" $a)` must make a prior instance's **functions** (and its globals/tables/memories) resolvable by a
later module's imports. P5 wired the *type-matching* half and the *state* half (snapshot); this unit
wires the **function-dispatch** half and states honestly which of the *state*-aliasing half remains a
categorized skip.

## Goal

> **A module B importing another module A's exported FUNCTION calls it correctly across instances via
> a linker-built closure capability — fail-closed on an unsatisfied/mismatched import
> (`assert_unlinkable`), D3a-clean (the dispatch is `apply(Closure, Args)` over a handed-in
> capability, never an ambient `apply(module, atom)`), so `linking.wast`'s function-import assertions
> stop skipping and the measured cross-module residual drops.**

Concretely: (1) `ProvidedFunc` carries a **`call: fn(List(Dynamic)) -> Dynamic`** dispatch closure the
linker builds capturing the exporting instance's live handle + its exported function; (2)
`link_imports` returns each cross-module function import as a **positional** `ProvidedFunc` element (a
runtime callable), matched **fail-closed** against the declared signature (spec §3.2 function
matching); (3) the `Registered(link_name, exports)` provider + the `(register …)` command compose so
a later module resolves an earlier module's **funcs / globals / tables / memories**; (4) the dispatch
**routes the call into the exporting instance's owning process** (so the callee runs against the
callee's live state — correct for a stateful callee, not just a constant-returning one) and
**propagates the callee's traps**; (5) it ships **cell-first for `linking.wast`** under the
owned-process run-ABI, with the genuinely-process-less cross-instance record-threading edge
**categorized honestly**; (6) it is **conformance-neutral by default** (I7) — an import-free / no-
function-import module is byte-identical to Phase-5 under both modes and every tier.

## Files owned (single-owner / additive — D1)

- **`src/twocore/runtime/link.gleam`** *(extend, single-owner-additive — P5-09 owns it, R4)* — the
  charter of this unit:
  - `Provided.ProvidedFunc(ty, call)` gains the **`call: fn(List(Dynamic)) -> Dynamic`** dispatch
    closure field (§B.1).
  - `resolve_fn_import` / `resolve_one` extended so a **cross-module (registered)** function import
    resolves to `Ok(Some(ProvidedFunc(ty, closure)))` (a **positional** element) instead of
    `Ok(None)`, matched fail-closed (§B.2). A **host** function import (`spectest`/genuine
    capability) resolves to `Ok(Some(ProvidedFunc(ty, host_closure)))` whose closure wraps
    `rt_host.call_host` — so **every** function import contributes exactly one positional slot,
    which is what makes the `emit_core` slot layout deterministic (§D.1, argued §Deviations).
  - `provided_func_call(p) -> fn(List(Dynamic)) -> Dynamic` — the emit-side extractor (the
    `link.provided_*` family, §D.2), fail-closed `panic` on a non-`ProvidedFunc` variant.
  - `provided_func(ty, call) -> Provided` — the constructor the register seam (P6-10) uses to build a
    function export without depending on the `Provided` tuple layout.
- **`src/twocore/runtime/profiles.gleam`** *(inspect / no change expected)* — cross-module linking
  adds **no new profile and no new `Binding` field** (§G): it composes with `safe()` / `safe_spectest()`
  / `portable()` unchanged. Documented here so P6-01 does not freeze a field this unit does not need.
- **`src/twocore/pipeline.gleam`** *(inspect / no change expected)* — the pipeline `instantiate`/
  `run_source` seam is unchanged (the harness owns the multi-instance `(register)` driving, §C.3);
  this unit only pins the *contract* the harness's instantiate-with-imports path already calls.

> **No new stub-day-1 freeze is produced here** — this unit is a leaf under `«XLINK»`. It
> **coordinates**: the generated imported-call codegen with **P6-06** (`emit_core` owns the emitter —
> §D, the `apply(Closure, Args)` seam + the positional-slot ABI growth + the D3a structural test);
> the imported-call *lowering* with **P6-05** (`lower.gleam` must stop rejecting an imported call and
> route it to the dispatch seam — §D.4); and the `(register)`/registry/harness plumbing + the
> conformance drive-through with **P6-10** (§C.3/§Verification). It flags — never claims — those files
> (D1).

## Deliverables & freeze milestones

**Consumes (frozen upstream):**

- `«XLINK»` (P6-01) — the keystone freezes the **`ProvidedFunc(ty, call)` shape** (the `call` field
  type `fn(List(Dynamic)) -> Dynamic`), the **positional-`Imports`-ABI growth to function imports**
  (one slot per function import), and the `provided_func_call` extractor head (so P6-06 compiles
  against a real signature immediately). This unit authors the **semantics**; the keystone freezes
  only the *shapes/names*.
- The Phase-5 `runtime/link.gleam` substrate (R4): `Provided`, `Provider {
  Registered(link_name, exports) }`, `ImportError { UnknownImport / IncompatibleImportType }`,
  `link_imports/2`, `import_error_phrase/1`, `spectest_export/1`, the `provided_*` extractor family,
  `limits_match/4`, `match_fn/4`.
- `rt_host.spectest_func_type/1` + `rt_host.call_host/3` (the host capability boundary — a host
  function import's dispatch closure wraps it, §B.3).
- The test-side `registry.gleam` (`define`/`register`/`resolve`, generic over the instance value) +
  the `(register …)` command (`fixture.Register`, parsed by both the JSON and WAT paths, P5-10b).
- The owned-process run-ABI (E1/P4-08): each instance is an owned process with a handle
  (`InstanceProc`/`runner.Instance`) whose `call_instance`/`call_instance_terms` route a synchronous,
  trap-catching call into it — the **routing primitive** the dispatch closure captures.
- `ir.ImportFn(capability, name, ty)` / `ir.ExportFn(export_name, fn_name)` / `ir.FuncType` (the
  frozen IR import/export/type shapes — **no new IR node**, I7/§H).

**Produces (this unit):**

- `link.ProvidedFunc(ty, call)` + `provided_func/2` + `provided_func_call/1`; the extended
  `resolve_fn_import`/`resolve_one` (cross-module function import → positional `ProvidedFunc`, fail-
  closed matching); the host-function-import dispatch-closure form.
- The **cross-module dispatch model** (§A): the routing closure that runs the callee against the
  callee's live state and propagates its traps, strategy-agnostic (Cell + Threaded, owned-process).
- The **registry-composition contract** (§C): what a `Registered` provider's `exports` map must carry
  for a cross-module function/global/table/memory import to resolve.
- The **D3a proof** (§Effect/security) that no ambient `apply(module, atom)` reaches program data,
  with a grep-verifiable recipe.
- The spec-cited tests (§Verification): `linking.wast` `$Mf`/`$Nf` (stateless call + re-export),
  `$Mg`/`$Ng` `get_mut`/`set_mut` (function routing observes the callee's *live* mutation),
  `$Mt`/`$Nt` `Mt.call` (imported `call_indirect` runs against the callee's table, + `uninitialized
  element` / `undefined element` trap propagation), the `assert_unlinkable` signature-mismatch cases
  (`reexport_f`), and **conformance-neutral** byte-identity for every non-function-import prior module.

**Freeze:** produces no new milestone; it is a prerequisite (with P6-05/P6-06) for the conformance
expansion (P6-10) and the capstone (P6-11).

## Depends on

| Needs | From | Why |
|---|---|---|
| `«XLINK»` | P6-01 | the `ProvidedFunc(ty, call)` shape + the positional-slot ABI growth + `provided_func_call` head units 05/06 compose against |
| P5 `link.gleam` substrate (R4) | P5-09 | the `Provided`/`Provider`/`ImportError`/`link_imports`/`match_fn`/`limits_match` this unit extends |
| `rt_host.call_host`/`spectest_func_type` | P5-09 (rt_host) | a host function import's dispatch closure wraps `call_host`; `spectest` function matching (§B.3) |
| the multi-instance `registry` + `(register)` | P5-10b / harness | the substrate that makes a prior instance's exports resolvable (§C) |
| the owned-process run-ABI (`call_instance`) | P4-08 / harness | the routing primitive the dispatch closure captures (§A.3) |
| imported-call lowering | **P6-05** | `lower.gleam` must stop rejecting an imported call and route it to the dispatch seam (§D.4) |
| imported-call codegen | **P6-06** | `emit_core` emits `apply(Closure, Args)` + grows the positional-`Imports` weave to function slots + the D3a structural test (§D) |
| `(register)`/registry drive-through + conformance | **P6-10** | populates `env.providers` with function-export closures; drives `linking.wast`; categorizes the aliasing residual (§C.3/§Verification) |

---

## A. The cross-module dispatch model — a build-constructed routing closure (I5)

### A.1 The model: a function external value is a closure that routes into the exporting instance

The spec's instantiation supplies one external value per import; a **function** external value is a
*function address* into the store ([§4.5.4](https://webassembly.github.io/spec/core/exec/modules.html#instantiation)).
2core's store is **per-instance and process-local** (E1): each instance is an owned process holding
its own memory/globals/table (a pdict cell under `Cell`, a threaded record loop-variable under
`Threaded` — P4-08). So a function address that leaves instance A and is imported by instance B is a
**closure that, when applied, runs A's exported function against A's live state and returns its
result** — dispatched by `apply(Closure, Args)`.

```gleam
/// The dispatch closure a cross-module function external value carries: it takes the call's
/// argument TERMS (D5 — a raw i32/i64/f32/f64 bit pattern is an Erlang integer; a reference is an
/// `rt_ref` term), routes the call into the EXPORTING instance (so the callee runs against the
/// callee's live state), and returns the callee's result PACKAGE (a `Dynamic` the caller unpacks
/// exactly like a defined multi-value call's package). It RAISES to propagate the callee's trap
/// (§E.2). Built at link time by the register seam (§C), NEVER by generated code (D3a).
type FuncCall = fn(List(Dynamic)) -> Dynamic
```

The invariant is: **the callee runs where its state lives.** A cross-module call is, from B's point of
view, a call to an opaque capability — the same shape as `call_host` (a host function leaves B's
values) and `externref` (an opaque handed-in term). B holds only the closure; it never learns A's
module name, A's process, or A's internal function names.

### A.2 Why NOT the provisional in-process apply — the load-bearing correction (argued §Deviations)

The provisional surface (`PROVISIONAL-SURFACE.md` §G) sketches the closure as
`fn(args){ a_instance:f(args) }` — a **direct in-process apply** of A's exported function in **B's**
process. That is correct **only for a callee whose transitive body touches no instance state**, and it
is *wrong* — silently, with a wrong-but-green result — for a stateful callee under `Cell`, and it does
not even type-check under `Threaded`. The three `linking.wast` families make this concrete:

| `linking.wast` callee | in-process apply in B (provisional) | correct (route into A) |
|---|---|---|
| `$Mf.call` → `call $g` → `i32.const 2` (stateless) | runs A's `call` in B, touches no state → **2 ✓** | **2 ✓** |
| `$Mg.get_mut` → `global.get $mut_glob` after `$Mg.set_mut(241)` | reads **B's** cell — B imported `mut_glob` as a *snapshot* (142) → **142 ✗** | reads **A's** live cell → **241 ✓** |
| `$Mt.call(2)` → `call_indirect` on `$Mt`'s table (slot 2 = `$g`→4) | reads **B's** table (B's `$g`→5) → **5 ✗** | reads **A's** table → **4 ✓** |
| `$Mt.call(1)` → `call_indirect` on `$Mt` slot 1 (null) | reads B's table → **wrong / wrong trap ✗** | traps `uninitialized element` in A, propagated → **✓** |

Under `Threaded` the in-process form is not even well-typed: A's export is emitted as `f(St, Args) ->
{Package, St'}` (it *consumes and returns* A's state record), and B does not hold A's record, so
`apply(A_module, f, Args)` is an arity/shape mismatch. **The only correct, strategy-independent
mechanism is to route the call into A's owning process**, where A's `Cell` pdict cell or `Threaded`
record loop-variable lives — exactly what the run-ABI already does for a normal `invoke`. This is the
refinement this unit ships; §Deviations records it as a formal deviation from the provisional surface.

### A.3 The routing primitive — the owned-process call, reused

Each instance's owning process (P4-08) already answers a **synchronous, trap-catching** request:
`call_instance(Pid, Field, Args)` applies `Module:Field(Args)` (under `Cell`) or `Module:Field(St,
Args…) -> {Package, St'}` and threads `St'` (under `Threaded`) **inside that process**, returning the
result package or an `Error(trap_reason)` (harness `twocore_conformance_ffi:call_instance` /
`call_instance_terms`; production `pipeline.invoke_instance`). The dispatch closure **captures the
exporting instance's handle + the export field** and, on application, performs this route (§E for the
term/trap contract):

```
closure = fun(Args) ->
  case route(A_handle, "call", Args) of        %% synchronous request into A's process
    {ok, Package}   -> Package;                %% A returned normally → the caller's result package
    {trap, Reason}  -> raise({wasm_trap, Reason})   %% A trapped → re-raise in the CALLER (§E.2)
  end
end
```

`route` is a **handed-in capability** (the run-ABI's `call_instance` seam), not an ambient reference:
the register seam that owns A's live handle constructs the closure with `route` + `A_handle` +
`"call"` all supplied explicitly (§C.2). Because the routing goes through the *process* (which
abstracts `Cell` vs `Threaded`, exactly as the run-ABI self-detects the strategy from the instantiate
return, P4-08 §C.2), **the same closure works under both state strategies** — see §F.

---

## B. The extended `Provided` + `link_imports` (fail-closed function matching)

### B.1 `ProvidedFunc` carries the dispatch closure

```gleam
/// A resolved external value supplied to an instance for ONE of its imports (spec §4.5.4). The
/// P5 state variants (ProvidedGlobal/RefGlobal/Table/Memory) are UNCHANGED. `ProvidedFunc` gains
/// the dispatch closure — a function import is NOW a first-class runtime callable, not only a
/// signature.
pub type Provided {
  ProvidedGlobal(value: Int, ty: ValType, mutable: Bool)
  ProvidedRefGlobal(value: Dynamic, ty: ValType, mutable: Bool)
  ProvidedTable(value: Dynamic, ref_ty: RefType, min: Int, max: Option(Int))
  ProvidedMemory(value: Dynamic, min_pages: Int, max_pages: Option(Int), idx_type: IdxType)
  /// A FUNCTION external value (spec §4.5.4 func address). `ty` drives fail-closed function
  /// matching (§B.2, spec §3.2.7). `call` is the build-constructed dispatch closure (§A.1):
  /// applied by the importer's generated code as `apply(call, Args)` (D3a — a handed-in
  /// capability, never an ambient `apply(module, atom)`). For a CROSS-MODULE import `call`
  /// routes into the exporting instance (§A.3); for a HOST import `call` wraps
  /// `rt_host.call_host` (§B.3). Unlike P5, `ProvidedFunc` now DOES contribute a positional
  /// `Imports` slot (the runtime callable the generated caller applies) — the ABI growth is
  /// argued in §Deviations.
  ProvidedFunc(ty: FuncType, call: fn(List(Dynamic)) -> Dynamic)
}

/// Constructor for a function external value (so the register seam / spectest provider build a
/// `ProvidedFunc` without depending on its tuple layout — the D1-clean shape ABI). `ty` is the
/// export's signature; `call` the dispatch closure (§A/§C.2).
pub fn provided_func(ty: FuncType, call: fn(List(Dynamic)) -> Dynamic) -> Provided {
  ProvidedFunc(ty:, call:)
}
```

### B.2 Resolution + matching — cross-module function imports become positional slots, fail-closed

`link_imports(module, providers) -> Result(List(Provided), ImportError)` is unchanged in signature;
its **walk** now returns a positional `ProvidedFunc` for every function import that needs a runtime
callable, matched fail-closed. The change is entirely in `resolve_fn_import` (and thereby `resolve`,
which already threads `Ok(Some(_))` into the positional accumulator and `Ok(None)` skips):

```gleam
/// Resolve a FUNCTION import to its dispatch closure (§A) + match its signature fail-closed
/// (spec §3.2.7 function matching — a provided function matches iff its type is EQUAL to the
/// declared import type; functions are invariant). Returns `Ok(Some(ProvidedFunc(ty, closure)))`
/// — a POSITIONAL callable slot — on a match, or `Error(ImportError)` fail-closed.
///
/// - `#("spectest", name)`: matched against `rt_host.spectest_func_type(name)`; the closure wraps
///   `rt_host.call_host("spectest", name, _)` (§B.3). A missing name → `UnknownImport`; a mismatch
///   → `IncompatibleImportType` (the `reexport_f` `assert_unlinkable` cases).
/// - `#(registered_mod, name)`: `registered_mod` is a `(register)`ed provider (`is_registered`);
///   its export `name` must be a `ProvidedFunc(sig, closure)` — match `sig == ty`, return that
///   provider-built closure (the routing capability, §C.2). A missing export → `UnknownImport`; a
///   non-function export → `IncompatibleImportType("expected a function")`; a signature mismatch →
///   `IncompatibleImportType("function signature")`.
/// - `#(other_capability, name)`: NEITHER spectest NOR registered → a genuine host capability
///   (e.g. `env`). NOT link-checked (its fate is the call-site `HostPolicy`); resolved to a
///   host closure wrapping `call_host` (§B.3), gated fail-closed at call time. (Preserves the P5
///   posture that a genuine host import is a call-site capability, not a link error.)
fn resolve_fn_import(
  capability: String,
  name: String,
  ty: FuncType,
  providers: List(Provider),
) -> Result(Option(Provided), ImportError)
```

The matching table (spec [§3.2 import matching](https://webassembly.github.io/spec/core/valid/matching.html),
functions [§3.2.7](https://webassembly.github.io/spec/core/valid/matching.html#functions) — **equality**,
via the existing `match_fn/4`), unchanged in direction from P5 but now returning the **closure-bearing**
`Ok(Some(ProvidedFunc(ty, closure)))` rather than `Ok(None)`:

| Function import `#(cap, name)` | provider | on match | on miss / mismatch |
|---|---|---|---|
| `#("spectest", name)` | `rt_host.spectest_func_type(name)` | `Ok(Some(ProvidedFunc(ty, host_closure)))` | `UnknownImport` / `IncompatibleImportType` |
| `#(reg, name)`, `reg` registered | provider's `ProvidedFunc(sig, closure)` | `Ok(Some(ProvidedFunc(ty, closure)))` (sig==ty) | `UnknownImport` / `IncompatibleImportType` |
| `#(other, name)`, unregistered | — (host capability) | `Ok(Some(ProvidedFunc(ty, host_closure)))` | *(never a link error — call-site gated)* |

The **first** failure short-circuits (`resolve` already `try`s each import), and no instance is
instantiated (fail-closed, H6/I6). The positional `Imports` list order is the module's **import
declaration order** (unchanged, spec [§2.5.1](https://webassembly.github.io/spec/core/syntax/modules.html#indices)
— imports precede definitions), now with one element **per function import** interleaved with the
state slots. State-import resolution (`ImportGlobal`/`ImportTable`/`ImportMemory`) is **unchanged**
from P5 (§B.2 of the Phase-5 doc): `limits_match`, mutability/type equality, snapshot value.

### B.3 The host function import's dispatch closure (uniformity — argued §Deviations)

Because `emit_core` bakes the positional-slot layout statically from the `ImportDecl` list at
**compile** time — and cannot know at compile time whether a given `#(cap, name)` will resolve to a
cross-module wasm export or a host capability at **link** time (both are `(import "mod" "name"
(func))`, resolved only against the *providers* present at link) — **every** function import must
contribute exactly one positional slot, or the slot layout would be link-dependent and `emit_core`
would not be deterministic-from-the-IR (breaking H7 byte-identity). Therefore a **host** function
import also yields a `ProvidedFunc`, whose closure wraps the existing capability boundary:

```gleam
/// A host function import's dispatch closure — the fail-closed capability boundary as a callable.
/// It marshals the arg terms to raw bit patterns (D5 — every host arg is a numeric i32/i64/f32/f64
/// bit pattern, spec `spectest.print*` §C.1), applies the per-instance `rt_host.call_host` (which
/// gates under THIS instance's `HostPolicy` — deny-all by default, `safe_spectest()` admits the
/// six/seven `spectest` prints), and packages the result. `call_host` RAISES the catchable
/// `{capability_denied, Cap, Name}` on a denied call, so a denied host import surfaces as a trap
/// exactly as before (no path around the gate). NEVER an `apply(module, atom)`: `Cap`/`Name` are
/// build-controlled strings captured at link time, and `call_host` dispatches a build-fixed handler
/// closure directly (rt_host §D3a).
fn host_func_closure(cap: String, name: String) -> fn(List(Dynamic)) -> Dynamic
```

This keeps the host-import path's semantics (fail-closed `HostPolicy` gating, `call_host` dispatch)
**exactly** as Phase-3/5 established — it only re-homes them behind a positional capability slot so the
codegen is uniform. `linking.wast` never *calls* a host import (the `reexport_f` cases are
signature-only `assert_unlinkable`), so this closure is exercised for **linking** (matching) but its
*invocation* is proved by the `spectest`-print differential (§Verification #7), not required for the
`linking.wast` DoD.

### B.4 What is UNCHANGED (P5 confirmed sound)

- **State-import resolution + matching** (`ImportGlobal`/`Table`/`Memory`, §B.2 P5-09): the
  mutability/type equality for globals, `limits_match`'s direction (`pmin ≥ dmin`, `pmax ≤ dmax`
  under a capped import), the `idx_type` equality for memories, snapshot value. Unchanged.
- **`spectest_export/1`** (the state provider — four globals, table, memory, R14) and the
  `spectest_func_type/1` signature table (§B.3). Unchanged.
- **`import_error_phrase/1`** — `"unknown import"` / `"incompatible import type"` (the spec link
  phrases, `assert_unlinkable` matching). Unchanged.
- **Fail-closed, no ambient default** (H6, spec §4.5.4): a missing import is never fabricated; only
  build-controlled providers (the fixed `spectest` + the explicitly-`(register)`ed instances) supply
  externvals; names select **among** providers, never **construct** a target (§Effect/D3a).

---

## C. The multi-instance registry + `(register …)` composition

### C.1 The `(register …)` command and the registry (P5 substrate)

`(register "A" $a)` records module `$a`'s exports under link-name `"A"`
([`linking.wast`](../../build/conformance-vendor/linking.wast): `(register "Mf" $Mf)` etc.). The
test-side `registry.gleam` already models the three bindings a `.wast` file builds up — `current` (the
default invoke target), `named` (definition `$name`), `registered` (link-name) — and `register/3`
aliases a prior instance under a link-name (`registry.gleam` L49–56, generic over the instance value).
The command is parsed by both conformance paths (`fixture.Register`, JSON + WAT — P5-10b). This unit
**adds no registry code**; it defines what the registry's instance value must **carry** so a later
module's imports resolve (§C.2), and the runner change that flows it into `link_imports` (§C.3).

### C.2 What a `Registered` provider's `exports` map must carry (the contract)

`link_imports` consumes `Provider { Registered(link_name: String, exports: Dict(String, Provided)) }`
(P5-09 §B.1, unchanged shape). To make a prior module A's exports resolvable, the register seam
populates `exports` — keyed by A's **export name** — with one `Provided` per exported entity, built
**capturing A's live handle**:

| A's `ExportDecl` | `exports[export_name] =` | built from |
|---|---|---|
| `ExportFn(export_name, fn_name)` | `ProvidedFunc(sig, closure)` where `closure = fun(Args) -> route(A_handle, export_name, Args) end` (§A.3) and `sig` is A's export signature | A's IR signature (`ir.signature` of `fn_name`, or the re-exported import's `FuncType`) + A's owning-process handle |
| `ExportGlobal(export_name, global_name)` | `ProvidedGlobal(bits, ty, mutable)` **or** `ProvidedRefGlobal(value, ty, mutable)` (R8) — the **snapshot** value read from A at register time | A's live global read (P5 §E.1 accessor) |
| `ExportTable(export_name, table_name)` | `ProvidedTable(value, ref_ty, min, max)` — the opaque table externval (snapshot) | A's table externval (P5) |
| `ExportMemory(export_name, mem_index)` | `ProvidedMemory(value, min_pages, max_pages, idx_type)` — the opaque memory externval (snapshot) | A's memory externval (P5) |

The **crucial asymmetry** (stated honestly, §F.2): a **function** export carries a *live-routing
closure* (every call re-enters A's process and sees A's current state), so a later importer that
mutates A through one imported function and observes through another sees the mutation — **correct**.
A **state** export (global/table/memory) carries a *snapshot* (P5 §E.2 value semantics), so a later
importer reading the imported *state directly* sees the register-time value — the **categorized
aliasing skip** P5 already flagged, unchanged. This is why `$Mg`/`$Ng`'s function-routed
`Mg.get_mut → 241` passes while `$Ng`'s directly-imported-`mut_glob` read stays a categorized skip
(§F.2, §Verification #3).

A **re-exported imported function** (module #3 `(import "spectest" "print_i32") (export "print"
(func $f))`) is exported with `sig` = the imported function's type; its `closure` routes into #3's
process and calls #3's `"print"` export, which dispatches to #3's own import slot. `linking.wast` only
tests such re-exports for **signature** (`reexport_f` `assert_unlinkable`), so the closure's routing
chain is exercised for matching, and its invocation for a re-exported *cross-module* function is
covered by `$Nf "Mf.call"` (§Verification #1).

### C.3 The runner drive-through (P6-10 — flagged, not owned)

The Phase-5 runner keeps `env.providers` **empty** on `(register)` (`runner.gleam` L200–207) — the
deliberate P5 depth-honesty gate. **P6-10 flips it on**: on `Register(as_name, module)`, after the
registry aliases the instance, the runner assembles a `Registered(as_name, exports)` provider whose
`exports` map is built per §C.2 (reading A's live handle + export signatures from the instance's
`export_types`), and appends it to `env.providers`. Then a later `ModuleCmd` runs
`link_imports(module_ir, env.providers)` (already the driver's call, `driver.gleam` L209–211) and the
cross-module imports resolve. `link_imports` + the `Provided`/closure contract are **this unit's**;
the runner assembly + the `route` capability wiring are **P6-10's** (the harness owns the FFI + the
live handles), specified here as the seam it calls. The ordering the spec's `(register)` semantics
already guarantee — **A is registered (hence instantiated, hence a live process) before B is
defined** — is exactly what the routing closure needs (A's handle exists at B's link time).

---

## D. The generated-code seam — `apply(Closure, Args)` (P6-05 lower + P6-06 emit, flagged)

This unit does not edit `lower.gleam` or `emit_core.gleam`; it pins the contract they satisfy, so the
`«XLINK»` seam is unambiguous.

### D.1 The positional-`Imports` ABI growth (the deterministic slot layout)

Today the positional `Imports` list carries **one element per STATE import**
(`count_state_imports`/`imported_slots` skip `ImportFn`, `emit_core.gleam` L3016 / L3206). This unit
grows it to **one element per import that needs a runtime value** = every state import (unchanged) +
**every function import** (its `ProvidedFunc` closure), in import-declaration order. Concretely
(P6-06):

- **`count_state_imports` → `count_import_slots`**: count `ImportFn` as `+1` too (so an import-
  bearing-by-function module gets `instantiate/1`). *Byte-identity note:* a module with **no** imports
  keeps `instantiate/0` (H7). A module importing only functions it never references could avoid a slot
  (see Open Q 1) — the recommended rule is **one slot per function import declaration** (simplest,
  matches R4 "positional, name-free"); the byte-identity cost falls only on already-import-bearing
  modules and is additive.
- **`imported_slots` gains an `ImportFn` arm**: consume the positional var `Imp<p>` (advance `p`) and
  install its closure into the instance's **imported-function dispatch vector** via
  `link.provided_func_call(Imp<p>)` (§D.2) — a new component alongside the `FullDecl`'s mems/globals/
  tables/ref-globals, keyed by the imported function's local funcidx `f<idx>` (imports occupy the low
  funcidx range, spec §2.5.1).

### D.2 The emit-side extractor (the `link.provided_*` family)

`emit_core` weaves each positional `Imp<p>` through a **fixed `link` module call** chosen statically
by the import's kind (D3a — `emit_core.gleam` L3218–3256 for the state extractors). This unit adds the
function extractor:

```gleam
/// Extract the dispatch closure from a `ProvidedFunc` (for the imported-function dispatch vector
/// slot, §D.1). Fail-closed `panic` on any other variant (an internal codegen invariant — 06
/// pairs the extractor with the import kind; a `panic` is node-safe, never a WASM trap — matching
/// `provided_global_bits`/`provided_table_value` etc.).
pub fn provided_func_call(p: Provided) -> fn(List(Dynamic)) -> Dynamic {
  case p {
    ProvidedFunc(_, call) -> call
    _ ->
      panic as "link.provided_func_call: not a function (internal invariant violation)"
  }
}
```

### D.3 The imported-function call → `apply(Closure, Args)` (P6-06)

`emit_core` lowers an imported-function call — a `CallDirect` whose target funcidx is imported (or a
`CallIndirect` whose resolved slot holds an imported funcref, §D.5) — to a **closure application** of
the instance's dispatch-vector slot for that funcidx:

```
%% call $f  where $f is imported funcidx k → apply the dispatch-vector's slot-k closure
let <Rs> = apply ImpFun_k (Arg1, …, Argn)   %% erlang:apply/2 on a FUN — NOT apply/3 on a module
in  …unpack Rs into the caller's result value(s)…
```

`ImpFun_k` is read from the instance state (the dispatch vector seeded at `instantiate/1`), addressed
by the **static** funcidx `k` (baked by emit from the import order — no runtime name lookup, D3a). The
result package `Rs` is unpacked exactly like a defined multi-value `CallDirect`'s package (single-
result → the bare value; multi-result → destructure the package). Under `Threaded` the cross-instance
call touches no B-state, so it composes as a *pure* call in B's state channel (the record threads
through unchanged, §F.1).

### D.4 The lowering change (P6-05)

`lower.gleam`'s `lower_call` must **stop rejecting** an imported call (`Unsupported("imported call")`,
L1197–1198) and instead produce the imported-call node the emit seam consumes. The cleanest shape
(P6-05/P6-06 pick, flagged §Open-Q 2): reuse `ir.CallDirect("f<funcidx>", args)` with the funcidx in
the imported range — `emit_core` already distinguishes imported vs defined funcidx by the
imports-first index space (`ctx.imported`, `emit_core.gleam` L1197 analogue), so no new IR node is
needed (I7 — the imported-function capability is a *runtime dispatch* decision, not an IR shape).
Validation (P6-04) already types an imported `call` against the import's signature; lower need only
allow it through.

### D.5 `CallIndirect` through an imported funcref (flagged for P6-06 / rt_table)

A cross-module funcref — an imported function `ref.func`'d into a table, or an imported *table* whose
slots hold the exporter's funcrefs — is a `funcref` value `{FuncType, Closure}` (R1) whose `Closure`
is the routing closure (§A). `call_indirect` applies it exactly as it applies a same-module funcref
closure (`rt_table` dispatch, unchanged shape). This unit provides the closure (via the `ProvidedFunc`
/ `ref.func`-of-import path); the `rt_table` funcref-dispatch reuse is **P6-06/P6-07's**, flagged here
because `linking.wast`'s `$Nt`/`$Ot` tables mix imported and defined funcrefs
(`(table funcref (elem $g $g $g $h $f))` where `$f`, `$h` are imported).

---

## E. Term marshalling + trap propagation across the instance boundary

### E.1 The value model crosses the process boundary soundly (D5/R1)

The routing closure carries **argument terms** and returns a **result package**; both cross a process
boundary (a synchronous send/receive), which **copies** terms. The 2core value model is copy-sound:

- **Numeric values** (i32/i64/f32/f64) are **raw bit patterns as Erlang integers** (D5) — copied
  exactly (an i64 bignum, an f32/f64 raw-bit integer; NaN/Inf/`-0.0` bit-exact, never a BEAM double).
- **References** are `rt_ref` terms (R1): `{ref_null}`, `{ref_extern, Term}` (the wrapped host term —
  copied, opacity preserved: the importer still cannot forge or inspect it, H6), or a `funcref`
  `{FuncType, Closure}` (the closure copied to the caller — sound on the BEAM; for a cross-instance
  funcref the closure is itself a routing closure, §D.5).

So the argument/result marshalling is the run-ABI's existing term ABI (`call_instance_terms` +
`ffi.result_list`, R17/R18), reused: a numeric-only cross-module call may use the integer fast-path
(`call_instance`), a reference-touching or multi-value one the term path. No new marshalling is
invented — the cross-module call is an *ordinary invoke* of A, routed by the closure.

### E.2 Trap propagation — the callee's trap becomes the caller's trap (spec §4.4.7)

Per the spec, a trap in a called function propagates to its caller
([§4.4.7 function calls](https://webassembly.github.io/spec/core/exec/instructions.html#function-calls);
a trap terminates the whole computation). A cross-module call must preserve this: if A's function
traps (`unreachable`, a division trap, `MemoryOutOfBounds`, `uninitialized`/`undefined element` on A's
`call_indirect`, or a `{capability_denied,…}` inside A), **B's caller must trap identically**, so an
`assert_trap` matches the spec phrase. The routing seam already **catches** A's exception (to return a
result over the synchronous boundary) and yields `Error(reason)`; the dispatch closure therefore
**re-raises** that reason in B's process so it rides the same catchable `{wasm_trap, Kind}` channel
B's own traps use:

```
{trap, Reason} -> raise({wasm_trap, Reason})   %% B's invoke surfaces Trapped(Reason) — spec phrase preserved
```

`linking.wast` pins this hard: `(assert_trap (invoke $Nt "Mt.call" (i32.const 1)) "uninitialized
element")` — the imported `Mt.call(1)` must trap `uninitialized element` **in A's table**, propagated
to B's `Nt "Mt.call"` invoke (§Verification #4). A **non-propagating** closure (swallowing the trap or
mapping it to a wrong reason) is a spec violation the test catches.

### E.3 No re-entrancy hazard beyond the spec (bounded, node-safe)

Cross-module calls form a **directed** call graph fixed by `(register)` ordering (A registered before
B; B may call A, A cannot call B — A linked no B closure). Mutual recursion across instances is not
expressible in a single `.wast` link chain (the later module holds the earlier's closure, not vice
versa), so the synchronous routing cannot deadlock on a self-cycle. Fuel + preemption still bound each
instance's own execution (Phase-3/4); a cross-module call is metered inside the **callee's** process
(the callee charges its own fuel). The worst case of a cross-module bug is a wrong result, a wrong/
missing trap, or a node-safe crash in one process — **never a host escape** (the closure only routes
into a build-controlled instance process, §Effect).

---

## F. State-strategy reach — cell-first, honestly (I5 open-Q d)

### F.1 Cross-module dispatch is process-based, hence strategy-agnostic for the caller

The dispatch routes into the **exporting instance's owning process** (§A.3), which abstracts the
exporter's internal `state_strategy` exactly as the run-ABI does (P4-08 §C.2 self-detects `Cell` vs
`Threaded` from the instantiate return and threads the record under `Threaded`). From the **caller's**
side, `apply(Closure, Args)` is a call that touches no caller state, so:

- Under **`Cell`** (the Safe default, the `linking.wast` target): B applies the closure; A runs in A's
  process against A's pdict cell; B's cell is untouched. Correct and shipped.
- Under **`Threaded`** (the runs-anywhere `portable()` build): B's generated code threads its record
  `St` through the call site unchanged (the cross-instance call is *pure* in B's state channel — it
  returns only the result package, no `St'`); A runs in A's process threading A's own record. **The
  same closure works** — the process boundary hides A's threading from B.

So **linking works under both strategies in the owned-process run-ABI** (both `Cell` and `Threaded`
host each instance as a process). `linking.wast` is proven **cell-first** (Safe default) and the
`portable()`/`Threaded` differential rides the same routing.

### F.2 The honest categorized edges (never a silent mis-pass)

Two edges are stated plainly so the conformance report (P6-10) categorizes them, never overstates
`linking.wast`, and never green-passes an aliasing case:

1. **The process-less runs-anywhere edge (deferred, categorized).** The *intent* of `Threaded` is a
   deployment with **no processes at all** — a single call chain threading records purely
   functionally. In that mode a cross-instance call would need the caller to hold and thread **every
   linked instance's record** (A's record threaded into B's call site and back), which is invasive
   (multi-record threading through the whole call graph). The shipped run-ABI hosts instances as
   *processes* (so this edge does not bite `linking.wast`), and the pure-process-less multi-record
   threading is **deferred / categorized**, exactly as P5 categorized spectest-memory-under-atomics.
   Stated, not silently assumed.

2. **The imported-STATE-aliasing edge (unchanged P5 categorized skip, §E.2 of the Phase-5 doc).** A
   later module reading an **imported mutable global / table / memory DIRECTLY** sees the *snapshot*
   captured at register time (value semantics, §C.2), not the exporter's subsequent mutation — so
   `linking.wast`'s `$Ng` directly-reading imported `mut_glob` after `$Mg.set_mut(241)` is a
   **categorized skip** (`cross-module state aliasing → deferred`). This is **not** contradicted by
   the function-routing win: `$Ng`'s **function-imported** `Mg.get_mut` routes into Mg and reads the
   live 241 (**passes**), while `$Ng`'s **state-imported** `Mg.mut_glob` read is snapshot 241-vs-142
   depending on register timing (**categorized**). The report distinguishes the two per-assertion.

The measured effect: the ~1088-assert **function-import** residual **drops** as the call / re-export /
trap assertions light up; the imported-mutable-*state*-aliasing sub-residual stays a **named**
categorized skip. The headline is whatever is **measured** (R16), never promised.

---

## G. `profiles` / `pipeline` — no new axis, no new field

Cross-module linking adds **no new profile, no new `Binding` field, and no new pipeline stage** (I7).
A cross-module import is resolved by `link_imports` (already called by the driver before compile,
`driver.gleam` L209–211) against `env.providers` (assembled by the runner, §C.3); the closure is a
runtime value threaded through `instantiate/1`, never a build-time binding. So:

- `profiles.safe()` / `safe_spectest()` / `portable()` compose with cross-module linking **unchanged**
  — a cross-module-importing module links under exactly the binding it would otherwise. (A module that
  also imports `spectest.print*` and *calls* it still needs `safe_spectest()`'s whitelist for the host
  closure's `call_host` gate, §B.3 — unchanged from P5.)
- The **per-instance policy is the unit of trust** (§13, I6): a Safe instance importing an Unsafe
  instance's function calls it through the routing closure; the callee runs under **its own** linked
  runtime posture in **its own** process (the closure does not carry the caller's policy into the
  callee). This is the existing isolation boundary, reused — no widening.

This section is documented so **P6-01 does not freeze a `Binding` field or a profile this unit does
not need**; if reconciliation finds a production embedder needs a `route` capability field on the
binding (the harness supplies it via FFI, §C.3), that is flagged in Open Q 3, not assumed here.

---

## Effect / soundness / security note

- **The dispatch is a handed-in capability, never ambient authority (D3a) — the full proof.** Trace
  every step of a cross-module call and confirm no dispatch target (module or function atom) is ever
  constructed from program/attacker data:
  1. **Generated caller (in B):** `apply(ImpFun_k, Args)` — an `erlang:apply/2` on a **fun value**
     read from the instance's dispatch vector at the **static** funcidx `k` (baked by `emit_core` from
     the import order). It is **not** `erlang:apply/3` on a `(Module, Function)` pair, and `k` is a
     compile-time constant, never a runtime name. ✓
  2. **The closure (built by the register seam, §C.2):** `fun(Args) -> route(A_handle, "call", Args)
     end` — `A_handle` (A's live process handle) and `"call"` (A's export name) are **captured at
     register time** from build-controlled sources (A's IR export list + A's owning process); `route`
     is the handed-in run-ABI seam. Nothing here is derived from B's program at call time. ✓
  3. **Inside A's process (the run-ABI receive loop):** `apply(A_module, "call", Args)` — `A_module`
     is the **build-controlled** loaded instance module (fixed at A's compile+load), and `"call"` is
     A's own export (Core Erlang exports only A's declared exports, so a bogus field fails `undef`
     fail-closed, never reaching an internal `f<idx>`). This is the **existing** `call_instance`
     run-ABI, already D3a-clean; the export list **is** A's capability surface. ✓
  4. **Host function imports (§B.3):** the closure applies `rt_host.call_host(Cap, Name, _)` with
     build-controlled `Cap`/`Name`; `call_host` dispatches a **build-fixed handler closure** directly
     (rt_host §D3a), never `apply/3` on a data-derived module. Gated fail-closed by `HostPolicy`. ✓

  **Grep-verifiable (the P6-06 D3a structural test extends the Phase-3/5 one):** the emitted `.core`
  for the imported-call path contains **only** closure-application (`apply Fun (Args)` — `c_apply` with
  a variable head), and **zero** `call '<Mod>':'<F>'(…)` whose `<Mod>` is derived from an import name.
  The one `apply/3` in the whole chain is inside A's build-controlled owned-process shim (the run-ABI),
  not in any importer's generated body.
- **Fail-closed linking (H6, spec §4.5.4).** An unsatisfied cross-module/`spectest` function import
  (`UnknownImport`) or a signature mismatch (`IncompatibleImportType`) is a link error → the instance
  is not created → `assert_unlinkable "unknown import" / "incompatible import type"`. No ambient
  default fabricates a missing function; the only providers are the fixed `spectest` + the explicitly
  `(register)`ed instances (§B.4).
- **Trap = capability boundary preserved (§E.2).** A cross-module call surfaces the callee's trap
  (including a `{capability_denied,…}` inside the callee) as the caller's trap — no path lets B
  observe a partial effect or bypass A's own fail-closed gates. A denied host closure (§B.3) raises;
  the deny surfaces as a trap.
- **`externref`/opacity preserved (R1/D5).** A reference argument/result crossing the process boundary
  is copied as an opaque `rt_ref` term; the importer holds/null-tests but cannot forge or inspect it.
- **Isolation is the unit of policy (I6/§13).** The callee runs in its own process under its own linked
  posture and fuel; a cross-module call cannot widen the caller's capability surface or the callee's.
- **Conformance-neutral (I7/H7).** A module with **no function imports** (and no SIMD, single 32-bit
  memory, no cross-module imports) emits **byte-identically** to Phase-5: `count_import_slots` returns
  `0` → `instantiate/0` unchanged; the `ProvidedFunc.call` field is unused by import-free modules; the
  extended `resolve_fn_import` is reached only for a module that actually declares a function import.
  The whole Phase-1..5 corpus + prior suite stay byte-identical under both modes and every tier
  (assert it, §Verification #6).

## Verification — Definition of Done (D8)

Tests assert **spec behaviour** (the WebAssembly instantiation/link/call semantics, the reference
`linking.wast` expected values), never "whatever the code emits" (no change-detector tests). Cite the
spec: [§4.5.4 instantiation](https://webassembly.github.io/spec/core/exec/modules.html#instantiation),
[§3.2 import matching](https://webassembly.github.io/spec/core/valid/matching.html) (functions
[§3.2.7](https://webassembly.github.io/spec/core/valid/matching.html#functions)),
[§4.4.7 function calls / traps](https://webassembly.github.io/spec/core/exec/instructions.html#function-calls),
[§7.5 embedding](https://webassembly.github.io/spec/core/appendix/embedding.html), and the suite file
[`linking.wast`](../../build/conformance-vendor/linking.wast). **"Done" = the cross-module link suite
passes** (`linking.wast`'s function-import assertions move skip→pass; the aliasing sub-residual is a
*categorized* skip), never "it compiles."

1. **Cross-module function call + re-export (`linking.wast` `$Mf`/`$Nf`).** `$Mf.call → 2`;
   `$Nf` imports `Mf.call` as `$f`, re-exports it, and calls it. Assert: `invoke $Mf "call" == 2`;
   `invoke $Nf "Mf.call" == 2` (the **re-exported** imported function, routed into `$Mf`);
   `invoke $Nf "call Mf.call" == 2` (`$Nf` **calls** the imported function via `apply(Closure, [])`);
   `invoke $Nf "call" == 3` (`$Nf`'s own `$g`, not `$Mf`'s — proving the closure routes to the right
   instance, not the caller). Sourced from `linking.wast` L1–19.
2. **Fail-closed function signature mismatch (`reexport_f`, spec §3.2.7).** A module re-exports
   `spectest.print_i32` as `print`; assert `assert_unlinkable (module (import "reexport_f" "print"
   (func (param i64))))` → `IncompatibleImportType` → `"incompatible import type"`, and the same for
   `(func (param i32) (result i32))`. Assert the **satisfying** counterpart (`(func (param i32))`)
   links `Ok`. Also assert an **unsatisfied** function import (`#("no_mod", "f")`) → `UnknownImport` →
   `"unknown import"`, and a missing registered export (`#("Mf", "nope")`) → `UnknownImport`. The
   instance is never created (fail-closed, H6).
3. **Function routing observes the callee's LIVE state (`$Mg`/`$Ng`, spec §4.4.7).** `$Mg` exports
   mutable `mut_glob` + `get_mut`/`set_mut`; `$Ng` imports `Mg.get_mut`/`Mg.set_mut`. Assert:
   `invoke $Mg "set_mut" (241)` then `invoke $Ng "Mg.get_mut" == 241` — the **function-routed** read
   sees `$Mg`'s live mutation (the closure runs `get_mut` in `$Mg`'s process). Assert the same for the
   `$Mt`/`$Nt` `call_indirect` case: `invoke $Nt "Mt.call" (2) == 4` (routes to **`$Mt`'s** table,
   returns `$Mt`'s `$g`→4, **not** `$Nt`'s `$g`→5). **Explicitly categorize** the sibling
   `directly-imported-mutable-state` reads (`get $Ng "Mg.mut_glob"`) as a named skip (§F.2), never a
   silent pass.
4. **Trap propagation across the boundary (§E.2, spec §4.4.7).** `assert_trap (invoke $Nt "Mt.call"
   (1)) "uninitialized element"` and `(20)) "undefined element"` — the imported `Mt.call` traps in
   `$Mt`'s table and the trap propagates to `$Nt`'s invoke with the spec phrase. Assert `$Nt`'s **own**
   `call` on the same indices does **not** trap the same way (returns `$Nt`'s value) — proving the
   trap comes from the routed callee, not the caller.
5. **`(register)` → cross-module import end-to-end (spec §4.5.4/§7.5).** Drive the `$Mf`/`register
   "Mf"`/`$Nf` sequence through the harness: after `(register "Mf" $Mf)`, `env.providers` carries a
   `Registered("Mf", exports)` whose `exports["call"]` is a `ProvidedFunc(sig, closure)`; `$Nf`'s
   `link_imports` resolves it to a positional slot; `$Nf` instantiates and its imported call routes.
   Assert the whole chain green (this is the ~1088-residual unlock).
6. **Conformance-neutral byte-identity (I7/H7).** For a representative Phase-1..5 module with **no
   function imports**, assert the emitted `.core`/`.beam` is **byte-identical** to Phase-5
   (`count_import_slots == 0` → `instantiate/0`; the `ProvidedFunc.call` field never materialised).
   Run the full prior conformance under `safe()` and assert `fail == 0`, pass unchanged. A module
   importing only STATE (no functions) also stays byte-identical (its slot layout is unchanged).
7. **Host function import still fail-closed (§B.3, regression).** A module importing+calling
   `spectest.print_i32` under `safe_spectest()` dispatches (the host closure's `call_host` admits the
   whitelisted pair, returns `[]`); under `safe()` (deny-all) the same call **denies** (surfaces as a
   trap). A non-whitelisted host capability stays denied. Assert `link_imports` matches the
   `spectest.print*` signatures (the seven-name table, R14) and rejects a bogus `spectest` function
   (`UnknownImport`).
8. **Unit tests for `link.gleam` (spec-cited, not change-detector).** `resolve_fn_import` for each of
   the three provider cases (spectest match / registered match / unregistered host) returns the right
   `Ok(Some(ProvidedFunc(_)))` or `Error`; `provided_func_call` extracts the closure and `panic`s
   fail-closed on a non-function variant; `provided_func` round-trips; the positional order of a mixed
   func+global+memory import list matches declaration order (spec §2.5.1).
9. **Gate.** `gleam format --check src test` clean; `gleam build` **zero warnings** (no `todo`, no
   unused params); **every public function doc-commented** with contract + failure modes (D8); `gleam
   test` green before and after (1212 → 1212 + the new cases). Done = the cross-module link suite
   passes.

## What this unit leaves

- **P6-05 (`lower.gleam`)** — stop rejecting an imported `call` (`Unsupported("imported call")`,
  L1197–1198); route it to the imported-call node the emit seam consumes (recommended: reuse
  `CallDirect` with an imported funcidx — no new IR node, §D.4). This unit specifies the contract; 05
  emits the lowering.
- **P6-06 (`emit_core.gleam`)** — grow the positional `Imports` weave to function slots
  (`count_import_slots` + the `imported_slots` `ImportFn` arm + the dispatch vector, §D.1); lower an
  imported call to `apply(Closure, Args)` over the dispatch-vector slot (§D.3); reuse the funcref
  routing closure in `call_indirect` (§D.5); **extend the D3a structural security test** to prove no
  ambient `apply(module, atom)` in the imported-call path (§Effect). This unit specifies the contract;
  06 emits the code.
- **P6-10 (conformance / harness)** — flip `env.providers` on: assemble a `Registered(as_name,
  exports)` provider on `(register)` with function exports built per §C.2 (capturing the live handle +
  the `route` FFI capability), drive `linking.wast`, report the **measured** function-import residual
  drop, and **categorize** the imported-mutable-state-aliasing sub-residual honestly (§F.2). The
  `(register)`/registry/FFI plumbing + the live-handle wiring are 10's; §C.3 states the seam it calls.
- **Deferred, stated:** the **process-less runs-anywhere cross-instance record-threading** (§F.2 #1) —
  the shipped path hosts instances as processes; the pure multi-record threading is a categorized
  deferral. The **imported-mutable-STATE aliasing** (§F.2 #2, unchanged P5 §E.2 deferral) — genuine
  shared mutation of an imported global/table/memory across instances (owner-routed handles or a
  shared tier-O store) — a categorized skip in Phase 6, a faithful mechanism later. **Cross-module
  `call_indirect` through an imported table of the exporter's funcrefs** (§D.5) is enabled by this
  unit's closures but its `rt_table` dispatch reuse is P6-06/P6-07's.

## Open questions (for the planner / cross-unit reconcile)

1. **One positional slot per function-import *declaration* vs per *referenced* import.** This doc
   recommends **one slot per function-import declaration** (simplest, matches R4 "positional, name-
   free"; `emit_core` bakes the count from the import list). The alternative — a slot only for a
   function import that is actually called / `ref.func`'d / re-exported — maximises byte-identity for
   an "imports-but-never-references" module but makes the slot count body-dependent. Recommend the
   declaration rule; keystone/P6-06 to ratify (this is the load-bearing `«XLINK»` positional-ABI
   decision).
2. **The imported-call IR shape — reuse `CallDirect` vs a dedicated node.** This doc recommends reusing
   `ir.CallDirect("f<funcidx>", args)` with the funcidx in the imported range (`emit_core` already
   splits imported vs defined by the imports-first index space; no new IR node — I7). If P6-05/P6-06
   prefer an explicit `CallImport(slot, args)` node for clarity, either composes; the emit seam
   (`apply(Closure, Args)`) is identical. Flagged so 01 does not freeze an IR node this doc argues is
   unnecessary.
3. **The `route` capability home — harness FFI vs a production `Binding` field / `rt_link` seam.** The
   dispatch closure captures a `route` primitive (the owned-process synchronous call). In the
   conformance harness this is `twocore_conformance_ffi:call_instance*` (test-side). A production
   embedder needs an equivalent runtime seam (a new `runtime/rt_link.gleam` `route/3`, or a `route`
   field the embedder supplies). This unit keeps `link.gleam` **free of a routing FFI** (the closure
   is handed in — the D3a-purest story); reconciliation decides whether Phase 6 also ships a
   production `rt_link.route` or leaves it an embedder capability (the harness proves the contract
   either way).
4. **Host function imports as positional slots (uniformity) vs a `call_host`-mediated fallback.** This
   doc adopts the **uniform positional-slot** model (every function import → a `ProvidedFunc` slot;
   host slots wrap `call_host`) because `emit_core`'s slot layout must be deterministic-from-the-IR
   (§B.3/§Deviations). The alternative — emit *every* imported call as `CallHost(cap, name, args)` and
   have `call_host` consult a per-instance linked-capability map seeded from the Imports — keeps host
   imports on their exact P5 path and needs no positional-ABI growth, but moves cross-module routing
   into `rt_host` (a different file) + a new instance seed. Recommend the positional-slot model (it
   matches the provisional surface's explicit "`apply(Closure, Args)` in generated code"); flagged for
   reconciliation.
5. **Whether the register seam or `link.gleam` literally constructs the routing closure.** The task
   says "the linker builds the closure." This doc has the **register seam** (which holds A's live
   handle + the `route` FFI) build it and hands it to `link.gleam` inside `Registered(...).exports`;
   `link.gleam` owns the *type* + the *resolution/threading* + `provided_func`/`provided_func_call`.
   This keeps `link.gleam` pure (no live-handle/FFI dependency — the D3a-purest split) while the
   *linking machinery* (register + link) as a whole builds the closure. Recommend this split; if
   reconciliation prefers `link.gleam` to build it from a handed-in `route` + `handle`, add a
   `route`/`handle` field to `Registered` and a `build_func_closure(handle, field, route)` helper —
   both compose (§C.2).

## Deviations from the provisional surface (argued, for critique + reconciliation)

The provisional surface (`PROVISIONAL-SURFACE.md` §G) is built against for coherence; these
refinements are argued so reconciliation can adjudicate.

1. **The dispatch closure ROUTES INTO the exporting instance's process; it is NOT the provisional
   in-process `fn(args){ a_instance:f(args) }`.** *Argued (§A.2):* the in-process direct apply runs
   A's function in **B's** process, which is correct only for a callee whose transitive body touches
   no instance state, and is *silently wrong* (wrong-but-green: `Mt.call → 5` not `4`, `Mg.get_mut →
   142` not `241`) for a stateful callee under `Cell`, and does not type-check under `Threaded` (A's
   export is `f(St, Args) -> {Package, St'}`, and B holds no `St`). The **only** correct, strategy-
   independent mechanism is to route into A's owning process (§A.3), where A's live state lives —
   reusing the run-ABI. This is the single load-bearing correction; the rest follows.
2. **`ProvidedFunc` DOES contribute a positional `Imports` slot (the callable), not `Ok(None)`.**
   *Argued (§B/§D.1):* P5 skipped function imports in the positional list because a host import was a
   pure call-site `CallHost` capability. A cross-module call needs a **runtime callable** in generated
   code (`apply(Closure, Args)` — the provisional surface's own §G wording), which must be delivered
   as a positional slot the importer's `instantiate/1` seeds. So the positional-`Imports` ABI grows to
   one element per function import. This is additive (import-free modules keep `instantiate/0`, H7).
3. **EVERY function import (host too) gets a slot; the slot layout is deterministic-from-the-IR.**
   *Argued (§B.3/§Open-Q 4):* `emit_core` bakes the slot layout at **compile** time, but whether a
   `#(cap, name)` resolves to a cross-module wasm export or a host capability is only known at **link**
   time. To keep the layout link-independent (hence H7-byte-identical and emit deterministic), every
   function import yields a `ProvidedFunc` slot; a host slot wraps `call_host` (§B.3), preserving the
   fail-closed `HostPolicy` gate. This *unifies* the imported-call codegen (always `apply(slot, Args)`)
   at the cost of re-homing the host-import path behind a capability slot — a strictly-additive change
   (the wasm frontend never lowered a host-import call before, so nothing regresses).
4. **`link.gleam` does not itself construct the closure from a `Pid`; the register seam does (Open Q
   5).** *Argued (§C.2/§Effect):* the closure captures a **live process handle + a routing FFI** —
   runtime values `link.gleam` (pure, src-side, no test FFI) should not hold. Having the register seam
   build the closure and hand it in (as a handed-in capability) is the D3a-purest reading of "the
   linker builds the closure" and respects D1 (no routing-FFI dependency creeps into `link.gleam`).
   `link.gleam` owns the *type*, the *resolution*, and the *extractor*; the *closure value* is a
   handed-in capability. The provisional §G's `fn(args){ a_instance:f(args) }` is thus refined to a
   handed-in routing capability, not a `link.gleam`-fabricated module-atom apply.
5. **No `.ir` grammar delta, no new `Binding` field, no new profile (§G/§H).** *Argued (I7):* a
   cross-module function import is a **runtime dispatch** decision, not an IR shape — the IR already
   carries `ImportFn`/`ExportFn`/`FuncType`, and the closure is a runtime value. The provisional
   surface §G implies only a `link.gleam` field change (`ProvidedFunc.call`), which this doc adopts;
   it adds nothing to the IR, the printer/parser, the `Binding`, or `profiles` (confirming the
   provisional §H "what does not change").
