//// Validation tests for the WebAssembly GC proposal: the subtype relation
//// (concrete supertype chains + the abstract hierarchy) and the typing rules of
//// the GC instructions. Positive fixtures are produced by `wasm-tools` (and
//// independently validated by it); negative cases are hand-built bytes that
//// decode but must be rejected with a specific error.

import gleam/list
import gleeunit/should
import simplifile
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/validate

fn bytes(ints: List(Int)) -> BitArray {
  list.fold(ints, <<>>, fn(acc, b) { <<acc:bits, b:8>> })
}

fn load(name: String) -> ast.Module {
  let assert Ok(raw) =
    simplifile.read_bits("test/twocore/frontend/wasm/gc_fixtures/" <> name)
  let assert Ok(m) = decode.decode(raw)
  m
}

/// The `subtyping.wasm` fixture defines `$dog <: $animal` and passes a `(ref
/// $dog)` where a `(ref $animal)` is expected — plus struct/array/i31/ref.test.
/// It validates iff the subtype relation is implemented (exact equality would
/// reject the cross-type call).
pub fn gc_subtyping_validates_test() {
  validate.validate(load("subtyping.wasm"))
  |> should.be_ok
}

/// `struct.get $t $f` with a non-reference operand on the stack is a type error.
/// Module: type 0 = struct { i32 }, type 1 = func () -> i32; body pushes `i32`
/// then `struct.get 0 0` (which expects `(ref null 0)`).
pub fn gc_illtyped_struct_get_rejected_test() {
  let m =
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        // type section: struct {i32}, func () -> i32
        [0x01, 0x09, 0x02, 0x5F, 0x01, 0x7F, 0x00, 0x60, 0x00, 0x01, 0x7F],
        // func section: one func of type 1
        [0x03, 0x02, 0x01, 0x01],
        // code: i32.const 0; struct.get 0 0; end
        [0x0A, 0x0A, 0x01, 0x08, 0x00, 0x41, 0x00, 0xFB, 0x02, 0x00, 0x00, 0x0B],
      ]),
    )
  let assert Ok(decoded) = decode.decode(m)
  validate.validate(decoded)
  |> should.equal(Error(validate.TypeMismatch))
}

/// `struct.new $t` with too few field operands underflows the stack. Same types;
/// body is just `struct.new 0; end` with nothing on the stack (the struct needs
/// one `i32`), and the result type is wrong too — but the underflow is caught
/// first.
pub fn gc_struct_new_underflow_rejected_test() {
  let m =
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        // type 0 struct {i32}, type 1 func () -> (ref 0)
        [0x01, 0x0A, 0x02, 0x5F, 0x01, 0x7F, 0x00, 0x60, 0x00, 0x01, 0x64, 0x00],
        [0x03, 0x02, 0x01, 0x01],
        // code: struct.new 0; end   (no i32 operand on the stack)
        [0x0A, 0x07, 0x01, 0x05, 0x00, 0xFB, 0x00, 0x00, 0x0B],
      ]),
    )
  let assert Ok(decoded) = decode.decode(m)
  validate.validate(decoded)
  |> should.equal(Error(validate.Underflow))
}
