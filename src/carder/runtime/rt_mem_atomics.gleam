//// `rt_mem_atomics` — the tier-O `atomics` linear-memory backend (owner: unit P4-04). The
//// **O(1) performance lever** (G2): `load`/`store`/`grow` in constant time over a FIXED array
//// of Erlang `atomics` 64-bit words, backing a byte-addressable little-endian linear memory.
////
//// **Trust tier (G6).** `atomics` is ERTS-native — no custom C, no NIF — so it is memory-safe
//// by construction and CANNOT crash the node; Safe permits it (tier P or O, never N). A bounds
//// bug's worst case is a wrong/missing trap or a node-safe process crash, NEVER a host
//// out-of-bounds read (the §11 security invariant). The array is PROCESS-LOCAL and never shared
//// (G8, the threads/shared-memory hard non-goal).
////
//// **Correctness is identical to `paged`, byte-for-byte (E4).** Little-endian throughout;
//// no-wrap effective address → trap on every access (E3); all-or-nothing multi-byte stores
//// (trap-before-write); the Safe max-pages cap. Held byte-for-byte to the flat-binary `rebuild`
//// oracle (`rt_mem`'s `o_*`), so the atomics tier is byte-identical to paged and to the spec.
//// f32/f64 store/load are raw-byte moves over the IEEE bit pattern — never a BEAM-double
//// round-trip, so NaN payloads / signalling bits survive (D5).
////
//// **`grow` is the sharp edge (§C).** `atomics` arrays are FIXED SIZE at creation, so `fresh`
//// pre-allocates to the effective max (`reserve` words) and `grow` is a pure watermark move
//// within `[0, max]` (the words already exist → O(1), `-1` past the cap, never a re-allocation).
//// On an UNCAPPED module (effective max = the 65536-page / 4 GiB hard ceiling), the eager
//// reservation would exceed the node-safe `atomics_reserve_cap_pages` ceiling, so the build is
//// FAIL-CLOSED REJECTED at link time (unit 07's `validate_binding`) — NEVER a silent 4 GiB
//// pre-allocation and NEVER a silent `paged` degrade. `a_fresh` is a defensive backstop that
//// `panic`s node-safe if ever reached with an over-cap reservation (unreachable post-validation).
////
//// **Byte↔word addressing (LE, exact).** Byte address `a` → word `w = a / 8`, `atomics` index
//// `ix = w + 1` (1-indexed), byte position `p = a mod 8` where `p = 0` is the least-significant
//// byte. A word's value is `Σ_{k=0..7} byte[8w+k]·256^k`. A multi-byte access of `n <= 8` bytes
//// spans word `w` and, iff `p + n > 8`, word `w+1` — at most two words. Alignment is a hint;
//// unaligned and word-boundary-crossing accesses are fully supported.
////
//// **Phase-5 additive surface (bulk memory + multi-memory, P5-08).** Additive to the frozen
//// Phase-4 heads: the pure `a_fill`/`a_copy`/`a_init` core and the index-routed cell/threaded
//// wrappers (`fill`/`copy`/`init` + the `_at` load/store/size/grow/init_data variants). Because
//// the backing array mutates IN PLACE, the bulk ops must be overlap-correct on the mutable store:
//// they GATHER the source region into an immutable `BitArray` snapshot FIRST, then SCATTER —
//// memmove-correct in either direction and cross-memory-correct (a distinct `ref`), byte-identical
//// to the `paged`/oracle result (the differential proves it). Eager bounds (trap-before-write,
//// R10) → ZERO mutation on trap; each bulk-op wrapper charges `count` fuel on success (R9/§F). The
//// index-0 `_at` heads are byte-identical to the frozen heads (H7). **memory64 + atomics (P6-08,
//// §D):** a 64-bit memory's effective max almost always exceeds `atomics_reserve_cap_pages`, so an
//// over-cap 64-bit binding is FAIL-CLOSED REJECTED at link time (unit 09's `validate_binding`
//// calls `reservation64`) — never a silent 256 TiB pre-alloc, never a silent `paged` degrade. A
//// TINY BOUNDED 64-bit memory (`(memory i64 1 8)`, reserve `<= reserve_cap`) IS admitted and runs
//// correctly: its addresses are all `< 8 * 64 KiB`, the byte↔word gather/scatter is bignum-safe,
//// and the differential proves it byte-for-byte against paged/oracle (§E.1). Everything larger
//// ships only on `paged`/`portable` (S9).

import carder/ir.{type TrapReason, MemoryOutOfBounds}
import carder/runtime/rt_mem
import carder/runtime/rt_meter
import carder/runtime/rt_state.{type InstanceState}
import carder/runtime/rt_trap
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/option.{type Option, None, Some}

// ───────────────────────────── constants ─────────────────────────────

/// Words per 64 KiB page: `rt_mem.page_bytes / 8 = 8192`. The physical backing of `n` pages is
/// `n * words_per_page` unsigned 64-bit `atomics` words. (The frozen page size `page_bytes` and
/// hard cap `hard_max_pages` are single-sourced from `rt_mem`.)
pub const words_per_page: Int = 8192

/// The tier-O node-safety ceiling: the MOST pages `fresh` will eagerly reserve as `atomics`
/// words. A module whose effective max exceeds this is FAIL-CLOSED REJECTED at link time (§C) —
/// `atomics` requires a bounded max/cap `=<` the reserve cap; it never silently degrades to
/// `paged` and never pre-allocates past this ceiling. Eager reservation of `p` pages costs
/// `p * 64 KiB` of `atomics` backing, so an UNBOUNDED reserve is a node-OOM (node-crash) vector —
/// forbidden for a tier that "cannot crash the node" (G6). FINITE and well below the 65536-page
/// (4 GiB) i32 ceiling; a tuning knob unit 07/10 may adjust. Default: a conservative 4096 pages
/// (256 MiB of eager reservation at the ceiling).
pub const atomics_reserve_cap_pages: Int = 4096

// ───────────────────────────── the opaque atomics handle ─────────────────────────────

/// Tier-O linear memory backed by a fixed array of Erlang `atomics` 64-bit words (the O(1)
/// mutable store). Opaque: callers go through the pure `a_*` core / the cell + threaded
/// wrappers. The `atomics` `ref` is PROCESS-LOCAL and never shared (G8). There is NO paged
/// fallback variant: when the effective max exceeds the node-safe reserve cap (§C), the build is
/// FAIL-CLOSED REJECTED at link time — never silently pre-allocated at 4 GiB and never silently
/// degraded to `paged`. So `a_fresh` only ever constructs `AtomicsBacked`.
///
/// - `ref`: the opaque `atomics` array handle (from `atomics:new/2`, `{signed, false}` →
///   unsigned 64-bit words). MUTABLE, shared by reference; a store mutates it IN PLACE.
/// - `pages`: the current logical size in 64 KiB pages — the `memory.size` source and the
///   bounds-check length (`byte_len = pages * page_bytes`). A watermark, NOT the physical size.
/// - `max`: the effective max in pages (`min(declared_max ?? safe_cap, safe_cap, 65536)`);
///   `grow` never exceeds it.
/// - `reserve`: the physical reservation in pages (`max(min_pages, max)`); `ref` holds
///   `reserve * words_per_page` zero-initialised words. `grow` is a pure watermark move within
///   `[0, max]` — the words already exist.
pub opaque type Atomics {
  AtomicsBacked(ref: Dynamic, pages: Int, max: Int, reserve: Int)
}

// ───────────────────────────── the `atomics` FFI (carder_-namespaced shim) ─────────────────────────────

/// Allocate a fresh zero-initialised `atomics` array of `arity` unsigned 64-bit words. `arity`
/// must be `>= 1`. Tier-O, cannot crash the node. See `carder_rt_mem_atomics_ffi`.
@external(erlang, "carder_rt_mem_atomics_ffi", "new")
fn atomics_new(arity: Int) -> Dynamic

/// Read the 1-indexed word `ix` (a `0..2^64-1` integer) from `ref`. No copy.
@external(erlang, "carder_rt_mem_atomics_ffi", "get")
fn atomics_get(ref: Dynamic, ix: Int) -> Int

/// Write `val` (a `0..2^64-1` integer) into the 1-indexed word `ix`, mutating `ref` IN PLACE.
@external(erlang, "carder_rt_mem_atomics_ffi", "put")
fn atomics_put(ref: Dynamic, ix: Int, val: Int) -> Nil

// ───────────────────────────── the opaque `Dynamic` coercions ─────────────────────────────

/// Coerce an `Atomics` handle into the opaque `Dynamic` the cell / threaded record stores.
/// Identity at run time (`gleam_stdlib:identity/1`); tier-O, cannot fail.
@external(erlang, "gleam_stdlib", "identity")
fn atomics_to_dynamic(a: Atomics) -> Dynamic

/// Coerce the cell / record's opaque `Dynamic` back into an `Atomics`. Identity at run time;
/// sound because `rt_mem_atomics` is the sole producer of the term held in the `mem` slot.
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_atomics(value: Dynamic) -> Atomics

// ───────────────────────────── the pure `a_*` core (value-threaded, effectful) ─────────────────────────────

/// Whether a tier-O `atomics` binding of `(min_pages, max_pages, safe_cap)` can be node-safely
/// reserved: the physical reservation `reserve = max(min_pages, effective_max)` pages must be
/// `=<` `reserve_cap`. This is the SINGLE source unit 07's `validate_binding` calls to
/// FAIL-CLOSED REJECT an over-cap / uncapped `atomics` binding at LINK time ("atomics requires a
/// bounded max/cap `=<` the reserve cap") — never a silent `paged` degrade or a 4 GiB
/// pre-allocation (§C).
///
/// - `min_pages`: the module's declared memory minimum in pages.
/// - `max_pages`: the module's declared maximum in pages, or `None` for "unbounded".
/// - `safe_cap`: the finite Safe max-pages cap (`binding.safe_max_pages`).
/// - `reserve_cap`: the node-safe reservation ceiling (normally `atomics_reserve_cap_pages`).
/// - Returns `Ok(reserve_pages)` when the binding is admissible (`atomics` engages O(1)), or
///   `Error(Nil)` when `reserve > reserve_cap` (the caller MUST reject, never degrade).
pub fn reservation(
  min_pages: Int,
  max_pages: Option(Int),
  safe_cap: Int,
  reserve_cap: Int,
) -> Result(Int, Nil) {
  let reserve = int.max(min_pages, effective_max(max_pages, safe_cap))
  case reserve <= reserve_cap {
    True -> Ok(reserve)
    False -> Error(Nil)
  }
}

/// The idx-aware fail-closed gate for a 64-bit (`Idx64`, memory64) `atomics` binding (§D). Whether
/// a tiny bounded 64-bit memory can be node-safely reserved: the physical reservation `reserve =
/// max(min_pages, effective_max64)` pages (folding the 64-bit cap `mem64_hard_max_pages`, NOT the
/// i32 cap) must be `=<` `reserve_cap`. This is the SINGLE source unit 09's `validate_binding`
/// calls to FAIL-CLOSED REJECT an over-cap / unbounded 64-bit `atomics` binding at LINK time —
/// never a silent `paged` degrade, never a 256 TiB pre-allocation (I4/S9).
///
/// - `min_pages`: the module's declared 64-bit memory minimum in pages (a `u64`).
/// - `max_pages`: the declared maximum in pages, or `None` for "unbounded".
/// - `mem64_cap`: the deployment 64-bit page cap (`Binding.mem64_max_pages`).
/// - `reserve_cap`: the node-safe reservation ceiling (normally `atomics_reserve_cap_pages`).
/// - Returns `Ok(reserve_pages)` for a tiny bounded 64-bit memory (`atomics` engages O(1)), or
///   `Error(Nil)` when `reserve > reserve_cap` (the caller MUST reject → `paged`/`portable`; NEVER
///   degrade). An unbounded 64-bit memory (`max = None`) folds to `min(mem64_cap, 2^32)` pages,
///   vastly over `reserve_cap`, so it is always rejected.
pub fn reservation64(
  min_pages: Int,
  max_pages: Option(Int),
  mem64_cap: Int,
  reserve_cap: Int,
) -> Result(Int, Nil) {
  let reserve = int.max(min_pages, effective_max64(max_pages, mem64_cap))
  case reserve <= reserve_cap {
    True -> Ok(reserve)
    False -> Error(Nil)
  }
}

/// Build a fresh tier-O memory of `min_pages` zero pages, pre-reserving `reserve =
/// max(min_pages, eff)` pages of `atomics` words up front.
///
/// - `min_pages`: initial pages (zero-filled — `atomics:new` zeroes the words).
/// - `max_pages`/`safe_cap`: the declared max / Safe cap; the baked effective max is
///   `eff = min(declared_max ?? cap, cap)` with `cap = min(safe_cap, hard_max_pages)` — the same
///   `effective_max` `rt_mem`'s paged core bakes (the differential proves they agree).
/// - `reserve_cap`: the node-safe reservation ceiling (`atomics_reserve_cap_pages`).
/// - Returns the fresh `AtomicsBacked`. REQUIRES `reserve =< reserve_cap`: unit 07's
///   `validate_binding` rejects an over-cap / uncapped binding at LINK time, so this is only
///   ever reached with an admissible reservation. Reached with an OVER-CAP `reserve` (unreachable
///   post-validation) it FAILS CLOSED — a node-safe `panic` ("atomics requires a bounded max/cap
///   <= the reserve cap") — never silently pre-allocating 4 GiB and never degrading to `paged`
///   (§C, keystone §B.2). At least one word is always reserved (a 0-page memory still needs a
///   valid `atomics` array; the extra word is never in bounds).
pub fn a_fresh(
  min_pages: Int,
  max_pages: Option(Int),
  safe_cap: Int,
  reserve_cap: Int,
) -> Atomics {
  let eff = effective_max(max_pages, safe_cap)
  let reserve = int.max(min_pages, eff)
  case reserve <= reserve_cap {
    False ->
      panic as "rt_mem_atomics.a_fresh: atomics requires a bounded max/cap <= the reserve cap (over-cap reservation, unreachable post-validation)"
    True -> {
      let arity = int.max(1, reserve * words_per_page)
      AtomicsBacked(
        ref: atomics_new(arity),
        pages: min_pages,
        max: eff,
        reserve: reserve,
      )
    }
  }
}

/// Build a fresh TINY BOUNDED 64-bit (`Idx64`, memory64) tier-O memory (§D). Identical to
/// `a_fresh` except the effective max folds the 64-bit cap `mem64_hard_max_pages` (via
/// `effective_max64`) instead of the i32 cap. REQUIRES `reserve = max(min_pages, eff) =<
/// reserve_cap`: unit 09's `validate_binding` calls `reservation64` first and fail-closed rejects
/// an over-cap / unbounded 64-bit binding at LINK time, so this is only ever reached with an
/// admissible reservation.
///
/// - `min_pages`/`max_pages`/`mem64_cap`: see `reservation64`.
/// - `reserve_cap`: the node-safe reservation ceiling (`atomics_reserve_cap_pages`).
/// - Returns the fresh `AtomicsBacked`. Reached with an OVER-CAP `reserve` (unreachable
///   post-validation) it FAILS CLOSED — a node-safe `panic` — never silently pre-allocating 256
///   TiB and never degrading to `paged` (§D). A tiny bounded 64-bit memory's addresses are all
///   within word range, so the frozen `a_load`/`a_store`/`a_grow`/bulk heads run it correctly
///   verbatim (its `max <= reserve_cap < hard_max_pages`, so `a_grow`'s retained i32 conjunct is
///   inert).
pub fn a_fresh64(
  min_pages: Int,
  max_pages: Option(Int),
  mem64_cap: Int,
  reserve_cap: Int,
) -> Atomics {
  let eff = effective_max64(max_pages, mem64_cap)
  let reserve = int.max(min_pages, eff)
  case reserve <= reserve_cap {
    False ->
      panic as "rt_mem_atomics.a_fresh64: atomics requires a tiny bounded 64-bit memory (reserve <= the reserve cap; over-cap reservation unreachable post-validation)"
    True -> {
      let arity = int.max(1, reserve * words_per_page)
      AtomicsBacked(
        ref: atomics_new(arity),
        pages: min_pages,
        max: eff,
        reserve: reserve,
      )
    }
  }
}

/// Pure load (same contract as `rt_mem.mem_load`): assemble the raw `n`-byte little-endian value
/// from the `<= 2` touched words and decode with the frozen LE codec.
///
/// - `bytes`: the access width (1/2/4/8).
/// - `signed`: whether a sub-word load is sign-extended to `result_width` (else zero-extended).
/// - `result_width`: the result's width in bits (32/64) — disambiguates `i32.load8_s` from
///   `i64.load8_s`.
/// - `addr`/`offset`: the unsigned i32 base and static offset. `ea = addr + offset` is a BIGNUM,
///   NEVER masked (§D no-wrap).
/// - Returns `Ok(bits)` (the loaded value as a raw bit pattern), or `Error(MemoryOutOfBounds)`
///   iff `ea < 0` or `ea + bytes > byte_len`. Read-only.
pub fn a_load(
  a: Atomics,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  let ea = addr + offset
  case in_bounds(a, ea, bytes) {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let raw = gather(a, ea, bytes)
      case signed {
        True -> Ok(decode_signed(raw, bytes, result_width))
        False -> Ok(raw)
      }
    }
  }
}

/// Pure store. Bounds-checks the WHOLE `[ea, ea+bytes)` range FIRST (trap-before-write,
/// all-or-nothing — ZERO mutation on trap), then scatters `value`'s low `bytes` bytes into the
/// `<= 2` touched words by read-modify-write.
///
/// - `bytes`: the store width (1/2/4/8). The low `bytes` bytes are written (wraps `store8/16/32`
///   for free); f32/f64 reuse this over the raw IEEE bits.
/// - `addr`/`value`/`offset`: the base address, raw bit pattern, and static offset.
/// - Returns `Ok(a')` where `a'` is the SAME `AtomicsBacked` handle (mutated in place — the `ref`
///   is shared by reference), or `Error(MemoryOutOfBounds)` with zero mutation.
pub fn a_store(
  a: Atomics,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(Atomics, TrapReason) {
  let ea = addr + offset
  case in_bounds(a, ea, bytes) {
    False -> Error(MemoryOutOfBounds)
    True -> {
      scatter(a, ea, value, bytes)
      Ok(a)
    }
  }
}

/// Pure UNCHECKED load (Phase-10 range-BCE, N5) — `a_load` MINUS the `in_bounds` compare. The
/// versioned fast loop (unit 06) proved `ea + bytes` in bounds. BEAM-SAFE even on an
/// (guard-impossible) OOB: `gather` indexes the ERTS-native `atomics` array via `atomics:get`,
/// which is itself bounds-checked (out-of-physical-array → a caught `badarg`; an in-reserve word →
/// a contained value) — NEVER corruption or a node crash. Returns the raw bit pattern.
pub fn a_load_unchecked(
  a: Atomics,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Int {
  let raw = gather(a, addr + offset, bytes)
  case signed {
    True -> decode_signed(raw, bytes, result_width)
    False -> raw
  }
}

/// Pure UNCHECKED store (Phase-10, N5) — `a_store` MINUS the `in_bounds` compare. Mutates the shared
/// `ref` in place and returns the SAME handle. BEAM-SAFE on an (guard-impossible) OOB: `scatter`'s
/// `atomics:put` is ERTS-bounds-checked (contained, never corrupting).
pub fn a_store_unchecked(
  a: Atomics,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Atomics {
  scatter(a, addr + offset, value, bytes)
  a
}

/// Pure `memory.size`: the current page-count watermark of `a`.
pub fn a_size(a: Atomics) -> Int {
  a.pages
}

/// Pure `memory.grow`. NO fuel charge (the cell/threaded wrappers add it). A pure watermark move
/// within the pre-reserved words: returns `#(old_pages, a')` on success (`pages += delta`; the
/// grown pages read as zero — their words were reserved and never written), or `#(-1, a)` if
/// `delta < 0`, or `pages + delta` would exceed the baked `max` or the 65536-page hard cap —
/// allocating NOTHING. O(1): no re-allocation, no copy.
pub fn a_grow(a: Atomics, delta: Int) -> #(Int, Atomics) {
  let old = a.pages
  let new = old + delta
  case delta >= 0 && new <= a.max && new <= rt_mem.hard_max_pages {
    True -> #(old, AtomicsBacked(..a, pages: new))
    False -> #(-1, a)
  }
}

/// Pure active-data-segment write at instantiation. Bounds-checks the WHOLE range up front
/// (`offset >= 0 && offset + len <= byte_len`); on overflow returns `Error(MemoryOutOfBounds)`
/// with no write (aborts instantiation). Otherwise scatters the bytes and returns `Ok(a')` (the
/// SAME handle — mutated in place).
pub fn a_init_data(
  a: Atomics,
  offset: Int,
  bytes: BitArray,
) -> Result(Atomics, TrapReason) {
  let len = bit_array.byte_size(bytes)
  case offset >= 0 && offset + len <= byte_len(a) {
    False -> Error(MemoryOutOfBounds)
    True -> {
      write_data_loop(a, offset, bytes)
      Ok(a)
    }
  }
}

/// Pure `memory.fill` (same contract as `rt_mem.mem_fill`): eager bounds
/// (`dest >= 0 && count >= 0 && dest + count <= byte_len`, R10 — checked UNCONDITIONALLY), then
/// scatter `value & 0xFF` across `[dest, dest+count)` byte-by-byte. Returns `Ok(a)` (the SAME
/// handle — mutated in place) or `Error(MemoryOutOfBounds)` with ZERO mutation. Charge-free.
pub fn a_fill(
  a: Atomics,
  dest: Int,
  value: Int,
  count: Int,
) -> Result(Atomics, TrapReason) {
  case dest >= 0 && count >= 0 && dest + count <= byte_len(a) {
    False -> Error(MemoryOutOfBounds)
    True -> {
      fill_loop(a, dest, int.bitwise_and(value, 0xFF), count)
      Ok(a)
    }
  }
}

/// Pure `memory.copy` (memmove, R11; same contract as `rt_mem.mem_copy`): eager bounds on BOTH
/// ranges, then GATHER the whole `src` region from `src_a` into an immutable `BitArray` snapshot
/// and SCATTER it into `dst_a` — snapshot-first, so overlap is correct even when `dst_a` and
/// `src_a` are the SAME handle, and cross-memory copy (distinct handles) shares the path. Returns
/// `Ok(dst_a)` (mutated in place) or `Error(MemoryOutOfBounds)` with ZERO mutation. Charge-free.
pub fn a_copy(
  dst_a: Atomics,
  src_a: Atomics,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Atomics, TrapReason) {
  case
    src >= 0
    && dst >= 0
    && count >= 0
    && src + count <= byte_len(src_a)
    && dst + count <= byte_len(dst_a)
  {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let region = gather_bytes(src_a, src, count)
      write_data_loop(dst_a, dst, region)
      Ok(dst_a)
    }
  }
}

/// Pure `memory.init` from `seg`'s current bytes (ε if dropped, R2; same contract as
/// `rt_mem.mem_init`): eager bounds on BOTH the segment (`src + count <= byte_size(seg)`) and the
/// memory (`dst + count <= byte_len`), then scatter `seg[src..src+count)` at `dst`. A dropped/ε
/// segment traps for `count > 0` and no-ops for `count = 0`. Returns `Ok(a)` (mutated in place) or
/// `Error(MemoryOutOfBounds)` with ZERO mutation. Charge-free.
pub fn a_init(
  a: Atomics,
  seg: BitArray,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Atomics, TrapReason) {
  case
    src >= 0
    && dst >= 0
    && count >= 0
    && src + count <= bit_array.byte_size(seg)
    && dst + count <= byte_len(a)
  {
    False -> Error(MemoryOutOfBounds)
    True -> {
      write_data_loop(a, dst, take(seg, src, count))
      Ok(a)
    }
  }
}

/// The whole in-bounds byte image (`pages * page_bytes` bytes, little-endian) — the differential
/// reference mirrored on `rt_mem.to_flat`/`o_flat` for the oracle to compare byte-for-byte.
/// Gathers the `AtomicsBacked` words word-by-word. O(byte_len); tests only.
pub fn a_flat(a: Atomics) -> BitArray {
  flat_loop(a, 0, a.pages * words_per_page, <<>>)
}

// ───────────────────────────── cell-backed wrappers (state_strategy: Cell) ─────────────────────────────

/// Build a FRESH tier-O memory (the frozen `fresh` head), returning it as the opaque `Dynamic`
/// the cell stores. Uses the default `atomics_reserve_cap_pages`; an over-cap / uncapped binding
/// is rejected at link time (§C) so this only ever builds `AtomicsBacked`.
///
/// - `min_pages`/`max_pages`/`safe_cap`: see `a_fresh`.
/// - Returns the fresh memory value as `Dynamic` (ready to hand to `rt_state.seed`).
pub fn fresh(min_pages: Int, max_pages: Option(Int), safe_cap: Int) -> Dynamic {
  atomics_to_dynamic(a_fresh(
    min_pages,
    max_pages,
    safe_cap,
    atomics_reserve_cap_pages,
  ))
}

/// Load from THIS process's cell memory (read-only; no write-back). See `a_load`.
pub fn load(
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  a_load(current_atomics(), bytes, signed, result_width, addr, offset)
}

/// Store into THIS process's cell memory. The O(1) win over paged: an `AtomicsBacked` store
/// mutates the shared `ref` IN PLACE, so the handle value is UNCHANGED and NO `rt_state.mem_put`
/// is emitted (the pdict write-back paged pays on every store is elided). Returns `Ok(Nil)` or
/// `Error(MemoryOutOfBounds)` (zero mutation). See `a_store`.
pub fn store(
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(Nil, TrapReason) {
  case a_store(current_atomics(), bytes, addr, value, offset) {
    Ok(_a) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

/// BARE-RAISING cell load (lever 2) — `load` MINUS the `Result` wrapper: returns the loaded bit
/// pattern DIRECTLY and, on an out-of-bounds access, raises the trap INTERNALLY via
/// `rt_trap.raise(MemoryOutOfBounds)`. Same bounds/decode contract as `a_load` (an UNSIGNED load
/// returns the raw `gather` directly — no decode); byte-identical trap reason and value. The seam
/// `emit_core`'s NoState path calls so a checked atomics load lowers to a single bare `call`.
///
/// - `bytes`/`signed`/`result_width`/`addr`/`offset`: see `load`.
/// - Returns the loaded value. Diverges (raises `MemoryOutOfBounds`) iff `ea < 0` or
///   `ea + bytes > byte_len`.
pub fn load_raising(
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Int {
  let a = current_atomics()
  let ea = addr + offset
  case in_bounds(a, ea, bytes) {
    False -> rt_trap.raise(MemoryOutOfBounds)
    True -> {
      let raw = gather(a, ea, bytes)
      case signed {
        True -> decode_signed(raw, bytes, result_width)
        False -> raw
      }
    }
  }
}

/// BARE-RAISING cell store (lever 2) — `store` MINUS the `Result` wrapper: scatters `value`'s low
/// `bytes` bytes into the mutable `ref` IN PLACE (no `mem_put`) and returns `Nil`, or on an
/// out-of-bounds access raises the trap INTERNALLY via `rt_trap.raise(MemoryOutOfBounds)` BEFORE any
/// byte is written (all-or-nothing — zero mutation). The bare call IS the ordered effect
/// `emit_core`'s NoState path sequences.
///
/// - `bytes`/`addr`/`value`/`offset`: see `store`.
/// - Returns `Nil` on success. Diverges (raises `MemoryOutOfBounds`, ZERO mutation) iff `ea < 0` or
///   `ea + bytes > byte_len`.
pub fn store_raising(bytes: Int, addr: Int, value: Int, offset: Int) -> Nil {
  let a = current_atomics()
  let ea = addr + offset
  case in_bounds(a, ea, bytes) {
    False -> rt_trap.raise(MemoryOutOfBounds)
    True -> scatter(a, ea, value, bytes)
  }
}

/// UNCHECKED cell load (Phase-10, N5) — `load` MINUS the bounds check/`Result`. See
/// `a_load_unchecked` (BEAM-safe on OOB).
pub fn load_unchecked(
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Int {
  a_load_unchecked(current_atomics(), bytes, signed, result_width, addr, offset)
}

/// UNCHECKED cell store (Phase-10, N5) — `store` MINUS the bounds check/`Result`. The `ref` mutates
/// in place (no `mem_put`, as with the checked `store`); returns `Nil`.
pub fn store_unchecked(bytes: Int, addr: Int, value: Int, offset: Int) -> Nil {
  let _a = a_store_unchecked(current_atomics(), bytes, addr, value, offset)
  Nil
}

/// The current size of THIS process's cell memory, in 64 KiB pages (`memory.size`).
pub fn size() -> Int {
  a_size(current_atomics())
}

/// Grow THIS process's cell memory by `delta` pages (`memory.grow`). Returns the PREVIOUS size on
/// success, or `-1` past the max / hard cap (allocating nothing, no fuel charged). On success it
/// charges `delta * page_bytes` fuel (proportional to the pages made addressable — a big grow is
/// not O(1)-cheap for the scheduler, E3) and writes the new watermark record back to the cell
/// (`grow` moves the `pages` field, so the handle value CHANGES — unlike `store`).
pub fn grow(delta: Int) -> Int {
  let #(result, updated) = a_grow(current_atomics(), delta)
  case result {
    -1 -> -1
    old -> {
      rt_meter.charge(delta * rt_mem.page_bytes)
      rt_state.mem_put(atomics_to_dynamic(updated))
      old
    }
  }
}

/// Write an active DATA segment into THIS process's cell memory at `offset`, at instantiation.
/// Bounds-checked (no-wrap), whole range up front. The `ref` is mutated in place, so — like
/// `store` — NO `mem_put`. Returns `Ok(Nil)` or `Error(MemoryOutOfBounds)` (nothing written).
pub fn init_data(offset: Int, bytes: BitArray) -> Result(Nil, TrapReason) {
  case a_init_data(current_atomics(), offset, bytes) {
    Ok(_a) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

// ── the v128-memory BitArray seam (S4) — the atomics twin of `rt_mem.load_bytes`/`store_bytes` ──
//
// `v128.load`/`store` (and the extend/zero/lane families' byte moves) route through these
// bounds-checked BitArray wrappers so the ATOMICS tier runs the SIMD-memory `.wast` files under the
// full `(state_strategy × mem_tier)` matrix (§G.1) — a mis-endianned atomics `v128.store` diverges
// on the exact file. Trap-before-write (no-wrap bignum bounds → `MemoryOutOfBounds`, ZERO mutation),
// composed from the existing `gather_bytes` (address-order read) / `write_data_loop` (address-order
// write) primitives, so the byte image is byte-identical to the paged `rt_mem` seam.

/// Pure v128-slice load: bounds-check the WHOLE `[ea, ea+n)` range, then gather `n` address-order
/// bytes into a `BitArray`. `Ok(bytes)` or `Error(MemoryOutOfBounds)`. Read-only. The atomics twin
/// of `rt_mem.mem_load_bytes`.
fn a_load_bytes(
  a: Atomics,
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  let ea = addr + offset
  case in_bounds(a, ea, n) {
    False -> Error(MemoryOutOfBounds)
    True -> Ok(gather_bytes(a, ea, n))
  }
}

/// Pure v128-slice store: bounds-check the WHOLE `[ea, ea+len)` range FIRST (trap-before-write,
/// all-or-nothing), then scatter the `bytes` in address order (the `ref` is mutated in place, so the
/// handle is unchanged — like `a_store`). `Ok(a)` or `Error(MemoryOutOfBounds)` (zero mutation).
fn a_store_bytes(
  a: Atomics,
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(Atomics, TrapReason) {
  let ea = addr + offset
  case in_bounds(a, ea, bit_array.byte_size(bytes)) {
    False -> Error(MemoryOutOfBounds)
    True -> {
      write_data_loop(a, ea, bytes)
      Ok(a)
    }
  }
}

/// `load_bytes` on THIS process's cell memory (index 0) — the atomics twin of `rt_mem.load_bytes`.
pub fn load_bytes(
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  a_load_bytes(current_atomics(), addr, offset, n)
}

/// `store_bytes` on THIS process's cell memory (index 0). In-place mutation → NO `mem_put` (like
/// `store`). `Ok(Nil)` or `Error(MemoryOutOfBounds)` (zero mutation).
pub fn store_bytes(
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(Nil, TrapReason) {
  case a_store_bytes(current_atomics(), addr, bytes, offset) {
    Ok(_a) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

/// `load_bytes` on memory `mem_idx` (read-only). Index-routed twin of `load_bytes`.
pub fn load_bytes_at(
  mem_idx: Int,
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  a_load_bytes(current_atomics_at(mem_idx), addr, offset, n)
}

/// `store_bytes` on memory `mem_idx`. In-place (no `mem_put`). Index-routed twin of `store_bytes`.
pub fn store_bytes_at(
  mem_idx: Int,
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(Nil, TrapReason) {
  case a_store_bytes(current_atomics_at(mem_idx), addr, bytes, offset) {
    Ok(_a) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

/// Threaded `load_bytes` (read-only; `st` unchanged). Projects the record's default memory.
pub fn t_load_bytes(
  st: InstanceState,
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  a_load_bytes(project(st), addr, offset, n)
}

/// Threaded `store_bytes`. In-place `ref` mutation → returns the SAME `st` (the handle value is
/// unchanged), or `Error(MemoryOutOfBounds)` (zero mutation). Mirrors `t_store`.
pub fn t_store_bytes(
  st: InstanceState,
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(InstanceState, TrapReason) {
  case a_store_bytes(project(st), addr, bytes, offset) {
    Ok(_a) -> Ok(st)
    Error(reason) -> Error(reason)
  }
}

/// Threaded `load_bytes` on memory `mem_idx` (read-only). Index-routed twin of `t_load_bytes`.
pub fn t_load_bytes_at(
  st: InstanceState,
  mem_idx: Int,
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  a_load_bytes(project_at(st, mem_idx), addr, offset, n)
}

/// Threaded `store_bytes` on memory `mem_idx`. In-place → returns the SAME `st`. Index-routed twin
/// of `t_store_bytes`.
pub fn t_store_bytes_at(
  st: InstanceState,
  mem_idx: Int,
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(InstanceState, TrapReason) {
  case a_store_bytes(project_at(st, mem_idx), addr, bytes, offset) {
    Ok(_a) -> Ok(st)
    Error(reason) -> Error(reason)
  }
}

/// Read THIS process's current `Atomics` out of the cell. Fail-closed: `rt_state.mem_get`
/// `panic`s on an un-seeded cell (it never returns garbage), which propagates here.
fn current_atomics() -> Atomics {
  dynamic_to_atomics(rt_state.mem_get())
}

// ───────────────────────────── multi-memory + bulk cell wrappers (Cell strategy, R6/R7/R9) ─────────────────────────────
//
// The index-routed cell family: each op projects memory `mem_idx` from the memories vector via
// `rt_state.mem_at` (index 0 = the default memory, so `load_at(0,…) ≡ load(…)`). Because the `ref`
// mutates IN PLACE, a mutator writes back NO `mem_put` — the handle value is unchanged — EXCEPT
// `grow_at`, which moves the `pages` watermark (the handle value changes). The bulk ops charge
// `count` fuel on the SUCCESS path (R9/§F).

/// Read memory `mem_idx`'s `Atomics` out of this process's cell. Fail-closed on an un-seeded cell /
/// out-of-range index (via `rt_state.mem_at`).
fn current_atomics_at(mem_idx: Int) -> Atomics {
  dynamic_to_atomics(rt_state.mem_at(mem_idx))
}

/// `load` from memory `mem_idx` (read-only). Index-routed twin of `load`. See `a_load`.
pub fn load_at(
  mem_idx: Int,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  a_load(current_atomics_at(mem_idx), bytes, signed, result_width, addr, offset)
}

/// `store` into memory `mem_idx`. The `ref` mutates IN PLACE (no `mem_put`); returns `Ok(Nil)` or
/// `Error(MemoryOutOfBounds)` (zero mutation). Index-routed twin of `store`. See `a_store`.
pub fn store_at(
  mem_idx: Int,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(Nil, TrapReason) {
  case a_store(current_atomics_at(mem_idx), bytes, addr, value, offset) {
    Ok(_a) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

/// BARE-RAISING `load` from memory `mem_idx` — the index-routed twin of `load_raising`. Returns the
/// loaded bit pattern directly; raises `MemoryOutOfBounds` internally on OOB. `load_at_raising(0,…)`
/// is byte-identical to `load_raising(…)`. See `load_raising`.
pub fn load_at_raising(
  mem_idx: Int,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Int {
  let a = current_atomics_at(mem_idx)
  let ea = addr + offset
  case in_bounds(a, ea, bytes) {
    False -> rt_trap.raise(MemoryOutOfBounds)
    True -> {
      let raw = gather(a, ea, bytes)
      case signed {
        True -> decode_signed(raw, bytes, result_width)
        False -> raw
      }
    }
  }
}

/// BARE-RAISING `store` into memory `mem_idx` — the index-routed twin of `store_raising`. Scatters
/// into the mutable `ref` IN PLACE (no `mem_put`) and returns `Nil`; on OOB raises
/// `MemoryOutOfBounds` internally BEFORE any write (zero mutation). `store_at_raising(0,…)` is
/// byte-identical to `store_raising(…)`. See `store_raising`.
pub fn store_at_raising(
  mem_idx: Int,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Nil {
  let a = current_atomics_at(mem_idx)
  let ea = addr + offset
  case in_bounds(a, ea, bytes) {
    False -> rt_trap.raise(MemoryOutOfBounds)
    True -> scatter(a, ea, value, bytes)
  }
}

/// `memory.size` of memory `mem_idx`. Index-routed twin of `size`.
pub fn size_at(mem_idx: Int) -> Int {
  a_size(current_atomics_at(mem_idx))
}

/// `memory.grow` memory `mem_idx` by `delta` pages. Returns the PREVIOUS size, or `-1` past the
/// cap (nothing allocated / charged). On success charges `delta * page_bytes` fuel and writes the
/// new watermark record back (the `pages` field changed). Index-routed twin of `grow`.
pub fn grow_at(mem_idx: Int, delta: Int) -> Int {
  let #(result, updated) = a_grow(current_atomics_at(mem_idx), delta)
  case result {
    -1 -> -1
    old -> {
      rt_meter.charge(delta * rt_mem.page_bytes)
      rt_state.with_mem_at(mem_idx, atomics_to_dynamic(updated))
      old
    }
  }
}

/// Write an active DATA segment into memory `mem_idx` at instantiation. The `ref` mutates in place
/// (no `mem_put`); returns `Ok(Nil)` or `Error(MemoryOutOfBounds)` (nothing written). Index-routed
/// twin of `init_data`. See `a_init_data`.
pub fn init_data_at(
  mem_idx: Int,
  offset: Int,
  bytes: BitArray,
) -> Result(Nil, TrapReason) {
  case a_init_data(current_atomics_at(mem_idx), offset, bytes) {
    Ok(_a) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

/// `memory.fill` on memory `mem_idx`. Eager bounds (R10); on success mutates in place (no
/// `mem_put`), charges `count` fuel (R9/§F), and returns `Ok(Nil)`, else `Error(MemoryOutOfBounds)`
/// with ZERO mutation and NO charge. See `a_fill`.
pub fn fill(
  mem_idx: Int,
  dest: Int,
  value: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  case a_fill(current_atomics_at(mem_idx), dest, value, count) {
    Ok(_a) -> {
      rt_meter.charge(count)
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// `memory.copy` from memory `src_mem` to `dst_mem` (memmove, R11; cross-memory when the indices
/// differ — two `ref`s projected independently). Eager bounds on BOTH ranges (R10); on success
/// mutates `dst_mem`'s `ref` in place, charges `count` fuel ONCE (R9), returns `Ok(Nil)`, else
/// `Error(MemoryOutOfBounds)` with ZERO mutation. See `a_copy`.
pub fn copy(
  dst_mem: Int,
  src_mem: Int,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  case
    a_copy(
      current_atomics_at(dst_mem),
      current_atomics_at(src_mem),
      dst,
      src,
      count,
    )
  {
    Ok(_a) -> {
      rt_meter.charge(count)
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// `memory.init` into memory `mem_idx` from segment bytes `seg` (ε if dropped, R2). Eager bounds on
/// BOTH the segment and the memory (R10) — dropped segment traps for `count > 0`, no-ops for
/// `count = 0`. On success mutates in place, charges `count` fuel (R9), returns `Ok(Nil)`, else
/// `Error(MemoryOutOfBounds)` with ZERO mutation. See `a_init`.
pub fn init(
  mem_idx: Int,
  seg: BitArray,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  case a_init(current_atomics_at(mem_idx), seg, dst, src, count) {
    Ok(_a) -> {
      rt_meter.charge(count)
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

// ───────────────────────────── threaded wrappers (state_strategy: Threaded) ─────────────────────────────

/// Threaded load (read-only): projects `st.mem`, drives `a_load`, leaves `st` UNCHANGED.
pub fn t_load(
  st: InstanceState,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  a_load(project(st), bytes, signed, result_width, addr, offset)
}

/// Threaded store. Per §A.2/§10 the mutable backend returns the SAME `st`: the `ref` is mutated
/// in place, so the `mem` `Dynamic` is unchanged (nothing to re-inject). Returns `Ok(st)` or
/// `Error(MemoryOutOfBounds)` (zero mutation).
pub fn t_store(
  st: InstanceState,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(InstanceState, TrapReason) {
  case a_store(project(st), bytes, addr, value, offset) {
    Ok(_a) -> Ok(st)
    Error(reason) -> Error(reason)
  }
}

/// UNCHECKED threaded load (Phase-10, N5) — `t_load` MINUS the bounds check/`Result`.
pub fn t_load_unchecked(
  st: InstanceState,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Int {
  a_load_unchecked(project(st), bytes, signed, result_width, addr, offset)
}

/// UNCHECKED threaded store (Phase-10, N5) — `t_store` MINUS the bounds check/`Result`. The `ref`
/// mutates in place, so the SAME `st` is returned (nothing to re-inject).
pub fn t_store_unchecked(
  st: InstanceState,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> InstanceState {
  let _a = a_store_unchecked(project(st), bytes, addr, value, offset)
  st
}

/// Threaded `memory.size` (read-only): `st` unchanged.
pub fn t_size(st: InstanceState) -> Int {
  a_size(project(st))
}

/// Threaded `memory.grow`. Returns `#(prev_pages, st')` where `st'` rebinds `st.mem` to the new
/// watermark record, or `#(-1, st)` past the cap (unchanged). Charges `delta * page_bytes` grow
/// fuel on the SUCCESS path (P2 — parity with the cell `grow`, so metered+threaded is
/// byte-identical to metered+cell, and an untrusted portable module cannot allocate to the page
/// cap with zero CPU accounting).
pub fn t_grow(st: InstanceState, delta: Int) -> #(Int, InstanceState) {
  let #(result, updated) = a_grow(project(st), delta)
  case result {
    -1 -> #(-1, st)
    old -> {
      rt_meter.charge(delta * rt_mem.page_bytes)
      #(old, rt_state.with_mem(st, atomics_to_dynamic(updated)))
    }
  }
}

/// Threaded active-data-segment write at instantiation. The `ref` is mutated in place → returns
/// the SAME `st`, or `Error(MemoryOutOfBounds)` (nothing written). See `a_init_data`.
pub fn t_init_data(
  st: InstanceState,
  offset: Int,
  bytes: BitArray,
) -> Result(InstanceState, TrapReason) {
  case a_init_data(project(st), offset, bytes) {
    Ok(_a) -> Ok(st)
    Error(reason) -> Error(reason)
  }
}

// ───────────────────────────── multi-memory + bulk threaded twins (Threaded strategy, R6/R7/R9) ─────────────────────────────
//
// The purely-functional twins: project memory `mem_idx` from the threaded record (`rt_state.
// t_mem_at`) and drive the SAME pure `a_*` core (so cell ≡ threaded, including fuel). Because the
// `ref` mutates IN PLACE, a mutator returns the SAME `st` (nothing to re-inject) — EXCEPT
// `t_grow_at`, which moves the watermark and rebinds slot `mem_idx`. `t_*_at(st, 0, …)` is
// byte-identical to the frozen `t_*` heads.

/// Project memory `mem_idx`'s `Atomics` out of the threaded record (read-only). Fail-closed `panic`
/// on an out-of-range index (via `rt_state.t_mem_at`).
fn project_at(st: InstanceState, mem_idx: Int) -> Atomics {
  dynamic_to_atomics(rt_state.t_mem_at(st, mem_idx))
}

/// Threaded `load` from memory `mem_idx` (read-only): `st` unchanged. See `a_load`.
pub fn t_load_at(
  st: InstanceState,
  mem_idx: Int,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  a_load(project_at(st, mem_idx), bytes, signed, result_width, addr, offset)
}

/// Threaded `store` into memory `mem_idx`: the `ref` mutates in place → returns the SAME `st`, or
/// `Error(MemoryOutOfBounds)` (zero mutation). See `a_store`.
pub fn t_store_at(
  st: InstanceState,
  mem_idx: Int,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(InstanceState, TrapReason) {
  case a_store(project_at(st, mem_idx), bytes, addr, value, offset) {
    Ok(_a) -> Ok(st)
    Error(reason) -> Error(reason)
  }
}

/// Threaded `memory.size` of memory `mem_idx` (read-only). See `a_size`.
pub fn t_size_at(st: InstanceState, mem_idx: Int) -> Int {
  a_size(project_at(st, mem_idx))
}

/// Threaded `memory.grow` of memory `mem_idx`. Returns `#(prev_pages, st')` (slot `mem_idx` rebound
/// to the new watermark record + `delta * page_bytes` fuel charged on success), or `#(-1, st)` past
/// the cap (unchanged, no charge). See `a_grow`.
pub fn t_grow_at(
  st: InstanceState,
  mem_idx: Int,
  delta: Int,
) -> #(Int, InstanceState) {
  let #(result, updated) = a_grow(project_at(st, mem_idx), delta)
  case result {
    -1 -> #(-1, st)
    old -> {
      rt_meter.charge(delta * rt_mem.page_bytes)
      #(old, rt_state.t_with_mem_at(st, mem_idx, atomics_to_dynamic(updated)))
    }
  }
}

/// Threaded active-data-segment write into memory `mem_idx`: the `ref` mutates in place → returns
/// the SAME `st`, or `Error(MemoryOutOfBounds)` (nothing written). See `a_init_data`.
pub fn t_init_data_at(
  st: InstanceState,
  mem_idx: Int,
  offset: Int,
  bytes: BitArray,
) -> Result(InstanceState, TrapReason) {
  case a_init_data(project_at(st, mem_idx), offset, bytes) {
    Ok(_a) -> Ok(st)
    Error(reason) -> Error(reason)
  }
}

/// Threaded `memory.fill` on memory `mem_idx`. Eager bounds (R10); on success mutates in place,
/// charges `count` fuel (R9), returns the SAME `st`, else `Error(MemoryOutOfBounds)` with ZERO
/// mutation and NO charge. See `a_fill`.
pub fn t_fill(
  st: InstanceState,
  mem_idx: Int,
  dest: Int,
  value: Int,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  case a_fill(project_at(st, mem_idx), dest, value, count) {
    Ok(_a) -> {
      rt_meter.charge(count)
      Ok(st)
    }
    Error(reason) -> Error(reason)
  }
}

/// Threaded `memory.copy` from memory `src_mem` to `dst_mem` (memmove, R11; cross-memory when the
/// indices differ). Eager bounds on BOTH ranges (R10); on success mutates `dst_mem`'s `ref` in
/// place, charges `count` fuel ONCE (R9), returns the SAME `st`, else `Error(MemoryOutOfBounds)`
/// with ZERO mutation. See `a_copy`.
pub fn t_copy(
  st: InstanceState,
  dst_mem: Int,
  src_mem: Int,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  case
    a_copy(project_at(st, dst_mem), project_at(st, src_mem), dst, src, count)
  {
    Ok(_a) -> {
      rt_meter.charge(count)
      Ok(st)
    }
    Error(reason) -> Error(reason)
  }
}

/// Threaded `memory.init` into memory `mem_idx` from segment bytes `seg` (ε if dropped, R2). Eager
/// bounds on BOTH the segment and the memory (R10); on success mutates in place, charges `count`
/// fuel (R9), returns the SAME `st`, else `Error(MemoryOutOfBounds)` with ZERO mutation. See
/// `a_init`.
pub fn t_init(
  st: InstanceState,
  mem_idx: Int,
  seg: BitArray,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  case a_init(project_at(st, mem_idx), seg, dst, src, count) {
    Ok(_a) -> {
      rt_meter.charge(count)
      Ok(st)
    }
    Error(reason) -> Error(reason)
  }
}

/// The differential hook (§B.2): the tier's whole in-bounds byte image, for the oracle to compare
/// byte-for-byte. Coerces the opaque `mem` `Dynamic` to `Atomics`, then `a_flat`.
pub fn to_flat(mem: Dynamic) -> BitArray {
  a_flat(dynamic_to_atomics(mem))
}

/// Project the opaque memory value out of the threaded record and coerce it to `Atomics` (the
/// field seam is unit 03's `rt_state.mem`). Read-only.
fn project(st: InstanceState) -> Atomics {
  dynamic_to_atomics(rt_state.mem(st))
}

// ───────────────────────────── shared helpers ─────────────────────────────

/// `2^n` as a BEAM bignum (for masks/widths up to 64 bits and sign-extension folds).
fn pow2(n: Int) -> Int {
  int.bitwise_shift_left(1, n)
}

/// The low-`b`-bits mask `(1 << b) - 1` (e.g. `mask(8) = 0xFF`, `mask(64) = 2^64-1`).
fn mask(b: Int) -> Int {
  pow2(b) - 1
}

/// The effective max in pages baked at `fresh` time: the smallest of the declared max (when
/// present), the Safe `safe_cap`, and the 65536-page hard cap. `None` drops the declared max,
/// giving `min(safe_cap, 65536)`. Re-derived here from `rt_mem`'s frozen formula; the differential
/// proves it agrees with `rt_mem`'s baked `max`. NEVER lets untrusted code allocate past
/// `safe_cap` (E3).
fn effective_max(max_pages: Option(Int), safe_cap: Int) -> Int {
  let cap = int.min(safe_cap, rt_mem.hard_max_pages)
  case max_pages {
    Some(declared) -> int.min(declared, cap)
    None -> cap
  }
}

/// The 64-bit (`Idx64`) effective max in pages: like `effective_max` but folding the 64-bit cap
/// `rt_mem.mem64_hard_max_pages` (2^32) instead of the i32 cap. Re-derived here from `rt_mem`'s
/// frozen `effective_max_for` formula; agrees with `rt_mem.fresh_mem64`'s baked `max` (the
/// differential proves it). The gate for `reservation64`/`a_fresh64` (§D).
fn effective_max64(max_pages: Option(Int), mem64_cap: Int) -> Int {
  let cap = int.min(mem64_cap, rt_mem.mem64_hard_max_pages)
  case max_pages {
    Some(declared) -> int.min(declared, cap)
    None -> cap
  }
}

/// `byte_len = pages * page_bytes`, the current (possibly-grown) length the bounds-check uses.
fn byte_len(a: Atomics) -> Int {
  a.pages * rt_mem.page_bytes
}

/// The no-wrap bounds predicate: an access of `n` bytes at effective address `ea` is in bounds
/// iff `ea >= 0` and `ea + n <= byte_len`. `ea` is a bignum and is NEVER masked to 32 bits, so
/// `addr = 0xFFFFFFFF` + a large offset correctly fails here (it does not wrap).
fn in_bounds(a: Atomics, ea: Int, n: Int) -> Bool {
  ea >= 0 && ea + n <= byte_len(a)
}

/// Decode the raw `bytes`-byte little-endian value `raw` (unsigned, in `[0, 2^{8·bytes})`) as a
/// SIGNED integer sign-extended to `result_width` bits, returning the UNSIGNED two's-complement
/// bit pattern in `[0, 2^result_width)` — for `loadN_s`. Transcribes `rt_mem`'s frozen
/// `decode_signed` (a negative fold `s + 2^result_width`) directly in integer arithmetic: iff the
/// top bit of the `bytes`-byte value is set, `raw` denotes the negative `raw - 2^{8·bytes}`, so the
/// bit pattern is `raw - 2^{8·bytes} + 2^result_width`. E.g. byte `0x80`: `i32.load8_s` →
/// `0xFFFFFF80`, `i64.load8_s` → `0xFF…FF80`.
fn decode_signed(raw: Int, bytes: Int, result_width: Int) -> Int {
  let b = bytes * 8
  case raw >= pow2(b - 1) {
    True -> raw - pow2(b) + pow2(result_width)
    False -> raw
  }
}

/// Assemble the raw `n`-byte (`n <= 8`) little-endian value at effective address `ea` from the
/// `<= 2` touched words (§A.2). `raw = Σ byte[ea+k]·256^k`, an unsigned integer in
/// `[0, 2^{8·n})`. Read-only; callers MUST have bounds-checked `ea`.
fn gather(a: Atomics, ea: Int, n: Int) -> Int {
  let w = ea / 8
  let p = ea % 8
  let ix = w + 1
  case p + n <= 8 {
    True ->
      // Single word: bytes [p, p+n) of word `w`. Shift the byte at `p` down to bit 0, keep `8n`.
      int.bitwise_and(
        int.bitwise_shift_right(atomics_get(a.ref, ix), 8 * p),
        mask(8 * n),
      )
    False -> {
      // Two words: low `(8-p)` bytes from word `w` (its top bytes), high `n-(8-p)` bytes from
      // word `w+1` (its low bytes).
      let lo_bytes = 8 - p
      let lo = int.bitwise_shift_right(atomics_get(a.ref, ix), 8 * p)
      let hi =
        int.bitwise_and(atomics_get(a.ref, ix + 1), mask(8 * { n - lo_bytes }))
      int.bitwise_or(lo, int.bitwise_shift_left(hi, 8 * lo_bytes))
    }
  }
}

/// Scatter `value`'s low `n` bytes (`n <= 8`) little-endian into the `<= 2` touched words at
/// effective address `ea` by read-modify-write (`new = (old & ~field) | (bytes << pos)`), then
/// `put` (§A.2). Process-local, so a plain `get`+`put` (no `compare_exchange`) — the array is
/// never contended. Callers MUST have bounds-checked `ea` (all-or-nothing). Mutates `ref` IN
/// PLACE; returns `Nil`.
fn scatter(a: Atomics, ea: Int, value: Int, n: Int) -> Nil {
  let w = ea / 8
  let p = ea % 8
  let ix = w + 1
  let v = int.bitwise_and(value, mask(8 * n))
  case p + n <= 8 {
    True -> {
      write_field(a, ix, p, n, v)
      Nil
    }
    False -> {
      let lo_bytes = 8 - p
      let lo_part = int.bitwise_and(v, mask(8 * lo_bytes))
      let hi_part = int.bitwise_shift_right(v, 8 * lo_bytes)
      // Word `w`: overwrite its top `lo_bytes` bytes (positions [p, 8)).
      write_field(a, ix, p, lo_bytes, lo_part)
      // Word `w+1`: overwrite its low `n-lo_bytes` bytes (positions [0, n-lo_bytes)).
      write_field(a, ix + 1, 0, n - lo_bytes, hi_part)
      Nil
    }
  }
}

/// Read-modify-write `len` bytes (`bits = len`) into word `ix` at byte position `pos`: clear the
/// field `[8·pos, 8·pos + 8·len)`, then OR in `bits` (already `<= 8·len` bits wide, positioned at
/// `pos`). `int.bitwise_not(field_mask)` is negative (infinite sign extension), but `band` with
/// the unsigned `old` (`< 2^64`) yields an unsigned result, so the stored word stays in
/// `[0, 2^64)`. Mutates `ref` IN PLACE.
fn write_field(a: Atomics, ix: Int, pos: Int, len: Int, bits: Int) -> Nil {
  let field_mask = int.bitwise_shift_left(mask(8 * len), 8 * pos)
  let old = atomics_get(a.ref, ix)
  let cleared = int.bitwise_and(old, int.bitwise_not(field_mask))
  let new = int.bitwise_or(cleared, int.bitwise_shift_left(bits, 8 * pos))
  atomics_put(a.ref, ix, new)
}

/// Write an arbitrary-length `bytes` BitArray into memory starting at `ea`, one byte per
/// single-byte `scatter`. Callers MUST have bounds-checked the whole range (`a_init_data`/
/// `a_copy`/`a_init`). O(len). Empty `bytes` is a no-op.
fn write_data_loop(a: Atomics, ea: Int, bytes: BitArray) -> Nil {
  case bytes {
    <<b:size(8), rest:bits>> -> {
      scatter(a, ea, b, 1)
      write_data_loop(a, ea + 1, rest)
    }
    _ -> Nil
  }
}

/// Scatter `count` copies of `byte` (`0..255`) starting at `ea`, one single-byte `scatter` each —
/// the `a_fill` body. Callers MUST have bounds-checked. O(count). `count <= 0` is a no-op.
fn fill_loop(a: Atomics, ea: Int, byte: Int, count: Int) -> Nil {
  case count <= 0 {
    True -> Nil
    False -> {
      scatter(a, ea, byte, 1)
      fill_loop(a, ea + 1, byte, count - 1)
    }
  }
}

/// Gather `count` bytes starting at `ea` into an immutable little-endian `BitArray` snapshot — the
/// source snapshot `a_copy` takes BEFORE writing (so overlap is memmove-correct). Reads one byte
/// per single-byte `gather`. Callers MUST have bounds-checked. O(count); `count <= 0` yields `<<>>`.
fn gather_bytes(a: Atomics, ea: Int, count: Int) -> BitArray {
  gather_loop(a, ea, count, <<>>)
}

fn gather_loop(a: Atomics, ea: Int, remaining: Int, acc: BitArray) -> BitArray {
  case remaining <= 0 {
    True -> acc
    False ->
      gather_loop(a, ea + 1, remaining - 1, <<
        acc:bits,
        { gather(a, ea, 1) }:size(8),
      >>)
  }
}

/// Slice `len` bytes from `bin` at byte offset `at` (zero-copy sub-binary) — the segment slice
/// `a_init` splices. Short-circuits `len <= 0` to `<<>>`. Callers MUST guarantee `at + len` is in
/// range (the eager bounds check does).
fn take(bin: BitArray, at: Int, len: Int) -> BitArray {
  case len <= 0 {
    True -> <<>>
    False -> {
      let assert Ok(slice) = bit_array.slice(bin, at, len)
      slice
    }
  }
}

/// Gather words `[i, total)` into a growing little-endian byte accumulator (`acc`). Each word is
/// emitted as 8 little-endian bytes, so the byte at address `8w+k` is bits `[8k, 8k+8)` of word
/// `w` — the exact LE layout. Tail-recursive so the BEAM binary-append optimisation keeps it
/// O(total).
fn flat_loop(a: Atomics, i: Int, total: Int, acc: BitArray) -> BitArray {
  case i >= total {
    True -> acc
    False ->
      flat_loop(a, i + 1, total, <<
        acc:bits,
        { atomics_get(a.ref, i + 1) }:size(64)-little,
      >>)
  }
}
