//// The WebAssembly binary decoder — turns an untrusted `BitArray` of `.wasm` bytes
//// into the `twocore/frontend/wasm/ast` model (extended through `«WASM-AST5»`).
////
//// Phase 6 (`«WASM-AST4»`) added the `0xFD` fixed-width SIMD family. Phase 7
//// (`«WASM-AST5»`) adds the exception-handling surface: the tag section (id 13), the
//// tag import/export descriptors (kind `0x04`), the `exnref` value/heap/blocktype
//// (`0x69` / s33 `-23`), the MODERN EH opcodes (`throw` 0x08 / `throw_ref` 0x0A /
//// `try_table` 0x1F + the four catch kinds), and the LEGACY EH opcodes Porffor
//// actually emits (`try` 0x06 / `catch` 0x07 / `rethrow` 0x09 / `delegate` 0x18 /
//// `catch_all` 0x19). Decode stays purely structural — it does NOT type the exception
//// stack, match `throw` operands, resolve tag/label indices, or restrict `exnref`
//// placement; those are validate's (unit 04). `try`/`try_table` are block-openers;
//// `throw`/`throw_ref` are not; a `delegate` at depth 0 is `Error(BadDelegate)`.
////
//// THREAT MODEL: the input is attacker-controlled. Every function in this module
//// is total over arbitrary bytes — any malformation returns a typed
//// `DecodeError`, and there are NO `let assert`/`panic`/`todo`/partial matches
//// reachable from untrusted input (overview D4, D5, H6). LEB128 numbers are
//// validated against the spec's width bounds (no silent wraparound).
////
//// Scope (Phase 5 — `«WASM-AST3»`): the full standardized binary surface minus
//// SIMD. On top of the Phase-2 sections/opcodes it decodes the import section (2),
//// the datacount section (12), the reftype value types (`funcref`/`externref`), the
//// reference instructions (`ref.null`/`ref.is_null`/`ref.func`), `table.get`/`.set`,
//// typed `select`, the ten `0xFC` bulk-memory/table ops (sub-opcodes 8–17), the
//// multi-memory memarg (bit-6 memidx + u64 offset) and per-op memidx, the memory64
//// limits flags (`0x04`/`0x05` → `Idx64`; runtime deferred to Phase 6, R12), and the
//// full element (flags 0–7) and data (flags 0/1/2) segment grammar.
////
//// Decode is PURELY STRUCTURAL: it does not type-check, range-check indices, enforce
//// `min <= max`, validate alignment, or check reftype ↔ table agreement — those are
//// validate's (unit 04) job (the spec's `assert_malformed` (decode) vs
//// `assert_invalid` (validate) split). The one wellformedness rule decode owns is
//// the datacount check (R13 / spec §5.5.14), enforced in `assemble`.
////
//// The decoder uses Gleam's (Erlang-target) bit syntax throughout, so this
//// module is Erlang-target-only. Spec references are cited inline.
////
//// Spec:
////  - modules:      https://webassembly.github.io/spec/core/binary/modules.html
////  - types:        https://webassembly.github.io/spec/core/binary/types.html
////  - instructions: https://webassembly.github.io/spec/core/binary/instructions.html
////  - values:       https://webassembly.github.io/spec/core/binary/values.html

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import twocore/frontend/wasm/ast.{
  type BlockType, type Catch, type DataSegment, type ElementSegment, type Export,
  type Func, type FuncType, type Global, type Import, type Instr, type Limits,
  type MemArg, type MemType, type Module, type TableType, type Tag, type ValType,
}

// ---------------------------------------------------------------------------
// LEB128 primitives (sub-task A)
// ---------------------------------------------------------------------------

/// Decode one unsigned LEB128 integer of `width` bits from the front of `bytes`.
///
/// `width` is the number of value bits (e.g. `32` or `64`). The encoding is
/// little-endian base-128 with bit 7 of each byte the continuation flag.
///
/// Returns `Ok(#(value, rest))` where `value` is in `[0, 2^width)` and `rest` is
/// the unconsumed tail. Failure modes:
///  - `Error(ast.LebTooLong)`   — more than `ceil(width/7)` bytes are used;
///  - `Error(ast.LebOverflow)`  — the terminal byte sets bits above `width`;
///  - `Error(ast.Truncated)`    — the input ends mid-number.
/// Per the spec's integer grammar the terminal byte must satisfy
/// `n < 2^(remaining width)`; these two rejections are exactly that bound.
pub fn decode_u_n(
  bytes: BitArray,
  width: Int,
) -> Result(#(Int, BitArray), ast.DecodeError) {
  decode_u_go(bytes, width)
}

fn decode_u_go(
  bytes: BitArray,
  remaining: Int,
) -> Result(#(Int, BitArray), ast.DecodeError) {
  case bytes {
    <<byte:8, rest:bytes>> -> {
      let continues = byte >= 0x80
      let data = byte % 0x80
      case continues {
        True ->
          // Another byte follows; the width must still have room (> 7 bits).
          case remaining > 7 {
            True ->
              case decode_u_go(rest, remaining - 7) {
                Ok(#(higher, tail)) -> Ok(#(data + higher * 0x80, tail))
                Error(e) -> Error(e)
              }
            False -> Error(ast.LebTooLong)
          }
        False ->
          // Terminal byte: its 7 data bits must fit the remaining width.
          case remaining >= 7 || data < two_pow(remaining) {
            True -> Ok(#(data, rest))
            False -> Error(ast.LebOverflow)
          }
      }
    }
    _ -> Error(ast.Truncated)
  }
}

/// Decode one signed LEB128 integer of `width` bits (two's-complement) from the
/// front of `bytes`, sign-extended from the terminal byte's bit 6.
///
/// Returns `Ok(#(value, rest))` with `value` in `[-2^(width-1), 2^(width-1))`.
/// Failure modes mirror `decode_u_n`, except the OVERFLOW check is that the
/// terminal byte's unused bits must ALL equal the sign bit (else
/// `Error(ast.LebOverflow)`). Used with `width = 32` for `i32.const`, `64` for
/// `i64.const`, and `33` for blocktypes.
pub fn decode_s_n(
  bytes: BitArray,
  width: Int,
) -> Result(#(Int, BitArray), ast.DecodeError) {
  decode_s_go(bytes, width)
}

fn decode_s_go(
  bytes: BitArray,
  remaining: Int,
) -> Result(#(Int, BitArray), ast.DecodeError) {
  case bytes {
    <<byte:8, rest:bytes>> -> {
      let continues = byte >= 0x80
      let data = byte % 0x80
      case continues {
        True ->
          case remaining > 7 {
            True ->
              case decode_s_go(rest, remaining - 7) {
                Ok(#(higher, tail)) -> Ok(#(data + higher * 0x80, tail))
                Error(e) -> Error(e)
              }
            False -> Error(ast.LebTooLong)
          }
        False -> {
          // Terminal byte (`data` in 0..127). Bit 6 is the sign.
          let negative = data >= 0x40
          case negative {
            False ->
              // Non-negative: unused high bits must be 0.
              case remaining >= 7 || data < two_pow(remaining - 1) {
                True -> Ok(#(data, rest))
                False -> Error(ast.LebOverflow)
              }
            True ->
              // Negative: unused high bits must be 1 (i.e. equal the sign).
              case remaining >= 7 || data >= 0x80 - two_pow(remaining - 1) {
                True -> Ok(#(data - 0x80, rest))
                False -> Error(ast.LebOverflow)
              }
          }
        }
      }
    }
    _ -> Error(ast.Truncated)
  }
}

/// `2^n` for small non-negative `n` (a total helper used by the LEB width
/// bounds). Returns `1` for `n <= 0`.
fn two_pow(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> 2 * two_pow(n - 1)
  }
}

// ---------------------------------------------------------------------------
// Module / section framing (sub-task B)
// ---------------------------------------------------------------------------

/// Mutable-free accumulator threaded through the section loop. Each field is
/// filled by at most one section (sections are strictly ascending, so no
/// duplicates). `func_type_idxs` (from the function section) and `codes` (from
/// the code section) are paired into `Func`s once decoding finishes.
type DecodeState {
  DecodeState(
    types: List(FuncType),
    imports: List(Import),
    tables: List(TableType),
    memories: List(MemType),
    globals: List(Global),
    tags: List(Tag),
    func_type_idxs: List(Int),
    start: Option(Int),
    elements: List(ElementSegment),
    data: List(DataSegment),
    data_count: Option(Int),
    exports: List(Export),
    codes: List(#(List(ValType), List(Instr))),
  )
}

fn empty_state() -> DecodeState {
  DecodeState(
    types: [],
    imports: [],
    tables: [],
    memories: [],
    globals: [],
    tags: [],
    func_type_idxs: [],
    start: None,
    elements: [],
    data: [],
    data_count: None,
    exports: [],
    codes: [],
  )
}

/// Decode a complete `.wasm` binary into the AST.
///
/// Returns `Ok(module)` iff `bytes` is a well-formed Phase-1 module; otherwise
/// `Error(_)` with the specific reason. Never panics on any input.
///
/// Steps (spec module grammar `magic version section*`):
///  1. match the preamble (`BadMagic`/`BadVersion`/`Truncated` otherwise);
///  2. decode sections in order, each `[id][u32 size][contents]`, honoring the
///     size to slice/skip; enforce strictly-ascending non-custom ids;
///  3. pair the function and code sections into `Func`s.
pub fn decode(bytes: BitArray) -> Result(Module, ast.DecodeError) {
  case bytes {
    <<m0:8, m1:8, m2:8, m3:8, after_magic:bytes>> ->
      case m0, m1, m2, m3 {
        0x00, 0x61, 0x73, 0x6D -> decode_after_magic(after_magic)
        _, _, _, _ -> Error(ast.BadMagic)
      }
    _ -> Error(ast.BadMagic)
  }
}

fn decode_after_magic(bytes: BitArray) -> Result(Module, ast.DecodeError) {
  case bytes {
    <<v0:8, v1:8, v2:8, v3:8, body:bytes>> ->
      case v0, v1, v2, v3 {
        0x01, 0x00, 0x00, 0x00 -> {
          use state <- result.try(decode_sections(body, 0, empty_state()))
          assemble(state)
        }
        _, _, _, _ -> Error(ast.BadVersion)
      }
    // Magic present but fewer than 4 version bytes.
    _ -> Error(ast.Truncated)
  }
}

/// The section loop. `last_rank` is the canonical position (see `section_rank`) of
/// the most recent NON-custom section (`0` before any). Sections must appear in
/// strictly-ascending canonical order. Custom(0) sections may appear anywhere/any
/// number of times and are dropped without affecting `last_rank`. Reaching an empty
/// input ends the module cleanly.
fn decode_sections(
  bytes: BitArray,
  last_rank: Int,
  state: DecodeState,
) -> Result(DecodeState, ast.DecodeError) {
  case bytes {
    <<>> -> Ok(state)
    <<id:8, after_id:bytes>> -> {
      use #(size, after_size) <- result.try(decode_u_n(after_id, 32))
      case after_size {
        <<contents:size(size)-bytes, tail:bytes>> ->
          case id == 0 {
            // Custom section: skip, keep last_rank.
            True -> decode_sections(tail, last_rank, state)
            False -> {
              let rank = section_rank(id)
              case rank <= last_rank {
                True -> Error(ast.SectionOrder)
                False -> {
                  use next <- result.try(dispatch_section(id, contents, state))
                  decode_sections(tail, rank, next)
                }
              }
            }
          }
        // Declared size exceeds the remaining bytes.
        _ -> Error(ast.Truncated)
      }
    }
    // Unreachable for byte-aligned input; kept for totality.
    _ -> Error(ast.Truncated)
  }
}

/// The canonical position of a non-custom section for the ascending-order check.
/// Two sections do NOT order by raw id: the tag section (13) sits between memory (5)
/// and global (6) per the EH proposal, and the datacount section (12) between element
/// (9) and code (10) per bulk-memory. So: tag(13) → 6, then global(6) → 7, export(7) →
/// 8, start(8) → 9, element(9) → 10, datacount(12) → 11, code(10) → 12, data(11) → 13;
/// ids 1..5 keep their id. This keeps the order `type < import < function < table <
/// memory < TAG < global < export < start < element < datacount < code < data` strictly
/// ascending — so a tag-free module's accept/reject decisions are byte-identical (§G),
/// while a misplaced tag section (e.g. after global) is rejected with `SectionOrder`.
fn section_rank(id: Int) -> Int {
  case id {
    13 -> 6
    6 -> 7
    7 -> 8
    8 -> 9
    9 -> 10
    12 -> 11
    10 -> 12
    11 -> 13
    _ -> id
  }
}

/// Run the sub-decoder for a known in-scope section over its exact `contents`
/// slice, asserting full consumption (`SectionSizeMismatch` on under-run). The
/// import section (2) stays out of scope (non-function imports → Phase 3) and is
/// skipped by discarding `contents`.
fn dispatch_section(
  id: Int,
  contents: BitArray,
  state: DecodeState,
) -> Result(DecodeState, ast.DecodeError) {
  case id {
    // type section: vec(functype)
    1 -> {
      use #(types, rest) <- result.try(decode_vec(contents, decode_functype))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, types: types))
    }
    // import section: vec(import) — non-function imports are Phase-5 in scope.
    2 -> {
      use #(imports, rest) <- result.try(decode_vec(contents, decode_import))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, imports: imports))
    }
    // table section: vec(tabletype)
    4 -> {
      use #(tables, rest) <- result.try(decode_vec(contents, decode_tabletype))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, tables: tables))
    }
    // memory section: vec(memtype)
    5 -> {
      use #(memories, rest) <- result.try(decode_vec(contents, decode_memtype))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, memories: memories))
    }
    // global section: vec(global)
    6 -> {
      use #(globals, rest) <- result.try(decode_vec(contents, decode_global))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, globals: globals))
    }
    // function section: vec(typeidx)
    3 -> {
      use #(idxs, rest) <- result.try(
        decode_vec(contents, fn(b) { decode_u_n(b, 32) }),
      )
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, func_type_idxs: idxs))
    }
    // export section: vec(export)
    7 -> {
      use #(exports, rest) <- result.try(decode_vec(contents, decode_export))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, exports: exports))
    }
    // start section: a single funcidx
    8 -> {
      use #(idx, rest) <- result.try(decode_u_n(contents, 32))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, start: Some(idx)))
    }
    // element section: vec(elem)
    9 -> {
      use #(elements, rest) <- result.try(decode_vec(contents, decode_elemseg))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, elements: elements))
    }
    // code section: vec(code)
    10 -> {
      use #(codes, rest) <- result.try(decode_vec(contents, decode_code))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, codes: codes))
    }
    // data section: vec(data)
    11 -> {
      use #(data, rest) <- result.try(decode_vec(contents, decode_dataseg))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, data: data))
    }
    // datacount section (id 12): a single u32 giving the number of data segments.
    // The `== length(data)` and "required for memory.init/data.drop" checks are in
    // `assemble` (R13 / spec §5.5.14).
    12 -> {
      use #(count, rest) <- result.try(decode_u_n(contents, 32))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, data_count: Some(count)))
    }
    // tag section (id 13): vec(tag), each `attribute:0x00 x:typeidx` (Phase 7).
    13 -> {
      use #(tags, rest) <- result.try(decode_vec(contents, decode_tag))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, tags: tags))
    }
    // any unknown id: already sliced by the caller, so just drop the contents.
    _ -> Ok(state)
  }
}

/// Decode one tag `attribute:0x00 x:typeidx` (tag section, id 13; Phase 7). The
/// attribute MUST be `0x00` (the exception attribute — the only kind defined); any
/// other byte is `Error(ast.BadTagAttribute)`. `typeidx` is a `u32` into `Module.types`;
/// that it names a functype with empty results is validate's check. EOF before the
/// attribute/typeidx is `Error(ast.Truncated)`.
fn decode_tag(bytes: BitArray) -> Result(#(Tag, BitArray), ast.DecodeError) {
  case bytes {
    <<0x00, r0:bytes>> -> {
      use #(type_idx, r1) <- result.try(decode_u_n(r0, 32))
      Ok(#(ast.Tag(type_idx: type_idx), r1))
    }
    <<_:8, _:bytes>> -> Error(ast.BadTagAttribute)
    _ -> Error(ast.Truncated)
  }
}

/// `Ok(Nil)` iff `bytes` is empty, else `Error(ast.SectionSizeMismatch)`. Used to
/// assert a section sub-decoder consumed exactly its slice.
fn expect_empty(bytes: BitArray) -> Result(Nil, ast.DecodeError) {
  case bytes {
    <<>> -> Ok(Nil)
    _ -> Error(ast.SectionSizeMismatch)
  }
}

/// Pair the function section's type indices with the code section's bodies into
/// `Func`s, then build the `Module`.
///
/// Failure modes:
///  - `Error(ast.FuncCodeCountMismatch)` if the function and code vectors differ in
///    length (the spec requires them equal);
///  - `Error(ast.DataCountMissing)` if any function body uses `memory.init`/
///    `data.drop` but the module has no datacount section (R13 / spec §5.5.14);
///  - `Error(ast.DataCountMismatch)` if a datacount section is present but its count
///    does not equal the number of data segments (spec §5.5.14).
///
/// `imported_func_count` is COMPUTED as the number of `ImportFunc` importdescs (0
/// for a module with no import section → byte-identical to Phase 4).
fn assemble(state: DecodeState) -> Result(Module, ast.DecodeError) {
  use funcs <- result.try(zip_funcs(state.func_type_idxs, state.codes))
  use _ <- result.try(check_data_count(state.data_count, state.data, funcs))
  let imported_func_count =
    list.fold(state.imports, 0, fn(acc, imp) {
      case imp.desc {
        ast.ImportFunc(_) -> acc + 1
        _ -> acc
      }
    })
  Ok(ast.Module(
    imported_func_count: imported_func_count,
    types: state.types,
    imports: state.imports,
    tables: state.tables,
    memories: state.memories,
    globals: state.globals,
    tags: state.tags,
    funcs: funcs,
    start: state.start,
    elements: state.elements,
    data: state.data,
    data_count: state.data_count,
    exports: state.exports,
  ))
}

/// The datacount-section wellformedness check decode owns (R13 / spec §5.5.14).
///
/// - If a datacount section is present, its `count` must equal the number of data
///   segments (`Error(ast.DataCountMismatch)` otherwise).
/// - If any function body uses `memory.init` or `data.drop` (the two instructions
///   that reference a data-segment index), a datacount section is REQUIRED
///   (`Error(ast.DataCountMissing)` if absent — the spec's `assert_malformed "data
///   count section required"`). `memory.init`/`data.drop` can only appear in code,
///   so scanning `funcs` bodies suffices.
fn check_data_count(
  data_count: Option(Int),
  data: List(DataSegment),
  funcs: List(Func),
) -> Result(Nil, ast.DecodeError) {
  case data_count {
    Some(n) ->
      case n == list.length(data) {
        True -> Ok(Nil)
        False -> Error(ast.DataCountMismatch)
      }
    None ->
      case list.any(funcs, fn(f) { list.any(f.body, uses_data_segment) }) {
        True -> Error(ast.DataCountMissing)
        False -> Ok(Nil)
      }
  }
}

/// Whether an instruction references a data-segment index (`memory.init`/
/// `data.drop`), and so requires a datacount section (spec §5.5.14).
fn uses_data_segment(instr: Instr) -> Bool {
  case instr {
    ast.MemoryInit(_, _) -> True
    ast.DataDrop(_) -> True
    _ -> False
  }
}

fn zip_funcs(
  idxs: List(Int),
  codes: List(#(List(ValType), List(Instr))),
) -> Result(List(Func), ast.DecodeError) {
  case idxs, codes {
    [], [] -> Ok([])
    [ti, ..ts], [#(locals, body), ..cs] -> {
      use rest <- result.try(zip_funcs(ts, cs))
      Ok([ast.Func(type_idx: ti, locals: locals, body: body), ..rest])
    }
    _, _ -> Error(ast.FuncCodeCountMismatch)
  }
}

// ---------------------------------------------------------------------------
// Generic vector + leaf decoders
// ---------------------------------------------------------------------------

/// Decode a spec vector `vec(X) = [u32 count][X…]`: a `u32` element count
/// followed by that many `elem`-decoded items. Returns the items in order plus
/// the unconsumed tail. Propagates any `elem`/count error.
fn decode_vec(
  bytes: BitArray,
  elem: fn(BitArray) -> Result(#(a, BitArray), ast.DecodeError),
) -> Result(#(List(a), BitArray), ast.DecodeError) {
  use #(count, rest) <- result.try(decode_u_n(bytes, 32))
  decode_vec_n(rest, count, elem, [])
}

fn decode_vec_n(
  bytes: BitArray,
  remaining: Int,
  elem: fn(BitArray) -> Result(#(a, BitArray), ast.DecodeError),
  acc: List(a),
) -> Result(#(List(a), BitArray), ast.DecodeError) {
  case remaining <= 0 {
    True -> Ok(#(list.reverse(acc), bytes))
    False -> {
      use #(item, rest) <- result.try(elem(bytes))
      decode_vec_n(rest, remaining - 1, elem, [item, ..acc])
    }
  }
}

/// Decode one value type byte: `0x7F→I32 0x7E→I64 0x7D→F32 0x7C→F64`, the SIMD vector
/// type `0x7B→V128` (Phase 6, `«WASM-AST4»`), the two MVP reference types
/// `0x70→FuncRef 0x6F→ExternRef` (Phase 5), plus the exception reference type
/// `0x69→ExnRef` (Phase 7, `«WASM-AST5»`). Any other byte (a GC heaptype, …) is
/// `Error(ast.BadValType)`; empty input is `Error(ast.Truncated)`. Used at every valtype
/// site (params/results, locals, globals, typed `select` vectors). `v128` is NOT a
/// reftype — `decode_reftype` still rejects `0x7B` — but `exn` (`0x69`) IS a heaptype,
/// so `decode_reftype` DOES accept it (for `ref.null exn`).
fn decode_valtype(
  bytes: BitArray,
) -> Result(#(ValType, BitArray), ast.DecodeError) {
  case bytes {
    <<b:8, rest:bytes>> ->
      case b {
        0x7F -> Ok(#(ast.I32, rest))
        0x7E -> Ok(#(ast.I64, rest))
        0x7D -> Ok(#(ast.F32, rest))
        0x7C -> Ok(#(ast.F64, rest))
        0x7B -> Ok(#(ast.V128, rest))
        0x70 -> Ok(#(ast.FuncRef, rest))
        0x6F -> Ok(#(ast.ExternRef, rest))
        0x69 -> Ok(#(ast.ExnRef, rest))
        _ -> Error(ast.BadValType)
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode one REFTYPE byte at a reftype-only position: `0x70→FuncRef`,
/// `0x6F→ExternRef`, `0x69→ExnRef` (Phase 7 — `exn` is a legal abstract heaptype).
/// Any other byte (a number type, `v128`, a GC heaptype) is `Error(ast.BadHeapType)`;
/// empty input is `Error(ast.Truncated)`. Used by `ref.null`'s heaptype operand, a
/// `tabletype`'s element type, and an element segment's flag-5/6/7 reftype (spec
/// binary/types.html#reference-types). Unlike `v128`, `exn` (`0x69`) is accepted here so
/// `ref.null exn` (`0xD0 0x69`) decodes to `RefNull(ExnRef)`; validate owns whether an
/// `exnref` may legally appear in a given table/global/element position.
fn decode_reftype(
  bytes: BitArray,
) -> Result(#(ValType, BitArray), ast.DecodeError) {
  case bytes {
    <<b:8, rest:bytes>> ->
      case b {
        0x70 -> Ok(#(ast.FuncRef, rest))
        0x6F -> Ok(#(ast.ExternRef, rest))
        0x69 -> Ok(#(ast.ExnRef, rest))
        _ -> Error(ast.BadHeapType)
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode a global's `mut` byte: `0x00`→`False` (const), `0x01`→`True` (var). Any
/// other byte is `Error(ast.BadMutability)`; empty input is `Error(ast.Truncated)`.
fn decode_mut(bytes: BitArray) -> Result(#(Bool, BitArray), ast.DecodeError) {
  case bytes {
    <<0x00, rest:bytes>> -> Ok(#(False, rest))
    <<0x01, rest:bytes>> -> Ok(#(True, rest))
    <<_:8, _:bytes>> -> Error(ast.BadMutability)
    _ -> Error(ast.Truncated)
  }
}

/// Decode one function type `0x60 vec(valtype) vec(valtype)`. `Error(
/// ast.BadFuncTypeForm)` if the leading tag is not `0x60`.
fn decode_functype(
  bytes: BitArray,
) -> Result(#(FuncType, BitArray), ast.DecodeError) {
  case bytes {
    <<b:8, after_tag:bytes>> ->
      case b {
        0x60 -> {
          use #(params, r1) <- result.try(decode_vec(after_tag, decode_valtype))
          use #(results, r2) <- result.try(decode_vec(r1, decode_valtype))
          Ok(#(ast.FuncType(params: params, results: results), r2))
        }
        _ -> Error(ast.BadFuncTypeForm)
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode a length-prefixed UTF-8 name `[u32 len][len bytes]`. The bytes are NOT
/// null-terminated and MUST be valid UTF-8 (`Error(ast.InvalidUtf8)` otherwise).
fn decode_name(
  bytes: BitArray,
) -> Result(#(String, BitArray), ast.DecodeError) {
  use #(len, after_len) <- result.try(decode_u_n(bytes, 32))
  case after_len {
    <<raw:size(len)-bytes, rest:bytes>> ->
      case bit_array.to_string(raw) {
        Ok(s) -> Ok(#(s, rest))
        Error(_) -> Error(ast.InvalidUtf8)
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode one export `[name][kind:8][idx u32]`. Kind byte `0x00`..`0x04` maps to
/// the five `ExportKind`s (`0x04 → ExportTag`, a tag export — Phase 7); anything else
/// is `Error(ast.BadExportKind)`.
fn decode_export(
  bytes: BitArray,
) -> Result(#(Export, BitArray), ast.DecodeError) {
  use #(name, after_name) <- result.try(decode_name(bytes))
  case after_name {
    <<kind_byte:8, after_kind:bytes>> -> {
      use kind <- result.try(case kind_byte {
        0x00 -> Ok(ast.ExportFunc)
        0x01 -> Ok(ast.ExportTable)
        0x02 -> Ok(ast.ExportMemory)
        0x03 -> Ok(ast.ExportGlobal)
        0x04 -> Ok(ast.ExportTag)
        _ -> Error(ast.BadExportKind)
      })
      use #(index, rest) <- result.try(decode_u_n(after_kind, 32))
      Ok(#(ast.Export(name: name, kind: kind, index: index), rest))
    }
    _ -> Error(ast.Truncated)
  }
}

// ---------------------------------------------------------------------------
// Section 4/5/6/9/11 leaf decoders (table / memory / global / element / data)
// ---------------------------------------------------------------------------

/// Decode a `u32` `limits` for a TABLE (spec binary/types.html): flag `0x00` →
/// `Limits(min, None)`; flag `0x01` → `Limits(min, Some(max))`; `min`/`max` are
/// `u32`. Any other flag (shared `0x02`/`0x03`, or the index-type bit `0x04` —
/// table64 is out of scope) is `Error(ast.BadLimitsFlag)`. The spec bound
/// `min <= max` is NOT checked here — that is validate's job.
fn decode_limits(
  bytes: BitArray,
) -> Result(#(Limits, BitArray), ast.DecodeError) {
  case bytes {
    <<flag:8, after_flag:bytes>> ->
      case flag {
        0x00 -> {
          use #(min, rest) <- result.try(decode_u_n(after_flag, 32))
          Ok(#(ast.Limits(min: min, max: None), rest))
        }
        0x01 -> {
          use #(min, r1) <- result.try(decode_u_n(after_flag, 32))
          use #(max, r2) <- result.try(decode_u_n(r1, 32))
          Ok(#(ast.Limits(min: min, max: Some(max)), r2))
        }
        _ -> Error(ast.BadLimitsFlag)
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode a MEMORY `limits` including the memory64 index-type flag (spec
/// binary/types.html + the memory64 proposal). The flag byte is a bitfield: bit 0
/// (`0x01`) has-max, bit 1 (`0x02`) shared (threads — out of scope), bit 2 (`0x04`)
/// i64 index type. In scope:
///  - `0x00` → `#(Limits(min, None), Idx32)`, `min` a `u32`;
///  - `0x01` → `#(Limits(min, Some(max)), Idx32)`, `min`/`max` `u32`;
///  - `0x04` → `#(Limits(min, None), Idx64)`, `min` a `u64` (memory64);
///  - `0x05` → `#(Limits(min, Some(max)), Idx64)`, `min`/`max` `u64` (memory64).
/// Shared flags (`0x02`/`0x03`) and any flag `>= 0x06` are `Error(ast.BadLimitsFlag)`.
/// `min <= max <= range` is validate's job (R12: memory64 decode/validate only).
fn decode_mem_limits(
  bytes: BitArray,
) -> Result(#(Limits, ast.IdxType, BitArray), ast.DecodeError) {
  case bytes {
    <<flag:8, after_flag:bytes>> ->
      case flag {
        0x00 -> {
          use #(min, rest) <- result.try(decode_u_n(after_flag, 32))
          Ok(#(ast.Limits(min: min, max: None), ast.Idx32, rest))
        }
        0x01 -> {
          use #(min, r1) <- result.try(decode_u_n(after_flag, 32))
          use #(max, r2) <- result.try(decode_u_n(r1, 32))
          Ok(#(ast.Limits(min: min, max: Some(max)), ast.Idx32, r2))
        }
        0x04 -> {
          use #(min, rest) <- result.try(decode_u_n(after_flag, 64))
          Ok(#(ast.Limits(min: min, max: None), ast.Idx64, rest))
        }
        0x05 -> {
          use #(min, r1) <- result.try(decode_u_n(after_flag, 64))
          use #(max, r2) <- result.try(decode_u_n(r1, 64))
          Ok(#(ast.Limits(min: min, max: Some(max)), ast.Idx64, r2))
        }
        _ -> Error(ast.BadLimitsFlag)
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode one `tabletype` = `reftype limits`. The reftype element byte is decoded
/// with `decode_reftype`, so `funcref` (`0x70`) AND `externref` (`0x6F`) are both
/// accepted (Phase 5); a non-reftype byte is `Error(ast.BadHeapType)`. Table limits
/// stay i32-indexed (`decode_limits`); table64 is out of scope.
fn decode_tabletype(
  bytes: BitArray,
) -> Result(#(TableType, BitArray), ast.DecodeError) {
  use #(elem_type, r1) <- result.try(decode_reftype(bytes))
  use #(limits, r2) <- result.try(decode_limits(r1))
  Ok(#(ast.TableType(elem_type: elem_type, limits: limits), r2))
}

/// Decode one `memtype` = `limits` (in 64KiB pages) with its address width
/// (`decode_mem_limits`). A `0x04`/`0x05` flag yields an `Idx64` (memory64) memory.
fn decode_memtype(
  bytes: BitArray,
) -> Result(#(MemType, BitArray), ast.DecodeError) {
  use #(limits, idx_type, rest) <- result.try(decode_mem_limits(bytes))
  Ok(#(ast.MemType(limits: limits, idx_type: idx_type), rest))
}

/// Decode one import `mod:name nm:name d:importdesc` (spec
/// binary/modules.html#import-section). The importdesc kind byte selects:
/// `0x00 x:typeidx` (func), `0x01 tt:tabletype` (table), `0x02 mt:memtype` (mem),
/// `0x03 t:valtype m:mut` (global), `0x04 0x00 x:typeidx` (tag — Phase 7). Any other
/// kind byte is `Error(ast.BadImportKind)`; a missing kind byte is
/// `Error(ast.Truncated)`. Decode records the declaration only — resolution/typing is
/// validate/link's job.
fn decode_import(
  bytes: BitArray,
) -> Result(#(Import, BitArray), ast.DecodeError) {
  use #(module, r1) <- result.try(decode_name(bytes))
  use #(name, r2) <- result.try(decode_name(r1))
  case r2 {
    <<kind:8, r3:bytes>> ->
      case kind {
        0x00 -> {
          use #(type_idx, r) <- result.try(decode_u_n(r3, 32))
          Ok(#(ast.Import(module, name, ast.ImportFunc(type_idx)), r))
        }
        0x01 -> {
          use #(tt, r) <- result.try(decode_tabletype(r3))
          Ok(#(ast.Import(module, name, ast.ImportTable(tt)), r))
        }
        0x02 -> {
          use #(mt, r) <- result.try(decode_memtype(r3))
          Ok(#(ast.Import(module, name, ast.ImportMemory(mt)), r))
        }
        0x03 -> {
          use #(ty, r4) <- result.try(decode_valtype(r3))
          use #(mutable, r) <- result.try(decode_mut(r4))
          Ok(#(ast.Import(module, name, ast.ImportGlobal(ty, mutable)), r))
        }
        // imported tag (Phase 7): attribute 0x00 THEN typeidx. A non-0x00 attribute
        // is `BadTagAttribute`; EOF before the attribute is `Truncated`.
        0x04 ->
          case r3 {
            <<0x00, r4:bytes>> -> {
              use #(type_idx, r) <- result.try(decode_u_n(r4, 32))
              Ok(#(ast.Import(module, name, ast.ImportTag(type_idx)), r))
            }
            <<_:8, _:bytes>> -> Error(ast.BadTagAttribute)
            _ -> Error(ast.Truncated)
          }
        _ -> Error(ast.BadImportKind)
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode one `global` = `valtype mut const-expr`. The `mut` byte is `0x00`
/// (const → `False`) or `0x01` (var → `True`); anything else is
/// `Error(ast.BadMutability)`. The const-expr is decoded structurally
/// (`decode_const_expr`); its const-ness is validate's job.
fn decode_global(
  bytes: BitArray,
) -> Result(#(Global, BitArray), ast.DecodeError) {
  use #(ty, after_ty) <- result.try(decode_valtype(bytes))
  use #(mutable, after_mut) <- result.try(decode_mut(after_ty))
  use #(init, rest) <- result.try(decode_const_expr(after_mut))
  Ok(#(ast.Global(ty: ty, mutable: mutable, init: init), rest))
}

/// Decode a constant expression: an instruction sequence terminated by a depth-0
/// `End` (`0x0B`), block-nesting tracked exactly like `decode_expr`. Returns the
/// instructions BEFORE that terminating `End` (the `End` is consumed, not
/// stored). PURELY STRUCTURAL — it does not reject non-const opcodes (the
/// const-expr restriction is validate's, unit 08). Total over any bytes.
fn decode_const_expr(
  bytes: BitArray,
) -> Result(#(List(Instr), BitArray), ast.DecodeError) {
  decode_const_go(bytes, 0, [])
}

fn decode_const_go(
  bytes: BitArray,
  depth: Int,
  acc: List(Instr),
) -> Result(#(List(Instr), BitArray), ast.DecodeError) {
  use #(instr, rest) <- result.try(decode_instr(bytes))
  case instr {
    ast.End ->
      case depth {
        0 -> Ok(#(list.reverse(acc), rest))
        _ -> decode_const_go(rest, depth - 1, [ast.End, ..acc])
      }
    // Block-openers (Phase 7 adds `try_table`/`try`): deepen nesting.
    ast.Block(_)
    | ast.Loop(_)
    | ast.If(_)
    | ast.TryTable(_, _)
    | ast.TryLegacy(_) -> decode_const_go(rest, depth + 1, [instr, ..acc])
    // A legacy `delegate` terminates its enclosing `try` (a closer, replacing `End`).
    // At depth 0 it is mis-nested — fail-closed with the dedicated `BadDelegate`.
    ast.LegacyDelegate(_) ->
      case depth {
        0 -> Error(ast.BadDelegate)
        _ -> decode_const_go(rest, depth - 1, [instr, ..acc])
      }
    _ -> decode_const_go(rest, depth, [instr, ..acc])
  }
}

/// Decode one element segment across the full flag 0–7 grammar (spec
/// binary/modules.html#element-section). A leading `u32` flag selects the mode and
/// init form; the bits mean bit 0 = passive-or-declarative, bit 1 = (explicit
/// tableidx | declarative-vs-passive), bit 2 = expression init + explicit reftype:
///
/// ```text
/// 0 ⇒ e:expr             y*:vec(funcidx)  ⇒ active table 0, funcref, ElemFuncs
/// 1 ⇒ et:elemkind        y*:vec(funcidx)  ⇒ passive,        funcref, ElemFuncs
/// 2 ⇒ x:tableidx e:expr et:elemkind y*    ⇒ active table x, funcref, ElemFuncs
/// 3 ⇒ et:elemkind        y*:vec(funcidx)  ⇒ declarative,    funcref, ElemFuncs
/// 4 ⇒ e:expr             el*:vec(expr)    ⇒ active table 0, funcref, ElemExprs
/// 5 ⇒ et:reftype         el*:vec(expr)    ⇒ passive,        reftype, ElemExprs
/// 6 ⇒ x:tableidx e:expr et:reftype el*    ⇒ active table x, reftype, ElemExprs
/// 7 ⇒ et:reftype         el*:vec(expr)    ⇒ declarative,    reftype, ElemExprs
/// ```
///
/// `elemkind` must be `0x00` (funcref); flags 0/4 fix `table 0` + `FuncRef` with no
/// byte on the wire; flags 2/6 read the tableidx BEFORE the offset expr. A flag `> 7`
/// or a non-`0x00` elemkind is `Error(ast.BadElemKind)`; a non-reftype byte in flags
/// 5/6/7 is `Error(ast.BadHeapType)`.
fn decode_elemseg(
  bytes: BitArray,
) -> Result(#(ElementSegment, BitArray), ast.DecodeError) {
  use #(flag, r0) <- result.try(decode_u_n(bytes, 32))
  case flag {
    0 -> {
      use #(offset, r1) <- result.try(decode_const_expr(r0))
      use #(funcs, r2) <- result.try(decode_funcidx_vec(r1))
      Ok(#(
        ast.ElementSegment(
          ast.ElemActive(0, offset),
          ast.FuncRef,
          ast.ElemFuncs(funcs),
        ),
        r2,
      ))
    }
    1 -> {
      use r1 <- result.try(decode_elemkind(r0))
      use #(funcs, r2) <- result.try(decode_funcidx_vec(r1))
      Ok(#(
        ast.ElementSegment(ast.ElemPassive, ast.FuncRef, ast.ElemFuncs(funcs)),
        r2,
      ))
    }
    2 -> {
      use #(table, r1) <- result.try(decode_u_n(r0, 32))
      use #(offset, r2) <- result.try(decode_const_expr(r1))
      use r3 <- result.try(decode_elemkind(r2))
      use #(funcs, r4) <- result.try(decode_funcidx_vec(r3))
      Ok(#(
        ast.ElementSegment(
          ast.ElemActive(table, offset),
          ast.FuncRef,
          ast.ElemFuncs(funcs),
        ),
        r4,
      ))
    }
    3 -> {
      use r1 <- result.try(decode_elemkind(r0))
      use #(funcs, r2) <- result.try(decode_funcidx_vec(r1))
      Ok(#(
        ast.ElementSegment(
          ast.ElemDeclarative,
          ast.FuncRef,
          ast.ElemFuncs(funcs),
        ),
        r2,
      ))
    }
    4 -> {
      use #(offset, r1) <- result.try(decode_const_expr(r0))
      use #(exprs, r2) <- result.try(decode_vec(r1, decode_const_expr))
      Ok(#(
        ast.ElementSegment(
          ast.ElemActive(0, offset),
          ast.FuncRef,
          ast.ElemExprs(exprs),
        ),
        r2,
      ))
    }
    5 -> {
      use #(ref_ty, r1) <- result.try(decode_reftype(r0))
      use #(exprs, r2) <- result.try(decode_vec(r1, decode_const_expr))
      Ok(#(
        ast.ElementSegment(ast.ElemPassive, ref_ty, ast.ElemExprs(exprs)),
        r2,
      ))
    }
    6 -> {
      use #(table, r1) <- result.try(decode_u_n(r0, 32))
      use #(offset, r2) <- result.try(decode_const_expr(r1))
      use #(ref_ty, r3) <- result.try(decode_reftype(r2))
      use #(exprs, r4) <- result.try(decode_vec(r3, decode_const_expr))
      Ok(#(
        ast.ElementSegment(
          ast.ElemActive(table, offset),
          ref_ty,
          ast.ElemExprs(exprs),
        ),
        r4,
      ))
    }
    7 -> {
      use #(ref_ty, r1) <- result.try(decode_reftype(r0))
      use #(exprs, r2) <- result.try(decode_vec(r1, decode_const_expr))
      Ok(#(
        ast.ElementSegment(ast.ElemDeclarative, ref_ty, ast.ElemExprs(exprs)),
        r2,
      ))
    }
    _ -> Error(ast.BadElemKind)
  }
}

/// Decode a `vec(funcidx)` (a `u32` count then that many `u32` funcidxs).
fn decode_funcidx_vec(
  bytes: BitArray,
) -> Result(#(List(Int), BitArray), ast.DecodeError) {
  decode_vec(bytes, fn(b) { decode_u_n(b, 32) })
}

/// Decode an `elemkind` byte (element flags 1/2/3). Only `0x00` (funcref) is valid;
/// any other byte is `Error(ast.BadElemKind)`, EOF is `Error(ast.Truncated)`. Returns
/// the unconsumed tail (the kind carries no payload beyond funcref in Phase-5 scope).
fn decode_elemkind(bytes: BitArray) -> Result(BitArray, ast.DecodeError) {
  case bytes {
    <<0x00, rest:bytes>> -> Ok(rest)
    <<_:8, _:bytes>> -> Error(ast.BadElemKind)
    _ -> Error(ast.Truncated)
  }
}

/// Decode one data segment across the flag 0/1/2 grammar (spec
/// binary/modules.html#data-section):
///
/// ```text
/// 0 ⇒ e:expr           b*:vec(byte)  ⇒ active mem 0, offset e
/// 1 ⇒                  b*:vec(byte)  ⇒ passive
/// 2 ⇒ x:memidx e:expr  b*:vec(byte)  ⇒ active mem x, offset e
/// ```
///
/// Flag 2's `memidx` may be non-zero (multi-memory). Any other flag is
/// `Error(ast.BadDataKind)`.
fn decode_dataseg(
  bytes: BitArray,
) -> Result(#(DataSegment, BitArray), ast.DecodeError) {
  use #(flag, r0) <- result.try(decode_u_n(bytes, 32))
  case flag {
    0 -> {
      use #(offset, r1) <- result.try(decode_const_expr(r0))
      use #(payload, r2) <- result.try(decode_vec_bytes(r1))
      Ok(#(ast.DataSegment(ast.DataActive(0, offset), payload), r2))
    }
    1 -> {
      use #(payload, r1) <- result.try(decode_vec_bytes(r0))
      Ok(#(ast.DataSegment(ast.DataPassive, payload), r1))
    }
    2 -> {
      use #(memidx, r1) <- result.try(decode_u_n(r0, 32))
      use #(offset, r2) <- result.try(decode_const_expr(r1))
      use #(payload, r3) <- result.try(decode_vec_bytes(r2))
      Ok(#(ast.DataSegment(ast.DataActive(memidx, offset), payload), r3))
    }
    _ -> Error(ast.BadDataKind)
  }
}

/// Decode a `vec(byte)` = `[u32 count][count raw bytes]` into a `BitArray`. An
/// oversized `count` (more than the remaining bytes) fails the slice match and is
/// reported `Error(ast.Truncated)` (fail-closed; never over-reads).
fn decode_vec_bytes(
  bytes: BitArray,
) -> Result(#(BitArray, BitArray), ast.DecodeError) {
  use #(count, rest) <- result.try(decode_u_n(bytes, 32))
  case rest {
    <<payload:size(count)-bytes, tail:bytes>> -> Ok(#(payload, tail))
    _ -> Error(ast.Truncated)
  }
}

// ---------------------------------------------------------------------------
// Code section: locals (RLE) + the instruction stream
// ---------------------------------------------------------------------------

/// Decode one code entry `[u32 size][vec(locals)][expr]`. The `size` bounds the
/// entry; `Error(ast.SectionSizeMismatch)` if the locals+expr do not consume it
/// exactly. Returns `#(expanded_locals, body)` (see `decode_locals`,
/// `decode_expr`).
fn decode_code(
  bytes: BitArray,
) -> Result(#(#(List(ValType), List(Instr)), BitArray), ast.DecodeError) {
  use #(size, after_size) <- result.try(decode_u_n(bytes, 32))
  case after_size {
    <<body_bytes:size(size)-bytes, rest:bytes>> -> {
      use #(locals, after_locals) <- result.try(decode_locals(body_bytes))
      use #(instrs, after_expr) <- result.try(decode_expr(after_locals, 0, []))
      case after_expr {
        <<>> -> Ok(#(#(locals, instrs), rest))
        _ -> Error(ast.SectionSizeMismatch)
      }
    }
    _ -> Error(ast.Truncated)
  }
}

/// Decode `vec(locals)` and RLE-EXPAND it: a count of groups, each
/// `[u32 n][valtype]`, producing `n` copies of the valtype, concatenated in
/// declaration order.
fn decode_locals(
  bytes: BitArray,
) -> Result(#(List(ValType), BitArray), ast.DecodeError) {
  use #(group_count, rest) <- result.try(decode_u_n(bytes, 32))
  use #(groups, rest2) <- result.try(
    decode_locals_groups(rest, group_count, []),
  )
  Ok(#(list.flatten(groups), rest2))
}

fn decode_locals_groups(
  bytes: BitArray,
  remaining: Int,
  acc: List(List(ValType)),
) -> Result(#(List(List(ValType)), BitArray), ast.DecodeError) {
  case remaining <= 0 {
    True -> Ok(#(list.reverse(acc), bytes))
    False -> {
      use #(n, r1) <- result.try(decode_u_n(bytes, 32))
      use #(vt, r2) <- result.try(decode_valtype(r1))
      decode_locals_groups(r2, remaining - 1, [list.repeat(vt, n), ..acc])
    }
  }
}

/// Decode a structured-control blocktype: one signed-LEB(33). A non-negative
/// value is a `BlockTypeIdx`; `-64` is `BlockEmpty`; the negative valtype encodings
/// are the four number types `-1`..`-4`, the SIMD vector type `v128` (`0x7B` as
/// s33 = `-5`, Phase 6), the two reference types funcref (`0x70` as s33 = `-16`)
/// / externref (`0x6F` = `-17`), and the exception reference type exnref (`0x69` as
/// s33 = `-23`, Phase 7); any other negative value is `Error(ast.BadBlockType)`.
fn decode_blocktype(
  bytes: BitArray,
) -> Result(#(BlockType, BitArray), ast.DecodeError) {
  use #(v, rest) <- result.try(decode_s_n(bytes, 33))
  case v {
    _ if v >= 0 -> Ok(#(ast.BlockTypeIdx(v), rest))
    _ if v == -64 -> Ok(#(ast.BlockEmpty, rest))
    _ if v == -1 -> Ok(#(ast.BlockVal(ast.I32), rest))
    _ if v == -2 -> Ok(#(ast.BlockVal(ast.I64), rest))
    _ if v == -3 -> Ok(#(ast.BlockVal(ast.F32), rest))
    _ if v == -4 -> Ok(#(ast.BlockVal(ast.F64), rest))
    _ if v == -5 -> Ok(#(ast.BlockVal(ast.V128), rest))
    _ if v == -16 -> Ok(#(ast.BlockVal(ast.FuncRef), rest))
    _ if v == -17 -> Ok(#(ast.BlockVal(ast.ExternRef), rest))
    _ if v == -23 -> Ok(#(ast.BlockVal(ast.ExnRef), rest))
    _ -> Error(ast.BadBlockType)
  }
}

/// Decode a function expression into a FLAT instruction list, tracking block
/// nesting `depth`. Each `block`/`loop`/`if` deepens nesting (its closing `End`
/// pops it); the `End` encountered at `depth = 0` terminates the expression and
/// is INCLUDED as the final element of the returned list (matching `Func.body`).
fn decode_expr(
  bytes: BitArray,
  depth: Int,
  acc: List(Instr),
) -> Result(#(List(Instr), BitArray), ast.DecodeError) {
  use #(instr, rest) <- result.try(decode_instr(bytes))
  case instr {
    ast.End ->
      case depth {
        0 -> Ok(#(list.reverse([ast.End, ..acc]), rest))
        _ -> decode_expr(rest, depth - 1, [ast.End, ..acc])
      }
    // Block-openers (Phase 7 adds `try_table`/`try`): deepen nesting so their body's
    // `End` is not mistaken for the function terminator.
    ast.Block(_)
    | ast.Loop(_)
    | ast.If(_)
    | ast.TryTable(_, _)
    | ast.TryLegacy(_) -> decode_expr(rest, depth + 1, [instr, ..acc])
    // A legacy `delegate` terminates its enclosing `try` (a closer, replacing its
    // `End`), so it pops one nesting level. Only `End` may terminate the whole
    // expression at depth 0; a `delegate` there is mis-nested → `BadDelegate`.
    ast.LegacyDelegate(_) ->
      case depth {
        0 -> Error(ast.BadDelegate)
        _ -> decode_expr(rest, depth - 1, [instr, ..acc])
      }
    _ -> decode_expr(rest, depth, [instr, ..acc])
  }
}

/// Decode exactly one instruction (opcode byte plus its immediates). Unknown
/// opcodes are `Error(ast.UnknownOpcode(byte))`; a `0xFC` sub-opcode outside
/// `0..7` is `Error(ast.UnknownSatOpcode(sub))`. `0xFC` is a PREFIX FAMILY: it
/// reads a `u32` sub-opcode after the prefix (never treated as a leaf).
fn decode_instr(
  bytes: BitArray,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  case bytes {
    <<op:8, rest:bytes>> ->
      case op {
        // control
        0x00 -> Ok(#(ast.Unreachable, rest))
        0x01 -> Ok(#(ast.Nop, rest))
        0x02 -> {
          use #(bt, r) <- result.try(decode_blocktype(rest))
          Ok(#(ast.Block(bt), r))
        }
        0x03 -> {
          use #(bt, r) <- result.try(decode_blocktype(rest))
          Ok(#(ast.Loop(bt), r))
        }
        0x04 -> {
          use #(bt, r) <- result.try(decode_blocktype(rest))
          Ok(#(ast.If(bt), r))
        }
        0x05 -> Ok(#(ast.Else, rest))
        0x0B -> Ok(#(ast.End, rest))
        0x0C -> {
          use #(l, r) <- result.try(decode_u_n(rest, 32))
          Ok(#(ast.Br(l), r))
        }
        0x0D -> {
          use #(l, r) <- result.try(decode_u_n(rest, 32))
          Ok(#(ast.BrIf(l), r))
        }
        0x0E -> {
          use #(targets, r1) <- result.try(
            decode_vec(rest, fn(b) { decode_u_n(b, 32) }),
          )
          use #(default, r2) <- result.try(decode_u_n(r1, 32))
          Ok(#(ast.BrTable(targets: targets, default: default), r2))
        }
        0x0F -> Ok(#(ast.Return, rest))
        0x10 -> {
          use #(f, r) <- result.try(decode_u_n(rest, 32))
          Ok(#(ast.Call(f), r))
        }
        0x11 -> {
          use #(ty, r1) <- result.try(decode_u_n(rest, 32))
          use #(table, r2) <- result.try(decode_u_n(r1, 32))
          Ok(#(ast.CallIndirect(type_idx: ty, table: table), r2))
        }
        // tail-call proposal (Q13): the two tail-call opcodes read immediates
        // BYTE-IDENTICAL to their non-tail siblings `0x10`/`0x11` (Q2). `0x12`
        // takes one `u32` funcidx (same as `Call`); `0x13` takes a `u32` typeidx
        // THEN a `u32` tableidx (same as `CallIndirect`).
        0x12 -> idx_instr(rest, ast.ReturnCall)
        // The two reads are kept OPEN (not collapsed into a shared helper) so the
        // typeidx-before-tableidx order mirrors `0x11` exactly — the labelled
        // `type_idx:`/`table:` lock the anti-swap field order.
        0x13 -> {
          use #(ty, r1) <- result.try(decode_u_n(rest, 32))
          use #(table, r2) <- result.try(decode_u_n(r1, 32))
          Ok(#(ast.ReturnCallIndirect(type_idx: ty, table: table), r2))
        }
        // exception handling — legacy (Porffor's headline path, §F): try 0x06 /
        // catch 0x07 / rethrow 0x09 / delegate 0x18 / catch_all 0x19.
        0x06 -> {
          use #(bt, r) <- result.try(decode_blocktype(rest))
          Ok(#(ast.TryLegacy(bt), r))
        }
        0x07 -> {
          use #(tag, r) <- result.try(decode_u_n(rest, 32))
          Ok(#(ast.LegacyCatch(tag), r))
        }
        0x09 -> {
          use #(label, r) <- result.try(decode_u_n(rest, 32))
          Ok(#(ast.Rethrow(label), r))
        }
        0x18 -> {
          use #(label, r) <- result.try(decode_u_n(rest, 32))
          Ok(#(ast.LegacyDelegate(label), r))
        }
        0x19 -> Ok(#(ast.LegacyCatchAll, rest))
        // exception handling — modern (spec-stable target, §E): throw 0x08 (shared
        // with legacy) / throw_ref 0x0A / try_table 0x1F (blocktype + vec(catch)).
        0x08 -> {
          use #(tag, r) <- result.try(decode_u_n(rest, 32))
          Ok(#(ast.Throw(tag), r))
        }
        0x0A -> Ok(#(ast.ThrowRef, rest))
        0x1F -> {
          use #(bt, r1) <- result.try(decode_blocktype(rest))
          use #(catches, r2) <- result.try(decode_vec(r1, decode_catch))
          Ok(#(ast.TryTable(bt, catches), r2))
        }
        // parametric
        0x1A -> Ok(#(ast.Drop, rest))
        0x1B -> Ok(#(ast.Select, rest))
        // typed `select t*` (0x1C): a `vec(valtype)` (reftypes allowed). The
        // length-must-be-1 restriction is validate's, not decode's.
        0x1C -> {
          use #(types, r) <- result.try(decode_vec(rest, decode_valtype))
          Ok(#(ast.SelectT(types), r))
        }
        // reference table access (0x25/0x26): one `u32` tableidx each.
        0x25 -> idx_instr(rest, ast.TableGet)
        0x26 -> idx_instr(rest, ast.TableSet)
        // variable access
        0x20 -> idx_instr(rest, ast.LocalGet)
        0x21 -> idx_instr(rest, ast.LocalSet)
        0x22 -> idx_instr(rest, ast.LocalTee)
        0x23 -> idx_instr(rest, ast.GlobalGet)
        0x24 -> idx_instr(rest, ast.GlobalSet)
        // memory load/store (0x28..0x3E): each followed by a `memarg`.
        0x28 -> memarg_instr(rest, ast.I32Load)
        0x29 -> memarg_instr(rest, ast.I64Load)
        0x2A -> memarg_instr(rest, ast.F32Load)
        0x2B -> memarg_instr(rest, ast.F64Load)
        0x2C -> memarg_instr(rest, ast.I32Load8S)
        0x2D -> memarg_instr(rest, ast.I32Load8U)
        0x2E -> memarg_instr(rest, ast.I32Load16S)
        0x2F -> memarg_instr(rest, ast.I32Load16U)
        0x30 -> memarg_instr(rest, ast.I64Load8S)
        0x31 -> memarg_instr(rest, ast.I64Load8U)
        0x32 -> memarg_instr(rest, ast.I64Load16S)
        0x33 -> memarg_instr(rest, ast.I64Load16U)
        0x34 -> memarg_instr(rest, ast.I64Load32S)
        0x35 -> memarg_instr(rest, ast.I64Load32U)
        0x36 -> memarg_instr(rest, ast.I32Store)
        0x37 -> memarg_instr(rest, ast.I64Store)
        0x38 -> memarg_instr(rest, ast.F32Store)
        0x39 -> memarg_instr(rest, ast.F64Store)
        0x3A -> memarg_instr(rest, ast.I32Store8)
        0x3B -> memarg_instr(rest, ast.I32Store16)
        0x3C -> memarg_instr(rest, ast.I64Store8)
        0x3D -> memarg_instr(rest, ast.I64Store16)
        0x3E -> memarg_instr(rest, ast.I64Store32)
        // memory.size/grow (0x3F/0x40): a `u32` memidx (a reserved `0x00` in the
        // MVP → `mem == 0`, byte-identical; a genuine index under multi-memory).
        0x3F -> idx_instr(rest, ast.MemorySize)
        0x40 -> idx_instr(rest, ast.MemoryGrow)
        // reference instructions (0xD0..0xD2).
        0xD0 -> {
          use #(ref_ty, r) <- result.try(decode_reftype(rest))
          Ok(#(ast.RefNull(ref_ty), r))
        }
        0xD1 -> Ok(#(ast.RefIsNull, rest))
        0xD2 -> idx_instr(rest, ast.RefFunc)
        // constants
        0x41 -> {
          use #(v, r) <- result.try(decode_s_n(rest, 32))
          Ok(#(ast.I32Const(v), r))
        }
        0x42 -> {
          use #(v, r) <- result.try(decode_s_n(rest, 64))
          Ok(#(ast.I64Const(v), r))
        }
        // Float consts are kept as RAW LE bit patterns (overview D5) — extracted
        // as unsigned ints so NaN/Infinity payloads survive (never `:float`).
        0x43 ->
          case rest {
            <<bits:32-unsigned-little, r:bytes>> -> Ok(#(ast.F32Const(bits), r))
            _ -> Error(ast.Truncated)
          }
        0x44 ->
          case rest {
            <<bits:64-unsigned-little, r:bytes>> -> Ok(#(ast.F64Const(bits), r))
            _ -> Error(ast.Truncated)
          }
        // leaf numeric / comparison / sign-extension opcodes (no immediates)
        _ ->
          case leaf_instr(op) {
            Ok(instr) -> Ok(#(instr, rest))
            Error(Nil) ->
              case op {
                // 0xFC prefix family: read a u32 sub-opcode and dispatch. Sub 0..7
                // are the saturating truncations; 8..17 the bulk memory/table ops.
                0xFC -> {
                  use #(sub, r) <- result.try(decode_u_n(rest, 32))
                  case sat_instr(sub) {
                    Ok(instr) -> Ok(#(instr, r))
                    Error(Nil) -> decode_bulk(sub, r)
                  }
                }
                // 0xFD prefix family (SIMD): read a u32 sub-opcode and dispatch to
                // `decode_simd` (all 236 fixed-width sub-opcodes + their immediates).
                0xFD -> {
                  use #(sub, r) <- result.try(decode_u_n(rest, 32))
                  decode_simd(sub, r)
                }
                _ -> Error(ast.UnknownOpcode(op))
              }
          }
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode one `try_table` catch clause (Phase 7; spec: the EH proposal's catch vector).
/// The leading KIND byte selects the form; `catch`/`catch_ref` (`0x00`/`0x01`) then read
/// a `tagidx` THEN a `labelidx`; `catch_all`/`catch_all_ref` (`0x02`/`0x03`) read a
/// `labelidx` only. A kind byte outside `0x00..0x03` is `Error(ast.BadCatchKind)`; EOF is
/// `Error(ast.Truncated)`. Both indices are raw `u32`s (validate resolves them). Order is
/// load-bearing: the tag is read BEFORE the label (swapping mis-decodes both).
fn decode_catch(
  bytes: BitArray,
) -> Result(#(Catch, BitArray), ast.DecodeError) {
  case bytes {
    <<0x00, r0:bytes>> -> {
      use #(tag, r1) <- result.try(decode_u_n(r0, 32))
      use #(label, r2) <- result.try(decode_u_n(r1, 32))
      Ok(#(ast.Catch(tag, label), r2))
    }
    <<0x01, r0:bytes>> -> {
      use #(tag, r1) <- result.try(decode_u_n(r0, 32))
      use #(label, r2) <- result.try(decode_u_n(r1, 32))
      Ok(#(ast.CatchRef(tag, label), r2))
    }
    <<0x02, r0:bytes>> -> {
      use #(label, r1) <- result.try(decode_u_n(r0, 32))
      Ok(#(ast.CatchAll(label), r1))
    }
    <<0x03, r0:bytes>> -> {
      use #(label, r1) <- result.try(decode_u_n(r0, 32))
      Ok(#(ast.CatchAllRef(label), r1))
    }
    <<_:8, _:bytes>> -> Error(ast.BadCatchKind)
    _ -> Error(ast.Truncated)
  }
}

/// Decode a `u32` index immediate and wrap it with `make` (the variable-access
/// instructions `0x20`..`0x24`).
fn idx_instr(
  bytes: BitArray,
  make: fn(Int) -> Instr,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  use #(i, r) <- result.try(decode_u_n(bytes, 32))
  Ok(#(make(i), r))
}

/// Decode a `memarg` and wrap it with `make` (every load/store opcode
/// `0x28`..`0x3E`), extended for multi-memory + memory64 (spec + the multi-memory
/// proposal):
///
/// ```text
/// memarg ::= n:u32 o:u64            (bit 6 of n clear) ⇒ {align n,      offset o, mem 0}
///          | n:u32 x:memidx o:u64   (bit 6 of n set)   ⇒ {align n−0x40, offset o, mem x}
/// ```
///
/// The alignment flags are a `u32` whose bit 6 (`0x40`) signals an explicit memidx;
/// the real alignment exponent is that value with bit 6 cleared. The offset is a
/// `u64` (the memory64 width; validate enforces `< 2^32` for an i32 memory). Values
/// that fit `u32` decode identically to Phase 4 (conformance-neutral). LEB errors /
/// `Error(ast.Truncated)` if any number is malformed.
fn memarg_instr(
  bytes: BitArray,
  make: fn(MemArg) -> Instr,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  use #(memarg, r) <- result.try(decode_memarg(bytes))
  Ok(#(make(memarg), r))
}

/// Decode a `memarg` (see `memarg_instr` for the grammar). Bit 6 (`0x40`) of the
/// alignment flags, if set, introduces an explicit `u32` memidx before the `u64`
/// offset; otherwise the memidx defaults to `0`. The alignment value is kept RAW
/// with bit 6 stripped (non-semantic; validate checks `2^align <= N`).
fn decode_memarg(
  bytes: BitArray,
) -> Result(#(MemArg, BitArray), ast.DecodeError) {
  use #(flags, r1) <- result.try(decode_u_n(bytes, 32))
  case int.bitwise_and(flags, 0x40) != 0 {
    True -> {
      use #(mem, r2) <- result.try(decode_u_n(r1, 32))
      use #(offset, r3) <- result.try(decode_u_n(r2, 64))
      let align = int.bitwise_exclusive_or(flags, 0x40)
      Ok(#(ast.MemArg(align: align, offset: offset, mem: mem), r3))
    }
    False -> {
      use #(offset, r2) <- result.try(decode_u_n(r1, 64))
      Ok(#(ast.MemArg(align: flags, offset: offset, mem: 0), r2))
    }
  }
}

/// Decode a `0xFC`-prefixed BULK memory/table op given its `sub`-opcode (8..17) and
/// the bytes after it (spec binary/instructions §bulk). Immediate order is WIRE
/// order and security-relevant (R3) — `table.init` reads elemidx THEN tableidx,
/// `memory.init` reads dataidx THEN memidx, and `memory.copy`/`table.copy` read the
/// DESTINATION index THEN the source. A `sub` outside 8..17 is
/// `Error(ast.UnknownSatOpcode(sub))`. The trailing memidxs (once a reserved `0x00`
/// in the MVP) are genuine `u32`s and are NOT required to be `0` (multi-memory).
fn decode_bulk(
  sub: Int,
  bytes: BitArray,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  case sub {
    8 -> {
      // memory.init: dataidx THEN memidx.
      use #(data, r1) <- result.try(decode_u_n(bytes, 32))
      use #(mem, r2) <- result.try(decode_u_n(r1, 32))
      Ok(#(ast.MemoryInit(data: data, mem: mem), r2))
    }
    9 -> {
      use #(data, r) <- result.try(decode_u_n(bytes, 32))
      Ok(#(ast.DataDrop(data), r))
    }
    10 -> {
      // memory.copy: dst memidx THEN src memidx.
      use #(dst, r1) <- result.try(decode_u_n(bytes, 32))
      use #(src, r2) <- result.try(decode_u_n(r1, 32))
      Ok(#(ast.MemoryCopy(dst_mem: dst, src_mem: src), r2))
    }
    11 -> idx_instr(bytes, ast.MemoryFill)
    12 -> {
      // table.init: elemidx THEN tableidx.
      use #(elem, r1) <- result.try(decode_u_n(bytes, 32))
      use #(table, r2) <- result.try(decode_u_n(r1, 32))
      Ok(#(ast.TableInit(elem: elem, table: table), r2))
    }
    13 -> idx_instr(bytes, ast.ElemDrop)
    14 -> {
      // table.copy: dst tableidx THEN src tableidx.
      use #(dst, r1) <- result.try(decode_u_n(bytes, 32))
      use #(src, r2) <- result.try(decode_u_n(r1, 32))
      Ok(#(ast.TableCopy(dst_table: dst, src_table: src), r2))
    }
    15 -> idx_instr(bytes, ast.TableGrow)
    16 -> idx_instr(bytes, ast.TableSize)
    17 -> idx_instr(bytes, ast.TableFill)
    _ -> Error(ast.UnknownSatOpcode(sub))
  }
}

/// Map a leaf opcode byte (comparison / numeric / sign-extension, all with NO
/// immediates) to its `Instr`. `Error(Nil)` for any byte not in those ranges —
/// the caller then tries the `0xFC` prefix or reports `UnknownOpcode`.
fn leaf_instr(op: Int) -> Result(Instr, Nil) {
  case op {
    // i32 comparisons 0x45..0x4F
    0x45 -> Ok(ast.I32Eqz)
    0x46 -> Ok(ast.I32Eq)
    0x47 -> Ok(ast.I32Ne)
    0x48 -> Ok(ast.I32LtS)
    0x49 -> Ok(ast.I32LtU)
    0x4A -> Ok(ast.I32GtS)
    0x4B -> Ok(ast.I32GtU)
    0x4C -> Ok(ast.I32LeS)
    0x4D -> Ok(ast.I32LeU)
    0x4E -> Ok(ast.I32GeS)
    0x4F -> Ok(ast.I32GeU)
    // i64 comparisons 0x50..0x5A
    0x50 -> Ok(ast.I64Eqz)
    0x51 -> Ok(ast.I64Eq)
    0x52 -> Ok(ast.I64Ne)
    0x53 -> Ok(ast.I64LtS)
    0x54 -> Ok(ast.I64LtU)
    0x55 -> Ok(ast.I64GtS)
    0x56 -> Ok(ast.I64GtU)
    0x57 -> Ok(ast.I64LeS)
    0x58 -> Ok(ast.I64LeU)
    0x59 -> Ok(ast.I64GeS)
    0x5A -> Ok(ast.I64GeU)
    // i32 numeric 0x67..0x78
    0x67 -> Ok(ast.I32Clz)
    0x68 -> Ok(ast.I32Ctz)
    0x69 -> Ok(ast.I32Popcnt)
    0x6A -> Ok(ast.I32Add)
    0x6B -> Ok(ast.I32Sub)
    0x6C -> Ok(ast.I32Mul)
    0x6D -> Ok(ast.I32DivS)
    0x6E -> Ok(ast.I32DivU)
    0x6F -> Ok(ast.I32RemS)
    0x70 -> Ok(ast.I32RemU)
    0x71 -> Ok(ast.I32And)
    0x72 -> Ok(ast.I32Or)
    0x73 -> Ok(ast.I32Xor)
    0x74 -> Ok(ast.I32Shl)
    0x75 -> Ok(ast.I32ShrS)
    0x76 -> Ok(ast.I32ShrU)
    0x77 -> Ok(ast.I32Rotl)
    0x78 -> Ok(ast.I32Rotr)
    // i64 numeric 0x79..0x8A
    0x79 -> Ok(ast.I64Clz)
    0x7A -> Ok(ast.I64Ctz)
    0x7B -> Ok(ast.I64Popcnt)
    0x7C -> Ok(ast.I64Add)
    0x7D -> Ok(ast.I64Sub)
    0x7E -> Ok(ast.I64Mul)
    0x7F -> Ok(ast.I64DivS)
    0x80 -> Ok(ast.I64DivU)
    0x81 -> Ok(ast.I64RemS)
    0x82 -> Ok(ast.I64RemU)
    0x83 -> Ok(ast.I64And)
    0x84 -> Ok(ast.I64Or)
    0x85 -> Ok(ast.I64Xor)
    0x86 -> Ok(ast.I64Shl)
    0x87 -> Ok(ast.I64ShrS)
    0x88 -> Ok(ast.I64ShrU)
    0x89 -> Ok(ast.I64Rotl)
    0x8A -> Ok(ast.I64Rotr)
    // float comparisons 0x5B..0x66 (yield i32)
    0x5B -> Ok(ast.F32Eq)
    0x5C -> Ok(ast.F32Ne)
    0x5D -> Ok(ast.F32Lt)
    0x5E -> Ok(ast.F32Gt)
    0x5F -> Ok(ast.F32Le)
    0x60 -> Ok(ast.F32Ge)
    0x61 -> Ok(ast.F64Eq)
    0x62 -> Ok(ast.F64Ne)
    0x63 -> Ok(ast.F64Lt)
    0x64 -> Ok(ast.F64Gt)
    0x65 -> Ok(ast.F64Le)
    0x66 -> Ok(ast.F64Ge)
    // f32 numeric 0x8B..0x98
    0x8B -> Ok(ast.F32Abs)
    0x8C -> Ok(ast.F32Neg)
    0x8D -> Ok(ast.F32Ceil)
    0x8E -> Ok(ast.F32Floor)
    0x8F -> Ok(ast.F32Trunc)
    0x90 -> Ok(ast.F32Nearest)
    0x91 -> Ok(ast.F32Sqrt)
    0x92 -> Ok(ast.F32Add)
    0x93 -> Ok(ast.F32Sub)
    0x94 -> Ok(ast.F32Mul)
    0x95 -> Ok(ast.F32Div)
    0x96 -> Ok(ast.F32Min)
    0x97 -> Ok(ast.F32Max)
    0x98 -> Ok(ast.F32Copysign)
    // f64 numeric 0x99..0xA6
    0x99 -> Ok(ast.F64Abs)
    0x9A -> Ok(ast.F64Neg)
    0x9B -> Ok(ast.F64Ceil)
    0x9C -> Ok(ast.F64Floor)
    0x9D -> Ok(ast.F64Trunc)
    0x9E -> Ok(ast.F64Nearest)
    0x9F -> Ok(ast.F64Sqrt)
    0xA0 -> Ok(ast.F64Add)
    0xA1 -> Ok(ast.F64Sub)
    0xA2 -> Ok(ast.F64Mul)
    0xA3 -> Ok(ast.F64Div)
    0xA4 -> Ok(ast.F64Min)
    0xA5 -> Ok(ast.F64Max)
    0xA6 -> Ok(ast.F64Copysign)
    // conversion block 0xA7..0xBF (int + float interleaved)
    0xA7 -> Ok(ast.I32WrapI64)
    0xA8 -> Ok(ast.I32TruncF32S)
    0xA9 -> Ok(ast.I32TruncF32U)
    0xAA -> Ok(ast.I32TruncF64S)
    0xAB -> Ok(ast.I32TruncF64U)
    0xAC -> Ok(ast.I64ExtendI32S)
    0xAD -> Ok(ast.I64ExtendI32U)
    0xAE -> Ok(ast.I64TruncF32S)
    0xAF -> Ok(ast.I64TruncF32U)
    0xB0 -> Ok(ast.I64TruncF64S)
    0xB1 -> Ok(ast.I64TruncF64U)
    0xB2 -> Ok(ast.F32ConvertI32S)
    0xB3 -> Ok(ast.F32ConvertI32U)
    0xB4 -> Ok(ast.F32ConvertI64S)
    0xB5 -> Ok(ast.F32ConvertI64U)
    0xB6 -> Ok(ast.F32DemoteF64)
    0xB7 -> Ok(ast.F64ConvertI32S)
    0xB8 -> Ok(ast.F64ConvertI32U)
    0xB9 -> Ok(ast.F64ConvertI64S)
    0xBA -> Ok(ast.F64ConvertI64U)
    0xBB -> Ok(ast.F64PromoteF32)
    0xBC -> Ok(ast.I32ReinterpretF32)
    0xBD -> Ok(ast.I64ReinterpretF64)
    0xBE -> Ok(ast.F32ReinterpretI32)
    0xBF -> Ok(ast.F64ReinterpretI64)
    // sign extension 0xC0..0xC4
    0xC0 -> Ok(ast.I32Extend8S)
    0xC1 -> Ok(ast.I32Extend16S)
    0xC2 -> Ok(ast.I64Extend8S)
    0xC3 -> Ok(ast.I64Extend16S)
    0xC4 -> Ok(ast.I64Extend32S)
    _ -> Error(Nil)
  }
}

/// Map a `0xFC` sub-opcode `0..7` to its saturating-truncation `Instr`.
/// `Error(Nil)` for any other sub-opcode (caller reports `UnknownSatOpcode`).
fn sat_instr(sub: Int) -> Result(Instr, Nil) {
  case sub {
    0 -> Ok(ast.I32TruncSatF32S)
    1 -> Ok(ast.I32TruncSatF32U)
    2 -> Ok(ast.I32TruncSatF64S)
    3 -> Ok(ast.I32TruncSatF64U)
    4 -> Ok(ast.I64TruncSatF32S)
    5 -> Ok(ast.I64TruncSatF32U)
    6 -> Ok(ast.I64TruncSatF64S)
    7 -> Ok(ast.I64TruncSatF64U)
    _ -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// SIMD: the 0xFD prefix family («WASM-AST4») — all 236 fixed-width sub-opcodes
// ---------------------------------------------------------------------------

/// Decode a `0xFD`-prefixed SIMD instruction given its `sub`-opcode (a `u32` already
/// read after the prefix) and the bytes after it (spec binary/instructions
/// §vector-instructions; the appendix instruction index is authoritative for the exact
/// opcodes). The six immediate-bearing ranges (memory loads/store, `v128.const`,
/// `i8x16.shuffle`, extract/replace lane, load/store-lane) are handled explicitly; every
/// other sub-opcode is a pure lane op looked up by `simd_pure_op`. A sub-opcode with no
/// standardized fixed-width instruction — one of the 20 reserved gaps in `0..255`, or a
/// relaxed-SIMD sub-opcode (`>= 256`, deferred) — is `Error(ast.UnknownSimdOpcode(sub))`.
/// Immediate order is WIRE order throughout (§E), and every read is fail-closed
/// (`Truncated` on any shortfall — never an over-read).
fn decode_simd(
  sub: Int,
  bytes: BitArray,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  case sub {
    // v128 memory loads / store — each takes a `memarg` (widths in BITS, S2)
    0 -> simd_load(ast.LoadV128, bytes)
    1 -> simd_load(ast.LoadExtend(8, True), bytes)
    2 -> simd_load(ast.LoadExtend(8, False), bytes)
    3 -> simd_load(ast.LoadExtend(16, True), bytes)
    4 -> simd_load(ast.LoadExtend(16, False), bytes)
    5 -> simd_load(ast.LoadExtend(32, True), bytes)
    6 -> simd_load(ast.LoadExtend(32, False), bytes)
    7 -> simd_load(ast.LoadSplat(8), bytes)
    8 -> simd_load(ast.LoadSplat(16), bytes)
    9 -> simd_load(ast.LoadSplat(32), bytes)
    10 -> simd_load(ast.LoadSplat(64), bytes)
    11 -> {
      use #(a, r) <- result.try(decode_memarg(bytes))
      Ok(#(ast.SimdStore(a), r))
    }
    92 -> simd_load(ast.LoadZero(32), bytes)
    93 -> simd_load(ast.LoadZero(64), bytes)
    // v128.const (16 raw bytes) / i8x16.shuffle (16 lane bytes)
    12 -> decode_v128_const(bytes)
    13 -> decode_shuffle(bytes)
    // extract / replace lane — one trailing lane byte, folded into the `SimdOp`
    21 -> lane_op(bytes, ast.SExtractLaneS(ast.I8x16, _))
    22 -> lane_op(bytes, ast.SExtractLaneU(ast.I8x16, _))
    23 -> lane_op(bytes, ast.SReplaceLane(ast.I8x16, _))
    24 -> lane_op(bytes, ast.SExtractLaneS(ast.I16x8, _))
    25 -> lane_op(bytes, ast.SExtractLaneU(ast.I16x8, _))
    26 -> lane_op(bytes, ast.SReplaceLane(ast.I16x8, _))
    27 -> lane_op(bytes, ast.SExtractLane(ast.I32x4, _))
    28 -> lane_op(bytes, ast.SReplaceLane(ast.I32x4, _))
    29 -> lane_op(bytes, ast.SExtractLane(ast.I64x2, _))
    30 -> lane_op(bytes, ast.SReplaceLane(ast.I64x2, _))
    31 -> lane_op(bytes, ast.SExtractLane(ast.F32x4, _))
    32 -> lane_op(bytes, ast.SReplaceLane(ast.F32x4, _))
    33 -> lane_op(bytes, ast.SExtractLane(ast.F64x2, _))
    34 -> lane_op(bytes, ast.SReplaceLane(ast.F64x2, _))
    // load / store lane — a `memarg` THEN a single lane byte (§E.4)
    84 -> simd_load_lane(8, bytes)
    85 -> simd_load_lane(16, bytes)
    86 -> simd_load_lane(32, bytes)
    87 -> simd_load_lane(64, bytes)
    88 -> simd_store_lane(8, bytes)
    89 -> simd_store_lane(16, bytes)
    90 -> simd_store_lane(32, bytes)
    91 -> simd_store_lane(64, bytes)
    // everything else: a pure lane op (no immediate) or a reserved/out-of-range gap
    _ ->
      case simd_pure_op(sub) {
        Ok(op) -> Ok(#(ast.Simd(op), bytes))
        Error(Nil) -> Error(ast.UnknownSimdOpcode(sub))
      }
  }
}

/// Decode a v128 memory-load op's `memarg` and wrap it as `SimdLoad(kind, arg)`. The
/// `memarg` is the same one scalar loads use (`decode_memarg`: multi-memory bit-6 memidx
/// + `u64` offset). LEB/`Truncated` errors propagate.
fn simd_load(
  kind: ast.SimdLoadKind,
  bytes: BitArray,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  use #(arg, r) <- result.try(decode_memarg(bytes))
  Ok(#(ast.SimdLoad(kind, arg), r))
}

/// Decode `v128.loadN_lane`: a `memarg` THEN one lane byte (`width` in BITS, S2). Order is
/// load-bearing — NOT lane-then-memarg (swapping them would read the lane byte as the
/// align flags and mis-decode the whole instruction). A missing lane byte is `Truncated`.
fn simd_load_lane(
  width: Int,
  bytes: BitArray,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  use #(arg, r1) <- result.try(decode_memarg(bytes))
  case r1 {
    <<l:8, r2:bytes>> -> Ok(#(ast.SimdLoadLane(width, arg, l), r2))
    _ -> Error(ast.Truncated)
  }
}

/// Decode `v128.storeN_lane`: a `memarg` THEN one lane byte (`width` in BITS, S2), exactly
/// like `simd_load_lane` but building `SimdStoreLane`. A missing lane byte is `Truncated`.
fn simd_store_lane(
  width: Int,
  bytes: BitArray,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  use #(arg, r1) <- result.try(decode_memarg(bytes))
  case r1 {
    <<l:8, r2:bytes>> -> Ok(#(ast.SimdStoreLane(width, arg, l), r2))
    _ -> Error(ast.Truncated)
  }
}

/// Decode `v128.const`'s 16-byte immediate (spec: an `i128` literal, little-endian).
/// Stored RAW (D5) as a 16-byte `BitArray` — never a decoded lane structure, so NaN
/// payloads / `-0.0` / exact lane bits survive. The shape annotation in WAT text
/// (`v128.const i32x4 …` vs `i8x16 …`) is a text nicety with no wire presence: on the wire
/// both are just these 16 bytes, taken verbatim. Fewer than 16 bytes ⇒ `Truncated`.
fn decode_v128_const(
  bytes: BitArray,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  case bytes {
    <<imm:size(16)-bytes, r:bytes>> -> Ok(#(ast.V128Const(imm), r))
    _ -> Error(ast.Truncated)
  }
}

/// Decode `i8x16.shuffle`'s 16 lane-index bytes. Each is a RAW byte 0..255 (a `laneidx`
/// is a single byte, NOT LEB128; validate requires 0..31). `lanes[i]` selects the byte for
/// RESULT lane `i`, from the concatenation `a ++ b` of the two v128 operands (0..15 → `a`,
/// 16..31 → `b`). Order is load-bearing: `lanes[0]` is result lane 0. Fewer than 16 bytes
/// ⇒ `Truncated`.
fn decode_shuffle(
  bytes: BitArray,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  case bytes {
    <<
      l0:8,
      l1:8,
      l2:8,
      l3:8,
      l4:8,
      l5:8,
      l6:8,
      l7:8,
      l8:8,
      l9:8,
      l10:8,
      l11:8,
      l12:8,
      l13:8,
      l14:8,
      l15:8,
      r:bytes,
    >> ->
      Ok(#(
        ast.I8x16Shuffle([
          l0, l1, l2, l3, l4, l5, l6, l7, l8, l9, l10, l11, l12, l13, l14, l15,
        ]),
        r,
      ))
    _ -> Error(ast.Truncated)
  }
}

/// Read one lane-index byte and build a lane-carrying `Simd` instruction via `make`
/// (extract/replace lane, sub 21..34). The lane is stored RAW (0..255); validate checks
/// `lane < lane-count`. An absent lane byte is `Truncated`.
fn lane_op(
  bytes: BitArray,
  make: fn(Int) -> ast.SimdOp,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  case bytes {
    <<l:8, r:bytes>> -> Ok(#(ast.Simd(make(l)), r))
    _ -> Error(ast.Truncated)
  }
}

/// Map a pure (immediate-free) `0xFD` sub-opcode to its `SimdOp`. This is the SIMD
/// analogue of `leaf_instr`/`sat_instr`: a total `case` over the sub-opcode covering the
/// splat/swizzle (14..20), comparison (35..76), bitwise/`any_true` (77..83), and lane-wise
/// arithmetic/rounding/narrow/widen/extend/dot/extmul/extadd/convert (94..255) blocks.
/// `Error(Nil)` for any sub-opcode NOT in this table — a reserved gap (154; 162,165,166,
/// 175,176,178,179,180,187; 194,197,198,207,208,210,211,212; 226; 238) or an out-of-range
/// sub — and the caller reports `UnknownSimdOpcode`. The opcode numbers ARE the spec (the
/// appendix instruction index); every arm cites its instruction mnemonic.
fn simd_pure_op(sub: Int) -> Result(ast.SimdOp, Nil) {
  case sub {
    // splat / swizzle (14..20)
    14 -> Ok(ast.SSwizzle)
    15 -> Ok(ast.SSplat(ast.I8x16))
    16 -> Ok(ast.SSplat(ast.I16x8))
    17 -> Ok(ast.SSplat(ast.I32x4))
    18 -> Ok(ast.SSplat(ast.I64x2))
    19 -> Ok(ast.SSplat(ast.F32x4))
    20 -> Ok(ast.SSplat(ast.F64x2))
    // i8x16 comparisons (35..44): eq ne lt_s lt_u gt_s gt_u le_s le_u ge_s ge_u
    35 -> Ok(ast.SEq(ast.I8x16))
    36 -> Ok(ast.SNe(ast.I8x16))
    37 -> Ok(ast.SLtS(ast.I8x16))
    38 -> Ok(ast.SLtU(ast.I8x16))
    39 -> Ok(ast.SGtS(ast.I8x16))
    40 -> Ok(ast.SGtU(ast.I8x16))
    41 -> Ok(ast.SLeS(ast.I8x16))
    42 -> Ok(ast.SLeU(ast.I8x16))
    43 -> Ok(ast.SGeS(ast.I8x16))
    44 -> Ok(ast.SGeU(ast.I8x16))
    // i16x8 comparisons (45..54)
    45 -> Ok(ast.SEq(ast.I16x8))
    46 -> Ok(ast.SNe(ast.I16x8))
    47 -> Ok(ast.SLtS(ast.I16x8))
    48 -> Ok(ast.SLtU(ast.I16x8))
    49 -> Ok(ast.SGtS(ast.I16x8))
    50 -> Ok(ast.SGtU(ast.I16x8))
    51 -> Ok(ast.SLeS(ast.I16x8))
    52 -> Ok(ast.SLeU(ast.I16x8))
    53 -> Ok(ast.SGeS(ast.I16x8))
    54 -> Ok(ast.SGeU(ast.I16x8))
    // i32x4 comparisons (55..64)
    55 -> Ok(ast.SEq(ast.I32x4))
    56 -> Ok(ast.SNe(ast.I32x4))
    57 -> Ok(ast.SLtS(ast.I32x4))
    58 -> Ok(ast.SLtU(ast.I32x4))
    59 -> Ok(ast.SGtS(ast.I32x4))
    60 -> Ok(ast.SGtU(ast.I32x4))
    61 -> Ok(ast.SLeS(ast.I32x4))
    62 -> Ok(ast.SLeU(ast.I32x4))
    63 -> Ok(ast.SGeS(ast.I32x4))
    64 -> Ok(ast.SGeU(ast.I32x4))
    // f32x4 comparisons (65..70): eq ne lt gt le ge (note gt BEFORE le)
    65 -> Ok(ast.FEq(ast.F32x4))
    66 -> Ok(ast.FNe(ast.F32x4))
    67 -> Ok(ast.FLt(ast.F32x4))
    68 -> Ok(ast.FGt(ast.F32x4))
    69 -> Ok(ast.FLe(ast.F32x4))
    70 -> Ok(ast.FGe(ast.F32x4))
    // f64x2 comparisons (71..76)
    71 -> Ok(ast.FEq(ast.F64x2))
    72 -> Ok(ast.FNe(ast.F64x2))
    73 -> Ok(ast.FLt(ast.F64x2))
    74 -> Ok(ast.FGt(ast.F64x2))
    75 -> Ok(ast.FLe(ast.F64x2))
    76 -> Ok(ast.FGe(ast.F64x2))
    // v128 bitwise + any_true (77..83): not and andnot or xor bitselect any_true
    77 -> Ok(ast.VNot)
    78 -> Ok(ast.VAnd)
    79 -> Ok(ast.VAndNot)
    80 -> Ok(ast.VOr)
    81 -> Ok(ast.VXor)
    82 -> Ok(ast.VBitselect)
    83 -> Ok(ast.VAnyTrue)
    // demote / promote (94, 95)
    94 -> Ok(ast.SDemoteF64x2Zero)
    95 -> Ok(ast.SPromoteLowF32x4)
    // i8x16 block + interleaved f32x4/f64x2 rounding (96..127, no gaps)
    96 -> Ok(ast.SAbs(ast.I8x16))
    97 -> Ok(ast.SNeg(ast.I8x16))
    98 -> Ok(ast.SPopcnt(ast.I8x16))
    99 -> Ok(ast.SAllTrue(ast.I8x16))
    100 -> Ok(ast.SBitmask(ast.I8x16))
    101 -> Ok(ast.SNarrow(ast.I16x8, True))
    102 -> Ok(ast.SNarrow(ast.I16x8, False))
    103 -> Ok(ast.FCeil(ast.F32x4))
    104 -> Ok(ast.FFloor(ast.F32x4))
    105 -> Ok(ast.FTrunc(ast.F32x4))
    106 -> Ok(ast.FNearest(ast.F32x4))
    107 -> Ok(ast.SShl(ast.I8x16))
    108 -> Ok(ast.SShrS(ast.I8x16))
    109 -> Ok(ast.SShrU(ast.I8x16))
    110 -> Ok(ast.SAdd(ast.I8x16))
    111 -> Ok(ast.SAddSatS(ast.I8x16))
    112 -> Ok(ast.SAddSatU(ast.I8x16))
    113 -> Ok(ast.SSub(ast.I8x16))
    114 -> Ok(ast.SSubSatS(ast.I8x16))
    115 -> Ok(ast.SSubSatU(ast.I8x16))
    116 -> Ok(ast.FCeil(ast.F64x2))
    117 -> Ok(ast.FFloor(ast.F64x2))
    118 -> Ok(ast.SMinS(ast.I8x16))
    119 -> Ok(ast.SMinU(ast.I8x16))
    120 -> Ok(ast.SMaxS(ast.I8x16))
    121 -> Ok(ast.SMaxU(ast.I8x16))
    122 -> Ok(ast.FTrunc(ast.F64x2))
    123 -> Ok(ast.SAvgrU(ast.I8x16))
    124 -> Ok(ast.SExtAddPairwise(ast.I8x16, True))
    125 -> Ok(ast.SExtAddPairwise(ast.I8x16, False))
    126 -> Ok(ast.SExtAddPairwise(ast.I16x8, True))
    127 -> Ok(ast.SExtAddPairwise(ast.I16x8, False))
    // i16x8 block (+ f64x2.nearest at 148), gap at 154 (128..159)
    128 -> Ok(ast.SAbs(ast.I16x8))
    129 -> Ok(ast.SNeg(ast.I16x8))
    130 -> Ok(ast.SQ15MulrSatS)
    131 -> Ok(ast.SAllTrue(ast.I16x8))
    132 -> Ok(ast.SBitmask(ast.I16x8))
    133 -> Ok(ast.SNarrow(ast.I32x4, True))
    134 -> Ok(ast.SNarrow(ast.I32x4, False))
    135 -> Ok(ast.SExtend(ast.I8x16, ast.Low, True))
    136 -> Ok(ast.SExtend(ast.I8x16, ast.High, True))
    137 -> Ok(ast.SExtend(ast.I8x16, ast.Low, False))
    138 -> Ok(ast.SExtend(ast.I8x16, ast.High, False))
    139 -> Ok(ast.SShl(ast.I16x8))
    140 -> Ok(ast.SShrS(ast.I16x8))
    141 -> Ok(ast.SShrU(ast.I16x8))
    142 -> Ok(ast.SAdd(ast.I16x8))
    143 -> Ok(ast.SAddSatS(ast.I16x8))
    144 -> Ok(ast.SAddSatU(ast.I16x8))
    145 -> Ok(ast.SSub(ast.I16x8))
    146 -> Ok(ast.SSubSatS(ast.I16x8))
    147 -> Ok(ast.SSubSatU(ast.I16x8))
    148 -> Ok(ast.FNearest(ast.F64x2))
    149 -> Ok(ast.SMul(ast.I16x8))
    150 -> Ok(ast.SMinS(ast.I16x8))
    151 -> Ok(ast.SMinU(ast.I16x8))
    152 -> Ok(ast.SMaxS(ast.I16x8))
    153 -> Ok(ast.SMaxU(ast.I16x8))
    155 -> Ok(ast.SAvgrU(ast.I16x8))
    156 -> Ok(ast.SExtMul(ast.I8x16, ast.Low, True))
    157 -> Ok(ast.SExtMul(ast.I8x16, ast.High, True))
    158 -> Ok(ast.SExtMul(ast.I8x16, ast.Low, False))
    159 -> Ok(ast.SExtMul(ast.I8x16, ast.High, False))
    // i32x4 block, gaps at 162,165,166,175,176,178,179,180,187 (160..191)
    160 -> Ok(ast.SAbs(ast.I32x4))
    161 -> Ok(ast.SNeg(ast.I32x4))
    163 -> Ok(ast.SAllTrue(ast.I32x4))
    164 -> Ok(ast.SBitmask(ast.I32x4))
    167 -> Ok(ast.SExtend(ast.I16x8, ast.Low, True))
    168 -> Ok(ast.SExtend(ast.I16x8, ast.High, True))
    169 -> Ok(ast.SExtend(ast.I16x8, ast.Low, False))
    170 -> Ok(ast.SExtend(ast.I16x8, ast.High, False))
    171 -> Ok(ast.SShl(ast.I32x4))
    172 -> Ok(ast.SShrS(ast.I32x4))
    173 -> Ok(ast.SShrU(ast.I32x4))
    174 -> Ok(ast.SAdd(ast.I32x4))
    177 -> Ok(ast.SSub(ast.I32x4))
    181 -> Ok(ast.SMul(ast.I32x4))
    182 -> Ok(ast.SMinS(ast.I32x4))
    183 -> Ok(ast.SMinU(ast.I32x4))
    184 -> Ok(ast.SMaxS(ast.I32x4))
    185 -> Ok(ast.SMaxU(ast.I32x4))
    186 -> Ok(ast.SDotI16x8S)
    188 -> Ok(ast.SExtMul(ast.I16x8, ast.Low, True))
    189 -> Ok(ast.SExtMul(ast.I16x8, ast.High, True))
    190 -> Ok(ast.SExtMul(ast.I16x8, ast.Low, False))
    191 -> Ok(ast.SExtMul(ast.I16x8, ast.High, False))
    // i64x2 block (+ i64x2 signed comparisons 214..219),
    // gaps at 194,197,198,207,208,210,211,212 (192..223)
    192 -> Ok(ast.SAbs(ast.I64x2))
    193 -> Ok(ast.SNeg(ast.I64x2))
    195 -> Ok(ast.SAllTrue(ast.I64x2))
    196 -> Ok(ast.SBitmask(ast.I64x2))
    199 -> Ok(ast.SExtend(ast.I32x4, ast.Low, True))
    200 -> Ok(ast.SExtend(ast.I32x4, ast.High, True))
    201 -> Ok(ast.SExtend(ast.I32x4, ast.Low, False))
    202 -> Ok(ast.SExtend(ast.I32x4, ast.High, False))
    203 -> Ok(ast.SShl(ast.I64x2))
    204 -> Ok(ast.SShrS(ast.I64x2))
    205 -> Ok(ast.SShrU(ast.I64x2))
    206 -> Ok(ast.SAdd(ast.I64x2))
    209 -> Ok(ast.SSub(ast.I64x2))
    213 -> Ok(ast.SMul(ast.I64x2))
    214 -> Ok(ast.SEq(ast.I64x2))
    215 -> Ok(ast.SNe(ast.I64x2))
    216 -> Ok(ast.SLtS(ast.I64x2))
    217 -> Ok(ast.SGtS(ast.I64x2))
    218 -> Ok(ast.SLeS(ast.I64x2))
    219 -> Ok(ast.SGeS(ast.I64x2))
    220 -> Ok(ast.SExtMul(ast.I32x4, ast.Low, True))
    221 -> Ok(ast.SExtMul(ast.I32x4, ast.High, True))
    222 -> Ok(ast.SExtMul(ast.I32x4, ast.Low, False))
    223 -> Ok(ast.SExtMul(ast.I32x4, ast.High, False))
    // f32x4 block, gap at 226 (224..235)
    224 -> Ok(ast.FAbs(ast.F32x4))
    225 -> Ok(ast.FNeg(ast.F32x4))
    227 -> Ok(ast.FSqrt(ast.F32x4))
    228 -> Ok(ast.FAdd(ast.F32x4))
    229 -> Ok(ast.FSub(ast.F32x4))
    230 -> Ok(ast.FMul(ast.F32x4))
    231 -> Ok(ast.FDiv(ast.F32x4))
    232 -> Ok(ast.FMin(ast.F32x4))
    233 -> Ok(ast.FMax(ast.F32x4))
    234 -> Ok(ast.FPMin(ast.F32x4))
    235 -> Ok(ast.FPMax(ast.F32x4))
    // f64x2 block, gap at 238 (236..247)
    236 -> Ok(ast.FAbs(ast.F64x2))
    237 -> Ok(ast.FNeg(ast.F64x2))
    239 -> Ok(ast.FSqrt(ast.F64x2))
    240 -> Ok(ast.FAdd(ast.F64x2))
    241 -> Ok(ast.FSub(ast.F64x2))
    242 -> Ok(ast.FMul(ast.F64x2))
    243 -> Ok(ast.FDiv(ast.F64x2))
    244 -> Ok(ast.FMin(ast.F64x2))
    245 -> Ok(ast.FMax(ast.F64x2))
    246 -> Ok(ast.FPMin(ast.F64x2))
    247 -> Ok(ast.FPMax(ast.F64x2))
    // float ⇄ int conversions (248..255, no gaps)
    248 -> Ok(ast.STruncSatF32x4S)
    249 -> Ok(ast.STruncSatF32x4U)
    250 -> Ok(ast.SConvertF32x4I32x4S)
    251 -> Ok(ast.SConvertF32x4I32x4U)
    252 -> Ok(ast.STruncSatF64x2SZero)
    253 -> Ok(ast.STruncSatF64x2UZero)
    254 -> Ok(ast.SConvertF64x2LowI32x4S)
    255 -> Ok(ast.SConvertF64x2LowI32x4U)
    // reserved gaps in 0..255, and any sub not enumerated above → the caller reports
    // `UnknownSimdOpcode`. (sub >= 256 is relaxed-SIMD, deferred; also caught here.)
    _ -> Error(Nil)
  }
}
