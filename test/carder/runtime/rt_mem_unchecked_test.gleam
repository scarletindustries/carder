//// Phase-10 unit 04 — the UNCHECKED memory entry points differential (`rt_mem` + `rt_mem_atomics`).
////
//// The correctness bar (N5): for every IN-BOUNDS access an unchecked op returns the IDENTICAL bits
//// as the checked oracle (across widths 1/2/4/8, signed/unsigned, various addr/offset). And an OOB
//// unchecked access is BEAM-SAFE — it returns a contained value (paged: zeros for an absent sparse
//// chunk), never a crash or corruption. The loop-versioning guard (unit 06) ensures an unchecked
//// access is never actually OOB; this proves the runtime degrades safely if it ever were.

import carder/runtime/rt_mem
import carder/runtime/rt_mem_atomics as rma
import gleam/list
import gleam/option.{Some}

const big_cap: Int = 100_000

const reserve_cap: Int = 4096

/// The in-bounds access matrix: `#(bytes, signed, result_width, addr, offset, value)`.
fn matrix() -> List(#(Int, Bool, Int, Int, Int, Int)) {
  [
    #(1, False, 32, 0, 0, 0xAB),
    #(1, True, 32, 3, 0, 0xFF),
    #(2, False, 32, 4, 0, 0xBEEF),
    #(2, True, 32, 6, 2, 0x8000),
    #(4, False, 32, 8, 0, 0x04030201),
    #(4, True, 32, 16, 4, 0xFFFFFFFF),
    #(8, False, 64, 24, 0, 0x0807060504030201),
    #(8, True, 64, 40, 8, 0x8000000000000000),
  ]
}

// ─────────────────────────── paged: unchecked ≡ checked (in-bounds) ───────────────────────────

pub fn paged_unchecked_matches_checked_in_bounds_test() {
  list.each(matrix(), fn(c) {
    let #(bytes, signed, rw, addr, offset, value) = c
    let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
    // store via each path (into a fresh memory) then load-back via BOTH paths.
    let assert Ok(checked_m) = rt_mem.mem_store(m, bytes, addr, value, offset)
    let unchecked_m = rt_mem.mem_store_unchecked(m, bytes, addr, value, offset)
    // the unchecked store wrote the identical bytes: a CHECKED load of both memories agrees.
    let assert Ok(from_checked) =
      rt_mem.mem_load(checked_m, bytes, signed, rw, addr, offset)
    let assert Ok(from_unchecked) =
      rt_mem.mem_load(unchecked_m, bytes, signed, rw, addr, offset)
    assert from_checked == from_unchecked
    // and the UNCHECKED load matches the checked load on the same memory.
    assert rt_mem.mem_load_unchecked(checked_m, bytes, signed, rw, addr, offset)
      == from_checked
  })
}

pub fn paged_oob_unchecked_is_beam_safe_test() {
  // A wildly OOB unchecked load returns contained ZEROS (absent sparse chunk) — no crash, no
  // corruption. Reaching this line at all proves it did not panic.
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  assert rt_mem.mem_load_unchecked(m, 4, False, 32, 9_000_000, 0) == 0
}

// ─────────────────────────── atomics: unchecked ≡ checked (in-bounds) ───────────────────────────

pub fn atomics_unchecked_matches_checked_in_bounds_test() {
  list.each(matrix(), fn(c) {
    let #(bytes, signed, rw, addr, offset, value) = c
    // NOTE: an `AtomicsBacked` `ref` mutates in place, so use a FRESH handle per direction.
    let a_checked = rma.a_fresh(1, Some(1), big_cap, reserve_cap)
    let assert Ok(_) = rma.a_store(a_checked, bytes, addr, value, offset)
    let assert Ok(from_checked) =
      rma.a_load(a_checked, bytes, signed, rw, addr, offset)

    let a_unchecked = rma.a_fresh(1, Some(1), big_cap, reserve_cap)
    let _ = rma.a_store_unchecked(a_unchecked, bytes, addr, value, offset)
    let from_unchecked =
      rma.a_load_unchecked(a_unchecked, bytes, signed, rw, addr, offset)
    assert from_unchecked == from_checked
  })
}
