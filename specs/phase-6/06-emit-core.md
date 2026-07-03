# Unit 06 — `emit_core` extension (lower IR4 → Core Erlang: SIMD + memory64 + cross-module dispatch)

> **One owner. Wave A. The deepest single-owner codegen change of Phase 6 — a critical path.**
> Depends on **FREEZES ONLY** — `«IR4-FROZEN»` (the `TV128` ValType, the `ConstV128` Value, the
> `SimdOp` enum + `SimdShape`, the SIMD `Expr` node(s) `Simd`/`SimdShuffle`, the SIMD-memory node(s)
> `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`, the cross-module imported-call node
> `CallImport`, and — expected — **no new `TrapReason`**) + `«RT-SIMD-SIG»` (the `rt_simd.gleam`
> heads, doc-frozen, `todo`-free — the ~236 op names + the SIMD-memory lane-assembly helpers) +
> `«MEM64-RUNTIME»` (the `instance.Binding` page-cap field + the `lower`/`link` `Idx64`-accept
> contract + the `rt_mem` byte-slice/`fresh64` head contract) + `«XLINK»` (the cross-module
> `ProvidedFunc` closure-dispatch contract + the `rt_state` func-import-slot accessor heads), all
> from the keystone (unit 01). You emit the seam **calls** against the frozen heads; the `rt_simd`
> **bodies** are 07, the `rt_mem` memory64/byte-slice **bodies** are 08, and the linker closure
> **construction** is 09. Do **not** serialize behind them — start the day the freezes land. Read
> [`00-overview.md`](00-overview.md) (I1–I8) and [`PROVISIONAL-SURFACE.md`](PROVISIONAL-SURFACE.md)
> first, then the Phase-5 [`RECONCILIATION.md`](../phase-5/RECONCILIATION.md) (R1–R18 still hold) and
> the corresponding Phase-5 unit [`../phase-5/06-emit-core.md`](../phase-5/06-emit-core.md), whose
> structure/depth this doc matches. Analog seam patterns:
> `NumOp → rt_num` (`num_op_name`, `emit_core.gleam:4106`); the `_at` memidx routing
> (`emit_mem_load`, `:1001`); the bulk-op trapping-write disposition (`emit_mem_copy`, `:2329`).

---

## Context

`emit_core` is the backend and the **binding chokepoint** (D3b): it walks an `ir.Module` and
produces a `core_erlang.CModule`, resolving **every** runtime reference through **one** helper,
`seam_call(module, fn_name, args) -> CExpr` (`emit_core.gleam:1473`), which emits
`call '<module>':'<fn_name>'(args)` with `module` a fixed build-controlled runtime atom and
`fn_name` a literal (D3a — no ambient authority, no data-driven `apply(Mod, …)`). Phases 2–5 routed
the stateful ops (`MemLoad`/`MemStore`/`MemSize`/`MemGrow`/`GlobalGet`/`GlobalSet`/`CallIndirect`,
the fourteen reftype/table/bulk-memory ops) and the generated `instantiate/{0,1}` through that
helper, under **two** state strategies — the tier-O `cell` pdict (`NoState`) and the tier-P
`threaded` `rt_state.InstanceState` record (`Threading(cur)`), keyed on `binding.state_strategy`
with the `StateChan` (`:229`) and the state-reaching call-graph closure
(`state_reaching_closure`/`expr_touches_state`, `:701`/`:751`).

The **numeric chokepoint** is the template Phase 6 climbs one level: the ~90 `rt_num` functions hide
behind the small `NumOp`/`ConvOp` enums carried by `Num`/`Convert`, and `emit_num` (`:1445`) maps
each op to its `rt_num` name through the total table `num_op_name` (`:4106`) — the ONE place a
neutral IR op name becomes a concrete runtime function atom. Phase 6's SIMD path is **the same
pattern**: the ~236 standardized SIMD instructions hide behind a `SimdOp` enum carried by a few
`Expr` nodes, and this unit adds `simd_op_name` — the `SimdOp → rt_simd` name table (the binding
chokepoint), exactly analogous to `num_op_name` (I2).

Phase 6 grows the IR for the third time since Phase 2 (I7). Concretely this unit consumes:

- **The `v128` value layer** — a new `ValType` `TV128` and a new `Value` `ConstV128(bytes: BitArray)`
  (exactly 16 little-endian bytes, D5-style raw bits — I1). `v128` is the BEAM's natural fixed-width
  byte container, a `<<_:128>>` binary.
- **The pure SIMD op layer** — a `Simd(op: SimdOp, args: List(Value))` node (pure, lane-wise,
  **no trap, no state** — I3/I6) and a `SimdShuffle(lanes, a, b)` node (16 static byte indices).
- **The SIMD memory layer** — `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`, which are
  **not** pure: they touch linear memory and route through the **bounds-checked `rt_mem` seam**
  (I6/D3a), composed with `rt_simd` lane-assembly helpers.
- **The memory64 runtime** — `MemoryDecl.idx_type ∈ {Idx32, Idx64}` (already frozen since P5-R12);
  Phase 6 makes `lower` **accept** `Idx64` (stop rejecting), so an `Idx64` memory now reaches this
  emitter for the first time. A 32-bit memory stays **byte-identical** (I4/I7).
- **The cross-module imported-function call** — a `CallImport(slot, ty, args)` node (the provisional
  surface's "imported-function `CallDirect` target", finalized as a dedicated node — §E, deviation
  D3): a call across instances, dispatched over a **build-constructed closure capability** the
  linker hands in (I5/D3a), **not** an ambient `apply` of an attacker-chosen `module:atom`.

Growing `ValType`/`Value`/`Expr` breaks every exhaustive match in this file. The keystone lands a
minimal compile-satisfying arm so the tree stays green; **this unit fills the real lowering** for all
of it — through the seams, under **both** state strategies, and **byte-identically** for a
non-SIMD / single-32-bit-memory / no-cross-import module (I7).

## Goal

Lower every new IR4 node to Core Erlang **through the runtime seams** (never a raw term/apply op,
D3a):

1. **SIMD — the chokepoint.** Add `simd_op_name : SimdOp → String` (total; every constructor mapped),
   and lower `Simd(op, args)` to `call '<simd_module>':'<simd_op_name(op)>'(args…)` — the binding
   chokepoint, exactly like `NumOp → rt_num`. Lower `SimdShuffle` to the byte-shuffle head carrying
   its 16 immediates. `Simd`/`SimdShuffle` are **pure, state-neutral, non-trapping** (I3/I6):
   emitted identically under `Cell` and `Threaded` (`cur` flows through unchanged), and — like
   `RefFunc` — they are **not** state-reaching seeds (a SIMD-only-arithmetic function keeps its pure
   Phase-1 arity).
2. **SIMD memory — the compose.** Lower `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane` as a
   **compose** of the **bounds-checked `rt_mem` byte-slice seam** (`load_bytes`/`store_bytes` — the
   trap owner) with **pure `rt_simd` lane-assembly helpers** (splat/extend/zero/replace-lane/
   extract-lane). Every access is bounds-checked → trap `MemoryOutOfBounds` **before any partial
   effect** (H6). State-reaching (join the threaded closure).
3. **memory64 — transparent addressing + the fresh seam.** Thread i64 addresses/offsets/bounds
   through the memory seam. The address operand and (possibly `> 2³²`) offset are already emitted as
   raw bignum `Int`s (§E of P5-06) — the ONE real change is `mem_fresh_term`: an `Idx64` memory seeds
   its handle through a width-carrying `rt_mem` fresh head with the **documented page cap**
   (`binding.mem64_max_pages`); an `Idx32` memory seeds the **byte-identical** Phase-5 `fresh` head.
4. **Cross-module dispatch — the capability.** Lower `CallImport(slot, ty, args)` to a read of the
   handed-in closure from the instance's positional import slot (`rt_state:func_import_at(slot)` /
   `t_func_import_at(St, slot)`) followed by **`apply(Closure, Args)`** — the Erlang `apply/2` fun-
   apply over that closure value — never a 3-arg `apply(Module, Fun, Args)` of a data-derived
   `module:atom` (D3a). State-reaching (reads the closure from instance state; join the threaded
   closure). Render the func-import closure slot in the `FullDecl`.

Every new node must (a) work under **both** `Cell` and `Threaded`, (b) trap fail-closed with **no
partial writes** (H6), and (c) leave a non-SIMD / single-32-bit-memory / no-cross-import module
**byte-identical** to Phase 5 (I7). Extend the D3a structural security-invariant test to prove the
new authority — **both** the SIMD seam and the closure dispatch — is ambient-free. Co-design the
`rt_simd`/`rt_mem`/`rt_state`/`link` call ABIs with 07/08/09 (you emit the calls; they implement the
bodies against the keystone-frozen sigs).

## Files owned (single-owner-additive)

- `src/twocore/backend/emit_core.gleam` — **EXTEND (single owner).** Add: the `emit` arms for `Simd`,
  `SimdShuffle`, `SimdLoad`, `SimdStore`, `SimdLoadLane`, `SimdStoreLane`, and `CallImport`; the
  `simd_op_name`/`simd_shape_name` chokepoint tables; the `ConstV128` arm of `emit_value` and the
  `TV128` arms of `valtype_atom`/`result_width`; the `mem_fresh_term` `idx_type` branch; the
  func-import-slot rendering in `full_decl_term`/`imported_slots` + `count_state_imports` →
  `count_import_slots`; and the descents into the new nodes in `expr_touches_state`,
  `direct_callees`, and `collect_expr`.
- `test/twocore/backend/emit_core_test.gleam` — AST-shape goldens for every new construct (EXTEND).
- `test/twocore/backend/emit_core_security_test.gleam` — the D3a walk over the new authority
  (EXTEND — grow the fixture to exercise SIMD arithmetic, SIMD memory, a second memory, an `Idx64`
  memory, and a cross-module `CallImport`; assert the new seam calls present, `erlang:apply` is the
  2-arg fun-apply only, and no data-driven apply/computed-module call).
- `test/twocore/backend/emit_core_e2e_test.gleam` — hand-built IR4 → build → `instantiate` → invoke
  (EXTEND; green once 07/08/09 land — see Concurrency).

## Deliverables & freeze milestones

**Consumes:**

| Freeze | From | What you take | Stub against meanwhile |
|---|---|---|---|
| `«IR4-FROZEN»` | 01 | `TV128`; `ConstV128(bytes: BitArray)`; `SimdShape` (`I8x16`/`I16x8`/`I32x4`/`I64x2`/`F32x4`/`F64x2`); the `SimdOp` enum (§B — the finalized taxonomy); `Simd(op, args)`; `SimdShuffle(lanes, a, b)`; `SimdLoad(mem, kind, addr, offset)` + `SimdLoadKind`; `SimdStore(mem, addr, value, offset)`; `SimdLoadLane(mem, width, addr, offset, lane, vec)`; `SimdStoreLane(mem, width, addr, offset, lane, vec)`; `CallImport(slot: Int, ty: FuncType, args: List(Value))`; **no new `TrapReason`** (SIMD is total; SIMD memory + memory64 reuse `MemoryOutOfBounds`; unlinkable is a link error, not a runtime trap). | The keystone's minimal `emit` arm keeps the tree green — replace it with the real lowering. |
| `«RT-SIMD-SIG»` | 01 (bodies 07) | The `rt_simd` heads: the ~236 lane ops named by `simd_op_name` (§B); the byte-slice lane-assembly helpers the SIMD-memory compose calls (`load_splat_{8,16,32,64}`, `load_extend_<shape>_{s,u}`, `load_zero_{32,64}`, `replace_lane_bytes_{8,16,32,64}`, `extract_lane_bytes_{8,16,32,64}` — §C, exact names co-designed with 07). All PURE (no trap, no state, no `rt_mem` import). | Emit calls against the *signatures*; e2e waits on 07. |
| `«MEM64-RUNTIME»` | 01 (bodies 08) | `instance.Binding.mem64_max_pages: Int` (the documented page cap, `safe_default` sets it — 08 pins the exact constant + spec citation); the two `rt_mem` **fresh** heads (`fresh`/`fresh64`, or `fresh` + an `idx_type` atom — §D); the `rt_mem` **byte-slice** heads `load_bytes`/`store_bytes` (+ `_at` + `t_*` twins, §C) returning `Result(BitArray,_)`/`Result(Nil,_)`; the `lower` `Idx64`-accept contract (05 stops rejecting). | Emit `fresh64`/`load_bytes`/`store_bytes` against the sigs; e2e waits on 08. |
| `«XLINK»` | 01/09 | `link.Provided` gains the closure-carrying `ProvidedFunc(ty, closure)` (09 finalizes; §E) + the `link:provided_func_closure` extractor; `rt_state` gains the `func_imports` vector in `FullDecl`/`InstanceState` + the accessors `func_import_at(slot)` / `t_func_import_at(st, slot)` (frozen todo-free by 01, R5-style; bodies 09); the cross-module import → `CallImport` lowering contract (05 produces it). | You render the `func_imports` slot term + emit `func_import_at` + `apply(Closure,…)`; the closure construction + `link_imports` extension is 09. |

**Produces (no downstream freeze; three load-bearing conventions):**

1. the **`SimdOp → rt_simd` name table** (`simd_op_name`) — the single place a neutral SIMD op name
   becomes a concrete `rt_simd` function atom; 07 binds its ~236 heads to exactly these names;
2. the **SIMD-memory compose ABI** — a bounds-checked `rt_mem` byte-slice call (16/8/N bytes) +
   a pure `rt_simd` lane-assembly call — which 07/08 bind their byte-slice/assembly signatures to;
3. the **cross-module closure-dispatch shape** — the closure lives in a positional `func_imports`
   slot of the instance state, read via `rt_state:func_import_at`, applied via `apply/2` — which 09
   binds its `Provided` closure + `func_imports` seeding to.

**Out of scope (do NOT build here):** the `rt_simd` **bodies** (07 — you emit calls against the
frozen heads); the `rt_mem` memory64/byte-slice **bodies** + the page-cap constant + the
atomics/nif fail-closed gate (08); the linker `Provided` closure **construction** +
`link_imports`-for-functions + the `(register)` registry (09 — you render the slot + emit the apply);
**decode/validate/lower** of the new ops (03/04/05 — you consume IR4, you do not produce it); the
`.ir` grammar delta (02); `ir/effect.gleam` SIMD classification (01/02); the **conformance**
expansion + the residual audit (10/11). **Relaxed-SIMD is a separate deferred proposal (I8).**

## Depends on (freeze milestones)

Start behind `«IR4-FROZEN»` + `«RT-SIMD-SIG»` (the SIMD path, §B/§C) and `«MEM64-RUNTIME»` (§D).
`«XLINK»` gates only the cross-module path (§E) and the `full_decl_term` func-import rendering; the
SIMD + memory64 lowerings need only the IR + RT-sig + mem64 freezes. The three tracks are independent
inside this unit — begin with §B (the broadest, purely-additive surface) the day `«IR4-FROZEN»` +
`«RT-SIMD-SIG»` land.

---

## A. The dispatch extension + the traversal/classification closure

### A.1 The seven new `emit` arms

The main dispatcher `emit(expr, cont, sc, state, ctx)` (`emit_core.gleam:826`) gains one arm per new
node, each delegating to a per-op lowering that honors **both** the continuation `cont` and the state
channel `sc`. Sketch:

```gleam
// ── SIMD value/arithmetic layer (I2/I3) — PURE, state-neutral, NON-trapping ──
ir.Simd(op, args) -> emit_simd(op, args, cont, sc, state, ctx)
ir.SimdShuffle(lanes, a, b) -> emit_simd_shuffle(lanes, a, b, cont, sc, state, ctx)
// ── SIMD memory layer (I6) — state-reaching; rt_mem bounds-check ∘ rt_simd assembly ──
ir.SimdLoad(mem, kind, addr, offset) ->
  emit_simd_load(mem, kind, addr, offset, cont, sc, state, ctx)
ir.SimdStore(mem, addr, value, offset) ->
  emit_simd_store(mem, addr, value, offset, cont, sc, state, ctx)
ir.SimdLoadLane(mem, width, addr, offset, lane, vec) ->
  emit_simd_load_lane(mem, width, addr, offset, lane, vec, cont, sc, state, ctx)
ir.SimdStoreLane(mem, width, addr, offset, lane, vec) ->
  emit_simd_store_lane(mem, width, addr, offset, lane, vec, cont, sc, state, ctx)
// ── cross-module dispatch (I5) — state-reaching; apply the handed-in closure capability ──
ir.CallImport(slot, ty, args) -> emit_call_import(slot, ty, args, cont, sc, state, ctx)
```

The `TermOp` arm stays `Error(UnsupportedNode("term_op"))` (still a later-phase deferral). The four
existing memory arms are **unchanged** in destructuring — memory64 is handled entirely at the
`instantiate`/`fresh` seam (§D), not at the op sites.

### A.2 `emit_value` / `valtype_atom` / `result_width` grow one arm each

- **`emit_value`** (`:2821`) gains `ConstV128(bytes) -> core_binary_bytes(bytes)` — the exact 16-byte
  little-endian binary literal (`#{ … }#`, one 8-bit segment per byte, reusing the verified
  `core_binary_bytes`, `:2929`). A `v128.const` is thus a **pure literal** (not a `call`), so it is
  const-foldable (a v128 global init) and D3a-trivially-clean — the same treatment `ConstF32(bits)`
  gets for a raw float bit pattern (D5). Validate/decode guarantee the byte length is exactly 16.
- **`valtype_atom`** (`:2908`) gains `TV128 -> "v128"` — the canonical type atom inside a
  `func_type_term` (needed only if a v128 param/result appears in a `call_indirect`/`CallImport`
  type tag; self-consistent — only its use on both sides of the `rt_table` `==` guard matters).
- **`result_width`** (`:1568`) gains `TV128 -> 128` for exhaustiveness, documented **unreachable**:
  `TV128` is never a scalar `MemLoad` result — a `v128.load` is a `SimdLoad`, not a `MemLoad`, and
  routes through the byte-slice seam (§C), never `result_width`.

### A.3 The three traversal functions MUST descend into every new node

Three traversals over `Expr` live in this file and **break** the moment `Expr` grows; the keystone's
minimal arm keeps them compiling but *inert*. This unit gives them the real behavior — getting any
one wrong silently corrupts threaded codegen or gensym uniqueness:

- **`expr_touches_state`** (`:751`) — the state-reaching **seed** test.
  - **Return `True`** for **`SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`** (they read/write
    linear memory, exactly like `MemLoad`/`MemStore`) and for **`CallImport`** (it reads the closure
    capability from the instance state's `func_imports` vector). Under `Threaded` a function
    containing one threads the record.
  - **Return `False`** for **`Simd`/`SimdShuffle`** — a pure lane op reaches no record; it is
    produced from operand values and a compile-time op tag, exactly like `Num`/`RefFunc`. This is the
    **I7-neutral classification**: a function that only does v128 arithmetic keeps its Phase-1 pure
    arity `'f'/n` (mis-classifying it as state-reaching would needlessly thread the record — correct
    but a shape regression that breaks byte-identity for a SIMD-arithmetic-only body; mis-classifying
    a SIMD-memory op as pure would emit a *threaded* body reading `St` that was never threaded in — a
    compile error / miscompile).
- **`direct_callees`** (`:796`) — the `CallDirect` edge scan for the state-reaching fixpoint. **None**
  of the new nodes contain a `CallDirect` (their operands are atomic `Value`s; `CallImport`'s target
  is a **closure**, not a static local edge — the callee lives in another instance, reached through
  the table-of-imports, not the `CallDirect` graph, exactly as a `CallIndirect` target is). So each
  new arm returns `acc` unchanged — but must be **matched** so the wildcard does not silently swallow
  a future nested body. (A `CallImport` still makes its containing function state-reaching, via
  `expr_touches_state`'s seed, **not** a `direct_callees` edge — the caller reads the closure from the
  record; it does not statically call a same-module function.)
- **`collect_expr`** (`:4301`) — the gensym-reservation scan (**exhaustive, no wildcard**). Every new
  arm must fold in its operand `Value`s: `Simd(_, args) -> collect_values(args, acc)`;
  `SimdShuffle(_, a, b) -> collect_value(b, collect_value(a, acc))`;
  `SimdLoad(_, _, addr, _) -> collect_value(addr, acc)`;
  `SimdStore(_, addr, value, _) -> collect_value(value, collect_value(addr, acc))`;
  `SimdLoadLane(_, _, addr, _, _, vec) -> collect_value(vec, collect_value(addr, acc))`;
  `SimdStoreLane(_, _, addr, _, _, vec) -> collect_value(vec, collect_value(addr, acc))`;
  `CallImport(_, _, args) -> collect_values(args, acc)`. `ConstV128` carries no `Var` (it is a
  literal — `collect_value` already returns `acc` for a non-`Var`). A missed `Var` lets a gensym
  collide with an IR name → a silently wrong body.

The `state_reaching_closure` fixpoint (`:701`) is otherwise unchanged: seeding on the SIMD-memory +
`CallImport` nodes and closing over `CallDirect` gives exactly the set of functions that must thread
the record under `Threaded`. A function that only builds/does v128 values stays **pure** (`NoState`),
preserving its Phase-1 arity — the I7 neutrality for SIMD-arithmetic code.

---

## B. SIMD value + pure lane-op lowering (`rt_simd` — the chokepoint)

`v128` is the **low-level fixed-width value** (I1): a `<<_:128>>` binary at runtime, holding the raw
16 little-endian lane bytes (D5). The ~236 standardized SIMD instructions collapse to on the order of
~110 `SimdOp` constructors (shape-tagged where uniform; individually named where shape-specific);
`rt_simd` still has ~236 concrete heads (shape × op). **This unit owns the neutral-name → runtime-name
map; 07 owns the bodies.** The emitter never enumerates lane semantics — it only routes.

### B.1 The pure-op emitter

```gleam
/// Lower a pure lane-wise `Simd(op, args)` through `binding.simd_module` (the SIMD chokepoint).
/// PURE, state-neutral, NON-trapping (I3/I6): a bare `call '<simd>':'<simd_op_name(op)>'(args…)`
/// whose single result (a v128 binary, or a scalar for extract-lane / any_true / all_true /
/// bitmask) is passed to `cont`. Under `Threading(cur)` the record flows through UNCHANGED — no
/// v128 op reaches the state. `args` arity already matches the op (validate/lower guarantee it), so
/// the operands are spread exactly like `emit_num`. Lane immediates (`extract`/`replace`) ride as
/// trailing `CInt`s via `simd_immediates(op)`.
fn emit_simd(op, args, cont, sc, state, ctx) {
  let call =
    seam_call(
      ctx.binding.simd_module,
      simd_op_name(op),
      list.append(list.map(args, emit_value), simd_immediates(op)),
    )
  apply_cont(cont, [call], sc, state, ctx)
}
```

This is `emit_num` one level up (`:1445`) — with two differences: (1) **nothing is trapping**
(`is_trapping` has no SIMD analogue — I3 guarantees the pure SIMD surface never traps; the only SIMD
trap is a memory-bounds fault on a load/store, §C), so there is no `case`-and-`raise`; (2) the two
lane-immediate ops append their static index. Worked example, `i32x4.add`:

```erlang
%% Simd(SAdd(I32x4), [Var("a"), Var("b")])  →
call 'twocore@runtime@rt_simd':'i32x4_add'(a, b)
```

and `f32x4.extract_lane 2` (yields the lane's f32 raw bits) and `i8x16.replace_lane 3`:

```erlang
%% Simd(SExtractLane(F32x4, 2), [Var("v")])       →  call '…rt_simd':'f32x4_extract_lane'(v, 2)
%% Simd(SReplaceLane(I8x16, 3), [Var("v"), Var("x")]) →  call '…rt_simd':'i8x16_replace_lane'(v, x, 3)
```

`simd_module` is a new `binding.simd_module` field (default `"twocore@runtime@rt_simd"`, set by
`safe_default`/`unsafe`) — recommended over a fixed atom because I3/I8 explicitly reserve a **tier-N
real-SIMD NIF** behind the same interface: a `Binding` field is the tier-swap seam (exactly as
`mem_module` swaps the paged/atomics/nif memory tiers, G5), so a future NIF binding is a
`*_module` name change with **no** `emit_core` edit. The security allow-set gains `binding.simd_module`
(a fixed build-controlled atom — D3a-clean). *(Seam flagged §Open questions — the keystone owns
`Binding`.)*

### B.2 `simd_shape_name` — the shape prefix

```gleam
/// The canonical lane-shape prefix for a `SimdShape` (`"i8x16"`/`"i16x8"`/`"i32x4"`/`"i64x2"`/
/// `"f32x4"`/`"f64x2"`) — the analogue of `iw`/`fw` for `NumOp`. Total.
fn simd_shape_name(s: SimdShape) -> String {
  case s {
    I8x16 -> "i8x16"   I16x8 -> "i16x8"   I32x4 -> "i32x4"
    I64x2 -> "i64x2"   F32x4 -> "f32x4"   F64x2 -> "f64x2"
  }
}
```

### B.3 `simd_op_name` — the total `SimdOp → rt_simd` table (the chokepoint)

The complete enumeration follows, grouped by family, grounded in the **fixed-width SIMD instruction
set** (`https://webassembly.github.io/spec/core/`; the `simd/*.wast` suite is the oracle). The
naming discipline mirrors `rt_num`: `<shape>_<snake_op>`, `v128_<op>` for the shape-agnostic bitwise
ops, and a fully-spelled name for each shape-specific conversion/widen/narrow. **07 must bind exactly
these heads.** (Which shapes each shape-tagged constructor legally accepts — e.g. `SMul` excludes
`i8x16`, `SAvgrU` is `i8x16`/`i16x8` only, `SMinS/MaxS` exclude `i64x2` — is enforced **upstream** by
validate/lower; `simd_op_name` maps whatever constructor+shape it is handed. The parenthetical shape
restrictions below are documentation, not a runtime guard.)

**Lane-uniform integer arithmetic** (`shape ∈ integer shapes`):

| `SimdOp` | `rt_simd` name | Shapes | Spec (per lane, two's-complement at lane width — I3/§9.1) |
|---|---|---|---|
| `SAdd(s)` | `<s>_add` | i8x16/i16x8/i32x4/i64x2 | wrapping add |
| `SSub(s)` | `<s>_sub` | same | wrapping sub |
| `SMul(s)` | `<s>_mul` | i16x8/i32x4/i64x2 (no `i8x16.mul`) | wrapping mul |
| `SNeg(s)` | `<s>_neg` | i8x16/i16x8/i32x4/i64x2 | wrapping negate |
| `SAbs(s)` | `<s>_abs` | same | absolute value (wrapping at `INT_MIN`) |
| `SMinS(s)`/`SMinU(s)` | `<s>_min_s`/`<s>_min_u` | i8x16/i16x8/i32x4 | signed/unsigned min |
| `SMaxS(s)`/`SMaxU(s)` | `<s>_max_s`/`<s>_max_u` | i8x16/i16x8/i32x4 | signed/unsigned max |
| `SAvgrU(s)` | `<s>_avgr_u` | i8x16/i16x8 | rounding average `(a+b+1)>>1` |
| `SShl(s)` | `<s>_shl` | i8x16/i16x8/i32x4/i64x2 | shift left, count masked `mod` lane width |
| `SShrS(s)`/`SShrU(s)` | `<s>_shr_s`/`<s>_shr_u` | same | arith/logical shift right, count masked |

**Lane-uniform comparisons** (`→ a v128 mask`, per lane all-ones/all-zeros):

| `SimdOp` | `rt_simd` name | Shapes |
|---|---|---|
| `SEq(s)`/`SNe(s)` | `<s>_eq`/`<s>_ne` | i8x16/i16x8/i32x4/i64x2 |
| `SLtS(s)`/`SLtU(s)` | `<s>_lt_s`/`<s>_lt_u` | i8x16/i16x8/i32x4 (u); i64x2 has `lt_s` only |
| `SLeS(s)`/`SLeU(s)` | `<s>_le_s`/`<s>_le_u` | same (i64x2 signed only) |
| `SGtS(s)`/`SGtU(s)` | `<s>_gt_s`/`<s>_gt_u` | same |
| `SGeS(s)`/`SGeU(s)` | `<s>_ge_s`/`<s>_ge_u` | same |

**v128 bitwise** (shape-agnostic):

| `SimdOp` | name | | `SimdOp` | name |
|---|---|---|---|---|
| `VNot` | `v128_not` | | `VAndNot` | `v128_andnot` |
| `VAnd` | `v128_and` | | `VOr` | `v128_or` |
| `VXor` | `v128_xor` | | `VBitselect` | `v128_bitselect` |

**Boolean reductions / mask:**

| `SimdOp` | `rt_simd` name | Result | Shapes |
|---|---|---|---|
| `VAnyTrue` | `v128_any_true` | i32 0/1 | over the whole v128 |
| `SAllTrue(s)` | `<s>_all_true` | i32 0/1 | i8x16/i16x8/i32x4/i64x2 |
| `SBitmask(s)` | `<s>_bitmask` | i32 | i8x16/i16x8/i32x4/i64x2 |

**Lane access / build** (splat takes a scalar; extract yields a scalar; replace takes v128+scalar —
the lane index rides as a trailing `CInt` via `simd_immediates`):

| `SimdOp` | `rt_simd` name | Shapes |
|---|---|---|
| `SSplat(s)` | `<s>_splat` | all 6 |
| `SExtractLaneS(s,l)`/`SExtractLaneU(s,l)` | `<s>_extract_lane_s`/`_u` | i8x16/i16x8 (signed+unsigned) |
| `SExtractLane(s,l)` | `<s>_extract_lane` | i32x4/i64x2/f32x4/f64x2 (plain) |
| `SReplaceLane(s,l)` | `<s>_replace_lane` | all 6 |

**Float-lane ops** (`shape ∈ F32x4/F64x2`; IEEE-754-exact, f32 single-rounding, spec NaN/`-0.0` — I3):

| `SimdOp` | `rt_simd` name | | `SimdOp` | `rt_simd` name |
|---|---|---|---|---|
| `FAdd(s)` | `<s>_add` | | `FMin(s)` | `<s>_min` |
| `FSub(s)` | `<s>_sub` | | `FMax(s)` | `<s>_max` |
| `FMul(s)` | `<s>_mul` | | `FPMin(s)` | `<s>_pmin` |
| `FDiv(s)` | `<s>_div` | | `FPMax(s)` | `<s>_pmax` |
| `FNeg(s)` | `<s>_neg` | | `FCeil(s)` | `<s>_ceil` |
| `FAbs(s)` | `<s>_abs` | | `FFloor(s)` | `<s>_floor` |
| `FSqrt(s)` | `<s>_sqrt` | | `FTrunc(s)` | `<s>_trunc` |
| `FEq/FNe/FLt/FLe/FGt/FGe(s)` | `<s>_eq/ne/lt/le/gt/ge` | | `FNearest(s)` | `<s>_nearest` |

**Conversions / narrow / widen / extend** (shape-specific — every one enumerated):

| `SimdOp` | `rt_simd` name |
|---|---|
| `I32x4TruncSatF32x4S` / `I32x4TruncSatF32x4U` | `i32x4_trunc_sat_f32x4_s` / `_u` |
| `I32x4TruncSatF64x2SZero` / `I32x4TruncSatF64x2UZero` | `i32x4_trunc_sat_f64x2_s_zero` / `_u_zero` |
| `F32x4ConvertI32x4S` / `F32x4ConvertI32x4U` | `f32x4_convert_i32x4_s` / `_u` |
| `F32x4DemoteF64x2Zero` | `f32x4_demote_f64x2_zero` |
| `F64x2ConvertLowI32x4S` / `F64x2ConvertLowI32x4U` | `f64x2_convert_low_i32x4_s` / `_u` |
| `F64x2PromoteLowF32x4` | `f64x2_promote_low_f32x4` |
| `I8x16NarrowI16x8S` / `I8x16NarrowI16x8U` | `i8x16_narrow_i16x8_s` / `_u` |
| `I16x8NarrowI32x4S` / `I16x8NarrowI32x4U` | `i16x8_narrow_i32x4_s` / `_u` |
| `I16x8ExtendLowI8x16S` / `…HighI8x16S` / `…LowI8x16U` / `…HighI8x16U` | `i16x8_extend_low_i8x16_s` / `_high_…_s` / `_low_…_u` / `_high_…_u` |
| `I32x4ExtendLow/HighI16x8S/U` (×4) | `i32x4_extend_{low,high}_i16x8_{s,u}` |
| `I64x2ExtendLow/HighI32x4S/U` (×4) | `i64x2_extend_{low,high}_i32x4_{s,u}` |

**Extended-multiply / pairwise / dot / q15 / popcnt / swizzle:**

| `SimdOp` | `rt_simd` name |
|---|---|
| `I16x8ExtMulLow/HighI8x16S/U` (×4) | `i16x8_extmul_{low,high}_i8x16_{s,u}` |
| `I32x4ExtMulLow/HighI16x8S/U` (×4) | `i32x4_extmul_{low,high}_i16x8_{s,u}` |
| `I64x2ExtMulLow/HighI32x4S/U` (×4) | `i64x2_extmul_{low,high}_i32x4_{s,u}` |
| `I16x8ExtAddPairwiseI8x16S/U` (×2) | `i16x8_extadd_pairwise_i8x16_{s,u}` |
| `I32x4ExtAddPairwiseI16x8S/U` (×2) | `i32x4_extadd_pairwise_i16x8_{s,u}` |
| `I32x4DotI16x8S` | `i32x4_dot_i16x8_s` |
| `I16x8Q15MulrSatS` | `i16x8_q15mulr_sat_s` |
| `I8x16Popcnt` | `i8x16_popcnt` |
| `I8x16Swizzle` | `i8x16_swizzle` (dynamic: 2 v128 args, OOB index → 0) |

`simd_immediates(op)` returns `[CInt(lane)]` for `SExtractLane{,S,U}`/`SReplaceLane`, and `[]` for
every other op (the lane index rides **last**, after the value operands — a convention pinned with
07; §Open questions). All other ops carry their operands only in `args`.

### B.4 `SimdShuffle` — the 16-immediate byte shuffle

`i8x16.shuffle` selects 16 bytes from the 32-byte concatenation `a ++ b` by 16 compile-time indices
(each `0..31`), so the indices are an **immediate**, not runtime data — they ride as a Core list:

```gleam
/// Lower `SimdShuffle(lanes, a, b)` (`i8x16.shuffle`) — PURE, state-neutral. The 16 immediate
/// indices (each 0..31, validated upstream) ride as a proper Core list AFTER the two v128 operands:
/// `call '<simd>':'i8x16_shuffle'(A, B, [l0,…,l15])`. `rt_simd` selects byte `lanes[i]` from
/// `A ++ B`. Cite the SIMD spec `i8x16.shuffle`.
fn emit_simd_shuffle(lanes, a, b, cont, sc, state, ctx) {
  let call =
    seam_call(ctx.binding.simd_module, "i8x16_shuffle", [
      emit_value(a), emit_value(b), core_list(list.map(lanes, CInt)),
    ])
  apply_cont(cont, [call], sc, state, ctx)
}
```

`i8x16.swizzle` (dynamic indices, OOB → 0) is by contrast a `Simd(I8x16Swizzle, [a, idx])` — its
index vector is a **runtime v128**, so it is an ordinary two-operand pure op (§B.3), not a shuffle
immediate.

---

## C. SIMD memory lowering (`rt_mem` bounds-check ∘ `rt_simd` lane-assembly)

The SIMD-memory family is the **only** trapping SIMD surface (I3/I6). Each op is a **compose**: the
**bounds check + the byte move live in `rt_mem`** (the trap owner — a `MemoryOutOfBounds` fault
before any partial read/write, H6), and the **lane assembly lives in `rt_simd`** (pure, total). The
emitter sequences them. This is the deliberate division the provisional surface §E fixes: `rt_mem`
owns the check, `rt_simd` owns the lanes, `emit_core` owns the compose.

### C.1 The `rt_mem` byte-slice seam (co-designed with 08)

Two new `rt_mem` heads carry a **raw byte slice** (unlike the existing numeric `load`/`store`, which
carry an `Int`), keyed by a byte count `n ∈ {1, 2, 4, 8, 16}`:

- `load_bytes(N, Addr, Off) -> Result(BitArray, MemoryOutOfBounds)` — read `N` bytes at
  `ea = unsigned(Addr) + Off`, trapping if `ea + N > byte_len` (**no partial read**). `+ _at`
  (leading memidx) + `t_load_bytes`/`t_load_bytes_at` twins.
- `store_bytes(N, Addr, Off, Bytes) -> Result(Nil, MemoryOutOfBounds)` — write the `N`-byte `Bytes`,
  trapping **before any write** if `ea + N > byte_len`. `+ _at` + `t_*` twins.

Memidx routing reuses the `_at` convention (§D of P5-06): index 0 → the un-indexed head; index ≥1 →
`load_bytes_at`/`store_bytes_at` with a leading memidx. Because a SIMD module is **not** byte-identical
to Phase 5 anyway (it has a `v128`), there is no P5 golden to preserve here — the 0/≥1 split is chosen
purely for **consistency** with the scalar mem seam. memory64 is transparent (§D): `Addr` is the raw
i64 bit pattern, `Off` a bignum `CInt`; `rt_mem` reads the width from the handle.

### C.2 The `rt_simd` lane-assembly helpers (co-designed with 07)

Pure, total, `rt_mem`-free helpers that turn a raw byte slice into (or a lane of a v128 out of) the
value:

- `load_splat_{8,16,32,64}(Slice) -> v128` — broadcast the `N`-byte scalar into every lane.
- `load_extend_<shape>_{s,u}(Slice8) -> v128` — sign/zero-extend eight `N`-bit lanes to the wider
  shape (`i16x8_extend_i8x16` naming per the `load8x8`/`16x4`/`32x2` families; exact head names with
  07).
- `load_zero_{32,64}(Slice) -> v128` — place the `N`-bit scalar in the low lane, zero the rest.
- `replace_lane_bytes_{8,16,32,64}(Vec, Lane, Slice) -> v128` — write the `N`-byte `Slice` into lane
  `Lane`.
- `extract_lane_bytes_{8,16,32,64}(Vec, Lane) -> BitArray` — read lane `Lane` as an `N`-byte slice.

### C.3 The four SIMD-memory emitters

`SimdLoadKind` (provisional) is `V128 | Splat(width) | Extend(from_shape, signed) | Zero(width)`.

| IR node | `rt_mem` (bounds check) | `rt_simd` (assembly) | Disposition |
|---|---|---|---|
| `SimdLoad(m, V128, a, o)` (`v128.load`) | `load_bytes(16,A,O)` | none — the 16 bytes **are** the v128 | trapping value → 1 value (read-only) |
| `SimdLoad(m, Splat(w), a, o)` | `load_bytes(w/8,A,O)` | `load_splat_<w>(Slice)` | trapping slice → assemble → 1 value |
| `SimdLoad(m, Extend(sh,sg), a, o)` | `load_bytes(8,A,O)` | `load_extend_<sh>_<sg>(Slice)` | trapping slice → assemble → 1 value |
| `SimdLoad(m, Zero(w), a, o)` | `load_bytes(w/8,A,O)` | `load_zero_<w>(Slice)` | trapping slice → assemble → 1 value |
| `SimdStore(m, a, v, o)` (`v128.store`) | `store_bytes(16,A,O,V)` | none — the v128 **is** the 16 bytes | trapping zero-effect |
| `SimdLoadLane(m, w, a, o, l, v)` | `load_bytes(w/8,A,O)` | `replace_lane_bytes_<w>(V,L,Slice)` | trapping slice → assemble → 1 value |
| `SimdStoreLane(m, w, a, o, l, v)` | `store_bytes(w/8,A,O,Slice)` | `extract_lane_bytes_<w>(V,L)` (first) | assemble slice → trapping zero-effect |

**The plain-load / plain-store shapes** reuse the verified Phase-2 dispositions exactly. `v128.load`
is `emit_trapping_result` over `load_bytes(16,…)` (the unwrapped `{ok, Bytes}` slice **is** the v128
result — 1 value, read-only, `cur` unchanged under `Threaded`, like `MemLoad`). `v128.store` is
`trapping_effect` + `emit_zero_effect` (cell) / `emit_threaded_record_effect` (threaded) over
`store_bytes(16,…)` (like `MemStore`).

**The assembling loads** (splat/extend/zero/load-lane) bind the checked slice, then feed it to the
pure assembly helper as the produced value:

```erlang
%% SimdLoad(0, Splat(32), Var("a"), 4)  under Cell  →
let <slice> =
    case call '…rt_mem':'load_bytes'(4, a, 4) of
      <{'ok', b}> when 'true' -> b
      <{'error', e}> when 'true' -> call '…rt_trap':'raise'(e)
    end
in <cont with> call '…rt_simd':'load_splat_32'(slice)
```

i.e. `emit_trapping_result` reduces `load_bytes` to the bound `slice`, and the continuation's value
is `rt_simd:load_splat_32(slice)` — a pure assembly. `SimdLoadLane` threads `vec` in as the first
assembly argument. This keeps the bounds trap **strictly before** any lane work (H6): if `load_bytes`
faults, the `rt_simd` call is never reached.

**`SimdStoreLane`** runs the pure extract **first** (no memory touched), then the trapping store:

```erlang
%% SimdStoreLane(0, 16, Var("a"), 0, 2, Var("v"))  under Cell  →
let <slice> = call '…rt_simd':'extract_lane_bytes_16'(v, 2)
in let <_> =
     case call '…rt_mem':'store_bytes'(2, a, 0, slice) of
       <{'ok', _}> when 'true' -> 'ok'
       <{'error', e}> when 'true' -> call '…rt_trap':'raise'(e)
     end
   in <cont disposing zero values>
```

The extract is pure/total, so ordering it before the bounds-checked store is sound (no observable
effect precedes the trap). Under `Threaded`, the store rebinds `cur` (record-rebind effect, like
`MemStore`); under `Cell`, it is a zero-result ordered effect.

**Spec grounding** (the fixed-width SIMD memory family): `v128.load`/`store`, `v128.load{8,16,32,64}_
splat`, `v128.load{8x8,16x4,32x2}_{s,u}` (extending), `v128.load{32,64}_zero`, and
`v128.load/store{8,16,32,64}_lane` all take a `memarg` (offset + align — **alignment is a validation
hint only, never affects semantics or the effective address**) and are **little-endian** lane-exact.
Every one traps `MemoryOutOfBounds` iff the accessed byte range exceeds the memory's current size —
the identical eager, no-partial-effect rule the scalar `MemLoad`/`MemStore` obey (H6), now owned by
`rt_mem.load_bytes`/`store_bytes`, not the emitter. The emitter passes the operand `Value`s and the
static `mem`/`width`/`lane` immediates straight through — **no pre-masking, no pre-add, no
pre-check** (that would duplicate and could contradict the security boundary).

---

## D. memory64 — i64 addressing through the mem seam (32-bit byte-identical)

memory64's runtime lands (I4/R12): `lower` now **accepts** `Idx64` (stops emitting
`Memory64Unsupported`), so an `Idx64` `MemoryDecl` reaches this emitter for the first time. The
governing fact — established in P5-06 §E.3 and unchanged — is that **the op sites need no change**:
`emit_core` already passes the address operand and the (possibly `> 2³²`) offset as raw bignum `Int`s
(`emit_value(addr)` + `CInt(offset)`), and `rt_mem` computes `ea = unsigned(addr) + offset` as a
bignum and traps iff `ea + bytes > byte_len` (no wrap — the runtime's job). The memory's `idx_type`
travels **in the state handle**, so `rt_mem` reads the width from the memory it routes to, not from
an emitter argument. Therefore `MemLoad`/`MemStore`/`MemSize`/`MemGrow`/`MemFill`/`MemCopy`/`MemInit`
and the SIMD-memory ops (§C) are **all unchanged** for a 64-bit memory — the addr/offset/count
operands are already width-agnostic bignums, and `memory.size`/`grow` already return a plain `Int`
page count (whose i32-vs-i64 WASM result type is a lower/validate concern, not an emit one).

### D.1 The ONE real change: `mem_fresh_term` seeds the width + the cap

The single memory64 obligation on this unit is at the **`instantiate` seed** — the memory handle must
be born knowing its address width and (for `Idx64`) the documented page cap. `mem_fresh_term`
(`:3281`) currently emits, for every memory, the byte-identical `rt_mem:fresh(Min, MaxOpt, SafeCap)`.
It grows one branch on `m.idx_type`:

```gleam
/// The `rt_mem` handle-seed term for a DEFINED memory. `Idx32` → the BYTE-IDENTICAL Phase-5
/// `fresh(Min, MaxOpt, SafeCap)` head (I7 — a 32-bit memory is unchanged). `Idx64` → the new
/// `fresh64(Min, MaxOpt, Mem64Cap)` head: a 64-bit-addressed memory bounded by the documented,
/// spec-aligned page cap `binding.mem64_max_pages` (08 pins the constant + its citation — I4).
/// The paged backend grows on demand, so the cap is a TRAP BOUNDARY, not a reservation.
fn mem_fresh_term(m: ir.MemoryDecl, ctx: Ctx) -> CExpr {
  case m.idx_type {
    ir.Idx32 ->
      seam_call(ctx.binding.mem_module, "fresh", [
        CInt(m.min_pages), option_int_term(m.max_pages), CInt(ctx.binding.safe_max_pages),
      ])
    ir.Idx64 ->
      seam_call(ctx.binding.mem_module, "fresh64", [
        CInt(m.min_pages), option_int_term(m.max_pages), CInt(ctx.binding.mem64_max_pages),
      ])
  }
}
```

The **byte-identity guarantee (I7)** falls straight out: an `Idx32` memory renders the *exact*
Phase-5 `fresh` term — no new argument, no new head — so a non-memory64 module's `instantiate` is
bit-for-bit unchanged. Only an `Idx64` memory renders the `fresh64` form. The imported-memory slot
(`imported_slots`, `:3252`) is unchanged: an imported memory's handle already carries its own
`idx_type` from the provider (the `Provided.idx_type` link-matched in P5), so `emit_core` passes the
opaque `provided_memory_value` through — the width is the provider's, not re-declared here.

*(Whether 08 prefers a single `fresh(Min, Max, Cap, IdxTypeAtom)` head over the two-head
`fresh`/`fresh64` split is a co-design; the invariant this unit fixes is: **the `Idx32` emission is
byte-for-byte Phase-5** — the two-head form is the recommendation because a single always-tagged head
changes every Phase-5 `fresh` call site. §Open questions.)*

### D.2 Growth/size return i64 page counts — transparently

`memory.grow` on a 64-bit memory returns the previous size (an i64 page count) or `-1` on failure;
`memory.size` returns the current i64 page count. At the emit level both are the existing bare `Int`
disposition (`emit_mem_grow`/`emit_mem_size`, unchanged) — the page count is a bignum either way, and
the `-1`-on-failure / never-trap semantics of `grow` are `rt_mem`'s (08), reused verbatim. Growth
**beyond `mem64_max_pages`** returns `-1` (never a trap); an **access beyond the current size** traps
`MemoryOutOfBounds` exactly where the spec's `assert_trap` expects — both inside `rt_mem`, the cap
being a trap boundary the paged backend enforces. `atomics`/`nif` tiers **fail closed** for an
over-cap 64-bit memory (08's gate); memory64 ships on `paged` (+ `portable`) — the emitter reads only
the `*_module` name (G5), never the tier, so this is invisible here.

---

## E. Cross-module imported-function call (`CallImport` → `apply(Closure, Args)`)

P5 wired imported **state** (globals/tables/memories) + the `spectest` module, and `link.gleam`
already **matches** `ProvidedFunc(ty)` signatures — but `lower` **rejected** every imported function
*call* (`lower.gleam:1197`, `Error(Unsupported("imported call"))`), so no generated code could
*invoke* a function living in another instance. Phase 6 closes this (I5): unit 05 now lowers an
imported-function call to a **`CallImport(slot: Int, ty: FuncType, args: List(Value))`** node
(deviation D3 — a dedicated node, argued below), and this unit dispatches it over the linker-built
**closure capability**.

### E.1 The capability model (D3a)

The load-bearing security decision: the dispatch target is a **first-class closure value** the
**linker** builds (capturing the exporting instance + its exported function — e.g.
`fun(A0,…,An) -> a_instance:f(A0,…,An) end`, or the threaded-state analogue), handed in at link time
through the positional `Provided` list, seeded into the instance's `func_imports` vector, and read at
the call site by its **static positional slot** (R4 — positional, name-free). The generated caller
applies that closure with `apply/2` — the Erlang fun-apply over a value — and **never** constructs a
`module:atom` from data. Contrast the two BEAM apply forms:

- **`apply(Closure, Args)`** — `erlang:apply/2`, the fun-apply of a **value** (the handed-in
  capability). This is what we emit. D3a-sanctioned: the "capabilities are handed-in closures" clause
  of D3a is *exactly* this form.
- **`apply(Module, Fun, Args)`** — `erlang:apply/3`, dispatch on a `module:atom` chosen at runtime.
  **Never emitted.** This is the ambient authority D3a forbids.

### E.2 The emitter

`CallImport` is **state-reaching** (it reads the closure from the instance's `func_imports` vector) —
so it seeds the threaded closure (§A.3), and under `Threaded` its function threads the record. But
the call itself is **read-only w.r.t. our record**: reading the closure does not mutate our state, and
the callee runs against **its own** state (the closure captures instance B's state handling
internally — the linker's concern, 09), so it does **not** rebind our `cur`. The disposition is
therefore "read the closure from state, then a value-producing apply" — a state **read** (like
`MemLoad`) feeding a call-result unpack (like `CallDirect`):

```gleam
/// Lower `CallImport(slot, ty, args)` — a cross-module call over the handed-in closure capability
/// (I5/D3a). Read the closure from the instance's positional func-import slot, then APPLY it to the
/// args with `erlang:apply/2` — the fun-apply over a VALUE, never `apply/3` of a module:atom. The
/// callee returns its result PACKAGE (bare value / tuple / dummy), unpacked to `len(ty.results)`
/// values exactly like a `CallDirect` (`apply_cont_call`). State-reaching but record-read-only:
/// `cur` is UNCHANGED (the callee threads its OWN state inside the closure).
fn emit_call_import(slot, ty, args, cont, sc, state, ctx) {
  let r = list.length(ty.results)
  let closure = case sc {
    NoState -> seam_call(ctx.binding.state_module, "func_import_at", [CInt(slot)])
    Threading(cur) ->
      seam_call(ctx.binding.state_module, "t_func_import_at", [CVar(cur), CInt(slot)])
  }
  let #(cvar, state2) = fresh_var(state)
  let applied =
    CCall(CAtom("erlang"), CAtom("apply"), [CVar(cvar), core_list(list.map(args, emit_value))])
  use #(rest, state3) <- result.try(apply_cont_call(cont, applied, r, sc, state2, ctx))
  Ok(#(CLet([cvar], closure, rest), state3))
}
```

Worked example, `CallImport(0, FuncType([TI32], [TI32]), [Var("x")])` under `Cell` (the callee
returns one value):

```erlang
let <c0> = call 'twocore@runtime@rt_state':'func_import_at'(0)
in call 'erlang':'apply'(c0, [x])
```

and under `Threaded` (the containing function is at arity `n+1`, `st` its live record):

```erlang
let <c0> = call 'twocore@runtime@rt_state':'t_func_import_at'(st, 0)
in <apply_cont_call re-pairs the result package with the UNCHANGED st at KReturn>
```

`apply_cont_call` (`:1302`) handles the `r ∈ {0, 1, ≥2}` unpack + the `Threading`/`KReturn`
re-pairing verbatim — the same machinery `CallHost` uses (a pure, record-neutral producer). The
closure is an **N-ary** BEAM fun; `erlang:apply/2` spreads the arg list `[A0,…,An]` into its
parameters. (This N-ary shape is deviation D4 from the provisional's `fn(List(Dynamic)) -> Dynamic`;
argued below — it makes `apply/2` natural and avoids a bespoke arg-list-unwrap seam.)

### E.3 Rendering the `func_imports` slot

The closure must be seeded into the instance state at `instantiate/1`, exactly as imported
globals/tables/memories are (P5). This unit **renders** the func-import slot in the `FullDecl`; the
linker (09) **builds** the closure and returns it as a positional `Provided`. Three touch-points:

- **`count_state_imports` → `count_import_slots`** (`:3016`): cross-module function imports now
  contribute a positional slot (the closure), so they are counted alongside global/table/memory
  imports. `instantiate/1`'s arity + the `Imp<p>` destructuring cover them. (A **host-capability**
  function import — a `CallHost`, §E.4 — still contributes **no** slot; the split is 05/09's, flagged
  below.)
- **`imported_slots`** (`:3198`): for each cross-module `ImportFn` positional slot, pull the closure
  via `seam_call(link_module, "provided_func_closure", [CVar(Imp<p>)])` — a fixed `link` module call,
  the slot chosen statically (D3a — no runtime name lookup), exactly like `provided_table_value`.
- **`full_decl_term`** (`:3168`): append a `func_imports` vector (the closures in import order) to
  the `FullDecl` tuple — **empty (byte-identical to the P5 four-field `full_decl`) when there are no
  cross-module function imports** (I7). `rt_state.seed_full`/`fresh_full` (09) install the vector;
  `func_import_at`/`t_func_import_at` read it.

Because the addition is **empty/omitted in the neutral case**, `emit_module(phase5_module, safe())`
prints byte-for-byte the pre-P6 `.core` (I7). *(The `FullDecl` `func_imports` field + the positional
ordering contract between `link_imports` (09) and this unit's `Imp<p>` destructuring is a shared seam
— flagged §Open questions; the keystone freezes the field, 09 fills it, this unit renders it.)*

### E.4 Host imports stay `CallHost` — unchanged

A function import satisfied by a **host capability** (`spectest`'s `print*`, or a genuine `env`
host function) is **not** a `CallImport`: it lowers to the existing `CallHost(cap, name, args)` node
(`emit_call_host`, `:1705`), which routes through `binding.host_module`/`binding.stdlib_module`
**unchanged**. This split — host capability → `CallHost`; cross-module WASM function →
`CallImport` — is made at **lower** (05), which knows the import's module name; this unit consumes
whichever node 05 produces. Keeping the host path untouched preserves the D9 capability boundary and
the byte-identity of any host-import code (I7). *(Whether 05/09 instead unify host + cross-module
under one closure model — building a `rt_host`-wrapping closure for host imports too — is their
scoping call, flagged §Open questions; either way this unit's `CallImport` emitter is unchanged.)*

---

## F. Both state strategies — the seam-reuse map

Every new state-touching op has a `Cell` arm and a `Threading(cur)` arm, chosen exactly as the
Phase-4/5 seam (`is_threaded`/`sc`). The lowering **shapes are already built** — this unit only wires
the new ops to them:

| Runtime shape | Cell helper | Threaded helper | New ops using it |
|---|---|---|---|
| bare pure value | `apply_cont` | `apply_cont`, `cur` unchanged | `Simd` / `SimdShuffle` (+ `ConstV128` via `emit_value`) |
| trapping value → 1 value, read-only | `emit_trapping_result` | `emit_trapping_result` (read `St`, `cur` unchanged) | `SimdLoad` (all kinds) |
| trapping zero-result write | `trapping_effect`+`emit_zero_effect` | `emit_threaded_record_effect` (rebind `cur`) | `SimdStore` / `SimdStoreLane` |
| state read → value producer, record-neutral | `let closure = …_at(slot)` + `apply_cont_call` | `t_…_at(cur, slot)` + `apply_cont_call`, `cur` unchanged | `CallImport` |

`Simd`/`SimdShuffle` are emitted **identically** under both strategies (pure, state-neutral — `cur`
flows through untouched, exactly like `Num`/`RefFunc`), so a SIMD-arithmetic body is byte-identical
across `Cell` and `Threaded` and keeps its Phase-1 pure arity (the I7-neutral shape). Under
`Threaded`, the SIMD-memory ops **rebind `cur`** on every store (making SIMD-store ordering a visible
dataflow edge through `St` — no optimizer can reorder a `v128.store` past a dependent load), and a
SIMD-memory loop threads the fixed-size record in **constant space** (the G4 template, unchanged —
the new ops add no loop-carried data beyond the box).

---

## Effect / soundness / security note

- **No ambient authority (D3a) survives the surface growth — for BOTH new authorities.**
  - **SIMD** is `seam_call(binding.simd_module, "<simd_op_name(op)>", args…)` — a fixed
    build-controlled runtime atom, a literal function atom (from a total compile-time table), operands
    as ordinary Core values, lane/shuffle indices as static immediates. The SIMD-memory ops are
    `seam_call(binding.mem_module, "load_bytes"/"store_bytes"/…)` + `seam_call(binding.simd_module,
    "load_splat_…"/…)` — the same fixed-atom shape. No SIMD op reaches a control transfer or a
    data-driven dispatch; the worst case of a SIMD bug is a wrong result or a node-safe crash, never a
    host escape (I6). `v128` is opaque in Safe mode — it can address memory **only** through the
    bounds-checked `rt_mem` seam.
  - **Cross-module dispatch** is `apply(Closure, Args)` — `erlang:apply/2` over a closure **value**
    read from the instance's positional `func_imports` slot (`rt_state:func_import_at`), a fixed seam.
    The closure is a capability supplied by the linker at link time, never a `module:atom` a generated
    body looks up by an attacker-controlled name. The forbidden `apply(Module, Fun, Args)` (3-arg) is
    **never** emitted. `link:provided_func_closure` (the slot extractor) and `func_import_at` (the
    slot read) are fixed `link`/`rt_state` module calls with literal function atoms.
- **Fail-closed for the new surface (H6).** A SIMD load/store out of range traps `MemoryOutOfBounds`
  **before any partial read/write** (eager, `rt_mem`-owned — the SIMD lane assembly is only reached on
  the `{ok, _}` path). A memory64 access beyond the current size traps `MemoryOutOfBounds`; growth
  beyond the documented cap returns `-1`. An unsatisfied/mismatched cross-module function import is a
  **link-time** failure (`assert_unlinkable`, 09) — never a runtime trap and never an ambient default;
  a `CallImport` is emitted only for an import 09 will satisfy with a closure. Every runtime trap is a
  `rt_*` `{error, R}` → `raise_trap` (`:1605`) → the catchable `{wasm_trap, Kind}` channel.
- **`v128` opacity + floats-as-bits (D5) + const-space (G4) unchanged.** `ConstV128` is a raw 16-byte
  binary literal (never a decoded structure — so lane values, NaN payloads, and `-0.0` are exact); a
  v128 flows as an opaque `Var`; the SIMD ops are ordinary reduction-consuming BEAM calls, so
  preemption and constant-space loops are unaffected. SIMD is **emulated lane-wise, faithful-over-fast
  — no speed claim (I3/I8)**.
- **I7 conformance-neutrality is a security-relevant invariant too:** a non-SIMD / single-32-bit-memory
  / no-cross-import module's authority surface is *unchanged* — no new call, no new argument, the
  `FullDecl` `func_imports`/`fresh64` additions omitted — so the prior D3a proof carries over
  unmodified.

---

## Verification — Definition of Done (D8)

Tests assert **WebAssembly-spec behavior** (the core + fixed-width-SIMD spec / the `simd/*.wast`,
`memory64.wast`, `linking.wast` suites), not whatever the code emits (no change-detector tests); cite
the spec section / I-decision in each. "Done" = the suite below passes + the conformance gate
(`fail == 0`), never "it compiles."

1. **`simd_op_name` totality + spec-name goldens** (`emit_core_test`): assert the chokepoint table is
   total and each family maps to its spec-grounded name — `SAdd(I32x4) → "i32x4_add"`,
   `FMul(F32x4) → "f32x4_mul"`, `SExtractLaneU(I8x16, 3) → "i8x16_extract_lane_u"`,
   `I32x4DotI16x8S → "i32x4_dot_i16x8_s"`, `I8x16Swizzle → "i8x16_swizzle"`,
   `F32x4DemoteF64x2Zero → "f32x4_demote_f64x2_zero"`, etc. — at least one per family in §B.3 (this is
   spec-cited, not change-detector: the names ARE the fixed-width-SIMD instruction mnemonics). Assert
   `simd_immediates` appends `[CInt(lane)]` only for extract/replace.
2. **SIMD AST-shape goldens** (`emit_core_test`), under **both** `Cell` and `Threaded`:
   - `Simd(SAdd(I32x4), [a,b])` → a bare `call '<simd>':'i32x4_add'(a,b)` (no `case`, no `raise` —
     total, I3); assert **byte-identical Cell vs Threaded** (a pure v128 op is state-neutral).
   - `SimdShuffle([0,…,15], a, b)` → `call '<simd>':'i8x16_shuffle'(a, b, [0,…,15])` (16-element
     immediate list after the two operands).
   - `Simd(SExtractLane(F32x4, 2), [v])` → `call '<simd>':'f32x4_extract_lane'(v, 2)` (lane immediate
     trailing); `Simd(SReplaceLane(I8x16, 3), [v,x])` → `…'i8x16_replace_lane'(v, x, 3)`.
   - `ConstV128(<<16 bytes>>)` → the exact 16-byte little-endian `#{…}#` binary literal (pure).
   - A **SIMD-arithmetic-only** function stays pure `'f'/n` under `Threaded` (assert `Simd` alone does
     **not** force threading — the I7-neutral classification of §A.3).
3. **SIMD-memory compose goldens** (`emit_core_test`): `SimdStore(0, a, v, o)` → an eager trapping
   `store_bytes(16, …)` zero-effect (no partial write); `SimdLoad(0, V128, a, o)` → a trapping
   `load_bytes(16, …)` value (the 16-byte slice **is** the v128); `SimdLoad(0, Splat(32), a, o)` →
   `load_bytes(4,…)` reduced to a bound slice **then** `load_splat_32(slice)` (assert the `rt_simd`
   assembly is on the `{ok,_}` path, unreachable if the load faults); `SimdStoreLane(0, 16, a, o, 2,
   v)` → `extract_lane_bytes_16(v, 2)` (pure, first) then a trapping `store_bytes(2, …)`. Cite the
   SIMD memory family + H6 (eager, no-partial-effect). Under `Threaded` each store is a record-rebind.
4. **memory64 goldens + byte-identity** (`emit_core_test`): a defined `Idx32` memory renders the
   **byte-identical** Phase-5 `rt_mem:fresh(Min, Max, SafeCap)` term; a defined `Idx64` memory renders
   `rt_mem:fresh64(Min, Max, Mem64Cap)` with `Mem64Cap == binding.mem64_max_pages`. Assert a
   `MemLoad`/`MemStore`/`MemSize`/`MemGrow` on an `Idx64` memory emits the **same** op-site Core as on
   an `Idx32` memory (memory64 is transparent at the op sites — §D; the width lives in the handle).
   Cite I4/I7.
5. **`CallImport` closure-dispatch goldens** (`emit_core_test`), both strategies:
   `CallImport(0, FuncType([TI32],[TI32]), [x])` → `let <c> = call '<state>':'func_import_at'(0) in
   call 'erlang':'apply'(c, [x])` (Cell) / `…'t_func_import_at'(st, 0)…` (Threaded), the result
   unpacked to one value and (Threaded) re-paired with the **unchanged** `st`. Assert **no**
   `erlang:apply/3` / computed-module `call` is emitted (the 2-arg fun-apply only). Assert a
   multi-result import (`FuncType([TI32],[TI32,TI32])`) destructures the returned tuple. Cite I5/D3a.
6. **I7 byte-identity** (the non-negotiable): `emit_module(phase5_fixture, safe())` and
   `emit_module(phase5_fixture, Threaded)` printed to `.core` are **bit-for-bit** unchanged from the
   pre-P6 emission — for a fixture with **no** SIMD, one 32-bit memory, and no cross-module imports
   (its `full_decl` has no `func_imports`/`fresh64`, its op sites are unchanged). The existing
   `emit_core_test`, `emit_core_security_test`, and conformance goldens stay green under every shipped
   `(state_strategy × mem_tier)`.
7. **D3a security walk extended & green** (`emit_core_security_test`): grow the `stateful_module()`
   fixture to exercise (a) pure SIMD arithmetic (`Simd`/`SimdShuffle` + a `ConstV128`), (b) every
   SIMD-memory node, (c) a **second** memory (memidx 1), (d) an **`Idx64`** memory, and (e) a
   **`CallImport`** — then assert:
   - every `CCall` targets a fixed allow-set atom with a literal function atom — **extend
     `runtime_modules` with `binding.simd_module` and `"erlang"`** (the latter admitted *only* for the
     2-arg fun-apply of a capability — the sanctioned D3a form);
   - **the surgical closure-dispatch assertion:** every `erlang:*` call in the module is exactly
     `erlang:apply` with **2** args whose first arg is a `Var` bound from `…rt_state':'func_import_at'`
     — i.e. no `apply/3`, no computed module, no data-derived dispatch;
   - every `CApply` is still a static local `FName` (the SIMD/closure paths introduce **no** new
     `CApply` — the closure dispatch is a `CCall(erlang, apply, …)`, not a `CApply`);
   - the new seam calls are delegated to the runtime: `has_call(m, simd_module, "i32x4_add")`,
     `has_call(m, mem_module, "store_bytes")`, `has_call(m, mem_module, "fresh64")`,
     `has_call(m, state_module, "func_import_at")`, `has_call(m, link_module,
     "provided_func_closure")`, and SIMD-memory faults reach `rt_trap:raise`.
   Run it under `Cell`, `Threaded`, **and** the `unsafe()` posture — all three pass with the same
   allow-set.
8. **End-to-end** (`emit_core_e2e_test`; green once 07/08/09 land — Concurrency), hand-built IR4 →
   `emit_module` → `build_beam` → `instantiate` → invoke, asserting **spec-correct** results and
   **byte-identical `Cell` vs `Threaded`**:
   - **SIMD arithmetic**: `i32x4.add`/`i8x16.add` wrap two's-complement at the lane width;
     `f32x4.mul` is f32-single-rounding-exact; `i8x16.shuffle`/`swizzle` (OOB → 0) select the right
     bytes; `i32x4.dot_i16x8_s`, `q15mulr_sat_s`, a narrow (saturating) and a widen match `wasmtime`
     / the baked `.wast` (differential — 10/11).
   - **SIMD memory**: `v128.store` then `v128.load` round-trips 16 bytes; `v128.load32_splat`
     broadcasts; `v128.load8x8_s` sign-extends; `v128.load64_zero` zeroes the high lane; a
     `v128.load`/`store` **out of range traps `MemoryOutOfBounds` with no partial write** (read the
     untouched bytes after the trap); `v128.store8_lane` writes exactly one byte.
   - **memory64**: on a 64-bit memory, a `v128`/scalar store+load at an address **≥ 2³²** round-trips;
     `memory.grow` beyond `mem64_max_pages` returns `-1`; an access beyond the current size traps;
     `memory.size` returns the i64 page count. A 32-bit memory is **byte-identical** to Phase 5.
   - **cross-module**: two hand-built IR4 modules — B `CallImport`s A's exported `f` through a
     linker-built closure — compute correctly across instances (Cell); a mismatched import fails
     closed at link (09). The `apply(Closure, Args)` reaches A's function, not a `module:atom`.
   Each case is diffed against the `Cell` oracle (same IR, `state_strategy: Cell`) — the I7 bar.
9. **No regression.** `gleam format --check src test` clean; `gleam build` **zero warnings**;
   `gleam test` stays green (the Phase-5 corpus + suite untouched — the neutral path is byte-identical,
   test 6). Every new public/private function carries a contract doc comment (D8).

**Proof of goal:** tests 1–5 + 8 are the unit's proof — a WASM module hand-built as IR4 that uses
v128 arithmetic, SIMD memory, a 64-bit memory, and a cross-module import compiles, instantiates, and
runs spec-correctly on the BEAM under **both** state strategies, with every new memory/cross-module
fault fail-closing, the security walk green (SIMD **and** the closure dispatch proven ambient-free),
and a Phase-5 module still byte-identical.

## What this unit leaves

- **Unit 07** implements the `rt_simd` **bodies** behind the `simd_op_name` heads + the SIMD-memory
  lane-assembly helpers this unit emits (bit-exact, reusing `rt_num` per lane, differential vs
  `wasmtime`); this unit's SIMD e2e is its integration check.
- **Unit 08** implements the `rt_mem` memory64 runtime (`fresh64`, the i64 bounds/cap) + the
  byte-slice heads (`load_bytes`/`store_bytes`) + the atomics/nif over-cap fail-closed gate + pins the
  `mem64_max_pages` constant (spec-cited).
- **Unit 09** builds the `Provided` closure capability (`ProvidedFunc(ty, closure)` + the
  `provided_func_closure` extractor), extends `link_imports` to functions (fail-closed
  `assert_unlinkable`), seeds the `func_imports` vector at instantiate, and drives `(register …)`;
  this unit renders the slot term + emits the `apply(Closure,…)` + the `func_import_at` read.
- **Unit 05 (lower)** produces the IR4 this unit consumes — the SIMD nodes, the resolved `mem`
  indices, the accepted `Idx64`, and the `CallImport` node (with its positional `slot` + the
  host-vs-cross-module split).
- **Units 10/11** prove the conformance-expansion headline (`simd/*.wast`, `memory64.wast`,
  `linking.wast` light up, skip-count drops, `fail == 0`, differential vs `wasmtime`) under the full
  `(mode × state_strategy × mem_tier)` matrix — cell-first for `linking.wast` (I5).

---

## Deviations from the provisional surface (ARGUED — for critique + reconciliation)

- **D1 — SIMD memory is dedicated nodes (as the provisional recommends), and I confirm it.** The
  provisional §D leaves open (Q-a) whether the SIMD-memory family extends `MemLoad`/`MemStore` access
  kinds or gets dedicated `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane` nodes. **Confirm the
  dedicated nodes.** `MemLoad`'s `result: ValType` + `MemAccess(bytes, signed)` do not stretch to the
  splat/extend/zero/lane-index variants without contorting the numeric-load node; the dedicated nodes
  keep the compose (`rt_mem` byte-slice ∘ `rt_simd` assembly) explicit and let `result_width`/`TV128`
  stay documented-unreachable at the scalar `MemLoad`. No argument against the provisional — this is
  ratification.

- **D2 — `binding.simd_module` field (not a fixed atom like `rt_ref`/`link`).** The provisional §E
  names `rt_simd` but does not say whether the emitter reaches it via a `Binding` field or a fixed
  literal atom. **Recommend a `binding.simd_module` field.** Rationale: I3/I8 explicitly reserve a
  **tier-N real-SIMD NIF** behind the same interface ("the interface admits it, we do not build it").
  A `Binding` field is the tier-swap seam — a future NIF binding is a `*_module` name change (exactly
  how `mem_module` swaps paged/atomics/nif, G5) with **zero** `emit_core` edits. A fixed atom would
  force an `emit_core` change to ever swap the tier. The security allow-set gains one build-controlled
  atom either way. *(Costs one `Binding` field the keystone owns — flagged §Open questions.)*

- **D3 — a dedicated `CallImport(slot, ty, args)` node, not a name-recognized `CallDirect`.** The
  provisional §G phrases the cross-module call as "an imported-function `CallDirect`/`CallIndirect`
  target". **Recommend a dedicated `CallImport(slot, ty, args)` node instead** (05 produces it; 01
  freezes it). Rationale: (1) reusing `CallDirect` forces the emitter to detect an imported target by
  **name** (`"f<idx>"` with `idx < imported`) and carry an imported-name→slot map — fragile and
  couples emit to the funcidx-space import ordering; (2) it re-introduces the exact **host-vs-cross-
  module ambiguity** D3a wants gone (a `CallDirect` name cannot say "this is a capability dispatch");
  (3) a **positional `slot`** on the node is the R4 "positional, name-free" discipline made explicit —
  the slot is a static immediate, D3a-clean, and matches how the closure is seeded. A dedicated node
  is one `Expr` constructor (the ~110-SimdOp explosion is already confined to `rt_simd`), well worth
  the clarity. `call_indirect` to an **imported table**'s funcref is *not* a `CallImport` — it stays a
  `CallIndirect` (the target is a table entry closure, dispatched by `rt_table`), so `CallImport` is
  purely the direct-imported-function path.

- **D4 — the closure is an N-ary BEAM fun applied via `erlang:apply/2`, not `fn(List(Dynamic)) ->
  Dynamic`.** The provisional §G types the closure `fn(List(Dynamic)) -> Dynamic` (a 1-ary list-taker).
  **Recommend an N-ary closure `fun(A0,…,An) -> …` applied with `erlang:apply(Closure, [A0,…,An])`**
  (the 2-arg fun-apply spreads the list into the fun's params). Rationale: (1) it is the literal
  `apply(Closure, Args)` the task + I5 call for, emitted **in generated code** (where the security walk
  inspects it), the sharpest possible D3a demonstration (2-arg fun-apply of a value vs the forbidden
  3-arg module-apply); (2) a list-taking closure would need `Closure(ArgList)` — a 1-ary apply the
  frozen `CApply` (which requires an `FName`) **cannot** express, forcing a bespoke
  `link:call_import(Closure, ArgList)` seam. **The reconciliation-time alternative** (flagged, not
  rejected): keep the list-taking closure + route through `link:call_import` (already-admitted `link`
  atom → a *homogeneous* twocore-only allow-set, no `erlang` entry; the `apply` then lives inside
  `link`, like `rt_table:call_indirect` applies funcref closures inside the runtime). Both realize the
  identical security property; the manager picks whether the demonstrative `erlang:apply/2` in
  generated code or the tighter homogeneous allow-set matters more. This unit builds the `erlang:apply/2`
  primary; swapping to the seam is a one-line change (`CCall(CAtom("erlang"), CAtom("apply"), …)` →
  `seam_call(link_module, "call_import", …)`) if reconciliation prefers it.

- **D5 — memory64's `fresh` is a two-head split (`fresh`/`fresh64`), not a re-typed single head.** The
  provisional §F leaves the `rt_mem` fresh ABI to 08. **Recommend `fresh` (Idx32, byte-identical
  Phase-5) + `fresh64` (Idx64, cap).** Rationale: byte-identity (I7) forces the `Idx32` seed to be the
  *exact* Phase-5 head; a single always-`idx_type`-tagged head would rewrite every Phase-5 `fresh`
  call site and body. Co-design with 08 (§Open questions) — either works provided the `Idx32` emission
  is byte-for-byte Phase-5.

## Open questions / cross-unit seams (for the planner / reconciliation)

- **`binding.simd_module` ownership (keystone).** D2 adds a `Binding` field. Confirm the keystone adds
  it + `safe_default`/`unsafe` set it to `"twocore@runtime@rt_simd"`; the security allow-set includes
  it. (Alternative: a fixed atom like `rt_ref` — but that forfeits the tier-N swap seam.)
- **The `CallImport` node + the host-vs-cross-module split (01/05/09).** D3 recommends a dedicated
  node. Pin: (a) the node shape `CallImport(slot: Int, ty: FuncType, args)`; (b) that 05 emits it
  **only** for a cross-module (registered-instance) function import, and a host-capability import stays
  `CallHost`; (c) the positional `slot` numbering (over cross-module function imports, interleaved with
  state imports in the single `Imports` positional list — the ordering must match `link_imports`'s
  output). If 09 unifies host + cross-module under one closure model, `CallHost` narrows and this
  unit's emitter is unchanged — decide with 09.
- **The `func_imports` `FullDecl` field + accessor heads (01/09).** Pin: (a) the `FullDecl`
  `func_imports` vector position (append after `ref_globals` — so the neutral four-field `full_decl`
  is byte-identical when empty); (b) the `rt_state` accessors `func_import_at(slot)` /
  `t_func_import_at(st, slot)` (frozen todo-free by 01, bodies 09); (c) the `link:provided_func_closure`
  extractor + the `Provided` `ProvidedFunc(ty, closure)` shape. This unit renders (b)/(c) call sites;
  09 fills the bodies.
- **The closure-dispatch form: `erlang:apply/2` (in generated code) vs `link:call_import` seam
  (homogeneous allow-set).** D4. Reconciliation picks; this unit builds `erlang:apply/2` + a surgical
  security assertion; the swap is one line.
- **The `rt_mem` byte-slice + `fresh64` ABI (08).** Pin: `load_bytes(N, Addr, Off) -> Result(BitArray,
  _)` / `store_bytes(N, Addr, Off, Bytes) -> Result(Nil, _)` (+ `_at` + `t_*`); `fresh64(Min, Max,
  Cap)` (D5); the `mem64_max_pages` constant + its spec citation (08 pins). Confirm the two-head fresh
  split and the byte-slice head signatures match what this unit emits.
- **The `rt_simd` lane-assembly head names + the lane-immediate arg order (07).** Pin the SIMD-memory
  assembly helper names (`load_splat_<w>`, `load_extend_<shape>_<s|u>`, `load_zero_<w>`,
  `replace_lane_bytes_<w>`, `extract_lane_bytes_<w>`) and the convention that a lane immediate rides
  **last** (`extract_lane(Vec, Lane)`, `replace_lane(Vec, X, Lane)`) — `simd_op_name` + the assembly
  emitters bind to exactly these.
- **`SimdOp` taxonomy finalization (01/03/07).** The §B.3 enumeration assumes the provisional taxonomy
  (shape-tagged uniform ops + individually-named shape-specific ops). If 01/03/07 refine a boundary
  (e.g. fold `SExtractLaneS`/`SExtractLaneU`/`SExtractLane` into one tagged variant, or split
  `SShr`), `simd_op_name` + `simd_immediates` update in lockstep — this unit owns the map, not the
  taxonomy.
