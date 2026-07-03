# `.ir` grammar delta — Phase-6 (IR4 surface)

> The **additions** to the canonical `.ir` textual form (`specs/phase-1/ir-grammar.md`, plus the
> Phase-2 delta `specs/phase-2/ir2-grammar-delta.md` and the Phase-5 delta
> `specs/phase-5/ir-grammar-delta.md`) made by the Phase-6 IR growth — SIMD (`v128` + the `SimdOp`
> op-enum + the SIMD `Expr` nodes) and the cross-module imported-function call `CallImport` (I1/I2/
> I7, S3/S5). Every Phase-1..5 spelling is **unchanged**; a Phase-1..5-shaped module (no v128, no
> SIMD op, no cross-module import) prints **byte-identically** (§D). This file is the written
> grammar the printer (`src/twocore/ir/printer.gleam`) and parser (`src/twocore/ir/parser.gleam`)
> both target, so they agree with a spec — not merely with each other (D7). It matches the unit-02
> implementation exactly; the unit-02 round-trip suite
> (`test/twocore/ir/roundtrip_test.gleam`, incl. the hand-authored `golden/simd.ir`) proves
> `parse(print(m)) == m` over the full IR4 surface.
>
> Conventions (sigils `%`/`$`/`@`, `"…"` strings, raw-hex float/bytes constants, neutral
> width-tagged op names, 2-space indentation, `;`-to-end-of-line comments, whitespace-insensitive
> parsing) are inherited verbatim. **The lexer needs no change.** Every new keyword — `v128`,
> `v128.const`, `simd`, `simd.shuffle`, `simd.load`, `simd.store`, `simd.load_lane`,
> `simd.store_lane`, `call_import` — and every SIMD-op mnemonic (`i32x4.add`,
> `i8x16.extract_lane_s.3`, `extend.i8x16.low.s`) is a single `TWord`, because `.`, letters, and
> digits are all word-continuation characters. The `offset=`/`lane=`/`mem=` immediates reuse the
> existing `TWord` + `=` decorator machinery.
>
> **⚠ Naming deviation from the unit-doc §A (recorded, authoritative here).** The unit doc
> `specs/phase-6/02-ir-textual-form.md` §A.3 proposed a **`v.<op>.<shape>`** mnemonic scheme
> (`v.add.i32x4`). The keystone (P6-01) instead froze a **`<shape>.<op>`** scheme in
> `printer.simdop_to_string` (`i32x4.add`), and P6-02 was directed to *use `simdop_to_string`'s
> scheme and make the parser its exact inverse*. **This delta documents the frozen `<shape>.<op>`
> scheme** (the unit doc is stale on the exact spelling; the `RECONCILIATION.md` decision that the
> keystone owns the shape/enum surface governs). The two are informationally equivalent — one
> neutral, width-and-lane-tagged mnemonic per `SimdOp` constructor (D6, never a WASM opcode string
> — but note the mnemonics here *resemble* the WASM shape names; they are the IR's own neutral
> tags, and the SIMD-op namespace is independent of the `rt_simd` function names, which `emit_core`
> (06) owns).

---

## A.1 The `v128` value type

```
valtype := i32 | i64 | f32 | f64 | term | funcref | externref
         | v128                                ; NEW (P6) — TV128
```

`v128` ([SIMD spec — the `v128` vector type](https://webassembly.github.io/spec/core/syntax/types.html#vector-types))
is a **generic 128-bit fixed-width low-level value** (I1) and is legal in **every** valtype
position (params/locals/globals/`FuncType`/`mem.load` result — the last is vestigial, as with the
reftypes: the token must be legal there, though a load never actually produces a v128).
`parse_valtype` gains one arm (`"v128" -> TV128`); `print_valtype` gains one (`TV128 -> "v128"`). It
is **not** a `reftype`, so `parse_reftype` does **not** accept it (a `v128` where a reftype is
required is an `UnexpectedToken`).

## A.2 The `v128.const` value literal (a `Value`, D5-exact)

A v128 literal is the **`ConstV128(bytes)` `Value`** — the raw 16 little-endian bytes, byte-exact,
like `f32.const`/`f64.const`'s raw-bit hex:

```
value += v128.const 0x<hexbytes>       ; ConstV128(bytes) — EXACTLY 16 bytes (32 lowercase hex digits)
```

| `Value` | canonical spelling |
|---|---|
| `ConstV128(<<0,…,0>>)` (all-zero) | `v128.const 0x00000000000000000000000000000000` |
| f32x4 lanes `[0x7fc00001, 0x80000000, 0x7f800000, 0x3f800000]` (qNaN+payload, `-0.0`, `+Inf`, `1.0`), little-endian | `v128.const 0x0100c07f000000800000807f0000803f` |

- **Byte order is storage order** — the 16 bytes print left-to-right in `ConstV128`'s stored order,
  which is the **little-endian lane layout** the SIMD spec fixes (lane 0 in the low/leftmost bytes).
  The printer does **no** lane interpretation (`print_hexbytes`, the data-segment renderer), so every
  bit — NaN payload, `-0.0` sign, saturation pattern — survives trivially (the point of storing raw
  bytes, D5).
- **Canonical form is raw hex bytes, not a typed-lane form** — one canonical spelling (the raw
  bytes), matching the `ConstF32(bits)` raw-hex discipline; a decimal typed-lane form would
  re-introduce float parsing and its rounding/NaN hazards.
- **Length is enforced (16 bytes).** `parse_value`'s `v128.const` arm reads the `0x<hex>` token
  (reusing `parse_hexbytes` → `hex_to_bytes`, which already rejects odd-length hex) and then checks
  the decoded length is **exactly 16 bytes**, else `BadNumberLiteral`. This is a *structural*
  well-formedness check on the literal (upholding `ir.ConstV128`'s "exactly 16 bytes" contract so a
  parsed `ConstV128` is always lane-decodable downstream), **not** a semantic one — no new
  `ParseError` variant.

## A.3 The `Simd(op, args)` expression + the `SimdOp` mnemonics

```
expr += simd <simdop> ( <value>,* )        ; Simd(op, args)
```

`<simdop>` is a single neutral mnemonic word. Arity is the op's business (1 unary, 2 binary, 3 for
`v128.bitselect`; `splat` takes a scalar, extract yields a scalar, replace takes v128+scalar) — the
parser reads whatever `value` list is written and does **not** arity-check (syntax only, exactly as
`Num`). Unknown mnemonics surface as `UnknownOp`.

**Lane-shape tags** (the six standardized shapes — a generic N-lanes×W-bits geometry, reusable by
any vector frontend):

```
simdshape := i8x16 | i16x8 | i32x4 | i64x2 | f32x4 | f64x2
```

The integer and float lane-uniform ops use **distinct mnemonics** (`add` vs `fadd`, `eq` vs `feq`,
…), so the mnemonic alone selects the integer-vs-float `SimdOp` constructor and the shape tag is
carried through verbatim — the `.ir` spelling is bijective over the full enum (`string_to_simdop` is
the exact inverse of `simdop_to_string`, both are exhaustive `case`s that fail to compile if a
constructor is dropped).

The complete mnemonic table (`SimdOp` constructor → `.ir` mnemonic):

### A.3.1 shape-tagged lane-uniform ops — `<shape>.<mnemonic>`

| `SimdOp` | mnemonic | | `SimdOp` | mnemonic |
|---|---|---|---|---|
| `SAdd(s)` | `<s>.add` | | `SEq(s)` | `<s>.eq` |
| `SSub(s)` | `<s>.sub` | | `SNe(s)` | `<s>.ne` |
| `SMul(s)` | `<s>.mul` | | `SLtS(s)`/`SLtU(s)` | `<s>.lt_s`/`<s>.lt_u` |
| `SNeg(s)` | `<s>.neg` | | `SLeS(s)`/`SLeU(s)` | `<s>.le_s`/`<s>.le_u` |
| `SAbs(s)` | `<s>.abs` | | `SGtS(s)`/`SGtU(s)` | `<s>.gt_s`/`<s>.gt_u` |
| `SAddSatS(s)`/`SAddSatU(s)` | `<s>.add_sat_s`/`<s>.add_sat_u` | | `SGeS(s)`/`SGeU(s)` | `<s>.ge_s`/`<s>.ge_u` |
| `SSubSatS(s)`/`SSubSatU(s)` | `<s>.sub_sat_s`/`<s>.sub_sat_u` | | `SAllTrue(s)` | `<s>.all_true` |
| `SMinS(s)`/`SMinU(s)` | `<s>.min_s`/`<s>.min_u` | | `SBitmask(s)` | `<s>.bitmask` |
| `SMaxS(s)`/`SMaxU(s)` | `<s>.max_s`/`<s>.max_u` | | `SSplat(s)` | `<s>.splat` |
| `SAvgrU(s)` | `<s>.avgr_u` | | `SFAdd(s)` | `<s>.fadd` |
| `SShl(s)` | `<s>.shl` | | `SFSub(s)`/`SFMul(s)`/`SFDiv(s)` | `<s>.fsub`/`<s>.fmul`/`<s>.fdiv` |
| `SShrS(s)`/`SShrU(s)` | `<s>.shr_s`/`<s>.shr_u` | | `SFNeg(s)`/`SFAbs(s)`/`SFSqrt(s)` | `<s>.fneg`/`<s>.fabs`/`<s>.fsqrt` |
| `SPopcnt(s)` | `<s>.popcnt` | | `SFMin(s)`/`SFMax(s)` | `<s>.fmin`/`<s>.fmax` |
| | | | `SFPMin(s)`/`SFPMax(s)` | `<s>.pmin`/`<s>.pmax` |
| | | | `SFCeil(s)`/`SFFloor(s)` | `<s>.fceil`/`<s>.ffloor` |
| | | | `SFTrunc(s)`/`SFNearest(s)` | `<s>.ftrunc`/`<s>.fnearest` |
| | | | `SFEq(s)`/`SFNe(s)` | `<s>.feq`/`<s>.fne` |
| | | | `SFLt(s)`/`SFLe(s)`/`SFGt(s)`/`SFGe(s)` | `<s>.flt`/`<s>.fle`/`<s>.fgt`/`<s>.fge` |

### A.3.2 lane access (lane immediate baked into the mnemonic)

| `SimdOp` | `.ir` mnemonic |
|---|---|
| `SExtractLane(s, n)` | `<s>.extract_lane.<n>` |
| `SExtractLaneS(s, n)` | `<s>.extract_lane_s.<n>` |
| `SExtractLaneU(s, n)` | `<s>.extract_lane_u.<n>` |
| `SReplaceLane(s, n)` | `<s>.replace_lane.<n>` |

### A.3.3 shape-agnostic bitwise & boolean-reduction (literal `v128.` prefix, no shape tag)

`VNot`→`v128.not`, `VAnd`→`v128.and`, `VOr`→`v128.or`, `VXor`→`v128.xor`, `VAndNot`→`v128.andnot`,
`VBitselect`→`v128.bitselect`, `VAnyTrue`→`v128.any_true`.

### A.3.4 tagged narrow / extend / extmul / extadd-pairwise (op-name-first)

| `SimdOp` | `.ir` mnemonic |
|---|---|
| `SNarrow(from, signed)` | `narrow.<from>.<s\|u>` |
| `SExtend(from, half, signed)` | `extend.<from>.<low\|high>.<s\|u>` |
| `SExtMul(from, half, signed)` | `extmul.<from>.<low\|high>.<s\|u>` |
| `SExtAddPairwise(from, signed)` | `extadd_pairwise.<from>.<s\|u>` |

`<from>` is the SOURCE shape; `<low|high>` selects the source half; `<s|u>` the sign. These are
op-name-first (unlike the shape-first §A.3.1), so they never collide with a shape-tagged mnemonic.

### A.3.5 singular conversion / dot / q15 / swizzle (fixed literal strings)

`STruncSatF32x4S`→`i32x4.trunc_sat_f32x4_s`, `STruncSatF32x4U`→`i32x4.trunc_sat_f32x4_u`,
`STruncSatF64x2SZero`→`i32x4.trunc_sat_f64x2_s_zero`, `STruncSatF64x2UZero`→`i32x4.trunc_sat_f64x2_u_zero`,
`SConvertF32x4I32x4S`→`f32x4.convert_i32x4_s`, `SConvertF32x4I32x4U`→`f32x4.convert_i32x4_u`,
`SConvertF64x2LowI32x4S`→`f64x2.convert_low_i32x4_s`, `SConvertF64x2LowI32x4U`→`f64x2.convert_low_i32x4_u`,
`SDemoteF64x2Zero`→`f32x4.demote_f64x2_zero`, `SPromoteLowF32x4`→`f64x2.promote_low_f32x4`,
`SDotI16x8S`→`i32x4.dot_i16x8_s`, `SQ15MulrSatS`→`i16x8.q15mulr_sat_s`, `SSwizzle`→`i8x16.swizzle`.
`string_to_simdop` matches these **verbatim first**, before the shape-first decomposition, so a
suffix that is not a lane-uniform mnemonic (`trunc_sat_f32x4_s`, `swizzle`, …) resolves to the fixed
constructor rather than falling through.

## A.4 `i8x16.shuffle` — the `SimdShuffle` node (16 immediate lane indices)

```
expr += simd.shuffle [ <int>,* ] <a-value> <b-value>       ; SimdShuffle(lanes, a, b)
```

The bracketed, comma-separated int list is the byte-lane indices (each `0..31`, selecting a byte
from the 32-byte concatenation `a ++ b`); the two following values are the v128 operands. Example:

```
simd.shuffle [0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23] %a %b
```

The printer emits `lanes` in order; the parser reads the list with `parse_lane_list` (a bracketed
`expect_number` list) then two `parse_value`s. The parser does **NOT** enforce list length 16 or
index range `0..31` — those are *typing* rules (`validate`, 04); it round-trips whatever list is
written (contrast the `v128.const` 16-byte check, which is *structural* well-formedness of a
literal).

## A.5 SIMD memory (bounds-checked through `rt_mem` — I6/D3a) — dedicated nodes

The four SIMD-memory `Expr` nodes reuse the omit-when-zero `mem=` decorator (§A.6 / Phase-5 §A.7) so
a single-memory (index-0) SIMD program is neutral, a **mandatory `offset=`** (like `mem.load`), and
— for the lane variants — a **mandatory `lane=`**. All widths are in **BITS** (S2).

```
expr += simd.load <loadkind> <addr> offset=<int> [ mem=<int> ]                    ; SimdLoad
      | simd.store <addr> <value> offset=<int> [ mem=<int> ]                       ; SimdStore
      | simd.load_lane <width> <addr> offset=<int> lane=<int> <vec> [ mem=<int> ]  ; SimdLoadLane
      | simd.store_lane <width> <addr> offset=<int> lane=<int> <vec> [ mem=<int> ] ; SimdStoreLane
```

`<width>` is a bare number token (`8`/`16`/`32`/`64` bits). `<loadkind>` is a **variable-token**
descriptor (the inverse of `simdloadkind_str`):

| `SimdLoadKind` | `<loadkind>` tokens |
|---|---|
| `LoadV128` | `v128` |
| `LoadSplat(bits)` | `splat <bits>` (8/16/32/64) |
| `LoadExtend(source_bits, signed)` | `extend <bits> <s\|u>` (8/16/32) |
| `LoadZero(lane_bits)` | `zero <bits>` (32/64) |

Worked examples:

| node | `.ir` |
|---|---|
| `SimdLoad(0, LoadV128, %a, 0)` | `simd.load v128 %a offset=0` |
| `SimdLoad(1, LoadSplat(32), %a, 4)` | `simd.load splat 32 %a offset=4 mem=1` |
| `SimdLoad(0, LoadExtend(8, False), %a, 0)` | `simd.load extend 8 u %a offset=0` |
| `SimdLoad(0, LoadZero(64), %a, 0)` | `simd.load zero 64 %a offset=0` |
| `SimdStore(0, %a, %v, 16)` | `simd.store %a %v offset=16` |
| `SimdLoadLane(0, 16, %a, 0, 3, %v)` | `simd.load_lane 16 %a offset=0 lane=3 %v` |
| `SimdStoreLane(2, 8, %a, 0, 2, %v)` | `simd.store_lane 8 %a offset=0 lane=2 %v mem=2` |

The invariant these carry — **bounds-checked → trap `MemoryOutOfBounds`** — is a runtime concern
(06/07/08), not a text concern; this unit only renders the shapes.

## A.6 The `offset=` / `lane=` / `mem=` decorators (reuse)

- **`offset=<int>`** — mandatory on every SIMD load/store (parsed by `parse_offset`: `offset` `=`
  number), identical to `mem.load`/`mem.store`.
- **`lane=<int>`** — mandatory on `simd.load_lane`/`simd.store_lane` (parsed by `parse_lane`); like
  `seg=`, recognised only when immediately followed by `=`, so it cannot swallow a following
  statement.
- **`mem=<int>`** — the omit-when-zero memory-index decorator (Phase-5 §A.7), reused verbatim via
  `print_memidx` / `parse_opt_kv(_, "mem")`. A single-memory (index-0) SIMD program is
  byte-identical to one with the decorator elided.

## A.7 The cross-module imported call `CallImport` (S5)

```
expr += call_import <slot> : <functype> ( <value>,* )      ; CallImport(slot, ty, args)
```

`<slot>` is the positional function-import index (imports occupy the low funcidx range; `slot`
counts function imports only). `<functype>` reuses the `call_indirect` signature form (`(params) ->
(results)`); the value list is the arguments. Distinct from `call @f (…)` (`CallDirect`, same-module
only): a `CallImport` is resolved at LINK time to a handed-in closure capability (`link.call_import`,
09) — D3a-legible in the `.ir`. The parser does not type-check the args against the signature (syntax
only). Example: `call_import 0 : (v128) -> () (%v)`.

The import DECL itself is **unchanged** — a cross-module function import prints byte-identically to a
host import (`import "A" "f" : (params) -> (results)`, the existing `ImportFn`), because the
linker-built dispatch closure is a `runtime/link.gleam` value, not an IR field.

## A.8 memory64 — confirmed unchanged (no new spelling)

A 64-bit memory is `memory i64 ( min N [max M] )` and an `i64`-addressed load/store is
`mem.load i64 8 %a offset=0 mem=1` — **exactly the Phase-5 spelling** (`P5-02` §A.3.1 / §A.7). Phase
6 unfreezes only the memory64 *runtime* (05/08); the `.ir` spelling of `Idx64` is unchanged. Unit 02
adds a confirming round-trip so a memory64 `.ir` regression fails a test rather than surfacing only
at conformance.

---

## D. Byte-identity (H7/I7) — a Phase-1..5-shaped module is unchanged

| Construct | Phase-1..5-shaped module prints as | Byte-identical? |
|---|---|---|
| no v128 value type / no `v128.const` | (never emitted) | yes — the new arms fire only for `TV128`/`ConstV128` |
| no SIMD op / node | (never emitted) | yes — `Simd`/`SimdShuffle`/`SimdLoad*`/`SimdStore*` never appear |
| SIMD-memory at memory index 0 | `mem=` omitted (§A.6) | yes (same omit-when-zero rule as scalar mem ops) |
| a function import + its call | `import "…" "…" : …` (+ `call_import` only for a genuinely-imported call) | yes — no Phase-1..5 module produces `CallImport` (05 introduces it) |
| memory64 memory | `memory i64 ( … )` | yes (Phase-5 spelling) |

The round-trip suite asserts a Phase-4-shaped module (`legacy_module_byte_identical_test`) prints an
EXACT expected string, and a module with an `ImportFn` + `CallImport`
(`cross_module_import_and_callimport_roundtrip_test`) prints the import DECL byte-identically — so a
regression that leaked a new token into legacy output fails closed.

## Reconciliation notes (deviations from unit-doc §A / open questions)

- **The frozen SIMD-op mnemonic scheme is `<shape>.<op>`, not the unit-doc `v.<op>.<shape>`.** The
  keystone (P6-01) froze `printer.simdop_to_string` in the `<shape>.<op>` form (`i32x4.add`,
  `i8x16.extract_lane_s.3`, `extend.i8x16.low.s`, `i32x4.dot_i16x8_s`); P6-02 was directed to use it
  and make `string_to_simdop` the exact inverse. This delta documents the frozen scheme
  (authoritative); the unit doc §A.3's `v.add.i32x4` proposal is stale. Both are one neutral,
  width-and-lane-tagged mnemonic per constructor (D6).
- **SIMD-memory `width`/`*_bits` fields are BITS** (S2): `simd.load_lane 32 …` is 32 bits,
  `LoadSplat(8)` prints `splat 8`, `LoadZero(32)` prints `zero 32`, `LoadExtend(8, False)` prints
  `extend 8 u`.
- **The `<loadkind>` for `simd.load` is a variable-token descriptor** (`v128` / `splat <bits>` /
  `extend <bits> <s|u>` / `zero <bits>`), matching the keystone's `simdloadkind_str`, rather than the
  unit-doc's single-word forms (`splat8`, `extend8x8_u`, `zero32`). Informationally equivalent.
- **`simd.load_lane`/`simd.store_lane` field order** is `<width> <addr> offset= lane= <vec> [mem=]`
  (the `vec` operand comes AFTER the `lane=` decorator), matching the keystone printer — a slight
  reorder from the unit-doc sketch (`<width> <addr> <vec> offset= lane=`).
- **`CallImport` is a new IR node (S5)** with its own `call_import <slot> : <functype> (args)`
  spelling — it is not `CallDirect` reuse; the unit doc's "no new IR shape for cross-module linking"
  note predates the S5 decision to add `CallImport` to «IR4-FROZEN».
- **No new `ParseError` variant** — a non-16-byte `v128.const` is `BadNumberLiteral`, an unknown SIMD
  mnemonic/load-kind is `UnknownOp`, a `v128` where a reftype is required is `UnexpectedToken` (S8's
  "TrapReason unchanged" has its parser analogue: the six existing `ParseError`s suffice).
