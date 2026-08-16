//// Self-tests for the wast2json fixture parser (run NOW — no compiler needed).
////
//// The load-bearing checks: the f32 `1.0 → "1065353216"` vector reconstructs the BITS
//// 0x3F800000 (NOT a parsed float); an i64 value beyond JSON float precision parses
//// EXACTLY; NaN literals carry only a class; and every Phase-1 command/action kind is
//// modelled (unknown kinds degrade to `Unhandled`, never an error).

import carder/conformance/fixture.{
  Arithmetic, AssertInvalid, AssertMalformed, AssertReturn, AssertTrap,
  BinaryModule, Canonical, ExternRefTag, ExternRefVal, F32Bits, F32Nan, F64Bits,
  FuncRefTag, FuncRefVal, Get, I32Val, I64Val, Invoke, ModuleCmd, NullRef,
  Register, TextModule, Unhandled,
}
import gleam/bit_array
import gleam/option.{None, Some}

fn parse(json: String) -> fixture.Fixture {
  let assert Ok(f) = fixture.parse(bit_array.from_string(json))
  f
}

/// `f32 1.0` arrives as the STRING "1065353216" (= 0x3F800000) and must reconstruct as
/// `F32Bits(1065353216)` — the raw bit pattern — not as a parsed float (D5). Likewise
/// i64/f64 strings beyond JSON number precision parse exactly.
pub fn assert_return_f32_bits_vector_test() {
  let json =
    "{\"commands\":[
       {\"type\":\"assert_return\",\"line\":7,
        \"action\":{\"type\":\"invoke\",\"field\":\"f\",
                    \"args\":[{\"type\":\"i64\",\"value\":\"18446744073709551615\"}]},
        \"expected\":[{\"type\":\"f32\",\"value\":\"1065353216\"}]}]}"
  let assert [AssertReturn(7, action, expected)] = parse(json).commands
  assert action == Invoke("f", [I64Val(18_446_744_073_709_551_615)], None)
  // The bits 0x3F800000 = 1065353216, exact — never a float.
  assert expected == [F32Bits(1_065_353_216)]
}

/// f64 1.0 is "4607182418800017408" (0x3FF0000000000000) — parsed exactly as bits.
pub fn f64_bits_vector_test() {
  let json =
    "{\"commands\":[
       {\"type\":\"assert_return\",\"line\":1,
        \"action\":{\"type\":\"invoke\",\"field\":\"g\",\"args\":[]},
        \"expected\":[{\"type\":\"f64\",\"value\":\"4607182418800017408\"}]}]}"
  let assert [AssertReturn(_, _, [F64Bits(bits)])] = parse(json).commands
  assert bits == 4_607_182_418_800_017_408
}

/// NaN expectations carry only a CLASS (no concrete bits).
pub fn nan_expectation_test() {
  let json =
    "{\"commands\":[
       {\"type\":\"assert_return\",\"line\":1,
        \"action\":{\"type\":\"invoke\",\"field\":\"n\",\"args\":[]},
        \"expected\":[{\"type\":\"f32\",\"value\":\"nan:canonical\"},
                      {\"type\":\"f64\",\"value\":\"nan:arithmetic\"}]}]}"
  let assert [AssertReturn(_, _, expected)] = parse(json).commands
  assert expected == [F32Nan(Canonical), fixture.F64Nan(Arithmetic)]
}

/// A `module` command carries `filename` and an optional `name`.
pub fn module_command_test() {
  let json =
    "{\"commands\":[
       {\"type\":\"module\",\"line\":3,\"filename\":\"x.0.wasm\"},
       {\"type\":\"module\",\"line\":9,\"name\":\"$m\",\"filename\":\"x.1.wasm\"}]}"
  let assert [
    ModuleCmd(3, None, "x.0.wasm"),
    ModuleCmd(9, Some("$m"), "x.1.wasm"),
  ] = parse(json).commands
}

/// `assert_trap` carries the expected message substring; `assert_invalid`/
/// `assert_malformed` carry `filename` + `module_type` (binary vs text).
pub fn reject_and_trap_commands_test() {
  let json =
    "{\"commands\":[
       {\"type\":\"assert_trap\",\"line\":2,
        \"action\":{\"type\":\"invoke\",\"field\":\"d\",
                    \"args\":[{\"type\":\"i32\",\"value\":\"1\"},
                              {\"type\":\"i32\",\"value\":\"0\"}]},
        \"text\":\"integer divide by zero\",\"expected\":[{\"type\":\"i32\"}]},
       {\"type\":\"assert_invalid\",\"line\":4,\"filename\":\"x.1.wasm\",
        \"text\":\"type mismatch\",\"module_type\":\"binary\"},
       {\"type\":\"assert_malformed\",\"line\":5,\"filename\":\"x.1.wat\",
        \"text\":\"unexpected token\",\"module_type\":\"text\"}]}"
  let assert [
    AssertTrap(
      2,
      Invoke("d", [I32Val(1), I32Val(0)], None),
      "integer divide by zero",
    ),
    AssertInvalid(4, "x.1.wasm", BinaryModule, "type mismatch"),
    AssertMalformed(5, "x.1.wat", TextModule, "unexpected token"),
  ] = parse(json).commands
}

/// `register` and a `get` action are modelled; an unknown command kind degrades to
/// `Unhandled` (no silent drop, no error).
pub fn register_get_and_unhandled_test() {
  let json =
    "{\"commands\":[
       {\"type\":\"register\",\"line\":1,\"as\":\"lib\",\"name\":\"$m\"},
       {\"type\":\"assert_return\",\"line\":2,
        \"action\":{\"type\":\"get\",\"field\":\"glob\",\"module\":\"$m\"},
        \"expected\":[{\"type\":\"i32\",\"value\":\"42\"}]},
       {\"type\":\"assert_exhaustion\",\"line\":3,
        \"action\":{\"type\":\"invoke\",\"field\":\"f\",\"args\":[]},
        \"text\":\"call stack exhausted\"}]}"
  let assert [
    Register(1, "lib", Some("$m")),
    AssertReturn(2, Get("glob", Some("$m")), [I32Val(42)]),
    Unhandled(3, "assert_exhaustion"),
  ] = parse(json).commands
}

/// Reference values (P5-11 / R18) decode from wast2json's `{"type":"externref"|"funcref",
/// "value":"null"|"<N>"}` encoding: `"null"` → a typed `NullRef`; a decimal → an externref
/// host-identity (`ExternRefVal`) or a funcref slot index (`FuncRefVal`); an absent value → a
/// value-less reference placeholder. VERIFIED against wabt 1.0.41 output (table_get.json etc.).
pub fn reference_value_parsing_test() {
  let json =
    "{\"commands\":[
       {\"type\":\"assert_return\",\"line\":1,
        \"action\":{\"type\":\"invoke\",\"field\":\"g\",
                    \"args\":[{\"type\":\"externref\",\"value\":\"7\"}]},
        \"expected\":[{\"type\":\"externref\",\"value\":\"null\"}]},
       {\"type\":\"assert_return\",\"line\":2,
        \"action\":{\"type\":\"invoke\",\"field\":\"g\",\"args\":[]},
        \"expected\":[{\"type\":\"funcref\",\"value\":\"null\"}]},
       {\"type\":\"assert_return\",\"line\":3,
        \"action\":{\"type\":\"invoke\",\"field\":\"g\",\"args\":[]},
        \"expected\":[{\"type\":\"funcref\",\"value\":\"3\"}]},
       {\"type\":\"assert_return\",\"line\":4,
        \"action\":{\"type\":\"invoke\",\"field\":\"g\",\"args\":[]},
        \"expected\":[{\"type\":\"externref\",\"value\":\"5\"}]}]}"
  let assert [
    AssertReturn(
      1,
      Invoke("g", [ExternRefVal(7)], None),
      [NullRef(ExternRefTag)],
    ),
    AssertReturn(2, Invoke("g", [], None), [NullRef(FuncRefTag)]),
    AssertReturn(3, Invoke("g", [], None), [FuncRefVal(Some(3))]),
    AssertReturn(4, Invoke("g", [], None), [ExternRefVal(5)]),
  ] = parse(json).commands
}

/// Malformed JSON is a typed `Error`, never a panic.
pub fn malformed_json_test() {
  let assert Error(_) = fixture.parse(bit_array.from_string("{not json"))
}
