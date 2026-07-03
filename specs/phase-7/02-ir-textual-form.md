# Unit P7-02 — The `.ir` printer/parser extension (EH-IR surface)

> **1 owner. Wave A, fast-follow OFF the freeze critical path.** Hard freeze dep:
> `«EH-IR-FROZEN»` (P7-01 — `ir.gleam` gains `Module.tags: List(TagDecl)`, the `ExnRef`
> `RefType` + `TExnRef` `ValType`, the `Throw` / `TryTable` / `ThrowRef` `Expr` nodes, the
> `CatchClause` type, and the `ImportTag` / `ExportTag` declaration variants — plus the
> spellings recorded in `specs/phase-7/ir-grammar-delta.md`). You gate **nothing downstream**
> — the round-trip property is a property, not an interface anyone binds to. Read
> [`00-overview.md`](00-overview.md) (J1/J2/J5/J6), then
> [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md), then
> [`../phase-6/RECONCILIATION.md`](../phase-6/RECONCILIATION.md) (the Phase-6 S-decisions still
> hold), then this doc. Where a Phase-7 reconciliation decision conflicts with this doc, the
> reconciliation wins; where P7-01 freezes a constructor shape that differs from §A's proposal,
> **P7-01's shape wins and §A tracks it bijectively** (exactly as P6-02 tracked P6-01's frozen
> `<shape>.<op>` SIMD scheme over this doc's earlier `v.<op>.<shape>` proposal).

## Context

`.ir` is the compiler's inter-stage contract (decision **D7**): any stage dumps its IR with
`twocore/ir/printer.print_module` and reloads it with `twocore/ir/parser.parse_module`, and the
two satisfy `parse(print(m)) == m` for every module `m`. Phase 1 made this green over the Phase-1
IR surface; Phase 2 (`P2-02`) extended it to tables/active-elements/mem-ops/floats/converting
`ConvOp`s; Phase 5 (`P5-02`) extended it to the full **IR3** surface (reftype value types +
`RefType`, the reference/table/bulk-memory `Expr` nodes, multi-memory + the memory-index
decorator, the `IdxType`/`Idx64` axis, the import/export state variants, the active/passive/
declarative element + passive data model, `ConstNull(RefType)`); Phase 6 (`P6-02`) extended it to
the **IR4** surface (the `TV128` valtype, `ConstV128(bytes)`, the ~110-constructor `SimdOp` enum,
`SimdShuffle`/`SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`, and the cross-module
`CallImport(slot, ty, args)` node). Phases 3 and 4 added **no** IR node types.

Phase 7 grows the IR again — this time with a **generic structured-exception model** (J2): a
`(tag)` declaration space, a `Throw`, a `TryTable` (try-with-tagged-catches), a `ThrowRef`
(re-raise a caught exception reference), and an `exnref` reference value. The keystone (`P7-01`)
adds, all at once:

- **`Module.tags: List(TagDecl)`** — a `TagDecl` is a **name + the list of value types the
  exception carries** (the tag's operand signature). Tags occupy a named declaration space in the
  IR, like globals and tables. Imported / exported tags follow the P5 import/export state pattern
  (`ImportTag`, `ExportTag`).
- the **`ExnRef` `RefType`** + its **`TExnRef` `ValType`** — a caught-exception handle, a new
  member of the reference layer (H1), **opaque like `externref`** (J5): Safe code may hold, pass,
  store, null-test, and *re-throw* one but **cannot forge or inspect** the underlying BEAM
  exception term. `reftype_to_valtype(ExnRef) = TExnRef`; `ConstNull(ExnRef)` is the null exnref.
- the **`Throw(tag, args)` `Expr`** — throw exception `tag` carrying `args`; does not return
  (bottom, like `Return`/`Trap`).
- the **`TryTable(result, body, catches)` `Expr`** — evaluate `body`; each catch clause is
  `(tag | catch_all, label, capture_ref: Bool)`; on a matching thrown tag transfer to the catch
  clause's `label` with the payload (and the exnref if `capture_ref`); an unmatched exception
  propagates. Structured (named labels, D6).
- the **`ThrowRef(exnref)` `Expr`** — re-raise a caught exception reference.

**This is the first IR growth in the reference layer since Phase 5.** Every EH addition must
**print and parse losslessly**, or the dump/load boundary silently drops a Phase-7 feature — and,
because a downstream unit (05 lower, 06 emit_core, 07 rt_exn) golden-tests through `.ir`, a lossy
EH spelling would corrupt the very fixtures those units check against. You **extend** the
Phase-1/2/5/6 printer/parser/test; you do not rewrite them. Their structure (centralized
`*_to_string` / `string_to_*` spelling tables, a two-phase recursive-descent total parser,
hand-authored goldens, an independently-built expected `Module`) is the template, and it
accommodates the EH surface with **no lexer change and no new `ParseError` variant** (§C).

## Goal

Keep `parse(print(m)) == m` **GREEN over the full EH-IR surface.** Every new variant prints in one
canonical spelling and parses back to the identical `Module`. The parser stays **total** — no
`let assert`/`panic`/`todo` on any path reachable from untrusted text; every fault is a typed
`ParseError` with position info. Measurable done: the round-trip property passes on a corpus that
exercises **every `TagDecl` shape** (empty-param and multi-param tags; a module tag, an imported
tag, an exported tag), the **`exnref` valtype in every valtype position** + the **`null.exnref`**
literal, **`Throw`** with zero/one/many args, **`TryTable`** with each catch-clause kind (`catch`,
`catch_ref`, `catch_all`, `catch_all_ref`) singly and in combination and with an **empty catch
list**, nested try/catch, and **`ThrowRef`**; the new hand-authored `exn.ir` golden (§E) parses to
its independently-built expected `Module` and re-prints stably; the **six** existing goldens
(`add`/`sum_to`/`fib`/`mem_table`/`refs_bulk`/`simd`) **still parse** and **still print
byte-identically** (the EH additions perturb no legacy spelling); and the negative/fuzz corpus
returns typed errors for the new malformed forms without panicking.

## Files owned

| Path | Role |
|---|---|
| `src/twocore/ir/printer.gleam` | IR → `.ir` text. **Extend** `print_module` (a `tags` block), `print_valtype`, `print_reftype`, `print_import`, `print_export`, `print_expr`; add `print_tag`, `print_catch`. |
| `src/twocore/ir/parser.gleam` | `.ir` text → IR. **Extend** `parse_module` accumulator + `build_module`, `parse_module_items` (a `tag` item), `parse_valtype`, `parse_reftype`/`parse_opt_reftype`, `parse_value` (`null.exnref`), `parse_import`, `parse_export`, `parse_expr`; add `parse_tag`, `parse_throw`, `parse_try_table`, `parse_catch_list`/`parse_catch_clause`, `parse_throw_ref`. |
| `test/twocore/ir/roundtrip_test.gleam` | **Extend** the corpora + add the new golden test + the EH discrimination tests + the EH negative corpus. (Minimally touched by `P7-01` to keep the tree compiling; you fill in the real coverage.) |
| `test/twocore/ir/golden/exn.ir` | **Add** ≥1 hand-authored Phase-7 golden exercising a tag (+ imported/exported tag), `exnref`/`null.exnref`, `Throw`, a `TryTable` with a matching `catch` + a `catch_all` + a `catch_ref`/`catch_all_ref`, and `ThrowRef`. Hand-authored — never printer-generated. |
| `specs/phase-7/ir-grammar-delta.md` | **Add/reconcile** the frozen grammar delta (mirrors `specs/phase-6/ir-grammar-delta.md`); §A of this doc is its authoritative source. |

You **read** `src/twocore/ir.gleam` (the EH-IR types), `specs/phase-1/ir-grammar.md`,
`specs/phase-2/ir2-grammar-delta.md`, `specs/phase-5/ir-grammar-delta.md`, and
`specs/phase-6/ir-grammar-delta.md`; you never edit `ir.gleam`, `ir/effect.gleam` (the EH-node
effect classification is P7-01's — §Effect note), or the prior grammar deltas.

## Deliverables & freeze milestones

- **No freeze milestone is owned by this unit** — it publishes no interface anyone downstream
  binds to. The round-trip property is an internal correctness invariant. (The *grammar-delta
  spellings* it fixes are, however, consumed by anyone hand-authoring an `.ir` fixture — 05/06/07
  golden tests — so treat §A as a stable, reconciled contract once P7-01 freezes the shapes.)
- Deliverable 1: the extended printer, deterministic and total (one canonical spelling per EH
  construct).
- Deliverable 2: the extended parser, total, mirroring every spelling.
- Deliverable 3: `specs/phase-7/ir-grammar-delta.md` — the written grammar the two target
  (defeats printer/parser collusion; §A here is its content), cross-linked from the Phase-6 delta.
- Deliverable 4: the extended `roundtrip_test.gleam` corpora + the hand-authored `exn.ir` golden
  with its by-hand expected `Module`.

## Depends on (freeze milestones)

- **`«EH-IR-FROZEN»`** — the only hard gate. By the time you start, `P7-01` has landed the IR type
  changes GREEN, which (Gleam has no default fields) means it has already minimally updated every
  affected constructor site in `roundtrip_test.gleam` and made the printer/parser exhaustive
  matches **compile** — possibly with placeholder arms (a `todo`, or a lossy stub) that *compile
  but do not yet round-trip*. **Your job is to replace those placeholders with the real lossless
  spellings and extend the corpus to exercise them.** Confirm the freeze is in: `Module` has
  `tags`; `RefType` has `ExnRef` and `ValType` has `TExnRef`; `Expr` has `Throw`, `TryTable`,
  `ThrowRef`; `TagDecl`, `CatchClause`, `ImportTag`, `ExportTag` exist; and `TrapReason` is
  **unchanged** (§OQ 1 — a thrown WASM exception is a *value*, not a trap; it never becomes a
  `TrapReason`).
- **The spellings in `specs/phase-7/ir-grammar-delta.md` WIN** over the proposals in this doc. If
  that file does not yet reflect P7-01's frozen shapes, author §A below as its content, get
  `P7-01` to record it verbatim, and flag any divergence — printer, parser, and grammar doc share
  one source of truth.
- You depend on **nothing downstream** and **no runtime/ABI/`rt_exn` milestone** — this is plain
  text I/O over Gleam strings. In particular you do **not** depend on `«RT-EXN-SIG»`: the `.ir`
  keyword namespace is independent of the `rt_exn`/`rt_trap` function names; `emit_core` (06) owns
  the EH-node → runtime binding, not this unit; the `{wasm_exn, TagId, Payload}` term shape (J1) is
  a runtime concern, invisible to the text.

## Scope — in / out for Phase 7

**In** (print + parse, lossless, both directions):

- **The `TExnRef` value type** → `exnref` (everywhere a `ValType` appears: params, locals,
  globals, `FuncType`, `mem.load` result — the last is vestigial, exactly as `funcref`/`v128`).
- **`ExnRef` as a `RefType`** → `exnref` in the reftype grammar (`table @t exnref …`, an imported
  exnref table, an exnref element segment) — maximally general, reusing the existing reftype
  machinery. Porffor never emits an exnref table, but the IR is capable and round-trips it.
- **The `null.exnref` value literal** → `ConstNull(ExnRef)` (falls out of the existing
  `"null." <> print_reftype(ty)` renderer once `ExnRef` is a `RefType`).
- **The module tag declaration** `TagDecl(name, params)` → `tag @name (valtype,*)`.
- **Imported / exported tags** → `import "M" "n" tag (valtype,*)` (`ImportTag`) and
  `export "name" = tag @tagname` (`ExportTag`).
- **`Throw(tag, args)`** → `throw @tag ( <value>,* )`.
- **`TryTable(result, body, catches)`** → `try_table : (results) [ <catch>,* ] { <body> }`, each
  catch clause one of `catch @tag $label` / `catch_ref @tag $label` / `catch_all $label` /
  `catch_all_ref $label`.
- **`ThrowRef(exnref)`** → `throw_ref <value>`.
- **All Phase-1..6 surface (confirm, inherited):** every prior spelling is **byte-identical**
  (§D). This unit adds a confirming round-trip for a tag-free module (byte-identical to Phase-6).

**Out** (per the J-decisions — keep deferred / owned elsewhere):

- Any **semantics** of the new nodes (which BEAM exception term a tag maps to, how `try_table`
  matches and re-raises, the exnref opacity enforcement, constant-space + preemption across a
  throw). The parser checks *syntax* and builds a well-formed `Module`; it is **not** a validator
  and does **not** check that a `throw`'s args match its tag's operand types, that a catch clause's
  `label` is in scope, that a `catch @tag`'s tag exists, or that a `TryTable`'s `result` matches
  its body. Those live in `validate` (04) / `lower` (05) / `emit_core` (06) / `rt_exn` (07). Unlike
  the `v128.const` 16-byte structural check (P6-02 §A.2), **the EH surface has no literal
  well-formedness invariant the parser must enforce** — a tag carries any valtype list, a catch
  list is any length — so the parser is pure syntax here (§Deviations 4).
- The **binary opcode bytes** — the **tag section (id `13` / `0x0d`)**, `throw` (`0x08`),
  `throw_ref` (`0x0a`), `try_table` (`0x1f`) and its catch-clause kinds (`0x00` catch / `0x01`
  catch_ref / `0x02` catch_all / `0x03` catch_all_ref), the `exnref` heap type, **and the LEGACY
  `try`/`catch`/`end` dialect Porffor 0.61.13 actually emits** (§Deviations 1 / §Seams F) — are
  the WASM binary encoding, owned by `decode` (03). The `.ir` spellings here are **neutral names**
  (D6), independent of the WASM byte encoding and of which EH dialect the binary used.
- The **EH-node → runtime binding** (`emit_core`, 06: `Throw`→`rt_exn` raise, `TryTable`→a Core
  Erlang `try…catch`, `ThrowRef`→re-raise) and the `rt_exn`/`rt_trap` bodies (07). This unit fixes
  the *`.ir` spelling*; the *runtime function names* + the `{wasm_exn, TagId, Payload}` term shape
  are a separate namespace (J1).
- The **effect classification** — `ir/effect.gleam` (owned by the keystone) classifies `Throw`,
  `TryTable`, `ThrowRef` as **effectful barriers** (J2). The printer/parser are effect-agnostic.
- The **legacy try/catch/delegate/rethrow** WASM dialect's *translation into the neutral IR* is
  `decode`/`lower`'s job (03/05), not a text concern (§Seams F). The IR's `TryTable` is the modern
  branch-to-label model; the neutral node abstracts *both* WASM EH dialects.

---

## A. The grammar delta (EBNF) — the authoritative spelling table

> This section IS the content of `specs/phase-7/ir-grammar-delta.md`. It **adds** to the Phase-1
> grammar and the Phase-2/5/6 deltas; every prior spelling is **unchanged**, so a Phase-1..6-shaped
> module (no tag, no `exnref`, no `Throw`/`TryTable`/`ThrowRef`) prints byte-identically (§D). This
> file is the written grammar the printer (`ir/printer.gleam`) and parser (`ir/parser.gleam`) both
> target, so they agree with a spec — not merely with each other (D7). The round-trip suite
> (`test/twocore/ir/roundtrip_test.gleam`, incl. the hand-authored `golden/exn.ir`) proves
> `parse(print(m)) == m` over the full EH-IR surface.
>
> Conventions (sigils `%`/`$`/`@`, `"…"` strings, raw-hex float/bytes constants, neutral op names,
> 2-space indentation, `;`-to-end-of-line comments, whitespace-insensitive parsing) are inherited
> verbatim. **The lexer needs no change.** Every new keyword — `tag`, `exnref`, `null.exnref`,
> `throw`, `throw_ref`, `try_table`, `catch`, `catch_ref`, `catch_all`, `catch_all_ref` — is a
> single `TWord`, because `.`, letters, digits, and `_` are all word(-continuation) characters (so
> `null.exnref`, `throw_ref`, `try_table`, and `catch_all_ref` each tokenise as one word). The tag
> name (`@exc`) and catch-clause label (`$handler`) reuse the existing `TAt` / `TLabel` sigil
> tokens.

### A.1 The `exnref` value type + the `null.exnref` literal (the reference-layer additions)

```
valtype := i32 | i64 | f32 | f64 | term | funcref | externref | v128
         | exnref                              ; NEW (P7) — TExnRef
reftype := funcref | externref
         | exnref                              ; NEW (P7) — ExnRef
value   += null.exnref                          ; ConstNull(ExnRef)
```

`exnref` ([EH proposal — the `exnref` heap type](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md))
is a **caught-exception handle** and a full member of the reference layer (H1). It is legal in
**every** valtype position (params/locals/globals/`FuncType`/`mem.load` result — the last is
vestigial, as with the other reftypes) and, being a `reftype`, in every reftype position
(`table @t exnref …`, an imported exnref table, an exnref element segment). `parse_valtype` gains
one arm (`"exnref" -> TExnRef`); `print_valtype` gains one (`TExnRef -> "exnref"`); `print_reftype`
/ `parse_reftype` / `parse_opt_reftype` each gain an `exnref`/`ExnRef` arm.

The null exnref literal is **`ConstNull(ExnRef)`** and spells `null.exnref` — it **falls out of the
existing renderer** `ir.ConstNull(ty) -> "null." <> print_reftype(ty)` the moment `ExnRef` joins
`print_reftype` (so the printer arm is *already written*, one reftype wider); the parser gains one
arm (`"null.exnref" -> ConstNull(ExnRef)`), mirroring `null.funcref`/`null.externref`. A caught,
non-null exnref flows as an ordinary `%var` bound by a `catch_ref`/`catch_all_ref` clause — there
is no other exnref literal (opacity, J5: Safe code cannot construct a concrete exception term).

| `Value` | canonical spelling |
|---|---|
| `ConstNull(ExnRef)` | `null.exnref` |
| a caught handle | `%e` (a `Var`, bound by a `_ref` catch clause) |

### A.2 The `tag` declaration (module tag + imported/exported tag)

A **tag** is the *type* of an exception: a name + the list of value types the exception carries
([EH proposal — tag section](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md#tags),
binary section id `13`). A tag has **no results** — it is a one-way carrier — so the IR stores just
the **operand type list**, `TagDecl(name, params)`; the `.ir` spells that list. Tags occupy a
NAMED declaration space in the IR (like globals and tables), so `throw`/`try_table` reference a tag
by `@name` (§Seams C).

```
tagdecl := tag @name ( valtype,* )              ; TagDecl(name, params)  — a module item
import  += import "M" "n" tag ( valtype,* )      ; ImportTag(module, name, params)
export  += export "name" = tag @tagname          ; ExportTag(export_name, tag_name)
```

- **Module tag decl.** `  tag @exc (f64, i32)` — the keyword `tag`, an `@name`, then a
  parenthesised valtype list (the operand signature; `()` for a tag carrying nothing). Measured:
  Porffor's exception tag is exactly `(tag (param f64 i32))` — the `(f64, i32)` JS-value pair
  ([`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md)) — so this tag decl prints
  `tag @exc (f64, i32)`.
- **Imported tag.** `  import "env" "host_exc" tag (i32)` — the import-kind dispatch (`:` / `global`
  / `table` / `memory`) gains a `tag` arm, then the same parenthesised valtype list. Follows the P5
  import state pattern (`ImportTable`/`ImportGlobal`); an imported tag is *provided state*, not a
  capability (it is a shared exception type between modules, resolved at link time — fail-closed if
  unsatisfied, H6).
- **Exported tag.** `  export "exc" = tag @exc` — the export-target dispatch (`@fn` / `global` /
  `table` / `memory`) gains a `tag @name` arm. Measured: Porffor *exports* its tag
  (`(export "0" (tag 0))`), so a cross-module JS corpus needs this.

The tag operand list reuses the printer's `valtype_list` / the parser's
`parse_paren_list(_, parse_valtype)` — the same helper `FuncType` params use — so an EH tag's
`(f64, i32)` and a functype's `(f64, i32)` render identically (they *are* the same list of
valtypes). **Placement:** the printer emits the `tags` block right after the `tables` block (both
are named indexed declaration spaces); a tag-free module emits **zero** tag lines, so placement
never perturbs legacy output (§D).

### A.3 The `Throw(tag, args)` expression

```
expr += throw @tag ( <value>,* )               ; Throw(tag, args)
```

Throw exception `tag` carrying the `args` values ([EH proposal — `throw`](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md#throwing-an-exception),
opcode `0x08`). Printed exactly like `CallDirect` one level up (`call @f (args)` ↔
`throw @tag (args)`) — the tag `@name`, then a parenthesised value list. Arity is the tag's
business (the args must match the tag's operand types) — the parser reads whatever value list is
written and does **not** arity-check (syntax only, exactly as `Num`/`CallDirect`). `Throw` does not
return (bottom — like `Return`/`Trap`), so it sits in tail position or as the whole of a
non-returning branch. Example: `throw @exc (%x, %xt)`.

### A.4 The `TryTable(result, body, catches)` expression + the catch clauses

```
expr  += try_table : ( valtype,* ) [ <catch>,* ] { <body> }    ; TryTable(result, body, catches)
catch  := catch @tag $label                     ; Catch(tag, label, capture_ref: False)
        | catch_ref @tag $label                  ; Catch(tag, label, capture_ref: True)
        | catch_all $label                       ; CatchAll(label, capture_ref: False)
        | catch_all_ref $label                   ; CatchAll(label, capture_ref: True)
```

Evaluate `body`; if a thrown exception matches a `catch @tag` / `catch_ref @tag` clause (by tag) or
any `catch_all` / `catch_all_ref` clause, transfer to that clause's `$label` (an enclosing
block/loop label, D6 named labels) delivering the tag's payload values (and, for the `_ref`
variants, the caught `exnref` as a trailing value); an **unmatched exception propagates**
([EH proposal — `try_table`](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md#try-table),
opcode `0x1f`; catch-clause kinds `0x00`/`0x01`/`0x02`/`0x03`). Spelled like the structured-control
`block` one level up (`block $l : (results) { body }` ↔ `try_table : (results) [catches] { body }`),
but with a **bracketed catch-clause list** before the body:

```
try_table : (i32) [catch @exc $onexc, catch_all $onall] {
  throw @exc (%x, %xt)
}
```

- **`result`** is the try_table's block type (the values a normal fall-off `body` yields) — printed
  as the `valtype_list` after `:`, exactly like `block`/`if`/`switch`.
- **The catch list** is a `[`-`]`-bracketed, comma-separated clause list (mirroring the shuffle
  lane list / the `elem` init list). An **empty catch list** `[]` is legal (a `try_table` that
  catches nothing — every exception propagates; a plain protected region). The clauses are read by
  a dedicated `parse_catch_clause` (not the top-level `parse_expr` dispatch), so `catch` /
  `catch_ref` / `catch_all` / `catch_all_ref` are **not** expression keywords and cannot collide
  with anything outside the bracket list.
- **The `$label`** is a `TLabel` referencing an enclosing block/loop — the catch delivers the
  payload to that label as `Break`-style values (the same label space `Break`/`Continue` use). The
  parser does **not** check the label is in scope (that is `validate`/`lower`'s job).
- **`capture_ref`** (the `_ref` suffix) records whether the caught `exnref` is delivered to the
  target label (as a trailing value) so it can be re-thrown by `ThrowRef`. Purely textual here — the
  actual exnref binding is 05/06's.

**Catch-clause type (proposal — §Seams E).** `CatchClause` is modelled as two constructors with a
`capture_ref: Bool` — `Catch(tag, label, capture_ref)` (the by-tag clauses) and
`CatchAll(label, capture_ref)` (the wildcard clauses). This is the cleanest neutral model of J2's
"`(tag | catch_all, label, ref?: Bool)`". Whether P7-01 freezes this 2-constructor-plus-bool shape
or a flat 4-constructor enum (`CatchTag`/`CatchTagRef`/`CatchAll`/`CatchAllRef`), the four `.ir`
spellings above are bijective either way; §A tracks whatever it freezes.

**No own label on `TryTable` (proposal — §Seams B).** J2 lists `TryTable`'s fields as exactly
`result`, `body`, `catches` — **no label of its own**. So a `br` that escapes the try_table's body
targets an **enclosing** `Block` (the standard IR pattern for every WASM structured construct: the
frontend wraps the WASM label in an IR `Block`). The catch labels are likewise enclosing-block
labels. If P7-01 instead gives `TryTable` its own `$label` (to make it a first-class `Break` target,
symmetric with `Block`/`Loop`/`If`), the header gains a `$label` token
(`try_table $l : (results) [catches] { body }`) and everything else stands; §A spells whatever it
freezes. **I lean label-less** (faithful to J2; the enclosing-`Block` pattern already covers
`br`-out-of-region and makes the catch-labels-are-enclosing-blocks scoping *visible* in the text —
see the golden §E).

### A.5 The `ThrowRef(exnref)` expression

```
expr += throw_ref <value>                       ; ThrowRef(exnref)
```

Re-raise a caught exception reference ([EH proposal — `throw_ref`](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md#rethrowing-an-exception),
opcode `0x0a`). Printed like `ref.is_null <value>` one level up — the keyword then a single value
operand (a `%var` bound by a `_ref` catch clause, or `null.exnref`). Like `Throw`, it does not
return (bottom). The spec traps on a **null** exnref (`throw_ref (ref.null exn)` → a trap) — that is
a runtime concern (07), not a text one; the parser round-trips `throw_ref null.exnref` fine.
Example: `throw_ref %e`.

### A.6 Phase-1..6 surface — confirmed unchanged (no new spelling)

Every Phase-1..6 spelling is inherited **verbatim** (§D). In particular a Phase-6-shaped module —
no tag, no `exnref`, no `Throw`/`TryTable`/`ThrowRef` — prints **byte-identically to Phase-6** under
this unit's printer. This unit adds a confirming round-trip (§DoD 6) so an EH-regression that leaked
a token into legacy output fails a test rather than surfacing only at conformance.

---

## B. Printer wiring (concrete Gleam sketches)

The printer's `*_to_string` / `print_*` tables remain the single source of truth for spellings; the
parser's `parse_*` / keyword dispatch mirror them, and the full-surface round-trip proves they
agree. Sketches (illustrative — final names per the P7-01-frozen types):

**Value type & reftype & null literal** — extend `print_valtype`, `print_reftype` (which makes the
existing `print_value` `ConstNull` arm handle `null.exnref` for free):
```gleam
// print_valtype: one new arm
ir.TExnRef -> "exnref"

// print_reftype: one new arm — this is ALSO what makes `null.exnref` print (via the existing
// `ConstNull(ty) -> "null." <> print_reftype(ty)` arm in print_value).
ir.ExnRef -> "exnref"
```

**The module `tags` block** — extend `print_module` (a new list, printed after `tables`) + a
`print_tag` renderer:
```gleam
// in print_module, alongside `let tables = list.map(module.tables, print_table)`:
let tags = list.map(module.tags, print_tag)
// … then splice `tags` into the flatten list, right after `tables`.

/// Renders one tag declaration: `  tag @name ( <valtype>,* )`. A tag carries a value-type list
/// (its operand signature) and has no results, so only the parenthesised param list is spelled —
/// the same `valtype_list` a `FuncType`'s params use. Total.
fn print_tag(t: ir.TagDecl) -> String {
  "  tag @" <> t.name <> " " <> valtype_list(t.params) <> "\n"
}
```

**Imported / exported tags** — one arm each on `print_import` / `print_export`:
```gleam
// print_import: one new arm (the import-kind is the keyword `tag` + the operand list)
ir.ImportTag(module, name, params) ->
  "  import \"" <> escape(module) <> "\" \"" <> escape(name)
  <> "\" tag " <> valtype_list(params) <> "\n"

// print_export: one new arm
ir.ExportTag(export_name, tag_name) ->
  "  export \"" <> escape(export_name) <> "\" = tag @" <> tag_name <> "\n"
```

**New `print_expr` arms** (Throw / ThrowRef / TryTable), mirroring `CallDirect` / `RefIsNull` /
`Block`:
```gleam
ir.Throw(tag, args) -> "throw @" <> tag <> " " <> value_list(args)
ir.ThrowRef(exnref) -> "throw_ref " <> print_value(exnref)
ir.TryTable(result, body, catches) ->
  "try_table : " <> valtype_list(result)
  <> " [" <> string.join(list.map(catches, print_catch), ", ") <> "] {\n"
  <> stmt(indent + 2, body) <> "\n" <> spaces(indent) <> "}"

/// Renders one catch clause: `catch @tag $label` / `catch_ref @tag $label` / `catch_all $label`
/// / `catch_all_ref $label`. The `_ref` suffix records `capture_ref` (the caught exnref is
/// delivered to `$label`). The single source of truth for a catch-clause spelling. Total.
fn print_catch(c: ir.CatchClause) -> String {
  case c {
    ir.Catch(tag, label, False) -> "catch @" <> tag <> " $" <> label
    ir.Catch(tag, label, True) -> "catch_ref @" <> tag <> " $" <> label
    ir.CatchAll(label, False) -> "catch_all $" <> label
    ir.CatchAll(label, True) -> "catch_all_ref $" <> label
  }
}
```
`TryTable` reuses the `block`/`stmt`/`spaces` indentation machinery exactly (body at `indent + 2`,
close brace at `indent`), so it nests cleanly inside `let`/`block`/`if` like every other structured
form.

## C. Parser wiring (concrete Gleam sketches)

**`parse_valtype`** — one arm (`"exnref" -> Ok(#(ir.TExnRef, rest))`). **`parse_reftype` +
`parse_opt_reftype`** — one `exnref`/`ExnRef` arm each. **`parse_value`** — one arm
(`"null.exnref" -> Ok(#(ir.ConstNull(ir.ExnRef), rest))`), beside `null.funcref`/`null.externref`.

**The `tags` accumulator** — extend `ModuleAcc` with a `tags: List(TagDecl)` field, reverse it in
`build_module`, and add a `"tag"` arm to `parse_module_items`:
```gleam
"tag" -> {
  use #(t, r) <- result.try(parse_tag(rest))
  parse_module_items(r, ModuleAcc(..acc, tags: [t, ..acc.tags]))
}

/// Parses one module tag declaration: `tag @name ( <valtype>,* )` → `TagDecl(name, params)`. The
/// leading `tag` keyword has been consumed. TOTAL — a missing `@name`/`(`/valtype flows a typed
/// `ParseError` from the total helpers.
fn parse_tag(toks) -> Result(#(TagDecl, List(PToken)), ParseError) {
  use #(name, rest) <- result.try(parse_at_name(toks))
  use #(params, rest) <- result.try(parse_paren_list(rest, parse_valtype))
  Ok(#(ir.TagDecl(name, params), rest))
}
```

**`parse_import` / `parse_export`** — one arm each (the kind/target dispatch already `case`s the
keyword after the strings / after `=`):
```gleam
// parse_import, after the two strings:
[PToken(TWord("tag"), _, _), ..r] -> {
  use #(params, r) <- result.try(parse_paren_list(r, parse_valtype))
  Ok(#(ir.ImportTag(a, b, params), r))
}
// parse_export, after `=`:
[PToken(TWord("tag"), _, _), ..r] -> {
  use #(t, r) <- result.try(parse_at_name(r))
  Ok(#(ir.ExportTag(ename, t), r))
}
```

**`parse_expr`** — three new keyword arms (each a distinct `TWord`, fitting the exact-string
`case kw` dispatch verbatim):
```gleam
"throw"     -> parse_throw(rest)       // @tag (args)
"throw_ref" -> {                        // a single value operand
  use #(v, rest) <- result.try(parse_value(rest))
  Ok(#(ir.ThrowRef(v), rest))
}
"try_table" -> parse_try_table(rest)   // : (results) [catches] { body }
```
```gleam
/// Parses `throw @tag (args)`. Mirrors `call @f (args)`: read the tag name, then a value list.
/// Arity is NOT checked (syntax only). TOTAL.
fn parse_throw(toks) -> Result(#(Expr, List(PToken)), ParseError) {
  use #(tag, rest) <- result.try(parse_at_name(toks))
  use #(args, rest) <- result.try(parse_value_list(rest))
  Ok(#(ir.Throw(tag, args), rest))
}

/// Parses `try_table : (results) [ <catch>,* ] { <body> }`. Mirrors `parse_block`: the block-type
/// valtype list after `:`, then the bracketed catch list, then the braced body. TOTAL.
fn parse_try_table(toks) -> Result(#(Expr, List(PToken)), ParseError) {
  use rest <- result.try(expect(toks, TColon, ":"))
  use #(result, rest) <- result.try(parse_paren_list(rest, parse_valtype))
  use #(catches, rest) <- result.try(parse_catch_list(rest))
  use rest <- result.try(expect(rest, TLBrace, "{"))
  use #(body, rest) <- result.try(parse_expr(rest))
  use rest <- result.try(expect(rest, TRBrace, "}"))
  Ok(#(ir.TryTable(result, body, catches), rest))
}

/// Parses the bracketed, comma-separated catch-clause list `[ <catch>,* ]` / `[]`. Mirrors
/// `parse_ref_init_list`'s shape (a `[`, items, `]`) over `parse_catch_clause`. TOTAL — a missing
/// `[`/`,`/`]` or an unknown clause word is a typed `ParseError`.
fn parse_catch_list(toks) -> Result(#(List(ir.CatchClause), List(PToken)), ParseError) {
  use rest <- result.try(expect(toks, TLBracket, "["))
  case rest {
    [PToken(TRBracket, _, _), ..r] -> Ok(#([], r))
    _ -> parse_catch_list_rest(rest, [])
  }
}

/// Parses one catch clause: `catch @tag $l` / `catch_ref @tag $l` / `catch_all $l` /
/// `catch_all_ref $l`. Dispatch on the leading clause word (recognised ONLY inside the bracket
/// list, so it is not a global expression keyword). TOTAL — an unknown word is `UnexpectedToken`.
fn parse_catch_clause(toks) -> Result(#(ir.CatchClause, List(PToken)), ParseError) {
  case toks {
    [PToken(TWord("catch"), _, _), ..r] -> {
      use #(tag, r) <- result.try(parse_at_name(r))
      use #(label, r) <- result.try(parse_label_name(r))
      Ok(#(ir.Catch(tag, label, False), r))
    }
    [PToken(TWord("catch_ref"), _, _), ..r] -> {
      use #(tag, r) <- result.try(parse_at_name(r))
      use #(label, r) <- result.try(parse_label_name(r))
      Ok(#(ir.Catch(tag, label, True), r))
    }
    [PToken(TWord("catch_all"), _, _), ..r] -> {
      use #(label, r) <- result.try(parse_label_name(r))
      Ok(#(ir.CatchAll(label, False), r))
    }
    [PToken(TWord("catch_all_ref"), _, _), ..r] -> {
      use #(label, r) <- result.try(parse_label_name(r))
      Ok(#(ir.CatchAll(label, True), r))
    }
    [PToken(t, l, c), ..] -> Error(UnexpectedToken(l, c, "catch clause", describe(t)))
    [] -> Error(UnexpectedEnd("catch clause"))
  }
}
```
(`ThrowRef` needs no helper — its body is the two-line `parse_value` arm shown above, mirroring
`ref.is_null`.)

**Totality (unchanged invariant).** Every new branch reuses the existing total helpers
(`parse_at_name`, `parse_label_name`, `parse_value`, `parse_value_list`, `parse_paren_list`,
`expect`, `expect_word`) — each returns `Error` (never panics) on the empty/wrong token. An unknown
catch-clause word is `UnexpectedToken`; a wrong sigil (`%x` where `@tag`/`$label` is required) is
`BadSigil`; an `exnref` where a reftype-only position wants funcref is accepted (it *is* a reftype
now); truncated input is `UnexpectedEnd`. **No new `ParseError` variant is needed** — the existing
six suffice (matching P5-02 / P6-02).

**Dispatch-collision audit (why the new keywords are unambiguous).**
- Module items: `tag` is a fresh keyword, distinct from `table` (they diverge at the 3rd
  character). The `parse_module_items` dispatch is exact-string, so no prefix hazard.
- Import kinds / export targets: `tag` is a fresh arm beside `:`/`global`/`table`/`memory` /
  `@fn`/`global`/`table`/`memory`.
- Expressions: `throw`, `throw_ref`, `try_table` are fresh, distinct from each other and from
  `trap` (`throw` ≠ `trap`) and from every prior expr keyword.
- Catch words: `catch`/`catch_ref`/`catch_all`/`catch_all_ref` are recognised **only** by
  `parse_catch_clause` inside a `try_table`'s `[ … ]`, never by `parse_expr` — so they never shadow
  an expression. (They are exact-string matched, so `catch` does not prefix-swallow `catch_all`.)
- `null.exnref` / `exnref` are single `TWord`s, distinct from `null.funcref`/`null.externref` /
  `funcref`/`externref`.

---

## D. Backward-compat & conformance-neutrality (the J6 story for `.ir`)

Every EH-IR addition is a **new keyword** (`tag`, `exnref`, `null.exnref`, `throw`, `throw_ref`,
`try_table`, the four catch words) or a **new arm on `print_valtype`/`print_reftype`/`print_import`/
`print_export`** or a **new list on `Module`**; **no existing spelling changes.** A Phase-1..6-shaped
module — no tag, no `exnref`, no EH node — therefore prints **byte-identically to Phase-6** under
this unit's printer. In particular:

| Construct | Phase-1..6-shaped module prints as | Byte-identical? |
|---|---|---|
| any non-exnref valtype | unchanged (`i32`/`funcref`/`v128`/…) | yes |
| any non-EH expr | unchanged | yes |
| a module with no tags | (no `tag` line emitted — `tags: []`) | yes — the tag block is empty |
| a host / cross-module function import | `import "…" "…" : …` (unchanged `ImportFn`) | yes |
| a SIMD / v128 module | unchanged Phase-6 spelling | yes |

The DoD asserts this concretely: the six existing goldens (`add`/`sum_to`/`fib`/`mem_table`/
`refs_bulk`/`simd`) re-print byte-identically and the Phase-6 `legacy_module_byte_identical_test`
stays green **verbatim** (its expected string is unchanged); a module with a `TagDecl` + `Throw` +
`TryTable` asserts the EH tokens appear only where an EH construct is present. This is the
`.ir`-level face of J6 (conformance-neutral-by-default); the emitted-Core byte-identity headline is
`emit_core`'s (06). **A tag-free module is byte-identical to its Phase-6 self — the load-bearing J6
invariant for the entire Phase-1..6 corpus + spec suite.**

---

## E. Worked example — the hand-authored Phase-7 golden (`exn.ir`)

A single module exercising, by hand, the EH surface — written by **reading §A** (never
printer-generated — D7), with an independently hand-built expected `Module` in the test. It includes
a **module tag decl**, an **imported tag**, an **exported tag**, the **`exnref` value type** (in
param + result position), the **`null.exnref`** literal, a **`Throw`**, a **`TryTable` whose catch
list covers all four clause kinds** (`catch` by tag, `catch_ref`, `catch_all`, `catch_all_ref`), and
a **`ThrowRef`**. The catch labels are **enclosing-block labels** (D6 named labels), which makes the
label-less-`TryTable` scoping visible. It is a **syntactic** round-trip fixture (every construct
exercised + independently hand-buildable), not an executable program — exactly as `simd.ir` was.

```
; exn — a hand-authored Phase-7 golden. Exercises, in ONE module and by reading the grammar
; delta (specs/phase-7/ir-grammar-delta.md), never printer-generated (D7): a module-level tag
; decl (the Porffor (f64, i32) exception carrier + a nullary tag), an imported tag + an exported
; tag, the exnref value type (param + result), the null.exnref literal, Throw, a TryTable whose
; catch list covers catch (by tag) / catch_ref (captures the exnref) / catch_all / catch_all_ref,
; and ThrowRef re-raising a captured exnref. EH is conformance-neutral: a tag-free module is
; byte-identical to Phase-6. Independent oracle vs collusion; syntax-only round-trip fixture.
module @exn {
  numerics true
  memory none
  tag @exc (f64, i32)
  tag @stop ()
  import "env" "host_exc" tag (i32)
  export "exc" = tag @exc
  func @guarded ( %x:f64, %xt:i32 ) -> (i32) {
    block $onexc : (i32) {
      block $onall : (i32) {
        try_table : (i32) [catch @exc $onexc, catch_all $onall] {
          throw @exc (%x, %xt)
        }
      }
    }
  }
  func @capture ( %x:f64, %xt:i32 ) -> (exnref) {
    block $caught : (exnref) {
      try_table : (exnref) [catch_ref @exc $caught, catch_all_ref $caught] {
        throw @exc (%x, %xt)
      }
    }
  }
  func @rethrow ( %e:exnref ) -> () {
    throw_ref %e
  }
  func @nullexn ( ) -> (exnref) {
    return (null.exnref)
  }
}
```

The expected `Module` is built by hand in `roundtrip_test.gleam` (an `exn_module()` builder). In
particular:
- `tags: [ir.TagDecl("exc", [ir.TF64, ir.TI32]), ir.TagDecl("stop", [])]`,
- `imports: [ir.ImportTag("env", "host_exc", [ir.TI32])]`,
- `exports: [ir.ExportTag("exc", "exc")]`,
- `@guarded`'s body is `Block("onexc", [TI32], Block("onall", [TI32], TryTable([TI32],
  Throw("exc", [Var("x"), Var("xt")]), [Catch("exc", "onexc", False), CatchAll("onall", False)])))`,
- `@capture`'s try_table catches are `[Catch("exc", "caught", True), CatchAll("caught", True)]`,
- `@rethrow`'s body is `ThrowRef(Var("e"))`,
- `@nullexn`'s body is `Return([ConstNull(ExnRef)])`.

The test asserts `parse_module(read_golden("exn.ir")) == Ok(exn_module())` **plus**
`check_roundtrip(exn_module())` (print then re-parse stable). Two independently authored artifacts
agreeing is what defeats printer/parser collusion; the by-hand `TagDecl`/`Catch`/`ConstNull(ExnRef)`
construction is what proves the EH fields (tag operand list, `capture_ref`, the exnref reftype) all
survive the round-trip.

---

## Effect / soundness / security note

- **Totality is the security property.** `parse_module` runs on **untrusted text** (a dumped
  `.ir`, a fixture, a fuzz input). A panic on malformed input is a denial-of-service / sandbox
  concern, so the parser stays total across the entire EH extension: every new branch reuses
  helpers that return typed `ParseError`, never `let assert`/`panic`/`todo`. The negative/fuzz
  corpus (§DoD 5) proves it — including the EH-specific garbage (an unknown catch-clause word, a
  `try_table` missing its `[`/`]`/`{`/`}`, a `throw` with no tag, a `%local` where a `@tag` is
  required, a bad tag operand list).
- **No new capability surface — and no ambient authority (D3a).** The printer/parser are pure
  `String ↔ Module` functions with no I/O, no ambient authority, and no evaluation. They do **not**
  raise or catch an exception, construct a `{wasm_exn, TagId, Payload}` term, or `apply` an
  attacker-named target — the thrown term is *build-controlled* and materialised only by `emit_core`
  (06) + `rt_exn` (07); a caught `exnref` is *opaque* (05/06/07); the D3a "a thrown value is a term,
  never authority" invariant (J1/J5) lives entirely downstream. This unit only *renders and re-reads
  names and shapes* — a tag NAME, a catch LABEL, an operand type LIST — never a runnable construct.
- **exnref opacity carries the externref discipline forward.** The `.ir` gives `exnref` exactly one
  literal (`null.exnref`) and otherwise only a `%var` handle — there is **no** `.ir` spelling that
  fabricates a concrete exception term, so a hand-authored / fuzzed `.ir` cannot forge an exnref
  (opacity, J5), the same guarantee `externref` already has. The forge-proof runtime representation
  (reuse `rt_ref`, J2 open-Q b) is 07's; the text layer simply offers no forging vocabulary.
- **Effect classification is not this unit's concern.** `ir/effect.gleam` (owned by the keystone
  01) classifies `Throw`, `TryTable`, and `ThrowRef` as **effectful barriers** (J2 — they alter
  control by raising/catching and must not be reordered/DCE'd across state). The printer/parser are
  effect-agnostic — they render/read structure only, so an effect-classification change never
  touches this unit.
- **Syntax, not semantics.** The parser does **not** check a `throw`'s args against its tag's
  operand types, a catch clause's `label` scoping, a `catch @tag`'s tag existence, a `TryTable`'s
  result-vs-body arity, or exnref nullability — it builds a well-formed `Module` and defers all
  meaning to `validate`/`lower`/`emit_core`/`rt_exn`. A syntactically valid but semantically
  nonsensical `.ir` (e.g. `throw @exc (%a, %b, %c)` for a 2-operand tag, or a `catch @exc $absent`
  with no `$absent` block) parses fine and is rejected later; that separation is intentional
  (D4/D7). **Unlike** the `v128.const` 16-byte check (P6-02 §A.2), the EH surface has **no** literal
  well-formedness invariant to enforce — every EH literal (`null.exnref`) is fixed-shape and every
  list (tag operands, catch clauses) is arbitrary-length by the grammar — so the parser is pure
  syntax here (§Deviations 4).

---

## Deviations from the overview / ABI findings (ARGUED)

1. **The `.ir` EH surface is DIALECT-NEUTRAL; measured Porffor 0.61.13 emits the LEGACY
   `try`/`catch` dialect, not `try_table`.** The overview (J1) and
   [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md) assume "`try/catch` JS → `try_table`/
   `catch`". **Measured, compiling a trivial `try { … } catch { … }` through Porffor 0.61.13 +
   `wasm-tools print`:** the module has a `(tag (param f64 i32))` section (id `13`) exported as
   `(export "0" (tag 0))`, **59** `throw 0` (opcode `0x08`), and **legacy** `try`/`catch`/`end`
   (opcodes `0x06`/`0x07`/`0x0b`) — **zero** `try_table`, `throw_ref`, `catch_all`, or `exnref`.
   This is a genuine, load-bearing deviation from the assumed ABI — **but it does not touch this
   unit.** The IR is a *generic structured-exception model* (J2): the neutral `TryTable` node models
   the modern branch-to-label try-with-tagged-catches, and **`decode`/`lower` (03/05) translate
   *whichever* WASM EH dialect the binary used** — legacy `try`/`catch`/`delegate`/`rethrow` *or*
   modern `try_table`/`throw_ref` — **onto the same neutral IR**. Legacy inline handlers become
   catch-to-enclosing-block clauses; the modern `_ref`/`exnref`/`throw_ref` surface is
   Porffor-*unexercised-but-spec-complete* and I round-trip it regardless (a future Porffor build /
   a future frontend emits it, and the IR surface is already whole). **I flag this as the #1
   cross-unit seam for 01/03** (§Seams F) and keep the text form dialect-agnostic.
2. **Tags are referenced by NAME (`@tag`), not by positional index.** J2 says a tag is "a name +
   operand signature". Following the P5 precedent for *named* declaration spaces — globals
   (`GlobalGet(name)` over `GlobalDecl(name)`/`ImportGlobal(_, name)`) and tables (`@table`) — every
   tag (defined *and* imported) gets a local IR name, and `throw`/`try_table` reference it by
   `@name`. This is the D6-neutral, readable choice and reuses the `@`-sigil machinery. (Contrast
   `CallImport(slot)`, which is positional because an imported *function* has no same-module
   definition to name; a tag, like a global, is a named declaration.) **Seam C:** if P7-01 instead
   makes `Throw`/`Catch` reference a positional `tagidx: Int` (as `CallImport` does), the spelling
   becomes a bare number (`throw 0 (…)`); I lean named (§Seams C). I round-trip whatever it freezes.
3. **`exnref` is modelled as a full `RefType` (`ExnRef`), reusing the reftype/null machinery.** J2
   says `exnref` is "a new reference-layer value … opaque like `externref`". Making it a member of
   `RefType` (not a bespoke value) means `TExnRef` widens via `reftype_to_valtype`, `null.exnref`
   falls out of the existing `ConstNull(_)` renderer, and an exnref table/element/import round-trips
   for free — maximally general at zero extra text cost, and exactly parallel to how `externref`
   was added in P5. Porffor never emits an exnref table, but the IR should be capable (a future
   frontend / a wider WASM corpus may). **Seam G:** the runtime `classify_ref` (rt_ref) then needs
   an `is_exn` test to distinguish an exnref box from funcref/externref — 07's concern, not the
   text's.
4. **The parser enforces NO EH literal well-formedness check.** P6-02 placed a *structural* 16-byte
   check on `v128.const` (its `ConstV128` contract). The EH surface has **no analogue**: the only EH
   literal is `null.exnref` (fixed shape, nothing to check), a `TagDecl`'s operand list is any
   valtype list, and a `TryTable`'s catch list is any length (an empty `[]` is legal). So the parser
   stays pure syntax across the whole EH surface — every EH constraint (a throw's arg arity vs its
   tag, a catch label's scope, a tag's existence) is a *typing* rule owned by `validate` (04), never
   a parser check. This is the deliberate D4/D7 syntax-vs-semantics split.
5. **`TryTable` is spelled label-less (`try_table : (results) [catches] { body }`), catch labels are
   enclosing-block labels.** J2 lists `TryTable`'s fields as `result`/`body`/`catches` (no own
   label). The label-less shape composes with the standard IR pattern (a WASM structured construct's
   own label becomes an enclosing IR `Block`), and it makes the "catch labels are enclosing blocks"
   scoping *visible* in the golden (§E). **Seam B:** if P7-01 gives `TryTable` its own `$label`, the
   header gains it; I lean label-less (faithful to J2). Either round-trips.
6. **The catch-clause spelling is a 4-way keyword (`catch`/`catch_ref`/`catch_all`/`catch_all_ref`)
   read only inside `try_table`'s `[ … ]`.** This keeps the four EH-proposal catch kinds
   (`0x00`/`0x01`/`0x02`/`0x03`) as neutral IR keywords that never enter the global expression
   namespace (so they cannot shadow an expression), and models J2's `(tag | catch_all, label,
   ref?)` as `Catch(tag, label, capture_ref)` / `CatchAll(label, capture_ref)`. **Seam E:** a flat
   4-constructor `CatchClause` enum round-trips identically; §A tracks P7-01's choice.

---

## Verification — Definition of Done (D8)

Tests assert the **D7 contract and the §A grammar**, not whatever the printer happens to emit (no
change-detector tests). Spec-objective: the corpus is derived from the **EH proposal's surface**
(what forms must exist — a tag with any operand list, the four catch-clause kinds, `throw`/
`throw_ref`, the exnref value/null) and the round-trip property `parse(print(m)) == m` is the
algebraic invariant asserted.

1. **Round-trip property** holds via `module_equal` (`==`) on the extended full-surface corpus:
   - the `TExnRef` valtype in **every** valtype position (param/local/global/functype/`mem.load`
     result) and as a `RefType` (a `table @t exnref`, an imported exnref table, an exnref element);
   - a `ConstNull(ExnRef)` (`null.exnref`) in value position;
   - a `TagDecl` with an **empty** operand list, a **one-type** list, and the **Porffor `(f64, i32)`**
     list; an `ImportTag`; an `ExportTag`;
   - a `Throw` with **zero**, **one**, and **many** args;
   - a `TryTable` with each catch-clause kind **singly**, **all four together**, and an **empty
     catch list `[]`**; a `TryTable` **nested** inside another (nested try/catch); a `TryTable`
     whose `result` is empty and non-empty;
   - a `ThrowRef` over a `%var` and over `null.exnref`;
   each round-trips to the identical `Module`.
2. **Golden suite (independent oracle).** The hand-authored `exn.ir` (§E) parses to its by-hand
   expected `Module` and re-prints + re-parses stably (`check_roundtrip`). The **six** existing
   goldens `add`/`sum_to`/`fib`/`mem_table`/`refs_bulk`/`simd` **still parse** to their expected
   modules and **re-print byte-identically** — proving the EH growth perturbed no legacy spelling.
3. **Discrimination tests** (prove no new field is dropped — each pair round-trips to **distinct**
   `Module`s):
   - `Catch("exc", "l", False)` vs `Catch("exc", "l", True)` (the `capture_ref` bool → `catch` vs
     `catch_ref`, not dropped);
   - `CatchAll("l", False)` vs `CatchAll("l", True)` (`catch_all` vs `catch_all_ref`);
   - `Catch("exc", "l", _)` vs `CatchAll("l", _)` (by-tag vs wildcard);
   - `Catch("a", "l", _)` vs `Catch("b", "l", _)` (the tag name not conflated);
   - `Catch("exc", "l1", _)` vs `Catch("exc", "l2", _)` (the label not dropped);
   - `TryTable(r, b, [c1, c2])` vs `TryTable(r, b, [c2, c1])` (catch-clause ORDER preserved);
   - `TagDecl("t", [TF64, TI32])` vs `TagDecl("t", [TI32, TF64])` (operand-list order not dropped);
   - `TagDecl("t", [])` vs `TagDecl("t", [TI32])` (a nullary tag distinct from a 1-operand tag);
   - `Throw("t", [])` vs `Throw("t", [Var("a")])` (arg list not dropped);
   - an `exnref` param vs a `funcref` param, and `null.exnref` vs `null.externref` (valtype /
     reftype not conflated).
4. **Reference-layer coexistence.** A module holding `funcref`, `externref`, **and** `exnref`
   values (params + a `null.<each>` in a value position + a table of each) round-trips, proving the
   new `ExnRef` reftype coexists with the P5 reftypes and the P5 `ConstNull` cases still round-trip.
5. **Negative / fuzz corpus** returns the expected typed `ParseError` and **none panics**
   (totality): `throw (%a)` (missing `@tag` — `BadSigil`/`UnexpectedToken`),
   `throw @exc %a` (args not parenthesised — `UnexpectedToken`),
   `try_table (i32) [catch @exc $h] { … }` (missing `:` — `UnexpectedToken`),
   `try_table : (i32) catch @exc $h { … }` (missing `[` — `UnexpectedToken`),
   `try_table : (i32) [frob $h] { … }` (unknown catch word — `UnexpectedToken`),
   `try_table : (i32) [catch @exc] { … }` (catch missing `$label` — `UnexpectedToken`/`BadSigil`),
   `try_table : (i32) [catch_all @exc $h] { … }` (catch_all given a `@tag` where `$label` expected
   — `BadSigil`), `throw_ref` (missing operand — `UnexpectedEnd`),
   `tag @exc i32` (operand list not parenthesised — `UnexpectedToken`),
   `func @f (%x:exnrefx) …` (bad valtype — `UnexpectedToken`), and
   `import "M" "n" tag i32` (tag operands not parenthesised — `UnexpectedToken`). Reaching the end of
   the garbage battery without crashing the runner is the totality proof; fold them into the existing
   `negative_garbage_inputs_never_panic_test` and/or named per-variant tests.
6. **Byte-identity (J6).** The Phase-6 `legacy_module_byte_identical_test` stays green with its
   expected string **unchanged**; add a check that each of the six prior goldens re-prints to its
   exact prior text; add a tag+`Throw`+`TryTable` module and assert its printed `.ir` contains the
   EH tokens, and that a **tag-free** control module's printed `.ir` contains **no** `tag`/`exnref`/
   `throw`/`try_table`/`catch` token (the additions are inert for a non-EH module).
7. **Build hygiene.** `gleam format --check src test` clean; `gleam build` has **ZERO warnings**
   (no `todo`/placeholder arm may remain in printer or parser — every exhaustive match over
   `ValType`/`RefType`/`Value`/`Expr`/`ImportDecl`/`ExportDecl`/`CatchClause` is fully implemented);
   `gleam test` green (≥ the current count; every prior round-trip/golden test stays green).
8. **Docs (D8).** Every new/changed public and private function documented: `print_tag`/`parse_tag`,
   `print_catch`/`parse_catch_clause`/`parse_catch_list`(+`_rest`), `parse_throw`/`parse_try_table`/
   the `throw_ref` arm, and the updated doc comments on `print_module`/`print_valtype`/
   `print_reftype`/`print_import`/`print_export`/`print_expr`/`build_module`/`parse_module_items`/
   `parse_valtype`/`parse_reftype`/`parse_value`/`parse_import`/`parse_export`/`parse_expr` — each
   stating the contract, the `Ok`/`Error` semantics, and (for the parser) why it cannot panic.
9. **Grammar reconciled.** `specs/phase-7/ir-grammar-delta.md` exists and matches the implementation
   exactly (§A is its content), cross-linked from `specs/phase-6/ir-grammar-delta.md` like the
   Phase-2/5/6 deltas, and records any P7-01 shape divergence (Seams B–G) as the authoritative
   frozen spelling.

**Proving the goal:** (a) full-surface round-trip green (every catch-clause kind, `throw`/
`throw_ref`, the tag decl/import/export, the exnref value/null) + (b) the hand-authored `exn.ir`
parsing *and* re-printing stably defeat printer/parser collusion; (c) the discrimination tests prove
no new field (`capture_ref`, the tag name, the label, the operand list, the catch order) is silently
dropped; (d) the reference-layer coexistence test proves `ExnRef` slots cleanly beside the P5
reftypes; (e) the negative corpus returning typed errors proves totality held across the extension;
(f) the byte-identity tests prove the EH growth is conformance-neutral by default (J6).

## What this unit leaves

Once `.ir` round-trips the EH surface, every Phase-7 stage regains its golden-file boundary for the
new surface:

- **05 (lower)** can golden-test "WASM EH AST → EH IR" by emitting `.ir` and diffing against a
  hand-written expected `.ir` (the tag-section lowering, the `throw`/`try_table`/`throw_ref` node
  mapping, the catch-clause → enclosing-label resolution, **and the legacy-`try`/`catch` → neutral
  `TryTable` translation** — §Seams F).
- **06 (emit_core)** can be driven from a hand-written EH `.ir` fixture (a `throw`, a `try_table`
  with a matching catch + a catch_all, a `throw_ref`) — an end-to-end backend test of the Core
  Erlang `try…catch`/`raise` mapping with no frontend needed.
- **07 (rt_exn)** can snapshot the IR of an EH `.wast`/JS module at any seam and hand-author a
  `try_table` + `throw` fixture to feed a differential exception-propagation test.
- **08 (Porffor shim) / 09 (JS harness) / 10 (capstone)** can dump/load EH IR at any seam for
  differential tests and snapshot the IR of a Porffor-compiled JS `try/catch` program.

This unit gates none of them (the round-trip is a property, not a bound interface), so it can land
any time after `«EH-IR-FROZEN»`.

## Cross-unit seams & open questions (for reconciliation)

- **SEAM A — the EH-IR type boundary is owned by P7-01** (`«EH-IR-FROZEN»`). This unit's spelling
  table (§A) is authoritative for the `.ir` *keywords/shapes* and must track whatever P7-01 freezes
  for `Module.tags`/`TagDecl`/`ImportTag`/`ExportTag`/`Throw`/`TryTable`/`CatchClause`/`ThrowRef`/
  `ExnRef`/`TExnRef`. If 01 renames/reshapes a constructor, 02 re-spells to stay bijective (exactly
  as P6-02 tracked P6-01's frozen `<shape>.<op>` SIMD scheme over this doc's kind of proposal).
- **SEAM B — does `TryTable` carry its own `$label`?** J2 lists 3 fields (no label). I spell
  label-less (`try_table : (results) [catches] { body }`); if 01 adds a `$label` (Break-target
  symmetry with `Block`), the header gains it. I lean label-less (§Deviations 5).
- **SEAM C — tag reference: name vs positional index.** I use `@tag` (named, like globals/tables); if
  01 uses a positional `tagidx: Int` on `Throw`/`Catch` (like `CallImport`'s slot), the spelling is a
  bare number. I lean named (§Deviations 2).
- **SEAM D — `TagDecl` shape: `params: List(ValType)` vs `ty: FuncType`.** A tag has no results, so I
  store just the operand list and spell `tag @name (valtypes)`. If 01 stores a `FuncType` (results
  empty), the spelling is unchanged (I print `ty.params`), but the builder in the test constructs a
  `FuncType(params, [])` — flag so the golden's expected `Module` matches.
- **SEAM E — `CatchClause`: 2-constructor+bool vs 4-constructor enum.** Either round-trips; §A tracks
  01's choice (§Deviations 6).
- **SEAM F — MEASURED: Porffor 0.61.13 emits the LEGACY `try`/`catch` dialect, not `try_table`**
  (§Deviations 1). This is a **decode (03) / keystone (01)** concern, **not** this unit's — the
  neutral `TryTable` abstracts both WASM EH dialects, and 03/05 own the legacy-→-neutral translation
  (legacy inline handlers → catch-to-enclosing-block clauses; `delegate`/`rethrow` re-expression).
  **Flag hard to 01/03:** confirm the decoder targets the legacy dialect (what 0.61.13 emits) while
  the IR stays modern-shaped, and confirm whether the `_ref`/`exnref`/`throw_ref` IR surface is
  Porffor-exercised at the pin or is spec-complete-but-unexercised (round-tripped regardless).
- **SEAM G — `ExnRef ∈ RefType` obliges `rt_ref.classify_ref` to gain an `is_exn` test** so an
  exnref box is distinguished from funcref/externref/null (07's forge-proof representation, J2
  open-Q b). Not a text concern; flag so 07 plans the extra reference kind.
- **OQ 1 — new `TrapReason`?** Expected **none**: a WASM exception is a *value* raised/caught through
  the EH machinery, not a trap — it never becomes a `TrapReason` (throw is not a trap). The one edge
  is `throw_ref (ref.null exn)`, which the spec makes a **trap** — 07 decides whether that reuses an
  existing reason or needs one new `TrapReason` arm; if so, add exactly one snake_case arm to
  `trapreason_to_string`/`string_to_trapreason` (no design impact on this unit).
- **OQ 2 — tag decl placement in the printed module.** I place the `tags` block after `tables`; the
  choice is byte-identity-neutral (a tag-free module emits none). Confirm with 01 for the golden's
  exact text.
- **Ownership of `roundtrip_test.gleam` between P7-01 and P7-02.** As in Phases 2/5/6, P7-01
  minimally updates the constructors to compile; P7-02 owns the real corpus + the new golden.
  Confirm this split so the test file is not double-owned.
