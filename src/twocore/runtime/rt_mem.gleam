//// `rt_mem` — linear memory: the `paged` implementation + the flat-binary `rebuild`
//// oracle (owner: unit 04). SIGNATURES frozen by unit 01; BODIES implemented by unit 04.
////
//// **State location.** `load`/`store`/`size`/`grow`/`init_data` operate on the `mem` field
//// of THIS process's cell — read via `rt_state.mem_get`, write the new memory value back
//// via `rt_state.mem_put`. The memory value is OPAQUE to `rt_state` (held as `Dynamic`);
//// `rt_mem` owns its shape and coerces (via `gleam_stdlib:identity/1`, a tier-O no-op — the
//// cell is the sole producer/consumer of this term, so the coercion is sound). The handle
//// never leaves the cell.
////
//// **Representation (the immutable, sparse, paged `Mem`).** Memory is a record
//// `{pages, max, chunk, data}` where `data` is a SPARSE `Dict(chunk_idx -> chunk-binary)`.
//// `byte_len = pages * 65536`. The WASM **page** (65536 B) is the grow/size unit; the
//// physical **chunk** (`chunk` bytes, default 4096, kept `> 64` so chunks are off-heap REFC
//// binaries shared by reference across `Mem` versions) is the binary-granularity knob,
//// DECOUPLED from the page. An ABSENT chunk reads as all-zero and costs nothing, so a
//// freshly-grown / never-written in-bounds region reads as `0` with no allocation and `grow`
//// is O(1) in allocation. A store copies only the affected chunk(s); untouched chunks stay
//// structurally shared, and the superseded `Mem` is garbage.
////
//// **No-wrap effective address (E3).** `ea = addr (unsigned i32) + offset (static u32)` is
//// computed as a BIGNUM and never reduced mod 2³²; an access traps iff
//// `ea + access_bytes > current_byte_len`. A multi-byte store traps BEFORE writing any
//// byte (all-or-nothing — zero corruption). Little-endian byte order. f32/f64 loads/stores
//// are raw-byte moves over the IEEE bit pattern — never a BEAM-double round-trip.
////
//// **`grow` resource cap (E3).** A finite Safe max-pages cap is baked into the memory by
//// `fresh` (single-sourced) so `grow` enforces it without threading a profile through
//// generated code; `grow` returns `-1` past the cap/declared max and never allocates, and
//// charges fuel proportional to the bytes allocated (`rt_meter.charge(delta * 65536)`).
////
//// **`rebuild` oracle (E4).** A flat-binary reference implementation (`OMem`) is held to
//// explicit spec-corner tests and differentially tested against `paged`. Memory is a BEAM
//// immutable binary, so a bounds bug's worst case is a wrong/missing trap or a node-safe
//// crash — never a host out-of-bounds read. Tier P/O, never NIF.
////
//// **Phase-5 additive surface (bulk memory + multi-memory).** This unit (P5-08) adds — WITHOUT
//// touching the frozen Phase-2/4 heads — the finalized bulk-memory ops (`memory.fill`/`copy`/
//// `init`; the bulk-memory proposal / exec §4.4.9) and the multi-memory index routing. The new
//// capability is:
//// - **Pure paged core** `mem_fill`/`mem_copy`/`mem_init` — value-threaded, charge-free, the
////   testable algebra. Every bulk op checks its WHOLE range up front (strict `>` bounds, R10) and
////   mutates ZERO bytes on a trap (all-or-nothing). `mem_copy` is memmove (snapshot-then-write, so
////   overlap is correct in either direction and same-vs-cross-memory copy share one path, R11).
//// - **Index-routed cell/threaded wrappers** `fill`/`copy`/`init` + the `_at` load/store/size/
////   grow/init_data variants — they project memory `mem_idx` from the `rt_state` memories vector
////   (`mem_at(i)`/`with_mem_at(i,_)` cell; `t_mem_at(st,i)`/`t_with_mem_at(st,i,_)` threaded),
////   drive the pure core, and persist. The frozen non-indexed heads are the byte-identical
////   index-0 path (H7): a single-memory-index-0 module emits the SAME calls and runs identically.
//// - **Fuel (R9/§F):** each O(count) bulk-op WRAPPER charges `rt_meter.charge(count)` on the
////   SUCCESS path, identically on cell and threaded (so metered+threaded is byte-identical to
////   metered+cell); the pure cores stay charge-free. A trapping op charges nothing.
//// - **Data-segment payload (R2):** `mem_init`/`init` take the segment's CURRENT bytes as a
////   `BitArray` argument (ε when dropped) — `emit_core` (06) projects them and does the drop-check;
////   `rt_mem` stays a pure byte-mover and never reads `rt_state` drop-state.
//// - **memory64 (P6-08, S4/S9):** a 64-bit-indexed (`Idx64`) memory now RUNS. The byte machinery
////   is ALREADY bignum-64-bit-correct (`ea = addr + offset` and `in_bounds` are never masked mod
////   2³²; `byte_len = pages * 65536` is a bignum), so `fresh64`/`fresh_mem64`/`o_fresh64` differ
////   from the 32-bit ctors ONLY in the page cap folded into `max`:
////   `effective_max_for(max, mem64_cap, mem64_hard_max_pages)` with the documented runtime cap
////   `mem64_hard_max_pages = 2³² pages = 256 TiB` (S9 — a sparse trap boundary, never allocated).
////   `mem_grow`/`o_grow` drop the now-redundant `&& new <= hard_max_pages` conjunct (folded into
////   `max`; behaviour-preserving for `Idx32` since `m.max <= 65_536` there). The
////   `load_bytes`/`store_bytes`/`_at`/`t_*` family (the BitArray v128-memory seam, S4) is the
////   checked wrapper unit 06 composes with `rt_simd`'s lane assembly for `v128.load`/`store`/
////   `loadNxM`/`loadN_zero`. A 32-bit memory stays BYTE-IDENTICAL — the frozen heads are untouched.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/option.{type Option, None, Some}
import twocore/ir.{type TrapReason, MemoryOutOfBounds}
import twocore/runtime/rt_meter
import twocore/runtime/rt_state

// ───────────────────────────── constants ─────────────────────────────

/// The fixed WASM page size in bytes (`64 KiB`). `memory.size`/`memory.grow` count pages;
/// `byte_len = pages * page_bytes`.
pub const page_bytes: Int = 65_536

/// The absolute i32-memory address cap: a 32-bit-indexed memory cannot exceed `2^16` pages
/// (`4 GiB`). `grow` enforces this regardless of the declared/Safe max.
pub const hard_max_pages: Int = 65_536

/// The documented RUNTIME page cap for a 64-bit (`Idx64`) memory (memory64, S9/§C): `2^32` pages
/// = `2^48` bytes = **256 TiB**. The i64 analogue of `hard_max_pages` (the frozen 32-bit cap).
///
/// This is a **sparse trap boundary, NOT a reservation**: the paged backend grows on demand
/// (O(1) grow, absent chunks read as zero), so a 64-bit memory with `pages = 2^32` costs nothing
/// until written. `grow` beyond the baked `max` (which folds this cap) returns `-1`; an access
/// beyond the current size traps `MemoryOutOfBounds`. Cited (§C) against the spec's grow-may-fail
/// licence (`exec/instructions`, `memory.grow` "failure can occur … depending on the resources
/// available to the embedder") + the 48-bit hardware VA ceiling; strictly BELOW the spec's
/// `2^48`-PAGE type-level maximum (validate's `memory64_page_limit = 281_474_976_710_656`), which
/// governs what a `(memory i64 …)` may DECLARE. Invariant: `hard_max_pages (65_536) <
/// mem64_hard_max_pages <= validate.memory64_page_limit`. Tunable per deployment via
/// `Binding.mem64_max_pages` (single-sourced to this value in `safe_default`).
pub const mem64_hard_max_pages: Int = 4_294_967_296

/// The default physical chunk size in bytes used by the cell-backed `fresh`. Chosen `> 64`
/// so chunks are off-heap REFC binaries (structurally shared across `Mem` versions); `4096`
/// is the 4–8 KiB sweet spot. Correctness is chunk-size-independent (the oracle proves it),
/// so this is a pure tuning knob.
pub const default_chunk_bytes: Int = 4096

// ───────────────────────────── the immutable paged Mem ─────────────────────────────

/// Immutable, sparse, paged linear memory. Mutation builds a NEW `Mem`; the per-instance
/// cell holds the latest. Opaque: callers go through the pure core / cell-backed API.
///
/// - `pages`: current size in 64 KiB WASM pages (the `memory.size` source).
/// - `max`: the EFFECTIVE max in pages baked at `fresh` time — `min(declared_max, cap)` where the
///   per-width `cap` is `min(safe_cap, hard_max_pages)` for a 32-bit memory (`fresh`) or
///   `min(mem64_cap, mem64_hard_max_pages)` for a 64-bit one (`fresh64`). `grow` never exceeds it,
///   so `in_bounds`/`mem_grow`/every bulk op read ONLY `max` and stay width-agnostic (S9 §A.3).
/// - `chunk`: physical chunk size in bytes (`> 64`); decoupled from the 64 KiB page.
/// - `data`: SPARSE map `chunk_idx -> chunk-sized binary`; an ABSENT chunk is all-zero.
pub opaque type Mem {
  Mem(pages: Int, max: Int, chunk: Int, data: Dict(Int, BitArray))
}

/// Coerce a `Mem` into the opaque `Dynamic` the cell stores. Identity at run time
/// (`gleam_stdlib:identity/1`); tier-O, cannot fail.
@external(erlang, "gleam_stdlib", "identity")
fn mem_to_dynamic(mem: Mem) -> Dynamic

/// Coerce the cell's opaque `Dynamic` back into a `Mem`. Identity at run time; sound because
/// `rt_mem` is the sole producer of the term `rt_state` holds in the `mem` slot.
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_mem(value: Dynamic) -> Mem

// ───────────────────────────── public cell-backed API (frozen heads) ─────────────────────────────

/// Build a FRESH opaque memory of `min_pages` zero-filled 64 KiB pages.
///
/// - `min_pages`: the initial page count (the module's declared memory minimum).
/// - `max_pages`: the module's declared maximum in pages, or `None` for "unbounded"
///   (still subject to `safe_cap`).
/// - `safe_cap`: the finite Safe max-pages cap (single-sourced; see E3), baked into the
///   returned value so `grow` enforces it without a profile parameter.
/// - Returns the fresh memory value as `Dynamic` (opaque, ready to hand to
///   `rt_state.seed`). Total — never fails. The baked effective max is
///   `min(min_pages-declared-or-safe_cap, safe_cap, 65536)`.
pub fn fresh(min_pages: Int, max_pages: Option(Int), safe_cap: Int) -> Dynamic {
  mem_to_dynamic(fresh_mem(min_pages, max_pages, safe_cap, default_chunk_bytes))
}

/// Build a FRESH opaque 64-bit (`Idx64`, memory64) paged memory of `min_pages` zero-filled 64 KiB
/// pages — the constructor `emit_core` (06) emits for a module declaring/importing a 64-bit
/// memory (S4/S9 §A.2). The byte machinery is shared verbatim with `fresh`; only the page cap
/// differs.
///
/// - `min_pages`: the initial page count (a `u64`; may exceed `2^16`). The sparse map starts
///   empty, so a large `min` allocates nothing.
/// - `max_pages`: the module's declared maximum in pages (a `u64`), or `None` for "unbounded"
///   (still subject to `mem64_cap`).
/// - `mem64_cap`: the deployment 64-bit page cap (`Binding.mem64_max_pages`, default
///   `mem64_hard_max_pages`). The baked effective max is
///   `min(declared ?? cap, cap)` where `cap = min(mem64_cap, mem64_hard_max_pages)` (§C).
/// - Returns the fresh memory as `Dynamic` (opaque, ready for `rt_state.seed`/`seed_full`). Total
///   — never fails. `grow` past the baked max returns `-1`; an access past the current size traps
///   `MemoryOutOfBounds`.
pub fn fresh64(
  min_pages: Int,
  max_pages: Option(Int),
  mem64_cap: Int,
) -> Dynamic {
  mem_to_dynamic(fresh_mem64(
    min_pages,
    max_pages,
    mem64_cap,
    default_chunk_bytes,
  ))
}

/// Load `bytes` bytes (little-endian) from `addr + offset` in this process's memory,
/// producing a `result_width`-bit value.
///
/// - `bytes`: the access width in bytes (1/2/4/8).
/// - `signed`: whether a sub-word load is sign-extended to `result_width` (else zero-
///   extended). Irrelevant when `bytes * 8 == result_width`.
/// - `result_width`: the result's width in bits (32 or 64) — disambiguates e.g.
///   `i32.load8_s` from `i64.load8_s`.
/// - `addr`: the unsigned i32 base address.
/// - `offset`: the static unsigned offset (added as a bignum — no wrap).
/// - Returns `Ok(bits)` (the loaded value as a raw bit pattern), or
///   `Error(MemoryOutOfBounds)` if `ea + bytes > byte_len`. Reads the `Mem` from the cell.
pub fn load(
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  mem_load(current_mem(), bytes, signed, result_width, addr, offset)
}

/// Store the low `bytes` bytes (little-endian) of `value` to `addr + offset` in this
/// process's memory. All-or-nothing: traps BEFORE writing any byte if out of bounds.
///
/// - `bytes`: the store width in bytes (1/2/4/8). The value's sign is irrelevant.
/// - `addr`: the unsigned i32 base address.
/// - `value`: the value whose low `bytes` bytes are written (raw bit pattern).
/// - `offset`: the static unsigned offset (added as a bignum — no wrap).
/// - Returns `Ok(Nil)` on success (and writes the new `Mem` back to the cell), or
///   `Error(MemoryOutOfBounds)` with ZERO mutation.
pub fn store(
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(Nil, TrapReason) {
  case mem_store(current_mem(), bytes, addr, value, offset) {
    Ok(updated) -> {
      rt_state.mem_put(mem_to_dynamic(updated))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// UNCHECKED cell load (Phase-10, N5) — `load` MINUS the bounds check/`Result`. Reads the `Mem` from
/// the pdict cell. Returns the raw bit pattern directly. See `mem_load_unchecked` (BEAM-safe on OOB).
pub fn load_unchecked(
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Int {
  mem_load_unchecked(current_mem(), bytes, signed, result_width, addr, offset)
}

/// UNCHECKED cell store (Phase-10, N5) — `store` MINUS the bounds check/`Result`. Writes the new
/// `Mem` back to the pdict cell; returns `Nil`. See `mem_store_unchecked` (BEAM-safe on OOB).
pub fn store_unchecked(bytes: Int, addr: Int, value: Int, offset: Int) -> Nil {
  rt_state.mem_put(
    mem_to_dynamic(mem_store_unchecked(
      current_mem(),
      bytes,
      addr,
      value,
      offset,
    )),
  )
  Nil
}

/// The current size of this process's memory, in 64 KiB pages (`memory.size`).
///
/// - Returns the page count. Total. Reads the `Mem` from the cell.
pub fn size() -> Int {
  mem_size(current_mem())
}

/// Grow this process's memory by `delta` pages (`memory.grow`).
///
/// - `delta`: the number of pages to add (≥ 0).
/// - Returns the PREVIOUS size in pages on success, or `-1` if the growth would exceed the
///   declared max, the Safe cap, OR the 65536-page hard cap (in which case NOTHING is
///   allocated, the memory is unchanged, and no fuel is charged). Newly-added pages are
///   zero-filled. On success it charges `delta * page_bytes` fuel (proportional to the bytes
///   allocated — a big grow is not O(1)-cheap, E3) and writes the new `Mem` back.
pub fn grow(delta: Int) -> Int {
  let #(result, updated) = mem_grow(current_mem(), delta)
  case result {
    -1 -> -1
    old -> {
      rt_meter.charge(delta * page_bytes)
      rt_state.mem_put(mem_to_dynamic(updated))
      old
    }
  }
}

/// Write an active DATA segment's `bytes` into this process's memory at `offset`, at
/// instantiation. Bounds-checked (no-wrap), whole range up front.
///
/// - `offset`: the destination byte offset.
/// - `bytes`: the raw bytes to write.
/// - Returns `Ok(Nil)` (writing the new `Mem` back), or `Error(MemoryOutOfBounds)` if the
///   segment does not fit (an instantiation-time trap; nothing is written).
pub fn init_data(offset: Int, bytes: BitArray) -> Result(Nil, TrapReason) {
  case mem_init_data(current_mem(), offset, bytes) {
    Ok(updated) -> {
      rt_state.mem_put(mem_to_dynamic(updated))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// Read THIS process's current `Mem` out of the cell. Fail-closed: `rt_state.mem_get`
/// `panic`s on an un-seeded cell (it never returns garbage), which `rt_mem` propagates.
fn current_mem() -> Mem {
  dynamic_to_mem(rt_state.mem_get())
}

// ───────────────────────────── multi-memory + bulk cell wrappers (Cell strategy, R6/R7/R9) ─────────────────────────────
//
// The index-routed cell family: each op projects memory `mem_idx` from the memories vector via
// `rt_state.mem_at`/`with_mem_at` (index 0 = the default memory, so `load_at(0,…) ≡ load(…)` — the
// frozen heads above are the byte-identical index-0 path), drives the SAME pure `mem_*` core the
// frozen heads use, and — for a mutator — rebinds slot `mem_idx` to the NEW `Mem` (paged memory is
// immutable). The bulk ops (`fill`/`copy`/`init`) charge `count` fuel on the SUCCESS path (R9/§F).

/// Read memory `mem_idx`'s `Mem` out of this process's cell. Fail-closed on an un-seeded cell (via
/// `rt_state`); an out-of-range index is an internal invariant violation (unreachable
/// post-validation) that `rt_state.mem_at` `panic`s on.
fn current_mem_at(mem_idx: Int) -> Mem {
  dynamic_to_mem(rt_state.mem_at(mem_idx))
}

/// `load` on memory `mem_idx` (read-only). The index-routed twin of `load`; `load_at(0,…)` is
/// byte-identical to `load(…)`. Returns `Ok(bits)` or `Error(MemoryOutOfBounds)`. See `mem_load`.
pub fn load_at(
  mem_idx: Int,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  mem_load(current_mem_at(mem_idx), bytes, signed, result_width, addr, offset)
}

/// `store` on memory `mem_idx`. Bounds-checks first (trap-before-write); on success rebinds slot
/// `mem_idx` to the new `Mem` and returns `Ok(Nil)`, else `Error(MemoryOutOfBounds)` (zero
/// mutation). The index-routed twin of `store`. See `mem_store`.
pub fn store_at(
  mem_idx: Int,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(Nil, TrapReason) {
  case mem_store(current_mem_at(mem_idx), bytes, addr, value, offset) {
    Ok(updated) -> {
      rt_state.with_mem_at(mem_idx, mem_to_dynamic(updated))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// `memory.size` of memory `mem_idx`, in 64 KiB pages. The index-routed twin of `size`.
pub fn size_at(mem_idx: Int) -> Int {
  mem_size(current_mem_at(mem_idx))
}

/// `memory.grow` memory `mem_idx` by `delta` pages. Returns the PREVIOUS size, or `-1` past the
/// max/cap (allocating nothing, charging nothing). On success charges `delta * page_bytes` fuel
/// (parity with `grow`) and rebinds slot `mem_idx`. The index-routed twin of `grow`.
pub fn grow_at(mem_idx: Int, delta: Int) -> Int {
  let #(result, updated) = mem_grow(current_mem_at(mem_idx), delta)
  case result {
    -1 -> -1
    old -> {
      rt_meter.charge(delta * page_bytes)
      rt_state.with_mem_at(mem_idx, mem_to_dynamic(updated))
      old
    }
  }
}

/// Write an active DATA segment's `bytes` into memory `mem_idx` at `offset`, at instantiation.
/// Whole-range bounds-checked (no-wrap). On success rebinds slot `mem_idx`; else
/// `Error(MemoryOutOfBounds)` (nothing written). The index-routed twin of `init_data`.
pub fn init_data_at(
  mem_idx: Int,
  offset: Int,
  bytes: BitArray,
) -> Result(Nil, TrapReason) {
  case mem_init_data(current_mem_at(mem_idx), offset, bytes) {
    Ok(updated) -> {
      rt_state.with_mem_at(mem_idx, mem_to_dynamic(updated))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// `memory.fill` on memory `mem_idx`: fill `count` bytes at `dest` with `value & 0xFF`. Eager
/// bounds (trap-before-write, R10). On success charges `count` fuel (R9/§F) and rebinds slot
/// `mem_idx`; else `Error(MemoryOutOfBounds)` with ZERO mutation and NO charge. See `mem_fill`.
pub fn fill(
  mem_idx: Int,
  dest: Int,
  value: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  case mem_fill(current_mem_at(mem_idx), dest, value, count) {
    Ok(updated) -> {
      rt_meter.charge(count)
      rt_state.with_mem_at(mem_idx, mem_to_dynamic(updated))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// `memory.copy` from memory `src_mem` to memory `dst_mem` (memmove, R11): copy `count` bytes
/// `src → dst`. Cross-memory when `dst_mem != src_mem` (the two slots are projected independently);
/// same-index when equal (the same handle drives both operands, still memmove-correct because the
/// source region is snapshotted first). Eager bounds on BOTH ranges (R10). On success charges
/// `count` fuel ONCE (R9) and rebinds slot `dst_mem`; else `Error(MemoryOutOfBounds)` with ZERO
/// mutation. See `mem_copy`.
pub fn copy(
  dst_mem: Int,
  src_mem: Int,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  case
    mem_copy(current_mem_at(dst_mem), current_mem_at(src_mem), dst, src, count)
  {
    Ok(updated) -> {
      rt_meter.charge(count)
      rt_state.with_mem_at(dst_mem, mem_to_dynamic(updated))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// `memory.init` into memory `mem_idx` from data segment bytes `seg` (ε if dropped, R2 — supplied
/// by `emit_core`): copy `count` bytes `src → dst`. Eager bounds on BOTH the segment and the
/// memory (R10) — a dropped segment traps for `count > 0`, no-ops for `count = 0`. On success
/// charges `count` fuel (R9) and rebinds slot `mem_idx`; else `Error(MemoryOutOfBounds)` with ZERO
/// mutation. See `mem_init`.
pub fn init(
  mem_idx: Int,
  seg: BitArray,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  case mem_init(current_mem_at(mem_idx), seg, dst, src, count) {
    Ok(updated) -> {
      rt_meter.charge(count)
      rt_state.with_mem_at(mem_idx, mem_to_dynamic(updated))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

// ───────────────────────────── tier-P threaded wrappers (state_strategy: Threaded) ─────────────────────────────
//
// The purely-functional twin of the cell-backed API above (Phase-4 keystone §A.2, owner unit
// 04). Under `state_strategy: Threaded` generated code threads the `rt_state.InstanceState`
// record as a value — every state-reaching function takes it as a leading parameter and returns
// the (possibly updated) record. These wrappers are THIN adapters: project `st.mem` (coerce the
// opaque `Dynamic` → `Mem` via the field seam `rt_state.mem`), drive the SAME pure `mem_*` core
// the cell path uses, and inject the result back via `rt_state.with_mem` — so the threaded and
// cell strategies compute BYTE-IDENTICAL results (G7). Reads leave `st` untouched; mutators
// return the rebound record (§10).

/// Threaded load (read-only): projects `st.mem`, drives `mem_load`, leaves `st` UNCHANGED (the
/// seam keeps threading the same record forward). Returns `Ok(bits)` or
/// `Error(MemoryOutOfBounds)`. See `mem_load` for the codec/bounds contract.
pub fn t_load(
  st: rt_state.InstanceState,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  mem_load(
    from_dynamic(rt_state.mem(st)),
    bytes,
    signed,
    result_width,
    addr,
    offset,
  )
}

/// Threaded store. Bounds-checks first (trap-before-write), then rebuilds only the affected
/// chunk(s) into a NEW `Mem` and rebinds `st.mem` to it — returning `Ok(st')` (the §10 rebound
/// record; paged memory is immutable, so unlike `atomics` the returned `mem` differs), or
/// `Error(MemoryOutOfBounds)` with `st` untouched (zero mutation). See `mem_store`.
pub fn t_store(
  st: rt_state.InstanceState,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(rt_state.InstanceState, TrapReason) {
  case mem_store(from_dynamic(rt_state.mem(st)), bytes, addr, value, offset) {
    Ok(updated) -> Ok(rt_state.with_mem(st, mem_to_dynamic(updated)))
    Error(reason) -> Error(reason)
  }
}

/// UNCHECKED threaded load (Phase-10, N5) — `t_load` MINUS the bounds check/`Result`. Reads the
/// `Mem` from the record; `st` unchanged. Returns the raw bit pattern.
pub fn t_load_unchecked(
  st: rt_state.InstanceState,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Int {
  mem_load_unchecked(
    from_dynamic(rt_state.mem(st)),
    bytes,
    signed,
    result_width,
    addr,
    offset,
  )
}

/// UNCHECKED threaded store (Phase-10, N5) — `t_store` MINUS the bounds check/`Result`. Rebinds
/// `st.mem` to the written `Mem` and returns the updated record.
pub fn t_store_unchecked(
  st: rt_state.InstanceState,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> rt_state.InstanceState {
  rt_state.with_mem(
    st,
    mem_to_dynamic(mem_store_unchecked(
      from_dynamic(rt_state.mem(st)),
      bytes,
      addr,
      value,
      offset,
    )),
  )
}

/// Threaded `memory.size` (read-only): the page count of `st.mem`; `st` unchanged.
pub fn t_size(st: rt_state.InstanceState) -> Int {
  mem_size(from_dynamic(rt_state.mem(st)))
}

/// Threaded `memory.grow`. Returns `#(prev_pages, st')` where `st'` rebinds `st.mem` to the
/// grown `Mem`, or `#(-1, st)` past the max / cap (unchanged, nothing allocated). Charges
/// `delta * page_bytes` grow fuel on the SUCCESS path — parity with the cell `grow`, so
/// metered+threaded is byte-identical to metered+cell (the G7 trap bar) and an untrusted portable
/// module cannot allocate to the page cap with zero CPU accounting. See `mem_grow`.
pub fn t_grow(
  st: rt_state.InstanceState,
  delta: Int,
) -> #(Int, rt_state.InstanceState) {
  let #(result, updated) = mem_grow(from_dynamic(rt_state.mem(st)), delta)
  case result {
    -1 -> #(-1, st)
    old -> {
      rt_meter.charge(delta * page_bytes)
      #(old, rt_state.with_mem(st, mem_to_dynamic(updated)))
    }
  }
}

/// Threaded active-data-segment write at instantiation. Bounds-checks the whole range up front,
/// then rebinds `st.mem` to the written `Mem` — returning `Ok(st')`, or `Error(MemoryOutOfBounds)`
/// (nothing written, `st` untouched). See `mem_init_data`.
pub fn t_init_data(
  st: rt_state.InstanceState,
  offset: Int,
  bytes: BitArray,
) -> Result(rt_state.InstanceState, TrapReason) {
  case mem_init_data(from_dynamic(rt_state.mem(st)), offset, bytes) {
    Ok(updated) -> Ok(rt_state.with_mem(st, mem_to_dynamic(updated)))
    Error(reason) -> Error(reason)
  }
}

// ───────────────────────────── multi-memory + bulk threaded twins (Threaded strategy, R6/R7/R9) ─────────────────────────────
//
// The purely-functional twins of the cell family above: project memory `mem_idx` from the threaded
// record's memories vector (`rt_state.t_mem_at`), drive the SAME pure `mem_*` core, and re-inject
// via `rt_state.t_with_mem_at` — so cell ≡ threaded byte-for-byte (G7), including fuel. `t_*_at(st,
// 0, …)` is byte-identical to the frozen `t_*` heads. Reads leave `st` untouched; a mutator returns
// the rebound record (paged memory is immutable → a new `Mem` in slot `mem_idx`).

/// Project memory `mem_idx`'s `Mem` out of the threaded record (read-only). Fail-closed `panic` on
/// an out-of-range index (via `rt_state.t_mem_at`).
fn project_mem_at(st: rt_state.InstanceState, mem_idx: Int) -> Mem {
  from_dynamic(rt_state.t_mem_at(st, mem_idx))
}

/// Threaded `load` on memory `mem_idx` (read-only): `st` unchanged. See `mem_load`.
pub fn t_load_at(
  st: rt_state.InstanceState,
  mem_idx: Int,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  mem_load(
    project_mem_at(st, mem_idx),
    bytes,
    signed,
    result_width,
    addr,
    offset,
  )
}

/// Threaded `store` on memory `mem_idx`. Bounds-checks first; on success returns `Ok(st')` with
/// slot `mem_idx` rebound to the new `Mem`, else `Error(MemoryOutOfBounds)` (`st` untouched, zero
/// mutation). See `mem_store`.
pub fn t_store_at(
  st: rt_state.InstanceState,
  mem_idx: Int,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(rt_state.InstanceState, TrapReason) {
  case mem_store(project_mem_at(st, mem_idx), bytes, addr, value, offset) {
    Ok(updated) ->
      Ok(rt_state.t_with_mem_at(st, mem_idx, mem_to_dynamic(updated)))
    Error(reason) -> Error(reason)
  }
}

/// Threaded `memory.size` of memory `mem_idx` (read-only). See `mem_size`.
pub fn t_size_at(st: rt_state.InstanceState, mem_idx: Int) -> Int {
  mem_size(project_mem_at(st, mem_idx))
}

/// Threaded `memory.grow` of memory `mem_idx`. Returns `#(prev_pages, st')` (slot `mem_idx`
/// rebound + `delta * page_bytes` fuel charged on success), or `#(-1, st)` past the cap
/// (unchanged, no charge). See `mem_grow`.
pub fn t_grow_at(
  st: rt_state.InstanceState,
  mem_idx: Int,
  delta: Int,
) -> #(Int, rt_state.InstanceState) {
  let #(result, updated) = mem_grow(project_mem_at(st, mem_idx), delta)
  case result {
    -1 -> #(-1, st)
    old -> {
      rt_meter.charge(delta * page_bytes)
      #(old, rt_state.t_with_mem_at(st, mem_idx, mem_to_dynamic(updated)))
    }
  }
}

/// Threaded active-data-segment write into memory `mem_idx` at instantiation. On success returns
/// `Ok(st')` (slot rebound), else `Error(MemoryOutOfBounds)` (nothing written). See `mem_init_data`.
pub fn t_init_data_at(
  st: rt_state.InstanceState,
  mem_idx: Int,
  offset: Int,
  bytes: BitArray,
) -> Result(rt_state.InstanceState, TrapReason) {
  case mem_init_data(project_mem_at(st, mem_idx), offset, bytes) {
    Ok(updated) ->
      Ok(rt_state.t_with_mem_at(st, mem_idx, mem_to_dynamic(updated)))
    Error(reason) -> Error(reason)
  }
}

/// Threaded `memory.fill` on memory `mem_idx`. Eager bounds (R10); on success returns `Ok(st')`
/// (slot rebound) charging `count` fuel (R9), else `Error(MemoryOutOfBounds)` with ZERO mutation
/// and NO charge. See `mem_fill`.
pub fn t_fill(
  st: rt_state.InstanceState,
  mem_idx: Int,
  dest: Int,
  value: Int,
  count: Int,
) -> Result(rt_state.InstanceState, TrapReason) {
  case mem_fill(project_mem_at(st, mem_idx), dest, value, count) {
    Ok(updated) -> {
      rt_meter.charge(count)
      Ok(rt_state.t_with_mem_at(st, mem_idx, mem_to_dynamic(updated)))
    }
    Error(reason) -> Error(reason)
  }
}

/// Threaded `memory.copy` from memory `src_mem` to `dst_mem` (memmove, R11; cross-memory when the
/// indices differ). Eager bounds on BOTH ranges (R10); on success returns `Ok(st')` (slot `dst_mem`
/// rebound) charging `count` fuel ONCE (R9), else `Error(MemoryOutOfBounds)` with ZERO mutation.
/// See `mem_copy`.
pub fn t_copy(
  st: rt_state.InstanceState,
  dst_mem: Int,
  src_mem: Int,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(rt_state.InstanceState, TrapReason) {
  case
    mem_copy(
      project_mem_at(st, dst_mem),
      project_mem_at(st, src_mem),
      dst,
      src,
      count,
    )
  {
    Ok(updated) -> {
      rt_meter.charge(count)
      Ok(rt_state.t_with_mem_at(st, dst_mem, mem_to_dynamic(updated)))
    }
    Error(reason) -> Error(reason)
  }
}

/// Threaded `memory.init` into memory `mem_idx` from segment bytes `seg` (ε if dropped, R2). Eager
/// bounds on BOTH the segment and the memory (R10); on success returns `Ok(st')` (slot rebound)
/// charging `count` fuel (R9), else `Error(MemoryOutOfBounds)` with ZERO mutation. See `mem_init`.
pub fn t_init(
  st: rt_state.InstanceState,
  mem_idx: Int,
  seg: BitArray,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(rt_state.InstanceState, TrapReason) {
  case mem_init(project_mem_at(st, mem_idx), seg, dst, src, count) {
    Ok(updated) -> {
      rt_meter.charge(count)
      Ok(rt_state.t_with_mem_at(st, mem_idx, mem_to_dynamic(updated)))
    }
    Error(reason) -> Error(reason)
  }
}

// ───────────────────────────── the pure paged core (the testable algebra) ─────────────────────────────

/// Build a fresh `Mem` of `min_pages` zero pages with a caller-chosen physical `chunk` size.
/// This is the pure constructor the cell-backed `fresh` wraps (with `default_chunk_bytes`)
/// and the differential suite drives across several chunk sizes.
///
/// - `min_pages`: initial pages (zero-filled — the sparse map starts empty, so no allocation).
/// - `max_pages`/`safe_cap`: see `fresh`; the baked `max` is `min(declared_or_safe_cap,
///   safe_cap, 65536)`.
/// - `chunk`: physical chunk size in bytes; keep `> 64` for off-heap REFC chunks.
/// - Returns the fresh `Mem`. Total.
pub fn fresh_mem(
  min_pages: Int,
  max_pages: Option(Int),
  safe_cap: Int,
  chunk: Int,
) -> Mem {
  Mem(
    pages: min_pages,
    max: effective_max(max_pages, safe_cap),
    chunk: chunk,
    data: dict.new(),
  )
}

/// Build a fresh 64-bit (`Idx64`) `Mem` of `min_pages` zero pages with a caller-chosen physical
/// `chunk` size — the pure constructor `fresh64` wraps (with `default_chunk_bytes`) and the
/// differential suite drives across several chunk sizes. Identical to `fresh_mem` except the
/// baked `max` folds the 64-bit cap `mem64_hard_max_pages` instead of `hard_max_pages` (§A.3).
///
/// - `min_pages`: initial pages (zero-filled — the sparse map starts empty, so no allocation even
///   for `min > 2^16`).
/// - `max_pages`/`mem64_cap`: see `fresh64`; the baked `max` is
///   `min(declared ?? cap, cap)` with `cap = min(mem64_cap, mem64_hard_max_pages)`.
/// - `chunk`: physical chunk size in bytes; keep `> 64` for off-heap REFC chunks.
/// - Returns the fresh `Mem`. Total.
pub fn fresh_mem64(
  min_pages: Int,
  max_pages: Option(Int),
  mem64_cap: Int,
  chunk: Int,
) -> Mem {
  Mem(
    pages: min_pages,
    max: effective_max_for(max_pages, mem64_cap, mem64_hard_max_pages),
    chunk: chunk,
    data: dict.new(),
  )
}

/// Pure load against an explicit `Mem`. Same contract as `load` but threads `m` instead of
/// reading the cell. Returns `Ok(bits)` or `Error(MemoryOutOfBounds)`.
pub fn mem_load(
  m: Mem,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  let ea = addr + offset
  case in_bounds(m, ea, bytes) {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let raw = read_bytes(m, ea, bytes)
      case signed {
        True -> Ok(decode_signed(raw, bytes, result_width))
        False -> Ok(decode_unsigned(raw, bytes))
      }
    }
  }
}

/// Pure store against an explicit `Mem`. Bounds-checks FIRST (trap-before-write, all-or-
/// nothing), then rebuilds only the affected chunk(s). Returns `Ok(new_mem)` or
/// `Error(MemoryOutOfBounds)` (the input `Mem` is returned untouched in the error path).
pub fn mem_store(
  m: Mem,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(Mem, TrapReason) {
  let ea = addr + offset
  case in_bounds(m, ea, bytes) {
    False -> Error(MemoryOutOfBounds)
    True -> Ok(write_bytes(m, ea, encode_le(value, bytes)))
  }
}

/// Pure UNCHECKED load against an explicit `Mem` (Phase-10 range-BCE, N5) — `mem_load` MINUS the
/// `in_bounds` compare. The caller (the versioned fast loop, unit 06) has PROVEN `ea + bytes` in
/// bounds via a runtime range-guard, so no `MemoryOutOfBounds` path is needed. BEAM-SAFE even on an
/// (guard-impossible) OOB: `read_bytes` returns ZEROS for absent sparse chunks (a contained wrong
/// value), NEVER a crash or corruption. Returns the raw bit pattern.
pub fn mem_load_unchecked(
  m: Mem,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Int {
  let raw = read_bytes(m, addr + offset, bytes)
  case signed {
    True -> decode_signed(raw, bytes, result_width)
    False -> decode_unsigned(raw, bytes)
  }
}

/// Pure UNCHECKED store against an explicit `Mem` (Phase-10, N5) — `mem_store` MINUS the `in_bounds`
/// compare. Returns the rebuilt `Mem`. BEAM-SAFE even on an (guard-impossible) OOB: `write_bytes`
/// writes into the process-local sparse chunk map (a contained write), NEVER corrupting other data.
pub fn mem_store_unchecked(
  m: Mem,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Mem {
  write_bytes(m, addr + offset, encode_le(value, bytes))
}

/// Pure `memory.size`: the current page count of `m`.
pub fn mem_size(m: Mem) -> Int {
  m.pages
}

/// Pure `memory.grow`. NO fuel charge (the cell-backed `grow` adds it). Returns
/// `#(old_pages, new_mem)` on success (pages += delta; new pages read as zero for free via
/// the sparse map), or `#(-1, m)` if `delta < 0` or `pages + delta` would exceed the baked `max`
/// — allocating nothing.
///
/// `max` already folds the per-width cap (`hard_max_pages` for `Idx32` via `fresh_mem`,
/// `mem64_hard_max_pages` for `Idx64` via `fresh_mem64`), so the check reads ONLY `max` and is
/// width-agnostic (§A.3). Behaviour-preserving for `Idx32`: `m.max <= hard_max_pages = 65_536`
/// there, so `new <= m.max` already implies the dropped `&& new <= hard_max_pages` conjunct.
pub fn mem_grow(m: Mem, delta: Int) -> #(Int, Mem) {
  let old = m.pages
  let new = old + delta
  case delta >= 0 && new <= m.max {
    True -> #(old, Mem(..m, pages: new))
    False -> #(-1, m)
  }
}

/// Pure active-data-segment write at instantiation. Bounds-checks the WHOLE range up front
/// (`offset + len <= byte_len`); on overflow returns `Error(MemoryOutOfBounds)` with no
/// write (aborts instantiation). Otherwise returns `Ok(new_mem)`.
pub fn mem_init_data(
  m: Mem,
  offset: Int,
  bytes: BitArray,
) -> Result(Mem, TrapReason) {
  let len = bit_array.byte_size(bytes)
  case offset >= 0 && offset + len <= byte_len(m) {
    False -> Error(MemoryOutOfBounds)
    True -> Ok(write_bytes(m, offset, bytes))
  }
}

/// Pure `memory.fill`: set `count` bytes at `dest` to the LOW byte of `value` (`value & 0xFF`).
///
/// - `dest`: the destination byte offset.
/// - `value`: an i32; only `value & 0xFF` is written (e.g. `fill(d, 0x12345678, 4)` writes
///   `78 78 78 78`).
/// - `count`: the number of bytes to write.
/// - Eager bounds (spec §4.4.9, R10): traps `Error(MemoryOutOfBounds)` iff `dest < 0`,
///   `count < 0`, or `dest + count > byte_len(m)` — checked UNCONDITIONALLY (`dest = byte_len,
///   count = 0` succeeds; `dest > byte_len, count = 0` traps). No `count == 0` short-circuit.
/// - Returns `Ok(new_mem)` on success (the input `Mem` returned untouched on trap — ZERO mutation,
///   including any in-bounds prefix). Charge-free (the cell/threaded wrapper charges `count` fuel).
pub fn mem_fill(
  m: Mem,
  dest: Int,
  value: Int,
  count: Int,
) -> Result(Mem, TrapReason) {
  case dest >= 0 && count >= 0 && dest + count <= byte_len(m) {
    False -> Error(MemoryOutOfBounds)
    True ->
      Ok(write_bytes(m, dest, repeat_byte(int.bitwise_and(value, 0xFF), count)))
  }
}

/// Pure `memory.copy` (memmove, R11): copy `count` bytes from `src` in `src_m` to `dst` in
/// `dst_m`.
///
/// - `dst_m`/`src_m`: the destination and source memories. They are the SAME value for a
///   same-index copy, and DISTINCT for a cross-memory copy (`memory.copy dstmemidx srcmemidx`);
///   the wrapper projects both from the memories vector. Overlap is correct in either direction
///   because the source region is snapshotted from the immutable `src_m` BEFORE any destination
///   byte is rebuilt (snapshot-then-write ≡ memmove).
/// - `dst`/`src`/`count`: destination offset, source offset, byte count.
/// - Eager bounds (spec §4.4.9, R10): traps `Error(MemoryOutOfBounds)` iff any of `dst`, `src`,
///   `count` is negative, `src + count > byte_len(src_m)`, or `dst + count > byte_len(dst_m)` —
///   BEFORE any write (ZERO mutation on trap).
/// - Returns `Ok(new_dst_m)` (the rebuilt destination). Charge-free.
pub fn mem_copy(
  dst_m: Mem,
  src_m: Mem,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Mem, TrapReason) {
  case
    src >= 0
    && dst >= 0
    && count >= 0
    && src + count <= byte_len(src_m)
    && dst + count <= byte_len(dst_m)
  {
    False -> Error(MemoryOutOfBounds)
    True -> Ok(write_bytes(dst_m, dst, read_bytes(src_m, src, count)))
  }
}

/// Pure `memory.init` from a data segment's CURRENT bytes `seg` (ε when the segment was dropped,
/// R2): copy `count` bytes from `src` in `seg` to `dst` in `m`.
///
/// - `seg`: the segment's current bytes — supplied by `emit_core` (06) after its drop-check, NOT
///   read from `rt_state` (rt_mem stays a pure byte-mover). A dropped segment arrives as `<<>>`.
/// - `dst`/`src`/`count`: destination memory offset, source segment offset, byte count.
/// - Eager bounds (spec §4.4.9, R10): traps `Error(MemoryOutOfBounds)` iff any of `dst`, `src`,
///   `count` is negative, `src + count > byte_size(seg)` (the segment bound — so `init` from a
///   dropped/ε segment with `count > 0` TRAPS and with `count = 0` is a no-op), or
///   `dst + count > byte_len(m)` — BEFORE any write (ZERO mutation on trap).
/// - Returns `Ok(new_mem)`. Charge-free.
pub fn mem_init(
  m: Mem,
  seg: BitArray,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Mem, TrapReason) {
  case
    src >= 0
    && dst >= 0
    && count >= 0
    && src + count <= bit_array.byte_size(seg)
    && dst + count <= byte_len(m)
  {
    False -> Error(MemoryOutOfBounds)
    True -> Ok(write_bytes(m, dst, take(seg, src, count)))
  }
}

/// The uniform differential hook (§B.2): the tier's whole in-bounds byte image, keyed on the
/// opaque cell / record `Dynamic` so the seam (unit 09) and the oracle can call `<mem_module>:
/// to_flat(MemDynamic)` identically across tiers. Coerces the `Dynamic` to a paged `Mem`, then
/// canonicalises it to one flat `byte_len`-length binary (`mem_flat`). O(byte_len); tests only.
pub fn to_flat(mem: Dynamic) -> BitArray {
  mem_flat(dynamic_to_mem(mem))
}

/// Canonicalise a paged `Mem` to one flat `byte_len`-length binary (every in-bounds byte,
/// absent chunks rendered as zero) — the pure image the differential compares against the
/// oracle's `o_flat`. O(byte_len); for tests only.
pub fn mem_flat(m: Mem) -> BitArray {
  read_bytes(m, 0, byte_len(m))
}

/// Coerce the cell / threaded-record's opaque `Dynamic` back into a paged `Mem` — the PUBLIC
/// `Dynamic → Mem` coercion the tier-P threaded wrappers and the §B.3 differential need to
/// project `st.mem`. Identity at run time (`gleam_stdlib:identity/1`); sound because `rt_mem` is
/// the sole producer of the term held in the `mem` slot. Tier-O, cannot fail.
pub fn from_dynamic(value: Dynamic) -> Mem {
  dynamic_to_mem(value)
}

// ───────────────────────────── the flat-binary rebuild oracle (E4) ─────────────────────────────

/// The trivially-correct flat-binary reference memory used ONLY in tests. `data` is one
/// contiguous binary of length `pages * page_bytes`; a store rebuilds the whole binary
/// (copy-on-write) — slow but unmistakable.
pub opaque type OMem {
  OMem(pages: Int, max: Int, data: BitArray)
}

/// Fresh oracle of `min_pages` zero pages, baking the same effective `max` as `fresh_mem`.
pub fn o_fresh(min_pages: Int, max_pages: Option(Int), safe_cap: Int) -> OMem {
  OMem(pages: min_pages, max: effective_max(max_pages, safe_cap), data: <<
    0:size({ min_pages * page_bytes * 8 }),
  >>)
}

/// Fresh 64-bit (`Idx64`) oracle of `min_pages` zero pages, baking the same effective `max` as
/// `fresh_mem64` (folding the 64-bit cap `mem64_hard_max_pages`) — the differential reference for
/// a SMALL bounded 64-bit memory (§E.1). The flat binary is O(byte_len), so this is for SMALL
/// sizes ONLY; the large-address (> 2³²) behaviour is proved by direct spec-corner assertions on
/// the sparse paged core (§E.2), NEVER by materialising this oracle.
pub fn o_fresh64(
  min_pages: Int,
  max_pages: Option(Int),
  mem64_cap: Int,
) -> OMem {
  OMem(
    pages: min_pages,
    max: effective_max_for(max_pages, mem64_cap, mem64_hard_max_pages),
    data: <<0:size({ min_pages * page_bytes * 8 })>>,
  )
}

/// Oracle load (same contract as `mem_load`) — `binary` slice + the shared LE codec.
pub fn o_load(
  o: OMem,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  let ea = addr + offset
  let limit = o.pages * page_bytes
  case ea >= 0 && ea + bytes <= limit {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let raw = take(o.data, ea, bytes)
      case signed {
        True -> Ok(decode_signed(raw, bytes, result_width))
        False -> Ok(decode_unsigned(raw, bytes))
      }
    }
  }
}

/// Oracle store (same contract as `mem_store`): bounds-check, then rebuild the whole binary.
pub fn o_store(
  o: OMem,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(OMem, TrapReason) {
  let ea = addr + offset
  let limit = o.pages * page_bytes
  case ea >= 0 && ea + bytes <= limit {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let new_bytes = encode_le(value, bytes)
      let pre = take(o.data, 0, ea)
      let post = take(o.data, ea + bytes, limit - ea - bytes)
      Ok(OMem(..o, data: <<pre:bits, new_bytes:bits, post:bits>>))
    }
  }
}

/// Oracle `memory.grow`: append `delta * page_bytes` zero bytes, same cap as `mem_grow` (reads
/// ONLY the baked `max`, which folds the per-width cap; the redundant `&& new <= hard_max_pages`
/// conjunct is dropped, behaviour-preserving for `Idx32` — §A.3).
pub fn o_grow(o: OMem, delta: Int) -> #(Int, OMem) {
  let old = o.pages
  let new = old + delta
  case delta >= 0 && new <= o.max {
    True -> #(
      old,
      OMem(..o, pages: new, data: <<
        o.data:bits,
        0:size({ delta * page_bytes * 8 }),
      >>),
    )
    False -> #(-1, o)
  }
}

/// Oracle active-data-segment write (same contract as `mem_init_data`).
pub fn o_init_data(
  o: OMem,
  offset: Int,
  bytes: BitArray,
) -> Result(OMem, TrapReason) {
  let len = bit_array.byte_size(bytes)
  let limit = o.pages * page_bytes
  case offset >= 0 && offset + len <= limit {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let pre = take(o.data, 0, offset)
      let post = take(o.data, offset + len, limit - offset - len)
      Ok(OMem(..o, data: <<pre:bits, bytes:bits, post:bits>>))
    }
  }
}

/// Oracle `memory.fill` (same contract as `mem_fill`): bounds-check, then splice `count` copies of
/// `value & 0xFF` into the flat binary. Trivially memmove-/eager-bounds-correct by construction.
pub fn o_fill(
  o: OMem,
  dest: Int,
  value: Int,
  count: Int,
) -> Result(OMem, TrapReason) {
  let limit = o.pages * page_bytes
  case dest >= 0 && count >= 0 && dest + count <= limit {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let new_bytes = repeat_byte(int.bitwise_and(value, 0xFF), count)
      let pre = take(o.data, 0, dest)
      let post = take(o.data, dest + count, limit - dest - count)
      Ok(OMem(..o, data: <<pre:bits, new_bytes:bits, post:bits>>))
    }
  }
}

/// Oracle `memory.copy` (same contract as `mem_copy`): slice the source region from the OLD
/// `src_o` binary (→ memmove-correct), then splice it into `dst_o`.
pub fn o_copy(
  dst_o: OMem,
  src_o: OMem,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(OMem, TrapReason) {
  let dst_limit = dst_o.pages * page_bytes
  let src_limit = src_o.pages * page_bytes
  case
    src >= 0
    && dst >= 0
    && count >= 0
    && src + count <= src_limit
    && dst + count <= dst_limit
  {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let region = take(src_o.data, src, count)
      let pre = take(dst_o.data, 0, dst)
      let post = take(dst_o.data, dst + count, dst_limit - dst - count)
      Ok(OMem(..dst_o, data: <<pre:bits, region:bits, post:bits>>))
    }
  }
}

/// Oracle `memory.init` from `seg`'s current bytes (same contract as `mem_init`): slice
/// `seg[src..src+count)` and splice it into the flat binary. A dropped/ε segment traps for
/// `count > 0` (the `src + count <= byte_size(seg)` bound) and no-ops for `count = 0`.
pub fn o_init(
  o: OMem,
  seg: BitArray,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(OMem, TrapReason) {
  let limit = o.pages * page_bytes
  case
    src >= 0
    && dst >= 0
    && count >= 0
    && src + count <= bit_array.byte_size(seg)
    && dst + count <= limit
  {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let region = take(seg, src, count)
      let pre = take(o.data, 0, dst)
      let post = take(o.data, dst + count, limit - dst - count)
      Ok(OMem(..o, data: <<pre:bits, region:bits, post:bits>>))
    }
  }
}

/// Oracle `memory.size`.
pub fn o_size(o: OMem) -> Int {
  o.pages
}

/// The oracle's flat byte image (its whole `data` binary) — the differential reference for
/// `to_flat(paged)`.
pub fn o_flat(o: OMem) -> BitArray {
  o.data
}

// ───────────────────────────── the v128-memory BitArray seam (S4, owner unit 08) ─────────────────────────────
//
// `load_bytes`/`store_bytes` are the PUBLIC checked wrappers over the private `read_bytes`/
// `write_bytes` (below): they move a whole `BitArray` slice/run rather than a scalar, so `emit_core`
// (06) can compose them with `rt_simd`'s lane-assembly helpers for the v128 memory family — `v128.
// load`/`store` (the 16 raw bytes ARE the vector), `v128.load{8x8,16x4,32x2}_{s,u}` /
// `v128.load{32,64}_zero` (load 8/4 bytes then extend/zero-pad in `rt_simd`). The bounds check is
// the SAME no-wrap bignum `in_bounds` the scalar path uses → `MemoryOutOfBounds` trap-BEFORE-write
// (the security boundary). The family mirrors the scalar `load`/`store`/`_at`/`t_*` structure
// exactly so 06 emits against it identically. Bytes are moved in ascending-address order (the
// little-endian in-memory layout); `rt_simd` interprets lanes. NO fuel charge (a single access,
// like the scalar `load`/`store`).

/// Pure v128-slice load against an explicit `Mem`: read exactly `n` bytes at `ea = addr + offset`
/// in ascending-address (little-endian) order. Threads `m` instead of the cell.
///
/// - `addr`/`offset`: the base address and static offset; `ea` is a BIGNUM, never masked (no-wrap,
///   so a 64-bit address/offset past 2³² is compared exactly — the memory64 property).
/// - `n`: the byte width to read (16 for `v128.load`, 8 for `load8x8`/`load64_zero`, 4 for
///   `load32_zero`).
/// - Returns `Ok(bytes)` — an exactly-`n`-byte `BitArray` (absent chunks contribute zero bytes) —
///   or `Error(MemoryOutOfBounds)` iff `ea < 0` or `ea + n > byte_len`. Read-only.
pub fn mem_load_bytes(
  m: Mem,
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  let ea = addr + offset
  case in_bounds(m, ea, n) {
    False -> Error(MemoryOutOfBounds)
    True -> Ok(read_bytes(m, ea, n))
  }
}

/// Pure v128-run store against an explicit `Mem`: bounds-check the WHOLE `[ea, ea+len(bytes))`
/// range FIRST (trap-before-write, all-or-nothing — ZERO mutation on trap), then write `bytes` in
/// ascending-address order, rebuilding only the touched chunk(s).
///
/// - `addr`/`offset`: the base and static offset; `ea = addr + offset` is a bignum (no-wrap).
/// - `bytes`: the run to write (16 bytes for `v128.store`; `rt_simd` produced the exact bytes).
/// - Returns `Ok(new_mem)` or `Error(MemoryOutOfBounds)` (the input `Mem` returned untouched).
pub fn mem_store_bytes(
  m: Mem,
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(Mem, TrapReason) {
  let ea = addr + offset
  case in_bounds(m, ea, bit_array.byte_size(bytes)) {
    False -> Error(MemoryOutOfBounds)
    True -> Ok(write_bytes(m, ea, bytes))
  }
}

/// `load_bytes` on THIS process's cell memory (index 0). The v128-slice twin of `load`; reads the
/// `Mem` from the cell. Returns `Ok(n_bytes)` or `Error(MemoryOutOfBounds)`. See `mem_load_bytes`.
pub fn load_bytes(
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  mem_load_bytes(current_mem(), addr, offset, n)
}

/// `store_bytes` on THIS process's cell memory (index 0). Bounds-checks first (trap-before-write);
/// on success writes the new `Mem` back to the cell and returns `Ok(Nil)`, else
/// `Error(MemoryOutOfBounds)` (zero mutation). The v128-run twin of `store`. See `mem_store_bytes`.
pub fn store_bytes(
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(Nil, TrapReason) {
  case mem_store_bytes(current_mem(), addr, bytes, offset) {
    Ok(updated) -> {
      rt_state.mem_put(mem_to_dynamic(updated))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// `load_bytes` on memory `mem_idx` (read-only). The index-routed twin of `load_bytes`;
/// `load_bytes_at(0, …)` is byte-identical to `load_bytes(…)`. See `mem_load_bytes`.
pub fn load_bytes_at(
  mem_idx: Int,
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  mem_load_bytes(current_mem_at(mem_idx), addr, offset, n)
}

/// `store_bytes` on memory `mem_idx`. Bounds-checks first; on success rebinds slot `mem_idx` to the
/// new `Mem` and returns `Ok(Nil)`, else `Error(MemoryOutOfBounds)` (zero mutation). The
/// index-routed twin of `store_bytes`. See `mem_store_bytes`.
pub fn store_bytes_at(
  mem_idx: Int,
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(Nil, TrapReason) {
  case mem_store_bytes(current_mem_at(mem_idx), addr, bytes, offset) {
    Ok(updated) -> {
      rt_state.with_mem_at(mem_idx, mem_to_dynamic(updated))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// Threaded `load_bytes` (read-only): projects `st.mem`, drives `mem_load_bytes`, leaves `st`
/// UNCHANGED. Returns `Ok(n_bytes)` or `Error(MemoryOutOfBounds)`. See `mem_load_bytes`.
pub fn t_load_bytes(
  st: rt_state.InstanceState,
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  mem_load_bytes(from_dynamic(rt_state.mem(st)), addr, offset, n)
}

/// Threaded `store_bytes`. Bounds-checks first (trap-before-write), then rebinds `st.mem` to the
/// new `Mem` — returning `Ok(st')` (paged memory is immutable → a NEW handle), or
/// `Error(MemoryOutOfBounds)` with `st` untouched (zero mutation). See `mem_store_bytes`.
pub fn t_store_bytes(
  st: rt_state.InstanceState,
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(rt_state.InstanceState, TrapReason) {
  case mem_store_bytes(from_dynamic(rt_state.mem(st)), addr, bytes, offset) {
    Ok(updated) -> Ok(rt_state.with_mem(st, mem_to_dynamic(updated)))
    Error(reason) -> Error(reason)
  }
}

/// Threaded `load_bytes` on memory `mem_idx` (read-only): `st` unchanged. The index-routed twin of
/// `t_load_bytes`. See `mem_load_bytes`.
pub fn t_load_bytes_at(
  st: rt_state.InstanceState,
  mem_idx: Int,
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  mem_load_bytes(project_mem_at(st, mem_idx), addr, offset, n)
}

/// Threaded `store_bytes` on memory `mem_idx`. Bounds-checks first; on success returns `Ok(st')`
/// with slot `mem_idx` rebound to the new `Mem`, else `Error(MemoryOutOfBounds)` (`st` untouched,
/// zero mutation). The index-routed twin of `t_store_bytes`. See `mem_store_bytes`.
pub fn t_store_bytes_at(
  st: rt_state.InstanceState,
  mem_idx: Int,
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(rt_state.InstanceState, TrapReason) {
  case mem_store_bytes(project_mem_at(st, mem_idx), addr, bytes, offset) {
    Ok(updated) ->
      Ok(rt_state.t_with_mem_at(st, mem_idx, mem_to_dynamic(updated)))
    Error(reason) -> Error(reason)
  }
}

/// Oracle v128-slice load (same contract as `mem_load_bytes`): `binary` slice at `ea`. The
/// differential reference for `load_bytes` on a SMALL bounded memory (§E.1).
pub fn o_load_bytes(
  o: OMem,
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  let ea = addr + offset
  let limit = o.pages * page_bytes
  case ea >= 0 && ea + n <= limit {
    False -> Error(MemoryOutOfBounds)
    True -> Ok(take(o.data, ea, n))
  }
}

/// Oracle v128-run store (same contract as `mem_store_bytes`): bounds-check, then rebuild the whole
/// binary with `bytes` spliced at `ea`. The differential reference for `store_bytes` (§E.1).
pub fn o_store_bytes(
  o: OMem,
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(OMem, TrapReason) {
  let ea = addr + offset
  let n = bit_array.byte_size(bytes)
  let limit = o.pages * page_bytes
  case ea >= 0 && ea + n <= limit {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let pre = take(o.data, 0, ea)
      let post = take(o.data, ea + n, limit - ea - n)
      Ok(OMem(..o, data: <<pre:bits, bytes:bits, post:bits>>))
    }
  }
}

// ───────────────────────────── shared helpers ─────────────────────────────

/// `2^n` as a BEAM bignum (used for sign-extension widths beyond 62 bits).
fn pow2(n: Int) -> Int {
  int.bitwise_shift_left(1, n)
}

/// Build a `count`-byte `BitArray` every byte of which is `byte` (`0..255`) — the constant fill
/// payload `mem_fill` splices. A DOUBLING builder (O(log count) concatenations of off-heap REFC
/// binaries) so a large fill does not do `count` small allocations. `count <= 0` yields `<<>>`
/// (so `write_bytes` is a no-op → the spec `n = 0` case). The builder doubles `acc` until it is
/// at least `count` bytes, then slices to exactly `count` (a zero-copy sub-binary).
fn repeat_byte(byte: Int, count: Int) -> BitArray {
  case count <= 0 {
    True -> <<>>
    False -> repeat_double(<<byte:size(8)>>, count)
  }
}

fn repeat_double(acc: BitArray, count: Int) -> BitArray {
  case bit_array.byte_size(acc) >= count {
    True -> take(acc, 0, count)
    False -> repeat_double(<<acc:bits, acc:bits>>, count)
  }
}

/// The effective max in pages baked at `fresh` time, parameterised by the per-width HARD cap
/// (§A.3). Returns `min(declared ?? cap, cap)` where `cap = min(safe_cap, hard_cap)`. Never lets
/// untrusted code allocate past `safe_cap` (E3) or the architectural `hard_cap`. The single fold
/// both widths delegate to: `Idx32` passes `hard_cap = hard_max_pages` (65_536), `Idx64` passes
/// `hard_cap = mem64_hard_max_pages` (2^32).
///
/// - `max_pages`: the module's declared maximum in pages, or `None` for "unbounded".
/// - `safe_cap`: the deployment cap (`safe_max_pages` for i32, `mem64_max_pages` for i64).
/// - `hard_cap`: the architectural per-width ceiling.
/// - Returns the baked `max` (a non-negative page count). Total.
fn effective_max_for(
  max_pages: Option(Int),
  safe_cap: Int,
  hard_cap: Int,
) -> Int {
  let cap = int.min(safe_cap, hard_cap)
  case max_pages {
    Some(declared) -> int.min(declared, cap)
    None -> cap
  }
}

/// The 32-bit (`Idx32`) effective max: `effective_max_for` with `hard_cap = hard_max_pages`
/// (65_536). Byte-identical to the frozen Phase-2 body (same computation), so every `Idx32`
/// caller (`fresh_mem`/`o_fresh`) bakes the SAME `max` as before (§A.3, Verification #4).
fn effective_max(max_pages: Option(Int), safe_cap: Int) -> Int {
  effective_max_for(max_pages, safe_cap, hard_max_pages)
}

/// `byte_len = pages * 65536`, the current (possibly-grown) length the bounds-check uses.
fn byte_len(m: Mem) -> Int {
  m.pages * page_bytes
}

/// The no-wrap bounds predicate: an access of `n` bytes at effective address `ea` is in
/// bounds iff `ea >= 0` and `ea + n <= byte_len`. `ea` is a bignum and is NEVER masked to
/// 32 bits, so `addr = 0xFFFFFFFF` + a large offset correctly fails here (it does not wrap).
fn in_bounds(m: Mem, ea: Int, n: Int) -> Bool {
  ea >= 0 && ea + n <= byte_len(m)
}

/// Encode `value`'s low `bytes` bytes little-endian. The `/little` integer segment wraps
/// `value` to `bytes * 8` bits automatically, which is exactly the `store8/16/32` low-bits
/// semantics. f32/f64 stores reuse this (the value is already the raw IEEE bit pattern).
fn encode_le(value: Int, bytes: Int) -> BitArray {
  let bits = bytes * 8
  <<value:size(bits)-little>>
}

/// Decode `bytes` little-endian bytes as an UNSIGNED integer — the loaded bit pattern for
/// `loadN_u` / plain / `f32.load` / `f64.load` (zero-extension is identity on the bit pattern).
fn decode_unsigned(raw: BitArray, bytes: Int) -> Int {
  let bits = bytes * 8
  let assert <<u:size(bits)-little-unsigned>> = raw
  u
}

/// Decode `bytes` little-endian bytes as a SIGNED integer then sign-extend to
/// `result_width` bits, returning the UNSIGNED two's-complement bit pattern in
/// `[0, 2^result_width)` — for `loadN_s`. (A raw negative `Int` must never escape into the
/// value layer.) E.g. byte `0x80`: `i32.load8_s` → `0xFFFFFF80`; `i64.load8_s` →
/// `0xFFFFFFFFFFFFFF80`. `result_width` is what disambiguates the two.
fn decode_signed(raw: BitArray, bytes: Int, result_width: Int) -> Int {
  let bits = bytes * 8
  let assert <<s:size(bits)-little-signed>> = raw
  case s >= 0 {
    True -> s
    False -> s + pow2(result_width)
  }
}

/// Slice `len` bytes from `bin` at byte offset `at` (zero-copy sub-binary). Short-circuits
/// `len <= 0` to the empty binary (so end-of-binary zero-length slices never fail).
fn take(bin: BitArray, at: Int, len: Int) -> BitArray {
  case len <= 0 {
    True -> <<>>
    False -> {
      let assert Ok(slice) = bit_array.slice(bin, at, len)
      slice
    }
  }
}

/// Read `n` bytes starting at absolute byte address `ea` from the paged `Mem`, handling a
/// chunk-boundary span. Absent chunks contribute zero bytes WITHOUT being materialised.
fn read_bytes(m: Mem, ea: Int, n: Int) -> BitArray {
  case n <= 0 {
    True -> <<>>
    False -> {
      let cs = m.chunk
      let first = ea / cs
      let end_byte = ea + n - 1
      let last = end_byte / cs
      case first == last {
        True -> read_in_chunk(m, first, ea % cs, n)
        False -> read_span(m, ea, n, <<>>)
      }
    }
  }
}

/// Read `n` bytes wholly inside chunk `idx` at intra-chunk offset `off`. An ABSENT chunk is
/// all-zero, so it short-circuits to `n` zero bytes (never materialising the full chunk).
fn read_in_chunk(m: Mem, idx: Int, off: Int, n: Int) -> BitArray {
  case dict.get(m.data, idx) {
    Ok(chunk) -> take(chunk, off, n)
    Error(Nil) -> <<0:size({ n * 8 })>>
  }
}

/// Read a byte run that spans ≥ 2 chunks: take the in-chunk prefix, then recurse on the
/// remainder at the next chunk boundary, concatenating little-endian-order byte runs.
fn read_span(m: Mem, ea: Int, remaining: Int, acc: BitArray) -> BitArray {
  case remaining <= 0 {
    True -> acc
    False -> {
      let cs = m.chunk
      let idx = ea / cs
      let off = ea % cs
      let avail = cs - off
      let n = int.min(remaining, avail)
      let part = read_in_chunk(m, idx, off, n)
      read_span(m, ea + n, remaining - n, <<acc:bits, part:bits>>)
    }
  }
}

/// Write `bytes` starting at absolute byte address `ea`, rebuilding only the touched
/// chunk(s) and leaving the rest structurally shared. Callers MUST have bounds-checked first.
fn write_bytes(m: Mem, ea: Int, bytes: BitArray) -> Mem {
  write_loop(m, ea, bytes, bit_array.byte_size(bytes))
}

/// Per-chunk write loop: splice the in-chunk run into chunk `idx` (materialising a zero chunk
/// if absent), `dict.insert` the rebuilt chunk, and recurse for the remaining bytes.
fn write_loop(m: Mem, ea: Int, bytes: BitArray, remaining: Int) -> Mem {
  case remaining <= 0 {
    True -> m
    False -> {
      let cs = m.chunk
      let idx = ea / cs
      let off = ea % cs
      let avail = cs - off
      let n = int.min(remaining, avail)
      let part = take(bytes, 0, n)
      let rest = take(bytes, n, remaining - n)
      let chunk = chunk_for_store(m, idx, cs)
      let rebuilt = splice_chunk(chunk, off, part, cs)
      let m2 = Mem(..m, data: dict.insert(m.data, idx, rebuilt))
      write_loop(m2, ea + n, rest, remaining - n)
    }
  }
}

/// The chunk to write into: the stored chunk, or a freshly-materialised all-zero chunk when
/// absent (materialisation happens ONLY on a store, never a load).
fn chunk_for_store(m: Mem, idx: Int, cs: Int) -> BitArray {
  case dict.get(m.data, idx) {
    Ok(chunk) -> chunk
    Error(Nil) -> <<0:size({ cs * 8 })>>
  }
}

/// Replace `part`'s bytes at intra-chunk offset `off` inside the `cs`-byte chunk `c`,
/// returning the rebuilt chunk (one `cs`-byte allocation; `pre`/`post` are zero-copy
/// sub-binaries).
fn splice_chunk(c: BitArray, off: Int, part: BitArray, cs: Int) -> BitArray {
  let n = bit_array.byte_size(part)
  let pre = take(c, 0, off)
  let post = take(c, off + n, cs - off - n)
  <<pre:bits, part:bits, post:bits>>
}
