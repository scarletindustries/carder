# Unit P7-05 — WASM lower extension (AST-EH → IR-EH): tags, throw, try_table, throw_ref, exnref

> **One owner. Extends `src/twocore/frontend/wasm/lower.gleam` (single-owner, additive).
> Wave A — runs behind the keystone freeze, in parallel with 03 (decode), 04 (validate),
> 06 (emit_core), 07 (rt_exn).** Read [`00-overview.md`](00-overview.md) (J1–J8),
> [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md) (the measured Porffor ABI), the keystone
> doc (P7-01) and the reconciliation once it lands (AUTHORITATIVE; where it and this doc disagree,
> it wins). Freeze deps: **`«EH-IR-FROZEN»`** (the IR-EH nodes you emit) and **`«WASM-AST-EH»`**
> (P7-03's day-1 AST constructors you match). Phase-6 counterpart:
> [`../phase-6/05-lower.md`](../phase-6/05-lower.md).

---

## Context

`lower.gleam` does the two WASM-frontend jobs together in one SSA naming context
(`lower/1` → `lower_func/3` → `go/3`): **stack-elimination/SSA** (the operand stack becomes named
`ir.Value` bindings — there is **no runtime stack**) and **structure → named-label IR** (a numeric
branch depth NEVER reaches the IR — D6). Phases 1–2 lowered the WASM 1.0 surface; Phase 5 completed
the standardized instruction surface minus SIMD (reference/table/bulk ops, multi-memory, non-function
imports/exports, the grown module shape); Phase 6 closed SIMD, the memory64 runtime, and cross-module
function imports (`CallImport`). It returns a typed `LowerError` (never a panic) for anything out of
scope.

Phase 7 opens the **one WASM feature 2core does not yet have** — **exception handling** — because it
is the single gate on running Porffor-compiled JavaScript on the BEAM (the load-bearing measurement:
[`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md); Porffor throws pervasively and compiles JS
`try/catch` to WASM EH). EH is a **small, language-neutral IR surface** (J2/J6): a `(tag)` declares an
exception class carrying an operand list; `throw` raises one; a protected region (`try_table`) catches
by tag and re-raises non-matches; `throw_ref` re-raises a caught handle; `exnref` is the opaque
caught-exception value. The keystone (J1) lowers all of this onto **BEAM-native exceptions** (Core
Erlang `try…catch` / `raise`) — the same compile-to-Erlang elegance as tail calls and preemption. Nothing
WASM-specific leaks into the IR: `Throw`/`TryTable`/`ThrowRef` are a **generic structured-exception
model** a future JS/Gleam frontend reuses (J6, decision #1).

**lower's role in Phase 7 is a pure syntactic map, exactly as in every prior phase.** Validation
(P7-04) has already proved the module well-typed and in scope — the tag operand types match the
`throw`'d operands, the `try_table` result and each catch clause's tag/label/exnref are well-typed,
the exnref stack discipline holds — so lower produces IR-EH nodes faithful to each instruction's spec
meaning and **nothing else**. The BEAM-exception term shape, the Core `try/catch` construction, the
tag-match + payload binding + re-raise, and the `exnref` forge-proof handle all belong **downstream**
(emit_core P7-06 + rt_exn P7-07). lower names the tag, resolves the catch labels through the existing
structured-label machinery, and forwards operands — it installs no handler and raises nothing itself.

Throughout it preserves the existing named-label + stack-elim/SSA discipline, the
`funcidx → "f<idx>"` / `globalidx → "g<idx>"` / `tableidx → "t<idx>"` naming conventions (EH adds
`tagidx → "tag<idx>"`), and the Phase-1 mutable-locals → `LoopParam` mechanism. **Conformance-neutral
by default (J6):** a module with **no tag section** and **no EH instructions** lowers to
**byte-identical** IR to Phase-6 under both modes and every shipped tier — every new construct is
additive, `Module.tags` is `[]`, and no `Throw`/`TryTable`/`ThrowRef`/`ExnRef` node is ever produced.

> ### ⚠ Measured-vs-assumed flag (load-bearing — see *Deviations* §1 and §A.4)
>
> The task brief and [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md) state Porffor emits the
> **modern** `try_table` proposal. **This unit's own probe of Porffor 0.61.13 contradicts that: it
> emits the LEGACY exception-handling proposal** — `try` (`0x06`) / `catch` (`0x07`) / `catch_all`
> (`0x19`) / `delegate` (`0x18`), plus `throw` (`0x08`) and the tag section (id `13`). Across a whole
> compiled module `wasm-tools` decodes **zero** `try_table`/`throw_ref`/`catch_ref`/`exnref`
> (reproduction in §A.4). The IR surface J2 froze (`TryTable`/`ThrowRef`/`exnref`) is the **modern,
> more-general** shape and is a correct neutral target for **both** wire proposals — legacy
> `try/catch` reduces onto the same `TryTable` — so **lower's AST→IR mapping is robust to whichever
> P7-03 decodes.** This doc writes the modern mapping (as J2/the brief direct) and shows the legacy
> AST forms map onto the same IR (§A.4), and flags the reconciliation for the planner + P7-03.

## Goal

Lower every EH instruction and the tag section into the IR, preserving the named-label + stack-elim/SSA
model. After this unit a validated Phase-7 `.wasm`/`.wat` module produces a complete `ir.Module`:
`throw x` → `ir.Throw("tag<x>", args)` (bottom, like `Return`/`Trap`); `try_table` → `ir.TryTable(result,
lowered-body, catches)` with each catch clause resolved to `(tag | catch_all, the enclosing IR label,
exnref-capture flag)` through the existing frame machinery; `throw_ref` → `ir.ThrowRef(exnref)` (bottom);
the tag section → `Module.tags` (+ imported/exported tags); and `exnref` valtype → the IR `TExnRef`
value type with its null literal. The negative obligation is the load-bearing one (J6): the entire
Phase-1..6 acceptance corpus + previously-passing suite lower to **byte-identical** IR.

## Files owned

- `src/twocore/frontend/wasm/lower.gleam` — **EXTEND** (single owner).
- `test/twocore/frontend/wasm/lower_test.gleam` — the unit's tests (mirrors `src/`; extend).

No freeze/publish-day-1 stub: lower is downstream of two freezes; it publishes nothing others depend
on. emit_core (P7-06) consumes the IR-EH nodes lower emits, but via `«EH-IR-FROZEN»`, not via lower.

## Depends on (freeze milestones)

- **`«EH-IR-FROZEN»`** (P7-01) — the IR-EH node shapes you emit. Concretely (my recommended surface,
  argued in *Deviations*; the keystone is authoritative — flag every seam so reconciliation pins
  single ownership):
  - `ir.ValType` gains **`TExnRef`** — the opaque caught-exception handle (a reference-layer value,
    forge-proof like `TExternRef`, J2/J5). `ir.RefType` gains **`ExnRef`** so `ConstNull(ExnRef)`
    (the null exnref) and `reftype_to_valtype(ExnRef) == TExnRef` exist. Placed AFTER `ExternRef`
    (keystone-placement discipline — S15 in Phase 6) so a non-EH module's exhaustive `RefType`/
    `ValType` matches keep their behaviour and gain one unreachable-in-practice arm.
  - `ir.Module` gains **`tags: List(TagDecl)`** where **`TagDecl(name: String, ty: FuncType)`** — a
    declared exception tag: a stable IR name (`"tag<absidx>"`) + the `FuncType` whose `params` are the
    carried operand types (`ty.results == []` always — a tag never yields; validate enforces). This
    mirrors `GlobalDecl`/`TableDecl` (a named module-level entity with an imports++defined index
    space).
  - `ir.ImportDecl` gains **`ImportTag(module: String, name: String, ty: FuncType)`** (an imported
    tag — provided state, keyed on the `(module, name)` link key exactly like `ImportGlobal`, J2:
    "imported/exported tags follow the P5 import/export state pattern"). `ir.ExportDecl` gains
    **`ExportTag(export_name: String, tag_name: String)`** (a tag export — Porffor exports its tag,
    measured `(export "0" (tag 0))`).
  - New `ir.Expr` nodes (all **effectful barriers** — §effect):
    - **`Throw(tag: String, args: List(Value))`** — throw exception `tag` (the IR tag name) carrying
      `args`. Does **not** return (bottom, like `Return`/`Trap`/`Unreachable`).
    - **`TryTable(result: List(ValType), body: Expr, catches: List(Catch))`** — evaluate `body`;
      `result` is the fall-through result type list (blocktype results ++ carried locals); each
      `catches` clause installs a handler.
    - **`ThrowRef(exnref: Value)`** — re-raise the caught exception `exnref`. Bottom. Traps
      (`MemoryOutOfBounds`? no — a dedicated reason; see §E + *Open questions* #4) on a **null**
      exnref, per spec.
  - **`Catch(tag: Option(String), label: String, capture_ref: Bool)`** (the catch-clause type):
    - `tag = Some("tag<x>")` for `catch`/`catch_ref` (match that tag); `tag = None` for `catch_all`/
      `catch_all_ref` (match any exception).
    - `label` — the enclosing IR named label the clause transfers to on a match (resolved by lower
      from the wire labelidx through the frame machinery — §D).
    - `capture_ref: Bool` — `True` for `catch_ref`/`catch_all_ref` (push the `exnref` handle to the
      label as well as/instead of the payload), `False` for `catch`/`catch_all`.
    This encodes the **four** catch-clause kinds exactly (§A). *Deviation #3 argues the keystone may
    need to enrich `Catch` with the target-frame transfer KIND for a catch that targets a loop /
    the function frame; the block-target case — Porffor + the common `.wast` — needs only the label.*
  - **`TrapReason` gains at most ONE variant** — a null-`throw_ref` trap (spec: `throw_ref` of a null
    exnref traps). See *Open questions* #4: reuse or add `UninitializedExn`. lower never constructs a
    `TrapReason` (it emits `ThrowRef`; the trap is rt_exn's), so this does not affect lower's code.
  - The keystone lands **minimal compile-satisfying arms** in lower (per the overview §4 ownership
    map); this unit fills the **full** mapping below. The keystone's default choices keep a tag-free
    module byte-identical.
  Until it lands, stub against these shapes; the *instruction→IR* mapping below is fixed regardless of
  the exact field spelling.
- **`«WASM-AST-EH»`** (P7-03, published day 1) — the new AST constructors you match (§A). The tag
  section (id 13), `throw`/`throw_ref`/`try_table` opcodes + the catch-clause encoding, the `exn`
  heap type / `exnref` valtype, and the tag import/export descriptors. **Until it lands, stub against
  the names in §A and re-sync when 03 publishes; the mapping is fixed.** §A.4 flags the legacy-vs-modern
  wire-shape question P7-03 owns.
- **P7-04 (validate)** — the `TypedModule` this unit consumes. lower needs **one new carried fact**:
  **`tag_types: List(ir.FuncType)`** spanning `imports ++ defined` (the tag signatures indexed by
  absolute tagidx), so `throw x` recovers its operand count from `nth_err(ctx.tag_types, x)` — exactly
  as `func_types` spans imports++defined for a call. Validate is the security boundary upstream: it
  rejects an ill-typed `throw` (operands ≠ tag params), an out-of-scope `try_table` result / catch
  label / tag, a tag with a non-empty result type, and an `exnref` misuse **before** lower runs. See
  *Open questions* #1 (the `tag_types` seam).

## Scope — in / out for Phase 7

**In:**
- **`throw x`** → `ir.Throw("tag<x>", args)` (bottom; pop the tag's operands in push order; §C).
- **`try_table bt catch*`** → `ir.TryTable(result, lowered-body, catches)` — lower the body under a
  block-like frame (its own label hosts a `br` out of the try_table), and resolve each catch clause to
  `ir.Catch(tag | catch_all, enclosing-label, capture_ref)` through the existing `st.frames`
  machinery (§D).
- **`throw_ref`** → `ir.ThrowRef(exnref)` (bottom; pop the exnref; §E).
- **the tag section** → `Module.tags` (defined tags, named `"tag<absidx>"`); imported tags →
  `ImportTag`; exported tags → `ExportTag` (§F).
- **`exnref` plumbing** — `to_ir_vt` gains `ExnRef → TExnRef`; `to_ir_reftype` gains `ExnRef`;
  `zero_value` gains `TExnRef → ConstNull(ExnRef)`; `value_type` gains `ConstNull(ExnRef) → TExnRef`;
  `ref.null exn` lowers to `ConstNull(ExnRef)` through the **existing** `ast.RefNull` arm once
  `to_ir_reftype` maps it (§B).

**Out (cite the deferral):**
- **The legacy EH proposal's wire decoding** (`try`/`catch`/`catch_all`/`delegate`/`rethrow`) is
  **P7-03's** to decode. lower maps whatever AST P7-03 publishes; §A.4 shows the legacy forms reduce
  onto the same IR-EH nodes so lower is complete either way, but the byte-level decoding is not lower's.
- **The BEAM-exception term shape, the Core `try/catch` construction, the tag-match/payload-binding/
  re-raise, and the exnref forge-proof handle** — emit_core (P7-06) + rt_exn (P7-07). lower emits the
  tier-agnostic IR node and nothing else.
- **The Porffor-ABI value convention** (`(f64, i32)` typed pairs). The tag carries `[TF64, TI32]` in
  the IR; that the `f64` is the value and the `i32` a Porffor type tag is a **host/frontend** fact
  (J6: the value ABI stays out of the IR), owned by rt_host (P7-08) + the run-ABI, not lower.
- lower does **not** validate (P7-04), optimize (no `ir_opt`), or implement any runtime.

---

## A. The AST-EH constructors this unit matches (the P7-03 seam)

lower matches `frontend/wasm/ast.gleam` constructors; the byte encoding is P7-03's. These are the names
lower expects (stub against them; re-sync when P7-03 publishes `«WASM-AST-EH»`). Opcodes are given for
**cross-reference only** — they are P7-03's authority, not lower's. lower reads the AST constructor +
its immediates and maps them. The bytes are the WebAssembly **exception-handling** proposal
([WebAssembly/exception-handling](https://github.com/WebAssembly/exception-handling)) as integrated
into the core spec.

### A.1 The tag section + tag import/export (spec: tag section id 13)

The **tag section** (id `13`) is a `vec(tag)`; each `tag = attribute:byte typeidx:u32`, `attribute =
0x00` (the exception attribute). The `typeidx` names a `FuncType` whose **params are the exception's
carried operand types** and whose **results are empty** (a tag never yields). *(Measured: Porffor's
`(tag (param f64 i32))` → `attribute 0x00`, a functype `(param f64 i32) (result)`.)* AST shape lower
expects:

```gleam
ast.Module( … , tags: List(ast.Tag))          // NEW field (P7-03)
pub type Tag { Tag(attribute: Int, type_idx: Int) }
```

Tag **imports** are a new `importdesc` kind (`0x04 attribute:byte x:typeidx`) and tag **exports** a new
`exportdesc` kind (`0x04 x:tagidx`):

```gleam
ast.ImportTag(attribute: Int, type_idx: Int)   // NEW ImportDesc variant (P7-03)
ast.ExportTag                                  // NEW ExportKind (kind byte 0x04)
```

### A.2 The EH value type (`exn` heap type / `exnref`)

`ast.ValType` gains **`ExnRef`** — the opaque caught-exception reference (the `exn` heap type, shorthand
`exnref`; the exact byte is P7-03's — the EH+typed-refs shorthand is `0x69`, and `decode_reftype` must
admit it in reftype position while `decode_valtype` admits `exnref` as a valtype). `ref.null exn` reuses
the existing `ast.RefNull(ExnRef)` (no new `Instr` — the null exnref literal). `to_ir_vt` maps
`ExnRef → ir.TExnRef` (§B).

### A.3 The EH instructions (the modern proposal — task-directed)

Two workable AST shapes and the mapping is fixed regardless of which P7-03 freezes:
**(a) flat `Instr` constructors** (the Phase-5/6 idiom) or **(b) an `ast.Eh(EhInstr)` wrapper**. This
doc writes shape (a) for concreteness. **The constructor names are P7-03's to freeze; this doc names
them so the mapping is unambiguous.**

| instruction | opcode | AST constructor lower matches | immediate(s) lower reads |
|---|---|---|---|
| `throw x` | `0x08` | `ast.Throw(tag: Int)` | the tagidx `x` |
| `throw_ref` | `0x0A` | `ast.ThrowRef` | — |
| `try_table bt catch* … end` | `0x1F` | `ast.TryTable(bt: BlockType, catches: List(CatchClause))` | the blocktype + the catch-clause vector (the body + closing `End` follow in the flat stream, exactly like `Block`/`Loop`/`If`) |

The **catch-clause** vector (part of the `try_table` immediate) encodes the four clause kinds — the
kind byte then, for `catch`/`catch_ref`, a `tagidx`, then a `labelidx`:

```gleam
pub type CatchClause {
  Catch(tag: Int, label: Int)      // 0x00 — match tag x; push its operands; branch to l
  CatchRef(tag: Int, label: Int)   // 0x01 — match tag x; push operands + the exnref; branch to l
  CatchAll(label: Int)             // 0x02 — match any; push nothing; branch to l
  CatchAllRef(label: Int)          // 0x03 — match any; push the exnref; branch to l
}
```

Per the EH proposal binary grammar
([exception-handling binary](https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md)):
`throw` pops the tag's operands and does not return; `throw_ref` pops an `exnref` and re-throws;
`try_table` is a **block-structured** instruction whose catch clauses are branch descriptors resolved
in the **enclosing** label context (§D).

### A.4 ⚠ The MEASURED reality: Porffor emits the LEGACY proposal (P7-03 + planner seam)

Reproduction (Porffor 0.61.13 + `wasm-tools` 1.252):

```
$ npx porffor wasm trycatch.js trycatch.wasm     # any JS with try/catch/throw
$ wasm-tools print trycatch.wasm | grep -cE '^\s*try_table\b'   # → 0
$ wasm-tools print trycatch.wasm | grep -cE '^\s*try\b'         # → ≥1  (legacy 0x06)
$ wasm-tools print trycatch.wasm | grep -cE '^\s*catch\b'       # → ≥1  (legacy 0x07)
$ grep -cE 'exnref|throw_ref|catch_ref|catch_all_ref' *.wat     # → 0
```

`wasm-tools` disassembles the whole module as legacy `try … catch 0 … end`, with **zero** `try_table`,
`throw_ref`, `catch_ref`, `catch_all_ref`, or `exnref`. The tag section (id 13, `(tag (param f64 i32))`)
and `throw` (`0x08`) are shared by both proposals and ARE present.

**Consequence for P7-03 (flagged), not lower.** P7-03 must decode the **legacy** opcodes to run
Porffor's output: `try` (`0x06`), `catch` (`0x07`), `catch_all` (`0x19`), `delegate` (`0x18`),
`rethrow` (`0x09`), and their inline-handler structure — *and* it may additionally decode the modern
`try_table` for the EH `.wast` conformance corpus. **Whichever it publishes, lower's IR target is the
same** (the IR is a neutral structured-exception model, J6). The legacy AST forms reduce onto the IR-EH
nodes lower already emits:

| legacy AST (Porffor) | reduces to the IR |
|---|---|
| `try bt … catch x H₁ … catch_all H₂ … end` (inline handlers) | `TryTable(result, body, [Catch(Some("tag<x>"), L₁, False), Catch(None, L₂, False)])` where `L₁`/`L₂` label the synthesized handler blocks — the inline-handler body is the branch target (see *Open questions* #3) |
| `catch_all` | a `Catch(None, …, False)` clause |
| `delegate l` (forward to an outer try) | a re-raise routed to the outer handler — `ThrowRef` of the caught exception into the enclosing try, or an outer-frame transfer |
| `rethrow l` (re-raise the exception caught at label `l`) | `ThrowRef(exnref_of_l)` — the legacy analogue of `throw_ref` |

The legacy inline-handler shape is in fact a **cleaner** fit for 2core's structured functional IR than
the modern `try_table` (whose catches branch to enclosing labels): a legacy `catch H` handler `H` is a
sub-expression and maps 1:1 onto Core `try Body catch … -> H`. This is a **strong argument the keystone
should let `Catch` carry an inline handler body**, not only a branch label — see *Deviations* §1 + #3.
This doc writes the modern (label-branch) mapping as J2 froze it, and flags the reconciliation.

---

## B. `exnref` value & tag-name plumbing

**`exnref` is a reference-layer value** (J2/J5), opaque like `externref`: Safe code may hold, pass,
store, and re-throw it but cannot forge or inspect the underlying BEAM term. Its IR type is **`TExnRef`**
and its null literal is **`ConstNull(ExnRef)`** (the null exnref, `ref.null exn`). It reuses the
**`rt_ref` forge-proof model** (P7-07 owns the representation; recommended — overview §3 open scoping
question (b)), so at runtime it is a wrapped term uncollidable with null / a funcref / an externref.

**Value-type plumbing (§I-style additions):**

```gleam
fn to_ir_vt(t: ast.ValType) -> ir.ValType {
  case t {
    ast.I32 -> ir.TI32   ast.I64 -> ir.TI64
    ast.F32 -> ir.TF32   ast.F64 -> ir.TF64
    ast.V128 -> ir.TV128
    ast.FuncRef -> ir.TFuncRef   ast.ExternRef -> ir.TExternRef
    ast.ExnRef -> ir.TExnRef                            // NEW
  }
}

fn to_ir_reftype(t: ast.ValType) -> ir.RefType {
  case t {
    ast.ExternRef -> ir.ExternRef
    ast.ExnRef -> ir.ExnRef                             // NEW
    _ -> ir.FuncRef
  }
}

// zero_value — a declared `exnref` local zero-inits to the null exnref (spec: local
// initialisation to the reftype's null, exactly like funcref/externref).
ir.TExnRef -> ir.ConstNull(ir.ExnRef)                  // NEW arm in zero_value

// value_type — a null-exnref literal is self-describing via its reftype tag.
ir.ConstNull(ir.ExnRef) -> ir.TExnRef                  // already covered by the ConstNull(ty) arm
```

`value_type`'s existing `ConstNull(ty) -> reftype_to_valtype(ty)` arm already returns `TExnRef` for an
`ExnRef` null once `RefType` gains `ExnRef` (no new arm needed). `ref.null exn` therefore lowers through
the **existing** `ast.RefNull(rt) -> push(st, ir.ConstNull(to_ir_reftype(rt)))` arm with no change — the
only additions are the two mapping arms above.

**Tag names.** A declared/imported tag at absolute tagidx `i` is named `"tag" <> int.to_string(i)`
(helper `tagname(i)`), the same absolute-index convention as `f<idx>`/`g<idx>`/`t<idx>`. A `throw x` and
every `catch x l` clause reference the tag by this name; `TagDecl.name`, `ImportTag`'s slot, and
`ExportTag`'s `tag_name` all use it, so a tag resolves to the same build-controlled exception class
across the module (the binding chokepoint is emit_core/rt_exn, J5).

---

## C. `throw` → `ir.Throw` (a bottom transfer)

`throw x` pops the tag's operands off the stack and raises the exception; it **does not return** —
its result type is bottom, exactly like `Return`/`Trap`/`Unreachable`
([spec exec/instructions §control, throw](https://webassembly.github.io/spec/core/exec/instructions.html)).
So it lowers like `ast.Return`/`ast.Unreachable`: build the transfer, then **consume the dead tail** to
the frame's closing marker (a `throw` is unconditional — everything after it in the block is
unreachable). The operand count is the tag's param count, recovered from `ctx.tag_types`:

```gleam
ast.Throw(x) -> {
  use sig <- result.try(nth_err(ctx.tag_types, x, UnknownTagIndex(x)))
  let pcount = list.length(sig.params)
  let args = take_push_order(st.stack, pcount)
  case list.length(args) == pcount {
    False -> Error(StackUnderflow)
    True -> {
      use #(marker, rest) <- result.try(consume_dead(tail, 0))
      Ok(end_or_else(marker, ir.Throw(tagname(x), args), rest, st.counter))
    }
  }
}
```

`take_push_order(st.stack, pcount)` returns the operands **deepest-first** — the WASM stack-type
left-to-right order — so `Throw(tag, [a, b])` carries the tag's operands in declaration order (matching
the tag's `param` order, so emit_core/rt_exn build the payload list in the right order). `throw` binds
no result and pushes nothing (bottom); the `consume_dead(tail, 0)` skip mirrors `Return`/`Unreachable`
exactly. `Error(UnknownTagIndex(x))` on an out-of-range tagidx (only reachable on an unvalidated module
— validation rejects it; fail-closed insurance); `Error(StackUnderflow)` on an under-deep stack (ditto).

**No new `TrapReason` for `throw`.** A `throw` is not a trap — it is a raise of a build-controlled
exception term (J1/J5). It routes through `rt_exn` (P7-07), never `rt_trap`, and an **uncaught** throw
propagates out of the instance as a BEAM exception the run-ABI surfaces (the instance boundary contains
it — J5).

---

## D. `try_table` → `ir.TryTable` + catch-clause label resolution (the meat)

`try_table bt catch* instr* end` is a **block-structured** instruction: it opens a frame (a `br` from
inside its body targets its own end, yielding the blocktype results — so it is a labelled block for
its OWN label) and installs the `catch*` clauses as dynamic handlers around the body. On a thrown
exception whose tag matches a clause, control **branches to that clause's label** (a label in scope at
the `try_table` site), carrying the exception's operands (and the `exnref` for a `_ref` clause). If no
clause matches, the exception propagates past the `try_table`
([spec exec/instructions §control, try_table](https://webassembly.github.io/spec/core/exec/instructions.html);
[EH proposal exec semantics](https://github.com/WebAssembly/exception-handling)).

**The two structural facts lower must get right:**

1. **The catch labels are resolved in the ENCLOSING context** — the frames in scope at the `try_table`
   site, *before* the try_table pushes its own body label. Per the spec typing rule, each catch
   clause's `labelidx l` is checked against `C` (the outer context), and the body is checked against
   `C` extended with the try_table's own result label. So lower resolves `l` against the **parent**
   `st.frames` (not the child frame stack), exactly as `build_transfer` resolves a `br` at the
   try_table site would — `nth_err(st.frames, l)` — giving the enclosing frame's IR named label. This
   is the "existing structured-label machinery" the task calls out; **no new label mechanism is
   introduced.**

2. **The try_table body is lowered under its own block-like frame** (a fresh label, block kind, its
   result = blocktype results ++ carried locals), like `lower_block`. Its own label hosts a `br` out of
   the try_table (rare but legal); if the body breaks to it, the emitted `TryTable` is wrapped in
   `ir.Block(label, result_types, TryTable(..))` — the same arity-transparent wrapper `finish_if` uses
   for an `if` that is a branch target (a bare `TryTable` otherwise).

```gleam
ast.TryTable(bt, catches) -> lower_try_table(bt, catches, tail, ctx, st)

fn lower_try_table(bt, catches, tail, ctx, st) {
  use #(in_ir, out_ir) <- result.try(blocktype_io(bt, ctx))
  let in_n = list.length(in_ir)
  let out_n = list.length(out_ir)
  let carried = scan_modified(tail, 0, set.new())
  use carried_ts <- result.try(carried_types(carried, ctx.local_types))
  let result_types = list.append(out_ir, carried_ts)

  // (1) Resolve each catch label against the PARENT frames (enclosing context) — the
  //     same resolution a `br l` at the try_table site would use.
  use ir_catches <- result.try(lower_catches(catches, st))

  // (2) Lower the body under the try_table's own block-like frame.
  let inner_stack = list.take(st.stack, in_n)
  let below = list.drop(st.stack, in_n)
  let #(label, c1) = fresh_label(st.counter)
  let frame = LFrame(label, FBlock, out_n, out_n, result_types, carried)
  let child = LState(inner_stack, st.locals, c1, [frame, ..st.frames], st.var_types)
  use body_res <- result.try(go(tail, ctx, child))
  use #(body_expr, rest, c2) <- result.try(expect_end(body_res))

  // Host the try_table's own label only if the body branches to it (arity-transparent
  // Block wrapper), exactly like finish_if.
  let node = ir.TryTable(result_types, body_expr, ir_catches)
  let construct = case expr_breaks_to(body_expr, label) {
    True -> ir.Block(label, result_types, node)
    False -> node
  }
  finish_construct(construct, result_types, out_n, carried, below, rest, c2, ctx, st)
}

/// Resolve every catch clause's labelidx against the enclosing frames and relabel the
/// clause kind to `ir.Catch(tag | catch_all, enclosing-label, capture_ref)`.
fn lower_catches(catches, st) {
  list.try_map(catches, fn(c) {
    let #(tag_opt, l, capture) = case c {
      ast.Catch(x, l) -> #(Some(tagname(x)), l, False)
      ast.CatchRef(x, l) -> #(Some(tagname(x)), l, True)
      ast.CatchAll(l) -> #(None, l, False)
      ast.CatchAllRef(l) -> #(None, l, True)
    }
    use fr <- result.try(nth_err(st.frames, l, Malformed("catch label out of range")))
    Ok(ir.Catch(tag_opt, fr.label, capture))
  })
}
```

**Operand order / payload arity.** A matching catch delivers the exception's operands to `label` in
tag-param order (and, for `_ref`, the `exnref` — spec pushes the operands then the exnref). The label's
expected value count equals the tag's operand count (+1 for `_ref`) — **validate proved this**
(`C.labels[l]` matches the tag's operand types, extended by `exnref` for `_ref`), so lower carries no
arity check beyond fail-closed insurance. lower records `capture_ref` so emit_core knows whether the
exnref is bound; it does **not** itself synthesize the payload values (they are dynamic — the caught
exception's operands, materialised by emit_core's Core `try/catch` handler + rt_exn).

**What lower deliberately leaves to emit_core (06) + rt_exn (07) — flagged §cross-unit:**
- Wrapping `body` in a Core Erlang `try … catch` that matches the tag term
  (`{wasm_exn, TagName, Payload}`), binds `Payload` to the clause's delivered values, binds the
  `exnref` for a `_ref` clause, and **re-raises a non-matching exception** (spec unwinding).
- Building the actual **transfer** to `label` (a `Break`/`Continue`/`Return` per the target frame's
  kind) carrying `[payload (++ exnref) ++ the target frame's carried locals]`. **The carried-locals /
  SSA-locals-across-a-throw interaction is the load-bearing keystone/emit_core seam** (see below).

> ### The hard seam: WASM locals persist across a throw, but 2core threads locals as SSA
>
> In WASM a local belongs to the **function frame** and survives an exception unwind — after a catch,
> the function's locals hold whatever they held when the throw happened. 2core, by contrast, turns a
> mutable local assigned inside a block into a **threaded SSA value** (`scan_modified`/`carried`/
> `LoopParam`). A catch that transfers to an enclosing block expects `[payload ++ that block's carried
> locals]`, but the "current" local values at a *dynamic* unwind point are not a static SSA name at the
> catch site. **This is genuinely the keystone's (P7-01) + emit_core's (P7-06) problem, not lower's.**
> The plausible resolutions the keystone must pick among (flagged, not decided here):
> (a) a function containing a `try_table` reifies its mutable locals into a small mutable cell so the
> catch handler reads current values (localised, only for EH functions — byte-identical elsewhere);
> (b) `Catch` carries an inline handler body (the legacy-Porffor shape, §A.4) so the handler runs in
> the try_table's own SSA continuation and no cross-frame carried-local delivery is needed; or
> (c) restrict Phase-7 catch targets to forward block labels with no carried locals threaded across the
> boundary (covers Porffor + the primary `.wast`), deferring the general case. lower's mapping (resolve
> label + tag + capture flag) is unchanged under all three; the choice lives in 01/06.

---

## E. `throw_ref` → `ir.ThrowRef` (a bottom re-raise)

`throw_ref` pops an `exnref` and re-throws that exception; it **does not return** (bottom) and **traps
if the exnref is null** ([spec exec/instructions §control, throw_ref](https://webassembly.github.io/spec/core/exec/instructions.html)).
It lowers like `throw`/`return` — pop one value, build the node, consume the dead tail:

```gleam
ast.ThrowRef -> {
  use #(exnref, _stack1) <- result.try(pop1(st.stack))
  use #(marker, rest) <- result.try(consume_dead(tail, 0))
  Ok(end_or_else(marker, ir.ThrowRef(exnref), rest, st.counter))
}
```

lower forwards the exnref `Value` unchanged; the **null-exnref trap**, the re-raise, and the exnref
term inspection are rt_exn's (P7-07). The `TrapReason` for a null re-throw is *Open questions* #4 (reuse
`UninitializedElement`-style or add one) — lower never constructs it. `throw_ref` is the modern-proposal
analogue of legacy `rethrow` (§A.4); a legacy `rethrow l` reduces onto `ThrowRef(exnref_of_l)` (the
exnref captured by the labelled catch), so this node also serves the legacy path.

---

## F. The tag section → `Module.tags` + `ImportTag`/`ExportTag`

Module-level lowering mirrors globals/tables (a named module-level entity, imports++defined index
space):

```gleam
/// Lower the tag section to `TagDecl`s. Defined tag `j` is named at its ABSOLUTE tagidx
/// `imported_tag_count + j` (`tag<abs>`), carrying the exception's operand signature
/// (`ty.results == []` — a tag never yields; validate enforces). Byte-identical when there
/// is no tag section (`Module.tags = []`).
fn lower_tags(module, imported_tag_count) -> Result(List(ir.TagDecl), LowerError) {
  list.index_map(module.tags, fn(t, i) {
    use sig <- result.try(nth_err(module.types, t.type_idx, UnknownTypeIndex(t.type_idx)))
    Ok(ir.TagDecl(tagname(imported_tag_count + i), ir_functype(sig)))
  })
  |> result.all
}
```

- **Imported tags** — add an arm to `lower_imports`:
  `ast.ImportTag(_attr, tyidx) -> Ok(ir.ImportTag(imp.module, imp.name, ir_functype(module.types[tyidx])))`
  (the `attribute` byte is validated `0x00` by decode/validate; lower drops it — it carries no IR
  meaning beyond "exception tag").
- **Exported tags** — add an arm to the exports map in `lower/1`:
  `ast.ExportTag -> ir.ExportTag(e.name, tagname(e.index))`.
- Thread the new declarations into the `ir.Module` constructor: `tags: lower_tags(module,
  typed.imported_tag_count)`. `imported_tag_count` is the count of `ImportTag` importdescs (a new
  `TypedModule` count analogous to `imported_func_count`/`imported_global_count` — a P7-04 seam,
  *Open questions* #1; lower can also derive it by counting `ast.ImportTag` in `module.imports`).

**Conformance-neutral:** no tag section ⇒ `Module.tags = []`, no `ImportTag`/`ExportTag`, no
`throw`/`try_table`/`throw_ref` node ⇒ the whole `ir.Module` is byte-identical to Phase-6.

---

## G. Effect / soundness / security note (J5 / D3a)

- **Every EH node is an effect barrier.** `Throw`/`TryTable`/`ThrowRef` transfer control and/or raise;
  they are classified `Effectful` in `ir/effect.gleam` (the keystone 01/02 reach, not lower's). lower's
  only obligation is program order: it builds `Throw`/`ThrowRef` as unconditional bottom transfers (dead
  tail consumed, like `Return`), and `TryTable`'s body is a straight-line walk (no reorder). A future
  optimizer must never CSE/reorder/DCE across an EH node. *(A `Simd`-style pure narrowing is NOT
  applicable — EH is control flow.)*
- **A thrown exception is a term, never authority (D3a/J5).** `throw`/`try_table`/`throw_ref` route
  through `rt_exn`/`rt_trap` (P7-07), never an ambient `apply` of an attacker-chosen `module:atom`. The
  tag term shape is **build-controlled** (`{wasm_exn, TagName, Payload}` with `TagName` the
  build-fixed `tag<idx>`, `Payload` the operand value list). lower emits a **named** tag reference
  (`tagname(x)`), never a data-derived dispatch — an auditor sees every throw/catch site names a
  build-fixed tag. The worst case of a lowering bug is a wrong tag name / wrong label caught by the
  differential oracle (P7-09/10), **never a host escape**.
- **`exnref` is opaque (J5).** A caught `exnref` is a forge-proof handle (rt_ref reuse, P7-07): Safe
  code can re-throw it (`throw_ref`) but cannot forge or inspect the underlying BEAM term. lower emits
  `ConstNull(ExnRef)` for `ref.null exn` and forwards a caught exnref `Value` unchanged; it exposes no
  unwrap.
- **EH does not weaken the sandbox (J5).** An uncaught WASM exception becomes a BEAM exception the
  instance boundary contains (one-instance-one-process); it cannot escape to other instances or the
  node. Metering/fuel still bites across a throw (rt_meter is orthogonal; the scheduler preempts a
  throwing loop at reduction boundaries — J7). lower changes none of this; it emits the neutral node.
- **Fail-closed, total.** An out-of-range tagidx ⇒ `Error(UnknownTagIndex(_))`; an out-of-range catch
  label ⇒ `Error(Malformed(_))`; an under-deep stack ⇒ `Error(StackUnderflow)` (all only reachable on
  an unvalidated module — validation is the boundary, these are insurance). A tag with a non-empty
  result signature is validate's to reject; lower's `ir_functype` carries whatever the AST holds (a
  defensive non-empty `results` never arises post-validation). **Never** `panic`/`let assert`.
- **Conformance-neutral by default (J6).** The obligation is *negative*: a module with no tag section
  and no EH instruction lowers to **byte-identical** IR. Enforced by the additive `go/3` arms (dead for
  a non-EH module), `Module.tags = []`, the dead `TExnRef`/`ExnRef` mapping arms, and no
  `ImportTag`/`ExportTag` produced.

---

## Verification — Definition of Done (D8)

Tests assert **spec behaviour / the spec's opcode meaning**, not whatever the code emits (no
change-detector tests). Fixtures are `wat.gleam`/`wat2wasm` programs (and, once P7-03 lands, real
Porffor `.wasm`) decoded+validated through P7-03/04, then lowered; cite the EH proposal / core-spec
section (and the measured Porffor form) in each test.

1. **Tag section (spec: tag section id 13).** A module declaring `(tag $e (param f64 i32))` ⇒
   `Module.tags = [TagDecl("tag0", FuncType([TF64, TI32], []))]` (assert the name, the operand types
   in order, and the **empty** result list — a tag never yields). A module importing a tag ⇒
   `ImportTag(mod, name, FuncType([...], []))` at the low tagidx; a module exporting one ⇒
   `ExportTag("e", "tag0")`. **A tag-free module ⇒ `Module.tags = []`, byte-identical.**
2. **`throw` (spec exec §control, throw).** `(tag $e (param i32)) … i32.const 7 (throw $e)` ⇒
   `Throw("tag0", [ConstI32(7)])` as an unconditional bottom transfer (the instructions after it in the
   block are consumed as dead code — assert no `Let` binds a `throw` result, mirroring `Return`). A
   `throw` of a **multi-operand** tag `(param i32 i64)` ⇒ `Throw("tag0", [a, b])` with the operands in
   **tag-param order** (deepest-first push order). A `throw` with no enclosing handler still lowers (its
   propagation is rt_exn's).
3. **`try_table` result + fall-through (spec exec §control, try_table).** `(try_table (result i32) …
   end)` with no catch that fires ⇒ `TryTable([TI32 ++ carried], body, [])` whose fall-through yields
   the blocktype result; assert the body is lowered under a fresh block-like frame and the node is
   **not** `Block`-wrapped when the body does not `br` to it (bare `TryTable`), and **is** wrapped
   (`Block(label, _, TryTable(..))`) when the body `br`s to the try_table's own label.
4. **Catch-clause label resolution (spec: catch labels resolved in the enclosing context).** A
   `(block $h (result i32) (try_table (catch $e $h) …) …)` ⇒ the `catch` clause resolves `$h` to the
   **enclosing block's** IR label (assert the resolved `Catch(Some("tag0"), "<h-label>", False)` names
   the block frame's label, i.e. resolution used the parent `st.frames`, NOT the try_table's own body
   label). Assert every clause kind maps exactly:
   - `catch $e $l` ⇒ `Catch(Some("tag<e>"), L, False)`
   - `catch_ref $e $l` ⇒ `Catch(Some("tag<e>"), L, True)`
   - `catch_all $l` ⇒ `Catch(None, L, False)`
   - `catch_all_ref $l` ⇒ `Catch(None, L, True)`
   and that the clause order is preserved (matching is first-match — spec).
5. **`throw_ref` + `exnref` (spec exec §control, throw_ref).** `(catch_ref $e $h)` delivering an
   `exnref` to `$h`, then `(throw_ref)` in `$h` ⇒ the exnref flows as a `Value` and `ThrowRef(exnref)`
   is an unconditional bottom transfer (dead tail consumed). `ref.null exn` ⇒ `ConstNull(ExnRef)` pushed
   like any null literal; a declared `exnref` local zero-inits to `ConstNull(ExnRef)`; a function param/
   result of type `exnref` ⇒ `TExnRef`.
6. **Bottom-ness / dead-code (spec: throw/throw_ref/unreachable are bottom).** After a `throw` (or
   `throw_ref`) the unreachable tail up to the frame's `end`/`else` is consumed (assert via a program
   with instructions after a `throw` inside a block — they must not appear in the lowered body), exactly
   as for `Return`/`Unreachable`.
7. **Conformance-neutral default (J6) — the negative obligation.** The entire Phase-1..6 acceptance
   corpus + previously-passing suite lowers to IR that is **byte-identical** to Phase-6 (a module with
   no tag section / no EH instruction). Prove via `.ir` round-trip equality (P7-02) or structural
   `ir.Module` equality against the Phase-6 golden. **This is the load-bearing test.**
8. **Fail-closed (no panic).** An out-of-range tagidx in `throw` ⇒ `Error(UnknownTagIndex(_))`; an
   out-of-range catch labelidx ⇒ `Error(Malformed(_))`; an under-deep stack at a `throw`/`throw_ref` ⇒
   `Error(StackUnderflow)`. **Never** `panic`/`let assert`.
9. **Measured Porffor shape (once P7-03 lands the legacy decode).** A real Porffor-compiled
   `trycatch.js` (`npx porffor wasm`) whose module carries `(tag (param f64 i32))`, `throw 0`, and the
   legacy `try/catch` ⇒ lowers to `Module.tags = [TagDecl("tag0", FuncType([TF64, TI32], []))]`, the
   throw sites → `Throw("tag0", [value, type_tag])`, and the try/catch → a `TryTable` with a
   `Catch(Some("tag0"), _, _)` clause (assert against the measured module, not a hand-written fixture —
   §A.4).
10. **End-to-end (proven at the capstone, P7-10):** a WASM module with a `(tag)`, `throw`, and
    `try_table`/`catch` runs spec-correctly through the full pipeline (uncaught `throw` → a BEAM
    exception the run-ABI surfaces; a `try_table` catches the matching tag, binds the payload, and
    re-raises a non-match; nested try/catch unwinds correctly) against the EH `.wast` where
    `wast2json`-able + an authored proof otherwise; and a Porffor JS `try/catch` produces Porffor's own
    result. lower is on that path; its output is the oracle's input.
11. `gleam format --check src test` clean; `gleam build` **zero warnings**; `gleam test` stays green
    with **no Phase-1..6 regression** (conformance `fail == 0`). Every new/changed public/private
    function carries a doc comment stating its contract (what/params/returns/failure modes — D8).

## What this unit leaves for others

- **P7-01 (keystone)** freezes the IR-EH nodes lower emits (`TExnRef`/`ExnRef`, `Module.tags`/
  `TagDecl`, `ImportTag`/`ExportTag`, `Throw`/`TryTable`/`ThrowRef`, `Catch`) and their effect
  classification (all barriers). It also owns the **BEAM-exception term shape** (`{wasm_exn, TagName,
  Payload}` or its final spelling) and the **SSA-locals-across-a-throw** decision (§D's hard seam).
  lower re-syncs on the exact field spelling; the instruction→IR mapping is fixed.
- **P7-02 (`.ir` textual)** round-trips every node lower emits: the tag section, `throw`/`try_table`/
  `throw_ref`, the catch-clause forms (tag-name / catch_all / `_ref` capture flag / resolved label),
  and the `exnref` valtype + null literal — and a legacy (tag-free) module prints byte-identically.
- **P7-03 (decode)** publishes `«WASM-AST-EH»` — the constructors §A matches (the tag section, the EH
  opcodes + catch-clause encoding, the `exn` heap type, tag import/export). **Decode owns the opcode
  bytes and the legacy-vs-modern wire question (§A.4).** lower matches constructors; the mapping is
  fixed either way.
- **P7-04 (validate)** is the security boundary upstream: it types the tag operands, checks `throw`'s
  operand match, the `try_table` result + each catch clause's tag/label/exnref typing, the tag's empty
  result, and the `exnref` stack discipline — **before** lower runs. It must carry **`tag_types`**
  (imports++defined) and **`imported_tag_count`** on the `TypedModule` (the P7-04 seam, *Open questions*
  #1). lower assumes a validated, in-scope module and keeps its `LowerError`s as fail-closed insurance.
- **P7-06 (emit_core)** consumes every EH node: it wraps a `TryTable` body in a Core Erlang `try …
  catch`, matches the tag term, binds the payload (+ exnref for a `_ref` clause), **re-raises a
  non-matching exception**, and builds the transfer to each catch's `label` (Break/Continue/Return +
  carried locals — §D's hard seam); it lowers `Throw`/`ThrowRef` to an `rt_exn` raise; it extends the
  D3a security test (grep-verifies no ambient `apply(Module, Fn, Args)` of a data-named atom at a
  throw/catch site — every tag is a build-fixed name). Constant-space loops + preemption survive a
  throw (native BEAM unwinding).
- **P7-07 (rt_exn)** (+ `rt_trap` extend) implements the tagged-exception runtime: `raise` a
  build-controlled tag term, match a tag in a catch, re-raise a non-match, `catch_all`, and the
  `exnref` forge-proof handle (reuse `rt_ref`), plus the null-`throw_ref` trap. lower emits the neutral
  node; rt_exn owns the term shape + the raise/catch primitives (the binding chokepoint).
- **P7-08 (Porffor shim) / P7-09 (JS harness)** decode a returned `(f64, i32)` and drive Porffor JS →
  2core → BEAM, checking a `try/catch` program's result differentially. lower's tag carries `[TF64,
  TI32]`; the ABI meaning is the harness's, not lower's (J6).

## Deviations from the overview / ABI findings

Every refinement below is argued so the critique + reconciliation can adjudicate; each is a **cross-unit
seam** the keystone (01) freezes.

1. **⚠ MEASURED: Porffor 0.61.13 emits the LEGACY EH proposal, not `try_table`** (the overview §2/J1,
   [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md), and the task brief all assert the modern
   `try_table`). Reproduction in §A.4: `wasm-tools` decodes `try`(`0x06`)/`catch`(`0x07`)/`catch_all`
   (`0x19`)/`delegate`(`0x18`) and **zero** `try_table`/`throw_ref`/`exnref` across a whole module; the
   tag section (id 13) + `throw` (`0x08`) ARE shared and present. The frozen IR surface
   (`TryTable`/`ThrowRef`/`exnref`) is the modern, more-general shape and is a correct neutral target
   for **both** wire proposals (legacy `try/catch` reduces onto the same `TryTable` — §A.4), so **lower
   is complete regardless of which P7-03 decodes.** The reconciliation should: (a) direct **P7-03** to
   decode the **legacy** opcodes (required to run real Porffor output) — and additionally `try_table`
   for the modern EH `.wast` corpus; (b) consider whether `ir.Catch` should carry an **inline handler
   body** (`Expr`) rather than a branch label, since the legacy inline-handler shape is a *cleaner* fit
   for 2core's structured IR and avoids §D's carried-locals-across-a-branch seam (see #3). This doc
   writes the modern label-branch mapping as J2 froze it; the legacy reduction is in §A.4. **Seam:
   01/03/06 + the planner.**
2. **`tag`/`throw` reference tags by NAME (`"tag<absidx>"`), not by an `Int` slot** (like `CallImport`'s
   `slot`). Tags are declared module entities with an imports++defined index space, exactly like
   globals/tables/functions, which 2core references by stable name (`g<idx>`/`t<idx>`/`f<idx>`). A name
   is more D6-idiomatic, makes the build-controlled tag identity legible in the `.ir` (P7-02 prints
   `throw tag0`), and lets emit_core build `{wasm_exn, tag0, Payload}` with a build-fixed name (J5).
   **Fallback:** if the keystone prefers an `Int` tagidx (matching `CallImport`), lower's arms change
   trivially (`ir.Throw(x, args)` / `ir.Catch(Some(x), …)`); the mapping is fixed. Seam: 01/06/07.
3. **`ir.Catch` may need a target-transfer field for non-block catch targets.** J2's sketch
   (`(tag | catch_all, label, ref?)`) suffices for a catch that targets a forward **block** label
   (Porffor + the primary `.wast` — a `Break`). But a catch may legally target a **loop** (a `Continue`
   with the payload as loop inputs) or the **function frame** (a `Return` of the payload). A bare
   `label: String` loses the frame KIND emit_core needs to pick Break/Continue/Return. Recommend the
   keystone either enrich `Catch` with a small transfer descriptor (mirroring `build_transfer`'s
   Break/Continue/Return choice) **or** — better, per #1 — carry an inline handler body so no cross-frame
   transfer is needed. Deferring loop/function catch targets (option (c) in §D) is acceptable for the
   Porffor goal but not full `try_table.wast` conformance. Seam: 01/06.
4. **`throw_ref` of a null exnref traps — at most ONE new `TrapReason`.** The spec traps a `throw_ref`
   whose exnref is null. The keystone adds one `TrapReason` (spelling TBD — e.g. `NullException`, or
   reuse the "uninitialized" family) OR routes it as a distinct rt_exn error. lower never constructs a
   `TrapReason` (it emits `ThrowRef`; the null check is rt_exn's), so this does not touch lower's arms.
   Seam: 01/07.
5. **`Module.tags` carries DEFINED tags only; `imported_tag_count` is a new `TypedModule` fact.**
   Mirrors `imported_func_count`/`imported_global_count`. lower can derive it by counting
   `ast.ImportTag` in `module.imports`, but validate carrying it is cleaner (single source of truth) and
   matches the other index spaces. Seam: 04 (carry it), 05 (use it).

## Open questions (for the planner / cross-unit reconciliation)

1. **`tag_types` + `imported_tag_count` on the `TypedModule` (P7-04 seam).** lower needs the tag
   signatures (imports++defined) to recover a `throw`'s operand count and the imported-tag offset for
   naming. Recommend validate carries both (like `func_types`/`imported_func_count`). Confirm P7-04
   owns them.
2. **Legacy vs modern AST shape (P7-03 seam — Deviation #1).** Confirm P7-03 decodes the **legacy**
   opcodes (Porffor's real output) and whether it also decodes `try_table` for the EH `.wast`. lower
   maps either; confirm which the byte-identical golden targets.
3. **`ir.Catch` shape (keystone seam — Deviation #3).** Confirm the frozen `Catch` shape: a bare branch
   label (block-target only, Phase-7-Porffor scope), a transfer-kind-enriched label (full try_table
   conformance), or an inline handler body (the legacy-Porffor-friendly shape). lower's resolution
   (label + tag + capture flag) is unchanged under all three; the field spelling differs.
4. **The SSA-locals-across-a-throw resolution (keystone/emit_core seam — §D).** Confirm which of
   options (a) reify locals into a cell for EH functions, (b) inline handler bodies, or (c) restrict
   catch targets 01/06 picks. lower's mapping is invariant to the choice; flag it so the golden and the
   `.wast` proofs target the right semantics.
5. **`exnref` reuses the `rt_ref` forge-proof model (07 seam — overview §3 (b)).** Recommend yes:
   `exnref` is an opaque reference-layer handle exactly like `externref`, so `rt_ref`'s wrapped-term
   model gives forge-proofness for free. Confirm P7-07 owns the representation; `to_ir_reftype`/
   `zero_value`/`ConstNull(ExnRef)` in lower assume it.
