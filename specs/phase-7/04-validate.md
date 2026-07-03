# Unit P7-04 — WASM `validate` extension (typing exception handling: tags, `throw`, `try_table`, `throw_ref`, `exnref`)

> **One owner · Wave A · AST-only.** Gates on **`«WASM-AST5»`** (unit **P7-03** decode's EH AST
> surface, published day 1) — *not* on completed decoding — and runs in **parallel** with all the
> IR/runtime work (it never imports `twocore/ir`). Read [`00-overview.md`](00-overview.md)
> (decisions **J1–J8**), [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md), the Phase-6
> [`RECONCILIATION.md`](../phase-6/RECONCILIATION.md) (still authoritative for the frozen platform
> invariants), and (when it lands) the Phase-7 `RECONCILIATION.md` first; where reconciliation
> conflicts with this doc, reconciliation wins. D1 (single-owner-per-file), **D3a (no ambient
> authority)**, D5 (floats/v128 as raw bits), D6 (neutral / generic op names — EH is a **structured-
> exception model**, not WASM opcodes), the conformance-neutral-by-default rule (a tag-free module is
> byte-identical to Phase 6), and the Definition of Done still hold. This unit **extends** the existing
> [`phase-6/04-validate.md`](../phase-6/04-validate.md) validator — the whole Phase-1/2 polymorphic-
> stack / label / else-less-`if` / `max_locals` machinery, the Phase-5 reference-types / bulk / multi-
> memory / memory64 surface, and the Phase-6 SIMD surface are kept **verbatim**. Phase 7 adds exactly
> one thing to this file: **typing for the standardized WebAssembly exception-handling proposal** — a
> **tag**'s operand signature, `throw` (stack-polymorphic operand match), `try_table` (result-typed
> body + per-catch-clause label typing), `throw_ref` (stack-polymorphic `exnref` pop), and **`exnref`
> as a value type**. Fail-closed on every ill-typed EH construct.

---

## Context

`validate.gleam` is the **security boundary** (overview D4/D9, J5). Its input AST is populated by
`frontend/wasm/decode.gleam` from **UNTRUSTED** bytes; everything downstream — `lower` (P7-05),
`emit_core` (P7-06), `rt_exn`/`rt_trap` (P7-07), the Porffor host shim (P7-08) — *trusts* that a module
which validated is well-typed, so it emits straight-line Core Erlang `try`/`catch`/`raise` with **no
re-checks**. Phase 1 shipped a faithful transcription of the spec's abstract stack-typing algorithm;
Phases 2/5/6 extended it to the full WebAssembly-2.0 surface (reference types, bulk memory, multi-
memory, memory64 typing, SIMD, cross-module imports). Phase 7 adds the **exception-handling** surface —
the load-bearing engine feature (J1), because **Porffor throws pervasively** (measured: a `(tag (param
f64 i32))` carrying the thrown JS value; a `throw` on every JS error path; a structured try/catch for
JS `try`/`catch`) and it is the **single WASM feature Phase 6 did not cover** (PORFFOR-ABI-FINDINGS).

The exception-handling proposal (the *modern*, standardized surface — tags, `throw`, `throw_ref`,
`try_table`, the `exn` heap type — **not** the legacy `try`/`catch`/`delegate`/`rethrow`) adds a small,
spec-clean set of typing rules that the abstract-stack algorithm absorbs with **zero** machinery change
beyond one new value type on the stack and one new module-level index space (tags). Specifically:

- **`exnref` as a first-class value type** — the reference type `(ref null exn)`, binary shorthand byte
  **`0x69`** (verified: it appears in a functype as `… 7e 69` — an `i64` then an `exnref` result). It is
  a **reference type** (a third reftype alongside `funcref`/`externref`): permitted by **typed
  `select (ref null exn)`**, rejected by **untyped `select`** (a reftype, not a number/vector — §C.3),
  accepted by **`ref.is_null`** (it is nullable — §C.4), and carried **opaquely** (J5: a caught-
  exception handle, forge-proof via `rt_ref`, never inspected at this layer).
- **Tag declarations** — a tag's type is a `functype` **`[t*] -> []`** (operands in, **no results**);
  the tag section (**binary section id `13`**) is a vector of `attribute(0x00) typeidx` (verified:
  `0d 03 01 00 00` = section 13, 3 bytes, 1 tag, attribute `0x00`, typeidx `0x00`). A tag whose
  referenced type has **non-empty results** is ill-typed (§D).
- **`throw x`** (opcode **`0x08`**) — pops the operand types of tag `x` and is **stack-polymorphic**
  (like `unreachable`/`br`/`return`): it does **not** push (§E).
- **`throw_ref`** (opcode **`0x0A`**) — pops an `exnref` and is **stack-polymorphic** (§E).
- **`try_table bt catch*`** (opcode **`0x1F`**) — a **structured control opener** (like `block`): its
  body is typed against the blocktype `[t1*] -> [t2*]`, and each of its **catch clauses** constrains a
  **target label** to accept the caught tag's operand types (plus an `exnref` for the `_ref` variants).
  The four catch-clause kinds are `catch`=`0x00`, `catch_ref`=`0x01`, `catch_all`=`0x02`,
  `catch_all_ref`=`0x03` (verified: `1f 7f 02 01 00 00 03 00` = try_table, blocktype `i32`, 2 catches:
  `catch_ref`(0x01) tag 0 label 0, then `catch_all_ref`(0x03) label 0) (§F).

The validator gates **independently of the IR**: an EH-ill-typed module must be rejected here even if
the backend would coincidentally produce something. Every ill-typed EH fixture must be rejected with a
**spec-cited** `ValidateError`; the worst case of a tag / operand / label bug must be a wrong/missing
*validation* rejection, **never** a host escape or an ambient `apply` of an attacker term (J5/D3a).
Because `rt_exn`/`emit_core` emit a Core Erlang `try` that trusts the tag/operand/label typing, this
boundary is what makes the EH runtime sound.

## Goal

Extend the abstract-stack validator to the exception-handling proposal so that (a) every well-typed EH
module is accepted and (b) every ill-typed one is rejected with the `ValidateError` the spec rule
demands — **without** touching the polymorphic-stack / label algorithm or any Phase-1…6 typing arm.
A measurable outcome: the proposal's spec-suite files (`tag.wast`, `throw.wast`, `throw_ref.wast`,
`try_table.wast` — the `assert_invalid` corpora across all four — where `wast2json`-able at the pin, or
an authored in-scope proof where not) land on this validator and go **green** (accepted when valid;
rejected for the spec-correct reason when invalid — never silently skipped); and a Phase-1…6 module
with **no tag section and no EH instruction** validates **byte-identically** (conformance-neutral by
default, J6).

## Files owned

| File | Action |
|---|---|
| `src/twocore/frontend/wasm/validate.gleam` | **EXTEND** (single-owner; AST-only — the security boundary). |
| `test/twocore/frontend/wasm/validate_test.gleam` | **EXTEND** — spec-cited acceptance + rejection tests for tags / `throw` / `try_table` / `throw_ref` / `exnref` + a conformance-neutrality confirmation set. |

No other file. This unit imports `twocore/frontend/wasm/ast` **only** (grep-proven: **no `twocore/ir`
import**), so its conformance gates independently of the backend, `rt_exn`, and the Porffor shim.

## Deliverables & freeze milestones

This unit produces **no** cross-unit freeze milestone of its own — it is a *consumer* of `«WASM-AST5»`
and a *producer* of the extended `TypedModule` that **P7-05 (lower)** consumes. It must **confirm the
`TypedModule` + `ValidateError` + `Ctx` shapes early** (a mini-freeze, day 1 of Wave A) so P7-05 can
target them. Deliverables:

1. Two new `ValidateError` variants — `UnknownTag(index)` and `BadTagType` (§B.1) — additive; every
   Phase-1…6 variant kept verbatim.
2. `exnref` absorbed as a value type on the abstract stack, with the `is_reftype` / `select` /
   `ref.is_null` interactions confirmed (§C).
3. The tag index space (`imports ++ defined`) resolved + typed at module setup, with the **`[t*] -> []`
   empty-results** rule enforced (§D).
4. Per-instruction EH typing (§E/§F) transcribed from the exception-handling proposal, each spec-cited,
   routed through explicit arms **before** the numeric fallthrough (fail-closed, §H).
5. `TypedModule` gains `tag_types` + `imported_tag_count` for lowering (§B.3).
6. Spec-cited acceptance + rejection tests (§Verification).

## Depends on (freeze milestones)

- **`«WASM-AST5»`** (P7-03 decode, published day 1) — the extended `frontend/wasm/ast.gleam`: the
  `ExnRef` value type (byte `0x69`); the tag section (`Module.tags`, imported/exported tags); and the
  EH instruction surface (`Throw`, `ThrowRef`, `TryTable` + its `CatchClause` list). **Stub against it
  meanwhile** — P7-03 owns the *exact* spelling. Write the typing rules keyed by the spec **rule +
  clause kind**; if P7-03's constructor names differ, only the `case` patterns change, not the rules.
  §A is this unit's precise expectation of that shape — the seam to reconcile with P7-03.
- **`«EH-IR-FROZEN»` is NOT a dependency** (AST-only boundary). The IR-side `TExnRef`, the
  `Throw`/`TryTable`/`ThrowRef` `Expr` nodes, and the effect classification (barriers) are the
  keystone's (P7-01); lowering to them is P7-05's. This unit reads the AST, never the IR.

## Scope — in / out for Phase 7

**In:** `exnref` as a value type on the abstract stack + its `is_reftype`/`select`/`ref.is_null`/
blocktype/global/local interactions; the tag index space (`imports ++ defined`) + the `[t*] -> []`
empty-results tag-type rule; `throw x` (operand-type match + stack-polymorphic); `throw_ref` (pop
`exnref` + stack-polymorphic); `try_table bt catch*` (blocktype-typed body reusing the block/label
machinery + per-catch-clause label typing for all four clause kinds); the cross-module / imported-tag
typing boundary documentation.

**Out (defer — state it, don't drop it):**
- **The legacy exception-handling proposal** (`try`/`catch`/`catch_all`/`delegate`/`rethrow` —
  opcodes `0x06`/`0x07`/`0x19`/`0x18`/`0x09`). The modern proposal *replaced* it; this unit types the
  **modern `try_table`** surface only (J1/J2). **⚠ MEASURED SEAM:** the Porffor 0.61.13 build in this
  environment emits the **legacy** form (`try`/`catch`/`end` — opcode `0x06`/`0x07`, verified via
  `wasm-tools print`), *not* `try_table`. This must be reconciled with P7-03 (decode) **before**
  building — see **Deviation D1** + the cross-unit flags. This unit specs the modern typing per the
  task mandate; if legacy typing is later required it is a **contingency arm** scoped in D1, not a
  default.
- **`exnref` in tables / globals as a general capability.** The proposal permits `exnref` valtypes in
  most positions; Porffor never emits an `exnref` table or global. This unit types `exnref` *generically*
  where it flows (locals, params, results, blocktypes, `select`, `ref.is_null`); whether decode admits
  an `exnref` table element / global type is a **decode/type-grammar** concern (P7-03). A `ref.null exn`
  const-expr, if decode emits it, flows through the existing `RefNull` arm (§C.4) with no new code.
- **The runtime exception term shape + the forge-proof `exnref` handle** — the `{wasm_exn, TagId,
  Payload}` build-controlled term, `raise`/`catch`/re-raise, and the opaque caught-exception handle
  (reusing `rt_ref`) are **P7-01/06/07**'s. This unit only *types* the operands/labels; the term and
  its D3a-clean routing are the runtime's (§H, do not double-own).
- **Import *satisfaction* of a tag** — whether a *provided* tag actually matches the declared tag type
  (the fail-closed link-time check) is **P7-08 (Porffor shim) / the linker**'s, not validation's. This
  unit types the import *shape* (the declared `[t*] -> []` in the tag index space); the *satisfaction*
  is downstream (§G).
- **All runtime trap / unwind behaviour** (an uncaught `throw` propagating out as a BEAM exception, a
  `throw_ref` of a **null** `exnref` trapping, constant-space unwinding, preemption across a throw) is
  **dynamic**, not validation. `throw_ref null` traps at runtime; validate only types the `exnref` pop.
- **GC-proposal reference types / stack-switching / the component model** — unchanged from Phase 6
  (still deferred / categorized-skip).

---

## A. The `«WASM-AST5»` surface this unit consumes (the P7-03 seam)

This is the **precise shape** the typing rules below assume. P7-03 owns the final spelling; where a
name is provisional it is flagged. If P7-03 diverges, keep the *rules* and re-map the `case` patterns.

### A.1 `exnref` as a value type

```gleam
// ast.gleam — ValType gains ONE constructor (byte-identical for non-EH modules):
pub type ValType {
  I32  I64  F32  F64
  V128
  FuncRef  ExternRef
  ExnRef          // NEW — 0x69, the reference type (ref null exn) (EH proposal)
}
```

`exnref` is the **third reference type** (`funcref`=`0x70`, `externref`=`0x6F`, `exnref`=`0x69`), a
`reftype` in the spec's value-type classification
([EH proposal — reference types](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md);
core-spec `syntax/types`). The classification matters for exactly three existing typing rules —
**`is_reftype`**, **untyped `select`**, and **`ref.is_null`** (§C) — where `exnref` behaves like any
reference type. Everywhere else it is just another `ValType` on the abstract stack (no machinery
change).

> **Cross-unit seam.** `ExnRef` on `ast.ValType` breaks every exhaustive `case` on `ast.ValType`
> across the frontend (exactly as `V128` did in Phase 6). P7-03 owns the AST-side addition and its byte
> `0x69`; the IR-side `TExnRef` is P7-01's. This unit only *reads* the AST `ExnRef`, and adds it to its
> own `is_reftype` predicate (§C.2).

### A.2 The tag surface (module level)

```gleam
// ast.gleam — a defined tag declares the type index of its operand signature.
pub type TagDecl {
  TagDecl(type_idx: Int)      // attribute 0x00 (exception); type_idx → module.types[type_idx]
}

// Module gains a tags vector (defined tags, in section order):
pub type Module {
  Module(
    // …every Phase-1..6 field verbatim…
    tags: List(TagDecl),      // NEW — the tag section (binary id 13)
    // …
  )
}

// ImportDesc gains the tag import kind (0x04); ExportKind gains the tag export kind (0x04):
pub type ImportDesc {
  ImportFunc(type_idx: Int)  ImportTable(TableType)  ImportMemory(MemType)
  ImportGlobal(ty: ValType, mutable: Bool)
  ImportTag(type_idx: Int)   // NEW — 0x04, an imported exception tag
}
pub type ExportKind { ExportFunc  ExportTable  ExportMemory  ExportGlobal  ExportTag /* NEW 0x04 */ }
```

A tag's `attribute` byte is always `0x00` (the *exception* attribute — the only one standardized);
decode rejects a non-zero attribute (its concern). The tag's operand types are `module.types[type_idx]`'s
**params**; its **results must be empty** (§D).

### A.3 The EH instruction surface

**RECOMMENDED shape (a strong recommendation to P7-03):** model `try_table` as a **structured control
opener** (like `Block`/`Loop`/`If`) whose body is the flat instruction stream up to the matching `End`,
carrying its catch clauses as an immediate. This reuses **all** of the existing control-frame /
label machinery (§F) — the same idiom that made SIMD's fail-closed dispatch a compiler invariant in
Phase 6.

```gleam
// ast.gleam — Instr gains THREE constructors (grouped with the Phase-1 control block):
pub type Instr {
  // …existing Phase-1..6 instructions, verbatim…
  Throw(tag: Int)                                   // 0x08 <tagidx>
  ThrowRef                                          // 0x0A
  TryTable(bt: BlockType, catches: List(CatchClause))  // 0x1F <blocktype> <vec(catch)> … End
}

/// One catch clause of a try_table (spec EH proposal, binary `catch` encoding).
/// The label indices resolve in the ENCLOSING label context (§F.2).
pub type CatchClause {
  Catch(tag: Int, label: Int)        // 0x00 — on tag: branch to label with the tag operands
  CatchRef(tag: Int, label: Int)     // 0x01 — …with the tag operands ++ an exnref
  CatchAll(label: Int)               // 0x02 — on any exception: branch to label with no operands
  CatchAllRef(label: Int)            // 0x03 — …with just an exnref
}
```

`TryTable` opens a frame; its body instructions follow in `Func.body`; the matching `End` (`0x0B`)
closes it — **identical** to `Block`. `Throw`/`ThrowRef` are ordinary leaf instructions. This is the
minimal, D6-neutral surface: three `Instr` constructors + one `CatchClause` enum, no bespoke control
machinery. (Contrast: a "flat" surface with a dedicated `TryTableEnd` marker would work too but buys
nothing — `End` already delimits every structured opener.)

### A.4 Unchanged from `«WASM-AST4»`

`BlockType`, `MemArg`, `FuncType`, `IdxType`, the import/export/segment shapes, and every scalar/SIMD
instruction constructor are consumed **verbatim** from Phase 6. This unit adds no requirement on them.

---

## B. `ValidateError`, `Ctx`, and `TypedModule` — the (minimal) Phase-7 delta

### B.1 `ValidateError` — two new variants (additive; keep every Phase-1…6 variant)

```gleam
pub type ValidateError {
  // … every Phase-1..6 variant kept verbatim: TypeMismatch, Underflow, UnknownLocal,
  //   UnknownGlobal, UnknownFunc, UnknownType, UnknownLabel, UnknownMemory, UnknownTable,
  //   ImmutableGlobal, BadAlignment, NonConstantExpr, BadLimits, TooManyMemories,
  //   TooManyTables, BadStartType, BranchArityMismatch, IfElseMismatch, UnexpectedEnd,
  //   TooManyLocals, Unsupported, OffsetOutOfRange, UnknownData, UnknownElem,
  //   UndeclaredFunctionRef, RefTypeMismatch, BadSelectType, UnknownImportKind, BadLaneIndex …
  UnknownTag(index: Int)      // NEW — a throw/try_table catch tagidx out of range
  BadTagType                  // NEW — a tag whose type has non-empty results ([t*] -> [r+])
}
```

Notes on variant choice (spec-honest, diagnosable):

- **`UnknownTag(index)` is the tag-index-out-of-range rejection.** It fires when a `throw x` or a
  `catch x l` / `catch_ref x l` clause names a `tagidx` past the module's tag index space (imports ++
  defined). It carries the offending index for diagnosis. Analogous to `UnknownFunc`/`UnknownMemory`/
  `UnknownTable` — the spec requires `C.tags[x]` to exist
  ([EH proposal — `throw`/`try_table` validation](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md)).
  Distinct from `UnknownType` (which is a *tag's* out-of-range typeidx at module setup — a declaration
  error, §D — versus a *use-site* out-of-range tagidx).
- **`BadTagType` is the "tag type has results" rejection.** The EH proposal requires a tag's type to be
  `[t*] -> []` — **empty results** (an exception carries operands, never returns). A tag whose
  `module.types[type_idx]` has a non-empty result list is invalid → `BadTagType`. Analogous to
  `BadStartType` (the start function's `[] -> []` rule). It carries no index (like `BadTagType`'s
  sibling `BadStartType`); a diagnostic index could be added but the conformance runner asserts *a*
  rejection, never message text.
- **No new variant for a catch-clause label mismatch.** A `catch`/`catch_ref`/`catch_all`/
  `catch_all_ref` whose **target label's types do not match** the required catch-type (the tag operands,
  plus an `exnref` for the `_ref` variants) is rejected with the **existing** vocabulary: a wrong
  **arity** → `BranchArityMismatch` (the same variant `br_table` uses for a target-arity disagreement),
  a wrong **element type** → `TypeMismatch`. This is spec-honest — a catch-label disagreement *is* a
  branch-target type/arity mismatch — and keeps the error surface lean (the Phase-6 precedent: reuse an
  existing variant where the failure is fundamentally the same kind).
- **No new variant for `exnref` operand disagreements.** A `throw_ref` fed a non-`exnref`, or an
  `exnref` where a number is wanted, is a plain `TypeMismatch` — `exnref` is just a `ValType`;
  `pop_expect` produces it uniformly. There is nothing about `exnref` that would want `RefTypeMismatch`
  (which stays reserved for `table.init`/`table.copy`/active-elem/`call_indirect` reftype disagreements).
- **`Unsupported(detail)` covers the deferred legacy EH.** If a legacy `try`/`catch`/`delegate`/
  `rethrow` ever reaches this validator (it should be decoder-rejected — see D1), it is rejected
  `Unsupported("legacy-eh")`, never waved through.

### B.2 `Ctx` — one new field (the tag index space)

The Phase-6 `Ctx` (types, func_types, globals, imported_global_count, tables, memories, data_count,
elem_types, refs, locals) gains **one** field:

```gleam
type Ctx {
  Ctx(
    // …every Phase-6 field verbatim…
    tags: List(List(ValType)),   // NEW — the operand types of each tag by tagidx (imports ++ defined)
  )
}
```

`ctx.tags` is the **operand-type list** of every tag by `tagidx`, built `imports ++ defined` (imports
occupy the low tagidx slots, spec `valid/modules`), each resolved from its `type_idx` at module setup
**and verified to have empty results** (§D). A `throw x` / `catch x l` reads `ctx.tags[x]` for the tag's
operands. For a tag-free module `tags = []` (byte-identical to Phase 6).

### B.3 `TypedModule` — two new fields (a conformance-neutrality result)

```gleam
pub type TypedModule {
  TypedModule(
    // …every Phase-6 field verbatim…
    imported_tag_count: Int,          // NEW — the tagidx offset (imported tags precede defined)
    tag_types: List(List(ValType)),   // NEW — operand types per tagidx (imports ++ defined)
  )
}
```

- **`imported_tag_count`** — the number of *imported* tags (the offset at which defined tags begin in
  the tag index space). `0` for a module with no imported tags (byte-identical). P7-05 (lower) reads it
  to route a `throw`/catch tagidx into the imports-first tag space; P7-07/08 read it to bind imported
  tags to their linked runtime tag identity.
- **`tag_types`** — the operand types per `tagidx`, which lowering reads to build the exception term's
  payload shape (the `Payload` in `{wasm_exn, TagId, Payload}`) and `emit_core` reads to pattern-match
  a caught tag's operands onto the catch label's values. This is the one EH typing fact lowering cannot
  trivially re-derive from the instruction alone (a `throw x` names only `x`), so it is carried here,
  exactly as `global_types` is carried for `global.set`.

**Headline conformance-neutrality fact for validate:** a module with **no tag section and no EH
instruction** produces a `TypedModule` with `imported_tag_count = 0`, `tag_types = []` and is
otherwise **structurally identical** to Phase 6 — the EH path is never entered (J6). New fields default
to empty; existing fields are untouched (the same additive discipline P5/P6 used).

---

## C. `exnref` as a value type — the abstract stack & existing-rule interactions

Spec: [`syntax/types` — Value Types](https://webassembly.github.io/spec/core/syntax/types.html#value-types),
the [EH proposal](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md).

### C.1 The stack machinery is untouched

`StackType` already wraps an arbitrary `ast.ValType`; `Known(ast.ExnRef)` needs no new constructor.
`push_val`/`pop_val`/`pop_expect`/`pop_vals`/`push_vals`/`types_match` all operate on `ValType`
generically, so `exnref` participates in the abstract stack, `unreachable` polymorphism, block
result-checking, and branch-arity checking with **zero** machinery change (the P5/P6 discipline of
keeping the algorithm verbatim). A `block (result exnref)`, a `br` carrying an `exnref`, an `exnref`
local (the natural landing spot for a `catch_ref`'s payload) — all validate through the existing code
the moment `ExnRef` is a `ValType`.

### C.2 `is_reftype` gains `exnref` (the one load-bearing predicate change)

```gleam
fn is_reftype(vt: ValType) -> Bool {
  case vt {
    ast.FuncRef | ast.ExternRef | ast.ExnRef -> True   // ExnRef ADDED (was FuncRef | ExternRef)
    _ -> False
  }
}
```

`exnref` **is** a reference type, so it must join `is_reftype`. This single change flows to the two
existing arms that branch on `is_reftype` — untyped `select` (§C.3) and `ref.is_null` (§C.4) — making
both spec-correct for `exnref` with no further code. This is the *only* behavioural edit to an existing
Phase-1…6 typing arm.

### C.3 Untyped `select` rejects `exnref`; typed `select (ref null exn)` accepts it

Spec [`valid/instructions` — Parametric](https://webassembly.github.io/spec/core/valid/instructions.html#parametric-instructions):
untyped `select` (0x1B) has type `[t t i32] → [t]` where **`t` is a number type or a vector type** —
**not** a reference type. `exnref` is a reference type, so **untyped `select` of two `exnref`s is
invalid** → `BadSelectType` (via the existing untyped-select arm, which rejects when `is_reftype(vt) ==
True`). A `select` of two exception references must use the **typed `select (ref null exn)`** form,
which the existing `SelectT([t])` arm accepts generically (`t = ExnRef`, `pop_expect` twice, push).
**Confirm both with tests**; write no code beyond §C.2 — the `is_reftype` update makes the existing arms
correct.

### C.4 `ref.is_null`, const-exprs, and `exnref`

- **`ref.is_null` on an `exnref` is VALID** (pops the ref, pushes `i32`). `ref.is_null` is
  reference-polymorphic: it accepts an operand that `is_reftype` (or `Unknown`). With §C.2,
  `is_reftype(ExnRef) == True`, so the existing arm accepts it — spec-correct (`exnref` is nullable, so
  a null-test is meaningful). No code change beyond §C.2; confirm with a test.
- **`ref.null exn` in a constant expression** (if decode emits it as `RefNull(ExnRef)`): the existing
  `[ast.RefNull(rt)] -> expect_const_type(rt, expected)` arm already handles it generically — a global
  of type `exnref` initialized by `ref.null exn` validates. No new const-expr arm. (Porffor never emits
  this; whether decode admits an `exnref` global at all is P7-03's type-grammar concern — §Scope-out.)
- **No EH instruction other than `ref.null exn` is a constant instruction.** `throw`/`throw_ref`/
  `try_table` are not in the const grammar → any of them in a const-expr falls to `NonConstantExpr`
  (spec-correct — the existing catch-all).

---

## D. Tag declarations — module-level typing (`[t*] -> []`) + the tag index space

Spec: [EH proposal — Tags](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md);
core-spec `valid/modules` (a tag's type is a `functype` `[t*] -> []`). Binary: the **tag section, id
`13`** (verified `0d …`), a vector of `attribute(0x00) typeidx`.

At module setup (in `validate/1`, alongside the func/global/table/memory index-space construction),
build the tag index space and validate each tag:

1. **Imported tags first.** `imported_tag_types(module)` walks `module.imports`, and for each
   `ImportTag(type_idx)` resolves `module.types[type_idx]` (→ `UnknownType(type_idx)` if out of range),
   checks its **results are empty** (→ `BadTagType`), and collects its **params** as that tag's operand
   types. Non-tag imports are skipped (they populate the other index spaces). This mirrors
   `imported_func_types`.
2. **Defined tags next.** For each `TagDecl(type_idx)` in `module.tags`, resolve + empty-results-check
   identically, collecting the params. This mirrors `resolve_func_types`.
3. **`ctx.tags = imported ++ defined`** (imports occupy the low tagidx slots — spec `valid/modules`);
   `imported_tag_count = length(imported)`; `tag_types = ctx.tags` (for `TypedModule`).

```gleam
/// The operand types of every tag (imports ++ defined), each resolved from its typeidx and
/// verified `[t*] -> []` (empty results). Error(UnknownType(_)) if a typeidx is out of range;
/// Error(BadTagType) if a tag's referenced type has a non-empty result list.
fn tag_operand_types(module: Module) -> Result(List(List(ValType)), ValidateError)
```

**The empty-results rule is the whole of tag typing.** A tag is *only* a named operand signature for an
exception; it has no results because a `throw` never returns. `tag_operand_types` is the single choke
where a bad tag is rejected; every use site (`throw`, `catch`, `catch_ref`) then trusts `ctx.tags[x]`
is a well-formed operand list. Cite `tag.wast` (its `assert_invalid` "type mismatch in tag" / non-empty-
result cases) and the spec tag-validity rule.

**Imported / exported tags — the index space, not satisfaction (§G).** Validate types the *shape* of
an imported tag (its declared `[t*] -> []` in the tag index space) and range-checks a tag export
(`ExportTag` index `< length(ctx.tags)` → else `UnknownTag`). Whether a *provided* tag matches at link
time is P7-08's (§G, do not double-own).

---

## E. `throw` and `throw_ref` — the stack-polymorphic barriers

Spec: [EH proposal — `throw` / `throw_ref`](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md).
Both are **stack-polymorphic** (they never fall through — like `unreachable`/`br`/`return`): they
consume their operands and mark the rest of the frame unreachable (the spec's `[t1* …] -> [t2*]` with
universally-quantified `t1*`/`t2*` = the bottom / polymorphic-stack marker).

### E.1 `throw x` (opcode `0x08`)

```
C.tags[x] = [t*] -> []
--------------------------------------
C ⊢ throw x : [t1* t*] -> [t2*]
```

Arm:

```gleam
ast.Throw(x) -> {
  use operands <- result.try(tag_operands(ctx, x))   // Error(UnknownTag(x)) if out of range
  use st2 <- result.try(pop_vals(st, operands))       // pop the tag's operand types (top-of-stack order)
  mark_unreachable(st2)                                // stack-polymorphic — does NOT push
}
```

`tag_operands(ctx, x)` is `nth(ctx.tags, x)` → `Error(UnknownTag(x))`. `pop_vals` checks the operands
match the tag's declared types (wrong type → `TypeMismatch`; missing → `Underflow`); `mark_unreachable`
makes the rest of the block polymorphic (a `throw` is a bottom). Cite `throw.wast` (its `assert_invalid`
"type mismatch"/"unknown tag" cases). **Operand order:** `pop_vals` pops the *last* declared operand
first (top-of-stack), matching the way a `call` pops its params — the tag's operands are pushed in
declaration order and popped in reverse (assert this in a test so a reversed pop is caught).

### E.2 `throw_ref` (opcode `0x0A`)

```
--------------------------------------
C ⊢ throw_ref : [t1* exnref] -> [t2*]
```

Arm:

```gleam
ast.ThrowRef -> {
  use st2 <- result.try(pop_expect(st, ast.ExnRef))   // pop the caught-exception reference
  mark_unreachable(st2)                                 // stack-polymorphic
}
```

Pops one `exnref` (a non-`exnref` → `TypeMismatch`; empty stack → `Underflow`), then bottom. The null-
`exnref` **trap** is a *runtime* semantics (P7-07), not validation — `throw_ref null` type-checks and
traps at run time. Cite `throw_ref.wast` (its `assert_invalid` type-mismatch cases).

---

## F. `try_table` — the blocktype-typed body + per-catch-clause label typing (the heart)

Spec: [EH proposal — `try_table`](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md).
`try_table` is a **structured control opener** (like `block`): its body is typed against the blocktype,
and its label targets its **result** types (like `block`, **not** `loop`). Its distinguishing content
is the catch clauses, each of which constrains a **branch-target label**.

```
C.types[bt] = [t1*] -> [t2*]
(for each catch clause: the clause is valid — §F.1)
C, label [t2*] ⊢ instr* : [t1*] -> [t2*]
------------------------------------------------------
C ⊢ try_table bt catch* instr* : [t1*] -> [t2*]
```

### F.1 The four catch-clause typing rules

Each clause names a tag (for the non-`all` kinds) and a **target label** that the caught exception
branches to. The clause is valid iff the label's types **equal** the *catch-type* — the values the
handler receives:

| clause (kind byte) | tag constraint | required `label_types(l)` (the catch-type) |
|---|---|---|
| `catch x l` (`0x00`) | `C.tags[x] = [t*] -> []` | `[t*]` (the tag's operands) |
| `catch_ref x l` (`0x01`) | `C.tags[x] = [t*] -> []` | `[t* exnref]` (operands, then an `exnref` on top) |
| `catch_all l` (`0x02`) | — | `[]` (no operands) |
| `catch_all_ref l` (`0x03`) | — | `[exnref]` (just an `exnref`) |

Verified against real bytes: `1f 7f 02 01 00 00 03 00` = `try_table` (blocktype `i32`), 2 catches:
`catch_ref`(`0x01`) tag 0 label 0, `catch_all_ref`(`0x03`) label 0 — where label 0 was a `block (result
i32 i64 exnref)`, i.e. the tag's `[i32 i64]` operands **then** an `exnref` on top (the `catch_ref`
catch-type), confirming the operand-then-exnref order.

Because 2core's MVP has **no GC subtyping** (the value types `{i32,i64,f32,f64,v128,funcref,externref,
exnref}` are pairwise-incomparable except through `Unknown`), the label match is **exact structural
equality** of the type list — a supertype rule is unnecessary. A helper:

```gleam
/// A catch clause's target label must have types EXACTLY equal to `required` (the catch-type).
/// A wrong arity → BranchArityMismatch (as br_table); a wrong element type → TypeMismatch.
fn check_catch_label(st: VState, label: Int, required: List(ValType)) -> Result(Nil, ValidateError) {
  use frame <- result.try(label_frame(st, label))     // Error(UnknownLabel(label)) if out of range
  let lt = label_types(frame)
  case list.length(lt) == list.length(required) {
    False -> Error(BranchArityMismatch)
    True ->
      case lt == required {
        True -> Ok(Nil)
        False -> Error(TypeMismatch)
      }
  }
}
```

### F.2 The label context — resolve catches BEFORE pushing the try_table frame (a load-bearing subtlety)

The catch-clause label indices resolve in **`C`** — the label context **at the `try_table`**, i.e.
**before** the try_table's own label is pushed for its body. So `catch x 0` targets the innermost
**enclosing** block, **not** the try_table itself. In implementation, validate the catch clauses
against the **current** `st.ctrls` (before `push_ctrl`), then pop the blocktype params and push the
frame. Getting this wrong (resolving catch labels against the post-push stack) shifts every catch label
by one — a silent mis-typing; **assert the timing in a test** (a `catch` whose label is the enclosing
block, verified to type against *that* block's results).

### F.3 The `TryTable` arm

```gleam
ast.TryTable(bt, catches) -> {
  use #(in_t, out_t) <- result.try(blocktype_types(bt, ctx.types))
  // (1) validate each catch clause against the CURRENT label context (§F.2) — BEFORE push_ctrl
  use _ <- result.try(list.try_each(catches, fn(c) { check_catch(st, ctx, c) }))
  // (2) enter the body: pop the blocktype params, push a block-like frame whose label = out_t
  use st2 <- result.try(pop_vals(st, in_t))
  Ok(push_ctrl(st2, KBlock, in_t, out_t))
}
```

with `check_catch` dispatching the four clause kinds to `check_catch_label` with the right catch-type:

```gleam
fn check_catch(st, ctx, c: CatchClause) -> Result(Nil, ValidateError) {
  case c {
    ast.Catch(x, l)      -> { use ops <- result.try(tag_operands(ctx, x)); check_catch_label(st, l, ops) }
    ast.CatchRef(x, l)   -> { use ops <- result.try(tag_operands(ctx, x))
                              check_catch_label(st, l, list.append(ops, [ast.ExnRef])) }
    ast.CatchAll(l)      -> check_catch_label(st, l, [])
    ast.CatchAllRef(l)   -> check_catch_label(st, l, [ast.ExnRef])
  }
}
```

- **The frame is `KBlock`, not a new `KTry` kind.** `try_table`'s label targets its **result** types
  (`out_t`) — identical to `block` (`label_types(KBlock) = end_types`). Its `End` behaves exactly like a
  `block`'s `End` (produce `out_t`, pop the frame). It needs *no* else-less-`if` check (only `KIf`
  triggers that) and *no* per-frame state (the catches are fully validated at the opener). So reusing
  `KBlock` is spec-correct and touches **neither** `label_types` **nor** the `End` arm. (A dedicated
  `KTry` FrameKind that aliases `KBlock` would be equivalent but is unnecessary; reuse keeps the change
  minimal.)
- **The body then validates through the existing instruction loop** with `out_t` as its label —
  `unreachable`/`br`/nested `try_table`/`throw` all compose through the existing machinery. Nested
  try/catch unwinds correctly because each `try_table` pushes its own frame and `throw`/`throw_ref` mark
  the enclosing frame polymorphic — exactly as `unreachable` does.

Cite `try_table.wast` (its `assert_invalid` corpus: unknown tag, label-type mismatch, arity mismatch,
missing/extra `exnref` on a `_ref` clause, out-of-range label) + the spec `try_table` rule.

---

## G. Cross-module / imported-tag typing — the declared `[t*] -> []` boundary

Spec: [`valid/modules` — Imports](https://webassembly.github.io/spec/core/valid/modules.html#imports).
Phase 7 adds imported tags (Porffor's own tag may be imported/exported across the JS↔host boundary), but
the **typing is a straightforward extension of the P5 import pattern** and is stated here so the
boundary is explicit and not double-owned.

- **An imported tag types against its *declared* type.** `imported_tag_types` resolves each
  `ImportTag(type_idx)` against `module.types` (→ `UnknownType` if out of range; `BadTagType` if
  non-empty results) and places it in the low tagidx slots. A `throw x` / `catch x l` where `x`
  addresses an imported tag type-checks against `ctx.tags[x]` — the import's declared operands — via
  the same §E/§F arms. **Complete and uniform.**
- **Validation does not check import *satisfaction*.** Whether a *provided* tag actually matches the
  declared type — the fail-closed link-time check — is **P7-08 (Porffor shim) / the linker**'s, not
  validation's. A module that imports a tag no other module provides still **type-checks** against its
  declared import type; the *link* fails, not validation. **Seam:** validate owns the *shape* (the
  declared `[t*] -> []` in the tag index space), P7-08 owns the *satisfaction*. This mirrors the P5/P6
  function-import seam (§G there), now extended to tags.
- **What the linker consumes from `TypedModule`** (all present after this unit): `module.imports` (the
  `ImportTag(type_idx)` descriptors), `imported_tag_count` (the tagidx offset), and `tag_types`
  (imports-first, so `list.take(tag_types, imported_tag_count)` is the imported tags' operand
  signatures in order). **No further `TypedModule` field is needed.**

---

## H. Effect / soundness / security note (J5 / D3a)

- **Fail-closed is the whole point — and EH keeps it structural.** Every EH `Instr` constructor
  (`Throw`, `ThrowRef`, `TryTable`) has an **explicit arm in `validate_instr` before the `numeric_sig`
  fallthrough** (the same S1 fail-closed invariant Phase 6 established for SIMD: `numeric_sig`'s
  `_ -> #([], [])` catch-all would silently accept an un-intercepted instruction as a typed no-op — a
  fail-*open* hole). A `throw`/`throw_ref`/`try_table` must **never** reach `numeric_sig`. Grep-verify
  the three arms exist ahead of the fallthrough. `tag_operand_types`/`check_catch` are total — a bad
  tag/label/operand is a typed `Error`, never a wave-through.
- **A thrown value is a *term*, never authority (D3a).** Validate types the tag's operands and the
  catch labels; the *shape* of the thrown BEAM term (`{wasm_exn, TagId, Payload}`, build-controlled) and
  its routing through `rt_exn`/`rt_trap` (a `raise` of a build-fixed term, a `catch` that matches the
  tag, a re-raise of a non-match) are the runtime's (P7-06/07). There is **no ambient `apply` of an
  attacker-named target** anywhere on the EH path — a `throw`/`catch`/`throw_ref` is a structured term
  operation, not a call. This unit's contribution to D3a: it guarantees the operands the runtime packs
  into `Payload` are the tag's *declared* types (so the term shape is statically known), and that a
  catch label receives *exactly* the declared operands (+ opaque `exnref`) — the runtime never has to
  re-derive or trust attacker-supplied shapes.
- **`exnref` is opaque + forge-proof (J5).** A caught `exnref` is a reference value — Safe code can
  re-throw it (`throw_ref`) or null-test it (`ref.is_null`) but **cannot inspect or forge** the
  underlying BEAM exception term (P7-07 reuses the `rt_ref` forge-proof model, like `externref`).
  Validate enforces the *type* boundary: an `exnref` only ever flows where the type system permits (a
  `catch_ref` payload, a `throw_ref` operand, a local/param/result/`select` of `exnref`) — it can never
  be conjured from a number or a memory read at this layer.
- **EH does not weaken the sandbox.** An uncaught `throw` becomes a BEAM exception the instance boundary
  contains (one-instance-one-process); it cannot escape to another instance or the node, and metering/
  fuel still bites across a throw (P7-06/07). Validate's job is only to guarantee the *typed* precondition
  those runtime invariants rely on.
- **Total.** `validate` never `panic`s / `let assert`s / diverges on any decodable AST — a decodable-
  but-ill-typed EH module (an unknown tag, a non-empty-result tag, a wrong `throw` operand, a mismatched
  catch label, a non-`exnref` `throw_ref`) is a typed `Error`, fail-closed.

---

## Verification — Definition of Done (spec-cited tests)

Tests assert the **spec rule** (the EH proposal's validation), not the implementation (no change-
detector tests). Cite the proposal section / `.wast` file each test encodes. Fixtures: valid `.wasm`
via `wat2wasm --enable-exceptions` / `wast2json` (or hand-built `ast.Module` values, as the Phase-6
SIMD tests do); invalid-but-decodable via `wat2wasm --no-check` (decode succeeds; only typing fails).
Keep the Phase-1…6 suite green (regression).

**Acceptance (must be `Ok`, and carry a correct `TypedModule`):**
- a module with a `(tag (param i32 i64))` (type `[i32 i64] -> []`) — accepted, `tag_types = [[i32,
  i64]]` (spec tag rule; `tag.wast`).
- `throw x` popping the tag's operands then falling through as bottom: a function `(param i32 i64)
  (result f64)` whose body is `local.get 0` `local.get 1` `throw 0` — accepted (the missing `f64`
  result is fine because `throw` is stack-polymorphic) (`throw.wast`, spec `throw` rule).
- `try_table (result i32) (catch 0 $l) … end` where `$l` is a `block (result i32 i64)` (tag 0's
  operands) — accepted; the body produces the try_table's `i32` result (`try_table.wast`, spec
  `try_table` rule).
- `catch_ref 0 $l` where `$l` is a `block (result i32 i64 exnref)` (operands **then** `exnref`) —
  accepted (the operand-then-exnref order; `try_table.wast`).
- `catch_all $l` where `$l` is a `block` (empty result); `catch_all_ref $l` where `$l` is a `block
  (result exnref)` — accepted (`try_table.wast`).
- `throw_ref` popping an `exnref`: a `block (result exnref)` … `throw_ref` — accepted, stack-polymorphic
  (`throw_ref.wast`, spec `throw_ref` rule).
- **`exnref` as a value type:** a function with an `exnref` param/local/result; a `block (result
  exnref)`; a `br` carrying an `exnref` — all accepted (generic stack, no EH-specific machinery).
- **typed `select (ref null exn)` of two `exnref`s** — accepted (a reference type via the typed form;
  spec parametric rule).
- **`ref.is_null` on an `exnref`** — accepted (`exnref` is nullable; spec `ref.is_null` rule).
- an **imported tag** `(import "" "e" (tag (param f64 i32)))` used by `throw 0` — the import types into
  the tag space and `throw` checks against the declared `[f64 i32]` (spec imports; the Porffor-ABI
  `(tag (param f64 i32))` shape from PORFFOR-ABI-FINDINGS).
- **nested `try_table`** — an inner `try_table` whose `catch` targets an *outer* block's label — accepted
  (label-context resolution, §F.2).

**Rejection (must be the cited `Error`):**
- `BadTagType` — a `(tag)` whose type is `[i32] -> [i32]` (non-empty results) — spec tag rule ("a tag
  type is `[t*] -> []`"); `tag.wast` `assert_invalid`.
- `UnknownTag` — `throw 5` / `catch 5 $l` with only 1 tag declared (tagidx out of range) — spec
  `C.tags[x]` must exist; `throw.wast` / `try_table.wast` `assert_invalid`.
- `UnknownType` — a `(tag (type 9))` whose typeidx is out of range (a *declaration* error, distinct from
  `UnknownTag`) — spec tag rule.
- `TypeMismatch` — `throw 0` fed the wrong operand types (tag wants `[i32 i64]`, given `[f32 f64]`); a
  `throw_ref` fed a non-`exnref` (e.g. an `i32`); a `catch_ref` clause whose label element types
  disagree (label `[i32 f64 exnref]` for a tag `[i32 i64]`) — spec `throw`/`throw_ref`/`try_table`
  rules; the respective `.wast` type-mismatch cases.
- `BranchArityMismatch` — a `catch 0 $l` whose label `$l` has the **wrong arity** for the tag's operands
  (label `[i32]` for a tag `[i32 i64]`); a `catch_ref` whose label is **missing the `exnref`** (label
  `[i32 i64]` where `[i32 i64 exnref]` is required); a `catch_all` whose label is non-empty — spec
  `try_table` catch-type rule; `try_table.wast` `assert_invalid`.
- `UnknownLabel` — a catch clause whose `label` exceeds the (enclosing) control-frame depth — spec
  `try_table` (the label must exist in `C`); `try_table.wast`.
- `BadSelectType` — an **untyped** `select` of two `exnref`s (a reference type is invalid for untyped
  select) — spec parametric rule; `select.wast`-style `assert_invalid`.
- `TypeMismatch` — `ref.is_null` typing is fine on `exnref`, but a `throw_ref` after `i32.const 0` (an
  `i32`, not an `exnref`) rejects — spec `throw_ref` rule.

**Properties:**
- **AST-only:** grep the source to prove **no `twocore/ir` import** (gates independently of the backend,
  `rt_exn`, and the Porffor shim).
- **Total / fail-closed:** never panics / `let assert`s / diverges on any decodable AST (fuzz the EH
  arms — a hostile tagidx, a wrong operand, a mismatched/out-of-range catch label, a non-`exnref`
  `throw_ref`, a non-empty-result tag all produce a typed `Error`). **Prove no EH op is silently
  accepted:** the three EH `Instr` arms precede the `numeric_sig` fallthrough (grep-assert), so a
  `throw`/`throw_ref`/`try_table` can never be waved through as a no-op (§H).
- **`throw` operand pop order** — a test whose tag is `[i32 i64]` and whose `throw` is fed `i64.const`
  then `i32.const` (reversed) **rejects** `TypeMismatch` (guards a reversed `pop_vals`).
- **catch label-context timing (§F.2)** — a `try_table` whose `catch`'s label is the enclosing block,
  accepted; the *same* structure where the label is mis-resolved would type against the try_table's own
  results and fail — asserts the resolve-before-push order.
- **Conformance-neutral (J6):** a Phase-1…6 module (no tag section, no EH instruction) validates
  **identically** — assert a Phase-6 fixture's `TypedModule` has `imported_tag_count = 0`, `tag_types =
  []` and is otherwise the same shape (the EH path is never entered). This is the headline neutrality
  proof.
- `gleam format --check src test` clean; `gleam build` **zero warnings**; `gleam test` green (≥ the
  current count; the manager gates conformance `fail=0`).

**Prove the boundary end-to-end:** the conformance harness routes `assert_invalid` → `check_frontend`
(decode + validate). So the negative corpora from `tag.wast`/`throw.wast`/`throw_ref.wast`/
`try_table.wast` (where `wast2json`-able at the pin — the P7-09/capstone audit confirms per file) flow
here automatically; validate's rejection is what makes each `assert_invalid` pass. **This** unit's job
is that the rejections are **spec-correct** so those assertions go green (not silently skipped).

---

## What this unit leaves for others

- **P7-01 (keystone)** owns the IR-side `TExnRef`, the `Throw`/`TryTable`/`ThrowRef` `Expr` nodes + the
  effect classification (barriers), the BEAM-exception lowering contract, and the `rt_exn`/`rt_trap`
  signatures. This unit only *types* the AST; it consumes none of that.
- **P7-03 (decode)** owns `«WASM-AST5»` — the `ExnRef` byte (`0x69`), the tag section (id `13`), the
  `throw`/`throw_ref`/`try_table` opcodes + catch-clause encoding, and (the seam, D1) **which EH surface
  Porffor actually emits at the pin** (legacy vs modern). If decode normalizes legacy `try`/`catch` →
  the modern `TryTable` AST, this validator is unchanged.
- **P7-05 (lower)** consumes the extended `TypedModule` — it reads a tag's operands off `tag_types` (no
  re-derivation), maps `Throw`/`ThrowRef`/`TryTable` → the IR EH nodes, maps each catch clause → its
  label + payload binding (+ `exnref` for the `_ref` variants), and threads `imported_tag_count` for the
  tag index space. It trusts every tag/operand/label is sound (never re-validates).
- **P7-06 (emit_core)** trusts the boundary: it emits a Core Erlang `try … catch` that matches the tag
  and binds the payload to the catch label's values, re-raising a non-match; it packs the `throw`
  operands into the build-controlled `{wasm_exn, TagId, Payload}` term. The *typing* of those operands/
  labels is this unit's; the term shape + D3a-clean routing are emit_core/rt_exn's.
- **P7-07 (rt_exn)** relies on the operand-type + catch-label guarantees this boundary provides to emit
  re-check-free `raise`/match/re-raise and the forge-proof `exnref` handle (reusing `rt_ref`).
- **P7-08 (Porffor shim / link)** owns the link-time tag *satisfaction* (does a provided tag match the
  declared `[t*] -> []`?); this unit owns only the import *shape* typing (§G, do not double-own).
- **P7-09/10 (JS conformance + capstone)** add the EH `.wast` allowlist + the residual audit; document
  any `assert_invalid` this validator does not yet cover (legacy EH, `exnref` corners Porffor never
  emits) as an explicit, categorized skip.

---

## Deviations from the overview / ABI findings (argued)

- **D1 — ⚠ MEASURED: Porffor 0.61.13 emits the LEGACY `try`/`catch`, not `try_table`.** The overview
  (J1/J2) and PORFFOR-ABI-FINDINGS assert Porffor emits the *modern* `try_table`/`catch`. **Measured in
  this environment** (`npx porffor wasm foo.js` + `wasm-tools print`): the output uses the **legacy**
  exception-handling proposal — `try ;; label = @1` / `catch 0` / `end` (opcodes `0x06`/`0x07`), with a
  `(tag (param f64 i32))` and pervasive `throw 0` (the tag + `throw` **are** shared with the modern
  proposal; only the *try/catch container* differs). The ABI-findings doc explicitly anticipated this:
  "the scoping agents refine … the EH opcode bytes … against Porffor's source + more probes." This is
  that refinement, and it is **load-bearing** — it must be reconciled with **P7-03 (decode)** *before*
  building. *Argument + recommendation:* this unit specs the **modern `try_table` typing** per the task
  mandate and J2's frozen IR (`TryTable(result, body, catches)`), because (a) the tag + `throw` +
  `throw_ref` typing is **identical** either way (a tag is `[t*] -> []`; `throw` pops operands; both are
  measured in Porffor's output), and (b) `try_table` maps **directly** onto Core Erlang `try…catch`
  (J1's elegance), whereas legacy `try`/`catch` pushes handler operands onto the stack (a materially
  different, larger typing surface: `catch x` pushes `[t*]`, `catch_all` pushes `[]`, plus `delegate l`
  and `rethrow l`). **Preferred resolution:** pin a Porffor version/flag that emits `try_table`, **or**
  have **P7-03 normalize legacy `try`/`catch` → the modern `TryTable` AST at decode** (legacy try/catch
  is expressible as `try_table` + a wrapping block/label) — either way **this validator is unchanged**.
  **Contingency (if legacy typing is required):** validate gains legacy arms (`try bt` opens a frame
  whose `catch x` handler pushes the tag operands; `catch_all` pushes nothing; `delegate l`/`rethrow l`)
  — a strictly larger surface scoped here but **not** the default. Flagged prominently in the cross-unit
  flags.
- **D2 — model `try_table` as a structured control opener (reuse `KBlock`), not a bespoke node.**
  *Argument:* `try_table`'s body/label/`End` semantics are **identical** to `block` (label targets
  results; `End` produces results; no else-less check; no per-frame state). Reusing the existing control-
  frame machinery + `KBlock` (validating the catch clauses at the opener, before `push_ctrl`) touches
  **neither** `label_types` **nor** the `End` arm and keeps a tag-free module byte-identical — the same
  "reuse the verbatim algorithm" discipline P5/P6 held. A dedicated `KTry` FrameKind is equivalent but
  unnecessary. (P7-03/05 may still model the *IR* node distinctly — that is their concern; the AST/
  validate side reuses the block idiom because the *typing* is a block's.)
- **D3 — reuse `BranchArityMismatch`/`TypeMismatch` for catch-label disagreements; add only
  `UnknownTag`/`BadTagType`.** *Argument:* a catch-clause label mismatch **is** a branch-target arity/
  type disagreement (the caught values are branched to the label), so the existing variants are spec-
  honest and keep the error surface minimal — the Phase-6 precedent (reuse where the failure is the same
  kind; add a variant only for a genuinely new rejection). The two genuinely-new rejections are an out-
  of-range **tagidx** (`UnknownTag`) and a **non-empty-result tag** (`BadTagType`).

No deviation from J2's frozen IR shape (this unit does not touch the IR) beyond the D1 legacy-vs-modern
seam, which is a **decode/pipeline** reconciliation, not an IR change.

---

## Open questions (for the planner / cross-unit sync)

1. **⚠ Legacy vs modern EH — the pin (D1).** Confirm with P7-03 whether the pinned Porffor emits
   `try_table` (modern) or `try`/`catch` (legacy — measured here), and whether decode **normalizes**
   legacy → the modern `TryTable` AST (preferred: validate unchanged) or the pipeline pins a modern-EH
   Porffor. If legacy AST reaches validate, the D1 contingency arms are in scope. **Resolve before
   building** — it determines validate's surface.
2. **`exnref` byte + type-grammar reach.** Confirm P7-03's `ExnRef` byte (`0x69`, verified here) and
   whether decode admits an `exnref` **table element** / **global type** / `ref.null exn` const-expr.
   Validate types `exnref` generically wherever it flows; the const-expr `RefNull(ExnRef)` arm already
   works. If decode restricts `exnref` positions, validate needs no change (it only accepts what decode
   produces).
3. **Tag attribute byte.** Confirm P7-03 rejects a non-`0x00` tag attribute at *decode* (the only
   standardized attribute is `0x00` exception), so validate never sees one. If a non-zero attribute
   could reach validate, add an `Unsupported("tag-attribute")` reject.
4. **Catch-label match direction (subtyping).** This unit uses **exact structural equality** of the
   label types to the catch-type (no GC subtyping in the 2core MVP). Confirm no unit expects a subtype
   rule for `exnref` (there is no `exnref` subtyping in the base proposal). If GC lands later, this is
   the one place to revisit.
5. **`TypedModule.tag_types` shape.** This unit carries **operand-type lists** per tagidx (`List(List(
   ValType))`). Confirm P7-05 (lower) wants operands (not the full `FuncType`) — operands are all that
   the payload shape + catch binding need; the empty-results half is already validated away.
6. **Tag export range check.** Validate range-checks a `ExportTag` index against the tag space
   (→ `UnknownTag`). Confirm P7-03/08 do not expect a separate tag-export typing pass (it folds into the
   existing `check_exports` with one added `ExportTag` arm).
