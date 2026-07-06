//// Spec-grounded tests for the Phase-5 reference-types + bulk-table surface on `TableAtomics`
//// (unit P5-07) — the same spec obligations as the `TablePaged` oracle, on the hybrid `occ`-array
//// + immutable-companion substrate (where null is `occ = 0` and `grow` REALLOCATES the array,
//// copying the old words). The cross-tier differential proves EQUALITY with the oracle; these
//// anchor the atomics mechanism, especially the grow-reallocation edge (§H).
////
//// Spec citations: table instructions
//// <https://webassembly.github.io/spec/core/exec/instructions.html#table-instructions>
//// (reference-types proposal); eager bounds + no-partial-write + memmove + dropped-segment =
//// length-0 (bulk-memory proposal §4.4.9,
//// <https://github.com/WebAssembly/bulk-memory-operations>).

import gleam/dynamic
import gleam/option.{None, Some}
import gleeunit/should
import twocore/ir.{
  type FuncType, FuncType, IndirectCallTypeMismatch, TI32, TableOutOfBounds,
  UndefinedElement, UninitializedElement,
}
import twocore/runtime/rt_meter
import twocore/runtime/rt_ref
import twocore/runtime/rt_state.{type InstanceState, FullDecl, StateDecl}
import twocore/runtime/rt_table
import twocore/runtime/rt_table_atomics as atom

/// Box a value as the package `Dynamic` a Phase-13 funcref closure returns (identity at run time).
@external(erlang, "gleam_stdlib", "identity")
fn to_pkg(v: a) -> dynamic.Dynamic

fn seed(size: Int, max: option.Option(Int)) -> Nil {
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [],
    table: atom.new(size, max),
  ))
}

fn threaded(size: Int, max: option.Option(Int)) -> InstanceState {
  rt_state.fresh(StateDecl(
    mem: dynamic.nil(),
    globals: [],
    table: atom.new(size, max),
  ))
}

fn ii_i() -> FuncType {
  FuncType([TI32, TI32], [TI32])
}

fn ext(n: Int) -> rt_table.RefValue {
  rt_ref.extern_of(n)
}

fn null() -> rt_table.RefValue {
  rt_ref.null_ref()
}

/// get/set round-trip + hard bounds; an untouched slot (`occ = 0`) reads null.
pub fn get_set_round_trip_and_bounds_test() {
  seed(4, None)
  let assert Ok(Nil) = atom.set(0, 2, ext(7))
  atom.get(0, 2) |> should.equal(Ok(ext(7)))
  let assert Ok(v) = atom.get(0, 0)
  rt_ref.is_null(v) |> should.be_true
  atom.get(0, 4) |> should.equal(Error(TableOutOfBounds))
  atom.set(0, -1, ext(1)) |> should.equal(Error(TableOutOfBounds))
}

/// A funcref set then overwritten with null: `get` is null and `call_indirect` traps
/// `UninitializedElement` (the `occ` word is zeroed on a null write).
pub fn set_null_then_call_indirect_traps_test() {
  seed(2, None)
  let assert Ok(Nil) =
    atom.set(
      0,
      0,
      rt_table.funcref(ii_i(), fn(args) {
        case args {
          [a, b] -> to_pkg(a + b)
          _ -> panic as "add"
        }
      }),
    )
  atom.call_indirect(0, ii_i(), [3, 4]) |> should.equal(Ok([7]))
  let assert Ok(Nil) = atom.set(0, 0, null())
  let assert Ok(v) = atom.get(0, 0)
  rt_ref.is_null(v) |> should.be_true
  atom.call_indirect(0, ii_i(), [3, 4])
  |> should.equal(Error(UninitializedElement))
}

/// grow: old size, init fill, past-max ⇒ -1 (unchanged), no-op grow(0). Charges `delta` fuel.
pub fn grow_test() {
  seed(1, Some(3))
  atom.grow(0, 2, ext(5)) |> should.equal(1)
  atom.size(0) |> should.equal(3)
  atom.get(0, 2) |> should.equal(Ok(ext(5)))
  atom.grow(0, 1, ext(9)) |> should.equal(-1)
  atom.size(0) |> should.equal(3)
  atom.grow(0, 0, ext(1)) |> should.equal(3)
}

/// The atomics REALLOCATION edge: growing copies the old `occ` words, so a slot written before the
/// grow still reads its value after (the array is a fresh, bigger allocation).
pub fn grow_preserves_old_slots_test() {
  seed(2, None)
  let assert Ok(Nil) = atom.set(0, 0, ext(1))
  let assert Ok(Nil) = atom.set(0, 1, ext(2))
  atom.grow(0, 3, null()) |> should.equal(2)
  atom.size(0) |> should.equal(5)
  // Old slots survive the reallocation.
  atom.get(0, 0) |> should.equal(Ok(ext(1)))
  atom.get(0, 1) |> should.equal(Ok(ext(2)))
  // New slots (null init) read null; and are writable.
  let assert Ok(vn) = atom.get(0, 4)
  rt_ref.is_null(vn) |> should.be_true
  let assert Ok(Nil) = atom.set(0, 4, ext(9))
  atom.get(0, 4) |> should.equal(Ok(ext(9)))
}

/// grow fuel parity: cell and threaded charge `delta` identically (R9/§G).
pub fn grow_fuel_parity_test() {
  seed(1, None)
  rt_meter.seed_fuel(1_000_000_000)
  atom.grow(0, 3, ext(1)) |> should.equal(1)
  let cost = rt_meter.fuel_consumed()
  cost |> should.equal(3)
  let st = threaded(1, None)
  rt_meter.seed_fuel(1_000_000_000)
  let #(old, _st) = atom.t_grow(st, 0, 3, ext(1))
  old |> should.equal(1)
  rt_meter.fuel_consumed() |> should.equal(cost)
}

/// fill eager bounds + the R10 zero-length boundary + no partial writes.
pub fn fill_eager_and_boundary_test() {
  seed(5, None)
  atom.fill(0, 3, ext(7), 5) |> should.equal(Error(TableOutOfBounds))
  let assert Ok(v3) = atom.get(0, 3)
  rt_ref.is_null(v3) |> should.be_true
  atom.fill(0, 5, ext(1), 0) |> should.equal(Ok(Nil))
  atom.fill(0, 6, ext(1), 0) |> should.equal(Error(TableOutOfBounds))
  let assert Ok(Nil) = atom.fill(0, 3, ext(7), 2)
  atom.get(0, 4) |> should.equal(Ok(ext(7)))
}

/// table.init copies a slice; both bounds; a dropped (empty) segment traps for n>0, no-ops n=0.
pub fn table_init_test() {
  seed(5, None)
  let items = [ext(10), ext(11), ext(12)]
  let assert Ok(Nil) = atom.table_init(0, items, 1, 0, 3)
  atom.get(0, 1) |> should.equal(Ok(ext(10)))
  atom.get(0, 3) |> should.equal(Ok(ext(12)))
  // Destination overflow: dst(4) + count(2) = 6 > size 5.
  atom.table_init(0, items, 4, 0, 2) |> should.equal(Error(TableOutOfBounds))
  // Source overflow: src(0) + count(4) = 4 > len(items) 3.
  atom.table_init(0, items, 0, 0, 4) |> should.equal(Error(TableOutOfBounds))
  atom.table_init(0, [], 0, 0, 1) |> should.equal(Error(TableOutOfBounds))
  atom.table_init(0, [], 0, 0, 0) |> should.equal(Ok(Nil))
}

/// table.copy overlap correctness (the descending memmove corner) — snapshot-then-write.
pub fn table_copy_overlap_test() {
  seed(5, None)
  let assert Ok(Nil) = atom.set(0, 0, ext(1))
  let assert Ok(Nil) = atom.set(0, 1, ext(2))
  let assert Ok(Nil) = atom.set(0, 2, ext(3))
  let assert Ok(Nil) = atom.set(0, 3, ext(4))
  let assert Ok(Nil) = atom.table_copy(0, 0, 2, 1, 3)
  atom.get(0, 2) |> should.equal(Ok(ext(2)))
  atom.get(0, 3) |> should.equal(Ok(ext(3)))
  atom.get(0, 4) |> should.equal(Ok(ext(4)))
}

/// externref opacity + forge-proofness: a host term (even one wrapping null) round-trips
/// bit-identically and is never mistaken for null.
pub fn externref_opaque_and_forge_proof_test() {
  seed(2, None)
  let sneaky = rt_ref.wrap_extern(rt_ref.null_ref())
  let assert Ok(Nil) = atom.set(0, 0, sneaky)
  let assert Ok(back) = atom.get(0, 0)
  back |> should.equal(sneaky)
  rt_ref.is_null(back) |> should.be_false
}

/// The threaded twins round-trip and re-inject the handle (grown companion, §10).
pub fn threaded_ops_test() {
  let st = threaded(4, None)
  let assert Ok(st) = atom.t_set(st, 0, 1, ext(9))
  atom.t_get(st, 0, 1) |> should.equal(Ok(ext(9)))
  let assert Ok(st) = atom.t_fill(st, 0, 2, ext(3), 2)
  atom.t_get(st, 0, 3) |> should.equal(Ok(ext(3)))
  atom.t_set(st, 0, 4, ext(1)) |> should.equal(Error(TableOutOfBounds))
}

// ── Multi-table call_indirect (Phase-5 follow-up) — the atomics substrate ──
//
// `call_indirect_at(k, …)` / `t_call_indirect_at(st, k, …)` dispatch through table `k` over the
// `occ`-array + immutable-companion store, with the SAME 3-fault fail-closed order
// (bounds → null → type) as the byte-identical `call_indirect` (reference-types multi-table
// dispatch, <https://webassembly.github.io/spec/core/exec/instructions.html#control-instructions>).

/// CELL: dispatch through the non-default table 1; the three faults fire in spec order.
pub fn call_indirect_at_multi_table_cell_test() {
  rt_state.seed_full(
    FullDecl(
      mems: [],
      globals: [],
      tables: [atom.new(1, None), atom.new(4, None)],
      ref_globals: [],
    ),
  )
  let assert Ok(Nil) =
    atom.set(
      1,
      1,
      rt_table.funcref(ii_i(), fn(a) {
        case a {
          [x, y] -> to_pkg(x + y)
          _ -> to_pkg(0)
        }
      }),
    )
  atom.call_indirect_at(1, 1, ii_i(), [3, 4]) |> should.equal(Ok([7]))
  atom.call_indirect_at(1, 4, ii_i(), [3, 4])
  |> should.equal(Error(UndefinedElement))
  atom.call_indirect_at(1, 0, ii_i(), [3, 4])
  |> should.equal(Error(UninitializedElement))
  atom.call_indirect_at(1, 1, FuncType([TI32], [TI32]), [3])
  |> should.equal(Error(IndirectCallTypeMismatch))
}

/// THREADED: the same multi-table dispatch over `t_call_indirect_at`.
pub fn t_call_indirect_at_multi_table_test() {
  let st =
    rt_state.fresh_full(
      FullDecl(
        mems: [],
        globals: [],
        tables: [atom.new(1, None), atom.new(4, None)],
        ref_globals: [],
      ),
    )
  let assert Ok(st) =
    atom.t_set(
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
  let assert Ok(#(res, _)) = atom.t_call_indirect_at(st, 1, 1, ii_i(), [3, 4])
  res |> should.equal([7])
  atom.t_call_indirect_at(st, 1, 4, ii_i(), [3, 4])
  |> should.equal(Error(UndefinedElement))
  atom.t_call_indirect_at(st, 1, 0, ii_i(), [3, 4])
  |> should.equal(Error(UninitializedElement))
  atom.t_call_indirect_at(st, 1, 1, FuncType([TI32], [TI32]), [3])
  |> should.equal(Error(IndirectCallTypeMismatch))
}
