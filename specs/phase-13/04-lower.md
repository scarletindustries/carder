# Q13-04 — The tail-call bottom-transfer lowering (`lower.gleam`)

> **Status:** scoped, awaiting build. **Owner:** Q13-04 (Wave A, parallel behind `«TC-FROZEN»`).
> **Read order:** [`00-overview.md`](00-overview.md) → the distilled brief
> (`brief-phase13-tailcall.md`) → this doc. **Depends on** `«TC-FROZEN»` (Q13-01). All prior-phase
> decisions and the permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8)
> still hold. This unit **completes** a keystone-reach placeholder in one file — it changes no emitted
> `.beam` for any module that does not use `return_call*` (Q6), and it produces no genuine tail call by
> itself (that is Q13-05's `emit_core`).

---

## §1. Goal

Complete the **real bottom-transfer lowering** of `return_call` (`ast.ReturnCall`) and
`return_call_indirect` (`ast.ReturnCallIndirect`) in `src/twocore/frontend/wasm/lower.gleam`. The
keystone (Q13-01) landed the two `go`-dispatch arms **conservative-sound and dead** (no decoder/WAT path
produces those AST nodes until Q13-02, so the arms are unreachable at freeze time). This unit replaces
those placeholder arm bodies with the two real lowering functions, each following the **`Return` shape**,
so that Q13-05's `emit_core` has the three bottom-transfer IR nodes to emit genuine tail calls from.

**Implements:**
- **Q4 (primary)** — lowering follows the **`Return` shape, not the `Call` shape**: build the
  bottom-transfer node → `consume_dead` the rest of the block → `end_or_else`; **no** `wrap_let`, **no**
  recursion into a live continuation (the continuation is dead by spec).
- **Q1 (partial)** — emit the three `Value`-only bottom-transfer IR nodes with the correct
  import-vs-defined split (direct / imported) and the indirect split, so the `emit_core` seam (Q13-05)
  and `rt_table` lookup (Q13-01) receive well-formed nodes. Lower carries **no funcidx and no `apply`**
  for the indirect case — the build-controlled dispatch stays the runtime's job (D3a).
- **Q6** — byte-identical by default: the new arms are reached only when the two opcodes are present.
- **Q8** — honest scope: only the two instructions; no new trap, no optimizer/tier/state-strategy change.

---

## §2. Depends on / Completes (behind `«TC-FROZEN»`)

**Frozen upstream (read-only — do not re-derive):**
- `src/twocore/frontend/wasm/ast.gleam` (Q2): `ReturnCall(func: Int)` and
  `ReturnCallIndirect(type_idx: Int, table: Int)` — immediates identical to `Call` / `CallIndirect`,
  field naming anti-swap.
- `src/twocore/ir.gleam` (Q1): the three bottom-transfer nodes, siblings of `Return` (`ir.gleam:692-701`),
  each carrying **only `Value` operands** (leaves in every traversal):
  ```gleam
  ReturnCall(fn_name: String, args: List(Value))
  ReturnCallIndirect(table: String, index: Value, ty: FuncType, args: List(Value))
  ReturnCallImport(slot: Int, ty: FuncType, args: List(Value))
  ```
  (These mirror `CallDirect` `ir.gleam:660`, `CallIndirect` `:662`, `CallImport` `:760` respectively —
  `ReturnCall`, like `CallDirect`, carries **no** `ty`.)

**What the keystone left for this unit to complete (recorded in `state.md`):** two conservative-sound
placeholder arms in the top-level `go` dispatch (the flat `case instr {}` walk), adjacent to the existing
`ast.Call(f) -> lower_call(f, tail, ctx, st)` arm (`lower.gleam:505`) and the
`ast.CallIndirect(ty, table) -> lower_call_indirect(ty, table, tail, ctx, st)` arm (`lower.gleam:746-747`):

```gleam
ast.ReturnCall(f)                    -> <keystone placeholder — sound & dead>
ast.ReturnCallIndirect(type_idx, table) -> <keystone placeholder — sound & dead>
```

This unit **replaces those two arm bodies** with dispatches to the real lowering functions it introduces
(§3). It overwrites the placeholder bodies wholesale, so it is robust to whatever sound-minimal form the
keystone chose (a fail-closed `Error`, or a delegating node-producer) — the completion boundary is the
arm body, and this is the sanctioned keystone-reach-then-complete split
([`../03-phase-workflow.md`](../03-phase-workflow.md) §3).

**Sibling Wave-A units this unit does NOT touch (D1):** `validate.gleam` (Q13-03 — the typing rule),
`decode.gleam`/`wat.gleam` (Q13-02 — the ingest that first produces these AST nodes), `emit_core.gleam`
(Q13-05 — the real constant-stack tail emission). **Because Q13-03 and Q13-04 run in parallel**, this
unit's tests must **not** route through `validate.validate` (whose `return_call*` arm is still the
keystone placeholder until Q13-03 lands). They construct a hand-built `validate.TypedModule` and call
`lower.lower` directly — the exact idiom the existing `throw_unknown_tag_fails_closed_test`
(`lower_test.gleam:2364-2399`) already uses to test lower in isolation. This keeps Q13-04 green
independently of Q13-03's state.

---

## §3. What it owns + design

**Owned file (D1):** `src/twocore/frontend/wasm/lower.gleam` — the completion of the two keystone-reach
arm bodies plus the two new private lowering functions. **New test module:**
`test/twocore/frontend/wasm/tail_call_lower_test.gleam` (self-contained, with its own small copies of the
`all_exprs` / `func` / direct-`TypedModule` helpers so the unit's suite runs in isolation via
`gleam test -- twocore/frontend/wasm/tail_call_lower_test`, and so it never collides with the keystone's
`tail_call_freeze_test.gleam`).

### 3.1 The dispatch completion

```gleam
ast.ReturnCall(f)                       -> lower_return_call(f, tail, ctx, st)
ast.ReturnCallIndirect(type_idx, table) -> lower_return_call_indirect(type_idx, table, tail, ctx, st)
```

### 3.2 `lower_return_call` — the direct / imported bottom transfer

**Template = the `Return`/`throw` bottom-transfer arm** (`lower.gleam:527-535` for `Return`,
`lower.gleam:519-523` for `Br`, `lower_throw` `:2104-2120`) — **not** `lower_call` (`:1366-1397`). The
callee's signature and the import-vs-defined split come from `lower_call` (`:1372`, `:1392-1395`); the
tail *shape* comes from `Return`.

```gleam
/// Lower `return_call f` (tail-call proposal, opcode 0x12) as a BOTTOM transfer.
///
/// Per the tail-call proposal, `return_call` replaces the current activation with a call to `f`: it
/// pops `f`'s params, transfers control, and the rest of the block is UNREACHABLE (stack-polymorphic,
/// exactly like `return`). Therefore lower builds a single leaf bottom-transfer node from the top
/// operands and DISCARDS the dead continuation — it does NOT bind result names or recurse into a live
/// tail (there are no result values to bind in the caller; the callee's results become the caller's).
///
/// The callee signature is fetched from `ctx.func_types` (which spans imports ++ defined, so an
/// imported funcidx recovers its signature) — identical to `lower_call`. The import split mirrors
/// `lower_call` (`lower.gleam:1392`):
/// - `f < ctx.imported` (a function import) -> `ir.ReturnCallImport(slot: f, ty, args)`; `slot` is the
///   positional function-import index (= `f`, since imports occupy funcidx `0 .. imported-1`); `ty` is
///   the import's IR signature (`ir_functype(sig)`). emit_core (Q13-05) tail-applies the linker-built
///   `link.call_import` capability under `KReturn` (never a name lookup — D3a).
/// - `f >= ctx.imported` (a same-module function) -> `ir.ReturnCall("f<f>", args)`.
///
/// - `tail`: the instructions AFTER this `return_call` within the current frame — dead code, consumed
///   to the frame's closing marker by `consume_dead`.
/// Returns `Ok(GoResult)` (the transfer node closed on the frame's `end`/`else`). Fail-closed (never a
/// panic): `Error(UnknownFuncIndex(f))` if `f` is out of range, `Error(StackUnderflow)` if the stack
/// lacks the params — both only reachable on an UNVALIDATED module (validate is the real boundary).
fn lower_return_call(
  f: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError)
```

**Algorithm (ordered):**
1. `use sig <- result.try(nth_err(ctx.func_types, f, UnknownFuncIndex(f)))` — as `lower_call:1372`.
2. `let pcount = list.length(sig.params)`.
3. `let args = take_push_order(st.stack, pcount)` — the top `pcount` operands in **push order**
   (deepest-first). **Read without mutating the stack** — the continuation is dead (`take_push_order`
   `:2611`; the same non-mutating read `lower_throw` uses at `:2112`).
4. Guard: `case list.length(args) == pcount { False -> Error(StackUnderflow) True -> … }`.
5. Build the node (import split, mirroring `lower_call:1392-1395`):
   ```gleam
   let node = case f < ctx.imported {
     True  -> ir.ReturnCallImport(f, ir_functype(sig), args)
     False -> ir.ReturnCall("f" <> int.to_string(f), args)
   }
   ```
6. `use #(marker, rest) <- result.try(consume_dead(tail, 0))` — skip the dead tail to the frame's
   closing marker (`consume_dead` `:2676`).
7. `Ok(end_or_else(marker, node, rest, st.counter))` — **counter unadvanced** (no fresh names minted),
   exactly as `Return` (`:534`) / `throw` (`:2117`) pass `st.counter`.

**What is deliberately absent (the `Return`-shape discriminator vs `lower_call`):** no `fresh_n`, no
`result_vars`, no `record_types`, no stack reshaping, no `wrap_let`, and **no** `go(tail, ctx, st2)`
recursion. A `return_call` lowered with the `Call` shape would bind dead result names and splice a live
continuation — the bug this unit's tests (§5.2) exist to catch.

### 3.3 `lower_return_call_indirect` — the indirect bottom transfer

**Template = `lower_call_indirect` (`:1228-1264`) for the type/index/args plumbing, but the `Return`
tail** for the closing (build → `consume_dead` → `end_or_else`).

```gleam
/// Lower `return_call_indirect y x` (tail-call proposal, opcode 0x13) as a BOTTOM transfer.
///
/// Pops the i32 table index (top of stack), then the type's params (push order beneath it), and builds
/// a single leaf `ir.ReturnCallIndirect(table, index, ty, args)`; the dead continuation is discarded.
/// `ty` is the STRUCTURAL expected type `module.types[y]` (the runtime does the per-call type check via
/// the Q13-01 `rt_table` lookup seam — E3/D3a); the table immediate `x` maps to the stable name `t<x>`
/// (`tname`). Lower carries NO funcidx and NO `apply` — dispatch is the runtime's job, exactly as for
/// non-tail `call_indirect`. The 3 ordered traps (undefined element -> uninitialized element -> type
/// mismatch) are preserved by emit_core + rt_table (Q13-05/Q13-01), NOT here.
///
/// - `tail`: dead code after this instruction — consumed to the frame's closing marker.
/// Returns `Ok(GoResult)`. Fail-closed: `Error(UnknownTypeIndex(y))` if `y` is out of range,
/// `Error(StackUnderflow)` if the stack lacks the index/params — both only reachable on an UNVALIDATED
/// module.
fn lower_return_call_indirect(
  type_idx: Int,
  table: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError)
```

**Algorithm (ordered):**
1. `use sig <- result.try(nth_err(ctx.types, type_idx, UnknownTypeIndex(type_idx)))` — `ctx.types` is
   `module.types` (`lower.gleam:395`), as `lower_call_indirect:1235`.
2. `let ir_ty = ir.FuncType(list.map(sig.params, to_ir_vt), list.map(sig.results, to_ir_vt))` — mirror
   `lower_call_indirect:1236-1237` (equivalent to `ir_functype(sig)`; keep it identical to the sibling
   for reviewability).
3. `use #(index, stack1) <- result.try(pop1(st.stack))` — the i32 index is the **top** of stack
   (`:1238`).
4. `let pcount = list.length(sig.params)` ; `let args = take_push_order(stack1, pcount)` — params
   **beneath** the index (`:1239-1240`).
5. Guard: `case list.length(args) == pcount { False -> Error(StackUnderflow) True -> … }` (`:1241-1242`).
6. Build `ir.ReturnCallIndirect(tname(table), index, ir_ty, args)`.
7. `use #(marker, rest) <- result.try(consume_dead(tail, 0))` then
   `Ok(end_or_else(marker, node, rest, st.counter))` — **counter unadvanced**, no `wrap_let`, no
   `go(tail, …)` recursion.

---

## §4. The work (ordered, buildable)

1. Replace the two keystone placeholder `go` arms (§3.1) with dispatches to the two new functions.
2. Add `lower_return_call` (§3.2) and `lower_return_call_indirect` (§3.3) with full `///` contract docs
   (what / params / `Ok`-`Error` semantics / failure modes — `UnknownFuncIndex` / `UnknownTypeIndex` /
   `StackUnderflow`, each only reachable on an unvalidated module).
3. `gleam format` → `gleam build` (zero warnings).
4. Write the spec-cited tests (§5) → `gleam test -- twocore/frontend/wasm/tail_call_lower_test`, then the
   full `gleam test`.
5. Confirm **default emission byte-identical**: a module using no `return_call*` never reaches the new
   arms; the existing corpus/conformance suite is unchanged. Record the completed keystone-reach in
   `state.md`.

---

## §5. Tests (`tail_call_lower_test.gleam`) — spec-cited + adversarial

**Spec basis (write against this, not against emitted text):** the WebAssembly tail-call proposal —
`return_call` / `return_call_indirect` **replace the current call frame** with a call to the callee, are
**stack-polymorphic** (the rest of the block is unreachable, like `return`), and `return_call_indirect`'s
traps are identical to `call_indirect`. So `lower` must (a) produce the correct **leaf bottom-transfer
node**, (b) **drop the dead continuation**, (c) split **import vs defined** correctly, and (d) route the
indirect case through the **structural type + index value only** (D3a — no funcidx, no `apply`).

**Harness (per test):** build a `validate.TypedModule` directly (bypassing `validate.validate`, per §2)
and call `lower.lower`; inspect the target function's body with local `all_exprs` + `func` copies
(the new nodes are leaves — `all_exprs`'s default arm keeps them, so a membership check over
`all_exprs(func(irm, "fN").body)` finds the bottom-transfer node). `TypedModule` field notes shared by
the fixtures: `func_locals` is `params ++ declared` per **defined** function (indexed by `defined_idx`),
so a single-`i32`-param, zero-declared function has `func_locals` entry `[ast.I32]`; `func_types` is
indexed by **absolute funcidx** (imports first); `table_types` is **unused** by indirect lowering, so `[]`
is fine (lower reads only `ctx.types` + the popped index). Params lower to `p0, p1, …`.

1. **Direct self tail call -> exact node.** `f0 : (i32) -> (i32)`, `imported_func_count: 0`, body
   `[LocalGet(0), ReturnCall(0), End]`. Assert `all_exprs(func(irm, "f0").body)` **contains**
   `ir.ReturnCall("f0", [ir.Var("p0")])` — funcidx 0 is not `< 0`, so the defined arm fires; args are the
   single param.

2. **Dead continuation dropped — the `Return`-shape discriminator (Q4, the load-bearing test).** Body
   `[LocalGet(0), ReturnCall(0), I32Const(999), LocalGet(0), End]`. Assert:
   - `ir.ReturnCall("f0", [ir.Var("p0")])` **is present**;
   - **no** `ir.ConstI32(999)` appears anywhere in `f0.body` (`consume_dead` skipped the dead tail);
   - **no** `ir.CallDirect("f0", _)` and **no** `ir.Let(_, ir.CallDirect(_, _), _)` appears (i.e. the
     `Call` shape — bind results + splice a live continuation — was **not** used).
   This is the single test that objectively distinguishes the mandated `Return` shape from the wrong
   `Call` shape.

3. **Import split — imported callee -> `ReturnCallImport`.** `imported_func_count: 2`; imports at funcidx
   `0,1` (`ImportFunc`, both `(i32) -> (i32)`); defined `f2` (funcidx 2) body
   `[LocalGet(0), ReturnCall(0), End]`; `func_types = [t0, t1, t2, t3]` (all `(i32) -> (i32)`). Assert
   `func(irm, "f2").body` contains
   `ir.ReturnCallImport(0, ir.FuncType([ir.TI32], [ir.TI32]), [ir.Var("p0")])` (slot = the import's
   positional index; `ty` = the import's IR signature) and **no** `ir.ReturnCall("f0", _)`.

4. **Import split — defined callee -> `ReturnCall("f<idx>")`.** Same module, defined `f3` (funcidx 3)
   body `[LocalGet(0), ReturnCall(2), End]`. Assert `func(irm, "f3").body` contains
   `ir.ReturnCall("f2", [ir.Var("p0")])` (funcidx 2 ≥ `imported` = 2 -> defined arm, name `"f2"`) and
   **no** `ir.ReturnCallImport(...)`.

5. **Indirect -> exact `ReturnCallIndirect` node.** `f0 : (i32) -> (i32)`, `module.types = [(i32)->(i32)]`,
   `func_types = [(i32)->(i32)]`, body `[LocalGet(0), I32Const(7), ReturnCallIndirect(0, 0), End]`. Assert
   `func(irm, "f0").body` contains
   `ir.ReturnCallIndirect("t0", ir.ConstI32(7), ir.FuncType([ir.TI32], [ir.TI32]), [ir.Var("p0")])` —
   proving: table name `"t0"` (`tname(0)`); the popped **index** is the top-of-stack value `7`; the
   **args** are the params beneath it; the `ty` is the **structural** `module.types[0]`.

6. **Indirect dead continuation dropped + no `Call` shape.** Body
   `[LocalGet(0), I32Const(7), ReturnCallIndirect(0, 0), I32Const(999), End]`. Assert the
   `ReturnCallIndirect` is present, **no** `ir.ConstI32(999)`, and **no** `ir.CallIndirect(...)` /
   `ir.Let(_, ir.CallIndirect(_, _, _, _), _)` (the `Call` shape was not used).

7. **Multi-arg operand order (anti-swap).** `f0 : (i32, i32) -> (i32, i32)`, body
   `[LocalGet(0), LocalGet(1), ReturnCall(0), End]`. Assert `ir.ReturnCall("f0", [ir.Var("p0"),
   ir.Var("p1")])` — args in push order (deepest-first), same ordering guarantee `take_push_order` gives
   `lower_call`. (Multi-result carries no extra lower obligation — results are the callee's, never bound
   here.)

8. **Adversarial fail-closed — unknown funcidx.** A hand-built `TypedModule` whose `return_call` targets
   a funcidx beyond `func_types` (e.g. `ReturnCall(9)` with a length-1 `func_types`). Assert
   `lower.lower(tm) == Error(lower.UnknownFuncIndex(9))` — fail closed, never a panic (mirrors
   `throw_unknown_tag_fails_closed_test`; only reachable on an unvalidated module).

9. **Adversarial fail-closed — unknown typeidx (indirect).** `ReturnCallIndirect(9, 0)` with a length-1
   `module.types`. Assert `Error(lower.UnknownTypeIndex(9))`.

10. **Adversarial fail-closed — stack underflow.** (a) `ReturnCall` of a callee needing 2 params with
    only 1 operand on the stack -> `Error(lower.StackUnderflow)`. (b) indirect twin: index present but
    the params short beneath it -> `Error(lower.StackUnderflow)`.

11. **Byte-identical default (Q6, local invariant).** Lower a plain module with **no** `return_call*`
    (e.g. `one_func_module`-style `(i32,i32)->(i32)` add) and assert `all_module_exprs` contains **none**
    of `ir.ReturnCall`, `ir.ReturnCallIndirect`, `ir.ReturnCallImport` — encoding that the new arms are
    dead unless the opcode is used. (The whole-corpus/conformance byte-identity proof is Q13-06's.)

> **Not this unit's tests (handoff):** the **result-type-equality rejection** (`assert_invalid` when the
> callee's results differ from the current function's results) and the stack-polymorphism marking are the
> **validation** rule — Q13-03 owns those `assert_invalid` must-reject fixtures. Lower **assumes a
> validated module** and never re-checks types; its only "must-reject" surface is the structural
> fail-closed insurance in tests 8–10.

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. Spec-cited tests (§5) green — including the dead-continuation `Return`-shape discriminator (§5.2/§5.6)
   and the three fail-closed adversarial cases (§5.8–5.10).
2. `///` contract docs on both new functions (what / param meaning / `Ok`-`Error` semantics / the
   fail-closed `UnknownFuncIndex` / `UnknownTypeIndex` / `StackUnderflow` failure modes, each noted as
   only reachable on an unvalidated module).
3. `gleam format --check src test` clean.
4. `gleam build` zero warnings.
5. The unit suite passes (`gleam test -- twocore/frontend/wasm/tail_call_lower_test`) and the **full**
   `gleam test` stays green; **default emission byte-identical** — a no-`return_call*` module reaches
   none of the new arms and produces none of the three nodes (§5.11), and the existing
   corpus/conformance suite is unchanged.
6. `state.md` updated: the keystone-reach arm bodies in `lower.gleam` are now **completed** by Q13-04.

---

## §7. What it leaves (handoff to downstream)

- **Q13-03 (validate):** the real tail-call **typing rule** — pop the callee's params (and, for indirect,
  the `FuncRef` table check + `pop_expect(I32)`), **require `sig.results == list.last(st.ctrls).end_types`
  else `TypeMismatch`**, then `mark_unreachable` (stack-polymorphic like `return`) — plus the
  `assert_invalid` must-reject fixtures. Lower produces no typing diagnostic and re-checks nothing.
- **Q13-05 (emit_core):** the **real constant-stack tail emission** for the three nodes this unit
  produces — `ReturnCall` via the direct-call path forced under `KReturn`; `ReturnCallIndirect` via the
  Q13-01 `rt_table.call_indirect_lookup` seam applied **in tail position** of the ok-arm
  (`case Lookup of {ok,T} -> apply T(Args) ; {error,E} -> raise(E) end`); `ReturnCallImport` via
  `link.call_import` tail-applied under `KReturn`. Lower only *shapes* the nodes; the "is it actually a
  tail call" (constant-stack) proof is emit_core's + the capstone's.
- **Q13-02 (decode/wat):** first produces `ast.ReturnCall` / `ast.ReturnCallIndirect` from bytes/text.
  Until it lands, the new `go` arms are exercised **only** by this unit's hand-built ASTs; once it lands,
  the full `decode -> validate -> lower` path flows through these arms.
- **Q13-06 (capstone):** the official `return_call.wast` / `return_call_indirect.wast` green, the
  constant-stack corpus program, the EH unblock, and the `(mode × state_strategy × mem_tier)`
  differential.
