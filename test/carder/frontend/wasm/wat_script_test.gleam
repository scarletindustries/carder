//// Spec + DIFFERENTIAL tests for the `.wast` script parser (unit P5-10b —
//// `parse_script` + the src-side `Script`/`Command`/`Action`/`WastValue`/
//// `Expected`).
////
//// Two bars:
////  1. SPEC-cited structural tests — a representative slice of the real
////     reference-interpreter script grammar (`module`/`register`/`assert_return`
////     with a reference-value and a `nan:canonical` expected / `assert_trap` /
////     `assert_invalid` / `assert_malformed` / `invoke` / `get`), asserting the
////     produced `Script` structure; plus `(module binary …)` byte round-trip,
////     `(module quote …)` re-parse, malformed-script totality, and out-of-scope
////     categorisation.
////  2. DIFFERENTIAL — `parse_script(text)` command count + kind sequence equals
////     what `wast2json` emits (via `fixture.parse`) for the same script. Skips
////     (passes) when `wast2json` is absent.
////
//// Spec: the reference interpreter script grammar (WebAssembly/spec
//// `interpreter/README.md`, `test/core/`).

import carder/conformance/ffi
import carder/conformance/fixture
import carder/frontend/wasm/ast
import carder/frontend/wasm/decode
import carder/frontend/wasm/wat
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import simplifile

// ─────────────────── a representative multi-command script ───────────────────

const script_text: String = "
(module $m
  (func (export \"add\") (param i32 i32) (result i32)
    (local.get 0) (local.get 1) (i32.add))
  (func (export \"getnull\") (result funcref) (ref.null func))
  (func (export \"nanf\") (result f32) (f32.const nan))
  (global (export \"g\") i32 (i32.const 42))
  (memory (export \"mem\") 1))
(register \"M\" $m)
(assert_return (invoke \"add\" (i32.const 1) (i32.const 2)) (i32.const 3))
(assert_return (invoke \"getnull\") (ref.null func))
(assert_return (invoke \"nanf\") (f32.const nan:canonical))
(assert_return (get \"g\") (i32.const 42))
(assert_trap (invoke \"add\" (i32.const 0) (i32.const 0)) \"no trap\")
(assert_exhaustion (invoke \"add\" (i32.const 0) (i32.const 0)) \"call stack exhausted\")
(assert_invalid (module (func (result i32))) \"type mismatch\")
(assert_malformed (module quote \"(func\") \"unexpected end\")
(assert_unlinkable (module (import \"missing\" \"x\" (func))) \"unknown import\")
"

/// The full grammar slice parses to exactly the 11 commands, in order, with the
/// expected shapes.
pub fn parse_script_full_slice_test() {
  case wat.parse_script(script_text) {
    Ok([
      // (module $m …) — a named text module.
      wat.WatModule(Some("m"), wat.TextModule(_)),
      // (register "M" $m)
      wat.Register("M", Some("m")),
      // (assert_return (invoke "add" 1 2) (i32.const 3))
      wat.AssertReturn(
        wat.Invoke(None, "add", [wat.WastI32(1), wat.WastI32(2)]),
        [wat.ExpectedValue(wat.WastI32(3))],
      ),
      // (assert_return (invoke "getnull") (ref.null func)) — a reference expected.
      wat.AssertReturn(
        wat.Invoke(None, "getnull", []),
        [wat.ExpectedValue(wat.RefNullVal(ast.FuncRef))],
      ),
      // (assert_return (invoke "nanf") (f32.const nan:canonical)) — a NaN class.
      wat.AssertReturn(
        wat.Invoke(None, "nanf", []),
        [wat.ExpectedNanCanonical(32)],
      ),
      // (assert_return (get "g") (i32.const 42)) — a global read action.
      wat.AssertReturn(wat.Get(None, "g"), [wat.ExpectedValue(wat.WastI32(42))]),
      // (assert_trap (invoke "add" 0 0) "no trap")
      wat.AssertTrap(
        wat.Invoke(None, "add", [wat.WastI32(0), wat.WastI32(0)]),
        "no trap",
      ),
      // (assert_exhaustion (invoke "add" 0 0) "call stack exhausted")
      wat.AssertExhaustion(wat.Invoke(None, "add", _), "call stack exhausted"),
      // (assert_invalid (module (func (result i32))) "type mismatch") — parses,
      // fails validate (not parse) → a TextModule is carried.
      wat.AssertInvalid(wat.TextModule(_), "type mismatch"),
      // (assert_malformed (module quote "(func") "unexpected end")
      wat.AssertMalformed(wat.QuoteModule("(func"), "unexpected end"),
      // (assert_unlinkable (module (import …)) "unknown import")
      wat.AssertUnlinkable(wat.TextModule(_), "unknown import"),
    ]) -> Nil
    other -> should.equal(string.inspect(other), "the 11-command script")
  }
}

// ─────────────────── (module binary …) byte round-trip ───────────────────

pub fn module_binary_roundtrips_bytes_test() {
  // The 8-byte empty-module header `\00asm\01\00\00\00`.
  let src = "(module binary \"\\00asm\\01\\00\\00\\00\")"
  case wat.parse_script(src) {
    Ok([wat.WatModule(None, wat.BinaryModule(bytes))]) -> {
      bytes
      |> should.equal(<<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>)
      // The carried bytes decode to a real (empty) module — the runner's path.
      let _ = decode.decode(bytes) |> should.be_ok
      Nil
    }
    other ->
      should.equal(string.inspect(other), "Ok([WatModule(BinaryModule)])")
  }
}

pub fn module_binary_concatenates_literals_test() {
  // Multiple binary string literals concatenate into one byte vector.
  let src = "(module binary \"\\00asm\" \"\\01\\00\\00\\00\")"
  case wat.parse_script(src) {
    Ok([wat.WatModule(None, wat.BinaryModule(bytes))]) ->
      bytes
      |> should.equal(<<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>)
    other -> should.equal(string.inspect(other), "one concatenated binary")
  }
}

// ─────────────────── (module quote …) re-parse ───────────────────

pub fn module_quote_reparses_test() {
  let src = "(module quote \"(module (func (export \\\"f\\\")))\")"
  case wat.parse_script(src) {
    Ok([wat.WatModule(None, wat.QuoteModule(quoted))]) -> {
      quoted |> should.equal("(module (func (export \"f\")))")
      // The quoted text is real WAT — it re-parses to a module.
      let _ = wat.parse_module(quoted) |> should.be_ok
      Nil
    }
    other -> should.equal(string.inspect(other), "Ok([WatModule(QuoteModule)])")
  }
}

// ─────────────────── reference & NaN values (R18) ───────────────────

pub fn ref_extern_value_test() {
  // (ref.extern N) is host-constructible → RefExternVal(N).
  let src = "(assert_return (invoke \"f\" (ref.extern 3)) (ref.extern 4))"
  case wat.parse_script(src) {
    Ok([
      wat.AssertReturn(
        wat.Invoke(None, "f", [wat.RefExternVal(3)]),
        [wat.ExpectedValue(wat.RefExternVal(4))],
      ),
    ]) -> Nil
    other -> should.equal(string.inspect(other), "RefExternVal args/expected")
  }
}

pub fn ref_func_and_null_values_test() {
  let src =
    "(assert_return (invoke \"f\" (ref.null extern) (ref.func 0)) (ref.func))"
  case wat.parse_script(src) {
    Ok([
      wat.AssertReturn(
        wat.Invoke(None, "f", [wat.RefNullVal(ast.ExternRef), wat.RefFuncVal]),
        [wat.ExpectedValue(wat.RefFuncVal)],
      ),
    ]) -> Nil
    other -> should.equal(string.inspect(other), "ref.func/ref.null values")
  }
}

pub fn nan_arithmetic_f64_test() {
  let src = "(assert_return (invoke \"f\") (f64.const nan:arithmetic))"
  case wat.parse_script(src) {
    Ok([wat.AssertReturn(_, [wat.ExpectedNanArithmetic(64)])]) -> Nil
    other -> should.equal(string.inspect(other), "ExpectedNanArithmetic(64)")
  }
}

pub fn concrete_nan_payload_is_exact_bits_test() {
  // A concrete `nan:0x…` expected keeps its RAW bits (distinct from a NaN class).
  let src = "(assert_return (invoke \"f\") (f32.const nan:0x200000))"
  case wat.parse_script(src) {
    Ok([wat.AssertReturn(_, [wat.ExpectedValue(wat.WastF32(0x7FA0_0000))])]) ->
      Nil
    other -> should.equal(string.inspect(other), "exact nan payload bits")
  }
}

// ─────────────────── bare actions / register variants ───────────────────

pub fn bare_action_test() {
  let src = "(invoke \"run\" (i32.const 7))"
  case wat.parse_script(src) {
    Ok([wat.ActionCmd(wat.Invoke(None, "run", [wat.WastI32(7)]))]) -> Nil
    other -> should.equal(string.inspect(other), "ActionCmd(Invoke)")
  }
}

pub fn register_current_module_test() {
  // (register "name") with no module → the current module (None).
  case wat.parse_script("(register \"host\")") {
    Ok([wat.Register("host", None)]) -> Nil
    other -> should.equal(string.inspect(other), "Register(host, None)")
  }
}

pub fn invoke_named_module_test() {
  // A cross-module invoke names the target by its script `$id`.
  case wat.parse_script("(invoke $other \"f\")") {
    Ok([wat.ActionCmd(wat.Invoke(Some("other"), "f", []))]) -> Nil
    other -> should.equal(string.inspect(other), "Invoke(Some(other))")
  }
}

// ─────────────────── out-of-scope / unknown commands ───────────────────

pub fn unknown_command_is_categorized_test() {
  // A non-modelled command head is a categorized skip, never dropped/panicked.
  case wat.parse_script("(assert_return_canonical_nan (invoke \"f\"))") {
    Ok([wat.CmdSkipped("assert_return_canonical_nan")]) -> Nil
    other -> should.equal(string.inspect(other), "CmdSkipped(...)")
  }
}

// ─────────────────── assert_malformed (module binary …) routes to decode ─────

pub fn assert_malformed_binary_carries_bytes_test() {
  // The suite injects malformed binaries through `(module binary …)`; the parser
  // carries the bytes for the runner to feed `decode` (which rejects them).
  let src = "(assert_malformed (module binary \"\\00asm\") \"unexpected end\")"
  case wat.parse_script(src) {
    Ok([wat.AssertMalformed(wat.BinaryModule(bytes), "unexpected end")]) -> {
      bytes |> should.equal(<<0x00, 0x61, 0x73, 0x6D>>)
      let _ = decode.decode(bytes) |> should.be_error
      Nil
    }
    other ->
      should.equal(string.inspect(other), "AssertMalformed(BinaryModule)")
  }
}

// ─────────────────── totality (D4): malformed script → typed error ───────────

pub fn malformed_script_no_panic_test() {
  let bad = [
    "(", ")", "(module", "(assert_return", "(assert_return (invoke))",
    "(register)", "(invoke)", "(get)", "(assert_trap (invoke \"f\"))",
    "(assert_invalid)", "(module quote",
    "(assert_return (invoke \"f\" (i32.const)))",
    "(assert_return (invoke \"f\") (i32.const 99999999999999999999))",
  ]
  list.each(bad, fn(t) {
    case wat.parse_script(t) {
      Ok(_) -> Nil
      Error(_) -> Nil
    }
  })
}

/// Truncation fuzz (D4): every prefix of the representative script must parse to
/// `Ok | Error(WatError)` — never a panic.
pub fn script_truncation_fuzz_test() {
  let n = string.length(script_text)
  list.each(int_range(0, n), fn(k) {
    let _ = wat.parse_script(string.slice(script_text, 0, k))
    Nil
  })
}

fn int_range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..int_range(from + 1, to)]
  }
}

// ─────────────────── differential vs wast2json (count + kinds) ───────────────

/// Run `wast2json` on `text` and return the fixture command list, or an error
/// reason (absent tool → skip).
fn wast2json_commands(text: String) -> Result(List(fixture.Command), String) {
  case ffi.find_executable("wast2json") {
    Error(_) -> Error("wast2json not found")
    Ok(exe) -> {
      let base = "/tmp/carder_wast_" <> int.to_string(ffi.unique_int())
      let wastp = base <> ".wast"
      let jsonp = base <> ".json"
      case simplifile.write(wastp, text) {
        Error(_) -> Error("cannot write temp wast")
        Ok(_) -> {
          let #(code, out) =
            ffi.run(exe, [
              wastp,
              "--enable-multi-memory",
              "--enable-memory64",
              "-o",
              jsonp,
            ])
          case code {
            0 ->
              case fixture.load(jsonp) {
                Ok(f) -> Ok(f.commands)
                Error(e) -> Error("fixture load: " <> e)
              }
            _ -> Error("wast2json failed: " <> out)
          }
        }
      }
    }
  }
}

/// A coarse command KIND tag for a `wat.Command` (our parser's output).
fn wat_kind(cmd: wat.Command) -> String {
  case cmd {
    wat.WatModule(_, _) -> "module"
    wat.Register(_, _) -> "register"
    wat.AssertReturn(_, _) -> "assert_return"
    wat.AssertTrap(_, _) -> "assert_trap"
    wat.AssertExhaustion(_, _) -> "assert_exhaustion"
    wat.AssertInvalid(_, _) -> "assert_invalid"
    wat.AssertMalformed(_, _) -> "assert_malformed"
    wat.AssertUnlinkable(_, _) -> "assert_unlinkable"
    wat.AssertUninstantiable(_, _) -> "assert_uninstantiable"
    wat.ActionCmd(_) -> "action"
    wat.CmdSkipped(kind) -> kind
  }
}

/// The matching KIND tag for a `fixture.Command` (wast2json's output). `Unhandled`
/// carries the raw wast2json `type`, so an `assert_exhaustion`/`assert_unlinkable`
/// tag is exactly the string our parser produces.
fn fixture_kind(cmd: fixture.Command) -> String {
  case cmd {
    fixture.ModuleCmd(_, _, _) -> "module"
    fixture.Register(_, _, _) -> "register"
    fixture.AssertReturn(_, _, _) -> "assert_return"
    fixture.AssertTrap(_, _, _) -> "assert_trap"
    fixture.AssertException(_, _, _) -> "assert_exception"
    fixture.AssertInvalid(_, _, _, _) -> "assert_invalid"
    fixture.AssertMalformed(_, _, _, _) -> "assert_malformed"
    fixture.AssertUninstantiable(_, _, _) -> "assert_uninstantiable"
    fixture.AssertUnlinkable(_, _, _) -> "assert_unlinkable"
    fixture.ActionCmd(_, _) -> "action"
    fixture.Unhandled(_, kind) -> kind
  }
}

/// `parse_script` must produce the SAME command count and kind sequence
/// `wast2json` does for the representative script. Skips if wast2json is absent.
pub fn differential_command_count_and_kinds_test() {
  case wast2json_commands(script_text) {
    Error("wast2json not found") -> Nil
    Error(reason) -> should.equal("wast2json: " <> reason, "ok")
    Ok(fixture_cmds) ->
      case wat.parse_script(script_text) {
        Error(e) ->
          should.equal("parse_script error: " <> string.inspect(e), "Ok")
        Ok(mine) -> {
          // Same number of commands.
          list.length(mine) |> should.equal(list.length(fixture_cmds))
          // Same kind sequence.
          list.map(mine, wat_kind)
          |> should.equal(list.map(fixture_cmds, fixture_kind))
        }
      }
  }
}
