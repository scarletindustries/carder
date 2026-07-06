//// Spec-grounded tests for `rt_table` (unit 05) — the funcref table value and the
//// 3-fault fail-closed `call_indirect` dispatch.
////
//// Assertions target the WebAssembly spec, NOT whatever the implementation emits:
////
//// - **`call_indirect` execution & the three ORDERED traps** —
////   <https://webassembly.github.io/spec/core/exec/instructions.html>: pop the i32 index;
////   trap `undefined element` if the index is out of bounds; else trap
////   `uninitialized element` if the slot is null; else trap `indirect call type mismatch`
////   if the stored function's type differs from the call site's; else invoke.
//// - **The dynamic type check is exact STRUCTURAL `FuncType` equality** (the type-safety
////   guarantee of the table mechanism, <https://webassembly.org/docs/security/>;
////   <https://webassembly.github.io/spec/core/valid/instructions.html> makes validation
////   static-only, so the per-call check is purely runtime).
//// - **Active element segments bounds-check the WHOLE range and write nothing on overflow**
////   (<https://webassembly.github.io/spec/core/exec/modules.html#instantiation> — an
////   out-of-bounds active segment aborts instantiation; no partial table write).
//// - **No ambient authority (D3a/E3)** — dispatch invokes the SUPPLIED build-controlled
////   closure directly; `rt_table` never `apply`s a data-derived module/function.
//// - **Fail-closed (E3)** — an op on an un-seeded cell raises rather than reading garbage.
//// - **Frozen trap-message mappings** — `rt_trap.spec_trap_message` reads exactly the spec
////   substrings (guards against drift in the unit-01 freeze).
////
//// Each test seeds its own cell (the table lives in the per-instance pdict cell). Exceptions
//// are caught via the namespace-hygienic `twocore_rt_state_test_ffi` helper (pure Gleam
//// cannot `catch`).

import gleam/dynamic
import gleam/option
import gleam/result
import gleeunit/should
import twocore/ir.{
  type FuncType, FuncType, IndirectCallTypeMismatch, TI32, TI64,
  TableOutOfBounds, UndefinedElement, UninitializedElement,
}
import twocore/runtime/rt_state.{type InstanceState, StateDecl}
import twocore/runtime/rt_table
import twocore/runtime/rt_trap

/// Run `thunk` and report whether it raised: `Ok(value)` on a normal return, `Error(text)`
/// on any raise/exit/throw. The fail-closed tests assert it raised at all (E3: never read
/// garbage). Shared with the `rt_state` tests.
@external(erlang, "twocore_rt_state_test_ffi", "catch_thunk")
fn catch_thunk(thunk: fn() -> a) -> Result(a, String)

/// Box a value as the package `Dynamic` a Phase-13 funcref closure returns (identity at run time).
@external(erlang, "gleam_stdlib", "identity")
fn to_pkg(v: a) -> dynamic.Dynamic

// ── test helpers ───────────────────────────────────────────────────────────────

/// Seed a fresh cell whose table has `size` null slots (no mem, no globals). Every test
/// that touches the table calls this first — the table lives in THIS process's cell.
fn seed_table(size: Int) -> Nil {
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [],
    // `None` max: a fixed-size MVP table (no `table.grow`).
    table: rt_table.new(size, option.None),
  ))
}

/// The structural type of a binary i32 operator: `(i32, i32) -> i32`.
fn ii_i() -> FuncType {
  FuncType([TI32, TI32], [TI32])
}

/// A build-controlled closure adding its two i32 args (raw bits; small positives here).
fn add_closure() -> fn(List(Int)) -> dynamic.Dynamic {
  fn(args) {
    case args {
      [a, b] -> to_pkg(a + b)
      _ -> panic as "add_closure: expected exactly two args"
    }
  }
}

// ── 1. Happy path — a matching call runs and returns the right values ────────────

/// `call_indirect` to a slot whose stored type EXACTLY matches the call site invokes the
/// build-controlled closure and returns its results (exec/instructions.html step 5).
pub fn call_indirect_matching_type_runs_test() {
  seed_table(4)
  let assert Ok(Nil) = rt_table.init_elem(0, [#(ii_i(), add_closure())])

  rt_table.call_indirect(0, ii_i(), [3, 4])
  |> should.equal(Ok([7]))
}

/// The closure interface is `fn(List(Int)) -> List(Int)`, so 0-arg/0-result and multi-result
/// targets round-trip through dispatch (the function-boundary list contract: 0→[], N→[..]).
pub fn call_indirect_zero_and_multi_result_test() {
  seed_table(2)
  let nullary = FuncType([], [])
  let pair = FuncType([TI32], [TI32, TI32])
  let assert Ok(Nil) =
    rt_table.init_elem(0, [
      #(nullary, fn(_args) { to_pkg(0) }),
      #(pair, fn(args) {
        case args {
          [x] -> to_pkg(#(x, x + 1))
          _ -> panic as "pair: expected one arg"
        }
      }),
    ])

  // 0 args → 0 results.
  rt_table.call_indirect(0, nullary, []) |> should.equal(Ok([]))
  // 1 arg → 2 results.
  rt_table.call_indirect(1, pair, [10]) |> should.equal(Ok([10, 11]))
}

// ── 2. Three faults, the right reason ────────────────────────────────────────────

/// An index `>= size` (and a negative index) traps `UndefinedElement` — the index is out of
/// the table's bounds (exec/instructions.html: `i >= length(table.elem)` ⇒ "undefined
/// element").
pub fn out_of_bounds_index_is_undefined_element_test() {
  seed_table(3)
  let assert Ok(Nil) = rt_table.init_elem(0, [#(ii_i(), add_closure())])

  // index == size (off-by-one) and a negative index both trap UndefinedElement.
  rt_table.call_indirect(3, ii_i(), [1, 2])
  |> should.equal(Error(UndefinedElement))
  rt_table.call_indirect(-1, ii_i(), [1, 2])
  |> should.equal(Error(UndefinedElement))
}

/// An in-range but never-filled slot traps `UninitializedElement` (the slot is null).
pub fn null_slot_is_uninitialized_element_test() {
  seed_table(3)
  // Fill slot 0 only; slots 1 and 2 stay null.
  let assert Ok(Nil) = rt_table.init_elem(0, [#(ii_i(), add_closure())])

  rt_table.call_indirect(1, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
  rt_table.call_indirect(2, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
}

/// A filled slot whose stored type differs from the call site's expected type traps
/// `IndirectCallTypeMismatch` — for a difference in params OR in results.
pub fn wrong_type_slot_is_type_mismatch_test() {
  seed_table(2)
  // Slot 0 holds an (i32,i32)->i32; slot 1 holds an (i32)->i32.
  let assert Ok(Nil) =
    rt_table.init_elem(0, [
      #(ii_i(), add_closure()),
      #(FuncType([TI32], [TI32]), fn(args) {
        case args {
          [a] -> to_pkg(a)
          _ -> panic as "id: expected one arg"
        }
      }),
    ])

  // Different params: expected (i32)->i32 against the stored (i32,i32)->i32.
  rt_table.call_indirect(0, FuncType([TI32], [TI32]), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
  // Different results: expected (i32)->() against the stored (i32)->i32.
  rt_table.call_indirect(1, FuncType([TI32], []), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
}

// ── 3. Guard ORDER (bounds → null → type) ────────────────────────────────────────

/// An OOB index whose in-range slots are ALL wrong-type still traps `UndefinedElement`
/// FIRST — the bounds guard precedes the type guard (the order is observable).
pub fn bounds_guard_precedes_type_guard_test() {
  seed_table(2)
  // Both in-range slots hold a type that no plausible expected type matches.
  let assert Ok(Nil) =
    rt_table.init_elem(0, [#(ii_i(), add_closure()), #(ii_i(), add_closure())])

  // index == size: even though slots 0/1 are wrong-type for this call site, an OOB index
  // must report UndefinedElement, not IndirectCallTypeMismatch.
  rt_table.call_indirect(2, FuncType([TI64], [TI64]), [1, 2])
  |> should.equal(Error(UndefinedElement))
}

/// A null in-range slot traps `UninitializedElement` BEFORE any type comparison — the null
/// guard precedes the type guard.
pub fn null_guard_precedes_type_guard_test() {
  seed_table(2)
  // Leave every slot null. A type that could never match is irrelevant: the null check wins.
  rt_table.call_indirect(0, FuncType([TI64], [TI64]), [])
  |> should.equal(Error(UninitializedElement))
}

// ── 4. Exact STRUCTURAL FuncType equality (==, not identity / not typeidx) ───────

/// Two DISTINCT `FuncType` values that are structurally equal match (`Ok`) — the check is
/// structural `==`, not object identity or a typeidx compare. (The stored type and the
/// expected type are built from separate literals.)
pub fn structurally_equal_types_match_test() {
  seed_table(1)
  // Stored type and expected type are independently-constructed equal values.
  let stored = FuncType([TI32, TI32], [TI32])
  let expected = FuncType([TI32, TI32], [TI32])
  let assert Ok(Nil) = rt_table.init_elem(0, [#(stored, add_closure())])

  rt_table.call_indirect(0, expected, [2, 5])
  |> should.equal(Ok([7]))
}

/// Differing params (`[TI64]` vs `[TI32]`) and differing results (`[]` vs `[TI32]`) each
/// mismatch — proving `==` distinguishes both halves of the structural type.
pub fn structurally_distinct_types_mismatch_test() {
  seed_table(1)
  let assert Ok(Nil) =
    rt_table.init_elem(0, [
      #(FuncType([TI32], [TI32]), fn(args) {
        case args {
          [a] -> to_pkg(a)
          _ -> panic as "id"
        }
      }),
    ])

  // Param difference: stored (i32)->i32 vs expected (i64)->i32.
  rt_table.call_indirect(0, FuncType([TI64], [TI32]), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
  // Result difference: stored (i32)->i32 vs expected (i32)->().
  rt_table.call_indirect(0, FuncType([TI32], []), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
}

// ── 5. `init_elem` whole-range bounds at instantiation (all-or-nothing) ──────────

/// An element segment that does not fit (`offset + len > size`, here the exact off-by-one
/// `offset == size`) returns `Error(TableOutOfBounds)` and writes NOTHING — a later
/// `call_indirect` to a slot the segment would have filled still traps `UninitializedElement`
/// (no partial write).
pub fn init_elem_out_of_bounds_writes_nothing_test() {
  seed_table(2)

  // offset == size: a single-entry segment at offset 2 of a size-2 table overflows.
  rt_table.init_elem(2, [#(ii_i(), add_closure())])
  |> should.equal(Error(TableOutOfBounds))

  // A multi-entry segment straddling the end (offset 1, len 2 > size 2) also overflows.
  rt_table.init_elem(1, [#(ii_i(), add_closure()), #(ii_i(), add_closure())])
  |> should.equal(Error(TableOutOfBounds))

  // Nothing was written: every slot is still null.
  rt_table.call_indirect(0, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
  rt_table.call_indirect(1, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
}

/// A negative offset also overflows (no write).
pub fn init_elem_negative_offset_writes_nothing_test() {
  seed_table(2)
  rt_table.init_elem(-1, [#(ii_i(), add_closure())])
  |> should.equal(Error(TableOutOfBounds))

  rt_table.call_indirect(0, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
}

/// An in-range segment fills EXACTLY its slots and leaves the rest null — `init_elem(1, [e])`
/// on a size-3 table fills only slot 1.
pub fn init_elem_fills_exactly_its_slots_test() {
  seed_table(3)
  let assert Ok(Nil) = rt_table.init_elem(1, [#(ii_i(), add_closure())])

  // Slot 1 is callable; slots 0 and 2 remain null.
  rt_table.call_indirect(1, ii_i(), [6, 1]) |> should.equal(Ok([7]))
  rt_table.call_indirect(0, ii_i(), [6, 1])
  |> should.equal(Error(UninitializedElement))
  rt_table.call_indirect(2, ii_i(), [6, 1])
  |> should.equal(Error(UninitializedElement))
}

// ── 6. Fail-closed on an un-seeded cell (E3 — never read garbage) ────────────────

/// With NO seeded cell, both `call_indirect` and `init_elem` RAISE (via `rt_state.table_get`)
/// rather than fabricating an empty table that silently "succeeds".
pub fn fail_closed_on_unseeded_cell_test() {
  rt_state.clear()

  catch_thunk(fn() { rt_table.call_indirect(0, ii_i(), [1, 2]) })
  |> result.is_error
  |> should.be_true

  catch_thunk(fn() { rt_table.init_elem(0, [#(ii_i(), add_closure())]) })
  |> result.is_error
  |> should.be_true
}

/// The fail-closed guard is exactly the un-seeded case, not a blanket refusal: once seeded,
/// `call_indirect` to a filled slot succeeds (proves the prior test is meaningful).
pub fn op_succeeds_once_seeded_test() {
  rt_state.clear()
  catch_thunk(fn() { rt_table.call_indirect(0, ii_i(), [1, 2]) })
  |> result.is_error
  |> should.be_true

  seed_table(1)
  let assert Ok(Nil) = rt_table.init_elem(0, [#(ii_i(), add_closure())])
  catch_thunk(fn() { rt_table.call_indirect(0, ii_i(), [3, 4]) })
  |> should.equal(Ok(Ok([7])))
}

// ── 7. Structural security — only the SUPPLIED closure is invoked (D3a) ──────────

/// Dispatch invokes the build-controlled closure DIRECTLY (`target(args)`), never an
/// `apply` of a data-derived module/function. We prove the supplied closure is what runs by
/// capturing a free variable in it: the returned value comes from that exact closure, so the
/// dispatch cannot be routing through some name reconstructed from table data.
///
/// (Structural assertion by construction: `rt_table` stores `#(FuncType, fn(List(Int)) ->
/// List(Int))` and the only control transfer is `Ok(target(args))` — a fun application of
/// the stored closure. `rt_table` constructs no module/function atom from its inputs and
/// calls no `erlang:apply/3` on data-derived names. The unit-10 structural security test
/// extends this to the generated `call_indirect` lowering.)
pub fn dispatch_invokes_supplied_closure_test() {
  seed_table(1)
  // A closure capturing a build-time constant (1000) that no table data could fabricate.
  let captured = 1000
  let assert Ok(Nil) =
    rt_table.init_elem(0, [
      #(ii_i(), fn(args) {
        case args {
          [a, b] -> to_pkg(a + b + captured)
          _ -> panic as "expected two args"
        }
      }),
    ])

  rt_table.call_indirect(0, ii_i(), [3, 4])
  |> should.equal(Ok([1007]))
}

// ── 8. Frozen trap-message mappings (guard against unit-01 drift) ────────────────

/// The three `rt_table` trap reasons map to the exact WASM-spec `assert_trap` substrings
/// (exec/instructions.html; unit 01 owns the mapping, this guards against drift).
pub fn spec_trap_messages_test() {
  rt_trap.spec_trap_message(UndefinedElement)
  |> should.equal("undefined element")
  rt_trap.spec_trap_message(UninitializedElement)
  |> should.equal("uninitialized element")
  rt_trap.spec_trap_message(IndirectCallTypeMismatch)
  |> should.equal("indirect call type mismatch")
  // The instantiation-time element-segment OOB reason.
  rt_trap.spec_trap_message(TableOutOfBounds)
  |> should.equal("out of bounds table access")
}

// ── 9. Paged THREADED family (state_strategy: Threaded; owner: unit P4-06) ────────
//
// The threaded heads `t_init_elem`/`t_call_indirect` over the SAME immutable `Dict` core: the
// handle travels in `st.table` (no pdict) and a mutating op RETURNS the (possibly rebuilt)
// record. Same three guards, same TrapReasons as the cell surface (§F).

/// A threaded add-closure adding its two i32 args and threading `st` unchanged.
fn t_add() -> fn(InstanceState, List(Int)) -> #(dynamic.Dynamic, InstanceState) {
  fn(st, args) {
    case args {
      [a, b] -> #(to_pkg(a + b), st)
      _ -> panic as "t_add: expected two args"
    }
  }
}

/// A threaded InstanceState whose table has `size` null slots.
fn threaded_table(size: Int) -> InstanceState {
  rt_state.fresh(StateDecl(
    mem: dynamic.nil(),
    globals: [],
    table: rt_table.new(size, option.None),
  ))
}

/// A matching threaded call runs and returns the results plus the callee's `st`.
pub fn threaded_matching_type_runs_test() {
  let st = threaded_table(4)
  let assert Ok(st) = rt_table.t_init_elem(st, 0, [#(ii_i(), t_add())])
  rt_table.t_call_indirect(st, 0, ii_i(), [3, 4])
  |> should.equal(Ok(#([7], st)))
}

/// §10 rule for the IMMUTABLE paged backend: `t_init_elem` returns a REBUILT `st` whose table now
/// holds the entry (the handle value changed — unlike a mutable-in-place backend). A call through
/// the returned `st` sees the fill; a call through the PRE-init `st` still traps null (the old
/// immutable handle is unchanged).
pub fn threaded_init_elem_rebuilds_handle_test() {
  let st0 = threaded_table(2)
  let assert Ok(st1) = rt_table.t_init_elem(st0, 0, [#(ii_i(), t_add())])
  rt_table.t_call_indirect(st1, 0, ii_i(), [6, 1])
  |> should.equal(Ok(#([7], st1)))
  // The pre-init immutable handle is unaffected (structural-sharing snapshot).
  rt_table.t_call_indirect(st0, 0, ii_i(), [6, 1])
  |> should.equal(Error(UninitializedElement))
}

/// The three faults, right reason & ORDER, through the threaded heads.
pub fn threaded_three_faults_test() {
  let st = threaded_table(3)
  let assert Ok(st) = rt_table.t_init_elem(st, 0, [#(ii_i(), t_add())])
  // Bounds (before null/type).
  rt_table.t_call_indirect(st, 3, ii_i(), [1, 2])
  |> should.equal(Error(UndefinedElement))
  rt_table.t_call_indirect(st, -1, ii_i(), [1, 2])
  |> should.equal(Error(UndefinedElement))
  // Null (before type).
  rt_table.t_call_indirect(st, 1, FuncType([TI64], [TI64]), [1, 2])
  |> should.equal(Error(UninitializedElement))
  // Type.
  rt_table.t_call_indirect(st, 0, FuncType([TI32], [TI32]), [1])
  |> should.equal(Error(IndirectCallTypeMismatch))
}

/// `t_init_elem` whole-range bounds: an overflowing segment writes nothing (no partial write).
pub fn threaded_init_elem_out_of_bounds_writes_nothing_test() {
  let st = threaded_table(2)
  rt_table.t_init_elem(st, 2, [#(ii_i(), t_add())])
  |> should.equal(Error(TableOutOfBounds))
  rt_table.t_call_indirect(st, 0, ii_i(), [1, 2])
  |> should.equal(Error(UninitializedElement))
}

/// A threaded target that MUTATES a global proves `t_call_indirect` returns the callee's `st'`.
pub fn threaded_call_returns_callee_state_test() {
  let st =
    rt_state.fresh(StateDecl(
      mem: dynamic.nil(),
      globals: [#("g", 0)],
      table: rt_table.new(1, option.None),
    ))
  let bump = fn(st: InstanceState, args: List(Int)) {
    case args {
      [x] -> #(to_pkg(x), rt_state.t_global_set(st, "g", x))
      _ -> panic as "one arg"
    }
  }
  let assert Ok(st) =
    rt_table.t_init_elem(st, 0, [#(FuncType([TI32], [TI32]), bump)])
  let assert Ok(#([9], st2)) =
    rt_table.t_call_indirect(st, 0, FuncType([TI32], [TI32]), [9])
  rt_state.t_global_get(st2, "g") |> should.equal(9)
}

/// `to_canon` on the paged ORACLE reports null vs filled slots with the filled slot's type.
pub fn paged_to_canon_reports_slot_image_test() {
  let st = threaded_table(3)
  let assert Ok(st) = rt_table.t_init_elem(st, 1, [#(ii_i(), t_add())])
  rt_table.to_canon(rt_state.table(st))
  |> should.equal([option.None, option.Some(ii_i()), option.None])
}
