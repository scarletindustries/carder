//// The conformance fixture model — wast2json JSON → typed `Command`/`Action`/`SpecValue`.
////
//// Tier-A insight (VERIFIED): the spec `.wast` files already carry the expected values,
//// so wast2json's JSON is self-contained — this module needs NO compiler and NO
//// reference engine. It is the parse half of the harness; the runner drives the
//// resulting `Command`s and the oracle compares the results.
////
//// wast2json shape facts honoured here (all VERIFIED against wabt 1.0.41 output):
////  - every command is an object with a `type`;
////  - a `module` command carries a `filename` (and optionally a `name`);
////  - ALL numeric `value`s are JSON STRINGS — the **decimal of the unsigned bit
////    pattern** (i64/float bits exceed JSON number precision). They are parsed as
////    integers, never as JSON floats: `f32 1.0` is the string `"1065353216"`
////    (= `0x3F800000`), NOT `"1.0"` (D5 — we store floats as raw bits).
////  - a NaN expectation is the literal string `"nan:canonical"` / `"nan:arithmetic"`,
////    carrying only a CLASS — never a concrete bit pattern (see `oracle`).
////  - `assert_invalid`/`assert_malformed` carry a `module_type` (`"binary"` references a
////    `.wasm` we can feed the decoder/validator; `"text"` references a `.wat` we cannot
////    — there is no Phase-1 WAT parser, so the runner skips text cases).

import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import twocore/conformance/ffi

// ─────────────────────────────── value model ───────────────────────────────

/// The NaN class a float expectation demands (the spec gives two; payloads vary, so
/// a NaN never compares by bit-equality — see `oracle.matches`).
///
/// - `Canonical`: payload is exactly the MSB (`0x40_0000` for f32); either sign.
/// - `Arithmetic`: payload MSB set, the remaining payload bits arbitrary; either sign.
pub type NanKind {
  Canonical
  Arithmetic
}

/// Which reference type a null / reference expectation is tagged with (the spec JSON
/// `type` field, R18). At the value layer a null's reftype is not observable (both reftypes
/// share the ONE null sentinel — `rt_ref.null_ref`), so the tag is carried for readable
/// diagnostics; the oracle matches a null of EITHER type (see `oracle.matches`).
pub type RefTypeTag {
  FuncRefTag
  ExternRefTag
}

/// Which lane shape a `v128` expectation is decoded at (the wast2json `lane_type` field, P6-10 /
/// S14). Determines the lane count and each lane's scalar type for the lane-wise oracle:
/// `i8`→16 lanes, `i16`→8, `i32`→4, `i64`→2, `f32`→4, `f64`→2. The 16 raw bytes are chunked
/// little-endian (lane 0 = the low-order bytes).
pub type V128Lane {
  LaneI8
  LaneI16
  LaneI32
  LaneI64
  LaneF32
  LaneF64
}

/// Which WebAssembly GC heap-type a reference expectation / classification is tagged with
/// (Phase-8 GC). These come from the wasm-tools `json-from-wast` `type` field for the GC
/// abstract-heap-type `assert_return` patterns (`structref`/`arrayref`/`i31ref`/`eqref`/`anyref`)
/// — TYPE-only assertions (no value): "the result is a non-null ref of this kind". The oracle
/// judges them against the WASM GC subtype lattice (`any ⊇ eq ⊇ {struct, array, i31}`).
///
/// - `StructRefK` / `ArrayRefK` / `I31RefK`: a concrete kind.
/// - `EqRefK`: any eq ref (i31/struct/array).
/// - `AnyRefK`: any (internal) ref.
/// - `GcHeapK`: the ACTUAL-side coarse kind for a returned `{gc, Id}` handle whose struct-vs-array
///   discriminator is not observable in the harness process (the arena is instance-process-local,
///   R-GC1) — matched leniently against `structref`/`arrayref` (documented, like the funcref
///   identity leniency in `oracle`), precisely against `eqref`/`anyref`. A future engine handle
///   retag (`{gc, struct|array, Id}`) refines `GcHeapK` into `StructRefK`/`ArrayRefK`.
pub type GcRefKind {
  StructRefK
  ArrayRefK
  I31RefK
  EqRefK
  AnyRefK
  GcHeapK
}

/// A single WebAssembly value as it appears in a fixture. Integers and concrete floats
/// hold the **raw UNSIGNED bit pattern** (the decimal-string in the JSON, parsed to an
/// `Int`). A NaN expectation carries only a `NanKind`, never concrete bits. Reference values
/// (P5-11 / R18) are BEAM terms, not integers — they marshal through the term invoke-ABI.
///
/// - `I32Val(bits)` / `I64Val(bits)`: `bits` in `[0, 2^32)` / `[0, 2^64)`.
/// - `F32Bits(bits)` / `F64Bits(bits)`: raw IEEE-754 binary32/binary64 bits.
/// - `F32Nan(kind)` / `F64Nan(kind)`: a NaN expectation of the given class.
/// - `NullRef(ty)`: a typed null reference (`ref.null func` | `ref.null extern`). Matches a
///   returned null of either reftype (the null sentinel is shared).
/// - `ExternRefVal(id)`: a non-null externref with a TESTABLE host identity `id` (the test's
///   `ref.extern N` — the engine must round-trip the SAME id).
/// - `FuncRefVal(index)`: a non-null funcref. Its identity is NOT compared (our funcref is an
///   opaque type-tagged table entry); `index` is diagnostic only. `None` = wast2json's
///   value-less funcref placeholder.
pub type SpecValue {
  I32Val(bits: Int)
  I64Val(bits: Int)
  F32Bits(bits: Int)
  F64Bits(bits: Int)
  F32Nan(kind: NanKind)
  F64Nan(kind: NanKind)
  NullRef(ty: RefTypeTag)
  ExternRefVal(id: Int)
  FuncRefVal(index: Option(Int))
  /// A `v128` value (P6-10 / S14). `lane` is the wast2json `lane_type` (how the 16 bytes are
  /// chunked); `lanes` is one scalar `SpecValue` per lane in **lane order 0..N-1** (== little-endian
  /// byte order, lane 0 = the low bytes). Integer lanes are `I32Val`/`I64Val`; float lanes are
  /// `F32Bits`/`F64Bits` (a concrete pattern) or `F32Nan`/`F64Nan` (a per-lane `nan:canonical` /
  /// `nan:arithmetic` token). The raw 16-byte binary is reconstructible via `v128_pack` +
  /// `v128_bytes_le`; a returned v128 is decoded back into this shape at the EXPECTED's lane type
  /// for lane-wise comparison (see `oracle.matches`).
  V128Val(lane: V128Lane, lanes: List(SpecValue))
  /// A NON-NULL WebAssembly GC reference of an abstract heap kind (Phase-8 GC). As an EXPECTED it
  /// is a TYPE-only assertion (`(ref.struct)`/`(ref.array)`/`(ref.i31)`/`(ref.eq)`/`(ref.any)` in
  /// the spec — no concrete value); as an ACTUAL it is the harness's classification of a returned
  /// GC term (`{i31, _}` → `I31RefK`, `{gc, Id}` → `GcHeapK`, refined to `StructRefK`/`ArrayRefK`
  /// if the handle self-describes). A GC null is `NullRef` (the shared sentinel), never this.
  GcRef(kind: GcRefKind)
}

/// Which on-disk form a rejected-module command references.
///
/// - `BinaryModule`: a `.wasm` — feed it to the decoder/validator (`check_frontend`).
/// - `TextModule`: a `.wat` — a text-syntax case with no binary; the Phase-1 harness
///   has no WAT parser, so the runner SKIPS it (honest coverage, D9).
pub type ModuleType {
  BinaryModule
  TextModule
}

/// A spec-suite action: either invoke an exported function or read an exported global.
///
/// - `Invoke(field, args, module)`: call export `field` with `args`. `module` names a
///   `register`-ed / named module, or `None` to target the current module.
/// - `Get(field, module)`: read exported global `field` (Phase-1 decodes no globals,
///   so the runner reports `Get` as unsupported — kept for completeness).
pub type Action {
  Invoke(field: String, args: List(SpecValue), module: Option(String))
  Get(field: String, module: Option(String))
}

/// One spec-suite command. Exactly the five Phase-1 command kinds plus the two
/// rejected-module kinds; any other command `type` is preserved as `Unhandled` so the
/// runner reports it as a skip rather than silently dropping it (no silent truncation).
///
/// - `ModuleCmd(line, name, filename)`: load `filename` as the new current module
///   (and, if `name` is `Some`, also bind it by that name).
/// - `Register(line, as_name, module)`: alias `module` (or the current module) under
///   `as_name` for later cross-module invokes.
/// - `AssertReturn(line, action, expected)`: `action` must return values matching
///   `expected` (compared by the oracle). Full pipeline.
/// - `AssertTrap(line, action, text)`: `action` must trap; `text` is the expected
///   trap-message SUBSTRING (e.g. `"integer divide by zero"`). Full pipeline.
/// - `AssertException(line, action, expected)`: `action` must raise an **uncaught WASM
///   exception** (the exception-handling proposal's `assert_exception`). Distinct from
///   `assert_trap` (T8/S8 — a WASM exception is control flow, not a trap): a `catch_all`
///   catches it but a trap propagates through. `expected` is the tag's operand-value
///   list where wast2json baked concrete values, else the operand TYPES (no value) — the
///   runner treats the presence of a well-formed WASM-exception outcome as the pass
///   condition (a normal return or a plain trap is a FAIL). Full pipeline.
/// - `AssertInvalid(line, filename, module_type, text)`: `filename` must FAIL
///   validation. Frontend only — never instantiated.
/// - `AssertMalformed(line, filename, module_type, text)`: `filename` must FAIL
///   decoding. Frontend only — never instantiated.
/// - `AssertUninstantiable(line, filename, text)`: `filename` decodes + validates,
///   but INSTANTIATING it must trap (an OOB active data/element segment, or a
///   trapping `start`) with a message containing `text` (E5). Full pipeline —
///   instantiated, and asserted to fail to instantiate.
/// - `AssertUnlinkable(line, filename, text)`: `filename` decodes + validates + compiles,
///   but LINKING it must fail (an unsatisfied / type-mismatched import) with a message
///   containing `text` (H6/D3a fail-closed proof). A successful link is a FAIL — a silently
///   linked unsatisfied import would be exactly the ambient authority D3a forbids.
/// - `Unhandled(line, kind)`: a command outside the modelled set (e.g.
///   `assert_exhaustion`) — reported as a skip.
pub type Command {
  ModuleCmd(line: Int, name: Option(String), filename: String)
  Register(line: Int, as_name: String, module: Option(String))
  AssertReturn(line: Int, action: Action, expected: List(SpecValue))
  AssertTrap(line: Int, action: Action, text: String)
  AssertException(line: Int, action: Action, expected: List(SpecValue))
  AssertInvalid(
    line: Int,
    filename: String,
    module_type: ModuleType,
    text: String,
  )
  AssertMalformed(
    line: Int,
    filename: String,
    module_type: ModuleType,
    text: String,
  )
  AssertUninstantiable(line: Int, filename: String, text: String)
  AssertUnlinkable(line: Int, filename: String, text: String)
  /// A bare `(invoke …)` / `(get …)` script action with NO assertion — run purely for
  /// its SIDE EFFECTS on the current module's mutable state (e.g. a `reset`/`init`/`run`
  /// that stores into memory before later asserts read it). Phase-1's pure modules made
  /// these no-ops, but with persistent per-instance memory they must EXECUTE, or later
  /// asserts read stale/zero state. Plumbing — never counted as pass/fail/skip.
  ActionCmd(line: Int, action: Action)
  Unhandled(line: Int, kind: String)
}

/// A parsed fixture: the originating `.wast` name plus its commands in file order.
pub type Fixture {
  Fixture(source_filename: String, commands: List(Command))
}

// ─────────────────────────────── parsing ───────────────────────────────

/// Parse a wast2json JSON byte string into a `Fixture`.
///
/// Returns `Ok(Fixture)` with every command decoded (unknown command kinds become
/// `Unhandled`, never an error), or `Error(reason)` if the bytes are not the expected
/// JSON shape. Total — never panics.
pub fn parse(json: BitArray) -> Result(Fixture, String) {
  case ffi.parse_json(json) {
    Error(e) -> Error("json: " <> e)
    Ok(dyn) ->
      case decode.run(dyn, fixture_decoder()) {
        Ok(f) -> Ok(f)
        Error(errs) -> Error("decode: " <> string.inspect(errs))
      }
  }
}

/// Read and parse a wast2json `.json` fixture from disk.
pub fn load(path: String) -> Result(Fixture, String) {
  case ffi.read_file(path) {
    Error(e) -> Error("read " <> path <> ": " <> e)
    Ok(bytes) -> parse(bytes)
  }
}

fn fixture_decoder() -> decode.Decoder(Fixture) {
  use source <- decode.optional_field("source_filename", "", decode.string)
  use commands <- decode.field("commands", decode.list(command_decoder()))
  decode.success(Fixture(source_filename: source, commands: commands))
}

fn command_decoder() -> decode.Decoder(Command) {
  use ty <- decode.field("type", decode.string)
  use line <- decode.optional_field("line", 0, decode.int)
  case ty {
    "module" -> {
      use name <- decode.optional_field("name", "", decode.string)
      use filename <- decode.field("filename", decode.string)
      decode.success(ModuleCmd(line, blank_to_none(name), filename))
    }
    "register" -> {
      use as_name <- decode.field("as", decode.string)
      use module <- decode.optional_field("name", "", decode.string)
      decode.success(Register(line, as_name, blank_to_none(module)))
    }
    "assert_return" -> {
      use action <- decode.field("action", action_decoder())
      use expected <- decode.field(
        "expected",
        decode.list(spec_value_decoder()),
      )
      decode.success(AssertReturn(line, action, expected))
    }
    "assert_trap" -> {
      use action <- decode.field("action", action_decoder())
      use text <- decode.optional_field("text", "", decode.string)
      decode.success(AssertTrap(line, action, text))
    }
    "assert_exception" -> {
      use action <- decode.field("action", action_decoder())
      // wast2json bakes the tag's operand list into `expected`; where an operand value is
      // known it carries a `value`, else just a `type` (value-less, decoded to a 0 sentinel
      // and never compared). The runner only asserts the outcome is a WASM exception.
      use expected <- decode.optional_field(
        "expected",
        [],
        decode.list(spec_value_decoder()),
      )
      decode.success(AssertException(line, action, expected))
    }
    "assert_invalid" -> {
      use filename <- decode.field("filename", decode.string)
      use mt <- decode.optional_field("module_type", "binary", decode.string)
      use text <- decode.optional_field("text", "", decode.string)
      decode.success(AssertInvalid(line, filename, module_type(mt), text))
    }
    "assert_malformed" -> {
      use filename <- decode.field("filename", decode.string)
      use mt <- decode.optional_field("module_type", "binary", decode.string)
      use text <- decode.optional_field("text", "", decode.string)
      decode.success(AssertMalformed(line, filename, module_type(mt), text))
    }
    "assert_uninstantiable" -> {
      use filename <- decode.field("filename", decode.string)
      use text <- decode.optional_field("text", "", decode.string)
      decode.success(AssertUninstantiable(line, filename, text))
    }
    "assert_unlinkable" -> {
      use filename <- decode.field("filename", decode.string)
      use text <- decode.optional_field("text", "", decode.string)
      decode.success(AssertUnlinkable(line, filename, text))
    }
    "action" -> {
      use action <- decode.field("action", action_decoder())
      decode.success(ActionCmd(line, action))
    }
    other -> decode.success(Unhandled(line, other))
  }
}

fn action_decoder() -> decode.Decoder(Action) {
  use ty <- decode.field("type", decode.string)
  use field <- decode.field("field", decode.string)
  use module <- decode.optional_field("module", "", decode.string)
  case ty {
    "get" -> decode.success(Get(field, blank_to_none(module)))
    _ -> {
      use args <- decode.optional_field(
        "args",
        [],
        decode.list(spec_value_decoder()),
      )
      decode.success(Invoke(field, args, blank_to_none(module)))
    }
  }
}

fn spec_value_decoder() -> decode.Decoder(SpecValue) {
  use ty <- decode.field("type", decode.string)
  case ty {
    // A `v128` value's `value` is an ARRAY of per-lane decimal-of-bits strings (with an optional
    // `lane_type`), NOT a single string — decode it separately so the scalar path is unchanged.
    "v128" -> {
      use lane_type <- decode.optional_field("lane_type", "i32", decode.string)
      use lanes <- decode.optional_field(
        "value",
        [],
        decode.list(decode.string),
      )
      decode.success(parse_v128(lane_type, lanes))
    }
    _ -> {
      use value <- decode.optional_field("value", "", decode.string)
      decode.success(parse_spec_value(ty, value))
    }
  }
}

/// Build a `V128Val` from the wast2json `lane_type` + the per-lane `value` strings. Each lane
/// string is run through the EXISTING scalar parse at the lane's scalar type (so per-lane NaN
/// tokens and decimal-of-bits are handled by the already-tested scalar path). An absent `value`
/// (a placeholder in an `assert_trap`) yields an empty lane list, never compared.
fn parse_v128(lane_type: String, values: List(String)) -> SpecValue {
  let lane = string_to_lane(lane_type)
  V128Val(lane, list.map(values, fn(s) { parse_lane_scalar(lane, s) }))
}

/// Map one lane's decimal-of-unsigned-bits string to its scalar `SpecValue` at the lane's type.
/// `i8`/`i16`/`i32` lanes → `I32Val` (their unsigned pattern fits in 32 bits); `i64` → `I64Val`;
/// `f32`/`f64` → a NaN class (`nan:canonical`/`nan:arithmetic`) or a concrete `F32Bits`/`F64Bits`.
fn parse_lane_scalar(lane: V128Lane, value: String) -> SpecValue {
  case lane {
    LaneI8 | LaneI16 | LaneI32 -> I32Val(parse_bits(value))
    LaneI64 -> I64Val(parse_bits(value))
    LaneF32 ->
      case nan_kind(value) {
        Some(k) -> F32Nan(k)
        None -> F32Bits(parse_bits(value))
      }
    LaneF64 ->
      case nan_kind(value) {
        Some(k) -> F64Nan(k)
        None -> F64Bits(parse_bits(value))
      }
  }
}

/// Map the wast2json `lane_type` string to a `V128Lane`. An unrecognised type defaults to `LaneI8`
/// (the finest chunking) — a defensive default; wabt 1.0.41 only emits the six known lane types.
fn string_to_lane(s: String) -> V128Lane {
  case s {
    "i8" -> LaneI8
    "i16" -> LaneI16
    "i32" -> LaneI32
    "i64" -> LaneI64
    "f32" -> LaneF32
    "f64" -> LaneF64
    _ -> LaneI8
  }
}

/// Build a `SpecValue` from the JSON `type` tag and the `value` STRING. Integers and
/// concrete floats parse the decimal-of-unsigned-bits to an `Int`; the NaN literals
/// map to a `NanKind`. An absent/empty value (e.g. an `assert_trap`'s placeholder
/// `expected:[{type:i32}]`) parses to `0` and is never compared as a value.
fn parse_spec_value(ty: String, value: String) -> SpecValue {
  case ty {
    "i32" -> I32Val(parse_bits(value))
    "i64" -> I64Val(parse_bits(value))
    "f32" ->
      case nan_kind(value) {
        Some(k) -> F32Nan(k)
        None -> F32Bits(parse_bits(value))
      }
    "f64" ->
      case nan_kind(value) {
        Some(k) -> F64Nan(k)
        None -> F64Bits(parse_bits(value))
      }
    // Reference values (P5-11 / R18). wast2json encodes them as
    // `{"type":"externref"|"funcref","value":"null"|"<N>"}` (VERIFIED against wabt 1.0.41):
    // `"null"` → the typed null sentinel; a decimal `"<N>"` → an externref host-identity `N`
    // (from the test's `ref.extern N`) or a funcref slot index; an ABSENT value (an
    // assert_trap's `[{type:externref}]` placeholder) → a value-less reference never compared.
    "externref" ->
      case value {
        "null" -> NullRef(ExternRefTag)
        "" -> ExternRefVal(0)
        _ -> ExternRefVal(parse_bits(value))
      }
    "funcref" ->
      case value {
        "null" -> NullRef(FuncRefTag)
        "" -> FuncRefVal(None)
        _ -> FuncRefVal(Some(parse_bits(value)))
      }
    // GC abstract-heap-type reference expectations (Phase-8 GC). wasm-tools `json-from-wast`
    // encodes the `(ref.struct)`/`(ref.array)`/`(ref.i31)`/`(ref.eq)` result patterns as a bare
    // `type` with NO value ("a non-null ref of this kind") — mapped to `GcRef(kind)` and judged by
    // the oracle against the GC subtype lattice.
    "structref" -> GcRef(StructRefK)
    "arrayref" -> GcRef(ArrayRefK)
    "i31ref" -> GcRef(I31RefK)
    "eqref" -> GcRef(EqRefK)
    // `anyref` carries a HOST value in the suite (`ref.host N` / `null`): a null is the shared
    // sentinel; a non-null host any-ref is judged by kind only (`AnyRefK`) — its host identity is
    // not cross-checked yet (documented; extern.wast is the only user).
    "anyref" ->
      case value {
        "null" -> NullRef(ExternRefTag)
        _ -> GcRef(AnyRefK)
      }
    // The GC null-heap-types (`(ref.null none|nofunc|noextern|noexn)` and the generic `refnull`):
    // all denote the ONE shared null sentinel, matched by the existing null oracle arm.
    "nullref" | "refnull" | "nullfuncref" | "nullexternref" | "nullexnref" ->
      NullRef(FuncRefTag)
    // `exnref` (Phase-7 EH heap type): a null exn is the shared sentinel; a non-null exn is an
    // opaque non-null reference (identity not compared — like a funcref).
    "exnref" ->
      case value {
        "null" -> NullRef(FuncRefTag)
        _ -> FuncRefVal(None)
      }
    // Any other reftype spelling is out of scope; model as a null placeholder so a value position
    // never panics (such modules skip at parse / instantiate anyway).
    _ -> NullRef(FuncRefTag)
  }
}

fn nan_kind(value: String) -> Option(NanKind) {
  case value {
    "nan:canonical" -> Some(Canonical)
    "nan:arithmetic" -> Some(Arithmetic)
    _ -> None
  }
}

/// Parse a decimal-of-unsigned-bits string to an `Int`. BEAM integers are bignums, so
/// i64/f64 patterns up to `2^64-1` parse exactly. A non-numeric/empty string yields
/// `0` (only reached for value-less placeholders, never compared).
fn parse_bits(value: String) -> Int {
  case int.parse(value) {
    Ok(n) -> n
    Error(_) -> 0
  }
}

fn module_type(s: String) -> ModuleType {
  case s {
    "text" -> TextModule
    _ -> BinaryModule
  }
}

fn blank_to_none(s: String) -> Option(String) {
  case s {
    "" -> None
    other -> Some(other)
  }
}

// ─────────────────────────────── the v128 lane codec (S14) ───────────────────────────────
//
// A `v128` crosses the harness as 16 raw little-endian bytes (S14). These pure helpers convert
// between the `V128Val` lane list and that byte image, treating the 16 bytes as one 128-bit
// little-endian integer (lane 0 = low bits). Shared by `driver.gleam` (arg/result ABI marshalling)
// and `oracle.gleam` (re-decode a returned v128 at the expected's lane type).

/// The bit-width of one lane of `lane` (`8`/`16`/`32`/`64`). Multiply the count `128 / width` to
/// get the lane count.
pub fn v128_lane_bits(lane: V128Lane) -> Int {
  case lane {
    LaneI8 -> 8
    LaneI16 -> 16
    LaneI32 -> 32
    LaneI64 -> 64
    LaneF32 -> 32
    LaneF64 -> 64
  }
}

/// Pack a lane list into the 128-bit little-endian integer it represents. Lane `i`'s raw bits (its
/// unsigned pattern, masked to the lane width) occupy bits `[width*i, width*(i+1))` — lane 0 lowest.
/// A NaN-class lane carries no concrete bits (it is only ever an EXPECTED, never packed as an
/// actual) and contributes `0`.
pub fn v128_pack(lanes: List(SpecValue), lane: V128Lane) -> Int {
  let width = v128_lane_bits(lane)
  let mask = pow2(width) - 1
  let #(acc, _shift) =
    list.fold(lanes, #(0, 0), fn(state, v) {
      let #(acc, shift) = state
      let bits = int.bitwise_and(lane_raw_bits(v), mask)
      #(acc + int.bitwise_shift_left(bits, shift), shift + width)
    })
  acc
}

/// Decode a 128-bit little-endian integer into `128 / width` lanes at `lane`. Integer lanes become
/// `I32Val`/`I64Val`; float lanes become `F32Bits`/`F64Bits` (a returned float lane is a concrete
/// bit pattern — the oracle matches it against a concrete OR a NaN-class expectation). Used by both
/// the driver (tag a returned v128) and the oracle (re-decode at the expected's lane type).
pub fn v128_unpack(n: Int, lane: V128Lane) -> List(SpecValue) {
  let width = v128_lane_bits(lane)
  let mask = pow2(width) - 1
  let count = 128 / width
  seq(count)
  |> list.map(fn(i) {
    let bits = int.bitwise_and(int.bitwise_shift_right(n, width * i), mask)
    case lane {
      LaneI8 | LaneI16 | LaneI32 -> I32Val(bits)
      LaneI64 -> I64Val(bits)
      LaneF32 -> F32Bits(bits)
      LaneF64 -> F64Bits(bits)
    }
  })
}

/// Encode a 128-bit integer as its 16 raw little-endian bytes (a `BitArray` == the runtime
/// `<<_:128>>`). Byte `i` is `(n >> 8i) & 0xFF`.
pub fn v128_bytes_le(n: Int) -> BitArray {
  seq(16)
  |> list.map(fn(i) {
    <<{ int.bitwise_and(int.bitwise_shift_right(n, 8 * i), 0xFF) }:size(8)>>
  })
  |> bit_array.concat
}

/// The list `[0, 1, …, n-1]` (a local range — this stdlib has no `list.range`). `n <= 0` → `[]`.
fn seq(n: Int) -> List(Int) {
  build_seq(n - 1, [])
}

fn build_seq(i: Int, acc: List(Int)) -> List(Int) {
  case i < 0 {
    True -> acc
    False -> build_seq(i - 1, [i, ..acc])
  }
}

/// Decode a 16-byte little-endian `BitArray` back into its 128-bit integer. A shorter/other input
/// (never expected for a `v128` result) yields `0`.
pub fn v128_from_bytes(bytes: BitArray) -> Int {
  case bytes {
    <<n:size(128)-little-unsigned>> -> n
    _ -> 0
  }
}

/// The raw unsigned bit pattern a concrete scalar lane carries (mirrors `oracle.raw_bits`, kept
/// local so the codec is self-contained). NaN-class / reference lanes contribute `0`.
fn lane_raw_bits(v: SpecValue) -> Int {
  case v {
    I32Val(b) | I64Val(b) | F32Bits(b) | F64Bits(b) -> b
    _ -> 0
  }
}

fn pow2(n: Int) -> Int {
  case n {
    8 -> 0x100
    16 -> 0x10000
    32 -> 0x100000000
    64 -> 0x10000000000000000
    _ -> 1
  }
}
