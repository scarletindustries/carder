//// Runtime differential for an **import-routed funcref** table slot (Phase-14, unit R14-03) — the
//// headline invariant: a table slot holding `#(FuncType, adapter)`, where `adapter` dispatches an
//// IMPORTED function through the D3a func-import capability, **stores, moves under `table.copy`, and
//// dispatches byte-identically across every `{TablePaged, TableEts, TableAtomics} × {Cell, Threaded}`
//// combo**, and honours the three fail-closed `call_indirect` guards IN ORDER. `TablePaged`/Cell is
//// the differential ORACLE; the hand-computed `expected` list in each scenario is the spec anchor
//// (so a shared bug that made all six combos agree WRONGLY is still caught).
////
//// **The adapter, built BY HAND (mirrors R14-02's inline emission, NOT the emit path).** The slot's
//// closure is the exact D3a adapter R2 specifies — it captures ONLY the literal integer `slot`,
//// resolves its target through the func-import vector at DISPATCH time (`rt_state.func_import_at` /
//// `t_func_import_at`), dispatches via the frozen 1-ary `link.call_import` seam (never `erlang:apply`
//// of program data), and RE-PACKAGES `call_import`'s result value LIST into the funcref-slot's
//// `function_return` PACKAGE — the bare value for one result, the dummy atom `'ok'` for zero, an
//// `N`-tuple for `N≥2` — the SAME package-ABI a defined funcref returns, which `rt_table.call_indirect`
//// inverts via `package_to_list`. (Passing the raw list straight through would double-wrap a single
//// result; the Phase-13 funcref-slot ABI is package-ABI, so the reshape is load-bearing.)
////
//// Spec-cited (NOT change-detectors): element segments unify the funcidx space so a `ref.func` of an
//// IMPORTED function is a first-class table-storable reference; an imported function reached via
//// `call_indirect` behaves identically to a direct `call` of that import; `call_indirect` evaluates
//// its three trap conditions in order — undefined element, uninitialized element, indirect call type
//// mismatch; `table.copy` is a reference-preserving memmove.
//// <https://webassembly.github.io/spec/core/exec/instructions.html>,
//// <https://webassembly.github.io/spec/core/exec/modules.html#instantiation>.

import carder/ir.{
  type FuncType, type TrapReason, FuncType, IndirectCallTypeMismatch, TI32,
  UndefinedElement, UninitializedElement,
}
import carder/runtime/link
import carder/runtime/rt_ref
import carder/runtime/rt_state.{type InstanceState, type StateDecl, StateDecl}
import carder/runtime/rt_table.{type RefValue}
import carder/runtime/rt_table_atomics as atomics
import carder/runtime/rt_table_ets as ets
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/list
import gleam/option.{None}
import gleeunit/should

// ── identity coercers for the raw-bit `List(Int) ≡ List(Dynamic)` invariant (D5) ──────────────
//
// A WASM numeric value is a raw bit pattern, which on the BEAM is exactly an Erlang integer, so
// boxing an `Int`/`List(Int)` as a `Dynamic`/`List(Dynamic)` (and back) is a no-op at run time —
// modelled on `link.gleam`'s `coerce_args_to_ints`/`coerce_ints_to_dynamics`. The seam is frozen to
// inline (F3), so these live locally in the test rather than in `link.gleam`.

/// Box any value as an opaque `Dynamic` (identity at run time) — used for the bare-value package and
/// to box a func-import double into the dispatch-vector slot.
@external(erlang, "gleam_stdlib", "identity")
fn to_pkg(v: a) -> Dynamic

/// Coerce a raw-bit argument `List(Int)` (the cell/threaded funcref ABI) to the `List(Dynamic)`
/// `link.call_import` consumes. Identity.
@external(erlang, "gleam_stdlib", "identity")
fn ints_to_dyn(args: List(Int)) -> List(Dynamic)

/// Coerce a `List(Dynamic)` value list back to `List(Int)` (inside a func-import double, so it can do
/// integer arithmetic on the raw bit patterns). Identity.
@external(erlang, "gleam_stdlib", "identity")
fn dyn_to_ints(args: List(Dynamic)) -> List(Int)

/// Coerce an opaque func-import vector slot (`rt_state.func_import_at`) back to the callable dispatch
/// closure `link.call_import` applies. Identity — the vector stores the closure opaquely (D3a).
@external(erlang, "gleam_stdlib", "identity")
fn unbox_import(d: Dynamic) -> fn(List(Dynamic)) -> List(Dynamic)

/// `erlang:list_to_tuple/1` — pack an `N≥2` value list into the multi-result `function_return`
/// tuple `{v1,…,vn}` (the package shape `rt_table.call_indirect` inverts via `tuple_to_list`).
@external(erlang, "erlang", "list_to_tuple")
fn list_to_tuple(xs: List(Dynamic)) -> Dynamic

/// Re-package `call_import`'s result value LIST into the funcref-slot's `function_return` PACKAGE —
/// the EXACT inverse of `rt_table.package_to_list`, mirroring `emit_core.function_return`:
///
/// - `[]` (zero results) → the dummy atom `'ok'` (immaterial — `package_to_list(_, 0)` yields `[]`);
/// - `[v]` (one result) → the BARE value `v`;
/// - `[v1,…,vn]` (`n≥2`) → the `N`-tuple `{v1,…,vn}`.
///
/// This is why the adapter RESHAPES rather than passing the list through: the Phase-13 funcref-slot
/// ABI is package-ABI, so a raw list would double-wrap a single result.
fn list_to_package(results: List(Dynamic)) -> Dynamic {
  case results {
    [] -> to_pkg(atom.create("ok"))
    [single] -> single
    many -> list_to_tuple(many)
  }
}

// ── the hand-built import-routed funcref (the modelled R2 adapter) ────────────────────────────

/// The CELL import adapter — the funcref-slot closure `fn(List(Int)) -> Dynamic`. Captures ONLY the
/// literal `slot`; at DISPATCH time it reads the func-import capability (`rt_state.func_import_at`),
/// dispatches via `link.call_import` (never `apply/3`, D3a), and re-packages the result list into the
/// slot's package (see `list_to_package`). This is the SAME `#(FuncType, adapter)` value R14-02 emits
/// inline for a `ref.func` of an imported function, built here by hand.
fn cell_import_ref(slot: Int, ty: FuncType) -> RefValue {
  rt_table.funcref(ty, fn(args: List(Int)) -> Dynamic {
    let closure = unbox_import(rt_state.func_import_at(slot))
    list_to_package(link.call_import(closure, ints_to_dyn(args)))
  })
}

/// The THREADED import adapter — `fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState)`. Reads
/// the func-import capability from the DISPATCH-time `st` (`rt_state.t_func_import_at`) and threads
/// `st` through UNCHANGED (the imported callee threads its own state inside the routing closure),
/// exactly as R2's threaded adapter. The stored funcref stays pure — `st` is the closure's parameter.
fn threaded_import_ref(slot: Int, ty: FuncType) -> RefValue {
  rt_table.funcref_t(ty, fn(st: InstanceState, args: List(Int)) -> #(
    Dynamic,
    InstanceState,
  ) {
    let closure = unbox_import(rt_state.t_func_import_at(st, slot))
    #(list_to_package(link.call_import(closure, ints_to_dyn(args))), st)
  })
}

/// A DEFINED (non-import) funcref of type `ty` computing `[a, b] -> a + b` (cell ABI) — coexists in
/// the same table as an import-routed funcref (the mixed-segment shape `table_copy.1.wasm` builds), so
/// `table.copy` moves both. Returns the package DIRECTLY (defined funcrefs do not route through
/// `call_import`). Only ever used with `ii_i()`.
fn cell_defined_ref(ty: FuncType) -> RefValue {
  rt_table.funcref(ty, fn(args) {
    case args {
      [a, b] -> to_pkg(a + b)
      _ -> panic as "cell_defined_ref: expected 2 args"
    }
  })
}

/// The threaded twin of `cell_defined_ref` — `fn(st, [a, b]) -> #(package(a + b), st)`.
fn threaded_defined_ref(ty: FuncType) -> RefValue {
  rt_table.funcref_t(ty, fn(st, args) {
    case args {
      [a, b] -> #(to_pkg(a + b), st)
      _ -> panic as "threaded_defined_ref: expected 2 args"
    }
  })
}

// ── the func-import doubles (the "imported" functions), `fn(List(Dynamic)) -> List(Dynamic)` ──────
//
// The `link.call_import` / `ProvidedFunc.call` ABI: a value list in, a value list out. Seeded into
// the func-import dispatch vector via `rt_state.seed_func_imports` / `set_func_imports`.

/// `a.add : (i32, i32) -> i32` — `[a, b] -> [a + b]`. The slot-0 double.
fn add_double() -> fn(List(Dynamic)) -> List(Dynamic) {
  fn(args) {
    case dyn_to_ints(args) {
      [a, b] -> ints_to_dyn([a + b])
      _ -> panic as "add_double: expected 2 args"
    }
  }
}

/// `a.dbl : (i32) -> i32` — `[a] -> [a * 2]`. The slot-1 double (distinct type, so `slot == funcidx`
/// for `slot >= 1` is exercised and guard 3 has a genuine mismatch to reject).
fn dbl_double() -> fn(List(Dynamic)) -> List(Dynamic) {
  fn(args) {
    case dyn_to_ints(args) {
      [a] -> ints_to_dyn([a * 2])
      _ -> panic as "dbl_double: expected 1 arg"
    }
  }
}

/// `a.sub : (i32, i32) -> i32` — `[a, b] -> [a - b]`. Re-seeded over slot 0 to prove D3a late-binding.
fn sub_double() -> fn(List(Dynamic)) -> List(Dynamic) {
  fn(args) {
    case dyn_to_ints(args) {
      [a, b] -> ints_to_dyn([a - b])
      _ -> panic as "sub_double: expected 2 args"
    }
  }
}

/// A ZERO-result import `(i32) -> ()` — `[_] -> []`. Exercises the `'ok'` package branch.
fn ret0_double() -> fn(List(Dynamic)) -> List(Dynamic) {
  fn(args) {
    case dyn_to_ints(args) {
      [_a] -> ints_to_dyn([])
      _ -> panic as "ret0_double: expected 1 arg"
    }
  }
}

/// A ONE-result import `(i32) -> i32` — `[a] -> [a]`. Exercises the bare-value package branch.
fn ret1_double() -> fn(List(Dynamic)) -> List(Dynamic) {
  fn(args) {
    case dyn_to_ints(args) {
      [a] -> ints_to_dyn([a])
      _ -> panic as "ret1_double: expected 1 arg"
    }
  }
}

/// A TWO-result import `(i32) -> (i32, i32)` — `[a] -> [a, a + 1]`. Exercises the `N`-tuple package
/// branch (multi-value funcref dispatch at the runtime layer).
fn ret2_double() -> fn(List(Dynamic)) -> List(Dynamic) {
  fn(args) {
    case dyn_to_ints(args) {
      [a] -> ints_to_dyn([a, a + 1])
      _ -> panic as "ret2_double: expected 1 arg"
    }
  }
}

// ── the structural function types (the funcref tag + call-site expected type, R2 guard-3) ─────────

fn ii_i() -> FuncType {
  FuncType([TI32, TI32], [TI32])
}

fn i_i() -> FuncType {
  FuncType([TI32], [TI32])
}

/// `(i32) -> ()` — a zero-result type.
fn i_void() -> FuncType {
  FuncType([TI32], [])
}

/// `(i32) -> (i32, i32)` — a two-result type.
fn i_ii() -> FuncType {
  FuncType([TI32], [TI32, TI32])
}

// ── the strategy-neutral op-trace + reference descriptors ─────────────────────────────────────

/// A strategy-neutral reference-value descriptor, materialised per strategy (the funcref value shape
/// is tier-agnostic — `TableEts`/`TableAtomics` store the same `#(FuncType, closure)` — but the cell
/// vs threaded closure ABI differs).
type Ref {
  /// An import-routed funcref: the adapter over func-import `slot`, tagged `ty`.
  ImportRef(slot: Int, ty: FuncType)
  /// A defined (non-import) funcref of type `ty` (an `[a, b] -> a + b` add).
  DefinedRef(ty: FuncType)
  /// The null sentinel (an absent slot).
  NullRef
}

/// One step of a scenario. Write ops (`WSet`/`WInit`/`WCopy`) and `Reseed` mutate the table / vector;
/// `Call` runs a `call_indirect` and contributes its normalised outcome to the collected trace.
type Op {
  /// `set(0, index, ref)` — the mutating write path.
  WSet(index: Int, ref: Ref)
  /// `init_elem_ref(0, offset, refs)` — the active-segment write path.
  WInit(offset: Int, refs: List(Ref))
  /// `table.copy` within table 0: `copy(dst, src, count)`.
  WCopy(dst: Int, src: Int, count: Int)
  /// Re-seed the func-import dispatch vector with new doubles (D3a late-binding).
  Reseed(doubles: List(fn(List(Dynamic)) -> List(Dynamic)))
  /// `call_indirect(index, ty, args)` — collects one normalised `Out`.
  Call(index: Int, ty: FuncType, args: List(Int))
}

/// The normalised per-`Call` outcome, comparable across ALL six combos: a threaded
/// `t_call_indirect`'s `#(results, st)` is projected to just `results`, so both strategies share the
/// `Result(List(Int), TrapReason)` shape.
type Out =
  Result(List(Int), TrapReason)

fn materialize_cell(ref: Ref) -> RefValue {
  case ref {
    ImportRef(slot, ty) -> cell_import_ref(slot, ty)
    DefinedRef(ty) -> cell_defined_ref(ty)
    NullRef -> rt_ref.null_ref()
  }
}

fn materialize_threaded(ref: Ref) -> RefValue {
  case ref {
    ImportRef(slot, ty) -> threaded_import_ref(slot, ty)
    DefinedRef(ty) -> threaded_defined_ref(ty)
    NullRef -> rt_ref.null_ref()
  }
}

// ── the tier drivers (one per table tier; `TablePaged` = the oracle) ──────────────────────────

/// The cell-strategy surface of one table tier (index-0 table) — the functions a scenario drives.
type CellTier {
  CellTier(
    new: fn(Int) -> Dynamic,
    init_elem_ref: fn(Int, Int, List(RefValue)) -> Result(Nil, TrapReason),
    set: fn(Int, Int, RefValue) -> Result(Nil, TrapReason),
    table_copy: fn(Int, Int, Int, Int, Int) -> Result(Nil, TrapReason),
    call: fn(Int, FuncType, List(Int)) -> Result(List(Int), TrapReason),
  )
}

/// The threaded-strategy surface of one table tier — each op threads the `InstanceState`.
type ThreadedTier {
  ThreadedTier(
    new: fn(Int) -> Dynamic,
    init_elem_ref: fn(InstanceState, Int, Int, List(RefValue)) ->
      Result(InstanceState, TrapReason),
    set: fn(InstanceState, Int, Int, RefValue) ->
      Result(InstanceState, TrapReason),
    table_copy: fn(InstanceState, Int, Int, Int, Int, Int) ->
      Result(InstanceState, TrapReason),
    call: fn(InstanceState, Int, FuncType, List(Int)) ->
      Result(#(List(Int), InstanceState), TrapReason),
  )
}

fn paged_cell() -> CellTier {
  CellTier(
    new: fn(n) { rt_table.new(n, None) },
    init_elem_ref: rt_table.init_elem_ref,
    set: rt_table.set,
    table_copy: rt_table.table_copy,
    call: rt_table.call_indirect,
  )
}

fn ets_cell() -> CellTier {
  CellTier(
    new: fn(n) { ets.new(n, None) },
    init_elem_ref: ets.init_elem_ref,
    set: ets.set,
    table_copy: ets.table_copy,
    call: ets.call_indirect,
  )
}

fn atomics_cell() -> CellTier {
  CellTier(
    new: fn(n) { atomics.new(n, None) },
    init_elem_ref: atomics.init_elem_ref,
    set: atomics.set,
    table_copy: atomics.table_copy,
    call: atomics.call_indirect,
  )
}

fn paged_threaded() -> ThreadedTier {
  ThreadedTier(
    new: fn(n) { rt_table.new(n, None) },
    init_elem_ref: rt_table.t_init_elem_ref,
    set: rt_table.t_set,
    table_copy: rt_table.t_table_copy,
    call: rt_table.t_call_indirect,
  )
}

fn ets_threaded() -> ThreadedTier {
  ThreadedTier(
    new: fn(n) { ets.new(n, None) },
    init_elem_ref: ets.t_init_elem_ref,
    set: ets.t_set,
    table_copy: ets.t_table_copy,
    call: ets.t_call_indirect,
  )
}

fn atomics_threaded() -> ThreadedTier {
  ThreadedTier(
    new: fn(n) { atomics.new(n, None) },
    init_elem_ref: atomics.t_init_elem_ref,
    set: atomics.t_set,
    table_copy: atomics.t_table_copy,
    call: atomics.t_call_indirect,
  )
}

// ── the six-combo runner ──────────────────────────────────────────────────────────────────────

fn decl(table: Dynamic) -> StateDecl {
  StateDecl(mem: dynamic.nil(), globals: [], table: table)
}

/// Run a scenario on a CELL tier: seed a fresh index-0 table of `size` + the func-import vector, then
/// fold the ops, collecting the normalised `Out` of each `Call`.
fn run_cell(
  tier: CellTier,
  imports: List(fn(List(Dynamic)) -> List(Dynamic)),
  size: Int,
  ops: List(Op),
) -> List(Out) {
  rt_state.seed(decl(tier.new(size)))
  rt_state.seed_func_imports(list.map(imports, to_pkg))
  cell_loop(tier, ops, [])
}

fn cell_loop(tier: CellTier, ops: List(Op), acc: List(Out)) -> List(Out) {
  case ops {
    [] -> list.reverse(acc)
    [op, ..rest] -> {
      let acc2 = case op {
        WSet(i, ref) -> {
          let assert Ok(Nil) = tier.set(0, i, materialize_cell(ref))
          acc
        }
        WInit(off, refs) -> {
          let assert Ok(Nil) =
            tier.init_elem_ref(0, off, list.map(refs, materialize_cell))
          acc
        }
        WCopy(d, s, n) -> {
          let assert Ok(Nil) = tier.table_copy(0, 0, d, s, n)
          acc
        }
        Reseed(doubles) -> {
          rt_state.seed_func_imports(list.map(doubles, to_pkg))
          acc
        }
        Call(i, ty, args) -> [tier.call(i, ty, args), ..acc]
      }
      cell_loop(tier, rest, acc2)
    }
  }
}

/// Run a scenario on a THREADED tier: build a fresh `InstanceState` (index-0 table of `size` + the
/// func-import vector) and thread it through the ops, collecting each `Call`'s normalised `Out`.
fn run_threaded(
  tier: ThreadedTier,
  imports: List(fn(List(Dynamic)) -> List(Dynamic)),
  size: Int,
  ops: List(Op),
) -> List(Out) {
  let st = rt_state.fresh(decl(tier.new(size)))
  let st = rt_state.set_func_imports(st, list.map(imports, to_pkg))
  threaded_loop(tier, ops, st, [])
}

fn threaded_loop(
  tier: ThreadedTier,
  ops: List(Op),
  st: InstanceState,
  acc: List(Out),
) -> List(Out) {
  case ops {
    [] -> list.reverse(acc)
    [op, ..rest] -> {
      let #(st2, acc2) = case op {
        WSet(i, ref) -> {
          let assert Ok(s) = tier.set(st, 0, i, materialize_threaded(ref))
          #(s, acc)
        }
        WInit(off, refs) -> {
          let assert Ok(s) =
            tier.init_elem_ref(st, 0, off, list.map(refs, materialize_threaded))
          #(s, acc)
        }
        WCopy(d, s, n) -> {
          let assert Ok(s2) = tier.table_copy(st, 0, 0, d, s, n)
          #(s2, acc)
        }
        Reseed(doubles) -> #(
          rt_state.set_func_imports(st, list.map(doubles, to_pkg)),
          acc,
        )
        Call(i, ty, args) ->
          case tier.call(st, i, ty, args) {
            Ok(#(rs, s)) -> #(s, [Ok(rs), ..acc])
            Error(e) -> #(st, [Error(e), ..acc])
          }
      }
      threaded_loop(tier, rest, st2, acc2)
    }
  }
}

/// Run `ops` (seeded with `imports`, table size `size`) through ALL SIX combos and assert every combo
/// yields the identical `Out` trace AND that the `TablePaged`/Cell ORACLE equals the hand-computed
/// spec `expected` — the six-way differential + the spec-oracle anchor folded into one assertion.
fn assert_six(
  imports: List(fn(List(Dynamic)) -> List(Dynamic)),
  size: Int,
  ops: List(Op),
  expected: List(Out),
) -> Nil {
  let oracle = run_cell(paged_cell(), imports, size, ops)
  // Oracle == spec (defeats "all six agree WRONGLY").
  oracle |> should.equal(expected)
  // The other five combos == oracle.
  oracle |> should.equal(run_cell(ets_cell(), imports, size, ops))
  oracle |> should.equal(run_cell(atomics_cell(), imports, size, ops))
  oracle |> should.equal(run_threaded(paged_threaded(), imports, size, ops))
  oracle |> should.equal(run_threaded(ets_threaded(), imports, size, ops))
  oracle |> should.equal(run_threaded(atomics_threaded(), imports, size, ops))
}

// ══════════════════════════ the scenarios ══════════════════════════

/// **Dispatch equivalence + the three fail-closed guards, in spec order, on import-routed slots.**
/// An import-routed funcref dispatches to its imported function on all six combos; guard 1
/// (`UndefinedElement`, index checked first), guard 2 (`UninitializedElement`, never-written and
/// null-deleted slots), and guard 3 (`IndirectCallTypeMismatch`, both directions) each fire. Slot 1
/// (`a.dbl`) exercises `slot == funcidx` for `slot >= 1` (R4). *Spec:* an imported function reached
/// via `call_indirect` behaves as a direct `call` of that import; the three trap conditions evaluate
/// in order.
pub fn dispatch_and_guards_all_six_test() {
  assert_six(
    [add_double(), dbl_double()],
    4,
    [
      // slot 1 = import-routed add (ii_i); slot 2 = import-routed dbl (i_i).
      WSet(1, ImportRef(0, ii_i())),
      WSet(2, ImportRef(1, i_i())),
      // dispatch: add and dbl (the slot-1 double, R4).
      Call(1, ii_i(), [3, 4]),
      Call(2, i_i(), [5]),
      // guard 1 — index >= size, and negative; fires before null/type.
      Call(4, ii_i(), [3, 4]),
      Call(-1, ii_i(), [3, 4]),
      // guard 2 — a never-written in-range slot.
      Call(0, ii_i(), [3, 4]),
      // guard 3 — both directions (store ii_i call i_i; store i_i call ii_i).
      Call(1, i_i(), [3]),
      Call(2, ii_i(), [3, 4]),
      // guard 2 — an import-routed funcref deleted by a ref.null write reads absent.
      WSet(2, NullRef),
      Call(2, i_i(), [5]),
    ],
    [
      Ok([7]),
      Ok([10]),
      Error(UndefinedElement),
      Error(UndefinedElement),
      Error(UninitializedElement),
      Error(IndirectCallTypeMismatch),
      Error(IndirectCallTypeMismatch),
      Error(UninitializedElement),
    ],
  )
}

/// **Dispatch equals a direct `call_import` of the same import** (the spec oracle for equivalence),
/// and the ACTIVE-segment write path (`init_elem_ref`) agrees with the MUTATING path (`set`). On the
/// `TablePaged`/Cell oracle. *Spec:* imported-fn-via-`call_indirect` ≡ direct `call` of the import.
pub fn dispatch_equals_direct_and_write_paths_agree_test() {
  // A direct call of the imported function.
  rt_state.seed(decl(rt_table.new(2, None)))
  rt_state.seed_func_imports([to_pkg(add_double())])
  let direct =
    dyn_to_ints(link.call_import(
      unbox_import(rt_state.func_import_at(0)),
      ints_to_dyn([3, 4]),
    ))
  direct |> should.equal([7])

  // The MUTATING write path.
  rt_state.seed(decl(rt_table.new(2, None)))
  rt_state.seed_func_imports([to_pkg(add_double())])
  let assert Ok(Nil) = rt_table.set(0, 1, cell_import_ref(0, ii_i()))
  let via_set = rt_table.call_indirect(1, ii_i(), [3, 4])
  // Dispatched == direct.
  via_set |> should.equal(Ok(direct))

  // The ACTIVE-segment write path agrees.
  rt_state.seed(decl(rt_table.new(2, None)))
  rt_state.seed_func_imports([to_pkg(add_double())])
  let assert Ok(Nil) =
    rt_table.init_elem_ref(0, 1, [cell_import_ref(0, ii_i())])
  let via_init = rt_table.call_indirect(1, ii_i(), [3, 4])
  via_init |> should.equal(via_set)
}

/// **`table.copy` (ascending, overlapping) preserves dispatchability + the guard behaviour.** An
/// import-routed funcref and a defined funcref coexist (the mixed-segment shape `table_copy.1.wasm`
/// builds); an overlapping ascending `copy(0, 1, 3)` relocates the import-routed funcref to slot 0
/// and the null hole to slot 1. Across all six: the copied import-routed reference still dispatches
/// (reference-preserving), the vacated slot traps `UninitializedElement`, an OOB index traps
/// `UndefinedElement`, and the wrong type traps `IndirectCallTypeMismatch`. *Spec:* `table.copy` is a
/// reference-preserving memmove; guards evaluate on each slot's post-copy contents.
pub fn table_copy_ascending_preserves_dispatch_all_six_test() {
  assert_six(
    [add_double(), dbl_double()],
    5,
    [
      // slot 1 = import-routed add; slot 2 = null hole; slot 3 = defined add.
      WSet(1, ImportRef(0, ii_i())),
      WSet(3, DefinedRef(ii_i())),
      // ascending overlap: source [1,2,3] = [import-add, null, defined] -> dst [0,1,2].
      WCopy(0, 1, 3),
      // import-routed reference preserved at its new slot 0.
      Call(0, ii_i(), [3, 4]),
      // the null (moved from slot 2) vacated slot 1.
      Call(1, ii_i(), [3, 4]),
      // the defined funcref preserved at its new slot 2, and untouched at slot 3.
      Call(2, ii_i(), [10, 20]),
      Call(3, ii_i(), [10, 20]),
      // guard 1 (index == size) and guard 3 (slot 0 is ii_i) after the shuffle.
      Call(5, ii_i(), [3, 4]),
      Call(0, i_i(), [3]),
    ],
    [
      Ok([7]),
      Error(UninitializedElement),
      Ok([30]),
      Ok([30]),
      Error(UndefinedElement),
      Error(IndirectCallTypeMismatch),
    ],
  )
}

/// **`table.copy` (descending, overlapping) is memmove-correct for import-routed slots.** A
/// descending overlapping `copy(2, 1, 3)` (dst > src) relocates the import-routed funcref to slot 2
/// while leaving its source slot 1 intact, moves the defined funcref to slot 3, and moves a null hole
/// to slot 4. Exact post-copy contents (a naive in-place forward smear would corrupt them) are
/// asserted across all six. *Spec:* `table.copy` snapshots the source slice before writing (memmove).
pub fn table_copy_descending_preserves_dispatch_all_six_test() {
  assert_six(
    [add_double(), dbl_double()],
    5,
    [
      // slot 1 = import-routed add; slot 2 = defined add; slot 3 = null hole.
      WSet(1, ImportRef(0, ii_i())),
      WSet(2, DefinedRef(ii_i())),
      // descending overlap: source [1,2,3] = [import-add, defined, null] -> dst [2,3,4].
      WCopy(2, 1, 3),
      // import-routed reference at its new slot 2, and still intact at source slot 1.
      Call(2, ii_i(), [3, 4]),
      Call(1, ii_i(), [3, 4]),
      // defined funcref at its new slot 3.
      Call(3, ii_i(), [10, 20]),
      // the null hole moved to slot 4, and slot 0 was never written.
      Call(4, ii_i(), [3, 4]),
      Call(0, ii_i(), [3, 4]),
      // guard 1 — index == size.
      Call(5, ii_i(), [3, 4]),
    ],
    [
      Ok([7]),
      Ok([7]),
      Ok([30]),
      Error(UninitializedElement),
      Error(UninitializedElement),
      Error(UndefinedElement),
    ],
  )
}

/// **D3a late-binding — the adapter captures only the literal slot integer.** A stable stored funcref
/// first dispatches to `a.add`; re-seeding the func-import vector so slot 0 now holds `a.sub` — WITHOUT
/// touching the stored funcref — makes the SAME funcref dispatch to the new import. Across all six.
/// *Proves* the closure holds only `slot` and resolves its target through the capability vector at
/// dispatch time (never a baked `module:atom`).
pub fn d3a_late_binding_reseed_all_six_test() {
  assert_six(
    [add_double(), dbl_double()],
    4,
    [
      WSet(1, ImportRef(0, ii_i())),
      // dispatches to a.add.
      Call(1, ii_i(), [3, 4]),
      // re-seed slot 0 with a.sub; the stored funcref is untouched.
      Reseed([sub_double(), dbl_double()]),
      // the SAME funcref now dispatches to a.sub (3 - 4 = -1).
      Call(1, ii_i(), [3, 4]),
    ],
    [Ok([7]), Ok([-1])],
  )
}

/// **The package-ABI reshape is correct for every result arity.** Import-routed funcrefs of a zero-,
/// one-, and two-result import each dispatch to the spec result list across all six combos — proving
/// the adapter's `list -> package` reshape (`'ok'` / bare value / `N`-tuple) exactly inverts
/// `rt_table.call_indirect`'s `package_to_list`. *Spec:* multi-value result vectors round-trip
/// through the funcref-slot ABI.
pub fn package_abi_reshape_all_arities_all_six_test() {
  assert_six(
    [ret0_double(), ret1_double(), ret2_double()],
    4,
    [
      WSet(0, ImportRef(0, i_void())),
      WSet(1, ImportRef(1, i_i())),
      WSet(2, ImportRef(2, i_ii())),
      // 0 results -> 'ok' package -> [].
      Call(0, i_void(), [5]),
      // 1 result -> bare package -> [5].
      Call(1, i_i(), [5]),
      // 2 results -> tuple package -> [5, 6].
      Call(2, i_ii(), [5]),
    ],
    [Ok([]), Ok([5]), Ok([5, 6])],
  )
}
