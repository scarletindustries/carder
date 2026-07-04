# Phase 9 · Unit 01 — MemorySSA + linear-memory alias analysis (the keystone)

> **One owner · Wave 0 · the phase's load-bearing correctness unit.** Read
> [`00-overview.md`](00-overview.md) (M1–M8) and the design note
> [`../future-work-memory-optimizer.md`](../future-work-memory-optimizer.md) first; Phase-1 D1–D10,
> Phase-2 E1–E8, Phase-3 F1–F8 still hold. This unit ships the shared **analysis** every Phase-9
> rewrite rests on — the access-footprint model, the alias oracle, the memory-barrier classifier,
> the reaching-value (`avail`) map type, and the extended termination measure — and **nothing that
> rewrites the IR**. An unsound `alias` or a too-narrow barrier set is **silent memory corruption**,
> so this unit ships with **adversarial fixtures** and lands GREEN with the optimizer pipeline
> **still empty** (identity — the corpus stays byte-identical until unit 04 wires the passes in).

---

## Context

Phase 3's `ir/effect.gleam` answers one question — *is this subtree observably pure?* — and
answers it **maximally conservatively for memory**: `can_cse` forbids **all** load CSE, because
"precise load-CSE ('no aliasing store between the two occurrences') needs an alias + reordering
analysis scoped as later work." **This unit is that analysis.** It does not replace `ir/effect`
(the passes still consult it for the general purity questions); it *refines* it for **memory
dependence** — the finer facts forwarding/RLE/DSE need: *does access A touch the same bytes as
access B?* and *does node N force us to forget what we know about memory?*

The analysis is **intraprocedural and per straight-line region** (M8): the passes walk a
`Let`-chain front-to-back threading an `avail` map, and **reset at every control-flow boundary**
(`If`/`Switch`/`Loop`/`Block`/`Try`). This keystone provides the *vocabulary* (footprints, the alias
lattice, the barrier set, the measure); units 02/03 provide the *walks*. Keeping the analysis in a
leaf module (`imports ir + ir/effect` only) lets `mem_forward` (02) and `mem_dse` (03) both consume
it without a cycle — exactly as `pass.gleam` sits below `baseline`/`aggressive`.

---

## Deliverables & the freeze milestone

**Consume (frozen upstream):**

- `ir.gleam` (`«IR4-FROZEN»` and later) — the `Expr` surface, in particular
  `MemLoad(mem, op, addr, offset, result)` and `MemStore(mem, op, addr, value, offset)` with
  `op: MemAccess(bytes, signed)`, and the `Value`/`ValType` types. **No IR change** (M4).
- `ir/effect.gleam` (unit 02/Phase-3) — `is_effectful_node/1`, the shallow barrier test this unit
  builds `is_memory_barrier` on top of.

**Produce (`«MEM-SSA-FROZEN»`):**

- `src/twocore/middle/ir_opt/mem_ssa.gleam` (**NEW**, owned) — the analysis surface below.
- `test/twocore/optimize/mem_ssa_test.gleam` (**NEW**) — the alias-lattice + barrier-set + measure
  spec/property tests, including the adversarial "must be `MayAlias`" / "must be a barrier" fixtures.

No pipeline edit; `ir_opt.pipeline(Baseline)` stays `baseline.baseline_passes()` (identity for the
memory layer). The corpus is **byte-identical** after this unit — it only *adds* a module + tests.

---

## A. The frozen analysis surface

```gleam
//// middle/ir_opt/mem_ssa — MemorySSA + linear-memory alias analysis (M1, the keystone).
//// Imports `ir` and `ir/effect` ONLY (a leaf below the memory passes in the DAG). Provides the
//// vocabulary the alias-aware rewrites (units 02/03) rest on; performs NO rewrite itself.

import gleam/dict.{type Dict}
import twocore/ir
import twocore/ir/effect

/// The **access footprint** of a memory op: exactly which bytes of which memory it touches
/// (M1/M4). All four fields are kept DISTINCT — `addr + offset` is NEVER folded (M4, the
/// invariant that keeps the IR analyzable) — because disambiguation reasons over them separately:
/// two accesses through the SAME base `addr` at DIFFERENT constant `offset`s are the tractable
/// disjoint case.
///
/// - `mem`: the memory index (memories are disjoint address spaces — different `mem` ⇒ `NoAlias`).
/// - `addr`: the dynamic base operand (a `Value` — a `Var` or a `Const*`). Compared by SYNTACTIC
///   equality only (M5): Phase 9 does NOT value-number bases beyond ==.
/// - `offset`: the static memarg byte offset (an `Int` ≥ 0).
/// - `bytes`: the access width in bytes (`op.bytes`) — the length of the touched byte range
///   `[offset, offset + bytes)`. Drives range-overlap disambiguation.
pub type Footprint {
  Footprint(mem: Int, addr: ir.Value, offset: Int, bytes: Int)
}

/// The alias relationship between two footprints — the safety lattice (M5). CONSERVATIVE: the
/// default answer is `MayAlias`; `MustAlias`/`NoAlias` are returned ONLY with a structural proof.
///
/// - `MustAlias`: the two accesses touch the EXACT same bytes (same `mem`, syntactically-equal
///   base, same `offset`, same `bytes`). A store's value may be forwarded to a must-alias load;
///   a store may be killed by a must-alias later store.
/// - `NoAlias`: the two accesses PROVABLY touch disjoint bytes (different `mem`, or same base with
///   disjoint `[offset, offset+bytes)` ranges). Neither can observe or clobber the other.
/// - `MayAlias`: cannot prove either — a different/unknown base, or an overlapping-but-not-equal
///   range. The optimizer must treat this as a clobber (no forward, no reuse across it).
pub type AliasResult {
  MustAlias
  NoAlias
  MayAlias
}

/// The **reaching-value map** the forwarding/RLE pass (unit 02) threads through a straight-line
/// region: a footprint ↦ the `Value` currently known to be at those bytes (the value a
/// non-truncating store wrote, or the name a prior natural-width load bound). Keyed by the full
/// `Footprint`, so a lookup by an identical footprint IS a `MustAlias` lookup (equal footprints are
/// `MustAlias` by construction — see `alias`). Unit 02 owns the transfer function that maintains it
/// (insert on store/load, invalidate on aliasing store, clear on a barrier); this type + the
/// helpers below are the shared vocabulary.
pub type Avail =
  Dict(Footprint, ir.Value)

/// Extract the `Footprint` of a memory access `Expr`, or `Error(Nil)` if `e` is not a scalar
/// linear-memory access. Returns `Ok` for exactly `MemLoad` and `MemStore` (the two scalar
/// per-access nodes the analysis reasons about). Bulk-memory ops (`MemFill`/`MemCopy`/`MemInit`)
/// and SIMD memory ops are NOT footprints — they are barriers (`is_memory_barrier`), because a
/// range write cannot be disambiguated against a scalar footprint (M5). Total; never panics.
pub fn footprint_of(e: ir.Expr) -> Result(Footprint, Nil)

/// The alias oracle (M5) — the safety gate. Total; never panics; DEFAULTS to `MayAlias`.
///
/// - different `mem` ⇒ `NoAlias`.
/// - same `mem`, `a.addr == b.addr` (syntactically-equal `Value`): compare the byte ranges
///   `[offset, offset+bytes)` — identical range ⇒ `MustAlias`; disjoint ranges ⇒ `NoAlias`;
///   partial overlap ⇒ `MayAlias`.
/// - same `mem`, `a.addr != b.addr` (different or unknown base) ⇒ `MayAlias` (undecidable; Phase 9
///   does not value-number bases — the honest ceiling, M8).
pub fn alias(a: Footprint, b: Footprint) -> AliasResult

/// Does node `e` force the analysis to FORGET everything it knows about linear memory (M5)? A
/// barrier clears the `avail` map (forwarding/RLE) and stops DSE look-ahead. Built on
/// `ir/effect.is_effectful_node` and STRICTLY MORE CONSERVATIVE where memory is concerned.
///
/// Barriers (`True`): `MemGrow` (reallocates); every call
/// (`CallDirect`/`CallIndirect`/`CallHost`/`CallImport`/`CallClosure` — may touch any memory);
/// every bulk-memory op (`MemFill`/`MemCopy`/`MemInit`/`DataDrop`); the four SIMD memory ops
/// (`SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`); every non-returning / control-flow
/// transfer (`Trap`/`Throw`/`ThrowRef`/`Return`/`Break`/`Continue`) and the structured region
/// heads (`Loop`/`If`/`Switch`/`Block`/`Try` — the analysis is per straight-line region, so a
/// region boundary is a reset).
///
/// Memory-transparent (`False` — do NOT clear memory knowledge): `MemLoad`/`MemStore` (they are
/// footprints, handled precisely by the transfer function, NOT blanket barriers); `GlobalGet`/
/// `GlobalSet` (the globals cell is disjoint from linear memory and cannot trap); and every pure
/// value op (`Values`/`Num`/`Convert`/`TermOp`/`Simd`/`SimdShuffle`/`MakeClosure`/`MapOp`/
/// `TermTest`/`TermTag`/reference constructors that only read a slot… — see the code for the
/// exhaustive split). NOTE: a `MemLoad`/`MemStore` returning `False` here does NOT mean "ignore
/// it" — the caller handles footprints explicitly; `is_memory_barrier` answers only "must I forget
/// everything?". Total; the `case` is exhaustive so a new `Expr` variant fails to compile until it
/// is classified (fail-closed, D4).
pub fn is_memory_barrier(e: ir.Expr) -> Bool

/// The byte width of a value type — the natural in-memory footprint of a full-width access
/// (M3/M7 truncation guard). `Ok(4)` for `TI32`/`TF32`, `Ok(8)` for `TI64`/`TF64`, `Ok(16)` for
/// `TV128`; `Error(Nil)` for reference/term types (`TTerm`/`TFuncRef`/`TExternRef`/`TExnRef` — not
/// linear-memory-representable). The forwarding pass uses this to reject TRUNCATING stores
/// (`i64.store32`, `i32.store8`, …) as forward sources and SUB-WIDTH loads (`i32.load8_u`, …) as
/// forward targets: a store/load is *natural-width* iff `op.bytes == byte_width(value/result
/// type)`, and only natural-width accesses move a value faithfully (§C). Total.
pub fn byte_width(t: ir.ValType) -> Result(Int, Nil)

/// The `n_mem` component of the extended termination measure (M7): the number of `MemLoad` +
/// `MemStore` nodes anywhere in `m`. No Phase-9 pass (and no baseline pass) ever CONSTRUCTS one, so
/// `n_mem` is monotonically non-increasing across the `run_pipeline` fixpoint and every *changing*
/// memory rewrite strictly decreases it — which keeps the fixpoint well-founded when the memory
/// passes are appended (unit 04). Exposed so the capstone can assert convergence/monotonicity over
/// the corpus. Total.
pub fn count_mem_ops(m: ir.Module) -> Int
```

**Freeze bodies are REAL, not `todo`.** Every function above ships a complete, conservative,
tested body in unit 01 (there is nothing to defer — the analysis is the deliverable). `alias`
defaults to `MayAlias`, `is_memory_barrier` defaults to `True` for anything not proven transparent —
the safe directions.

---

## B. The alias oracle — the exact algorithm (and why each arm is sound)

```gleam
pub fn alias(a: Footprint, b: Footprint) -> AliasResult {
  case a.mem == b.mem {
    False -> NoAlias                    // disjoint address spaces (multi-memory)
    True ->
      case a.addr == b.addr {           // SYNTACTIC equality of the base Value (Var name / Const)
        False -> MayAlias               // different/unknown base — undecidable (M8 ceiling)
        True -> range_alias(a.offset, a.bytes, b.offset, b.bytes)
      }
  }
}
```

`range_alias(oa, la, ob, lb)` over the byte intervals `[oa, oa+la)` and `[ob, ob+lb)`:

| Condition | Result | Why |
|---|---|---|
| `oa == ob && la == lb` | `MustAlias` | identical byte range through the same base — the same bytes |
| `oa + la <= ob` **or** `ob + lb <= oa` | `NoAlias` | the intervals are disjoint (the Array-SSA element disambiguation: `base+0`/4B vs `base+4`/4B) |
| otherwise (overlap, not identical) | `MayAlias` | partial overlap — a store to `base+0`/4B partly clobbers `base+2`/4B |

**Soundness of each arm.**
- **`NoAlias` on different `mem`** — WASM memories are separate address spaces; a write to memory 0
  cannot be observed through memory 1 (spec §4.2). Sound.
- **`MayAlias` on a different base** — Phase 9 does **not** prove two distinct `Var`s denote
  disjoint addresses (that needs value-numbering / induction-variable ranges — deferred, M8). So it
  refuses to disambiguate: the caller treats it as a clobber. This is the *conservative* direction,
  so it can never cause an unsound rewrite — only a missed one. (The honest ceiling: the win comes
  from the SAME base reused with different constant offsets, the shape compilers emit.)
- **`MustAlias`/`NoAlias`/`MayAlias` on the same base** — pure integer interval arithmetic on the
  static `offset`/`bytes`; deterministic and exact. The `offset`s are the WASM memarg constants
  (never negative), `bytes` the access width — both known at compile time.

**The load-bearing adversarial requirement (the "must be `MayAlias`" fixtures).** The test suite
pins that `alias` returns `MayAlias` (never `NoAlias`/`MustAlias`) for: two DIFFERENT `Var` bases at
the same offset; a `Var` base vs a `ConstI32` base; overlapping-but-unequal same-base ranges
(`off 0 / 4B` vs `off 2 / 4B`); and same base + same offset but DIFFERENT widths (`4B` vs `8B` →
overlap, not identical → `MayAlias`). A future "optimization" that narrows any of these to
`NoAlias`/`MustAlias` breaks a fixture — this is the tripwire against silent memory corruption.

---

## C. The truncation guard (`byte_width`) — why it is in the keystone

Two accesses with the SAME `Footprint` (same `mem`/`addr`/`offset`/`bytes`) still do **not** move
a value faithfully unless both are **natural-width**. The hazards Phase 9 must exclude:

- **Sub-width load** (`i32.load8_u`: `bytes = 1`, `result = TI32` whose `byte_width = 4`). It
  zero/sign-extends one byte into a 4-byte value — the loaded value is a *transformation* of the
  bytes, not their verbatim content. Excluded as a forward *target*: a load is eligible only when
  `op.bytes == byte_width(result)`.
- **Truncating store** (`i64.store32`: `bytes = 4`, value type `TI64` whose `byte_width = 8`). It
  writes the low 4 bytes of an 8-byte value; forwarding the whole `i64` value into a 4-byte
  `i32.load` slot would forward bits the load never sees. Excluded as a forward *source*: a store
  populates `avail` only when `op.bytes == byte_width(type_of(value))`.

`byte_width` is the shared primitive both checks call. It lives in the keystone (a pure
`ValType → Int` fact, analysis-shared) while the *type-of-a-value* threading (a small
`Dict(String, ValType)` name→type environment seeded from `params`/`locals`) is unit 02's, since it
is specific to the forwarding transfer function. **Why natural-width forwarding is bit-exact even
across value types (the D5 point):** when a natural-width store and a natural-width load share a
footprint, they move the identical `bytes`-byte range; because 2core carries every scalar as its
**raw little-endian bit pattern in an Erlang integer** (D5), an `i32.store` followed by an
`f32.load` forwards the same integer bit pattern the `f32.load` would have assembled — the value
`Value` is a faithful representative regardless of the two ends' `ValType`s, *provided* neither
truncates nor extends. The fixtures pin this (a stored `i32` forwarded to an `f32.load` at the same
footprint is bit-identical to the round-tripped load).

---

## D. The extended termination measure (M7)

The Phase-3 fixpoint (`pass.run_pipeline`) converges under `μ = (n_loops, n_ops, n_nodes, n_vars)`;
Phase 9 prepends the most-significant `n_mem = count_mem_ops(m)`:

```
μ₉(m) = ( n_mem , n_loops , n_ops , n_nodes , n_vars )
```

- **store→load forwarding / RLE** rewrite a `MemLoad` to `Values` ⟹ `n_mem` strictly ↓ (and never
  add a `Loop`/op/node).
- **dead-store elimination** removes a `MemStore` (and its enclosing `Let([], …)`) ⟹ `n_mem` ↓ and
  `n_nodes` ↓.
- **no Phase-9 pass, and no baseline pass, ever constructs a `MemLoad`/`MemStore`.** So `n_mem` is
  monotonically non-increasing across every round; a *changing* memory rewrite strictly decreases
  the most-significant component; the baseline passes keep strictly decreasing the lower-order
  components on their changing rounds (their measure argument is unchanged since they never touch
  `n_mem`). `μ₉` is bounded below by `(0,0,0,0,0)`, so `run_pipeline` reaches the fixpoint well
  before `max_rounds`, and no pass can undo another. `count_mem_ops` is exposed so the capstone
  (unit 04) can assert this monotonicity holds over the whole corpus (no non-convergence, no panic,
  no growth in `n_mem`).

This unit does not change `run_pipeline`; it only *provides* `count_mem_ops` and *states* the
argument that unit 04's registration preserves.

---

## E. Verification (Definition of Done — D8)

Tests assert **spec/analysis behaviour** and the **safety invariants**, cite the reasoning, and are
**not** change-detectors. "Done" = the suite passes — never "it compiles".

1. **`alias` lattice — positive.** `MustAlias` for identical footprints; `NoAlias` for different
   `mem`, and for same-base disjoint ranges (`base+0`/4B vs `base+4`/4B, either order).
2. **`alias` lattice — adversarial (the tripwires, §B).** `MayAlias` for two different `Var` bases,
   a `Var` vs a `Const` base, overlapping-unequal same-base ranges, and same-base same-offset
   different-width. **Property test:** for random footprints, `alias` is symmetric
   (`alias(a,b) == alias(b,a)`), and `MustAlias ⟹ a == b` (equal footprints), and `NoAlias ⟹` the
   byte intervals are genuinely disjoint (re-derived test-side) — so a `NoAlias` is never a lie.
3. **`is_memory_barrier` — the barrier set.** `True` for `MemGrow`, each call kind, each bulk-mem
   op, each SIMD-memory op, each control transfer, and each structured region head; `False` for
   `MemLoad`/`MemStore`/`GlobalGet`/`GlobalSet` and the pure value ops. **Adversarial:** assert a
   `CallHost`/`MemGrow`/`MemFill` IS a barrier (the "must forget" fixtures) — a future narrowing
   that lets memory knowledge survive a call breaks this.
4. **`byte_width` + the truncation guard.** `byte_width(TI32) == Ok(4)`, `(TI64) == Ok(8)`,
   `(TV128) == Ok(16)`, `(TTerm)/(TFuncRef)/… == Error(Nil)`. Fixtures showing an
   `i32.load8_u`/`i64.store32` footprint is NOT natural-width (`op.bytes != byte_width(type)`) while
   an `i32.load`/`i64.store` is.
5. **`count_mem_ops`.** Correct on a hand-built module (nested `Let`/`If`/`Loop` with a known number
   of `MemLoad`+`MemStore`); zero on a memory-free module.
6. **Green DoD.** `gleam format --check src test` clean; `gleam build` **zero warnings** (no
   `todo`/`panic`/`let assert` on any path — every function total); `gleam test` ≥ 1734 + the new
   tests, 0 failures; the WASM corpus **byte-identical** (this unit adds only a module + tests — the
   pipeline is untouched, so `optimize` is unchanged).

**Proof of goal:** a sound, symmetric, conservative `alias`; a fail-closed barrier set that forgets
everything on a call/grow/bulk/control; a truncation guard that rejects sub-width/truncating
accesses; and the `n_mem` measure — all pinned by adversarial fixtures — so units 02/03 can build
alias-aware rewrites that **cannot** be unsound, and unit 04 can append them without breaking the
fixpoint.

---

## What this unit leaves for others

- **Unit 02** (`mem_forward`) consumes `Footprint`/`AliasResult`/`alias`/`is_memory_barrier`/`Avail`/
  `byte_width` to build the straight-line-region transfer function (thread `avail`, insert on
  natural-width store/load, invalidate on `alias != NoAlias`, clear on `is_memory_barrier`) realizing
  **store→load forwarding + redundant-load elimination** — and owns the small name→`ValType` env the
  truncation guard needs.
- **Unit 03** (`mem_dse`) consumes the same surface for the **dead-store** look-ahead peephole
  (`MustAlias` later store, only-pure-between).
- **Unit 04** (capstone) appends `[mem_forward.…, mem_dse.…]` to `ir_opt.pipeline`'s `Baseline` arm
  (inherited by `Aggressive`), and uses `count_mem_ops` for the corpus-wide monotonicity/convergence
  assertion and the benchmark's deterministic elimination count.
