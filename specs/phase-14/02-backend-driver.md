# R14-02 — The heart: imported-funcref emission + the func-import-seed detector + the driver delegation (LOCKSTEP)

> **Status:** scoped, awaiting build. **Owner:** R14-02 (the heart — completes the emit path and its
> arity-detection twin in ONE unit so the import-bearing detection cannot desync). **Depends on:**
> `«REFFUNC-IMPORT-FROZEN»` (R14-01 — the `ir.RefFuncImport(slot, ty)` node, the lowering import-split,
> the `.ir` round-trip, and the **conservative fail-closed `emit_core` arm** this unit replaces).
> **Read order:** [`00-overview.md`](00-overview.md) → the distilled codebase map
> (`brief-phase14-xmodule-elem.md`) → this doc. All prior-phase decisions and the permanent invariants
> ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold. This unit lands **green with default
> emission byte-identical** (H7/§8) — a module with no imported `ref.func` compiles bit-for-bit as it did
> in Phase 13 — while flipping the imported-`ref.func`-into-`elem` case from "still skips" to "emits, links,
> and dispatches correctly." It touches **neither `rt_table.gleam` nor `link.gleam`** (no runtime shape
> change, R8): the funcref value stays `#(FuncType, closure)`, the seam functions
> (`func_import_at`/`t_func_import_at`/`call_import`) already exist.

---

## §1. Goal

Complete the two halves of the imported-`ref.func` feature that must move together — the shared import-bearing
predicate and the driver's delegation to it — because either half alone silently corrupts `instantiate` arity
(R3):

1. **Backend emit (`emit_core.gleam`).** Turn `ir.RefFuncImport(slot, ty)` — the frozen keystone node — into
   a real, table-storable funcref whose slot dispatches through the D3a import capability
   (`link.call_import(func_import_at(slot), args)`), never `erlang:apply` on program data. This is: a
   body-level dispatch arm (`emit_ref_func_import`), an element-init arm (`render_ref_item` → `RefFuncImport`),
   a reference-global-init arm (`render_ref_global_init` → `RefFuncImport`, F2),
   the shared `#(FuncType, closure)` builder (`imported_reference_func_entry`, Cell **and** Threaded), the
   fast-path gate (`all_reffunc`/`byte_ident_funcref` route mixed/imported segments to `init_elem_ref`), and
   the **extended `needs_func_imports`** that scans element segments (+ passive segments reachable via
   `table.init`) and function bodies for `RefFuncImport` so the func-import dispatch vector is seeded even
   when no `CallImport` appears anywhere.

2. **Driver delegation (`test/twocore/conformance/driver.gleam`).** Change `module_calls_import` to **call**
   the now-`pub` `emit_core.needs_func_imports` (deleting its private `expr_calls_import` mirror), so the
   conformance harness weaves the positional `link.Provided` function-import closures onto **exactly** the
   modules whose generated `instantiate` destructures them. Because both sides are now the *same* predicate
   over the *same* lowered `irmod`, `instantiate/0` vs `instantiate/1` cannot desync — the sharpest edge in the
   phase is closed structurally. Owning both in one unit lets the emit predicate be made `pub` and the driver
   rewired together.

Implements **R1** (consumes the `RefFuncImport` node), **R2** (the D3a adapter closure, both strategies),
**R3** (the lockstep dual detector — the *reason* this is one unit), preserves **R4** (seeding order untouched)
and **R5** (byte-identical default via the distinct node), and stays inside **R8** (function references only,
no runtime shape change, no new trap). It **completes** R14-01's conservative fail-closed emit arm recorded in
`state.md`.

**This unit does NOT** flip `table_copy.wast`, re-measure `skipcount_test`, tighten `residual_audit`, author
`corpus/xlink`, or run the cross-tier `rt_table` differential — those are R14-04 (capstone) and R14-03 (runtime
differential). R14-02 proves the mechanism on hand-built modules end-to-end; the capstone proves the real file.

---

## §2. Depends on / Produces

**Depends on (read-only, frozen upstream — `«REFFUNC-IMPORT-FROZEN»`):**
- `src/twocore/ir.gleam` — `RefFuncImport(slot: Int, ty: FuncType)` (a pure barrier, sibling of `CallImport`;
  brief §IR), `ElementSegment(mode, ref_ty, init: List(Expr))` (`ir.gleam:154-155`), `ElemMode`
  (`ElemActive(table, offset)` / `ElemPassive` / `ElemDeclarative`, `ir.gleam:166-170`), `RefFunc(fn_name)`
  (`ir.gleam:557`), `ImportFn(capability, name, ty)` (`ir.gleam:220`), `TableInit(table, seg, dst, src, count)`
  (`ir.gleam:581` — `seg` is the passive-element index for reachability).
- `src/twocore/frontend/wasm/lower.gleam` — the import-split at `lower.gleam:757-759` now emits
  `RefFuncImport(f, ir_functype(sig))` for `f < ctx.imported`, `ir.RefFunc("f"<>f)` otherwise (R14-01).
- `src/twocore/backend/emit_core.gleam` internals, **read-only reuse** (not re-designed here):
  `emit_call_import` (`emit_core.gleam:3366-3401` — reads `func_import_at(slot)` / `t_func_import_at(St, slot)`,
  applies `link.call_import(closure, argslist)`; under `Threading`, `cur` unchanged `:3360-3364`),
  `func_type_term` (`emit_core.gleam:4584-4590` — the single canonical `TypeTag` renderer used at BOTH the
  `call_indirect` site and the slot), `is_threaded(ctx)`, `apply_cont`, `fresh_var`/`fresh_n_vars`, `seam_call`,
  `CFun`/`CTuple`/`CVar`/`CInt`, `core_list`.
- `src/twocore/runtime/rt_state.gleam` — `func_import_at(slot)` (`:424-428`) / `t_func_import_at(St, slot)`
  (`:676-680`), seeded BEFORE element segments (see R4 / §3.5) — **read-only, not edited.**
- `src/twocore/runtime/link.gleam` — `call_import(closure, args) = closure(args)` (`:236-241`, 1-ary, D3a,
  never `apply/3`) — **read-only, not edited.**
- `src/twocore/runtime/rt_table.gleam` — the 3-guard `call_indirect` dispatch (`:203-223`) that invokes the
  slot's stored closure DIRECTLY as `target(args)` — **read-only, zero change** (an imported funcref is just
  another build-controlled `#(FuncType, closure)` in a slot; brief §"why imported funcref needs ZERO rt_table
  change").

**Produces:** the substantive imported-`ref.func` emit path in `emit_core.gleam` and the driver's delegation to
the now-`pub` `needs_func_imports` in `driver.gleam`; the func-import vector is now seeded, and the closures woven, on modules that only `ref.func`
an import (no `CallImport` in any body). **Unblocks** R14-04 (capstone: `table_copy` flip, `corpus/xlink`,
`skipcount`/`residual` re-measure) and interlocks with R14-03 (runtime cross-tier/cross-strategy differential
for an import-routed slot).

---

## §3. What it owns + design

**Owned files (D1) — this unit is the sole substantive owner of each:**
`src/twocore/backend/emit_core.gleam` · `test/twocore/conformance/driver.gleam` · new
`test/twocore/backend/reffunc_import_emit_test.gleam` (its e2e / dispatch / arity-lockstep suite). It also makes
**one additive, non-substantive touch** to the shared structural D3a test
`test/twocore/backend/emit_core_security_test.gleam` (adds an imported-funcref module to the corpus its
existing invariant already walks — §5.5; this claims no ownership of that file's invariant, which is unchanged).

> **Build strategy — let the compiler enumerate the sites.** With the `RefFuncImport` node already in
> `ir.gleam`, the keystone (R14-01) has already cleared the exhaustiveness arm in `emit`'s top-level `case`
> (`emit_core.gleam:~1021`, beside `ir.RefFunc(name) -> emit_ref_func(...)`) as a conservative fail-closed
> placeholder. This unit **replaces** that placeholder with the real arm and adds the four supporting pieces.
> The anchors below are the map; `gleam build` after each edit is the checklist.

### 3.1 The five emit pieces (the four from brief §"THE 4 MISSING PIECES" #2–#3, plus the reference-global completion)

**(a) Body-level dispatch arm — `emit_ref_func_import` (beside `emit_ref_func`, `emit_core.gleam:3407`;
dispatched from the `emit` `case` at `:1021`).** Replaces R14-01's conservative arm. A bare `ref.func` of an
import in a function body (pushed then `table.set`/returned) is a PURE, state-neutral funcref *construction* —
the `func_import_at(slot)` read is deferred INTO the adapter closure body (dispatch time), so building the value
touches no state; under `Threading(cur)`, `cur` flows through unchanged, exactly like `emit_ref_func`
(`emit_core.gleam:3405-3416`). Shape:

```
fn emit_ref_func_import(slot, ty, cont, sc, state, ctx) {
  use #(entry, state2) <- result.try(imported_reference_func_entry(slot, ty, ctx, state))
  apply_cont(cont, [entry], sc, state2, ctx)
}
```

**(b) Element-init arm — `render_ref_item` (`emit_core.gleam:4031-4043`).** Today the `case item` at
`:4037-4042` has `ir.RefFunc(name) -> reference_func_entry(name, ctx, state)` and a wildcard
`_ -> Error(UnsupportedNode("elem_item"))` — so a `RefFuncImport` init item is currently *rejected* (this is the
load-bearing gap on the element path). Add:

```
ir.RefFuncImport(slot, ty) -> imported_reference_func_entry(slot, ty, ctx, state)
```

Note `render_ref_item` is the general `init_elem_ref` path; it is only reached once `byte_ident_funcref`
returns `False` for the segment (see (d)).

**(c) The shared builder — `imported_reference_func_entry(slot, ty, ctx, state)` (new; sibling of
`reference_func_entry` `:3426-3435`, `element_entry` `:5775-5789`, `threaded_element_entry` `:5468-5484`).**
Emits `#(func_type_term(ty), adapter_closure)`. Like `reference_func_entry`, it branches on the BUILD strategy
`is_threaded(ctx)` (NOT `sc`) — a funcref is consumed uniformly by `call_indirect` / `t_call_indirect` across
the whole build, so the closure ABI must match the build, not the local state channel:

```
fn imported_reference_func_entry(slot, ty, ctx, state) {
  case is_threaded(ctx) {
    True  -> Ok(#(func_type_term(ty), <threaded adapter over slot>), state')   // §3.2 Threaded
    False -> Ok(#(func_type_term(ty), <cell adapter over slot>),     state')   // §3.2 Cell
  }
}
```

- `func_type_term(ty)` is the SAME renderer `emit_call_indirect` uses for its expected `TypeTag`
  (`emit_core.gleam:4584-4590`), so `rt_table`'s guard-3 structural `entry_type == expected_type`
  (`rt_table.gleam:~209-221`) matches an import-routed slot exactly as it matches a defined-funcref slot. The
  imported `FuncType` carried by `RefFuncImport.ty` is the import's declared signature.
- Returns `Result` (like its siblings) for signature uniformity, but this arm **never errors** — there is no
  `dict.get(ctx.fn_sig, name)` lookup to miss (that miss, `Error(UnknownFunction)` at
  `element_entry:5781`/`threaded_element_entry:5474`, is exactly the residual this unit removes for imports).

**(d) The fast-path gate — `all_reffunc` / `byte_ident_funcref` (`emit_core.gleam:5732-5744`).**
`byte_ident_funcref(seg, tidx) = seg.ref_ty == FuncRef && tidx == 0 && all_reffunc(seg.init)` (`:5732-5734`)
selects the frozen Phase-4 `init_elem` fast path (`:5690-5701`). `all_reffunc` (`:5737-5744`) returns `True`
iff every init item is `ir.RefFunc(_)`. Because `RefFuncImport` is a **distinct node** (R1/R5), it already
falls through `all_reffunc`'s wildcard `_ -> False`, so a mixed or imported segment auto-routes to the general
`init_elem_ref` path (`:5702-5718`) → `render_ref_items` → `render_ref_item` → the new arm (b). To make the
contract explicit and **regression-proof against a future maintainer widening the `True` arm**, add an
explicit arm and a doc note:

```
fn all_reffunc(items) {
  list.all(items, fn(it) {
    case it {
      ir.RefFunc(_) -> True
      ir.RefFuncImport(_, _) -> False   // imported ref.func is NOT the plain Phase-2 shape:
                                        // route the segment through init_elem_ref (R1/R5)
      _ -> False
    }
  })
}
```

`reffunc_names` (`:5748-5755`) is unaffected: it only runs behind a `byte_ident_funcref == True` gate, where no
`RefFuncImport` can be present, so its `_ -> Error(UnsupportedNode)` arm stays unreachable. **The frozen
`init_elem` fast path for pure-defined table-0 segments is byte-identical** — a module with no imported
`ref.func` never trips the new arm (R5).

**(e) The reference-*global* completion — `render_ref_global_init` (`emit_core.gleam:5282`).** R14-01 left a
conservative fail-closed arm here (a funcref *global* initialised by an imported `ref.func`); R14-02
**completes** it by reusing the shared builder, exactly as (b) does for the element path:

```
ir.RefFuncImport(slot, ty) -> imported_reference_func_entry(slot, ty, ctx, state)
```

A funcref global holding an imported funcref is **well-defined and cheap** — the same
`#(func_type_term(ty), adapter)` value (§3.1c), just stored in a global rather than a table slot. Completing
it (decision F2, option (a)) means that after Phase 14 **NO** path skips as `UnknownFunction` from this gap
— not just the element path. It is not exercised by `table_copy`, but closing it keeps the residual honest:
the capstone **measures** that no residual carries `UnknownFunction` before removing the phrase (04 §3.3).

### 3.2 The adapter closure (R2 / D3a — brief §"Adapter closure")

The slot value is the unchanged `#(FuncType, closure)` funcref. The closure is a **build-emitted adapter that
captures only the literal integer `slot`** (D3a: the only program-derived datum is an integer index; there is
no `erlang:apply` on program/attacker data). It speaks the frozen table-entry ABI directly — and, crucially, it
does **not** re-wrap the result: `link.call_import(closure, args)` already returns the callee's result value
**LIST** (`emit_call_import` doc, `emit_core.gleam:3355`; `call_import` at `link.gleam:236-241`), which IS the
`fn(List(Int)) -> List(Int)` table-entry ABI. This is the key contrast with `element_closure`
(`emit_core.gleam:5796-5814`), which unpacks and re-wraps a `function_return` package via `wrap_result_list` —
the import adapter must **not** call `wrap_result_list`, or it would doubly wrap and return the wrong value.

- **Cell** (build `is_threaded == False`; table-entry ABI `fn(List(Int)) -> List(Int)`):

  ```
  fun(Args) -> link:call_import(rt_state:func_import_at(Slot), Args)
  ```

  `Args` is a `List(Int)` ≡ `List(Dynamic)` (raw bit patterns, identity coercion, cf. `link.gleam:56-66`);
  the returned list flows straight back to `rt_table.call_indirect`, which returns it to `emit_call_indirect`,
  which unpacks it (`unpack_result_list`, `emit_core.gleam:3326-3349`) exactly as for a defined-funcref slot.

- **Threaded** (build `is_threaded == True`; table-entry ABI `fn(St, List(Int)) -> #(List(Int), St)`):

  ```
  fun(St, Args) -> {link:call_import(rt_state:t_func_import_at(St, Slot), Args), St}
  ```

  `St` (the dispatch-time instance state handed in by `t_call_indirect`) is threaded through **unchanged** —
  the imported callee threads its OWN state INSIDE the linker-built routing closure, exactly as
  `emit_call_import` does under `Threading` (`cur` unchanged, `emit_core.gleam:3360-3364`). The `St` used by
  `t_func_import_at(St, Slot)` is the closure's `St` PARAMETER (dispatch-time), never the build-time `cur` — so
  building the funcref remains pure.

Structurally the adapter body is `link:call_import(...)` and `rt_state:func_import_at(...)` — both `CCall`s to
FIXED, already-admitted runtime modules (`link`, `rt_state` = `binding.state_module`); no new module atom, no
`CApply` of program data. It is D3a-clean by construction (§5.5 asserts it).

### 3.3 Extended import-bearing detection — `needs_func_imports` (brief §"THE 4 MISSING PIECES" #3)

Today (`emit_core.gleam:4715-4717`):

```
fn needs_func_imports(module) {
  list.any(module.functions, fn(f) { expr_has_call_import(f.body) })
}
```

with `expr_has_call_import` (`:4719-4736`) recursing bodies for `ir.CallImport(..)` only. A module that only
`ref.func`s an import — in an element segment OR in a body (via `table.set`/return) — has NO `CallImport`, so
the func-import vector is never seeded, and the adapter's `func_import_at(slot)` faults at dispatch. Extend the
detector to fire on `RefFuncImport` **everywhere it can appear**, so the seed is present whenever any adapter
could read the vector:

1. **Function bodies:** generalise the body scan to also return `True` on `ir.RefFuncImport(..)` — add a
   parallel `expr_has_ref_func_import` and `||` it into the body scan. **This is the one pinned helper name**
   (no `expr_needs_func_import` alias — F4). This catches a body-level imported `ref.func` (e.g. returned or
   stored) that has no `CallImport`.
2. **Element segments:** scan every `module.elements` segment's `init` items for `RefFuncImport`. Scan **all
   modes** (`ElemActive` / `ElemPassive` / `ElemDeclarative`) — a conservative over-approximation that
   subsumes "passive segments reachable via `table.init`" without tracing `TableInit(_, seg, …)` reachability
   (fragile). Over-seeding is safe and byte-neutral: R4 seeds ALL function imports regardless
   (`count_func_import_positions:4782-4787`), so a passive segment that is never `table.init`'d merely seeds an
   already-all-seeded vector; a module with NO `RefFuncImport` in any segment finds none and stays exactly at
   its Phase-13 arity (R5).

Resulting shape — and **make it `pub`** so the driver calls it (single source of truth, §3.5):

```
pub fn needs_func_imports(module) {
  list.any(module.functions, fn(f) { expr_has_call_import(f.body) })
  || list.any(module.elements, fn(seg) {
       list.any(seg.init, expr_has_ref_func_import)   // True on RefFuncImport (recursive, robust)
     })
}
```

Exporting `needs_func_imports` is what makes the arity detection a **single source of truth**: the conformance
driver calls this exact function (§3.5) rather than re-deriving the scan, so emit's seed and the driver's woven
closures cannot disagree. This forces the `FullDecl` + `seed_func_imports` / `set_func_imports` path (via
`count_func_import_positions` → `count_import_slots:4775-4777`) so `instantiate/1` destructures the woven
closures. **Byte-identity holds** for every pre-Phase-14 module: `RefFuncImport` is a new node that appeared in
no earlier module, so neither the body generalisation nor the element scan changes any existing module's
detection result (H7/§8).

### 3.4 Seeding order — preserve, do NOT reorder (R4)

The func-import vector is seeded BEFORE element segments run in both `full_cell_body`
(`emit_core.gleam:4855-4887` — `…→ seed_func_imports → element segments → data → start`) and `full_threaded_body`
(`:4916-4955` — `set_func_imports` before elements) — `:4893-4894`. So an imported-funcref element entry can
safely be *built* while the vector is seeded, and dispatched later. `slot == funcidx` holds because ALL function
imports are seeded (function imports occupy funcidx `0..imported-1`; `count_func_import_positions:4782-4787`).
**This unit reads these invariants and preserves them; it edits neither `full_cell_body` nor `full_threaded_body`
nor the seed functions.** The only new dependency on the seed is that `needs_func_imports` now also switches it
on for element-only imported `ref.func` — which is precisely the fix.

### 3.5 The driver delegates to the shared predicate — `module_calls_import` calls `emit_core.needs_func_imports` (brief §"THE 4 MISSING PIECES" #4)

`test/twocore/conformance/driver.gleam` decides whether to append the positional `link.Provided` function-import
closures to the `Imports` list handed to `instantiate/1`, and it MUST agree with `emit_core.needs_func_imports`
**exactly** (else the generated `instantiate/1` destructures a slot the driver never supplied — the arity
desync). Today `module_calls_import` (`driver.gleam:325-327`) maintains a *separate* mirror of the OLD emit
predicate:

```
fn module_calls_import(module) {
  list.any(module.functions, fn(f) { expr_calls_import(f.body) })
}
```

with `expr_calls_import` (`:331-347`) recursing bodies for `ir.CallImport(..)` only. **Do not extend this
mirror — replace it with a delegation (F4).** Because `emit_core.needs_func_imports` is now `pub` (§3.3) and
the driver already holds the **identical lowered `irmod`** it hands to emit (computed at `driver.gleam:224`,
before `ir_to_core` at `:239`), `module_calls_import` becomes a thin call to the single source of truth:

```
fn module_calls_import(module) {
  emit_core.needs_func_imports(module)   // one predicate — cannot desync from emit's seed
}
```

and the now-dead private `expr_calls_import` is deleted (no `expr_needs_func_import` sibling is introduced —
F4 pins `expr_has_ref_func_import` as the single helper, owned by emit). This eliminates the desync **class**
structurally: there is exactly one implementation of "is this module import-bearing," so emit's `instantiate/1`
arity and the driver's supplied `Imports` length are the same function of the same `irmod` — strictly stronger
than keeping two copies a reviewer must diff by eye. §5.4 pins it behaviourally (a load succeeds on a module
that ONLY `ref.func`s an import from an element segment, active **and** passive). This shared predicate is the
whole reason emit and the driver land in one unit (R3).

---

## §4. The work (ordered, buildable)

1. **`emit_core.gleam`** — replace R14-01's conservative `ir.RefFuncImport` arm at `emit`'s top-level `case`
   (`:~1021`) with the real `emit_ref_func_import` (§3.1a); add `imported_reference_func_entry` (§3.1c) with
   the Cell + Threaded adapters (§3.2); add the `RefFuncImport` arm to `render_ref_item` (`:4037-4042`, §3.1b);
   complete `render_ref_global_init` (`:5282`) via `imported_reference_func_entry` (§3.1e); add the explicit
   `ir.RefFuncImport(_, _) -> False` arm to `all_reffunc` (`:5737-5744`, §3.1d); extend and **make `pub`**
   `needs_func_imports` + the `expr_has_ref_func_import` body scanner (`:4715-4736`, §3.3). Each new/edited
   function gets `///` contract docs (§6.2). `gleam build` after each edit.
2. **`driver.gleam`** — replace `module_calls_import`'s body with a call to the now-`pub`
   `emit_core.needs_func_imports` and delete the private `expr_calls_import` (`:325-347`, §3.5); update
   `module_calls_import`'s `///` doc to state it **delegates** to the single source of truth and WHY (arity
   agreement with `needs_func_imports` cannot desync).
3. `gleam format` → `gleam build` (**zero warnings**).
4. **Write the tests** — new `test/twocore/backend/reffunc_import_emit_test.gleam` (§5.1–§5.4) + the additive
   D3a corpus module in `emit_core_security_test.gleam` (§5.5). `gleam test`.
5. **Verify default emission byte-identical** — the existing corpus/conformance suite is green and unchanged
   (no `.core` for an imported-`ref.func`-free module changes; the new arms are unreached on those modules).
   Record in `state.md` that R14-01's conservative emit reach is now COMPLETED by R14-02.

---

## §5. Tests (`test/twocore/backend/reffunc_import_emit_test.gleam`) — spec-cited + adversarial

Objective tests against the **WebAssembly spec** for element segments (§2.5.6 / §4.5.4 — instantiation writes
each element's `ref.func x` reference into the table, where the funcidx space is unified with imports first) and
`call_indirect` of an imported function (spec §4.4.8: an imported function reached via `call_indirect` behaves
**identically** to a direct `call` of that import; the three guards — index-in-bounds → `UndefinedElement`,
slot-non-null → `UninitializedElement`, exact `FuncType` → `IndirectCallTypeMismatch` — evaluate in order).
**Not** change-detectors (R7/D8): each test asserts a spec-defined *result/behaviour*, not the current byte
output. Reuse the e2e harness pattern from `test/twocore/backend/emit_core_e2e_test.gleam`
(`emit_core.emit_module(m, instance.safe_default())` → `core_printer.print_module` →
`build_beam.compile_and_load` → `catch_apply` / `catch_apply_dyn` FFI).

### 5.1 Hand-built imported-funcref module emits and compiles/loads (well-formed Core)

Hand-build an `ir.Module` with one `ImportFn("a", "ef", FuncType([TI32], [TI32]))` (funcidx 0, so
`ctx.imported == 1`), one defined function, one `TableDecl(FuncRef, min:2, …)`, and one `ElemActive` segment at
offset 0 whose `init` is `[RefFuncImport(0, FuncType([TI32],[TI32]))]` (as R14-01's lowering would produce).
Assert `emit_module` returns `Ok` and the emitted `.core` **compiles and loads** (`build_beam.compile_and_load`
succeeds) under BOTH the Cell binding and the Threaded binding — i.e. the adapter closure's arity matches the
table-entry ABI (`fun(Args)` for Cell, `fun(St, Args)` for Threaded). This is the "emits + type-checks" bar:
Core well-formedness = the ABI arities line up, which the earlier `Error(UnknownFunction)` residual could never
reach. Adversarial variants: a **multi-value** imported `ty` (e.g. `[TI32, TF64] -> [TI32, TF64]`); a
**non-zero table** target (forces `init_elem_ref`, tidx ≠ 0); a **mixed** segment
`[RefFunc("f1"), RefFuncImport(0, …), Values([ConstNull(FuncRef)])]` (asserts `byte_ident_funcref` returns
`False` and every item renders — the imported item does NOT poison the defined/null items).

### 5.2 End-to-end dispatch — imported funcref via active `elem` + `call_indirect` == direct `call` (Cell AND Threaded)

The headline spec claim. Build a provider module exporting `ef : [TI32] -> [TI32]` (e.g. `x ↦ x + 41`) and
`(register "a")`-style plumb it as the function-import capability (the driver / linker path). Build a consumer
module that (a) imports `a.ef` (funcidx 0), (b) has an active `ElemActive` segment placing
`RefFuncImport(0, [TI32]->[TI32])` into table slot 0, and (c) exports a function
`(call_indirect (type $t) (i32.const 0) (i32.const K))` dispatching slot 0 with argument `K`. Emit, link, and
run. Assert the `call_indirect` result **equals** the result of a direct `call` of the import with the same
argument (`K + 41`) — a **single value**, NOT a wrapped list (this is exactly the `wrap_result_list` trap §3.2
guards against: proves the adapter returns `link.call_import`'s list straight into the table ABI, unpacked once
to the scalar). Run the whole thing under **Cell** and under **Threaded** builds and assert the same result in
both (the Threaded adapter threads `St` unchanged). Spec cite: §4.4.8 — indirect call of an imported function is
observationally identical to a direct call of it.

### 5.3 Guard order preserved for import-routed slots (fail-closed)

With the same table, assert the three ordered `call_indirect` guards still fire on an import-routed slot (spec
§4.4.8): (1) index ≥ table size → `UndefinedElement`; (2) a null / never-written slot → `UninitializedElement`;
(3) a `call_indirect` whose expected `FuncType` differs from the import's declared `ty` → `IndirectCallTypeMismatch`.
Because the slot is the unchanged `#(FuncType, closure)` and guard-3 compares `func_type_term(import_ty)` against
`func_type_term(callsite_ty)` (same renderer), the guards behave identically to a defined-funcref slot — assert
each trap by driving a `call_indirect` that violates exactly one guard. (The `table_copy`-after-shuffle guard
asserts belong to the capstone's real-file run; here we pin the mechanism.)

### 5.4 `instantiate/0` vs `instantiate/1` arity lockstep — the desync guard

Build a module that **only** `ref.func`s an import from an element segment and has **no `CallImport` in any
body** (e.g. `import a.ef`; one active `elem` with `RefFuncImport(0, …)`; one exported wrapper that
`call_indirect`s it — the wrapper contains `CallIndirect`, never `CallImport`). Assert:
- `emit_core.needs_func_imports(m) == True` and `count_import_slots(m) == count_function_imports(m)` (> 0) — the
  generated entry is `instantiate/1`.
- `driver.module_calls_import(m) == True` — the driver weaves the function-import closure (it *calls*
  `needs_func_imports`, so this equals the line above by construction, §3.5).
- **Passive-only lockstep (F4):** a **third** module whose ONLY `RefFuncImport` sits in a **passive** `elem`
  segment that is **never `table.init`'d**, again with **no `CallImport` in any body**. Assert
  `emit_core.needs_func_imports(m) == True` — the conservative all-modes element scan (§3.3) fires on passive
  segments too — and therefore `driver.module_calls_import(m) == True`. This over-seeds a vector a
  never-`table.init`'d passive segment may never read, which R4 makes safe (all function imports are seeded
  regardless) and byte-neutral, and proves the delegation covers the **passive** path, not just active segments.
- **Behavioural lockstep:** the driver's `instantiate_typed` path (weave the provider closure) LOADS and RUNS
  the active-segment module successfully and the export returns the spec-correct value — proving emit's
  `instantiate/1` arity and the driver's supplied `Imports` length agree. Then the **negative twin**: a module
  that imports `a.ef` but neither calls NOR `ref.func`s it stays `needs_func_imports == False` /
  `module_calls_import == False` → `instantiate/0`, byte-neutral (I7). If the extended element scan failed to
  fire (or the driver stopped delegating to it), one of these loads would crash on an arity mismatch — this
  test is the desync tripwire (hazard `link.gleam:198-215`, `emit_core.gleam:4769-4787`).

### 5.5 D3a — the adapter captures only the literal slot (extends the structural security test)

Add an imported-funcref module (as §5.1) to the corpus that `emit_core_security_test.gleam` already walks
structurally. Its existing invariant — every inter-module `call` targets a FIXED `binding`/allowed runtime
module, and no `CApply`/`apply` of program-derived module data — must hold for the emitted adapter:
`link:call_import` and `rt_state:func_import_at`/`t_func_import_at` are `CCall`s to already-admitted fixed
modules (`link`, `binding.state_module`); the closure's only program-derived operand is `CInt(slot)` (a literal
integer). Assert no NEW module atom is introduced and the adapter is a `CFun` whose body is a `call` to those
fixed modules — never an `erlang:apply` of a data-named target (D3a). No new allow-set entry is required (the
adapter routes through the already-admitted `link.call_import` seam).

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. Spec-cited tests §5.1–§5.5 green — including the Cell **and** Threaded e2e dispatch equality (§5.2), the
   guard-order preservation (§5.3), the arity-lockstep positive + negative twins (§5.4), and the D3a structural
   assertion (§5.5).
2. `///` contract docs on **every** new/edited public-facing function: `emit_ref_func_import` (pure barrier;
   `cur` unchanged under Threaded; captures literal slot), `imported_reference_func_entry` (returns
   `#(func_type_term(ty), adapter)`; branches on BUILD `is_threaded`; never errors; does NOT `wrap_result_list`
   because `call_import` already yields the list ABI), the `render_ref_item` / `render_ref_global_init` /
   `all_reffunc` arms (WHY `RefFuncImport` routes to `init_elem_ref` and is not-plain), and the now-`pub`
   `needs_func_imports` / `expr_has_ref_func_import` (WHAT they now scan) + the delegating `module_calls_import`
   (WHY it calls the single source of truth — arity agreement cannot desync, R3).
3. `gleam format --check src test` clean.
4. `gleam build` **zero warnings** (no unused import/var; every touched match total).
5. The unit suite passes; **default emission byte-identical** — the existing corpus/conformance suite is green
   and unchanged (no `.core` for an imported-`ref.func`-free module changes; the new arms are unreached on
   those modules), and `OptNone ≡ Baseline ≡ Aggressive` across the matrix is undisturbed (R5).
6. `state.md` records that R14-01's conservative `emit_core` reach is now **completed** by R14-02, and that the
   `needs_func_imports` (now `pub`) ← `driver.module_calls_import` delegation (R3, single source of truth) is
   landed and tested.

---

## §7. What it leaves (handoff to downstream)

- **R14-03 (runtime differential):** proves an import-routed funcref slot **stores and dispatches identically**
  across `TablePaged` / `TableEts` / `TableAtomics` × Cell / Threaded (bit-identical). R14-02 emits the adapter
  **inline** in Core Erlang (no new runtime function; the seam is frozen to inline, F3 — R14-03 is pure
  test-only and adds no `link` helper). R14-02 leaves the slot ABI (`#(FuncType, closure)`) and guard behaviour
  proven on `TablePaged`; the cross-tier sweep is R14-03's.
- **R14-04 (capstone):** lights up the **real** `table_copy.wast` (already JSON-driven; brief §Conformance),
  measures the ~1,080-assert flip (Tier-A baked values) plus the `assert_trap` guard asserts after `table.copy`
  shuffles import-routed slots; authors the in-scope `corpus/xlink` backstop (imported funcref through
  `call_indirect`, Cell/Threaded × all table tiers); re-measures `skipcount_test` (lower `max_residual_skips`);
  tightens `residual_audit_test` by removing the now-dead `"UnknownFunction"` / `"call_indirect_table"`
  cross-module-elem `allowed_phrases` entries (`residual_audit_test.gleam:32-34`, R7) so a re-skip turns the
  suite red; and regenerates `docs/wasm-conformance.svg` + `docs/phase-14-surface.md`. R14-02 leaves the
  mechanism proven on hand-built modules; the capstone proves the real file and the accounting.
- **Nothing runtime-shaped is left open:** `rt_table` / `rt_ref` / `rt_state` / `link` are untouched (R8) — the
  imported funcref is just another build-controlled closure in a slot, so there is no deferred runtime data
  shape for a later phase to reconcile.
