# Q13-01 — The keystone: the three tail-call IR nodes + the tail-call vocabulary freeze

> **Status:** scoped, awaiting build. **Owner:** Q13-01 (the keystone — goes first and alone).
> **Freeze:** produces `«TC-FROZEN»`. **Read order:** [`00-overview.md`](00-overview.md) → the distilled
> codebase map (`brief-phase13-tailcall.md`) → this doc. All prior-phase decisions and the permanent
> invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold. This unit lands
> **green with default emission byte-identical** — it adds three IR nodes + two AST instrs + a lossless
> `.ir` round-trip, and lands three documented conservative-sound **value-correct** compile-arms into
> `validate`/`lower`/`emit_core` that units Q13-03/04/05 complete. The `rt_table.call_indirect_lookup`
> seam, the funcref-ABI change, and the `link` tail-import path are **NOT** the keystone's — they are
> self-contained in Q13-05 (overview §2 ⚠ ABI reconciliation note); the keystone touches neither
> `rt_table.gleam` nor `link.gleam`. **No emitted `.core` for a `return_call*`-free module changes.**

---

## §1. Goal

Freeze the **whole tail-call IR + runtime vocabulary** every downstream unit binds to, and prove it is
expressible, lossless, inert-by-default, and byte-identical. Concretely:

- **Three new `ir.Expr` nodes** — `ReturnCall`, `ReturnCallIndirect`, `ReturnCallImport` — each a
  **bottom-transfer barrier carrying only `Value` operands** (leaves in every traversal, siblings of
  `Return`/`Trap`).
- **Two new `ast.Instr` constructors** — `ReturnCall(func)` / `ReturnCallIndirect(type_idx, table)` —
  the decode/WAT surface (immediates identical to `call` / `call_indirect`; **field naming anti-swap**).
- **A lossless `.ir` printer/parser round-trip** for the three nodes (**D5**).
- **Every exhaustiveness-forced arm** across `effect`, `ir_lower`, and the seven `ir_opt/*` passes —
  final **barrier / operand-rewrite** arms (never reorder/CSE/DCE across a tail call, exactly like
  `Return`/`CallImport`).
- **Three conservative-sound compile-arms** into `validate.gleam` / `lower.gleam` / `emit_core.gleam`,
  documented as *reaches* (completed by Q13-03/04/05), each keeping the file **single-substantive-owner**
  and every intermediate state **green + byte-identical**.

Implements the load-bearing parts of **Q1** (the bottom-transfer IR vocabulary — the lookup seam +
funcref-ABI change are Q13-05's, per the overview's ⚠ ABI reconciliation note), **Q2** (constructors +
exhaustiveness plumbing + D5 round-trip), and the *reach* side of the **Q4/Q5** completion boundary; it
upholds **Q6** (byte-identical default) and **Q8** (no new trap, no optimizer/tier/state change).

**Resolves overview open seam #2:** `ReturnCallImport` is a **distinct IR node**, not `ReturnCall` with an
`imported: Bool`. Rationale: it mirrors the existing `CallImport` ≠ `CallDirect` split, gives Q13-05 a
clean per-node emit path (positional-slot closure read + `link.call_import` under `KReturn`, structurally
different from a same-module `apply`), and does not over-fragment the optimizer arms (all three are the
*same* Value-only barrier class — one mirrored arm per site).

---

## §2. Depends on / Produces

**Depends on (read-only, frozen upstream):**
- `src/twocore/ir.gleam` — `Expr`, `Value`, `FuncType(params, results)` (line 398), `TrapReason`
  (`UndefinedElement`/`UninitializedElement`/`IndirectCallTypeMismatch` already exist — line 1445+),
  `Return`/`Trap`/`CallDirect`/`CallIndirect`/`CallImport` as the sibling shapes.
- `src/twocore/runtime/rt_table.gleam` — the existing frozen 3-guard dispatch (`call_indirect` 203–223,
  `call_indirect_at` 241–262, `t_call_indirect` 418–439, `t_call_indirect_at` 445–467), **read-only**:
  the keystone's placeholder `emit` arm delegates through the existing `emit_call_indirect` (which calls
  these); it **does not add or edit any `rt_table` function**. The `call_indirect_lookup` seam + the
  funcref-ABI package→list re-wrap are **Q13-05's** (overview §2 ⚠ ABI reconciliation note).
- `src/twocore/runtime/link.gleam` — `call_import(closure, args)` (236–241), **read-only**: reached only
  via the existing `emit_call_import` in the keystone's placeholder delegation. **Not touched this phase**
  (no `call_import` tail variant — Q13-05's imported tail call reuses the existing import path).

**Produces `«TC-FROZEN»`:** the three IR nodes, the two AST constructors, the `.ir` round-trip
spellings, and every exhaustiveness arm (effect/optimizer as final barriers; validate/lower/emit as
conservative-sound **value-correct** placeholders). The `rt_table.call_indirect_lookup*` seam + the
funcref-ABI change + the `link` tail-import path are **NOT** part of the freeze — they are self-contained
in Q13-05 (overview §2 ⚠ ABI reconciliation note), so nothing downstream binds to them at freeze time.
**Unblocks** Q13-02 (ingest), Q13-03 (validate), Q13-04 (lower), Q13-05 (emit_core real tail),
Q13-06 (capstone).

---

## §3. What it owns + design

**Owned files (D1) — this unit is the sole substantive owner of each:**
`src/twocore/ir.gleam` · `src/twocore/frontend/wasm/ast.gleam` · `src/twocore/ir/effect.gleam` ·
`src/twocore/ir/printer.gleam` · `src/twocore/ir/parser.gleam` · `src/twocore/middle/ir_lower.gleam` ·
`src/twocore/middle/ir_opt/{pass,baseline,aggressive,bce,loop_analysis,mem_clobber,mem_ssa}.gleam` · new
`test/twocore/tail_call_freeze_test.gleam`. **Does NOT own `rt_table.gleam` / `link.gleam`** — the
`call_indirect_lookup` seam + the funcref-ABI change live in Q13-05, and `link.gleam` is not touched this
phase (overview §2 ⚠ ABI reconciliation note).

**Three documented cross-file reaches** (conservative-sound compile-arms, §3.9), completed by
Q13-03/04/05, recorded in `state.md`: `src/twocore/frontend/wasm/validate.gleam`,
`src/twocore/frontend/wasm/lower.gleam`, `src/twocore/backend/emit_core.gleam`.

> **Build strategy — let the compiler enumerate the sites.** Gleam has no default match arm and all the
> touched matches are total. **Add the three IR constructors to `ir.gleam` first, then `gleam build`:**
> every non-exhaustive-match error points at exactly the site that needs an arm. The anchors below are
> the *map*; the compiler is the *checklist*. Every new arm mirrors `CallImport` (a Value-only barrier).

### 3.1 The three IR nodes — `ir.gleam` (insert next to `CallImport`, ~line 760)

Add, with full `///` contract docs, siblings of `Return` (bottom transfer) and `CallImport`
(Value-only, capability dispatch):

```gleam
/// A DIRECT tail call to same-module function `fn_name` (WASM `return_call $f`). BOTTOM: transfers
/// control to the callee whose results BECOME this function's results; the rest of the block is
/// unreachable (like `Return`). Carries only `Value` args (a leaf in every traversal). Effectful
/// barrier (§effect). `emit_core` (Q13-05) emits it as a GENUINE BEAM tail call — the direct-call
/// logic forced under `KReturn` — so cross-function tail recursion runs in CONSTANT stack. Only
/// `lower` of a `return_call` to a DEFINED function produces this node (imports → `ReturnCallImport`).
ReturnCall(fn_name: String, args: List(Value))

/// An INDIRECT tail call through `table` at `index`, type-checked against `ty` (WASM
/// `return_call_indirect`). BOTTOM (like `Return`). Carries only `Value` operands (`index` + `args`).
/// Effectful barrier. `emit_core` (Q13-05) emits the lookup seam
/// (`rt_table.call_indirect_lookup*`, Q13-05-owned) then TAIL-APPLIES the returned **package-ABI**
/// target in the ok-arm — same 3 fail-closed guards, same traps, same order as `CallIndirect`, but
/// constant stack. `table` is the table NAME (resolved to an absolute tableidx by `emit_core`); `ty`
/// is the call-site `FuncType` (guard 3 matches it structurally).
ReturnCallIndirect(table: String, index: Value, ty: FuncType, args: List(Value))

/// A tail call to an IMPORTED function by positional func-import `slot` (WASM `return_call $f` where
/// `f` is an import). BOTTOM (like `Return`). Carries only `Value` args. Effectful barrier.
/// `emit_core` (Q13-05) reads the linker-built closure from the instance's func-import `slot`, then
/// TAIL-APPLIES `link.call_import(closure, args)` under `KReturn` (D3a — a handed-in capability, never
/// an ambient `apply`). Distinct from `ReturnCall` (same-module `apply`) for a clean emit path
/// (resolves overview open seam #2).
ReturnCallImport(slot: Int, ty: FuncType, args: List(Value))
```

**Contract to freeze in the docs:** each is bottom (does not fall through — its callee's results are the
function's results); each carries **only `Value` operands** (no sub-`Expr`), so it is a leaf in
`pass.map_expr` and a barrier in `effect`; **no new `TrapReason`** — the indirect guards reuse the three
existing element/type reasons, and "call stack exhausted" is not a WASM trap (Q8).

### 3.2 The two AST instrs — `ast.gleam` (insert after `CallIndirect`, ~line 588)

```gleam
/// `return_call $f` (0x12). Immediate: one u32 funcidx — IDENTICAL to `Call`.
ReturnCall(func: Int)
/// `return_call_indirect (type $t) $tbl` (0x13). Immediates: u32 typeidx THEN u32 tableidx —
/// IDENTICAL to `CallIndirect` (field naming ANTI-SWAP: `type_idx` before `table`).
ReturnCallIndirect(type_idx: Int, table: Int)
```

> The keystone adds the constructors only; **Q13-02 owns the `0x12`/`0x13` decode + the
> `return_call`/`return_call_indirect` WAT keywords**. No default module produces these, so their mere
> existence is conformance-neutral (Q6).

### 3.3 `effect.gleam` — the barrier arm (`is_effectful_node`, ~line 146, beside `CallImport`)

Add all three to the `-> True` (effectful) group:

```gleam
| ReturnCall(_, _)
| ReturnCallIndirect(_, _, _, _)
| ReturnCallImport(_, _, _)
```

Freeze in a `//` note: like `Return`/`Trap`/`CallImport`, a tail call is a non-local control transfer
that transfers to arbitrary callee code — **never** reordered, hoisted, CSE'd, duplicated, or eliminated.
The deep `classify`/`can_cse`/`can_eliminate_if_unused` derive `Effectful`/`False`/`False` from this arm
(asserted in §5).

### 3.4 `printer.gleam` + `parser.gleam` — lossless `.ir` round-trip (D5)

**Printer** (`print_expr`, beside `CallDirect`/`CallIndirect`/`CallImport`, ~lines 716/731/864) — reuse
the frozen `value_list` / `print_value` / `print_functype` helpers so the spelling cannot drift:

```gleam
ReturnCall(fn_name, args) ->
  "return_call @" <> fn_name <> " " <> value_list(args)
ReturnCallIndirect(table, index, ty, args) ->
  "return_call_indirect @" <> table <> " [" <> print_value(index) <> "] : "
    <> print_functype(ty) <> " " <> value_list(args)
ReturnCallImport(slot, ty, args) ->
  "return_call_import " <> int.to_string(slot) <> " : "
    <> print_functype(ty) <> " " <> value_list(args)
```

**Parser** (`parse_expr` keyword `case`, beside `"call"`/`"call_indirect"`/`"call_import"`, ~lines
1424/1444/1414) — three **exact-string** arms (unambiguous: distinct full keywords; the existing
`"return"` arm is a different string). Reuse `parse_at_name` / `parse_value` / `parse_functype` /
`parse_value_list` / `expect_number` / `expect(_, TColon/TLBracket/TRBracket, _)`:

```gleam
"return_call" -> {
  use #(fname, rest) <- result.try(parse_at_name(rest))
  use #(args, rest) <- result.try(parse_value_list(rest))
  Ok(#(ReturnCall(fname, args), rest))
}
"return_call_indirect" -> parse_return_call_indirect(rest)   // clone of parse_call_indirect (1703)
"return_call_import" -> parse_return_call_import(rest)         // clone of parse_call_import (2092)
```

where `parse_return_call_indirect` and `parse_return_call_import` are verbatim clones of the frozen
`parse_call_indirect` (1703–1715) / `parse_call_import` (2092–2100) that build the `ReturnCall*` node
instead. **D5 requirement:** `parser.parse_module(printer.print_module(m)) == Ok(m)` for any module using
the three nodes (proved in §5, test 3), including a multi-value `ty`, a non-default `table` name, a `slot
>= 1`, and `index` as both a `Var` and a constant.

### 3.5 `ir_lower.gleam` — leaf threading, no per-call charge

`ir_lower` inserts `Charge` only on fn-entry (174–175) and loop body (181–182) — **never per call**. Add
the three nodes to the recursive walk's **leaf** handling exactly like `CallDirect`/`CallImport`: they
carry only `Value` operands (no sub-`Expr` to recurse into) and receive **no `Charge`**. Metering stays
identical to an ordinary call (Q8 — no metering change).

### 3.6 `ir_opt/*` — barrier + operand-rewrite arms (seven files)

All three nodes are the **same class**: Value-only, effect-barrier, siblings of `CallImport`. At every
site, mirror the existing `CallImport` arm. Known anchors (the compiler enumerates the rest — grep
`ir.CallImport(` in each file and mirror):

- **`pass.gleam`** (`map_expr` pass-through group, ~line 151, beside `ir.CallImport(..)`): add
  `ir.ReturnCall(..) | ir.ReturnCallIndirect(..) | ir.ReturnCallImport(..)` — Value-only leaves return
  unchanged from the `Expr`-traversal combinator.
- **`baseline.gleam`** — (a) `subst_expr` (~986): `ReturnCall(f, a) -> ReturnCall(f, subst_values(a,
  subs))`; `ReturnCallIndirect(t, i, ty, a) -> ReturnCallIndirect(t, subst_value(i, subs), ty,
  subst_values(a, subs))`; `ReturnCallImport(s, ty, a) -> ReturnCallImport(s, ty, subst_values(a,
  subs))`. (b) free-name collector (~1134): `ReturnCall(_, a) -> values_names(a)`;
  `ReturnCallIndirect(_, i, _, a) -> list.append(value_name(i), values_names(a))`; `ReturnCallImport(_,
  _, a) -> values_names(a)`. (Plus any other explicit call-node arm the compiler flags.)
- **`aggressive.gleam`** — `apply_rename_subst` (~640) and its free-name/liveness collectors: rewrite the
  Value operands with `rs_value`/`rs_values` (index + args) exactly as the `CallImport` arm; collect
  operand names for liveness. Never CSE/hoist/DCE across them (barriers, from `effect`).
- **`bce.gleam`** (`has_grow_or_call`, ~385–392, and the second call-scan site): add all three to the
  `-> True` group — **a tail call is a call**, so a loop containing one is NOT versioning-eligible.
- **`loop_analysis.gleam`** (operand-var collector, ~126, and its sibling site): `ReturnCall(_, a) ->
  union_values(acc, a)`; `ReturnCallIndirect(_, i, _, a) -> union_values(add_value(acc, i), a)`;
  `ReturnCallImport(_, _, a) -> union_values(acc, a)`.
- **`mem_clobber.gleam`** (both `-> True` clobber groups, ~37–41 and ~75–79): add all three — a call
  clobbers/​may-write any memory AND transfers control non-locally.
- **`mem_ssa.gleam`** ("barriers: calls out" `-> True` group, ~215–219): add all three.

None of these changes any default module's optimization (the nodes never appear by default — Q6).

### 3.7–3.8 `rt_table.gleam` / `link.gleam` — NOT the keystone's (moved to Q13-05, ABI reconciliation)

The scoping critique caught a phase-killer in the original "the keystone adds a `call_indirect_lookup`
seam that returns the stored funcref closure for `emit_core` to tail-apply" plan: a funcref table target
today speaks the **list ABI** (`fn(List) -> List`, a `[apply f(args)]` cons-wrap), while a WASM
function's Core boundary is the **`function_return` package** (`[]`→`'ok'`, `[v]`→bare `v`, `[…]`→tuple).
Tail-applying the stored list-wrapping closure would be *both* wrong-valued (`[v]` not `v`) *and* secretly
non-tail (the inner `apply` inside a cons → linear stack growth). The overview's **§2 ⚠ ABI reconciliation
note** resolves this by moving the whole tail codegen into **Q13-05**:

- **`rt_table.gleam` is owned by Q13-05**, which (a) changes the funcref-construction ABI in `emit_core`
  (`element_closure` / `threaded_element_closure` / `reference_func_entry` → **package-ABI
  tail-transparent** closures whose body is a bare `apply 'f'/n(unpacked)`), (b) adds the
  `call_indirect_lookup` (+`_at`+`t_`) seam that runs the 3 guards and **returns the package-ABI target**
  for tail-apply, and (c) re-wraps package→list **inside** the non-tail `call_indirect*` using the
  guard-checked `FuncType` result arity (`0→[]`, `1→[v]`, `N→tuple_to_list`) so `emit_call_indirect`'s
  emitted seam stays observably identical. **The keystone does not add, edit, or freeze any `rt_table`
  function**, and does not describe the lookup seam's signatures or body.
- **`link.gleam` is NOT touched this phase.** Imported tail calls (`ReturnCallImport`) reuse the
  **existing** import-call logic under `KReturn` (Q13-05) — no `call_import` tail variant, no signature
  change; value-correct with a **bounded caller frame** (an honest-scope sub-case, Q8 — cross-module /
  threaded constant-stack tail recursion through imports is *not* guaranteed). The keystone adds no note
  to `call_import`.

The freeze guard that the lookup target, when applied, yields the `function_return` package (bare `v` for
one result, `'ok'`/tuple otherwise), **not** a list — the assertion that would have caught the original
blocker — lives in **Q13-05's** `emit_core_tailcall_test`, not in the keystone's freeze test.

Consequence: because the funcref-construction ABI changes, **funcref-bearing modules become
result-identical rather than byte-identical** (§8-sanctioned; proven by the `callind` corpus
differential). Modules with no funcref/`elem` stay byte-identical. This is Q13-05's consequence to prove,
not the keystone's — the keystone's placeholder emit (§3.9c) delegates through the *unchanged* non-tail
seam, so at freeze time even funcref-bearing modules stay byte-identical.

### 3.9 The three conservative-sound compile-arms (validate / lower / emit_core) — the reach

Because Gleam has no default arm, adding the AST + IR constructors forces arms in `validate.gleam`,
`lower.gleam`, and `emit_core.gleam` **merely to compile**. The keystone lands them **conservative-sound
and byte-identical**; Q13-03/04/05 **complete** each file's arm (the substantive owner). At keystone time
**no test reaches any of these arms** — Q13-02 (decode/WAT) has not landed, so no module produces the AST
or the new IR nodes yet — so "byte-identical + green" is trivially satisfied; the placeholders exist to
compile and to be **sound if reached**.

**(a) `validate.gleam` — arms for `ast.ReturnCall` / `ast.ReturnCallIndirect`.** Land the **`return`-shape
operand typing minus the result-equality check**:

- `ast.ReturnCall(f)`: fetch `sig` (like `Call` 964–971), `pop_vals(st, sig.params)`, then
  `mark_unreachable` (like `Return` 953–961). No push (bottom).
- `ast.ReturnCallIndirect(type_idx, table)`: fetch `sig` + `table_entry`, require the entry `FuncRef`
  else `RefTypeMismatch`, `pop_expect(st, ast.I32)`, `pop_vals(sig.params)`, then `mark_unreachable`
  (like `CallIndirect` 978–991 but bottom instead of pushing results).

This is **sound for every VALID module** (correct operand consumption + `return`-shape stack
polymorphism). **Q13-03 completes it** by adding the spec result-equality check — `sig.results ==
label_types(list.last(st.ctrls))`/`func_frame.end_types` else `TypeMismatch` (reusing the existing
`TypeMismatch` variant — no new error, so `validate.gleam` stays single-owner) — and the `assert_invalid`
spec tests. The keystone doc marks this as "operand typing landed; result-equality + rejection tests
deferred to Q13-03." (The lenient-on-invalid gap is never exercised until Q13-03's own tests.)

**(b) `lower.gleam` — arms for `ast.ReturnCall` / `ast.ReturnCallIndirect` in `go`.** Land the
**bottom-transfer template** (like `ast.Return` 527–535 / `ast.Unreachable` 536–539), but **desugar to an
ordinary call bound to fresh names + `ir.Return` of them** — NOT yet the new IR nodes:

```gleam
ast.ReturnCall(f) -> {
  // PLACEHOLDER (Q13-04 completes with the real ReturnCall/ReturnCallImport bottom node). Sound
  // bottom transfer: ordinary call bound to fresh names, then Return them; result-identical, NOT the
  // constant-stack node yet.
  use sig <- result.try(nth_err(ctx.func_types, f, UnknownFuncIndex(f)))
  let args = take_push_order(st.stack, list.length(sig.params))
  let #(names, c2) = fresh_n(st.counter, list.length(sig.results))
  let call = case f < ctx.imported {
    True  -> ir.CallImport(f, ir_functype(sig), args)
    False -> ir.CallDirect("f" <> int.to_string(f), args)
  }
  let node = ir.Let(names, call, ir.Return(list.map(names, ir.Var)))
  use #(marker, rest) <- result.try(consume_dead(tail, 0))
  Ok(end_or_else(marker, node, rest, c2))
}
```

`ast.ReturnCallIndirect` desugars the same way to `ir.Let(names, ir.CallIndirect(table, index, ty, args),
ir.Return(vars))` (pop `i32` index + params in the frozen `call_indirect` order). Because this produces
**ordinary** IR nodes, the pipeline flows through the unchanged emit path (byte-identical for any module —
though none exist yet). **Q13-04 completes it** by replacing the desugared `Let(names, call, Return)` with
the real `ir.ReturnCall` / `ir.ReturnCallImport` (import split `f < ctx.imported`) / `ir.ReturnCallIndirect`
bottom node (no `wrap_let`, no live-continuation recurse). The keystone doc marks this "bottom-transfer
placeholder as ordinary-call-then-return; real ReturnCall* node deferred to Q13-04."

**(c) `emit_core.gleam` — arms for `ir.ReturnCall` / `ir.ReturnCallIndirect` / `ir.ReturnCallImport` in
`emit` (~954).** Land the **semantically-correct, explicitly NON-constant-stack delegation** the overview
specifies ("emit the equivalent ordinary call + return — right answer, not yet a tail call"). Route
through the existing ordinary-call emitters under a continuation that **binds the results then function-
returns them** (`KBind(fresh_names, ir.Return(vars), KReturn)`), so the call sits in a `let`-binding — a
real frame, NOT a tail position:

```gleam
ir.ReturnCall(fn_name, args) -> {
  // PLACEHOLDER (Q13-05 completes as a forced-KReturn genuine tail call). Non-tail: bind results, return.
  let r = result.unwrap(dict.get(ctx.fn_results, fn_name), 1)
  let #(names, st2) = fresh_n_vars(state, r)
  emit_call_direct(fn_name, args,
    KBind(names, ir.Return(list.map(names, ir.Var)), KReturn), sc, st2, ctx)
}
ir.ReturnCallImport(slot, ty, args) -> {   // r = list.length(ty.results); via emit_call_import, same KBind }
ir.ReturnCallIndirect(table, index, ty, args) -> {   // r = list.length(ty.results); via emit_call_indirect, same KBind }
```

Result-identical to the real tail call (same values, same traps in the same order) — it differs **only**
in stack growth, which is not WASM-observable — so it keeps the whole matrix green while making the
completion boundary crisp: **the keystone does NOT claim the constant-stack property.** **Q13-05 completes
it** — owning the *whole* tail codegen (overview §2 ⚠ ABI reconciliation note): the funcref-construction
ABI change (`element_closure`/… → package-ABI tail-transparent), the `rt_table.call_indirect_lookup` seam
+ the non-tail `call_indirect*` package→list re-wrap, and the real emit arms (direct = direct-call logic
forced under `KReturn`, a bare tail `apply`; indirect = the lookup seam + tail-apply the package-ABI
target; imported = the existing import path under `KReturn`, value-correct/bounded-frame, **no** `link`
change) — plus the constant-stack proof. The keystone doc marks this "non-tail delegation placeholder;
real constant-stack tail emission + rt_table seam + funcref-ABI change deferred to Q13-05."

> **Boundary summary (resolves overview open seam #1).** Per file: keystone lands the *sound skeleton*
> (validate: operand typing; lower: bottom-transfer desugar to ordinary-call-then-return; emit: non-tail
> delegation); the unit lands the *substance* (validate: result-equality + assert_invalid; lower: the
> real `ReturnCall*` nodes; emit: the forced-`KReturn` tail + lookup seam + constant-stack proof). Every
> file stays single-substantive-owner; every intermediate state is green + byte-identical.

---

## §4. The work (ordered, buildable)

1. **`ir.gleam`** — add the three nodes (§3.1) with `///` docs. `gleam build` now lists every
   non-exhaustive match — this is your worklist.
2. **`ast.gleam`** — add the two instrs (§3.2). (Decode/WAT is Q13-02; not here.)
3. **`effect.gleam`** (§3.3), **`ir_lower.gleam`** (§3.5), **`ir_opt/*`** ×7 (§3.6) — clear every barrier /
   operand-rewrite arm the compiler flags, mirroring `CallImport`.
4. **`printer.gleam` + `parser.gleam`** (§3.4) — the three print arms + the three parse arms (two via
   cloned helpers). Confirm D5 round-trip locally.
5. **`validate.gleam` / `lower.gleam` / `emit_core.gleam`** (§3.9) — the three conservative-sound
   value-correct placeholder arms (the `emit` arm routes each `ReturnCall*` through the **existing**
   non-tail `call`/`call_indirect`/`call_import` + return — no `rt_table`/`link` edit). Record all three
   reaches in `state.md`.
6. `gleam format` → `gleam build` (**zero warnings**) → write the freeze tests (§5) → `gleam test`.
7. **Verify default emission byte-identical** — run the existing corpus/conformance suite unchanged
   (no `.core` for a `return_call*`-free module changes; the new nodes/arms are unreached). Announce
   `«TC-FROZEN»` in `state.md` with the three reaches recorded and the exact running-total re-confirmed.

---

## §5. Tests (`test/twocore/tail_call_freeze_test.gleam`) — spec-cited + adversarial

Objective tests against the **WebAssembly tail-call proposal** + the frozen contract, **not**
change-detectors (Q7/D8). Model on `test/twocore/ir/eh_freeze_test.gleam`.

1. **The three nodes are EXPRESSIBLE.** Construct a `Function`/`Module` whose body uses `ReturnCall`,
   `ReturnCallIndirect`, and `ReturnCallImport` (each carrying `Value` operands — `Var`s and consts) and
   assert it typechecks (the value compiles) + the frozen shapes via `let assert`. This is the
   load-bearing freeze: Q13-02..06 bind to exactly these constructors.

2. **Every tail-call node is an effect BARRIER (Q2).** For each of the three:
   `effect.classify(node) == Effectful`, `effect.can_cse(node) == False`,
   `effect.can_eliminate_if_unused(node) == False`. Spec cite: `return_call*` transfer control and are
   stack-polymorphic like `return` — never reorder/CSE/DCE.

3. **Lossless `.ir` round-trip (D5).** Build a module using all three nodes and assert
   `parser.parse_module(printer.print_module(m)) == Ok(m)`. **Adversarial coverage:** a **multi-value**
   `ty` (e.g. `[TI32, TF64] -> [TI32, TF64]`), a **non-default** `table` name, a `ReturnCallImport` with
   `slot >= 1`, and `index` as **both** a `Var` and a constant across two nodes. This is the D5 proof.

4. **No new `TrapReason` (Q8).** Lock the exact `TrapReason` variant set (a compile-time list, like
   eh's `trap_reason_unchanged_test`) — the indirect guards reuse `UndefinedElement` /
   `UninitializedElement` / `IndirectCallTypeMismatch`; assert the count is unchanged. Spec cite: "No
   'call stack exhausted' trap exists" — a WASM tail call traps for exactly the reasons an ordinary call
   does.

5. **Defaults inert / byte-identical (Q6).** A `return_call*`-free module (one memory, function-only):
   (a) `parser.parse_module(printer.print_module(m)) == Ok(m)`; (b) its `.ir` text contains **none** of
   `"return_call"`, `"return_call_indirect"`, `"return_call_import"`; (c)
   `emit_core.emit_module(m, instance.safe_default())` succeeds and the printed `.core` contains **no**
   `"call_indirect_lookup"` and **no** `"return_call"` (the new arms/seam are unreached). Mirrors eh's
   `tag_free_module_is_conformance_neutral_test`. (Full byte-identity is additionally guaranteed by the
   unchanged corpus/conformance run — DoD §6.5.)

6. **Placeholder emit is VALUE-CORRECT (the reach is sound, Q6).** Hand-build a module whose body uses
   each of the three nodes (as Q13-04 will eventually produce them), emit it via
   `emit_core.emit_module(m, instance.safe_default())`, and assert the emit **succeeds** and routes each
   node through the EXISTING ordinary-call path bound-then-returned — the `.core` contains an ordinary
   `call`/`apply` + a function return for the node, and **no** `"call_indirect_lookup"` and **no** bare
   tail form — i.e. the keystone's delegation is a correct *non-tail* emission, not yet a tail call. The
   keystone deliberately does **NOT** assert the constant-stack property or the lookup-seam package shape:
   those (the `call_indirect_lookup` target yields the `function_return` package not a list; the callee
   apply is in tail position) are **Q13-05's** guards, in its `emit_core_tailcall_test`. This test pins
   that the reach compiles and is value-sound if reached, keeping the completion boundary crisp.

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. Spec-cited freeze tests (§5) green — including the D5 round-trip (test 3) and the placeholder-
   soundness test (test 6). (The lookup-seam guard-order / package-shape guards are **Q13-05's**, not the
   keystone's.)
2. `///` contract docs on **every** new public type/constructor/function: the three IR nodes (bottom +
   Value-only + barrier + no-new-trap) and the two AST instrs. Each conservative-sound value-correct
   placeholder arm (§3.9) carries a `//` note naming the completing unit. (No `rt_table`/`link` docs are
   the keystone's — those functions are not added or edited here.)
3. `gleam format --check src test` clean.
4. `gleam build` **zero warnings** (every forced arm cleared; no unused import/var).
5. The unit suite passes; **default emission byte-identical** — the existing corpus/conformance suite is
   green and unchanged (no `.core` for a `return_call*`-free module changes; the new nodes/arms/seam are
   unreached and dead-until-called), and `OptNone ≡ Baseline ≡ Aggressive` across the matrix is
   undisturbed.
6. `«TC-FROZEN»` announced in `state.md` with the three cross-file reaches (`validate`/`lower`/
   `emit_core`) recorded as *conservative-sound placeholders* and the exact running total re-confirmed.

---

## §7. What it leaves (handoff to downstream)

- **Q13-02 (ingest):** decode `0x12 → ast.ReturnCall(f)` (one u32 funcidx; `idx_instr` reuse) and
  `0x13 → ast.ReturnCallIndirect(type_idx, table)` (u32 typeidx THEN u32 tableidx — the 0x11 body
  verbatim, anti-swap); WAT `"return_call"` / `"return_call_indirect"`. Binds to the frozen AST
  constructors; owns its own decode/WAT round-trip tests.
- **Q13-03 (validate):** **completes** the `validate.gleam` arms — add the spec **result-type equality**
  check (`sig.results == the function frame's end_types` else `TypeMismatch`, reusing the existing
  variant) on top of the keystone's operand typing, plus the `assert_invalid` spec fixtures (callee
  results ≠ function results → rejected) and the stack-polymorphism-matches-`return` cases.
- **Q13-04 (lower):** **completes** the `lower.gleam` arms — replace the keystone's ordinary-call-then-
  `Return` desugar with the real `ir.ReturnCall` / `ir.ReturnCallImport` (import split `f <
  ctx.imported`) / `ir.ReturnCallIndirect` bottom nodes (no `wrap_let`, dead continuation `consume_dead`d);
  hand-built AST → IR lower tests.
- **Q13-05 (emit_core + rt_table):** **completes** the `emit_core.gleam` arms **and owns the whole tail
  codegen** (overview §2 ⚠ ABI reconciliation note): the funcref-construction ABI change
  (`element_closure`/`threaded_element_closure`/`reference_func_entry` → package-ABI tail-transparent);
  the new `rt_table.call_indirect_lookup*` seam (returns the package-ABI target) + the non-tail
  `call_indirect*` package→list re-wrap; and the genuine constant-stack tail emission: `ReturnCall` =
  direct-call logic forced under `KReturn` (bare tail `apply`); `ReturnCallIndirect` = the
  `call_indirect_lookup*` seam + tail-apply the package-ABI target in the ok-arm (raise in the error arm);
  `ReturnCallImport` = the **existing** import path under `KReturn` (value-correct/bounded-frame, **no**
  `link` change). Threaded builds thread `cur` into the direct/indirect tail apply (callee threads its own
  state). The **loop tail-`apply` back-edge is untouched** (invariant §8). Owns the tail-position +
  constant-stack + package-shape emit tests. Funcref-bearing modules become result-identical (Q13-05's
  consequence to prove).
- **Q13-06 (capstone):** proves the acceptance table — `return_call.wast` / `return_call_indirect.wast`
  green, the constant-stack corpus program (direct + indirect deep tail recursion; imported is
  value-correct with bounded caller frames, not a cross-module constant-stack claim), the two EH
  unblocks (`legacy/try_catch.wast` + `legacy/try_delegate.wast`), the corpus-wide differential, the SVG
  regen. **Left to the capstone** (overview open seams #3/#4): whether the constant-stack **indirect**
  proof needs a dedicated bounded-recursion `.wast` fixture (deep self-recursion through a table slot),
  and whether multi-table tail dispatch needs an authored backstop. The `call_indirect_lookup` seam +
  its package-shape / guard-order guards are **Q13-05's** (not the keystone's), so those remaining items
  are pure test-authoring choices, not seam risks.
