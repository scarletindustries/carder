# Phase 10 · Unit 06 — Range-based bounds-check elimination via loop versioning

> **One owner · Wave C (the BCE chain's tail) · the phase's hardest correctness unit.** Read
> [`00-overview.md`](00-overview.md) (N4 loop-versioning, N6 conformance-neutral, N7 termination,
> N8 honest scope), [`01-keystone.md`](01-keystone.md) (the unchecked nodes
> `MemLoadUnchecked`/`MemStoreUnchecked`; `loop_analysis.is_loop_invariant`/`free_vars`/
> `bound_names`), and the Phase-9 keystone [`../phase-9/01-mem-ssa-keystone.md`](../phase-9/01-mem-ssa-keystone.md)
> (`Footprint`, `byte_width`) first. This unit ships `middle/ir_opt/bce.gleam` — the pass that
> recognizes an **affine-access loop**, synthesizes a **pure runtime range-guard**, and emits a
> **versioned loop** (`if range_ok { fast, unchecked } else { slow, checked }`). It is **NOT wired
> into the pipeline** (unit 07 does that), so the whole Phase-1…9 corpus is **byte-identical** after
> this unit. A wrong range proof — or a guard that itself wraps or traps — is silent memory
> corruption, so the recognition predicate is deliberately narrow, the guard arithmetic is
> non-wrapping, and every claim below is argued, not asserted.

---

## Context

Phase 9's `mem_forward`/`mem_dse` removed *whole redundant accesses* per straight-line region; they
never touched the **per-iteration bounds check** that every surviving `MemLoad`/`MemStore` still
pays. A WASM memory access is **trap-or-access** (spec §4.4.7: `t.load`/`t.store` compute
`ea = i + memarg.offset`, and **if `ea + N/8 > |mem.data|` then trap** `MemoryOutOfBounds`), so the
check cannot simply be dropped: a loop with side effects before an out-of-bounds iteration must
still trap **at that iteration** with those effects applied. N4 resolves this with **loop
versioning** — a runtime guard proves the *whole* access range in-bounds and picks an unchecked
fast loop, else runs the original checked loop — so both **values and traps** are preserved exactly.
This is the classic loop-versioning / bounds-check-hoisting technique (Bik & Gannon; the HotSpot /
V8 "range check elimination by loop versioning" transform), specialized to the single-affine-access
shape a compiler frontend emits.

BCE is the one Phase-10 pass that *produces* the additive unchecked IR nodes (unit 01) and relies on
the unchecked runtime (unit 04) + `emit_core` lowering (unit 05). It stays **trust-neutral** and
runs at **Baseline** (all tiers, both modes) because versioning preserves traps exactly — there is
no trust assumption to make.

---

## Deliverables & the freeze it consumes

**Consume (frozen upstream):**

- `ir.gleam` — `Loop(label, params, result, body)`, `LoopParam(name, ty, init)`,
  `Continue(label, values)`, `Break(label, values)`, `If(cond, result, then, else)`,
  `Num(op, args)` (`IAdd`/`IMul`/`IShl`/`ISub`/`ILtU`/`IGeU`/`ILeU`/`IAnd` …),
  `MemLoad(mem, op, addr, offset, result)`, `MemStore(mem, op, addr, value, offset)`,
  `MemSize(mem)` (the page count, an i32), `Convert(I64ExtendI32U, …)`, and the additive
  `MemLoadUnchecked(mem, op, addr, offset, result)` / `MemStoreUnchecked(mem, op, addr, value,
  offset)` (unit 01, N6 — **produced only here**).
- `middle/ir_opt/loop_analysis.gleam` (unit 01) — `free_vars/1`, `value_vars/1`,
  `is_loop_invariant(e, bound_in_loop)`, `bound_names(loop_params, body)`.
- `middle/ir_opt/mem_ssa.gleam` (Phase-9 keystone) — `Footprint`, `byte_width(t)`, `count_mem_ops`.
- `middle/ir_opt/pass.gleam` — `Pass`, `pass`, `per_function`, `run_pipeline`.
- unit 04's `rt_mem`/`rt_mem_atomics` unchecked entry points + unit 05's `emit_core` lowering of the
  unchecked nodes (paged/atomics → check-free; nif → checked fallback, a sound no-op).

**Produce (`«BCE»`, single-owner):**

- `src/twocore/middle/ir_opt/bce.gleam` (**NEW**, owned) — the pass. Exports one public constructor:

  ```gleam
  /// The range-based bounds-check-elimination pass (Phase-10 N4). A whole-module `per_function`
  /// pass: for each function it walks the body and rewrites every ELIGIBLE affine-access `Loop`
  /// (§Recognition) into a versioned loop `Let([g], <pure range guard>, If(Var(g), result,
  /// <fast: recognized accesses → unchecked>, <slow: original, unchanged>))` (§Versioning). A loop
  /// that is not eligible — non-affine, non-monotone, `grow`/call in the body, or already versioned
  /// (idempotence, §Termination) — is left byte-identical. Semantics-preserving in BOTH values and
  /// traps (N4/N6). Total — never fails, never panics.
  ///
  /// - Return: the `Pass` value unit 07 appends to `Baseline` (inherited by `Aggressive`). Until
  ///   unit 07 wires it, the corpus is byte-identical (this unit only ADDS a module + tests).
  pub fn bce_pass() -> pass.Pass
  ```

- `test/twocore/optimize/bce_test.gleam` (**NEW**) — the transform + adversarial "must-NOT" fixtures
  + end-to-end BEAM value/trap-preservation (§Verification).

**No pipeline edit.** `ir_opt.pipeline/1` is untouched; the corpus is **byte-identical** after this
unit (N6). Unit 07 registers `bce_pass()` and proves the corpus differential.

---

## Recognition — the eligible affine-access loop predicate

A `Loop(l, params, result, body)` is **eligible** iff **all** of the following hold. Any failure
leaves the loop **checked and unchanged** (sound, just not accelerated — the honest ceiling, N8).
The predicate is deliberately narrow; each clause below is a *necessary* premise of the soundness
proof, so widening it later must re-discharge that proof.

### R1 — exactly one monotone induction variable `i`

There is exactly one `LoopParam(i, TI32, init)` such that:

- **init is a valid start.** `init` is `ConstI32(0)` **or** a loop-invariant `Value` (its name is
  not in `bound_names(params, body)`). Its unsigned value is `i₀ ≥ 0` (every i32 is non-negative as
  an address) — this is all the low end needs (R5).
- **positive constant step on every back-edge.** *Every* `Continue(l, vals)` reachable in `body`
  passes, in `i`'s positional slot, a value bound to `Num(IAdd(W32), [Var(i), ConstI32(step)])`
  with the **same** `step > 0`. (In ANF the increment is a `Let([t], Num(IAdd(W32), [Var(i),
  ConstI32(step)]), …)` and the `Continue` passes `Var(t)`; recognition resolves `t` back to the
  `IAdd`.) So across iterations `i` is **strictly increasing** and never reset to an out-of-range
  value: `i₀ ≤ i` always. `step` need not be a constant for the *range* bound (R4 uses `n−1`, not
  `step`), but a positive-constant step is the clean, checkable witness that `i` is a genuine
  monotone IV; a decrementing, zero, variable, or absent step ⇒ **not eligible** (adversarial fixture).

No `Continue(l, …)` may rebind `i` to anything else, and `i` occurs in no other binder (names are
unique per function — D6 — so there is no shadowing to worry about).

### R2 — a loop-invariant trip bound `n` dominating the accesses

`body` begins with the exit test `Let([d], Num(IGeU(W32), [Var(i), n]), If(Var(d), _, Break(l, _),
rest))` — "`if i >=u n: break`" — where `n` is a loop-invariant `Value`
(`is_loop_invariant(Values([n]), bound_names(params, body)) == True`). The equivalent guard-shapes
`ILtU(i, n)` used as a *continue* condition (`if i <u n: rest else break`) are accepted and
normalized to the same fact. The point is structural: **the exit test dominates every access in
`rest`**, so every access executes only when `i <u n`, hence at every executed access `i ≤ n − 1`.
(`>=u`/`<u` are the unsigned WASM compares — `i` and `n` are addresses.) If the exit test is not the
dominating head of the body, or `n` is loop-variant ⇒ **not eligible**.

### R3 — the memory accesses are affine in `i` (the recognized forms — v1)

Build an **affine environment** by scanning `body`'s `Let`-chain: a bound name `a` maps to a
descriptor `Affine(base, coeff)` (an address that equals, as a mathematical function of the current
value of `i`, `base + coeff·i`, with `base` a loop-invariant `Value` — `None` meaning `0` — and
`coeff` a positive compile-time constant) when its `rhs` is one of:

| `rhs` of `Let([a], rhs, …)` | descriptor `Affine(base, coeff)` |
|---|---|
| `Values([Var(i)])` (or `a` used directly as `Var(i)`) | `Affine(None, 1)` — the **direct byte cursor** |
| `Num(IMul(W32), [Var(i), ConstI32(c)])` / `[ConstI32(c), Var(i)]`, `1 ≤ c ≤ 2³¹` | `Affine(None, c)` — **scaled index** |
| `Num(IShl(W32), [Var(i), ConstI32(k)])`, `2ᵏ ≤ 2³¹` | `Affine(None, 2ᵏ)` — shift-scaled index |
| `Num(IAdd(W32), [X, Y])` where one operand resolves to `Affine(None, coeff)` and the other is a loop-invariant `Value` `b` | `Affine(Some(b), coeff)` — **based + scaled** |

A **recognized affine access** is a `MemLoad(mem, op, Var(a), off, _)` or `MemStore(mem, op, Var(a),
_, off)` whose `Var(a)` resolves to `Affine(base, coeff)` in the environment — equivalently, a
`MemLoad`/`MemStore` whose `addr` is `Var(i)` directly (the direct form, `Affine(None, 1)`). The
recognized effective-address model is

```
a(i)  =  base + coeff·i        (base ∈ {0, an invariant Value}, coeff a positive constant ≤ 2³¹)
ea(i) =  a(i) + off            (the byte offset the access starts at; off = op's static memarg offset)
range touched = [ea(i), ea(i) + bytes)      (bytes = op.bytes, the access width)
```

**Why these two forms and no more (v1).** They are exactly what a frontend emits for a dense array
scan (`mem[base + width·i]`) or a byte cursor (`mem[i]`), and they keep `coeff` a *small compile-time
constant* — the property the guard's non-wrapping proof (§Guard, overflow corner) rests on.
`coeff ≤ 2³¹` bounds `coeff·(n−1) < 2³¹·2³² = 2⁶³`, leaving head-room for `base + off + bytes < 2³⁴`
so the whole guard value stays `< 2⁶⁴` (exact in W64 — proved in §Guard). Any address the environment
does **not** resolve to this shape — a non-affine index, two induction variables, a runtime-computed
stride, a `coeff > 2³¹`, or an `IAdd` with *two* variant operands — makes that access
**non-recognized**; it stays a checked `MemLoad`/`MemStore` (see R6).

### R4 — at least one recognized access, all covered by the range model

`body` contains ≥ 1 recognized affine access (R3). Each recognized access `A` contributes a
`(mem_A, base_A, coeff_A, off_A, bytes_A)` tuple; the guard (§Guard) is the conjunction of one
range check per recognized access. Accesses may target different `mem` (multi-memory): each is
checked against its own memory's byte length.

### R5 — the low end is trivially in bounds

`ea(i) = base + coeff·i + off ≥ 0` for every executed `i`, because `base ≥ 0` (an unsigned i32 or
`0`), `coeff > 0`, `i ≥ i₀ ≥ 0`, `off ≥ 0` (a memarg offset is unsigned). So **only the high end
needs a runtime check** (§Guard) — the min effective address is unconditionally `≥ 0` (N4).

### R6 — no `MemGrow` and no call anywhere in `body` (memory size is stable)

Scan `body` (a direct structural walk `contains_grow_or_call/1`): if it contains any `MemGrow`, or
any call — `CallDirect`/`CallIndirect`/`CallHost`/`CallImport`/`CallClosure` — the loop is **not
eligible**. Rationale: the guard reads `MemSize` **once** (before the loop); the fast loop's
unchecked accesses are safe every iteration only if the byte length the guard proved against is the
byte length in force at each access. A `MemGrow` or a call (which may grow memory or resize it
transitively) would invalidate that. Bulk-memory ops (`MemFill`/`MemCopy`/`MemInit`) and ordinary
`MemStore`/`MemLoad` are **allowed** — they write/read bytes but never resize memory, so
`MemSize` is unchanged; `mem_clobber.may_write_memory` is therefore **too coarse** to use as the
gate (the loop legitimately writes memory via its own stores) — use the targeted grow/call scan.

### R7 — not already versioned (idempotence)

The loop is eligible only if it is **neither**:

- **(R7a)** a loop whose `body` already contains a `MemLoadUnchecked`/`MemStoreUnchecked` — it is
  already a fast arm; **nor**
- **(R7b)** a `Loop` arm of an `If(Var(_), _, then, else)` whose **other** arm is a `Loop` whose body
  contains an unchecked access — it is the *slow* twin of an existing versioning.

(R7a) excludes the fast arm from re-versioning; (R7b) excludes the *slow* arm (which is pristine and
checked, so (R7a) alone would let it be versioned again, nesting a version inside a version).
Together they make the pass a **fixpoint**: re-running it rewrites nothing (§Termination). Nested
loops *inside* either arm are still eligible (they are not direct arms of the versioning `If`).

---

## The guard — a pure, non-wrapping range check

For each recognized access `A = (mem_A, base_A, coeff_A, off_A, bytes_A)`, the maximum effective
byte the loop can touch is bounded (using `i ≤ n − 1` from R2 and `coeff_A > 0` from R1/R3) by

```
maxEA(A)  =  base_A + coeff_A·(n − 1) + off_A + bytes_A          (conservative for step ≥ 1, i₀ ≥ 0)
```

and the memory's byte length is `byteLen(mem_A) = MemSize(mem_A) · 65536` (the WASM page is 65536 B).
The per-access guard is `maxEA(A) ≤ byteLen(mem_A)`; the whole guard is the **conjunction** over all
recognized accesses:

```
range_ok  =  ⋀_A  ( maxEA(A) ≤u byteLen(mem_A) )
```

This mirrors the runtime check exactly: `rt_mem.load`/`store` trap iff `ea + bytes > byteLen`, so
`maxEA(A) ≤ byteLen` is precisely "the highest access `A` performs would not trap."

### Constructed as IR (Num nodes over loop-invariant values + `MemSize`)

The guard is built entirely from **W64** arithmetic so it **does not wrap** in the range that
matters (see the overflow corner). i32 operands are zero-extended with `Convert(I64ExtendI32U, …)`;
constants (`coeff`, `off`, `bytes`, `65536`) are emitted as `ConstI64`. Writing `ext(x)` for
`Convert(I64ExtendI32U, x)`:

```
Let(["pg"],    MemSize(mem_A),                                     // i32 page count (a pure read)
Let(["blen"],  Num(IMul(W64), [ext(Var("pg")), ConstI64(65536)]), // i64 byte length ≤ 2³²
Let(["n64"],   ext(n),                                             // i64 trip bound
Let(["nm1"],   Num(ISub(W64), [Var("n64"), ConstI64(1)]),         // n − 1 (see n=0 corner)
Let(["scl"],   Num(IMul(W64), [ConstI64(coeff_A), Var("nm1")]),   // coeff·(n−1)
Let(["hi"],    Num(IAdd(W64), [ext(base_A), Var("scl")]),         // base + coeff·(n−1)   (base=0 ⟹ drop)
Let(["maxea"], Num(IAdd(W64), [Var("hi"), ConstI64(off_A + bytes_A)]),  // + off + bytes
Let(["gA"],    Num(ILeU(W64), [Var("maxea"), Var("blen")]),       // i32 truth value 0/1
  … )))))))))
```

`Num(ILeU(W64), …)` yields an **i32 truth value** (`0`/`1`) — exactly what `If.cond` wants. Multiple
per-access guards are AND-ed with `Num(IAnd(W32), [gA, gB])` (an `IAnd` of `0/1` values is logical
and). The final `Let(["g"], <conjunction>, If(Var("g"), result, fast, slow))` is the versioned loop.

For the **direct byte-cursor** form (`Affine(None, 1)`): `base = 0`, `coeff = 1`, so
`maxEA = (n − 1) + off + bytes` — the `ext(base)` and `IMul` collapse away.

### The guard is pure — it introduces no new observable

- **No trap.** Every node is total: `MemSize` never traps (it reads the page count); `I64ExtendI32U`,
  `IAdd`/`ISub`/`IMul(W64)`, `ILeU`, `IAnd` are non-trapping `Num`/`Convert` ops (only `IDiv*`/`IRem*`
  and the `TruncS/U` conversions trap — none appear). So evaluating the guard cannot raise.
- **No side effect.** `MemSize` is a *read* with no mutation; the rest is arithmetic on `Value`s. The
  guard writes no memory, no global, calls nothing.
- **No observable timing/size divergence.** Because R6 forbids grow/call, `MemSize` read once before
  the loop equals `MemSize` at every iteration, so hoisting the read into the guard observes the same
  value the loop body would have — it reveals nothing the program could not already compute.

Therefore the guard can be evaluated unconditionally without changing behaviour on **any** path,
including the zero-trip path (§Soundness).

### The overflow / range corner (the load-bearing subtlety — flag for review)

Two distinct wraps are in play; both are handled.

1. **The address operand wraps mod 2³² (WASM i32 arithmetic).** For the based/scaled form the
   runtime `addr` operand is `(base + coeff·i) mod 2³²` — the IR computes it with `Num(IAdd/IMul/IShl,
   W32)`, which wrap. The guard reasons about the *mathematical* `base + coeff·i`. **Claim:** when
   `range_ok` is TRUE, no wrap occurred, so the two coincide. **Proof:** `range_ok` TRUE ⇒
   `maxEA(A) ≤ byteLen(mem_A)`. A memory's byte length is `pages · 65536 ≤ 65536 · 65536 = 2³²`, so
   `byteLen ≤ 2³²`. Hence `base + coeff·(n−1) = maxEA − off − bytes ≤ 2³² − bytes < 2³²`. Because
   `base, coeff, off, i ≥ 0` and `i ≤ n − 1`, the address `base + coeff·i` is monotone
   non-decreasing in `i` and `≤ base + coeff·(n−1) < 2³²` for every executed `i` — so **the W32
   arithmetic never overflows**, and the runtime `addr` operand equals the mathematical value. ∎

2. **The guard's own W64 arithmetic must not wrap.** W64 `Num` ops wrap at 2⁶⁴. **Claim:** for every
   `n` that yields ≥ 1 iteration (`n > i₀ ≥ 0`, so `n ≥ 1`), all guard intermediates are `< 2⁶⁴`, so
   W64 is **exact (non-wrapping)**. **Proof:** `n ≥ 1` ⇒ `nm1 = n − 1 ≥ 0` (no `ISub` underflow);
   `coeff ≤ 2³¹` (R3) and `n − 1 < 2³²` ⇒ `coeff·(n−1) < 2⁶³`; `base < 2³²`, `off < 2³²`,
   `bytes ≤ 16` ⇒ `maxEA < 2⁶³ + 2³² + 2³² + 16 < 2⁶⁴`; `blen ≤ 2³² < 2⁶⁴`. Every intermediate is
   `< 2⁶⁴`. ∎ So for an *executing* loop the guard value is the true mathematical `maxEA`, and
   `range_ok` TRUE ⇒ `maxEA ≤ byteLen` ⇒ every recognized access in-bounds (combined with claim 1).

   For `n = 0` (the loop is zero-trip, since `i₀ ≥ 0 = n` ⇒ the exit test breaks immediately), the
   `ISub` underflows and the guard value is meaningless — **but it does not matter**: both arms run
   zero iterations and yield the loop's `init` values, so *whichever* arm `range_ok` selects the
   result is identical (§Soundness, zero-trip case). Correctness never depends on the guard's value
   when the loop does not execute.

**Soundness concern to double-check with the planner (explicit).** The proof of claim 2 rests on
`coeff ≤ 2³¹`. This is why R3 caps the recognized coefficient. The two safe generalizations, both
recommended for the planner to choose between if a larger stride is ever wanted: **(a)** lower the
guard through a *pure Erlang-bignum* runtime helper (e.g. a `rt_mem.range_ok/…` added in unit 04)
that does the arithmetic in arbitrary precision — removing the 2⁶⁴ corner entirely and letting
`coeff` be any i32; or **(b)** add an explicit W64-overflow test to the guard. v1 takes neither: it
caps `coeff ≤ 2³¹` (which excludes no realistic compiler-emitted stride) and proves exactness in
W64, keeping the guard a self-contained IR expression with no new runtime surface. If the planner
prefers the bignum helper now, R3's cap can be dropped.

---

## The versioning transform

For an eligible `Loop(l, params, result, body)` the pass emits

```
Let([g], <range_ok conjunction>,           // the pure guard (§Guard)
  If(Var(g), result,
     <FAST>,                               // clone of the loop, recognized accesses → unchecked
     <SLOW>))                              // the ORIGINAL loop, byte-identical
```

- **`<SLOW>`** is `Loop(l, params, result, body)` **unchanged** — the pristine checked loop. It
  still bounds-checks every access and traps at exactly the original iteration/point on OOB.
- **`<FAST>`** is `Loop(l, params, result, body')` where `body'` is `body` with **only the
  recognized affine accesses** (R3) rewritten:
  - `MemLoad(mem, op, Var(a), off, result)` → `MemLoadUnchecked(mem, op, Var(a), off, result)`
  - `MemStore(mem, op, Var(a), value, off)` → `MemStoreUnchecked(mem, op, Var(a), value, off)`

  Every **non-recognized** access in `body'` stays a checked `MemLoad`/`MemStore` (still traps
  correctly if it is somehow OOB). The rewrite is address-preserving: the unchecked node carries the
  **identical** `addr`/`offset`/`op`, so the fast loop computes byte-for-byte the same effective
  addresses as the slow loop.

The pass is a top-down rewrite `version(expr)`: at a `Loop` it tests eligibility (R1–R7); if
eligible it builds the `Let/If` above (recursing `version` into `body'` and `body` to version any
*nested* loops), and returns it as a finished subtree; if not eligible it recurses into the body.
Because R7b makes the produced slow arm non-re-eligible and R7a makes the fast arm non-re-eligible,
one pass versions each eligible loop once and a second pass changes nothing.

---

## Soundness (N4) — values and traps are preserved exactly

Fix an eligible loop and let the guard be `range_ok`. Write `S` for the set of induction values
actually reached, `S ⊆ [i₀, n)` with `i₀ ≥ 0`. There are three cases.

**Case A — `range_ok` is TRUE and the loop executes ≥ 1 iteration.** By §Guard claim 2 the guard
value is the true `maxEA`, and `range_ok` TRUE ⇒ for every recognized access `A` and every `i ∈ S`,
`ea_A(i) + bytes_A ≤ base_A + coeff_A·(n−1) + off_A + bytes_A = maxEA(A) ≤ byteLen(mem_A)`
(monotonicity + `i ≤ n−1`), and by claim 1 the runtime address equals this mathematical value. So
**every recognized access is in-bounds at every iteration.** Consequences:

- *Values.* An unchecked access at an in-bounds address reads/writes the identical bytes the checked
  access would (unit 04's differential pins `load_unchecked ≡ load` and `store_unchecked ≡ store`
  bit-for-bit on in-bounds addresses). Non-recognized accesses are untouched. So the fast loop
  computes the identical result values as the slow loop.
- *Traps.* The checked slow loop would **not** trap on any recognized access (all in-bounds), so
  dropping those checks removes no trap that would have fired. Any non-recognized access stays
  checked, so if *it* is OOB the fast loop traps at the identical iteration/point with the identical
  effects already applied (a recognized store earlier in that iteration wrote the same in-bounds
  bytes in both loops). `MemSize` is stable (R6), so the byte length the guard proved against is the
  byte length in force at every iteration.

Fast ≡ slow ≡ original. ✔

**Case B — `range_ok` is FALSE.** The `If` selects `<SLOW>`, the byte-identical original checked
loop. Identical values; identical trap (`MemoryOutOfBounds`) at the identical iteration and point;
identical effects up to that point. ✔ (This is the whole reason versioning, not check-hoisting, is
used: when the range is not provably safe, the program runs *exactly* as before — the trap is not
moved earlier.)

**Case C — the loop is zero-trip (`S = ∅`, i.e. `n ≤ i₀`).** No access executes in either arm; both
arms yield the loop's `init` values. Whichever arm `range_ok` selects (its value may be meaningless
here — §Guard n=0 corner), the observable result is the `init` tuple, identical to the original. ✔

**The guard adds no observable.** By §Guard it is pure and non-trapping, so inserting it on the path
to the loop changes nothing on any of A/B/C. The guard reads `MemSize` (a value the program could
already read) and never wraps in the deciding range (claims 1–2).

Because A/B/C are exhaustive and each preserves values **and** traps exactly, **loop versioning is
semantics-preserving** — trust-neutral, correct on every tier and both modes (on `nif`, unit 05
lowers the unchecked nodes to the *checked* path, so `<FAST>` ≡ `<SLOW>` there — a documented sound
no-op; the win is on paged/atomics, N5).

---

## Termination (N7)

BCE **adds** nodes (it clones the loop into a fast and a slow copy plus the guard `Let`/`If`), so it
is **not** in the size-reducing fixpoint set (`μ₉`). It stays well-founded by **idempotence**: R7a
excludes any loop whose body already contains an unchecked access (the fast arm), and R7b excludes
the pristine checked slow arm (its versioning-sibling contains unchecked accesses). So each eligible
loop is versioned **at most once, ever**; a second application of `bce_pass()` matches no eligible
loop and returns the module unchanged (`==`), which is the fixpoint driver's termination condition.
`count_mem_ops` still counts the unchecked nodes as memory ops (unit 01, §C), and cross-CF MemorySSA
/ Phase-9 passes only *remove* accesses, so appending BCE to the pipeline (unit 07) keeps the round
count bounded: BCE fires once per loop, the size-reducing passes converge as before, and no pass can
undo BCE (the unchecked nodes are never re-checked by any pass). The capstone re-verifies convergence
(no non-termination, no panic, no unbounded growth) over the corpus.

---

## Verification (Definition of Done — D8)

Tests assert **defined behaviour** and the **soundness invariant** (never change-detector bytes),
cite the spec, and use the loop-building + end-to-end BEAM recipe from
[`mem_forward_test.gleam`](../../test/twocore/optimize/mem_forward_test.gleam) and
[`mem_bench_test.gleam`](../../test/twocore/optimize/mem_bench_test.gleam) (build a one-function
`Loop` module, run `pass.run_pipeline(m, [bce.bce_pass()])`, and `emit_core` → `pipeline.core_to_beam`
→ `pipeline.exec_beam`). "Done" = the suite passes.

1. **(D8a) an eligible loop is versioned — inspect the IR.** Build `for i in 0..n: acc +=
   load(i·4)` (the affine kernel: `LoopParam(i, TI32, ConstI32(0))`, exit `if i >=u n break`, body
   `let t = i·4; let v = load(0, MemAccess(4,False), Var(t), 0, TI32); …; continue(l, [i+1, acc+v])`).
   Assert `bce_pass()` rewrites the loop to `Let([g], _guard, If(Var(g), _, fast, slow))` where:
   - the **fast** arm's load is `MemLoadUnchecked(0, MemAccess(4,False), Var("t"), 0, TI32)` (the
     recognized access is unchecked; assert via pattern-match / `count` of unchecked nodes = 1);
   - the **slow** arm is structurally the **original** `Loop` (a checked `MemLoad`, no unchecked node);
   - the guard binds a pure expression mentioning `MemSize(0)` and no call / store (assert it is a
     `Let`-chain of `Num`/`Convert`/`MemSize`, i.e. `contains_grow_or_call(guard) == False`).

2. **(D8b) end-to-end BEAM — value AND trap preservation.** Compile the *unoptimized* and *BCE*
   modules to real `.beam`. Seed a 1-page memory (65536 B) with known i32s.
   - **In-bounds run** (`n = 100`, all `i·4 + 4 ≤ 65536`): `exec_beam(…, "sum", [100], 1)` returns
     the **identical** `Returned([v])` from both builds (BCE took the fast arm; value-identical).
   - **Out-of-range run** (`n = 20000`, so `i·4 + 4 > 65536` from `i = 16384`): **both** builds
     return `Trapped(reason)` with `reason` containing `"out of bounds memory access"` (the
     `rt_trap` string for `MemoryOutOfBounds`) — the BCE build fell to the **slow** checked loop and
     trapped at the same observable point. Assert both, and assert the two builds' outcomes are equal
     for both `n`.

3. **(D8c) adversarial "must-NOT version" — left checked and unchanged.** Each of these loops is
   `optimize`d and asserted **byte-identical** to its input (no unchecked node produced,
   `count of MemLoadUnchecked/MemStoreUnchecked == 0`):
   - a loop containing a **`MemGrow`** in the body (R6);
   - a loop containing a **call** (`CallDirect`/`CallHost`) in the body (R6);
   - a **non-affine** address (`load(Var(x))` where `x` is not resolvable to `Affine`, e.g. `x`
     bound to `mem_load(...)` or a runtime product of two variables) (R3);
   - a **non-monotone / decrementing** IV (`Continue(l, [i−1, …])`, or a variable/zero step) (R1);
   - a **loop-variant bound** `n` (recomputed inside the loop) (R2).

4. **(D8d) idempotence.** `run_pipeline(m, [bce_pass()])` applied to an *already-versioned* module
   equals the module (no second version wrapped); running `bce_pass()` twice equals running it once
   (assert `once == twice`). Pins R7a+R7b — the slow arm is never re-versioned into a nested `If`.

5. **(D8e) green DoD + corpus byte-identical.** `gleam format --check src test` clean; `gleam build`
   **zero warnings** (every function total — no `todo`/`panic`/`let assert` on a live path); `gleam
   test` ≥ baseline + the new tests, 0 failures. Because the pass is **not wired into the pipeline**,
   the WASM corpus is **result-identical / byte-identical** under both profiles and every tier after
   this unit (N6) — this unit only adds a module + tests.

**Proof of goal:** a narrow, provably-sound recognizer (R1–R7); a pure, non-wrapping range guard
whose TRUE case provably in-bounds the whole access range (claims 1–2) and whose FALSE/zero-trip
cases run the original loop (cases B/C); values and traps preserved exactly on every tier and both
modes — so unit 07 can wire `bce_pass()` into `Baseline` and keep the corpus differential green
while the atomics affine-access loop drops its per-iteration bounds branch.

---

## What this unit leaves for others

- **Unit 07 (capstone)** appends `bce_pass()` to `ir_opt.pipeline`'s `Baseline` arm (inherited by
  `Aggressive`), proves the corpus + spec-suite differential (values + traps) under **both** profiles
  and **every** `(state_strategy × mem_tier)`, and reports BCE's deterministic per-iteration
  check-removal count + the atomics wall-clock win in `docs/phase-10-benchmark.md`.
- **Deferred (N8), stated not dropped:** non-affine / multi-dimensional / nested-IV BCE; a general
  (polyhedral) range solver; arbitrary runtime strides (the `coeff ≤ 2³¹` cap — see the planner flag
  in §Guard, resolvable with a pure bignum `rt_mem.range_ok` helper); and tier-`nif` unchecked native
  access (stays checked-fallback per N5).
