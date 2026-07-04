# Phase 8 · Unit 06 — Term classification + native number arithmetic (guarded fast paths)

> Read [`00-overview.md`](00-overview.md) (K2) + units 01/04. Ships the two things a frontend needs to
> compile hot JS arithmetic to **native BEAM code**: (1) cheap `TTerm → i32` **type guards**, and (2)
> **native BEAM arithmetic on number terms**. Files: `ir.gleam`, `emit_core.gleam`, `effect.gleam`,
> `printer.gleam`, `parser.gleam`, `ir_lower.gleam`, `ir_opt/{aggressive,baseline,pass}.gleam`, tests.

## The corrected numeric model (read this — it supersedes HANDOFF §2's "number = a BEAM float" hedge)

Unit 04 established that 2core's **unboxed** `TF64` layer is a **raw bit pattern in an integer** (D5,
for WASM semantics), and `Box/UnboxFloat` losslessly bridge *that* layer ↔ a term. That layer is the
right tool for **raw f64s** (e.g. a `Float64Array` element), but it is **not** the right home for a JS
`number`, because (a) a bit-pattern integer answers `is_float` → false, breaking guards, and (b) you
can't turn NaN/±Inf bits into a BEAM `float()` anyway.

So the recommended JS-number representation (frontend's choice, but this is what unit 06 optimises for):
a **finite JS number = a native BEAM `float()`** (or a small BEAM `integer` for a smi, frontend's
call); **NaN / ±Infinity = frontend sentinels** (they can't be BEAM floats). Then hot arithmetic is
**native BEAM float/int ops** on those terms — no box/unbox dance, no `rt_js` round-trip — **guarded**
by a `TermTest(IsNumber)` and **deopting** to `rt_js` for the JS-specific cold cases (string `+`,
NaN/Inf production, `/0` → Infinity, mixed types). This unit ships both halves.

## IR delta

### 1. `TermTest(kind: TermKind, arg: Value)` → `TI32` (the guards)
```
pub type TermKind { IsInt IsFloat IsNumber IsAtom IsBinary IsTuple IsMap IsFun IsList }
```
Lower each to `case 'erlang':'is_*'(X) of 'true'->1; 'false'->0 end` (an i32 truth value → `If`/`Switch`):
`IsInt`→is_integer, `IsFloat`→is_float, `IsNumber`→is_number, `IsAtom`→is_atom, `IsBinary`→is_binary,
`IsTuple`→is_tuple, `IsMap`→is_map, `IsFun`→is_function, `IsList`→is_list. **`Pure`** (K8).

### 2. `TermTag(arg: Value)` → `TI32` (dense classification, for one-shot `Switch`)
One `case`/`if` chain over the `is_*` tests returning a fixed code: `0=int 1=float 2=atom 3=binary
4=tuple 5=map 6=fun 7=list 8=other` (**document this encoding in the handoff**). **`Pure`**.

### 3. `NumTerm(op: NumTermOp, lhs: Value, rhs: Value)` — native BEAM number arithmetic
```
pub type NumTermOp { NAdd NSub NMul  NLt NLe NGt NGe NEq }
```
Operates on two **number terms** (BEAM `float()`/`integer()`), lowering to native BEAM ops:
- `NAdd/NSub/NMul` → `call 'erlang':'+'/'-'/'*'(A, B)` → a **number term** (`TTerm`). BEAM's mixed
  int/float arithmetic + bignums Just Work for the common case; the frontend guards args are numbers
  and deopts for JS edge cases (Inf/NaN production, string `+`).
- `NLt/NLe/NGt/NGe/NEq` → `case A </=</>/>=/=:= B of 'true'->1; 'false'->0 end` → **`TI32`** (drops into
  `If`). (`NEq` is BEAM `=:=` on numbers; JS `===`/`==` full semantics stay in `rt_js` — this is the
  *guarded numeric* compare only.)
- **Division/remainder are intentionally OMITTED** (`erlang:'/'` raises `badarith` on `/0`, but JS
  `1/0 = Infinity`) — the frontend routes `/`/`%` through `rt_js` (or a later guarded-div unit).

**Effect (K8):** classify `NumTerm` **like the existing trapping `Num` ops** — it can raise `badarith`
on non-number args (the frontend guards, but the IR can't prove it), so it is **not** freely `Pure`.
Match whatever classification the trapping `Num(idiv/irem)` variants use (non-barrier but effectful /
can-trap). Default to effectful if unsure — correctness first.

## Exhaustiveness

`TermTest`, `TermTag`, `NumTerm` are new `Expr` variants → the 8 sites unit 02 named (emit_core `emit`
+ `collect_expr`, `effect.is_effectful_node`, `printer.print_expr`, `parser.parse_expr`,
`ir_lower.lower_expr`, `ir_opt/{aggressive,baseline,pass}`). Grep an existing Phase-8 node
(`MakeClosure(`/`MapOp(`) for every arm's shape. WASM never produces them (K7).

## The composed fast-path proof (the acceptance — this is the whole point of Phase 8)

Author the frontend's guarded `a + b` **in IR** and test it end-to-end:
```
If( TermTest(IsNumber, a)  &&  TermTest(IsNumber, b),      // guard (i32; combine two If/Switch or nest)
    NumTerm(NAdd, a, b),                                    // FAST: native BEAM add on number terms
    CallHost("js", "add", [a, b]) )                         // SLOW: rt_js (unit 05 stub)
```
Assert `1.5 + 2.5` (two BEAM floats) → `4.0` via the **fast** path (native, no rt_js), and a non-number
argument takes the **slow** path and still returns the stub's result. This demonstrates Phase 8's
thesis: **hot arithmetic compiled to native BEAM, dynamic only on the cold path.**

## Tests (spec-first)

- Each `TermTest(kind,…)` returns `1` for a matching term, `0` otherwise (cover int/float/atom/binary/
  tuple/map/fun/list — use the unit-01 term constructors + unit-02 closures + unit-03 maps to build
  representatives).
- `TermTag` returns the documented code per type.
- `NumTerm`: `NAdd`/`NSub`/`NMul` on `2` and `3` → `5`/`-1`/`6`; on `1.5`,`2.5` → `4.0`; the comparisons
  return correct `0/1`. (Mixed `2` + `2.5` → `4.5` — BEAM promotes.)
- The composed guarded `a+b` fast/slow proof above.
- Conformance-neutral: WASM byte-identical.

## Definition of Done

Suite green (≥1716, 0 failures — unit 05 lands first), format/build clean, WASM byte-identical, D3a
untouched. Commit `phase-8/06: term classification + native number arithmetic` and push.
