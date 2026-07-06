# Q13-03 — The tail-call typing rule in `validate.gleam`

> **Status:** scoped, awaiting build. **Owner:** Q13-03 (Wave A, parallel behind `«TC-FROZEN»`).
> **Depends on:** `«TC-FROZEN»` (Q13-01 keystone) — the two AST constructors `ast.ReturnCall` /
> `ast.ReturnCallIndirect` and the two conservative-sound placeholder arms the keystone landed in
> `validate_instr`. **Produces:** no freeze; it *completes* one file's placeholder arm. **Read order:**
> [`00-overview.md`](00-overview.md) → the distilled brief → this doc. All prior-phase decisions and the
> permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold. This unit
> changes **no emitted `.beam`** (validation is a gate, not a codegen stage) — default output stays
> byte-identical; it only makes the validator **accept** well-typed tail calls and **reject** ill-typed
> ones per the WASM tail-call proposal.

---

## §1. Goal

Complete the real **tail-call typing rule** for `return_call` (`0x12`) and `return_call_indirect`
(`0x13`) inside `src/twocore/frontend/wasm/validate.gleam`. Per the WebAssembly tail-call proposal, both
instructions:

1. pop the **callee's params** (and, for `return_call_indirect`, first an `i32` table index and a
   `FuncRef`-table check — identical to `call_indirect`);
2. **require the callee's result types to equal the current function's result types** — else reject with
   `TypeMismatch`;
3. **mark the operand stack polymorphic** (`mark_unreachable`) — stack-polymorphic bottom-transfers,
   exactly like `return` / `br`.

The keystone left each arm as a **sound-minimal placeholder** (it compiles and is never reached by any
real input, because decode/WAT do not emit these AST nodes until sibling unit Q13-02 lands). This unit
**replaces the two placeholder arm bodies** with the rule above and lands the spec-cited `assert_invalid`
suite that proves it.

---

## §2. Decisions honored

- **Q3 (the rule itself).** Validation is "the `return` / `br` rule plus a result-type equality check."
  The current function's results are read exactly the way `ast.Return` reads them — the **outermost**
  control frame's `end_types` (`list.last(st.ctrls)`), not the innermost. The result-mismatch diagnostic
  **reuses the existing `TypeMismatch` variant** — no new `ValidateError` constructor — so `validate.gleam`
  stays single-substantive-owner (this unit) with no shared-type edit that would collide with the keystone.
- **Q7 (proof is spec, not change-detectors).** Tests encode the tail-call proposal's *validation*
  semantics — `assert_invalid` for result mismatch (direct + indirect), the `RefTypeMismatch` for a
  non-`FuncRef` indirect table, and the stack-polymorphism-after-tail-call property that mirrors `return`.
  No test locks in emitted text or the current implementation's incidental behavior.
- **Q8 (honest scope).** Only the two instructions; **no new trap reason**, **no new `ValidateError`
  variant**, no new machinery. The pops reuse the existing `pop_vals` / `pop_expect` / `table_entry`
  helpers; the polymorphism reuses the existing `mark_unreachable`.
- **Q2 (exhaustiveness plumbing already discharged).** The `case instr { … }` arms exist only because the
  keystone added the AST constructors (Gleam has no default arm); this unit gives the two arms their real
  bodies and touches nothing else in the match.

---

## §3. What it owns + design

**Owned file (D1):** `src/twocore/frontend/wasm/validate.gleam` — the two tail-call arms in the private
`validate_instr` (fn at **`:893`**), plus the negative/positive spec tests appended to
`test/twocore/frontend/wasm/validate_test.gleam`. **No cross-file reach.** No public signature changes:
the module's only public entry, `pub fn validate(module) -> Result(TypedModule, ValidateError)`
(**`:593`**), keeps its signature; the completion is entirely internal to two `case` arms.

### 3.1 The exact edit points (cite verbatim)

| Anchor | What it is | Role in this unit |
|---|---|---|
| `validate.gleam:893` | `fn validate_instr(instr, ctx, st)` — the flat `case instr { … }` | contains the two arms to complete |
| `validate.gleam:953-961` | `ast.Return` arm | **shape template**: `list.last(st.ctrls)` → `pop_vals(func_frame.end_types)` → `mark_unreachable` (does **not** push) |
| `validate.gleam:964-971` | `ast.Call(f)` arm | **callee-sig source (direct)**: `nth(ctx.func_types, f)` → `Error(UnknownFunc(f))`; `pop_vals(sig.params)` |
| `validate.gleam:978-991` | `ast.CallIndirect(type_idx, table)` arm | **indirect prelude**: `nth(ctx.types, type_idx)` → `UnknownType`; `table_entry(ctx, table)` + `FuncRef` else `RefTypeMismatch`; `pop_expect(I32)`; `pop_vals(sig.params)` |
| `validate.gleam:531` | `fn mark_unreachable(st)` | the stack-polymorphic bottom-transfer (drops operands above the frame base, sets the polymorphic bit) — **reuse verbatim** |
| `validate.gleam:278-310` | `pub type ValidateError` | **reuse `TypeMismatch` (`:279`)** — add **no** variant |

The two keystone-placeholder arms live in the **`// calls`** section of the `case`, sited immediately
after the `ast.CallIndirect` arm (~`:991`). This unit rewrites their bodies in place.

### 3.2 `ast.ReturnCall(f)` — the direct rule

Reads the callee signature like `ast.Call`, then applies the `ast.Return`-shaped tail: require the
callee's results to equal the function's results, then `mark_unreachable` (no push — the continuation is
dead). Illustrative body (house-style `//` comment above the arm, since `///` cannot attach inside a
`case`):

```gleam
// `return_call f`: pop the callee's params, then REQUIRE the callee's result
// types to equal the CURRENT function's result types (the outermost/function
// frame's `end_types`, read as `return` reads it); on mismatch reject with
// `TypeMismatch`. The stack then goes polymorphic (`mark_unreachable`) exactly
// like `return` — the continuation is unreachable (WASM tail-call proposal:
// `return_call` is valid iff callee results == function results, stack-polymorphic).
ast.ReturnCall(f) -> {
  use sig <- result.try(case nth(ctx.func_types, f) {
    Ok(s) -> Ok(s)
    Error(_) -> Error(UnknownFunc(f))
  })
  use func_frame <- result.try(case list.last(st.ctrls) {
    Ok(fr) -> Ok(fr)
    Error(_) -> Error(UnexpectedEnd)
  })
  use st2 <- result.try(pop_vals(st, sig.params))
  case sig.results == func_frame.end_types {
    False -> Error(TypeMismatch)
    True -> mark_unreachable(st2)
  }
}
```

### 3.3 `ast.ReturnCallIndirect(type_idx, table)` — the indirect rule

The `ast.CallIndirect` prelude (type-in-range → table-`FuncRef` → pop `i32` index → pop params) followed
by the same result-equality gate and `mark_unreachable`. Same traps, same order as `call_indirect` for
the structural part; the equality gate is the added tail-call constraint. Illustrative body:

```gleam
// `return_call_indirect (type y) x`: the static `typeidx y` must be in range and
// table `x` must hold `funcref` (else `RefTypeMismatch`); pop the i32 index then the
// callee's params — identical to `call_indirect`. Then REQUIRE the callee (type y)
// result types to equal the current function's result types (else `TypeMismatch`),
// and go stack-polymorphic. The per-call structural type check stays DYNAMIC (runtime),
// unchanged from `call_indirect` (WASM tail-call proposal validation).
ast.ReturnCallIndirect(type_idx, table) -> {
  use sig <- result.try(case nth(ctx.types, type_idx) {
    Ok(s) -> Ok(s)
    Error(_) -> Error(UnknownType(type_idx))
  })
  use #(ref_ty, _) <- result.try(table_entry(ctx, table))
  use _ <- result.try(case ref_ty {
    ast.FuncRef -> Ok(Nil)
    _ -> Error(RefTypeMismatch)
  })
  use func_frame <- result.try(case list.last(st.ctrls) {
    Ok(fr) -> Ok(fr)
    Error(_) -> Error(UnexpectedEnd)
  })
  use st2 <- result.try(pop_expect(st, ast.I32))
  use st3 <- result.try(pop_vals(st2, sig.params))
  case sig.results == func_frame.end_types {
    False -> Error(TypeMismatch)
    True -> mark_unreachable(st3)
  }
}
```

### 3.4 Correctness notes (pin these)

- **"Current function's results" = the outermost frame, not the innermost.** Use `list.last(st.ctrls)`
  (the `KFunc` frame), matching `ast.Return` at `:953-961`. Reading `top_ctrl` / the innermost block's
  `end_types` would be wrong when the tail call is nested inside a `block`/`if`/`loop`.
- **Equality is order-sensitive `List(ValType)` equality.** `sig.results == func_frame.end_types` correctly
  rejects both a *type* mismatch (`[i32]` vs `[i64]`) and an *arity* mismatch (`[]` vs `[i32]`, or
  `[i32,i32]` vs `[i32]`) — the spec requires the full result vector to be equal.
- **No push after the transfer.** Like `return`/`br`, the tail-call arms end in `mark_unreachable(st…)`
  and never `push_vals` — the caller's continuation carries no result values.
- **The pops precede the equality gate** so a stack that lacks the callee's params underflows exactly as an
  ordinary `call`/`call_indirect` would; the equality gate is the final constraint before the transfer.
  (Validation-error *ordering* is not spec-observable for `assert_invalid`; any offending module is
  rejected — but this ordering keeps the arm a clean superset of the `call` / `call_indirect` shape.)
- **`UnexpectedEnd` on an empty `ctrls`** is an impossible state inside a function body (the `KFunc` frame
  is always present); it is handled defensively, identically to `ast.Return`.

---

## §4. The work (ordered, buildable)

1. Locate the two keystone-placeholder arms in `validate_instr` (`:893`, in the `// calls` section after
   `ast.CallIndirect` ~`:991`). Confirm they currently compile as sound-minimal stubs.
2. Replace the `ast.ReturnCall(f)` arm body with §3.2; add the `//` block comment citing the rule.
3. Replace the `ast.ReturnCallIndirect(type_idx, table)` arm body with §3.3; add the `//` block comment.
4. `gleam format` → `gleam build` (must stay zero-warning; the arms reference only pre-existing helpers).
5. Add the spec tests (§5) to `test/twocore/frontend/wasm/validate_test.gleam`, each with a `///`
   doc-comment citing the tail-call proposal rule it encodes.
6. `gleam test -- twocore/frontend/wasm/validate_test` green; then the full `gleam test` green (default
   output unchanged — no module in the existing corpus emits these opcodes yet, so conformance is
   untouched by this unit).
7. Record completion of the validate placeholder in [`../state.md`](../state.md).

---

## §5. Tests (spec-cited + adversarial) — append to `validate_test.gleam`

Use the file's existing hand-built helpers (`ft`, `func_`, `tbl`, `rtbl`, `module`, `accept`, `is_ok`) so
the tests target the **typing rule directly** on `ast.ReturnCall` / `ast.ReturnCallIndirect` AST values —
no decode/WAT dependency (that keeps Q13-03 dependent only on `«TC-FROZEN»`, not on sibling Q13-02).
Every case cites the WASM tail-call proposal rule it violates or satisfies; **none** locks in emitted text.

**Positive (must ACCEPT):**

1. **`accept_return_call_direct_test`** — `types: [ft([], [I32])]`; two funcs of type 0; caller body
   `[ast.ReturnCall(1), ast.End]`, callee body `[ast.I32Const(0), ast.End]`. Callee params `[]`, callee
   results `[I32]` == caller results `[I32]` → accepted. *(Spec: `return_call` valid iff callee results ==
   function results.)*
2. **`accept_return_call_params_consumed_test`** — `types: [ft([], [I32]), ft([I32, I32], [I32])]`; caller
   of type 0 body `[ast.I32Const(1), ast.I32Const(2), ast.ReturnCall(1), ast.End]`, callee of type 1.
   Proves the callee's two `i32` params are popped and results still equal `[I32]`. Accepted.
3. **`accept_return_call_indirect_test`** — `types: [ft([], [I32])]`; `tables: [tbl(1, None)]`; caller of
   type 0 body `[ast.I32Const(0), ast.ReturnCallIndirect(0, 0), ast.End]`. Pops the `i32` index, callee
   type 0 results `[I32]` == caller results `[I32]` → accepted. *(Mirrors `accept_call_indirect_test`
   plus the equality gate.)*
4. **`accept_return_call_stack_polymorphic_test`** — the honest polymorphism proof, modeled on the
   existing `accept_unreachable_then_op_test`: `types: [ft([], [I32])]`; caller of type 0 body
   `[ast.ReturnCall(1), ast.I32Add, ast.End]`, callee of type 0. The trailing `i32.add` would **underflow**
   on a concrete empty stack; it validates only because `mark_unreachable` made the stack polymorphic
   after the tail call. Reaching `End` with declared result `[I32]` is satisfied by the polymorphic stack.
   Accepted → this is the test that would fail if the arm forgot `mark_unreachable`. *(Spec: `return_call`
   is stack-polymorphic like `return`.)*

**Negative (must REJECT — each `|> should.equal(Error(validate.<Variant>))`):**

5. **`reject_return_call_result_mismatch_test`** — `types: [ft([], [I32]), ft([], [I64])]`; caller func of
   type 0 (result `i32`), callee func of type 1 (result `i64`); caller body `[ast.ReturnCall(1), ast.End]`.
   Callee results `[I64]` != caller results `[I32]` → `Error(validate.TypeMismatch)`. *(Spec: callee result
   type must equal the function's result type — the core new constraint.)*
6. **`reject_return_call_result_arity_mismatch_test`** — `types: [ft([], [I32]), ft([], [])]`; caller of
   type 0 (result `i32`), callee of type 1 (result `[]`); caller body `[ast.ReturnCall(1), ast.End]` →
   `Error(validate.TypeMismatch)`. Proves *arity* difference (not just element type) is rejected.
7. **`reject_return_call_indirect_result_mismatch_test`** — `types: [ft([], [I32]), ft([], [I64])]`;
   `tables: [tbl(1, None)]`; caller of type 0 body `[ast.I32Const(0), ast.ReturnCallIndirect(1, 0),
   ast.End]`. Callee `(type 1)` results `[I64]` != caller `[I32]` → `Error(validate.TypeMismatch)`.
8. **`reject_return_call_indirect_externref_table_test`** — `types: [ft([], [I32])]`;
   `tables: [rtbl(ast.ExternRef, 1)]`; caller of type 0 body `[ast.I32Const(0),
   ast.ReturnCallIndirect(0, 0), ast.End]` → `Error(validate.RefTypeMismatch)`. Exact twin of the existing
   `reject_call_indirect_externref_table_test`: an `externref` table cannot back an indirect tail call.
   *(Spec: `return_call_indirect` shares `call_indirect`'s table-`funcref` validation constraint.)*

**Adversarial extras (strengthen; optional but recommended):**

9. **`reject_return_call_bad_func_test`** — caller body `[ast.ReturnCall(7), ast.End]` with only one func
   defined → `Error(validate.UnknownFunc(7))` (callee funcidx out of range — same guard as `call`).
10. **`reject_return_call_indirect_bad_type_test`** — caller body `[ast.I32Const(0),
    ast.ReturnCallIndirect(5, 0), ast.End]` with `types` shorter than 6 →
    `Error(validate.UnknownType(5))` (static typeidx out of range — same guard as `call_indirect`).
11. **`reject_return_call_param_mismatch_test`** — `types: [ft([], [I32]), ft([I32], [I32])]`; caller of
    type 0 body `[ast.ReturnCall(1), ast.End]` with **no** `i32` pushed for the callee's param →
    `Error(validate.Underflow)` (callee params must be supplied — same `pop_vals` underflow as `call`).

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. The §5 spec tests are green, including the polymorphism-after-tail-call case (#4) and the result-mismatch
   cases (#5–#7) written **first as failing tests** against the placeholder arm, then made to pass by the
   real rule.
2. Each new `///`-documented test cites the tail-call proposal rule it encodes; each new `case` arm carries
   a `//` block comment stating its contract (there is no new *public function* to document — the public
   surface `validate/1` is unchanged — so the doc-comment obligation is satisfied by the arm comments +
   the test `///`s).
3. `gleam format --check src test` clean.
4. `gleam build` zero warnings.
5. The unit suite (`gleam test -- twocore/frontend/wasm/validate_test`) and the full `gleam test` pass;
   **default emission byte-identical** (validation is a gate — no `.beam` changes; the existing
   corpus/conformance stay green because no shipped fixture emits `0x12`/`0x13` yet).
6. No new `ValidateError` variant added (grep the `pub type ValidateError` block — unchanged); the
   result-mismatch path reuses `TypeMismatch`.
7. [`../state.md`](../state.md) records the validate placeholder as completed.

---

## §7. What it leaves (handoff to downstream)

- **Q13-01 (keystone) is upstream, not downstream:** this unit assumes `«TC-FROZEN»` already added
  `ast.ReturnCall` / `ast.ReturnCallIndirect` and the placeholder arms. It edits only those two arm bodies.
- **Q13-02 (decode + WAT ingest):** produces the `ast.ReturnCall` / `ast.ReturnCallIndirect` nodes from
  bytes/text. Independent of this unit; the validate tests hand-build the AST rather than decode it, so the
  two units can land in either order behind the freeze.
- **Q13-04 (lower):** the bottom-transfer lowering (`Return`-shape, `consume_dead`, no `wrap_let`). This
  unit does **not** touch `lower.gleam`; it only decides *acceptance*. A module this unit accepts is what
  Q13-04 lowers.
- **Q13-05 (emit_core):** the real constant-stack tail emission + the `rt_table.call_indirect_lookup` seam.
  Out of scope here — validation neither emits nor traps.
- **Q13-06 (capstone):** drives `return_call.wast` / `return_call_indirect.wast`, whose official
  `assert_invalid` result-mismatch cases exercise this rule end-to-end (decode → validate). This unit's
  hand-built `assert_invalid` fixtures are the unit-level analogue; the capstone confirms the official
  suite agrees.
- **Explicitly NOT this unit:** no new trap reason, no runtime, no IR node semantics, no `ValidateError`
  variant, no optimizer/tier/state-strategy interaction — all deferred to their owning units or excluded
  by Q8.
