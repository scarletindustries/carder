//// The decoded WebAssembly module model. Originally the `«WASM-AST»` Phase-1
//// slice (Unit 05); extended by Unit 07 to the full WASM 1.0 surface —
//// `«WASM-AST2»` — adding the table/memory/global/element/data/start sections and
//// the memory, float, and conversion instruction groups consumed by units 08
//// (validate) and 09 (lower). Extended again by **Phase-5 Unit P5-03** to the full
//// standardized surface (minus SIMD) — `«WASM-AST3»` — adding the two MVP
//// reference value types (`funcref`/`externref`), the reference/table/bulk-memory
//// instructions, a per-op memory index (multi-memory), the memory64 address-width
//// axis (`IdxType`; runtime deferred to Phase 6 per R12), the full element-segment
//// (flags 0–7) and data-segment (flags 0/1/2) grammar with passive/declarative
//// modes, the import section (non-function imports), and the datacount section.
//// `«WASM-AST3»` is consumed by units P5-04 (validate), P5-05 (lower), and P5-10
//// (WAT text parser). The AST is deliberately WASM-shaped: a reftype is just the
//// `FuncRef`/`ExternRef` subset of `ValType` (the IR's distinct `RefType` narrowing
//// happens at lower, not here).
////
//// This AST is deliberately **WASM-shaped**: it mirrors the binary format's
//// structure (a flat instruction stream, an operand-stack op set, numeric
//// blocktypes, a funcidx address space). It is the WASM frontend's *private*
//// representation and is NOT the neutral shared IR (`carder/ir`). Unit 10
//// (`validate` + `lower`) consumes this AST: `validate.gleam` reads it as the
//// security boundary, and `lower.gleam` lowers it into the IR. Nothing in this
//// module knows about the IR.
////
//// Threat model: these types are populated by `carder/frontend/wasm/decode`
//// from UNTRUSTED bytes. Every malformation is reported as a typed
//// `DecodeError` (below) — the decoder never panics, `let assert`s, or wraps a
//// value silently (fail-closed, overview D4). This type module is frozen on day
//// 1 so Unit 10 can target it immediately.
////
//// References (WebAssembly core spec, binary format):
////  - modules:      https://webassembly.github.io/spec/core/binary/modules.html
////  - types:        https://webassembly.github.io/spec/core/binary/types.html
////  - instructions: https://webassembly.github.io/spec/core/binary/instructions.html
////  - values:       https://webassembly.github.io/spec/core/binary/values.html

import gleam/option.{type Option}

/// A WebAssembly value type — the four number types, the 128-bit SIMD vector type
/// (Phase 6, `«WASM-AST4»`), the two MVP reference types (Phase 5, `«WASM-AST3»`), and
/// the exception reference type `ExnRef` (Phase 7, `«WASM-AST5»`).
///
/// In the binary format each is a single byte: `i32 = 0x7F`, `i64 = 0x7E`,
/// `f32 = 0x7D`, `f64 = 0x7C`, `v128 = 0x7B`, `funcref = 0x70`, `externref = 0x6F`,
/// **`exnref = 0x69`** (spec binary/types.html#value-types + the exception-handling
/// proposal). `V128` is the low-level 128-bit fixed-width SIMD value (`«WASM-AST4»`) —
/// it is **NOT** a reference type: `decode_reftype` (reftype-only positions) still
/// rejects `0x7B` with `BadHeapType`; only `decode_valtype` accepts it. `ExnRef`, by
/// contrast, **IS** a reference type (`exn`/`0x69` is a legal abstract heaptype), so
/// `decode_reftype` accepts `0x69` (for `ref.null exn`) — an OPAQUE handle to an
/// in-flight/caught exception, structurally like `ExternRef`. There is **no separate
/// `RefType`** in the AST — a reftype is exactly the `FuncRef`/`ExternRef`/`ExnRef`
/// subset of `ValType`, validated positionally by `decode_reftype` (so one
/// `decode_valtype` serves every valtype site). No GC-proposal reftypes. A non-SIMD
/// module never carries `V128` and a non-EH module never carries `ExnRef`, so every
/// existing exhaustive match over `ValType` gains one unreachable-in-practice arm and
/// stays byte-identical (lower maps `V128 → ir.TV128` and `ExnRef → ir.TExnRef`, 1:1
/// like `FuncRef`/`TFuncRef`).
pub type ValType {
  I32
  I64
  F32
  F64
  V128
  FuncRef
  ExternRef
  ExnRef
  /// A GC-proposal reference type `(ref null? ht)` carrying an explicit heap type
  /// and nullability. The legacy `FuncRef`/`ExternRef`/`ExnRef` are the short
  /// spellings of `Ref(RefType(True, HFunc/HExtern/HExn))`; `normalize_reftype`
  /// bridges the two for subtyping. Only the GC decode path produces `Ref(..)`.
  Ref(RefType)
}

/// A reference type: whether it may be null, and the heap type it points at.
pub type RefType {
  RefType(nullable: Bool, heap: HeapType)
}

/// A heap type — what a reference points at. Either one of the built-in abstract
/// types (the roots/leaves of the three type hierarchies) or a concrete type
/// declared in the type section (by index).
pub type HeapType {
  // internal / aggregate hierarchy: any ⊒ eq ⊒ {i31, struct, array} ⊒ none
  HAny
  HEq
  HI31
  HStruct
  HArray
  HNone
  // function hierarchy: func ⊒ nofunc
  HFunc
  HNoFunc
  // extern hierarchy: extern ⊒ noextern
  HExtern
  HNoExtern
  // exception hierarchy (EH proposal): exn ⊒ noexn
  HExn
  HNoExn
  /// A concrete type at this index in the type section (a struct/array/func).
  HConcrete(type_idx: Int)
}

/// The storage type of a struct field or array element. Packed `i8`/`i16` are
/// stored narrow and widened on read (`struct.get_s`/`_u`); anything else is a
/// full value type.
pub type StorageType {
  StVal(ValType)
  StI8
  StI16
}

/// A field of a struct, or the (single) element type of an array: its storage
/// type plus whether it is mutable.
pub type FieldType {
  FieldType(storage: StorageType, mutable: Bool)
}

/// A composite type — the three shapes a defined type can take. Func types keep
/// the existing `FuncType`; structs are an ordered field list; an array is one
/// field type (its element).
pub type CompositeType {
  CtFunc(FuncType)
  CtStruct(fields: List(FieldType))
  CtArray(element: FieldType)
}

/// A defined type in the (now unified) type section: its composite body, an
/// optional declared supertype (a type index it extends), and whether it is
/// `final` (may not itself be subtyped). A plain `(type (func …))` decodes to
/// `DefType(CtFunc(..), None, True)`.
pub type DefType {
  DefType(comp: CompositeType, supertype: Option(Int), final: Bool)
}

/// A final, supertype-less defined type wrapping a func signature — the shape a
/// plain `(type (func …))` decodes to. Convenient for building type sections.
pub fn func_def(ft: FuncType) -> DefType {
  DefType(comp: CtFunc(ft), supertype: option.None, final: True)
}

/// The func type at `idx` in a defined-type list, or `Error(Nil)` if the index is
/// out of range or names a non-func type. Every place that used to index a
/// `List(FuncType)` now goes through this.
pub fn func_type_at(types: List(DefType), idx: Int) -> Result(FuncType, Nil) {
  case list_at(types, idx) {
    Ok(DefType(comp: CtFunc(ft), ..)) -> Ok(ft)
    _ -> Error(Nil)
  }
}

/// The defined type at `idx`, or `Error(Nil)` if out of range.
pub fn def_type_at(types: List(DefType), idx: Int) -> Result(DefType, Nil) {
  list_at(types, idx)
}

fn list_at(xs: List(a), i: Int) -> Result(a, Nil) {
  case i < 0 {
    True -> Error(Nil)
    False ->
      case xs {
        [] -> Error(Nil)
        [x, ..rest] ->
          case i {
            0 -> Ok(x)
            _ -> list_at(rest, i - 1)
          }
      }
  }
}

/// Normalize a value type to its reference-type form, if it is a reference type.
/// Bridges the legacy `FuncRef`/`ExternRef`/`ExnRef` spellings and the general
/// `Ref(..)` form so subtyping has a single representation to reason about.
pub fn normalize_reftype(vt: ValType) -> Result(RefType, Nil) {
  case vt {
    FuncRef -> Ok(RefType(True, HFunc))
    ExternRef -> Ok(RefType(True, HExtern))
    ExnRef -> Ok(RefType(True, HExn))
    Ref(rt) -> Ok(rt)
    _ -> Error(Nil)
  }
}

/// A function type (signature): the parameter value types and the result value
/// types, in order. Phase-1 modules may declare multi-result types (decoded
/// faithfully here); whether a given function/block is *valid* is Unit 10's job.
///
/// - `params`: parameter types, left-to-right. Parameters occupy local indices
///   `0..length(params)-1`.
/// - `results`: result types, in stack order.
pub type FuncType {
  FuncType(params: List(ValType), results: List(ValType))
}

/// A single defined (non-imported) function.
///
/// - `type_idx`: index into the module's `types` vector giving this function's
///   signature. Range `0..length(types)-1` for a valid module (the decoder does
///   not range-check it — that is validation, Unit 10).
/// - `locals`: the **RLE-EXPANDED** list of DECLARED locals only. The binary
///   format run-length-encodes locals as `(count, valtype)` groups; this field
///   holds them already expanded into one `ValType` per local, in declaration
///   order. Parameters are NOT included here: params occupy local indices
///   `0..param_count-1`, and these declared locals follow at
///   `param_count..param_count+length(locals)-1`.
/// - `body`: the flat instruction stream of the function's expression, including
///   the `Else`/`End` markers of any nested `block`/`loop`/`if` AND the
///   function-terminating `End` as the final element.
pub type Func {
  Func(type_idx: Int, locals: List(ValType), body: List(Instr))
}

/// What an export refers to. Phase 1 only ever *resolves* `ExportFunc`, but the
/// binary kind byte may legally be any of these (`0x00`..`0x04`); the decoder
/// records the kind faithfully and leaves use-site checks to Unit 10. Phase 7
/// (`«WASM-AST5»`) adds `ExportTag` (kind byte `0x04`) — an exported exception tag.
pub type ExportKind {
  ExportFunc
  ExportTable
  ExportMemory
  ExportGlobal
  ExportTag
}

/// A single export entry: a UTF-8 name, the kind of thing exported, and its
/// index in the relevant index space.
///
/// - `name`: the export's name, already validated as UTF-8 (the binary form is a
///   length-prefixed, NOT null-terminated, UTF-8 byte string).
/// - `kind`: which index space `index` addresses.
/// - `index`: the index of the exported item within its space.
pub type Export {
  Export(name: String, kind: ExportKind, index: Int)
}

/// The type annotation on a structured control instruction (`block`/`loop`/`if`).
///
/// In the binary format this is encoded as a single signed-LEB of width 33:
///  - `0x40` (decodes to `-64`)        → `BlockEmpty` (no params, no results);
///  - a valtype byte (`-1`..`-4`)      → `BlockVal(_)` (no params, one result);
///  - a non-negative value             → `BlockTypeIdx(_)` (a `types` index, the
///                                        multi-value / with-params form).
pub type BlockType {
  BlockEmpty
  BlockVal(ValType)
  BlockTypeIdx(Int)
}

/// Resizable limits (the shared shape of a memory type and a table type).
///
/// - `min`: the minimum size — memory in 64KiB **pages**, table in **entries**.
///   Decoded as a `u32` LEB128.
/// - `max`: the optional maximum (`None` is the open-ended `0x00` form; `Some(m)`
///   is the `0x01` form). Also a `u32`.
///
/// The spec bound (`min <= max <= range`, `range = 2^16` pages for a memory) is a
/// VALIDATION rule (unit 08), NOT enforced here — decode reads the numbers
/// faithfully even when they violate the limit (a `2^16+1` page count is a valid
/// `u32`, an invalid *limit*).
pub type Limits {
  Limits(min: Int, max: Option(Int))
}

/// A table type (table section, id 4).
///
/// - `elem_type`: the element reference type — `FuncRef` (`0x70`) or `ExternRef`
///   (`0x6F`), guaranteed a reftype by `decode_reftype`. A Phase-4 module's table is
///   `FuncRef` (byte-identical). Tables stay i32-indexed (table64 is out of scope).
/// - `limits`: the resizable size bounds, in entries.
///
/// Validate (unit 04) checks table element ↔ element-segment reftype agreement.
pub type TableType {
  TableType(elem_type: ValType, limits: Limits)
}

/// A memory's address width, from the limits' index-type flag bit (bit 2, `0x04`).
///
/// - `Idx32`: a 32-bit-indexed memory (`i32` addresses, MVP). The default and only
///   value for a Phase-4 module.
/// - `Idx64`: a 64-bit-indexed memory (memory64). Decoded here so a 64-bit memory
///   round-trips and validate can type it, but its runtime is deferred to Phase 6
///   (R12): lower/link reject an `Idx64` memory.
pub type IdxType {
  Idx32
  Idx64
}

/// A memory type (memory section, id 5): resizable `limits` (in 64KiB pages) plus
/// the address width `idx_type` (`Idx64` iff the limits flag set the index-type
/// bit). Validate (unit 04) owns `min <= max <= range` (range = 2^16 pages for
/// `Idx32`, 2^48 for `Idx64`). The shared/threads bit is rejected by the flag
/// decoder and never stored here.
pub type MemType {
  MemType(limits: Limits, idx_type: IdxType)
}

/// A global declaration (global section, id 6).
///
/// - `ty`: the global's value type.
/// - `mutable`: the `mut` byte — `False` for `const` (`0x00`), `True` for `var`
///   (`0x01`).
/// - `init`: the decoded constant-expression instruction list (its terminating
///   `End`/`0x0B` is consumed, NOT stored). Decode is purely structural here; that
///   `init` is a *valid* const-expr (only `t.const` / `global.get` of an immutable
///   imported global) is enforced by validate (unit 08), not decode.
pub type Global {
  Global(ty: ValType, mutable: Bool, init: List(Instr))
}

/// An element segment (element section, id 9; binary flags 0–7 — Phase 5).
///
/// The reference-types proposal generalizes the element grammar along two axes,
/// both modeled here faithfully (lower unifies them into IR3's `init: List(Expr)`):
///
/// - `mode`: active (a target table index + offset const-expr), passive, or
///   declarative.
/// - `ref_ty`: the element reference type (`FuncRef` for the funcidx / elemkind
///   forms, the decoded reftype for the expression forms 5/6/7).
/// - `init`: either a `funcidx` vector (`ElemFuncs`, flags 0–3; each funcidx is an
///   implicit `ref.func`) or a vector of const-expressions (`ElemExprs`, flags 4–7).
///
/// A Phase-4 module's active flag-0 segment is
/// `ElementSegment(ElemActive(0, offset), FuncRef, ElemFuncs(funcs))` (byte-identical).
pub type ElementSegment {
  ElementSegment(mode: ElemMode, ref_ty: ValType, init: ElemInit)
}

/// The three element-segment modes (spec binary/modules.html#element-section).
///
/// - `ElemActive(table, offset)`: written into table `table` at const `offset` at
///   instantiation. Flags 0/4 imply `table 0`; flags 2/6 carry an explicit tableidx.
/// - `ElemPassive`: a droppable runtime value consumed by `table.init`.
/// - `ElemDeclarative`: carries no runtime state; only makes `ref.func` targets valid.
pub type ElemMode {
  ElemActive(table: Int, offset: List(Instr))
  ElemPassive
  ElemDeclarative
}

/// An element segment's init items.
///
/// - `ElemFuncs(funcs)`: the `funcidx` vector (flags 0–3, implicitly funcref; each
///   funcidx denotes a `ref.func`).
/// - `ElemExprs(exprs)`: a vector of const-expressions (flags 4–7), each terminated
///   by its own depth-0 `End` (consumed, not stored) — typically `ref.func x` or
///   `ref.null t`.
pub type ElemInit {
  ElemFuncs(List(Int))
  ElemExprs(List(List(Instr)))
}

/// A data segment (data section, id 11; binary flags 0/1/2 — Phase 5).
///
/// - `mode`: active (a target memory index + offset const-expr) or passive.
/// - `bytes`: the raw payload (`vec(byte)`), as a `BitArray`.
///
/// A Phase-4 module's active flag-0 segment is `DataSegment(DataActive(0, offset),
/// bytes)` (byte-identical). The passive form (flag 1) has no memidx/offset.
pub type DataSegment {
  DataSegment(mode: DataMode, bytes: BitArray)
}

/// The two data-segment modes (spec binary/modules.html#data-section).
///
/// - `DataActive(mem, offset)`: written into memory index `mem` at const `offset` at
///   instantiation. Flag 0 implies `mem 0`; flag 2 carries an explicit memidx (which
///   under multi-memory may be non-zero).
/// - `DataPassive`: a droppable runtime value consumed by `memory.init` (flag 1).
pub type DataMode {
  DataActive(mem: Int, offset: List(Instr))
  DataPassive
}

/// A load/store memory immediate (`memarg`) — extended for multi-memory + memory64.
///
/// - `align`: the log2 alignment EXPONENT with the memidx flag bit (`0x40`) already
///   stripped. NON-SEMANTIC (never affects a result); kept only so validate can
///   enforce `2^align <= access-byte-width`.
/// - `offset`: the static byte offset added to the dynamic address operand. Decoded
///   as a `u64` (the memory64 width); for an i32 memory validate enforces `< 2^32`.
///   Values that fit `u32` decode identically to Phase 4 (conformance-neutral).
/// - `mem`: the memory index — `0` unless bit 6 of the alignment flags was set and
///   an explicit memidx followed. Default `0` → byte-identical to Phase 4.
pub type MemArg {
  MemArg(align: Int, offset: Int, mem: Int)
}

/// One import (import section, id 2 — Phase 5). Binary: `mod:name nm:name
/// d:importdesc` (spec binary/modules.html#import-section).
///
/// - `module`: the two-level import's module (namespace) name.
/// - `name`: the import's field name within `module`.
/// - `desc`: what is imported (function type index / table / memory / global type).
pub type Import {
  Import(module: String, name: String, desc: ImportDesc)
}

/// An import descriptor (the five `importdesc` kinds).
///
/// - `ImportFunc(type_idx)`: `0x00 x:typeidx` — a function of the module's `types[x]`.
/// - `ImportTable(TableType)`: `0x01 tt:tabletype` — a reference table.
/// - `ImportMemory(MemType)`: `0x02 mt:memtype` — a linear memory.
/// - `ImportGlobal(ty, mutable)`: `0x03 t:valtype m:mut` — a global (`mut` `0x00`
///   const / `0x01` var).
/// - `ImportTag(type_idx)`: `0x04 0x00 x:typeidx` — an imported exception tag of
///   `types[x]` (Phase 7, `«WASM-AST5»`). The `0x00` attribute byte is checked and
///   dropped by decode (a non-`0x00` attribute is `Error(BadTagAttribute)`); only the
///   tag's `type_idx` is stored.
///
/// Decode records declarations only; link/instantiation (unit 09) resolves them
/// fail-closed. An importdesc byte outside `0x00..0x04` is `BadImportKind`.
pub type ImportDesc {
  ImportFunc(type_idx: Int)
  ImportTable(TableType)
  ImportMemory(MemType)
  ImportGlobal(ty: ValType, mutable: Bool)
  ImportTag(type_idx: Int)
}

/// A tag declaration (tag section, id 13; Phase 7, `«WASM-AST5»`). A tag is an
/// EXCEPTION type: on the wire `attribute:0x00 x:typeidx`. `type_idx` names the tag's
/// `FuncType` in `Module.types`; that functype's PARAMETERS are the exception's operand
/// types (the payload a `throw` of this tag carries) and its RESULTS must be empty
/// (`[t*] → []`) — the empty-results check is validate's (unit 04), not decode's. The
/// `0x00` attribute is consumed + checked by decode (a non-`0x00` byte is
/// `Error(BadTagAttribute)`) and NOT stored; only the exception attribute exists today.
/// Defined tags live in `Module.tags`; IMPORTED tags live in `Module.imports` as
/// `ImportTag` (the tag index space is imported-then-defined, exactly like functions).
pub type Tag {
  Tag(type_idx: Int)
}

/// A whole decoded module.
///
/// - `imported_func_count`: the number of *imported* functions — now COMPUTED by
///   `assemble` as the count of `ImportFunc` importdescs. A `funcidx` addresses the
///   combined space `imports ++ defined`, so the funcidx of defined function `i` is
///   `imported_func_count + i`. For a module with no import section this stays `0`
///   (byte-identical to Phase 4). The imported table/memory/global counts (for the
///   other index spaces) are derivable from `imports` by validate/lower.
/// - `types`: the type section's function types, in declaration order.
/// - `imports`: the import section's entries (section 2), in order.
/// - `tables`: the table section's table types (section 4), in order.
/// - `memories`: the memory section's memory types (section 5), in order.
/// - `globals`: the global section's global declarations (section 6), in order.
/// - `tags`: the tag section's DEFINED exception tags (section 13, ordered between
///   memory (5) and global (6) per the EH proposal), in order. Empty for a non-EH
///   module (byte-identical to Phase 6). Imported tags are NOT here — they live in
///   `imports` as `ImportTag`; the tag index space is `imported tags ++ tags` (the
///   split derived by validate/lower, like the table/memory/global spaces).
/// - `funcs`: the defined functions, in order. `funcs[i]` pairs the function
///   section's `i`-th type index with the code section's `i`-th body.
/// - `start`: the start section's funcidx (section 8), or `None` if absent — run
///   last at instantiation.
/// - `elements`: the element segments (section 9), in order.
/// - `data`: the data segments (section 11), in order.
/// - `data_count`: the datacount section's segment count (section 12), or `None` if
///   absent. Decode owns the wellformedness rules (R13 / spec §5.5.14): a
///   `memory.init`/`data.drop` present with no datacount section is
///   `Error(DataCountMissing)`, and a present `data_count != length(data)` is
///   `Error(DataCountMismatch)`.
/// - `exports`: the export entries, in order.
pub type Module {
  Module(
    imported_func_count: Int,
    /// The type section (id 1), now a unified list of **defined types**
    /// (func/struct/array), flat-indexed. A `typeidx` indexes here; use
    /// `func_type_at` to pull the signature at a func-type index. Rec groups are
    /// flattened into this list (their members occupy consecutive indices).
    types: List(DefType),
    /// The **member count of each recursive type group**, in type-section order
    /// (GC iso-recursive typing). The type section is a sequence of `rectype`s;
    /// this records how many defined types each contributed, so a downstream pass
    /// can recover the rec-group boundaries that `types` (flattened) erased. The
    /// spans partition `types`: group `k` occupies indices
    /// `[sum(rec_groups[..k]), sum(rec_groups[..k]) + rec_groups[k])`. Iso-recursive
    /// canonicalization (identity of a `HConcrete` reference) and type-section
    /// declaration validation both consult these boundaries. `[]` is the **non-GC
    /// default** — every type is treated as its own singleton group (a plain
    /// `(type (func …))` module carries `[]` and behaves byte-identically). It is
    /// also the fallback when `sum(rec_groups) != length(types)` (a defensive
    /// singleton reading), so a stale/absent value can never mis-slice.
    rec_groups: List(Int),
    imports: List(Import),
    tables: List(TableType),
    memories: List(MemType),
    globals: List(Global),
    tags: List(Tag),
    funcs: List(Func),
    start: Option(Int),
    elements: List(ElementSegment),
    data: List(DataSegment),
    data_count: Option(Int),
    exports: List(Export),
  )
}

// ===================== Phase 6 SIMD types («WASM-AST4») =====================

/// The six standardized SIMD lane shapes (spec §2.3.2 — the fixed-width SIMD value
/// interpretations). A shape tags the shape-uniform `SimdOp` constructors the way an
/// integer width tags a numeric op. Integer shapes (`I8x16`/`I16x8`/`I32x4`/`I64x2`)
/// tag the integer lane ops; float shapes (`F32x4`/`F64x2`) tag the float lane ops. A
/// shape's lane bit-width is `128 / lane_count`: `I8x16`→8, `I16x8`→16, `I32x4`→32,
/// `I64x2`→64, `F32x4`→32, `F64x2`→64.
///
/// AST-PRIVATE — the IR has its own `SimdShape`; this spelling mirrors it 1:1 so
/// lower's (P6-05) relabel is mechanical. A `(shape, op)` pair with no standardized
/// opcode (e.g. `SMul(I8x16)`, `SLtU(I64x2)`) is simply never produced by decode; the
/// enum admits it, the wire does not.
pub type SimdShape {
  I8x16
  I16x8
  I32x4
  I64x2
  F32x4
  F64x2
}

/// Which half of a source vector a widening/extending op (`SExtend`/`SExtMul`) consumes.
/// `Low` selects source lanes `0 .. n/2-1`, `High` selects `n/2 .. n-1`, each promoted to
/// the double-width result shape. Mirrors `ir.SimdHalf` 1:1 (lower relabels).
pub type SimdHalf {
  Low
  High
}

/// A single lane-wise SIMD operation, carried by the `Simd(op)` `Instr` (the immediate-
/// bearing SIMD ops get dedicated `Instr`s instead — see `Instr`). AST-PRIVATE; it
/// deliberately mirrors `ir.SimdOp` constructor-for-constructor so lower (P6-05) relabels
/// near-1:1 — the sole spelling difference is the float ops, which are `F`-prefixed here
/// (`FAdd`, …) because this module has no `NumOp` to collide with, whereas the IR must use
/// `SF`-prefixed names (`SFAdd`, …). Every constructor corresponds to one or more `0xFD`
/// sub-opcodes (decode.gleam §D).
///
/// The design (matching `NumOp`): **shape-tag the uniform ops** (one constructor for all
/// applicable lane shapes, like `SAdd(shape)`); **parametrise the widen/narrow/extend/
/// extmul/pairwise families** (`from` = the SOURCE shape, plus `half` and `signed`);
/// **name the genuinely-singular conversions / dot / q15 / swizzle**. Lane indices for
/// extract/replace ride as `lane` fields.
///
/// The enum is **permissive** — the shape-tag admits illegal combinations (e.g.
/// `SMul(I8x16)` — there is no `i8x16.mul`; `i64x2` has no min/max or unsigned compare;
/// `SAvgrU`/`SAddSat*`/`SSubSat*` are `i8x16`/`i16x8` only; `SPopcnt` is `i8x16` only).
/// Decode never emits an illegal combo, and **validate (P6-04) rejects them fail-closed**
/// — exactly the latitude `NumOp` already has.
pub type SimdOp {
  // ── lane-uniform integer arithmetic (integer shapes) ──
  SAdd(SimdShape)
  SSub(SimdShape)
  SMul(SimdShape)
  SNeg(SimdShape)
  SAbs(SimdShape)
  SAddSatS(SimdShape)
  SAddSatU(SimdShape)
  SSubSatS(SimdShape)
  SSubSatU(SimdShape)
  SMinS(SimdShape)
  SMinU(SimdShape)
  SMaxS(SimdShape)
  SMaxU(SimdShape)
  SAvgrU(SimdShape)
  SShl(SimdShape)
  SShrS(SimdShape)
  SShrU(SimdShape)
  SPopcnt(SimdShape)
  // ── lane-uniform comparisons → a v128 mask (all-ones / all-zeros per lane) ──
  SEq(SimdShape)
  SNe(SimdShape)
  SLtS(SimdShape)
  SLtU(SimdShape)
  SLeS(SimdShape)
  SLeU(SimdShape)
  SGtS(SimdShape)
  SGtU(SimdShape)
  SGeS(SimdShape)
  SGeU(SimdShape)
  // ── v128 bitwise (shape-agnostic) + boolean reductions ──
  VNot
  VAnd
  VOr
  VXor
  VAndNot
  VBitselect
  VAnyTrue
  SAllTrue(SimdShape)
  SBitmask(SimdShape)
  // ── lane access / build (lane index rides in the constructor) ──
  SSplat(SimdShape)
  SExtractLane(shape: SimdShape, lane: Int)
  SExtractLaneS(shape: SimdShape, lane: Int)
  SExtractLaneU(shape: SimdShape, lane: Int)
  SReplaceLane(shape: SimdShape, lane: Int)
  // ── float-lane ops (F32x4 / F64x2) ──
  FAdd(SimdShape)
  FSub(SimdShape)
  FMul(SimdShape)
  FDiv(SimdShape)
  FNeg(SimdShape)
  FAbs(SimdShape)
  FSqrt(SimdShape)
  FMin(SimdShape)
  FMax(SimdShape)
  FPMin(SimdShape)
  FPMax(SimdShape)
  FCeil(SimdShape)
  FFloor(SimdShape)
  FTrunc(SimdShape)
  FNearest(SimdShape)
  FEq(SimdShape)
  FNe(SimdShape)
  FLt(SimdShape)
  FLe(SimdShape)
  FGt(SimdShape)
  FGe(SimdShape)
  // ── widen / narrow / extended-multiply / pairwise (parametric — `from` = SOURCE shape) ──
  SNarrow(from: SimdShape, signed: Bool)
  SExtend(from: SimdShape, half: SimdHalf, signed: Bool)
  SExtMul(from: SimdShape, half: SimdHalf, signed: Bool)
  SExtAddPairwise(from: SimdShape, signed: Bool)
  // ── conversions (genuinely singular — named like `ConvOp`) ──
  STruncSatF32x4S
  STruncSatF32x4U
  STruncSatF64x2SZero
  STruncSatF64x2UZero
  SConvertF32x4I32x4S
  SConvertF32x4I32x4U
  SConvertF64x2LowI32x4S
  SConvertF64x2LowI32x4U
  SDemoteF64x2Zero
  SPromoteLowF32x4
  // ── dot / q15 (singular) ──
  SDotI16x8S
  SQ15MulrSatS
  // ── byte swizzle (dynamic; shuffle is a dedicated `Instr`) ──
  SSwizzle
}

/// The v128 memory-LOAD variant carried by a `SimdLoad` (`Instr`). **All bit-widths are
/// in BITS, never bytes (RECONCILIATION S2).** Mirrors `ir.SimdLoadKind`.
///
/// - `LoadV128`: `v128.load` (sub 0) — a plain 16-byte load (the 16 bytes ARE the v128).
/// - `LoadSplat(lane_bits)`: `v128.load{8,16,32,64}_splat` (sub 7..10) — load `lane_bits`
///   ∈ {8,16,32,64} and broadcast to every lane.
/// - `LoadExtend(source_bits, signed)`: `v128.load{8x8,16x4,32x2}_{s,u}` (sub 1..6) — load
///   8 bytes as `source_bits` ∈ {8,16,32}-wide source lanes (8/4/2 of them) and sign-/
///   zero-extend each to double width (`signed` picks the sign).
/// - `LoadZero(lane_bits)`: `v128.load{32,64}_zero` (sub 92,93) — load `lane_bits` ∈
///   {32,64} into the low lane, zero the rest.
pub type SimdLoadKind {
  LoadV128
  LoadSplat(lane_bits: Int)
  LoadExtend(source_bits: Int, signed: Bool)
  LoadZero(lane_bits: Int)
}

/// A single `try_table` catch clause (Phase 7, `«WASM-AST5»`; spec: the EH proposal's
/// `catch` vector). Each clause routes a caught exception to a block LABEL, optionally
/// binding an `exnref`. Decode stores raw `tag`/`label` indices (`u32`); validate (04)
/// resolves + types them. Constructor names mirror the spec keywords 1:1.
///
/// - `Catch(tag, label)`      — kind `0x00`: on a throw of `tag`, push its operands and
///                              branch to `label`.
/// - `CatchRef(tag, label)`   — kind `0x01`: on a throw of `tag`, push its operands AND
///                              an `exnref` for the caught exception, branch to `label`.
/// - `CatchAll(label)`        — kind `0x02`: on ANY throw, branch to `label` (no operands).
/// - `CatchAllRef(label)`     — kind `0x03`: on ANY throw, push an `exnref`, branch to
///                              `label`.
///
/// Wire order for the tag-bearing kinds is `tag` THEN `label` (anti-swap; a swap
/// mis-decodes both indices). A kind byte outside `0x00..0x03` is `Error(BadCatchKind)`.
pub type Catch {
  Catch(tag: Int, label: Int)
  CatchRef(tag: Int, label: Int)
  CatchAll(label: Int)
  CatchAllRef(label: Int)
}

/// A single decoded instruction (one constructor per Phase-1 opcode).
///
/// The constructors are grouped by the binary opcode ranges they decode from
/// (comments give the opcode). Immediates are carried as fields:
///  - branch labels and indices are relative `u32` values (kept as `Int`);
///  - `I32Const`/`I64Const` carry the decoded SIGNED value;
///  - `F32Const`/`F64Const` carry the RAW little-endian IEEE-754 BIT PATTERN as
///    an unsigned `Int` (NEVER a BEAM float — overview D5: BEAM doubles cannot
///    represent NaN/Infinity payloads, so floats are kept as bits end-to-end).
///
/// This is a flat list per `Func.body`; `block`/`loop`/`if` introduce their own
/// `End` (and `if` an optional `Else`) marker into the same stream rather than
/// nesting — structure is recovered by Unit 10.
pub type Instr {
  // --- control (0x00..0x11) ---
  Unreachable
  // 0x00
  Nop
  // 0x01
  Block(BlockType)
  // 0x02
  Loop(BlockType)
  // 0x03
  If(BlockType)
  // 0x04
  Else
  // 0x05
  End
  // 0x0B
  Br(label: Int)
  // 0x0C
  BrIf(label: Int)
  // 0x0D
  BrTable(targets: List(Int), default: Int)
  // 0x0E
  Return
  // 0x0F
  Call(func: Int)
  // 0x10
  CallIndirect(type_idx: Int, table: Int)
  // 0x11
  /// `return_call $f` (0x12, WASM tail-call proposal). Immediate: one u32 funcidx —
  /// IDENTICAL to `Call`. A BOTTOM transfer (stack-polymorphic like `Return`): the callee's
  /// results become the current function's results. The keystone (Q13-01) adds only the
  /// constructor; **Q13-02 owns the 0x12 decode + the `return_call` WAT keyword.**
  ReturnCall(func: Int)
  /// `return_call_indirect (type $t) $tbl` (0x13, WASM tail-call proposal). Immediates: a u32
  /// typeidx THEN a u32 tableidx — IDENTICAL to `CallIndirect` (field naming ANTI-SWAP:
  /// `type_idx` before `table`). A BOTTOM transfer (stack-polymorphic like `Return`). The
  /// keystone adds only the constructor; **Q13-02 owns the 0x13 decode + the
  /// `return_call_indirect` WAT keyword.**
  ReturnCallIndirect(type_idx: Int, table: Int)

  // --- parametric (0x1A..0x1B) ---
  Drop
  // 0x1A
  Select

  // 0x1B
  // --- variable access (0x20..0x24) ---
  LocalGet(index: Int)
  // 0x20
  LocalSet(index: Int)
  // 0x21
  LocalTee(index: Int)
  // 0x22
  GlobalGet(index: Int)
  // 0x23
  GlobalSet(index: Int)

  // 0x24
  // --- constants (0x41..0x44) ---
  I32Const(value: Int)
  // 0x41 (signed-LEB s32)
  I64Const(value: Int)
  // 0x42 (signed-LEB s64)
  F32Const(bits: Int)
  // 0x43 (4 raw LE bytes)
  F64Const(bits: Int)

  // 0x44 (8 raw LE bytes)
  // --- i32 comparisons (0x45..0x4F) ---
  I32Eqz
  I32Eq
  I32Ne
  I32LtS
  I32LtU
  I32GtS
  I32GtU
  I32LeS
  I32LeU
  I32GeS
  I32GeU

  // --- i64 comparisons (0x50..0x5A) ---
  I64Eqz
  I64Eq
  I64Ne
  I64LtS
  I64LtU
  I64GtS
  I64GtU
  I64LeS
  I64LeU
  I64GeS
  I64GeU

  // --- i32 numeric (0x67..0x78) ---
  I32Clz
  I32Ctz
  I32Popcnt
  I32Add
  I32Sub
  I32Mul
  I32DivS
  I32DivU
  I32RemS
  I32RemU
  I32And
  I32Or
  I32Xor
  I32Shl
  I32ShrS
  I32ShrU
  I32Rotl
  I32Rotr

  // --- i64 numeric (0x79..0x8A) ---
  I64Clz
  I64Ctz
  I64Popcnt
  I64Add
  I64Sub
  I64Mul
  I64DivS
  I64DivU
  I64RemS
  I64RemU
  I64And
  I64Or
  I64Xor
  I64Shl
  I64ShrS
  I64ShrU
  I64Rotl
  I64Rotr

  // --- sign extension (0xC0..0xC4) ---
  I32Extend8S
  I32Extend16S
  I64Extend8S
  I64Extend16S
  I64Extend32S

  // --- saturating truncation (0xFC prefix, sub-opcodes 0..7) ---
  I32TruncSatF32S
  // 0xFC 0
  I32TruncSatF32U
  // 0xFC 1
  I32TruncSatF64S
  // 0xFC 2
  I32TruncSatF64U
  // 0xFC 3
  I64TruncSatF32S
  // 0xFC 4
  I64TruncSatF32U
  // 0xFC 5
  I64TruncSatF64S
  // 0xFC 6
  I64TruncSatF64U

  // 0xFC 7
  // --- memory load (0x28..0x35) — each carries a `MemArg` immediate ---
  // The load suffix encodes the access WIDTH and SIGN: e.g. `I32Load8S` reads one
  // byte and sign-extends to i32; `F32Load`/`I32Load` are byte-identical (raw
  // bits). The result width is implied by the constructor (unit 09 maps it).
  I32Load(MemArg)
  // 0x28
  I64Load(MemArg)
  // 0x29
  F32Load(MemArg)
  // 0x2A
  F64Load(MemArg)
  // 0x2B
  I32Load8S(MemArg)
  // 0x2C
  I32Load8U(MemArg)
  // 0x2D
  I32Load16S(MemArg)
  // 0x2E
  I32Load16U(MemArg)
  // 0x2F
  I64Load8S(MemArg)
  // 0x30
  I64Load8U(MemArg)
  // 0x31
  I64Load16S(MemArg)
  // 0x32
  I64Load16U(MemArg)
  // 0x33
  I64Load32S(MemArg)
  // 0x34
  I64Load32U(MemArg)

  // 0x35
  // --- memory store (0x36..0x3E) — each carries a `MemArg` immediate ---
  // `StoreN` writes only the low N bits of the value (sign is irrelevant).
  I32Store(MemArg)
  // 0x36
  I64Store(MemArg)
  // 0x37
  F32Store(MemArg)
  // 0x38
  F64Store(MemArg)
  // 0x39
  I32Store8(MemArg)
  // 0x3A
  I32Store16(MemArg)
  // 0x3B
  I64Store8(MemArg)
  // 0x3C
  I64Store16(MemArg)
  // 0x3D
  I64Store32(MemArg)

  // 0x3E
  // --- memory size/grow (0x3F/0x40) — a `u32` memidx (multi-memory; 0 in the MVP) ---
  MemorySize(mem: Int)
  // 0x3F <memidx> — current size in pages
  MemoryGrow(mem: Int)

  // 0x40 <memidx> — grow by delta pages; result is old size or -1
  // --- float comparisons (0x5B..0x66) → i32 0/1 ---
  F32Eq
  // 0x5B
  F32Ne
  // 0x5C
  F32Lt
  // 0x5D
  F32Gt
  // 0x5E
  F32Le
  // 0x5F
  F32Ge
  // 0x60
  F64Eq
  // 0x61
  F64Ne
  // 0x62
  F64Lt
  // 0x63
  F64Gt
  // 0x64
  F64Le
  // 0x65
  F64Ge

  // 0x66
  // --- f32 numeric (0x8B..0x98): abs neg ceil floor trunc nearest sqrt
  //     add sub mul div min max copysign ---
  F32Abs
  // 0x8B
  F32Neg
  // 0x8C
  F32Ceil
  // 0x8D
  F32Floor
  // 0x8E
  F32Trunc
  // 0x8F
  F32Nearest
  // 0x90
  F32Sqrt
  // 0x91
  F32Add
  // 0x92
  F32Sub
  // 0x93
  F32Mul
  // 0x94
  F32Div
  // 0x95
  F32Min
  // 0x96
  F32Max
  // 0x97
  F32Copysign

  // 0x98
  // --- f64 numeric (0x99..0xA6): same order in f64 ---
  F64Abs
  // 0x99
  F64Neg
  // 0x9A
  F64Ceil
  // 0x9B
  F64Floor
  // 0x9C
  F64Trunc
  // 0x9D
  F64Nearest
  // 0x9E
  F64Sqrt
  // 0x9F
  F64Add
  // 0xA0
  F64Sub
  // 0xA1
  F64Mul
  // 0xA2
  F64Div
  // 0xA3
  F64Min
  // 0xA4
  F64Max
  // 0xA5
  F64Copysign

  // 0xA6
  // --- conversion block (0xA7..0xBF): INT and FLOAT interleaved — DO NOT split ---
  // The trapping `Trunc*` here are DISTINCT from the saturating `TruncSat*`
  // (0xFC) above (same source/target, different overflow/NaN behaviour).
  I32WrapI64
  // 0xA7
  I32TruncF32S
  // 0xA8 (trapping)
  I32TruncF32U
  // 0xA9 (trapping)
  I32TruncF64S
  // 0xAA (trapping)
  I32TruncF64U
  // 0xAB (trapping)
  I64ExtendI32S
  // 0xAC
  I64ExtendI32U
  // 0xAD
  I64TruncF32S
  // 0xAE (trapping)
  I64TruncF32U
  // 0xAF (trapping)
  I64TruncF64S
  // 0xB0 (trapping)
  I64TruncF64U
  // 0xB1 (trapping)
  F32ConvertI32S
  // 0xB2
  F32ConvertI32U
  // 0xB3
  F32ConvertI64S
  // 0xB4
  F32ConvertI64U
  // 0xB5
  F32DemoteF64
  // 0xB6
  F64ConvertI32S
  // 0xB7
  F64ConvertI32U
  // 0xB8
  F64ConvertI64S
  // 0xB9
  F64ConvertI64U
  // 0xBA
  F64PromoteF32
  // 0xBB
  I32ReinterpretF32
  // 0xBC
  I64ReinterpretF64
  // 0xBD
  F32ReinterpretI32
  // 0xBE
  F64ReinterpretI64

  // 0xBF
  // ===================== GC + function-references proposal =====================
  // --- ref.null with an explicit heap type (0xD0 <heaptype>) ---
  RefNullHt(heap: HeapType)
  // --- typed function references (single-byte / 0xD3..0xD6) ---
  RefEq
  // 0xD3 — pops two eq refs, pushes i32 (1 iff identical)
  RefAsNonNull
  // 0xD4 — asserts non-null (traps on null)
  BrOnNull(label: Int)
  // 0xD5 — branch if null, else keep the (non-null) ref
  BrOnNonNull(label: Int)
  // 0xD6 — branch if non-null (passing the ref), else fall through
  CallRef(type_idx: Int)
  // 0x14 <typeidx> — call through a typed function reference
  ReturnCallRef(type_idx: Int)
  // 0x15 <typeidx> — tail call through a typed function reference
  // --- GC prefix (0xFB) : structs ---
  StructNew(type_idx: Int)
  StructNewDefault(type_idx: Int)
  StructGet(type_idx: Int, field: Int)
  StructGetS(type_idx: Int, field: Int)
  StructGetU(type_idx: Int, field: Int)
  StructSet(type_idx: Int, field: Int)
  // --- GC prefix : arrays ---
  ArrayNew(type_idx: Int)
  ArrayNewDefault(type_idx: Int)
  ArrayNewFixed(type_idx: Int, count: Int)
  ArrayNewData(type_idx: Int, data_idx: Int)
  ArrayNewElem(type_idx: Int, elem_idx: Int)
  ArrayGet(type_idx: Int)
  ArrayGetS(type_idx: Int)
  ArrayGetU(type_idx: Int)
  ArraySet(type_idx: Int)
  ArrayLen
  ArrayFill(type_idx: Int)
  ArrayCopy(dst_type: Int, src_type: Int)
  ArrayInitData(type_idx: Int, data_idx: Int)
  ArrayInitElem(type_idx: Int, elem_idx: Int)
  // --- GC prefix : i31 ---
  RefI31
  I31GetS
  I31GetU
  // --- GC prefix : casts, tests, conversions ---
  RefTest(ref_ty: RefType)
  RefCast(ref_ty: RefType)
  BrOnCast(label: Int, from: RefType, to: RefType)
  BrOnCastFail(label: Int, from: RefType, to: RefType)
  AnyConvertExtern
  ExternConvertAny

  // ===================== Phase 5 («WASM-AST3») =====================
  // --- reference instructions (0xD0..0xD2) — spec binary/instructions §reference ---
  RefNull(ref_ty: ValType)
  // 0xD0 <reftype byte 0x70|0x6F> — the null reference of a reftype
  RefIsNull
  // 0xD1 — pops a ref, pushes i32 (1 iff null)
  RefFunc(func: Int)

  // 0xD2 <funcidx u32> — a funcref to function `func`
  // --- table access (0x25/0x26) ---
  TableGet(table: Int)
  // 0x25 <tableidx u32>
  TableSet(table: Int)

  // 0x26 <tableidx u32>
  // --- typed select (0x1C) — a vec(valtype); untyped `select` is `Select` (0x1B) ---
  SelectT(types: List(ValType))

  // --- 0xFC bulk memory & table (sub-opcodes 8..17) — spec binary/instructions ---
  // Immediate order is WIRE order and security-relevant (R3); the fields are named
  // in the order the bytes appear so a swap is impossible to write accidentally.
  MemoryInit(data: Int, mem: Int)
  // 0xFC 8  — <dataidx> THEN <memidx>
  DataDrop(data: Int)
  // 0xFC 9  — <dataidx>
  MemoryCopy(dst_mem: Int, src_mem: Int)
  // 0xFC 10 — <memidx dst> THEN <memidx src>
  MemoryFill(mem: Int)
  // 0xFC 11 — <memidx>
  TableInit(elem: Int, table: Int)
  // 0xFC 12 — <elemidx> THEN <tableidx>
  ElemDrop(elem: Int)
  // 0xFC 13 — <elemidx>
  TableCopy(dst_table: Int, src_table: Int)
  // 0xFC 14 — <tableidx dst> THEN <tableidx src>
  TableGrow(table: Int)
  // 0xFC 15 — <tableidx>
  TableSize(table: Int)
  // 0xFC 16 — <tableidx>
  TableFill(table: Int)

  // 0xFC 17 — <tableidx>
  // ===================== Phase 6 («WASM-AST4», the 0xFD SIMD family) =====================
  // The ~236 fixed-width SIMD instructions collapse to SEVEN `Instr` constructors (I2): a
  // single `Simd(op)` for the pure lane ops, plus six dedicated nodes for the immediate-
  // bearing / memory ops (a raw 16-byte immediate, 16 shuffle bytes, or a `memarg` are
  // structurally unlike a bare op). Immediate order is WIRE order throughout (decode.gleam
  // §E). `V128` is opaque at the AST — no SIMD instruction grants memory authority except
  // the `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane` family, which carry only a
  // `memarg` routed downstream (06/07) through the bounds-checked `rt_mem` seam (I6).
  /// `v128.const` (0xFD 12) — the 16-byte immediate, stored RAW little-endian (D5: the
  /// bits, never a decoded lane structure, so NaN payloads / `-0.0` survive). `bytes` is
  /// always exactly 16 bytes; a shorter input is `Truncated`.
  V128Const(bytes: BitArray)
  /// A pure lane-wise SIMD op with no wire immediate beyond its identity (arithmetic,
  /// comparisons, bitwise, splat, swizzle, extract/replace-lane — the lane index rides
  /// inside `op` —, conversions, narrow/widen/extend/dot/extmul/extadd/reductions).
  /// Operands come from the operand stack, as for every AST instruction. PURE downstream.
  Simd(op: SimdOp)
  /// `i8x16.shuffle` (0xFD 13) — 16 immediate lane indices (each a raw byte 0..255 on the
  /// wire; validate requires 0..31), selecting bytes from the two v128 operands `a ++ b`
  /// (indices 0..15 pick from `a`, 16..31 from `b`). `lanes` is always length 16; a shorter
  /// input is `Truncated`. Kept a dedicated node: its 16-element immediate does not fit the
  /// uniform `SimdOp` shape.
  I8x16Shuffle(lanes: List(Int))
  /// A v128 memory LOAD (0xFD 0..10, 92, 93): `v128.load`, the `loadN_splat`, the extending
  /// `loadMxK_{s,u}`, and `loadN_zero`. `kind` (a `SimdLoadKind`) selects which; `arg` is
  /// the standard `memarg` (multi-memory bit-6 memidx + `u64` offset already handled — the
  /// same decoder as scalar loads). Routes through the bounds-checked `rt_mem` seam
  /// downstream (06/07) — never a raw term op.
  SimdLoad(kind: SimdLoadKind, arg: MemArg)
  /// `v128.store` (0xFD 11): stores a full 16-byte v128 to memory. `arg` is a `memarg`.
  SimdStore(arg: MemArg)
  /// `v128.loadN_lane` (0xFD 84..87): load `width` BITS (∈ {8,16,32,64} — S2) from memory
  /// into lane `lane` of the v128 operand (the other lanes preserved). `arg` is a `memarg`
  /// decoded FIRST, then the trailing lane byte (§E.4). Validate checks `lane < 128/width`.
  SimdLoadLane(width: Int, arg: MemArg, lane: Int)
  /// `v128.storeN_lane` (0xFD 88..91): store the `width`-BIT (∈ {8,16,32,64} — S2) lane
  /// `lane` of the v128 operand to memory. Fields as `SimdLoadLane` (memarg THEN lane byte).
  SimdStoreLane(width: Int, arg: MemArg, lane: Int)

  // ===================== Phase 7 («WASM-AST5») — exception handling =====================
  // A flat-stream AST carries structured control as opener + markers + `End`, exactly as
  // `Block`/`If`/`Else`/`End` already do. Decode is purely structural (§F.3): the legacy
  // in-stream handler markers are NOT normalized to `try_table` here — lower (05) unifies
  // both surfaces onto the one structured-exception IR.
  // --- modern EH (spec: throw=0x08, throw_ref=0x0A, try_table=0x1F) ---
  /// `throw x` (0x08 + `tagidx`) — throw a new exception of tag `x`, consuming the tag's
  /// operand values from the stack as the payload. Does not return (bottom, like
  /// `Return`/`Unreachable`); NOT a block-opener (no matching `End`). `tag` is a raw
  /// `u32` tagidx; validate resolves it + checks the operands against `types[tag]`. This
  /// opcode is SHARED with the legacy surface (Porffor emits it — §F).
  Throw(tag: Int)
  /// `throw_ref` (0x0A, no immediate) — re-raise the `exnref` on top of the stack. Does
  /// not return. Consumes one `exnref` operand (validate's check); NOT a block-opener.
  ThrowRef
  /// `try_table bt catch*` (0x1F + blocktype + `vec(catch)`) — a BLOCK-OPENER (its body
  /// runs to the matching `End`, exactly like `Block`) that installs `catches` for the
  /// dynamic extent of the body: a thrown exception matching a clause transfers to that
  /// clause's block `label` (binding the payload, and an `exnref` for the `_ref`
  /// clauses); an unmatched exception propagates. `bt` is the body's blocktype;
  /// `catches` is the decoded clause vector (in wire order — the first matching clause
  /// wins, so order is load-bearing).
  TryTable(bt: BlockType, catches: List(Catch))

  // --- legacy EH (MEASURED: what Porffor 0.61.13 actually emits — §F) ---
  /// `try bt` (0x06 + blocktype) — the LEGACY try block-opener. Its body runs to a
  /// `LegacyCatch`/`LegacyCatchAll` handler marker (or straight to `End`), and the whole
  /// construct is closed by `End` OR terminated by `LegacyDelegate`. A block-opener for
  /// depth accounting (§F.2).
  TryLegacy(bt: BlockType)
  /// `catch x` (0x07 + `tagidx`) — a LEGACY in-block handler marker (like `Else` for
  /// `If`): begins the handler for tag `x` within the enclosing `TryLegacy`. NOT an
  /// opener/closer (depth unchanged).
  LegacyCatch(tag: Int)
  /// `catch_all` (0x19, no immediate) — a LEGACY in-block catch-all handler marker.
  LegacyCatchAll
  /// `delegate l` (0x18 + `labelidx`) — LEGACY: terminates the enclosing `TryLegacy`
  /// (a block-CLOSER, replacing its `End`) and delegates any uncaught exception to the
  /// `l`-th enclosing handler. `label` is a raw `u32`.
  LegacyDelegate(label: Int)
  /// `rethrow l` (0x09 + `labelidx`) — LEGACY: re-throw the exception caught by the
  /// `l`-th enclosing `catch`/`catch_all`. Does not return; NOT a block-opener.
  Rethrow(label: Int)
}

/// Every reason the decoder rejects a binary. UNTRUSTED input maps to EXACTLY
/// one of these — never a panic (overview D4). Variants carry enough context to
/// debug where sensible.
///
/// - `BadMagic`: the leading 4 bytes are not `00 61 73 6D` (also covers an input
///   too short to contain the magic).
/// - `BadVersion`: magic is present but the 4 version bytes are not
///   `01 00 00 00`.
/// - `Truncated`: the input ended in the middle of a structure (a section,
///   LEB128 number, name, instruction, or const).
/// - `LebOverflow`: a LEB128 value does not fit its declared width — the
///   terminal byte's bits above the width are set (unsigned), or the unused bits
///   do not all equal the sign bit (signed). Never wraps silently.
/// - `LebTooLong`: a LEB128 number spans more than `ceil(width/7)` bytes.
/// - `SectionOrder`: a non-custom section id is not strictly greater than the
///   previous non-custom section's id.
/// - `SectionSizeMismatch`: a section/code sub-decoder did not consume EXACTLY
///   the declared length (it left bytes inside the slice). The corruption guard.
/// - `TrailingBytes`: bytes remain after the module is fully decoded. Reserved:
///   the greedy section loop instead reports leftover bytes as a more specific
///   error (`Truncated`/`SectionOrder`/…); kept in the vocabulary for Unit 10.
/// - `BadValType`: a value-type byte is not one of `0x7C`..`0x7F`.
/// - `BadFuncTypeForm`: a functype did not begin with the `0x60` tag.
/// - `BadExportKind`: an export kind byte is not `0x00`..`0x03`.
/// - `InvalidUtf8`: an export name's bytes are not valid UTF-8.
/// - `BadBlockType`: a blocktype's signed-LEB(33) is negative but not one of the
///   recognised valtype/empty encodings (`-1`..`-4`, `-64`).
/// - `UnknownOpcode(Int)`: an opcode byte is outside the Phase-1 set (carries the
///   offending byte).
/// - `UnknownSatOpcode(Int)`: a `0xFC`-prefixed sub-opcode is outside `0..7`
///   (carries the offending sub-opcode).
/// - `UnknownSimdOpcode(Int)`: a `0xFD`-prefixed sub-opcode outside the 236 standardized
///   fixed-width SIMD instructions — one of the 20 reserved gaps in `0..255`
///   (decode.gleam §D.7), or a relaxed-SIMD sub-opcode (`>= 256`, deferred). Carries the
///   offending sub-opcode. The SIMD analogue of `UnknownSatOpcode`.
/// - `FuncCodeCountMismatch`: the function section and code section declared
///   different numbers of functions, so their entries cannot be paired. (Spec:
///   the binary module decoding requires the two vectors to have equal length.)
/// - `BadHeapType`: a reftype/heaptype byte (in `ref.null`, a tabletype element, or
///   an element segment's flag-5/6/7 reftype) is not `0x70`/`0x6F` — e.g. a number
///   type, `v128`, or a GC-proposal heaptype (deferred to a later phase).
/// - `BadLimitsFlag`: a limits flag byte is out of scope. For memories `0x00`/`0x01`
///   (Idx32) and `0x04`/`0x05` (Idx64/memory64) are accepted; the shared/threads
///   bits (`0x02`/`0x03`) and `>= 0x06` are rejected. For tables only `0x00`/`0x01`
///   are accepted (table64 out of scope), so a table flag with the idx-type or
///   shared bit is rejected.
/// - `BadMutability`: a global `mut` byte is not `0x00` (const) / `0x01` (var).
/// - `BadElemKind`: an element-segment leading flag is `> 7`, or an `elemkind` byte
///   (flags 1/2/3) is not `0x00` (funcref).
/// - `BadDataKind`: a data-segment leading flag is not `0`/`1`/`2`.
/// - `BadImportKind`: an importdesc kind byte is not `0x00..0x04`.
/// - `DataCountMissing`: a `memory.init`/`data.drop` instruction is present but the
///   module has no datacount section (R13 / spec §5.5.14 "data count section
///   required" — an `assert_malformed`).
/// - `DataCountMismatch`: the datacount section's count does not equal the number of
///   data segments (spec §5.5.14 — an `assert_malformed`).
/// - `BadTagAttribute`: a tag / imported-tag ATTRIBUTE byte is not `0x00` (Phase 7 —
///   the only defined attribute is the exception attribute; spec: `tag ::= 0x00
///   typeidx`). An `assert_malformed`-class error.
/// - `BadCatchKind`: a `try_table` catch-clause KIND byte is not `0x00..0x03` (Phase 7
///   — the catch grammar has exactly the four kinds catch/catch_ref/catch_all/
///   catch_all_ref). An `assert_malformed`-class error.
/// - `BadDelegate`: a LEGACY `delegate` (`0x18`) appears at block depth 0, with no
///   enclosing `try` to terminate (Phase 7 — a well-formed opcode in a mis-nested
///   position). A dedicated error rather than an overloaded `UnknownOpcode`, so the
///   depth-0 `delegate` case is distinguishable from a genuinely-unassigned byte.
pub type DecodeError {
  BadMagic
  BadVersion
  Truncated
  LebOverflow
  LebTooLong
  SectionOrder
  SectionSizeMismatch
  TrailingBytes
  BadValType
  BadFuncTypeForm
  BadExportKind
  InvalidUtf8
  BadBlockType
  UnknownOpcode(Int)
  UnknownSatOpcode(Int)
  UnknownSimdOpcode(Int)
  FuncCodeCountMismatch
  BadHeapType
  BadLimitsFlag
  BadMutability
  BadElemKind
  BadDataKind
  BadImportKind
  DataCountMissing
  DataCountMismatch
  BadTagAttribute
  BadCatchKind
  BadDelegate
  // --- GC proposal ---
  BadCompositeType
  BadStorageType
  BadSubForm
  UnknownGcOpcode(Int)
}
