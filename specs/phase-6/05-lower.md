# Unit P6-05 — WASM lower extension (AST4 → IR4): SIMD, memory64, cross-module imports

> **One owner. Extends `src/twocore/frontend/wasm/lower.gleam` (single-owner, additive).
> Wave A — runs behind the keystone freeze, in parallel with 03 (decode), 04 (validate),
> 06 (emit_core), 07 (rt_simd), 08 (rt_mem/memory64), 09 (cross-module linking).** Read
> [`00-overview.md`](00-overview.md) (I1–I8), [`RECONCILIATION.md`](RECONCILIATION.md)
> (S1–Sn — AUTHORITATIVE; where it and this doc disagree, it wins), the keystone doc
> (P6-01), and [`PROVISIONAL-SURFACE.md`](PROVISIONAL-SURFACE.md) first. Freeze deps:
> **`«IR4-FROZEN»`** (the IR4 nodes you emit) and **`«WASM-AST4»`** (P6-03's day-1
> AST constructors you match). Phase-5 counterpart: [`../phase-5/05-lower.md`](../phase-5/05-lower.md).

---

## Context

`lower.gleam` does the two WASM-frontend jobs together in one SSA naming context
(`lower/1` → `lower_func/3` → `go/3`): **stack-elimination/SSA** (the operand stack
becomes named `ir.Value` bindings — there is **no runtime stack**) and **structure →
named-label IR** (a numeric branch depth NEVER reaches the IR — D6). Phase 1 lowered the
integer/control slice; Phase 2 completed WASM 1.0 (linear memory, one table +
`call_indirect`, globals, the full float/conversion surface, `select`); Phase 5 completed
the standardized instruction surface **minus SIMD** — the reference instructions, the
table instructions, bulk memory, typed `select`, multi-memory memidx, reference-typed
tables/elements, non-function imports/exports, and the grown module shape. It returns a
typed `LowerError` (never a panic) for anything out of scope.

Phase 5 deliberately left **three holes** that Phase 6 closes, and **lower is on the
critical path for all three**:

1. **SIMD.** `go/3`'s numeric fall-through (`lower_numeric`) rejects every `v128`/lane op
   with `Error(Unsupported("instruction"))`. Phase 6 makes the ~236 standardized SIMD
   instructions lower into IR4 — each mapped to a compact `Simd(op, args)` /
   `SimdShuffle(lanes, a, b)` / `SimdLoad*`/`SimdStore*` node (I2), exactly as the ~90
   `rt_num` scalar ops hide behind the small `NumOp`/`ConvOp` enums carried by
   `Num`/`Convert`. `v128.const` pushes a `ConstV128(bytes)` value literal, like a numeric
   const (D5 — the raw 16 little-endian bytes, never a decoded structure).

2. **memory64 runtime.** `lower/1` currently calls `reject_memory64/1`, returning
   `Error(Memory64Unsupported)` for any 64-bit-indexed memory (R12 deferred the runtime).
   Phase 6 **deletes the rejection** (I4): a 64-bit memory decodes/validates/**lowers**;
   lower carries the `Idx64` axis onto `MemoryDecl`/`ImportMemory` (it already computes
   this via `to_ir_idxtype`), and the i64 address operands flow through the memory nodes
   unchanged (the width is a value-width fact + a per-memory `idx_type`, not a lower
   branch — exactly the Phase-5 "deferrable half" stance, now un-deferred).

3. **Cross-module function imports.** `lower_call/4` rejects a call to an imported function
   (`f < ctx.imported ⇒ Error(Unsupported("imported call"))`). Phase 6 lowers it to a
   **positional-slot import-call node** (`CallImport`, I5/R4) that emit_core dispatches via
   the linker-built closure capability (`apply(Closure, Args)` — a capability, **not** an
   ambient `apply` of an attacker-chosen `module:atom`; D3a).

As in every prior phase, this unit is a **pure syntactic mapping**. Validation (P6-04) has
already proved the module well-typed and in scope: `v128` on the abstract stack, lane
indices in range, shuffle indices `0..31`, i64 addressing for a 64-bit memory, and the
cross-module function-import signatures matched. Lower produces IR4 nodes faithful to each
instruction's spec meaning and **nothing else** — the per-lane bit-exact semantics belong
to `rt_simd` (P6-07), the bounds-checked v128 memory + 64-bit bounds arithmetic to `rt_mem`
(P6-08), and the closure construction / positional wiring to `link.gleam` (P6-09) +
`emit_core` (P6-06). Lower emits the **tier-agnostic** IR4 node. Per I6 every SIMD-memory
node is an **effect** (a barrier): lower must preserve program order and never drop a
zero-result effect — it does this structurally (a straight-line walk; zero-result effects
are sequenced as `Let([], …, cont)`, never discarded).

Throughout it preserves the existing named-label + stack-elim/SSA discipline, the
`funcidx → "f<idx>"` / `globalidx → "g<idx>"` / `tableidx → "t<idx>"` naming conventions,
and the Phase-1 mutable-locals → `LoopParam` mechanism. **Conformance-neutral by default
(I7):** a module with **no `v128`**, a **single 32-bit memory**, and **no cross-module
function imports** lowers to **byte-identical** IR4 to Phase-5 under both modes and every
shipped tier — every new construct is additive, the `Idx64` path is dead for a 32-bit
memory, and `CallImport` fires only for an imported-function call (which Phase-5 rejected,
so no green module relies on the old behaviour).

## Goal

Lower every standardized SIMD instruction, every 64-bit-memory access, and every
cross-module function-import call into IR4, preserving the existing named-label +
stack-elim/SSA model. After this unit a validated Phase-6 `.wasm`/`.wat` module produces a
complete `ir.Module` — SIMD lane ops as `Simd`/`SimdShuffle`/`SimdLoad*`/`SimdStore*`
nodes, `v128.const` as `ConstV128`, a 64-bit memory carrying `Idx64` with its i64 address
operands forwarded, and an imported-function call as `CallImport(slot, ty, args)` — ready
for emit_core (P6-06). The negative obligation is the load-bearing one (I7): the entire
Phase-1..5 acceptance corpus + previously-passing suite lower to **byte-identical** IR4.

## Files owned

- `src/twocore/frontend/wasm/lower.gleam` — **EXTEND** (single owner).
- `test/twocore/frontend/wasm/lower_test.gleam` — the unit's tests (mirrors `src/`; extend).

No freeze/publish-day-1 stub: lower is downstream of two freezes; it publishes nothing
others depend on. emit_core (P6-06) consumes the IR4 nodes lower emits, but via
`«IR4-FROZEN»`, not via lower.

## Depends on (freeze milestones)

- **`«IR4-FROZEN»`** (P6-01) — the IR4 node shapes you emit. Concretely (per the provisional
  surface; the keystone is authoritative — flag every seam so reconciliation pins single
  ownership):
  - `ir.ValType` gains **`TV128`**; `ir.Value` gains **`ConstV128(bytes: BitArray)`**
    (exactly 16 bytes, little-endian lane layout — D5).
  - `ir.SimdShape { I8x16 I16x8 I32x4 I64x2 F32x4 F64x2 }` and the **`ir.SimdOp`** enum
    (the compact, shape-and-lane-tagged, neutral op names — §C/§D/§E enumerate every one).
  - New `ir.Expr` nodes: **`Simd(op: SimdOp, args: List(Value))`** (pure lane-wise),
    **`SimdShuffle(lanes: List(Int), a: Value, b: Value)`**, and the SIMD-memory family
    **`SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`** (routed through `rt_mem`; §F),
    with **`SimdLoadKind`** (`V128 | Splat(width) | Extend(result_shape, signed) | Zero(width)`).
  - A **`CallImport(slot: Int, ty: FuncType, args: List(Value))`** `Expr` node for a
    cross-module / provided imported-function call (§H — my recommended shape; argued in
    *Deviations*).
  - **No new `TrapReason`** (SIMD is total; SIMD memory + memory64 reuse `MemoryOutOfBounds`;
    an unsatisfied import is a link-time error, not a runtime trap — I1).
  - The keystone lands **minimal compile-satisfying arms** in lower (per the overview §4
    ownership map); this unit fills the **full** mapping below. The keystone's default
    choices keep a non-SIMD/32-bit/import-free module byte-identical.
  Until it lands, stub against §A/§B/§C/§D of the provisional; the *instruction→IR* mapping
  below is fixed regardless of the exact field spelling.
- **`«WASM-AST4»`** (P6-03, published day 1) — the new AST constructors you match (§A). The
  `0xFD` SIMD prefix + all ~236 sub-opcodes, `v128.const` (16 immediate bytes), the shuffle
  lane immediates, the extract/replace lane immediates, and the v128-memory instructions
  with their `MemArg` + (for the lane family) a lane immediate. Until it lands, stub against
  the names in §A and re-sync when 03 publishes; the mapping is fixed.
- **P6-04 (validate)** — the `TypedModule` this unit consumes. **No new carried fact is
  required** beyond Phase-5's: `func_types: List(FuncType)` already spans `imports ++
  defined` (validate `func_types = list.append(imp_funcs, def_funcs)`), so a cross-module
  imported-function call at absolute funcidx `f` recovers its signature from
  `nth_err(ctx.func_types, f)`. Validate is the security boundary upstream (it rejects
  ill-typed SIMD, out-of-range lane/shuffle immediates, mistyped 64-bit addresses, and
  unmatched function imports **before** lower runs). See *Open questions* for the one
  optional seam (a link-policy fact distinguishing a host-capability import from a
  provided-instance import — lower does not need it; the linker decides).

## Scope — in / out for Phase 6

**In:**
- **SIMD lane ops** → `Simd(op, args)` for every pure lane-wise instruction (integer + float
  arithmetic/compare/bitwise/shift/convert/narrow/widen/extmul/extadd/dot/q15/abs/neg/
  popcnt/splat/any_true/all_true/bitmask/swizzle) (§C/§D), with the **lane immediate** riding
  on the `SimdOp` for `extract_lane`/`replace_lane` (§E).
- **`i8x16.shuffle`** → `SimdShuffle(lanes, a, b)` (16 immediate indices) (§E).
- **`v128.const`** → the `ConstV128(bytes)` value literal, pushed like a numeric const (§B).
- **SIMD memory** — `v128.load`/`store`, the splat/extend/zero loads, and the load/store
  lane family → `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`, carrying the memidx +
  static offset + (for lane ops) the lane immediate + width (§F).
- **memory64 runtime unfreeze** — **delete `reject_memory64` and its call**; a 64-bit memory
  lowers, carrying `Idx64` on `MemoryDecl`/`ImportMemory`; i64 address/count operands flow
  unchanged (§G).
- **Cross-module function imports** — lower a `call` of an imported function to
  `CallImport(slot, ty, args)` (positional slot = the imported funcidx; §H).
- **`v128` plumbing** — `to_ir_vt` gains `V128 → TV128`; `zero_value`/`zero_init` gains a
  v128 all-zero literal; `value_type` gains a `ConstV128 → TV128` arm; `lower_const_expr`
  accepts `v128.const` as a global initialiser (§I).

**Out (cite the deferral):**
- **relaxed-SIMD** (the separate, non-deterministic proposal — `f32x4.relaxed_madd`,
  `i8x16.relaxed_swizzle`, `i16x8.relaxed_q15mulr_s`, the relaxed conversions/laneselect,
  the relaxed dot products, …) — later (I8). Any relaxed-SIMD op ⇒ `Error(Unsupported(_))`.
- **GC-proposal reference types** (typed function refs, `struct`/`array`/`i31`) — later.
  Reference types stay `funcref`/`externref` only (unchanged from Phase 5).
- lower does **not** validate (P6-04), does not optimize (no `ir_opt` — this is a syntactic
  map), does **not** implement the per-lane bit-exact SIMD semantics (P6-07 `rt_simd`), the
  bounds-checked v128 memory / 64-bit bounds arithmetic (P6-08 `rt_mem`), or the
  closure-dispatch / positional import wiring (P6-06 emit_core + P6-09 link).
- The **page-cap constant** for a 64-bit memory (I4) is `instance.gleam`'s `Binding` field
  (01 freezes it, 08 pins the value) and a **runtime** trap boundary — lower never sees it.

---

## A. The AST4 constructors this unit matches (the P6-03 seam)

lower matches `frontend/wasm/ast.gleam` constructors; the byte encoding is P6-03's. These
are the names lower expects (stub against them; re-sync when P6-03 publishes `«WASM-AST4»`).
Opcodes are the `0xFD` prefix + a LEB128 sub-opcode
([binary/instructions#vector-instructions](https://webassembly.github.io/spec/core/binary/instructions.html));
they are given per category **for cross-reference only** — they are P6-03's authority, not
lower's. lower reads the AST constructor + its immediates and maps them.

**AST4 SIMD constructor shape (the P6-03 decision, flagged).** Two shapes are workable and
the mapping below is fixed regardless of which P6-03 freezes:
- **(a) flat `Instr` constructors** — one per SIMD instruction, e.g. `ast.I8x16Add`,
  `ast.F32x4Sqrt`, `ast.V128Load(MemArg)`, `ast.I8x16Shuffle(lanes: List(Int))`,
  `ast.I8x16ExtractLaneS(lane: Int)`, `ast.V128Const(bytes: BitArray)`,
  `ast.V128Load8Lane(mem: MemArg, lane: Int)` — the Phase-5 idiom (one constructor per
  opcode).
- **(b) a `ast.Simd(SimdInstr)` wrapper** carrying a nested `SimdInstr` enum (keeps the
  top-level `Instr` from ballooning by 236). If P6-03 picks this, lower's `go/3` gets one
  `ast.Simd(si) -> lower_simd(si, …)` arm and the case below nests one level; the
  instruction→IR mapping is identical.

This doc writes shape **(a)** for concreteness (matching Phase-5's flat table). **The
constructor names are P6-03's to freeze; this doc names them so the mapping is unambiguous.**

**Immediates lower reads off the AST:**
- `v128.const` — the **16 immediate bytes** (`bytes: BitArray`, little-endian lane layout).
- `i8x16.shuffle` — the **16 lane indices** (`lanes: List(Int)`, each `0..31`).
- `extract_lane`/`replace_lane` — the **lane index** (`lane: Int`).
- the v128-memory instructions — a **`MemArg(align, offset, mem)`** (the `mem` index defaults
  to `0`, exactly as the Phase-5 scalar loads/stores); the lane family additionally carries a
  **lane index** (`lane: Int`).
- `ast.ValType` gains **`V128`** (a v128 param/local/blocktype/result); `to_ir_vt` maps it.

The remaining SIMD instructions carry no immediate — their whole meaning is the opcode,
which the AST constructor names. **Validate (P6-04) has already range-checked every lane
index and shuffle index** (`extract`/`replace` lane `< lanes-of-shape`; shuffle indices
`0..31`); lower keeps only fail-closed insurance (§ soundness).

---

## B. `v128` value & const lowering

`v128` is a **low-level fixed-width value** (I1/I2), the numeric path — never a term. At
runtime it is a 16-byte binary (`<<_:128>>`); in the IR its type is **`TV128`** and its
literal is **`ConstV128(bytes)`** holding the exact 16 raw little-endian bytes (D5 — the
bits, so every lane value, NaN payload, and `-0.0` is exact).

**`v128.const` → a pushed value literal (no `Let`).** Exactly like a numeric const, a
`v128.const` reduces to a `Value` and is pushed onto the abstract stack — no fresh binding,
no `Expr`:

```gleam
ast.V128Const(bytes) -> go(tail, ctx, push(st, ir.ConstV128(bytes)))
```

The 16 bytes come straight from decode (P6-03); lower forwards them verbatim. Per
[valid/instructions#constant-expressions](https://webassembly.github.io/spec/core/valid/instructions.html#constant-expressions)
`v128.const` is a **constant instruction**, so a `v128` global initialiser is `v128.const`
— `lower_const_expr` gains the arm (§I).

**`v128` value-type plumbing (§I):** `to_ir_vt` gains `ast.V128 -> ir.TV128`; `value_type`
gains `ir.ConstV128(_) -> ir.TV128`; `zero_value`/`zero_init` gains a v128 all-zero literal
(a declared `v128` local zero-inits to `<<0:128>>` per
[exec/instructions](https://webassembly.github.io/spec/core/exec/instructions.html), local
initialisation — a numeric zero). See §I.

**Splat is not a const.** `iNxM.splat`/`fNxM.splat` build a `v128` from a **runtime scalar**;
they are pure lane ops (`Simd(SSplat(shape), [x])`, §C), not literals.

---

## C. Integer-lane SIMD ops → `Simd(op, args)`

Every pure lane-wise integer instruction lowers through one `simd_op/1` mapping (the SIMD
analogue of `num_op/1`): it returns `#(arity, ir.SimdOp)`, and the `go/3` leaf routes it to
`emit_value_op_t(arity, simdop_result_type(op), fn(args){ ir.Simd(op, args) }, …)` — the
**same shape** as a numeric op. `emit_value_op_t` pops `arity` operands (in push order,
deepest-first — the WASM stack-type left→right order), binds `Simd(op, args)` to a fresh
name of the op's result type, pushes it, records the type, and lowers the continuation. Per
[exec/instructions#vector-instructions](https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions).

Operand order follows the spec stack types exactly. A binary op `[v128 v128] → [v128]` pops
`b` (top) then `a` (deeper); `take_push_order` returns `[a, b]`, so `Simd(op, [a, b])`. A
shift `[v128 i32] → [v128]` yields `[v, count]`. `v128.bitselect` `[v128 v128 v128] → [v128]`
yields `[v1, v2, mask]`. `iNxM.replace_lane` `[v128 t] → [v128]` yields `[vec, x]`.
`i8x16.swizzle` `[v128 v128] → [v128]` yields `[a, idx]`.

**`SimdOp` is width-and-lane-tagged and NEUTRAL** (never a WASM opcode string — D6), the same
discipline as `NumOp`. lower carries the neutral `SimdOp`; the ~236-way explosion into
concrete per-lane heads is confined to `rt_simd` (P6-07), which `emit_core` binds one
`SimdOp` constructor → one `rt_simd` function (the binding chokepoint, exactly like
`NumOp`→`rt_num`). **`rt_simd` owns the exact per-lane semantics** (two's-complement wrap at
the *lane* width, shift-count mask mod lane bit-width, saturation, signed/unsigned per lane);
lower only names the op.

### C.1 Integer arithmetic, min/max, average, saturating add/sub

Shapes: `i8x16` / `i16x8` / `i32x4` / `i64x2` (an integer `SimdShape`). Not every op exists
for every shape (validate enforces this; lower maps only the instructions decode produced —
e.g. there is **no `i8x16.mul`**, and `avgr_u`/`q15`/`add_sat`/`sub_sat` exist only on the
narrow shapes). `arity` in the table is the operand count.

| instruction (per applicable shape) | stack type | arity | `SimdOp` | result |
|---|---|---|---|---|
| `iNxM.add` | `[v128 v128] → [v128]` | 2 | `SAdd(shape)` | `TV128` |
| `iNxM.sub` | `[v128 v128] → [v128]` | 2 | `SSub(shape)` | `TV128` |
| `iNxM.mul` (`i16x8`/`i32x4`/`i64x2`) | `[v128 v128] → [v128]` | 2 | `SMul(shape)` | `TV128` |
| `iNxM.neg` | `[v128] → [v128]` | 1 | `SNeg(shape)` | `TV128` |
| `iNxM.abs` | `[v128] → [v128]` | 1 | `SAbs(shape)` | `TV128` |
| `iNxM.min_s` | `[v128 v128] → [v128]` | 2 | `SMinS(shape)` | `TV128` |
| `iNxM.min_u` (`i8x16`/`i16x8`/`i32x4`) | `[v128 v128] → [v128]` | 2 | `SMinU(shape)` | `TV128` |
| `iNxM.max_s` | `[v128 v128] → [v128]` | 2 | `SMaxS(shape)` | `TV128` |
| `iNxM.max_u` (`i8x16`/`i16x8`/`i32x4`) | `[v128 v128] → [v128]` | 2 | `SMaxU(shape)` | `TV128` |
| `iNxM.avgr_u` (`i8x16`/`i16x8`) | `[v128 v128] → [v128]` | 2 | `SAvgrU(shape)` | `TV128` |
| `iNxM.add_sat_s` (`i8x16`/`i16x8`) | `[v128 v128] → [v128]` | 2 | `SAddSatS(shape)` | `TV128` |
| `iNxM.add_sat_u` (`i8x16`/`i16x8`) | `[v128 v128] → [v128]` | 2 | `SAddSatU(shape)` | `TV128` |
| `iNxM.sub_sat_s` (`i8x16`/`i16x8`) | `[v128 v128] → [v128]` | 2 | `SSubSatS(shape)` | `TV128` |
| `iNxM.sub_sat_u` (`i8x16`/`i16x8`) | `[v128 v128] → [v128]` | 2 | `SSubSatU(shape)` | `TV128` |

> **Deviation flag (argued below):** the provisional `SimdOp` omits **`SAddSatS/U`** and
> **`SSubSatS/U`** (the four saturating add/sub families that exist for `i8x16`/`i16x8`).
> They are real standardized instructions (spec §
> [SIMD/arithmetic](https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions))
> and lower must map them, so the enum needs these constructors. See *Deviations*.

### C.2 Shifts

`iNxM.shl` / `iNxM.shr_s` / `iNxM.shr_u` for all four integer shapes. Stack type `[v128 i32]
→ [v128]` — a **scalar i32 shift count** masked mod the lane bit-width (the mask is
`rt_simd`'s per-lane job, not lower's). `take_push_order` yields `[v, count]`.

| instruction | arity | `SimdOp` | result |
|---|---|---|---|
| `iNxM.shl` | 2 | `SShl(shape)` | `TV128` |
| `iNxM.shr_s` | 2 | `SShrS(shape)` | `TV128` |
| `iNxM.shr_u` | 2 | `SShrU(shape)` | `TV128` |

### C.3 Integer comparisons → a v128 lane mask

Each comparison yields a **v128 mask** (all-ones lanes for true, all-zeros for false — spec
§ SIMD comparisons), so the result type is `TV128`, **not** i32. `i8x16`/`i16x8`/`i32x4`
carry the full 10-op set (`eq`/`ne`/`lt_s`/`lt_u`/`gt_s`/`gt_u`/`le_s`/`le_u`/`ge_s`/`ge_u`);
`i64x2` carries only the **6** signed/equality ops (`eq`/`ne`/`lt_s`/`gt_s`/`le_s`/`ge_s` —
there is no unsigned i64x2 compare; validate enforces this).

| instruction | arity | `SimdOp` | result |
|---|---|---|---|
| `iNxM.eq` | 2 | `SEq(shape)` | `TV128` |
| `iNxM.ne` | 2 | `SNe(shape)` | `TV128` |
| `iNxM.lt_s` | 2 | `SLtS(shape)` | `TV128` |
| `iNxM.lt_u` (`i8x16`/`i16x8`/`i32x4`) | 2 | `SLtU(shape)` | `TV128` |
| `iNxM.gt_s` | 2 | `SGtS(shape)` | `TV128` |
| `iNxM.gt_u` (`i8x16`/`i16x8`/`i32x4`) | 2 | `SGtU(shape)` | `TV128` |
| `iNxM.le_s` | 2 | `SLeS(shape)` | `TV128` |
| `iNxM.le_u` (`i8x16`/`i16x8`/`i32x4`) | 2 | `SLeU(shape)` | `TV128` |
| `iNxM.ge_s` | 2 | `SGeS(shape)` | `TV128` |
| `iNxM.ge_u` (`i8x16`/`i16x8`/`i32x4`) | 2 | `SGeU(shape)` | `TV128` |

### C.4 v128 bitwise, boolean reductions, bitmask, popcnt

The bitwise ops are **shape-agnostic** (they operate on the whole 128-bit value); their
`SimdOp` carries no shape. `any_true` reduces the whole v128; `all_true`/`bitmask` are
shape-tagged (they reduce/pack per lane). `popcnt` exists only on `i8x16`.

| instruction | stack type | arity | `SimdOp` | result |
|---|---|---|---|---|
| `v128.not` | `[v128] → [v128]` | 1 | `VNot` | `TV128` |
| `v128.and` | `[v128 v128] → [v128]` | 2 | `VAnd` | `TV128` |
| `v128.or` | `[v128 v128] → [v128]` | 2 | `VOr` | `TV128` |
| `v128.xor` | `[v128 v128] → [v128]` | 2 | `VXor` | `TV128` |
| `v128.andnot` | `[v128 v128] → [v128]` | 2 | `VAndNot` | `TV128` |
| `v128.bitselect` | `[v128 v128 v128] → [v128]` | 3 | `VBitselect` | `TV128` |
| `v128.any_true` | `[v128] → [i32]` | 1 | `VAnyTrue` | `TI32` |
| `iNxM.all_true` | `[v128] → [i32]` | 1 | `SAllTrue(shape)` | `TI32` |
| `iNxM.bitmask` | `[v128] → [i32]` | 1 | `SBitmask(shape)` | `TI32` |
| `i8x16.popcnt` | `[v128] → [v128]` | 1 | `SPopcnt(I8x16)` | `TV128` |

> **Deviation flag:** the provisional spells popcnt as a bare `I8x16Popcnt`. For enum
> uniformity with the other shape-tagged unary ops I recommend `SPopcnt(SimdShape)`
> (constrained by validate to `I8x16`); either spelling maps the same instruction. See
> *Deviations* — this is cosmetic and defers to the keystone.

### C.5 Narrowing, widening (extend), extended-multiply, extadd-pairwise, dot, q15

These are the shape-changing integer ops — the taxonomy the provisional flags "enumerate
ALL". Each is a distinct `SimdOp` constructor (they are shape-specific, not shape-uniform).
lower maps the AST constructor 1:1; `rt_simd` implements the exact per-lane saturation /
sign-extension.

**Narrowing (saturating, two v128 → one v128; low half from `a`, high half from `b`):**

| instruction | arity | `SimdOp` | result |
|---|---|---|---|
| `i8x16.narrow_i16x8_s` | 2 | `I8x16NarrowI16x8S` | `TV128` |
| `i8x16.narrow_i16x8_u` | 2 | `I8x16NarrowI16x8U` | `TV128` |
| `i16x8.narrow_i32x4_s` | 2 | `I16x8NarrowI32x4S` | `TV128` |
| `i16x8.narrow_i32x4_u` | 2 | `I16x8NarrowI32x4U` | `TV128` |

**Widening / extend (one v128 → one v128; low or high half, signed or unsigned):**

| instruction | arity | `SimdOp` | result |
|---|---|---|---|
| `i16x8.extend_low_i8x16_s` | 1 | `I16x8ExtendLowI8x16S` | `TV128` |
| `i16x8.extend_high_i8x16_s` | 1 | `I16x8ExtendHighI8x16S` | `TV128` |
| `i16x8.extend_low_i8x16_u` | 1 | `I16x8ExtendLowI8x16U` | `TV128` |
| `i16x8.extend_high_i8x16_u` | 1 | `I16x8ExtendHighI8x16U` | `TV128` |
| `i32x4.extend_low_i16x8_s` | 1 | `I32x4ExtendLowI16x8S` | `TV128` |
| `i32x4.extend_high_i16x8_s` | 1 | `I32x4ExtendHighI16x8S` | `TV128` |
| `i32x4.extend_low_i16x8_u` | 1 | `I32x4ExtendLowI16x8U` | `TV128` |
| `i32x4.extend_high_i16x8_u` | 1 | `I32x4ExtendHighI16x8U` | `TV128` |
| `i64x2.extend_low_i32x4_s` | 1 | `I64x2ExtendLowI32x4S` | `TV128` |
| `i64x2.extend_high_i32x4_s` | 1 | `I64x2ExtendHighI32x4S` | `TV128` |
| `i64x2.extend_low_i32x4_u` | 1 | `I64x2ExtendLowI32x4U` | `TV128` |
| `i64x2.extend_high_i32x4_u` | 1 | `I64x2ExtendHighI32x4U` | `TV128` |

**Extended multiply (two v128 → one v128; low/high half, signed/unsigned):**

| instruction | arity | `SimdOp` | result |
|---|---|---|---|
| `i16x8.extmul_low_i8x16_s` | 2 | `I16x8ExtMulLowI8x16S` | `TV128` |
| `i16x8.extmul_high_i8x16_s` | 2 | `I16x8ExtMulHighI8x16S` | `TV128` |
| `i16x8.extmul_low_i8x16_u` | 2 | `I16x8ExtMulLowI8x16U` | `TV128` |
| `i16x8.extmul_high_i8x16_u` | 2 | `I16x8ExtMulHighI8x16U` | `TV128` |
| `i32x4.extmul_low_i16x8_s` | 2 | `I32x4ExtMulLowI16x8S` | `TV128` |
| `i32x4.extmul_high_i16x8_s` | 2 | `I32x4ExtMulHighI16x8S` | `TV128` |
| `i32x4.extmul_low_i16x8_u` | 2 | `I32x4ExtMulLowI16x8U` | `TV128` |
| `i32x4.extmul_high_i16x8_u` | 2 | `I32x4ExtMulHighI16x8U` | `TV128` |
| `i64x2.extmul_low_i32x4_s` | 2 | `I64x2ExtMulLowI32x4S` | `TV128` |
| `i64x2.extmul_high_i32x4_s` | 2 | `I64x2ExtMulHighI32x4S` | `TV128` |
| `i64x2.extmul_low_i32x4_u` | 2 | `I64x2ExtMulLowI32x4U` | `TV128` |
| `i64x2.extmul_high_i32x4_u` | 2 | `I64x2ExtMulHighI32x4U` | `TV128` |

**Extended add-pairwise (one v128 → one v128), dot product, q15:**

| instruction | arity | `SimdOp` | result |
|---|---|---|---|
| `i16x8.extadd_pairwise_i8x16_s` | 1 | `I16x8ExtAddPairwiseI8x16S` | `TV128` |
| `i16x8.extadd_pairwise_i8x16_u` | 1 | `I16x8ExtAddPairwiseI8x16U` | `TV128` |
| `i32x4.extadd_pairwise_i16x8_s` | 1 | `I32x4ExtAddPairwiseI16x8S` | `TV128` |
| `i32x4.extadd_pairwise_i16x8_u` | 1 | `I32x4ExtAddPairwiseI16x8U` | `TV128` |
| `i32x4.dot_i16x8_s` | 2 | `I32x4DotI16x8S` | `TV128` |
| `i16x8.q15mulr_sat_s` | 2 | `I16x8Q15MulrSatS` | `TV128` |

---

## D. Float-lane SIMD ops → `Simd(op, args)`

Shapes `f32x4` / `f64x2`. Same routing as §C (`emit_value_op_t` → `Simd(op, args)`), result
`TV128` for arithmetic/unary, `TV128` for comparisons (a lane mask). `rt_simd` owns the
**IEEE-754** semantics — **f32x4 single-rounding after every op**, spec NaN
propagation/canonicalisation, and the `min`/`max` vs `pmin`/`pmax` NaN/`-0.0` distinction
(I3). lower only names the op.

### D.1 Float arithmetic + unary

| instruction (per `f32x4`/`f64x2`) | stack type | arity | `SimdOp` | result |
|---|---|---|---|---|
| `fNxM.add` | `[v128 v128] → [v128]` | 2 | `FAdd(shape)` | `TV128` |
| `fNxM.sub` | `[v128 v128] → [v128]` | 2 | `FSub(shape)` | `TV128` |
| `fNxM.mul` | `[v128 v128] → [v128]` | 2 | `FMul(shape)` | `TV128` |
| `fNxM.div` | `[v128 v128] → [v128]` | 2 | `FDiv(shape)` | `TV128` |
| `fNxM.min` | `[v128 v128] → [v128]` | 2 | `FMin(shape)` | `TV128` |
| `fNxM.max` | `[v128 v128] → [v128]` | 2 | `FMax(shape)` | `TV128` |
| `fNxM.pmin` | `[v128 v128] → [v128]` | 2 | `FPMin(shape)` | `TV128` |
| `fNxM.pmax` | `[v128 v128] → [v128]` | 2 | `FPMax(shape)` | `TV128` |
| `fNxM.neg` | `[v128] → [v128]` | 1 | `FNeg(shape)` | `TV128` |
| `fNxM.abs` | `[v128] → [v128]` | 1 | `FAbs(shape)` | `TV128` |
| `fNxM.sqrt` | `[v128] → [v128]` | 1 | `FSqrt(shape)` | `TV128` |
| `fNxM.ceil` | `[v128] → [v128]` | 1 | `FCeil(shape)` | `TV128` |
| `fNxM.floor` | `[v128] → [v128]` | 1 | `FFloor(shape)` | `TV128` |
| `fNxM.trunc` | `[v128] → [v128]` | 1 | `FTrunc(shape)` | `TV128` |
| `fNxM.nearest` | `[v128] → [v128]` | 1 | `FNearest(shape)` | `TV128` |

### D.2 Float comparisons → a v128 lane mask

Full 6-op set for both float shapes.

| instruction | arity | `SimdOp` | result |
|---|---|---|---|
| `fNxM.eq` | 2 | `FEq(shape)` | `TV128` |
| `fNxM.ne` | 2 | `FNe(shape)` | `TV128` |
| `fNxM.lt` | 2 | `FLt(shape)` | `TV128` |
| `fNxM.le` | 2 | `FLe(shape)` | `TV128` |
| `fNxM.gt` | 2 | `FGt(shape)` | `TV128` |
| `fNxM.ge` | 2 | `FGe(shape)` | `TV128` |

### D.3 Splat (scalar → v128)

`iNxM.splat` / `fNxM.splat` for all six shapes. Stack type `[t] → [v128]` where `t` is the
lane scalar (`i32` for `i8x16`/`i16x8`/`i32x4` splat, `i64` for `i64x2`, `f32`/`f64` for the
float splats). lower forwards the scalar `Value` — it does not care about the scalar's type.

| instruction | arity | `SimdOp` | result |
|---|---|---|---|
| `iNxM.splat` / `fNxM.splat` | 1 | `SSplat(shape)` | `TV128` |

### D.4 Conversions (integer↔float lane conversions; narrowing/widening float↔float)

These are the shape-specific conversions — **enumerate ALL** (the provisional's word). Each
is one operand → one v128; `rt_simd` owns the exact IEEE-754 conversion + saturation.

| instruction | arity | `SimdOp` | result |
|---|---|---|---|
| `i32x4.trunc_sat_f32x4_s` | 1 | `I32x4TruncSatF32x4S` | `TV128` |
| `i32x4.trunc_sat_f32x4_u` | 1 | `I32x4TruncSatF32x4U` | `TV128` |
| `i32x4.trunc_sat_f64x2_s_zero` | 1 | `I32x4TruncSatF64x2SZero` | `TV128` |
| `i32x4.trunc_sat_f64x2_u_zero` | 1 | `I32x4TruncSatF64x2UZero` | `TV128` |
| `f32x4.convert_i32x4_s` | 1 | `F32x4ConvertI32x4S` | `TV128` |
| `f32x4.convert_i32x4_u` | 1 | `F32x4ConvertI32x4U` | `TV128` |
| `f32x4.demote_f64x2_zero` | 1 | `F32x4DemoteF64x2Zero` | `TV128` |
| `f64x2.convert_low_i32x4_s` | 1 | `F64x2ConvertLowI32x4S` | `TV128` |
| `f64x2.convert_low_i32x4_u` | 1 | `F64x2ConvertLowI32x4U` | `TV128` |
| `f64x2.promote_low_f32x4` | 1 | `F64x2PromoteLowF32x4` | `TV128` |

---

## E. Lane access (`extract`/`replace`) and byte shuffle / swizzle

**`extract_lane` / `replace_lane` — the lane immediate rides on the `SimdOp`.** These are the
only lane ops whose `SimdOp` carries an integer immediate (the static lane index), exactly as
the provisional pins (`SExtractLaneS(shape, lane)`). lower reads `lane` off the AST
constructor and threads it into the `SimdOp`. `extract_lane_s`/`extract_lane_u` yield a
**scalar** (so `simdop_result_type` returns the lane's scalar type, not `TV128`);
`replace_lane` yields a v128.

| instruction | stack type | arity | `SimdOp` | result |
|---|---|---|---|---|
| `i8x16.extract_lane_s` | `[v128] → [i32]` | 1 | `SExtractLaneS(I8x16, lane)` | `TI32` |
| `i8x16.extract_lane_u` | `[v128] → [i32]` | 1 | `SExtractLaneU(I8x16, lane)` | `TI32` |
| `i16x8.extract_lane_s` | `[v128] → [i32]` | 1 | `SExtractLaneS(I16x8, lane)` | `TI32` |
| `i16x8.extract_lane_u` | `[v128] → [i32]` | 1 | `SExtractLaneU(I16x8, lane)` | `TI32` |
| `i32x4.extract_lane` | `[v128] → [i32]` | 1 | `SExtractLane(I32x4, lane)` | `TI32` |
| `i64x2.extract_lane` | `[v128] → [i64]` | 1 | `SExtractLane(I64x2, lane)` | `TI64` |
| `f32x4.extract_lane` | `[v128] → [f32]` | 1 | `SExtractLane(F32x4, lane)` | `TF32` |
| `f64x2.extract_lane` | `[v128] → [f64]` | 1 | `SExtractLane(F64x2, lane)` | `TF64` |
| `i8x16.replace_lane` | `[v128 i32] → [v128]` | 2 | `SReplaceLane(I8x16, lane)` | `TV128` |
| `i16x8.replace_lane` | `[v128 i32] → [v128]` | 2 | `SReplaceLane(I16x8, lane)` | `TV128` |
| `i32x4.replace_lane` | `[v128 i32] → [v128]` | 2 | `SReplaceLane(I32x4, lane)` | `TV128` |
| `i64x2.replace_lane` | `[v128 i64] → [v128]` | 2 | `SReplaceLane(I64x2, lane)` | `TV128` |
| `f32x4.replace_lane` | `[v128 f32] → [v128]` | 2 | `SReplaceLane(F32x4, lane)` | `TV128` |
| `f64x2.replace_lane` | `[v128 f64] → [v128]` | 2 | `SReplaceLane(F64x2, lane)` | `TV128` |

> **Deviation flag:** the provisional gives only `SExtractLaneS`/`SExtractLaneU` (the signed
> variants that apply to the narrow shapes) and does not name the **plain** `extract_lane`
> for `i32x4`/`i64x2`/`f32x4`/`f64x2` (which have no sign variant). I recommend a plain
> `SExtractLane(shape, lane)` constructor alongside the `S`/`U` pair. See *Deviations*.

**`extract`/`replace` operand order.** `replace_lane`'s stack type is `[v128 t] → [v128]` —
the vector is pushed first (deeper), the scalar second (top); `take_push_order(stack, 2) =
[vec, x]`, so `Simd(SReplaceLane(shape, lane), [vec, x])`. `extract_lane` pops one v128 →
`Simd(SExtractLane*(shape, lane), [v])`. Because the lane immediate is on the `SimdOp` and
the arity is fixed, these route through the ordinary `simd_op/1` + `emit_value_op_t` path
(the immediate travels inside the returned `SimdOp`). **Validate guarantees `lane <
lanes-of-shape`** (`16`/`8`/`4`/`2`); lower does not re-check it (fail-closed insurance only).

**`i8x16.swizzle`** — a **dynamic** byte permute: `[v128 v128] → [v128]`, first operand the
data `a`, second the indices `s`; an out-of-range index (`≥ 16`) yields lane `0`
(`rt_simd`'s semantics). It is shape-uniform (no immediate), so it rides the `simd_op/1`
table:

| instruction | arity | `SimdOp` | result |
|---|---|---|---|
| `i8x16.swizzle` | 2 | `I8x16Swizzle` | `TV128` |

**`i8x16.shuffle`** — a **static** byte permute selecting 16 bytes from `a ++ b` (32 bytes)
by **16 immediate indices**, each `0..31` (validate range-checks them). Its 16 immediates do
not fit the `simd_op/1` `#(arity, SimdOp)` shape, so it lowers via a **dedicated `go/3`
arm** to the dedicated `SimdShuffle(lanes, a, b)` node:

```gleam
ast.I8x16Shuffle(lanes) ->
  emit_value_op_t(
    2,
    ir.TV128,
    fn(args) {
      case args {
        [a, b] -> ir.SimdShuffle(lanes, a, b)
        _ -> ir.SimdShuffle(lanes, ir.ConstV128(<<0:size(128)>>), ir.ConstV128(<<0:size(128)>>))
      }
    },
    tail, ctx, st,
  )
```

Stack type `[v128 v128] → [v128]`; `take_push_order` yields `[a, b]` (spec: byte `lanes[i]`
selects from `a` if `< 16`, else `b[lanes[i]-16]`). The 16 indices flow verbatim from decode;
lower does not reorder or validate them (P6-04 did). Per
[exec/instructions#vector-instructions](https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions),
`i8x16.shuffle`.

> **`SimdShuffle` is a dedicated node (agree with the provisional).** A `Simd(op, args)`
> cannot carry 16 static indices without a bespoke `SimdOp` field; a dedicated `Expr` node
> keeps `SimdOp` uniform and prints cleanly in `.ir` (P6-02). Ratified.

---

## F. SIMD memory ops → `SimdLoad` / `SimdStore` / `SimdLoadLane` / `SimdStoreLane`

The v128 memory family routes through the **existing bounds-checked `rt_mem` seam** (I6/D3a)
— it is **NOT** a raw term/binary op. lower emits **dedicated `Expr` nodes** (agree with the
provisional open-Q (a): `MemLoad`'s `result: ValType` + `MemAccess(bytes, signed)` do not
stretch to the splat/extend/zero/lane shapes); emit_core (P6-06) composes each into a
bounds-checked `rt_mem` load/store of the right byte-width, and `rt_simd` (P6-07) supplies
the pure lane-assembly helpers. **Every access is bounds-checked → `MemoryOutOfBounds`
before any partial effect** — that trap is `rt_mem`'s, not lower's. Per
[exec/instructions#vector-memory-instructions](https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions)
and [SIMD/memory](https://webassembly.github.io/spec/core/syntax/instructions.html#vector-instructions).

Each carries the **memory index** (`MemArg.mem`, default `0`) and the **static offset**
(`MemArg.offset`). The loads produce a v128 (bound via `emit_value_op_t`); the stores are
**zero-result effects** (sequenced via `emit_effect` — never dropped, I6).

### F.1 Plain / splat / extend / zero loads → `SimdLoad(mem, kind, addr, offset)`

Stack type `[iAddr] → [v128]` (`iAddr` is `i32` for a 32-bit memory, `i64` for a 64-bit
memory — a value-width fact, §G). `take_push_order(stack, 1) = [addr]`. The `SimdLoadKind`
selects the load flavour:

| instruction | `SimdLoadKind` | bytes read | result |
|---|---|---|---|
| `v128.load` | `V128` | 16 | `TV128` |
| `v128.load8_splat` | `Splat(1)` | 1 | `TV128` |
| `v128.load16_splat` | `Splat(2)` | 2 | `TV128` |
| `v128.load32_splat` | `Splat(4)` | 4 | `TV128` |
| `v128.load64_splat` | `Splat(8)` | 8 | `TV128` |
| `v128.load8x8_s` | `Extend(I16x8, True)` | 8 | `TV128` |
| `v128.load8x8_u` | `Extend(I16x8, False)` | 8 | `TV128` |
| `v128.load16x4_s` | `Extend(I32x4, True)` | 8 | `TV128` |
| `v128.load16x4_u` | `Extend(I32x4, False)` | 8 | `TV128` |
| `v128.load32x2_s` | `Extend(I64x2, True)` | 8 | `TV128` |
| `v128.load32x2_u` | `Extend(I64x2, False)` | 8 | `TV128` |
| `v128.load32_zero` | `Zero(4)` | 4 | `TV128` |
| `v128.load64_zero` | `Zero(8)` | 8 | `TV128` |

```gleam
ast.V128Load(m) -> emit_simd_load(m.mem, ir.V128, m.offset, tail, ctx, st)
ast.V128Load8Splat(m) -> emit_simd_load(m.mem, ir.Splat(1), m.offset, tail, ctx, st)
ast.V128Load8x8S(m) -> emit_simd_load(m.mem, ir.Extend(ir.I16x8, True), m.offset, tail, ctx, st)
// … one arm per load flavour; emit_simd_load binds SimdLoad(mem, kind, addr, offset): TV128
fn emit_simd_load(mem, kind, offset, tail, ctx, st) {
  emit_value_op_t(1, ir.TV128,
    fn(args) {
      case args {
        [addr] -> ir.SimdLoad(mem, kind, addr, offset)
        _ -> ir.SimdLoad(mem, kind, ir.ConstI32(0), offset)
      }
    }, tail, ctx, st)
}
```

> **`SimdLoadKind.Extend` naming pin (deviation, argued below).** The provisional writes
> `Extend(from_shape, signed)`. The load's meaning is fully determined by the **result**
> shape (`I16x8←i8`, `I32x4←i16`, `I64x2←i32`), so I recommend `Extend(result_shape:
> SimdShape, signed: Bool)`. `Splat(width)` / `Zero(width)` are **byte** counts (1/2/4/8 and
> 4/8). See *Deviations*.

### F.2 `v128.store` → `SimdStore(mem, addr, value, offset)`

Stack type `[iAddr v128] → []`; `take_push_order(stack, 2) = [addr, value]` (address deeper,
value on top). A **zero-result effect** (evaluation order addr → value → store, preserved by
the straight-line `Let([], …)` sequencing):

```gleam
ast.V128Store(m) ->
  emit_effect(2,
    fn(a) {
      case a {
        [addr, value] -> ir.SimdStore(m.mem, addr, value, m.offset)
        _ -> ir.SimdStore(m.mem, ir.ConstI32(0), ir.ConstV128(<<0:size(128)>>), m.offset)
      }
    }, tail, ctx, st)
```

### F.3 Lane load/store → `SimdLoadLane` / `SimdStoreLane`

`v128.loadN_lane` loads `N` bits (N ∈ {8,16,32,64}) from memory into lane `lane` of an
**input vector** `vec`, yielding the modified v128; `v128.storeN_lane` stores lane `lane` of
`vec` (N bits) to memory. Stack type `[iAddr v128] → [v128]` (load) / `[iAddr v128] → []`
(store) — the address is pushed first (deeper), the vector second (top);
`take_push_order(stack, 2) = [addr, vec]`. Both carry the memidx, the static offset, the
**lane immediate**, and the access **width** (bytes: `1`/`2`/`4`/`8`).

| instruction | node | width (bytes) | shape |
|---|---|---|---|
| `v128.load8_lane` | `SimdLoadLane(mem, 1, addr, offset, lane, vec)` | 1 | value → `TV128` |
| `v128.load16_lane` | `SimdLoadLane(mem, 2, addr, offset, lane, vec)` | 2 | value → `TV128` |
| `v128.load32_lane` | `SimdLoadLane(mem, 4, addr, offset, lane, vec)` | 4 | value → `TV128` |
| `v128.load64_lane` | `SimdLoadLane(mem, 8, addr, offset, lane, vec)` | 8 | value → `TV128` |
| `v128.store8_lane` | `SimdStoreLane(mem, 1, addr, offset, lane, vec)` | 1 | zero-result effect |
| `v128.store16_lane` | `SimdStoreLane(mem, 2, addr, offset, lane, vec)` | 2 | zero-result effect |
| `v128.store32_lane` | `SimdStoreLane(mem, 4, addr, offset, lane, vec)` | 4 | zero-result effect |
| `v128.store64_lane` | `SimdStoreLane(mem, 8, addr, offset, lane, vec)` | 8 | zero-result effect |

```gleam
ast.V128Load32Lane(m, lane) ->
  emit_value_op_t(2, ir.TV128,
    fn(a) {
      case a {
        [addr, vec] -> ir.SimdLoadLane(m.mem, 4, addr, m.offset, lane, vec)
        _ -> ir.SimdLoadLane(m.mem, 4, ir.ConstI32(0), m.offset, lane, ir.ConstV128(<<0:size(128)>>))
      }
    }, tail, ctx, st)
ast.V128Store32Lane(m, lane) ->
  emit_effect(2,
    fn(a) {
      case a {
        [addr, vec] -> ir.SimdStoreLane(m.mem, 4, addr, m.offset, lane, vec)
        _ -> ir.SimdStoreLane(m.mem, 4, ir.ConstI32(0), m.offset, lane, ir.ConstV128(<<0:size(128)>>))
      }
    }, tail, ctx, st)
```

> **`SimdLoadLane.width` unit pin (deviation).** The provisional writes `width: Int` and its
> comment says "N bits". I pin `width` to **bytes** (`1`/`2`/`4`/`8`) for consistency with
> `MemAccess.bytes` (the existing scalar convention) — so `v128.load32_lane` carries `width =
> 4`, not `32`. See *Deviations*; the keystone freezes the field.

---

## G. memory64 — delete the rejection, thread the i64 address width

P5 shipped decode + validate for memory64 and made `lower/1` **reject** a 64-bit memory
(`reject_memory64/1 → Error(Memory64Unsupported)`, R12). Phase 6 (I4) **removes the
rejection** and makes a 64-bit memory lower. Concretely:

1. **Delete `reject_memory64/1` and its `use _ <- result.try(reject_memory64(module))` call
   in `lower/1`.** A 64-bit memory now flows straight through.
2. **Delete the `Memory64Unsupported` `LowerError` variant** (it is no longer produced). Its
   module-doc paragraph is rewritten to describe the runtime. *(Cross-unit seam: the
   conformance harness's `Memory64Unsupported → categorized skip` mapping is removed — P6-10
   owns that; `memory64.wast` now runs. Flagged §cross-unit.)*
3. **`to_ir_idxtype` already maps `ast.Idx64 → ir.Idx64` faithfully** (it was reachable only
   defensively under R12; it is now the live path). `lower_memory` /
   `lower_imports`/`ImportMemory` already carry `to_ir_idxtype(mt.idx_type)` onto the decls
   — so the `Idx64` axis reaches the IR **with no code change beyond deleting the guard**.

**The address width is a value-width fact + a per-memory `idx_type`, not a lower branch.**
This is exactly the Phase-5 stance ("no `i32`/`i64` branch in any instruction arm"), now
un-deferred:
- The `dest`/`src`/`count`/`addr` operands of a 64-bit memory's load/store/size/grow/fill/
  copy/init (scalar **and** SIMD-memory) are already `ir.Value`s the **validator typed
  `TI64`**; lower forwards whatever the SSA stack holds. There is **no width branch** in any
  memory arm.
- The per-access width that emit_core needs (i32 vs i64 bounds arithmetic) is **derivable
  from the node's `mem: Int` index + the module's memory decls** (`Module.memories[mem]
  .idx_type` for a defined memory, or the matching `ImportMemory.idx_type` for an imported
  one). So **no address-width field is threaded onto any memory node** — the `mem` index is
  the key, and the `idx_type` already rides on the decls. This keeps a 32-bit memory's nodes
  **byte-identical** (`MemLoad(0, …)`/`SimdLoad(0, …)` are unchanged) and confines the
  64-bit arithmetic entirely to emit_core (P6-06) + `rt_mem` (P6-08).
- `memory.size`/`memory.grow` on a 64-bit memory take/return **i64** page counts — again a
  value-width fact: `MemSize(mem)`/`MemGrow(mem, delta)` are unchanged nodes; the validator
  typed the delta/result i64, and emit_core threads the width from `mem`'s `idx_type`.

> **Why no width field on the nodes?** Threading an `IdxType` onto every `MemLoad`/`MemStore`/
> `SimdLoad*` would (a) break byte-identity (a 32-bit node would gain a field), and (b)
> duplicate a fact already on `MemoryDecl.idx_type`, risking drift. Deriving the width from
> the `mem` index is the single-source-of-truth choice and is byte-identical by construction.
> **Cross-unit seam (06/08):** emit_core must look up `mem → idx_type` from the module decls
> when it lowers a memory node; lower guarantees the decls carry the right `idx_type`. Flagged.

**Page cap.** lower never sees the documented page cap (I4) — it is a `Binding` field (01
freezes, 08 pins) and a **runtime trap boundary** (`grow` beyond it → `-1`; an access beyond
current size → `MemoryOutOfBounds`). lower's contract is unchanged by it.

**Tier fail-closed.** `atomics`/`nif` keep their 32-bit reserve model and fail closed for an
over-cap 64-bit memory (P6-08's gate) — a **runtime/link** concern, not lower's. lower emits
the same `Idx64` decl regardless of tier.

---

## H. Cross-module function imports → the IR call shape

P5's `lower_call/4` rejects a call to an imported function:

```gleam
case f < ctx.imported {
  True -> Error(Unsupported("imported call"))   // ← Phase 5
  ...
}
```

Phase 6 (I5/R4) lowers it to a **positional-slot import-call** that emit_core dispatches via
the **linker-built closure capability** — `apply(Closure, Args)` over a handed-in closure, a
capability exactly like `externref`/`call_host`, **NOT** an ambient `apply` of an
attacker-chosen `module:atom` (D3a). The closure is supplied explicitly at link time and
held by its **positional import slot** (P5 R4: positional, name-free), never a runtime name
lookup in generated code.

**The IR shape: `CallImport(slot: Int, ty: FuncType, args: List(Value))`** (my recommended
node; argued in *Deviations*). `slot` is the **imported funcidx `f`** — the function-import
position in the module's import order, which *is* `f` because function imports occupy funcidx
`0..imported_func_count-1` (imports-first index space). `ty` is the imported function's
signature (for arity + robustness, mirroring `CallIndirect`), recovered from
`nth_err(ctx.func_types, f)` (which spans `imports ++ defined`). The `go/3` `ast.Call(f)` arm
routes to `lower_call`; the changed body:

```gleam
fn lower_call(f, tail, ctx, st) {
  use sig <- result.try(nth_err(ctx.func_types, f, UnknownFuncIndex(f)))
  let pcount = list.length(sig.params)
  let rcount = list.length(sig.results)
  let args = take_push_order(st.stack, pcount)
  case list.length(args) == pcount {
    False -> Error(StackUnderflow)
    True -> {
      let rest_stack = list.drop(st.stack, pcount)
      let #(names, c2) = fresh_n(st.counter, rcount)
      let result_vars = list.map(names, ir.Var)
      let st2 = record_types(
        LState(..st, stack: list.append(list.reverse(result_vars), rest_stack), counter: c2),
        list.zip(names, list.map(sig.results, to_ir_vt)))
      use inner <- result.try(go(tail, ctx, st2))
      let call = case f < ctx.imported {
        True  -> ir.CallImport(f, ir_functype(sig), args)   // ← Phase 6: positional import slot
        False -> ir.CallDirect("f" <> int.to_string(f), args)
      }
      Ok(wrap_let(names, call, inner))
    }
  }
}
```

Note `lower_call` now needs the callee signature for **both** branches (Phase 5 fetched it
only in the defined branch); the fetch moves to the top, and `ctx.func_types` already spans
`imports ++ defined`, so the imported signature is available.

**This is the unified provided-function dispatch (I5).** The provider of slot `f` is decided
at **link time** (P6-09): it may be another wasm instance's exported function
(`linking.wast`) **or** the build-fixed `spectest` registry (`print`/`print_i32`/… — R14) —
in both cases `link_imports` builds a `ProvidedFunc(ty, call)` whose `call` is a closure
capturing the target, and emit_core lowers `CallImport(slot, ty, args)` to
`apply(closure_at(slot), Args)`. **lower stays neutral** — it does not know (and must not
depend on) whether the provider is a wasm instance or the host registry; it emits the same
positional-slot node, and the linker supplies the closure. *(This is why Phase-5's
spectest-`print` calls were a categorized skip: `lower_call` rejected them. `CallImport`
un-skips them along with cross-module wasm calls — a single mechanism.)*

**`ref.func` of an imported function + `call_indirect` (seam, flagged).** `ref.func x` where
`x` is an imported funcidx still lowers to `RefFunc("f<x>")` (unchanged); a `call_indirect`
through a table holding such a funcref dispatches dynamically and needs no lower change.
**But** `RefFunc(fn_name)` names a *defined* function — for an imported target, emit_core +
link must resolve `f<x>` (an imported funcidx) to the **provided closure** wrapped as a
funcref value. lower cannot construct that (it has no closure); it emits `RefFunc("f<x>")`
and **flags this as a P6-06/P6-09 seam** (emit_core recognises an imported funcidx and
materialises the provided closure as the funcref). This is the `linking.wast`
`(elem (ref.func $imported))` case. lower's scope is the **direct** imported call
(`CallImport`); the ref.func-of-import resolution is downstream. Flagged §cross-unit.

**Host-capability vs provided-instance (seam, flagged).** In the 2core model
`CallHost(capability, name, args)` is the deny-all host boundary (for a Porffor `rt_host`
shim, Phase 7). A cross-module wasm import + spectest are **provided closures**, not
host-capabilities, so they lower to `CallImport`. Distinguishing "this import is a
policy-gated host function" from "this import is a provided instance's function" is a
**link-time policy decision** lower does not have a fact for (the `TypedModule` carries no
link policy). The neutral default — **lower always emits `CallImport` for an imported wasm
function call, and the linker decides the closure's provenance** — is correct for the Phase-6
conformance target (spectest + `linking.wast`) and defers the host-capability routing to the
linker/09. If the keystone/09 want lower to emit `CallHost` for a designated host-capability
import, that needs a new `TypedModule` fact — flagged as *Open questions* #3.

---

## I. `v128` SSA plumbing, declared locals, and const-expr

**`to_ir_vt` gains the v128 arm** so a `v128` param/local/blocktype/result lowers correctly:

```gleam
fn to_ir_vt(t: ast.ValType) -> ir.ValType {
  case t {
    ast.I32 -> ir.TI32   ast.I64 -> ir.TI64
    ast.F32 -> ir.TF32   ast.F64 -> ir.TF64
    ast.FuncRef -> ir.TFuncRef   ast.ExternRef -> ir.TExternRef
    ast.V128 -> ir.TV128                              // NEW
  }
}
```

**`value_type` gains the v128 literal arm** (self-describing, like the numeric consts), so a
plain `select` over v128 operands recovers the type (v128 `select` uses `select_t` in
practice, but the arm keeps `value_type` total and robust):

```gleam
ir.ConstV128(_) -> ir.TV128
```

**Declared `v128` locals zero-init to all-zero bits.** A declared local of type `v128` is
zero-initialised to `v128.const i64x2 0 0` (all-zero — the numeric zero, per
[exec/instructions](https://webassembly.github.io/spec/core/exec/instructions.html) local
initialisation). `zero_value` gains:

```gleam
ir.TV128 -> ir.ConstV128(<<0:size(128)>>)             // 16 zero bytes, little-endian
```

(Numeric/reference locals are unchanged — byte-identical.) `var_types` records the v128
local's type at entry so a later `select_t`/op reading it recovers `TV128`.

**`lower_const_expr` accepts `v128.const` as a global initialiser.** Per
[valid/instructions#constant-expressions](https://webassembly.github.io/spec/core/valid/instructions.html#constant-expressions)
`v128.const` is a constant instruction, so a `v128` global's init is `v128.const`:

```gleam
[ast.V128Const(bytes)] -> Ok(ir.Values([ir.ConstV128(bytes)]))   // NEW arm
```

(Element items and data/table offsets are `i32`/`i64`/`funcref`/`externref`, never `v128`,
so only the global-init path uses it; the arm is added to the one shared `lower_const_expr`.)

**No new control frames, no `LoopParam` entanglement.** Every SIMD op is **flat**
(non-structural), so `scan_modified`/`consume_dead`/`build_transfer` handle them through
their existing wildcard arms — no change to the depth-tracking scanners (the P2-09/P5-05
pitfall note). A `v128.store`/`store_lane` mutates **instance memory** (the cell / threaded
record), not a WASM local, so — like `*.store`/`global.set` — it must **never** enter
`scan_modified`/`carried`/`LoopParam`. It does not, because those scanners only track
`local.set`/`local.tee`. A `v128` **local** carried through a loop is exactly a numeric local
carried through a loop — its `TV128` type flows via `carried_types`/`LoopParam` unchanged.

---

## Effect / soundness / security note

- **SIMD lane ops are pure; SIMD memory ops are effect barriers (I6).** `Simd`/`SimdShuffle`
  are pure (referentially transparent, no trap, no state); `SimdLoad`/`SimdStore`/
  `SimdLoadLane`/`SimdStoreLane` read/write mutable memory and are barriers. The
  classification is `ir/effect.gleam`'s (keystone 01/02 reach), not lower's. lower's only
  obligation is the P2-09 one: never drop a zero-result effect (it sequences
  `SimdStore`/`SimdStoreLane` as `Let([], …, cont)`) and never reorder (a straight-line
  walk). Pure `Simd` ops are bound with a fresh name via `emit_value_op_t`, exactly like
  `Num`.
- **`v128` is opaque in Safe mode; its only trap surface is the SIMD memory load/store**,
  which routes through the **existing bounds-checked `rt_mem` seam** → `MemoryOutOfBounds`
  before any partial effect. `v128` cannot address memory except through the checked seam.
  Worst case of a SIMD lowering bug is a wrong-shaped node caught by the differential oracle
  (P6-10) — a wrong result or a node-safe crash, **never a host escape** (I6).
- **memory64 keeps every access bounds-checked → trap.** lower forwards the i64 address
  operand unchanged; the 64-bit bounds arithmetic + the page-cap trap boundary are `rt_mem`'s
  (P6-08). lower enforces no bound — a 64-bit bounds bug's worst case is a wrong/missing trap
  or a node-safe crash, never an escape.
- **Cross-module imports are fail-closed capabilities (I6/D3a).** An unsatisfied/mismatched
  function import fails at **link time** (`assert_unlinkable`, P6-09), not in lower. lower
  emits a **positional-slot** `CallImport(slot, …)` — no name, no ambient `apply`; the
  closure is handed in at link time. lower's worst failure is a wrong slot caught by the
  differential oracle, never a name-based escape. *(P6-06's extended D3a security test
  grep-verifies no ambient `apply(Module, Fn, Args)` of an attacker-named atom in generated
  code.)*
- **Fail-closed, total.** Out-of-scope (relaxed-SIMD / GC ops) ⇒ `Error(Unsupported(_))`; a
  non-const init ⇒ `Error(NonConstInitExpr(_))`; an under-deep stack ⇒ `Error(StackUnderflow)`
  (only reachable on an unvalidated module — fail-closed insurance). **Never**
  `panic`/`let assert`. No new `LowerError` variant is required; the `Memory64Unsupported`
  variant is **removed** (its case is now handled, not rejected).
- **Conformance-neutral by default (I7).** The obligation is *negative*: a module with no
  `v128`, a single 32-bit memory, and no cross-module function imports lowers to
  **byte-identical** IR4. Enforced by the additive SIMD arms (dead for a non-SIMD module),
  the dead `Idx64` path (a 32-bit memory maps `Idx32` exactly as before), and the
  `CallImport` arm firing only for `f < ctx.imported` (a case Phase-5 rejected).

## Verification — Definition of Done (D8)

Tests assert **spec behaviour / the spec's opcode meaning**, not whatever the code emits (no
change-detector tests). Fixtures are `wat.gleam`/`wat2wasm` programs decoded+validated
through P6-03/04, then lowered; cite the SIMD/memory64/linking spec section in each test.

1. **v128 value & const (spec §
   [SIMD/const](https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions)).**
   `v128.const i32x4 1 2 3 4` ⇒ a pushed `ConstV128(<16 little-endian bytes>)` whose bytes
   are the exact spec encoding (assert the byte pattern, including a NaN-payload/`-0.0` lane
   is preserved bit-for-bit — D5). A `v128` global initialised by `v128.const` ⇒
   `GlobalDecl("g<i>", TV128, _, Values([ConstV128(bytes)]))`. A declared `v128` local
   zero-inits to `ConstV128(<<0:128>>)`.
2. **Integer lane ops (§C, per spec opcode meaning).** For a representative op in each family
   and each applicable shape, assert the exact `Simd(op, args)` with the right shape, arity,
   operand order, and result type: `i32x4.add` ⇒ `Simd(SAdd(I32x4), [a, b])`:`TV128`;
   `i8x16.add_sat_s` ⇒ `Simd(SAddSatS(I8x16), [a, b])`; `i16x8.shl` ⇒ `Simd(SShl(I16x8),
   [v, count])`; `i32x4.lt_u` ⇒ `Simd(SLtU(I32x4), [a, b])`:`TV128` (a **mask**, not i32);
   `v128.bitselect` ⇒ `Simd(VBitselect, [v1, v2, mask])`; `i8x16.all_true` ⇒
   `Simd(SAllTrue(I8x16), [v])`:`TI32`; `i8x16.bitmask`/`v128.any_true` ⇒ `TI32`;
   `i32x4.dot_i16x8_s`/`i16x8.q15mulr_sat_s` ⇒ their nodes; the narrow/extend/extmul/extadd
   families ⇒ their exact constructors (assert at least one low + one high + one s + one u).
3. **Float lane ops (§D).** `f32x4.add`/`f64x2.div` ⇒ `Simd(FAdd(F32x4)/FDiv(F64x2), [a,
   b])`:`TV128`; `f32x4.sqrt` ⇒ `Simd(FSqrt(F32x4), [v])`; `f32x4.pmin`/`f64x2.pmax` ⇒
   `FPMin`/`FPMax` (distinct from `FMin`/`FMax`); `f32x4.eq` ⇒ `Simd(FEq(F32x4), [a,
   b])`:`TV128`; every conversion (`i32x4.trunc_sat_f32x4_s`, `f32x4.convert_i32x4_u`,
   `f32x4.demote_f64x2_zero`, `f64x2.promote_low_f32x4`, the `_zero`/`_low` variants) ⇒ its
   exact constructor.
4. **Lane access & shuffle (§E).** `i8x16.extract_lane_s 3` ⇒ `Simd(SExtractLaneS(I8x16, 3),
   [v])`:`TI32`; `i64x2.extract_lane 1` ⇒ `TI64`; `f64x2.extract_lane 0` ⇒ `TF64`;
   `i32x4.replace_lane 2` ⇒ `Simd(SReplaceLane(I32x4, 2), [vec, x])`:`TV128`;
   `i8x16.shuffle 0 1 … 15` (16 indices) ⇒ `SimdShuffle([0,1,…,15], a, b)` with the indices
   **verbatim and in order**; `i8x16.swizzle` ⇒ `Simd(I8x16Swizzle, [a, idx])`. Assert the
   lane immediate and shuffle indices are carried unchanged.
5. **SIMD memory (§F, spec § vector memory).** `v128.load` ⇒ `SimdLoad(0, V128, addr,
   offset)`:`TV128`; `v128.load32_splat`/`load8x8_u`/`load64_zero` ⇒ `SimdLoad(0,
   Splat(4)/Extend(I16x8,False)/Zero(8), …)`; `v128.store` ⇒ `SimdStore(0, addr, value,
   offset)` (zero-result effect, `Let([], …)`); `v128.load32_lane 2` ⇒ `SimdLoadLane(0, 4,
   addr, offset, 2, vec)`:`TV128`; `v128.store64_lane 1` ⇒ `SimdStoreLane(0, 8, addr,
   offset, 1, vec)` (effect). Assert the memidx (a non-zero memidx under multi-memory carries
   `mem: 1`), the static offset, the width (bytes), the lane, and the operand order.
6. **memory64 (§G).** A module with a 64-bit memory (`(memory i64 1)`) **lowers** (no
   `Memory64Unsupported` — the variant is gone): `MemoryDecl(min, max, Idx64)`; an
   `i64.load`/`v128.load` against it lowers with the i64 address `Value` forwarded unchanged
   (no width branch in the arm); `memory.size`/`memory.grow` lower to `MemSize(mem)`/
   `MemGrow(mem, delta)` unchanged (the delta typed i64 by validate). An imported 64-bit
   memory ⇒ `ImportMemory(_, _, min, max, Idx64)`. A 32-bit memory ⇒ `Idx32`, **byte-identical**.
7. **Cross-module function import (§H).** A module importing `(func (param i32) (result
   i32))` and calling it (funcidx `0`) ⇒ `CallImport(0, FuncType([TI32], [TI32]),
   [arg])` bound to a fresh result name (assert the slot = the imported funcidx, the signature
   carried, and the args in push order). A call to a **defined** function is unchanged
   (`CallDirect("f<idx>", args)`). A module importing spectest `print_i32` and calling it ⇒
   `CallImport(slot, FuncType([TI32], []), [arg])` sequenced as a zero-result effect.
8. **Conformance-neutral default (I7) — the negative obligation.** The entire Phase-1..5
   acceptance corpus + previously-passing suite lowers to IR4 that is **byte-identical** to
   Phase-5 (a non-SIMD/single-32-bit-memory/no-cross-module-import module). Prove via `.ir`
   round-trip equality (P6-02) or structural `ir.Module` equality against the Phase-5 golden.
   This is the load-bearing test.
9. **Fail-closed (no panic).** A **relaxed-SIMD** op (e.g. `f32x4.relaxed_madd`) ⇒
   `Error(Unsupported(_))`; a GC-proposal op ⇒ `Error(Unsupported(_))`; an out-of-range
   func/type index ⇒ the matching `LowerError`. **Never** `panic`/`let assert`. (Lane-index
   and shuffle-index range are validate's, §soundness — but a defensive out-of-range lane
   still produces a well-formed node, never a crash.)
10. **End-to-end (proven at the capstone, P6-11):** representative SIMD programs (integer +
    float lane arithmetic, a shuffle, a swizzle, a `bitselect`, a v128 load/store round-trip,
    an extend/narrow, a dot product), a 64-bit-memory round-trip, and a `linking.wast`
    cross-module call run **spec-differentially correct** through the full pipeline (against
    `wasmtime` / the `rebuild` oracle). lower is on that path; its output is the oracle's input.
11. `gleam format --check src test` clean; `gleam build` **zero warnings**; `gleam test`
    stays green with **no Phase-1..5 regression** (conformance `fail == 0`). Every
    new/changed public/private function carries a doc comment stating its contract
    (what/params/returns/failure modes — D8).

## What this unit leaves for others

- **P6-01 (keystone)** freezes the IR4 nodes lower emits (`TV128`, `ConstV128`, `SimdShape`,
  `SimdOp`, `Simd`/`SimdShuffle`/`SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`,
  `SimdLoadKind`, `CallImport`) and the effect classification of each. lower re-syncs on the
  exact field spelling; the instruction→IR mapping is fixed.
- **P6-02 (`.ir` textual)** round-trips every node lower emits: `v128.const` (16-byte hex),
  each `SimdOp` (neutral name), the shuffle indices, the SIMD-memory forms (memidx/offset/
  lane/width), `CallImport`'s positional slot, and the `Idx64` memory forms — and a legacy
  module prints byte-identically.
- **P6-03 (decode)** publishes `«WASM-AST4»` — the constructors §A matches (the `0xFD`
  prefix + all ~236 sub-opcodes, `v128.const`, shuffle/lane immediates, the v128-memory
  instructions + memarg + lane immediates, and `ast.ValType`'s `V128`). lower re-syncs on
  the exact spelling; the opcode→IR mapping is fixed. **Decode owns the opcode bytes**; lower
  matches constructors.
- **P6-04 (validate)** is the security boundary upstream: it types `v128` on the abstract
  stack, range-checks every lane index (`< lanes-of-shape`) and shuffle index (`0..31`),
  types i64 addressing for a 64-bit memory, and matches the cross-module function-import
  signatures — **before** lower runs. lower assumes a validated, in-scope module and keeps
  its `LowerError`s only as fail-closed insurance.
- **P6-06 (emit_core)** consumes every node lower emits: each `SimdOp` → the `rt_simd`
  function (the binding chokepoint); `SimdLoad*`/`SimdStore*` → the bounds-checked `rt_mem`
  compose; a 64-bit memory node → i64 addressing/bounds (**deriving the width from the `mem`
  index + the module's memory `idx_type`** — the seam lower guarantees the decls carry);
  `CallImport(slot, …)` → `apply(closure_at(slot), Args)`; `ref.func` of an imported funcidx
  → the provided closure as a funcref (the seam §H flags). It also extends the D3a security
  test (SIMD purity + the closure-dispatch no-ambient-authority proof).
- **P6-07 (rt_simd)** implements the ~236 concrete per-lane heads (bit-exact, `rt_num`-reusing)
  behind the `SimdOp` names lower emits, and the v128 lane-assembly helpers the SIMD-memory
  compose uses.
- **P6-08 (rt_mem)** implements the 64-bit bounds arithmetic + the documented page cap + the
  bounds-checked v128 memory slices; `atomics`/`nif` fail-closed for an over-cap 64-bit memory.
- **P6-09 (cross-module linking)** builds the `ProvidedFunc(ty, call)` closure for each
  imported-function slot (another instance's export **or** the spectest registry) and the
  fail-closed `link_imports` function matching; resolves `ref.func` of an imported funcidx.
- **P6-10 (conformance)** lights up `simd/*.wast`, `memory64.wast`, `linking.wast`, removes
  the `memory64 runtime → Phase 6` categorized skip, and differential-checks the new surface.

## Deviations from the provisional surface

Every refinement below is argued so the critique + reconciliation can adjudicate; each is a
**cross-unit seam** the keystone (01) freezes.

1. **`CallImport(slot, ty, args)` — a dedicated import-call node (vs the provisional's "emit
   reuses `CallDirect`/`CallIndirect`").** The provisional §G says emit_core lowers "an
   imported-function `CallDirect`/`CallIndirect` target to `apply(Closure, Args)`". Reusing
   `CallDirect` overloads its documented meaning ("a direct call to a **same-module** function
   by name") and forces emit_core to reconstruct the set of imported function names to detect
   an import — a name-based reasoning R4 (positional, name-free) and D3a (no name lookup) want
   to avoid. A dedicated `CallImport(slot: Int, ty: FuncType, args: List(Value))`: (a) makes
   the positional-slot capability **explicit and legible** in the IR and `.ir` (P6-02 prints
   `call_import 0 …`), (b) keeps `CallDirect` meaning exactly what its doc says, (c) surfaces
   the security boundary (an auditor sees every cross-instance/host call site), and (d)
   round-trips cleanly. **Fallback:** if the keystone keeps `CallDirect`-reuse, lower's arm
   changes trivially (emit `CallDirect(iname(f), args)` with an import-naming `iname`), and
   emit_core owns the import-set reconstruction; the *mapping* is fixed either way. Seam: 01/06/09.
2. **`SimdOp` gains the saturating add/sub families `SAddSatS/U`, `SSubSatS/U`.** The
   provisional `SimdOp` enum omits them, but `i8x16`/`i16x8` `add_sat_s/u` + `sub_sat_s/u` are
   **eight real standardized instructions** lower must map. Without these constructors the
   mapping is impossible. Seam: 01 (add the constructors), 07 (implement).
3. **`SimdOp` gains a plain `SExtractLane(shape, lane)`** alongside the provisional's
   `SExtractLaneS`/`SExtractLaneU`. `i32x4`/`i64x2`/`f32x4`/`f64x2` extract has **no sign
   variant**; a plain constructor is cleaner than overloading `SExtractLaneS` with a
   "signedness ignored" convention. (Cosmetic; the keystone may instead keep the `S` variant
   for all and document the ignored flag — the mapping is fixed.) Seam: 01/07.
4. **`SimdLoadKind.Extend(result_shape: SimdShape, signed: Bool)`** (vs provisional
   `Extend(from_shape, signed)`), and **`Splat(width)`/`Zero(width)` are byte counts**
   (`1`/`2`/`4`/`8` and `4`/`8`). The load's meaning is fully fixed by the result shape
   (`I16x8←i8`, `I32x4←i16`, `I64x2←i32`); naming the result shape is unambiguous and matches
   how rt_simd re-encodes. Seam: 01/06/07.
5. **`SimdLoadLane`/`SimdStoreLane` `width` is in bytes** (`1`/`2`/`4`/`8`), not bits, for
   consistency with `MemAccess.bytes` (the provisional comment ambiguously said "N bits").
   Seam: 01/06/07.
6. **`SPopcnt(SimdShape)` (vs the provisional's bare `I8x16Popcnt`).** Cosmetic — a
   shape-tagged unary constructor is uniform with the other unary ops; validate constrains it
   to `I8x16`. Either spelling maps the one instruction. Seam: 01/07.
7. **The `Memory64Unsupported` `LowerError` variant is removed** (the keystone's provisional
   "minimal compile-satisfying arm" for lower may keep it). It is no longer produced (memory64
   lowers); keeping it dead would warn under `gleam build` zero-warnings. Removing it changes
   the conformance harness's skip mapping — **P6-10 owns that** (the `memory64 runtime → Phase
   6` skip is deleted). Seam: lower removes it; 10 updates the skip categorisation.

## Open questions (for the planner / cross-unit reconciliation)

1. **AST4 SIMD constructor shape (P6-03 seam).** §A: flat `Instr` constructors (Phase-5
   idiom) vs a `ast.Simd(SimdInstr)` wrapper. lower handles either (one extra pattern nest
   for the wrapper); the mapping is fixed. Confirm at `«WASM-AST4»` publish so the golden
   byte-identical test targets the right shape.
2. **`CallImport` vs `CallDirect`-reuse (keystone seam — Deviation #1).** Confirm the keystone
   freezes `CallImport`; if not, lower emits `CallDirect` with an import-naming convention and
   emit_core owns the import-set detection.
3. **Host-capability vs provided-instance import routing (link-policy seam).** lower emits
   `CallImport` for **every** imported wasm function call (the linker decides the closure's
   provenance — a provided instance, spectest, or a host capability). If the design wants
   lower to emit `CallHost` for a designated policy-gated host-capability import, the
   `TypedModule` needs a new link-policy fact lower does not currently have. Recommend keeping
   lower neutral (linker decides); flagged for 09/reconciliation.
4. **`ref.func` of an imported funcidx (06/09 seam).** lower emits `RefFunc("f<x>")` for an
   imported target; emit_core + link must materialise the provided closure as the funcref
   (the `linking.wast` `(elem (ref.func $imported))` case). Confirm 06/09 own the resolution;
   lower's mapping is unchanged.
5. **Per-access memory width derivation (06/08 seam — §G).** lower carries `idx_type` on the
   memory decls and does **not** thread a width field onto the memory nodes; emit_core derives
   the i32/i64 arithmetic width from the node's `mem` index → `Module.memories[mem].idx_type`
   (or the matching `ImportMemory`). Confirm 06 owns this lookup (it keeps 32-bit nodes
   byte-identical). If reconciliation instead wants an explicit width field on the nodes, it
   breaks byte-identity — recommend against.
6. **`SimdOp` taxonomy completeness (01/07 seam).** This doc enumerates every standardized
   SIMD instruction → its `SimdOp`/node (§C/§D/§E/§F). The keystone freezes the exact enum;
   Deviations #2–#6 note the constructors the provisional's sketch was missing/ambiguous.
   rt_simd (07) is the authority on which `(op, shape)` pairs exist (validate enforces it);
   lower maps only the instructions decode produced.
