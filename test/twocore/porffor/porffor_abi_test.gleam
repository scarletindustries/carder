//// Spec tests for `porffor_abi` — the pure `(f64, i32)` typed-value ABI (P7-08 §C/§D/§F).
////
//// These assert against the **ECMAScript spec** ([ECMA-262 §6.1.6.1.20 `Number::toString`](https://tc39.es/ecma262/#sec-numeric-types-number-tostring))
//// and **Porffor 0.61.13's measured semantics** (`compiler/types.js` type tags, `compiler/wrap.js`
//// `porfToJSValue`), never "whatever the code emits". The raw bit patterns are the exact
//// IEEE-754 encodings of the named JS numbers (computed with `erlang:float_to_binary`), and the
//// expected strings are the JS-exact `Number::toString` output (cross-checked against `porf run`).

import gleeunit/should
import twocore/runtime/porffor_abi.{
  PBool, PNull, PNumber, POpaque, PString, PUndefined,
}

// ─────────────────────────── §F: ECMAScript Number::toString ───────────────────────────

/// The load-bearing formatter: `porf_number_to_string(bits)` == the ECMAScript
/// `Number::toString(x, 10)` string for each `x`, from the raw IEEE-754 bits. Covers the
/// integer form, the shortest-round-trip fraction (`0.1+0.2`), both exponential thresholds
/// (`1e21` up, `1e-7` down), the boundary that stays fixed (`1e20`, `1e-6`), and the special
/// bit patterns (`±0`, `±Inf`, `NaN` — checked from the bits, since Erlang has no such float).
pub fn number_to_string_spec_test() {
  // integers print with no ".0"
  porffor_abi.porf_number_to_string(0x0000000000000000)
  |> should.equal("0")
  // -0.0 prints "0" (ECMA-262: -0 → "0")
  porffor_abi.porf_number_to_string(0x8000000000000000)
  |> should.equal("0")
  porffor_abi.porf_number_to_string(0x4045000000000000)
  |> should.equal("42")
  porffor_abi.porf_number_to_string(0x4010000000000000)
  |> should.equal("4")
  porffor_abi.porf_number_to_string(0x402C000000000000)
  |> should.equal("14")
  porffor_abi.porf_number_to_string(0x4059000000000000)
  |> should.equal("100")
  porffor_abi.porf_number_to_string(0x419D6F3454000000)
  |> should.equal("123456789")
  porffor_abi.porf_number_to_string(0x406FE00000000000)
  |> should.equal("255")
  // fixed-point with a decimal point
  porffor_abi.porf_number_to_string(0x3FE0000000000000)
  |> should.equal("0.5")
  porffor_abi.porf_number_to_string(0x401A000000000000)
  |> should.equal("6.5")
  porffor_abi.porf_number_to_string(0x400921F9F01B866E)
  |> should.equal("3.14159")
  // shortest round-trip (17 significant digits)
  porffor_abi.porf_number_to_string(0x3FD3333333333334)
  |> should.equal("0.30000000000000004")
  // 1e20 stays in full-digit integer form (below the 1e21 threshold)
  porffor_abi.porf_number_to_string(0x4415AF1D78B58C40)
  |> should.equal("100000000000000000000")
  // 1e21 and above go exponential with an explicit "+"
  porffor_abi.porf_number_to_string(0x444B1AE4D6E2EF50)
  |> should.equal("1e+21")
  // 1e-6 stays fixed (leading-zero form); 1e-7 goes exponential
  porffor_abi.porf_number_to_string(0x3EB0C6F7A0B5ED8D)
  |> should.equal("0.000001")
  porffor_abi.porf_number_to_string(0x3E7AD7F29ABCAF48)
  |> should.equal("1e-7")
  // special bit patterns (from the bits directly)
  porffor_abi.porf_number_to_string(0x7FF0000000000000)
  |> should.equal("Infinity")
  porffor_abi.porf_number_to_string(0xFFF0000000000000)
  |> should.equal("-Infinity")
  porffor_abi.porf_number_to_string(0x7FF8000000000000)
  |> should.equal("NaN")
  // negative values carry the leading "-"
  porffor_abi.porf_number_to_string(0xC045000000000000)
  |> should.equal("-42")
}

/// `number_to_string_bytes` is the UTF-8 `BitArray` of the same string (the `print` sink).
pub fn number_to_string_bytes_test() {
  porffor_abi.number_to_string_bytes(0x4045000000000000)
  |> should.equal(<<"42">>)
  porffor_abi.number_to_string_bytes(0x7FF8000000000000)
  |> should.equal(<<"NaN">>)
}

// ─────────────────────────── §E: printChar UTF-8 encoding ───────────────────────────

/// `char_code_to_utf8(f64_bits)` encodes the truncated code unit as UTF-8: ASCII → 1 byte,
/// (matching `String.fromCharCode(i)` piped to Node's `stdout.write`). `65.0` → `"A"`, ESC
/// (`27.0`) → `0x1b`, newline (`10.0`) → `0x0a`.
pub fn char_code_ascii_test() {
  // 65.0 bits = 0x4050400000000000
  porffor_abi.char_code_to_utf8(0x4050400000000000)
  |> should.equal(<<"A">>)
  // 27.0 (ESC) bits = 0x403B000000000000
  porffor_abi.char_code_to_utf8(0x403B000000000000)
  |> should.equal(<<0x1B>>)
  // 10.0 (newline) bits = 0x4024000000000000
  porffor_abi.char_code_to_utf8(0x4024000000000000)
  |> should.equal(<<0x0A>>)
}

/// A code unit ≥ 0x80 encodes to multi-byte UTF-8 — `é` = U+00E9 (233) → `0xC3 0xA9`
/// (2-byte). 233.0 bits = 0x406D200000000000.
pub fn char_code_multibyte_test() {
  porffor_abi.char_code_to_utf8(0x406D200000000000)
  |> should.equal(<<0xC3, 0xA9>>)
}

// ─────────────────────────── §D: porf_decode across type tags ───────────────────────────

/// A `MemReader` backed by a fixed `BitArray` starting at address 0: read `len` bytes at `addr`,
/// or `Error(Nil)` if out of range (mirrors the bounds-checked instance reader).
fn fixture_reader(mem: BitArray) -> fn(Int, Int) -> Result(BitArray, Nil) {
  fn(addr: Int, len: Int) {
    case bit_slice(mem, addr, len) {
      Ok(bytes) -> Ok(bytes)
      Error(_) -> Error(Nil)
    }
  }
}

@external(erlang, "binary", "part")
fn erlang_binary_part(bin: BitArray, pos: Int, len: Int) -> BitArray

/// Total slice: `Ok(bytes)` for an in-range `[pos, pos+len)`, else `Error(Nil)`.
fn bit_slice(mem: BitArray, pos: Int, len: Int) -> Result(BitArray, Nil) {
  case pos >= 0 && len >= 0 && pos + len <= byte_size(mem) {
    True -> Ok(erlang_binary_part(mem, pos, len))
    False -> Error(Nil)
  }
}

@external(erlang, "erlang", "byte_size")
fn byte_size(bin: BitArray) -> Int

/// The primitive tags decode exactly, with NO memory access needed. `undefined`/`number`/
/// `boolean` are the common scalar completion values (T12).
pub fn decode_scalars_test() {
  let no_mem = fixture_reader(<<>>)
  // 0x00 undefined
  porffor_abi.porf_decode(0, 0x00, no_mem)
  |> should.equal(PUndefined)
  // 0x01 number — the raw bits pass through, compared bit-exactly
  porffor_abi.porf_decode(0x400C000000000000, 0x01, no_mem)
  |> should.equal(PNumber(0x400C000000000000))
  // 0x02 boolean: 0.0 → false, 1.0 → true
  porffor_abi.porf_decode(0x0000000000000000, 0x02, no_mem)
  |> should.equal(PBool(False))
  porffor_abi.porf_decode(0x3FF0000000000000, 0x02, no_mem)
  |> should.equal(PBool(True))
}

/// A `0x07` object with pointer `0` is `null`; a non-null object pointer is `POpaque("object")`
/// (heap walk deferred, T12).
pub fn decode_object_null_test() {
  let no_mem = fixture_reader(<<>>)
  porffor_abi.porf_decode(0x0000000000000000, 0x07, no_mem)
  |> should.equal(PNull)
  // f64 of 16.0 (a non-null pointer) → POpaque
  porffor_abi.porf_decode(0x4030000000000000, 0x07, no_mem)
  |> should.equal(POpaque("object"))
}

/// A `0x43` string pointer whose memory holds `[u32 len=3][UTF-16LE 'a','b','c']` decodes to
/// `PString("abc")` — the layout `porfToJSValue` reads (`compiler/wrap.js`). Pointer at addr 8.
pub fn decode_string_utf16_test() {
  // mem: 8 bytes padding, then len=3 (LE u32), then 'a','b','c' as LE u16 each.
  let mem = <<0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0x61, 0, 0x62, 0, 0x63, 0>>
  // pointer 8.0 in the f64
  porffor_abi.porf_decode(0x4020000000000000, 0x43, fixture_reader(mem))
  |> should.equal(PString("abc"))
}

/// A `0xC3` bytestring pointer whose memory holds `[u32 len=5][Latin-1 'h','e','l','l','o']`
/// decodes to `PString("hello")`. Pointer at addr 0.
pub fn decode_string_latin1_test() {
  let mem = <<5, 0, 0, 0, 0x68, 0x65, 0x6C, 0x6C, 0x6F>>
  porffor_abi.porf_decode(0x0000000000000000, 0xC3, fixture_reader(mem))
  |> should.equal(PString("hello"))
}

/// A string whose pointer's memory cannot be read fails closed to `POpaque` (never a crash).
pub fn decode_string_out_of_range_test() {
  let no_mem = fixture_reader(<<>>)
  // pointer 1000.0, empty memory → the length read fails → POpaque
  porffor_abi.porf_decode(0x408F400000000000, 0x43, no_mem)
  |> should.equal(POpaque("string"))
}

/// An unknown/extended tag is `POpaque(kind)` — categorized, never a false green.
pub fn decode_opaque_tags_test() {
  let no_mem = fixture_reader(<<>>)
  porffor_abi.porf_decode(0, 0x06, no_mem)
  |> should.equal(POpaque("function"))
  porffor_abi.porf_decode(0, 0x48, no_mem)
  |> should.equal(POpaque("array"))
}
