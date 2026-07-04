# Phase 10 · Unit 05 — `emit_core` unchecked-access lowering (flip the freeze to the fast seam)

> **One owner · the BCE runtime chain (04 → 05 → 06) · depends on the freeze (01) + the runtime
> bodies (04).** Read [`00-overview.md`](00-overview.md) (**N4** loop-versioning soundness, **N5**
> unchecked entry points are BEAM-safe on paged/atomics + nif falls back to checked) and
> [`01-keystone.md`](01-keystone.md) (**§C** — at the freeze the unchecked IR nodes lower *exactly
> like the checked nodes*) first, then the analogous Phase-4 emit unit
> [`../phase-4/02-emit-threaded-seam.md`](../phase-4/02-emit-threaded-seam.md) (the seam-expansion
> discipline, G5/D3a). This unit **flips** the keystone's checked-path lowering of
> `MemLoadUnchecked`/`MemStoreUnchecked` to the genuine **unchecked** entry points (unit 04) on the
> tiers that ship them, and keeps the **checked** path everywhere the unchecked one is absent. It is
> a pure `emit_core` change: no IR node, no new runtime, no pipeline registration.

---

## Context

The keystone (unit 01, §C) landed the additive `MemLoadUnchecked`/`MemStoreUnchecked` `Expr`
variants **freeze-safe**: `ir/printer`+`parser` round-trip them, `ir/effect` classifies them as
barriers, `mem_ssa` gives them a footprint and counts them, and — the line this unit rewrites —
`emit_core` lowers them **exactly like the checked nodes**, routing `MemLoadUnchecked` to
`emit_mem_load` and `MemStoreUnchecked` to `emit_mem_store` (the trapping `load`/`store` seam). That
made the freeze sound *before* any runtime honoured "unchecked": a stray unchecked node still traps
on OOB, so nothing is unsafe until a proven guard produces one. Unit 04 then shipped the real
check-free bodies — `rt_mem`/`rt_mem_atomics` gained `load_unchecked`/`store_unchecked` and the
threaded twins `t_load_unchecked`/`t_store_unchecked` — which return a **bare value** (an `Int` / a
`Nil` / an `InstanceState` record), **not** a trapping `Result`, and which are **BEAM-safe even on
an OOB** (paged slices an immutable binary; atomics indexes an `atomics` array — a caught error → a
trap, never corruption). This unit cashes that: it points the two unchecked-node arms at the
unchecked seam so that, once unit 06 emits an unchecked node inside a range-guarded fast loop, the
per-iteration `MemoryOutOfBounds` compare is actually gone.

Two facts from `emit_core` today anchor the change (both `mem == 0` heads shown; the `_at`
multi-memory heads and the threaded twins parallel them):

- **`emit_mem_load`** (`emit_core.gleam:1547`) builds the operand tail
  `[bytes, signed, W(result), addr, offset]` and lowers to
  `seam_call(ctx.binding.mem_module, "load"/"t_load", …)`, then routes the result **through
  `emit_trapping_result`** — a `case … of {ok,X}->X; {error,R}->raise` that unwraps the trapping
  `Result(Int, _)`. Read-only: `cur` is threaded on unchanged.
- **`emit_mem_store`** (`emit_core.gleam:1588`) builds `[bytes, addr, value, offset]` and, under
  `NoState`, routes through **`trapping_effect` + `emit_zero_effect`** (`{ok,_}`→`'ok'`, `{error,E}`
  →`raise`, sequenced as a discardable `let`); under `Threading(cur)` through
  **`emit_threaded_record_effect`** — a `case … of {ok,S}->S; {error,R}->raise` that reduces the
  trapping `Result(InstanceState, _)` to the rebound record `St2`.

Both selections key on **`ctx.binding.mem_module`** — a fixed module *name*, tier-agnostic (G5): the
tier ladder is a module swap the linker resolves, and `emit_core` reads only the name, never
`mem_tier`. `profiles.mem_module_for` maps the tier to that atom (`Paged →
"twocore@runtime@rt_mem"`, `Atomics → "twocore@runtime@rt_mem_atomics"`, `Nif →
"twocore@runtime@rt_mem_nif"`; `profiles.gleam:358`), and `resolve_tiers` copies it onto the binding.

**This unit flips exactly that freeze decision** — the unchecked nodes stop borrowing the checked
emitters and get their own, calling the `_unchecked` seam and (crucially) **skipping
`emit_trapping_result`/`trapping_effect`/`emit_threaded_record_effect`**, because the unchecked
runtime returns a bare value with no `Result` to unwrap.

---

## A. Deliverables (single-owner-additive, `emit_core.gleam` only)

- `src/twocore/backend/emit_core.gleam` — **EXTEND (single owner).**
  1. Two new private emitters, `emit_mem_load_unchecked` / `emit_mem_store_unchecked`, mirroring the
     checked pair but calling the `_unchecked` seam and binding the bare return directly (§B).
  2. The **tier-selection dispatch** (§C): the `MemLoadUnchecked`/`MemStoreUnchecked` arms in the
     main `emit` walk (`emit_core.gleam:~969`, freeze-routed to `emit_mem_load`/`emit_mem_store`) now
     branch on a small predicate — **paged/atomics `mem_module` ⇒ the unchecked emitter; nif
     `mem_module` or `mem >= 1` ⇒ the checked emitter** (a sound no-op of the optimization).
  3. One private helper, `mem_supports_unchecked(mem_module: String) -> Bool` (§C), keyed on the
     **module name** (adds `import twocore/runtime/profiles` for `mem_module_for` — a clean
     backend→runtime dependency, no cycle).
- `test/twocore/backend/emit_core_test.gleam` — **EXTEND.** Structural goldens for the flipped
  lowering: an unchecked node emits the `_unchecked` seam fn on paged **and** atomics, and the
  **checked** seam fn on nif / for `mem >= 1` (§F.1). The checked emitters (`emit_mem_load`/
  `emit_mem_store`) and their goldens are **untouched**.
- `test/twocore/backend/emit_core_e2e_test.gleam` — **EXTEND.** End-to-end BEAM differential: an
  in-bounds unchecked access returns the **identical** value/effect as the checked equivalent,
  across `cell`+`threaded` × `paged`+`atomics` (§F.2).

**Out of scope (do NOT build here):** the `rt_mem`/`rt_mem_atomics` unchecked **bodies** (unit 04 —
this unit emits calls against them); the **BCE pass** that *produces* the unchecked nodes under a
proven guard (unit 06); the `_at` unchecked runtime twins (unit 04 ships none — `mem >= 1` stays
checked here); any pipeline registration (unit 07). No IR change, no `.ir` grammar change (N6).

---

## B. The two unchecked emitters (the seam shapes)

Both mirror their checked twin **operand-for-operand** — identical `tail`, identical `mem == 0` vs
`_at` split were an `_at` twin to exist (it does not — §C) — and differ in exactly two ways:
**(a)** they call the `_unchecked` seam fn; **(b)** the return is a **bare value**, so they bind it
with a plain `let`/`apply_cont` and **never** touch `emit_trapping_result`/`trapping_effect`/
`emit_threaded_record_effect`. The sketches are illustrative (final names/vars per the code), and
reuse the same `tail`, `bool_atom`, `result_width`, `emit_value`, `seam_call`, `apply_cont`,
`emit_zero_effect`, and `fresh_var` helpers the checked emitters already use.

### B.1 `emit_mem_load_unchecked` — a read that returns a bare `Int`

`load_unchecked`/`t_load_unchecked` return an `Int` directly (unit 04, keystone §D) — no `Result`,
no trap. So the emitter is the **`MemSize`-shaped** read: bind the value straight through `apply_cont`
(read-only, `cur` unchanged under `Threading`). The tail is byte-for-byte `emit_mem_load`'s.

```gleam
/// `t.load` on a PROVEN-in-bounds address (Phase-10 N4). Identical operands + tail to `emit_mem_load`,
/// but calls `rt_mem`'s UNCHECKED entry point (unit 04), which returns a BARE `Int` (no trapping
/// `Result`) — so it binds the value directly via `apply_cont` and NEVER goes through
/// `emit_trapping_result`. Read-only: `cur` is threaded on unchanged. Reached ONLY on paged/atomics
/// for `mem == 0` (§C); nif / `mem >= 1` route to `emit_mem_load` instead.
fn emit_mem_load_unchecked(
  mem: Int, op: ir.MemAccess, addr: Value, offset: Int, result: ValType,
  cont: Cont, sc: StateChan, state: EmitState, ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let tail = [
    CInt(op.bytes), bool_atom(op.signed), CInt(result_width(result)),
    emit_value(addr), CInt(offset),
  ]
  let call = case sc {
    NoState -> seam_call(ctx.binding.mem_module, "load_unchecked", tail)
    Threading(cur) ->
      seam_call(ctx.binding.mem_module, "t_load_unchecked", [CVar(cur), ..tail])
  }
  // Bare Int → dispose directly (no `case`-and-`raise`). Mirrors `emit_mem_size`.
  apply_cont(cont, [call], sc, state, ctx)
}
```

### B.2 `emit_mem_store_unchecked` — a `global.set`-shaped ordered effect

`store_unchecked` returns `Nil` (cell) and `t_store_unchecked` returns the `InstanceState` **record
directly** (unit 04, keystone §D) — again no `Result`. So the store is the **`global.set`-shaped**
non-trapping mutator: under `NoState`, a discardable `emit_zero_effect` (`let <_> = call in rest`);
under `Threading(cur)`, a **direct record rebind** `let St2 = call in <rest under Threading(St2)>`
(exactly `emit_global_set`'s `t_global_set` branch — the record comes back bare, not `{ok,S}`), so it
does **not** call `emit_threaded_record_effect`.

```gleam
/// `t.store` on a PROVEN-in-bounds address (Phase-10 N4). Identical operands + tail to `emit_mem_store`,
/// but calls `rt_mem`'s UNCHECKED entry point, which returns BARE `Nil` (cell) / a BARE record
/// (threaded) — no trapping `Result`. So `NoState` is a discardable `emit_zero_effect` and
/// `Threading` is a DIRECT record rebind `let St2 = call in …` (NOT `emit_threaded_record_effect`,
/// which reduces a `{ok,S}` case). Eval order addr → value → store. Reached ONLY on paged/atomics
/// for `mem == 0` (§C); nif / `mem >= 1` route to `emit_mem_store`.
fn emit_mem_store_unchecked(
  mem: Int, op: ir.MemAccess, addr: Value, value: Value, offset: Int,
  cont: Cont, sc: StateChan, state: EmitState, ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let tail = [CInt(op.bytes), emit_value(addr), emit_value(value), CInt(offset)]
  case sc {
    NoState -> {
      let effect = seam_call(ctx.binding.mem_module, "store_unchecked", tail)
      emit_zero_effect(effect, cont, sc, state, ctx)
    }
    Threading(cur) -> {
      let call =
        seam_call(ctx.binding.mem_module, "t_store_unchecked", [CVar(cur), ..tail])
      let #(newst, state2) = fresh_var(state)
      use #(rest, state3) <- result.try(apply_cont(
        cont, [], Threading(newst), state2, ctx,
      ))
      Ok(#(CLet([newst], call, rest), state3))
    }
  }
}
```

**Why no trapping plumbing.** The checked emitters exist to *unwrap a `Result` and raise on
`{error,R}`*. The unchecked runtime carries no `Result` — the guard (unit 06) already proved
in-bounds, so there is no error arm to encode. Removing the `case`/`raise` is the entire fast-path
win the node exists to express; keeping it would defeat the optimization. Soundness that the value is
in-bounds is unit 06's (the range guard); soundness that an *impossible* OOB is still node-safe is
unit 04's (the BEAM-safe slice/index, N5).

| IR node | checked emitter (freeze / fallback) | unchecked emitter (this unit) |
|---|---|---|
| `MemLoadUnchecked` | `case '<mem>':'load'/'t_load'(…) of {ok,X}->X; {error,R}->raise` | `X = '<mem>':'load_unchecked'/'t_load_unchecked'(…)` (bare `Int`) |
| `MemStoreUnchecked`, `NoState` | `let <_> = case '<mem>':'store'(…) of {ok,_}->'ok'; {error,E}->raise in …` | `let <_> = '<mem>':'store_unchecked'(…) in …` (bare `Nil`) |
| `MemStoreUnchecked`, `Threading(cur)` | `let St2 = case '<mem>':'t_store'(…) of {ok,S}->S; {error,R}->raise in …` | `let St2 = '<mem>':'t_store_unchecked'(…) in …` (bare record) |

---

## C. Tier selection + the nif / multi-memory fallback (N5)

The main `emit` walk arms — freeze-routed to the checked emitters (keystone §C) — now branch:

```gleam
MemLoadUnchecked(mem, op, addr, offset, result) ->
  case mem == 0 && mem_supports_unchecked(ctx.binding.mem_module) {
    True  -> emit_mem_load_unchecked(mem, op, addr, offset, result, cont, sc, state, ctx)
    False -> emit_mem_load(mem, op, addr, offset, result, cont, sc, state, ctx)   // checked fallback
  }
MemStoreUnchecked(mem, op, addr, value, offset) ->
  case mem == 0 && mem_supports_unchecked(ctx.binding.mem_module) {
    True  -> emit_mem_store_unchecked(mem, op, addr, value, offset, cont, sc, state, ctx)
    False -> emit_mem_store(mem, op, addr, value, offset, cont, sc, state, ctx)   // checked fallback
  }
```

with the module-name predicate:

```gleam
/// True iff the linked memory tier ships the UNCHECKED entry points (unit 04) and they are
/// BEAM-safe on an (guard-impossible) OOB — paged + atomics (N5). Keyed on the MODULE NAME (G5:
/// `emit_core` never reads `mem_tier`). FAIL-CLOSED: the nif module — and ANY module not proven to
/// carry the unchecked twins — returns False, so the node lowers via the CHECKED emitter (a sound
/// no-op of the optimization: the versioned fast loop only runs in-bounds, so the check never fires).
fn mem_supports_unchecked(mem_module: String) -> Bool {
  mem_module == profiles.mem_module_for(instance.Paged)
  || mem_module == profiles.mem_module_for(instance.Atomics)
}
```

The two fallback conditions and why each is sound:

- **`mem >= 1` (multi-memory) ⇒ checked.** Unit 04 ships **no** `load_unchecked_at`/`store_unchecked_at`
  twin (the `_at` heads carry a leading memidx; the unchecked path is single-memory only). So a
  multi-memory unchecked node lowers to the checked `load_at`/`store_at` — identical behaviour, just
  with the check. (Unit 06 need not even emit unchecked nodes for `mem >= 1`; this arm is the
  belt-and-braces sound default if it ever does.)
- **nif `mem_module` ⇒ checked (N5).** An unchecked *native* access could corrupt the node if the
  range analysis were ever wrong; Safe forbids nif and the nif C backend is a documented Phase-4
  skeleton, so the unchecked twins **ship only on paged + atomics**. On nif the fast arm and slow arm
  of the versioned loop are therefore **identical checked code** — a documented, sound no-op of the
  BCE win on that tier (the overview's "`nif` BCE is deferred (fallback to checked)").

**Why a positive whitelist (paged + atomics), not `!= nif`.** Both are equivalent under today's
three tiers (the profile guarantees `mem_module` is one of exactly three atoms), but the whitelist is
**fail-closed**: a future/unknown `mem_module` returns `False` and lowers checked (always correct),
whereas a negative `!= nif` would route an unrecognized module to the unchecked seam it may not carry.
Given N5's soundness emphasis (a wrong "unchecked" is silent corruption), the fail-closed direction
is the house rule.

**G5 is preserved.** The predicate reads the **module name**, never the `mem_tier` enum — exactly as
`emit_mem_load`/`emit_mem_store` already select `load` vs `load_at` by the name. `ctx.binding.mem_tier`
*is* reachable (the `Binding` record carries it, `instance.gleam:242`), but reading it would violate
G5/N5's "the emitter never sees the tier"; the module-name predicate keeps the tier a linker concern.

---

## D. Effect / soundness / security note (D3a, N4, N5)

- **The unchecked seam is only *reached* under a proven guard.** `emit_core` does not decide an access
  is in-bounds — it only *lowers* a node the **BCE pass (unit 06)** placed inside the **fast arm of a
  versioned loop** whose runtime range-guard proved the whole access range `< memory.size` (N4). So
  at runtime the unchecked call is **never OOB**. This unit adds no proof obligation of its own; it
  faithfully lowers a node whose soundness is unit 06's (the guard) and unit 04's (the BEAM-safe body).
- **BEAM-safe even on an impossible OOB (N5).** Were the range analysis ever wrong, the unchecked
  path still cannot corrupt: paged slices an **immutable binary** (an out-of-range slice is a caught
  BEAM error → a trap), atomics indexes an `atomics` array (an out-of-range index is a caught error).
  A hypothetical bug degrades to a *trap*, never a node crash or memory escape. nif — where an
  unchecked native access *could* escape — is excluded by §C.
- **No ambient authority (D3a).** Every emitted call is
  `seam_call(ctx.binding.mem_module, "load_unchecked"/"t_load_unchecked"/"store_unchecked"/
  "t_store_unchecked", [St?, bytes, …])` — a **fixed** runtime module atom, a **literal** function
  atom, and `addr`/`value`/`St` as **ordinary arguments**, never a module/function selector. It is a
  static `call '<mem_module>':'load_unchecked'(…)`, **never** apply-from-data. So the structural
  security walk (`assert_calls_are_runtime` + the `apply`-is-`FName` walk,
  `emit_core_security_test`) passes with the **same** `runtime_modules(binding)` allow-set (the
  `mem_module` is already in it) — the unchecked fns add no new callee module, only new function
  atoms on an already-allowed module.
- **Safe byte-identity for non-Phase-10 modules is preserved.** The unchecked nodes are produced
  **only** by the BCE pass (unit 06), **never** by `decode`/`validate`/`lower` (N6, keystone §C), and
  this unit **does not touch** `emit_mem_load`/`emit_mem_store` or any other emitter. So **every**
  module without the unchecked nodes — the whole Phase-1…9 corpus + the WASM spec suite — emits
  **byte-identical** `.core` under every tier and both profiles. The flip is inert until unit 06 runs.
- **Floats-as-bits (D5) unchanged.** The unchecked load/store pass `(bytes, signed, W, addr, offset)`
  straight through, exactly as the checked pair — raw bytes over the IEEE bit pattern, never a
  BEAM-double round-trip.

---

## E. Spec grounding

The unchecked lowering changes **nothing** about the WASM memory semantics the runtime realises — it
is the *same* effective-address / width / sign computation as the checked path, with the bounds
compare elided *because the optimizer proved it redundant*. No-wrap effective address and (for the
checked fallback) trap-before-write remain the runtime's job
([exec/memory](https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions)).
Loop versioning (N4) is what makes eliding the check observably sound: the fast arm runs **only** when
the guard proved the whole range in-bounds, so no iteration could have trapped either way; otherwise
the original **checked** loop runs, trapping `MemoryOutOfBounds` at the identical observable point.
This unit is the mechanical realisation of "the fast arm's accesses are unchecked" — the guard that
justifies it is unit 06's.

---

## F. Verification — Definition of Done (D8)

Tests assert **decision/spec behaviour** (N4/N5, G5, D3a), not whatever bytes the code emits (no
change-detector goldens). Cite the decision in each.

1. **Structural — the flipped lowering (`emit_core_test`).** Hand-build a module (via the existing
   `op_module` helper) whose body is `MemLoadUnchecked(0, MemAccess(4, False), Var("a"), 0, TI32)` and
   one with `MemStoreUnchecked(0, MemAccess(4, False), Var("a"), Var("v"), 0)`. Using `contains_call`
   (`emit_core_test.gleam:913`):
   - **paged binding** (`instance.safe_default()`): assert `contains_call(body, b.mem_module,
     "load_unchecked")` (and `"t_load_unchecked"` under a `Threaded` binding); the store body is a
     `let <_> = call '<mem>':'store_unchecked'(4,a,v,0) in …` with **no** `{error,_}` clause /
     `raise` (assert the shape is a plain `CLet` over the bare seam call, and `!contains_call(body,
     b.trap_module, "raise")` for the store); the threaded store rebinds `let St2 =
     '<mem>':'t_store_unchecked'(St,…)` (a direct record `CLet`, not a `{ok,S}` `CCase`).
   - **atomics binding** (`profiles.compose(profiles.ceiling(), Cell, Atomics, TableAtomics)` or an
     equivalent hand-set `mem_module`): assert the **same** `load_unchecked`/`store_unchecked` fn
     names on the atomics `mem_module` (the seam is module-name-selected, G5).
   - **nif binding** (`mem_module == mem_module_for(Nif)`) **and** the `mem >= 1` case on paged:
     assert the **checked** fn is emitted — `contains_call(body, b.mem_module, "load")` /
     `"store"` — and the unchecked fn is **absent** (`!contains_call(body, b.mem_module,
     "load_unchecked")`), i.e. the node fell back to `emit_mem_load`/`emit_mem_store`. Cite N5 / §C.
2. **End-to-end BEAM differential (`emit_core_e2e_test`; green once unit 04's bodies exist).** For each
   of `cell`+`threaded` × `paged`+`atomics`: hand-build IR that stores then loads an **in-bounds**
   address via the **unchecked** nodes, `emit_module` → `build_beam` → `instantiate` → invoke, and
   assert the returned value is **byte-identical** to the **checked oracle** (the same IR with
   `MemLoad`/`MemStore`), including a `load8_s`/`load16_u` sign-extension width and a `TI64` load. The
   unchecked and checked builds must agree bit-for-bit on every in-bounds access (N5's "identical bits
   as the checked path"). (On nif the two builds are identical by construction — §C.)
3. **WASM corpus byte-identical for modules WITHOUT the nodes.** The whole Phase-1…9 conformance
   corpus + WASM spec suite stay **result-identical** (and the emitted `.core` byte-identical) under
   both profiles and every `(state_strategy × mem_tier)` — proven by the checked emitters being
   untouched and the frontend never producing an unchecked node (§D, N6). This is the standing
   conformance gate; no new fixture regresses it.
4. **Green DoD.** `gleam format --check src test` clean; `gleam build` **zero warnings** (both new
   emitters total, no `todo`/`panic` on a live path); `gleam test` stays green (≥ 1783 + the new
   tests, 0 failures); a contract doc comment on `emit_mem_load_unchecked`, `emit_mem_store_unchecked`,
   and `mem_supports_unchecked` (D8). Committed as one focused unit and pushed.

**Proof of goal:** test 1 shows the two nodes now emit the `load_unchecked`/`store_unchecked` seam on
paged **and** atomics and the **checked** seam on nif / for `mem >= 1`; test 2 shows the fast path
returns the identical value/effect as the checked oracle on every shipped `(state_strategy × mem_tier)`;
test 3 shows every module without the nodes is unchanged. The freeze's checked-path stand-in is
replaced by the real fast seam, with the fallback keeping every tier sound.

---

## What this unit leaves for others

- **Unit 06 (range-BCE)** *produces* `MemLoadUnchecked`/`MemStoreUnchecked` — inside the fast arm of a
  versioned loop whose runtime range-guard proved the whole access range in-bounds — so the seam this
  unit wired is finally reached under a proof. Until unit 06 lands, no node exists to lower and the
  corpus stays byte-identical (§D).
- **Unit 07 (capstone)** wires LICM + cross-CF + BCE into `ir_opt.pipeline` and runs the corpus
  differential across every tier + both modes, re-verifying that the in-bounds unchecked path is
  value/trap-identical to the checked oracle corpus-wide.
