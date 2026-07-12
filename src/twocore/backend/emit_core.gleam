//// Unit 08 — `emit_core` — lower the shared IR to a Core Erlang AST.
////
//// This is the **backend** and the **binding chokepoint** (D3b). It walks an
//// `ir.Module` and produces a `core_erlang.CModule` (unit 03's AST), which unit 04's
//// `build_beam` compiles to a loadable `.beam`. Nothing here knows about WASM — the
//// lowering is uniform across frontends because the IR is (high-level §5).
////
//// ## The lowering strategy (structured control → letrec + tail calls)
////
//// The IR is ANF-with-structured-control. Every `Expr` is emitted in **tail position**
//// of the enclosing function under an explicit *continuation* describing what to do
//// with the values it yields:
////
//// - `KReturn` — the values are the function's result (a Core value list). This is the
////   trivial/tail continuation; it is inlined at every site for free.
//// - `KJump(fname)` — apply a materialised join-point `letrec` function with the values
////   (a tail call). Sharing a join point is how multiple exits of a `block`/`if`/`switch`
////   avoid duplicating the code that follows the construct.
//// - `KBind(names, body, next)` — bind the values to `names`, then emit `body` under
////   `next` (this is exactly how `Let` is lowered: `emit(rhs, KBind(names, body, cont))`).
////
//// A multi-exit construct (`If`/`Switch`/`Block`/`Loop`) first **materialises** a
//// non-trivial (`KBind`) continuation into a `letrec` join point so the continuation is
//// emitted once and every exit tail-applies it; a trivial continuation (`KReturn`/
//// `KJump`) is used as-is. Because every `apply` of a join point and every loop back-edge
//// is in tail position, loops run in **constant space** (the verified §5 template) and
//// `return` from any arm always returns from the function.
////
//// ## The binding chokepoint (D3)
////
//// EVERY runtime reference resolves to a concrete `call '<binding.*_module>':'<fn>'(...)`
//// here and nowhere else, against the fixed `twocore@runtime@*` module names carried by
//// the `Binding` (D3a — no ambient authority, no data-driven `apply(Mod, …)`). Numerics
//// route through `binding.num_module`, traps through `trap_module`, the host boundary
//// through `host_module`, metering through `meter_module`, and the resolved `own` stdlib
//// through `stdlib_module`. The `NumOp → rt_num` name table lives here (`num_op_name`)
//// and MUST match `rt_num`'s frozen names. Phase-1 functions are pure: no runtime record
//// is threaded (D3d).
////
//// ## Name legality
////
//// IR variable names need not be Core-legal; the printer's `legalize_var` maps every raw
//// variable token to a legal, injective Core variable (so per-function-unique IR names
//// stay unique). `emit_core` additionally **gensyms** fresh variables (for trapping-op
//// results and metering binders) and fresh `letrec` function atoms (join points and loop
//// heads), each guaranteed not to collide with any name already present in the function.
////
//// ## Scope (Phase 2)
////
//// In: the Phase-1 surface (`Values`/`Return`/`Num`/`Convert`/`Let`/`If`/`Switch`/`Block`/
//// `Break`/`Loop`/`Continue`/`CallDirect`/`CallHost`/`Trap`/`Charge`) PLUS the stateful ops
//// — `MemLoad`/`MemStore`/`MemSize`/`MemGrow`/`GlobalGet`/`GlobalSet`/`CallIndirect` — and
//// the new float `NumOp`s (`FAbs`…`FGe`/`FCopysign`) and `ConvOp`s (trapping `TruncS`/`TruncU`,
//// total `ConvertS`/`ConvertU`/`F32DemoteF64`/`F64PromoteF32`). All stateful ops route through
//// the ONE state-access seam (`seam_call`) — a direct `call '<binding.X_module>':'op'(...)`
//// for the tier-O cell strategy, no ambient authority (E1/D3a). The backend also emits the
//// generated `instantiate/0` entry (E5) that seeds the per-instance cell and runs the active
//// element/data segments + start. Out (returns a typed `EmitError`, never a panic): `TermOp`
//// and the four term↔numeric boxing `Convert`s (still Phase-3 deferrals).
////
//// ## Phase 3 — posture-agnostic BODIES, seeded `instantiate/0` (F4/F6/F7)
////
//// For every NON-instantiate function body, `emit_module` reads ONLY the `binding.*_module`
//// names (+ `safe_max_pages`); it reads NONE of the policy fields
//// (`opt_level`/`meter`/`bif_gate`/`stdlib`/`host_policy`/`fuel_budget`). Because
//// `profiles.unsafe()` keeps the SAME `*_module` names as `safe()`, those bodies are
//// structurally identical under both profiles for the same IR (Safe and Unsafe are distinct
//// B3 builds; the instance is the unit of policy). The optimizer runs BEFORE emit (F1) and the
//// `Charge`-skip lives in `ir_lower` (F5) — so a metered body's Safe/Unsafe `.core` differs
//// only by charge, never by anything emit_core decides. The ONE documented exception is the
//// synthesized `instantiate/0`, which bakes the per-instance seeds:
//// `rt_meter:seed_fuel(binding.fuel_budget)` FIRST when `meter == MeterFuel`, and ALWAYS
//// `rt_host:seed_policy(binding.host_policy)`. Do NOT branch any non-instantiate body on a
//// policy field: that would break the F5 zero-overhead differential.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import twocore/backend/core_erlang.{
  type CBitSeg, type CClause, type CExpr, type CModule, type CPat, type FName,
  type FunDef, CApply, CApplyExpr, CAtom, CBinary, CBitSeg, CCall, CCase,
  CClause, CCons, CFloat, CFun, CInt, CLet, CLetrec, CNil, CPrimop, CTry, CTuple,
  CValues, CVar, FName, FunDef, PAtom, PCons, PInt, PNil, PTuple, PVar,
}
import twocore/ir.{
  type ConvOp, type Expr, type FuncType, type Function, type IntWidth,
  type Module, type NumOp, type SwitchArm, type TrapReason, type ValType,
  type Value, ArrayOutOfBounds, Block, BoxFloat, BoxInt, Break, CallClosure,
  CallDirect, CallHost, CallIndirect, CastFailure, Charge, ConstF32, ConstF64,
  ConstI32, ConstI64, Continue, Convert, ConvertS, ConvertU, F32DemoteF64,
  F64PromoteF32, FAbs, FAdd, FCeil, FCopysign, FDiv, FEq, FFloor, FGe, FGt, FLe,
  FLt, FMax, FMin, FMul, FNe, FNearest, FNeg, FSqrt, FSub, FTrunc, FW32, FW64,
  FuelExhausted, FuncType, Gc, GlobalGet, GlobalSet, I32Extend16S, I32Extend8S,
  I32WrapI64, I64Extend16S, I64Extend32S, I64Extend8S, I64ExtendI32S,
  I64ExtendI32U, IAdd, IAnd, IClz, ICtz, IDivS, IDivU, IEq, IEqz, IGeS, IGeU,
  IGtS, IGtU, ILeS, ILeU, ILtS, ILtU, IMul, INe, IOr, IPopcnt, IRemS, IRemU,
  IRotl, IRotr, IShl, IShrS, IShrU, ISub, IXor, If, IndirectCallTypeMismatch,
  IntDivByZero, IntOverflow, InvalidConversionToInteger, Let, Loop, MakeClosure,
  MapOp, MemGrow, MemLoad, MemSize, MemStore, MemoryOutOfBounds, NullReference,
  Num, ReinterpretFToI, ReinterpretIToF, Return, Switch, SwitchArm, TF32, TF64,
  TI32, TI64, TTerm, TableOutOfBounds, TermOp, Trap, TruncS, TruncSatS,
  TruncSatU, TruncU, UnboxFloat, UnboxInt, UndefinedElement,
  UninitializedElement, Unreachable, Values, Var, W32, W64,
}
import twocore/runtime/instance.{
  type Binding, type HostPolicy, type MemTier, Atomics, HostDenyAll, HostOpen,
  HostWhitelist, MeterFuel, MeterOff, Nif, Paged, Threaded,
}
import twocore/runtime/profiles

// ─────────────────────────────── fixed runtime-module atoms (D3a) ───────────────────────────────

/// The reference-value runtime module (`runtime/rt_ref` → `twocore@runtime@rt_ref`, R1). The
/// keystone deliberately did NOT add a `binding.ref_module` field (R1 minor), so this fixed,
/// build-controlled atom is the home for `RefIsNull`'s `is_null` seam call. It is D3a-clean —
/// a literal module atom, never program-derived — and is admitted by the security walk's
/// allow-set exactly like a `binding.*_module`.
const ref_module = "twocore@runtime@rt_ref"

/// The non-function-import link/instantiate contract module (`runtime/link` →
/// `twocore@runtime@link`, R4). Home for the `provided_*` externval extractors the generated
/// `instantiate/1(Imports)` calls to weave each positional `Provided` into its `FullDecl`
/// slot. A fixed build-controlled atom (D3a); never a `Binding` field.
const link_module = "twocore@runtime@link"

/// The SIMD lane-op runtime module (`runtime/rt_simd` → `twocore@runtime@rt_simd`, I1/I2). The
/// SIMD binding chokepoint — every `Simd`/`SimdShuffle`/SIMD-memory-assembly seam call targets it
/// (`simd_op_name` maps each neutral `SimdOp` to a concrete `rt_simd` fn here, exactly as
/// `num_op_name → rt_num`). A fixed build-controlled atom (D3a); like `rt_ref`/`link` the keystone
/// did not add a `binding.simd_module` field, so this literal is its home and it is admitted by the
/// security walk's allow-set exactly like a `binding.*_module`. (A future tier-N real-SIMD NIF
/// would swap this one atom — the whole `emit_core` SIMD surface routes through it and nothing
/// else, I3/I8.)
const simd_module = "twocore@runtime@rt_simd"

/// The WasmGC arena runtime (this proposal). Bound only into programs that use a
/// GC instruction (`Gc` lowers to a `seam_call` here), so plain core-WASM modules
/// never pull `rt_gc` in — the whole-program linker's reachability walk drops it.
const gc_module = "twocore@runtime@rt_gc"

/// The tagged-exception runtime module (`runtime/rt_exn` → `twocore@runtime@rt_exn`, J1/T3).
/// The EH binding chokepoint — every `Throw`/`Try`/`ThrowRef` seam call targets it
/// (`throw_exn`/`match_tag`/`is_wasm_exn`/`reraise`/`capture_exnref`/`throw_ref`, the ONE place
/// the `{wasm_exn, …}` term shape lives — T7/D3b). A fixed build-controlled atom (D3a); like
/// `rt_ref`/`link`/`rt_simd` the keystone did not add a `binding.exn_module` field (there is no
/// alternate exception backend to tier-swap, D2), so this literal is its home and it is admitted
/// by the security walk's allow-set exactly like a `binding.*_module`. `erlang:throw`/
/// `erlang:raise/3` live INSIDE `rt_exn`, never in generated code — the homogeneous twocore-only
/// allow-set (S5, no `erlang` entry).
const exn_module = "twocore@runtime@rt_exn"

// ─────────────────────────────── error type (D4) ───────────────────────────────

/// This stage's own error type (D4 — there is no shared `StageError`). `emit_module`
/// returns `Error(EmitError)` — never a panic — for any IR node outside the lowering
/// surface or for a structurally inconsistent IR.
///
/// - `UnsupportedNode(node)`: an IR node not lowered (Phase-2 leaves only `"term_op"`
///   and the four term↔numeric boxing `Convert`s — `"box_int"`/`"unbox_int"`/
///   `"box_float"`/`"unbox_float"` — out of scope). `node` is a stable lowercase tag for
///   the node kind. The Phase-2 stateful ops (memory/global/table/size/grow) and the
///   trapping/total `Convert`s are now lowered through the state-access seam, so they no
///   longer appear here.
/// - `ArityMismatch(expected, got)`: a value-list arity clash — a `Let`/join-point bind
///   whose name count (`expected`) does not equal the number of values produced (`got`).
/// - `UnboundLabel(label)`: a `Break`/`Continue` referencing a label not on the
///   enclosing block/loop stack, or a `Continue` targeting a `Block` (which has no
///   back-edge).
/// - `UnknownFunction(name)`: a `CallDirect`, `ExportFn`, `ElementSegment` func, or
///   `start` naming a function the module does not define.
/// - `NonConstInit(detail)`: a `GlobalDecl.init` / data-or-element-segment `offset`
///   expression that is not a Phase-2 constant literal (`t.const` → `Values([Const])`),
///   so the `instantiate/0` entry cannot constant-fold it to a bit pattern. `detail` is a
///   human-readable reason. (Validation upstream already enforces the const-expr rule;
///   this is the fail-closed backend defence — never a panic, never arbitrary emitted
///   code in the seed decl.)
pub type EmitError {
  UnsupportedNode(node: String)
  ArityMismatch(expected: Int, got: Int)
  UnboundLabel(label: String)
  UnknownFunction(name: String)
  NonConstInit(detail: String)
  /// A `Throw`/`Try` catch clause referencing a tag NAME the module does not declare
  /// (neither in `Module.tags` nor as an imported `ImportTag`, T4). Fail-closed — the tag's
  /// module-local `Int` identity cannot be resolved, so no `{wasm_exn, TagId, …}` term can be
  /// built. Validation upstream already resolves tag references; this is the backend defence
  /// (never a panic).
  UnknownTag(name: String)
  /// A `CallHost("js", op, args)` (Phase-8 unit 05, K6) whose `op` is NOT one of the
  /// build-fixed `rt_js` ops (`resolve_js`). FAIL-CLOSED (K6/D3a): the JS runtime boundary is a
  /// literal `case` bound at build time to the `js_runtime_module` atom — an unrecognised `op`
  /// resolves to NO function, so no `call`/`apply` is emitted and the module is rejected here
  /// rather than a data-derived op reaching an arbitrary MFA. Never a panic. The real `rt_js`
  /// (the frontend's) will grow this op set; a new op is registered by adding one literal arm to
  /// `resolve_js` (and the `ir_lower` "js" admit + the `rt_js` impl).
  UnknownJsOp(op: String)
}

// ─────────────────────────────── internal state ───────────────────────────────

/// Read-only emission context shared across one module:
/// - `binding`: the runtime `Binding` (the chokepoint table).
/// - `fn_arity`: each defined function's PARAMETER count (the `apply 'f'/n` arity, for
///   resolving `CallDirect`/exports). NOTE: this is the Phase-1 arity (`n`); a
///   state-reaching function under `Threaded` is emitted and applied at `n+1` (the leading
///   `InstanceState`), so the seam adds `+1` at the call/export site (§B).
/// - `fn_results`: each defined function's RESULT count, needed to unpack a call: a
///   function returning 0/1/many values is realised as a single BEAM value (a dummy / the
///   bare value / a tuple — see `function_return`), so the caller must unpack it back into
///   the right number of values.
/// - `fn_sig`: each defined function's `FuncType` (for the `call_indirect` element type tag).
/// - `fn_state_reaching`: under `state_strategy: Threaded`, the transitive-closure set of
///   functions that touch instance state (§A.3). A function in this set is emitted at
///   arity `n+1`, threads the `InstanceState` record as its leading parameter, and returns
///   `{ResultPackage, St'}`. Computed once in `emit_module`; unused (but harmless) under
///   `Cell`, where every function keeps its Phase-1 shape.
/// - `table_index`: each table NAME → its absolute tableidx in the imports-first WASM table
///   index space (imported tables at the low indices, then `module.tables`, R7/§E.2). The
///   reference/bulk table ops carry a `table: String`; this resolves it to the `Int` index the
///   `rt_table` seam takes. Index 0 is the Phase-2 single/default table (byte-identical).
/// - `elements`: the module's element segments, indexed by `table.init`'s `seg` immediate to
///   recover the segment's compile-time init items (rendered to references + drop-gated, R2).
/// - `data_segments`: the module's data segments, indexed by `memory.init`'s `seg` immediate to
///   recover the segment's compile-time bytes (drop-gated, R2).
/// - `ref_global_names`: the set of REFERENCE-typed global names (funcref/externref, R8) — an
///   `ExportGlobal` of one routes through `ref_global_get` (the `ref_globals` map) rather than
///   the numeric `global_get`.
type Ctx {
  Ctx(
    binding: Binding,
    fn_arity: Dict(String, Int),
    fn_results: Dict(String, Int),
    fn_sig: Dict(String, FuncType),
    fn_state_reaching: Set(String),
    table_index: Dict(String, Int),
    elements: List(ir.ElementSegment),
    data_segments: List(ir.DataSegment),
    ref_global_names: Set(String),
    /// Each exception-tag NAME → its module-local `Int` identity (its absolute tagidx in the
    /// imports-first tag-index space, T4). `Throw(tag)` resolves to `rt_exn:throw_exn(<idx>, …)`
    /// and a `CatchTag.OnTag(tag)` dispatches on the SAME `<idx>` via `rt_exn:match_tag(R, <idx>)`,
    /// so throw and catch agree on ONE identity (the spec tag-identity match, §4.5). Empty for a
    /// tag-free module (no `Throw`/`Try` ever resolves) — inert, byte-identical to Phase 6.
    tag_index: Dict(String, Int),
  )
}

/// A compile-time continuation — what to do with the value list an `Expr` yields.
///
/// - `KReturn`: yield as the function result (a Core value list). Trivial; inlined.
/// - `KJump(target)`: tail-apply a materialised join-point `letrec` function.
/// - `KBind(names, body, next)`: bind the values to `names`, then emit `body` under
///   `next`.
type Cont {
  KReturn
  KJump(target: FName)
  KBind(names: List(String), body: Expr, next: Cont)
}

/// The state-threading channel carried alongside `cont` under `state_strategy: Threaded`
/// (keystone §A.2). It is *environment*, not accumulator: it flows down, is REBOUND after
/// each mutating op, and BRANCHES (each `if` arm / loop iteration has its own live record),
/// so it is a parameter, never stored in `EmitState`.
///
/// - `NoState`: the `Cell` strategy, OR a PURE function under `Threaded` — emit today's
///   code. No record is threaded; functions keep their Phase-1 arity; `KReturn` yields the
///   bare `function_return` package.
/// - `Threading(cur)`: `cur` is the raw Core-variable name currently holding the live
///   `InstanceState`. Reads pass `cur`; mutators REBIND a fresh var and continue under
///   `Threading(fresh)`; `KReturn` pairs the package with `cur` into `{Package, cur}`; a
///   `KJump`/loop back-edge PREPENDS `cur` to the value list.
type StateChan {
  NoState
  Threading(cur: String)
}

/// One entry of the compile-time label → continuation stack.
///
/// - `label`: the IR label of the enclosing `Block`/`Loop`.
/// - `break_cont`: the continuation a `Break(label, vs)` (and a `Loop`/`Block`
///   fall-through) resolves to. Always trivial (`KReturn`/`KJump`) — a non-trivial
///   continuation is materialised before the label is pushed.
/// - `continue_target`: `Some(fname)` for a `Loop` (the head to tail-apply on
///   `Continue`); `None` for a `Block` (which has no back-edge).
type LabelEntry {
  LabelEntry(label: String, break_cont: Cont, continue_target: Option(FName))
}

/// Mutable-threaded emission state: a monotonic gensym `counter`, the reserved variable
/// names (`vars`) and reserved function atoms (`fns`) that gensym must avoid, and the
/// scoped label stack (`labels`).
type EmitState {
  EmitState(
    counter: Int,
    vars: Set(String),
    fns: Set(String),
    labels: List(LabelEntry),
  )
}

/// A fresh Core-variable raw name guaranteed distinct from every name already reserved
/// in this function. Returns the name and the advanced state.
fn fresh_var(s: EmitState) -> #(String, EmitState) {
  let cand = "g" <> int.to_string(s.counter)
  let s2 = EmitState(..s, counter: s.counter + 1)
  case set.contains(s.vars, cand) {
    True -> fresh_var(s2)
    False -> #(cand, EmitState(..s2, vars: set.insert(s2.vars, cand)))
  }
}

/// A fresh `letrec` function atom guaranteed distinct from every module function name and
/// previously-generated join-point/loop atom. Returns the name and the advanced state.
fn fresh_fn(s: EmitState) -> #(String, EmitState) {
  let cand = "j" <> int.to_string(s.counter)
  let s2 = EmitState(..s, counter: s.counter + 1)
  case set.contains(s.fns, cand) {
    True -> fresh_fn(s2)
    False -> #(cand, EmitState(..s2, fns: set.insert(s2.fns, cand)))
  }
}

/// Push `entry` for the dynamic extent of the construct that owns the label.
fn push_label(s: EmitState, entry: LabelEntry) -> EmitState {
  EmitState(..s, labels: [entry, ..s.labels])
}

/// Restore the label stack to `labels` (popping a scope) while keeping the monotonic
/// gensym counter and reserved-name sets from `s`.
fn restore_labels(s: EmitState, labels: List(LabelEntry)) -> EmitState {
  EmitState(..s, labels: labels)
}

/// Resolve a label on the enclosing stack, or `Error(UnboundLabel)`.
fn find_label(s: EmitState, label: String) -> Result(LabelEntry, EmitError) {
  case list.find(s.labels, fn(e) { e.label == label }) {
    Ok(e) -> Ok(e)
    Error(_) -> Error(UnboundLabel(label))
  }
}

// ─────────────────────────────── module entry point ───────────────────────────────

/// Lower a shared-IR module to a Core Erlang module AST (unit 03's `CModule`), resolving
/// every runtime reference through `binding` (D3b).
///
/// - `module`: the IR module to lower. Its `functions` become top-level Core defs
///   `'name'/arity = fun (params…) -> <body>`; its `exports` become the Core export list
///   (an `ExportFn` whose `export_name` differs from `fn_name` gets a thin forwarding
///   wrapper, since Core Erlang exports a function by its own name/arity).
/// - `binding`: the build-time runtime binding (the fixed `twocore@runtime@*` module
///   names). Never embedded in or threaded through generated code (D3d).
///
/// Returns `Ok(CModule)` on success. Returns `Error(EmitError)` — never a panic — for any
/// IR node outside the Phase-1 surface (`CallIndirect`, memory/global/term ops, boxing
/// conversions), an unknown `CallDirect`/export target, an unbound `Break`/`Continue`
/// label, or a value-list arity clash. The emitted module name is `module.name` verbatim;
/// `twocore@…` namespacing is the caller's responsibility (overview §5).
pub fn emit_module(
  module: Module,
  binding: Binding,
) -> Result(CModule, EmitError) {
  let fn_arity =
    list.map(module.functions, fn(f) { #(f.name, list.length(f.params)) })
    |> dict.from_list
  let fn_results =
    list.map(module.functions, fn(f) { #(f.name, list.length(f.result)) })
    |> dict.from_list
  let fn_sig =
    list.map(module.functions, fn(f) { #(f.name, ir.signature(f)) })
    |> dict.from_list
  // The state-reaching call-graph closure (§A.3) — computed ONCE, keyed on only under
  // `Threaded`. Under `Cell` it is inert (every function keeps its Phase-1 shape).
  let fn_state_reaching = state_reaching_closure(module.functions)
  let ctx =
    Ctx(
      binding: binding,
      fn_arity: fn_arity,
      fn_results: fn_results,
      fn_sig: fn_sig,
      fn_state_reaching: fn_state_reaching,
      table_index: build_table_index(module),
      elements: module.elements,
      data_segments: module.data_segments,
      ref_global_names: reference_global_names(module),
      tag_index: build_tag_index(module),
    )
  use defs <- result.try(
    list.try_map(module.functions, fn(f) { emit_function(f, ctx) }),
  )
  use #(export_names, wrappers) <- result.try(emit_exports(module.exports, ctx))
  // The generated instantiation entry (E5) — seeds the fresh per-instance cell and runs
  // the active element/data segments + start in WASM spec order. Always emitted and
  // exported so the harness (unit 11) can call `instantiate/0` in the instance process.
  use inst_def <- result.try(emit_instantiate(module, ctx))
  // The generated entry is `instantiate/1(Imports)` for an import-bearing module (R4/S5) and
  // `instantiate/0` for an import-free one (byte-identical, H7). `Imports` carries the state imports
  // AND — when the module calls an imported function — the function-import dispatch closures.
  let inst_arity = case count_import_slots(module) > 0 {
    True -> 1
    False -> 0
  }
  let cmod =
    core_erlang.CModule(
      name: module.name,
      exports: list.append(export_names, [FName("instantiate", inst_arity)]),
      attributes: [],
      defs: list.append(list.append(defs, wrappers), [inst_def]),
    )
  // Lever 6 (opt-in, default OFF): beta-reduce single-use, non-recursive `letrec` join funs.
  // Gated on `binding.inline_joins` so the DEFAULT emitted Core is byte-identical (the pass is a
  // pure `CModule -> CModule` rewrite; when the flag is off it is never applied).
  let cmod2 = case binding.inline_joins {
    True -> inline_join_funs(cmod)
    False -> cmod
  }
  // Lever 8 (opt-in, default OFF): eliminate a redundant outer `band` mask subsumed by an inner
  // one. Gated on `binding.lazy_mask`, applied AFTER inlining (so a mask chain revealed by a
  // spliced join is also collapsed); a pure `CModule -> CModule` rewrite, byte-identical when off.
  let cmod3 = case binding.lazy_mask {
    True -> elim_redundant_masks(cmod2)
    False -> cmod2
  }
  Ok(cmod3)
}

/// Build the Core export list and any forwarding wrappers from the IR exports.
///
/// **Under `Cell`** (byte-identical to Phase 2/3): for `ExportFn(export_name, fn_name)`, if
/// the two names are equal export `'fn_name'/arity` directly; otherwise emit a forwarding
/// wrapper `'export_name'/arity = fun(A…) -> apply 'fn_name'/arity(A…)` (Core Erlang exports
/// a function by its own name/arity).
///
/// **Under `Threaded`** the export boundary is made UNIFORM (§B.4) so unit 08's run-ABI can
/// always pass the `InstanceState` leading and always receive `{Package, St'}` — every export
/// presents at arity `n+1`. For `ExportFn(export_name, fn_name)`:
/// - `fn_name` STATE-REACHING and `export_name == fn_name` → export the internal
///   `'fn_name'/(n+1)` DIRECTLY (no wrapper). `emit_function` already emitted it with exactly
///   the run-ABI shape `fun(St, A…) -> {Package, St'}`; synthesizing a same-name/arity wrapper
///   would emit a DUPLICATE `FunDef` (invalid Core) that also self-applies (infinite
///   recursion). This mirrors the `Cell` name-equality check and is the common case
///   (`ExportFn(f, f)`).
/// - `fn_name` STATE-REACHING and `export_name != fn_name` → forwarding wrapper
///   `'export_name'/(n+1) = fun(St, A…) -> apply 'fn_name'/(n+1)(St, A…)` (already
///   `{Package, St'}`). A distinct name cannot collide with the internal `'fn_name'/(n+1)`.
/// - `fn_name` PURE (either name relation) → adapting wrapper
///   `'export_name'/(n+1) = fun(St, A…) -> {apply 'fn_name'/n(A…), St}` — threads `St`
///   straight through. Even when `export_name == fn_name`, the DISTINCT ARITY (`n+1` vs the
///   internal `'fn_name'/n`) keeps them apart, so no collision.
///
/// `Error(UnknownFunction)` if `fn_name` is not defined in the module.
fn emit_exports(
  exports: List(ir.ExportDecl),
  ctx: Ctx,
) -> Result(#(List(FName), List(FunDef)), EmitError) {
  list.try_fold(exports, #([], []), fn(acc, exp) {
    let #(names, wrappers) = acc
    case exp {
      // FUNCTION exports (the Phase-1..4 surface, byte-identical) lower via the existing
      // cell/threaded run-ABI wrappers below.
      ir.ExportFn(export_name, fn_name) ->
        emit_fn_export(export_name, fn_name, names, wrappers, ctx)
      // Exported STATE (H4): a build-controlled `<export_name>/0` (cell) / `<export_name>/1(St)`
      // (threaded) accessor reading the exported global/table/memory out of the instance state,
      // so the harness's `(get $m "x")` and `spectest`'s exported table/memory resolve (09/11).
      ir.ExportGlobal(export_name, global_name) -> {
        let ref = set.contains(ctx.ref_global_names, global_name)
        let cell_fn = case ref {
          True -> "ref_global_get"
          False -> "global_get"
        }
        let threaded_fn = case ref {
          True -> "t_ref_global_get"
          False -> "t_global_get"
        }
        let cell =
          seam_call(ctx.binding.state_module, cell_fn, [
            core_binary_string(global_name),
          ])
        let threaded =
          seam_call(ctx.binding.state_module, threaded_fn, [
            CVar(wrapper_state_param),
            core_binary_string(global_name),
          ])
        Ok(add_state_export(export_name, cell, threaded, names, wrappers, ctx))
      }
      ir.ExportTable(export_name, table_name) -> {
        let idx = table_idx(ctx, table_name)
        let cell = seam_call(ctx.binding.state_module, "table_at", [CInt(idx)])
        let threaded =
          seam_call(ctx.binding.state_module, "t_table_at", [
            CVar(wrapper_state_param),
            CInt(idx),
          ])
        Ok(add_state_export(export_name, cell, threaded, names, wrappers, ctx))
      }
      ir.ExportMemory(export_name, mem_index) -> {
        let cell =
          seam_call(ctx.binding.state_module, "mem_at", [
            CInt(mem_index),
          ])
        let threaded =
          seam_call(ctx.binding.state_module, "t_mem_at", [
            CVar(wrapper_state_param),
            CInt(mem_index),
          ])
        Ok(add_state_export(export_name, cell, threaded, names, wrappers, ctx))
      }
      // An exported exception TAG (Phase-7, T2) is INERT for single-module execution (nothing
      // imports it), and a tag seeds no runtime state under the static-`TagId` model (§H.1) — so
      // it adds NO export name / wrapper. Byte-neutral (no Phase-1..6 module has one). P7-05/link
      // owns the cross-module `ProvidedTag` identity if pursued.
      ir.ExportTag(_export_name, _tag_name) -> Ok(#(names, wrappers))
    }
  })
  |> result.map(fn(acc) {
    let #(names, wrappers) = acc
    #(list.reverse(names), list.reverse(wrappers))
  })
}

/// Lower one `ExportFn(export_name, fn_name)` to its export name/arity + any forwarding/adapting
/// wrapper, prepending to `names`/`wrappers` (unchanged Phase-1..4 cell/threaded run-ABI logic —
/// see `emit_exports`). `Error(UnknownFunction)` if `fn_name` is not defined.
fn emit_fn_export(
  export_name: String,
  fn_name: String,
  names: List(FName),
  wrappers: List(FunDef),
  ctx: Ctx,
) -> Result(#(List(FName), List(FunDef)), EmitError) {
  case dict.get(ctx.fn_arity, fn_name) {
    Error(_) -> Error(UnknownFunction(fn_name))
    Ok(arity) ->
      case is_threaded(ctx) {
        False ->
          // ── Cell: unchanged (direct export when names match, else a bare forwarder). ──
          case export_name == fn_name {
            True -> Ok(#([FName(fn_name, arity), ..names], wrappers))
            False -> {
              let params = wrapper_arg_params(arity)
              let body = CApply(FName(fn_name, arity), list.map(params, CVar))
              let wrapper =
                FunDef(FName(export_name, arity), CFun(params, body))
              Ok(#([FName(export_name, arity), ..names], [wrapper, ..wrappers]))
            }
          }
        True ->
          case set.contains(ctx.fn_state_reaching, fn_name) {
            // A state-reaching def already IS the `n+1` run-ABI export.
            True ->
              case export_name == fn_name {
                // Export it directly — NO second def (the P3 collision fix).
                True -> Ok(#([FName(fn_name, arity + 1), ..names], wrappers))
                // A distinctly-named forwarder to the internal `n+1` def.
                False -> {
                  let params = wrapper_arg_params(arity)
                  let body =
                    CApply(FName(fn_name, arity + 1), [
                      CVar(wrapper_state_param),
                      ..list.map(params, CVar)
                    ])
                  let wrapper =
                    FunDef(
                      FName(export_name, arity + 1),
                      CFun([wrapper_state_param, ..params], body),
                    )
                  Ok(
                    #([FName(export_name, arity + 1), ..names], [
                      wrapper,
                      ..wrappers
                    ]),
                  )
                }
              }
            // A pure def gets a thin `n+1` adapter returning `{apply 'g'/n(A…), St}`.
            False -> {
              let params = wrapper_arg_params(arity)
              let applied =
                CApply(FName(fn_name, arity), list.map(params, CVar))
              let body = CTuple([applied, CVar(wrapper_state_param)])
              let wrapper =
                FunDef(
                  FName(export_name, arity + 1),
                  CFun([wrapper_state_param, ..params], body),
                )
              Ok(
                #([FName(export_name, arity + 1), ..names], [
                  wrapper,
                  ..wrappers
                ]),
              )
            }
          }
      }
  }
}

/// Build a STATE-export accessor and prepend it to `names`/`wrappers`. Cell:
/// `'<export_name>'/0 = fun () -> <cell>` (the reader). Threaded: `'<export_name>'/1 =
/// fun (St) -> {<threaded>, St}` — the run-ABI (a value paired with the unchanged record, since a
/// state export is read-only). `cell`/`threaded` are the runtime reads (`global_get`/`table_at`/
/// `mem_at` and their `t_*` twins); `threaded` references `wrapper_state_param` as its `St`.
fn add_state_export(
  export_name: String,
  cell: CExpr,
  threaded: CExpr,
  names: List(FName),
  wrappers: List(FunDef),
  ctx: Ctx,
) -> #(List(FName), List(FunDef)) {
  case is_threaded(ctx) {
    False -> {
      let def = FunDef(FName(export_name, 0), CFun([], cell))
      #([FName(export_name, 0), ..names], [def, ..wrappers])
    }
    True -> {
      let body = CTuple([threaded, CVar(wrapper_state_param)])
      let def = FunDef(FName(export_name, 1), CFun([wrapper_state_param], body))
      #([FName(export_name, 1), ..names], [def, ..wrappers])
    }
  }
}

/// The `arity` positional argument-parameter names for a synthesized export wrapper
/// (`ea0`, `ea1`, …). Wrapper-local, so they only need to be internally distinct + Core-legal.
fn wrapper_arg_params(arity: Int) -> List(String) {
  list.index_map(list.repeat("", arity), fn(_, i) { "ea" <> int.to_string(i) })
}

/// The leading `InstanceState` parameter name of a synthesized THREADED export wrapper.
/// Distinct from every `wrapper_arg_params` name (`ea…`), so no wrapper-local collision.
const wrapper_state_param = "est"

/// Lower one IR `Function` to a top-level Core `FunDef`.
///
/// The body is emitted in tail position under `KReturn`. The Core `fun`'s parameters are
/// the IR param names verbatim (the printer legalizes them). Declared `locals` are not
/// pre-bound: in the Phase-1 corpus `locals` is empty and all body bindings come from
/// `Let`/loop params; a frontend that populates `locals` must also bind them.
///
/// Under `state_strategy: Threaded`, a STATE-REACHING function (`ctx.fn_state_reaching`) is
/// emitted as `'f'/(n+1) = fun (St, params…) -> {ResultPackage, St'}` — the `InstanceState`
/// record threaded as the LEADING parameter and paired with the outgoing record on return
/// (§B.1). A PURE function (and every function under `Cell`) keeps its Phase-1 `'f'/n` shape
/// (channel `NoState`), so pure numeric leaves pay nothing.
fn emit_function(f: Function, ctx: Ctx) -> Result(FunDef, EmitError) {
  let reserved_vars = collect_vars(f)
  let reserved_fns = set.from_list(dict.keys(ctx.fn_arity))
  let state0 =
    EmitState(counter: 0, vars: reserved_vars, fns: reserved_fns, labels: [])
  case is_threaded(ctx) && set.contains(ctx.fn_state_reaching, f.name) {
    True -> {
      let #(st0, state1) = fresh_var(state0)
      use #(body, _state) <- result.try(emit(
        f.body,
        KReturn,
        Threading(st0),
        state1,
        ctx,
      ))
      let params = [st0, ..list.map(f.params, fn(l) { l.name })]
      Ok(FunDef(FName(f.name, list.length(f.params) + 1), CFun(params, body)))
    }
    False -> {
      use #(body, _state) <- result.try(emit(
        f.body,
        KReturn,
        NoState,
        state0,
        ctx,
      ))
      let params = list.map(f.params, fn(l) { l.name })
      Ok(FunDef(FName(f.name, list.length(f.params)), CFun(params, body)))
    }
  }
}

/// `True` when the build threads the `InstanceState` record (`state_strategy: Threaded`),
/// `False` for the `Cell` (pdict) strategy — the ONE codegen-shape switch (§A.1).
fn is_threaded(ctx: Ctx) -> Bool {
  ctx.binding.state_strategy == Threaded
}

// ─────────────────────────── the imports-first index spaces (R7/§E.2) ───────────────────────────

/// Build the table NAME → absolute-tableidx map over the imports-first WASM table index space
/// (spec §2.5.1: imports precede definitions). Imported tables occupy the low indices in import
/// order (local name `t<idx>`, the `lower` convention), then `module.tables` continue at
/// `imported_table_count + i` (their `TableDecl.name` is already `t<abs>`). For the H7 case (no
/// imported tables, one table) every name resolves to `0` → byte-identical `call_indirect`.
fn build_table_index(module: Module) -> Dict(String, Int) {
  let #(imported, itc) =
    list.fold(module.imports, #([], 0), fn(acc, imp) {
      let #(pairs, k) = acc
      case imp {
        ir.ImportTable(..) -> #([#("t" <> int.to_string(k), k), ..pairs], k + 1)
        _ -> #(pairs, k)
      }
    })
  let defined = list.index_map(module.tables, fn(t, i) { #(t.name, itc + i) })
  dict.from_list(list.append(list.reverse(imported), defined))
}

/// Build the tag NAME → module-local `Int` identity map over the imports-first tag-index space
/// (spec §2.5.1: imports precede definitions — the same discipline as tables/globals, T4).
/// Imported tags (`ImportTag`) occupy the low indices in import order (named `tag<k>`, the
/// `lower` convention); then `module.tags` continue at `imported_tag_count + i` (their
/// `TagDecl.name` is already `tag<abs>`). A `Throw`/`OnTag` resolving a same-module tag maps to
/// this `Int` symmetrically at throw + catch. Empty for a tag-free module (no `ImportTag`, no
/// `tags`) → inert, byte-identical to Phase 6.
fn build_tag_index(module: Module) -> Dict(String, Int) {
  let #(imported, itc) =
    list.fold(module.imports, #([], 0), fn(acc, imp) {
      let #(pairs, k) = acc
      case imp {
        ir.ImportTag(..) -> #([#("tag" <> int.to_string(k), k), ..pairs], k + 1)
        _ -> #(pairs, k)
      }
    })
  let defined = list.index_map(module.tags, fn(t, i) { #(t.name, itc + i) })
  dict.from_list(list.append(list.reverse(imported), defined))
}

/// Resolve an exception-tag NAME to its module-local `Int` identity (T4), or `Error(UnknownTag)`
/// if the module declares no such tag (fail-closed — validation guarantees the name exists).
fn resolve_tag(ctx: Ctx, name: String) -> Result(Int, EmitError) {
  case dict.get(ctx.tag_index, name) {
    Ok(i) -> Ok(i)
    Error(_) -> Error(UnknownTag(name))
  }
}

/// The set of BOXED global NAMES — reference (funcref/externref, R8) AND `v128` (S6) — the union of
/// imported boxed globals (named `g<idx>` in imports-first order) and defined boxed globals
/// (`GlobalDecl.name`). Used so `ExportGlobal` and the op-site `global.get`/`global.set` route a
/// boxed global through the `ref_globals` map (`ref_global_get`/`set`), not the numeric raw-bit
/// `globals` path (which stays byte-identical for D5).
fn reference_global_names(module: Module) -> Set(String) {
  let #(imported, _gidx) =
    list.fold(module.imports, #(set.new(), 0), fn(acc, imp) {
      let #(names, k) = acc
      case imp {
        ir.ImportGlobal(_, _, ty, _) ->
          case is_boxed_global_type(ty) {
            True -> #(set.insert(names, "g" <> int.to_string(k)), k + 1)
            False -> #(names, k + 1)
          }
        _ -> #(names, k)
      }
    })
  list.fold(module.globals, imported, fn(names, g) {
    case is_boxed_global_type(g.ty) {
      True -> set.insert(names, g.name)
      False -> names
    }
  })
}

/// `True` iff `ty` is a reference type (`TFuncRef`/`TExternRef`) — the funcref/externref
/// globals that route through `rt_state`'s parallel `ref_globals` map (R8).
fn is_reference_type(ty: ValType) -> Bool {
  case ty {
    // `TExnRef` (Phase-7, T9) is a reference type — a semantic MUST-ADD (not a hard compile
    // break): an exnref-typed global must route through `rt_state`'s boxed `ref_globals` map, not
    // the numeric raw-bit path. Leaving it at the `_ -> False` default would mis-box it.
    // `TTerm` (Phase-8 GC) is a boxed reference: a GC `(ref …)` global holds a `{gc,Id}` /
    // `{i31,V}` / `{ref_null}` handle, which must route through `rt_state`'s boxed `ref_globals`
    // map, not the numeric raw-bit path. TTerm globals arise ONLY from GC `ast.Ref(_)`, so this
    // is additive — no non-GC module has a TTerm global (headline byte-identical).
    ir.TFuncRef | ir.TExternRef | ir.TExnRef | ir.TTerm -> True
    _ -> False
  }
}

/// Resolve a table NAME to its absolute tableidx. Defaults to `0` when the map has no entry
/// (validation guarantees the name exists; the default preserves the H7 single-table path).
fn table_idx(ctx: Ctx, name: String) -> Int {
  result.unwrap(dict.get(ctx.table_index, name), 0)
}

/// The `index`-th element of `xs`, or `Error(Nil)` — a total list index (no partial `list.at`).
fn nth(xs: List(a), index: Int) -> Result(a, Nil) {
  case list.drop(xs, index) {
    [x, ..] -> Ok(x)
    [] -> Error(Nil)
  }
}

// ─────────────────────────── the state-reaching call-graph closure (§A.3) ───────────────────────────

/// Compute the set of STATE-REACHING functions: the transitive `CallDirect` closure of the
/// functions whose body contains a stateful op (§A.3). A function is state-reaching iff it
/// (1) contains any of the seven stateful nodes — `MemLoad`/`MemStore`/`MemSize`/`MemGrow`/
/// `GlobalGet`/`GlobalSet`/`CallIndirect` (reads count, since they need the record to read
/// FROM) — or (2) transitively `CallDirect`s a state-reaching function. Computing it as a
/// closure (not just "direct") is the correctness crux of uniform threading: a caller of a
/// memory-touching helper must thread the record even with no stateful node of its own.
///
/// `CallHost`/`Charge` are NOT seeds (the host boundary + fuel counter never touch the
/// record); a `CallIndirect` TARGET is reached via the table (not a `CallDirect` edge), so a
/// pure table target stays pure and only the closure adapter absorbs the ABI (§C). Under
/// `Cell` the result is unused.
///
/// **PUBLIC — the Phase-12 keystone cross-file reach (P12-01, «IFACE-DESC-FROZEN»).**
/// `backend/iface.describe/2` reuses THIS exact function to derive each export's
/// `touches_state`, so the typed host binding's arity/threading always agrees with the emitted
/// `.beam` ABI. It MUST stay the single source of truth for state-reachingness — the shallow
/// `expr_touches_state` (below) is NOT the descriptor's input (a pure-*bodied* export that
/// `CallDirect`s a memory helper is emitted at `n+1` and threads `St`, which only the transitive
/// closure captures). Promoting it changes no emitted output (same callers, same result).
pub fn state_reaching_closure(functions: List(Function)) -> Set(String) {
  let seeds =
    list.filter_map(functions, fn(f) {
      case expr_touches_state(f.body) {
        True -> Ok(f.name)
        False -> Error(Nil)
      }
    })
    |> set.from_list
  let edges =
    list.map(functions, fn(f) { #(f.name, direct_callees(f.body, set.new())) })
    |> dict.from_list
  reaching_fixpoint(functions, edges, seeds)
}

/// The monotone fixpoint over the `CallDirect` edge graph: add any function whose callee set
/// intersects the current state-reaching set, until no function is added. Terminates because
/// the set only grows and is bounded by the (finite) function count.
fn reaching_fixpoint(
  functions: List(Function),
  edges: Dict(String, Set(String)),
  current: Set(String),
) -> Set(String) {
  let next =
    list.fold(functions, current, fn(acc, f) {
      case set.contains(acc, f.name) {
        True -> acc
        False -> {
          let callees = result.unwrap(dict.get(edges, f.name), set.new())
          case any_member(callees, acc) {
            True -> set.insert(acc, f.name)
            False -> acc
          }
        }
      }
    })
  case set.size(next) == set.size(current) {
    True -> current
    False -> reaching_fixpoint(functions, edges, next)
  }
}

/// `True` iff any element of `xs` is a member of `ys` (a non-empty set intersection).
fn any_member(xs: Set(String), ys: Set(String)) -> Bool {
  set.fold(xs, False, fn(found, x) { found || set.contains(ys, x) })
}

/// `True` iff `expr` (recursively) contains one of the seven stateful nodes — the seeding
/// condition (§A.3). `CallDirect`/`CallHost`/`Charge` are NOT stateful nodes (a caller's
/// state-reaching-ness flows through the `CallDirect` closure, not this scan).
fn expr_touches_state(expr: Expr) -> Bool {
  case expr {
    MemLoad(..)
    | MemStore(..)
    | // Phase-10 unchecked accesses (N4) read/write linear memory exactly like the checked twins, so
      // a function containing one is state-reaching under `Threaded` (it must thread `St`). Omitting
      // them here would emit an unchecked-only body with the CELL seam under a Threaded build →
      // an un-seeded-cell panic.
      ir.MemLoadUnchecked(..)
    | ir.MemStoreUnchecked(..)
    | MemSize(..)
    | MemGrow(..)
    | GlobalGet(..)
    | GlobalSet(..)
    | CallIndirect(..)
    | // Phase-5 TABLE + BULK-MEMORY nodes read/write mutable instance state (a table slot, a
      // memory range, or passive drop-state), so a function containing one is state-reaching
      // under `Threaded` (§A.2/§A.3). No Phase-1..4 module has them. The REFERENCE nodes
      // (`RefFunc`/`RefIsNull`, and the `ConstNull` value) are PURE — a reference is produced
      // from a compile-time name or a constant sentinel and reaches no record — so they are NOT
      // seeds (a reference-only function keeps its Phase-1 pure arity, the H7-neutral rule §A.2).
      ir.TableGet(..)
    | ir.TableSet(..)
    | ir.TableSize(..)
    | ir.TableGrow(..)
    | ir.TableFill(..)
    | ir.TableInit(..)
    | ir.TableCopy(..)
    | ir.ElemDrop(..)
    | ir.MemFill(..)
    | ir.MemCopy(..)
    | ir.MemInit(..)
    | ir.DataDrop(..)
    | // Phase-6 (§A.3): the four SIMD-MEMORY nodes read/write linear memory (like `MemLoad`/
      // `MemStore`), and `CallImport` reads the closure capability from the instance's `func_imports`
      // vector — so a function containing one is state-reaching under `Threaded`. The PURE lane ops
      // (`Simd`/`SimdShuffle`) reach no record (produced from operand values + a compile-time op tag,
      // like `Num`/`RefFunc`), so they are NOT seeds — the I7-neutral rule keeping a
      // SIMD-arithmetic-only body at its Phase-1 pure arity.
      ir.SimdLoad(..)
    | ir.SimdStore(..)
    | ir.SimdLoadLane(..)
    | ir.SimdStoreLane(..)
    | ir.CallImport(..)
    | // Phase-13 (Q13-05): a tail `return_call_indirect` READS the table capability and a tail
      // `return_call_import` READS the func-import capability — exactly like their non-tail twins
      // `CallIndirect`/`CallImport` — so a function containing one is state-reaching under `Threaded`
      // (it threads `cur` into the lookup + tail apply). `ReturnCall` (direct) is NOT a seed — like
      // `CallDirect` its state-reachingness flows through the `direct_callees` closure below.
      ir.ReturnCallIndirect(..)
    | ir.ReturnCallImport(..) -> True
    Let(_, rhs, body) -> expr_touches_state(rhs) || expr_touches_state(body)
    If(_, _, t, e) -> expr_touches_state(t) || expr_touches_state(e)
    Switch(_, _, arms, default) ->
      list.any(arms, fn(a) {
        let SwitchArm(_, b) = a
        expr_touches_state(b)
      })
      || expr_touches_state(default)
    Block(_, _, body) -> expr_touches_state(body)
    Loop(_, _, _, body) -> expr_touches_state(body)
    Charge(_, body) -> expr_touches_state(body)
    // Phase-7 (T6): a `Try` around a state-touching body is state-reaching — RECURSE into the
    // body + each handler (like `Block`/`If`). `Throw`/`ThrowRef` carry NO state in the thrown
    // term (Cell-only), so they are NOT seeds (fall to `_ -> False`). A tag-free module has none
    // of these, so its classification is byte-identical to Phase 6.
    ir.Try(_, body, handlers) ->
      expr_touches_state(body)
      || list.any(handlers, fn(h) { expr_touches_state(h.handler) })
    _ -> False
  }
}

/// Accumulate every `CallDirect` target name reachable in `expr` (the call-graph edges out of
/// a function body). Only `CallDirect` edges — `CallIndirect` targets go through the table, so
/// they are not static edges.
fn direct_callees(expr: Expr, acc: Set(String)) -> Set(String) {
  case expr {
    CallDirect(name, _) -> set.insert(acc, name)
    // Phase-13 (Q13-05): a DIRECT `return_call` is a real call-graph edge exactly like `CallDirect`
    // — a function that tail-calls a state-reaching callee must itself be state-reaching (so it is
    // emitted under `Threading` and emits `apply 'g'/(n+1)(cur, args)`, the callee's threaded arity).
    ir.ReturnCall(name, _) -> set.insert(acc, name)
    Let(_, rhs, body) -> direct_callees(body, direct_callees(rhs, acc))
    If(_, _, t, e) -> direct_callees(e, direct_callees(t, acc))
    Switch(_, _, arms, default) -> {
      let acc =
        list.fold(arms, acc, fn(a, arm) {
          let SwitchArm(_, b) = arm
          direct_callees(b, a)
        })
      direct_callees(default, acc)
    }
    Block(_, _, body) -> direct_callees(body, acc)
    Loop(_, _, _, body) -> direct_callees(body, acc)
    Charge(_, body) -> direct_callees(body, acc)
    // Phase-7: a `CallDirect` inside a `Try` body or handler is a real call-graph edge — RECURSE
    // (like `Block`/`Loop`). `Throw`/`ThrowRef`'s operands are atomic `Value`s (no call), so they
    // fall to `_ -> acc`.
    ir.Try(_, body, handlers) -> {
      let acc = direct_callees(body, acc)
      list.fold(handlers, acc, fn(a, h) { direct_callees(h.handler, a) })
    }
    _ -> acc
  }
}

// ─────────────────────────────── the core emitter ───────────────────────────────

/// Emit `expr` in tail position under continuation `cont` and state channel `sc`, threading
/// `state`.
///
/// Returns the Core expression for `expr` (its yielded values disposed of by `cont`) and
/// the advanced state, or an `EmitError`. The non-returning transfers (`Return`/`Trap`/
/// `Break`/`Continue`) ignore `cont` and emit the transfer directly. Under `Threading(cur)`
/// (§A.2), reads pass `cur`, mutators rebind it, and `Return`/`KReturn` pair the package with
/// the live record; under `NoState` the Phase-2/3 cell code is emitted verbatim.
fn emit(
  expr: Expr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case expr {
    Values(vs) -> apply_cont(cont, list.map(vs, emit_value), sc, state, ctx)
    Return(vs) -> emit_return(vs, sc, state)
    Num(op, args) -> emit_num(op, args, cont, sc, state, ctx)
    Convert(op, arg) -> emit_convert(op, arg, cont, sc, state, ctx)
    CallDirect(fn_name, args) ->
      emit_call_direct(fn_name, args, cont, sc, state, ctx)
    CallHost(cap, name, args) ->
      emit_call_host(cap, name, args, cont, sc, state, ctx)
    Let(names, rhs, body) -> emit(rhs, KBind(names, body, cont), sc, state, ctx)
    If(cond, result, t, e) -> emit_if(cond, result, t, e, cont, sc, state, ctx)
    Switch(sel, result, arms, default) ->
      emit_switch(sel, result, arms, default, cont, sc, state, ctx)
    Block(label, result, body) ->
      emit_block(label, result, body, cont, sc, state, ctx)
    Loop(label, params, result, body) ->
      emit_loop(label, params, result, body, cont, sc, state, ctx)
    Break(label, vs) -> emit_break(label, vs, sc, state, ctx)
    Continue(label, vs) -> emit_continue(label, vs, sc, state)
    Trap(reason) ->
      Ok(#(raise_trap(ctx, CAtom(trap_reason_atom(reason))), state))
    Charge(cost, body) -> emit_charge(cost, body, cont, sc, state, ctx)
    // ── Stateful ops — routed through the ONE state-access seam (`seam_call`). Under
    // `NoState` each is today's cell `call '<binding.X_module>':'op'(...)`; under
    // `Threading(cur)` each threads the `InstanceState` record through the `t_*` family. ──
    // The `mem` index routes the memory-node seam (§E): index `0` emits the EXACT Phase-4 head
    // (no index arg — byte-identical, H7); index `>= 1` emits the `_at` head with a leading
    // memory-index argument.
    MemSize(mem) -> emit_mem_size(mem, cont, sc, state, ctx)
    MemGrow(mem, delta) -> emit_mem_grow(mem, delta, cont, sc, state, ctx)
    MemLoad(mem, op, addr, offset, result) ->
      emit_mem_load(mem, op, addr, offset, result, cont, sc, state, ctx)
    MemStore(mem, op, addr, value, offset) ->
      emit_mem_store(mem, op, addr, value, offset, cont, sc, state, ctx)
    // ── Phase-10 unchecked accesses (N4/N5): lower to the tier's UNCHECKED entry point on
    //    paged/atomics; fall back to the CHECKED path on nif / multi-memory (sound, just not
    //    accelerated — the versioned fast loop's guard proved the access in-bounds either way). ──
    ir.MemLoadUnchecked(mem, op, addr, offset, result) ->
      emit_mem_load_unchecked(
        mem,
        op,
        addr,
        offset,
        result,
        cont,
        sc,
        state,
        ctx,
      )
    ir.MemStoreUnchecked(mem, op, addr, value, offset) ->
      emit_mem_store_unchecked(
        mem,
        op,
        addr,
        value,
        offset,
        cont,
        sc,
        state,
        ctx,
      )
    GlobalGet(name) -> emit_global_get(name, cont, sc, state, ctx)
    GlobalSet(name, value) -> emit_global_set(name, value, cont, sc, state, ctx)
    CallIndirect(table, index, ty, args) ->
      emit_call_indirect(table, index, ty, args, cont, sc, state, ctx)
    // ── Phase-5 reference layer (H1/H2) — PURE, state-neutral (they touch no memory/table/
    // global, §B). `cur` flows through unchanged under `Threading`. ──
    ir.RefFunc(name) -> emit_ref_func(name, cont, sc, state, ctx)
    // Phase-14 `RefFuncImport` (R14-02, R1/R2): a bare `ref.func` of an IMPORTED function in a
    // function body (pushed then `table.set`/returned) is a PURE, state-neutral funcref
    // CONSTRUCTION — the `func_import_at(slot)` read is deferred INTO the adapter closure body
    // (dispatch time), so building the value touches no state and `cur` flows through unchanged
    // under `Threading`, exactly like `emit_ref_func`.
    ir.RefFuncImport(slot, ty) ->
      emit_ref_func_import(slot, ty, cont, sc, state, ctx)
    ir.RefIsNull(arg) -> emit_ref_is_null(arg, cont, sc, state, ctx)
    // ── Phase-5 table layer (H2) — state-reaching (§C). ──
    ir.TableGet(table, index) ->
      emit_table_get(table, index, cont, sc, state, ctx)
    ir.TableSet(table, index, value) ->
      emit_table_set(table, index, value, cont, sc, state, ctx)
    ir.TableSize(table) -> emit_table_size(table, cont, sc, state, ctx)
    ir.TableGrow(table, delta, init) ->
      emit_table_grow(table, delta, init, cont, sc, state, ctx)
    ir.TableFill(table, offset, value, count) ->
      emit_table_fill(table, offset, value, count, cont, sc, state, ctx)
    ir.TableInit(table, seg, dst, src, count) ->
      emit_table_init(table, seg, dst, src, count, cont, sc, state, ctx)
    ir.TableCopy(dst_table, src_table, dst, src, count) ->
      emit_table_copy(
        dst_table,
        src_table,
        dst,
        src,
        count,
        cont,
        sc,
        state,
        ctx,
      )
    ir.ElemDrop(seg) -> emit_elem_drop(seg, cont, sc, state, ctx)
    // ── Phase-5 bulk-memory layer (H2/H3) — state-reaching (§D). ──
    ir.MemFill(mem, dest, value, count) ->
      emit_mem_fill(mem, dest, value, count, cont, sc, state, ctx)
    ir.MemCopy(dst_mem, src_mem, dst, src, count) ->
      emit_mem_copy(dst_mem, src_mem, dst, src, count, cont, sc, state, ctx)
    ir.MemInit(mem, seg, dst, src, count) ->
      emit_mem_init(mem, seg, dst, src, count, cont, sc, state, ctx)
    ir.DataDrop(seg) -> emit_data_drop(seg, cont, sc, state, ctx)
    // ── Phase-6 SIMD (§B/§C) — PURE lane ops are state-neutral, non-trapping; the SIMD-memory
    // family composes the bounds-checked `rt_mem` byte-slice seam with pure `rt_simd` lane
    // assembly (S4). ──
    ir.Simd(op, args) -> emit_simd(op, args, cont, sc, state, ctx)
    Gc(op, args) -> emit_gc(op, args, cont, sc, state, ctx)
    ir.SimdShuffle(lanes, a, b) ->
      emit_simd_shuffle(lanes, a, b, cont, sc, state, ctx)
    ir.SimdLoad(mem, kind, addr, offset) ->
      emit_simd_load(mem, kind, addr, offset, cont, sc, state, ctx)
    ir.SimdStore(mem, addr, value, offset) ->
      emit_simd_store(mem, addr, value, offset, cont, sc, state, ctx)
    ir.SimdLoadLane(mem, width, addr, offset, lane, vec) ->
      emit_simd_load_lane(
        mem,
        width,
        addr,
        offset,
        lane,
        vec,
        cont,
        sc,
        state,
        ctx,
      )
    ir.SimdStoreLane(mem, width, addr, offset, lane, vec) ->
      emit_simd_store_lane(
        mem,
        width,
        addr,
        offset,
        lane,
        vec,
        cont,
        sc,
        state,
        ctx,
      )
    // ── Phase-6 cross-module dispatch (§E/S5) — read the handed-in closure from the instance's
    // positional func-import slot, then `link.call_import(closure, args_list)` (a capability, never
    // an ambient `apply` of a data-named `module:atom` — D3a). ──
    ir.CallImport(slot, ty, args) ->
      emit_call_import(slot, ty, args, cont, sc, state, ctx)
    // ── Phase-13 tail calls (Q1/Q5) — CONSERVATIVE-SOUND PLACEHOLDER (Q13-05 completes as genuine
    // constant-stack tail calls). Each routes through the EXISTING ordinary-call emitter under a
    // `KBind(fresh_names, Return(vars), KReturn)` continuation, so the call sits in a `let`-binding
    // (a real frame, NOT tail position) and its results are then function-returned. Result-identical
    // to the real tail call (same values, same traps, same order) — it differs ONLY in stack growth,
    // which is not WASM-observable — so the whole matrix stays green + byte-identical while the
    // keystone deliberately does NOT claim the constant-stack property. Q13-05 replaces these with
    // the forced-`KReturn` tail emit + the `rt_table.call_indirect_lookup` seam + the funcref-ABI
    // change (overview §2 ⚠ ABI reconciliation note). ──
    ir.ReturnCall(fn_name, args) ->
      emit_return_call(fn_name, args, sc, state, ctx)
    ir.ReturnCallIndirect(table, index, ty, args) ->
      emit_return_call_indirect(table, index, ty, args, sc, state, ctx)
    ir.ReturnCallRef(funcref, args) ->
      emit_return_call_ref(funcref, args, sc, state, ctx)
    ir.ReturnCallImport(slot, ty, args) ->
      emit_return_call_import(slot, ty, args, sc, state, ctx)
    // ── Phase-7 EH nodes (§J/T1/T5/T7): BEAM-native exceptions through the `rt_exn` chokepoint.
    // `Throw`/`ThrowRef` are BOTTOM transfers (like `Trap`/`Return`) — they drop `cont`; `Try`
    // installs a Core Erlang `try…catch` (the `CTry` node) around its body. EH ships CELL-ONLY
    // (T6): no state travels in the thrown term. A tag-free module reaches NONE of these. ──
    ir.Throw(tag, args) -> emit_throw(tag, args, state, ctx)
    ir.Try(result, body, handlers) ->
      emit_try(result, body, handlers, cont, sc, state, ctx)
    ir.ThrowRef(exnref) -> emit_throw_ref(exnref, state)
    // ── Phase-8 term layer (K2/K8, unit 01): PURE BEAM-term construction/destructuring. Each
    // op yields ONE value disposed through `cont` (like a non-trapping `Num`); tuples/lists are
    // immutable, so none traps or touches mutable state. The term↔numeric boxing `Convert`s
    // remain a later-unit deferral (unit 04). ──
    TermOp(op, args) -> emit_term_op(op, args, cont, sc, state, ctx)
    // ── Phase-8 native closures (K3/K8, unit 02) — THE HEADLINE. `MakeClosure` builds a BEAM
    // `fun` closing over already-evaluated captures (PURE, one value); `CallClosure` applies a fun
    // VALUE via a native `apply F(Args)` (EFFECTFUL barrier, one value). Neither arises from WASM
    // (K7). A closure over an enclosing local — Porffor's wall — is here just a `fun`. ──
    MakeClosure(fn_name, captures, arity) ->
      emit_make_closure(fn_name, captures, arity, cont, sc, state, ctx)
    CallClosure(callee, args) ->
      emit_call_closure(callee, args, cont, sc, state, ctx)
    // ── Phase-8 map layer (K4/K8, unit 03): the immutable BEAM map — the object substrate. Each
    // op is PURE and yields ONE value disposed through `cont` (like a `TermOp`); a BEAM map is
    // immutable, so no op traps or touches mutable state, and `sc` flows through unchanged. Neither
    // arises from WASM (K7). ──
    MapOp(op, args) -> emit_map_op(op, args, cont, sc, state, ctx)
    // ── Phase-8 term classification + native number arithmetic (K2/K8, unit 06). `TermTest`/
    // `TermTag` are PURE `TTerm → i32` guards/classifiers (a `case` over `erlang:is_*` BIFs);
    // `NumTerm` is native BEAM arithmetic/compare on number terms (a bare `erlang:'+'/'-'/'*'`
    // BIF call, or a compare `case` → i32). Each yields ONE value disposed through `cont` (like a
    // `Num`); `sc` flows through unchanged. Neither arises from WASM (K7). This is the guarded hot
    // arithmetic fast path: `TermTest(IsNumber)` guards, `NumTerm` computes native. ──
    ir.TermTest(kind, arg) -> emit_term_test(kind, arg, cont, sc, state, ctx)
    ir.TermTag(arg) -> emit_term_tag(arg, cont, sc, state, ctx)
    ir.NumTerm(op, lhs, rhs) ->
      emit_num_term(op, lhs, rhs, cont, sc, state, ctx)
  }
}

/// Lower a `TermOp(op, args)` — the Phase-8 term construction/destructuring layer (unit 01, K2).
///
/// Every variant is PURE and yields exactly ONE value, disposed through `cont` via `apply_cont`
/// (the same continuation-passing shape as a non-trapping `Num`; `sc` flows through unchanged
/// since no term op touches threaded instance state). Lowerings (unit-01 table):
/// - `MakeTuple` (N args) → `{V₁,…,Vₙ}` (`CTuple`).
/// - `TupleGet(i)` (1 arg) → `call 'erlang':'element'(i+1, T)` (IR index 0-based; `element/2`
///   1-based).
/// - `TupleSize` (1 arg) → `call 'erlang':'tuple_size'(T)`.
/// - `MakeCons` (2 args) → `[H|T]` (`CCons`).
/// - `ListHead` (1 arg) → `call 'erlang':'hd'(L)`.
/// - `ListTail` (1 arg) → `call 'erlang':'tl'(L)`.
/// - `IsEmptyList` (1 arg) → `case L of [] -> 1; _ -> 0 end` (an i32 truth value).
///
/// A wrong operand arity is an impossible state for a validated module (validate/frontend uphold
/// the arities, K7); it fails closed with `Error(UnsupportedNode("term_op"))`, never a panic.
fn emit_term_op(
  op: ir.TermOp,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case op, args {
    ir.MakeTuple, _ ->
      apply_cont(cont, [CTuple(list.map(args, emit_value))], sc, state, ctx)
    ir.TupleGet(i), [t] ->
      apply_cont(
        cont,
        [CCall(CAtom("erlang"), CAtom("element"), [CInt(i + 1), emit_value(t)])],
        sc,
        state,
        ctx,
      )
    ir.TupleSize, [t] ->
      apply_cont(
        cont,
        [CCall(CAtom("erlang"), CAtom("tuple_size"), [emit_value(t)])],
        sc,
        state,
        ctx,
      )
    ir.MakeCons, [h, t] ->
      apply_cont(cont, [CCons(emit_value(h), emit_value(t))], sc, state, ctx)
    ir.ListHead, [l] ->
      apply_cont(
        cont,
        [CCall(CAtom("erlang"), CAtom("hd"), [emit_value(l)])],
        sc,
        state,
        ctx,
      )
    ir.ListTail, [l] ->
      apply_cont(
        cont,
        [CCall(CAtom("erlang"), CAtom("tl"), [emit_value(l)])],
        sc,
        state,
        ctx,
      )
    ir.IsEmptyList, [l] -> {
      // `case L of [] -> 1; _ -> 0 end` — one i32 value (fresh wildcard binder for the `_` arm).
      let #(wild, state2) = fresh_var(state)
      let is_empty =
        CCase(emit_value(l), [
          CClause([PNil], CAtom("true"), CInt(1)),
          CClause([PVar(wild)], CAtom("true"), CInt(0)),
        ])
      apply_cont(cont, [is_empty], sc, state2, ctx)
    }
    // Arity mismatch — impossible for a validated module (K7); fail closed.
    _, _ -> Error(UnsupportedNode("term_op"))
  }
}

/// Lower a `MapOp(op, args)` — the Phase-8 immutable-map layer (unit 03, K4/K8), the object
/// substrate a JS frontend builds on. A BEAM map is immutable (a functional update returns a NEW
/// map), so every op is PURE, yields exactly ONE value, and is disposed through `cont` via
/// `apply_cont` (the same shape as `emit_term_op`); `sc` flows through unchanged (no map op touches
/// threaded instance state).
///
/// ARG ORDER (the crux): the IR args are uniformly map-first (`m, k[, v/default]`), but the Erlang
/// `maps` BIFs take the KEY (and value) BEFORE the map — so this re-orders per BIF. Lowerings
/// (unit-03 table):
/// - `MapNew` (0 args) → `call 'maps':'new'()` — the empty map `#{}` (a behavioural equal of the
///   Core empty-map literal `~{}~`; `maps:new/0` avoids introducing a new Core AST node).
/// - `MapGet` (`m, k, default`) → `call 'maps':'get'(K, M, Default)` — a missing key yields
///   `Default` (the frontend's sentinel), never a BEAM `badkey`.
/// - `MapPut` (`m, k, v`) → `call 'maps':'put'(K, V, M)` — returns a NEW map.
/// - `MapHas` (`m, k`) → `case call 'maps':'is_key'(K, M) of 'true' -> 1; 'false' -> 0 end` — an
///   i32 truth value (so it drops into `If`/`Switch`, like `IsEmptyList`).
/// - `MapRemove` (`m, k`) → `call 'maps':'remove'(K, M)` — returns a NEW map.
/// - `MapSize` (`m`) → `call 'maps':'size'(M)` — an i32 count.
///
/// A wrong operand arity is an impossible state for a validated module (validate/frontend uphold
/// the arities, K7); it fails closed with `Error(UnsupportedNode("map_op"))`, never a panic.
fn emit_map_op(
  op: ir.MapOp,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case op, args {
    ir.MapNew, [] ->
      apply_cont(cont, [CCall(CAtom("maps"), CAtom("new"), [])], sc, state, ctx)
    ir.MapGet, [m, k, default] ->
      apply_cont(
        cont,
        [
          CCall(CAtom("maps"), CAtom("get"), [
            emit_value(k),
            emit_value(m),
            emit_value(default),
          ]),
        ],
        sc,
        state,
        ctx,
      )
    ir.MapPut, [m, k, v] ->
      apply_cont(
        cont,
        [
          CCall(CAtom("maps"), CAtom("put"), [
            emit_value(k),
            emit_value(v),
            emit_value(m),
          ]),
        ],
        sc,
        state,
        ctx,
      )
    ir.MapHas, [m, k] -> {
      // `case maps:is_key(K, M) of 'true' -> 1; 'false' -> 0 end` — one i32 truth value.
      // `is_key/2` always returns a boolean atom, so the two clauses are exhaustive.
      let has =
        CCase(
          CCall(CAtom("maps"), CAtom("is_key"), [emit_value(k), emit_value(m)]),
          [
            CClause([PAtom("true")], CAtom("true"), CInt(1)),
            CClause([PAtom("false")], CAtom("true"), CInt(0)),
          ],
        )
      apply_cont(cont, [has], sc, state, ctx)
    }
    ir.MapRemove, [m, k] ->
      apply_cont(
        cont,
        [CCall(CAtom("maps"), CAtom("remove"), [emit_value(k), emit_value(m)])],
        sc,
        state,
        ctx,
      )
    ir.MapSize, [m] ->
      apply_cont(
        cont,
        [CCall(CAtom("maps"), CAtom("size"), [emit_value(m)])],
        sc,
        state,
        ctx,
      )
    // Arity mismatch — impossible for a validated module (K7); fail closed.
    _, _ -> Error(UnsupportedNode("map_op"))
  }
}

/// Lower a `TermTest(kind, arg)` — a single Phase-8 BEAM term-shape guard (unit 06, K2/K8). Emits
/// `case call 'erlang':'is_<kind>'(X) of 'true' -> 1; 'false' -> 0 end` — an **i32 truth value** (so
/// it drops into `If`/`Switch`, exactly like `IsEmptyList`/`MapHas`). PURE and single-valued —
/// disposed through `cont` via `apply_cont`; `sc` flows through unchanged (an `is_*` BIF touches no
/// threaded instance state). `X` is the atomic operand (a `CVar`/literal), so it is referenced once
/// and needs no fresh binder. `kind` selects the BIF via `term_test_bif` (a total map).
fn emit_term_test(
  kind: ir.TermKind,
  arg: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let guard = bool_bif_to_i32(term_test_bif(kind), [emit_value(arg)])
  apply_cont(cont, [guard], sc, state, ctx)
}

/// The `erlang:is_*` BIF name for a `TermKind` (Phase-8 unit 06): `IsInt`→`is_integer`,
/// `IsFloat`→`is_float`, `IsNumber`→`is_number`, `IsAtom`→`is_atom`, `IsBinary`→`is_binary`,
/// `IsTuple`→`is_tuple`, `IsMap`→`is_map`, `IsFun`→`is_function`, `IsList`→`is_list`. Total.
fn term_test_bif(kind: ir.TermKind) -> String {
  case kind {
    ir.IsInt -> "is_integer"
    ir.IsFloat -> "is_float"
    ir.IsNumber -> "is_number"
    ir.IsAtom -> "is_atom"
    ir.IsBinary -> "is_binary"
    ir.IsTuple -> "is_tuple"
    ir.IsMap -> "is_map"
    ir.IsFun -> "is_function"
    ir.IsList -> "is_list"
  }
}

/// Wrap a boolean-returning `erlang` BIF call (`fn_name(args)` → `'true'`/`'false'`) into an i32
/// truth value: `case call 'erlang':'<fn_name>'(args) of 'true' -> 1; 'false' -> 0 end`. The BIF
/// always returns a boolean atom, so the two clauses are exhaustive (no fresh wildcard needed).
/// Shared by `TermTest` (an `is_*` test) and `NumTerm`'s comparisons (a relational BIF).
fn bool_bif_to_i32(fn_name: String, args: List(CExpr)) -> CExpr {
  CCase(CCall(CAtom("erlang"), CAtom(fn_name), args), [
    CClause([PAtom("true")], CAtom("true"), CInt(1)),
    CClause([PAtom("false")], CAtom("true"), CInt(0)),
  ])
}

/// Lower a `TermTag(arg)` — the Phase-8 DENSE term classification (unit 06, K2/K8). Emits a nested
/// `case` chain over the `erlang:is_*` BIFs returning the FIXED i32 code
/// `0=int 1=float 2=atom 3=binary 4=tuple 5=map 6=fun 7=list 8=other` (the frontend's `Switch` ABI).
/// PURE and single-valued — disposed through `cont` via `apply_cont`; `sc` flows through unchanged.
/// The atomic operand `X` is referenced in each nested test (an atomic `CVar`/literal, so re-use is
/// free — no binder). The chain is built inside-out (`term_tag_case`) so the tests are tried in the
/// documented order and the innermost fall-through is `8` (other).
fn emit_term_tag(
  arg: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  apply_cont(cont, [term_tag_case(emit_value(arg))], sc, state, ctx)
}

/// Build the `TermTag` nested `case` over the atomic term `x`: for each `#(is_BIF, code)` (in the
/// documented order int/float/atom/binary/tuple/map/fun/list), `case is_BIF(x) of 'true' -> code;
/// 'false' -> <rest> end`, with the final fall-through `8` (other). Folded right-to-left so the
/// first pair is the outermost `case` (tested first).
fn term_tag_case(x: CExpr) -> CExpr {
  let tests = [
    #("is_integer", 0),
    #("is_float", 1),
    #("is_atom", 2),
    #("is_binary", 3),
    #("is_tuple", 4),
    #("is_map", 5),
    #("is_function", 6),
    #("is_list", 7),
  ]
  list.fold_right(tests, CInt(8), fn(rest, pair) {
    let #(bif, code) = pair
    CCase(CCall(CAtom("erlang"), CAtom(bif), [x]), [
      CClause([PAtom("true")], CAtom("true"), CInt(code)),
      CClause([PAtom("false")], CAtom("true"), rest),
    ])
  })
}

/// Lower a `NumTerm(op, lhs, rhs)` — native BEAM arithmetic/compare on two number terms (unit 06,
/// K2/K8), the JS-arithmetic FAST path. Yields ONE value disposed through `cont` via `apply_cont`;
/// `sc` flows through unchanged (a bare `erlang` BIF touches no threaded instance state):
/// - `NAdd`/`NSub`/`NMul` → `call 'erlang':'+'/'-'/'*'(A, B)` → a **number term** (`TTerm`).
/// - `NLt`/`NLe`/`NGt`/`NGe`/`NEq` → `case A </=</>/>=/=:= B of 'true' -> 1; 'false' -> 0 end` → an
///   i32 truth value (via `bool_bif_to_i32` — the relational BIFs return boolean atoms).
///
/// A non-number operand raises a NATIVE BEAM `badarith` at run time (the frontend guards with
/// `TermTest(IsNumber)`; the IR's effect classifier marks `NumTerm` a barrier so the optimizer never
/// moves the raise). No division/remainder (they trap on `/0`, unlike JS `1/0 = Infinity`).
fn emit_num_term(
  op: ir.NumTermOp,
  lhs: Value,
  rhs: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let a = emit_value(lhs)
  let b = emit_value(rhs)
  let result = case op {
    // arithmetic → a number term (a bare BIF call)
    ir.NAdd -> CCall(CAtom("erlang"), CAtom("+"), [a, b])
    ir.NSub -> CCall(CAtom("erlang"), CAtom("-"), [a, b])
    ir.NMul -> CCall(CAtom("erlang"), CAtom("*"), [a, b])
    // comparison → an i32 truth value (`=<` is Erlang's ≤; `=:=` is exact-equal)
    ir.NLt -> bool_bif_to_i32("<", [a, b])
    ir.NLe -> bool_bif_to_i32("=<", [a, b])
    ir.NGt -> bool_bif_to_i32(">", [a, b])
    ir.NGe -> bool_bif_to_i32(">=", [a, b])
    ir.NEq -> bool_bif_to_i32("=:=", [a, b])
  }
  apply_cont(cont, [result], sc, state, ctx)
}

/// Lower `MakeClosure(fn_name, captures, arity)` — the Phase-8 native-closure constructor (K3/K8,
/// unit 02, THE HEADLINE). Builds a Core Erlang
/// `fun (A_1, …, A_arity) -> apply 'fn_name'/(m+arity)(C_1, …, C_m, A_1, …, A_arity)`
/// (m = `list.length(captures)`): the captured values are PREPENDED to `arity` fresh runtime
/// params, so the emitted `fun` closes over them by BEAM value capture (nothing else to do). PURE
/// and single-valued — disposed through `cont` via `apply_cont` (like a `TermOp`); `sc` flows
/// through unchanged (building a fun touches no threaded instance state).
///
/// Resolution mirrors `CallDirect` (D3a — the EXACT same-module `apply 'f'/n(…)` shape, never a
/// new call form): `fn_name` must be a defined same-module function (`ctx.fn_arity`), else
/// `Error(UnknownFunction)`. Its parameter count must equal `m + arity` (it takes the captures,
/// then the runtime args), else `Error(ArityMismatch(expected, got))` — a TYPED error, never a
/// panic. `arity = 0` yields a nullary `fun () -> apply 'fn_name'/m(captures…)`; `captures = []`
/// yields a plain `fun` forwarding all args.
///
/// NOTE: the closure body is the UN-threaded direct call. A state-threaded build whose closure
/// target is state-reaching is out of scope — Phase-8 closures arise only in the direct-IR JS
/// path, which threads no instance state (K7); no WASM module produces this node.
fn emit_make_closure(
  fn_name: String,
  captures: List(Value),
  arity: Int,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case dict.get(ctx.fn_arity, fn_name) {
    Error(_) -> Error(UnknownFunction(fn_name))
    Ok(fn_params) -> {
      let expected = list.length(captures) + arity
      case fn_params == expected {
        False -> Error(ArityMismatch(expected, fn_params))
        True -> {
          let #(param_names, state2) = fresh_n_vars(state, arity)
          let body =
            CApply(
              FName(fn_name, fn_params),
              list.append(
                list.map(captures, emit_value),
                list.map(param_names, CVar),
              ),
            )
          apply_cont(cont, [CFun(param_names, body)], sc, state2, ctx)
        }
      }
    }
  }
}

/// Lower `CallClosure(callee, args)` — apply a native fun VALUE (K3/K8, unit 02). Emits a Core
/// Erlang `apply <callee>(A_1, …, A_n)` (`CApplyExpr` — a first-class value application, never a
/// data-named `apply(Mod, Fn, Args)`, never the list-spreading `erlang:apply/2`). EFFECTFUL
/// barrier (it transfers to arbitrary code, like `CallIndirect`), yielding ONE value.
///
/// State-NEUTRAL under `Threading(cur)`: a native BEAM fun does not carry our `InstanceState`, so
/// `cur` flows through unchanged (like `CallHost`/`CallImport`). The single result is disposed
/// through `cont` by `apply_cont_call` with `r = 1` — which under `Threading` re-pairs the value
/// with `cur` at a tail `KReturn`, and under `NoState`/`KReturn` yields the `apply` straight
/// through (a single value packaged is itself, §apply_cont_call). A callee arity mismatch is a
/// BEAM `badarity` error at RUN time (the IR carries no static fun arity — K1).
fn emit_call_closure(
  callee: Value,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let applied = CApplyExpr(emit_value(callee), list.map(args, emit_value))
  apply_cont_call(cont, applied, 1, sc, state, ctx)
}

/// Lower `Return(vs)` (the non-continuation transfer). Under `NoState` it yields the bare
/// `function_return` package; under `Threading(cur)` it pairs that package with the CURRENT
/// live record into the `{Package, St'}` 2-tuple (§B.2).
fn emit_return(
  vs: List(Value),
  sc: StateChan,
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  let pkg = function_return(list.map(vs, emit_value))
  case sc {
    NoState -> Ok(#(pkg, state))
    Threading(cur) -> Ok(#(CTuple([pkg, CVar(cur)]), state))
  }
}

// ─────────────────────────── the per-op state seam (cell / threaded) ───────────────────────────

/// `memory.size` on memory `mem` (read-only). Index `0` emits the byte-identical Phase-4 head
/// (`size`/`t_size`, no index arg — H7); index `>= 1` the `_at` head (`size_at`/`t_size_at`).
/// `NoState`: `call '<mem>':'size'()`. `Threading(cur)`: `call '<mem>':'t_size'(St)` — the
/// record is threaded on UNCHANGED.
fn emit_mem_size(
  mem: Int,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let call = case mem, sc {
    0, NoState -> seam_call(ctx.binding.mem_module, "size", [])
    0, Threading(cur) ->
      seam_call(ctx.binding.mem_module, "t_size", [CVar(cur)])
    _, NoState -> seam_call(ctx.binding.mem_module, "size_at", [CInt(mem)])
    _, Threading(cur) ->
      seam_call(ctx.binding.mem_module, "t_size_at", [CVar(cur), CInt(mem)])
  }
  apply_cont(cont, [call], sc, state, ctx)
}

/// `memory.grow` on memory `mem` (effectful). Index `0` emits the byte-identical Phase-4 head
/// (`grow`/`t_grow`); index `>= 1` the `_at` head (`grow_at`/`t_grow_at`, leading memidx).
/// `NoState`: a bare `call '<mem>':'grow'(Delta)` (i32). `Threading(cur)`: `{V, St2} =
/// call '<mem>':'t_grow'(St, Delta)` — bind the old page count `V`, REBIND the record to `St2`
/// (`t_grow` charges the success-path fuel internally, unit 04, so emit charges nothing here).
fn emit_mem_grow(
  mem: Int,
  delta: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case sc {
    NoState -> {
      let call = case mem {
        0 -> seam_call(ctx.binding.mem_module, "grow", [emit_value(delta)])
        _ ->
          seam_call(ctx.binding.mem_module, "grow_at", [
            CInt(mem),
            emit_value(delta),
          ])
      }
      apply_cont(cont, [call], sc, state, ctx)
    }
    Threading(cur) -> {
      let call = case mem {
        0 ->
          seam_call(ctx.binding.mem_module, "t_grow", [
            CVar(cur),
            emit_value(delta),
          ])
        _ ->
          seam_call(ctx.binding.mem_module, "t_grow_at", [
            CVar(cur),
            CInt(mem),
            emit_value(delta),
          ])
      }
      emit_value_state_pair(call, cont, state, ctx)
    }
  }
}

/// `t.load` (trapping, read-only).
///
/// `NoState` (Cell / lever 2): call the BARE-RAISING seam `'<mem>':'load_raising'(Bytes,Signed,W,
/// Addr,Off)` (or `'load_at_raising'` for `mem != 0`), which returns the loaded value DIRECTLY and
/// raises `MemoryOutOfBounds` INTERNALLY on OOB — so the value binds straight through `apply_cont`
/// (like `emit_mem_load_unchecked`), with NO per-op `{ok,X}|{error,E}` tuple + emit-side
/// `case … raise` unwrap. The trap reason is identical to the old `load`; this is a runtime win and
/// roughly halves the emitted Core for a load.
///
/// `Threading(cur)`: UNCHANGED — `case '<mem>':'t_load'(St,…)` reduced to one value via
/// `emit_trapping_result` (the threaded seams still return `Result`, and the record is read-only so
/// `cur` is threaded on unchanged, preserving `sc`).
fn emit_mem_load(
  mem: Int,
  op: ir.MemAccess,
  addr: Value,
  offset: Int,
  result: ValType,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let tail = [
    CInt(op.bytes),
    bool_atom(op.signed),
    CInt(result_width(result)),
    emit_value(addr),
    CInt(offset),
  ]
  case sc {
    NoState -> {
      // Lever 3: on a memory-0 access under `trust_memory` and a BEAM-memory-SAFE tier, route the
      // BARE `load_unchecked` seam (same shape `emit_mem_load_unchecked` uses) instead of the
      // checked `load_raising`. `Nif`, `trust_memory` off, or `mem != 0` keep the current path.
      let call = case
        mem == 0
        && ctx.binding.trust_memory
        && trust_memory_unchecked_tier(ctx.binding.mem_tier),
        mem
      {
        True, _ -> seam_call(ctx.binding.mem_module, "load_unchecked", tail)
        False, 0 -> seam_call(ctx.binding.mem_module, "load_raising", tail)
        False, _ ->
          seam_call(ctx.binding.mem_module, "load_at_raising", [
            CInt(mem),
            ..tail
          ])
      }
      apply_cont(cont, [call], sc, state, ctx)
    }
    Threading(cur) -> {
      let call = case mem {
        0 -> seam_call(ctx.binding.mem_module, "t_load", [CVar(cur), ..tail])
        _ ->
          seam_call(ctx.binding.mem_module, "t_load_at", [
            CVar(cur),
            CInt(mem),
            ..tail
          ])
      }
      emit_trapping_result(call, cont, sc, state, ctx)
    }
  }
}

/// `t.store` (trapping, ZERO-RESULT ordered effect). `op.signed` is irrelevant for stores
/// (`storeN` writes the low N bytes); eval order is addr → value → store (left-to-right `call`
/// args).
///
/// `NoState` (Cell / lever 2): the BARE-RAISING seam `'<mem>':'store_raising'(Bytes,Addr,Value,Off)`
/// (or `'store_at_raising'` for `mem != 0`) returns `Nil` and raises `MemoryOutOfBounds` INTERNALLY
/// on OOB — so the call ITSELF is the ordered effect, sequenced+discarded by `emit_zero_effect` with
/// NO per-op `{ok,_}|{error,E}` tuple + emit-side `case … raise` reduction. Trap-before-write and
/// the trap reason are identical to the old `store`; this halves the emitted Core for a store.
///
/// `Threading(cur)`: UNCHANGED — `St2 = case '<mem>':'t_store'(St,…) of {ok,S}->S; {error,R}->raise`
/// REBINDS the record to `St2` (`t_store` returns the updated record); continue under
/// `Threading(St2)` disposing zero values. This makes store-before-load a visible dataflow edge
/// through `St` (stronger than the cell `let`-discard barrier, §G).
fn emit_mem_store(
  mem: Int,
  op: ir.MemAccess,
  addr: Value,
  value: Value,
  offset: Int,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let tail = [
    CInt(op.bytes),
    emit_value(addr),
    emit_value(value),
    CInt(offset),
  ]
  case sc {
    NoState -> {
      // Lever 3: mirror `emit_mem_load` — a memory-0 store under `trust_memory` on a
      // BEAM-memory-SAFE tier routes the BARE `store_unchecked` seam (disposed via
      // `emit_zero_effect`, same shape `emit_mem_store_unchecked` uses); otherwise unchanged.
      let effect = case
        mem == 0
        && ctx.binding.trust_memory
        && trust_memory_unchecked_tier(ctx.binding.mem_tier),
        mem
      {
        True, _ -> seam_call(ctx.binding.mem_module, "store_unchecked", tail)
        False, 0 -> seam_call(ctx.binding.mem_module, "store_raising", tail)
        False, _ ->
          seam_call(ctx.binding.mem_module, "store_at_raising", [
            CInt(mem),
            ..tail
          ])
      }
      emit_zero_effect(effect, cont, sc, state, ctx)
    }
    Threading(cur) -> {
      let call = case mem {
        0 -> seam_call(ctx.binding.mem_module, "t_store", [CVar(cur), ..tail])
        _ ->
          seam_call(ctx.binding.mem_module, "t_store_at", [
            CVar(cur),
            CInt(mem),
            ..tail
          ])
      }
      emit_threaded_record_effect(call, cont, state, ctx)
    }
  }
}

/// `MemLoadUnchecked` (Phase-10, N4/N5) — a bounds-check-free load the BCE pass proved in-bounds.
/// On a tier that supports it (paged/atomics/nif, single memory), lower to the `load_unchecked`/
/// `t_load_unchecked` seam, which returns a BARE `Int` (no `Result`) — so it binds DIRECTLY via
/// `apply_cont` (like `global.get`), NOT through the trapping-result reducer. On multi-memory
/// (`mem != 0`) or an unknown module it falls back to the CHECKED `emit_mem_load` (sound; the guard
/// proved in-bounds either way).
fn emit_mem_load_unchecked(
  mem: Int,
  op: ir.MemAccess,
  addr: Value,
  offset: Int,
  result: ValType,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case mem == 0 && mem_supports_unchecked(ctx.binding.mem_module) {
    False -> emit_mem_load(mem, op, addr, offset, result, cont, sc, state, ctx)
    True -> {
      let tail = [
        CInt(op.bytes),
        bool_atom(op.signed),
        CInt(result_width(result)),
        emit_value(addr),
        CInt(offset),
      ]
      let call = case sc {
        NoState -> seam_call(ctx.binding.mem_module, "load_unchecked", tail)
        Threading(cur) ->
          seam_call(ctx.binding.mem_module, "t_load_unchecked", [
            CVar(cur),
            ..tail
          ])
      }
      apply_cont(cont, [call], sc, state, ctx)
    }
  }
}

/// `MemStoreUnchecked` (Phase-10, N4/N5) — a bounds-check-free store the BCE pass proved in-bounds.
/// On paged/atomics/nif (single memory) it lowers to `store_unchecked`/`t_store_unchecked`, which
/// return `Nil` (cell) / the record (threaded) DIRECTLY (no `Result`) — the NON-trapping mutator
/// shape of `global.set`. On multi-memory (`mem != 0`) or an unknown module it falls back to the
/// CHECKED `emit_mem_store`.
fn emit_mem_store_unchecked(
  mem: Int,
  op: ir.MemAccess,
  addr: Value,
  value: Value,
  offset: Int,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case mem == 0 && mem_supports_unchecked(ctx.binding.mem_module) {
    False -> emit_mem_store(mem, op, addr, value, offset, cont, sc, state, ctx)
    True -> {
      let tail = [
        CInt(op.bytes),
        emit_value(addr),
        emit_value(value),
        CInt(offset),
      ]
      case sc {
        NoState -> {
          let effect =
            seam_call(ctx.binding.mem_module, "store_unchecked", tail)
          emit_zero_effect(effect, cont, sc, state, ctx)
        }
        Threading(cur) -> {
          let call =
            seam_call(ctx.binding.mem_module, "t_store_unchecked", [
              CVar(cur),
              ..tail
            ])
          let #(newst, state2) = fresh_var(state)
          use #(rest, state3) <- result.try(apply_cont(
            cont,
            [],
            Threading(newst),
            state2,
            ctx,
          ))
          Ok(#(CLet([newst], call, rest), state3))
        }
      }
    }
  }
}

/// Does the linked memory backend `mem_module` provide the Phase-10 UNCHECKED entry points? A
/// FAIL-CLOSED name whitelist (N5 / S4): exactly the paged + atomics + nif runtime modules. An
/// unknown/future module is NOT whitelisted → the caller falls back to the checked path, which is
/// always sound. Compared by module name (G5 — the emitter never branches on the tier ENUM).
///
/// Nif (tier-N) joins the whitelist because it now ships real `*_unchecked` heads (S15-02): it is a
/// BEAM-memory-UNSAFE tier where eliding the bounds compare is the whole point, and the arm is only
/// reached inside a BCE-versioned loop's fast branch whose guard already proved the range in-bounds.
fn mem_supports_unchecked(mem_module: String) -> Bool {
  mem_module == profiles.mem_module_for(Paged)
  || mem_module == profiles.mem_module_for(Atomics)
  || mem_module == profiles.mem_module_for(Nif)
}

/// May `trust_memory` (lever 3) route a memory-0 access through the bounds-check-free
/// `*_unchecked` seam on `mem_tier`? True ONLY for the BEAM-memory-SAFE tiers where an
/// out-of-bounds access is CONTAINED to a wrong value: `Paged` (an absent sparse chunk reads
/// zero) and `Atomics` (`atomics:get` is ERTS-bounds-checked). NEVER `Nif` (tier-N): eliding the
/// bounds compare there would let a raw C deref past the buffer crash the node, so tier-N stays on
/// the checked/raising path even under `trust_memory` (§SAFETY).
///
/// This is the ONE emit-site that consults the tier ENUM for `trust_memory` — a node-safety gate
/// (which tiers are safe to skip the check on), NOT a module-swap decision (G5), so branching the
/// enum here is warranted. Distinct from `mem_supports_unchecked`, which whitelists BCE-proven
/// unchecked nodes on ALL three tiers (Nif INCLUDED, since there the elision is guarded by a proof).
fn trust_memory_unchecked_tier(mem_tier: MemTier) -> Bool {
  case mem_tier {
    Paged | Atomics -> True
    Nif -> False
  }
}

/// `global.get` (read-only). Routes by global TYPE (via `ctx.ref_global_names`, which holds the
/// BOXED — reference + `v128` — global names, S6): a NUMERIC global reads the raw-bit `global_get`
/// (byte-identical, D5); a BOXED global (funcref/externref, R8, or a `v128`, S6) reads the parallel
/// `ref_global_get` (the opaque-`Dynamic` map). `NoState` reads the pdict cell; `Threading(cur)`
/// reads the live record via the `t_*` twin (`cur` threaded on unchanged).
fn emit_global_get(
  name: String,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let boxed = set.contains(ctx.ref_global_names, name)
  let #(cell_fn, threaded_fn) = case boxed {
    True -> #("ref_global_get", "t_ref_global_get")
    False -> #("global_get", "t_global_get")
  }
  case sc {
    NoState ->
      apply_cont(
        cont,
        [
          seam_call(ctx.binding.state_module, cell_fn, [
            core_binary_string(name),
          ]),
        ],
        sc,
        state,
        ctx,
      )
    Threading(cur) ->
      apply_cont(
        cont,
        [
          seam_call(ctx.binding.state_module, threaded_fn, [
            CVar(cur),
            core_binary_string(name),
          ]),
        ],
        sc,
        state,
        ctx,
      )
  }
}

/// `global.set` (ZERO-RESULT ordered effect). Routes by global TYPE like `emit_global_get`: a
/// NUMERIC global writes the raw-bit `global_set` (byte-identical); a BOXED (reference/`v128`, S6)
/// global writes the parallel `ref_global_set`. `NoState`: the pure cell effect sequenced with a
/// `let`-discard. `Threading(cur)`: rebind `cur := <t_*>_set(St, Name, Val)` (NON-trapping, returns
/// the record) and continue disposing zero values.
fn emit_global_set(
  name: String,
  value: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let boxed = set.contains(ctx.ref_global_names, name)
  let #(cell_fn, threaded_fn) = case boxed {
    True -> #("ref_global_set", "t_ref_global_set")
    False -> #("global_set", "t_global_set")
  }
  case sc {
    NoState -> {
      let effect =
        seam_call(ctx.binding.state_module, cell_fn, [
          core_binary_string(name),
          emit_value(value),
        ])
      emit_zero_effect(effect, cont, sc, state, ctx)
    }
    Threading(cur) -> {
      let call =
        seam_call(ctx.binding.state_module, threaded_fn, [
          CVar(cur),
          core_binary_string(name),
          emit_value(value),
        ])
      let #(newst, state2) = fresh_var(state)
      use #(rest, state3) <- result.try(apply_cont(
        cont,
        [],
        Threading(newst),
        state2,
        ctx,
      ))
      Ok(#(CLet([newst], call, rest), state3))
    }
  }
}

/// Bind a `#(value, InstanceState)` pair a threaded seam call returns (`t_grow`): a
/// `case <call> of <{V, St2}> when 'true' -> <continue with V under Threading(St2)>`. Used by
/// `memory.grow`, whose runtime returns `#(Int, InstanceState)`.
fn emit_value_state_pair(
  call: CExpr,
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(vvar, state2) = fresh_var(state)
  let #(stvar, state3) = fresh_var(state2)
  use #(rest, state4) <- result.try(apply_cont(
    cont,
    [CVar(vvar)],
    Threading(stvar),
    state3,
    ctx,
  ))
  Ok(#(
    CCase(call, [
      CClause([PTuple([PVar(vvar), PVar(stvar)])], CAtom("true"), rest),
    ]),
    state4,
  ))
}

/// Sequence a threaded RECORD-rebinding effect: reduce a trapping
/// `Result(InstanceState, TrapReason)` producer to the record on `{ok,S}` (raise on
/// `{error,E}`), bind it to a fresh state var, and continue under `Threading(new)` disposing
/// zero values. Used by `MemStore` (and by the threaded `instantiate` for element/data
/// segments). The `{ok,S}` arm yields the rebound record `S` (not a discardable `'ok'`).
fn emit_threaded_record_effect(
  call: CExpr,
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(newst, state2) = fresh_var(state)
  let #(reduced, state3) = record_result_case(call, ctx, state2)
  use #(rest, state4) <- result.try(apply_cont(
    cont,
    [],
    Threading(newst),
    state3,
    ctx,
  ))
  Ok(#(CLet([newst], reduced, rest), state4))
}

/// Reduce a trapping `Result(InstanceState, TrapReason)` producer to the record:
/// `case <call> of <{'ok',S}> -> S; <{'error',E}> -> raise(E) end`. The `{ok,S}` arm yields
/// the rebound record `S`; the `{error,E}` arm raises via `rt_trap`. Both arms yield exactly
/// one value, so the shape is arity-correct in any surrounding context.
fn record_result_case(
  call: CExpr,
  ctx: Ctx,
  state: EmitState,
) -> #(CExpr, EmitState) {
  let #(svar, state2) = fresh_var(state)
  let #(evar, state3) = fresh_var(state2)
  let reduced =
    CCase(call, [
      CClause([PTuple([PAtom("ok"), PVar(svar)])], CAtom("true"), CVar(svar)),
      CClause(
        [PTuple([PAtom("error"), PVar(evar)])],
        CAtom("true"),
        raise_trap(ctx, CVar(evar)),
      ),
    ])
  #(reduced, state3)
}

/// Dispose of the produced `vals` according to `cont`, under state channel `sc`.
///
/// - `KReturn`: `NoState` → yield `vals` as the `function_return` package; `Threading(cur)` →
///   pair it with the live record into `{Package, cur}` (§B.2).
/// - `KJump(target)`: `NoState` → tail-apply the join point `apply target(vals)`;
///   `Threading(cur)` → PREPEND the live record `apply target(cur, vals)` (the join was
///   widened by one leading state slot, §D).
/// - `KBind(names, body, next)`: bind `vals` to `names` (`ArityMismatch` if the counts
///   differ), then emit `body` under `next` — `sc` flows through unchanged (a bound value
///   list is state-neutral).
fn apply_cont(
  cont: Cont,
  vals: List(CExpr),
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case cont {
    KReturn ->
      case sc {
        NoState -> Ok(#(function_return(vals), state))
        Threading(cur) ->
          Ok(#(CTuple([function_return(vals), CVar(cur)]), state))
      }
    KJump(target) ->
      case sc {
        NoState -> Ok(#(CApply(target, vals), state))
        Threading(cur) -> Ok(#(CApply(target, [CVar(cur), ..vals]), state))
      }
    KBind(names, body, next) ->
      case list.length(names) == list.length(vals) {
        False -> Error(ArityMismatch(list.length(names), list.length(vals)))
        True -> {
          use #(body_c, state2) <- result.try(emit(body, next, sc, state, ctx))
          case names {
            // A zero-value bind is `let <> = <> in body`: the RHS `value_list([])` is the
            // empty value list `<>` — a pure literal with no side effects — so the `let` is a
            // vacuous no-op. Emit `body` directly. On a large guest (e.g. the TeaVM gateway)
            // this drops ~10k such lets (~10% of the emitted Core text), shrinking the
            // emit/scan/parse cost and wall-time. It does NOT change the resulting `.beam`
            // (`sys_core_fold` inside `compile:forms` already elides these), so the
            // compile:forms peak is unchanged; this is a text/transient/time win only.
            [] -> Ok(#(body_c, state2))
            _ -> Ok(#(CLet(names, value_list(vals), body_c), state2))
          }
        }
      }
  }
}

/// Dispose a single Core expression `produced` that itself yields a value LIST (a
/// `CallDirect`/`CallHost` to a function returning 0, 1, or many values) according to
/// `cont`.
///
/// A `CallDirect`/`CallHost` is realised as a single BEAM `apply`/`call` whose result is
/// ONE value — but the callee logically returns `r` values, packaged by `function_return`
/// (a dummy for `r==0`, the bare value for `r==1`, an `r`-tuple for `r>=2`). This routine
/// UNPACKS that single value back into `r` Core values and disposes them through `cont`.
///
/// - `KReturn`: the caller's own result is the same `r`-valued thing, already packaged
///   identically — yield `produced` straight through (no unpack/repack).
/// - otherwise: unpack and feed `apply_cont`:
///   - `r==0`: bind+discard the dummy (`let <_> = produced in …`), continue with no values;
///   - `r==1`: continue with the bare value (this matches the legacy single-result shape
///     exactly, so existing `.core` goldens are preserved);
///   - `r>=2`: destructure the result tuple `<{V1,…,Vr}>` and continue with `V1,…,Vr`.
///
/// `r` is the callee's result count (from `ctx.fn_results` for `CallDirect`; `1` for a
/// `CallHost`, whose Phase-1 fates each yield one value or raise). Validation guarantees
/// `r` matches the surrounding binding, so no arity error is raised here.
///
/// The `KReturn` STRAIGHT-THROUGH (yield `produced` unpackaged) is sound ONLY under
/// `NoState`: there the caller's own result is the same `r`-valued package. Under
/// `Threading(cur)` the caller must return `{Package, cur}`, so `produced` cannot be yielded
/// bare — it is unpacked into `r` values and re-disposed through `KReturn`, which pairs the
/// re-formed package with `cur`. (A THREADED callee's `{Package, St'}` tail call is handled
/// by `emit_call_direct` directly, preserving the cross-function tail call, §B.3.)
fn apply_cont_call(
  cont: Cont,
  produced: CExpr,
  r: Int,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case cont, sc {
    KReturn, NoState -> Ok(#(produced, state))
    _, _ -> apply_cont_call_unpack(cont, produced, r, sc, state, ctx)
  }
}

/// Unpack a single `function_return`-packaged value `produced` into its `r` values and
/// dispose them through `cont` under `sc`: `r==0` binds+discards the dummy (keeping the
/// effect); `r==1` continues with the bare value; `r>=2` destructures the `{V1,…,Vr}` tuple.
fn apply_cont_call_unpack(
  cont: Cont,
  produced: CExpr,
  r: Int,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case r {
    0 -> {
      let #(g, state2) = fresh_var(state)
      use #(rest, state3) <- result.try(apply_cont(cont, [], sc, state2, ctx))
      Ok(#(CLet([g], produced, rest), state3))
    }
    1 -> apply_cont(cont, [produced], sc, state, ctx)
    _ -> {
      let #(names, state2) = fresh_n_vars(state, r)
      use #(rest, state3) <- result.try(apply_cont(
        cont,
        list.map(names, CVar),
        sc,
        state2,
        ctx,
      ))
      let clause = CClause([PTuple(list.map(names, PVar))], CAtom("true"), rest)
      Ok(#(CCase(produced, [clause]), state3))
    }
  }
}

/// `n` fresh Core-variable raw names (in order), each distinct from every reserved name,
/// plus the advanced state. Used to destructure a multi-value call result tuple.
fn fresh_n_vars(state: EmitState, n: Int) -> #(List(String), EmitState) {
  case n <= 0 {
    True -> #([], state)
    False -> {
      let #(name, state2) = fresh_var(state)
      let #(rest, state3) = fresh_n_vars(state2, n - 1)
      #([name, ..rest], state3)
    }
  }
}

/// Materialise `cont` into a shared join point if it is non-trivial, under state channel `sc`.
///
/// `arity` is the number of values the multi-exit construct yields. A `KBind` continuation
/// is lowered to a `letrec` join `fun(names…) -> <body under next>`; the returned `Cont`
/// becomes `KJump('J')` so every exit tail-applies it once. A trivial continuation
/// (`KReturn`/`KJump`) is returned unchanged with no join point. `ArityMismatch` if the
/// bind's name count differs from `arity`.
///
/// Under `Threading(_)` the join is WIDENED by one leading state slot (§D):
/// `'J'/(arity+1) = fun(St, names…) -> <body under Threading(St)>`. Every exit appends its
/// live record to the value list (`apply_cont`'s `KJump` prepend), so the branches' differing
/// records UNIFY at the merge — the natural functional join, in constant stack (the join
/// `apply` stays a tail call). Under `NoState` the Phase-2/3 join is emitted verbatim.
fn materialize(
  cont: Cont,
  arity: Int,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(Option(FunDef), Cont, EmitState), EmitError) {
  case cont {
    KReturn -> Ok(#(None, KReturn, state))
    KJump(t) -> Ok(#(None, KJump(t), state))
    KBind(names, body, next) ->
      case list.length(names) == arity {
        False -> Error(ArityMismatch(arity, list.length(names)))
        True ->
          case sc {
            NoState -> {
              let #(jname, state2) = fresh_fn(state)
              let fname = FName(jname, arity)
              use #(jbody, state3) <- result.try(emit(
                body,
                next,
                NoState,
                state2,
                ctx,
              ))
              Ok(#(
                Some(FunDef(fname, CFun(names, jbody))),
                KJump(fname),
                state3,
              ))
            }
            Threading(_) -> {
              let #(jname, state2) = fresh_fn(state)
              let #(st_join, state3) = fresh_var(state2)
              let fname = FName(jname, arity + 1)
              use #(jbody, state4) <- result.try(emit(
                body,
                next,
                Threading(st_join),
                state3,
                ctx,
              ))
              Ok(#(
                Some(FunDef(fname, CFun([st_join, ..names], jbody))),
                KJump(fname),
                state4,
              ))
            }
          }
      }
  }
}

/// Wrap `inner` in a `letrec` for `maybe_def` (the materialised join point), if any.
fn wrap_join(maybe_def: Option(FunDef), inner: CExpr) -> CExpr {
  case maybe_def {
    Some(def) -> CLetrec([def], inner)
    None -> inner
  }
}

// ─────────────────────────────── lever 6: single-use join inlining ───────────────────────────────

/// Beta-reduce single-use, non-recursive `letrec` join functions across every def of `mod` (lever 6
/// — opt-in, run by `emit_module` only when `binding.inline_joins == True`).
///
/// 2core lowers each wasm block/if/switch continuation to a single-def
/// `letrec 'J'/n = fun(P1..Pn) -> Fbody in Inner`, entered by `apply 'J'/n(A1..An)` (`wrap_join` +
/// `materialize`). A join reached from EXACTLY ONE exit (a fall-through-only block) pays a fun
/// allocation + local call for nothing. This pass replaces that sole `apply 'J'/n(A1..An)` with
/// `let <P1..Pn> = <A1..An> in Fbody` and DROPS the `letrec`, leaving only `Inner`.
///
/// SOUNDNESS — a def is inlined IFF ALL hold (else the node is left byte-identical):
/// - SINGLE DEF: the letrec binds exactly one def (2core emits exactly one for joins/loops/try).
/// - NON-RECURSIVE: `Fbody` never applies `'J'/n`. A loop's back-edge (`Continue`) self-applies its
///   `'L'` head, so loops are recognised recursive and left intact.
/// - SINGLE-USE: `'J'/n` is applied EXACTLY ONCE across the whole enclosing function body. In this
///   AST an `FName` can ONLY appear as a `CApply` target (there is no first-class funref-to-`FName`
///   node — a closure applies a `CVar`/inline `fun` via `CApplyExpr`), so "applied once" is the
///   COMPLETE single-use condition: no other reference kind can leak the name.
/// - NOT TRY-PINNED: the def is not applied as a `CTry` `arg`. `emit_try` deliberately hoists its
///   protected body into a nullary local fun so the try `Arg` stays a single `apply`; inlining it
///   back would re-expose the `ambiguous_catch_try_state` BEAM-validator rejection the hoist
///   prevents, so any def applied as a `CTry.arg` is PINNED (never inlined).
///
/// Join params are fresh SSA names (`fresh_var`/`fresh_fn`), so the spliced body cannot capture, and
/// every free variable of `Fbody` is bound ABOVE the letrec — hence still in scope at the sole use
/// site (which lies inside `Inner`, i.e. inside that same enclosing scope). This is the standard
/// soundness of inlining a non-recursive single-use local function.
///
/// COMPLEXITY: two LINEAR passes over each def body — (1) `scan_joins` counts applies + detects
/// self-recursion and try-pinning in one traversal; (2) `inline_expr` rewrites top-down, splicing
/// each inlinable def's body from an environment keyed by its unique `FName`. Every node is visited
/// once (the precomputed counts stay valid because inlining removes only the def + its single apply,
/// never perturbing any OTHER name's count), so a deep nest (~280) of joins collapses in ONE pass —
/// no quadratic re-traversal.
pub fn inline_join_funs(mod: CModule) -> CModule {
  core_erlang.CModule(..mod, defs: list.map(mod.defs, inline_join_def))
}

/// Run the join-inlining pass over one top-level `FunDef`'s body. A non-`CFun` value (which never
/// occurs for an emitted def — every def RHS is a `CFun`, §core_erlang) is returned unchanged.
fn inline_join_def(def: FunDef) -> FunDef {
  case def.value {
    CFun(vars, body) -> {
      let info =
        scan_joins(body, set.new(), JoinInfo(dict.new(), set.new(), set.new()))
      FunDef(..def, value: CFun(vars, inline_expr(body, info, dict.new())))
    }
    _ -> def
  }
}

/// The per-body facts the inliner needs, gathered in ONE traversal (`scan_joins`):
/// - `counts`: for each applied `FName`, how many `apply` sites reference it in the whole body.
/// - `recursive`: the `FName`s applied WITHIN their own def's body (a loop back-edge) — never inline.
/// - `pinned`: the `FName`s applied as a `CTry` `arg` (the hoisted try-body funs) — never inline.
type JoinInfo {
  JoinInfo(counts: Dict(FName, Int), recursive: Set(FName), pinned: Set(FName))
}

/// Whether the def `fname` (bound by a single-def letrec) may be inlined: applied exactly once, not
/// self-recursive, and not try-pinned. All three are read from the precomputed `JoinInfo`.
fn join_inlinable(fname: FName, info: JoinInfo) -> Bool {
  dict.get(info.counts, fname) == Ok(1)
  && !set.contains(info.recursive, fname)
  && !set.contains(info.pinned, fname)
}

/// One linear traversal gathering `JoinInfo` for a function body. `scope` is the set of enclosing
/// `letrec` def names whose BODY we are currently inside — an `apply` of a name in `scope` marks it
/// recursive. `acc` is the accumulator threaded through.
fn scan_joins(expr: CExpr, scope: Set(FName), acc: JoinInfo) -> JoinInfo {
  case expr {
    CVar(_) | CInt(_) | CFloat(_) | CAtom(_) | CNil -> acc
    CCons(h, t) -> scan_joins(t, scope, scan_joins(h, scope, acc))
    CTuple(es) -> list.fold(es, acc, fn(a, e) { scan_joins(e, scope, a) })
    CBinary(segs) ->
      list.fold(segs, acc, fn(a, s) {
        scan_joins(s.size, scope, scan_joins(s.value, scope, a))
      })
    CValues(vs) -> list.fold(vs, acc, fn(a, e) { scan_joins(e, scope, a) })
    CFun(_, b) -> scan_joins(b, scope, acc)
    CLet(_, arg, body) -> scan_joins(body, scope, scan_joins(arg, scope, acc))
    CLetrec(defs, inner) -> {
      // Each def name is in scope for EVERY def body (letrec defs are mutually recursive) but NOT
      // for `inner` (a use in `inner` is the legitimate call, not a recursive back-edge).
      let names = set.from_list(list.map(defs, fn(d) { d.name }))
      let body_scope = set.union(scope, names)
      let acc2 =
        list.fold(defs, acc, fn(a, d) { scan_joins(def_body(d), body_scope, a) })
      scan_joins(inner, scope, acc2)
    }
    CCase(arg, clauses) ->
      list.fold(clauses, scan_joins(arg, scope, acc), fn(a, cl) {
        scan_joins(cl.body, scope, scan_joins(cl.guard, scope, a))
      })
    CApply(fname, args) -> {
      let n = case dict.get(acc.counts, fname) {
        Ok(c) -> c + 1
        Error(_) -> 1
      }
      let recursive = case set.contains(scope, fname) {
        True -> set.insert(acc.recursive, fname)
        False -> acc.recursive
      }
      let acc1 =
        JoinInfo(..acc, counts: dict.insert(acc.counts, fname, n), recursive:)
      list.fold(args, acc1, fn(a, e) { scan_joins(e, scope, a) })
    }
    CApplyExpr(op, args) ->
      list.fold(args, scan_joins(op, scope, acc), fn(a, e) {
        scan_joins(e, scope, a)
      })
    CCall(m, f, args) ->
      list.fold(args, scan_joins(f, scope, scan_joins(m, scope, acc)), fn(a, e) {
        scan_joins(e, scope, a)
      })
    CPrimop(_, args) ->
      list.fold(args, acc, fn(a, e) { scan_joins(e, scope, a) })
    CTry(arg, _, body, _, handler) -> {
      // PIN a def applied directly as the try `Arg` (the hoisted try-body): it must stay a single
      // `apply` (see `inline_join_funs`).
      let acc1 = case arg {
        CApply(fname, _) ->
          JoinInfo(..acc, pinned: set.insert(acc.pinned, fname))
        _ -> acc
      }
      scan_joins(
        handler,
        scope,
        scan_joins(body, scope, scan_joins(arg, scope, acc1)),
      )
    }
  }
}

/// The body expression of a `FunDef` — the `CFun` body when the RHS is a `fun` (always, for an
/// emitted def), else the RHS itself (keeps `scan_joins` total on a non-`CFun` RHS).
fn def_body(d: FunDef) -> CExpr {
  case d.value {
    CFun(_, b) -> b
    other -> other
  }
}

/// Top-down rewrite that inlines each eligible join. `env` maps an inlinable def's `FName` to its
/// `#(params, transformed_body)`; when the sole `apply` of that name is reached it is replaced by
/// `let <params> = <args> in body`. `env` only holds names decided inlinable at an enclosing letrec,
/// so a lookup hit is ALWAYS that def's unique call site.
fn inline_expr(
  expr: CExpr,
  info: JoinInfo,
  env: Dict(FName, #(List(String), CExpr)),
) -> CExpr {
  case expr {
    CVar(_) | CInt(_) | CFloat(_) | CAtom(_) | CNil -> expr
    CCons(h, t) -> CCons(inline_expr(h, info, env), inline_expr(t, info, env))
    CTuple(es) -> CTuple(list.map(es, fn(e) { inline_expr(e, info, env) }))
    CBinary(segs) ->
      CBinary(
        list.map(segs, fn(s) {
          CBitSeg(
            ..s,
            value: inline_expr(s.value, info, env),
            size: inline_expr(s.size, info, env),
          )
        }),
      )
    CValues(vs) -> CValues(list.map(vs, fn(e) { inline_expr(e, info, env) }))
    CFun(vars, b) -> CFun(vars, inline_expr(b, info, env))
    CLet(vars, arg, body) ->
      CLet(vars, inline_expr(arg, info, env), inline_expr(body, info, env))
    CLetrec([FunDef(fname, CFun(params, fbody))], inner) ->
      case join_inlinable(fname, info) {
        True -> {
          // Transform the body once (its own nested joins collapse), stash it, then rewrite `inner`
          // with the def in scope — the single `apply fname(..)` there splices it in. The letrec is
          // DROPPED (nothing else references `fname`).
          let fbody2 = inline_expr(fbody, info, env)
          let env2 = dict.insert(env, fname, #(params, fbody2))
          inline_expr(inner, info, env2)
        }
        False ->
          CLetrec(
            [FunDef(fname, CFun(params, inline_expr(fbody, info, env)))],
            inline_expr(inner, info, env),
          )
      }
    CLetrec(defs, inner) ->
      // Not the single-def-join shape — leave the letrec, but recurse into every def body + inner.
      CLetrec(
        list.map(defs, fn(d) {
          case d.value {
            CFun(vs, b) -> FunDef(d.name, CFun(vs, inline_expr(b, info, env)))
            other -> FunDef(d.name, inline_expr(other, info, env))
          }
        }),
        inline_expr(inner, info, env),
      )
    CCase(arg, clauses) ->
      CCase(
        inline_expr(arg, info, env),
        list.map(clauses, fn(cl) {
          CClause(
            cl.pats,
            inline_expr(cl.guard, info, env),
            inline_expr(cl.body, info, env),
          )
        }),
      )
    CApply(fname, args) -> {
      let args2 = list.map(args, fn(e) { inline_expr(e, info, env) })
      case dict.get(env, fname) {
        Ok(#(params, fbody2)) -> bind_join_args(params, args2, fbody2)
        Error(_) -> CApply(fname, args2)
      }
    }
    CApplyExpr(op, args) ->
      CApplyExpr(
        inline_expr(op, info, env),
        list.map(args, fn(e) { inline_expr(e, info, env) }),
      )
    CCall(m, f, args) ->
      CCall(
        inline_expr(m, info, env),
        inline_expr(f, info, env),
        list.map(args, fn(e) { inline_expr(e, info, env) }),
      )
    CPrimop(name, args) ->
      CPrimop(name, list.map(args, fn(e) { inline_expr(e, info, env) }))
    CTry(arg, bv, body, ev, handler) ->
      CTry(
        inline_expr(arg, info, env),
        bv,
        inline_expr(body, info, env),
        ev,
        inline_expr(handler, info, env),
      )
  }
}

/// Bind a join's `params` to the call-site `args` and run its `body` — the beta-reduction that
/// replaces `apply 'J'/n(args)` when inlined. Mirrors `apply_cont`'s `KBind`: `[]` params splice
/// `body` directly (the vacuous zero-value `let <> = <> in body`), otherwise
/// `let <params> = <value_list(args)> in body`. `len(params) == len(args)` always — a join's arity
/// equals its param count, and `emit_core` applies it with exactly that many args.
fn bind_join_args(
  params: List(String),
  args: List(CExpr),
  body: CExpr,
) -> CExpr {
  case params {
    [] -> body
    _ -> CLet(params, value_list(args), body)
  }
}

// ─────────────────────────── Lever 8: redundant-mask elimination (opt-in) ───────────────────────────

/// Eliminate a redundant OUTER bitwise-AND mask throughout every function body of `mod` (lever 8,
/// opt-in via `binding.lazy_mask`; a pure `CModule -> CModule` rewrite that is a safe no-op when the
/// pattern is absent). When the flag is off this is never applied, so the default Core is unchanged.
///
/// Lever 1 emits `call 'erlang':'band'(op, 2^n-1)` on every WRAPPING arithmetic op, so a chain
/// `band(band(X, M2), M1)` can arise — e.g. consecutive constant `i32.and`s (`x & 0xFF & 0xFFFF`),
/// or a re-normalized value flowing into another masked op. This rewrites `band(band(X, M2), M1)` →
/// `band(X, M2)` whenever `M1` and `M2` are INTEGER LITERALS with `M2 band M1 == M2` — i.e. M2's set
/// bits are a SUBSET of M1's, so the outer `band M1` cannot clear any bit that `band M2` left set
/// and is redundant.
///
/// **Soundness for ALL integers X (including negative).** With a non-negative finite mask M2,
/// `X band M2` is a NON-NEGATIVE value whose set bits ⊆ M2's bits; if M2's bits ⊆ M1's bits then
/// `(X band M2) band M1 == X band M2`. Every mask 2core emits here — `2^n-1`, the shift counts
/// `31`/`63`, and wasm-const operands (stored as unsigned bit patterns) — is non-negative, so the
/// identity holds regardless of X's runtime sign. The value operand X is preserved VERBATIM (never
/// dropped or duplicated), and no operand is evaluated a different number of times, so the transform
/// is semantics-preserving. Distinct from a risky interval-analysis "lazy masking" (NOT attempted).
pub fn elim_redundant_masks(mod: CModule) -> CModule {
  core_erlang.CModule(..mod, defs: list.map(mod.defs, mask_def))
}

/// Run the mask peephole over one top-level (or `letrec`) `FunDef`'s body. A non-`CFun` RHS (which
/// never occurs for an emitted def, §core_erlang) is returned unchanged.
fn mask_def(def: FunDef) -> FunDef {
  case def.value {
    CFun(vars, body) -> FunDef(..def, value: CFun(vars, mask_expr(body)))
    _ -> def
  }
}

/// Bottom-up rewrite: rewrite every child first, then apply the local redundant-mask reduction at a
/// `band` node. Because a node's children are collapsed BEFORE the node itself is examined, a whole
/// `band` chain reaches a fixpoint in ONE pass — each level sees its already-collapsed child, and a
/// produced `band(X, M2)` is never itself further reducible (its inner mask, if any, was resolved
/// against M2 when the child was rewritten).
fn mask_expr(expr: CExpr) -> CExpr {
  case expr {
    CVar(_) | CInt(_) | CFloat(_) | CAtom(_) | CNil -> expr
    CCons(h, t) -> CCons(mask_expr(h), mask_expr(t))
    CTuple(es) -> CTuple(list.map(es, mask_expr))
    CBinary(segs) ->
      CBinary(
        list.map(segs, fn(s) {
          CBitSeg(..s, value: mask_expr(s.value), size: mask_expr(s.size))
        }),
      )
    CValues(vs) -> CValues(list.map(vs, mask_expr))
    CFun(vars, b) -> CFun(vars, mask_expr(b))
    CLet(vars, arg, body) -> CLet(vars, mask_expr(arg), mask_expr(body))
    CLetrec(defs, inner) -> CLetrec(list.map(defs, mask_def), mask_expr(inner))
    CCase(arg, clauses) ->
      CCase(
        mask_expr(arg),
        list.map(clauses, fn(cl) {
          CClause(cl.pats, mask_expr(cl.guard), mask_expr(cl.body))
        }),
      )
    CApply(fname, args) -> CApply(fname, list.map(args, mask_expr))
    CApplyExpr(op, args) -> CApplyExpr(mask_expr(op), list.map(args, mask_expr))
    // `band` is the only reducible node — apply the local rule to the rewritten `call`.
    CCall(m, f, args) ->
      reduce_mask(CCall(mask_expr(m), mask_expr(f), list.map(args, mask_expr)))
    CPrimop(name, args) -> CPrimop(name, list.map(args, mask_expr))
    CTry(arg, bv, body, ev, handler) ->
      CTry(mask_expr(arg), bv, mask_expr(body), ev, mask_expr(handler))
  }
}

/// Apply ONE redundant-mask reduction at a `band` node whose children are already rewritten:
/// `band(band(X, M2), M1)` → `band(X, M2)` when `M1`, `M2` are integer literals and `M2 band M1 ==
/// M2` (M2's bits ⊆ M1's). Returns `node` unchanged when it is not a reducible masked-band-of-
/// masked-band (the common case — a safe no-op).
fn reduce_mask(node: CExpr) -> CExpr {
  case as_masked(node) {
    Some(#(inner, m1)) ->
      case as_masked(inner) {
        Some(#(x, m2)) ->
          case int.bitwise_and(m2, m1) == m2 {
            True -> band_lit(x, m2)
            False -> node
          }
        None -> node
      }
    None -> node
  }
}

/// Recognize a bitwise-AND against a SINGLE integer-literal mask: `band(V, CInt(M))` or the
/// commuted `band(CInt(M), V)`. Returns `Some(#(V, M))` — the value operand and the literal mask —
/// or `None` for a non-`band`, a wrong arity, or a `band` with zero or two literal operands (no
/// single value/mask split). `band` is commutative, so either operand order is accepted; a
/// `band(CInt, CInt)` (a constant — nothing to preserve) yields `None`.
fn as_masked(node: CExpr) -> Option(#(CExpr, Int)) {
  case node {
    CCall(CAtom("erlang"), CAtom("band"), [CInt(m), v]) ->
      case v {
        CInt(_) -> None
        _ -> Some(#(v, m))
      }
    CCall(CAtom("erlang"), CAtom("band"), [v, CInt(m)]) ->
      case v {
        CInt(_) -> None
        _ -> Some(#(v, m))
      }
    _ -> None
  }
}

/// Build the reduced single-mask node `call 'erlang':'band'(x, M)`.
fn band_lit(x: CExpr, mask: Int) -> CExpr {
  CCall(CAtom("erlang"), CAtom("band"), [x, CInt(mask)])
}

// ─────────────────────────────── numeric ops (the chokepoint) ───────────────────────────────

/// A BEAM guard-BIF call `call 'erlang':'<name>'(args…)`. The Erlang compiler folds these
/// (`+`/`band`/`bsl`/`<`/…) to inline `bif`/`gc_bif` instructions, so no function call remains.
fn bif(name: String, args: List(CExpr)) -> CExpr {
  CCall(CAtom("erlang"), CAtom(name), args)
}

/// The unsigned mask `2^n − 1` bounding an n-bit value (the two's-complement wrap bound).
fn width_mask(w: IntWidth) -> Int {
  case w {
    W32 -> 4_294_967_295
    W64 -> 18_446_744_073_709_551_615
  }
}

/// `band(expr, 2^n−1)` — normalize an arithmetic result to the width's unsigned range.
/// Bit-identical to `rt_num.norm` (`norm(x,n) == band(x, 2^n−1)` for ANY Erlang integer,
/// positive or negative — the low n bits of the two's-complement representation).
fn mask_to_width(w: IntWidth, expr: CExpr) -> CExpr {
  bif("band", [expr, CInt(width_mask(w))])
}

/// The shift/rotate count `b band (n−1)` — matches `rt_num.shift_count`.
fn shift_count_expr(w: IntWidth, b: CExpr) -> CExpr {
  let mask = case w {
    W32 -> 31
    W64 -> 63
  }
  bif("band", [b, CInt(mask)])
}

/// Try to lower a non-trapping integer `NumOp` to an INLINE BEAM guard BIF instead of an
/// `rt_num` seam call, so a `rt_num:i32_add` local function call becomes a folded `+`/`band`
/// instruction (per-op function-call overhead is a large fraction of a wasm-lowered guest's
/// runtime). Returns `Ok(expr)` for the provably-exact inlinable ops, `Error(Nil)` for
/// everything else (signed compares/shifts, rotate, clz/ctz/popcnt, div/rem, float,
/// conversions) — those stay on the `rt_num` seam. `args` are the already-emitted operands.
///
/// Bit-exactness (rt_num.gleam is the oracle): `norm(x,n) == band(x, 2^n−1)` so add/sub/mul
/// and `shl` reduce to a masked BIF; `and`/`or`/`xor` and `shr_u` are already in-range so need
/// no mask; `eqz`/`eq`/`ne` and the UNSIGNED comparisons (`lt_u`/`gt_u`/`le_u`/`ge_u`) are raw
/// BEAM comparisons on the stored unsigned bit patterns. SIGNED compares/shifts need a
/// `signed(a,n)` reinterpret first, so they deliberately stay on the seam.
fn inline_num_op(op: NumOp, args: List(CExpr)) -> Result(CExpr, Nil) {
  case op, args {
    IAnd(_), [a, b] -> Ok(bif("band", [a, b]))
    IOr(_), [a, b] -> Ok(bif("bor", [a, b]))
    IXor(_), [a, b] -> Ok(bif("bxor", [a, b]))
    IAdd(w), [a, b] -> Ok(mask_to_width(w, bif("+", [a, b])))
    ISub(w), [a, b] -> Ok(mask_to_width(w, bif("-", [a, b])))
    IMul(w), [a, b] -> Ok(mask_to_width(w, bif("*", [a, b])))
    IShl(w), [a, b] ->
      Ok(mask_to_width(w, bif("bsl", [a, shift_count_expr(w, b)])))
    IShrU(w), [a, b] -> Ok(bif("bsr", [a, shift_count_expr(w, b)]))
    IEqz(_), [a] -> Ok(bool_bif_to_i32("=:=", [a, CInt(0)]))
    IEq(_), [a, b] -> Ok(bool_bif_to_i32("=:=", [a, b]))
    INe(_), [a, b] -> Ok(bool_bif_to_i32("=/=", [a, b]))
    ILtU(_), [a, b] -> Ok(bool_bif_to_i32("<", [a, b]))
    IGtU(_), [a, b] -> Ok(bool_bif_to_i32(">", [a, b]))
    ILeU(_), [a, b] -> Ok(bool_bif_to_i32("=<", [a, b]))
    IGeU(_), [a, b] -> Ok(bool_bif_to_i32(">=", [a, b]))
    _, _ -> Error(Nil)
  }
}

/// Lower a `Num` op through `binding.num_module` (the numeric chokepoint).
///
/// The hot, provably-exact non-trapping integer ops are INLINED as BEAM BIFs (`inline_num_op`)
/// — valid only because `num_module` is the standard `rt_num` (its single definition site). The
/// rest emit `call '<num>':'<fn>'(args…)`. The four trapping ops (`div`/`rem`, signed and
/// unsigned) return `Result(Int, TrapReason)` = `{ok,X}`/`{error,R}`; they emit the verified
/// `case`-and-`raise` shape, continuing with `X` on `{ok,X}` and raising `R` via
/// `binding.trap_module` on `{error,R}`.
fn emit_num(
  op: NumOp,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let cargs = list.map(args, emit_value)
  case
    ctx.binding.num_module == "twocore@runtime@rt_num",
    inline_num_op(op, cargs)
  {
    True, Ok(inlined) -> apply_cont(cont, [inlined], sc, state, ctx)
    _, _ -> {
      let call = seam_call(ctx.binding.num_module, num_op_name(op), cargs)
      case is_trapping(op) {
        False -> apply_cont(cont, [call], sc, state, ctx)
        True -> emit_trapping_result(call, cont, sc, state, ctx)
      }
    }
  }
}

// ─────────────────────────── the state-access seam + dispositions ───────────────────────────

/// Emit a direct call to a fixed runtime module field of the `Binding` — THE state-access
/// seam (E1). `module` is always a build-controlled `twocore@runtime@*` atom (one of
/// `binding.{num,trap,host,meter,stdlib,mem,table,state}_module`), never a program value;
/// `fn_name` is always a literal atom (D3a — no ambient authority). For the cell strategy
/// every stateful op is a `call '<module>':'<fn_name>'(args)`; the Phase-3 `threaded`
/// retrofit expands THIS one helper rather than every op site.
fn seam_call(module: String, fn_name: String, args: List(CExpr)) -> CExpr {
  CCall(CAtom(module), CAtom(fn_name), args)
}

/// Dispose a trapping `Result(Int, TrapReason)` producer — the verified `case`-and-`raise`
/// shape shared by trapping `Num`, `MemLoad`, and trapping `Convert`.
///
/// A trapping op yields EXACTLY ONE value (or raises). Reduce it to a single bound variable
/// `rvar` via a `case` whose BOTH clauses yield one value — the unwrapped `{ok,X}` result,
/// or the never-returning `raise` on `{error,E}` — then thread that single value through
/// `cont` normally. Binding once and threading once keeps the two `case` arms arity-
/// consistent (both yield 1) regardless of the surrounding value-list arity: a 0-result
/// function (`cont` yields `<>`) or a multi-value join point would break a structure that
/// inlined `cont` into only the `ok` arm, because then the `error` arm's lone `raise` value
/// would disagree with the `ok` arm's arity (the Core compiler rejects that as a "return
/// count mismatch").
fn emit_trapping_result(
  produced: CExpr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(xvar, state2) = fresh_var(state)
  let #(evar, state3) = fresh_var(state2)
  let #(rvar, state4) = fresh_var(state3)
  let result_case =
    CCase(produced, [
      CClause([PTuple([PAtom("ok"), PVar(xvar)])], CAtom("true"), CVar(xvar)),
      CClause(
        [PTuple([PAtom("error"), PVar(evar)])],
        CAtom("true"),
        raise_trap(ctx, CVar(evar)),
      ),
    ])
  use #(rest, state5) <- result.try(apply_cont(
    cont,
    [CVar(rvar)],
    sc,
    state4,
    ctx,
  ))
  Ok(#(CLet([rvar], result_case, rest), state5))
}

/// Reduce a trapping zero-result `Result(Nil, TrapReason)` producer (`MemStore`,
/// `init_elem`, `init_data`) to a SINGLE discardable value: `{ok,_}` → `'ok'`,
/// `{error,E}` → `raise(E)`. Returns the reduced `case` expression (one value), ready to be
/// sequenced as an ordered effect by `emit_zero_effect`.
fn trapping_effect(
  call: CExpr,
  ctx: Ctx,
  state: EmitState,
) -> #(CExpr, EmitState) {
  let #(wild, state2) = fresh_var(state)
  let #(evar, state3) = fresh_var(state2)
  let reduced =
    CCase(call, [
      CClause([PTuple([PAtom("ok"), PVar(wild)])], CAtom("true"), CAtom("ok")),
      CClause(
        [PTuple([PAtom("error"), PVar(evar)])],
        CAtom("true"),
        raise_trap(ctx, CVar(evar)),
      ),
    ])
  #(reduced, state3)
}

/// Sequence a ZERO-RESULT ordered effect: `let <g> = <effect> in <rest>` with `g`
/// discarded and `<rest>` emitted under `cont` disposing ZERO values. Non-DCE, non-
/// reorderable (E6): Core `let` is strict, so the effect always runs before `<rest>` and
/// is never eliminated.
fn emit_zero_effect(
  effect: CExpr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(g, state2) = fresh_var(state)
  use #(rest, state3) <- result.try(apply_cont(cont, [], sc, state2, ctx))
  Ok(#(CLet([g], effect, rest), state3))
}

/// The Erlang atom `'true'`/`'false'` for a `Bool` — `MemLoad`'s `Signed` argument.
fn bool_atom(b: Bool) -> CExpr {
  case b {
    True -> CAtom("true")
    False -> CAtom("false")
  }
}

/// The load result width in bits — `W(result)` from the load's result `ValType`: 32 for
/// `TI32`/`TF32`, 64 for `TI64`/`TF64` (raw-bits rep: `f32.load` == `i32.load` byte-wise, so
/// only width+sign matter). `TTerm` cannot be a numeric load result; defaulted to 32.
fn result_width(t: ValType) -> Int {
  case t {
    TI32 | TF32 | TTerm -> 32
    TI64 | TF64 -> 64
    // Reference types are never a numeric load result (validate rejects it); defaulted to 32.
    ir.TFuncRef | ir.TExternRef -> 32
    // A `v128` is a 16-byte value — 128 bits. Never a scalar numeric-load result (validate
    // rejects it; SIMD loads route through the dedicated `SimdLoad*` nodes, P6-06). §J.
    ir.TV128 -> 128
    // An `exnref` is a reference, never a numeric load result (validate rejects it); defaulted
    // to 32 like the other references (Phase-7, T9). §J.
    ir.TExnRef -> 32
  }
}

/// Lower a `Convert` op. Numeric width/sign/reinterpret/saturating-truncation/int→float/
/// demote/promote conversions route through `binding.num_module` (the same chokepoint) as a
/// bare `call` (total — never traps). The TRAPPING float→int truncations (`TruncS`/`TruncU`)
/// return `Result(Int, TrapReason)` and route through the verified `case`-and-`raise` shape
/// (`emit_trapping_result`), exactly like `IDivS` — `is_trapping_conv` decides which.
///
/// The four term↔numeric boxing conversions (`BoxInt`/`UnboxInt`/`BoxFloat`/`UnboxFloat`, the
/// K5/D5 bridge) intercept BEFORE `conv_op_name` and lower to a PURE value pass-through — a
/// static-type retag emitting no `num_module` call. This is bit-exact and total: 2core carries
/// every scalar, floats INCLUDED, as its raw bit pattern (an Erlang integer — see `emit_value`
/// for `ConstF64`/`ConstI64` and `rt_num`'s representation contract), so a `TF64`/`TI32`/… and
/// the term that boxes it are the SAME Erlang value; boxing only changes the static IR type.
/// A pass-through therefore round-trips ALL patterns (finite, denormal, NaN, ±Inf, the full
/// i64 bignum range) exactly — where a bits→BEAM-`float()` reinterpret would be impossible,
/// because NaN/±Inf bit patterns cannot be matched as a BEAM `float()` (`<<F:64/float>>` raises
/// `badmatch` on them; this is the very reason D5 keeps floats as bits).
fn emit_convert(
  op: ConvOp,
  arg: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case is_boxing_conv(op) {
    // Term↔numeric boxing bridge (K5/D5): identity on the carried bit pattern.
    True -> apply_cont(cont, [emit_value(arg)], sc, state, ctx)
    False ->
      case conv_op_name(op) {
        Error(node) -> Error(UnsupportedNode(node))
        Ok(fn_name) -> {
          let call =
            seam_call(ctx.binding.num_module, fn_name, [emit_value(arg)])
          case is_trapping_conv(op) {
            True -> emit_trapping_result(call, cont, sc, state, ctx)
            False -> apply_cont(cont, [call], sc, state, ctx)
          }
        }
      }
  }
}

/// `True` for exactly the four term↔numeric boxing conversions (`BoxInt`/`UnboxInt`/
/// `BoxFloat`/`UnboxFloat`) — the ONLY IR bridge between the unboxed numeric layer
/// (`TI32`/`TI64`/`TF32`/`TF64`) and the term layer (`TTerm`) (K5). `emit_convert` lowers these
/// as a pure value pass-through (a static-type retag), NEVER a `num_module` call, because
/// 2core represents every scalar — floats as raw bits (D5) — as the same underlying Erlang
/// value; boxing changes only the static type. `False` for every other `ConvOp` (a genuine
/// `num_module` value transform routed via `conv_op_name`).
fn is_boxing_conv(op: ConvOp) -> Bool {
  case op {
    BoxInt(_) | UnboxInt(_) | BoxFloat(_) | UnboxFloat(_) -> True
    _ -> False
  }
}

/// Emit a trap raise: `call '<trap_module>':'raise'(Reason)`. `reason_expr` is the
/// trap-kind atom (for `Trap`) or the error payload var (for a trapping `Num` error arm).
fn raise_trap(ctx: Ctx, reason_expr: CExpr) -> CExpr {
  CCall(CAtom(ctx.binding.trap_module), CAtom("raise"), [reason_expr])
}

// ─────────────────────────── SIMD lane ops (the chokepoint, §B) ───────────────────────────

/// Lower a pure lane-wise `Simd(op, args)` through the SIMD chokepoint (`simd_module`).
///
/// PURE, state-neutral, NON-trapping (I3/I6): a bare `call '<rt_simd>':'<simd_op_name(op)>'(args…)`
/// whose single result (a v128 binary, or an i32/i64/f-bits scalar for extract-lane / `VAnyTrue` /
/// `SAllTrue` / `SBitmask`) is passed to `cont`. Emitted identically under `Cell` and `Threaded`
/// (`cur` flows through UNCHANGED — a v128 op reaches no state), so a SIMD-arithmetic-only body is
/// byte-identical across strategies and keeps its Phase-1 pure arity (§A.3, the I7-neutral shape).
/// The lane immediate of `SExtractLane*`/`SReplaceLane` is spliced by `simd_call_args` at the exact
/// position the FROZEN `rt_simd` head expects (extract: `(vec, lane)`; replace: `(vec, lane, x)`).
fn emit_simd(
  op: ir.SimdOp,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let call = seam_call(simd_module, simd_op_name(op), simd_call_args(op, args))
  apply_cont(cont, [call], sc, state, ctx)
}

/// Lower a `Gc(op, args)` to a single `rt_gc` seam call. Every GC op is one call
/// (the runtime raises any trap itself — `ref.cast` cast-failure, `array.*` OOB,
/// null deref — so no trap plumbing is needed here); its result is the operation's
/// single pushed value (or `ok` for a `void` op, discarded by the continuation).
fn emit_gc(
  op: ir.GcOp,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case op {
    // call_ref returns the callee's N results (a package) — a dedicated path
    // unpacks it and threads state, exactly like an indirect call.
    ir.GcCallRef(rc) -> emit_gc_call_ref(rc, args, cont, sc, state, ctx)
    // Segment-sourced array ops resolve their drop-gated segment payload (bytes
    // for data, rendered ref values for elem) before the arena call.
    ir.GcArrayNewData(t, d, w) ->
      emit_gc_array_new_data(t, d, w, args, cont, sc, state, ctx)
    ir.GcArrayInitData(d, w) ->
      emit_gc_array_init_data(d, w, args, cont, sc, state, ctx)
    ir.GcArrayNewElem(t, e) ->
      emit_gc_array_new_elem(t, e, args, cont, sc, state, ctx)
    ir.GcArrayInitElem(e) ->
      emit_gc_array_init_elem(e, args, cont, sc, state, ctx)
    _ -> {
      let call = seam_call(gc_module, gc_op_name(op), gc_call_args(op, args))
      case gc_is_void(op) {
        // struct.set / array.set / fill / copy push no value — sequence the call
        // and continue with zero results.
        True -> emit_zero_effect(call, cont, sc, state, ctx)
        // Every other GC op pushes exactly its one result (a ref, i32, or term).
        False -> apply_cont(cont, [call], sc, state, ctx)
      }
    }
  }
}

/// Emit `call_ref $t`: apply the funcref (args = `[funcref, ...params]`) through
/// the `rt_gc` seam, which null-checks and applies the funcref's build-strategy
/// closure, returning the callee's `result_count` results as a list (raising the
/// null trap itself). Under `Threaded` the seam also threads instance state.
fn emit_gc_call_ref(
  rc: Int,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(funcref, params) = case args {
    [f, ..ps] -> #(f, ps)
    [] -> #(ir.ConstI32(0), [])
  }
  let params_c = core_list(list.map(params, emit_value))
  case sc {
    NoState -> {
      let call =
        seam_call(gc_module, "call_ref", [
          emit_value(funcref),
          params_c,
          CInt(rc),
        ])
      let #(lvar, state2) = fresh_var(state)
      use #(rest, state3) <- result.try(unpack_result_list(
        lvar,
        rc,
        cont,
        NoState,
        state2,
        ctx,
      ))
      Ok(#(CLet([lvar], call, rest), state3))
    }
    Threading(cur) -> {
      let call =
        seam_call(gc_module, "t_call_ref", [
          CVar(cur),
          emit_value(funcref),
          params_c,
          CInt(rc),
        ])
      let #(pair, state2) = fresh_var(state)
      let #(rsvar, state3) = fresh_var(state2)
      let #(stvar, state4) = fresh_var(state3)
      use #(rest, state5) <- result.try(unpack_result_list(
        rsvar,
        rc,
        cont,
        Threading(stvar),
        state4,
        ctx,
      ))
      let destructure =
        CCase(CVar(pair), [
          CClause([PTuple([PVar(rsvar), PVar(stvar)])], CAtom("true"), rest),
        ])
      Ok(#(CLet([pair], call, destructure), state5))
    }
  }
}

/// The GC ops that produce no stack value (a pure heap mutation).
fn gc_is_void(op: ir.GcOp) -> Bool {
  case op {
    ir.GcStructSet(_) | ir.GcArraySet | ir.GcArrayFill | ir.GcArrayCopy -> True
    _ -> False
  }
}

/// Emit `array.new_data $t $d`: resolve the drop-gated bytes of data segment `d`
/// (empty if dropped), then build the array from `count` elements of `width`
/// little-endian bytes at `byte_offset` (`[byte_offset, count]` operands). The
/// arena call raises the OOB trap itself and returns the new array reference.
fn emit_gc_array_new_data(
  type_idx: Int,
  data_idx: Int,
  width: Int,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use segment <- result.try(
    nth(ctx.data_segments, data_idx)
    |> result.replace_error(UnsupportedNode("array_new_data_seg")),
  )
  let #(offset, count) = gc_two_args(args)
  let #(gated, state2) =
    drop_gate(
      data_idx,
      "data_dropped",
      core_binary_bytes(<<>>),
      core_binary_bytes(segment.bytes),
      sc,
      state,
      ctx,
    )
  let #(segvar, state3) = fresh_var(state2)
  let call =
    seam_call(gc_module, "array_new_data", [
      CInt(type_idx),
      CVar(segvar),
      emit_value(offset),
      emit_value(count),
      CInt(width),
    ])
  use #(rest, state4) <- result.try(apply_cont(cont, [call], sc, state3, ctx))
  Ok(#(CLet([segvar], gated, rest), state4))
}

/// Emit `array.init_data $t $d`: like `array.new_data`, but copy into an existing
/// array (`[arrayref, dst_index, src_byte_offset, count]` operands). No result.
fn emit_gc_array_init_data(
  data_idx: Int,
  width: Int,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use segment <- result.try(
    nth(ctx.data_segments, data_idx)
    |> result.replace_error(UnsupportedNode("array_init_data_seg")),
  )
  let #(arrayref, dst, src, count) = gc_four_args(args)
  let #(gated, state2) =
    drop_gate(
      data_idx,
      "data_dropped",
      core_binary_bytes(<<>>),
      core_binary_bytes(segment.bytes),
      sc,
      state,
      ctx,
    )
  let #(segvar, state3) = fresh_var(state2)
  let call =
    seam_call(gc_module, "array_init_data", [
      emit_value(arrayref),
      emit_value(dst),
      CVar(segvar),
      emit_value(src),
      emit_value(count),
      CInt(width),
    ])
  use #(rest, state4) <- result.try(emit_zero_effect(
    call,
    cont,
    sc,
    state3,
    ctx,
  ))
  Ok(#(CLet([segvar], gated, rest), state4))
}

/// Emit `array.new_elem $t $e`: render element segment `e`'s init items to a
/// drop-gated Core reference list (empty if dropped), then build the array from
/// `count` of them starting at `elem_offset` (`[elem_offset, count]` operands).
fn emit_gc_array_new_elem(
  type_idx: Int,
  elem_idx: Int,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use segment <- result.try(
    nth(ctx.elements, elem_idx)
    |> result.replace_error(UnsupportedNode("array_new_elem_seg")),
  )
  let #(offset, count) = gc_two_args(args)
  let items_state_ref = case sc {
    NoState -> None
    Threading(cur) -> Some(cur)
  }
  use #(entries, state2) <- result.try(render_ref_items(
    segment.init,
    ctx,
    items_state_ref,
    state,
  ))
  let #(gated, state3) =
    drop_gate(
      elem_idx,
      "elem_dropped",
      CNil,
      core_list(entries),
      sc,
      state2,
      ctx,
    )
  let #(segvar, state4) = fresh_var(state3)
  let call =
    seam_call(gc_module, "array_new_elem", [
      CInt(type_idx),
      CVar(segvar),
      emit_value(offset),
      emit_value(count),
    ])
  use #(rest, state5) <- result.try(apply_cont(cont, [call], sc, state4, ctx))
  Ok(#(CLet([segvar], gated, rest), state5))
}

/// Emit `array.init_elem $t $e`: like `array.new_elem`, but copy into an existing
/// array (`[arrayref, dst_index, src_index, count]` operands). No result.
fn emit_gc_array_init_elem(
  elem_idx: Int,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use segment <- result.try(
    nth(ctx.elements, elem_idx)
    |> result.replace_error(UnsupportedNode("array_init_elem_seg")),
  )
  let #(arrayref, dst, src, count) = gc_four_args(args)
  let items_state_ref = case sc {
    NoState -> None
    Threading(cur) -> Some(cur)
  }
  use #(entries, state2) <- result.try(render_ref_items(
    segment.init,
    ctx,
    items_state_ref,
    state,
  ))
  let #(gated, state3) =
    drop_gate(
      elem_idx,
      "elem_dropped",
      CNil,
      core_list(entries),
      sc,
      state2,
      ctx,
    )
  let #(segvar, state4) = fresh_var(state3)
  let call =
    seam_call(gc_module, "array_init_elem", [
      emit_value(arrayref),
      emit_value(dst),
      CVar(segvar),
      emit_value(src),
      emit_value(count),
    ])
  use #(rest, state5) <- result.try(emit_zero_effect(
    call,
    cont,
    sc,
    state4,
    ctx,
  ))
  Ok(#(CLet([segvar], gated, rest), state5))
}

/// Split a two-operand GC arg list `[a, b]` (a defensive zero pair otherwise —
/// arity is already validated).
fn gc_two_args(args: List(Value)) -> #(Value, Value) {
  case args {
    [a, b] -> #(a, b)
    _ -> #(ir.ConstI32(0), ir.ConstI32(0))
  }
}

/// Split a four-operand GC arg list `[a, b, c, d]`.
fn gc_four_args(args: List(Value)) -> #(Value, Value, Value, Value) {
  case args {
    [a, b, c, d] -> #(a, b, c, d)
    _ -> #(ir.ConstI32(0), ir.ConstI32(0), ir.ConstI32(0), ir.ConstI32(0))
  }
}

/// The `rt_gc` function name for a GC op. Packed reads and the signed/unsigned
/// i31 reads dispatch to distinct helpers so the runtime need not carry the width.
fn gc_op_name(op: ir.GcOp) -> String {
  case op {
    ir.GcStructNew(_) -> "struct_new"
    ir.GcStructGet(_, ir.ReadPlain) -> "struct_get"
    ir.GcStructGet(_, ir.ReadPacked(_, _)) -> "struct_get_packed"
    ir.GcStructSet(_) -> "struct_set"
    ir.GcArrayNew(_) -> "array_new"
    ir.GcArrayNewFixed(_) -> "array_new_fixed"
    ir.GcArrayGet(ir.ReadPlain) -> "array_get"
    ir.GcArrayGet(ir.ReadPacked(_, _)) -> "array_get_packed"
    ir.GcArraySet -> "array_set"
    ir.GcArrayLen -> "array_len"
    ir.GcArrayFill -> "array_fill"
    ir.GcArrayCopy -> "array_copy"
    ir.GcRefI31 -> "ref_i31"
    ir.GcI31Get(True) -> "i31_get_s"
    ir.GcI31Get(False) -> "i31_get_u"
    ir.GcRefTest(_, _) -> "ref_test"
    ir.GcRefCast(_, _) -> "ref_cast"
    ir.GcRefEq -> "ref_eq"
    ir.GcRefAsNonNull -> "ref_as_non_null"
    ir.GcAnyConvertExtern -> "any_convert_extern"
    ir.GcExternConvertAny -> "extern_convert_any"
    // Handled by dedicated emitters before this table is consulted.
    ir.GcCallRef(_) -> "call_ref"
    ir.GcArrayNewData(_, _, _) -> "array_new_data"
    ir.GcArrayInitData(_, _) -> "array_init_data"
    ir.GcArrayNewElem(_, _) -> "array_new_elem"
    ir.GcArrayInitElem(_) -> "array_init_elem"
  }
}

/// The Core argument list for a GC op: the operand values (bottom-of-stack first)
/// with the op's compile-time immediates spliced in — the type index / field
/// index / packed width+signedness / RTTI matcher the runtime needs. Field lists
/// (`struct.new`, `array.new_fixed`) are passed as a single Core list.
fn gc_call_args(op: ir.GcOp, args: List(Value)) -> List(CExpr) {
  let ev = list.map(args, emit_value)
  case op {
    ir.GcStructNew(t) -> [CInt(t), core_list(ev)]
    ir.GcStructGet(f, ir.ReadPlain) -> list.append(ev, [CInt(f)])
    ir.GcStructGet(f, ir.ReadPacked(bits, signed)) ->
      list.append(ev, [CInt(f), CInt(bits), cbool(signed)])
    ir.GcStructSet(f) ->
      case ev {
        [ref, val] -> [ref, CInt(f), val]
        _ -> ev
      }
    ir.GcArrayNew(t) -> [CInt(t), ..ev]
    ir.GcArrayNewFixed(t) -> [CInt(t), core_list(ev)]
    ir.GcArrayGet(ir.ReadPlain) -> ev
    ir.GcArrayGet(ir.ReadPacked(bits, signed)) ->
      list.append(ev, [CInt(bits), cbool(signed)])
    ir.GcArraySet -> ev
    ir.GcArrayLen -> ev
    ir.GcArrayFill -> ev
    ir.GcArrayCopy -> ev
    ir.GcRefI31 -> ev
    ir.GcI31Get(_) -> ev
    ir.GcRefTest(m, null_ok) ->
      list.append(ev, [emit_matcher(m), cbool(null_ok)])
    ir.GcRefCast(m, null_ok) ->
      list.append(ev, [emit_matcher(m), cbool(null_ok)])
    ir.GcRefEq -> ev
    ir.GcRefAsNonNull -> ev
    ir.GcAnyConvertExtern -> ev
    ir.GcExternConvertAny -> ev
    // Handled by dedicated emitters before this table is consulted.
    ir.GcCallRef(_)
    | ir.GcArrayNewData(_, _, _)
    | ir.GcArrayInitData(_, _)
    | ir.GcArrayNewElem(_, _)
    | ir.GcArrayInitElem(_) -> ev
  }
}

/// Render a compile-time RTTI matcher as a Core literal: `{concrete, [I0,I1,…]}`
/// (the closed set of subtype indices) or `{abstract, Kind}` (an object-kind atom).
fn emit_matcher(m: ir.GcMatcher) -> CExpr {
  case m {
    ir.MatchConcrete(ts) ->
      CTuple([CAtom("concrete"), core_list(list.map(ts, CInt))])
    ir.MatchAbstract(k) -> CTuple([CAtom("abstract"), CAtom(gc_kind_atom(k))])
  }
}

fn gc_kind_atom(k: ir.GcKind) -> String {
  case k {
    ir.KStruct -> "struct"
    ir.KArray -> "array"
    ir.KI31 -> "i31"
    ir.KEq -> "eq"
    ir.KAny -> "any"
    ir.KNone -> "none"
    ir.KFunc -> "func"
    ir.KNoFunc -> "nofunc"
    ir.KExtern -> "extern"
    ir.KNoExtern -> "noextern"
    ir.KExn -> "exn"
    ir.KNoExn -> "noexn"
  }
}

/// A Core boolean atom (`'true'`/`'false'`).
fn cbool(b: Bool) -> CExpr {
  case b {
    True -> CAtom("true")
    False -> CAtom("false")
  }
}

/// Build the concrete Core argument list for a `Simd(op, args)`, splicing any static lane
/// immediate at the position the frozen `rt_simd` head expects.
///
/// - `SExtractLane(_, l)`/`SExtractLaneS`/`SExtractLaneU` — the head is `<shape>_extract_lane[_s|_u]
///   (a, lane)`; `args == [vec]`, so append `CInt(l)`: `[vec, l]`.
/// - `SReplaceLane(_, l)` — the head is `<shape>_replace_lane(a, lane, x)` (lane is the MIDDLE arg,
///   per the frozen rt_simd signature — NOT last as the stale unit doc §B.1 sketched); `args ==
///   [vec, x]`, so splice: `[vec, l, x]`.
/// - every other op — its operands only (`list.map(args, emit_value)`).
fn simd_call_args(op: ir.SimdOp, args: List(Value)) -> List(CExpr) {
  case op {
    ir.SExtractLane(_, lane)
    | ir.SExtractLaneS(_, lane)
    | ir.SExtractLaneU(_, lane) ->
      list.append(list.map(args, emit_value), [CInt(lane)])
    ir.SReplaceLane(_, lane) ->
      case args {
        [vec, x] -> [emit_value(vec), CInt(lane), emit_value(x)]
        // Validation guarantees replace-lane has exactly [vec, scalar]; any other shape is an
        // internal invariant, defaulted to the operands verbatim (never reached).
        _ -> list.map(args, emit_value)
      }
    _ -> list.map(args, emit_value)
  }
}

/// Lower `SimdShuffle(lanes, a, b)` (`i8x16.shuffle`) — PURE, state-neutral. The 16 immediate lane
/// indices (each 0..31, validated by P6-04) ride as a proper Core list AFTER the two v128 operands:
/// `call '<rt_simd>':'i8x16_shuffle'(A, B, [l0,…,l15])`. `rt_simd` selects byte `lanes[i]` from
/// `A ++ B` (spec `i8x16.shuffle`).
fn emit_simd_shuffle(
  lanes: List(Int),
  a: Value,
  b: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let call =
    seam_call(simd_module, "i8x16_shuffle", [
      emit_value(a),
      emit_value(b),
      core_list(list.map(lanes, CInt)),
    ])
  apply_cont(cont, [call], sc, state, ctx)
}

/// The `SimdOp → rt_simd` name table — the SIMD binding chokepoint (I2), the analogue of
/// `num_op_name`. Total; every constructor maps to the EXACT frozen `rt_simd` public head
/// (`<shape>_<op>` for shape-uniform ops, `v128_<op>` for the shape-agnostic bitwise/reductions, a
/// fully-spelled name for each conversion/widen/narrow). 07 bound its ~217 heads to precisely
/// these names; the names ARE the fixed-width-SIMD instruction mnemonics (spec §5.4.9 / the
/// `simd/*.wast` oracle), so a golden asserting them is spec-cited, not a change-detector.
///
/// Legality (which `(op, shape)` combos are valid) is enforced UPSTREAM by validate/lower; this map
/// names whatever constructor+shape it is handed (a nonsensical combo has no `rt_simd` head, exactly
/// as `num_op_name` names an out-of-range width).
pub fn simd_op_name(op: ir.SimdOp) -> String {
  case op {
    // ── lane-uniform integer arithmetic ──
    ir.SAdd(s) -> simd_shape_name(s) <> "_add"
    ir.SSub(s) -> simd_shape_name(s) <> "_sub"
    ir.SMul(s) -> simd_shape_name(s) <> "_mul"
    ir.SNeg(s) -> simd_shape_name(s) <> "_neg"
    ir.SAbs(s) -> simd_shape_name(s) <> "_abs"
    ir.SAddSatS(s) -> simd_shape_name(s) <> "_add_sat_s"
    ir.SAddSatU(s) -> simd_shape_name(s) <> "_add_sat_u"
    ir.SSubSatS(s) -> simd_shape_name(s) <> "_sub_sat_s"
    ir.SSubSatU(s) -> simd_shape_name(s) <> "_sub_sat_u"
    ir.SMinS(s) -> simd_shape_name(s) <> "_min_s"
    ir.SMinU(s) -> simd_shape_name(s) <> "_min_u"
    ir.SMaxS(s) -> simd_shape_name(s) <> "_max_s"
    ir.SMaxU(s) -> simd_shape_name(s) <> "_max_u"
    ir.SAvgrU(s) -> simd_shape_name(s) <> "_avgr_u"
    ir.SShl(s) -> simd_shape_name(s) <> "_shl"
    ir.SShrS(s) -> simd_shape_name(s) <> "_shr_s"
    ir.SShrU(s) -> simd_shape_name(s) <> "_shr_u"
    ir.SPopcnt(s) -> simd_shape_name(s) <> "_popcnt"
    // ── lane-uniform comparisons → v128 mask ──
    ir.SEq(s) -> simd_shape_name(s) <> "_eq"
    ir.SNe(s) -> simd_shape_name(s) <> "_ne"
    ir.SLtS(s) -> simd_shape_name(s) <> "_lt_s"
    ir.SLtU(s) -> simd_shape_name(s) <> "_lt_u"
    ir.SLeS(s) -> simd_shape_name(s) <> "_le_s"
    ir.SLeU(s) -> simd_shape_name(s) <> "_le_u"
    ir.SGtS(s) -> simd_shape_name(s) <> "_gt_s"
    ir.SGtU(s) -> simd_shape_name(s) <> "_gt_u"
    ir.SGeS(s) -> simd_shape_name(s) <> "_ge_s"
    ir.SGeU(s) -> simd_shape_name(s) <> "_ge_u"
    // ── v128 bitwise (shape-agnostic) ──
    ir.VNot -> "v128_not"
    ir.VAnd -> "v128_and"
    ir.VOr -> "v128_or"
    ir.VXor -> "v128_xor"
    ir.VAndNot -> "v128_andnot"
    ir.VBitselect -> "v128_bitselect"
    // ── boolean reductions / mask ──
    ir.VAnyTrue -> "v128_any_true"
    ir.SAllTrue(s) -> simd_shape_name(s) <> "_all_true"
    ir.SBitmask(s) -> simd_shape_name(s) <> "_bitmask"
    // ── lane access / build ──
    ir.SSplat(s) -> simd_shape_name(s) <> "_splat"
    ir.SExtractLane(s, _) -> simd_shape_name(s) <> "_extract_lane"
    ir.SExtractLaneS(s, _) -> simd_shape_name(s) <> "_extract_lane_s"
    ir.SExtractLaneU(s, _) -> simd_shape_name(s) <> "_extract_lane_u"
    ir.SReplaceLane(s, _) -> simd_shape_name(s) <> "_replace_lane"
    // ── float-lane ops (SF-prefixed constructors → the plain `<fshape>_<op>` head) ──
    ir.SFAdd(s) -> simd_shape_name(s) <> "_add"
    ir.SFSub(s) -> simd_shape_name(s) <> "_sub"
    ir.SFMul(s) -> simd_shape_name(s) <> "_mul"
    ir.SFDiv(s) -> simd_shape_name(s) <> "_div"
    ir.SFNeg(s) -> simd_shape_name(s) <> "_neg"
    ir.SFAbs(s) -> simd_shape_name(s) <> "_abs"
    ir.SFSqrt(s) -> simd_shape_name(s) <> "_sqrt"
    ir.SFMin(s) -> simd_shape_name(s) <> "_min"
    ir.SFMax(s) -> simd_shape_name(s) <> "_max"
    ir.SFPMin(s) -> simd_shape_name(s) <> "_pmin"
    ir.SFPMax(s) -> simd_shape_name(s) <> "_pmax"
    ir.SFCeil(s) -> simd_shape_name(s) <> "_ceil"
    ir.SFFloor(s) -> simd_shape_name(s) <> "_floor"
    ir.SFTrunc(s) -> simd_shape_name(s) <> "_trunc"
    ir.SFNearest(s) -> simd_shape_name(s) <> "_nearest"
    ir.SFEq(s) -> simd_shape_name(s) <> "_eq"
    ir.SFNe(s) -> simd_shape_name(s) <> "_ne"
    ir.SFLt(s) -> simd_shape_name(s) <> "_lt"
    ir.SFLe(s) -> simd_shape_name(s) <> "_le"
    ir.SFGt(s) -> simd_shape_name(s) <> "_gt"
    ir.SFGe(s) -> simd_shape_name(s) <> "_ge"
    // ── widen / narrow / extended-multiply / pairwise (parametric — S3) ──
    ir.SNarrow(from, signed) ->
      simd_narrow_shape_name(from)
      <> "_narrow_"
      <> simd_shape_name(from)
      <> "_"
      <> sign_suffix(signed)
    ir.SExtend(from, half, signed) ->
      simd_double_shape_name(from)
      <> "_extend_"
      <> simd_half_name(half)
      <> "_"
      <> simd_shape_name(from)
      <> "_"
      <> sign_suffix(signed)
    ir.SExtMul(from, half, signed) ->
      simd_double_shape_name(from)
      <> "_extmul_"
      <> simd_half_name(half)
      <> "_"
      <> simd_shape_name(from)
      <> "_"
      <> sign_suffix(signed)
    ir.SExtAddPairwise(from, signed) ->
      simd_double_shape_name(from)
      <> "_extadd_pairwise_"
      <> simd_shape_name(from)
      <> "_"
      <> sign_suffix(signed)
    // ── conversions (genuinely singular) ──
    ir.STruncSatF32x4S -> "i32x4_trunc_sat_f32x4_s"
    ir.STruncSatF32x4U -> "i32x4_trunc_sat_f32x4_u"
    ir.STruncSatF64x2SZero -> "i32x4_trunc_sat_f64x2_s_zero"
    ir.STruncSatF64x2UZero -> "i32x4_trunc_sat_f64x2_u_zero"
    ir.SConvertF32x4I32x4S -> "f32x4_convert_i32x4_s"
    ir.SConvertF32x4I32x4U -> "f32x4_convert_i32x4_u"
    ir.SConvertF64x2LowI32x4S -> "f64x2_convert_low_i32x4_s"
    ir.SConvertF64x2LowI32x4U -> "f64x2_convert_low_i32x4_u"
    ir.SDemoteF64x2Zero -> "f32x4_demote_f64x2_zero"
    ir.SPromoteLowF32x4 -> "f64x2_promote_low_f32x4"
    // ── dot / q15 / swizzle (singular) ──
    ir.SDotI16x8S -> "i32x4_dot_i16x8_s"
    ir.SQ15MulrSatS -> "i16x8_q15mulr_sat_s"
    ir.SSwizzle -> "i8x16_swizzle"
  }
}

/// The canonical lane-shape prefix for a `SimdShape` — the analogue of `iw`/`fw` for `NumOp`. Total.
fn simd_shape_name(s: ir.SimdShape) -> String {
  case s {
    ir.I8x16 -> "i8x16"
    ir.I16x8 -> "i16x8"
    ir.I32x4 -> "i32x4"
    ir.I64x2 -> "i64x2"
    ir.F32x4 -> "f32x4"
    ir.F64x2 -> "f64x2"
  }
}

/// The DOUBLE-width result shape name of a widening/extending source shape (extend/extmul/pairwise):
/// I8x16→i16x8, I16x8→i32x4, I32x4→i64x2. Float / i64x2 sources are documented-unreachable (validate
/// rejects them); defaulted for totality.
fn simd_double_shape_name(from: ir.SimdShape) -> String {
  case from {
    ir.I8x16 -> "i16x8"
    ir.I16x8 -> "i32x4"
    ir.I32x4 -> "i64x2"
    _ -> "i64x2"
  }
}

/// The HALF-width result shape name of a narrowing source shape: I16x8→i8x16, I32x4→i16x8. Other
/// sources are documented-unreachable (validate rejects them); defaulted for totality.
fn simd_narrow_shape_name(from: ir.SimdShape) -> String {
  case from {
    ir.I16x8 -> "i8x16"
    ir.I32x4 -> "i16x8"
    _ -> "i8x16"
  }
}

/// `"low"`/`"high"` for a `SimdHalf` (extend/extmul name component). Total.
fn simd_half_name(h: ir.SimdHalf) -> String {
  case h {
    ir.Low -> "low"
    ir.High -> "high"
  }
}

/// `"s"`/`"u"` — the signed/unsigned suffix of a parametric widen/narrow/extmul/pairwise head. Total.
fn sign_suffix(signed: Bool) -> String {
  case signed {
    True -> "s"
    False -> "u"
  }
}

// ─────────────────── SIMD memory (rt_mem bounds-check ∘ rt_simd assembly, §C/S4) ───────────────────

/// Lower a `SimdLoad(mem, kind, addr, offset)` — the S4 compose: the bounds check + byte move are
/// `rt_mem`'s (the trap owner, `MemoryOutOfBounds` before any partial read — H6), the pure lane
/// assembly is `rt_simd`'s. The trapping load is reduced to a bound value FIRST; the `rt_simd`
/// assembly runs ONLY on the `{ok, _}` path (unreachable if the load faults). Read-only w.r.t. the
/// record (`cur` unchanged under `Threaded`, like `MemLoad`).
///
/// - `LoadV128`  → `load_bytes(16)`; the 16 bytes ARE the v128 (identity assembly).
/// - `LoadSplat(w)` → scalar `rt_mem.load(w/8)` then `iNxM_splat` (the existing lane splat, S4).
/// - `LoadExtend(src, signed)` → `load_bytes(8)` then `rt_simd:v128_load_extend(_, src, signed)`.
/// - `LoadZero(w)` → `load_bytes(w/8)` then `rt_simd:v128_load_zero(_, w)`.
fn emit_simd_load(
  mem: Int,
  kind: ir.SimdLoadKind,
  addr: Value,
  offset: Int,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case kind {
    ir.LoadV128 -> {
      let call = simd_load_bytes_call(mem, addr, offset, 16, sc, ctx)
      emit_simd_trapping_value(call, fn(x) { x }, cont, sc, state, ctx)
    }
    ir.LoadSplat(bits) -> {
      let call =
        simd_scalar_load_call(
          mem,
          bits / 8,
          False,
          scalar_result_width(bits),
          addr,
          offset,
          sc,
          ctx,
        )
      emit_simd_trapping_value(
        call,
        fn(x) { seam_call(simd_module, simd_splat_head(bits), [x]) },
        cont,
        sc,
        state,
        ctx,
      )
    }
    ir.LoadExtend(source_bits, signed) -> {
      let call = simd_load_bytes_call(mem, addr, offset, 8, sc, ctx)
      emit_simd_trapping_value(
        call,
        fn(x) {
          seam_call(simd_module, "v128_load_extend", [
            x,
            CInt(source_bits),
            bool_atom(signed),
          ])
        },
        cont,
        sc,
        state,
        ctx,
      )
    }
    ir.LoadZero(bits) -> {
      let call = simd_load_bytes_call(mem, addr, offset, bits / 8, sc, ctx)
      emit_simd_trapping_value(
        call,
        fn(x) { seam_call(simd_module, "v128_load_zero", [x, CInt(bits)]) },
        cont,
        sc,
        state,
        ctx,
      )
    }
  }
}

/// Lower a `SimdStore(mem, addr, value, offset)` (`v128.store`) — the 16-byte `value` IS the run
/// `store_bytes` writes (no lane assembly). Trapping ZERO-effect: `Cell` reduces `{ok,_}`/`{error,E}`
/// to a discardable `'ok'`/`raise` and sequences (`emit_zero_effect`); `Threaded` rebinds `cur` to
/// the record `t_store_bytes` returns (`emit_threaded_record_effect`). Trap-before-write (H6), like
/// `MemStore`.
fn emit_simd_store(
  mem: Int,
  addr: Value,
  value: Value,
  offset: Int,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let call =
    simd_store_bytes_call(mem, addr, emit_value(value), offset, sc, ctx)
  case sc {
    NoState -> {
      let #(effect, state2) = trapping_effect(call, ctx, state)
      emit_zero_effect(effect, cont, sc, state2, ctx)
    }
    Threading(_) -> emit_threaded_record_effect(call, cont, state, ctx)
  }
}

/// Lower a `SimdLoadLane(mem, width, addr, offset, lane, vec)` (`v128.loadN_lane`) — scalar
/// `rt_mem.load(width/8)` (bounds-checked) then `rt_simd:v128_replace_lane_bits(vec, lane, width, _)`
/// writes the loaded bits into lane `lane` of `vec` (S4). Read-only; the replace runs only on the
/// `{ok,_}` path.
fn emit_simd_load_lane(
  mem: Int,
  width: Int,
  addr: Value,
  offset: Int,
  lane: Int,
  vec: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let call =
    simd_scalar_load_call(
      mem,
      width / 8,
      False,
      scalar_result_width(width),
      addr,
      offset,
      sc,
      ctx,
    )
  emit_simd_trapping_value(
    call,
    fn(x) {
      seam_call(simd_module, "v128_replace_lane_bits", [
        emit_value(vec),
        CInt(lane),
        CInt(width),
        x,
      ])
    },
    cont,
    sc,
    state,
    ctx,
  )
}

/// Lower a `SimdStoreLane(mem, width, addr, offset, lane, vec)` (`v128.storeN_lane`) — the PURE
/// `rt_simd:v128_extract_lane_bits(vec, lane, width)` runs FIRST (no memory touched), then the
/// trapping scalar `rt_mem.store(width/8)` writes it. Ordering the pure extract before the
/// bounds-checked store is sound (no observable effect precedes the trap — H6). Trapping ZERO-effect
/// (`Cell`: discard; `Threaded`: rebind `cur`), like `MemStore`.
fn emit_simd_store_lane(
  mem: Int,
  width: Int,
  addr: Value,
  offset: Int,
  lane: Int,
  vec: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let extracted =
    seam_call(simd_module, "v128_extract_lane_bits", [
      emit_value(vec),
      CInt(lane),
      CInt(width),
    ])
  let call =
    simd_scalar_store_call(mem, width / 8, addr, extracted, offset, sc, ctx)
  case sc {
    NoState -> {
      let #(effect, state2) = trapping_effect(call, ctx, state)
      emit_zero_effect(effect, cont, sc, state2, ctx)
    }
    Threading(_) -> emit_threaded_record_effect(call, cont, state, ctx)
  }
}

/// Reduce a trapping `Result(X, TrapReason)` SIMD-memory producer to its `{ok, X}` payload, then
/// feed `make_value(X)` (the pure `rt_simd` lane assembly, or identity for `v128.load`) to `cont`.
/// The `{error, E}` arm raises via `rt_trap` — so the assembly is on the `{ok,_}` path only (H6:
/// never reached if the load faults). Mirrors `emit_trapping_result`, but post-processes the bound
/// value before disposing it.
fn emit_simd_trapping_value(
  produced: CExpr,
  make_value: fn(CExpr) -> CExpr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(xvar, state2) = fresh_var(state)
  let #(evar, state3) = fresh_var(state2)
  let #(rvar, state4) = fresh_var(state3)
  let result_case =
    CCase(produced, [
      CClause([PTuple([PAtom("ok"), PVar(xvar)])], CAtom("true"), CVar(xvar)),
      CClause(
        [PTuple([PAtom("error"), PVar(evar)])],
        CAtom("true"),
        raise_trap(ctx, CVar(evar)),
      ),
    ])
  use #(rest, state5) <- result.try(apply_cont(
    cont,
    [make_value(CVar(rvar))],
    sc,
    state4,
    ctx,
  ))
  Ok(#(CLet([rvar], result_case, rest), state5))
}

/// The `rt_mem` v128-slice LOAD seam call (`Result(BitArray, _)`), routed by memory index +
/// state channel: index 0 → the un-indexed `load_bytes`/`t_load_bytes`; index ≥1 → the `_at` head
/// with a leading memidx. `n` is the byte count (16/8/4). memory64 is transparent — `addr` is the
/// raw bignum address, `offset` a bignum `CInt`; `rt_mem` reads the width from the handle (§D).
fn simd_load_bytes_call(
  mem: Int,
  addr: Value,
  offset: Int,
  n: Int,
  sc: StateChan,
  ctx: Ctx,
) -> CExpr {
  let tail = [emit_value(addr), CInt(offset), CInt(n)]
  case mem, sc {
    0, NoState -> seam_call(ctx.binding.mem_module, "load_bytes", tail)
    0, Threading(cur) ->
      seam_call(ctx.binding.mem_module, "t_load_bytes", [CVar(cur), ..tail])
    _, NoState ->
      seam_call(ctx.binding.mem_module, "load_bytes_at", [CInt(mem), ..tail])
    _, Threading(cur) ->
      seam_call(ctx.binding.mem_module, "t_load_bytes_at", [
        CVar(cur),
        CInt(mem),
        ..tail
      ])
  }
}

/// The `rt_mem` v128-slice STORE seam call (`Result(Nil, _)` cell / `Result(InstanceState, _)`
/// threaded) for a 16-byte `v128.store`. Arg order matches the frozen head: `store_bytes(Addr,
/// Bytes, Off)`. Index 0 → the un-indexed head; ≥1 → the `_at` head with a leading memidx.
fn simd_store_bytes_call(
  mem: Int,
  addr: Value,
  bytes: CExpr,
  offset: Int,
  sc: StateChan,
  ctx: Ctx,
) -> CExpr {
  let tail = [emit_value(addr), bytes, CInt(offset)]
  case mem, sc {
    0, NoState -> seam_call(ctx.binding.mem_module, "store_bytes", tail)
    0, Threading(cur) ->
      seam_call(ctx.binding.mem_module, "t_store_bytes", [CVar(cur), ..tail])
    _, NoState ->
      seam_call(ctx.binding.mem_module, "store_bytes_at", [CInt(mem), ..tail])
    _, Threading(cur) ->
      seam_call(ctx.binding.mem_module, "t_store_bytes_at", [
        CVar(cur),
        CInt(mem),
        ..tail
      ])
  }
}

/// The SCALAR `rt_mem` LOAD seam call (`Result(Int, _)`) for a `load{N}_splat`/`load{N}_lane` — the
/// existing numeric load head (`load(Bytes, Signed, W, Addr, Off)`), memidx/state routed. Splat and
/// load-lane load the raw bytes UNSIGNED; the lane assembly masks to the lane width.
fn simd_scalar_load_call(
  mem: Int,
  bytes: Int,
  signed: Bool,
  result_bits: Int,
  addr: Value,
  offset: Int,
  sc: StateChan,
  ctx: Ctx,
) -> CExpr {
  let tail = [
    CInt(bytes),
    bool_atom(signed),
    CInt(result_bits),
    emit_value(addr),
    CInt(offset),
  ]
  case mem, sc {
    0, NoState -> seam_call(ctx.binding.mem_module, "load", tail)
    0, Threading(cur) ->
      seam_call(ctx.binding.mem_module, "t_load", [CVar(cur), ..tail])
    _, NoState ->
      seam_call(ctx.binding.mem_module, "load_at", [CInt(mem), ..tail])
    _, Threading(cur) ->
      seam_call(ctx.binding.mem_module, "t_load_at", [
        CVar(cur),
        CInt(mem),
        ..tail
      ])
  }
}

/// The SCALAR `rt_mem` STORE seam call (`store(Bytes, Addr, Value, Off)`) for a `store{N}_lane` —
/// `value_expr` is the pure `v128_extract_lane_bits(vec, lane, width)` result, inlined as the store
/// value (evaluated before the store's bounds check — sound, the extract is pure). memidx/state
/// routed.
fn simd_scalar_store_call(
  mem: Int,
  bytes: Int,
  addr: Value,
  value_expr: CExpr,
  offset: Int,
  sc: StateChan,
  ctx: Ctx,
) -> CExpr {
  let tail = [CInt(bytes), emit_value(addr), value_expr, CInt(offset)]
  case mem, sc {
    0, NoState -> seam_call(ctx.binding.mem_module, "store", tail)
    0, Threading(cur) ->
      seam_call(ctx.binding.mem_module, "t_store", [CVar(cur), ..tail])
    _, NoState ->
      seam_call(ctx.binding.mem_module, "store_at", [CInt(mem), ..tail])
    _, Threading(cur) ->
      seam_call(ctx.binding.mem_module, "t_store_at", [
        CVar(cur),
        CInt(mem),
        ..tail
      ])
  }
}

/// The `iNxM_splat` head for a `load{N}_splat` scalar of `bits` (8→i8x16, 16→i16x8, 32→i32x4,
/// 64→i64x2). Total; defaulted for an out-of-range width (validate rejects it).
fn simd_splat_head(bits: Int) -> String {
  case bits {
    8 -> "i8x16_splat"
    16 -> "i16x8_splat"
    32 -> "i32x4_splat"
    _ -> "i64x2_splat"
  }
}

/// The scalar-load result width in bits for a splat/lane access of `bits`: 64 for a 64-bit lane,
/// else 32 (an i32-carried sub-word, matching the numeric `MemLoad` result-width convention).
fn scalar_result_width(bits: Int) -> Int {
  case bits {
    64 -> 64
    _ -> 32
  }
}

// ─────────────────────────────── calls ───────────────────────────────

/// Lower a `CallDirect` to `apply 'fn'/arity(args…)` against a same-module function
/// (a static local name — D3a-safe). `Error(UnknownFunction)` if the target is undefined.
///
/// Under `Threading(cur)` with a STATE-REACHING callee `g`, the record is threaded:
/// `apply 'g'/(n+1)(cur, args…)` yields `{Package, St'}`.
/// - `cont == KReturn` → emit the `apply` STRAIGHT THROUGH — `{Package, St'}` is already
///   exactly what the caller must return, so a tail `CallDirect` to a threaded callee stays a
///   TAIL CALL (cross-function tail recursion keeps constant stack, §B.3).
/// - otherwise → `case {Pkg, St'} -> …` destructures the pair, unpacks `Pkg` into `r` values,
///   and continues under `Threading(St')`.
/// A PURE callee is `apply 'g'/n(args…)` with `cur` flowing AROUND it unchanged (dispatched
/// by `apply_cont_call`, which under `Threading` re-pairs the result with `cur` at `KReturn`).
fn emit_call_direct(
  fn_name: String,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case dict.get(ctx.fn_arity, fn_name) {
    Error(_) -> Error(UnknownFunction(fn_name))
    Ok(arity) -> {
      let r = result.unwrap(dict.get(ctx.fn_results, fn_name), 1)
      let cargs = list.map(args, emit_value)
      let callee_threaded =
        is_threaded(ctx) && set.contains(ctx.fn_state_reaching, fn_name)
      case sc, callee_threaded {
        Threading(cur), True -> {
          let applied = CApply(FName(fn_name, arity + 1), [CVar(cur), ..cargs])
          case cont {
            KReturn -> Ok(#(applied, state))
            _ -> emit_threaded_call_unpack(applied, r, cont, state, ctx)
          }
        }
        _, _ ->
          apply_cont_call(
            cont,
            CApply(FName(fn_name, arity), cargs),
            r,
            sc,
            state,
            ctx,
          )
      }
    }
  }
}

/// Destructure a threaded callee's `{Package, St'}` at a NON-tail site: `case <applied> of
/// <{Pkg, St'}> -> <unpack Pkg into r values, continue under Threading(St')>`. Unpacking `Pkg`
/// reuses the same `r∈{0,1,≥2}` logic as a pure call (`apply_cont_call`).
fn emit_threaded_call_unpack(
  applied: CExpr,
  r: Int,
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(pkgvar, state2) = fresh_var(state)
  let #(stvar, state3) = fresh_var(state2)
  use #(rest, state4) <- result.try(apply_cont_call(
    cont,
    CVar(pkgvar),
    r,
    Threading(stvar),
    state3,
    ctx,
  ))
  Ok(#(
    CCase(applied, [
      CClause([PTuple([PVar(pkgvar), PVar(stvar)])], CAtom("true"), rest),
    ]),
    state4,
  ))
}

/// Lower a `CallHost` (the capability boundary, D9). THREE fates, all D3a-clean (the target
/// module + function are always build-controlled literal atoms, never derived from `capability`/
/// `name`/`args` data — no `apply(Mod,Fn,Args)`):
///
/// - the reserved JS-runtime capability `"js"` (Phase-8 unit 05, K6) → a DIRECT
///   `call '<js_runtime_module>':'<fn>'(args…)`, where `<fn>` is resolved from `name` by the
///   build-fixed literal `case` `resolve_js`. An `op` outside that set is FAIL-CLOSED here as
///   `UnknownJsOp` — no call is emitted, so a data-driven op cannot reach an arbitrary MFA.
/// - a resolved `own`-stdlib triple (`resolve_stdlib`) → a DIRECT
///   `call '<stdlib_module>':'<fn>'(args…)` (a vetted call does not pass through the host);
/// - otherwise (a genuine host import) → the deny-all
///   `call '<host_module>':'call_host'(Cap, Name, [args…])`, which under the Safe profile
///   fails closed.
///
/// SEAM (for unit 11's `ir_lower`, the allowlist enforcer): `resolve_stdlib`/`resolve_js` here
/// mirror the pinned stdlib / JS-runtime op mappings. `ir_lower` is the canonical place the
/// capability provenance is enforced (the stdlib `rt_bif` allowlist and the `"js"` admit); this
/// backend routing must stay aligned with it. `Cap`/`Name` for the host fate are emitted as
/// BINARY STRINGS — the exact type `rt_host.call_host` consumes, so its
/// `resolve_handler`/`HostWhitelist` string matching actually fires under a permissive
/// (`HostOpen`/`HostWhitelist`) posture (F4), and the deny-all `{capability_denied, Cap,
/// Name}` echoes them as binaries (consistent with a direct Gleam-side call). Emitting them
/// as atoms — faithful only for deny-all, which inspects nothing — would make an admitting
/// host silently deny every handler (an atom never matches the `String` patterns).
fn emit_call_host(
  capability: String,
  name: String,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let cargs = list.map(args, emit_value)
  case capability == js_capability {
    // The reserved JS runtime boundary (K6): a build-fixed literal dispatch to `rt_js`.
    True ->
      case resolve_js(name) {
        Some(fn_name) ->
          // A vetted `rt_js` op yields exactly ONE value (K6/Phase-1). State-neutral: the JS
          // runtime boundary never touches the instance record, so `cur` flows through unchanged.
          apply_cont_call(
            cont,
            CCall(CAtom(ctx.binding.js_runtime_module), CAtom(fn_name), cargs),
            1,
            sc,
            state,
            ctx,
          )
        // Fail-closed (D3a): an unrecognised op resolves to no function — the dispatch is a
        // literal `case`, not a data-driven target, so no `call`/`apply` is emitted.
        None -> Error(UnknownJsOp(name))
      }
    False ->
      case resolve_stdlib(capability, name) {
        Some(fn_name) ->
          // A vetted `own`-stdlib call yields a single value (Phase-1: `gcd/2`). State-neutral:
          // the host boundary never touches the record, so `cur` flows through unchanged (§G).
          apply_cont_call(
            cont,
            CCall(CAtom(ctx.binding.stdlib_module), CAtom(fn_name), cargs),
            1,
            sc,
            state,
            ctx,
          )
        None -> {
          // The host yields a single value or raises (`{capability_denied,…}`).
          // `capability`/`name` are emitted as BINARY STRINGS so `rt_host`'s handler/whitelist
          // matching (which pattern-matches Gleam `String`s) fires under a permissive posture,
          // not just deny-all.
          let call =
            CCall(CAtom(ctx.binding.host_module), CAtom("call_host"), [
              core_binary_string(capability),
              core_binary_string(name),
              core_list(cargs),
            ])
          apply_cont_call(cont, call, 1, sc, state, ctx)
        }
      }
  }
}

/// The reserved capability string that names the JS runtime boundary (Phase-8 unit 05, K6).
/// A `CallHost` whose capability equals this routes to the build-fixed `js_runtime_module`
/// (`rt_js`) via `resolve_js`; it is NEVER treated as a stdlib call or a host import. Pinned
/// with `ir_lower.js_capability` (the admit gate) and `specs/phase-8/05-js-runtime-boundary.md`.
const js_capability: String = "js"

/// The build-fixed JS-runtime op → `rt_js` function-name map (Phase-8 unit 05, K6). A LITERAL
/// `case` in THIS module (D3a): the only input is the static `op` string and the result is one
/// of a CLOSED set of compile-time-fixed function atoms — the target is NEVER constructed from
/// program/runtime data, so no `op` value can reach an arbitrary `Mod:Fn`. Each op returns
/// exactly one value (K6). This is the v1 surface of the REAL `rt_js` (HANDOFF §4): arithmetic
/// (`add`/`sub`/`mul` /2, `neg`/1, `div`/`mod` /2), comparisons (`lt`/`le`/`gt`/`ge`/
/// `strict_eq`/`eq` /2 → i32 1|0), coercion (`truthy`/`to_string`/`type_of` /1,
/// `undefined_sentinel`/0), cells (`cell_new`/`cell_get` /1, `cell_set`/2), objects
/// (`new_object`/0, `get_prop`/`has_prop` /2, `set_prop`/3), `empty_list`/0, `console_log`/1,
/// and `not_callable`/1. The op strings `"div"`/`"mod"` map to the function names
/// `divide`/`modulo` because `div` is an Erlang reserved word (the op spelling the frontend
/// emits is unchanged). `Some(fn_name)` for a known op, `None` (fail-closed → `UnknownJsOp`)
/// otherwise.
///
/// Extending the boundary with a new `rt_js` op is exactly: (1) add one literal arm here, (2)
/// implement the function in `runtime/rt_js.gleam`, (3) admit it in `ir_lower` (the `"js"`
/// capability is already admitted wholesale, so no `ir_lower` change is needed per-op).
fn resolve_js(op: String) -> Option(String) {
  case op {
    // arithmetic (sentinel-aware IEEE; see rt_js / twocore_rt_js_ffi)
    "add" -> Some("add")
    "sub" -> Some("sub")
    "mul" -> Some("mul")
    "neg" -> Some("neg")
    "div" -> Some("divide")
    "mod" -> Some("modulo")
    // comparisons → i32 1|0
    "lt" -> Some("lt")
    "le" -> Some("le")
    "gt" -> Some("gt")
    "ge" -> Some("ge")
    "strict_eq" -> Some("strict_eq")
    "eq" -> Some("eq")
    // bitwise / shift (int32 semantics)
    "bit_and" -> Some("bit_and")
    "bit_or" -> Some("bit_or")
    "bit_xor" -> Some("bit_xor")
    "bit_not" -> Some("bit_not")
    "shl" -> Some("shl")
    "shr" -> Some("shr")
    "ushr" -> Some("ushr")
    "pow" -> Some("pow")
    // Math
    "math_unary" -> Some("math_unary")
    "math_binary" -> Some("math_binary")
    "math_reduce" -> Some("math_reduce")
    "math_random" -> Some("math_random")
    // truthiness / coercion
    "truthy" -> Some("truthy")
    "to_number" -> Some("to_number")
    "to_string" -> Some("to_string")
    "type_of" -> Some("type_of")
    "undefined_sentinel" -> Some("undefined_sentinel")
    // cells (mutable captures + object storage)
    "cell_new" -> Some("cell_new")
    "cell_get" -> Some("cell_get")
    "cell_set" -> Some("cell_set")
    // objects
    "new_object" -> Some("new_object")
    "get_prop" -> Some("get_prop")
    "set_prop" -> Some("set_prop")
    "has_prop" -> Some("has_prop")
    // arrays
    "new_array" -> Some("new_array")
    "array_push" -> Some("array_push")
    "array_pop" -> Some("array_pop")
    "is_array" -> Some("is_array")
    "array_map" -> Some("array_map")
    "array_filter" -> Some("array_filter")
    "array_foreach" -> Some("array_foreach")
    "array_reduce" -> Some("array_reduce")
    "array_reduce1" -> Some("array_reduce1")
    "array_some" -> Some("array_some")
    "array_every" -> Some("array_every")
    "array_find" -> Some("array_find")
    "array_find_index" -> Some("array_find_index")
    "array_index_of" -> Some("array_index_of")
    "array_includes" -> Some("array_includes")
    "array_join" -> Some("array_join")
    "array_slice" -> Some("array_slice")
    "array_concat" -> Some("array_concat")
    "array_reverse" -> Some("array_reverse")
    "array_shift" -> Some("array_shift")
    "array_unshift" -> Some("array_unshift")
    "array_sort" -> Some("array_sort")
    // strings
    "str_char_at" -> Some("str_char_at")
    "str_char_code_at" -> Some("str_char_code_at")
    "str_upper" -> Some("str_upper")
    "str_lower" -> Some("str_lower")
    "str_substring" -> Some("str_substring")
    "str_split" -> Some("str_split")
    "str_trim" -> Some("str_trim")
    "str_trim_start" -> Some("str_trim_start")
    "str_trim_end" -> Some("str_trim_end")
    "str_repeat" -> Some("str_repeat")
    "str_starts_with" -> Some("str_starts_with")
    "str_ends_with" -> Some("str_ends_with")
    "str_replace" -> Some("str_replace")
    "str_replace_all" -> Some("str_replace_all")
    // globals + statics
    "parse_int" -> Some("parse_int")
    "parse_float" -> Some("parse_float")
    "is_nan" -> Some("is_nan")
    "is_finite" -> Some("is_finite")
    "is_nullish" -> Some("is_nullish")
    "number_is_nan" -> Some("number_is_nan")
    "number_is_finite" -> Some("number_is_finite")
    "number_is_integer" -> Some("number_is_integer")
    "object_keys" -> Some("object_keys")
    "object_values" -> Some("object_values")
    "object_entries" -> Some("object_entries")
    // lists / console / misc
    "empty_list" -> Some("empty_list")
    "console_log" -> Some("console_log")
    "not_callable" -> Some("not_callable")
    _ -> None
  }
}

/// The resolved `own`-stdlib lookup (the positive fate of `CallHost`). Returns the
/// `rt_stdlib` function name if `(capability, name)` is a vetted stdlib entry.
///
/// Phase-1 pins exactly one triple (state.md): `("std", "gcd")` → `rt_stdlib:gcd/2`.
/// Keep this aligned with unit 11's `ir_lower` + the `rt_bif` allowlist.
fn resolve_stdlib(capability: String, name: String) -> Option(String) {
  case capability, name {
    "std", "gcd" -> Some("gcd")
    _, _ -> None
  }
}

/// Lower a `CallIndirect` to the 3-fault, ambient-free dispatch (E3): a single seam call
/// `call '<table_module>':'call_indirect'(Idx, TypeTag, ArgList)` — the runtime type-check
/// and the three traps (bounds → null → type) live INSIDE `rt_table`, never here.
///
/// - `index`: the runtime table index — the ONLY program-derived value that reaches the
///   dispatch. The dispatched target is a build-controlled closure stored in the slot at
///   instantiation (never `apply(Mod, F, Args)` with `Mod`/`F` from data) — D3a.
/// - `ty`: the call-site's expected `FuncType`, emitted as a compile-time-canonical
///   `TypeTag` term via `func_type_term` (the SAME renderer the element-segment entry uses,
///   so `rt_table`'s structural `==` guard holds at run time).
/// - `args`: spread into a proper Core list `ArgList`.
///
/// The result is `Result(List(Int), TrapReason)`: `{ok,V}`/`{error,R}` → `case`-and-`raise`
/// (`emit_trapping_result`) binding the result LIST `V`, then the list is unpacked into
/// `len(ty.results)` values and disposed through `cont`.
///
/// `table` resolves to its absolute tableidx. Index 0 (the default table) emits the frozen
/// un-indexed `call_indirect`/`t_call_indirect` head (byte-identical to Phase-4, H7); a NON-zero
/// table (reference-types multi-table) emits the INDEXED `call_indirect_at(Idx, …)` /
/// `t_call_indirect_at(St, Idx, …)` head, which reads table `Idx` via `rt_state.table_at` and runs
/// the SAME 3-fault fail-closed dispatch. The result/trap handling below is identical for both.
fn emit_call_indirect(
  table: String,
  index: Value,
  ty: FuncType,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let idx = table_idx(ctx, table)
  let r = list.length(ty.results)
  case sc {
    NoState -> {
      // Index 0 → the byte-identical un-indexed head; ≥1 → the indexed head with a leading tableidx.
      let call = case idx {
        0 ->
          seam_call(ctx.binding.table_module, "call_indirect", [
            emit_value(index),
            func_type_term(ty),
            core_list(list.map(args, emit_value)),
          ])
        _ ->
          seam_call(ctx.binding.table_module, "call_indirect_at", [
            CInt(idx),
            emit_value(index),
            func_type_term(ty),
            core_list(list.map(args, emit_value)),
          ])
      }
      // Bind one var to the unwrapped result LIST (or raise on `{error,R}`), then unpack it.
      let #(xvar, state2) = fresh_var(state)
      let #(evar, state3) = fresh_var(state2)
      let #(lvar, state4) = fresh_var(state3)
      let result_case =
        CCase(call, [
          CClause(
            [PTuple([PAtom("ok"), PVar(xvar)])],
            CAtom("true"),
            CVar(xvar),
          ),
          CClause(
            [PTuple([PAtom("error"), PVar(evar)])],
            CAtom("true"),
            raise_trap(ctx, CVar(evar)),
          ),
        ])
      use #(rest, state5) <- result.try(unpack_result_list(
        lvar,
        r,
        cont,
        sc,
        state4,
        ctx,
      ))
      Ok(#(CLet([lvar], result_case, rest), state5))
    }
    Threading(cur) -> {
      // `{Rs, St2} = case '<table>':'t_call_indirect'(St, Idx, TypeTag, Args) of
      //   {ok,P} -> P; {error,R} -> raise end` — unpack `Rs` to `len(ty.results)` values,
      // REBIND `cur := St2`. `t_call_indirect` returns `#(List(Int), InstanceState)`. Index 0 →
      // the byte-identical un-indexed head; ≥1 → the indexed `t_call_indirect_at` (leading tableidx).
      let call = case idx {
        0 ->
          seam_call(ctx.binding.table_module, "t_call_indirect", [
            CVar(cur),
            emit_value(index),
            func_type_term(ty),
            core_list(list.map(args, emit_value)),
          ])
        _ ->
          seam_call(ctx.binding.table_module, "t_call_indirect_at", [
            CVar(cur),
            CInt(idx),
            emit_value(index),
            func_type_term(ty),
            core_list(list.map(args, emit_value)),
          ])
      }
      let #(pvar, state2) = fresh_var(state)
      let #(evar, state3) = fresh_var(state2)
      let #(pbound, state4) = fresh_var(state3)
      let result_case =
        CCase(call, [
          CClause(
            [PTuple([PAtom("ok"), PVar(pvar)])],
            CAtom("true"),
            CVar(pvar),
          ),
          CClause(
            [PTuple([PAtom("error"), PVar(evar)])],
            CAtom("true"),
            raise_trap(ctx, CVar(evar)),
          ),
        ])
      // Destructure `pbound = {Rs, St2}`, then unpack `Rs` under `Threading(St2)`.
      let #(rsvar, state5) = fresh_var(state4)
      let #(stvar, state6) = fresh_var(state5)
      use #(rest, state7) <- result.try(unpack_result_list(
        rsvar,
        r,
        cont,
        Threading(stvar),
        state6,
        ctx,
      ))
      let destructure =
        CCase(CVar(pbound), [
          CClause([PTuple([PVar(rsvar), PVar(stvar)])], CAtom("true"), rest),
        ])
      Ok(#(CLet([pbound], result_case, destructure), state7))
    }
  }
}

/// Unpack the result LIST bound to `lvar` (length `r`, the callee's result count) into `r`
/// Core values and dispose them through `cont`. `r == 0` disposes zero values (the list is
/// `[]`, discarded); otherwise a `case lvar of <[V1,…,Vr]> -> …` destructures the list and
/// continues with the elements.
fn unpack_result_list(
  lvar: String,
  r: Int,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case r {
    0 -> apply_cont(cont, [], sc, state, ctx)
    _ -> {
      let #(names, state2) = fresh_n_vars(state, r)
      use #(rest, state3) <- result.try(apply_cont(
        cont,
        list.map(names, CVar),
        sc,
        state2,
        ctx,
      ))
      let clause = CClause([list_pattern(names)], CAtom("true"), rest)
      Ok(#(CCase(CVar(lvar), [clause]), state3))
    }
  }
}

/// Lower `CallImport(slot, ty, args)` — a call to an IMPORTED function over the linker-built closure
/// capability (I5/S5/D3a). Read the closure from the instance's positional func-import `slot`
/// (`rt_state:func_import_at(slot)` / `t_func_import_at(St, slot)`), then dispatch it through the
/// frozen `link.call_import(closure, ArgsList)` seam — a plain 1-ary application of a HANDED-IN
/// closure VALUE, returning the callee's result value LIST. This is NEVER `erlang:apply(Mod, Fun,
/// Args)` of a data-named `module:atom`, and NEVER the 2-arg `erlang:apply(Closure, ArgsList)` that
/// would SPREAD the list into an N-ary fun's params (the arity bug S5 fixes) — the closure is a
/// capability supplied at link time, exactly like `externref`/`call_host` (D3a).
///
/// State-reaching (it READS the closure from `func_imports`), but record-READ-ONLY: reading the
/// closure does not mutate our record, and the callee threads its OWN state inside the closure — so
/// `cur` is UNCHANGED under `Threaded`. The returned value list is unpacked to `len(ty.results)`
/// values (`unpack_result_list`, the same machinery `CallIndirect` uses) and disposed through
/// `cont`. A callee trap PROPAGATES by the closure raising (`call_import` neither catches nor
/// synthesizes).
fn emit_call_import(
  slot: Int,
  ty: FuncType,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let r = list.length(ty.results)
  let closure = case sc {
    NoState ->
      seam_call(ctx.binding.state_module, "func_import_at", [CInt(slot)])
    Threading(cur) ->
      seam_call(ctx.binding.state_module, "t_func_import_at", [
        CVar(cur),
        CInt(slot),
      ])
  }
  let #(cvar, state2) = fresh_var(state)
  let applied =
    seam_call(link_module, "call_import", [
      CVar(cvar),
      core_list(list.map(args, emit_value)),
    ])
  let #(lvar, state3) = fresh_var(state2)
  use #(rest, state4) <- result.try(unpack_result_list(
    lvar,
    r,
    cont,
    sc,
    state3,
    ctx,
  ))
  Ok(#(CLet([cvar], closure, CLet([lvar], applied, rest)), state4))
}

// ─────────────────────────── Phase-13 tail calls (§Q1/Q5) ───────────────────────────
// GENUINE BEAM TAIL CALLS in constant stack space (Q13-05). Each forces `cont = KReturn` internally
// — a tail call is a bottom transfer to the FUNCTION's result, so the enclosing `cont` is DISCARDED
// (like `Return`/`Trap`/`Break`). The direct case reuses the existing direct-call tail path; the
// indirect case emits the `rt_table.call_indirect_lookup` seam then tail-applies the package-ABI
// target in the ok-arm; the imported case reuses the existing import path under `KReturn`
// (value-correct with a bounded caller frame — Q8 honest-scope sub-case, no `link` change). The loop
// tail-`apply` back-edge (`emit_loop`/`emit_continue`) is orthogonal and UNTOUCHED (invariant §8).

/// Emit `ir.ReturnCall(fn_name, args)` — a DIRECT tail call. A `CallDirect` under `KReturn` is
/// ALREADY a genuine BEAM tail call (`emit_call_direct`), so a tail call is exactly "the direct-call
/// logic with `cont` forced to `KReturn`". The incoming enclosing `cont` is DISCARDED (a bottom
/// transfer returns to the FUNCTION, not the block). Reachable shapes:
/// - `NoState` + `KReturn` → the fast path yields a bare `apply 'f'/n(Args)` — a real tail call,
///   constant stack (the direct self-`return_call` constant-stack proof, Q1).
/// - `Threading(cur)` to a STATE-REACHING callee → a bare `apply 'f'/(n+1)(cur, Args)` returning
///   `{Package, St'}` — the threaded return shape, constant stack.
/// - `Threading(cur)` to a PURE callee → the pure result re-paired with the unchanged `cur`
///   (bounded; a pure callee cannot tail-recurse back through a state-reaching frame).
/// `Error(UnknownFunction)` if `fn_name` is undefined (only reachable on an unvalidated module).
fn emit_return_call(
  fn_name: String,
  args: List(Value),
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  emit_call_direct(fn_name, args, KReturn, sc, state, ctx)
}

/// Emit `ir.ReturnCallIndirect(table, index, ty, args)` — an INDIRECT tail call. Emits the
/// `rt_table.call_indirect_lookup` seam (the 3-fault fail-closed dispatch that RETURNS the
/// PACKAGE-ABI target instead of applying it) as the WHOLE `case` expression, then APPLIES the
/// target in the ok-arm's TAIL position — a real BEAM tail call in constant stack (Q1). Because the
/// target is package-ABI, its tail-application yields the caller's `function_return` package
/// DIRECTLY (no `let`, no `unpack_result_list`, no re-wrap). The error-arm re-raises the seam's
/// `TrapReason` verbatim (the same three traps, same order, as `call_indirect`, D3a-clean — only the
/// integer `index` is program-derived). Index 0 emits the un-indexed `call_indirect_lookup` head
/// (byte-identity, H7); index ≥ 1 the `_at` head. Under `Threading(cur)` the `t_`-prefixed twins
/// thread the read-only `cur` into BOTH the lookup and the target apply (no rebind). Discards the
/// enclosing `cont`. Two fresh vars only (`T`, `E`).
fn emit_return_call_indirect(
  table: String,
  index: Value,
  ty: FuncType,
  args: List(Value),
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let idx = table_idx(ctx, table)
  let tag = func_type_term(ty)
  let cargs = core_list(list.map(args, emit_value))
  let #(tvar, state2) = fresh_var(state)
  let #(evar, state3) = fresh_var(state2)
  // Select the head + tail-apply per state channel. Under `Threading` the read-only `cur` flows
  // into both the lookup and the 2-ary target apply (which returns `{Package, St'}`).
  let #(lookup, tail_apply) = case sc {
    NoState -> {
      let lookup = case idx {
        0 ->
          seam_call(ctx.binding.table_module, "call_indirect_lookup", [
            emit_value(index),
            tag,
          ])
        _ ->
          seam_call(ctx.binding.table_module, "call_indirect_lookup_at", [
            CInt(idx),
            emit_value(index),
            tag,
          ])
      }
      #(lookup, CApplyExpr(CVar(tvar), [cargs]))
    }
    Threading(cur) -> {
      let lookup = case idx {
        0 ->
          seam_call(ctx.binding.table_module, "t_call_indirect_lookup", [
            CVar(cur),
            emit_value(index),
            tag,
          ])
        _ ->
          seam_call(ctx.binding.table_module, "t_call_indirect_lookup_at", [
            CVar(cur),
            CInt(idx),
            emit_value(index),
            tag,
          ])
      }
      #(lookup, CApplyExpr(CVar(tvar), [CVar(cur), cargs]))
    }
  }
  // The `case`-over-lookup IS the whole expression (no outer `let`), so the ok-arm `apply` is in
  // genuine tail position; the error-arm re-raises the seam's `TrapReason`.
  let result_case =
    CCase(lookup, [
      CClause([PTuple([PAtom("ok"), PVar(tvar)])], CAtom("true"), tail_apply),
      CClause(
        [PTuple([PAtom("error"), PVar(evar)])],
        CAtom("true"),
        raise_trap(ctx, CVar(evar)),
      ),
    ])
  Ok(#(result_case, state3))
}

/// Emit `ir.ReturnCallRef(funcref, args)` — a tail call through a typed function
/// reference. The `rt_gc` `apply_ref` seam null-checks the funcref then tail-applies
/// its build-strategy closure, and this seam call is itself the whole (tail) result
/// expression — so the tail-recursion is constant-stack across both hops. NoState:
/// `apply_ref` returns the callee package; Threaded: `t_apply_ref` returns
/// `{package, st'}`, exactly this function's threaded return shape.
fn emit_return_call_ref(
  funcref: Value,
  args: List(Value),
  sc: StateChan,
  state: EmitState,
  _ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let cargs = core_list(list.map(args, emit_value))
  let call = case sc {
    NoState -> seam_call(gc_module, "apply_ref", [emit_value(funcref), cargs])
    Threading(cur) ->
      seam_call(gc_module, "t_apply_ref", [
        CVar(cur),
        emit_value(funcref),
        cargs,
      ])
  }
  Ok(#(call, state))
}

/// Emit `ir.ReturnCallImport(slot, ty, args)` — an IMPORTED tail call. Routes through the EXISTING
/// import-call logic (`emit_call_import`) under a forced `KReturn` — NO `link` change, NO
/// `call_import` tail variant (overview §2 ⚠ ABI reconciliation note). `link.call_import` returns a
/// value LIST, so `emit_call_import` re-packages it into the caller's `function_return` package
/// under `KReturn` — value-correct, D3a (a 1-ary apply of a handed-in capability, never an ambient
/// `apply` of a data-named atom). This introduces a BOUNDED caller frame (an import callee is a
/// separate BEAM process; it cannot tail-recurse back through it): the imported case is
/// value-correct but NOT a constant-stack claim (Q8 honest-scope sub-case). Discards the enclosing
/// `cont` (the forced `KReturn` supersedes it), for both `NoState` and `Threading(cur)`.
fn emit_return_call_import(
  slot: Int,
  ty: FuncType,
  args: List(Value),
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  emit_call_import(slot, ty, args, KReturn, sc, state, ctx)
}

// ─────────────────────────── Phase-5 reference layer (§B) ───────────────────────────

/// Lower `RefFunc($name)` (§B). PURE (state-neutral): produce the `{TypeTag, Closure}` funcref
/// value and dispose it through `cont`; under `Threading(cur)`, `cur` flows through unchanged.
fn emit_ref_func(
  name: String,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use #(entry, state2) <- result.try(reference_func_entry(name, ctx, state))
  apply_cont(cont, [entry], sc, state2, ctx)
}

/// Build the `{TypeTag, Closure}` funcref value for `ref.func $name` — the SAME renderer the
/// active element segment uses (`element_entry` / `threaded_element_entry`), so a `ref.func`
/// stored into a table then `call_indirect`-ed is byte-identical to a segment-placed entry (§B).
/// The closure ABI follows the BUILD strategy (`is_threaded`), NOT `sc`: a `Cell` build makes
/// the cell closure `fun(Args) -> Results`, a `Threaded` build the threaded closure
/// `fun(St, Args) -> {Results, St'}` — because a funcref is consumed by `call_indirect` /
/// `t_call_indirect` uniformly across the whole build (a `Cell`-ABI closure invoked by
/// `t_call_indirect` would arity-mismatch). `Error(UnknownFunction)` if `name` is undefined.
fn reference_func_entry(
  name: String,
  ctx: Ctx,
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  case is_threaded(ctx) {
    True -> threaded_element_entry(name, ctx, state)
    False -> element_entry(name, ctx, state)
  }
}

/// Lower `ir.RefFuncImport(slot, ty)` — a `ref.func` of an IMPORTED function (Phase-14, R1/R2).
/// A PURE, state-neutral funcref CONSTRUCTION (a sibling of `emit_ref_func`): it builds the
/// `#(FuncType, adapter)` value and disposes it through `cont`, reading NOTHING from state at
/// build time (the `func_import_at(slot)` read is deferred into the adapter body — see
/// `imported_reference_func_entry`). Under `Threading(cur)`, `cur` flows through UNCHANGED
/// (`apply_cont` threads it), exactly like `emit_ref_func`. `slot` is the func-import index
/// (funcidx `0..imported-1`); `ty` is the import's declared `FuncType`. Never errors — there is
/// no `ctx.fn_sig` lookup to miss (that miss was the removed `UnknownFunction` residual).
fn emit_ref_func_import(
  slot: Int,
  ty: FuncType,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use #(entry, state2) <- result.try(imported_reference_func_entry(
    slot,
    ty,
    ctx,
    state,
  ))
  apply_cont(cont, [entry], sc, state2, ctx)
}

/// Build the `#(TypeTag, adapter)` funcref value for an IMPORTED `ref.func` (Phase-14, R2/D3a) —
/// the sibling of `reference_func_entry` for imports. The stored value is the UNCHANGED funcref
/// shape `#(FuncType, closure)`, so `rt_table`'s guard-3 structural `entry_type == expected_type`
/// matches an import-routed slot exactly as it matches a defined-funcref slot (`func_type_term`
/// is the SAME renderer the `call_indirect` site uses). Like `reference_func_entry`, it branches
/// on the BUILD strategy `is_threaded(ctx)` (NOT `sc`): a funcref is consumed uniformly by
/// `call_indirect` / `t_call_indirect` across the whole build, so the adapter ABI must match the
/// BUILD, not the local state channel.
///
/// The adapter is emitted INLINE in Core Erlang (no `link` helper — F3), capturing only the
/// LITERAL integer `slot` (D3a: the only program-derived operand is a `CInt`; dispatch is
/// `link:call_import(func_import_at(slot), Args)`, never `erlang:apply` of program data). It
/// dispatches through the frozen func-import capability seam, then re-packages `call_import`'s
/// result LIST into the funcref-slot's `function_return` PACKAGE (bare value for one result, the
/// N-tuple for N≥2, `'ok'` for zero) — the SAME package-ABI a DEFINED `element_closure` returns,
/// which `rt_table.call_indirect` inverts via `package_to_list`. (This is why the value is
/// re-shaped and not passed straight through: the Phase-13 funcref-slot ABI is package-ABI, so a
/// raw list would double-wrap a single result / mis-shape a multi-value one.)
///
/// Returns `Result` for signature uniformity with its siblings, but NEVER errors (there is no
/// `ctx.fn_sig` lookup to miss). Advances `state` past the closure's fresh binder names.
fn imported_reference_func_entry(
  slot: Int,
  ty: FuncType,
  ctx: Ctx,
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(closure, state2) = case is_threaded(ctx) {
    True -> imported_funcref_threaded_closure(slot, ty, ctx, state)
    False -> imported_funcref_cell_closure(slot, ty, ctx, state)
  }
  Ok(#(CTuple([func_type_term(ty), closure]), state2))
}

/// The CELL import adapter (build `is_threaded == False`; funcref-slot ABI `fun(Args) -> Package`):
///
/// ```
/// fun(Args) -> case link:call_import(rt_state:func_import_at(Slot), Args) of
///                <[V1,…,Vr]> when 'true' -> <Package(V1,…,Vr)> end
/// ```
///
/// `Args` is the raw-bit argument `List` handed in by `rt_table.call_indirect`; the func-import
/// slot's closure is read at DISPATCH time (`func_import_at(Slot)`), dispatched via the 1-ary
/// `link:call_import` (never `apply/3`, D3a), and its result LIST re-packaged into the
/// `function_return` package the slot ABI expects (`function_return` — bare value / N-tuple /
/// `'ok'`). The only program-derived operand is the literal `CInt(slot)`.
fn imported_funcref_cell_closure(
  slot: Int,
  ty: FuncType,
  ctx: Ctx,
  state: EmitState,
) -> #(CExpr, EmitState) {
  let #(argsvar, state1) = fresh_var(state)
  let #(resnames, state2) = fresh_n_vars(state1, list.length(ty.results))
  let call =
    seam_call(link_module, "call_import", [
      seam_call(ctx.binding.state_module, "func_import_at", [CInt(slot)]),
      CVar(argsvar),
    ])
  let body =
    CCase(call, [
      CClause(
        [list_pattern(resnames)],
        CAtom("true"),
        function_return(list.map(resnames, CVar)),
      ),
    ])
  #(CFun([argsvar], body), state2)
}

/// The THREADED import adapter (build `is_threaded == True`; funcref-slot ABI
/// `fun(St, Args) -> {Package, St'}`):
///
/// ```
/// fun(St, Args) -> case link:call_import(rt_state:t_func_import_at(St, Slot), Args) of
///                    <[V1,…,Vr]> when 'true' -> {<Package(V1,…,Vr)>, St} end
/// ```
///
/// `St` (the dispatch-time instance state handed in by `t_call_indirect`) is threaded through
/// UNCHANGED — the imported callee threads its OWN state INSIDE the linker-built routing closure,
/// exactly as `emit_call_import` does under `Threading` (`cur` unchanged). The `St` used to read
/// the slot is the closure's PARAMETER (dispatch-time), never the build-time `cur`, so building
/// the funcref stays pure. The result LIST is re-packaged into the `function_return` package the
/// threaded slot ABI expects (paired with the threaded-through `St`).
fn imported_funcref_threaded_closure(
  slot: Int,
  ty: FuncType,
  ctx: Ctx,
  state: EmitState,
) -> #(CExpr, EmitState) {
  let #(stvar, state1) = fresh_var(state)
  let #(argsvar, state2) = fresh_var(state1)
  let #(resnames, state3) = fresh_n_vars(state2, list.length(ty.results))
  let call =
    seam_call(link_module, "call_import", [
      seam_call(ctx.binding.state_module, "t_func_import_at", [
        CVar(stvar),
        CInt(slot),
      ]),
      CVar(argsvar),
    ])
  let body =
    CCase(call, [
      CClause(
        [list_pattern(resnames)],
        CAtom("true"),
        CTuple([function_return(list.map(resnames, CVar)), CVar(stvar)]),
      ),
    ])
  #(CFun([stvar, argsvar], body), state3)
}

/// Lower `RefIsNull(arg)` (§B): delegate the sentinel test to the runtime
/// (`call '<rt_ref>':'is_null'(Arg)` → a Core `'true'`/`'false'`) and map it to the i32
/// `1`/`0` the spec requires (`ref.is_null` yields an i32). Keeping the comparison inside
/// `rt_ref` preserves `externref` opacity (emit never pattern-matches a host term) and keeps
/// the sentinel shape runtime-owned. PURE / state-neutral. Cite spec §4.4.2.
fn emit_ref_is_null(
  arg: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let call = seam_call(ref_module, "is_null", [emit_value(arg)])
  let #(wild, state2) = fresh_var(state)
  let i32 =
    CCase(call, [
      CClause([PAtom("true")], CAtom("true"), CInt(1)),
      CClause([PVar(wild)], CAtom("true"), CInt(0)),
    ])
  apply_cont(cont, [i32], sc, state2, ctx)
}

// ─────────────────────────── Phase-5 table layer (§C) ───────────────────────────
//
// Each op resolves `table` name → its absolute tableidx (`table_idx`, §E.2) and routes through
// the `binding.table_module` seam against the FROZEN idx-based rt_table heads (`get(idx,index)`,
// `set(idx,index,v)`, `size(idx)`, `grow(idx,delta,init)`, `fill(idx,off,v,n)`,
// `table_init(idx,items,dst,src,n)`, `table_copy(dst_idx,src_idx,dst,src,n)` + the `t_*` twins).
// The dispositions REUSE the verified Phase-2/4 shapes (§G). All held to the finalized WASM 2.0
// semantics — the traps live inside rt_table (07); emit only routes.

/// `table.get` — trapping value, read-only (`Result(ref, TableOutOfBounds)`). Cell:
/// `get(Idx, Index)`; threaded: `t_get(St, Idx, Index)` (read `St`, `cur` unchanged, like
/// `MemLoad`). Cite §4.4.6 (an in-bounds unfilled slot reads the null sentinel — a value, not a
/// trap; an OOB index traps `TableOutOfBounds`).
fn emit_table_get(
  table: String,
  index: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let idx = table_idx(ctx, table)
  let call = case sc {
    NoState ->
      seam_call(ctx.binding.table_module, "get", [CInt(idx), emit_value(index)])
    Threading(cur) ->
      seam_call(ctx.binding.table_module, "t_get", [
        CVar(cur),
        CInt(idx),
        emit_value(index),
      ])
  }
  emit_trapping_result(call, cont, sc, state, ctx)
}

/// `table.set` — trapping ZERO-RESULT write (`Result(_, TableOutOfBounds)`, eager). Cell:
/// `set(Idx, Index, V)` reduced to a discardable effect; threaded: `t_set(St, Idx, Index, V)`
/// REBINDS `cur` (like `MemStore`). Cite §4.4.6.
fn emit_table_set(
  table: String,
  index: Value,
  value: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let idx = table_idx(ctx, table)
  case sc {
    NoState -> {
      let call =
        seam_call(ctx.binding.table_module, "set", [
          CInt(idx),
          emit_value(index),
          emit_value(value),
        ])
      let #(effect, state2) = trapping_effect(call, ctx, state)
      emit_zero_effect(effect, cont, sc, state2, ctx)
    }
    Threading(cur) -> {
      let call =
        seam_call(ctx.binding.table_module, "t_set", [
          CVar(cur),
          CInt(idx),
          emit_value(index),
          emit_value(value),
        ])
      emit_threaded_record_effect(call, cont, state, ctx)
    }
  }
}

/// `table.size` — bare i32, never traps. Cell: `size(Idx)`; threaded: `t_size(St, Idx)`
/// (read-only). Cite §4.4.6.
fn emit_table_size(
  table: String,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let idx = table_idx(ctx, table)
  let call = case sc {
    NoState -> seam_call(ctx.binding.table_module, "size", [CInt(idx)])
    Threading(cur) ->
      seam_call(ctx.binding.table_module, "t_size", [CVar(cur), CInt(idx)])
  }
  apply_cont(cont, [call], sc, state, ctx)
}

/// `table.grow(delta, init)` — the PREVIOUS size or `-1`; NEVER traps (like `memory.grow`).
/// Cell: bare `grow(Idx, Delta, Init)`; threaded: `t_grow(St, Idx, Delta, Init)` returns
/// `#(i32, St)` → `emit_value_state_pair` rebinds `cur`. Cite §4.4.6 (grow returns `-1` on
/// failure, never traps).
fn emit_table_grow(
  table: String,
  delta: Value,
  init: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let idx = table_idx(ctx, table)
  case sc {
    NoState ->
      apply_cont(
        cont,
        [
          seam_call(ctx.binding.table_module, "grow", [
            CInt(idx),
            emit_value(delta),
            emit_value(init),
          ]),
        ],
        sc,
        state,
        ctx,
      )
    Threading(cur) -> {
      let call =
        seam_call(ctx.binding.table_module, "t_grow", [
          CVar(cur),
          CInt(idx),
          emit_value(delta),
          emit_value(init),
        ])
      emit_value_state_pair(call, cont, state, ctx)
    }
  }
}

/// `table.fill(offset, value, count)` — EAGER trapping ZERO-RESULT write (bounds-checked before
/// any write, no partial effect, R10). Cell: `fill(Idx, O, V, N)`; threaded: `t_fill(St, Idx, O,
/// V, N)` rebinds `cur`. Cite §4.4.6.
fn emit_table_fill(
  table: String,
  offset: Value,
  value: Value,
  count: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let idx = table_idx(ctx, table)
  case sc {
    NoState -> {
      let call =
        seam_call(ctx.binding.table_module, "fill", [
          CInt(idx),
          emit_value(offset),
          emit_value(value),
          emit_value(count),
        ])
      let #(effect, state2) = trapping_effect(call, ctx, state)
      emit_zero_effect(effect, cont, sc, state2, ctx)
    }
    Threading(cur) -> {
      let call =
        seam_call(ctx.binding.table_module, "t_fill", [
          CVar(cur),
          CInt(idx),
          emit_value(offset),
          emit_value(value),
          emit_value(count),
        ])
      emit_threaded_record_effect(call, cont, state, ctx)
    }
  }
}

/// `table.init(seg, dst, src, count)` — copy references from passive element segment `seg` into
/// `table` (EAGER trapping, R10). The segment payload is emit-supplied, drop-GATED (R2): emit
/// `case rt_state:elem_dropped(Seg) of 'true' -> []; _ -> <items> end` so a dropped segment
/// behaves as length-0 (a later `init` with `count > 0` traps on the source bound). Cell:
/// `table_init(Idx, Items, D, S, N)`; threaded: `t_table_init(St, Idx, Items, D, S, N)`. Cite
/// §4.4.6 + §4.4.9.
fn emit_table_init(
  table: String,
  seg: Int,
  dst: Value,
  src: Value,
  count: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let idx = table_idx(ctx, table)
  use segment <- result.try(
    nth(ctx.elements, seg)
    |> result.replace_error(UnsupportedNode("table_init_seg")),
  )
  // A `global.get` init item resolves against the live state at THIS `table.init` site: the
  // threaded record `cur` under `Threading`, the pdict cell (None) under `Cell`.
  let items_state_ref = case sc {
    NoState -> None
    Threading(cur) -> Some(cur)
  }
  use #(entries, state2) <- result.try(render_ref_items(
    segment.init,
    ctx,
    items_state_ref,
    state,
  ))
  let #(gated, state3) =
    drop_gate(seg, "elem_dropped", CNil, core_list(entries), sc, state2, ctx)
  let #(segvar, state4) = fresh_var(state3)
  case sc {
    NoState -> {
      let call =
        seam_call(ctx.binding.table_module, "table_init", [
          CInt(idx),
          CVar(segvar),
          emit_value(dst),
          emit_value(src),
          emit_value(count),
        ])
      let #(effect, state5) = trapping_effect(call, ctx, state4)
      use #(rest, state6) <- result.try(emit_zero_effect(
        effect,
        cont,
        sc,
        state5,
        ctx,
      ))
      Ok(#(CLet([segvar], gated, rest), state6))
    }
    Threading(cur) -> {
      let call =
        seam_call(ctx.binding.table_module, "t_table_init", [
          CVar(cur),
          CInt(idx),
          CVar(segvar),
          emit_value(dst),
          emit_value(src),
          emit_value(count),
        ])
      use #(rest, state5) <- result.try(emit_threaded_record_effect(
        call,
        cont,
        state4,
        ctx,
      ))
      Ok(#(CLet([segvar], gated, rest), state5))
    }
  }
}

/// `table.copy(dst, src, count)` from `src_table` to `dst_table` — memmove-correct, EAGER
/// trapping (R10/R11). Cell: `table_copy(DstIdx, SrcIdx, D, S, N)`; threaded:
/// `t_table_copy(St, DstIdx, SrcIdx, D, S, N)`. Cite §4.4.6.
fn emit_table_copy(
  dst_table: String,
  src_table: String,
  dst: Value,
  src: Value,
  count: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let didx = table_idx(ctx, dst_table)
  let sidx = table_idx(ctx, src_table)
  case sc {
    NoState -> {
      let call =
        seam_call(ctx.binding.table_module, "table_copy", [
          CInt(didx),
          CInt(sidx),
          emit_value(dst),
          emit_value(src),
          emit_value(count),
        ])
      let #(effect, state2) = trapping_effect(call, ctx, state)
      emit_zero_effect(effect, cont, sc, state2, ctx)
    }
    Threading(cur) -> {
      let call =
        seam_call(ctx.binding.table_module, "t_table_copy", [
          CVar(cur),
          CInt(didx),
          CInt(sidx),
          emit_value(dst),
          emit_value(src),
          emit_value(count),
        ])
      emit_threaded_record_effect(call, cont, state, ctx)
    }
  }
}

/// `elem.drop(seg)` — mark passive element segment `seg` empty; NEVER traps (R2). Cell:
/// `rt_state:drop_elem(Seg)` as a discarded effect; threaded: `t_drop_elem(St, Seg)` returns the
/// record directly (non-trapping) → REBIND `cur`. Cite §4.4.6.
fn emit_elem_drop(
  seg: Int,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  emit_drop(seg, "drop_elem", cont, sc, state, ctx)
}

// ─────────────────────────── Phase-5 bulk-memory layer (§D) ───────────────────────────
//
// Each op carries an explicit memory index and routes through the `binding.mem_module` seam
// against the FROZEN idx-based bulk heads (`fill(idx,d,v,n)`, `copy(dst,src,d,s,n)`,
// `init(idx,seg,d,s,n)` + `t_*` twins). Same dispositions as §C.

/// `memory.fill(dest, value, count)` on memory `mem` — EAGER trapping ZERO-RESULT write (R10).
/// Cell: `fill(Mem, D, V, N)`; threaded: `t_fill(St, Mem, D, V, N)`. Cite §4.4.7.
fn emit_mem_fill(
  mem: Int,
  dest: Value,
  value: Value,
  count: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case sc {
    NoState -> {
      let call =
        seam_call(ctx.binding.mem_module, "fill", [
          CInt(mem),
          emit_value(dest),
          emit_value(value),
          emit_value(count),
        ])
      let #(effect, state2) = trapping_effect(call, ctx, state)
      emit_zero_effect(effect, cont, sc, state2, ctx)
    }
    Threading(cur) -> {
      let call =
        seam_call(ctx.binding.mem_module, "t_fill", [
          CVar(cur),
          CInt(mem),
          emit_value(dest),
          emit_value(value),
          emit_value(count),
        ])
      emit_threaded_record_effect(call, cont, state, ctx)
    }
  }
}

/// `memory.copy` from `src_mem` to `dst_mem` — memmove, EAGER trapping on BOTH ranges (R10/R11);
/// cross-memory when the indices differ. Cell: `copy(DstMem, SrcMem, D, S, N)`; threaded:
/// `t_copy(St, DstMem, SrcMem, D, S, N)`. Cite §4.4.7.
fn emit_mem_copy(
  dst_mem: Int,
  src_mem: Int,
  dst: Value,
  src: Value,
  count: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case sc {
    NoState -> {
      let call =
        seam_call(ctx.binding.mem_module, "copy", [
          CInt(dst_mem),
          CInt(src_mem),
          emit_value(dst),
          emit_value(src),
          emit_value(count),
        ])
      let #(effect, state2) = trapping_effect(call, ctx, state)
      emit_zero_effect(effect, cont, sc, state2, ctx)
    }
    Threading(cur) -> {
      let call =
        seam_call(ctx.binding.mem_module, "t_copy", [
          CVar(cur),
          CInt(dst_mem),
          CInt(src_mem),
          emit_value(dst),
          emit_value(src),
          emit_value(count),
        ])
      emit_threaded_record_effect(call, cont, state, ctx)
    }
  }
}

/// `memory.init(seg, dst, src, count)` on memory `mem` — copy bytes from passive data segment
/// `seg` into memory (EAGER trapping, R10). The segment payload is emit-supplied, drop-GATED
/// (R2): emit `case rt_state:data_dropped(Seg) of 'true' -> <<>>; _ -> <bytes> end` so a dropped
/// segment traps for `count > 0` (source bound) and no-ops for `count = 0`. Cell:
/// `init(Mem, Bytes, D, S, N)`; threaded: `t_init(St, Mem, Bytes, D, S, N)`. Cite §4.4.7 + §4.4.9.
fn emit_mem_init(
  mem: Int,
  seg: Int,
  dst: Value,
  src: Value,
  count: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use segment <- result.try(
    nth(ctx.data_segments, seg)
    |> result.replace_error(UnsupportedNode("mem_init_seg")),
  )
  let #(gated, state2) =
    drop_gate(
      seg,
      "data_dropped",
      core_binary_bytes(<<>>),
      core_binary_bytes(segment.bytes),
      sc,
      state,
      ctx,
    )
  let #(segvar, state3) = fresh_var(state2)
  case sc {
    NoState -> {
      let call =
        seam_call(ctx.binding.mem_module, "init", [
          CInt(mem),
          CVar(segvar),
          emit_value(dst),
          emit_value(src),
          emit_value(count),
        ])
      let #(effect, state4) = trapping_effect(call, ctx, state3)
      use #(rest, state5) <- result.try(emit_zero_effect(
        effect,
        cont,
        sc,
        state4,
        ctx,
      ))
      Ok(#(CLet([segvar], gated, rest), state5))
    }
    Threading(cur) -> {
      let call =
        seam_call(ctx.binding.mem_module, "t_init", [
          CVar(cur),
          CInt(mem),
          CVar(segvar),
          emit_value(dst),
          emit_value(src),
          emit_value(count),
        ])
      use #(rest, state4) <- result.try(emit_threaded_record_effect(
        call,
        cont,
        state3,
        ctx,
      ))
      Ok(#(CLet([segvar], gated, rest), state4))
    }
  }
}

/// `data.drop(seg)` — mark passive data segment `seg` empty; NEVER traps (R2). Cell:
/// `rt_state:drop_data(Seg)`; threaded: `t_drop_data(St, Seg)` rebinds `cur`. Cite §4.4.7.
fn emit_data_drop(
  seg: Int,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  emit_drop(seg, "drop_data", cont, sc, state, ctx)
}

// ─────────────────────────── shared drop / reference-item helpers ───────────────────────────

/// The shared `data.drop`/`elem.drop` lowering (non-trapping, R2). Cell: the `rt_state`
/// `drop_fn(Seg)` effect (`Nil`), sequenced+discarded (`emit_zero_effect`). Threaded: the
/// `t_<drop_fn>(St, Seg)` twin returns the rebound record directly (non-trapping) → REBIND `cur`
/// and continue disposing zero values (the `t_global_set` shape).
fn emit_drop(
  seg: Int,
  drop_fn: String,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case sc {
    NoState -> {
      let effect = seam_call(ctx.binding.state_module, drop_fn, [CInt(seg)])
      emit_zero_effect(effect, cont, sc, state, ctx)
    }
    Threading(cur) -> {
      let call =
        seam_call(ctx.binding.state_module, "t_" <> drop_fn, [
          CVar(cur),
          CInt(seg),
        ])
      let #(newst, state2) = fresh_var(state)
      use #(rest, state3) <- result.try(apply_cont(
        cont,
        [],
        Threading(newst),
        state2,
        ctx,
      ))
      Ok(#(CLet([newst], call, rest), state3))
    }
  }
}

/// The passive-segment drop-GATE (R2): bind the segment payload to a value that is `empty` when
/// the segment is dropped and `present` otherwise, via
/// `case rt_state:<base>_dropped(Seg) of 'true' -> empty; _ -> present end` (threaded reads the
/// same via the read-only `t_<base>_dropped(St, Seg)` twin). Returns the gate expression and the
/// advanced state; the caller `let`-binds it and passes it to the `rt_mem`/`rt_table` op.
fn drop_gate(
  seg: Int,
  dropped_fn: String,
  empty: CExpr,
  present: CExpr,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> #(CExpr, EmitState) {
  let check = case sc {
    NoState -> seam_call(ctx.binding.state_module, dropped_fn, [CInt(seg)])
    Threading(cur) ->
      seam_call(ctx.binding.state_module, "t_" <> dropped_fn, [
        CVar(cur),
        CInt(seg),
      ])
  }
  let #(wild, state2) = fresh_var(state)
  let gate =
    CCase(check, [
      CClause([PAtom("true")], CAtom("true"), empty),
      CClause([PVar(wild)], CAtom("true"), present),
    ])
  #(gate, state2)
}

/// Render an element segment's `init` items (each a ref-producing const-expr `Expr`) to a list
/// of Core reference VALUES — the payload `table.init` / active reference-segment seeding pass to
/// `rt_table`. `RefFunc($f)` → the `{TypeTag, Closure}` funcref entry (build-strategy ABI, §B);
/// `Values([ConstNull(_)])` → the null sentinel `{ref_null}`; `GlobalGet($g)` → a RUNTIME read of
/// the reference global `$g` (an imported/defined immutable reference global, spec §3.3.1 const
/// exprs), resolved at instantiate/`table.init` time from the seeded `ref_globals` (R8). The
/// `state_ref` is the state channel at the render site: `None` under `Cell` (`ref_global_get` reads
/// the pdict cell directly), `Some(st)` under `Threaded` (`t_ref_global_get(St, …)` over the live
/// record `st`). `Error(UnsupportedNode)` for any other shape.
fn render_ref_items(
  items: List(Expr),
  ctx: Ctx,
  state_ref: Option(String),
  state: EmitState,
) -> Result(#(List(CExpr), EmitState), EmitError) {
  list.try_fold(items, #([], state), fn(acc, item) {
    let #(rendered, st) = acc
    use #(c, st2) <- result.try(render_ref_item(item, ctx, state_ref, st))
    Ok(#(list.append(rendered, [c]), st2))
  })
}

/// Render ONE element-init item to a Core reference value (see `render_ref_items`). A `GlobalGet`
/// item reads the reference global at run time via the `ref_globals` seam so a
/// global-initialised element segment (`(elem … (global.get $g))`, spec §4.5.4) places the global's
/// current reference value into the table.
fn render_ref_item(
  item: Expr,
  ctx: Ctx,
  state_ref: Option(String),
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  case item {
    ir.RefFunc(name) -> reference_func_entry(name, ctx, state)
    // Phase-14 `RefFuncImport` (R14-02, R1/R2): an IMPORTED `ref.func` element-init item. A
    // `RefFuncImport` makes its segment non-`all_reffunc` → non-`byte_ident_funcref`, so the whole
    // segment routes to the general `init_elem_ref` path and lands here. Build the real D3a
    // adapter-closure funcref entry (the SAME `#(TypeTag, adapter)` value `emit_ref_func_import`
    // builds for a body-level ref.func — imported items and defined/null items coexist in a mixed
    // segment, so this must NOT poison the others).
    ir.RefFuncImport(slot, ty) ->
      imported_reference_func_entry(slot, ty, ctx, state)
    Values([ir.ConstNull(_)]) -> Ok(#(null_ref_term(), state))
    GlobalGet(name) -> Ok(#(ref_global_read(name, state_ref, ctx), state))
    // A GC constant-expression element item (Phase-8 GC): a `(ref $t)`/i31/array element
    // initialised by an allocator (possibly a nested `Let`-chain). Evaluate in-process; the
    // boxed handle is placed into the table by the existing `init_elem_ref` path. NoState is
    // correct for the arena in both the cell (state_ref=None) and threaded callers.
    Gc(_, _) | Let(_, _, _) -> emit(item, KReturn, NoState, state, ctx)
    _ -> Error(UnsupportedNode("elem_item"))
  }
}

/// A runtime read of reference global `name` (R8) at the current state site: `Cell`
/// (`state_ref == None`) reads the pdict cell via `rt_state:ref_global_get(<<name>>)`; `Threaded`
/// (`state_ref == Some(st)`) reads the live record via `rt_state:t_ref_global_get(St, <<name>>)`.
/// Used to resolve a `global.get`-initialised element item at instantiate/`table.init` time.
fn ref_global_read(name: String, state_ref: Option(String), ctx: Ctx) -> CExpr {
  case state_ref {
    None ->
      seam_call(ctx.binding.state_module, "ref_global_get", [
        core_binary_string(name),
      ])
    Some(st) ->
      seam_call(ctx.binding.state_module, "t_ref_global_get", [
        CVar(st),
        core_binary_string(name),
      ])
  }
}

// ─────────────────────────────── structured control ───────────────────────────────

/// Lower `If` to a `case` on the i32 condition. Per the IR contract `cond` is an i32 truth
/// value (`0` = false, non-zero = true), so we match the integer directly — `<0>` selects
/// the else branch, a fresh wildcard selects the then branch — avoiding any external BIF
/// call (keeping the D3a invariant that every `call` targets a runtime module). Both arms
/// are emitted under the (materialised) continuation so each yields the merged result; every
/// `case` clause carries the mandatory `when 'true'` guard.
fn emit_if(
  cond: Value,
  result: List(ir.ValType),
  then_branch: Expr,
  else_branch: Expr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use #(maybe_def, jcont, state2) <- result.try(materialize(
    cont,
    list.length(result),
    sc,
    state,
    ctx,
  ))
  use #(then_c, state3) <- result.try(emit(then_branch, jcont, sc, state2, ctx))
  use #(else_c, state4) <- result.try(emit(else_branch, jcont, sc, state3, ctx))
  let #(wild, state5) = fresh_var(state4)
  let case_expr =
    CCase(emit_value(cond), [
      CClause([PInt(0)], CAtom("true"), else_c),
      CClause([PVar(wild)], CAtom("true"), then_c),
    ])
  Ok(#(wrap_join(maybe_def, case_expr), state5))
}

/// Lower `Switch` to a `case` on the integer selector: one `<match>` clause per arm and a
/// trailing wildcard clause for `default`. Every clause carries `when 'true'`; all arms and
/// the default are emitted under the (materialised) continuation.
fn emit_switch(
  selector: Value,
  result: List(ir.ValType),
  arms: List(SwitchArm),
  default: Expr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use #(maybe_def, jcont, state2) <- result.try(materialize(
    cont,
    list.length(result),
    sc,
    state,
    ctx,
  ))
  use #(arm_clauses, state3) <- result.try(
    emit_switch_arms(arms, jcont, sc, state2, ctx, []),
  )
  use #(default_c, state4) <- result.try(emit(default, jcont, sc, state3, ctx))
  let #(wild, state5) = fresh_var(state4)
  let clauses =
    list.append(arm_clauses, [CClause([PVar(wild)], CAtom("true"), default_c)])
  Ok(#(wrap_join(maybe_def, CCase(emit_value(selector), clauses)), state5))
}

/// Emit the `Switch` arm clauses, threading state (accumulator in reverse).
fn emit_switch_arms(
  arms: List(SwitchArm),
  jcont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
  acc: List(CClause),
) -> Result(#(List(CClause), EmitState), EmitError) {
  case arms {
    [] -> Ok(#(list.reverse(acc), state))
    [SwitchArm(match, body), ..rest] -> {
      use #(body_c, state2) <- result.try(emit(body, jcont, sc, state, ctx))
      let clause = CClause([PInt(match)], CAtom("true"), body_c)
      emit_switch_arms(rest, jcont, sc, state2, ctx, [clause, ..acc])
    }
  }
}

/// Lower `Block` to a forward continuation. A non-trivial continuation is materialised into
/// a join point; the block body is emitted with both fall-through and `Break(label, …)`
/// resolving to that exit continuation (so the code after the block is emitted once). Under
/// `Threading`, the materialised join carries the record (§D) and each exit prepends its live
/// record (`apply_cont`'s `KJump`).
fn emit_block(
  label: String,
  result: List(ir.ValType),
  body: Expr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use #(maybe_def, exit_cont, state2) <- result.try(materialize(
    cont,
    list.length(result),
    sc,
    state,
    ctx,
  ))
  let state3 = push_label(state2, LabelEntry(label, exit_cont, None))
  use #(body_c, state4) <- result.try(emit(body, exit_cont, sc, state3, ctx))
  let state5 = restore_labels(state4, state2.labels)
  Ok(#(wrap_join(maybe_def, body_c), state5))
}

/// Lower `Loop` to the verified §5 template: `letrec 'L'/arity = fun(params…) -> <body>`
/// applied to the loop-param inits. `Continue(label, vs)` becomes a tail `apply 'L'(vs)`
/// (the back-edge → constant space); fall-through and `Break(label, …)` exit through the
/// (materialised) continuation.
///
/// Under `Threading(cur)` (the G4 crux), the record is carried as the LEADING loop param:
/// `letrec 'L'/(k+1) = fun(St, P1…Pk) -> <body under Threading(St)>` applied to
/// `apply 'L'(St_entry, Init1…Initk)`. `Continue` prepends the LIVE record
/// (`apply 'L'(St', vs…)`) and `Break`/fall-through prepend the exit record. The back-edge
/// stays a TAIL `apply`, and the `InstanceState` is a fixed-size box, so threading it does NOT
/// grow the stack — constant space and preemption are preserved.
fn emit_loop(
  label: String,
  params: List(ir.LoopParam),
  result: List(ir.ValType),
  body: Expr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let arity = list.length(params)
  use #(maybe_def, exit_cont, state2) <- result.try(materialize(
    cont,
    list.length(result),
    sc,
    state,
    ctx,
  ))
  let #(lname, state3) = fresh_fn(state2)
  case sc {
    NoState -> {
      let lfname = FName(lname, arity)
      let state4 =
        push_label(state3, LabelEntry(label, exit_cont, Some(lfname)))
      use #(body_c, state5) <- result.try(emit(
        body,
        exit_cont,
        NoState,
        state4,
        ctx,
      ))
      let state6 = restore_labels(state5, state3.labels)
      let param_names = list.map(params, fn(p) { p.name })
      let inits = list.map(params, fn(p) { emit_value(p.init) })
      let loop_def = FunDef(lfname, CFun(param_names, body_c))
      let loop_expr = CLetrec([loop_def], CApply(lfname, inits))
      Ok(#(wrap_join(maybe_def, loop_expr), state6))
    }
    Threading(cur) -> {
      let #(st_loop, state3b) = fresh_var(state3)
      let lfname = FName(lname, arity + 1)
      let state4 =
        push_label(state3b, LabelEntry(label, exit_cont, Some(lfname)))
      use #(body_c, state5) <- result.try(emit(
        body,
        exit_cont,
        Threading(st_loop),
        state4,
        ctx,
      ))
      let state6 = restore_labels(state5, state3b.labels)
      let param_names = [st_loop, ..list.map(params, fn(p) { p.name })]
      let inits = [CVar(cur), ..list.map(params, fn(p) { emit_value(p.init) })]
      let loop_def = FunDef(lfname, CFun(param_names, body_c))
      let loop_expr = CLetrec([loop_def], CApply(lfname, inits))
      Ok(#(wrap_join(maybe_def, loop_expr), state6))
    }
  }
}

/// Lower `Break(label, vs)`: resolve the label's exit continuation and dispose `vs`
/// through it (under the break-site's `sc`, so a threaded break prepends its live record).
/// `Error(UnboundLabel)` if the label is not in scope.
fn emit_break(
  label: String,
  vs: List(Value),
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use entry <- result.try(find_label(state, label))
  apply_cont(entry.break_cont, list.map(vs, emit_value), sc, state, ctx)
}

/// Lower `Continue(label, vs)`: tail-apply the loop head `apply 'L'(vs)` — under
/// `Threading(cur)` the LIVE record leads (`apply 'L'(cur, vs)`), keeping the back-edge a tail
/// call (constant space). `Error(UnboundLabel)` if the label is not in scope or names a
/// `Block` (no back-edge).
fn emit_continue(
  label: String,
  vs: List(Value),
  sc: StateChan,
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  use entry <- result.try(find_label(state, label))
  case entry.continue_target {
    Some(lfname) ->
      case sc {
        NoState -> Ok(#(CApply(lfname, list.map(vs, emit_value)), state))
        Threading(cur) ->
          Ok(#(CApply(lfname, [CVar(cur), ..list.map(vs, emit_value)]), state))
      }
    None -> Error(UnboundLabel(label))
  }
}

/// Lower `Charge(cost, body)` to the metering seam (D9): `let _ =
/// call '<meter_module>':'charge'(Cost) in <body>`. State-neutral — `charge` never touches the
/// record, so `sc` (and the live `cur`) flows through `body` unchanged (§G).
fn emit_charge(
  cost: Int,
  body: Expr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case body {
    // Batch consecutive `Charge` regions into ONE `meter:charge` with the summed cost (lever 9).
    // Both charges already run before `inner`, so pre-charging their sum deducts the same fuel and
    // traps at the SAME program point (before `inner`) — one fewer seam call on the hot path.
    Charge(cost2, inner) ->
      emit_charge(cost + cost2, inner, cont, sc, state, ctx)
    _ -> {
      let #(wild, state2) = fresh_var(state)
      use #(body_c, state3) <- result.try(emit(body, cont, sc, state2, ctx))
      let charge_call =
        CCall(CAtom(ctx.binding.meter_module), CAtom("charge"), [CInt(cost)])
      Ok(#(CLet([wild], charge_call, body_c), state3))
    }
  }
}

// ─────────────────────────── Phase-7 exception handling (§J/T1/T5/T7) ───────────────────────────

/// Lower `Throw(tag, args)` — a BEAM-native raise of the build-controlled `{wasm_exn, TagId,
/// Payload}` term through the `rt_exn` chokepoint (J1/D3a). BOTTOM: never returns, so `cont` is
/// dropped (exactly like `Trap`). Emits `call '<rt_exn>':'throw_exn'(<tag_index>, [args…])`, where
/// `tag_index` is the tag's module-local `Int` identity (T4, resolved from `Module.tags`) and the
/// payload is the operand value LIST — rendered, never interpreted (the `(f64,i32)` pair rides
/// opaquely, «PORFFOR-ABI»). Cell-only (T6): no state travels in the term, so `sc` is irrelevant.
/// `Error(UnknownTag)` if the module declares no such tag.
fn emit_throw(
  tag: String,
  args: List(Value),
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use tag_id <- result.try(resolve_tag(ctx, tag))
  let payload = core_list(list.map(args, emit_value))
  Ok(#(seam_call(exn_module, "throw_exn", [CInt(tag_id), payload]), state))
}

/// Lower `ThrowRef(exnref)` — re-raise the exception captured in `exnref` (J1/T9). BOTTOM (never
/// returns), so `cont` is dropped. Emits `call '<rt_exn>':'throw_ref'(<exnref>)`; `rt_exn` unboxes
/// `{ref_exn, Reason}` and re-raises (a null exnref traps, owned by `rt_exn`). State-neutral.
/// Porffor-INERT (spec-conformance surface only).
fn emit_throw_ref(
  exnref: Value,
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  Ok(#(seam_call(exn_module, "throw_ref", [emit_value(exnref)]), state))
}

/// Lower `Try(result, body, handlers)` to a BEAM-native `try … catch` (the `CTry` node, J1/§C).
///
/// `body` is emitted under the (materialised) OUTER continuation `exit_cont`, so its normal
/// completion / `br`-to-enclosing / `return` dispose through `cont` AS TODAY and the `of <V> -> V`
/// clause is a TRANSPARENT pass-through (sound because every emitted expr reduces to ONE packaged
/// value — §C.1). The `catch <C,R,S>` handler (`try_dispatch`) matches the thrown tag against
/// `handlers` in order via the `rt_exn` helpers, transfers a matching handler (its result also
/// disposing through `exit_cont` — so it yields the try's `result`), and re-raises a non-match
/// (T7). Constant-space + the result arity are preserved. Cell-only (T6): the same `sc` flows to
/// the handler (no state travels in the throw — Threaded+EH is a categorised-unsupported combo).
fn emit_try(
  result: List(ValType),
  body: Expr,
  handlers: List(ir.CatchHandler),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use #(join, exit_cont, s1) <- result.try(materialize(
    cont,
    list.length(result),
    sc,
    state,
    ctx,
  ))
  use #(body_c, s2) <- result.try(emit(body, exit_cont, sc, s1, ctx))
  // Hoist the protected body into a local NULLARY function so the try's `Arg` is a SINGLE
  // `apply 'trybody'/0()` (a closure over the try-site scope). This is required for correctness,
  // not cosmetics: a trapping op inside the body emits a `case`-and-raise, and a `case` whose
  // branch raises sitting DIRECTLY in a try `Arg` together with the handler's own `case` makes the
  // BEAM validator reject the module (`ambiguous_catch_try_state` — empirically verified). Routing
  // the body through a single `apply` (whose exceptions the try still catches, exactly as for a
  // bare `Throw` call) sidesteps it. `trybody` sits lexically inside the join `letrec` (via
  // `wrap_join`), so a `br`-to-enclosing (`apply J`) inside the body still resolves.
  let #(bname, s2b) = fresh_fn(s2)
  let body_fn = FName(bname, 0)
  let body_def = FunDef(body_fn, CFun([], body_c))
  // The single transparent success binder (§C.1) + the three exception pattern variables.
  let #(vv, s3) = fresh_var(s2b)
  let #(cvar, s4) = fresh_var(s3)
  let #(rvar, s5) = fresh_var(s4)
  let #(svar, s6) = fresh_var(s5)
  use #(handler_c, s7) <- result.try(try_dispatch(
    handlers,
    cvar,
    rvar,
    svar,
    exit_cont,
    sc,
    s6,
    ctx,
  ))
  let ctry =
    CTry(
      arg: CApply(body_fn, []),
      body_vars: [vv],
      body: CVar(vv),
      evars: [cvar, rvar, svar],
      handler: handler_c,
    )
  Ok(#(wrap_join(join, CLetrec([body_def], ctry)), s7))
}

/// Build the `catch <C,R,S>` handler body for a `Try`'s clauses (§C.3, `Produces` #2): a chain of
/// `case`s, ONE per `CatchHandler` in order, ending in a re-raise default. Each `OnTag(t)` clause
/// tests `rt_exn:match_tag(R, <t index>)` (matched → the payload bound + the handler; else the
/// next clause); each `OnAll` clause tests `rt_exn:is_wasm_exn(R)` (`'true'` → the handler; else
/// next). The final default re-raises via `rt_exn:reraise(C, R, <built stacktrace>)` — so a wrong
/// tag AND any trap `{wasm_trap,_}` / fuel raise PROPAGATE uncaught (T7 — the load-bearing rule
/// that `catch_all` catches exceptions but NOT traps, enforced by `is_wasm_exn`). The stacktrace
/// is rebuilt via `primop 'build_stacktrace'` (verified: `erlang:raise/3` on the raw catch token
/// returns `badarg`). D3a: every reach is a fixed-atom `rt_exn` seam call — no `erlang:*` emitted.
fn try_dispatch(
  handlers: List(ir.CatchHandler),
  cvar: String,
  rvar: String,
  svar: String,
  exit_cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(stk_var, state1) = fresh_var(state)
  let reraise =
    CLet(
      [stk_var],
      CPrimop("build_stacktrace", [CVar(svar)]),
      seam_call(exn_module, "reraise", [
        CVar(cvar),
        CVar(rvar),
        CVar(stk_var),
      ]),
    )
  // Fold from the LAST handler inward so the FIRST handler becomes the OUTERMOST case (clause
  // order preserved — a `catch $t` before a `catch_all` tests the tag first).
  list.try_fold(list.reverse(handlers), #(reraise, state1), fn(acc, h) {
    let #(next, st) = acc
    emit_catch_clause(h, rvar, next, exit_cont, sc, st, ctx)
  })
}

/// Emit ONE catch clause of the `try_dispatch` chain: `case <test> of <matched> -> <handler> ;
/// <_> -> <next> end`. The handler `Expr` is emitted under the try's `exit_cont` (so it yields the
/// try's result, composing with the label-continuation machinery — a modern Break/Continue/Return
/// transfer or a legacy inline handler); its payload names bind from the matched term, and an
/// `exnref` (if any) is captured via `rt_exn:capture_exnref(R)` before the handler runs (§E).
fn emit_catch_clause(
  h: ir.CatchHandler,
  rvar: String,
  next: CExpr,
  exit_cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let ir.CatchHandler(on, payload, exnref, hexpr) = h
  use #(hbody0, state1) <- result.try(emit(hexpr, exit_cont, sc, state, ctx))
  // Capture the caught exception as an opaque `exnref` handle if the handler binds one (T9).
  let hbody = case exnref {
    Some(name) ->
      CLet(
        [name],
        seam_call(exn_module, "capture_exnref", [CVar(rvar)]),
        hbody0,
      )
    None -> hbody0
  }
  case on {
    // `catch $t` — match the SAME module-local tag identity throw used (T4); the matched clause
    // binds the payload operands directly (`{ok, [P0,P1,…]}`), so throw/catch arities agree.
    ir.OnTag(tag) -> {
      use tag_id <- result.try(resolve_tag(ctx, tag))
      let match = seam_call(exn_module, "match_tag", [CVar(rvar), CInt(tag_id)])
      let #(wild, state2) = fresh_var(state1)
      Ok(#(
        CCase(match, [
          CClause(
            [PTuple([PAtom("ok"), list_pattern(payload)])],
            CAtom("true"),
            hbody,
          ),
          CClause([PVar(wild)], CAtom("true"), next),
        ]),
        state2,
      ))
    }
    // `catch_all` — catch ANY wasm exception but NOT a trap (T7): `is_wasm_exn` is `'false'` for a
    // `{wasm_trap,_}` / fuel raise, which falls to `next` (ultimately the re-raise), so a trap
    // propagates through the region untouched. No payload is bound.
    ir.OnAll -> {
      let is_exn = seam_call(exn_module, "is_wasm_exn", [CVar(rvar)])
      Ok(#(
        CCase(is_exn, [
          CClause([PAtom("true")], CAtom("true"), hbody),
          CClause([PAtom("false")], CAtom("true"), next),
        ]),
        state1,
      ))
    }
  }
}

// ─────────────────────────────── values ───────────────────────────────

/// Lower an atomic IR `Value` to a Core expression. Variables become `CVar` (raw name —
/// the printer legalizes). Every constant is its RAW BIT PATTERN as a `CInt` (integers as
/// the unsigned bit pattern; floats as their IEEE-754 bits per D5 — never a Core float).
fn emit_value(v: Value) -> CExpr {
  case v {
    Var(name) -> CVar(name)
    ConstI32(bits) -> CInt(bits)
    ConstI64(bits) -> CInt(bits)
    ConstF32(bits) -> CInt(bits)
    ConstF64(bits) -> CInt(bits)
    // The null-reference literal (both reftypes share ONE sentinel, R1) — the forge-proof
    // `{ref_null}` term `rt_ref.null_ref` produces. Reftype-agnostic at runtime.
    ir.ConstNull(_ty) -> null_ref_term()
    // The `v128.const` literal (I1/D5) — the 16 raw little-endian bytes as a Core binary
    // literal, verbatim (like `ConstF32`'s raw bits, one level wider). Pure; no `rt_simd` call.
    ir.ConstV128(bytes) -> core_binary_bytes(bytes)
    // Phase-8 term literals (K2, unit 01): a literal atom lowers to a Core `CAtom` (the backend
    // quotes/escapes `name`); a literal binary lowers to a byte-exact Core binary literal (the
    // same renderer a data-segment payload uses). Both pure — no runtime call.
    ir.ConstAtom(name) -> CAtom(name)
    ir.ConstBinary(bytes) -> core_binary_bytes(bytes)
    // A native BEAM float TERM literal — the term-layer double a dynamic-language frontend emits
    // for a FINITE number literal, so `NumTerm`/`erlang:'+'` runs native double arithmetic. THE
    // deliberate exception to the "floats as bits, never a Core float" rule above (D5): only a
    // frontend `ConstFloatTerm` (finite, K7-additive) reaches it; no WASM float ever does.
    ir.ConstFloatTerm(value) -> CFloat(value)
  }
}

/// The shared null-reference sentinel literal `{ref_null}` (R1) — the SINGLE build-controlled
/// term `ConstNull`/`ref.null` lowers to, byte-identical to what `rt_ref.null_ref` produces and
/// what `rt_table` stores/compares in an unfilled slot. A pure literal (not a `call`), so it is
/// const-foldable (element/global reference inits) and D3a-trivially-clean. Reftype-agnostic:
/// both `funcref` and `externref` null share this one sentinel (Phase 5 has no typed dispatch on
/// a null reference — the `ty` on `ConstNull` is carried only for validation / the `.ir` text).
fn null_ref_term() -> CExpr {
  CTuple([CAtom("ref_null")])
}

/// A Core value list: a single value is itself; zero or many become `<…>` (`CValues`).
/// Used for *internal* value-list positions (the RHS of a `let <names…> = … in …` and the
/// arguments of a join-point `apply`), where Core Erlang permits an arbitrary-arity value
/// list. NOT used at a function/join-point return boundary — see `function_return`.
fn value_list(exprs: List(CExpr)) -> CExpr {
  case exprs {
    [single] -> single
    _ -> CValues(exprs)
  }
}

/// Package a function/join-point's result value list into the SINGLE value a BEAM function
/// must return (Core Erlang rejects a top-level body that yields a value list of arity ≠ 1
/// as a "return count mismatch"):
///
/// - 0 results (a `void`/zero-result WASM function) → the canonical unit atom `'ok'`. The
///   conformance driver ignores a zero-result return, so the concrete value is immaterial;
///   what matters is that exactly one value is produced so the function compiles (and any
///   trap inside it still raises).
/// - 1 result → the bare value (the common case; unchanged).
/// - N≥2 results (multi-value) → an N-tuple `{V1,…,Vn}`. The matching `apply_cont_call`
///   destructures this tuple at the call site, so the multi-value convention round-trips.
///   Direct multi-value *invocation* remains out of Phase-1 scope (the driver skips it);
///   this only makes multi-value functions and their callers compile and compute correctly.
fn function_return(exprs: List(CExpr)) -> CExpr {
  case exprs {
    [] -> CAtom("ok")
    [single] -> single
    _ -> CTuple(exprs)
  }
}

/// Build a proper Core list `[E1, E2, …]` (`CCons` chain ending in `CNil`).
fn core_list(exprs: List(CExpr)) -> CExpr {
  list.fold_right(exprs, CNil, fn(acc, e) { CCons(e, acc) })
}

/// A proper Core LIST PATTERN `[N1, N2, …]` of variable binders (`PCons` chain ending in
/// `PNil`). Used to destructure a `call_indirect` result list and a closure's args list.
fn list_pattern(names: List(String)) -> CPat {
  list.fold_right(names, PNil, fn(acc, n) { PCons(PVar(n), acc) })
}

// ─────────────────────────────── the FuncType / binary-literal renderers ───────────────────────────────

/// Render an `ir.FuncType` as a build-controlled, compile-time-canonical Core TERM
/// `{[paramtype-atoms…], [resulttype-atoms…]}` — the `call_indirect` `TypeTag`.
///
/// This is the SINGLE renderer used at BOTH the call site (the expected type) and the
/// element-segment entry (the slot's stored type tag), so `rt_table`'s exact structural
/// guard `entry_type == expected_type` holds at run time (both terms are byte-identical when
/// the `FuncType`s are structurally equal). `rt_table` never inspects the term's shape — it
/// only stores and `==`-compares it — so any canonical encoding works provided it is
/// produced here and nowhere else.
fn func_type_term(ty: FuncType) -> CExpr {
  let FuncType(params, results) = ty
  CTuple([
    core_list(list.map(params, valtype_atom)),
    core_list(list.map(results, valtype_atom)),
  ])
}

/// The canonical valtype atom used inside a `func_type_term` (`'i32'`/`'i64'`/`'f32'`/
/// `'f64'`/`'term'`). Self-consistent — only its use on both sides of the `==` guard matters.
fn valtype_atom(t: ValType) -> CExpr {
  CAtom(case t {
    TI32 -> "i32"
    TI64 -> "i64"
    TF32 -> "f32"
    TF64 -> "f64"
    TTerm -> "term"
    ir.TFuncRef -> "funcref"
    ir.TExternRef -> "externref"
    // Phase-6 SIMD value type (§J). Self-consistent inside `func_type_term`.
    ir.TV128 -> "v128"
    // Phase-7 exnref value type (§J/T9). Self-consistent inside `func_type_term`.
    ir.TExnRef -> "exnref"
  })
}

/// A Core binary STRING literal of `s`'s UTF-8 bytes (e.g. `"g0"` → `<<"g0">>`), byte-exact
/// with the BEAM binary a Gleam `String` is — so `rt_state.global_get(name: String)` /
/// `seed`'s global-name keys match. Emitted as a `CBinary` of 8-bit integer segments.
fn core_binary_string(s: String) -> CExpr {
  core_binary_bytes(bit_array.from_string(s))
}

/// A Core binary literal of the raw `bytes` (a data-segment payload), each byte an 8-bit
/// `'integer'` segment — byte-exact with a BEAM `binary`/Gleam `BitArray`.
fn core_binary_bytes(bytes: BitArray) -> CExpr {
  CBinary(byte_segments(bytes, []))
}

/// Peel `bytes` into one little-endian-irrelevant 8-bit segment per byte (accumulated in
/// reverse, then restored). A non-byte-aligned tail (never produced here) ends the scan.
fn byte_segments(bytes: BitArray, acc: List(CBitSeg)) -> List(CBitSeg) {
  case bytes {
    <<b:size(8), rest:bits>> -> byte_segments(rest, [byte_seg(b), ..acc])
    _ -> list.reverse(acc)
  }
}

/// One unsigned 8-bit integer binary segment `#<B>(8,1,'integer',['unsigned','big'])`.
fn byte_seg(b: Int) -> CBitSeg {
  CBitSeg(value: CInt(b), size: CInt(8), unit: 1, segtype: "integer", flags: [
    "unsigned",
    "big",
  ])
}

// ─────────────────────────────── the instantiate/0 entry (E5) ───────────────────────────────

/// Emit the generated `'instantiate'/0` entry (the frozen instantiation contract, §C).
///
/// This is the ONE documented exception to `emit_core`'s posture-agnosticism (module doc,
/// F4/F6/F7): it is the sole owner of the per-instance runtime SEEDS, so it — and only it —
/// reads policy fields (`meter`/`fuel_budget`/`host_policy`). Its body runs, in order, inside
/// the instance's owned process:
///
/// - (0a) **when `binding.meter == MeterFuel`** — `rt_meter:seed_fuel(binding.fuel_budget)` as
///   the FIRST effect, arming the fail-closed CPU bound BEFORE any `charge` can fire (F5/D4).
///   Under `MeterOff` no `seed_fuel` line is emitted (there are no `Charge` sites to bound).
/// - (0b) **always** — `rt_host:seed_policy(binding.host_policy)` with `host_policy` baked as a
///   Core Erlang literal (F4/F7). Safe seeds `host_deny_all`, Unsafe seeds `host_open`;
///   seeding always keeps the boundary explicit (an unseeded policy already defaults deny-all).
/// - (1) seed the FRESH per-instance cell (`rt_state:seed` with a build-controlled `StateDecl`
///   term whose `mem = rt_mem:fresh(min, max, safe_cap)`, `table = rt_table:new(min, max)`, and
///   globals from their constant-folded inits); (2) write each active ELEMENT segment
///   (`rt_table:init_elem`); (3) write each active DATA segment (`rt_mem:init_data`); (4) run
///   the `start` function. Element BEFORE data (spec instantiation order). Steps 2–4 are
///   trap-at-instantiation: each is reduced to one discardable value (`{ok,_}` → `'ok'`,
///   `{error,E}` → `raise`) and `let`-sequenced, so a segment-OOB / trapping-start raises and
///   fails instantiation. The body returns `'ok'` on success.
///
/// The two seed lines are the ONLY difference between `emit_module(m, safe())` and
/// `emit_module(m, unsafe())` beyond the `Charge` nodes already differing in the incoming IR
/// (§A.4). Both target fixed `Binding` runtime atoms (`meter_module`/`host_module`), so they
/// pass the no-ambient-authority walk unchanged (D3a). They run once per instance, never on a
/// hot path — so F5 zero-overhead on metered functions is untouched.
///
/// Returns `Error(NonConstInit)` if a global init / segment offset is not a constant
/// literal, or `Error(UnknownFunction)` if an element/`start` function is undefined.
///
/// Under `state_strategy: Threaded` the body instead BUILDS and RETURNS the `InstanceState`
/// record (`emit_instantiate_threaded`, §E); the `seed_fuel`/`seed_policy` seeds are unchanged
/// (metering/host are pdict-seeded — orthogonal to state threading).
fn emit_instantiate(module: Module, ctx: Ctx) -> Result(FunDef, EmitError) {
  case needs_full_decl(module) {
    // The byte-identical Phase-4 path (StateDecl + `seed`/`fresh`, `instantiate/0`) for a
    // single-region, import-free, no-reference-global module (H7) — UNCHANGED.
    False ->
      case is_threaded(ctx) {
        False -> emit_instantiate_cell(module, ctx)
        True -> emit_instantiate_threaded(module, ctx)
      }
    // The general path (FullDecl + `seed_full`/`fresh_full`) for a multi-memory / multi-table /
    // non-function-import / reference-global module (R4/R5/R7/R8). `instantiate/1(Imports)` when
    // the module has ≥1 state import, else `instantiate/0`.
    True -> emit_instantiate_full(module, ctx)
  }
}

/// `True` iff `module` needs the general `FullDecl` seed (`seed_full`/`fresh_full`): it has a
/// non-function import (imported provided state), ≥2 memories, ≥2 tables, or a defined
/// reference-typed global. Otherwise the byte-identical Phase-4 `StateDecl` path applies (H7) —
/// a single-region, import-free, numeric-global module keeps its exact prior `.core`.
fn needs_full_decl(module: Module) -> Bool {
  count_state_imports(module) > 0
  || list.length(module.memories) >= 2
  || list.length(module.tables) >= 2
  // A boxed (reference OR v128, S6) defined global needs the `FullDecl.ref_globals` slot — the
  // `StateDecl` path has only the numeric raw-bit `globals`.
  || list.any(module.globals, fn(g) { is_boxed_global_type(g.ty) })
  // An `Idx64` memory needs the `mem_fresh_term` `fresh64` branch (§D) — the `StateDecl` path inlines
  // the byte-identical Phase-5 `fresh` (Idx32-only).
  || list.any(module.memories, fn(m) { m.idx_type == ir.Idx64 })
  // A module that CALLS an imported function needs its `func_imports` vector seeded at instantiate
  // (S5) — the `FullDecl` path carries the positional func-import slots.
  || needs_func_imports(module)
}

/// `True` iff `module` is IMPORT-BEARING for the func-import dispatch vector — the SINGLE PUBLIC
/// predicate (R3, Phase-14) that forces the vector to be seeded at `instantiate` (S5) AND that the
/// conformance driver (`driver.module_calls_import`) calls to decide whether to weave the positional
/// `link.Provided` function-import closures. Because emit's seed and the driver's woven closures are
/// now the SAME function of the SAME lowered `irmod`, the `instantiate/0`↔`instantiate/1` arity
/// cannot desync (the sharpest edge in Phase 13's capstone).
///
/// `True` when EITHER (a) some function body contains a `CallImport` / `ReturnCallImport` (it CALLS
/// an imported function) OR a body-level `RefFuncImport` (it `ref.func`s an imported function — e.g.
/// returned or `table.set` into a slot), OR (b) some ELEMENT SEGMENT init item is a `RefFuncImport`
/// — a `ref.func` of an imported function placed into a table (Phase-14). Case (b) scans ALL element
/// modes (active / passive / declarative): a conservative over-approximation that subsumes "passive
/// segments reachable via `table.init`" without fragile reachability tracing. Over-seeding is safe
/// and byte-neutral — R4 seeds ALL function imports regardless, so a never-`table.init`'d passive
/// segment merely seeds an already-all-seeded vector. Both surfaces are scanned because the adapter's
/// deferred `func_import_at(slot)` read (built by EITHER) faults at dispatch unless the vector was
/// seeded at instantiate.
///
/// BYTE-IDENTITY (H7/R5): `RefFuncImport` is a new node present in NO pre-Phase-14 module, so
/// neither the body scan nor the element scan changes any existing module's result — a module that
/// merely IMPORTS a function without calling or `ref.func`-ing it stays `False` (I7).
pub fn needs_func_imports(module: Module) -> Bool {
  list.any(module.functions, fn(f) {
    expr_has_call_import(f.body) || expr_has_ref_func_import(f.body)
  })
  || list.any(module.elements, fn(seg) {
    list.any(seg.init, expr_has_ref_func_import)
  })
}

/// `True` iff `expr` (recursively) contains a `RefFuncImport` node — an imported `ref.func`
/// construction anywhere in `expr`. Used by `needs_func_imports` to seed the func-import vector for
/// a module whose ONLY use of a func import is a `ref.func` (in an element-segment init item OR a
/// function body), with no `CallImport` anywhere. Recurses the SAME control-flow containers as
/// `expr_has_call_import` so a body-level imported `ref.func` (returned or stored) is also caught.
fn expr_has_ref_func_import(expr: Expr) -> Bool {
  case expr {
    ir.RefFuncImport(..) -> True
    Let(_, rhs, body) ->
      expr_has_ref_func_import(rhs) || expr_has_ref_func_import(body)
    If(_, _, t, e) -> expr_has_ref_func_import(t) || expr_has_ref_func_import(e)
    Switch(_, _, arms, default) ->
      list.any(arms, fn(a) {
        let SwitchArm(_, b) = a
        expr_has_ref_func_import(b)
      })
      || expr_has_ref_func_import(default)
    Block(_, _, body) -> expr_has_ref_func_import(body)
    Loop(_, _, _, body) -> expr_has_ref_func_import(body)
    Charge(_, body) -> expr_has_ref_func_import(body)
    _ -> False
  }
}

/// `True` iff `expr` (recursively) contains a `CallImport` node — OR a Phase-13 `ReturnCallImport`
/// (a TAIL call to an imported function reads the same positional func-import capability, so the
/// module still needs `instantiate/1` + the seeded func-import vector).
fn expr_has_call_import(expr: Expr) -> Bool {
  case expr {
    ir.CallImport(..) | ir.ReturnCallImport(..) -> True
    Let(_, rhs, body) -> expr_has_call_import(rhs) || expr_has_call_import(body)
    If(_, _, t, e) -> expr_has_call_import(t) || expr_has_call_import(e)
    Switch(_, _, arms, default) ->
      list.any(arms, fn(a) {
        let SwitchArm(_, b) = a
        expr_has_call_import(b)
      })
      || expr_has_call_import(default)
    Block(_, _, body) -> expr_has_call_import(body)
    Loop(_, _, _, body) -> expr_has_call_import(body)
    Charge(_, body) -> expr_has_call_import(body)
    _ -> False
  }
}

/// `True` iff `ty` is a BOXED (opaque-`Dynamic`) global type — a reference (funcref/externref, R8)
/// OR a `v128` (a 16-byte `BitArray`, S6). Boxed globals live in `rt_state`'s parallel `ref_globals`
/// map (`ref_global_get`/`set`), NOT the numeric raw-bit `globals` map (which stays byte-identical
/// for D5). `emit_core` routes both through the same boxed accessor.
fn is_boxed_global_type(ty: ValType) -> Bool {
  is_reference_type(ty) || ty == ir.TV128
}

/// The number of STATE imports (imported globals/tables/memories) — the length of the positional
/// `Imports` list `instantiate/1` destructures, and `> 0` ⇔ the module gets `instantiate/1`.
/// Function imports (call-site capabilities, H4) contribute NO positional slot.
fn count_state_imports(module: Module) -> Int {
  list.fold(module.imports, 0, fn(n, imp) {
    case imp {
      ir.ImportFn(..) -> n
      _ -> n + 1
    }
  })
}

/// The number of FUNCTION imports (`ir.ImportFn`) — one dispatch-closure slot each, in
/// function-import declaration order, indexed by `CallImport.slot`. Public (Phase-14) so the
/// arity-lockstep test can assert `count_import_slots == count_function_imports` for an
/// import-bearing module.
pub fn count_function_imports(module: Module) -> Int {
  list.fold(module.imports, 0, fn(n, imp) {
    case imp {
      ir.ImportFn(..) -> n + 1
      _ -> n
    }
  })
}

/// The total number of positional `Imports` slots the generated `instantiate` destructures (S5):
/// the state imports (`count_state_imports`, first) PLUS — only when the module CALLS an imported
/// function (`needs_func_imports`) — every function import's dispatch-closure slot (last). A module
/// that imports functions but never calls one contributes NO function slot, so its arity is
/// byte-identical to Phase-5 (I7). The harness passes `link_imports(m) ++ link_func_imports(m)` in
/// exactly this order. Public (Phase-14) so the arity-lockstep test can assert the generated entry
/// is `instantiate/1` (`count_import_slots > 0`) for an import-bearing module.
pub fn count_import_slots(module: Module) -> Int {
  count_state_imports(module) + count_func_import_positions(module)
}

/// The number of positional FUNCTION-import slots (`count_function_imports` when the module calls an
/// imported function, else 0). Seeding ALL function imports (not just the called ones) keeps
/// `CallImport.slot` — the function-import index — a direct index into the seeded vector.
fn count_func_import_positions(module: Module) -> Int {
  case needs_func_imports(module) {
    True -> count_function_imports(module)
    False -> 0
  }
}

/// Emit the general `instantiate` entry (R4/R5): `instantiate/1(Imports)` for an import-bearing
/// module (weaving each positional `link.Provided` into its `FullDecl` slot), else
/// `instantiate/0`. Builds the `FullDecl` (a memories vector + a tables vector + numeric and
/// reference globals, imports woven at the low indices — spec §2.5.1), seeds via `seed_full`
/// (cell) / `fresh_full` (threaded), runs the active element → data segments (element BEFORE
/// data — spec instantiation order) and the `start`, and returns `'ok'` (cell) / the record
/// (threaded).
fn emit_instantiate_full(
  module: Module,
  ctx: Ctx,
) -> Result(FunDef, EmitError) {
  let state0 =
    EmitState(
      counter: 0,
      vars: set.new(),
      fns: set.from_list(dict.keys(ctx.fn_arity)),
      labels: [],
    )
  let n_imports = count_import_slots(module)
  // The positional `Imports` parameter (only present at arity 1) + one destructuring var per
  // import SLOT (`Imp<p>`) — state imports first, then the function-import dispatch closures (S5).
  // Gensym'd, so they never collide with each other or the seeds.
  let #(imports_param, state1) = fresh_var(state0)
  let #(imp_vars, state2) = fresh_n_vars(state1, n_imports)
  use #(decl_term, deferred_global_sets, state3) <- result.try(full_decl_term(
    module,
    ctx,
    imp_vars,
    state2,
  ))
  // The function-import dispatch closures occupy the positional slots AFTER the state imports (S5);
  // pull their `Imp<p>` vars for the `seed_func_imports`/`set_func_imports` seed.
  let func_import_vars = list.drop(imp_vars, count_state_imports(module))
  use body <- result.try(case is_threaded(ctx) {
    False ->
      full_cell_body(
        module,
        ctx,
        decl_term,
        deferred_global_sets,
        func_import_vars,
        state3,
      )
    // `deferred_global_sets` is empty for the Threaded posture (defer is off there).
    True -> full_threaded_body(module, ctx, decl_term, func_import_vars, state3)
  })
  Ok(wrap_instantiate(n_imports, imports_param, imp_vars, body))
}

/// Wrap the general instantiate `body` in its entry function. Import-free (`n == 0`) →
/// `instantiate/0 = fun () -> body`; import-bearing → `instantiate/1 = fun (Imports) ->
/// case Imports of <[Imp0, …]> -> body` — destructuring the positional list ONCE at the top so
/// each `Imp<p>` is in scope for the `link.provided_*` weaving (D3a — the slot wiring is
/// statically baked, no runtime name lookup).
fn wrap_instantiate(
  n_imports: Int,
  imports_param: String,
  imp_vars: List(String),
  body: CExpr,
) -> FunDef {
  case n_imports {
    0 -> FunDef(FName("instantiate", 0), CFun([], body))
    _ -> {
      let destructure =
        CCase(CVar(imports_param), [
          CClause([list_pattern(imp_vars)], CAtom("true"), body),
        ])
      FunDef(FName("instantiate", 1), CFun([imports_param], destructure))
    }
  }
}

/// The `Cell` general-instantiate body: `seed_full(Decl)` then the active element → data segment
/// effects → `start`, chained as ordered effects (same shape as `emit_instantiate_cell`, but with
/// `seed_full` instead of `seed`). Returns `'ok'`.
fn full_cell_body(
  module: Module,
  ctx: Ctx,
  decl_term: CExpr,
  deferred_global_sets: List(CExpr),
  func_import_vars: List(String),
  state: EmitState,
) -> Result(CExpr, EmitError) {
  let seed_effect =
    seam_call(ctx.binding.state_module, "seed_full", [decl_term])
  use #(elem_fx, state2) <- result.try(element_segment_effects(
    module.elements,
    ctx,
    state,
  ))
  use #(data_fx, state3) <- result.try(data_segment_effects(
    module.data_segments,
    ctx,
    state2,
  ))
  use start_fx <- result.try(start_effects(module, ctx))
  let effects =
    list.flatten([
      seed_fuel_effect(ctx),
      seed_policy_effect(ctx),
      [seed_effect],
      seed_func_imports_effect(func_import_vars, ctx),
      // Globals whose init reads another global, set in declaration order now that the cell is
      // seeded — BEFORE any element/data segment or `start`, which may read them.
      deferred_global_sets,
      elem_fx,
      data_fx,
      start_fx,
    ])
  let #(body, _state4) = chain_effects(effects, state3)
  Ok(body)
}

/// The `Cell` `seed_func_imports` effect (S5), or `[]` when the module calls no imported function.
/// Pulls each positional func-import closure out of its `Imp<p>` var via `link:provided_func_call`
/// (a fixed `link` module call, the slot chosen statically — D3a) and installs the whole vector into
/// the just-seeded cell via `rt_state:seed_func_imports([Closures…])`. Runs right after
/// `seed_full`, before any element/data segment, so any `start` function that calls an import finds
/// the vector present.
fn seed_func_imports_effect(
  func_import_vars: List(String),
  ctx: Ctx,
) -> List(CExpr) {
  case func_import_vars {
    [] -> []
    _ -> [
      seam_call(ctx.binding.state_module, "seed_func_imports", [
        core_list(
          list.map(func_import_vars, fn(v) {
            seam_call(link_module, "provided_func_call", [CVar(v)])
          }),
        ),
      ]),
    ]
  }
}

/// The `Threaded` general-instantiate body: `St0 = fresh_full(Decl)` then the record-threading
/// active element → data → start wrappers (same shape as `emit_instantiate_threaded`, but with
/// `fresh_full`). Returns the final `InstanceState`.
fn full_threaded_body(
  module: Module,
  ctx: Ctx,
  decl_term: CExpr,
  func_import_vars: List(String),
  state: EmitState,
) -> Result(CExpr, EmitError) {
  let seed_effects =
    list.flatten([seed_fuel_effect(ctx), seed_policy_effect(ctx)])
  let #(seed_wraps, state2) = discard_wrappers(seed_effects, state)
  let #(st0, state3) = fresh_var(state2)
  let fresh_wrap = fn(rest) {
    CLet(
      [st0],
      seam_call(ctx.binding.state_module, "fresh_full", [decl_term]),
      rest,
    )
  }
  // Seed the func-import dispatch vector on the fresh record (S5): `St0b = set_func_imports(St0,
  // [Closures…])`, threaded forward from here — or, with no imported-function call, thread `St0`
  // straight through (byte-neutral).
  let #(cur_seeded, fi_wraps, state3b) = case func_import_vars {
    [] -> #(st0, [], state3)
    _ -> {
      let #(st0b, s) = fresh_var(state3)
      let wrap = fn(rest) {
        CLet(
          [st0b],
          seam_call(ctx.binding.state_module, "set_func_imports", [
            CVar(st0),
            core_list(
              list.map(func_import_vars, fn(v) {
                seam_call(link_module, "provided_func_call", [CVar(v)])
              }),
            ),
          ]),
          rest,
        )
      }
      #(st0b, [wrap], s)
    }
  }
  use #(elem_wraps, cur1, state4) <- result.try(threaded_elem_wrappers(
    module.elements,
    cur_seeded,
    state3b,
    ctx,
  ))
  use #(data_wraps, cur2, state5) <- result.try(threaded_data_wrappers(
    module.data_segments,
    cur1,
    state4,
    ctx,
  ))
  use #(start_wraps, cur3, _state6) <- result.try(threaded_start_wrapper(
    module,
    cur2,
    state5,
    ctx,
  ))
  let all_wraps =
    list.flatten([
      seed_wraps,
      [fresh_wrap],
      fi_wraps,
      elem_wraps,
      data_wraps,
      start_wraps,
    ])
  Ok(list.fold_right(all_wraps, CVar(cur3), fn(rest, wrap) { wrap(rest) }))
}

/// Build the `FullDecl` Core term `{full_decl, Mems, Globals, Tables, RefGlobals}` (R5/R7/R8):
/// imported memories/tables/globals occupy the LOW indices (each pulled from its positional
/// `Imp<p>` via a `link.provided_*` extractor — spec §2.5.1), then the module's defined
/// memories (`rt_mem:fresh`) / tables (`rt_table:new`) / globals (const-folded numeric bits or a
/// rendered reference value). `imp_vars` are the destructuring vars of the positional `Imports`
/// list, in state-import order. Threads `state` (defined reference-global funcref closures gensym).
fn full_decl_term(
  module: Module,
  ctx: Ctx,
  imp_vars: List(String),
  state: EmitState,
) -> Result(#(CExpr, List(CExpr), EmitState), EmitError) {
  use #(imp_mems, imp_tables, imp_nums, imp_refs) <- result.try(imported_slots(
    module,
    imp_vars,
  ))
  let def_mems = list.map(module.memories, fn(m) { mem_fresh_term(m, ctx) })
  let def_tables = list.map(module.tables, fn(t) { table_new_term(t, ctx) })
  // Only the Cell posture defers global-reading inits to post-seed sets; the Threaded posture builds
  // its state record functionally (`fresh_full`) and is unchanged here.
  use #(def_nums, def_refs, deferred, state2) <- result.try(defined_globals(
    module.globals,
    ctx,
    state,
    !is_threaded(ctx),
  ))
  let mems = core_list(list.append(imp_mems, def_mems))
  let globals = core_list(list.append(imp_nums, def_nums))
  let tables = core_list(list.append(imp_tables, def_tables))
  let ref_globals = core_list(list.append(imp_refs, def_refs))
  Ok(#(
    CTuple([CAtom("full_decl"), mems, globals, tables, ref_globals]),
    deferred,
    state2,
  ))
}

/// Walk `module.imports` and build the IMPORTED slot vectors for the `FullDecl` — each imported
/// memory/table/global pulled from its positional `Imp<p>` (`imp_vars[p]`) via the matching
/// `link.provided_*` extractor (D3a — a fixed `link` module call, the slot chosen statically).
/// Returns `#(mems, tables, numeric_globals, reference_globals)`, each a Core list in import
/// order; function imports contribute nothing. Numeric globals are `{<<name>>, Bits}`, reference
/// globals `{<<name>>, Ref}`, keyed by the imported global's local name `g<idx>`.
fn imported_slots(
  module: Module,
  imp_vars: List(String),
) -> Result(#(List(CExpr), List(CExpr), List(CExpr), List(CExpr)), EmitError) {
  use #(mems, tables, nums, refs, _p, _g) <- result.map(
    list.try_fold(module.imports, #([], [], [], [], 0, 0), fn(acc, imp) {
      let #(mems, tables, nums, refs, p, gidx) = acc
      case imp {
        ir.ImportFn(..) -> Ok(#(mems, tables, nums, refs, p, gidx))
        // An imported exception TAG (Phase-7, T2) contributes NO positional state slot here (like
        // a function import) — its link identity (`ProvidedTag`) is DEFERRED (§H.4). Byte-neutral
        // (no Phase-1..6 module imports a tag; Porffor is single-module).
        ir.ImportTag(..) -> Ok(#(mems, tables, nums, refs, p, gidx))
        ir.ImportGlobal(_, _, ty, _) -> {
          use v <- result.map(import_var(imp_vars, p))
          let name = core_binary_string("g" <> int.to_string(gidx))
          case is_boxed_global_type(ty) {
            True -> #(
              mems,
              tables,
              nums,
              list.append(refs, [
                CTuple([
                  name,
                  seam_call(link_module, "provided_ref_value", [CVar(v)]),
                ]),
              ]),
              p + 1,
              gidx + 1,
            )
            False -> #(
              mems,
              tables,
              list.append(nums, [
                CTuple([
                  name,
                  seam_call(link_module, "provided_global_bits", [CVar(v)]),
                ]),
              ]),
              refs,
              p + 1,
              gidx + 1,
            )
          }
        }
        ir.ImportTable(..) -> {
          use v <- result.map(import_var(imp_vars, p))
          #(
            mems,
            list.append(tables, [
              seam_call(link_module, "provided_table_value", [CVar(v)]),
            ]),
            nums,
            refs,
            p + 1,
            gidx,
          )
        }
        ir.ImportMemory(..) -> {
          use v <- result.map(import_var(imp_vars, p))
          #(
            list.append(mems, [
              seam_call(link_module, "provided_memory_value", [CVar(v)]),
            ]),
            tables,
            nums,
            refs,
            p + 1,
            gidx,
          )
        }
      }
    }),
  )
  #(mems, tables, nums, refs)
}

/// The positional import var `imp_vars[p]` (the `Imp<p>` destructured from `Imports`), or a
/// fail-closed `Error` if `p` is out of range (an internal codegen invariant — the count is baked
/// from the same import list).
fn import_var(imp_vars: List(String), p: Int) -> Result(String, EmitError) {
  nth(imp_vars, p)
  |> result.replace_error(UnsupportedNode("import_positional"))
}

/// The `rt_mem` handle-seed term for a DEFINED memory (§D/I4).
///
/// - `Idx32` → the BYTE-IDENTICAL Phase-5 `fresh(Min, MaxOpt, SafeCap)` head — a 32-bit memory's
///   seed is bit-for-bit unchanged (I7). This is also the exact term the `StateDecl` path inlines.
/// - `Idx64` → the memory64 `fresh64(Min, MaxOpt, Mem64Cap)` head (P6-08): a 64-bit-addressed memory
///   bounded by the documented, spec-aligned page cap `binding.mem64_max_pages` (2³² pages, S9). The
///   `paged` backend grows on demand, so the cap is a TRAP BOUNDARY, not a reservation. A module
///   with an `Idx64` memory routes through `FullDecl` (`needs_full_decl`), so this branch is reached.
fn mem_fresh_term(m: ir.MemoryDecl, ctx: Ctx) -> CExpr {
  case m.idx_type {
    ir.Idx32 ->
      seam_call(ctx.binding.mem_module, "fresh", [
        CInt(m.min_pages),
        option_int_term(m.max_pages),
        CInt(ctx.binding.safe_max_pages),
      ])
    ir.Idx64 ->
      seam_call(ctx.binding.mem_module, "fresh64", [
        CInt(m.min_pages),
        option_int_term(m.max_pages),
        CInt(ctx.binding.mem64_max_pages),
      ])
  }
}

/// The `rt_table:new(Min, MaxOpt)` term for a DEFINED table.
fn table_new_term(t: ir.TableDecl, ctx: Ctx) -> CExpr {
  seam_call(ctx.binding.table_module, "new", [
    CInt(t.min),
    option_int_term(t.max),
  ])
}

/// Does a constant-init expression READ another global? In a constant expression the only global
/// read is a `GlobalGet`, appearing either as the whole init or as the bound expr of a `Let` (the
/// shape a nested GC allocation with a `global.get` operand lowers to). Such a global cannot be
/// evaluated while BUILDING the seed decl (the instance cell is not installed yet) — it must be set
/// after `seed_full`, once its (preceding) referents are in the cell.
fn init_reads_global(expr: ir.Expr) -> Bool {
  case expr {
    ir.GlobalGet(_) -> True
    ir.Let(_, rhs, body) -> init_reads_global(rhs) || init_reads_global(body)
    _ -> False
  }
}

/// Split the DEFINED globals into the numeric `{<<name>>, Bits}` pairs (const-folded raw bits,
/// D5) and the reference `{<<name>>, Ref}` pairs (R8), threading `state` for funcref-closure
/// gensyms. When `defer` is set (the Cell posture — the only one that seeds via a self-installed
/// cell), a boxed global whose init READS another global is instead seeded with a null placeholder
/// and its real init returned as a ready-to-chain `ref_global_set` effect, to run in declaration
/// order AFTER `seed_full` (spec constant expressions read only PRECEDING immutable globals, so the
/// declaration-order sets always see their referents already installed). `Error(NonConstInit)` on a
/// non-constant init. Returns `#(numeric_pairs, reference_pairs, deferred_set_effects, state)`.
fn defined_globals(
  globals: List(ir.GlobalDecl),
  ctx: Ctx,
  state: EmitState,
  defer: Bool,
) -> Result(#(List(CExpr), List(CExpr), List(CExpr), EmitState), EmitError) {
  list.try_fold(globals, #([], [], [], state), fn(acc, g) {
    let #(nums, refs, deferred, st) = acc
    let name = core_binary_string(g.name)
    case is_boxed_global_type(g.ty) {
      True -> {
        use #(refval, st2) <- result.try(render_ref_global_init(g.init, ctx, st))
        case defer && init_reads_global(g.init) {
          True -> {
            let set_effect =
              seam_call(ctx.binding.state_module, "ref_global_set", [
                name,
                refval,
              ])
            Ok(#(
              nums,
              list.append(refs, [CTuple([name, null_ref_term()])]),
              list.append(deferred, [set_effect]),
              st2,
            ))
          }
          False ->
            Ok(#(
              nums,
              list.append(refs, [CTuple([name, refval])]),
              deferred,
              st2,
            ))
        }
      }
      False -> {
        use bits <- result.try(const_fold(g.init))
        Ok(#(
          list.append(nums, [CTuple([name, CInt(bits)])]),
          refs,
          deferred,
          st,
        ))
      }
    }
  })
}

/// Render a DEFINED boxed global's constant init to a Core boxed value for the `ref_globals` slot:
/// `ref.null` (`Values([ConstNull(_)])`) → the null sentinel (R8); `ref.func` (`RefFunc`) → the
/// `{TypeTag, Closure}` funcref entry (build-strategy ABI, R8); `v128.const`
/// (`Values([ConstV128(bytes)])`) → the raw 16-byte little-endian binary literal (S6/D5 — the
/// EXACT bytes, so lane values / NaN payloads / `-0.0` survive). `Error(NonConstInit)` for any
/// other init (e.g. an imported-global `global.get` — 09's resolution).
fn render_ref_global_init(
  init: Expr,
  ctx: Ctx,
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  case init {
    Values([ir.ConstNull(_)]) -> Ok(#(null_ref_term(), state))
    ir.RefFunc(name) -> reference_func_entry(name, ctx, state)
    // Phase-14 `RefFuncImport` (R14-02, F2): a reference GLOBAL initialised by an imported
    // `ref.func`. Well-defined and cheap — the SAME `#(TypeTag, adapter)` funcref value (§3.1c),
    // just stored in a global rather than a table slot. Completing it (decision F2, option (a))
    // means that after Phase 14 NO path skips as `UnknownFunction` from this gap — not just the
    // element path. Not exercised by `table_copy`, but closing it keeps the residual honest.
    ir.RefFuncImport(slot, ty) ->
      imported_reference_func_entry(slot, ty, ctx, state)
    Values([ir.ConstV128(bytes)]) -> Ok(#(core_binary_bytes(bytes), state))
    // A GC constant-expression global init (Phase-8 GC): a `ref.i31`/`struct.new`/`array.new*`
    // allocation, possibly a `Let`-chain of nested allocations. Evaluate it in-process via the
    // general emitter — `emit` yields the boxed arena handle `{gc,Id}`/`{i31,V}`. GC ops are
    // state-neutral (arena = process dictionary), so `NoState` is correct under cell AND threaded.
    Gc(_, _) | Let(_, _, _) -> emit(init, KReturn, NoState, state, ctx)
    _ -> Error(NonConstInit("non-constant reference global init"))
  }
}

/// The `Cell` `instantiate/0` (byte-identical to Phase 2/3): seed the pdict cell
/// (`rt_state:seed(Decl)` as a `let`-discard), write element → data segments, run `start`, and
/// return `'ok'`. Every step is a zero-result ordered effect chained with `chain_effects`.
fn emit_instantiate_cell(
  module: Module,
  ctx: Ctx,
) -> Result(FunDef, EmitError) {
  let state0 =
    EmitState(
      counter: 0,
      vars: set.new(),
      fns: set.from_list(dict.keys(ctx.fn_arity)),
      labels: [],
    )
  use #(decl_term, state1) <- result.try(state_decl_term(module, ctx, state0))
  let seed_effect = seam_call(ctx.binding.state_module, "seed", [decl_term])
  use #(elem_fx, state2) <- result.try(element_segment_effects(
    module.elements,
    ctx,
    state1,
  ))
  use #(data_fx, state3) <- result.try(data_segment_effects(
    module.data_segments,
    ctx,
    state2,
  ))
  use start_fx <- result.try(start_effects(module, ctx))
  let effects =
    list.flatten([
      seed_fuel_effect(ctx),
      seed_policy_effect(ctx),
      [seed_effect],
      elem_fx,
      data_fx,
      start_fx,
    ])
  let #(body, _state4) = chain_effects(effects, state3)
  Ok(FunDef(FName("instantiate", 0), CFun([], body)))
}

/// The `Threaded` `instantiate/0` (§E) — BUILDS and RETURNS the `InstanceState` record
/// instead of seeding the pdict. The body, in order:
///
/// - (0a/0b) `seed_fuel` (MeterFuel only) / `seed_policy` — UNCHANGED `let`-discards (metering
///   and the host boundary are pdict-seeded, orthogonal to state threading, F5/F4).
/// - (1) `St0 = call '<state>':'fresh'(Decl)` — the SAME `Decl` term the cell strategy passes
///   to `seed`, but its consumer is `fresh(Decl) -> InstanceState` (bound, not discarded), so a
///   `Threaded` and a `Cell` build start from byte-identical state (G7).
/// - (2) each active ELEMENT segment: `St' = case '<table>':'t_init_elem'(St, Off, Entries) of
///   {ok,S}->S; {error,E}->raise` — rebinds the record; `Entries` are the THREADED closures
///   (`fun(St, Args) -> {Results, St'}`, §C).
/// - (3) each active DATA segment: `St' = case '<mem>':'t_init_data'(St, Off, Bytes) of …`.
/// - (4) `start` (WASM `[]→[]`): a STATE-REACHING start threads
///   `{_, St'} = apply 'f<start>'/(a+1)(St)`; a PURE start is `apply 'f<start>'/a()` with the
///   record unchanged. Element BEFORE data BEFORE start (spec instantiation order); a
///   segment-OOB / trapping start raises and fails instantiation, abandoning the record.
/// - (5) RETURN the final `InstanceState` (not `'ok'`).
fn emit_instantiate_threaded(
  module: Module,
  ctx: Ctx,
) -> Result(FunDef, EmitError) {
  let state0 =
    EmitState(
      counter: 0,
      vars: set.new(),
      fns: set.from_list(dict.keys(ctx.fn_arity)),
      labels: [],
    )
  use #(decl_term, state1) <- result.try(state_decl_term(module, ctx, state0))
  // (0) The unchanged metering/host seed discards.
  let seed_effects =
    list.flatten([seed_fuel_effect(ctx), seed_policy_effect(ctx)])
  let #(seed_wraps, state2) = discard_wrappers(seed_effects, state1)
  // (1) St0 = fresh(Decl).
  let #(st0, state3) = fresh_var(state2)
  let fresh_wrap = fn(rest) {
    CLet([st0], seam_call(ctx.binding.state_module, "fresh", [decl_term]), rest)
  }
  // (2) element segments, (3) data segments, (4) start — each threading the record.
  use #(elem_wraps, cur1, state4) <- result.try(threaded_elem_wrappers(
    module.elements,
    st0,
    state3,
    ctx,
  ))
  use #(data_wraps, cur2, state5) <- result.try(threaded_data_wrappers(
    module.data_segments,
    cur1,
    state4,
    ctx,
  ))
  use #(start_wraps, cur3, _state6) <- result.try(threaded_start_wrapper(
    module,
    cur2,
    state5,
    ctx,
  ))
  // Assemble: seeds → fresh → element → data → start, wrapping the returned final record.
  let all_wraps =
    list.flatten([seed_wraps, [fresh_wrap], elem_wraps, data_wraps, start_wraps])
  let body =
    list.fold_right(all_wraps, CVar(cur3), fn(rest, wrap) { wrap(rest) })
  Ok(FunDef(FName("instantiate", 0), CFun([], body)))
}

/// Turn a list of zero-result seed effects into `let <g> = <effect> in …` wrappers, each with
/// a fresh discarded binder — the `seed_fuel`/`seed_policy` lines under threaded `instantiate`.
fn discard_wrappers(
  effects: List(CExpr),
  state: EmitState,
) -> #(List(fn(CExpr) -> CExpr), EmitState) {
  list.fold(effects, #([], state), fn(acc, effect) {
    let #(wraps, st) = acc
    let #(g, st2) = fresh_var(st)
    let wrap = fn(rest) { CLet([g], effect, rest) }
    #(list.append(wraps, [wrap]), st2)
  })
}

/// Build the threaded element-segment wrappers, threading the record from `cur`. Each active
/// segment produces `let St' = case '<table>':'t_init_elem'(St, Off, Entries) of {ok,S}->S;
/// {error,E}->raise in …` and advances the current state var. Returns the wrappers (in order),
/// the final state var, and the emit state. `Error(NonConstInit)` for a non-const offset;
/// `Error(UnknownFunction)` for an undefined element target.
fn threaded_elem_wrappers(
  segs: List(ir.ElementSegment),
  cur: String,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(List(fn(CExpr) -> CExpr), String, EmitState), EmitError) {
  list.try_fold(segs, #([], cur, state), fn(acc, seg) {
    let #(wraps, cur, st) = acc
    case seg.mode {
      ir.ElemActive(table, offset_expr) -> {
        use offset <- result.try(render_offset(offset_expr, Some(cur), ctx))
        let tidx = table_idx(ctx, table)
        use #(call, st2) <- result.try(case byte_ident_funcref(seg, tidx) {
          True -> {
            use funcs <- result.try(reffunc_names(seg.init))
            use #(entries, st2) <- result.try(build_threaded_entries(
              funcs,
              ctx,
              st,
            ))
            Ok(#(
              seam_call(ctx.binding.table_module, "t_init_elem", [
                CVar(cur),
                offset,
                core_list(entries),
              ]),
              st2,
            ))
          }
          False -> {
            // Threaded active seeding: a `global.get` item reads the live record `cur`.
            use #(refs, st2) <- result.try(render_ref_items(
              seg.init,
              ctx,
              Some(cur),
              st,
            ))
            Ok(#(
              seam_call(ctx.binding.table_module, "t_init_elem_ref", [
                CVar(cur),
                CInt(tidx),
                offset,
                core_list(refs),
              ]),
              st2,
            ))
          }
        })
        let #(reduced, st3) = record_result_case(call, ctx, st2)
        let #(newvar, st4) = fresh_var(st3)
        let wrap = fn(rest) { CLet([newvar], reduced, rest) }
        Ok(#(list.append(wraps, [wrap]), newvar, st4))
      }
      ir.ElemPassive | ir.ElemDeclarative -> Ok(#(wraps, cur, st))
    }
  })
}

/// Build the threaded data-segment wrappers, threading the record from `cur`. Each active
/// segment produces `let St' = case '<mem>':'t_init_data'(St, Off, Bytes) of {ok,S}->S;
/// {error,E}->raise in …`. `Error(NonConstInit)` for a non-const offset.
fn threaded_data_wrappers(
  segs: List(ir.DataSegment),
  cur: String,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(List(fn(CExpr) -> CExpr), String, EmitState), EmitError) {
  list.try_fold(segs, #([], cur, state), fn(acc, seg) {
    let #(wraps, cur, st) = acc
    case seg.mode {
      ir.DataActive(mem, offset_expr) -> {
        use offset <- result.try(render_offset(offset_expr, Some(cur), ctx))
        let call = case mem {
          0 ->
            seam_call(ctx.binding.mem_module, "t_init_data", [
              CVar(cur),
              offset,
              core_binary_bytes(seg.bytes),
            ])
          _ ->
            seam_call(ctx.binding.mem_module, "t_init_data_at", [
              CVar(cur),
              CInt(mem),
              offset,
              core_binary_bytes(seg.bytes),
            ])
        }
        let #(reduced, st2) = record_result_case(call, ctx, st)
        let #(newvar, st3) = fresh_var(st2)
        let wrap = fn(rest) { CLet([newvar], reduced, rest) }
        Ok(#(list.append(wraps, [wrap]), newvar, st3))
      }
      ir.DataPassive -> Ok(#(wraps, cur, st))
    }
  })
}

/// Build the threaded `start` wrapper (WASM `start` is `[]→[]`). A STATE-REACHING start
/// threads the record: `case apply 'f<start>'/(a+1)(St) of <{_, St'}> -> …` (the `'ok'`
/// package is discarded), advancing the current state var to `St'`. A PURE start is
/// `let _ = apply 'f<start>'/a() in …` with the record unchanged. No `start` → no wrapper.
/// `Error(UnknownFunction)` if `start` names no defined function.
fn threaded_start_wrapper(
  module: Module,
  cur: String,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(List(fn(CExpr) -> CExpr), String, EmitState), EmitError) {
  case module.start {
    None -> Ok(#([], cur, state))
    Some(name) ->
      case dict.get(ctx.fn_arity, name) {
        Error(_) -> Error(UnknownFunction(name))
        Ok(arity) ->
          case set.contains(ctx.fn_state_reaching, name) {
            True -> {
              let applied = CApply(FName(name, arity + 1), [CVar(cur)])
              let #(wildvar, state2) = fresh_var(state)
              let #(newvar, state3) = fresh_var(state2)
              let wrap = fn(rest) {
                CCase(applied, [
                  CClause(
                    [PTuple([PVar(wildvar), PVar(newvar)])],
                    CAtom("true"),
                    rest,
                  ),
                ])
              }
              Ok(#([wrap], newvar, state3))
            }
            False -> {
              let applied = CApply(FName(name, arity), [])
              let #(wildvar, state2) = fresh_var(state)
              let wrap = fn(rest) { CLet([wildvar], applied, rest) }
              Ok(#([wrap], cur, state2))
            }
          }
      }
  }
}

/// Build the threaded `{TypeTag, Closure}` entry list for an element segment's `funcs`.
fn build_threaded_entries(
  funcs: List(String),
  ctx: Ctx,
  state: EmitState,
) -> Result(#(List(CExpr), EmitState), EmitError) {
  list.try_fold(funcs, #([], state), fn(acc, fname) {
    let #(entries, st) = acc
    use #(entry, st2) <- result.try(threaded_element_entry(fname, ctx, st))
    Ok(#(list.append(entries, [entry]), st2))
  })
}

/// One THREADED element-segment entry `{TypeTag, Closure}`: the function's IR `FuncType` (the
/// SAME `func_type_term` renderer the call site uses, so `rt_table`'s type guard matches)
/// paired with a threaded closure over the compile-time-fixed target name.
/// `Error(UnknownFunction)` if `fname` is not defined.
fn threaded_element_entry(
  fname: String,
  ctx: Ctx,
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  case dict.get(ctx.fn_sig, fname) {
    Error(_) -> Error(UnknownFunction(fname))
    Ok(sig) -> {
      let arity = result.unwrap(dict.get(ctx.fn_arity, fname), 0)
      let reaching = set.contains(ctx.fn_state_reaching, fname)
      let #(closure, state2) =
        threaded_element_closure(fname, arity, reaching, state)
      Ok(#(CTuple([func_type_term(sig), closure]), state2))
    }
  }
}

/// A build-controlled THREADED element-segment closure `fun(St, ArgsList) -> {Package, St'}` —
/// PACKAGE-ABI and TAIL-TRANSPARENT (Phase-13, overview §2 ⚠ ABI reconciliation note). Matches the
/// funcref threaded ABI `fn(InstanceState, List(Int)) -> #(Dynamic, InstanceState)`. Unpacks
/// `ArgsList` to the target's static `arity`, then:
/// - PURE target: `{apply 'f'/n(args…), St}` — the callee's package paired with `St` threaded
///   through UNTOUCHED (a pure callee cannot tail-recurse back through a state-reaching frame, so
///   the non-tail tuple position is bounded, §3.2).
/// - STATE-REACHING target: a BARE `apply 'f'/(n+1)(St, args…)` in TAIL position — `f/(n+1)` returns
///   `{Package, St'}` DIRECTLY, exactly this closure's return shape, so the tail apply through
///   `t_call_indirect_lookup` is a real BEAM tail call in constant stack.
/// Always a static `apply` of a COMPILE-TIME-LITERAL name — `St` is a parameter, never a dispatch
/// key (D3a). The non-tail `t_call_indirect*` re-wraps the package back into the result list.
fn threaded_element_closure(
  fname: String,
  arity: Int,
  reaching: Bool,
  state: EmitState,
) -> #(CExpr, EmitState) {
  let #(stvar, state1) = fresh_var(state)
  let #(argsvar, state2) = fresh_var(state1)
  let #(argnames, state3) = fresh_n_vars(state2, arity)
  case reaching {
    False -> {
      let applied = CApply(FName(fname, arity), list.map(argnames, CVar))
      let paired = CTuple([applied, CVar(stvar)])
      let body = wrap_args_case(argsvar, arity, argnames, paired)
      #(CFun([stvar, argsvar], body), state3)
    }
    True -> {
      let applied =
        CApply(FName(fname, arity + 1), [
          CVar(stvar),
          ..list.map(argnames, CVar)
        ])
      let body = wrap_args_case(argsvar, arity, argnames, applied)
      #(CFun([stvar, argsvar], body), state3)
    }
  }
}

/// Wrap `inner` in the args-list unpack for an element closure: `case ArgsList of <[A0,…]> ->
/// inner` (or `inner` verbatim for a 0-arity target, whose args list is the empty `[]`).
fn wrap_args_case(
  argsvar: String,
  arity: Int,
  argnames: List(String),
  inner: CExpr,
) -> CExpr {
  case arity {
    0 -> inner
    _ ->
      CCase(CVar(argsvar), [
        CClause([list_pattern(argnames)], CAtom("true"), inner),
      ])
  }
}

/// The `rt_meter:seed_fuel(binding.fuel_budget)` per-instance seed — `[seam_call…]` under
/// `MeterFuel` (arming the fail-closed CPU bound, F5), or `[]` under `MeterOff` (no `Charge`
/// sites to bound, so no seed — the F5 zero-overhead posture). `fuel_budget` is baked as a
/// Core integer literal. Emitted as `instantiate/0`'s first effect.
fn seed_fuel_effect(ctx: Ctx) -> List(CExpr) {
  case ctx.binding.meter {
    MeterFuel -> [
      seam_call(ctx.binding.meter_module, "seed_fuel", [
        CInt(ctx.binding.fuel_budget),
      ]),
    ]
    MeterOff -> []
  }
}

/// The `rt_host:seed_policy(binding.host_policy)` per-instance seed — ALWAYS emitted (F4).
/// The `host_policy` is baked as a Core Erlang literal via `host_policy_term`. A fixed
/// `host_module` call, so it adds no ambient authority (D3a).
fn seed_policy_effect(ctx: Ctx) -> List(CExpr) {
  [
    seam_call(ctx.binding.host_module, "seed_policy", [
      host_policy_term(ctx.binding.host_policy),
    ]),
  ]
}

/// Render a `HostPolicy` as the Core Erlang literal Gleam compiles it to — the term
/// `rt_host:seed_policy`/`current_policy` round-trips (rt_host §): `HostDenyAll` → the atom
/// `'host_deny_all'`, `HostOpen` → `'host_open'`, `HostWhitelist(allow)` →
/// `{'host_whitelist', [{<<Cap>>, <<Name>>}…]}` (each string a BEAM binary). Build-controlled
/// (from `binding.host_policy`) — NEVER derived from program data (D3a). Total.
fn host_policy_term(policy: HostPolicy) -> CExpr {
  case policy {
    HostDenyAll -> CAtom("host_deny_all")
    HostOpen -> CAtom("host_open")
    HostWhitelist(allow) ->
      CTuple([
        CAtom("host_whitelist"),
        core_list(
          list.map(allow, fn(pair) {
            let #(cap, name) = pair
            CTuple([core_binary_string(cap), core_binary_string(name)])
          }),
        ),
      ])
  }
}

/// Sequence a list of zero-result ordered effects into nested `let <g> = <effect> in …`,
/// ending in `'ok'`. Each `let` is strict, so every effect runs in order (non-DCE, E6); the
/// discarded binders are fresh wildcards.
fn chain_effects(
  effects: List(CExpr),
  state: EmitState,
) -> #(CExpr, EmitState) {
  case effects {
    [] -> #(CAtom("ok"), state)
    [e, ..rest] -> {
      let #(g, state2) = fresh_var(state)
      let #(tail, state3) = chain_effects(rest, state2)
      #(CLet([g], e, tail), state3)
    }
  }
}

/// Build the `StateDecl` Core TERM seed passed to `rt_state:seed` — the Gleam record
/// `StateDecl(mem, globals, table)` compiles to `{state_decl, Mem, Globals, Table}`:
/// `Mem = rt_mem:fresh(MinPages, MaxOpt, SafeCap)` (a 0-page memory when the module declares
/// none), `Table = rt_table:new(Min, MaxOpt)` (the first declared table, or an empty one),
/// `Globals = [{NameBin, InitBits}…]`. `SafeCap` is the build-time `binding.safe_max_pages`.
fn state_decl_term(
  module: Module,
  ctx: Ctx,
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  // The FIRST (index-0) memory's sizing. KEYSTONE: a single 32-bit memory emits the same
  // `rt_mem:fresh(Min, Max, Cap)` call as Phase-4 (byte-identical); the multi-memory vector
  // seed (index 1+) is P5-06/09's. `[]` (numerics-only) → a 0-page memory, unchanged.
  let #(min_pages, mem_max) = case module.memories {
    [m, ..] -> #(m.min_pages, option_int_term(m.max_pages))
    [] -> #(0, CAtom("none"))
  }
  let mem =
    seam_call(ctx.binding.mem_module, "fresh", [
      CInt(min_pages),
      mem_max,
      CInt(ctx.binding.safe_max_pages),
    ])
  let table = case module.tables {
    [t, ..] ->
      seam_call(ctx.binding.table_module, "new", [
        CInt(t.min),
        option_int_term(t.max),
      ])
    [] -> seam_call(ctx.binding.table_module, "new", [CInt(0), CAtom("none")])
  }
  use globals <- result.try(global_pairs(module.globals))
  Ok(#(CTuple([CAtom("state_decl"), mem, globals, table]), state))
}

/// The `[{NameBin, InitBits}…]` Core list of a module's globals — each `GlobalDecl.init`
/// constant-folded to a bit pattern. `Error(NonConstInit)` if any init is non-constant.
fn global_pairs(globals: List(ir.GlobalDecl)) -> Result(CExpr, EmitError) {
  use pairs <- result.try(
    list.try_map(globals, fn(g) {
      use bits <- result.try(const_fold(g.init))
      Ok(CTuple([core_binary_string(g.name), CInt(bits)]))
    }),
  )
  Ok(core_list(pairs))
}

/// Render an `Option(Int)` as a Core term — `Some(n)` → `{some, n}`, `None` → `none` (the
/// Gleam `Option` runtime shape `rt_mem.fresh` / `rt_table.new` expect for `max`).
fn option_int_term(o: Option(Int)) -> CExpr {
  case o {
    Some(n) -> CTuple([CAtom("some"), CInt(n)])
    None -> CAtom("none")
  }
}

/// Build the ordered element-seeding effects for the ACTIVE element segments (passive /
/// declarative segments carry no instantiation write — R2 — and are SKIPPED). A funcref-only,
/// all-`RefFunc`, table-0 active segment takes the byte-identical Phase-4 `init_elem(Off,
/// Entries)` fast path (H7); any other active segment (externref, a `ref.null` slot, or a
/// non-zero table) routes through `init_elem_ref(TblIdx, Off, Refs)`. Each is reduced to a
/// discardable trapping effect (`{ok,_}`→`'ok'`, `{error,E}`→raise).
fn element_segment_effects(
  segs: List(ir.ElementSegment),
  ctx: Ctx,
  state: EmitState,
) -> Result(#(List(CExpr), EmitState), EmitError) {
  list.try_fold(segs, #([], state), fn(acc, seg) {
    let #(effects, st) = acc
    case seg.mode {
      ir.ElemActive(table, offset_expr) -> {
        use offset <- result.try(render_offset(offset_expr, None, ctx))
        let tidx = table_idx(ctx, table)
        use #(call, st2) <- result.try(case byte_ident_funcref(seg, tidx) {
          True -> {
            use funcs <- result.try(reffunc_names(seg.init))
            use #(entries, st2) <- result.try(build_entries(funcs, ctx, st))
            Ok(#(
              seam_call(ctx.binding.table_module, "init_elem", [
                offset,
                core_list(entries),
              ]),
              st2,
            ))
          }
          False -> {
            // Cell active seeding: a `global.get` item reads the already-seeded pdict cell (None).
            use #(refs, st2) <- result.try(render_ref_items(
              seg.init,
              ctx,
              None,
              st,
            ))
            Ok(#(
              seam_call(ctx.binding.table_module, "init_elem_ref", [
                CInt(tidx),
                offset,
                core_list(refs),
              ]),
              st2,
            ))
          }
        })
        let #(effect, st3) = trapping_effect(call, ctx, st2)
        Ok(#(list.append(effects, [effect]), st3))
      }
      ir.ElemPassive | ir.ElemDeclarative -> Ok(#(effects, st))
    }
  })
}

/// `True` iff active element segment `seg` targeting table index `tidx` is the byte-identical
/// Phase-4 shape: a `FuncRef` table-0 segment whose every init item is a `RefFunc` (so it seeds
/// through the frozen `init_elem`/`t_init_elem` fast path). Any other active segment routes
/// through the generalised `init_elem_ref`/`t_init_elem_ref` (arbitrary references, any table).
fn byte_ident_funcref(seg: ir.ElementSegment, tidx: Int) -> Bool {
  seg.ref_ty == ir.FuncRef && tidx == 0 && all_reffunc(seg.init)
}

/// `True` iff every element-init item is a `RefFunc` (the Phase-2 funcidx-only shape) — the gate
/// that keeps a pure-defined table-0 segment on the frozen `init_elem` fast path (byte-identical,
/// R5). An IMPORTED `ref.func` (`RefFuncImport`, Phase-14 R1) is DELIBERATELY not-plain: it returns
/// `False` (explicit arm, regression-proof against a future maintainer widening the `True` arm) so
/// any segment carrying one routes through the general `init_elem_ref` path → `render_ref_item`'s
/// `RefFuncImport` arm, where the D3a adapter closure is built.
fn all_reffunc(items: List(Expr)) -> Bool {
  list.all(items, fn(it) {
    case it {
      ir.RefFunc(_) -> True
      // Imported ref.func is NOT the plain Phase-2 shape: route the segment through
      // `init_elem_ref` (R1/R5), never the frozen defined-only `init_elem` fast path.
      ir.RefFuncImport(_, _) -> False
      _ -> False
    }
  })
}

/// The `RefFunc` target names of an all-`RefFunc` init list. `Error(UnsupportedNode)` if any
/// item is not a `RefFunc` (unreachable when `byte_ident_funcref` gated the call).
fn reffunc_names(items: List(Expr)) -> Result(List(String), EmitError) {
  list.try_map(items, fn(it) {
    case it {
      ir.RefFunc(n) -> Ok(n)
      _ -> Error(UnsupportedNode("elem_item"))
    }
  })
}

/// Build the `{TypeTag, Closure}` entry list for an element segment's `funcs`.
fn build_entries(
  funcs: List(String),
  ctx: Ctx,
  state: EmitState,
) -> Result(#(List(CExpr), EmitState), EmitError) {
  list.try_fold(funcs, #([], state), fn(acc, fname) {
    let #(entries, st) = acc
    use #(entry, st2) <- result.try(element_entry(fname, ctx, st))
    Ok(#(list.append(entries, [entry]), st2))
  })
}

/// One element-segment entry `{TypeTag, Closure}`: the function's IR `FuncType` (via the
/// SAME `func_type_term` renderer the call site uses, so `rt_table`'s guard 3 matches) paired
/// with a build-controlled closure over its compile-time-fixed module-local name (§3 —
/// the integer index is the only runtime data; the function name is a literal).
/// `Error(UnknownFunction)` if `fname` is not a defined function.
fn element_entry(
  fname: String,
  ctx: Ctx,
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  case dict.get(ctx.fn_sig, fname) {
    Error(_) -> Error(UnknownFunction(fname))
    Ok(sig) -> {
      let arity = result.unwrap(dict.get(ctx.fn_arity, fname), 0)
      let #(closure, state2) = element_closure(fname, arity, state)
      Ok(#(CTuple([func_type_term(sig), closure]), state2))
    }
  }
}

/// A build-controlled element-segment closure `fun(Args) -> Package` — PACKAGE-ABI and
/// TAIL-TRANSPARENT (Phase-13, overview §2 ⚠ ABI reconciliation note). Its body unpacks the args
/// list to the function's static `arity`, then a BARE `apply 'f<idx>'/arity(<args>)` in TAIL
/// position, returning `f`'s `function_return` package DIRECTLY (bare `v` for one result, `'ok'`
/// for zero, a tuple for `N≥2`) — NOT re-wrapped into a list. This is what lets
/// `rt_table.call_indirect_lookup`'s returned target tail-apply into the caller's package
/// (constant stack); the non-tail `call_indirect*` family re-wraps the package back into the result
/// list inside `rt_table` (`package_to_list`). Never a data-driven `apply` (D3a).
fn element_closure(
  fname: String,
  arity: Int,
  state: EmitState,
) -> #(CExpr, EmitState) {
  let #(argsvar, state1) = fresh_var(state)
  let #(argnames, state2) = fresh_n_vars(state1, arity)
  let applied = CApply(FName(fname, arity), list.map(argnames, CVar))
  let body = case arity {
    0 -> applied
    _ ->
      CCase(CVar(argsvar), [
        CClause([list_pattern(argnames)], CAtom("true"), applied),
      ])
  }
  #(CFun([argsvar], body), state2)
}

/// Build the ordered data-seeding effects for the ACTIVE data segments (passive segments carry
/// no instantiation write — R2 — and are SKIPPED). A memory-0 active segment takes the
/// byte-identical Phase-4 `init_data(Off, Bytes)` head (H7); a memory-`>=1` active segment routes
/// through `init_data_at(MemIdx, Off, Bytes)`. Each →
/// `case call '<mem_module>':'init_data…'(…) of {ok,_}->'ok'; {error,E}->raise`.
fn data_segment_effects(
  segs: List(ir.DataSegment),
  ctx: Ctx,
  state: EmitState,
) -> Result(#(List(CExpr), EmitState), EmitError) {
  list.try_fold(segs, #([], state), fn(acc, seg) {
    let #(effects, st) = acc
    case seg.mode {
      ir.DataActive(mem, offset_expr) -> {
        use offset <- result.try(render_offset(offset_expr, None, ctx))
        let call = case mem {
          0 ->
            seam_call(ctx.binding.mem_module, "init_data", [
              offset,
              core_binary_bytes(seg.bytes),
            ])
          _ ->
            seam_call(ctx.binding.mem_module, "init_data_at", [
              CInt(mem),
              offset,
              core_binary_bytes(seg.bytes),
            ])
        }
        let #(effect, st2) = trapping_effect(call, ctx, st)
        Ok(#(list.append(effects, [effect]), st2))
      }
      ir.DataPassive -> Ok(#(effects, st))
    }
  })
}

/// The `start` effect (if any): `apply 'f<idx>'/0()` — a trap inside it propagates (raises)
/// and fails instantiation. `Error(UnknownFunction)` if `start` names no defined function.
fn start_effects(module: Module, ctx: Ctx) -> Result(List(CExpr), EmitError) {
  case module.start {
    None -> Ok([])
    Some(name) ->
      case dict.get(ctx.fn_arity, name) {
        Error(_) -> Error(UnknownFunction(name))
        Ok(arity) -> Ok([CApply(FName(name, arity), [])])
      }
  }
}

/// Render an active segment's OFFSET const-expr to the Core i32 offset the `init_*` seam takes.
///
/// A constant literal (`Values([Const])`) const-folds to its raw-bit `CInt` — BYTE-IDENTICAL to
/// Phase-4 (a numeric offset never changed). A `global.get $g` (an imported / defined IMMUTABLE i32
/// global, a valid constant expression, spec §3.3.1 / §4.5.4) is resolved at instantiate time by a
/// RUNTIME read of the seeded numeric global: `Cell` (`state_ref == None`) reads the pdict cell via
/// `rt_state:global_get(<<name>>)`, `Threaded` (`Some(st)`) reads the live record via
/// `rt_state:t_global_get(St, <<name>>)`. Because the seed installs the (imported) global BEFORE any
/// active segment runs, the read yields the exact provided value (e.g. an OOB active-data offset
/// then traps at instantiation, spec §4.5.4). `Error(NonConstInit)` for any other shape.
fn render_offset(
  offset_expr: Expr,
  state_ref: Option(String),
  ctx: Ctx,
) -> Result(CExpr, EmitError) {
  case offset_expr {
    GlobalGet(name) ->
      Ok(case state_ref {
        None ->
          seam_call(ctx.binding.state_module, "global_get", [
            core_binary_string(name),
          ])
        Some(st) ->
          seam_call(ctx.binding.state_module, "t_global_get", [
            CVar(st),
            core_binary_string(name),
          ])
      })
    _ -> result.map(const_fold(offset_expr), CInt)
  }
}

/// Constant-fold a Phase-2 constant-literal init/offset `Expr` (`Values([Const])`) to its
/// raw bit-pattern `Int`. `Error(NonConstInit)` for any non-constant shape (e.g. an
/// imported-global `GlobalGet`, an extended-const chain, or a multi-value form) — fail-
/// closed, never a panic, never arbitrary emitted code in the seed decl.
fn const_fold(expr: Expr) -> Result(Int, EmitError) {
  case expr {
    Values([v]) -> const_value_bits(v)
    _ -> Error(NonConstInit("non-constant init/offset expression"))
  }
}

/// The raw bit pattern of a constant `Value`; `Error(NonConstInit)` for a `Var` (a
/// non-constant operand).
fn const_value_bits(v: Value) -> Result(Int, EmitError) {
  case v {
    ConstI32(b) | ConstI64(b) | ConstF32(b) | ConstF64(b) -> Ok(b)
    Var(_) -> Error(NonConstInit("variable in constant init/offset"))
    // A reference-typed constant init (`ref.null`) has no numeric bit pattern; its seeding is
    // P5-06/09's (a `ConstNull` never appears in a Phase-1..4 numeric offset/init).
    ir.ConstNull(_) ->
      Error(NonConstInit("null reference in constant init/offset"))
    // A `v128` constant is a 16-byte binary, not a scalar `Int`, so it has no numeric bit
    // pattern for a memory offset/numeric-global seed; a v128 GLOBAL is a boxed `Dynamic`
    // seeded via `ref_globals` (S6, P6-06/08/09), never through this numeric path.
    ir.ConstV128(_) ->
      Error(NonConstInit("v128 constant in numeric constant init/offset"))
    // Phase-8 term literals (K2) are boxed BEAM terms, not scalar `Int`s, so they have no
    // numeric bit pattern for a memory offset / numeric-global seed; they never appear in a
    // WASM numeric const init (K7). Fail-closed like `ConstNull`/`ConstV128`.
    ir.ConstAtom(_) ->
      Error(NonConstInit("atom constant in numeric constant init/offset"))
    ir.ConstBinary(_) ->
      Error(NonConstInit("binary constant in numeric constant init/offset"))
    // A native float term is a boxed BEAM double, not a scalar bit pattern; like the other term
    // literals it never appears in a WASM numeric const init (K7). Fail-closed.
    ir.ConstFloatTerm(_) ->
      Error(NonConstInit("float term constant in numeric constant init/offset"))
  }
}

// ─────────────────────────────── the NumOp → rt_num name table ───────────────────────────────

/// Map a `NumOp` to its `rt_num` function name (the chokepoint table; MUST match the
/// frozen `rt_num` signatures). Names are `i{32|64}_<op>` / `f{32|64}_<op>` where `<op>`
/// is the snake_case suffix (`add`, `div_s`, `shr_u`, `lt_u`, …). Total — every `NumOp`
/// constructor is mapped.
pub fn num_op_name(op: NumOp) -> String {
  case op {
    IAdd(w) -> iw(w) <> "_add"
    ISub(w) -> iw(w) <> "_sub"
    IMul(w) -> iw(w) <> "_mul"
    IDivS(w) -> iw(w) <> "_div_s"
    IDivU(w) -> iw(w) <> "_div_u"
    IRemS(w) -> iw(w) <> "_rem_s"
    IRemU(w) -> iw(w) <> "_rem_u"
    IAnd(w) -> iw(w) <> "_and"
    IOr(w) -> iw(w) <> "_or"
    IXor(w) -> iw(w) <> "_xor"
    IShl(w) -> iw(w) <> "_shl"
    IShrS(w) -> iw(w) <> "_shr_s"
    IShrU(w) -> iw(w) <> "_shr_u"
    IRotl(w) -> iw(w) <> "_rotl"
    IRotr(w) -> iw(w) <> "_rotr"
    IClz(w) -> iw(w) <> "_clz"
    ICtz(w) -> iw(w) <> "_ctz"
    IPopcnt(w) -> iw(w) <> "_popcnt"
    IEqz(w) -> iw(w) <> "_eqz"
    IEq(w) -> iw(w) <> "_eq"
    INe(w) -> iw(w) <> "_ne"
    ILtS(w) -> iw(w) <> "_lt_s"
    ILtU(w) -> iw(w) <> "_lt_u"
    IGtS(w) -> iw(w) <> "_gt_s"
    IGtU(w) -> iw(w) <> "_gt_u"
    ILeS(w) -> iw(w) <> "_le_s"
    ILeU(w) -> iw(w) <> "_le_u"
    IGeS(w) -> iw(w) <> "_ge_s"
    IGeU(w) -> iw(w) <> "_ge_u"
    FAdd(f) -> fw(f) <> "_add"
    FSub(f) -> fw(f) <> "_sub"
    FMul(f) -> fw(f) <> "_mul"
    FDiv(f) -> fw(f) <> "_div"
    FMin(f) -> fw(f) <> "_min"
    FMax(f) -> fw(f) <> "_max"
    // Phase-2 float NumOps (`«RTNUM2-SIG-FROZEN»`) — all TOTAL (stay out of `is_trapping`).
    // Unary/copysign produce the width's float bits; the 6 comparisons produce an i32 0/1.
    FAbs(f) -> fw(f) <> "_abs"
    FNeg(f) -> fw(f) <> "_neg"
    FCeil(f) -> fw(f) <> "_ceil"
    FFloor(f) -> fw(f) <> "_floor"
    FTrunc(f) -> fw(f) <> "_trunc"
    FNearest(f) -> fw(f) <> "_nearest"
    FSqrt(f) -> fw(f) <> "_sqrt"
    FCopysign(f) -> fw(f) <> "_copysign"
    FEq(f) -> fw(f) <> "_eq"
    FNe(f) -> fw(f) <> "_ne"
    FLt(f) -> fw(f) <> "_lt"
    FGt(f) -> fw(f) <> "_gt"
    FLe(f) -> fw(f) <> "_le"
    FGe(f) -> fw(f) <> "_ge"
  }
}

/// `True` for the four trapping ops (`div`/`rem`, signed/unsigned) — those return
/// `Result(Int, TrapReason)` and need the `case`-and-`raise` lowering. All other ops
/// return a bare `Int`.
fn is_trapping(op: NumOp) -> Bool {
  case op {
    IDivS(_) | IDivU(_) | IRemS(_) | IRemU(_) -> True
    _ -> False
  }
}

/// Map a `ConvOp` to its `rt_num` function name. Every conversion that is a genuine numeric
/// value transform maps to `Ok(name)`. The four term↔numeric boxing conversions
/// (`BoxInt`/`UnboxInt`/`BoxFloat`/`UnboxFloat`) have NO `num_module` function — they are a
/// pure value pass-through — and are intercepted by `is_boxing_conv` in `emit_convert` BEFORE
/// this function is reached; their `Error(_)` arms below are therefore dead, retained only to
/// keep the `case` exhaustive.
fn conv_op_name(op: ConvOp) -> Result(String, String) {
  case op {
    I32WrapI64 -> Ok("i32_wrap_i64")
    I64ExtendI32S -> Ok("i64_extend_i32_s")
    I64ExtendI32U -> Ok("i64_extend_i32_u")
    I32Extend8S -> Ok("i32_extend8_s")
    I32Extend16S -> Ok("i32_extend16_s")
    I64Extend8S -> Ok("i64_extend8_s")
    I64Extend16S -> Ok("i64_extend16_s")
    I64Extend32S -> Ok("i64_extend32_s")
    TruncSatS(from, to) -> Ok(iw(to) <> "_trunc_sat_f" <> fwn(from) <> "_s")
    TruncSatU(from, to) -> Ok(iw(to) <> "_trunc_sat_f" <> fwn(from) <> "_u")
    ReinterpretFToI(FW32) -> Ok("i32_reinterpret_f32")
    ReinterpretFToI(FW64) -> Ok("i64_reinterpret_f64")
    ReinterpretIToF(W32) -> Ok("f32_reinterpret_i32")
    ReinterpretIToF(W64) -> Ok("f64_reinterpret_i64")
    BoxInt(_) -> Error("box_int")
    UnboxInt(_) -> Error("unbox_int")
    BoxFloat(_) -> Error("box_float")
    UnboxFloat(_) -> Error("unbox_float")
    // Phase-2 ConvOps (`«RTNUM2-SIG-FROZEN»`). TRAPPING float→int truncation
    // (`i{to}_trunc_f{from}_{s,u}`) — `emit_convert` routes these through the
    // `case`-and-`raise` shape (see `is_trapping_conv`), NOT a bare call.
    TruncS(from, to) -> Ok(iw(to) <> "_trunc_f" <> fwn(from) <> "_s")
    TruncU(from, to) -> Ok(iw(to) <> "_trunc_f" <> fwn(from) <> "_u")
    // int→float conversion + float width change — all TOTAL (bare call, never trap).
    ConvertS(from, to) -> Ok(fw(to) <> "_convert_" <> iw(from) <> "_s")
    ConvertU(from, to) -> Ok(fw(to) <> "_convert_" <> iw(from) <> "_u")
    F32DemoteF64 -> Ok("f32_demote_f64")
    F64PromoteF32 -> Ok("f64_promote_f32")
  }
}

/// `True` for the TRAPPING float→int truncations (`TruncS`/`TruncU`) — those return
/// `Result(Int, TrapReason)` (trap `InvalidConversionToInteger` on NaN/±Inf,
/// `IntOverflow` out of range) and need the `case`-and-`raise` lowering. Every other
/// `ConvOp` is total (a bare `call`). Getting this wrong either drops a mandated trap or
/// wraps a total op in a spurious `case` (unit-10 grounded fact).
fn is_trapping_conv(op: ConvOp) -> Bool {
  case op {
    TruncS(_, _) | TruncU(_, _) -> True
    _ -> False
  }
}

/// The integer-op module/name prefix for a width (`"i32"` / `"i64"`).
fn iw(w: IntWidth) -> String {
  case w {
    W32 -> "i32"
    W64 -> "i64"
  }
}

/// The float-op module/name prefix for a width (`"f32"` / `"f64"`).
fn fw(f: ir.FloatWidth) -> String {
  case f {
    FW32 -> "f32"
    FW64 -> "f64"
  }
}

/// The bare width number of a float width (`"32"` / `"64"`), for composing trunc_sat names.
fn fwn(f: ir.FloatWidth) -> String {
  case f {
    FW32 -> "32"
    FW64 -> "64"
  }
}

// ─────────────────────────────── trap-atom wrapper (fact 2) ───────────────────────────────

/// The Erlang atom a `TrapReason` becomes — exactly how Gleam compiles its 0-field
/// constructor (PascalCase → snake_case), e.g. `IntDivByZero` → `"int_div_by_zero"`.
/// Generated code passes this atom to `rt_trap:raise/1`. Total — covers every constructor.
pub fn trap_reason_atom(reason: TrapReason) -> String {
  pascal_to_snake(trap_ctor_name(reason))
}

/// The PascalCase source spelling of a `TrapReason` constructor (the input to
/// `pascal_to_snake`). Kept explicit because Gleam has no constructor reflection.
fn trap_ctor_name(reason: TrapReason) -> String {
  case reason {
    IntDivByZero -> "IntDivByZero"
    IntOverflow -> "IntOverflow"
    Unreachable -> "Unreachable"
    IndirectCallTypeMismatch -> "IndirectCallTypeMismatch"
    MemoryOutOfBounds -> "MemoryOutOfBounds"
    InvalidConversionToInteger -> "InvalidConversionToInteger"
    UndefinedElement -> "UndefinedElement"
    UninitializedElement -> "UninitializedElement"
    TableOutOfBounds -> "TableOutOfBounds"
    // Runtime-only policy reason (F5); never emitted by lowering, but the match is exhaustive.
    FuelExhausted -> "FuelExhausted"
    // WasmGC traps (this proposal).
    CastFailure -> "CastFailure"
    NullReference -> "NullReference"
    ArrayOutOfBounds -> "ArrayOutOfBounds"
  }
}

/// Convert a PascalCase identifier to snake_case — the transformation Gleam's compiler
/// applies to a 0-field constructor to derive its runtime atom (verified fact 2). Each
/// uppercase letter after the first is prefixed with `_`, then the whole string is
/// lowercased: `"IntDivByZero"` → `"int_div_by_zero"`. Total; never panics.
pub fn pascal_to_snake(name: String) -> String {
  string.to_utf_codepoints(name)
  |> list.index_map(fn(cp, i) {
    let c = string.utf_codepoint_to_int(cp)
    let s = string.from_utf_codepoints([cp])
    case i > 0 && c >= 65 && c <= 90 {
      True -> "_" <> s
      False -> s
    }
  })
  |> string.concat
  |> string.lowercase
}

// ─────────────────────────────── gensym reservation scan ───────────────────────────────

/// Collect every variable name present in `f` (params, locals, `Let`/loop binders, and all
/// `Value` references) so gensym can avoid colliding with any of them. Over-approximating
/// is safe; the set is only used to keep generated variable tokens unique.
fn collect_vars(f: Function) -> Set(String) {
  let base =
    list.fold(f.params, set.new(), fn(acc, l) { set.insert(acc, l.name) })
  let base = list.fold(f.locals, base, fn(acc, l) { set.insert(acc, l.name) })
  collect_expr(f.body, base)
}

/// Accumulate variable names appearing in `expr` into `acc`.
fn collect_expr(expr: Expr, acc: Set(String)) -> Set(String) {
  case expr {
    Values(vs) -> collect_values(vs, acc)
    Return(vs) -> collect_values(vs, acc)
    Num(_, args) -> collect_values(args, acc)
    Convert(_, arg) -> collect_value(arg, acc)
    TermOp(_, args) -> collect_values(args, acc)
    Gc(_, args) -> collect_values(args, acc)
    // ── Phase-8 native closures: collect the `Var` names in their `Value` operands (the captures /
    // the callee + args) so gensym avoids them. `MakeClosure`'s `fn_name` is a function name, not a
    // `Var`. Over-approximating is safe. ──
    MakeClosure(_, captures, _) -> collect_values(captures, acc)
    CallClosure(callee, args) ->
      collect_values(args, collect_value(callee, acc))
    // ── Phase-8 map layer: collect the `Var` names in the map op's `Value` operands so gensym
    // avoids them (over-approximating is safe). ──
    MapOp(_, args) -> collect_values(args, acc)
    // ── Phase-8 term classification + native number arithmetic (unit 06): collect the `Var` names
    // in their `Value` operands (the `kind`/`op` are static). Over-approximating is safe. ──
    ir.TermTest(_, arg) -> collect_value(arg, acc)
    ir.TermTag(arg) -> collect_value(arg, acc)
    ir.NumTerm(_, lhs, rhs) -> collect_value(rhs, collect_value(lhs, acc))
    MemSize(_) -> acc
    MemGrow(_, delta) -> collect_value(delta, acc)
    MemLoad(_, _, addr, _, _) -> collect_value(addr, acc)
    MemStore(_, _, addr, value, _) ->
      collect_value(value, collect_value(addr, acc))
    ir.MemLoadUnchecked(_, _, addr, _, _) -> collect_value(addr, acc)
    ir.MemStoreUnchecked(_, _, addr, value, _) ->
      collect_value(value, collect_value(addr, acc))
    // ── Phase-5 reference/table/bulk nodes: collect the `Var` names in their operands so
    // gensym avoids them (over-approximating is safe). ──
    ir.RefFunc(_) -> acc
    // Phase-14 `RefFuncImport` (R1): PASS-THROUGH — a slot + type only (no `Var` operands), so it
    // contributes nothing to collect, exactly like `RefFunc`. NEVER an `Error` (this is a collector,
    // not the dispatch/render fail-closed reach). This arm is PERMANENT — R14-02 does not touch it.
    ir.RefFuncImport(_, _) -> acc
    ir.RefIsNull(arg) -> collect_value(arg, acc)
    ir.TableGet(_, index) -> collect_value(index, acc)
    ir.TableSet(_, index, value) ->
      collect_value(value, collect_value(index, acc))
    ir.TableSize(_) -> acc
    ir.TableGrow(_, delta, init) ->
      collect_value(init, collect_value(delta, acc))
    ir.TableFill(_, offset, value, count) ->
      collect_value(count, collect_value(value, collect_value(offset, acc)))
    ir.TableInit(_, _, dst, src, count) ->
      collect_value(count, collect_value(src, collect_value(dst, acc)))
    ir.TableCopy(_, _, dst, src, count) ->
      collect_value(count, collect_value(src, collect_value(dst, acc)))
    ir.ElemDrop(_) -> acc
    ir.MemFill(_, dest, value, count) ->
      collect_value(count, collect_value(value, collect_value(dest, acc)))
    ir.MemCopy(_, _, dst, src, count) ->
      collect_value(count, collect_value(src, collect_value(dst, acc)))
    ir.MemInit(_, _, dst, src, count) ->
      collect_value(count, collect_value(src, collect_value(dst, acc)))
    ir.DataDrop(_) -> acc
    GlobalGet(_) -> acc
    GlobalSet(_, value) -> collect_value(value, acc)
    CallDirect(_, args) -> collect_values(args, acc)
    CallIndirect(_, index, _, args) ->
      collect_values(args, collect_value(index, acc))
    CallHost(_, _, args) -> collect_values(args, acc)
    Let(names, rhs, body) -> {
      let acc = list.fold(names, acc, set.insert)
      collect_expr(body, collect_expr(rhs, acc))
    }
    If(cond, _, t, e) ->
      collect_expr(e, collect_expr(t, collect_value(cond, acc)))
    Switch(sel, _, arms, default) -> {
      let acc = collect_value(sel, acc)
      let acc =
        list.fold(arms, acc, fn(a, arm) {
          let SwitchArm(_, body) = arm
          collect_expr(body, a)
        })
      collect_expr(default, acc)
    }
    Block(_, _, body) -> collect_expr(body, acc)
    Loop(_, params, _, body) -> {
      let acc =
        list.fold(params, acc, fn(a, p) {
          collect_value(p.init, set.insert(a, p.name))
        })
      collect_expr(body, acc)
    }
    Break(_, vs) -> collect_values(vs, acc)
    Continue(_, vs) -> collect_values(vs, acc)
    Trap(_) -> acc
    Charge(_, body) -> collect_expr(body, acc)
    // ── Phase-6 SIMD nodes + `CallImport`: collect the `Var` names in their `Value` operands
    // (over-approximating keeps gensym collision-free). ──
    ir.Simd(_, args) -> collect_values(args, acc)
    ir.SimdShuffle(_, a, b) -> collect_value(b, collect_value(a, acc))
    ir.SimdLoad(_, _, addr, _) -> collect_value(addr, acc)
    ir.SimdStore(_, addr, value, _) ->
      collect_value(value, collect_value(addr, acc))
    ir.SimdLoadLane(_, _, addr, _, _, vec) ->
      collect_value(vec, collect_value(addr, acc))
    ir.SimdStoreLane(_, _, addr, _, _, vec) ->
      collect_value(vec, collect_value(addr, acc))
    ir.CallImport(_, _, args) -> collect_values(args, acc)
    // ── Phase-13 tail calls: collect the `Var` names in their `Value` operands (the direct/import
    // args, plus the indirect `index`) so gensym avoids them (over-approximating is safe), exactly
    // like `CallImport`/`CallIndirect`. ──
    ir.ReturnCall(_, args) -> collect_values(args, acc)
    ir.ReturnCallIndirect(_, index, _, args) ->
      collect_values(args, collect_value(index, acc))
    ir.ReturnCallImport(_, _, args) -> collect_values(args, acc)
    ir.ReturnCallRef(funcref, args) ->
      collect_values(args, collect_value(funcref, acc))
    // ── Phase-7 EH nodes: collect the `Var` names in their operands / sub-expressions so gensym
    // avoids them (over-approximating is safe). `Try` recurses into its body + each handler's
    // inline handler expression and includes the handler's `payload`/`exnref` binder names. ──
    ir.Throw(_, args) -> collect_values(args, acc)
    ir.ThrowRef(exnref) -> collect_value(exnref, acc)
    ir.Try(_, body, handlers) -> {
      let acc = collect_expr(body, acc)
      list.fold(handlers, acc, fn(a, h) {
        let a = list.fold(h.payload, a, set.insert)
        let a = case h.exnref {
          Some(name) -> set.insert(a, name)
          None -> a
        }
        collect_expr(h.handler, a)
      })
    }
  }
}

/// Accumulate the name of `value` if it is a `Var`.
fn collect_value(value: Value, acc: Set(String)) -> Set(String) {
  case value {
    Var(name) -> set.insert(acc, name)
    _ -> acc
  }
}

/// Accumulate every `Var` name among `values`.
fn collect_values(values: List(Value), acc: Set(String)) -> Set(String) {
  list.fold(values, acc, fn(a, v) { collect_value(v, a) })
}
