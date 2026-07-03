//// Spec-grounded tests for `rt_mem_atomics` (unit P4-04) — the tier-O `atomics` linear memory.
////
//// These assert WebAssembly linear-memory SEMANTICS (not whatever the impl emits), citing the
//// spec, and hold the atomics backend BYTE-FOR-BYTE to the flat-binary `rebuild` oracle
//// (`rt_mem`'s `o_*`) AND to the paged backend (`rt_mem`'s `mem_*`) — a shared bug cannot hide
//// (E4). The op set mirrors the official `memory_trap`/`address`/`endianness`/`float_memory`/
//// `memory_size`/`memory_redundancy` `.wast`.
////
//// The atomics-specific risk is byte↔word addressing: an unaligned multi-byte access spanning
//// TWO 64-bit words must be byte-identical to the aligned / paged case. The word-boundary-crossing
//// corner cases + the randomized differential (with unaligned addresses and 1..8-byte widths)
//// target exactly that.
////
//// Spec refs:
//// - exec/instructions (load/store, memory.size/grow):
////   <https://webassembly.github.io/spec/core/exec/instructions.html>
//// - exec/modules (active data init): <https://webassembly.github.io/spec/core/exec/modules.html>
//// - syntax/values (little-endian, two's complement, IEEE bits):
////   <https://webassembly.github.io/spec/core/syntax/values.html>
////
//// Structure: (1) spec-corner tests on the pure `a_*` core; (2) fail-closed reservation / §C
//// rejection; (3) a randomized DIFFERENTIAL suite (atomics ≡ paged ≡ oracle); (4) cell-backed +
//// threaded wrapper tests (in-place store, grow-writes-back + charges fuel, metered parity);
//// (5) a constant-space store-loop smoke.

import gleam/dict
import gleam/dynamic
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleeunit/should
import twocore/ir.{MemoryOutOfBounds}
import twocore/runtime/rt_mem
import twocore/runtime/rt_mem_atomics as rma
import twocore/runtime/rt_meter
import twocore/runtime/rt_state.{type InstanceState, InstanceState, StateDecl}

// Page byte length; one fresh page = 65536 bytes.
const page: Int = 65_536

/// A generous Safe cap so the spec-corner tests are governed by the declared max / hard cap.
/// `100_000 > 65_536`, so it never binds below the 65536-page hard cap.
const big_cap: Int = 100_000

/// The default reserve cap (single-sourced), used where the test wants the production ceiling.
const reserve_cap: Int = 4096

/// Run `thunk` and report whether it raised: `Ok(value)` on a normal return, `Error(text)` on
/// any raise/exit/throw. The fail-closed reservation tests assert `result.is_error` — i.e. the
/// op raised at all (§C: `a_fresh` panics node-safe on an over-cap reserve). Pure Gleam cannot
/// `catch`; see `twocore_rt_state_test_ffi`.
@external(erlang, "twocore_rt_state_test_ffi", "catch_thunk")
fn catch_thunk(thunk: fn() -> a) -> Result(a, String)

// ───────────────────────────── 1. Little-endian multi-byte layout (endianness.wast) ─────────────────────────────

// Per the spec all loads/stores are little-endian: storing `0x04030201` as an i32 lays bytes
// `01 02 03 04` at +0..+3, and an i32 load reads them back as `0x04030201`. Aligned i32 at +0 is
// the atomics O(1) fast path (a whole word masked to 32 bits).
pub fn le_layout_test() {
  let a = rma.a_fresh(1, Some(1), big_cap, reserve_cap)
  let assert Ok(a) = rma.a_store(a, 4, 0, 0x04030201, 0)
  rma.a_load(a, 1, False, 32, 0, 0) |> should.equal(Ok(0x01))
  rma.a_load(a, 1, False, 32, 1, 0) |> should.equal(Ok(0x02))
  rma.a_load(a, 1, False, 32, 2, 0) |> should.equal(Ok(0x03))
  rma.a_load(a, 1, False, 32, 3, 0) |> should.equal(Ok(0x04))
  // The whole i32 reads back identically (redundant load after store — memory_redundancy).
  rma.a_load(a, 4, False, 32, 0, 0) |> should.equal(Ok(0x04030201))
}

// ───────────────────────────── 2. Word-boundary-crossing access (the atomics-specific risk) ─────────────────────────────

// An unaligned i64 store/load at p ≠ 0 that spans two 64-bit words must round-trip identically to
// the aligned case. At addr 5, an i64 touches word 0 (bytes 5,6,7) and word 1 (bytes 8..12).
pub fn word_boundary_crossing_i64_test() {
  let a = rma.a_fresh(1, Some(1), big_cap, reserve_cap)
  let v = 0x0102030405060708
  let assert Ok(a) = rma.a_store(a, 8, 5, v, 0)
  // The whole i64 reads back across the word boundary.
  rma.a_load(a, 8, False, 64, 5, 0) |> should.equal(Ok(v))
  // Each byte sits where LE expects (byte[5] = 0x08 low .. byte[12] = 0x01 high).
  rma.a_load(a, 1, False, 32, 5, 0) |> should.equal(Ok(0x08))
  rma.a_load(a, 1, False, 32, 7, 0) |> should.equal(Ok(0x06))
  // The exact word-boundary byte pair: byte[7] (word 0) and byte[8] (word 1).
  rma.a_load(a, 1, False, 32, 8, 0) |> should.equal(Ok(0x05))
  rma.a_load(a, 1, False, 32, 12, 0) |> should.equal(Ok(0x01))
  // Neighbours are untouched (no spill into byte 4 of word 0 or byte 13 of word 1).
  rma.a_load(a, 1, False, 32, 4, 0) |> should.equal(Ok(0))
  rma.a_load(a, 1, False, 32, 13, 0) |> should.equal(Ok(0))
  // A 2-byte access straddling the exact word boundary (bytes 7,8) round-trips.
  rma.a_load(a, 2, False, 32, 7, 0) |> should.equal(Ok(0x0506))
}

// An i32 store at addr 6 spans word 0 (bytes 6,7) and word 1 (bytes 8,9); overwrite a subset and
// confirm no corruption of the surrounding bytes in either word.
pub fn word_boundary_crossing_i32_partial_overwrite_test() {
  let a = rma.a_fresh(1, Some(1), big_cap, reserve_cap)
  // Fill both words with a known pattern via aligned i64 stores.
  let assert Ok(a) = rma.a_store(a, 8, 0, 0xAAAAAAAAAAAAAAAA, 0)
  let assert Ok(a) = rma.a_store(a, 8, 8, 0xBBBBBBBBBBBBBBBB, 0)
  // Cross-boundary i32 at addr 6: bytes 6,7 (word 0) and 8,9 (word 1).
  let assert Ok(a) = rma.a_store(a, 4, 6, 0x11223344, 0)
  rma.a_load(a, 4, False, 32, 6, 0) |> should.equal(Ok(0x11223344))
  // Surrounding bytes keep their pattern: byte 5 still 0xAA, byte 10 still 0xBB.
  rma.a_load(a, 1, False, 32, 5, 0) |> should.equal(Ok(0xAA))
  rma.a_load(a, 1, False, 32, 10, 0) |> should.equal(Ok(0xBB))
}

// ───────────────────────────── 3. Sign vs zero extend × result width ─────────────────────────────

// `loadN_s` sign-extends to the operand width; `loadN_u` zero-extends. `result_width`
// disambiguates i32.load8_s (→ 0xFFFFFF80) from i64.load8_s (→ 0xFF..FF80) for byte 0x80.
pub fn sign_zero_extend_test() {
  let a = rma.a_fresh(1, Some(1), big_cap, reserve_cap)
  let assert Ok(a) = rma.a_store(a, 1, 0, 0x80, 0)
  let assert Ok(a) = rma.a_store(a, 1, 1, 0xFF, 0)
  rma.a_load(a, 1, True, 32, 0, 0) |> should.equal(Ok(0xFFFFFF80))
  rma.a_load(a, 1, True, 64, 0, 0) |> should.equal(Ok(0xFFFFFFFFFFFFFF80))
  rma.a_load(a, 1, False, 32, 0, 0) |> should.equal(Ok(0x80))
  rma.a_load(a, 1, True, 32, 1, 0) |> should.equal(Ok(0xFFFFFFFF))
  rma.a_load(a, 1, True, 64, 1, 0) |> should.equal(Ok(0xFFFFFFFFFFFFFFFF))
  rma.a_load(a, 1, False, 32, 1, 0) |> should.equal(Ok(0xFF))
}

// i64.load16_s of 0x8000 → 0xFFFFFFFFFFFF8000; i64.load32_s of 0x80000000 → high bits set;
// load32_u zero-extends. Store the 32-bit value word-crossing (addr 6) to exercise the codec on
// a spanning access too.
pub fn wide_sign_extend_test() {
  let a = rma.a_fresh(1, Some(1), big_cap, reserve_cap)
  let assert Ok(a) = rma.a_store(a, 2, 0, 0x8000, 0)
  let assert Ok(a) = rma.a_store(a, 4, 6, 0x80000000, 0)
  rma.a_load(a, 2, True, 64, 0, 0) |> should.equal(Ok(0xFFFFFFFFFFFF8000))
  rma.a_load(a, 2, True, 32, 0, 0) |> should.equal(Ok(0xFFFF8000))
  rma.a_load(a, 4, True, 64, 6, 0) |> should.equal(Ok(0xFFFFFFFF80000000))
  rma.a_load(a, 4, False, 64, 6, 0) |> should.equal(Ok(0x80000000))
}

// ───────────────────────────── 4. Zero-fill (never-written + freshly grown) ─────────────────────────────

// A never-written in-bounds byte reads 0 (atomics:new zero-inits the words); every byte of a
// freshly grown page reads 0 (its words were reserved and never written). (memory.wast)
pub fn zero_fill_test() {
  let a = rma.a_fresh(1, Some(3), big_cap, reserve_cap)
  rma.a_load(a, 1, False, 32, 0, 0) |> should.equal(Ok(0))
  rma.a_load(a, 4, False, 32, 12_345, 0) |> should.equal(Ok(0))
  rma.a_load(a, 8, False, 64, page - 8, 0) |> should.equal(Ok(0))
  let #(old, a) = rma.a_grow(a, 1)
  old |> should.equal(1)
  // Every byte of the new page reads 0.
  rma.a_load(a, 1, False, 32, page, 0) |> should.equal(Ok(0))
  rma.a_load(a, 8, False, 64, 2 * page - 8, 0) |> should.equal(Ok(0))
  // The grown page is writable (its reserved words accept a store).
  let assert Ok(a) = rma.a_store(a, 4, page, 0xCAFEBABE, 0)
  rma.a_load(a, 4, False, 32, page, 0) |> should.equal(Ok(0xCAFEBABE))
}

// ───────────────────────────── 5. No-wrap effective address (memory_trap / address.wast) ─────────────────────────────

// ea = addr + offset is a bignum; NEVER reduced mod 2^32. addr = 0xFFFFFFFF + a large offset must
// TRAP, not wrap to a small in-bounds ea.
pub fn no_wrap_ea_test() {
  let a = rma.a_fresh(1, Some(2), big_cap, reserve_cap)
  rma.a_load(a, 4, False, 32, 0xFFFFFFFF, 100)
  |> should.equal(Error(MemoryOutOfBounds))
  rma.a_store(a, 4, 0xFFFFFFFF, 0xDEADBEEF, 100)
  |> should.equal(Error(MemoryOutOfBounds))
  // A wrap bug would have computed ea = 99 (in bounds). Prove byte 99 is untouched (still 0).
  rma.a_load(a, 4, False, 32, 99, 0) |> should.equal(Ok(0))
}

// ───────────────────────────── 6. Exact-length off-by-one (address.wast) ─────────────────────────────

// An access ending EXACTLY at byte_len is in bounds; one byte past traps.
pub fn off_by_one_test() {
  let a = rma.a_fresh(1, Some(1), big_cap, reserve_cap)
  rma.a_load(a, 4, False, 32, page - 4, 0) |> should.equal(Ok(0))
  rma.a_load(a, 4, False, 32, page - 3, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  rma.a_load(a, 1, False, 32, page - 1, 0) |> should.equal(Ok(0))
  rma.a_load(a, 1, False, 32, page, 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

// ───────────────────────────── 7. Partial multi-byte store traps with ZERO mutation (E3) ─────────────────────────────

// A multi-byte store straddling byte_len traps BEFORE any byte is written — including the
// in-bounds prefix. Seed a known i32, attempt a straddling store, prove every byte is unchanged.
pub fn partial_store_zero_mutation_test() {
  let a = rma.a_fresh(1, Some(1), big_cap, reserve_cap)
  let assert Ok(a) = rma.a_store(a, 4, page - 4, 0xAABBCCDD, 0)
  rma.a_store(a, 4, page - 2, 0x11223344, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  // The straddling store mutated nothing (bounds-check-before-write): the seeded bytes stand.
  rma.a_load(a, 4, False, 32, page - 4, 0) |> should.equal(Ok(0xAABBCCDD))
  rma.a_load(a, 1, False, 32, page - 2, 0) |> should.equal(Ok(0xBB))
  rma.a_load(a, 1, False, 32, page - 1, 0) |> should.equal(Ok(0xAA))
}

// ───────────────────────────── 8. memory.grow: OLD size, then -1 past max (memory_size.wast) ─────────────────────────────

// grow returns the OLD size on success and -1 past the declared max, allocating nothing (the
// watermark is unchanged); size reflects only successful grows.
pub fn grow_declared_max_test() {
  let a = rma.a_fresh(1, Some(3), big_cap, reserve_cap)
  rma.a_size(a) |> should.equal(1)
  let #(r1, a) = rma.a_grow(a, 1)
  r1 |> should.equal(1)
  rma.a_size(a) |> should.equal(2)
  let #(r2, a) = rma.a_grow(a, 1)
  r2 |> should.equal(2)
  rma.a_size(a) |> should.equal(3)
  let #(r3, a) = rma.a_grow(a, 1)
  r3 |> should.equal(-1)
  rma.a_size(a) |> should.equal(3)
  // delta 0 is a successful no-op returning the current size.
  let #(r4, _a) = rma.a_grow(a, 0)
  r4 |> should.equal(3)
}

// A negative delta never grows (defensive; WASM delta is u32 so this is unreachable upstream).
pub fn grow_negative_delta_test() {
  let a = rma.a_fresh(2, Some(4), big_cap, reserve_cap)
  let #(r, a) = rma.a_grow(a, -1)
  r |> should.equal(-1)
  rma.a_size(a) |> should.equal(2)
}

// ───────────────────────────── 9. f32/f64 round-trip preserves raw bits incl. NaN (float_memory.wast) ─────────────────────────────

// f32/f64 store/load are raw-byte moves over the IEEE bit pattern — never a BEAM-double
// round-trip (which would mangle NaN payloads / signalling bits). Store a NaN-payload pattern
// (word-crossing, to also exercise the codec on a spanning access) and read the identical bits.
pub fn float_nan_roundtrip_test() {
  let a = rma.a_fresh(1, Some(1), big_cap, reserve_cap)
  let f64_nan = 0x7FF8000000000001
  let f64_neg_zero = 0x8000000000000000
  let f32_nan = 0x7FC00001
  let f32_pos_inf = 0x7F800000
  // f64 at addr 3 spans two words.
  let assert Ok(a) = rma.a_store(a, 8, 3, f64_nan, 0)
  let assert Ok(a) = rma.a_store(a, 8, 16, f64_neg_zero, 0)
  let assert Ok(a) = rma.a_store(a, 4, 24, f32_nan, 0)
  let assert Ok(a) = rma.a_store(a, 4, 28, f32_pos_inf, 0)
  rma.a_load(a, 8, False, 64, 3, 0) |> should.equal(Ok(f64_nan))
  rma.a_load(a, 8, False, 64, 16, 0) |> should.equal(Ok(f64_neg_zero))
  rma.a_load(a, 4, False, 32, 24, 0) |> should.equal(Ok(f32_nan))
  rma.a_load(a, 4, False, 32, 28, 0) |> should.equal(Ok(f32_pos_inf))
}

// ───────────────────────────── 10. init_data: in-bounds writes exact bytes; OOB traps ─────────────────────────────

pub fn init_data_test() {
  let a = rma.a_fresh(1, Some(1), big_cap, reserve_cap)
  let assert Ok(a) = rma.a_init_data(a, 10, <<0xDE, 0xAD, 0xBE, 0xEF>>)
  rma.a_load(a, 1, False, 32, 10, 0) |> should.equal(Ok(0xDE))
  rma.a_load(a, 1, False, 32, 13, 0) |> should.equal(Ok(0xEF))
  // i32.load reads them little-endian: bytes DE AD BE EF → 0xEFBEADDE.
  rma.a_load(a, 4, False, 32, 10, 0) |> should.equal(Ok(0xEFBEADDE))
  // A segment that overruns byte_len traps (whole-range check, no partial write).
  rma.a_init_data(a, page - 2, <<1, 2, 3, 4>>)
  |> should.equal(Error(MemoryOutOfBounds))
  // The straddling segment wrote nothing: the last in-bounds byte is still 0.
  rma.a_load(a, 1, False, 32, page - 2, 0) |> should.equal(Ok(0))
}

// An empty active segment is always in bounds (even at byte_len), and is a no-op.
pub fn init_data_empty_segment_test() {
  let a = rma.a_fresh(1, Some(1), big_cap, reserve_cap)
  rma.a_init_data(a, page, <<>>) |> should.be_ok
}

// A data segment that crosses a word boundary writes each byte correctly.
pub fn init_data_word_crossing_test() {
  let a = rma.a_fresh(1, Some(1), big_cap, reserve_cap)
  // 6 bytes at offset 5 span word 0 (5,6,7) and word 1 (8,9,10).
  let assert Ok(a) = rma.a_init_data(a, 5, <<1, 2, 3, 4, 5, 6>>)
  rma.a_load(a, 1, False, 32, 5, 0) |> should.equal(Ok(1))
  rma.a_load(a, 1, False, 32, 8, 0) |> should.equal(Ok(4))
  rma.a_load(a, 1, False, 32, 10, 0) |> should.equal(Ok(6))
  // i64 read of all 6 bytes (LE, zero-high): 06 05 04 03 02 01 → 0x060504030201.
  rma.a_load(a, 8, False, 64, 5, 0) |> should.equal(Ok(0x060504030201))
}

// ───────────────────────────── 11. Fail-closed reservation / §C rejection ─────────────────────────────

// `reservation` is the SINGLE source unit 07 uses to admit-or-reject: reserve = max(min, eff)
// must be <= reserve_cap. A bounded max engages atomics; an uncapped no-max module (eff = hard
// cap) is rejected (over-cap), NEVER silently degraded to paged / pre-allocated at 4 GiB.
pub fn reservation_bounded_engages_test() {
  // A bounded declared max within the cap engages.
  rma.reservation(1, Some(4), big_cap, reserve_cap) |> should.equal(Ok(4))
  // reserve = max(min, eff): min dominates when larger.
  rma.reservation(10, Some(4), big_cap, reserve_cap) |> should.equal(Ok(10))
  // safe_capped(small) lowers safe_cap so an uncapped memory still engages.
  rma.reservation(1, None, 4000, reserve_cap) |> should.equal(Ok(4000))
}

pub fn reservation_uncapped_rejected_test() {
  // No declared max AND a generous safe_cap → eff = hard cap 65536 > 4096 → REJECT (never degrade).
  rma.reservation(1, None, big_cap, reserve_cap) |> should.equal(Error(Nil))
  // A bounded-but-too-large declared max is also rejected.
  rma.reservation(1, Some(5000), big_cap, reserve_cap)
  |> should.equal(Error(Nil))
  // eff folds the hard cap: a declared max above 65536 is clamped, still over the reserve cap.
  rma.reservation(1, Some(70_000), big_cap, reserve_cap)
  |> should.equal(Error(Nil))
}

// `a_fresh` reached with an over-cap reserve FAILS CLOSED (a node-safe panic) — the defensive
// backstop (unreachable post-validation). It never silently pre-allocates 4 GiB / degrades.
pub fn a_fresh_over_cap_panics_test() {
  catch_thunk(fn() { rma.a_fresh(1, None, big_cap, reserve_cap) })
  |> result.is_error
  |> should.be_true
  // And the cell-backed `fresh` (which uses the default reserve cap) panics on an uncapped memory.
  catch_thunk(fn() { rma.fresh(1, None, big_cap) })
  |> result.is_error
  |> should.be_true
}

// A bounded `a_fresh` succeeds (engages AtomicsBacked) — the positive control for the above.
pub fn a_fresh_bounded_succeeds_test() {
  catch_thunk(fn() { rma.a_fresh(1, Some(4), big_cap, reserve_cap) })
  |> result.is_ok
  |> should.be_true
}

// ───────────────────────────── 12. DIFFERENTIAL: atomics ≡ paged ≡ oracle (E4) ─────────────────────────────

type OpResult {
  RLoad(Result(Int, ir.TrapReason))
  RStore(Result(Nil, ir.TrapReason))
  RGrow(Int)
  RInit(Result(Nil, ir.TrapReason))
}

type Op {
  OpLoad(bytes: Int, signed: Bool, width: Int, addr: Int, offset: Int)
  OpStore(bytes: Int, addr: Int, value: Int, offset: Int)
  OpGrow(delta: Int)
  OpInit(offset: Int, bytes: BitArray)
  OpFill(dest: Int, value: Int, count: Int)
  OpCopy(dst: Int, src: Int, count: Int)
  OpBulkInit(seg: BitArray, dst: Int, src: Int, count: Int)
}

/// A 31-bit linear-congruential PRNG (deterministic so a failure reproduces).
fn lcg(state: Int) -> Int {
  let next = state * 1_103_515_245 + 12_345
  int_band(next, 0x7FFFFFFF)
}

@external(erlang, "erlang", "band")
fn int_band(a: Int, b: Int) -> Int

@external(erlang, "erlang", "bor")
fn int_bor(a: Int, b: Int) -> Int

@external(erlang, "erlang", "bsl")
fn int_bsl(a: Int, b: Int) -> Int

/// Drive atomics, paged, and oracle through the same `count` random ops on a memory that ENGAGES
/// `AtomicsBacked` (bounded max 2, reserve 2 << cap); assert identical results+traps at every step
/// AND an identical flat byte image after every step (the strongest byte-for-byte differential —
/// it catches any in-place-mutation / word-boundary drift the instant it happens).
fn run_differential(count: Int, seed: Int) -> Nil {
  let a = rma.a_fresh(1, Some(2), big_cap, reserve_cap)
  let m = rt_mem.fresh_mem(1, Some(2), big_cap, rt_mem.default_chunk_bytes)
  let o = rt_mem.o_fresh(1, Some(2), big_cap)
  diff_loop(a, m, o, seed, count)
}

fn diff_loop(
  a: rma.Atomics,
  m: rt_mem.Mem,
  o: rt_mem.OMem,
  seed: Int,
  remaining: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let #(op, seed) = gen_op(rma.a_size(a) * page, seed)
      let #(a, ra) = apply_atomics(a, op)
      let #(m, rp) = apply_paged(m, op)
      let #(o, ro) = apply_oracle(o, op)
      // The security boundary: all three agree on value AND trap, every step.
      ra |> should.equal(rp)
      ra |> should.equal(ro)
      // And the whole in-bounds byte image is byte-identical, every step.
      let image = rma.a_flat(a)
      image |> should.equal(rt_mem.mem_flat(m))
      image |> should.equal(rt_mem.o_flat(o))
      diff_loop(a, m, o, seed, remaining - 1)
    }
  }
}

fn apply_atomics(a: rma.Atomics, op: Op) -> #(rma.Atomics, OpResult) {
  case op {
    OpLoad(b, s, w, ad, off) -> #(a, RLoad(rma.a_load(a, b, s, w, ad, off)))
    OpStore(b, ad, v, off) ->
      case rma.a_store(a, b, ad, v, off) {
        Ok(a2) -> #(a2, RStore(Ok(Nil)))
        Error(e) -> #(a, RStore(Error(e)))
      }
    OpGrow(d) -> {
      let #(r, a2) = rma.a_grow(a, d)
      #(a2, RGrow(r))
    }
    OpInit(off, bytes) ->
      case rma.a_init_data(a, off, bytes) {
        Ok(a2) -> #(a2, RInit(Ok(Nil)))
        Error(e) -> #(a, RInit(Error(e)))
      }
    OpFill(d, v, n) ->
      case rma.a_fill(a, d, v, n) {
        Ok(a2) -> #(a2, RInit(Ok(Nil)))
        Error(e) -> #(a, RInit(Error(e)))
      }
    OpCopy(d, s, n) ->
      case rma.a_copy(a, a, d, s, n) {
        Ok(a2) -> #(a2, RInit(Ok(Nil)))
        Error(e) -> #(a, RInit(Error(e)))
      }
    OpBulkInit(seg, d, s, n) ->
      case rma.a_init(a, seg, d, s, n) {
        Ok(a2) -> #(a2, RInit(Ok(Nil)))
        Error(e) -> #(a, RInit(Error(e)))
      }
  }
}

fn apply_paged(m: rt_mem.Mem, op: Op) -> #(rt_mem.Mem, OpResult) {
  case op {
    OpLoad(b, s, w, ad, off) -> #(
      m,
      RLoad(rt_mem.mem_load(m, b, s, w, ad, off)),
    )
    OpStore(b, ad, v, off) ->
      case rt_mem.mem_store(m, b, ad, v, off) {
        Ok(m2) -> #(m2, RStore(Ok(Nil)))
        Error(e) -> #(m, RStore(Error(e)))
      }
    OpGrow(d) -> {
      let #(r, m2) = rt_mem.mem_grow(m, d)
      #(m2, RGrow(r))
    }
    OpInit(off, bytes) ->
      case rt_mem.mem_init_data(m, off, bytes) {
        Ok(m2) -> #(m2, RInit(Ok(Nil)))
        Error(e) -> #(m, RInit(Error(e)))
      }
    OpFill(d, v, n) ->
      case rt_mem.mem_fill(m, d, v, n) {
        Ok(m2) -> #(m2, RInit(Ok(Nil)))
        Error(e) -> #(m, RInit(Error(e)))
      }
    OpCopy(d, s, n) ->
      case rt_mem.mem_copy(m, m, d, s, n) {
        Ok(m2) -> #(m2, RInit(Ok(Nil)))
        Error(e) -> #(m, RInit(Error(e)))
      }
    OpBulkInit(seg, d, s, n) ->
      case rt_mem.mem_init(m, seg, d, s, n) {
        Ok(m2) -> #(m2, RInit(Ok(Nil)))
        Error(e) -> #(m, RInit(Error(e)))
      }
  }
}

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
    OpFill(d, v, n) ->
      case rt_mem.o_fill(o, d, v, n) {
        Ok(o2) -> #(o2, RInit(Ok(Nil)))
        Error(e) -> #(o, RInit(Error(e)))
      }
    OpCopy(d, s, n) ->
      case rt_mem.o_copy(o, o, d, s, n) {
        Ok(o2) -> #(o2, RInit(Ok(Nil)))
        Error(e) -> #(o, RInit(Error(e)))
      }
    OpBulkInit(seg, d, s, n) ->
      case rt_mem.o_init(o, seg, d, s, n) {
        Ok(o2) -> #(o2, RInit(Ok(Nil)))
        Error(e) -> #(o, RInit(Error(e)))
      }
  }
}

/// Generate a random op given the current `byte_len`. Addresses span in-bounds (many UNALIGNED,
/// so word-boundary crossings are frequent), a few bytes past the end, and occasionally
/// 0xFFFFFFFF (the no-wrap probe); widths/signs/values random; grows stay within the 2-page max.
fn gen_op(byte_len: Int, seed: Int) -> #(Op, Int) {
  let s = lcg(seed)
  case s % 16 {
    k if k < 4 -> {
      let s2 = lcg(s)
      let bytes = pick_bytes(s2 % 4)
      let #(addr, s3) = pick_addr(s2, byte_len)
      let s4 = lcg(s3)
      let s5 = lcg(s4)
      #(OpStore(bytes, addr, pick_value(s5), s4 % 8), s5)
    }
    k if k < 7 -> {
      let s2 = lcg(s)
      let bytes = pick_bytes(s2 % 4)
      let #(width, s3) = pick_width(bytes, s2)
      let s4 = lcg(s3)
      let #(addr, s5) = pick_addr(s4, byte_len)
      let signed = s4 % 2 == 0
      #(OpLoad(bytes, signed, width, addr, s5 % 8), s5)
    }
    7 -> {
      let s2 = lcg(s)
      #(OpGrow(s2 % 3), s2)
    }
    8 -> {
      let s2 = lcg(s)
      let len = s2 % 6
      let #(addr, s3) = pick_addr(s2, byte_len)
      let #(bytes, s4) = rand_bytes(len, s3)
      #(OpInit(addr, bytes), s4)
    }
    k if k < 11 -> {
      // memory.fill: dest spanning in/out of bounds (many UNALIGNED), low-byte value, small count.
      let s2 = lcg(s)
      let #(dest, s3) = pick_addr(s2, byte_len)
      let s4 = lcg(s3)
      #(OpFill(dest, pick_value(s4), s4 % 9), s4)
    }
    k if k < 13 -> {
      // memory.copy on ONE memory → OVERLAP both directions (crosses word boundaries too).
      let s2 = lcg(s)
      let #(dst, s3) = pick_addr(s2, byte_len)
      let #(src, s4) = pick_addr(s3, byte_len)
      #(OpCopy(dst, src, s4 % 9), s4)
    }
    _ -> {
      // memory.init from a random-length segment (occasionally ε); src may overrun the segment.
      let s2 = lcg(s)
      let seg_len = s2 % 6
      let #(seg, s3) = rand_bytes(seg_len, s2)
      let #(dst, s4) = pick_addr(s3, byte_len)
      let s5 = lcg(s4)
      let src = s5 % { seg_len + 3 }
      let s6 = lcg(s5)
      #(OpBulkInit(seg, dst, src, s6 % 9), s6)
    }
  }
}

fn pick_bytes(i: Int) -> Int {
  case i {
    0 -> 1
    1 -> 2
    2 -> 4
    _ -> 8
  }
}

fn pick_width(bytes: Int, seed: Int) -> #(Int, Int) {
  case bytes {
    8 -> #(64, seed)
    _ -> {
      let s = lcg(seed)
      case s % 2 {
        0 -> #(32, s)
        _ -> #(64, s)
      }
    }
  }
}

/// Mostly in-bounds (a touch past byte_len so OOB is exercised), occasionally 0xFFFFFFFF (the
/// no-wrap probe — must trap, never wrap).
fn pick_addr(seed: Int, byte_len: Int) -> #(Int, Int) {
  let s = lcg(seed)
  case s % 17 == 0 {
    True -> #(0xFFFFFFFF, s)
    False -> #(s % { byte_len + 16 }, s)
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

pub fn differential_seed_a_test() {
  run_differential(150, 0x1234)
}

pub fn differential_seed_b_test() {
  run_differential(150, 0xBEEF)
}

pub fn differential_seed_c_test() {
  run_differential(200, 0xC0FFEE)
}

// ───────────────────────────── 13. Cell-backed wrappers (seed → op → observe) ─────────────────────────────

// The public load/store/size/grow read the `mem` slot of THIS process's cell. Seed a fresh
// atomics memory via rt_state, exercise the wrappers, observe persistence + isolation.

pub fn cell_store_load_roundtrip_test() {
  rt_state.seed(StateDecl(
    mem: rma.fresh(1, Some(2), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rma.store(4, 0, 0x04030201, 0) |> should.equal(Ok(Nil))
  // The store persisted (the ref mutated in place) across the separate load call.
  rma.load(4, False, 32, 0, 0) |> should.equal(Ok(0x04030201))
  rma.load(1, False, 32, 0, 0) |> should.equal(Ok(0x01))
  rma.load(1, True, 32, 3, 0) |> should.equal(Ok(0x04))
  rma.load(4, False, 32, page, 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

// The O(1) win: an AtomicsBacked store mutates the shared ref in place, so NO mem_put is needed —
// yet the value persists. We prove persistence WITHOUT any grow (the only op that writes back).
pub fn cell_store_persists_in_place_test() {
  rt_state.seed(StateDecl(
    mem: rma.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  // A word-crossing store, then read via a SEPARATE call (fresh cell read): in-place mutation.
  rma.store(8, 5, 0x1122334455667788, 0) |> should.equal(Ok(Nil))
  rma.load(8, False, 64, 5, 0) |> should.equal(Ok(0x1122334455667788))
}

pub fn cell_size_and_grow_test() {
  rt_state.seed(StateDecl(
    mem: rma.fresh(1, Some(3), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rma.size() |> should.equal(1)
  rma.grow(1) |> should.equal(1)
  // grow writes back the new watermark record → size reflects it.
  rma.size() |> should.equal(2)
  rma.grow(5) |> should.equal(-1)
  rma.size() |> should.equal(2)
  // The grown page is zero and writable.
  rma.load(4, False, 32, page, 0) |> should.equal(Ok(0))
  rma.store(4, page, 0xCAFEBABE, 0) |> should.equal(Ok(Nil))
  rma.load(4, False, 32, page, 0) |> should.equal(Ok(0xCAFEBABE))
}

pub fn cell_grow_charges_fuel_proportional_test() {
  rt_meter.reset_fuel()
  rt_state.seed(StateDecl(
    mem: rma.fresh(1, Some(4), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  // A successful grow of 2 pages charges 2 * 65536 bytes of fuel (E3).
  rma.grow(2) |> should.equal(1)
  rt_meter.fuel_consumed() |> should.equal(2 * page)
  // A FAILED grow (past max) allocates nothing and charges nothing.
  rma.grow(100) |> should.equal(-1)
  rt_meter.fuel_consumed() |> should.equal(2 * page)
}

pub fn cell_isolation_between_seeds_test() {
  rt_state.seed(StateDecl(
    mem: rma.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rma.store(1, 42, 0xAB, 0) |> should.equal(Ok(Nil))
  rma.load(1, False, 32, 42, 0) |> should.equal(Ok(0xAB))
  // Re-seed: a FRESH atomics array. A's write must NOT bleed through (a new ref, not the old one).
  rt_state.seed(StateDecl(
    mem: rma.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rma.load(1, False, 32, 42, 0) |> should.equal(Ok(0))
}

pub fn cell_partial_store_trap_no_mutation_test() {
  rt_state.seed(StateDecl(
    mem: rma.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  let assert Ok(Nil) = rma.store(4, page - 4, 0xAABBCCDD, 0)
  rma.store(4, page - 2, 0x11223344, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  rma.load(4, False, 32, page - 4, 0) |> should.equal(Ok(0xAABBCCDD))
}

pub fn cell_init_data_test() {
  rt_state.seed(StateDecl(
    mem: rma.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rma.init_data(8, <<0xDE, 0xAD, 0xBE, 0xEF>>) |> should.equal(Ok(Nil))
  rma.load(4, False, 32, 8, 0) |> should.equal(Ok(0xEFBEADDE))
  rma.init_data(page - 2, <<1, 2, 3, 4>>)
  |> should.equal(Error(MemoryOutOfBounds))
}

// The uniform differential hook over the cell Dynamic: to_flat(mem_get()) is the byte image.
pub fn cell_to_flat_matches_oracle_test() {
  rt_state.seed(StateDecl(
    mem: rma.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rma.store(4, 100, 0x04030201, 0) |> should.equal(Ok(Nil))
  // Build the equivalent oracle image and compare byte-for-byte via the frozen Dynamic hook.
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  let assert Ok(o) = rt_mem.o_store(o, 4, 100, 0x04030201, 0)
  rma.to_flat(rt_state.mem_get()) |> should.equal(rt_mem.o_flat(o))
}

// ───────────────────────────── 14. Threaded wrappers (thread the InstanceState record) ─────────────────────────────

/// Build a threaded InstanceState whose `mem` slot holds a fresh atomics memory.
fn threaded_state() -> rt_state.InstanceState {
  rt_state.fresh(StateDecl(
    mem: rma.fresh(1, Some(4), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
}

// t_store returns the SAME st (§10): the ref is mutated in place, so the mem Dynamic is
// unchanged. We prove it by reading through the ORIGINAL st after the store — it sees the value.
pub fn threaded_store_in_place_test() {
  let st = threaded_state()
  let assert Ok(_st2) = rma.t_store(st, 8, 5, 0xDEADBEEFCAFEF00D, 0)
  // Read through the pre-store `st`: the shared ref carries the mutation (no re-injection needed).
  rma.t_load(st, 8, False, 64, 5, 0)
  |> should.equal(Ok(0xDEADBEEFCAFEF00D))
}

// t_load / t_size are read-only (st unchanged).
pub fn threaded_read_only_test() {
  let st = threaded_state()
  rma.t_size(st) |> should.equal(1)
  rma.t_load(st, 4, False, 32, 0, 0) |> should.equal(Ok(0))
}

// t_grow returns the OLD pages + a REBOUND record whose size reflects the grow; -1 past max.
pub fn threaded_grow_rebinds_test() {
  let st = threaded_state()
  let #(r1, st) = rma.t_grow(st, 2)
  r1 |> should.equal(1)
  rma.t_size(st) |> should.equal(3)
  let #(r2, st) = rma.t_grow(st, 1)
  r2 |> should.equal(3)
  rma.t_size(st) |> should.equal(4)
  // Past the declared max (4): -1, unchanged.
  let #(r3, st) = rma.t_grow(st, 1)
  r3 |> should.equal(-1)
  rma.t_size(st) |> should.equal(4)
  // The grown pages are zero and writable through the threaded record.
  let assert Ok(st) = rma.t_store(st, 4, 3 * page, 0x0BADF00D, 0)
  rma.t_load(st, 4, False, 32, 3 * page, 0) |> should.equal(Ok(0x0BADF00D))
}

// P2 metered parity: a metered THREADED grow and a metered CELL grow debit an IDENTICAL fuel
// amount (delta * page_bytes) — so metered+threaded == metered+cell (the G7 trap bar).
pub fn threaded_grow_charges_same_fuel_as_cell_test() {
  // Cell grow of 3 pages.
  rt_meter.reset_fuel()
  rt_state.seed(StateDecl(
    mem: rma.fresh(1, Some(8), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rma.grow(3) |> should.equal(1)
  let cell_fuel = rt_meter.fuel_consumed()

  // Threaded grow of 3 pages.
  rt_meter.reset_fuel()
  let st =
    rt_state.fresh(StateDecl(
      mem: rma.fresh(1, Some(8), big_cap),
      globals: [],
      table: dynamic.nil(),
    ))
  let #(r, _st) = rma.t_grow(st, 3)
  r |> should.equal(1)
  let threaded_fuel = rt_meter.fuel_consumed()

  cell_fuel |> should.equal(3 * page)
  threaded_fuel |> should.equal(cell_fuel)
}

// A failed threaded grow (past max) charges nothing and returns the unchanged record.
pub fn threaded_grow_failed_charges_nothing_test() {
  rt_meter.reset_fuel()
  let st = threaded_state()
  let #(r, st) = rma.t_grow(st, 100)
  r |> should.equal(-1)
  rma.t_size(st) |> should.equal(1)
  rt_meter.fuel_consumed() |> should.equal(0)
}

pub fn threaded_init_data_test() {
  let st = threaded_state()
  let assert Ok(st) = rma.t_init_data(st, 10, <<0xDE, 0xAD, 0xBE, 0xEF>>)
  rma.t_load(st, 4, False, 32, 10, 0) |> should.equal(Ok(0xEFBEADDE))
  rma.t_init_data(st, page - 2, <<1, 2, 3, 4>>)
  |> should.equal(Error(MemoryOutOfBounds))
}

// ───────────────────────────── 15. Constant-space store loop (E1, §Verification #4) ─────────────────────────────

// ~100k stores over the cell API: each mutates the shared atomics array IN PLACE (no per-store
// garbage, no mem_put). We assert the loop completes and the final read is correct — exercising
// the in-place-mutation path the constant-space property rests on.
pub fn constant_space_store_loop_test() {
  rt_state.seed(StateDecl(
    mem: rma.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  store_loop(0, 100_000)
  // After 100k in-place stores the array is still sound: a fresh store/load round-trips.
  rma.store(4, 128, 0x0BADF00D, 0) |> should.equal(Ok(Nil))
  rma.load(4, False, 32, 128, 0) |> should.equal(Ok(0x0BADF00D))
}

fn store_loop(i: Int, n: Int) -> Nil {
  case i >= n {
    True -> Nil
    False -> {
      let addr = i * 4 % { page - 4 }
      let assert Ok(Nil) = rma.store(4, addr, i, 0)
      store_loop(i + 1, n)
    }
  }
}

// ───────────────────────────── 16. Bulk memory spec corners on a_* (memory_fill/copy/init.wast) ─────────────────────────────
//
// The finalized bulk-memory proposal (§4.4.9) on the tier-O atomics core: eager bounds (strict `>`,
// unconditional incl. n==0 — R10), no partial writes on trap, memmove-correct copy (R11) even
// across 64-bit word boundaries (the atomics-specific risk), init bounded by BOTH the segment and
// the memory (a dropped/ε segment traps for n>0, no-ops for n=0).

/// A fresh 1-page atomics memory (declared max 1).
fn a_fresh1() -> rma.Atomics {
  rma.a_fresh(1, Some(1), big_cap, reserve_cap)
}

/// Bytes `[from, from+count)` of an atomics memory as a list (for a compact image assertion).
fn a_bytes(a: rma.Atomics, from: Int, count: Int) -> List(Int) {
  list.map(index_range(from, count), fn(i) {
    let assert Ok(b) = rma.a_load(a, 1, False, 32, i, 0)
    b
  })
}

/// The ascending list `[start, start+1, …, start+count-1]` (`[]` for `count <= 0`). Built by hand
/// (the stdlib pinned here has no `list.range`).
fn index_range(start: Int, count: Int) -> List(Int) {
  index_range_loop(start, count, [])
}

fn index_range_loop(start: Int, count: Int, acc: List(Int)) -> List(Int) {
  case count <= 0 {
    True -> list.reverse(acc)
    False -> index_range_loop(start + 1, count - 1, [start, ..acc])
  }
}

// `memory.fill` writes the LOW byte only, `count` times; count 0 is a no-op. Fill across a word
// boundary (offset 5, count 6 → bytes 5..10) exercises the two-word scatter path.
pub fn a_fill_low_byte_and_word_crossing_test() {
  let assert Ok(a) = rma.a_fill(a_fresh1(), 5, 0x12345678, 6)
  a_bytes(a, 5, 6) |> should.equal([0x78, 0x78, 0x78, 0x78, 0x78, 0x78])
  // Neighbours untouched (byte 4 in word 0, byte 11 in word 1).
  rma.a_load(a, 1, False, 32, 4, 0) |> should.equal(Ok(0))
  rma.a_load(a, 1, False, 32, 11, 0) |> should.equal(Ok(0))
  // A zero-count fill writes nothing.
  let assert Ok(a0) = rma.a_fill(a, 20, 0xFF, 0)
  rma.a_load(a0, 1, False, 32, 20, 0) |> should.equal(Ok(0))
}

// Eager bounds (R10) + no partial write (the check precedes any scatter, so nothing is mutated).
pub fn a_fill_eager_bounds_no_partial_write_test() {
  let assert Ok(a) = rma.a_store(a_fresh1(), 4, page - 4, 0xAABBCCDD, 0)
  // dest+count == byte_len is in bounds.
  let assert Ok(a) = rma.a_fill(a, 0, 0x00, 8)
  // dest+count == byte_len+1 traps with ZERO mutation (the seeded tail stands).
  rma.a_fill(a, page - 3, 0x22, 4)
  |> should.equal(Error(MemoryOutOfBounds))
  rma.a_load(a, 4, False, 32, page - 4, 0) |> should.equal(Ok(0xAABBCCDD))
  // R10 exact boundary at n==0.
  rma.a_fill(a, page, 0x33, 0) |> should.be_ok
  rma.a_fill(a, page + 1, 0x33, 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

// `memory.copy` is memmove — correct in BOTH directions, including a copy that crosses a 64-bit
// word boundary in both the source and destination regions.
pub fn a_copy_memmove_overlap_test() {
  // Within word 0: the §B.2 worked examples on [0..7].
  let assert Ok(a) = rma.a_init_data(a_fresh1(), 0, <<0, 1, 2, 3, 4, 5, 6, 7>>)
  let assert Ok(fwd) = rma.a_copy(a, a, 1, 0, 3)
  a_bytes(fwd, 0, 8) |> should.equal([0, 0, 1, 2, 4, 5, 6, 7])

  // Word-crossing overlap: [0..15] (two words), copy(dst=6, src=3, count=6) → bytes[6..11] become
  // the memmove snapshot of bytes[3..8] = [3,4,5,6,7,8].
  let assert Ok(b) =
    rma.a_init_data(a_fresh1(), 0, <<
      0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    >>)
  let assert Ok(b2) = rma.a_copy(b, b, 6, 3, 6)
  a_bytes(b2, 6, 6) |> should.equal([3, 4, 5, 6, 7, 8])
  // Untouched tail.
  a_bytes(b2, 12, 4) |> should.equal([12, 13, 14, 15])
}

// Eager bounds on BOTH ranges; a trapping copy mutates nothing (bounds precede any scatter).
pub fn a_copy_eager_bounds_test() {
  let assert Ok(a) = rma.a_init_data(a_fresh1(), 0, <<0, 1, 2, 3, 4, 5, 6, 7>>)
  rma.a_copy(a, a, 0, page - 2, 4)
  |> should.equal(Error(MemoryOutOfBounds))
  rma.a_copy(a, a, page - 2, 0, 4)
  |> should.equal(Error(MemoryOutOfBounds))
  a_bytes(a, 0, 8) |> should.equal([0, 1, 2, 3, 4, 5, 6, 7])
}

// Cross-memory copy on the pure core: distinct atomics handles; reads src, writes dst; src intact.
pub fn a_cross_memory_copy_test() {
  let assert Ok(src) = rma.a_init_data(a_fresh1(), 0, <<10, 20, 30, 40, 50>>)
  let dst = rma.a_fresh(2, Some(2), big_cap, reserve_cap)
  let assert Ok(dst2) = rma.a_copy(dst, src, 5, 0, 3)
  rma.a_load(dst2, 1, False, 32, 5, 0) |> should.equal(Ok(10))
  rma.a_load(dst2, 1, False, 32, 7, 0) |> should.equal(Ok(30))
  rma.a_load(dst2, 1, False, 32, 0, 0) |> should.equal(Ok(0))
  // src is unchanged; bounds use each memory's own length (fits in dst, overruns src → trap).
  rma.a_load(src, 1, False, 32, 0, 0) |> should.equal(Ok(10))
  rma.a_copy(dst, src, page, page - 2, 4)
  |> should.equal(Error(MemoryOutOfBounds))
}

// `memory.init` writes seg[src..src+count); eager bounds on the segment AND the memory; a dropped
// (ε) segment traps for n>0 and no-ops for n=0.
pub fn a_init_from_segment_and_dropped_test() {
  let seg = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE>>
  let assert Ok(a) = rma.a_init(a_fresh1(), seg, 10, 1, 3)
  rma.a_load(a, 1, False, 32, 10, 0) |> should.equal(Ok(0xBB))
  rma.a_load(a, 1, False, 32, 12, 0) |> should.equal(Ok(0xDD))
  rma.a_load(a, 1, False, 32, 13, 0) |> should.equal(Ok(0))
  // src + count > len(seg) traps.
  rma.a_init(a, seg, 0, 3, 3) |> should.equal(Error(MemoryOutOfBounds))
  // Dropped/ε segment: n>0 traps, n=0 no-ops.
  rma.a_init(a, <<>>, 0, 0, 1) |> should.equal(Error(MemoryOutOfBounds))
  rma.a_init(a, <<>>, 0, 0, 0) |> should.be_ok
}

// No-wrap ea carries to bulk ops: dest/dst near 2^32 with a wrapping count must TRAP, not wrap.
pub fn a_bulk_no_wrap_ea_test() {
  let a = a_fresh1()
  rma.a_fill(a, 0xFFFFFFFF, 0x11, 100)
  |> should.equal(Error(MemoryOutOfBounds))
  rma.a_copy(a, a, 0xFFFFFFFF, 0, 4)
  |> should.equal(Error(MemoryOutOfBounds))
  rma.a_init(a, <<1, 2, 3, 4>>, 0xFFFFFFFF, 0, 4)
  |> should.equal(Error(MemoryOutOfBounds))
}

// ───────────────────────────── 17. Bulk cell wrappers (in-place, fuel, no partial write) ─────────────────────────────

/// Seed a fresh 1-page atomics cell memory for the bulk-wrapper tests.
fn seed_cell_1page() -> Nil {
  rt_state.seed(StateDecl(
    mem: rma.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
}

// `fill` mutates the shared ref IN PLACE (persists across a separate cell read) and charges `count`
// fuel (R9); a trapping fill mutates nothing and charges nothing.
pub fn cell_fill_persists_and_charges_fuel_test() {
  rt_meter.reset_fuel()
  seed_cell_1page()
  rma.fill(0, 0, 0xFF, 16) |> should.equal(Ok(Nil))
  rma.load_at(0, 4, False, 32, 0, 0) |> should.equal(Ok(0xFFFFFFFF))
  // The frozen index-0 head observes the SAME ref (byte-identity).
  rma.load(4, False, 32, 12, 0) |> should.equal(Ok(0xFFFFFFFF))
  rt_meter.fuel_consumed() |> should.equal(16)
  rma.fill(0, page - 1, 0x00, 4) |> should.equal(Error(MemoryOutOfBounds))
  rt_meter.fuel_consumed() |> should.equal(16)
  rma.load_at(0, 1, False, 32, 0, 0) |> should.equal(Ok(0xFF))
}

// Same-memory `copy` through the cell wrapper is overlap-correct and charges `count` fuel.
pub fn cell_copy_same_memory_overlap_test() {
  rt_meter.reset_fuel()
  seed_cell_1page()
  rma.init_data_at(0, 0, <<0, 1, 2, 3, 4, 5, 6, 7>>)
  |> should.equal(Ok(Nil))
  rma.copy(0, 0, 1, 0, 3) |> should.equal(Ok(Nil))
  rma.load_at(0, 1, False, 32, 2, 0) |> should.equal(Ok(1))
  rma.load_at(0, 1, False, 32, 3, 0) |> should.equal(Ok(2))
  rt_meter.fuel_consumed() |> should.equal(3)
}

// `init` from a dropped (ε) segment traps for n>0, no-ops for n=0; a trap charges no fuel.
pub fn cell_init_dropped_segment_test() {
  rt_meter.reset_fuel()
  seed_cell_1page()
  rma.init(0, <<>>, 0, 0, 1) |> should.equal(Error(MemoryOutOfBounds))
  rt_meter.fuel_consumed() |> should.equal(0)
  rma.init(0, <<>>, 0, 0, 0) |> should.equal(Ok(Nil))
  rma.init(0, <<9, 8, 7>>, 4, 0, 3) |> should.equal(Ok(Nil))
  rma.load_at(0, 1, False, 32, 4, 0) |> should.equal(Ok(9))
  rt_meter.fuel_consumed() |> should.equal(3)
}

// Metered parity: a cell `fill` and a threaded `t_fill` of the same count debit IDENTICAL fuel.
pub fn cell_threaded_fill_metered_parity_test() {
  rt_meter.reset_fuel()
  seed_cell_1page()
  let assert Ok(Nil) = rma.fill(0, 0, 0x01, 20)
  let cell_fuel = rt_meter.fuel_consumed()

  rt_meter.reset_fuel()
  let st =
    rt_state.fresh(StateDecl(
      mem: rma.fresh(1, Some(1), big_cap),
      globals: [],
      table: dynamic.nil(),
    ))
  let assert Ok(_st) = rma.t_fill(st, 0, 0, 0x01, 20)
  let threaded_fuel = rt_meter.fuel_consumed()

  cell_fuel |> should.equal(20)
  threaded_fuel |> should.equal(cell_fuel)
}

// ───────────────────────────── 18. Multi-memory routing (atomics threaded, hand-built 2-mem state) ─────────────────────────────

/// A threaded InstanceState with TWO independent 1-page atomics memories (indices 0 and 1).
fn two_mem_state() -> InstanceState {
  InstanceState(
    mems: [rma.fresh(1, Some(1), big_cap), rma.fresh(1, Some(1), big_cap)],
    globals: dict.new(),
    tables: [],
    dropped_data: set.new(),
    dropped_elem: set.new(),
    ref_globals: dict.new(),
  )
}

pub fn threaded_cross_memory_copy_test() {
  let st = two_mem_state()
  let assert Ok(_) = rma.t_store_at(st, 1, 1, 0, 0xAB, 0)
  // Copy 1 byte from memory 1 (src) to memory 0 (dst) at address 5. The refs mutate in place, so
  // the SAME st threads through; read back through it.
  let assert Ok(st) = rma.t_copy(st, 0, 1, 5, 0, 1)
  rma.t_load_at(st, 0, 1, False, 32, 5, 0) |> should.equal(Ok(0xAB))
  rma.t_load_at(st, 1, 1, False, 32, 0, 0) |> should.equal(Ok(0xAB))
  rma.t_load_at(st, 0, 1, False, 32, 0, 0) |> should.equal(Ok(0))
}

pub fn threaded_fill_init_second_memory_test() {
  let st = two_mem_state()
  let assert Ok(_) = rma.t_fill(st, 1, 0, 0x77, 4)
  rma.t_load_at(st, 1, 4, False, 32, 0, 0) |> should.equal(Ok(0x77777777))
  rma.t_load_at(st, 0, 4, False, 32, 0, 0) |> should.equal(Ok(0))
  let assert Ok(_) = rma.t_init(st, 0, <<1, 2, 3, 4>>, 8, 0, 4)
  rma.t_load_at(st, 0, 1, False, 32, 8, 0) |> should.equal(Ok(1))
  rma.t_load_at(st, 0, 1, False, 32, 11, 0) |> should.equal(Ok(4))
}

// ───────────────────────────── 19. memory64 (P6-08, §D) — fail-closed gate + the tiny bounded edge ─────────────────────────────
//
// A 64-bit memory's effective max almost always vastly exceeds the node-safe reserve cap, so an
// over-cap / unbounded 64-bit atomics binding is FAIL-CLOSED REJECTED at link time (never a silent
// 256 TiB pre-alloc, never a silent paged degrade). A TINY BOUNDED 64-bit memory IS admitted and
// runs byte-identically to paged/oracle — a 64-bit TYPE does not imply a huge SIZE (§D).

// `reservation64` is the idx-aware SINGLE source unit 09 uses to admit-or-reject a 64-bit binding:
// reserve = max(min, effective_max64) must be <= reserve_cap. A tiny bounded 64-bit memory engages.
pub fn reservation64_tiny_bounded_engages_test() {
  rma.reservation64(1, Some(8), rt_mem.mem64_hard_max_pages, reserve_cap)
  |> should.equal(Ok(8))
  // reserve = max(min, eff): min dominates when larger.
  rma.reservation64(10, Some(8), rt_mem.mem64_hard_max_pages, reserve_cap)
  |> should.equal(Ok(10))
  // Exactly at the reserve cap is admissible.
  rma.reservation64(
    1,
    Some(reserve_cap),
    rt_mem.mem64_hard_max_pages,
    reserve_cap,
  )
  |> should.equal(Ok(reserve_cap))
}

// An unbounded / over-cap 64-bit memory is fail-closed rejected (never degraded, never pre-alloc'd).
pub fn reservation64_over_cap_rejected_test() {
  // Unbounded: eff folds min(mem64_cap, 2^32) >> reserve_cap → REJECT.
  rma.reservation64(1, None, rt_mem.mem64_hard_max_pages, reserve_cap)
  |> should.equal(Error(Nil))
  // A bounded-but-too-large declared max is also rejected.
  rma.reservation64(1, Some(5000), rt_mem.mem64_hard_max_pages, reserve_cap)
  |> should.equal(Error(Nil))
  // A huge declared max within the 2^48-page type range is still over the reserve cap.
  rma.reservation64(
    1,
    Some(1_000_000),
    rt_mem.mem64_hard_max_pages,
    reserve_cap,
  )
  |> should.equal(Error(Nil))
}

// `a_fresh64` reached with an over-cap reservation (unreachable post-validation) FAILS CLOSED (a
// node-safe panic) — never a silent 256 TiB pre-allocation.
pub fn a_fresh64_over_cap_panics_test() {
  catch_thunk(fn() {
    rma.a_fresh64(1, None, rt_mem.mem64_hard_max_pages, reserve_cap)
  })
  |> result.is_error
  |> should.be_true
}

// A tiny bounded 64-bit memory engages AtomicsBacked and runs correctly (load/store/grow) — the
// §D admitted edge: its addresses are all within word range, gather/scatter is bignum-safe.
pub fn a_fresh64_tiny_bounded_runs_test() {
  let a = rma.a_fresh64(1, Some(8), rt_mem.mem64_hard_max_pages, reserve_cap)
  let assert Ok(a) = rma.a_store(a, 8, 100, 0x0123456789ABCDEF, 0)
  rma.a_load(a, 8, False, 64, 100, 0) |> should.equal(Ok(0x0123456789ABCDEF))
  // grow within the tiny bound (1 → 8), then -1 beyond it (would be 9 > 8).
  let #(r1, a) = rma.a_grow(a, 7)
  r1 |> should.equal(1)
  let #(r2, _a) = rma.a_grow(a, 1)
  r2 |> should.equal(-1)
}

// The small-memory differential over a TINY BOUNDED 64-bit memory: atomics ≡ paged ≡ oracle after
// every op AND byte-for-byte flat image — proving a 64-bit memory runs correctly on atomics (§E.1).
fn run_differential64(count: Int, seed: Int) -> Nil {
  let cap = rt_mem.mem64_hard_max_pages
  let a = rma.a_fresh64(1, Some(2), cap, reserve_cap)
  let m = rt_mem.fresh_mem64(1, Some(2), cap, rt_mem.default_chunk_bytes)
  let o = rt_mem.o_fresh64(1, Some(2), cap)
  diff_loop(a, m, o, seed, count)
}

pub fn differential64_seed_a_test() {
  run_differential64(150, 0x640)
}

pub fn differential64_seed_b_test() {
  run_differential64(200, 0x641)
}
