//// Spec-grounded tests for the Phase-5 reference-types + bulk-table surface on `TableEts` (unit
//// P5-07) — the same spec obligations as the `TablePaged` oracle, on the in-place ETS substrate
//// (where null is DELETE-on-null so `call_indirect`'s absent-key guard stays byte-identical).
//// The cross-tier differential proves EQUALITY with the oracle; these anchor the ETS mechanism.
////
//// Spec citations: table instructions
//// <https://webassembly.github.io/spec/core/exec/instructions.html#table-instructions>
//// (reference-types proposal); eager bounds + no-partial-write + memmove + dropped-segment =
//// length-0 (bulk-memory proposal §4.4.9,
//// <https://github.com/WebAssembly/bulk-memory-operations>).

import carder/ir.{
  type FuncType, FuncType, IndirectCallTypeMismatch, TI32, TableOutOfBounds,
  UndefinedElement, UninitializedElement,
}
import carder/runtime/rt_meter
import carder/runtime/rt_ref
import carder/runtime/rt_state.{type InstanceState, FullDecl, StateDecl}
import carder/runtime/rt_table
import carder/runtime/rt_table_ets as ets
import gleam/dynamic
import gleam/option.{None, Some}
import gleeunit/should

/// Box a value as the package `Dynamic` a Phase-13 funcref closure returns (identity at run time).
@external(erlang, "gleam_stdlib", "identity")
fn to_pkg(v: a) -> dynamic.Dynamic

fn seed(size: Int, max: option.Option(Int)) -> Nil {
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [],
    table: ets.new(size, max),
  ))
}

fn threaded(size: Int, max: option.Option(Int)) -> InstanceState {
  rt_state.fresh(StateDecl(
    mem: dynamic.nil(),
    globals: [],
    table: ets.new(size, max),
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

/// get/set round-trip + hard bounds; an untouched slot reads null.
pub fn get_set_round_trip_and_bounds_test() {
  seed(4, None)
  let assert Ok(Nil) = ets.set(0, 2, ext(7))
  ets.get(0, 2) |> should.equal(Ok(ext(7)))
  let assert Ok(v) = ets.get(0, 0)
  rt_ref.is_null(v) |> should.be_true
  ets.get(0, 4) |> should.equal(Error(TableOutOfBounds))
  ets.set(0, -1, ext(1)) |> should.equal(Error(TableOutOfBounds))
}

/// A funcref set then overwritten with null: `get` is null and `call_indirect` traps
/// `UninitializedElement` (the ETS entry is DELETED on a null write).
pub fn set_null_then_call_indirect_traps_test() {
  seed(2, None)
  let assert Ok(Nil) =
    ets.set(
      0,
      0,
      rt_table.funcref(ii_i(), fn(args) {
        case args {
          [a, b] -> to_pkg(a + b)
          _ -> panic as "add"
        }
      }),
    )
  ets.call_indirect(0, ii_i(), [3, 4]) |> should.equal(Ok([7]))
  let assert Ok(Nil) = ets.set(0, 0, null())
  let assert Ok(v) = ets.get(0, 0)
  rt_ref.is_null(v) |> should.be_true
  ets.call_indirect(0, ii_i(), [3, 4])
  |> should.equal(Error(UninitializedElement))
}

/// grow: old size, init fill, past-max ⇒ -1 (unchanged), no-op grow(0). Charges `delta` fuel.
pub fn grow_test() {
  seed(1, Some(3))
  ets.grow(0, 2, ext(5)) |> should.equal(1)
  ets.size(0) |> should.equal(3)
  ets.get(0, 2) |> should.equal(Ok(ext(5)))
  ets.grow(0, 1, ext(9)) |> should.equal(-1)
  ets.size(0) |> should.equal(3)
  ets.grow(0, 0, ext(1)) |> should.equal(3)
}

/// grow fuel parity: cell and threaded charge `delta` identically (R9/§G).
pub fn grow_fuel_parity_test() {
  seed(1, None)
  rt_meter.seed_fuel(1_000_000_000)
  ets.grow(0, 3, ext(1)) |> should.equal(1)
  let cost = rt_meter.fuel_consumed()
  cost |> should.equal(3)
  let st = threaded(1, None)
  rt_meter.seed_fuel(1_000_000_000)
  let #(old, _st) = ets.t_grow(st, 0, 3, ext(1))
  old |> should.equal(1)
  rt_meter.fuel_consumed() |> should.equal(cost)
}

/// fill eager bounds + the R10 zero-length boundary + no partial writes.
pub fn fill_eager_and_boundary_test() {
  seed(5, None)
  ets.fill(0, 3, ext(7), 5) |> should.equal(Error(TableOutOfBounds))
  let assert Ok(v3) = ets.get(0, 3)
  rt_ref.is_null(v3) |> should.be_true
  // R10: d = size, n = 0 no-op; d > size, n = 0 traps.
  ets.fill(0, 5, ext(1), 0) |> should.equal(Ok(Nil))
  ets.fill(0, 6, ext(1), 0) |> should.equal(Error(TableOutOfBounds))
  let assert Ok(Nil) = ets.fill(0, 3, ext(7), 2)
  ets.get(0, 4) |> should.equal(Ok(ext(7)))
}

/// table.init copies a slice; both bounds; a dropped (empty) segment traps for n>0, no-ops n=0.
pub fn table_init_test() {
  seed(5, None)
  let items = [ext(10), ext(11), ext(12)]
  let assert Ok(Nil) = ets.table_init(0, items, 1, 0, 3)
  ets.get(0, 1) |> should.equal(Ok(ext(10)))
  ets.get(0, 3) |> should.equal(Ok(ext(12)))
  // Source overflow.
  ets.table_init(0, items, 0, 0, 4) |> should.equal(Error(TableOutOfBounds))
  // Dropped (empty) segment.
  ets.table_init(0, [], 0, 0, 1) |> should.equal(Error(TableOutOfBounds))
  ets.table_init(0, [], 0, 0, 0) |> should.equal(Ok(Nil))
}

/// table.copy overlap correctness (the descending memmove corner) — snapshot-then-write.
pub fn table_copy_overlap_test() {
  seed(5, None)
  let assert Ok(Nil) = ets.set(0, 0, ext(1))
  let assert Ok(Nil) = ets.set(0, 1, ext(2))
  let assert Ok(Nil) = ets.set(0, 2, ext(3))
  let assert Ok(Nil) = ets.set(0, 3, ext(4))
  let assert Ok(Nil) = ets.table_copy(0, 0, 2, 1, 3)
  ets.get(0, 2) |> should.equal(Ok(ext(2)))
  ets.get(0, 3) |> should.equal(Ok(ext(3)))
  ets.get(0, 4) |> should.equal(Ok(ext(4)))
}

/// externref opacity + forge-proofness: a host term (even one wrapping null) round-trips
/// bit-identically and is never mistaken for null.
pub fn externref_opaque_and_forge_proof_test() {
  seed(2, None)
  let sneaky = rt_ref.wrap_extern(rt_ref.null_ref())
  let assert Ok(Nil) = ets.set(0, 0, sneaky)
  let assert Ok(back) = ets.get(0, 0)
  back |> should.equal(sneaky)
  rt_ref.is_null(back) |> should.be_false
}

/// The threaded twins round-trip and return the record (in-place backend ⇒ same handle, §10).
pub fn threaded_ops_test() {
  let st = threaded(4, None)
  let assert Ok(st) = ets.t_set(st, 0, 1, ext(9))
  ets.t_get(st, 0, 1) |> should.equal(Ok(ext(9)))
  let assert Ok(st) = ets.t_fill(st, 0, 2, ext(3), 2)
  ets.t_get(st, 0, 3) |> should.equal(Ok(ext(3)))
  ets.t_set(st, 0, 4, ext(1)) |> should.equal(Error(TableOutOfBounds))
}

// ── Multi-table call_indirect (Phase-5 follow-up) — the ETS substrate ──
//
// `call_indirect_at(k, …)` / `t_call_indirect_at(st, k, …)` dispatch through table `k` over the
// in-place ETS store, with the SAME 3-fault fail-closed order (bounds → null → type) as the
// byte-identical `call_indirect` (reference-types multi-table dispatch,
// <https://webassembly.github.io/spec/core/exec/instructions.html#control-instructions>).

/// CELL: dispatch through the non-default table 1; the three faults fire in spec order.
pub fn call_indirect_at_multi_table_cell_test() {
  rt_state.seed_full(
    FullDecl(
      mems: [],
      globals: [],
      tables: [ets.new(1, None), ets.new(4, None)],
      ref_globals: [],
    ),
  )
  let assert Ok(Nil) =
    ets.set(
      1,
      1,
      rt_table.funcref(ii_i(), fn(a) {
        case a {
          [x, y] -> to_pkg(x + y)
          _ -> to_pkg(0)
        }
      }),
    )
  ets.call_indirect_at(1, 1, ii_i(), [3, 4]) |> should.equal(Ok([7]))
  ets.call_indirect_at(1, 4, ii_i(), [3, 4])
  |> should.equal(Error(UndefinedElement))
  ets.call_indirect_at(1, 0, ii_i(), [3, 4])
  |> should.equal(Error(UninitializedElement))
  ets.call_indirect_at(1, 1, FuncType([TI32], [TI32]), [3])
  |> should.equal(Error(IndirectCallTypeMismatch))
}

/// THREADED: the same multi-table dispatch over `t_call_indirect_at`.
pub fn t_call_indirect_at_multi_table_test() {
  let st =
    rt_state.fresh_full(
      FullDecl(
        mems: [],
        globals: [],
        tables: [ets.new(1, None), ets.new(4, None)],
        ref_globals: [],
      ),
    )
  let assert Ok(st) =
    ets.t_set(
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
  let assert Ok(#(res, _)) = ets.t_call_indirect_at(st, 1, 1, ii_i(), [3, 4])
  res |> should.equal([7])
  ets.t_call_indirect_at(st, 1, 4, ii_i(), [3, 4])
  |> should.equal(Error(UndefinedElement))
  ets.t_call_indirect_at(st, 1, 0, ii_i(), [3, 4])
  |> should.equal(Error(UninitializedElement))
  ets.t_call_indirect_at(st, 1, 1, FuncType([TI32], [TI32]), [3])
  |> should.equal(Error(IndirectCallTypeMismatch))
}
