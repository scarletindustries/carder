# Q13-05 — `emit_core`: the REAL constant-stack tail emission

> **Status:** scoped, awaiting build. **Owner:** Q13-05 (Wave A, behind `«TC-FROZEN»`).
> **Freeze produced:** none — this unit *consumes* `«TC-FROZEN»` and produces no new milestone.
> **Read order:** [`00-overview.md`](00-overview.md) → the distilled brief
> (`scratchpad/brief-phase13-tailcall.md`) → this doc. All prior-phase decisions and the permanent
> invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold. This unit **completes**
> the three keystone-placeholder `emit` arms: the keystone (Q13-01) landed them as a *correct non-tail
> delegation* (right value, not yet a BEAM tail call); Q13-05 replaces that delegation with genuine
> **constant-stack tail emission** — **and owns the whole tail codegen** (overview §2 ⚠ ABI
> reconciliation note): the funcref-construction ABI change in `emit_core`, the new
> `rt_table.call_indirect_lookup*` seam + the non-tail `call_indirect*` package→list re-wrap, and the
> real tail emit arms. A module using no funcref/`elem` **and** no `return_call*` compiles
> **byte-identically** to Phase 12 (Q6/H7). A funcref/`elem`-bearing module becomes **result-identical,
> not byte-identical** — the funcref-construction ABI change (list-wrapping → package-ABI) alters its
> emitted Core even without `return_call*` (§8-sanctioned; proven by the `callind` corpus differential).

**Honors decisions:** **Q1** (the direct tail path already exists under `KReturn`; the **indirect** case
gets the "lookup → raise-or-tail-apply" seam over the package-ABI target; the **imported** case reuses
the existing import path under `KReturn`, value-correct/bounded-frame), **Q5** (`emit_core` emits genuine
tail calls; the loop back-edge is untouched), **Q6** (byte-identical for non-funcref modules; funcref
modules result-identical), **Q7** (correctness is a constant-stack property + fail-closed guards, not
emitted-text change-detectors), **Q8** (no optimizer/tier/state-strategy change; both strategies + all
tiers inherit through this one seam; imported constant-stack is a documented honest-scope sub-case).

---

## §1. Goal

Own the **whole tail codegen** (overview §2 ⚠ ABI reconciliation note — this unit is self-contained: it
owns `emit_core`'s funcref-construction **and** `rt_table.gleam`). Three pieces:

**(a) The funcref-construction ABI change (`emit_core.gleam`).** Today a funcref table target is stored
as a **list-ABI** closure (`fn(List(Int)) -> List(Int)`, a `[apply f(args)]` cons-wrap). That is
*wrong-valued* for a tail call (`[v]` not the bare `v`) and *secretly non-tail* (the `apply` sits inside
a cons). Change `element_closure` / `threaded_element_closure` / `reference_func_entry` so the stored
closure is **package-ABI and tail-transparent**: its body is a bare `apply 'f'/n(unpacked args)` returning
`f`'s `function_return` package directly (under `Threading`, returning `{package, St'}`).

**(b) The `rt_table.gleam` seam + re-wrap (`rt_table.gleam`).** Add the `call_indirect_lookup` (+ `_at` +
`t_` twins) entry points that run the 3 fail-closed guards and **return the package-ABI target** (do not
apply it), so `emit_core` can tail-apply it. Because the stored closure is now package-ABI, the **non-tail**
`call_indirect*` family must **re-wrap** the target's package back into the result list *inside* `rt_table`,
using the result arity from the guard-checked `FuncType` (`0→[]`, `1→[v]`, `N→tuple_to_list`) — so
`emit_call_indirect`'s emitted seam stays **observably identical** (its result list is unchanged).

**(c) The three real emit arms (`emit_core.gleam`)** — a **genuine BEAM tail call in constant stack space**:

- `ReturnCall(fn_name, args)` — a direct tail call: emit the existing direct-call logic **forcing
  `cont = KReturn`** (a `CallDirect` under `KReturn` is already a real BEAM tail call, Q1).
- `ReturnCallIndirect(table, index, ty, args)` — emit the `rt_table.call_indirect_lookup` seam, then
  **apply the returned package-ABI target in tail position of the ok-arm**
  (`case Lookup of {ok,T} -> apply T(Args) ; {error,E} -> raise(E) end`), with the `_at` twin for a
  multi-table module and the `t_`-prefixed twins threading `cur` under `Threaded`.
- `ReturnCallImport(slot, ty, args)` — route through the **existing** import-call logic under `KReturn`
  (value-correct with a **bounded caller frame**; **no** `link` change — no `call_import` tail variant).
  Cross-module / threaded constant-stack tail recursion through imports is **not** guaranteed (Q8 honest-
  scope sub-case), only value-correctness.

The `cont` reaching each of these arms is **discarded** — like `Return`/`Trap`/`Break`, a tail call is a
bottom transfer to the *function's* result, so it emits under a **forced `KReturn`** regardless of any
enclosing block/loop join point. The loop tail-`apply` back-edge (`emit_loop`/`emit_continue`,
emit_core.gleam:4186-4280) is **orthogonal and untouched** (invariant, §8): a tail *call* is a
cross-function transfer.

This unit adds **no new public surface** in `emit_core` (`emit`, `emit_call_direct`,
`emit_call_indirect`, `emit_call_import` stay private `fn`; `emit_module`'s signature is unchanged). It
*does* add the four `call_indirect_lookup*` public functions in `rt_table.gleam`. What changes is the
*emitted Core*: for modules with the three new IR nodes, from the keystone's non-tail-but-correct
delegation to a constant-stack tail call; and for any funcref/`elem`-bearing module, the stored funcref
closure's ABI (list → package) — making funcref-bearing modules **result-identical, not byte-identical**.

---

## §2. Depends on / owns

The IR vocabulary sits behind `«TC-FROZEN»` (Q13-01) and is **read-only**. This unit **owns**
`emit_core.gleam` (the funcref-construction ABI change + the three emit arms) **and** `rt_table.gleam`
(the `call_indirect_lookup*` seam + the non-tail `call_indirect*` re-wrap) — the whole tail codegen is
self-contained here (overview §2 ⚠ ABI reconciliation note). It **does not** touch `link.gleam`.

- **`src/twocore/ir.gleam` (read-only, Q13-01-owned)** — the three nodes, each carrying only `Value`
  operands (leaves): `ReturnCall(fn_name: String, args: List(Value))`,
  `ReturnCallIndirect(table: String, index: Value, ty: FuncType, args: List(Value))`,
  `ReturnCallImport(slot: Int, ty: FuncType, args: List(Value))` (ir.gleam siblings of `Return`, near
  the `CallDirect`/`CallIndirect`/`CallImport` cluster at ir.gleam:658-760).
- **`src/twocore/runtime/rt_table.gleam` (THIS UNIT OWNS — §3.5)** — modelled on the existing
  `call_indirect` at rt_table.gleam:203-224 and the funcref coercions (`ref_to_cell_funcref`
  rt_table.gleam:107 / `ref_to_threaded_funcref` rt_table.gleam:118). This unit adds the **new** additive
  lookup seam that runs the 3 ordered fail-closed guards and **returns the package-ABI target** instead
  of applying it, and it **re-wraps** the non-tail `call_indirect*` package→list so its emitted seam stays
  observably identical:
  - `call_indirect_lookup(index, expected_type) -> Result(target, TrapReason)` — default table (index 0).
  - `call_indirect_lookup_at(table_idx, index, expected_type) -> Result(target, TrapReason)` — multi-table.
  - `t_call_indirect_lookup(st, index, expected_type) -> Result(target, TrapReason)` — threaded twin.
  - `t_call_indirect_lookup_at(st, table_idx, index, expected_type) -> Result(target, TrapReason)`.

  **Guard order (spec-mandated):** (1) `index ∈ [0, size)` else `UndefinedElement`; (2) slot
  non-null else `UninitializedElement`; (3) exact structural `FuncType` `==` else
  `IndirectCallTypeMismatch` — the same three traps, same order, as `call_indirect` (rt_table.gleam:209-221).
  **No new `TrapReason`** (Q8). After the funcref-ABI change the `NoState` target applied over an args
  LIST returns the **`function_return` package** (not a list); the `Threaded` target returns
  `{package, St'}`.
- **`src/twocore/runtime/link.gleam` (read-only — NOT touched this phase)** — the imported tail call
  reuses the **existing** import-call logic under `KReturn` (`emit_call_import`, which reads the closure
  from the positional func-import slot via `func_import_at(slot)` / `t_func_import_at(St, slot)` and
  applies `link.call_import(closure, args)`, link.gleam:236-241, D3a). **No `call_import` tail variant,
  no signature change** — value-correct with a bounded caller frame (Q8 sub-case).

### The ABI-shape invariant (the correctness crux — read before writing a line)

A direct tail call is trivially shape-correct: `emit_call_direct` under `KReturn` yields the bare
`apply 'g'/n(Args)` (emit_core.gleam:2984/2988-2996), and `'g'/n` returns the **`function_return`
package** — bit-for-bit exactly what the caller must return — so it is drop-in (Q1). The invariant this
unit must uphold for **all three** nodes is precisely that drop-in property:

> **Applying the tail target (a direct `apply`, the `call_indirect_lookup` target, or the imported
> `call_import`) in the emitted ok/tail position must yield exactly the value shape a normal
> `Return([r…])` yields for THIS function** — under `NoState`, the `function_return` package
> (`[]`→dummy `'ok'`, `[v]`→bare `v`, `[v1..vn]`→`{v1,…,vn}`, per `function_return`,
> emit_core.gleam:4554); under `Threading(cur)`, `{package, St'}` — **and it must be in genuine BEAM
> tail position** (no wrapping `let`/`case`/tuple between it and the function boundary, so the frame is
> released before the callee runs).

This unit **realizes** the value-shape half at the indirect boundary itself — it owns `rt_table.gleam`
**and** `emit_core`'s funcref-construction (§3.5/§3.6). The fix (overview §2 ⚠ ABI reconciliation note):
the funcref stored closure is changed from the **list ABI** (`fn(List)→List`, a `[apply f(args)]`
cons-wrap — wrong-valued `[v]` not `v`, and secretly non-tail) to **package-ABI tail-transparent**, so
`call_indirect_lookup`'s returned target, tail-applied, yields the `function_return` package directly; the
**non-tail** `call_indirect*` re-wraps that package back to the result list *inside* `rt_table` (using the
guard-checked `FuncType` result arity) so its own seam stays observably identical. This ABI/constant-stack
contract is a **settled decision**, **not** an open seam. If a §5 objective test fails on value shape, the
fix is **here** (the funcref-ABI change or the seam) — **never** a compensating unpack, which would
re-introduce a frame and destroy constant stack (exactly what the non-tail `emit_call_indirect` does at
emit_core.gleam:3237-3262, and why the tail form must NOT). (The overview's open seam **#3** is a
*separate, purely test-fixture* question — whether the deep-indirect constant-stack proof needs a
dedicated bounded-recursion `.wast` fixture beyond the corpus, §5 test 8 — not this ABI contract.)

---

## §3. What it owns + design

**Owned files (D1):**
- **`src/twocore/backend/emit_core.gleam`** — complete the three keystone-placeholder arms + their
  private helpers (§3.1–3.4), **and** perform the funcref-construction ABI change (§3.6:
  `element_closure` / `threaded_element_closure` / `reference_func_entry` → package-ABI tail-transparent).
  **This unit is the single substantive owner of these arms and the funcref-construction** (the keystone
  landed the arms non-tail-but-correct and does **not** touch funcref-construction; Q13-05 completes both).
  Every other `emit_core` line is untouched.
- **`src/twocore/runtime/rt_table.gleam`** (§3.5) — the new additive `call_indirect_lookup*` seam (returns
  the package-ABI target) **and** the non-tail `call_indirect*` package→list re-wrap. Owned outright by
  this unit per the overview §2 ⚠ ABI reconciliation note (the keystone does not touch it).
- new **`test/twocore/backend/emit_core_tailcall_test.gleam`** — the tail-position + package-shape +
  constant-stack + fail-closed emit tests (§5). A fresh file keeps single-owner clean and avoids editing
  the keystone's `test/twocore/tail_call_freeze_test.gleam` or the shared `emit_core_test.gleam`.

### 3.1 The dispatch arms (emit_core.gleam:954-975, `emit`'s top-level `case expr`)

The keystone added three arms adjacent to the existing `CallDirect`/`CallIndirect`/`CallImport`/`Return`
arms (emit_core.gleam:959-962, 956). Q13-05 points each at a real helper:

```gleam
ReturnCall(fn_name, args) -> emit_return_call(fn_name, args, sc, state, ctx)
ReturnCallIndirect(table, index, ty, args) ->
  emit_return_call_indirect(table, index, ty, args, sc, state, ctx)
ReturnCallImport(slot, ty, args) ->
  emit_return_call_import(slot, ty, args, sc, state, ctx)
```

Note the helper arities: they take **no `cont`** — the transfer forces `KReturn` internally, mirroring
`Return(vs) -> emit_return(vs, sc, state)` (emit_core.gleam:956), which likewise drops `cont`.

### 3.2 `emit_return_call` — the direct tail call (Q1, trivial)

Delegate to the existing direct-call helper, forcing the continuation:

```gleam
/// Emit `ReturnCall(fn_name, args)` — a DIRECT tail call. A `CallDirect` under `KReturn` is
/// ALREADY a genuine BEAM tail call (`emit_call_direct`, emit_core.gleam:2965-3000), so a
/// tail call is exactly "the direct-call logic with cont forced to KReturn". The incoming
/// enclosing `cont` is DISCARDED (a bottom transfer returns to the FUNCTION, not the block).
fn emit_return_call(fn_name, args, sc, state, ctx) {
  emit_call_direct(fn_name, args, KReturn, sc, state, ctx)
}
```

What this yields, by reachable `(sc, callee)` case (all verified against emit_core.gleam:2980-2997):
- **`NoState` + `KReturn`** → `apply_cont_call(KReturn, CApply(FName(fn_name, n), Args), r, NoState, …)`
  → the fast path `KReturn, NoState -> Ok(#(produced, state))` (emit_core.gleam:2011) → **bare
  `apply 'f'/n(Args)`** — a real BEAM tail call, constant stack. (A `NoState` self-`return_call` counter
  is the direct constant-stack proof.)
- **`Threading(cur)` + state-reaching callee** → `Ok(#(applied, state))` (emit_core.gleam:2984) →
  **bare `apply 'f'/(n+1)(cur, Args)`**, returning `{Package, St'}` — the threaded return shape,
  constant stack (this is exactly `threaded_tail_call_to_state_reaching_stays_tail_test`,
  emit_core_test.gleam:1393, now reached *through* a tail node).

A **pure** function under a `Threaded` build is emitted under `NoState` (StateChan doc,
emit_core.gleam:264-266), so its self-`return_call` takes the `NoState` bare-tail path above — no special
case needed. The only non-bare combination — a state-reaching caller doing `return_call` to a *pure*
callee — re-pairs the pure result with the unchanged `cur` (emit_core.gleam:2988-2996 via
`apply_cont_call_unpack`), which is bounded (a pure callee cannot tail-recurse back through a
state-reaching frame — a `NoState` function may not call a state-reaching one, by the transitive
state-reaching closure), so it does not threaten constant stack.

### 3.3 `emit_return_call_indirect` — the lookup seam + tail apply (Q1, the hard half)

Emit the **`case`-over-lookup as the whole expression** — no outer `let`, no `unpack_result_list`. The
ok-arm's `apply` is thereby in genuine tail position; the error-arm re-raises the seam's `TrapReason`
verbatim via the same `raise_trap(ctx, …)` the non-tail path uses (emit_core.gleam:3251), preserving the
three fail-closed traps in order.

Resolve `let idx = table_idx(ctx, table)` (emit_core.gleam:3217), `let tag = func_type_term(ty)` (the
compile-time `TypeTag` matched by guard 3 — identical to non-tail, emit_core.gleam:3226), and
`let cargs = core_list(list.map(args, emit_value))`.

**`NoState`, default table (idx == 0):**
```
case call 'twocore@runtime@rt_table':'call_indirect_lookup'(<Index>, <TypeTag>) of
  <{'ok', T}>    when 'true' -> apply T(<[A…]>)              %% 1-ary over the args LIST
  <{'error', E}> when 'true' -> call '<trap_module>':'raise'(E)
end
```
**`NoState`, multi-table (idx ≥ 1):** the head becomes
`call '<table_module>':'call_indirect_lookup_at'(<idx:int>, <Index>, <TypeTag>)`; ok/error arms
identical. (Index 0 keeps the un-indexed head → byte-identity for single-table modules, H7.)

**`Threading(cur)`, default table:**
```
case call '<table_module>':'t_call_indirect_lookup'(<cur>, <Index>, <TypeTag>) of
  <{'ok', T}>    when 'true' -> apply T(<cur>, <[A…]>)       %% 2-ary: (St, args LIST) → {Pkg, St'}
  <{'error', E}> when 'true' -> call '<trap_module>':'raise'(E)
end
```
The table read is read-only, so the **same** `cur` is threaded into the target apply (no rebind). The
target returns `{Package, St'}` — the function's threaded return shape. **`Threading`, multi-table:** head
`t_call_indirect_lookup_at(<cur>, <idx:int>, <Index>, <TypeTag>)`.

Signature to add (private, sibling of `emit_call_indirect`, emit_core.gleam:3207):
```gleam
/// Emit `ReturnCallIndirect(table, index, ty, args)` — an INDIRECT tail call. Emits the
/// `call_indirect_lookup` seam (§3.5, this-unit-owned — the 3-fault fail-closed dispatch that RETURNS
/// the **package-ABI** target instead of applying it) as the whole `case` expression, then APPLIES the
/// target in the ok-arm's TAIL position — a real BEAM tail call in constant stack (Q1). Because the
/// target is package-ABI, its tail-application yields the `function_return` package directly (no
/// unpack, no re-wrap). `error` re-raises the seam's `TrapReason` unchanged (same three traps, same
/// order as `call_indirect`, D3a-clean — the closure is the build-controlled table capability; only the
/// integer `index` is program-derived). Index 0 emits the un-indexed head; ≥1 emits the `_at` head.
/// Under `Threading(cur)` the `t_`-prefixed twins thread the read-only `cur` into both the lookup and
/// the target apply. Discards the enclosing `cont`.
fn emit_return_call_indirect(
  table: String, index: Value, ty: FuncType, args: List(Value),
  sc: StateChan, state: EmitState, ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError)
```
Contrast with the non-tail `emit_call_indirect` (emit_core.gleam:3207-3320): that binds the seam result
in a `let` and calls `unpack_result_list` to continue a *live* continuation (emit_core.gleam:3254-3262),
which is why it is not a tail call. The tail form **omits** the `let`/unpack entirely — the `apply` is
inlined into the ok-arm. Two fresh vars only (`T`, `E`); no `lvar`/`pbound`/`rsvar`/`stvar`.

### 3.4 `emit_return_call_import` — the existing import path under `KReturn` (value-correct, bounded frame)

An imported callee's `link.call_import` returns a value **LIST**, but this function's Core boundary is the
`function_return` **package** — so a bare tail-apply of `call_import` would be *wrong-valued* (`[v]` not
`v`), the exact ABI mismatch the funcref case hit. Per the overview §2 ⚠ ABI reconciliation note, imports
therefore reuse the **existing** import-call logic under a forced `KReturn` — **no** `link` change, **no**
`call_import` tail variant. `emit_call_import` binds the list result and re-packages it (list→package)
under `KReturn`, which is a **frame**: value-correct, and **bounded** (an import callee is a separate BEAM
process; the caller tail-transfers a bounded amount before the import returns — an import cannot
tail-recurse back through our frame). This is an honest-scope sub-case (Q8): cross-module / threaded
*constant-stack* tail recursion through imports is **not** guaranteed — only value-correctness. Both `sc`
cases delegate identically:

```gleam
fn emit_return_call_import(slot, ty, args, sc, state, ctx) {
  emit_call_import(slot, ty, args, KReturn, sc, state, ctx)
}
```

Signature (private, sibling of `emit_call_import`, emit_core.gleam:3366):
```gleam
/// Emit `ReturnCallImport(slot, ty, args)` — an IMPORTED tail call. Routes through the EXISTING
/// import-call logic (`emit_call_import`) under a forced `KReturn` — **no** `link` change, **no**
/// `call_import` tail variant (overview §2 ⚠ ABI reconciliation note). `call_import` returns a value
/// LIST, so `emit_call_import` re-packages it into the caller's `function_return` package under
/// `KReturn` — value-correct, D3a (a 1-ary apply of a handed-in capability, never `erlang:apply` of a
/// data-named atom). This introduces a BOUNDED caller frame (an import cannot tail-recurse back through
/// it): the imported case is **value-correct but NOT a constant-stack claim** (Q8 sub-case). Discards
/// the enclosing `cont` (the forced `KReturn` supersedes it), for both `NoState` and `Threading(cur)`.
fn emit_return_call_import(
  slot: Int, ty: FuncType, args: List(Value),
  sc: StateChan, state: EmitState, ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError)
```

### 3.5 `rt_table.gleam` — the `call_indirect_lookup*` seam + the non-tail `call_indirect*` re-wrap

This unit **owns** `rt_table.gleam` (overview §2 ⚠ ABI reconciliation note). Two coordinated changes:

**(1) Four ADDITIVE lookup functions** — the same 3-guard dispatch as `call_indirect*`, but they
**return the target instead of applying it**, so `emit_core` (§3.3) can tail-apply it. Guard order is
spec-mandated (identical to `call_indirect`): (1) `index ∈ [0, size)` else `UndefinedElement`; (2) slot
non-null else `UninitializedElement`; (3) exact structural `FuncType` `==` else
`IndirectCallTypeMismatch`. **No new `TrapReason`** (Q8).

```gleam
/// Look up (WITHOUT applying) the `call_indirect` target in THIS process's default table (index 0),
/// running the 3 fail-closed guards IN ORDER, and RETURN the target so `emit_core` can TAIL-APPLY it
/// (a real BEAM tail call). After the funcref-ABI change (§3.6) the target is PACKAGE-ABI: applied over
/// an args LIST it yields the callee's `function_return` package DIRECTLY (bare `v` for one result), so
/// tail-applying it in the caller's tail position returns the caller's package with no unpack/re-wrap.
/// D3a-clean (only the integer `index` is program-derived). Raises (fail-closed) on an un-seeded cell.
pub fn call_indirect_lookup(
  index: Int, expected_type: FuncType,
) -> Result(fn(List(Int)) -> List(Int), TrapReason)
// + call_indirect_lookup_at(table_idx, …)          — multi-table twin (rt_state.table_at)
// + t_call_indirect_lookup(st, …)                   — threaded twin; target 2-ary (st, args)→{pkg, st'}
// + t_call_indirect_lookup_at(st, table_idx, …)     — indexed threaded twin
```

The success arm returns the closure (`Ok(target)`) rather than applying it (`Ok(target(args))`) — the
whole point of the seam.

**(2) The non-tail `call_indirect*` re-wrap.** Because §3.6 changes the stored funcref closure to
package-ABI, the four existing `call_indirect*` functions (rt_table.gleam:203-224 etc.) — which still
speak the **list ABI** to `emit_call_indirect` — must, after applying the target, convert its
`function_return` package **back** into the result list using the **guard-checked `FuncType`** result
arity: `0 → []`, `1 → [v]`, `N → tuple_to_list(v)`. This keeps `emit_call_indirect`'s emitted seam
(rt_table.gleam:3207-3320) **observably identical** — the ordinary `call_indirect` still returns the same
result list it did in Phase 12. (This is the price of package-ABI funcref closures: the non-tail path
pays a small re-wrap so the tail path can be constant-stack.)

> **Additive vs re-wrap, freeze impact.** The lookup functions are additive (new code). The `call_indirect*`
> re-wrap is an *edit* to the existing dispatch bodies, so `call_indirect`'s **internal** Core changes —
> but its **result contract** (the list it returns) is unchanged, which is why funcref-bearing modules are
> **result-identical, not byte-identical**. The §5 differential (test against `call_indirect`'s observable
> result) is the arbiter.

### 3.6 `emit_core.gleam` funcref-construction — the package-ABI tail-transparent closure

Change the funcref-stored-closure construction so the stored closure is **package-ABI and
tail-transparent** — the correctness crux of the whole reconciliation (§2). Today `element_closure` /
`threaded_element_closure` / `reference_func_entry` emit a **list-wrapping** closure whose body is
`fun(ArgsList) -> [apply 'f'/n(unpacked)] end` (the `[…]` cons re-wraps the callee's result into a list —
wrong-valued for a tail return, and secretly non-tail because the `apply` sits inside the cons). Change
each to:

```
fun(ArgsList) -> apply 'f'/n(<unpacked args>) end          %% NoState: body a BARE apply, returns f's package
fun(St, ArgsList) -> apply 'f'/(n+1)(St, <unpacked>) end   %% Threading: returns {package, St'}
```

so the body is a **bare `apply` in tail position** returning `f`'s `function_return` package directly.
This is what makes `call_indirect_lookup`'s returned target tail-apply into the caller's package (§3.3),
and it is what forces the non-tail re-wrap in §3.5(2). It affects **every** funcref/`elem`-bearing module
(even one with no `return_call*`), which is why those modules become **result-identical, not
byte-identical** (§8-sanctioned; proven by the `callind` corpus differential in the capstone). Modules
with no funcref/`elem` are entirely unaffected — byte-identical.

---

## §4. The work (ordered, buildable)

1. Confirm `«TC-FROZEN»` is live in `state.md`: the three IR nodes + all exhaustiveness arms + the
   keystone's non-tail value-correct placeholder arms exist, compile, and are green + byte-identical.
   Run `gleam test` to confirm the baseline. (The `call_indirect_lookup*` seam does **not** exist yet —
   it is this unit's to build; `link.gleam` is untouched.)
2. **`rt_table.gleam` (§3.5).** Add the four additive `call_indirect_lookup*` functions (return the
   target), and re-wrap the non-tail `call_indirect*` package→list using the guard-checked `FuncType`
   arity. `gleam build`; run the `rt_table` + `call_indirect` differential tests green.
3. **`emit_core` funcref-construction (§3.6).** Change `element_closure` /
   `threaded_element_closure` / `reference_func_entry` to the package-ABI tail-transparent closure
   (bare `apply`). Re-run the `callind` corpus differential: funcref modules are **result-identical**
   (values + traps unchanged), not byte-identical.
4. Add `emit_return_call` (§3.2) and point the `ReturnCall` arm at it (emit_core.gleam:954-975).
5. Add `emit_return_call_indirect` (§3.3): resolve `idx`/`tag`/`cargs`; emit the `case`-over-lookup with
   the `_at` and `t_` head selection; ok-arm bare `apply` of the package-ABI target, error-arm
   `raise_trap`. Two fresh vars only.
6. Add `emit_return_call_import` (§3.4): delegate to `emit_call_import` under a forced `KReturn` for both
   `NoState` and `Threading` (value-correct, bounded frame — no `link` change).
7. `gleam format` → `gleam build` (zero warnings) → write the §5 tests → `gleam test`.
8. Verify emission: a module with **no funcref/`elem` and no `return_call*`** is byte-identical; a
   funcref/`elem`-bearing module is **result-identical** (the funcref-ABI change). Record completion in
   `state.md` (the keystone-placeholder → Q13-05-completed boundary for `emit_core.gleam` is now closed,
   and `rt_table.gleam` is now this unit's single-owned surface).

---

## §5. Tests (`emit_core_tailcall_test.gleam`) — spec-cited + objective, not change-detectors

Per Q7, the proof is a **constant-stack property + the fail-closed guards**, not emitted-text goldens.
Two layers: structural tail-position assertions (cheap, precise) and behavioral compile-and-run
(the honest "is it really a tail call" test). Build IR by hand; emit via `emit_core.emit_module`; for
behavioral tests reuse the e2e harness pattern (`load(module) -> Atom` + `catch_apply(mod, fn, args)`,
emit_core_e2e_test.gleam:56-58 / :26-33) and the `sum_to(100000)` constant-stack precedent
(emit_core_e2e_test.gleam:152-157).

**Structural — emitted Core is a genuine tail apply:**
1. **Direct is a bare tail apply (`NoState`).** A hand-built `f(x) = ReturnCall("g", [Var x])` (both
   pure) ⇒ the whole body is `CApply(FName("g", n), […])` — no wrapping `CLet`/`CCase`/`CTuple`. Mirror
   `threaded_tail_call_to_state_reaching_stays_tail_test` (emit_core_test.gleam:1393-1429).
2. **Direct is a bare tail apply (`Threaded`, state-reaching callee).** Same shape as the reference test,
   reached through `ReturnCall`: body is `CApply(FName("g", n+1), [CVar(st), …])`, `st` = the function's
   leading record param — returns `{Package, St'}` straight through.
3. **Indirect ok-arm apply is in tail position.** `ReturnCallIndirect("t0", Var i, FuncType([TI32],
   [TI32]), [Var x])` ⇒ the body is `CCase(<call call_indirect_lookup(i, tag)>, [ok-clause, err-clause])`
   with the ok-clause body **exactly** `CApply(_, [<args-list>])` (no `CLet`/`unpack`/`CCase` between the
   apply and the clause), and the err-clause body `CCall(<trap_module>, "raise", [CVar E])`. Assert the
   `TypeTag` arg equals the non-tail path's (`func_type_term` of the same `ty`) so guard 3 matches
   identically (cf. `call_indirect_is_seam_dispatch_test`, emit_core_test.gleam:739-779). Assert the head
   atom is `"call_indirect_lookup"`, NOT `"call_indirect"`.
4. **Indirect multi-table selects the `_at` head.** A module with two tables, `ReturnCallIndirect("t1",
   …)` ⇒ head atom `"call_indirect_lookup_at"` with a leading `CInt(idx)` (idx ≥ 1); a single-table /
   index-0 module keeps the un-indexed `"call_indirect_lookup"` head (byte-identity, H7).
5. **Indirect threads `cur` under `Threaded`.** A state-reaching module ⇒ head
   `"t_call_indirect_lookup"` with a leading `CVar(cur)`, and the ok-arm apply is `CApply(_, [CVar(cur),
   <args-list>])` — the same `cur` in both, no rebind.
6. **Import routes through the existing import path under `KReturn` (value-correct, bounded frame).**
   `ReturnCallImport(slot, ty, [Var x])` emits **exactly** what `emit_call_import(slot, ty, [Var x],
   KReturn, …)` emits (assert structural equality against a direct call to that helper): the closure read
   from `func_import_at(slot)` + the `link.call_import` dispatch + the list→package re-package under
   `KReturn`. It is **NOT** a bare tail apply — so do **not** assert "nothing after the `call_import`";
   the list→package re-package (a bounded frame) is expected and correct. Assert `link_module` /
   `func_import_at` (cf. emit_core.gleam:3378-3390) and that **no** `link` tail variant is called (no
   `link.gleam` change this phase).

**ABI / package-shape — the freeze/DoD guard (the check that would have caught the blocker, §2/§3.5/§3.6):**
6a. **The `call_indirect_lookup` target yields the `function_return` PACKAGE, not a list.** Seed a table
    with a funcref to a compiled function of result arity **1**; `call_indirect_lookup(slot, ty)` ⇒
    `Ok(target)`, and **applying `target` to an args LIST yields the bare value `v`, NOT `[v]`** (the
    package for r=1). Repeat for r=0 (yields the dummy `'ok'`, not `[]`) and r≥2 (yields a tuple
    `{v1,…,vn}`, not a list). This is the exact package-shape assertion the keystone deferred to Q13-05 —
    a list-ABI target would fail here. Add the `t_call_indirect_lookup` threaded analogue: the target
    applied to `(st, args)` yields `{package, St'}`.
6b. **The stored funcref closure's callee apply is in TAIL position.** Inspect the emitted funcref-
    construction closure (§3.6): its body is a bare `apply 'f'/n(<unpacked>)` (no wrapping `[…]` cons /
    `CLet` / `CTuple`) — the structural half of "tail-transparent".
6c. **The non-tail `call_indirect*` re-wrap keeps its result contract (funcref result-identity).** For a
    seeded table and inputs, `call_indirect(index, ty, args)` returns the **same result LIST** it did in
    Phase 12 (differential against the pre-change observable result) — i.e. the §3.5(2) package→list
    re-wrap is faithful. Cross-check `call_indirect(index, ty, args) ==
    rewrap(call_indirect_lookup(index, ty)(args), arity(ty))` across all four guard outcomes, and the
    `t_` threaded analogue. This is the observable proof that funcref-bearing modules are
    **result-identical** despite the internal ABI change.

**Behavioral — the constant-stack property (Q7, the honest test):** a non-tail emission grows the
process stack and would exhaust it; a real tail call completes in constant space.
7. **Direct deep self-recursion completes.** Hand-build a counter `count(n) = if n==0 then Return[acc]
   else ReturnCall("count", [n-1, …])` (an accumulator loop), compile+load, and assert
   `catch_apply(mod, "count", [1_000_000, 0]) == Ok(<expected>)`. A wrapped (non-tail) emission would
   die; the tail call returns. (Direct constant-stack proof — Q1.)
8. **Indirect deep self-recursion through a table slot completes.** Seed a one-slot table whose entry is
   `count` itself (via an element segment / `ref.func`), body does `ReturnCallIndirect(table, Const 0,
   ty, …)` to that slot, and assert the same deep count returns `Ok(<expected>)`. This is open seam #3's
   fixture — deep indirect self-recursion — proving the `call_indirect_lookup` + tail-apply seam is
   genuinely constant stack, not just structurally shaped.
9. **Mutual recursion via `return_call` (even/odd).** `is_even(n) = if n==0 then Return[1] else
   ReturnCall("is_odd", [n-1])` and dual, compile+load, assert `is_even(1_000_000) == Ok(1)` and
   `is_even(999_999) == Ok(0)`. Exercises the value-shape invariant across a **mixed** function (one arm
   a normal `Return`, one arm a `return_call`) — if the tail arm returned a list where the normal arm
   returns a bare value, the results would disagree; equal correct results prove the shapes agree (§2).
10. **Imported `return_call` is VALUE-CORRECT (bounded frame, NOT a constant-stack claim).** Drive an
    import-bearing module that does `return_call_import` to a host provider and assert the returned
    **value** is correct (the list→package re-package under `KReturn` is faithful). Per Q8 (honest scope)
    and the overview §2 ⚠ ABI reconciliation note, cross-module / threaded constant-stack tail recursion
    through imports is **not** guaranteed (the import callee is a separate BEAM process; the caller frame
    is bounded, not eliminated) — so this test asserts value-correctness + a bounded frame, **not** a
    1,000,000-deep constant-stack property. The constant-stack proofs are direct (test 7) + indirect
    (test 8) only.

**Adversarial / must-reject — fail-closed guards preserved (spec: `return_call_indirect` traps are
identical to `call_indirect`, in guard order):**
11. **Undefined element (guard 1).** `return_call_indirect` with an out-of-bounds index (index < 0 or
    ≥ table size) ⇒ trap `UndefinedElement` — same trap as `call_indirect` on the same table.
12. **Uninitialized element (guard 2).** In-bounds but null slot ⇒ trap `UninitializedElement`.
13. **Type mismatch (guard 3).** In-bounds, non-null slot whose stored `FuncType` differs from the call
    site's `ty` ⇒ trap `IndirectCallTypeMismatch`.
14. **Guard ORDER preserved.** A table where an out-of-bounds index *and* a type-mismatched slot could
    both apply ⇒ the **bounds** trap wins (guard 1 before guard 3) — asserting the seam's ordered
    evaluation is not reordered by the tail emission. Assert the same trap the non-tail `call_indirect`
    produces on the identical table+index (differential against `call_indirect`, not a hard-coded
    string), so the two dispatch paths are proven trap-equivalent.
15. **No new trap reason (Q8).** None of the above yields any `TrapReason` outside the existing three;
    "call stack exhausted" is not a WASM trap and never surfaces.

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. The §5 tests green: the structural tail-position assertions, the **package-shape guard** (6a — the
   `call_indirect_lookup` target yields the `function_return` package, not a list) + the funcref
   result-identity differential (6c), the behavioral constant-stack properties (**direct + indirect +
   even/odd** at 1,000,000 depth; imported is **value-correct with a bounded frame**, not a constant-stack
   claim — test 10), and the four fail-closed / guard-order cases. The package-shape guard (6a), the
   even/odd mixed-arm test (value-shape invariant), and the deep indirect test (the fixture answering
   overview open seam #3) are the load-bearing ones.
2. `///` contract docs on every new/edited function — `emit_return_call`, `emit_return_call_indirect`,
   `emit_return_call_import`, the four `rt_table.call_indirect_lookup*` heads (guard order +
   returns-package-ABI-target-not-applies + D3a + fail-closed), and the changed funcref-construction
   (`element_closure` / `threaded_element_closure` / `reference_func_entry` → package-ABI tail-transparent)
   — stating what each emits/returns, the `sc` cases, the discarded `cont`, and the package-ABI contract
   (§2/§3.5/§3.6). The non-tail `call_indirect*` re-wrap carries a `//` note on its package→list conversion.
3. `gleam format --check src test` clean.
4. `gleam build` zero warnings.
5. The unit suite passes; **emission as specified** — a module with **no funcref/`elem` and no
   `return_call*`** is byte-identical (reaches no new arm and no changed funcref-construction), so its
   corpus/conformance stay byte-for-byte green; a funcref/`elem`-bearing module is **result-identical**
   (values + traps unchanged under the funcref-ABI change; `callind` corpus differential). The loop
   back-edge (`emit_loop`/`emit_continue`) is untouched.
6. `state.md` records the `emit_core.gleam` keystone-placeholder → Q13-05-completed boundary as closed
   **and** `rt_table.gleam` as now single-substantive-owned by Q13-05 (the tail arms + funcref-construction
   + the lookup seam + re-wrap).

---

## §7. What it leaves (handoff to downstream)

- **Q13-01 (keystone, upstream):** owns only the frozen IR **vocabulary** (the three nodes + AST instrs
  + exhaustiveness arms + `.ir` round-trip) and the value-correct non-tail placeholder `emit` arms. It
  does **not** own the `call_indirect_lookup` seam, the funcref-construction, or `rt_table.gleam` — those
  are **THIS unit's** (overview §2 ⚠ ABI reconciliation note). If a §5 objective test fails on value
  shape, the fix lives **here** (the funcref-ABI change or the seam), not upstream.
- **Q13-02 / Q13-03 / Q13-04:** decode/WAT ingest, the validation typing rule, and the bottom-transfer
  lowering that *produces* the three IR nodes this unit emits. Q13-05 assumes hand-built IR in its own
  tests and does not depend on the frontend landing first (Wave A parallelism).
- **Q13-06 (capstone):** the end-to-end proof — the official `return_call.wast` /
  `return_call_indirect.wast` green, the corpus tail-recursion program in the full `(mode ×
  state_strategy × mem_tier)` matrix with `OptNone ≡ Baseline ≡ Aggressive`, the two EH files
  (`legacy/try_catch.wast`, `legacy/try_delegate.wast`) unblocked, the SVG regen, and the status
  compaction. Q13-05's unit-level constant-stack tests are a *local* proof; the capstone's corpus at
  1,000,000 across the matrix is the *authoritative* one.
- **Out of scope (unchanged, Q8):** the optimizer barrier arms (keystone), the loop back-edge, any
  memory-tier or state-strategy machinery — all inherit the feature through this one `emit_core` seam,
  untouched.
