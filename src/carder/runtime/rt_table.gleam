//// `rt_table` — the typed reference-table value + the 3-fault fail-closed `call_indirect`
//// dispatch (owner: unit 05; Phase-5 reference/bulk extension: unit P5-07).
////
//// **State location.** A table value lives in the index-keyed `tables` vector of THIS
//// process's cell (read via `rt_state.table_at(idx)` / the index-0 alias `table_get`, written
//// via `rt_state.with_table_at(idx, _)` / `table_put`); it is OPAQUE to `rt_state`. `rt_table`
//// owns its shape — the private `Table` record below — and coerces to/from the cell's `Dynamic`
//// via `gleam_stdlib:identity/1` (a tier-O no-op; `rt_table` is the sole producer/consumer of
//// this term, so the coercion is sound).
////
//// **Representation (Phase-5, §A).** A `Table` is `{size, max, slots}` where `slots` is a SPARSE
//// `Dict(Int, RefValue)` mapping a slot index to a **reference value**. A reference value is one
//// of the forge-proof `rt_ref` shapes (R1): a `funcref` `#(FuncType, closure)` (UNCHANGED from
//// Phase-2 — a funcref value *is* a table-entry shape, so `call_indirect` stays byte-identical),
//// an `externref` `{ref_extern, term}` (opaque host term), or the null sentinel `{ref_null}`.
//// **Null is represented by ABSENCE** (a missing key): `ref.null` is never stored as the sentinel
//// term — `set`/`fill`/`grow`/`init`/`copy` DELETE a slot written to null. So a slot present in
//// `[0, size)` is a real (funcref | externref) reference and an absent key reads as the null
//// sentinel. This keeps the Phase-2/4 `call_indirect` guard-2 ("absent key ⇒ `UninitializedElement`")
//// byte-identical: a funcref-only module never stores a non-funcref value, so its dispatch is
//// untouched (H7).
////
//// **`externref` opacity (H6).** `rt_table` stores `externref` values VERBATIM and never
//// constructs, forges, inspects, or reveals their host payload — it moves the opaque term between
//// slots and values. The only value comparison it makes is `rt_ref.is_null` (null detection) and,
//// for a funcref, `FuncType == expected_type` (guard 3); neither touches `externref` contents.
////
//// **No ambient authority (E3, D3a).** Dispatch goes through BUILD-CONTROLLED closures populated
//// from element segments / `ref.func` — NEVER a data-driven `apply(Module, Fun, Args)`. Each
//// funcref is TYPE-TAGGED `#(FuncType, closure)`; the ONLY runtime-data input reaching a control
//// transfer is the integer `index`, and the dispatched target is the stored closure, invoked
//// DIRECTLY as `target(args)` (a fun application). The new reference/bulk ops move reference
//// *values* between slots without ever turning runtime data into a module/function atom.
////
//// **Three guards, in order, each fail-closed**
//// (<https://webassembly.github.io/spec/core/exec/instructions.html>):
//// 1. `index` in `[0, size)` — else `UndefinedElement` ("undefined element");
//// 2. slot non-null (a present key) — else `UninitializedElement` ("uninitialized element");
//// 3. exact STRUCTURAL `FuncType` match against the call site's expected type — else
////    `IndirectCallTypeMismatch` ("indirect call type mismatch").
//// The order is observable: an OOB index traps `UndefinedElement` BEFORE any null/type check.
////
//// **Fail-closed on an un-seeded cell (E3 isolation).** The cell-backed ops read the cell via
//// `rt_state`, which raises (a node-safe internal error) on an un-seeded cell rather than
//// fabricating an empty table. Tier-O (immutable `Dict`), never NIF; `TablePaged` is the
//// differential ORACLE the mutable tiers (`TableEts`/`TableAtomics`) are held against.

import carder/ir.{
  type FuncType, type TrapReason, IndirectCallTypeMismatch, TableOutOfBounds,
  UndefinedElement, UninitializedElement,
}
import carder/runtime/rt_meter
import carder/runtime/rt_ref
import carder/runtime/rt_state.{type InstanceState}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// A WebAssembly reference value as the runtime moves it: the null sentinel `{ref_null}`, a
/// funcref `#(FuncType, closure)`, or an opaque externref `{ref_extern, term}` (R1). Held OPAQUE
/// as `Dynamic` — `rt_table` stores/returns reference values verbatim and only ever INTERPRETS
/// the funcref shape (for `call_indirect`) or tests null (via `rt_ref.is_null`). The value layer
/// is owned by the keystone module `rt_ref`; this alias names it locally.
pub type RefValue =
  Dynamic

/// The hard implementation cap on a table's entry count — the largest size `table.grow` may reach
/// (identical across all tiers so the differential agrees). The reference-types spec caps a table
/// at `2^32` elements; a Safe engine additionally bounds allocation, and `table.grow` fuel (R9)
/// bounds a metered module. A grow past `min(declared_max, hard_max_slots)` returns `-1` (never a
/// silent under-allocation, never a host escape).
pub const hard_max_slots: Int = 4_294_967_295

/// The immutable, sparse, typed reference table held (opaque, as `Dynamic`) in a `tables`-vector
/// slot of the cell.
///
/// - `size`: the number of slots (the current entry count; `table.size`). Grows via `grow`.
/// - `max`: the EFFECTIVE maximum entry count, baked at `new` time as `min(declared_max,
///   hard_max_slots)` — `grow` never exceeds it.
/// - `slots`: SPARSE map slot-index → `RefValue`. A PRESENT key in `[0, size)` is a real
///   (funcref | externref) reference; an ABSENT key is the null sentinel. Private: the value
///   never escapes `rt_table` except as the opaque `Dynamic` in the cell.
type Table {
  Table(size: Int, max: Int, slots: Dict(Int, RefValue))
}

/// Coerce a `Table` into the opaque `Dynamic` the cell stores. Identity at run time
/// (`gleam_stdlib:identity/1`); tier-O, cannot fail.
@external(erlang, "gleam_stdlib", "identity")
fn table_to_dynamic(table: Table) -> Dynamic

/// Coerce the cell's opaque `Dynamic` back into a `Table`. Identity at run time; sound because
/// `rt_table` is the sole producer of the term `rt_state` holds in a table slot.
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_table(value: Dynamic) -> Table

/// Coerce a cell-ABI funcref entry `#(FuncType, closure)` into a `RefValue`. Identity at run time;
/// a funcref value *is* a table-entry shape (R1), so this is a no-op box.
///
/// **Package-ABI (Phase-13).** The stored closure is now `fn(List(Int)) -> Dynamic`: applied over
/// an args LIST it returns the callee's `function_return` PACKAGE (bare `v` for one result, the
/// dummy `'ok'` for zero, a tuple for `N≥2`) — NOT a result list. This makes the closure
/// tail-transparent for `call_indirect_lookup` (a constant-stack tail apply); the non-tail
/// `call_indirect*` re-wraps the package back into the result list via `package_to_list`.
@external(erlang, "gleam_stdlib", "identity")
fn cell_funcref_to_ref(e: #(FuncType, fn(List(Int)) -> Dynamic)) -> RefValue

/// Coerce a `RefValue` back to a cell-ABI funcref entry. Identity at run time; sound only after a
/// `classify_ref`/absence check has established the value is a funcref (never a null/externref).
/// Package-ABI: the closure returns the callee's `function_return` package (see `cell_funcref_to_ref`).
@external(erlang, "gleam_stdlib", "identity")
fn ref_to_cell_funcref(v: RefValue) -> #(FuncType, fn(List(Int)) -> Dynamic)

/// Coerce a threaded-ABI funcref entry into a `RefValue`. Identity at run time. Package-ABI: the
/// closure is `fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState)`, returning the callee's
/// `{package, St'}` (see `cell_funcref_to_ref`).
@external(erlang, "gleam_stdlib", "identity")
fn threaded_funcref_to_ref(
  e: #(FuncType, fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState)),
) -> RefValue

/// Coerce a `RefValue` back to a threaded-ABI funcref entry. Identity at run time; sound after a
/// non-null/funcref check (the threaded family is the sole reader of a threaded-written slot).
/// Package-ABI: the closure returns `{package, St'}`.
@external(erlang, "gleam_stdlib", "identity")
fn ref_to_threaded_funcref(
  v: RefValue,
) -> #(FuncType, fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState))

/// Read just a funcref `RefValue`'s `FuncType` tag (element 0), leaving the closure opaque —
/// ABI-agnostic (the type tag is element 0 regardless of cell/threaded closure). For `to_canon`.
@external(erlang, "gleam_stdlib", "identity")
fn ref_func_type_entry(v: RefValue) -> #(FuncType, Dynamic)

// ───────────────────────────── construction + reference constructors ─────────────────────────────

/// Build a FRESH opaque table of `min` null (absent) slots.
///
/// - `min`: the table's initial entry count (the declared minimum); becomes the current `size`.
///   Every slot is initially absent (null), so a `call_indirect` to any in-range slot before an
///   element segment / `table.set` fills it traps `UninitializedElement`.
/// - `max`: the declared maximum entry count, or `None` for unbounded. The EFFECTIVE cap baked
///   into the table is `min(declared_max, hard_max_slots)`; `grow` enforces it.
/// - Returns the fresh table value as `Dynamic` (opaque, ready for `rt_state.seed`). Total.
pub fn new(min: Int, max: Option(Int)) -> Dynamic {
  table_to_dynamic(Table(size: min, max: effective_max(max), slots: dict.new()))
}

/// Construct a `funcref` reference value from a cell-ABI closure (R1) — `#(ty, closure)`. Used by
/// tests to build funcref operands (`emit_core` builds its funcref closures directly in Core).
///
/// - `ty`: the function's structural `FuncType` (guard 3 of `call_indirect` matches it).
/// - `closure`: the build-controlled `fn(List(Int)) -> Dynamic` over the referenced function. It
///   is PACKAGE-ABI (Phase-13): applied over the args LIST it returns the callee's
///   `function_return` package — the bare value for one result, the dummy `'ok'` for zero, a tuple
///   for `N≥2` — NOT a result list. The non-tail `call_indirect` re-wraps it via `package_to_list`.
/// - Returns the funcref `RefValue`. Total; never fails.
pub fn funcref(ty: FuncType, closure: fn(List(Int)) -> Dynamic) -> RefValue {
  cell_funcref_to_ref(#(ty, closure))
}

/// Construct a `funcref` reference value from a threaded-ABI closure (R1). The threaded twin of
/// `funcref`, for the `Threaded` state strategy.
///
/// - `ty`: the function's structural `FuncType`.
/// - `closure`: the threaded PACKAGE-ABI closure
///   `fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState)`, returning `{package, St'}`.
/// - Returns the funcref `RefValue`. Total.
pub fn funcref_t(
  ty: FuncType,
  closure: fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState),
) -> RefValue {
  threaded_funcref_to_ref(#(ty, closure))
}

// ───────────────────────────── legacy funcref surface (byte-identical, §A) ─────────────────────────────

/// Write an active ELEMENT segment's `entries` into THIS process's default table (index 0)
/// starting at `offset`, at instantiation. Whole-range bounds-checked (all-or-nothing).
///
/// UNCHANGED from Phase-2 (byte-identity, H7): funcref-funcidx active segments lower here.
///
/// - `offset`: the first entry index written; `entries[k]` goes into slot `offset + k`.
/// - `entries`: type-tagged build-controlled closures — each `#(FuncType, closure)` pairs an
///   element function's IR signature with a closure over the generated function.
/// - Bounds check FIRST: if `offset < 0` or `offset + length(entries) > size`, return
///   `Error(TableOutOfBounds)` writing NOTHING. On success returns `Ok(Nil)`.
/// - Failure modes: `Error(TableOutOfBounds)`; raises (fail-closed) on an un-seeded cell.
pub fn init_elem(
  offset: Int,
  entries: List(#(FuncType, fn(List(Int)) -> Dynamic)),
) -> Result(Nil, TrapReason) {
  let table = dynamic_to_table(rt_state.table_get())
  case offset < 0 || offset + list.length(entries) > table.size {
    True -> Error(TableOutOfBounds)
    False -> {
      let new_slots =
        list.index_fold(entries, table.slots, fn(slots, entry, k) {
          dict.insert(slots, offset + k, cell_funcref_to_ref(entry))
        })
      rt_state.table_put(table_to_dynamic(Table(..table, slots: new_slots)))
      Ok(Nil)
    }
  }
}

/// Dispatch a `call_indirect` through THIS process's default table (index 0) — the 3-fault
/// fail-closed dispatch. UNCHANGED behaviour from Phase-2 (§A).
///
/// - `index`/`expected_type`/`args`: the entry index, the call site's required `FuncType`
///   (exact STRUCTURAL `==`), and the raw-bit arguments.
/// - Returns `Ok(results)`, or an `Error(reason)` in guard order: `UndefinedElement` (bounds),
///   `UninitializedElement` (absent/null slot), `IndirectCallTypeMismatch` (type). Raises
///   (fail-closed) on an un-seeded cell.
pub fn call_indirect(
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(List(Int), TrapReason) {
  let table = dynamic_to_table(rt_state.table_get())
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case dict.get(table.slots, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(value) -> {
          let #(entry_type, target) = ref_to_cell_funcref(value)
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            // Package-ABI (Phase-13): `target` returns the callee's `function_return` package;
            // re-wrap it back into the result LIST (the frozen `call_indirect` contract) using the
            // guard-checked `FuncType`'s result arity, so the emitted seam stays observably identical.
            True ->
              Ok(package_to_list(target(args), result_arity(expected_type)))
          }
        }
      }
  }
}

/// Dispatch a `call_indirect` through table `table_idx` — the INDEXED twin of `call_indirect`
/// (reference-types multi-table dispatch, <https://webassembly.github.io/spec/core/exec/instructions.html>).
///
/// Behaviourally IDENTICAL to `call_indirect` for `table_idx == 0` (the default table), so a
/// funcref-only single-table module keeps emitting the un-indexed head (byte-identity, H7); a
/// module declaring MULTIPLE tables dispatches through the selected table here. The 3-fault
/// fail-closed dispatch is otherwise VERBATIM the frozen `call_indirect`: guard 1 `index` in
/// `[0, size)` else `UndefinedElement`; guard 2 slot non-null else `UninitializedElement`; guard 3
/// exact STRUCTURAL `FuncType` match else `IndirectCallTypeMismatch`. NO ambient `apply` of a
/// data-derived name (D3a) — the dispatched target is the build-controlled slot closure.
///
/// - `table_idx`: the absolute table index the dispatch reads (via `rt_state.table_at`).
/// - `index`/`expected_type`/`args`: the entry index, the call site's required `FuncType`, and the
///   raw-bit arguments — exactly as `call_indirect`.
/// - Returns `Ok(results)` or an `Error(reason)` in guard order. Raises (fail-closed) on an
///   un-seeded cell.
pub fn call_indirect_at(
  table_idx: Int,
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(List(Int), TrapReason) {
  let table = dynamic_to_table(rt_state.table_at(table_idx))
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case dict.get(table.slots, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(value) -> {
          let #(entry_type, target) = ref_to_cell_funcref(value)
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

// ───────────────────────────── the package-ABI ⇄ result-list bridge (Phase-13) ─────────────────────────────

/// Convert a callee's `function_return` PACKAGE back into the WebAssembly result value LIST — the
/// bridge between the Phase-13 package-ABI funcref closure and the frozen `call_indirect` list
/// contract (overview §2 ⚠ ABI reconciliation note).
///
/// After the funcref-construction ABI change, a stored funcref closure applied over an args LIST
/// returns the callee's `function_return` package: the dummy atom `'ok'` for `result_count == 0`,
/// the BARE value for `result_count == 1`, and an `N`-tuple `{v1,…,vn}` for `result_count >= 2`
/// (the shape `emit_core.function_return` produces). This inverts that packaging so the non-tail
/// `call_indirect*` family keeps returning the same result list it did in Phase 12 (its emitted
/// seam is observably identical). The tail path (`call_indirect_lookup*`) does NOT call this — it
/// tail-applies the package-ABI target directly, so the caller's package is returned in constant
/// stack space.
///
/// - `pkg`: the callee's package (opaque `Dynamic`; interpreted per `result_count` only).
/// - `result_count`: the guard-checked callee result arity (`result_arity(expected_type)`).
/// - Returns the `result_count`-length value list: `[]` for 0, `[v]` for 1,
///   `tuple_to_list(pkg)` for `N≥2`. Total; never fails for a well-formed package.
pub fn package_to_list(pkg: Dynamic, result_count: Int) -> List(Int) {
  case result_count {
    0 -> []
    1 -> [package_as_int(pkg)]
    _ -> package_tuple_to_list(pkg)
  }
}

/// Coerce a single-result `function_return` package (the bare value) into the raw-bit `Int` the
/// result list holds. Identity at run time (a WASM value is already the raw Erlang integer).
@external(erlang, "gleam_stdlib", "identity")
fn package_as_int(pkg: Dynamic) -> Int

/// Explode a multi-result `function_return` package (the `N`-tuple `{v1,…,vn}`) into its value
/// list `[v1,…,vn]`. `erlang:tuple_to_list/1`; sound because a `result_count >= 2` package is
/// exactly the `emit_core.function_return` tuple.
@external(erlang, "erlang", "tuple_to_list")
fn package_tuple_to_list(pkg: Dynamic) -> List(Int)

/// The callee RESULT ARITY carried by a `call_indirect` type argument — the count `package_to_list`
/// needs to invert the callee's package.
///
/// **Why this is not `list.length(ty.results)`.** The `call_indirect*` `expected_type` parameter is
/// declared `FuncType`, but it takes TWO different runtime shapes at this boundary: the emitted seam
/// passes the compile-time `func_type_term` TAG `{params, results}` (a bare 2-tuple), while a direct
/// Gleam caller (tests) passes a real `FuncType` record `{func_type, params, results}` (a 3-tuple).
/// Reading the record field `ty.results` (`element(3, …)`) is a `badarg` on the 2-tuple tag. In BOTH
/// shapes, however, the results list is the LAST tuple element — so its length is the arity whichever
/// shape arrived. Used only for the non-tail re-wrap (guard 3 has already equated both sides).
pub fn result_arity(ty: FuncType) -> Int {
  let term = func_type_to_dynamic(ty)
  erl_length(erl_element(erl_tuple_size(term), term))
}

/// Coerce a `FuncType` to its opaque runtime term (identity) so `result_arity` can read its last
/// tuple element regardless of whether it is a `func_type_term` tag or a `FuncType` record.
@external(erlang, "gleam_stdlib", "identity")
fn func_type_to_dynamic(ty: FuncType) -> Dynamic

/// `erlang:tuple_size/1` — the term's tuple arity.
@external(erlang, "erlang", "tuple_size")
fn erl_tuple_size(term: Dynamic) -> Int

/// `erlang:element/2` — the `n`-th (1-based) element of `term`.
@external(erlang, "erlang", "element")
fn erl_element(n: Int, term: Dynamic) -> Dynamic

/// `erlang:length/1` — the length of the (results) list.
@external(erlang, "erlang", "length")
fn erl_length(items: Dynamic) -> Int

/// Look up (WITHOUT applying) the `call_indirect` target in THIS process's default table (index 0),
/// running the 3 fail-closed guards IN ORDER, and RETURN the target so `emit_core` can TAIL-APPLY it
/// (a real BEAM tail call in constant stack). This is the tail-call twin of `call_indirect`.
///
/// After the funcref-ABI change the returned target is PACKAGE-ABI: applied over an args LIST it
/// yields the callee's `function_return` package DIRECTLY (bare `v` for one result, `'ok'` for zero,
/// a tuple for `N≥2`), so tail-applying it in the caller's tail position returns the caller's package
/// with NO unpack/re-wrap. D3a-clean: the returned closure is the build-controlled slot capability;
/// only the integer `index` is program-derived (never an `erlang:apply` of a data-named atom).
///
/// - `index`: the table entry index (the only runtime-data input).
/// - `expected_type`: the call site's required `FuncType` (guard 3, exact structural `==`).
/// - Returns `Ok(target)` — the package-ABI closure — or an `Error(reason)` in guard order:
///   `UndefinedElement` (bounds), `UninitializedElement` (absent/null slot),
///   `IndirectCallTypeMismatch` (type). Raises (fail-closed) on an un-seeded cell.
pub fn call_indirect_lookup(
  index: Int,
  expected_type: FuncType,
) -> Result(fn(List(Int)) -> Dynamic, TrapReason) {
  lookup_cell(dynamic_to_table(rt_state.table_get()), index, expected_type)
}

/// `call_indirect_lookup` through table `table_idx` — the multi-table twin (reads
/// `rt_state.table_at`). Behaviourally identical for `table_idx == 0`. See `call_indirect_lookup`.
pub fn call_indirect_lookup_at(
  table_idx: Int,
  index: Int,
  expected_type: FuncType,
) -> Result(fn(List(Int)) -> Dynamic, TrapReason) {
  lookup_cell(
    dynamic_to_table(rt_state.table_at(table_idx)),
    index,
    expected_type,
  )
}

/// Threaded `call_indirect_lookup` over `st`'s default table — returns the package-ABI THREADED
/// target `fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState)`, which tail-applied yields
/// `{package, St'}`. The table read is read-only, so the SAME `st` is threaded into the target
/// apply by `emit_core`. See `call_indirect_lookup`.
pub fn t_call_indirect_lookup(
  st: InstanceState,
  index: Int,
  expected_type: FuncType,
) -> Result(
  fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState),
  TrapReason,
) {
  lookup_threaded(dynamic_to_table(rt_state.table(st)), index, expected_type)
}

/// Threaded `call_indirect_lookup` through table `table_idx` — the indexed threaded twin. See
/// `t_call_indirect_lookup`.
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
    dynamic_to_table(rt_state.t_table_at(st, table_idx)),
    index,
    expected_type,
  )
}

/// The shared 3-fault fail-closed lookup over a resolved cell-ABI `Table`: guard 1 bounds
/// (`UndefinedElement`), guard 2 non-null (`UninitializedElement`), guard 3 exact `FuncType`
/// (`IndirectCallTypeMismatch`) — the SAME order as `call_indirect` — returning the target closure
/// on success (never applying it).
fn lookup_cell(
  table: Table,
  index: Int,
  expected_type: FuncType,
) -> Result(fn(List(Int)) -> Dynamic, TrapReason) {
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case dict.get(table.slots, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(value) -> {
          let #(entry_type, target) = ref_to_cell_funcref(value)
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
  table: Table,
  index: Int,
  expected_type: FuncType,
) -> Result(
  fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState),
  TrapReason,
) {
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case dict.get(table.slots, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(value) -> {
          let #(entry_type, target) = ref_to_threaded_funcref(value)
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
// The Phase-5 reference-types + bulk-table ops (state_strategy: Cell). Each reaches table `idx` via
// the R7 index-keyed `rt_state.table_at`/`with_table_at` accessors (index 0 = the default table),
// coerces the opaque handle to a `Table`, drives the SHARED op core (`do_*`), and re-injects the
// rebuilt handle. The op cores charge fuel (R9) on success, so the cell and threaded families are
// metering-identical by construction (the G7 parity bar).

/// `table.get idx` — read the reference value at `index`. Ok(ref) in range (a never-written /
/// grown-into slot reads as the null sentinel); `Error(TableOutOfBounds)` if `index < 0 || index
/// >= size` ("out of bounds table access"). No mutation. (exec/instructions.html — Table
/// Instructions; reference-types proposal.)
pub fn get(idx: Int, index: Int) -> Result(RefValue, TrapReason) {
  do_get(read_at(idx), index)
}

/// `table.set idx` — write reference `value` at `index`. Ok(Nil) in range (writes back the table);
/// `Error(TableOutOfBounds)` out of range with NO write (eager). `value = ref.null` stores the
/// null sentinel (represented as an absent slot).
pub fn set(idx: Int, index: Int, value: RefValue) -> Result(Nil, TrapReason) {
  commit(idx, do_set(read_at(idx), index, value))
}

/// `table.size idx` — the current slot count. Total; no trap.
pub fn size(idx: Int) -> Int {
  do_size(read_at(idx))
}

/// `table.grow idx` — append `delta` slots each initialised to `init`; return the OLD size on
/// success, or `-1` if `old + delta` exceeds the effective `max`/cap or `delta < 0` (the table is
/// UNCHANGED and NO fuel is charged). On success charges `delta` growth fuel (R9/§G). Never traps.
pub fn grow(idx: Int, delta: Int, init: RefValue) -> Int {
  case do_grow(read_at(idx), delta, init) {
    #(-1, _) -> -1
    #(old, table) -> {
      rt_state.with_table_at(idx, table_to_dynamic(table))
      old
    }
  }
}

/// `table.fill idx` — write `value` into `count` slots from `offset`. `Error(TableOutOfBounds)` if
/// `offset < 0` or `offset + count > size` (eager, evaluated even for `count == 0`, R10) with NO
/// partial writes; else Ok(Nil), charging `count` fuel (R9).
pub fn fill(
  idx: Int,
  offset: Int,
  value: RefValue,
  count: Int,
) -> Result(Nil, TrapReason) {
  commit(idx, do_fill(read_at(idx), offset, value, count))
}

/// `table.init idx` from element-segment items — copy `count` references from `items` (source
/// offset `src`) into table `idx` at `dst`. `items` is the segment's CURRENT element vector,
/// supplied by `emit_core` (ε when the segment is dropped, R2). Eager bounds against BOTH
/// `src + count > length(items)` and `dst + count > size` ⇒ `Error(TableOutOfBounds)` with NO
/// write; else Ok(Nil), charging `count` fuel (R9). (bulk-memory proposal; exec/instructions.html.)
pub fn table_init(
  idx: Int,
  items: List(RefValue),
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  commit(idx, do_table_init(read_at(idx), items, dst, src, count))
}

/// `table.copy dst_idx src_idx` — copy `count` references from table `src_idx` (offset `src`) to
/// table `dst_idx` (offset `dst`) with **memmove/overlap correctness** (R11). Eager bounds against
/// both ranges ⇒ `Error(TableOutOfBounds)` with NO write; else Ok(Nil), charging `count` fuel (R9).
pub fn table_copy(
  dst_idx: Int,
  src_idx: Int,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  commit(
    dst_idx,
    do_table_copy(read_at(dst_idx), read_at(src_idx), dst, src, count),
  )
}

/// Write an active reference-typed ELEMENT segment's `refs` into table `idx` at `offset`, at
/// instantiation (the generalisation of `init_elem` to arbitrary references — funcref | externref
/// | null — and any table index). All-or-nothing: `Error(TableOutOfBounds)` if `offset < 0` or
/// `offset + length(refs) > size`, no partial write. Charges NO fuel (an instantiation write,
/// parity with `init_elem`). `emit_core` uses this for expr/externref/null/non-zero-table active
/// segments; funcref-funcidx active segments keep the byte-identical `init_elem` fast path.
pub fn init_elem_ref(
  idx: Int,
  offset: Int,
  refs: List(RefValue),
) -> Result(Nil, TrapReason) {
  commit(idx, do_init_elem_ref(read_at(idx), offset, refs))
}

/// Read table `idx`'s handle from the cell and coerce it to a `Table`. Fail-closed on an un-seeded
/// cell (via `rt_state`).
fn read_at(idx: Int) -> Table {
  dynamic_to_table(rt_state.table_at(idx))
}

/// Commit a mutating op's `Result(Table, _)` back into table `idx` of the cell: on `Ok`, re-inject
/// the rebuilt handle and return `Ok(Nil)`; on `Error`, propagate (nothing was written).
fn commit(
  idx: Int,
  result: Result(Table, TrapReason),
) -> Result(Nil, TrapReason) {
  case result {
    Ok(table) -> {
      rt_state.with_table_at(idx, table_to_dynamic(table))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

// ───────────────────────────── the paged THREADED family (state_strategy: Threaded) ─────────────────────────────
//
// The purely-functional twin of the cell surface. The handle travels in the `tables` vector of the
// threaded `InstanceState` (projected via `rt_state.t_table_at`, re-injected via
// `rt_state.t_with_table_at`) instead of the pdict cell — the §10 uniform-threading rule. Every op
// drives the SAME `do_*` core the cell family uses (so cell ≡ threaded, including fuel), a mutating
// op re-injecting the rebuilt immutable handle.

/// Threaded `init_elem` (byte-identical to Phase-4): whole-range bounds-check, RETURN the record
/// with the rebuilt `Table`, or `Error(TableOutOfBounds)` writing nothing.
pub fn t_init_elem(
  st: InstanceState,
  offset: Int,
  entries: List(
    #(FuncType, fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState)),
  ),
) -> Result(InstanceState, TrapReason) {
  let table = dynamic_to_table(rt_state.table(st))
  case offset < 0 || offset + list.length(entries) > table.size {
    True -> Error(TableOutOfBounds)
    False -> {
      let new_slots =
        list.index_fold(entries, table.slots, fn(slots, entry, k) {
          dict.insert(slots, offset + k, threaded_funcref_to_ref(entry))
        })
      Ok(rt_state.with_table(
        st,
        table_to_dynamic(Table(..table, slots: new_slots)),
      ))
    }
  }
}

/// Threaded `call_indirect` (byte-identical to Phase-4): the 3-fault dispatch over `st`'s default
/// table, invoking the target as `target(st, args) -> #(results, st')`.
pub fn t_call_indirect(
  st: InstanceState,
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(#(List(Int), InstanceState), TrapReason) {
  let table = dynamic_to_table(rt_state.table(st))
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case dict.get(table.slots, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(value) -> {
          let #(entry_type, target) = ref_to_threaded_funcref(value)
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            // Package-ABI re-wrap (Phase-13): the threaded target returns `#(package, st')`;
            // re-wrap the package into the result list, keeping the frozen `#(List(Int), st')`
            // contract observably identical.
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
/// `t_call_indirect` for `table_idx == 0`; the 3-fault dispatch is VERBATIM the frozen twin,
/// invoking the target as `target(st, args) -> #(results, st')`. See `call_indirect_at`.
pub fn t_call_indirect_at(
  st: InstanceState,
  table_idx: Int,
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(#(List(Int), InstanceState), TrapReason) {
  let table = dynamic_to_table(rt_state.t_table_at(st, table_idx))
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case dict.get(table.slots, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(value) -> {
          let #(entry_type, target) = ref_to_threaded_funcref(value)
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            // Package-ABI re-wrap (Phase-13) — see `t_call_indirect`.
            True -> {
              let #(pkg, st2) = target(st, args)
              Ok(#(package_to_list(pkg, result_arity(expected_type)), st2))
            }
          }
        }
      }
  }
}

/// Threaded `table.get` (read-only): `st` unchanged. See `get`.
pub fn t_get(
  st: InstanceState,
  idx: Int,
  index: Int,
) -> Result(RefValue, TrapReason) {
  do_get(read_at_t(st, idx), index)
}

/// Threaded `table.set`: returns `Ok(st')` with the rebuilt handle (immutable backend, §10), or
/// `Error(TableOutOfBounds)` with `st` untouched. See `set`.
pub fn t_set(
  st: InstanceState,
  idx: Int,
  index: Int,
  value: RefValue,
) -> Result(InstanceState, TrapReason) {
  commit_t(st, idx, do_set(read_at_t(st, idx), index, value))
}

/// Threaded `table.size` (read-only). See `size`.
pub fn t_size(st: InstanceState, idx: Int) -> Int {
  do_size(read_at_t(st, idx))
}

/// Threaded `table.grow`: returns `#(old_size_or_-1, st')` — on success the rebuilt handle and
/// `delta` fuel charged (parity with cell `grow`), on failure `#(-1, st)` unchanged. See `grow`.
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
      rt_state.t_with_table_at(st, idx, table_to_dynamic(table)),
    )
  }
}

/// Threaded `table.fill`: eager bounds, no partial writes; `Ok(st')` charging `count` fuel, else
/// `Error(TableOutOfBounds)`. See `fill`.
pub fn t_fill(
  st: InstanceState,
  idx: Int,
  offset: Int,
  value: RefValue,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  commit_t(st, idx, do_fill(read_at_t(st, idx), offset, value, count))
}

/// Threaded `table.init` from segment `items` (R2): eager double bounds, no partial writes;
/// `Ok(st')` charging `count` fuel, else `Error(TableOutOfBounds)`. See `table_init`.
pub fn t_table_init(
  st: InstanceState,
  idx: Int,
  items: List(RefValue),
  dst: Int,
  src: Int,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  commit_t(st, idx, do_table_init(read_at_t(st, idx), items, dst, src, count))
}

/// Threaded `table.copy` (memmove, R11): eager bounds, no partial writes; `Ok(st')` charging
/// `count` fuel, else `Error(TableOutOfBounds)`. See `table_copy`.
pub fn t_table_copy(
  st: InstanceState,
  dst_idx: Int,
  src_idx: Int,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  commit_t(
    st,
    dst_idx,
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
  commit_t(st, idx, do_init_elem_ref(read_at_t(st, idx), offset, refs))
}

/// Project table `idx`'s handle out of the threaded record and coerce it to a `Table`. Read-only.
fn read_at_t(st: InstanceState, idx: Int) -> Table {
  dynamic_to_table(rt_state.t_table_at(st, idx))
}

/// Commit a mutating op's `Result(Table, _)` into table `idx` of the threaded record: on `Ok`,
/// re-inject the rebuilt handle (§10) and return `Ok(st')`; on `Error`, propagate `st` untouched.
fn commit_t(
  st: InstanceState,
  idx: Int,
  result: Result(Table, TrapReason),
) -> Result(InstanceState, TrapReason) {
  case result {
    Ok(table) -> Ok(rt_state.t_with_table_at(st, idx, table_to_dynamic(table)))
    Error(reason) -> Error(reason)
  }
}

// ───────────────────────────── the shared op cores (the testable algebra) ─────────────────────────────
//
// One core per op, driven by BOTH the cell and threaded families — so behaviour AND fuel are
// identical across state strategies by construction. Cores operate on an explicit immutable
// `Table`, treating every reference value as OPAQUE (they never invoke or inspect a funcref
// closure), and charge fuel (R9) on the success path.

/// Pure `table.get`: bounds-check, else the slot's reference (absent ⇒ null sentinel).
fn do_get(t: Table, index: Int) -> Result(RefValue, TrapReason) {
  case index < 0 || index >= t.size {
    True -> Error(TableOutOfBounds)
    False -> Ok(slot_ref(t, index))
  }
}

/// Pure `table.set`: bounds-check FIRST (eager, no write on trap), else the rebuilt table.
fn do_set(t: Table, index: Int, value: RefValue) -> Result(Table, TrapReason) {
  case index < 0 || index >= t.size {
    True -> Error(TableOutOfBounds)
    False -> Ok(Table(..t, slots: put_slot(t.slots, index, value)))
  }
}

/// Pure `table.size`.
fn do_size(t: Table) -> Int {
  t.size
}

/// Pure `table.grow`. Returns `#(old_size, grown)` on success (charging `delta` fuel, R9) or
/// `#(-1, t)` if `delta < 0` or `old + delta` exceeds the effective `max` (unchanged, no charge).
fn do_grow(t: Table, delta: Int, init: RefValue) -> #(Int, Table) {
  let old = t.size
  let new = old + delta
  case delta >= 0 && new <= t.max {
    False -> #(-1, t)
    True -> {
      let grown =
        Table(..t, size: new, slots: fill_slots(t.slots, old, init, delta))
      rt_meter.charge(delta)
      #(old, grown)
    }
  }
}

/// Pure `table.fill`: eager bounds (`offset + count > size`, checked even for `count == 0`, R10),
/// no partial writes; else the filled table, charging `count` fuel (R9).
fn do_fill(
  t: Table,
  offset: Int,
  value: RefValue,
  count: Int,
) -> Result(Table, TrapReason) {
  case offset < 0 || count < 0 || offset + count > t.size {
    True -> Error(TableOutOfBounds)
    False -> {
      let filled = Table(..t, slots: fill_slots(t.slots, offset, value, count))
      rt_meter.charge(count)
      Ok(filled)
    }
  }
}

/// Pure `table.init` from `items`: eager bounds against BOTH the segment length and the table
/// size, no partial writes; else the written table, charging `count` fuel (R9). A dropped segment
/// arrives as `items = []`, so any `count > 0` traps and `count == 0` no-ops (R2/§D).
fn do_table_init(
  t: Table,
  items: List(RefValue),
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Table, TrapReason) {
  case
    dst < 0
    || src < 0
    || count < 0
    || dst + count > t.size
    || src + count > list.length(items)
  {
    True -> Error(TableOutOfBounds)
    False -> {
      let slice = list.take(list.drop(items, src), count)
      let written = Table(..t, slots: write_slots(t.slots, dst, slice))
      rt_meter.charge(count)
      Ok(written)
    }
  }
}

/// Pure `table.copy` (memmove, R11): eager bounds against both ranges, no partial writes; else the
/// written destination table, charging `count` fuel (R9). Overlap correctness comes from
/// SNAPSHOTTING the whole source slice as a list BEFORE any destination write.
fn do_table_copy(
  dst_t: Table,
  src_t: Table,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Table, TrapReason) {
  case
    dst < 0
    || src < 0
    || count < 0
    || dst + count > dst_t.size
    || src + count > src_t.size
  {
    True -> Error(TableOutOfBounds)
    False -> {
      let slice = list.map(range_list(src, count), fn(i) { slot_ref(src_t, i) })
      let written = Table(..dst_t, slots: write_slots(dst_t.slots, dst, slice))
      rt_meter.charge(count)
      Ok(written)
    }
  }
}

/// Pure active reference-segment write (no fuel): whole-range bounds, no partial writes.
fn do_init_elem_ref(
  t: Table,
  offset: Int,
  refs: List(RefValue),
) -> Result(Table, TrapReason) {
  case offset < 0 || offset + list.length(refs) > t.size {
    True -> Error(TableOutOfBounds)
    False -> Ok(Table(..t, slots: write_slots(t.slots, offset, refs)))
  }
}

// ───────────────────────────── slot helpers ─────────────────────────────

/// The reference value at slot `index`: the stored value, or the null sentinel if absent.
fn slot_ref(t: Table, index: Int) -> RefValue {
  case dict.get(t.slots, index) {
    Ok(value) -> value
    Error(Nil) -> rt_ref.null_ref()
  }
}

/// Write `value` into slot `index`: a non-null reference is INSERTED; the null sentinel is
/// represented by ABSENCE, so a null write DELETES the slot (keeping `call_indirect`'s absent-key
/// guard byte-identical).
fn put_slot(
  slots: Dict(Int, RefValue),
  index: Int,
  value: RefValue,
) -> Dict(Int, RefValue) {
  case rt_ref.is_null(value) {
    True -> dict.delete(slots, index)
    False -> dict.insert(slots, index, value)
  }
}

/// Fill slots `[start, start + count)` all with `value` (via `put_slot`).
fn fill_slots(
  slots: Dict(Int, RefValue),
  start: Int,
  value: RefValue,
  count: Int,
) -> Dict(Int, RefValue) {
  case count <= 0 {
    True -> slots
    False ->
      fill_slots(put_slot(slots, start, value), start + 1, value, count - 1)
  }
}

/// Write `values` into consecutive slots starting at `start` (`values[k]` → slot `start + k`).
fn write_slots(
  slots: Dict(Int, RefValue),
  start: Int,
  values: List(RefValue),
) -> Dict(Int, RefValue) {
  list.index_fold(values, slots, fn(acc, value, k) {
    put_slot(acc, start + k, value)
  })
}

/// The effective maximum entry count baked at `new` time: `min(declared_max, hard_max_slots)`, or
/// `hard_max_slots` when no maximum is declared. `grow` never exceeds it.
pub fn effective_max(max: Option(Int)) -> Int {
  case max {
    Some(declared) -> int.min(declared, hard_max_slots)
    None -> hard_max_slots
  }
}

// ───────────────────────────── differential canon hook (tests only, §H) ─────────────────────────────

/// The tier's whole slot image as a `size`-length list of funcref type tags — the differential
/// ORACLE image (`TablePaged` is the oracle). `None` = a null slot (absent) OR a non-funcref
/// (externref) reference; `Some(ty)` = a funcref slot's structural `FuncType`. Closures/externref
/// payloads are not compared here (behaviour is compared via `call_indirect`/`get`). Tests only.
pub fn to_canon(handle: Dynamic) -> List(Option(FuncType)) {
  let table = dynamic_to_table(handle)
  list.map(indices(table.size), fn(i) {
    case dict.get(table.slots, i) {
      Error(Nil) -> None
      Ok(value) ->
        case rt_ref.classify_ref(value) {
          rt_ref.FuncRef -> Some(ref_func_type_entry(value).0)
          _ -> None
        }
    }
  })
}

/// The ascending slot indices `[0, 1, …, size-1]` (`[]` for `size <= 0`). Built by hand so it
/// never depends on `list.range`'s descending-range edge behaviour. Private helper for `to_canon`.
fn indices(size: Int) -> List(Int) {
  range_list(0, size)
}

/// The `count` ascending integers `[start, start+1, …, start+count-1]` (`[]` for `count <= 0`).
fn range_list(start: Int, count: Int) -> List(Int) {
  build_range(start, count, [])
}

fn build_range(start: Int, count: Int, acc: List(Int)) -> List(Int) {
  case count <= 0 {
    True -> list.reverse(acc)
    False -> build_range(start + 1, count - 1, [start, ..acc])
  }
}
