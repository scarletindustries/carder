//// Ingest tests for the WebAssembly tail-call proposal (unit Q13-02): the two
//// front-door paths that PRODUCE `ast.ReturnCall` / `ast.ReturnCallIndirect`.
////
//// Assertions target the proposal's BINARY + TEXT grammar, not whatever the
//// implementation happens to emit (no change-detectors):
////  - proposal:      https://github.com/WebAssembly/tail-call/blob/main/proposals/tail-call/Overview.md
////  - binary format: `return_call` = 0x12 + one u32 funcidx (identical to `call`
////    0x10); `return_call_indirect` = 0x13 + a u32 typeidx THEN a u32 tableidx
////    (identical to `call_indirect` 0x11).
////  - text format:   `return_call $f` / `return_call_indirect $tbl? (type $ft)`
////    share the exact index / typeuse resolution of `call` / `call_indirect`.
////
//// Scope is SYNTAX ONLY. The typing rule (callee results == current function's
//// results) is Q13-03's `assert_invalid` surface and is deliberately NOT tested
//// here — every syntactically well-formed `return_call*` is accepted regardless
//// of types.
////
//// Byte fixtures are embedded so the suite needs no external tool at run time;
//// each carries its assembling WAT in a comment for provenance (produced once via
//// `wat2wasm --enable-tail-call`, wabt 1.0.41). The `diff_tail` equivalence tests
//// (WAT-source == decoded-bytes) additionally re-assemble at run time and SKIP
//// deterministically when `wat2wasm` is absent or lacks the tail-call feature.

import carder/conformance/ffi
import carder/frontend/wasm/ast
import carder/frontend/wasm/decode
import carder/frontend/wasm/wat
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import simplifile

// ─────────────────────────── embedded byte fixtures ───────────────────────────

// return_call. Assembled from:
//   (module
//     (func $a (result i32) (i32.const 42))
//     (func (export "main") (result i32) (return_call $a)))
// The load-bearing bytes are `0x12, 0x00` = `return_call 0` in func 1's body.
const rc_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7F, 0x03, 0x03, 0x02, 0x00, 0x00, 0x07, 0x08, 0x01, 0x04, 0x6D, 0x61,
  0x69, 0x6E, 0x00, 0x01, 0x0A, 0x0B, 0x02, 0x04, 0x00, 0x41, 0x2A, 0x0B, 0x04,
  0x00, 0x12, 0x00, 0x0B,
>>

// return_call_indirect with typeidx (1) ≠ tableidx (0) — the anti-swap fixture.
// Assembled from:
//   (module
//     (type $t0 (func (param i32 i32) (result i32)))   ;; type 0
//     (type $t1 (func (result i32)))                    ;; type 1
//     (table 1 funcref)
//     (func $f (type $t1) (i32.const 7))
//     (elem (i32.const 0) $f)
//     (func (export "main") (type $t1)
//       (i32.const 0)
//       (return_call_indirect (type $t1))))
// The load-bearing bytes are `0x13, 0x01, 0x00` = `return_call_indirect` with
// typeidx 1 THEN tableidx 0 in func 1's body.
const rci_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0B, 0x02, 0x60, 0x02,
  0x7F, 0x7F, 0x01, 0x7F, 0x60, 0x00, 0x01, 0x7F, 0x03, 0x03, 0x02, 0x01, 0x01,
  0x04, 0x04, 0x01, 0x70, 0x00, 0x01, 0x07, 0x08, 0x01, 0x04, 0x6D, 0x61, 0x69,
  0x6E, 0x00, 0x01, 0x09, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0B, 0x01, 0x00, 0x0A,
  0x0E, 0x02, 0x04, 0x00, 0x41, 0x07, 0x0B, 0x07, 0x00, 0x41, 0x00, 0x13, 0x01,
  0x00, 0x0B,
>>

// A one-function `(module (func))` whose body is a bare `0x12` (return_call
// opcode) with NO funcidx bytes: type 0 `(func)`, funcsec [type 0], codesec with
// body_size 2 = `00 12` (locals=0, 0x12, EOF). Decode must reach the missing
// funcidx read (idx_instr → decode_u_n on empty) → Truncated.
const rc_truncated: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x0A, 0x04, 0x01, 0x02, 0x00, 0x12,
>>

// Like `rc_truncated` but a `return_call_indirect` whose typeidx is present and
// tableidx is missing: body_size 5 = `00 41 00 13 00` (locals=0, i32.const 0,
// 0x13, typeidx 0x00, EOF). Decode reads the typeidx then hits EOF on the SECOND
// immediate (the tableidx) → Truncated. Table section makes the module framing
// well-formed so decode reaches the body.
const rci_truncated: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00, 0x01, 0x0A, 0x07,
  0x01, 0x05, 0x00, 0x41, 0x00, 0x13, 0x00,
>>

// ─────────────────────────── binary decode: return_call ───────────────────────

/// 0x12 decodes to `ast.ReturnCall(funcidx)` with the funcidx read from the one
/// u32 immediate (identical to `call`). Func 1's body is exactly the tail-call
/// followed by the function `End`.
pub fn decode_return_call_test() {
  let assert Ok(m) = decode.decode(rc_wasm)
  let assert [_callee, caller] = m.funcs
  caller.body
  |> should.equal([ast.ReturnCall(0), ast.End])
}

/// Regression guard: pre-Q13, 0x12 fell through to `Error(ast.UnknownOpcode(18))`.
/// The additive arm must now make the whole module decode `Ok`; asserting on `Ok`
/// specifically means dropping the arm fails loudly.
pub fn decode_return_call_not_unknown_opcode_test() {
  decode.decode(rc_wasm)
  |> should.be_ok
}

// ────────────────────── binary decode: return_call_indirect ───────────────────

/// 0x13 decodes to `ast.ReturnCallIndirect(type_idx, table)` reading the typeidx
/// BEFORE the tableidx. The fixture uses type index 1 and table 0 so a field swap
/// (table before type) would surface as `type_idx == 0 && table == 1` and fail —
/// this locks the immediate order against a regression.
pub fn decode_return_call_indirect_antiswap_test() {
  let assert Ok(m) = decode.decode(rci_wasm)
  let assert [_callee, caller] = m.funcs
  // Body: the i32 index operand, the tail-call, then the function End.
  let assert [ast.I32Const(0), tail, ast.End] = caller.body
  tail
  |> should.equal(ast.ReturnCallIndirect(type_idx: 1, table: 0))
}

// ───────────────────────── binary decode: fail-closed ─────────────────────────

/// A `0x12` with no following funcidx bytes is `Error(ast.Truncated)` — never a
/// silent success (the immediate is read via `idx_instr` → `decode_u_n`).
pub fn decode_return_call_truncated_test() {
  decode.decode(rc_truncated)
  |> should.equal(Error(ast.Truncated))
}

/// A `0x13` with a typeidx but a missing tableidx is `Error(ast.Truncated)` —
/// proving the SECOND immediate is genuinely required (the two-read anti-swap
/// path, not the single-read `idx_instr`).
pub fn decode_return_call_indirect_truncated_test() {
  decode.decode(rci_truncated)
  |> should.equal(Error(ast.Truncated))
}

// ─────────────────────────────── WAT parse ────────────────────────────────────

/// `return_call $f` parses like `call`: the symbolic `$a` resolves to funcidx 0
/// via the func name-map, producing `ast.ReturnCall(0)` in the caller's body.
pub fn wat_return_call_test() {
  let assert Ok(m) =
    wat.parse_module("(module (func $a) (func (return_call $a)))")
  let assert [_callee, caller] = m.funcs
  list.contains(caller.body, ast.ReturnCall(0))
  |> should.be_true
}

// A module exercising both the default-table and explicit-table forms of
// return_call_indirect. `$ft` is the FIRST declared type (index 0); `$tbl` is the
// SECOND table (index 1). The anonymous callers get an inferred empty type, but
// the `(type $ft)` typeuse resolves to the declared $ft = 0 in both.
const rci_wat: String = "(module
  (type $ft (func (param i32) (result i32)))
  (table 2 funcref)
  (table $tbl 2 funcref)
  (func $f (type $ft) (local.get 0))
  (elem (i32.const 0) $f)
  (func (i32.const 0) (i32.const 0) (return_call_indirect (type $ft)))
  (func (i32.const 0) (i32.const 0) (return_call_indirect $tbl (type $ft))))"

/// `return_call_indirect` shares `call_indirect`'s optional-`tableidx?` + typeuse
/// grammar: the default form resolves to table 0; the explicit `$tbl` form
/// resolves the named table (here index 1), proving the same optional-table
/// machinery backs both mnemonics.
pub fn wat_return_call_indirect_test() {
  let assert Ok(m) = wat.parse_module(rci_wat)
  let assert [_f, default_tbl, explicit_tbl] = m.funcs
  // Default (no table id) → table 0; the `(type $ft)` typeuse → type 0.
  list.contains(default_tbl.body, ast.ReturnCallIndirect(type_idx: 0, table: 0))
  |> should.be_true
  // Explicit `$tbl` → table 1 (the resolved name), type unchanged.
  list.contains(
    explicit_tbl.body,
    ast.ReturnCallIndirect(type_idx: 0, table: 1),
  )
  |> should.be_true
}

// ─────────────────────────── WAT parse: fail-closed ───────────────────────────

/// `(return_call)` with no operand is `Error(UnexpectedEof(_))` from `one_idx`.
pub fn wat_return_call_missing_operand_test() {
  case wat.parse_module("(module (func (return_call)))") {
    Error(wat.UnexpectedEof(_)) -> Nil
    other -> should.equal(string.inspect(other), "UnexpectedEof(_)")
  }
}

/// `return_call $nope` referencing an undefined func id is an unresolved-reference
/// error (`UnboundIdentifier` in the `func` space).
pub fn wat_return_call_unbound_func_test() {
  case wat.parse_module("(module (func (return_call $nope)))") {
    Error(wat.UnboundIdentifier(_, "func", "nope")) -> Nil
    other ->
      should.equal(string.inspect(other), "UnboundIdentifier(func, nope)")
  }
}

/// `return_call_indirect $undef (type $ft)` with an undefined table id is an
/// unresolved-reference error in the `table` space — same shared resolution as
/// `call_indirect`.
pub fn wat_return_call_indirect_unbound_table_test() {
  case
    wat.parse_module(
      "(module (type $ft (func)) (func (i32.const 0) (return_call_indirect $undef (type $ft))))",
    )
  {
    Error(wat.UnboundIdentifier(_, "table", "undef")) -> Nil
    other ->
      should.equal(string.inspect(other), "UnboundIdentifier(table, undef)")
  }
}

/// Scope guard (Q8): `return_call_ref` — a typed-refs tail-call neighbour that is
/// OUT OF SCOPE this phase — must still route to `unsupported_or_unknown`
/// (`UnknownMnemonic`/`Unsupported`). The two additive arms did not swallow it.
pub fn wat_return_call_ref_still_unknown_test() {
  case wat.parse_module("(module (func (return_call_ref $ft)))") {
    Error(wat.UnknownMnemonic(_, "return_call_ref")) -> Nil
    Error(wat.Unsupported(_, _, _)) -> Nil
    other ->
      should.equal(string.inspect(other), "UnknownMnemonic(return_call_ref)")
  }
}

// ────────────────────── WAT ↔ binary equivalence (skip-able) ───────────────────

/// Assemble `text` with `wat2wasm --enable-tail-call` and assert
/// `decode.decode(bytes) == wat.parse_module(text)` (structural AST equality — the
/// same contract as `wat_test.gleam`'s `diff`). Returns `Nil` (pass) when
/// `wat2wasm` is ABSENT, when a temp write/read fails, or when the assemble fails
/// with a reason mentioning the tail-call feature (older wabt without the flag) —
/// so CI stays deterministic on toolchains lacking tail-call support. Any OTHER
/// assemble failure fails loudly (a genuinely-malformed fixture).
fn diff_tail(text: String) -> Nil {
  case ffi.find_executable("wat2wasm") {
    Error(_) -> Nil
    Ok(exe) -> {
      let base = "/tmp/carder_tailcall_" <> int.to_string(ffi.unique_int())
      let watp = base <> ".wat"
      let wasmp = base <> ".wasm"
      case simplifile.write(watp, text) {
        Error(_) -> Nil
        Ok(_) -> {
          let #(code, out) =
            ffi.run(exe, [watp, "--enable-tail-call", "-o", wasmp])
          case code {
            0 ->
              case simplifile.read_bits(wasmp) {
                Error(_) -> Nil
                Ok(bytes) ->
                  case decode.decode(bytes), wat.parse_module(text) {
                    Ok(dec), Ok(parsed) -> should.equal(parsed, dec)
                    Ok(_), Error(e) ->
                      should.equal(
                        "parse error: " <> string.inspect(e),
                        "Ok(module)",
                      )
                    Error(e), _ ->
                      should.equal(
                        "decode error: " <> string.inspect(e),
                        "Ok(module)",
                      )
                  }
              }
            // Non-zero: skip if the build doesn't know the tail-call feature;
            // otherwise the fixture is wrong → fail loudly.
            _ ->
              case string.contains(out, "tail") {
                True -> Nil
                False -> should.equal("assemble failed: " <> out, "assembled")
              }
          }
        }
      }
    }
  }
}

/// The same `return_call` text assembled and decoded must equal the parsed AST.
pub fn wat_binary_equivalence_return_call_test() {
  diff_tail(
    "(module
       (func $a (result i32) (i32.const 42))
       (func (export \"main\") (result i32) (return_call $a)))",
  )
}

/// The same `return_call_indirect` text assembled and decoded must equal the
/// parsed AST — the shared typeuse/table path can't diverge between text and
/// bytes.
pub fn wat_binary_equivalence_return_call_indirect_test() {
  diff_tail(
    "(module
       (type $ft (func (result i32)))
       (table 1 funcref)
       (func $f (type $ft) (i32.const 7))
       (elem (i32.const 0) $f)
       (func (export \"main\") (type $ft)
         (i32.const 0)
         (return_call_indirect (type $ft))))",
  )
}
