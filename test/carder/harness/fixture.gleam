//// The harness VALUE MODEL — the language-independent shape of one WebAssembly value as it
//// crosses the test boundary, plus the `v128` lane codec.
////
//// A `SpecValue` is how an EXPECTED (parsed from a `.expected` oracle by `corpus`) and an ACTUAL
//// (marshalled off the BEAM by `driver`) meet in `oracle.matches`. Two invariants make that
//// comparison sound, and both are load-bearing:
////
////  - Integers and concrete floats hold the **raw UNSIGNED bit pattern**, never a decoded float
////    (D5). BEAM integers are bignums, so an i64/f64 pattern up to `2^64-1` is exact, and float
////    comparison is bit-exact rather than approximate.
////  - A NaN expectation carries only a `NanKind` CLASS — never a concrete bit pattern — because
////    the spec fixes only the payload class, not the payload bits (see `oracle.matches`).
////
//// SCOPE (the frontend split). This module used to be the parse half of the wasm conformance
//// harness as well: wast2json JSON → typed `Fixture`/`Command`/`Action`. carder is now purely the
//// backend and has no `.wast` fixtures, so the whole JSON/command half (`Fixture`, `Command`,
//// `Action`, `ModuleType`, `parse`, `load` and their decoders) moved to scribbler with the
//// WebAssembly frontend. What remains is exactly the part that is about VALUES, which is
//// source-language-agnostic and is still driven by every corpus/tier/optimize proof here.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option}

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

/// A single WebAssembly value as it crosses the test boundary. Integers and concrete floats
/// hold the **raw UNSIGNED bit pattern** (in a `.expected` oracle it is spelled as the decimal
/// of that pattern, e.g. `f32:1065353216` for `1.0`, parsed to an `Int` by `corpus.parse`).
/// A NaN expectation carries only a `NanKind`, never concrete bits. Reference values
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
///   opaque type-tagged table entry); `index` is diagnostic only. `None` = a value-less funcref
///   placeholder (an expectation that asserts only "a funcref", carrying no slot).
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
