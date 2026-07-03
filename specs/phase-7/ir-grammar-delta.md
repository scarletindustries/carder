# `.ir` grammar delta — Phase-7 (EH-IR surface)

> The **additions** to the canonical `.ir` textual form (`specs/phase-1/ir-grammar.md`, plus the
> Phase-2 delta `specs/phase-2/ir2-grammar-delta.md`, the Phase-5 delta
> `specs/phase-5/ir-grammar-delta.md`, and the Phase-6 delta `specs/phase-6/ir-grammar-delta.md`)
> made by the Phase-7 IR growth — a **generic structured-exception model** (J1/J2/J6): the tag
> declaration space (`tag` / imported / exported tags), the `exnref` reference value, and the
> `Throw` / `TryTable` / `ThrowRef` `Expr` nodes. Every Phase-1..6 spelling is **unchanged**; a
> Phase-1..6-shaped module (no tag, no `exnref`, no EH node) prints **byte-identically** (§D). This
> file is the written grammar the printer (`src/twocore/ir/printer.gleam`) and parser
> (`src/twocore/ir/parser.gleam`) both target, so they agree with a spec — not merely with each
> other (D7). It matches the unit-02 implementation exactly; the unit-02 round-trip suite
> (`test/twocore/ir/roundtrip_test.gleam`, incl. the hand-authored `golden/exn.ir`) proves
> `parse(print(m)) == m` over the full EH-IR surface.
>
> Conventions (sigils `%`/`$`/`@`, `"…"` strings, raw-hex constants, neutral op names, 2-space
> indentation, `;`-to-end-of-line comments, whitespace-insensitive parsing) are inherited verbatim.
> **The lexer needs no change.** Every new keyword — `tag`, `exnref`, `null.exnref`, `throw`,
> `throw_ref`, `try_table`, `catch`, `catch_ref`, `catch_all`, `catch_all_ref` — is a single
> `TWord`, because `.`, letters, digits, and `_` are all word(-continuation) characters. Tag names
> (`@exc`) and catch labels (`$handler`) reuse the existing `TAt` / `TLabel` sigil tokens.
>
> **⚠ This delta TRACKS the P7-01 keystone freeze (`«EH-IR-FROZEN»`).** The unit doc
> `specs/phase-7/02-ir-textual-form.md` §A is the authoritative source of these spellings; where
> P7-01 freezes a constructor shape that differs (Seams B–G in the unit doc), **P7-01's shape wins
> and this delta records the frozen spelling** (exactly as the Phase-6 delta recorded P6-01's
> `<shape>.<op>` SIMD scheme over the unit doc's `v.<op>.<shape>` proposal). The neutral IR names
> below are **not** WASM opcodes (D6) — the binary EH encoding (tag section id `13`; `throw` `0x08`,
> `throw_ref` `0x0a`, `try_table` `0x1f`; catch kinds `0x00`/`0x01`/`0x02`/`0x03`; the `exnref` heap
> type; and the LEGACY `try`/`catch`/`end` dialect Porffor 0.61.13 actually emits) is `decode`'s
> (03) concern, and the neutral `TryTable` abstracts *both* WASM EH dialects.

---

## A.1 The `exnref` value type + the `null.exnref` literal

```
valtype := i32 | i64 | f32 | f64 | term | funcref | externref | v128
         | exnref                              ; NEW (P7) — TExnRef
reftype := funcref | externref
         | exnref                              ; NEW (P7) — ExnRef
value   += null.exnref                          ; ConstNull(ExnRef)
```

`exnref` ([EH proposal — the `exnref` heap type](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md))
is a **caught-exception handle** and a full member of the reference layer (H1), **opaque like
`externref`** (J5): Safe code may hold/pass/store/null-test/re-throw one but cannot forge or inspect
the underlying BEAM exception term. It is legal in every valtype position (params/locals/globals/
`FuncType`/`mem.load` result — the last vestigial) and, being a `reftype`, in every reftype position
(`table @t exnref`, an imported exnref table, an exnref element). `parse_valtype`/`print_valtype`
gain one arm (`exnref ↔ TExnRef`); `print_reftype`/`parse_reftype`/`parse_opt_reftype` gain an
`exnref`/`ExnRef` arm. The null literal `ConstNull(ExnRef)` spells `null.exnref` — it **falls out**
of the existing `ir.ConstNull(ty) -> "null." <> print_reftype(ty)` renderer once `ExnRef` joins
`print_reftype`; the parser gains one arm beside `null.funcref`/`null.externref`. A non-null caught
exnref flows as an ordinary `%var` (bound by a `_ref` catch clause) — there is no other exnref
literal (opacity, J5).

## A.2 The `tag` declaration (module tag + imported/exported tag)

A **tag** is the type of an exception: a name + the value-type list it carries (no results). The IR
stores the operand list (`TagDecl(name, params)`) and spells it. Tags are a NAMED declaration space
(like globals/tables); `throw`/`try_table` reference a tag by `@name` (Seam C).

```
tagdecl := tag @name ( valtype,* )              ; TagDecl(name, params)          — a module item
import  += import "M" "n" tag ( valtype,* )      ; ImportTag(module, name, params)
export  += export "name" = tag @tagname          ; ExportTag(export_name, tag_name)
```

| construct | canonical spelling |
|---|---|
| `TagDecl("exc", [TF64, TI32])` (the Porffor exception carrier) | `  tag @exc (f64, i32)` |
| `TagDecl("stop", [])` (a nullary tag) | `  tag @stop ()` |
| `ImportTag("env", "host_exc", [TI32])` | `  import "env" "host_exc" tag (i32)` |
| `ExportTag("exc", "exc")` | `  export "exc" = tag @exc` |

- **Measured** ([`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md)): Porffor's exception tag is
  `(tag (param f64 i32))` — the `(f64, i32)` JS-value pair — exported as `(export "0" (tag 0))`. So
  the tag decl prints `tag @exc (f64, i32)` and the export `export "exc" = tag @exc`.
- The operand list reuses the printer's `valtype_list` / the parser's
  `parse_paren_list(_, parse_valtype)` (the same helper functype params use). The import-kind
  dispatch (`:`/`global`/`table`/`memory`) gains a `tag` arm; the export-target dispatch (`@fn`/
  `global`/`table`/`memory`) gains a `tag @name` arm — the P5 import/export state pattern.
- **Placement:** the printer emits the `tags` block right after `tables`. A tag-free module emits
  **zero** tag lines (`tags: []`), so placement never perturbs legacy output (§D).

## A.3 The `Throw(tag, args)` expression

```
expr += throw @tag ( <value>,* )               ; Throw(tag, args)
```

Throw exception `tag` carrying `args` ([EH proposal — `throw`](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md#throwing-an-exception),
opcode `0x08`). Printed like `call @f (args)` — the tag `@name`, then a parenthesised value list.
Arity is the tag's business; the parser does **not** arity-check (syntax only, like `Num`/
`CallDirect`). `Throw` does not return (bottom, like `Return`/`Trap`). Example: `throw @exc (%x, %xt)`.

## A.4 The `TryTable(result, body, catches)` expression + the catch clauses

```
expr  += try_table : ( valtype,* ) [ <catch>,* ] { <body> }    ; TryTable(result, body, catches)
catch  := catch @tag $label                     ; Catch(tag, label, capture_ref: False)     — 0x00
        | catch_ref @tag $label                  ; Catch(tag, label, capture_ref: True)       — 0x01
        | catch_all $label                       ; CatchAll(label, capture_ref: False)        — 0x02
        | catch_all_ref $label                   ; CatchAll(label, capture_ref: True)         — 0x03
```

Evaluate `body`; a thrown exception matching a `catch @tag`/`catch_ref @tag` clause (by tag) or any
`catch_all`/`catch_all_ref` clause transfers to that clause's `$label` (an enclosing block/loop
label, D6) delivering the tag's payload (and, for the `_ref` variants, the caught `exnref` as a
trailing value); an unmatched exception propagates ([EH proposal — `try_table`](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md#try-table),
opcode `0x1f`). Spelled like `block $l : (results) { body }`, but with a **bracketed catch-clause
list** before the body:

```
try_table : (i32) [catch @exc $onexc, catch_all $onall] {
  throw @exc (%x, %xt)
}
```

- **`result`** is the block type (the values a normal fall-off yields), the `valtype_list` after
  `:` — exactly like `block`/`if`/`switch`.
- **The catch list** is a `[`-`]`-bracketed comma-separated clause list (mirroring the `elem` init
  list); an **empty list `[]`** is legal (a plain protected region). Clauses are read by a dedicated
  `parse_catch_clause`, so the four catch words are **not** global expression keywords and cannot
  shadow an expression.
- **`$label`** is a `TLabel` (an enclosing block/loop label — the same space `Break`/`Continue`
  use). The parser does **not** check scope (that is `validate`/`lower`'s job).
- **`capture_ref`** (the `_ref` suffix) records whether the caught `exnref` is delivered to the
  label. Purely textual here.

**No own label on `TryTable`** (Seam B — J2 lists 3 fields). A `br` escaping the body targets an
enclosing `Block` (the standard IR pattern). If P7-01 gives `TryTable` its own `$label`, the header
gains `try_table $l : (results) …` and this delta records it.

## A.5 The `ThrowRef(exnref)` expression

```
expr += throw_ref <value>                       ; ThrowRef(exnref)
```

Re-raise a caught exception reference ([EH proposal — `throw_ref`](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md#rethrowing-an-exception),
opcode `0x0a`). Printed like `ref.is_null <value>` — the keyword then one value operand (a `%var`
bound by a `_ref` catch clause, or `null.exnref`). Does not return (bottom). The spec traps on a
null exnref (a runtime concern, 07); the parser round-trips `throw_ref null.exnref` fine. Example:
`throw_ref %e`.

---

## D. Byte-identity (H7/J6) — a Phase-1..6-shaped module is unchanged

| Construct | Phase-1..6-shaped module prints as | Byte-identical? |
|---|---|---|
| no exnref value type / no `null.exnref` | (never emitted) | yes — the new arms fire only for `TExnRef`/`ConstNull(ExnRef)` |
| no tag | (no `tag` line — `tags: []`) | yes — the tag block is empty |
| no EH expr | (never emitted) | yes — `Throw`/`TryTable`/`ThrowRef` never appear |
| a host / cross-module function import | `import "…" "…" : …` (unchanged `ImportFn`) | yes |
| a SIMD / v128 / memory64 module | unchanged Phase-6 spelling | yes |

The round-trip suite asserts a Phase-4-shaped module (`legacy_module_byte_identical_test`) prints an
EXACT expected string (unchanged), the six prior goldens (`add`/`sum_to`/`fib`/`mem_table`/
`refs_bulk`/`simd`) re-print byte-identically, and a **tag-free control module** contains **no**
`tag`/`exnref`/`throw`/`try_table`/`catch` token — so a regression that leaked a new token into
legacy output fails closed.

## Reconciliation notes (deviations from the overview / open questions)

- **The `.ir` EH surface is DIALECT-NEUTRAL.** Measured Porffor 0.61.13 emits the LEGACY
  `try`/`catch`/`end` dialect (opcodes `0x06`/`0x07`/`0x0b`) + `(tag)` + `throw` (`0x08`) — **not**
  `try_table`/`throw_ref`/`exnref` — for a trivial `try/catch` (59× `throw`, 1× legacy try/catch,
  1 tag). The neutral `TryTable`/`Throw`/`ThrowRef` IR models the modern branch-to-label form; `decode`/`lower`
  (03/05) translate *whichever* WASM EH dialect the binary used onto it. The `_ref`/`exnref`/
  `throw_ref` IR surface is Porffor-*unexercised-but-spec-complete* and round-trips regardless.
  (Unit-doc §Seams F / §Deviations 1 — the #1 flag for 01/03.)
- **Tags are referenced by NAME (`@tag`), not a positional index** (Seam C) — the P5 named-decl
  precedent (globals/tables); if 01 uses `tagidx: Int`, the spelling is a bare number.
- **`exnref` is a full `RefType` (`ExnRef`)** (Seam G) — reusing the reftype/null machinery, so an
  exnref table/element/import round-trips; obliges `rt_ref.classify_ref` to gain an `is_exn` test
  (07's concern).
- **`CatchClause` = `Catch(tag, label, capture_ref)` / `CatchAll(label, capture_ref)`** (Seam E) — a
  flat 4-constructor enum round-trips identically; this delta records 01's frozen choice.
- **`TryTable` is label-less** (Seam B — J2's 3 fields); catch labels are enclosing-block labels.
- **No new `ParseError` variant** — an unknown catch word / a `throw` missing its tag is
  `UnexpectedToken`, a wrong sigil is `BadSigil`, truncation is `UnexpectedEnd` (the six existing
  `ParseError`s suffice, matching P5-02/P6-02).
- **No new `TrapReason`** (expected) — a WASM exception is a *value* through the EH machinery, not a
  trap; the one edge is `throw_ref` on a null exnref (a spec trap), which 07 decides (OQ 1).
