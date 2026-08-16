//// Unit P4-09 — PROOF 2: the shared-trace cross-tier memory oracle differential (§C, G2/G6,
//// keystone §B.3).
////
//// The corpus differential (§B) proves the tiers agree WITH EACH OTHER; this proves each memory
//// tier agrees WITH THE SPEC, holding all tiers to the trivially-correct `o_*` rebuild oracle
//// (`rt_mem.{o_fresh, o_load, o_store, o_grow, o_init_data, o_size, o_flat}` over `OMem` — one
//// contiguous binary, store rebuilds the whole thing). One shared operation trace runs through the
//// `o_*` oracle AND through the THREADED family of every shipped memory tier — paged
//// (`rt_mem.t_*`), atomics (`rt_mem_atomics.t_*`), and the nif skeleton (`rt_mem_nif.t_*`, which
//// delegates to the paged core) — each threading an `rt_state.InstanceState` record. After EVERY
//// op it asserts: identical returned value, identical trap (`Ok`/`Error(reason)`), AND identical
//// byte image (`<tier>.to_flat(st.mem) == rt_mem.o_flat(oracle)`, bit-pattern equality, D7).
////
//// Why the THREADED families: §B drove them end-to-end through compiled code; this holds the
//// uniform-threading ADAPTER (03/04) to the spec directly — a `t_store` returning the rebound
//// record must produce the identical byte image the oracle's rebuild produces, on EVERY tier. A
//// wrong/missing trap, a sub-word sign/zero-extension slip, a lost store, or a wrong-endian write
//// on ANY tier diverges the byte image and turns this red on the exact op.
////
//// This is the G6 security invariant, tested: a bounds bug's worst case in tiers P/O is a
//// wrong/missing trap or a node-safe crash — NEVER a host escape (tiers P/O are memory-safe by
//// construction); tier-N is the one native seam, gated to Unsafe. The oracle is the reference that
//// would catch a tier that silently read/wrote out of bounds. Spec:
//// <https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions>,
//// <https://webassembly.github.io/spec/core/exec/modules.html> (active data), little-endian /
//// two's-complement / IEEE bits <https://webassembly.github.io/spec/core/syntax/values.html>.
////
//// Process hygiene: `t_grow` charges fuel; the trace seeds a LARGE budget up front so a grow never
//// spuriously exhausts (and a stale small budget from another eunit test cannot bite).

import carder/ir.{type TrapReason}
import carder/runtime/rt_mem
import carder/runtime/rt_mem_atomics
import carder/runtime/rt_mem_nif
import carder/runtime/rt_meter
import carder/runtime/rt_state.{type InstanceState, StateDecl}
import gleam/dynamic
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string

/// One 64 KiB page in bytes.
const page: Int = 65_536

/// A generous Safe cap so the spec corners are governed by the declared max / hard cap, not the
/// cap. `100_000 > 65_536`, so it never binds below the hard cap.
const cap: Int = 100_000

// ─────────────────────────── the four parallel backends ───────────────────────────

/// The four backends driven in lock-step: the `o_*` rebuild oracle plus the THREADED
/// `InstanceState` of each shipped memory tier (paged / atomics / nif). Applying one op to all
/// four and comparing value + trap + byte image after every op is the cross-tier differential.
type Bench {
  Bench(o: rt_mem.OMem, p: InstanceState, a: InstanceState, n: InstanceState)
}

/// A normalized op result, comparable across the oracle and every tier: a load's value/trap, a
/// store/init's success/trap status, or a grow's integer result.
type Rep {
  RLoad(Result(Int, TrapReason))
  RStatus(Result(Nil, TrapReason))
  RGrow(Int)
}

/// One memory operation in the shared trace (spec-corner coverage below).
type Op {
  Load(bytes: Int, signed: Bool, width: Int, addr: Int, offset: Int)
  Store(bytes: Int, addr: Int, value: Int, offset: Int)
  Grow(delta: Int)
  Init(offset: Int, bytes: BitArray)
}

/// Build a fresh `Bench`: a 1-page memory with declared max 3, seeded identically into the oracle
/// and the threaded record of each tier (atomics reserves 3 pages ≤ the reserve cap → engages;
/// nif delegates to the paged core). A large fuel budget is seeded so `t_grow`'s charge never
/// spuriously exhausts during the trace.
fn fresh_bench() -> Bench {
  rt_meter.seed_fuel(rt_meter.default_fuel_budget)
  let decl = fn(mem) { StateDecl(mem: mem, globals: [], table: dynamic.nil()) }
  Bench(
    o: rt_mem.o_fresh(1, Some(3), cap),
    p: rt_state.fresh(decl(rt_mem.fresh(1, Some(3), cap))),
    a: rt_state.fresh(decl(rt_mem_atomics.fresh(1, Some(3), cap))),
    n: rt_state.fresh(decl(rt_mem_nif.fresh(1, Some(3), cap))),
  )
}

// ─────────────────────────── apply one op to all four backends ───────────────────────────

/// Apply `op` to all four backends, returning the new `Bench` and the four normalized `Rep`s (in
/// oracle/paged/atomics/nif order). Threaded mutators rebind the record; a trapping store/init
/// leaves the record untouched (trap-before-write), mirroring the oracle keeping its `OMem`.
fn apply(b: Bench, op: Op) -> #(Bench, #(Rep, Rep, Rep, Rep)) {
  case op {
    Load(bytes, signed, width, addr, off) -> #(
      b,
      #(
        RLoad(rt_mem.o_load(b.o, bytes, signed, width, addr, off)),
        RLoad(rt_mem.t_load(b.p, bytes, signed, width, addr, off)),
        RLoad(rt_mem_atomics.t_load(b.a, bytes, signed, width, addr, off)),
        RLoad(rt_mem_nif.t_load(b.n, bytes, signed, width, addr, off)),
      ),
    )
    Store(bytes, addr, value, off) -> {
      let #(o2, ro) = case rt_mem.o_store(b.o, bytes, addr, value, off) {
        Ok(x) -> #(x, RStatus(Ok(Nil)))
        Error(e) -> #(b.o, RStatus(Error(e)))
      }
      let #(p2, rp) = case rt_mem.t_store(b.p, bytes, addr, value, off) {
        Ok(x) -> #(x, RStatus(Ok(Nil)))
        Error(e) -> #(b.p, RStatus(Error(e)))
      }
      let #(a2, ra) = case
        rt_mem_atomics.t_store(b.a, bytes, addr, value, off)
      {
        Ok(x) -> #(x, RStatus(Ok(Nil)))
        Error(e) -> #(b.a, RStatus(Error(e)))
      }
      let #(n2, rn) = case rt_mem_nif.t_store(b.n, bytes, addr, value, off) {
        Ok(x) -> #(x, RStatus(Ok(Nil)))
        Error(e) -> #(b.n, RStatus(Error(e)))
      }
      #(Bench(o: o2, p: p2, a: a2, n: n2), #(ro, rp, ra, rn))
    }
    Grow(delta) -> {
      let #(oi, o2) = rt_mem.o_grow(b.o, delta)
      let #(pi, p2) = rt_mem.t_grow(b.p, delta)
      let #(ai, a2) = rt_mem_atomics.t_grow(b.a, delta)
      let #(ni, n2) = rt_mem_nif.t_grow(b.n, delta)
      #(
        Bench(o: o2, p: p2, a: a2, n: n2),
        #(RGrow(oi), RGrow(pi), RGrow(ai), RGrow(ni)),
      )
    }
    Init(off, bytes) -> {
      let #(o2, ro) = case rt_mem.o_init_data(b.o, off, bytes) {
        Ok(x) -> #(x, RStatus(Ok(Nil)))
        Error(e) -> #(b.o, RStatus(Error(e)))
      }
      let #(p2, rp) = case rt_mem.t_init_data(b.p, off, bytes) {
        Ok(x) -> #(x, RStatus(Ok(Nil)))
        Error(e) -> #(b.p, RStatus(Error(e)))
      }
      let #(a2, ra) = case rt_mem_atomics.t_init_data(b.a, off, bytes) {
        Ok(x) -> #(x, RStatus(Ok(Nil)))
        Error(e) -> #(b.a, RStatus(Error(e)))
      }
      let #(n2, rn) = case rt_mem_nif.t_init_data(b.n, off, bytes) {
        Ok(x) -> #(x, RStatus(Ok(Nil)))
        Error(e) -> #(b.n, RStatus(Error(e)))
      }
      #(Bench(o: o2, p: p2, a: a2, n: n2), #(ro, rp, ra, rn))
    }
  }
}

// ─────────────────────────── the differential fold ───────────────────────────

/// Run the shared trace, asserting after every op: the four `Rep`s agree (value + trap) AND the
/// four byte images agree with the oracle (`to_flat(st.mem) == o_flat(oracle)`). Returns the list
/// of mismatch descriptions (empty ⇒ every tier matched the oracle at every step).
fn run_trace(ops: List(Op)) -> List(String) {
  let #(_final, mismatches) =
    list.index_fold(ops, #(fresh_bench(), []), fn(acc, op, i) {
      let #(b, fails) = acc
      let #(b2, #(ro, rp, ra, rn)) = apply(b, op)
      let here = "op#" <> int.to_string(i) <> " " <> string.inspect(op)
      let value_fails = rep_failures(here, ro, rp, ra, rn)
      let image_fails = flat_failures(here, b2)
      #(b2, list.flatten([fails, value_fails, image_fails]))
    })
  mismatches
}

/// The value/trap mismatch messages: every tier's `Rep` must equal the oracle's.
fn rep_failures(
  here: String,
  ro: Rep,
  rp: Rep,
  ra: Rep,
  rn: Rep,
) -> List(String) {
  list.filter_map([#("paged", rp), #("atomics", ra), #("nif", rn)], fn(pair) {
    let #(tier, rep) = pair
    case rep == ro {
      True -> Error(Nil)
      False ->
        Ok(
          here
          <> " ["
          <> tier
          <> " value≠oracle]: "
          <> string.inspect(ro)
          <> " vs "
          <> string.inspect(rep),
        )
    }
  })
}

/// The byte-image mismatch messages: every tier's flat image must equal the oracle's `o_flat`.
fn flat_failures(here: String, b: Bench) -> List(String) {
  let ref = rt_mem.o_flat(b.o)
  let images = [
    #("paged", rt_mem.to_flat(rt_state.mem(b.p))),
    #("atomics", rt_mem_atomics.to_flat(rt_state.mem(b.a))),
    #("nif", rt_mem_nif.to_flat(rt_state.mem(b.n))),
  ]
  list.filter_map(images, fn(pair) {
    let #(tier, image) = pair
    case image == ref {
      True -> Error(Nil)
      False -> Ok(here <> " [" <> tier <> " byte-image≠oracle]")
    }
  })
}

// ─────────────────────────── the spec-corner trace ───────────────────────────

/// The shared spec-corner op trace (keystone §B.3 / E4): little-endian layout, sub-word sign/zero
/// extension × result width, the no-wrap `0xFFFFFFFF` effective address (trap, never wrap),
/// trap-before-write (a straddling store leaves the byte image unchanged), exact-length off-by-one,
/// word-boundary-crossing (the atomics-specific risk), grow caps (`-1` past `effective_max`,
/// nothing allocated), zero-fill of a freshly grown page, and active-data init (in-bounds + OOB).
fn corner_trace() -> List(Op) {
  [
    // LE i32 store then per-byte reads.
    Store(4, 0, 0x04030201, 0),
    Load(1, False, 32, 0, 0),
    Load(1, False, 32, 3, 0),
    Load(4, False, 32, 0, 0),
    // Sub-word sign/zero extension × result width (byte 0x80).
    Store(1, 16, 0x80, 0),
    Load(1, True, 32, 16, 0),
    Load(1, True, 64, 16, 0),
    Load(1, False, 32, 16, 0),
    // Word-boundary-crossing i64 (atomics touches two 64-bit words).
    Store(8, 5, 0x0102030405060708, 0),
    Load(8, False, 64, 5, 0),
    Load(2, False, 32, 7, 0),
    // No-wrap effective address: 0xFFFFFFFF + offset must TRAP, never wrap to a small ea.
    Load(4, False, 32, 0xFFFFFFFF, 100),
    Store(4, 0xFFFFFFFF, 0xDEADBEEF, 100),
    Load(4, False, 32, 99, 0),
    // Exact-length off-by-one at byte_len.
    Load(4, False, 32, page - 4, 0),
    Load(4, False, 32, page - 3, 0),
    Load(1, False, 32, page - 1, 0),
    Load(1, False, 32, page, 0),
    // Trap-before-write: a straddling store mutates NOTHING (image unchanged on every tier).
    Store(4, page - 4, 0xAABBCCDD, 0),
    Store(4, page - 2, 0x11223344, 0),
    Load(4, False, 32, page - 4, 0),
    // Grow: OLD size, then zero-fill of the new page, then a write in it.
    Grow(1),
    Load(4, False, 32, page, 0),
    Store(4, page, 0xCAFEBABE, 0),
    Load(4, False, 32, page, 0),
    // Grow to the declared max, then -1 past it (nothing allocated).
    Grow(1),
    Grow(1),
    Load(4, False, 32, 3 * page - 4, 0),
    // Active data init: in-bounds exact bytes, then an OOB segment (whole-range check, no write).
    Init(20, <<0xDE, 0xAD, 0xBE, 0xEF>>),
    Load(4, False, 32, 20, 0),
    Init(3 * page - 2, <<1, 2, 3, 4>>),
    Load(1, False, 32, 3 * page - 2, 0),
  ]
}

/// PROOF 2 (§C). The spec-corner trace agrees with the `o_*` oracle on value, trap, and `to_flat`
/// byte image after EVERY op, across the paged, atomics, and nif threaded families — including the
/// sub-word extension / no-wrap-`0xFFFFFFFF` / trap-before-write / off-by-one / word-boundary /
/// grow-cap corners.
pub fn mem_tier_oracle_corner_differential_test() {
  assert run_trace(corner_trace()) == []
}

// ─────────────────────────── a randomized differential ───────────────────────────

/// A 31-bit linear-congruential PRNG (deterministic so a failure reproduces).
fn lcg(state: Int) -> Int {
  int_band(state * 1_103_515_245 + 12_345, 0x7FFFFFFF)
}

@external(erlang, "erlang", "band")
fn int_band(a: Int, b: Int) -> Int

/// Generate `count` pseudo-random ops over a 1..3-page memory: stores/loads at mostly-in-bounds
/// (many UNALIGNED, so word crossings are frequent) addresses with random widths/signs/values, a
/// few past the end (OOB), occasional grows and inits. Deterministic in `seed`.
fn random_ops(count: Int, seed: Int, byte_len: Int, acc: List(Op)) -> List(Op) {
  case count <= 0 {
    True -> list.reverse(acc)
    False -> {
      let s = lcg(seed)
      let #(op, s2, len2) = gen_op(s, byte_len)
      random_ops(count - 1, s2, len2, [op, ..acc])
    }
  }
}

fn gen_op(s: Int, byte_len: Int) -> #(Op, Int, Int) {
  case s % 10 {
    k if k < 5 -> {
      let s2 = lcg(s)
      let bytes = pick_bytes(s2 % 4)
      let #(addr, s3) = pick_addr(s2, byte_len)
      let s4 = lcg(s3)
      #(Store(bytes, addr, pick_value(s4), s3 % 8), lcg(s4), byte_len)
    }
    k if k < 8 -> {
      let s2 = lcg(s)
      let bytes = pick_bytes(s2 % 4)
      let width = case bytes {
        8 -> 64
        _ ->
          case s2 % 2 {
            0 -> 32
            _ -> 64
          }
      }
      let #(addr, s3) = pick_addr(s2, byte_len)
      #(Load(bytes, s3 % 2 == 0, width, addr, s3 % 8), lcg(s3), byte_len)
    }
    8 -> {
      let s2 = lcg(s)
      #(Grow(s2 % 3), s2, byte_len)
    }
    _ -> {
      let s2 = lcg(s)
      let #(addr, s3) = pick_addr(s2, byte_len)
      #(
        Init(addr, <<{ s3 % 256 }, { s2 % 256 }, { s % 256 }>>),
        lcg(s3),
        byte_len,
      )
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

/// Mostly in-bounds (a touch past `byte_len` so OOB is exercised), occasionally `0xFFFFFFFF` (the
/// no-wrap probe — must trap, never wrap).
fn pick_addr(seed: Int, byte_len: Int) -> #(Int, Int) {
  let s = lcg(seed)
  case s % 17 == 0 {
    True -> #(0xFFFFFFFF, s)
    False -> #(s % { byte_len + 16 }, s)
  }
}

fn pick_value(seed: Int) -> Int {
  let a = lcg(seed)
  int_bor(int_bsl(a, 33), lcg(a))
}

@external(erlang, "erlang", "bor")
fn int_bor(a: Int, b: Int) -> Int

@external(erlang, "erlang", "bsl")
fn int_bsl(a: Int, b: Int) -> Int

/// Run a randomized trace against the oracle across all threaded tiers. Deterministic seeds so a
/// failure reproduces; targets word-boundary / unaligned-access drift on the threaded path.
fn random_trace(seed: Int) -> List(String) {
  run_trace(random_ops(200, seed, page, []))
}

pub fn mem_tier_oracle_random_seed_a_test() {
  assert random_trace(0x1234) == []
}

pub fn mem_tier_oracle_random_seed_b_test() {
  assert random_trace(0xC0FFEE) == []
}

pub fn mem_tier_oracle_random_seed_c_test() {
  assert random_trace(0xBEEF) == []
}
