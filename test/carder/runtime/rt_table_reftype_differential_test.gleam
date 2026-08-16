//// Tier differential for the Phase-5 reference/bulk table surface (unit P5-07, §H) — the headline
//// invariant: **`get/set/size/grow/fill/table_init/table_copy` behave byte-identically across every
//// `(table_tier × state_strategy)`** (`TablePaged` ≡ `TableEts` ≡ `TableAtomics`, cell and
//// threaded). `TablePaged` (the immutable-`Dict` implementation, trivially correct) is the ORACLE.
////
//// One shared op-trace — set (externref/funcref/null), in-range and OOB `fill`, overlapping
//// `table.copy` (with a deleted-slot in the copied slice), `table.init` (ok + OOB), and `grow` — is
//// driven through each tier and, after every op, asserted to produce the identical returned
//// outcome, the identical `size`, the identical whole-slot reference image (via `get`, exact for
//// null/funcref/externref), AND the identical `to_canon` funcref type-tag image
//// (<https://webassembly.github.io/spec/core/exec/instructions.html#table-instructions>; the
//// bulk-memory proposal for eager bounds + memmove). An ORACLE anchor pins the trace to the spec
//// so a shared bug that made all tiers agree WRONGLY is still caught.

import carder/ir.{
  type FuncType, type TrapReason, FuncType, TI32, TableOutOfBounds,
}
import carder/runtime/rt_ref
import carder/runtime/rt_state.{type InstanceState, StateDecl}
import carder/runtime/rt_table.{type RefValue}
import carder/runtime/rt_table_atomics as atom
import carder/runtime/rt_table_ets as ets
import gleam/dynamic
import gleam/list
import gleam/option.{type Option, None}
import gleeunit/should

/// Box a value as the package `Dynamic` a Phase-13 funcref closure returns (identity at run time).
@external(erlang, "gleam_stdlib", "identity")
fn to_pkg(v: a) -> dynamic.Dynamic

const init_size: Int = 5

fn ii_i() -> FuncType {
  FuncType([TI32, TI32], [TI32])
}

fn ext(n: Int) -> RefValue {
  rt_ref.extern_of(n)
}

/// A funcref reference value — stored/moved OPAQUELY by every op (never invoked), so the cell ABI
/// works for both state strategies; `to_canon` reads only its `FuncType` tag.
fn fref() -> RefValue {
  rt_table.funcref(ii_i(), fn(args) {
    case args {
      [a, b] -> to_pkg(a + b)
      _ -> panic as "add"
    }
  })
}

// ── the shared op-trace ────────────────────────────────────────────────────────

type Op {
  Set(index: Int, value: RefValue)
  Fill(offset: Int, value: RefValue, count: Int)
  Init(items: List(RefValue), dst: Int, src: Int, count: Int)
  Copy(dst: Int, src: Int, count: Int)
  Grow(delta: Int, init: RefValue)
}

/// A comparable per-op outcome (`st`/closures are not comparable across tiers).
type Out {
  Unit(Result(Nil, TrapReason))
  Grew(Int)
}

fn trace() -> List(Op) {
  [
    Set(0, ext(10)),
    // funcref → to_canon Some
    Set(1, fref()),
    Set(2, ext(20)),
    // fills slots 3,4
    Fill(3, ext(30), 2),
    // delete slot 2 (null write)
    Set(2, rt_ref.null_ref()),
    // ascending overlap; src slice [1,2,3] = [funcref, null, ext(30)] → slots [0,1,2]
    Copy(0, 1, 3),
    // OOB (3 + 5 > 5): traps, no partial write
    Fill(3, ext(9), 5),
    // in-range init
    Init([ext(40), ext(41)], 0, 0, 2),
    // source overflow (0 + 2 > 1): traps, no write
    Init([ext(1)], 0, 0, 2),
    // grow by 2 (unbounded) → old size 5, new slots ext(50)
    Grow(2, ext(50)),
    Set(6, ext(60)),
  ]
}

// ══════════════════════════ THREADED lockstep differential ══════════════════════════

fn fresh(table: dynamic.Dynamic) -> InstanceState {
  rt_state.fresh(StateDecl(mem: dynamic.nil(), globals: [], table: table))
}

fn drive_paged(st: InstanceState, op: Op) -> #(InstanceState, Out) {
  case op {
    Set(i, v) -> unit(st, rt_table.t_set(st, 0, i, v))
    Fill(o, v, n) -> unit(st, rt_table.t_fill(st, 0, o, v, n))
    Init(items, d, s, n) ->
      unit(st, rt_table.t_table_init(st, 0, items, d, s, n))
    Copy(d, s, n) -> unit(st, rt_table.t_table_copy(st, 0, 0, d, s, n))
    Grow(delta, v) -> {
      let #(old, st2) = rt_table.t_grow(st, 0, delta, v)
      #(st2, Grew(old))
    }
  }
}

fn drive_ets(st: InstanceState, op: Op) -> #(InstanceState, Out) {
  case op {
    Set(i, v) -> unit(st, ets.t_set(st, 0, i, v))
    Fill(o, v, n) -> unit(st, ets.t_fill(st, 0, o, v, n))
    Init(items, d, s, n) -> unit(st, ets.t_table_init(st, 0, items, d, s, n))
    Copy(d, s, n) -> unit(st, ets.t_table_copy(st, 0, 0, d, s, n))
    Grow(delta, v) -> {
      let #(old, st2) = ets.t_grow(st, 0, delta, v)
      #(st2, Grew(old))
    }
  }
}

fn drive_atomics(st: InstanceState, op: Op) -> #(InstanceState, Out) {
  case op {
    Set(i, v) -> unit(st, atom.t_set(st, 0, i, v))
    Fill(o, v, n) -> unit(st, atom.t_fill(st, 0, o, v, n))
    Init(items, d, s, n) -> unit(st, atom.t_table_init(st, 0, items, d, s, n))
    Copy(d, s, n) -> unit(st, atom.t_table_copy(st, 0, 0, d, s, n))
    Grow(delta, v) -> {
      let #(old, st2) = atom.t_grow(st, 0, delta, v)
      #(st2, Grew(old))
    }
  }
}

/// Map a mutating threaded op's `Result(st, _)` to `#(st', Out)`: on `Ok` the rebound record, on
/// `Error` the original `st` (nothing was written).
fn unit(
  st: InstanceState,
  result: Result(InstanceState, TrapReason),
) -> #(InstanceState, Out) {
  case result {
    Ok(st2) -> #(st2, Unit(Ok(Nil)))
    Error(e) -> #(st, Unit(Error(e)))
  }
}

/// Step the three threaded tiers together, asserting identical outcome, size, whole-slot image,
/// and `to_canon` after each op.
pub fn threaded_tiers_are_identical_test() {
  threaded_loop(
    trace(),
    fresh(rt_table.new(init_size, None)),
    fresh(ets.new(init_size, None)),
    fresh(atom.new(init_size, None)),
  )
}

fn threaded_loop(
  ops: List(Op),
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
      // Identical outcome.
      out_p |> should.equal(out_e)
      out_p |> should.equal(out_a)
      // Identical size.
      let size_p = rt_table.t_size(sp2, 0)
      size_p |> should.equal(ets.t_size(se2, 0))
      size_p |> should.equal(atom.t_size(sa2, 0))
      // Identical whole-slot reference image (exact for null/funcref/externref).
      let img_p = image_t(sp2, rt_table.t_get, size_p)
      img_p |> should.equal(image_t(se2, ets.t_get, size_p))
      img_p |> should.equal(image_t(sa2, atom.t_get, size_p))
      // Identical funcref type-tag image.
      let canon_p = rt_table.to_canon(rt_state.table(sp2))
      canon_p |> should.equal(ets.to_canon(rt_state.table(se2)))
      canon_p |> should.equal(atom.to_canon(rt_state.table(sa2)))
      threaded_loop(rest, sp2, se2, sa2)
    }
  }
}

/// The whole-slot reference image `[get(0), …, get(size-1)]` via a tier's threaded `get`.
fn image_t(
  st: InstanceState,
  get: fn(InstanceState, Int, Int) -> Result(RefValue, TrapReason),
  size: Int,
) -> List(RefValue) {
  list.map(seq(size), fn(i) {
    let assert Ok(v) = get(st, 0, i)
    v
  })
}

// ══════════════════════════ CELL differential ══════════════════════════

fn seed(table: dynamic.Dynamic) -> Nil {
  rt_state.seed(StateDecl(mem: dynamic.nil(), globals: [], table: table))
}

/// One collected step: outcome, size, whole-slot image, funcref type-tag image.
type Step {
  Step(
    out: Out,
    size: Int,
    image: List(RefValue),
    canon: List(Option(FuncType)),
  )
}

fn drive_paged_cell(op: Op) -> Out {
  case op {
    Set(i, v) -> Unit(rt_table.set(0, i, v))
    Fill(o, v, n) -> Unit(rt_table.fill(0, o, v, n))
    Init(items, d, s, n) -> Unit(rt_table.table_init(0, items, d, s, n))
    Copy(d, s, n) -> Unit(rt_table.table_copy(0, 0, d, s, n))
    Grow(delta, v) -> Grew(rt_table.grow(0, delta, v))
  }
}

fn drive_ets_cell(op: Op) -> Out {
  case op {
    Set(i, v) -> Unit(ets.set(0, i, v))
    Fill(o, v, n) -> Unit(ets.fill(0, o, v, n))
    Init(items, d, s, n) -> Unit(ets.table_init(0, items, d, s, n))
    Copy(d, s, n) -> Unit(ets.table_copy(0, 0, d, s, n))
    Grow(delta, v) -> Grew(ets.grow(0, delta, v))
  }
}

fn drive_atomics_cell(op: Op) -> Out {
  case op {
    Set(i, v) -> Unit(atom.set(0, i, v))
    Fill(o, v, n) -> Unit(atom.fill(0, o, v, n))
    Init(items, d, s, n) -> Unit(atom.table_init(0, items, d, s, n))
    Copy(d, s, n) -> Unit(atom.table_copy(0, 0, d, s, n))
    Grow(delta, v) -> Grew(atom.grow(0, delta, v))
  }
}

/// Run a tier's whole cell trace, collecting a `Step` after each op. `seed_fn`/`drive`/`get`/`canon`
/// select the tier; the cell already holds this tier's table after `seed_fn`. `ops` is passed in
/// (not re-generated per tier) so every tier stores the SAME funcref term — the exact image
/// comparison then holds (a funcref's closure is only equal to itself).
fn collect(
  ops: List(Op),
  seed_fn: fn() -> Nil,
  drive: fn(Op) -> Out,
  get: fn(Int, Int) -> Result(RefValue, TrapReason),
  sz: fn(Int) -> Int,
  canon: fn() -> List(Option(FuncType)),
) -> List(Step) {
  seed_fn()
  list.map(ops, fn(op) {
    let out = drive(op)
    let size = sz(0)
    Step(out, size, image_c(get, size), canon())
  })
}

fn image_c(
  get: fn(Int, Int) -> Result(RefValue, TrapReason),
  size: Int,
) -> List(RefValue) {
  list.map(seq(size), fn(i) {
    let assert Ok(v) = get(0, i)
    v
  })
}

/// Each tier's cell trace produces the IDENTICAL `Step` sequence — oracle vs ETS vs atomics.
pub fn cell_tiers_are_identical_test() {
  let ops = trace()
  let paged =
    collect(
      ops,
      fn() { seed(rt_table.new(init_size, None)) },
      drive_paged_cell,
      rt_table.get,
      rt_table.size,
      fn() { rt_table.to_canon(rt_state.table_get()) },
    )
  let ets_steps =
    collect(
      ops,
      fn() { seed(ets.new(init_size, None)) },
      drive_ets_cell,
      ets.get,
      ets.size,
      fn() { ets.to_canon(rt_state.table_get()) },
    )
  let atomics_steps =
    collect(
      ops,
      fn() { seed(atom.new(init_size, None)) },
      drive_atomics_cell,
      atom.get,
      atom.size,
      fn() { atom.to_canon(rt_state.table_get()) },
    )
  paged |> should.equal(ets_steps)
  paged |> should.equal(atomics_steps)
}

/// Sanity anchor on the ORACLE: the exact expected outcome sequence, so a shared bug that made all
/// three tiers agree WRONGLY is still caught (the differential alone proves equality, not spec
/// correctness).
pub fn oracle_trace_matches_spec_test() {
  let steps =
    collect(
      trace(),
      fn() { seed(rt_table.new(init_size, None)) },
      drive_paged_cell,
      rt_table.get,
      rt_table.size,
      fn() { rt_table.to_canon(rt_state.table_get()) },
    )
  list.map(steps, fn(s) { s.out })
  |> should.equal([
    Unit(Ok(Nil)),
    Unit(Ok(Nil)),
    Unit(Ok(Nil)),
    Unit(Ok(Nil)),
    Unit(Ok(Nil)),
    Unit(Ok(Nil)),
    // OOB fill traps.
    Unit(Error(TableOutOfBounds)),
    Unit(Ok(Nil)),
    // OOB init (source overflow) traps.
    Unit(Error(TableOutOfBounds)),
    // grow returns the old size.
    Grew(init_size),
    Unit(Ok(Nil)),
  ])
  // After the trace: size 7, slot 1 was overwritten by Copy (funcref → the copied funcref stays a
  // funcref), and the overlap Copy(dst=0,src=1,n=3) placed [funcref,null,ext(30)] at [0,1,2].
  let assert [last, ..] = list.reverse(steps)
  last.size |> should.equal(7)
  // The whole final slot image, exact — proves overlap/null/grow correctness on the oracle.
  last.image
  |> should.equal([
    // slot 0 = old slot 1 (funcref, moved by Copy) then overwritten by Init[0]=ext(40)
    ext(40),
    // slot 1 = Init[1]=ext(41)
    ext(41),
    // slot 2 = old slot 3 (ext(30), moved by Copy)
    ext(30),
    // slots 3,4 = the earlier Fill(ext(30))
    ext(30),
    ext(30),
    // slots 5,6 = grow init ext(50), then slot 6 overwritten by Set(6, ext(60))
    ext(50),
    ext(60),
  ])
}

// ── shared helper ──────────────────────────────────────────────────────────────

/// The ascending indices `[0, 1, …, n-1]` (`[]` for `n <= 0`).
fn seq(n: Int) -> List(Int) {
  build_seq(n - 1, [])
}

fn build_seq(i: Int, acc: List(Int)) -> List(Int) {
  case i < 0 {
    True -> acc
    False -> build_seq(i - 1, [i, ..acc])
  }
}
