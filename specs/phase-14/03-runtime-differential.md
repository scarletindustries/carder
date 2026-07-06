# R14-03 — The runtime differential: an import-routed funcref slot is tier- and strategy-uniform

> **Status:** scoped, awaiting build. **Owner:** R14-03 (runtime differential coverage — **pure test-only**;
> adds no production code — the adapter seam is frozen to inline (F3), so `link.gleam` is untouched). **Wave A**, behind
> `«REFFUNC-IMPORT-FROZEN»` (R14-01) but *independent of* R14-02's emit — it exercises the **runtime
> substrate** (`rt_table` / `rt_state` / `link`) that R14-02's emitted adapter closure relies on, not the
> emit path itself, so it can be built in parallel with R14-02. **Read order:**
> [`00-overview.md`](00-overview.md) → the distilled codebase map (`brief-phase14-xmodule-elem.md`) → this
> doc. All prior-phase decisions and the permanent invariants
> ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold. This unit lands **green with default
> emission byte-identical** — it adds **tests only** (no runtime code), and changes **no** runtime data shape.
> The funcref value shape `#(FuncType, closure)` is unchanged.

---

## §1. Goal

Prove — by a **cross-tier × cross-strategy differential** with a **spec oracle** — that a table slot holding
an **import-routed funcref** (`#(FuncType, adapter)`, where `adapter` dispatches through the D3a func-import
capability) is stored, moved, and dispatched **byte-identically** across the whole matrix, and that the
three fail-closed `call_indirect` guards fire correctly on such a slot **including after `table.copy`
shuffles it**. Concretely:

- **The headline invariant.** For an import-routed funcref stored at a table slot, `call_indirect` returns
  the **same result** across all six combos `{TablePaged, TableEts, TableAtomics} × {Cell, Threaded}`, and
  that result **equals a direct `link.call_import` of the same imported function** (WebAssembly spec: an
  imported function reached via `call_indirect` behaves identically to a direct `call` of that import).
- **The three fail-closed guards, on import-routed slots, in spec order** (`rt_table.gleam` §doc lines
  35–41; cell `call_indirect` guards at `rt_table.gleam:209–222`; threaded `t_call_indirect` at
  `:425–434`): (1) index in `[0, size)` else `UndefinedElement`; (2) slot non-null (present key) else
  `UninitializedElement`; (3) exact structural `FuncType` match else `IndirectCallTypeMismatch`. Each is
  asserted to fire on a slot whose contents are an import-routed funcref, across all six combos.
- **After `table.copy`** (`rt_table.gleam:335–346` cell / `:538–557` threaded, memmove/overlap-correct,
  R11): the copied import-routed funcref still dispatches to its imported function (reference-preserving
  copy), a vacated/null-overwritten slot traps `UninitializedElement`, and an out-of-range index traps
  `UndefinedElement` — the `table_copy.wast` trap shape (R6/R7) reproduced at the unit layer.
- **D3a made observable.** The adapter captures **only the literal slot integer** and resolves its target
  through the func-import vector at *dispatch* time — proven by re-seeding the vector under a stable stored
  funcref and observing the dispatch change (a late-binding capability, never a baked `module:atom`).

This upholds **R2** (the adapter is an D3a func-import-capability closure over `#(FuncType, closure)`),
**R4** (seed order / `slot == funcidx`), **R5/R8** (no runtime shape change, byte-identical default), and
**R6** (correctness is a cross-strategy/tier differential + a spec oracle, not a golden). It gives the
capstone (R14-04) the confidence that any `table_copy.wast` failure localizes to **emit/driver**
(R14-01/02), never the runtime substrate.

---

## §2. Depends on / Produces

**Depends on (read-only, frozen upstream) — all already exist; nothing here is a new runtime capability:**

- `src/twocore/runtime/rt_table.gleam` — the funcref constructors `funcref(ty, closure)` (`:147–149`,
  cell ABI `fn(List(Int)) -> List(Int)`) and `funcref_t(ty, closure)` (`:157–162`, threaded ABI
  `fn(InstanceState, List(Int)) -> #(List(Int), InstanceState)`); the active-segment writers `init_elem`
  (`:177–193`, byte-identical Phase-2 fast path), `init_elem_ref` (`:354–360`) / `t_init_elem_ref`
  (`:560–567`); `set`/`t_set` (`:283–285`/`:480–487`); `table_copy`/`t_table_copy` (`:335–346`/`:538–557`,
  memmove R11); and the **3-guard dispatch** `call_indirect` (`:203–223`, cell) / `t_call_indirect`
  (`:418–439`, threaded). **Read-only** — this unit adds/edits **no** `rt_table` function.
- `src/twocore/runtime/rt_table_ets.gleam` (`TableEts`) and `rt_table_atomics.gleam` (`TableAtomics`) —
  the mutable tiers, which store the **same** `#(FuncType, closure)` funcref and expose the full parity
  surface (`set`/`t_set`, `table_copy`/`t_table_copy`, `init_elem_ref`/`t_init_elem_ref`,
  `call_indirect`/`t_call_indirect`). **Read-only.**
- `src/twocore/runtime/rt_state.gleam` — the **function-import dispatch vector**: `seed_func_imports`
  (`:413–416`, cell) / `set_func_imports` (`:666–670`, threaded), read via `func_import_at(slot)`
  (`:424–430`, cell) / `t_func_import_at(st, slot)` (`:676–680`, threaded). **Read-only.**
- `src/twocore/runtime/link.gleam` — `call_import(closure, args) = closure(args)` (`:236–241`, the 1-ary
  D3a seam, never `apply/3`); the raw-bit `List(Int) ≡ List(Dynamic)` identity coercers `coerce_args_to_ints`
  / `coerce_ints_to_dynamics` (`:56–66`, D5 precedent); `provided_func` (`:141–146`). **Read-only.**
- `src/twocore/runtime/rt_ref.gleam` — the funcref shape `{FuncType, Closure}` (`:15`, `:65–66`; the
  representation `rt_table` also documents at `:13–15`, `:30–33`). **Read-only.**

**Produces:** the runtime differential test module (§3.1–§3.3) proving the acceptance points of §1. It builds
its import-routed funcref **by hand** (`rt_table.funcref(ty, fn(...))`, §3.1) and adds **no production code** —
the adapter seam is frozen to inline (F3), so there is no `link.gleam` helper.

**Unblocks / feeds:** R14-04 (capstone) — the substrate proof that de-risks the `table_copy.wast` flip; and
R14-02 (backend emit) — this differential is the independent runtime-substrate proof that R14-02's
inline-emitted adapter must match (§7).

---

## §3. What it owns + design

**Owned files (D1) — this unit is the sole Phase-14 owner of each. It owns ONLY test files — no `src/` file
(the adapter is emitted inline by R14-02, F3):**

| File | Role |
|---|---|
| `test/twocore/runtime/rt_table_import_funcref_differential_test.gleam` **(new — the primary deliverable)** | The import-routed-funcref differential + guard + `table.copy` + D3a tests (§3.1–§3.3). |
| `test/twocore/runtime/rt_table_reftype_differential_test.gleam` **(existing; re-owned this phase per the overview §4 map)** | Left **untouched** in substance — its Phase-5 op-trace stays the pristine oracle; R14-03 owns it only to keep the differential family under one owner. A single import-routed case *may* be appended here instead of the sibling if the fan-out prefers, but the default keeps the two concerns in separate files. |

**Design principle — the substrate is already complete; this unit only *proves* it.** The entire reason
Phase 14 needs **zero** `rt_table`/`rt_ref`/`rt_state` shape change is that an import-routed funcref is *just
another* build-controlled `#(FuncType, closure)` in a slot (brief §"call_indirect dispatch (why imported
funcref needs ZERO rt_table change)"; R2/R8). This unit constructs exactly that closure by hand, drives it
through the existing dispatch, and shows the six combos agree with each other and with the spec.

### 3.1 The import-routed funcref, built by hand (the modelled adapter)

The differential seeds a **func-import vector** with known test doubles for imported functions, then builds
a funcref whose closure is the **R2 adapter** — capturing only the literal `slot`, resolving its target
through the func-import capability at dispatch time:

- **Cell** — `rt_table.funcref(ty, fn(args) { <dyn→ints>(link.call_import(rt_state.func_import_at(slot),
  <ints→dyn>(args))) })`, i.e. `#(func_type_term(import_ty), adapter)` where the adapter is the exact shape
  R2 specifies: `fun(Args) -> link:call_import(rt_state:func_import_at(Slot), Args)`.
- **Threaded** — `rt_table.funcref_t(ty, fn(st, args) { #(<dyn→ints>(link.call_import(
  rt_state.t_func_import_at(st, slot), <ints→dyn>(args))), st) })` — threads `st` **unchanged** (the callee
  threads its own state inside the routing closure), exactly as R2's threaded adapter
  `fun(St, Args) -> {link:call_import(rt_state:t_func_import_at(St, Slot), Args), St}`.

The `<ints→dyn>` / `<dyn→ints>` boxes are **identity coercions** for the raw-bit `List(Int) ≡ List(Dynamic)`
invariant (D5), modelled on `link.gleam:56–66` (`coerce_ints_to_dynamics` / `coerce_args_to_ints`). They are
two local `@external(erlang, "gleam_stdlib", "identity")` coercers in the test module (the seam is frozen to
inline, F3 — nothing moves into `link.gleam`). The `FuncType` tag is built directly as
`ir.FuncType(import_ty.params, import_ty.results)` — the
**same structural value** `emit_core`'s `func_type_term` renders (R2), so guard 3's structural `==`
(`rt_table.gleam:216`) is exercised faithfully.

**The func-import doubles (the "imported" functions).** Two, at slots 0 and 1, of **distinct** types — so
the differential proves `slot == funcidx` for `slot >= 1` (R4) *and* gives guard 3 a genuine mismatch to
reject:

- slot 0 — `a.add : (i32, i32) -> i32`, type `ii_i = FuncType([TI32, TI32], [TI32])`, closure
  `fn([a, b]) -> [a + b]` (D5 raw-bit ABI, `fn(List(Dynamic)) -> List(Dynamic)`).
- slot 1 — `a.dbl : (i32) -> i32`, type `i_i = FuncType([TI32], [TI32])`, closure `fn([a]) -> [a * 2]`.

Seeded via `rt_state.seed_func_imports([add, dbl])` (cell, after `rt_state.seed(StateDecl(...))`) /
`rt_state.set_func_imports(st, [add, dbl])` (threaded, on the `fresh` record) — the **exact vector**
R14-02's `needs_func_imports` extension (brief §THE 4 MISSING PIECES #3) forces `emit_core` to seed.

### 3.2 The six-combo differential harness (mirrors the existing file's proven pattern)

Reuse the shape of `rt_table_reftype_differential_test.gleam`: three tier drivers (`rt_table` = the
`TablePaged` **oracle**, `rt_table_ets as ets`, `rt_table_atomics as atom`), a `Cell` family and a
`Threaded` family, and a normalized comparable outcome. Because a cell `call_indirect` returns
`Result(List(Int), TrapReason)` while a threaded `t_call_indirect` returns
`Result(#(List(Int), InstanceState), TrapReason)`, **normalize** by projecting away `st`
(`Result(List(Int), TrapReason)`) so all six combos are `should.equal`-comparable. Each scenario:

1. seed the table (size `N`) on the tier, seed the func-import vector on the strategy;
2. write the import-routed funcref into slot(s) via **both** the active-segment path (`init_elem_ref` /
   `t_init_elem_ref`) **and** the mutating path (`set` / `t_set`), asserting the two write paths agree;
3. run the scenario's op(s) + a `call_indirect` / `t_call_indirect`;
4. assert **all six outcomes equal each other** *and* **equal the spec oracle** (§3.3).

### 3.3 What the scenarios assert (all spec-cited — see §5)

- **Dispatch equivalence** (spec: imported fn via `call_indirect` ≡ direct `call` of the import): the
  import-routed funcref at slot `k`, called `call_indirect(k, ii_i, [3, 4])`, yields `Ok([7])` — **equal to
  the direct** `link.call_import(rt_state.func_import_at(0), [3, 4])`.
- **Guard 1 — `UndefinedElement`** on an out-of-range index (`index >= size`), regardless of what any
  in-range slot holds; fires **before** null/type checks (`rt_table.gleam:209–210`).
- **Guard 2 — `UninitializedElement`** on a never-written in-range slot, and on a slot whose import-routed
  funcref was deleted by a `ref.null` write (`rt_table.gleam:212–213`; null = absent key).
- **Guard 3 — `IndirectCallTypeMismatch`** when the call site's expected `FuncType` differs from the stored
  funcref's tag (`rt_table.gleam:216–217`) — store the slot-0 adapter (`ii_i`) and call with `i_i`, and the
  reverse; and confirm the **correctly-typed** dispatch to the slot-1 adapter (`i_i`, `[5]`) yields
  `Ok([10])`, proving the tag distinguishes the two imports.
- **After `table.copy`** (the crux, R6/R7): move the import-routed funcref from `s_src` to `s_dst` with an
  **overlapping** copy (ascending **and** descending, to exercise memmove R11), then assert on the copied
  slot: `call_indirect(s_dst, ii_i, args)` → `Ok([sum])` (reference preserved); the vacated/null-overwritten
  slot → `UninitializedElement`; an index past `size` → `UndefinedElement`; `s_dst` with the wrong type →
  `IndirectCallTypeMismatch`.
- **D3a late-binding** (R2, "captures only the literal slot integer"): with a **stable** stored funcref,
  re-seed the func-import vector so slot 0 now holds a different double (`fn([a,b]) -> [a - b]`); the same
  stored funcref now dispatches to the **new** import — proving the closure holds only `slot` and resolves
  the target through the capability vector, never a baked callee.

### 3.4 The adapter seam is frozen to inline — no `link.gleam` helper (F3)

Open seam #1 (overview §3) is **resolved: inline.** R14-02 emits the Cell/Threaded adapter **inline** in Core
Erlang; `link.gleam` is **not** touched by R14-02 or R14-03. This unit is therefore **pure test-only** — it
builds the import-routed funcref **by hand** with `rt_table.funcref(ty, fn(...))` / `rt_table.funcref_t(...)`
(§3.1) plus the two local identity coercers, and proves that hand-built `#(FuncType, adapter)` slot is exactly
what R14-02's inline adapter must match. There is **one** source of truth for the adapter *shape* (R2 / §3.2),
which this differential and R14-02's inline emission implement independently; the differential is the
executable check that the two agree. No production `link.imported_funcref` / `t_imported_funcref` helper is
introduced, so the byte-identical-default invariant (R5) is trivially untouched (this unit adds no `src/`
code at all).

---

## §4. The work (ordered, buildable)

1. **New test module** `test/twocore/runtime/rt_table_import_funcref_differential_test.gleam` — module
   `////` header stating the invariant (import-routed slot is tier/strategy-uniform + guards fire + copy
   preserves) and the spec anchor. Define `ii_i()`/`i_i()`, the two func-import doubles, the two local
   identity coercers, and the cell/threaded adapter builders (§3.1).
2. **The six-combo harness** (§3.2) — three tier drivers × two strategies, normalized `Out`, the seed +
   write + dispatch loop; reuse the existing file's `seq`/image patterns where helpful.
3. **The scenarios** (§3.3 → §5 tests) — dispatch-equivalence, the three guards, the `table.copy` shuffle,
   and the D3a re-seed; each asserted across all six combos **and** against the spec oracle.
4. `gleam format` → `gleam build` (**zero warnings**) → `gleam test -- twocore/runtime/rt_table_import_funcref_differential_test` (and the base differential file, unchanged) → full `gleam test`.
5. **Verify byte-identical default** — the existing corpus/conformance suite is unchanged (this is a pure
   test-only unit — no `src/` file is touched). Record completion in `state.md`.

---

## §5. Tests (`rt_table_import_funcref_differential_test.gleam`) — spec-cited + adversarial

Objective tests against the **WebAssembly spec** — element segments / instantiation (§4.5.4: `ref.func x`
yields the reference for funcidx `x`; the funcidx space is **unified**, imports occupying `0 .. n-1`, so a
`ref.func` of an *imported* function is a first-class table-storable reference), `call_indirect`
(exec/instructions.html: the three trap conditions evaluated **in order** — undefined element,
uninitialized element, indirect call type mismatch), and `table.copy` (reference-preserving memmove) — **not
change-detectors** (R6/D8). The oracle test (test 7) pins the trace to the spec so a shared bug that made
all tiers agree *wrongly* is still caught.

1. **Dispatch equivalence across all six combos.** For every `{TablePaged, TableEts, TableAtomics} ×
   {Cell, Threaded}`: store the slot-0 adapter (`ii_i`) at slot `k` via **both** the active-segment write
   (`init_elem_ref`/`t_init_elem_ref`) and `set`/`t_set` (asserting the two writes agree), then
   `call_indirect(k, ii_i, [3, 4])`. Assert every combo yields `Ok([7])` **and** each equals the direct
   `link.call_import(rt_state.func_import_at(0), [3, 4])` (cell) / `t_func_import_at` (threaded). *Spec:* an
   imported function reached via `call_indirect` behaves identically to a direct `call` of that import.

2. **Guard 1 — `UndefinedElement` (index in bounds, checked first).** With the import-routed funcref at an
   in-range slot, `call_indirect(size, …)` and `call_indirect(-1, …)` → `Error(UndefinedElement)` across all
   six; asserted to fire **before** the null/type checks (a null in-range slot at a *different* index is not
   consulted). *Spec:* "undefined element."

3. **Guard 2 — `UninitializedElement`.** (a) a never-written in-range slot → `Error(UninitializedElement)`;
   (b) an import-routed funcref written then deleted by a `ref.null` write (`set(k, null_ref())`) reads as
   absent → `Error(UninitializedElement)`. Across all six. *Spec:* "uninitialized element."

4. **Guard 3 — `IndirectCallTypeMismatch` (adversarial: tag vs closure).** Store the slot-0 adapter
   (`ii_i`) and call with expected type `i_i` → `Error(IndirectCallTypeMismatch)`; store the slot-1 adapter
   (`i_i`) and call with `ii_i` → mismatch; and the **correct** dispatch `call_indirect(slot-1 adapter, i_i,
   [5])` → `Ok([10])`. Across all six. *Spec:* "indirect call type mismatch" — guard 3 compares the stored
   funcref's `FuncType` tag (`== func_type_term(import_ty)`), never the closure.

5. **Guards after `table.copy` shuffles the slots (the `table_copy.wast` trap shape, R6/R7).** Build a
   table with the import-routed funcref at `s_src`, a null hole, and a *defined* funcref elsewhere; perform
   an **overlapping** `table.copy` — **both** ascending (`copy(0, 1, 3)`) and descending — that relocates the
   import-routed funcref to `s_dst` and vacates `s_src`. Then across all six: `call_indirect(s_dst, ii_i,
   args)` → `Ok([sum])` (the copied import-routed reference still dispatches to its imported function);
   `call_indirect(vacated/null slot)` → `UninitializedElement`; `call_indirect(index >= size')` →
   `UndefinedElement`; `call_indirect(s_dst, wrong_type)` → `IndirectCallTypeMismatch`. *Spec:* `table.copy`
   is reference-preserving; the guards evaluate on each slot's actual post-copy contents.

6. **D3a late-binding — the adapter captures only the slot (adversarial).** Store the slot-0 adapter; assert
   `call_indirect → Ok([7])`. **Re-seed** the func-import vector so slot 0 now holds `fn([a,b]) -> [a - b]`
   (cell `seed_func_imports` / threaded `set_func_imports`) **without touching the stored funcref**; assert
   the *same* stored funcref now yields `Ok([-1])` for `[3, 4]`. Across all six. *Proves* the closure holds
   only the literal `slot` and resolves its target through the capability vector at dispatch (R2/D3a — never
   a baked `module:atom`).

7. **Spec-oracle anchor (defeats "all tiers agree wrongly").** On the `TablePaged` cell oracle alone, pin
   the exact expected sequence for a hand-written script: `[3,4] → [7]`, the three guards → their exact
   `TrapReason`s in spec order, the post-copy dispatch → the preserved result, and the re-seed → `[-1]`. The
   differential (tests 1–6) proves the *other five combos equal the oracle*; this test proves the *oracle
   equals the spec*.

> **Adversarial fixtures folded into the above:** `slot >= 1` (slot-1 double, R4 `slot == funcidx`);
> distinct func-import types so guard 3 has a real reject; a `ref.null`-deleted slot (guard 2 via absence);
> overlapping **and** descending `table.copy` (memmove R11 in both directions); a defined funcref coexisting
> in the same table as an import-routed one (the mixed-segment shape `table_copy.1.wasm` builds); and the
> re-seed (D3a capture discipline).

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. Spec-cited differential tests (§5, tests 1–7) green — the six-combo dispatch equivalence, the three
   guards on import-routed slots, the `table.copy` shuffle, the D3a re-seed, and the oracle anchor.
2. **Doc comments.** The test module carries a `////` header stating the invariant + spec anchor and `///`
   on each non-trivial helper (the adapter builders, the func-import doubles, the coercers).
3. `gleam format --check src test` clean.
4. `gleam build` **zero warnings** (no unused import/var; this unit adds no `src/` code).
5. The unit suite passes; the **existing** `rt_table_reftype_differential_test.gleam` stays green and
   substantively unchanged; **default emission byte-identical** — no `.core` for any module changes (this is
   a pure test-only unit), and `OptNone ≡ Baseline ≡ Aggressive` across the matrix is undisturbed (R5).
6. Completion recorded in `state.md`.

---

## §7. What it leaves (handoff to downstream)

- **R14-02 (backend emit + driver — the heart):** emit stays **inline** (the seam is frozen to inline, F3),
  and this unit is the independent runtime-substrate proof that R14-02's inline adapter must match. R14-03 has
  proven that a correctly-shaped `#(FuncType, adapter)` in a slot **stores, moves under `table.copy`, and
  dispatches** identically across every tier and strategy and honors all three guards — so R14-02 owns only
  *producing* that slot (the emit arm + the `needs_func_imports` seed), not the runtime behavior of it.
- **R14-04 (capstone):** the differential is the **substrate backstop** behind the `table_copy.wast` flip
  (R6). Because R14-03 shows the runtime is tier/strategy-uniform for import-routed slots, any residual
  `table_copy.wast` failure the capstone measures localizes to **emit/driver** (R14-01/02) — the capstone's
  `corpus/xlink` end-to-end backstop and the measured ~1,080-assert flip build on this guarantee rather than
  re-proving it. The unit-layer guard-after-copy coverage (test 5) is the fine-grained companion to the
  capstone's `assert_trap` conformance asserts.
- **Nothing to the IR / optimizer layers:** this unit binds only to the runtime substrate
  (`rt_table`/`rt_state`/`link`), which is frozen; it does not touch `ir.gleam`, the emit path, or the
  optimizer, and it leaves the funcref value shape `#(FuncType, closure)` exactly as it found it (R5/R8).
