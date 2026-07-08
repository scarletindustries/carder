//// `ir/effect` — the shared purity/effect classifier (F3, owner: unit 02).
////
//// Conservative: anything not *proven* pure is `Effectful`. The optimizer's soundness rests
//// on this classifier (E6): it must never rewrite across an effect barrier — no CSE of a load
//// past a store, no reorder past a `MemGrow`/`GlobalSet`/`CallIndirect`/`CallHost`/`Charge`/
//// `Trap`, no DCE of an effect.
////
//// ## The one-directional error budget (F3)
////
//// `classify` answers exactly one question: **may the optimizer treat this expression as if
//// it had no observable effect?** "Observable" is fixed by F2 — the returned bit patterns
//// (D5/D7: NaN payload / `-0.0` / wrap exact), the trap (its `TrapReason` and whether one
//// occurs at all), the final memory/global state, and — under Safe — the fuel consumed.
////
//// The analysis is deliberately asymmetric:
//// - a false `Effectful` (an inert node called effectful) costs only a missed optimization;
//// - a false `Pure` (a side-effecting/trapping node called inert) lets a downstream pass
////   delete a store, CSE a load across a write, hoist a trap above its guard, or drop a
////   charge — **silent memory corruption or a wrong answer.**
////
//// So every judgement defaults to `Effectful` and is narrowed to `Pure` only with a
//// structural proof: the node is not a barrier *and* every sub-expression is provably `Pure`.
//// The analysis is purely structural on `Expr` (no `Module`, no runtime binding — matching the
//// frozen `classify(Expr)` signature) and total: every variant is covered, nothing panics.
//// If a new `Expr` variant is added, the exhaustive `case`s here fail to compile until it is
//// classified (fail-closed, D4) — an unclassified node can never be silently optimized.
////
//// ## Trapping-op refinement of the keystone (§B.1)
////
//// The keystone's `is_effectful_node` doc enumerated `Num`/`Convert` broadly as non-barriers.
//// This unit refines that: the trapping subsets — `Num` with `IDivS/IDivU/IRemS/IRemU` and
//// `Convert` with `TruncS/TruncU` — are barriers, because deleting one or hoisting it onto a
//// path where it did not originally evaluate *adds or removes a trap* (an F2 observable). The
//// set is not invented here: it is exactly the partition `emit_core` routes through `rt_num`'s
//// `Result(Int, TrapReason)` (`is_trapping/1`, `is_trapping_conv/1`). This is *strictly more
//// conservative* than the keystone (it never narrows anything the keystone called effectful),
//// so it needs no signature change.
////
//// ## Phase-6 SIMD refinement (S7 — the one structural divergence)
////
//// Unlike every Phase-5 new node (all barriers), Phase 6's PURE lane-wise SIMD ops
//// (`Simd`/`SimdShuffle`) classify **`Pure` like `Num`**: a lane-wise vector instruction is a
//// TOTAL, DETERMINISTIC value transform (WASM §4.4 — no trap, since saturation replaces the
//// overflow trap and there is no SIMD divide-trap; no state read/write), so CSE / DCE / reorder
//// over it preserve observable behaviour exactly, enabling later SIMD const-fold. The four SIMD
//// MEMORY nodes (`SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`) touch mutable memory and
//// can trap OOB, so they stay barriers; `CallImport` is a call, so it is a barrier too.
////
//// ## Spec anchor
////
//// WASM has a defined store/evaluation model (WebAssembly spec §4.2 Runtime Structure and
//// §4.4 Instructions): memory and global operations read/write the store in program order.
//// Trapping arithmetic/conversion is WASM §4.3.2/§4.3.3. E6/F3 make that order the optimizer's
//// hard barrier.

import gleam/list
import twocore/ir.{
  type ConvOp, type Expr, type Function, type NumOp, Block, Break, CallClosure,
  CallDirect, CallHost, CallImport, CallIndirect, Charge, Continue, Convert,
  DataDrop, ElemDrop, Gc, GlobalGet, GlobalSet, IDivS, IDivU, IRemS, IRemU, If,
  Let, Loop, MakeClosure, MapOp, MemCopy, MemFill, MemGrow, MemInit, MemLoad,
  MemLoadUnchecked, MemSize, MemStore, MemStoreUnchecked, Num, NumTerm, RefFunc,
  RefFuncImport, RefIsNull, Return, ReturnCall, ReturnCallImport,
  ReturnCallIndirect, Simd, SimdLoad, SimdLoadLane, SimdShuffle, SimdStore,
  SimdStoreLane, Switch, TableCopy, TableFill, TableGet, TableGrow, TableInit,
  TableSet, TableSize, TermOp, TermTag, TermTest, Throw, ThrowRef, Trap, TruncS,
  TruncU, Try, Values,
}

/// Whether an expression is observably pure or side-effecting (F3).
///
/// - `Pure`: evaluation reads/writes no mutable instance state and cannot trap or diverge —
///   safe to fold, CSE, reorder, or eliminate.
/// - `Effectful`: evaluation may read/write memory/globals/tables, call the host, charge fuel,
///   or trap — an optimizer barrier.
pub type Effect {
  Pure
  Effectful
}

/// SHALLOW barrier test (F3): does THIS node — ignoring its sub-expressions — read or write
/// mutable instance state, call out, meter, trap, transfer control, or possibly diverge? The
/// primitive `classify` is built on, and the fast test a pass uses to find the nearest barrier
/// in a straight-line sequence.
///
/// Barriers (`True`): the E6/F3 state ops (`MemSize`/`MemGrow`/`MemLoad`/`MemStore`/
/// `GlobalGet`/`GlobalSet`) + the three call kinds (`CallDirect`/`CallIndirect`/`CallHost`) +
/// `Charge` + `Trap` + the non-returning transfers (`Break`/`Continue`/`Return`) + `Loop` (may
/// not terminate) + the TRAPPING `Num`/`Convert` subsets (§B.1). Non-barriers (`False`):
/// `Values`, non-trapping `Num`/`Convert`, `TermOp`, and the `Let`/`Block`/`If`/`Switch`
/// shells — their DEEP verdict is decided by their sub-expressions in `classify`, not here.
///
/// Total; never panics. A `True` here does NOT imply the whole subtree is effectful (only this
/// node); a `False` here does NOT imply the subtree is pure (a shell may hide a barrier) — use
/// the DEEP `is_pure`/`classify` for that.
pub fn is_effectful_node(e: Expr) -> Bool {
  case e {
    MemSize(_)
    | MemGrow(_, _)
    | MemLoad(_, _, _, _, _)
    | MemStore(_, _, _, _, _)
    | // Phase-10 range-BCE (N4): the UNCHECKED memory accesses read/write mutable memory exactly like
      // `MemLoad`/`MemStore` — barriers (no CSE, no reorder, no DCE). They omit only the bounds-check,
      // never the memory effect, so their effect classification is IDENTICAL to the checked nodes.
      MemLoadUnchecked(_, _, _, _, _)
    | MemStoreUnchecked(_, _, _, _, _)
    | GlobalGet(_)
    | GlobalSet(_, _)
    | CallDirect(_, _)
    | CallIndirect(_, _, _, _)
    | CallHost(_, _, _)
    | Charge(_, _)
    | Trap(_)
    | Break(_, _)
    | Continue(_, _)
    | Return(_)
    | Loop(_, _, _, _)
    | // ── Phase-5 reference / table / bulk ops (H2): ALL barriers. ──
      // Every one reads and/or writes mutable instance state (a table slot, a memory range,
      // passive-segment drop state, or an instance-linked closure) → no CSE, no reorder, no DCE,
      // exactly like `MemStore`/`GlobalSet` (§E). `RefFunc`/`RefFuncImport`/`RefIsNull` are
      // conservatively classified as barriers too (the maximally-safe freeze posture — narrowing
      // them to `Pure` is an explicit, tested refinement a later unit may make; strictly the safe
      // direction). `RefFuncImport` (R14) materialises an INSTANCE-LINKED imported funcref — a
      // barrier exactly like `RefFunc`; it carries only a slot + type (no sub-`Expr`), so
      // `children_all_pure`'s `_ -> True` catch-all is reached vacuously and NO arm is needed there,
      // giving `classify == Effectful`, `can_cse == False`, `can_eliminate_if_unused == False`.
      RefFunc(_)
    | RefFuncImport(_, _)
    | RefIsNull(_)
    | TableGet(_, _)
    | TableSet(_, _, _)
    | TableSize(_)
    | TableGrow(_, _, _)
    | TableFill(_, _, _, _)
    | TableInit(_, _, _, _, _)
    | TableCopy(_, _, _, _, _)
    | ElemDrop(_)
    | MemFill(_, _, _, _)
    | MemCopy(_, _, _, _, _)
    | MemInit(_, _, _, _, _)
    | DataDrop(_)
    | // ── Phase-6 SIMD MEMORY (S7): the four v128 load/store nodes read/write mutable memory
      // state and can trap (OOB → `MemoryOutOfBounds`), so they are barriers exactly like
      // `MemLoad`/`MemStore` — no CSE across a store, no reorder across a grow, no DCE. ──
      SimdLoad(_, _, _, _)
    | SimdStore(_, _, _, _)
    | SimdLoadLane(_, _, _, _, _, _)
    | SimdStoreLane(_, _, _, _, _, _)
    | // Phase-6 imported-function CALL (S5/S7): a call is a barrier (it may read/write any
      // state and trap) — classified like `CallDirect`/`CallHost`.
      CallImport(_, _, _)
    | // ── Phase-13 tail calls (Q1/Q2): ALL THREE tail-call nodes are barriers. Like
      // `Return`/`Trap`/`CallImport`, a tail call is a non-local control transfer to arbitrary
      // callee code that also may read/write any state and trap — so it is NEVER reordered,
      // hoisted, CSE'd, duplicated, or eliminated (doing so would add/remove/relocate an effect or
      // a trap, an F2 observable). Since the `case` is exhaustive, OMITTING any tail-call node
      // fails to compile (fail-closed, D4). The deep `classify`/`can_cse`/`can_eliminate_if_unused`
      // derive `Effectful`/`False`/`False` from this arm. They carry only `Value` operands.
      ReturnCall(_, _)
    | ReturnCallIndirect(_, _, _, _)
    | ReturnCallImport(_, _, _)
    | // ── Phase-7 exception handling (J5/T1): ALL THREE EH nodes are barriers. `Throw`/`ThrowRef`
      // are non-local control transfers that RAISE (like `Trap`/`Return`) — never reorder, hoist,
      // duplicate, or eliminate (they add/remove an exception, an F2 observable). `Try` establishes
      // an exception handler and alters control flow (catching turns a throwing body into a normal
      // result — observable), and its `body`/handlers may be effectful; conservatively a barrier.
      // Since the `case` is exhaustive, OMITTING any EH node fails to compile (fail-closed, D4) —
      // an unclassified EH node can never be silently optimized. ──
      Throw(_, _)
    | Try(_, _, _)
    | ThrowRef(_)
    | // ── Phase-8 native closures (K8): `CallClosure` applies a fun VALUE — it transfers control
      // to arbitrary code (the same class as `CallIndirect`/`CallHost`/`CallImport`), so it is a
      // barrier: never reorder, CSE, or DCE it. (`MakeClosure` is NOT here — building a fun over
      // evaluated values is inert; it classifies `Pure` in the non-barrier arm below.) ──
      CallClosure(_, _)
    | // ── Phase-8 native number arithmetic (K8, unit 06): `NumTerm` is classified like the TRAPPING
      // `Num` ops (`IDivS`/`IRemS`/…). It can raise a native BEAM `badarith` on a non-number operand
      // — the frontend guards with `TermTest(IsNumber)`, but the IR can't prove it — so deleting one,
      // or hoisting it onto a path where it did not originally evaluate, adds/removes a raise (an F2
      // observable). Hence a barrier: no CSE, no DCE, no reorder. (`TermTest`/`TermTag` are PURE — the
      // `is_*` BIFs are total, never trap — so they classify `Pure` in the non-barrier arm below.) ──
      NumTerm(_, _, _)
    | // ── WasmGC (this proposal): every `Gc` op is a barrier. Each reads and/or
      // writes the per-process GC arena (an alias-heavy mutable heap) through an
      // `rt_gc` seam call, and several trap (`ref.cast` cast-failure, array OOB,
      // null deref) — so, like `MemStore`/the table ops, never CSE/DCE/reorder. ──
      Gc(_, _) -> True
    Num(op, _) -> trapping_numop(op)
    Convert(op, _) -> trapping_convop(op)
    // ── Phase-6 PURE lane-wise SIMD (S7): `Simd`/`SimdShuffle` are TOTAL and DETERMINISTIC —
    // no trap (I3: saturation replaces overflow-trap; no SIMD divide-trap), no state read/write.
    // So they are non-barriers, classified `Pure` like a non-trapping `Num`: CSE / DCE / reorder
    // over them preserve observable behaviour exactly. They carry only `Value` operands (no
    // sub-`Expr`), so `children_all_pure` reaches its `_ -> True` catch-all vacuously. A
    // deliberate, argued improvement over Phase-5's conservatism (spec §4.4: vector instructions
    // are total value transforms), enabling SIMD const-fold/DCE later. ──
    // ── Phase-8 native closures (K8): `MakeClosure` builds a `fun` over already-evaluated pure
    // `Value` captures — no state read/write, no trap, no control transfer — so it is a
    // non-barrier and classifies `Pure` like `TermOp` (CSE/DCE/hoist of a fun literal are sound).
    // It carries only `Value` operands (no sub-`Expr`), so `children_all_pure` reaches its
    // `_ -> True` catch-all vacuously. (`CallClosure` is the barrier — see the `True` arm above.) ──
    // ── Phase-8 map layer (K8, unit 03): every `MapOp` is PURE — a BEAM map is immutable, so
    // construction, functional update, AND the reads all read/write no shared mutable state, never
    // trap, and transfer no control. So it is a non-barrier like `TermOp`/`MakeClosure` (CSE/DCE/
    // reorder sound). It carries only `Value` operands (no sub-`Expr`), so `children_all_pure`
    // reaches its `_ -> True` catch-all vacuously. ──
    // ── Phase-8 term classification (K8, unit 06): `TermTest`/`TermTag` are PURE — a composition of
    // total `erlang:is_*` BIFs (they inspect a term's shape, never trap, read/write no state, transfer
    // no control), so they are non-barriers exactly like `TermOp`/`MapOp` (CSE/DCE/reorder sound).
    // They carry only `Value` operands (no sub-`Expr`), so `children_all_pure` reaches its `_ -> True`
    // catch-all vacuously. (`NumTerm` is the barrier — see the `True` arm above.) ──
    Values(_)
    | TermOp(_, _)
    | MakeClosure(_, _, _)
    | MapOp(_, _)
    | TermTest(_, _)
    | TermTag(_)
    | Simd(_, _)
    | SimdShuffle(_, _, _)
    | Let(_, _, _)
    | Block(_, _, _)
    | If(_, _, _, _)
    | Switch(_, _, _, _) -> False
  }
}

/// The four TRAPPING integer ops — `div`/`rem`, signed & unsigned — trap on a zero divisor,
/// and `div_s` additionally on `INT_MIN / -1` (WASM spec §4.3.2). Mirrors `emit_core`'s
/// authoritative `is_trapping/1` (`emit_core.gleam:1530`). Every other `NumOp` (arithmetic,
/// bitwise, shifts, comparisons, and ALL float ops — IEEE never traps) is total.
///
/// Returns `True` for exactly `IDivS`/`IDivU`/`IRemS`/`IRemU` (any width), `False` otherwise.
fn trapping_numop(op: NumOp) -> Bool {
  case op {
    IDivS(_) | IDivU(_) | IRemS(_) | IRemU(_) -> True
    _ -> False
  }
}

/// The two TRAPPING float→int conversions — `trunc_s`/`trunc_u` trap on NaN, ±∞, or an
/// out-of-range magnitude (WASM spec §4.3.3). Mirrors `emit_core`'s authoritative
/// `is_trapping_conv/1` (`emit_core.gleam:1577`). The saturating `trunc_sat_*`, width/sign
/// extends, reinterpret, `convert_*`, demote/promote, and the term↔numeric boxing bridge are
/// all total value transforms.
///
/// Returns `True` for exactly `TruncS`/`TruncU` (any width pair), `False` otherwise.
fn trapping_convop(op: ConvOp) -> Bool {
  case op {
    TruncS(_, _) | TruncU(_, _) -> True
    _ -> False
  }
}

/// DEEP classification (F3): `Pure` iff `e` is a non-barrier node AND every sub-expression is
/// `Pure`. The optimizer uses this to decide whether a whole subtree may be folded / CSE'd /
/// eliminated.
///
/// - `e`: the expression to classify (its whole subtree).
/// - Return: `Pure` when the subtree is observationally inert modulo its result value
///   (reads/writes no state, cannot trap or diverge, performs no control transfer);
///   `Effectful` otherwise. Conservative — see the module docs: anything not *proven* pure is
///   `Effectful`. Total; never panics.
pub fn classify(e: Expr) -> Effect {
  case is_effectful_node(e) {
    True -> Effectful
    False ->
      case children_all_pure(e) {
        True -> Pure
        False -> Effectful
      }
  }
}

/// Are all of `e`'s SUB-EXPRESSIONS pure? Only the non-barrier recursive shells
/// (`Let`/`Block`/`If`/`Switch`) have sub-expressions; every other non-barrier node
/// (`Values`/non-trapping `Num`/non-trapping `Convert`/`TermOp`) is atomic over `Value`s and so
/// has none (vacuously `True`). Barriers never reach here — `classify` short-circuits — so
/// `Loop`/`Charge`/etc. need no arm and fall into the `_` catch-all.
fn children_all_pure(e: Expr) -> Bool {
  case e {
    Let(_, rhs, body) -> is_pure(rhs) && is_pure(body)
    Block(_, _, body) -> is_pure(body)
    If(_, _, then_branch, else_branch) ->
      is_pure(then_branch) && is_pure(else_branch)
    Switch(_, _, arms, default) ->
      is_pure(default) && list.all(arms, fn(a) { is_pure(a.body) })
    _ -> True
  }
}

/// `True` iff `classify(e) == Pure` — the master safety oracle the derived predicates below
/// are built on, and the guard a pass consults before folding/CSE-ing/eliminating a subtree.
///
/// - `e`: the expression to test (its whole subtree).
/// - Return: `True` only when `e` is observationally inert modulo its result value (safe to
///   duplicate, delete, reorder, hoist, or sink). `False` for any node that reads/writes state,
///   calls out, meters, traps, diverges, or transfers control — or any shell containing one.
///   Total; never panics.
pub fn is_pure(e: Expr) -> Bool {
  classify(e) == Pure
}

// ───────────────────── optimizer-facing predicates (what 03/04 call) ─────────────────────
// `classify`/`is_pure`/`is_effectful_node` are the *analysis*. Passes gate their rewrites on
// the NAMED predicates below, whose names ARE their soundness contract, so a call site reads as
// its intent and a future refinement changes one body, not every caller (§D).

/// May a `let names = e in body` whose bound `names` are ALL dead in `body` drop the binding
/// (and `e`)?
///
/// - `e`: the bound right-hand side whose result is unused.
/// - Return: `True` licenses dropping `e` entirely — sound only when `e` has nothing to
///   preserve (no state write, host call, fuel charge, trap, divergence, or control transfer),
///   i.e. exactly `is_pure(e)`. `False` FORBIDS the drop: an effectful `e` (a `MemStore`, a
///   `Charge`, a trapping `div`, a `CallHost`) is KEPT even though its result is unused —
///   E1's ordered `let _ = effect in …` sequencing is load-bearing (F3, "no DCE of an effect").
///   Total; never panics.
pub fn can_eliminate_if_unused(e: Expr) -> Bool {
  is_pure(e)
}

/// May occurrences of `e` be shared / hoisted to a common dominator (CSE / value numbering)?
///
/// - `e`: the candidate expression to share.
/// - Return: `True` licenses sharing — sound only for a `Pure` `e`: it computes the same value
///   in any position and introduces no trap or divergence at the hoist point. A
///   `MemLoad`/`GlobalGet` is NOT pure (it reads mutable state), so this is `False` — the
///   classifier FORBIDS ALL load/global CSE in Phase 3. That is a conscious, sound
///   under-approximation (F8): precise load-CSE ("no aliasing store between the two
///   occurrences") needs an alias + reordering analysis scoped as later work. It makes "a load
///   is never CSE'd across a store" hold the strongest way — a load is never CSE'd *at all*.
///   Total; never panics.
pub fn can_cse(e: Expr) -> Bool {
  is_pure(e)
}

/// May two ADJACENT, data-INDEPENDENT expressions `a` then `b` swap without changing observable
/// behavior?
///
/// - `a`, `b`: the two adjacent expressions, in current program order.
/// - Return: `True` iff at least one is DEEP-pure: a pure expression commutes with everything
///   (reads/writes no state, cannot trap or diverge). `False` keeps the order: two barriers —
///   two stores, a load and a store, a grow and a load, a `Charge` and anything, a `Trap` and
///   anything — do not swap.
///
/// CONTRACT: the caller MUST separately ensure `b` uses no name `a` binds (no data dependency).
/// This predicate answers the EFFECT-ORDERING question only. It uses the DEEP `is_pure`, NEVER
/// the shallow `is_effectful_node`: a `Block` whose body hides a `MemStore` is a non-barrier
/// NODE yet is not reorderable. Total; never panics.
pub fn can_reorder(a: Expr, b: Expr) -> Bool {
  is_pure(a) || is_pure(b)
}

/// `True` iff `f`'s whole body is pure — the interprocedural escape hatch (pure-callee
/// reasoning for inlining, unit 04, and pure-call CSE).
///
/// - `f`: the function whose body is examined.
/// - Return: `True` only when `is_pure(f.body)` holds. CONSERVATIVE: it does NOT chase callees,
///   so a body containing any `CallDirect`, `Loop`, state op, or trapping op is `False` even if
///   that callee is itself pure. A call-graph fixpoint on top is unit 04's choice, not this
///   unit's obligation. Total; never panics.
pub fn function_is_pure(f: Function) -> Bool {
  is_pure(f.body)
}
