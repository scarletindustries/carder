//// Spec-grounded tests for `rt_table_ets` (unit P4-06) — the tier-O, closure-native ETS
//// funcref-table backend. Assertions target the WebAssembly spec, NOT whatever the impl emits:
////
//// - **`call_indirect` execution & the three ORDERED traps** —
////   <https://webassembly.github.io/spec/core/exec/instructions.html>: pop the i32 index; trap
////   `undefined element` if out of bounds; else `uninitialized element` if the slot is null; else
////   `indirect call type mismatch` if the stored type differs; else invoke.
//// - **Exact STRUCTURAL `FuncType` equality** is the table's type-safety guarantee
////   (<https://webassembly.org/docs/security/>; the per-call check is purely runtime —
////   <https://webassembly.github.io/spec/core/valid/instructions.html>).
//// - **Active element segments bounds-check the WHOLE range, write nothing on overflow**
////   (<https://webassembly.github.io/spec/core/exec/modules.html#instantiation>).
//// - **No ambient authority (D3a)** — dispatch invokes the SUPPLIED build-controlled closure
////   directly; the backend never `apply`s a data-derived module/function.
//// - **Process-local + lifecycle (§C)** — a `private` ETS table a second process cannot read; a
////   re-`new` in a reused process deletes the prior table (no leak).
//// - **Byte-identical to `TablePaged`** — the three faults + right-type call are the SAME as the
////   paged oracle (the differential in `rt_table_tier_differential_test`).
////
//// Both op families are covered: the cell-backed heads (seed a pdict cell) and the threaded heads
//// (over an `InstanceState`), asserting the threaded ops return the record per the §10 rule (a
//// mutable-in-place backend returns the SAME handle).

import carder/ir.{
  type FuncType, FuncType, IndirectCallTypeMismatch, TI32, TI64,
  TableOutOfBounds, UndefinedElement, UninitializedElement,
}
import carder/runtime/rt_state.{type InstanceState, StateDecl}
import carder/runtime/rt_table_ets as ets
import gleam/dynamic
import gleam/option.{None, Some}
import gleam/result
import gleeunit/should

/// Catch a raise (pure Gleam cannot `catch`); shared fail-closed helper.
@external(erlang, "carder_rt_state_test_ffi", "catch_thunk")
fn catch_thunk(thunk: fn() -> a) -> Result(a, String)

/// Box a value as the package `Dynamic` a Phase-13 funcref closure returns (identity at run time).
@external(erlang, "gleam_stdlib", "identity")
fn to_pkg(v: a) -> dynamic.Dynamic

/// The count of `carder_rt_table` ETS tables THIS process owns (lifecycle/leak probe).
@external(erlang, "carder_rt_table_ets_test_ffi", "owned_table_count")
fn owned_table_count() -> Int

/// Whether a SECOND process is BLOCKED from reading the ETS table in `handle` (privacy probe).
@external(erlang, "carder_rt_table_ets_test_ffi", "private_blocks_other_process")
fn private_blocks_other_process(handle: dynamic.Dynamic) -> Bool

// ── shared fixtures ──────────────────────────────────────────────────────────────

/// The structural type `(i32, i32) -> i32`.
fn ii_i() -> FuncType {
  FuncType([TI32, TI32], [TI32])
}

/// A cell-family closure adding its two i32 args.
fn add_cell() -> fn(List(Int)) -> dynamic.Dynamic {
  fn(args) {
    case args {
      [a, b] -> to_pkg(a + b)
      _ -> panic as "add_cell: expected exactly two args"
    }
  }
}

/// A threaded-family closure adding its two i32 args, threading `st` unchanged.
fn add_threaded() -> fn(InstanceState, List(Int)) ->
  #(dynamic.Dynamic, InstanceState) {
  fn(st, args) {
    case args {
      [a, b] -> #(to_pkg(a + b), st)
      _ -> panic as "add_threaded: expected exactly two args"
    }
  }
}

/// Seed a fresh cell whose ETS table has `size` null slots (no mem, no globals).
fn seed_ets(size: Int) -> Nil {
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [],
    table: ets.new(size, None),
  ))
}

/// A threaded InstanceState whose `table` slot holds a fresh ETS table of `size` slots.
fn threaded_ets(size: Int) -> InstanceState {
  rt_state.fresh(StateDecl(
    mem: dynamic.nil(),
    globals: [],
    table: ets.new(size, None),
  ))
}

// ══════════════════════════ CELL family ══════════════════════════

// ── 1. Happy path ────────────────────────────────────────────────────────────────

pub fn cell_matching_type_runs_test() {
  seed_ets(4)
  let assert Ok(Nil) = ets.init_elem(0, [#(ii_i(), add_cell())])
  ets.call_indirect(0, ii_i(), [3, 4]) |> should.equal(Ok([7]))
}

pub fn cell_zero_and_multi_result_test() {
  seed_ets(2)
  let nullary = FuncType([], [])
  let pair = FuncType([TI32], [TI32, TI32])
  let assert Ok(Nil) =
    ets.init_elem(0, [
      #(nullary, fn(_args) { to_pkg(0) }),
      #(pair, fn(args) {
        case args {
          [x] -> to_pkg(#(x, x + 1))
          _ -> panic as "pair"
        }
      }),
    ])
  ets.call_indirect(0, nullary, []) |> should.equal(Ok([]))
  ets.call_indirect(1, pair, [10]) |> should.equal(Ok([10, 11]))
}

// ── 2. Three faults, right reason & ORDER ─────────────────────────────────────────

pub fn cell_out_of_bounds_is_undefined_element_test() {
  seed_ets(3)
  let assert Ok(Nil) = ets.init_elem(0, [#(ii_i(), add_cell())])
  ets.call_indirect(3, ii_i(), [1, 2]) |> should.equal(Error(UndefinedElement))
  ets.call_indirect(-1, ii_i(), [1, 2]) |> should.equal(Error(UndefinedElement))
}

pub fn cell_null_slot_is_uninitialized_element_test() {
  seed_ets(3)
  let assert Ok(Nil) = ets.init_elem(0, [#(ii_i(), add_cell())])
  ets.call_indirect(1, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
  ets.call_indirect(2, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
}

pub fn cell_wrong_type_is_type_mismatch_test() {
  seed_ets(2)
  let assert Ok(Nil) =
    ets.init_elem(0, [
      #(ii_i(), add_cell()),
      #(FuncType([TI32], [TI32]), fn(args) {
        case args {
          [a] -> to_pkg(a)
          _ -> panic as "id"
        }
      }),
    ])
  // Param difference.
  ets.call_indirect(0, FuncType([TI32], [TI32]), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
  // Result difference.
  ets.call_indirect(1, FuncType([TI32], []), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
}

/// Bounds fires BEFORE type: an OOB index whose in-range slots are wrong-type still traps
/// `UndefinedElement`.
pub fn cell_bounds_precedes_type_test() {
  seed_ets(2)
  let assert Ok(Nil) =
    ets.init_elem(0, [#(ii_i(), add_cell()), #(ii_i(), add_cell())])
  ets.call_indirect(2, FuncType([TI64], [TI64]), [1, 2])
  |> should.equal(Error(UndefinedElement))
}

/// Null fires BEFORE type: a null in-range slot traps `UninitializedElement` even with an
/// unmatchable expected type.
pub fn cell_null_precedes_type_test() {
  seed_ets(2)
  ets.call_indirect(0, FuncType([TI64], [TI64]), [])
  |> should.equal(Error(UninitializedElement))
}

// ── 3. Structural type equality ───────────────────────────────────────────────────

pub fn cell_structurally_equal_types_match_test() {
  seed_ets(1)
  let stored = FuncType([TI32, TI32], [TI32])
  let expected = FuncType([TI32, TI32], [TI32])
  let assert Ok(Nil) = ets.init_elem(0, [#(stored, add_cell())])
  ets.call_indirect(0, expected, [2, 5]) |> should.equal(Ok([7]))
}

pub fn cell_structurally_distinct_types_mismatch_test() {
  seed_ets(1)
  let assert Ok(Nil) =
    ets.init_elem(0, [
      #(FuncType([TI32], [TI32]), fn(args) {
        case args {
          [a] -> to_pkg(a)
          _ -> panic as "id"
        }
      }),
    ])
  ets.call_indirect(0, FuncType([TI64], [TI32]), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
  ets.call_indirect(0, FuncType([TI32], []), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
}

// ── 4. init_elem whole-range bounds (all-or-nothing) ──────────────────────────────

pub fn cell_init_elem_out_of_bounds_writes_nothing_test() {
  seed_ets(2)
  ets.init_elem(2, [#(ii_i(), add_cell())])
  |> should.equal(Error(TableOutOfBounds))
  ets.init_elem(1, [#(ii_i(), add_cell()), #(ii_i(), add_cell())])
  |> should.equal(Error(TableOutOfBounds))
  // No partial write: every slot still null.
  ets.call_indirect(0, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
  ets.call_indirect(1, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
}

pub fn cell_init_elem_negative_offset_writes_nothing_test() {
  seed_ets(2)
  ets.init_elem(-1, [#(ii_i(), add_cell())])
  |> should.equal(Error(TableOutOfBounds))
  ets.call_indirect(0, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
}

pub fn cell_init_elem_fills_exactly_its_slots_test() {
  seed_ets(3)
  let assert Ok(Nil) = ets.init_elem(1, [#(ii_i(), add_cell())])
  ets.call_indirect(1, ii_i(), [6, 1]) |> should.equal(Ok([7]))
  ets.call_indirect(0, ii_i(), [6, 1])
  |> should.equal(Error(UninitializedElement))
  ets.call_indirect(2, ii_i(), [6, 1])
  |> should.equal(Error(UninitializedElement))
}

// ── 5. Fail-closed on an un-seeded cell (E3) ──────────────────────────────────────

pub fn cell_fail_closed_on_unseeded_test() {
  rt_state.clear()
  catch_thunk(fn() { ets.call_indirect(0, ii_i(), [1, 2]) })
  |> result.is_error
  |> should.be_true
  catch_thunk(fn() { ets.init_elem(0, [#(ii_i(), add_cell())]) })
  |> result.is_error
  |> should.be_true
}

// ── 6. D3a — only the SUPPLIED closure runs ───────────────────────────────────────

pub fn cell_dispatch_invokes_supplied_closure_test() {
  seed_ets(1)
  let captured = 1000
  let assert Ok(Nil) =
    ets.init_elem(0, [
      #(ii_i(), fn(args) {
        case args {
          [a, b] -> to_pkg(a + b + captured)
          _ -> panic as "two args"
        }
      }),
    ])
  ets.call_indirect(0, ii_i(), [3, 4]) |> should.equal(Ok([1007]))
}

// ══════════════════════════ THREADED family ══════════════════════════

pub fn threaded_matching_type_runs_test() {
  let st = threaded_ets(4)
  let assert Ok(st) = ets.t_init_elem(st, 0, [#(ii_i(), add_threaded())])
  ets.t_call_indirect(st, 0, ii_i(), [3, 4])
  |> should.equal(Ok(#([7], st)))
}

/// §10 rule for a mutable-in-place backend: `t_init_elem` returns the SAME `st` (ETS is mutated
/// through the stable `tid`, so the handle value is unchanged).
pub fn threaded_init_elem_returns_same_st_test() {
  let st = threaded_ets(2)
  let assert Ok(st2) = ets.t_init_elem(st, 0, [#(ii_i(), add_threaded())])
  // The handle Dynamic is unchanged (same tid) — the returned st equals the input st.
  rt_state.table(st2) |> should.equal(rt_state.table(st))
}

pub fn threaded_three_faults_test() {
  let st = threaded_ets(3)
  let assert Ok(st) = ets.t_init_elem(st, 0, [#(ii_i(), add_threaded())])
  // Bounds.
  ets.t_call_indirect(st, 3, ii_i(), [1, 2])
  |> should.equal(Error(UndefinedElement))
  ets.t_call_indirect(st, -1, ii_i(), [1, 2])
  |> should.equal(Error(UndefinedElement))
  // Null.
  ets.t_call_indirect(st, 1, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
  // Type.
  ets.t_call_indirect(st, 0, FuncType([TI32], [TI32]), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
}

pub fn threaded_init_elem_out_of_bounds_writes_nothing_test() {
  let st = threaded_ets(2)
  ets.t_init_elem(st, 2, [#(ii_i(), add_threaded())])
  |> should.equal(Error(TableOutOfBounds))
  // No partial write.
  ets.t_call_indirect(st, 0, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
}

/// A threaded target that MUTATES a global proves `t_call_indirect` returns the callee's `st'`.
pub fn threaded_call_returns_callee_state_test() {
  let st =
    rt_state.fresh(StateDecl(
      mem: dynamic.nil(),
      globals: [#("g", 0)],
      table: ets.new(1, None),
    ))
  let bump = fn(st: InstanceState, args: List(Int)) {
    case args {
      [x] -> #(to_pkg(x), rt_state.t_global_set(st, "g", x))
      _ -> panic as "one arg"
    }
  }
  let assert Ok(st) =
    ets.t_init_elem(st, 0, [#(FuncType([TI32], [TI32]), bump)])
  let assert Ok(#([9], st2)) =
    ets.t_call_indirect(st, 0, FuncType([TI32], [TI32]), [9])
  rt_state.t_global_get(st2, "g") |> should.equal(9)
}

// ══════════════════════════ PROCESS-LOCAL + LIFECYCLE (§C) ══════════════════════════

/// The ETS table is `private`: a second process cannot read it (never shared memory, G8).
pub fn ets_table_is_private_test() {
  let handle = ets.new(1, None)
  private_blocks_other_process(handle) |> should.be_true
}

/// Re-instantiation in a reused process deletes the prior table (§C/§D — no leak): after two
/// successive `new`s the process still owns exactly ONE `carder_rt_table`, not two.
pub fn ets_re_new_deletes_prior_no_leak_test() {
  let _h1 = ets.new(4, None)
  owned_table_count() |> should.equal(1)
  let _h2 = ets.new(4, None)
  // The prior table was deleted, not leaked.
  owned_table_count() |> should.equal(1)
}

/// Re-`new` gives a FRESH empty table: a prior segment's fills do not bleed through.
pub fn ets_re_new_is_fresh_test() {
  seed_ets(2)
  let assert Ok(Nil) = ets.init_elem(0, [#(ii_i(), add_cell())])
  ets.call_indirect(0, ii_i(), [1, 2]) |> should.equal(Ok([3]))
  // Re-seed with a fresh table: slot 0 is null again.
  seed_ets(2)
  ets.call_indirect(0, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
}

// ══════════════════════════ differential canon hook ══════════════════════════

/// `to_canon` reports null vs filled slots with the filled slot's structural `FuncType`.
pub fn to_canon_reports_slot_image_test() {
  let handle = ets.new(3, None)
  rt_state.seed(StateDecl(mem: dynamic.nil(), globals: [], table: handle))
  let assert Ok(Nil) = ets.init_elem(1, [#(ii_i(), add_cell())])
  ets.to_canon(rt_state.table_get())
  |> should.equal([None, Some(ii_i()), None])
}
