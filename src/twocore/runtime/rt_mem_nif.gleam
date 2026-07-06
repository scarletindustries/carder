//// `rt_mem_nif` — the tier-N (`nif`) linear-memory backend: the raw-`O(1)` NATIVE ceiling
//// (G2). **Unsafe-only; forbidden in Safe** (G6) — the linker rejects a `Safe + Nif` binding
//// fail-closed. Selected when `binding.mem_tier == Nif`, which maps to the module name
//// `"twocore@runtime@rt_mem_nif"`; `emit_core` stays tier-agnostic (it reads only `mem_module`,
//// never the tier), so the tier routes here unchanged.
////
//// **Native-when-loaded, paged-delegate-otherwise (Phase-15 MF3).** Every frozen head dispatches
//// on `nif_available()` — a cheap cached-atom read that is `true` ONLY when the compiled `.so`
//// (`c_src/twocore_rt_mem_nif.c`) is attached to the shim `twocore_rt_mem_nif_ffi`:
////
//// - **loaded** (CI ubuntu gcc, dev macOS clang, packaged deployments) → the native arm sources the
////   ERTS resource handle (from the pdict cell / the threaded record / the mem-index slot) and calls
////   the `nif_`-prefixed `@external`s on it, passing the COMBINED no-wrap effective address
////   `ea = addr + offset` (computed Gleam-side as a BEAM bignum — the C never re-adds). The C is the
////   security boundary (the overflow-safe bounds check lives there, S3); the memory algebra is
////   BIT-IDENTICAL to the paged reference (the per-op `nif ≡ paged ≡ oracle` differential proves it).
//// - **not loaded** (a bare BEAM / `cc`-absent host) → the same head delegates to the paged core
////   `twocore/runtime/rt_mem`, byte-identical by construction. This preserves the Phase-11
////   `runs_anywhere` property: the tier runs on a bare BEAM with NO NIF and no per-file skip-gating,
////   so `conformance_test` / `mem_oracle_differential_test` / `pipeline_tier_test` keep working.
////
//// **The Gleam keeps the plumbing + the fuel; the C is the pure algebra.** The pdict/record/mem-index
//// sourcing and the `rt_meter.charge` fuel debits live in these heads (metering byte-identical to
//// paged/atomics — an untrusted module cannot allocate to the cap with zero CPU accounting), never
//// in the C. The resource is MUTATED IN PLACE and its identity is stable across every op including
//// `grow` (a watermark bump inside the reserved buffer — no realloc), so the cell mutators need no
//// write-back and the threaded mutators return the rebound record carrying the SAME handle. This
//// module NEVER calls `rt_trap`; the `emit_core` seam does the `{ok,_}`/`{error,R}` → raise.
////
//// **Behaviour is frozen** (the §11 security invariant, G6): little-endian; no-wrap effective address
//// (never masked); trap-before-write (all-or-nothing multi-byte stores); a bounds-check on every
//// checked access; the reserved max-pages cap; f32/f64 as raw-byte moves over the IEEE bit pattern.
//// All identical to the paged reference (native by construction; paged by delegation) — so tier-N is
//// byte-identical to the spec via the shared oracle.
////
//// **Coercion soundness.** Under `mem_tier == Nif` an OWN memory is produced SOLELY by this module's
//// `fresh`/`fresh64`, so its opaque `Dynamic` is always THIS tier's handle: a native resource when the
//// `.so` is loaded (→ `enif_get_resource` is sound), else a paged `Mem` (→ delegating to `rt_mem`'s
//// coercing entry points is sound).
////
//// **The one exception is an IMPORTED memory.** A module may `(import "spectest" "memory" …)`, and
//// `link.spectest_export` builds the provided memory with the PAGED tier UNCONDITIONALLY
//// (`rt_mem.fresh`), tier-agnostically — so under a loaded `.so` the `mem` slot can hold a paged `Mem`
//// even though `nif_available()` is `true`. Handing that foreign handle to a native `@external`
//// (`enif_get_resource`) FAILS with `badarg` — NOT the WebAssembly `Error(MemoryOutOfBounds)` an
//// out-of-bounds active-data segment must raise (the S15-03 native `init_data` bug: `data.wast`'s
//// imported-memory OOB cases raised `badarg`, not the trap). The instantiation-time SEGMENT + BULK
//// writers (`init_data*`/`fill`/`copy`/`init` + `t_*` twins) — the ops that receive an imported handle
//// — therefore DISCRIMINATE on the handle shape (`is_native_mem`): a native resource is served by the
//// C, an imported paged `Mem` is DELEGATED to `rt_mem` (byte-identical by construction, so a genuine
//// OOB returns `Error(MemoryOutOfBounds)` from the paged core). A paged `Mem` is a Gleam record → an
//// Erlang TUPLE; a native resource is an opaque ERTS resource term (a reference — never a tuple), so
//// the discriminator is stable and under this module's control.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}
import twocore/ir.{type TrapReason}
import twocore/runtime/rt_mem
import twocore/runtime/rt_mem_atomics
import twocore/runtime/rt_meter
import twocore/runtime/rt_state.{type InstanceState}

// ───────────────────────────── the frozen NIF ABI (@external into the shim) ─────────────────────────────
//
// One `@external` per §3.2 export, each targeting its `nif_`-prefixed name in the frozen shim
// `twocore_rt_mem_nif_ffi`. Every load/store passes the COMBINED `ea` (never `addr`/`offset`
// separately). The term shapes are the frozen ABI: `Ok(x)` = `{ok, x}`, `Error(MemoryOutOfBounds)`
// = `{error, memory_out_of_bounds}`, `Nil` = the atom `nil`, `Bool` = `true`/`false`, `BitArray` =
// an Erlang binary. When the `.so` is NOT attached the shim stubs raise `nif_error(nif_not_loaded)`
// — so these are called ONLY under `nif_available()` (which the `.erl` stub answers `false`).

/// `true` iff the native `.so` is attached (the C body returns `true`; the `.erl` stub `false`). THE
/// dispatch switch: `true` ⇒ native arm, `false` ⇒ paged-delegate arm. Never raises.
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_available")
fn nif_available() -> Bool

/// `erlang:is_tuple/1` — a cheap guard BIF. A paged `Mem` is a Gleam record → an Erlang TUPLE; a
/// native tier-N resource is an opaque ERTS resource term (a reference — never a tuple).
@external(erlang, "erlang", "is_tuple")
fn is_tuple(term: Dynamic) -> Bool

/// `True` iff `h` is a NATIVE tier-N resource (serve it from the C), `False` iff it is an IMPORTED
/// paged `Mem` that must be delegated to the paged core `rt_mem` (see the module doc's "Coercion
/// soundness"). Discriminates on the stable paged shape: a paged `Mem` is a Gleam record → an Erlang
/// tuple, so `!is_tuple(h)` ⇒ a native resource. This is the guard the SEGMENT + BULK writers use so an
/// imported-memory OOB returns `Error(MemoryOutOfBounds)` from `rt_mem` rather than a `badarg` from
/// `enif_get_resource` failing on a foreign handle. Only meaningful under `nif_available()`; when the
/// `.so` is unloaded EVERY handle is a paged `Mem` (a tuple), so this is `False` and all ops delegate.
fn is_native_mem(h: Dynamic) -> Bool {
  !is_tuple(h)
}

/// Allocate a reserved buffer of `reserve_bytes`, zero-filled, with the live watermark at
/// `min_bytes`. Returns the opaque resource handle.
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_fresh")
fn nif_fresh(min_bytes: Int, reserve_bytes: Int) -> Dynamic

/// Load `bytes` LE bytes at `ea`, sign/zero-extended to `result_width`. `{ok, v}` | OOB.
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_load")
fn nif_load(
  res: Dynamic,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  ea: Int,
) -> Result(Int, TrapReason)

/// Store the low `bytes` bytes of `value` LE at `ea` (trap-before-write). `{ok, nil}` | OOB.
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_store")
fn nif_store(
  res: Dynamic,
  bytes: Int,
  ea: Int,
  value: Int,
) -> Result(Nil, TrapReason)

/// Current size in pages (`byte_len / 65536`).
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_size")
fn nif_size(res: Dynamic) -> Int

/// Bump the watermark by `delta` pages within the reservation; previous pages, or `-1` on failure.
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_grow")
fn nif_grow(res: Dynamic, delta: Int) -> Int

/// Write `bytes` at `ea` (whole-range check up front). `{ok, nil}` | OOB.
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_init_data")
fn nif_init_data(
  res: Dynamic,
  ea: Int,
  bytes: BitArray,
) -> Result(Nil, TrapReason)

/// Read `n` bytes at `ea` in ascending-address order. `{ok, bytes}` | OOB. The v128 byte seam.
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_load_bytes")
fn nif_load_bytes(res: Dynamic, ea: Int, n: Int) -> Result(BitArray, TrapReason)

/// Write the run `bytes` at `ea` (trap-before-write). `{ok, nil}` | OOB. The v128 byte seam.
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_store_bytes")
fn nif_store_bytes(
  res: Dynamic,
  ea: Int,
  bytes: BitArray,
) -> Result(Nil, TrapReason)

/// Fill `count` bytes at `dest` with `value & 0xFF` (eager bounds). `{ok, nil}` | OOB.
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_fill")
fn nif_fill(
  res: Dynamic,
  dest: Int,
  value: Int,
  count: Int,
) -> Result(Nil, TrapReason)

/// memmove `count` bytes `src → dst` (cross-resource when the handles differ; eager bounds on both).
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_copy")
fn nif_copy(
  dst_res: Dynamic,
  src_res: Dynamic,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Nil, TrapReason)

/// Copy `count` bytes from `seg[src..]` to `dst` (eager bounds on segment + memory). `{ok, nil}` | OOB.
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_init")
fn nif_init(
  res: Dynamic,
  seg: BitArray,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Nil, TrapReason)

/// The whole in-bounds byte image `[0, byte_len)` — the differential hook (tests only).
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_to_flat")
fn nif_to_flat(res: Dynamic) -> BitArray

/// UNCHECKED load — `nif_load` MINUS the bounds compare (a raw LE deref). Bare `int`.
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_load_unchecked")
fn nif_load_unchecked(
  res: Dynamic,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  ea: Int,
) -> Int

/// UNCHECKED store — `nif_store` MINUS the bounds compare (a raw LE write). Bare `nil`.
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_store_unchecked")
fn nif_store_unchecked(res: Dynamic, bytes: Int, ea: Int, value: Int) -> Nil

// ───────────────────────────── the cell-backed family (state_strategy: Cell) ─────────────────────────────

/// Build a FRESH tier-N memory of `min_pages` zero-filled 64 KiB pages, returning the opaque handle
/// as `Dynamic` (ready for `rt_state.seed`).
///
/// - `min_pages`: the initial page count (the module's declared memory minimum).
/// - `max_pages`: the declared maximum in pages, or `None` for "unbounded" (still subject to
///   `safe_cap`). The baked effective max is `min(declared_max ?? safe_cap, safe_cap, 65536)`.
/// - `safe_cap`: the finite Safe max-pages cap.
/// - Returns the fresh memory as `Dynamic` (opaque). Total on the admissible path.
///
/// **Native arm** (`.so` loaded): the tier RESERVES its buffer up front (never realloc'd) — the
/// reservation `reserve = max(min_pages, effective_max)` pages reuses the atomics reservation caps
/// (`rt_mem_atomics.reservation`), so `nif_fresh` gets `MinBytes = min_pages * 65536` and
/// `ReserveBytes = reserve * 65536`; `max_bytes` encodes the paged `max` so `grow` is bit-identical.
/// An over-cap reservation is INADMISSIBLE under tier-N (it must use paged — enforced at link time by
/// `validate_binding`); reaching it here is unreachable-post-validation and fails closed with a
/// node-safe `panic` (mirroring `rt_mem_atomics.a_fresh`). **Fallback arm**: `rt_mem.fresh` (paged).
pub fn fresh(min_pages: Int, max_pages: Option(Int), safe_cap: Int) -> Dynamic {
  case nif_available() {
    True ->
      case
        rt_mem_atomics.reservation(
          min_pages,
          max_pages,
          safe_cap,
          rt_mem_atomics.atomics_reserve_cap_pages,
        )
      {
        Ok(reserve) ->
          nif_fresh(min_pages * rt_mem.page_bytes, reserve * rt_mem.page_bytes)
        Error(Nil) ->
          panic as "rt_mem_nif.fresh: over-cap reservation (inadmissible under tier-N; must use paged — unreachable post-validation)"
      }
    False -> rt_mem.fresh(min_pages, max_pages, safe_cap)
  }
}

/// Build a FRESH tier-N 64-bit (`Idx64`, memory64) memory. Only ever emitted for a TINY BOUNDED
/// 64-bit memory: an over-cap / unbounded 64-bit `nif` binding is fail-closed rejected at link time
/// (`validate_binding` via `reservation64`), because the native tier RESERVES (it cannot back a
/// 256 TiB sparse memory).
///
/// - `min_pages`/`max_pages`/`mem64_cap`: see `rt_mem.fresh64`.
/// - Returns the fresh memory as `Dynamic` (opaque). Total on the admissible path.
///
/// **Native arm**: reserve via `rt_mem_atomics.reservation64` (folding the 64-bit cap) → `nif_fresh`;
/// over-cap is unreachable-post-validation and fails closed. **Fallback arm**: `rt_mem.fresh64`.
pub fn fresh64(
  min_pages: Int,
  max_pages: Option(Int),
  mem64_cap: Int,
) -> Dynamic {
  case nif_available() {
    True ->
      case
        rt_mem_atomics.reservation64(
          min_pages,
          max_pages,
          mem64_cap,
          rt_mem_atomics.atomics_reserve_cap_pages,
        )
      {
        Ok(reserve) ->
          nif_fresh(min_pages * rt_mem.page_bytes, reserve * rt_mem.page_bytes)
        Error(Nil) ->
          panic as "rt_mem_nif.fresh64: over-cap 64-bit reservation (inadmissible under tier-N; must use paged — unreachable post-validation)"
      }
    False -> rt_mem.fresh64(min_pages, max_pages, mem64_cap)
  }
}

/// Load `bytes` bytes (1/2/4/8) little-endian at `ea = addr + offset`, normalised to `result_width`
/// bits (`signed` ⇒ sign-extend, else zero-extend). Reads the handle from the cell (index 0).
///
/// - `bytes`: the access width in bytes (1/2/4/8).
/// - `signed`: whether a sub-word load is sign-extended to `result_width` (else zero-extended).
/// - `result_width`: 32 or 64 — disambiguates `i32.load8_s` from `i64.load8_s`.
/// - `addr`/`offset`: the unsigned i32 base and static offset (combined as a bignum — no wrap).
/// - Returns `Ok(bits)`, or `Error(MemoryOutOfBounds)` iff `ea + bytes > byte_len`. Read-only.
///
/// Native: `nif_load` on the cell resource with the combined `ea`. Fallback: `rt_mem.load`.
pub fn load(
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  case nif_available() {
    True ->
      nif_load(rt_state.mem_at(0), bytes, signed, result_width, addr + offset)
    False -> rt_mem.load(bytes, signed, result_width, addr, offset)
  }
}

/// Store `value`'s low `bytes` bytes (1/2/4/8) little-endian at `ea`. Traps BEFORE any byte is
/// written if out of bounds (all-or-nothing — zero corruption).
///
/// - `bytes`: the store width in bytes (1/2/4/8); the value's sign is irrelevant.
/// - `addr`/`offset`: the base and static offset (bignum — no wrap).
/// - `value`: the raw bit pattern whose low `bytes` bytes are written.
/// - Returns `Ok(Nil)` on success, or `Error(MemoryOutOfBounds)` with ZERO mutation.
///
/// Native: `nif_store` mutates the cell resource IN PLACE — NO write-back (stable handle). Fallback:
/// `rt_mem.store` (rebuild + `mem_put`).
pub fn store(
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(Nil, TrapReason) {
  case nif_available() {
    True -> nif_store(rt_state.mem_at(0), bytes, addr + offset, value)
    False -> rt_mem.store(bytes, addr, value, offset)
  }
}

/// The current size of this process's memory, in 64 KiB pages (`memory.size`). Total; read-only.
/// Native: `nif_size`. Fallback: `rt_mem.size`.
pub fn size() -> Int {
  case nif_available() {
    True -> nif_size(rt_state.mem_at(0))
    False -> rt_mem.size()
  }
}

/// Grow this process's memory by `delta` pages (`memory.grow`).
///
/// - `delta`: the number of pages to add (≥ 0).
/// - Returns the PREVIOUS size in pages on success, or `-1` if the growth would exceed the reserved
///   max (in which case NOTHING is allocated and NO fuel is charged). Newly-added pages are
///   zero-filled. On success it charges `delta * page_bytes` fuel (proportional to the bytes made
///   addressable, P2), IDENTICALLY on both arms — a failed grow (`-1`) charges nothing, so nif and
///   paged meter identically.
///
/// Native: `nif_grow` bumps the watermark in place (stable handle — no write-back), then the fuel is
/// charged here on `prev != -1`. Fallback: `rt_mem.grow`.
pub fn grow(delta: Int) -> Int {
  case nif_available() {
    True -> grow_charged(nif_grow(rt_state.mem_at(0), delta), delta)
    False -> rt_mem.grow(delta)
  }
}

/// Shared grow-fuel accounting for the native arm: charge `delta * page_bytes` ONLY when the grow
/// succeeded (`prev != -1`), returning `prev`. A failed grow charges nothing (metering parity).
fn grow_charged(prev: Int, delta: Int) -> Int {
  case prev {
    -1 -> -1
    _ -> {
      rt_meter.charge(delta * rt_mem.page_bytes)
      prev
    }
  }
}

/// Write an active DATA segment's `bytes` into this process's memory at `offset`, at instantiation.
/// Whole-range bounds-checked (no-wrap). `Ok(Nil)`, or `Error(MemoryOutOfBounds)` (nothing written).
/// Native (own memory): `nif_init_data` (`ea = offset`). An IMPORTED paged memory OR an unloaded `.so`:
/// `rt_mem.init_data` — so an OOB active segment into an imported memory returns
/// `Error(MemoryOutOfBounds)`, not a `badarg` (S15-03 fix; see the module doc's "Coercion soundness").
pub fn init_data(offset: Int, bytes: BitArray) -> Result(Nil, TrapReason) {
  case nif_available() {
    True -> {
      let h = rt_state.mem_at(0)
      case is_native_mem(h) {
        True -> nif_init_data(h, offset, bytes)
        False -> rt_mem.init_data(offset, bytes)
      }
    }
    False -> rt_mem.init_data(offset, bytes)
  }
}

// ───────────────────────────── the threaded family (state_strategy: Threaded) ─────────────────────────────
//
// The purely-functional twin: generated code under `Threaded` threads the `InstanceState` record.
// Reads leave `st` untouched; mutators return the rebound record. On the native arm the resource is
// mutable, so `t_store` mutates it in place and rebinds the SAME handle — the SIGNATURE is identical
// to the paged skeleton (which rebinds a NEW immutable `Mem`), which is why the seam needs no change.

/// Threaded load (read-only): projects `st.mem`, drives the load, leaves `st` UNCHANGED. See `load`.
pub fn t_load(
  st: InstanceState,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  case nif_available() {
    True ->
      nif_load(rt_state.mem(st), bytes, signed, result_width, addr + offset)
    False -> rt_mem.t_load(st, bytes, signed, result_width, addr, offset)
  }
}

/// Threaded store. Bounds-checks first (trap-before-write), then returns `Ok(st')` — the rebound
/// record whose `mem` is the (in-place-mutated, same) handle — or `Error(MemoryOutOfBounds)` with
/// `st` untouched (zero mutation). See `store`.
pub fn t_store(
  st: InstanceState,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(InstanceState, TrapReason) {
  case nif_available() {
    True -> {
      let h = rt_state.mem(st)
      case nif_store(h, bytes, addr + offset, value) {
        Ok(Nil) -> Ok(rt_state.with_mem(st, h))
        Error(reason) -> Error(reason)
      }
    }
    False -> rt_mem.t_store(st, bytes, addr, value, offset)
  }
}

/// Threaded `memory.size` (read-only): the page count of `st.mem`; `st` unchanged.
pub fn t_size(st: InstanceState) -> Int {
  case nif_available() {
    True -> nif_size(rt_state.mem(st))
    False -> rt_mem.t_size(st)
  }
}

/// Threaded `memory.grow`. Returns `#(prev_pages, st')` (rebinding `st.mem` to the grown, same
/// handle), or `#(-1, st)` past the max/cap (unchanged, nothing allocated). Charges
/// `delta * page_bytes` grow fuel on the SUCCESS path (P2 parity with the cell `grow`). See `grow`.
pub fn t_grow(st: InstanceState, delta: Int) -> #(Int, InstanceState) {
  case nif_available() {
    True -> {
      let h = rt_state.mem(st)
      case nif_grow(h, delta) {
        -1 -> #(-1, st)
        prev -> {
          rt_meter.charge(delta * rt_mem.page_bytes)
          #(prev, rt_state.with_mem(st, h))
        }
      }
    }
    False -> rt_mem.t_grow(st, delta)
  }
}

/// Threaded active-data-segment write at instantiation. Bounds-checks the whole range up front, then
/// returns `Ok(st')` (rebinding `st.mem`), or `Error(MemoryOutOfBounds)` (nothing written). See
/// `init_data`.
pub fn t_init_data(
  st: InstanceState,
  offset: Int,
  bytes: BitArray,
) -> Result(InstanceState, TrapReason) {
  case nif_available() {
    True -> {
      let h = rt_state.mem(st)
      case is_native_mem(h) {
        True ->
          case nif_init_data(h, offset, bytes) {
            Ok(Nil) -> Ok(rt_state.with_mem(st, h))
            Error(reason) -> Error(reason)
          }
        False -> rt_mem.t_init_data(st, offset, bytes)
      }
    }
    False -> rt_mem.t_init_data(st, offset, bytes)
  }
}

// ───────────────────────────── the differential hook (§D/§11) ─────────────────────────────

/// The tier's whole in-bounds byte image — the differential reference the oracle compares
/// byte-for-byte after each op. `mem` is passed directly by the test (the handle from the cell /
/// record). Dispatches on the GIVEN handle (not a global flag): a native resource → `nif_to_flat`, an
/// imported/paged `Mem` → `rt_mem.to_flat`. O(byte_len); tests only.
pub fn to_flat(mem: Dynamic) -> BitArray {
  case is_native_mem(mem) {
    True -> nif_to_flat(mem)
    False -> rt_mem.to_flat(mem)
  }
}

// ───────────────────────────── multi-memory + bulk (the `_at` twins + fill/copy/init) ─────────────────────────────
//
// The index-routed cell family: each op sources the handle from the mem-index slot
// (`rt_state.mem_at(mem_idx)` / `with_mem_at`), so `load_at(0, …) ≡ load(…)`. Mutators mutate the
// resource in place (native) so no write-back; bulk ops charge `count` fuel on the SUCCESS path.

/// `load` from memory `mem_idx` (read-only). Native: `nif_load` on slot `mem_idx`. Fallback:
/// `rt_mem.load_at`.
pub fn load_at(
  mem_idx: Int,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  case nif_available() {
    True ->
      nif_load(
        rt_state.mem_at(mem_idx),
        bytes,
        signed,
        result_width,
        addr + offset,
      )
    False -> rt_mem.load_at(mem_idx, bytes, signed, result_width, addr, offset)
  }
}

/// `store` into memory `mem_idx`. Native: `nif_store` in place (no write-back). Fallback:
/// `rt_mem.store_at`.
pub fn store_at(
  mem_idx: Int,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(Nil, TrapReason) {
  case nif_available() {
    True -> nif_store(rt_state.mem_at(mem_idx), bytes, addr + offset, value)
    False -> rt_mem.store_at(mem_idx, bytes, addr, value, offset)
  }
}

/// `memory.size` of memory `mem_idx`. Native: `nif_size` on slot `mem_idx`. Fallback:
/// `rt_mem.size_at`.
pub fn size_at(mem_idx: Int) -> Int {
  case nif_available() {
    True -> nif_size(rt_state.mem_at(mem_idx))
    False -> rt_mem.size_at(mem_idx)
  }
}

/// `memory.grow` memory `mem_idx` by `delta` pages (charges `delta * page_bytes` fuel on success).
/// Native: `nif_grow` in place. Fallback: `rt_mem.grow_at`.
pub fn grow_at(mem_idx: Int, delta: Int) -> Int {
  case nif_available() {
    True -> grow_charged(nif_grow(rt_state.mem_at(mem_idx), delta), delta)
    False -> rt_mem.grow_at(mem_idx, delta)
  }
}

/// Active DATA-segment write into memory `mem_idx` at instantiation. Native (own memory):
/// `nif_init_data`. IMPORTED paged memory / unloaded `.so`: `rt_mem.init_data_at` (S15-03 fix).
pub fn init_data_at(
  mem_idx: Int,
  offset: Int,
  bytes: BitArray,
) -> Result(Nil, TrapReason) {
  case nif_available() {
    True -> {
      let h = rt_state.mem_at(mem_idx)
      case is_native_mem(h) {
        True -> nif_init_data(h, offset, bytes)
        False -> rt_mem.init_data_at(mem_idx, offset, bytes)
      }
    }
    False -> rt_mem.init_data_at(mem_idx, offset, bytes)
  }
}

/// `memory.fill` on memory `mem_idx` (eager bounds, `count` fuel on success). Native: `nif_fill`,
/// charging Gleam-side on `Ok`. Fallback: `rt_mem.fill`.
pub fn fill(
  mem_idx: Int,
  dest: Int,
  value: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  case nif_available() {
    True -> {
      let h = rt_state.mem_at(mem_idx)
      case is_native_mem(h) {
        True -> charge_count(nif_fill(h, dest, value, count), count)
        False -> rt_mem.fill(mem_idx, dest, value, count)
      }
    }
    False -> rt_mem.fill(mem_idx, dest, value, count)
  }
}

/// `memory.copy` from memory `src_mem` to `dst_mem` (memmove, cross-memory-capable, `count` fuel on
/// success). Native (both own memories): `nif_copy` on the two sourced handles. If EITHER handle is an
/// IMPORTED paged memory (or the `.so` is unloaded): `rt_mem.copy` — a single module's memories are one
/// kind, so a mixed native/paged pair never arises in practice (S15-03 fix).
pub fn copy(
  dst_mem: Int,
  src_mem: Int,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  case nif_available() {
    True -> {
      let dh = rt_state.mem_at(dst_mem)
      let sh = rt_state.mem_at(src_mem)
      case is_native_mem(dh) && is_native_mem(sh) {
        True -> charge_count(nif_copy(dh, sh, dst, src, count), count)
        False -> rt_mem.copy(dst_mem, src_mem, dst, src, count)
      }
    }
    False -> rt_mem.copy(dst_mem, src_mem, dst, src, count)
  }
}

/// `memory.init` into memory `mem_idx` from segment bytes `seg` (ε if dropped; eager bounds, `count`
/// fuel on success). Native: `nif_init`. Fallback: `rt_mem.init`.
pub fn init(
  mem_idx: Int,
  seg: BitArray,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  case nif_available() {
    True -> {
      let h = rt_state.mem_at(mem_idx)
      case is_native_mem(h) {
        True -> charge_count(nif_init(h, seg, dst, src, count), count)
        False -> rt_mem.init(mem_idx, seg, dst, src, count)
      }
    }
    False -> rt_mem.init(mem_idx, seg, dst, src, count)
  }
}

/// Shared bulk-op fuel accounting for the native (cell) arm: charge `count` fuel ONLY when the op
/// succeeded (`Ok`), passing the result through unchanged. A trapping op charges nothing.
fn charge_count(
  result: Result(Nil, TrapReason),
  count: Int,
) -> Result(Nil, TrapReason) {
  case result {
    Ok(Nil) -> {
      rt_meter.charge(count)
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// Threaded `load` from memory `mem_idx` (read-only). Native: `nif_load` on slot `mem_idx`.
/// Fallback: `rt_mem.t_load_at`.
pub fn t_load_at(
  st: InstanceState,
  mem_idx: Int,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  case nif_available() {
    True ->
      nif_load(
        rt_state.t_mem_at(st, mem_idx),
        bytes,
        signed,
        result_width,
        addr + offset,
      )
    False ->
      rt_mem.t_load_at(st, mem_idx, bytes, signed, result_width, addr, offset)
  }
}

/// Threaded `store` into memory `mem_idx`. Native: `nif_store` in place, rebinding the same handle.
/// Fallback: `rt_mem.t_store_at`.
pub fn t_store_at(
  st: InstanceState,
  mem_idx: Int,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(InstanceState, TrapReason) {
  case nif_available() {
    True -> {
      let h = rt_state.t_mem_at(st, mem_idx)
      case nif_store(h, bytes, addr + offset, value) {
        Ok(Nil) -> Ok(rt_state.t_with_mem_at(st, mem_idx, h))
        Error(reason) -> Error(reason)
      }
    }
    False -> rt_mem.t_store_at(st, mem_idx, bytes, addr, value, offset)
  }
}

// ── the v128-memory BitArray seam (S4): checked whole-run byte moves emit_core composes with rt_simd.

/// `load_bytes` on the cell memory (index 0). Native: `nif_load_bytes`. Fallback: `rt_mem.load_bytes`.
pub fn load_bytes(
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  case nif_available() {
    True -> nif_load_bytes(rt_state.mem_at(0), addr + offset, n)
    False -> rt_mem.load_bytes(addr, offset, n)
  }
}

/// `store_bytes` into the cell memory (index 0). Native: `nif_store_bytes` in place. Fallback:
/// `rt_mem.store_bytes`.
pub fn store_bytes(
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(Nil, TrapReason) {
  case nif_available() {
    True -> nif_store_bytes(rt_state.mem_at(0), addr + offset, bytes)
    False -> rt_mem.store_bytes(addr, bytes, offset)
  }
}

/// `load_bytes` on memory `mem_idx`. Native: `nif_load_bytes` on slot `mem_idx`. Fallback:
/// `rt_mem.load_bytes_at`.
pub fn load_bytes_at(
  mem_idx: Int,
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  case nif_available() {
    True -> nif_load_bytes(rt_state.mem_at(mem_idx), addr + offset, n)
    False -> rt_mem.load_bytes_at(mem_idx, addr, offset, n)
  }
}

/// `store_bytes` on memory `mem_idx`. Native: `nif_store_bytes` in place. Fallback:
/// `rt_mem.store_bytes_at`.
pub fn store_bytes_at(
  mem_idx: Int,
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(Nil, TrapReason) {
  case nif_available() {
    True -> nif_store_bytes(rt_state.mem_at(mem_idx), addr + offset, bytes)
    False -> rt_mem.store_bytes_at(mem_idx, addr, bytes, offset)
  }
}

/// Threaded `load_bytes` (read-only). Native: `nif_load_bytes`. Fallback: `rt_mem.t_load_bytes`.
pub fn t_load_bytes(
  st: InstanceState,
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  case nif_available() {
    True -> nif_load_bytes(rt_state.mem(st), addr + offset, n)
    False -> rt_mem.t_load_bytes(st, addr, offset, n)
  }
}

/// Threaded `store_bytes`. Native: `nif_store_bytes` in place, rebinding the same handle. Fallback:
/// `rt_mem.t_store_bytes`.
pub fn t_store_bytes(
  st: InstanceState,
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(InstanceState, TrapReason) {
  case nif_available() {
    True -> {
      let h = rt_state.mem(st)
      case nif_store_bytes(h, addr + offset, bytes) {
        Ok(Nil) -> Ok(rt_state.with_mem(st, h))
        Error(reason) -> Error(reason)
      }
    }
    False -> rt_mem.t_store_bytes(st, addr, bytes, offset)
  }
}

/// Threaded `load_bytes` on memory `mem_idx`. Native: `nif_load_bytes` on slot `mem_idx`. Fallback:
/// `rt_mem.t_load_bytes_at`.
pub fn t_load_bytes_at(
  st: InstanceState,
  mem_idx: Int,
  addr: Int,
  offset: Int,
  n: Int,
) -> Result(BitArray, TrapReason) {
  case nif_available() {
    True -> nif_load_bytes(rt_state.t_mem_at(st, mem_idx), addr + offset, n)
    False -> rt_mem.t_load_bytes_at(st, mem_idx, addr, offset, n)
  }
}

/// Threaded `store_bytes` on memory `mem_idx`. Native: `nif_store_bytes` in place. Fallback:
/// `rt_mem.t_store_bytes_at`.
pub fn t_store_bytes_at(
  st: InstanceState,
  mem_idx: Int,
  addr: Int,
  bytes: BitArray,
  offset: Int,
) -> Result(InstanceState, TrapReason) {
  case nif_available() {
    True -> {
      let h = rt_state.t_mem_at(st, mem_idx)
      case nif_store_bytes(h, addr + offset, bytes) {
        Ok(Nil) -> Ok(rt_state.t_with_mem_at(st, mem_idx, h))
        Error(reason) -> Error(reason)
      }
    }
    False -> rt_mem.t_store_bytes_at(st, mem_idx, addr, bytes, offset)
  }
}

/// Threaded `memory.size` of memory `mem_idx`. Native: `nif_size` on slot `mem_idx`. Fallback:
/// `rt_mem.t_size_at`.
pub fn t_size_at(st: InstanceState, mem_idx: Int) -> Int {
  case nif_available() {
    True -> nif_size(rt_state.t_mem_at(st, mem_idx))
    False -> rt_mem.t_size_at(st, mem_idx)
  }
}

/// Threaded `memory.grow` of memory `mem_idx`. Native: `nif_grow` in place, charging fuel on success
/// and rebinding the same handle. Fallback: `rt_mem.t_grow_at`.
pub fn t_grow_at(
  st: InstanceState,
  mem_idx: Int,
  delta: Int,
) -> #(Int, InstanceState) {
  case nif_available() {
    True -> {
      let h = rt_state.t_mem_at(st, mem_idx)
      case nif_grow(h, delta) {
        -1 -> #(-1, st)
        prev -> {
          rt_meter.charge(delta * rt_mem.page_bytes)
          #(prev, rt_state.t_with_mem_at(st, mem_idx, h))
        }
      }
    }
    False -> rt_mem.t_grow_at(st, mem_idx, delta)
  }
}

/// Threaded active DATA-segment write into memory `mem_idx`. Native: `nif_init_data`. Fallback:
/// `rt_mem.t_init_data_at`.
pub fn t_init_data_at(
  st: InstanceState,
  mem_idx: Int,
  offset: Int,
  bytes: BitArray,
) -> Result(InstanceState, TrapReason) {
  case nif_available() {
    True -> {
      let h = rt_state.t_mem_at(st, mem_idx)
      case is_native_mem(h) {
        True ->
          case nif_init_data(h, offset, bytes) {
            Ok(Nil) -> Ok(rt_state.t_with_mem_at(st, mem_idx, h))
            Error(reason) -> Error(reason)
          }
        False -> rt_mem.t_init_data_at(st, mem_idx, offset, bytes)
      }
    }
    False -> rt_mem.t_init_data_at(st, mem_idx, offset, bytes)
  }
}

/// Threaded `memory.fill` on memory `mem_idx`. Native: `nif_fill`, charging `count` fuel on success
/// and rebinding the same handle. Fallback: `rt_mem.t_fill`.
pub fn t_fill(
  st: InstanceState,
  mem_idx: Int,
  dest: Int,
  value: Int,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  case nif_available() {
    True -> {
      let h = rt_state.t_mem_at(st, mem_idx)
      case is_native_mem(h) {
        True ->
          t_charge_count(nif_fill(h, dest, value, count), st, mem_idx, h, count)
        False -> rt_mem.t_fill(st, mem_idx, dest, value, count)
      }
    }
    False -> rt_mem.t_fill(st, mem_idx, dest, value, count)
  }
}

/// Threaded `memory.copy` from memory `src_mem` to `dst_mem` (memmove, cross-memory-capable). Native:
/// `nif_copy` on the two sourced handles, charging `count` fuel on success and rebinding `dst_mem`.
/// Fallback: `rt_mem.t_copy`.
pub fn t_copy(
  st: InstanceState,
  dst_mem: Int,
  src_mem: Int,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  case nif_available() {
    True -> {
      let dh = rt_state.t_mem_at(st, dst_mem)
      let sh = rt_state.t_mem_at(st, src_mem)
      case is_native_mem(dh) && is_native_mem(sh) {
        True ->
          t_charge_count(
            nif_copy(dh, sh, dst, src, count),
            st,
            dst_mem,
            dh,
            count,
          )
        False -> rt_mem.t_copy(st, dst_mem, src_mem, dst, src, count)
      }
    }
    False -> rt_mem.t_copy(st, dst_mem, src_mem, dst, src, count)
  }
}

/// Threaded `memory.init` into memory `mem_idx` from segment bytes `seg` (ε if dropped). Native:
/// `nif_init`, charging `count` fuel on success and rebinding `mem_idx`. Fallback: `rt_mem.t_init`.
pub fn t_init(
  st: InstanceState,
  mem_idx: Int,
  seg: BitArray,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  case nif_available() {
    True -> {
      let h = rt_state.t_mem_at(st, mem_idx)
      case is_native_mem(h) {
        True ->
          t_charge_count(
            nif_init(h, seg, dst, src, count),
            st,
            mem_idx,
            h,
            count,
          )
        False -> rt_mem.t_init(st, mem_idx, seg, dst, src, count)
      }
    }
    False -> rt_mem.t_init(st, mem_idx, seg, dst, src, count)
  }
}

/// Shared bulk-op fuel + rebind accounting for the native (threaded) arm: on `Ok`, charge `count`
/// fuel and return `Ok(st')` with slot `mem_idx` rebound to the (in-place-mutated) handle `h`; on a
/// trap, return `Error` with `st` untouched and no charge.
fn t_charge_count(
  result: Result(Nil, TrapReason),
  st: InstanceState,
  mem_idx: Int,
  h: Dynamic,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  case result {
    Ok(Nil) -> {
      rt_meter.charge(count)
      Ok(rt_state.t_with_mem_at(st, mem_idx, h))
    }
    Error(reason) -> Error(reason)
  }
}

// ───────────────────────────── the unchecked fast path (S4 — dead until S15-03 routes it) ─────────────────────────────
//
// The Phase-10 lever: `load_unchecked`/`store_unchecked` (+ `t_` twins) skip the bounds compare (a
// raw deref). SOUND only because the loop-versioning guard has already proved the whole range in
// bounds before this arm runs (trap-preservation is absolute). On tier-N a bug here is a raw OOB
// access, which is why the tier is Unsafe-only and the guard is load-bearing. `emit_core` gates
// `mem == 0` for unchecked, so there are NO `_at` unchecked heads. S15-02 lands these heads green and
// dead-until-called; S15-03 flips the `emit_core` whitelist so they route.

/// UNCHECKED cell load — `load` MINUS the bounds check/`Result`. Returns the raw bit pattern. Native:
/// `nif_load_unchecked` (a raw C deref). Fallback: `rt_mem.load_unchecked`.
pub fn load_unchecked(
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Int {
  case nif_available() {
    True ->
      nif_load_unchecked(
        rt_state.mem_at(0),
        bytes,
        signed,
        result_width,
        addr + offset,
      )
    False -> rt_mem.load_unchecked(bytes, signed, result_width, addr, offset)
  }
}

/// UNCHECKED cell store — `store` MINUS the bounds check/`Result`. Native: `nif_store_unchecked` (a
/// raw C write) in place; returns `Nil`. Fallback: `rt_mem.store_unchecked`.
pub fn store_unchecked(bytes: Int, addr: Int, value: Int, offset: Int) -> Nil {
  case nif_available() {
    True -> nif_store_unchecked(rt_state.mem_at(0), bytes, addr + offset, value)
    False -> rt_mem.store_unchecked(bytes, addr, value, offset)
  }
}

/// UNCHECKED threaded load — `t_load` MINUS the bounds check/`Result`. `st` unchanged. Native:
/// `nif_load_unchecked`. Fallback: `rt_mem.t_load_unchecked`.
pub fn t_load_unchecked(
  st: InstanceState,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Int {
  case nif_available() {
    True ->
      nif_load_unchecked(
        rt_state.mem(st),
        bytes,
        signed,
        result_width,
        addr + offset,
      )
    False ->
      rt_mem.t_load_unchecked(st, bytes, signed, result_width, addr, offset)
  }
}

/// UNCHECKED threaded store — `t_store` MINUS the bounds check/`Result`. Rebinds the same (in-place-
/// mutated) handle. Native: `nif_store_unchecked`. Fallback: `rt_mem.t_store_unchecked`.
pub fn t_store_unchecked(
  st: InstanceState,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> InstanceState {
  case nif_available() {
    True -> {
      let h = rt_state.mem(st)
      let _ = nif_store_unchecked(h, bytes, addr + offset, value)
      rt_state.with_mem(st, h)
    }
    False -> rt_mem.t_store_unchecked(st, bytes, addr, value, offset)
  }
}
