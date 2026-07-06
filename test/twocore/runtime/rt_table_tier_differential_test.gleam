//// Tier differential for the funcref-table backends (unit P4-06, §F) — the headline invariant:
//// **`call_indirect` behaviour is byte-identical across every tier** (`TablePaged` ≡ `TableEts` ≡
//// `TableAtomics`). `TablePaged` (the immutable-`Dict` implementation, trivially correct) is the
//// ORACLE, the table analog of `rt_mem`'s flat-binary `rebuild` oracle (E4/§11).
////
//// One shared op-trace — `new(size)`; in-range and OOB `init_elem` segments; `call_indirect` at
//// OOB, null, wrong-type, and right-type indices — is driven through each tier and, after every
//// op, asserted to produce the identical returned value / `Ok`/`Error(reason)` AND the identical
//// `to_canon` type-tag image (<https://webassembly.github.io/spec/core/exec/instructions.html>).
//// Run through BOTH state strategies: the threaded heads in lockstep (three `InstanceState`s
//// stepped together), and the cell heads (each tier's whole trace collected then compared).

import gleam/dynamic
import gleam/list
import gleam/option.{type Option, None}
import gleeunit/should
import twocore/ir.{type FuncType, type TrapReason, FuncType, TI32}
import twocore/runtime/rt_state.{type InstanceState, StateDecl}
import twocore/runtime/rt_table
import twocore/runtime/rt_table_atomics as atom
import twocore/runtime/rt_table_ets as ets

/// Box a value as the package `Dynamic` a Phase-13 funcref closure returns (identity at run time).
@external(erlang, "gleam_stdlib", "identity")
fn to_pkg(v: a) -> dynamic.Dynamic

/// The size of every table in the trace.
const size: Int = 4

fn ii_i() -> FuncType {
  FuncType([TI32, TI32], [TI32])
}

fn id_i() -> FuncType {
  FuncType([TI32], [TI32])
}

// ── the outcome of one op, comparable across tiers (closures/`st` are not comparable) ──

type OpOut {
  InitOut(Result(Nil, TrapReason))
  CallOut(Result(List(Int), TrapReason))
}

// ══════════════════════════ THREADED lockstep differential ══════════════════════════

/// A threaded op (closures are the threaded ABI).
type TOp {
  TInit(
    offset: Int,
    entries: List(
      #(
        FuncType,
        fn(InstanceState, List(Int)) -> #(dynamic.Dynamic, InstanceState),
      ),
    ),
  )
  TCall(index: Int, expected: FuncType, args: List(Int))
}

fn t_add() -> fn(InstanceState, List(Int)) -> #(dynamic.Dynamic, InstanceState) {
  fn(st, args) {
    case args {
      [a, b] -> #(to_pkg(a + b), st)
      _ -> panic as "t_add"
    }
  }
}

fn t_id() -> fn(InstanceState, List(Int)) -> #(dynamic.Dynamic, InstanceState) {
  fn(st, args) {
    case args {
      [a] -> #(to_pkg(a), st)
      _ -> panic as "t_id"
    }
  }
}

/// The shared threaded op-trace: fill 0/1, an OOB segment (no write), the four dispatch outcomes,
/// then a later fill + call.
fn threaded_trace() -> List(TOp) {
  [
    TInit(0, [#(ii_i(), t_add()), #(id_i(), t_id())]),
    TInit(4, [#(ii_i(), t_add())]),
    // offset == size: OOB, writes nothing
    TCall(0, ii_i(), [3, 4]),
    // right type
    TCall(1, id_i(), [9]),
    // right type
    TCall(2, ii_i(), [1, 2]),
    // null slot
    TCall(4, ii_i(), [1, 2]),
    // OOB index
    TCall(-1, ii_i(), [1, 2]),
    // negative index
    TCall(0, id_i(), [1]),
    // wrong type (params differ)
    TInit(2, [#(id_i(), t_id())]),
    TCall(2, id_i(), [5]),
  ]
}

fn drive_paged(st: InstanceState, op: TOp) -> #(InstanceState, OpOut) {
  case op {
    TInit(off, es) ->
      case rt_table.t_init_elem(st, off, es) {
        Ok(st2) -> #(st2, InitOut(Ok(Nil)))
        Error(e) -> #(st, InitOut(Error(e)))
      }
    TCall(i, ty, args) ->
      case rt_table.t_call_indirect(st, i, ty, args) {
        Ok(#(rs, st2)) -> #(st2, CallOut(Ok(rs)))
        Error(e) -> #(st, CallOut(Error(e)))
      }
  }
}

fn drive_ets(st: InstanceState, op: TOp) -> #(InstanceState, OpOut) {
  case op {
    TInit(off, es) ->
      case ets.t_init_elem(st, off, es) {
        Ok(st2) -> #(st2, InitOut(Ok(Nil)))
        Error(e) -> #(st, InitOut(Error(e)))
      }
    TCall(i, ty, args) ->
      case ets.t_call_indirect(st, i, ty, args) {
        Ok(#(rs, st2)) -> #(st2, CallOut(Ok(rs)))
        Error(e) -> #(st, CallOut(Error(e)))
      }
  }
}

fn drive_atomics(st: InstanceState, op: TOp) -> #(InstanceState, OpOut) {
  case op {
    TInit(off, es) ->
      case atom.t_init_elem(st, off, es) {
        Ok(st2) -> #(st2, InitOut(Ok(Nil)))
        Error(e) -> #(st, InitOut(Error(e)))
      }
    TCall(i, ty, args) ->
      case atom.t_call_indirect(st, i, ty, args) {
        Ok(#(rs, st2)) -> #(st2, CallOut(Ok(rs)))
        Error(e) -> #(st, CallOut(Error(e)))
      }
  }
}

fn fresh(table: dynamic.Dynamic) -> InstanceState {
  rt_state.fresh(StateDecl(mem: dynamic.nil(), globals: [], table: table))
}

/// Step the three threaded tiers together, asserting identical value/trap AND identical
/// `to_canon` image after each op.
pub fn threaded_tiers_are_identical_test() {
  threaded_loop(
    threaded_trace(),
    fresh(rt_table.new(size, None)),
    fresh(ets.new(size, None)),
    fresh(atom.new(size, None)),
  )
}

fn threaded_loop(
  ops: List(TOp),
  sp: InstanceState,
  se: InstanceState,
  sa: InstanceState,
) -> Nil {
  case ops {
    [] -> Nil
    [op, ..rest] -> {
      let #(sp2, out_p) = drive_paged(sp, op)
      let #(se2, out_e) = drive_ets(se, op)
      let #(sa2, out_a) = drive_atomics(sa, op)
      // The security boundary: all three agree on value AND trap, every step.
      out_p |> should.equal(out_e)
      out_p |> should.equal(out_a)
      // And the whole slot type-tag image is identical, every step.
      let canon_p = rt_table.to_canon(rt_state.table(sp2))
      canon_p |> should.equal(ets.to_canon(rt_state.table(se2)))
      canon_p |> should.equal(atom.to_canon(rt_state.table(sa2)))
      threaded_loop(rest, sp2, se2, sa2)
    }
  }
}

// ══════════════════════════ CELL differential ══════════════════════════

/// A cell op (closures are the cell ABI).
type COp {
  CInit(
    offset: Int,
    entries: List(#(FuncType, fn(List(Int)) -> dynamic.Dynamic)),
  )
  CCall(index: Int, expected: FuncType, args: List(Int))
}

fn c_add() -> fn(List(Int)) -> dynamic.Dynamic {
  fn(args) {
    case args {
      [a, b] -> to_pkg(a + b)
      _ -> panic as "c_add"
    }
  }
}

fn c_id() -> fn(List(Int)) -> dynamic.Dynamic {
  fn(args) {
    case args {
      [a] -> to_pkg(a)
      _ -> panic as "c_id"
    }
  }
}

fn cell_trace() -> List(COp) {
  [
    CInit(0, [#(ii_i(), c_add()), #(id_i(), c_id())]),
    CInit(4, [#(ii_i(), c_add())]),
    CCall(0, ii_i(), [3, 4]),
    CCall(1, id_i(), [9]),
    CCall(2, ii_i(), [1, 2]),
    CCall(4, ii_i(), [1, 2]),
    CCall(-1, ii_i(), [1, 2]),
    CCall(0, id_i(), [1]),
    CInit(2, [#(id_i(), c_id())]),
    CCall(2, id_i(), [5]),
  ]
}

/// Run a tier's whole cell trace, collecting `#(OpOut, canon)` after each op. The `seed`, `init`,
/// `call`, and `canon` functions select the tier; the cell already holds this tier's table after
/// `seed`.
fn collect_cell(
  seed: fn() -> Nil,
  init: fn(Int, List(#(FuncType, fn(List(Int)) -> dynamic.Dynamic))) ->
    Result(Nil, TrapReason),
  call: fn(Int, FuncType, List(Int)) -> Result(List(Int), TrapReason),
  canon: fn() -> List(Option(FuncType)),
  ops: List(COp),
) -> List(#(OpOut, List(Option(FuncType)))) {
  seed()
  collect_loop(init, call, canon, ops, [])
}

fn collect_loop(
  init: fn(Int, List(#(FuncType, fn(List(Int)) -> dynamic.Dynamic))) ->
    Result(Nil, TrapReason),
  call: fn(Int, FuncType, List(Int)) -> Result(List(Int), TrapReason),
  canon: fn() -> List(Option(FuncType)),
  ops: List(COp),
  acc: List(#(OpOut, List(Option(FuncType)))),
) -> List(#(OpOut, List(Option(FuncType)))) {
  case ops {
    [] -> list.reverse(acc)
    [op, ..rest] -> {
      let out = case op {
        CInit(off, es) -> InitOut(init(off, es))
        CCall(i, ty, args) -> CallOut(call(i, ty, args))
      }
      collect_loop(init, call, canon, rest, [#(out, canon()), ..acc])
    }
  }
}

fn seed_cell(table: dynamic.Dynamic) -> Nil {
  rt_state.seed(StateDecl(mem: dynamic.nil(), globals: [], table: table))
}

/// Each tier's cell trace produces the IDENTICAL `#(OpOut, canon)` sequence — `TablePaged` oracle
/// vs `TableEts` vs `TableAtomics`.
pub fn cell_tiers_are_identical_test() {
  let paged =
    collect_cell(
      fn() { seed_cell(rt_table.new(size, None)) },
      rt_table.init_elem,
      rt_table.call_indirect,
      fn() { rt_table.to_canon(rt_state.table_get()) },
      cell_trace(),
    )
  let ets =
    collect_cell(
      fn() { seed_cell(ets.new(size, None)) },
      ets.init_elem,
      ets.call_indirect,
      fn() { ets.to_canon(rt_state.table_get()) },
      cell_trace(),
    )
  let atomics =
    collect_cell(
      fn() { seed_cell(atom.new(size, None)) },
      atom.init_elem,
      atom.call_indirect,
      fn() { atom.to_canon(rt_state.table_get()) },
      cell_trace(),
    )
  paged |> should.equal(ets)
  paged |> should.equal(atomics)
}

/// Sanity anchor on the ORACLE: the exact expected `OpOut` sequence for the trace, so a shared
/// bug that made all three tiers agree WRONGLY would still be caught (the differential alone only
/// proves equality, not correctness).
pub fn oracle_trace_matches_spec_test() {
  let paged =
    collect_cell(
      fn() { seed_cell(rt_table.new(size, None)) },
      rt_table.init_elem,
      rt_table.call_indirect,
      fn() { rt_table.to_canon(rt_state.table_get()) },
      cell_trace(),
    )
  let outs = list.map(paged, fn(pair) { pair.0 })
  outs
  |> should.equal([
    // fill 0/1
    InitOut(Ok(Nil)),
    // OOB segment (offset == size) writes nothing
    InitOut(Error(ir.TableOutOfBounds)),
    // right-type calls
    CallOut(Ok([7])),
    CallOut(Ok([9])),
    // null slot
    CallOut(Error(ir.UninitializedElement)),
    // OOB indices (bounds fires first)
    CallOut(Error(ir.UndefinedElement)),
    CallOut(Error(ir.UndefinedElement)),
    // wrong type
    CallOut(Error(ir.IndirectCallTypeMismatch)),
    // later fill + call
    InitOut(Ok(Nil)),
    CallOut(Ok([5])),
  ])
}
