//// `rt_state` — the per-instance **cell** holder (`«CELL-STATE-ABI-FROZEN»`; owner: unit
//// 03). SIGNATURES frozen by unit 01; BODIES implemented by unit 03.
////
//// **One-instance-one-process (E1).** An instance's mutable state — its linear memory,
//// its mutable globals, and its table — lives in THIS process's dictionary under a single
//// fixed namespaced key, holding an opaque `InstanceState` record. The harness/linker
//// (unit 11) runs `instantiate` plus every `invoke` of an instance inside one owned
//// process, so the cell is naturally isolated and reset per (re)instantiation. Generated
//// function arities are unchanged — the state handle never becomes a loop-carried value
//// (it stays hidden in the cell), preserving the Phase-1 constant-space tail loop.
////
//// **The key.** The cell lives under ONE fixed key, the 0-field Gleam constructor
//// `TwocoreRtState`, which compiles to the unique, namespace-hygienic atom
//// `twocore_rt_state` (exactly the `rt_meter` `TwocoreRtMeterFuel → twocore_rt_meter_fuel`
//// pattern). One key holds the WHOLE `{mem, globals, table}` record, so it cannot collide
//// with `rt_meter`'s fuel key (or any other pdict use) and a (re)seed is an atomic
//// one-`put` replacement of all prior state.
////
//// **Tier-O, by reference, constant space.** Reads use `erlang:get/1`, which returns the
//// stored term BY REFERENCE (no copy); writes use `erlang:put/2`, which replaces a single
//// root (the superseded record becomes garbage, GC'd with the process). This is the proven
//// `rt_meter` posture (a 100k-iteration pdict store loop was constant-space on OTP 29). It
//// is tier-O (OTP-native, memory-safe, no NIF), which Safe permits. ETS is the WRONG cell
//// here: it deep-copies the whole term on every read/write and has no auto-GC.
////
//// **Fail-closed (E3).** Operating on an UN-SEEDED cell is an internal invariant
//// violation (it is unreachable under the one-instance-one-process harness contract), NOT
//// a WASM `TrapReason`: the bodies raise a distinct internal error (a node-safe `panic`)
//// rather than reading garbage. Reading garbage out of an empty pdict — fabricating a
//// zeroed cell to "recover" — is exactly the bug this guard exists to prevent.
////
//// **Opacity.** `rt_state` does NOT import `rt_mem`/`rt_table`, so there is no circular
//// import: the memory and table values are held as `gleam/dynamic.Dynamic`. `rt_mem` owns
//// the memory value's shape and `rt_table` owns the table value's shape; each coerces its
//// own field via `mem_get`/`mem_put` / `table_get`/`table_put`. Mutable globals are
//// raw-bit-pattern `Int`s keyed by name.
////
//// **Globals are raw bits (D5) or boxed `Dynamic`s.** i32/i64/f32/f64 globals are all stored
//// identically as a raw bit-pattern `Int` in `globals`. f32/f64 are NEVER round-tripped through a
//// BEAM double (a double cannot hold NaN payloads / signalling bits), so `rt_state` does no float
//// math and needs no per-global type tag. **Non-numeric globals box in the parallel `ref_globals`
//// map** as opaque `Dynamic`s: a REFERENCE global (funcref/externref, R8) and — Phase-6 (S6) — a
//// `v128` global (a 16-byte `BitArray`), which cannot live in the `Int` `globals` map without
//// disturbing the byte-identical numeric path. `rt_state` treats every `ref_globals` entry
//// opaquely (`emit_core` routes both reftype and v128 global access through the boxed accessors).
////
//// **Effect note (E6).** `global.get`/`global.set` (and the mem/table accessors) are
//// side-effecting: a future optimizer must treat them as barriers — never CSE, reorder, or
//// dead-code-eliminate across them.
////
//// **Pitfall — one-instance-one-process is load-bearing.** pdict is strictly per-process.
//// If a host or another process calls an instance export directly, `rt_state` reads the
//// CALLER's (empty) pdict → silent corruption. The contract is that every cross-process
//// entry goes via the instance's owned process; the harness (unit 11) enforces it.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/set.{type Set}

/// `erlang:put/2` — store `value` under `key` in the current process dictionary; returns
/// the previous value (or the atom `undefined` if unset), which callers here discard.
/// Direct BIF reference; process-local, cannot crash the node.
@external(erlang, "erlang", "put")
fn erlang_put(key: k, value: v) -> Dynamic

/// `erlang:erase/1` — remove `key` from the current process dictionary, returning its
/// previous value (or `undefined`), which callers here discard. Direct BIF reference;
/// process-local, cannot crash the node.
@external(erlang, "erlang", "erase")
fn erlang_erase(key: k) -> Dynamic

/// Read this process's cell with a sound presence check (the `twocore_`-namespaced shim,
/// mirroring `twocore_codegen_ffi`/`twocore_cli_ffi`). Returns `Ok(state)` when the key
/// holds a cell, or `Error(Nil)` when it is absent (the BIF's `undefined`). The present
/// term is returned BY REFERENCE wrapped in `{ok, _}` (no deep copy) — `rt_state` is the
/// sole writer of this key, so coercing the present term back to `InstanceState` is sound.
@external(erlang, "twocore_rt_state_ffi", "read_cell")
fn read_cell(key: k) -> Result(InstanceState, Nil)

/// The process-dictionary key holding this process's whole instance cell. As a 0-field
/// Gleam constructor it compiles to the unique, namespace-hygienic atom `twocore_rt_state`,
/// so it cannot clash with `rt_meter`'s fuel key or any other library's pdict keys.
type StateKey {
  TwocoreRtState
}

/// The opaque per-instance state record held in the process cell (Phase-5 grown, R5/R7/R8).
///
/// Phase 5 generalizes the single-memory/single-table Phase-4 record to the complete-WASM
/// surface: a **dense index-keyed memories vector**, a **dense index-keyed tables vector**
/// (R7 — `emit_core` resolves table name→index at compile time; index 0 is the Phase-2 single
/// table, byte-identical), passive-segment **drop-state sets** (R2 — `rt_state` owns ONLY the
/// drop flag; the segment payload is an emit-supplied argument), and a **parallel
/// `ref_globals` map** (R8 — reference-typed globals live on the term `Dynamic` path so the
/// raw-bit `Int` `globals` path, D5, is untouched and byte-identical). The Phase-4 accessors
/// (`mem_get`/`mem_put`/`mem`/`with_mem`, the single-table accessors, `global_*`/`t_global_*`)
/// remain as **index-0 / head aliases** so generated code and `rt_mem`/`rt_table` stay
/// byte-identical.
///
/// SEEDING (R5, unit 09): the keystone froze the record SHAPE + accessor bodies; unit 09 lands
/// the REAL general seeding — `FullDecl` + `seed_full`/`fresh_full` build an N-memory / N-table /
/// imported-state (imports at the low indices) / reference-global record, while `StateDecl` +
/// `seed`/`fresh` stay the byte-identical single-region path (`emit_core` unit 06 picks which to
/// emit). No generated code embeds this record literally (it is built by a seed/fresh call and
/// threaded opaquely), so growing it changes NO emitted `.core`.
///
/// - `mems`: the memory-index vector, each entry OPAQUE to `rt_state` (built/interpreted by
///   `rt_mem`). Index 0 is the default memory every Phase-1..4 memory node targets.
/// - `globals`: the mutable NUMERIC globals as raw IEEE/two's-complement bit patterns, keyed
///   by global name (unchanged — D5 raw-bits path).
/// - `tables`: the table-index vector, each entry OPAQUE to `rt_state` (built/interpreted by
///   `rt_table`). Index 0 is the Phase-2 single table.
/// - `dropped_data`: the set of passive DATA segment indices marked dropped (R2). Drop is O(1).
/// - `dropped_elem`: the set of passive ELEMENT segment indices marked dropped (R2).
/// - `ref_globals`: the mutable/immutable **boxed non-numeric globals** as opaque `Dynamic` terms
///   keyed by name — kept parallel to `globals` so the numeric raw-bit path (D5) is byte-identical.
///   Phase-5 (R8) this held REFERENCE globals (funcref/externref); Phase-6 (S6) WIDENS its role to
///   also hold **`v128` globals** — a `v128` is a 16-byte `BitArray` (`<<_:128>>`), a `Dynamic`
///   that stores/retrieves exactly like a reference value and, like a reference, cannot live in the
///   numeric-`Int` `globals` map (which must stay byte-identical for D5). `emit_core` (unit 06)
///   routes a `v128`-typed `global.get`/`global.set`/const-init to the SAME boxed accessor
///   (`ref_global_get`/`ref_global_set`) it uses for reftype globals; `rt_state` does not
///   distinguish the two (both are opaque `Dynamic`s), so no per-global type tag is needed.
/// - `func_imports`: the per-instance **function-import dispatch vector** (S5, completed by unit
///   06). One opaque closure per IMPORTED function, in function-import declaration order — each a
///   `fn(List(Dynamic)) -> List(Dynamic)` capability the linker built (`link.link_func_imports`):
///   a host/`spectest` import wraps `rt_host.call_host`, a cross-module import routes into the
///   exporting instance. `emit_core` reads slot `CallImport.slot` via `func_import_at`/
///   `t_func_import_at` and applies it through `link.call_import` — a HANDED-IN capability, never an
///   ambient `apply` of a data-named `module:atom` (D3a). Seeded by `seed_func_imports` (cell) /
///   `set_func_imports` (threaded) at `instantiate`; empty (`[]`) for a module with no
///   imported-function CALLS (so the field is inert + byte-neutral for the whole Phase-1..5 corpus).
pub type InstanceState {
  InstanceState(
    mems: List(Dynamic),
    globals: Dict(String, Int),
    tables: List(Dynamic),
    dropped_data: Set(Int),
    dropped_elem: Set(Int),
    ref_globals: Dict(String, Dynamic),
    func_imports: List(Dynamic),
  )
}

/// What the generated `instantiate/0` entry passes to `seed`/`fresh` for the **single-memory /
/// single-table / import-free** module (the entire Phase-1..4 corpus): the FRESH per-layer
/// values to install into a brand-new cell/record.
///
/// FROZEN UNCHANGED from Phase 4 (byte-identity, H7): `emit_core.state_decl_term` emits the
/// same `{state_decl, Mem, Globals, Table}` term, so the `.core`/`.beam` is unchanged. `build`
/// wraps the single `mem`/`table` into one-element index-0 vectors and seeds empty drop-state /
/// `ref_globals`, sharing the materialisation path (`build_full`) with the general case.
///
/// **The general case** — a module with multiple memories/tables, non-function imports, or
/// reference-typed globals — uses `FullDecl` + `seed_full`/`fresh_full` (below). `emit_core`
/// (unit 06) emits `StateDecl` for the byte-identical case and `FullDecl` for the rich case, so
/// a Phase-1..4 module keeps its exact prior `.core` (R5/R7/R8; the `StateDecl` shape is stable
/// and never grown, so growing the surface never disturbs the frozen emitted term).
///
/// - `mem`: a fresh memory value built by `rt_mem.fresh` (rt_state stores it as-is,
///   preserving opacity — it never constructs memory). Becomes the index-0 memory.
/// - `globals`: the initial NUMERIC globals as `#(name, raw_bits)` pairs (from each global's
///   constant init expression), in declaration order. Duplicate names keep the LAST pair
///   (`dict.from_list` semantics); validation guarantees unique global names upstream.
/// - `table`: a fresh table value built by `rt_table.new` (stored as-is). Becomes index-0.
pub type StateDecl {
  StateDecl(mem: Dynamic, globals: List(#(String, Int)), table: Dynamic)
}

/// What the generated `instantiate/1(Imports)` entry passes to `seed_full`/`fresh_full` for the
/// **general** module — the multi-memory / multi-table / non-function-import / reference-global
/// surface (R5/R7/R8). It is the value-shaped decl `emit_core` (unit 06) builds after weaving
/// each resolved `Provided` externval (`link.Provided`) into the right slot: an IMPORTED
/// memory/table/global occupies the LOW index of its space (imports precede definitions, spec
/// §2.5.1), a DEFINED one holds its freshly-built value. `rt_state` needs NO knowledge of imports
/// — it receives a decl whose imported slots ALREADY hold their provided values and installs it
/// exactly as it installs a fresh one (the imported-state wiring is a codegen concern, unit 06).
///
/// A fresh instance drops NO segment, so the drop-state is always empty at instantiate and is not
/// carried here (`build_full` seeds `set.new()` for both).
///
/// - `mems`: the instance's memories as a **dense index-keyed vector** in index order, imported
///   memories first (multi-memory, H3). Each entry is OPAQUE `Dynamic` (built by `rt_mem`); index
///   0 is the default memory every Phase-1..4 memory node targets. A single element ⇒ byte-
///   identical to Phase-4.
/// - `globals`: the NUMERIC globals as `#(name, raw_bits)` pairs (D5 raw-bit path) — an imported
///   global's pair is its provided bits, a defined global's its const-folded init.
/// - `tables`: the instance's tables as a **dense index-keyed vector** in index order, imported
///   tables first (R7 — `emit_core` resolves table name→index at compile time). Each entry OPAQUE.
/// - `ref_globals`: the **boxed non-numeric globals** as `#(name, value)` pairs on the opaque
///   `Dynamic` path, kept parallel to `globals` so the numeric path is byte-identical. Reference
///   globals (funcref/externref, R8) AND — Phase-6 (S6) — `v128` globals (each a 16-byte
///   `BitArray`) seed through here; an imported such global's pair is its provided value, a defined
///   one's its rendered/const init. `rt_state` treats every entry as an opaque `Dynamic`.
pub type FullDecl {
  FullDecl(
    mems: List(Dynamic),
    globals: List(#(String, Int)),
    tables: List(Dynamic),
    ref_globals: List(#(String, Dynamic)),
  )
}

/// Seed a FRESH per-instance cell for THIS process from `decl`, RESETTING any prior state
/// (one-instance-one-process). Called once by the generated `instantiate` entry before any
/// element/data segment is written or the start function runs.
///
/// - `decl`: the fresh mem/globals/table to install. `decl.globals` is materialised into a
///   `Dict` keyed by name.
/// - Returns `Nil`. The body installs the cell with a single `erlang:put/2`, so the reset
///   is atomic: the old record (if any) is discarded wholesale and becomes garbage. Total;
///   never raises. Routes through the shared `build` constructor so a `Cell` build (this
///   `seed`) and a `Threaded` build (`fresh`) materialise BYTE-IDENTICAL state (G7).
pub fn seed(decl: StateDecl) -> Nil {
  put_cell(build(decl))
}

/// Seed a FRESH per-instance cell from a GENERAL `FullDecl` (the multi-memory / multi-table /
/// imported / reference-global surface, R5/R7/R8) — the `Cell` install the generated
/// `instantiate/1(Imports)` entry calls once, before any element/data segment write or `start`.
///
/// - `decl`: the fully-woven per-layer values (imported slots already hold their provided
///   values, at their low indices). Installs the memories/tables vectors verbatim in index order,
///   materialises `globals`/`ref_globals` into `Dict`s, and seeds EMPTY drop-state (a fresh
///   instance has dropped nothing).
/// - Returns `Nil`. Installs the cell with a single atomic `erlang:put/2`, resetting any prior
///   state (one-instance-one-process). Total; never raises. Routes through the shared `build_full`
///   constructor so a `Cell` build (`seed_full`) and a `Threaded` build (`fresh_full`) materialise
///   BYTE-IDENTICAL state (G7). Byte-identical to `seed` when `mems`/`tables` are one-element and
///   `ref_globals` is empty.
pub fn seed_full(decl: FullDecl) -> Nil {
  put_cell(build_full(decl))
}

/// Drop this process's cell (used between instances when a process is reused). After
/// `clear`, any state accessor is an un-seeded-cell invariant violation until the next
/// `seed`.
///
/// - Returns `Nil`. Side-effecting (process-local `erlang:erase/1`). Total; never raises
///   (erasing an absent key is a no-op).
pub fn clear() -> Nil {
  let _ = erlang_erase(TwocoreRtState)
  Nil
}

/// Read the DEFAULT (index-0) opaque memory value out of this process's cell (for `rt_mem`).
///
/// The Phase-4 name, preserved as the index-0 alias of `mem_at` for byte-identity (R6).
/// - Returns the `Dynamic` memory value, unchanged (rt_state never inspects it). Fail-closed:
///   `panic`s (a node-safe internal error) on an un-seeded cell — never returns garbage.
pub fn mem_get() -> Dynamic {
  mem_at(0)
}

/// Write a new DEFAULT (index-0) opaque memory value into this process's cell (for `rt_mem`).
///
/// The Phase-4 name, preserved as the index-0 alias of `with_mem_at` for byte-identity (R6).
/// - `mem`: the updated memory value (rt_mem produces it; rt_state stores it opaquely).
/// - Returns `Nil`. Fail-closed: `panic`s on an un-seeded cell. Other fields preserved by ref.
pub fn mem_put(mem: Dynamic) -> Nil {
  with_mem_at(0, mem)
}

/// Read the opaque memory value at index `index` out of this process's cell (R6/R7).
///
/// - `index`: the memory index (0 = the default memory). Out of range is an internal
///   invariant violation (unreachable post-validation; the multi-memory vector is seeded to
///   the module's memory count by unit 09) and `panic`s fail-closed — never garbage.
/// - Returns the `Dynamic` memory value at `index`, unchanged. Fail-closed on an un-seeded
///   cell. (Keystone stub: the vector currently holds exactly the default memory; 09 seeds N.)
pub fn mem_at(index: Int) -> Dynamic {
  nth_or_panic(
    require_cell().mems,
    index,
    "rt_state.mem_at: memory index out of range (internal invariant violation)",
  )
}

/// Rebind the memory at index `index` in this process's cell (R6/R7).
///
/// - `index`: the memory index (0 = the default memory).
/// - `handle`: the updated opaque memory value.
/// - Returns `Nil`. Fail-closed: `panic`s on an un-seeded cell. Only `index` changes; other
///   memories/fields are preserved by reference. An out-of-range `index` leaves the vector
///   unchanged (a conservative no-op — 09 grows the vector so every live index exists).
pub fn with_mem_at(index: Int, handle: Dynamic) -> Nil {
  let st = require_cell()
  put_cell(InstanceState(..st, mems: set_nth(st.mems, index, handle)))
}

/// Read the DEFAULT (index-0 / first) opaque table value out of this process's cell.
///
/// The Phase-4 name, preserved as the index-0 alias of `table_at` for byte-identity (R6/R7).
/// - Returns the `Dynamic` table value, unchanged. Fail-closed on an un-seeded cell.
pub fn table_get() -> Dynamic {
  table_at(0)
}

/// Write a new DEFAULT (index-0 / first) opaque table value into this process's cell.
///
/// The Phase-4 name, preserved as the index-0 alias of `with_table_at` for byte-identity.
/// - `table`: the updated table value (rt_table produces it; rt_state stores it opaquely).
/// - Returns `Nil`. Fail-closed on an un-seeded cell. Other fields preserved by reference.
pub fn table_put(table: Dynamic) -> Nil {
  with_table_at(0, table)
}

/// Read the opaque table value at index `index` out of this process's cell (R7).
///
/// - `index`: the table index (0 = the default/first table). `emit_core` resolves each table
///   name to its compile-time index. Out of range `panic`s fail-closed (internal invariant).
/// - Returns the `Dynamic` table value at `index`, unchanged. Fail-closed on an un-seeded cell.
pub fn table_at(index: Int) -> Dynamic {
  nth_or_panic(
    require_cell().tables,
    index,
    "rt_state.table_at: table index out of range (internal invariant violation)",
  )
}

/// Rebind the table at index `index` in this process's cell (R7).
///
/// - `index`: the table index (0 = the default/first table).
/// - `handle`: the updated opaque table value.
/// - Returns `Nil`. Fail-closed on an un-seeded cell. Only `index` changes; others by ref.
///   An out-of-range `index` is a conservative no-op (09 seeds every live table index).
pub fn with_table_at(index: Int, handle: Dynamic) -> Nil {
  let st = require_cell()
  put_cell(InstanceState(..st, tables: set_nth(st.tables, index, handle)))
}

// ── passive-segment drop state (cell family; R2) ──────────────────────────────
//
// `rt_state` owns ONLY the drop FLAG (a `Set(Int)`); the segment payload is a compile-time
// constant `emit_core` passes as an argument to `rt_mem`/`rt_table` (never stored here). Drop
// is O(1). A dropped segment behaves as length-0, so a later `*.init` with count>0 traps on
// the source-bounds check — exactly the spec (§4.4.9). These bodies are REAL (simple set ops);
// what unit 09 adds is seeding the sets to empty at instantiate (already the `build` default).

/// Has passive data segment `seg` been dropped? (`data.drop` / `memory.init` guard, R2.)
/// - Returns `True` iff `seg ∈ dropped_data`. Fail-closed on an un-seeded cell.
pub fn data_dropped(seg: Int) -> Bool {
  set.contains(require_cell().dropped_data, seg)
}

/// Mark passive data segment `seg` dropped (`data.drop`, R2). Idempotent.
/// - Returns `Nil`. Fail-closed on an un-seeded cell. Other fields preserved by reference.
pub fn drop_data(seg: Int) -> Nil {
  let st = require_cell()
  put_cell(InstanceState(..st, dropped_data: set.insert(st.dropped_data, seg)))
}

/// Has passive element segment `seg` been dropped? (`elem.drop` / `table.init` guard, R2.)
/// - Returns `True` iff `seg ∈ dropped_elem`. Fail-closed on an un-seeded cell.
pub fn elem_dropped(seg: Int) -> Bool {
  set.contains(require_cell().dropped_elem, seg)
}

/// Mark passive element segment `seg` dropped (`elem.drop`, R2). Idempotent.
/// - Returns `Nil`. Fail-closed on an un-seeded cell. Other fields preserved by reference.
pub fn drop_elem(seg: Int) -> Nil {
  let st = require_cell()
  put_cell(InstanceState(..st, dropped_elem: set.insert(st.dropped_elem, seg)))
}

// ── boxed non-numeric globals (cell family; R8 + S6) ──────────────────────────
//
// A boxed global holds a `Dynamic`, not an `Int`, so it lives in a PARALLEL map, leaving the
// raw-bit numeric `globals` (D5) untouched and byte-identical. Two kinds box here: a REFERENCE
// global (funcref/externref, R8) and — Phase-6 (S6) — a `v128` global (a 16-byte `BitArray`).
// `rt_state` does not distinguish them; both round-trip as opaque `Dynamic`s through these
// accessors (`emit_core` routes both reftype and v128 `global.get`/`global.set` here).

/// Read boxed global `name`'s current value from this process's cell (R8/S6) — a reference
/// (funcref/externref) or a `v128` (16-byte `BitArray`), as an opaque `Dynamic`.
/// - Returns the boxed `Dynamic`. Fail-closed: `panic`s on an un-seeded cell OR an
///   undeclared `name` (both unreachable post-validation) — never fabricates a value.
pub fn ref_global_get(name: String) -> Dynamic {
  case dict.get(require_cell().ref_globals, name) {
    Ok(value) -> value
    Error(Nil) ->
      panic as "rt_state.ref_global_get: undeclared reference global (internal invariant violation)"
  }
}

/// Write boxed global `name` in this process's cell (R8/S6) — a reference or a `v128` `Dynamic`.
/// - `value`: the new boxed `Dynamic` (stored verbatim; `rt_state` never inspects it, so a v128's
///   16 raw bytes / a reference's opacity survive exactly). Returns `Nil`. Fail-closed on an
///   un-seeded cell. Only `name` changes; other globals and fields are preserved by reference.
pub fn ref_global_set(name: String, value: Dynamic) -> Nil {
  let st = require_cell()
  put_cell(
    InstanceState(..st, ref_globals: dict.insert(st.ref_globals, name, value)),
  )
}

// ── function-import dispatch vector (cell family; S5, completed by unit 06) ────────────
//
// The per-instance vector of imported-function closures (one per imported function, in
// function-import order). `emit_core`'s generated `instantiate` seeds it once (right after the
// fresh cell is installed) from the linker-built `link.link_func_imports` result; a `CallImport`
// site reads slot `n` and applies it through `link.call_import`. A handed-in capability (D3a) —
// `rt_state` stores the closures opaquely and never names a callee.

/// Seed this process's cell with the function-import dispatch vector `closures` (S5) — one opaque
/// `fn(List(Dynamic)) -> List(Dynamic)` per imported function, in function-import order. Called
/// once by the generated `instantiate` (unit 06) immediately after `seed`/`seed_full`, only when
/// the module calls an imported function.
/// - `closures`: the linker-built dispatch closures (from `link.link_func_imports`).
/// - Returns `Nil`. Fail-closed: `panic`s on an un-seeded cell. Only `func_imports` changes; other
///   fields are preserved by reference.
pub fn seed_func_imports(closures: List(Dynamic)) -> Nil {
  let st = require_cell()
  put_cell(InstanceState(..st, func_imports: closures))
}

/// Read the imported-function dispatch closure at `slot` from this process's cell (S5) — the
/// capability a `CallImport(slot, …)` applies via `link.call_import`.
/// - `slot`: the positional function-import index (0-based over imported functions, declaration
///   order). Out of range / un-seeded cell `panic`s fail-closed (an internal codegen invariant —
///   `emit_core` seeds exactly one closure per imported function; never a WASM trap).
/// - Returns the boxed closure as an opaque `Dynamic`.
pub fn func_import_at(slot: Int) -> Dynamic {
  nth_or_panic(
    require_cell().func_imports,
    slot,
    "rt_state.func_import_at: function-import slot out of range (internal invariant violation)",
  )
}

/// Read mutable global `name`'s current raw bit pattern from this process's cell.
///
/// - `name`: the global's name.
/// - Returns the global's value as a raw bit pattern (`Int`) — bit-exact, never coerced to
///   a BEAM double. Fail-closed: `panic`s (internal invariant violation, NOT a WASM trap)
///   on an un-seeded cell OR an undeclared `name`; both are unreachable under validation +
///   the harness contract, so they are defensive guards, never a normal path.
pub fn global_get(name: String) -> Int {
  case dict.get(require_cell().globals, name) {
    Ok(value) -> value
    Error(Nil) ->
      panic as "rt_state.global_get: undeclared global (internal invariant violation)"
  }
}

/// Write `value` (a raw bit pattern) into mutable global `name` in this process's cell.
///
/// - `name`: the global's name.
/// - `value`: the new raw bit pattern (stored verbatim; rt_state does no float math).
/// - Returns `Nil`. Side-effecting (read-cell → `dict.insert` → put-cell). Fail-closed:
///   `panic`s on an un-seeded cell. `value` overwrites only `name`; other globals are
///   preserved by reference. Immutability of `const` globals is enforced at validation
///   (unit 08), not here — this is a mechanical write.
pub fn global_set(name: String, value: Int) -> Nil {
  let state = require_cell()
  put_cell(
    InstanceState(..state, globals: dict.insert(state.globals, name, value)),
  )
}

// ── tier-P: the threaded instance-state surface (unit 03; NO process dictionary) ──
//
// The purely-functional twin of the cell surface above. Under `state_strategy: Threaded`
// (Phase-4 keystone §A), generated code threads the SAME `InstanceState` record as an
// ordinary value — every state-reaching function takes it as a leading parameter and returns
// the (possibly updated) record. There is NO ambient location the state lives in: it is a
// Gleam value on the stack. This surface reaches NONE of the module's three pdict externals
// (`erlang_put`/`erlang_erase`/`read_cell`) — it is pure `dict.*` + record construction, so
// it links no process dictionary, no OTP-native state (atomics/ets/persistent_term), and no
// NIF (the "runs-anywhere" posture, G6). The cell surface above stays untouched and parallel.

/// Build the initial threaded instance-state record from the SAME `StateDecl` the cell
/// strategy passes to `seed` — but RETURN it as a value (no pdict write). Called once by the
/// threaded `instantiate/0` (unit 02) before any element/data segment is written or the start
/// function runs.
///
/// - `decl`: the fresh per-layer values to install. `decl.globals` is materialised into the
///   `globals` `Dict` (keyed by name; duplicate names keep the LAST, per `dict.from_list`);
///   `mem`/`table` are stored opaquely as-is (already built by `rt_mem.fresh`/`rt_table.new`,
///   never inspected here).
/// - Returns the fresh `InstanceState`. Total; never raises; touches NO process dictionary.
///   Shares the `build` constructor with `seed`, so a `Threaded` build and a `Cell` build
///   start from BYTE-IDENTICAL state (G7).
pub fn fresh(decl: StateDecl) -> InstanceState {
  build(decl)
}

/// Build the initial threaded instance-state record from a GENERAL `FullDecl` — the `Threaded`
/// twin of `seed_full` (returns the record as a value; no pdict write). Called once by the
/// threaded `instantiate/1(Imports)` (unit 06) before any element/data segment write or `start`.
///
/// - `decl`: the fully-woven per-layer values (imported slots at their low indices). The
///   memories/tables vectors are stored opaquely in index order; `globals`/`ref_globals` are
///   materialised into `Dict`s; drop-state starts empty.
/// - Returns the fresh `InstanceState`. Total; never raises; touches NO process dictionary. Shares
///   the `build_full` constructor with `seed_full`, so a `Threaded` build and a `Cell` build start
///   from BYTE-IDENTICAL state (G7).
pub fn fresh_full(decl: FullDecl) -> InstanceState {
  build_full(decl)
}

/// Read mutable global `name`'s raw bit pattern from the threaded record. READ-ONLY: `st` is
/// unchanged (the caller keeps threading the same record forward).
///
/// - `st`: the threaded instance-state record.
/// - `name`: the global's name.
/// - Returns the global's value as a raw bit pattern (`Int`) — bit-exact, never coerced to a
///   BEAM double (D5). Fail-closed: an undeclared `name` `panic`s a distinct internal error
///   (a node-safe internal-invariant violation, NOT a WASM `TrapReason`); it is unreachable
///   post-validation (global existence is a validation property, unit P2-08), so this is a
///   defensive guard, never a normal path — it never fabricates a value.
///   (<https://webassembly.github.io/spec/core/exec/instructions.html#variable-instructions>)
pub fn t_global_get(st: InstanceState, name: String) -> Int {
  case dict.get(st.globals, name) {
    Ok(value) -> value
    Error(Nil) ->
      panic as "rt_state.t_global_get: undeclared global (internal invariant violation)"
  }
}

/// Rebind mutable global `name` to `value`, RETURNING the updated record.
///
/// - `st`: the threaded instance-state record.
/// - `name`: the global's name.
/// - `value`: the new raw bit pattern (stored verbatim; `rt_state` does no float math, so a
///   NaN payload / signalling bit / `-0.0` round-trips exactly — D5).
/// - Returns a NEW `InstanceState` whose `globals` is `dict.insert`ed (only the named global
///   changes) and whose `mem`/`table` fields are shared by reference — NOT a deep copy (the
///   §10 uniform-threading rule for a mutating op). Total; never raises; touches NO process
///   dictionary. Immutability of `const` globals is a validation property (unit P2-08), not
///   enforced here — this is a mechanical write.
///   (<https://webassembly.github.io/spec/core/exec/instructions.html#variable-instructions>)
pub fn t_global_set(
  st: InstanceState,
  name: String,
  value: Int,
) -> InstanceState {
  InstanceState(..st, globals: dict.insert(st.globals, name, value))
}

/// Project the DEFAULT (index-0) opaque memory value out of the threaded record. READ-ONLY.
///
/// The Phase-4 name, preserved as the index-0 alias of `t_mem_at` for byte-identity (R6).
/// - Returns the default `mem` unchanged — a `Dynamic` `rt_state` never inspects. Total.
pub fn mem(st: InstanceState) -> Dynamic {
  t_mem_at(st, 0)
}

/// Rebind the DEFAULT (index-0) memory field, RETURNING the updated record.
///
/// The Phase-4 name, preserved as the index-0 alias of `t_with_mem_at` for byte-identity.
/// - `mem`: the new opaque memory value. Returns a NEW `InstanceState`. Total; never raises.
pub fn with_mem(st: InstanceState, mem: Dynamic) -> InstanceState {
  t_with_mem_at(st, 0, mem)
}

/// Project the opaque memory value at index `index` out of the threaded record (R6/R7).
/// READ-ONLY. Fail-closed `panic` on an out-of-range index (internal invariant violation).
pub fn t_mem_at(st: InstanceState, index: Int) -> Dynamic {
  nth_or_panic(
    st.mems,
    index,
    "rt_state.t_mem_at: memory index out of range (internal invariant violation)",
  )
}

/// Rebind the memory at index `index` in the threaded record, RETURNING the updated record
/// (R6/R7). Only `index` changes; other memories/fields are shared by reference. An
/// out-of-range `index` is a conservative no-op (09 seeds every live memory index).
pub fn t_with_mem_at(
  st: InstanceState,
  index: Int,
  handle: Dynamic,
) -> InstanceState {
  InstanceState(..st, mems: set_nth(st.mems, index, handle))
}

/// Project the DEFAULT (index-0 / first) opaque table value out of the threaded record.
/// READ-ONLY. The Phase-4 name, preserved as the index-0 alias of `t_table_at` (R6/R7).
pub fn table(st: InstanceState) -> Dynamic {
  t_table_at(st, 0)
}

/// Rebind the DEFAULT (index-0 / first) table field, RETURNING the updated record.
/// The Phase-4 name, preserved as the index-0 alias of `t_with_table_at` for byte-identity.
pub fn with_table(st: InstanceState, table: Dynamic) -> InstanceState {
  t_with_table_at(st, 0, table)
}

/// Project the opaque table value at index `index` out of the threaded record (R7). READ-ONLY.
/// Fail-closed `panic` on an out-of-range index (internal invariant violation).
pub fn t_table_at(st: InstanceState, index: Int) -> Dynamic {
  nth_or_panic(
    st.tables,
    index,
    "rt_state.t_table_at: table index out of range (internal invariant violation)",
  )
}

/// Rebind the table at index `index` in the threaded record, RETURNING the updated record
/// (R7). Only `index` changes; other tables/fields are shared by reference. An out-of-range
/// `index` is a conservative no-op (09 seeds every live table index).
pub fn t_with_table_at(
  st: InstanceState,
  index: Int,
  handle: Dynamic,
) -> InstanceState {
  InstanceState(..st, tables: set_nth(st.tables, index, handle))
}

// ── passive-segment drop state (threaded twins; R2) ───────────────────────────

/// Has passive data segment `seg` been dropped in the threaded record? READ-ONLY (R2).
pub fn t_data_dropped(st: InstanceState, seg: Int) -> Bool {
  set.contains(st.dropped_data, seg)
}

/// Mark passive data segment `seg` dropped in the threaded record, RETURNING it (R2).
/// Idempotent; other fields shared by reference.
pub fn t_drop_data(st: InstanceState, seg: Int) -> InstanceState {
  InstanceState(..st, dropped_data: set.insert(st.dropped_data, seg))
}

/// Has passive element segment `seg` been dropped in the threaded record? READ-ONLY (R2).
pub fn t_elem_dropped(st: InstanceState, seg: Int) -> Bool {
  set.contains(st.dropped_elem, seg)
}

/// Mark passive element segment `seg` dropped in the threaded record, RETURNING it (R2).
/// Idempotent; other fields shared by reference.
pub fn t_drop_elem(st: InstanceState, seg: Int) -> InstanceState {
  InstanceState(..st, dropped_elem: set.insert(st.dropped_elem, seg))
}

// ── boxed non-numeric globals (threaded twins; R8 + S6) ───────────────────────

/// Read boxed global `name`'s value from the threaded record (R8/S6) — a reference or a `v128`
/// (16-byte `BitArray`), as an opaque `Dynamic`. READ-ONLY.
/// Fail-closed `panic` on an undeclared `name` (unreachable post-validation).
pub fn t_ref_global_get(st: InstanceState, name: String) -> Dynamic {
  case dict.get(st.ref_globals, name) {
    Ok(value) -> value
    Error(Nil) ->
      panic as "rt_state.t_ref_global_get: undeclared reference global (internal invariant violation)"
  }
}

/// Rebind boxed global `name` in the threaded record, RETURNING it (R8/S6) — a reference or a
/// `v128` `Dynamic` (stored verbatim; opacity / raw v128 bytes preserved).
/// Only `name` changes; other globals/fields shared by reference.
pub fn t_ref_global_set(
  st: InstanceState,
  name: String,
  value: Dynamic,
) -> InstanceState {
  InstanceState(..st, ref_globals: dict.insert(st.ref_globals, name, value))
}

// ── function-import dispatch vector (threaded twins; S5) ──────────────────────

/// Seed the function-import dispatch vector on the threaded record, RETURNING it (S5) — the
/// `Threaded` twin of `seed_func_imports` (no pdict write). Called once by the threaded
/// `instantiate` (unit 06) immediately after `fresh_full`, only when the module calls an imported
/// function. Only `func_imports` changes; other fields shared by reference.
pub fn set_func_imports(
  st: InstanceState,
  closures: List(Dynamic),
) -> InstanceState {
  InstanceState(..st, func_imports: closures)
}

/// Read the imported-function dispatch closure at `slot` from the threaded record (S5) — the
/// capability a threaded `CallImport(slot, …)` applies via `link.call_import`. READ-ONLY.
/// Out of range `panic`s fail-closed (an internal codegen invariant, never a WASM trap).
pub fn t_func_import_at(st: InstanceState, slot: Int) -> Dynamic {
  nth_or_panic(
    st.func_imports,
    slot,
    "rt_state.t_func_import_at: function-import slot out of range (internal invariant violation)",
  )
}

// ── internal helpers ──────────────────────────────────────────────────────────

/// Materialise the single-memory / single-table / import-free `StateDecl` (the byte-identical
/// Phase-1..4 path) into an `InstanceState`, by widening it to a one-element-vectors `FullDecl`
/// (index 0 = the default memory/table, empty `ref_globals`) and delegating to `build_full`. So
/// BOTH decl shapes share ONE materialisation seam (`build_full`) — a single-region `StateDecl`
/// and the equivalent one-element `FullDecl` produce field-identical records. Total; never
/// raises; touches NO process dictionary (the caller's `seed` does the pdict write, if any).
fn build(decl: StateDecl) -> InstanceState {
  build_full(
    FullDecl(
      mems: [decl.mem],
      globals: decl.globals,
      tables: [decl.table],
      ref_globals: [],
    ),
  )
}

/// The single record builder shared by every seed/fresh path (`seed`/`fresh` via `build`, and
/// `seed_full`/`fresh_full` directly). Sharing ONE constructor guarantees the cell and threaded
/// strategies materialise BYTE-IDENTICAL state (G7 — a `Threaded` build and a `Cell` build compute
/// identical results). Installs the memories/tables vectors verbatim in index order (imported
/// slots already at their low indices, woven by unit 06); `globals`/`ref_globals` become `Dict`s
/// (duplicate names keep the LAST, `dict.from_list` semantics — validation guarantees uniqueness);
/// drop-state starts empty (a fresh instance has dropped no passive segment, R2). Total; never
/// raises; touches NO process dictionary. (Private: the shared materialisation seam.)
fn build_full(decl: FullDecl) -> InstanceState {
  InstanceState(
    mems: decl.mems,
    globals: dict.from_list(decl.globals),
    tables: decl.tables,
    dropped_data: set.new(),
    dropped_elem: set.new(),
    ref_globals: dict.from_list(decl.ref_globals),
    // The function-import dispatch vector starts EMPTY (S5); `emit_core`'s `instantiate` seeds it
    // via `seed_func_imports`/`set_func_imports` immediately after the fresh record is built, and
    // only when the module actually calls an imported function — so a no-imported-call module keeps
    // an empty vector and the whole Phase-1..5 corpus is byte-neutral through this field.
    func_imports: [],
  )
}

/// Read the `index`-th element of `xs`, or `panic` with `msg` if out of range. The fail-closed
/// projection every index accessor goes through — an out-of-range index is an internal
/// invariant violation (the vector is seeded to the live region count), never a normal path.
fn nth_or_panic(xs: List(a), index: Int, msg: String) -> a {
  case list.drop(xs, index) {
    [x, ..] -> x
    [] -> panic as msg
  }
}

/// Return `xs` with its `index`-th element replaced by `value`. An out-of-range `index` leaves
/// `xs` unchanged (a conservative no-op — the keystone vector holds only index 0; unit 09 grows
/// it so every live index exists). Total; never raises.
fn set_nth(xs: List(a), index: Int, value: a) -> List(a) {
  list.index_map(xs, fn(x, i) {
    case i == index {
      True -> value
      False -> x
    }
  })
}

/// Install `state` as this process's cell under the fixed key. The superseded record (if
/// any) becomes garbage. Total; never raises. (Private: the seam between rt_state's public
/// ops and the raw pdict BIF.)
fn put_cell(state: InstanceState) -> Nil {
  let _ = erlang_put(TwocoreRtState, state)
  Nil
}

/// Read this process's cell, FAILING CLOSED on an un-seeded cell. `panic`s a distinct
/// internal error (node-safe) rather than fabricating a zeroed cell — reading garbage out
/// of an empty pdict is the bug the guard prevents. A present cell coerces in O(1) (the
/// term is shared by reference; no deep copy). Private: the single read chokepoint every
/// fail-closed accessor goes through.
fn require_cell() -> InstanceState {
  case read_cell(TwocoreRtState) {
    Ok(state) -> state
    Error(Nil) ->
      panic as "rt_state: operation on an un-seeded instance cell (one-instance-one-process contract violated)"
  }
}
