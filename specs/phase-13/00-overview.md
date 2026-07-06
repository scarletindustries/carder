# Phase 13 — The tail-call proposal (`return_call` / `return_call_indirect`)

> **Status:** scoped, awaiting the scoping fan-out + critique. No code yet. Follows the fixed skeleton in
> [`../03-phase-workflow.md`](../03-phase-workflow.md) §2. Decisions are `Q1–Q8` (the letter series
> continues from Phase 11's `O` and Phase 12's `P`; `Q1` = keystone, `Q8` = honest scope); **units** are
> `Q13-01 … Q13-06` (separately numbered).
>
> **All prior-phase decisions and the permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8)
> still hold.** Baseline entering: ~1,978 tests / 0 fail · `gleam build` zero warnings · `gleam format`
> clean · WASM conformance 46,529 / 1,768 / 0 (Safe ≡ Unsafe, every `state_strategy × mem_tier`). The
> keystone re-confirms the exact running total on landing.
>
> This is a small, focused **surface** phase (one WASM proposal). Per
> [`../03-phase-workflow.md`](../03-phase-workflow.md) §1 step 4 it folds its reconciliation into this
> overview (no standalone `RECONCILIATION.md`) unless the fan-out + critique surface a genuine conflict.

---

## §0. Where this phase sits

This is a **WASM-surface** phase: it completes one post-2.0 proposal. WASM 2.0 fixed-width is done
([`../01-status.md`](../01-status.md)); [`../02-roadmap.md`](../02-roadmap.md) §B flags tail-call as the
plausible fast-follow because it **maps natively onto the BEAM** — Core Erlang tail-calls in tail
position, so the runtime cost of a WASM tail call is *zero new machinery* for the common (direct) case,
and a single new dispatch seam for the indirect/imported case. It touches the frontend (decode, WAT,
validate, lower), the IR, the backend (`emit_core`), and one runtime module (`rt_table`), but **no
optimizer semantics, no memory tier, no state strategy**.

Its concrete payoff beyond spec-completeness: it **unblocks the 2 official EH `.wast` files that are
blocked purely on `return_call`** — `legacy/try_catch.wast` and `legacy/try_delegate.wast` — and lights
up the two official tail-call suite files `return_call.wast` / `return_call_indirect.wast` (currently
allowlisted out). (`try_table.wast` additionally needs typed refs / GC and `tag.wast` needs `(rec …)`;
both stay categorized-deferred — Phase 13 is *necessary-but-not-sufficient* for `try_table`.)

---

## §1. Goal & acceptance

**Goal.** Implement `return_call` (opcode `0x12`) and `return_call_indirect` (opcode `0x13`) end to end —
decode + WAT parse, validation (the tail-call typing rule), lowering, IR, and Core-Erlang emission that
performs a **genuine BEAM tail call in constant stack space**, D3a-clean (indirect dispatch still routes
through the build-controlled `rt_table` capability, never `erlang:apply` from table data). A module using
neither instruction compiles **byte-identically** to Phase 12.

**Acceptance table** (owned by the capstone, Q13-06):

| Area | Must demonstrate |
|---|---|
| Official suite | `return_call.wast` and `return_call_indirect.wast` (vendored from the pinned testsuite, previously allowlisted out) run green — measured pass count reported, `fail=0`. |
| Constant stack | A tail-recursive corpus program (e.g. `return_call` self-loop counting to 1,000,000, and a mutually-recursive even/odd via `return_call`) **completes in constant space** — proven the way `sum_to(100000)` is (a growing call stack would exhaust the process). Applies to direct, indirect, and imported tail calls. |
| Typing rule | `assert_invalid` cases where the callee's result types differ from the current function's result types are **rejected** (spec §"return_call" validation: the callee results must equal the function's results); stack-polymorphism after a tail call matches `return`/`br`. |
| Indirect fail-closed | `return_call_indirect` preserves the 3 ordered guards (index-in-bounds → `UndefinedElement`; slot-non-null → `UninitializedElement`; exact `FuncType` → `IndirectCallTypeMismatch`) — same traps, same order as `call_indirect`. |
| EH unblock | `legacy/try_catch.wast` + `legacy/try_delegate.wast` move from `eh_unconvertible` into the driven `eh_files` set (vendored with `--enable-exceptions`) and convert. |
| Default unaffected | A module with no `return_call*` compiles byte-identically; the loop tail-`apply` back-edge is untouched; `gleam test` + conformance stay green; `OptNone ≡ Baseline ≡ Aggressive` across the whole `(mode × state_strategy × mem_tier)` matrix, bit-identical values + identical traps. |

**Honest scope** (= decision Q8, restated in §2):
- **Only the two tail-call instructions.** No GC, no typed refs, no `try_table` (still needs those); no
  `tag.wast` (`(rec …)`). Those stay categorized-deferred in [`../02-roadmap.md`](../02-roadmap.md).
- **No new trap reason.** A WASM tail call traps for exactly the reasons an ordinary call does; "call
  stack exhausted" is not a WASM trap and does not exist on the BEAM (that is the whole point).
- **No optimizer, memory-tier, or state-strategy change.** Both state strategies (Cell/Threaded) and all
  tiers inherit the feature through the single `emit_core` seam, unchanged.

---

## §2. Decisions (Q1–Q8)

> Each decision is **frozen** for this phase. If you believe one is wrong, **raise it with the planner
> BEFORE building — do not silently diverge.** By convention Q1 is the keystone; Q8 is honest scope.

**Q1 (keystone) — Tail calls are bottom-transfer IR nodes; the indirect case gets a constant-stack
"lookup → tail-apply" seam over a *package-ABI, tail-transparent* funcref target.** The load-bearing new
thing. Three new IR nodes, each carrying only `Value` operands (leaves in every traversal, siblings of
`Return`): `ReturnCall(fn_name, args)`, `ReturnCallIndirect(table, index, ty, args)`,
`ReturnCallImport(slot, ty, args)`. Direct tail calls need *no new runtime* — `emit_core` already emits a
`CallDirect` under `KReturn` as a genuine BEAM tail call (`emit_call_direct` / `apply_cont_call`), and a
compiled function returns its `function_return` package directly, so `ReturnCall` is "emit the direct-call
logic forcing the return continuation" — value-correct (the Q3 result-equality rule guarantees caller and
callee share result types) and constant-stack, Cell and Threaded.

The genuinely-new machinery is the **indirect** case, and its correctness hinges on an ABI fact caught by
the scoping critique (see the **⚠ ABI reconciliation** note below §2): a funcref table target today speaks
the **list ABI** (`fn(List(Int)) -> List(Int)`, a list-wrapping closure), but a WASM function's Core
boundary is the **`function_return` package** (`[]`→`'ok'`, `[v]`→bare `v`, `[v₁..vₙ]`→tuple). Tail-
applying the list-wrapping closure would be *both* wrong-valued (`[v]` not `v`) *and* secretly non-tail
(the inner `apply` sits inside a cons → linear stack growth). The fix: the funcref stored closure becomes
**package-ABI and tail-transparent** (its body a bare `apply 'f'/n(unpacked args)` returning `f`'s package
directly); the **non-tail** `call_indirect` seam re-wraps that package back into the result list *inside
`rt_table`* using the result arity carried by the (guard-checked) `FuncType` — so `emit_call_indirect`'s
emitted seam is unchanged and observably identical. A new `rt_table` entry point
`call_indirect_lookup(index, expected_type) -> Result(target, TrapReason)` (+ the `_at` multi-table twin +
`t_` threaded twins) runs the 3 fail-closed guards and **returns the package-ABI target instead of applying
it**, so `emit_core` can tail-apply it in the success arm (`case Lookup of {ok,T} -> apply T(Args) ;
{error,E} -> raise(E) end`) — a real tail call, constant stack, D3a-clean (the closure is the
build-controlled table capability; only the integer index is program-derived). The **imported** tail call
(`ReturnCallImport`) emits the existing import-call logic under `KReturn`: value-correct with a bounded
caller frame (the import callee is another process; the caller is not accumulated) — cross-module/threaded
*constant-stack* tail recursion through imports is a documented honest-scope sub-case (Q8), not a claim.

Because the funcref stored closure's emitted Core changes (package-ABI), **funcref-bearing modules become
result-identical rather than byte-identical** — a §8-sanctioned legitimate emitted-code change, proven by
the `callind` corpus differential. Modules with no funcref/`elem` are byte-identical.

**Q2 — Two new opcodes / two new AST + IR constructors; everything else is exhaustiveness plumbing.**
`0x12 → ast.ReturnCall(func)`, `0x13 → ast.ReturnCallIndirect(type_idx, table)` (immediates identical to
`call` / `call_indirect`; the field naming stays anti-swap). Adding the AST + IR constructors forces new
arms in every total match (`validate`, `lower`, `emit_core.emit`, `ir/effect`, `ir/printer`, `ir/parser`,
`ir_lower`, and the `ir_opt` passes `pass`/`baseline`/`aggressive`/`bce`/`loop_analysis`/`mem_clobber`/
`mem_ssa`). In the optimizer + effect layers the new nodes are **effectful bottom-transfer barriers**,
handled exactly like `Return`/`Trap` (no reorder/CSE/DCE across them) — mechanical, final. The keystone
adds all of them and ships a lossless round-trip in the `.ir` printer/parser (D5).

**Q3 — Validation is the `return`/`br` rule plus a result-type equality check.** Per the WASM tail-call
spec, `return_call`/`return_call_indirect` pop the callee's params (and, for indirect, an `i32` index and
a `FuncRef` table check), then **require the callee's result types to equal the current function's result
types**, then mark the stack polymorphic (`mark_unreachable`) exactly like `return`. The current
function's results are read the way `Return` reads them (the outermost control frame's `end_types`). The
result-mismatch diagnostic reuses the existing `TypeMismatch` `ValidateError` (the spec treats it as a
plain type mismatch — no new error variant, so `validate.gleam` stays single-owner).

**Q4 — Lowering follows the `Return` shape, not the `Call` shape.** A tail call's continuation is dead by
spec: build the bottom-transfer node, `consume_dead` the rest of the block to its closing marker,
`end_or_else` — it must **not** `wrap_let` + recurse into a live continuation (there are no result values
to bind in the caller). The import-vs-defined split mirrors `lower_call` (`func < ctx.imported` →
`ReturnCallImport(slot=func, …)`, else `ReturnCall("f"<>func, …)`).

**Q5 — `emit_core` emits genuine tail calls; the loop back-edge is untouched.** `ReturnCall` reuses the
existing direct-call tail path under a forced `KReturn` (a bare tail `apply`, value + stack correct).
`ReturnCallIndirect` emits the Q1 `call_indirect_lookup` seam then tail-applies the returned package-ABI
target. `ReturnCallImport` emits the existing import-call logic under `KReturn` (value-correct, bounded
frame). None of this touches `emit_loop`/`emit_continue`/`materialize`: a tail *call* is a cross-function
transfer, orthogonal to the loop tail-`apply` back-edge, which stays byte-for-byte unchanged (invariant,
§8). Threaded builds thread `cur` into the direct/indirect tail apply unchanged (the callee threads its
own state and returns the `{package, St'}` shape), matching `emit_call_direct` under `Threading`. The
funcref-construction ABI change (list-wrapping → package-ABI tail-transparent) and the `rt_table`
re-wrap live with the tail-emission unit (Q13-05), not the keystone — see §4.

**Q6 — Byte-identical by default.** New opcodes only appear when a module uses them; the new AST/IR
constructors only exist post-lowering of those opcodes; the new `emit` arms are only reached by the new
IR nodes; the new `rt_table` seam is dead code until `emit_core` calls it. A module using no `return_call*`
compiles **byte-identically** to Phase 12 (H7/§8). Where the capstone drives new surface, the bar is
result-identical across `OptNone ≡ Baseline ≡ Aggressive` and the whole tier/state matrix.

**Q7 — Correctness is the official suite + a constant-stack property, not golden change-detectors.** The
proof is: the two official tail-call `.wast` files run green (Tier-A baked values), the newly-unblocked EH
files convert, and an authored corpus program *demonstrates constant space under deep tail recursion*
(the honest test of "is it really a tail call" — a wrapped/non-tail emission would exhaust the process).
Spec-cited `assert_invalid` tests encode the typing rule. No test locks in emitted Core text beyond a
small spec-grounded round-trip golden for the `.ir` form.

**Q8 — Honest scope.** As §1: the two tail-call instructions only; no GC/typed-refs/`try_table`/`tag`; no
new trap; no optimizer/tier/state-strategy change; both state strategies + all tiers inherit through the
`emit_core` seam. **Constant-stack guarantee scope:** direct and indirect (same-module) tail calls are
fully constant-stack (the acceptance property). A `return_call` to an **imported** function is
**value-correct with a bounded caller frame** — cross-module/threaded *constant-stack* tail recursion
through imports is **not** guaranteed and is a documented sub-case (on the BEAM an import callee is a
separate process, so "stack" is per-process; the caller tail-transfers a bounded amount before the import
returns). The official `return_call.wast` / `return_call_indirect.wast` suites exercise same-module tail
calls, which are fully covered.

> **⚠ ABI reconciliation (authoritative; folds the scoping critique into these decisions).** The scoping
> fan-out's adversarial critique caught a phase-killer: the frozen "return the stored funcref closure and
> tail-apply it" plan is *wrong-valued and secretly non-tail*, because the stored closure speaks the
> **list ABI** (`fn(List)→List`, a `[apply f(args)]` cons-wrap) while a function's Core boundary is the
> **`function_return` package** (`[]`→`'ok'`, `[v]`→bare `v`, `[…]`→tuple). The resolution, binding on Q1/Q5
> and the ownership map §4:
> 1. **Funcref stored closures become package-ABI + tail-transparent** — `emit_core`'s `element_closure` /
>    `threaded_element_closure` / `reference_func_entry` emit `fun(ArgsList) -> apply 'f'/n(unpacked) end`
>    (body = a bare `apply` in tail position, returning `f`'s package directly). Under Threading the
>    closure returns `{package, St'}`.
> 2. **The non-tail `call_indirect` re-wraps inside `rt_table`** — after the guards, it applies the target
>    and converts the package back to the result list using the result arity from the guard-checked
>    `FuncType` (`0→[]`, `1→[v]`, `N→tuple_to_list`), so `emit_call_indirect`'s emitted seam is unchanged
>    and observably identical.
> 3. **`call_indirect_lookup(index, expected_type)`** runs the guards and returns the package-ABI target
>    for `emit_core` to tail-apply.
> 4. **Imports** use the existing import-call logic under `KReturn` — **no** `link` change (no
>    `call_import` tail variant); value-correct, bounded frame (Q8 sub-case).
> 5. **Ownership:** the funcref-ABI change + the `rt_table` re-wrap + `call_indirect_lookup` + the real
>    tail emit **all live in the tail-emission unit Q13-05** (self-contained: it owns `emit_core`'s
>    funcref-construction + `rt_table`). The **keystone does not touch `rt_table`/`link`**; it owns the IR
>    vocabulary + plumbing + conservative-sound placeholders. `link.gleam` is **not** touched this phase.
> 6. **A freeze guard** (in Q13-05, and echoed as an assertion) verifies the `call_indirect_lookup` target,
>    when applied, yields the `function_return` package (bare `v` for one result, `'ok'`/tuple otherwise),
>    not a list — the check that would have caught the blocker.
>
> Consequence: **funcref-bearing modules are result-identical, not byte-identical** (§8-sanctioned; proven
> by the `callind` corpus differential). Modules without funcref/`elem` stay byte-identical.

---

## §3. Dependency DAG & freeze milestone

```
   Q13-01 keystone ──«TC-FROZEN»──┬──▶ Q13-02 decode + WAT ingest ─┐
   (ast+ir nodes, all exhaustiveness │──▶ Q13-03 validate typing rule ├─▶ Q13-06 capstone
    arms, conservative-sound         │──▶ Q13-04 lower bottom-transfer│   (official .wast green,
    validate/lower/emit placeholders,│──▶ Q13-05 emit_core + rt_table  ┘    constant-stack, EH unblock,
    .ir round-trip — byte-identical)      tail codegen (funcref-ABI, real)   differential, docs, SVG)
```

**Freeze milestone:**

| Milestone | Produced by | Unblocks |
|---|---|---|
| `«TC-FROZEN»` — the three IR nodes (`ReturnCall`/`ReturnCallIndirect`/`ReturnCallImport`), the two AST constructors, the `.ir` printer/parser round-trip, and every exhaustiveness-forced arm (effect/optimizer as final barriers; validate/lower/emit as conservative-sound value-correct placeholders their units complete). The `rt_table.call_indirect_lookup` seam and the funcref-ABI change are **self-contained in Q13-05** (no other unit consumes them), so they are *not* part of the keystone freeze | Q13-01 | Q13-02 … Q13-06 |

**Waves.** Wave 0: Q13-01. Wave A (parallel behind `«TC-FROZEN»`): Q13-02 (ingest), Q13-03 (validate),
Q13-04 (lower), Q13-05 (emit_core + `rt_table` tail codegen). Wave B: Q13-06 capstone (ties the pipeline
end-to-end and proves the phase).

**Keystone → unit handoff for the exhaustiveness-forced files (validate/lower/emit).** Because Gleam has
no default match arms, the keystone must add arms to `validate.gleam`, `lower.gleam`, and `emit_core.gleam`
merely to compile. It lands them **conservative-sound and value-correct**: the `emit` arms as a
semantically correct *non-constant-stack delegation* (route each `ReturnCall*` through the existing
ordinary `call`/`call_indirect`/`call_import` + return — right answer via the existing list-ABI seam, not
yet a tail call), keeping the keystone byte-identical; `lower`/`validate` as the minimal sound arm. Units
Q13-03/04 then **complete** `validate`/`lower`; **Q13-05** completes the `emit` arms *and* performs the
funcref-ABI change (package-ABI tail-transparent closures) + the `rt_table` re-wrap +
`call_indirect_lookup` — the whole tail codegen in one unit (per the ABI reconciliation note). This
keystone-reach-then-complete split is the sanctioned pattern
([`../03-phase-workflow.md`](../03-phase-workflow.md) §3); the reach is documented in
[`../state.md`](../state.md).

**Open seams for the scoping fan-out / critique to resolve:**
1. The keystone-placeholder ↔ unit-completion boundary for `validate`/`lower`/`emit_core` (which arm the
   keystone lands sound-but-minimal vs which the unit completes) — confirm it keeps each file
   single-substantive-owner and every intermediate state green + byte-identical.
2. Whether `ReturnCallImport` is a distinct IR node or `ReturnCall` with an `imported: Bool` (the map
   leans distinct-node for a clean emit path; confirm it does not over-fragment the optimizer arms).
3. Whether `return_call_indirect`'s constant-stack proof needs a bounded-recursion spec fixture beyond
   the corpus program (deep indirect self-recursion through a table slot).
4. Whether the capstone can drive `table_copy`-adjacent multi-table tail dispatch, or a dedicated authored
   `.wast` backstop is cleaner.

---

## §4. File-ownership map (one owner per file, D1)

| Unit | Owns / creates | Deliberate cross-file reaches |
|---|---|---|
| **Q13-01** keystone | `src/twocore/ir.gleam` (3 nodes) · `src/twocore/frontend/wasm/ast.gleam` (2 instrs) · `src/twocore/ir/effect.gleam` · `src/twocore/ir/printer.gleam` · `src/twocore/ir/parser.gleam` · `src/twocore/middle/ir_lower.gleam` · `src/twocore/middle/ir_opt/{pass,baseline,aggressive,bce,loop_analysis,mem_clobber,mem_ssa}.gleam` (barrier arms) · new `test/twocore/tail_call_freeze_test.gleam` | conservative-sound compile-arms into `validate.gleam` / `lower.gleam` / `emit_core.gleam` (completed by Q13-03/04/05), recorded in `state.md`. **Does NOT touch `rt_table.gleam` / `link.gleam`** (the tail seam + funcref-ABI are Q13-05's, per the ABI reconciliation note). |
| **Q13-02** ingest | `src/twocore/frontend/wasm/decode.gleam` (0x12/0x13) · `src/twocore/frontend/wasm/wat.gleam` (text) + focused decode/WAT round-trip tests | — |
| **Q13-03** validate | the real tail-call typing rule in `src/twocore/frontend/wasm/validate.gleam` + `assert_invalid` spec tests | — |
| **Q13-04** lower | the real bottom-transfer lowering in `src/twocore/frontend/wasm/lower.gleam` + lower tests (hand-built AST → IR) | — |
| **Q13-05** emit_core + rt_table tail codegen | the whole tail codegen: `src/twocore/backend/emit_core.gleam` — the real constant-stack tail emit arms (direct via forced `KReturn`; indirect via the `call_indirect_lookup` seam; imported via the existing import path under `KReturn`) **and** the funcref-construction ABI change (`element_closure`/`threaded_element_closure`/`reference_func_entry` → package-ABI tail-transparent); `src/twocore/runtime/rt_table.gleam` — the new `call_indirect_lookup` (+`_at`+`t_`) seam + the non-tail `call_indirect*` package→list re-wrap; tail-position + constant-stack + package-shape tests | completes the keystone's conservative `emit` arms (documented reach) |
| **Q13-06** capstone | `test/twocore/conformance/vendor/ALLOWLIST` + `vendor/vendor.sh` (vendor the 2 tail-call + 2 EH files) · `test/twocore/conformance/eh_conformance_test.gleam` (move 2 files into `eh_files`) · `test/twocore/conformance/residual_audit_test.gleam` + `skipcount_test.gleam` (re-measure) · `test/twocore/tier/combos.gleam` + a new `corpus/*.wat/.wasm/.expected` tail-recursion program · `docs/phase-13-surface.md` · `docs/wasm-conformance.svg` (regen) · `../01-status.md` | the single conformance-wiring + status point only |

---

## §5. How to claim & complete

Standard loop ([`../03-phase-workflow.md`](../03-phase-workflow.md) §7 + §9): read
[`../state.md`](../state.md); claim a unit; for Q13-01 freeze `«TC-FROZEN»` and land green with byte-
identical default output; build Q13-02…05 behind the frozen signatures; satisfy the per-unit Definition
of Done (spec-cited tests, doc comments, `gleam format --check src test` clean, `gleam build` zero
warnings, the unit's suite green); update `state.md`. The capstone (Q13-06) proves the acceptance table
(official `.wast` green, constant stack, EH unblock, the corpus-wide differential), regenerates the
conformance SVG, then this phase is compacted into [`../01-status.md`](../01-status.md) and `phase-13/`
removed.

> **Next step (per the methodology):** a scoping fan-out + adversarial critique before freezing — the
> constant-stack indirect/import seam (Q1), the keystone-placeholder boundary (open seam 1), and the
> validation result-equality rule (Q3) are exactly the areas a critique should pressure-test.
