# Unit P7-03 — WASM decode extension for exception handling (+ «WASM-AST5»)

> **One owner. Depends on nothing** upstream (extends the Phase-1/2/5/6
> `frontend/wasm/ast.gleam` + `decode.gleam`, i.e. `«WASM-AST4»`). **Publish the
> extended `ast.gleam` types as `«WASM-AST5»` on day 1** → unblocks **04 (validate)**
> and **05 (lower)**. Read [`00-overview.md`](00-overview.md) (J1–J8),
> [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md) (the measured Porffor facts),
> the Phase-6 decode doc [`phase-6/03-decode.md`](../phase-6/03-decode.md) (the shape
> this doc matches) and [`phase-6/RECONCILIATION.md`](../phase-6/RECONCILIATION.md)
> (S1 — "decode's shape IS the freeze"; still holds) first.
>
> **⚠ Load-bearing measured finding (this unit's homework, §F).** The overview and
> `PORFFOR-ABI-FINDINGS.md` state that Porffor emits the **modern `try_table`/`catch`**.
> **That is not what Porffor 0.61.13 actually emits.** Measured with `npx porffor wasm`
> + raw-byte inspection: Porffor emits the **legacy** exception opcodes `try` (`0x06`) /
> `catch` (`0x07`) / `throw` (`0x08`) / `end` (`0x0B`) — **never** `try_table` (`0x1F`).
> The tag section, the `throw` opcode, and the import/export tag descriptors it emits
> *do* match the modern spec exactly (verified byte-for-byte). This unit therefore
> decodes **both** the modern EH surface (the spec-stable, conformance-tested target the
> task specifies) **and** the legacy surface Porffor actually emits — because *JS on the
> BEAM cannot be reached decoding only `try_table` that Porffor never produces*. Both
> map onto the same downstream structured-exception IR (P7-01/P7-05). See §F + Deviation
> **D1** (the top reconciliation item).

---

## Context

Phase-6's decoder (`src/twocore/frontend/wasm/decode.gleam`, `«WASM-AST4»`) handles the
**complete standardized WebAssembly 2.0 binary surface** — the whole numeric/reference/
bulk-memory/multi-memory/memory64 set plus all ~236 fixed-width SIMD sub-opcodes. The
one standardized feature it does **not** yet parse is **exception handling**: the tag
section (id 13), the tag import/export descriptors (desc kind `0x04`), the `throw` /
`throw_ref` / `try_table` opcodes with their catch-clause immediates, and the `exnref`
reference type (byte `0x69`). Today every one of those bytes decode-rejects:

- the **tag section id `13`** is an unknown non-custom id → its `contents` are sliced
  and dropped by `dispatch_section`'s `_ -> Ok(state)` arm (silently ignored, not
  stored — wrong for a module that *defines* tags);
- an **importdesc / exportdesc kind byte `0x04`** → `Error(ast.BadImportKind)` /
  `Error(ast.BadExportKind)` (the current decoders accept only `0x00..0x03`);
- the opcodes **`0x06` (`try`), `0x07` (`catch`), `0x08` (`throw`), `0x09` (`rethrow`),
  `0x0A` (`throw_ref`), `0x18` (`delegate`), `0x19` (`catch_all`), `0x1F`
  (`try_table`)** → none are in `leaf_instr`, none are `0xFC`/`0xFD`, so `decode_instr`'s
  inner `case` falls through to `Error(ast.UnknownOpcode(op))`;
- the **`exnref` byte `0x69`** in a valtype/heaptype position → `Error(ast.BadValType)`
  (valtype) / `Error(ast.BadHeapType)` (reftype) / `Error(ast.BadBlockType)`
  (blocktype). (In an *instruction* position `0x69` is `i32.popcnt` — unaffected; the
  byte is context-disambiguated exactly as the SIMD spec disambiguates `0x7B`.)

Phase 7 completes the standard by decoding the exception-handling surface. This unit is
the **front door for EH**: it accepts the tag section, the tag import/export forms, the
EH control opcodes with their immediates, and `exnref` as a first-class value type. It
publishes the AST it produces as **`«WASM-AST5»`**.

The threat model is unchanged (D4 / H6): **the input is attacker-controlled.** Every
function stays total over arbitrary bytes — any malformation returns a typed
`DecodeError`, and **no `let assert`, `panic`, `todo`, or partial match is reachable from
input bytes**. This unit is purely *structural*: it does **not** type the exception
operand stack, check that a `throw`'s operands match the tag's `FuncType`, verify that a
catch clause's `labelidx` targets a block whose result matches the tag's payload, resolve
a `tagidx` against the tag space, confirm a tag's `FuncType` has empty results, or enforce
`exnref`'s placement restrictions — those are **04 (validate)**'s security-boundary job
(the spec's `assert_malformed` (decode) vs `assert_invalid` (validate) split). Its
contract is: bytes → the extended WASM AST, faithfully and fail-closed.

## Goal

Decode the full WebAssembly exception-handling binary surface into an extended
`ast.Module`:

- the **tag section** (id `13`): a `vec(tag)` where `tag ::= 0x00 x:typeidx` (attribute
  byte `0x00` = the exception attribute, then a `typeidx` naming the tag's `FuncType`);
- the **tag import / export descriptors** (desc kind `0x04`): an imported tag
  `0x04 0x00 x:typeidx` and an exported tag `0x04 x:tagidx`;
- the **modern EH opcodes** — `throw x` (`0x08` + `tagidx`), `throw_ref` (`0x0A`, no
  immediate), and `try_table bt catch*` (`0x1F` + a blocktype + a `vec(catch)`), where
  each **catch clause** is one of `0x00` `catch x l` (tagidx + labelidx), `0x01`
  `catch_ref x l` (tagidx + labelidx), `0x02` `catch_all l` (labelidx), `0x03`
  `catch_all_ref l` (labelidx);
- the **`exnref`** reference type (byte `0x69`) wherever a valtype appears (params/
  results, locals, globals, typed `select`, blocktypes), the heaptype `exn` (`0x69`) for
  `ref.null exn`, and its `-23` blocktype encoding;
- **(measured-Porffor requirement, §F / D1)** the **legacy EH opcodes** Porffor 0.61.13
  actually emits — `try bt` (`0x06`), `catch x` (`0x07`), `catch_all` (`0x19`),
  `delegate l` (`0x18`), `rethrow l` (`0x09`) — decoded into legacy AST markers that
  lower (05) unifies with the modern nodes onto the one structured-exception IR.

Prove it by decoding **real Porffor output** and **wasm-tools-assembled modern-EH
fixtures** to an exact AST for each construct — with **anti-swap fixtures** for the
catch-clause immediates (tag-before-label, the four clause kinds) and the tag descriptor
(attribute-before-typeidx) — and by extending the fail-closed fuzz battery to the EH
surface (typed errors, zero panics).

## Files owned

| File | Action |
|---|---|
| `src/twocore/frontend/wasm/ast.gleam` | **Extend** (single-owner). `ValType` gains `ExnRef`; `Module` gains `tags: List(Tag)`; the new `Tag` type; `ImportDesc` gains `ImportTag`; `ExportKind` gains `ExportTag`; the new `Catch` clause type; the EH `Instr` constructors (`Throw`, `ThrowRef`, `TryTable` — and the legacy `TryLegacy`, `LegacyCatch`, `LegacyCatchAll`, `LegacyDelegate`, `Rethrow`); the new `DecodeError` variants `BadTagAttribute`, `BadCatchKind`. **This is `«WASM-AST5»`, published day 1.** |
| `src/twocore/frontend/wasm/decode.gleam` | **Extend** (single-owner). `decode_valtype`/`decode_reftype` accept `0x69 → ExnRef`; `decode_blocktype` accepts the `-23` encoding; `section_rank` places the tag section (13) between memory (5) and global (6); `dispatch_section` decodes section 13; `decode_import`/`decode_export` accept kind `0x04`; `decode_instr` routes the eight EH opcodes; `decode_expr`/`decode_const_go` treat `try_table`/`try` as block-openers and `delegate` as a closer; `DecodeState`/`assemble` carry `tags`. |
| `test/twocore/frontend/wasm/decode_test.gleam` (+ embedded fixtures) | **Extend.** Worked-fixture AST assertions per EH construct + the anti-swap fixtures + the Porffor round-trip fixtures + the fail-closed fuzz extension. |

**Day-1 publish (the freeze milestone `«WASM-AST5»`):** land the `ast.gleam` *type*
additions first as one compiling commit (the new/changed types, with the `decode.gleam`
arms filled just enough to compile — a stub `0x1F -> Error(ast.UnknownOpcode(0x1F))` is
acceptable transiently), announce `«WASM-AST5»` in `state.md` with the full type delta
listed, **then** implement the decode bodies. Units 04/05 bind to the types, not the
bodies.

## Deliverables & freeze milestones

1. **`«WASM-AST5»`** — the extended `ast.gleam` type surface (§A), day 1. The single
   milestone this unit *produces*; it is on the critical path for 04/05.
2. **`decode.gleam` bodies** — §§B–F decoded, fail-closed.
3. **Tests** — worked fixtures + anti-swap fixtures + Porffor round-trip + fuzz
   (§Verification).

## Depends on

**Nothing upstream.** This unit extends the Phase-6 AST/decoder and touches neither the
IR (`ir.gleam`), the runtime, `rt_exn`, nor validate/lower. It can start immediately.
Like P6-03, it does **not** depend on the P7-01 keystone (`«EH-IR-FROZEN»`) — the WASM
AST is the frontend's *private* model, and lowering AST5 → the IR EH nodes is unit 05's
seam. **The AST must not import `ir.gleam`.** It **scopes its AST against the keystone's
EH-IR taxonomy** (J2: `Throw`/`TryTable`/`ThrowRef`/`exnref`) so 05's job is a
near-mechanical relabel, but it defines its **own** `ast.Tag`/`ast.Catch`/`ast.ExnRef` —
exactly as the AST's own `V128`/`SimdOp` are distinct from `ir.TV128`/`ir.SimdOp`.

## Scope — in / out for Phase 7

**In (decode to AST5):**
- The **tag section** (id 13) `vec(tag)`, `tag ::= 0x00 typeidx` (§C).
- The **tag import/export descriptors** (desc kind `0x04`) (§D).
- The **modern EH opcodes** `throw`/`throw_ref`/`try_table` + the four catch-clause kinds
  (§E).
- The **legacy EH opcodes** `try`/`catch`/`catch_all`/`delegate`/`rethrow` (§F —
  measured-Porffor; Deviation D1).
- The **`exnref`** value type / `exn` heaptype (`0x69`) + its `-23` blocktype (§B).
- The EH immediates: the `tag` attribute byte + typeidx, the `throw` tagidx, the
  `try_table` blocktype + `vec(catch)` (each catch's kind byte + tag/label indices), the
  legacy `catch`/`delegate`/`rethrow` indices — all read in **wire order** (§E, §F,
  anti-swap).

**Out (defer; document, fail-closed):**
- **All EH semantic checks** — the exception operand-stack typing, that a `throw`'s
  operands match `types[tag]`'s params, that a tag's `FuncType` has **empty results**
  (spec: an exception type is `[t*] → []`), that a catch clause's `labelidx` targets a
  block whose result type is the tag payload (`+ exnref` for the `_ref` clauses), that a
  `tagidx`/`labelidx` is in range, `exnref`'s value-position restrictions, and the
  legacy `delegate`/`rethrow` `labelidx` well-nestedness — are **validate's** (unit 04).
  Decode parses structure faithfully; validate is the security boundary for semantics.
- **The EH runtime** (`rt_exn`, P7-07) and **lowering** (AST5 → the IR EH nodes, P7-05).
  Decode emits the AST node; nothing downstream is this unit's concern.
- **The `(f64, i32)` Porffor value-ABI** — that is a *host/run-ABI* convention (P7-08),
  **not** a decode concern. Decode sees the tag's `FuncType` as `(param f64 i32)` like any
  other functype; it does not interpret the pair.
- **GC heaptypes** — `struct`/`array`/`i31`/typed refs stay rejected (`BadHeapType`);
  Porffor does not use them (confirmed, findings §GC). Only `exn` (`0x69`) is added.

---

## A. `«WASM-AST5»` — the type surface (day-1 freeze)

Scope every new shape against the keystone's EH-IR taxonomy (J2) so lower is mechanical,
but keep the AST **WASM-shaped**: a flat instruction stream, raw indices, no `ir.gleam`
import.

### A.1 The `exnref` value type

Extend `ValType` with the one exception reference type. In the binary format it is a
single byte in the same encoding position as any reftype: **`exnref = 0x69`** (the
shorthand for `(ref null exn)`; the abstract heaptype `exn` is likewise `0x69`). Verified
against wasm-tools-assembled ground truth (`(local exnref)` → locals group `01 69`;
`ref.null exn` → `0xD0 0x69`).

```gleam
/// A WebAssembly value type. Phase 1/2: the four number types. Phase 5: the two MVP
/// reference types. Phase 6: `V128`. Phase 7 (`«WASM-AST5»`) adds `ExnRef` — a caught-
/// exception reference (`(ref null exn)`), an OPAQUE handle to an in-flight/caught
/// exception, structurally like `ExternRef`. Binary bytes: i32=0x7F i64=0x7E f32=0x7D
/// f64=0x7C, v128=0x7B, funcref=0x70, externref=0x6F, **exnref=0x69**. No GC-proposal
/// reftypes. A non-EH module never carries `ExnRef`, so every existing exhaustive match
/// over `ValType` gains one unreachable-in-practice arm and stays byte-identical (lower
/// maps `ExnRef → ir.TExnRef`, 1:1 like `FuncRef`/`TFuncRef`).
pub type ValType {
  I32
  I64
  F32
  F64
  V128
  FuncRef
  ExternRef
  ExnRef
}
```

Unlike `V128` (which is **not** a reftype — `decode_reftype` rejects `0x7B`), `ExnRef`
**is** a reftype: `exn` (`0x69`) is a legal absheaptype, so `decode_reftype` (the
reftype-only position used by `ref.null`) accepts `0x69 → ExnRef` (§B). Whether an
`exnref` may appear in a *table* / *global* / *element segment* is **validate's** call
(the spec restricts where `exnref` values live); decode is structural and accepts it in
every reftype position.

> **Cross-unit seam (S-EXNREF):** `ast.ExnRef` ↔ `ir.TExnRef` (keystone P7-01, J2's
> "`exnref` reference-layer value, opaque like `externref`"). Lower (05) maps
> `ExnRef → TExnRef`. The keystone owns `TExnRef`; this unit owns `ast.ExnRef`. 1:1, like
> `FuncRef`/`TFuncRef`.

### A.2 Tags — `Tag` + `Module.tags`

A **tag** declares an exception type: an attribute (always `0x00`, the *exception*
attribute) and a `typeidx` into the module's `types` giving the tag's operand signature
(the values a thrown instance of this tag carries). The AST stores only the `type_idx`
(the attribute is checked `== 0x00` by decode and dropped — like the funcref `elemkind`
check; a non-`0x00` attribute is a decode error, §C).

```gleam
/// A tag declaration (tag section, id 13). A tag is an EXCEPTION type: `attribute:0x00
/// x:typeidx`. `type_idx` names the tag's `FuncType` in `Module.types`; that functype's
/// PARAMETERS are the exception's operand types (the payload a `throw` of this tag
/// carries) and its RESULTS must be empty (`[t*] → []`) — the empty-results check is
/// validate's (unit 04), not decode's. The `0x00` attribute is consumed + checked by
/// decode (a non-`0x00` byte is `Error(ast.BadTagAttribute)`) and NOT stored; only the
/// exception attribute exists today. Defined tags live here; IMPORTED tags live in
/// `Module.imports` as `ImportTag` (the tag index space is imported-then-defined, exactly
/// like functions).
pub type Tag {
  Tag(type_idx: Int)
}
```

`Module` gains a `tags` field (the **defined** tags, section 13, in order):

```gleam
pub type Module {
  Module(
    imported_func_count: Int,
    types: List(FuncType),
    imports: List(Import),
    tables: List(TableType),
    memories: List(MemType),
    globals: List(Global),
    tags: List(Tag),          // NEW — the tag section (id 13), defined tags in order
    funcs: List(Func),
    start: Option(Int),
    elements: List(ElementSegment),
    data: List(DataSegment),
    data_count: Option(Int),
    exports: List(Export),
  )
}
```

A tag-free module decodes `tags: []` (byte-identical semantics; §G). The imported-tag
count (for the tag index-space split) is derivable from `imports` by validate/lower —
exactly as the imported table/memory/global counts already are — so **no** new computed
`Module` field is added (only `imported_func_count` is precomputed, unchanged).

### A.3 Tag import / export descriptors

```gleam
/// ImportDesc gains the tag form (desc kind 0x04):
///   `0x04 0x00 x:typeidx` — an imported exception tag of `types[x]` (attribute 0x00).
/// A non-0x00 attribute is `Error(ast.BadTagAttribute)`.
pub type ImportDesc {
  ImportFunc(type_idx: Int)
  ImportTable(TableType)
  ImportMemory(MemType)
  ImportGlobal(ty: ValType, mutable: Bool)
  ImportTag(type_idx: Int)          // NEW — 0x04 0x00 typeidx
}

/// ExportKind gains the tag form (export desc kind 0x04): `0x04 x:tagidx`.
pub type ExportKind {
  ExportFunc
  ExportTable
  ExportMemory
  ExportGlobal
  ExportTag                          // NEW — 0x04
}
```

### A.4 Catch clauses (the `try_table` immediate)

The four standardized catch-clause kinds carried in a `try_table`'s immediate `vec(catch)`
(spec: the EH proposal's `catch` grammar). Constructor names mirror the spec keywords 1:1.

```gleam
/// A single `try_table` catch clause (spec: EH proposal §binary — the catch vector).
/// Each clause routes a caught exception to a block LABEL, optionally binding an `exnref`.
/// Decode stores raw `tag`/`label` indices (`u32`); validate (04) resolves + types them.
///
/// - `Catch(tag, label)`      — 0x00: on a throw of `tag`, push its operands, branch to
///                              `label`.
/// - `CatchRef(tag, label)`   — 0x01: on a throw of `tag`, push its operands AND an
///                              `exnref` for the caught exception, branch to `label`.
/// - `CatchAll(label)`        — 0x02: on ANY throw, branch to `label` (no operands).
/// - `CatchAllRef(label)`     — 0x03: on ANY throw, push an `exnref`, branch to `label`.
pub type Catch {
  Catch(tag: Int, label: Int)
  CatchRef(tag: Int, label: Int)
  CatchAll(label: Int)
  CatchAllRef(label: Int)
}
```

### A.5 EH instructions

The EH surface adds a **modern** group (the task-specified, spec-stable, conformance-
tested target) and a **legacy** group (the measured-Porffor surface, §F / D1). All are
distinct `Instr` constructors — a flat-stream AST carries structured control as opener +
markers + `End`, exactly as `Block`/`If`/`Else`/`End` already do.

```gleam
pub type Instr {
  // …all existing Phase-1..6 constructors…

  // ===================== Phase 7 («WASM-AST5») — exception handling =====================
  // --- modern EH (spec: throw=0x08, throw_ref=0x0A, try_table=0x1F) ---
  /// `throw x` (0x08 + `tagidx`) — throw a new exception of tag `x`, consuming the tag's
  /// operand values from the stack as the payload. Does not return (bottom, like
  /// `Return`/`Unreachable`); NOT a block-opener (no matching `End`). `tag` is a raw
  /// `u32` tagidx; validate resolves it + checks the operands against `types[tag]`.
  Throw(tag: Int)
  /// `throw_ref` (0x0A, no immediate) — re-raise the `exnref` on top of the stack. Does
  /// not return. Consumes one `exnref` operand (validate's check); NOT a block-opener.
  ThrowRef
  /// `try_table bt catch*` (0x1F + blocktype + `vec(catch)`) — a BLOCK-OPENER (its body
  /// runs to the matching `End`, exactly like `Block`) that installs `catches` for the
  /// dynamic extent of the body: a thrown exception matching a clause transfers to that
  /// clause's block `label` (binding the payload, and an `exnref` for the `_ref`
  /// clauses); an unmatched exception propagates. `bt` is the body's blocktype;
  /// `catches` is the decoded clause vector (in wire order — the first matching clause
  /// wins, so order is load-bearing).
  TryTable(bt: BlockType, catches: List(Catch))

  // --- legacy EH (MEASURED: what Porffor 0.61.13 actually emits — §F / Deviation D1) ---
  /// `try bt` (0x06 + blocktype) — the LEGACY try block-opener. Its body runs to a
  /// `LegacyCatch`/`LegacyCatchAll` handler marker (or straight to `End`), and the whole
  /// construct is closed by `End` OR terminated by `LegacyDelegate`. A block-opener for
  /// depth accounting (§F.2).
  TryLegacy(bt: BlockType)
  /// `catch x` (0x07 + `tagidx`) — a LEGACY in-block handler marker (like `Else` for
  /// `If`): begins the handler for tag `x` within the enclosing `TryLegacy`. NOT an
  /// opener/closer (depth unchanged).
  LegacyCatch(tag: Int)
  /// `catch_all` (0x19, no immediate) — a LEGACY in-block catch-all handler marker.
  LegacyCatchAll
  /// `delegate l` (0x18 + `labelidx`) — LEGACY: terminates the enclosing `TryLegacy`
  /// (a block-CLOSER, replacing its `End`) and delegates any uncaught exception to the
  /// `l`-th enclosing handler. `label` is a raw `u32`.
  LegacyDelegate(label: Int)
  /// `rethrow l` (0x09 + `labelidx`) — LEGACY: re-throw the exception caught by the
  /// `l`-th enclosing `catch`/`catch_all`. Does not return; NOT a block-opener.
  Rethrow(label: Int)
}
```

> **Note (why legacy markers, not normalization).** Decode is *structural*: legacy
> `try`/`catch`/`catch_all`/`delegate` interleave handlers into the instruction stream
> (markers, like `Else`), whereas modern `try_table` carries its clauses as an
> *immediate vector* with the body running straight to `End`. Normalizing legacy →
> `TryTable` requires **restructuring** the stream (moving handler bodies into sibling
> blocks) — that is a *lowering* transform, not a parse. So decode keeps the legacy
> shape faithfully and **lower (05) unifies both onto the one structured-exception IR**
> (J2). This preserves the P5-03 "decode parses, does not transform" discipline. (An
> alternative — decode-time normalization — is Open Q1 for the keystone.)

### A.6 New `DecodeError` variants

```gleam
/// A tag / imported-tag ATTRIBUTE byte is not `0x00` (the only defined attribute is the
/// exception attribute; spec: `tag ::= 0x00 typeidx`). An `assert_malformed`-class error.
BadTagAttribute
/// A `try_table` catch-clause KIND byte is not `0x00..0x03` (spec: the catch grammar has
/// exactly the four kinds catch/catch_ref/catch_all/catch_all_ref). An
/// `assert_malformed`-class error.
BadCatchKind
```

These are the **only** two new `DecodeError` variants. Every other EH malformation reuses
an existing one (P5-03/P6-03 discipline: *reuse over add*):

- a truncated tag section / catch vector / EH immediate → `Truncated`;
- a malformed LEB tagidx/labelidx/typeidx → `LebOverflow`/`LebTooLong`/`Truncated`;
- an importdesc / exportdesc kind byte outside `0x00..0x04` → `BadImportKind` /
  `BadExportKind` (unchanged — the accepted set simply grows by one);
- an `exnref`/`exn` byte `0x69` in a *number-only* position → `BadValType` (valtype) /
  `BadHeapType` (a GC-only reftype position, unchanged) as appropriate;
- a misplaced tag section (out of canonical order) → `SectionOrder` (via `section_rank`,
  §C);
- an EH opcode that is genuinely unknown (none remain — all eight are assigned) →
  `UnknownOpcode` (only for a truly unassigned byte).

`BadTagAttribute` is justified by the non-`0x00`-attribute fuzz case; `BadCatchKind` by
the `>= 0x04` catch-kind fuzz case (§Verification 2). Both encode a distinct
`assert_malformed` the tests exercise.

---

## B. `exnref` valtype / heaptype / blocktype

Three existing decoders gain an `exnref` arm; the change is one byte (`0x69`) in each.

**`decode_valtype`** adds `0x69 → ExnRef` (a value-type position: params/results, locals,
globals, typed `select`):

| Byte | `decode_valtype` | `decode_reftype` |
|---|---|---|
| `0x7F 0x7E 0x7D 0x7C` | I32 I64 F32 F64 | → `BadHeapType` |
| `0x7B` | V128 | → `BadHeapType` (v128 is not a reftype) |
| `0x70` | FuncRef | FuncRef |
| `0x6F` | ExternRef | ExternRef |
| **`0x69`** | **ExnRef** (NEW) | **ExnRef** (NEW — `exn` IS a heaptype) |
| other | `BadValType` | `BadHeapType` |

**`decode_reftype`** *also* adds `0x69 → ExnRef` — unlike `V128`, `exn` is a legal
abstract heaptype, so `ref.null exn` (`0xD0 0x69`) must decode to `RefNull(ExnRef)`.
(Verified: wasm-tools assembles `ref.null exn` to exactly `d0 69`.) This is the sole
behavioural difference from the P6 v128 handling of `decode_reftype`.

**`decode_blocktype`** adds the `exnref` negative encoding. A single-byte valtype in a
blocktype is read as a signed LEB(33); `exn = 0x69` sign-extends to **`-23`** (`0x69 =
105`, `105 − 128 = −23`; verified: `(block (result exnref) …)` assembles to opener byte
`02 69`):

| s33 value | `BlockType` |
|---|---|
| `>= 0` | `BlockTypeIdx(v)` |
| `-64` | `BlockEmpty` |
| `-1 -2 -3 -4` | `BlockVal(I32/I64/F32/F64)` |
| `-5` | `BlockVal(V128)` |
| `-16 -17` | `BlockVal(FuncRef/ExternRef)` |
| **`-23`** | **`BlockVal(ExnRef)`** (NEW) |
| other negative | `BadBlockType` |

A `try_table (result exnref) …` and a `block (result exnref) …` — both legal — decode
via this arm. Because `decode_valtype`/`decode_reftype`/`decode_blocktype` serve every
type site, this one arm each cascades correctly (an `(param exnref)`, a `(local exnref)`,
a `select (result exnref)` → `SelectT([ExnRef])`, a `catch_all_ref`-bound block result)
with no further change.

---

## C. The tag section (id 13) + section ordering

The tag section is **section id 13**, ordered in the module sequence **between the memory
section (5) and the global section (6)** (spec: the merged EH module structure). It is a
`vec(tag)` where `tag ::= attribute:0x00 x:typeidx` (verified byte-for-byte: Porffor's
tag section is `0d 03 01 00 17` = id 13, size 3, `[count 1][attr 0x00][typeidx 23]`; a
wasm-tools-assembled tag is `01 00 00`).

**`section_rank`** must place 13 between 5 and 6. Since ranks are integers and no integer
sits strictly between 5 and 6, `section_rank` is re-expressed as an explicit,
order-preserving canonical-position table (the relative order of every existing section
is unchanged, so a **tag-free** module's accept/reject decisions are byte-identical — §G):

```gleam
/// The canonical position of a non-custom section for the ascending-order check. The tag
/// section (13) sits between memory (5) and global (6) per the EH proposal; the datacount
/// section (12) between element (9) and code (10) per bulk-memory. Neither orders by raw
/// id. Order: type < import < function < table < memory < TAG < global < export < start
/// < element < datacount < code < data. Monotonic in the canonical order, so a tag-free
/// module decodes byte-identically (§G).
fn section_rank(id: Int) -> Int {
  case id {
    13 -> 6     // tag  — between memory(5) and global(6)
    6 -> 7      // global
    7 -> 8      // export
    8 -> 9      // start
    9 -> 10     // element
    12 -> 11    // datacount
    10 -> 12    // code
    11 -> 13    // data
    _ -> id     // 1,2,3,4,5 keep their id
  }
}
```

> **Note the placement subtlety:** the tag section (13) is ordered *early* (after memory)
> **despite its high id** — a naive `_ -> id` would place it last and wrongly reject a
> spec-ordered module (tag before global) as `SectionOrder`, and wrongly accept a
> misordered one. The remap is required for correctness, not cosmetics.

**`dispatch_section`** gains the section-13 arm (a `vec(tag)`, full-consumption checked
like every section):

```gleam
// tag section (id 13): vec(tag), each `0x00 typeidx`.
13 -> {
  use #(tags, rest) <- result.try(decode_vec(contents, decode_tag))
  use _ <- result.try(expect_empty(rest))
  Ok(DecodeState(..state, tags: tags))
}
```

with the leaf decoder:

```gleam
/// Decode one tag `attribute:0x00 x:typeidx`. The attribute MUST be `0x00` (the exception
/// attribute — the only kind defined); any other byte is `Error(ast.BadTagAttribute)`.
/// `typeidx` is a `u32` into `Module.types`; that it names a functype with empty results
/// is validate's check. EOF before the attribute/typeidx is `Error(ast.Truncated)`.
fn decode_tag(bytes: BitArray) -> Result(#(Tag, BitArray), ast.DecodeError) {
  case bytes {
    <<0x00, r0:bytes>> -> {
      use #(type_idx, r1) <- result.try(decode_u_n(r0, 32))
      Ok(#(ast.Tag(type_idx: type_idx), r1))
    }
    <<_:8, _:bytes>> -> Error(ast.BadTagAttribute)
    _ -> Error(ast.Truncated)
  }
}
```

`DecodeState` gains a `tags: List(Tag)` field (defaulted `[]` in `empty_state`), and
`assemble` threads `tags: state.tags` into the `Module`. Nothing else in `assemble`
changes (tags do not participate in the func/code pairing or the datacount check).

---

## D. Tag import / export descriptors (desc kind `0x04`)

**`decode_import`** gains a `0x04` arm (the imported-tag form `0x04 0x00 typeidx`;
verified: `01 01 6d 01 74 04 00 00` = one import `"m" "t"` desc `04`(tag) `00`(attr)
`00`(typeidx)):

```gleam
0x04 -> {
  // imported tag: attribute 0x00 THEN typeidx.
  case r3 {
    <<0x00, r4:bytes>> -> {
      use #(type_idx, r) <- result.try(decode_u_n(r4, 32))
      Ok(#(ast.Import(module, name, ast.ImportTag(type_idx)), r))
    }
    <<_:8, _:bytes>> -> Error(ast.BadTagAttribute)
    _ -> Error(ast.Truncated)
  }
}
```

A kind byte outside `0x00..0x04` stays `Error(ast.BadImportKind)` (the accepted set grew
by one; the error is unchanged). `assemble`'s `imported_func_count` fold is untouched —
`ImportTag` is not `ImportFunc`, so it does not perturb the func index space; imported
tags contribute to the **tag** index space (derived from `imports` by validate/lower).

**`decode_export`** gains a `0x04 → ExportTag` mapping (the exported-tag form `0x04
tagidx`; verified: `04 00` = tag export, tagidx 0):

```gleam
use kind <- result.try(case kind_byte {
  0x00 -> Ok(ast.ExportFunc)
  0x01 -> Ok(ast.ExportTable)
  0x02 -> Ok(ast.ExportMemory)
  0x03 -> Ok(ast.ExportGlobal)
  0x04 -> Ok(ast.ExportTag)          // NEW
  _ -> Error(ast.BadExportKind)
})
```

---

## E. The modern EH opcode dispatch

Add the modern EH arms to `decode_instr`'s opcode `case` (all currently
`UnknownOpcode`):

```gleam
// exception handling (modern): throw / throw_ref / try_table
0x08 -> {
  use #(tag, r) <- result.try(decode_u_n(rest, 32))
  Ok(#(ast.Throw(tag), r))
}
0x0A -> Ok(#(ast.ThrowRef, rest))
0x1F -> {
  use #(bt, r1) <- result.try(decode_blocktype(rest))
  use #(catches, r2) <- result.try(decode_vec(r1, decode_catch))
  Ok(#(ast.TryTable(bt, catches), r2))
}
```

with the catch-clause leaf decoder (**wire order: kind byte, then tag (if any), then
label** — anti-swap §E.1):

```gleam
/// Decode one `try_table` catch clause (spec: EH proposal, the catch vector). The leading
/// KIND byte selects the form; `catch`/`catch_ref` (0x00/0x01) then read a `tagidx` THEN a
/// `labelidx`; `catch_all`/`catch_all_ref` (0x02/0x03) read a `labelidx` only. A kind byte
/// outside `0x00..0x03` is `Error(ast.BadCatchKind)`; EOF is `Error(ast.Truncated)`. Both
/// indices are raw `u32`s (validate resolves them). Order is load-bearing: the tag is read
/// BEFORE the label (swapping mis-decodes both).
fn decode_catch(bytes: BitArray) -> Result(#(Catch, BitArray), ast.DecodeError) {
  case bytes {
    <<0x00, r0:bytes>> -> {
      use #(tag, r1) <- result.try(decode_u_n(r0, 32))
      use #(label, r2) <- result.try(decode_u_n(r1, 32))
      Ok(#(ast.Catch(tag, label), r2))
    }
    <<0x01, r0:bytes>> -> {
      use #(tag, r1) <- result.try(decode_u_n(r0, 32))
      use #(label, r2) <- result.try(decode_u_n(r1, 32))
      Ok(#(ast.CatchRef(tag, label), r2))
    }
    <<0x02, r0:bytes>> -> {
      use #(label, r1) <- result.try(decode_u_n(r0, 32))
      Ok(#(ast.CatchAll(label), r1))
    }
    <<0x03, r0:bytes>> -> {
      use #(label, r1) <- result.try(decode_u_n(r0, 32))
      Ok(#(ast.CatchAllRef(label), r1))
    }
    <<_:8, _:bytes>> -> Error(ast.BadCatchKind)
    _ -> Error(ast.Truncated)
  }
}
```

**Block-nesting change (critical).** `try_table` is a **structured control instruction**
closed by a matching `End`, exactly like `Block`/`Loop`/`If`. Both depth trackers —
`decode_expr` (function bodies) and `decode_const_go` (const exprs) — must treat
`TryTable(_, _)` as a block-opener (`depth + 1`). `Throw`/`ThrowRef` are **not** openers
(they carry no `End`). Update the opener arm in both:

```gleam
ast.Block(_) | ast.Loop(_) | ast.If(_) | ast.TryTable(_, _) | ast.TryLegacy(_) ->
  decode_expr(rest, depth + 1, [instr, ..acc])
```

Omitting `try_table` from the opener set would mis-count nesting: its body's `End` would
be read as the *function's* terminator, truncating the body and corrupting everything
after. (This is the modern analogue of forgetting that `if` opens a block.) The
`TryLegacy` opener + the `LegacyDelegate` closer are handled in §F.2.

### E.1 Anti-swap fixtures (the catch-clause immediates)

The catch-clause immediates are the sharp edges — a swap silently mis-decodes. Ground
truth (wasm-tools-assembled `try_table (result i32) (catch $e $h) (catch_ref $e $ha)
(catch_all $h) (catch_all_ref $ha)`): the immediate is `1f 7f 04 | 00 00 01 | 01 00 00 |
02 01 | 03 00`, i.e. `try_table`(0x1F) bt=`7f`(i32) count=4, then:

- `00 00 01` — `Catch(tag 0, label 1)` (kind, **tag before label**);
- `01 00 00` — `CatchRef(tag 0, label 0)`;
- `02 01` — `CatchAll(label 1)`;
- `03 00` — `CatchAllRef(label 0)`.

**Anti-swap fixture:** a `try_table` with a catch clause whose tag and label are
*distinct* (e.g. `catch tag=1 label=3`) must decode `Catch(1, 3)` — **not** `Catch(3, 1)`
— proving the tag is read before the label. A four-clause fixture with distinct indices
per clause proves the kind dispatch (`0x00..0x03`) and per-clause immediate arity
(2 indices for catch/catch_ref, 1 for the `_all` forms).

---

## F. The MEASURED Porffor reality — legacy `try`/`catch` (Deviation D1)

> **This section is this unit's load-bearing homework.** The overview (J1) and
> `PORFFOR-ABI-FINDINGS.md` assert Porffor emits `try_table`/`catch`. **Measured, it does
> not.** Decode must handle what Porffor *actually* emits, or Phase 7's headline goal
> (JS on the BEAM) is unreachable.

### F.1 What Porffor 0.61.13 actually emits (measured, raw bytes)

Compiling a JS `try { … throw x … } catch (e) { … }` with `npx porffor wasm eh.js
eh.wasm` and inspecting the raw code bytes (and `wasm-tools print`, which renders it in
the **legacy** `try …/catch …/end` textual syntax — *not* `try_table …`):

| Construct | Measured bytes | Meaning |
|---|---|---|
| tag section | `0d 03 01 00 17` | id 13, one tag, attr `0x00`, `typeidx 23` = `(func (param f64 i32))` ✓ (matches §C) |
| tag export | `04 00` | export desc kind `0x04`, tagidx 0 ✓ (matches §D) |
| intrinsic imports | `… 00 01 62 00 1a  00 01 61 00 1a` | `("" "b")`/`("" "a")`, both `(func (param f64))` ✓ (findings) |
| **try opener** | **`06 40`** | **legacy `try`** (`0x06`) + blocktype `0x40` (empty) — **NOT** `try_table` (`0x1F`) |
| **catch** | **`07 00`** | **legacy `catch`** (`0x07`) + tagidx 0 |
| throw | `08 00` | `throw` (`0x08`) + tagidx 0 — shared with modern ✓ |
| block close | `0b` | `end` |

Every working `--exception-mode` (`stack` (default), `stackest`, `partial`) emits the
same legacy `06 …/07 …/0b`. **No Porffor mode emits `try_table` (`0x1F`).** Porffor's EH
usage is minimal: exactly `try`/`catch`/`throw`/`end` — **no** `catch_all`, `delegate`,
`rethrow`, `throw_ref`, or `exnref` in typical output (a `try/catch/finally` still emits a
single `try` + single `catch`, the `finally` body duplicated into both paths).

So: the **tag section, tag descriptors, and `throw`** Porffor emits are byte-for-byte the
modern spec (this unit decodes them per §C/§D/§E). The **control construct** is the
*legacy* `try`/`catch` proposal, which this unit must additionally decode.

### F.2 The legacy EH opcodes (decode surface)

The legacy exception-handling proposal's opcodes (deprecated by, but coexisting in the
opcode space with, the modern set — **no byte conflicts**; `throw`=`0x08` is shared):

| Opcode | Instruction | Immediate | AST |
|---|---|---|---|
| `0x06` | `try bt` | blocktype | `TryLegacy(bt)` — block-opener |
| `0x07` | `catch x` | `tagidx` | `LegacyCatch(x)` — in-block handler marker |
| `0x19` | `catch_all` | — | `LegacyCatchAll` — in-block handler marker |
| `0x18` | `delegate l` | `labelidx` | `LegacyDelegate(l)` — try-terminator (block-closer) |
| `0x09` | `rethrow l` | `labelidx` | `Rethrow(l)` |
| `0x08` | `throw x` | `tagidx` | `Throw(x)` — **shared with modern** (§E) |

`decode_instr` arms (all currently `UnknownOpcode`):

```gleam
0x06 -> {
  use #(bt, r) <- result.try(decode_blocktype(rest))
  Ok(#(ast.TryLegacy(bt), r))
}
0x07 -> {
  use #(tag, r) <- result.try(decode_u_n(rest, 32))
  Ok(#(ast.LegacyCatch(tag), r))
}
0x19 -> Ok(#(ast.LegacyCatchAll, rest))
0x18 -> {
  use #(label, r) <- result.try(decode_u_n(rest, 32))
  Ok(#(ast.LegacyDelegate(label), r))
}
0x09 -> {
  use #(label, r) <- result.try(decode_u_n(rest, 32))
  Ok(#(ast.Rethrow(label), r))
}
```

**Legacy block-nesting.** A legacy `try` opens a block (`depth + 1`) whose handlers
(`catch`/`catch_all`) are *in-stream markers* (depth **unchanged**, like `Else`), and
which is closed by **either** `End` **or** `delegate` (both `depth − 1`). Update the
depth trackers:

- **openers** (`depth + 1`): `Block`, `Loop`, `If`, `TryTable(_, _)`, `TryLegacy(_)`.
- **markers** (depth unchanged): `LegacyCatch(_)`, `LegacyCatchAll` fall through the `_`
  arm — no change needed (they are not openers/closers).
- **closer** (`depth − 1`): `LegacyDelegate(_)` — a `try` terminated by `delegate` has
  **no** `End`, so `delegate` pops the try's depth. Handle it alongside the non-zero
  `End` case:

```gleam
ast.End ->
  case depth {
    0 -> Ok(#(list.reverse([ast.End, ..acc]), rest))   // the expr's terminator
    _ -> decode_expr(rest, depth - 1, [ast.End, ..acc])
  }
ast.LegacyDelegate(_) ->
  case depth {
    0 -> Error(ast.UnknownOpcode(0x18))   // a delegate with no open try is malformed
    _ -> decode_expr(rest, depth - 1, [instr, ..acc])
  }
```

Only `End` (`0x0B`) can terminate the whole expression (depth 0); a `delegate` at depth 0
is a mis-nested body and is rejected fail-closed (reusing `UnknownOpcode(0x18)` — a
distinct malformation without a new variant; reconciliation may prefer a dedicated
`BadDelegate` — Open Q2). Since Porffor never emits `delegate`/`catch_all`/`rethrow`, this
path is exercised only by authored fixtures + fuzz, but decode must stay **total** over
it.

### F.3 Legacy → the same IR (lower's seam, not decode's)

Decode keeps the legacy shape faithful; **lower (P7-05) unifies legacy + modern onto the
one structured-exception IR (J2)**. The mapping is straightforward (flagged for 05):
`TryLegacy` + its `LegacyCatch(x)`/`LegacyCatchAll` handlers + `End` → the same
`TryTable`-style IR node (each handler → a catch clause branching to a synthesized
handler block); `LegacyDelegate(l)` → a re-raise to the `l`-th outer handler; `Rethrow(l)`
→ the IR re-raise of the `l`-th caught exception (the modern `ThrowRef` of a bound
`exnref`). Decode does **not** perform this transform (Deviation D1 rationale).

### F.4 Recommendation

**P7-03 owns both surfaces** (both are "decode the EH binary format"). The modern surface
is the spec-stable, conformance-tested (`throw.wast`/`try_table.wast`/`tag.wast`) target;
the legacy surface is the *measured-Porffor* requirement without which the JS harness
(P7-09) has nothing to run. The overview + `PORFFOR-ABI-FINDINGS.md` should be corrected
to say "Porffor emits **legacy** `try`/`catch`" (flagged for reconciliation). If the
planner instead pins the modern surface **only**, Phase 7's goal is blocked until Porffor
ships a `try_table` mode (it has none as of 0.61.13) — so the legacy path is not optional.

---

## G. Conformance-neutral defaults

A module with **no tag section, no `0x04` descriptor, and no EH opcode** decodes to a
*structurally identical* AST5:

- `Module.tags == []` (the new field's empty default);
- no `Throw`/`ThrowRef`/`TryTable`/`TryLegacy`/`LegacyCatch`/`LegacyCatchAll`/
  `LegacyDelegate`/`Rethrow` node appears;
- the `ExnRef` `ValType`, `ImportTag`, `ExportTag`, and `Catch` constructors are unused;
- `section_rank` is order-preserving (§C), so every legacy module's section-order
  accept/reject decision is unchanged;
- every behavioural change to an existing path is **unreachable** for a non-EH module: it
  never contains a `0x69` in a type position, a `0x04` descriptor, a section id 13, or any
  EH opcode (`0x06`–`0x0A`, `0x18`, `0x19`, `0x1F`).

So the entire Phase-1..6 corpus decodes **byte-identically** (the H7-style neutrality
obligation for this layer; lower/emit discharge the rest jointly with 05/06).

---

## Effect / soundness / security note

- **Fail-closed over hostile bytes (D4/H6).** Every new EH sub-decoder returns a typed
  `DecodeError` on malformation; `decode.gleam` stays free of `let assert`, `panic`,
  `todo`, and non-exhaustive matches reachable from input. The tag attribute is an exact
  `0x00` match (else `BadTagAttribute`); the catch kind is an exact `0x00..0x03` match
  (else `BadCatchKind`); every index is a `decode_u_n(_, 32)` (a malformed LEB is
  `LebOverflow`/`LebTooLong`/`Truncated`, never a wrap); the `try_table` catch vector is a
  standard `decode_vec` (a truncated vector is `Truncated`, never an over-read); the
  block-nesting counters are monotone (`TryTable`/`TryLegacy` open, `End`/`delegate`
  close) so no stream desync escapes as a panic. Totality holds over arbitrary bytes.
- **Decode is not the security boundary; it is the parser.** It deliberately does *not*
  type the exception stack, match `throw` operands to `types[tag]`, check a tag's
  functype has empty results, resolve/range-check a `tagidx`/`labelidx`, verify a catch
  label's block result type, or restrict `exnref`'s value positions. Those are validate's
  (unit 04) — the `assert_malformed` (decode) vs `assert_invalid` (validate) split.
  Decode's soundness obligation is **totality + faithful structure**: a well-formed EH
  binary decodes to the *exact* AST the spec's grammar prescribes, and every ill-formed
  binary is rejected without a crash.
- **No ambient authority is introduced (D3a / J5).** A `throw` carries a **tagidx** — an
  integer index into the module's *own* tag space — plus stack operands; it is **never** an
  attacker-chosen term or an ambient `apply`. The thrown term's shape is *build-controlled*
  downstream (emit_core, P7-06, mints `{wasm_exn, TagId, Payload}` — the binding
  chokepoint), so decode records only indices, granting nothing. An `exnref` is an
  **opaque** value at the AST (like `externref`): decode stores no inspectable structure,
  only that a value of that type flows; Safe code (downstream) can re-throw a caught
  `exnref` (`throw_ref`) but cannot forge or inspect the underlying BEAM term. No EH
  instruction at the AST grants memory or host authority.
- **Conformance-neutral defaults (J6 / §G).** A tag-free module decodes byte-identically;
  the whole EH surface is inert unless a tag/EH byte actually appears.

---

## Verification — Definition of Done (D8)

**Spec behavior + measured Porffor, not change-detector.** Drive decode from two
byte-sources, both embedded as `BitArray` literals so the suite needs no external tool at
run time: (a) **wasm-tools-assembled** modern-EH modules (ground truth for the spec
surface — cite the exact opcode/section byte per fixture), and (b) **real Porffor output**
(ground truth for the legacy surface Porffor emits). Never assert "whatever decode emits";
the byte tables in §C–§F are the spec/measurement, so a fixture that decodes to the wrong
AST is a *code* bug caught here.

### 1. Worked fixtures (exact AST), per construct

- **tag section (§C):** a module with `(tag (type 0))` where `types[0] = (func (param f64
  i32))` → `Module.tags == [Tag(type_idx: 0)]`; a module with **two** tags → both, in
  order; the tag section ordered **before** the global section decodes `Ok`, ordered
  **after** it → `Error(SectionOrder)` (proving the `section_rank` placement). Byte fixture
  from Porffor: tag section `0d 03 01 00 17` → `[Tag(23)]`.
- **tag import/export (§D):** `(import "m" "t" (tag (type 0)))` → an `ImportTag(0)` in
  `Module.imports` (byte `04 00 00`); `(export "e" (tag 0))` → `Export("e", ExportTag, 0)`
  (byte `04 00`). A Porffor byte fixture: export `04 00` → `ExportTag`.
- **`exnref` (§B):** `(func (param exnref) (result exnref) local.get 0)` →
  `FuncType([ExnRef], [ExnRef])`; `(local exnref)` → the local vector contains `ExnRef`
  (byte `01 69`); `ref.null exn` → `RefNull(ExnRef)` (bytes `d0 69`); `select (result
  exnref)` → `SelectT([ExnRef])`; `(block (result exnref) …)` → `Block(BlockVal(ExnRef))`
  (opener byte `02 69`, blocktype `-23`). A `0x69` byte in a **number-only** position
  (e.g. an `i32.const`'s… n/a) — assert `0x69` as an *instruction* opcode still decodes
  `I32Popcnt` (context disambiguation preserved).
- **`throw` / `throw_ref` (§E):** `throw 0` → `Throw(0)` (bytes `08 00`); a `throw` with a
  multi-byte tagidx LEB (`08 80 01` = tag 128) → `Throw(128)` (proves LEB, not a raw
  byte); `throw_ref` → `ThrowRef` (byte `0a`).
- **`try_table` + catches (§E, anti-swap):** the ground-truth four-clause fixture `1f 7f
  04 00 00 01 01 00 00 02 01 03 00 …` → `TryTable(BlockVal(I32), [Catch(0,1),
  CatchRef(0,0), CatchAll(1), CatchAllRef(0)])`; a **distinct-index** clause `catch tag=1
  label=3` → `Catch(1, 3)` (**not** `Catch(3, 1)` — anti-swap); an empty catch vector
  `1f 40 00` → `TryTable(BlockEmpty, [])`; a `try_table` with a `v128`/`exnref`/typeidx
  blocktype decodes the blocktype correctly.
- **`try_table` nesting:** a `try_table` whose body contains a nested `block`…`end` and
  whose own `end` terminates it correctly (proves `TryTable` is counted as a block-opener);
  a function whose body ends with `try_table … end` at top level decodes the trailing
  `End` as the function terminator, not the `try_table`'s.
- **legacy EH (§F, Porffor byte fixtures):** the real Porffor func-3 body region → the
  legacy nodes: `06 40` → `TryLegacy(BlockEmpty)`; `07 00` → `LegacyCatch(0)`; `08 00` →
  `Throw(0)`; the whole `try …/catch 0 …/end` decodes with correct depth (the `catch`
  marker at the same depth as the body, the `end` closing the try). Authored legacy
  fixtures for the constructs Porffor omits: `catch_all` (`19`) → `LegacyCatchAll`;
  `delegate 1` (`18 01`) → `LegacyDelegate(1)` closing a nested try; `rethrow 0` (`09 00`)
  → `Rethrow(0)`.
- **Porffor end-to-end decode:** the committed `porffor` EH sample (`eh.wasm`) decodes
  `Ok` to a `Module` with `tags == [Tag(_)]`, an `ExportTag`, the two `""` `ImportFunc`s
  (n/a — they're func imports), and the legacy `TryLegacy`/`LegacyCatch`/`Throw` nodes in
  the expected function — the concrete proof that decode accepts real Porffor output.
- **neutrality:** the Phase-1..6 fixtures decode **unchanged** (no EH node, `tags == []`).

### 2. Fail-closed fuzz on the EH surface (extend the battery)

Each returns a **specific `DecodeError`**, never a panic/`let assert`/loop:

- a tag with a non-`0x00` attribute (`0d 03 01 01 00`) → `BadTagAttribute`; an imported tag
  with a non-`0x00` attribute → `BadTagAttribute`;
- a `try_table` catch clause with a kind byte `>= 0x04` (`1f 40 01 04 …`) → `BadCatchKind`;
- a truncated tag section (attribute present, typeidx at EOF) → `Truncated`; a truncated
  catch vector (count says 2, one clause present) → `Truncated`;
- a `throw`/`catch`/`delegate`/`rethrow` with the index LEB truncated → `Truncated`;
  over-wide → `LebOverflow`/`LebTooLong`;
- a `try_table` whose blocktype byte is a bad negative s33 → `BadBlockType`;
- an import/export desc kind byte `0x05` → `BadImportKind` / `BadExportKind` (the added
  `0x04` did not widen the *rejection* boundary further);
- a `0x69` byte in a tabletype element position — **accepted** as `ExnRef` (`exn` is a
  heaptype) — but a `0x7B` (v128) there still → `BadHeapType` (unchanged);
- a legacy `delegate` at block depth 0 (no open try) → rejected fail-closed
  (`UnknownOpcode(0x18)`), never a negative-depth loop;
- **the single-byte-mutation + truncation sweep** over every new EH fixture always yields
  `Ok(_) | Error(DecodeError)` — the property is *totality*;
- assert (grep in a test or by inspection) that `decode.gleam` contains no `let assert`,
  `panic`, or `todo`.

### 3. The EH opcode-map audit (spec-exhaustive)

A sweep asserting **exactly** the eight assigned EH opcodes decode `Ok` to the §E/§F node
(`0x06 try`, `0x07 catch`, `0x08 throw`, `0x09 rethrow`, `0x0A throw_ref`, `0x18
delegate`, `0x19 catch_all`, `0x1F try_table`) with a minimal well-formed immediate, and
the four catch-clause kinds (`0x00..0x03`) decode `Ok` while `0x04` → `BadCatchKind`. This
is the change-detector-proof form of §E/§F: it is derived from the spec/measured opcode
tables, so a mis-transcribed opcode fails it.

### 4. Neutrality + clean build

The full Phase-1..6 decode fixture suite still decodes to the **same** AST (up to the
mechanical `ValType`/`Module` widening — the `ExnRef` constructor and EH nodes are simply
never produced, `tags == []`). `gleam test` stays green (≥ the current count + the new
tests). `gleam format --check src test` clean; `gleam build` **zero warnings** (no
leftover `todo`/unused). Every new/changed public type, constructor, and function has a
`///` doc comment stating its contract, immediate order, accepted byte ranges, and failure
modes (D8).

### 5. `«WASM-AST5»` announced

In `state.md` the moment the types compile (day 1), listing: `ValType` gaining `ExnRef`;
`Module` gaining `tags`; the new `Tag` and `Catch` types; `ImportDesc` gaining
`ImportTag`; `ExportKind` gaining `ExportTag`; the EH `Instr` constructors (`Throw`,
`ThrowRef`, `TryTable`, `TryLegacy`, `LegacyCatch`, `LegacyCatchAll`, `LegacyDelegate`,
`Rethrow`); and the new `DecodeError` variants `BadTagAttribute`, `BadCatchKind` — for
04/05.

**Spec citations to use in tests:** the WebAssembly exception-handling proposal
([github.com/WebAssembly/exception-handling](https://github.com/WebAssembly/exception-handling))
and the merged core spec: binary/modules.html#tag-section (id 13; `tag ::= 0x00 typeidx`),
binary/modules.html#import-section / #export-section (desc kind `0x04`),
binary/instructions.html (the EH opcodes `throw`=`0x08`, `throw_ref`=`0x0A`,
`try_table`=`0x1F` + the catch grammar `0x00..0x03`; the legacy `try`=`0x06`,
`catch`=`0x07`, `catch_all`=`0x19`, `delegate`=`0x18`, `rethrow`=`0x09`),
binary/types.html (the `exnref`/`exn` heaptype byte `0x69`), and
binary/instructions.html#binary-blocktype (the `-23` `exnref` blocktype). For the legacy
surface, the **measured Porffor 0.61.13 output** is the ground truth (§F).

## What this unit leaves for others

- **04 (validate)** consumes `«WASM-AST5»`: it types the exception operand stack; checks
  that a tag's `FuncType` has **empty results** (`[t*] → []`); that a `throw x`'s stack
  operands match `types[tag]`'s params; that a `try_table`/legacy-`catch` clause's
  `labelidx` targets a block whose result type is the tag payload (`+ exnref` for the
  `_ref`/legacy handlers); range-checks every `tagidx`/`labelidx`; types `throw_ref`/
  `rethrow`/`exnref`; and enforces `exnref`'s value-position restrictions — all
  fail-closed (`assert_invalid`). It also decides where `exnref` may legally appear
  (table/global/element).
- **05 (lower)** maps AST5 → the IR EH nodes (keystone J2): `ast.ExnRef → ir.TExnRef`;
  `Tag(type_idx) → ir.TagDecl(...)` (resolving the functype); `Throw(tag) →
  ir.Throw(tag, args)`; `TryTable(bt, catches) → ir.TryTable(result, body, clauses)`
  (the catch-clause `labelidx` → the IR's named-label targets, D6); `ThrowRef →
  ir.ThrowRef(exnref)`; and **unifies the legacy nodes** (`TryLegacy`/`LegacyCatch`/
  `LegacyCatchAll`/`LegacyDelegate`/`Rethrow`) onto the **same** IR (§F.3). Lower is the
  adapter between this unit's WASM-shaped AST and the keystone's language-neutral IR.
- **06 (emit_core)** maps the IR EH nodes onto Core Erlang `try…catch`/`throw`/`raise`
  and mints the build-controlled tag term (the binding chokepoint) — it never sees this
  unit's `ast` nodes.
- **07 (rt_exn)** implements the tagged-exception runtime (throw/match/rethrow, the
  `exnref` forge-proof handle) the §C/§E/§F constructs name.
- **08/09 (Porffor shim + JS harness)** rely on decode accepting **real Porffor output**
  (the legacy EH surface, §F) — without it the JS corpus does not decode.
- **The keystone (P7-01)** must confirm its EH-IR taxonomy can express **both** the modern
  and legacy surfaces this unit decodes (§F.3) — the definitive EH construct set for the
  phase is §C–§F here.
- **The `.ir` textual form (P7-02)** round-trips the IR EH nodes; the WAT parser (if
  un-skipped) targets this same AST5.

## Deviations from the overview / ABI findings

Each is ARGUED for the critique + reconciliation to adjudicate.

- **D1 — Porffor emits LEGACY `try`/`catch`, not modern `try_table` (measured).** The
  overview (J1) and `PORFFOR-ABI-FINDINGS.md` (the "measured" doc) state Porffor emits
  `try_table`/`catch`. **Direct measurement of Porffor 0.61.13 (§F) proves it emits the
  legacy `try` (`0x06`) / `catch` (`0x07`) / `throw` (`0x08`) / `end` — in every exception
  mode — never `try_table` (`0x1F`).** (The findings doc's own *prose* says "`throw`" +
  "`catch`", which is consistent with legacy; the "`try_table`" label is the overview's
  interpretive error.) **Why this matters:** the phase goal is *JS on the BEAM*; the JS
  harness (P7-09) runs *Porffor output*; if decode handles only `try_table` that Porffor
  never emits, **nothing runs**. **Resolution:** this unit decodes **both** surfaces — the
  modern one (spec-stable, conformance-tested, the AST/IR target) and the legacy one
  (measured-Porffor, required for the goal), both unified by lower onto the one
  structured-exception IR. The overview + findings should be corrected. This is the **top
  reconciliation item**. *(If the planner pins modern-only, the phase is blocked on a
  Porffor feature that does not exist — see §F.4.)*
- **D2 — the EH op enum is AST-private, not shared with the IR.** The keystone (J2) owns
  the IR EH nodes (`ir.Throw`/`ir.TryTable`/`ir.ThrowRef`/`ir.TExnRef`/`ir.TagDecl`). This
  unit defines its **own** `ast.Tag`/`ast.Catch`/`ast.ExnRef` + the EH `Instr`
  constructors, distinct from the IR's, bridged by lower. **Why:** the P5-03 frozen rule
  is that the WASM AST does **not** import `ir.gleam` (it is the frontend's private,
  WASM-shaped model). This mirrors P6-03's `ast.SimdOp` vs `ir.SimdOp`. The cost is one
  relabel pass in lower — the same cost every AST opcode already pays.
- **D3 — legacy handlers are decoded as in-stream markers, not normalized to `TryTable`
  at decode.** Decode is structural; normalizing interleaved legacy handlers into
  `try_table`'s immediate-vector form requires *restructuring* the stream (a lowering
  transform). So decode keeps `TryLegacy`/`LegacyCatch`/… faithful and lower unifies (§F.3
  / A.5 note). *(Decode-time normalization is the alternative — Open Q1.)*
- **D4 — the tag AST stores only `type_idx`; the `0x00` attribute is checked + dropped.**
  Like the funcref `elemkind` (which decode checks `== 0x00` and does not store), the tag
  attribute has one legal value (exception); a non-`0x00` byte is `BadTagAttribute`. No
  attribute field is added (nothing to represent). Trivially extensible if a future
  attribute is standardized.
- **D5 — `exnref` joins `ValType` (not a separate `RefType`).** Matches the frozen AST
  choice that a reftype is the `FuncRef`/`ExternRef`(/now `ExnRef`) subset of `ValType`,
  positionally validated by `decode_reftype`. `exn` is a real absheaptype (`0x69`), so —
  unlike `v128` — `decode_reftype` accepts it (for `ref.null exn`). 1:1 with `ir.TExnRef`.
- **D6 — two new `DecodeError` variants (`BadTagAttribute`, `BadCatchKind`), no more.**
  Every other EH malformation reuses an existing variant (§A.6). Each added variant
  encodes a *distinct* `assert_malformed` the fuzz suite exercises (the non-`0x00`
  attribute; the `>= 0x04` catch kind).

## Cross-unit seams (flag for reconciliation)

- **S-EHSURFACE (03 ↔ 01/05/08/09).** *The* seam. This unit decodes **both** modern
  (`try_table`) and legacy (`try`/`catch`) EH; the keystone's IR (01) and lower (05) must
  express/unify both; the Porffor shim + JS harness (08/09) depend on the **legacy** path
  (measured, §F). Reconciliation must ratify "decode + lower handle both surfaces" and
  correct the overview/findings (Deviation D1).
- **S-EXNREF (03 ↔ 01/05).** `ast.ExnRef` ↔ `ir.TExnRef`; lower maps; non-EH modules stay
  byte-identical. 1:1 like `FuncRef`/`TFuncRef`. The keystone must include `TExnRef`
  (opaque, forge-proof — reuse `rt_ref`, per the overview's open Q(b)).
- **S-TAGSPACE (03 ↔ 04/05).** The tag index space is *imported-then-defined*: imported
  tags live in `Module.imports` (`ImportTag`), defined tags in `Module.tags`. Validate/
  lower compute the split (as they already do for tables/memories/globals). Confirm 04/05
  index the combined space (`imported tags ++ Module.tags`) so a `throw`/`catch` `tagidx`
  resolves correctly. This unit adds **no** `imported_tag_count` field (derivable) —
  flag if 04/05 prefer it precomputed.
- **S-TAGTYPE (03 ↔ 04).** A tag's `type_idx` names a `FuncType` whose **results must be
  empty** (`[t*] → []`, spec) — validate's check, not decode's. The tag's *params* are the
  exception payload types; Porffor's tag is `(param f64 i32)` (the value-ABI pair, opaque
  to decode). Confirm 04 enforces empty-results and resolves `type_idx` in range.
- **S-CATCHLABEL (03 ↔ 04/05).** Decode stores raw catch-clause `tag`/`label` indices;
  validate owns the range + type checks (the label targets a block whose result is the tag
  payload, `+ exnref` for `_ref`), and lower maps the `labelidx` onto the IR's named-label
  targets (D6). Confirm 04/05 apply them.
- **S-LEGACYUNIFY (03 ↔ 05).** Lower unifies the legacy nodes (`TryLegacy`/`LegacyCatch`/
  `LegacyCatchAll`/`LegacyDelegate`/`Rethrow`) onto the modern IR (§F.3). Confirm 05 owns
  this transform (decode does not).

## Open questions (for the planner / cross-unit sync)

- **Q1 — decode-time legacy→modern normalization?** I default to decoding legacy as
  faithful markers + lower unifying (D3, preserves "decode does not transform"). The
  alternative — decode normalizes legacy `try`/`catch` into `TryTable` nodes directly —
  would give 04/05 a single EH shape, but forces a stream-restructuring *transform* into
  the parser. Recommend the marker form (smaller, faithful); flag for P7-01/P7-05.
- **Q2 — `BadDelegate` vs reusing `UnknownOpcode(0x18)` for a depth-0 `delegate`.** A
  legacy `delegate` with no open try is malformed; I reject it fail-closed by reusing
  `UnknownOpcode(0x18)` (no new variant). A dedicated `BadDelegate` would be clearer but
  adds a variant for a case Porffor never emits. Recommend the reuse; flag if 04 prefers a
  named error.
- **Q3 — should decode reject legacy EH under a modern-only profile, or always accept?** I
  always accept both (decode is the parser; profile posture is a *validate/pipeline*
  concern). If a "strict-modern" mode is wanted (reject legacy), that is validate's gate,
  not decode's. Recommend always-accept at decode; flag for P7-04/P7-08.
- **Q4 — `exnref` in tables/globals/elements: decode-accept, validate-reject?** I
  decode-accept `0x69` in every reftype position (structural), leaving the placement
  restriction to validate (`assert_invalid`). Confirm 04 owns which positions are legal
  for `exnref` (the spec restricts it). Flag for P7-04.
