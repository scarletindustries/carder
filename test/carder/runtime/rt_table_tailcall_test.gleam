//// Q13-05 — spec-grounded tests for the `rt_table` constant-stack TAIL-CALL seam: the additive
//// `call_indirect_lookup*` functions, the package-ABI ⇄ result-list bridge (`package_to_list`),
//// and the non-tail `call_indirect*` package→list re-wrap (the funcref result-identity guard).
////
//// Assertions target the WebAssembly spec + the Phase-13 ABI reconciliation note, NOT emitted
//// text:
//// - **`call_indirect_lookup` runs the SAME three ordered fail-closed guards as `call_indirect`**
////   (`UndefinedElement` → `UninitializedElement` → `IndirectCallTypeMismatch`), but RETURNS the
////   target instead of applying it (<https://webassembly.github.io/spec/core/exec/instructions.html>).
//// - **The looked-up target is PACKAGE-ABI**: applied over an args LIST it yields the callee's
////   `function_return` package DIRECTLY — the BARE value for one result (NOT `[v]`), a tuple for
////   `N≥2`, a dummy for zero — so `emit_core` can tail-apply it into the caller's package in
////   constant stack.
//// - **The non-tail `call_indirect` re-wrap is FAITHFUL**: `call_indirect(i, ty, args)` returns the
////   SAME result LIST it did in Phase 12 (funcref result-identity), i.e. equals
////   `package_to_list(call_indirect_lookup(i, ty)(args), arity(ty))`.

import carder/ir.{
  type FuncType, FuncType, IndirectCallTypeMismatch, TI32, TI64,
  UndefinedElement, UninitializedElement,
}
import carder/runtime/rt_state.{type InstanceState, StateDecl}
import carder/runtime/rt_table
import gleam/dynamic.{type Dynamic}
import gleam/option
import gleeunit/should

// ── package / dynamic helpers (all identity or classic BIFs at run time) ──────────

/// Box a value as the `function_return` package `Dynamic` a funcref closure returns.
@external(erlang, "gleam_stdlib", "identity")
fn to_pkg(v: a) -> Dynamic

/// Recover the raw-bit `Int` inside a one-result package. Identity at run time.
@external(erlang, "gleam_stdlib", "identity")
fn dyn_to_int(v: Dynamic) -> Int

/// `erlang:is_integer/1` — True iff the package is the BARE value (one result), not a list.
@external(erlang, "erlang", "is_integer")
fn is_integer(v: Dynamic) -> Bool

/// `erlang:is_list/1` — used to PROVE the target does not return the list-ABI `[v]`.
@external(erlang, "erlang", "is_list")
fn is_list(v: Dynamic) -> Bool

/// `erlang:is_tuple/1` — True iff the package is the multi-result tuple `{v1,…,vn}`.
@external(erlang, "erlang", "is_tuple")
fn is_tuple(v: Dynamic) -> Bool

// ── test fixtures ─────────────────────────────────────────────────────────────────

fn seed_table(size: Int) -> Nil {
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [],
    table: rt_table.new(size, option.None),
  ))
}

fn threaded_table(size: Int) -> InstanceState {
  rt_state.fresh(StateDecl(
    mem: dynamic.nil(),
    globals: [],
    table: rt_table.new(size, option.None),
  ))
}

/// The structural type of a binary i32 operator `(i32, i32) -> i32`.
fn ii_i() -> FuncType {
  FuncType([TI32, TI32], [TI32])
}

/// A one-result cell funcref closure: `(a, b) -> a + b`, returning the BARE package value.
fn add_pkg() -> fn(List(Int)) -> Dynamic {
  fn(args) {
    case args {
      [a, b] -> to_pkg(a + b)
      _ -> panic as "add_pkg"
    }
  }
}

// ══════════════════════════ package-shape guard (§5.6a / §6b) ══════════════════════════

/// The `call_indirect_lookup` target of a ONE-result function yields the BARE value `v` when
/// applied to an args list — the `function_return` package, NOT the list-ABI `[v]`. This is the
/// exact package-shape assertion that a list-ABI target would fail.
pub fn lookup_target_is_bare_value_for_one_result_test() {
  seed_table(4)
  let assert Ok(Nil) = rt_table.init_elem(0, [#(ii_i(), add_pkg())])

  let assert Ok(target) = rt_table.call_indirect_lookup(0, ii_i())
  let package = target([3, 4])
  // The package is the bare value 7, an integer — NOT the list `[7]`.
  should.be_true(is_integer(package))
  should.be_false(is_list(package))
  dyn_to_int(package) |> should.equal(7)
}

/// The target of a ZERO-result function yields a dummy package (the runtime discards it); the
/// non-tail `call_indirect` re-wrap turns it into the empty list `[]` (result arity 0).
pub fn lookup_target_zero_result_rewraps_to_empty_test() {
  seed_table(2)
  let nullary = FuncType([], [])
  let assert Ok(Nil) =
    rt_table.init_elem(0, [#(nullary, fn(_args) { to_pkg(dynamic.nil()) })])

  // The re-wrap yields `[]` for a 0-result callee (byte-identical to Phase 12).
  rt_table.call_indirect(0, nullary, []) |> should.equal(Ok([]))
}

/// The target of a MULTI-result function yields a TUPLE `{v1,…,vn}` (NOT a list); the non-tail
/// re-wrap explodes it back into the result list `[v1,…,vn]` (result arity ≥ 2).
pub fn lookup_target_is_tuple_for_multi_result_test() {
  seed_table(2)
  let pair = FuncType([TI32], [TI32, TI32])
  let closure = fn(args: List(Int)) -> Dynamic {
    case args {
      [x] -> to_pkg(#(x, x + 1))
      _ -> panic as "pair"
    }
  }
  let assert Ok(Nil) = rt_table.init_elem(0, [#(pair, closure)])

  let assert Ok(target) = rt_table.call_indirect_lookup(0, pair)
  let package = target([10])
  // The package is the tuple `{10, 11}` — NOT a list.
  should.be_true(is_tuple(package))
  should.be_false(is_list(package))
  // The non-tail re-wrap turns it back into the result list.
  rt_table.call_indirect(0, pair, [10]) |> should.equal(Ok([10, 11]))
}

/// The THREADED lookup target yields `#(package, st')` when applied to `(st, args)` — the
/// threaded return shape (the `st` is threaded read-only, so it comes back unchanged here).
pub fn t_lookup_target_returns_package_and_state_test() {
  let st = threaded_table(4)
  let t_closure = fn(s: InstanceState, args: List(Int)) -> #(
    Dynamic,
    InstanceState,
  ) {
    case args {
      [a, b] -> #(to_pkg(a + b), s)
      _ -> panic as "t_add_pkg"
    }
  }
  let assert Ok(st) = rt_table.t_init_elem(st, 0, [#(ii_i(), t_closure)])

  let assert Ok(target) = rt_table.t_call_indirect_lookup(st, 0, ii_i())
  let #(package, _st2) = target(st, [3, 4])
  should.be_true(is_integer(package))
  should.be_false(is_list(package))
  dyn_to_int(package) |> should.equal(7)
}

// ══════════════════════ funcref result-identity — the re-wrap is faithful (§5.6c) ══════════════════════

/// `call_indirect(i, ty, args)` equals `package_to_list(call_indirect_lookup(i, ty)(args),
/// arity(ty))` — the observable proof that the non-tail path re-wraps the package-ABI target
/// faithfully, so funcref-bearing modules are result-identical despite the internal ABI change.
pub fn call_indirect_equals_rewrap_of_lookup_test() {
  seed_table(4)
  let assert Ok(Nil) = rt_table.init_elem(0, [#(ii_i(), add_pkg())])

  let assert Ok(target) = rt_table.call_indirect_lookup(0, ii_i())
  let rewrapped = rt_table.package_to_list(target([6, 1]), 1)
  rewrapped |> should.equal([7])
  // The ordinary dispatch returns the identical result LIST (unchanged from Phase 12).
  rt_table.call_indirect(0, ii_i(), [6, 1]) |> should.equal(Ok([7]))
  rt_table.call_indirect(0, ii_i(), [6, 1]) |> should.equal(Ok(rewrapped))
}

/// `package_to_list` inverts `function_return` for every arity: 0 → `[]`, 1 → `[v]`,
/// N≥2 → `[v1,…,vn]` (from the tuple).
pub fn package_to_list_shapes_test() {
  rt_table.package_to_list(to_pkg(dynamic.nil()), 0) |> should.equal([])
  rt_table.package_to_list(to_pkg(7), 1) |> should.equal([7])
  rt_table.package_to_list(to_pkg(#(1, 2)), 2) |> should.equal([1, 2])
  rt_table.package_to_list(to_pkg(#(1, 2, 3)), 3) |> should.equal([1, 2, 3])
}

// ══════════════════════ fail-closed guards, in order (§5.11–14, adversarial) ══════════════════════

/// Guard 1 — an out-of-bounds index (≥ size, or negative) traps `UndefinedElement`, and the lookup
/// seam produces the SAME trap as `call_indirect` (dispatch-path trap-equivalence).
pub fn lookup_out_of_bounds_is_undefined_element_test() {
  seed_table(3)
  let assert Ok(Nil) = rt_table.init_elem(0, [#(ii_i(), add_pkg())])

  rt_table.call_indirect_lookup(3, ii_i())
  |> should.equal(Error(UndefinedElement))
  rt_table.call_indirect_lookup(-1, ii_i())
  |> should.equal(Error(UndefinedElement))
  // Same trap as the non-tail dispatch on the identical table + index.
  rt_table.call_indirect_lookup(3, ii_i())
  |> lookup_trap
  |> should.equal(call_indirect_trap(rt_table.call_indirect(3, ii_i(), [1, 2])))
}

/// Guard 2 — an in-range but never-filled (null) slot traps `UninitializedElement`.
pub fn lookup_null_slot_is_uninitialized_element_test() {
  seed_table(3)
  // Fill slot 0 only; slots 1 and 2 stay null.
  let assert Ok(Nil) = rt_table.init_elem(0, [#(ii_i(), add_pkg())])

  rt_table.call_indirect_lookup(1, ii_i())
  |> should.equal(Error(UninitializedElement))
}

/// Guard 3 — an in-range, non-null slot whose stored `FuncType` differs from the call site's traps
/// `IndirectCallTypeMismatch` (exact structural type check).
pub fn lookup_type_mismatch_is_indirect_call_type_mismatch_test() {
  seed_table(3)
  let assert Ok(Nil) = rt_table.init_elem(0, [#(ii_i(), add_pkg())])

  rt_table.call_indirect_lookup(0, FuncType([TI64], [TI64]))
  |> should.equal(Error(IndirectCallTypeMismatch))
}

/// Guard ORDER preserved — an OOB index into a table whose slot 0 would ALSO type-mismatch: the
/// BOUNDS trap wins (guard 1 before guard 3), and the seam is trap-equivalent to `call_indirect` on
/// the identical table + index (differential, not a hard-coded string).
pub fn lookup_guard_order_bounds_before_type_test() {
  seed_table(1)
  let assert Ok(Nil) = rt_table.init_elem(0, [#(ii_i(), add_pkg())])

  // Index 5 is OOB (size 1) AND the call site type `[i64]->[i64]` mismatches slot 0's `[i32,i32]`
  // → bounds fires first.
  let wrong = FuncType([TI64], [TI64])
  rt_table.call_indirect_lookup(5, wrong)
  |> should.equal(Error(UndefinedElement))
  // Trap-equivalent to the non-tail dispatch (proves the tail seam does not reorder the guards).
  rt_table.call_indirect_lookup(5, wrong)
  |> lookup_trap
  |> should.equal(call_indirect_trap(rt_table.call_indirect(5, wrong, [1, 2])))
}

/// The seam raises no NEW trap reason (Q8): every guard outcome is one of the existing three.
/// "Call stack exhausted" is not a WASM trap and never surfaces (that is the whole point of a real
/// tail call).
pub fn lookup_uses_no_new_trap_reason_test() {
  seed_table(1)
  // Null slot 0 in a size-1 table: the only three reasons ever produced.
  let assert Error(reason) = rt_table.call_indirect_lookup(0, ii_i())
  case reason {
    UndefinedElement | UninitializedElement | IndirectCallTypeMismatch -> Nil
    _ ->
      panic as "call_indirect_lookup produced a trap reason outside the frozen three"
  }
}

// ── differential helpers: reduce both dispatch paths to their trap reason ──────────

fn lookup_trap(r: Result(a, ir.TrapReason)) -> option.Option(ir.TrapReason) {
  case r {
    Ok(_) -> option.None
    Error(reason) -> option.Some(reason)
  }
}

fn call_indirect_trap(
  r: Result(List(Int), ir.TrapReason),
) -> option.Option(ir.TrapReason) {
  case r {
    Ok(_) -> option.None
    Error(reason) -> option.Some(reason)
  }
}
