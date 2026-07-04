//// `middle/ir_opt/mem_ssa` — MemorySSA + linear-memory alias analysis (Phase-9 M1, the keystone).
////
//// This is the shared **analysis** every Phase-9 memory rewrite rests on. It provides the
//// vocabulary — an access footprint, the alias lattice, the memory-barrier classifier, the
//// reaching-value (`avail`) map type, a truncation-guard width helper, and the extended
//// termination-measure component — and performs **no rewrite itself**. Units 02 (`mem_forward`,
//// store→load forwarding + redundant-load elimination) and 03 (`mem_dse`, dead-store elimination)
//// consume this surface to build alias-aware rewrites that **cannot** be unsound.
////
//// ## Why this is a leaf module (the import-cycle fix)
////
//// It imports `twocore/ir` and `twocore/ir/effect` **only** — it sits *below* the memory passes
//// in the import DAG, exactly as `pass.gleam` sits below `baseline`/`aggressive`. So `mem_forward`
//// and `mem_dse` both import it with no cycle, and `ir_opt` (which imports those to register them)
//// stays acyclic too.
////
//// ## What it refines (relative to `ir/effect`)
////
//// `ir/effect` answers "is this subtree observably pure?" and forbids **all** load CSE as the
//// strongest sound under-approximation (`can_cse` == `is_pure`, and a load is never pure). This
//// module answers the finer **memory-dependence** questions the alias-aware passes need: *do two
//// accesses touch the same bytes?* (`alias`) and *does this node force me to forget what I know
//// about linear memory?* (`is_memory_barrier`). It does not replace `ir/effect` — the passes still
//// consult it for the general purity questions (e.g. DSE's "only pure between the two stores").
////
//// ## The soundness posture (M5)
////
//// CONSERVATIVE in both directions: `alias` defaults to `MayAlias` (only a structural proof yields
//// `MustAlias`/`NoAlias`), and `is_memory_barrier` defaults to `True` (only nodes provably unable
//// to write/reallocate linear memory or leave the straight-line region are transparent). A false
//// `NoAlias` or a false "transparent" is silent memory corruption; a false `MayAlias`/`True` costs
//// only a missed optimization. Every judgement below takes the safe direction under any doubt.

import gleam/dict.{type Dict}
import gleam/list
import twocore/ir.{
  type Expr, type Module, type Value, Block, Break, Charge, Continue, Convert,
  Loop, MakeClosure, MapOp, MemLoad, MemStore, Num, NumTerm, Switch, TermOp,
  TermTag, TermTest, Try, Values,
}

/// An **access footprint**: exactly which bytes of which memory a `MemLoad`/`MemStore` touches
/// (M1/M4). All four fields are kept DISTINCT — `addr + offset` is NEVER folded (M4, the invariant
/// that keeps the IR analyzable) — because disambiguation reasons over `addr` and `offset`
/// separately: two accesses through the SAME base `addr` at DIFFERENT constant `offset`s are the
/// tractable disjoint case (the Array-SSA element disambiguation).
///
/// - `mem`: the memory index (memories are disjoint address spaces — different `mem` ⇒ `NoAlias`).
/// - `addr`: the dynamic base operand (a `Value` — a `Var` or a `Const*`). Compared by SYNTACTIC
///   equality only (M5): Phase 9 does NOT value-number bases beyond `==`.
/// - `offset`: the static memarg byte offset (≥ 0).
/// - `bytes`: the access width in bytes (`op.bytes`) — the length of the touched byte range
///   `[offset, offset + bytes)`. Drives range-overlap disambiguation.
pub type Footprint {
  Footprint(mem: Int, addr: Value, offset: Int, bytes: Int)
}

/// The alias relationship between two footprints — the safety lattice (M5). CONSERVATIVE: the
/// default answer is `MayAlias`; `MustAlias`/`NoAlias` are returned ONLY with a structural proof.
///
/// - `MustAlias`: the two accesses touch the EXACT same bytes (same `mem`, syntactically-equal
///   base, same `offset`, same `bytes`). A store's value may be forwarded to a must-alias load; a
///   store may be killed by a must-alias later store.
/// - `NoAlias`: the two accesses PROVABLY touch disjoint bytes (different `mem`, or same base with
///   disjoint `[offset, offset+bytes)` ranges). Neither can observe or clobber the other.
/// - `MayAlias`: cannot prove either — a different/unknown base, or an overlapping-but-not-equal
///   range. The optimizer must treat this as a clobber (no forward, no reuse across it).
pub type AliasResult {
  MustAlias
  NoAlias
  MayAlias
}

/// The **reaching-value map** the forwarding/RLE pass (unit 02) threads through a straight-line
/// region: a footprint ↦ the `Value` currently known to be at those bytes (the value a
/// non-truncating store wrote, or the name a prior natural-width load bound). Keyed by the full
/// `Footprint`, so a lookup by an identical footprint IS a `MustAlias` lookup (equal footprints are
/// `MustAlias` by construction — see `alias`). Unit 02 owns the transfer function that maintains it
/// (insert on store/load, invalidate on aliasing store, clear on a barrier); this type is the
/// shared vocabulary.
pub type Avail =
  Dict(Footprint, Value)

/// Extract the `Footprint` of a memory access `Expr`, or `Error(Nil)` if `e` is not a scalar
/// linear-memory access.
///
/// Returns `Ok` for exactly `MemLoad` and `MemStore` — the two scalar per-access nodes the analysis
/// reasons about. Bulk-memory ops (`MemFill`/`MemCopy`/`MemInit`) and the SIMD memory ops are NOT
/// footprints — they are barriers (`is_memory_barrier`), because a range write cannot be
/// disambiguated against a scalar footprint (M5). Total; never panics.
pub fn footprint_of(e: Expr) -> Result(Footprint, Nil) {
  case e {
    MemLoad(mem, op, addr, offset, _result) ->
      Ok(Footprint(mem: mem, addr: addr, offset: offset, bytes: op.bytes))
    MemStore(mem, op, addr, _value, offset) ->
      Ok(Footprint(mem: mem, addr: addr, offset: offset, bytes: op.bytes))
    // Phase-10 unchecked accesses (N4) touch the SAME bytes as their checked twins, so they have
    // the same footprint — they alias the checked nodes exactly.
    ir.MemLoadUnchecked(mem, op, addr, offset, _result) ->
      Ok(Footprint(mem: mem, addr: addr, offset: offset, bytes: op.bytes))
    ir.MemStoreUnchecked(mem, op, addr, _value, offset) ->
      Ok(Footprint(mem: mem, addr: addr, offset: offset, bytes: op.bytes))
    _ -> Error(Nil)
  }
}

/// The alias oracle (M5) — the safety gate. Total; never panics; DEFAULTS to `MayAlias`.
///
/// - different `mem` ⇒ `NoAlias` (multi-memory: memories are disjoint address spaces).
/// - same `mem`, `a.addr == b.addr` (syntactically-equal `Value`) ⇒ compare the byte ranges
///   `[offset, offset+bytes)` (see `range_alias`).
/// - same `mem`, `a.addr != b.addr` (different or unknown base) ⇒ `MayAlias` — general pointer
///   aliasing is undecidable and Phase 9 does not value-number bases (the honest ceiling, M8).
///   This is the conservative direction, so it can never cause an unsound rewrite — only a missed
///   one.
pub fn alias(a: Footprint, b: Footprint) -> AliasResult {
  case a.mem == b.mem {
    False -> NoAlias
    True ->
      case a.addr == b.addr {
        False -> MayAlias
        True -> range_alias(a.offset, a.bytes, b.offset, b.bytes)
      }
  }
}

/// Alias relationship of two byte intervals `[oa, oa+la)` and `[ob, ob+lb)` known to share a base
/// (same `mem`, syntactically-equal `addr`). Pure integer interval arithmetic on the static
/// `offset`/`bytes` — deterministic and exact.
///
/// - identical range (`oa == ob && la == lb`) ⇒ `MustAlias`.
/// - disjoint (`oa + la <= ob` or `ob + lb <= oa`) ⇒ `NoAlias` (`base+0`/4B vs `base+4`/4B).
/// - otherwise (overlapping, not identical) ⇒ `MayAlias` (`base+0`/4B partly clobbers `base+2`/4B).
fn range_alias(oa: Int, la: Int, ob: Int, lb: Int) -> AliasResult {
  case oa == ob && la == lb {
    True -> MustAlias
    False ->
      case oa + la <= ob || ob + lb <= oa {
        True -> NoAlias
        False -> MayAlias
      }
  }
}

/// Does node `e` force the analysis to FORGET everything it knows about linear memory (M5)? A
/// barrier clears the `avail` map (forwarding/RLE) and stops DSE look-ahead.
///
/// Answers only the SHALLOW question "may evaluating this node change/relocate linear-memory bytes,
/// or transfer control out of the straight-line region?". A `True` means the region walkers reset;
/// it does NOT mean "the subtree is effectful" (that is `ir/effect`'s question).
///
/// Barriers (`True`): `MemGrow` (reallocates); every call
/// (`CallDirect`/`CallIndirect`/`CallHost`/`CallImport`/`CallClosure` — may write any memory);
/// every bulk-memory op (`MemFill`/`MemCopy`/`MemInit`/`DataDrop`); the four SIMD memory ops
/// (conservatively — v128 memory traffic is exotic and a barrier only costs a missed rewrite);
/// every non-returning / control-flow transfer (`Trap`/`Throw`/`ThrowRef`/`Return`/`Break`/
/// `Continue`) and the structured region heads (`Loop`/`If`/`Switch`/`Block`/`Try` — the analysis
/// is per straight-line region, so a region boundary is a reset; the walkers recurse INTO these as
/// fresh regions); and — conservatively — the reference/table ops (`RefFunc`/`RefIsNull`/`Table*`/
/// `ElemDrop`): they touch the disjoint table/reference state, never linear memory, but are
/// forgotten in v1 to keep this classifier's audit surface small (transparent-izing them is a
/// sound, tested refinement a later unit may make).
///
/// Memory-transparent (`False` — keep memory knowledge): `MemLoad`/`MemStore` (they are
/// FOOTPRINTS, handled precisely by the walkers — a load may add to `avail`, a store invalidates
/// only ALIASING entries and inserts its own — NOT a blanket "forget"); `MemSize` (reads the page
/// count, no write, no trap); `GlobalGet`/`GlobalSet` (the globals cell is disjoint from linear
/// memory and cannot trap); `Charge` (fuel only — the walkers thread `avail` through its body);
/// `Let` (sequencing shell — the walkers thread `avail` through `rhs` then `body`); and every pure
/// value op (`Values`/`Num`/`Convert`/`TermOp`/`NumTerm`/`TermTest`/`TermTag`/`MakeClosure`/
/// `MapOp`/`Simd`/`SimdShuffle`) — none writes linear memory, and a value that traps/raises
/// (`i32.div_s`, `NumTerm` `badarith`) merely LEAVES the region consistently, which forwarding
/// already tolerates (the reused value is never observed on a trapping path).
///
/// Total; the `case` is exhaustive (no wildcard), so a NEW `Expr` variant fails to compile until it
/// is classified here — fail-closed (D4): an unclassified node can never silently keep memory
/// knowledge alive.
pub fn is_memory_barrier(e: Expr) -> Bool {
  case e {
    // ── memory-transparent: footprints (handled precisely by the walkers) ──
    ir.MemLoad(_, _, _, _, _)
    | ir.MemStore(_, _, _, _, _)
    | // Phase-10 unchecked accesses (N4): footprints too (same bytes as the checked twins), so
      // handled precisely by the walkers, NOT a blanket "forget".
      ir.MemLoadUnchecked(_, _, _, _, _)
    | ir.MemStoreUnchecked(_, _, _, _, _) -> False
    // ── memory-transparent: read-only / disjoint-state / sequencing / pure ──
    ir.MemSize(_)
    | ir.GlobalGet(_)
    | ir.GlobalSet(_, _)
    | ir.Charge(_, _)
    | ir.Let(_, _, _)
    | Values(_)
    | Num(_, _)
    | Convert(_, _)
    | TermOp(_, _)
    | NumTerm(_, _, _)
    | TermTest(_, _)
    | TermTag(_)
    | MakeClosure(_, _, _)
    | MapOp(_, _)
    | ir.Simd(_, _)
    | ir.SimdShuffle(_, _, _) -> False
    // ── barriers: writes/reallocates linear memory ──
    ir.MemGrow(_, _)
    | ir.MemFill(_, _, _, _)
    | ir.MemCopy(_, _, _, _, _)
    | ir.MemInit(_, _, _, _, _)
    | ir.DataDrop(_)
    | ir.SimdLoad(_, _, _, _)
    | ir.SimdStore(_, _, _, _)
    | ir.SimdLoadLane(_, _, _, _, _, _)
    | ir.SimdStoreLane(_, _, _, _, _, _) -> True
    // ── barriers: calls out (may touch any memory) ──
    ir.CallDirect(_, _)
    | ir.CallIndirect(_, _, _, _)
    | ir.CallHost(_, _, _)
    | ir.CallImport(_, _, _)
    | ir.CallClosure(_, _) -> True
    // ── barriers: control leaves the straight-line region ──
    ir.Trap(_)
    | ir.Throw(_, _)
    | ir.ThrowRef(_)
    | ir.Return(_)
    | Break(_, _)
    | Continue(_, _) -> True
    // ── barriers: structured region heads (walkers recurse in as FRESH regions) ──
    Loop(_, _, _, _)
    | Block(_, _, _)
    | ir.If(_, _, _, _)
    | Switch(_, _, _, _)
    | Try(_, _, _) -> True
    // ── barriers (conservative v1): reference / table ops touch the disjoint table state,
    //     never linear memory, but are forgotten to keep the audit surface small ──
    ir.RefFunc(_)
    | ir.RefIsNull(_)
    | ir.TableGet(_, _)
    | ir.TableSet(_, _, _)
    | ir.TableSize(_)
    | ir.TableGrow(_, _, _)
    | ir.TableFill(_, _, _, _)
    | ir.TableInit(_, _, _, _, _)
    | ir.TableCopy(_, _, _, _, _)
    | ir.ElemDrop(_) -> True
  }
}

/// The byte width of a value type — the natural in-memory footprint of a full-width access
/// (M3/M7 truncation guard).
///
/// `Ok(4)` for `TI32`/`TF32`, `Ok(8)` for `TI64`/`TF64`, `Ok(16)` for `TV128`; `Error(Nil)` for
/// reference/term types (`TTerm`/`TFuncRef`/`TExternRef`/`TExnRef` — not linear-memory-representable).
/// The forwarding pass (unit 02) uses this to reject TRUNCATING stores (`i64.store32`,
/// `i32.store8`, …) as forward sources and SUB-WIDTH loads (`i32.load8_u`, …) as forward targets: a
/// store/load is *natural-width* iff `op.bytes == byte_width(value/result type)`, and only
/// natural-width accesses move a value faithfully. Total.
pub fn byte_width(t: ir.ValType) -> Result(Int, Nil) {
  case t {
    ir.TI32 | ir.TF32 -> Ok(4)
    ir.TI64 | ir.TF64 -> Ok(8)
    ir.TV128 -> Ok(16)
    ir.TTerm | ir.TFuncRef | ir.TExternRef | ir.TExnRef -> Error(Nil)
  }
}

/// The `n_mem` component of the extended termination measure (M7): the number of `MemLoad` +
/// `MemStore` nodes anywhere in `m`.
///
/// No Phase-9 pass (and no baseline pass) ever CONSTRUCTS a `MemLoad`/`MemStore`, so `n_mem` is
/// monotonically non-increasing across the `run_pipeline` fixpoint and every *changing* memory
/// rewrite strictly decreases it — which keeps the fixpoint well-founded when the memory passes are
/// appended (unit 04). Exposed so the capstone can assert convergence/monotonicity over the corpus
/// and count eliminations for the benchmark's deterministic metric. Total.
pub fn count_mem_ops(m: Module) -> Int {
  list.fold(m.functions, 0, fn(acc, f) { acc + count_in_expr(f.body) })
}

/// Count `MemLoad` + `MemStore` nodes in `e`, recursing through every sub-`Expr`-bearing node.
/// Leaves (including the non-`MemLoad`/`MemStore` memory-adjacent ops, which carry only `Value`
/// operands) contribute `0`.
fn count_in_expr(e: Expr) -> Int {
  case e {
    MemLoad(_, _, _, _, _)
    | MemStore(_, _, _, _, _)
    | ir.MemLoadUnchecked(_, _, _, _, _)
    | ir.MemStoreUnchecked(_, _, _, _, _) -> 1
    ir.Let(_, rhs, body) -> count_in_expr(rhs) + count_in_expr(body)
    Block(_, _, body) -> count_in_expr(body)
    Loop(_, _, _, body) -> count_in_expr(body)
    ir.If(_, _, then_branch, else_branch) ->
      count_in_expr(then_branch) + count_in_expr(else_branch)
    Switch(_, _, arms, default) ->
      list.fold(arms, count_in_expr(default), fn(acc, a) {
        acc + count_in_expr(a.body)
      })
    Charge(_, body) -> count_in_expr(body)
    Try(_, body, handlers) ->
      list.fold(handlers, count_in_expr(body), fn(acc, h) {
        acc + count_in_expr(h.handler)
      })
    _ -> 0
  }
}
