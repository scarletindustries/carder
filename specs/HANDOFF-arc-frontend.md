# Handoff — the 2core IR spec for the JavaScript frontend

> **Audience: the team writing the JS→2core-IR emitter** (reusing arc's parser + scope/capture
> analysis). This is the **complete, authoritative interface**: the value model, the calling
> convention, every IR node you emit, the compiled-code↔`rt_js` ABI, and how to lower each JS
> construct. You never touch `emit_core`/`build_beam` — you produce a `twocore/ir.Module` and hand it
> to the existing pipeline (`decode`-free direct-IR entry → `ir_lower` → `emit_core` → `build_beam` →
> BEAM). 2core team owns the IR + backend (the Phase-8 value layer, now shipped — see `specs/01-status.md` §3); **you own the emitter + `rt_js`**.

---

## 1. The pipeline & the division of labour

```
JS source ──arc.parser──▶ AST ──arc.scope.finalize──▶ scope-resolved AST + capture/box sets
          │                                                    │
          │                                    YOUR NEW CODE:  ▼
          │                                   emit_2core(ast, scope_tree) ──▶ twocore/ir.Module
          │                                                                        │
          └─ rt_js.gleam (YOUR JS runtime: coercion, prototypes, builtins, cells)  │
                              ▲ reached only via CallHost("js", op, args)          ▼
                                            2core (unchanged): ir_lower ─▶ emit_core ─▶ build_beam ─▶ BEAM
```

- **Reuse from arc, verbatim:** the parser (AST) and `scope.finalize` (slot allocation + which locals
  are captured / boxed). `scope.lookup` gives you a per-identifier `Resolution` — use it directly.
- **You write:** `emit_2core` (AST → IR, this doc) and **`rt_js`** (all JS *semantics* — the IR carries
  none). Register every `rt_js` op in the Phase-8 unit-05 fixed dispatch (D3a: no dynamic apply — adding
  an op = adding a `case` arm on the 2core side; coordinate a small allow-list PR).
- **2core guarantees:** the IR nodes below lower to idiomatic, preemptive, GC'd Core Erlang; the WASM
  surface is untouched; the numeric fast paths are bit-exact (D5).

---

## 2. The value model (ABI)

A **JS value is a BEAM term** (`TTerm` to the IR — opaque). Your `rt_js` picks the concrete encodings;
the IR only needs these to be *some* term. Recommended encodings (BEAM-native, fast):

| JS | BEAM term | IR support |
|---|---|---|
| number (finite) | a **native BEAM `float()`** (or `integer()` for a smi/bitwise) | `NumTerm` (native +/-/*/compare), `TermTest(IsNumber)` (guard) — **not** `Box/UnboxFloat` (see the number note below) |
| number `NaN`/`±Infinity` | frontend **sentinels** (can't be BEAM floats) | `rt_js` produces/handles them on the cold path |
| boolean | `'true'` / `'false'` atoms | `ConstAtom`, `TermTest(IsAtom)` |
| `undefined` / `null` | your sentinels (e.g. atoms `'undefined'`/`'null'`) | `ConstAtom` or `rt_js.undefined_sentinel()` |
| string | a **binary** | `ConstBinary`, `TermTest(IsBinary)` |
| object | an `rt_js` **cell holding a map** (mutable identity) | `MapOp`, closures capture the cell handle, `rt_js` cell ops |
| array | object with a fast dense representation your `rt_js` chooses | `MapOp` / `rt_js` |
| function | a **native BEAM `fun`** | `MakeClosure` / `CallClosure` |
| bignum | a BEAM `integer` (arbitrary precision — free) | `BoxInt(W64)` won't fit >64b; use `rt_js` for bigint ops |
| symbol | your encoding (e.g. a tagged tuple / unique ref) | `MakeTuple` / `rt_js` |

> **The number note (important — two different float layers).** 2core has *two* float representations:
> (1) the IR's unboxed `TF64` layer is a **raw IEEE-754 bit pattern in an integer** (WASM semantics,
> D5), bridged to/from a term losslessly by `Box/UnboxFloat` — use this only for **raw f64 storage**
> (e.g. a `Float64Array` element), never as a JS `number`, because a bit-pattern integer answers
> `is_float`→false and NaN/±Inf can't become BEAM floats; (2) a **JS `number` is a native BEAM
> `float()`** (finite) so `TermTest(IsNumber)` guards work and `NumTerm` does native BEAM arithmetic
> with no box/unbox. Represent NaN/±Infinity as your own sentinels and handle them on the `rt_js` cold
> path. Hot arithmetic: guard with `TermTest(IsNumber)`, fast-path with `NumTerm`, deopt to
> `CallHost("js",…)` for string-`+`/NaN/Inf/`/0`/mixed — see unit 06's composed proof.

### Calling convention (recommended, you may choose your own)
Compile every JS function to a same-module 2core `Function` of a **uniform shape**, e.g.
`f(This, Args)` where `This` is a `TTerm` and `Args` is a **cons list** of `TTerm`. Then:
- a JS **closure** = `MakeClosure("f", [captured…], arity=2)` → a `fun(This, Args)` that forwards to
  `f(captured…, This, Args)`. Captured cells (for mutated `let`s, per arc's `is_boxed`) are captured as
  **handle values**; captured immutable consts are captured directly.
- a JS **call** `g(a,b)` = evaluate `g` to a fun `TTerm`, build `Args = [a, b]` (`MakeCons`), then
  `CallClosure(g, [ThisVal, Args])`. `this`/spread/default/rest are your emitter's job (arc's scope
  already resolved arity/rest).

---

## 3. IR node reference (what you emit)

### Values (`ir.Value`)
`Var(name)` · `ConstI32/64`, `ConstF32/64` (unboxed numerics) · `ConstNull(reftype)` ·
**`ConstAtom(name)`** (Phase 8) · **`ConstBinary(bytes)`** (Phase 8). Everything a node "returns" is
bound with `Let(names, rhs, body)` and referenced as `Var`.

### Term layer (unit 01) — `Expr = TermOp(op, args)`
`MakeTuple`(v…)→tuple · `TupleGet(i)`(t)→elem (0-based) · `TupleSize`(t)→i32 · `MakeCons`(h,t)→`[h|t]` ·
`ListHead`(l) · `ListTail`(l) · `IsEmptyList`(l)→i32. Use for arg lists, iterables, and (with a tag)
internal records / shaped objects.

### Closures (unit 02) — `Expr`
`MakeClosure(fn_name, captures, arity)` → fun `TTerm`; `CallClosure(callee, args)` → result `TTerm`.
**This is your closures — Porffor's wall does not exist here.**

### Maps (unit 03) — `Expr = MapOp(op, args)`
`MapNew` · `MapGet`(m,k,default) · `MapPut`(m,k,v)→new map · `MapHas`(m,k)→i32 · `MapRemove`(m,k) ·
`MapSize`(m)→i32. **Immutable** — for a mutable JS object, keep the map inside an `rt_js` cell and
`cell_set(c, MapPut(cell_get(c), k, v))`.

### Boxing bridge (unit 04) — `Expr = Convert(op, arg)`
`BoxFloat/UnboxFloat`(raw f64 ↔ term, **bit-exact, lossless**) · `BoxInt/UnboxInt`(iN ↔ term). This
bridges the IR's **raw-bit-pattern** `TF64`/`TI32` layer ↔ terms — use for **raw f64/iN storage** (typed
arrays, wasm interop). **Not** the JS-`number` path (see the number note in §2).

### Term classification + native arithmetic (unit 06) — `Expr`
`TermTest(kind, arg)`→i32 for `IsInt/IsFloat/IsNumber/IsAtom/IsBinary/IsTuple/IsMap/IsFun/IsList` (guards);
`TermTag(arg)`→i32 dense code (`0=int 1=float 2=atom 3=binary 4=tuple 5=map 6=fun 7=list 8=other`) for a
one-shot `Switch`; **`NumTerm(op, lhs, rhs)`** — native BEAM arithmetic/compare on **number terms**
(`NAdd/NSub/NMul`→number term; `NLt/NLe/NGt/NGe/NEq`→i32). **This is your JS-arithmetic fast path**:
guard with `TermTest(IsNumber)`, compute with `NumTerm`, deopt to `rt_js` for `/`,`%`, NaN/Inf, string-`+`.

### Numeric raw layer (existing) — `Expr = Num(op, args)` / `Convert(op, arg)`
Width-tagged **raw-bit-pattern** arithmetic on `TI32/TI64/TF32/TF64` (`f64.add`, `i32.and`, …). This is
the WASM numeric layer (bit-exact wasm semantics) — use for wasm interop / raw f64/iN math, **not** JS
numbers (use `NumTerm`). Cross to/from terms via the unit-04 boxing bridge.

### Control (existing, structured — emit from arc's structured AST, **not** flat jumps)
`Let` (SSA bind) · `Block(label, result, body)` + `Break(label, vs)` · `Loop(label, params, result,
body)` + `Continue(label, vs)` · `If(cond_i32, result, then, else)` · `Switch(sel_i32, result, arms,
default)` · `Return(vs)`. Labeled `break`/`continue` → named `Block`/`Loop` + `Break`/`Continue` (1:1
with arc's `LoopContext`).

### Exceptions (existing) — for `throw`/`try`
JS `throw x` → the IR's `Throw`/`ThrowRef` carrying one `TTerm` payload; `try/catch` → the IR's `Try`
(lowers to BEAM `try/catch`). `finally` → re-express via the IR's try surface (BEAM `after`); preserve
abrupt-completion precedence (finally overrides return/break/throw) in your emitter.

### The runtime chokepoint (unit 05) — `Expr = CallHost("js", op, args)`
Every JS *semantic* that isn't one of the above: property get/set with prototypes, `+`/`ToPrimitive`,
`typeof`, `instanceof`, `new`, iterators, builtins (`console.log`, `Object`, `Array`, `Math`, …),
mutable **cells**, sentinels. One value out (tuple-pack for multiple). Fail-closed; every `op` must be
in the fixed dispatch.

---

## 4. The `rt_js` ABI (the runtime YOU provide)

`rt_js.gleam` (BEAM module) implements JS semantics, reached only via `CallHost("js", op, args)`. The
2core Phase-8 stub ships a few ops; you grow it. Register each in the unit-05 dispatch. Suggested core
surface (name → args → result), all on boxed `TTerm`s:

- **cells (mutable captures + object storage):** `cell_new(init)→cell` · `cell_get(cell)→v` ·
  `cell_set(cell, v)→undefined`.
- **objects:** `new_object()→obj` · `get_prop(obj, key)→v` (prototype walk) · `set_prop(obj, key, v)` ·
  `has_prop`, `delete_prop`, `get_elem`/`set_elem`.
- **operators (slow path behind your fast-path guards):** `add(a,b)` (string-or-number `+`), `sub`,
  `mul`, `div`, `mod`, `eq`/`strict_eq`, `lt`/`le`/`gt`/`ge`, `bitand`/`bitor`/… , `neg`, `not`, `to_boolean`,
  `to_number`, `to_string`, `type_of`, `instance_of`.
- **calls/construct:** `call(fn, this, args)` (when the callee may not be a raw fun), `construct(fn,
  args)`, `get_iterator`, `iter_next`.
- **sentinels/consts:** `undefined_sentinel()`, `null_sentinel()`.
- **builtins:** `console_log`, and the global object surface you support.

**Fast-path rule:** for arithmetic/compare, guard with `TermTest(IsNumber, …)` and use the unboxed
`Num` + `Box/Unbox` path when it holds; fall to `rt_js.<op>` only on the cold path (unit 06 shows the
exact IR).

---

## 5. Lowering cheat-sheet (JS construct → IR)

| JS | IR |
|---|---|
| `42` / `1.5` | `ConstF64(bits)` then `BoxFloat` (or keep unboxed on a fast path) |
| `"s"` | `ConstBinary(<<"s">>)` |
| `true`/`false`/`undefined`/`null` | `ConstAtom(...)` / sentinel |
| local read (arc `Resolution=Local`) | `Var` (unboxed if you tracked its type, else the boxed slot) |
| captured read (arc `Local(boxed)`) | capture the **cell**; `CallHost("js","cell_get",[cell])` |
| `x = e` (mutated capture) | `CallHost("js","cell_set",[cell, e])` |
| global read/write | `CallHost("js","global_get"/"global_set",…)` (or a module map) |
| `a + b` | `If(TermTest(IsNumber,a) && TermTest(IsNumber,b), NumTerm(NAdd,a,b), CallHost("js","add",[a,b]))` |
| `a < b`, `a === b` | guarded `NumTerm(NLt,…)`/`NumTerm(NEq,…)` (numbers) else `rt_js` |
| `a / b`, `a % b` | always `CallHost("js","div"/"mod",…)` (BEAM `/0` traps; JS `1/0=Infinity`) |
| `!x`, `x && y`, `x ? … : …` | `TermTest`/`rt_js.to_boolean` → `If`/`Switch` |
| `function f(){…}` / arrow | a same-module `Function(This, Args)`; the *value* is `MakeClosure("f", captures, 2)` |
| `g(a,b)` | `Args=MakeCons(a,MakeCons(b,[]))`; `CallClosure(g,[This,Args])` (or `rt_js.call` if `g` may be non-fun) |
| `o.m(a)` | eval `o`; `f=get_prop(o,"m")`; `CallClosure(f,[o,Args])` |
| `new C(a)` | `CallHost("js","construct",[C,Args])` |
| `o.x` / `o.x = v` | `CallHost("js","get_prop"/"set_prop",…)` (IC fast path v2: `TermTag`+shape guard + tuple slot) |
| `{a:1}` | `new_object()` then `set_prop`s (or a `MapPut` chain inside a fresh cell) |
| `[1,2]` | `rt_js` array-new + pushes (or your dense array repr) |
| `if`/`while`/`for` | `If` / `Loop`+`Break`/`Continue` (from arc's structured AST) |
| labeled `break l`/`continue l` | `Break("l", …)` / `Continue("l", …)` to the named `Block`/`Loop` |
| `return e` | `Return([e])` |
| `throw e` | `Throw`/`ThrowRef` carrying `e` |
| `try{}catch(x){}finally{}` | the IR `Try` surface → BEAM `try/catch/after`; preserve completion precedence |

---

## 6. Out of scope for v1 (know the cliffs)

- **Generators / async / async-generators.** arc gets suspend/resume free from its interpreter
  (`value.gleam` saves pc/stack); a run-to-completion Core-Erlang function **cannot freeze locals**.
  These need an explicit CPS/state-machine transform (per-function, gated on arc's `is_generator`/
  `is_async`) — a real compiler stage. **v1: reject them** (or run just those functions on the arc VM —
  a hybrid, since both share the value model). Don't block the sync subset on this.
- **Direct `eval`** (parses new source against live scope): reject in v1 (or per-function VM fallback).
- **`with`, exotic Annex-B, full `Proxy`/`Reflect` reflection:** `rt_js` territory, defer.

---

## 7. First thing to build — Milestone 0 (de-risk the perf premise)

Before the emitter, **hand-write the IR** for one hot numeric function (e.g. a summation loop) using the
unboxed `f64` fast path + a `MakeClosure` + one `CallHost("js",…)`, run it through the pipeline to BEAM,
and **benchmark against arc's interpreter** on the same input. The entire direction rests on
compiled-control-flow + unboxed-arith beating interpreter dispatch. If it does, build the emitter; the
reusable parser + scope analysis + these primitives make the sync subset tractable, and **closures —
Porffor's wall — are free**.
