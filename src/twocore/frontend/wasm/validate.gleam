//// Unit 10a / Phase-2 unit 08 — WASM `full` validation (the security boundary).
////
//// `validate/1` proves a decoded `wasm.Module` well-typed per the WebAssembly
//// core spec's validation rules (<https://webassembly.github.io/spec/core/valid/>)
//// using the abstract stack-typing algorithm from the appendix
//// (<https://webassembly.github.io/spec/core/appendix/algorithm.html>). It is the
//// **security boundary** (overview D4/D9): the input AST is populated from
//// UNTRUSTED bytes, so every malformation is reported as a typed `ValidateError`
//// and the validator never panics, `let assert`s, or diverges (fail-closed).
////
//// This module reads `twocore/frontend/wasm/ast` ONLY — it has **no dependency on
//// the shared IR** (so its conformance gates independently of the backend, per the
//// unit doc). The output `TypedModule` carries exactly the typing facts the lowering
//// stage (`lower.gleam`, 10b / unit 09) needs so lowering never re-derives types.
////
//// Phase 2 (unit 08) extends the Phase-1 algorithm — the polymorphic-stack /
//// label / else-less-`if` / `max_locals` machinery is kept verbatim — with typing
//// for the new ops: the load/store width matrix (+ memarg alignment), `memory.size`/
//// `memory.grow`, `global.get`/`global.set` (incl. the **mutability** check),
//// `call_indirect` (typeidx + table-presence), the float arith/unary/copysign/compare
//// ops, the full `0xA7–0xBF` int↔float conversion block, and `select`. It adds the
//// **module-level** checks (limits, ≤1 memory/table, in-range func/type/global
//// indices, the `start` signature) and **constant-expression** validation for global
//// initializers and element/data segment offsets.
////
//// Phase 5 (unit P5-04) completes the standardized surface (minus SIMD) — again
//// keeping the polymorphic-stack machinery verbatim. It types the **reference**
//// instructions (`ref.null`/`ref.func` + the `C.refs` declared-reference set /
//// `ref.is_null`), **typed `select t`** and the untyped-`select` reference
//// restriction, **reftype-typed tables** with `table.get/set/size/grow/fill` and
//// **multiple tables**, the **bulk memory & table** ops (`memory.init/copy/fill`,
//// `data.drop`, `table.init/copy`, `elem.drop`) with their `dataidx`/`elemidx`/
//// `memidx`/`tableidx` bounds and reftype-match rules, **multi-memory** `memidx`
//// routing (the Phase-2 `≤1 memory / ≤1 table` caps are LIFTED per H3), **memory64**
//// `i64`-address typing (decode/validate-only — runtime deferred to Phase 6, R12),
//// **non-function imports** wired into the `imports ++ defined` index spaces, and the
//// passive/declarative element + passive data segment grammar. The `TypedModule` now
//// also carries the reftypes of tables/element-segments, the memories' address
//// widths, the per-kind imported counts, and `C.refs`, so lowering (P5-05) never
//// re-derives them.
////
//// Phase 6 (unit P6-04) closes the last gap in the standardized surface — again
//// keeping the polymorphic-stack / label machinery verbatim. It types the
//// **fixed-width SIMD** instruction set (`«WASM-AST4»`): `v128` as a vector value
//// type on the abstract stack (permitted by untyped `select`, rejected by
//// `ref.is_null` — it is NOT a reference type), the pure lane-wise ops
//// (`ast.Simd(op)`, exhaustive on `SimdOp`) with their spec abstract-stack
//// signatures (comparisons yield a `v128` lane **mask**, not `i32`), the lane-immediate
//// bounds (`extract_lane`/`replace_lane` `lane < dim`, `i8x16.shuffle` indices `< 32`,
//// `load/store{N}_lane` `lane < 128/N`) as `BadLaneIndex`, and the v128 memory family
//// (`SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`) routed through the SAME
//// `mem_addr_type`/`check_align`/`check_offset` seam as scalar loads (so `v128.load` on
//// a 64-bit memory pops an `i64` address — the memory64 seam). Every SIMD `Instr` is
//// intercepted BEFORE the `numeric_sig` fallthrough (S1 — the fail-closed security
//// invariant): an ill-typed / out-of-range-lane / over-aligned SIMD program is
//// REJECTED, never silently accepted. memory64 typing (P5) is re-confirmed spec-complete
//// (its runtime now lands in Phase 6), and cross-module function-import typing is
//// unchanged — a `call` to an imported function type-checks against its declared
//// `FuncType` in the imports-first func space (the link-time satisfaction is P6-09's).
//// A module with no `v128` validates **byte-identically** to Phase 5 (I7).
////
//// Strength: **`full`** (the only Phase-1 strength — required for untrusted input;
//// `subset`/`assume_valid` are deferred and are NOT a default, D9).

import gleam/list
import gleam/option
import gleam/result
import gleam/set.{type Set}
import twocore/frontend/wasm/ast.{
  type FuncType, type IdxType, type Instr, type Limits, type MemArg, type Module,
  type ValType,
}

// ─────────────────────────────── public types ───────────────────────────────

/// A per-function defensive cap on the number of locals (params + declared).
///
/// The spec requires the local count to fit in a `u32`, but every practical engine
/// imposes a tighter bound; this cap guards the unit-05 decoder's RLE expansion (a
/// `(count, valtype)` group with a huge count would otherwise expand to a giant
/// list). `50_000` matches common engine limits and is far above anything the
/// corpus needs. A function exceeding it is rejected with `Error(TooManyLocals(_))`.
pub const max_locals: Int = 50_000

/// The hard architectural cap on memory size, in 64KiB pages (`2^16`). A 32-bit
/// linear memory cannot exceed `2^16` pages = 4 GiB of address space, so a `memory`
/// whose `min`/`max` limit exceeds this is invalid (spec `valid/types`, limit
/// range `2^16` for memories).
pub const memory_page_limit: Int = 65_536

/// The hard architectural cap on a **64-bit** (memory64) memory, in 64KiB pages
/// (`2^48`). A 64-bit linear memory addresses `2^64` bytes; dividing by the 64 KiB
/// (`2^16`) page size gives `2^48` pages (spec/memory64 proposal, limit range for an
/// `i64`-indexed memory). A 64-bit `memory` whose `min`/`max` exceeds this is invalid
/// (`Error(BadLimits)`). memory64 is decode/validate-only in Phase 5 (its runtime is
/// deferred to Phase 6, R12) — but the typing here is spec-correct regardless.
pub const memory64_page_limit: Int = 281_474_976_710_656

/// The static memarg-offset ceiling for a 32-bit (`Idx32`) memory: an offset must be
/// `< 2^32` (spec `valid/instructions` memarg rule). Decode reads the offset as a
/// `u64` (the memory64 width), so this is the check that rejects an over-range offset
/// on a 32-bit memory (`align.wast`'s "offset out of range"). A 64-bit memory's
/// offset may be any `u64`, so no ceiling applies there.
const offset32_limit: Int = 4_294_967_296

/// The hard cap on a table's size, in entries (`2^32 - 1`). The spec limit range for
/// a table is `2^32 - 1` (spec `valid/types`). Since the decoder reads `min`/`max`
/// as `u32`, this bound is only meaningful as an upper edge; the load-bearing table
/// check is `min <= max`.
pub const table_entry_limit: Int = 4_294_967_295

/// The result of validating a module: the original AST plus the typing facts that
/// lowering (10b / unit 09) consumes so it never re-derives types.
///
/// - `module`: the original decoded AST, **unmutated** (validate never edits the AST).
/// - `imported_func_count`: the funcidx offset (imports occupy `0..n-1`, defined
///   functions follow). Phase-1/2 have no imports (`0`), but it is kept explicit so
///   the `call`/import boundary is not baked away.
/// - `func_types`: the signature of every function indexed by **funcidx** (imports
///   then defined). With no imports this is the defined functions' types in order.
/// - `func_locals`: for each **defined** function (in order), its fully-expanded
///   local types — `params ++ declared` — indexed from `0`.
/// - `global_types`: the value type of each global indexed by **globalidx** (imports
///   then defined). This is the one typing fact lowering cannot trivially re-derive
///   from the AST and that validate must compute anyway (for the `global.set`
///   mutability check), so it is carried here. Load result types live on the load
///   opcode and `call_indirect`/`global.get` result types are recoverable from
///   `module.types`/`global_types`, so no per-instruction annotation map is needed.
/// - `imported_global_count` / `imported_table_count` / `imported_memory_count`
///   (Phase 5): the number of *imported* globals/tables/memories — the offset at
///   which the corresponding *defined* items begin in each index space (imports
///   precede definitions). `0` for an import-free module (byte-identical to Phase 4).
/// - `table_types` (Phase 5): the element **reftype** (`FuncRef`/`ExternRef`, the
///   AST's reftype subset of `ValType`) of each table by **tableidx** (imports then
///   defined). Lowering reads it for `table.get` result types and the table's
///   reference storage kind. Empty for a module with no tables.
/// - `memory_idx_types` (Phase 5): the address width (`Idx32`/`Idx64`) of each memory
///   by **memidx** (imports then defined). Lowering reads it for the address operand
///   width; `Idx32` for a Phase-4 module.
/// - `elem_types` (Phase 5): the **reftype** of each element segment by **elemidx**,
///   consumed by `table.init`/`elem.drop` lowering.
/// - `refs` (Phase 5): `C.refs`, the set of function indices *declared* in the module
///   (element segments of any mode, global inits, and function exports) — the funcs a
///   body may legally `ref.func`. Lowering reads it for the `ref.func` lowering guard.
/// - `imported_tag_count` (Phase 7): the number of *imported* tags — the offset at which
///   *defined* tags begin in the tag index space (imports precede definitions). `0` for a
///   module with no imported tags (byte-identical to Phase 6). Lowering (P7-05) reads it
///   to route a `throw`/catch tagidx into the imports-first tag space; the linker binds
///   `list.take(tag_types, imported_tag_count)` to the provided runtime tags.
/// - `tag_types` (Phase 7): the **operand types** of every tag by **tagidx** (imports ++
///   defined), each resolved from its `type_idx` and verified `[t*] -> []` (empty
///   results). Lowering reads it to build the exception term's payload shape and to bind
///   a caught tag's operands onto a catch label's values — the one EH typing fact lower
///   cannot trivially re-derive (a `throw x` names only `x`), so it is carried here,
///   exactly as `global_types` is for `global.set`. Empty for a tag-free module.
pub type TypedModule {
  TypedModule(
    module: Module,
    imported_func_count: Int,
    imported_global_count: Int,
    imported_table_count: Int,
    imported_memory_count: Int,
    func_types: List(FuncType),
    func_locals: List(List(ValType)),
    global_types: List(ValType),
    table_types: List(ValType),
    memory_idx_types: List(IdxType),
    elem_types: List(ValType),
    refs: Set(Int),
    imported_tag_count: Int,
    tag_types: List(List(ValType)),
  )
}

/// Every reason `validate` rejects a module (this stage's own error type — D4, not a
/// shared enum). Each variant captures enough context to diagnose the failure; the
/// conformance suite asserts the *variant the spec rule demands*, never message text.
///
/// - `TypeMismatch`: an operand on the abstract stack had the wrong value type for an
///   instruction, or a const-expr produced the wrong type (spec: the typing rule for
///   that instruction).
/// - `Underflow`: an instruction tried to pop an operand the current block did not
///   provide (operand-stack underflow).
/// - `UnknownLocal(index)`: a `local.get/set/tee` index is out of range of the
///   function's locals.
/// - `UnknownGlobal(index)`: a `global.get/set` index is out of range of the module's
///   globals.
/// - `UnknownFunc(index)`: a `call`/`start`/element funcidx is out of range.
/// - `UnknownType(index)`: a `type`/blocktype/`call_indirect` `typeidx` is out of
///   range of the module's type section.
/// - `UnknownLabel(index)`: a `br`/`br_if`/`br_table` relative depth exceeds the
///   control-frame stack.
/// - `UnknownMemory(index)`: a memory op (load/store/`memory.*`/a bulk-memory op/an
///   active data segment/a memory export) whose `memidx` is out of range of the
///   module's memories (imports ++ defined). Phase 5 carries the **real** `memidx`
///   (not always `0`) and fires on any out-of-range index (spec: `C.mems[memidx]`
///   must exist).
/// - `UnknownTable(index)`: a `call_indirect`/`table.*`/active element segment/a table
///   export whose `tableidx` is out of range of the module's tables (imports ++
///   defined). Phase 5 carries the **real** `tableidx` (spec: `C.tables[tableidx]`).
/// - `ImmutableGlobal(index)`: a `global.set` on a `const` (immutable) global — a
///   validation error (spec `valid/instructions` `global.set` rule).
/// - `BadAlignment`: a memarg whose `2^align` exceeds the access's natural byte width
///   (spec `valid/instructions` memarg rule: `2^align <= N/8`). Routed from `align.wast`.
/// - `NonConstantExpr`: a global init / element-offset / data-offset expr uses an
///   instruction other than a single `t.const` — e.g. an extended-const `i32.add`
///   chain, or a `global.get` (valid only against an immutable imported global, none
///   of which exist in Phase 2). Spec `valid/instructions` constant expressions.
/// - `BadLimits`: a memory/table `limits` with `min > max`, or `min`/`max` exceeding
///   the type's range (`2^16` pages for a memory; `2^32 - 1` entries for a table).
///   Spec `valid/types` limits rule.
/// - `TooManyMemories`: **retained in the type but no longer produced** — Phase 5
///   lifts the Phase-2 MVP `≤1 memory` cap (multi-memory is valid, H3). Kept so its
///   removal is not an API break and a future "single-memory profile" flag could
///   reuse it. (An unused public constructor does not warn in Gleam, so DoD "zero
///   warnings" holds.)
/// - `TooManyTables`: likewise retained-but-unproduced — Phase 5 lifts the `≤1 table`
///   cap (multi-table is valid, H3).
/// - `BadStartType`: the `start` function's type is not `[] -> []` (spec `valid/modules`
///   start rule).
/// - `BranchArityMismatch`: a `br_table` whose targets/default do not all share the
///   same label arity (spec: all branch targets must agree).
/// - `IfElseMismatch`: an `if` with no `else` whose blocktype params differ from its
///   results (an else-less `if` is only valid when `params == results`).
/// - `UnexpectedEnd`: an `end`/`else` with no matching open control frame, or a body
///   that did not close cleanly.
/// - `TooManyLocals(count)`: the function's local count exceeds `max_locals`.
/// - `Unsupported(detail)`: a construct outside the validation surface. Phase 6 types
///   the whole standardized surface INCLUDING SIMD, so this is now reserved for the
///   genuinely-deferred constructs — relaxed-SIMD (if one ever decodes) and GC-proposal
///   reftypes — and for a `(SimdOp, SimdShape)` combo that denotes no standardized SIMD
///   instruction (e.g. `i8x16.mul`, `i64x2.min_s`; the AST enum is shape-permissive but
///   decode never emits such a combo — this arm keeps the validator total + fail-closed).
///   Rejected fail-closed rather than waved through.
/// - `BadLaneIndex(index)`: a static SIMD lane immediate out of range (spec vector-
///   instruction lane rule) — `extract_lane`/`replace_lane` with `lane >= dim(shape)`,
///   an `i8x16.shuffle` index `>= 32`, or a `load/store{8,16,32,64}_lane` with
///   `lane >= 128/N`. Carries the offending index. Distinct from `TypeMismatch` (this is
///   an immediate, not an operand-type disagreement). Routed from the `simd_lane.wast` /
///   `simd_*_lane.wast` `assert_invalid` corpora.
/// - `OffsetOutOfRange`: a load/store memarg static offset `>= 2^32` on a **32-bit**
///   (`Idx32`) memory (spec `valid/instructions` memarg). Reachable now that decode
///   reads the offset as a `u64` (P5-03); routed from `align.wast`'s "offset out of
///   range". A 64-bit (`Idx64`) memory's offset may be any `u64`, so this never fires
///   there.
/// - `UnknownData(index)`: a `memory.init`/`data.drop` `dataidx` out of range of the
///   module's data segments (spec `valid/instructions`; `bulk.wast`). The data-count
///   *section presence* rule is decode's (R13); this checks `dataidx < data_count`.
/// - `UnknownElem(index)`: a `table.init`/`elem.drop` `elemidx` out of range of the
///   module's element segments (spec `valid/instructions`; `table_init.wast`).
/// - `UndeclaredFunctionRef(index)`: a `ref.func x` whose `x` is a valid funcidx but
///   **not** in `C.refs` (the module's declared-reference set). The spec requires
///   `x ∈ C.refs` (spec `valid/instructions` ref.func; `ref_func.wast`
///   `assert_invalid`). Distinct from `UnknownFunc` (which is x out of range).
/// - `RefTypeMismatch`: a **reference-type** disagreement that is not an operand-stack
///   pop mismatch — `table.init`/`table.copy` across mismatched reftypes, an active
///   element segment whose reftype ≠ its target table's, or `call_indirect` through a
///   non-`funcref` table (spec `valid/instructions`/`valid/modules`). Operand-stack
///   reftype mismatches (e.g. `table.set` fed the wrong reftype) use `TypeMismatch`.
/// - `BadSelectType`: an untyped `select` (0x1B) on a **reference** operand (invalid —
///   untyped select is number-typed only), or a typed `select t` (0x1C) whose
///   annotation vector is not exactly length 1 (spec parametric rule; `select.wast`).
/// - `UnknownImportKind(detail)`: an import/export whose referent index is out of the
///   space its kind selects, where no more specific `Unknown*` fits, or a **duplicate
///   export name** (spec `valid/modules` forbids duplicate export names). Carries a
///   human-readable detail.
/// - `UnknownTag(index)` (Phase 7): a `throw`/`try_table` catch / legacy `catch` /
///   `tag`-export tagidx out of range of the module's tag index space (imports ++
///   defined) — spec: the EH proposal requires `C.tags[x]` to exist. Analogous to
///   `UnknownFunc`/`UnknownMemory`. Distinct from `UnknownType` (a *tag declaration*'s
///   out-of-range typeidx at module setup, a declaration error, versus a *use-site*
///   out-of-range tagidx). Carries the offending index.
/// - `BadTagType` (Phase 7): a tag (defined or imported) whose referenced `FuncType`
///   has a **non-empty result list** — the EH proposal requires a tag's type to be
///   `[t*] -> []` (an exception carries operands but never returns). Analogous to
///   `BadStartType` (the `[] -> []` start rule); carries no index (message text is not
///   asserted by the conformance runner, only the variant).
pub type ValidateError {
  TypeMismatch
  Underflow
  UnknownLocal(index: Int)
  UnknownGlobal(index: Int)
  UnknownFunc(index: Int)
  UnknownType(index: Int)
  UnknownLabel(index: Int)
  UnknownMemory(index: Int)
  UnknownTable(index: Int)
  ImmutableGlobal(index: Int)
  BadAlignment
  NonConstantExpr
  BadLimits
  TooManyMemories
  TooManyTables
  BadStartType
  BranchArityMismatch
  IfElseMismatch
  UnexpectedEnd
  TooManyLocals(count: Int)
  Unsupported(detail: String)
  OffsetOutOfRange
  UnknownData(index: Int)
  UnknownElem(index: Int)
  UndeclaredFunctionRef(index: Int)
  RefTypeMismatch
  BadSelectType
  UnknownImportKind(detail: String)
  BadLaneIndex(index: Int)
  UnknownTag(index: Int)
  BadTagType
}

// ─────────────────────────────── validation context ───────────────────────────────

/// The module-level facts every instruction typing rule may need, threaded into
/// `validate_instr` as one record (the Phase-1 `types, func_types, locals` triple
/// generalized to the full Phase-5 index spaces; the abstract-stack algorithm is
/// otherwise untouched).
///
/// Every index space is built **imports first** (in import order) then definitions,
/// so a `funcidx`/`globalidx`/`tableidx`/`memidx` addresses the combined space
/// directly (spec `valid/modules`).
///
/// - `types`: the module's type section (resolved by blocktype/`call_indirect`).
/// - `func_types`: per-funcidx signatures (imports `++` defined).
/// - `globals`: `(value type, mutable?)` by globalidx (imports `++` defined) — drives
///   `global.get`/`global.set` typing and the mutability check.
/// - `imported_global_count`: the number of imported globals — a `global.get` in a
///   constant expression is only constant when its index is an *imported* immutable
///   global, i.e. `x < imported_global_count` (spec constant expressions).
/// - `tables`: `(element reftype, limits)` by tableidx (imports `++` defined) — drives
///   the `table.*` operand/result reftypes and the `call_indirect` funcref check.
/// - `memories`: the address width (`Idx32`/`Idx64`) by memidx (imports `++` defined)
///   — drives the `i32`/`i64` address typing of every memory op.
/// - `data_count`: the number of data segments (the `dataidx` bound for
///   `memory.init`/`data.drop`).
/// - `elem_types`: the reftype of each element segment by elemidx (the `elemidx` bound
///   and reftype for `table.init`/`elem.drop`).
/// - `refs`: `C.refs`, the module's declared function references (`ref.func x` is valid
///   only if `x ∈ refs`).
/// - `tags` (Phase 7): the **operand types** of every tag by `tagidx` (imports ++
///   defined), each resolved from its `type_idx` at module setup and verified to have
///   empty results (§D). A `throw x` / `catch x l` / legacy `catch x` reads `ctx.tags[x]`
///   for the tag's operands. Empty for a tag-free module (byte-identical to Phase 6).
/// - `locals`: the current function's expanded local types (`params ++ declared`).
type Ctx {
  Ctx(
    types: List(ast.DefType),
    func_types: List(FuncType),
    globals: List(#(ValType, Bool)),
    imported_global_count: Int,
    tables: List(#(ValType, Limits)),
    memories: List(IdxType),
    data_count: Int,
    elem_types: List(ValType),
    refs: Set(Int),
    tags: List(List(ValType)),
    locals: List(ValType),
  )
}

// ─────────────────────────────── stack-typing model ───────────────────────────────

/// A value type on the abstract operand stack: a concrete WASM `ValType` or `Unknown`
/// — the polymorphic placeholder produced after `unreachable` (the spec's "Unknown"
/// / bottom). `Unknown` unifies with any expected type.
type StackType {
  Known(ValType)
  Unknown
}

/// The opcode that opened a control frame — selects how the frame's label is typed
/// and whether an else-less `if` needs the params==results check.
///
/// Phase 7 adds three LEGACY exception-handling frame kinds. All three are typed exactly
/// like `KBlock` (their label targets the frame's RESULT types, `label_types` returns
/// `end_types`, and their `end` produces the results) — they exist only so the legacy
/// handler markers (`LegacyCatch`/`LegacyCatchAll`/`LegacyDelegate`) can dispatch on the
/// kind of frame they close/re-open (a `catch`/`catch_all` handler may only follow the
/// try body or a preceding `catch`, never a `catch_all`; a `delegate` may only close the
/// bare try body). The MODERN `try_table` reuses `KBlock` directly (its body/label/`end`
/// semantics are a block's), so it needs no new kind.
///
/// - `KTry`: an open legacy `try` body (`TryLegacy`), before any handler marker.
/// - `KCatch`: a legacy `catch x` handler region (the tag's operands were pushed).
/// - `KCatchAll`: a legacy `catch_all` handler region (no operands pushed).
type FrameKind {
  KFunc
  KBlock
  KLoop
  KIf
  KElse
  KTry
  KCatch
  KCatchAll
}

/// One control frame (spec appendix `ctrl_frame`).
///
/// - `kind`: which structured opcode opened it.
/// - `start_types`: the frame's input types (a `loop` label targets these).
/// - `end_types`: the frame's result types (a `block`/`if` label targets these; the
///   function frame's are the function results).
/// - `height`: the operand-stack height at frame entry (its base).
/// - `unreachable`: whether the rest of the frame is stack-polymorphic (set by
///   `unreachable`/`br`/`return`/`br_table`).
type CtrlFrame {
  CtrlFrame(
    kind: FrameKind,
    start_types: List(ValType),
    end_types: List(ValType),
    height: Int,
    unreachable: Bool,
  )
}

/// The validator's threaded state: the operand-type stack (`vals`, top at head) and
/// the control-frame stack (`ctrls`, innermost at head).
type VState {
  VState(vals: List(StackType), ctrls: List(CtrlFrame))
}

// ─────────────────────────────── stack operations ───────────────────────────────

/// `True` if a stack type satisfies an expectation, honoring `Unknown` polymorphism
/// in either position (spec: `Unknown` matches any type).
fn types_match(a: StackType, b: StackType) -> Bool {
  case a, b {
    Unknown, _ -> True
    _, Unknown -> True
    Known(x), Known(y) -> x == y
  }
}

/// The innermost control frame, or `Error(UnexpectedEnd)` if there is none.
fn top_ctrl(st: VState) -> Result(CtrlFrame, ValidateError) {
  case st.ctrls {
    [f, ..] -> Ok(f)
    [] -> Error(UnexpectedEnd)
  }
}

/// Pop one operand (spec appendix `pop_val`). At the current frame's base: yields
/// `Unknown` (without popping) if the frame is polymorphic, else `Error(Underflow)`.
fn pop_val(st: VState) -> Result(#(StackType, VState), ValidateError) {
  use frame <- result.try(top_ctrl(st))
  case list.length(st.vals) == frame.height {
    True ->
      case frame.unreachable {
        True -> Ok(#(Unknown, st))
        False -> Error(Underflow)
      }
    False ->
      case st.vals {
        [t, ..rest] -> Ok(#(t, VState(..st, vals: rest)))
        [] -> Error(Underflow)
      }
  }
}

/// Pop one operand and check it matches `expect` (spec appendix `pop_val(expect)`).
fn pop_expect(st: VState, expect: ValType) -> Result(VState, ValidateError) {
  use #(t, st2) <- result.try(pop_val(st))
  case types_match(t, Known(expect)) {
    True -> Ok(st2)
    False -> Error(TypeMismatch)
  }
}

/// Push one known operand type.
fn push_val(st: VState, t: ValType) -> VState {
  VState(..st, vals: [Known(t), ..st.vals])
}

/// Push a run of operand types so the last element ends up on top (spec `push_vals`).
fn push_vals(st: VState, ts: List(ValType)) -> VState {
  list.fold(ts, st, fn(s, t) { push_val(s, t) })
}

/// Pop and check a run of operand types, last-on-top first (spec `pop_vals`).
fn pop_vals(st: VState, ts: List(ValType)) -> Result(VState, ValidateError) {
  list.try_fold(list.reverse(ts), st, fn(s, t) { pop_expect(s, t) })
}

/// Open a control frame: push it (recording the current height), then push its input
/// types (spec `push_ctrl`).
fn push_ctrl(
  st: VState,
  kind: FrameKind,
  in_types: List(ValType),
  out_types: List(ValType),
) -> VState {
  let frame =
    CtrlFrame(
      kind: kind,
      start_types: in_types,
      end_types: out_types,
      height: list.length(st.vals),
      unreachable: False,
    )
  push_vals(VState(..st, ctrls: [frame, ..st.ctrls]), in_types)
}

/// Close the innermost control frame: pop and check its result types, verify the stack
/// returned to the frame's base, then remove it (spec `pop_ctrl`). Returns the closed
/// frame. `Error(TypeMismatch)` if the height does not return to base (too many/few
/// operands left on the stack).
fn pop_ctrl(st: VState) -> Result(#(CtrlFrame, VState), ValidateError) {
  use frame <- result.try(top_ctrl(st))
  use st2 <- result.try(pop_vals(st, frame.end_types))
  case list.length(st2.vals) == frame.height {
    False -> Error(TypeMismatch)
    True ->
      case st2.ctrls {
        [_, ..rest] -> Ok(#(frame, VState(..st2, ctrls: rest)))
        [] -> Error(UnexpectedEnd)
      }
  }
}

/// The types a branch to `frame` carries: a `loop` targets its INPUT types (the head),
/// every other frame targets its result types (spec `label_types`).
fn label_types(frame: CtrlFrame) -> List(ValType) {
  case frame.kind {
    KLoop -> frame.start_types
    _ -> frame.end_types
  }
}

/// Make the rest of the innermost frame stack-polymorphic: drop operands above the
/// frame's base and mark it `unreachable` (spec `unreachable`).
fn mark_unreachable(st: VState) -> Result(VState, ValidateError) {
  use frame <- result.try(top_ctrl(st))
  let drop_n = list.length(st.vals) - frame.height
  let kept = list.drop(st.vals, drop_n)
  let frame2 = CtrlFrame(..frame, unreachable: True)
  case st.ctrls {
    [_, ..rest] -> Ok(VState(vals: kept, ctrls: [frame2, ..rest]))
    [] -> Error(UnexpectedEnd)
  }
}

// ─────────────────────────────── helpers ───────────────────────────────

/// Total list indexing: `Ok(element)` at position `i` (0-based) or `Error(Nil)`.
fn nth(xs: List(a), i: Int) -> Result(a, Nil) {
  case xs, i {
    [x, ..], 0 -> Ok(x)
    [_, ..rest], _ ->
      case i > 0 {
        True -> nth(rest, i - 1)
        False -> Error(Nil)
      }
    [], _ -> Error(Nil)
  }
}

/// Resolve a blocktype to its `#(input_types, result_types)` (spec: a blocktype is an
/// empty type, a single valtype, or a `typeidx` giving `params -> results`).
/// `Error(UnknownType(i))` if a `typeidx` is out of range.
fn blocktype_types(
  bt: ast.BlockType,
  types: List(ast.DefType),
) -> Result(#(List(ValType), List(ValType)), ValidateError) {
  case bt {
    ast.BlockEmpty -> Ok(#([], []))
    ast.BlockVal(t) -> Ok(#([], [t]))
    ast.BlockTypeIdx(i) ->
      case ast.func_type_at(types, i) {
        Ok(ast.FuncType(params, results)) -> Ok(#(params, results))
        Error(_) -> Error(UnknownType(i))
      }
  }
}

// ─────────────────────────────── public entry point ───────────────────────────────

/// Proves `module` well-typed per WASM `full` validation and returns the typing
/// information lowering needs.
///
/// `Ok(TypedModule)` ⇒ every memory/table limit is in range (per the memory's address
/// width — `2^16` pages for a 32-bit memory, `2^48` for a 64-bit one), every function
/// body type-checks under the abstract stack algorithm, every local/global/func/type/
/// label/memory/table/data/elem index is in bounds, every branch arity matches, every
/// function's local count is within `max_locals`, every reference/table/bulk op is
/// correctly typed (reftypes match; `ref.func` targets a declared function), every
/// `select t` annotation is length 1 and untyped `select` is number-typed, every
/// global init / element offset / element item / data offset is a well-typed constant
/// expression, every export index is in range and export names are unique, and any
/// `start` function has type `[] -> []`. Multiple memories/tables are permitted (H3);
/// memory64 is typed (i64 addresses) even though its runtime is deferred (R12).
/// `Error(ValidateError)` ⇒ the module is invalid; the security boundary REJECTS it
/// (fail-closed). Total over any decoded AST — never panics or diverges.
pub fn validate(module: Module) -> Result(TypedModule, ValidateError) {
  // Build every index space `imports ++ defined` (imports precede definitions, in
  // import order) so a funcidx/globalidx/tableidx/memidx addresses the combined
  // space directly (spec `valid/modules`). A module with no import section keeps the
  // Phase-4 shape (imports contribute nothing → byte-identical).
  use imp_funcs <- result.try(imported_func_types(module))
  let imp_globals = imported_globals(module)
  let imp_tables = imported_tables(module)
  let imp_memtypes = imported_memtypes(module)
  let imported_func_count = list.length(imp_funcs)
  let imported_global_count = list.length(imp_globals)
  let imported_table_count = list.length(imp_tables)
  let imported_memory_count = list.length(imp_memtypes)

  use def_funcs <- result.try(resolve_func_types(module))
  let func_types = list.append(imp_funcs, def_funcs)
  let globals =
    list.append(
      imp_globals,
      list.map(module.globals, fn(g) { #(g.ty, g.mutable) }),
    )
  let global_types = list.map(globals, fn(g) { g.0 })
  let tables =
    list.append(
      imp_tables,
      list.map(module.tables, fn(t) { #(t.elem_type, t.limits) }),
    )
  let table_types = list.map(tables, fn(t) { t.0 })
  // Full MemType list (imports ++ defined) for the limit check; the idx-type-only
  // projection feeds the context (address typing needs only the width).
  let all_memtypes = list.append(imp_memtypes, module.memories)
  let memories = list.map(all_memtypes, fn(m) { m.idx_type })
  let elem_types = list.map(module.elements, fn(e) { e.ref_ty })
  let data_count = list.length(module.data)

  // The tag index space (Phase 7, EH proposal): imported tags occupy the low tagidx
  // slots, defined tags follow. Each tag's `type_idx` is resolved against the type
  // section and its type verified `[t*] -> []` (empty results, §D) — the single choke
  // where an ill-typed tag is rejected. Empty for a tag-free module (byte-identical).
  use imp_tags <- result.try(imported_tag_types(module))
  use def_tags <- result.try(defined_tag_types(module))
  let tags = list.append(imp_tags, def_tags)
  let imported_tag_count = list.length(imp_tags)

  // Module-level structural checks (spec `valid/modules` / `valid/types`). Multi-
  // memory / multi-table caps are LIFTED (H3): every memory/table limit is validated.
  use _ <- result.try(list.try_each(all_memtypes, check_memory))
  use _ <- result.try(
    list.try_each(tables, fn(t) { check_limits(t.1, table_entry_limit) }),
  )

  // `C.refs` — the module's declared function references (spec `funcidx(module)`):
  // computed once, up front, before validating any body or const-expr (§C.1).
  let refs = compute_refs(module)

  // A module-wide context; `locals` is filled per function in `validate_func`.
  let ctx =
    Ctx(
      types: module.types,
      func_types: func_types,
      globals: globals,
      imported_global_count: imported_global_count,
      tables: tables,
      memories: memories,
      data_count: data_count,
      elem_types: elem_types,
      refs: refs,
      tags: tags,
      locals: [],
    )

  use func_locals <- result.try(
    list.try_map(module.funcs, fn(f) { validate_func(f, module, ctx) }),
  )

  // Constant-expression validation (globals, element & data segments), export
  // range/uniqueness, and the `start` signature (spec `valid/modules`).
  use _ <- result.try(check_global_inits(module.globals, ctx))
  use _ <- result.try(check_elements(module, ctx))
  use _ <- result.try(check_data(module, ctx))
  use _ <- result.try(check_exports(module, ctx))
  use _ <- result.try(check_start(module, func_types))

  Ok(TypedModule(
    module: module,
    imported_func_count: imported_func_count,
    imported_global_count: imported_global_count,
    imported_table_count: imported_table_count,
    imported_memory_count: imported_memory_count,
    func_types: func_types,
    func_locals: func_locals,
    global_types: global_types,
    table_types: table_types,
    memory_idx_types: memories,
    elem_types: elem_types,
    refs: refs,
    imported_tag_count: imported_tag_count,
    tag_types: tags,
  ))
}

/// The signature of every **imported** function by import order — each `ImportFunc`'s
/// `type_idx` resolved against the type section (`Error(UnknownType(_))` if out of
/// range). Non-function imports are skipped (they populate the other index spaces).
fn imported_func_types(
  module: Module,
) -> Result(List(FuncType), ValidateError) {
  list.try_fold(module.imports, [], fn(acc, imp) {
    case imp.desc {
      ast.ImportFunc(type_idx) ->
        case ast.func_type_at(module.types, type_idx) {
          Ok(ft) -> Ok([ft, ..acc])
          Error(_) -> Error(UnknownType(type_idx))
        }
      _ -> Ok(acc)
    }
  })
  |> result.map(list.reverse)
}

/// The `(value type, mutable?)` of every **imported** global, in import order.
fn imported_globals(module: Module) -> List(#(ValType, Bool)) {
  list.filter_map(module.imports, fn(imp) {
    case imp.desc {
      ast.ImportGlobal(ty, mutable) -> Ok(#(ty, mutable))
      _ -> Error(Nil)
    }
  })
}

/// The `(element reftype, limits)` of every **imported** table, in import order.
fn imported_tables(module: Module) -> List(#(ValType, Limits)) {
  list.filter_map(module.imports, fn(imp) {
    case imp.desc {
      ast.ImportTable(tt) -> Ok(#(tt.elem_type, tt.limits))
      _ -> Error(Nil)
    }
  })
}

/// The `MemType` (limits + address width) of every **imported** memory, in import
/// order. Imported memories occupy the low `memidx` slots and are limit-checked and
/// address-typed exactly like defined ones.
fn imported_memtypes(module: Module) -> List(ast.MemType) {
  list.filter_map(module.imports, fn(imp) {
    case imp.desc {
      ast.ImportMemory(mt) -> Ok(mt)
      _ -> Error(Nil)
    }
  })
}

/// The signature of every **defined** function. Each function's `type_idx` must be in
/// range, else `Error(UnknownType(_))`.
fn resolve_func_types(module: Module) -> Result(List(FuncType), ValidateError) {
  list.try_map(module.funcs, fn(f) {
    case ast.func_type_at(module.types, f.type_idx) {
      Ok(ft) -> Ok(ft)
      Error(_) -> Error(UnknownType(f.type_idx))
    }
  })
}

/// The operand types of every **imported** tag, in import order (Phase 7, EH proposal).
/// Each `ImportTag(type_idx)` is resolved against the type section (`Error(UnknownType(_))`
/// if the typeidx is out of range) and its type verified `[t*] -> []` (`Error(BadTagType)`
/// if the referenced type has non-empty results, §D); its **params** are collected as the
/// tag's operand types. Non-tag imports are skipped. Imported tags occupy the low tagidx
/// slots (spec `valid/modules`). Mirrors `imported_func_types`.
fn imported_tag_types(
  module: Module,
) -> Result(List(List(ValType)), ValidateError) {
  list.try_fold(module.imports, [], fn(acc, imp) {
    case imp.desc {
      ast.ImportTag(type_idx) -> {
        use ops <- result.try(resolve_tag_type(module.types, type_idx))
        Ok([ops, ..acc])
      }
      _ -> Ok(acc)
    }
  })
  |> result.map(list.reverse)
}

/// The operand types of every **defined** tag (`Module.tags`), in section order (Phase 7).
/// Each `Tag(type_idx)` is resolved + empty-results-checked identically to an imported tag
/// (`resolve_tag_type`). Mirrors `resolve_func_types`.
fn defined_tag_types(
  module: Module,
) -> Result(List(List(ValType)), ValidateError) {
  list.try_map(module.tags, fn(t) { resolve_tag_type(module.types, t.type_idx) })
}

/// Resolve one tag's `type_idx` to its **operand types** (the referenced functype's
/// params), enforcing the EH proposal's tag rule that a tag's type is `[t*] -> []`
/// (spec `valid/modules`; `tag.wast`). `Error(UnknownType(type_idx))` if the typeidx is
/// out of range; `Error(BadTagType)` if the referenced type has a **non-empty result
/// list** (an exception carries operands but never returns). This is the single choke
/// where a malformed tag is rejected — every use site then trusts `ctx.tags[x]` is a
/// well-formed operand list.
fn resolve_tag_type(
  types: List(ast.DefType),
  type_idx: Int,
) -> Result(List(ValType), ValidateError) {
  case ast.func_type_at(types, type_idx) {
    Error(_) -> Error(UnknownType(type_idx))
    Ok(ast.FuncType(params, results)) ->
      case results {
        [] -> Ok(params)
        _ -> Error(BadTagType)
      }
  }
}

/// Validate one memory's address-width-relative limits: a 32-bit (`Idx32`) memory's
/// range is `2^16` pages, a 64-bit (`Idx64`) memory's is `2^48` (spec `valid/types` /
/// the memory64 proposal). `Error(BadLimits)` on any violation. memory64 is typed here
/// even though its runtime is deferred (R12) — an over-range 64-bit limit still fails.
fn check_memory(m: ast.MemType) -> Result(Nil, ValidateError) {
  let range = case m.idx_type {
    ast.Idx32 -> memory_page_limit
    ast.Idx64 -> memory64_page_limit
  }
  check_limits(m.limits, range)
}

/// A `limits` is valid within range `k` iff `min <= k`, and (when present) `max <= k`
/// and `min <= max` (spec `valid/types`: `n <= k`, `m <= k`, `n <= m`). Any violation
/// is `Error(BadLimits)`.
fn check_limits(limits: Limits, range: Int) -> Result(Nil, ValidateError) {
  case limits.min > range {
    True -> Error(BadLimits)
    False ->
      case limits.max {
        option.None -> Ok(Nil)
        option.Some(m) ->
          case m <= range && limits.min <= m {
            True -> Ok(Nil)
            False -> Error(BadLimits)
          }
      }
  }
}

/// Validate one defined function's body and return its expanded local types
/// (`params ++ declared`). Enforces `max_locals`, sets up the function control frame
/// (whose result types are the function results — the target of `return`), runs the
/// instruction stream under a per-function `Ctx`, and verifies the body closed cleanly
/// (the function `end` popped the frame). `Error(_)` on any typing/index violation.
fn validate_func(
  f: ast.Func,
  module: Module,
  ctx: Ctx,
) -> Result(List(ValType), ValidateError) {
  use sig <- result.try(case ast.func_type_at(module.types, f.type_idx) {
    Ok(ft) -> Ok(ft)
    Error(_) -> Error(UnknownType(f.type_idx))
  })
  let local_types = list.append(sig.params, f.locals)
  let local_count = list.length(local_types)
  case local_count > max_locals {
    True -> Error(TooManyLocals(local_count))
    False -> {
      let fctx = Ctx(..ctx, locals: local_types)
      // The implicit function frame: a `block`-like frame whose results are the
      // function's results (spec: a function body is validated as a block).
      let st0 =
        VState(vals: [], ctrls: [
          CtrlFrame(
            kind: KFunc,
            start_types: [],
            end_types: sig.results,
            height: 0,
            unreachable: False,
          ),
        ])
      use st_final <- result.try(
        list.try_fold(f.body, st0, fn(st, instr) {
          validate_instr(st, instr, fctx)
        }),
      )
      // A well-formed body's trailing `end` pops the function frame, leaving no
      // open frames. Anything else is a malformed/incomplete body.
      case st_final.ctrls {
        [] -> Ok(local_types)
        _ -> Error(UnexpectedEnd)
      }
    }
  }
}

// ─────────────────────────────── per-instruction typing ───────────────────────────────

/// Type-check one instruction against the current state, returning the advanced state
/// (spec: the typing rule for each instruction). `ctx` carries the module-level facts
/// (types, the func/global/table/memory index spaces, the data/elem segment counts,
/// `C.refs`) plus the current function's expanded local types. Every reference/table/
/// bulk op has an EXPLICIT arm before the numeric fallthrough, so an unhandled opcode
/// can only be an unreachable decode state (fail-closed). Any violation is a typed
/// `ValidateError`.
fn validate_instr(
  st: VState,
  instr: Instr,
  ctx: Ctx,
) -> Result(VState, ValidateError) {
  case instr {
    ast.Unreachable -> mark_unreachable(st)
    ast.Nop -> Ok(st)

    // structured control --------------------------------------------------------
    ast.Block(bt) -> {
      use #(in_t, out_t) <- result.try(blocktype_types(bt, ctx.types))
      use st2 <- result.try(pop_vals(st, in_t))
      Ok(push_ctrl(st2, KBlock, in_t, out_t))
    }
    ast.Loop(bt) -> {
      use #(in_t, out_t) <- result.try(blocktype_types(bt, ctx.types))
      use st2 <- result.try(pop_vals(st, in_t))
      Ok(push_ctrl(st2, KLoop, in_t, out_t))
    }
    ast.If(bt) -> {
      use #(in_t, out_t) <- result.try(blocktype_types(bt, ctx.types))
      use st2 <- result.try(pop_expect(st, ast.I32))
      use st3 <- result.try(pop_vals(st2, in_t))
      Ok(push_ctrl(st3, KIf, in_t, out_t))
    }
    ast.Else -> {
      use #(frame, st2) <- result.try(pop_ctrl(st))
      case frame.kind {
        KIf ->
          // Re-open as an else frame with the same in/out so the matching `end`
          // checks the else arm against the same result types.
          Ok(push_ctrl(st2, KElse, frame.start_types, frame.end_types))
        _ -> Error(UnexpectedEnd)
      }
    }
    ast.End -> {
      use #(frame, st2) <- result.try(pop_ctrl(st))
      // An `if` frame reaching `end` directly means no `else` was present, which is
      // only valid when the params and results coincide (spec: else-less `if`).
      case frame.kind == KIf && frame.start_types != frame.end_types {
        True -> Error(IfElseMismatch)
        False -> Ok(push_vals(st2, frame.end_types))
      }
    }

    // branches ------------------------------------------------------------------
    ast.Br(l) -> {
      use frame <- result.try(label_frame(st, l))
      use st2 <- result.try(pop_vals(st, label_types(frame)))
      mark_unreachable(st2)
    }
    ast.BrIf(l) -> {
      use frame <- result.try(label_frame(st, l))
      let lt = label_types(frame)
      use st2 <- result.try(pop_expect(st, ast.I32))
      use st3 <- result.try(pop_vals(st2, lt))
      Ok(push_vals(st3, lt))
    }
    ast.BrTable(targets, default) -> validate_br_table(st, targets, default)
    ast.Return -> {
      // `return` targets the outermost (function) frame.
      use func_frame <- result.try(case list.last(st.ctrls) {
        Ok(fr) -> Ok(fr)
        Error(_) -> Error(UnexpectedEnd)
      })
      use st2 <- result.try(pop_vals(st, func_frame.end_types))
      mark_unreachable(st2)
    }

    // calls ---------------------------------------------------------------------
    ast.Call(f) -> {
      use sig <- result.try(case nth(ctx.func_types, f) {
        Ok(s) -> Ok(s)
        Error(_) -> Error(UnknownFunc(f))
      })
      use st2 <- result.try(pop_vals(st, sig.params))
      Ok(push_vals(st2, sig.results))
    }
    // `call_indirect y x`: the static `typeidx y` must be in range and the target
    // table `x` must be in range and hold `funcref` (an `externref` table cannot back
    // an indirect call → `RefTypeMismatch`) (spec `valid/instructions`). Operand
    // order: the i32 table index is on top (popped first), then the type's params;
    // the type's results are pushed. The per-call structural type check is purely
    // DYNAMIC (runtime), not validation.
    ast.CallIndirect(type_idx, table) -> {
      use sig <- result.try(case ast.func_type_at(ctx.types, type_idx) {
        Ok(s) -> Ok(s)
        Error(_) -> Error(UnknownType(type_idx))
      })
      use #(ref_ty, _) <- result.try(table_entry(ctx, table))
      use _ <- result.try(case ref_ty {
        ast.FuncRef -> Ok(Nil)
        _ -> Error(RefTypeMismatch)
      })
      use st2 <- result.try(pop_expect(st, ast.I32))
      use st3 <- result.try(pop_vals(st2, sig.params))
      Ok(push_vals(st3, sig.results))
    }
    // ── Phase-13 tail calls (Q3) — the WASM tail-call proposal typing rule. ──
    // `return_call f`: read the callee signature exactly like `ast.Call` (funcidx in
    // range → `UnknownFunc`), pop the callee's params, then REQUIRE the callee's result
    // types to equal the CURRENT function's result types — read as `ast.Return` reads
    // them, from the OUTERMOST (function) control frame's `end_types` via
    // `list.last(st.ctrls)`, NOT the innermost block (a mismatch → the existing
    // `TypeMismatch`, reused; no new `ValidateError` variant). Equality is order-sensitive
    // `List(ValType)` equality, so it rejects both an element-type mismatch (`[i32]` vs
    // `[i64]`) and an arity mismatch (`[]` vs `[i32]`). The stack then goes polymorphic
    // (`mark_unreachable`) exactly like `return` — the continuation is unreachable, so
    // nothing is pushed (WASM tail-call proposal: `return_call` is valid iff callee
    // results == function results, and is stack-polymorphic like `return`).
    ast.ReturnCall(f) -> {
      use sig <- result.try(case nth(ctx.func_types, f) {
        Ok(s) -> Ok(s)
        Error(_) -> Error(UnknownFunc(f))
      })
      use func_frame <- result.try(case list.last(st.ctrls) {
        Ok(fr) -> Ok(fr)
        Error(_) -> Error(UnexpectedEnd)
      })
      use st2 <- result.try(pop_vals(st, sig.params))
      case sig.results == func_frame.end_types {
        False -> Error(TypeMismatch)
        True -> mark_unreachable(st2)
      }
    }
    // `return_call_indirect (type y) x`: the structural prelude is identical to
    // `call_indirect` — the static `typeidx y` must be in range (`UnknownType`), table `x`
    // must hold `funcref` (an `externref` table cannot back an indirect tail call →
    // `RefTypeMismatch`), then pop the i32 index and the callee's params. The added
    // tail-call constraint is the same result-equality gate as `return_call`: the callee
    // (type `y`) result types must equal the current function's result types (else
    // `TypeMismatch`), read from the outermost frame's `end_types`. Then go stack-
    // polymorphic (`mark_unreachable`). The per-call structural FuncType check stays DYNAMIC
    // (runtime), unchanged from `call_indirect` (WASM tail-call proposal validation).
    ast.ReturnCallIndirect(type_idx, table) -> {
      use sig <- result.try(case ast.func_type_at(ctx.types, type_idx) {
        Ok(s) -> Ok(s)
        Error(_) -> Error(UnknownType(type_idx))
      })
      use #(ref_ty, _) <- result.try(table_entry(ctx, table))
      use _ <- result.try(case ref_ty {
        ast.FuncRef -> Ok(Nil)
        _ -> Error(RefTypeMismatch)
      })
      use func_frame <- result.try(case list.last(st.ctrls) {
        Ok(fr) -> Ok(fr)
        Error(_) -> Error(UnexpectedEnd)
      })
      use st2 <- result.try(pop_expect(st, ast.I32))
      use st3 <- result.try(pop_vals(st2, sig.params))
      case sig.results == func_frame.end_types {
        False -> Error(TypeMismatch)
        True -> mark_unreachable(st3)
      }
    }

    // parametric ----------------------------------------------------------------
    ast.Drop -> {
      use #(_, st2) <- result.try(pop_val(st))
      Ok(st2)
    }
    // `select` (untyped, 0x1B): `t t i32 -> t` where `t` is a **number** type; the two
    // values must share a type (spec parametric rule). Phase 5 adds the restriction
    // that a resolved *reference* operand is invalid for untyped select → `BadSelectType`
    // (a `funcref`/`externref` select must use the typed `select t` form). A fully
    // polymorphic pair (both `Unknown`, post-`unreachable`) stays polymorphic.
    ast.Select -> {
      use st2 <- result.try(pop_expect(st, ast.I32))
      use #(t1, st3) <- result.try(pop_val(st2))
      use #(t2, st4) <- result.try(pop_val(st3))
      case types_match(t1, t2) {
        False -> Error(TypeMismatch)
        True -> {
          // The result type is the first concrete of the two operands.
          let t = case t1 {
            Known(_) -> t1
            Unknown -> t2
          }
          case t {
            Known(vt) ->
              case is_reftype(vt) {
                True -> Error(BadSelectType)
                False -> Ok(VState(..st4, vals: [t, ..st4.vals]))
              }
            Unknown -> Ok(VState(..st4, vals: [t, ..st4.vals]))
          }
        }
      }
    }
    // `select t` (typed, 0x1C): the annotation vector must be exactly length 1 (spec
    // parametric rule; a length ≠ 1 → `BadSelectType`); signature `[t t i32] → [t]`
    // with `t` the annotated type — which MAY be a reference type. Pop i32, pop t,
    // pop t, push t.
    ast.SelectT(types) ->
      case types {
        [t] -> {
          use st1 <- result.try(pop_expect(st, ast.I32))
          use st2 <- result.try(pop_expect(st1, t))
          use st3 <- result.try(pop_expect(st2, t))
          Ok(push_val(st3, t))
        }
        _ -> Error(BadSelectType)
      }

    // reference instructions (spec `valid/instructions` §reference) ---------------
    ast.RefNull(rt) -> Ok(push_val(st, rt))
    // `ref.is_null` is reference-polymorphic: pop one operand, which must be a
    // reference type (`FuncRef`/`ExternRef`) or `Unknown`; a numeric operand →
    // `TypeMismatch`. Push i32.
    ast.RefIsNull -> {
      use #(t, st2) <- result.try(pop_val(st))
      case t {
        Unknown -> Ok(push_val(st2, ast.I32))
        Known(vt) ->
          case is_reftype(vt) {
            True -> Ok(push_val(st2, ast.I32))
            False -> Error(TypeMismatch)
          }
      }
    }
    // `ref.func x`: `x` must be a valid funcidx AND declared (`x ∈ C.refs`) — else
    // `UnknownFunc(x)` (out of range) / `UndeclaredFunctionRef(x)` (in range, not
    // declared). Push `funcref`.
    ast.RefFunc(x) -> {
      use _ <- result.try(check_ref_declared(ctx, x))
      Ok(push_val(st, ast.FuncRef))
    }

    // table instructions (spec `valid/instructions` §table) -----------------------
    // `table.get x`: `[i32] → [t]` where `t` is table x's reftype.
    ast.TableGet(x) -> {
      use #(t, _) <- result.try(table_entry(ctx, x))
      use st2 <- result.try(pop_expect(st, ast.I32))
      Ok(push_val(st2, t))
    }
    // `table.set x`: `[i32 t] → []` — pop the value `t` (top), then the i32 index.
    ast.TableSet(x) -> {
      use #(t, _) <- result.try(table_entry(ctx, x))
      use st2 <- result.try(pop_expect(st, t))
      pop_expect(st2, ast.I32)
    }
    // `table.size x`: `[] → [i32]`.
    ast.TableSize(x) -> {
      use #(_, _) <- result.try(table_entry(ctx, x))
      Ok(push_val(st, ast.I32))
    }
    // `table.grow x`: `[t i32] → [i32]` — pop the i32 delta (top), then the init value
    // `t`; push i32 (old size / −1 at runtime).
    ast.TableGrow(x) -> {
      use #(t, _) <- result.try(table_entry(ctx, x))
      use st2 <- result.try(pop_expect(st, ast.I32))
      use st3 <- result.try(pop_expect(st2, t))
      Ok(push_val(st3, ast.I32))
    }
    // `table.fill x`: `[i32 t i32] → []` — pop the i32 count (top), the value `t`,
    // then the i32 offset.
    ast.TableFill(x) -> {
      use #(t, _) <- result.try(table_entry(ctx, x))
      use st2 <- result.try(pop_expect(st, ast.I32))
      use st3 <- result.try(pop_expect(st2, t))
      pop_expect(st3, ast.I32)
    }

    // bulk memory & table (spec `valid/instructions` §memory/§table) --------------
    // `memory.init d m`: `[at(m) i32 i32] → []` — d indexes a data segment (always
    // i32 src/len); m in memory range. Pop len(i32), src(i32), then dest(at(m)).
    ast.MemoryInit(d, m) -> {
      use at <- result.try(mem_addr_type(ctx, m))
      use _ <- result.try(check_data_idx(ctx, d))
      use st2 <- result.try(pop_expect(st, ast.I32))
      use st3 <- result.try(pop_expect(st2, ast.I32))
      pop_expect(st3, at)
    }
    // `data.drop d`: `[] → []` — d indexes a data segment.
    ast.DataDrop(d) -> {
      use _ <- result.try(check_data_idx(ctx, d))
      Ok(st)
    }
    // `memory.copy dm sm`: `[at(dm) at(sm) at3] → []`, `at3 = min(at(dm),at(sm))` (the
    // count is bounded by the narrower memory). Pop count(at3), src(at(sm)), then
    // dest(at(dm)).
    ast.MemoryCopy(dm, sm) -> {
      use at_dst <- result.try(mem_addr_type(ctx, dm))
      use at_src <- result.try(mem_addr_type(ctx, sm))
      let at_count = min_addr_type(at_dst, at_src)
      use st2 <- result.try(pop_expect(st, at_count))
      use st3 <- result.try(pop_expect(st2, at_src))
      pop_expect(st3, at_dst)
    }
    // `memory.fill m`: `[at(m) i32 at(m)] → []` — the value byte is i32 even for a
    // 64-bit memory. Pop count(at), value(i32), then dest(at).
    ast.MemoryFill(m) -> {
      use at <- result.try(mem_addr_type(ctx, m))
      use st2 <- result.try(pop_expect(st, at))
      use st3 <- result.try(pop_expect(st2, ast.I32))
      pop_expect(st3, at)
    }
    // `table.init e t` (wire order elemidx,tableidx — R3): `[i32 i32 i32] → []`; e in
    // elem range, t in table range; the element segment's reftype must equal the
    // target table's (`RefTypeMismatch`). Tables are always i32-indexed.
    ast.TableInit(e, t) -> {
      use elem_rt <- result.try(elem_type(ctx, e))
      use #(tbl_rt, _) <- result.try(table_entry(ctx, t))
      use _ <- result.try(case elem_rt == tbl_rt {
        True -> Ok(Nil)
        False -> Error(RefTypeMismatch)
      })
      pop_three_i32(st)
    }
    // `elem.drop e`: `[] → []` — e indexes an element segment.
    ast.ElemDrop(e) -> {
      use _ <- result.try(elem_type(ctx, e))
      Ok(st)
    }
    // `table.copy dt st` (wire order dst,src): `[i32 i32 i32] → []`; both tables in
    // range; their reftypes must match (`RefTypeMismatch`).
    ast.TableCopy(dt, stbl) -> {
      use #(dst_rt, _) <- result.try(table_entry(ctx, dt))
      use #(src_rt, _) <- result.try(table_entry(ctx, stbl))
      use _ <- result.try(case dst_rt == src_rt {
        True -> Ok(Nil)
        False -> Error(RefTypeMismatch)
      })
      pop_three_i32(st)
    }

    // variable access -----------------------------------------------------------
    ast.LocalGet(i) -> {
      use t <- result.try(local_type(ctx.locals, i))
      Ok(push_val(st, t))
    }
    ast.LocalSet(i) -> {
      use t <- result.try(local_type(ctx.locals, i))
      pop_expect(st, t)
    }
    ast.LocalTee(i) -> {
      use t <- result.try(local_type(ctx.locals, i))
      use st2 <- result.try(pop_expect(st, t))
      Ok(push_val(st2, t))
    }
    // `global.get i` pushes the global's type (valid on any global). `global.set i`
    // pops it, but is valid ONLY if the global is mutable (spec `valid/instructions`).
    ast.GlobalGet(i) ->
      case nth(ctx.globals, i) {
        Ok(#(ty, _)) -> Ok(push_val(st, ty))
        Error(_) -> Error(UnknownGlobal(i))
      }
    ast.GlobalSet(i) ->
      case nth(ctx.globals, i) {
        Ok(#(ty, mutable)) ->
          case mutable {
            False -> Error(ImmutableGlobal(i))
            True -> pop_expect(st, ty)
          }
        Error(_) -> Error(UnknownGlobal(i))
      }

    // constants -----------------------------------------------------------------
    ast.I32Const(_) -> Ok(push_val(st, ast.I32))
    ast.I64Const(_) -> Ok(push_val(st, ast.I64))
    ast.F32Const(_) -> Ok(push_val(st, ast.F32))
    ast.F64Const(_) -> Ok(push_val(st, ast.F64))

    // memory loads (pop i32 address, push the load's result type) ----------------
    // Each carries a memarg whose alignment must satisfy `2^align <= natural bytes`.
    ast.I32Load(m) -> check_load(st, ctx, m, ast.I32, 2)
    ast.I64Load(m) -> check_load(st, ctx, m, ast.I64, 3)
    ast.F32Load(m) -> check_load(st, ctx, m, ast.F32, 2)
    ast.F64Load(m) -> check_load(st, ctx, m, ast.F64, 3)
    ast.I32Load8S(m) -> check_load(st, ctx, m, ast.I32, 0)
    ast.I32Load8U(m) -> check_load(st, ctx, m, ast.I32, 0)
    ast.I32Load16S(m) -> check_load(st, ctx, m, ast.I32, 1)
    ast.I32Load16U(m) -> check_load(st, ctx, m, ast.I32, 1)
    ast.I64Load8S(m) -> check_load(st, ctx, m, ast.I64, 0)
    ast.I64Load8U(m) -> check_load(st, ctx, m, ast.I64, 0)
    ast.I64Load16S(m) -> check_load(st, ctx, m, ast.I64, 1)
    ast.I64Load16U(m) -> check_load(st, ctx, m, ast.I64, 1)
    ast.I64Load32S(m) -> check_load(st, ctx, m, ast.I64, 2)
    ast.I64Load32U(m) -> check_load(st, ctx, m, ast.I64, 2)

    // memory stores (pop value then i32 address; push nothing) -------------------
    // The `signed` distinction is irrelevant for stores (a store writes the low N
    // bits), so it is not part of the value type. Alignment is checked as for loads.
    ast.I32Store(m) -> check_store(st, ctx, m, ast.I32, 2)
    ast.I64Store(m) -> check_store(st, ctx, m, ast.I64, 3)
    ast.F32Store(m) -> check_store(st, ctx, m, ast.F32, 2)
    ast.F64Store(m) -> check_store(st, ctx, m, ast.F64, 3)
    ast.I32Store8(m) -> check_store(st, ctx, m, ast.I32, 0)
    ast.I32Store16(m) -> check_store(st, ctx, m, ast.I32, 1)
    ast.I64Store8(m) -> check_store(st, ctx, m, ast.I64, 0)
    ast.I64Store16(m) -> check_store(st, ctx, m, ast.I64, 1)
    ast.I64Store32(m) -> check_store(st, ctx, m, ast.I64, 2)

    // memory size/grow — route by `memidx`; result/operand width is the memory's
    // address type (`i32` for a 32-bit memory, `i64` for a 64-bit one) -----------
    // `memory.size m`: `[] → [at(m)]`. `memory.grow m`: `[at(m)] → [at(m)]`.
    ast.MemorySize(m) -> {
      use at <- result.try(mem_addr_type(ctx, m))
      Ok(push_val(st, at))
    }
    ast.MemoryGrow(m) -> {
      use at <- result.try(mem_addr_type(ctx, m))
      use st2 <- result.try(pop_expect(st, at))
      Ok(push_val(st2, at))
    }

    // SIMD («WASM-AST4», the 0xFD family) — real typing (P6-04). Every SIMD `Instr`
    // constructor is intercepted HERE, BEFORE the `validate_numeric` fallthrough, so
    // none can reach `numeric_sig`'s fail-OPEN `_ -> #([], [])` catch-all (S1 — the
    // fail-closed security invariant). `v128.const` pushes a `v128`; the pure lane ops
    // route to the exhaustive `validate_simd`; `i8x16.shuffle` bounds its 16 indices
    // (`< 32`) then `[v128 v128] → [v128]`; the four v128 memory ops route through the
    // SAME `mem_addr_type`/`check_align`/`check_offset` seam as scalar loads (the
    // memory64 seam — a 64-bit memory pops an `i64` address).
    ast.V128Const(_) -> Ok(push_val(st, ast.V128))
    ast.Simd(op) -> validate_simd(st, op)
    ast.I8x16Shuffle(lanes) -> {
      use _ <- result.try(list.try_each(lanes, fn(x) { check_lane(x, 32) }))
      use st2 <- result.try(pop_vals(st, [ast.V128, ast.V128]))
      Ok(push_val(st2, ast.V128))
    }
    ast.SimdLoad(kind, arg) ->
      check_simd_load(st, ctx, arg, simd_load_max_align(kind))
    ast.SimdStore(arg) -> check_simd_store(st, ctx, arg, 4)
    ast.SimdLoadLane(width, arg, lane) ->
      check_simd_load_lane(
        st,
        ctx,
        arg,
        bits_max_align(width),
        lane,
        simd_lane_count(width),
      )
    ast.SimdStoreLane(width, arg, lane) ->
      check_simd_store_lane(
        st,
        ctx,
        arg,
        bits_max_align(width),
        lane,
        simd_lane_count(width),
      )

    // exception handling («WASM-AST5», Phase 7). Every EH `Instr` constructor — the
    // three MODERN ops and the five LEGACY ops — is intercepted HERE with REAL typing,
    // BEFORE the `validate_numeric` fallthrough, so none reaches `numeric_sig`'s
    // fail-OPEN `_ -> #([], [])` catch-all (T2 — the fail-closed-COMPLETE security
    // invariant: an ill-typed / mis-nested EH form is a typed `Error`, never a silent
    // no-op). Both encodings are fully typed (they are the headline Porffor path); the
    // spec-conformance-only modern surface (`throw_ref`/`try_table` catch-`_ref`) is
    // typed uniformly through the same abstract stack.
    // `throw x` (0x08): pop the tag's operand types (spec `[t1* t*] -> [t2*]`) then
    // stack-polymorphic — a bottom, does NOT push (spec `throw` rule; §E.1).
    ast.Throw(x) -> {
      use operands <- result.try(tag_operands(ctx, x))
      use st2 <- result.try(pop_vals(st, operands))
      mark_unreachable(st2)
    }
    // `throw_ref` (0x0A): pop one `exnref` (spec `[t1* exnref] -> [t2*]`) then
    // stack-polymorphic (§E.2). The null-`exnref` trap is RUNTIME, not validation.
    ast.ThrowRef -> {
      use st2 <- result.try(pop_expect(st, ast.ExnRef))
      mark_unreachable(st2)
    }
    // `try_table bt catch*` (0x1F): a block-like structured opener whose body is typed
    // against the blocktype (label targets its RESULT types, like `block`, so `KBlock`).
    // Each catch clause constrains a target label to the catch-type — validated against
    // the CURRENT label context, BEFORE the try_table's own frame is pushed (§F.2, a
    // load-bearing timing: `catch x 0` targets the innermost ENCLOSING block).
    ast.TryTable(bt, catches) -> {
      use #(in_t, out_t) <- result.try(blocktype_types(bt, ctx.types))
      use _ <- result.try(
        list.try_each(catches, fn(c) { check_catch(st, ctx, c) }),
      )
      use st2 <- result.try(pop_vals(st, in_t))
      Ok(push_ctrl(st2, KBlock, in_t, out_t))
    }

    // ── legacy EH (MEASURED: what Porffor 0.61.13 emits — the legacy exception-handling
    // proposal's validation). `try` is a block-structured construct: the body region is
    // typed against the blocktype, then each `catch`/`catch_all` handler region is typed
    // with the tag's operands (resp. nothing) pushed against the SAME result types. The
    // handler markers are the flat-stream analogue of `if`/`else`: `pop_ctrl` the current
    // region (checking it produced the results), then `push_ctrl` a new region. ──
    // `try bt` (0x06): open a `KTry` body region (label targets its results, like a
    // block). Consumes the blocktype params, produces its results on a normal exit.
    ast.TryLegacy(bt) -> {
      use #(in_t, out_t) <- result.try(blocktype_types(bt, ctx.types))
      use st2 <- result.try(pop_vals(st, in_t))
      Ok(push_ctrl(st2, KTry, in_t, out_t))
    }
    // `catch x` (0x07): end the preceding region (the try body or an earlier `catch`) —
    // which must have produced the try's result types — and begin the handler for tag
    // `x` with the tag's OPERAND types pushed, typed against the same results. A `catch`
    // may not follow a `catch_all` (spec grammar `catch* catch_all?`).
    ast.LegacyCatch(x) -> {
      use ops <- result.try(tag_operands(ctx, x))
      use #(frame, st2) <- result.try(pop_ctrl(st))
      use _ <- result.try(require_try_region(frame))
      Ok(push_ctrl(st2, KCatch, ops, frame.end_types))
    }
    // `catch_all` (0x19): as `catch` but the handler receives NO operands. It is the last
    // handler (nothing may follow it but `end`), so the region it closes must be a `KTry`
    // body or a `KCatch` (never another `KCatchAll`).
    ast.LegacyCatchAll -> {
      use #(frame, st2) <- result.try(pop_ctrl(st))
      use _ <- result.try(require_try_region(frame))
      Ok(push_ctrl(st2, KCatchAll, [], frame.end_types))
    }
    // `delegate l` (0x18): closes the enclosing `try` body (REPLACING its `end`) and
    // forwards an uncaught exception to the `l`-th enclosing construct. Value-stack
    // effect is a block's (produce the results on normal exit); the frame it closes must
    // be the bare `try` body (`KTry`, no handlers), and `l` must name an enclosing frame
    // (resolved in the context OUTSIDE the try — `mis-nested`/out-of-range → UnknownLabel).
    ast.LegacyDelegate(l) -> {
      use #(frame, st2) <- result.try(pop_ctrl(st))
      use _ <- result.try(case frame.kind {
        KTry -> Ok(Nil)
        _ -> Error(UnexpectedEnd)
      })
      use _ <- result.try(label_frame(st2, l))
      Ok(push_vals(st2, frame.end_types))
    }
    // `rethrow l` (0x09): re-raise the exception caught by the `l`-th enclosing handler —
    // stack-polymorphic (a bottom, like `throw`). `l` must name an enclosing `catch`/
    // `catch_all` handler frame; a label that is out of range OR does not denote a catch
    // handler is `UnknownLabel` (there is no catch label at that depth).
    ast.Rethrow(l) -> {
      use frame <- result.try(label_frame(st, l))
      use _ <- result.try(case frame.kind {
        KCatch | KCatchAll -> Ok(Nil)
        _ -> Error(UnknownLabel(l))
      })
      mark_unreachable(st)
    }

    // numeric / comparison / conversion / float leaves --------------------------
    _ -> validate_numeric(st, instr)
  }
}

/// Type a memory load: resolve the memarg's memory (`memidx`) and its address width,
/// check the memarg alignment + offset, pop the address (`i32`/`i64` per the memory),
/// push the load's `result` type. `max_align` is the log2 of the natural access
/// byte-width (e.g. `2` for a 4-byte access). `Error(UnknownMemory(memidx))` if the
/// memidx is out of range.
fn check_load(
  st: VState,
  ctx: Ctx,
  memarg: MemArg,
  result: ValType,
  max_align: Int,
) -> Result(VState, ValidateError) {
  use at <- result.try(mem_addr_type(ctx, memarg.mem))
  use _ <- result.try(check_align(memarg, max_align))
  use _ <- result.try(check_offset(memarg, at))
  use st2 <- result.try(pop_expect(st, at))
  Ok(push_val(st2, result))
}

/// Type a memory store: resolve the memory + address width, check the memarg
/// alignment + offset, pop the `value` (top of stack) then the address, push nothing.
/// `max_align` is as `check_load`.
fn check_store(
  st: VState,
  ctx: Ctx,
  memarg: MemArg,
  value: ValType,
  max_align: Int,
) -> Result(VState, ValidateError) {
  use at <- result.try(mem_addr_type(ctx, memarg.mem))
  use _ <- result.try(check_align(memarg, max_align))
  use _ <- result.try(check_offset(memarg, at))
  use st2 <- result.try(pop_expect(st, value))
  pop_expect(st2, at)
}

/// Validate a memarg's alignment (spec `valid/instructions` memarg rule): "the
/// alignment `2^align` must not be larger than `N/8`". Since `N/8 = 2^max_align`,
/// this is exactly `align <= max_align`; a larger `align` is `Error(BadAlignment)`.
/// The rule follows the *access* width, NOT the address width, so it is identical for
/// 32- and 64-bit memories. Alignment is a non-semantic hint — under-alignment is
/// always legal and never rejected; the value is discarded after this check.
fn check_align(memarg: MemArg, max_align: Int) -> Result(Nil, ValidateError) {
  case memarg.align > max_align {
    True -> Error(BadAlignment)
    False -> Ok(Nil)
  }
}

/// The static memarg offset must fit the memory's address range (spec
/// `valid/instructions` memarg rule). Decode reads the offset as a `u64` (the memory64
/// width, P5-03). For a 32-bit (`Idx32`) memory a valid offset is `< 2^32`; a larger
/// one (e.g. `align.wast`'s "offset out of range") is `Error(OffsetOutOfRange)`. A
/// 64-bit (`Idx64`) memory's offset may be any `u64`, so it is always in range (R12).
fn check_offset(memarg: MemArg, at: ValType) -> Result(Nil, ValidateError) {
  case at {
    ast.I32 ->
      case memarg.offset >= offset32_limit {
        True -> Error(OffsetOutOfRange)
        False -> Ok(Nil)
      }
    _ -> Ok(Nil)
  }
}

// ─────────────────────────────── SIMD typing («WASM-AST4», Phase 6) ───────────────────────────────
// Spec: <https://webassembly.github.io/spec/core/valid/instructions.html#vector-instructions>.
// The abstract stack absorbs `v128` generically (it is just another `ValType`); these
// helpers add the SIMD-specific typing rules — per-op operand/result signatures, static
// lane-immediate bounds, and the v128 memory family — all fail-closed (S1 / §H). SIMD
// lane ops never trap (I3): the only SIMD trap surface is a memory-bounds trap, a
// RUNTIME check (P6-07/08), not validation.

/// The lane count `dim(shape)` of a SIMD shape (spec vector conventions): the number of
/// lanes the 128-bit vector is divided into — `i8x16 = 16`, `i16x8 = 8`, `i32x4 = 4`,
/// `i64x2 = 2`, `f32x4 = 4`, `f64x2 = 2`. Bounds `extract_lane`/`replace_lane` lane
/// immediates (`lane < dim`).
fn simd_dim(shape: ast.SimdShape) -> Int {
  case shape {
    ast.I8x16 -> 16
    ast.I16x8 -> 8
    ast.I32x4 -> 4
    ast.I64x2 -> 2
    ast.F32x4 -> 4
    ast.F64x2 -> 2
  }
}

/// The scalar value type a shape's lane packs/unpacks to (spec `unpacked(shape)`): a
/// lane narrower than 32 bits unpacks to `i32` (`i8x16`/`i16x8 → i32`, hence the
/// sign-choosing `extract_lane_s`/`_u`), a 32-bit-and-wider lane to its own width
/// (`i32x4 → i32`, `i64x2 → i64`, `f32x4 → f32`, `f64x2 → f64`). Drives `splat` /
/// `extract_lane` / `replace_lane` typing.
fn simd_unpacked(shape: ast.SimdShape) -> ValType {
  case shape {
    ast.I8x16 -> ast.I32
    ast.I16x8 -> ast.I32
    ast.I32x4 -> ast.I32
    ast.I64x2 -> ast.I64
    ast.F32x4 -> ast.F32
    ast.F64x2 -> ast.F64
  }
}

/// A static lane immediate `lane` is valid iff `0 <= lane < dim` (spec vector-
/// instruction lane rule: "the lane index must be smaller than `dim`"). An out-of-range
/// (or, defensively, negative) index is `Error(BadLaneIndex(lane))` — the fail-closed
/// rejection that lets `rt_simd` (P6-07) decode the lane with no bounds re-check (§H).
fn check_lane(lane: Int, dim: Int) -> Result(Nil, ValidateError) {
  case lane >= 0 && lane < dim {
    True -> Ok(Nil)
    False -> Error(BadLaneIndex(lane))
  }
}

/// Type-check a pure lane-wise SIMD op (`ast.Simd(op)`) against the abstract stack
/// (spec vector instructions). Two fail-closed steps: (1) bound any static lane
/// immediate (`extract_lane`/`replace_lane`, `lane < dim`) via `check_simd_lane_imm`;
/// (2) apply the op's fixed operand→result signature (`simd_sig`), which also rejects a
/// shape the op has no standardized instruction for. NOTE comparisons yield a `v128`
/// lane MASK (`[v128 v128] → [v128]`), NOT `i32` (the spec `vrelop` rule — a classic
/// pitfall). Never traps.
fn validate_simd(st: VState, op: ast.SimdOp) -> Result(VState, ValidateError) {
  use _ <- result.try(check_simd_lane_imm(op))
  use #(ins, outs) <- result.try(simd_sig(op))
  use st2 <- result.try(pop_vals(st, ins))
  Ok(push_vals(st2, outs))
}

/// Bound the static lane immediate of a lane-access SIMD op (spec: `extract_lane` /
/// `replace_lane` require `lane < dim(shape)`); every other `SimdOp` carries no lane
/// immediate and passes through `Ok(Nil)`. `Error(BadLaneIndex(lane))` on a violation.
fn check_simd_lane_imm(op: ast.SimdOp) -> Result(Nil, ValidateError) {
  case op {
    ast.SExtractLane(shape, lane)
    | ast.SExtractLaneS(shape, lane)
    | ast.SExtractLaneU(shape, lane)
    | ast.SReplaceLane(shape, lane) -> check_lane(lane, simd_dim(shape))
    _ -> Ok(Nil)
  }
}

/// `Ok(sig)` iff `shape` is one of `allowed`, else a fail-closed reject: the `(op,
/// shape)` pair denotes no standardized SIMD instruction (e.g. `i8x16.mul`,
/// `i64x2.min_s`, `i64x2.lt_u`, `i16x8.popcnt`). The AST `SimdOp` enum is
/// shape-permissive (one constructor tags all applicable shapes) but decode never emits
/// an illegal combo, so this arm is unreachable from decoded input — it exists only to
/// keep the validator TOTAL + fail-closed over any `SimdOp` value.
fn require_shape(
  shape: ast.SimdShape,
  allowed: List(ast.SimdShape),
  sig: #(List(ValType), List(ValType)),
) -> Result(#(List(ValType), List(ValType)), ValidateError) {
  case list.contains(allowed, shape) {
    True -> Ok(sig)
    False -> Error(Unsupported("simd: no instruction for this (op, shape)"))
  }
}

/// The `#(operands, results)` abstract-stack signature of a pure lane-wise `SimdOp`
/// (spec vector instructions), or a fail-closed `Error` for an illegal `(op, shape)`
/// combo (`require_shape`). Signature classes: vector unary `[v128] → [v128]`; vector
/// binary / comparison(→mask) / swizzle / dot / q15 / extmul / narrow `[v128 v128] →
/// [v128]`; shift `[v128 i32] → [v128]` (the count is an `i32`, whatever the lane
/// width); test / bitmask `[v128] → [i32]`; bitselect `[v128 v128 v128] → [v128]`;
/// splat `[unpacked(shape)] → [v128]`; extract `[v128] → [unpacked(shape)]`; replace
/// `[v128 unpacked(shape)] → [v128]` (the scalar is on top). The lane-immediate BOUND
/// is `check_simd_lane_imm`; this gives only the type signature. Exhaustive on `SimdOp`
/// (the compiler enforces it — the fail-closed guarantee, §H).
fn simd_sig(
  op: ast.SimdOp,
) -> Result(#(List(ValType), List(ValType)), ValidateError) {
  let v128 = ast.V128
  let i32 = ast.I32
  let unop = #([v128], [v128])
  let binop = #([v128, v128], [v128])
  let shiftop = #([v128, i32], [v128])
  let testop = #([v128], [i32])
  let ternop = #([v128, v128, v128], [v128])
  // legal-shape sets per op family (spec §9.1 / the standardized SIMD opcode set)
  let ints = [ast.I8x16, ast.I16x8, ast.I32x4, ast.I64x2]
  let ints_no64 = [ast.I8x16, ast.I16x8, ast.I32x4]
  let small_ints = [ast.I8x16, ast.I16x8]
  let mul_shapes = [ast.I16x8, ast.I32x4, ast.I64x2]
  let floats = [ast.F32x4, ast.F64x2]
  case op {
    // ── integer arithmetic (integer shapes) ──
    ast.SAdd(s) -> require_shape(s, ints, binop)
    ast.SSub(s) -> require_shape(s, ints, binop)
    // no `i8x16.mul` in the standard — i16x8/i32x4/i64x2 only
    ast.SMul(s) -> require_shape(s, mul_shapes, binop)
    ast.SNeg(s) -> require_shape(s, ints, unop)
    ast.SAbs(s) -> require_shape(s, ints, unop)
    // saturating add/sub is i8x16/i16x8 only
    ast.SAddSatS(s) -> require_shape(s, small_ints, binop)
    ast.SAddSatU(s) -> require_shape(s, small_ints, binop)
    ast.SSubSatS(s) -> require_shape(s, small_ints, binop)
    ast.SSubSatU(s) -> require_shape(s, small_ints, binop)
    // min/max is i8x16/i16x8/i32x4 (no i64x2)
    ast.SMinS(s) -> require_shape(s, ints_no64, binop)
    ast.SMinU(s) -> require_shape(s, ints_no64, binop)
    ast.SMaxS(s) -> require_shape(s, ints_no64, binop)
    ast.SMaxU(s) -> require_shape(s, ints_no64, binop)
    ast.SAvgrU(s) -> require_shape(s, small_ints, binop)
    // shifts: the count is a single i32 regardless of lane width
    ast.SShl(s) -> require_shape(s, ints, shiftop)
    ast.SShrS(s) -> require_shape(s, ints, shiftop)
    ast.SShrU(s) -> require_shape(s, ints, shiftop)
    ast.SPopcnt(s) -> require_shape(s, [ast.I8x16], unop)
    // ── integer comparisons → v128 mask ──
    ast.SEq(s) -> require_shape(s, ints, binop)
    ast.SNe(s) -> require_shape(s, ints, binop)
    ast.SLtS(s) -> require_shape(s, ints, binop)
    ast.SLeS(s) -> require_shape(s, ints, binop)
    ast.SGtS(s) -> require_shape(s, ints, binop)
    ast.SGeS(s) -> require_shape(s, ints, binop)
    // i64x2 has NO unsigned lt/le/gt/ge
    ast.SLtU(s) -> require_shape(s, ints_no64, binop)
    ast.SLeU(s) -> require_shape(s, ints_no64, binop)
    ast.SGtU(s) -> require_shape(s, ints_no64, binop)
    ast.SGeU(s) -> require_shape(s, ints_no64, binop)
    // ── v128 bitwise (shape-agnostic) + boolean reductions ──
    ast.VNot -> Ok(unop)
    ast.VAnd -> Ok(binop)
    ast.VOr -> Ok(binop)
    ast.VXor -> Ok(binop)
    ast.VAndNot -> Ok(binop)
    ast.VBitselect -> Ok(ternop)
    ast.VAnyTrue -> Ok(testop)
    ast.SAllTrue(s) -> require_shape(s, ints, testop)
    ast.SBitmask(s) -> require_shape(s, ints, testop)
    // ── lane access / build ──
    ast.SSplat(s) -> Ok(#([simd_unpacked(s)], [v128]))
    // extract_lane (no sign) is the 32-bit-and-wider shapes; the s/u variants are the
    // narrow shapes (which unpack to i32). Result = unpacked(shape).
    ast.SExtractLane(s, _) ->
      require_shape(
        s,
        [ast.I32x4, ast.I64x2, ast.F32x4, ast.F64x2],
        #([v128], [simd_unpacked(s)]),
      )
    ast.SExtractLaneS(s, _) -> require_shape(s, small_ints, #([v128], [i32]))
    ast.SExtractLaneU(s, _) -> require_shape(s, small_ints, #([v128], [i32]))
    // replace_lane: [v128 unpacked(shape)] → [v128] (scalar on top), all six shapes
    ast.SReplaceLane(s, _) -> Ok(#([v128, simd_unpacked(s)], [v128]))
    // ── float-lane ops (f32x4 / f64x2) ──
    ast.FAdd(s) -> require_shape(s, floats, binop)
    ast.FSub(s) -> require_shape(s, floats, binop)
    ast.FMul(s) -> require_shape(s, floats, binop)
    ast.FDiv(s) -> require_shape(s, floats, binop)
    ast.FMin(s) -> require_shape(s, floats, binop)
    ast.FMax(s) -> require_shape(s, floats, binop)
    ast.FPMin(s) -> require_shape(s, floats, binop)
    ast.FPMax(s) -> require_shape(s, floats, binop)
    ast.FNeg(s) -> require_shape(s, floats, unop)
    ast.FAbs(s) -> require_shape(s, floats, unop)
    ast.FSqrt(s) -> require_shape(s, floats, unop)
    ast.FCeil(s) -> require_shape(s, floats, unop)
    ast.FFloor(s) -> require_shape(s, floats, unop)
    ast.FTrunc(s) -> require_shape(s, floats, unop)
    ast.FNearest(s) -> require_shape(s, floats, unop)
    // float comparisons → v128 mask
    ast.FEq(s) -> require_shape(s, floats, binop)
    ast.FNe(s) -> require_shape(s, floats, binop)
    ast.FLt(s) -> require_shape(s, floats, binop)
    ast.FLe(s) -> require_shape(s, floats, binop)
    ast.FGt(s) -> require_shape(s, floats, binop)
    ast.FGe(s) -> require_shape(s, floats, binop)
    // ── widen / narrow / extended-multiply / pairwise (`from` = SOURCE shape) ──
    // narrow i16x8→i8x16 / i32x4→i16x8 (saturating): [v128 v128] → [v128]
    ast.SNarrow(from, _) -> require_shape(from, [ast.I16x8, ast.I32x4], binop)
    // extend low/high from a narrower source (i8x16/i16x8/i32x4): [v128] → [v128]
    ast.SExtend(from, _, _) -> require_shape(from, ints_no64, unop)
    // extmul low/high from a narrower source: [v128 v128] → [v128]
    ast.SExtMul(from, _, _) -> require_shape(from, ints_no64, binop)
    // extadd_pairwise from i8x16/i16x8: [v128] → [v128]
    ast.SExtAddPairwise(from, _) -> require_shape(from, small_ints, unop)
    // ── conversions (singular; all [v128] → [v128]) ──
    ast.STruncSatF32x4S -> Ok(unop)
    ast.STruncSatF32x4U -> Ok(unop)
    ast.STruncSatF64x2SZero -> Ok(unop)
    ast.STruncSatF64x2UZero -> Ok(unop)
    ast.SConvertF32x4I32x4S -> Ok(unop)
    ast.SConvertF32x4I32x4U -> Ok(unop)
    ast.SConvertF64x2LowI32x4S -> Ok(unop)
    ast.SConvertF64x2LowI32x4U -> Ok(unop)
    ast.SDemoteF64x2Zero -> Ok(unop)
    ast.SPromoteLowF32x4 -> Ok(unop)
    // ── dot / q15 / swizzle (singular; [v128 v128] → [v128]) ──
    ast.SDotI16x8S -> Ok(binop)
    ast.SQ15MulrSatS -> Ok(binop)
    // swizzle: dynamic byte indices in a v128 (OOB→0 is a RUNTIME semantics, not typing)
    ast.SSwizzle -> Ok(binop)
  }
}

// ─────────────────────────────── SIMD memory family ───────────────────────────────
// Every v128 memory op reuses the SCALAR `mem_addr_type`/`check_align`/`check_offset`
// seam (D2): the memarg alignment cap `2^align <= N/8`, the offset ceiling, and the
// `i32`/`i64` address typing are the SAME rules as scalar loads/stores, with a per-op
// access width N (in BITS — S2). So `v128.load` on a 64-bit memory pops an `i64`
// address exactly as a scalar load does (the memory64 seam, §F).

/// The maximum memarg alignment exponent for a v128 LOAD, from its access width in BITS
/// (spec memarg rule `2^align <= N/8`; RECONCILIATION S2 — widths are bits):
/// `v128.load` accesses 128 bits (`align <= 4`); an extending `load{8x8,16x4,32x2}`
/// accesses 8 bytes = 64 bits (`align <= 3`); a `load{N}_splat`/`load{N}_zero` accesses
/// `N` bits.
fn simd_load_max_align(kind: ast.SimdLoadKind) -> Int {
  case kind {
    ast.LoadV128 -> 4
    ast.LoadSplat(bits) -> bits_max_align(bits)
    // every extending load reads 8 bytes (64 bits) regardless of the source lane width
    ast.LoadExtend(_, _) -> 3
    ast.LoadZero(bits) -> bits_max_align(bits)
  }
}

/// The memarg alignment cap `log2(bits / 8)` for a natural access of `bits` BITS
/// (∈ {8,16,32,64,128} — S2), so `2^align <= bits/8`. A non-standard width falls to `0`
/// (the most conservative cap — fail-closed; unreachable from decoded input).
fn bits_max_align(bits: Int) -> Int {
  case bits {
    8 -> 0
    16 -> 1
    32 -> 2
    64 -> 3
    128 -> 4
    _ -> 0
  }
}

/// The lane count `128 / width` for a v128 `load{N}_lane`/`store{N}_lane` of `width`
/// BITS (∈ {8,16,32,64} — S2): the valid lane index range is `[0, 128/width)`, i.e.
/// `8 → 16`, `16 → 8`, `32 → 4`, `64 → 2`. A non-standard width falls to `0` (rejects
/// every lane — fail-closed; unreachable from decoded input; avoids a division-by-zero).
fn simd_lane_count(width: Int) -> Int {
  case width {
    8 -> 16
    16 -> 8
    32 -> 4
    64 -> 2
    _ -> 0
  }
}

/// Type a v128 LOAD (`v128.load`, the splat/extend/zero loads): resolve the memory +
/// address width, check the memarg alignment (`max_align`) + offset ceiling, pop the
/// address (`i32`/`i64` per the memory), push `v128`. `[at] → [v128]`.
fn check_simd_load(
  st: VState,
  ctx: Ctx,
  memarg: MemArg,
  max_align: Int,
) -> Result(VState, ValidateError) {
  use at <- result.try(mem_addr_type(ctx, memarg.mem))
  use _ <- result.try(check_align(memarg, max_align))
  use _ <- result.try(check_offset(memarg, at))
  use st2 <- result.try(pop_expect(st, at))
  Ok(push_val(st2, ast.V128))
}

/// Type `v128.store`: resolve the memory + address width, check alignment + offset, pop
/// the `v128` value (top of stack) then the address, push nothing. `[at v128] → []`.
fn check_simd_store(
  st: VState,
  ctx: Ctx,
  memarg: MemArg,
  max_align: Int,
) -> Result(VState, ValidateError) {
  use at <- result.try(mem_addr_type(ctx, memarg.mem))
  use _ <- result.try(check_align(memarg, max_align))
  use _ <- result.try(check_offset(memarg, at))
  use st2 <- result.try(pop_expect(st, ast.V128))
  pop_expect(st2, at)
}

/// Type a v128 `load{N}_lane`: resolve the memory + address width, check alignment +
/// offset, bound the lane (`lane < dim = 128/N`), pop the `v128` operand (top) then the
/// address, push the updated `v128`. `[at v128] → [v128]`.
fn check_simd_load_lane(
  st: VState,
  ctx: Ctx,
  memarg: MemArg,
  max_align: Int,
  lane: Int,
  dim: Int,
) -> Result(VState, ValidateError) {
  use at <- result.try(mem_addr_type(ctx, memarg.mem))
  use _ <- result.try(check_align(memarg, max_align))
  use _ <- result.try(check_offset(memarg, at))
  use _ <- result.try(check_lane(lane, dim))
  use st2 <- result.try(pop_expect(st, ast.V128))
  use st3 <- result.try(pop_expect(st2, at))
  Ok(push_val(st3, ast.V128))
}

/// Type a v128 `store{N}_lane`: resolve the memory + address width, check alignment +
/// offset, bound the lane (`lane < dim = 128/N`), pop the `v128` operand (top) then the
/// address, push nothing. `[at v128] → []`.
fn check_simd_store_lane(
  st: VState,
  ctx: Ctx,
  memarg: MemArg,
  max_align: Int,
  lane: Int,
  dim: Int,
) -> Result(VState, ValidateError) {
  use at <- result.try(mem_addr_type(ctx, memarg.mem))
  use _ <- result.try(check_align(memarg, max_align))
  use _ <- result.try(check_offset(memarg, at))
  use _ <- result.try(check_lane(lane, dim))
  use st2 <- result.try(pop_expect(st, ast.V128))
  pop_expect(st2, at)
}

// ─────────────────────────────── reference / index-space helpers ───────────────────────────────

/// `True` iff `vt` is a reference type — the two MVP reftypes (`FuncRef`/`ExternRef`)
/// plus, Phase 7, `ExnRef` (`exnref` IS a reference type per the EH proposal). Used by
/// `ref.is_null`/untyped-`select` (reference-polymorphic / number-only). Adding `ExnRef`
/// here (the ONE load-bearing predicate edit) makes both spec-correct for `exnref` with
/// no further code: untyped `select` of two `exnref`s is rejected (`BadSelectType`, a
/// reftype is not number/vector-typed, §C.3) and `ref.is_null` on an `exnref` is accepted
/// (`exnref` is nullable, §C.4). `V128` stays a NON-reference (it is a vector type).
fn is_reftype(vt: ValType) -> Bool {
  case vt {
    ast.FuncRef | ast.ExternRef | ast.ExnRef -> True
    _ -> False
  }
}

/// The operand types of tag `tagidx` (Phase 7): `ctx.tags[tagidx]` (imports ++ defined),
/// or `Error(UnknownTag(tagidx))` if out of range of the module's tag index space (spec:
/// the EH proposal requires `C.tags[x]` to exist). Read by `throw`, `try_table`'s catch
/// clauses, and legacy `catch`.
fn tag_operands(ctx: Ctx, tagidx: Int) -> Result(List(ValType), ValidateError) {
  case nth(ctx.tags, tagidx) {
    Ok(ops) -> Ok(ops)
    Error(_) -> Error(UnknownTag(tagidx))
  }
}

/// A legacy `catch`/`catch_all` handler may only follow the try body (`KTry`) or an
/// earlier `catch` (`KCatch`) — never a `catch_all` (`KCatchAll`) or a non-try frame
/// (spec grammar `try bt instr* (catch x instr*)* (catch_all instr*)? end`). Any other
/// frame kind is a mis-nested handler → `Error(UnexpectedEnd)`.
fn require_try_region(frame: CtrlFrame) -> Result(Nil, ValidateError) {
  case frame.kind {
    KTry | KCatch -> Ok(Nil)
    _ -> Error(UnexpectedEnd)
  }
}

/// Type one `try_table` catch clause (Phase 7, EH proposal; §F.1): the clause's target
/// label must accept the *catch-type* — the values the handler receives — resolved in the
/// CURRENT label context (`st`, before the try_table's own frame is pushed, §F.2):
///
/// | clause          | catch-type (`required` label types)        |
/// |-----------------|--------------------------------------------|
/// | `catch x l`     | `[t*]` (tag x's operands)                  |
/// | `catch_ref x l` | `[t* exnref]` (operands, then `exnref` on top) |
/// | `catch_all l`   | `[]`                                       |
/// | `catch_all_ref l` | `[exnref]`                               |
///
/// `Error(UnknownTag(x))` if a tag is out of range; the label check is `check_catch_label`.
fn check_catch(
  st: VState,
  ctx: Ctx,
  c: ast.Catch,
) -> Result(Nil, ValidateError) {
  case c {
    ast.Catch(x, l) -> {
      use ops <- result.try(tag_operands(ctx, x))
      check_catch_label(st, l, ops)
    }
    ast.CatchRef(x, l) -> {
      use ops <- result.try(tag_operands(ctx, x))
      check_catch_label(st, l, list.append(ops, [ast.ExnRef]))
    }
    ast.CatchAll(l) -> check_catch_label(st, l, [])
    ast.CatchAllRef(l) -> check_catch_label(st, l, [ast.ExnRef])
  }
}

/// A `try_table` catch clause's target label must have types EXACTLY equal to `required`
/// (the catch-type). Because the 2core MVP has no GC subtyping (the value types are
/// pairwise-incomparable), the match is structural equality — a supertype rule is
/// unnecessary (§F.1). `Error(UnknownLabel(label))` if the label is out of range; a wrong
/// **arity** → `BranchArityMismatch` (as `br_table`); a wrong **element type** →
/// `TypeMismatch` (the caught values are branched to the label, so a label disagreement
/// IS a branch-target arity/type mismatch — the spec-honest reuse of the existing
/// vocabulary, §B.1 D3).
fn check_catch_label(
  st: VState,
  label: Int,
  required: List(ValType),
) -> Result(Nil, ValidateError) {
  use frame <- result.try(label_frame(st, label))
  let lt = label_types(frame)
  case list.length(lt) == list.length(required) {
    False -> Error(BranchArityMismatch)
    True ->
      case lt == required {
        True -> Ok(Nil)
        False -> Error(TypeMismatch)
      }
  }
}

/// The address value type for a memory's index width: `i32` for a 32-bit (`Idx32`)
/// memory, `i64` for a 64-bit (`Idx64`, memory64) one (spec/memory64 proposal).
fn addr_type(it: IdxType) -> ValType {
  case it {
    ast.Idx32 -> ast.I32
    ast.Idx64 -> ast.I64
  }
}

/// The address value type of memory `memidx`, or `Error(UnknownMemory(memidx))` if the
/// index is out of range of the module's memories (imports ++ defined).
fn mem_addr_type(ctx: Ctx, memidx: Int) -> Result(ValType, ValidateError) {
  case nth(ctx.memories, memidx) {
    Ok(it) -> Ok(addr_type(it))
    Error(_) -> Error(UnknownMemory(memidx))
  }
}

/// The narrower of two address types (`i32 < i64`): a `memory.copy` between memories
/// of different widths bounds its count to the narrower one (spec/memory64 copy rule).
fn min_addr_type(a: ValType, b: ValType) -> ValType {
  case a, b {
    ast.I32, _ -> ast.I32
    _, ast.I32 -> ast.I32
    _, _ -> ast.I64
  }
}

/// The `(element reftype, limits)` of table `tableidx`, or `Error(UnknownTable(_))` if
/// out of range of the module's tables (imports ++ defined).
fn table_entry(
  ctx: Ctx,
  tableidx: Int,
) -> Result(#(ValType, Limits), ValidateError) {
  case nth(ctx.tables, tableidx) {
    Ok(entry) -> Ok(entry)
    Error(_) -> Error(UnknownTable(tableidx))
  }
}

/// The reftype of element segment `elemidx`, or `Error(UnknownElem(_))` if out of range
/// of the module's element segments (`table.init`/`elem.drop`).
fn elem_type(ctx: Ctx, elemidx: Int) -> Result(ValType, ValidateError) {
  case nth(ctx.elem_types, elemidx) {
    Ok(rt) -> Ok(rt)
    Error(_) -> Error(UnknownElem(elemidx))
  }
}

/// `dataidx` must be `< data_count` (spec `valid/instructions`; `memory.init`/
/// `data.drop`), else `Error(UnknownData(dataidx))`. The data-count-section *presence*
/// rule is decode's (R13); this checks only the index bound.
fn check_data_idx(ctx: Ctx, dataidx: Int) -> Result(Nil, ValidateError) {
  case dataidx >= 0 && dataidx < ctx.data_count {
    True -> Ok(Nil)
    False -> Error(UnknownData(dataidx))
  }
}

/// A `ref.func x` reference is valid iff `x` is a funcidx in range AND `x ∈ C.refs`
/// (the declared-reference set). Out of range → `UnknownFunc(x)`; in range but not
/// declared → `UndeclaredFunctionRef(x)` (spec `valid/instructions` ref.func rule).
fn check_ref_declared(ctx: Ctx, x: Int) -> Result(Nil, ValidateError) {
  case x >= 0 && x < list.length(ctx.func_types) {
    False -> Error(UnknownFunc(x))
    True ->
      case set.contains(ctx.refs, x) {
        True -> Ok(Nil)
        False -> Error(UndeclaredFunctionRef(x))
      }
  }
}

/// Pop three `i32` operands (the `dst, src, count` of a `table.init`/`table.copy` —
/// tables are always `i32`-indexed regardless of memory64), returning the reduced
/// state. Any operand that is not `i32` → `TypeMismatch`.
fn pop_three_i32(st: VState) -> Result(VState, ValidateError) {
  use st1 <- result.try(pop_expect(st, ast.I32))
  use st2 <- result.try(pop_expect(st1, ast.I32))
  pop_expect(st2, ast.I32)
}

/// Compute `C.refs`: the set of funcidx *declared* in the module (spec appendix
/// `funcidx(module)` free-occurrence collection). A funcidx joins `C.refs` when it
/// occurs OUTSIDE a function body — specifically in a global initializer, an element
/// segment (any mode: active offset/init, passive, declarative), or a **function**
/// export. `start` does NOT join (it is a call, not a reference). Function bodies do
/// not contribute (a `ref.func` in a body *requires* membership, it does not declare).
/// Computed once, up front, before any body/const-expr is validated (§C.1).
fn compute_refs(module: Module) -> Set(Int) {
  let from_globals =
    list.fold(module.globals, set.new(), fn(acc, g) {
      collect_ref_funcs(acc, g.init)
    })
  let from_elems =
    list.fold(module.elements, from_globals, fn(acc, e) {
      let acc2 = case e.mode {
        ast.ElemActive(_, offset) -> collect_ref_funcs(acc, offset)
        _ -> acc
      }
      case e.init {
        ast.ElemFuncs(funcs) ->
          list.fold(funcs, acc2, fn(a, x) { set.insert(a, x) })
        ast.ElemExprs(exprs) ->
          list.fold(exprs, acc2, fn(a, expr) { collect_ref_funcs(a, expr) })
      }
    })
  list.fold(module.exports, from_elems, fn(acc, ex) {
    case ex.kind {
      ast.ExportFunc -> set.insert(acc, ex.index)
      _ -> acc
    }
  })
}

/// Add every funcidx referenced by a `ref.func x` in `instrs` to `acc` (used by
/// `compute_refs` over const-expression instruction lists).
fn collect_ref_funcs(acc: Set(Int), instrs: List(Instr)) -> Set(Int) {
  list.fold(instrs, acc, fn(a, instr) {
    case instr {
      ast.RefFunc(x) -> set.insert(a, x)
      _ -> a
    }
  })
}

/// The control frame at relative depth `l` (0 = innermost), or `Error(UnknownLabel)`.
fn label_frame(st: VState, l: Int) -> Result(CtrlFrame, ValidateError) {
  case nth(st.ctrls, l) {
    Ok(f) -> Ok(f)
    Error(_) -> Error(UnknownLabel(l))
  }
}

/// The declared type of local `i`, or `Error(UnknownLocal(i))` if out of range.
fn local_type(locals: List(ValType), i: Int) -> Result(ValType, ValidateError) {
  case nth(locals, i) {
    Ok(t) -> Ok(t)
    Error(_) -> Error(UnknownLocal(i))
  }
}

/// Validate `br_table` (spec): pop the i32 index; every target and the default must be
/// in range and share the same label arity; each target's label types are checked
/// against the operands; finally the default's types are popped and the rest becomes
/// polymorphic. `Error(UnknownLabel)`/`Error(BranchArityMismatch)` on violations.
fn validate_br_table(
  st: VState,
  targets: List(Int),
  default: Int,
) -> Result(VState, ValidateError) {
  use st1 <- result.try(pop_expect(st, ast.I32))
  use default_frame <- result.try(label_frame(st1, default))
  let default_types = label_types(default_frame)
  let arity = list.length(default_types)
  use st2 <- result.try(
    list.try_fold(targets, st1, fn(s, n) {
      use frame <- result.try(label_frame(s, n))
      let lt = label_types(frame)
      case list.length(lt) == arity {
        False -> Error(BranchArityMismatch)
        True -> {
          // Type-check this target's operands against the stack, then restore them.
          use s2 <- result.try(pop_vals(s, lt))
          Ok(push_vals(s2, lt))
        }
      }
    }),
  )
  use st3 <- result.try(pop_vals(st2, default_types))
  mark_unreachable(st3)
}

// ─────────────────────────────── constant expressions & module items ───────────────────────────────

/// A constant expression (global init / element offset / element item / data offset)
/// is valid iff it is a single producing instruction from the Phase-5 constant grammar
/// (spec `valid/instructions`, constant expressions):
///
/// - `t.const c` → `t` (including `v128.const` → `v128`, Phase 6); `ref.null t` → the
///   reftype `t`; `ref.func x` → `funcref` (valid iff `x` is a funcidx in range AND
///   `x ∈ C.refs`); `global.get x` → `globals[x].0` (valid ONLY when `x` is an
///   **imported, immutable** global).
///
/// Everything else — extended-const `i32.add`/… chains, a `global.get` of a *defined*
/// or *mutable* global — is `Error(NonConstantExpr)`. The produced type must equal
/// `expected`, else `Error(TypeMismatch)` (numeric or reference). `ctx` supplies the
/// `C.refs` set and imported-global lookup.
fn validate_const_expr(
  init: List(Instr),
  expected: ValType,
  ctx: Ctx,
) -> Result(Nil, ValidateError) {
  case init {
    [ast.I32Const(_)] -> expect_const_type(ast.I32, expected)
    [ast.I64Const(_)] -> expect_const_type(ast.I64, expected)
    [ast.F32Const(_)] -> expect_const_type(ast.F32, expected)
    [ast.F64Const(_)] -> expect_const_type(ast.F64, expected)
    // `v128.const c` is a valid constant instruction (spec constant expressions list
    // `t.const`, which includes `v128.const`); no other SIMD op is constant, so any
    // other `Simd(_)`/`SimdLoad`/… in a const-expr falls to `NonConstantExpr` below.
    [ast.V128Const(_)] -> expect_const_type(ast.V128, expected)
    [ast.RefNull(rt)] -> expect_const_type(rt, expected)
    [ast.RefFunc(x)] -> {
      use _ <- result.try(check_ref_declared(ctx, x))
      expect_const_type(ast.FuncRef, expected)
    }
    [ast.GlobalGet(x)] -> const_global_get(ctx, x, expected)
    _ -> Error(NonConstantExpr)
  }
}

/// A `global.get x` in a constant expression is constant ONLY when `x` refers to an
/// **imported, immutable** global (spec constant expressions): `x < imported_global_count`
/// and `globals[x].mutable == False`. Otherwise (a defined or mutable global) it is
/// `Error(NonConstantExpr)`. On success the referenced global's type must equal
/// `expected`, else `Error(TypeMismatch)`.
fn const_global_get(
  ctx: Ctx,
  x: Int,
  expected: ValType,
) -> Result(Nil, ValidateError) {
  case x >= 0 && x < ctx.imported_global_count {
    False -> Error(NonConstantExpr)
    True ->
      case nth(ctx.globals, x) {
        Ok(#(ty, False)) -> expect_const_type(ty, expected)
        // an imported MUTABLE global is not a constant referent
        Ok(#(_, True)) -> Error(NonConstantExpr)
        Error(_) -> Error(NonConstantExpr)
      }
  }
}

/// `Ok(Nil)` if a const-expr's produced type matches `expected`, else `TypeMismatch`.
/// (A reference-type disagreement in a const-expr is a plain operand mismatch — the
/// dedicated `RefTypeMismatch` is reserved for `table.init`/`table.copy`/active-elem/
/// `call_indirect` reftype disagreements, per the error vocabulary in §B.1.)
fn expect_const_type(
  actual: ValType,
  expected: ValType,
) -> Result(Nil, ValidateError) {
  case actual == expected {
    True -> Ok(Nil)
    False -> Error(TypeMismatch)
  }
}

/// Every global's init expr is a constant expression of the global's declared type
/// (spec `valid/modules` globals). `Error(NonConstantExpr)`/`Error(TypeMismatch)`.
fn check_global_inits(
  globals: List(ast.Global),
  ctx: Ctx,
) -> Result(Nil, ValidateError) {
  list.try_each(globals, fn(g) { validate_const_expr(g.init, g.ty, ctx) })
}

/// Validate every element segment (spec `valid/modules` elements). For every mode each
/// init item is a constant expression producing the segment's reftype; an active
/// segment additionally requires its target table in range, that table's reftype to
/// equal the segment's (`RefTypeMismatch`), and an `i32` offset const-expr (tables are
/// `i32`-indexed). Passive/declarative segments carry no table/offset. `Error(_)` on
/// any index/type/const violation.
fn check_elements(module: Module, ctx: Ctx) -> Result(Nil, ValidateError) {
  list.try_each(module.elements, fn(e) {
    use _ <- result.try(check_elem_init(e, ctx))
    case e.mode {
      ast.ElemActive(table, offset) -> {
        use #(tbl_rt, _) <- result.try(table_entry(ctx, table))
        use _ <- result.try(case tbl_rt == e.ref_ty {
          True -> Ok(Nil)
          False -> Error(RefTypeMismatch)
        })
        validate_const_expr(offset, ast.I32, ctx)
      }
      ast.ElemPassive -> Ok(Nil)
      ast.ElemDeclarative -> Ok(Nil)
    }
  })
}

/// Validate a segment's init items against its reftype (spec `valid/modules`). An
/// `ElemFuncs` funcidx vector is an implicit `ref.func` per entry — each funcidx must
/// be in range and declared (`C.refs`) and the segment's reftype must be `funcref`;
/// an `ElemExprs` vector is a list of constant expressions each producing the reftype.
fn check_elem_init(
  e: ast.ElementSegment,
  ctx: Ctx,
) -> Result(Nil, ValidateError) {
  case e.init {
    ast.ElemFuncs(funcs) -> {
      use _ <- result.try(expect_const_type(ast.FuncRef, e.ref_ty))
      list.try_each(funcs, fn(x) { check_ref_declared(ctx, x) })
    }
    ast.ElemExprs(exprs) ->
      list.try_each(exprs, fn(expr) { validate_const_expr(expr, e.ref_ty, ctx) })
  }
}

/// Validate every data segment (spec `valid/modules` data). An active segment's target
/// memory must be in range and its offset is a constant expression of THAT memory's
/// index type (`i32` for a 32-bit memory, `i64` for a 64-bit one — the one place a
/// data offset is not `i32`). A passive segment carries no memory/offset.
fn check_data(module: Module, ctx: Ctx) -> Result(Nil, ValidateError) {
  list.try_each(module.data, fn(d) {
    case d.mode {
      ast.DataActive(mem, offset) -> {
        use at <- result.try(mem_addr_type(ctx, mem))
        validate_const_expr(offset, at, ctx)
      }
      ast.DataPassive -> Ok(Nil)
    }
  })
}

/// Validate the export section (spec `valid/modules`): every export name is distinct
/// and every export index is in range of the space its kind selects. A duplicate name
/// → `Error(UnknownImportKind("duplicate export"))`; an out-of-range index → the
/// matching `Unknown*` variant. Function exports have already contributed to `C.refs`.
fn check_exports(module: Module, ctx: Ctx) -> Result(Nil, ValidateError) {
  use _ <- result.try(check_export_names_unique(module.exports))
  list.try_each(module.exports, fn(ex) {
    // A tag export (`ExportTag`, Phase 7) range-checks its index against the tag index
    // space (imports ++ defined); the link-time tag *satisfaction* is downstream (§G).
    let count = case ex.kind {
      ast.ExportFunc -> list.length(ctx.func_types)
      ast.ExportTable -> list.length(ctx.tables)
      ast.ExportMemory -> list.length(ctx.memories)
      ast.ExportGlobal -> list.length(ctx.globals)
      ast.ExportTag -> list.length(ctx.tags)
    }
    case ex.index >= 0 && ex.index < count {
      True -> Ok(Nil)
      False ->
        case ex.kind {
          ast.ExportFunc -> Error(UnknownFunc(ex.index))
          ast.ExportTable -> Error(UnknownTable(ex.index))
          ast.ExportMemory -> Error(UnknownMemory(ex.index))
          ast.ExportGlobal -> Error(UnknownGlobal(ex.index))
          ast.ExportTag -> Error(UnknownTag(ex.index))
        }
    }
  })
}

/// Reject a module with two exports sharing a name (spec `valid/modules`: export names
/// must be distinct) → `Error(UnknownImportKind("duplicate export"))`. Total.
fn check_export_names_unique(
  exports: List(ast.Export),
) -> Result(Nil, ValidateError) {
  let names = list.map(exports, fn(ex) { ex.name })
  case list.length(names) == set.size(set.from_list(names)) {
    True -> Ok(Nil)
    False -> Error(UnknownImportKind("duplicate export"))
  }
}

/// If a `start` function is present, its funcidx is in range and its type is `[] -> []`
/// (spec `valid/modules` start). `Error(UnknownFunc(_))`/`Error(BadStartType)`.
fn check_start(
  module: Module,
  func_types: List(FuncType),
) -> Result(Nil, ValidateError) {
  case module.start {
    option.None -> Ok(Nil)
    option.Some(idx) ->
      case nth(func_types, idx) {
        Error(_) -> Error(UnknownFunc(idx))
        Ok(ast.FuncType(params, results)) ->
          case params == [] && results == [] {
            True -> Ok(Nil)
            False -> Error(BadStartType)
          }
      }
  }
}

// ─────────────────────────────── numeric typing tables ───────────────────────────────

/// Type-check a numeric / comparison / conversion / float leaf instruction by its
/// fixed operand→result signature (spec: the numeric typing rules). Every Phase-1 and
/// Phase-2 numeric leaf has an explicit arm in `numeric_sig`; this just applies it.
fn validate_numeric(st: VState, instr: Instr) -> Result(VState, ValidateError) {
  let #(ins, outs) = numeric_sig(instr)
  use st2 <- result.try(pop_vals(st, ins))
  Ok(push_vals(st2, outs))
}

/// The `#(operands, results)` signature of every numeric/comparison/conversion/float
/// leaf opcode. Integer binary ops take two same-width operands and yield one;
/// comparisons yield `i32`; `eqz`/unary keep one operand; sign-extension and the two
/// truncation families follow their spec source/target widths; the float arith/unary/
/// copysign ops are width-preserving and the float comparisons yield `i32`; the
/// `0xA7–0xBF` conversion block is width-only (trapping vs. saturating is a runtime
/// concern with identical signatures).
fn numeric_sig(instr: Instr) -> #(List(ValType), List(ValType)) {
  let i32 = ast.I32
  let i64 = ast.I64
  let f32 = ast.F32
  let f64 = ast.F64
  case instr {
    // i32 comparisons (yield i32)
    ast.I32Eqz -> #([i32], [i32])
    ast.I32Eq -> #([i32, i32], [i32])
    ast.I32Ne -> #([i32, i32], [i32])
    ast.I32LtS -> #([i32, i32], [i32])
    ast.I32LtU -> #([i32, i32], [i32])
    ast.I32GtS -> #([i32, i32], [i32])
    ast.I32GtU -> #([i32, i32], [i32])
    ast.I32LeS -> #([i32, i32], [i32])
    ast.I32LeU -> #([i32, i32], [i32])
    ast.I32GeS -> #([i32, i32], [i32])
    ast.I32GeU -> #([i32, i32], [i32])
    // i64 comparisons (yield i32)
    ast.I64Eqz -> #([i64], [i32])
    ast.I64Eq -> #([i64, i64], [i32])
    ast.I64Ne -> #([i64, i64], [i32])
    ast.I64LtS -> #([i64, i64], [i32])
    ast.I64LtU -> #([i64, i64], [i32])
    ast.I64GtS -> #([i64, i64], [i32])
    ast.I64GtU -> #([i64, i64], [i32])
    ast.I64LeS -> #([i64, i64], [i32])
    ast.I64LeU -> #([i64, i64], [i32])
    ast.I64GeS -> #([i64, i64], [i32])
    ast.I64GeU -> #([i64, i64], [i32])
    // i32 unary numeric
    ast.I32Clz -> #([i32], [i32])
    ast.I32Ctz -> #([i32], [i32])
    ast.I32Popcnt -> #([i32], [i32])
    // i32 binary numeric
    ast.I32Add -> #([i32, i32], [i32])
    ast.I32Sub -> #([i32, i32], [i32])
    ast.I32Mul -> #([i32, i32], [i32])
    ast.I32DivS -> #([i32, i32], [i32])
    ast.I32DivU -> #([i32, i32], [i32])
    ast.I32RemS -> #([i32, i32], [i32])
    ast.I32RemU -> #([i32, i32], [i32])
    ast.I32And -> #([i32, i32], [i32])
    ast.I32Or -> #([i32, i32], [i32])
    ast.I32Xor -> #([i32, i32], [i32])
    ast.I32Shl -> #([i32, i32], [i32])
    ast.I32ShrS -> #([i32, i32], [i32])
    ast.I32ShrU -> #([i32, i32], [i32])
    ast.I32Rotl -> #([i32, i32], [i32])
    ast.I32Rotr -> #([i32, i32], [i32])
    // i64 unary numeric
    ast.I64Clz -> #([i64], [i64])
    ast.I64Ctz -> #([i64], [i64])
    ast.I64Popcnt -> #([i64], [i64])
    // i64 binary numeric
    ast.I64Add -> #([i64, i64], [i64])
    ast.I64Sub -> #([i64, i64], [i64])
    ast.I64Mul -> #([i64, i64], [i64])
    ast.I64DivS -> #([i64, i64], [i64])
    ast.I64DivU -> #([i64, i64], [i64])
    ast.I64RemS -> #([i64, i64], [i64])
    ast.I64RemU -> #([i64, i64], [i64])
    ast.I64And -> #([i64, i64], [i64])
    ast.I64Or -> #([i64, i64], [i64])
    ast.I64Xor -> #([i64, i64], [i64])
    ast.I64Shl -> #([i64, i64], [i64])
    ast.I64ShrS -> #([i64, i64], [i64])
    ast.I64ShrU -> #([i64, i64], [i64])
    ast.I64Rotl -> #([i64, i64], [i64])
    ast.I64Rotr -> #([i64, i64], [i64])
    // sign extension (same width)
    ast.I32Extend8S -> #([i32], [i32])
    ast.I32Extend16S -> #([i32], [i32])
    ast.I64Extend8S -> #([i64], [i64])
    ast.I64Extend16S -> #([i64], [i64])
    ast.I64Extend32S -> #([i64], [i64])
    // saturating float→int truncation (0xFC 0..7)
    ast.I32TruncSatF32S -> #([f32], [i32])
    ast.I32TruncSatF32U -> #([f32], [i32])
    ast.I32TruncSatF64S -> #([f64], [i32])
    ast.I32TruncSatF64U -> #([f64], [i32])
    ast.I64TruncSatF32S -> #([f32], [i64])
    ast.I64TruncSatF32U -> #([f32], [i64])
    ast.I64TruncSatF64S -> #([f64], [i64])
    ast.I64TruncSatF64U -> #([f64], [i64])
    // f32 comparisons (yield i32)
    ast.F32Eq -> #([f32, f32], [i32])
    ast.F32Ne -> #([f32, f32], [i32])
    ast.F32Lt -> #([f32, f32], [i32])
    ast.F32Gt -> #([f32, f32], [i32])
    ast.F32Le -> #([f32, f32], [i32])
    ast.F32Ge -> #([f32, f32], [i32])
    // f64 comparisons (yield i32)
    ast.F64Eq -> #([f64, f64], [i32])
    ast.F64Ne -> #([f64, f64], [i32])
    ast.F64Lt -> #([f64, f64], [i32])
    ast.F64Gt -> #([f64, f64], [i32])
    ast.F64Le -> #([f64, f64], [i32])
    ast.F64Ge -> #([f64, f64], [i32])
    // f32 unary (width-preserving)
    ast.F32Abs -> #([f32], [f32])
    ast.F32Neg -> #([f32], [f32])
    ast.F32Ceil -> #([f32], [f32])
    ast.F32Floor -> #([f32], [f32])
    ast.F32Trunc -> #([f32], [f32])
    ast.F32Nearest -> #([f32], [f32])
    ast.F32Sqrt -> #([f32], [f32])
    // f32 binary (width-preserving, incl. copysign)
    ast.F32Add -> #([f32, f32], [f32])
    ast.F32Sub -> #([f32, f32], [f32])
    ast.F32Mul -> #([f32, f32], [f32])
    ast.F32Div -> #([f32, f32], [f32])
    ast.F32Min -> #([f32, f32], [f32])
    ast.F32Max -> #([f32, f32], [f32])
    ast.F32Copysign -> #([f32, f32], [f32])
    // f64 unary (width-preserving)
    ast.F64Abs -> #([f64], [f64])
    ast.F64Neg -> #([f64], [f64])
    ast.F64Ceil -> #([f64], [f64])
    ast.F64Floor -> #([f64], [f64])
    ast.F64Trunc -> #([f64], [f64])
    ast.F64Nearest -> #([f64], [f64])
    ast.F64Sqrt -> #([f64], [f64])
    // f64 binary (width-preserving, incl. copysign)
    ast.F64Add -> #([f64, f64], [f64])
    ast.F64Sub -> #([f64, f64], [f64])
    ast.F64Mul -> #([f64, f64], [f64])
    ast.F64Div -> #([f64, f64], [f64])
    ast.F64Min -> #([f64, f64], [f64])
    ast.F64Max -> #([f64, f64], [f64])
    ast.F64Copysign -> #([f64, f64], [f64])
    // int↔float conversion block (0xA7..0xBF) — width-only
    ast.I32WrapI64 -> #([i64], [i32])
    ast.I32TruncF32S -> #([f32], [i32])
    ast.I32TruncF32U -> #([f32], [i32])
    ast.I32TruncF64S -> #([f64], [i32])
    ast.I32TruncF64U -> #([f64], [i32])
    ast.I64ExtendI32S -> #([i32], [i64])
    ast.I64ExtendI32U -> #([i32], [i64])
    ast.I64TruncF32S -> #([f32], [i64])
    ast.I64TruncF32U -> #([f32], [i64])
    ast.I64TruncF64S -> #([f64], [i64])
    ast.I64TruncF64U -> #([f64], [i64])
    ast.F32ConvertI32S -> #([i32], [f32])
    ast.F32ConvertI32U -> #([i32], [f32])
    ast.F32ConvertI64S -> #([i64], [f32])
    ast.F32ConvertI64U -> #([i64], [f32])
    ast.F32DemoteF64 -> #([f64], [f32])
    ast.F64ConvertI32S -> #([i32], [f64])
    ast.F64ConvertI32U -> #([i32], [f64])
    ast.F64ConvertI64S -> #([i64], [f64])
    ast.F64ConvertI64U -> #([i64], [f64])
    ast.F64PromoteF32 -> #([f32], [f64])
    ast.I32ReinterpretF32 -> #([f32], [i32])
    ast.I64ReinterpretF64 -> #([f64], [i64])
    ast.F32ReinterpretI32 -> #([i32], [f32])
    ast.F64ReinterpretI64 -> #([i64], [f64])
    // Non-numeric instructions are handled by `validate_instr`; treat any other as
    // a no-op signature so this function stays total (unreachable in practice — every
    // numeric/conversion/float leaf has an explicit arm above).
    _ -> #([], [])
  }
}
