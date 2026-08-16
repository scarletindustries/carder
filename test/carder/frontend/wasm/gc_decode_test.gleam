//// Decoder tests for the WebAssembly **GC proposal** — the type section (struct/
//// array/func composite types, rec groups, sub types), the general `(ref null?
//// ht)` value types, and the `0xFB`-prefixed GC instructions. Bytes are
//// hand-constructed against the spec binary format so the decoder is exercised
//// directly (independent of any external assembler).

import carder/frontend/wasm/ast
import carder/frontend/wasm/decode
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

fn bytes(ints: List(Int)) -> BitArray {
  list.fold(ints, <<>>, fn(acc, b) { <<acc:bits, b:8>> })
}

const header = [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

/// A struct, an array (packed `i8`), and a func type — three singleton defined
/// types, decoded from the unified type section.
pub fn gc_type_section_test() {
  let assert Ok(m) =
    decode.decode(
      bytes(
        list.flatten([
          header,
          // type section (id 1), size 16
          [0x01, 0x10],
          [0x03],
          // struct { mut i32, i32 }
          [0x5F, 0x02, 0x7F, 0x01, 0x7F, 0x00],
          // array (mut i8)
          [0x5E, 0x78, 0x01],
          // func (ref 0) -> i32
          [0x60, 0x01, 0x64, 0x00, 0x01, 0x7F],
        ]),
      ),
    )
  m.types
  |> should.equal([
    ast.DefType(
      ast.CtStruct([
        ast.FieldType(ast.StVal(ast.I32), True),
        ast.FieldType(ast.StVal(ast.I32), False),
      ]),
      None,
      True,
    ),
    ast.DefType(ast.CtArray(ast.FieldType(ast.StI8, True)), None, True),
    ast.DefType(
      ast.CtFunc(
        ast.FuncType([ast.Ref(ast.RefType(False, ast.HConcrete(0)))], [ast.I32]),
      ),
      None,
      True,
    ),
  ])
}

/// A rec group of two mutually-referential struct types, and a final sub type
/// that extends type 0.
pub fn gc_rec_group_and_subtype_test() {
  let assert Ok(m) =
    decode.decode(
      bytes(
        list.flatten([
          header,
          [0x01, 0x17],
          // two rec-type elements (a rec group of 2 + a subtype) → 3 defined types
          [0x02],
          // rec group of 2:  0x4E count=2
          [0x4E, 0x02],
          //   type 0: struct { (ref null 1) }
          [0x5F, 0x01, 0x63, 0x01, 0x00],
          //   type 1: struct { (ref null 0) }
          [0x5F, 0x01, 0x63, 0x00, 0x00],
          // type 2: sub final, supertype [0], struct { (ref null 1), i32 }
          [0x4F, 0x01, 0x00, 0x5F, 0x02, 0x63, 0x01, 0x00, 0x7F, 0x00],
        ]),
      ),
    )
  m.types
  |> should.equal([
    ast.DefType(
      ast.CtStruct([
        ast.FieldType(
          ast.StVal(ast.Ref(ast.RefType(True, ast.HConcrete(1)))),
          False,
        ),
      ]),
      None,
      True,
    ),
    ast.DefType(
      ast.CtStruct([
        ast.FieldType(
          ast.StVal(ast.Ref(ast.RefType(True, ast.HConcrete(0)))),
          False,
        ),
      ]),
      None,
      True,
    ),
    ast.DefType(
      ast.CtStruct([
        ast.FieldType(
          ast.StVal(ast.Ref(ast.RefType(True, ast.HConcrete(1)))),
          False,
        ),
        ast.FieldType(ast.StVal(ast.I32), False),
      ]),
      Some(0),
      True,
    ),
  ])
}

/// The abstract heap-type shorthands and the general `(ref null? ht)` forms all
/// decode as value types.
pub fn gc_abstract_reftypes_test() {
  // A func type () -> (anyref, eqref, i31ref, structref, arrayref, nullref,
  //                    (ref any), (ref null 0))
  let assert Ok(m) =
    decode.decode(
      bytes(
        list.flatten([
          header,
          [0x01, 0x0E],
          [0x01],
          [0x60, 0x00, 0x08],
          [0x6E, 0x6D, 0x6C, 0x6B, 0x6A, 0x71],
          [0x64, 0x6E],
          [0x63, 0x00],
        ]),
      ),
    )
  let assert [ast.DefType(ast.CtFunc(ast.FuncType([], results)), _, _)] =
    m.types
  results
  |> should.equal([
    ast.Ref(ast.RefType(True, ast.HAny)),
    ast.Ref(ast.RefType(True, ast.HEq)),
    ast.Ref(ast.RefType(True, ast.HI31)),
    ast.Ref(ast.RefType(True, ast.HStruct)),
    ast.Ref(ast.RefType(True, ast.HArray)),
    ast.Ref(ast.RefType(True, ast.HNone)),
    ast.Ref(ast.RefType(False, ast.HAny)),
    ast.Ref(ast.RefType(True, ast.HConcrete(0))),
  ])
}

/// The `0xFB`-prefixed GC instructions decode with their immediates. Body:
/// `struct.new 0; struct.get 0 0; ref.i31; ref.test (ref 0); array.len;
/// ref.cast (ref null 0); br_on_cast 0 (ref null 0)->(ref 0)`.
pub fn gc_instructions_test() {
  let assert Ok(m) =
    decode.decode(
      bytes(
        list.flatten([
          header,
          // type section: one func () -> ()
          [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
          // func section: one func of type 0
          [0x03, 0x02, 0x01, 0x00],
          // code section
          [0x0A],
          // size, then: locals=0, body, end
          code_section(
            list.flatten([
              [0xFB, 0x00, 0x00],
              // struct.new 0
              [0xFB, 0x02, 0x00, 0x00],
              // struct.get 0 0
              [0xFB, 0x1C],
              // ref.i31
              [0xFB, 0x14, 0x00],
              // ref.test (ref 0)
              [0xFB, 0x0F],
              // array.len
              [0xFB, 0x17, 0x00],
              // ref.cast (ref null 0)
              [0xFB, 0x18, 0x02, 0x00, 0x00, 0x00],
              // br_on_cast, flags=0b10 (dst null? no — bit1=dst null=1 here), label 0, src 0, dst 0
              [0xD3],
              // ref.eq
              [0x14, 0x00],
              // call_ref 0
            ]),
          ),
        ]),
      ),
    )
  let assert [f] = m.funcs
  f.body
  |> should.equal([
    ast.StructNew(0),
    ast.StructGet(0, 0),
    ast.RefI31,
    ast.RefTest(ast.RefType(False, ast.HConcrete(0))),
    ast.ArrayLen,
    ast.RefCast(ast.RefType(True, ast.HConcrete(0))),
    ast.BrOnCast(
      0,
      ast.RefType(False, ast.HConcrete(0)),
      ast.RefType(True, ast.HConcrete(0)),
    ),
    ast.RefEq,
    ast.CallRef(0),
    ast.End,
  ])
}

/// Wrap a body (locals-free) as one code-section entry: `[count=1][size][0x00
/// locals][body][0x0B end]`, returning the section content (after the id byte).
fn code_section(body: List(Int)) -> List(Int) {
  let inner = list.flatten([[0x00], body, [0x0B]])
  let size = list.length(inner)
  // section content = [count=1][entry_size][inner]; its length = 2 + size.
  list.flatten([[size + 2], [0x01], [size], inner])
}
