# Unit 01 — Interface Freeze (Phase-7 keystone)

> **One owner. The spine of the phase. On the critical path of everything.** Read
> [`00-overview.md`](00-overview.md) (J1–J8) first, then
> [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md), then the Phase-1…6 overviews +
> [`../phase-6/RECONCILIATION.md`](../phase-6/RECONCILIATION.md) (D1–D10 … S1–S15). Phase 7 is the
> **goal phase** ("JS on the BEAM via Porffor") and the first since Phase 6 to **grow the IR** (J6).
> This unit freezes the **four** contracts the Phase-7 swarm binds to — the **EH-IR extension**
> (`«EH-IR-FROZEN»`: `Module.tags` + `TagDecl` + `ImportTag`/`ExportTag`; the `Throw`/`TryTable`/
> `ThrowRef` `Expr` nodes + the `CatchClause`/`CatchTag` shapes; the `exnref` reference value —
> `RefType.ExnRef` + `ValType.TExnRef`; the effect classification; the `.ir` grammar delta), the
> **`rt_exn` signature heads** (`«RT-EXN-SIG»`: the throw / tag-match / re-raise / capture / throw_ref
> heads, doc-frozen, `todo`-free), the **BEAM-exception lowering contract** (`«BEAM-EXN-LOWERING»`:
> the `{wasm_exn, TagId, Payload}` term shape, `try_table` → Core Erlang `try…catch`, the
> "`catch_all` does **not** catch traps" rule, and the D3a-clean routing), and the **Porffor-ABI
> contract head** (`«PORFFOR-ABI-HEAD»`: the `(f64, i32)` typed-value ABI + the build-fixed `rt_host`
> Porffor-shim shape) — and lands the EH-IR extension **GREEN** (build compiles, `gleam test` passes,
> **zero warnings**) with defaults chosen so every Phase-1..6 module compiles **byte-identically**
> (J6).

The build is currently zero-warning with **1491 passing tests** (conformance **46,529 pass / 1,768
skip / 0 fail** under every shipped `(mode × state_strategy × mem_tier)` binding — the complete
WebAssembly 2.0 surface). **It must stay that way after this unit.** Like the Phase-5/6 keystones
(which grew `ValType`, `Value`, `Expr`, `Module`, and several declaration types), Phase 7 grows
`Module` (a `tags` list), `ImportDecl`/`ExportDecl` (an imported/exported tag variant), `Expr` (three
EH nodes), `RefType` (`ExnRef`), and `ValType` (`TExnRef`). Because Gleam has no default field values
and every exhaustive `case` over these types must stay total, **growing them breaks every exhaustive
match and every full constructor across `ir`/`printer`/`parser`/`effect`/`emit_core`/`lower`/
`ir_lower`/`ir_opt`/`link`.** This unit **enumerates every one** (the reach table below is
load-bearing — treat it as the acceptance checklist, not a sketch), lands them all green with
byte-identical defaults, and **doc-freezes** the `rt_exn` signatures + the BEAM-lowering contract +
the Porffor-ABI head that units 02–10 implement — exactly the posture the Phase-4/5/6 keystones took
(frozen in prose, no `todo` stubs, so no new warnings).

The one structural continuity with Phase 5 (and divergence from Phase 6): **every EH node is an
effect barrier.** Phase 6's pure lane-wise SIMD were the exception; Phase 7's `Throw`/`TryTable`/
`ThrowRef` all read/transfer control (a throw is a non-local transfer; a `try_table` establishes a
handler and alters control flow), so they classify **`Effectful`**, like `Trap`/`Return`/`Loop`. The
load-bearing semantic freeze is instead **the BEAM-exception lowering contract** (§H): a WASM
exception becomes a **BEAM-native exception** (`erlang:error`/`raise` of a build-controlled term),
`try_table` becomes a **Core Erlang `try…catch`**, and — the subtle spec point — `catch_all` catches
**exceptions but not traps**, so the emitted handler matches only the build-controlled
`{wasm_exn, …}` shape and **re-raises everything else** (a `{wasm_trap, …}`, a fuel exhaustion, any
BEAM error). Constant-space loops + preemption survive because BEAM unwinding is native (J7).

---

## Context

Phases 1–6 built the complete, sandboxed, fast, runs-anywhere **WebAssembly 2.0** engine on the BEAM.
That was always the means to the stated end (§8.2): *any Porffor application runs via 2core on the
BEAM* — "JS on the BEAM". The EM homework ([`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md))
measured real Porffor output and found the gap is remarkably narrow: **everything Porffor emits, 2core
already runs after Phase 6 — with exactly one exception: WASM exception handling.** Porffor throws
pervasively (64× in a trivial program — every JS error path / type check), and a JS `try/catch`
compiles to WASM EH. So Phase 7's load-bearing engine work is **exception handling**, which maps
*beautifully* onto BEAM-native `try`/`catch`/`throw` (the same compile-to-Erlang elegance as tail
calls → BEAM tail calls and preemption → the scheduler).

### The measured Porffor EH surface (0.61.13 — re-verified for this freeze)

Compiling JS `try/catch/throw/finally/rethrow/nested` through `npx porffor wasm foo.js foo.wasm` and
inspecting with `wasm-tools print` yields a **tiny, stable** EH surface:

| Construct | Measured in Porffor output | 2core status |
|---|---|---|
| **tag section** (id **13**) | `(tag (param f64 i32))` — **exactly one** tag, carrying the thrown JS value as the `(f64, i32)` typed pair; also **`(export "0" (tag 0))`** | ✗ new (this phase) |
| **`throw`** (0x08) | `throw 0` — **59–61×** in a trivial program | ✗ new |
| **`try … catch <tag> … end`** | present (1–2× per `try`) | ✗ new |
| `catch_all` / `catch_ref` / `delegate` / `rethrow` / `throw_ref` / `try_table` | **absent** across every probe (even `try/finally` + JS `throw e` rethrow) | — |

> **⚠ LOAD-BEARING MEASURED CORRECTION (see §Deviations D1).** The overview + findings + the task
> brief describe Porffor as emitting the **modern** `try_table`. **It does not.** Porffor 0.61.13
> emits the **legacy** exception-handling encoding (`try` = **0x06**, `catch` = **0x07**, `end` =
> 0x0B, `throw` = 0x08). `wasm-tools validate` **rejects** the output without the `legacy_exceptions`
> feature: *"legacy_exceptions feature required for try instruction"*. The IR this unit freezes is
> **binary-encoding-neutral** (D6): both the legacy `try/catch` (Porffor) **and** the modern
> `try_table`/`throw_ref` (the spec `.wast`) lower onto the *same* neutral nodes. **P7-03 (decode)
> owns which encoding(s) to read** — the JS-on-BEAM headline needs the **legacy** decode; the EH
> `.wast` conformance needs the **modern** decode. The keystone's job is only to make the IR
> expressive enough for both. This is flagged prominently and does not change J1's thesis.

### The elegant fit — WASM EH → BEAM-native exceptions (J1)

The BEAM has first-class exceptions (`throw`/`catch`, `error`/`raise`, `try…catch`), reached already
by `rt_trap` (a WASM trap is `erlang:error({wasm_trap, Kind})`, caught by the run-ABI). WASM EH lowers
onto the same machinery:

- a WASM **`(tag)`** → a distinguishable, build-controlled BEAM exception **term** `{wasm_exn, TagId,
  Payload}` (`Payload` = the tag's operand value list);
- **`throw t (vals…)`** → `rt_exn.throw_tag(TagId, Payload)` → an `erlang:error` **raise** of that
  term (routed through `rt_exn`, never an ambient construct — D3a);
- **`try_table` / legacy `try…catch`** → a Core Erlang **`try…catch`** that matches `{wasm_exn, TagId,
  _}`, binds the payload to the clause's target label, and **re-raises a non-matching exception**
  (spec §4.4.9 unwinding) — including re-raising any **trap** untouched, because `catch_all` does not
  catch traps;
- **`throw_ref` / `ThrowRef`** → re-raise the captured exception carried by an `exnref`.

Constant-space loops + preemption are preserved (BEAM unwinding is native — J7). The keystone
(**P7-01**) freezes the EH IR nodes (J2), the `rt_exn` signatures, the BEAM-lowering contract, the
Porffor-ABI head, and the `.ir` grammar delta; it lands green, byte-identical for tag-free modules.

---

## Goal

Freeze `«EH-IR-FROZEN»` / `«RT-EXN-SIG»` / `«BEAM-EXN-LOWERING»` / `«PORFFOR-ABI-HEAD»`, land the EH-IR
extension green and byte-identical, and prove the default-neutrality claim: a module with **no tags**,
**no `Throw`/`TryTable`/`ThrowRef` node**, and **no `exnref`** emits **byte-identical `.core`** to
Phase-6, under both state strategies and every shipped memory tier. Nothing in the Phase-1..6
acceptance corpus or the previously-passing spec suite may move by one atom.

## Files owned (single-owner / additive per D1)

| File | Ownership | This unit's change |
|---|---|---|
| `src/twocore/ir.gleam` | **owner-additive** | The whole EH-IR surface: `Module.tags`; `TagDecl`; `ImportDecl.ImportTag`; `ExportDecl.ExportTag`; the `Throw`/`TryTable`/`ThrowRef` `Expr` nodes; `CatchClause`/`CatchTag`; `RefType.ExnRef`; `ValType.TExnRef`; `reftype_to_valtype`/`valtype_to_reftype` arms. `TrapReason` **unchanged** (reuse — §E). |
| `src/twocore/ir/effect.gleam` | **owner-additive** | Real classification (§D): `Throw`/`TryTable`/`ThrowRef` are **barriers → `Effectful`** (all three in the `True` group); update the import list. Not a stub. |
| `src/twocore/runtime/rt_exn.gleam` | **NEW — owner** | The `rt_exn` **signature heads** (§G), doc-frozen, `todo`-free, with fail-loud `panic` placeholder bodies that unit 07 replaces. Imports only `gleam/dynamic` (+ reuses `rt_ref`'s null sentinel — §C/§G). |
| `src/twocore/ir/printer.gleam` | **land-green reach** (full impl → P7-02) | Minimal compile-satisfying arms for `TExnRef`/`ExnRef`/the three EH nodes/`ImportTag`/`ExportTag` so `.ir` printing stays total; byte-identical for the existing surface. |
| `src/twocore/ir/parser.gleam` | **land-green reach** (full impl → P7-02) | Minimal arms (string-dispatch) for `exnref`/`throw`/`try_table`/`throw_ref`/tag decls; enough for the freeze-test round-trip. |
| `src/twocore/backend/emit_core.gleam` | **land-green reach** (full impl → P7-06) | Compile-satisfying arms: `TExnRef`/`ExnRef` in the valtype/reftype matches; **one `Error(UnsupportedNode(node))` arm per EH `Expr` node**; `ImportTag`/`ExportTag` arms in the import/export folds. Byte-identical existing output preserved. §J. |
| `src/twocore/frontend/wasm/lower.gleam` | **land-green reach** (full impl → P7-05) | `TExnRef`/`ExnRef` arms in `zero_value`/`value_type`/the reftype bridge; `ImportTag`/`ExportTag` in any `ir.ImportDecl`/`ir.ExportDecl` fold it emits. Compile & byte-identical; P7-05 fills the real EH lowering. |
| `src/twocore/middle/ir_lower.gleam` | **land-green reach** (this unit) | Add `Throw`/`ThrowRef` to the leaves arm (`Ok(expr)`); add `TryTable` **recursing into `body`** (like `Block`); add `ImportTag` to the import fold if matched. |
| `src/twocore/middle/ir_opt/pass.gleam` + `ir_opt/aggressive.gleam` | **land-green reach** (this unit) | Add `Throw`/`ThrowRef` to `map_expr`'s leaves arm; `TryTable` recurses into `body`; add `ExportTag`/`ImportTag` arms where those decls are folded. |
| `src/twocore/runtime/link.gleam` | **land-green reach** (this unit) | `ImportTag`/`ExportTag` arms in the `ir.ImportDecl`/`ir.ExportDecl` matches — minimal (an imported tag is a link-time provided value; the **`ProvidedTag`** identity contract is deferred — §H.4 seam). |
| Test corpus | **land-green reach** (this unit) | Every **full** `ir.Module(...)` constructor gains `tags: []`; the freeze test. `..spread` constructors absorb the field automatically. |

**Seam-doc only (frozen in this doc, implemented by the named unit):** the `rt_exn` bodies (§G — unit
07); the `core_erlang.gleam` `CTry` construct + printer + `core_lint` + the real EH codegen (§H —
unit 06); the Porffor `rt_host` registry + the `(f64,i32)` run-ABI (§I — unit 08); the `.ir` grammar
delta (§F — unit 02); the `frontend/wasm/ast.gleam` EH AST + `decode`/`validate`/`lower` EH pipeline
(units 03/04/05); the run-ABI **uncaught-exception outcome** (§E/§H — unit 06 + the harness 09). This
unit does **not** claim those files.

## Deliverables & freeze milestones

1. **`«EH-IR-FROZEN»`** — `ir.gleam` (all of §A–§E) + `ir/effect.gleam` (§D) landed green +
   byte-identical defaults; the `.ir` grammar delta **sketched** here (§F, owned + reconciled by
   P7-02). Unblocks **02, 03, 04, 05, 06, 07, 09, 10**.
2. **`«RT-EXN-SIG»`** — the `runtime/rt_exn.gleam` public heads (§G), doc-frozen and `todo`-free
   (fail-loud `panic` bodies), so 06/07 implement bodies / the emit mapping without racing signatures.
   Unblocks **06, 07**.
3. **`«BEAM-EXN-LOWERING»`** — the `{wasm_exn, TagId, Payload}` term shape + the `try_table` → Core
   Erlang `try…catch` contract + the "`catch_all` does not catch traps" rule + the D3a routing + the
   `CTry` seam (§H). Frozen in prose; the `CTry`/codegen is P7-06. Unblocks **06, 07, 09**.
4. **`«PORFFOR-ABI-HEAD»`** — the `(f64, i32)` typed-value ABI + the build-fixed `rt_host`
   Porffor-shim registry shape + the fail-closed rule (§I). Frozen in prose; the impl is P7-08.
   Unblocks **08, 09**.

**Out of scope for this unit:** any EH decode/validate/lower logic (03/04/05); the real EH codegen +
the `CTry` construct (06); the `rt_exn` bodies (07); the Porffor registry + the value-ABI decode (08);
the JS harness (09); the conformance/close (10). This unit ships the EH-IR types (real, total, zero
`todo`) + the frozen `rt_exn` signatures + the lowering contract + the Porffor-ABI head + the
land-green reach + a scratch freeze test.

## Depends on (freeze milestones)

None upstream — this is Wave-0, the keystone. It consumes the Phase-6 `ir.gleam`/`rt_trap`/`rt_ref`/
`rt_host` shapes (already green) and freezes on top of them.

---

## Land-green cross-file reaches (enumerate EVERY one)

Growing `Module` (`tags`), `ImportDecl`/`ExportDecl` (`ImportTag`/`ExportTag`), `Expr` (three EH
nodes), `RefType` (`ExnRef`), and `ValType` (`TExnRef`) breaks every exhaustive `case` over these
types and every **full** constructor. The `..spread` sites absorb the `Module.tags` field. Each row
**must** be landed for the tree to stay green; the "full impl" column names the unit that later
replaces a minimal arm with the real one.

| # | File · symbol | What breaks | Land-green edit (this unit) | Full impl |
|---|---|---|---|---|
| 1 | `ir.gleam` | owner-additive | Add everything in §A–§D. `TrapReason` unchanged (§E). | — |
| 2 | `ir.gleam` · `reftype_to_valtype` / `valtype_to_reftype` | 1 exhaustive `RefType` `case` (+ 1 `_`-catch-all) | `ExnRef -> TExnRef`; `TExnRef -> Ok(ExnRef)`. | — (this unit) |
| 3 | `ir/effect.gleam` · `is_effectful_node` + import | exhaustive `Expr` `case` | Add `Throw(_,_)` \| `TryTable(_,_,_)` \| `ThrowRef(_)` to the **`True`** (barrier) group; import them. **Real (§D).** | — (this unit) |
| 4 | `ir/printer.gleam` · `print_valtype`, `print_reftype`, `print_value`, `print_expr` | exhaustive `ValType`/`RefType`/`Expr` `case`s | `TExnRef -> "exnref"`; `ExnRef -> "exnref"`; one arm per EH node (any spelling — conformance-neutral); tag-decl / import-tag / export-tag print arms. Byte-identical existing surface. | **P7-02** |
| 5 | `ir/parser.gleam` · `parse_valtype`, `parse_reftype`, `parse_expr`, decl parsers | string-dispatch (NOT a hard break) | Add `"exnref"`, `"throw"`, `"try_table"`, `"throw_ref"`, tag decls; enough for the freeze-test round-trip. | **P7-02** |
| 6 | `backend/emit_core.gleam` · `valtype_atom`, `result_width`, `is_reference_type`, `emit` dispatch, import/export folds | 3 exhaustive `ValType` `case`s + the `Expr` dispatch + the decl folds | `TExnRef -> "exnref"` / `-> 32` / `is_reference_type -> True`; **one `Error(UnsupportedNode("throw"/"try_table"/"throw_ref"))` per EH node**; `ExnRef` reftype arm; `ImportTag`/`ExportTag` fold arms (inert — no emitted state). Byte-identical existing output. §J. | **P7-06** |
| 7 | `frontend/wasm/lower.gleam` · `zero_value`, `value_type`, reftype bridge, `ir.Import`/`ir.Export` builders | exhaustive `ValType`/`RefType` `case`s | `TExnRef -> ConstNull(ExnRef)`; `ConstNull(ExnRef) -> TExnRef`; `ExnRef` reftype arm. Compile & byte-identical; P7-05 fills real EH lowering + `ImportTag`/`ExportTag` production. | **P7-05** |
| 8 | `middle/ir_lower.gleam` · `lower_expr` (+ import fold) | exhaustive `Expr` `case` | `Throw`/`ThrowRef` → leaves arm (`Ok(expr)`); `TryTable` → **recurse into `body`** (like `Block`, so a metered/gated body is preserved); `ImportTag` arm if the import fold matches. | — (this unit) |
| 9 | `middle/ir_opt/pass.gleam` + `aggressive.gleam` · `map_expr` (+ decl folds) | exhaustive `Expr` `case` | `Throw`/`ThrowRef` → leaves (`-> e`); `TryTable` → recurse into `body`; `ExportTag`/`ImportTag` decl arms. | — (this unit) |
| 10 | `runtime/link.gleam` · `ir.ImportDecl`/`ir.ExportDecl` matches | 2 exhaustive decl `case`s | `ImportTag(_,_,_)` / `ExportTag(_,_)` minimal arms (an imported tag has no P5-style provided value yet — link-time fail-closed or ignore; the `ProvidedTag` identity is deferred, §H.4). | **P7-05/link** |
| 11 | Test corpus | every **full** `ir.Module(...)` constructor | Add `tags: []`. `..spread` sites unaffected. | mixed |

**The five shape changes that break constructors/matches everywhere** (call them out — they are the
bulk of the diff):

- **`Module` gains `tags: List(TagDecl)`** breaks every **full** `ir.Module(name:, uses_numerics:,
  memories:, …)` constructor (in `src/` at `lower.gleam`, `ir_opt/baseline.gleam`, `parser.gleam`,
  and ~40 test sites). The **`ir.Module(..m, …)` spread** sites (`ir_lower`, `ir_opt/pass`,
  `ir_opt/aggressive`, several tests) **absorb** it. This is the single largest reach — analogous to
  Phase-5 adding `memories`/`tables`/`elements`.
- **`ImportDecl` gains `ImportTag(module, name, params)`** and **`ExportDecl` gains
  `ExportTag(export_name, tag_name)`** break every exhaustive `ir.ImportDecl`/`ir.ExportDecl` match
  (`printer`, `parser`, `emit_core`, `lower`, `ir_lower`, `ir_opt/aggressive`, `link`). Each gets a
  minimal arm (mostly inert — a defined/imported/exported tag emits **no** runtime state under the
  static-`TagId` model of §H).
- **`Expr` gains `Throw`/`TryTable`/`ThrowRef`** breaks the six exhaustive `Expr` matches:
  `print_expr`, `emit`-dispatch, `is_effectful_node`, `lower_expr`, `map_expr`, and
  `ir_opt/aggressive`'s `map_expr`. `parse_expr` (string dispatch) and `expr_touches_state`
  (`emit_core`, `_` catch-all) are **not** hard breaks, but see §D/§J for the semantic arm P7-06 must
  add to `expr_touches_state` (`TryTable` touches state only via its body — a `_`-default is safe;
  `Throw`/`ThrowRef` transfer control → treat as barriers there too).
- **`RefType` gains `ExnRef`** breaks `reftype_to_valtype`, `print_reftype`, and any exhaustive
  `ir.RefType` match. `valtype_to_reftype` (has a `_ -> Error` catch-all) is **not** a hard break but
  gains a `TExnRef -> Ok(ExnRef)` arm. The **decode AST**'s `ast.RefType` (`ast.FuncRef`/
  `ast.ExternRef`) is a **separate** type owned by P7-03 — **untouched here**.
- **`ValType` gains `TExnRef`** breaks `print_valtype`, `valtype_atom`, `result_width`, `zero_value`,
  `value_type` (exhaustive `ValType` matches with **no** catch-all). `is_reference_type`
  (`emit_core:678`, a `ir.TFuncRef | ir.TExternRef -> True` group with a `_ -> False` catch-all) is
  **not** a hard compile break, but leaving it would **mis**classify an exnref as a non-reference (it
  would route an exnref-typed global through the numeric `Int` path instead of `rt_state`'s boxed
  `ref_globals` map) — so `TExnRef` **must** be added to the `True` group (a semantic must-add, like
  Phase-6's `expr_touches_state`). Every `ValType` match **with** a `_` catch-all that treats
  non-references uniformly is otherwise unaffected.

Announce all four milestones in `specs/phase-7/state.md` with this reach list, exactly as the
Phase-2..6 keystones did.

---

## A. `«EH-IR-FROZEN»` — `Module.tags`, `TagDecl`, imported/exported tags (J2)

A **tag** (the EH proposal's *exception type*) is a module-level declaration carrying an operand
signature — exactly the shape of a `GlobalDecl`, and threaded through `Module`/imports/exports the
**same way globals are** (the P5 import/export-state pattern the task names). This is the neutral,
consistent choice: nothing about tags is WASM-specific (a generic "named exception class carrying a
typed payload", reusable by a future JS/Gleam frontend — J2/decision #1).

### A.1 `Module` gains one field

```gleam
pub type Module {
  Module(
    name: String,
    uses_numerics: Bool,
    memories: List(MemoryDecl),
    globals: List(GlobalDecl),
    imports: List(ImportDecl),
    functions: List(Function),
    exports: List(ExportDecl),
    data_segments: List(DataSegment),
    tables: List(TableDecl),
    elements: List(ElementSegment),
    start: Option(String),
    /// The module's own **exception tags** (J2). Each `TagDecl` names an exception class and its
    /// operand signature. `[]` (the default) means the module declares no tags — the
    /// conformance-neutral case, byte-identical to Phase-6. The list position **is** the tag-index
    /// space (as `memories`'s position is the memory-index space), so a `Throw`/`TryTable`-catch
    /// referencing a same-module tag resolves by name (D6 — never a numeric index in the IR core).
    /// Imported tags are declared in `imports` (`ImportTag`), NOT here; `tags` holds module-DEFINED
    /// tags only, exactly as `globals` holds module-defined globals and `ImportGlobal` the imports.
    tags: List(TagDecl),
  )
}
```

### A.2 `TagDecl` — a name + an operand signature

```gleam
/// An exception-tag declaration (J2). A tag is a build-controlled exception CLASS carrying a typed
/// payload — the operand `ValType`s the exception transports (spec: a tag's type is a `FuncType`
/// whose results MUST be empty; only `params` are meaningful for an exception tag). NEUTRAL: a
/// generic named exception class, not a WASM opcode (D6).
///
/// - `name`: the tag's unique name within the module (referenced by `Throw` and `CatchTag.OnTag`,
///   and by `ExportTag`). Frontend-conventional (`tag0 … tag{n-1}`), like `p0`/global names.
/// - `params`: the operand value types the exception carries. Measured for Porffor: `[TF64, TI32]`
///   (the `(f64, i32)` typed JS value). May be `[]` (a payload-less tag) or any `ValType` list.
pub type TagDecl {
  TagDecl(name: String, params: List(ValType))
}
```

### A.3 Imported / exported tags (the P5 pattern)

```gleam
pub type ImportDecl {
  ImportFn(capability: String, name: String, ty: FuncType)
  ImportGlobal(module: String, name: String, ty: ValType, mutable: Bool)
  ImportTable(module: String, name: String, ref_ty: RefType, min: Int, max: Option(Int))
  ImportMemory(module: String, name: String, min_pages: Int, max_pages: Option(Int), idx_type: IdxType)
  /// An imported exception tag (J2 — the P5 import/export-state pattern). Provided state, not a
  /// capability: its RUNTIME IDENTITY is the exporter's (an exception thrown with the exporter's
  /// tag is caught by a `catch` on this import — spec §4.5.4 tag matching). `params` is the declared
  /// operand signature, link-matched against the provider fail-closed (spec §3.2). No Phase-1..6
  /// module has one; Porffor (single-module) never imports a tag. The link-time identity resolution
  /// (`ProvidedTag`) is DEFERRED (§H.4 seam) — the keystone freezes the decl shape only.
  ImportTag(module: String, name: String, params: List(ValType))
}

pub type ExportDecl {
  ExportFn(export_name: String, fn_name: String)
  ExportGlobal(export_name: String, global_name: String)
  ExportTable(export_name: String, table_name: String)
  ExportMemory(export_name: String, mem_index: Int)
  /// Exports the module-defined tag named `tag_name` (J2). Measured: Porffor emits
  /// `(export "0" (tag 0))`, so this arm IS exercised by real output — but the export is **inert for
  /// single-module execution** (nothing imports it), so `emit_core` emits no state for it (§J).
  ExportTag(export_name: String, tag_name: String)
}
```

Spec anchor: the **tag section** (id **13**) declares tags; a tag has an attribute byte (`0x00`
exception) + a type index whose `FuncType` gives the operand signature (results empty)
([EH proposal — tags](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md);
core-spec §2.5.4 / §5.5.15). The exact section/byte decode is **P7-03**'s freeze; the IR is
opcode-neutral (D6) — cited only as the surface these decls model.

---

## B. `«EH-IR-FROZEN»` — the EH `Expr` nodes + catch clauses (J2)

Three new `Expr` variants, **all effect barriers** (§D), added to `Expr`:

```gleam
// ── Phase-7 exception handling (J1/J2) — three effectful barriers. A generic structured-exception
// model (throw a value / guard-and-catch by class / re-raise a handle), NOT WASM opcodes (D6). ──
/// `throw <tag> (args…)` — raise exception `tag` (a same-module `TagDecl` name) carrying `args` as
/// its payload. **Does not return** — bottom, exactly like `Return`/`Trap` (spec §4.4.9: `throw`
/// transfers control, the rest of the block is unreachable). `args` arity + types match the tag's
/// `params`. Lowers to `rt_exn.throw_tag(TagId, Payload)` (§H). Effectful (a non-local transfer).
Throw(tag: String, args: List(Value))
/// `try_table result body catches` (modern) / legacy `try body catch* end` — evaluate `body`; on a
/// thrown exception, each `CatchClause` is tried in order: a matching clause transfers control to its
/// target `label` (a block/loop label in scope, D6) carrying the payload (and an `exnref` if
/// `capture_exnref`); an unmatched exception **propagates** (re-raised). `body` falling through
/// yields `result`. Lowers to a Core Erlang `try…catch` (§H). Effectful (establishes a handler +
/// alters control flow — a barrier). `result` is the block type the try region produces on normal
/// completion.
TryTable(result: List(ValType), body: Expr, catches: List(CatchClause))
/// `throw_ref <exnref>` — re-raise the exception referenced by the `exnref` value `exnref`
/// (produced by a `capture_exnref` catch clause). **Does not return** — bottom (spec §4.4.9). A
/// null `exnref` traps (`ref.null exn` re-thrown → a trap — validate/emit uphold). Lowers to
/// `rt_exn.throw_ref(ExnRefValue)` (§H). Effectful (a non-local transfer).
ThrowRef(exnref: Value)
```

```gleam
/// One catch clause of a `TryTable` (J2). The task's `(tag-or-catch_all, label, capture-exnref?)`
/// triple, made total: `on` selects which exceptions this clause handles; `label` is the target it
/// transfers control to (with the payload values, then the `exnref` if `capture_exnref`);
/// `capture_exnref` is the ref/non-ref distinction of the modern proposal.
///
/// The four modern clause kinds map 1:1:
/// - `catch $t $l`        → `CatchClause(OnTag($t), $l, False)`   (0x00)
/// - `catch_ref $t $l`    → `CatchClause(OnTag($t), $l, True)`    (0x01)
/// - `catch_all $l`       → `CatchClause(OnAll,     $l, False)`   (0x02)
/// - `catch_all_ref $l`   → `CatchClause(OnAll,     $l, True)`    (0x03)
/// The legacy `catch $t H` / `catch_all H` (Porffor) normalize onto `OnTag`/`OnAll` with
/// `capture_exnref = False` and a synthesized handler label (P7-05 owns the normalization).
pub type CatchClause {
  CatchClause(on: CatchTag, label: String, capture_exnref: Bool)
}

/// What a `CatchClause` catches (J2).
/// - `OnTag(tag)`: catch exceptions thrown with the same-module tag named `tag` (spec tag-identity
///   match); the tag's payload is bound to the target label.
/// - `OnAll`: catch ANY exception (`catch_all`) — but per spec, **exceptions only, NOT traps** (a
///   trap is re-raised untouched; the emitted handler enforces this — §H.2). No payload is bound
///   (an all-catch carries no operand types).
pub type CatchTag {
  OnTag(tag: String)
  OnAll
}
```

**No new `Value` constructor.** An `exnref` value flows as an ordinary `Value` — a `Var` bound by a
`capture_exnref` catch label (`ThrowRef(Var("e"))`), or `ConstNull(ExnRef)` for `ref.null exn` (§C).
This reuses the whole ANF/operand machinery unchanged.

Spec anchors: `throw` = **0x08**, `throw_ref` = **0x0A**, `try_table` = **0x1F** with the catch-clause
kinds **0x00** `catch` / **0x01** `catch_ref` / **0x02** `catch_all` / **0x03** `catch_all_ref`
([EH proposal — instructions](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md#instructions);
core-spec §5.4.1). **Measured legacy (Porffor):** `try` = **0x06**, `catch` = **0x07**, `end` = 0x0B,
`throw` = 0x08 (shared). The IR node captures the *semantics*; **P7-03 owns the byte decode** of
whichever encoding(s) are in scope (D1).

---

## C. `«EH-IR-FROZEN»` — `exnref` as a reference value (Open Q b — resolved: REUSE `rt_ref`)

An `exnref` is a **caught-exception handle** — the modern proposal's `(ref null exn)`, pushed by
`catch_ref`/`catch_all_ref`, consumed by `throw_ref`, nullable (`ref.null exn`), and **opaque**
(inspect-proof — you can only re-throw / null-test / pass / store it). The keystone models it by
**extending the reference layer**, not inventing a parallel one:

- **`ValType` gains `TExnRef`** — a reference-typed value (locals/params/blocktypes/try-table
  results carry it).
- **`RefType` gains `ExnRef`** — so `ConstNull(ExnRef)` expresses `ref.null exn`, and exnref rides
  the whole Phase-5 reference machinery (tables/elements/typed `select`/the shared null sentinel).

```gleam
pub type ValType {
  TI32  TI64  TF32  TF64  TTerm  TFuncRef  TExternRef  TV128
  /// An `exnref` (`(ref null exn)`, J2) — a caught-exception handle. A REFERENCE value (term-layer,
  /// like funcref/externref — never the raw-bit numeric path): it flows as a `Dynamic`, is nullable,
  /// and is OPAQUE in Safe mode (holdable/passable/storable/null-testable/re-throwable, but its
  /// underlying BEAM exception is NOT inspectable — H6/J5). Placed AFTER `TV128` so it falls to the
  /// reference/`_` arm of every `ValType` match with a catch-all; the exhaustive matches gain an
  /// explicit `TExnRef` arm (§reach). `is_reference_type(TExnRef) == True`.
  TExnRef
}

pub type RefType {
  FuncRef  ExternRef
  /// The `exn` heap type's reference (`exnref`, J2). `ConstNull(ExnRef)` is `ref.null exn`; an
  /// exnref table/element/select carries it. Maps 1:1 onto `TExnRef` via `reftype_to_valtype`.
  ExnRef
}
```

`reftype_to_valtype(ExnRef) == TExnRef`; `valtype_to_reftype(TExnRef) == Ok(ExnRef)` (the two
spellings cannot drift — the Phase-5 invariant).

### C.1 The runtime model — reuse `rt_ref`'s forge-proof wrapping (argued)

The task asks: reuse `rt_ref`'s forge-proof model, or a parallel one? **Reuse it.** An `exnref` at
runtime is a **wrapped, forge-proof term** in the exact `rt_ref` discipline, but its box + capture/
re-raise primitives live in the **new single-owner `rt_exn`** (D1 — `rt_exn` owns EH), reusing
`rt_ref`'s shared null sentinel:

| exnref value | Core Erlang term | Notes |
|---|---|---|
| `null` (`ref.null exn`) | `{ref_null}` (shared with funcref/externref) | `is_null(x)` ⟺ `x =:= {ref_null}` — reuse `rt_ref.is_null`/`null_ref` verbatim |
| a caught exception | `{ref_exn, Caught}` (new box) | `Caught` = the opaque caught `{Class, Reason, Stack}` needed to re-raise faithfully; the box makes it uncollidable with null / a funcref / an externref, and inspect-proof |

Why reuse, not parallel: (a) **maximal reuse** of the *proven* Phase-5 reference machinery — the null
sentinel, `ConstNull`, `is_null`, tables/elements, and the opacity/forge-proofness the whole security
story (H6/J5) already rests on; (b) **spec-faithful** — `exnref` *is* a reftype in the type grammar;
(c) **one new concept** (`{ref_exn, Caught}`), not a whole new value world. The wrapping is what makes
`throw_ref` D3a-clean: `throw_ref` unwraps `{ref_exn, Caught}` and re-raises `Caught` through
`rt_exn` — never an ambient `apply` of a program-chosen term (§H.3).

**Cross-unit note (flag).** `rt_ref.classify_ref` classifies "not-null, not-extern" as `FuncRef` **by
elimination** — an `exnref` `{ref_exn, _}` would misclassify there. This is inert for the Porffor path
(exnref never reaches `classify_ref`) but matters for spec-faithful `throw_ref.wast` judging;
**P7-07** adds an `ExnRef` arm to `rt_ref.RefKind` + `classify_ref` (an additive, downstream
refinement — not a keystone break; `classify_ref`'s tests are structural). Flagged as seam §5.

Spec anchor: `exnref = (ref null exn)`; `exn` is a heap type; `catch_ref`/`catch_all_ref` push an
exnref; `throw_ref` consumes one (null → trap)
([EH proposal — exnref](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md)).
The exact `exn` heap-type byte is **P7-03**'s decode freeze.

---

## D. `«EH-IR-FROZEN»` — effect classification (owner: this unit, REAL not stub)

`ir/effect.gleam` is the optimizer's soundness floor (E6/F3): anything not *proven* pure defaults to
`Effectful`. **All three EH nodes are barriers** — Phase 7 does **not** repeat Phase 6's
pure-lane-op divergence:

| Node | `is_effectful_node` | `classify` | Why |
|---|---|---|---|
| `Throw(tag, args)` | **`True`** | `Effectful` | A non-local control transfer that raises (like `Trap`/`Return`) — must never be reordered, hoisted, duplicated, or eliminated (it *adds/removes an exception* — an F2 observable). |
| `TryTable(result, body, catches)` | **`True`** | `Effectful` | Establishes an exception handler and alters control flow (a `Loop`-like shell that changes semantics); its `body` may be effectful; catching turns a throwing body into a normal result (observable). Conservatively a barrier. |
| `ThrowRef(exnref)` | **`True`** | `Effectful` | Re-raises — a non-local transfer, exactly like `Throw`. |

Concretely, the keystone adds `Throw(_, _) | TryTable(_, _, _) | ThrowRef(_)` to the existing **`True`**
barrier group in `is_effectful_node` (alongside `Trap`/`Break`/`Continue`/`Return`/`Loop`/the call
kinds) and updates `import twocore/ir.{…}` to name the three constructors. `children_all_pure` needs
**no** edit: the three nodes are barriers, so `classify` short-circuits before reaching it (`TryTable`'s
`body` sub-expression is never asked for deep purity — the whole node is already `Effectful`).

This is **strictly the safe direction** (the F3 asymmetry): calling an EH node effectful costs at most
a missed optimization, never a wrong answer. Since the `case` is exhaustive, **omitting any new node
fails to compile** (fail-closed, D4) — an unclassified EH node can never be silently optimized.

---

## E. `«EH-IR-FROZEN»` — `TrapReason` (reuse — **no new variant**; ARGUED, J5)

**The keystone adds ZERO `TrapReason` variants.** A WASM *exception* is **not** a *trap* — the spec
distinguishes them (an uncaught exception surfaces to the embedder via `assert_exception`, never
`assert_trap`). So an uncaught exception must **not** be forced into `TrapReason` (which surfaces as
`Trapped`); it is a **distinct run outcome**.

| Failure on the new surface | Handling | Why no new `TrapReason` |
|---|---|---|
| an **uncaught** `throw`/`throw_ref` propagating out of an exported invocation | a NEW **run-ABI outcome** (e.g. `UncaughtException(TagId, Payload)`), surfaced by the run-ABI catching `{wasm_exn, …}` — **owned downstream** (P7-06 emit + the harness 09), NOT `TrapReason` | spec: an exception is not a trap; distinct assertion (`assert_exception`) |
| a **`throw_ref` of a null `exnref`** | `Trap(...)` with an **existing** reason (spec: re-throwing `ref.null exn` traps) — reuse **`Unreachable`** or `UninitializedElement`-style; **P7-04/06 confirm** which existing message the pinned `.wast` expects (expected: reuses an existing one) | address/ref-null trap, not EH-specific |
| a WASM **trap raised inside a `try_table` body** | re-raised untouched by the emitted handler (**`catch_all` does NOT catch traps** — §H.2) | traps propagate through EH regions |

So `TrapReason` is **unchanged**, and the exhaustive `spec_trap_message` (`rt_trap.gleam:71`) /
`trap_reason_atom` (`emit_core.gleam`) matches are **untouched** — one fewer reach than an IR-growing
keystone would otherwise take, exactly as Phases 5/6 achieved (S8). **Flag (§Open):** if a pinned EH
`.wast` `assert_trap` (e.g. a null-`throw_ref` trap) distinguishes a message the existing set cannot
produce, add **exactly one** variant + its `spec_trap_message` (the Phase-2/3 pattern) — a conscious
add, not a silent one. Expected: **none**.

> **The run-ABI uncaught-exception outcome is a CROSS-UNIT SEAM (flag §1).** `pipeline.RunResult` is
> today `Returned(_) | Trapped(reason: String)`. An uncaught `{wasm_exn, TagId, Payload}` should
> surface **distinctly** from a trap so the JS harness (09) can judge JS `throw`-that-escapes and the
> EH `.wast` `assert_exception`. Whether the run-ABI adds an `UncaughtException(...)` variant or
> renders it through `Trapped`'s string is **P7-06/09's** decision; the keystone freezes only the
> **reason-term shape** `{wasm_exn, TagId, Payload}` it must recognize (§H.1).

---

## F. `«EH-IR-FROZEN»` — the `.ir` grammar delta (sketch; owned + reconciled by P7-02)

Full spelling + round-trip is **P7-02**'s (as IR2/IR3/IR4 were), landing in
`specs/phase-7/ir-grammar-delta.md`. Sketched here so P7-02 and the printer/parser land-green arms
agree:

```
; value / reference types
valtype     ::= … | "exnref"                                     ; TExnRef
reftype     ::= … | "exnref"                                     ; ExnRef  (ConstNull(ExnRef) = "null exnref")
; module-level tag declarations (a section like globals/tables)
tagdecl     ::= "tag" name "(" valtype* ")"                      ; TagDecl(name, params)
importdecl  ::= … | "import.tag" module name "(" valtype* ")"    ; ImportTag
exportdecl  ::= … | "export.tag" export_name tag_name           ; ExportTag
; EH expressions
expr        ::= … | "throw" name value*                          ; Throw(tag, args)
              | "throw_ref" value                                 ; ThrowRef(exnref)
              | "try_table" "(" valtype* ")" "{" expr "}" catch*  ; TryTable(result, body, catches)
catch       ::= "catch" name label ["ref"]                        ; CatchClause(OnTag(name), label, ref?)
              | "catch_all" label ["ref"]                          ; CatchClause(OnAll, label, ref?)
```

**Byte-identity of the `.ir` text (J6).** A Phase-1..6 `.ir` fixture is unchanged: the new tokens
(`exnref`, `tag`, `throw`, `try_table`, `catch*`) appear **only** when a module actually declares a
tag or uses EH. A tag-free module prints no `tag` section (as a global-free module prints no globals).
P7-02 reconciles the exact spelling into `ir-grammar-delta.md`; the keystone guarantees only that the
shape is expressible and the defaults elide.

---

## G. `«RT-EXN-SIG»` — the `rt_exn` signature heads (NEW module; bodies → P7-07)

`runtime/rt_exn.gleam` is a **new** single-owned module, the EH analogue of `rt_trap`: the single
auditable chokepoint for exception fidelity (tier-P — raises, never crashes the node). This unit
**creates the file with every public head, its doc comment, and a fail-loud `panic` placeholder
body**; **unit 07 replaces the bodies.** The keystone fixes the **names, arities, and term shapes**;
the exec *semantics* (§H) are 07's.

### G.1 Conventions (the documented representation contract)

- **The exception term is `{wasm_exn, TagId, Payload}`** (§H.1). `TagId` is a build-controlled
  `Dynamic` tag identity (the static `{tag, ModuleAtom, Index}` term of §H.1 in the first milestone);
  `Payload` is the operand **value list** `List(Dynamic)` (each element a raw-bit `Int` for
  i32/i64/f32/f64 — D5 — a `BitArray` for v128, a boxed `Dynamic` for a reference).
- **A caught exception is `{Class, Reason, Stack}`** — the Core Erlang `try…catch` binds these three;
  `rt_exn` matches/re-raises over them (`reraise` uses `erlang:raise(Class, Reason, Stack)` to
  preserve the original class + stacktrace faithfully).
- **Raising heads are bottom (`-> a`)** — `throw_tag`/`reraise`/`throw_ref` diverge (raise), never
  return, so the emitter can place them in any value position — exactly like `rt_trap.raise`.
- **`rt_exn` REUSES `rt_ref` for the null sentinel** (an `exnref` null is `{ref_null}`, §C) but owns
  the `{ref_exn, Caught}` box + capture/re-raise. The keystone's file imports only `gleam/dynamic`
  (the heads need only `Dynamic`/`List`/`Bool`/`Result`); 07 adds `import twocore/runtime/rt_ref`
  when it fills bodies (so the keystone has no unused-import warning).

### G.2 The placeholder-body posture (todo-free, zero-warning, fail-loud)

Each head lands with a body `panic as "rt_exn.<name>: body pending unit 07"` — **`todo`-free**
(Gleam's `todo` warns; `panic` does not), **zero-warning** (a `pub fn` is never "unused"), and
**fail-loud** (07's differential tests catch any unfilled head; a `panic` in generated code is a
node-safe crash, never a silent wrong answer — D4). No Phase-1..6 module or the keystone's own freeze
test calls `rt_exn` (the keystone's `emit` arms return `UnsupportedNode`, §J), so the placeholders are
never reached until 07. This mirrors the Phase-5/6 keystone posture.

### G.3 The head enumeration (frozen names + arities + shapes)

```gleam
import gleam/dynamic.{type Dynamic}

/// Raise a WASM exception carrying `tag_id` + `payload` as `{wasm_exn, TagId, Payload}` (error
/// class — catchable via `try … catch error:{wasm_exn, _, _}`). NEVER returns (diverges). This is
/// the `Throw`/legacy-`throw`/modern-`throw` lowering target (§H).
pub fn throw_tag(tag_id: Dynamic, payload: List(Dynamic)) -> a

/// `True` iff a caught `Reason` is a WASM exception `{wasm_exn, _, _}` — NOT a WASM trap
/// `{wasm_trap, _}`, a fuel exhaustion, or any other BEAM error. LOAD-BEARING: this is what makes
/// `catch_all` catch **exceptions but not traps** (spec §4.4) — the emitted handler tests it before
/// treating a caught reason as an exception, and re-raises otherwise (§H.2).
pub fn is_wasm_exn(reason: Dynamic) -> Bool

/// Match a caught `Reason` against a specific `tag_id` (the `catch $t` case). `Ok(Payload)` iff
/// `Reason` is `{wasm_exn, tag_id, Payload}` with THE SAME tag identity (spec tag-identity match);
/// `Error(Nil)` otherwise (a different tag, or not a wasm_exn at all → the caller re-raises).
pub fn match_tag(reason: Dynamic, tag_id: Dynamic) -> Result(List(Dynamic), Nil)

/// Wrap a caught exception as an `exnref` handle `{ref_exn, {Class, Reason, Stack}}` (the
/// `catch_ref`/`catch_all_ref` capture — §C). Forge-proof (the box is uncollidable with null / a
/// funcref / an externref) and opaque (Safe code cannot unwrap it — H6/J5).
pub fn capture(class: Dynamic, reason: Dynamic, stack: Dynamic) -> Dynamic

/// Faithfully re-raise a caught exception, preserving its class + stacktrace
/// (`erlang:raise(Class, Reason, Stack)`). The non-matching-clause propagation path (§H.2). NEVER
/// returns.
pub fn reraise(class: Dynamic, reason: Dynamic, stack: Dynamic) -> a

/// Re-raise the exception referenced by an `exnref` (`ThrowRef`/`throw_ref`, §H.3). Unwraps
/// `{ref_exn, Caught}` and re-raises `Caught` faithfully; a NULL exnref traps (spec: re-throwing
/// `ref.null exn` traps — routes through `rt_trap`, §E). NEVER returns.
pub fn throw_ref(exnref: Dynamic) -> a

/// The build-controlled per-module tag identity for the tag at `index` in module `module_atom` —
/// the static `{tag, ModuleAtom, Index}` term (§H.1). Deterministic + D3a-clean (no ambient
/// authority; the inputs are build-time constants). A `Throw` and its catching `try_table` emit the
/// SAME `tag_id(m, i)`, so they match. (Per-instance-fresh identity for spec-faithful cross-instance
/// EH is a downstream refinement — §H.4.)
pub fn tag_id(module_atom: Dynamic, index: Int) -> Dynamic
```

**07 finalizes the bodies** (may add private workers); the keystone freezes the public *shape*
(names, arities, `Dynamic`-vs-`Int` term shapes) so 06 (the emit mapping) and 07 (the bodies) never
race signatures. **07 consumes `rt_ref`/`rt_trap`, never edits them.**

---

## H. `«BEAM-EXN-LOWERING»` — the BEAM-exception lowering contract (J1/J5; codegen → P7-06)

The keystone freezes the **contract** that maps EH IR → Core Erlang; **P7-06 implements it** (adds the
`CTry` Core Erlang construct + the codegen). This is the load-bearing semantic freeze of the phase.

### H.1 The exception term shape (the binding chokepoint)

A WASM exception is the build-controlled BEAM term **`{wasm_exn, TagId, Payload}`**, raised **error
class** (so it rides the same catchable channel as `{wasm_trap, Kind}`):

- **`TagId`** — the tag's runtime identity. First-milestone: the **static `{tag, ModuleAtom, Index}`**
  term (deterministic, D3a-clean, no per-instance seeding). A `Throw($t)` emits `throw_tag(tag_id(m,
  i), …)`; a `catch $t` emits `match_tag(Reason, tag_id(m, i))` with the **same** `tag_id` — so they
  match within a module. (Two *instances* of the same module share this static identity — a spec
  deviation exercised ONLY by cross-instance EH linking, out of scope; the per-instance-fresh identity
  is a downstream refinement, §H.4.)
- **`Payload`** — the operand value list (`[F64Bits, I32]` for Porffor; `List(Dynamic)` generally,
  §G.1).

This shape is **distinct from `{wasm_trap, Kind}`** (rt_trap), so the run-ABI + the emitted handlers
can tell an exception from a trap — the crux of "catch_all catches exceptions but not traps" (§H.2).

### H.2 `try_table` → a Core Erlang `try…catch` (the codegen contract, P7-06)

The emitted shape (P7-06 realizes it; the keystone freezes the SHAPE):

```
try  <body>                                       %% the try_table body
of   <R1,…,Rk> -> <normal continuation with the try region's result>
catch <Cls, Rsn, Stk> ->
  case {Cls, Rsn} of
    %% one arm per CatchClause, IN ORDER:
    {'error', {wasm_exn, <TagId_1>, Payload}} -> <bind Payload (+ capture if ref) → branch to label_1>
    {'error', {wasm_exn, _,          Payload}} -> <catch_all: (+ capture if ref) → branch to label_all>
    %% fall-through: NOT a matching wasm_exn (a trap, a different tag with no catch_all, a BEAM error):
    _ -> call 'erlang':'raise'(<Cls>, <Rsn>, <Stk>)      %% RE-RAISE faithfully (rt_exn.reraise)
  end
end
```

**The load-bearing rules the keystone pins (06 must honour, 04/05 must not contradict):**

1. **`catch_all` catches exceptions, NOT traps** (spec §4.4). The handler's arms match only
   `{'error', {wasm_exn, …}}`; a `{wasm_trap, Kind}` (or fuel exhaustion, or any BEAM error) falls to
   the `_ -> raise` arm and **propagates untouched**. Getting this wrong would let a `try_table` in
   Porffor's output swallow a real 2core trap — a correctness + sandbox regression. (`rt_exn.is_wasm_exn`
   / `match_tag` encode the test; 06 may inline the pattern or call the helpers.)
2. **Clauses are tried in order** — the first matching clause wins (spec §4.4.9); `catch_all` (if
   present) is last-resort within the try region.
3. **Non-matching → re-raise faithfully** — `erlang:raise(Class, Reason, Stack)` preserves the
   original class + stacktrace, so a re-thrown exception is indistinguishable from the original at an
   outer handler (spec: propagation is transparent).
4. **Constant space + preemption preserved** — the `try` is native BEAM unwinding; the body's loops
   stay tail-recursive `letrec`s (Phase-1 structured-control lowering is unchanged inside the body);
   the scheduler still preempts at reduction boundaries across a throw (J7).
5. **Legacy vs modern is a decode/lower concern** — both encodings produce this same `TryTable` +
   this same emitted `try…catch`. P7-05 normalizes the legacy inline handler into the labeled-branch
   form.

**`CTry` is a CROSS-UNIT SEAM (flag §2).** `core_erlang.gleam` currently has **no** `try` construct
(only `CVar/CInt/…/CCall/CPrimop`). P7-06 **adds** a `CTry(body, of_vars, of_body, catch_vars,
catch_body)` constructor + its `core_printer` output + `core_lint` acceptance. The keystone does
**not** add `CTry` (its EH `emit` arms return `UnsupportedNode`, §J), keeping the keystone minimal
and the tree byte-identical. **Owner: P7-06.**

### H.3 `throw` / `throw_ref` → `rt_exn` raises (D3a-clean)

- **`Throw(tag, args)`** → `call 'twocore@runtime@rt_exn':'throw_tag'(TagId, Payload)` where `TagId`
  is the build-controlled `tag_id(m, i)` literal and `Payload` is the emitted arg value list. **No
  ambient authority (D3a):** the raised term is build-controlled; there is no `apply(Mod, Fun, Args)`
  of a program-chosen target anywhere on the path.
- **`ThrowRef(exnref)`** → `call 'twocore@runtime@rt_exn':'throw_ref'(ExnRefValue)` — `rt_exn` unwraps
  the handed-in `{ref_exn, Caught}` and re-raises `Caught`. Again a **capability** (a wrapped value),
  never an ambient construct; a null exnref traps (§E).

**06 extends the structural D3a security test** to grep-verify: every EH raise is a fixed
`twocore@runtime@rt_exn` module atom with a literal function name; the thrown term is a
build-controlled `{wasm_exn, …}` / `{ref_exn, …}`, never a program-derived `module:atom`. (The
keystone guarantees the seam *shape* composes; the test is 06's.)

### H.4 Tag identity + imported/exported tags (deferred; flagged seams)

- **`ProvidedTag` (link identity) is DEFERRED.** An `ImportTag`'s runtime identity is the exporter's
  (spec §4.5.4). The P5 pattern would add a `link.Provided.ProvidedTag(params, identity)` + a
  `link_imports` tag arm. The keystone freezes the **decl** shapes (`ImportTag`/`ExportTag`, §A.3) and
  the `link.gleam` land-green arms, but **defers the `ProvidedTag` identity resolution** to a
  downstream unit (P7-05/link) — cross-module EH linking is almost certainly out of scope for the
  Porffor headline (single module). Flagged as seam §3.
- **Per-instance-fresh `TagId` is a downstream refinement.** If cross-instance EH conformance is
  pursued, `tag_id` becomes a per-instance value seeded at instantiation (an `rt_exn.fresh_tag_id()`
  in the instance's owned process, like `rt_host`'s policy seed). Not needed for the single-instance
  Porffor path; flagged.

---

## I. `«PORFFOR-ABI-HEAD»` — the value ABI + the `rt_host` Porffor-shim shape (J3; impl → P7-08)

Porffor's output needs two glue pieces beyond EH; the keystone freezes their **contract head**, and
**P7-08 implements them.**

### I.1 The `(f64, i32)` typed-value ABI (frozen contract; run-ABI + harness are P7-08/09)

**Measured:** every JS value is a `(f64, i32)` pair — the `f64` is the value (a JS number directly;
for objects/strings/arrays an i32 pointer carried in the f64), the `i32` is a **type tag**. So a JS
function compiles to a WASM function of type `(param f64 i32 …) (result f64 i32)` — **multi-value** in
and out, which 2core already supports (Phase-1). The keystone freezes:

- **The value ABI is NOT an IR node** (J6 — it is a *frontend/host* convention, a WASM-level pairing,
  not an IR concept). The IR sees ordinary `TF64`/`TI32` multi-value functions; **no EH-IR change**
  models it.
- **The run-ABI/harness (P7-08/09) understand the pair** — decoding a returned `(f64, i32)` into a JS
  value for differential judging, and mapping the type tag to number/string/object/boolean/undefined/
  function. This composes with the R17 multi-value value-list invoke ABI (the pair is two values in
  the list). **P7-08 pins the exact type-tag enumeration** by probing Porffor's `Prefs`/builtins.

### I.2 The `rt_host` Porffor-shim shape (frozen; the registry is P7-08)

**Measured:** Porffor imports a **tiny treeshaken** set from module `""` — every probe imports exactly
`(import "" "a" (func (param f64)))` and `(import "" "b" (func (param f64)))` (its `print`/`printChar`
console primitives; a wider corpus pulls in more). The keystone freezes:

- **The Porffor shim extends the EXISTING `rt_host` registry** (`resolve_handler` — the same
  build-fixed literal `case` that serves `spectest`), with new arms for module `""` names (`"" "a"`,
  `"" "b"`, + whatever a wider corpus enumerates). **No dispatch change** — D3a is preserved verbatim:
  a literal `case`, a closure written in `rt_host`, invoked directly; **never** `apply/3` on
  data-derived names. This is the SAME posture the `spectest` arms took (one arm each, no dispatch
  change — J3).
- **An unprovided intrinsic FAILS CLOSED** — `resolve_handler` returns `Error(Nil)` → a denial (a
  link-time/categorized error), **never** a silent stub that corrupts semantics (D4/J5).
- **A `profiles.porffor()` / JS posture** admits the `""`-module intrinsics (a whitelist, like
  `safe_spectest()`) — **P7-08** adds it; the Safe capability model is unchanged (the shim's IO
  intrinsics are explicit, auditable host functions).
- **The value ABI meets the shim here** — `"" "a"`/`"" "b"` take a `(param f64)`; their handlers
  consume the raw f64 bits (D5) and (for a real `console.log`) render per the type tag. **P7-08** owns
  the handler bodies + the captured-output plumbing the harness (09) judges.

WASI/DOM are **out** (J8) — the shim is Porffor's runtime ABI only. The keystone owns **none** of
`rt_host`'s Porffor arms or the run-ABI value-ABI — it freezes the **shape** so 08/09 don't race it.

---

## J. The `emit_core` / `lower` / `printer` / `parser` seam reach (doc; full impl → 02/05/06)

The keystone makes these files **compile** and stay **byte-identical** on the existing surface; it
does **not** implement the new codegen/lowering/round-trip (that is 02/05/06). Concretely:

- **`emit_core`**: `valtype_atom` gains `TExnRef -> "exnref"`; `result_width` gains `TExnRef -> 32`
  (a reference is never a numeric-load result — validate rejects it; benign default like the other
  refs); `is_reference_type` gains `TExnRef -> True`; the RefType-emitting matches gain an `ExnRef`
  arm. The **three EH `Expr` arms** in `emit`'s dispatch each land as
  `Error(UnsupportedNode("throw"/"try_table"/"throw_ref"))` — a real `Result` path (no new `EmitError`
  variant; `UnsupportedNode` already exists). The `ImportTag`/`ExportTag` fold arms are **inert** (a
  tag emits no runtime state under the static-`TagId` model, §H.1). Because **no Phase-1..6 module
  contains these nodes**, the corpus + suite are unaffected; **P7-06** replaces each EH arm with the
  real `try…catch`/`rt_exn` lowering (+ the `CTry` construct).
- **`expr_touches_state` (`emit_core`, `_ -> False` catch-all)** — not a hard land-green break; the
  three EH nodes fall to the default. It is **semantically fine** to leave `Throw`/`ThrowRef` at the
  default (they transfer control, not touch memory) and `TryTable` at the default (it touches state
  only via its `body`, which the recursive walk visits). **Flag for P7-06:** confirm the threaded
  state-channel threads correctly through a `try_table` body (a throw mid-body must not lose the
  live state record — P7-06's obligation).
- **`printer`** gains the `TExnRef`/`ExnRef`/three-EH-node/tag-decl arms (any spelling —
  conformance-neutral; P7-02 makes it the round-trip spelling). **`parser`** gains minimal
  string-dispatch arms (P7-02 full). **`lower`** gains `TExnRef -> ConstNull(ExnRef)` (`zero_value`)
  and `ConstNull(ExnRef) -> TExnRef` (`value_type`); P7-05 fills the real EH lowering + the
  legacy/modern normalization + `ImportTag`/`ExportTag` production.

The **D3a security-invariant test extension** (the no-ambient-authority proof for `rt_exn` raises) is
**P7-06's**; the keystone only guarantees the seam *shape* composes.

---

## Effect / soundness / security note

- **No ambient authority (D3a) survives the new surface.** A thrown exception is a **build-controlled
  term** `{wasm_exn, TagId, Payload}` raised through the fixed `twocore@runtime@rt_exn` module with a
  literal function name — never a program-chosen `apply(Mod, Fun, Args)` (J5). A caught `exnref` is an
  **opaque** `{ref_exn, Caught}` box (Safe code may re-throw/null-test/pass/store it, never inspect
  the underlying BEAM exception — H6). `throw_ref` re-raises a **handed-in** capability, not a
  data-driven target.
- **Fail-closed everywhere (D4/J5).** `catch_all` catches exceptions but **not traps** — a real 2core
  trap (memory OOB, fuel exhaustion, indirect-call mismatch) propagates through any `try_table`
  untouched (§H.2). An unprovided Porffor intrinsic is **denied** (§I.2). An uncaught exception
  becomes a BEAM exception the **instance boundary contains** (one-instance-one-process) — it cannot
  escape to another instance or the node; metering/fuel still bites across a throw (J5). Worst case of
  any new EH bug is a wrong result or a node-safe crash, never a host escape.
- **Conformance-neutral by default (J6) — the proof.** The defaults are chosen so a module with **no
  `tags`**, **no `Throw`/`TryTable`/`ThrowRef` node**, and **no `exnref`** produces: the same `.ir`
  text (the new tokens appear only when EH is used; no `tag` section printed for a tag-free module),
  the same `InstanceState`/`StateDecl` term (tags seed no state under the static-`TagId` model), and
  the same `.core` bytes (the EH `emit` arms are unreached; `valtype_atom`/`result_width`/
  `is_reference_type` add arms the existing surface never hits; `Module.tags` defaults to `[]`;
  `ImportTag`/`ExportTag` are inert for import-free modules). Since WebAssembly is deterministic,
  **byte-identity ⇒ result-identity** across both state strategies and every shipped tier. **Nothing
  observable changes** for the existing corpus + suite (the J6 claim, asserted by the conformance
  suite passing unchanged).
- **EH stays a generic structured-exception model (J2/decision #1).** `Throw`/`TryTable`/`ThrowRef` +
  `TagDecl` + `exnref` are neutral (throw a value / guard-and-catch by class / re-raise a handle) — a
  future native-JS or Gleam frontend reuses them; nothing WASM-specific (an opcode, the `(f64,i32)`
  value ABI) leaks into the IR core.

---

## Deviations from the overview / ABI findings (ARGUED — for the critique + reconciliation)

1. **Porffor emits LEGACY EH, not `try_table` (MEASURED — the load-bearing correction).** The overview
   §J1, the findings, and the task brief describe Porffor as emitting the modern `try_table` / the
   catch-clause kinds / `throw_ref` / `exnref`. **Re-measuring Porffor 0.61.13 shows it emits the
   LEGACY encoding** (`try` 0x06 / `catch` 0x07 / `throw` 0x08 / `end` 0x0B), with **exactly one
   `(tag (param f64 i32))`**, **no** `catch_all`/`catch_ref`/`delegate`/`rethrow`/`throw_ref`/
   `try_table` across every probe (`try/finally`, JS `throw e` rethrow, nested). `wasm-tools validate`
   requires the `legacy_exceptions` feature. **Resolution:** the IR this unit freezes is
   **encoding-neutral** (D6) — both legacy `try/catch` (Porffor, the headline) and modern
   `try_table`/`throw_ref` (the spec `.wast`) lower onto the same `Throw`/`TryTable`/`ThrowRef`
   nodes. **P7-03 owns the byte decode** and must decode the **legacy** encoding for the JS headline
   (and the modern one for the EH `.wast` conformance, where wast2json-able). J1's thesis (EH → BEAM
   exceptions) is **unaffected**. **Consequence for scope honesty (J8):** `exnref`/`ThrowRef`/
   `catch_ref`/`catch_all` are **spec-conformance surface**, NOT Porffor-critical — their conformance
   is bounded by which EH `.wast` are wast2json-able at the pin. Fix the "try_table" language in
   00-overview §J1 + PORFFOR-ABI-FINDINGS to "legacy `try/catch` (measured); the IR is
   encoding-neutral."

2. **`TryTable` is the frozen IR node name even for the legacy encoding.** The task + overview name the
   node `TryTable`. It is kept (a neutral "guarded region with tag-matched catch clauses branching to
   labels"), and the **legacy `try…catch` normalizes onto it** (P7-05). The alternative (a separate
   `LegacyTry` node) is rejected — it would fork the IR by encoding, violating D6. Minor: the name
   reads "try_table" but the semantics are the general structured-exception region both encodings
   share.

3. **`exnref` is a full `RefType` member, reusing `rt_ref` (§C).** The task offered "reuse rt_ref or a
   parallel model"; the keystone **reuses** (`RefType.ExnRef` + `ValType.TExnRef` + the
   `{ref_exn, Caught}` box sharing the null sentinel), argued in §C.1 (maximal reuse, spec-faithful,
   one new concept). The cost is the `RefType`/`ValType` exhaustive-match reach (enumerated §reach).
   **Fallback if reconciliation prefers minimalism:** drop `RefType.ExnRef` and make `TExnRef` a
   standalone non-null-able ValType, deferring `ref.null exn` conformance — but this forks null
   handling and loses reuse. **Recommend the full RefType member.**

4. **`ImportTag`/`ExportTag` are frozen in the keystone (§A.3) though only `ExportTag` is
   Porffor-exercised.** Measured: Porffor exports its tag but imports none. Both are frozen (the task
   mandates "imported/exported tag variants"; symmetry with globals). `ExportTag` is **inert for
   single-module execution**; `ImportTag`'s link identity (`ProvidedTag`) is **deferred** (§H.4). A
   consistency choice, not a taste one.

5. **No new `TrapReason`; an uncaught exception is a run-ABI outcome (§E).** Spec-faithful (an
   exception is not a trap — `assert_exception ≠ assert_trap`). The run-ABI `UncaughtException`
   outcome is deferred to P7-06/09 (a `pipeline.RunResult` change the keystone does not own). Argued
   §E; flagged seam §1.

6. **The `(f64, i32)` value ABI is NOT an IR node (§I.1).** Per J6, it is a frontend/host convention,
   modeled as ordinary `TF64`/`TI32` multi-value; the run-ABI/harness (08/09) understand the pair.
   Adopted from J3; no IR divergence.

Everything else (the tag-as-`GlobalDecl`-analogue; the three EH `Expr` nodes; the
`CatchClause`/`CatchTag` shapes; the all-barriers effect classification; the reuse of `rt_trap`'s
raise channel for `{wasm_exn, …}`; the Porffor-shim-as-`rt_host`-arm posture) is adopted **as the
overview specifies**.

---

## Verification — Definition of Done (D8)

- **`gleam build` compiles with zero warnings.** The only *behavioural* code the keystone lands is
  `ir.gleam` (types), `ir/effect.gleam` (real classification, §D), the land-green arms (printer/parser/
  emit_core/lower/ir_lower/ir_opt/link), and the **new `rt_exn.gleam`** (heads + `panic` placeholder
  bodies, `todo`-free, one import → no unused-import warning). The `rt_exn` bodies, the `CTry`
  construct + EH codegen, the Porffor registry + value ABI, and the decode/validate/lower EH pipeline
  are frozen in **prose** (no `todo` stubs → no warnings), the Phase-4/5/6 posture.
- **`gleam format --check src test` clean; `gleam test` stays green (1491 tests, conformance
  46,529/1,768/0 under every shipped `(mode × state_strategy × mem_tier)`).** The land-green reaches
  keep the tree total; the default paths are byte-identical, so **no conformance number moves** — the
  J6 proof, asserted by the existing conformance suite passing unchanged.
- **A scratch freeze test** (`test/twocore/ir/eh_freeze_test.gleam`, mirroring `ir4_freeze_test`) —
  **spec assertions, not change-detectors**:
  - constructs an EH `Module` exercising the whole new surface: a `TagDecl("t0", [TF64, TI32])` (the
    Porffor tag), an `ExportTag`, an `ImportTag`; a function whose body uses `Throw("t0", [Var("v"),
    Var("k")])`, a `TryTable([TI32], <body>, [CatchClause(OnTag("t0"), "h", False),
    CatchClause(OnAll, "a", True)])`, a `ThrowRef(Var("e"))`, an `exnref` local (`Local("e",
    TExnRef)`), and a `ConstNull(ExnRef)` operand — and asserts it **typechecks**, proving the types
    express the whole Phase-7 surface before anyone builds on them.
  - asserts **`effect.classify(Throw(…)) == Effectful`**, **`effect.classify(TryTable(…)) ==
    Effectful`**, and **`effect.classify(ThrowRef(…)) == Effectful`** (the J5 freeze — every EH node
    is a barrier, WASM §4.4.9) — asserted against the **spec rule**, not current output.
  - asserts **`reftype_to_valtype(ExnRef) == TExnRef`** and **`valtype_to_reftype(TExnRef) ==
    Ok(ExnRef)`** (the no-drift invariant) and **`is_reference_type(TExnRef) == True`**.
  - asserts **default-neutrality structurally**: a `tags: []`, no-EH, no-`exnref` module round-trips
    its `.ir` text **byte-identically** to the Phase-6 spelling and lowers to a **byte-identical**
    `.core` (compare against a committed Phase-6 golden) — the J6 claim as a test.
  - asserts **`TrapReason` is unchanged** (§E) — constructs the full list and asserts the
    count/messages are exactly Phase-6's (a guard against an accidental variant addition breaking
    `spec_trap_message`/`trap_reason_atom`).
  - asserts the `rt_exn` heads **exist with the frozen arities** (constructs a `throw_tag`/`match_tag`/
    `capture`/`reraise`/`throw_ref`/`is_wasm_exn`/`tag_id` reference — a compile-time signature check;
    NOT calling them, since the bodies `panic` until 07).
- **The `.ir` grammar delta** (§F) is sketched for P7-02; the `«RT-EXN-SIG»` heads (§G), the
  `«BEAM-EXN-LOWERING»` contract (§H), and the `«PORFFOR-ABI-HEAD»` (§I) are frozen for 02–09.
- **Done = the freeze test + the full suite pass** (D8) — **not** "it compiles."
- Announce `«EH-IR-FROZEN»` / `«RT-EXN-SIG»` / `«BEAM-EXN-LOWERING»` / `«PORFFOR-ABI-HEAD»` in
  `state.md` with the full reach list.

---

## What this unit leaves

- **02** implements the `.ir` printer/parser round-trip of the whole EH surface (§F) — `exnref`, the
  `tag` section, `throw`/`try_table`/`catch*`/`throw_ref`, and reconciles `ir-grammar-delta.md`;
  legacy modules print byte-identically.
- **03** publishes `«WASM-AST4-EH»`: the **tag section** (id 13) decode, and — per D1 above — the
  **legacy** EH opcodes (`try` 0x06 / `catch` 0x07 / `catch_all` 0x19 / `delegate` 0x18 / `rethrow`
  0x09 / `throw` 0x08) that **Porffor** emits, **and** the **modern** opcodes (`throw_ref` 0x0A /
  `try_table` 0x1F + catch kinds 0x00–0x03 / the `exn` heap type) for the EH `.wast`; the `ast`
  EH delta for 04/05.
- **04** types the EH surface: a tag's operand types; `throw` operand match; `try_table` result +
  catch-clause label/tag typing; `exnref` on the abstract stack; a null-`throw_ref` trap. Fail-closed
  (S1's fail-closed build invariant applies — intercept every EH `Instr` before any silent-accept
  fallthrough).
- **05** lowers WASM-AST-EH → EH-IR: the tag section → `Module.tags`; `throw` → `Throw`; legacy
  `try/catch` + modern `try_table` → `TryTable` (the normalization); `throw_ref` → `ThrowRef`;
  `rethrow N`/`delegate` → the re-raise/`ThrowRef` mapping; `ImportTag`/`ExportTag` production.
- **06** replaces the `emit_core` `UnsupportedNode` arms (§J) with the real EH codegen: **adds the
  `CTry` Core Erlang construct** (+ `core_printer` + `core_lint`); `Throw`/`ThrowRef` →
  `rt_exn.throw_tag`/`throw_ref`; `TryTable` → the Core Erlang `try…catch` (§H.2) with the
  "catch_all ≠ trap" handler; threads the state channel through the body; the run-ABI
  `UncaughtException` outcome; the extended D3a security test.
- **07** implements the `«RT-EXN-SIG»` bodies (§G) over `{wasm_exn, TagId, Payload}` /
  `{ref_exn, Caught}`, reusing `rt_ref`'s null sentinel + `erlang:raise` for faithful re-raise; adds
  the `rt_ref.RefKind.ExnRef` classification arm (§C.1); differential-tested vs the EH `.wast`
  semantics.
- **08** implements the Porffor `rt_host` registry (`"" "a"`/`"" "b"` + the enumerated corpus set,
  fail-closed), the `(f64, i32)` value-ABI decode in the run-ABI, a `profiles.porffor()`/JS posture,
  and the captured-output plumbing.
- **09** builds the JS-subset conformance harness (Porffor `porf wasm` → 2core → BEAM, judged
  differentially vs `porf run`/Node), measured coverage, honest categorized skips.
- **10** proves the phase end-to-end: EH `.wast` green under the matrix it's defined for; JS on the
  BEAM demonstrated + measured; honest close (bounded by Porffor's ⅓-of-ECMA coverage); SVG/docs.

---

## Cross-unit seams (flagged for reconciliation — pin single ownership)

1. **The run-ABI uncaught-exception outcome (01 freezes the term, 06/09 own the outcome).** `01`
   freezes `{wasm_exn, TagId, Payload}`; whether `pipeline.RunResult` gains an `UncaughtException(…)`
   variant or renders it through `Trapped`'s string is **P7-06/09**'s. Pin: an uncaught exception must
   be **distinguishable from a trap** for the harness + `assert_exception` (§E). No new `TrapReason`.
2. **The `CTry` Core Erlang construct (01 freezes the lowering shape, 06 adds `CTry`).** `01` freezes
   the `try…catch` shape (§H.2); `06` adds `CTry` to `core_erlang.gleam` + `core_printer` +
   `core_lint`. Pin: the keystone's EH `emit` arms are `UnsupportedNode` (no `CTry` yet), so the
   keystone stays byte-identical. **Owner: P7-06.**
3. **`ProvidedTag` link identity (01 freezes `ImportTag`/`ExportTag` decls, link/05 own identity).**
   `01` freezes the decl shapes + the `link.gleam` land-green arms; the P5-style
   `Provided.ProvidedTag` identity resolution is **deferred** (§H.4) — cross-module EH linking is
   likely out of scope (single-module Porffor). Pin: a `ProvidedFunc`-style closure is **not**
   `==`'d; a tag identity likewise must never be `==`'d by structure across instances (spec
   tag-identity is nominal). **Owner: P7-05/link.**
4. **The `(f64, i32)` value ABI + the Porffor `rt_host` registry (01 freezes the shape, 08 owns it).**
   `01` freezes: NOT an IR node (§I.1); the shim is an `rt_host` `resolve_handler` extension (D3a
   verbatim, §I.2); fail-closed on unprovided. `08` pins the type-tag enumeration + the `""`-module
   intrinsic set + the handlers. Pin: the intrinsic set is a **build-fixed literal `case`**, never
   `apply/3`.
5. **`rt_ref.RefKind.ExnRef` classification (01 freezes the `{ref_exn,_}` box, 07 adds the arm).** An
   `exnref` reuses `rt_ref`'s null sentinel but its `{ref_exn, Caught}` box would misclassify as
   `FuncRef` in `classify_ref`'s elimination arm. `07` adds an `ExnRef` `RefKind` + `classify_ref`
   arm (additive, structural). Inert for the Porffor path; needed for `throw_ref.wast` judging.
   **Owner: P7-07.**
6. **Tag identity across instances (01 freezes the static `{tag, Module, Index}`, downstream may
   refine).** The first milestone uses a static per-module identity (single-instance-correct,
   cross-instance-lax). Per-instance-fresh identity (seeded at instantiation) is a downstream
   refinement iff cross-instance EH conformance is pursued (§H.4). **Owner: downstream / flagged.**

---

## Open questions (for the planner / cross-unit sync)

1. **Legacy vs modern EH decode scope (Deviation 1).** Porffor is legacy-only (measured); the EH
   `.wast` is modern. Does P7-03 decode **both** encodings, or legacy-for-headline + modern-only-where-
   wast2json-able? Recommend: **both**, since the modern surface is small and the IR is shared.
   Reconcile the overview's "try_table" language.
2. **`ProvidedTag` / cross-module EH linking scope (seam 3).** Is any EH `.wast` linking test in scope,
   or is cross-module tag identity deferred entirely (single-module Porffor only)? Recommend
   **deferred**; the keystone freezes only the decl shapes.
3. **The uncaught-exception run-ABI outcome (seam 1).** A distinct `UncaughtException(TagId, Payload)`
   `RunResult` variant, or rendered through `Trapped`'s string? Recommend **distinct** (spec-faithful
   `assert_exception`); 06/09 finalize.
4. **`TagId` representation (seam 6).** Static `{tag, Module, Index}` (recommended — deterministic,
   no seeding, single-instance-correct) vs per-instance-fresh (spec-faithful cross-instance). The
   keystone ships static; downstream refines if needed.
5. **A distinct EH trap message? (§E).** The keystone reuses `TrapReason` with **zero** new variants
   (a null-`throw_ref` trap reuses an existing reason). If a pinned EH `.wast` `assert_trap`
   distinguishes a message the existing set cannot produce, add **exactly one** variant + its
   `spec_trap_message` (a conscious add). Expected: **none** — flagged so it is not silent.
6. **`rt_exn` placeholder body: `panic` vs a conservative value (§G.2).** Recommend **`panic`**
   (fail-loud, `todo`-free, never reached before 07). A green-but-inert value risks a spurious pass;
   `panic` is the fail-closed choice.
