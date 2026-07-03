//// `porffor_abi` — the pure Porffor `(f64, i32)` typed-value ABI (P7-08, J3).
////
//// Porffor represents **every JS value as a `(f64, i32)` pair** (`compiler/wrap.js`
//// "typed values", no NaN-boxing): the `f64` is the value (a JS number *directly*; for a
//// string/object/array an **i32 pointer** into linear memory, carried in the f64's integer
//// value) and the `i32` is a **type tag** from `compiler/types.js`. A Porffor program's
//// entry `m : () → (result f64 i32)` returns its completion value as such a pair.
////
//// This module is the **pure** value model shared by two consumers with **no cycle**:
//// - `rt_host` imports `number_to_string_bytes`/`char_code_to_utf8` for the `print`/
////   `printChar` intrinsics (§F/§E of the unit doc);
//// - the run-ABI (`pipeline.run_porffor`) + the JS harness import `porf_decode`/`PorfValue`
////   to decode a returned pair into a judgeable JS value (§D).
////
//// Everything here is **total** — an unknown tag, an out-of-range pointer, or a malformed
//// value yields `POpaque`/a categorized value, NEVER a panic (a malformed value is a reported
//// skip, not a runner crash, D3a). Number formatting reproduces **ECMAScript
//// `Number::toString(x, 10)`** ([ECMA-262 §6.1.6.1.20](https://tc39.es/ecma262/#sec-numeric-types-number-tostring)),
//// verified against `porf run` (T13). All Porffor facts are measured against Porffor 0.61.13
//// (`compiler/types.js`, `compiler/wrap.js` `porfToJSValue`).

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/result
import gleam/string

// ─────────────────────────── the type-tag table (compiler/types.js) ───────────────────────────

/// Porffor type tag `undefined` (`compiler/types.js`). Decodes to `PUndefined`.
pub const tag_undefined: Int = 0x00

/// Porffor type tag `number`. The f64 IS the value (reconstructed from its raw bits).
pub const tag_number: Int = 0x01

/// Porffor type tag `boolean`. `false` iff the f64 value is `0.0`, else `true` (`Boolean(v)`).
pub const tag_boolean: Int = 0x02

/// Porffor type tag `object`. A null-or-pointer type: pointer `0` is `null`, else a heap object.
pub const tag_object: Int = 0x07

/// Porffor type tag `string` (`0x03 | 0x40` length-flag). A UTF-16 string read from memory.
pub const tag_string: Int = 0x43

/// Porffor type tag `bytestring` (`string | 0x80` parity). A Latin-1 byte-string read from memory.
pub const tag_bytestring: Int = 0xC3

// ─────────────────────────── the judged-value type (§D.1) ───────────────────────────

/// A judged JS value decoded from a Porffor `(f64, i32)` pair (§C). The harness (P7-09)
/// compares a `PorfValue` against the `porf run`/Node oracle. PRIMITIVES are decoded exactly;
/// pointer types are read from the instance's linear memory through a handed-in reader
/// capability; genuinely-opaque or extended kinds (function/symbol/object/array/…) become
/// `POpaque` so the harness categorizes them rather than false-greening.
///
/// - `PUndefined` — tag `0x00`.
/// - `PNull` — tag `0x07` with pointer `0`.
/// - `PBool(Bool)` — tag `0x02`.
/// - `PNumber(bits)` — tag `0x01`; the **raw f64 bits** (D5), compared bit-exactly by the
///   harness so NaN and `-0.0` stay distinct from `+0.0`.
/// - `PString(String)` — tag `0x43` (UTF-16) or `0xC3` (Latin-1), decoded to a Gleam string.
/// - `POpaque(kind)` — an extended/opaque kind (non-null object, array, function, symbol,
///   bigint, date, …) or a value whose pointer could not be read; judged structurally by the
///   harness, never a false green (T12 — heap-typed results are best-effort/deferred).
pub type PorfValue {
  PUndefined
  PNull
  PBool(Bool)
  PNumber(bits: Int)
  PString(String)
  POpaque(kind: String)
}

/// A read capability over the instance's exported linear memory `"$"` (§C.1): read `len`
/// bytes at byte address `addr`. HANDED IN by the caller (built from the instance's memory
/// via an FFI — P7-09's routed reader, §H.2) — a capability, never ambient authority (D3a):
/// `porf_decode` cannot reach memory it was not given, and a read out of range is `Error(Nil)`
/// (a categorized decode failure, never a crash). For unit-testing, a `BitArray`-backed reader
/// is supplied directly (no FFI needed).
pub type MemReader =
  fn(Int, Int) -> Result(BitArray, Nil)

// ─────────────────────────── f64 bit reconstruction ───────────────────────────

/// The exponent field (11 bits) of the IEEE-754 double whose raw bits are `bits`.
fn exponent_bits(bits: Int) -> Int {
  int.bitwise_and(int.bitwise_shift_right(bits, 52), 0x7FF)
}

/// The classification of an IEEE-754 double from its raw 64-bit pattern — checked on the
/// BITS (before reconstructing an Erlang float, which cannot represent ±Inf/NaN, §C.2).
type FloatClass {
  Zero
  PosInfinity
  NegInfinity
  NotANumber
  Finite
}

/// Classify the double whose raw bits are `bits` WITHOUT constructing an Erlang float — so a
/// ±Inf/NaN pattern (which Erlang cannot hold as a float) is handled from the bits directly.
/// `+0.0`/`-0.0` → `Zero`; exponent all-ones + zero mantissa → ±Infinity by sign; exponent
/// all-ones + non-zero mantissa → NaN; everything else (incl. subnormals) → Finite. Total.
fn classify_bits(bits: Int) -> FloatClass {
  let exp = exponent_bits(bits)
  let mantissa = int.bitwise_and(bits, 0xFFFFFFFFFFFFF)
  let sign = int.bitwise_and(int.bitwise_shift_right(bits, 63), 1)
  case exp, mantissa {
    0, 0 -> Zero
    0x7FF, 0 ->
      case sign {
        1 -> NegInfinity
        _ -> PosInfinity
      }
    0x7FF, _ -> NotANumber
    _, _ -> Finite
  }
}

/// Reconstruct the Erlang float from a FINITE 64-bit pattern (the caller guarantees finiteness
/// via `classify_bits`). Pure Gleam bit-array round-trip: pack the bits into a 64-bit big-endian
/// binary, then read it back as a 64-bit float. Only called for finite values, so the match
/// never fails.
fn bits_to_float_unsafe(bits: Int) -> Float {
  let assert <<f:float-size(64)>> = <<bits:size(64)>>
  f
}

/// Reconstruct the IEEE-754 double whose raw 64-bit pattern is `bits`, as an Erlang `Float`.
///
/// - `bits`: the raw unsigned 64-bit pattern (D5 — how an `f64` crosses the run-ABI).
/// - Returns the double for a finite value (incl. `±0.0` → `0.0`); returns `0.0` for a ±Inf/NaN
///   pattern (Erlang has no float for those). Callers that must distinguish ±Inf/NaN inspect the
///   bits directly (e.g. `porf_number_to_string`). Total — never panics.
pub fn f64_from_bits(bits: Int) -> Float {
  case classify_bits(bits) {
    Finite -> bits_to_float_unsafe(bits)
    _ -> 0.0
  }
}

/// Pack the raw 64-bit pattern of the Erlang float `f` (the inverse of `f64_from_bits` for a
/// finite `f`). Used where a handler must return an `f64` result as its raw bits. Total for a
/// finite `f`.
pub fn float_to_bits(f: Float) -> Int {
  let assert <<bits:size(64)>> = <<f:float-size(64)>>
  bits
}

// ─────────────────────────── ECMAScript Number::toString (§F) ───────────────────────────

/// The `[short]` option atom for `erlang:float_to_binary/2` — the shortest round-tripping
/// decimal (the digit oracle for `Number::toString`).
type FloatFormatOption {
  Short
}

/// `erlang:float_to_binary(F, [short])` — the shortest decimal string that round-trips to the
/// double `F` (e.g. `42.0` → `"42.0"`, `0.1+0.2` → `"0.30000000000000004"`). The RENDERING
/// differs from JS (Erlang always shows a `.`, uses its own `e` thresholds), so `parse_short`
/// re-derives the digits + exponent and the ECMAScript rules produce the JS-exact bytes.
@external(erlang, "erlang", "float_to_binary")
fn erlang_float_to_binary(f: Float, options: List(FloatFormatOption)) -> String

/// Format the f64 whose raw IEEE-754 bits are `bits` as ECMAScript `Number::toString(x, 10)`
/// ([ECMA-262 §6.1.6.1.20](https://tc39.es/ecma262/#sec-numeric-types-number-tostring)) — the
/// exact bytes Porffor's `print` (`i => print(i.toString())`) writes.
///
/// Special bit patterns are handled FIRST (from the bits, before reconstructing a float):
/// `±0.0` → `"0"`, `+Inf` → `"Infinity"`, `-Inf` → `"-Infinity"`, NaN → `"NaN"`. Otherwise the
/// shortest round-tripping digits (`float_to_binary/2 [short]`) are re-parsed into `(digits, n)`
/// with `value = digits × 10^(n − k)` (`k = |digits|`), and the ECMAScript steps 5–10 pick the
/// integer / fixed-point / leading-zero / exponential rendering with the JS thresholds
/// (`k ≤ n ≤ 21`, `0 < n ≤ 21`, `-6 < n ≤ 0`, else exponential).
///
/// - `bits`: the raw unsigned 64-bit pattern of the number (D5).
/// - Returns the JS-exact decimal string. Total — never panics.
pub fn porf_number_to_string(bits: Int) -> String {
  case classify_bits(bits) {
    Zero -> "0"
    PosInfinity -> "Infinity"
    NegInfinity -> "-Infinity"
    NotANumber -> "NaN"
    Finite -> {
      let f = bits_to_float_unsafe(bits)
      let negative = f <. 0.0
      let magnitude = float.absolute_value(f)
      let #(digits, n) = parse_short(erlang_float_to_binary(magnitude, [Short]))
      let body = ecma_render(digits, n)
      case negative {
        True -> "-" <> body
        False -> body
      }
    }
  }
}

/// The ECMAScript number string as the UTF-8 `BitArray` the `print` intrinsic appends to the
/// output buffer (§B.2/§E) — `porf_number_to_string` then `bit_array.from_string`. Total.
pub fn number_to_string_bytes(bits: Int) -> BitArray {
  bit_array.from_string(porf_number_to_string(bits))
}

/// Re-parse a shortest-round-trip decimal (from `float_to_binary/2 [short]`, of a NON-NEGATIVE
/// magnitude) into `#(digits, n)` where `digits` is the minimal significant-digit string (no
/// leading/trailing zeros) and `n` is the ECMAScript decimal exponent such that the value equals
/// `int(digits) × 10^(n − |digits|)`. E.g. `"42.0"` → `#("42", 2)`, `"3.14159"` → `#("314159", 1)`,
/// `"1.0e21"` → `#("1", 22)`, `"1.0e-7"` → `#("1", -6)`. Total.
fn parse_short(s: String) -> #(String, Int) {
  let #(mantissa, exp) = case string.split_once(s, "e") {
    Ok(#(m, e)) -> #(m, result.unwrap(int.parse(e), 0))
    Error(_) -> #(s, 0)
  }
  let #(int_part, frac_part) = case string.split_once(mantissa, ".") {
    Ok(#(i, f)) -> #(i, f)
    Error(_) -> #(mantissa, "")
  }
  let digits = int_part <> frac_part
  // value = int(digits) × 10^(exp − |frac_part|)
  let exp10 = exp - string.length(frac_part)
  let #(no_trailing, exp10b) = strip_trailing_zeros(digits, exp10)
  let stripped = strip_leading_zeros(no_trailing)
  let k = string.length(stripped)
  #(stripped, exp10b + k)
}

/// Strip trailing `'0'`s from `digits`, raising `exp10` by one per removed zero (a trailing zero
/// is `× 10`). Keeps at least one digit. Total.
fn strip_trailing_zeros(digits: String, exp10: Int) -> #(String, Int) {
  case string.ends_with(digits, "0") && string.length(digits) > 1 {
    True -> strip_trailing_zeros(string.drop_end(digits, 1), exp10 + 1)
    False -> #(digits, exp10)
  }
}

/// Strip leading `'0'`s from `digits` (they do not change the integer value or the exponent).
/// Keeps at least one digit. Total.
fn strip_leading_zeros(digits: String) -> String {
  case string.starts_with(digits, "0") && string.length(digits) > 1 {
    True -> strip_leading_zeros(string.drop_start(digits, 1))
    False -> digits
  }
}

/// Apply ECMAScript `Number::toString` steps 5–10 to the significant `digits` (k = |digits|)
/// and decimal exponent `n` (`value = int(digits) × 10^(n − k)`) — the JS-exact rendering:
/// `k ≤ n ≤ 21` integer form; `0 < n ≤ 21` fixed with point; `-6 < n ≤ 0` leading-zero fixed;
/// otherwise exponential. Total.
fn ecma_render(digits: String, n: Int) -> String {
  let k = string.length(digits)
  case k <= n && n <= 21 {
    True -> digits <> string.repeat("0", n - k)
    False ->
      case 0 < n && n <= 21 {
        True ->
          string.slice(digits, 0, n) <> "." <> string.slice(digits, n, k - n)
        False ->
          case -6 < n && n <= 0 {
            True -> "0." <> string.repeat("0", 0 - n) <> digits
            False -> render_exponential(digits, n, k)
          }
      }
  }
}

/// The exponential form `d1["." d2…dk] "e" ("+"|"-") |n−1|` (ECMAScript steps 9–10), for
/// `n > 21` or `n ≤ -6`. Total.
fn render_exponential(digits: String, n: Int, k: Int) -> String {
  let exp = n - 1
  let mantissa = case k {
    1 -> digits
    _ -> string.slice(digits, 0, 1) <> "." <> string.slice(digits, 1, k - 1)
  }
  let sign = case exp >= 0 {
    True -> "+"
    False -> "-"
  }
  mantissa <> "e" <> sign <> int.to_string(int.absolute_value(exp))
}

// ─────────────────────────── printChar UTF-8 encoding (§E) ───────────────────────────

/// Encode the UTF-16 code unit carried by Porffor's `printChar` (`i => print(String
/// .fromCharCode(i))`) as the UTF-8 bytes Node's `stdout.write` would emit (§E.2).
///
/// - `bits`: the raw f64 bits of the char-code argument (D5). The value is truncated to an
///   integer and reduced mod 2^16 (matching `String.fromCharCode`'s ToUint16), then UTF-8
///   (WTF-8) encoded — 1 byte for ASCII, 2 for `< 0x800`, 3 otherwise (incl. lone surrogates,
///   a rare categorized edge). Total — never panics.
pub fn char_code_to_utf8(bits: Int) -> BitArray {
  let code = int.bitwise_and(float.truncate(f64_from_bits(bits)), 0xFFFF)
  encode_code_unit(code)
}

/// UTF-8 (WTF-8) encode a single 16-bit code unit `code` (0…0xFFFF). Total.
fn encode_code_unit(code: Int) -> BitArray {
  case code < 0x80 {
    True -> <<code:8>>
    False ->
      case code < 0x800 {
        True -> {
          let b0 = int.bitwise_or(0xC0, int.bitwise_shift_right(code, 6))
          let b1 = int.bitwise_or(0x80, int.bitwise_and(code, 0x3F))
          <<b0:8, b1:8>>
        }
        False -> {
          let b0 = int.bitwise_or(0xE0, int.bitwise_shift_right(code, 12))
          let b1 =
            int.bitwise_or(
              0x80,
              int.bitwise_and(int.bitwise_shift_right(code, 6), 0x3F),
            )
          let b2 = int.bitwise_or(0x80, int.bitwise_and(code, 0x3F))
          <<b0:8, b1:8, b2:8>>
        }
      }
  }
}

// ─────────────────────────── the (f64,i32) decoder (§D.2) ───────────────────────────

/// Decode a returned Porffor `(f64_bits, type_tag)` pair into a judgeable `PorfValue`,
/// mirroring Porffor's own `porfToJSValue` (`compiler/wrap.js`). PURE — every memory access
/// goes through the handed-in `read` capability (§D.1).
///
/// PRIMITIVES are decoded exactly: `0x00`→`PUndefined`, `0x01`→`PNumber(bits)`,
/// `0x02`→`PBool(v ≠ 0)`, `0x07` with pointer `0`→`PNull`. `0x43`/`0xC3` read a UTF-16/Latin-1
/// string from memory → `PString`. Every OTHER tag — a non-null object, array, function,
/// symbol, bigint, date, or a string whose pointer could not be read — yields `POpaque(kind)`
/// (heap-typed results are best-effort/deferred, T12), never a false green.
///
/// - `f64_bits`: element 0 of `result_list(2, pkg)` — the value (a number's raw f64 bits, or a
///   pointer carried as the f64's integer value for a pointer type).
/// - `type_tag`: element 1 — the i32 type tag (§C.3).
/// - `read`: the memory-read capability (§D.1); may fail closed (→ `POpaque`).
/// - Returns the judged `PorfValue`. Total — never panics.
pub fn porf_decode(f64_bits: Int, type_tag: Int, read: MemReader) -> PorfValue {
  case type_tag {
    0x00 -> PUndefined
    0x01 -> PNumber(f64_bits)
    0x02 -> PBool(f64_from_bits(f64_bits) != 0.0)
    0x07 -> decode_object(f64_bits)
    0x43 -> decode_string_utf16(f64_bits, read)
    0xC3 -> decode_string_latin1(f64_bits, read)
    _ -> POpaque(tag_name(type_tag))
  }
}

/// Decode an `object` (tag `0x07`): pointer `0` is `null`; a non-null object pointer is a
/// heap walk that is best-effort/deferred (T12) — reported `POpaque("object")`. Total.
fn decode_object(ptr_bits: Int) -> PorfValue {
  case float.truncate(f64_from_bits(ptr_bits)) {
    0 -> PNull
    _ -> POpaque("object")
  }
}

/// Decode a `string` (tag `0x43`): read a `u32` length at the pointer, then `2 × length` bytes
/// as little-endian UTF-16 code units. A read failure or a lone surrogate is `POpaque("string")`.
fn decode_string_utf16(ptr_bits: Int, read: MemReader) -> PorfValue {
  let ptr = float.truncate(f64_from_bits(ptr_bits))
  case read_u32_le(read, ptr) {
    Error(_) -> POpaque("string")
    Ok(len) ->
      case read(ptr + 4, len * 2) {
        Error(_) -> POpaque("string")
        Ok(bytes) ->
          case utf16le_to_string(bytes, "") {
            Ok(s) -> PString(s)
            Error(_) -> POpaque("string")
          }
      }
  }
}

/// Decode a `bytestring` (tag `0xC3`): read a `u32` length at the pointer, then `length` Latin-1
/// bytes (each byte = a code point). A read failure is `POpaque("bytestring")`.
fn decode_string_latin1(ptr_bits: Int, read: MemReader) -> PorfValue {
  let ptr = float.truncate(f64_from_bits(ptr_bits))
  case read_u32_le(read, ptr) {
    Error(_) -> POpaque("bytestring")
    Ok(len) ->
      case read(ptr + 4, len) {
        Error(_) -> POpaque("bytestring")
        Ok(bytes) ->
          case latin1_to_string(bytes, "") {
            Ok(s) -> PString(s)
            Error(_) -> POpaque("bytestring")
          }
      }
  }
}

/// Read a little-endian `u32` at byte address `addr` through `read`. `Error(Nil)` if the read
/// capability cannot supply 4 bytes there. Total.
fn read_u32_le(read: MemReader, addr: Int) -> Result(Int, Nil) {
  case read(addr, 4) {
    Ok(<<b0:8, b1:8, b2:8, b3:8>>) ->
      Ok(b0 + b1 * 256 + b2 * 65_536 + b3 * 16_777_216)
    _ -> Error(Nil)
  }
}

/// Fold a little-endian UTF-16 byte buffer into a Gleam string (2 bytes = one code unit).
/// `Error(Nil)` on an odd byte count or a code unit that is not a scalar value (a lone
/// surrogate) — surfaced as `POpaque` by the caller. Total.
fn utf16le_to_string(bytes: BitArray, acc: String) -> Result(String, Nil) {
  case bytes {
    <<>> -> Ok(acc)
    <<lo:8, hi:8, rest:bits>> -> {
      let code = lo + hi * 256
      case string.utf_codepoint(code) {
        Ok(cp) ->
          utf16le_to_string(rest, acc <> string.from_utf_codepoints([cp]))
        Error(_) -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// Fold a Latin-1 byte buffer into a Gleam string (each byte 0…255 = a code point). Total.
fn latin1_to_string(bytes: BitArray, acc: String) -> Result(String, Nil) {
  case bytes {
    <<>> -> Ok(acc)
    <<b:8, rest:bits>> ->
      case string.utf_codepoint(b) {
        Ok(cp) ->
          latin1_to_string(rest, acc <> string.from_utf_codepoints([cp]))
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// A human-readable kind name for an extended/opaque type tag (`compiler/types.js`), used to
/// label a `POpaque` value the harness categorizes. Total.
fn tag_name(tag: Int) -> String {
  case tag {
    0x04 -> "bigint"
    0x05 -> "symbol"
    0x06 -> "function"
    0x07 -> "object"
    0x0A -> "date"
    0x48 -> "array"
    _ -> "unknown"
  }
}
