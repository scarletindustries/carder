//// `rt_table_ets` — the tier-O, closure-native funcref-table backend (owner: unit P4-06).
//// A **private, process-local ETS table** mapping slot-index → `#(FuncType, closure)`,
//// behind the frozen uniform `rt_table` interface (keystone §B.2). A pure module swap the
//// linker (unit 07) resolves for `table_tier: TableEts`; nothing about the generated code or
//// the `call_indirect` seam changes (G5/G7).
////
//// **The 3-fault fail-closed dispatch is byte-identical to `TablePaged`** (§F, unchanged from
//// P2-05, <https://webassembly.github.io/spec/core/exec/instructions.html>): the three guards
//// fire in spec order and return the three distinct `TrapReason`s —
//// 1. `index` in `[0, size)` — else `UndefinedElement`;
//// 2. slot filled (an ETS entry present) — else `UninitializedElement`;
//// 3. exact STRUCTURAL `FuncType` match — else `IndirectCallTypeMismatch`.
//// The order is observable: an OOB index traps `UndefinedElement` BEFORE any null/type check;
//// a null in-range slot traps `UninitializedElement` BEFORE any type comparison.
////
//// **No ambient authority (D3a).** The dispatched target is ALWAYS a build-controlled closure
//// supplied by the generated `instantiate` via `init_elem`/`t_init_elem` (`emit_core` captures
//// a compile-time-literal `'carder@wasm@<mod>':'f<idx>'/arity` inside it). ETS stores the
//// closure term natively; dispatch invokes it DIRECTLY as `target(args)` (a fun application).
//// This module constructs NO module/function atom from its inputs and calls NO `erlang:apply/3`
//// on data-derived names — the ONLY runtime-data input reaching a control transfer is the
//// integer `index`.
////
//// **Process-local; tier-O never NIF (G6/G8).** The ETS table is `private` (a second process
//// cannot read it) and UNNAMED (no node-global name to collide), owned by the instance process
//// under the one-instance-one-process contract (E1). It is process-local mutable storage, never
//// shared memory. ETS is OTP-native/memory-safe; there is no `nif` table tier, so Safe permits
//// it. A `private` ETS table is not GC'd while the process lives, so `new` deletes the prior
//// table this process owns before creating a fresh one (the §C re-instantiation lifecycle).
////
//// **Fail-closed on an un-seeded cell (E3).** The cell-backed ops read the handle via
//// `rt_state.table_get`, which raises (a node-safe internal error) on an un-seeded cell rather
//// than fabricating an empty table that silently "succeeds"; the threaded ops require the
//// handle present in `st.table`.
////
//// **Both op families.** The **cell-backed** family (`new`/`init_elem`/`call_indirect`, reached
//// through the pdict cell) and the **threaded** family (`t_init_elem`/`t_call_indirect`, over
//// an `InstanceState`) both compose with this tier (§C — tier and state-strategy are
//// orthogonal). Because ETS is mutated IN PLACE, a threaded op returns the SAME `st` (the `tid`
//// is unchanged; nothing to re-inject) — the §10 uniform-threading rule.

import carder/ir.{
  type FuncType, type TrapReason, IndirectCallTypeMismatch, TableOutOfBounds,
  UndefinedElement, UninitializedElement,
}
import carder/runtime/rt_meter
import carder/runtime/rt_ref
import carder/runtime/rt_state.{type InstanceState}
import carder/runtime/rt_table.{
  type RefValue, effective_max, package_to_list, result_arity,
}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}

/// The ETS-backed typed reference-table handle (opaque; carried as `Dynamic` in a `tables`-vector
/// slot). Phase-5 generalises the funcref store to a typed REFERENCE store (§A).
///
/// - `tid`: the PRIVATE, unnamed `set` ETS table owned by the instance process, keyed
///   `slot_index -> RefValue` (ETS stores the reference term natively — a funcref
///   `#(FuncType, closure)` or an externref `{ref_extern, term}`). A stable reference: a mutating
///   op writes THROUGH it in place. **Null is ABSENCE** — a slot set to null is DELETED, so
///   `call_indirect`'s absent-key guard stays byte-identical.
/// - `size`: the current slot count (`table.size`). Grows via `grow` (a new handle with the new
///   size; the `tid` is stable in place).
/// - `max`: the EFFECTIVE maximum entry count (`min(declared_max, hard_max_slots)`), baked at
///   `new` time; `grow` never exceeds it.
type EtsTable {
  EtsTable(tid: Dynamic, size: Int, max: Int)
}

// ───────────────────────────── the `ets` FFI (carder_-namespaced shim) ─────────────────────────────

/// Create a fresh PRIVATE `set` ETS table owned by this process, first deleting any prior table
/// this process created (§C lifecycle — no leak on re-instantiation). Returns the opaque `tid`.
@external(erlang, "carder_rt_table_ets_ffi", "new")
fn ets_new() -> Dynamic

/// Insert the opaque type-tagged `entry` at slot `key`, mutating the table IN PLACE (a `set`
/// upsert). `entry` is the `#(FuncType, closure)` term, boxed as `Dynamic` (both closure ABIs
/// coerce to the same stored shape). Returns `Nil`.
@external(erlang, "carder_rt_table_ets_ffi", "insert")
fn ets_insert(tid: Dynamic, key: Int, entry: Dynamic) -> Nil

/// Read slot `key`: `Ok(entry)` (the stored `RefValue` term as an opaque `Dynamic`) when the
/// slot is filled, or `Error(Nil)` when it is null/absent (the guard-2 signal).
@external(erlang, "carder_rt_table_ets_ffi", "lookup")
fn ets_lookup(tid: Dynamic, key: Int) -> Result(Dynamic, Nil)

/// Delete slot `key` IN PLACE (a no-op if absent). Represents a null reference write (a null slot
/// is an ABSENT key), keeping the `call_indirect` guard byte-identical.
@external(erlang, "carder_rt_table_ets_ffi", "delete")
fn ets_delete(tid: Dynamic, key: Int) -> Nil

// ───────────────────────────── opaque `Dynamic` coercions (identity at run time) ─────────────────────────────

/// Coerce an `EtsTable` handle into the opaque `Dynamic` the cell / threaded record stores.
/// Identity at run time (`gleam_stdlib:identity/1`); tier-O, cannot fail.
@external(erlang, "gleam_stdlib", "identity")
fn ets_to_dynamic(t: EtsTable) -> Dynamic

/// Coerce the cell / record's opaque `Dynamic` back into an `EtsTable`. Identity at run time;
/// sound because `rt_table_ets` is the sole producer of the term held in the `table` slot.
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_ets(value: Dynamic) -> EtsTable

/// Box a CELL-family entry (`#(FuncType, fn(List(Int)) -> Dynamic)`) as the opaque `Dynamic`
/// ETS stores. Identity at run time; the cell family is the sole reader of what it inserts.
/// PACKAGE-ABI (Phase-13): the closure returns the callee's `function_return` package (see
/// `rt_table.package_to_list`).
@external(erlang, "gleam_stdlib", "identity")
fn cell_entry_to_dynamic(e: #(FuncType, fn(List(Int)) -> Dynamic)) -> Dynamic

/// Unbox a stored entry back to the CELL-family shape. Identity at run time; sound because a
/// cell-inserted entry is only ever read by the cell family. Package-ABI (see above).
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_cell_entry(d: Dynamic) -> #(FuncType, fn(List(Int)) -> Dynamic)

/// Box a THREADED-family entry as the opaque `Dynamic` ETS stores. Identity at run time; the
/// threaded family is the sole reader of what it inserts. Package-ABI (Phase-13): the closure
/// returns `#(package, st')`.
@external(erlang, "gleam_stdlib", "identity")
fn threaded_entry_to_dynamic(
  e: #(FuncType, fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState)),
) -> Dynamic

/// Unbox a stored entry back to the THREADED-family shape. Identity at run time; sound because a
/// threaded-inserted entry is only ever read by the threaded family. Package-ABI (see above).
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_threaded_entry(
  d: Dynamic,
) -> #(FuncType, fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState))

/// Read just a stored entry's `FuncType` tag (for `to_canon`), leaving the closure opaque.
/// Identity at run time; sound for any family (the type tag is element 0 regardless of ABI).
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_type_entry(d: Dynamic) -> #(FuncType, Dynamic)

// ───────────────────────────── construction (both strategies) ─────────────────────────────

/// Build a FRESH ETS-backed table of `min` null (uninitialised) slots, returned as the opaque
/// `Dynamic` the cell / threaded record stores.
///
/// - `min`: the table's initial entry count (the declared minimum). Becomes the fixed `size`;
///   the ETS table starts empty, so a `call_indirect` to any in-range slot before an element
///   segment fills it traps `UninitializedElement`.
/// - `max`: optional maximum entry count. UNUSED in the MVP — funcref tables cannot grow
///   (`table.grow` is a post-MVP reference-types op) and are only ever filled via `init_elem`.
/// - `max`: the declared maximum entry count, or `None` for unbounded. The EFFECTIVE cap baked
///   into the handle is `min(declared_max, hard_max_slots)`; `grow` enforces it.
/// - Returns the fresh handle. Side effect: creates a PRIVATE ETS table and (§C lifecycle)
///   deletes any prior one this process created, so re-instantiation never leaks. Total.
pub fn new(min: Int, max: Option(Int)) -> Dynamic {
  ets_to_dynamic(EtsTable(tid: ets_new(), size: min, max: effective_max(max)))
}

// ───────────────────────────── cell-backed family (state_strategy: Cell) ─────────────────────────────

/// Write an active ELEMENT segment's `entries` into THIS process's cell table starting at
/// `offset`, at instantiation. Whole-range bounds-checked (all-or-nothing).
///
/// - `offset`: the first slot written; `entries[k]` goes into slot `offset + k`.
/// - `entries`: the type-tagged build-controlled closures — each `#(FuncType, closure)` pairs an
///   element function's IR signature with a closure over the generated function (invoked directly,
///   never `apply` of a data-derived name).
/// - Bounds check FIRST, before any write: if `offset < 0` or `offset + length(entries) > size`,
///   return `Error(TableOutOfBounds)` and write NOTHING (a slot the failed segment would have
///   filled still reads null). On success returns `Ok(Nil)`; the ETS table is mutated in place,
///   so NO `table_put` is needed (the `tid` is unchanged).
/// - Failure modes: `Error(TableOutOfBounds)`; raises (fail-closed, via `rt_state.table_get`) on
///   an un-seeded cell.
pub fn init_elem(
  offset: Int,
  entries: List(#(FuncType, fn(List(Int)) -> Dynamic)),
) -> Result(Nil, TrapReason) {
  let table = current_ets()
  case offset < 0 || offset + list.length(entries) > table.size {
    True -> Error(TableOutOfBounds)
    False -> {
      list.index_fold(entries, Nil, fn(_acc, entry, k) {
        ets_insert(table.tid, offset + k, cell_entry_to_dynamic(entry))
      })
      Ok(Nil)
    }
  }
}

/// Dispatch a `call_indirect` through THIS process's cell table — the 3-fault fail-closed
/// dispatch (§F). Reads the cell's `tid`, applies the three guards IN ORDER, and on success
/// invokes the slot's build-controlled `target` with `args` directly (`target(args)`).
///
/// - `index`: the table entry index to call (the only runtime-data input reaching a control
///   transfer).
/// - `expected_type`: the call site's statically-required `FuncType`. Guard 3 matches the stored
///   entry's type tag against this with exact STRUCTURAL equality (`==`).
/// - `args`: the call arguments as raw bit patterns.
/// - Returns `Ok(results)`, or an `Error(reason)` checked in this order: `UndefinedElement`
///   (guard 1, bounds); `UninitializedElement` (guard 2, null slot); `IndirectCallTypeMismatch`
///   (guard 3, type). Raises (fail-closed) on an un-seeded cell.
pub fn call_indirect(
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(List(Int), TrapReason) {
  let table = current_ets()
  // Guard 1 — bounds. Must fire before any null/type inspection.
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      // Guard 2 — null slot. An absent ETS entry is an uninitialised slot.
      case ets_lookup(table.tid, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(entry) -> {
          let #(entry_type, target) = dynamic_to_cell_entry(entry)
          // Guard 3 — exact structural FuncType match.
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            // Build-controlled invocation: invoke the STORED closure directly, then re-wrap its
            // package-ABI result into the frozen result list (Phase-13, see `rt_table`).
            True ->
              Ok(package_to_list(target(args), result_arity(expected_type)))
          }
        }
      }
  }
}

/// Dispatch a `call_indirect` through table `table_idx` — the INDEXED twin of `call_indirect`
/// (reference-types multi-table dispatch). Behaviourally identical to `call_indirect` for
/// `table_idx == 0`; reads table `table_idx` via `rt_state.table_at`, then applies the SAME
/// 3-fault fail-closed dispatch (bounds → null → exact `FuncType`) verbatim. No ambient `apply`
/// of a data-derived name (D3a). See `rt_table.call_indirect_at`.
pub fn call_indirect_at(
  table_idx: Int,
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(List(Int), TrapReason) {
  let table = dynamic_to_ets(rt_state.table_at(table_idx))
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case ets_lookup(table.tid, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(entry) -> {
          let #(entry_type, target) = dynamic_to_cell_entry(entry)
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            // Package-ABI re-wrap (Phase-13) — see `call_indirect`.
            True ->
              Ok(package_to_list(target(args), result_arity(expected_type)))
          }
        }
      }
  }
}

/// Read THIS process's current `EtsTable` out of the cell. Fail-closed: `rt_state.table_get`
/// `panic`s on an un-seeded cell (never returns garbage), which propagates here.
fn current_ets() -> EtsTable {
  dynamic_to_ets(rt_state.table_get())
}

// ───────────────────────────── threaded family (state_strategy: Threaded) ─────────────────────────────

/// Threaded `init_elem`: project `st.table`, whole-range bounds-check, insert each entry into the
/// ETS table IN PLACE, and return the record.
///
/// - `st`: the threaded instance-state record; its `table` slot holds this handle's `tid`.
/// - `offset`/`entries`: as `init_elem`, but the closures are threaded
///   (`fn(InstanceState, List(Int)) -> #(List(Int), InstanceState)`).
/// - Returns `Ok(st)` — the SAME `st` (the §10 rule for a mutable-in-place backend: ETS is
///   mutated through the stable `tid`, so there is nothing to re-inject) — or
///   `Error(TableOutOfBounds)` with NO write (all-or-nothing).
pub fn t_init_elem(
  st: InstanceState,
  offset: Int,
  entries: List(
    #(FuncType, fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState)),
  ),
) -> Result(InstanceState, TrapReason) {
  let table = project(st)
  case offset < 0 || offset + list.length(entries) > table.size {
    True -> Error(TableOutOfBounds)
    False -> {
      list.index_fold(entries, Nil, fn(_acc, entry, k) {
        ets_insert(table.tid, offset + k, threaded_entry_to_dynamic(entry))
      })
      Ok(st)
    }
  }
}

/// Threaded `call_indirect`: the 3-fault dispatch (§F) over `st.table`, invoking the target as
/// `target(st, args) -> #(results, st')`.
///
/// - `st`: the threaded instance-state record.
/// - `index`/`expected_type`/`args`: as `call_indirect`.
/// - Returns `Ok(#(results, st'))` where `st'` is whatever the invoked build-controlled closure
///   threaded (memory/global updates the callee made), or the three `Error(reason)`s in guard
///   order. The `tid` (the table slot) is unchanged — the MVP dispatch never mutates the table.
pub fn t_call_indirect(
  st: InstanceState,
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(#(List(Int), InstanceState), TrapReason) {
  let table = project(st)
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case ets_lookup(table.tid, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(entry) -> {
          let #(entry_type, target) = dynamic_to_threaded_entry(entry)
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            // Package-ABI re-wrap (Phase-13) — see `rt_table.t_call_indirect`.
            True -> {
              let #(pkg, st2) = target(st, args)
              Ok(#(package_to_list(pkg, result_arity(expected_type)), st2))
            }
          }
        }
      }
  }
}

/// Threaded `call_indirect` through table `table_idx` — the INDEXED twin of `t_call_indirect`
/// (multi-table dispatch over `st`'s `tables` vector). Behaviourally identical to
/// `t_call_indirect` for `table_idx == 0`; the 3-fault dispatch is VERBATIM the frozen twin. See
/// `rt_table.t_call_indirect_at`.
pub fn t_call_indirect_at(
  st: InstanceState,
  table_idx: Int,
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(#(List(Int), InstanceState), TrapReason) {
  let table = dynamic_to_ets(rt_state.t_table_at(st, table_idx))
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case ets_lookup(table.tid, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(entry) -> {
          let #(entry_type, target) = dynamic_to_threaded_entry(entry)
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            // Package-ABI re-wrap (Phase-13) — see `rt_table.t_call_indirect`.
            True -> {
              let #(pkg, st2) = target(st, args)
              Ok(#(package_to_list(pkg, result_arity(expected_type)), st2))
            }
          }
        }
      }
  }
}

/// Project THIS record's default `EtsTable` out of `st.table` (the field seam `rt_state.table`)
/// and coerce it. Read-only.
fn project(st: InstanceState) -> EtsTable {
  dynamic_to_ets(rt_state.table(st))
}

// ───────────────────────────── the constant-stack tail-call lookup seam (Phase-13) ─────────────────────────────

/// Look up (WITHOUT applying) the `call_indirect` target in THIS process's cell table, running the
/// 3 fail-closed guards IN ORDER and RETURNING the package-ABI target so `emit_core` can TAIL-APPLY
/// it (a real BEAM tail call). The ETS-tier twin of `rt_table.call_indirect_lookup` — same guards,
/// same order, same package-ABI contract.
pub fn call_indirect_lookup(
  index: Int,
  expected_type: FuncType,
) -> Result(fn(List(Int)) -> Dynamic, TrapReason) {
  lookup_cell(current_ets(), index, expected_type)
}

/// `call_indirect_lookup` through table `table_idx` — the multi-table twin. See
/// `rt_table.call_indirect_lookup_at`.
pub fn call_indirect_lookup_at(
  table_idx: Int,
  index: Int,
  expected_type: FuncType,
) -> Result(fn(List(Int)) -> Dynamic, TrapReason) {
  lookup_cell(
    dynamic_to_ets(rt_state.table_at(table_idx)),
    index,
    expected_type,
  )
}

/// Threaded `call_indirect_lookup` over `st`'s default table — returns the package-ABI THREADED
/// target. See `rt_table.t_call_indirect_lookup`.
pub fn t_call_indirect_lookup(
  st: InstanceState,
  index: Int,
  expected_type: FuncType,
) -> Result(
  fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState),
  TrapReason,
) {
  lookup_threaded(project(st), index, expected_type)
}

/// Threaded `call_indirect_lookup` through table `table_idx` — the indexed threaded twin. See
/// `rt_table.t_call_indirect_lookup_at`.
pub fn t_call_indirect_lookup_at(
  st: InstanceState,
  table_idx: Int,
  index: Int,
  expected_type: FuncType,
) -> Result(
  fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState),
  TrapReason,
) {
  lookup_threaded(
    dynamic_to_ets(rt_state.t_table_at(st, table_idx)),
    index,
    expected_type,
  )
}

/// The shared 3-fault fail-closed lookup over a resolved `EtsTable` (guard 1 bounds →
/// `UndefinedElement`; guard 2 present ETS key → `UninitializedElement`; guard 3 exact `FuncType`
/// → `IndirectCallTypeMismatch`, same order as `call_indirect`), returning the cell-ABI target
/// closure on success (never applying it).
fn lookup_cell(
  table: EtsTable,
  index: Int,
  expected_type: FuncType,
) -> Result(fn(List(Int)) -> Dynamic, TrapReason) {
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case ets_lookup(table.tid, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(entry) -> {
          let #(entry_type, target) = dynamic_to_cell_entry(entry)
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            True -> Ok(target)
          }
        }
      }
  }
}

/// The threaded twin of `lookup_cell` — same 3 guards, same order, returning the threaded target.
fn lookup_threaded(
  table: EtsTable,
  index: Int,
  expected_type: FuncType,
) -> Result(
  fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState),
  TrapReason,
) {
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case ets_lookup(table.tid, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(entry) -> {
          let #(entry_type, target) = dynamic_to_threaded_entry(entry)
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            True -> Ok(target)
          }
        }
      }
  }
}

// ───────────────────────────── cell-backed reference/bulk surface (§B) ─────────────────────────────
//
// The Phase-5 reference-types + bulk-table ops (state_strategy: Cell), reaching table `idx` via the
// R7 index-keyed `rt_state.table_at`/`with_table_at` accessors. ETS is mutated IN PLACE, so `set`/
// `fill`/`table_init`/`table_copy` need no write-back (the `tid` is stable); `grow` re-injects the
// handle because the `size` field changes. The op cores charge fuel (R9) identically to the
// threaded family (G7 parity).

/// `table.get idx` — the reference at `index`; absent ⇒ null sentinel; `Error(TableOutOfBounds)`
/// out of range. No mutation.
pub fn get(idx: Int, index: Int) -> Result(RefValue, TrapReason) {
  do_get(read_at(idx), index)
}

/// `table.set idx` — write `value` at `index` (eager bounds, no write on trap). Null ⇒ delete slot.
pub fn set(idx: Int, index: Int, value: RefValue) -> Result(Nil, TrapReason) {
  in_place(do_set(read_at(idx), index, value))
}

/// `table.size idx`.
pub fn size(idx: Int) -> Int {
  do_size(read_at(idx))
}

/// `table.grow idx` — append `delta` slots of `init`; the OLD size, or `-1` past `max`/cap
/// (unchanged, no fuel). Charges `delta` fuel on success (R9). Re-injects the resized handle.
pub fn grow(idx: Int, delta: Int, init: RefValue) -> Int {
  case do_grow(read_at(idx), delta, init) {
    #(-1, _) -> -1
    #(old, table) -> {
      rt_state.with_table_at(idx, ets_to_dynamic(table))
      old
    }
  }
}

/// `table.fill idx` — eager bounds (checked even for `count == 0`, R10), no partial writes; charges
/// `count` fuel on success (R9).
pub fn fill(
  idx: Int,
  offset: Int,
  value: RefValue,
  count: Int,
) -> Result(Nil, TrapReason) {
  in_place(do_fill(read_at(idx), offset, value, count))
}

/// `table.init idx` from segment `items` (R2) — eager double bounds, no partial writes; `count`
/// fuel on success (R9). A dropped segment arrives as `items = []`.
pub fn table_init(
  idx: Int,
  items: List(RefValue),
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  in_place(do_table_init(read_at(idx), items, dst, src, count))
}

/// `table.copy dst_idx src_idx` — memmove/overlap-correct (R11); eager bounds, no partial writes;
/// `count` fuel on success (R9).
pub fn table_copy(
  dst_idx: Int,
  src_idx: Int,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  in_place(do_table_copy(read_at(dst_idx), read_at(src_idx), dst, src, count))
}

/// Active reference-segment write into table `idx` at `offset` (no fuel; whole-range bounds).
pub fn init_elem_ref(
  idx: Int,
  offset: Int,
  refs: List(RefValue),
) -> Result(Nil, TrapReason) {
  in_place(do_init_elem_ref(read_at(idx), offset, refs))
}

/// Read table `idx`'s `EtsTable` from the cell. Fail-closed on an un-seeded cell (via `rt_state`).
fn read_at(idx: Int) -> EtsTable {
  dynamic_to_ets(rt_state.table_at(idx))
}

/// Map an in-place op's `Result(EtsTable, _)` to `Result(Nil, _)`: the ETS mutation already
/// happened in place (the `tid`/`size` are unchanged for these ops), so on `Ok` nothing is
/// re-injected; on `Error` the table was left untouched (no partial write).
fn in_place(result: Result(EtsTable, TrapReason)) -> Result(Nil, TrapReason) {
  case result {
    Ok(_table) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

// ───────────────────────────── threaded reference/bulk surface (§B) ─────────────────────────────
//
// The threaded twins reach table `idx` via `rt_state.t_table_at`/`t_with_table_at`. A mutating op
// mutates ETS in place and returns the record: the SAME `st` when the handle is unchanged (§10 —
// `set`/`fill`/`init`/`copy`), or a re-injected handle when `grow` changes the `size` field.

/// Threaded `table.get` (read-only). See `get`.
pub fn t_get(
  st: InstanceState,
  idx: Int,
  index: Int,
) -> Result(RefValue, TrapReason) {
  do_get(read_at_t(st, idx), index)
}

/// Threaded `table.set`: mutates ETS in place, returns the SAME `st` (§10). See `set`.
pub fn t_set(
  st: InstanceState,
  idx: Int,
  index: Int,
  value: RefValue,
) -> Result(InstanceState, TrapReason) {
  in_place_t(st, do_set(read_at_t(st, idx), index, value))
}

/// Threaded `table.size` (read-only). See `size`.
pub fn t_size(st: InstanceState, idx: Int) -> Int {
  do_size(read_at_t(st, idx))
}

/// Threaded `table.grow`: `#(old_or_-1, st')`; on success re-injects the resized handle and
/// charges `delta` fuel (parity with cell `grow`). See `grow`.
pub fn t_grow(
  st: InstanceState,
  idx: Int,
  delta: Int,
  init: RefValue,
) -> #(Int, InstanceState) {
  case do_grow(read_at_t(st, idx), delta, init) {
    #(-1, _) -> #(-1, st)
    #(old, table) -> #(
      old,
      rt_state.t_with_table_at(st, idx, ets_to_dynamic(table)),
    )
  }
}

/// Threaded `table.fill`: in place, returns the SAME `st`; `count` fuel on success. See `fill`.
pub fn t_fill(
  st: InstanceState,
  idx: Int,
  offset: Int,
  value: RefValue,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  in_place_t(st, do_fill(read_at_t(st, idx), offset, value, count))
}

/// Threaded `table.init` from segment `items` (R2): in place, same `st`; `count` fuel on success.
pub fn t_table_init(
  st: InstanceState,
  idx: Int,
  items: List(RefValue),
  dst: Int,
  src: Int,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  in_place_t(st, do_table_init(read_at_t(st, idx), items, dst, src, count))
}

/// Threaded `table.copy` (memmove, R11): in place, same `st`; `count` fuel on success.
pub fn t_table_copy(
  st: InstanceState,
  dst_idx: Int,
  src_idx: Int,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  in_place_t(
    st,
    do_table_copy(
      read_at_t(st, dst_idx),
      read_at_t(st, src_idx),
      dst,
      src,
      count,
    ),
  )
}

/// Threaded active reference-segment write (no fuel). See `init_elem_ref`.
pub fn t_init_elem_ref(
  st: InstanceState,
  idx: Int,
  offset: Int,
  refs: List(RefValue),
) -> Result(InstanceState, TrapReason) {
  in_place_t(st, do_init_elem_ref(read_at_t(st, idx), offset, refs))
}

/// Project table `idx`'s `EtsTable` out of the threaded record. Read-only.
fn read_at_t(st: InstanceState, idx: Int) -> EtsTable {
  dynamic_to_ets(rt_state.t_table_at(st, idx))
}

/// Map an in-place threaded op's result to `Result(InstanceState, _)`: the ETS mutation already
/// happened in place (the handle is unchanged), so on `Ok` the SAME `st` is returned (§10).
fn in_place_t(
  st: InstanceState,
  result: Result(EtsTable, TrapReason),
) -> Result(InstanceState, TrapReason) {
  case result {
    Ok(_table) -> Ok(st)
    Error(reason) -> Error(reason)
  }
}

// ───────────────────────────── the op cores (mutate ETS in place; §H) ─────────────────────────────
//
// One core per op, driven by BOTH families — so behaviour AND fuel are identical across state
// strategies. Cores mutate the ETS table IN PLACE (an effect through the stable `tid`) and return
// the (mostly unchanged) `EtsTable`; `grow` returns the resized handle. Reference values are
// OPAQUE (never invoked/inspected here); fuel (R9) is charged on the success path.

/// Pure-shaped `table.get`: bounds-check, else the slot's reference (absent ⇒ null sentinel).
fn do_get(t: EtsTable, index: Int) -> Result(RefValue, TrapReason) {
  case index < 0 || index >= t.size {
    True -> Error(TableOutOfBounds)
    False ->
      Ok(case ets_lookup(t.tid, index) {
        Ok(value) -> value
        Error(Nil) -> rt_ref.null_ref()
      })
  }
}

/// `table.set` core: bounds-check FIRST (no write on trap), else write the slot in place.
fn do_set(
  t: EtsTable,
  index: Int,
  value: RefValue,
) -> Result(EtsTable, TrapReason) {
  case index < 0 || index >= t.size {
    True -> Error(TableOutOfBounds)
    False -> {
      put_slot(t.tid, index, value)
      Ok(t)
    }
  }
}

/// `table.size` core.
fn do_size(t: EtsTable) -> Int {
  t.size
}

/// `table.grow` core: `#(old, resized)` on success (inserting `init`, charging `delta` fuel), or
/// `#(-1, t)` if `delta < 0` or `old + delta` exceeds the effective `max`.
fn do_grow(t: EtsTable, delta: Int, init: RefValue) -> #(Int, EtsTable) {
  let old = t.size
  let new = old + delta
  case delta >= 0 && new <= t.max {
    False -> #(-1, t)
    True -> {
      fill_run(t.tid, old, init, delta)
      rt_meter.charge(delta)
      #(old, EtsTable(..t, size: new))
    }
  }
}

/// `table.fill` core: eager bounds (checked even for `count == 0`, R10), no partial writes; else
/// fill in place, charging `count` fuel.
fn do_fill(
  t: EtsTable,
  offset: Int,
  value: RefValue,
  count: Int,
) -> Result(EtsTable, TrapReason) {
  case offset < 0 || count < 0 || offset + count > t.size {
    True -> Error(TableOutOfBounds)
    False -> {
      fill_run(t.tid, offset, value, count)
      rt_meter.charge(count)
      Ok(t)
    }
  }
}

/// `table.init` core from `items`: eager bounds against BOTH the segment length and the table
/// size, no partial writes; else write in place, charging `count` fuel.
fn do_table_init(
  t: EtsTable,
  items: List(RefValue),
  dst: Int,
  src: Int,
  count: Int,
) -> Result(EtsTable, TrapReason) {
  case
    dst < 0
    || src < 0
    || count < 0
    || dst + count > t.size
    || src + count > list.length(items)
  {
    True -> Error(TableOutOfBounds)
    False -> {
      write_run(t.tid, dst, list.take(list.drop(items, src), count))
      rt_meter.charge(count)
      Ok(t)
    }
  }
}

/// `table.copy` core (memmove, R11): eager bounds, no partial writes; SNAPSHOT the whole source
/// slice as a list BEFORE writing the destination (overlap-correct); charge `count` fuel.
fn do_table_copy(
  dst_t: EtsTable,
  src_t: EtsTable,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(EtsTable, TrapReason) {
  case
    dst < 0
    || src < 0
    || count < 0
    || dst + count > dst_t.size
    || src + count > src_t.size
  {
    True -> Error(TableOutOfBounds)
    False -> {
      let slice = snapshot(src_t, src, count)
      write_run(dst_t.tid, dst, slice)
      rt_meter.charge(count)
      Ok(dst_t)
    }
  }
}

/// Active reference-segment write core (no fuel): whole-range bounds, no partial writes.
fn do_init_elem_ref(
  t: EtsTable,
  offset: Int,
  refs: List(RefValue),
) -> Result(EtsTable, TrapReason) {
  case offset < 0 || offset + list.length(refs) > t.size {
    True -> Error(TableOutOfBounds)
    False -> {
      write_run(t.tid, offset, refs)
      Ok(t)
    }
  }
}

// ───────────────────────────── slot helpers ─────────────────────────────

/// Write `value` into slot `index` IN PLACE: a non-null reference is INSERTED; the null sentinel is
/// represented by ABSENCE, so a null write DELETES the slot (keeping `call_indirect` byte-identical).
fn put_slot(tid: Dynamic, index: Int, value: RefValue) -> Nil {
  case rt_ref.is_null(value) {
    True -> ets_delete(tid, index)
    False -> ets_insert(tid, index, value)
  }
}

/// Fill slots `[start, start + count)` all with `value`, in place.
fn fill_run(tid: Dynamic, start: Int, value: RefValue, count: Int) -> Nil {
  case count <= 0 {
    True -> Nil
    False -> {
      put_slot(tid, start, value)
      fill_run(tid, start + 1, value, count - 1)
    }
  }
}

/// Write `values` into consecutive slots from `start` (`values[k]` → slot `start + k`), in place.
fn write_run(tid: Dynamic, start: Int, values: List(RefValue)) -> Nil {
  list.index_fold(values, Nil, fn(_acc, value, k) {
    put_slot(tid, start + k, value)
  })
}

/// Snapshot source slots `[src, src + count)` into a list of reference values (read BEFORE any
/// destination write — the memmove guarantee).
fn snapshot(t: EtsTable, src: Int, count: Int) -> List(RefValue) {
  snapshot_loop(t, src, count, [])
}

fn snapshot_loop(
  t: EtsTable,
  at: Int,
  remaining: Int,
  acc: List(RefValue),
) -> List(RefValue) {
  case remaining <= 0 {
    True -> list.reverse(acc)
    False -> {
      let value = case ets_lookup(t.tid, at) {
        Ok(v) -> v
        Error(Nil) -> rt_ref.null_ref()
      }
      snapshot_loop(t, at + 1, remaining - 1, [value, ..acc])
    }
  }
}

// ───────────────────────────── differential canon hook (tests only, §F) ─────────────────────────────

/// The tier's whole slot image as a `size`-length list — the table analog of `rt_mem.to_flat`
/// (§B.2). `None` = a null slot, `Some(ty)` = a filled slot's structural `FuncType` tag.
/// Closures are not comparable, so behaviour is compared via `call_indirect`; this gives unit 09
/// a structural cross-tier equality it can assert without invoking. Tests only.
pub fn to_canon(handle: Dynamic) -> List(Option(FuncType)) {
  let table = dynamic_to_ets(handle)
  list.map(indices(table.size), fn(i) {
    case ets_lookup(table.tid, i) {
      Error(Nil) -> None
      Ok(value) ->
        case rt_ref.classify_ref(value) {
          rt_ref.FuncRef -> Some(dynamic_to_type_entry(value).0)
          _ -> None
        }
    }
  })
}

/// The ascending slot indices `[0, 1, …, size-1]` (`[]` for `size <= 0`). Built by hand so it
/// never depends on `list.range`'s descending-range edge behaviour. Private helper for `to_canon`.
fn indices(size: Int) -> List(Int) {
  build_indices(size - 1, [])
}

fn build_indices(i: Int, acc: List(Int)) -> List(Int) {
  case i < 0 {
    True -> acc
    False -> build_indices(i - 1, [i, ..acc])
  }
}
