//// The canonical `.ir` printer (Unit 02).
////
//// Renders a `twocore/ir` `Module` to its **canonical, lossless, deterministic**
//// textual form — the inter-stage contract of the compiler (decision **D7** in
//// `specs/phase-1/00-overview.md`). Any stage can dump its IR with `print_module`
//// and reload it with `twocore/ir/parser.parse_module`; the two satisfy the D7
//// round-trip property `parse(print(m)) == m` for every module `m`.
////
//// ## Canonical-form rules (fixed and deterministic)
////
//// - **One spelling per construct.** The grammar is `specs/phase-1/ir-grammar.md`.
////   Sigils: `%name` locals/let-binders/loop-vars, `$name` labels,
////   `@name` functions/globals/module, `"…"` host/export/capability names.
//// - **Indentation** is a fixed 2 spaces per nesting level (whitespace is not
////   semantically significant — the parser ignores it — but the printer is still
////   deterministic so a given `Module` always prints byte-identically).
//// - **Floats are raw IEEE-754 bit patterns in lower-case, zero-padded `0x`-hex**
////   (`f32.const 0x<8 digits>`, `f64.const 0x<16 digits>`) — NEVER decimals, which
////   would lose f32 rounding and NaN payloads (D5). **Integer** constants print as
////   the stored **unsigned** value in canonical decimal.
//// - **Strict ANF.** Every operand position is an atomic `Value`; computations are
////   named by `let` before use. The printer never nests a computation in an operand.
//// - **Neutral, width-tagged op spellings** (D6): `i.add.32`, `f.add.64`,
////   `i.le_u.64` — never the WASM opcode string `i32.add`. The spelling tables here
////   are the single source of truth shared (by construction) with the parser.
////
//// Every function is total: the type system guarantees the `Module`/`Expr`/… variants,
//// so there is no unprintable value and nothing here panics.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/string_tree
import twocore/ir.{
  type ConvOp, type Expr, type FloatWidth, type FuncType, type Function,
  type IntWidth, type Local, type LoopParam, type MemAccess, type Module,
  type NumOp, type SwitchArm, type TermOp, type TrapReason, type ValType,
  type Value, Block, BoxFloat, BoxInt, Break, CallClosure, CallDirect, CallHost,
  CallIndirect, Charge, ConstF32, ConstF64, ConstI32, ConstI64, Continue,
  Convert, ConvertS, ConvertU, F32DemoteF64, F64PromoteF32, FAbs, FAdd, FCeil,
  FCopysign, FDiv, FEq, FFloor, FGe, FGt, FLe, FLt, FMax, FMin, FMul, FNe,
  FNearest, FNeg, FSqrt, FSub, FTrunc, FW32, FW64, FuelExhausted, FuncType,
  Function, GlobalGet, GlobalSet, I32Extend16S, I32Extend8S, I32WrapI64,
  I64Extend16S, I64Extend32S, I64Extend8S, I64ExtendI32S, I64ExtendI32U, IAdd,
  IAnd, IClz, ICtz, IDivS, IDivU, IEq, IEqz, IGeS, IGeU, IGtS, IGtU, ILeS, ILeU,
  ILtS, ILtU, IMul, INe, IOr, IPopcnt, IRemS, IRemU, IRotl, IRotr, IShl, IShrS,
  IShrU, ISub, IXor, If, IndirectCallTypeMismatch, IntDivByZero, IntOverflow,
  InvalidConversionToInteger, Let, Loop, LoopParam, MakeClosure, MakeCons,
  MakeTuple, MemAccess, MemGrow, MemLoad, MemSize, MemStore, MemoryOutOfBounds,
  Num, ReinterpretFToI, ReinterpretIToF, Return, Switch, SwitchArm, TF32, TF64,
  TI32, TI64, TTerm, TableOutOfBounds, TermOp, Trap, TruncS, TruncSatS,
  TruncSatU, TruncU, TupleGet, UnboxFloat, UnboxInt, UndefinedElement,
  UninitializedElement, Unreachable, Values, Var, W32, W64,
}

// ───────────────────────────── public entry point ─────────────────────────────

/// Render an IR module to its canonical `.ir` text (D7).
///
/// Deterministic: the same `Module` always produces byte-identical output, and it
/// is the ONE canonical form (so a golden's text is unambiguous). Float constants
/// are printed as RAW IEEE-754 bit patterns in lower-case zero-padded `0x`-hex (D5)
/// — NEVER decimals (decimals lose f32 rounding and NaN payloads). Integer constants
/// are printed as their stored **unsigned** value in canonical decimal.
///
/// Parameters:
/// - `module`: any value of type `ir.Module`. All three capability axes (numerics,
///   memory, term) and every declaration/expression variant are handled.
///
/// Returns the full module text, terminated by a trailing newline. Total — every
/// value of type `Module` has a printable form (the type system guarantees the
/// variants), so this never fails and never panics.
pub fn print_module(module: Module) -> String {
  let header = [
    "module @" <> module.name <> " {\n",
    "  numerics " <> bool_str(module.uses_numerics) <> "\n",
  ]
  // One `memory` line per declaration, in list order (list position = memory index, H3);
  // the empty list renders the legacy `memory none` sentinel (byte-identical to a Phase-1
  // numerics-only module). See `print_memory_decl` (§A.2.1).
  let memories = case module.memories {
    [] -> ["  memory none\n"]
    ms -> list.map(ms, print_memory_decl)
  }
  let globals = list.map(module.globals, print_global)
  // One `tag` line per module-defined exception tag (J2/T2), in list order (= tag-index space).
  // The empty list (the conformance-neutral default) renders NOTHING, so a tag-free module's
  // `.ir` text is byte-identical to Phase-6.
  let tags = list.map(module.tags, print_tag)
  let tables = list.map(module.tables, print_table)
  let imports = list.map(module.imports, print_import)
  let exports = list.map(module.exports, print_export)
  let data = list.map(module.data_segments, print_data)
  let elements = list.map(module.elements, print_elem)
  let start = case module.start {
    Some(fn_name) -> ["  start @" <> fn_name <> "\n"]
    None -> []
  }
  let funcs = list.map(module.functions, fn(f) { print_func(f) <> "\n" })

  string_tree.from_strings(
    list.flatten([
      header,
      memories,
      globals,
      tags,
      tables,
      imports,
      exports,
      data,
      elements,
      start,
      funcs,
      ["}\n"],
    ]),
  )
  |> string_tree.to_string
}

// ───────────────────────────── module declarations ─────────────────────────────

/// Renders the `numerics` capability flag as the keyword `true`/`false`.
fn bool_str(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

/// Renders one linear-memory declaration as a `  memory …` line (H3, §A.2.1).
///
/// The address-width token is **omitted for `Idx32`** (the default — a single 32-bit memory
/// prints byte-identically to Phase-4) and spelled `i64 ` before the sizing for `Idx64`
/// (memory64). The sizing reuses the Phase-2 `(min N)` / `(min N max M)` shape. A module with
/// two memories prints two lines; the empty list is handled by `print_module` (which emits the
/// legacy `memory none` sentinel). Total.
fn print_memory_decl(m: ir.MemoryDecl) -> String {
  "  memory "
  <> print_idxtype(m.idx_type)
  <> "(min "
  <> int.to_string(m.min_pages)
  <> max_clause(m.max_pages)
  <> ")\n"
}

/// Renders one global slot: `  global @name : ty [mut] = <init-expr>`. The init is
/// a full expression printed at module indentation (2).
fn print_global(g: ir.GlobalDecl) -> String {
  let mut = case g.mutable {
    True -> " mut"
    False -> ""
  }
  "  global @"
  <> g.name
  <> " : "
  <> print_valtype(g.ty)
  <> mut
  <> " = "
  <> print_expr(2, g.init)
  <> "\n"
}

/// Renders one module-defined exception tag (J2/T2): `  tag @name (params)`, mirroring the
/// `global`/`table` module-declaration spellings. `params` is the operand signature the exception
/// carries (`()` for a payload-less tag). Conformance-neutral (no legacy module declares a tag);
/// P7-02 owns the full round-trip. Total.
fn print_tag(t: ir.TagDecl) -> String {
  "  tag @" <> t.name <> " " <> valtype_list(t.params) <> "\n"
}

/// Renders one import (H4, §A.2.3).
///
/// Every import is `  import "<module>" "<name>" <kind-clause>`. `ImportFn` keeps its exact
/// Phase-1 host-function form (the kind clause is `: <functype>`), so a function-only module
/// is byte-identical. The three state variants replace the kind clause with a `global`/
/// `table`/`memory` keyword and the state's shape:
/// - `global <valtype> [mut]` (an imported global);
/// - `table <reftype> min N [max M]` (an imported reference table);
/// - `memory [i64 ]( min N [max M] )` (an imported memory; `i64 ` marks a memory64/`Idx64`
///   memory, omitted for the default `Idx32`).
/// Total — every `ImportDecl` variant has a spelling.
fn print_import(i: ir.ImportDecl) -> String {
  case i {
    ir.ImportFn(capability, name, ty) ->
      "  import \""
      <> escape(capability)
      <> "\" \""
      <> escape(name)
      <> "\" : "
      <> print_functype(ty)
      <> "\n"
    ir.ImportGlobal(module, name, ty, mutable) ->
      "  import \""
      <> escape(module)
      <> "\" \""
      <> escape(name)
      <> "\" global "
      <> print_valtype(ty)
      <> case mutable {
        True -> " mut"
        False -> ""
      }
      <> "\n"
    ir.ImportTable(module, name, ref_ty, min, max) ->
      "  import \""
      <> escape(module)
      <> "\" \""
      <> escape(name)
      <> "\" table "
      <> print_reftype(ref_ty)
      <> " min "
      <> int.to_string(min)
      <> max_clause(max)
      <> "\n"
    ir.ImportMemory(module, name, min, max, idx) ->
      "  import \""
      <> escape(module)
      <> "\" \""
      <> escape(name)
      <> "\" memory "
      <> print_idxtype(idx)
      <> "(min "
      <> int.to_string(min)
      <> max_clause(max)
      <> ")\n"
    // Phase-7 imported exception tag (J2/T2) — `import "mod" "name" tag (params)`, mirroring the
    // imported-global/table/memory spellings. Conformance-neutral (no legacy module imports a
    // tag); P7-02 owns the full round-trip.
    ir.ImportTag(module, name, params) ->
      "  import \""
      <> escape(module)
      <> "\" \""
      <> escape(name)
      <> "\" tag "
      <> valtype_list(params)
      <> "\n"
  }
}

/// Renders a memory address-width prefix for the parenthesised sizing form: `""` for the
/// default `Idx32`, `"i64 "` for a memory64 (`Idx64`) memory (§A.2.1). Shared by the
/// `import … memory` spelling; the module-level `memory` line inlines the same rule.
fn print_idxtype(t: ir.IdxType) -> String {
  case t {
    ir.Idx32 -> ""
    ir.Idx64 -> "i64 "
  }
}

/// Renders one export (H4, §A.2.4).
///
/// Every export is `  export "<name>" = <target>`. `ExportFn` keeps its exact Phase-1 form
/// (`= @<fn>`), so a function-only module is byte-identical. The state variants prefix the
/// target with a `global`/`table`/`memory` keyword: `= global @<global>`, `= table @<table>`,
/// and `= memory <index>` (a memory is named by its **index** in `Module.memories`, not a
/// name). Total — every `ExportDecl` variant has a spelling.
fn print_export(e: ir.ExportDecl) -> String {
  case e {
    ir.ExportFn(export_name, fn_name) ->
      "  export \"" <> escape(export_name) <> "\" = @" <> fn_name <> "\n"
    ir.ExportGlobal(export_name, global_name) ->
      "  export \""
      <> escape(export_name)
      <> "\" = global @"
      <> global_name
      <> "\n"
    ir.ExportTable(export_name, table_name) ->
      "  export \""
      <> escape(export_name)
      <> "\" = table @"
      <> table_name
      <> "\n"
    ir.ExportMemory(export_name, mem_index) ->
      "  export \""
      <> escape(export_name)
      <> "\" = memory "
      <> int.to_string(mem_index)
      <> "\n"
    // Phase-7 exported exception tag (J2/T2) — `export "name" = tag @tagname`, mirroring the
    // global/table export spellings. Measured: Porffor emits `(export "0" (tag 0))`. Inert for
    // single-module execution; P7-02 owns the full round-trip.
    ir.ExportTag(export_name, tag_name) ->
      "  export \"" <> escape(export_name) <> "\" = tag @" <> tag_name <> "\n"
  }
}

/// Renders one data segment (H2, §A.2.5).
///
/// An **active** segment prints `  data [mem=<i>] ( <offset-expr> ) = 0x<hex>` — the memory
/// index decorator is **omitted when 0** (so a single-memory active data segment is
/// byte-identical to Phase-2). A **passive** segment drops the offset entirely:
/// `  data passive = 0x<hex>`. Total.
fn print_data(d: ir.DataSegment) -> String {
  case d.mode {
    ir.DataActive(mem, offset) ->
      "  data"
      <> print_kv("mem", mem)
      <> " ("
      <> print_expr(2, offset)
      <> ") = "
      <> print_hexbytes(d.bytes)
      <> "\n"
    ir.DataPassive -> "  data passive = " <> print_hexbytes(d.bytes) <> "\n"
  }
}

/// Renders a reference type token (`funcref`/`externref`).
fn print_reftype(r: ir.RefType) -> String {
  case r {
    ir.FuncRef -> "funcref"
    ir.ExternRef -> "externref"
    // Phase-7 exnref (J2/T9). Conformance-neutral — no legacy module has it; P7-02 owns the
    // full round-trip.
    ir.ExnRef -> "exnref"
  }
}

/// Renders an optional ` max M` clause (empty for an unbounded `None`).
fn max_clause(max: option.Option(Int)) -> String {
  case max {
    Some(m) -> " max " <> int.to_string(m)
    None -> ""
  }
}

/// Renders an omit-when-zero ` <key>=<n>` decorator (§A.6). Returns `""` when `n == 0` (the
/// default, so the token disappears and the surrounding line is byte-identical to Phase-4),
/// else ` key=<n>`. Used for the memory-index decorators (`mem`/`dst_mem`/`src_mem`) on the
/// memory ops and active data segments.
fn print_kv(key: String, n: Int) -> String {
  case n {
    0 -> ""
    v -> " " <> key <> "=" <> int.to_string(v)
  }
}

/// Renders the memory-index decorator ` mem=<n>` (omitted when `n == 0`) — `print_kv` fixed to
/// the `mem` key. The omit-when-zero rule keeps single-memory `.ir` byte-identical (§A.6).
fn print_memidx(mem: Int) -> String {
  print_kv("mem", mem)
}

/// Renders a **mandatory** ` seg=<n>` decorator (the passive-segment index into
/// `Module.elements` / `Module.data_segments`). Unlike `print_memidx` this is always spelled
/// (a segment index is not defaulted). Used by `table.init`/`mem.init`/`elem.drop`/`data.drop`.
fn print_seg(seg: Int) -> String {
  " seg=" <> int.to_string(seg)
}

/// Renders one reference table declaration (H1, §A.2.2): `  table @name [<reftype>] min N
/// [max M]`.
///
/// Mirrors `memory`'s sizing but is NAMED (`@name`) because `call_indirect`/`elem`/the table
/// ops reference it. The reference type is **elided for `FuncRef`** (so a Phase-2 funcref
/// table is byte-identical, `  table @name min N …`) and spelled ` externref` for an
/// `externref` table — the two are then unambiguous. `min`/`max` are entry counts in canonical
/// decimal; the ` max M` clause is omitted for an unbounded table (`max: None`). Total.
fn print_table(t: ir.TableDecl) -> String {
  let ref_ty = case t.ref_ty {
    ir.FuncRef -> ""
    ir.ExternRef -> " externref"
    // Phase-7 exnref-typed table (spec-conformance surface only; validate rejects it for
    // Porffor). Total match — no legacy module has it.
    ir.ExnRef -> " exnref"
  }
  "  table @"
  <> t.name
  <> ref_ty
  <> " min "
  <> int.to_string(t.min)
  <> max_clause(t.max)
  <> "\n"
}

/// Renders one element segment (H2, §A.2.6).
///
/// Two spellings, both parsed by `parser.parse_elem`:
/// - **Legacy (byte-identical)** — an ACTIVE `FuncRef` segment whose items are all `RefFunc`
///   prints the Phase-2 form `  elem @table ( <offset> ) [ @fn, … ]` (the bare `@name`
///   funcidx-list abbreviation), so `mem_table.ir` re-prints unchanged.
/// - **Canonical** — everything else prints `  elem <reftype> <mode> [ <init-item>,* ]` where
///   the reference type comes first, then the mode (`@table ( <offset> )` active / `passive` /
///   `declare`), then the init items via `print_ref_init` (`ref.func @f` for a funcref item,
///   the general expression form otherwise — e.g. `values (null.funcref)` for a null slot).
/// Total — every `ElementSegment` has a spelling.
fn print_elem(e: ir.ElementSegment) -> String {
  case e.mode, e.ref_ty, all_reffunc(e.init) {
    ir.ElemActive(table, offset), ir.FuncRef, Ok(funcs) ->
      "  elem @"
      <> table
      <> " ("
      <> print_expr(2, offset)
      <> ") ["
      <> string.join(list.map(funcs, fn(f) { "@" <> f }), ", ")
      <> "]\n"
    _, _, _ ->
      "  elem "
      <> print_reftype(e.ref_ty)
      <> " "
      <> print_elem_mode(e.mode)
      <> " ["
      <> string.join(list.map(e.init, print_ref_init), ", ")
      <> "]\n"
  }
}

/// Renders an element-segment mode (§A.2.6): `@table ( <offset> )` (active) / `passive` /
/// `declare`. The active form reuses the `data`-style parenthesised constant offset.
fn print_elem_mode(mode: ir.ElemMode) -> String {
  case mode {
    ir.ElemActive(table, offset) ->
      "@" <> table <> " (" <> print_expr(2, offset) <> ")"
    ir.ElemPassive -> "passive"
    ir.ElemDeclarative -> "declare"
  }
}

/// Renders one element-init item (a ref-producing constant expression, §A.2.6). A `RefFunc`
/// prints the clean `ref.func @name`; every other admissible const-init expression (a null
/// slot `Values([ConstNull(ty)])`, a `global.get`, a numeric const) falls back to the general
/// `print_expr` at module indent, so any init item round-trips. Total.
fn print_ref_init(item: Expr) -> String {
  case item {
    ir.RefFunc(name) -> "ref.func @" <> name
    _ -> print_expr(2, item)
  }
}

/// If every element item is a `RefFunc`, return `Ok(func-names)` (the byte-identical Phase-2
/// case for an active funcref segment); otherwise `Error(Nil)` (a null / non-funcref item is
/// present, so the canonical `elem` spelling is used).
fn all_reffunc(init: List(Expr)) -> Result(List(String), Nil) {
  list.try_map(init, fn(item) {
    case item {
      ir.RefFunc(name) -> Ok(name)
      _ -> Error(Nil)
    }
  })
}

/// Renders a whole function with its named-param header (`func @add (%p0:i32) -> (i32)`),
/// any `local` slots, and the body indented at level 4.
fn print_func(f: Function) -> String {
  let Function(name, params, result, locals, body) = f
  let header =
    "  func @"
    <> name
    <> " ("
    <> string.join(list.map(params, print_param), ", ")
    <> ") -> ("
    <> string.join(list.map(result, print_valtype), ", ")
    <> ") {\n"
  let local_lines =
    list.map(locals, fn(l) {
      "    local %" <> l.name <> " : " <> print_valtype(l.ty) <> "\n"
    })
  header <> string.concat(local_lines) <> stmt(4, body) <> "\n  }"
}

/// Renders a named param slot as `%name:ty`.
fn print_param(l: Local) -> String {
  "%" <> l.name <> ":" <> print_valtype(l.ty)
}

// ───────────────────────────── types & values ─────────────────────────────

/// Renders a value type: `i32`/`i64`/`f32`/`f64`/`term`/`funcref`/`externref`.
fn print_valtype(t: ValType) -> String {
  case t {
    TI32 -> "i32"
    TI64 -> "i64"
    TF32 -> "f32"
    TF64 -> "f64"
    TTerm -> "term"
    ir.TFuncRef -> "funcref"
    ir.TExternRef -> "externref"
    // Phase-6 SIMD value type (I1). Conformance-neutral — no legacy module has it.
    ir.TV128 -> "v128"
    // Phase-7 exnref value type (J2/T9). Conformance-neutral; P7-02 owns the full round-trip.
    ir.TExnRef -> "exnref"
  }
}

/// Renders a nameless `(params) -> (results)` signature (imports / call_indirect).
fn print_functype(ft: FuncType) -> String {
  let FuncType(params, results) = ft
  "("
  <> string.join(list.map(params, print_valtype), ", ")
  <> ") -> ("
  <> string.join(list.map(results, print_valtype), ", ")
  <> ")"
}

/// Renders an atomic value operand.
///
/// `Var` → `%name`. Integer constants print as the stored **unsigned** decimal.
/// Float constants print as their raw IEEE-754 bits in lower-case zero-padded
/// `0x`-hex (8 digits for f32, 16 for f64) — losslessly preserving NaN payloads
/// and `-0.0` (D5).
fn print_value(v: Value) -> String {
  case v {
    Var(name) -> "%" <> name
    ConstI32(bits) -> "i32.const " <> int.to_string(bits)
    ConstI64(bits) -> "i64.const " <> int.to_string(bits)
    ConstF32(bits) -> "f32.const 0x" <> hex_pad(bits, 8)
    ConstF64(bits) -> "f64.const 0x" <> hex_pad(bits, 16)
    // The null-reference literal, tagged by reftype (a single dotted token so it lexes as one
    // word, like `i32.const`): `null.funcref` / `null.externref` (R1c).
    ir.ConstNull(ty) -> "null." <> print_reftype(ty)
    // The `v128.const` literal — the 16 raw little-endian bytes as `0x` + 32 lower-case hex
    // digits (D5, §A.2). Byte-exact, so NaN-payload / `-0.0` / `±Inf` lanes survive; the parser
    // (`parse_value`) reads them back and enforces the 16-byte length. No legacy module has it.
    ir.ConstV128(bytes) -> "v128.const " <> print_hexbytes(bytes)
    // Phase-8 term literals (K2, unit 01). An atom prints `atom "<escaped-name>"`; a binary
    // prints `binary 0x<hex>` (the same hex-bytes form a data-segment payload uses). The parser
    // (`parse_value`) reads both back. No WASM module produces one (K7).
    ir.ConstAtom(name) -> "atom \"" <> escape(name) <> "\""
    ir.ConstBinary(bytes) -> "binary " <> print_hexbytes(bytes)
  }
}

/// Lower-case hex of `n`, left-zero-padded to at least `width` digits.
fn hex_pad(n: Int, width: Int) -> String {
  string.pad_start(string.lowercase(int.to_base16(n)), width, "0")
}

/// Comma-separated parenthesised list of values: `(%a, i32.const 1)` / `()`.
fn value_list(vs: List(Value)) -> String {
  "(" <> string.join(list.map(vs, print_value), ", ") <> ")"
}

/// Comma-separated parenthesised list of value types: `(i32, i64)` / `()`.
fn valtype_list(ts: List(ValType)) -> String {
  "(" <> string.join(list.map(ts, print_valtype), ", ") <> ")"
}

// ───────────────────────────── expressions ─────────────────────────────

/// `n` spaces of indentation.
fn spaces(n: Int) -> String {
  string.repeat(" ", n)
}

/// Prints an expression as a *statement*: indented to `indent`, then the expression.
fn stmt(indent: Int, e: Expr) -> String {
  spaces(indent) <> print_expr(indent, e)
}

/// Renders an expression. By convention the FIRST line carries NO leading indent
/// (the caller positions it — e.g. after `let (...) = `), while every continuation
/// line is absolutely indented relative to `indent`. The sequencing forms (`Let`,
/// `Charge`) place their continuation body on the next line at the same `indent`;
/// the structured-control forms (`Block`/`Loop`/`If`/`Switch`) indent their bodies
/// by one further level (`indent + 2`).
fn print_expr(indent: Int, e: Expr) -> String {
  case e {
    Values(vs) -> "values " <> value_list(vs)
    Num(op, args) -> "num " <> numop_to_string(op) <> " " <> value_list(args)
    Convert(op, arg) ->
      "convert " <> convop_to_string(op) <> " " <> print_value(arg)
    TermOp(op, args) ->
      "term " <> termop_to_string(op) <> " " <> value_list(args)
    // The four existing memory nodes gain a trailing `mem=<n>` decorator, OMITTED when the
    // index is 0 (§A.6) — so a single-memory (index-0) module's `.ir` is byte-identical to
    // Phase-4 (H7); a non-zero index appends ` mem=<n>`.
    MemSize(mem) -> "mem.size" <> print_memidx(mem)
    MemGrow(mem, delta) ->
      "mem.grow " <> print_value(delta) <> print_memidx(mem)
    MemLoad(mem, op, addr, offset, result) ->
      "mem.load "
      <> print_valtype(result)
      <> " "
      <> print_memaccess(op)
      <> " "
      <> print_value(addr)
      <> " offset="
      <> int.to_string(offset)
      <> print_memidx(mem)
    MemStore(mem, op, addr, value, offset) ->
      "mem.store "
      <> print_memaccess(op)
      <> " "
      <> print_value(addr)
      <> " "
      <> print_value(value)
      <> " offset="
      <> int.to_string(offset)
      <> print_memidx(mem)
    // ── Phase-5 reference / table / bulk nodes (H2, §A.3–§A.5). No Phase-1..4 module
    // contains these, so any spelling is conformance-neutral by construction. Value operands
    // are printed positionally; `seg=<n>` is always spelled; `mem=`/`dst_mem=`/`src_mem=`
    // decorators are omitted when 0 (§A.6). ──
    ir.RefFunc(fn_name) -> "ref.func @" <> fn_name
    ir.RefIsNull(arg) -> "ref.is_null " <> print_value(arg)
    ir.TableGet(table, index) ->
      "table.get @" <> table <> " " <> print_value(index)
    ir.TableSet(table, index, value) ->
      "table.set @"
      <> table
      <> " "
      <> print_value(index)
      <> " "
      <> print_value(value)
    ir.TableSize(table) -> "table.size @" <> table
    ir.TableGrow(table, delta, init) ->
      "table.grow @"
      <> table
      <> " "
      <> print_value(delta)
      <> " "
      <> print_value(init)
    ir.TableFill(table, offset, value, count) ->
      "table.fill @"
      <> table
      <> " "
      <> print_value(offset)
      <> " "
      <> print_value(value)
      <> " "
      <> print_value(count)
    ir.TableInit(table, seg, dst, src, count) ->
      "table.init @"
      <> table
      <> " "
      <> print_value(dst)
      <> " "
      <> print_value(src)
      <> " "
      <> print_value(count)
      <> print_seg(seg)
    ir.TableCopy(dst_table, src_table, dst, src, count) ->
      "table.copy @"
      <> dst_table
      <> " @"
      <> src_table
      <> " "
      <> print_value(dst)
      <> " "
      <> print_value(src)
      <> " "
      <> print_value(count)
    ir.ElemDrop(seg) -> "elem.drop" <> print_seg(seg)
    ir.MemFill(mem, dest, value, count) ->
      "mem.fill "
      <> print_value(dest)
      <> " "
      <> print_value(value)
      <> " "
      <> print_value(count)
      <> print_memidx(mem)
    ir.MemCopy(dst_mem, src_mem, dst, src, count) ->
      "mem.copy "
      <> print_value(dst)
      <> " "
      <> print_value(src)
      <> " "
      <> print_value(count)
      <> print_kv("dst_mem", dst_mem)
      <> print_kv("src_mem", src_mem)
    ir.MemInit(mem, seg, dst, src, count) ->
      "mem.init "
      <> print_value(dst)
      <> " "
      <> print_value(src)
      <> " "
      <> print_value(count)
      <> print_seg(seg)
      <> print_memidx(mem)
    ir.DataDrop(seg) -> "data.drop" <> print_seg(seg)
    GlobalGet(name) -> "global.get @" <> name
    GlobalSet(name, value) ->
      "global.set @" <> name <> " " <> print_value(value)
    CallDirect(fn_name, args) -> "call @" <> fn_name <> " " <> value_list(args)
    // ── Phase-8 native closures (K3, unit 02). No Phase-1..7 module contains these, so any
    // spelling is conformance-neutral by construction; this is the round-trip spelling
    // (`parser.parse_expr` reads it back). `make_closure @f (captures…) arity=<n>` prints the
    // target function name, the capture value list, then the mandatory runtime-arity decorator;
    // `call_closure <callee> (args…)` prints the fun value then the argument list. ──
    MakeClosure(fn_name, captures, arity) ->
      "make_closure @"
      <> fn_name
      <> " "
      <> value_list(captures)
      <> " arity="
      <> int.to_string(arity)
    CallClosure(callee, args) ->
      "call_closure " <> print_value(callee) <> " " <> value_list(args)
    CallIndirect(table, index, ty, args) ->
      "call_indirect @"
      <> table
      <> " ["
      <> print_value(index)
      <> "] : "
      <> print_functype(ty)
      <> " "
      <> value_list(args)
    CallHost(capability, name, args) ->
      "call_host \""
      <> escape(capability)
      <> "\" \""
      <> escape(name)
      <> "\" "
      <> value_list(args)
    Let(names, rhs, body) ->
      "let ("
      <> string.join(list.map(names, fn(n) { "%" <> n }), ", ")
      <> ") = "
      <> print_expr(indent, rhs)
      <> "\n"
      <> stmt(indent, body)
    Block(label, result, body) ->
      "block $"
      <> label
      <> " : "
      <> valtype_list(result)
      <> " {\n"
      <> stmt(indent + 2, body)
      <> "\n"
      <> spaces(indent)
      <> "}"
    Loop(label, params, result, body) ->
      "loop $"
      <> label
      <> " ("
      <> string.join(list.map(params, print_loopparam), ", ")
      <> ") : "
      <> valtype_list(result)
      <> " {\n"
      <> stmt(indent + 2, body)
      <> "\n"
      <> spaces(indent)
      <> "}"
    If(cond, result, then_branch, else_branch) ->
      "if "
      <> print_value(cond)
      <> " : "
      <> valtype_list(result)
      <> " {\n"
      <> stmt(indent + 2, then_branch)
      <> "\n"
      <> spaces(indent)
      <> "} else {\n"
      <> stmt(indent + 2, else_branch)
      <> "\n"
      <> spaces(indent)
      <> "}"
    Switch(selector, result, arms, default) ->
      "switch "
      <> print_value(selector)
      <> " : "
      <> valtype_list(result)
      <> " {\n"
      <> string.concat(list.map(arms, fn(a) { print_arm(indent, a) }))
      <> spaces(indent + 2)
      <> "default {\n"
      <> stmt(indent + 4, default)
      <> "\n"
      <> spaces(indent + 2)
      <> "}\n"
      <> spaces(indent)
      <> "}"
    Break(label, values) -> "break $" <> label <> " " <> value_list(values)
    Continue(label, values) ->
      "continue $" <> label <> " " <> value_list(values)
    Return(values) -> "return " <> value_list(values)
    Trap(reason) -> "trap " <> trapreason_to_string(reason)
    Charge(cost, body) ->
      "charge " <> int.to_string(cost) <> "\n" <> stmt(indent, body)
    // ── Phase-6 SIMD nodes + cross-module call (I1/I2/S5). No Phase-1..5 module contains these,
    // so any spelling is conformance-neutral by construction; P6-02 makes it the round-trip
    // spelling. SIMD-memory nodes elide `mem=0` (like the scalar memory nodes, §A.6). ──
    ir.Simd(op, args) ->
      "simd " <> simdop_to_string(op) <> " " <> value_list(args)
    ir.SimdShuffle(lanes, a, b) ->
      "simd.shuffle ["
      <> string.join(list.map(lanes, int.to_string), ", ")
      <> "] "
      <> print_value(a)
      <> " "
      <> print_value(b)
    ir.SimdLoad(mem, kind, addr, offset) ->
      "simd.load "
      <> simdloadkind_str(kind)
      <> " "
      <> print_value(addr)
      <> " offset="
      <> int.to_string(offset)
      <> print_memidx(mem)
    ir.SimdStore(mem, addr, value, offset) ->
      "simd.store "
      <> print_value(addr)
      <> " "
      <> print_value(value)
      <> " offset="
      <> int.to_string(offset)
      <> print_memidx(mem)
    ir.SimdLoadLane(mem, width, addr, offset, lane, vec) ->
      "simd.load_lane "
      <> int.to_string(width)
      <> " "
      <> print_value(addr)
      <> " offset="
      <> int.to_string(offset)
      <> " lane="
      <> int.to_string(lane)
      <> " "
      <> print_value(vec)
      <> print_memidx(mem)
    ir.SimdStoreLane(mem, width, addr, offset, lane, vec) ->
      "simd.store_lane "
      <> int.to_string(width)
      <> " "
      <> print_value(addr)
      <> " offset="
      <> int.to_string(offset)
      <> " lane="
      <> int.to_string(lane)
      <> " "
      <> print_value(vec)
      <> print_memidx(mem)
    ir.CallImport(slot, ty, args) ->
      "call_import "
      <> int.to_string(slot)
      <> " : "
      <> print_functype(ty)
      <> " "
      <> value_list(args)
    // ── Phase-7 EH nodes (J2/T1). No Phase-1..6 module contains these, so any spelling is
    // conformance-neutral by construction; P7-02 makes it the round-trip spelling. ──
    ir.Throw(tag, args) -> "throw @" <> tag <> " " <> value_list(args)
    ir.ThrowRef(exnref) -> "throw_ref " <> print_value(exnref)
    ir.Try(result, body, handlers) ->
      "try "
      <> valtype_list(result)
      <> " {\n"
      <> stmt(indent + 2, body)
      <> "\n"
      <> spaces(indent)
      <> "}"
      <> string.concat(
        list.map(handlers, fn(h) { print_catch_handler(indent, h) }),
      )
  }
}

/// Renders one `CatchHandler` of a `Try` region (J2/T1) at the try's `indent`. Spells the
/// `CatchTag` (`catch @tag` / `catch_all`), the payload names in `(%a, %b)`, an optional ` ref %e`
/// exnref-capture clause, then the inline handler body. Conformance-neutral spelling; P7-02 owns
/// the round-trip. Total.
fn print_catch_handler(indent: Int, h: ir.CatchHandler) -> String {
  let tag = case h.on {
    ir.OnTag(t) -> "catch @" <> t
    ir.OnAll -> "catch_all"
  }
  let payload =
    "(" <> string.join(list.map(h.payload, fn(n) { "%" <> n }), ", ") <> ")"
  let exnref = case h.exnref {
    Some(name) -> " ref %" <> name
    None -> ""
  }
  " "
  <> tag
  <> " "
  <> payload
  <> exnref
  <> " {\n"
  <> stmt(indent + 2, h.handler)
  <> "\n"
  <> spaces(indent)
  <> "}"
}

/// Renders a SIMD lane shape token (`i8x16`/`i16x8`/`i32x4`/`i64x2`/`f32x4`/`f64x2`). Shared by
/// the shape-tagged `simdop` spellings (§F). Total.
fn simdshape_str(s: ir.SimdShape) -> String {
  case s {
    ir.I8x16 -> "i8x16"
    ir.I16x8 -> "i16x8"
    ir.I32x4 -> "i32x4"
    ir.I64x2 -> "i64x2"
    ir.F32x4 -> "f32x4"
    ir.F64x2 -> "f64x2"
  }
}

/// Renders a widen/extend half token (`low`/`high`). Total.
fn simdhalf_str(h: ir.SimdHalf) -> String {
  case h {
    ir.Low -> "low"
    ir.High -> "high"
  }
}

/// Renders the signed/unsigned suffix `s`/`u` for the tagged shape-changing families. Total.
fn signed_str(signed: Bool) -> String {
  case signed {
    True -> "s"
    False -> "u"
  }
}

/// Renders a SIMD-load kind token (§F): `v128` / `splat <bits>` / `extend <bits> s|u` /
/// `zero <bits>`. All widths are BITS (S2). Total.
fn simdloadkind_str(k: ir.SimdLoadKind) -> String {
  case k {
    ir.LoadV128 -> "v128"
    ir.LoadSplat(bits) -> "splat " <> int.to_string(bits)
    ir.LoadExtend(bits, signed) ->
      "extend " <> int.to_string(bits) <> " " <> signed_str(signed)
    ir.LoadZero(bits) -> "zero " <> int.to_string(bits)
  }
}

/// Renders a neutral, shape-tagged `SimdOp` token for the `.ir` text — the canonical spelling
/// table (documented in `specs/phase-6/ir-grammar-delta.md` §A.3). The parser's `string_to_simdop`
/// is its EXACT inverse, proven by the full-surface round-trip (`test/twocore/ir/roundtrip_test`).
/// The `<shape>.<op>` scheme (`i32x4.add`) is bijective: integer vs float ops use distinct
/// mnemonics (`add` vs `fadd`), the tagged narrow/extend/extmul/pairwise families are op-name-first
/// (`narrow.i16x8.s`), and the singular conversion/dot/q15/swizzle ops are fixed strings.
/// Total — the exhaustive `case` fails to compile if a `SimdOp` constructor is added later.
fn simdop_to_string(op: ir.SimdOp) -> String {
  case op {
    ir.SAdd(s) -> simdshape_str(s) <> ".add"
    ir.SSub(s) -> simdshape_str(s) <> ".sub"
    ir.SMul(s) -> simdshape_str(s) <> ".mul"
    ir.SNeg(s) -> simdshape_str(s) <> ".neg"
    ir.SAbs(s) -> simdshape_str(s) <> ".abs"
    ir.SAddSatS(s) -> simdshape_str(s) <> ".add_sat_s"
    ir.SAddSatU(s) -> simdshape_str(s) <> ".add_sat_u"
    ir.SSubSatS(s) -> simdshape_str(s) <> ".sub_sat_s"
    ir.SSubSatU(s) -> simdshape_str(s) <> ".sub_sat_u"
    ir.SMinS(s) -> simdshape_str(s) <> ".min_s"
    ir.SMinU(s) -> simdshape_str(s) <> ".min_u"
    ir.SMaxS(s) -> simdshape_str(s) <> ".max_s"
    ir.SMaxU(s) -> simdshape_str(s) <> ".max_u"
    ir.SAvgrU(s) -> simdshape_str(s) <> ".avgr_u"
    ir.SShl(s) -> simdshape_str(s) <> ".shl"
    ir.SShrS(s) -> simdshape_str(s) <> ".shr_s"
    ir.SShrU(s) -> simdshape_str(s) <> ".shr_u"
    ir.SPopcnt(s) -> simdshape_str(s) <> ".popcnt"
    ir.SEq(s) -> simdshape_str(s) <> ".eq"
    ir.SNe(s) -> simdshape_str(s) <> ".ne"
    ir.SLtS(s) -> simdshape_str(s) <> ".lt_s"
    ir.SLtU(s) -> simdshape_str(s) <> ".lt_u"
    ir.SLeS(s) -> simdshape_str(s) <> ".le_s"
    ir.SLeU(s) -> simdshape_str(s) <> ".le_u"
    ir.SGtS(s) -> simdshape_str(s) <> ".gt_s"
    ir.SGtU(s) -> simdshape_str(s) <> ".gt_u"
    ir.SGeS(s) -> simdshape_str(s) <> ".ge_s"
    ir.SGeU(s) -> simdshape_str(s) <> ".ge_u"
    ir.VNot -> "v128.not"
    ir.VAnd -> "v128.and"
    ir.VOr -> "v128.or"
    ir.VXor -> "v128.xor"
    ir.VAndNot -> "v128.andnot"
    ir.VBitselect -> "v128.bitselect"
    ir.VAnyTrue -> "v128.any_true"
    ir.SAllTrue(s) -> simdshape_str(s) <> ".all_true"
    ir.SBitmask(s) -> simdshape_str(s) <> ".bitmask"
    ir.SSplat(s) -> simdshape_str(s) <> ".splat"
    ir.SExtractLane(s, lane) ->
      simdshape_str(s) <> ".extract_lane." <> int.to_string(lane)
    ir.SExtractLaneS(s, lane) ->
      simdshape_str(s) <> ".extract_lane_s." <> int.to_string(lane)
    ir.SExtractLaneU(s, lane) ->
      simdshape_str(s) <> ".extract_lane_u." <> int.to_string(lane)
    ir.SReplaceLane(s, lane) ->
      simdshape_str(s) <> ".replace_lane." <> int.to_string(lane)
    ir.SFAdd(s) -> simdshape_str(s) <> ".fadd"
    ir.SFSub(s) -> simdshape_str(s) <> ".fsub"
    ir.SFMul(s) -> simdshape_str(s) <> ".fmul"
    ir.SFDiv(s) -> simdshape_str(s) <> ".fdiv"
    ir.SFNeg(s) -> simdshape_str(s) <> ".fneg"
    ir.SFAbs(s) -> simdshape_str(s) <> ".fabs"
    ir.SFSqrt(s) -> simdshape_str(s) <> ".fsqrt"
    ir.SFMin(s) -> simdshape_str(s) <> ".fmin"
    ir.SFMax(s) -> simdshape_str(s) <> ".fmax"
    ir.SFPMin(s) -> simdshape_str(s) <> ".pmin"
    ir.SFPMax(s) -> simdshape_str(s) <> ".pmax"
    ir.SFCeil(s) -> simdshape_str(s) <> ".fceil"
    ir.SFFloor(s) -> simdshape_str(s) <> ".ffloor"
    ir.SFTrunc(s) -> simdshape_str(s) <> ".ftrunc"
    ir.SFNearest(s) -> simdshape_str(s) <> ".fnearest"
    ir.SFEq(s) -> simdshape_str(s) <> ".feq"
    ir.SFNe(s) -> simdshape_str(s) <> ".fne"
    ir.SFLt(s) -> simdshape_str(s) <> ".flt"
    ir.SFLe(s) -> simdshape_str(s) <> ".fle"
    ir.SFGt(s) -> simdshape_str(s) <> ".fgt"
    ir.SFGe(s) -> simdshape_str(s) <> ".fge"
    ir.SNarrow(from, signed) ->
      "narrow." <> simdshape_str(from) <> "." <> signed_str(signed)
    ir.SExtend(from, half, signed) ->
      "extend."
      <> simdshape_str(from)
      <> "."
      <> simdhalf_str(half)
      <> "."
      <> signed_str(signed)
    ir.SExtMul(from, half, signed) ->
      "extmul."
      <> simdshape_str(from)
      <> "."
      <> simdhalf_str(half)
      <> "."
      <> signed_str(signed)
    ir.SExtAddPairwise(from, signed) ->
      "extadd_pairwise." <> simdshape_str(from) <> "." <> signed_str(signed)
    ir.STruncSatF32x4S -> "i32x4.trunc_sat_f32x4_s"
    ir.STruncSatF32x4U -> "i32x4.trunc_sat_f32x4_u"
    ir.STruncSatF64x2SZero -> "i32x4.trunc_sat_f64x2_s_zero"
    ir.STruncSatF64x2UZero -> "i32x4.trunc_sat_f64x2_u_zero"
    ir.SConvertF32x4I32x4S -> "f32x4.convert_i32x4_s"
    ir.SConvertF32x4I32x4U -> "f32x4.convert_i32x4_u"
    ir.SConvertF64x2LowI32x4S -> "f64x2.convert_low_i32x4_s"
    ir.SConvertF64x2LowI32x4U -> "f64x2.convert_low_i32x4_u"
    ir.SDemoteF64x2Zero -> "f32x4.demote_f64x2_zero"
    ir.SPromoteLowF32x4 -> "f64x2.promote_low_f32x4"
    ir.SDotI16x8S -> "i32x4.dot_i16x8_s"
    ir.SQ15MulrSatS -> "i16x8.q15mulr_sat_s"
    ir.SSwizzle -> "i8x16.swizzle"
  }
}

/// Renders one `switch` arm at `indent + 2`, body at `indent + 4`.
fn print_arm(indent: Int, arm: SwitchArm) -> String {
  let SwitchArm(match, body) = arm
  spaces(indent + 2)
  <> "case "
  <> int.to_string(match)
  <> " {\n"
  <> stmt(indent + 4, body)
  <> "\n"
  <> spaces(indent + 2)
  <> "}\n"
}

/// Renders one loop iteration variable: `%name:ty = <init-value>`.
fn print_loopparam(p: LoopParam) -> String {
  let LoopParam(name, ty, init) = p
  "%" <> name <> ":" <> print_valtype(ty) <> " = " <> print_value(init)
}

/// Renders a memory-access descriptor: `<bytes>` optionally followed by ` signed`.
fn print_memaccess(m: MemAccess) -> String {
  let MemAccess(bytes, signed) = m
  case signed {
    True -> int.to_string(bytes) <> " signed"
    False -> int.to_string(bytes)
  }
}

// ───────────────────────────── op spelling tables ─────────────────────────────
// These are the single source of truth for the textual spellings; the parser's
// `string_to_*` mirror them. The full-surface round-trip test proves they agree.

/// Renders the 32/64 integer width suffix (`32`/`64`).
fn iwidth_str(w: IntWidth) -> String {
  case w {
    W32 -> "32"
    W64 -> "64"
  }
}

/// Renders the 32/64 float width suffix (`32`/`64`).
fn fwidth_str(w: FloatWidth) -> String {
  case w {
    FW32 -> "32"
    FW64 -> "64"
  }
}

/// Renders an integer width as a value-type token (`i32`/`i64`) for conv-op spellings.
fn iwidth_ty(w: IntWidth) -> String {
  case w {
    W32 -> "i32"
    W64 -> "i64"
  }
}

/// Renders a float width as a value-type token (`f32`/`f64`) for conv-op spellings.
fn fwidth_ty(w: FloatWidth) -> String {
  case w {
    FW32 -> "f32"
    FW64 -> "f64"
  }
}

/// Renders a neutral, width-tagged numeric op (D6): `i.<mnemonic>.<width>` for
/// integer ops, `f.<mnemonic>.<width>` for float ops (e.g. `i.add.32`, `f.div.64`).
fn numop_to_string(op: NumOp) -> String {
  case op {
    IAdd(w) -> "i.add." <> iwidth_str(w)
    ISub(w) -> "i.sub." <> iwidth_str(w)
    IMul(w) -> "i.mul." <> iwidth_str(w)
    IDivS(w) -> "i.div_s." <> iwidth_str(w)
    IDivU(w) -> "i.div_u." <> iwidth_str(w)
    IRemS(w) -> "i.rem_s." <> iwidth_str(w)
    IRemU(w) -> "i.rem_u." <> iwidth_str(w)
    IAnd(w) -> "i.and." <> iwidth_str(w)
    IOr(w) -> "i.or." <> iwidth_str(w)
    IXor(w) -> "i.xor." <> iwidth_str(w)
    IShl(w) -> "i.shl." <> iwidth_str(w)
    IShrS(w) -> "i.shr_s." <> iwidth_str(w)
    IShrU(w) -> "i.shr_u." <> iwidth_str(w)
    IRotl(w) -> "i.rotl." <> iwidth_str(w)
    IRotr(w) -> "i.rotr." <> iwidth_str(w)
    IClz(w) -> "i.clz." <> iwidth_str(w)
    ICtz(w) -> "i.ctz." <> iwidth_str(w)
    IPopcnt(w) -> "i.popcnt." <> iwidth_str(w)
    IEqz(w) -> "i.eqz." <> iwidth_str(w)
    IEq(w) -> "i.eq." <> iwidth_str(w)
    INe(w) -> "i.ne." <> iwidth_str(w)
    ILtS(w) -> "i.lt_s." <> iwidth_str(w)
    ILtU(w) -> "i.lt_u." <> iwidth_str(w)
    IGtS(w) -> "i.gt_s." <> iwidth_str(w)
    IGtU(w) -> "i.gt_u." <> iwidth_str(w)
    ILeS(w) -> "i.le_s." <> iwidth_str(w)
    ILeU(w) -> "i.le_u." <> iwidth_str(w)
    IGeS(w) -> "i.ge_s." <> iwidth_str(w)
    IGeU(w) -> "i.ge_u." <> iwidth_str(w)
    FAdd(w) -> "f.add." <> fwidth_str(w)
    FSub(w) -> "f.sub." <> fwidth_str(w)
    FMul(w) -> "f.mul." <> fwidth_str(w)
    FDiv(w) -> "f.div." <> fwidth_str(w)
    FMin(w) -> "f.min." <> fwidth_str(w)
    FMax(w) -> "f.max." <> fwidth_str(w)
    // Phase-2 float NumOps (`«IR2-FROZEN»`; spellings in ir2-grammar-delta.md). The
    // comparisons are sign-AGNOSTIC (`f.lt.<W>`, not `f.lt_s`) — there is no signed/unsigned
    // distinction for IEEE floats, so they cannot collide with the integer `i.lt_s`/`i.lt_u`.
    FAbs(w) -> "f.abs." <> fwidth_str(w)
    FNeg(w) -> "f.neg." <> fwidth_str(w)
    FCeil(w) -> "f.ceil." <> fwidth_str(w)
    FFloor(w) -> "f.floor." <> fwidth_str(w)
    FTrunc(w) -> "f.trunc." <> fwidth_str(w)
    FNearest(w) -> "f.nearest." <> fwidth_str(w)
    FSqrt(w) -> "f.sqrt." <> fwidth_str(w)
    FCopysign(w) -> "f.copysign." <> fwidth_str(w)
    FEq(w) -> "f.eq." <> fwidth_str(w)
    FNe(w) -> "f.ne." <> fwidth_str(w)
    FLt(w) -> "f.lt." <> fwidth_str(w)
    FGt(w) -> "f.gt." <> fwidth_str(w)
    FLe(w) -> "f.le." <> fwidth_str(w)
    FGe(w) -> "f.ge." <> fwidth_str(w)
  }
}

/// Renders a conversion op. Fixed spellings for the width/sign changes
/// (`i32.wrap_i64`, `i64.extend_i32_s`, `i32.extend8_s`, …) and parametric
/// spellings for the rest: `trunc_sat_s.<from>.<to>` (e.g. `trunc_sat_s.f64.i32`),
/// `reinterpret_f2i.<fw>` / `reinterpret_i2f.<iw>`, and `box.<ty>` / `unbox.<ty>`
/// for the explicit term↔numeric boxing bridge (`box.i32`, `unbox.f64`).
///
/// Phase-2 additions (`«IR2-FROZEN»`): the TRAPPING `trunc_s.<fw>.<iw>` / `trunc_u.<fw>.<iw>`
/// (distinct from the saturating `trunc_sat_*`), the integer→float `convert_s.<iw>.<fw>` /
/// `convert_u.<iw>.<fw>`, and the fixed `demote.f64` / `promote.f32`.
fn convop_to_string(op: ConvOp) -> String {
  case op {
    I32WrapI64 -> "i32.wrap_i64"
    I64ExtendI32S -> "i64.extend_i32_s"
    I64ExtendI32U -> "i64.extend_i32_u"
    I32Extend8S -> "i32.extend8_s"
    I32Extend16S -> "i32.extend16_s"
    I64Extend8S -> "i64.extend8_s"
    I64Extend16S -> "i64.extend16_s"
    I64Extend32S -> "i64.extend32_s"
    TruncSatS(from, to) ->
      "trunc_sat_s." <> fwidth_ty(from) <> "." <> iwidth_ty(to)
    TruncSatU(from, to) ->
      "trunc_sat_u." <> fwidth_ty(from) <> "." <> iwidth_ty(to)
    ReinterpretFToI(w) -> "reinterpret_f2i." <> fwidth_ty(w)
    ReinterpretIToF(w) -> "reinterpret_i2f." <> iwidth_ty(w)
    BoxInt(w) -> "box." <> iwidth_ty(w)
    UnboxInt(w) -> "unbox." <> iwidth_ty(w)
    BoxFloat(w) -> "box." <> fwidth_ty(w)
    UnboxFloat(w) -> "unbox." <> fwidth_ty(w)
    // Phase-2 ConvOps (`«IR2-FROZEN»`; spellings in ir2-grammar-delta.md). The TRAPPING
    // truncations drop the `_sat` of the saturating forms (`trunc_s.<fw>.<iw>` vs
    // `trunc_sat_s.<fw>.<iw>`), so their `string.split` heads differ and never collide.
    // Operand order: trapping truncation is `<from-float>.<to-int>`; integer→float convert
    // is `<from-int>.<to-float>`. `demote`/`promote` are fixed strings (one each in MVP).
    TruncS(from, to) -> "trunc_s." <> fwidth_ty(from) <> "." <> iwidth_ty(to)
    TruncU(from, to) -> "trunc_u." <> fwidth_ty(from) <> "." <> iwidth_ty(to)
    ConvertS(from, to) ->
      "convert_s." <> iwidth_ty(from) <> "." <> fwidth_ty(to)
    ConvertU(from, to) ->
      "convert_u." <> iwidth_ty(from) <> "." <> fwidth_ty(to)
    F32DemoteF64 -> "demote.f64"
    F64PromoteF32 -> "promote.f32"
  }
}

/// Renders a term-layer op (Phase-8 unit 01): `make_tuple`, `make_cons`, `tuple_size`,
/// `list_head`, `list_tail`, `is_empty_list`, or `tuple_get.<index>` (the index encoded in the
/// spelling). The parser's `string_to_termop` reads each back.
fn termop_to_string(op: TermOp) -> String {
  case op {
    MakeTuple -> "make_tuple"
    MakeCons -> "make_cons"
    TupleGet(index) -> "tuple_get." <> int.to_string(index)
    ir.TupleSize -> "tuple_size"
    ir.ListHead -> "list_head"
    ir.ListTail -> "list_tail"
    ir.IsEmptyList -> "is_empty_list"
  }
}

/// Renders a trap reason as the snake_case of its constructor (a clean 1:1
/// rendering): `int_div_by_zero`, `int_overflow`, `unreachable`,
/// `indirect_call_type_mismatch`, `memory_out_of_bounds`.
fn trapreason_to_string(r: TrapReason) -> String {
  case r {
    IntDivByZero -> "int_div_by_zero"
    IntOverflow -> "int_overflow"
    Unreachable -> "unreachable"
    IndirectCallTypeMismatch -> "indirect_call_type_mismatch"
    MemoryOutOfBounds -> "memory_out_of_bounds"
    InvalidConversionToInteger -> "invalid_conversion_to_integer"
    UndefinedElement -> "undefined_element"
    UninitializedElement -> "uninitialized_element"
    TableOutOfBounds -> "table_out_of_bounds"
    // Runtime-only policy reason (F5); never emitted by lowering, but the match is exhaustive.
    FuelExhausted -> "fuel_exhausted"
  }
}

// ───────────────────────────── string & bytes helpers ─────────────────────────────

/// Escapes a string for the `"…"` form: backslash, double-quote, and the common
/// control chars get a backslash escape; all other characters pass through.
fn escape(s: String) -> String {
  string.to_graphemes(s)
  |> list.map(escape_char)
  |> string.concat
}

/// Escapes a single grapheme for a quoted string literal.
fn escape_char(c: String) -> String {
  case c {
    "\\" -> "\\\\"
    "\"" -> "\\\""
    "\n" -> "\\n"
    "\t" -> "\\t"
    "\r" -> "\\r"
    _ -> c
  }
}

/// Renders a `BitArray` of bytes as `0x` followed by two lower-case hex digits per
/// byte (empty array → `0x`). Leading zero bytes are preserved (significant).
fn print_hexbytes(b: BitArray) -> String {
  "0x" <> hex_of_bytes(b, "")
}

/// Accumulates the lower-case hex-pair rendering of each byte of `b`.
fn hex_of_bytes(b: BitArray, acc: String) -> String {
  case b {
    <<byte:8, rest:bytes>> ->
      hex_of_bytes(
        rest,
        acc <> string.pad_start(string.lowercase(int.to_base16(byte)), 2, "0"),
      )
    _ -> acc
  }
}
