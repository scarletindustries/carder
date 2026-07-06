# R14-01 — The keystone: the `RefFuncImport` IR node + the `ref.func` import-split freeze

> **Status:** scoped, awaiting build. **Owner:** R14-01 (the keystone — goes first and alone).
> **Freeze:** produces `«REFFUNC-IMPORT-FROZEN»`. **Read order:** [`00-overview.md`](00-overview.md) →
> the distilled codebase map (`brief-phase14-xmodule-elem.md`) → this doc. All prior-phase decisions and
> the permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold. This unit
> lands **green with default emission byte-identical** — it adds ONE IR node (`RefFuncImport(slot, ty)`),
> a real `ref.func` **import-split** in `lower.gleam`, a lossless `.ir` round-trip, and every
> exhaustiveness-forced pure-barrier arm — and it lands a **conservative fail-closed arm** into
> `emit_core.gleam` that **R14-02 completes**. The imported-`ref.func` case still SKIPS **exactly as
> today** (byte-identical skip reason `UnknownFunction`); no module without an imported `ref.func` changes
> a single byte of `.core`. The adapter-closure emission, the `needs_func_imports` element scan, and the
> driver mirror are **NOT** the keystone's — they are R14-02's.

---

## §1. Goal

Freeze the **one missing distinction** every downstream Phase-14 unit binds to — `ref.func` of an
**imported** function — and prove it is expressible, split correctly in lowering, lossless, inert-by-
default, and byte-identical. Concretely:

- **One new `ir.Expr` node** — `RefFuncImport(slot: Int, ty: FuncType)` — a **pure barrier** carrying no
  sub-`Expr` and no `Value` operands, whose *shape* mirrors `CallImport` (positional func-import slot +
  the imported `FuncType`) but whose *operand/traversal treatment* mirrors `RefFunc` (a nullary reference
  construction — no args to rewrite, no linear memory written).
- **A real `ref.func` import-split in `lower.gleam`** — `ast.RefFunc(f)` with `f < ctx.imported` →
  `ir.RefFuncImport(f, ir_functype(sig))`, else the unchanged `ir.RefFunc("f" <> f)`. This is **owned and
  completed here** (not a placeholder): it is the exact mirror of the frozen `lower_call` import-split.
- **A lossless `.ir` printer/parser round-trip** for the node (**D5**), including inside an element
  segment and mixed with defined `ref.func` items.
- **Every exhaustiveness-forced arm** across `effect`, `printer`, `parser`, `ir_lower`, and the `ir_opt/*`
  passes — final **pure-barrier / pass-through** arms, each mirroring the existing `RefFunc` arm at the
  same site (never reorder/CSE/DCE across it; never treat it as a linear-memory write; never treat it as a
  *call* for versioning).
- **A conservative-sound fail-closed arm** into `emit_core.gleam`, documented as a *reach* (completed by
  R14-02), keeping the file single-substantive-owner and every intermediate state **green + byte-
  identical**: an imported `ref.func` still yields the existing `UnknownFunction` skip — the residual is
  unchanged, `residual_audit` stays green, no assert flips.

Implements the load-bearing part of **R1** (the `RefFuncImport` node + the lowering import-split — the
adapter closure, the seed scan, and the driver mirror are R2/R3, owned by R14-02); upholds **R5** (byte-
identical by default — the funcref value shape `#(FuncType, closure)` is untouched and the frozen
`init_elem` fast path is preserved) and **R8** (no new `TrapReason`, no runtime shape change).

**Why a distinct node, not `ir.RefFunc` with an `imported: Bool` (mirrors R1, and the `CallImport ≠
CallDirect` precedent).** `ir.RefFunc` keeps its documented invariant — *"`fn_name` names a **defined**
function"* (`ir.gleam:553-557`). Overloading it would force every non-imported path to re-examine a flag
and would break the byte-identity mechanism: `all_reffunc` / `byte_ident_funcref`
(`emit_core.gleam:5732-5744`) test for *plain* `ir.RefFunc` items to keep the frozen table-0 `init_elem`
fast path. A separate node means a pure-defined segment still sees only `ir.RefFunc` items (fast path,
byte-identical), while any segment containing a `RefFuncImport` is automatically **not** `all_reffunc` →
routes to the general `init_elem_ref` / `render_ref_items` path where R14-02 lands the adapter closure.

---

## §2. Depends on / Produces

**Depends on (read-only, frozen upstream):**
- `src/twocore/ir.gleam` — `Expr`, `Value`, `FuncType(params, results)` (`ir.gleam:398-399`), `TrapReason`
  (`ir.gleam:1445-1454` — `UndefinedElement` / `UninitializedElement` / `IndirectCallTypeMismatch` /
  `TableOutOfBounds` already exist), and `CallImport(slot, ty, args)` (`ir.gleam:760`) + `RefFunc(fn_name)`
  (`ir.gleam:557`) as the two sibling shapes the node borrows from.
- `src/twocore/frontend/wasm/lower.gleam` — the frozen `lower_call` import-split (`lower.gleam:1392-1394`,
  `f < ctx.imported` → `ir.CallImport(f, ir_functype(sig), args)`), `ctx.imported`
  (`lower.gleam:166` / seeded `:397` from `typed.imported_func_count`), `nth_err(ctx.func_types, f,
  UnknownFuncIndex(f))` (`:1372`), `ir_functype` (`:3166-3167`), `emit_nullary` (`:1102`), `ir.TFuncRef`.
  The `ref.func` lowering site being replaced is `lower.gleam:757-764`.
- `src/twocore/runtime/rt_table.gleam` / `rt_ref.gleam` / `link.gleam` / `rt_state.gleam` — **read-only,
  not touched this phase by the keystone.** The funcref value shape `#(FuncType, closure)`, the
  `func_import_at` / `t_func_import_at` reads, and the `link.call_import` capability all already exist;
  R14-02/03 reach them. The keystone adds, edits, and freezes **no** runtime function.

**Produces `«REFFUNC-IMPORT-FROZEN»`:** the `RefFuncImport(slot, ty)` node, the completed `ref.func`
import-split in `lower`, the `.ir` round-trip spelling, every exhaustiveness arm (effect / printer /
parser / ir_lower / ir_opt as pure-barrier pass-throughs), and a **conservative fail-closed `emit_core`
arm** (imported `ref.func` still yields the existing `UnknownFunction` skip — byte-identical, no
regression) that R14-02 completes. **Unblocks** R14-02 (backend emit + seed + driver mirror — the heart),
R14-03 (runtime differential), R14-04 (capstone).

---

## §3. What it owns + design

**Owned files (D1) — this unit is the sole substantive owner of each:**
`src/twocore/ir.gleam` · `src/twocore/frontend/wasm/lower.gleam` · `src/twocore/ir/effect.gleam` ·
`src/twocore/ir/printer.gleam` · `src/twocore/ir/parser.gleam` · `src/twocore/middle/ir_lower.gleam` ·
`src/twocore/middle/ir_opt/{pass,baseline,aggressive,bce,loop_analysis,mem_clobber,mem_ssa}.gleam` · new
`test/twocore/reffunc_import_freeze_test.gleam`. **Does NOT own `rt_table.gleam` / `rt_ref.gleam` /
`link.gleam` / `rt_state.gleam` / `driver.gleam`** — the adapter closure, the seed scan, and the driver
mirror are R14-02/03.

> **Ownership note (resolving the §4 table vs the compiler).** The overview's §4 file map names
> `ir_opt/{baseline,aggressive,bce,mem_clobber}` as the *representative* barrier edits; the governing scope
> is the freeze-milestone clause *"every exhaustiveness arm (effect/printer/parser/ir_lower/ir_opt as
> pure-barrier pass-throughs)"*, and **`gleam build` is the checklist** (Gleam has no default match arm).
> The compiler forces a `RefFuncImport` arm wherever there is an *exhaustive* match with an explicit
> `RefFunc` arm — that is `pass` / `baseline` / `aggressive` / `loop_analysis` / `mem_ssa` (§3.6). `bce`
> and `mem_clobber` use `_ -> False` defaults into which `RefFunc` already falls, so `RefFuncImport` falls
> there too and needs **no** arm (§3.6, confirmed by a test, not by silence). No other Phase-14 unit
> touches any of these files, so the keystone owning all of them is D1-clean.

**One documented cross-file reach** (a conservative-sound compile-arm, §3.7), completed by R14-02, recorded
in `state.md`: `src/twocore/backend/emit_core.gleam`.

> **Build strategy — let the compiler enumerate the sites.** Add `RefFuncImport` to `ir.gleam` first,
> then `gleam build`: every non-exhaustive-match error points at exactly the site that needs an arm. The
> anchors below are the *map*; the compiler is the *checklist*. **At every forced site, mirror the
> existing `RefFunc` arm — NOT the `CallImport` arm** (the node carries no `Value` operands, so there is
> nothing to substitute/rewrite/collect; and it constructs a funcref, so it writes no linear memory).

### 3.1 The IR node — `ir.gleam` (insert next to `CallImport`, ~line 760)

Add, with full `///` contract docs, a sibling of `CallImport` (positional import slot + import `FuncType`)
whose classification matches `RefFunc` (a reference-materialising barrier that never traps):

```gleam
/// `ref.func $f` where `$f` is an IMPORTED function (R1). A funcref to the imported function at
/// positional func-import `slot` — the build-controlled type-tagged closure `#(FuncType, closure)`
/// whose closure routes through the D3a import capability (`link.call_import` over the instance's
/// func-import vector), rendered by `emit_core` (R14-02). `slot` counts function imports only
/// (imports occupy the low funcidx range, so `slot == funcidx`); `ty` is the import's declared
/// signature — the SAME `func_type_term(ty)` renderer `call_indirect`'s guard-3 uses, so a stored
/// imported funcref structurally type-matches unchanged. Effectful in the barrier sense only (it
/// materialises instance-linked state); NEVER traps. Distinct from `RefFunc`, which keeps its
/// invariant — `fn_name` names a DEFINED function (`apply 'f'/n`). Only `lower` of a `ref.func` to
/// an IMPORTED funcidx produces this node (defined → `RefFunc`). No Phase-1..13 module produces it.
RefFuncImport(slot: Int, ty: FuncType)
```

**Contract to freeze in the docs:** it carries **only** a `slot: Int` and a `ty: FuncType` — no sub-
`Expr`, no `Value` operands — so it is a leaf in every traversal and a barrier in `effect`; it introduces
**no new `TrapReason`** (building a funcref never traps; the indirect-dispatch guards it later feeds reuse
the three existing element/type reasons); and its shape mirrors `CallImport` while its arm-treatment
mirrors `RefFunc` everywhere downstream.

### 3.2 The `ref.func` import-split — `lower.gleam:757-764` (OWNED + COMPLETED here)

Replace the single unconditional arm

```gleam
ast.RefFunc(f) ->
  emit_nullary(ir.RefFunc("f" <> int.to_string(f)), ir.TFuncRef, tail, ctx, st)
```

with the import-split — the exact mirror of `lower_call` (`lower.gleam:1392-1394`), because the WASM
funcidx space is **unified** (imports occupy funcidx `0 .. ctx.imported - 1`, so for an imported target
`slot == funcidx == f`):

```gleam
ast.RefFunc(f) ->
  case f < ctx.imported {
    True -> {
      use sig <- result.try(nth_err(ctx.func_types, f, UnknownFuncIndex(f)))
      emit_nullary(ir.RefFuncImport(f, ir_functype(sig)), ir.TFuncRef, tail, ctx, st)
    }
    False ->
      emit_nullary(ir.RefFunc("f" <> int.to_string(f)), ir.TFuncRef, tail, ctx, st)
  }
```

Notes: the pushed result type stays `ir.TFuncRef` in **both** arms (a `ref.func` yields a funcref
regardless of imported/defined); the imported arm fetches `sig` from `ctx.func_types` with the same
`UnknownFuncIndex(f)` error `lower_call` uses (`:1372`) and renders it with `ir_functype`
(`:3166-3167`) — identical to how `CallImport` gets its `ty`. Validation is unchanged: `ref.func x`
requires `x ∈ C.refs` (declared) at validate time (`validate.gleam:1057-1060`), which the `table_copy`
elem funcs already satisfy — **no `validate.gleam` change is needed** (it is not owned by this unit).

This split is **substantive and complete** in the keystone (unlike the Phase-13 keystone's `lower`
*placeholder*): after it lands, imported `ref.func` in the real fixtures produces `RefFuncImport`, and the
downstream emit reach (§3.7) is what keeps the observable behaviour byte-identical (still skipping) until
R14-02 flips it.

### 3.3 `effect.gleam` — the barrier arm (`is_effectful_node`, ~line 146, beside `CallImport`)

`is_effectful_node` (`effect.gleam:95`) is exhaustive (no wildcard). Add `RefFuncImport` to the `-> True`
group, beside `RefFunc(_)` (`:123`) / `CallImport(_, _, _)` (`:146`):

```gleam
| RefFuncImport(_, _)
```

Freeze in a `//` note: like `RefFunc`, materialising an instance-linked funcref is a barrier (no CSE, no
reorder, no DCE) — the maximally-safe posture. `children_all_pure` (`effect.gleam:260`) has a `_ -> True`
catch-all that a barrier never reaches (`classify` short-circuits via `is_effectful_node`), so **no arm is
needed there**. Consequently `classify(RefFuncImport(..)) == Effectful`, `can_cse(..) == False`
(`:314`), `can_eliminate_if_unused(..) == False` (`:299`) — all derived from this one arm and asserted in
§4 test 3.

### 3.4 `printer.gleam` + `parser.gleam` — lossless `.ir` round-trip (D5)

**Printer** (`print_expr`, exhaustive — `printer.gleam:556`; add beside `CallImport` at `:864`). Reuse the
frozen `print_functype` helper so the spelling cannot drift; the node has no args, so no `value_list`:

```gleam
ir.RefFuncImport(slot, ty) ->
  "ref.func_import " <> int.to_string(slot) <> " : " <> print_functype(ty)
```

`print_ref_init` (`printer.gleam:423`) has a `_ -> print_expr(2, item)` fallback, so a `RefFuncImport`
element-init item prints via this `print_expr` arm — **no separate arm needed**. `all_reffunc`
(`printer.gleam:433`) has `_ -> Error(Nil)`, so a segment containing a `RefFuncImport` is **not** all-
`RefFunc` and takes the canonical `elem` spelling (round-tripping through `parse_ref_init` → `parse_expr`).

**Parser** (`parse_expr` keyword `case`; add beside `"ref.func"` at `parser.gleam:1322` and
`"call_import"` at `:1414`). One exact-string arm — the `slot : functype` form mirrors `parse_call_import`
(`:2092-2100`) minus the arg list, reusing `expect_number` / `expect(_, TColon, ":")` / `parse_functype`:

```gleam
"ref.func_import" -> {
  use #(slot, rest) <- result.try(expect_number(rest))
  use rest <- result.try(expect(rest, TColon, ":"))
  use #(ty, rest) <- result.try(parse_functype(rest))
  Ok(#(ir.RefFuncImport(slot, ty), rest))
}
```

`parse_ref_init` (`parser.gleam:1042`) has a `_ -> parse_expr(toks)` fallback, so an element-segment
`RefFuncImport` parses back through this keyword arm — **no separate arm needed**. **D5 requirement:**
`parser.parse_module(printer.print_module(m)) == Ok(m)` for any module using the node (proved in §4 test
4), including a multi-value `ty`, `slot == 0` and `slot >= 1`, and the node both inside an `ElemExprs`
element segment (mixed with defined `RefFunc` items) and inside a function body.

### 3.5 `ir_lower.gleam` — leaf pass-through, no per-call charge

The metering walk (`ir_lower.gleam:200-237`, exhaustive) inserts `Charge` only on fn-entry / loop body,
never per node. `RefFuncImport` carries only a static `slot` + `ty` (no sub-`Expr`), so add it to the
"leaves unchanged" `|` group beside `ir.RefFunc(_)` (`:214`) / `ir.CallImport(_, _, _)` (`:237`):

```gleam
| ir.RefFuncImport(_, _)
```

Metering stays identical (R8 — no metering change; building a funcref is not a call and receives no
`Charge`).

### 3.6 `ir_opt/*` — pure-barrier / pass-through arms (mirror `RefFunc`, not `CallImport`)

Every forced arm mirrors the existing **`RefFunc`** arm at the same site (the node has no `Value` operands
to rewrite/collect, and it writes no linear memory). Known anchors (the compiler enumerates the exact
set):

- **`pass.gleam`** (`map_expr` leaf group, exhaustive — beside `ir.RefFunc(..)` at `:127`): add
  `| ir.RefFuncImport(..)` — a `Value`-free leaf returned unchanged from the `Expr`-traversal combinator.
- **`baseline.gleam`** — (a) `subst_expr` (beside `ir.RefFunc(_) -> e` at `:845`):
  `ir.RefFuncImport(_, _) -> e` (nothing to substitute); (b) free-name collector (beside
  `ir.RefFunc(_) -> []` at `:1048`): `ir.RefFuncImport(_, _) -> []` (no `Var` names).
- **`aggressive.gleam`** — `apply_rename_subst` (beside `ir.RefFunc(_) -> e` at `:467`):
  `ir.RefFuncImport(_, _) -> e`. (The reference-target collector at `:903` sits behind an `all_reffunc`-
  style gate and has its own default; confirm the compiler does not additionally flag it — if it does,
  the mirror is "not a plain `RefFunc` target", i.e. it is skipped exactly as a null/`GlobalGet` item.)
- **`loop_analysis.gleam`** — operand-var collector (beside `ir.RefFunc(_) -> acc` at `:89`):
  `ir.RefFuncImport(_, _) -> acc` (contributes no loop-variant operand).
- **`mem_ssa.gleam`** — the "reference / table ops" barrier group (`-> True`, exhaustive, beside
  `ir.RefFunc(_)` at `:235`): add `| ir.RefFuncImport(_, _)` — conservatively a barrier (touches disjoint
  table/instance state, never linear memory), identical to `RefFunc`.
- **`bce.gleam`** — **no arm.** `has_grow_or_call` (`:385`) has a `_ -> False` default (`:404`) into which
  `RefFunc` already falls; `RefFuncImport` is **not a call** (it constructs a funcref, it does not
  dispatch), so it falls to `False` too — a loop containing only a `RefFuncImport` stays versioning-
  eligible, exactly as with `RefFunc`. (This is the one place `RefFuncImport` deliberately does **not**
  mirror `CallImport`, which **is** in the `-> True` call group.) Confirmed by §4 test 3, not by silence.
- **`mem_clobber.gleam`** — **no arm.** Both `may_clobber` (`:30`) and `may_write_memory` (`:65`) have
  `_ -> False` defaults (`:57` / `:100`) into which `RefFunc` already falls; building an adapter closure
  writes no linear memory at construction time (the dispatch happens later, at the `CallIndirect` node, a
  distinct barrier), so `RefFuncImport` falls to `False` too. Confirmed by §4 test 3.

None of these changes any default module's optimization — the node never appears by default (R5).

### 3.7 `emit_core.gleam` — the conservative fail-closed reach (completed by R14-02)

Adding the IR node forces an arm in **every exhaustive `Expr` traversal in `emit_core`** (Gleam has no
default match arm) **merely to compile** — `gleam build` enumerates the exact set. There are **two forced
sites** and **two deliberate sites**, and the disposition differs by kind: **collectors pass through (mirror
`RefFunc`); dispatch/render fail closed** (reproduce today's byte-identical skip). The keystone lands all
four; the three fail-closed arms are **conservative-sound and byte-identical to today's skip**, and R14-02
(the substantive owner) replaces those with the real adapter-closure emission (the collector pass-through is
permanent). Record all four as reaches in `state.md`.

- **Forced site (i) — the collector `collect_expr` (`:6274`, an exhaustive `Expr` traversal with NO
  wildcard): PASS-THROUGH.** It must mirror the existing `ir.RefFunc(_) -> acc` arm (`:6305`) — a
  `Value`-free leaf contributes nothing to collect — and must **never** be an `Error`:

  ```gleam
  ir.RefFuncImport(_, _) -> acc
  ```

- **Forced site (ii) — the body dispatch (`:1021`, no wildcard beside `ir.RefFunc(name)`): FAIL-CLOSED**
  (arm (a) below).
- **Deliberate sites — `render_ref_item` (`:4140`) and `render_ref_global_init` (`:5282`): FAIL-CLOSED**
  (arms (b)/(c) below). Both already carry a `_ -> …` wildcard, so the compiler does **not** force them;
  the keystone adds **explicit** arms anyway so the skip string is byte-identical to today's
  `UnknownFunction` (not the wildcard's `UnsupportedNode` / `NonConstInit`).

The invariant to preserve: an imported `ref.func` must keep failing with the **exact** error today's
`ir.RefFunc("f" <> slot)` produced, so the conformance skip is byte-identical (`residual_audit` green, no
assert flips). Today that error is `Error(UnknownFunction("f" <> slot))`, raised by
`element_entry` / `threaded_element_entry` (`emit_core.gleam:5781` / `:5474`) via `reference_func_entry`
(`:3426-3435`) when `dict.get(ctx.fn_arity, "f<slot>")` misses (an import name is absent from
`ctx.fn_sig` / `fn_arity` / `fn_results`, which are built only from `module.functions` at `:362-370`). The
keystone reconstructs that literal name so the skip reason is **identical**:

**(a) `emit` body dispatch (`:1021`, compiler-FORCED)** — beside `ir.RefFunc(name) ->
emit_ref_func(...)`:

```gleam
ir.RefFuncImport(slot, _) -> Error(UnknownFunction("f" <> int.to_string(slot)))
```

**(b) `render_ref_item` (`:4140`, DELIBERATE — not forced; has a `_ -> Error(UnsupportedNode(..))`
default)** — the element-segment init path. Because a `RefFuncImport` makes the segment non-`all_reffunc`
(§3.4, `emit_core.gleam:5737-5744`), an imported-`ref.func` segment routes through the general
`render_ref_items` → `render_ref_item` path. Left to the wildcard it would skip as `UnsupportedNode`; the
keystone adds an **explicit** arm so the skip string is byte-identical to today's `UnknownFunction`:

```gleam
ir.RefFuncImport(slot, _) -> Error(UnknownFunction("f" <> int.to_string(slot)))
```

**(c) `render_ref_global_init` (`:5282`, DELIBERATE — not forced; has a `_ -> Error(NonConstInit(..))`
default)** — a reference *global* initialised by an imported `ref.func` (not exercised by `table_copy`,
but added so no path silently re-categorises the skip; R14-02 *completes* this arm too — a funcref global
holding an imported funcref is well-defined and cheap, see F2 / 02 §3.1):

```gleam
ir.RefFuncImport(slot, _) -> Error(UnknownFunction("f" <> int.to_string(slot)))
```

Each **fail-closed** arm carries a `//` note naming R14-02 as the completing unit (the `collect_expr`
pass-through is permanent — R14-02 does not touch it). **The keystone does NOT touch
`needs_func_imports` (`:4715`), `all_reffunc` / `byte_ident_funcref` (`:5732-5744`), or the driver's
`module_calls_import`** — those are R14-02/R3. Because the conservative arm fails **before** any `func_import_at` read,
no `instantiate/0` vs `instantiate/1` arity desync is exposed at freeze time (the module simply skips, as
today), so the keystone is safe without the lockstep seed/detector extension.

> **Boundary summary.** Keystone lands the *sound skeleton* (node + real lower split + IR plumbing +
> fail-closed emit that reproduces today's skip byte-for-byte); R14-02 lands the *substance* (the D3a
> adapter closure Cell+Threaded, the `all_reffunc` / `byte_ident_funcref` "not-plain" treatment, the
> `needs_func_imports` element scan, and the driver mirror in lockstep). Every file stays single-
> substantive-owner; every intermediate state is green + byte-identical.

---

## §4. Tests (`test/twocore/reffunc_import_freeze_test.gleam`) — spec-cited + adversarial

Objective tests against the **WebAssembly spec** semantics for element segments + `call_indirect` of an
imported function, **not** change-detectors (R7/D8). Model on `test/twocore/ir/eh_freeze_test.gleam`
(construct/typecheck the value; assert against the spec rule; use `emit_core.emit_module(m,
instance.safe_default())` for the emit assertions).

1. **The node is EXPRESSIBLE.** Construct a `Function` / `Module` whose element segment (an `ElemExprs`
   holding `ir.RefFuncImport(slot, ty)`) **and** a function body use the node, and assert it typechecks
   (the value compiles) + pin the frozen shape via `let assert RefFuncImport(slot, ty) = …`. This is the
   load-bearing freeze: R14-02..04 bind to exactly this constructor.

2. **The `ref.func` import-split is CORRECT (the spec's unified funcidx space).** Hand-build a small AST
   `Module` with `n` function imports and a defined function; lower it (`ir_lower` / the `lower.gleam`
   frontend entry). Assert: `ast.RefFunc(f)` with `f < imported` lowers to `ir.RefFuncImport(f, ty)` where
   `ty == ir_functype(sig_f)`; `ast.RefFunc(f)` with `f >= imported` lowers to `ir.RefFunc("f" <> f)`; and
   the exact boundary `f == imported - 1` (last import) → `RefFuncImport`, `f == imported` (first defined)
   → `RefFunc`. **Spec cite:** `ref.func x` names the function at unified funcidx `x` — imports occupy
   `0..imported-1`, defined functions follow — so an imported and a defined `ref.func` differ only in
   which half of the unified index space `x` falls in (mirrors the `call` split, `lower.gleam:1392-1394`).

3. **The node is an effect BARRIER, memory-inert, and not-a-call (the arm treatment).**
   `effect.is_effectful_node(RefFuncImport(0, ty)) == True`; `effect.classify(..) == Effectful`;
   `effect.can_cse(..) == False`; `effect.can_eliminate_if_unused(..) == False`. **And** the deliberate
   non-mirrors of `CallImport`: assert (via the exported predicates / a minimal loop fixture) that
   `RefFuncImport` is **not** treated as a memory clobber (`mem_clobber` — it writes no linear memory) and
   **not** treated as a call for loop-versioning (`bce.has_grow_or_call` over a body containing only a
   `RefFuncImport` is `False`). **Spec cite:** building a funcref materialises an instance-linked closure —
   a barrier like `ref.func` of a defined function — but it neither writes memory nor dispatches, so the
   dispatch-only analyses (mem-clobber, versioning-eligibility) see it as inert, exactly as `RefFunc`.

4. **Lossless `.ir` round-trip (D5).** Build a module using `RefFuncImport` and assert
   `parser.parse_module(printer.print_module(m)) == Ok(m)`. **Adversarial coverage:** a **multi-value**
   `ty` (e.g. `[TI32, TF64] -> [TI32, TF64]`), `slot == 0` **and** a `slot >= 1`, an **empty-results**
   `ty` (`[] -> []`), the node **inside an `ElemExprs` element segment mixed with a defined `ir.RefFunc`
   item** (proving the mixed segment is not `all_reffunc` and round-trips via the canonical `elem`
   spelling), and the node inside a function body. This is the D5 proof.

5. **No new `TrapReason` (R8).** Lock the exact `TrapReason` variant set (a compile-time list, like eh's
   `trap_reason_unchanged_test`) and assert the count is unchanged (10 variants, `ir.gleam:1445-1454`).
   **Spec cite:** constructing a funcref never traps; the guards a stored imported funcref later feeds
   through `call_indirect` reuse `UndefinedElement` / `UninitializedElement` /
   `IndirectCallTypeMismatch` — no new reason is introduced.

6. **Defaults inert / byte-identical (R5).** A module with **no** imported `ref.func` (a table-0 active
   `FuncRef` segment whose items are all *defined* `ref.func`): (a)
   `parser.parse_module(printer.print_module(m)) == Ok(m)`; (b) its `.ir` text contains **none** of
   `"ref.func_import"`; (c) `emit_core.emit_module(m, instance.safe_default())` succeeds and the printed
   `.core` contains **no** `"ref.func_import"` and is **byte-identical** to a golden captured from the
   pre-keystone emitter (the frozen `init_elem` fast path is preserved — `all_reffunc` stays `True` because
   every item is a plain `ir.RefFunc`). Mirrors eh's `tag_free_module_is_conformance_neutral_test`.

7. **Imported `ref.func` STILL SKIPS, byte-identically (the conservative arm is no-regression).** Hand-
   build a module whose element segment references an **imported** function via `ir.RefFuncImport(slot,
   ty)` (as `lower` now produces) and whose module carries the matching `ImportFn`. Emit via
   `emit_core.emit_module(m, instance.safe_default())` and assert it returns
   `Error(UnknownFunction("f" <> slot))` — the **exact** error the pre-keystone `ir.RefFunc("f" <> slot)`
   produced. Assert the same for the node in a function body (arm (a)) and in a reference-global init (arm
   (c)). This pins that the keystone leaves the imported-funcref case **still skipping**, byte-identical,
   no regression — R14-02 is what flips it to `Ok`. **Spec cite (deferred obligation, R14-04 proves it):**
   an imported function reached via `call_indirect` through such a slot must return the same value as a
   direct `call` of that import — the keystone does **not** yet claim this; it claims only the byte-
   identical skip.

---

## §5. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. Spec-cited freeze tests (§4) green — including the import-split test (2), the barrier/memory-inert/not-
   a-call test (3), the D5 round-trip (4), and the still-skips no-regression test (7).
2. `///` contract docs on the new node `RefFuncImport` (shape mirrors `CallImport`, treatment mirrors
   `RefFunc`; barrier; no `Value` operands; no new trap) and on the completed `ref.func` import-split arm
   in `lower.gleam`. Each conservative-sound `emit_core` placeholder arm (§3.7) carries a `//` note naming
   R14-02 as the completing unit. (No `rt_table` / `link` docs are the keystone's — those functions are
   not added or edited here.)
3. `gleam format --check src test` clean.
4. `gleam build` **zero warnings** (every forced arm cleared; no unused import/var; `bce` / `mem_clobber`
   deliberately un-armed, confirmed by test 3, not by a stray unused pattern).
5. The unit suite passes; **default emission byte-identical** — the existing corpus/conformance suite is
   green and unchanged (no `.core` for a module without an imported `ref.func` changes; the new node/arms
   are unreached there), the imported-`ref.func` residual is unchanged (`residual_audit` green, `fail ==
   0`, `skip` total and every category constant), and `OptNone ≡ Baseline ≡ Aggressive` across the matrix
   is undisturbed. Re-confirm the exact running total (~1,978 tests / 0 fail; conformance 46,529 / 1,768 /
   0).
6. `«REFFUNC-IMPORT-FROZEN»` announced in `state.md` with the single cross-file reach (`emit_core.gleam`,
   four arms — one forced pass-through collector + three conservative-sound fail-closed) recorded as a
   *placeholder completed by R14-02*, and the exact running total re-confirmed.

---

## §6. What it leaves (handoff to downstream)

- **R14-02 (backend emit + driver — the heart, LOCKSTEP):** **completes** the `emit_core.gleam` reach —
  replace the three fail-closed arms with the real emission: `emit_ref_func_import(slot, ty, …)` (body
  dispatch), the `render_ref_item` `RefFuncImport` arm, and `imported_reference_func_entry(slot, ty, ctx,
  state)` building `#(func_type_term(ty), adapter_closure)` for **both** strategies (Cell:
  `fun(Args) -> link:call_import(rt_state:func_import_at(Slot), Args)`; Threaded:
  `fun(St, Args) -> {link:call_import(rt_state:t_func_import_at(St, Slot), Args), St}`). Make
  `all_reffunc` / `byte_ident_funcref` (`:5732-5744`) treat `RefFuncImport` as **not-plain** (routing
  mixed/imported segments to `init_elem_ref`). Extend `needs_func_imports` (`:4715`) to scan element
  segments (+ passive segments reachable via `table.init`) for `RefFuncImport`, **and** mirror it in
  `driver.module_calls_import` / `expr_calls_import` (`driver.gleam:325-340`) in the **same unit** so the
  `instantiate/0` vs `instantiate/1` arity cannot desync (R3). Owns its own emit e2e/dispatch tests.
- **R14-03 (runtime differential):** proves an import-routed funcref slot stores/dispatches identically
  across `TablePaged` / `TableEts` / `TableAtomics` × Cell/Threaded — **test-only**, building its
  differential substrate by hand (`rt_table.funcref(ty, fn(...))`); the adapter stays emitted **inline** in
  Core (the seam is frozen to inline), so no `link` helper is introduced.
- **R14-04 (capstone):** proves the acceptance table — the measured `table_copy.wast` cross-module flip
  (~1,080 asserts), the authored `corpus/xlink` backstop (imported funcref through `call_indirect`, Cell
  **and** Threaded, all table tiers, bit-identical), D3a, arity lockstep, the guard-order trap asserts
  after `table.copy`; re-measures `skipcount_test` (`max_residual_skips` lowered) and **tightens**
  `residual_audit` (removes the `UnknownFunction` cross-module allowance so a re-skip turns the suite red);
  regenerates `docs/wasm-conformance.svg` and the surface docs. Discharges the §4 test 7 deferred spec
  obligation (imported `call_indirect` ≡ direct `call`).
</content>
</invoke>
