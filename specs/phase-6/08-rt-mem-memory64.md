# Unit P6-08 — `rt_mem` extension: the **memory64 runtime** (i64 addressing + the documented page cap)

> **One owner · Wave A · the memory-runtime completion unit for Phase 6.** Freeze deps:
> `«MEM64-RUNTIME»` (keystone **P6-01** doc-freezes the `Binding` page-cap field `mem64_max_pages`
> + the "`lower`/`link` accept `Idx64`" contract), and the frozen `IdxType { Idx32 Idx64 }` /
> `TrapReason` / `MemoryDecl` / `ImportMemory` shapes I consume (unchanged from Phase 5). Read
> [`00-overview.md`](00-overview.md) (I1–I8) then [`RECONCILIATION.md`](RECONCILIATION.md) (Phase-6
> S-decisions — AUTHORITATIVE) **before** this doc. This unit executes the **deferred half of R12**:
> Phase 5 shipped memory64 **decode + validate** and made `lower`/`link` **reject** a 64-bit memory
> (`Memory64Unsupported`); Phase 6 removes the rejection and makes a 64-bit memory **run**. It mirrors
> the structure of [`../phase-5/08-rt-mem.md`](../phase-5/08-rt-mem.md) (P5-08 §C is the design sketch
> this unit realises). Phase-1 D1–D10 / Phase-2 E1–E8 / Phase-3 F1–F8 / Phase-4 G1–G8 / Phase-5
> H1–H8 + R1–R18 all still hold.

---

## Context

`rt_mem` is the immutable, sparse, **paged** linear memory (Phase 2), joined by the tier-O
`atomics` backend (`rt_mem_atomics`, the O(1) lever) and the tier-N `nif` skeleton (`rt_mem_nif`,
node-safe, delegates to paged). Phase 5 (P5-08) added the finalized **bulk-memory** ops
(`memory.fill`/`copy`/`init`), **multiple memories** (index-routed `_at` heads over an `rt_state`
memories vector), and passive-data semantics — all held byte-for-byte to the flat-binary `rebuild`
oracle (E4) and green across `(state_strategy × mem_tier)`. Phase 5 deliberately **deferred the
64-bit-memory runtime to Phase 6** (R12): the `IdxType { Idx32 Idx64 }` axis stayed frozen in the
IR/AST, decode parsed the 64-bit limits flags (`0x04`/`0x05`), and validate typed `i64` addresses
correctly — but `lower.gleam`'s `reject_memory64` returned `Error(Memory64Unsupported)` for any
`Idx64` memory, so `memory64.wast` reported a **categorized skip** (`memory64 runtime → Phase 6`) and
`atomics`/`nif` never saw a 64-bit memory.

This unit closes that gap. The load-bearing observation — and why memory64 is **cheap and cleanly
localised** — is that the paged byte machinery is **already 64-bit-correct**: the frozen effective
address `ea = addr + offset` is a BEAM **bignum** and is **never masked** mod 2³²; `byte_len =
pages * 65536` is a bignum; `in_bounds`, the LE codec, `read_bytes`/`write_bytes`, and **every §B
bulk op from P5-08** already operate on bignums. So an `i64` address `> 2³²`, an offset `> 2³²`, and a
`byte_len > 2³²` already flow through the existing code **unchanged**. What is genuinely *new* is
exactly two things:

1. **A per-index-width page cap.** The frozen `hard_max_pages = 65_536` is the **i32** cap (2¹⁶ pages
   = 4 GiB). A 64-bit memory needs a much larger — but still **documented, honest, node-safe** — cap
   (§C). This is the single number this unit must pin against the spec, not guess (I4/I8, R12's
   deferred warning).
2. **`memory.size`/`memory.grow` take/return `i64` page counts** for a 64-bit memory (a value-layer
   width concern; the runtime returns a plain bignum `Int`, §B.3).

Everything else is byte-identical. A 32-bit memory decodes/validates/lowers/emits/**runs**
**byte-identically** to Phase 5 under both modes and every shipped tier + state strategy (I7/H7). The
security posture is unchanged and is the boundary (I6/H6): **little-endian**, **no-wrap effective
address → trap** (`ea` a bignum, never masked — this is *what makes memory64 safe*: a 64-bit bounds
bug's worst case is a wrong/missing trap or a node-safe process crash, **never a host escape**),
**eager bounds → trap before any write** (all-or-nothing), **f32/f64 as raw-byte moves** (D5). Every
64-bit access stays **bounds-checked → trap**; the page cap is a **hard trap boundary**; Safe forbids
tier-N as before.

## Goal

Make a **64-bit-indexed linear memory execute** — decode/validate/lower/**run** — with spec-exact
semantics, held to the spec and (at affordable sizes) to the `rebuild` oracle:

- **i64 addressing + 64-bit bounds arithmetic.** `load`/`store`/`fill`/`copy`/`init` on a 64-bit
  memory address bytes past 2³², with offsets past 2³², through the **same** bignum `ea`/`byte_len`
  machinery — no wrap, no mask, trap `MemoryOutOfBounds` exactly at `ea + N > byte_len`
  (spec `exec/instructions`, memory instructions).
- **`memory.size`/`memory.grow` on a 64-bit memory take/return i64 page counts** (§B.3); the runtime
  returns a bignum `Int`, `emit_core` (06) boxes it width-appropriately (`grow` failure `-1` → an i64
  all-ones for a 64-bit memory).
- **A documented, spec-aligned page cap** (§C) — the `Binding.mem64_max_pages` field, pinned to a
  **real constant with a spec citation, never a guess** (I4). `grow` beyond the cap returns `-1`
  (allocating nothing); an access beyond the *current* size traps `MemoryOutOfBounds` exactly where
  the spec's `assert_trap` expects.
- **`paged` (+ `portable`/threaded) ship it.** `atomics`/`nif` keep their 32-bit reserve model and
  **fail closed** for an over-cap 64-bit memory (§D) — a genuinely-large 64-bit memory whose reserve
  exceeds the tier's node-safe reserve cap is a **fail-closed link-time rejection** (no silent
  fallback, no silent 4 GiB pre-alloc); the tier matrix categorises it honestly.
- **32-bit heads byte-identical.** Every Phase-1..5 memory head keeps its exact prior body and
  signature for a 32-bit memory; the `effective_max` generalisation and the `mem_grow` cap
  simplification are proven behaviour-preserving for `Idx32` (§A.3, Verification #4).
- **Prove it.** Extend the flat-binary oracle with `o_fresh64` and drive the differential over
  **small bounded** 64-bit memories (paged ≡ atomics ≡ oracle); prove the **large-address** (> 2³²)
  behaviour with **direct spec-corner assertions** on the sparse paged core (the flat oracle cannot
  be materialised at 4 GiB+ — §E); transcribe `memory64.wast`/`address64.wast` corners.

## Files owned (single-owner · additive per D1)

- `src/twocore/runtime/rt_mem.gleam` — **EXTEND (additive).** The 64-bit `fresh64`/`fresh_mem64`
  builders + the `o_fresh64` oracle ctor; the `mem64_hard_max_pages` documented constant (§C); the
  generalised `effective_max_for(max, safe_cap, hard_cap)` fold (i32 `effective_max` delegates to it
  → byte-identical); the behaviour-preserving `mem_grow`/`o_grow` cap simplification (§A.3). The
  Phase-2/4/5 frozen heads and the pure `mem_*`/`o_*`/`a_*`-consumed core stay **byte-identical for
  `Idx32`**. The load/store/size/grow/fill/copy/init/`_at`/`t_*` heads are **reused verbatim** — they
  are already 64-bit-correct.
- `src/twocore/runtime/rt_mem_atomics.gleam` — **EXTEND (additive).** The idx-aware `reservation64` /
  `a_fresh64` (the fail-closed gate for an over-cap 64-bit memory; a *tiny bounded* 64-bit memory is
  admitted and runs correctly — §D). No change to the frozen 32-bit heads.
- `src/twocore/runtime/rt_mem_nif.gleam` — **EXTEND (additive).** The delegating `fresh64` (→
  `rt_mem.fresh64`); the nif fail-closed gate mirrors atomics (an over-cap 64-bit memory is rejected
  at link time — the deferred native impl reserves; the skeleton delegates to sparse paged for a tiny
  bounded one). Coercion soundness holds unchanged (the `mem` slot is produced solely by this
  module's `fresh`/`fresh64`).
- `src/twocore/runtime/instance.gleam` — **the `mem64_max_pages` `Binding` field is added + frozen by
  P6-01** (keystone). **This unit does not own `instance.gleam`; it PICKS the value** (§C) and states
  the `safe_default` it requires. Flagged as a cross-unit seam.
- `test/twocore/runtime/rt_mem_test.gleam`, `test/twocore/runtime/rt_mem_atomics_test.gleam` —
  **EXTEND.** The small-memory differential + the large-address spec-corner + the cap-boundary +
  the byte-identity + the fail-closed-gate suites for 64-bit memories.

## Deliverables & freeze milestones

Under `«MEM64-RUNTIME»` the keystone (P6-01) publishes: the `Binding.mem64_max_pages` field (this
unit picks its value, §C) and the "`lower`/`link` accept `Idx64`" contract (this unit hands `lower`
(05) / `emit_core` (06) the runtime seam). The additive runtime surface this unit owns (final names
pinned here; 01 references them):

```gleam
// ── the documented 64-bit implementation cap (§C) ──
/// The hard architectural page cap for a 64-bit (Idx64) memory: 2^32 pages = 2^48 bytes = 256 TiB.
/// Cited (§C) against the spec's grow-may-fail licence + the 48-bit hardware VA ceiling; strictly
/// below the spec's 2^48-PAGE type-level max (validate's `memory64_page_limit`). The i32 analogue
/// of the frozen `hard_max_pages` (65_536). A memory's baked `max` never exceeds this.
pub const mem64_hard_max_pages: Int = 4_294_967_296

// ── idx-width-aware constructors (paged) — additive ──
/// Build a FRESH opaque 64-bit (Idx64) paged memory. `mem64_cap` is the deployment cap
/// (Binding.mem64_max_pages); the baked effective max is min(declared ?? cap, cap,
/// mem64_hard_max_pages). Total. Returns the opaque `Dynamic` for `rt_state.seed`/`seed_full`.
pub fn fresh64(min_pages: Int, max_pages: Option(Int), mem64_cap: Int) -> Dynamic
/// The pure ctor `fresh64` wraps (default chunk); the differential drives it across chunk sizes.
pub fn fresh_mem64(min_pages: Int, max_pages: Option(Int), mem64_cap: Int, chunk: Int) -> Mem
/// Oracle ctor for a 64-bit memory (SMALL sizes only — the flat binary is O(byte_len), §E).
pub fn o_fresh64(min_pages: Int, max_pages: Option(Int), mem64_cap: Int) -> OMem

// ── the generalised cap fold (i32 `effective_max` delegates → byte-identical) ──
fn effective_max_for(max_pages: Option(Int), safe_cap: Int, hard_cap: Int) -> Int
// changed body (behaviour-preserving for Idx32): `mem_grow`/`o_grow` drop the redundant
//   `&& new <= hard_max_pages` conjunct in favour of `new <= m.max` (m.max already folds the
//   per-width cap; for Idx32 m.max <= 65_536 so the dropped conjunct was always implied — §A.3).

// ── atomics: the idx-aware fail-closed gate (§D) — additive ──
/// The reserve (pages) a 64-bit atomics binding needs; `Error(Nil)` when it exceeds `reserve_cap`
/// (the caller MUST reject — never degrade). A tiny bounded 64-bit memory (reserve <= cap) → Ok.
pub fn reservation64(min_pages, max_pages, mem64_cap, reserve_cap) -> Result(Int, Nil)
/// Build a tiny bounded 64-bit atomics memory (reserve <= reserve_cap); node-safe `panic` (unreachable
/// post-`validate_binding`) on an over-cap reservation — never a silent 256 TiB pre-alloc.
pub fn a_fresh64(min_pages, max_pages, mem64_cap, reserve_cap) -> Atomics

// ── nif: delegating fresh64 (→ rt_mem.fresh64), fail-closed gate mirrors atomics ──
pub fn fresh64(min_pages: Int, max_pages: Option(Int), mem64_cap: Int) -> Dynamic
```

The load/store/size/grow/`_at`/bulk/`t_*` heads from P5-08 are **unchanged** — memory64 reuses them
verbatim (they are already bignum-correct). **This unit is done** when: a 64-bit memory
loads/stores/fills/copies/inits at addresses `> 2³²` with `i64`/bignum arithmetic (spec-exact); the
small-memory differential (`paged ≡ atomics ≡ oracle`) is green over 64-bit op streams; `grow` returns
`-1` exactly at the page cap and an access past current size traps `MemoryOutOfBounds`; a 32-bit
memory is byte-identical; `atomics`/`nif` fail closed for an over-cap 64-bit memory;
`memory64.wast`/`address64.wast` run green under `paged` (+ `portable`) with `fail == 0` (the
categorised skip DROPS); `gleam format --check` is clean and `gleam build` has **zero warnings**; every
public fn/type carries a `///` contract doc. "Done" = *the suite passes*, not "it compiles".

## Depends on (freeze milestones)

- **`«MEM64-RUNTIME»`** (P6-01) — the `Binding.mem64_max_pages` field (I pick the value, §C; 01
  freezes the field + `safe_default` sets it) and the "`lower`/`link` accept `Idx64`" contract head.
- **`IdxType { Idx32 Idx64 }` / `MemoryDecl` / `ImportMemory` / `TrapReason`** — frozen in the IR/AST
  from Phase 5; I **consume, do not own**. **No new `TrapReason`** — a 64-bit bounds trap is the
  existing `MemoryOutOfBounds` (spec message *"out of bounds memory access"*), identical to i32.
- **Unit 05 (`lower`)** — deletes `reject_memory64`; threads each memory's `idx_type` so **06** knows
  which width to seed/box. **Unit 06 (`emit_core`)** — seeds an `Idx64` memory via `rt_mem:fresh64`
  (§A.2) and boxes `size`/`grow`/`-1` at i64 width (§B.3). **Unit 04 (`validate`)** — already types
  i64 addresses (P5, confirm); owns `memory64_page_limit` (the type-level max, §C). **Unit 09
  (`link`/`validate_binding`)** — the idx-aware fail-closed tier gate calls my `reservation64` (§D).
  I hand each of these the seam in §A/§C/§D; I do not own their files.
- **Unit 07 (`rt_table`)** — the structural parallel would be table64, but **there is no table64 in
  scope** (the memory64 proposal's 64-bit *tables* are a separate concern the conformance corpus does
  not require at the pin — flag to 10/11). No coordination needed beyond noting it.

---

## A. The memory64 axis — the cap seam, the constructor seam, the byte-identity discipline

### A.1 Why the byte machinery needs no change (the bignum invariant)

Every address computation in `rt_mem` is a BEAM **bignum** and is **never reduced mod 2³²**:

- `ea = addr + offset` (`mem_load`/`mem_store`), where `offset` is decoded as a **u64** (P5-03) and
  `addr` arrives as a resolved unsigned integer (i32 for a 32-bit memory, **i64 for a 64-bit one** —
  validate 04 types the operand; the runtime is agnostic).
- `byte_len(m) = m.pages * page_bytes` — a bignum; for a 64-bit memory `pages` may exceed 2¹⁶ so
  `byte_len` may exceed 2³².
- `in_bounds(m, ea, n) = ea >= 0 && ea + n <= byte_len(m)` — a bignum comparison; a 64-bit address
  `> 2³²` and an offset `> 2³²` are compared exactly. `addr = 0xFFFF_FFFF_FFFF_FFFF` + a large offset
  produces a huge `ea` that **fails** here (it does not wrap to in-bounds) — the no-wrap security
  property (E3), now exercised across the full 64-bit range.
- `read_bytes`/`write_bytes` chunk-address arithmetic (`ea / chunk`, `ea % chunk`) — bignum division;
  the sparse `Dict(chunk_idx -> binary)` keys on a bignum chunk index, so a store at byte `2³² + k`
  materialises exactly **one** chunk (O(1)), and an unwritten in-bounds region past 2³² reads as
  zero **without allocation**.
- **Every P5-08 bulk op** (`mem_fill`/`mem_copy`/`mem_init` + `a_*`/`o_*`) already sums bounds as
  bignums (`dest + count`, `src + count`, `dst + count`) and traps before any write — unchanged for a
  64-bit memory.

So the paged/atomics/oracle **bodies are reused verbatim** for the byte moves. memory64 touches only
the **cap fold** and adds the **64-bit constructors**.

### A.2 The constructor seam (what `emit_core` emits)

Today `emit_core` (06) seeds a memory into `rt_state` via `rt_mem:fresh(Min, Max, SafeCap)` where
`SafeCap = binding.safe_max_pages` (the i32 Safe cap, default 65_536). For a 64-bit memory `emit_core`
instead emits `rt_mem:fresh64(Min, Max, Mem64Cap)` where `Mem64Cap = binding.mem64_max_pages` (§C).
The choice is **static** — `emit_core` reads each `MemoryDecl.idx_type` (lowered from the AST, once 05
stops rejecting `Idx64`) and picks the builder per memory. The seeded `mem` value is **opaque** and
serves BOTH state strategies (cell and threaded store the same handle), so **one** `fresh64` builder
suffices — no `t_fresh64` twin (identical to `fresh`, which has no threaded twin either).

**Byte-identity (H7/I7).** A 32-bit memory still emits `rt_mem:fresh(Min, Max, SafeCap)` verbatim, so
a Phase-1..5 module's `instantiate` `.core` is **unchanged**. `fresh64` is only ever emitted for a
module that *declares or imports* an `Idx64` memory — a module that could not compile at all before
this unit.

**Imported 64-bit memory.** `ImportMemory(_, _, min, max, Idx64)` is provided state (H4): the
**linker** (09) supplies the memory value through the `Provided`/`FullDecl` seam. A `ProvidedMemory`
carrying an `Idx64` memory whose limits mismatch the import declaration is a **fail-closed link-time
failure** (`assert_unlinkable`) — unchanged from P5's `link_imports` matching, now with `idx_type` in
the compatibility check (already typed by validate; 09 owns the match). The runtime is agnostic: it
receives an opaque handle built by `fresh64` (or the exporting instance's).

### A.3 The cap fold — the one place width enters the pure core

The per-width cap folds into the existing `Mem.max` field at `fresh` time; **`Mem` gains no field**
(a deliberate refinement of P5-08 §C, which floated an `idx: IdxType`/`hard` field — see Deviations).
Because `max` already encodes the correct per-width ceiling, **`in_bounds`, `mem_grow`, and every bulk
op read only `max`** and stay width-agnostic. Concretely:

```gleam
/// The effective max in pages baked at `fresh` time, parameterised by the per-width HARD cap:
/// min(declared ?? min(safe_cap, hard_cap), min(safe_cap, hard_cap)). Never lets untrusted code
/// allocate past `safe_cap` (E3) or the architectural `hard_cap`.
fn effective_max_for(max_pages: Option(Int), safe_cap: Int, hard_cap: Int) -> Int {
  let cap = int.min(safe_cap, hard_cap)
  case max_pages { Some(declared) -> int.min(declared, cap)  None -> cap }
}
// i32 — byte-identical to the frozen body (same computation, hard_cap = hard_max_pages = 65_536):
fn effective_max(max_pages: Option(Int), safe_cap: Int) -> Int {
  effective_max_for(max_pages, safe_cap, hard_max_pages)
}
// i64:
//   fresh_mem64 folds effective_max_for(max_pages, mem64_cap, mem64_hard_max_pages).
```

`mem_grow` today checks `delta >= 0 && new <= m.max && new <= hard_max_pages`. The third conjunct is
**redundant for i32** (`effective_max` guarantees `m.max <= hard_max_pages = 65_536`, so
`new <= m.max` already implies `new <= 65_536`) and **wrong for i64** (it would clamp a 64-bit memory
to 65_536 pages). P5-08 §C.3 already anticipated dropping it; this unit does so:

```gleam
pub fn mem_grow(m: Mem, delta: Int) -> #(Int, Mem) {
  let old = m.pages
  let new = old + delta
  case delta >= 0 && new <= m.max {          // was: && new <= hard_max_pages
    True -> #(old, Mem(..m, pages: new))
    False -> #(-1, m)
  }
}
```

**Behaviour-preserving for `Idx32`** — a mechanically-checkable claim, asserted in Verification #4:
for every `Idx32` `Mem`, `m.max <= 65_536`, so `new <= m.max ⟺ (new <= m.max && new <= 65_536)`. The
same one-conjunct drop applies to `o_grow`. `a_grow` (atomics) needs **no** change: atomics only ever
hosts a 32-bit memory or a *tiny bounded* 64-bit memory whose `a.max <= reserve_cap (4096) < 65_536`,
so its `new <= a.max` binds first and the retained `hard_max_pages` conjunct is inert (§D). (Keeping
`a_grow` untouched preserves the frozen tier-O body exactly.)

### A.4 memory.size / memory.grow width is a value-layer concern (§B.3 forward-ref)

`mem_size`/`grow`/`size_at`/`grow_at` (+ `t_*`) return a plain bignum `Int` and are **width-agnostic**
— they need no change. The *type* of the returned value (i32 vs i64) and the *boxing* of the `grow`
failure sentinel `-1` are `emit_core`'s (06) concern (§B.3). This unit hands 06 the invariant: the
runtime returns the true page count (a non-negative bignum, up to `mem64_hard_max_pages` for a 64-bit
memory) or `-1`; 06 boxes it at the memory's address width.

---

## B. memory64 runtime semantics — spec-exact

> Spec anchors (transcribe, do not re-derive) — the memory64 proposal is merged into the core spec
> (WASM 3.0):
> types/validation: <https://webassembly.github.io/spec/core/valid/types.html> (memory limits valid
> within `2^(|addrtype|-16)` — i32 ⇒ 2¹⁶ pages, **i64 ⇒ 2⁴⁸ pages**);
> execution: <https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions>
> (`ea = i + memarg.offset`; trap iff `ea + N/8 > |mem.data|`; `memory.grow` never traps — it
> succeeds returning the old size or fails returning `-1`);
> the address type of a memory determines its operand types (`i32.load` vs the i64-addressed forms);
> conformance: `memory64.wast`, `address64.wast`.

### B.1 Addressing — the semantics table (unchanged machinery, extended range)

| op | operand width (64-bit memory) | trap condition (bignum, no wrap) | effect on success |
|---|---|---|---|
| `iN.load`/`iN.store` | `addr : i64` | `ea + bytes > byte_len` | LE codec over `[ea, ea+bytes)` |
| `memory.size` | — | (never traps) | pushes `pages` as **i64** |
| `memory.grow` | `delta : i64` | (never traps) | pushes old `pages` as **i64**, or `-1` (i64) |
| `memory.fill` | `d,val,n : i64`(d,n) | `d + n > byte_len` | `mem[d..d+n) := val & 0xFF` |
| `memory.copy` | `d,s,n : i64` | `s + n > byte_len(src)` **or** `d + n > byte_len(dst)` | memmove |
| `memory.init` | `d,s,n` (`d : i64`) | `s + n > len(data)` **or** `d + n > byte_len(mem)` | splice |

`memory.copy` between a 32-bit and a 64-bit memory (cross-width copy — legal per multi-memory ×
memory64) uses **each memory's own** `byte_len` for its side of the bounds check (the pure
`mem_copy(dst_m, src_m, …)` already does exactly this — the wrapper projects each handle
independently). The `count` bound `s + n <= byte_len(src)` / `d + n <= byte_len(dst)` is the src/dst
memory's own length; no cross-width special case is needed (bignums throughout).

### B.2 Large-address behaviour (the interesting part — > 2³²)

For a 64-bit memory grown past 2¹⁶ pages, addresses and offsets exceed 2³². The sparse paged backend
handles this without allocating the address space:

- **Grow is O(1)/sparse.** `mem_grow(fresh64(1, None, cap), 2^16 + 1)` yields a `Mem` with `pages =
  2^16 + 2`, `byte_len ≈ 4 GiB + 128 KiB`, and an **empty** chunk `Dict` — no allocation (the
  watermark move only). A store at byte `2³² + k` materialises exactly one `chunk`-byte chunk.
- **i64 offset.** `store(addr = 0, offset = 2³² + 40, …)` and `store(addr = 2³² + 40, offset = 0, …)`
  address the **same** byte (`ea = addr + offset`, bignum) — the offset is not truncated to 32 bits.
- **No-wrap trap at the 64-bit boundary.** A load of 8 bytes at `ea = byte_len − 8` succeeds; at
  `ea = byte_len − 7` it traps (`ea + 8 > byte_len`); an `addr` near 2⁶⁴ plus a large offset produces
  an `ea` far past `byte_len` that traps (never wraps to a small in-bounds value).
- **f32/f64 raw bytes (D5)** and **little-endian** hold identically at any address.

### B.3 `memory.size` / `memory.grow` return i64 (the value-layer seam)

The runtime returns a bignum `Int`; **`emit_core` (06) owns the width boxing**:

- **`memory.size`** on a 64-bit memory: runtime `mem_size` returns `pages` (up to
  `mem64_hard_max_pages = 2³²`, which does not fit i32); 06 boxes it as **i64**. On a 32-bit memory it
  is boxed i32 (byte-identical to Phase-5).
- **`memory.grow`** on a 64-bit memory: `delta : i64` arrives as a bignum; the runtime returns the old
  `pages` (non-negative) or `-1`. 06 boxes success as an **i64** page count and the failure sentinel
  `-1` as the **i64 all-ones bit pattern** (`0xFFFF_FFFF_FFFF_FFFF`) — the spec's `i64 -1`. On a 32-bit
  memory `-1` boxes as i32 `0xFFFF_FFFF` (byte-identical). **This is the one place the runtime's plain
  `Int` return must be interpreted at width** — flagged as the 06 seam (Cross-unit seams).

The runtime's `grow` **fuel charge is unchanged** (`delta * page_bytes`, §F): it is proportional to
the bytes *made addressable*, so under Safe a 64-bit `grow` is bounded by the fuel budget (an honest
interaction — a Safe deployment tunes `mem64_max_pages` and `fuel_budget` together, §F).

---

## C. The page cap — the honesty point (a documented, spec-cited constant, NOT a guess)

This is the load-bearing decision the scoping unit must pin (I4, R12's deferred warning: *"a real
constant with a spec citation, never a guess"*). There are **two distinct numbers**, cited separately;
conflating them is the error the reconciliation must prevent.

### C.1 The spec **type-level** max (owned by validate 04 — already in code, confirmed correct)

The WebAssembly spec (`valid/types`) validates a memory type's limits **within range `2^(|addrtype|
− 16)`** — the range in **pages**. For `i32` that is `2^(32−16) = 2¹⁶ = 65_536` pages (4 GiB); for
`i64` it is `2^(64−16) = **2⁴⁸ pages**` (= 2⁴⁸ × 2¹⁶ = **2⁶⁴ bytes**, 16 EiB of address space). This
is the largest limit a `(memory i64 min max)` may **declare**; a module declaring more fails
`assert_invalid`. It is **already encoded and correct** in `validate.gleam`:

```gleam
pub const memory64_page_limit: Int = 281_474_976_710_656   // = 2^48 PAGES (validate 04)
```

> **⚠ Correction flagged for reconciliation.** The scoping brief stated *"the WASM memory64 spec max
> is 2⁴⁸ bytes = 2³² pages."* That is **mislabelled** — the spec's i64 limit range is **2⁴⁸ *pages*
> (2⁶⁴ bytes)**, verified against `valid/types` (the `2^(|addrtype|−16)` rule) and matching the
> in-repo `memory64_page_limit = 2⁴⁸`. The brief's "2⁴⁸ bytes = 2³² pages" is exactly the *runtime
> implementation cap* this unit pins below (C.2) — a value strictly **below** the spec type max, not
> the type max itself. Per the DoD ("the spec wins"), this doc cites the correct spec value and pins
> the implementation cap explicitly against it.

### C.2 The **runtime implementation** cap (this unit pins it — `Binding.mem64_max_pages`)

We do **not** allocate — nor claim to address — 2⁶⁴ bytes (I8). The paged backend is **sparse and
grows on demand** (O(1) grow, absent chunks read as zero), so the cap is a **trap boundary, not a
reservation**. But the boundary must be a **real, documented, node-safe** number where `grow` returns
`-1` and access traps. **Pin:**

```gleam
// rt_mem.gleam
pub const mem64_hard_max_pages: Int = 4_294_967_296   // 2^32 pages = 2^48 bytes = 256 TiB
// instance.gleam (Binding field, frozen by 01, value picked here):
mem64_max_pages: Int   // safe_default = 4_294_967_296  (= rt_mem.mem64_hard_max_pages)
```

**The value: 2³² pages = 2⁴⁸ bytes = 256 TiB.** Rationale, cited, honest, non-guessed:

1. **Spec licence to cap below the type max.** The spec (`exec/instructions`, `memory.grow`) makes
   growth **non-deterministic**: it *"may either succeed, returning the old memory size, or fail,
   returning `−1`. Failure must occur if growing would exceed the memory's maximum size; however,
   failure can occur in other cases as well… the choice depends on the resources available to the
   embedder."* An engine may therefore return `-1` at **any documented implementation limit** below
   the 2⁴⁸-page type range. This is the spec hook that makes a sub-type-max runtime cap *conformant*.
2. **A real hardware ceiling.** 2⁴⁸ bytes (256 TiB) is the canonical **48-bit virtual-address span**
   of current x86-64 / AArch64 hardware — no real host maps beyond it (Linux user-space VA on x86-64
   is 2⁴⁷ = 128 TiB, so the host **runs out of memory long before** even this ceiling). This mirrors
   Wasmtime's own documented posture: 64-bit memories *"can theoretically grow up to 2⁶⁴ bytes,
   although most hosts will run out of memory long before that"* — Wasmtime imposes **no fixed
   sub-2⁶⁴ page cap** (its `memory_reservation` default of 4 GiB is a virtual-address **reservation
   hint**, not a max) and relies on host OOM. Our sparse-paged backend has the **same** posture; we
   name the honest ceiling explicitly rather than leave it implicit.
3. **Not a 2⁶⁴ (or 256 TiB) allocation.** Because paged is sparse and `grow` is O(1), a 64-bit memory
   with `pages = 2³²` costs **nothing** until written; a store materialises one chunk; fuel bounds
   actual materialisation under Safe (§F). The cap is a *logical* trap boundary.
4. **Conformance-neutral.** `memory64.wast`/`address64.wast` exercise **tiny** memories (a few pages)
   and test *addressing/trap semantics*, not multi-terabyte allocation — so the exact cap value does
   **not** affect their greenness. The cap only governs the `grow → -1` boundary (untestable at 2³²
   directly; tested at small scale via an injected small cap, §E/Verification #3).
5. **Tunable, invariant-bounded.** It is a **`Binding` field**, so a stricter Safe deployment can
   lower it (e.g. to Wasmtime's 4 GiB `memory_reservation` = 2¹⁶ pages, or a few GiB) via a named
   profile. The **hard invariant** (asserted in Verification #3): `0 < mem64_max_pages <=
   memory64_page_limit` (runtime cap ≤ spec type max) and `mem64_max_pages >= 65_537` (so a 64-bit
   memory can exceed the i32 range — otherwise it would be indistinguishable from i32).

**Grow/access at the cap:** `grow` whose result would exceed the baked `max` (= `min(declared ?? cap,
cap, mem64_hard_max_pages)`) returns `-1`, allocating nothing and charging no fuel (§A.3, §F); an
access at `ea + N > byte_len` traps `MemoryOutOfBounds` — exactly where `memory64.wast`'s `assert_trap`
expects, since the byte machinery is bignum-exact (§A.1).

---

## D. `atomics` / `nif` — fail closed for an over-cap 64-bit memory (no silent fallback)

`atomics` reserves a **fixed** array of 64-bit words at `fresh` time (§C of the Phase-4 template): it
pre-allocates `reserve = max(min_pages, effective_max)` pages of words and grows by a pure watermark
move. A 64-bit memory's effective max is **vastly** larger than the node-safe
`atomics_reserve_cap_pages` (default 4096 pages = 256 MiB of eager reservation), so eager reservation
is impossible. Per I4 the rule is **fail closed — no silent 256 TiB pre-alloc, no silent `paged`
degrade**:

- **The gate (idx-aware).** For a 64-bit memory the linker (09 `validate_binding`) calls
  `rt_mem_atomics.reservation64(min, max, mem64_cap, reserve_cap)`, which folds the effective max via
  the **mem64** hard cap and returns `Error(Nil)` when `reserve > reserve_cap`. An **unbounded** or
  **large** 64-bit memory (`(memory i64 1)`, or any declared max > `reserve_cap`) is **fail-closed
  rejected at link time** — the exact posture P4/P5 use for an uncapped `atomics` binding. The tier
  matrix categorises the rejection honestly (`atomics + Idx64(over-cap) → paged/portable`), exactly as
  prior phases categorised their tier edges.
- **The admitted edge (correctness, not a loophole).** A **tiny bounded** 64-bit memory — `(memory
  i64 1 8)`, reserve = 8 ≤ 4096 — is **admitted** and runs **correctly** on atomics: its addresses are
  all `< 8 × 64 KiB`, well within word range, and the byte↔word gather/scatter is bignum-safe. The
  small-memory differential (§E) proves it byte-for-byte against paged/oracle. This is honest: a
  64-bit *type* does not imply a huge *size*, and a small one is genuinely representable in the
  tier-O reserve model.
- **`nif`.** The skeleton delegates to `rt_mem` (paged), so it *could* physically run a large 64-bit
  memory sparsely — but the **native tier's classification** is that of its **deferred C impl**, which
  reserves. To keep the tier honest, an over-cap 64-bit memory on `nif` is **fail-closed rejected at
  link time** on the same rule as atomics (the eventual native impl cannot back it); a tiny bounded
  one delegates to paged via `rt_mem_nif.fresh64 → rt_mem.fresh64`. `nif` is Unsafe-only regardless
  (Safe + Nif is already rejected, G6/R-P5).

**So memory64 ships on `paged` (+ `portable`/threaded).** `atomics`/`nif` host only tiny bounded
64-bit memories; everything larger is a categorised fail-closed rejection. This is precisely I4's
statement (*"memory64 therefore ships on paged (+ portable); the tier matrix categorises an over-cap
64-bit atomics binding honestly"*).

---

## E. The oracle & differential — proof strategy (small-memory diff + large-address spec-corner)

The flat-binary `rebuild` oracle (`OMem`, one contiguous binary) is the trivially-correct reference —
but it is **O(byte_len)**, so it **cannot be materialised for a large 64-bit memory** (a 4 GiB+ flat
binary would OOM the test node). The proof therefore splits, exactly as P5-08 §C anticipated:

### E.1 Small-memory differential (`paged ≡ atomics ≡ oracle`) — bounded 64-bit memories

Extend the oracle ctor (`o_fresh64`, §Deliverables) and drive the **existing** P5-08 differential
harness over a **bounded** 64-bit memory (a handful of pages, ≤ a few MiB flat) — a randomised op
stream of `load`/`store`/`grow`/`init_data` **plus** `fill`/`copy` (overlapping both directions +
cross-memory, including **cross-width** 32↔64 copy) / `init` (full and dropped/ε segments), across
several chunk sizes and on a memory small enough that `AtomicsBacked` engages (reserve ≤
`atomics_reserve_cap_pages`). After each op assert **identical value, identical trap
(`Ok`/`Error(reason)`), identical flat byte image** (`to_flat(paged) == o_flat(oracle) ==
a_flat(atomics)`). This proves: the i64 cap fold agrees across tiers; the bulk ops are 64-bit-correct;
a **tiny 64-bit memory runs correctly on atomics** (the §D admitted edge).

### E.2 Large-address spec-corner (paged, sparse, **no** flat oracle) — the > 2³² behaviour

The whole point of memory64 is addresses > 2³², which the flat oracle cannot reach. Prove it with
**direct spec-cited assertions** on the sparse paged core (transcribed from `address64.wast` /
`memory64.wast`; `to_flat`/`o_flat` are **not** called on these — flagged node-safe):

- **Round-trip past 2³².** Grow `(memory i64 1)` to `pages = 2^16 + 2` (sparse, O(1)); `store` i64
  `0x0123_4567_89AB_CDEF` at byte `2³² + 40`; `load64`/`load32_u`/`load16_u`/`load8_u` back at that
  address → the exact little-endian bytes (D5); overwrite one byte, reload → the byte changed, its
  neighbours did not. Only two chunks were ever materialised (assert bounded process memory).
- **i64 offset equivalence.** `store(addr=0, offset=2³²+40, v)` and `store(addr=2³²+40, offset=0, v)`
  address the same byte; `load` confirms.
- **No-wrap trap at the 64-bit boundary.** 8-byte access at `byte_len − 8` → `Ok`; at `byte_len − 7`
  → `Error(MemoryOutOfBounds)`; at `byte_len` → trap; `addr = 0xFFFF_FFFF_FFFF_FFF8` + `offset = 16`
  (an `ea` near 2⁶⁴) → trap (never wraps). Re-reading the in-bounds prefix after a trapping op shows
  it **unchanged** (all-or-nothing).
- **Bulk ops past 2³².** `fill`/`copy`/`init` (small `count`) at `dest`/`src`/`dst` near 2³² work and
  are memmove-correct; eager bounds at the > 4 GiB boundary trap with **zero mutation**; a `copy`
  whose `d + n` overflows a 32-bit register but not the bignum `byte_len` does **not** wrap.

### E.3 Page-cap boundary — at small scale via an injected cap

The real cap (2³² pages) is untestable directly (you cannot grow there). Test the **mechanism**
deterministically by constructing a memory with a **small injected cap** through the pure ctor
(`fresh_mem64(min, None, mem64_cap = 4, chunk)` → `max` folds to 4):

- `grow(3)` from `pages = 1` → `Ok(old = 1)` (→ 4); a further `grow(1)` from 4 → **`-1`** (would
  exceed the cap), allocating nothing, charging no fuel. Proves `grow → -1` exactly at the cap.
- With the **real** default cap: assert `mem64_hard_max_pages == 4_294_967_296` and `== pow2(32)`; the
  cross-unit invariant `mem64_hard_max_pages <= validate.memory64_page_limit` (2³² ≤ 2⁴⁸) and
  `mem64_hard_max_pages > 65_536` (a 64-bit memory can exceed the i32 range); and
  `Binding.mem64_max_pages == mem64_hard_max_pages` in `safe_default` (the single-source seam).

### E.4 Fail-closed gate

`reservation64(min=1, max=None, mem64_cap=…, reserve_cap=4096)` for an unbounded 64-bit memory →
`Error(Nil)` (reject); `reservation64(min=1, max=Some(8), …)` → `Ok(8)` (a tiny bounded one engages
atomics). `a_fresh64` reached with an over-cap reservation `panic`s node-safe (unreachable
post-`validate_binding`), never pre-allocating.

---

## F. Fuel / resource bound (unchanged mechanism, extended reach)

The P5/P4 fuel charges apply **unchanged** to a 64-bit memory (R9/§F of P5-08):

- **`grow` charges `delta * page_bytes`** (bytes made addressable). Under Safe this **bounds how large
  a 64-bit memory can be made addressable** — a `grow(2³²)` would charge `2⁴⁸` fuel and raise
  `FuelExhausted` long before the watermark moves. This is the intended Safe resource bound (E3/I4):
  an untrusted portable module cannot make 256 TiB addressable for free. Under Unsafe (no metering)
  the grow is O(1) and succeeds up to the cap. A Safe deployment therefore tunes `mem64_max_pages` and
  `fuel_budget` **together** (documented interaction).
- **`fill`/`copy`/`init` charge `count`** (bytes touched). Under Safe this bounds *actual*
  materialisation of a large 64-bit memory (a `fill` of a huge range hits the fuel wall before
  allocating), so the sparse-cap design opens **no new node-OOM hole** beyond what i32 already had,
  scaled by the same mechanism. A trapping bulk op charges nothing.

The pure `mem_*`/`a_*`/`o_*` cores stay **charge-free** (testable); the wrappers charge identically on
cell and threaded (metered-parity, G7). **Constant-space** holds: a store loop over a large-address
64-bit memory keeps bounded process memory (superseded `Mem` is garbage; only touched chunks live).

---

## Effect / soundness / security note

- **Fail-closed bounds — the security property (I6/H6), now across the full 64-bit range.** Every
  access and every bulk op checks its whole range as **bignum** sums, **never masked** mod 2³²/2⁶⁴,
  and traps `MemoryOutOfBounds` **before** any byte is written → **zero mutation on trap**. A 64-bit
  bounds bug's worst case is a wrong/missing trap or a node-safe process crash — **never a host
  out-of-bounds read** (tier P/O: a BEAM binary / `atomics` array is memory-safe by construction; the
  tier-N native impl stays deferred behind the byte-identical skeleton). The **no-wrap `ea`** is what
  makes memory64 safe: an attacker-chosen `addr`/`offset` near 2⁶⁴ produces a huge bignum `ea` that
  fails the bounds check, it does not wrap to a small in-bounds address.
- **The page cap is a hard trap boundary, not a reservation.** `grow` past the baked `max` returns
  `-1` (allocating nothing); fuel bounds actual materialisation under Safe (§F). We do **not** reserve
  256 TiB or 2⁶⁴ bytes (I8).
- **`atomics`/`nif` fail closed for an over-cap 64-bit memory (§D)** — a fail-closed **link-time**
  rejection, never a silent 256 TiB pre-alloc or a silent `paged` degrade. Safe forbids tier-N as
  before (G6).
- **Conformance-neutral by default (H7/I7).** A single 32-bit memory compiles and runs
  **byte-identically** to Phase-5 under both modes and every shipped `(state_strategy × mem_tier)`:
  the frozen load/store/size/grow/`_at`/bulk/`t_*` bodies are untouched; the `effective_max`
  generalisation and `mem_grow` cap simplification are proven behaviour-preserving for `Idx32`
  (Verification #4); `fresh64` is emitted **only** for a module that declares/imports an `Idx64`
  memory (one that could not compile at all before). Floats-as-bits (D5) and the no-wrap `ea` are
  untouched. No new `TrapReason`.
- **No ambient authority (D3a).** memory64 adds no new capability and no `apply` of an attacker-chosen
  target; it reuses the existing bounds-checked `rt_mem` seam. The `Binding.mem64_max_pages` cap is a
  build-controlled constant, never program-supplied.

---

## Deviations from the provisional surface (ARGUED — for critique + reconciliation)

1. **`Mem`/`OMem`/`Atomics` gain NO `idx: IdxType` field** (provisional surface §F / P5-08 §C floated
   *"the `Mem`/`OMem`/`Atomics` records gain an `idx: IdxType` (or an already-folded `hard`) field"*).
   **Argument:** the per-width cap folds fully into the existing `max` field at `fresh` time, and
   `in_bounds`/`mem_grow`/every bulk op read only `max`. No other runtime behaviour depends on the
   address width (size/grow return a bignum; boxing is 06's concern, §B.3). Adding a field would touch
   every `Mem(...)` constructor and pattern for **zero** behavioural gain and would perturb the
   Phase-2..5 byte-identity proof surface. Folding-into-`max` is strictly smaller and keeps `Mem`
   field-identical for i32. *(If reconciliation prefers an explicit `idx` field for
   printer/debug legibility, it can be added opaquely — but it is not needed for correctness.)*

2. **`fresh64(min, max, mem64_cap)` + `fresh_mem64(…, chunk)` (dedicated ctors), not the P5-08 sketch
   `fresh_mem_idx(min, max, safe_cap, chunk, idx: IdxType)`.** **Argument:** an idx-parameterised
   general ctor implies a stored `idx` field (Deviation 1) and forces every caller to pass an
   `IdxType`; dedicated `fresh64`/`fresh_mem64` mirror the existing `fresh`/`fresh_mem` pair exactly,
   keep the i32 path byte-identical (its call sites are unchanged), and localise the width choice to
   `emit_core`'s builder selection (§A.2). The provisional surface's frozen head list (F) named
   `fresh64(min_pages, max_pages, safe_cap)`; I add the explicit **`mem64_cap`** argument (the
   deployment cap from `Binding.mem64_max_pages`) rather than overloading `safe_cap` — because the i32
   `safe_max_pages` (65_536) is the *wrong* cap for a 64-bit memory (it would clamp it to 4 GiB). This
   is a genuine correction to the provisional signature, flagged for 01/06 to align the seam.

3. **The page cap is pinned at 2³² pages (2⁴⁸ bytes), and the spec type max is corrected to 2⁴⁸
   *pages* (2⁶⁴ bytes).** **Argument:** the scoping brief's *"spec max is 2⁴⁸ bytes = 2³² pages"* is
   mislabelled (§C.1) — verified against `valid/types` and the in-repo `memory64_page_limit = 2⁴⁸
   pages`. The brief's "2⁴⁸ bytes = 2³² pages" is exactly the **runtime implementation cap** (a value
   *below* the spec type max), which is the honest thing to pin (§C.2). So this doc keeps the two
   numbers distinct and correctly cited: type max = 2⁴⁸ pages (validate 04); runtime cap = 2³² pages
   (this unit). The runtime cap value is a documented engineering choice (hardware VA ceiling +
   Wasmtime posture + spec grow-may-fail licence), tunable via the `Binding` field, invariant-bounded
   `≤` the type max — reconciliation may lower it, never raise it past `memory64_page_limit`.

4. **`atomics`/`nif` gain idx-aware `reservation64`/`a_fresh64`/`fresh64` rather than relying on the
   numeric coincidence that the existing i32 gate (`reserve > 65_536`) also rejects large 64-bit
   memories.** **Argument:** the existing `reservation` already rejects an unbounded 64-bit memory
   (because `65_536 > reserve_cap = 4096`), so the *outcome* coincides — but making the gate
   **explicitly idx-aware** (folding via the mem64 cap) is auditable and robust to a deployment that
   raises `reserve_cap` above 65_536. Additive; the i32 gate is untouched (byte-identical).

---

## Verification — Definition of Done (D8)

Tests assert **WebAssembly memory64 semantics** (and, at affordable scale, the oracle), never
"whatever the impl emits" — no change-detectors. Spec-cited (`valid/types`, `exec/instructions`,
`memory64.wast`/`address64.wast`).

1. **Small-memory differential `paged ≡ atomics ≡ oracle`** (§E.1) over randomised 64-bit op streams
   — `load`/`store`/`grow`/`init_data` + `fill`/`copy` (overlap both directions, cross-memory,
   **cross-width 32↔64**) / `init` (full **and** dropped/ε), across chunk sizes, on a memory small
   enough that `AtomicsBacked` engages. Assert identical value, trap, and flat byte image after every
   op. Proves the i64 fold + bulk ops + the tiny-64-bit-on-atomics edge.
2. **Large-address spec-corner** (§E.2, paged, sparse, **no** flat oracle): round-trip an i64 value at
   byte `2³² + 40` (load8/16/32/64_u exact, D5); i64-offset equivalence; no-wrap trap at
   `byte_len − 7` / `byte_len` / an `ea` near 2⁶⁴; bulk ops (small count) past 2³² memmove-correct with
   eager bounds → zero mutation. Assert bounded process memory (only touched chunks materialised).
3. **Page-cap boundary** (§E.3): with an **injected small cap** (`fresh_mem64(1, None, 4, chunk)`),
   `grow` returns the old size up to the cap and **`-1`** beyond it (allocating nothing, charging no
   fuel). With the **real** cap: `mem64_hard_max_pages == 4_294_967_296 == pow2(32)`; the invariants
   `mem64_hard_max_pages <= validate.memory64_page_limit`, `mem64_hard_max_pages > 65_536`, and
   `Binding.mem64_max_pages (safe_default) == mem64_hard_max_pages` (the single-source seam).
4. **32-bit byte-identity** (§A.3): for a range of `(max_pages, safe_cap)` inputs,
   `effective_max(max, safe) == effective_max_for(max, safe, hard_max_pages)`; for `Idx32` inputs
   spanning the 65_536 boundary, the new `mem_grow`/`o_grow` (dropped conjunct) return **exactly** the
   Phase-5 result (a reference computed with the old two-conjunct rule). Every existing i32
   `rt_mem`/`rt_mem_atomics` test still passes unchanged.
5. **Fail-closed gate** (§E.4): `reservation64` rejects an unbounded / over-cap 64-bit memory
   (`Error(Nil)`) and admits a tiny bounded one (`Ok(reserve)`); `a_fresh64` `panic`s node-safe on an
   over-cap reservation (never pre-allocates). `nif` mirrors it.
6. **Fuel / constant-space** (§F): a 64-bit `grow(delta)` charges `delta * page_bytes` (so a Safe
   budget bounds addressability); a large `fill`/`copy` on a 64-bit memory charges `count` and a trap
   charges nothing, identically across cell/threaded (metered-parity); a store loop over a
   large-address 64-bit memory holds bounded process memory.
7. **Spec-anchor `.wast`, reserved here.** Transcribe `memory64.wast` / `address64.wast` corners as
   `rt_mem`-level tests **now** (their semantics *are* this unit's contract); reserve those filenames
   in the allowlist so **unit 10/11** flip them to end-to-end pass under `paged` (+ `portable`) and
   both state strategies — the categorised `memory64 runtime → Phase 6` **skip DROPS** (`fail == 0`,
   `pass` rises, reported as **measured**, R16).
8. `gleam format --check src test` clean; `gleam build` **zero warnings** (every public fn total — no
   `todo`/`panic` on an untrusted path; the `a_fresh64` over-cap `panic` is unreachable
   post-validation and documented); `gleam test` green (≥ current count); conformance `fail == 0`
   under every shipped `(state_strategy × mem_tier)`; every public fn/type carries a `///` contract
   doc (what / params+ranges / `Result` semantics / failure modes).

**Done = the extended `rt_mem`/`rt_mem_atomics` suites pass** (the small-memory differential + the
large-address spec-corner + the cap boundary + the byte-identity + the fail-closed gate + the
fuel/constant-space tests), **not** "it compiles".

## What this unit leaves (downstream)

- **Unit 05 (`lower`)** deletes `reject_memory64` (stop returning `Memory64Unsupported`) and threads
  each memory's `idx_type` into the IR so 06 can select the builder + boxing width.
- **Unit 06 (`emit_core`)** seeds an `Idx64` memory via `rt_mem:fresh64(Min, Max, binding.
  mem64_max_pages)` (§A.2) and **boxes `memory.size`/`memory.grow`/the `-1` sentinel at i64 width**
  for a 64-bit memory (§B.3) — the one place the runtime's plain-`Int` return is interpreted at width.
  A 32-bit memory emits the frozen `fresh`/i32-boxed forms verbatim (byte-identical).
- **Unit 01 (keystone)** freezes `Binding.mem64_max_pages` and sets `safe_default` to this unit's
  pinned value (`= rt_mem.mem64_hard_max_pages`, the single-source seam).
- **Unit 09 (`link`/`validate_binding`)** makes the tier gate idx-aware — for an `Idx64` memory on
  `Atomics`/`Nif` it calls my `reservation64` and fail-closed rejects an over-cap one (§D), matching a
  64-bit `ProvidedMemory`/`ImportMemory` on `idx_type` (fail-closed `assert_unlinkable` on mismatch).
- **Unit 10/11 (conformance/capstone)** light up `memory64.wast`/`address64.wast` under `paged` (+
  `portable`), report the **measured** skip drop honestly (R16), and categorise the over-cap
  64-bit-on-atomics/nif tier edge.

## Cross-unit seams (pin single ownership in reconciliation)

- **`Binding.mem64_max_pages` value vs `rt_mem.mem64_hard_max_pages`.** 01 owns the *field*; **08
  picks the value** and requires `safe_default`'s field `== rt_mem.mem64_hard_max_pages` (single
  source). Asserted (Verification #3). Avoid two divergent literals.
- **The two page limits must not be conflated.** validate (04) owns `memory64_page_limit = 2⁴⁸ pages`
  (the *type-level* max, `assert_invalid`); rt_mem/Binding (08/01) own `mem64_max_pages = 2³² pages`
  (the *runtime* cap, `grow → -1`). Invariant `mem64_max_pages <= memory64_page_limit`. §C is the
  authoritative statement; reconciliation should ratify both numbers and the invariant.
- **The i64 width-boxing of `size`/`grow`/`-1`** is **06's** (emit_core), not the runtime's — the
  runtime returns a plain bignum `Int` (§B.3). Pin that 06, not 08, owns the width interpretation.
- **The idx-aware tier gate** (`reservation64`) is called by **09** (`validate_binding`); **08**
  provides the predicate. Pin single ownership so the fail-closed rule lives in one place.
- **No table64.** The memory64 proposal's 64-bit *tables* are **not in this unit** and not required by
  the corpus at the pin — flag to 07/10/11 so nothing assumes table64 exists.
- **No new `TrapReason`.** A 64-bit bounds trap is `MemoryOutOfBounds` (confirm with 01, per the
  provisional surface — the SIMD/mem64/xlink keystone expects **none**).
</invoke>
