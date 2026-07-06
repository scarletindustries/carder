//// Spec-grounded tests for `rt_table_atomics` (unit P4-06) — the tier-O, O(1)-integer-slot
//// `atomics`+companion funcref-table backend. Assertions target the WebAssembly spec, NOT
//// whatever the impl emits:
////
//// - **`call_indirect` execution & the three ORDERED traps** —
////   <https://webassembly.github.io/spec/core/exec/instructions.html>.
//// - **Exact STRUCTURAL `FuncType` equality** is the table's type-safety guarantee
////   (<https://webassembly.org/docs/security/>).
//// - **Active element segments bounds-check the WHOLE range, write nothing on overflow**
////   (<https://webassembly.github.io/spec/core/exec/modules.html#instantiation>).
//// - **No ambient authority (D3a)** — the only runtime-data inputs reaching a control transfer
////   are the integer index and the integer dense key; the dispatched target is the build-supplied
////   companion closure, invoked directly.
//// - **Byte-identical to `TablePaged`** — the three faults + right-type call match the paged
////   oracle (the differential in `rt_table_tier_differential_test`).
////
//// Both op families are covered: the cell-backed heads and the threaded heads, asserting the
//// threaded ops return the record per the §10 rule (a hybrid backend returns the handle with the
//// GROWN companion; `occ` written in place).

import gleam/dynamic
import gleam/option.{None, Some}
import gleam/result
import gleeunit/should
import twocore/ir.{
  type FuncType, FuncType, IndirectCallTypeMismatch, TI32, TI64,
  TableOutOfBounds, UndefinedElement, UninitializedElement,
}
import twocore/runtime/rt_state.{type InstanceState, StateDecl}
import twocore/runtime/rt_table_atomics as atom

/// Catch a raise (pure Gleam cannot `catch`); shared fail-closed helper.
@external(erlang, "twocore_rt_state_test_ffi", "catch_thunk")
fn catch_thunk(thunk: fn() -> a) -> Result(a, String)

/// Box a value as the package `Dynamic` a Phase-13 funcref closure returns (identity at run time).
@external(erlang, "gleam_stdlib", "identity")
fn to_pkg(v: a) -> dynamic.Dynamic

// ── shared fixtures ──────────────────────────────────────────────────────────────

fn ii_i() -> FuncType {
  FuncType([TI32, TI32], [TI32])
}

fn add_cell() -> fn(List(Int)) -> dynamic.Dynamic {
  fn(args) {
    case args {
      [a, b] -> to_pkg(a + b)
      _ -> panic as "add_cell: expected exactly two args"
    }
  }
}

fn add_threaded() -> fn(InstanceState, List(Int)) ->
  #(dynamic.Dynamic, InstanceState) {
  fn(st, args) {
    case args {
      [a, b] -> #(to_pkg(a + b), st)
      _ -> panic as "add_threaded: expected exactly two args"
    }
  }
}

fn seed_atom(size: Int) -> Nil {
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [],
    table: atom.new(size, None),
  ))
}

fn threaded_atom(size: Int) -> InstanceState {
  rt_state.fresh(StateDecl(
    mem: dynamic.nil(),
    globals: [],
    table: atom.new(size, None),
  ))
}

// ══════════════════════════ CELL family ══════════════════════════

pub fn cell_matching_type_runs_test() {
  seed_atom(4)
  let assert Ok(Nil) = atom.init_elem(0, [#(ii_i(), add_cell())])
  atom.call_indirect(0, ii_i(), [3, 4]) |> should.equal(Ok([7]))
}

pub fn cell_zero_and_multi_result_test() {
  seed_atom(2)
  let nullary = FuncType([], [])
  let pair = FuncType([TI32], [TI32, TI32])
  let assert Ok(Nil) =
    atom.init_elem(0, [
      #(nullary, fn(_args) { to_pkg(0) }),
      #(pair, fn(args) {
        case args {
          [x] -> to_pkg(#(x, x + 1))
          _ -> panic as "pair"
        }
      }),
    ])
  atom.call_indirect(0, nullary, []) |> should.equal(Ok([]))
  atom.call_indirect(1, pair, [10]) |> should.equal(Ok([10, 11]))
}

pub fn cell_out_of_bounds_is_undefined_element_test() {
  seed_atom(3)
  let assert Ok(Nil) = atom.init_elem(0, [#(ii_i(), add_cell())])
  atom.call_indirect(3, ii_i(), [1, 2]) |> should.equal(Error(UndefinedElement))
  atom.call_indirect(-1, ii_i(), [1, 2])
  |> should.equal(Error(UndefinedElement))
}

pub fn cell_null_slot_is_uninitialized_element_test() {
  seed_atom(3)
  let assert Ok(Nil) = atom.init_elem(0, [#(ii_i(), add_cell())])
  atom.call_indirect(1, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
  atom.call_indirect(2, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
}

pub fn cell_wrong_type_is_type_mismatch_test() {
  seed_atom(2)
  let assert Ok(Nil) =
    atom.init_elem(0, [
      #(ii_i(), add_cell()),
      #(FuncType([TI32], [TI32]), fn(args) {
        case args {
          [a] -> to_pkg(a)
          _ -> panic as "id"
        }
      }),
    ])
  atom.call_indirect(0, FuncType([TI32], [TI32]), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
  atom.call_indirect(1, FuncType([TI32], []), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
}

pub fn cell_bounds_precedes_type_test() {
  seed_atom(2)
  let assert Ok(Nil) =
    atom.init_elem(0, [#(ii_i(), add_cell()), #(ii_i(), add_cell())])
  atom.call_indirect(2, FuncType([TI64], [TI64]), [1, 2])
  |> should.equal(Error(UndefinedElement))
}

pub fn cell_null_precedes_type_test() {
  seed_atom(2)
  atom.call_indirect(0, FuncType([TI64], [TI64]), [])
  |> should.equal(Error(UninitializedElement))
}

pub fn cell_structurally_equal_types_match_test() {
  seed_atom(1)
  let stored = FuncType([TI32, TI32], [TI32])
  let expected = FuncType([TI32, TI32], [TI32])
  let assert Ok(Nil) = atom.init_elem(0, [#(stored, add_cell())])
  atom.call_indirect(0, expected, [2, 5]) |> should.equal(Ok([7]))
}

pub fn cell_structurally_distinct_types_mismatch_test() {
  seed_atom(1)
  let assert Ok(Nil) =
    atom.init_elem(0, [
      #(FuncType([TI32], [TI32]), fn(args) {
        case args {
          [a] -> to_pkg(a)
          _ -> panic as "id"
        }
      }),
    ])
  atom.call_indirect(0, FuncType([TI64], [TI32]), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
  atom.call_indirect(0, FuncType([TI32], []), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
}

pub fn cell_init_elem_out_of_bounds_writes_nothing_test() {
  seed_atom(2)
  atom.init_elem(2, [#(ii_i(), add_cell())])
  |> should.equal(Error(TableOutOfBounds))
  atom.init_elem(1, [#(ii_i(), add_cell()), #(ii_i(), add_cell())])
  |> should.equal(Error(TableOutOfBounds))
  atom.call_indirect(0, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
  atom.call_indirect(1, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
}

pub fn cell_init_elem_negative_offset_writes_nothing_test() {
  seed_atom(2)
  atom.init_elem(-1, [#(ii_i(), add_cell())])
  |> should.equal(Error(TableOutOfBounds))
  atom.call_indirect(0, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
}

pub fn cell_init_elem_fills_exactly_its_slots_test() {
  seed_atom(3)
  let assert Ok(Nil) = atom.init_elem(1, [#(ii_i(), add_cell())])
  atom.call_indirect(1, ii_i(), [6, 1]) |> should.equal(Ok([7]))
  atom.call_indirect(0, ii_i(), [6, 1])
  |> should.equal(Error(UninitializedElement))
  atom.call_indirect(2, ii_i(), [6, 1])
  |> should.equal(Error(UninitializedElement))
}

/// Two separate element segments assign DISTINCT dense keys (the companion never overwrites a
/// prior fill): both slots stay independently callable.
pub fn cell_two_segments_independent_dense_keys_test() {
  seed_atom(3)
  let assert Ok(Nil) = atom.init_elem(0, [#(ii_i(), add_cell())])
  let assert Ok(Nil) =
    atom.init_elem(2, [
      #(FuncType([TI32], [TI32]), fn(args) {
        case args {
          [a] -> to_pkg(a * 2)
          _ -> panic as "id2"
        }
      }),
    ])
  atom.call_indirect(0, ii_i(), [3, 4]) |> should.equal(Ok([7]))
  atom.call_indirect(2, FuncType([TI32], [TI32]), [5]) |> should.equal(Ok([10]))
}

pub fn cell_fail_closed_on_unseeded_test() {
  rt_state.clear()
  catch_thunk(fn() { atom.call_indirect(0, ii_i(), [1, 2]) })
  |> result.is_error
  |> should.be_true
  catch_thunk(fn() { atom.init_elem(0, [#(ii_i(), add_cell())]) })
  |> result.is_error
  |> should.be_true
}

pub fn cell_dispatch_invokes_supplied_closure_test() {
  seed_atom(1)
  let captured = 1000
  let assert Ok(Nil) =
    atom.init_elem(0, [
      #(ii_i(), fn(args) {
        case args {
          [a, b] -> to_pkg(a + b + captured)
          _ -> panic as "two args"
        }
      }),
    ])
  atom.call_indirect(0, ii_i(), [3, 4]) |> should.equal(Ok([1007]))
}

/// A re-seed builds a FRESH `atomics` array: a prior fill does not bleed through (the ref is
/// reachable only via the handle, §C).
pub fn cell_isolation_between_seeds_test() {
  seed_atom(2)
  let assert Ok(Nil) = atom.init_elem(0, [#(ii_i(), add_cell())])
  atom.call_indirect(0, ii_i(), [1, 2]) |> should.equal(Ok([3]))
  seed_atom(2)
  atom.call_indirect(0, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
}

// ══════════════════════════ THREADED family ══════════════════════════

pub fn threaded_matching_type_runs_test() {
  let st = threaded_atom(4)
  let assert Ok(st) = atom.t_init_elem(st, 0, [#(ii_i(), add_threaded())])
  atom.t_call_indirect(st, 0, ii_i(), [3, 4])
  |> should.equal(Ok(#([7], st)))
}

/// §10 rule for a hybrid backend: `t_init_elem` returns the handle with the GROWN companion, so a
/// `call_indirect` through the RETURNED `st` sees the fill.
pub fn threaded_init_elem_grows_companion_test() {
  let st = threaded_atom(2)
  let assert Ok(st2) = atom.t_init_elem(st, 0, [#(ii_i(), add_threaded())])
  atom.t_call_indirect(st2, 0, ii_i(), [10, 5])
  |> should.equal(Ok(#([15], st2)))
}

pub fn threaded_three_faults_test() {
  let st = threaded_atom(3)
  let assert Ok(st) = atom.t_init_elem(st, 0, [#(ii_i(), add_threaded())])
  atom.t_call_indirect(st, 3, ii_i(), [1, 2])
  |> should.equal(Error(UndefinedElement))
  atom.t_call_indirect(st, -1, ii_i(), [1, 2])
  |> should.equal(Error(UndefinedElement))
  atom.t_call_indirect(st, 1, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
  atom.t_call_indirect(st, 0, FuncType([TI32], [TI32]), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
}

pub fn threaded_init_elem_out_of_bounds_writes_nothing_test() {
  let st = threaded_atom(2)
  atom.t_init_elem(st, 2, [#(ii_i(), add_threaded())])
  |> should.equal(Error(TableOutOfBounds))
  atom.t_call_indirect(st, 0, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
}

pub fn threaded_call_returns_callee_state_test() {
  let st =
    rt_state.fresh(StateDecl(
      mem: dynamic.nil(),
      globals: [#("g", 0)],
      table: atom.new(1, None),
    ))
  let bump = fn(st: InstanceState, args: List(Int)) {
    case args {
      [x] -> #(to_pkg(x), rt_state.t_global_set(st, "g", x))
      _ -> panic as "one arg"
    }
  }
  let assert Ok(st) =
    atom.t_init_elem(st, 0, [#(FuncType([TI32], [TI32]), bump)])
  let assert Ok(#([9], st2)) =
    atom.t_call_indirect(st, 0, FuncType([TI32], [TI32]), [9])
  rt_state.t_global_get(st2, "g") |> should.equal(9)
}

// ══════════════════════════ differential canon hook ══════════════════════════

pub fn to_canon_reports_slot_image_test() {
  let handle = atom.new(3, None)
  rt_state.seed(StateDecl(mem: dynamic.nil(), globals: [], table: handle))
  let assert Ok(Nil) = atom.init_elem(1, [#(ii_i(), add_cell())])
  atom.to_canon(rt_state.table_get())
  |> should.equal([None, Some(ii_i()), None])
}

/// A 0-slot table's `to_canon` is the empty image (`build_indices` edge case).
pub fn to_canon_zero_size_test() {
  atom.to_canon(atom.new(0, None)) |> should.equal([])
}
