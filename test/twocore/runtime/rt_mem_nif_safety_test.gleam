//// S15-04 — the tier-N («nif») C bounds-check as a CONTAINMENT BOUNDARY (the security fuzz).
////
//// The tested TRUST BOUNDARY of Phase 15 (decision S3). tier-N is the only BEAM-memory-UNSAFE tier: a
//// checked op validates the combined effective address `ea` in C BEFORE touching the reserved buffer,
//// so a bug there is a genuine HOST ESCAPE — a read or write outside `[0, byte_len)` corrupts arbitrary
//// BEAM heap or segfaults the node. This suite is adversarial: it biases inputs to the boundary and
//// past it, at `grow` watermarks, over the memory64 overflow class, and across two distinct resources,
//// and proves — against the memory-safe paged reference + the flat-binary oracle — that every
//// out-of-bounds access (a) TRAPS `Error(MemoryOutOfBounds)` in C (never a crash, never a value), and
//// (b) NEVER lands a byte outside `[0, byte_len)` (the containment property).
////
//// It is DISTINCT from S15-02's general per-op bit-identity differential (`rt_mem_nif_test.gleam`): that
//// proves the C is byte-identical to paged over a broad random trace; THIS proves the C CONTAINS every
//// access at the boundary. It runs against the REAL NIF only, gated on `cc` via the shared
//// `nif_loader` (categorized-skip when no toolchain — never a false green, S6).
////
//// Spec anchors (objective tests against WebAssembly linear-memory semantics, D8/S7 — NOT
//// change-detectors): a memory access traps iff `ea + sizeof > length`, `ea = i + offset` with NO
//// wraparound (exec/instructions); a multi-byte store is "not performed" on a trap (all-or-nothing);
//// `memory.fill/copy/init` trap BEFORE any write if the range is out of bounds; freshly-grown pages are
//// zero-filled (memory.wast); memory64 addressing extends `ea` to a full u64.
////
//// ## How each escape shape is caught (S3)
//// - Escape into `[byte_len, max_bytes)` (past the logical end, inside the reservation, invisible to a
////   naive check): the post-`grow` ZERO-FILL probe — a stale escaped write surfaces as a non-zero read
////   of a freshly-grown page.
//// - Escape into an in-bounds neighbour (a straddling multi-byte store writing its in-bounds prefix
////   before trapping): the ALL-OR-NOTHING assertions — a seeded pattern must stand after a trapping op.
//// - Escape past `max_bytes` (heap corruption / segfault): the boundary-biased DIFFERENTIAL — the same
////   trace drives nif ≡ paged ≡ oracle with a `to_flat` byte-image equality EVERY step; a C write
////   outside the buffer crashes the test (→ red) or diverges the flat image from the memory-safe paged
////   reference (→ red).

import gleam/dynamic
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import twocore
import twocore/ir.{type TrapReason, MemoryOutOfBounds}
import twocore/runtime/instance.{type Binding, Binding, Nif}
import twocore/runtime/nif_loader.{BuildError, Loaded, SkipNoToolchain}
import twocore/runtime/profiles
import twocore/runtime/rt_mem
import twocore/runtime/rt_mem_nif as nif
import twocore/runtime/rt_meter
import twocore/runtime/rt_state.{type InstanceState, FullDecl, StateDecl}

/// One WASM page = 65536 bytes.
const page: Int = 65_536

/// A generous Safe cap so the spec-corner tests are governed by the declared max / hard cap, never the
/// cap (`100_000 > 65_536`, the i32 page ceiling).
const big_cap: Int = 100_000

/// `2^64` — the memory64 address-space ceiling. An `ea` at or above it cannot be a valid u64 offset, so
/// it is itself out of bounds (the C's `enif_get_uint64` fails → OOB, matching the paged bignum check).
const pow2_64: Int = 18_446_744_073_709_551_616

// ───────────────────────────── the cc-gated real-NIF harness (S6, shared loader) ─────────────────────────────
//
// Every native assertion funnels through the SINGLE shared `nif_loader.ensure_loaded()` (reuse-first,
// VM-global-safe — see its module doc), so this suite never fights the keystone probe's reload or the
// S15-02 differential over the shim atom. Absent a C toolchain the whole native arm is a CATEGORIZED
// SKIP (never a false green); a broken pipe (`BuildError`) is a LOUD panic.

/// Run `body` against the REAL NIF, or categorize a skip when no toolchain is present. On `Loaded` it
/// asserts `nif_loader.available()` (so the body genuinely exercises the native buffer — a silent paged
/// fallback cannot false-green the containment equalities), runs `body`, then RELEASES the body's
/// resources (clear the cell + a global GC sweep) so a later reload — a subsequent gated test, the
/// keystone probe — is not blocked by a resource this test left live (the S15-02 caveat).
fn with_native(body: fn() -> Nil) -> Nil {
  case nif_loader.ensure_loaded() {
    Loaded -> {
      nif_loader.available() |> should.be_true
      body()
      rt_state.clear()
      gc_all()
    }
    SkipNoToolchain -> Nil
    BuildError(text) -> panic as text
  }
}

/// `erlang:processes/0` — every live process (so each can be GC'd to release unreferenced resources).
@external(erlang, "erlang", "processes")
fn all_pids() -> List(dynamic.Dynamic)

/// `erlang:garbage_collect/1` — GC the given process, freeing any nif resource it no longer references.
@external(erlang, "erlang", "garbage_collect")
fn gc_pid(pid: dynamic.Dynamic) -> Bool

/// GC every live process, freeing any nif resource that has become unreferenced (so a later reload can
/// attach — see `nif_loader`).
fn gc_all() -> Nil {
  list.each(all_pids(), fn(p) {
    let _ = gc_pid(p)
    Nil
  })
}

/// `[0, 1, …, n-1]` — a small ascending index list (this stdlib has no `list.range`).
fn seq(n: Int) -> List(Int) {
  seq_loop(n - 1, [])
}

/// Tail-recursive accumulator for `seq`: prepends `i, i-1, …, 0` onto `acc`.
fn seq_loop(i: Int, acc: List(Int)) -> List(Int) {
  case i < 0 {
    True -> acc
    False -> seq_loop(i - 1, [i, ..acc])
  }
}

// ───────────────────────────── state builders ─────────────────────────────

/// A threaded `InstanceState` whose `mem` slot holds a fresh tier-N memory of `min`/`max` pages.
fn threaded_nif(min: Int, max: option.Option(Int)) -> InstanceState {
  rt_state.fresh(StateDecl(
    mem: nif.fresh(min, max, big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
}

/// The paged reference twin of `threaded_nif` (same declared min/max), for the differential.
fn threaded_paged(min: Int, max: option.Option(Int)) -> InstanceState {
  rt_state.fresh(StateDecl(
    mem: rt_mem.fresh(min, max, big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
}

/// A threaded `InstanceState` with TWO independent tier-N memories (indices 0 and 1) for the
/// cross-resource `copy` test (both handles must be validated before the `memmove`).
fn two_mem_nif(
  min0: Int,
  max0: option.Option(Int),
  min1: Int,
  max1: option.Option(Int),
) -> InstanceState {
  rt_state.fresh_full(
    FullDecl(
      mems: [nif.fresh(min0, max0, big_cap), nif.fresh(min1, max1, big_cap)],
      globals: [],
      tables: [],
      ref_globals: [],
    ),
  )
}

/// The paged twin of `two_mem_nif`.
fn two_mem_paged(
  min0: Int,
  max0: option.Option(Int),
  min1: Int,
  max1: option.Option(Int),
) -> InstanceState {
  rt_state.fresh_full(
    FullDecl(
      mems: [
        rt_mem.fresh(min0, max0, big_cap),
        rt_mem.fresh(min1, max1, big_cap),
      ],
      globals: [],
      tables: [],
      ref_globals: [],
    ),
  )
}

/// A threaded `InstanceState` holding a TINY BOUNDED 64-bit (`fresh64`, memory64) tier-N memory — the
/// only memory64 shape admissible under tier-N (it RESERVES). The i64 addresses this exercises are far
/// past `byte_len`, so the constructor's bounded reservation is never actually addressed.
fn threaded_nif64(min: Int, max: option.Option(Int)) -> InstanceState {
  rt_state.fresh(StateDecl(
    mem: nif.fresh64(min, max, rt_mem.mem64_hard_max_pages),
    globals: [],
    table: dynamic.nil(),
  ))
}

/// The paged twin of `threaded_nif64`.
fn threaded_paged64(min: Int, max: option.Option(Int)) -> InstanceState {
  rt_state.fresh(StateDecl(
    mem: rt_mem.fresh64(min, max, rt_mem.mem64_hard_max_pages),
    globals: [],
    table: dynamic.nil(),
  ))
}

// ═══════════════════════════ 1. Off-by-one containment, every width, at grow watermarks ═══════════════════════════
//
// (Test §5.1.) A load/store ENDING EXACTLY at `byte_len` is in bounds (reads 0); `byte_len - n + 1`
// straddles by one and TRAPS; `byte_len` traps. Repeat at each `grow` watermark: after `grow` the OLD
// `byte_len` is now in bounds (reads 0), the NEW `byte_len` boundary traps. Cite exec/instructions
// bounds; memory_size.wast. Both the THREADED and CELL families.

/// The exact-boundary probe for one access width `n` over a threaded state at page-count `pages`: an
/// access ending at `byte_len` is `Ok(0)`; one byte past (`byte_len - n + 1` .. `byte_len`) traps.
fn boundary_probe_threaded(
  st: InstanceState,
  pages: Int,
  n: Int,
  width: Int,
) -> Nil {
  let byte_len = pages * page
  // Ends exactly at byte_len → in bounds, reads 0.
  nif.t_load(st, n, False, width, byte_len - n, 0) |> should.equal(Ok(0))
  // Straddles by one → traps.
  nif.t_load(st, n, False, width, byte_len - n + 1, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  // Starts exactly at byte_len → traps (for n >= 1).
  nif.t_load(st, n, False, width, byte_len, 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

/// Threaded family: the exact boundary is in bounds, one byte past traps, at every width and at each
/// `grow` watermark (the old boundary opens up, the new one traps).
pub fn off_by_one_every_width_threaded_test() {
  with_native(fn() {
    let st = threaded_nif(1, Some(3))
    boundary_probe_threaded(st, 1, 1, 32)
    boundary_probe_threaded(st, 1, 2, 32)
    boundary_probe_threaded(st, 1, 4, 32)
    boundary_probe_threaded(st, 1, 8, 64)
    // Grow to 2 pages: the OLD boundary (page) is now in bounds (reads 0); re-probe at the NEW boundary.
    let #(old, st) = nif.t_grow(st, 1)
    old |> should.equal(1)
    nif.t_load(st, 8, False, 64, page, 0) |> should.equal(Ok(0))
    nif.t_load(st, 8, False, 64, page - 8, 0) |> should.equal(Ok(0))
    boundary_probe_threaded(st, 2, 1, 32)
    boundary_probe_threaded(st, 2, 4, 32)
    boundary_probe_threaded(st, 2, 8, 64)
    // Grow again to 3; the boundary tracks the new watermark.
    let #(old2, st) = nif.t_grow(st, 1)
    old2 |> should.equal(2)
    boundary_probe_threaded(st, 3, 8, 64)
  })
}

/// Cell family (pdict-backed): a store at the last aligned slot succeeds, a straddling store traps, and
/// after `grow` the old boundary opens up and reads zero — the same boundary proof under the cell ABI.
pub fn off_by_one_every_width_cell_test() {
  with_native(fn() {
    rt_state.seed(StateDecl(
      mem: nif.fresh(1, Some(2), big_cap),
      globals: [],
      table: dynamic.nil(),
    ))
    // Store at the last aligned slot succeeds; a straddling store traps.
    nif.store(4, page - 4, 0xDEADBEEF, 0) |> should.equal(Ok(Nil))
    nif.load(4, False, 32, page - 4, 0) |> should.equal(Ok(0xDEADBEEF))
    nif.store(4, page - 2, 0x11223344, 0)
    |> should.equal(Error(MemoryOutOfBounds))
    nif.load(1, False, 32, page, 0) |> should.equal(Error(MemoryOutOfBounds))
    // Grow: the old boundary opens up, reads zero.
    nif.grow(1) |> should.equal(1)
    nif.load(4, False, 32, page, 0) |> should.equal(Ok(0))
    nif.load(8, False, 64, 2 * page - 8, 0) |> should.equal(Ok(0))
    nif.load(8, False, 64, 2 * page - 7, 0)
    |> should.equal(Error(MemoryOutOfBounds))
  })
}

// ═══════════════════════════ 2. No-wrap ea + the memory64 boundary (MF2 — the overflow-safe proof) ═══════════════════════════
//
// (Test §5.2.) `ea = addr + offset` is a no-wrap bignum: `addr = 0xFFFFFFFF` with a large offset must
// TRAP, never wrap to a small in-bounds ea. AND, over a `fresh64`-backed resource, 64-bit addresses in
// `[2^64 - 32, 2^64 - 1]` with assorted offsets trap nif == paged, trap-for-trap — the vectors that
// expose an overflow-WRAPPING C check as an OOB `memcpy` HOST ESCAPE (a wrapping `ea + n` computes a
// small in-bounds value and passes). The i32-range trace cannot reach them; the guarded-subtraction
// bounds (`ea > byte_len || n > byte_len - ea`) defeat them. THE "Security boundary" acceptance row is
// not proven without these. Cite address.wast / exec/instructions no-wraparound + memory64 addressing.

/// i32-range no-wrap: `addr = 0xFFFFFFFF` + a large offset traps (a bignum `ea`, never masked mod 2^32),
/// and the byte a wrap bug would have hit (ea = 99) is proven untouched.
pub fn no_wrap_ea_i32_test() {
  with_native(fn() {
    let st = threaded_nif(1, Some(2))
    // addr = 0xFFFFFFFF + a large offset: ea is a bignum far past byte_len → traps, never wraps to 99.
    nif.t_load(st, 4, False, 32, 0xFFFFFFFF, 100)
    |> should.equal(Error(MemoryOutOfBounds))
    nif.t_store(st, 4, 0xFFFFFFFF, 0xDEADBEEF, 100)
    |> should.equal(Error(MemoryOutOfBounds))
    // A wrap bug would have computed ea = 99 (in bounds). Prove byte 99 is untouched (still 0).
    nif.t_load(st, 4, False, 32, 99, 0) |> should.equal(Ok(0))
  })
}

/// The memory64 overflow vectors: over a bounded `fresh64` resource, every i64 address in
/// `[2^64-32, 2^64-1]` with assorted offsets (so the combined `ea` lands at, just below, and PAST
/// `2^64`) traps nif == paged, trap-for-trap. All are far past `byte_len`, so every one is
/// `Error(MemoryOutOfBounds)` on BOTH backends; the equality proves the C's guarded subtraction does
/// not wrap where a naive `ea + n` would.
pub fn memory64_boundary_overflow_test() {
  with_native(fn() {
    let sn = threaded_nif64(1, Some(3))
    let sp = threaded_paged64(1, Some(3))
    // Seed a known byte low in both so a straddling store's would-be corruption is observable.
    let assert Ok(sn) = nif.t_store(sn, 8, 0, 0x0102030405060708, 0)
    let assert Ok(sp) = rt_mem.t_store(sp, 8, 0, 0x0102030405060708, 0)
    let before = nif.to_flat(rt_state.mem(sn))
    // The addresses at/near the u64 ceiling, and the offsets that push ea across it.
    let addrs = [
      pow2_64 - 32,
      pow2_64 - 16,
      pow2_64 - 8,
      pow2_64 - 1,
    ]
    let offsets = [0, 1, 8, 16, 31, 32, 64]
    list.each(addrs, fn(a) {
      list.each(offsets, fn(off) {
        list.each([1, 2, 4, 8], fn(n) {
          let w = case n {
            8 -> 64
            _ -> 32
          }
          // Load: nif == paged, and both MUST be OOB (never a wrapped in-bounds value).
          let rn = nif.t_load(sn, n, False, w, a, off)
          rn |> should.equal(rt_mem.t_load(sp, n, False, w, a, off))
          rn |> should.equal(Error(MemoryOutOfBounds))
          // Store: nif == paged, both OOB, and nothing is written on either.
          nif.t_store(sn, n, a, 0xFF, off)
          |> should.equal(rt_mem.t_store(sp, n, a, 0xFF, off))
          nif.t_store(sn, n, a, 0xFF, off)
          |> should.equal(Error(MemoryOutOfBounds))
        })
      })
    })
    // No memory64 store escaped: the flat image (incl. the seeded low bytes) is unchanged.
    nif.to_flat(rt_state.mem(sn)) |> should.equal(before)
  })
}

// ═══════════════════════════ 3. All-or-nothing on the boundary (the write-escape proof) ═══════════════════════════
//
// (Test §5.3.) A straddling `store` / `init_data` / `fill` / same-memory `copy` / `init` / `store_bytes`
// traps BEFORE any byte is written — the seeded in-bounds bytes STAND. Cite exec/instructions (the store
// is "not performed" on trap) + the bulk-op trap conditions.

/// A scalar store straddling `byte_len` traps BEFORE any byte (not even its in-bounds prefix) is written
/// — the seeded pattern stands and the flat image is unchanged (trap-before-write).
pub fn all_or_nothing_scalar_store_test() {
  with_native(fn() {
    let st = threaded_nif(1, Some(1))
    let assert Ok(st) = nif.t_store(st, 4, page - 4, 0xAABBCCDD, 0)
    let before = nif.to_flat(rt_state.mem(st))
    // A store straddling byte_len by two bytes traps and writes NOTHING (not even its in-bounds prefix).
    nif.t_store(st, 4, page - 2, 0x11223344, 0)
    |> should.equal(Error(MemoryOutOfBounds))
    nif.to_flat(rt_state.mem(st)) |> should.equal(before)
    nif.t_load(st, 4, False, 32, page - 4, 0) |> should.equal(Ok(0xAABBCCDD))
    nif.t_load(st, 1, False, 32, page - 1, 0) |> should.equal(Ok(0xAA))
  })
}

/// Every BULK + SIMD-seam mutator (`init_data`/`fill`/`copy`/`init`/`store_bytes`/`load_bytes`, plus a
/// dropped-segment `init`) straddling `byte_len` traps with ZERO mutation — a seeded pattern stands.
pub fn all_or_nothing_bulk_and_simd_test() {
  with_native(fn() {
    rt_state.seed(StateDecl(
      mem: nif.fresh(1, Some(1), big_cap),
      globals: [],
      table: dynamic.nil(),
    ))
    // Seed a known pattern near the boundary.
    let assert Ok(Nil) =
      nif.store_bytes(page - 4, <<0xA1, 0xA2, 0xA3, 0xA4>>, 0)
    let before = nif.to_flat(rt_state.mem_get())
    // Each straddling mutator traps BEFORE any write; the seeded pattern must stand after each.
    nif.init_data(page - 2, <<1, 2, 3, 4>>)
    |> should.equal(Error(MemoryOutOfBounds))
    nif.fill(0, page - 2, 0xFF, 4) |> should.equal(Error(MemoryOutOfBounds))
    nif.copy(0, 0, page - 2, 0, 4) |> should.equal(Error(MemoryOutOfBounds))
    nif.init(0, <<1, 2, 3, 4>>, page - 2, 0, 4)
    |> should.equal(Error(MemoryOutOfBounds))
    nif.store_bytes(page - 2, <<1, 2, 3, 4>>, 0)
    |> should.equal(Error(MemoryOutOfBounds))
    nif.load_bytes(page - 2, 0, 4) |> should.equal(Error(MemoryOutOfBounds))
    // A dropped/ε segment `init` with count > 0 traps (segment bounds), writing nothing.
    nif.init(0, <<>>, 0, 0, 1) |> should.equal(Error(MemoryOutOfBounds))
    // NONE of the trapping ops mutated the buffer.
    nif.to_flat(rt_state.mem_get()) |> should.equal(before)
  })
}

/// The S15-03 native `init_data` OOB fix, driven DIRECTLY (nif ≡ paged, trap-for-trap). Spec:
/// exec/modules — an active-data segment whose `offset + len` exceeds the memory length traps "out of
/// bounds memory access"; exec/instructions — the write "is not performed" on a trap.
///
/// The bug: an IMPORTED memory is built with the PAGED tier UNCONDITIONALLY (`link.spectest_export`), so
/// under a LOADED `.so` the `mem` slot can hold a paged `Mem` (a tuple) even though `nif_available()` is
/// `true`. Handing that FOREIGN handle to the C `enif_get_resource` fails with `badarg`, NOT the WASM
/// trap — exactly `data.wast` lines 274/305/320 (imported spectest memory, offsets `0x1_0000` / `-1`).
/// The fix routes a paged handle to `rt_mem`, so the native heads return a bit-identical
/// `Error(MemoryOutOfBounds)`. This drives that exact shape: a PAGED memory in the slot while the native
/// `.so` is attached (an ESCAPE here — a `badarg` instead of the trap — is the S15-03 bug re-surfacing).
pub fn native_init_data_oob_on_imported_paged_memory_test() {
  with_native(fn() {
    // The native `.so` IS attached (with_native asserted `nif_available`), yet these mem slots hold PAGED
    // memories — precisely the imported-spectest-memory shape under the `Nif` tier.
    nif_loader.available() |> should.be_true
    let sn =
      rt_state.fresh(StateDecl(
        mem: rt_mem.fresh(1, Some(1), big_cap),
        globals: [],
        table: dynamic.nil(),
      ))
    let sp =
      rt_state.fresh(StateDecl(
        mem: rt_mem.fresh(1, Some(1), big_cap),
        globals: [],
        table: dynamic.nil(),
      ))
    // OOB active-data segment — the `0x1_0000` (== byte_len) and `-1`(== 0xFFFFFFFF) data.wast shapes.
    // nif (delegating the paged handle) == paged, both `Error(MemoryOutOfBounds)`, NEVER a `badarg`.
    nif.t_init_data(sn, page, <<"a">>)
    |> should.equal(rt_mem.t_init_data(sp, page, <<"a">>))
    nif.t_init_data(sn, page, <<"a">>)
    |> should.equal(Error(MemoryOutOfBounds))
    nif.t_init_data(sn, 0xFFFFFFFF, <<"a">>)
    |> should.equal(Error(MemoryOutOfBounds))
    // In-bounds delegates correctly (writes into the paged memory) — nif == paged, byte-for-byte.
    let assert Ok(sn) = nif.t_init_data(sn, 10, <<0xDE, 0xAD>>)
    let assert Ok(sp) = rt_mem.t_init_data(sp, 10, <<0xDE, 0xAD>>)
    nif.to_flat(rt_state.mem(sn))
    |> should.equal(rt_mem.to_flat(rt_state.mem(sp)))
    // The CELL head too (the memory-0 data-segment path `emit_core` actually calls at instantiation).
    rt_state.seed(StateDecl(
      mem: rt_mem.fresh(1, Some(1), big_cap),
      globals: [],
      table: dynamic.nil(),
    ))
    nif.init_data(page, <<"a">>) |> should.equal(Error(MemoryOutOfBounds))
    nif.init_data(10, <<0xDE, 0xAD>>) |> should.equal(Ok(Nil))
    // Read the in-bounds write back through the PAGED head — a scalar `load` is deliberately NOT
    // handle-aware (the segment/bulk writers are the ops that receive an imported handle in the vendored
    // suite; a `load`/`store` on imported spectest memory is a named out-of-scope gap — no vendored
    // fixture counts one), so an imported memory's scalar reads stay on the paged core.
    rt_mem.load(2, False, 32, 10, 0) |> should.equal(Ok(0xADDE))
  })
}

/// Cross-resource `copy` (lesser-c): with `DstRes != SrcRes`, a straddle of EITHER buffer's `byte_len`
/// traps — proving `nif_copy` validates BOTH handles (`enif_get_resource`) AND BOTH ranges before the
/// `memmove`. A one-handle-only check would corrupt or read the OTHER memory. Held byte-identical to the
/// paged two-memory reference; nothing is mutated on a trap.
pub fn cross_resource_copy_both_handles_checked_test() {
  with_native(fn() {
    let sn = two_mem_nif(1, Some(1), 1, Some(1))
    let sp = two_mem_paged(1, Some(1), 1, Some(1))
    // Seed BOTH memories identically (a distinct pattern in each).
    let assert Ok(sn) = nif.t_init_data_at(sn, 0, 0, <<0x10, 0x11, 0x12, 0x13>>)
    let assert Ok(sn) = nif.t_init_data_at(sn, 1, 0, <<0x20, 0x21, 0x22, 0x23>>)
    let assert Ok(sp) =
      rt_mem.t_init_data_at(sp, 0, 0, <<0x10, 0x11, 0x12, 0x13>>)
    let assert Ok(sp) =
      rt_mem.t_init_data_at(sp, 1, 0, <<0x20, 0x21, 0x22, 0x23>>)
    // (a) An in-bounds cross-resource copy (mem 1 → mem 0) matches the paged reference on both memories.
    let assert Ok(sn) = nif.t_copy(sn, 0, 1, 8, 0, 4)
    let assert Ok(sp) = rt_mem.t_copy(sp, 0, 1, 8, 0, 4)
    nif.to_flat(rt_state.t_mem_at(sn, 0))
    |> should.equal(rt_mem.to_flat(rt_state.t_mem_at(sp, 0)))
    nif.to_flat(rt_state.t_mem_at(sn, 1))
    |> should.equal(rt_mem.to_flat(rt_state.t_mem_at(sp, 1)))
    let base0 = nif.to_flat(rt_state.t_mem_at(sn, 0))
    // (b) SRC straddles src's byte_len (dst fine): must trap → proves the SRC handle+range is checked.
    nif.t_copy(sn, 0, 1, 0, page - 2, 4)
    |> should.equal(Error(MemoryOutOfBounds))
    nif.to_flat(rt_state.t_mem_at(sn, 0)) |> should.equal(base0)
    // (c) DST straddles dst's byte_len (src fine): must trap → proves the DST handle+range is checked.
    nif.t_copy(sn, 0, 1, page - 2, 0, 4)
    |> should.equal(Error(MemoryOutOfBounds))
    nif.to_flat(rt_state.t_mem_at(sn, 0)) |> should.equal(base0)
    // Memory 1 (the source) is untouched by the traps.
    nif.to_flat(rt_state.t_mem_at(sn, 1))
    |> should.equal(rt_mem.to_flat(rt_state.t_mem_at(sp, 1)))
  })
}

// ═══════════════════════════ 4. Post-grow zero-fill escape probe ═══════════════════════════
//
// (Test §5.4.) After trapping stores near `byte_len`, `grow`, then EVERY newly-addressable byte reads
// `0`. A stale escaped write that a bounds bug let slip into the reserved-but-not-yet-logical region
// `[byte_len, max_bytes)` — invisible to the pre-grow `to_flat` — surfaces HERE as a non-zero read.
// Cite memory.wast zero-fill.
pub fn post_grow_zero_fill_escape_probe_test() {
  with_native(fn() {
    let st = threaded_nif(1, Some(4))
    // Hammer the boundary with 8-byte stores that STRADDLE byte_len (start at page-k for k in 1..7, or
    // exactly AT page) — each traps and a broken check might spill it into the reserved tail. (page-8
    // would END exactly at byte_len and is IN bounds, so it is deliberately excluded.)
    list.each([0, 1, 2, 3, 4, 5, 6, 7], fn(k) {
      nif.t_store(st, 8, page - k, 0xFFFFFFFFFFFFFFFF, 0)
      |> should.equal(Error(MemoryOutOfBounds))
    })
    // Grow two pages; the newly-addressable region must read 0 everywhere (no escaped write lurking).
    let #(old, st) = nif.t_grow(st, 2)
    old |> should.equal(1)
    // Dense at the seam (where a straddling store would escape into the reserved tail), then a strided
    // sample across both new pages, then the very last word.
    seq(32)
    |> list.each(fn(i) {
      nif.t_load(st, 8, False, 64, page + i * 8, 0) |> should.equal(Ok(0))
    })
    [512, 1024, 4096, page - 8, page, page + 4096, 2 * page - 16, 2 * page - 8]
    |> list.each(fn(off) {
      nif.t_load(st, 8, False, 64, page + off, 0) |> should.equal(Ok(0))
    })
    // And the newly-addressable region is writable + reads back exactly (not corrupt).
    let assert Ok(st) = nif.t_store(st, 4, page, 0xCAFEBABE, 0)
    nif.t_load(st, 4, False, 32, page, 0) |> should.equal(Ok(0xCAFEBABE))
  })
}

// ═══════════════════════════ 5. The boundary-biased differential (the containment oracle) ═══════════════════════════
//
// (Test §5.5.) A deterministic-seed randomized trace, HEAVILY weighting addresses in
// `[byte_len - 16, byte_len + 16]` + occasional `0xFFFFFFFF` + `grow`s that move the watermark, drives
// nif ≡ paged ≡ oracle with a `to_flat` byte-image equality EVERY step. This is S3's "no read/write
// lands outside `[0, byte_len)`" proof against the memory-SAFE reference: a C bounds bug either crashes
// the test process (→ red) or diverges the flat image (→ red). Multiple seeds. Cite exec/instructions
// memory.

type Op {
  OpLoad(bytes: Int, signed: Bool, width: Int, addr: Int, offset: Int)
  OpStore(bytes: Int, addr: Int, value: Int, offset: Int)
  OpGrow(delta: Int)
  OpInit(offset: Int, bytes: BitArray)
}

type OpResult {
  RLoad(Result(Int, TrapReason))
  RStore(Result(Nil, TrapReason))
  RGrow(Int)
  RInit(Result(Nil, TrapReason))
}

/// `erlang:band/2` — bitwise AND (used to mask the LCG state to 31 bits).
@external(erlang, "erlang", "band")
fn int_band(a: Int, b: Int) -> Int

/// `erlang:bor/2` — bitwise OR (used to assemble a wide pseudo-random value).
@external(erlang, "erlang", "bor")
fn int_bor(a: Int, b: Int) -> Int

/// `erlang:bsl/2` — arithmetic left shift (used to assemble a wide pseudo-random value).
@external(erlang, "erlang", "bsl")
fn int_bsl(a: Int, b: Int) -> Int

/// A 31-bit linear-congruential PRNG (deterministic so a failing seed reproduces exactly).
fn lcg(state: Int) -> Int {
  int_band(state * 1_103_515_245 + 12_345, 0x7FFFFFFF)
}

/// Drive the tier-N handle (threaded), the paged handle (threaded), and the flat-binary oracle through
/// the SAME `count` BOUNDARY-BIASED ops; assert identical value+trap at every step AND an identical flat
/// byte image after every step (the strongest containment check — a C escape crashes or diverges here).
fn run_boundary_differential(count: Int, seed: Int) -> Nil {
  rt_meter.reset_fuel()
  let sn = threaded_nif(1, Some(2))
  let sp = threaded_paged(1, Some(2))
  let o = rt_mem.o_fresh(1, Some(2), big_cap)
  diff_loop(sn, sp, o, seed, count)
}

/// One step of the boundary differential: generate a boundary-biased op, apply it to the nif, paged, and
/// oracle backends, assert all three agree on value+trap AND on the whole flat byte image, then recurse.
fn diff_loop(
  sn: InstanceState,
  sp: InstanceState,
  o: rt_mem.OMem,
  seed: Int,
  remaining: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let #(op, seed) = gen_boundary_op(nif.t_size(sn) * page, seed)
      let #(sn, rn) = apply_nif(sn, op)
      let #(sp, rp) = apply_paged(sp, op)
      let #(o, ro) = apply_oracle(o, op)
      // Value AND trap agree, every step.
      rn |> should.equal(rp)
      rn |> should.equal(ro)
      // The whole in-bounds byte image is byte-identical, every step (a C escape diverges it).
      let image = nif.to_flat(rt_state.mem(sn))
      image |> should.equal(rt_mem.to_flat(rt_state.mem(sp)))
      image |> should.equal(rt_mem.o_flat(o))
      diff_loop(sn, sp, o, seed, remaining - 1)
    }
  }
}

/// Apply one `Op` to the tier-N (native, own resource) backend, returning the rebound state + result.
fn apply_nif(st: InstanceState, op: Op) -> #(InstanceState, OpResult) {
  case op {
    OpLoad(b, s, w, ad, off) -> #(st, RLoad(nif.t_load(st, b, s, w, ad, off)))
    OpStore(b, ad, v, off) ->
      case nif.t_store(st, b, ad, v, off) {
        Ok(st2) -> #(st2, RStore(Ok(Nil)))
        Error(e) -> #(st, RStore(Error(e)))
      }
    OpGrow(d) -> {
      let #(r, st2) = nif.t_grow(st, d)
      #(st2, RGrow(r))
    }
    OpInit(off, bytes) ->
      case nif.t_init_data(st, off, bytes) {
        Ok(st2) -> #(st2, RInit(Ok(Nil)))
        Error(e) -> #(st, RInit(Error(e)))
      }
  }
}

/// Apply one `Op` to the memory-safe PAGED reference backend (the containment oracle).
fn apply_paged(st: InstanceState, op: Op) -> #(InstanceState, OpResult) {
  case op {
    OpLoad(b, s, w, ad, off) -> #(
      st,
      RLoad(rt_mem.t_load(st, b, s, w, ad, off)),
    )
    OpStore(b, ad, v, off) ->
      case rt_mem.t_store(st, b, ad, v, off) {
        Ok(st2) -> #(st2, RStore(Ok(Nil)))
        Error(e) -> #(st, RStore(Error(e)))
      }
    OpGrow(d) -> {
      let #(r, st2) = rt_mem.t_grow(st, d)
      #(st2, RGrow(r))
    }
    OpInit(off, bytes) ->
      case rt_mem.t_init_data(st, off, bytes) {
        Ok(st2) -> #(st2, RInit(Ok(Nil)))
        Error(e) -> #(st, RInit(Error(e)))
      }
  }
}

/// Apply one `Op` to the flat-binary spec ORACLE (a rebuild-from-bytes reference), returning it + result.
fn apply_oracle(o: rt_mem.OMem, op: Op) -> #(rt_mem.OMem, OpResult) {
  case op {
    OpLoad(b, s, w, ad, off) -> #(o, RLoad(rt_mem.o_load(o, b, s, w, ad, off)))
    OpStore(b, ad, v, off) ->
      case rt_mem.o_store(o, b, ad, v, off) {
        Ok(o2) -> #(o2, RStore(Ok(Nil)))
        Error(e) -> #(o, RStore(Error(e)))
      }
    OpGrow(d) -> {
      let #(r, o2) = rt_mem.o_grow(o, d)
      #(o2, RGrow(r))
    }
    OpInit(off, bytes) ->
      case rt_mem.o_init_data(o, off, bytes) {
        Ok(o2) -> #(o2, RInit(Ok(Nil)))
        Error(e) -> #(o, RInit(Error(e)))
      }
  }
}

/// Generate a BOUNDARY-BIASED op given the current `byte_len`. Unlike the S15-02 broad trace, this
/// weights addresses tightly around `byte_len` (`[byte_len - 16, byte_len + 16]`) with occasional
/// `0xFFFFFFFF` (the no-wrap probe) and `grow`s that move the watermark — so the C bounds check is
/// exercised right AT the seam where an off-by-one escapes.
fn gen_boundary_op(byte_len: Int, seed: Int) -> #(Op, Int) {
  let s = lcg(seed)
  case s % 10 {
    k if k < 4 -> {
      let s2 = lcg(s)
      let bytes = pick_bytes(s2 % 4)
      let #(addr, s3) = boundary_addr(s2, byte_len)
      let s4 = lcg(s3)
      #(OpStore(bytes, addr, pick_value(s4), s4 % 8), s4)
    }
    k if k < 8 -> {
      let s2 = lcg(s)
      let bytes = pick_bytes(s2 % 4)
      let width = case bytes {
        8 -> 64
        _ -> 32
      }
      let #(addr, s3) = boundary_addr(s2, byte_len)
      let signed = s3 % 2 == 0
      #(OpLoad(bytes, signed, width, addr, s3 % 8), s3)
    }
    8 -> {
      let s2 = lcg(s)
      #(OpGrow(s2 % 2), s2)
    }
    _ -> {
      let s2 = lcg(s)
      let len = s2 % 6
      let #(addr, s3) = boundary_addr(s2, byte_len)
      let #(bytes, s4) = rand_bytes(len, s3)
      #(OpInit(addr, bytes), s4)
    }
  }
}

/// Map a 0-3 selector to an access width in bytes (1/2/4/8).
fn pick_bytes(i: Int) -> Int {
  case i {
    0 -> 1
    1 -> 2
    2 -> 4
    _ -> 8
  }
}

/// Heavily bias to `[byte_len - 16, byte_len + 16]` (the seam), occasionally `0xFFFFFFFF` (the no-wrap
/// probe), rarely a random in-bounds address (to keep the buffer non-trivially populated).
fn boundary_addr(seed: Int, byte_len: Int) -> #(Int, Int) {
  let s = lcg(seed)
  case s % 20 {
    0 -> #(0xFFFFFFFF, s)
    r if r < 15 -> {
      // Within +-16 of the boundary (clamped at 0), so many accesses straddle byte_len.
      let base = case byte_len - 16 {
        b if b < 0 -> 0
        b -> b
      }
      #(base + s % 32, s)
    }
    _ -> {
      let span = case byte_len {
        0 -> 1
        b -> b
      }
      #(s % span, s)
    }
  }
}

/// A pseudo-random ~64-bit value (high byte reachable so 8-byte stores vary fully).
fn pick_value(seed: Int) -> Int {
  let a = lcg(seed)
  let b = lcg(a)
  int_bor(int_bsl(a, 33), b)
}

/// A deterministic `n`-byte BitArray for init segments.
fn rand_bytes(n: Int, seed: Int) -> #(BitArray, Int) {
  case n <= 0 {
    True -> #(<<>>, seed)
    False -> {
      let s = lcg(seed)
      let #(rest, s2) = rand_bytes(n - 1, s)
      #(<<{ s % 256 }, rest:bits>>, s2)
    }
  }
}

/// The boundary-biased containment differential, seed A (300 ops).
pub fn boundary_differential_seed_a_test() {
  with_native(fn() { run_boundary_differential(300, 0x5EED) })
}

/// The boundary-biased containment differential, seed B (300 ops) — a distinct trace.
pub fn boundary_differential_seed_b_test() {
  with_native(fn() { run_boundary_differential(300, 0xBADC0DE) })
}

/// The boundary-biased containment differential, seed C (400 ops) — a third distinct trace.
pub fn boundary_differential_seed_c_test() {
  with_native(fn() { run_boundary_differential(400, 0x1DEA5) })
}

// ═══════════════════════════ 6. The four Safe-forbidden gates + the L1 exclusion (S5, read-only) ═══════════════════════════
//
// (Test §5.6.) This phase adds capability, NOT posture: `Safe + nif` and `--link + nif` remain
// IMPOSSIBLE. These are pure `profiles`/`twocore` reads (no NIF, no ownership conflict), so the security
// suite is self-proving. Cite G6/O8. The Phase-11 L1 `--link` 8-way matrix (which must NOT gain a `Nif`
// row) is verified by the whole suite staying green (this unit does not touch that file) — an accidental
// widening turns it red.

/// Gate 1 — `validate_binding`: a hand-composed `Safe + Nif` binding is `Error(SafeForbidsNif)`. The
/// mem_module is coerced to the `Nif` module so the ONLY reason to reject is the Safe+Nif policy clash
/// (not a `TierModuleMismatch`), pinning gate 1 precisely.
pub fn gate_validate_binding_safe_forbids_nif_test() {
  let safe_nif =
    profiles.resolve_tiers(Binding(..profiles.safe(), mem_tier: Nif))
  profiles.validate_binding(safe_nif)
  |> should.equal(Error(profiles.SafeForbidsNif))
}

/// Gates 2 + 3 — type-unconstructibility: EVERY Safe profile constructor names `Paged`, so `Safe + Nif`
/// is unconstructible through the profile API (which is why the `instantiate` node-safe panic arm,
/// gate 2, is unreachable and asserted structurally here rather than driven to panic).
pub fn gate_safe_profiles_never_name_nif_test() {
  [
    profiles.safe(),
    profiles.safe_capped(1),
    profiles.safe_metered(1000),
    instance.safe_default(),
  ]
  |> list.all(fn(b: Binding) { b.mem_tier != Nif })
  |> should.be_true
}

/// Gate 4 — the `--link` gate: a coherent Unsafe + Nif binding is `Error(LinkTierNif)` (a NIF is
/// un-mergeable into a `.beam` under ANY mode, O8), even though `profiles.link/1` ADMITS the identical
/// binding for the ordinary non-linked runtime path.
pub fn gate_link_forbids_nif_tier_test() {
  let unsafe_nif =
    profiles.resolve_tiers(Binding(..profiles.unsafe(), mem_tier: Nif))
  twocore.link_gate(unsafe_nif, empty_module())
  |> should.equal(Error(twocore.LinkTierNif))
  // The load-bearing pin: link/1 ADMITS the identical binding (a valid runtime posture) — so the tier
  // gate, not link/1, is the packaging-boundary enforcement point.
  let assert Ok(_) = profiles.link(unsafe_nif)
}

/// A minimal import-free numerics `ir.Module` — the gate reads only `binding.mem_tier` and `m.imports`.
fn empty_module() -> ir.Module {
  ir.Module(
    name: "safety_gate_mod",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [],
    exports: [],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
    tags: [],
  )
}

// ═══════════════════════════ 7. The cc-absent path skips, never false-greens (S6) ═══════════════════════════
//
// (Test §5.7.) The build gate is CATEGORIZED: `Loaded` (cc present) OR `SkipNoToolchain` (cc absent) —
// NEVER a `BuildError`. On a cc-absent host this is the test that proves the native fuzz SKIPS rather
// than silently passing; on a cc-present host it confirms the native `.so` genuinely attaches. Either
// way conformance `fail=0` is unaffected (the paged delegate covers cell_nif when the `.so` is absent).
pub fn build_gate_is_categorized_not_false_green_test() {
  case nif_loader.ensure_loaded() {
    Loaded -> nif_loader.available() |> should.be_true
    SkipNoToolchain -> Nil
    BuildError(text) -> panic as text
  }
}
