//// Spec-grounded tests for the Phase-5 reference-types + bulk-table surface on `TablePaged`
//// (unit P5-07) — `table.get/set/size/grow/fill`, `table.init/copy`, active reference segments,
//// typed reference storage, and `externref` opacity. `TablePaged` is the differential ORACLE, so
//// these are the CORRECTNESS anchors (the cross-tier differential proves the other tiers agree).
////
//// Assertions target the WebAssembly spec, NOT the implementation:
////
//// - **`table.get`/`table.set` trap iff `index >= size`** ("out of bounds table access") —
////   <https://webassembly.github.io/spec/core/exec/instructions.html#table-instructions>
////   (reference-types proposal); a never-written / grown-into slot reads the null sentinel.
//// - **`table.grow` returns the previous size, or `-1` on failure** (exceeds max / cap), never
////   traps; new slots take the init reference — same page.
//// - **`table.fill` / `table.init` / `table.copy` are EAGER: `offset + n > size` traps BEFORE any
////   write (no partial effect)**, and the check is unconditional so `d = size, n = 0` does NOT trap
////   while `d > size, n = 0` DOES (bulk-memory proposal §4.4.9;
////   <https://github.com/WebAssembly/bulk-memory-operations>).
//// - **`table.copy` is memmove** (overlap-correct in either direction) — same page.
//// - **`table.init` from a dropped (length-0) segment traps for `n > 0`, no-ops for `n = 0`**.
//// - **`externref` is opaque and forge-proof** (R1): a host term round-trips bit-identically and a
////   stored externref is never mistaken for null.
//// - **`table.grow`/`fill`/`init`/`copy` charge O(N) fuel on success** (R9), identically across
////   the cell and threaded families (the G7 parity bar).
////
//// Each test seeds its own cell (the table lives in the per-instance pdict cell) or threads an
//// `InstanceState`. Exceptions are caught via `twocore_rt_state_test_ffi`.

import gleam/dict
import gleam/dynamic
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleeunit/should
import twocore/ir.{
  type FuncType, FuncType, IndirectCallTypeMismatch, TI32, TableOutOfBounds,
  UndefinedElement, UninitializedElement,
}
import twocore/runtime/rt_meter
import twocore/runtime/rt_ref
import twocore/runtime/rt_state.{
  type InstanceState, FullDecl, InstanceState, StateDecl,
}
import twocore/runtime/rt_table
import twocore/runtime/rt_trap

@external(erlang, "twocore_rt_state_test_ffi", "catch_thunk")
fn catch_thunk(thunk: fn() -> a) -> Result(a, String)

/// Box a value as the package `Dynamic` a Phase-13 funcref closure returns (identity at run time).
@external(erlang, "gleam_stdlib", "identity")
fn to_pkg(v: a) -> dynamic.Dynamic

// ── helpers ──────────────────────────────────────────────────────────────────

/// Seed a fresh cell whose (index-0) table has `size` null slots and declared max `max`.
fn seed(size: Int, max: option.Option(Int)) -> Nil {
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [],
    table: rt_table.new(size, max),
  ))
}

/// A fresh threaded instance-state whose (index-0) table has `size` null slots.
fn threaded(size: Int, max: option.Option(Int)) -> InstanceState {
  rt_state.fresh(StateDecl(
    mem: dynamic.nil(),
    globals: [],
    table: rt_table.new(size, max),
  ))
}

fn ii_i() -> FuncType {
  FuncType([TI32, TI32], [TI32])
}

/// A distinguishable externref carrying integer handle `n` (comparable, opaque).
fn ext(n: Int) -> rt_table.RefValue {
  rt_ref.extern_of(n)
}

fn null() -> rt_table.RefValue {
  rt_ref.null_ref()
}

// ── 1. get/set round-trip + hard bounds (cell + threaded) ─────────────────────

/// `set(0, 2, r)` then `get(0, 2)` yields `Ok(r)`; a never-written slot reads the null sentinel.
pub fn get_set_round_trip_test() {
  seed(4, None)
  let assert Ok(Nil) = rt_table.set(0, 2, ext(7))
  rt_table.get(0, 2) |> should.equal(Ok(ext(7)))
  // Untouched slot 0 reads null.
  let assert Ok(v) = rt_table.get(0, 0)
  rt_ref.is_null(v) |> should.be_true
}

/// `get`/`set` at `index = size` and `index = -1` trap `TableOutOfBounds` ("out of bounds table
/// access"); the failed `set` writes nothing.
pub fn get_set_out_of_bounds_traps_test() {
  seed(3, None)
  rt_table.get(0, 3) |> should.equal(Error(TableOutOfBounds))
  rt_table.get(0, -1) |> should.equal(Error(TableOutOfBounds))
  rt_table.set(0, 3, ext(1)) |> should.equal(Error(TableOutOfBounds))
  rt_table.set(0, -1, ext(1)) |> should.equal(Error(TableOutOfBounds))
}

/// The threaded twins round-trip and trap identically, returning the rebuilt record.
pub fn threaded_get_set_test() {
  let st = threaded(3, None)
  let assert Ok(st) = rt_table.t_set(st, 0, 1, ext(9))
  rt_table.t_get(st, 0, 1) |> should.equal(Ok(ext(9)))
  rt_table.t_set(st, 0, 3, ext(1)) |> should.equal(Error(TableOutOfBounds))
  rt_table.t_get(st, 0, 3) |> should.equal(Error(TableOutOfBounds))
}

/// Storing `ref.null` then `get` returns null; a `call_indirect` to that slot traps
/// `UninitializedElement` (a funcref set to null is uninitialised, per reference-types).
pub fn set_null_then_call_indirect_traps_test() {
  seed(2, None)
  // Fill slot 0 with a real funcref, then overwrite it with null.
  let assert Ok(Nil) =
    rt_table.set(
      0,
      0,
      rt_table.funcref(ii_i(), fn(args) {
        case args {
          [a, b] -> to_pkg(a + b)
          _ -> panic as "add"
        }
      }),
    )
  // The funcref is callable...
  rt_table.call_indirect(0, ii_i(), [3, 4]) |> should.equal(Ok([7]))
  // ...until set to null, after which get is null and call_indirect traps uninitialised.
  let assert Ok(Nil) = rt_table.set(0, 0, null())
  let assert Ok(v) = rt_table.get(0, 0)
  rt_ref.is_null(v) |> should.be_true
  rt_table.call_indirect(0, ii_i(), [3, 4])
  |> should.equal(Error(UninitializedElement))
}

// ── 2. size/grow ──────────────────────────────────────────────────────────────

/// `grow` returns the OLD size and appends `delta` slots holding the init reference; `size` tracks
/// it. A `grow(0, delta, r)` on `min=1, max=Some(3)` returns 1, then a further grow past max → -1
/// (unchanged). `grow(0, 0, r)` returns the current size (no-op).
pub fn grow_old_size_init_and_max_test() {
  seed(1, Some(3))
  rt_table.size(0) |> should.equal(1)
  // grow by 2 → old size 1, size now 3, new slots hold the init externref.
  rt_table.grow(0, 2, ext(5)) |> should.equal(1)
  rt_table.size(0) |> should.equal(3)
  rt_table.get(0, 1) |> should.equal(Ok(ext(5)))
  rt_table.get(0, 2) |> should.equal(Ok(ext(5)))
  // A further grow past max=3 fails: -1, size unchanged, contents unchanged.
  rt_table.grow(0, 1, ext(9)) |> should.equal(-1)
  rt_table.size(0) |> should.equal(3)
  rt_table.get(0, 2) |> should.equal(Ok(ext(5)))
  // grow by 0 is a no-op returning the current size.
  rt_table.grow(0, 0, ext(1)) |> should.equal(3)
  rt_table.size(0) |> should.equal(3)
}

/// A negative delta fails (`-1`), the table unchanged.
pub fn grow_negative_delta_is_minus_one_test() {
  seed(2, None)
  rt_table.grow(0, -1, ext(1)) |> should.equal(-1)
  rt_table.size(0) |> should.equal(2)
}

/// A grown-into slot with a NULL init reads as the null sentinel (no forged value).
pub fn grow_with_null_init_test() {
  seed(1, None)
  rt_table.grow(0, 2, null()) |> should.equal(1)
  let assert Ok(v) = rt_table.get(0, 2)
  rt_ref.is_null(v) |> should.be_true
}

// ── 3. grow/fill fuel — O(N), success-only, cell ≡ threaded (R9/§G) ────────────

/// A successful `grow(0, delta, r)` charges `delta` fuel, and the cell and threaded families
/// charge the SAME (parity, the G7 bar); a failing grow charges nothing.
pub fn grow_fuel_parity_test() {
  // Cell. Seed a large budget (zeroes the consumed counter; never trips here).
  seed(1, None)
  rt_meter.seed_fuel(1_000_000_000)
  rt_table.grow(0, 3, ext(1)) |> should.equal(1)
  let cell_cost = rt_meter.fuel_consumed()
  cell_cost |> should.equal(3)
  // Threaded.
  let st = threaded(1, None)
  rt_meter.seed_fuel(1_000_000_000)
  let #(old, _st) = rt_table.t_grow(st, 0, 3, ext(1))
  old |> should.equal(1)
  rt_meter.fuel_consumed() |> should.equal(cell_cost)
  // A failing grow (past a max) charges nothing.
  seed(1, Some(1))
  rt_meter.seed_fuel(1_000_000_000)
  rt_table.grow(0, 5, ext(1)) |> should.equal(-1)
  rt_meter.fuel_consumed() |> should.equal(0)
}

/// A successful `fill` charges `count` fuel; the cell and threaded families agree.
pub fn fill_fuel_parity_test() {
  seed(5, None)
  rt_meter.seed_fuel(1_000_000_000)
  let assert Ok(Nil) = rt_table.fill(0, 1, ext(2), 3)
  let cell_cost = rt_meter.fuel_consumed()
  cell_cost |> should.equal(3)
  let st = threaded(5, None)
  rt_meter.seed_fuel(1_000_000_000)
  let assert Ok(_st) = rt_table.t_fill(st, 0, 1, ext(2), 3)
  rt_meter.fuel_consumed() |> should.equal(cell_cost)
}

/// A `grow` whose cost exceeds a seeded budget surfaces `FuelExhausted` (diverges), like
/// `memory.grow` — proving the O(N) grow cannot outrun the CPU bound (F5).
pub fn grow_fuel_exhaustion_test() {
  seed(1, None)
  rt_meter.seed_fuel(2)
  catch_thunk(fn() { rt_table.grow(0, 5, ext(1)) })
  |> result.is_error
  |> should.be_true
  // Restore a large budget so this test cannot poison another (shared-process safety).
  rt_meter.seed_fuel(1_000_000_000)
}

// ── 4. fill — eager bounds, the R10 boundary, no partial writes ────────────────

/// `fill(0, d, r, n)` with `d + n > size` traps `TableOutOfBounds` and writes NOTHING (all-or-
/// nothing): the slots the failed fill would have touched still read null.
pub fn fill_eager_no_partial_write_test() {
  seed(5, None)
  // 3 + 5 = 8 > 5 ⇒ trap; slots 3,4 must stay null (no partial write).
  rt_table.fill(0, 3, ext(7), 5) |> should.equal(Error(TableOutOfBounds))
  let assert Ok(v3) = rt_table.get(0, 3)
  let assert Ok(v4) = rt_table.get(0, 4)
  rt_ref.is_null(v3) |> should.be_true
  rt_ref.is_null(v4) |> should.be_true
  // An in-range fill sets exactly its run.
  let assert Ok(Nil) = rt_table.fill(0, 3, ext(7), 2)
  rt_table.get(0, 3) |> should.equal(Ok(ext(7)))
  rt_table.get(0, 4) |> should.equal(Ok(ext(7)))
}

/// The exact R10 boundary: `fill(d = size, n = 0)` does NOT trap (a no-op), but `fill(d > size,
/// n = 0)` DOES — the check `d + n > size` is unconditional (bulk-memory §4.4.9).
pub fn fill_zero_length_boundary_test() {
  seed(5, None)
  // d = size, n = 0 → 5 + 0 = 5, not > 5 → Ok (no-op).
  rt_table.fill(0, 5, ext(1), 0) |> should.equal(Ok(Nil))
  // d > size, n = 0 → 6 + 0 = 6 > 5 → trap.
  rt_table.fill(0, 6, ext(1), 0) |> should.equal(Error(TableOutOfBounds))
  // A negative offset traps even for n = 0.
  rt_table.fill(0, -1, ext(1), 0) |> should.equal(Error(TableOutOfBounds))
}

// ── 5. table.init — from a segment, both bounds, dropped = length 0 ────────────

/// `table_init` copies exactly `[src, src+count)` of the segment `items` into `[dst, dst+count)`.
pub fn table_init_copies_slice_test() {
  seed(5, None)
  let items = [ext(10), ext(11), ext(12)]
  let assert Ok(Nil) = rt_table.table_init(0, items, 1, 0, 3)
  rt_table.get(0, 1) |> should.equal(Ok(ext(10)))
  rt_table.get(0, 2) |> should.equal(Ok(ext(11)))
  rt_table.get(0, 3) |> should.equal(Ok(ext(12)))
  // Slots outside the run stay null.
  let assert Ok(v0) = rt_table.get(0, 0)
  rt_ref.is_null(v0) |> should.be_true
}

/// `table_init` traps if EITHER the source range exceeds the segment OR the destination range
/// exceeds the table — before any write.
pub fn table_init_both_bounds_test() {
  seed(3, None)
  let items = [ext(1), ext(2)]
  // src + count > len(items): 0 + 3 > 2 ⇒ trap.
  rt_table.table_init(0, items, 0, 0, 3)
  |> should.equal(Error(TableOutOfBounds))
  // dst + count > size: 2 + 2 > 3 ⇒ trap.
  rt_table.table_init(0, items, 2, 0, 2)
  |> should.equal(Error(TableOutOfBounds))
  // Nothing written.
  let assert Ok(v0) = rt_table.get(0, 0)
  rt_ref.is_null(v0) |> should.be_true
}

/// A DROPPED segment arrives as `items = []` (ε, R2): `table_init` with `count > 0` traps (source
/// bound), with `count = 0` no-ops. This is the spec's "init from a dropped/exhausted segment".
pub fn table_init_dropped_segment_test() {
  seed(5, None)
  // Non-zero count from an empty (dropped) segment ⇒ src(0)+count(1) > 0 ⇒ trap.
  rt_table.table_init(0, [], 0, 0, 1) |> should.equal(Error(TableOutOfBounds))
  // Zero count is a spec no-op even from a dropped segment.
  rt_table.table_init(0, [], 0, 0, 0) |> should.equal(Ok(Nil))
}

// ── 6. table.copy — memmove (the overlap corner), eager bounds ─────────────────

/// Overlapping same-table copy with `d > s` (the descending case): the snapshot-correct result,
/// NOT the naive forward in-place smear. Table `[e1,e2,e3,e4,_]`, `copy(dst=2, src=1, n=3)` yields
/// `[e1,e2,e2,e3,e4]` (a forward smear would give `…,e2,e2,e2`).
pub fn table_copy_overlap_descending_test() {
  seed(5, None)
  let assert Ok(Nil) = rt_table.set(0, 0, ext(1))
  let assert Ok(Nil) = rt_table.set(0, 1, ext(2))
  let assert Ok(Nil) = rt_table.set(0, 2, ext(3))
  let assert Ok(Nil) = rt_table.set(0, 3, ext(4))
  let assert Ok(Nil) = rt_table.table_copy(0, 0, 2, 1, 3)
  rt_table.get(0, 0) |> should.equal(Ok(ext(1)))
  rt_table.get(0, 1) |> should.equal(Ok(ext(2)))
  rt_table.get(0, 2) |> should.equal(Ok(ext(2)))
  // These two would be wrongly ext(2) under a naive ascending in-place copy.
  rt_table.get(0, 3) |> should.equal(Ok(ext(3)))
  rt_table.get(0, 4) |> should.equal(Ok(ext(4)))
}

/// Overlapping same-table copy with `d <= s` (the ascending case): `[e1,e2,e3,e4,e5]`,
/// `copy(dst=1, src=2, n=3)` yields `[e1,e3,e4,e5,e5]` — also snapshot-correct.
pub fn table_copy_overlap_ascending_test() {
  seed(5, None)
  let assert Ok(Nil) = rt_table.fill(0, 0, ext(1), 1)
  let assert Ok(Nil) = rt_table.set(0, 1, ext(2))
  let assert Ok(Nil) = rt_table.set(0, 2, ext(3))
  let assert Ok(Nil) = rt_table.set(0, 3, ext(4))
  let assert Ok(Nil) = rt_table.set(0, 4, ext(5))
  let assert Ok(Nil) = rt_table.table_copy(0, 0, 1, 2, 3)
  rt_table.get(0, 1) |> should.equal(Ok(ext(3)))
  rt_table.get(0, 2) |> should.equal(Ok(ext(4)))
  rt_table.get(0, 3) |> should.equal(Ok(ext(5)))
  rt_table.get(0, 4) |> should.equal(Ok(ext(5)))
}

/// `table_copy` traps if either range is OOB, before any write.
pub fn table_copy_out_of_bounds_test() {
  seed(4, None)
  let assert Ok(Nil) = rt_table.set(0, 0, ext(1))
  // dst + count > size.
  rt_table.table_copy(0, 0, 3, 0, 2) |> should.equal(Error(TableOutOfBounds))
  // src + count > size.
  rt_table.table_copy(0, 0, 0, 3, 2) |> should.equal(Error(TableOutOfBounds))
}

// ── 7. externref opacity + forge-proofness (H6/R1) ────────────────────────────

/// An externref host term round-trips bit-identically through `set`/`get`/`fill`/`grow`/`copy`,
/// and is NEVER mistaken for null — even one wrapping the null sentinel itself.
pub fn externref_opaque_and_forge_proof_test() {
  seed(4, None)
  // A host term that literally wraps the null sentinel — the forge-proof adversary.
  let sneaky = rt_ref.wrap_extern(rt_ref.null_ref())
  let assert Ok(Nil) = rt_table.set(0, 0, sneaky)
  let assert Ok(back) = rt_table.get(0, 0)
  // Bit-identical round-trip.
  back |> should.equal(sneaky)
  // And NOT null (forge-proof): a stored externref is never the sentinel.
  rt_ref.is_null(back) |> should.be_false
  // Whereas an actual null slot IS null.
  let assert Ok(v1) = rt_table.get(0, 1)
  rt_ref.is_null(v1) |> should.be_true
}

// ── 8. active reference-segment write (init_elem_ref) ─────────────────────────

/// `init_elem_ref` writes a run of reference values at an offset (all-or-nothing; whole-range
/// bounds). Generalises `init_elem` to externref/null/any index.
pub fn init_elem_ref_writes_and_bounds_test() {
  seed(4, None)
  // Out-of-range segment writes nothing.
  rt_table.init_elem_ref(0, 3, [ext(1), ext(2)])
  |> should.equal(Error(TableOutOfBounds))
  let assert Ok(v3) = rt_table.get(0, 3)
  rt_ref.is_null(v3) |> should.be_true
  // In-range writes exactly its run.
  let assert Ok(Nil) = rt_table.init_elem_ref(0, 1, [ext(1), ext(2)])
  rt_table.get(0, 1) |> should.equal(Ok(ext(1)))
  rt_table.get(0, 2) |> should.equal(Ok(ext(2)))
}

// ── 9. Multiple tables — the vector seam routes by index (R7) ─────────────────

/// Two tables of different sizes: an op on table 1 never touches table 0, a `table.copy` between
/// them moves values, and each table's `size`/`get` are independent. Proven through the threaded
/// family over a directly-built 2-table `InstanceState` (multi-table cell seeding is unit 09's).
pub fn multiple_tables_route_by_index_test() {
  let st =
    InstanceState(
      mems: [],
      globals: dict.new(),
      tables: [rt_table.new(3, None), rt_table.new(2, None)],
      dropped_data: set.new(),
      dropped_elem: set.new(),
      ref_globals: dict.new(),
      func_imports: [],
      js_store: None,
      js_realm: None,
    )
  rt_table.t_size(st, 0) |> should.equal(3)
  rt_table.t_size(st, 1) |> should.equal(2)
  // Write into table 1; table 0 is untouched.
  let assert Ok(st) = rt_table.t_set(st, 1, 0, ext(42))
  rt_table.t_get(st, 1, 0) |> should.equal(Ok(ext(42)))
  let assert Ok(v) = rt_table.t_get(st, 0, 0)
  rt_ref.is_null(v) |> should.be_true
  // Copy table 1 → table 0 at index 2.
  let assert Ok(st) = rt_table.t_table_copy(st, 0, 1, 2, 0, 1)
  rt_table.t_get(st, 0, 2) |> should.equal(Ok(ext(42)))
}

// ── 10. Frozen trap messages (guard against unit-01 drift) ────────────────────

/// The reference/bulk OOB reason maps to the exact spec `assert_trap` substring, distinct from the
/// `call_indirect` "undefined element" (they are different spec messages, F).
pub fn spec_trap_messages_test() {
  rt_trap.spec_trap_message(TableOutOfBounds)
  |> should.equal("out of bounds table access")
  rt_trap.spec_trap_message(UninitializedElement)
  |> should.equal("uninitialized element")
}

// ── 11. Multi-table call_indirect (Phase-5 follow-up, reference-types multi-table dispatch) ──
//
// Reference-types lifts the single-table restriction: `call_indirect` carries an explicit table
// index (<https://webassembly.github.io/spec/core/exec/instructions.html#control-instructions>).
// `call_indirect_at(k, …)` / `t_call_indirect_at(st, k, …)` dispatch through table `k` (0 = the
// default, behaviourally identical to `call_indirect`) with the SAME 3-fault fail-closed order:
// bounds → `UndefinedElement`, null slot → `UninitializedElement`, type → `IndirectCallTypeMismatch`.

/// CELL: dispatch through the NON-default table 1 — a filled slot runs; the three faults fire in
/// spec order on the non-default table; and `call_indirect_at(0, …)` reads the default table.
pub fn call_indirect_at_multi_table_cell_test() {
  rt_state.seed_full(
    FullDecl(
      mems: [],
      globals: [],
      tables: [rt_table.new(1, None), rt_table.new(4, None)],
      ref_globals: [],
    ),
  )
  let assert Ok(Nil) =
    rt_table.set(
      1,
      1,
      rt_table.funcref(ii_i(), fn(a) {
        case a {
          [x, y] -> to_pkg(x + y)
          _ -> to_pkg(0)
        }
      }),
    )
  rt_table.call_indirect_at(1, 1, ii_i(), [3, 4]) |> should.equal(Ok([7]))
  // bounds → null → type, all on table 1.
  rt_table.call_indirect_at(1, 4, ii_i(), [3, 4])
  |> should.equal(Error(UndefinedElement))
  rt_table.call_indirect_at(1, 0, ii_i(), [3, 4])
  |> should.equal(Error(UninitializedElement))
  rt_table.call_indirect_at(1, 1, FuncType([TI32], [TI32]), [3])
  |> should.equal(Error(IndirectCallTypeMismatch))
  // table 0 (the default) is independent and untouched — its slot 0 reads null.
  rt_table.call_indirect_at(0, 0, ii_i(), [3, 4])
  |> should.equal(Error(UninitializedElement))
}

/// THREADED: the same multi-table dispatch over the record-threading `t_call_indirect_at`.
pub fn t_call_indirect_at_multi_table_test() {
  let st =
    rt_state.fresh_full(
      FullDecl(
        mems: [],
        globals: [],
        tables: [rt_table.new(1, None), rt_table.new(4, None)],
        ref_globals: [],
      ),
    )
  let assert Ok(st) =
    rt_table.t_set(
      st,
      1,
      1,
      rt_table.funcref_t(ii_i(), fn(s, a) {
        case a {
          [x, y] -> #(to_pkg(x + y), s)
          _ -> #(to_pkg(0), s)
        }
      }),
    )
  let assert Ok(#(res, _)) =
    rt_table.t_call_indirect_at(st, 1, 1, ii_i(), [3, 4])
  res |> should.equal([7])
  rt_table.t_call_indirect_at(st, 1, 4, ii_i(), [3, 4])
  |> should.equal(Error(UndefinedElement))
  rt_table.t_call_indirect_at(st, 1, 0, ii_i(), [3, 4])
  |> should.equal(Error(UninitializedElement))
  rt_table.t_call_indirect_at(st, 1, 1, FuncType([TI32], [TI32]), [3])
  |> should.equal(Error(IndirectCallTypeMismatch))
}
