# Unit 06 — `emit_core` extension (lower the EH IR → BEAM-native exceptions: `throw`/`try_table`/`throw_ref` → Core Erlang `try…catch`/`raise`)

> **One owner. The deepest single-owner codegen change of Phase 7 — the keystone-adjacent critical
> path.** Depends on **FREEZES ONLY** — `«EH-IR-FROZEN»` (the `Module.tags`/`TagDecl` surface, the
> `Throw`/`TryTable`/`ThrowRef` `Expr` nodes + the `CatchClause` shape, the `exnref` reference-layer
> value/`TExnRef` ValType, the **`CTry` Core-AST node** in `core_erlang.gleam` + its printer arm, and —
> expected — **no new `TrapReason`**), `«RT-EXN-SIG»` (the `rt_exn.gleam` heads, doc-frozen,
> `todo`-free — `throw`/`t_throw`, `rethrow`, `capture`, `throw_ref`), and `«PORFFOR-ABI»` (the
> `(f64,i32)` value ABI — a tag's operand payload is a value list, not an IR node), all from the
> keystone (unit 01). You emit the seam **calls** against the frozen `rt_exn` heads; the `rt_exn`
> **bodies** (the actual `erlang:throw`/`erlang:raise`/`exnref` boxing) are unit 07. Do **not**
> serialize behind it — start the day the freezes land. Read [`00-overview.md`](00-overview.md)
> (J1–J8) and [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md) first, then the Phase-6
> [`RECONCILIATION.md`](../phase-6/RECONCILIATION.md) (S1–S15 still hold) and the corresponding
> Phase-6 unit [`../phase-6/06-emit-core.md`](../phase-6/06-emit-core.md), whose structure/depth this
> doc matches. Analog seam patterns already in `emit_core.gleam`:
> `Trap → rt_trap:raise` (`raise_trap`, `emit_core.gleam:1685`); the trapping `case`-and-`raise`
> disposition (`emit_trapping_result`, `:1566`); the block/label/join machinery
> (`emit_block`/`materialize`/`emit_break`, `:3407`/`:1452`/`:3503`); the threaded record-rebind
> (`emit_threaded_record_effect`, `:1271`); the state channel (`StateChan`, `:239`) and the
> state-reaching closure (`state_reaching_closure`/`expr_touches_state`, `:713`/`:763`).

---

## Context

`emit_core` is the backend and the **binding chokepoint** (D3b): it walks an `ir.Module` and produces
a `core_erlang.CModule`, resolving **every** runtime reference through **one** helper,
`seam_call(module, fn_name, args) -> CExpr` (`emit_core.gleam:1550`), which emits
`call '<module>':'<fn_name>'(args)` with `module` a fixed build-controlled runtime atom and `fn_name` a
literal (D3a — no ambient authority, no data-driven `apply(Mod, …)`). Phases 2–6 routed every stateful
op, every trap (`raise_trap → rt_trap:raise`), the cross-module dispatch (`link:call_import`), and the
generated `instantiate/{0,1}` through that helper, under **two** state strategies — the tier-O `cell`
pdict (`NoState`) and the tier-P `threaded` `rt_state.InstanceState` record (`Threading(cur)`), keyed
on `binding.state_strategy` with the `StateChan` and the state-reaching call-graph closure.

The **trap chokepoint** is the template Phase 7 climbs one level. A WASM `Trap(reason)` already lowers
to `call '<trap_module>':'raise'(Reason)` (`raise_trap`, `:1685`) — a BEAM-native `erlang:error/1`
raising the catchable **`{wasm_trap, Kind}`** error term (`rt_trap.gleam`). Phase 7's exception handling
is **the same idea, made bidirectional**: a WASM `(tag)` + `throw` becomes a BEAM-native `raise` of a
build-controlled **`{wasm_exn, TagId, Payload}`** term through the `rt_exn` chokepoint, and a
`try_table` becomes a BEAM-native **`try … catch`** that matches the tag, binds the payload, transfers
to the catch label, and **re-raises** a non-matching exception. This is the platform thesis
(compile-to-Erlang gives us the BEAM machinery for free — like tail calls → BEAM tail calls,
preemption → the scheduler, traps → `erlang:error`) applied to structured exceptions (J1/J7).

Phase 7 grows the IR for the fourth time since Phase 2 (J6). Concretely this unit consumes the new EH
IR surface (J2, frozen by P7-01 as `«EH-IR-FROZEN»`):

- **`Module.tags: List(TagDecl)`** — each tag is a name + a `FuncType`-shaped operand signature (the
  types the exception carries; for Porffor, `params: [TF64, TI32]`, `results: []` — the measured
  `(tag (param f64 i32))`, §Porffor). No `emit_core` op consumes `Module.tags` directly except to
  render each *defined* tag's identity term (§B.3) — it is otherwise a validate/lower concern.
- **`Throw(tag: Int, args: List(Value))`** — throw exception `tag` (a tag index) carrying `args`. Does
  **not** return (bottom, like `Return`/`Trap`).
- **`TryTable(result: List(ValType), body: Expr, catches: List(CatchClause))`** — evaluate `body`; on a
  thrown exception whose tag matches a `catch` clause, transfer to the clause's `label` with the payload
  (and the exnref if the clause is a `_ref` variant); an unmatched exception propagates. **Structured**
  (named labels, D6): the catch `label`s are enclosing block labels reached through the existing
  label/join machinery. `CatchClause = Catch(tag: Int, label: String, ref: Bool) | CatchAll(label:
  String, ref: Bool)`.
- **`ThrowRef(exnref: Value)`** — re-raise a caught exception reference; **`exnref`** is a new
  reference-layer value (`TExnRef` ValType), a caught-exception handle, opaque like `externref` (§E).

Growing `Expr`/`ValType` breaks every exhaustive match in this file. The keystone lands a minimal
compile-satisfying arm so the tree stays green; **this unit fills the real lowering** — through the
`rt_exn` seam, under **both** state strategies, and **byte-identically** for a **tag-free** module
(J6 — a module with no `Module.tags` decodes/validates/lowers/emits bit-for-bit as Phase 6).

### Why the neutral IR makes this unit surface-agnostic (a measured note)

The task and overview specify the **modern** exception-handling proposal (tag section id `13`,
`throw`=`0x08`, `throw_ref`=`0x0A`, `try_table`=`0x1F` with the four catch-clause kinds `0x00` catch /
`0x01` catch_ref / `0x02` catch_all / `0x03` catch_all_ref, and the `exnref` heap type). **Measured
reality (Porffor 0.61.13, this pin):** Porffor emits the **legacy** proposal — `(tag (param f64 i32))`
(tag section id `13` — `0d`), `try`=`0x06` / `catch`=`0x07` / `throw`=`0x08` (a `(f64, i32)` payload
pushed before `throw 0`), with the tag **exported** (`(export "0" (tag 0))`) and **`return` inside the
try body** (see §Porffor). This surface difference is **entirely absorbed upstream of this unit**: the
decoder (P7-03) reads whichever opcodes the pin emits, and the lowerer (P7-05) maps **both** legacy
`try/catch/catch_all` **and** modern `try_table` onto the **same neutral `TryTable`/`Throw`/`ThrowRef`
IR** (a generic structured-exception model, D6/J2). `emit_core` consumes only the neutral IR, so its
BEAM mapping is **identical regardless of which EH surface the frontend decoded** — the payoff of the
IR-neutrality discipline. This unit cites the modern proposal's *semantics* (which the neutral IR
models); the legacy-vs-modern opcode split is a P7-03/05 concern (flagged §Cross-unit seams).

## Goal

Lower every EH IR node to **BEAM-native exceptions through the `rt_exn` chokepoint** (never a raw
`erlang:*` in generated code, D3a):

1. **`Throw` — the raise chokepoint.** Lower `Throw(tag, args)` to `call
   '<exn_module>':'throw'(TagId, ArgList)` (`Cell`) / `'t_throw'(TagId, ArgList, St)` (`Threaded`) — a
   fixed-atom seam call whose body (`rt_exn`, unit 07) raises the build-controlled **`{wasm_exn, TagId,
   Payload}`** term (`erlang:throw`, throw-class), **never returning** (bottom, like `Trap`). `TagId` is
   a **compile-time-constant** tag identity (§B.3), `Payload = ArgList` the operand value list (the
   `(f64,i32)` pair for a Porffor JS value). No attacker-chosen `apply` (D3a): the term SHAPE is fixed,
   the tag identity is build-controlled.
2. **`TryTable` — the try/catch (the elegant core).** Lower `TryTable(result, body, catches)` to a Core
   Erlang **`try Body of <V> -> V catch <Class,Reason,Stk> -> Handler`** (the new `CTry` node, §G) that:
   (a) runs `Body` (emitted so normal completion / `br`-to-self / `return` flow through the
   **transparent** `of <V> -> V` — §C.1, the packaging invariant makes this sound); (b) on a raise, the
   `Handler` **matches the thrown tag** against each catch clause (a literal-pattern `case Reason of
   {wasm_exn, TagId_k, Payload} -> …`), **extracts the payload** (and the **exnref** for a `_ref`
   clause), and **transfers to the clause's catch label** with those values (`apply_cont` over the
   enclosing label's break-continuation — the existing `emit_break` machinery); (c) **re-raises** a
   non-matching exception via `call '<exn_module>':'rethrow'(Class, Reason, Stk)` — `erlang:raise/3`,
   **preserving the stacktrace** (spec §4.4.9 unwinding).
3. **`ThrowRef` — re-raise a captured exception.** Lower `ThrowRef(exnref)` to `call
   '<exn_module>':'throw_ref'(ExnRef)` — `rt_exn` unboxes the captured `{Class, Reason, Stk}` and
   re-raises it (`erlang:raise/3`). Bottom (never returns).
4. **`exnref` — the forge-proof caught-exception handle.** A `catch_ref`/`catch_all_ref` clause binds an
   `exnref` = `call '<exn_module>':'capture'(Class, Reason, Stk)` (a `{ref_exn, {Class, Reason, Stk}}`
   box, opaque, `rt_ref`-style, §E) and transfers it to the catch label alongside the payload. Safe code
   may hold/pass/re-throw it but cannot forge or inspect the underlying BEAM term (H6).
5. **Both state strategies — the thrown-through record (H6/J5).** Under `Threaded` a `throw` **carries
   the live `InstanceState` record** in the thrown term (`{wasm_exn, TagId, Payload, St}`), and the
   catch handler **extracts** it and continues under `Threading(St)` — so mutations made **before** the
   throw are preserved (WASM has no rollback), and threaded state is **never corrupted** by a throw.
   Under `Cell` the record lives in the pdict (already reflects the mutations), so no record travels in
   the term. Constant-space loops + preemption survive a throw (the BEAM `try/catch` is native, §F).

Every new node must (a) work under **both** `Cell` and `Threaded`, (b) fail closed — a **trap**
(`{wasm_trap, _}`) is **never** caught by a `try_table` (not even `catch_all`); only a WASM **exception**
(`{wasm_exn, _, _}`) is (§Effect), (c) leave a **tag-free** module **byte-identical** to Phase 6 (J6),
and (d) route **all** authority through the `rt_exn` chokepoint with **no** `erlang:*` in generated
code (the homogeneous D3a allow-set, S5). Extend the D3a structural security test to prove the new
authority (the raise, the catch/re-raise, the exnref capture) is ambient-free. Co-design the `rt_exn`
call ABI with 07 (you emit the calls; it implements the bodies against the keystone-frozen sigs).

## Files owned (single-owner-additive)

- `src/twocore/backend/emit_core.gleam` — **EXTEND (single owner).** Add: the `emit` arms for `Throw`,
  `TryTable`, `ThrowRef`; the `emit_throw`/`emit_try_table`/`emit_throw_ref` lowerings; the
  `tag_id_term`/`tag_id_pat` tag-identity renderers (§B.3); the `try_catch_handler` catch-clause
  dispatcher (§C.3); the `exnref` capture/transfer helpers (§E); the `TExnRef` arm of
  `valtype_atom`/`result_width`; and the descents into the three new nodes in `expr_touches_state`,
  `direct_callees`, and `collect_expr` (§A.3). Add a module-level `const exn_module =
  "twocore@runtime@rt_exn"` (matching the `simd_module`/`link_module` precedent) **or** consume
  `binding.exn_module` if the keystone adds the field (§Deviations D2).
- `test/twocore/backend/emit_core_test.gleam` — AST-shape goldens for every new construct (EXTEND).
- `test/twocore/backend/emit_core_security_test.gleam` — the D3a walk over the new authority (EXTEND —
  admit `exn_module` in `runtime_modules`; **extend the `children` walker with a `CTry` arm** so a
  `CCall` inside a try body/handler is reached by the walk — a missed arm is a fail-OPEN hole in the
  *security test itself*; grow the fixture to exercise `Throw`, a multi-clause `TryTable` (`catch` +
  `catch_ref` + `catch_all`), and `ThrowRef`, then assert every `CCall` targets `exn_module` with a
  literal function atom, **no `erlang:*` call is emitted**, every `CApply` is a static local `FName`,
  and the re-raise/capture/throw reach `rt_exn`).
- `test/twocore/backend/emit_core_e2e_test.gleam` — hand-built EH IR → build → `instantiate` → invoke
  (EXTEND; green once 07 lands — see Concurrency).

## Deliverables & freeze milestones

**Consumes:**

| Freeze | From | What you take | Stub against meanwhile |
|---|---|---|---|
| `«EH-IR-FROZEN»` | 01 | `Module.tags: List(TagDecl)` + `TagDecl(name, ty: FuncType)`; `Throw(tag: Int, args)`; `TryTable(result, body, catches)` + `CatchClause = Catch(tag: Int, label: String, ref: Bool) \| CatchAll(label: String, ref: Bool)`; `ThrowRef(exnref: Value)`; the `TExnRef` ValType (+ `ExnRef` reference kind if the null exnref is modelled); **the `CTry(arg, body_vars, body, evars, handler)` Core-AST node in `core_erlang.gleam` + its `core_printer` arm**; **no new `TrapReason`** (a WASM exception is a distinct term class, not a trap — §Effect/S8-analogue). | The keystone's minimal `emit` arm keeps the tree green — replace it with the real lowering. |
| `«RT-EXN-SIG»` | 01 (bodies 07) | The `rt_exn` heads (doc-frozen, `todo`-free), all raising through the ONE build-controlled term shape: `throw(TagId, Payload) -> a` + the threaded twin `t_throw(TagId, Payload, St) -> a` (`erlang:throw({wasm_exn, …})`, never returns); `rethrow(Class, Reason, Stk) -> a` (`erlang:raise/3`, preserves the stacktrace); `capture(Class, Reason, Stk) -> ExnRef` (box `{ref_exn, {Class, Reason, Stk}}`, PURE, forge-proof); `throw_ref(ExnRef) -> a` (unbox + `erlang:raise/3`). | Emit calls against the *signatures*; e2e waits on 07. |
| `«PORFFOR-ABI»` | 01 | The `(f64,i32)` value-ABI convention: a tag's operand `Payload` is a value LIST (the tag's `FuncType.params`) — the emitter renders `args` as a Core list, it does **not** interpret the pair. | Render `args` as a list; the harness decode of a returned/thrown `(f64,i32)` is 08/09. |

**Produces (no downstream freeze; three load-bearing conventions):**

1. the **thrown-term shape** — `{wasm_exn, TagId, Payload}` (`Cell`) / `{wasm_exn, TagId, Payload, St}`
   (`Threaded`), throw-class — which 07 binds `rt_exn`'s `throw`/`t_throw`/`rethrow` to and against which
   the catch handler pattern-matches. **Distinct from the trap term `{wasm_trap, Kind}`** — the
   fail-closed exception/trap boundary (§Effect);
2. the **catch-clause dispatch shape** — a literal-pattern `case Reason of {wasm_exn, TagId_k, Payload}
   -> <transfer to label_k> ; … ; _ -> rethrow end`, with `_ref` clauses inserting an `rt_exn:capture`
   exnref before the label transfer — which 07's `capture`/`throw_ref` bind to;
3. the **compile-time tag-identity term** `tag_id_term(tag, ctx)` — the single place a tag index becomes
   a concrete build-controlled identity term (recommend `{'<module>', <idx>}`, §B.3), used symmetrically
   at the `throw` site (an expression) and the `catch` site (a literal pattern) so the match holds.

**Out of scope (do NOT build here):** the `rt_exn` **bodies** (07 — you emit calls against the frozen
heads); the tag-import/export **link resolution** + the `(f64,i32)` run-ABI decode (08 — the Porffor
host shim + value ABI); the JS-subset harness (09); **decode/validate/lower** of the EH ops (03/04/05 —
you consume the neutral IR, you do not produce it, and you never see legacy-vs-modern opcodes); the
`.ir` grammar delta (02); the `ir/effect.gleam` EH classification (01); the **conformance** expansion +
the residual audit (10). **The `CTry` Core-AST node + its printer arm are the keystone's (01)** — this
unit emits `CTry`, it does not define the type or its print form.

## Depends on (freeze milestones)

Start behind `«EH-IR-FROZEN»` (the IR nodes + the `CTry` Core node) and `«RT-EXN-SIG»` (the `rt_exn`
heads). `«PORFFOR-ABI»` gates only the payload-as-value-list convention (trivial). The three tracks
(`Throw`, `TryTable`, `ThrowRef`) are independent inside this unit — begin with `Throw` (§B, the
smallest, purely-additive surface) the day the freezes land, then `TryTable` (§C, the core), then
`ThrowRef`/`exnref` (§D/§E).

---

## A. The dispatch extension + the traversal/classification closure

### A.1 The three new `emit` arms

The main dispatcher `emit(expr, cont, sc, state, ctx)` (`emit_core.gleam:849`) gains one arm per new
node. `Throw` is a **non-returning transfer** (like `Return`/`Trap`): it ignores `cont` and emits the
raise directly. `TryTable` is a **control barrier** that installs a handler around its body. `ThrowRef`
is a non-returning transfer. Sketch:

```gleam
// ── the raise chokepoint (J1) — bottom, ignores `cont` (like `Trap`/`Return`) ──
ir.Throw(tag, args) -> emit_throw(tag, args, sc, state, ctx)
// ── the try/catch (the elegant core) — a Core `try` around the body ──
ir.TryTable(result, body, catches) ->
  emit_try_table(result, body, catches, cont, sc, state, ctx)
// ── re-raise a captured exnref (J1) — bottom ──
ir.ThrowRef(exnref) -> emit_throw_ref(exnref, ctx, state)
```

Note `Throw`/`ThrowRef` take neither `cont` (they never return) — exactly as `Trap(reason) ->
Ok(#(raise_trap(ctx, …), state))` (`:875`) drops `cont`. `TryTable` takes `cont` (its body's normal
completion + the caught path both dispose through it).

### A.2 `valtype_atom` / `result_width` grow one arm each

- **`valtype_atom`** (`:3649`) gains `ir.TExnRef -> "exnref"` — the canonical type atom, needed only if
  an `exnref` param/result appears in a `call_indirect`/`CallImport` type tag (self-consistent — only
  its use on both sides of the `rt_table` `==` guard matters; Porffor never puts an `exnref` in a
  funcref type).
- **`result_width`** (`:1645`) gains `ir.TExnRef -> 32` for exhaustiveness, documented **unreachable**:
  an `exnref` is a term-layer reference value (like `externref`), never a scalar numeric `MemLoad`
  result — validate rejects `iN.load` into an `exnref`.

`ConstV128` and the reference values already have their `emit_value` arms (P5/P6); an `exnref` flows as
an opaque `Var`, so `emit_value(Var(x)) -> CVar(x)` covers it with **no** new arm (like `externref`).

### A.3 The three traversal functions MUST descend into every new node

Three traversals over `Expr` live in this file and **break** the moment `Expr` grows; the keystone's
minimal arm keeps them compiling but *inert*. This unit gives them the real behavior — getting any one
wrong silently corrupts threaded codegen or gensym uniqueness:

- **`expr_touches_state`** (`:763`) — the state-reaching **seed** test.
  - **`Throw` → `True`.** Under `Threaded` a `throw` **reads and carries the live record** (the
    thrown-through state, §F/§B.2), so a function containing one threads the record. (Under `Cell` this
    is inert — the state is in the pdict.)
  - **`TryTable(_, body, _) → expr_touches_state(body)`** — **recurse into the body** (like
    `Block`/`Loop`/`If`). A `try_table` around a state-touching body is state-reaching (it threads the
    record through the try + must rebind `cur` from the caught term); a `try_table` around a pure body
    that only `throw`s reaches `Throw`'s `True`. (The catch `label`s are `String`s, not sub-exprs.)
  - **`ThrowRef(_) → True`** — it is an effectful barrier that re-raises within a threaded function;
    classify state-reaching for safety (it never reads `cur`, but conservatism is sound and — since any
    module with a `ThrowRef` has tags — it never affects a tag-free module's byte-identity, §Effect).
  - **Byte-identity note (J6):** a **tag-free** module has **none** of these nodes, so its classification
    is unchanged and its arity/threading is bit-for-bit Phase 6.
- **`direct_callees`** (`:819`) — the `CallDirect` edge scan for the state-reaching fixpoint. **None** of
  the new nodes contain a `CallDirect` in an *operand* position (`Throw`/`ThrowRef`'s operands are atomic
  `Value`s). **`TryTable` MUST recurse into `body`** (`direct_callees(body, acc)` — a `CallDirect`
  inside a try body is a real call-graph edge, exactly like `Block`/`Loop`). `Throw`/`ThrowRef` return
  `acc` unchanged — but must be **matched** so the wildcard does not silently swallow a future nested
  body.
- **`collect_expr`** (`:5203`) — the gensym-reservation scan (**exhaustive, no wildcard**). Add:
  `ir.Throw(_, args) -> collect_values(args, acc)`;
  `ir.TryTable(_, body, _) -> collect_expr(body, acc)` (recurse into the body; the catch `label`s are
  IR label names handled by the label machinery, not gensym); `ir.ThrowRef(exnref) ->
  collect_value(exnref, acc)`. A missed `Var` lets a gensym collide with an IR name → a silently wrong
  body.

The `state_reaching_closure` fixpoint (`:713`) is otherwise unchanged: seeding on `Throw`/`ThrowRef` +
the `TryTable`-body recursion and closing over `CallDirect` gives exactly the set of functions that must
thread the record under `Threaded`. A tag-free module stays **pure** (`NoState`), preserving its
Phase-6 arity — the J6 neutrality.

---

## B. `Throw` → the `rt_exn` raise chokepoint (the binding chokepoint, D3a)

A WASM `throw t (vals…)` **creates an exception** with tag `t` carrying `vals…` (the tag's operand
values) and **unwinds** to the nearest matching handler (exception-handling proposal, `throw`=`0x08`;
core-spec §4.4.9). On the BEAM this is a **native raise** of a build-controlled term — the exact analogue
of `Trap → rt_trap:raise` (`:1685`), one class up.

### B.1 The thrown-term shape (`Produces` #1 — the binding chokepoint)

The thrown BEAM term is **`{wasm_exn, TagId, Payload}`**, raised **throw-class** (`erlang:throw`) by
`rt_exn` (unit 07):

- **`wasm_exn`** — a fixed outer tag (a build-controlled atom), the analogue of `rt_trap`'s `wasm_trap`.
  It is what makes a WASM **exception** distinguishable from a WASM **trap** (`{wasm_trap, Kind}`,
  error-class) and from any incidental BEAM error — the load-bearing fail-closed distinction (§Effect):
  a `try_table` catches **only** `{wasm_exn, _, _}`, **never** a trap.
- **`TagId`** — the tag's **build-controlled identity** (§B.3). Never program data (D3a).
- **`Payload`** — the tag's operand values as a Core **list** `[V0, …]` (for Porffor, the `(f64, i32)`
  pair; the emitter renders `args`, never interprets them — `«PORFFOR-ABI»`).

**Class choice — throw, not error (argued).** `rt_exn:throw` raises with **throw** class; `rt_trap:raise`
raises with **error** class. This makes the exception/trap distinction rest on the **BEAM-native class**
(throw ⟺ WASM exception, catchable by `try_table`; error ⟺ trap/host-denial, **not** catchable by
`try_table`), a robust second line of defence behind the `wasm_exn`/`wasm_trap` reason tags. It also
matches Erlang idiom (`throw` is the recoverable non-local exit; `error` is the fault). The catch handler
(§C.3) matches on the reason shape and re-raises with the **captured** class, so both classes round-trip
faithfully.

### B.2 The emitter — `Cell` vs `Threaded` (the thrown-through record, J5)

```gleam
/// Lower `Throw(tag, args)` — a BEAM-native raise of the build-controlled `{wasm_exn, TagId, Payload}`
/// term through the `rt_exn` chokepoint (J1/D3a). Bottom: never returns, so `cont` is dropped (like
/// `Trap`). `Cell`: `call '<exn>':'throw'(TagId, [args…])`. `Threaded`: `call '<exn>':'t_throw'(TagId,
/// [args…], St)` — the LIVE record travels in the thrown term so the catcher recovers the
/// mutated-before-throw state (§F). `TagId` is the compile-time tag identity (§B.3); the payload is the
/// operand value LIST (never interpreted — the (f64,i32) pair rides opaquely, «PORFFOR-ABI»).
fn emit_throw(tag, args, sc, state, ctx) -> Result(#(CExpr, EmitState), EmitError) {
  let payload = core_list(list.map(args, emit_value))
  let call = case sc {
    NoState -> seam_call(exn_module, "throw", [tag_id_term(tag, ctx), payload])
    Threading(cur) ->
      seam_call(exn_module, "t_throw", [tag_id_term(tag, ctx), payload, CVar(cur)])
  }
  Ok(#(call, state))
}
```

Worked example, `Throw(0, [Var("v"), ConstI32(195)])` (Porffor's `throw 0` with the `(f64, i32)` payload
`(v, 195)`) under `Cell`:

```erlang
%% the whole expr is the raise (bottom) — no `case`, no continuation:
call 'twocore@runtime@rt_exn':'throw'({'m', 0}, [v, 195])
```

and under `Threaded` (the function is at arity `n+1`, `st` its live record):

```erlang
call 'twocore@runtime@rt_exn':'t_throw'({'m', 0}, [v, 195], st)
```

`rt_exn:throw({'m',0}, P)` runs `erlang:throw({wasm_exn, {'m',0}, P})`; `t_throw` runs
`erlang:throw({wasm_exn, {'m',0}, P, St})` (07). Both diverge (bottom) — typed `-> a` so the emitter may
place the call in any value position, exactly like `rt_trap:raise`.

### B.3 `tag_id_term` — the compile-time tag identity (`Produces` #3)

A tag has **identity** in WASM EH: `catch $t` matches an exception iff the exception's tag is the **same
tag** the throw used (not merely a structurally-equal type). This unit renders that identity **once**,
used symmetrically at the raise (an expression) and the catch (a literal pattern):

```gleam
/// The build-controlled runtime identity of DEFINED tag `tag` (an index into `module.tags`). Rendered
/// symmetrically as an EXPRESSION (the `throw` payload) and a PATTERN (`tag_id_pat`, the `catch` match),
/// so `throw t` and `catch t` agree structurally. Recommend a per-MODULE-unique COMPILE-TIME CONSTANT
/// `{'<module>', <idx>}` (module-name atom + local tag index): a constant ⇒ `Throw`/`TryTable` need no
/// state read for identity (only the threaded `cur` travels, §B.2), the catch match is a literal
/// pattern (no guard), and two DIFFERENT modules never collide (distinct module atoms).
fn tag_id_term(tag: Int, ctx: Ctx) -> CExpr {
  CTuple([CAtom(ctx.module_name), CInt(tag)])
}
fn tag_id_pat(tag: Int, ctx: Ctx) -> CPat {
  PTuple([PAtom(ctx.module_name), PInt(tag)])
}
```

*(`Ctx` gains a `module_name: String` field — a one-line keystone-adjacent addition this unit needs;
`emit_module` already has `module.name` in scope, §Cross-unit seams.)* The identity representation is a
**cross-unit seam** the keystone owns (P7-01/P7-07); the recommendation above is the emitter's ask.
Alternatives + their trade-offs are argued in §Deviations D3 (a bare `CInt(tag)` — simplest, but
collides across *any* two instances; an **instance-unique** identity minted at instantiation and read
`rt_state:tag_at(idx)` — fully correct across re-instantiation + cross-module, but makes `Throw`/`catch`
**state-reaching** and the match a guard, not a pattern). The compile-time `{module, idx}` is
recommended as the sound-for-the-measured-scope default (Porffor is single-module-single-instance,
§Porffor). **An imported tag** resolves its identity to the **exporter's** term through the link slot
(a seam, §Cross-unit seams) — out of Porffor's measured scope (Porffor exports its tag but nothing
imports it, §Porffor).

---

## C. `TryTable` → Core Erlang `try … catch` (the elegant core)

`try_table bt catch* body` (modern; `0x1F`) — equivalently legacy `try bt body catch* end`
(`0x06`/`0x07`, what Porffor emits) — **installs exception handlers** for the dynamic extent of `body`.
On normal completion it yields the block type's `result` values; on a thrown exception it matches the
tag against the clauses **in order** and either transfers to the matching clause's label (with the
payload, + exnref for a `_ref` clause) or propagates (spec §4.4.9). On the BEAM this is a **native `try …
catch`** — the platform thesis applied to structured exceptions.

### C.1 The transparent-`try` encoding — sound because every emitted expr is ONE packaged value

The subtle part: a `try_table` body may `return` from the function, `br` to an **enclosing** block, or
`continue` an enclosing loop — and these must exit the try **without** triggering the catch (only a
`throw` triggers it). In the CPS/ANF emitter these transfers compile to **tail-calls / return-package
values** through the existing continuation + label machinery. The key invariant that makes wrapping the
body in a Core `try` **sound**: **every `emit(…)` result is a SINGLE Core value** — a `function_return`
package (`'ok'` / the bare value / an N-tuple, `:3609`), a `{Package, cur}` threaded pair (`:989`), or a
tail `apply` that returns one such value. Therefore the body reduces to **one** value on every control
path, and the try's success clause is the **transparent identity** `of <V> -> V`:

```gleam
/// Lower `TryTable(result, body, catches)` to a BEAM-native `try … catch` (J1). `body` is emitted under
/// the (materialised) OUTER continuation, so its normal completion / `br`-to-self / `return` dispose
/// through `cont` AS TODAY and the `of <V> -> V` clause is a TRANSPARENT pass-through (sound because
/// every emitted expr is one packaged value — §C.1). The `catch <Class,Reason,Stk>` handler matches the
/// thrown tag against `catches`, transfers to the matching catch label (payload + exnref), and re-raises
/// a non-match (§C.3). The catch `label`s are ENCLOSING block labels resolved through the existing label
/// stack (no new label pushed — P7-05 wraps the try_table's own block label in a `Block`, §C.2).
fn emit_try_table(result, body, catches, cont, sc, state, ctx) {
  use #(join, exit_cont, s1) <- result.try(materialize(cont, list.length(result), sc, state, ctx))
  use #(body_c, s2) <- result.try(emit(body, exit_cont, sc, s1, ctx))
  let #(v, s3) = fresh_var(s2)                         // the transparent success binder
  use #(handler, s4) <- result.try(try_catch_handler(catches, sc, s3, ctx))  // §C.3
  let ctry = CTry(arg: body_c, body_vars: [v], body: CVar(v), evars: handler.evars, handler: handler.body)
  Ok(#(wrap_join(join, ctry), s4))
}
```

The Core shape (`Cell`, a `catch $t0 $L0` + a `catch_all $La`, outer cont trivial):

```erlang
try
  <body_c>                         %% normal completion / return / br-to-self flow through `of` unchanged
of <v> -> v                        %% TRANSPARENT: the body already disposed through `cont`
catch <c, r, s> ->
  case r of
    <{'wasm_exn', {'m', 0}, p}> when 'true' ->        %% catch $t0 → L0, payload `p`
      <bind payload from p, transfer to L0 with it>
    <{'wasm_exn', _tag, _p}> when 'true' ->           %% catch_all → La (any wasm_exn tag)
      <transfer to La with no payload>
    <_other> when 'true' ->
      call 'twocore@runtime@rt_exn':'rethrow'(c, r, s) %% no clause matched (or a trap) → propagate
  end
```

**Why transparent `of` is correct — the four control paths:**

- **Normal completion / `br`-to-self / `return`** → `body_c` reduces to its single packaged value V →
  `of <v> -> v` returns V unchanged → V is the try_table expression's value → flows to `cont`
  **exactly as a plain `Block` would**. `return` is a function exit (nothing runs after it inside the
  try), so it is **always** correct.
- **`throw`** → `body_c` raises → `catch <c,r,s>` runs the handler (§C.3). ✓
- **`br`/`continue` to an ENCLOSING label** → `body_c` tail-calls the enclosing join. Because a Core
  `try`'s `Arg` is not tail-transparent, that join runs while the try frame is dynamically active. For
  the overwhelming majority of programs (and **all** of Porffor's measured output + the JS corpus) this
  is observationally identical to WASM; the ONE spec-corner where it differs — a `br`/`continue` out of
  a `try_table` **followed by a re-`throw` of the same still-installed tag** — is flagged in §Deviations
  D1 with a measured escalation path (the tagged-exit trampoline) and an honest-scope categorisation
  (J8). It does **not** affect `return`, normal completion, or any caught/propagated `throw`.

### C.2 The try_table's own block label — P7-05 wraps it in a `Block`

`try_table bt … end` is **also a block**: `br 0` targets its `end` and fall-through yields `bt`'s
results. `emit_try_table` does **not** model this self-label — **P7-05 (lower) wraps the `TryTable` in a
`Block($self, result, TryTable(result, body', catches))`**, so `br`-to-self / fall-through is the
enclosing `Block`'s job (the existing byte-identical block machinery) and `TryTable` is *purely* the
handler installation. This keeps `TryTable` minimal and the emitter free of a bespoke self-label push.
*(Flagged §Cross-unit seams — P7-05 owns the wrap; this unit assumes it.)*

### C.3 The catch-clause dispatcher (`Produces` #2) — match, extract, transfer, re-raise

The handler is a `case Reason of …` with **one clause per catch clause** (in order), then a final
**re-raise** default. Each clause is a **literal pattern** on the compile-time tag identity (`tag_id_pat`,
§B.3), so no guard is needed:

```gleam
/// Build the `catch <Class,Reason,Stk> -> case Reason of … end` handler for a `try_table`'s clauses.
/// One `case` clause per catch clause (order-preserving); a final `_ -> rethrow(C,R,S)` propagates a
/// non-match (a wrong tag, or ANY trap `{wasm_trap,_}` — a trap is never caught, §Effect). Under
/// `Threaded` the payload pattern also binds the thrown-through record `St` and the transfer continues
/// under `Threading(St)` (§F). A `_ref` clause inserts an `rt_exn:capture(C,R,S)` exnref before the
/// label transfer (§E).
fn try_catch_handler(catches, sc, state, ctx) { … }
```

| `CatchClause` | thrown-`Reason` pattern (`Cell`) | transfer to `label` carries | Core (Cell) |
|---|---|---|---|
| `Catch(t, L, ref: False)` | `{wasm_exn, tag_id_pat(t), P}` | the payload values (unpacked from `P`) | `apply_cont(find_label(L).break_cont, payload)` |
| `Catch(t, L, ref: True)` | `{wasm_exn, tag_id_pat(t), P}` | payload **++ [exnref]** | capture exnref, then `apply_cont(…, payload ++ [exnref])` |
| `CatchAll(L, ref: False)` | `{wasm_exn, _, _}` | **no** payload | `apply_cont(find_label(L).break_cont, [])` |
| `CatchAll(L, ref: True)` | `{wasm_exn, _, _}` | **[exnref]** only | capture exnref, then `apply_cont(…, [exnref])` |
| *(implicit last)* | `_` | — (propagate) | `call '<exn>':'rethrow'(c, r, s)` |

**Payload unpacking.** `P` is the operand value **list**; a `Catch(t, L, ref)` binds it to a fresh var
and unpacks into the tag's operand arity (`len(tagtype.params)`) via the existing `unpack_result_list`
(`:2580`) — the same list-destructure `CallIndirect`/`CallImport` use — then transfers those values (+
the exnref if `ref`) to `L`. For Porffor's `(f64,i32)` tag, the payload unpacks to **two** values (the
JS value + its type tag), which a `catch $t $L` delivers to `$L`'s two block params.

**The transfer to the catch label** reuses `emit_break`'s core exactly: `apply_cont(find_label(L).
break_cont, transfer_values, sc', state, ctx)`. The catch `label`s are **enclosing** block labels (from
the `Block` P7-05 wrapped, and outer blocks), already on the label stack with materialised
break-continuations — so a caught exception **branches to the right structured target with the payload**,
in constant stack (the branch is a tail `apply`, §F). `find_label` returning `Error(UnboundLabel)` for a
catch label the lowerer produced out of scope is a fail-closed `EmitError` (never a panic).

**The re-raise default** — `call '<exn_module>':'rethrow'(c, r, s)` → `rt_exn:rethrow` runs
`erlang:raise(Class, Reason, Stacktrace)` (07), **preserving the stacktrace** `s` bound by the `try`'s
third exception variable (modern OTP Core Erlang binds the stacktrace directly as the third `evar` — no
`get_stacktrace/0`). This fires for a **non-matching tag** AND for a **trap** (`{wasm_trap, Kind}` never
matches `{wasm_exn, …}`) AND for any incidental BEAM error — so a trap propagates through a `try_table`
uncaught (even past a `catch_all`), which is exactly the WASM rule that traps are not catchable by
exception handlers. **All handler clauses yield one value** (a transfer `apply`, or the bottom
`rethrow`), so the `case` is arity-consistent in any surrounding context (the `emit_trapping_result`
invariant, `:1560`).

---

## D. `ThrowRef` → re-raise a captured `exnref`

`throw_ref` (`0x0A`) re-raises a previously-caught exception (its `exnref`). On the BEAM this is trivial —
the `exnref` box already holds the original `{Class, Reason, Stk}` (§E), so `rt_exn` unboxes and
`erlang:raise`s it:

```gleam
/// Lower `ThrowRef(exnref)` — re-raise the exception captured in `exnref` (J1). Bottom (never returns),
/// so `cont` is dropped. `rt_exn:throw_ref` unboxes `{ref_exn, {Class, Reason, Stk}}` and re-raises via
/// `erlang:raise/3` (07), preserving the ORIGINAL class/reason/stacktrace. State-neutral at the emit
/// site (the record was already carried in `Reason` at the original throw, §F).
fn emit_throw_ref(exnref, ctx, state) {
  Ok(#(seam_call(exn_module, "throw_ref", [emit_value(exnref)]), state))
}
```

```erlang
%% ThrowRef(Var("ex")) →
call 'twocore@runtime@rt_exn':'throw_ref'(ex)
```

`throw_ref` on a **null** exnref traps (`ref.null exn` re-thrown → a trap per the proposal); `rt_exn`
owns that check (07 — an unboxable/null exnref → `erlang:error({wasm_trap, …})`, reusing an existing
`TrapReason`; no new variant, §Effect). `ThrowRef` is state-neutral at the emit site under both
strategies: it re-raises a value; the record travels inside the captured `Reason` (§F).

---

## E. `exnref` — the forge-proof caught-exception handle (`rt_ref`-style)

`exnref` is a **term-layer reference value** (J2), the caught-exception handle a `catch_ref` /
`catch_all_ref` clause pushes and `throw_ref` consumes. It reuses the **forge-proof** discipline of
`rt_ref` (R1) — a reserved box no Safe op can construct:

- **Representation** — `{ref_exn, {Class, Reason, Stk}}` (a reserved 2-tuple, owned by `rt_exn`).
  Uncollidable with the `rt_ref` shapes (`{ref_null}`, `{ref_extern, _}`, `{FuncType, Closure}`) and
  with the exception term `{wasm_exn, …}` — so an `exnref` is neither null, nor a funcref, nor an
  externref, nor (re-)confusable with a live exception.
- **Capture** (in a `_ref` catch clause) — `call '<exn_module>':'capture'(Class, Reason, Stk)` binds the
  box before the label transfer. **PURE** (no trap, no state) — it wraps the three exception variables
  the `try` already bound; the emitter threads it as the extra transfer value (§C.3).
- **Opacity (H6)** — Safe code may **hold, pass, store, and re-throw** an `exnref` but cannot read the
  underlying `{Class, Reason, Stk}` — `rt_exn` exposes no unwrap except `throw_ref`. A caught exnref
  cannot be forged (no IR op produces `{ref_exn, _}` except `capture`) or inspected (H6/J5).

The Core shape for a `Catch(t, L, ref: True)` clause (Cell), delivering `[payload…, exnref]` to `L`:

```erlang
<{'wasm_exn', {'m', 0}, p}> when 'true' ->
  let <ex> = call 'twocore@runtime@rt_exn':'capture'(c, r, s) in
  case p of                             %% unpack the operand payload list
    <[v0, v1]> when 'true' ->
      <apply_cont(find_label(L).break_cont, [v0, v1, ex], sc, …)>   %% payload ++ exnref → L
  end
```

The `TExnRef` ValType flows opaquely (`emit_value(Var) -> CVar`); a `ConstNull(ExnRef)` (if P7-01 models
a null exnref in `RefType`) lowers to the shared null sentinel like every other reftype (`null_ref_term`,
`:3581`) — no new emitter code.

---

## F. Both state strategies — the thrown-through record + constant space (J5/J7)

Every EH node has a `Cell` arm and a `Threading(cur)` arm. The **crux** is what happens to threaded
instance state when an exception unwinds the BEAM stack:

| Runtime shape | `Cell` (`NoState`) | `Threaded` (`Threading(cur)`) |
|---|---|---|
| `Throw` | `rt_exn:throw(TagId, [args])` — state is in the pdict; nothing travels | `rt_exn:t_throw(TagId, [args], cur)` — the **live record travels in the term** `{wasm_exn, TagId, P, St}` |
| `TryTable` normal completion | `of <V> -> V` — the pdict already reflects mutations | `of <V> -> V` — `body_c` yields `{Package, cur'}`, passed through |
| `TryTable` caught (transfer to label) | continue `NoState` (pdict mutated in place) | **extract `St` from the caught `Reason`** (the payload pattern binds `{wasm_exn, TagId, P, St}`), continue `Threading(St)` — so mutations made **before** the throw are preserved (WASM has **no rollback**) |
| `TryTable` re-raise | `rt_exn:rethrow(C, R, S)` — `R` propagates as-is | `rt_exn:rethrow(C, R, S)` — `R` still carries `St`, so the enclosing catcher recovers it |
| `ThrowRef` | `rt_exn:throw_ref(ex)` | `rt_exn:throw_ref(ex)` — `ex`'s captured `Reason` carries the original `St` |

**The thrown-through record (the "no corrupt state" decision).** Under `Threaded` there is **no pdict**;
the only live state is the record threaded as a function argument and rebound after each mutation. A
Core exception unwinds the stack and **discards** the intermediate `cur` bindings — so the record must
**ride inside the thrown term** (`{wasm_exn, TagId, Payload, St}`) for the catcher to continue from the
**throw-point** state. Because the record is threaded **linearly** (one logical instance state passed
into calls and returned), whoever throws carries the **latest** record — every mutation that happened
before the throw. The catcher's payload pattern binds `St`, and the transfer to the catch label runs
under `Threading(St)`: the enclosing join receives the throw-point state, not a stale try-entry copy and
not a rollback. This is the spec-faithful semantics (a WASM exception does **not** undo memory/global
writes made before it) and it is why threaded state is **never corrupted** by a throw (J5). *(This makes
the thrown-term shape differ by arity across strategies — a 3-tuple (`Cell`) vs a 4-tuple (`Threaded`);
each instance is compiled under one strategy, so within an instance the shapes are consistent, and the
JS/EH path ships under `cell` per I5/S5, so cross-instance propagation is uniform-`cell`.)*

**Constant space + preemption (J7).** The BEAM `try/catch` and `raise` are **native** unwinding — no
reified stack, no interpreter. A `throw` on the hot path of a constant-space loop unwinds to the handler
in O(active-handlers) native frames; the caught-path transfer to a catch label is a **tail `apply`** to
the enclosing join (constant stack), and a loop that `throw`s-and-catches per iteration threads the
fixed-size record with **no** loop-carried growth (the G4 template, unchanged). The scheduler still
preempts at reduction boundaries across a throw (metering/fuel still bites — a `throw` does not escape
`rt_meter`; `FuelExhausted` is a **trap**, so it propagates past every `try_table`, §Effect).

---

## G. The `CTry` Core-AST node + printer + the security-test walker (cross-unit seams)

Emitting a BEAM `try` requires a Core-AST node **that does not exist yet** — `core_erlang.gleam`
deliberately omitted `try`/`catch`/`receive` since Phase 1 (its module doc says so), and
`core_printer.gleam` has no `try` arm. Three touch-points:

1. **`core_erlang.CTry` (keystone-owned, P7-01).** A new `CExpr`:
   ```gleam
   CTry(arg: CExpr, body_vars: List(String), body: CExpr, evars: List(String), handler: CExpr)
   ```
   modelling cerl's `#c_try{arg, vars, body, evars, handler}`. `arg` is the protected expression;
   `body_vars` bind its success value(s) (this unit always uses a **single** transparent binder, §C.1);
   `body` is the success continuation (`CVar(v)` — the identity); `evars` are the **three** exception
   variables `[Class, Reason, Stacktrace]`; `handler` is the catch body. This unit **emits** `CTry`; the
   keystone **defines the type** (growing `CExpr` breaks the printer + the security walker — the
   keystone's deliberate cross-file reach, exactly as P6-01 grew `CExpr` for SIMD).
2. **`core_printer` `CTry` arm (keystone-owned, P7-01).** Prints
   ```text
   ( try <Arg>
       of <V1,…> -> <Body>
       catch <Ec,Er,Et> -> <Handler> )
   ```
   the OTP-29-accepted Core `try` form. (The three `evars` are the class/reason/**stacktrace** — OTP ≥
   21 binds the stacktrace as the third `try` variable directly.) This unit consumes the printed form;
   it does not write the printer.
3. **The D3a security-test `children` walker (THIS unit, `emit_core_security_test.gleam`).** The walker
   (`children`, `:69`) that reaches every `CCall` for the ambient-authority proof **MUST gain a `CTry`
   arm** — `CTry(arg, _, body, _, handler) -> [arg, body, handler]` — otherwise a `CCall` inside a try
   body or handler **escapes the walk**, a **fail-OPEN hole in the security test itself**. This is
   owned here (this unit owns the security test) and is a required part of the D3a extension.

*(Whether `CTry` lands in the keystone or is co-owned with this unit is a §Cross-unit seam; the
recommendation is keystone-owned — it is a shared Core-AST/printer change other EH units reference,
mirroring how P6-01 owned the `CExpr` growth. This unit's `emit_try_table` is unchanged either way.)*

---

## Effect / soundness / security note

- **No ambient authority (D3a) survives the surface growth — a HOMOGENEOUS allow-set (S5).** Every EH
  runtime reach is `seam_call(exn_module, "<fixed>", …)` — a fixed build-controlled atom
  (`"twocore@runtime@rt_exn"`, admitted in the security allow-set exactly like `rt_simd`/`link`), a
  literal function atom, operands as ordinary Core values, and the tag identity a **compile-time
  constant** (never program data). **No `erlang:*` call is emitted in generated code** — `erlang:throw`
  and `erlang:raise/3` live **inside** `rt_exn` (a build-controlled runtime module, exactly as
  `erlang:error/1` lives inside `rt_trap`). So the generated-code allow-set stays the homogeneous
  twocore-only set (there is deliberately **no** `erlang` entry, matching the `link:call_import`
  decision, S5). `rt_exn:rethrow` transfers control by **unwinding**, not by calling a data-named
  function — there is no `apply(Mod, Fun, Args)` of an attacker term anywhere on the EH path (D3a). A
  caught `exnref` is **opaque** (`rt_ref`-style, §E): Safe code can re-throw but cannot forge or inspect
  the underlying BEAM term.
- **Fail-closed exception/trap distinction (H6/J5) — a trap is NEVER caught by `try_table`.** The
  handler's `case Reason of {wasm_exn, …} -> … ; _ -> rethrow end` matches **only** the exception term
  `{wasm_exn, TagId, Payload}`; a **trap** `{wasm_trap, Kind}` (memory OOB, `unreachable`, div-by-zero,
  a host **denial** `{capability_denied, …}`, **`FuelExhausted`**) falls to the `_ -> rethrow` default
  and **propagates uncaught — even past a `catch_all`** (which matches only `{wasm_exn, _, _}`). This is
  the spec rule that traps abort past exception handlers, and it is enforced structurally: the
  distinguished outer tag (`wasm_exn` vs `wasm_trap`) **plus** the distinguished BEAM class (throw vs
  error, §B.1) are a defence-in-depth double check. Metering therefore still bites across a throw —
  `FuelExhausted` is a trap, so a runaway `throw`/catch loop is still preempted + fuel-bounded (J5/J7).
- **`TrapReason` unchanged (no new variants) — a WASM exception is a distinct term class, not a trap.**
  A WASM exception rides its own `{wasm_exn, …}` channel; it never reuses `TrapReason` (so the exhaustive
  `spec_trap_message`/`trap_reason_atom` matches stay untouched — the S8-analogue). The only trap on the
  EH surface is a `throw_ref` of a **null** exnref, which reuses an existing reason (§D). If a pinned EH
  `.wast` `assert_trap` empirically needs a message the existing set cannot produce (expected: none —
  the EH suite asserts *exception* behaviour via `assert_return`/`assert_exception`, not new traps), add
  exactly one variant consciously (10).
- **Conformance-neutral by default (J6) — a security-relevant invariant too.** A **tag-free** module has
  no `Throw`/`TryTable`/`ThrowRef` node → the three traversals are unchanged, no `try` is emitted, no
  `exn_module` call appears, `Ctx.module_name` is inert → the authority surface is *identical* to Phase
  6, so the prior D3a proof carries over unmodified and `emit_module(phase6_fixture, safe())` is
  bit-for-bit unchanged.
- **The BEAM sandbox is not weakened (J5).** An **uncaught** WASM exception becomes an uncaught BEAM
  `throw` that the instance boundary contains (one-instance-one-process) — it cannot escape to another
  instance or the node; the run-ABI surfaces it as an ordinary trapped/failed result (09). Preemption +
  the one-process-per-instance isolation are unchanged.

---

## Verification — Definition of Done (D8)

Tests assert **WebAssembly-EH-spec behavior** (the exception-handling proposal + core-spec §4.4.9;
the pinned `throw.wast`/`try_table.wast`/`tag.wast`/`throw_ref.wast` where `wast2json`-able, else an
authored in-scope proof — 10) and **measured Porffor behavior** (the legacy `try/catch`, the `(f64,i32)`
payload) — never whatever the code emits (no change-detector tests); cite the spec/J-decision in each.
"Done" = the suite below passes + the conformance gate (`fail == 0`), never "it compiles."

1. **`Throw` raise goldens** (`emit_core_test`), both strategies: `Throw(0, [Var("v"), ConstI32(195)])`
   → `Cell`: a bare `call '<exn>':'throw'({'m',0}, [v, 195])` (no `case`, no `cont` — bottom); `Threaded`
   (arity `n+1`, record `st`): `call '<exn>':'t_throw'({'m',0}, [v, 195], st)` (the record travels).
   Assert the payload is the operand value **list** (unchanged, un-interpreted — `«PORFFOR-ABI»`), and
   that `tag_id_term`/`tag_id_pat` are the symmetric `{'m',0}` constant (expression vs pattern). Cite
   `throw`=`0x08` + §4.4.9 (throw creates + unwinds).
2. **`TryTable` try/catch AST-shape goldens** (`emit_core_test`), both strategies:
   - a single `Catch(0, "L", ref: False)` around a body → `try <body> of <v> -> v catch <c,r,s> -> case
     r of {wasm_exn, {'m',0}, p} -> <unpack p, break to L> ; _ -> rethrow(c,r,s) end`; assert the
     **transparent** `of <v> -> v`, the **literal-pattern** tag match, and the `_ -> rethrow` default.
   - a **trap does not match**: assert the only `wasm_exn` clauses are the tag clauses and that a
     `{wasm_trap, _}` reason would fall to `rethrow` (structural: `catch_all` is `{wasm_exn, _, _}`, not
     `_`). Cite the spec rule that traps are not catchable.
   - a `CatchAll("La", ref: False)` → a `{wasm_exn, _, _}` clause transferring **no** payload to `La`.
   - **clause order** is preserved (a `catch $t0` before a `catch_all` emits the `t0` case first).
   - **`Threaded` thrown-through record**: the caught payload pattern binds `St` (`{wasm_exn, {'m',0},
     p, st'}`) and the label transfer continues under `Threading(st')` — assert the enclosing join is
     applied with `st'` (the throw-point record), NOT the try-entry `cur`. Cite J5 (no rollback).
3. **`catch_ref` / exnref goldens** (`emit_core_test`): a `Catch(0, "L", ref: True)` → `let <ex> = call
   '<exn>':'capture'(c, r, s) in <unpack p, break to L with [payload…, ex]>` — assert the exnref is the
   **last** transfer value and is an `rt_exn:capture` of the three exception variables. A
   `CatchAll("La", ref: True)` → transfers `[ex]` only. `ThrowRef(Var("ex"))` → `call
   '<exn>':'throw_ref'(ex)` (bottom). Cite `throw_ref`=`0x0A` + the exnref opacity (H6).
4. **J6 byte-identity** (the non-negotiable): `emit_module(phase6_fixture, safe())` and
   `emit_module(phase6_fixture, Threaded)` printed to `.core` are **bit-for-bit** unchanged from the
   pre-P7 emission — for a fixture with **no** tags (no `Throw`/`TryTable`/`ThrowRef`). The existing
   `emit_core_test`, `emit_core_security_test`, and conformance goldens stay green under every shipped
   `(state_strategy × mem_tier)`.
5. **D3a security walk extended & green** (`emit_core_security_test`): grow the fixture to exercise
   `Throw`, a multi-clause `TryTable` (`Catch` + `Catch(ref)` + `CatchAll` + the re-raise), and
   `ThrowRef`, then assert:
   - **`children` gains its `CTry` arm** and the walk reaches inside the try body + handler (regression:
     a `CCall` planted inside a try handler MUST be caught by the walk — proves the walker is not
     fail-open);
   - every `CCall` targets a fixed allow-set atom (`runtime_modules` **extended with `exn_module`**) with
     a **literal** function atom; **assert NO `CCall` targets `erlang`** (the re-raise/throw/capture all
     route through `rt_exn`, homogeneous allow-set — S5);
   - every `CApply` is still a static local `FName` (EH introduces **no** new `CApply`);
   - the new seam calls are delegated to `rt_exn`: `has_call(m, exn_module, "throw")`, `…"t_throw"` (under
     `Threaded`), `…"rethrow"`, `…"capture"`, `…"throw_ref"`.
   Run it under `Cell`, `Threaded`, **and** `unsafe()` — all three pass with the same allow-set.
6. **End-to-end** (`emit_core_e2e_test`; green once 07 lands — Concurrency), hand-built EH IR →
   `emit_module` → `build_beam` → `instantiate` → invoke, asserting **spec-correct** results and
   **byte-identical `Cell` vs `Threaded`** where applicable:
   - **uncaught throw** → propagates out as a BEAM `throw` the run-ABI surfaces as a trapped/failed
     result (the instance boundary contains it — J5).
   - **caught throw** — a `try_table (catch $t $L)` whose body `throw $t (payload)` **catches the
     matching tag**, delivers the payload to `$L`, and yields the handler's result (the canonical `f(5)
     → 6`, `f(-2) → -1` shape of the Porffor sample, §Porffor); assert the payload `(f64,i32)` pair
     round-trips through the catch to `$L` unchanged.
   - **non-matching tag re-raises** — a body throwing `$t2` under a `try_table (catch $t1 $L)`
     **propagates** (the `_ -> rethrow` fires), caught by an enclosing handler or surfacing as a failed
     result; assert the **stacktrace is preserved** across the re-raise.
   - **a trap is NOT caught** — a body that traps (`unreachable` / memory OOB) under a `try_table
     (catch_all $L)` **propagates the trap** (never lands at `$L`); assert the result is the trap, not
     the catch_all handler. Cite the spec exception/trap distinction.
   - **nested try/catch** unwinds to the innermost matching handler; an inner `catch_all` shadows an
     outer `catch $t` for a matching throw.
   - **`throw_ref`** — a `catch_ref` captures an exnref, and a later `throw_ref` of it **re-raises the
     original exception** (original tag + payload), caught by an enclosing `catch $t`.
   - **threaded state survives a throw** — a body that mutates a global/memory **then** throws, caught by
     a handler that reads the mutated state, sees the **mutated-before-throw** value (no rollback);
     diffed against the `Cell` oracle (same IR, `state_strategy: Cell`) — the J6 bar.
   - **constant space across a throw** — a loop that `throw`s-and-catches per iteration runs in bounded
     stack (a large iteration count does not blow the stack); preemption/fuel still bites.
7. **No regression.** `gleam format --check src test` clean; `gleam build` **zero warnings**; `gleam
   test` stays green (the Phase-6 corpus + suite untouched — the tag-free path is byte-identical, test
   4). Every new public/private function carries a contract doc comment (D8).

**Proof of goal:** tests 1–3 + 6 are the unit's proof — a WASM module hand-built as EH IR that `throw`s,
`try_table`-catches (matching tag, payload delivered), re-raises a non-match (stacktrace preserved), is
transparent to traps (never caught), captures/re-throws an exnref, and preserves threaded state across a
throw — compiles, instantiates, and runs spec-correctly on the BEAM under **both** state strategies, with
the security walk green (the raise/catch/capture proven ambient-free + `erlang`-free), and a tag-free
module still byte-identical.

## What this unit leaves

- **Unit 07 (`rt_exn`)** implements the bodies behind the `rt_exn` heads this unit emits: `throw`/
  `t_throw` (`erlang:throw({wasm_exn, …})`), `rethrow` (`erlang:raise/3`), `capture`/`throw_ref` (the
  `{ref_exn, {Class, Reason, Stk}}` box + unbox, forge-proof, `rt_ref`-style) — plus the null-exnref
  trap. This unit's EH e2e is 07's integration check.
- **Unit 01 (keystone)** freezes `Module.tags`/`TagDecl` + `Throw`/`TryTable`/`ThrowRef` + the
  `CatchClause` shape + `TExnRef`, **defines the `CTry` Core-AST node + its `core_printer` arm**, adds
  `Ctx.module_name` (or an equivalent tag-identity carrier), and pins the tag-identity representation
  (§B.3/D3) + the `rt_exn` sigs («RT-EXN-SIG»).
- **Unit 05 (lower)** produces the EH IR this unit consumes — mapping **both** legacy `try/catch/
  catch_all` **and** modern `try_table` onto the neutral `TryTable`/`Throw`/`ThrowRef`, **wrapping the
  try_table's self-label in a `Block`** (§C.2), resolving each catch clause's branch target to an
  enclosing label, and resolving imported/exported tags (§Cross-unit seams).
- **Unit 08 (Porffor shim)** provides the `(f64,i32)` value-ABI decode so a returned/thrown JS value is
  judged, and the tag-import link resolution if a cross-module tag ever appears.
- **Units 09/10** prove the JS-on-the-BEAM headline (a Porffor `try/catch` JS program runs + judges
  differentially vs `porf run`/Node) and the EH conformance (`throw.wast`/`try_table.wast`/`tag.wast`/
  `throw_ref.wast` green or an authored proof, `fail == 0`), measured honestly (J8).

---

## Deviations from the overview / provisional surface (ARGUED — for critique + reconciliation)

- **D1 — the transparent-`try` encoding, with the `br`/`continue`-out-then-rethrow corner measured, not
  emulated.** The overview (J1) says `try_table → a Core Erlang try that matches the tag … and re-raises
  a non-matching exception`, without pinning how a **non-local exit** (`return`/`br`-enclosing/
  `continue`) out of a try body interacts with the Core `try`'s dynamic extent. **Recommend the
  transparent `try Body of <V> -> V catch …` encoding** (§C.1): sound because every emitted expr is one
  packaged value, elegant (no trampoline, no tagged-exit protocol, constant-space), and correct for
  normal completion, `throw` (caught + propagated), and **`return`** (always — a function exit runs
  nothing after it inside the try). The single spec-corner it does **not** capture — a `br`/`continue`
  out of a `try_table` **followed by a re-`throw` of the SAME still-installed tag while the try frame is
  dynamically active** — is flagged, not hand-waved: **(a)** it never affects Porffor's measured output
  (its try bodies contain `if`/`return`/`throw`, no `br`-out-then-rethrow, §Porffor) or the JS corpus;
  **(b)** its escalation is a **tagged-exit trampoline** (the try's `Arg` returns a
  `{done|return|break|continue, …}` discriminant and the `of` clause dispatches, deactivating the
  handler on a non-local exit) — build it **iff** the pinned EH `.wast` handler-deactivation tests
  require it (MEASURED by 10, R16-style), else **(c)** categorise it as an honest-scope gap (J8). This
  is the R16 discipline: assert the corner empirically, never a false green.
- **D2 — `exn_module` as a module-level `const`, matching `simd_module`/`link_module` (not a `Binding`
  field).** P6-06 reached `rt_simd`/`link` via `const`s (`emit_core.gleam:127`/`137`), not `Binding`
  fields, because they are not tier-swappable. **Recommend the same for `exn_module`** (`const exn_module
  = "twocore@runtime@rt_exn"`, admitted in the security allow-set like `rt_simd`/`link`): `rt_exn` is not
  a tier-swap seam (there is no "alternate exception backend"), so a `Binding` field would be dead
  configuration. If the keystone prefers a `binding.exn_module` field for uniformity with `trap_module`,
  this unit consumes it with a one-line change — either realises the identical D3a property.
- **D3 — the tag identity is a compile-time `{module, idx}` constant (recommended), with the
  instance-unique alternative argued.** The overview (J1) models the term `{wasm_exn, TagId, Payload}`
  but leaves `TagId` unspecified. **Recommend a per-module compile-time constant `{'<module>', <idx>}`**
  (§B.3): a constant keeps `Throw`/`TryTable` free of a state read for identity (only the threaded `cur`
  travels), makes the catch match a **literal pattern** (no guard), and never collides across two
  **different** modules. It is **not** fully correct for two instances of the **same** module cross-
  propagating an exception (both use `{'m', 0}`) — an exotic case **out of Porffor's measured scope**
  (single-module-single-instance, §Porffor) — nor for a genuine **imported** tag (whose identity is the
  *exporter's*, resolved at link time — a seam). **The reconciliation-time alternative** (flagged, not
  rejected): an **instance-unique** identity minted at instantiation for each defined tag, seeded into
  instance state like a table, read `rt_state:tag_at(idx)` / `t_tag_at(St, idx)` at the throw/catch site.
  That is fully correct (re-instantiation + cross-module) but makes `Throw`/`TryTable` **state-reaching**
  (a state read for the identity) and the catch match a **guard** (`when TagId =:= <read>`), not a
  pattern — heavier, and only needed if the EH `.wast` `tag.wast` cross-module-identity tests are in the
  pinned scope (MEASURED by 04/10). The keystone owns the freeze; this unit routes through
  `tag_id_term`/`tag_id_pat` so swapping the representation is a two-function change.
- **D4 — `throw`-class for exceptions, `error`-class for traps (the exception/trap distinction rests on
  the BEAM class + the reason tag).** The overview says `throw → a BEAM throw/error of that term`
  (either class). **Recommend `throw` class** (`rt_exn:throw` = `erlang:throw`), keeping `rt_trap`'s
  `error` class for traps — so a `try_table` naturally distinguishes an exception (throw class,
  `{wasm_exn,…}`) from a trap (error class, `{wasm_trap,…}`) on **both** the class and the reason tag
  (defence-in-depth). The catch handler matches the reason shape and re-raises with the **captured**
  class, so both round-trip. (Matching only on the reason tag would also work — the classes are a robust
  second check that a genuine BEAM `error` is never mistaken for a WASM exception.)

## Open questions / cross-unit seams (for the planner / reconciliation)

- **The `CTry` Core-AST node + printer ownership (01).** §G. Confirm the keystone adds
  `core_erlang.CTry(arg, body_vars, body, evars, handler)` + the `core_printer` `try … of … catch …`
  arm (recommended keystone-owned, mirroring P6-01's `CExpr` growth). This unit emits `CTry` + owns the
  security-test `children` `CTry` arm regardless.
- **`Ctx.module_name` (01/this unit).** §B.3. The tag-identity term needs the module name (or an
  equivalent per-module discriminant) in `Ctx`. Confirm the keystone (or this unit, as a minimal
  additive `Ctx` field threaded from `emit_module`) adds it.
- **The tag-identity representation (01/07).** §B.3/D3. Pin: the compile-time `{module, idx}` constant
  (recommended) vs the instance-unique state-seeded identity vs a bare `CInt(idx)`; the `rt_exn` term
  shape (`{wasm_exn, TagId, Payload[, St]}`, throw-class); and **whether imported/exported tags are in
  the pinned scope** (Porffor exports its tag but nothing imports it — measured, §Porffor). If imported
  tags are in scope, the identity of an imported tag is link-resolved (a `provided_tag_identity` seam,
  09-adjacent).
- **The `rt_exn` call ABI (07).** §B/§C/§D/§E. Pin: `throw(TagId, Payload)`/`t_throw(TagId, Payload, St)`
  (never-returning, throw-class); `rethrow(Class, Reason, Stk)` (`erlang:raise/3`, stacktrace-preserving);
  `capture(Class, Reason, Stk) -> ExnRef` (the `{ref_exn, {C,R,S}}` box, PURE, forge-proof);
  `throw_ref(ExnRef)` (unbox + re-raise; null-exnref trap). Confirm the two-head throw split
  (`throw`/`t_throw`, matching the `size`/`t_size` twin convention) and that `rt_exn` is the SOLE emitter
  of `erlang:throw`/`erlang:raise` (no `erlang:*` in generated code — S5).
- **The try_table self-label wrap (05).** §C.2. Confirm P7-05 wraps `try_table`'s own block label in a
  `Block` (so `TryTable` is purely handler-installation) and resolves each catch clause's branch target
  to an enclosing label + resolves `ref`-clause exnref pushes.
- **Legacy vs modern EH decode (03/05).** §Context. Confirm P7-03 decodes the pin's actual surface
  (measured **legacy** `try`=`0x06`/`catch`=`0x07`/`throw`=`0x08` for Porffor 0.61.13, and/or the modern
  `try_table`=`0x1F`/`throw_ref`=`0x0A` for the EH `.wast`) and P7-05 lowers **both** onto the same
  neutral `TryTable`/`Throw`/`ThrowRef` — so this unit's mapping is surface-agnostic.

---

## Porffor — the measured EH surface (Porffor 0.61.13, this pin)

Compiling a JS `try/catch/finally` program (`npx porffor wasm foo.js foo.wasm` + `wasm-tools
dump`/`print`) shows the **exact** EH surface this pipeline must run — and it is the **legacy**
proposal, not the modern `try_table` the overview assumes:

- **Tag section (id `13` — `0d`).** `(tag (;0;) (type 3) (param f64 i32))` — one tag whose operand type
  is the `(f64, i32)` **typed-value pair** (a JS value + its type tag). Confirmed via
  `wasm-tools dump`: `0d 03 | tag section`, `00 03 | TagType { kind: Exception, func_type_idx: 3 }`.
- **The tag is EXPORTED** — `(export "0" (tag 0))` (`01 30 04 00 | export … kind: Tag`). Nothing in a
  single-module program imports it, so a module-local identity suffices (§B.3/D3); a genuine cross-module
  tag import is out of the measured scope.
- **Legacy `try`/`catch`/`throw`** — `try ;; label = @1 … catch 0 … end`; `wasm-tools dump` confirms the
  bytes `06 40 | try blockty:Empty`, `08 00 | throw tag_index:0`, `07 00 | catch tag_index:0`. The
  **payload** is pushed before `throw`: `f64.const 16 / i32.const 195 / throw 0` — the `(f64, i32)` pair.
  **Both `--exception-mode=stack` (default) and `lut` still emit tag/throw/catch** — there is no Porffor
  mode that avoids WASM EH (findings §). So JS-on-the-BEAM **is** gated on this unit.
- **`return` inside the try body** — the measured try body contains `local.get 2 / local.get 3 / return`
  (a JS `return` inside `try`). This is why §C.1's transparent-`try` encoding must (and does) handle
  `return`-out-of-try correctly, and why the `br`/`continue`-out corner (D1) is called out explicitly
  rather than assumed absent.

The **neutral IR absorbs the legacy-vs-modern split** (P7-05 lowers legacy `try/catch` and modern
`try_table` to the same `TryTable`/`Throw`/`ThrowRef`), so this unit's BEAM mapping is identical for
both — the payoff of the IR-neutrality discipline (D6/J2). This unit cites the modern proposal's opcode
bytes + semantics per the task's requirement (they are what the neutral IR models); the measured legacy
reality is recorded here so 03/05 decode the right surface and 09/10 judge the right corpus.
