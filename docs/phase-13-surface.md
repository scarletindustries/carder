# Phase 13 — the WebAssembly tail-call proposal (`return_call` / `return_call_indirect`)

> A small, focused **surface** phase: one WASM proposal, lowered to **genuine constant-stack BEAM
> tail calls**, D3a-clean. Non-funcref modules stay **byte-identical**; funcref/`elem`-bearing
> modules become **result-identical** (a §8-sanctioned emitted-code change, proven by the `callind`
> differential). MEASURED, never promised (R16).

---

## The headline (measured)

WASM spec conformance, Safe profile, full re-vendored allowlist (identical under **Safe** and
**Unsafe**, and `fail == 0` under every shipped `(state_strategy × mem_tier × table_tier)` combo):

| | pass | skip | fail |
|---|---|---|---|
| **Phase-6 close** (the WASM 2.0 surface) | 46,529 | 1,768 | 0 |
| **Phase-13** (two official tail-call `.wast` folded into the main allowlist) | **46,646** | 1,771 | **0** |
| **Δ** | **+117** | +3 | 0 |

The `+117` is the two official tail-call files lighting up: `return_call.wast` **+43**,
`return_call_indirect.wast` **+74**. The `+3` skip is the **one** host-import tail/direct call in each
file (`spectest.print_i32_f32`) **denied under the deny-all Safe host** — a categorized POLICY denial,
not a spec trap (it PASSES under the open-host `unsafe` profile) — plus one already-categorized
text-format assert in `return_call_indirect`. Running gleeunit total: **2,049 pass / 0 fail** (was
2,043; +6 in the dedicated capstone proofs). `gleam build` zero warnings, `gleam format --check` clean.

---

## What shipped

`return_call` (opcode `0x12`) and `return_call_indirect` (opcode `0x13`), end to end:

| Stage | What landed |
|---|---|
| **decode + WAT** (Q13-02) | `0x12 → ast.ReturnCall(func)`, `0x13 → ast.ReturnCallIndirect(type_idx, table)` (typeidx then tableidx, anti-swap); WAT `return_call`/`return_call_indirect` text. |
| **validate** (Q13-03) | The tail-call typing rule: pop the callee's params (+ an `i32` index and a `FuncRef` table check for indirect), then **require the callee's result types to equal the current function's result types** (reuses `TypeMismatch`, no new error variant), then `mark_unreachable` (stack-polymorphic, exactly like `return`). |
| **lower** (Q13-04) | The `Return`-shape bottom-transfer lowering: build the transfer node, `consume_dead` the rest of the block, `end_or_else` — no `wrap_let`/live-continuation recursion (the continuation is dead by spec). Import-vs-defined split mirrors `lower_call` → `ir.ReturnCall` / `ir.ReturnCallIndirect` / `ir.ReturnCallImport`. |
| **emit_core + rt_table** (Q13-05) | The real constant-stack tail emission: **direct** reuses the existing direct-call tail path under a forced `KReturn` (a bare tail `apply`); **indirect** emits the new `rt_table.call_indirect_lookup` seam (the 3 ordered fail-closed guards, RETURNING the target instead of applying it) then **tail-applies** the package-ABI target in the ok-arm; **imported** reuses the existing import path under `KReturn` (value-correct, bounded frame — no `link` change). |

**The funcref-ABI change (Q13-05, the load-bearing new thing).** A funcref table target used to speak the
**list ABI** (`fn(List)→List`); a WASM function's Core boundary is the **`function_return` package**
(`[]`→`'ok'`, `[v]`→bare `v`, `[v₁..vₙ]`→tuple). Tail-applying the list-wrapping closure would be *both*
wrong-valued *and* secretly non-tail (the inner `apply` sits inside a cons → linear stack growth). So the
funcref stored closure became **package-ABI and tail-transparent** (body = a bare tail `apply`), and the
**non-tail** `call_indirect` seam re-wraps that package back into a result list *inside `rt_table`* using
the result arity from the guard-checked `FuncType` — so `emit_call_indirect`'s emitted seam is unchanged
and observably identical. Consequence: **funcref/`elem`-bearing modules are result-identical, not
byte-identical** (proven by the `callind` corpus differential — values + traps unchanged though the Core
changed). Modules with no funcref/`elem` stay **byte-identical**. `link.gleam` was **not** touched.

---

## The acceptance table — proven, MEASURED

| Row | Proven by | Measured result |
|---|---|---|
| **Official suite** | `return_call.wast` + `return_call_indirect.wast` vendored (`--enable-tail-call`) and driven by the main `conformance_test` | `fail == 0`; +117 pass (43 + 74); driven under Safe/Unsafe + every matrix combo |
| **Constant stack** | `tailcall_capstone_test` proofs 1–3: `count_down` / `is_even`+`is_odd` / `ind_count_down` to **1,000,000** on real BEAM, `ffi.gc_and_memory` bounded (`mem_big < mem_small × 4`) | direct + mutual + indirect (same-module) complete in **bounded live memory**; indirect proven under both `TablePaged` and `TableAtomics` |
| **Typing rule** | Q13-03's `assert_invalid` spec tests (result-type mismatch rejected; stack-polymorphism like `return`) | Q13-03 suite green (re-run) |
| **Indirect fail-closed** | the three ordered traps in `corpus/tailrec.expected` (driven across every combo) + `return_call_indirect.wast` | `undefined element` → `uninitialized element` → `indirect call type mismatch`, same order as `call_indirect`; `fail == 0` |
| **Default unaffected** | full conformance for all non-tail files UNCHANGED; `tier_differential` + `tailrec_opt_level_bit_identical_test` + `tailrec_default_byte_identical_test` | non-funcref modules byte-identical; funcref (`callind`) result-identical; **OptNone ≡ Baseline ≡ Aggressive**; cross-combo results identical, `fail == 0` everywhere |

"Green" here always means **MEASURED** (a count printed and asserted), never "it compiled".

---

## Honest scope (Q8 — stated, not hidden)

- **Only the two tail-call instructions.** No GC, no typed refs, no new trap reason. A WASM tail call
  traps for exactly the reasons an ordinary call does; **"call stack exhausted" is not a WASM trap and
  does not exist on the BEAM** — which is precisely what the constant-stack witness proves.
- **Imported tail calls (`ReturnCallImport`) are VALUE-CORRECT with a BOUNDED caller frame**, NOT a
  cross-module constant-stack claim. On the BEAM an import callee is a separate process, so "stack" is
  per-process; the caller tail-transfers a bounded amount before the import returns. Q13-05 owns the
  imported-tail-call emit proof (value-correctness); this capstone re-runs it green and **cites** it,
  and makes **no** 1,000,000-deep constant-stack claim for imports. In the official `return_call.wast`,
  the one imported tail call (`spectest.print_i32_f32`) is a **categorized POLICY skip under the
  deny-all Safe host** and a **pass under `unsafe`** (open host) — the fail-closed sandbox working as
  designed, not a tail-call gap.
- **No optimizer / memory-tier / state-strategy change.** Both state strategies (Cell/Threaded) and all
  tiers inherit the feature through the single `emit_core` seam. The loop tail-`apply` back-edge is
  untouched (a tail *call* is a cross-function transfer, orthogonal to the loop back-edge).

---

## The EH unblock — the MEASURED reality (R16: report the reality, not the plan)

Phase 13 was expected to unblock the two official EH `.wast` files "blocked purely on `return_call`"
(`legacy/try_catch.wast`, `legacy/try_delegate.wast`). **Measurement contradicts the premise:**

- **Conversion — DONE.** Both files now `wast2json`-**convert** at the pin with `--enable-exceptions
  --enable-tail-call` (self-consistency `spectest-interp` **42/42** + **26/26**), vendored by
  `vendor.sh`. The tail-call blocker on *conversion* is genuinely gone.
- **Driving green — DEFERRED (a scope DEEPER than tail-call).** Driving them end-to-end reveals they
  were **not** blocked purely on `return_call`:
  - `try_catch`'s `imported-mismatch` is a **cross-module EH function+tag import** (`(import "test" …)`)
    exercised by a plain `call` (NOT a tail call) — out of scope like `table_copy`'s cross-module
    funcref-`elem` init.
  - `try_delegate`'s `delegate-skip` / `delegate-correct-targets` are **legacy `delegate`
    label-targeting** semantics (NO `return_call` involved at all) — a pre-existing EH-lowering gap,
    newly exposed because the file was never driven before.
  - `try_delegate`'s `return-call-in-try-delegate` is the **`return_call`-inside-`try` interaction**: a
    WASM tail call must ABANDON the enclosing handler, but a BEAM `try/catch` is **dynamically scoped**,
    so a tail `apply` inside it stays in the handler's extent. A genuine emit-seam / EH-lowering concern,
    not a tail-call feature gap.

So `eh_conformance_test` keeps **4 files driven green** (153 asserts × 3 profiles, `fail == 0`) and lists
the two newly-convertible files as **categorized-deferred on the deeper scope** (never a false green;
the two un-`wast2json`-able files `tag.wast`/`try_table.wast` stay deferred on **GC / typed-refs**, no
longer on tail-call). See the module doc + `eh_unconvertible` in `test/twocore/conformance/eh_conformance_test.gleam`.

---

## Deferred, stated not dropped

- `try_table.wast` — needs typed refs / the GC `exn` heap type (Phase 13 is *necessary-but-not-sufficient*).
- `tag.wast` — GC recursive type groups `(rec …)`.
- Driving `legacy/try_catch.wast` + `legacy/try_delegate.wast` green — cross-module EH imports, legacy
  `delegate` label-targeting, and the `return_call`-abandons-`try` interaction (above).
- Cross-module / threaded **constant-stack** tail recursion **through imports** (bounded-frame only, Q8).
- GC (typed refs / `struct`/`array`/`i31`), stack-switching, the component model, relaxed-SIMD.

---

## One line per proof → the test that proves it

| Proof | Test |
|---|---|
| Official `return_call.wast` + `return_call_indirect.wast` run green (`fail == 0`, +117 pass) | `test/twocore/conformance/conformance_test.gleam` (vendored via `vendor/ALLOWLIST` + `vendor.sh`) |
| Constant stack — direct `return_call` self-loop to 1,000,000 in bounded live memory | `test/twocore/tier/tailcall_capstone_test.gleam` (`count_down_constant_space_test`) |
| Constant stack — mutual `is_even`/`is_odd` recursion to 1,000,000 | `tailcall_capstone_test.gleam` (`even_odd_constant_space_test`) |
| Constant stack — `return_call_indirect` self-loop, both table tiers | `tailcall_capstone_test.gleam` (`indirect_constant_space_test`) |
| Typing rule — result-type-mismatch `assert_invalid` rejected | Q13-03 suite (re-run green) |
| Indirect fail-closed — 3 ordered traps, driven across every combo | `test/twocore/conformance/corpus/tailrec.{wat,wasm,expected}` via `tier_differential_test` |
| Differential — `tailrec` result-identical across every shipped combo | `test/twocore/tier/tier_differential_test.gleam` (`corpus_programs` enrolls `tailrec`) |
| `OptNone ≡ Baseline ≡ Aggressive` bit-identical on `tailrec`, every combo | `tailcall_capstone_test.gleam` (`tailrec_opt_level_bit_identical_test`) |
| Default unaffected — non-funcref byte-identical, funcref (`callind`) result-identical | `tailcall_capstone_test.gleam` (`tailrec_default_byte_identical_test`) |
| Imported tail call value-correct / bounded frame | Q13-05 suite (re-run green + cited) |
| EH: 4 files driven green; 2 convert but categorized-deferred (measured) | `test/twocore/conformance/eh_conformance_test.gleam` |
| Skip audit honest + tight (`"return_call"`/`"call stack"` phrases removed) | `test/twocore/conformance/{skipcount,residual_audit}_test.gleam` |
