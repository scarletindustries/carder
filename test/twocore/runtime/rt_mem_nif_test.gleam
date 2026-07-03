//// Spec-grounded tests for `rt_mem_nif` (unit P4-05) — the tier-N (`nif`) linear memory: the
//// raw-`O(1)` NATIVE ceiling (Unsafe-only, Safe-forbidden), shipped as a NODE-SAFE REFERENCE
//// SKELETON that delegates to the proven paged core (the production C NIF is documented-deferred,
//// §B). These tests assert WebAssembly linear-memory SEMANTICS (not "whatever the skeleton
//// emits", D8), citing the spec, and hold the tier-N backend BYTE-FOR-BYTE to the flat-binary
//// `rebuild` oracle (`rt_mem`'s `o_*`) AND to the paged backend (`rt_mem`'s threaded `t_*`) — the
//// §D differential proves the tier-N MODULE WIRING + the `to_flat` coercion introduce no
//// corruption. Because the skeleton IS the paged algebra, `tier-N ≡ paged ≡ oracle` holds by
//// construction; the identical harness is the exact check that would catch a C bounds / endianness
//// bug the day the deferred native impl drops in behind these byte-identical heads.
////
//// Spec refs:
//// - exec/instructions (load/store, memory.size/grow):
////   <https://webassembly.github.io/spec/core/exec/instructions.html>
//// - exec/modules (active data init): <https://webassembly.github.io/spec/core/exec/modules.html>
//// - syntax/values (little-endian, two's complement, IEEE bits):
////   <https://webassembly.github.io/spec/core/syntax/values.html>
////
//// Structure: (1) interface-conformance spec corners through the tier-N heads; (2) the §D
//// differential (tier-N ≡ paged ≡ oracle) over a shared randomized op trace; (3) both state
//// families — cell-backed (seed → op → observe persistence + isolation) and threaded
//// (`t_store`/`t_grow` return the rebound record, reads leave `st` untouched, fuel parity); (4)
//// the structural Safe-forbids-nif assertion (G6/§C); (5) head-compatibility with paged (the tier
//// swap is uniform).

import gleam/dynamic
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import twocore/ir.{MemoryOutOfBounds}
import twocore/runtime/instance.{type Binding, Nif}
import twocore/runtime/profiles
import twocore/runtime/rt_mem
import twocore/runtime/rt_mem_nif as nif
import twocore/runtime/rt_meter
import twocore/runtime/rt_state.{type InstanceState, StateDecl}

/// Page byte length; one fresh page = 65536 bytes.
const page: Int = 65_536

/// A generous Safe cap so the spec-corner tests are governed by the declared max / hard cap
/// (`100_000 > 65_536`, so it never binds below the 65536-page hard cap).
const big_cap: Int = 100_000

// ───────────────────────────── helpers ─────────────────────────────

/// Build a threaded `InstanceState` whose `mem` slot holds a fresh tier-N memory (the skeleton's
/// paged handle). The threaded path is the functional twin used by most interface-conformance
/// tests (no shared cell to reset).
fn threaded(min_pages: Int, max_pages: option.Option(Int)) -> InstanceState {
  rt_state.fresh(StateDecl(
    mem: nif.fresh(min_pages, max_pages, big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
}

// ───────────────────────────── 1. Little-endian multi-byte layout (endianness.wast) ─────────────────────────────

// Per the spec all loads/stores are little-endian: storing `0x04030201` as an i32 lays bytes
// `01 02 03 04` at +0..+3, and an i32 load reads them back as `0x04030201`.
pub fn le_layout_test() {
  let st = threaded(1, Some(1))
  let assert Ok(st) = nif.t_store(st, 4, 0, 0x04030201, 0)
  nif.t_load(st, 1, False, 32, 0, 0) |> should.equal(Ok(0x01))
  nif.t_load(st, 1, False, 32, 1, 0) |> should.equal(Ok(0x02))
  nif.t_load(st, 1, False, 32, 2, 0) |> should.equal(Ok(0x03))
  nif.t_load(st, 1, False, 32, 3, 0) |> should.equal(Ok(0x04))
  // The whole i32 reads back identically (redundant load after store).
  nif.t_load(st, 4, False, 32, 0, 0) |> should.equal(Ok(0x04030201))
}

// A store at a non-zero `offset` adds `addr + offset` (bignum) and round-trips little-endian.
pub fn le_layout_with_offset_test() {
  let st = threaded(1, Some(1))
  let assert Ok(st) = nif.t_store(st, 8, 100, 0x0102030405060708, 8)
  // ea = 108: byte[108] = 0x08 (low), byte[115] = 0x01 (high).
  nif.t_load(st, 1, False, 32, 108, 0) |> should.equal(Ok(0x08))
  nif.t_load(st, 1, False, 32, 115, 0) |> should.equal(Ok(0x01))
  nif.t_load(st, 8, False, 64, 100, 8) |> should.equal(Ok(0x0102030405060708))
}

// ───────────────────────────── 2. Sign vs zero extend × result width ─────────────────────────────

// `loadN_s` sign-extends to the operand width; `loadN_u` zero-extends. `result_width`
// disambiguates i32.load8_s (→ 0xFFFFFF80) from i64.load8_s (→ 0xFF..FF80) for byte 0x80.
pub fn sign_zero_extend_test() {
  let st = threaded(1, Some(1))
  let assert Ok(st) = nif.t_store(st, 1, 0, 0x80, 0)
  let assert Ok(st) = nif.t_store(st, 1, 1, 0xFF, 0)
  nif.t_load(st, 1, True, 32, 0, 0) |> should.equal(Ok(0xFFFFFF80))
  nif.t_load(st, 1, True, 64, 0, 0) |> should.equal(Ok(0xFFFFFFFFFFFFFF80))
  nif.t_load(st, 1, False, 32, 0, 0) |> should.equal(Ok(0x80))
  nif.t_load(st, 1, True, 32, 1, 0) |> should.equal(Ok(0xFFFFFFFF))
  nif.t_load(st, 1, True, 64, 1, 0) |> should.equal(Ok(0xFFFFFFFFFFFFFFFF))
  nif.t_load(st, 1, False, 32, 1, 0) |> should.equal(Ok(0xFF))
}

// i64.load16_s of 0x8000 → 0xFFFFFFFFFFFF8000; i64.load32_s of 0x80000000 → high bits set;
// load32_u zero-extends.
pub fn wide_sign_extend_test() {
  let st = threaded(1, Some(1))
  let assert Ok(st) = nif.t_store(st, 2, 0, 0x8000, 0)
  let assert Ok(st) = nif.t_store(st, 4, 6, 0x80000000, 0)
  nif.t_load(st, 2, True, 64, 0, 0) |> should.equal(Ok(0xFFFFFFFFFFFF8000))
  nif.t_load(st, 2, True, 32, 0, 0) |> should.equal(Ok(0xFFFF8000))
  nif.t_load(st, 4, True, 64, 6, 0) |> should.equal(Ok(0xFFFFFFFF80000000))
  nif.t_load(st, 4, False, 64, 6, 0) |> should.equal(Ok(0x80000000))
}

// ───────────────────────────── 3. Zero-fill (never-written + freshly grown) ─────────────────────────────

// A never-written in-bounds byte reads 0; every byte of a freshly grown page reads 0. (memory.wast)
pub fn zero_fill_test() {
  let st = threaded(1, Some(3))
  nif.t_load(st, 1, False, 32, 0, 0) |> should.equal(Ok(0))
  nif.t_load(st, 4, False, 32, 12_345, 0) |> should.equal(Ok(0))
  nif.t_load(st, 8, False, 64, page - 8, 0) |> should.equal(Ok(0))
  let #(old, st) = nif.t_grow(st, 1)
  old |> should.equal(1)
  // Every byte of the new page reads 0, and it is writable.
  nif.t_load(st, 1, False, 32, page, 0) |> should.equal(Ok(0))
  nif.t_load(st, 8, False, 64, 2 * page - 8, 0) |> should.equal(Ok(0))
  let assert Ok(st) = nif.t_store(st, 4, page, 0xCAFEBABE, 0)
  nif.t_load(st, 4, False, 32, page, 0) |> should.equal(Ok(0xCAFEBABE))
}

// ───────────────────────────── 4. No-wrap effective address (memory_trap / address.wast) ─────────────────────────────

// ea = addr + offset is a bignum; NEVER reduced mod 2^32. addr = 0xFFFFFFFF + a large offset must
// TRAP, not wrap to a small in-bounds ea.
pub fn no_wrap_ea_test() {
  let st = threaded(1, Some(2))
  nif.t_load(st, 4, False, 32, 0xFFFFFFFF, 100)
  |> should.equal(Error(MemoryOutOfBounds))
  nif.t_store(st, 4, 0xFFFFFFFF, 0xDEADBEEF, 100)
  |> should.equal(Error(MemoryOutOfBounds))
  // A wrap bug would have computed ea = 99 (in bounds). Prove byte 99 is untouched (still 0).
  nif.t_load(st, 4, False, 32, 99, 0) |> should.equal(Ok(0))
}

// ───────────────────────────── 5. Exact-length off-by-one (address.wast) ─────────────────────────────

// An access ending EXACTLY at byte_len is in bounds; one byte past traps.
pub fn off_by_one_test() {
  let st = threaded(1, Some(1))
  nif.t_load(st, 4, False, 32, page - 4, 0) |> should.equal(Ok(0))
  nif.t_load(st, 4, False, 32, page - 3, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  nif.t_load(st, 1, False, 32, page - 1, 0) |> should.equal(Ok(0))
  nif.t_load(st, 1, False, 32, page, 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

// ───────────────────────────── 6. Partial multi-byte store traps with ZERO mutation (E3) ─────────────────────────────

// A multi-byte store straddling byte_len traps BEFORE any byte is written — including the
// in-bounds prefix. Seed a known i32, attempt a straddling store, prove every byte is unchanged.
pub fn partial_store_zero_mutation_test() {
  let st = threaded(1, Some(1))
  let assert Ok(st) = nif.t_store(st, 4, page - 4, 0xAABBCCDD, 0)
  nif.t_store(st, 4, page - 2, 0x11223344, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  // The straddling store mutated nothing (bounds-check-before-write): the seeded bytes stand.
  nif.t_load(st, 4, False, 32, page - 4, 0) |> should.equal(Ok(0xAABBCCDD))
  nif.t_load(st, 1, False, 32, page - 2, 0) |> should.equal(Ok(0xBB))
  nif.t_load(st, 1, False, 32, page - 1, 0) |> should.equal(Ok(0xAA))
}

// ───────────────────────────── 7. memory.grow: OLD size, then -1 past max (memory_size.wast) ─────────────────────────────

// grow returns the OLD size on success and -1 past the declared max, allocating nothing; size
// reflects only successful grows.
pub fn grow_declared_max_test() {
  let st = threaded(1, Some(3))
  nif.t_size(st) |> should.equal(1)
  let #(r1, st) = nif.t_grow(st, 1)
  r1 |> should.equal(1)
  nif.t_size(st) |> should.equal(2)
  let #(r2, st) = nif.t_grow(st, 1)
  r2 |> should.equal(2)
  nif.t_size(st) |> should.equal(3)
  let #(r3, st) = nif.t_grow(st, 1)
  r3 |> should.equal(-1)
  nif.t_size(st) |> should.equal(3)
  // delta 0 is a successful no-op returning the current size.
  let #(r4, _st) = nif.t_grow(st, 0)
  r4 |> should.equal(3)
}

// ───────────────────────────── 8. f32/f64 round-trip preserves raw bits incl. NaN (float_memory.wast) ─────────────────────────────

// f32/f64 store/load are raw-byte moves over the IEEE bit pattern — never a BEAM-double round-trip
// (which would mangle NaN payloads / signalling bits). Store NaN-payload patterns and read the
// identical bits.
pub fn float_nan_roundtrip_test() {
  let st = threaded(1, Some(1))
  let f64_nan = 0x7FF8000000000001
  let f64_neg_zero = 0x8000000000000000
  let f32_nan = 0x7FC00001
  let f32_pos_inf = 0x7F800000
  let assert Ok(st) = nif.t_store(st, 8, 3, f64_nan, 0)
  let assert Ok(st) = nif.t_store(st, 8, 16, f64_neg_zero, 0)
  let assert Ok(st) = nif.t_store(st, 4, 24, f32_nan, 0)
  let assert Ok(st) = nif.t_store(st, 4, 28, f32_pos_inf, 0)
  nif.t_load(st, 8, False, 64, 3, 0) |> should.equal(Ok(f64_nan))
  nif.t_load(st, 8, False, 64, 16, 0) |> should.equal(Ok(f64_neg_zero))
  nif.t_load(st, 4, False, 32, 24, 0) |> should.equal(Ok(f32_nan))
  nif.t_load(st, 4, False, 32, 28, 0) |> should.equal(Ok(f32_pos_inf))
}

// ───────────────────────────── 9. init_data: in-bounds writes exact bytes; OOB traps ─────────────────────────────

pub fn init_data_test() {
  let st = threaded(1, Some(1))
  let assert Ok(st) = nif.t_init_data(st, 10, <<0xDE, 0xAD, 0xBE, 0xEF>>)
  nif.t_load(st, 1, False, 32, 10, 0) |> should.equal(Ok(0xDE))
  nif.t_load(st, 1, False, 32, 13, 0) |> should.equal(Ok(0xEF))
  // i32.load reads them little-endian: bytes DE AD BE EF → 0xEFBEADDE.
  nif.t_load(st, 4, False, 32, 10, 0) |> should.equal(Ok(0xEFBEADDE))
  // A segment that overruns byte_len traps (whole-range check, no partial write).
  nif.t_init_data(st, page - 2, <<1, 2, 3, 4>>)
  |> should.equal(Error(MemoryOutOfBounds))
  // The straddling segment wrote nothing: the last in-bounds byte is still 0.
  nif.t_load(st, 1, False, 32, page - 2, 0) |> should.equal(Ok(0))
}

// An empty active segment is always in bounds (even at byte_len), and is a no-op.
pub fn init_data_empty_segment_test() {
  let st = threaded(1, Some(1))
  nif.t_init_data(st, page, <<>>) |> should.be_ok
}

// ───────────────────────────── 10. DIFFERENTIAL: tier-N ≡ paged ≡ oracle (§D, E4) ─────────────────────────────

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

/// Drive the tier-N handle (threaded), the paged handle (threaded), and the flat-binary oracle
/// through the SAME `count` random ops; assert identical value+trap at every step AND an identical
/// flat byte image after every step (the strongest byte-for-byte differential — it exercises the
/// tier-N module wiring + the `to_flat` coercion, and is the exact check that would catch a C
/// bounds/endianness bug in the deferred native impl). No CPU-fuel budget is seeded, so the grow
/// fuel charge on the threaded path never traps.
fn run_differential(count: Int, seed: Int) -> Nil {
  rt_meter.reset_fuel()
  let sn = threaded(1, Some(2))
  let sp =
    rt_state.fresh(StateDecl(
      mem: rt_mem.fresh(1, Some(2), big_cap),
      globals: [],
      table: dynamic.nil(),
    ))
  let o = rt_mem.o_fresh(1, Some(2), big_cap)
  diff_loop(sn, sp, o, seed, count)
}

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
      let #(op, seed) = gen_op(nif.t_size(sn) * page, seed)
      let #(sn, rn) = apply_nif(sn, op)
      let #(sp, rp) = apply_paged(sp, op)
      let #(o, ro) = apply_oracle(o, op)
      // The security boundary: all three agree on value AND trap, every step.
      rn |> should.equal(rp)
      rn |> should.equal(ro)
      // And the whole in-bounds byte image is byte-identical, every step (via the frozen hook).
      let image = nif.to_flat(rt_state.mem(sn))
      image |> should.equal(rt_mem.to_flat(rt_state.mem(sp)))
      image |> should.equal(rt_mem.o_flat(o))
      diff_loop(sn, sp, o, seed, remaining - 1)
    }
  }
}

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

/// Generate a random op given the current `byte_len`. Addresses span in-bounds (many UNALIGNED and
/// boundary-crossing), a few bytes past the end, and occasionally 0xFFFFFFFF (the no-wrap probe);
/// widths/signs/values random; grows stay within the 2-page max.
fn gen_op(byte_len: Int, seed: Int) -> #(Op, Int) {
  let s = lcg(seed)
  case s % 10 {
    k if k < 5 -> {
      let s2 = lcg(s)
      let bytes = pick_bytes(s2 % 4)
      let #(addr, s3) = pick_addr(s2, byte_len)
      let s4 = lcg(s3)
      let s5 = lcg(s4)
      #(OpStore(bytes, addr, pick_value(s5), s4 % 8), s5)
    }
    k if k < 8 -> {
      let s2 = lcg(s)
      let bytes = pick_bytes(s2 % 4)
      let #(width, s3) = pick_width(bytes, s2)
      let s4 = lcg(s3)
      let #(addr, s5) = pick_addr(s4, byte_len)
      let signed = s4 % 2 == 0
      #(OpLoad(bytes, signed, width, addr, s5 % 8), s5)
    }
    8 -> {
      let s2 = lcg(s)
      #(OpGrow(s2 % 3), s2)
    }
    _ -> {
      let s2 = lcg(s)
      let len = s2 % 6
      let #(addr, s3) = pick_addr(s2, byte_len)
      let #(bytes, s4) = rand_bytes(len, s3)
      #(OpInit(addr, bytes), s4)
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

// ───────────────────────────── 11. Cell-backed family (seed → op → observe) ─────────────────────────────

// The public load/store/size/grow read the `mem` slot of THIS process's cell. Seed a fresh tier-N
// memory via rt_state, exercise the wrappers, observe persistence + isolation.

pub fn cell_store_load_roundtrip_test() {
  rt_state.seed(StateDecl(
    mem: nif.fresh(1, Some(2), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  nif.store(4, 0, 0x04030201, 0) |> should.equal(Ok(Nil))
  // The store persisted across the separate load call (written back to the cell).
  nif.load(4, False, 32, 0, 0) |> should.equal(Ok(0x04030201))
  nif.load(1, False, 32, 0, 0) |> should.equal(Ok(0x01))
  nif.load(1, True, 32, 3, 0) |> should.equal(Ok(0x04))
  nif.load(4, False, 32, page, 0) |> should.equal(Error(MemoryOutOfBounds))
}

pub fn cell_size_and_grow_test() {
  rt_state.seed(StateDecl(
    mem: nif.fresh(1, Some(3), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  nif.size() |> should.equal(1)
  nif.grow(1) |> should.equal(1)
  nif.size() |> should.equal(2)
  nif.grow(5) |> should.equal(-1)
  nif.size() |> should.equal(2)
  // The grown page is zero and writable.
  nif.load(4, False, 32, page, 0) |> should.equal(Ok(0))
  nif.store(4, page, 0xCAFEBABE, 0) |> should.equal(Ok(Nil))
  nif.load(4, False, 32, page, 0) |> should.equal(Ok(0xCAFEBABE))
}

pub fn cell_isolation_between_seeds_test() {
  rt_state.seed(StateDecl(
    mem: nif.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  nif.store(1, 42, 0xAB, 0) |> should.equal(Ok(Nil))
  nif.load(1, False, 32, 42, 0) |> should.equal(Ok(0xAB))
  // Re-seed: a FRESH memory. The first write must NOT bleed through.
  rt_state.seed(StateDecl(
    mem: nif.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  nif.load(1, False, 32, 42, 0) |> should.equal(Ok(0))
}

pub fn cell_partial_store_trap_no_mutation_test() {
  rt_state.seed(StateDecl(
    mem: nif.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  let assert Ok(Nil) = nif.store(4, page - 4, 0xAABBCCDD, 0)
  nif.store(4, page - 2, 0x11223344, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  nif.load(4, False, 32, page - 4, 0) |> should.equal(Ok(0xAABBCCDD))
}

pub fn cell_init_data_test() {
  rt_state.seed(StateDecl(
    mem: nif.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  nif.init_data(8, <<0xDE, 0xAD, 0xBE, 0xEF>>) |> should.equal(Ok(Nil))
  nif.load(4, False, 32, 8, 0) |> should.equal(Ok(0xEFBEADDE))
  nif.init_data(page - 2, <<1, 2, 3, 4>>)
  |> should.equal(Error(MemoryOutOfBounds))
}

// A successful cell grow charges fuel proportional to the pages made addressable (E3/P2); a
// failed grow charges nothing.
pub fn cell_grow_charges_fuel_proportional_test() {
  rt_meter.reset_fuel()
  rt_state.seed(StateDecl(
    mem: nif.fresh(1, Some(4), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  nif.grow(2) |> should.equal(1)
  rt_meter.fuel_consumed() |> should.equal(2 * page)
  // A FAILED grow (past max) allocates nothing and charges nothing.
  nif.grow(100) |> should.equal(-1)
  rt_meter.fuel_consumed() |> should.equal(2 * page)
}

// The uniform differential hook over the cell Dynamic: to_flat(mem_get()) is the byte image.
pub fn cell_to_flat_matches_oracle_test() {
  rt_state.seed(StateDecl(
    mem: nif.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  nif.store(4, 100, 0x04030201, 0) |> should.equal(Ok(Nil))
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  let assert Ok(o) = rt_mem.o_store(o, 4, 100, 0x04030201, 0)
  nif.to_flat(rt_state.mem_get()) |> should.equal(rt_mem.o_flat(o))
}

// ───────────────────────────── 12. Threaded family (thread the InstanceState record) ─────────────────────────────

// t_store returns a REBOUND record (the skeleton's paged Mem is immutable). Reading through the
// PRE-store `st` must NOT see the mutation (the value lives only in the rebound record).
pub fn threaded_store_rebinds_test() {
  let st = threaded(1, Some(1))
  let assert Ok(st2) = nif.t_store(st, 8, 5, 0xDEADBEEFCAFEF00D, 0)
  // The rebound record carries the store.
  nif.t_load(st2, 8, False, 64, 5, 0)
  |> should.equal(Ok(0xDEADBEEFCAFEF00D))
  // The pre-store record is UNCHANGED (immutable paged handle — a new one was rebound).
  nif.t_load(st, 8, False, 64, 5, 0) |> should.equal(Ok(0))
}

// t_load / t_size are read-only (st unchanged).
pub fn threaded_read_only_test() {
  let st = threaded(1, Some(4))
  nif.t_size(st) |> should.equal(1)
  nif.t_load(st, 4, False, 32, 0, 0) |> should.equal(Ok(0))
}

// t_grow returns the OLD pages + a REBOUND record whose size reflects the grow; -1 past max.
pub fn threaded_grow_rebinds_test() {
  let st = threaded(1, Some(4))
  let #(r1, st) = nif.t_grow(st, 2)
  r1 |> should.equal(1)
  nif.t_size(st) |> should.equal(3)
  let #(r2, st) = nif.t_grow(st, 1)
  r2 |> should.equal(3)
  nif.t_size(st) |> should.equal(4)
  // Past the declared max (4): -1, unchanged.
  let #(r3, st) = nif.t_grow(st, 1)
  r3 |> should.equal(-1)
  nif.t_size(st) |> should.equal(4)
  // The grown pages are zero and writable through the threaded record.
  let assert Ok(st) = nif.t_store(st, 4, 3 * page, 0x0BADF00D, 0)
  nif.t_load(st, 4, False, 32, 3 * page, 0) |> should.equal(Ok(0x0BADF00D))
}

// A failed threaded grow (past max) charges nothing and returns the unchanged record.
pub fn threaded_grow_failed_charges_nothing_test() {
  rt_meter.reset_fuel()
  let st = threaded(1, Some(1))
  let #(r, st) = nif.t_grow(st, 100)
  r |> should.equal(-1)
  nif.t_size(st) |> should.equal(1)
  rt_meter.fuel_consumed() |> should.equal(0)
}

// P2 metered parity: a metered THREADED grow and a metered CELL grow debit an IDENTICAL fuel
// amount (delta * page_bytes) — so metered+threaded == metered+cell (the G7 trap bar), matching
// paged/atomics.
pub fn threaded_grow_charges_same_fuel_as_cell_test() {
  // Cell grow of 3 pages.
  rt_meter.reset_fuel()
  rt_state.seed(StateDecl(
    mem: nif.fresh(1, Some(8), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  nif.grow(3) |> should.equal(1)
  let cell_fuel = rt_meter.fuel_consumed()

  // Threaded grow of 3 pages.
  rt_meter.reset_fuel()
  let st = threaded(1, Some(8))
  let #(r, _st) = nif.t_grow(st, 3)
  r |> should.equal(1)
  let threaded_fuel = rt_meter.fuel_consumed()

  cell_fuel |> should.equal(3 * page)
  threaded_fuel |> should.equal(cell_fuel)
}

pub fn threaded_init_data_test() {
  let st = threaded(1, Some(1))
  let assert Ok(st) = nif.t_init_data(st, 10, <<0xDE, 0xAD, 0xBE, 0xEF>>)
  nif.t_load(st, 4, False, 32, 10, 0) |> should.equal(Ok(0xEFBEADDE))
  nif.t_init_data(st, page - 2, <<1, 2, 3, 4>>)
  |> should.equal(Error(MemoryOutOfBounds))
}

// ───────────────────────────── 13. Safe-forbids-nif (structural, G6/§C) ─────────────────────────────

// tier-N is Unsafe-only, forbidden in Safe fail-closed: the shipped skeleton is pure BEAM and
// cannot crash the node, but the tier's CLASSIFICATION (and the gate that contains it) is a
// property of the intended PRODUCTION C NIF. Because Gleam has no default field values, every Safe
// profile constructor NAMES `Paged` — so `Safe + Nif` is UNCONSTRUCTIBLE through the profile API.
// (Unit 07 adds the defensive `validate_binding` gate + its tests; this pins the structural layer.)
pub fn safe_forbids_nif_is_unconstructible_test() {
  let safe_bindings = [
    profiles.safe(),
    profiles.safe_capped(1),
    profiles.safe_metered(1000),
    instance.safe_default(),
  ]
  list.all(safe_bindings, fn(b: Binding) { b.mem_tier != Nif })
  |> should.be_true
}

// ───────────────────────────── 14. Head-compatibility with paged (the tier swap is uniform) ─────────────────────────────

// The tier-N heads are byte-identical to paged, so unit 07's tier→module swap and unit 09's
// differential bind uniformly. Driving the SAME fixed op sequence through the tier-N threaded API
// and the paged threaded API yields byte-identical images at every step — the skeleton IS the
// paged algebra, so the swap introduces no behavioural drift (this is the property the deferred
// native impl must also uphold, held to the spec by §D).
pub fn head_compatibility_with_paged_test() {
  let sn = threaded(1, Some(2))
  let sp =
    rt_state.fresh(StateDecl(
      mem: rt_mem.fresh(1, Some(2), big_cap),
      globals: [],
      table: dynamic.nil(),
    ))
  // A store, a grow, and an init-data — the three mutators — plus a load, in lockstep.
  let assert Ok(sn) = nif.t_store(sn, 8, 7, 0x1122334455667788, 0)
  let assert Ok(sp) = rt_mem.t_store(sp, 8, 7, 0x1122334455667788, 0)
  nif.to_flat(rt_state.mem(sn))
  |> should.equal(rt_mem.to_flat(rt_state.mem(sp)))

  let #(rn, sn) = nif.t_grow(sn, 1)
  let #(rp, sp) = rt_mem.t_grow(sp, 1)
  rn |> should.equal(rp)
  nif.to_flat(rt_state.mem(sn))
  |> should.equal(rt_mem.to_flat(rt_state.mem(sp)))

  let assert Ok(sn) = nif.t_init_data(sn, page, <<0xDE, 0xAD, 0xBE, 0xEF>>)
  let assert Ok(sp) = rt_mem.t_init_data(sp, page, <<0xDE, 0xAD, 0xBE, 0xEF>>)
  nif.to_flat(rt_state.mem(sn))
  |> should.equal(rt_mem.to_flat(rt_state.mem(sp)))

  nif.t_load(sn, 4, False, 32, page, 0)
  |> should.equal(rt_mem.t_load(sp, 4, False, 32, page, 0))
}

// ───────────────────────────── memory64 (P6-08, §D): fresh64 delegates to the sparse paged core ─────────────────────────────
//
// The nif skeleton's `fresh64` delegates to `rt_mem.fresh64` (a paged `Mem`; NOT the native
// ceiling). The over-cap fail-closed gate lives in unit 09's `validate_binding` (mirroring atomics
// via `reservation64`); a TINY BOUNDED 64-bit memory delegates to the sparse paged core, which is
// already 64-bit-correct — so an address past 2^32 round-trips through the delegated `Mem`.
pub fn fresh64_delegates_to_paged_large_address_test() {
  let cap = rt_mem.mem64_hard_max_pages
  // fresh64 builds a paged Mem; coerce it back via rt_mem.from_dynamic to drive the pure core.
  let m = rt_mem.from_dynamic(nif.fresh64(1, None, cap))
  // Grow past the i32 range (1 → 2^16 + 2 pages), sparse — then round-trip an i64 past 2^32.
  let #(old, m) = rt_mem.mem_grow(m, 65_537)
  old |> should.equal(1)
  let base = 4_294_967_296 + 40
  let assert Ok(m) = rt_mem.mem_store(m, 8, base, 0x0123456789ABCDEF, 0)
  rt_mem.mem_load(m, 8, False, 64, base, 0)
  |> should.equal(Ok(0x0123456789ABCDEF))
  // The delegating fresh64 and rt_mem.fresh64 build a byte-identical handle.
  rt_mem.to_flat(nif.fresh64(2, Some(3), cap))
  |> should.equal(rt_mem.to_flat(rt_mem.fresh64(2, Some(3), cap)))
}
