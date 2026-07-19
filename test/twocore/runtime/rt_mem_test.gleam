//// Spec-grounded tests for `rt_mem` (unit 04) — the `paged` linear memory + the flat-binary
//// `rebuild` oracle.
////
//// These assert WebAssembly linear-memory SEMANTICS (not whatever the impl emits), citing
//// the spec, and hold BOTH the paged impl and the oracle to the same corner cases (a shared
//// bug must not hide — E4). The op set mirrors the official `memory_trap`/`address`/
//// `endianness`/`float_memory`/`memory_size`/`memory_redundancy` `.wast`; those are wired
//// END-TO-END at the capstone (unit 11), once decode/lower/emit reach memory ops — here we
//// call rt_mem's API directly (there is no pipeline path to memory yet).
////
//// Spec refs:
//// - exec/instructions (load/store, memory.size/grow):
////   <https://webassembly.github.io/spec/core/exec/instructions.html>
//// - exec/modules (active data init): <https://webassembly.github.io/spec/core/exec/modules.html>
//// - syntax/values (little-endian, two's complement, IEEE bits):
////   <https://webassembly.github.io/spec/core/syntax/values.html>
////
//// Structure: (1) spec-corner tests, each run on BOTH impls; (2) a randomized DIFFERENTIAL
//// suite (paged ≡ oracle) across several chunk sizes; (3) cell-backed wrapper tests
//// (seed → op → observe persistence + grow fuel); (4) a constant-space store-loop smoke.

import gleam/dict
import gleam/dynamic
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleeunit/should
import twocore/frontend/wasm/validate
import twocore/ir.{MemoryOutOfBounds}
import twocore/runtime/instance
import twocore/runtime/rt_mem
import twocore/runtime/rt_meter
import twocore/runtime/rt_state.{
  type InstanceState, FullDecl, InstanceState, StateDecl,
}

// Page byte length; one fresh page = 65536 bytes.
const page: Int = 65_536

/// A generous Safe cap so the spec-corner tests are governed by the declared max / hard cap,
/// not by `safe_cap` (which unit 11 owns). `100_000 > 65_536`, so it never binds below the
/// 65536-page hard cap.
const big_cap: Int = 100_000

// ───────────────────────────── 1. Little-endian multi-byte layout (endianness.wast) ─────────────────────────────

// Per the spec all loads/stores are little-endian: storing `0x04030201` as an i32 lays bytes
// `01 02 03 04` at +0..+3, and an i32 load reads them back as `0x04030201`.

pub fn le_layout_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  let assert Ok(m) = rt_mem.mem_store(m, 4, 0, 0x04030201, 0)
  // Each byte, low-to-high.
  rt_mem.mem_load(m, 1, False, 32, 0, 0) |> should.equal(Ok(0x01))
  rt_mem.mem_load(m, 1, False, 32, 1, 0) |> should.equal(Ok(0x02))
  rt_mem.mem_load(m, 1, False, 32, 2, 0) |> should.equal(Ok(0x03))
  rt_mem.mem_load(m, 1, False, 32, 3, 0) |> should.equal(Ok(0x04))
  // The whole i32 reads back identically (redundant load after store — memory_redundancy).
  rt_mem.mem_load(m, 4, False, 32, 0, 0) |> should.equal(Ok(0x04030201))
}

pub fn le_layout_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  let assert Ok(o) = rt_mem.o_store(o, 4, 0, 0x04030201, 0)
  rt_mem.o_load(o, 1, False, 32, 0, 0) |> should.equal(Ok(0x01))
  rt_mem.o_load(o, 1, False, 32, 1, 0) |> should.equal(Ok(0x02))
  rt_mem.o_load(o, 1, False, 32, 2, 0) |> should.equal(Ok(0x03))
  rt_mem.o_load(o, 1, False, 32, 3, 0) |> should.equal(Ok(0x04))
  rt_mem.o_load(o, 4, False, 32, 0, 0) |> should.equal(Ok(0x04030201))
}

// ───────────────────────────── 2. Sign vs zero extend × result width ─────────────────────────────

// `loadN_s` sign-extends to the operand width; `loadN_u` zero-extends. `result_width`
// disambiguates `i32.load8_s` (→ 0xFFFFFF80) from `i64.load8_s` (→ 0xFF..FF80) for byte 0x80,
// and the all-ones byte 0xFF.

pub fn sign_zero_extend_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  let assert Ok(m) = rt_mem.mem_store(m, 1, 0, 0x80, 0)
  let assert Ok(m) = rt_mem.mem_store(m, 1, 1, 0xFF, 0)
  // 0x80: i32.load8_s, i64.load8_s, load8_u.
  rt_mem.mem_load(m, 1, True, 32, 0, 0) |> should.equal(Ok(0xFFFFFF80))
  rt_mem.mem_load(m, 1, True, 64, 0, 0) |> should.equal(Ok(0xFFFFFFFFFFFFFF80))
  rt_mem.mem_load(m, 1, False, 32, 0, 0) |> should.equal(Ok(0x80))
  // 0xFF.
  rt_mem.mem_load(m, 1, True, 32, 1, 0) |> should.equal(Ok(0xFFFFFFFF))
  rt_mem.mem_load(m, 1, True, 64, 1, 0)
  |> should.equal(Ok(0xFFFFFFFFFFFFFFFF))
  rt_mem.mem_load(m, 1, False, 32, 1, 0) |> should.equal(Ok(0xFF))
}

pub fn sign_zero_extend_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  let assert Ok(o) = rt_mem.o_store(o, 1, 0, 0x80, 0)
  let assert Ok(o) = rt_mem.o_store(o, 1, 1, 0xFF, 0)
  rt_mem.o_load(o, 1, True, 32, 0, 0) |> should.equal(Ok(0xFFFFFF80))
  rt_mem.o_load(o, 1, True, 64, 0, 0) |> should.equal(Ok(0xFFFFFFFFFFFFFF80))
  rt_mem.o_load(o, 1, False, 32, 0, 0) |> should.equal(Ok(0x80))
  rt_mem.o_load(o, 1, True, 32, 1, 0) |> should.equal(Ok(0xFFFFFFFF))
  rt_mem.o_load(o, 1, True, 64, 1, 0) |> should.equal(Ok(0xFFFFFFFFFFFFFFFF))
  rt_mem.o_load(o, 1, False, 32, 1, 0) |> should.equal(Ok(0xFF))
}

// `i64.load16_s` of 0x8000 → 0xFFFFFFFFFFFF8000; `i64.load32_s` of 0x80000000 → high bits set.
pub fn wide_sign_extend_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  let assert Ok(m) = rt_mem.mem_store(m, 2, 0, 0x8000, 0)
  let assert Ok(m) = rt_mem.mem_store(m, 4, 8, 0x80000000, 0)
  rt_mem.mem_load(m, 2, True, 64, 0, 0)
  |> should.equal(Ok(0xFFFFFFFFFFFF8000))
  rt_mem.mem_load(m, 2, True, 32, 0, 0) |> should.equal(Ok(0xFFFF8000))
  rt_mem.mem_load(m, 4, True, 64, 8, 0)
  |> should.equal(Ok(0xFFFFFFFF80000000))
  rt_mem.mem_load(m, 4, False, 64, 8, 0) |> should.equal(Ok(0x80000000))
}

// ───────────────────────────── 3. Zero-fill (never-written + freshly grown) ─────────────────────────────

// A never-written in-bounds byte reads 0; every byte of a freshly grown page reads 0 (the
// sparse default-zero map gives this for free). (memory.wast)

pub fn zero_fill_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(3), big_cap, rt_mem.default_chunk_bytes)
  // Never-written bytes at assorted in-bounds offsets read 0.
  rt_mem.mem_load(m, 1, False, 32, 0, 0) |> should.equal(Ok(0))
  rt_mem.mem_load(m, 4, False, 32, 12_345, 0) |> should.equal(Ok(0))
  rt_mem.mem_load(m, 8, False, 64, page - 8, 0) |> should.equal(Ok(0))
  // Grow one page; every byte of the new page reads 0.
  let #(old, m) = rt_mem.mem_grow(m, 1)
  old |> should.equal(1)
  rt_mem.mem_load(m, 1, False, 32, page, 0) |> should.equal(Ok(0))
  rt_mem.mem_load(m, 8, False, 64, 2 * page - 8, 0) |> should.equal(Ok(0))
}

pub fn zero_fill_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(3), big_cap)
  rt_mem.o_load(o, 1, False, 32, 0, 0) |> should.equal(Ok(0))
  rt_mem.o_load(o, 4, False, 32, 12_345, 0) |> should.equal(Ok(0))
  let #(old, o) = rt_mem.o_grow(o, 1)
  old |> should.equal(1)
  rt_mem.o_load(o, 1, False, 32, page, 0) |> should.equal(Ok(0))
}

// ───────────────────────────── 4. No-wrap effective address (memory_trap / address.wast) ─────────────────────────────

// ea = addr + offset is a bignum; it is NEVER reduced mod 2^32. addr = 0xFFFFFFFF with a
// large static offset must TRAP, not wrap to a small in-bounds ea.

pub fn no_wrap_ea_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(2), big_cap, rt_mem.default_chunk_bytes)
  // 0xFFFFFFFF + 100 = 0x10000_0063, far past byte_len = 65536. Must trap (no wrap to 99).
  rt_mem.mem_load(m, 4, False, 32, 0xFFFFFFFF, 100)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.mem_store(m, 4, 0xFFFFFFFF, 0xDEADBEEF, 100)
  |> should.equal(Error(MemoryOutOfBounds))
  // A wrap-bug would have computed ea = 99 (in bounds). Prove byte 99 is untouched (still 0).
  rt_mem.mem_load(m, 4, False, 32, 99, 0) |> should.equal(Ok(0))
}

pub fn no_wrap_ea_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(2), big_cap)
  rt_mem.o_load(o, 4, False, 32, 0xFFFFFFFF, 100)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.o_store(o, 4, 0xFFFFFFFF, 0xDEADBEEF, 100)
  |> should.equal(Error(MemoryOutOfBounds))
}

// ───────────────────────────── 5. Exact-length off-by-one (address.wast) ─────────────────────────────

// An access ending EXACTLY at byte_len is in bounds; one byte past traps.

pub fn off_by_one_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  // Last in-bounds i32: ea = 65532, ea+4 = 65536 == byte_len → OK.
  rt_mem.mem_load(m, 4, False, 32, page - 4, 0) |> should.equal(Ok(0))
  // One byte further: ea = 65533, ea+4 = 65537 > 65536 → trap.
  rt_mem.mem_load(m, 4, False, 32, page - 3, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  // Last single byte in bounds; first byte past traps.
  rt_mem.mem_load(m, 1, False, 32, page - 1, 0) |> should.equal(Ok(0))
  rt_mem.mem_load(m, 1, False, 32, page, 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

pub fn off_by_one_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  rt_mem.o_load(o, 4, False, 32, page - 4, 0) |> should.equal(Ok(0))
  rt_mem.o_load(o, 4, False, 32, page - 3, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.o_load(o, 1, False, 32, page - 1, 0) |> should.equal(Ok(0))
  rt_mem.o_load(o, 1, False, 32, page, 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

// ───────────────────────────── 6. Partial multi-byte store traps with ZERO mutation (E3) ─────────────────────────────

// A multi-byte store straddling byte_len traps BEFORE any byte is written — including the
// in-bounds prefix. We seed a known i32, attempt a straddling store, and prove every byte is
// unchanged.

pub fn partial_store_zero_mutation_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  // Seed bytes at 65532..65535 = DD CC BB AA (i32 0xAABBCCDD, little-endian).
  let assert Ok(m) = rt_mem.mem_store(m, 4, page - 4, 0xAABBCCDD, 0)
  // Straddling store: ea = 65534, ea+4 = 65538 > 65536 → trap.
  rt_mem.mem_store(m, 4, page - 2, 0x11223344, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  // mem_store returns the input Mem untouched on error; the original `m` is unchanged.
  rt_mem.mem_load(m, 4, False, 32, page - 4, 0)
  |> should.equal(Ok(0xAABBCCDD))
  rt_mem.mem_load(m, 1, False, 32, page - 2, 0) |> should.equal(Ok(0xBB))
  rt_mem.mem_load(m, 1, False, 32, page - 1, 0) |> should.equal(Ok(0xAA))
}

pub fn partial_store_zero_mutation_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  let assert Ok(o) = rt_mem.o_store(o, 4, page - 4, 0xAABBCCDD, 0)
  rt_mem.o_store(o, 4, page - 2, 0x11223344, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.o_load(o, 4, False, 32, page - 4, 0)
  |> should.equal(Ok(0xAABBCCDD))
}

// ───────────────────────────── 7. memory.grow: OLD size, then -1 past max / cap (memory_size.wast) ─────────────────────────────

// grow returns the OLD size on success and -1 past the declared max / Safe cap / hard cap,
// allocating nothing; size reflects only successful grows.

pub fn grow_declared_max_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(3), big_cap, rt_mem.default_chunk_bytes)
  rt_mem.mem_size(m) |> should.equal(1)
  let #(r1, m) = rt_mem.mem_grow(m, 1)
  r1 |> should.equal(1)
  rt_mem.mem_size(m) |> should.equal(2)
  let #(r2, m) = rt_mem.mem_grow(m, 1)
  r2 |> should.equal(2)
  rt_mem.mem_size(m) |> should.equal(3)
  // Past the declared max (3): -1, allocate nothing, size unchanged.
  let #(r3, m) = rt_mem.mem_grow(m, 1)
  r3 |> should.equal(-1)
  rt_mem.mem_size(m) |> should.equal(3)
  // delta 0 is a successful no-op returning the current size.
  let #(r4, _m) = rt_mem.mem_grow(m, 0)
  r4 |> should.equal(3)
}

pub fn grow_declared_max_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(3), big_cap)
  let #(r1, o) = rt_mem.o_grow(o, 1)
  r1 |> should.equal(1)
  let #(r2, o) = rt_mem.o_grow(o, 1)
  r2 |> should.equal(2)
  let #(r3, o) = rt_mem.o_grow(o, 1)
  r3 |> should.equal(-1)
  rt_mem.o_size(o) |> should.equal(3)
}

// The Safe `safe_cap` binds when no max is declared (max_pages = None). Paged grow allocates
// nothing for unwritten pages, so we can probe the cap cheaply.
pub fn grow_safe_cap_paged_test() {
  // max = None, safe_cap = 5 → effective max 5.
  let m = rt_mem.fresh_mem(2, None, 5, rt_mem.default_chunk_bytes)
  let #(r1, m) = rt_mem.mem_grow(m, 3)
  r1 |> should.equal(2)
  rt_mem.mem_size(m) |> should.equal(5)
  let #(r2, m) = rt_mem.mem_grow(m, 1)
  r2 |> should.equal(-1)
  rt_mem.mem_size(m) |> should.equal(5)
}

// The 65536-page hard cap binds even when safe_cap/declared-max are larger. Paged pages cost
// nothing until written, so start near the cap and probe it without allocating gigabytes.
pub fn grow_hard_cap_paged_test() {
  // safe_cap huge, max None → effective max = min(200000, 65536) = 65536.
  let m = rt_mem.fresh_mem(65_535, None, 200_000, rt_mem.default_chunk_bytes)
  let #(r1, m) = rt_mem.mem_grow(m, 1)
  r1 |> should.equal(65_535)
  rt_mem.mem_size(m) |> should.equal(65_536)
  // One more page would be 65537 > 65536 → -1.
  let #(r2, _m) = rt_mem.mem_grow(m, 1)
  r2 |> should.equal(-1)
}

// A negative delta never grows (defensive; WASM delta is u32 so this is unreachable upstream).
pub fn grow_negative_delta_paged_test() {
  let m = rt_mem.fresh_mem(2, Some(4), big_cap, rt_mem.default_chunk_bytes)
  let #(r, m) = rt_mem.mem_grow(m, -1)
  r |> should.equal(-1)
  rt_mem.mem_size(m) |> should.equal(2)
}

// ───────────────────────────── 8. f32/f64 round-trip preserves raw bits incl. NaN (float_memory.wast) ─────────────────────────────

// f32/f64 store/load are raw-byte moves over the IEEE bit pattern — never a BEAM-double
// round-trip (which would mangle NaN payloads / signalling bits). Store a NaN-payload pattern
// and read the identical bits back.

pub fn float_nan_roundtrip_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  // f64 signalling-NaN-ish payload, and -0.0.
  let f64_nan = 0x7FF8000000000001
  let f64_neg_zero = 0x8000000000000000
  // f32 quiet NaN with payload, and +Inf.
  let f32_nan = 0x7FC00001
  let f32_pos_inf = 0x7F800000
  let assert Ok(m) = rt_mem.mem_store(m, 8, 0, f64_nan, 0)
  let assert Ok(m) = rt_mem.mem_store(m, 8, 8, f64_neg_zero, 0)
  let assert Ok(m) = rt_mem.mem_store(m, 4, 16, f32_nan, 0)
  let assert Ok(m) = rt_mem.mem_store(m, 4, 20, f32_pos_inf, 0)
  rt_mem.mem_load(m, 8, False, 64, 0, 0) |> should.equal(Ok(f64_nan))
  rt_mem.mem_load(m, 8, False, 64, 8, 0) |> should.equal(Ok(f64_neg_zero))
  rt_mem.mem_load(m, 4, False, 32, 16, 0) |> should.equal(Ok(f32_nan))
  rt_mem.mem_load(m, 4, False, 32, 20, 0) |> should.equal(Ok(f32_pos_inf))
}

pub fn float_nan_roundtrip_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  let f64_nan = 0x7FF8000000000001
  let f32_nan = 0x7FC00001
  let assert Ok(o) = rt_mem.o_store(o, 8, 0, f64_nan, 0)
  let assert Ok(o) = rt_mem.o_store(o, 4, 8, f32_nan, 0)
  rt_mem.o_load(o, 8, False, 64, 0, 0) |> should.equal(Ok(f64_nan))
  rt_mem.o_load(o, 4, False, 32, 8, 0) |> should.equal(Ok(f32_nan))
}

// ───────────────────────────── 9. init_data: in-bounds writes exact bytes; OOB traps (instantiation abort) ─────────────────────────────

pub fn init_data_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  let assert Ok(m) = rt_mem.mem_init_data(m, 10, <<0xDE, 0xAD, 0xBE, 0xEF>>)
  rt_mem.mem_load(m, 1, False, 32, 10, 0) |> should.equal(Ok(0xDE))
  rt_mem.mem_load(m, 1, False, 32, 13, 0) |> should.equal(Ok(0xEF))
  // i32.load reads them little-endian: bytes DE AD BE EF → 0xEFBEADDE.
  rt_mem.mem_load(m, 4, False, 32, 10, 0) |> should.equal(Ok(0xEFBEADDE))
  // A segment that overruns byte_len traps (whole-range check, no partial write).
  rt_mem.mem_init_data(m, page - 2, <<1, 2, 3, 4>>)
  |> should.equal(Error(MemoryOutOfBounds))
  // The straddling segment wrote nothing: the last in-bounds byte is still 0.
  rt_mem.mem_load(m, 1, False, 32, page - 2, 0) |> should.equal(Ok(0))
}

pub fn init_data_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  let assert Ok(o) = rt_mem.o_init_data(o, 10, <<0xDE, 0xAD, 0xBE, 0xEF>>)
  rt_mem.o_load(o, 4, False, 32, 10, 0) |> should.equal(Ok(0xEFBEADDE))
  rt_mem.o_init_data(o, page - 2, <<1, 2, 3, 4>>)
  |> should.equal(Error(MemoryOutOfBounds))
}

// An empty active segment is always in bounds (even at byte_len), and is a no-op.
pub fn init_data_empty_segment_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  rt_mem.mem_init_data(m, page, <<>>) |> should.be_ok
}

// ───────────────────────────── 10. Chunk-boundary-crossing access (alignment is non-semantic) ─────────────────────────────

// An unaligned access that crosses a physical chunk boundary must read/write correctly —
// alignment is only a hint. With chunk = 65, an i32 at addr 63 spans chunk 0 and chunk 1.
pub fn chunk_boundary_crossing_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, 65)
  let assert Ok(m) = rt_mem.mem_store(m, 4, 63, 0x04030201, 0)
  // Whole i32 reads back across the boundary.
  rt_mem.mem_load(m, 4, False, 32, 63, 0) |> should.equal(Ok(0x04030201))
  // Each byte sits where expected: 63,64 in chunk 0; 65,66 in chunk 1.
  rt_mem.mem_load(m, 1, False, 32, 63, 0) |> should.equal(Ok(0x01))
  rt_mem.mem_load(m, 1, False, 32, 64, 0) |> should.equal(Ok(0x02))
  rt_mem.mem_load(m, 1, False, 32, 65, 0) |> should.equal(Ok(0x03))
  rt_mem.mem_load(m, 1, False, 32, 66, 0) |> should.equal(Ok(0x04))
  // A neighbouring byte is untouched.
  rt_mem.mem_load(m, 1, False, 32, 62, 0) |> should.equal(Ok(0))
  rt_mem.mem_load(m, 1, False, 32, 67, 0) |> should.equal(Ok(0))
}

// ───────────────────────────── 11. DIFFERENTIAL: paged ≡ oracle over randomized streams (E4) ─────────────────────────────

// One observable result of an op (loaded value/trap, store ok/trap, grow result, init
// ok/trap) — compared between paged and oracle in lockstep.
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

/// A 31-bit linear-congruential PRNG (deterministic so a failure reproduces). Returns the
/// next state in `[0, 2^31)`.
fn lcg(state: Int) -> Int {
  let next = state * 1_103_515_245 + 12_345
  bitand(next, 0x7FFFFFFF)
}

@external(erlang, "erlang", "band")
fn bitand(a: Int, b: Int) -> Int

@external(erlang, "erlang", "bor")
fn bitor(a: Int, b: Int) -> Int

@external(erlang, "erlang", "bsl")
fn bsl(a: Int, b: Int) -> Int

/// Drive paged and oracle through the same `count` random ops at physical chunk size `chunk`;
/// assert identical results+traps at every step and an identical final flat byte image.
fn run_differential(chunk: Int, count: Int, seed: Int) -> Nil {
  let m = rt_mem.fresh_mem(1, Some(4), big_cap, chunk)
  let o = rt_mem.o_fresh(1, Some(4), big_cap)
  let #(m, o) = diff_loop(m, o, seed, count)
  // Final byte image must be identical (catches any silent LE/sparse-zero/boundary drift).
  rt_mem.mem_flat(m) |> should.equal(rt_mem.o_flat(o))
}

fn diff_loop(
  m: rt_mem.Mem,
  o: rt_mem.OMem,
  seed: Int,
  remaining: Int,
) -> #(rt_mem.Mem, rt_mem.OMem) {
  case remaining <= 0 {
    True -> #(m, o)
    False -> {
      let #(op, seed) = gen_op(rt_mem.mem_size(m) * page, seed)
      let #(m, rp) = apply_paged(m, op)
      let #(o, ro) = apply_oracle(o, op)
      // The security boundary: paged and oracle must agree on value AND trap, every step.
      rp |> should.equal(ro)
      diff_loop(m, o, seed, remaining - 1)
    }
  }
}

fn apply_paged(m: rt_mem.Mem, op: Op) -> #(rt_mem.Mem, OpResult) {
  case op {
    OpLoad(b, s, w, a, off) -> #(m, RLoad(rt_mem.mem_load(m, b, s, w, a, off)))
    OpStore(b, a, v, off) ->
      case rt_mem.mem_store(m, b, a, v, off) {
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
    // Same-memory copy: dst_m and src_m are the same value (overlap → memmove).
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
    OpLoad(b, s, w, a, off) -> #(o, RLoad(rt_mem.o_load(o, b, s, w, a, off)))
    OpStore(b, a, v, off) ->
      case rt_mem.o_store(o, b, a, v, off) {
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

/// Generate a random op given the current `byte_len`. Addresses span in-bounds, a few bytes
/// past the end, and occasionally `0xFFFFFFFF` (the no-wrap probe); widths/signs/values are
/// random; grows stay within the 4-page max.
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
      // memory.fill: dest spanning in/out of bounds, low-byte value, small count (incl. 0).
      let s2 = lcg(s)
      let #(dest, s3) = pick_addr(s2, byte_len)
      let s4 = lcg(s3)
      #(OpFill(dest, pick_value(s4), s4 % 7), s4)
    }
    k if k < 13 -> {
      // memory.copy on ONE memory (dst_m == src_m) → exercises OVERLAP both directions.
      let s2 = lcg(s)
      let #(dst, s3) = pick_addr(s2, byte_len)
      let #(src, s4) = pick_addr(s3, byte_len)
      #(OpCopy(dst, src, s4 % 7), s4)
    }
    _ -> {
      // memory.init from a random-length segment (occasionally ε — the dropped-segment case);
      // src may exceed the segment length so the segment bound is exercised.
      let s2 = lcg(s)
      let seg_len = s2 % 6
      let #(seg, s3) = rand_bytes(seg_len, s2)
      let #(dst, s4) = pick_addr(s3, byte_len)
      let s5 = lcg(s4)
      let src = s5 % { seg_len + 3 }
      let s6 = lcg(s5)
      #(OpBulkInit(seg, dst, src, s6 % 7), s6)
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

/// Mostly in-bounds (a touch past byte_len so OOB is exercised), occasionally `0xFFFFFFFF`
/// (the no-wrap probe — must trap, never wrap).
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
  bitor(bsl(a, 33), b)
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

// Several chunk sizes — including the 64-byte REFC edge + 1, an odd size, and the default —
// so the differential proves correctness is chunk-size-independent.
pub fn differential_chunk_65_test() {
  run_differential(65, 250, 0x1234)
}

pub fn differential_chunk_100_test() {
  run_differential(100, 250, 0xBEEF)
}

pub fn differential_chunk_default_test() {
  run_differential(rt_mem.default_chunk_bytes, 250, 0xC0FFEE)
}

pub fn differential_chunk_4096_alt_seed_test() {
  run_differential(4096, 300, 0x5EED)
}

// ───────────────────────────── 12. Cell-backed wrappers (seed → op → observe persistence) ─────────────────────────────

// The public load/store/size/grow read+write the `mem` slot of THIS process's cell. We seed a
// fresh memory via rt_state, exercise the wrappers, and observe persistence + isolation.

pub fn cell_store_load_roundtrip_test() {
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(2), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rt_mem.store(4, 0, 0x04030201, 0) |> should.equal(Ok(Nil))
  // The store persisted in the cell across the separate load call.
  rt_mem.load(4, False, 32, 0, 0) |> should.equal(Ok(0x04030201))
  rt_mem.load(1, False, 32, 0, 0) |> should.equal(Ok(0x01))
  rt_mem.load(1, True, 32, 3, 0) |> should.equal(Ok(0x04))
  // An out-of-bounds load through the cell traps.
  rt_mem.load(4, False, 32, page, 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

pub fn cell_size_and_grow_test() {
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(3), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rt_mem.size() |> should.equal(1)
  rt_mem.grow(1) |> should.equal(1)
  rt_mem.size() |> should.equal(2)
  // Past the declared max: -1, no allocation, size unchanged.
  rt_mem.grow(5) |> should.equal(-1)
  rt_mem.size() |> should.equal(2)
  // The grown page is zero and writable.
  rt_mem.load(4, False, 32, page, 0) |> should.equal(Ok(0))
  rt_mem.store(4, page, 0xCAFEBABE, 0) |> should.equal(Ok(Nil))
  rt_mem.load(4, False, 32, page, 0) |> should.equal(Ok(0xCAFEBABE))
}

pub fn cell_grow_charges_fuel_proportional_test() {
  rt_meter.reset_fuel()
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(4), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  // A successful grow of 2 pages charges 2 * 65536 bytes of fuel (proportional to allocation).
  rt_mem.grow(2) |> should.equal(1)
  rt_meter.fuel_consumed() |> should.equal(2 * page)
  // A FAILED grow (past max) allocates nothing and charges nothing.
  rt_mem.grow(100) |> should.equal(-1)
  rt_meter.fuel_consumed() |> should.equal(2 * page)
}

pub fn cell_isolation_between_seeds_test() {
  // Seed A, write a byte.
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rt_mem.store(1, 42, 0xAB, 0) |> should.equal(Ok(Nil))
  rt_mem.load(1, False, 32, 42, 0) |> should.equal(Ok(0xAB))
  // Re-seed: fresh memory. A's write must NOT bleed through.
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rt_mem.load(1, False, 32, 42, 0) |> should.equal(Ok(0))
}

pub fn cell_partial_store_trap_no_mutation_test() {
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  let assert Ok(Nil) = rt_mem.store(4, page - 4, 0xAABBCCDD, 0)
  // A straddling store traps and (since the cell is not written on the error path) leaves the
  // prior bytes intact.
  rt_mem.store(4, page - 2, 0x11223344, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.load(4, False, 32, page - 4, 0) |> should.equal(Ok(0xAABBCCDD))
}

pub fn cell_init_data_test() {
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rt_mem.init_data(8, <<0xDE, 0xAD, 0xBE, 0xEF>>) |> should.equal(Ok(Nil))
  rt_mem.load(4, False, 32, 8, 0) |> should.equal(Ok(0xEFBEADDE))
  rt_mem.init_data(page - 2, <<1, 2, 3, 4>>)
  |> should.equal(Error(MemoryOutOfBounds))
}

// ───────────────────────────── 13. Constant-space store loop (E1, D8 #4) ─────────────────────────────

// ~100k stores threaded through the pure paged core: each store supersedes the prior Mem
// (only the latest is live; superseded versions are garbage and touched chunks are shared).
// We assert the loop completes and the final read is correct — exercising the
// supersede-and-share path the constant-space property rests on. (The precise allocation-
// profile measurement is the capstone, unit 11.)
pub fn constant_space_store_loop_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  let m = store_loop(m, 0, 100_000)
  // After 100k superseding stores, the paged structure is still sound: a fresh store/load
  // round-trips, proving the supersede-and-share path held up across the whole loop.
  let assert Ok(m) = rt_mem.mem_store(m, 4, 128, 0x0BADF00D, 0)
  rt_mem.mem_load(m, 4, False, 32, 128, 0) |> should.equal(Ok(0x0BADF00D))
}

fn store_loop(m: rt_mem.Mem, i: Int, n: Int) -> rt_mem.Mem {
  case i >= n {
    True -> m
    False -> {
      // Vary the address across the page so many chunks are touched (and shared).
      let addr = i * 4 % { page - 4 }
      let assert Ok(m) = rt_mem.mem_store(m, 4, addr, i, 0)
      store_loop(m, i + 1, n)
    }
  }
}

// ───────────────────────────── 14. Tier-P threaded wrappers (thread the InstanceState record) ─────────────────────────────

// The paged threaded family (unit 04): project st.mem → drive the pure mem_* core → inject back
// via rt_state.with_mem. Because paged memory is IMMUTABLE, a mutator returns a REBOUND record
// (a new mem) — reading through the pre-store record must NOT see the write (the contrast with
// the mutable atomics tier, whose t_store returns the same record with an in-place-mutated ref).

/// Build a threaded InstanceState whose `mem` slot holds a fresh paged memory.
fn paged_threaded_state() -> rt_state.InstanceState {
  rt_state.fresh(StateDecl(
    mem: rt_mem.fresh(1, Some(4), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
}

// t_store returns a REBOUND st: reading through the returned record sees the store, but reading
// through the ORIGINAL (pre-store) record does NOT — paged memory is a value, not mutated in place.
pub fn threaded_store_rebinds_immutably_test() {
  let st = paged_threaded_state()
  let assert Ok(st2) = rt_mem.t_store(st, 4, 0, 0x04030201, 0)
  rt_mem.t_load(st2, 4, False, 32, 0, 0) |> should.equal(Ok(0x04030201))
  // The pre-store record is untouched (immutable): its byte 0 is still 0.
  rt_mem.t_load(st, 4, False, 32, 0, 0) |> should.equal(Ok(0))
}

// t_load / t_size are read-only.
pub fn threaded_read_only_test() {
  let st = paged_threaded_state()
  rt_mem.t_size(st) |> should.equal(1)
  rt_mem.t_load(st, 4, False, 32, 0, 0) |> should.equal(Ok(0))
  // An out-of-bounds threaded load traps.
  rt_mem.t_load(st, 4, False, 32, page, 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

// t_grow returns OLD pages + a rebound record whose size reflects the grow; -1 past max unchanged.
pub fn threaded_grow_rebinds_test() {
  let st = paged_threaded_state()
  let #(r1, st) = rt_mem.t_grow(st, 2)
  r1 |> should.equal(1)
  rt_mem.t_size(st) |> should.equal(3)
  let #(r2, st) = rt_mem.t_grow(st, 1)
  r2 |> should.equal(3)
  rt_mem.t_size(st) |> should.equal(4)
  let #(r3, st) = rt_mem.t_grow(st, 1)
  r3 |> should.equal(-1)
  rt_mem.t_size(st) |> should.equal(4)
  // The grown page is zero and writable through the threaded record.
  let assert Ok(st) = rt_mem.t_store(st, 4, 3 * page, 0xCAFEBABE, 0)
  rt_mem.t_load(st, 4, False, 32, 3 * page, 0) |> should.equal(Ok(0xCAFEBABE))
}

// P2 metered parity: a metered paged THREADED grow and a metered paged CELL grow debit an
// IDENTICAL fuel amount (delta * page_bytes) — so metered+threaded == metered+cell (E3/G7).
pub fn threaded_grow_charges_same_fuel_as_cell_test() {
  // Cell grow of 3 pages.
  rt_meter.reset_fuel()
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(8), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rt_mem.grow(3) |> should.equal(1)
  let cell_fuel = rt_meter.fuel_consumed()

  // Threaded grow of 3 pages.
  rt_meter.reset_fuel()
  let st =
    rt_state.fresh(StateDecl(
      mem: rt_mem.fresh(1, Some(8), big_cap),
      globals: [],
      table: dynamic.nil(),
    ))
  let #(r, _st) = rt_mem.t_grow(st, 3)
  r |> should.equal(1)
  let threaded_fuel = rt_meter.fuel_consumed()

  cell_fuel |> should.equal(3 * page)
  threaded_fuel |> should.equal(cell_fuel)
}

// A failed threaded grow (past max) charges nothing and returns the unchanged record.
pub fn threaded_grow_failed_charges_nothing_test() {
  rt_meter.reset_fuel()
  let st = paged_threaded_state()
  let #(r, st) = rt_mem.t_grow(st, 100)
  r |> should.equal(-1)
  rt_mem.t_size(st) |> should.equal(1)
  rt_meter.fuel_consumed() |> should.equal(0)
}

pub fn threaded_init_data_test() {
  let st = paged_threaded_state()
  let assert Ok(st) = rt_mem.t_init_data(st, 8, <<0xDE, 0xAD, 0xBE, 0xEF>>)
  rt_mem.t_load(st, 4, False, 32, 8, 0) |> should.equal(Ok(0xEFBEADDE))
  rt_mem.t_init_data(st, page - 2, <<1, 2, 3, 4>>)
  |> should.equal(Error(MemoryOutOfBounds))
}

// The uniform differential hook over a cell Dynamic (paged): to_flat(mem_get()) == oracle image.
pub fn to_flat_dynamic_matches_oracle_test() {
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  let assert Ok(Nil) = rt_mem.store(4, 100, 0x04030201, 0)
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  let assert Ok(o) = rt_mem.o_store(o, 4, 100, 0x04030201, 0)
  rt_mem.to_flat(rt_state.mem_get()) |> should.equal(rt_mem.o_flat(o))
}

// ───────────────────────────── 15. Bulk memory spec corners (memory_fill/copy/init.wast, §4.4.9) ─────────────────────────────
//
// The finalized bulk-memory proposal (WebAssembly spec §4.4.9): eager bounds (strict `>`, checked
// UNCONDITIONALLY incl. n==0 — R10), no partial writes on trap, memmove-correct copy (R11), init
// bounded by BOTH the segment and the memory (a dropped/ε segment traps for n>0, no-ops for n=0).

/// A fresh 1-page paged memory (declared max 1) with a generous cap.
fn fresh1() -> rt_mem.Mem {
  rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
}

/// A fresh 1-page paged memory holding bytes `[0,1,2,3,4,5,6,7]` at offset 0.
fn seed_0_to_7() -> rt_mem.Mem {
  let assert Ok(m) =
    rt_mem.mem_init_data(fresh1(), 0, <<0, 1, 2, 3, 4, 5, 6, 7>>)
  m
}

/// The first 8 bytes of a paged memory as a list (for a compact image assertion).
fn bytes8(m: rt_mem.Mem) -> List(Int) {
  list.map([0, 1, 2, 3, 4, 5, 6, 7], fn(i) {
    let assert Ok(b) = rt_mem.mem_load(m, 1, False, 32, i, 0)
    b
  })
}

/// The first 8 bytes of an oracle memory as a list.
fn o_bytes8(o: rt_mem.OMem) -> List(Int) {
  list.map([0, 1, 2, 3, 4, 5, 6, 7], fn(i) {
    let assert Ok(b) = rt_mem.o_load(o, 1, False, 32, i, 0)
    b
  })
}

// `memory.fill` writes the LOW byte only, `count` times. fill(d, 0x12345678, 4) → 78 78 78 78.
pub fn fill_low_byte_paged_test() {
  let assert Ok(m) = rt_mem.mem_fill(fresh1(), 0, 0x12345678, 4)
  rt_mem.mem_load(m, 1, False, 32, 0, 0) |> should.equal(Ok(0x78))
  rt_mem.mem_load(m, 1, False, 32, 3, 0) |> should.equal(Ok(0x78))
  rt_mem.mem_load(m, 4, False, 32, 0, 0) |> should.equal(Ok(0x78787878))
  // Byte 4 is untouched.
  rt_mem.mem_load(m, 1, False, 32, 4, 0) |> should.equal(Ok(0))
  // A zero-count fill writes nothing.
  let assert Ok(m0) = rt_mem.mem_fill(m, 10, 0xFF, 0)
  rt_mem.mem_load(m0, 1, False, 32, 10, 0) |> should.equal(Ok(0))
}

pub fn fill_low_byte_oracle_test() {
  let assert Ok(o) =
    rt_mem.o_fill(rt_mem.o_fresh(1, Some(1), big_cap), 0, 0x12345678, 4)
  rt_mem.o_load(o, 4, False, 32, 0, 0) |> should.equal(Ok(0x78787878))
  rt_mem.o_load(o, 1, False, 32, 4, 0) |> should.equal(Ok(0))
}

// Eager bounds (R10): dest+count == byte_len succeeds; +1 traps with ZERO mutation; the exact
// n==0 boundary: fill(byte_len, v, 0) succeeds, fill(byte_len+1, v, 0) traps.
pub fn fill_eager_bounds_no_partial_write_paged_test() {
  // Seed a marker across the tail so a partial write would be observable.
  let assert Ok(m) = rt_mem.mem_store(fresh1(), 4, page - 4, 0xAABBCCDD, 0)
  // dest+count == byte_len is in bounds.
  rt_mem.mem_fill(m, page - 4, 0x11, 4) |> should.be_ok
  // dest+count == byte_len+1 traps.
  rt_mem.mem_fill(m, page - 3, 0x22, 4)
  |> should.equal(Error(MemoryOutOfBounds))
  // No partial write: the trapping fill's in-bounds prefix (bytes page-3, page-2, page-1) is
  // still the seeded pattern in the (untouched) input `m`.
  rt_mem.mem_load(m, 4, False, 32, page - 4, 0) |> should.equal(Ok(0xAABBCCDD))
  // R10 exact boundary at n==0.
  rt_mem.mem_fill(m, page, 0x33, 0) |> should.be_ok
  rt_mem.mem_fill(m, page + 1, 0x33, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  // A negative-index / negative-count fill traps.
  rt_mem.mem_fill(m, -1, 0x33, 1) |> should.equal(Error(MemoryOutOfBounds))
}

pub fn fill_r10_boundary_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  rt_mem.o_fill(o, page, 0x33, 0) |> should.be_ok
  rt_mem.o_fill(o, page + 1, 0x33, 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

// `memory.copy` is memmove: the §B.2 worked examples on [0..7] round-trip correctly in BOTH
// directions — the exact case a naive ascending byte-by-byte copy would corrupt.
pub fn copy_memmove_overlap_paged_test() {
  let m = seed_0_to_7()
  // copy(dst=1, src=0, count=3): naive ascending would give [0,0,0,0,..]; memmove → [0,0,1,2,..].
  let assert Ok(fwd) = rt_mem.mem_copy(m, m, 1, 0, 3)
  bytes8(fwd) |> should.equal([0, 0, 1, 2, 4, 5, 6, 7])
  // copy(dst=0, src=1, count=3): → [1,2,3,3,4,5,6,7].
  let assert Ok(bwd) = rt_mem.mem_copy(m, m, 0, 1, 3)
  bytes8(bwd) |> should.equal([1, 2, 3, 3, 4, 5, 6, 7])
}

pub fn copy_memmove_overlap_oracle_test() {
  let assert Ok(o) =
    rt_mem.o_init_data(rt_mem.o_fresh(1, Some(1), big_cap), 0, <<
      0, 1, 2, 3, 4, 5, 6, 7,
    >>)
  let assert Ok(fwd) = rt_mem.o_copy(o, o, 1, 0, 3)
  o_bytes8(fwd) |> should.equal([0, 0, 1, 2, 4, 5, 6, 7])
  let assert Ok(bwd) = rt_mem.o_copy(o, o, 0, 1, 3)
  o_bytes8(bwd) |> should.equal([1, 2, 3, 3, 4, 5, 6, 7])
}

// Eager bounds on BOTH ranges; a trapping copy leaves the destination unchanged (immutable input).
pub fn copy_eager_bounds_paged_test() {
  let m = seed_0_to_7()
  // src + count > byte_len traps.
  rt_mem.mem_copy(m, m, 0, page - 2, 4)
  |> should.equal(Error(MemoryOutOfBounds))
  // dst + count > byte_len traps.
  rt_mem.mem_copy(m, m, page - 2, 0, 4)
  |> should.equal(Error(MemoryOutOfBounds))
  // Neither wrote: the source image is intact.
  bytes8(m) |> should.equal([0, 1, 2, 3, 4, 5, 6, 7])
}

// Cross-memory copy on the pure core: reads memory 1 (src), writes memory 0 (dst); the source
// memory is untouched; and bounds use EACH memory's own length.
pub fn cross_memory_copy_paged_test() {
  let assert Ok(src) = rt_mem.mem_init_data(fresh1(), 0, <<10, 20, 30, 40, 50>>)
  // dst is 2 pages so it has room past `src`'s length — bounds must still use src's length.
  let dst = rt_mem.fresh_mem(2, Some(2), big_cap, rt_mem.default_chunk_bytes)
  let assert Ok(dst2) = rt_mem.mem_copy(dst, src, 5, 0, 3)
  // dst[5..7] == src[0..2].
  rt_mem.mem_load(dst2, 1, False, 32, 5, 0) |> should.equal(Ok(10))
  rt_mem.mem_load(dst2, 1, False, 32, 7, 0) |> should.equal(Ok(30))
  // dst elsewhere is 0; src is unchanged.
  rt_mem.mem_load(dst2, 1, False, 32, 0, 0) |> should.equal(Ok(0))
  rt_mem.mem_load(src, 1, False, 32, 0, 0) |> should.equal(Ok(10))
  // A copy that fits in `dst` but overruns `src` traps on src's length (per-memory bounds).
  rt_mem.mem_copy(dst, src, page, page - 2, 4)
  |> should.equal(Error(MemoryOutOfBounds))
}

// `memory.init` writes seg[src..src+count) at dst; eager bounds on the segment AND the memory.
pub fn init_from_segment_paged_test() {
  let m = fresh1()
  let seg = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE>>
  // init(dst=10, src=1, count=3) writes BB CC DD.
  let assert Ok(m2) = rt_mem.mem_init(m, seg, 10, 1, 3)
  rt_mem.mem_load(m2, 1, False, 32, 10, 0) |> should.equal(Ok(0xBB))
  rt_mem.mem_load(m2, 1, False, 32, 12, 0) |> should.equal(Ok(0xDD))
  rt_mem.mem_load(m2, 1, False, 32, 13, 0) |> should.equal(Ok(0))
  // src + count > len(seg) traps (3 + 3 = 6 > 5).
  rt_mem.mem_init(m, seg, 0, 3, 3) |> should.equal(Error(MemoryOutOfBounds))
  // dst + count > byte_len traps.
  rt_mem.mem_init(m, seg, page - 2, 0, 3)
  |> should.equal(Error(MemoryOutOfBounds))
}

// `memory.init` from a dropped (ε) segment: n>0 traps (src-bound), n=0 no-ops — exactly the spec
// behaviour `data.drop` then `memory.init` produces (R2). Modelled as an empty segment argument.
pub fn init_from_dropped_segment_paged_test() {
  let m = fresh1()
  rt_mem.mem_init(m, <<>>, 0, 0, 1) |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.mem_init(m, <<>>, 0, 0, 0) |> should.be_ok
  // R10 boundary carries to init: dst==byte_len with n=0 succeeds; dst>byte_len with n=0 traps.
  rt_mem.mem_init(m, <<>>, page, 0, 0) |> should.be_ok
  rt_mem.mem_init(m, <<>>, page + 1, 0, 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

pub fn init_from_dropped_segment_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  rt_mem.o_init(o, <<>>, 0, 0, 1) |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.o_init(o, <<>>, 0, 0, 0) |> should.be_ok
}

// No-wrap ea (E3) carries to bulk ops: a dest/dst near 2^32 with a count that would wrap to a
// small in-bounds index must TRAP, not wrap. (0xFFFFFFFF + 100 = 99 mod 2^32; must not be used.)
pub fn bulk_no_wrap_ea_paged_test() {
  let m = fresh1()
  rt_mem.mem_fill(m, 0xFFFFFFFF, 0x11, 100)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.mem_copy(m, m, 0xFFFFFFFF, 0, 4)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.mem_init(m, <<1, 2, 3, 4>>, 0xFFFFFFFF, 0, 4)
  |> should.equal(Error(MemoryOutOfBounds))
}

// ───────────────────────────── 16. Multi-memory routing (paged threaded, hand-built 2-mem state) ─────────────────────────────
//
// Until unit 09 seeds N memories from `StateDecl`, a multi-memory instance is built directly here
// to prove the index routing: `t_copy` reads `src_mem`, writes `dst_mem`; `t_fill`/`t_init` touch
// only their named memory.

/// A threaded InstanceState with TWO independent 1-page paged memories (indices 0 and 1).
fn two_mem_state() -> InstanceState {
  InstanceState(
    mems: [rt_mem.fresh(1, Some(1), big_cap), rt_mem.fresh(1, Some(1), big_cap)],
    globals: dict.new(),
    tables: [],
    dropped_data: set.new(),
    dropped_elem: set.new(),
    ref_globals: dict.new(),
    func_imports: [],
    js_store: None,
    js_realm: None,
  )
}

pub fn threaded_cross_memory_copy_test() {
  let st = two_mem_state()
  // Put a byte into memory 1.
  let assert Ok(st) = rt_mem.t_store_at(st, 1, 1, 0, 0xAB, 0)
  // Copy 1 byte from memory 1 (src) to memory 0 (dst) at address 5.
  let assert Ok(st) = rt_mem.t_copy(st, 0, 1, 5, 0, 1)
  rt_mem.t_load_at(st, 0, 1, False, 32, 5, 0) |> should.equal(Ok(0xAB))
  // Memory 1 is untouched; memory 0 address 0 was never written.
  rt_mem.t_load_at(st, 1, 1, False, 32, 0, 0) |> should.equal(Ok(0xAB))
  rt_mem.t_load_at(st, 0, 1, False, 32, 0, 0) |> should.equal(Ok(0))
}

pub fn threaded_fill_init_second_memory_test() {
  let st = two_mem_state()
  // Fill memory 1; memory 0 must be untouched.
  let assert Ok(st) = rt_mem.t_fill(st, 1, 0, 0x77, 4)
  rt_mem.t_load_at(st, 1, 4, False, 32, 0, 0) |> should.equal(Ok(0x77777777))
  rt_mem.t_load_at(st, 0, 4, False, 32, 0, 0) |> should.equal(Ok(0))
  // Init into memory 0 from a segment.
  let assert Ok(st) = rt_mem.t_init(st, 0, <<1, 2, 3, 4>>, 8, 0, 4)
  rt_mem.t_load_at(st, 0, 1, False, 32, 8, 0) |> should.equal(Ok(1))
  rt_mem.t_load_at(st, 0, 1, False, 32, 11, 0) |> should.equal(Ok(4))
}

// ───────────────────────────── 17. Bulk cell wrappers (fuel + no partial write, index 0) ─────────────────────────────

/// Seed a fresh 1-page cell memory for the bulk-wrapper tests.
fn seed_cell_1page() -> Nil {
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
}

// A successful `fill` persists in the cell and charges `count` fuel (R9); a trapping `fill`
// mutates nothing and charges nothing.
pub fn cell_fill_persists_and_charges_fuel_test() {
  rt_meter.reset_fuel()
  seed_cell_1page()
  rt_mem.fill(0, 0, 0xFF, 16) |> should.equal(Ok(Nil))
  rt_mem.load_at(0, 4, False, 32, 0, 0) |> should.equal(Ok(0xFFFFFFFF))
  // The frozen index-0 head observes the SAME cell (byte-identity).
  rt_mem.load(4, False, 32, 12, 0) |> should.equal(Ok(0xFFFFFFFF))
  rt_meter.fuel_consumed() |> should.equal(16)
  // A trapping fill (straddling byte_len) charges nothing and leaves the filled bytes intact.
  rt_mem.fill(0, page - 1, 0x00, 4) |> should.equal(Error(MemoryOutOfBounds))
  rt_meter.fuel_consumed() |> should.equal(16)
  rt_mem.load_at(0, 1, False, 32, 0, 0) |> should.equal(Ok(0xFF))
}

// Same-memory `copy` through the cell wrapper is overlap-correct and charges `count` fuel.
pub fn cell_copy_same_memory_overlap_test() {
  rt_meter.reset_fuel()
  seed_cell_1page()
  rt_mem.init_data_at(0, 0, <<0, 1, 2, 3, 4, 5, 6, 7>>)
  |> should.equal(Ok(Nil))
  rt_mem.copy(0, 0, 1, 0, 3) |> should.equal(Ok(Nil))
  // [0,0,1,2,4,5,6,7].
  rt_mem.load_at(0, 1, False, 32, 2, 0) |> should.equal(Ok(1))
  rt_mem.load_at(0, 1, False, 32, 3, 0) |> should.equal(Ok(2))
  rt_meter.fuel_consumed() |> should.equal(3)
}

// `init` from a dropped (ε) segment traps for n>0 and no-ops for n=0; a trap charges no fuel.
pub fn cell_init_dropped_segment_test() {
  rt_meter.reset_fuel()
  seed_cell_1page()
  rt_mem.init(0, <<>>, 0, 0, 1) |> should.equal(Error(MemoryOutOfBounds))
  rt_meter.fuel_consumed() |> should.equal(0)
  rt_mem.init(0, <<>>, 0, 0, 0) |> should.equal(Ok(Nil))
  // A real init from a segment charges `count`.
  rt_mem.init(0, <<9, 8, 7>>, 4, 0, 3) |> should.equal(Ok(Nil))
  rt_mem.load_at(0, 1, False, 32, 4, 0) |> should.equal(Ok(9))
  rt_meter.fuel_consumed() |> should.equal(3)
}

// Metered parity: a cell `fill` and a threaded `t_fill` of the same count debit IDENTICAL fuel.
pub fn cell_threaded_fill_metered_parity_test() {
  rt_meter.reset_fuel()
  seed_cell_1page()
  let assert Ok(Nil) = rt_mem.fill(0, 0, 0x01, 20)
  let cell_fuel = rt_meter.fuel_consumed()

  rt_meter.reset_fuel()
  let st =
    rt_state.fresh(StateDecl(
      mem: rt_mem.fresh(1, Some(1), big_cap),
      globals: [],
      table: dynamic.nil(),
    ))
  let assert Ok(_st) = rt_mem.t_fill(st, 0, 0, 0x01, 20)
  let threaded_fuel = rt_meter.fuel_consumed()

  cell_fuel |> should.equal(20)
  threaded_fuel |> should.equal(cell_fuel)
}

// ───────────────────────────── 18. memory64 (P6-08, S4/S9) — page cap, large addresses, byte seam ─────────────────────────────
//
// Asserts memory64 SEMANTICS (spec valid/types `2^(|addrtype|-16)` page range; exec/instructions
// `ea = i + offset`, trap iff `ea + N > |mem.data|`; memory.grow may fail returning -1) and, at
// affordable size, the flat oracle. The byte machinery is already bignum-64-bit-correct, so a
// 64-bit memory addresses past 2^32 through the SAME core; the deltas are the page cap + the ctors.

/// 2^32 — the memory64 runtime page cap (in pages) and the first byte address past the i32 range.
const two_pow_32: Int = 4_294_967_296

/// A canonical 16-byte v128 image (bytes 0..15 in address order) for the byte-seam tests.
fn sample16() -> BitArray {
  <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>
}

// ── the documented page cap: the constant + the cross-unit invariants (§C / §E.3, Verification #3) ──

// The runtime cap is a documented, spec-cited constant, NOT a guess: 2^32 pages = 2^48 bytes =
// 256 TiB. It sits strictly between the i32 hard cap (65_536) and the DECLARABLE type-level max
// (validate's 2^48-page `memory64_page_limit`), and the Binding single-sources it.
pub fn mem64_hard_max_pages_constant_test() {
  // 2^32 pages, exactly.
  rt_mem.mem64_hard_max_pages |> should.equal(4_294_967_296)
  rt_mem.mem64_hard_max_pages |> should.equal(bsl(1, 32))
  // A 64-bit memory can exceed the i32 range (else it is indistinguishable from i32).
  { rt_mem.mem64_hard_max_pages > rt_mem.hard_max_pages } |> should.be_true
  // The runtime cap is <= the DECLARABLE spec type max (2^32 <= 2^48) — the two must not conflate.
  { rt_mem.mem64_hard_max_pages <= validate.memory64_page_limit }
  |> should.be_true
  validate.memory64_page_limit |> should.equal(bsl(1, 48))
  // The single-source seam: safe_default's Binding field == this unit's pinned constant.
  let binding = instance.safe_default()
  binding.mem64_max_pages |> should.equal(rt_mem.mem64_hard_max_pages)
}

// ── the page-cap boundary via an injected small cap (§E.3): grow to the cap, then -1 beyond it ──

// With a small injected cap the grow→-1 boundary is deterministically testable (the real 2^32 cap
// is not directly reachable). fresh_mem64(1, None, 4) folds max = min(4, 2^32) = 4.
pub fn mem64_grow_cap_boundary_paged_test() {
  let m = rt_mem.fresh_mem64(1, None, 4, rt_mem.default_chunk_bytes)
  // grow 3 pages: 1 → 4 (== cap), returns old size 1.
  let #(r1, m) = rt_mem.mem_grow(m, 3)
  r1 |> should.equal(1)
  rt_mem.mem_size(m) |> should.equal(4)
  // A further grow of 1 would be 5 > cap → -1, allocating nothing, size unchanged.
  let #(r2, m) = rt_mem.mem_grow(m, 1)
  r2 |> should.equal(-1)
  rt_mem.mem_size(m) |> should.equal(4)
}

pub fn mem64_grow_cap_boundary_oracle_test() {
  let o = rt_mem.o_fresh64(1, None, 4)
  let #(r1, o) = rt_mem.o_grow(o, 3)
  r1 |> should.equal(1)
  let #(r2, o) = rt_mem.o_grow(o, 1)
  r2 |> should.equal(-1)
  rt_mem.o_size(o) |> should.equal(4)
}

// A declared max on a 64-bit memory binds below the cap exactly as for i32.
pub fn mem64_declared_max_binds_test() {
  let m = rt_mem.fresh_mem64(1, Some(2), two_pow_32, rt_mem.default_chunk_bytes)
  let #(r1, m) = rt_mem.mem_grow(m, 1)
  r1 |> should.equal(1)
  let #(r2, m) = rt_mem.mem_grow(m, 1)
  r2 |> should.equal(-1)
  rt_mem.mem_size(m) |> should.equal(2)
}

// A 64-bit memory grows PAST the i32 range (2^16 pages) — impossible for an Idx32 memory (whose
// max folds to <= 65_536) — sparsely, with no allocation.
pub fn mem64_grow_beyond_i32_range_test() {
  let m =
    rt_mem.fresh_mem64(
      1,
      None,
      rt_mem.mem64_hard_max_pages,
      rt_mem.default_chunk_bytes,
    )
  // 1 → 2^16 + 2 pages (65538) — past the i32 4 GiB ceiling. O(1) watermark move.
  let #(old, m) = rt_mem.mem_grow(m, 65_537)
  old |> should.equal(1)
  rt_mem.mem_size(m) |> should.equal(65_538)
  // The freshly-grown region past 2^32 reads as zero without allocation.
  rt_mem.mem_load(m, 8, False, 64, two_pow_32 + 1000, 0) |> should.equal(Ok(0))
}

// ── large-address behaviour (§E.2, sparse paged, NO flat oracle): the point of memory64 ──

/// A 64-bit memory grown to 65538 pages (byte_len ≈ 4 GiB + 128 KiB), sparse.
fn big_mem64() -> rt_mem.Mem {
  let m =
    rt_mem.fresh_mem64(
      1,
      None,
      rt_mem.mem64_hard_max_pages,
      rt_mem.default_chunk_bytes,
    )
  let #(_old, m) = rt_mem.mem_grow(m, 65_537)
  m
}

// Round-trip an i64 value at byte 2^32 + 40: load8/16/32/64_u read back the exact little-endian
// bytes (D5); overwriting one byte changes it and NOT its neighbours. Only touched chunks live.
pub fn mem64_large_address_roundtrip_test() {
  let m = big_mem64()
  let base = two_pow_32 + 40
  let assert Ok(m) = rt_mem.mem_store(m, 8, base, 0x0123456789ABCDEF, 0)
  // Little-endian: bytes EF CD AB 89 67 45 23 01 at base..base+7.
  rt_mem.mem_load(m, 8, False, 64, base, 0)
  |> should.equal(Ok(0x0123456789ABCDEF))
  rt_mem.mem_load(m, 4, False, 64, base, 0) |> should.equal(Ok(0x89ABCDEF))
  rt_mem.mem_load(m, 2, False, 64, base, 0) |> should.equal(Ok(0xCDEF))
  rt_mem.mem_load(m, 1, False, 64, base, 0) |> should.equal(Ok(0xEF))
  // Overwrite one byte (base+2, was 0xAB) → 0xFF; neighbours base+1 (0xCD) / base+3 (0x89) hold.
  let assert Ok(m) = rt_mem.mem_store(m, 1, base + 2, 0xFF, 0)
  rt_mem.mem_load(m, 1, False, 32, base + 2, 0) |> should.equal(Ok(0xFF))
  rt_mem.mem_load(m, 1, False, 32, base + 1, 0) |> should.equal(Ok(0xCD))
  rt_mem.mem_load(m, 1, False, 32, base + 3, 0) |> should.equal(Ok(0x89))
}

// i64 offset equivalence: store(addr=0, offset=2^32+40) and store(addr=2^32+40, offset=0) address
// the SAME byte — the offset is a u64, not truncated to 32 bits (memory64 proposal).
pub fn mem64_i64_offset_equivalence_test() {
  let m = big_mem64()
  let assert Ok(m) =
    rt_mem.mem_store(m, 8, 0, 0xDEADBEEFCAFEF00D, two_pow_32 + 40)
  // Read back with the offset folded into addr instead — same byte.
  rt_mem.mem_load(m, 8, False, 64, two_pow_32 + 40, 0)
  |> should.equal(Ok(0xDEADBEEFCAFEF00D))
}

// No-wrap trap at the 64-bit boundary: an 8-byte access at byte_len-8 is Ok, at byte_len-7 traps,
// at byte_len traps; an addr near 2^64 plus an offset produces a huge ea that traps (never wraps).
pub fn mem64_no_wrap_trap_boundary_test() {
  let m = big_mem64()
  let byte_len = 65_538 * page
  rt_mem.mem_load(m, 8, False, 64, byte_len - 8, 0) |> should.be_ok
  rt_mem.mem_load(m, 8, False, 64, byte_len - 7, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.mem_load(m, 8, False, 64, byte_len, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  // addr = 0xFFFF_FFFF_FFFF_FFF8 (near 2^64) + offset 16 → ea > 2^64, a huge bignum → trap.
  rt_mem.mem_load(m, 8, False, 64, 0xFFFFFFFFFFFFFFF8, 16)
  |> should.equal(Error(MemoryOutOfBounds))
  // A store at the boundary traps BEFORE writing (all-or-nothing), leaving the prefix intact.
  let assert Ok(m) = rt_mem.mem_store(m, 8, byte_len - 8, 0x1122334455667788, 0)
  rt_mem.mem_store(m, 8, byte_len - 7, 0, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.mem_load(m, 8, False, 64, byte_len - 8, 0)
  |> should.equal(Ok(0x1122334455667788))
}

// Bulk ops past 2^32 are memmove-correct with a small count; eager bounds at the > 4 GiB boundary
// trap with zero mutation (a d + n that overflows a 32-bit register but not the bignum byte_len
// does NOT wrap).
pub fn mem64_bulk_ops_past_2_32_test() {
  let m = big_mem64()
  let base = two_pow_32 + 40
  let byte_len = 65_538 * page
  // fill 4 bytes 0x55.
  let assert Ok(m) = rt_mem.mem_fill(m, base, 0x55, 4)
  rt_mem.mem_load(m, 4, False, 64, base, 0) |> should.equal(Ok(0x55555555))
  // copy those 4 bytes to base+8.
  let assert Ok(m) = rt_mem.mem_copy(m, m, base + 8, base, 4)
  rt_mem.mem_load(m, 4, False, 64, base + 8, 0) |> should.equal(Ok(0x55555555))
  // init 3 bytes from a segment at base+16.
  let assert Ok(m) = rt_mem.mem_init(m, <<0xDE, 0xAD, 0xBE>>, base + 16, 0, 3)
  rt_mem.mem_load(m, 1, False, 32, base + 16, 0) |> should.equal(Ok(0xDE))
  // Eager bounds past byte_len trap with zero mutation.
  rt_mem.mem_fill(m, byte_len - 2, 0x00, 4)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.mem_copy(m, m, byte_len - 2, base, 4)
  |> should.equal(Error(MemoryOutOfBounds))
}

// ── 32-bit byte-identity (§A.3, Verification #4): the mem_grow conjunct-drop is behaviour-preserving ──

/// Reference: the OLD two-conjunct `mem_grow` rule for an `Idx32` memory (`new <= eff && new <=
/// 65_536`, where `eff = min(declared ?? min(safe, 65_536), min(safe, 65_536))`). The NEW rule
/// drops the second conjunct; for `Idx32` `eff <= 65_536`, so they agree — asserted below.
fn eff_max32_ref(max: Option(Int), safe: Int) -> Int {
  let cap = int.min(safe, 65_536)
  case max {
    Some(d) -> int.min(d, cap)
    None -> cap
  }
}

fn grow32_ref(old: Int, delta: Int, max: Option(Int), safe: Int) -> Int {
  let new = old + delta
  case delta >= 0 && new <= eff_max32_ref(max, safe) && new <= 65_536 {
    True -> old
    False -> -1
  }
}

// For a battery of Idx32 (min, max, safe, delta) spanning the 65_536 boundary, the NEW `mem_grow`
// returns EXACTLY the old two-conjunct result — so a 32-bit memory is byte-identical (H7).
pub fn mem_grow_idx32_byte_identity_test() {
  let mins = [1, 65_534, 65_535, 65_536]
  let maxes = [None, Some(3), Some(65_536), Some(70_000)]
  let safes = [5, 65_536, 100_000]
  let deltas = [-1, 0, 1, 2, 3]
  list.each(mins, fn(min) {
    list.each(maxes, fn(max) {
      list.each(safes, fn(safe) {
        list.each(deltas, fn(delta) {
          let m = rt_mem.fresh_mem(min, max, safe, rt_mem.default_chunk_bytes)
          let #(got, _m) = rt_mem.mem_grow(m, delta)
          got |> should.equal(grow32_ref(min, delta, max, safe))
        })
      })
    })
  })
}

// ── the small-memory differential (§E.1): a bounded 64-bit memory — paged ≡ oracle over op streams ──

/// Drive paged64 and oracle64 through the same `count` random ops (reusing the §11 harness) on a
/// SMALL bounded 64-bit memory (max 4 pages, so the flat oracle is affordable); assert identical
/// results+traps at every step and an identical final flat byte image. Proves the i64 cap fold +
/// the bulk ops are 64-bit-correct and agree with the trivially-correct flat reference.
fn run_differential64(chunk: Int, count: Int, seed: Int) -> Nil {
  let m = rt_mem.fresh_mem64(1, Some(4), rt_mem.mem64_hard_max_pages, chunk)
  let o = rt_mem.o_fresh64(1, Some(4), rt_mem.mem64_hard_max_pages)
  let #(m, o) = diff_loop(m, o, seed, count)
  rt_mem.mem_flat(m) |> should.equal(rt_mem.o_flat(o))
}

pub fn differential64_chunk_default_test() {
  run_differential64(rt_mem.default_chunk_bytes, 250, 0x64A)
}

pub fn differential64_chunk_65_test() {
  run_differential64(65, 250, 0x64B)
}

pub fn differential64_chunk_4096_test() {
  run_differential64(4096, 300, 0x64C)
}

// ───────────────────────────── 19. the v128-memory BitArray seam (S4) — load_bytes/store_bytes ─────────────────────────────
//
// `load_bytes`/`store_bytes` are the checked wrappers 06 composes with rt_simd for the v128 memory
// family. `v128.load`: the 16 bytes at `ea` ARE the vector; `load8x8`/`load32_zero`: load 8/4 bytes
// then extend in rt_simd. Same no-wrap bignum bounds → MemoryOutOfBounds trap-before-write.

// 16-byte round-trip on the pure core; the in-memory bytes match a byte-by-byte scalar read (the
// little-endian in-memory layout); the oracle agrees.
pub fn load_store_bytes_16_roundtrip_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  let assert Ok(m) = rt_mem.mem_store_bytes(m, 16, sample16(), 0)
  rt_mem.mem_load_bytes(m, 16, 0, 16) |> should.equal(Ok(sample16()))
  // Byte-by-byte layout: address 16 holds sample[0]=0, address 31 holds sample[15]=15.
  rt_mem.mem_load(m, 1, False, 32, 16, 0) |> should.equal(Ok(0))
  rt_mem.mem_load(m, 1, False, 32, 31, 0) |> should.equal(Ok(15))
  // Oracle agrees byte-for-byte.
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  let assert Ok(o) = rt_mem.o_store_bytes(o, 16, sample16(), 0)
  rt_mem.o_load_bytes(o, 16, 0, 16) |> should.equal(Ok(sample16()))
}

// 8-byte (load8x8/load64_zero) and 4-byte (load32_zero) slices are exact little-endian sub-slices.
pub fn load_bytes_8_and_4_slices_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  let assert Ok(m) =
    rt_mem.mem_store_bytes(
      m,
      0,
      <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22>>,
      0,
    )
  rt_mem.mem_load_bytes(m, 0, 0, 8)
  |> should.equal(Ok(<<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22>>))
  rt_mem.mem_load_bytes(m, 0, 0, 4)
  |> should.equal(Ok(<<0xAA, 0xBB, 0xCC, 0xDD>>))
  // The offset folds into ea: load 4 bytes at addr=2 reads bytes [2..5].
  rt_mem.mem_load_bytes(m, 0, 2, 4)
  |> should.equal(Ok(<<0xCC, 0xDD, 0xEE, 0xFF>>))
}

// store_bytes bounds-checks the WHOLE run first → trap BEFORE any write (all-or-nothing); the exact
// 16-byte boundary; a no-wrap probe near 2^32 traps; load_bytes OOB traps.
pub fn store_bytes_oob_trap_before_write_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  // Seed a marker at the tail so a partial write would be observable.
  let assert Ok(m) = rt_mem.mem_store(m, 4, page - 16, 0xAABBCCDD, 0)
  // Exact boundary: 16 bytes at page-16 fit; at page-15 they straddle byte_len → trap.
  rt_mem.mem_store_bytes(m, page - 16, sample16(), 0) |> should.be_ok
  rt_mem.mem_store_bytes(m, page - 15, sample16(), 0)
  |> should.equal(Error(MemoryOutOfBounds))
  // A straddling store traps with ZERO mutation (the input m is untouched).
  rt_mem.mem_store_bytes(m, page - 8, sample16(), 0)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.mem_load(m, 4, False, 32, page - 16, 0) |> should.equal(Ok(0xAABBCCDD))
  // load_bytes OOB traps; the no-wrap probe near 2^32 must trap (never wrap).
  rt_mem.mem_load_bytes(m, page - 8, 0, 16)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.mem_load_bytes(m, 0xFFFFFFFF, 8, 16)
  |> should.equal(Error(MemoryOutOfBounds))
}

// The cell-backed byte seam (index 0): a store persists across a separate load; OOB via the cell
// traps.
pub fn cell_load_store_bytes_roundtrip_test() {
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rt_mem.store_bytes(32, sample16(), 0) |> should.equal(Ok(Nil))
  rt_mem.load_bytes(32, 0, 16) |> should.equal(Ok(sample16()))
  rt_mem.load_bytes(page - 8, 0, 16)
  |> should.equal(Error(MemoryOutOfBounds))
}

// The index-routed cell byte seam: store into memory 1, read it back, memory 0 untouched (16 zero
// bytes).
pub fn cell_load_store_bytes_at_index_test() {
  rt_state.seed_full(
    FullDecl(
      mems: [
        rt_mem.fresh(1, Some(1), big_cap),
        rt_mem.fresh(1, Some(1), big_cap),
      ],
      globals: [],
      tables: [],
      ref_globals: [],
    ),
  )
  rt_mem.store_bytes_at(1, 0, sample16(), 0) |> should.equal(Ok(Nil))
  rt_mem.load_bytes_at(1, 0, 0, 16) |> should.equal(Ok(sample16()))
  // load_bytes_at(0, …) is the byte-identical index-0 path; memory 0 is all zero.
  rt_mem.load_bytes_at(0, 0, 0, 16) |> should.equal(Ok(<<0:size(128)>>))
}

// The threaded byte seam: t_store_bytes rebinds immutably (the pre-store record still reads zero);
// OOB traps.
pub fn threaded_load_store_bytes_test() {
  let st = paged_threaded_state()
  let assert Ok(st2) = rt_mem.t_store_bytes(st, 0, sample16(), 0)
  rt_mem.t_load_bytes(st2, 0, 0, 16) |> should.equal(Ok(sample16()))
  // Immutable: the pre-store record is untouched.
  rt_mem.t_load_bytes(st, 0, 0, 16) |> should.equal(Ok(<<0:size(128)>>))
  rt_mem.t_store_bytes(st, page - 8, sample16(), 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

// The threaded index-routed byte seam: touches only the named memory.
pub fn threaded_load_store_bytes_at_test() {
  let st = two_mem_state()
  let assert Ok(st) = rt_mem.t_store_bytes_at(st, 1, 0, sample16(), 0)
  rt_mem.t_load_bytes_at(st, 1, 0, 0, 16) |> should.equal(Ok(sample16()))
  rt_mem.t_load_bytes_at(st, 0, 0, 0, 16)
  |> should.equal(Ok(<<0:size(128)>>))
}

// The byte seam past 2^32 (memory64 × v128 memory): a 16-byte store/load round-trips at a > 4 GiB
// address, and the i64 offset (which alone exceeds 2^32) folds into ea identically.
pub fn mem64_load_store_bytes_past_2_32_test() {
  let m = big_mem64()
  let assert Ok(m) = rt_mem.mem_store_bytes(m, two_pow_32 + 40, sample16(), 0)
  rt_mem.mem_load_bytes(m, two_pow_32 + 40, 0, 16)
  |> should.equal(Ok(sample16()))
  // The same bytes via a u64 offset that itself exceeds 2^32.
  rt_mem.mem_load_bytes(m, 0, two_pow_32 + 40, 16)
  |> should.equal(Ok(sample16()))
}
