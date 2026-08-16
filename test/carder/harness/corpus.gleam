//// The Phase-1 acceptance-corpus expectation format (`corpus/*.expected`).
////
//// Each corpus program is a checked-in `test/carder/ir/corpus/<name>.ir` (carder's own IR text —
//// the backend's entry language) paired with a `<name>.expected` file whose every numeric-edge
//// value is SOURCED FROM THE SPEC (the vendored `.wast` files) or cross-checked via wasmtime —
//// the source is cited in `#` comments inside each `.expected`. This module parses that
//// format into typed `Expect`s; the driving + comparison live in the tier/optimize suites.
////
//// The `.expected` format is deliberately FRONTEND-INDEPENDENT: it names an export and raw
//// bit-pattern arguments/results plus spec trap phrases, never anything about the source
//// language. That is why these oracles were carried over verbatim when the WebAssembly frontend
//// was extracted and the corpus was rebased from `<name>.wasm` onto `<name>.ir`.
////
//// Grammar (one statement per non-blank, non-`#` line):
////
////     invoke <field> <value>* => return <value>*     ; expect those results
////     invoke <field> <value>* => trap <text…>        ; expect a trap whose spec
////                                                       message contains <text>
////     reject                                         ; the module must NOT compile to
////                                                       a runnable instance (fail-closed)
////     instantiate => trap <text…>                    ; INSTANTIATING the module must trap
////                                                       (OOB active segment / trapping
////                                                       start) with a spec message
////                                                       containing <text> (E5)
////
//// A `<value>` is `<ty>:<n>` where `<ty>` ∈ {i32,i64,f32,f64} and `<n>` is the RAW
//// UNSIGNED bit pattern in decimal (floats included — D5), or `<ty>:nan:canonical` /
//// `<ty>:nan:arithmetic` for a NaN expectation.

import carder/harness/fixture.{
  type SpecValue, Arithmetic, Canonical, F32Bits, F32Nan, F64Bits, F64Nan,
  I32Val, I64Val,
}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// One corpus expectation.
///
/// - `Returns(field, args, results)`: invoking `field` with `args` must return values
///   matching `results` (compared by the oracle).
/// - `Traps(field, args, text)`: invoking `field` with `args` must trap with a spec
///   message containing `text`.
/// - `Rejects`: the program's module must FAIL to compile to a runnable instance
///   (fail-closed at BUILD time — a `parse .ir:` / `link:` / `emit:` rejection).
/// - `InstantiateTraps(text)`: the module compiles, but INSTANTIATING it must trap (an OOB
///   active data/element segment, or a trapping `start`) with a spec message containing
///   `text` (a RUNTIME instantiation-time trap, distinct from `Rejects`).
pub type Expect {
  Returns(field: String, args: List(SpecValue), results: List(SpecValue))
  Traps(field: String, args: List(SpecValue), text: String)
  Rejects
  InstantiateTraps(text: String)
}

/// Parse the textual `.expected` content into a list of `Expect`s (in file order).
/// Returns `Error(reason)` on a malformed line. Total — never panics.
pub fn parse(text: String) -> Result(List(Expect), String) {
  text
  |> string.split("\n")
  |> list.map(strip_comment)
  |> list.map(string.trim)
  |> list.filter(fn(l) { l != "" })
  |> list.try_map(parse_line)
}

/// Drop an inline `# …` comment (everything from the first `#`). WASM trap phrases and raw
/// bit-pattern values never contain `#`, so this is unambiguous; it lets `.expected` files
/// annotate individual lines inline (e.g. `… => return i32:3   # 3.5 → 3`).
fn strip_comment(line: String) -> String {
  case string.split_once(line, "#") {
    Ok(#(before, _)) -> before
    Error(_) -> line
  }
}

fn parse_line(line: String) -> Result(Expect, String) {
  case line {
    "reject" -> Ok(Rejects)
    _ ->
      case string.starts_with(line, "invoke ") {
        True -> parse_invoke(line)
        False ->
          case string.starts_with(line, "instantiate") {
            True -> parse_instantiate(line)
            False -> Error("unrecognised statement: " <> line)
          }
      }
  }
}

/// Parse `instantiate => trap <text…>` into `InstantiateTraps(text)`.
fn parse_instantiate(line: String) -> Result(Expect, String) {
  use #(_left, right) <- result.try(
    string.split_once(line, " => ")
    |> result.replace_error("missing ' => ' in: " <> line),
  )
  case string.starts_with(right, "trap ") {
    True -> Ok(InstantiateTraps(string.trim(string.drop_start(right, 5))))
    False ->
      Error("expected 'trap <text>' after 'instantiate =>', got: " <> right)
  }
}

fn parse_invoke(line: String) -> Result(Expect, String) {
  use #(left, right) <- result.try(
    string.split_once(line, " => ")
    |> result.replace_error("missing ' => ' in: " <> line),
  )
  let left_toks = tokens(left)
  case left_toks {
    ["invoke", field, ..arg_toks] -> {
      use args <- result.try(list.try_map(arg_toks, parse_value))
      parse_rhs(field, args, right)
    }
    _ -> Error("malformed invoke (need a field): " <> line)
  }
}

fn parse_rhs(
  field: String,
  args: List(SpecValue),
  right: String,
) -> Result(Expect, String) {
  case string.starts_with(right, "return") {
    True -> {
      let res_toks = list.drop(tokens(right), 1)
      use results <- result.try(list.try_map(res_toks, parse_value))
      Ok(Returns(field, args, results))
    }
    False ->
      case string.starts_with(right, "trap ") {
        True -> Ok(Traps(field, args, string.trim(string.drop_start(right, 5))))
        False -> Error("expected 'return' or 'trap' after =>, got: " <> right)
      }
  }
}

fn tokens(s: String) -> List(String) {
  s
  |> string.split(" ")
  |> list.filter(fn(t) { t != "" })
}

/// Parse a `<ty>:<n>` (or `<ty>:nan:<kind>`) token into a `SpecValue`.
fn parse_value(tok: String) -> Result(SpecValue, String) {
  use #(ty, rest) <- result.try(
    string.split_once(tok, ":")
    |> result.replace_error("value needs a type prefix: " <> tok),
  )
  case ty {
    "i32" -> result.map(parse_int(rest), I32Val)
    "i64" -> result.map(parse_int(rest), I64Val)
    "f32" ->
      case nan(rest) {
        Ok(k) -> Ok(F32Nan(k))
        Error(_) -> result.map(parse_int(rest), F32Bits)
      }
    "f64" ->
      case nan(rest) {
        Ok(k) -> Ok(F64Nan(k))
        Error(_) -> result.map(parse_int(rest), F64Bits)
      }
    _ -> Error("unknown value type: " <> ty)
  }
}

fn nan(rest: String) {
  case rest {
    "nan:canonical" -> Ok(Canonical)
    "nan:arithmetic" -> Ok(Arithmetic)
    _ -> Error(Nil)
  }
}

fn parse_int(s: String) -> Result(Int, String) {
  int.parse(s) |> result.replace_error("not an integer: " <> s)
}
