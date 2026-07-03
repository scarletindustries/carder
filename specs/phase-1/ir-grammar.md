# The `.ir` textual form — grammar

> Owned by **unit 01** (frozen *with* the IR types). Implemented and reconciled by
> **unit 02** (printer + parser). It exists so the printer and parser target a *written
> grammar* rather than each other (D7 — prevents printer/parser collusion).
>
> **The unit-02 implementation (`src/twocore/ir/{printer,parser}.gleam`) is now the
> authoritative grammar** — it round-trips the full IR surface (237 tests). Six points
> resolved during implementation and folded back here: `;` is a comment, **not** a
> `let`/`charge` separator (the rhs/continuation are self-delimiting); trap reasons are
> the uniform snake_case of the `TrapReason` ctor; `ConvOp` spellings are
> `trunc_sat_{s,u}.<fw>.<iw>`, `reinterpret_{f2i,i2f}.<w>`, `box.<ty>`/`unbox.<ty>` plus
> the fixed `i32.wrap_i64`/`extendK_s` forms; `TermOp` spellings are `make_tuple`,
> `make_cons`, `tuple_get.<index>`; `data` is `data ( <offset-expr> ) = 0x<hex>`;
> canonical whitespace is compact (`%name:ty`, no inner-paren padding) though the parser
> is whitespace-insensitive.
>
> **Extensions (per-phase grammar deltas).** This page is the Phase-1 core; later phases
> grow the grammar **additively** (every spelling here is unchanged). See:
> - `specs/phase-2/ir2-grammar-delta.md` — Phase-2 (`table`/`elem`/`start`, `mem.size`/
>   `mem.grow`, the result-typed `mem.load`, the float ops, the trapping/converting `ConvOp`s).
> - `specs/phase-5/ir-grammar-delta.md` — Phase-5 IR3 (reftype valtypes + `RefType`, the
>   `null.<reftype>` literal, the reference/table/bulk-memory expressions, the memory-index
>   decorator, multi-memory + memory64, the import/export state variants, and the
>   passive/declarative segment forms).
> - `specs/phase-6/ir-grammar-delta.md` — Phase-6 IR4 (the `v128` valtype + `v128.const`
>   literal, the `simd <simdop> (args)` op family, `simd.shuffle`, the four SIMD-memory nodes,
>   and the cross-module `call_import` call).

## Design rules (from D7)

- **One canonical form.** The printer is deterministic; for any module `m`,
  `parse(print(m)) == m`, where equality compares **numeric literals by bit pattern**
  (NaN payloads and `-0.0` are significant).
- **Floats are lossless.** Print float constants as their raw bit pattern (the form
  below uses `f64.const 0x<hex-bits>`), never a decimal that can lose precision.
- **Human-readable**, LLVM-`.ll`-flavoured. Comments start with `;` to end of line.
- **Golden `.ir` files are authored by hand** against this grammar (unit 01 deliverable
  6), so the printer and parser are validated against an independent source of truth,
  not just each other.

## Lexical

```
ident   := name of a local/label/function/global, e.g. %x, %loop0, @add   ; see note
int     := decimal or 0x-hex (the stored UNSIGNED bit pattern)
fbits   := 0x-hex (raw IEEE-754 bits)
string  := "…" with the usual escapes (export/import/capability names)
comment := ';' … end-of-line
```

> **Sigil convention (frozen by unit 01):** `%name` for locals/let-bindings/loop vars,
> `$name` for labels, `@name` for functions/globals, `"…"` for host/export names. These
> are the frozen sigils; they make the textual form unambiguous and easy to parse.

## Module

```
module @<name> {
  ; capability axes (D5)
  numerics <true|false>
  memory <none | (min <int> [max <int>])>

  global @<name> : <valtype> [mut] = <expr>
  import "<capability>" "<name>" : <functype>          ; reached only via call_host
  export "<export-name>" = @<fnname>
  data ( <offset-expr> ) = 0x<hexbytes>                  ; Phase-2 (lowercase hex pairs; empty = `0x`)

  func @<name> ( <param>,* ) -> ( <valtype>* ) {        ; params are NAMED slots
    local %<name> : <valtype>
    <expr>                                               ; the body
  }
}
```

```
valtype  := i32 | i64 | f32 | f64 | term
functype := ( <valtype>* ) -> ( <valtype>* )             ; nameless; for imports/call_indirect
param    := %<name> : <valtype>                          ; a named param slot (Function.params)
```

## Values

```
value := %<name>                  ; a binding reference
       | i32.const <int>          ; raw unsigned bits in [0, 2^32)
       | i64.const <int>
       | f32.const <fbits>        ; raw binary32 bits
       | f64.const <fbits>        ; raw binary64 bits
```

## Expressions (ANF with structured control)

> **Strict ANF (frozen by unit 01).** Every *operand* position holds an atomic
> `<value>` — including an `if`/`switch` selector and the operands of
> `return`/`break`/`continue`. Computations are therefore named by `let` before being
> used; the canonical printer never nests a computation in an operand position. This is
> what makes the round-trip canonical and the 1:1 lowering to Core Erlang clean.

```
expr :=
    ; sequencing
    let ( %<name>,* ) = <expr> <expr>            ; bind rhs results, then continue (rhs is self-delimiting; no separator — `;` is a comment)
  | values ( <value>,* )                          ; forward values (tail of a block)

    ; ops
  | num <numop> ( <value>,* )
  | convert <convop> <value>
  | term <termop> ( <value>,* )                   ; Phase-2

    ; memory (Phase-2)
  | mem.load  <memaccess> <value> offset=<int>
  | mem.store <memaccess> <value> <value> offset=<int>
  | global.get @<name>
  | global.set @<name> <value>

    ; calls
  | call @<fnname> ( <value>,* )
  | call_indirect @<table> [<value>] : <functype> ( <value>,* )
  | call_host "<capability>" "<name>" ( <value>,* )

    ; structured control (NAMED labels only — D6)
  | block $<label> : ( <valtype>* ) { <expr> }
  | loop  $<label> ( <loopparam>,* ) : ( <valtype>* ) { <expr> }
  | if <value> : ( <valtype>* ) { <expr> } else { <expr> }
  | switch <value> : ( <valtype>* ) { <arm>* default { <expr> } }

    ; control transfers (do not fall through)
  | break    $<label> ( <value>,* )
  | continue $<label> ( <value>,* )
  | return ( <value>,* )

    ; effects
  | trap <trapreason>
  | charge <int> <expr>                           ; no separator (`;` is a comment)

loopparam := %<name> : <valtype> = <value>          ; name : type = initial value
arm       := case <int> { <expr> }
```

```
numop      := i.add.32 | i.sub.32 | … | f.add.64 | …   ; a neutral, width-suffixed spelling
convop     := i32.wrap_i64 | i64.extend_i32_s | trunc_sat_s.f64.i32 | box.i32 | …
memaccess  := <bytes> [signed]
trapreason := int_div_by_zero | int_overflow | unreachable | indirect_call_type_mismatch | memory_out_of_bounds
            ; uniform snake_case of the TrapReason constructor (matches unit 09 rt_trap atoms)
```

> The textual spellings of `numop`/`convop`/`trapreason` are a 1:1 rendering of the
> `NumOp`/`ConvOp`/`TrapReason` constructors in `ir.gleam`. Keep them **neutral** (no
> `i32.add`-as-the-canonical-op-name; the *value type* is i32 but the *operation
> spelling* should read as "integer add, width 32"). Unit 01 fixes the exact spellings
> when it freezes the enums.

## Worked example — `add(i32,i32) -> i32`

```
module @add {
  numerics true
  memory none
  export "add" = @add
  func @add ( %p0:i32, %p1:i32 ) -> (i32) {
    let (%r) = num i.add.32 (%p0, %p1) ;     ; ANF: bind the op, then return the value
    return (%r)
  }
}
```

## Worked example — `sum_to(n) -> i64` (loop = constant-space tail recursion)

```
module @loop {
  numerics true
  memory none
  export "sum_to" = @sum_to
  func @sum_to ( %p0:i64 ) -> (i64) {
    loop $go ( %i : i64 = i64.const 1, %acc : i64 = i64.const 0 ) : (i64) {
      let (%cond) = num i.le_u.64 (%i, %p0) ;  ; ANF: the if-selector is an atomic value
      if %cond : (i64) {
        let (%acc1) = num i.add.64 (%acc, %i) ;
        let (%i1)   = num i.add.64 (%i, i64.const 1) ;
        continue $go (%i1, %acc1)
      } else {
        break $go (%acc)
      }
    }
  }
}
```

> These two examples are also unit 01's first hand-authored golden `.ir` fixtures.
> Walking them through the `ir.gleam` types by hand (open question 4 in unit 01) is how
> you confirm the types can express the Phase-1 slice *before* freezing.
