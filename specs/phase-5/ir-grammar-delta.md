# `.ir` grammar delta — Phase-5 (IR3 surface)

> **Next delta:** the Phase-6 IR4 growth (SIMD + `call_import`) is in
> `specs/phase-6/ir-grammar-delta.md` — additive on top of this one.
>
> The **additions** to the canonical `.ir` textual form (`specs/phase-1/ir-grammar.md`, plus
> the Phase-2 delta `specs/phase-2/ir2-grammar-delta.md`) made by the Phase-5 IR growth (H7).
> Every Phase-1/2 spelling is **unchanged**; a Phase-1..4-shaped module prints byte-identically
> (§D). This file is the written grammar the printer (`src/twocore/ir/printer.gleam`) and parser
> (`src/twocore/ir/parser.gleam`) both target, so they agree with a spec — not merely with each
> other (D7). It matches the unit-02 implementation exactly; the unit-02 round-trip suite
> (`test/twocore/ir/roundtrip_test.gleam`, incl. the hand-authored `golden/refs_bulk.ir`) proves
> `parse(print(m)) == m` over the full IR3 surface.
>
> Conventions (sigils `%`/`$`/`@`, `"…"` strings, raw-hex float constants, neutral width-tagged
> op names, 2-space indentation, `;`-to-end-of-line comments, whitespace-insensitive parsing) are
> inherited verbatim. The lexer needs **no change**: every new keyword (`funcref`, `externref`,
> `ref.func`, `ref.is_null`, `null.funcref`, `table.get`, `mem.fill`, `data.drop`, `passive`,
> `declare`, …) is a single `TWord` — `.` and digits are word-continuation chars, so all dotted
> mnemonics tokenise as one word, and the `mem=`/`seg=`/`dst_mem=`/`src_mem=` decorators are a
> `TWord` immediately followed by `=`.

---

## A.1 Value types and reference types

```
valtype := i32 | i64 | f32 | f64 | term
         | funcref | externref              ; NEW — TFuncRef / TExternRef
reftype := funcref | externref              ; NEW — RefType (subset of valtype)
```

`funcref`/`externref` are legal in **every** valtype position (params/locals/globals/`FuncType`/
`mem.load` result). `parse_reftype` accepts only these two (rejecting `i32`/`term`/… with
`UnexpectedToken(expected: "reftype")`).

## A.2 The null reference literal (a `Value`, R1c)

A null reference is the **`ConstNull(ty)` `Value`** — a null literal, like `i32.const`, not a
separate `Expr` (R1c drops `RefNull` as an `Expr`). Its spelling is a single dotted token:

```
value += null.funcref        ; ConstNull(FuncRef)
       | null.externref      ; ConstNull(ExternRef)
```

So `ref.null t` lowers to a `ConstNull(t)` value operand; it appears anywhere a `value` may
(`table.grow` init, `global` init via `values (null.funcref)`, an element-init item, a `let`
rhs). There is **no** `ref.null` expression keyword — `ref.null …` in expression position is a
parse error.

## A.3 Module declarations

### A.3.1 `memory` — multiple memories + the memory64 index type

```
memory := memory none                                 ; empty list (Module.memories = [])
        | memory [ i64 | i32 ] ( min <int> [ max <int> ] )   ; one MemoryDecl
```

- `Module.memories` is a **list**. The printer emits **one `memory` line per element, in list
  order** (list position = memory index, H3), and the legacy `memory none` sentinel for the
  **empty** list (byte-identical to a Phase-1 numerics-only module). The parser accepts
  `memory none` (contributes no memory) and re-accumulates one decl per sized `memory` line.
- The index-type token is **omitted for `Idx32`** (the default — a single 32-bit memory prints
  byte-identically to Phase-4) and spelled **`i64 ` before the sizing** for `Idx64` (memory64).
  The parser also accepts an explicit `i32`.

| `MemoryDecl` | canonical spelling |
|---|---|
| `MemoryDecl(1, None, Idx32)` | `memory (min 1)` |
| `MemoryDecl(1, Some(4), Idx32)` | `memory (min 1 max 4)` |
| `MemoryDecl(2, None, Idx64)` | `memory i64 (min 2)` |

### A.3.2 `table` — reference type on the table declaration

```
table := table @<name> [ <reftype> ] min <int> [ max <int> ]
```

`TableDecl(name, ref_ty, min, max)`. The reftype is **elided for `FuncRef`** (so a Phase-2
funcref table `table @t min 2 max 8` is byte-identical) and spelled ` externref` for an
`externref` table. The parser accepts an optional reftype after `@name` (`funcref`/`externref`),
defaulting to `FuncRef` when absent (so the legacy form still parses).

### A.3.3 `import` — non-function imports (state)

```
import := import "<a>" "<b>" : <functype>                          ; ImportFn (unchanged)
        | import "<module>" "<name>" global <valtype> [ mut ]      ; ImportGlobal
        | import "<module>" "<name>" table <reftype> min <int> [max <int>]      ; ImportTable
        | import "<module>" "<name>" memory [ i64 | i32 ] ( min <int> [max <int>] )  ; ImportMemory
```

Two strings then a **kind clause** disambiguate. `ImportFn` keeps its exact Phase-1 spelling (the
`:` kind clause), so function-only modules are byte-identical. `global`/`table`/`memory` select
the state variants; the `mut`, reftype, and `i64`/`i32` markers reuse A.3.1/A.3.2.

### A.3.4 `export` — non-function exports (state)

```
export := export "<name>" = @<fn>              ; ExportFn (unchanged)
        | export "<name>" = global @<global>   ; ExportGlobal
        | export "<name>" = table @<table>     ; ExportTable
        | export "<name>" = memory <int>       ; ExportMemory (by memory index)
```

After `=`, a bare `@name` is `ExportFn` (byte-identical to Phase-1); a `global`/`table`/`memory`
keyword selects the state variant. `ExportMemory` names a memory by **index** (its position in
`Module.memories`), the others by `@name`.

### A.3.5 `data` — passive data + the memory index

```
data := data [ mem=<int> ] ( <offset-expr> ) = 0x<hexbytes>   ; DataActive(mem, offset), mem= omitted when 0
      | data passive = 0x<hexbytes>                            ; DataPassive
```

`DataSegment(mode, bytes)` with `mode = DataActive(mem, offset) | DataPassive`. The active form
keeps the Phase-2 shape and adds an optional `mem=<int>` decorator **omitted when 0** (so a
single-memory active data segment is byte-identical). The passive form drops the offset.

### A.3.6 `elem` — active / passive / declarative + reftype + init items

```
elem     := elem <reftype> <elemmode> [ <inititem>,* ]         ; canonical
          | elem @<table> ( <offset-expr> ) [ <inititem>,* ]   ; legacy (reftype=funcref, active)
elemmode := @<table> ( <offset-expr> )        ; ElemActive(table, offset)
          | passive                            ; ElemPassive
          | declare                            ; ElemDeclarative
inititem := ref.func @<name>                   ; RefFunc(name)
          | @<name>                            ; ABBREVIATION for ref.func @<name> (WAT funcidx)
          | <expr>                             ; any ref-producing const expr, e.g. values (null.funcref)
```

`ElementSegment(mode, ref_ty, init)` with `init: List(Expr)`. The printer emits the **canonical**
form `elem <reftype> <mode> [ … ]` (reftype first, then mode) for anything that is not a plain
active-funcref segment; a null slot is `Values([ConstNull(ty)])`, printed via the general
expression form `values (null.funcref)`. An **active `FuncRef` segment whose items are all
`RefFunc`** prints the **legacy** byte-identical form `elem @<table> ( <offset> ) [ @a, @b ]`
(the bare `@name` funcidx-list). The parser dispatches on the token after `elem` (a reftype
keyword ⇒ canonical, `@table` ⇒ legacy) and reads each init item as an `@name` abbreviation or a
full expression.

Canonical examples:
```
elem funcref @funcs (values (i32.const 0)) [ref.func @a, values (null.funcref)]
elem funcref passive [ref.func @a, values (null.funcref)]
elem externref declare [values (null.externref)]
```

## A.4 Reference expressions

```
expr += ref.func @<name>           ; RefFunc(fn_name)
      | ref.is_null <value>        ; RefIsNull(arg)  -> i32 bool
```

(There is **no** `ref.null` expression — see A.2; a null reference is the `null.<reftype>`
`Value`.)

| `Expr` | spelling |
|---|---|
| `RefFunc("f")` | `ref.func @f` |
| `RefIsNull(Var("x"))` | `ref.is_null %x` |
| `RefIsNull(ConstNull(FuncRef))` | `ref.is_null null.funcref` |

## A.5 Table expressions

All reference a table by `@name`. Value operands are atomic ANF `value`s. `seg=<int>` (the
passive-segment index into `Module.elements`) is always spelled.

```
expr += table.get  @<table> <index>                            ; TableGet
      | table.set  @<table> <index> <value>                    ; TableSet
      | table.size @<table>                                    ; TableSize -> i32
      | table.grow @<table> <delta> <init>                     ; TableGrow -> i32 (old size | -1)
      | table.fill @<table> <offset> <value> <count>           ; TableFill
      | table.init @<table> <dst> <src> <count> seg=<int>      ; TableInit(table, seg, …)
      | table.copy @<dsttable> @<srctable> <dst> <src> <count> ; TableCopy
      | elem.drop  seg=<int>                                    ; ElemDrop(seg)
```

`TableInit(table, seg, dst, src, count)` (R3 constructor order) prints the three value operands
positionally, then the `seg=<int>` decorator. `TableCopy` names two tables positionally.

## A.6 Bulk-memory expressions

New ops; a Phase-4 module has none, so any spelling is conformance-neutral. The memory index
follows the **omit-when-zero** rule (A.7) as a `key=<int>` decorator; `seg=` is always spelled.

```
expr += mem.fill <dest> <value> <count> [ mem=<int> ]                    ; MemFill
      | mem.copy <dst> <src> <count> [ dst_mem=<int> ] [ src_mem=<int> ] ; MemCopy (memmove)
      | mem.init <dst> <src> <count> seg=<int> [ mem=<int> ]             ; MemInit(mem, seg, …)
      | data.drop seg=<int>                                               ; DataDrop(seg)
```

Positional value operands first, then the `seg=` (mandatory) and the omit-when-zero `key=<int>`
decorators in the fixed order shown. `MemInit(mem, seg, dst, src, count)` is R3 constructor order.

## A.7 The memory-index decorator on existing memory ops

`MemSize`/`MemGrow`/`MemLoad`/`MemStore` each carry a leading `mem: Int` field (H3), spelled as a
**trailing `mem=<int>` decorator, omitted when it equals `0`** — so a single-memory (index-0)
module prints byte-identically to Phase-4 (H7).

```
mem.size [ mem=<int> ]
mem.grow <value> [ mem=<int> ]
mem.load  <result-valtype> <memaccess> <addr> offset=<int> [ mem=<int> ]
mem.store <memaccess> <addr> <value> offset=<int> [ mem=<int> ]
```

| `Expr` | spelling |
|---|---|
| `MemSize(0)` | `mem.size` |
| `MemSize(1)` | `mem.size mem=1` |
| `MemGrow(2, Var("d"))` | `mem.grow %d mem=2` |
| `MemLoad(0, MemAccess(4, False), Var("a"), 0, TI32)` | `mem.load i32 4 %a offset=0` |
| `MemLoad(1, MemAccess(1, True), Var("a"), 8, TI64)` | `mem.load i64 1 signed %a offset=8 mem=1` |
| `MemStore(3, MemAccess(4, False), Var("a"), Var("v"), 0)` | `mem.store 4 %a %v offset=0 mem=3` |

**Decorator lexical rule (parser).** The keywords `mem`, `dst_mem`, `src_mem` (and the mandatory
`seg`) are recognised **only when immediately followed by `=`**. No expression keyword is a bare
`mem`/`seg`/`dst_mem`/`src_mem` word (every real expr keyword is dotted — `mem.size`, `mem.fill`,
… — or distinct), so no statement can begin with a bare decorator word; the trailing peek for an
optional decorator is unambiguous and cannot swallow a following statement in a `let`/`charge`
continuation. `offset` (Phase-2) already works this way.

---

## D. Backward-compatibility / byte-identity (H7 for `.ir`)

A **Phase-4-shaped module** — one 32-bit memory (or none), all `FuncRef` tables, all
`ElemActive`, all `DataActive(0, _)`, function-only imports/exports, memory index 0 everywhere,
no ref/table/bulk ops — prints with **no new tokens**:

| Construct | Phase-4-shaped module prints as | Byte-identical? |
|---|---|---|
| no memory (numerics-only) | `memory none` | yes |
| single 32-bit memory | `memory (min N [max M])` | yes |
| funcref table | `table @t min N` (reftype elided) | yes |
| active funcref elem (all `RefFunc`) | `elem @t ( off ) [ @f, … ]` (legacy list) | yes |
| memory index 0 on load/store/size/grow | `mem=` omitted | yes |
| active data, memory 0 | `data ( off ) = 0x…` | yes |
| function import/export | `import "…" "…" : …` / `export "…" = @f` | yes |

The parser also accepts the explicit spellings (an explicit `funcref`/`i32`, a canonical
`elem funcref @t …`), so both the legacy and canonical texts parse to the same `Module`.

## Reconciliation notes (deviations from unit-doc §A / open questions)

- **`ConstNull` is a `Value` (R1c).** The keystone froze `ConstNull(ty: RefType)` as a `Value`
  and dropped `RefNull` as an `Expr`. Accordingly the null-ref spelling is the **value** token
  `null.funcref`/`null.externref` (OQ1's value-position spelling, single dotted token), **not**
  a `ref.null` expression. Unit-doc §A.3 (which listed `ref.null` as an `Expr`) is stale on this
  point; this delta is authoritative.
- **`memory none` is retained for the empty list** (OQ6) rather than emitting no line, so a
  numerics-only Phase-1 module is byte-identical. The parser accepts both `memory none` and an
  omitted line.
- **Import/export kind placement.** The kind keyword follows the two strings (`import "m" "n"
  global …`) / follows `=` (`export "e" = global @g`), so `ImportFn`/`ExportFn` share their exact
  prefix with the state variants and are byte-identical. (Unit-doc §A.2.3/§A.2.4 sketched the
  same shape.)
- **`elem` canonical order is `<reftype> <mode>`** and the declarative keyword is `declare`
  (matching the WASM text format), per §A.2.6.
