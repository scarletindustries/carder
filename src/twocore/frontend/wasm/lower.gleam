//// Unit 10b — lower a validated WASM module into the shared IR.
////
//// `lower/1` consumes a `validate.TypedModule` (10a) and produces an `ir.Module`. It
//// performs the two classic WASM-frontend jobs together (they share one SSA naming
//// context, so they live in one file):
////
//// 1. **Stack elimination / SSA.** The operand stack's shape is statically known from
////    validation, so every pushed value becomes a named binding (or an immediate
////    constant) and every pop becomes a value reference — there is **no runtime
////    stack**. Numeric ops become `ir.Num`/`ir.Convert`; consts become `ConstI32`/…
//// 2. **Structure → IR with NAMED labels (D6).** WASM branches by **numeric label
////    depth**; this stage resolves each relative depth into the IR's named-label
////    constructs at the frontend boundary — a depth NEVER reaches the IR. A `br` to a
////    `loop` becomes `Continue`, to a `block`/`if` becomes `Break`, the function frame
////    becomes `Return`.
////
//// **Mutable locals → SSA.** WASM locals are mutable; the IR is functional. A local
//// assigned anywhere inside a control construct is threaded through that construct as a
//// loop-carried `LoopParam` (for `loop`) or as an extra block/`if` result value (for
//// `block`/`if`), so the value flowing out reflects whichever path ran. Declared locals
//// are zero-initialised by an explicit `Let` at function entry (emit_core ignores
//// `ir.Function.locals`, per units 05 & 08).
////
//// Phase 2 (unit 09) extends the walk with the remaining WASM 1.0 surface: linear-memory
//// load/store (the full width matrix), `memory.size`/`memory.grow`, `global.get`/`global.set`
//// (index → a stable IR global name `g<idx>`), `call_indirect` (the single MVP table → the
//// fixed name `t0`), `select` (lowered to the existing `If`, no new IR node), and the full
//// `0xA7–0xBF` int↔float conversion block (wrap/extend/reinterpret → the existing ConvOps,
//// trapping trunc → `TruncS/U`, convert → `ConvertS/U`, demote/promote). Float binary
//// **arithmetic** (`f32/f64 add/sub/mul/div/min/max` → `FAdd..FMax`) is lowered (emit_core +
//// `rt_num` already lower these end-to-end). The 14 float unary/copysign/comparison NumOps
//// (`FAbs..FGe`) are deferred — see the NOTE in `num_op/1` (emit_core's `num_op_name` still
//// `todo`s on them, so lowering them would crash the conformance runner rather than skip).
//// It also populates the module-level IR declarations (`memory`/`globals`/`tables`/
//// `elements`/`data_segments`/`start`) from the decoded sections, lowering their
//// constant-literal init/offset expressions. The mem/global/table nodes are effects (E6):
//// stores/sets/grows are sequenced into the continuation as zero-result `Let`s and are never
//// dropped, and they never enter the Phase-1 mutable-local → `LoopParam` machinery (they
//// mutate the per-instance cell, not a WASM local).
////
//// Phase 5 (unit P5-05) completes the standardized instruction surface (minus SIMD).
//// It adds the reference instructions (`ref.null`/`ref.func`/`ref.is_null` → the
//// `ConstNull` value / `RefFunc`/`RefIsNull` `Expr`s — R1c), the table instructions
//// (`table.get/set/size/grow/fill` + the `0xFC` `table.init/copy` + `elem.drop`), the
//// bulk-memory `0xFC` ops (`memory.init/copy/fill` + `data.drop`), typed `select`
//// (`select_t`, still → the existing `If` merge — no new node), the per-op memory index
//// (multi-memory), and the grown module shape: `Module.memories` (a list),
//// reference-typed tables, active/passive/declarative element segments with
//// ref-producing init items, active/passive data segments, and the non-function
//// `ImportGlobal`/`ImportTable`/`ImportMemory` + `ExportGlobal`/`ExportTable`/
//// `ExportMemory` variants (the index spaces are threaded `imports ++ defined`). Const
//// inits now accept `ref.func`/`ref.null`/`global.get` alongside the numeric literals.
//// A single 32-bit-memory, funcref-only-active, import-free module lowers to
//// byte-identical IR3 (H7): every new immediate defaults away (`mem: 0`, `FuncRef`,
//// `ElemActive`/`DataActive`).
////
//// Phase 6 (unit P6-05) closes the three deferred holes (I1–I5):
////
//// 1. **SIMD.** Every standardized `v128` lane instruction lowers into IR4 — `ast.Simd(op)`
////    relabels to `ir.Simd(<neutral op>, args)` (the parametric keystone `ir.SimdOp`; float
////    ops gain the `SF` prefix, the widen/narrow/extmul/pairwise families copy their
////    `from`/`half`/`signed` fields — S3), `ast.V128Const(bytes)` pushes a `ConstV128(bytes)`
////    value literal (like a numeric const — D5, splat/const are not trapping),
////    `ast.I8x16Shuffle` → the dedicated `SimdShuffle(lanes, a, b)` node, and the four
////    SIMD-memory instructions → the `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`
////    `Expr` nodes (memidx + BITS width (S2) + static offset + lane threaded), routed
////    downstream (06/07) through the bounds-checked `rt_mem` seam. The pure lane ops bind a
////    fresh name via `emit_value_op_t` (like `Num`); the two stores are zero-result effects.
////
//// 2. **memory64 (I4).** The 64-bit-memory rejection is GONE: a 64-bit memory decodes,
////    validates, and now **lowers**, carrying `Idx64` on `MemoryDecl`/`ImportMemory` (via
////    `to_ir_idxtype`). The i64 address operands flow through the memory nodes unchanged (no
////    width branch in any arm — the width is a per-memory `idx_type` fact emit_core derives
////    from the node's `mem` index, keeping a 32-bit memory byte-identical). The page cap is a
////    runtime trap boundary (a `Binding` field), never lower's concern.
////
//// 3. **Cross-module function imports (I5/S5).** A `call` of an imported function (funcidx
////    `< imported`) lowers to `ir.CallImport(slot, ty, args)` — the positional function-import
////    slot (= the funcidx, since function imports occupy the low funcidx range) + the import's
////    signature. emit_core dispatches it via the linker-built closure capability
////    (`link.call_import`), never an ambient `apply` of an attacker-named `module:atom` (D3a).
////    A same-module call stays `CallDirect`.
////
//// Still out of scope (returns a typed `LowerError`, never a panic): relaxed-SIMD (the
//// separate non-deterministic proposal) and the GC-proposal reference types
//// (`Error(Unsupported(_))`); and any const-expr that is not a single `t.const` / `v128.const`
//// / `ref.func` / `ref.null` / `global.get` (`Error(NonConstInitExpr)` — extended-const
//// arithmetic chains stay rejected).

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/canon as canon_mod
import twocore/frontend/wasm/validate.{type TypedModule}
import twocore/ir

// ─────────────────────────────── error type ───────────────────────────────

/// Every reason lowering fails (this stage's own type — D4). Lowering is **total**:
/// an out-of-scope construct returns `Error`, never a `panic`/`let assert`.
///
/// - `Unsupported(detail)`: a construct outside lowering scope (an imported `call`, or a
///   Phase-3 reference-type op). `detail` is a stable tag.
/// - `StackUnderflow`: the operand stack lacked an expected operand — only reachable
///   on a module that bypassed validation (fail-closed defence).
/// - `Malformed(detail)`: a structural inconsistency (e.g. an `else` with no `if`).
/// - `UnknownLocalIndex(i)`/`UnknownTypeIndex(i)`/`UnknownFuncIndex(i)`/`UnknownTagIndex(i)`:
///   an index out of range (validation should have caught it; kept so lowering is total).
///   `UnknownTagIndex` is the Phase-7 EH addition — a `throw x` / catch clause / `ExportTag`
///   whose (absolute) tagidx has no entry in the tag index space (imports ++ defined).
/// - `NonConstInitExpr(detail)`: a global init / element-item / element-or-data offset
///   constant expression outside the admissible const-expr grammar. Phase 5 accepts a
///   single `t.const` / `v128.const` / `ref.func` / `ref.null` / `global.get` (of an
///   immutable imported global); an extended-const arithmetic chain (a separate proposal) is
///   rejected here — validation already blocks it, this is fail-closed insurance. `detail` is
///   a stable tag.
///
/// Phase 6 (P6-05) REMOVED `Memory64Unsupported`: a 64-bit-indexed memory now lowers (I4), so
/// nothing produces that variant. The conformance harness's `memory64 runtime → Phase 6`
/// categorized skip is likewise retired (P6-10).
pub type LowerError {
  Unsupported(detail: String)
  StackUnderflow
  Malformed(detail: String)
  UnknownLocalIndex(index: Int)
  UnknownTypeIndex(index: Int)
  UnknownFuncIndex(index: Int)
  UnknownTagIndex(index: Int)
  NonConstInitExpr(detail: String)
}

// ─────────────────────────────── internal state ───────────────────────────────

/// Read-only per-module/function context threaded into the walk.
///
/// - `types`: the module's type section (for blocktype resolution).
/// - `func_types`: every function's signature indexed by funcidx.
/// - `imported`: the funcidx offset (imports occupy `0..imported-1`).
/// - `local_types`: the current function's expanded local types (`params ++ declared`),
///   as IR types, indexed from 0.
/// - `global_types`: the IR value type of each module global, indexed by globalidx
///   (mirrors `local_types`; from `TypedModule.global_types`). Drives the result type of
///   `global.get` for SSA value-type tracking and the global declarations.
/// - `table_types`: the element **reference type** of each table by absolute tableidx
///   (imports ++ defined; from `TypedModule.table_types`). Drives the result type of
///   `table.get` (a `table.get`'s result is the table's element reftype) — Phase 5.
/// - `tag_types` (Phase 7): the operand `ValType`s carried by each exception tag, indexed
///   by **absolute tagidx** (imports ++ defined; from `TypedModule.tag_types`, mapped to IR
///   types). A `throw x` / `try_table catch x` recovers the payload count/types from
///   `tag_types[x]` — the one EH typing fact lower cannot re-derive (a `throw x` names only
///   `x`), exactly as `global_types` serves `global.set`. Empty for a tag-free module.
/// - `catch_refs` (Phase 7): the `exnref` names of the LEXICALLY-ENCLOSING legacy catch
///   handlers, innermost at the head, used to lower a legacy `rethrow l` (which re-raises
///   the caught exception of an enclosing handler) to `ThrowRef(Var(<enclosing exnref>))`.
///   A handler that contains a `rethrow` captures an `exnref` name and pushes it here for
///   its body's walk; empty at function entry (a `rethrow` outside any handler is malformed,
///   rejected by validate — lower fails closed).
type LCtx {
  LCtx(
    types: List(ast.DefType),
    /// The iso-recursive canonical id of every type by index (`canon.canon_ids`),
    /// so the compile-time `ref.test`/`ref.cast` subtype set matches concrete types
    /// by structural identity, not declared index (mirrors the validator).
    canon: List(Int),
    func_types: List(ast.FuncType),
    imported: Int,
    local_types: List(ir.ValType),
    global_types: List(ir.ValType),
    table_types: List(ir.RefType),
    tag_types: List(List(ir.ValType)),
    catch_refs: List(String),
    /// (Lever 5) `True` iff frontend liveness narrowing is enabled FOR THIS FUNCTION — the build
    /// flag AND the function being analysable (no exception-handling / GC-typed-branch instruction,
    /// which the backward liveness pass does not model and so bails on). When `False`, every
    /// block/loop/if threads its FULL `scan_modified` carried set (byte-identical to a no-narrowing
    /// build).
    narrow_carried: Bool,
    /// (Lever 5) `{0..local_count-1}` — the conservative "all locals" set the backward liveness pass
    /// falls back to on any uncertainty (an out-of-range branch depth, a body that runs off its end),
    /// so an unknown live-set can never DROP a local. Empty when `narrow_carried` is `False`.
    all_locals: set.Set(Int),
    /// (Lever 5) The branch-target and fall-through live-local sets of each ENCLOSING control frame,
    /// innermost at the head, parallel to `LState.frames`. Entry `#(br_live, ft_live)`: `br_live` =
    /// the locals live where a `br` to that frame lands (a `block`/`if`'s merge, a `loop`'s head =
    /// its back-edge live set); `ft_live` = the locals live at that frame's fall-through exit. The
    /// backward liveness pass indexes `br_live` by branch depth and reads the head `ft_live` at a
    /// frame-closing `end`. Only meaningful (and only maintained in lockstep with `frames`) while
    /// `narrow_carried` is `True`; a stale value is never read otherwise.
    label_lives: List(#(set.Set(Int), set.Set(Int))),
  )
}

/// The kind of a lowering control frame — selects how a branch to it lowers and how
/// its label is typed.
type FrameKind {
  FBlock
  FLoop
  FIf
  FFunc
}

/// One lowering control frame. Unlike the validator's frame this carries the resolved
/// IR label and the SSA threading facts.
///
/// - `label`: the IR (named) label of this construct.
/// - `kind`: block / loop / if / function.
/// - `branch_arity`: stack values a `br` to this frame carries (a `loop` carries its
///   INPUT arity — the head; others carry their result arity).
/// - `out_arity`: stack values yielded on fall-through (the blocktype result arity).
/// - `result_types`: the construct's IR result types = blocktype results ++ carried
///   local types (the fall-through / exit yield).
/// - `carried`: the local indices threaded through this construct (ascending) — locals
///   assigned anywhere inside it.
type LFrame {
  LFrame(
    label: String,
    kind: FrameKind,
    branch_arity: Int,
    out_arity: Int,
    result_types: List(ir.ValType),
    carried: List(Int),
  )
}

/// The mutable-threaded lowering state.
///
/// - `stack`: the abstract operand stack of IR `Value`s (top at head) — names, never a
///   runtime stack.
/// - `locals`: each local's current SSA value (index → `Value`).
/// - `counter`: a monotonic gensym counter for fresh names/labels.
/// - `frames`: the control-frame stack, innermost (current) at head.
/// - `var_types`: every minted SSA name → its IR value type. Recorded whenever lower binds
///   a fresh name (params, declared locals, op results, loads, calls, loop params, construct
///   results). Used by `value_type` to recover a `select`'s operand type (the one result
///   type that is operand-determined, not opcode-determined). Keys are stable names that are
///   never reshuffled, so this is robust across the stack reshaping in the construct lowerers.
type LState {
  LState(
    stack: List(ir.Value),
    locals: Dict(Int, ir.Value),
    counter: Int,
    frames: List(LFrame),
    var_types: Dict(String, ir.ValType),
  )
}

/// The result of walking a straight-line instruction run within one frame: the lowered
/// expression, the instructions remaining after the frame's closing marker, and the
/// advanced gensym counter. `GEnd` closed on the frame's `end`; `GElse` closed on an
/// `else` (only inside an `if` then-branch).
type GoResult {
  GEnd(expr: ir.Expr, rest: List(ast.Instr), counter: Int)
  GElse(expr: ir.Expr, rest: List(ast.Instr), counter: Int)
}

// ─────────────────────────────── public entry point ───────────────────────────────

/// Lowers a validated module into the shared IR.
///
/// The operand stack (statically known from validation) becomes named SSA bindings and
/// structured control becomes the IR's named-label constructs (D6). Sets
/// `uses_numerics: True`. Each defined function `i` is named `"f<funcidx>"`; `ExportFunc`
/// exports become `ir.ExportFn` referencing those names. The module-level declarations are
/// populated from the decoded sections: `memory` from the single MVP memory; `globals` from
/// the global section (named `g<idx>`, with constant-literal inits); `tables` from the table
/// section (named `t<idx>`); `elements` from active element segments (each funcidx → the IR
/// name `f<funcidx>`); `data_segments` from active data segments; `start` from the start
/// section (→ `f<funcidx>`).
///
/// Returns `Ok(ir.Module)`, or `Error(LowerError)` — fail-closed, never a panic — for an
/// out-of-scope construct (`Unsupported`) or a non-constant-literal init/offset expression
/// (`NonConstInitExpr`).
///
/// Frontend liveness narrowing (lever 5) is OFF: every block/loop/if threads its full
/// `scan_modified` carried-local set, so the output is byte-identical to a no-narrowing build.
/// Use `lower_with(typed, True)` to enable narrowing.
pub fn lower(typed: TypedModule) -> Result(ir.Module, LowerError) {
  lower_with(typed, False)
}

/// As `lower/1`, but `narrow_carried` selects whether the frontend runs the SOUND liveness pass
/// (lever 5) that drops each block/loop/if carried local it can PROVE is dead at the construct's
/// exit (a loop additionally keeps any local live at its back-edge). `False` reproduces `lower/1`
/// exactly (byte-identical). `True` only ever REMOVES a provably-dead carried local — never a live
/// one — and bails to the full set for any function using exception handling or a GC-typed branch.
pub fn lower_with(
  typed: TypedModule,
  narrow_carried: Bool,
) -> Result(ir.Module, LowerError) {
  let module = typed.module
  use functions <- result.try(
    list.index_map(module.funcs, fn(f, i) {
      lower_func(f, i, typed, narrow_carried)
    })
    |> result.all,
  )
  // Exports of all four kinds. Functions → `f<funcidx>`; state exports carry the IR name
  // of the exported item (`t<tableidx>` / `g<globalidx>` / the raw memidx) — the same
  // absolute-index naming instruction lowering uses (H4/§G.5).
  use exports <- result.try(
    list.try_map(module.exports, fn(e) {
      case e.kind {
        ast.ExportFunc -> Ok(ir.ExportFn(e.name, "f" <> int.to_string(e.index)))
        ast.ExportTable -> Ok(ir.ExportTable(e.name, tname(e.index)))
        ast.ExportGlobal -> Ok(ir.ExportGlobal(e.name, gname(e.index)))
        ast.ExportMemory -> Ok(ir.ExportMemory(e.name, e.index))
        // A tag export («WASM-AST5», Phase 7). `e.index` is the ABSOLUTE tagidx (imports ++
        // defined); it names the same build-controlled exception class as `throw`/`catch`
        // (`tag<idx>`). Measured: Porffor emits `(export "0" (tag 0))`.
        ast.ExportTag -> Ok(ir.ExportTag(e.name, tagname(e.index)))
      }
    }),
  )
  use imports <- result.try(lower_imports(module))
  use globals <- result.try(lower_globals(
    module,
    typed.imported_global_count,
    typed.imported_func_count,
    typed.func_types,
  ))
  use elements <- result.try(lower_elements(
    module,
    typed.imported_func_count,
    typed.func_types,
  ))
  use data_segments <- result.try(lower_data(
    module,
    typed.imported_func_count,
    typed.func_types,
  ))
  use tags <- result.try(lower_tags(module, typed.imported_tag_count))
  Ok(ir.Module(
    name: "twocore@wasm@" <> module_base(module),
    uses_numerics: True,
    memories: lower_memory(module),
    globals: globals,
    imports: imports,
    functions: functions,
    exports: exports,
    data_segments: data_segments,
    tables: lower_tables(module, typed.imported_table_count),
    elements: elements,
    start: lower_start(module),
    // Phase-7 exception tags (J2/T2). The module's DEFINED tags → `TagDecl`s (imported tags
    // live in `imports` as `ImportTag`). A tag-free module lowers `[]`, byte-identical to
    // Phase-6.
    tags: tags,
  ))
}

/// A sanitised base for the IR module name, derived from the first function export
/// (or `"anon"`). Non-identifier characters are dropped so the emitted BEAM module
/// atom is well-formed.
fn module_base(module: ast.Module) -> String {
  case list.find(module.exports, fn(e) { e.kind == ast.ExportFunc }) {
    Ok(e) -> sanitize(e.name)
    Error(_) -> "anon"
  }
}

/// Keep only `[a-zA-Z0-9_]`; map everything else away. Falls back to `"anon"` if the
/// result is empty.
fn sanitize(name: String) -> String {
  let kept =
    name
    |> string_to_chars
    |> list.filter(is_ident_char)
    |> string_concat
  case kept {
    "" -> "anon"
    _ -> kept
  }
}

// ─────────────────────────────── per-function lowering ───────────────────────────────

/// Lower one defined function (its `defined_idx` within the code section). Names params
/// `p0..`, zero-initialises declared locals with explicit `Let`s at entry, and walks the
/// body under a function control frame whose result types are the function's results
/// (the `return` target).
fn lower_func(
  f: ast.Func,
  defined_idx: Int,
  typed: TypedModule,
  narrow_carried: Bool,
) -> Result(ir.Function, LowerError) {
  let module = typed.module
  let funcidx = typed.imported_func_count + defined_idx
  use sig <- result.try(func_type_err(
    module.types,
    f.type_idx,
    UnknownTypeIndex(f.type_idx),
  ))
  use local_ts_wasm <- result.try(nth_err(
    typed.func_locals,
    defined_idx,
    Malformed("missing function locals"),
  ))
  let local_types = list.map(local_ts_wasm, to_ir_vt)
  let param_count = list.length(sig.params)
  let result_types = list.map(sig.results, to_ir_vt)

  // params: named p0..p{k-1}
  let params =
    list.index_map(sig.params, fn(t, i) {
      ir.Local("p" <> int.to_string(i), to_ir_vt(t))
    })
  let param_pairs =
    list.index_map(sig.params, fn(_t, i) {
      #(i, ir.Var("p" <> int.to_string(i)))
    })

  // declared locals: fresh names, zero-initialised at entry
  let declared_types = list.drop(local_types, param_count)
  let #(decl_names, c1) = fresh_n(0, list.length(declared_types))
  let decl_pairs =
    list.index_map(decl_names, fn(name, j) { #(param_count + j, ir.Var(name)) })
  let env = dict.from_list(list.append(param_pairs, decl_pairs))
  let zero_inits = list.zip(decl_names, declared_types)

  // Seed the SSA type map with the params (`p0..`) and the zero-initialised declared
  // locals so a `select` reading a param/local recovers the right operand type.
  let param_type_pairs =
    list.index_map(sig.params, fn(t, i) {
      #("p" <> int.to_string(i), to_ir_vt(t))
    })
  let init_var_types =
    dict.from_list(list.append(
      param_type_pairs,
      list.zip(decl_names, declared_types),
    ))

  let #(flabel, c2) = fresh_label(c1)
  let func_frame =
    LFrame(
      label: flabel,
      kind: FFunc,
      branch_arity: list.length(result_types),
      out_arity: list.length(result_types),
      result_types: result_types,
      carried: [],
    )
  let ctx =
    LCtx(
      types: module.types,
      canon: canon_mod.canon_ids(module.types, module.rec_groups),
      func_types: typed.func_types,
      imported: typed.imported_func_count,
      local_types: local_types,
      global_types: list.map(typed.global_types, to_ir_vt),
      table_types: list.map(typed.table_types, to_ir_reftype),
      // Phase-7 EH: the operand types of every tag (imports ++ defined), mapped to IR
      // types (`exnref` → `TExnRef`), so `throw`/`catch` recover their payload arity. No
      // legacy catch handler is active at function entry, so `catch_refs` starts empty.
      tag_types: list.map(typed.tag_types, fn(ts) { list.map(ts, to_ir_vt) }),
      catch_refs: [],
      // Lever 5: narrow this function's carried sets by liveness only if the build asked for it AND
      // the body is analysable (no EH / GC-typed branch the pass would have to model). Otherwise the
      // pass never runs and the full over-approximated carried set is threaded (byte-identical).
      narrow_carried: narrow_carried && is_narrowable(f.body),
      all_locals: case narrow_carried {
        True -> set_range(list.length(local_types))
        False -> set.new()
      },
      // The function frame's branch/fall-through live sets: a `return` and a fall-through off the
      // body end both exit the function, where NO local is live (results are stack values). One
      // entry, parallel to `st0.frames = [func_frame]`.
      label_lives: [#(set.new(), set.new())],
    )
  let st0 =
    LState(
      stack: [],
      locals: env,
      counter: c2,
      frames: [func_frame],
      var_types: init_var_types,
    )
  use body_res <- result.try(go(f.body, ctx, st0))
  use #(body_core, _rest, _c) <- result.try(expect_end(body_res))
  let body = wrap_zero_inits(zero_inits, body_core)
  Ok(ir.Function(
    name: "f" <> int.to_string(funcidx),
    params: params,
    result: result_types,
    locals: [],
    body: body,
  ))
}

/// Wrap `body` in one zero-initialising `Let` per declared local (first declared local
/// outermost). Each local is bound to its type's zero value before the body runs.
fn wrap_zero_inits(
  zero_inits: List(#(String, ir.ValType)),
  body: ir.Expr,
) -> ir.Expr {
  list.fold(list.reverse(zero_inits), body, fn(acc, pair) {
    let #(name, ty) = pair
    ir.Let([name], ir.Values([zero_value(ty)]), acc)
  })
}

// ─────────────────────────────── the instruction walk ───────────────────────────────

/// Lower a straight-line instruction run within the current frame (head of
/// `st.frames`), threading SSA state. Returns a `GoResult` once the frame's closing
/// `end`/`else` is reached. Value-producing instructions wrap a `Let` around the
/// recursively-lowered continuation; structured instructions recurse into sub-bodies;
/// control transfers resolve label depths into named-label IR and skip the dead tail.
fn go(
  instrs: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  case instrs {
    [] -> Error(Malformed("ran off end of body without a closing end"))
    [instr, ..tail] ->
      case instr {
        ast.Nop -> go(tail, ctx, st)

        // closing markers: yield the current frame's fall-through result ------------
        ast.End -> {
          use cur <- result.try(current_frame(st))
          use ft <- result.try(fallthrough(cur, st))
          Ok(GEnd(ft, tail, st.counter))
        }
        ast.Else -> {
          use cur <- result.try(current_frame(st))
          use ft <- result.try(fallthrough(cur, st))
          Ok(GElse(ft, tail, st.counter))
        }

        // constants -----------------------------------------------------------------
        ast.I32Const(v) ->
          go(tail, ctx, push(st, ir.ConstI32(unsigned_bits(v, 32))))
        ast.I64Const(v) ->
          go(tail, ctx, push(st, ir.ConstI64(unsigned_bits(v, 64))))
        ast.F32Const(bits) -> go(tail, ctx, push(st, ir.ConstF32(bits)))
        ast.F64Const(bits) -> go(tail, ctx, push(st, ir.ConstF64(bits)))

        // locals --------------------------------------------------------------------
        ast.LocalGet(i) -> {
          use v <- result.try(get_local(st, i))
          go(tail, ctx, push(st, v))
        }
        ast.LocalSet(i) -> {
          use #(v, rest_stack) <- result.try(pop1(st.stack))
          go(
            tail,
            ctx,
            LState(
              ..st,
              stack: rest_stack,
              locals: dict.insert(st.locals, i, v),
            ),
          )
        }
        ast.LocalTee(i) -> {
          use #(v, _) <- result.try(pop1(st.stack))
          go(tail, ctx, LState(..st, locals: dict.insert(st.locals, i, v)))
        }

        ast.Drop -> {
          use #(_, rest_stack) <- result.try(pop1(st.stack))
          go(tail, ctx, LState(..st, stack: rest_stack))
        }

        // calls ---------------------------------------------------------------------
        ast.Call(f) -> lower_call(f, tail, ctx, st)

        // tail calls (Phase 13, Q4) — REAL bottom-transfer lowering to `ir.ReturnCall` /
        // `ir.ReturnCallImport`. See `lower_return_call`.
        ast.ReturnCall(f) -> lower_return_call(f, tail, ctx, st)

        // structured control --------------------------------------------------------
        ast.Block(bt) -> lower_block(bt, tail, ctx, st)
        ast.Loop(bt) -> lower_loop(bt, tail, ctx, st)
        ast.If(bt) -> lower_if(bt, tail, ctx, st)

        // exception handling — try regions (Phase 7, T1/T2). BOTH wire encodings structure
        // into the ONE inline-handler `ir.Try`: the LEGACY flat-stream `try…catch…end`
        // (Porffor) via `lower_try_legacy`, the MODERN `try_table` via `lower_try_table`.
        ast.TryLegacy(bt) -> lower_try_legacy(bt, tail, ctx, st)
        ast.TryTable(bt, catches) -> lower_try_table(bt, catches, tail, ctx, st)

        // branches ------------------------------------------------------------------
        ast.Br(l) -> {
          use transfer <- result.try(build_transfer(l, st))
          use #(marker, rest) <- result.try(consume_dead(tail, 0))
          Ok(end_or_else(marker, transfer, rest, st.counter))
        }
        ast.BrIf(l) -> lower_br_if(l, tail, ctx, st)
        ast.BrTable(targets, default) ->
          lower_br_table(targets, default, tail, st)
        ast.Return -> {
          use func_frame <- result.try(case list.last(st.frames) {
            Ok(fr) -> Ok(fr)
            Error(_) -> Error(Malformed("no function frame for return"))
          })
          let vals = take_push_order(st.stack, func_frame.out_arity)
          use #(marker, rest) <- result.try(consume_dead(tail, 0))
          Ok(end_or_else(marker, ir.Return(vals), rest, st.counter))
        }
        ast.Unreachable -> {
          use #(marker, rest) <- result.try(consume_dead(tail, 0))
          Ok(end_or_else(marker, ir.Trap(ir.Unreachable), rest, st.counter))
        }

        // exception raises — all BOTTOM transfers (like `Return`/`Unreachable`): build the
        // node, then consume the unreachable tail to the frame's closing marker (Phase 7).
        ast.Throw(x) -> lower_throw(x, tail, ctx, st)
        ast.ThrowRef -> lower_throw_ref(tail, st)
        ast.Rethrow(l) -> lower_rethrow(l, tail, ctx, st)

        // Legacy in-stream handler markers are consumed structurally by `lower_try_legacy`
        // (which splits the flat try/catch stream at them); `go` never reaches one in a
        // well-formed module. Fail closed rather than mis-lower.
        ast.LegacyCatch(_) | ast.LegacyCatchAll | ast.LegacyDelegate(_) ->
          Error(Malformed("legacy EH handler marker outside a try region"))

        // linear-memory loads (pop addr, push the load's result-typed value) --------
        // `MemAccess(bytes, signed)`: bytes = access width, signed = sub-word sign-extend.
        // `result` is set from the opcode suffix (it, not `MemAccess`, disambiguates e.g.
        // `i32.load8_s` from `i64.load8_s`). `m.align` is dropped (validate checked it).
        ast.I32Load(m) ->
          emit_load(
            m.mem,
            ir.MemAccess(4, False),
            ir.TI32,
            m.offset,
            tail,
            ctx,
            st,
          )
        ast.I64Load(m) ->
          emit_load(
            m.mem,
            ir.MemAccess(8, False),
            ir.TI64,
            m.offset,
            tail,
            ctx,
            st,
          )
        ast.F32Load(m) ->
          emit_load(
            m.mem,
            ir.MemAccess(4, False),
            ir.TF32,
            m.offset,
            tail,
            ctx,
            st,
          )
        ast.F64Load(m) ->
          emit_load(
            m.mem,
            ir.MemAccess(8, False),
            ir.TF64,
            m.offset,
            tail,
            ctx,
            st,
          )
        ast.I32Load8S(m) ->
          emit_load(
            m.mem,
            ir.MemAccess(1, True),
            ir.TI32,
            m.offset,
            tail,
            ctx,
            st,
          )
        ast.I32Load8U(m) ->
          emit_load(
            m.mem,
            ir.MemAccess(1, False),
            ir.TI32,
            m.offset,
            tail,
            ctx,
            st,
          )
        ast.I32Load16S(m) ->
          emit_load(
            m.mem,
            ir.MemAccess(2, True),
            ir.TI32,
            m.offset,
            tail,
            ctx,
            st,
          )
        ast.I32Load16U(m) ->
          emit_load(
            m.mem,
            ir.MemAccess(2, False),
            ir.TI32,
            m.offset,
            tail,
            ctx,
            st,
          )
        ast.I64Load8S(m) ->
          emit_load(
            m.mem,
            ir.MemAccess(1, True),
            ir.TI64,
            m.offset,
            tail,
            ctx,
            st,
          )
        ast.I64Load8U(m) ->
          emit_load(
            m.mem,
            ir.MemAccess(1, False),
            ir.TI64,
            m.offset,
            tail,
            ctx,
            st,
          )
        ast.I64Load16S(m) ->
          emit_load(
            m.mem,
            ir.MemAccess(2, True),
            ir.TI64,
            m.offset,
            tail,
            ctx,
            st,
          )
        ast.I64Load16U(m) ->
          emit_load(
            m.mem,
            ir.MemAccess(2, False),
            ir.TI64,
            m.offset,
            tail,
            ctx,
            st,
          )
        ast.I64Load32S(m) ->
          emit_load(
            m.mem,
            ir.MemAccess(4, True),
            ir.TI64,
            m.offset,
            tail,
            ctx,
            st,
          )
        ast.I64Load32U(m) ->
          emit_load(
            m.mem,
            ir.MemAccess(4, False),
            ir.TI64,
            m.offset,
            tail,
            ctx,
            st,
          )

        // linear-memory stores (pop [addr, value]; zero-result effect) ---------------
        // A store writes the low `bytes` bytes; `signed` is irrelevant → always `False`.
        ast.I32Store(m) ->
          emit_store(m.mem, ir.MemAccess(4, False), m.offset, tail, ctx, st)
        ast.I64Store(m) ->
          emit_store(m.mem, ir.MemAccess(8, False), m.offset, tail, ctx, st)
        ast.F32Store(m) ->
          emit_store(m.mem, ir.MemAccess(4, False), m.offset, tail, ctx, st)
        ast.F64Store(m) ->
          emit_store(m.mem, ir.MemAccess(8, False), m.offset, tail, ctx, st)
        ast.I32Store8(m) ->
          emit_store(m.mem, ir.MemAccess(1, False), m.offset, tail, ctx, st)
        ast.I32Store16(m) ->
          emit_store(m.mem, ir.MemAccess(2, False), m.offset, tail, ctx, st)
        ast.I64Store8(m) ->
          emit_store(m.mem, ir.MemAccess(1, False), m.offset, tail, ctx, st)
        ast.I64Store16(m) ->
          emit_store(m.mem, ir.MemAccess(2, False), m.offset, tail, ctx, st)
        ast.I64Store32(m) ->
          emit_store(m.mem, ir.MemAccess(4, False), m.offset, tail, ctx, st)

        // memory size/grow ----------------------------------------------------------
        // The `mem` immediate is the memory index (default `0`; a single-memory module
        // keeps `MemSize(0)`/`MemGrow(0, _)`, byte-identical to Phase-4).
        ast.MemorySize(m) -> emit_nullary(ir.MemSize(m), ir.TI32, tail, ctx, st)
        ast.MemoryGrow(m) ->
          emit_value_op_t(
            1,
            ir.TI32,
            fn(a) { ir.MemGrow(m, one(a)) },
            tail,
            ctx,
            st,
          )

        // globals (index → stable `g<idx>` name) ------------------------------------
        ast.GlobalGet(i) ->
          emit_nullary(ir.GlobalGet(gname(i)), global_ty(ctx, i), tail, ctx, st)
        ast.GlobalSet(i) ->
          emit_effect(
            1,
            fn(a) { ir.GlobalSet(gname(i), one(a)) },
            tail,
            ctx,
            st,
          )

        // indirect call + select ----------------------------------------------------
        ast.CallIndirect(ty, table) ->
          lower_call_indirect(ty, table, tail, ctx, st)
        // tail call indirect (Phase 13, Q4) — REAL bottom-transfer lowering to the
        // `ir.ReturnCallIndirect` bottom node. See `lower_return_call_indirect`.
        ast.ReturnCallIndirect(ty, table) ->
          lower_return_call_indirect(ty, table, tail, ctx, st)
        ast.Select -> lower_select(tail, ctx, st)
        ast.SelectT(types) -> lower_select_t(types, tail, ctx, st)

        // reference instructions (0xD0..0xD2) — spec exec/instructions §reference ----
        // `ref.null t` is a value literal — it reduces to a `ConstNull(t)` VALUE (R1c),
        // pushed like a numeric const (no `Let`, no separate `Expr`). `ref.func`/
        // `ref.is_null` produce value-producing `Expr`s bound to fresh names.
        ast.RefNull(rt) ->
          go(tail, ctx, push(st, ir.ConstNull(to_ir_reftype(rt))))
        ast.RefFunc(f) -> {
          use ref_expr <- result.try(lower_ref_func(
            f,
            ctx.imported,
            ctx.func_types,
          ))
          emit_nullary(ref_expr, ir.TFuncRef, tail, ctx, st)
        }
        ast.RefIsNull ->
          emit_value_op_t(
            1,
            ir.TI32,
            fn(a) { ir.RefIsNull(one(a)) },
            tail,
            ctx,
            st,
          )

        // table instructions (0x25/0x26 + 0xFC 12..17) — spec exec/instructions §table
        ast.TableGet(x) ->
          emit_value_op_t(
            1,
            ir.reftype_to_valtype(table_reftype(ctx, x)),
            fn(a) { ir.TableGet(tname(x), one(a)) },
            tail,
            ctx,
            st,
          )
        ast.TableSet(x) ->
          emit_effect(
            2,
            fn(a) {
              case a {
                [i, v] -> ir.TableSet(tname(x), i, v)
                _ -> ir.TableSet(tname(x), ir.ConstI32(0), ir.ConstI32(0))
              }
            },
            tail,
            ctx,
            st,
          )
        ast.TableSize(x) ->
          emit_nullary(ir.TableSize(tname(x)), ir.TI32, tail, ctx, st)
        ast.TableGrow(x) ->
          // stack `[t i32] → [i32]`: operands push-order `[init, n]` (init deeper, delta on
          // top). `TableGrow(table, delta, init)` returns the previous size (a value).
          emit_value_op_t(
            2,
            ir.TI32,
            fn(a) {
              case a {
                [init, n] -> ir.TableGrow(tname(x), n, init)
                _ ->
                  ir.TableGrow(
                    tname(x),
                    ir.ConstI32(0),
                    ir.ConstNull(ir.FuncRef),
                  )
              }
            },
            tail,
            ctx,
            st,
          )
        ast.TableFill(x) ->
          emit_effect(
            3,
            fn(a) {
              case a {
                [i, v, n] -> ir.TableFill(tname(x), i, v, n)
                _ -> ir.TableFill(tname(x), z(), zref(), z())
              }
            },
            tail,
            ctx,
            st,
          )
        // `table.init x y`: AST field order is wire order `TableInit(elem, table)` (R3);
        // the IR is `TableInit(table, seg, dst, src, count)`, so map `table → tname(x)`,
        // `elem → seg`.
        ast.TableInit(elem, table) ->
          emit_effect(
            3,
            fn(a) {
              case a {
                [d, s, n] -> ir.TableInit(tname(table), elem, d, s, n)
                _ -> ir.TableInit(tname(table), elem, z(), z(), z())
              }
            },
            tail,
            ctx,
            st,
          )
        ast.TableCopy(dst, src) ->
          emit_effect(
            3,
            fn(a) {
              case a {
                [d, s, n] -> ir.TableCopy(tname(dst), tname(src), d, s, n)
                _ -> ir.TableCopy(tname(dst), tname(src), z(), z(), z())
              }
            },
            tail,
            ctx,
            st,
          )
        ast.ElemDrop(elem) ->
          emit_effect(0, fn(_) { ir.ElemDrop(elem) }, tail, ctx, st)

        // bulk-memory (0xFC 8..11) — spec exec/instructions §memory (finalized 2.0) ---
        // Every op carries the memory index (default `0`). `memory.init x` field order is
        // wire order `MemoryInit(data, mem)` (R3) → `MemInit(mem, seg=data, dst, src, n)`.
        ast.MemoryFill(m) ->
          emit_effect(
            3,
            fn(a) {
              case a {
                [d, v, n] -> ir.MemFill(m, d, v, n)
                _ -> ir.MemFill(m, z(), z(), z())
              }
            },
            tail,
            ctx,
            st,
          )
        ast.MemoryCopy(dst_mem, src_mem) ->
          emit_effect(
            3,
            fn(a) {
              case a {
                [d, s, n] -> ir.MemCopy(dst_mem, src_mem, d, s, n)
                _ -> ir.MemCopy(dst_mem, src_mem, z(), z(), z())
              }
            },
            tail,
            ctx,
            st,
          )
        ast.MemoryInit(data, m) ->
          emit_effect(
            3,
            fn(a) {
              case a {
                [d, s, n] -> ir.MemInit(m, data, d, s, n)
                _ -> ir.MemInit(m, data, z(), z(), z())
              }
            },
            tail,
            ctx,
            st,
          )
        ast.DataDrop(data) ->
          emit_effect(0, fn(_) { ir.DataDrop(data) }, tail, ctx, st)

        // ── Phase-6 SIMD (0xFD family; I1/I2) — spec exec/instructions §vector ──
        // `v128.const` is a value literal (like a numeric const, D5): push `ConstV128(bytes)`
        // — no `Let`, no `Expr` (splat/const are not trapping). The 16 raw little-endian bytes
        // flow verbatim from decode (P6-03).
        ast.V128Const(bytes) -> go(tail, ctx, push(st, ir.ConstV128(bytes)))
        // Every pure lane-wise op relabels to the neutral `ir.SimdOp` and routes through the
        // shared `emit_value_op_t` path (its arity + result type derived from the op — §C/§D/§E).
        ast.Simd(op) -> lower_simd(op, tail, ctx, st)
        // `i8x16.shuffle` — a dedicated node carrying its 16 static lane indices (verbatim from
        // decode; validate range-checked them 0..31). Stack `[v128 v128] → [v128]`, operands
        // `[a, b]` (a deeper, b on top) select bytes from `a ++ b`.
        ast.I8x16Shuffle(lanes) ->
          emit_value_op_t(
            2,
            ir.TV128,
            fn(args) {
              case args {
                [a, b] -> ir.SimdShuffle(lanes, a, b)
                _ -> ir.SimdShuffle(lanes, zv128(), zv128())
              }
            },
            tail,
            ctx,
            st,
          )
        // SIMD memory (§F) — the four dedicated `rt_mem`-routed nodes. Loads produce a v128
        // (bound via `emit_value_op_t`); stores are zero-result effects (`emit_effect`, never
        // dropped — I6). Each carries the memidx (`arg.mem`, default 0 → byte-identical), the
        // static `arg.offset`, and (lane ops) the BITS width (S2) + lane immediate. The address
        // operand is whatever the SSA stack holds — an i32 for a 32-bit memory, an i64 for a
        // 64-bit memory (validate typed it), forwarded unchanged (no width branch — §G).
        ast.SimdLoad(kind, arg) ->
          emit_value_op_t(
            1,
            ir.TV128,
            fn(args) {
              case args {
                [addr] ->
                  ir.SimdLoad(
                    arg.mem,
                    relabel_load_kind(kind),
                    addr,
                    arg.offset,
                  )
                _ ->
                  ir.SimdLoad(arg.mem, relabel_load_kind(kind), z(), arg.offset)
              }
            },
            tail,
            ctx,
            st,
          )
        ast.SimdStore(arg) ->
          emit_effect(
            2,
            fn(args) {
              case args {
                [addr, value] -> ir.SimdStore(arg.mem, addr, value, arg.offset)
                _ -> ir.SimdStore(arg.mem, z(), zv128(), arg.offset)
              }
            },
            tail,
            ctx,
            st,
          )
        ast.SimdLoadLane(width, arg, lane) ->
          emit_value_op_t(
            2,
            ir.TV128,
            fn(args) {
              case args {
                [addr, vec] ->
                  ir.SimdLoadLane(arg.mem, width, addr, arg.offset, lane, vec)
                _ ->
                  ir.SimdLoadLane(
                    arg.mem,
                    width,
                    z(),
                    arg.offset,
                    lane,
                    zv128(),
                  )
              }
            },
            tail,
            ctx,
            st,
          )
        ast.SimdStoreLane(width, arg, lane) ->
          emit_effect(
            2,
            fn(args) {
              case args {
                [addr, vec] ->
                  ir.SimdStoreLane(arg.mem, width, addr, arg.offset, lane, vec)
                _ ->
                  ir.SimdStoreLane(
                    arg.mem,
                    width,
                    z(),
                    arg.offset,
                    lane,
                    zv128(),
                  )
              }
            },
            tail,
            ctx,
            st,
          )

        // ═══════════════════════ WasmGC (this proposal) ═══════════════════════
        // Each GC value/effect op lowers to a single `ir.Gc(op, args)` node routed
        // through the shared value/effect emitters. Operands are deepest-first,
        // matching `ir.Gc`'s convention.
        //
        // The full GC + typed-function-references instruction surface is lowered.
        ast.StructNew(t) -> {
          use fields <- result.try(gc_struct_fields(ctx, t))
          emit_value_op_t(
            list.length(fields),
            gc_ref_ty(),
            fn(a) { ir.Gc(ir.GcStructNew(t), a) },
            tail,
            ctx,
            st,
          )
        }
        ast.StructNewDefault(t) -> {
          use fields <- result.try(gc_struct_fields(ctx, t))
          let defaults =
            list.map(fields, fn(fd) { default_storage_value(fd.storage) })
          emit_value_op_t(
            0,
            gc_ref_ty(),
            fn(_) { ir.Gc(ir.GcStructNew(t), defaults) },
            tail,
            ctx,
            st,
          )
        }
        ast.StructGet(t, f) ->
          lower_struct_get(t, f, option.None, tail, ctx, st)
        ast.StructGetS(t, f) ->
          lower_struct_get(t, f, option.Some(True), tail, ctx, st)
        ast.StructGetU(t, f) ->
          lower_struct_get(t, f, option.Some(False), tail, ctx, st)
        ast.StructSet(_, f) ->
          emit_effect(2, fn(a) { ir.Gc(ir.GcStructSet(f), a) }, tail, ctx, st)
        ast.ArrayNew(t) ->
          emit_value_op_t(
            2,
            gc_ref_ty(),
            fn(a) { ir.Gc(ir.GcArrayNew(t), a) },
            tail,
            ctx,
            st,
          )
        ast.ArrayNewDefault(t) -> {
          use fd <- result.try(gc_array_field(ctx, t))
          let d = default_storage_value(fd.storage)
          emit_value_op_t(
            1,
            gc_ref_ty(),
            fn(a) { ir.Gc(ir.GcArrayNew(t), [d, ..a]) },
            tail,
            ctx,
            st,
          )
        }
        ast.ArrayNewFixed(t, n) ->
          emit_value_op_t(
            n,
            gc_ref_ty(),
            fn(a) { ir.Gc(ir.GcArrayNewFixed(t), a) },
            tail,
            ctx,
            st,
          )
        ast.ArrayGet(t) -> lower_array_get(t, option.None, tail, ctx, st)
        ast.ArrayGetS(t) -> lower_array_get(t, option.Some(True), tail, ctx, st)
        ast.ArrayGetU(t) ->
          lower_array_get(t, option.Some(False), tail, ctx, st)
        ast.ArraySet(_) ->
          emit_effect(3, fn(a) { ir.Gc(ir.GcArraySet, a) }, tail, ctx, st)
        ast.ArrayLen ->
          emit_value_op_t(
            1,
            ir.TI32,
            fn(a) { ir.Gc(ir.GcArrayLen, a) },
            tail,
            ctx,
            st,
          )
        ast.ArrayFill(_) ->
          emit_effect(4, fn(a) { ir.Gc(ir.GcArrayFill, a) }, tail, ctx, st)
        ast.ArrayCopy(_, _) ->
          emit_effect(5, fn(a) { ir.Gc(ir.GcArrayCopy, a) }, tail, ctx, st)
        // Segment-sourced array ops: the element byte width (data) drives the
        // uniform little-endian decode; emit resolves the drop-gated segment
        // payload. args are `[offset, count]` (new_*) / `[ref, dst, src, count]`.
        ast.ArrayNewData(t, d) -> {
          use fd <- result.try(gc_array_field(ctx, t))
          let w = storage_byte_width(fd.storage)
          emit_value_op_t(
            2,
            gc_ref_ty(),
            fn(a) { ir.Gc(ir.GcArrayNewData(t, d, w), a) },
            tail,
            ctx,
            st,
          )
        }
        ast.ArrayInitData(t, d) -> {
          use fd <- result.try(gc_array_field(ctx, t))
          let w = storage_byte_width(fd.storage)
          emit_effect(
            4,
            fn(a) { ir.Gc(ir.GcArrayInitData(d, w), a) },
            tail,
            ctx,
            st,
          )
        }
        ast.ArrayNewElem(t, e) ->
          emit_value_op_t(
            2,
            gc_ref_ty(),
            fn(a) { ir.Gc(ir.GcArrayNewElem(t, e), a) },
            tail,
            ctx,
            st,
          )
        ast.ArrayInitElem(_, e) ->
          emit_effect(
            4,
            fn(a) { ir.Gc(ir.GcArrayInitElem(e), a) },
            tail,
            ctx,
            st,
          )
        ast.RefI31 ->
          emit_value_op_t(
            1,
            gc_ref_ty(),
            fn(a) { ir.Gc(ir.GcRefI31, a) },
            tail,
            ctx,
            st,
          )
        ast.I31GetS ->
          emit_value_op_t(
            1,
            ir.TI32,
            fn(a) { ir.Gc(ir.GcI31Get(True), a) },
            tail,
            ctx,
            st,
          )
        ast.I31GetU ->
          emit_value_op_t(
            1,
            ir.TI32,
            fn(a) { ir.Gc(ir.GcI31Get(False), a) },
            tail,
            ctx,
            st,
          )
        ast.RefTest(rt) -> {
          let #(m, null_ok) = gc_matcher(rt, ctx)
          emit_value_op_t(
            1,
            ir.TI32,
            fn(a) { ir.Gc(ir.GcRefTest(m, null_ok), a) },
            tail,
            ctx,
            st,
          )
        }
        ast.RefCast(rt) -> {
          let #(m, null_ok) = gc_matcher(rt, ctx)
          emit_value_op_t(
            1,
            gc_ref_ty(),
            fn(a) { ir.Gc(ir.GcRefCast(m, null_ok), a) },
            tail,
            ctx,
            st,
          )
        }
        ast.RefEq ->
          emit_value_op_t(
            2,
            ir.TI32,
            fn(a) { ir.Gc(ir.GcRefEq, a) },
            tail,
            ctx,
            st,
          )
        ast.RefAsNonNull ->
          emit_value_op_t(
            1,
            gc_ref_ty(),
            fn(a) { ir.Gc(ir.GcRefAsNonNull, a) },
            tail,
            ctx,
            st,
          )
        ast.AnyConvertExtern ->
          emit_value_op_t(
            1,
            gc_ref_ty(),
            fn(a) { ir.Gc(ir.GcAnyConvertExtern, a) },
            tail,
            ctx,
            st,
          )
        ast.ExternConvertAny ->
          emit_value_op_t(
            1,
            gc_ref_ty(),
            fn(a) { ir.Gc(ir.GcExternConvertAny, a) },
            tail,
            ctx,
            st,
          )
        // `ref.null ht` for a GC heap type: the reftype-agnostic null sentinel
        // (`{ref_null}`) — the same one funcref/externref null uses, so ref.eq/
        // test/cast treat all nulls uniformly.
        ast.RefNullHt(_) -> go(tail, ctx, push(st, ir.ConstNull(ir.FuncRef)))
        // Branch casts — a conditional `If` around the ref's nullness / cast test,
        // keeping or dropping the ref on each side per the spec stack types.
        ast.BrOnNull(l) -> lower_br_on_null(l, True, tail, ctx, st)
        ast.BrOnNonNull(l) -> lower_br_on_null(l, False, tail, ctx, st)
        ast.BrOnCast(l, _rt1, rt2) ->
          lower_br_on_cast(l, rt2, False, tail, ctx, st)
        ast.BrOnCastFail(l, _rt1, rt2) ->
          lower_br_on_cast(l, rt2, True, tail, ctx, st)
        ast.CallRef(type_idx) -> lower_call_ref(type_idx, tail, ctx, st)
        ast.ReturnCallRef(type_idx) ->
          lower_return_call_ref(type_idx, tail, ctx, st)

        // numeric / comparison / conversion / float leaves --------------------------
        _ -> lower_numeric(instr, tail, ctx, st)
      }
  }
}

/// Lower a numeric/comparison instruction (→ `ir.Num`) or a conversion/sign-extension/
/// saturating-truncation (→ `ir.Convert`): pop its operands, bind a fresh name to the
/// op, push the name, and lower the continuation. Anything else is out of scope.
fn lower_numeric(
  instr: ast.Instr,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  case num_op(instr) {
    Ok(#(arity, op)) ->
      emit_value_op_t(
        arity,
        numop_result_type(op),
        fn(args) { ir.Num(op, args) },
        tail,
        ctx,
        st,
      )
    Error(_) ->
      case conv_op(instr) {
        Ok(op) ->
          emit_value_op_t(
            1,
            convop_result_type(op),
            fn(args) {
              case args {
                [a] -> ir.Convert(op, a)
                _ -> ir.Convert(op, ir.ConstI32(0))
              }
            },
            tail,
            ctx,
            st,
          )
        Error(_) -> Error(Unsupported("instruction"))
      }
  }
}

/// Pop `n` operands, bind `build(args)` (a value-producing expression) to a fresh name of
/// type `result_type`, push the name (recording its type), and lower `tail`.
/// `Error(StackUnderflow)` if fewer than `n` operands are present (only reachable on an
/// unvalidated module). The recorded `result_type` lets a later `select` recover its
/// operand type (§5 of the unit doc).
fn emit_value_op_t(
  n: Int,
  result_type: ir.ValType,
  build: fn(List(ir.Value)) -> ir.Expr,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  let args = take_push_order(st.stack, n)
  case list.length(args) == n {
    False -> Error(StackUnderflow)
    True -> {
      let rest_stack = list.drop(st.stack, n)
      let #(name, c2) = fresh(st.counter)
      let st2 =
        record_type(
          LState(..st, stack: [ir.Var(name), ..rest_stack], counter: c2),
          name,
          result_type,
        )
      use inner <- result.try(go(tail, ctx, st2))
      Ok(wrap_let([name], build(args), inner))
    }
  }
}

/// Bind a fresh name to a nullary value-producing expression `rhs` (`MemSize` /
/// `GlobalGet`) of type `result_type`, push it (recording its type), and lower `tail`.
/// Pops nothing.
fn emit_nullary(
  rhs: ir.Expr,
  result_type: ir.ValType,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  let #(name, c2) = fresh(st.counter)
  let st2 =
    record_type(
      LState(..st, stack: [ir.Var(name), ..st.stack], counter: c2),
      name,
      result_type,
    )
  use inner <- result.try(go(tail, ctx, st2))
  Ok(wrap_let([name], rhs, inner))
}

/// Lower a memory load: pop the i32 address, bind `MemLoad(mem, op, addr, offset, result)`
/// to a fresh name of type `result`, push it, and continue. `mem` is the memory index
/// (default `0` for a single-memory module — byte-identical); `op` carries the access
/// width/sign; `result` is the opcode-determined load result type.
fn emit_load(
  mem: Int,
  op: ir.MemAccess,
  result: ir.ValType,
  offset: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  emit_value_op_t(
    1,
    result,
    fn(args) {
      case args {
        [addr] -> ir.MemLoad(mem, op, addr, offset, result)
        _ -> ir.MemLoad(mem, op, ir.ConstI32(0), offset, result)
      }
    },
    tail,
    ctx,
    st,
  )
}

/// Lower a memory store: pop `[addr, value]` (value is on top of the WASM stack, so it is
/// second in push order), sequence `MemStore(mem, op, addr, value, offset)` as a zero-result
/// effect, and continue. `mem` is the memory index (default `0` — byte-identical). Pushes
/// nothing. Evaluation order is addr, then value, then the store (E6) — preserved by the
/// straight-line `Let([], …)` sequencing.
fn emit_store(
  mem: Int,
  op: ir.MemAccess,
  offset: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  emit_effect(
    2,
    fn(args) {
      case args {
        [addr, value] -> ir.MemStore(mem, op, addr, value, offset)
        _ -> ir.MemStore(mem, op, ir.ConstI32(0), ir.ConstI32(0), offset)
      }
    },
    tail,
    ctx,
    st,
  )
}

/// Pop `n` operands and sequence `build(args)` as a ZERO-result effect — `Let([], rhs, …)`
/// — then lower the continuation. Pushes nothing. Used by `MemStore` and `GlobalSet`, whose
/// effect must be ordered into the continuation and never dropped (E6). `Error(StackUnderflow)`
/// if fewer than `n` operands are present.
fn emit_effect(
  n: Int,
  build: fn(List(ir.Value)) -> ir.Expr,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  let args = take_push_order(st.stack, n)
  case list.length(args) == n {
    False -> Error(StackUnderflow)
    True -> {
      let rest_stack = list.drop(st.stack, n)
      let st2 = LState(..st, stack: rest_stack)
      use inner <- result.try(go(tail, ctx, st2))
      Ok(wrap_let([], build(args), inner))
    }
  }
}

/// The single argument of a one-operand op, or a defensive `ConstI32(0)` if absent (only
/// reachable on an unvalidated module — the caller guaranteed arity 1).
fn one(args: List(ir.Value)) -> ir.Value {
  case args {
    [a] -> a
    _ -> ir.ConstI32(0)
  }
}

/// A defensive zero i32 operand for the unreachable `_ ->` arm of a bulk/table op's
/// `build` (the arity was already checked by `emit_effect`; this only satisfies
/// exhaustiveness). Never appears in the output of a validated module.
fn z() -> ir.Value {
  ir.ConstI32(0)
}

// ─────────────────────────── WasmGC lowering helpers ───────────────────────────

/// The IR type a GC reference lowers to — a boxed BEAM term (an arena handle or null).
fn gc_ref_ty() -> ir.ValType {
  ir.TTerm
}

/// The struct fields at type index `t` (`UnknownTypeIndex` if absent / not a struct).
fn gc_struct_fields(
  ctx: LCtx,
  t: Int,
) -> Result(List(ast.FieldType), LowerError) {
  case ast.def_type_at(ctx.types, t) {
    Ok(ast.DefType(comp: ast.CtStruct(fs), ..)) -> Ok(fs)
    _ -> Error(UnknownTypeIndex(t))
  }
}

/// The array element field at type index `t`.
fn gc_array_field(ctx: LCtx, t: Int) -> Result(ast.FieldType, LowerError) {
  case ast.def_type_at(ctx.types, t) {
    Ok(ast.DefType(comp: ast.CtArray(fd), ..)) -> Ok(fd)
    _ -> Error(UnknownTypeIndex(t))
  }
}

/// The default operand for a defaultable storage type (numeric zero / null ref /
/// packed zero) — used to synthesize `struct.new_default` / `array.new_default`.
fn default_storage_value(s: ast.StorageType) -> ir.Value {
  case s {
    ast.StI8 | ast.StI16 -> ir.ConstI32(0)
    ast.StVal(vt) -> default_ir_value(vt)
  }
}

fn default_ir_value(vt: ast.ValType) -> ir.Value {
  case vt {
    ast.I32 -> ir.ConstI32(0)
    ast.I64 -> ir.ConstI64(0)
    ast.F32 -> ir.ConstF32(0)
    ast.F64 -> ir.ConstF64(0)
    // v128/ref: the null sentinel is a safe zero placeholder (validate already
    // confirmed the field is defaultable — a nullable ref or a numeric/vector).
    _ -> ir.ConstNull(ir.FuncRef)
  }
}

/// Lower `struct.get[_s|_u]`: resolve the field's storage to pick the read mode
/// (plain vs packed sign/zero-extend) and the IR result type.
fn lower_struct_get(
  t: Int,
  f: Int,
  signed: option.Option(Bool),
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use fields <- result.try(gc_struct_fields(ctx, t))
  use field <- result.try(nth_err(fields, f, UnknownTypeIndex(t)))
  let #(read, rty) = gc_field_read(field.storage, signed)
  emit_value_op_t(
    1,
    rty,
    fn(a) { ir.Gc(ir.GcStructGet(f, read), a) },
    tail,
    ctx,
    st,
  )
}

/// Lower `array.get[_s|_u]`: like `struct.get` but two operands (`[ref, index]`).
fn lower_array_get(
  t: Int,
  signed: option.Option(Bool),
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use field <- result.try(gc_array_field(ctx, t))
  let #(read, rty) = gc_field_read(field.storage, signed)
  emit_value_op_t(
    2,
    rty,
    fn(a) { ir.Gc(ir.GcArrayGet(read), a) },
    tail,
    ctx,
    st,
  )
}

/// The read mode + IR result type of a field/element access: a plain (non-packed)
/// field reads as its value type; a packed `i8`/`i16` sign/zero-extends to `i32`.
fn gc_field_read(
  storage: ast.StorageType,
  signed: option.Option(Bool),
) -> #(ir.FieldRead, ir.ValType) {
  case storage {
    ast.StVal(vt) -> #(ir.ReadPlain, to_ir_vt(vt))
    ast.StI8 -> #(ir.ReadPacked(8, sign_of(signed)), ir.TI32)
    ast.StI16 -> #(ir.ReadPacked(16, sign_of(signed)), ir.TI32)
  }
}

/// The byte width of a storage type — the stride `array.new_data`/`init_data`
/// decode each element at (numeric elements are their raw little-endian bit
/// pattern, so width is all the runtime needs). Reference elements never reach
/// the data ops (validate rejects them); 4 is a harmless default.
fn storage_byte_width(s: ast.StorageType) -> Int {
  case s {
    ast.StI8 -> 1
    ast.StI16 -> 2
    ast.StVal(ast.I64) | ast.StVal(ast.F64) -> 8
    ast.StVal(ast.V128) -> 16
    ast.StVal(_) -> 4
  }
}

fn sign_of(signed: option.Option(Bool)) -> Bool {
  case signed {
    option.Some(b) -> b
    option.None -> False
  }
}

/// The RTTI matcher + null-acceptance flag for a `ref.test`/`ref.cast` target: a
/// concrete target expands to the closed set of subtype indices; abstract targets
/// map to an object-kind atom. Null is accepted iff the target ref type is nullable.
fn gc_matcher(rt: ast.RefType, ctx: LCtx) -> #(ir.GcMatcher, Bool) {
  let m = case rt.heap {
    ast.HConcrete(t) -> ir.MatchConcrete(subtype_set(t, ctx.types, ctx.canon))
    ast.HStruct -> ir.MatchAbstract(ir.KStruct)
    ast.HArray -> ir.MatchAbstract(ir.KArray)
    ast.HI31 -> ir.MatchAbstract(ir.KI31)
    ast.HEq -> ir.MatchAbstract(ir.KEq)
    ast.HAny -> ir.MatchAbstract(ir.KAny)
    ast.HNone -> ir.MatchAbstract(ir.KNone)
    ast.HFunc -> ir.MatchAbstract(ir.KFunc)
    ast.HNoFunc -> ir.MatchAbstract(ir.KNoFunc)
    ast.HExtern -> ir.MatchAbstract(ir.KExtern)
    ast.HNoExtern -> ir.MatchAbstract(ir.KNoExtern)
    ast.HExn -> ir.MatchAbstract(ir.KExn)
    ast.HNoExn -> ir.MatchAbstract(ir.KNoExn)
  }
  #(m, rt.nullable)
}

/// The closed set of concrete type indices `<:` `t` — the runtime match set for a
/// concrete `ref.test`/`ref.cast` (an object whose stored type index is in this set
/// matches). Bounded walk (chain ≤ #types) so a malformed cycle can't loop.
fn subtype_set(
  t: Int,
  types: List(ast.DefType),
  canon: List(Int),
) -> List(Int) {
  let n = list.length(types)
  types
  |> list.index_map(fn(_dt, i) { i })
  |> list.filter(fn(i) { gc_reaches(i, t, types, canon, n) })
}

/// Lower `call_ref $t`: pop the funcref (top of stack) then the params, and bind
/// the callee's results. Mirrors `lower_call_indirect`, but the target is the
/// funcref value itself (no table dispatch) — `ir.Gc(GcCallRef, [funcref, ...params])`.
fn lower_call_ref(
  type_idx: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use sig <- result.try(func_type_err(
    ctx.types,
    type_idx,
    UnknownTypeIndex(type_idx),
  ))
  let result_ir_types = list.map(sig.results, to_ir_vt)
  let rc = list.length(sig.results)
  use #(funcref, stack1) <- result.try(pop1(st.stack))
  let pcount = list.length(sig.params)
  let args = take_push_order(stack1, pcount)
  case list.length(args) == pcount {
    False -> Error(StackUnderflow)
    True -> {
      let rest_stack = list.drop(stack1, pcount)
      let #(names, c2) = fresh_n(st.counter, rc)
      let result_vars = list.map(names, ir.Var)
      let st2 =
        record_types(
          LState(
            ..st,
            stack: list.append(list.reverse(result_vars), rest_stack),
            counter: c2,
          ),
          list.zip(names, result_ir_types),
        )
      use inner <- result.try(go(tail, ctx, st2))
      Ok(wrap_let(names, ir.Gc(ir.GcCallRef(rc), [funcref, ..args]), inner))
    }
  }
}

/// Lower `return_call_ref $t`: a tail call through a funcref — pop the funcref
/// (top) then the params, emit the `ir.ReturnCallRef` bottom node, and consume the
/// (dead) tail. Mirrors `lower_return_call_indirect` without a table dispatch.
fn lower_return_call_ref(
  type_idx: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use sig <- result.try(func_type_err(
    ctx.types,
    type_idx,
    UnknownTypeIndex(type_idx),
  ))
  use #(funcref, stack1) <- result.try(pop1(st.stack))
  let pcount = list.length(sig.params)
  let args = take_push_order(stack1, pcount)
  case list.length(args) == pcount {
    False -> Error(StackUnderflow)
    True -> {
      let node = ir.ReturnCallRef(funcref, args)
      use #(marker, rest) <- result.try(consume_dead(tail, 0))
      Ok(end_or_else(marker, node, rest, st.counter))
    }
  }
}

/// Lower `br_on_null`/`br_on_non_null l`: pop the ref, branch on `ref.is_null`.
/// `br_on_null` (on_null = True) branches on the null case carrying the stack sans
/// the ref, and falls through keeping the (now non-null) ref; `br_on_non_null`
/// swaps which side branches and which keeps the ref.
fn lower_br_on_null(
  l: Int,
  on_null: Bool,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(ref, stack1) <- result.try(pop1(st.stack))
  let #(cond_name, c2) = fresh(st.counter)
  use cur <- result.try(current_frame(st))
  let st_without = LState(..st, stack: stack1, counter: c2)
  let st_with = LState(..st, stack: [ref, ..stack1], counter: c2)
  case on_null {
    True -> {
      use transfer <- result.try(build_transfer(l, st_without))
      use inner <- result.try(go(tail, ctx, st_with))
      Ok(finish_br_cond(cond_name, ref, cur, transfer, inner, True))
    }
    False -> {
      use transfer <- result.try(build_transfer(l, st_with))
      use inner <- result.try(go(tail, ctx, st_without))
      Ok(finish_br_cond(cond_name, ref, cur, transfer, inner, False))
    }
  }
}

/// Lower `br_on_cast`/`br_on_cast_fail l _ rt2`: pop the ref, branch on
/// `ref.test rt2`. Both sides keep the ref on the stack (the spec fall-through /
/// branch both carry a ref); `br_on_cast` branches when the test succeeds,
/// `br_on_cast_fail` (is_fail = True) when it fails.
fn lower_br_on_cast(
  l: Int,
  rt2: ast.RefType,
  is_fail: Bool,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(ref, stack1) <- result.try(pop1(st.stack))
  let #(cond_name, c2) = fresh(st.counter)
  use cur <- result.try(current_frame(st))
  let #(matcher, null_ok) = gc_matcher(rt2, ctx)
  let st_with = LState(..st, stack: [ref, ..stack1], counter: c2)
  use transfer <- result.try(build_transfer(l, st_with))
  use inner <- result.try(go(tail, ctx, st_with))
  let mk = fn(e) {
    case is_fail {
      False -> ir.If(ir.Var(cond_name), cur.result_types, transfer, e)
      True -> ir.If(ir.Var(cond_name), cur.result_types, e, transfer)
    }
  }
  let gr = case inner {
    GEnd(e, rest, c) -> GEnd(mk(e), rest, c)
    GElse(e, rest, c) -> GElse(mk(e), rest, c)
  }
  Ok(wrap_let([cond_name], ir.Gc(ir.GcRefTest(matcher, null_ok), [ref]), gr))
}

/// Assemble a branch-cast `If`: bind `cond = ref.is_null(ref)`, then choose which
/// arm branches. `branch_when_null` puts the transfer in the then-arm (br_on_null)
/// or the else-arm (br_on_non_null).
fn finish_br_cond(
  cond_name: String,
  ref: ir.Value,
  cur: LFrame,
  transfer: ir.Expr,
  inner: GoResult,
  branch_when_null: Bool,
) -> GoResult {
  let mk = fn(e) {
    case branch_when_null {
      True -> ir.If(ir.Var(cond_name), cur.result_types, transfer, e)
      False -> ir.If(ir.Var(cond_name), cur.result_types, e, transfer)
    }
  }
  let gr = case inner {
    GEnd(e, rest, c) -> GEnd(mk(e), rest, c)
    GElse(e, rest, c) -> GElse(mk(e), rest, c)
  }
  wrap_let([cond_name], ir.RefIsNull(ref), gr)
}

/// Does concrete type `i` reach `t` up its declared supertype chain, comparing by
/// **iso-recursive canonical id** (`canon[i'] == canon[t]`) rather than declared
/// index — so a `ref.test`/`ref.cast` to `$t` matches every structurally-equivalent
/// concrete type, across rec groups (mirrors the validator's `supertype_reaches`).
/// Bounded by `fuel` (chain length ≤ #types) so a malformed cycle can't loop.
fn gc_reaches(
  i: Int,
  t: Int,
  types: List(ast.DefType),
  canon: List(Int),
  fuel: Int,
) -> Bool {
  case gc_canon_eq(canon, i, t) {
    True -> True
    False ->
      case fuel <= 0 {
        True -> False
        False ->
          case ast.def_type_at(types, i) {
            Ok(ast.DefType(supertype: option.Some(s), ..)) ->
              gc_reaches(s, t, types, canon, fuel - 1)
            _ -> False
          }
      }
  }
}

/// `True` iff type indices `i` and `j` have the same canonical id, falling back to
/// declared-index equality when either index is out of range of `canon`.
fn gc_canon_eq(canon: List(Int), i: Int, j: Int) -> Bool {
  case i == j {
    True -> True
    False ->
      case nth_canon(canon, i), nth_canon(canon, j) {
        Ok(ci), Ok(cj) -> ci == cj
        _, _ -> False
      }
  }
}

/// Total list indexing for the canonical-id list.
fn nth_canon(xs: List(Int), i: Int) -> Result(Int, Nil) {
  case i < 0 {
    True -> Error(Nil)
    False ->
      case xs {
        [] -> Error(Nil)
        [x, ..rest] ->
          case i {
            0 -> Ok(x)
            _ -> nth_canon(rest, i - 1)
          }
      }
  }
}

/// A defensive null funcref operand, the reference-typed counterpart of `z/0` (used where
/// a bulk/table op's unreachable arm needs a reference value).
fn zref() -> ir.Value {
  ir.ConstNull(ir.FuncRef)
}

/// Lower `call_indirect y x`: pop the i32 table index (top of stack), then the type's
/// params (push order beneath it); bind the type's results to fresh names; push them; emit
/// `CallIndirect(table, index, ty, args)`. The `ty` is the STRUCTURAL expected type
/// `module.types[y]` (the runtime does the per-call type check, E3); the table immediate
/// `x` maps to the stable name `t<x>` (MVP reserved `0` → `"t0"`). lower carries no funcidx
/// and no `apply` — the build-controlled dispatch is the runtime's job (D3a, preserved
/// structurally). `Error(UnknownTypeIndex(y))` if `y` is out of range; `Error(StackUnderflow)`
/// if the stack lacks the index/args (both only reachable on an unvalidated module).
fn lower_call_indirect(
  type_idx: Int,
  table: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use sig <- result.try(func_type_err(
    ctx.types,
    type_idx,
    UnknownTypeIndex(type_idx),
  ))
  let result_ir_types = list.map(sig.results, to_ir_vt)
  let ir_ty = ir.FuncType(list.map(sig.params, to_ir_vt), result_ir_types)
  use #(index, stack1) <- result.try(pop1(st.stack))
  let pcount = list.length(sig.params)
  let args = take_push_order(stack1, pcount)
  case list.length(args) == pcount {
    False -> Error(StackUnderflow)
    True -> {
      let rest_stack = list.drop(stack1, pcount)
      let #(names, c2) = fresh_n(st.counter, list.length(sig.results))
      let result_vars = list.map(names, ir.Var)
      let st2 =
        record_types(
          LState(
            ..st,
            stack: list.append(list.reverse(result_vars), rest_stack),
            counter: c2,
          ),
          list.zip(names, result_ir_types),
        )
      use inner <- result.try(go(tail, ctx, st2))
      Ok(wrap_let(
        names,
        ir.CallIndirect(tname(table), index, ir_ty, args),
        inner,
      ))
    }
  }
}

/// Lower `select` (0x1B) to the existing `If` (no new IR node). `select` pops `cond` (top),
/// then `val2`, then `val1`; the result is `val1` iff `cond ≠ 0` (spec exec/instructions).
/// So this emits `If(cond, [t], Values([val1]), Values([val2]))` — then-arm `val1`, else-arm
/// `val2` — where `t` is the operands' shared `ValType`, recovered from `val1` via
/// `value_type`. `Error(StackUnderflow)` on an under-deep stack (unvalidated module).
fn lower_select(
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(cond, stack1) <- result.try(pop1(st.stack))
  // `val1` is deeper (pushed first), `val2` nearer the top (pushed second).
  case take_push_order(stack1, 2) {
    // Untyped `select` (0x1B): the result type is operand-determined — recover it from
    // `val1` via the SSA type map (numeric operands only, per the spec).
    [val1, val2] ->
      finish_select(
        cond,
        val1,
        val2,
        value_type(st, val1),
        stack1,
        tail,
        ctx,
        st,
      )
    _ -> Error(StackUnderflow)
  }
}

/// Lower typed `select t` (0x1C) — the reference-admitting form — to the SAME `If`
/// value-merge (no new IR node, exactly like untyped `select`), but taking the result
/// type from the explicit `vec(valtype)` immediate rather than recovering it from an
/// operand. In the MVP the immediate is exactly one type (validate guarantees arity 1);
/// a different arity is `Error(Malformed)` fail-closed. Per spec exec/instructions.
fn lower_select_t(
  types: List(ast.ValType),
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use t <- result.try(case types {
    [ty] -> Ok(to_ir_vt(ty))
    _ -> Error(Malformed("select_t result arity must be 1"))
  })
  use #(cond, stack1) <- result.try(pop1(st.stack))
  case take_push_order(stack1, 2) {
    [val1, val2] -> finish_select(cond, val1, val2, t, stack1, tail, ctx, st)
    _ -> Error(StackUnderflow)
  }
}

/// The shared `select`/`select_t` core: emit `If(cond, [t], Values([val1]),
/// Values([val2]))` — the result is `val1` iff `cond ≠ 0` (spec: then-arm `val1`,
/// else-arm `val2`) — bind it to a fresh name of type `t`, and lower the continuation.
/// `stack1` is the operand stack after `cond` was popped (with `val1`/`val2` still on it).
fn finish_select(
  cond: ir.Value,
  val1: ir.Value,
  val2: ir.Value,
  t: ir.ValType,
  stack1: List(ir.Value),
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  let rest_stack = list.drop(stack1, 2)
  let #(name, c2) = fresh(st.counter)
  let st2 =
    record_type(
      LState(..st, stack: [ir.Var(name), ..rest_stack], counter: c2),
      name,
      t,
    )
  use inner <- result.try(go(tail, ctx, st2))
  Ok(wrap_let(
    [name],
    ir.If(cond, [t], ir.Values([val1]), ir.Values([val2])),
    inner,
  ))
}

/// Lower a `call f` (direct or cross-module import). Pops the callee's parameters, binds its
/// results to fresh names (multi-value capable), pushes them, and continues.
///
/// The callee signature is fetched up front (needed for BOTH branches — Phase 5 fetched it
/// only in the defined branch) from `ctx.func_types`, which spans `imports ++ defined`, so an
/// imported funcidx recovers its signature.
///
/// - `f < ctx.imported` (a function import) → `ir.CallImport(slot, ty, args)` (I5/S5): `slot`
///   is the positional function-import index, which *is* `f` because function imports occupy
///   funcidx `0 .. imported-1`; `ty` is the import's IR signature. emit_core (06) dispatches
///   this via the linker-built closure capability (`link.call_import`), never a name lookup
///   (D3a). This un-skips both `spectest.print`-style host calls and `linking.wast`
///   cross-module wasm calls — a single mechanism (Phase 5 rejected them at lower).
/// - `f >= ctx.imported` (a same-module function) → `ir.CallDirect("f<f>", args)` (unchanged,
///   byte-identical).
///
/// `Error(UnknownFuncIndex(f))` if `f` is out of range; `Error(StackUnderflow)` if the stack
/// lacks the params (both only reachable on an unvalidated module — fail-closed insurance).
fn lower_call(
  f: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use sig <- result.try(nth_err(ctx.func_types, f, UnknownFuncIndex(f)))
  let pcount = list.length(sig.params)
  let rcount = list.length(sig.results)
  let args = take_push_order(st.stack, pcount)
  case list.length(args) == pcount {
    False -> Error(StackUnderflow)
    True -> {
      let rest_stack = list.drop(st.stack, pcount)
      let #(names, c2) = fresh_n(st.counter, rcount)
      let result_vars = list.map(names, ir.Var)
      let st2 =
        record_types(
          LState(
            ..st,
            stack: list.append(list.reverse(result_vars), rest_stack),
            counter: c2,
          ),
          list.zip(names, list.map(sig.results, to_ir_vt)),
        )
      use inner <- result.try(go(tail, ctx, st2))
      let call = case f < ctx.imported {
        True -> ir.CallImport(f, ir_functype(sig), args)
        False -> ir.CallDirect("f" <> int.to_string(f), args)
      }
      Ok(wrap_let(names, call, inner))
    }
  }
}

/// Lower `return_call f` (tail-call proposal, opcode 0x12) as a BOTTOM transfer (Phase 13, Q4).
///
/// Per the tail-call proposal, `return_call` replaces the current activation with a call to `f`:
/// it pops `f`'s params, transfers control, and the rest of the block is UNREACHABLE
/// (stack-polymorphic, exactly like `return`). Therefore lower builds a single leaf
/// bottom-transfer node from the top operands and DISCARDS the dead continuation — it does NOT
/// bind result names or recurse into a live tail (there are no result values to bind in the
/// caller; the callee's results become the caller's, per the Q13-03 result-equality rule). This
/// is the `Return` shape, not the `Call` shape: no `fresh_n`, no `record_types`, no `wrap_let`,
/// no `go(tail, …)` recursion, and the name counter stays UNADVANCED (as `ir.Return` / `throw`).
///
/// The callee signature is fetched from `ctx.func_types` (which spans imports ++ defined, so an
/// imported funcidx recovers its signature) — identical to `lower_call`. The import split mirrors
/// `lower_call`:
/// - `f < ctx.imported` (a function import) → `ir.ReturnCallImport(slot: f, ty, args)`; `slot` is
///   the positional function-import index (= `f`, since imports occupy funcidx `0 .. imported-1`);
///   `ty` is the import's IR signature (`ir_functype(sig)`). emit_core (Q13-05) tail-applies the
///   linker-built `link.call_import` capability under `KReturn` — never a name lookup (D3a).
/// - `f >= ctx.imported` (a same-module function) → `ir.ReturnCall("f<f>", args)`.
///
/// - `tail`: the instructions AFTER this `return_call` in the current frame — dead code, consumed
///   to the frame's closing marker by `consume_dead`.
///
/// Returns `Ok(GoResult)` (the transfer node closed on the frame's `end`/`else`). Fail-closed
/// (never a panic): `Error(UnknownFuncIndex(f))` if `f` is out of range, `Error(StackUnderflow)`
/// if the stack lacks the params — both only reachable on an UNVALIDATED module (validate is the
/// real boundary).
fn lower_return_call(
  f: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use sig <- result.try(nth_err(ctx.func_types, f, UnknownFuncIndex(f)))
  let pcount = list.length(sig.params)
  let args = take_push_order(st.stack, pcount)
  case list.length(args) == pcount {
    False -> Error(StackUnderflow)
    True -> {
      let node = case f < ctx.imported {
        True -> ir.ReturnCallImport(f, ir_functype(sig), args)
        False -> ir.ReturnCall("f" <> int.to_string(f), args)
      }
      use #(marker, rest) <- result.try(consume_dead(tail, 0))
      Ok(end_or_else(marker, node, rest, st.counter))
    }
  }
}

/// Lower `return_call_indirect y x` (tail-call proposal, opcode 0x13) as a BOTTOM transfer
/// (Phase 13, Q4).
///
/// Pops the i32 table index (top of stack), then the type's params (push order beneath it), and
/// builds a single leaf `ir.ReturnCallIndirect(table, index, ty, args)`; the dead continuation is
/// discarded. `ty` is the STRUCTURAL expected type `module.types[y]` (the runtime does the
/// per-call type check via the Q13-01 `rt_table` lookup seam — E3/D3a); the table immediate `x`
/// maps to the stable name `t<x>` (`tname`). Lower carries NO funcidx and NO `apply` — the
/// build-controlled dispatch stays the runtime's job, exactly as for non-tail `call_indirect`. The
/// 3 ordered traps (undefined element → uninitialized element → type mismatch) are preserved by
/// emit_core + rt_table (Q13-05/Q13-01), NOT here. This is the `Return` shape: no `fresh_n`, no
/// `record_types`, no `wrap_let`, no `go(tail, …)` recursion, and the counter stays UNADVANCED.
///
/// - `tail`: dead code after this instruction — consumed to the frame's closing marker.
///
/// Returns `Ok(GoResult)`. Fail-closed (never a panic): `Error(UnknownTypeIndex(y))` if `y` is out
/// of range, `Error(StackUnderflow)` if the stack lacks the index/params — both only reachable on
/// an UNVALIDATED module.
fn lower_return_call_indirect(
  type_idx: Int,
  table: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use sig <- result.try(func_type_err(
    ctx.types,
    type_idx,
    UnknownTypeIndex(type_idx),
  ))
  let ir_ty =
    ir.FuncType(list.map(sig.params, to_ir_vt), list.map(sig.results, to_ir_vt))
  use #(index, stack1) <- result.try(pop1(st.stack))
  let pcount = list.length(sig.params)
  let args = take_push_order(stack1, pcount)
  case list.length(args) == pcount {
    False -> Error(StackUnderflow)
    True -> {
      let node = ir.ReturnCallIndirect(tname(table), index, ir_ty, args)
      use #(marker, rest) <- result.try(consume_dead(tail, 0))
      Ok(end_or_else(marker, node, rest, st.counter))
    }
  }
}

// ─────────────────────────────── SIMD lane-op lowering ───────────────────────────────

/// Lower a pure lane-wise SIMD op (`ast.Simd(op)`) to `ir.Simd(<neutral op>, args)`. Relabels
/// the AST op to the frozen parametric `ir.SimdOp` (S3), derives the operand arity + result
/// type from it (`simd_op_arity_result`), and routes through the shared `emit_value_op_t` path
/// — the same shape as a numeric op. Operand order follows the spec stack types (deepest-first
/// via `take_push_order`): a binary op yields `[a, b]`, a shift `[v, count]`, `bitselect`
/// `[v1, v2, mask]`, `replace_lane` `[vec, x]`, `swizzle` `[a, idx]`.
fn lower_simd(
  op: ast.SimdOp,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  let ir_op = relabel_simd_op(op)
  let #(arity, result_type) = simd_op_arity_result(ir_op)
  emit_value_op_t(
    arity,
    result_type,
    fn(args) { ir.Simd(ir_op, args) },
    tail,
    ctx,
    st,
  )
}

/// The operand arity + IR result type of a neutral `ir.SimdOp` (the routing facts
/// `emit_value_op_t` needs). Per the spec vector-instruction stack types
/// ([exec/instructions#vector-instructions](https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions)):
///
/// - Most ops yield a `v128` (`TV128`): binary arithmetic/compare/shift/narrow/extmul/dot/q15/
///   swizzle (arity 2), unary neg/abs/popcnt/extend/pairwise/float-unary/conversions (arity 1),
///   `bitselect` (arity 3), splat/replace-lane. **Comparisons yield a v128 MASK, not i32** (the
///   classic pitfall — spec § SIMD comparisons).
/// - The boolean reductions `any_true`/`all_true`/`bitmask` yield `TI32` (arity 1).
/// - `extract_lane` yields the lane's SCALAR type (`i32`/`i64`/`f32`/`f64` per shape); the
///   signed/unsigned narrow-shape variants yield `TI32`.
///
/// This mapping is INDEPENDENT of validate (lower runs after); validate already rejected any
/// illegal `(op, shape)` combination fail-closed.
fn simd_op_arity_result(op: ir.SimdOp) -> #(Int, ir.ValType) {
  case op {
    // binary integer arith / min-max / avgr / shifts / compares / narrow / extmul / dot /
    // q15 / swizzle → a v128 (compares yield a v128 mask, NOT i32).
    ir.SAdd(_)
    | ir.SSub(_)
    | ir.SMul(_)
    | ir.SAddSatS(_)
    | ir.SAddSatU(_)
    | ir.SSubSatS(_)
    | ir.SSubSatU(_)
    | ir.SMinS(_)
    | ir.SMinU(_)
    | ir.SMaxS(_)
    | ir.SMaxU(_)
    | ir.SAvgrU(_)
    | ir.SShl(_)
    | ir.SShrS(_)
    | ir.SShrU(_)
    | ir.SEq(_)
    | ir.SNe(_)
    | ir.SLtS(_)
    | ir.SLtU(_)
    | ir.SLeS(_)
    | ir.SLeU(_)
    | ir.SGtS(_)
    | ir.SGtU(_)
    | ir.SGeS(_)
    | ir.SGeU(_)
    | ir.SNarrow(_, _)
    | ir.SExtMul(_, _, _)
    | ir.SDotI16x8S
    | ir.SQ15MulrSatS
    | ir.SSwizzle -> #(2, ir.TV128)
    // unary integer / extend / pairwise → v128.
    ir.SNeg(_)
    | ir.SAbs(_)
    | ir.SPopcnt(_)
    | ir.SExtend(_, _, _)
    | ir.SExtAddPairwise(_, _) -> #(1, ir.TV128)
    // v128 bitwise (shape-agnostic).
    ir.VNot -> #(1, ir.TV128)
    ir.VAnd | ir.VOr | ir.VXor | ir.VAndNot -> #(2, ir.TV128)
    ir.VBitselect -> #(3, ir.TV128)
    // boolean reductions → i32.
    ir.VAnyTrue | ir.SAllTrue(_) | ir.SBitmask(_) -> #(1, ir.TI32)
    // splat (scalar → v128) / replace-lane (v128 + scalar → v128).
    ir.SSplat(_) -> #(1, ir.TV128)
    ir.SReplaceLane(_, _) -> #(2, ir.TV128)
    // extract-lane → the lane's scalar type (plain, or sign/zero-extended to i32).
    ir.SExtractLane(shape, _) -> #(1, lane_scalar_type(shape))
    ir.SExtractLaneS(_, _) | ir.SExtractLaneU(_, _) -> #(1, ir.TI32)
    // float binary (arith / min-max / pmin-pmax / compares → v128 mask).
    ir.SFAdd(_)
    | ir.SFSub(_)
    | ir.SFMul(_)
    | ir.SFDiv(_)
    | ir.SFMin(_)
    | ir.SFMax(_)
    | ir.SFPMin(_)
    | ir.SFPMax(_)
    | ir.SFEq(_)
    | ir.SFNe(_)
    | ir.SFLt(_)
    | ir.SFLe(_)
    | ir.SFGt(_)
    | ir.SFGe(_) -> #(2, ir.TV128)
    // float unary → v128.
    ir.SFNeg(_)
    | ir.SFAbs(_)
    | ir.SFSqrt(_)
    | ir.SFCeil(_)
    | ir.SFFloor(_)
    | ir.SFTrunc(_)
    | ir.SFNearest(_) -> #(1, ir.TV128)
    // conversions (int↔float lane; demote/promote) → v128, all unary.
    ir.STruncSatF32x4S
    | ir.STruncSatF32x4U
    | ir.STruncSatF64x2SZero
    | ir.STruncSatF64x2UZero
    | ir.SConvertF32x4I32x4S
    | ir.SConvertF32x4I32x4U
    | ir.SConvertF64x2LowI32x4S
    | ir.SConvertF64x2LowI32x4U
    | ir.SDemoteF64x2Zero
    | ir.SPromoteLowF32x4 -> #(1, ir.TV128)
  }
}

/// The IR scalar type a shape's lane holds — the result type of a plain `extract_lane`
/// (`i32x4`→`TI32`, `i64x2`→`TI64`, `f32x4`→`TF32`, `f64x2`→`TF64`). `I8x16`/`I16x8` never use
/// the plain extract (they use the sign/zero-extending `_s`/`_u` variants → `TI32`), but map
/// defensively to `TI32` so this stays total.
fn lane_scalar_type(shape: ir.SimdShape) -> ir.ValType {
  case shape {
    ir.I8x16 | ir.I16x8 | ir.I32x4 -> ir.TI32
    ir.I64x2 -> ir.TI64
    ir.F32x4 -> ir.TF32
    ir.F64x2 -> ir.TF64
  }
}

/// Relabel an AST SIMD op (`ast.SimdOp`) to the frozen neutral IR op (`ir.SimdOp`) — a pure,
/// mechanical, semantics-preserving mapping (S3). The two enums mirror each other
/// constructor-for-constructor with two spelling deltas the keystone pins: the float ops are
/// `F`-prefixed in the AST but **`SF`-prefixed** in the IR (the IR's `NumOp` already owns
/// `FAdd`/…), and the parametric widen/narrow/extmul/pairwise families copy their
/// `from`/`half`/`signed` fields (relabelling only the nested `SimdShape`/`SimdHalf`).
fn relabel_simd_op(op: ast.SimdOp) -> ir.SimdOp {
  case op {
    // integer arithmetic / saturating / min-max / avgr / shifts / popcnt
    ast.SAdd(s) -> ir.SAdd(relabel_shape(s))
    ast.SSub(s) -> ir.SSub(relabel_shape(s))
    ast.SMul(s) -> ir.SMul(relabel_shape(s))
    ast.SNeg(s) -> ir.SNeg(relabel_shape(s))
    ast.SAbs(s) -> ir.SAbs(relabel_shape(s))
    ast.SAddSatS(s) -> ir.SAddSatS(relabel_shape(s))
    ast.SAddSatU(s) -> ir.SAddSatU(relabel_shape(s))
    ast.SSubSatS(s) -> ir.SSubSatS(relabel_shape(s))
    ast.SSubSatU(s) -> ir.SSubSatU(relabel_shape(s))
    ast.SMinS(s) -> ir.SMinS(relabel_shape(s))
    ast.SMinU(s) -> ir.SMinU(relabel_shape(s))
    ast.SMaxS(s) -> ir.SMaxS(relabel_shape(s))
    ast.SMaxU(s) -> ir.SMaxU(relabel_shape(s))
    ast.SAvgrU(s) -> ir.SAvgrU(relabel_shape(s))
    ast.SShl(s) -> ir.SShl(relabel_shape(s))
    ast.SShrS(s) -> ir.SShrS(relabel_shape(s))
    ast.SShrU(s) -> ir.SShrU(relabel_shape(s))
    ast.SPopcnt(s) -> ir.SPopcnt(relabel_shape(s))
    // comparisons (→ v128 mask)
    ast.SEq(s) -> ir.SEq(relabel_shape(s))
    ast.SNe(s) -> ir.SNe(relabel_shape(s))
    ast.SLtS(s) -> ir.SLtS(relabel_shape(s))
    ast.SLtU(s) -> ir.SLtU(relabel_shape(s))
    ast.SLeS(s) -> ir.SLeS(relabel_shape(s))
    ast.SLeU(s) -> ir.SLeU(relabel_shape(s))
    ast.SGtS(s) -> ir.SGtS(relabel_shape(s))
    ast.SGtU(s) -> ir.SGtU(relabel_shape(s))
    ast.SGeS(s) -> ir.SGeS(relabel_shape(s))
    ast.SGeU(s) -> ir.SGeU(relabel_shape(s))
    // v128 bitwise + boolean reductions
    ast.VNot -> ir.VNot
    ast.VAnd -> ir.VAnd
    ast.VOr -> ir.VOr
    ast.VXor -> ir.VXor
    ast.VAndNot -> ir.VAndNot
    ast.VBitselect -> ir.VBitselect
    ast.VAnyTrue -> ir.VAnyTrue
    ast.SAllTrue(s) -> ir.SAllTrue(relabel_shape(s))
    ast.SBitmask(s) -> ir.SBitmask(relabel_shape(s))
    // lane access / build (lane index copied)
    ast.SSplat(s) -> ir.SSplat(relabel_shape(s))
    ast.SExtractLane(s, lane) -> ir.SExtractLane(relabel_shape(s), lane)
    ast.SExtractLaneS(s, lane) -> ir.SExtractLaneS(relabel_shape(s), lane)
    ast.SExtractLaneU(s, lane) -> ir.SExtractLaneU(relabel_shape(s), lane)
    ast.SReplaceLane(s, lane) -> ir.SReplaceLane(relabel_shape(s), lane)
    // float lanes: F* (AST) → SF* (IR) — same semantics, S3 spelling delta
    ast.FAdd(s) -> ir.SFAdd(relabel_shape(s))
    ast.FSub(s) -> ir.SFSub(relabel_shape(s))
    ast.FMul(s) -> ir.SFMul(relabel_shape(s))
    ast.FDiv(s) -> ir.SFDiv(relabel_shape(s))
    ast.FNeg(s) -> ir.SFNeg(relabel_shape(s))
    ast.FAbs(s) -> ir.SFAbs(relabel_shape(s))
    ast.FSqrt(s) -> ir.SFSqrt(relabel_shape(s))
    ast.FMin(s) -> ir.SFMin(relabel_shape(s))
    ast.FMax(s) -> ir.SFMax(relabel_shape(s))
    ast.FPMin(s) -> ir.SFPMin(relabel_shape(s))
    ast.FPMax(s) -> ir.SFPMax(relabel_shape(s))
    ast.FCeil(s) -> ir.SFCeil(relabel_shape(s))
    ast.FFloor(s) -> ir.SFFloor(relabel_shape(s))
    ast.FTrunc(s) -> ir.SFTrunc(relabel_shape(s))
    ast.FNearest(s) -> ir.SFNearest(relabel_shape(s))
    ast.FEq(s) -> ir.SFEq(relabel_shape(s))
    ast.FNe(s) -> ir.SFNe(relabel_shape(s))
    ast.FLt(s) -> ir.SFLt(relabel_shape(s))
    ast.FLe(s) -> ir.SFLe(relabel_shape(s))
    ast.FGt(s) -> ir.SFGt(relabel_shape(s))
    ast.FGe(s) -> ir.SFGe(relabel_shape(s))
    // parametric widen / narrow / extmul / pairwise (copy from/half/signed)
    ast.SNarrow(from, signed) -> ir.SNarrow(relabel_shape(from), signed)
    ast.SExtend(from, half, signed) ->
      ir.SExtend(relabel_shape(from), relabel_half(half), signed)
    ast.SExtMul(from, half, signed) ->
      ir.SExtMul(relabel_shape(from), relabel_half(half), signed)
    ast.SExtAddPairwise(from, signed) ->
      ir.SExtAddPairwise(relabel_shape(from), signed)
    // conversions (named — copied 1:1)
    ast.STruncSatF32x4S -> ir.STruncSatF32x4S
    ast.STruncSatF32x4U -> ir.STruncSatF32x4U
    ast.STruncSatF64x2SZero -> ir.STruncSatF64x2SZero
    ast.STruncSatF64x2UZero -> ir.STruncSatF64x2UZero
    ast.SConvertF32x4I32x4S -> ir.SConvertF32x4I32x4S
    ast.SConvertF32x4I32x4U -> ir.SConvertF32x4I32x4U
    ast.SConvertF64x2LowI32x4S -> ir.SConvertF64x2LowI32x4S
    ast.SConvertF64x2LowI32x4U -> ir.SConvertF64x2LowI32x4U
    ast.SDemoteF64x2Zero -> ir.SDemoteF64x2Zero
    ast.SPromoteLowF32x4 -> ir.SPromoteLowF32x4
    // dot / q15 / swizzle (named — copied 1:1)
    ast.SDotI16x8S -> ir.SDotI16x8S
    ast.SQ15MulrSatS -> ir.SQ15MulrSatS
    ast.SSwizzle -> ir.SSwizzle
  }
}

/// Relabel an AST SIMD lane shape to the mirrored IR `SimdShape` (1:1).
fn relabel_shape(s: ast.SimdShape) -> ir.SimdShape {
  case s {
    ast.I8x16 -> ir.I8x16
    ast.I16x8 -> ir.I16x8
    ast.I32x4 -> ir.I32x4
    ast.I64x2 -> ir.I64x2
    ast.F32x4 -> ir.F32x4
    ast.F64x2 -> ir.F64x2
  }
}

/// Relabel an AST widening/extending half-selector to the IR `SimdHalf` (1:1).
fn relabel_half(h: ast.SimdHalf) -> ir.SimdHalf {
  case h {
    ast.Low -> ir.Low
    ast.High -> ir.High
  }
}

/// Relabel an AST `SimdLoadKind` to the mirrored IR `SimdLoadKind`. All bit-width fields are
/// **BITS** in both enums (S2 — `LoadSplat`/`LoadZero`'s `lane_bits`, `LoadExtend`'s
/// `source_bits`), copied verbatim.
fn relabel_load_kind(k: ast.SimdLoadKind) -> ir.SimdLoadKind {
  case k {
    ast.LoadV128 -> ir.LoadV128
    ast.LoadSplat(lane_bits) -> ir.LoadSplat(lane_bits)
    ast.LoadExtend(source_bits, signed) -> ir.LoadExtend(source_bits, signed)
    ast.LoadZero(lane_bits) -> ir.LoadZero(lane_bits)
  }
}

/// A defensive all-zero `v128` value literal (`<<0:128>>`), the v128 counterpart of `z/0`,
/// used only in the unreachable `_ ->` arm of a SIMD node's `build` (the arity was already
/// checked). Never appears in the output of a validated module.
fn zv128() -> ir.Value {
  ir.ConstV128(<<0:size(128)>>)
}

// ─────────────────────────────── structured-control lowering ───────────────────────────────

/// Lower a `block`. Locals assigned within it are threaded out as extra block results;
/// the body is lowered under a fresh named `Block` label whose fall-through and every
/// `Break` to it yield `[block results ++ carried locals]`.
fn lower_block(
  bt: ast.BlockType,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(in_ir, out_ir) <- result.try(blocktype_io(bt, ctx))
  let in_n = list.length(in_ir)
  let out_n = list.length(out_ir)
  // Lever 5: a `block`'s carried locals are its extra RESULTS (the merge after it); narrow to the
  // ones live at that exit. `br 0` to the block and the fall-through both land at the same merge, so
  // the narrowed set is sound for every exit.
  let #(carried, body_ctx) =
    narrow_join_carried(scan_modified(tail, 0, set.new()), tail, ctx)
  use carried_ts <- result.try(carried_types(carried, ctx.local_types))
  let result_types = list.append(out_ir, carried_ts)

  let inner_stack = list.take(st.stack, in_n)
  let below = list.drop(st.stack, in_n)
  let #(label, c1) = fresh_label(st.counter)
  let frame =
    LFrame(
      label: label,
      kind: FBlock,
      branch_arity: out_n,
      out_arity: out_n,
      result_types: result_types,
      carried: carried,
    )
  let child =
    LState(
      stack: inner_stack,
      locals: st.locals,
      counter: c1,
      frames: [frame, ..st.frames],
      var_types: st.var_types,
    )
  use body_res <- result.try(go(tail, body_ctx, child))
  use #(body_expr, rest, c2) <- result.try(expect_end(body_res))
  finish_construct(
    ir.Block(label, result_types, body_expr),
    result_types,
    out_n,
    carried,
    below,
    rest,
    c2,
    ctx,
    st,
  )
}

/// Lower a `loop`. The blocktype params and every locally-assigned local become
/// loop-carried `LoopParam`s; the back-edge (`br` to the loop) becomes `Continue`
/// rebinding them. The constant-space tail loop is realised by emit_core.
fn lower_loop(
  bt: ast.BlockType,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(in_ir, out_ir) <- result.try(blocktype_io(bt, ctx))
  let in_n = list.length(in_ir)
  let out_n = list.length(out_ir)
  // Lever 5: a `loop`'s carried locals become loop PARAMETERS — threaded both out on exit AND back
  // on every `br 0` (Continue) into the next iteration. So a carried local must be kept if it is
  // live at the loop's exit OR at its back-edge (read on a later iteration); `narrow_loop_carried`
  // drops only the ones dead on BOTH.
  let #(carried, body_ctx) =
    narrow_loop_carried(scan_modified(tail, 0, set.new()), tail, ctx)
  use carried_ts <- result.try(carried_types(carried, ctx.local_types))
  use carried_inits <- result.try(get_locals(st, carried))

  let in_vals = take_push_order(st.stack, in_n)
  let below = list.drop(st.stack, in_n)
  let #(lp_names, c1) = fresh_n(st.counter, in_n + list.length(carried))
  let in_names = list.take(lp_names, in_n)
  let carried_names = list.drop(lp_names, in_n)

  let in_params = zip3_loop_params(in_names, in_ir, in_vals)
  let carried_params =
    zip3_loop_params(carried_names, carried_ts, carried_inits)
  let loop_params = list.append(in_params, carried_params)
  let result_types = list.append(out_ir, carried_ts)

  let #(label, c2) = fresh_label(c1)
  let inner_stack = list.reverse(list.map(in_names, ir.Var))
  let inner_locals = update_locals(st.locals, carried, carried_names)
  // The loop-param names (the inputs on the inner stack and the carried locals) are fresh
  // SSA names: record their types so a `select` inside the loop body recovers them.
  let child_var_types =
    insert_types(
      st.var_types,
      list.append(
        list.zip(in_names, in_ir),
        list.zip(carried_names, carried_ts),
      ),
    )
  let frame =
    LFrame(
      label: label,
      kind: FLoop,
      branch_arity: in_n,
      out_arity: out_n,
      result_types: result_types,
      carried: carried,
    )
  let child =
    LState(
      stack: inner_stack,
      locals: inner_locals,
      counter: c2,
      frames: [frame, ..st.frames],
      var_types: child_var_types,
    )
  use body_res <- result.try(go(tail, body_ctx, child))
  use #(body_expr, rest, c3) <- result.try(expect_end(body_res))
  finish_construct(
    ir.Loop(label, loop_params, result_types, body_expr),
    result_types,
    out_n,
    carried,
    below,
    rest,
    c3,
    ctx,
    st,
  )
}

/// Lower an `if`. Pops the i32 condition; both arms start from the same operand prefix
/// and pre-`if` locals; locals assigned in either arm are threaded out as extra results.
/// A missing `else` is synthesised as an arm forwarding the params (`params == results`,
/// guaranteed by validation) and the unchanged carried locals.
fn lower_if(
  bt: ast.BlockType,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(in_ir, out_ir) <- result.try(blocktype_io(bt, ctx))
  let in_n = list.length(in_ir)
  let out_n = list.length(out_ir)
  // Lever 5: an `if`'s carried locals are its extra RESULTS (the merge after the whole `if`), like a
  // `block` — narrow to the ones live at that exit (both arms + any `br 0` land at the same merge).
  let #(carried, body_ctx) =
    narrow_join_carried(scan_modified(tail, 0, set.new()), tail, ctx)
  use carried_ts <- result.try(carried_types(carried, ctx.local_types))
  let result_types = list.append(out_ir, carried_ts)

  use #(cond, stack1) <- result.try(pop1(st.stack))
  let inner_stack = list.take(stack1, in_n)
  let below = list.drop(stack1, in_n)
  let #(label, c1) = fresh_label(st.counter)
  let frame =
    LFrame(
      label: label,
      kind: FIf,
      branch_arity: out_n,
      out_arity: out_n,
      result_types: result_types,
      carried: carried,
    )
  let child_then =
    LState(
      stack: inner_stack,
      locals: st.locals,
      counter: c1,
      frames: [frame, ..st.frames],
      var_types: st.var_types,
    )
  use then_res <- result.try(go(tail, body_ctx, child_then))
  case then_res {
    GElse(then_expr, after_else, c2) -> {
      let child_else =
        LState(
          stack: inner_stack,
          locals: st.locals,
          counter: c2,
          frames: [frame, ..st.frames],
          var_types: st.var_types,
        )
      use else_res <- result.try(go(after_else, body_ctx, child_else))
      use #(else_expr, rest, c3) <- result.try(expect_end(else_res))
      finish_if(
        label,
        cond,
        result_types,
        then_expr,
        else_expr,
        out_n,
        carried,
        below,
        rest,
        c3,
        ctx,
        st,
      )
    }
    GEnd(then_expr, after_end, c2) -> {
      // No `else`: synthesise one forwarding the inputs (params == results) and the
      // unchanged carried locals (their pre-`if` values).
      use carried_curr <- result.try(get_locals(st, carried))
      let else_vals = list.append(list.reverse(inner_stack), carried_curr)
      let else_expr = ir.Values(else_vals)
      finish_if(
        label,
        cond,
        result_types,
        then_expr,
        else_expr,
        out_n,
        carried,
        below,
        after_end,
        c2,
        ctx,
        st,
      )
    }
  }
}

/// Bind an `if`'s results and continue lowering after it (shared by the with/without
/// `else` paths).
///
/// A WASM `if` is itself a labelled block: `br 0` (from anywhere inside, possibly nested)
/// exits the `if` forward. The IR `If` node carries **no** label, so when any branch
/// targets this `if`'s frame the lowering must give the label a home: it wraps the `If` in
/// an `ir.Block(label, result_types, If(..))` — the same `result_types`, so the wrapper is
/// arity-transparent — and the `Break(label, …)` then resolves to that block's forward
/// exit. When the `if` is *not* a branch target (the common case — `fib`/`fac`), the bare
/// `If` is emitted with no wrapper.
fn finish_if(
  label: String,
  cond: ir.Value,
  result_types: List(ir.ValType),
  then_expr: ir.Expr,
  else_expr: ir.Expr,
  out_n: Int,
  carried: List(Int),
  below: List(ir.Value),
  rest: List(ast.Instr),
  counter: Int,
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  let if_expr = ir.If(cond, result_types, then_expr, else_expr)
  let construct = case
    expr_breaks_to(then_expr, label) || expr_breaks_to(else_expr, label)
  {
    True -> ir.Block(label, result_types, if_expr)
    False -> if_expr
  }
  finish_construct(
    construct,
    result_types,
    out_n,
    carried,
    below,
    rest,
    counter,
    ctx,
    st,
  )
}

/// True if `expr` contains a `Break(label, _)` — a `br` resolved to this `label`. Labels
/// are unique within a function (fresh-generated), so there is no shadowing and a plain
/// recursive scan over the structured sub-expressions is exact. Used by `finish_if` to
/// decide whether a WASM `if` needs an `ir.Block` wrapper to host its label.
fn expr_breaks_to(expr: ir.Expr, label: String) -> Bool {
  case expr {
    ir.Break(l, _) -> l == label
    ir.Let(_, rhs, body) ->
      expr_breaks_to(rhs, label) || expr_breaks_to(body, label)
    ir.If(_, _, t, e) -> expr_breaks_to(t, label) || expr_breaks_to(e, label)
    ir.Switch(_, _, arms, default) ->
      list.any(arms, fn(a) {
        let ir.SwitchArm(_, b) = a
        expr_breaks_to(b, label)
      })
      || expr_breaks_to(default, label)
    ir.Block(_, _, body) -> expr_breaks_to(body, label)
    ir.Loop(_, _, _, body) -> expr_breaks_to(body, label)
    ir.Charge(_, body) -> expr_breaks_to(body, label)
    // A `Try` region's body and every handler are sub-expressions a `Break` may live in
    // (Phase 7) — recurse so an outer construct detects a break resolved to its label.
    ir.Try(_, body, handlers) ->
      expr_breaks_to(body, label)
      || list.any(handlers, fn(h) { expr_breaks_to(h.handler, label) })
    _ -> False
  }
}

/// Bind a construct's `out_arity` stack results and its carried locals to fresh names,
/// restore the operand stack beneath it, rebind the carried locals, and lower the
/// instructions after the construct — wrapping the whole thing in a `Let`. `result_types`
/// is the construct's IR result type list (`out` types ++ carried-local types, matching
/// `res_names` 1:1); each fresh result/carried name is recorded with its type so a later
/// `select` can recover an operand's type.
fn finish_construct(
  construct: ir.Expr,
  result_types: List(ir.ValType),
  out_n: Int,
  carried: List(Int),
  below: List(ir.Value),
  rest: List(ast.Instr),
  counter: Int,
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  let #(res_names, c) = fresh_n(counter, out_n + list.length(carried))
  let res_vars = list.map(res_names, ir.Var)
  let out_vars = list.take(res_vars, out_n)
  let carried_names = list.drop(res_names, out_n)
  let new_stack = list.append(list.reverse(out_vars), below)
  let new_locals = update_locals(st.locals, carried, carried_names)
  let new_var_types =
    insert_types(st.var_types, list.zip(res_names, result_types))
  let st_parent =
    LState(
      stack: new_stack,
      locals: new_locals,
      counter: c,
      frames: st.frames,
      var_types: new_var_types,
    )
  use cont <- result.try(go(rest, ctx, st_parent))
  Ok(wrap_let(res_names, construct, cont))
}

/// Lower `br_if l`: an `If` whose then-arm is the branch transfer and whose else-arm is
/// the rest of the current body (the branch operands stay on the stack for the
/// fall-through path, per WASM semantics).
fn lower_br_if(
  l: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(cond, stack1) <- result.try(pop1(st.stack))
  let st_nocond = LState(..st, stack: stack1)
  use transfer <- result.try(build_transfer(l, st_nocond))
  use cur <- result.try(current_frame(st))
  use inner <- result.try(go(tail, ctx, st_nocond))
  case inner {
    GEnd(e, rest, c) ->
      Ok(GEnd(ir.If(cond, cur.result_types, transfer, e), rest, c))
    GElse(e, rest, c) ->
      Ok(GElse(ir.If(cond, cur.result_types, transfer, e), rest, c))
  }
}

/// Lower `br_table`: a `Switch` on the i32 selector. Arm `i` branches to `targets[i]`,
/// the default to `default`. Each branch resolves its target frame's named label and
/// carried locals; the dead tail after the (unconditional) table is skipped.
fn lower_br_table(
  targets: List(Int),
  default: Int,
  tail: List(ast.Instr),
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(sel, stack1) <- result.try(pop1(st.stack))
  let st_nosel = LState(..st, stack: stack1)
  use default_t <- result.try(build_transfer(default, st_nosel))
  use arms <- result.try(
    list.index_map(targets, fn(t, i) {
      case build_transfer(t, st_nosel) {
        Ok(tr) -> Ok(ir.SwitchArm(i, tr))
        Error(e) -> Error(e)
      }
    })
    |> result.all,
  )
  use cur <- result.try(current_frame(st))
  let switch = ir.Switch(sel, cur.result_types, arms, default_t)
  use #(marker, rest) <- result.try(consume_dead(tail, 0))
  Ok(end_or_else(marker, switch, rest, st.counter))
}

/// Build the named-label transfer for a `br` to relative depth `l`: `Continue` to a
/// `loop`, `Return` from the function frame, or `Break` to a `block`/`if`. The carried
/// values are the top `branch_arity` operands (in push order) followed by the target
/// frame's carried locals' current values.
fn build_transfer(l: Int, st: LState) -> Result(ir.Expr, LowerError) {
  use frame <- result.try(nth_err(
    st.frames,
    l,
    Malformed("branch label out of range"),
  ))
  let stack_vals = take_push_order(st.stack, frame.branch_arity)
  use carried_v <- result.try(get_locals(st, frame.carried))
  let vals = list.append(stack_vals, carried_v)
  case frame.kind {
    FLoop -> Ok(ir.Continue(frame.label, vals))
    FFunc -> Ok(ir.Return(stack_vals))
    _ -> Ok(ir.Break(frame.label, vals))
  }
}

/// The current frame's fall-through expression: forward the top `out_arity` operands
/// (push order) and the carried locals' current values as the construct's result.
fn fallthrough(cur: LFrame, st: LState) -> Result(ir.Expr, LowerError) {
  let stack_vals = take_push_order(st.stack, cur.out_arity)
  use carried_v <- result.try(get_locals(st, cur.carried))
  Ok(ir.Values(list.append(stack_vals, carried_v)))
}

// ───────────────────── exception-handling lowering (Phase 7, T1/T2) ─────────────────────
//
// BOTH wire encodings structure into the ONE inline-handler `ir.Try(result, body,
// handlers)` (T1): the LEGACY `try…catch…end` maps 1:1 (the inline handler `H` is the
// `CatchHandler.handler` expression, the tag operands bound to fresh `payload` names); the
// MODERN `try_table catch* … end` maps each label-branch clause to a `CatchHandler` whose
// `handler` is the TRANSFER to the resolved enclosing frame (`Break`/`Continue`/`Return`),
// so lower picks the transfer from the target frame kind (resolving M4 without a scope
// limit). lower installs no runtime handler and raises nothing — the Core Erlang
// `try…catch` + the `{wasm_exn,…}` term shape + the tag match/payload binding/re-raise are
// emit_core (P7-06) + rt_exn (P7-07)'s.

/// Lower `throw x` → `ir.Throw(tagname(x), args)` (a BOTTOM transfer, spec §control `throw`:
/// the rest of the block is unreachable). Pops the tag's operands (deepest-first, i.e.
/// tag-param order) recovered from `ctx.tag_types`, builds the node, then consumes the
/// unreachable tail to the frame's closing marker — exactly like `Return`/`Unreachable`.
/// `Error(UnknownTagIndex(x))` on an out-of-range tagidx, `Error(StackUnderflow)` on an
/// under-deep stack (both only reachable on an unvalidated module).
fn lower_throw(
  x: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use operands <- result.try(nth_err(ctx.tag_types, x, UnknownTagIndex(x)))
  let pcount = list.length(operands)
  let args = take_push_order(st.stack, pcount)
  case list.length(args) == pcount {
    False -> Error(StackUnderflow)
    True -> {
      use #(marker, rest) <- result.try(consume_dead(tail, 0))
      Ok(end_or_else(marker, ir.Throw(tagname(x), args), rest, st.counter))
    }
  }
}

/// Lower `throw_ref` → `ir.ThrowRef(exnref)` — re-raise the exception the top-of-stack
/// `exnref` handle refers to. A BOTTOM transfer (spec §control `throw_ref`); lower forwards
/// the `exnref` value unchanged — the null-exnref trap + the re-raise are rt_exn's (P7-07).
/// Pops one value, builds the node, consumes the dead tail. `Error(StackUnderflow)` on an
/// empty stack.
fn lower_throw_ref(
  tail: List(ast.Instr),
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(exnref, _stack1) <- result.try(pop1(st.stack))
  use #(marker, rest) <- result.try(consume_dead(tail, 0))
  Ok(end_or_else(marker, ir.ThrowRef(exnref), rest, st.counter))
}

/// Lower a legacy `rethrow l` → `ir.ThrowRef(Var(e))` re-raising the exception captured by
/// the enclosing legacy catch handler (T1: `rethrow` is the legacy analogue of `throw_ref`).
/// `e` is the innermost active handler's captured `exnref` name (`ctx.catch_refs` head — the
/// handler that lexically encloses the `rethrow` always captures, since it contains one). A
/// BOTTOM transfer, so the dead tail is consumed. The label `l` (which selects WHICH
/// enclosing handler) is currently approximated to the innermost — precise `l > 0` routing
/// is deferred (a documented deviation; Porffor emits no `rethrow`). `Error(Malformed)` if
/// no handler is active (a `rethrow` outside any handler — validate rejects it upstream).
fn lower_rethrow(
  _l: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  case ctx.catch_refs {
    [e, ..] -> {
      use #(marker, rest) <- result.try(consume_dead(tail, 0))
      Ok(end_or_else(marker, ir.ThrowRef(ir.Var(e)), rest, st.counter))
    }
    [] -> Error(Malformed("rethrow outside a catch handler"))
  }
}

// ── legacy `try…catch…end` structuring ──

/// The kind of a legacy in-stream handler section: `catch x` (matches tag `x`) or
/// `catch_all` (matches any exception).
type LegacyKind {
  LKCatch(tag: Int)
  LKCatchAll
}

/// How a legacy `try` region is terminated: a plain `end`, or a `delegate l` that closes
/// the `try` and forwards uncaught exceptions to the enclosing region (label `l`).
type LegacyTerm {
  LTEnd
  LTDelegate(label: Int)
}

/// Lower a legacy `try bt B (catch x Hₓ | catch_all Hₐ)* end` (or `try bt B delegate l`)
/// into the one inline-handler `ir.Try` (T1). It structures the flat stream exactly as
/// `lower_block`/`lower_if` do — a labelled block whose body AND every handler are
/// alternatives yielding the try's result — resolving the interspersed `catch`/`catch_all`/
/// `delegate` markers by SPLITTING the stream first (`split_legacy_try`), then lowering each
/// segment (body + handlers) as its own block-body.
///
/// The IR produced: `Try(result_types, lower(B), [CatchHandler(OnTag(tagname(x)), names,
/// None, lower(Hₓ)) | CatchHandler(OnAll, [], None, lower(Hₐ))])`, where each handler's
/// `names` are fresh bindings for the tag's operands the handler consumes off its incoming
/// stack (spec: legacy `catch x` pushes the tag operands; `catch_all` pushes nothing). A
/// `delegate l` becomes a single `CatchHandler(OnAll, [], Some(e), ThrowRef(Var(e)))` —
/// catch-and-re-raise, forwarding to the enclosing region (§A.4).
///
/// `result_types` = blocktype results ++ the construct's carried locals (locals assigned
/// anywhere in the body or a handler, threaded out as extra results — the block discipline).
/// A handler runs with `locals` as of the try SITE (the SSA names in scope there) — the
/// pragmatic resolution of the "WASM locals persist across a throw but 2core threads them as
/// SSA" seam (§D); precise per-throw-point local values are 01/06's to refine. The whole
/// `Try` is wrapped in `ir.Block(label, …)` only when the body or a handler `br`s to the
/// try's own label (arity-transparent, exactly like `finish_if`).
fn lower_try_legacy(
  bt: ast.BlockType,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(in_ir, out_ir) <- result.try(blocktype_io(bt, ctx))
  let in_n = list.length(in_ir)
  let out_n = list.length(out_ir)
  // Carried locals span the WHOLE construct (body + every handler), so the body's and each
  // handler's fall-through agree on the result shape (like an `if`'s two arms).
  let carried = scan_modified(tail, 0, set.new())
  use carried_ts <- result.try(carried_types(carried, ctx.local_types))
  let result_types = list.append(out_ir, carried_ts)

  use #(segments, term, rest) <- result.try(split_legacy_try(tail))
  use #(body_seg, handler_segs) <- result.try(case segments {
    [#(None, body), ..hs] -> Ok(#(body, hs))
    _ -> Error(Malformed("legacy try without a body segment"))
  })

  // Lower the body under the try's own block-like frame (its label hosts a `br` out).
  let inner_stack = list.take(st.stack, in_n)
  let below = list.drop(st.stack, in_n)
  let #(label, c1) = fresh_label(st.counter)
  let frame = LFrame(label, FBlock, out_n, out_n, result_types, carried)
  let child =
    LState(inner_stack, st.locals, c1, [frame, ..st.frames], st.var_types)
  use body_res <- result.try(go(list.append(body_seg, [ast.End]), ctx, child))
  use #(body_expr, _, c2) <- result.try(expect_end(body_res))

  // Handlers (or, for `delegate`, one catch-all re-raise).
  use #(handlers, c3) <- result.try(case term {
    LTEnd -> lower_legacy_handlers(handler_segs, frame, ctx, st, c2)
    LTDelegate(_l) -> {
      let #(e, c_d) = fresh(c2)
      Ok(#(
        [ir.CatchHandler(ir.OnAll, [], Some(e), ir.ThrowRef(ir.Var(e)))],
        c_d,
      ))
    }
  })

  let node = ir.Try(result_types, body_expr, handlers)
  let breaks =
    expr_breaks_to(body_expr, label)
    || list.any(handlers, fn(h) { expr_breaks_to(h.handler, label) })
  let construct = case breaks {
    True -> ir.Block(label, result_types, node)
    False -> node
  }
  finish_construct(
    construct,
    result_types,
    out_n,
    carried,
    below,
    rest,
    c3,
    ctx,
    st,
  )
}

/// Split a legacy `try` region's flat stream (the instructions AFTER the `try` opener) into
/// its body + handler segments, its terminator, and the instructions after it. Walks with a
/// nesting `depth` (openers `block`/`loop`/`if`/`try`/`try_table` +1; `end` and `delegate`
/// −1) so only the try's OWN depth-0 `catch`/`catch_all`/`end`/`delegate` markers split it.
///
/// Returns `#(segments, term, rest)` where `segments` is `[#(None, body), #(Some(kind),
/// handler)…]` — the first segment (marker `None`) is the try body, each following segment
/// is a handler tagged with its `LegacyKind` — `term` is `LTEnd` | `LTDelegate(l)`, and
/// `rest` is the stream after the construct. `Error(Malformed)` if the stream ends before a
/// depth-0 `end`/`delegate` closes the try.
fn split_legacy_try(
  instrs: List(ast.Instr),
) -> Result(
  #(List(#(Option(LegacyKind), List(ast.Instr))), LegacyTerm, List(ast.Instr)),
  LowerError,
) {
  do_split_legacy(instrs, 0, None, [], [])
}

/// The `split_legacy_try` accumulator loop. `depth` is the nesting depth; `cur_kind`/
/// `cur_rev` are the current segment's leading marker + its instructions (reversed);
/// `finished` is the completed segments (most-recent first). On a depth-0 `catch`/
/// `catch_all` the current segment closes and a new handler segment opens; on a depth-0
/// `end`/`delegate` the construct closes.
fn do_split_legacy(
  instrs: List(ast.Instr),
  depth: Int,
  cur_kind: Option(LegacyKind),
  cur_rev: List(ast.Instr),
  finished: List(#(Option(LegacyKind), List(ast.Instr))),
) -> Result(
  #(List(#(Option(LegacyKind), List(ast.Instr))), LegacyTerm, List(ast.Instr)),
  LowerError,
) {
  case instrs {
    [] -> Error(Malformed("unterminated legacy try region"))
    [i, ..t] ->
      case i, depth {
        ast.Block(_), _
        | ast.Loop(_), _
        | ast.If(_), _
        | ast.TryLegacy(_), _
        | ast.TryTable(_, _), _
        -> do_split_legacy(t, depth + 1, cur_kind, [i, ..cur_rev], finished)
        ast.End, 0 ->
          Ok(#(close_segment(cur_kind, cur_rev, finished), LTEnd, t))
        ast.End, _ ->
          do_split_legacy(t, depth - 1, cur_kind, [i, ..cur_rev], finished)
        ast.LegacyDelegate(l), 0 ->
          Ok(#(close_segment(cur_kind, cur_rev, finished), LTDelegate(l), t))
        ast.LegacyDelegate(_), _ ->
          do_split_legacy(t, depth - 1, cur_kind, [i, ..cur_rev], finished)
        ast.LegacyCatch(x), 0 ->
          do_split_legacy(t, 0, Some(LKCatch(x)), [], [
            #(cur_kind, list.reverse(cur_rev)),
            ..finished
          ])
        ast.LegacyCatchAll, 0 ->
          do_split_legacy(t, 0, Some(LKCatchAll), [], [
            #(cur_kind, list.reverse(cur_rev)),
            ..finished
          ])
        _, _ -> do_split_legacy(t, depth, cur_kind, [i, ..cur_rev], finished)
      }
  }
}

/// Close the current segment (reversing its accumulated instructions) and append it to
/// `finished`, returning the full segment list in SOURCE order (body first, handlers after).
fn close_segment(
  cur_kind: Option(LegacyKind),
  cur_rev: List(ast.Instr),
  finished: List(#(Option(LegacyKind), List(ast.Instr))),
) -> List(#(Option(LegacyKind), List(ast.Instr))) {
  list.reverse([#(cur_kind, list.reverse(cur_rev)), ..finished])
}

/// Lower each legacy handler segment to a `CatchHandler`, threading the gensym `counter`.
/// A malformed segment (a handler without a `catch`/`catch_all` marker) fails closed.
fn lower_legacy_handlers(
  segs: List(#(Option(LegacyKind), List(ast.Instr))),
  frame: LFrame,
  ctx: LCtx,
  st: LState,
  counter: Int,
) -> Result(#(List(ir.CatchHandler), Int), LowerError) {
  case segs {
    [] -> Ok(#([], counter))
    [#(Some(kind), seg), ..rest_segs] -> {
      use #(h, c1) <- result.try(lower_one_legacy_handler(
        kind,
        seg,
        frame,
        ctx,
        st,
        counter,
      ))
      use #(hs, c2) <- result.try(lower_legacy_handlers(
        rest_segs,
        frame,
        ctx,
        st,
        c1,
      ))
      Ok(#([h, ..hs], c2))
    }
    [#(None, _), ..] ->
      Error(Malformed("legacy handler segment without a catch marker"))
  }
}

/// Lower one legacy handler segment `H` to a `CatchHandler`. The handler runs under the
/// try's own block frame (`frame` — so a `br 0` in `H` exits the try), starting with the
/// tag's operands on its incoming stack (bound to fresh `payload` names; `catch_all` starts
/// empty), and `locals` as of the try site. `on` = `OnTag(tagname(x))` for `catch x`,
/// `OnAll` for `catch_all`. An `exnref` is captured (and threaded into `ctx.catch_refs`) IFF
/// the handler contains a `rethrow` that would reference it — otherwise `None`, matching the
/// common legacy shape (T1). `Error(UnknownTagIndex)` on an out-of-range tag.
fn lower_one_legacy_handler(
  kind: LegacyKind,
  seg: List(ast.Instr),
  frame: LFrame,
  ctx: LCtx,
  st: LState,
  counter: Int,
) -> Result(#(ir.CatchHandler, Int), LowerError) {
  use #(on, payload_types) <- result.try(case kind {
    LKCatch(x) -> {
      use ops <- result.try(nth_err(ctx.tag_types, x, UnknownTagIndex(x)))
      Ok(#(ir.OnTag(tagname(x)), ops))
    }
    LKCatchAll -> Ok(#(ir.OnAll, []))
  })
  let pcount = list.length(payload_types)
  let #(payload_names, c1) = fresh_n(counter, pcount)
  // Capture an `exnref` only if the handler contains a `rethrow` (which re-raises the caught
  // exception) — keeping the common no-rethrow handler `exnref = None` (T1).
  let #(exnref_opt, c2, child_catch_refs) = case seg_has_rethrow(seg) {
    True -> {
      let #(e, c) = fresh(c1)
      #(Some(e), c, [e, ..ctx.catch_refs])
    }
    False -> #(None, c1, ctx.catch_refs)
  }
  // The handler's incoming stack is the tag operands (top = last operand, push order).
  let payload_vars = list.map(payload_names, ir.Var)
  let inner_stack = list.reverse(payload_vars)
  let vt1 = insert_types(st.var_types, list.zip(payload_names, payload_types))
  let vt2 = case exnref_opt {
    Some(e) -> insert_types(vt1, [#(e, ir.TExnRef)])
    None -> vt1
  }
  let hctx = LCtx(..ctx, catch_refs: child_catch_refs)
  let child = LState(inner_stack, st.locals, c2, [frame, ..st.frames], vt2)
  use hres <- result.try(go(list.append(seg, [ast.End]), hctx, child))
  use #(hexpr, _, c3) <- result.try(expect_end(hres))
  Ok(#(ir.CatchHandler(on, payload_names, exnref_opt, hexpr), c3))
}

/// Whether a legacy handler segment (a flat instruction list) contains a `rethrow` — the
/// signal that the handler must capture an `exnref` so `lower_rethrow` can re-raise it.
fn seg_has_rethrow(seg: List(ast.Instr)) -> Bool {
  list.any(seg, fn(i) {
    case i {
      ast.Rethrow(_) -> True
      _ -> False
    }
  })
}

// ── modern `try_table` structuring ──

/// Lower a modern `try_table bt catch* B end` into the one inline-handler `ir.Try` (T1). The
/// body `B` is lowered under the try_table's OWN block-like frame (exactly like `lower_block`
/// — its label hosts a `br` out of the try_table), and each catch clause becomes a
/// `CatchHandler` whose `handler` is the TRANSFER to the clause's target label, resolved in
/// the ENCLOSING context (`st.frames`, BEFORE the body frame is pushed — spec typing) to the
/// enclosing frame's kind: `Break` for a block/if, `Continue` for a loop, `Return` for the
/// function frame. The payload (the tag operands, plus the `exnref` for a `_ref` clause) is
/// delivered as the transfer's branch values. `result_types` = blocktype results ++ carried
/// locals (the body's normal-completion result). The `Try` is `Block`-wrapped only when `B`
/// `br`s to the try_table's own label (catches target ENCLOSING labels, never this one).
fn lower_try_table(
  bt: ast.BlockType,
  catches: List(ast.Catch),
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(in_ir, out_ir) <- result.try(blocktype_io(bt, ctx))
  let in_n = list.length(in_ir)
  let out_n = list.length(out_ir)
  let carried = scan_modified(tail, 0, set.new())
  use carried_ts <- result.try(carried_types(carried, ctx.local_types))
  let result_types = list.append(out_ir, carried_ts)

  // Resolve every catch clause against the ENCLOSING frames (the parent context).
  use #(handlers, c_h) <- result.try(lower_trytable_catches(
    catches,
    ctx,
    st,
    st.counter,
  ))

  // Lower the body under the try_table's own block-like frame (like `lower_block`).
  let inner_stack = list.take(st.stack, in_n)
  let below = list.drop(st.stack, in_n)
  let #(label, c1) = fresh_label(c_h)
  let frame = LFrame(label, FBlock, out_n, out_n, result_types, carried)
  let child =
    LState(inner_stack, st.locals, c1, [frame, ..st.frames], st.var_types)
  use body_res <- result.try(go(tail, ctx, child))
  use #(body_expr, rest, c2) <- result.try(expect_end(body_res))

  let node = ir.Try(result_types, body_expr, handlers)
  let construct = case expr_breaks_to(body_expr, label) {
    True -> ir.Block(label, result_types, node)
    False -> node
  }
  finish_construct(
    construct,
    result_types,
    out_n,
    carried,
    below,
    rest,
    c2,
    ctx,
    st,
  )
}

/// Lower every `try_table` catch clause to a `CatchHandler`, threading the gensym `counter`.
fn lower_trytable_catches(
  catches: List(ast.Catch),
  ctx: LCtx,
  st: LState,
  counter: Int,
) -> Result(#(List(ir.CatchHandler), Int), LowerError) {
  case catches {
    [] -> Ok(#([], counter))
    [c, ..rest] -> {
      use #(h, c1) <- result.try(lower_one_trytable_catch(c, ctx, st, counter))
      use #(hs, c2) <- result.try(lower_trytable_catches(rest, ctx, st, c1))
      Ok(#([h, ..hs], c2))
    }
  }
}

/// Lower one `try_table` catch clause to a `CatchHandler(on, payload, exnref?, transfer)`.
/// The four clause kinds map exactly: `catch x l` → `OnTag(tagname(x))`, no exnref;
/// `catch_ref x l` → `OnTag`, an exnref; `catch_all l` → `OnAll`, no exnref; `catch_all_ref
/// l` → `OnAll`, an exnref. The `payload` names bind the tag operands (empty for `catch_all`);
/// the `transfer` delivers `[payload (++ exnref)]` to the enclosing label `l` — built by
/// `build_transfer` over a synthetic stack of exactly those values, so it picks
/// `Break`/`Continue`/`Return` from the resolved frame's kind and appends that frame's
/// carried locals (as of the try site). `Error(UnknownTagIndex)` / `Error(Malformed)` on an
/// out-of-range tag / label (only on an unvalidated module).
fn lower_one_trytable_catch(
  c: ast.Catch,
  ctx: LCtx,
  st: LState,
  counter: Int,
) -> Result(#(ir.CatchHandler, Int), LowerError) {
  use #(on, payload_types, capture, l) <- result.try(case c {
    ast.Catch(x, l) -> {
      use ops <- result.try(nth_err(ctx.tag_types, x, UnknownTagIndex(x)))
      Ok(#(ir.OnTag(tagname(x)), ops, False, l))
    }
    ast.CatchRef(x, l) -> {
      use ops <- result.try(nth_err(ctx.tag_types, x, UnknownTagIndex(x)))
      Ok(#(ir.OnTag(tagname(x)), ops, True, l))
    }
    ast.CatchAll(l) -> Ok(#(ir.OnAll, [], False, l))
    ast.CatchAllRef(l) -> Ok(#(ir.OnAll, [], True, l))
  })
  let pcount = list.length(payload_types)
  let #(payload_names, c1) = fresh_n(counter, pcount)
  let #(exnref_opt, c2) = case capture {
    True -> {
      let #(e, c) = fresh(c1)
      #(Some(e), c)
    }
    False -> #(None, c1)
  }
  let payload_vars = list.map(payload_names, ir.Var)
  let delivered = case exnref_opt {
    Some(e) -> list.append(payload_vars, [ir.Var(e)])
    None -> payload_vars
  }
  // Deliver the payload (+exnref) as a `br l` at the try_table site: a synthetic stack of
  // exactly those values (validate proved `l`'s arity matches) resolves the transfer against
  // the enclosing frames + that frame's carried locals.
  use transfer <- result.try(build_transfer(
    l,
    LState(..st, stack: list.reverse(delivered)),
  ))
  Ok(#(ir.CatchHandler(on, payload_names, exnref_opt, transfer), c2))
}

// ─────────────────────────────── small helpers ───────────────────────────────

/// The current (innermost) control frame, or `Error` if the frame stack is empty.
fn current_frame(st: LState) -> Result(LFrame, LowerError) {
  case st.frames {
    [f, ..] -> Ok(f)
    [] -> Error(Malformed("no enclosing control frame"))
  }
}

/// `GEnd`/`GElse` selected by the closing marker (`end`/`else`) — used after an
/// unconditional transfer skips the dead tail.
fn end_or_else(
  marker: ast.Instr,
  expr: ir.Expr,
  rest: List(ast.Instr),
  counter: Int,
) -> GoResult {
  case marker {
    ast.Else -> GElse(expr, rest, counter)
    _ -> GEnd(expr, rest, counter)
  }
}

/// Require a `GoResult` that closed on `end` (a `block`/`loop`/function body must not be
/// closed by a stray `else`).
fn expect_end(
  gr: GoResult,
) -> Result(#(ir.Expr, List(ast.Instr), Int), LowerError) {
  case gr {
    GEnd(e, rest, c) -> Ok(#(e, rest, c))
    GElse(_, _, _) -> Error(Malformed("else without matching if"))
  }
}

/// Push a value onto the abstract operand stack.
fn push(st: LState, v: ir.Value) -> LState {
  LState(..st, stack: [v, ..st.stack])
}

/// Pop one value off the operand stack, or `Error(StackUnderflow)`.
fn pop1(
  stack: List(ir.Value),
) -> Result(#(ir.Value, List(ir.Value)), LowerError) {
  case stack {
    [v, ..rest] -> Ok(#(v, rest))
    [] -> Error(StackUnderflow)
  }
}

/// The top `n` operands in PUSH order (deepest first). Reads without modifying.
fn take_push_order(stack: List(ir.Value), n: Int) -> List(ir.Value) {
  list.reverse(list.take(stack, n))
}

/// The current SSA value of local `i`, or `Error(UnknownLocalIndex(i))`.
fn get_local(st: LState, i: Int) -> Result(ir.Value, LowerError) {
  case dict.get(st.locals, i) {
    Ok(v) -> Ok(v)
    Error(_) -> Error(UnknownLocalIndex(i))
  }
}

/// The current SSA values of `indices`, in order.
fn get_locals(
  st: LState,
  indices: List(Int),
) -> Result(List(ir.Value), LowerError) {
  list.try_map(indices, fn(i) { get_local(st, i) })
}

/// Rebind each local in `indices` to a fresh `Var(name)` (zipped pairwise).
fn update_locals(
  locals: Dict(Int, ir.Value),
  indices: List(Int),
  names: List(String),
) -> Dict(Int, ir.Value) {
  list.zip(indices, names)
  |> list.fold(locals, fn(acc, pair) {
    let #(i, name) = pair
    dict.insert(acc, i, ir.Var(name))
  })
}

/// The IR types of carried locals, or `Error(UnknownLocalIndex)` if any is out of range.
fn carried_types(
  carried: List(Int),
  local_types: List(ir.ValType),
) -> Result(List(ir.ValType), LowerError) {
  list.try_map(carried, fn(i) { nth_err(local_types, i, UnknownLocalIndex(i)) })
}

/// Build `LoopParam`s by zipping names, types, and initial values.
fn zip3_loop_params(
  names: List(String),
  types: List(ir.ValType),
  inits: List(ir.Value),
) -> List(ir.LoopParam) {
  list.zip(names, list.zip(types, inits))
  |> list.map(fn(triple) {
    let #(name, #(ty, init)) = triple
    ir.LoopParam(name, ty, init)
  })
}

/// Wrap a `Let([names], rhs, _)` around a `GoResult`'s expression (preserving its kind).
fn wrap_let(names: List(String), rhs: ir.Expr, gr: GoResult) -> GoResult {
  case gr {
    GEnd(e, rest, c) -> GEnd(ir.Let(names, rhs, e), rest, c)
    GElse(e, rest, c) -> GElse(ir.Let(names, rhs, e), rest, c)
  }
}

/// Skip the unreachable tail after an unconditional transfer until the marker that
/// closes the current frame: the `end` at depth 0, or an `else` at depth 0 (closing an
/// `if` then-branch). Nested `block`/`loop`/`if` are balanced via `depth`.
fn consume_dead(
  instrs: List(ast.Instr),
  depth: Int,
) -> Result(#(ast.Instr, List(ast.Instr)), LowerError) {
  case instrs {
    [] -> Error(Malformed("unterminated dead code"))
    [ast.Block(_), ..t] -> consume_dead(t, depth + 1)
    [ast.Loop(_), ..t] -> consume_dead(t, depth + 1)
    [ast.If(_), ..t] -> consume_dead(t, depth + 1)
    // Phase-7 EH block-openers: `try`/`try_table` open like `block` (depth +1); `delegate`
    // CLOSES an enclosing `try` (depth −1, like `end`), so a nested `try…delegate` in dead
    // code balances. (`catch`/`catch_all` are in-block markers — no depth change; they fall
    // to the default skip.)
    [ast.TryLegacy(_), ..t] -> consume_dead(t, depth + 1)
    [ast.TryTable(_, _), ..t] -> consume_dead(t, depth + 1)
    [ast.LegacyDelegate(l), ..t] ->
      case depth {
        0 -> Ok(#(ast.LegacyDelegate(l), t))
        _ -> consume_dead(t, depth - 1)
      }
    [ast.Else, ..t] ->
      case depth {
        0 -> Ok(#(ast.Else, t))
        _ -> consume_dead(t, depth)
      }
    [ast.End, ..t] ->
      case depth {
        0 -> Ok(#(ast.End, t))
        _ -> consume_dead(t, depth - 1)
      }
    [_, ..t] -> consume_dead(t, depth)
  }
}

/// The set of local indices assigned (`local.set`/`local.tee`) anywhere within the
/// current construct's body — scanned until the matching `end` (depth 0), crossing an
/// `else` for an `if`. Returned ascending (deterministic carried-local order).
fn scan_modified(
  instrs: List(ast.Instr),
  depth: Int,
  acc: set.Set(Int),
) -> List(Int) {
  case instrs {
    [] -> set_to_sorted(acc)
    [ast.Block(_), ..t] -> scan_modified(t, depth + 1, acc)
    [ast.Loop(_), ..t] -> scan_modified(t, depth + 1, acc)
    [ast.If(_), ..t] -> scan_modified(t, depth + 1, acc)
    // Phase-7 EH openers/closers: `try`/`try_table` open like `block`; `delegate` closes an
    // enclosing `try` (like `end`); `catch`/`catch_all` are in-block markers (like `else` —
    // no depth change), so a legacy try's whole body+handlers is scanned in one pass.
    [ast.TryLegacy(_), ..t] -> scan_modified(t, depth + 1, acc)
    [ast.TryTable(_, _), ..t] -> scan_modified(t, depth + 1, acc)
    [ast.LegacyDelegate(_), ..t] ->
      case depth {
        0 -> set_to_sorted(acc)
        _ -> scan_modified(t, depth - 1, acc)
      }
    [ast.End, ..t] ->
      case depth {
        0 -> set_to_sorted(acc)
        _ -> scan_modified(t, depth - 1, acc)
      }
    [ast.Else, ..t] -> scan_modified(t, depth, acc)
    [ast.LegacyCatch(_), ..t] -> scan_modified(t, depth, acc)
    [ast.LegacyCatchAll, ..t] -> scan_modified(t, depth, acc)
    [ast.LocalSet(i), ..t] -> scan_modified(t, depth, set.insert(acc, i))
    [ast.LocalTee(i), ..t] -> scan_modified(t, depth, set.insert(acc, i))
    [_, ..t] -> scan_modified(t, depth, acc)
  }
}

/// A set of ints as an ascending list.
fn set_to_sorted(s: set.Set(Int)) -> List(Int) {
  set.to_list(s) |> list.sort(int.compare)
}

// ───────────────────── lever 5: liveness narrowing of the carried-local set ─────────────────────
//
// `scan_modified` over-approximates a block/loop/if's carried locals as EVERY local set/tee'd
// inside it. Under `narrow_carried` we intersect that with the locals actually LIVE at the
// construct's exit, computed by a SOUND structured backward liveness pass (`live_of`). The pass may
// only ever REMOVE a local it can prove dead — on any uncertainty it keeps the local. Enabled only
// for functions with no exception-handling / GC-typed branch (`is_narrowable`), whose control flow
// the pass models exactly; every other function threads the full `scan_modified` set unchanged.

/// `True` iff `instrs` (a whole function body) contains NO instruction the backward liveness pass
/// declines to model: exception handling (`throw`/`throw_ref`/`rethrow`/`try*`/legacy catch/delegate)
/// or a GC-typed branch (`br_on_null`/`br_on_non_null`/`br_on_cast`/`br_on_cast_fail`). Their control
/// flow (a throw reaching a handler that may read locals; a ref-typed conditional edge) is outside the
/// pass's model, so a body containing any of them is NOT narrowed — it threads the full over-
/// approximated carried set (sound). Every other instruction either touches no local and falls through
/// (transparent to local liveness) or is one of the modeled control instructions (`live_of`).
fn is_narrowable(instrs: List(ast.Instr)) -> Bool {
  case instrs {
    [] -> True
    [i, ..t] ->
      case i {
        ast.Throw(_)
        | ast.ThrowRef
        | ast.Rethrow(_)
        | ast.TryLegacy(_)
        | ast.TryTable(_, _)
        | ast.LegacyCatch(_)
        | ast.LegacyCatchAll
        | ast.LegacyDelegate(_)
        | ast.BrOnNull(_)
        | ast.BrOnNonNull(_)
        | ast.BrOnCast(_, _, _)
        | ast.BrOnCastFail(_, _, _) -> False
        _ -> is_narrowable(t)
      }
  }
}

/// The set `{0, 1, …, n-1}` — the conservative "all locals" fallback.
fn set_range(n: Int) -> set.Set(Int) {
  set_range_go(0, n, set.new())
}

fn set_range_go(i: Int, n: Int, acc: set.Set(Int)) -> set.Set(Int) {
  case i < n {
    True -> set_range_go(i + 1, n, set.insert(acc, i))
    False -> acc
  }
}

/// Narrow a `block`/`if`'s carried locals to those live at its exit, and produce the child `LCtx`
/// (with this construct's frame pushed onto `label_lives`) for lowering its body. A block/if's
/// carried locals are its extra RESULTS: every exit (fall-through or a `br` to it) lands at the SAME
/// merge — the code immediately after the construct — so `live_out` (that merge's live-in) is the
/// exit live set for all of them. Returns `#(narrowed_carried, body_ctx)`. When `narrow_carried` is
/// off, returns the full set and the unchanged ctx (byte-identical to a no-narrowing build).
///
/// `full_carried` is `scan_modified`'s over-approximation (ascending); the result preserves order and
/// is always a SUBSET, so downstream threading is unaffected apart from dropping provably-dead locals.
fn narrow_join_carried(
  full_carried: List(Int),
  tail: List(ast.Instr),
  ctx: LCtx,
) -> #(List(Int), LCtx) {
  case ctx.narrow_carried {
    False -> #(full_carried, ctx)
    True -> {
      let live_out =
        live_of(skip_construct(tail), ctx.label_lives, ctx.all_locals)
      let narrowed =
        list.filter(full_carried, fn(i) { set.contains(live_out, i) })
      #(
        narrowed,
        LCtx(..ctx, label_lives: [#(live_out, live_out), ..ctx.label_lives]),
      )
    }
  }
}

/// Narrow a `loop`'s carried locals, and produce the child `LCtx` for lowering its body. A loop's
/// carried locals are its loop PARAMETERS: threaded OUT on exit AND back on every `br 0` (Continue)
/// into the next iteration. So a carried local must be kept if it is live at the loop's exit
/// (`live_out`) OR at its back-edge — the loop head (`headlive`, the loop body's live-in, computed as
/// a least fixpoint so a value written this iteration and read the next is captured). Only a local
/// dead at BOTH is dropped. The pushed `label_lives` entry is `#(headlive, live_out)`: a `br 0` in
/// the body reaches the head (`headlive`), a fall-through off the body end exits the loop (`live_out`).
fn narrow_loop_carried(
  full_carried: List(Int),
  tail: List(ast.Instr),
  ctx: LCtx,
) -> #(List(Int), LCtx) {
  case ctx.narrow_carried {
    False -> #(full_carried, ctx)
    True -> {
      let live_out =
        live_of(skip_construct(tail), ctx.label_lives, ctx.all_locals)
      let head = loop_headlive(tail, live_out, ctx.label_lives, ctx.all_locals)
      let keep = set.union(live_out, head)
      let narrowed = list.filter(full_carried, fn(i) { set.contains(keep, i) })
      #(
        narrowed,
        LCtx(..ctx, label_lives: [#(head, live_out), ..ctx.label_lives]),
      )
    }
  }
}

/// The set of locals LIVE at the entry of `instrs` — a suffix of ONE control frame's body, up to and
/// including that frame's closing `end` (which the pass stops at). SOUND backward liveness: the
/// result is always a SUPERSET of the true live set (it never under-approximates), so intersecting a
/// carried set with it can only drop a PROVABLY-dead local.
///
/// - `lives`: `#(br_live, ft_live)` per enclosing frame, innermost at the head (parallel to the
///   lowering frame stack). A `br l` lands with `lives[l].br_live` live; the current frame's
///   fall-through `end`/`else` yields `lives[0].ft_live`.
/// - `all_locals`: the conservative fallback returned on any uncertainty (a body that runs off its
///   end, an out-of-range branch depth) — it contains every local, so nothing is ever dropped there.
///
/// Local liveness gen/kill lives entirely in `local.get` (gen), `local.set`/`local.tee` (kill); every
/// other non-control instruction is transparent (its stack operands' reads are their producers').
/// Unconditional transfers (`br`/`br_table`/`return`/`return_call*`/`unreachable`) make the fall-
/// through tail unreachable, so live-in is purely the target's live set. Nested `block`/`loop`/`if`
/// recurse: the sub-region's merge is the live-in of the code AFTER it; a `loop` back-edge (`br 0`)
/// targets its head, resolved by `loop_headlive`. Only ever called on `is_narrowable` bodies, so no
/// EH / GC-typed-branch instruction is reached.
fn live_of(
  instrs: List(ast.Instr),
  lives: List(#(set.Set(Int), set.Set(Int))),
  all_locals: set.Set(Int),
) -> set.Set(Int) {
  case instrs {
    // Ran off the body end without a closing `end` (only on a malformed stream) — keep all.
    [] -> all_locals
    // Frame-closing markers: fall through to this frame's fall-through live set.
    [ast.End, ..] -> ft_head(lives, all_locals)
    [ast.Else, ..] -> ft_head(lives, all_locals)

    // Locals — the ONLY gen (get) / kill (set/tee) sites.
    [ast.LocalGet(i), ..t] -> set.insert(live_of(t, lives, all_locals), i)
    [ast.LocalSet(i), ..t] -> set.delete(live_of(t, lives, all_locals), i)
    [ast.LocalTee(i), ..t] -> set.delete(live_of(t, lives, all_locals), i)

    // Unconditional transfers — the fall-through tail is unreachable, so live-in is the target's
    // live set (∅ for a bottom-exit that leaves the function via `return`/`return_call*`/`unreachable`).
    [ast.Br(l), ..] -> br_at(lives, l, all_locals)
    [ast.BrTable(targets, default), ..] ->
      list.fold(targets, br_at(lives, default, all_locals), fn(acc, tgt) {
        set.union(acc, br_at(lives, tgt, all_locals))
      })
    [ast.Return, ..] -> set.new()
    [ast.ReturnCall(_), ..] -> set.new()
    [ast.ReturnCallIndirect(_, _), ..] -> set.new()
    [ast.ReturnCallRef(_), ..] -> set.new()
    [ast.Unreachable, ..] -> set.new()

    // Conditional branch — either the target `l` or the fall-through continue.
    [ast.BrIf(l), ..t] ->
      set.union(br_at(lives, l, all_locals), live_of(t, lives, all_locals))

    // Nested structured control. A `block`/`if`'s `br 0` and fall-through both land at its merge
    // (`live_of` of the code after it); a `loop`'s `br 0` lands at its head (`loop_headlive`), its
    // fall-through at its merge. The live-in of the whole sub-region is the live-in of its body
    // (control enters the body once); an `if` unions its two arms.
    [ast.Block(_), ..body] -> {
      let merge = live_of(skip_construct(body), lives, all_locals)
      live_of(body, [#(merge, merge), ..lives], all_locals)
    }
    [ast.Loop(_), ..body] -> {
      let merge = live_of(skip_construct(body), lives, all_locals)
      loop_headlive(body, merge, lives, all_locals)
    }
    [ast.If(_), ..body] -> {
      let merge = live_of(skip_construct(body), lives, all_locals)
      let inner = [#(merge, merge), ..lives]
      let live_then = live_of(body, inner, all_locals)
      let live_else = case else_part(body) {
        option.Some(e) -> live_of(e, inner, all_locals)
        // No `else`: the synthesised arm forwards params (no local read/write), so its live-in is
        // the merge.
        option.None -> merge
      }
      set.union(live_then, live_else)
    }

    // Every other instruction touches no local and falls through (its trap/return edge, if any,
    // leaves nothing local live), so it is transparent to local liveness.
    [_, ..t] -> live_of(t, lives, all_locals)
  }
}

/// The live-in of a `loop` body accounting for its back-edge — the least fixpoint of
/// `H = live_of(body, br0 = H, ft0 = live_out)`. Iterated from `∅` upward: each step is monotone and
/// the result is bounded by `all_locals`, so it converges (equal size ⟹ equal set, since the
/// iteration only grows). `body` starts at the loop's first body instruction (its closing `end`
/// terminates `live_of` at `live_out`). On the (unreachable) fuel exhaustion, returns `all_locals`.
fn loop_headlive(
  body: List(ast.Instr),
  live_out: set.Set(Int),
  lives: List(#(set.Set(Int), set.Set(Int))),
  all_locals: set.Set(Int),
) -> set.Set(Int) {
  loop_headlive_go(
    body,
    live_out,
    lives,
    all_locals,
    set.new(),
    set.size(all_locals) + 2,
  )
}

fn loop_headlive_go(
  body: List(ast.Instr),
  live_out: set.Set(Int),
  lives: List(#(set.Set(Int), set.Set(Int))),
  all_locals: set.Set(Int),
  cur: set.Set(Int),
  fuel: Int,
) -> set.Set(Int) {
  case fuel <= 0 {
    True -> all_locals
    False -> {
      let next = live_of(body, [#(cur, live_out), ..lives], all_locals)
      case set.size(next) == set.size(cur) {
        True -> next
        False ->
          loop_headlive_go(body, live_out, lives, all_locals, next, fuel - 1)
      }
    }
  }
}

/// The instructions AFTER a construct's matching `end` (depth 0), given `instrs` starting just after
/// its opener — i.e. the construct's continuation. `else` at depth 0 is NOT a closer (an `if`'s two
/// arms are one region here); a legacy `delegate` closes its `try` like `end`. Mirrors
/// `scan_modified`'s depth bookkeeping.
fn skip_construct(instrs: List(ast.Instr)) -> List(ast.Instr) {
  skip_construct_go(instrs, 0)
}

fn skip_construct_go(instrs: List(ast.Instr), depth: Int) -> List(ast.Instr) {
  case instrs {
    [] -> []
    [ast.Block(_), ..t]
    | [ast.Loop(_), ..t]
    | [ast.If(_), ..t]
    | [ast.TryLegacy(_), ..t]
    | [ast.TryTable(_, _), ..t] -> skip_construct_go(t, depth + 1)
    [ast.LegacyDelegate(_), ..t] | [ast.End, ..t] ->
      case depth {
        0 -> t
        _ -> skip_construct_go(t, depth - 1)
      }
    [_, ..t] -> skip_construct_go(t, depth)
  }
}

/// `Some(else_instrs)` if `instrs` (starting just after an `if`'s opener) has a depth-0 `else` — the
/// instructions of the else-arm (through its `end`); `None` if the `if` closes with no `else`.
fn else_part(instrs: List(ast.Instr)) -> Option(List(ast.Instr)) {
  else_part_go(instrs, 0)
}

fn else_part_go(
  instrs: List(ast.Instr),
  depth: Int,
) -> Option(List(ast.Instr)) {
  case instrs {
    [] -> None
    [ast.Block(_), ..t]
    | [ast.Loop(_), ..t]
    | [ast.If(_), ..t]
    | [ast.TryLegacy(_), ..t]
    | [ast.TryTable(_, _), ..t] -> else_part_go(t, depth + 1)
    [ast.LegacyDelegate(_), ..t] ->
      case depth {
        0 -> None
        _ -> else_part_go(t, depth - 1)
      }
    [ast.Else, ..t] ->
      case depth {
        0 -> Some(t)
        _ -> else_part_go(t, depth)
      }
    [ast.End, ..t] ->
      case depth {
        0 -> None
        _ -> else_part_go(t, depth - 1)
      }
    [_, ..t] -> else_part_go(t, depth)
  }
}

/// The branch-target live set for a `br` at relative depth `l` (`lives[l].br_live`); the conservative
/// `all_locals` if `l` is out of range (only on a malformed/unvalidated stream — never drops a local).
fn br_at(
  lives: List(#(set.Set(Int), set.Set(Int))),
  l: Int,
  all_locals: set.Set(Int),
) -> set.Set(Int) {
  case nth_err(lives, l, StackUnderflow) {
    Ok(#(br, _ft)) -> br
    Error(_) -> all_locals
  }
}

/// The current frame's fall-through live set (`lives` head's `ft_live`); `all_locals` if `lives` is
/// empty (never, given the function frame is always present — conservative regardless).
fn ft_head(
  lives: List(#(set.Set(Int), set.Set(Int))),
  all_locals: set.Set(Int),
) -> set.Set(Int) {
  case lives {
    [#(_br, ft), ..] -> ft
    [] -> all_locals
  }
}

/// Resolve a blocktype to `#(input_types, result_types)` as IR types.
fn blocktype_io(
  bt: ast.BlockType,
  ctx: LCtx,
) -> Result(#(List(ir.ValType), List(ir.ValType)), LowerError) {
  case bt {
    ast.BlockEmpty -> Ok(#([], []))
    ast.BlockVal(t) -> Ok(#([], [to_ir_vt(t)]))
    ast.BlockTypeIdx(i) ->
      case func_type_err(ctx.types, i, UnknownTypeIndex(i)) {
        Ok(ast.FuncType(params, results)) ->
          Ok(#(list.map(params, to_ir_vt), list.map(results, to_ir_vt)))
        Error(e) -> Error(e)
      }
  }
}

/// Map a WASM value type to the IR value type. The 128-bit SIMD vector type maps to
/// `ir.TV128` (`«WASM-AST4»` ↔ `«IR4»`, 1:1 like `FuncRef`/`TFuncRef`); the two MVP
/// reference types map to the IR's reference value types (`FuncRef → TFuncRef`,
/// `ExternRef → TExternRef`). The v128 SIMD *instructions* that produce/consume a `V128`
/// remain unsupported until P6-05 (they fail closed via `Error(Unsupported(_))` in
/// `lower_numeric`); this mapping only carries the value type through function
/// signatures / locals / globals so the tree compiles green.
fn to_ir_vt(t: ast.ValType) -> ir.ValType {
  case t {
    ast.I32 -> ir.TI32
    ast.I64 -> ir.TI64
    ast.F32 -> ir.TF32
    ast.F64 -> ir.TF64
    ast.V128 -> ir.TV128
    ast.FuncRef -> ir.TFuncRef
    ast.ExternRef -> ir.TExternRef
    ast.ExnRef -> ir.TExnRef
    // A GC-proposal reference is a boxed BEAM term (an arena handle, or null).
    ast.Ref(_) -> ir.TTerm
  }
}

/// Map a WASM reference type (the `FuncRef`/`ExternRef`/`ExnRef` subset of `ast.ValType`)
/// to the IR's distinct `RefType`. `ExnRef` (Phase-7 EH — `ref.null exn`) maps 1:1 onto
/// `ir.ExnRef`, so `ref.null exn` lowers through the existing `ast.RefNull` arm to
/// `ConstNull(ExnRef)`. A non-reftype value type never appears in reftype position (validate
/// guarantees it); it defaults to `FuncRef` fail-closed so this stays total.
fn to_ir_reftype(t: ast.ValType) -> ir.RefType {
  case t {
    ast.ExternRef -> ir.ExternRef
    ast.ExnRef -> ir.ExnRef
    _ -> ir.FuncRef
  }
}

/// Map a WASM memory address-width tag to the IR `IdxType`. Both widths are live in Phase 6
/// (I4 — memory64's runtime lands): `Idx64` now flows through onto the lowered
/// `MemoryDecl`/`ImportMemory`, carrying the address width to emit_core (06) + rt_mem (08); a
/// 32-bit memory maps `Idx32` exactly as before (byte-identical).
fn to_ir_idxtype(it: ast.IdxType) -> ir.IdxType {
  case it {
    ast.Idx32 -> ir.Idx32
    ast.Idx64 -> ir.Idx64
  }
}

/// The zero value of an IR type (for declared-local initialisation). `TTerm` never
/// arises from WASM; it maps to a zero i32 defensively.
fn zero_value(t: ir.ValType) -> ir.Value {
  case t {
    ir.TI32 -> ir.ConstI32(0)
    ir.TI64 -> ir.ConstI64(0)
    ir.TF32 -> ir.ConstF32(0)
    ir.TF64 -> ir.ConstF64(0)
    // A `TTerm` WASM local is a GC reference (only `ast.Ref` lowers to `TTerm`);
    // its zero value is the null sentinel `{ref_null}` (shared with funcref/
    // externref null), never an integer.
    ir.TTerm -> ir.ConstNull(ir.FuncRef)
    // A reference-typed slot's zero value is the null reference (H1). Never arises from the
    // Phase-1..4 WASM surface (only numeric locals); P5-05 exercises reference locals.
    ir.TFuncRef -> ir.ConstNull(ir.FuncRef)
    ir.TExternRef -> ir.ConstNull(ir.ExternRef)
    // A `v128` slot's zero value is the all-zero 16-byte vector (I1). Never arises from the
    // Phase-1..5 WASM surface; P6-05 exercises real v128 locals.
    ir.TV128 -> ir.ConstV128(<<0:128>>)
    // An `exnref` slot's zero value is the null reference (J2/T9) — `ref.null exn`. Never arises
    // from the Phase-1..6 WASM surface; P7-05 exercises real exnref locals.
    ir.TExnRef -> ir.ConstNull(ir.ExnRef)
  }
}

/// Convert a possibly-negative decoded const value to its raw unsigned bit pattern in
/// `[0, 2^width)` (the IR stores integer constants as unsigned bits).
fn unsigned_bits(value: Int, width: Int) -> Int {
  case value < 0 {
    True -> value + two_pow(width)
    False -> value
  }
}

/// `2^n` for `n >= 0` (BEAM bignum). Total.
fn two_pow(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> 2 * two_pow(n - 1)
  }
}

/// Total list indexing returning `Error(err)` (the caller's chosen `LowerError`).
fn func_type_err(
  types: List(ast.DefType),
  i: Int,
  err: LowerError,
) -> Result(ast.FuncType, LowerError) {
  case ast.func_type_at(types, i) {
    Ok(ft) -> Ok(ft)
    Error(_) -> Error(err)
  }
}

fn nth_err(xs: List(a), i: Int, err: LowerError) -> Result(a, LowerError) {
  case xs, i {
    [x, ..], 0 -> Ok(x)
    [_, ..rest], _ ->
      case i > 0 {
        True -> nth_err(rest, i - 1, err)
        False -> Error(err)
      }
    [], _ -> Error(err)
  }
}

/// Generate one fresh SSA variable name and advance the counter.
fn fresh(counter: Int) -> #(String, Int) {
  #("v" <> int.to_string(counter), counter + 1)
}

/// Generate one fresh label name and advance the counter.
fn fresh_label(counter: Int) -> #(String, Int) {
  #("lbl" <> int.to_string(counter), counter + 1)
}

/// Generate `n` fresh SSA variable names and advance the counter.
fn fresh_n(counter: Int, n: Int) -> #(List(String), Int) {
  case n <= 0 {
    True -> #([], counter)
    False -> {
      let #(name, c) = fresh(counter)
      let #(rest, c2) = fresh_n(c, n - 1)
      #([name, ..rest], c2)
    }
  }
}

// ─────────────────────────────── SSA value-type tracking ───────────────────────────────

/// Record `name → ty` in the SSA type map (used to recover a `select`'s operand type).
fn record_type(st: LState, name: String, ty: ir.ValType) -> LState {
  LState(..st, var_types: dict.insert(st.var_types, name, ty))
}

/// Record many `name → ty` pairs in the SSA type map.
fn record_types(st: LState, pairs: List(#(String, ir.ValType))) -> LState {
  LState(..st, var_types: insert_types(st.var_types, pairs))
}

/// Fold a list of `#(name, type)` pairs into a `Dict(String, ValType)`.
fn insert_types(
  d: Dict(String, ir.ValType),
  pairs: List(#(String, ir.ValType)),
) -> Dict(String, ir.ValType) {
  list.fold(pairs, d, fn(acc, p) { dict.insert(acc, p.0, p.1) })
}

/// The IR value type of an operand `v`. Constants are self-describing; a `Var` looks up the
/// recorded SSA type (always present for a validated module, since every binder records its
/// type), falling back to `TI32` defensively for an unvalidated module. Used to type a
/// `select` result (§5 — every other Phase-2 result type is opcode-determined).
fn value_type(st: LState, v: ir.Value) -> ir.ValType {
  case v {
    ir.ConstI32(_) -> ir.TI32
    ir.ConstI64(_) -> ir.TI64
    ir.ConstF32(_) -> ir.TF32
    ir.ConstF64(_) -> ir.TF64
    // A null-reference literal is self-describing via its reftype tag (H1).
    ir.ConstNull(ty) -> ir.reftype_to_valtype(ty)
    // A `v128.const` literal is self-describing (I1).
    ir.ConstV128(_) -> ir.TV128
    // Phase-8 term literals (K2) are boxed BEAM terms (`TTerm`). No WASM instruction produces
    // one (K7 — additive), so these arms are unreachable on the WASM path; present only to keep
    // the `Value` match exhaustive (fail-closed, D4).
    ir.ConstAtom(_) | ir.ConstBinary(_) | ir.ConstFloatTerm(_) -> ir.TTerm
    ir.Var(n) -> dict.get(st.var_types, n) |> result.unwrap(ir.TI32)
  }
}

/// The stable IR global name for global index `i` (`g<idx>`). Must match emit_core /
/// instantiate (unit 10) and `GlobalDecl.name`.
fn gname(i: Int) -> String {
  "g" <> int.to_string(i)
}

/// The stable IR table name for table index `i` (`t<idx>`; MVP reserved table `0` → `"t0"`).
/// Must match `TableDecl.name`, `ElementSegment.table`, and emit_core / instantiate.
fn tname(i: Int) -> String {
  "t" <> int.to_string(i)
}

/// The stable IR tag name for ABSOLUTE tagidx `i` (`tag<idx>`; Phase 7). The single naming
/// convention shared by `TagDecl.name`, `ImportTag`'s slot, `Throw`/`CatchTag.OnTag`, and
/// `ExportTag.tag_name`, so a tag resolves to the same build-controlled exception class
/// across the module — mirroring `f<idx>`/`g<idx>`/`t<idx>` (D6).
fn tagname(i: Int) -> String {
  "tag" <> int.to_string(i)
}

/// The declared IR value type of global `i`, for SSA type tracking of `global.get`. Falls
/// back to `TI32` for an out-of-range index (only reachable on an unvalidated module —
/// validation rejects an out-of-range global, so the lowered `GlobalGet` name is still valid).
fn global_ty(ctx: LCtx, i: Int) -> ir.ValType {
  case nth_err(ctx.global_types, i, UnknownTypeIndex(i)) {
    Ok(t) -> t
    Error(_) -> ir.TI32
  }
}

/// The element reference type of table `x` (absolute tableidx), for typing a `table.get`
/// result. Falls back to `FuncRef` for an out-of-range index (only reachable on an
/// unvalidated module — validation rejects an out-of-range table).
fn table_reftype(ctx: LCtx, x: Int) -> ir.RefType {
  case nth_err(ctx.table_types, x, UnknownTypeIndex(x)) {
    Ok(rt) -> rt
    Error(_) -> ir.FuncRef
  }
}

// ─────────────────────────────── module-level declarations ───────────────────────────────

/// Lower the memory section to the IR memories vector (H3), in index order. Each declared
/// memory → `MemoryDecl(min, max, idx_type)`. A single 32-bit memory becomes a one-element
/// `[MemoryDecl(min, max, Idx32)]` (byte-identical to Phase-4); `[]` if the module declares
/// no memory. A 64-bit memory carries `Idx64` (I4 — memory64 runtime lands in Phase 6); the
/// address width rides on the decl for emit_core/rt_mem, never as a per-node field. These are
/// the *defined* memories; imported memories occupy the low indices of the memory index space
/// and are surfaced as `ImportMemory` (their runtime slot wiring is P5-09's).
fn lower_memory(module: ast.Module) -> List(ir.MemoryDecl) {
  list.map(module.memories, fn(m) {
    ir.MemoryDecl(m.limits.min, m.limits.max, to_ir_idxtype(m.idx_type))
  })
}

/// Lower the global section to `GlobalDecl`s in index order. Defined global `j` is named at
/// its **absolute** globalidx `imported_global_count + j` (`g<abs>`) so a `GlobalGet`/`Set`
/// referencing that absolute index resolves to the same slot (imports ++ defined, §G.5). The
/// init is a const-expr (`t.const` / `ref.func` / `ref.null` / `global.get`).
/// `Error(NonConstInitExpr(_))` on an inadmissible init. Byte-identical when there are no
/// imported globals (`imported_global_count = 0` ⇒ `g0, g1, …`).
fn lower_globals(
  module: ast.Module,
  imported_global_count: Int,
  imported_func_count: Int,
  func_types: List(ast.FuncType),
) -> Result(List(ir.GlobalDecl), LowerError) {
  list.index_map(module.globals, fn(g, i) {
    use init <- result.try(lower_const_expr(
      g.init,
      imported_func_count,
      func_types,
      module.types,
    ))
    Ok(ir.GlobalDecl(
      gname(imported_global_count + i),
      to_ir_vt(g.ty),
      g.mutable,
      init,
    ))
  })
  |> result.all
}

/// Lower the table section to `TableDecl`s. Defined table `i` is named at its **absolute**
/// tableidx `imported_table_count + i` (`t<abs>`) and carries its element reference type
/// (`FuncRef`/`ExternRef`) from the AST table type. Imported tables occupy the low indices
/// (surfaced as `ImportTable`). Byte-identical for a single funcref table with no imports
/// (`TableDecl("t0", FuncRef, …)`).
fn lower_tables(
  module: ast.Module,
  imported_table_count: Int,
) -> List(ir.TableDecl) {
  list.index_map(module.tables, fn(t, i) {
    ir.TableDecl(
      tname(imported_table_count + i),
      to_ir_reftype(t.elem_type),
      t.limits.min,
      t.limits.max,
    )
  })
}

/// Lower the tag section to `TagDecl`s (J2/T2). Defined tag `j` is named at its ABSOLUTE
/// tagidx `imported_tag_count + j` (`tag<abs>`) — the same imports-first index space and
/// `tag<idx>` naming a `throw`/`catch`/`ExportTag` references — and carries the exception's
/// operand types (`types[type_idx].params`; the tag's results are `[]`, proven empty by
/// validate). `Error(UnknownTypeIndex(_))` on an out-of-range `type_idx` (only reachable on
/// an unvalidated module). Byte-identical when there is no tag section (`Module.tags = []`).
fn lower_tags(
  module: ast.Module,
  imported_tag_count: Int,
) -> Result(List(ir.TagDecl), LowerError) {
  list.index_map(module.tags, fn(t, i) {
    use sig <- result.try(func_type_err(
      module.types,
      t.type_idx,
      UnknownTypeIndex(t.type_idx),
    ))
    Ok(ir.TagDecl(
      tagname(imported_tag_count + i),
      list.map(sig.params, to_ir_vt),
    ))
  })
  |> result.all
}

/// Lower every element segment (active | passive | declarative), preserving its mode and
/// element reference type, and lowering each init item to a ref-producing const-expr `Expr`
/// (§G.3):
///
/// - **Active** → `ElemActive(t<table>, offset)` where `table` is the absolute tableidx and
///   `offset` is the const-expr offset. A funcref-active flag-0 segment into table 0 lowers
///   byte-identically to Phase-4 (`ElemActive("t0", …)`, `init = [RefFunc("f0"), …]`).
/// - **Passive** → `ElemPassive`; the items are the source for a later `table.init`.
/// - **Declarative** → `ElemDeclarative`; no runtime content (declares `ref.func` targets).
///
/// Init items: the legacy `funcidx` vector (`ElemFuncs`) maps each funcidx `x` →
/// `RefFunc("f<x>")`; the expression form (`ElemExprs`) lowers each const-expr (`ref.func` →
/// `RefFunc`, `ref.null t` → `Values([ConstNull(t)])`, `global.get` → `GlobalGet`).
/// `Error(NonConstInitExpr(_))` on an inadmissible offset/item.
fn lower_elements(
  module: ast.Module,
  imported: Int,
  func_types: List(ast.FuncType),
) -> Result(List(ir.ElementSegment), LowerError) {
  list.try_map(module.elements, fn(e) {
    use init <- result.try(lower_elem_init(
      e.init,
      imported,
      func_types,
      module.types,
    ))
    use mode <- result.try(case e.mode {
      ast.ElemActive(table, offset_expr) -> {
        use offset <- result.try(lower_const_expr(
          offset_expr,
          imported,
          func_types,
          module.types,
        ))
        Ok(ir.ElemActive(tname(table), offset))
      }
      ast.ElemPassive -> Ok(ir.ElemPassive)
      ast.ElemDeclarative -> Ok(ir.ElemDeclarative)
    })
    Ok(ir.ElementSegment(mode, to_ir_reftype(e.ref_ty), init))
  })
}

/// Lower an element segment's init items to ref-producing const-expr `Expr`s. Both forms apply the
/// R14 `ref.func` import split (`lower_ref_func`): the legacy funcidx vector maps each funcidx to a
/// DEFINED `RefFunc("f<idx>")` or, for an imported funcidx, a `RefFuncImport(idx, ty)` (each funcidx
/// is an implicit `ref.func` — the same funcidx→name convention for defined targets); the expression
/// form lowers each const-expr (a `ref.func x` there splits the same way). `imported`/`func_types`
/// drive the split (see `lower_ref_func`).
fn lower_elem_init(
  init: ast.ElemInit,
  imported: Int,
  func_types: List(ast.FuncType),
  types: List(ast.DefType),
) -> Result(List(ir.Expr), LowerError) {
  case init {
    ast.ElemFuncs(funcs) ->
      list.try_map(funcs, fn(idx) { lower_ref_func(idx, imported, func_types) })
    ast.ElemExprs(exprs) ->
      list.try_map(exprs, fn(e) {
        lower_const_expr(e, imported, func_types, types)
      })
  }
}

/// Lower every data segment (active | passive), preserving its mode:
///
/// - **Active** → `DataActive(mem, offset)` where `mem` is the (absolute) memory index and
///   `offset` is the const-expr offset. `DataActive(0, …)` is byte-identical to Phase-4.
/// - **Passive** → `DataPassive`; the bytes are the source for a later `memory.init`.
///
/// `Error(NonConstInitExpr(_))` on a non-constant active offset.
fn lower_data(
  module: ast.Module,
  imported: Int,
  func_types: List(ast.FuncType),
) -> Result(List(ir.DataSegment), LowerError) {
  list.try_map(module.data, fn(d) {
    case d.mode {
      ast.DataActive(mem, offset_expr) -> {
        use offset <- result.try(lower_const_expr(
          offset_expr,
          imported,
          func_types,
          module.types,
        ))
        Ok(ir.DataSegment(ir.DataActive(mem, offset), d.bytes))
      }
      ast.DataPassive -> Ok(ir.DataSegment(ir.DataPassive, d.bytes))
    }
  })
}

/// Lower the import section to `ImportDecl`s in order (H4). Function imports become
/// `ImportFn(module, name, ty)` (the capability grouping is the WASM import module name, the
/// convention host-function imports already use); the three state kinds become the provided
/// -state variants `ImportGlobal`/`ImportTable`/`ImportMemory`. lower only *declares* imports
/// — the actual link/instantiation wiring is P5-09's (`«INSTANTIATE3»`). `[]` for an
/// import-free module (byte-identical to Phase-4). `Error(UnknownTypeIndex)` if a function
/// import names a type index out of range.
fn lower_imports(
  module: ast.Module,
) -> Result(List(ir.ImportDecl), LowerError) {
  list.try_map(module.imports, fn(imp) {
    case imp.desc {
      ast.ImportFunc(tyidx) -> {
        use sig <- result.try(func_type_err(
          module.types,
          tyidx,
          UnknownTypeIndex(tyidx),
        ))
        Ok(ir.ImportFn(imp.module, imp.name, ir_functype(sig)))
      }
      ast.ImportGlobal(ty, mutable) ->
        Ok(ir.ImportGlobal(imp.module, imp.name, to_ir_vt(ty), mutable))
      ast.ImportTable(tt) ->
        Ok(ir.ImportTable(
          imp.module,
          imp.name,
          to_ir_reftype(tt.elem_type),
          tt.limits.min,
          tt.limits.max,
        ))
      ast.ImportMemory(mt) ->
        Ok(ir.ImportMemory(
          imp.module,
          imp.name,
          mt.limits.min,
          mt.limits.max,
          to_ir_idxtype(mt.idx_type),
        ))
      // An imported exception tag («WASM-AST5», Phase 7). Provided state keyed on the
      // `(module, name)` link key (like `ImportGlobal`); `params` is the tag's operand
      // signature (the exception payload types), resolved from `types[tyidx]` and mapped to
      // IR types. Imported tags occupy the LOW tagidx range (before defined tags).
      ast.ImportTag(tyidx) -> {
        use sig <- result.try(func_type_err(
          module.types,
          tyidx,
          UnknownTypeIndex(tyidx),
        ))
        Ok(ir.ImportTag(imp.module, imp.name, list.map(sig.params, to_ir_vt)))
      }
    }
  })
}

/// Convert an AST function type to the nameless IR `FuncType` (params ++ results mapped to
/// IR value types). Used for function imports and `call_indirect` type tags.
fn ir_functype(sig: ast.FuncType) -> ir.FuncType {
  ir.FuncType(list.map(sig.params, to_ir_vt), list.map(sig.results, to_ir_vt))
}

/// Lower a `ref.func $f` funcidx to its IR reference expression, splitting on whether `$f` names
/// an IMPORTED or a DEFINED function — the exact mirror of `lower_call`'s import split (R14
/// keystone). The WASM funcidx space is UNIFIED: function imports occupy funcidx `0..imported-1`
/// and defined functions follow, so an imported and a defined `ref.func` differ only in which half
/// of the index space `f` falls in.
///
/// - `f < imported` (a function import) → `ir.RefFuncImport(f, ty)`, where `ty` is the import's IR
///   signature and `slot == funcidx == f` (imports occupy the low funcidx range). This is the
///   cross-module funcref the emitter later routes through `link.call_import` (R14-02); until then
///   it fails closed with the same `UnknownFunction("f<f>")` skip as before (byte-identical).
/// - `f >= imported` (a same-module function) → `ir.RefFunc("f<f>")` (unchanged, byte-identical).
///
/// Used by every `ref.func` lowering site — a function-body instruction, an element-segment item
/// (`ElemFuncs`/`ElemExprs`), and a reference-global initialiser — so the import split cannot drift
/// across them. `func_types` spans `imports ++ defined` (`typed.func_types`), so an imported funcidx
/// recovers its signature. Returns `Error(UnknownFuncIndex(f))` if `f` is out of range (only
/// reachable on an unvalidated module — fail-closed insurance).
fn lower_ref_func(
  f: Int,
  imported: Int,
  func_types: List(ast.FuncType),
) -> Result(ir.Expr, LowerError) {
  case f < imported {
    True -> {
      use sig <- result.try(nth_err(func_types, f, UnknownFuncIndex(f)))
      Ok(ir.RefFuncImport(f, ir_functype(sig)))
    }
    False -> Ok(ir.RefFunc("f" <> int.to_string(f)))
  }
}

/// Lower the start section's funcidx (if present) to the IR function name `f<funcidx>`
/// (run once at instantiation). The funcidx is absolute (imports ++ defined).
fn lower_start(module: ast.Module) -> Option(String) {
  case module.start {
    Some(idx) -> Some("f" <> int.to_string(idx))
    None -> None
  }
}

/// Lower a constant expression (a global init, an element item, or an element/data offset)
/// to its IR value expression, per the WebAssembly const-expr grammar
/// ([valid/instructions#constant-expressions]): a single `t.const` / `ref.func` / `ref.null`
/// / `global.get` (of an immutable imported global), then `end` (decode already strips the
/// `end`; a trailing `End` is stripped defensively here too):
///
/// - `t.const` → `Values([Const…])`. Integers are stored as their raw unsigned bit pattern;
///   floats keep their raw IEEE-754 bits (D5); `v128.const` keeps its raw 16 little-endian
///   bytes as `ConstV128(bytes)` (I1 — a `v128` global's initialiser).
/// - `ref.func x` → `RefFunc("f<x>")` for a DEFINED `x`, or `RefFuncImport(x, ty)` for an IMPORTED
///   `x` (the R14 import split, via `lower_ref_func` — so a funcref-in-`elem`/global init to an
///   imported function is a first-class cross-module funcref, not an `UnknownFunction`-named
///   defined ref). `imported`/`func_types` drive that split (see `lower_ref_func`); an element/data
///   OFFSET is never a `ref.func`, so those callers pass the params through unused.
/// - `ref.null t` → `Values([ConstNull(t)])` (the null reference literal — R1c: `ref.null`
///   reduces to the `ConstNull` value, not a separate `Expr`).
/// - `global.get i` → `GlobalGet("g<i>")` (an immutable imported global's value; now
///   accepted, was rejected in Phase 2 when no imports existed).
///
/// Anything else (an extended-const arithmetic chain — a separate proposal) →
/// `Error(NonConstInitExpr(_))`, fail-closed. Validation already enforces the const-expr
/// rule; this is the constructive counterpart + defence.
fn lower_const_expr(
  instrs: List(ast.Instr),
  imported: Int,
  func_types: List(ast.FuncType),
  types: List(ast.DefType),
) -> Result(ir.Expr, LowerError) {
  let stripped = case list.reverse(instrs) {
    [ast.End, ..rest] -> list.reverse(rest)
    _ -> instrs
  }
  case stripped {
    [ast.I32Const(v)] -> Ok(ir.Values([ir.ConstI32(unsigned_bits(v, 32))]))
    [ast.I64Const(v)] -> Ok(ir.Values([ir.ConstI64(unsigned_bits(v, 64))]))
    [ast.F32Const(bits)] -> Ok(ir.Values([ir.ConstF32(bits)]))
    [ast.F64Const(bits)] -> Ok(ir.Values([ir.ConstF64(bits)]))
    // `v128.const` is a constant instruction (spec valid/instructions §constant-expressions),
    // so a `v128` global's initialiser is a single `v128.const` — the raw 16 bytes verbatim.
    [ast.V128Const(bytes)] -> Ok(ir.Values([ir.ConstV128(bytes)]))
    [ast.RefFunc(x)] -> lower_ref_func(x, imported, func_types)
    [ast.RefNull(rt)] -> Ok(ir.Values([ir.ConstNull(to_ir_reftype(rt))]))
    [ast.GlobalGet(i)] -> Ok(ir.GlobalGet(gname(i)))
    // GC constant-expression SEQUENCES (`ref.i31`, `struct.new[_default]`,
    // `array.new[_default|_fixed]`, which NEST): lower to an ANF `Let`-chain of `ir.Gc`
    // allocations evaluated in-process at instantiate time. Validation already guaranteed
    // constancy + arity; this is the constructive counterpart. Non-GC modules never reach
    // here (their inits hit the single-instruction arms above), so IR is byte-identical.
    _ -> lower_const_seq(stripped, imported, func_types, types)
  }
}

/// Lower a GC constant-expression SEQUENCE to an `ir.Expr` (an ANF `Let`-chain ending in the
/// produced value). Mirrors the body's operand construction (`ir.Gc` args bottom-first): each
/// allocation / `ref.func` / `global.get` binds a fresh name and pushes its `Var`; constants
/// push their `Value` directly. The single leftover stack value is the init's result.
/// `Error(NonConstInitExpr(_))` on a non-constant instruction (validation already rejected these,
/// so this is a defensive backstop).
fn lower_const_seq(
  instrs: List(ast.Instr),
  imported: Int,
  func_types: List(ast.FuncType),
  types: List(ast.DefType),
) -> Result(ir.Expr, LowerError) {
  use #(stack, binds, _c) <- result.try(
    list.try_fold(instrs, #([], [], 0), fn(acc, instr) {
      let #(stack, binds, counter) = acc
      case instr {
        ast.I32Const(v) ->
          Ok(#([ir.ConstI32(unsigned_bits(v, 32)), ..stack], binds, counter))
        ast.I64Const(v) ->
          Ok(#([ir.ConstI64(unsigned_bits(v, 64)), ..stack], binds, counter))
        ast.F32Const(b) -> Ok(#([ir.ConstF32(b), ..stack], binds, counter))
        ast.F64Const(b) -> Ok(#([ir.ConstF64(b), ..stack], binds, counter))
        ast.V128Const(b) -> Ok(#([ir.ConstV128(b), ..stack], binds, counter))
        ast.RefNull(rt) ->
          Ok(#([ir.ConstNull(to_ir_reftype(rt)), ..stack], binds, counter))
        ast.RefNullHt(_) ->
          Ok(#([ir.ConstNull(ir.FuncRef), ..stack], binds, counter))
        ast.RefFunc(x) -> {
          use e <- result.try(lower_ref_func(x, imported, func_types))
          Ok(bind_seq(e, stack, binds, counter))
        }
        ast.GlobalGet(i) ->
          Ok(bind_seq(ir.GlobalGet(gname(i)), stack, binds, counter))
        ast.RefI31 ->
          pop_bind(1, stack, binds, counter, fn(a) { ir.Gc(ir.GcRefI31, a) })
        ast.StructNew(t) -> {
          use fs <- result.try(struct_fields_at(types, t))
          pop_bind(list.length(fs), stack, binds, counter, fn(a) {
            ir.Gc(ir.GcStructNew(t), a)
          })
        }
        ast.StructNewDefault(t) -> {
          use fs <- result.try(struct_fields_at(types, t))
          Ok(bind_seq(
            ir.Gc(
              ir.GcStructNew(t),
              list.map(fs, fn(fd) { default_storage_value(fd.storage) }),
            ),
            stack,
            binds,
            counter,
          ))
        }
        // GC array.new args are [elem, count] (bottom-first); the stack top→down is count,elem,
        // so `pop_bind` (reverse of the top n) yields exactly [elem, count].
        ast.ArrayNew(t) ->
          pop_bind(2, stack, binds, counter, fn(a) {
            ir.Gc(ir.GcArrayNew(t), a)
          })
        ast.ArrayNewDefault(t) -> {
          use fd <- result.try(array_field_at(types, t))
          let d = default_storage_value(fd.storage)
          pop_bind(1, stack, binds, counter, fn(a) {
            ir.Gc(ir.GcArrayNew(t), [d, ..a])
          })
        }
        ast.ArrayNewFixed(t, n) ->
          pop_bind(n, stack, binds, counter, fn(a) {
            ir.Gc(ir.GcArrayNewFixed(t), a)
          })
        ast.AnyConvertExtern ->
          pop_bind(1, stack, binds, counter, fn(a) {
            ir.Gc(ir.GcAnyConvertExtern, a)
          })
        ast.ExternConvertAny ->
          pop_bind(1, stack, binds, counter, fn(a) {
            ir.Gc(ir.GcExternConvertAny, a)
          })
        _ -> Error(NonConstInitExpr("non-constant init expression"))
      }
    }),
  )
  case stack {
    [final] ->
      Ok(
        list.fold(binds, ir.Values([final]), fn(inner, b) {
          let #(ns, rhs) = b
          ir.Let(ns, rhs, inner)
        }),
      )
    _ -> Error(NonConstInitExpr("const expr did not yield exactly one value"))
  }
}

/// Bind an `Expr` result to a fresh SSA name: record the `#(names, rhs)` binding and push the
/// name's `Var` onto the value stack. The binding list is prepended (most-recent first); the
/// caller folds it so the FIRST binding is outermost (correct evaluation order).
fn bind_seq(
  rhs: ir.Expr,
  stack: List(ir.Value),
  binds: List(#(List(String), ir.Expr)),
  counter: Int,
) -> #(List(ir.Value), List(#(List(String), ir.Expr)), Int) {
  let #(name, c2) = fresh(counter)
  #([ir.Var(name), ..stack], [#([name], rhs), ..binds], c2)
}

/// Pop `n` operand values (bottom-first) off the const-seq stack, build the allocation `Expr`
/// from them, and bind it. `Error(StackUnderflow)` on too few operands (validation guarantees
/// arity, so this is defensive).
fn pop_bind(
  n: Int,
  stack: List(ir.Value),
  binds: List(#(List(String), ir.Expr)),
  counter: Int,
  build: fn(List(ir.Value)) -> ir.Expr,
) -> Result(#(List(ir.Value), List(#(List(String), ir.Expr)), Int), LowerError) {
  case list.length(stack) >= n {
    False -> Error(StackUnderflow)
    True -> {
      let args = list.reverse(list.take(stack, n))
      let rest = list.drop(stack, n)
      Ok(bind_seq(build(args), rest, binds, counter))
    }
  }
}

/// The struct field types at type index `t` (for const-expr `struct.new`).
fn struct_fields_at(
  types: List(ast.DefType),
  t: Int,
) -> Result(List(ast.FieldType), LowerError) {
  case ast.def_type_at(types, t) {
    Ok(ast.DefType(comp: ast.CtStruct(fs), ..)) -> Ok(fs)
    _ -> Error(UnknownTypeIndex(t))
  }
}

/// The array element field type at type index `t` (for const-expr `array.new*`).
fn array_field_at(
  types: List(ast.DefType),
  t: Int,
) -> Result(ast.FieldType, LowerError) {
  case ast.def_type_at(types, t) {
    Ok(ast.DefType(comp: ast.CtArray(fd), ..)) -> Ok(fd)
    _ -> Error(UnknownTypeIndex(t))
  }
}

// ─────────────────────────────── numeric op tables ───────────────────────────────

/// Map a WASM numeric/comparison opcode to `#(operand_count, ir.NumOp)` (neutral,
/// width-tagged — D6). `Error(Nil)` for opcodes that are not `ir.Num` ops (conversions,
/// control, etc.).
fn num_op(instr: ast.Instr) -> Result(#(Int, ir.NumOp), Nil) {
  case instr {
    // i32 comparisons
    ast.I32Eqz -> Ok(#(1, ir.IEqz(ir.W32)))
    ast.I32Eq -> Ok(#(2, ir.IEq(ir.W32)))
    ast.I32Ne -> Ok(#(2, ir.INe(ir.W32)))
    ast.I32LtS -> Ok(#(2, ir.ILtS(ir.W32)))
    ast.I32LtU -> Ok(#(2, ir.ILtU(ir.W32)))
    ast.I32GtS -> Ok(#(2, ir.IGtS(ir.W32)))
    ast.I32GtU -> Ok(#(2, ir.IGtU(ir.W32)))
    ast.I32LeS -> Ok(#(2, ir.ILeS(ir.W32)))
    ast.I32LeU -> Ok(#(2, ir.ILeU(ir.W32)))
    ast.I32GeS -> Ok(#(2, ir.IGeS(ir.W32)))
    ast.I32GeU -> Ok(#(2, ir.IGeU(ir.W32)))
    // i64 comparisons
    ast.I64Eqz -> Ok(#(1, ir.IEqz(ir.W64)))
    ast.I64Eq -> Ok(#(2, ir.IEq(ir.W64)))
    ast.I64Ne -> Ok(#(2, ir.INe(ir.W64)))
    ast.I64LtS -> Ok(#(2, ir.ILtS(ir.W64)))
    ast.I64LtU -> Ok(#(2, ir.ILtU(ir.W64)))
    ast.I64GtS -> Ok(#(2, ir.IGtS(ir.W64)))
    ast.I64GtU -> Ok(#(2, ir.IGtU(ir.W64)))
    ast.I64LeS -> Ok(#(2, ir.ILeS(ir.W64)))
    ast.I64LeU -> Ok(#(2, ir.ILeU(ir.W64)))
    ast.I64GeS -> Ok(#(2, ir.IGeS(ir.W64)))
    ast.I64GeU -> Ok(#(2, ir.IGeU(ir.W64)))
    // i32 numeric
    ast.I32Clz -> Ok(#(1, ir.IClz(ir.W32)))
    ast.I32Ctz -> Ok(#(1, ir.ICtz(ir.W32)))
    ast.I32Popcnt -> Ok(#(1, ir.IPopcnt(ir.W32)))
    ast.I32Add -> Ok(#(2, ir.IAdd(ir.W32)))
    ast.I32Sub -> Ok(#(2, ir.ISub(ir.W32)))
    ast.I32Mul -> Ok(#(2, ir.IMul(ir.W32)))
    ast.I32DivS -> Ok(#(2, ir.IDivS(ir.W32)))
    ast.I32DivU -> Ok(#(2, ir.IDivU(ir.W32)))
    ast.I32RemS -> Ok(#(2, ir.IRemS(ir.W32)))
    ast.I32RemU -> Ok(#(2, ir.IRemU(ir.W32)))
    ast.I32And -> Ok(#(2, ir.IAnd(ir.W32)))
    ast.I32Or -> Ok(#(2, ir.IOr(ir.W32)))
    ast.I32Xor -> Ok(#(2, ir.IXor(ir.W32)))
    ast.I32Shl -> Ok(#(2, ir.IShl(ir.W32)))
    ast.I32ShrS -> Ok(#(2, ir.IShrS(ir.W32)))
    ast.I32ShrU -> Ok(#(2, ir.IShrU(ir.W32)))
    ast.I32Rotl -> Ok(#(2, ir.IRotl(ir.W32)))
    ast.I32Rotr -> Ok(#(2, ir.IRotr(ir.W32)))
    // i64 numeric
    ast.I64Clz -> Ok(#(1, ir.IClz(ir.W64)))
    ast.I64Ctz -> Ok(#(1, ir.ICtz(ir.W64)))
    ast.I64Popcnt -> Ok(#(1, ir.IPopcnt(ir.W64)))
    ast.I64Add -> Ok(#(2, ir.IAdd(ir.W64)))
    ast.I64Sub -> Ok(#(2, ir.ISub(ir.W64)))
    ast.I64Mul -> Ok(#(2, ir.IMul(ir.W64)))
    ast.I64DivS -> Ok(#(2, ir.IDivS(ir.W64)))
    ast.I64DivU -> Ok(#(2, ir.IDivU(ir.W64)))
    ast.I64RemS -> Ok(#(2, ir.IRemS(ir.W64)))
    ast.I64RemU -> Ok(#(2, ir.IRemU(ir.W64)))
    ast.I64And -> Ok(#(2, ir.IAnd(ir.W64)))
    ast.I64Or -> Ok(#(2, ir.IOr(ir.W64)))
    ast.I64Xor -> Ok(#(2, ir.IXor(ir.W64)))
    ast.I64Shl -> Ok(#(2, ir.IShl(ir.W64)))
    ast.I64ShrS -> Ok(#(2, ir.IShrS(ir.W64)))
    ast.I64ShrU -> Ok(#(2, ir.IShrU(ir.W64)))
    ast.I64Rotl -> Ok(#(2, ir.IRotl(ir.W64)))
    ast.I64Rotr -> Ok(#(2, ir.IRotr(ir.W64)))
    // Float binary ARITHMETIC (arity 2, → the operand's float width). These map to the
    // existing `FAdd…FMax` NumOps, which emit_core + `rt_num` already lower end-to-end
    // (Phase-1 covered them), so lowering them is complete *and* runnable.
    ast.F32Add -> Ok(#(2, ir.FAdd(ir.FW32)))
    ast.F32Sub -> Ok(#(2, ir.FSub(ir.FW32)))
    ast.F32Mul -> Ok(#(2, ir.FMul(ir.FW32)))
    ast.F32Div -> Ok(#(2, ir.FDiv(ir.FW32)))
    ast.F32Min -> Ok(#(2, ir.FMin(ir.FW32)))
    ast.F32Max -> Ok(#(2, ir.FMax(ir.FW32)))
    ast.F64Add -> Ok(#(2, ir.FAdd(ir.FW64)))
    ast.F64Sub -> Ok(#(2, ir.FSub(ir.FW64)))
    ast.F64Mul -> Ok(#(2, ir.FMul(ir.FW64)))
    ast.F64Div -> Ok(#(2, ir.FDiv(ir.FW64)))
    ast.F64Min -> Ok(#(2, ir.FMin(ir.FW64)))
    ast.F64Max -> Ok(#(2, ir.FMax(ir.FW64)))
    // Float UNARY (arity 1, → the operand's float width) and COMPARISONS (arity 2, → i32).
    // CROSS-REACH (unit 10): these were deferred only because emit_core's `num_op_name`
    // PANICKED on them; unit 10 now maps `FAbs..FGe`/`FCopysign` to the frozen `rt_num`
    // float names, so lowering them here makes the float comparison/unary modules
    // lower → emit → run end-to-end.
    ast.F32Abs -> Ok(#(1, ir.FAbs(ir.FW32)))
    ast.F32Neg -> Ok(#(1, ir.FNeg(ir.FW32)))
    ast.F32Ceil -> Ok(#(1, ir.FCeil(ir.FW32)))
    ast.F32Floor -> Ok(#(1, ir.FFloor(ir.FW32)))
    ast.F32Trunc -> Ok(#(1, ir.FTrunc(ir.FW32)))
    ast.F32Nearest -> Ok(#(1, ir.FNearest(ir.FW32)))
    ast.F32Sqrt -> Ok(#(1, ir.FSqrt(ir.FW32)))
    ast.F32Copysign -> Ok(#(2, ir.FCopysign(ir.FW32)))
    ast.F64Abs -> Ok(#(1, ir.FAbs(ir.FW64)))
    ast.F64Neg -> Ok(#(1, ir.FNeg(ir.FW64)))
    ast.F64Ceil -> Ok(#(1, ir.FCeil(ir.FW64)))
    ast.F64Floor -> Ok(#(1, ir.FFloor(ir.FW64)))
    ast.F64Trunc -> Ok(#(1, ir.FTrunc(ir.FW64)))
    ast.F64Nearest -> Ok(#(1, ir.FNearest(ir.FW64)))
    ast.F64Sqrt -> Ok(#(1, ir.FSqrt(ir.FW64)))
    ast.F64Copysign -> Ok(#(2, ir.FCopysign(ir.FW64)))
    ast.F32Eq -> Ok(#(2, ir.FEq(ir.FW32)))
    ast.F32Ne -> Ok(#(2, ir.FNe(ir.FW32)))
    ast.F32Lt -> Ok(#(2, ir.FLt(ir.FW32)))
    ast.F32Gt -> Ok(#(2, ir.FGt(ir.FW32)))
    ast.F32Le -> Ok(#(2, ir.FLe(ir.FW32)))
    ast.F32Ge -> Ok(#(2, ir.FGe(ir.FW32)))
    ast.F64Eq -> Ok(#(2, ir.FEq(ir.FW64)))
    ast.F64Ne -> Ok(#(2, ir.FNe(ir.FW64)))
    ast.F64Lt -> Ok(#(2, ir.FLt(ir.FW64)))
    ast.F64Gt -> Ok(#(2, ir.FGt(ir.FW64)))
    ast.F64Le -> Ok(#(2, ir.FLe(ir.FW64)))
    ast.F64Ge -> Ok(#(2, ir.FGe(ir.FW64)))
    _ -> Error(Nil)
  }
}

/// Map a WASM conversion opcode (sign-extension, saturating truncation, or the full
/// `0xA7–0xBF` int↔float block) to its `ir.ConvOp` (always one operand). `Error(Nil)` for
/// non-conversion opcodes.
///
/// The `0xA7–0xBF` block: `wrap`/`extend`/the 4 `reinterpret`s reuse the EXISTING ConvOps
/// (no new node); the TRAPPING `trunc_f*` map to `TruncS/U` (distinct from the saturating
/// `TruncSat*` above — lower does NOT mark them, emit_core learns which ConvOps trap);
/// `convert_i*` → `ConvertS/U`; `demote`/`promote` → `F32DemoteF64`/`F64PromoteF32`. Field
/// order is fixed by the freeze: `TruncS(from: FloatWidth, to: IntWidth)`,
/// `ConvertS(from: IntWidth, to: FloatWidth)`.
fn conv_op(instr: ast.Instr) -> Result(ir.ConvOp, Nil) {
  case instr {
    ast.I32Extend8S -> Ok(ir.I32Extend8S)
    ast.I32Extend16S -> Ok(ir.I32Extend16S)
    ast.I64Extend8S -> Ok(ir.I64Extend8S)
    ast.I64Extend16S -> Ok(ir.I64Extend16S)
    ast.I64Extend32S -> Ok(ir.I64Extend32S)
    ast.I32TruncSatF32S -> Ok(ir.TruncSatS(ir.FW32, ir.W32))
    ast.I32TruncSatF32U -> Ok(ir.TruncSatU(ir.FW32, ir.W32))
    ast.I32TruncSatF64S -> Ok(ir.TruncSatS(ir.FW64, ir.W32))
    ast.I32TruncSatF64U -> Ok(ir.TruncSatU(ir.FW64, ir.W32))
    ast.I64TruncSatF32S -> Ok(ir.TruncSatS(ir.FW32, ir.W64))
    ast.I64TruncSatF32U -> Ok(ir.TruncSatU(ir.FW32, ir.W64))
    ast.I64TruncSatF64S -> Ok(ir.TruncSatS(ir.FW64, ir.W64))
    ast.I64TruncSatF64U -> Ok(ir.TruncSatU(ir.FW64, ir.W64))
    // 0xA7–0xBF: wrap / extend / reinterpret reuse EXISTING ConvOps
    ast.I32WrapI64 -> Ok(ir.I32WrapI64)
    ast.I64ExtendI32S -> Ok(ir.I64ExtendI32S)
    ast.I64ExtendI32U -> Ok(ir.I64ExtendI32U)
    ast.I32ReinterpretF32 -> Ok(ir.ReinterpretFToI(ir.FW32))
    ast.I64ReinterpretF64 -> Ok(ir.ReinterpretFToI(ir.FW64))
    ast.F32ReinterpretI32 -> Ok(ir.ReinterpretIToF(ir.W32))
    ast.F64ReinterpretI64 -> Ok(ir.ReinterpretIToF(ir.W64))
    // 0xA8–0xB1: TRAPPING float→int truncation → TruncS/U(from, to)
    ast.I32TruncF32S -> Ok(ir.TruncS(ir.FW32, ir.W32))
    ast.I32TruncF32U -> Ok(ir.TruncU(ir.FW32, ir.W32))
    ast.I32TruncF64S -> Ok(ir.TruncS(ir.FW64, ir.W32))
    ast.I32TruncF64U -> Ok(ir.TruncU(ir.FW64, ir.W32))
    ast.I64TruncF32S -> Ok(ir.TruncS(ir.FW32, ir.W64))
    ast.I64TruncF32U -> Ok(ir.TruncU(ir.FW32, ir.W64))
    ast.I64TruncF64S -> Ok(ir.TruncS(ir.FW64, ir.W64))
    ast.I64TruncF64U -> Ok(ir.TruncU(ir.FW64, ir.W64))
    // 0xB2–0xBA: int→float conversion → ConvertS/U(from, to)
    ast.F32ConvertI32S -> Ok(ir.ConvertS(ir.W32, ir.FW32))
    ast.F32ConvertI32U -> Ok(ir.ConvertU(ir.W32, ir.FW32))
    ast.F32ConvertI64S -> Ok(ir.ConvertS(ir.W64, ir.FW32))
    ast.F32ConvertI64U -> Ok(ir.ConvertU(ir.W64, ir.FW32))
    ast.F64ConvertI32S -> Ok(ir.ConvertS(ir.W32, ir.FW64))
    ast.F64ConvertI32U -> Ok(ir.ConvertU(ir.W32, ir.FW64))
    ast.F64ConvertI64S -> Ok(ir.ConvertS(ir.W64, ir.FW64))
    ast.F64ConvertI64U -> Ok(ir.ConvertU(ir.W64, ir.FW64))
    // 0xB6 / 0xBB: float width changes
    ast.F32DemoteF64 -> Ok(ir.F32DemoteF64)
    ast.F64PromoteF32 -> Ok(ir.F64PromoteF32)
    _ -> Error(Nil)
  }
}

/// The IR result type a `NumOp` produces: integer arith/bit ops yield their width's int;
/// `Clz/Ctz/Popcnt` likewise; all comparisons (integer `IEq…`/`IEqz` and float `FEq…FGe`)
/// yield `i32`; float arith/unary (`FAdd…FCopysign`, `FAbs…FSqrt`) yield their width's float.
fn numop_result_type(op: ir.NumOp) -> ir.ValType {
  case op {
    // integer comparisons → i32
    ir.IEqz(_)
    | ir.IEq(_)
    | ir.INe(_)
    | ir.ILtS(_)
    | ir.ILtU(_)
    | ir.IGtS(_)
    | ir.IGtU(_)
    | ir.ILeS(_)
    | ir.ILeU(_)
    | ir.IGeS(_)
    | ir.IGeU(_) -> ir.TI32
    // float comparisons → i32
    ir.FEq(_) | ir.FNe(_) | ir.FLt(_) | ir.FGt(_) | ir.FLe(_) | ir.FGe(_) ->
      ir.TI32
    // integer arith / bit ops → width's int
    ir.IAdd(w)
    | ir.ISub(w)
    | ir.IMul(w)
    | ir.IDivS(w)
    | ir.IDivU(w)
    | ir.IRemS(w)
    | ir.IRemU(w)
    | ir.IAnd(w)
    | ir.IOr(w)
    | ir.IXor(w)
    | ir.IShl(w)
    | ir.IShrS(w)
    | ir.IShrU(w)
    | ir.IRotl(w)
    | ir.IRotr(w)
    | ir.IClz(w)
    | ir.ICtz(w)
    | ir.IPopcnt(w) -> int_width_ty(w)
    // float arith / unary → width's float
    ir.FAdd(w)
    | ir.FSub(w)
    | ir.FMul(w)
    | ir.FDiv(w)
    | ir.FMin(w)
    | ir.FMax(w)
    | ir.FAbs(w)
    | ir.FNeg(w)
    | ir.FCeil(w)
    | ir.FFloor(w)
    | ir.FTrunc(w)
    | ir.FNearest(w)
    | ir.FSqrt(w)
    | ir.FCopysign(w) -> float_width_ty(w)
  }
}

/// The IR result type a `ConvOp` produces (the target of the conversion). The term-boxing
/// ops never arise from WASM lowering but are mapped defensively so this stays total.
fn convop_result_type(op: ir.ConvOp) -> ir.ValType {
  case op {
    ir.I32WrapI64 -> ir.TI32
    ir.I64ExtendI32S | ir.I64ExtendI32U -> ir.TI64
    ir.I32Extend8S | ir.I32Extend16S -> ir.TI32
    ir.I64Extend8S | ir.I64Extend16S | ir.I64Extend32S -> ir.TI64
    ir.TruncSatS(_, to) | ir.TruncSatU(_, to) -> int_width_ty(to)
    ir.TruncS(_, to) | ir.TruncU(_, to) -> int_width_ty(to)
    ir.ConvertS(_, to) | ir.ConvertU(_, to) -> float_width_ty(to)
    ir.ReinterpretFToI(w) -> fwidth_to_int(w)
    ir.ReinterpretIToF(w) -> iwidth_to_float(w)
    ir.F32DemoteF64 -> ir.TF32
    ir.F64PromoteF32 -> ir.TF64
    ir.BoxInt(_) | ir.BoxFloat(_) -> ir.TTerm
    ir.UnboxInt(w) -> int_width_ty(w)
    ir.UnboxFloat(w) -> float_width_ty(w)
  }
}

/// The IR integer value type for an `IntWidth`.
fn int_width_ty(w: ir.IntWidth) -> ir.ValType {
  case w {
    ir.W32 -> ir.TI32
    ir.W64 -> ir.TI64
  }
}

/// The IR float value type for a `FloatWidth`.
fn float_width_ty(w: ir.FloatWidth) -> ir.ValType {
  case w {
    ir.FW32 -> ir.TF32
    ir.FW64 -> ir.TF64
  }
}

/// The IR integer value type matching a `FloatWidth` (a reinterpret f→i preserves bit
/// width: `FW32`→`TI32`, `FW64`→`TI64`).
fn fwidth_to_int(w: ir.FloatWidth) -> ir.ValType {
  case w {
    ir.FW32 -> ir.TI32
    ir.FW64 -> ir.TI64
  }
}

/// The IR float value type matching an `IntWidth` (a reinterpret i→f preserves bit width:
/// `W32`→`TF32`, `W64`→`TF64`).
fn iwidth_to_float(w: ir.IntWidth) -> ir.ValType {
  case w {
    ir.W32 -> ir.TF32
    ir.W64 -> ir.TF64
  }
}

// ─────────────────────────────── tiny string utilities ───────────────────────────────

/// Split a string into its character pieces (used only for export-name sanitisation).
fn string_to_chars(s: String) -> List(String) {
  string.to_graphemes(s)
}

/// Concatenate a list of strings.
fn string_concat(parts: List(String)) -> String {
  string.concat(parts)
}

/// `True` if `c` is a single `[a-zA-Z0-9_]` character.
fn is_ident_char(c: String) -> Bool {
  case c {
    "_" -> True
    _ ->
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
        c,
      )
  }
}
