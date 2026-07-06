//// The shared, language-neutral intermediate representation — the keystone of 2core.
////
//// A frontend lowers *into* this IR; the middle-end transforms it; the backend
//// (`emit_core`) emits Core Erlang from it. The IR is **structured, functional,
//// administrative normal form (ANF)**: computation is sequenced by `Let`, operands
//// are always atomic `Value`s, and structured control (`Block`/`Loop`/`If`/`Switch`)
//// composes as ordinary expressions. This shape lowers 1:1 onto Core Erlang
//// `let`/`letrec`/`case` + tail calls (see unit 08).
////
//// See `specs/phase-1/00-overview.md` (decisions D5/D6) and the high-level spec §3.
//// The canonical textual form is `specs/phase-1/ir-grammar.md` (the `.ir` grammar,
//// frozen together with these types — D7).
////
//// ## Design decisions baked into these types
////
//// - **D5 — three orthogonal capability axes.** A `Module` declares them
////   independently and never fuses them: the *term* layer (BEAM-native values) is
////   always available; *fixed-width numerics* (`i32/i64/f32/f64`) are opt-in via
////   `uses_numerics`; *linear memory* is a **separate** opt-in via `memory`
////   (`Option(MemoryDecl)`). A numerics-only module sets `memory: None` so it links
////   no memory runtime. Conversions between the term and numeric layers are
////   **explicit IR ops** (`Convert` with a boxing `ConvOp`) — there is no implicit
////   bridging.
//// - **D5 — floats are bit patterns.** Float constants store the **raw IEEE-754 bit
////   pattern** (in an `Int`), never a native BEAM double, because BEAM doubles cannot
////   represent NaN/Infinity. Integer constants store the **raw unsigned bit pattern**
////   in `[0, 2^width)`.
//// - **D6 — IR neutrality.** Operation names are neutral and width-tagged
////   (`IAdd(W32)`, not the WASM opcode string `"i32.add"`). Structured control
////   references **named labels only** — never a numeric branch depth (the WASM
////   frontend resolves `br N` into a named label at the frontend boundary). There is
////   **no operand-stack typing** in the IR; the frontend has already eliminated the
////   stack into named values.
////
//// ## Resolved open questions (unit 01 freeze)
////
//// 1. **Names, not SSA indices.** Locals, params, let-bindings, loop vars, and labels
////    are `String` names (clearer `.ir`, easier debugging). They must be **unique
////    within a function**; the backend alpha-renames to Core Erlang's variable rules,
////    so IR names need only be unique, not Core-legal. The WASM frontend conventionally
////    names params `p0 … p{n-1}` so the `.ir` text and body references line up.
//// 2. **`If` condition is an i32 truth value.** `If.cond` is a `Value` interpreted as
////    an i32 (`0` = false, non-zero = true); the emitter tests `≠ 0`. A future term
////    frontend boxes its condition to an i32; no term-boolean is baked into `If`.
//// 3. **Trapping ops keep the `Expr` clean.** A `Num(IDivS(..), ..)` *yields a value*
////    in the IR. The trap is realised entirely by `emit_core` + `rt_num`'s
////    `Result(Int, TrapReason)`-returning signatures (the emitter `case`s on the
////    result and raises on `Error`). The IR `Expr` type carries no `Result`.
//// 4. **Block/Loop results thread through `Let`.** A block's result list can be bound:
////    `Let(["x"], Block("b", [TI32], ..), body)`. The three Phase-1 acceptance
////    programs (`add`, `sum_to`, `fib`) lower cleanly under this shape — see
////    `test/twocore/ir/strawman_test.gleam`.

import gleam/list
import gleam/option.{type Option}

// ───────────────────────── Module & declarations ─────────────────────────

/// A compilation unit — the top-level IR object that the whole pipeline carries.
///
/// The three capability axes (D5) are independent and never fused:
/// - `uses_numerics`: whether the module uses the low-level `i32/i64/f32/f64` layer.
/// - `memories`: linear memories are opt-in and **separate** from numerics. `[]` means
///   the module links no memory runtime; each `MemoryDecl` in the list declares one
///   memory's sizing, and the list position **is** the memory-index space (H3). A
///   single-memory module is a one-element list; index `0` is the default memory every
///   Phase-1..4 memory node targets, so 32-bit single-memory output is byte-identical.
/// - the term layer is always available (no flag).
///
/// A Phase-1 WASM module sets `uses_numerics: True` and `memories: []`.
///
/// Fields:
/// - `name`: the module's logical name (becomes part of the emitted module name).
/// - `globals`: module-level mutable/immutable global slots.
/// - `imports`: host functions reachable only through `CallHost` (the capability
///   boundary) plus non-function imports (globals/tables/memories — H4) supplied as
///   provided state at instantiation.
/// - `functions`: the module's own defined functions.
/// - `exports`: the externally callable entry points (functions + exported state — H4).
/// - `data_segments`: linear-memory initialisers — active (written into a memory at
///   instantiation) or passive (droppable, consumed by `memory.init`).
/// - `tables`: the module's reference tables (funcref/externref — H1). A `CallIndirect`
///   references one of these by name.
/// - `elements`: element segments — active (written into a table at instantiation),
///   passive (droppable, consumed by `table.init`), or declarative (H2).
/// - `start`: the name of the module's start function (run once at instantiation), or
///   `None`. A trapping start fails instantiation.
pub type Module {
  Module(
    name: String,
    uses_numerics: Bool,
    memories: List(MemoryDecl),
    globals: List(GlobalDecl),
    imports: List(ImportDecl),
    functions: List(Function),
    exports: List(ExportDecl),
    data_segments: List(DataSegment),
    tables: List(TableDecl),
    elements: List(ElementSegment),
    start: Option(String),
    /// The module's own **exception tags** (J2/T2). Each `TagDecl` names an exception class
    /// and its operand signature. `[]` (the default) means the module declares no tags — the
    /// conformance-neutral case, byte-identical to Phase-6. The list position **is** the
    /// tag-index space (as `memories`'s position is the memory-index space), so a `Throw`/`Try`
    /// catch referencing a same-module tag resolves by name (D6 — never a numeric index in the
    /// IR core). Imported tags are declared in `imports` (`ImportTag`), NOT here; `tags` holds
    /// module-DEFINED tags only, exactly as `globals` holds module-defined globals and
    /// `ImportGlobal` the imports.
    tags: List(TagDecl),
  )
}

/// An exception-tag declaration (J2/T2). A tag is a build-controlled exception CLASS carrying a
/// typed payload — the operand `ValType`s the exception transports (spec: a tag's type is a
/// `FuncType` whose results MUST be empty; only `params` are meaningful for an exception tag, so
/// this decl stores JUST the params, NOT a `FuncType` — T2). NEUTRAL: a generic named exception
/// class, not a WASM opcode (D6).
///
/// - `name`: the tag's unique name within the module (referenced by `Throw` and
///   `CatchTag.OnTag`, and by `ExportTag`). Frontend-conventional (`tag0 … tag{n-1}`), like
///   `p0`/global names.
/// - `params`: the operand value types the exception carries. Measured for Porffor:
///   `[TF64, TI32]` (the `(f64, i32)` typed JS value). May be `[]` (a payload-less tag) or any
///   `ValType` list.
pub type TagDecl {
  TagDecl(name: String, params: List(ValType))
}

/// A reference table declaration. Generalizes the Phase-2 funcref-only table with a
/// reference-type tag (H1).
///
/// - `name`: the table's unique name (referenced by `CallIndirect`, `ElementSegment`, and
///   the reference/bulk table ops).
/// - `ref_ty`: the table's element reference type (`FuncRef`/`ExternRef`). Defaults to
///   `FuncRef` — a `FuncRef` table is the Phase-2 table, byte-identical.
/// - `min`: the initial size in entries (≥ 0). Every slot starts as the null reference.
/// - `max`: optional upper bound in entries; `None` means unbounded growth.
pub type TableDecl {
  TableDecl(name: String, ref_ty: RefType, min: Int, max: Option(Int))
}

/// An element segment. GENERALIZES the Phase-2 `ElementSegment(table, offset, funcs)` (H2):
///
/// - `mode`: active (writes a table at instantiation) | passive (a droppable runtime
///   segment consumed by `table.init`; `elem.drop` empties it) | declarative (carries no
///   runtime data; forward-declares `ref.func` targets).
/// - `ref_ty`: the element reference type (`FuncRef`/`ExternRef`).
/// - `init`: the element items, each a **ref-producing constant expression** (`Expr`) —
///   `RefFunc(name)` for a funcref, `Values([ConstNull(ty)])` for a null slot (a `ref.null`
///   reduces to the `ConstNull` value, R1c), and `GlobalGet(name)` / `Values([Const…])` for the
///   other admissible const-init forms. This replaces the Phase-2 `funcs: List(String)`, letting
///   an element carry `externref`s and null slots. An active `FuncRef` segment whose items are
///   all `RefFunc` is the Phase-2 case, lowered byte-identically.
pub type ElementSegment {
  ElementSegment(mode: ElemMode, ref_ty: RefType, init: List(Expr))
}

/// The three element-segment modes (WebAssembly spec §2.5.6).
///
/// - `ElemActive(table, offset)`: written into `table` at the constant `offset` at
///   instantiation (an out-of-bounds active segment traps, `TableOutOfBounds`). The
///   Phase-2 case; byte-identical when `ref_ty = FuncRef` and every item is `RefFunc`.
/// - `ElemPassive`: a droppable runtime segment consumed by `table.init`; `elem.drop`
///   marks it empty (length 0).
/// - `ElemDeclarative`: carries no runtime state; makes `ref.func` targets valid.
pub type ElemMode {
  ElemActive(table: String, offset: Expr)
  ElemPassive
  ElemDeclarative
}

/// Declares one of the module's linear memories (H3). The list position in
/// `Module.memories` is this memory's index.
///
/// - `min_pages`: initial size in 64 KiB WebAssembly pages (≥ 0).
/// - `max_pages`: optional upper bound in pages; `None` means unbounded growth.
/// - `idx_type`: the address width (`Idx32`/`Idx64`, memory64 — H3/R12). Defaults to
///   `Idx32`, the classic 32-bit-indexed memory (byte-identical to Phase-4). `Idx64`'s
///   runtime is deferred to Phase 6 (R12): the axis is frozen so the shape is stable and
///   decode/validate can round-trip a 64-bit memory, but lower/link reject it.
pub type MemoryDecl {
  MemoryDecl(min_pages: Int, max_pages: Option(Int), idx_type: IdxType)
}

/// A memory's address width (H3, memory64). Neutral name (a generic multi-region address
/// width, not a WASM immediate leaked into the IR, H7).
///
/// - `Idx32`: a 32-bit-indexed memory (address operand `i32`, bounds arithmetic 32-bit).
/// - `Idx64`: a 64-bit-indexed memory (address operand `i64`, offsets may exceed 2³²).
///   Runtime deferred to Phase 6 (R12).
pub type IdxType {
  Idx32
  Idx64
}

/// A module-level global variable slot.
///
/// - `name`: unique global name (referenced by `GlobalGet`/`GlobalSet`).
/// - `ty`: the global's value type.
/// - `mutable`: whether `GlobalSet` is permitted; immutable globals are write-once at
///   init.
/// - `init`: the constant initialiser expression evaluated at instantiation.
pub type GlobalDecl {
  GlobalDecl(name: String, ty: ValType, mutable: Bool, init: Expr)
}

/// A module import (H4). `ImportFn` is the capability boundary (host functions reached via
/// `CallHost`); the three state variants are **provided state**, not capabilities — a value
/// the instantiation contract SUPPLIES, whose absence is a link-time failure (fail-closed,
/// H6), never an ambient default. The state variants deliberately key on the WASM
/// `(module, name)` LINK key (not the capability tag), because they must not be conflated
/// with the deny-all `CallHost` boundary.
///
/// - `ImportFn(capability, name, ty)`: a host function — `capability` groups imports for the
///   host policy (deny-all checks this), `name` is the function name, `ty` its signature.
/// - `ImportGlobal(module, name, ty, mutable)`: an imported global of value type `ty`.
/// - `ImportTable(module, name, ref_ty, min, max)`: an imported reference table.
/// - `ImportMemory(module, name, min_pages, max_pages, idx_type)`: an imported linear memory.
pub type ImportDecl {
  ImportFn(capability: String, name: String, ty: FuncType)
  ImportGlobal(module: String, name: String, ty: ValType, mutable: Bool)
  ImportTable(
    module: String,
    name: String,
    ref_ty: RefType,
    min: Int,
    max: Option(Int),
  )
  ImportMemory(
    module: String,
    name: String,
    min_pages: Int,
    max_pages: Option(Int),
    idx_type: IdxType,
  )
  /// An imported exception tag (J2/T2 — the P5 import/export-state pattern). Provided state,
  /// not a capability: its RUNTIME IDENTITY is the exporter's (an exception thrown with the
  /// exporter's tag is caught by a `catch` on this import — spec §4.5.4 tag matching). `params`
  /// is the declared operand signature, link-matched against the provider fail-closed (spec
  /// §3.2). No Phase-1..6 module has one; Porffor (single-module) never imports a tag. The
  /// link-time identity resolution (`ProvidedTag`) is DEFERRED (P7-05/link) — the keystone
  /// freezes the decl shape only.
  ImportTag(module: String, name: String, params: List(ValType))
}

/// Names an externally callable / observable entry point (H4). Functions plus exported
/// state (the spec suite's `(get $m "g")` and `spectest`'s exported table/memory need these).
///
/// - `ExportFn(export_name, fn_name)`: exports the `Function` named `fn_name`.
/// - `ExportGlobal(export_name, global_name)`: exports the global named `global_name`.
/// - `ExportTable(export_name, table_name)`: exports the table named `table_name`.
/// - `ExportMemory(export_name, mem_index)`: exports the memory at index `mem_index` (its
///   position in `Module.memories`).
pub type ExportDecl {
  ExportFn(export_name: String, fn_name: String)
  ExportGlobal(export_name: String, global_name: String)
  ExportTable(export_name: String, table_name: String)
  ExportMemory(export_name: String, mem_index: Int)
  /// Exports the module-defined tag named `tag_name` (J2/T2). Measured: Porffor emits
  /// `(export "0" (tag 0))`, so this arm IS exercised by real output — but the export is
  /// **inert for single-module execution** (nothing imports it), so `emit_core` emits no state
  /// for it (§J).
  ExportTag(export_name: String, tag_name: String)
}

/// A linear-memory data segment (H2). GENERALIZES the Phase-2 `DataSegment(offset, bytes)`.
///
/// - `mode`: active (written into a memory at instantiation) | passive (a droppable runtime
///   value consumed by `memory.init`; `data.drop` empties it).
/// - `bytes`: the raw payload.
pub type DataSegment {
  DataSegment(mode: DataMode, bytes: BitArray)
}

/// The two data-segment modes (WebAssembly spec §2.5.7).
///
/// - `DataActive(mem, offset)`: written into memory index `mem` at the constant `offset` at
///   instantiation (an out-of-bounds segment traps, `MemoryOutOfBounds`). The Phase-2 case
///   is `DataActive(0, offset)`, byte-identical.
/// - `DataPassive`: a droppable runtime value consumed by `memory.init`; `data.drop` marks
///   it empty (length 0).
pub type DataMode {
  DataActive(mem: Int, offset: Expr)
  DataPassive
}

// ───────────────────────────── Types ─────────────────────────────

/// The bit-width of a low-level integer operation: 32 or 64 bits.
pub type IntWidth {
  W32
  W64
}

/// The bit-width of a low-level float operation: 32-bit (`FW32`) or 64-bit (`FW64`).
pub type FloatWidth {
  FW32
  FW64
}

/// A value's type. The low-level numeric types and the boxed term type coexist (D5);
/// conversions between the layers are always explicit (`Convert` with a boxing
/// `ConvOp`).
///
/// - `TI32`/`TI64`: 32/64-bit integers (stored as raw unsigned bit patterns).
/// - `TF32`/`TF64`: 32/64-bit floats (stored as raw IEEE-754 bit patterns).
/// - `TTerm`: a boxed BEAM term (atoms/tuples/lists/… — the home of Phase-2 term
///   frontends).
/// - `TFuncRef`: a function reference (`funcref`, H1). A runtime value is the null sentinel
///   (`rt_ref`, R1) OR the Phase-2 type-tagged table entry `#(FuncType, target)` — a
///   `funcref` value *is* what a table slot already holds, promoted to a first-class value.
///   Produced by `RefFunc`, consumed by `CallIndirect`, stored in `funcref` tables.
/// - `TExternRef`: an opaque host reference (`externref`, H1). A runtime value is the null
///   sentinel OR any BEAM term the host supplies, wrapped `{ref_extern, Term}` (R1). Safe
///   code may hold/pass/store/null-test it but **cannot forge or inspect** it (opacity is
///   the security property, H6). Never callable.
pub type ValType {
  TI32
  TI64
  TF32
  TF64
  TTerm
  TFuncRef
  TExternRef
  /// A 128-bit fixed-width low-level value (`v128`, I1/I2 — Phase 6 keystone). Represented at
  /// runtime as a 16-byte binary (`<<_:128>>`) — the natural BEAM fixed-width byte container
  /// (the BEAM has no 128-bit scalar), consistent with how linear-memory bytes are already
  /// handled. NEUTRAL: a generic 128-bit vector value, not a WASM-only construct (I7) — a
  /// future SIMD-capable frontend reuses it. On the **low-level (numeric) path**, never the term
  /// layer (I2): no implicit bridging to terms (only an explicit boxing `Convert` bridges, as for
  /// i32/i64). Placed AFTER the reference types (S15: keystone placement, consistent) so it falls
  /// to the `_` default of every `ValType` match with a catch-all (it is not a reference type).
  ///
  /// Spec anchor: `v128` is the sole vector type; `vectype = v128 ⊆ valtype`
  /// ([spec §2.3.2 vector types](https://webassembly.github.io/spec/core/syntax/types.html)).
  TV128
  /// An `exnref` (`(ref null exn)`, J2/T9) — a caught-exception handle. A REFERENCE value
  /// (term-layer, like funcref/externref — never the raw-bit numeric path): it flows as a
  /// `Dynamic`, is nullable, and is OPAQUE in Safe mode (holdable/passable/storable/
  /// null-testable/re-throwable, but its underlying BEAM exception is NOT inspectable — H6/J5).
  /// Placed AFTER `TV128` so it falls to the reference/`_` arm of every `ValType` match with a
  /// catch-all; the exhaustive matches gain an explicit `TExnRef` arm. `is_reference_type(TExnRef)
  /// == True`. Maps 1:1 onto `RefType.ExnRef` via `reftype_to_valtype`/`valtype_to_reftype`.
  ///
  /// Spec anchor: `exnref = (ref null exn)`; `exn` is a heap type
  /// ([EH proposal](https://github.com/WebAssembly/exception-handling)).
  TExnRef
}

/// The subset of `ValType` that is a reference type (H1). Used wherever the spec's `reftype`
/// grammar appears: `TableDecl.ref_ty`, `ElementSegment.ref_ty`, `ConstNull(ty)`, an imported
/// table's reftype, and typed `select` (validate/decode only). `FuncRef`/`ExternRef` map 1:1
/// onto `TFuncRef`/`TExternRef`; `reftype_to_valtype`/`valtype_to_reftype` bridge the two
/// spellings so they cannot drift.
pub type RefType {
  FuncRef
  ExternRef
  /// The `exn` heap type's reference (`exnref`, J2/T9). `ConstNull(ExnRef)` is `ref.null exn`;
  /// an exnref table/element/select carries it. Maps 1:1 onto `TExnRef` via
  /// `reftype_to_valtype`. Its runtime box `{ref_exn, Reason}` (T9) is owned by `rt_exn`, reusing
  /// `rt_ref`'s shared null sentinel — the forge-proof reference model.
  ExnRef
}

/// Widen a `RefType` to its `ValType` — `FuncRef → TFuncRef`, `ExternRef → TExternRef`,
/// `ExnRef → TExnRef`.
///
/// - `r`: the reference type.
/// - Returns the corresponding `ValType` reference constructor. Total — never fails.
pub fn reftype_to_valtype(r: RefType) -> ValType {
  case r {
    FuncRef -> TFuncRef
    ExternRef -> TExternRef
    ExnRef -> TExnRef
  }
}

/// Narrow a `ValType` to a `RefType` iff it is a reference type.
///
/// - `t`: the value type to narrow.
/// - Returns `Ok(FuncRef)`/`Ok(ExternRef)`/`Ok(ExnRef)` for `TFuncRef`/`TExternRef`/`TExnRef`;
///   `Error(Nil)` for a non-reference type (`TI32`/`TI64`/`TF32`/`TF64`/`TTerm`/`TV128`). Total —
///   never panics.
pub fn valtype_to_reftype(t: ValType) -> Result(RefType, Nil) {
  case t {
    TFuncRef -> Ok(FuncRef)
    TExternRef -> Ok(ExternRef)
    TExnRef -> Ok(ExnRef)
    _ -> Error(Nil)
  }
}

/// A nameless function signature: the parameter types and the result types.
///
/// Used where names are irrelevant — imports and `call_indirect` type tags. A defined
/// `Function`'s signature is *derived* from its named params via `signature/1` rather
/// than stored, so names and types cannot drift.
pub type FuncType {
  FuncType(params: List(ValType), results: List(ValType))
}

// ───────────────────────────── Functions ─────────────────────────────

/// A function in ANF-with-structured-control.
///
/// Params and locals are NAMED, typed slots — the frontend has already eliminated any
/// operand stack into named values (high-level §8.1).
///
/// Fields:
/// - `name`: the function's unique name within the module.
/// - `params`: named argument slots, in order. Their names let the `.ir` text and the
///   body reference arguments (e.g. `%p0`). The nameless `FuncType` is derived from
///   these via `signature/1`, never stored separately.
/// - `result`: the result types the body yields (0, 1, or many — multi-value).
/// - `locals`: additional named slots used by the body (distinct from `params`).
/// - `body`: the expression whose evaluation produces the function's `result` values
///   (via a `Return`, or a fall-through expression of the right arity).
///
/// All names across `params`, `locals`, and let-bindings/labels must be unique within
/// the function (resolved open question #1).
pub type Function {
  Function(
    name: String,
    params: List(Local),
    result: List(ValType),
    locals: List(Local),
    body: Expr,
  )
}

/// A named, typed value slot (a parameter or a local).
///
/// - `name`: the slot's name, unique within its function.
/// - `ty`: the slot's value type.
pub type Local {
  Local(name: String, ty: ValType)
}

/// Derives the nameless `FuncType` of a defined function from its named params and
/// declared results.
///
/// This is the single source of truth for a function's signature: it is computed from
/// `f.params`/`f.result` rather than stored, so the names and the type can never drift
/// (resolved open question #1). Imports and `call_indirect` use a `FuncType` directly
/// since they have no named params.
///
/// Returns the `FuncType` whose `params` are the param slots' types (in order) and
/// whose `results` are `f.result`. Total — never fails.
pub fn signature(f: Function) -> FuncType {
  FuncType(params: list.map(f.params, fn(l) { l.ty }), results: f.result)
}

// ───────────────────────────── Values ─────────────────────────────

/// An atomic value operand: either a reference to a named binding or an immediate
/// constant. In ANF every operand position holds a `Value`, never a nested
/// computation.
///
/// - `Var(name)`: references a param, local, or let-bound name in scope.
/// - `ConstI32(bits)`/`ConstI64(bits)`: an integer constant stored as its RAW UNSIGNED
///   bit pattern in `[0, 2^width)`.
/// - `ConstF32(bits)`/`ConstF64(bits)`: a float constant stored as its RAW IEEE-754
///   bit pattern in an `Int` (D5 — never a BEAM double, so NaN/Inf/`-0.0` are exact).
/// - `ConstNull(ty)`: the null-reference literal of reftype `ty` — the null sentinel
///   (`rt_ref.null_ref`, R1) as an atomic operand. The static reftype `ty` is carried for
///   validation and the `.ir` text; at runtime there is ONE null sentinel shared by both
///   reftypes (`ref.is_null` is the same test either way). It is what `ref.null t` lowers to
///   (R1c — no separate `RefNull` `Expr`), the default `init` of a `ref.null`-sourced
///   `table.grow`/`table.fill`, and the value a reference-typed element/global constant
///   initialiser const-folds to. Pure (it is a `Value`).
pub type Value {
  Var(name: String)
  ConstI32(bits: Int)
  ConstI64(bits: Int)
  ConstF32(bits: Int)
  ConstF64(bits: Int)
  ConstNull(ty: RefType)
  /// The `v128.const` literal — EXACTLY 16 raw bytes in **little-endian lane layout** (D5:
  /// store the bits, never a decoded lane structure, so every lane value, NaN payload, and
  /// `-0.0` is bit-exact). A `BitArray` of length 16; two equal byte sequences compare `==`
  /// (BEAM binary equality), so v128 constants const-fold / dedup like the other `Const*`.
  /// Pure (it is a `Value`). Invariant (validate/lower/emit uphold it): `bit_size(bytes) == 128`.
  /// This is the analogue of `ConstF32(bits)`'s raw-bit representation, one level wider (I1/I2).
  ConstV128(bytes: BitArray)
  /// A literal BEAM **atom** term (K2, Phase-8 unit 01) — e.g. the booleans `'true'`/`'false'`,
  /// or a dynamic-frontend sentinel. `name` is the atom's logical characters (the backend
  /// quotes/escapes them into a Core `CAtom`). A `TTerm`-typed operand; pure (it is a `Value`,
  /// constructs an immutable term, never traps). **No WASM module produces one** (K7 — additive;
  /// the WASM `validate` surface rejects it, and `lower` never emits it).
  ConstAtom(name: String)
  /// A literal BEAM **binary** term (K2, Phase-8 unit 01) — e.g. a JS string literal. `bytes` is
  /// the raw payload, emitted verbatim as a Core binary literal (byte-exact, like a data-segment
  /// payload). A `TTerm`-typed operand; pure (it is a `Value`). **No WASM module produces one**
  /// (K7 — additive; the WASM `validate` surface rejects it, and `lower` never emits it).
  ConstBinary(bytes: BitArray)
}

// ───────────────────── Expressions (yield value lists) ─────────────────────

/// An expression. Every expression yields a list of 0, 1, or many values
/// (multi-value). Structured-control constructs are expressions too, so they compose
/// under `Let`. The non-returning transfers (`Break`/`Continue`/`Return`/`Trap`) do
/// not fall through — their "result type" is bottom.
///
/// This is administrative normal form: `Let(names, rhs, body)` sequences computation,
/// operands are atomic `Value`s, and the leaves are pure/trapping ops or calls. It
/// maps 1:1 onto Core Erlang `let`/`letrec`/`case` + tail calls (unit 08).
///
/// Variants:
/// - `Values(vs)`: forward existing values unchanged (e.g. a block's tail result).
/// - `Num(op, args)`: a low-level numeric op (neutral, width-tagged — D6). Trapping
///   variants (e.g. `IDivS`) still *yield a value* here; the emitter realises the trap
///   via `rt_num`'s `Result` (resolved open question #3).
/// - `Convert(op, arg)`: a width/sign/layer conversion, including explicit
///   term↔numeric boxing (the only bridge between the value layers, D5).
/// - `TermOp(op, args)`: term construction/destructuring (Phase-2 term layer;
///   lock-now placeholder).
/// - `MemSize`/`MemGrow(delta)`: query / grow linear memory (`memory.size` returns the
///   page count; `memory.grow` returns the previous page count or `-1`).
/// - `MemLoad`/`MemStore`: typed linear-memory access with a static `offset` (Phase-2).
///   `MemLoad` carries a `result` value type (a load's result bit pattern depends on its
///   target width/sign, which `MemAccess` alone cannot express).
/// - `GlobalGet(name)`/`GlobalSet(name, value)`: read/write a module global.
/// - `CallDirect`/`CallIndirect`/`CallHost`: the three first-class call kinds
///   (high-level §3). `CallHost` is THE capability boundary.
/// - `Let(names, rhs, body)`: bind `rhs`'s result values to `names`, then evaluate
///   `body`. The arity of `names` matches the arity of `rhs`'s results.
/// - `Block`/`Loop`/`If`/`Switch`: structured control with **named labels only** (D6).
/// - `Break`/`Continue`/`Return`: non-returning control transfers.
/// - `Trap(reason)`: abort with a typed trap.
/// - `Charge(cost, body)`: the metering hook — charge `cost` fuel, then evaluate
///   `body` (inserted by `ir_lower`, unit 11; D9).
///
/// **Effects (E6).** `MemLoad`, `MemStore`, `MemGrow`, `GlobalGet`, `GlobalSet`, and
/// `CallIndirect` are **side-effecting**: they read and/or write mutable instance state
/// (the per-instance memory/globals/table cell). A future optimizer must treat them as
/// memory barriers — **no** CSE of a load across a store, **no** reordering across a grow,
/// **no** dead-store elimination without an aliasing proof. The remaining `Expr` variants
/// (`Num`/`Convert`/`Values`/structured control/…) are pure. `CallHost` and `Charge` are
/// effectful by their nature (host boundary / fuel) and likewise non-reorderable.
pub type Expr {
  // pure / value-producing ----------------------------------------------------
  /// Forward existing values unchanged (e.g. a block's tail result).
  Values(List(Value))
  /// A low-level numeric op (neutral, width-tagged — D6). Trapping variants yield a
  /// value here; `emit_core` + `rt_num` realise the trap (open question #3).
  Num(op: NumOp, args: List(Value))
  /// Width / sign / layer conversions, including explicit term↔numeric boxing.
  Convert(op: ConvOp, arg: Value)
  /// Term construction / destructuring (Phase-2 term layer; lock-now placeholder).
  TermOp(op: TermOp, args: List(Value))
  // reference layer (H1/H2) — all effectful barriers (§effect) -----------------
  /// `ref.func $f` → a `funcref` to same-module function `fn_name` (the build-controlled
  /// type-tagged closure `#(FuncType, closure)`, R1). Effectful in the barrier sense only
  /// (it materialises instance-linked state); never traps. `fn_name` must be a defined
  /// function. (`ref.null t` is NOT an `Expr` — it lowers to `ConstNull(t)`, R1c.)
  RefFunc(fn_name: String)
  /// `ref.is_null x` → i32 `1` if `x` is the null sentinel, else `0`. Lowers through
  /// `rt_ref.is_null` (R1). Classified as a barrier for the freeze (§effect).
  RefIsNull(arg: Value)
  // table layer (H2) — reference read/write, size/grow/fill, bulk init/copy ----
  /// `table.get` → the reference at `index` in `table`; **traps `TableOutOfBounds`** if
  /// `index ≥ size`.
  TableGet(table: String, index: Value)
  /// `table.set` — write `value` (a reference) at `index`; **traps `TableOutOfBounds`** if
  /// `index ≥ size`.
  TableSet(table: String, index: Value, value: Value)
  /// `table.size` → the table's current size in entries (i32).
  TableSize(table: String)
  /// `table.grow(delta, init)` → the PREVIOUS size, or `-1` if growth fails (exceeds
  /// `max`/cap). New slots are filled with `init` (a reference). Never traps.
  TableGrow(table: String, delta: Value, init: Value)
  /// `table.fill(offset, value, count)` — write `value` into `count` slots from `offset`.
  /// **Eager bounds check → traps `TableOutOfBounds` before any write** if
  /// `offset + count > size` (R10).
  TableFill(table: String, offset: Value, value: Value, count: Value)
  /// `table.init(seg, dst, src, count)` — copy `count` elements from passive element `seg`
  /// (index into `Module.elements`) at `src` into `table` at `dst`. **Eager bounds; trap
  /// before any write** on OOB (either range) or a dropped/short segment (R10). `table` is
  /// the target, `seg` the element-segment index (immediate order pinned by R3).
  TableInit(table: String, seg: Int, dst: Value, src: Value, count: Value)
  /// `table.copy(dst, src, count)` from `src_table` to `dst_table` — **memmove semantics**
  /// (overlap-correct in either direction, R11). **Eager bounds; trap before any write.**
  TableCopy(
    dst_table: String,
    src_table: String,
    dst: Value,
    src: Value,
    count: Value,
  )
  /// `elem.drop(seg)` — mark passive element segment `seg` empty (length 0). Idempotent; a
  /// later `table.init` from it with non-zero `count` traps.
  ElemDrop(seg: Int)
  // linear-memory layer (Phase-2 + H2/H3 bulk & multi-memory) ------------------
  /// `memory.size` on memory `mem` → the current size in 64 KiB pages (an i32).
  /// Side-effecting (observes mutable state; do not CSE across a `MemGrow`). `mem` is the
  /// memory index (default `0`; a single-memory module keeps `mem = 0`, byte-identical).
  MemSize(mem: Int)
  /// `memory.grow(delta_pages)` on memory `mem` → the PREVIOUS size in pages, or `-1` (i32)
  /// on failure (the requested growth exceeds the declared `max_pages` or the Safe cap).
  /// Side-effecting (E6): allocates/zero-fills pages and mutates the memory state.
  MemGrow(mem: Int, delta: Value)
  /// Typed load from memory `mem` at `addr + offset`, yielding a `result`-typed value.
  ///
  /// `op` (a `MemAccess`) carries the access width in bytes and, for sub-word loads, the
  /// sign-extension flag. `result` is the value type the load PRODUCES — required because
  /// `op` alone cannot distinguish `i32.load8_s` from `i64.load8_s`. Side-effecting (E6).
  MemLoad(mem: Int, op: MemAccess, addr: Value, offset: Int, result: ValType)
  /// Typed store of `value` to memory `mem` at `addr + offset`. `op.bytes` is the store
  /// width; `op.signed` is IRRELEVANT for stores and is ignored. Side-effecting (E6); the
  /// evaluation order is addr, then value, then the store.
  MemStore(mem: Int, op: MemAccess, addr: Value, value: Value, offset: Int)
  /// A linear-memory load the optimizer has **proven in-bounds** (Phase-10 range-BCE, N4). Identical
  /// operands + meaning as `MemLoad`, but it carries **no bounds check**: `emit_core` lowers it to
  /// `rt_mem`'s UNCHECKED entry point, which skips the `MemoryOutOfBounds` compare. **Produced ONLY
  /// by the BCE pass**, inside the fast arm of a versioned loop whose runtime range-guard proved the
  /// whole access range in-bounds — a WASM module NEVER produces one (decode/validate/lower never
  /// emit it; the WASM validator surface rejects it). On paged/atomics the unchecked path is
  /// BEAM-safe even on a (guard-impossible) OOB (a caught error → trap, never corruption); on nif it
  /// falls back to the checked path (N5). Side-effecting (reads mutable memory) — a barrier, exactly
  /// like `MemLoad`.
  MemLoadUnchecked(
    mem: Int,
    op: MemAccess,
    addr: Value,
    offset: Int,
    result: ValType,
  )
  /// A linear-memory store the optimizer has **proven in-bounds** (Phase-10 range-BCE, N4). The
  /// unchecked twin of `MemStore` — see `MemLoadUnchecked` for the invariants. Side-effecting
  /// (writes mutable memory); a barrier. Produced ONLY by the BCE pass; a WASM module never
  /// produces one.
  MemStoreUnchecked(
    mem: Int,
    op: MemAccess,
    addr: Value,
    value: Value,
    offset: Int,
  )
  /// `memory.fill(dest, value, count)` on memory `mem` — set `count` bytes from `dest` to
  /// the low byte of `value`. **Eager bounds; trap `MemoryOutOfBounds` before any write** if
  /// `dest + count > bytelen` (R10).
  MemFill(mem: Int, dest: Value, value: Value, count: Value)
  /// `memory.copy` from `src_mem` to `dst_mem` — **memmove semantics** (R11). **Eager
  /// bounds; trap before any write.** (Multi-memory: source and destination may differ.)
  MemCopy(dst_mem: Int, src_mem: Int, dst: Value, src: Value, count: Value)
  /// `memory.init(seg, dst, src, count)` on memory `mem` — copy `count` bytes from passive
  /// data `seg` (index into `Module.data_segments`) at `src` into memory at `dst`. **Eager
  /// bounds; trap before any write** on OOB or a dropped/short segment (R10). `mem` is the
  /// target, `seg` the data-segment index (immediate order pinned by R3).
  MemInit(mem: Int, seg: Int, dst: Value, src: Value, count: Value)
  /// `data.drop(seg)` — mark passive data segment `seg` empty (length 0). Idempotent.
  DataDrop(seg: Int)
  /// Read the named module global's current value.
  GlobalGet(name: String)
  /// Write `value` into the named (mutable) module global.
  GlobalSet(name: String, value: Value)
  // calls (three kinds, all first-class — high-level §3) ----------------------
  /// A direct call to a same-module function by name.
  CallDirect(fn_name: String, args: List(Value))
  /// An indirect call through `table` at `index`, type-checked against `ty`.
  CallIndirect(table: String, index: Value, ty: FuncType, args: List(Value))
  /// THE capability boundary. Both host imports and `own` stdlib lower to this
  /// (high-level §6); `ir_lower` (unit 11) decides each one's fate.
  CallHost(capability: String, name: String, args: List(Value))
  // sequencing ----------------------------------------------------------------
  /// Bind `rhs`'s result values to `names`, then evaluate `body`.
  Let(names: List(String), rhs: Expr, body: Expr)
  // structured control (named labels only — D6) -------------------------------
  /// Forward block. Falling off the end yields `result` values; `Break(label, vs)`
  /// jumps to just after this block with `vs`.
  Block(label: String, result: List(ValType), body: Expr)
  /// Loop carrying named iteration vars. `Continue(label, vs)` re-enters the head
  /// rebinding `params`; `Break(label, vs)` (or fall-through) exits with `result`.
  Loop(
    label: String,
    params: List(LoopParam),
    result: List(ValType),
    body: Expr,
  )
  /// Two-way branch. `cond` is an i32 truth value (`0` = false). Both arms yield
  /// `result`.
  If(cond: Value, result: List(ValType), then_branch: Expr, else_branch: Expr)
  /// Multi-way switch on an integer selector with a mandatory `default` arm. Both the
  /// arms and the default yield `result`.
  Switch(
    selector: Value,
    result: List(ValType),
    arms: List(SwitchArm),
    default: Expr,
  )
  // non-returning control transfers -------------------------------------------
  /// Exit the enclosing block/loop named `label`, yielding `values`.
  Break(label: String, values: List(Value))
  /// Re-enter the enclosing loop named `label`, rebinding its params to `values`.
  Continue(label: String, values: List(Value))
  /// Return `values` from the enclosing function.
  Return(values: List(Value))
  // effects -------------------------------------------------------------------
  /// Abort execution with a typed trap reason (lowered to an `rt_trap` raise).
  Trap(reason: TrapReason)
  /// Metering hook (D9): charge `cost` fuel, then evaluate `body`. Inserted by
  /// `ir_lower` (unit 11).
  Charge(cost: Int, body: Expr)
  // ── Phase-6 SIMD (I1/I2) — six new nodes. Two PURE lane-wise (classify like `Num`, §effect);
  // four SIMD-memory BARRIERS (route through the bounds-checked `rt_mem` seam). ──
  /// A pure lane-wise SIMD op (P6-01 keystone). `args` arity matches `op` (1 unary, 2 binary,
  /// 3 for `VBitselect`; `SSplat` takes a scalar i32/i64/f32/f64-bits value; `SExtractLane*`
  /// yields a scalar; `SReplaceLane` takes v128 + scalar). Yields a `v128` (or an
  /// i32/i64/f32/f64-bits scalar for extract-lane / `VAnyTrue` / `SAllTrue` / `SBitmask`).
  /// PURE (no trap, no state — I3): participates in const-fold / DCE / CSE exactly like a
  /// non-trapping `Num`. `emit_core` (P6-06) maps `op` → a concrete `rt_simd` fn (the binding
  /// chokepoint, like `NumOp → rt_num`).
  Simd(op: SimdOp, args: List(Value))
  /// `i8x16.shuffle` — 16 immediate lane indices (each 0..31), selecting bytes from `a ++ b`
  /// (indices 0..15 pick from `a`, 16..31 from `b`). Kept a DEDICATED node (not a `Simd`
  /// variant) because its 16-element immediate does not fit the uniform `SimdOp` shape. PURE
  /// (a byte permutation over two `Value` operands). Yields a v128.
  SimdShuffle(lanes: List(Int), a: Value, b: Value)
  /// `v128.load` and the splat/extend/zero load family. `kind` (a `SimdLoadKind`) selects the
  /// exact form. Effective address is `addr + offset` (offset a static immediate ≥ 0) on memory
  /// `mem`. **Bounds-checked → traps `MemoryOutOfBounds`** on OOB, before any partial effect
  /// (I6). Yields a v128. NOT pure (reads mutable memory → a barrier like `MemLoad`, §effect).
  /// (`mem` default 0; a single-memory module keeps `mem = 0`, byte-identical.)
  SimdLoad(mem: Int, kind: SimdLoadKind, addr: Value, offset: Int)
  /// `v128.store` — write the 16-byte `value` to memory `mem` at `addr + offset`.
  /// **Bounds-checked → traps `MemoryOutOfBounds`.** NOT pure (writes memory → a barrier).
  SimdStore(mem: Int, addr: Value, value: Value, offset: Int)
  /// `v128.loadN_lane` — load `width` BITS (8/16/32/64, S2) from memory `mem` at `addr + offset`
  /// into lane `lane` of `vec` (the other lanes preserved). **Bounds-checked → traps.** Yields a
  /// v128. NOT pure (reads memory → a barrier).
  SimdLoadLane(
    mem: Int,
    width: Int,
    addr: Value,
    offset: Int,
    lane: Int,
    vec: Value,
  )
  /// `v128.storeN_lane` — store lane `lane` (`width` BITS, 8/16/32/64 — S2) of `vec` to memory
  /// `mem` at `addr + offset`. **Bounds-checked → traps.** NOT pure (writes memory → a barrier).
  SimdStoreLane(
    mem: Int,
    width: Int,
    addr: Value,
    offset: Int,
    lane: Int,
    vec: Value,
  )
  // ── Phase-6 cross-module / imported-function call (S5) ──
  /// A call to an IMPORTED function by its positional function-import `slot` (S5). `slot` counts
  /// function imports only (imports occupy the low funcidx range). `ty` is the import's declared
  /// signature (drives the run-ABI). Distinct from `CallDirect`, which stays **same-module only**
  /// (`apply 'f'/n`): `CallImport` is resolved at LINK TIME to a handed-in closure capability (a
  /// host/`spectest` import routes through the checked `rt_host` dispatch; a cross-module import
  /// routes into the exporting instance) and lowered by `emit_core` (P6-06) to
  /// `link.call_import(closure, args_list)` over the caller's positional import-slot vector — a
  /// CAPABILITY, never an ambient `apply` of a data-named `module:atom` (D3a). Effectful (it is a
  /// call — §effect). No Phase-1..5 module produces this node; P6-05 lowers imported calls to it.
  CallImport(slot: Int, ty: FuncType, args: List(Value))
  // ── Phase-14 cross-module funcref (R1) — a reference-materialising barrier ──
  /// `ref.func $f` where `$f` is an IMPORTED function (R1). A funcref to the imported function at
  /// positional func-import `slot` — the build-controlled type-tagged closure `#(FuncType, closure)`
  /// whose closure routes through the D3a import capability (`link.call_import` over the instance's
  /// func-import vector), rendered by `emit_core` (R14-02). `slot` counts function imports only
  /// (imports occupy the low funcidx range, so `slot == funcidx`); `ty` is the import's declared
  /// signature — the SAME `func_type_term(ty)` renderer `call_indirect`'s guard-3 uses, so a stored
  /// imported funcref structurally type-matches unchanged.
  ///
  /// SHAPE mirrors `CallImport` (a positional func-import slot + the imported `FuncType`); ARM
  /// TREATMENT mirrors `RefFunc` everywhere downstream (a nullary reference construction). It carries
  /// **only** a `slot: Int` and a `ty: FuncType` — no sub-`Expr`, no `Value` operands — so it is a
  /// LEAF in every traversal (collectors pass it through, contributing no `Var` names) and a barrier
  /// in `ir/effect` (materialising instance-linked state → no CSE, no reorder, no DCE). Unlike
  /// `CallImport`, it is NOT a call: it constructs a funcref, dispatches nothing, and writes no
  /// linear memory (so mem-clobber / loop-versioning analyses see it as inert). Introduces NO new
  /// `TrapReason` — building a funcref never traps; the indirect-dispatch guards a stored imported
  /// funcref later feeds reuse the existing `UndefinedElement` / `UninitializedElement` /
  /// `IndirectCallTypeMismatch` reasons. Distinct from `RefFunc`, which keeps its invariant —
  /// `fn_name` names a DEFINED function. Only `lower` of a `ref.func` to an IMPORTED funcidx produces
  /// this node (defined → `RefFunc`). No Phase-1..13 module produces it.
  RefFuncImport(slot: Int, ty: FuncType)
  // ── Phase-13 tail calls (Q1/Q2) — three effectful BOTTOM-TRANSFER barriers, each a sibling of
  // `Return` (control leaves; the rest of the block is unreachable) AND of `CallImport`
  // (Value-only, capability dispatch). Each carries ONLY `Value` operands (no sub-`Expr`), so it
  // is a LEAF in every traversal and a barrier in `ir/effect` — never reordered, hoisted, CSE'd,
  // duplicated, or eliminated (like `Return`/`Trap`/`CallImport`). No new `TrapReason`: the
  // indirect guards reuse the existing element/type reasons, and "call stack exhausted" is not a
  // WASM trap (Q8). No Phase-1..12 module produces these; `lower` (Q13-04) mints them from the new
  // `return_call`/`return_call_indirect` opcodes (Q13-02), so they are inert-by-default (Q6). ──
  /// A DIRECT tail call to same-module function `fn_name` (WASM `return_call $f`). BOTTOM: transfers
  /// control to the callee whose results BECOME this function's results, so the rest of the block is
  /// unreachable (exactly like `Return`). Carries only `Value` `args` (a leaf in every traversal);
  /// an effectful barrier (§effect). `emit_core` (Q13-05) emits it as a GENUINE BEAM tail call — the
  /// direct-call logic forced under `KReturn` — so cross-function tail recursion runs in CONSTANT
  /// stack. Only `lower` of a `return_call` to a DEFINED function produces this node (a
  /// `return_call` to an import produces `ReturnCallImport`). The result-type equality rule (Q13-03
  /// validation) guarantees the callee's results equal the caller's, so the transfer is value-typed.
  ReturnCall(fn_name: String, args: List(Value))
  /// An INDIRECT tail call through `table` at `index`, type-checked against `ty` (WASM
  /// `return_call_indirect`). BOTTOM: the selected callee's results become this function's results
  /// (like `Return`). Carries only `Value` operands (`index` + `args`); an effectful barrier
  /// (§effect). `emit_core` (Q13-05) emits the lookup seam then TAIL-APPLIES the returned target in
  /// the ok-arm — the SAME three fail-closed guards, the same traps (`UndefinedElement` →
  /// `UninitializedElement` → `IndirectCallTypeMismatch`), and the same order as `CallIndirect`, but
  /// in constant stack. `table` is the table NAME (resolved to an absolute tableidx by `emit_core`);
  /// `ty` is the call-site `FuncType` that guard 3 matches structurally.
  ReturnCallIndirect(
    table: String,
    index: Value,
    ty: FuncType,
    args: List(Value),
  )
  /// A tail call to an IMPORTED function by its positional func-import `slot` (WASM `return_call $f`
  /// where `f` resolves to an import). BOTTOM: the import's results become this function's results
  /// (like `Return`). Carries only `Value` `args`; an effectful barrier (§effect). `emit_core`
  /// (Q13-05) reads the linker-built closure from the instance's func-import `slot` and TAIL-APPLIES
  /// `link.call_import(closure, args)` under `KReturn` (D3a — a handed-in capability, never an
  /// ambient `apply`); value-correct with a bounded caller frame (cross-module constant-stack tail
  /// recursion through imports is a documented honest-scope sub-case, Q8). Distinct from `ReturnCall`
  /// (a same-module `apply`) for a clean per-node emit path (mirrors the existing
  /// `CallImport` ≠ `CallDirect` split). `slot` counts function imports only (the low funcidx range);
  /// `ty` is the import's declared signature.
  ReturnCallImport(slot: Int, ty: FuncType, args: List(Value))
  // ── Phase-7 exception handling (J1/J2, INLINE-HANDLER shaped — T1) — three effectful barriers.
  // A generic structured-exception model (throw a value / guard-and-catch by class / re-raise a
  // handle), NOT WASM opcodes (D6). The IR is binary-encoding-neutral: the LEGACY `try/catch`
  // (Porffor) maps 1:1, the MODERN `try_table` maps via a transfer inside each handler
  // (Break/Continue/Return to the target frame), and both lower onto Core Erlang's own
  // inline-handler `try…catch` 1:1 (P7-06). ──
  /// `throw <tag> (args…)` — raise exception `tag` (a same-module `TagDecl` NAME — T4) carrying
  /// `args` as its payload. **Does not return** — bottom, exactly like `Return`/`Trap` (spec
  /// §4.4.9: `throw` transfers control, the rest of the block is unreachable). `args` arity +
  /// types match the tag's `params`. Lowers to `rt_exn.throw_exn(tag_id, payload)` (P7-06/07).
  /// Effectful (a non-local transfer — §effect).
  Throw(tag: String, args: List(Value))
  /// `try result body handlers` — the INLINE-HANDLER exception region (T1). Evaluate `body`; on
  /// a thrown exception, each `CatchHandler` is tried in order: a matching handler runs its
  /// inline `handler` expression (with the tag's payload bound to `payload` names, plus an
  /// `exnref` name if captured); an unmatched exception **propagates** (re-raised). `body`
  /// falling through yields `result`. Lowers to a Core Erlang `try … of <Vs> -> <Vs> catch
  /// C:R:S -> <handler dispatch>` 1:1 (P7-06). Effectful (establishes a handler + alters control
  /// flow — a barrier). Both the legacy `try…catch…end` (Porffor, DIRECT — the handler is the
  /// inline legacy handler) and the modern `try_table` (each clause's `handler` is a
  /// `Break`/`Continue`/`Return` transfer to the resolved target frame) structure into this one
  /// node in lower (P7-05). `result` is the block type the try region produces on normal
  /// completion.
  Try(result: List(ValType), body: Expr, handlers: List(CatchHandler))
  /// `throw_ref <exnref>` — re-raise the exception referenced by the `exnref` value `exnref`
  /// (produced by a `capture_exnref` handler). **Does not return** — bottom (spec §4.4.9). A
  /// null `exnref` traps (`ref.null exn` re-thrown → a trap — validate/emit uphold). Lowers to
  /// `rt_exn.throw_ref(exnref)` (P7-06/07). Effectful (a non-local transfer — §effect).
  /// Porffor-INERT (Porffor never emits it — spec-conformance surface only, T9).
  ThrowRef(exnref: Value)
  // ── Phase-8 native closures (K3/K8, unit 02) — THE HEADLINE. A closure over an
  // enclosing-function local is just a BEAM `fun` here: the exact thing a WASM target (Porffor)
  // cannot build (WASM has no closures, so it must hand-build heap environments — the wall). The
  // backend already emits `CFun`/`apply`, and the BEAM owns the closure's environment, lifetime,
  // and GC (no heap environments, no relooping, no linear memory). NEUTRAL (K1): the calling
  // convention ("captures first, then the `arity` runtime args") is the frontend's — the IR fixes
  // only that shape. No WASM module produces either node (K7 — additive; `lower` never emits one).
  /// Build a native BEAM closure (`fun`) of runtime arity `arity` that closes over the
  /// already-evaluated `captures` and tail-forwards to the same-module function `fn_name`.
  ///
  /// Lowers to a Core Erlang `fun (A_1, …, A_arity) -> apply 'fn_name'/(m+arity)(C_1, …, C_m,
  /// A_1, …, A_arity)` (m = `list.length(captures)`): the captured values are textually PREPENDED
  /// to the fresh runtime params, so the emitted `fun` closes over them by BEAM value capture —
  /// nothing else to do. The direct call reuses the EXACT `apply 'f'/n(…)` shape `CallDirect`
  /// emits (D6/D3a — a static local name, never a new call shape). Result type: `TTerm` (a fun IS
  /// a term).
  ///
  /// - `fn_name`: a DEFINED same-module `Function` whose parameter count MUST equal
  ///   `list.length(captures) + arity` (it receives the captures, then the runtime args). Joins
  ///   the same `UnknownFunction` resolution set as `CallDirect`/`ExportFn`; an undefined name is
  ///   `Error(UnknownFunction)` and an arity disagreement is `Error(ArityMismatch)` at `emit_core`
  ///   — a TYPED backend error, never a panic.
  /// - `captures`: the already-evaluated values the closure captures, in the order `fn_name`
  ///   expects them as its LEADING parameters. May be `[]` (a plain `fun` forwarding all args —
  ///   still valid, just no closed-over values). Immutable captures are the common case and the
  ///   whole headline; a MUTATED JS `let` is captured as an opaque `TTerm` CELL HANDLE by the
  ///   frontend (via `rt_js`), never as an IR-level mutable cell (K1 — out of scope here).
  /// - `arity`: the closure's runtime arity — how many arguments a later `CallClosure` supplies.
  ///   May be `0` (a nullary fun whose body is `apply 'fn_name'/m(captures…)`).
  ///
  /// **Pure** (K8): building a fun over evaluated values reads/writes no state and cannot trap, so
  /// it is a non-barrier — CSE/DCE/hoist are sound (`ir/effect`).
  MakeClosure(fn_name: String, captures: List(Value), arity: Int)
  /// Apply the closure value `callee` (a fun `TTerm` — e.g. produced by `MakeClosure`) to `args`,
  /// yielding the callee's single result value. Result type: `TTerm`.
  ///
  /// Lowers to a Core Erlang `apply <callee> (A_1, …, A_n)` — a native application of a
  /// first-class fun value. NOT `apply(Mod, Fn, Args)` of a data-named `module:atom` (D3a), and
  /// NOT the list-spreading `erlang:apply/2`: `callee` is a value already in hand.
  ///
  /// - `callee`: the fun value to apply (any `TTerm` that is a fun at runtime). Its arity must
  ///   equal `list.length(args)`; a mismatch is a BEAM `badarity` error at RUN time — the IR
  ///   carries no static fun-arity to check (K1: arity is the frontend's calling-convention
  ///   concern). The callee is expected to return exactly one value (the frontend's uniform
  ///   single-result convention).
  /// - `args`: the runtime arguments, in order (`[]` for a nullary closure).
  ///
  /// **Effectful + barrier** (K8): applying a fun transfers control to arbitrary code — the same
  /// class as `CallIndirect`/`CallHost`, so it is never reordered, CSE'd, or eliminated.
  CallClosure(callee: Value, args: List(Value))
  /// Map construction / query / functional update — the BEAM-native immutable map, the substrate a
  /// frontend builds JS objects on (Phase-8 unit 03; K4/K8). Groups all six map ops under one
  /// variant (mirrors `TermOp`, minimal blast radius). All are **`Pure`**: a BEAM map is immutable,
  /// so every op — including the reads — is a total, non-trapping, state-free value transform (see
  /// `MapOp` for per-op arities/lowering). **No WASM module produces one** (K7 — additive).
  MapOp(op: MapOp, args: List(Value))
  // ── Phase-8 term classification + native number arithmetic (K2/K8, unit 06) — the two things a
  // dynamic-language frontend needs to compile HOT arithmetic to NATIVE BEAM code: cheap `TTerm → i32`
  // type guards + native BEAM arithmetic on number terms, so the guarded fast path is plain BEAM ops
  // (no box/unbox, no `rt_js` round-trip) and only the cold JS edge cases deopt to `CallHost("js",…)`.
  // NEUTRAL (K1): general BEAM-value classification/arithmetic, not JS semantics. No WASM module
  // produces any of them (K7 — additive; `lower` never emits one, the WASM corpus stays byte-identical).
  /// A single BEAM **term type guard** — `1` if the argument's runtime term shape matches `kind`,
  /// else `0` (an **i32 truth value**, so it drops straight into `If`/`Switch`). Lowers to
  /// `case 'erlang':'is_<kind>'(X) of 'true' -> 1; 'false' -> 0 end` (the `is_*` BIF for `kind`:
  /// `IsInt`→`is_integer`, `IsFloat`→`is_float`, `IsNumber`→`is_number`, `IsAtom`→`is_atom`,
  /// `IsBinary`→`is_binary`, `IsTuple`→`is_tuple`, `IsMap`→`is_map`, `IsFun`→`is_function`,
  /// `IsList`→`is_list`). Result type `TI32`.
  ///
  /// **Pure** (K8): an `is_*` BIF reads/writes no state, never traps (it is total over ALL terms),
  /// and transfers no control — so it is a non-barrier (CSE/DCE/reorder are sound), exactly like a
  /// non-trapping `Num`. This is the guard the frontend puts in front of a `NumTerm` fast path.
  TermTest(kind: TermKind, arg: Value)
  /// A **dense term classification** of the single argument — one i32 code selecting the term's
  /// runtime shape, for a one-shot `Switch` (cheaper than a chain of `TermTest`s when a frontend
  /// dispatches on "what kind of value is this"). Lowers to a nested `case` over the `is_*` tests
  /// returning the FIXED code: `0=int 1=float 2=atom 3=binary 4=tuple 5=map 6=fun 7=list 8=other`
  /// (this encoding is the ABI — the frontend's `Switch` arms match these numbers; documented in the
  /// handoff). Result type `TI32`.
  ///
  /// **Pure** (K8): the same reasoning as `TermTest` — a composition of total `is_*` BIFs, no state,
  /// no trap, no control transfer, so a non-barrier.
  TermTag(arg: Value)
  /// **Native BEAM arithmetic / comparison on two number terms** (`float()`/`integer()`) — the JS
  /// arithmetic FAST path. Lowers to native BEAM ops (NO box/unbox, NO `rt_js`):
  /// - `NAdd`/`NSub`/`NMul` → `call 'erlang':'+'/'-'/'*'(A, B)` → a **number term** (`TTerm`); BEAM's
  ///   mixed int/float arithmetic and bignums Just Work for the common case.
  /// - `NLt`/`NLe`/`NGt`/`NGe`/`NEq` → `case A </=</>/>=/=:= B of 'true' -> 1; 'false' -> 0 end` → an
  ///   i32 truth value (`TI32`, so it drops into `If`). (`NEq` is BEAM `=:=` on numbers; full JS
  ///   `===`/`==` semantics stay in `rt_js` — this is the *guarded numeric* compare only.)
  /// - **Division / remainder are intentionally OMITTED**: `erlang:'/'` raises `badarith` on `/0` but
  ///   JS `1/0 = Infinity`, so the frontend routes `/`/`%` through `rt_js` (or a later guarded unit).
  ///
  /// **Effectful (K8) — like the trapping `Num` ops.** `NumTerm` can raise `badarith` on a
  /// non-number operand: the frontend guards the operands with `TermTest(IsNumber)` first, but the IR
  /// cannot prove that, so — exactly as the trapping `Num(IDivS/IRemS/…)` variants are classified — it
  /// is a **barrier**, never freely `Pure`: no CSE, no DCE, no reorder that could add/remove/move the
  /// raise (an F2 observable). Correctness first (default effectful).
  NumTerm(op: NumTermOp, lhs: Value, rhs: Value)
}

/// One catch handler of a `Try` region (J2/T1 — the INLINE-HANDLER shape). `on` selects which
/// exceptions this handler catches; when it matches, `handler` (a full `Expr`) is evaluated with
/// the tag's payload bound to the `payload` names (in operand order), plus the captured exnref
/// bound to `exnref`'s name if present.
///
/// The two encodings map onto this ONE shape:
/// - **Legacy `try bt B catch x H end`** (Porffor) → `Try(bt, lower(B), [CatchHandler(OnTag(x),
///   names, None, lower(H))])` — DIRECT; the handler `H` is the inline legacy handler, the tag's
///   operands bound to fresh `names` the handler references. No restructuring / branch
///   renumbering.
/// - **Modern `try_table` clause → label** → `CatchHandler(on, names, exnref?, handler)` where
///   `handler` is the transfer to the target frame: `Break(label, names ++ exnref)` for a block,
///   `Continue(label, …)` for a loop, `Return(…)` for the function frame (P7-05 picks the
///   transfer from the resolved frame kind — this is why `handler` is a full `Expr`, resolving
///   the modern label-clause's target-frame kind without a scope limitation).
///
/// - `on`: the `CatchTag` this handler matches (`OnTag(tag)` or `OnAll`).
/// - `payload`: names the tag's operand values are bound to inside `handler` (empty for `OnAll`,
///   which carries no operand types).
/// - `exnref`: `Some(name)` for the ref-capturing forms (`catch_ref`/`catch_all_ref`) — binds
///   the caught exception as an `exnref` handle inside `handler`; `None` otherwise.
/// - `handler`: the expression evaluated when this handler matches (the inline legacy handler,
///   or the modern transfer to the target frame).
pub type CatchHandler {
  CatchHandler(
    on: CatchTag,
    payload: List(String),
    exnref: Option(String),
    handler: Expr,
  )
}

/// What a `CatchHandler` catches (J2/T4 — tag by NAME, never a numeric index in the IR core).
/// - `OnTag(tag)`: catch exceptions thrown with the same-module tag named `tag` (spec
///   tag-identity match); the tag's payload is bound to the handler's `payload` names.
/// - `OnAll`: catch ANY exception (`catch_all`) — but per spec, **exceptions only, NOT traps** (a
///   trap is re-raised untouched; the emitted handler enforces this via `rt_exn.is_wasm_exn`,
///   P7-06/07). No payload is bound (an all-catch carries no operand types).
pub type CatchTag {
  OnTag(tag: String)
  OnAll
}

// ───────────────────────────── SIMD (Phase-6, I1/I2) ─────────────────────────────

/// The six standardized SIMD lane shapes (spec §2.3.2 / §4.4). Carried by shape-uniform
/// `SimdOp` constructors the way `IntWidth` is carried by `NumOp`. Integer shapes
/// (`I8x16`/`I16x8`/`I32x4`/`I64x2`) serve the integer ops; float shapes (`F32x4`/`F64x2`) the
/// float ops. A shape's lane bit-width is `128 / lane_count`: I8x16→8, I16x8→16, I32x4→32,
/// I64x2→64, F32x4→32, F64x2→64. NEUTRAL (a generic lane-shape tag, not a WASM opcode — D6).
pub type SimdShape {
  I8x16
  I16x8
  I32x4
  I64x2
  F32x4
  F64x2
}

/// Which half of a source vector a widening/extending op consumes (`extend`, `extmul`). `Low`
/// selects lanes `0 .. n/2-1`, `High` selects `n/2 .. n-1` of the source, each promoted to the
/// double-width result shape. Neutral (a generic half-selector, not a WASM opcode string — D6).
pub type SimdHalf {
  Low
  High
}

/// Neutral, shape-and-lane-tagged SIMD lane operations (I2 — never WASM opcode strings, D6).
///
/// The ~236 standardized SIMD instructions collapse to this compact op-enum, carried by the
/// pure `Simd`/`SimdShuffle` `Expr` nodes; `emit_core` (P6-06) maps each `(SimdOp[, shape])` to
/// a concrete `rt_simd` function — the binding chokepoint, exactly like `NumOp → rt_num`. The
/// design discipline (matching `NumOp`): **shape-tag the uniform ops** (one constructor for all
/// applicable lane shapes, like `IAdd(IntWidth)`); **name the genuinely-singular ops** (like
/// `ConvOp.I32WrapI64`); and **tag the uniform-over-a-parameter families** (widen/extend/
/// extmul/pairwise) rather than spell out every opcode string.
///
/// The enum is **permissive** — the shape-tag admits illegal combos (e.g. `SMul(I8x16)` — there
/// is no `i8x16.mul`; `i64x2` has no min/max; `i64x2` comparisons are `eq/ne/lt_s/le_s/gt_s/ge_s`
/// only; `SAvgrU`/`SAddSat*`/`SSubSat*` are `i8x16`/`i16x8` only; `SPopcnt` is `i8x16` only).
/// **`validate` (P6-04) rejects the illegal combinations fail-closed**, and `emit_core` (P6-06)
/// only has a `rt_simd` mapping for the legal ones — exactly as `Num(IAdd(W32))` admits a
/// nonsensical width elsewhere.
///
/// ## Per-lane semantics (held to the spec, not the implementation — I3; 07 must honour)
///
/// - Integer lanes wrap two's-complement at the *lane* width (8/16/32/64), never 128-bit;
///   `SShl`/`SShrS`/`SShrU` take a scalar i32 shift count masked mod the lane bit-width.
/// - Comparisons yield a per-lane mask: all-ones (`-1` in the lane) if true, all-zeros if false.
/// - Saturating ops saturate exactly, never trap (`SAddSat*`, `SSubSat*`, `SNarrow`,
///   `SQ15MulrSatS`, `STruncSat*`) — I3: saturation replaces the overflow trap. `SAvgrU` is the
///   rounding unsigned average `(a + b + 1) >> 1` at lane width.
/// - Float lanes are IEEE-754 with f32x4 rounded to single precision after every op, `FMin`/
///   `FMax` returning the spec NaN / `-0.0` result, `FPMin`/`FPMax` the pseudo-min/max variants,
///   NaN canonicalization/propagation per the SIMD spec (mirrors scalar).
/// - SIMD ops do NOT trap (I3). The only trap on the SIMD surface is the memory-bounds trap on
///   a SIMD load/store, via the `rt_mem` seam (the `SimdLoad*`/`SimdStore*` `Expr` nodes).
pub type SimdOp {
  // ── lane-uniform integer arithmetic (shape ∈ integer shapes) ─────────────────
  /// Lane-wise integer add. `SMul` is illegal for `I8x16` (there is no `i8x16.mul`).
  SAdd(SimdShape)
  SSub(SimdShape)
  SMul(SimdShape)
  SNeg(SimdShape)
  SAbs(SimdShape)
  /// Saturating signed add (I8x16/I16x8 only) — saturates to the signed lane range, never traps.
  SAddSatS(SimdShape)
  /// Saturating unsigned add (I8x16/I16x8 only).
  SAddSatU(SimdShape)
  /// Saturating signed subtract (I8x16/I16x8 only).
  SSubSatS(SimdShape)
  /// Saturating unsigned subtract (I8x16/I16x8 only).
  SSubSatU(SimdShape)
  /// Lane-wise signed minimum (I8x16/I16x8/I32x4).
  SMinS(SimdShape)
  SMinU(SimdShape)
  SMaxS(SimdShape)
  SMaxU(SimdShape)
  /// Rounding unsigned average `(a + b + 1) >> 1` (I8x16/I16x8 only).
  SAvgrU(SimdShape)
  /// Lane-wise shift-left by a scalar i32 count masked mod the lane bit-width.
  SShl(SimdShape)
  SShrS(SimdShape)
  SShrU(SimdShape)
  /// Per-lane population count (I8x16 only).
  SPopcnt(SimdShape)
  // ── lane-uniform comparisons → a v128 MASK (all-ones / all-zeros per lane) ───
  SEq(SimdShape)
  SNe(SimdShape)
  /// Signed/unsigned lane comparisons. The `U` variants are illegal for `I64x2` (no unsigned
  /// i64x2 comparisons in the spec).
  SLtS(SimdShape)
  SLtU(SimdShape)
  SLeS(SimdShape)
  SLeU(SimdShape)
  SGtS(SimdShape)
  SGtU(SimdShape)
  SGeS(SimdShape)
  SGeU(SimdShape)
  // ── v128 bitwise (shape-agnostic — operate on the whole 128 bits) ────────────
  VNot
  VAnd
  VOr
  VXor
  VAndNot
  VBitselect
  // ── boolean reductions / mask ─────────────────────────────────────────────────
  /// `v128.any_true` — over the whole v128 → i32 0/1.
  VAnyTrue
  /// `iNxM.all_true` (integer shapes) → i32 0/1 (all lanes non-zero).
  SAllTrue(SimdShape)
  /// `iNxM.bitmask` (integer shapes) → i32 (the high bit of each lane packed).
  SBitmask(SimdShape)
  // ── lane access / build (immediates ride as fields) ──────────────────────────
  /// scalar → v128 (all lanes = the scalar).
  SSplat(SimdShape)
  /// Extract a full lane (I32x4/I64x2/F32x4/F64x2 — no sign variant; yields the whole lane).
  SExtractLane(shape: SimdShape, lane: Int)
  /// Extract + sign-extend a lane to i32 (I8x16/I16x8).
  SExtractLaneS(shape: SimdShape, lane: Int)
  /// Extract + zero-extend a lane to i32 (I8x16/I16x8).
  SExtractLaneU(shape: SimdShape, lane: Int)
  /// Replace lane `lane` with a scalar (v128 + scalar → v128).
  SReplaceLane(shape: SimdShape, lane: Int)
  // ── float-lane ops (shape ∈ F32x4/F64x2) ─────────────────────────────────────
  // NB: `SF`-prefixed (Simd-Float) — NOT `F`-prefixed — because `NumOp` already defines
  // `FAdd`/`FSub`/…/`FGe` in this same module and Gleam requires module-unique constructor
  // names. A necessary deviation from the unit-doc spelling; semantics are identical.
  SFAdd(SimdShape)
  SFSub(SimdShape)
  SFMul(SimdShape)
  SFDiv(SimdShape)
  SFNeg(SimdShape)
  SFAbs(SimdShape)
  SFSqrt(SimdShape)
  /// Spec `min`/`max` (NaN- and `-0.0`-aware).
  SFMin(SimdShape)
  SFMax(SimdShape)
  /// Pseudo-min/max (`pmin`/`pmax`) — return the second operand when either is NaN, no `-0.0`
  /// special-casing.
  SFPMin(SimdShape)
  SFPMax(SimdShape)
  SFCeil(SimdShape)
  SFFloor(SimdShape)
  SFTrunc(SimdShape)
  SFNearest(SimdShape)
  SFEq(SimdShape)
  SFNe(SimdShape)
  SFLt(SimdShape)
  SFLe(SimdShape)
  SFGt(SimdShape)
  SFGe(SimdShape)
  // ── widen / narrow / extended-multiply / pairwise (TAGGED — Deviation 1) ─────
  /// Saturating narrow of `from` to the half-width shape (I16x8→I8x16, I32x4→I16x8). `signed`
  /// selects the signed vs unsigned saturation range.
  SNarrow(from: SimdShape, signed: Bool)
  /// Extend the `half` of `from` to the double-width shape (I8x16→I16x8, I16x8→I32x4,
  /// I32x4→I64x2). `signed` selects sign vs zero extension. NB: `from` is the SOURCE shape (the
  /// result is the double-width shape) — a slightly different reading than `SAdd(shape)`'s
  /// result-shape tag.
  SExtend(from: SimdShape, half: SimdHalf, signed: Bool)
  /// Extended multiply of the `half` of `from` (same source shapes as `SExtend`).
  SExtMul(from: SimdShape, half: SimdHalf, signed: Bool)
  /// Extended pairwise add of `from` (I8x16→I16x8, I16x8→I32x4).
  SExtAddPairwise(from: SimdShape, signed: Bool)
  // ── conversions (genuinely singular — named like ConvOp) ─────────────────────
  /// f32x4 → i32x4 saturating truncation (signed; never traps).
  STruncSatF32x4S
  STruncSatF32x4U
  /// f64x2 → i32x4 saturating truncation, upper two lanes = 0 (signed).
  STruncSatF64x2SZero
  STruncSatF64x2UZero
  /// i32x4 → f32x4 conversion (signed).
  SConvertF32x4I32x4S
  SConvertF32x4I32x4U
  /// low two i32x4 lanes → f64x2 (signed).
  SConvertF64x2LowI32x4S
  SConvertF64x2LowI32x4U
  /// f64x2 → f32x4 (upper two lanes = 0).
  SDemoteF64x2Zero
  /// low two f32x4 lanes → f64x2.
  SPromoteLowF32x4
  // ── dot / q15 (singular) ─────────────────────────────────────────────────────
  /// `i32x4.dot_i16x8_s` — i16x8·i16x8 → i32x4 (pairwise multiply-add; WRAPS at i32).
  SDotI16x8S
  /// `i16x8.q15mulr_sat_s` — fixed-point rounding multiply, saturating.
  SQ15MulrSatS
  // ── byte swizzle (dynamic; shuffle is a dedicated Expr node) ──────────────────
  /// `i8x16.swizzle` — dynamic byte select; OOB index (≥ 16) → 0.
  SSwizzle
}

/// The v128 memory-load family (spec §5.4.9). Distinguishes the load forms `SimdLoad` carries.
/// All bit-widths are BITS (S2), never bytes.
///
/// - `LoadV128`: a plain 16-byte load.
/// - `LoadSplat(lane_bits)`: load `lane_bits` (8/16/32/64) and splat to all lanes.
/// - `LoadExtend(source_bits, signed)`: load 8 bytes as `source_bits`-wide lanes (8/16/32 →
///   8/4/2 lanes) and sign/zero-extend each to double width (`load8x8`/`load16x4`/`load32x2`).
/// - `LoadZero(lane_bits)`: load `lane_bits` (32/64) into the low lane, zero the rest.
pub type SimdLoadKind {
  LoadV128
  LoadSplat(lane_bits: Int)
  LoadExtend(source_bits: Int, signed: Bool)
  LoadZero(lane_bits: Int)
}

/// A named loop iteration variable with its initial value.
///
/// - `name`: the loop var's name, in scope within the loop body.
/// - `ty`: its value type.
/// - `init`: the value bound on first entry (re-bound by `Continue` thereafter).
pub type LoopParam {
  LoopParam(name: String, ty: ValType, init: Value)
}

/// One arm of a `Switch`: when the selector equals `match`, evaluate `body`.
pub type SwitchArm {
  SwitchArm(match: Int, body: Expr)
}

// ───────────────────────────── Operations ─────────────────────────────

/// Neutral, width-tagged numeric operations (D6 — never WASM opcode strings).
///
/// `emit_core` maps each constructor to a concrete `rt_num` function name (the binding
/// chokepoint, units 06/08). Signed vs unsigned is a fundamental low-level distinction
/// (cf. LLVM `sdiv`/`udiv`), not a WASM-ism. Integer ops take/produce raw unsigned bit
/// patterns; the comparison ops (`IEq` … `IGeU`, `IEqz`) produce an i32 truth value
/// (`0` or `1`). The four `IDivS`/`IDivU`/`IRemS`/`IRemU` are the trapping ops (open
/// question #3). Float ops operate on raw IEEE-754 bit patterns.
pub type NumOp {
  IAdd(IntWidth)
  ISub(IntWidth)
  IMul(IntWidth)
  IDivS(IntWidth)
  IDivU(IntWidth)
  IRemS(IntWidth)
  IRemU(IntWidth)
  IAnd(IntWidth)
  IOr(IntWidth)
  IXor(IntWidth)
  IShl(IntWidth)
  IShrS(IntWidth)
  IShrU(IntWidth)
  IRotl(IntWidth)
  IRotr(IntWidth)
  IClz(IntWidth)
  ICtz(IntWidth)
  IPopcnt(IntWidth)
  IEqz(IntWidth)
  IEq(IntWidth)
  INe(IntWidth)
  ILtS(IntWidth)
  ILtU(IntWidth)
  IGtS(IntWidth)
  IGtU(IntWidth)
  ILeS(IntWidth)
  ILeU(IntWidth)
  IGeS(IntWidth)
  IGeU(IntWidth)
  // floats — binary arithmetic (Phase-1 covered these end-to-end; see unit 06)
  FAdd(FloatWidth)
  FSub(FloatWidth)
  FMul(FloatWidth)
  FDiv(FloatWidth)
  FMin(FloatWidth)
  FMax(FloatWidth)
  // floats — unary (Phase-2). Operate on / produce raw IEEE-754 bit patterns.
  /// `f.abs` — clear the sign bit (magnitude).
  FAbs(FloatWidth)
  /// `f.neg` — flip the sign bit.
  FNeg(FloatWidth)
  /// `f.ceil` — round toward +∞.
  FCeil(FloatWidth)
  /// `f.floor` — round toward −∞.
  FFloor(FloatWidth)
  /// `f.trunc` — round toward zero.
  FTrunc(FloatWidth)
  /// `f.nearest` — round to nearest, ties to even.
  FNearest(FloatWidth)
  /// `f.sqrt` — IEEE square root.
  FSqrt(FloatWidth)
  /// `f.copysign(a, b)` — magnitude of `a` with the sign of `b`.
  FCopysign(FloatWidth)
  // floats — comparisons (Phase-2). Produce an i32 truth value (`0`/`1`).
  /// `f.eq` — ordered equality (NaN compares false).
  FEq(FloatWidth)
  /// `f.ne` — ordered/unordered inequality (NaN compares true).
  FNe(FloatWidth)
  /// `f.lt` — ordered less-than.
  FLt(FloatWidth)
  /// `f.gt` — ordered greater-than.
  FGt(FloatWidth)
  /// `f.le` — ordered less-than-or-equal.
  FLe(FloatWidth)
  /// `f.ge` — ordered greater-than-or-equal.
  FGe(FloatWidth)
}

/// Conversion operations: width/sign changes within the numeric layer, float↔int
/// reinterpretation/truncation, and the explicit term↔numeric boxing bridge (D5).
///
/// - `I32WrapI64`: narrow an i64 to its low 32 bits.
/// - `I64ExtendI32S`/`I64ExtendI32U`: widen an i32 to i64 (sign- or zero-extended).
/// - `I32Extend8S`/`I32Extend16S`/`I64Extend8S`/`I64Extend16S`/`I64Extend32S`:
///   sign-extend a sub-word value within the same width.
/// - `TruncSatS(from, to)`/`TruncSatU(from, to)`: saturating float→int truncation
///   (never traps).
/// - `ReinterpretFToI(w)`/`ReinterpretIToF(w)`: reinterpret the raw bit pattern
///   between a float and an integer of the same width (no value change).
/// - `BoxInt`/`UnboxInt`/`BoxFloat`/`UnboxFloat`: the ONLY bridge between the term
///   layer and the numeric layer (D5) — explicit, never implicit.
/// - `TruncS(from, to)`/`TruncU(from, to)`: TRAPPING float→int truncation (Phase-2),
///   distinct from the saturating `TruncSat*` — traps on NaN/±Inf
///   (`InvalidConversionToInteger`) or out-of-range (`IntOverflow`).
/// - `ConvertS(from, to)`/`ConvertU(from, to)`: int→float conversion (round to nearest,
///   ties to even). Never traps.
/// - `F32DemoteF64`/`F64PromoteF32`: float width changes (narrow f64→f32 with rounding;
///   widen f32→f64 exactly).
pub type ConvOp {
  I32WrapI64
  I64ExtendI32S
  I64ExtendI32U
  I32Extend8S
  I32Extend16S
  I64Extend8S
  I64Extend16S
  I64Extend32S
  TruncSatS(from: FloatWidth, to: IntWidth)
  TruncSatU(from: FloatWidth, to: IntWidth)
  ReinterpretFToI(FloatWidth)
  ReinterpretIToF(IntWidth)
  // explicit term↔numeric boxing (D5) — the only bridge between the layers
  BoxInt(IntWidth)
  UnboxInt(IntWidth)
  BoxFloat(FloatWidth)
  UnboxFloat(FloatWidth)
  // TRAPPING float→int truncation (Phase-2) — distinct from the saturating `TruncSat*`.
  // Traps `InvalidConversionToInteger` on NaN/±Inf and `IntOverflow` when the truncated
  // value is out of the target's range; otherwise truncates toward zero. Because they
  // trap, `emit_core` wires these through `rt_num`'s `Result(Int, TrapReason)` signatures
  // (the `case`-and-`raise` shape), unlike the total `TruncSat*`.
  /// Trapping signed truncation `from` float → `to` int.
  TruncS(from: FloatWidth, to: IntWidth)
  /// Trapping unsigned truncation `from` float → `to` int.
  TruncU(from: FloatWidth, to: IntWidth)
  // int→float conversion (Phase-2) — round to nearest, ties to even. Never traps.
  /// Signed `from` int → `to` float.
  ConvertS(from: IntWidth, to: FloatWidth)
  /// Unsigned `from` int → `to` float.
  ConvertU(from: IntWidth, to: FloatWidth)
  /// `f32.demote_f64` — narrow an f64 to f32 (round to nearest, ties to even).
  F32DemoteF64
  /// `f64.promote_f32` — widen an f32 to f64 (exact).
  F64PromoteF32
}

/// Term-layer operations — the BEAM-native value construction/destructuring surface a
/// dynamic-language frontend lowers to (Phase-8 unit 01; K2/K8). All are **`Pure`** (they
/// construct or inspect immutable BEAM terms — tuples and lists are immutable on the BEAM — so
/// even the reads never trap and never touch mutable instance state). Carried by the `TermOp(op,
/// args)` `Expr`. **No WASM module produces one** (K7 — additive; the WASM `validate` surface
/// rejects them, `lower` never emits them, so the WASM corpus stays byte-identical).
///
/// Arities (validate/frontend uphold; `emit_core` pattern-matches them):
/// - `MakeTuple`: build a tuple from its N `args` (`{V₁,…,Vₙ}`). Result `TTerm`.
/// - `TupleGet(index)`: project the element at 0-based `index` from the single tuple arg
///   (lowers to 1-based `erlang:element/2`). Result `TTerm`. Exactly 1 arg.
/// - `TupleSize`: the arity of the single tuple arg (`erlang:tuple_size/1`). Result `TI32`.
///   Exactly 1 arg.
/// - `MakeCons`: build a cons cell `[H|T]` from exactly 2 args (head, tail). Result `TTerm`.
/// - `ListHead`: the head of the single cons arg (`erlang:hd/1`). Result `TTerm`. Exactly 1 arg.
/// - `ListTail`: the tail of the single cons arg (`erlang:tl/1`). Result `TTerm`. Exactly 1 arg.
/// - `IsEmptyList`: `1` if the single list arg is `[]`, else `0` — an **i32 truth value** (so it
///   drops into `If`/`Switch`). Result `TI32`. Exactly 1 arg.
pub type TermOp {
  MakeTuple
  TupleGet(index: Int)
  MakeCons
  TupleSize
  ListHead
  ListTail
  IsEmptyList
}

/// Map-layer operations — the BEAM-native immutable-map surface a dynamic-language frontend lowers
/// JS objects to (Phase-8 unit 03; K4/K8). A BEAM map is **immutable** (a functional update returns
/// a NEW map), so every op is **`Pure`** (reads never trap, writes never mutate shared state — CSE/
/// DCE/reorder are all sound). Carried by the `MapOp(op, args)` `Expr`. **No WASM module produces
/// one** (K7 — additive; the WASM `validate` surface rejects them, `lower` never emits them, so the
/// WASM corpus stays byte-identical).
///
/// The `args` order is uniformly **map-first** at the IR level (`m, k[, v/default]`); `emit_core`
/// re-orders to the Erlang `maps` calling convention (`Key`, `[Value,]` `Map`). Arities
/// (validate/frontend uphold; `emit_core` pattern-matches them):
/// - `MapNew`: build the empty map `#{}` from **0 args**. Result `TTerm`.
/// - `MapGet`: look up `k` in map `m`, yielding its value, or the explicit `default` when `k` is
///   absent (3 args `[m, k, default]` → `maps:get(K, M, Default)`; a missing key deterministically
///   yields the frontend's `undefined` sentinel — **no BEAM `badkey`**). Result `TTerm`.
/// - `MapPut`: return a NEW map equal to `m` but with `k` bound to `v` (overwriting any prior
///   binding) (3 args `[m, k, v]` → `maps:put(K, V, M)`). Result `TTerm`.
/// - `MapHas`: `1` if `k` is a key of `m`, else `0` — an **i32 truth value** (so it drops into
///   `If`/`Switch`) (2 args `[m, k]` → `maps:is_key(K, M)`). Result `TI32`.
/// - `MapRemove`: return a NEW map equal to `m` with any binding for `k` removed (2 args `[m, k]` →
///   `maps:remove(K, M)`; removing an absent key is a no-op that returns an equal map). Result
///   `TTerm`.
/// - `MapSize`: the number of key/value pairs in `m` (1 arg `[m]` → `maps:size(M)`). Result `TI32`.
pub type MapOp {
  MapNew
  MapGet
  MapPut
  MapHas
  MapRemove
  MapSize
}

/// The nine BEAM **term-shape guards** carried by `TermTest(kind, arg)` (Phase-8 unit 06; K2/K8).
/// Each names an `erlang:is_*` type-test BIF — the guard `emit_core` lowers to a `case … of 'true'
/// -> 1; 'false' -> 0 end` i32 truth value:
/// - `IsInt` → `is_integer`, `IsFloat` → `is_float`, `IsNumber` → `is_number` (integer OR float),
/// - `IsAtom` → `is_atom`, `IsBinary` → `is_binary`, `IsTuple` → `is_tuple`, `IsMap` → `is_map`,
/// - `IsFun` → `is_function`, `IsList` → `is_list`.
/// All are **`Pure`** (an `is_*` BIF is total over every term — never traps, reads/writes no state).
/// NEUTRAL (K1 — general BEAM type tests, not JS `typeof`). **No WASM module produces one** (K7).
pub type TermKind {
  IsInt
  IsFloat
  IsNumber
  IsAtom
  IsBinary
  IsTuple
  IsMap
  IsFun
  IsList
}

/// The eight **native BEAM number-term operations** carried by `NumTerm(op, lhs, rhs)` (Phase-8 unit
/// 06; K2/K8) — the JS-arithmetic fast path on number terms (`float()`/`integer()`).
/// - Arithmetic → a **number term** (`TTerm`): `NAdd` → `erlang:'+'`, `NSub` → `erlang:'-'`,
///   `NMul` → `erlang:'*'`.
/// - Comparison → an **i32 truth value** (`TI32`): `NLt` → `<`, `NLe` → `=<`, `NGt` → `>`,
///   `NGe` → `>=`, `NEq` → `=:=` (exact-equal on numbers).
/// Division/remainder are deliberately absent (they trap on `/0`; the frontend routes `/`/`%` through
/// `rt_js`). Every op is **`Effectful`** — it can raise `badarith` on a non-number operand, so it is
/// classified like the trapping `Num` ops (a barrier). **No WASM module produces one** (K7).
pub type NumTermOp {
  NAdd
  NSub
  NMul
  NLt
  NLe
  NGt
  NGe
  NEq
}

/// Describes a linear-memory access (Phase-2; lock-now).
///
/// - `bytes`: the access width in bytes (1/2/4/8).
/// - `signed`: for sub-word loads, whether the loaded value is sign-extended.
pub type MemAccess {
  MemAccess(bytes: Int, signed: Bool)
}

/// The reason an execution `Trap`s. Lowered to a concrete `rt_trap` raise by the
/// emitter.
///
/// - `IntDivByZero`: integer divide/remainder by zero.
/// - `IntOverflow`: signed `div_s` of `INT_MIN / -1` (the one overflow trap).
/// - `Unreachable`: an explicit unreachable point was executed.
/// - `IndirectCallTypeMismatch`: a `CallIndirect` target's type did not match.
/// - `MemoryOutOfBounds`: a linear-memory access fell outside bounds. Also raised when an
///   active DATA segment is out of bounds at instantiation.
/// - `InvalidConversionToInteger`: a trapping float→int truncation of NaN or ±Inf
///   (distinct from `IntOverflow`, which is the out-of-range case).
/// - `UndefinedElement`: a `CallIndirect` whose table index is out of bounds (runtime).
/// - `UninitializedElement`: a `CallIndirect` to a null / unfilled table slot.
/// - `TableOutOfBounds`: an active ELEMENT segment is out of bounds at instantiation.
/// - `FuelExhausted`: the 2core CPU-fuel resource bound was exhausted (Phase-3, F5). This is
///   OUR policy trap, NOT a WebAssembly spec trap — no `.wasm` operation raises it and no
///   `assert_trap` expects it. It is a **runtime** reason raised only by `rt_meter.charge`
///   when a seeded budget is spent, and is **never emitted as an IR `Trap` node** (no lowering
///   produces `Trap(FuelExhausted)`); it lives in `TrapReason` only so it rides the existing
///   catchable `{wasm_trap, Kind}` channel and surfaces through the run-ABI as an ordinary
///   `Trapped(reason)`.
///
/// ## Phase 6 adds ZERO variants (S8 — argued; keep the exhaustive `spec_trap_message` /
/// `trap_reason_atom` matches untouched)
///
/// - **SIMD lane ops are total** (I3): saturation replaces the overflow trap, there is no SIMD
///   divide-trap, and conversions saturate — so no `Simd`/`SimdShuffle` traps. No variant needed.
/// - **SIMD memory** (`SimdLoad*`/`SimdStore*`) out of bounds reuses `MemoryOutOfBounds` (a SIMD
///   memory access is a linear-memory access — the same bounds trap, routed through the same
///   `rt_mem` seam, address-width-agnostic).
/// - **memory64** (an `Idx64` memory access beyond current size / the page cap) reuses
///   `MemoryOutOfBounds` — it is address-width-agnostic, so memory64 adds no distinct reason.
/// - **Cross-module linking**: an unsatisfied / signature-mismatched function import is a
///   **link-time `ImportError`** (`UnknownImport`/`IncompatibleImportType`, surfaced as
///   `assert_unlinkable`), NOT a runtime `TrapReason`.
///
/// Confirmed against the SIMD + memory64 + linking suites: `"out of bounds memory access"`
/// covers every SIMD/memory64 OOB. If a pinned `.wast` `assert_trap` empirically distinguishes a
/// message this set cannot produce (expected: none), add exactly one variant consciously (10/11).
///
/// ## Phase 7 adds ZERO variants (T8 — a WASM exception is NOT a trap)
///
/// The EH surface (`Throw`/`Try`/`ThrowRef` + `TagDecl` + `exnref`) raises a DISTINCT term class
/// `{wasm_exn, TagId, Payload}` (owned by `rt_exn`), never `{wasm_trap, Kind}`. An **uncaught**
/// exception is a distinct run-ABI outcome (`pipeline.RunResult.UncaughtException` — owned by
/// P7-06), NOT a trap: the spec separates them (`assert_exception ≠ assert_trap`). So the
/// exhaustive `spec_trap_message`/`trap_reason_atom` matches stay untouched. (A null-`throw_ref`
/// trap reuses an EXISTING reason — no new variant.)
pub type TrapReason {
  IntDivByZero
  IntOverflow
  Unreachable
  IndirectCallTypeMismatch
  MemoryOutOfBounds
  InvalidConversionToInteger
  UndefinedElement
  UninitializedElement
  TableOutOfBounds
  FuelExhausted
}
