# Unit P6-02 — The `.ir` printer/parser extension (IR4 surface)

> **1 owner. Wave A, fast-follow OFF the freeze critical path.** Hard freeze dep:
> `«IR4-FROZEN»` (P6-01 — `ir.gleam` gains the `TV128` `ValType`, the `ConstV128(bytes)`
> `Value`, the `SimdOp` enum + `SimdShape` (and, if it lands, the `SimdLoadKind`
> descriptor), the `Simd`/`SimdShuffle`/`SimdLoad`/`SimdStore`/`SimdLoadLane`/
> `SimdStoreLane` `Expr` nodes, and any new `TrapReason` (expected: **none**) — plus the
> spellings recorded in `specs/phase-6/ir-grammar-delta.md`). You gate **nothing
> downstream** — the round-trip property is a property, not an interface anyone binds to.
> Read [`00-overview.md`](00-overview.md) (I1/I2/I3/I7), then
> [`RECONCILIATION.md`] (Phase-6 S-decisions, when it exists), then the EM's
> [`PROVISIONAL-SURFACE.md`](PROVISIONAL-SURFACE.md), then this doc. Where a Phase-6
> reconciliation decision conflicts with this doc, the reconciliation wins.

## Context

`.ir` is the compiler's inter-stage contract (decision **D7**): any stage dumps its IR with
`twocore/ir/printer.print_module` and reloads it with `twocore/ir/parser.parse_module`, and
the two satisfy `parse(print(m)) == m` for every module `m`. Phase 1 made this green over the
Phase-1 IR surface; Phase 2 (`P2-02`) extended it to tables/active-elements/mem-ops/floats/
converting-`ConvOp`s; Phase 5 (`P5-02`) extended it to the full **IR3** surface (reftype value
types + `RefType`, the reference/table/bulk-memory `Expr` nodes, multi-memory + the memory-index
decorator, the `IdxType` axis incl. `Idx64`, the import/export state variants, the
active/passive/declarative element + passive data model, the `ConstNull(RefType)` value). Phases
3 and 4 added **no** IR node types.

Phase 6 is **the first phase since Phase 5 to grow the IR** (I7), and the growth is the largest
single-op-family expansion the IR has ever seen. The keystone (`P6-01`) adds, all at once:

- the **`TV128` `ValType`** — a generic 128-bit fixed-width low-level value (I1);
- the **`ConstV128(bytes: BitArray)` `Value`** — the raw 16-byte little-endian v128 literal (D5:
  store the bits, never a decoded lane structure — so NaN payloads, `-0.0`, and every bit pattern
  are exact);
- the **`SimdOp` enum** (I2) — the compact, width-and-lane-tagged, neutral op enum that carries
  the ~236 standardized SIMD lane instructions in ~110 constructors, routed to `rt_simd` by
  `emit_core` exactly as `NumOp` is routed to `rt_num`;
- the **`SimdShape`** lane-geometry tag (`I8x16`/`I16x8`/`I32x4`/`I64x2`/`F32x4`/`F64x2`);
- the SIMD `Expr` nodes: the pure lane-wise **`Simd(op, args)`**, the immediate-carrying
  **`SimdShuffle(lanes, a, b)`**, and the bounds-checked SIMD-memory family
  **`SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane`**;
- (memory64) **no new IR shape** — the `IdxType`/`Idx64` axis already froze in P5-01; Phase 6
  only unfreezes its *runtime* (P6-05/P6-08). The `.ir` spelling of a 64-bit memory is unchanged.
- (cross-module linking) **no new IR shape** — an imported function is the existing
  `ImportFn(capability, name, ty)`; the linker-built dispatch closure lives in
  `runtime/link.gleam`'s `Provided`, never in `ir.gleam`. The `.ir` spelling of a cross-module
  function import is unchanged.

Every SIMD/v128 addition must **print and parse losslessly** or the dump/load boundary silently
drops a Phase-6 feature — and, because v128 is stored as raw bytes and the SIMD conformance suite
leans hard on exact NaN/`-0.0`/saturation lane bit patterns, a lossy v128 spelling would corrupt
the very values the differential oracle checks. You **extend** the Phase-1/2/5 printer/parser/
test; you do not rewrite them. Their structure (centralized `*_to_string` / `string_to_*`
spelling tables, a two-phase recursive-descent total parser, hand-authored goldens, an
independently-built expected `Module`) is the template, and it already accommodates the new
surface with **no lexer change and no new `ParseError` variant** (§C).

## Goal

Keep `parse(print(m)) == m` **GREEN over the full IR4 surface.** Every new variant prints in
one canonical spelling and parses back to the identical `Module`. The v128 literal round-trips
**bit-exactly** (the 16 raw bytes compared byte-for-byte, so a NaN-payload lane, a `-0.0` lane,
a `±Inf` lane, and any saturation/canonicalization bit pattern survive — the same D5 fidelity
`ConstF32`/`ConstF64` already have, one level wider). The parser stays **total** — no
`let assert`/`panic`/`todo` on any path reachable from untrusted text; every fault is a typed
`ParseError` with position info. Measurable done: the round-trip property passes on a corpus that
exercises **every `SimdOp` constructor**, every `SimdShape`, every SIMD `Expr` node (incl. shuffle
lane lists and every SIMD-memory kind/width/lane at memory index 0 **and** non-zero), the `TV128`
valtype in every valtype position, and `v128.const` with NaN-payload / `-0.0` / `±Inf` lanes; the
new hand-authored `simd.ir` golden parses to its independently-built expected `Module` and
re-prints stably; the five existing goldens (`add`/`sum_to`/`fib`/`mem_table`/`refs_bulk`) **still
parse** and **still print byte-identically** (the IR4 additions perturb no legacy spelling); and
the negative/fuzz corpus returns typed errors for the new malformed forms without panicking.

## Files owned

| Path | Role |
|---|---|
| `src/twocore/ir/printer.gleam` | IR → `.ir` text. **Extend** `print_valtype`, `print_value`, `print_expr`; add `simdop_to_string`, `simd_shape_str`, `print_simd_load_kind`, `print_lane`, `print_lane_list`, `print_v128_const`. |
| `src/twocore/ir/parser.gleam` | `.ir` text → IR. **Extend** `parse_valtype`, `parse_value`, `parse_expr`; add `parse_simd`, `string_to_simdop`, `parse_simd_shape` (+ `is_int_shape`), `parse_simd_load`/`parse_simd_store`/`parse_simd_load_lane`/`parse_simd_store_lane`/`parse_simd_shuffle`, `string_to_simd_load_kind`, `parse_lane`, `parse_lane_list`, `parse_v128_const`. |
| `test/twocore/ir/roundtrip_test.gleam` | **Extend** the corpora + add the new golden test + the SIMD discrimination tests + the SIMD negative corpus. (Minimally touched by `P6-01` to keep the tree compiling; you fill in the real coverage.) |
| `test/twocore/ir/golden/simd.ir` | **Add** ≥1 hand-authored Phase-6 golden exercising SIMD + a `v128.const` with NaN-payload lanes. Hand-authored — never printer-generated. |
| `specs/phase-6/ir-grammar-delta.md` | **Add** the frozen grammar delta (mirrors `specs/phase-5/ir-grammar-delta.md`); §A of this doc is its authoritative source. |

You **read** `src/twocore/ir.gleam` (the IR4 types), `specs/phase-1/ir-grammar.md`,
`specs/phase-2/ir2-grammar-delta.md`, and `specs/phase-5/ir-grammar-delta.md`; you never edit
`ir.gleam`, `ir/effect.gleam` (the SIMD effect classification is P6-01's, §Effect note), or the
prior grammar deltas.

## Deliverables & freeze milestones

- **No freeze milestone is owned by this unit** — it publishes no interface anyone downstream
  binds to. The round-trip property is an internal correctness invariant. (The *grammar-delta
  spellings* it fixes are, however, consumed by anyone hand-authoring an `.ir` fixture — 05/06/07
  golden tests — so treat §A as a stable, reconciled contract.)
- Deliverable 1: the extended printer, deterministic and total (one canonical spelling per IR4
  construct).
- Deliverable 2: the extended parser, total, mirroring every spelling.
- Deliverable 3: `specs/phase-6/ir-grammar-delta.md` — the written grammar the two target
  (defeats printer/parser collusion; §A here is its content), cross-linked from the Phase-5 delta.
- Deliverable 4: the extended `roundtrip_test.gleam` corpora + the hand-authored `simd.ir` golden
  with its by-hand expected `Module`.

## Depends on (freeze milestones)

- **`«IR4-FROZEN»`** — the only hard gate. By the time you start, `P6-01` has landed the IR type
  changes GREEN, which (Gleam has no default fields) means it has already minimally updated every
  affected constructor site in `roundtrip_test.gleam` and made the printer/parser exhaustive
  matches **compile** — possibly with placeholder arms (a `todo`, an `UnknownOp`, or a lossy stub)
  that *compile but don't yet round-trip*. **Your job is to replace those placeholders with the
  real lossless spellings and extend the corpus to exercise them.** Confirm the freeze is in:
  `ValType` has `TV128`; `Value` has `ConstV128(bytes: BitArray)`; `Expr` has `Simd(op, args)`,
  `SimdShuffle(lanes, a, b)`, `SimdLoad`, `SimdStore`, `SimdLoadLane`, `SimdStoreLane`; the
  `SimdOp` enum + `SimdShape` exist; and `TrapReason` is unchanged (or gained exactly the arm 01
  documents — §OQ 2).
- **The spellings in `specs/phase-6/ir-grammar-delta.md` WIN** over the proposals in this doc. If
  that file does not exist yet (`P6-01` in flight), author §A below as its content, get `P6-01`
  to record it verbatim, and flag any divergence — printer, parser, and grammar doc share one
  source of truth.
- You depend on **nothing downstream** and **no runtime/ABI/`rt_simd`** milestone — this is plain
  text I/O over Gleam strings. (In particular you do **not** depend on `«RT-SIMD-SIG»`: the `.ir`
  mnemonic namespace is independent of the `rt_simd` function names; `emit_core` (06) owns the
  `SimdOp`→`rt_simd`-function binding, not this unit.)

## Scope — in / out for Phase 6

**In** (print + parse, lossless, both directions):

- **The `TV128` value type** → `v128` (everywhere a `ValType` appears: params, locals, globals,
  `FuncType`, `mem.load` result — the last cannot actually produce a v128, but the token must be
  legal in every valtype position, exactly as `funcref` is).
- **The `ConstV128(bytes)` value literal** → `v128.const 0x<32 hex digits>` — the 16 raw
  little-endian bytes, byte-exact (D5).
- **Every `SimdOp`** carried by `Simd(op, args)` → `simd <mnemonic> (args)`, one neutral,
  width-and-lane-tagged mnemonic per constructor (§A.3 enumerates all ~110).
- **`SimdShuffle(lanes, a, b)`** → `simd.shuffle [ l0, …, l15 ] <a> <b>` — the 16 immediate lane
  indices as a bracketed int list plus two v128 operands.
- **The SIMD-memory nodes** `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane` → the
  `simd.load`/`simd.store`/`simd.load_lane`/`simd.store_lane` forms with their kind/width, the
  `offset=` and `lane=` immediates, and the omit-when-zero `mem=` decorator (§A.5).
- **memory64 (confirm, inherited):** a 64-bit memory still prints `memory i64 (min N …)` and an
  `i64`-addressed `mem.load`/`store` still round-trips — **unchanged from P5**; this unit adds a
  test that confirms it, since P6 unfreezes the memory64 *runtime* (05/08) and a regression here
  would be invisible until conformance.
- **Cross-module function imports (confirm, inherited):** a module importing another module's
  exported **function** prints as the existing `ImportFn` — `import "A" "f" : (…) -> (…)` —
  **byte-identical to P5**; the linker-built dispatch closure is a `runtime/link.gleam` artifact,
  not an IR field, so there is **no `.ir` grammar change** for cross-module linking. This unit
  asserts the round-trip is byte-identical.

**Out** (per the I-decisions — keep deferred / owned elsewhere):

- Any **semantics** of the new ops (lane arithmetic, NaN canonicalization, saturation, bounds
  checks, the memory64 page cap, the closure dispatch). The parser checks *syntax* and builds a
  well-formed `Module`; it is **not** a validator and does **not** check lane-index ranges,
  shuffle-list length/range, `SimdShape`/op compatibility, memory-index bounds, or v128 operand
  arity (those live in `validate` (04) / `lower` (05) / `emit_core` (06) / `rt_simd` (07)). The
  one structural well-formedness check the parser *does* make is that a `v128.const` literal is
  **exactly 16 bytes** (see §A.2 and the Deviations note) — because `ConstV128`'s type contract
  and the downstream bit-syntax lane decode both assume it.
- The **binary opcode bytes** — the `0xFD` SIMD prefix and its ~236 sub-opcodes, the v128
  immediate layout, the shuffle/lane immediates, the SIMD-memory memarg — are the WASM binary
  encoding, owned by `decode` (03). The `.ir` spellings here are **neutral names** (D6),
  independent of the WASM byte encoding: `simd v.add.i32x4 (…)`, never `i32x4.add`.
- The **`SimdOp`→`rt_simd`-function binding** (`emit_core`, 06) and the `rt_simd` lane bodies
  (07). This unit fixes the *`.ir` mnemonic* per `SimdOp`; the *runtime function name* is a
  separate namespace.
- The **`Provided`/closure dispatch** for cross-module linking (`runtime/link.gleam`, 09) — not
  an IR shape, nothing to print.
- **relaxed-SIMD** (the separate non-deterministic proposal) — deferred (I8). No relaxed-SIMD op
  mnemonic exists in the IR4 surface.

---

## A. The grammar delta (EBNF) — the authoritative spelling table

> This section IS the content of `specs/phase-6/ir-grammar-delta.md`. It **adds** to the Phase-1
> grammar, the Phase-2 delta, and the Phase-5 delta; every prior spelling is **unchanged**, so a
> Phase-1..5-shaped module (no v128, no SIMD op, a single 32-bit memory, no cross-module import)
> prints byte-identically (§D). This file is the written grammar the printer
> (`ir/printer.gleam`) and parser (`ir/parser.gleam`) both target, so they agree with a spec — not
> merely with each other (D7). It matches the unit-02 implementation exactly; the round-trip suite
> (`test/twocore/ir/roundtrip_test.gleam`, incl. the hand-authored `golden/simd.ir`) proves
> `parse(print(m)) == m` over the full IR4 surface.
>
> Conventions (sigils `%`/`$`/`@`, `"…"` strings, raw-hex float/bytes constants, neutral
> width-tagged op names, 2-space indentation, `;`-to-end-of-line comments, whitespace-insensitive
> parsing) are inherited verbatim. **The lexer needs no change.** Every new keyword — `v128`,
> `v128.const`, `simd`, `simd.shuffle`, `simd.load`, `simd.store`, `simd.load_lane`,
> `simd.store_lane` — is a single `TWord`, because `.`, letters, and digits are all
> word-continuation characters (so `simd.load_lane` and `v.trunc_sat_s.i32x4.f32x4` each tokenise
> as one word). The SIMD-op mnemonic (`v.add.i32x4`, `v.extract_lane_s.i8x16.3`) is a `TWord`; the
> `lane=<int>` immediate reuses the existing `TWord` + `TEquals` decorator machinery.

### A.1 The `v128` value type

```
valtype := i32 | i64 | f32 | f64 | term | funcref | externref
         | v128                                ; NEW (P6) — TV128
```

`v128` ([SIMD spec — the `v128` value type](https://webassembly.github.io/spec/core/syntax/types.html#vector-types))
is a **generic 128-bit fixed-width low-level value** (I1) and is legal in **every** valtype
position (params/locals/globals/`FuncType`/`mem.load` result — the last is vestigial, as with the
reftypes). `parse_valtype` gains one arm (`"v128" -> TV128`); `print_valtype` gains one
(`TV128 -> "v128"`). It is **not** a `reftype`, so `parse_reftype` does **not** accept it (a
`v128` where a reftype is required is an `UnexpectedToken`).

### A.2 The `v128.const` value literal (a `Value`, D5-exact)

A v128 literal is the **`ConstV128(bytes)` `Value`** — a byte-exact 128-bit constant, like
`i32.const`/`f32.const`, stored as its raw 16 little-endian bytes (I1/D5). Its spelling is a
single dotted keyword plus a `0x`-hex byte string, **identical in shape to a data-segment payload
and a float const's raw-bit hex** (the printer already owns `hex_of_bytes`; the parser already
owns `hex_to_bytes`):

```
value += v128.const 0x<hexbytes>       ; ConstV128(bytes) — EXACTLY 16 bytes (32 lowercase hex digits)
```

| `Value` | canonical spelling |
|---|---|
| `ConstV128(<<0,0,…,0>>)` (all-zero) | `v128.const 0x00000000000000000000000000000000` |
| f32x4 lanes `[0x7fc00001, 0x80000000, 0x7f800000, 0x3f800000]` (qNaN+payload, `-0.0`, `+Inf`, `1.0`), little-endian | `v128.const 0x0100c07f000000800000807f0000803f` |

- **Byte order is storage order.** The 16 bytes print left-to-right in `ConstV128`'s stored order,
  which is the **little-endian lane layout** the SIMD spec fixes for memory
  ([SIMD spec — lanes are little-endian](https://webassembly.github.io/spec/core/exec/numerics.html)):
  lane 0 occupies the low-address (leftmost) bytes. The printer does **no** lane interpretation, so
  every bit — NaN payload, `-0.0` sign bit, saturation pattern — is preserved trivially (this is
  the whole point of storing raw bytes per D5). The reader authoring a golden lays out the lanes by
  hand (§E).
- **Canonical form is raw hex bytes, not a typed-lane form.** The `.ir` is neutral (D6) and must be
  byte-exact for NaN payloads; a decimal `i32x4 a b c d` authoring form (WAT-style) would be a
  *second* spelling that (for float lanes) re-introduces float parsing and its rounding hazards.
  We therefore fix **one** canonical spelling — the raw bytes — matching the existing
  `ConstF32(bits)` raw-hex discipline. (Reconciliation may, if it wants author ergonomics, add a
  parser-only typed-lane *input* alias that desugars to the same 16 bytes; the printer stays raw
  hex. Flagged §OQ 3 — the default is raw-hex-only.)
- **Length is enforced (16 bytes).** `parse_v128_const` reads the `0x<hex>` token (reusing
  `hex_to_bytes`, which already rejects odd-length hex) and then checks the decoded length is
  **exactly 16 bytes**, else `BadNumberLiteral(l, c, lexeme)`. This is a *structural* well-formedness
  check on the literal — not a semantic one — analogous to rejecting odd-length hex, and it upholds
  `ConstV128`'s "exactly 16 bytes" contract so that every parsed `ConstV128` can be lane-decoded by
  `<<a:32/little, …>>` downstream without crashing (see the Deviations note — this contrasts with
  shuffle-lane counts, which the parser does *not* enforce because they are a typing rule).

### A.3 The `Simd(op, args)` expression + the `SimdOp` mnemonics

The pure lane-wise SIMD op is `Simd(op: SimdOp, args: List(Value))`, printed exactly like the
scalar `Num(op, args)` one level up:

```
expr += simd <simdop> ( <value>,* )        ; Simd(op, args)
```

`<simdop>` is a single neutral mnemonic word. Arity is the op's business (1 unary, 2 binary, 3 for
`bitselect`; splat takes a scalar, extract yields a scalar, replace takes v128+scalar) — the
parser reads whatever `value` list is written and does **not** arity-check (syntax only, exactly
as `Num`). The mnemonics follow the **`i.`/`f.` scalar precedent one namespace up**: the vector
namespace is **`v.`**, then the operation, then — for the lane-uniform ops — the **lane-shape
tag**. This is the same neutralising transform the IR already applies to scalars (`i32.add` →
`i.add.32`); the WASM opcode `i32x4.add` becomes **`v.add.i32x4`**, never the opcode string
itself (D6).

**Lane-shape tags** (the six standardized shapes — a *generic lane geometry*, N lanes × W bits,
reusable by any vector-capable frontend; **not** a WASM opcode):

```
simdshape := i8x16 | i16x8 | i32x4 | i64x2 | f32x4 | f64x2
```

`parse_simd_shape` maps these six; `is_int_shape` classifies the four integer shapes. **The shape
tag's int-vs-float family selects the integer-vs-float `SimdOp` constructor** where a mnemonic is
shared (`add`/`sub`/`mul`/`neg`/`abs`/`eq`/`ne`): `v.add.i32x4` → the integer `SAdd(I32x4)`,
`v.add.f32x4` → the float `FAdd(F32x4)`. (This selection rule makes the spelling bijective over the
*valid* surface; see the Deviations note recommending disjoint shape types so the invalid combos
are unrepresentable.)

The spelling of the sign-bearing integer ops carries `_s`/`_u` in the mnemonic (as scalar `NumOp`
does: `i.lt_s.32`), so they never collide with the sign-agnostic float mnemonics.

Below, every standardized fixed-width SIMD lane instruction is enumerated: **WASM instruction →
provisional `SimdOp` constructor → `.ir` mnemonic**. Spec references are to the SIMD instruction
set ([WebAssembly SIMD — vector instructions](https://webassembly.github.io/spec/core/syntax/instructions.html#vector-instructions)).

#### A.3.1 v128 bitwise & boolean-reduction (shape-agnostic — no shape tag)

| WASM | `SimdOp` | `.ir` mnemonic |
|---|---|---|
| `v128.not` | `VNot` | `v.not` |
| `v128.and` | `VAnd` | `v.and` |
| `v128.andnot` | `VAndNot` | `v.andnot` |
| `v128.or` | `VOr` | `v.or` |
| `v128.xor` | `VXor` | `v.xor` |
| `v128.bitselect` | `VBitselect` | `v.bitselect` |
| `v128.any_true` | `VAnyTrue` | `v.any_true` |

#### A.3.2 Lane build / access (splat, extract, replace)

`splat` and `replace_lane` are sign-free; `extract_lane` is signed/unsigned for the sub-word
integer shapes (`i8x16`/`i16x8`) and sign-free for the full-width shapes. The **lane immediate is
baked into the mnemonic** as a trailing `.<n>` segment (the `tuple_get.<index>` precedent), so
`Simd`'s `simd <op> (args)` shape stays perfectly uniform (op is always one word; args always a
paren list).

| WASM | `SimdOp` | `.ir` mnemonic |
|---|---|---|
| `<shape>.splat` (all six) | `SSplat(shape)` | `v.splat.<shape>` |
| `i8x16.extract_lane_s N` | `SExtractLaneS(I8x16, N)` | `v.extract_lane_s.i8x16.<N>` |
| `i8x16.extract_lane_u N` | `SExtractLaneU(I8x16, N)` | `v.extract_lane_u.i8x16.<N>` |
| `i16x8.extract_lane_s N` | `SExtractLaneS(I16x8, N)` | `v.extract_lane_s.i16x8.<N>` |
| `i16x8.extract_lane_u N` | `SExtractLaneU(I16x8, N)` | `v.extract_lane_u.i16x8.<N>` |
| `i32x4.extract_lane N` | `SExtractLaneS(I32x4, N)` † | `v.extract_lane_s.i32x4.<N>` |
| `i64x2.extract_lane N` | `SExtractLaneS(I64x2, N)` † | `v.extract_lane_s.i64x2.<N>` |
| `f32x4.extract_lane N` | `SExtractLaneS(F32x4, N)` † | `v.extract_lane_s.f32x4.<N>` |
| `f64x2.extract_lane N` | `SExtractLaneS(F64x2, N)` † | `v.extract_lane_s.f64x2.<N>` |
| `<shape>.replace_lane N` (all six) | `SReplaceLane(shape, N)` | `v.replace_lane.<shape>.<N>` |

† The full-width shapes have a single (sign-free) `extract_lane`; the keystone picks the
constructor it maps to (the `_s` spelling above is the provisional pick). This is a cross-unit seam
(§Seams) — 01/03 fix the constructor; 02 spells whatever it fixes, bijectively. The **`.ir`
spelling is bijective per (constructor, shape, lane)** regardless.

#### A.3.3 Integer-lane arithmetic (int shapes)

| WASM | `SimdOp` | `.ir` mnemonic |
|---|---|---|
| `<is>.neg` (i8x16/i16x8/i32x4/i64x2) | `SNeg(is)` | `v.neg.<is>` |
| `<is>.abs` (all four) | `SAbs(is)` | `v.abs.<is>` |
| `<is>.add` (all four) | `SAdd(is)` | `v.add.<is>` |
| `<is>.sub` (all four) | `SSub(is)` | `v.sub.<is>` |
| `<is>.mul` (i16x8/i32x4/i64x2 — **no** `i8x16.mul`) | `SMul(is)` | `v.mul.<is>` |
| `<is>.min_s` (i8x16/i16x8/i32x4) | `SMinS(is)` | `v.min_s.<is>` |
| `<is>.min_u` (i8x16/i16x8/i32x4) | `SMinU(is)` | `v.min_u.<is>` |
| `<is>.max_s` (i8x16/i16x8/i32x4) | `SMaxS(is)` | `v.max_s.<is>` |
| `<is>.max_u` (i8x16/i16x8/i32x4) | `SMaxU(is)` | `v.max_u.<is>` |
| `<is>.avgr_u` (i8x16/i16x8) | `SAvgrU(is)` | `v.avgr_u.<is>` |
| `<is>.shl` (all four) | `SShl(is)` | `v.shl.<is>` |
| `<is>.shr_s` (all four) | `SShrS(is)` | `v.shr_s.<is>` |
| `<is>.shr_u` (all four) | `SShrU(is)` | `v.shr_u.<is>` |
| `i8x16.popcnt` | `I8x16Popcnt` | `v.popcnt.i8x16` |
| `i16x8.q15mulr_sat_s` | `I16x8Q15MulrSatS` | `v.q15mulr_sat_s.i16x8` |

#### A.3.4 Integer-lane comparisons (int shapes) → a v128 lane mask

Each lane result is all-ones (true) or all-zeros (false). `i8x16`/`i16x8`/`i32x4` have signed and
unsigned orderings; `i64x2` has `eq`/`ne` and **only signed** orderings (`lt_s`/`gt_s`/`le_s`/`ge_s`).

| WASM | `SimdOp` | `.ir` mnemonic |
|---|---|---|
| `<is>.eq` | `SEq(is)` | `v.eq.<is>` |
| `<is>.ne` | `SNe(is)` | `v.ne.<is>` |
| `<is>.lt_s` / `lt_u` | `SLtS(is)` / `SLtU(is)` | `v.lt_s.<is>` / `v.lt_u.<is>` |
| `<is>.gt_s` / `gt_u` | `SGtS(is)` / `SGtU(is)` | `v.gt_s.<is>` / `v.gt_u.<is>` |
| `<is>.le_s` / `le_u` | `SLeS(is)` / `SLeU(is)` | `v.le_s.<is>` / `v.le_u.<is>` |
| `<is>.ge_s` / `ge_u` | `SGeS(is)` / `SGeU(is)` | `v.ge_s.<is>` / `v.ge_u.<is>` |

#### A.3.5 Integer bitmask / all_true (int shapes)

| WASM | `SimdOp` | `.ir` mnemonic |
|---|---|---|
| `<is>.all_true` (all four) | `SAllTrue(is)` | `v.all_true.<is>` |
| `<is>.bitmask` (all four) | `SBitmask(is)` | `v.bitmask.<is>` |

#### A.3.6 Narrow / widen / extended-mul / extended-add-pairwise / dot (fixed constructors)

These are individually-named constructors (source **and** result shape fixed); each gets a fixed
neutral spelling `v.<op>[_s|_u].<result-shape>.<source-shape>`. The `_s`/`_u` sign and the
`_low`/`_high` half selector are in the mnemonic.

| WASM | `SimdOp` | `.ir` mnemonic |
|---|---|---|
| `i8x16.narrow_i16x8_s` / `_u` | `I8x16NarrowI16x8S` / `U` | `v.narrow_s.i8x16.i16x8` / `v.narrow_u.i8x16.i16x8` |
| `i16x8.narrow_i32x4_s` / `_u` | `I16x8NarrowI32x4S` / `U` | `v.narrow_s.i16x8.i32x4` / `v.narrow_u.i16x8.i32x4` |
| `i16x8.extend_low_i8x16_s` / `_u` | `I16x8ExtendLowI8x16S` / `U` | `v.extend_low_s.i16x8.i8x16` / `v.extend_low_u.i16x8.i8x16` |
| `i16x8.extend_high_i8x16_s` / `_u` | `I16x8ExtendHighI8x16S` / `U` | `v.extend_high_s.i16x8.i8x16` / `v.extend_high_u.i16x8.i8x16` |
| `i32x4.extend_low_i16x8_s` / `_u` | `I32x4ExtendLowI16x8S` / `U` | `v.extend_low_s.i32x4.i16x8` / `v.extend_low_u.i32x4.i16x8` |
| `i32x4.extend_high_i16x8_s` / `_u` | `I32x4ExtendHighI16x8S` / `U` | `v.extend_high_s.i32x4.i16x8` / `v.extend_high_u.i32x4.i16x8` |
| `i64x2.extend_low_i32x4_s` / `_u` | `I64x2ExtendLowI32x4S` / `U` | `v.extend_low_s.i64x2.i32x4` / `v.extend_low_u.i64x2.i32x4` |
| `i64x2.extend_high_i32x4_s` / `_u` | `I64x2ExtendHighI32x4S` / `U` | `v.extend_high_s.i64x2.i32x4` / `v.extend_high_u.i64x2.i32x4` |
| `i16x8.extmul_low_i8x16_s` / `_u` | `I16x8ExtMulLowI8x16S` / `U` | `v.extmul_low_s.i16x8.i8x16` / `v.extmul_low_u.i16x8.i8x16` |
| `i16x8.extmul_high_i8x16_s` / `_u` | `I16x8ExtMulHighI8x16S` / `U` | `v.extmul_high_s.i16x8.i8x16` / `v.extmul_high_u.i16x8.i8x16` |
| `i32x4.extmul_low_i16x8_s` / `_u` | `I32x4ExtMulLowI16x8S` / `U` | `v.extmul_low_s.i32x4.i16x8` / `v.extmul_low_u.i32x4.i16x8` |
| `i32x4.extmul_high_i16x8_s` / `_u` | `I32x4ExtMulHighI16x8S` / `U` | `v.extmul_high_s.i32x4.i16x8` / `v.extmul_high_u.i32x4.i16x8` |
| `i64x2.extmul_low_i32x4_s` / `_u` | `I64x2ExtMulLowI32x4S` / `U` | `v.extmul_low_s.i64x2.i32x4` / `v.extmul_low_u.i64x2.i32x4` |
| `i64x2.extmul_high_i32x4_s` / `_u` | `I64x2ExtMulHighI32x4S` / `U` | `v.extmul_high_s.i64x2.i32x4` / `v.extmul_high_u.i64x2.i32x4` |
| `i16x8.extadd_pairwise_i8x16_s` / `_u` | `I16x8ExtAddPairwiseI8x16S` / `U` | `v.extadd_pairwise_s.i16x8.i8x16` / `v.extadd_pairwise_u.i16x8.i8x16` |
| `i32x4.extadd_pairwise_i16x8_s` / `_u` | `I32x4ExtAddPairwiseI16x8S` / `U` | `v.extadd_pairwise_s.i32x4.i16x8` / `v.extadd_pairwise_u.i32x4.i16x8` |
| `i32x4.dot_i16x8_s` | `I32x4DotI16x8S` | `v.dot_s.i32x4.i16x8` |

#### A.3.7 Swizzle (dynamic byte permute)

| WASM | `SimdOp` | `.ir` mnemonic |
|---|---|---|
| `i8x16.swizzle` | `I8x16Swizzle` | `v.swizzle` |

(`i8x16.shuffle` — 16 *immediate* lane indices — is **not** a `SimdOp`; it is the dedicated
`SimdShuffle` node, §A.4, because its immediates are a list, not a scalar bakeable into one word.)

#### A.3.8 Float-lane arithmetic (float shapes)

Sign-agnostic mnemonics (no `_s`/`_u`), so they never collide with the integer ops even before the
shape tag disambiguates.

| WASM | `SimdOp` | `.ir` mnemonic |
|---|---|---|
| `<fs>.abs` (f32x4/f64x2) | `FAbs(fs)` | `v.abs.<fs>` |
| `<fs>.neg` | `FNeg(fs)` | `v.neg.<fs>` |
| `<fs>.sqrt` | `FSqrt(fs)` | `v.sqrt.<fs>` |
| `<fs>.ceil` | `FCeil(fs)` | `v.ceil.<fs>` |
| `<fs>.floor` | `FFloor(fs)` | `v.floor.<fs>` |
| `<fs>.trunc` | `FTrunc(fs)` | `v.trunc.<fs>` |
| `<fs>.nearest` | `FNearest(fs)` | `v.nearest.<fs>` |
| `<fs>.add` | `FAdd(fs)` | `v.add.<fs>` |
| `<fs>.sub` | `FSub(fs)` | `v.sub.<fs>` |
| `<fs>.mul` | `FMul(fs)` | `v.mul.<fs>` |
| `<fs>.div` | `FDiv(fs)` | `v.div.<fs>` |
| `<fs>.min` | `FMin(fs)` | `v.min.<fs>` |
| `<fs>.max` | `FMax(fs)` | `v.max.<fs>` |
| `<fs>.pmin` | `FPMin(fs)` | `v.pmin.<fs>` |
| `<fs>.pmax` | `FPMax(fs)` | `v.pmax.<fs>` |

#### A.3.9 Float-lane comparisons (float shapes) → a v128 lane mask

| WASM | `SimdOp` | `.ir` mnemonic |
|---|---|---|
| `<fs>.eq` | `FEq(fs)` | `v.eq.<fs>` |
| `<fs>.ne` | `FNe(fs)` | `v.ne.<fs>` |
| `<fs>.lt` | `FLt(fs)` | `v.lt.<fs>` |
| `<fs>.gt` | `FGt(fs)` | `v.gt.<fs>` |
| `<fs>.le` | `FLe(fs)` | `v.le.<fs>` |
| `<fs>.ge` | `FGe(fs)` | `v.ge.<fs>` |

#### A.3.10 Float ↔ int lane conversions (fixed constructors)

`v.<op>[_s|_u][_zero|_low].<result-shape>.<source-shape>`. All total (no trap); the `_zero`/`_low`
half/zeroing selector and the sign are in the mnemonic.

| WASM | `SimdOp` | `.ir` mnemonic |
|---|---|---|
| `i32x4.trunc_sat_f32x4_s` / `_u` | `I32x4TruncSatF32x4S` / `U` | `v.trunc_sat_s.i32x4.f32x4` / `v.trunc_sat_u.i32x4.f32x4` |
| `i32x4.trunc_sat_f64x2_s_zero` / `_u_zero` | `I32x4TruncSatF64x2SZero` / `UZero` | `v.trunc_sat_s_zero.i32x4.f64x2` / `v.trunc_sat_u_zero.i32x4.f64x2` |
| `f32x4.convert_i32x4_s` / `_u` | `F32x4ConvertI32x4S` / `U` | `v.convert_s.f32x4.i32x4` / `v.convert_u.f32x4.i32x4` |
| `f32x4.demote_f64x2_zero` | `F32x4DemoteF64x2Zero` | `v.demote_zero.f32x4.f64x2` |
| `f64x2.convert_low_i32x4_s` / `_u` | `F64x2ConvertLowI32x4S` / `U` | `v.convert_low_s.f64x2.i32x4` / `v.convert_low_u.f64x2.i32x4` |
| `f64x2.promote_low_f32x4` | `F64x2PromoteLowF32x4` | `v.promote_low.f64x2.f32x4` |

### A.4 `i8x16.shuffle` — the `SimdShuffle` node (16 immediate lane indices)

```
expr += simd.shuffle [ <int>,* ] <a-value> <b-value>       ; SimdShuffle(lanes, a, b)
```

`SimdShuffle(lanes: List(Int), a: Value, b: Value)` — the 16 immediate byte-lane indices (each
`0..31`, selecting a byte from the 32-byte concatenation `a ++ b`
([SIMD spec — `i8x16.shuffle`](https://webassembly.github.io/spec/core/syntax/instructions.html#vector-instructions)))
are a **bracketed, comma-separated int list**, followed by the two v128 operands. Example:

```
simd.shuffle [0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23] %a %b
```

The printer emits `lanes` in order; the parser reads the int list with a `parse_lane_list` (a
bracketed `expect_number` list, mirroring `parse_ref_init_list`) and then two `parse_value`s. **The
parser does NOT enforce list length 16 or index range `0..31`** — those are *typing* rules owned by
`validate` (04); the parser round-trips whatever list is written (contrast the `v128.const`
16-byte check, which is *structural* well-formedness of a literal, §A.2 and Deviations). This keeps
the parser a pure syntax layer and keeps the round-trip total.

### A.5 SIMD memory (bounds-checked through `rt_mem` — I6/D3a) — dedicated nodes

The SIMD-memory family is **dedicated `Expr` nodes** (the provisional pick — open Q (a); a
`MemLoad`'s `result: ValType` + `MemAccess` do not stretch to splat/extend/lane, so extending them
would be lossier than new nodes). The invariant they carry — **bounds-checked → trap
`MemoryOutOfBounds`** — is a runtime concern (06/07/08), not a text concern; this unit only renders
the shapes. All four reuse the **omit-when-zero `mem=` decorator** (§A.6 / Phase-5 §A.7) so a
single-memory (index-0) SIMD program is neutral, a **mandatory `offset=`** (like `mem.load`), and —
for the lane variants — a **mandatory `lane=`**.

```
expr += simd.load <loadkind> <addr> offset=<int> [ mem=<int> ]                    ; SimdLoad
      | simd.store <addr> <value> offset=<int> [ mem=<int> ]                       ; SimdStore
      | simd.load_lane <width> <addr> <vec> offset=<int> lane=<int> [ mem=<int> ]  ; SimdLoadLane
      | simd.store_lane <width> <addr> <vec> offset=<int> lane=<int> [ mem=<int> ] ; SimdStoreLane
```

`<width>` is a bare number token (`8`/`16`/`32`/`64`). `<loadkind>` is a single neutral word
resolved by `string_to_simd_load_kind`; `SimdLoadKind = V128 | Splat(width) | Extend(pack, signed)
| Zero(width)` (provisional §D), enumerated:

| WASM | `SimdLoadKind` | `<loadkind>` word |
|---|---|---|
| `v128.load` | `V128` | `v128` |
| `v128.load8_splat` | `Splat(8)` | `splat8` |
| `v128.load16_splat` | `Splat(16)` | `splat16` |
| `v128.load32_splat` | `Splat(32)` | `splat32` |
| `v128.load64_splat` | `Splat(64)` | `splat64` |
| `v128.load8x8_s` / `_u` | `Extend(P8x8, s)` | `extend8x8_s` / `extend8x8_u` |
| `v128.load16x4_s` / `_u` | `Extend(P16x4, s)` | `extend16x4_s` / `extend16x4_u` |
| `v128.load32x2_s` / `_u` | `Extend(P32x2, s)` | `extend32x2_s` / `extend32x2_u` |
| `v128.load32_zero` | `Zero(32)` | `zero32` |
| `v128.load64_zero` | `Zero(64)` | `zero64` |

| WASM | node | `.ir` |
|---|---|---|
| `v128.load off` | `SimdLoad(0, V128, %a, off)` | `simd.load v128 %a offset=<off>` |
| `v128.load32_splat off (mem 1)` | `SimdLoad(1, Splat(32), %a, off)` | `simd.load splat32 %a offset=<off> mem=1` |
| `v128.load8x8_u off` | `SimdLoad(0, Extend(P8x8, False), %a, off)` | `simd.load extend8x8_u %a offset=<off>` |
| `v128.load64_zero off` | `SimdLoad(0, Zero(64), %a, off)` | `simd.load zero64 %a offset=<off>` |
| `v128.store off` | `SimdStore(0, %a, %v, off)` | `simd.store %a %v offset=<off>` |
| `v128.load16_lane off L` | `SimdLoadLane(0, 16, %a, off, L, %v)` | `simd.load_lane 16 %a %v offset=<off> lane=<L>` |
| `v128.store8_lane off L (mem 2)` | `SimdStoreLane(2, 8, %a, off, L, %v)` | `simd.store_lane 8 %a %v offset=<off> lane=<L> mem=2` |

Spec: [SIMD memory instructions](https://webassembly.github.io/spec/core/syntax/instructions.html#vector-instructions)
(`v128.load`/`store`, `loadN_splat`, `loadMxN_{s,u}`, `loadN_zero`, `loadN_lane`/`storeN_lane`).
The `Extend` pack tag (`P8x8`/`P16x4`/`P32x2`) is whatever the keystone names it; §A spells the
word (`extend8x8_s` …) and `string_to_simd_load_kind` maps it — a cross-unit seam (§Seams).

### A.6 The `lane=` / `mem=` / `offset=` decorators (reuse)

- **`offset=<int>`** — mandatory on every SIMD load/store, identical to `mem.load`/`mem.store`
  (Phase-2). Parsed by `expect_word "offset"` + `=` + `expect_number`.
- **`mem=<int>`** — the omit-when-zero memory-index decorator (Phase-5 §A.7), reused verbatim via
  the existing `print_memidx` / `parse_opt_kv(_, "mem")`. So a single-memory SIMD program is
  byte-identical to one with the decorator elided.
- **`lane=<int>`** — mandatory on `simd.load_lane`/`simd.store_lane` (the destination/source lane
  index). A new **mandatory** decorator helper `parse_lane` (mirroring `parse_seg`:
  `expect_word "lane"` + `=` + `expect_number`) and `print_lane` (` lane=<n>`). It is recognised
  **only when immediately followed by `=`** — `lane` is not an expression keyword — so, like
  `seg`/`mem`/`offset`, it cannot swallow a following statement in a `let`/`charge` continuation.

### A.7 memory64 & cross-module imports — confirmed unchanged (no new spelling)

- **memory64.** A 64-bit memory is `memory i64 (min N [max M])` and an `i64`-addressed load/store
  is `mem.load i64 8 %a offset=0 mem=1` — **exactly the Phase-5 spelling** (`P5-02` §A.3.1 / §A.7,
  `refs_bulk.ir`). Phase 6 unfreezes the *runtime* of `Idx64` (05/08) but adds **no `.ir` change**.
  This unit adds a confirming round-trip (§DoD 6) so a memory64 `.ir` regression fails a test
  rather than surfacing only at conformance.
- **Cross-module function import.** `import "A" "f" : (params) -> (results)` — the existing
  `ImportFn(capability="A", name="f", ty)`, **byte-identical to a host import**. The linker-built
  dispatch closure (`Provided.ProvidedFunc.call`) is a `runtime/link.gleam` value, not an IR field,
  so there is **nothing new to print**. This unit asserts the byte-identical round-trip (§DoD 6).

---

## B. Printer wiring (concrete Gleam sketches)

The printer's `*_to_string` tables remain the single source of truth for spellings; the parser's
`string_to_*` / keyword dispatch mirror them, and the full-surface round-trip proves they agree.
Sketches (illustrative — final names per the frozen types):

**Value type & literal** — extend `print_valtype`, `print_value`:
```gleam
// print_valtype: one new arm
TV128 -> "v128"

// print_value: one new arm — the raw 16 bytes, reusing the data-segment hex renderer.
ConstV128(bytes) -> "v128.const " <> print_hexbytes(bytes)   // "0x" <> 32 lowercase hex digits
```

**The `Simd` op mnemonic** — a big `simdop_to_string` mirroring `numop_to_string`:
```gleam
/// Renders a SIMD op as its neutral `v.<mnemonic>[.<shape>][.<lane>]` spelling (D6 — never the
/// WASM opcode `i32x4.add`). The lane-uniform ops carry a `simd_shape_str` tag; the fixed
/// conversion/narrow/widen/dot/pairwise constructors are literal strings; extract/replace bake
/// the lane index. The single source of truth for every SimdOp spelling.
fn simdop_to_string(op: SimdOp) -> String {
  case op {
    SAdd(s) -> "v.add." <> simd_shape_str(s)
    FAdd(s) -> "v.add." <> simd_shape_str(s)          // disambiguated by the shape tag (i* vs f*)
    SMinS(s) -> "v.min_s." <> simd_shape_str(s)
    FMin(s) -> "v.min." <> simd_shape_str(s)
    VBitselect -> "v.bitselect"
    VAnyTrue -> "v.any_true"
    SSplat(s) -> "v.splat." <> simd_shape_str(s)
    SExtractLaneS(s, lane) ->
      "v.extract_lane_s." <> simd_shape_str(s) <> "." <> int.to_string(lane)
    I8x16NarrowI16x8S -> "v.narrow_s.i8x16.i16x8"
    I32x4DotI16x8S -> "v.dot_s.i32x4.i16x8"
    // … every constructor, per §A.3 …
  }
}

fn simd_shape_str(s: SimdShape) -> String {
  case s {
    I8x16 -> "i8x16"  I16x8 -> "i16x8"  I32x4 -> "i32x4"
    I64x2 -> "i64x2"  F32x4 -> "f32x4"  F64x2 -> "f64x2"
  }
}
```

**New `print_expr` arms**:
```gleam
Simd(op, args) -> "simd " <> simdop_to_string(op) <> " " <> value_list(args)
SimdShuffle(lanes, a, b) ->
  "simd.shuffle [" <> string.join(list.map(lanes, int.to_string), ", ") <> "] "
  <> print_value(a) <> " " <> print_value(b)
SimdLoad(mem, kind, addr, offset) ->
  "simd.load " <> print_simd_load_kind(kind) <> " " <> print_value(addr)
  <> " offset=" <> int.to_string(offset) <> print_memidx(mem)
SimdStore(mem, addr, value, offset) ->
  "simd.store " <> print_value(addr) <> " " <> print_value(value)
  <> " offset=" <> int.to_string(offset) <> print_memidx(mem)
SimdLoadLane(mem, width, addr, offset, lane, vec) ->
  "simd.load_lane " <> int.to_string(width) <> " " <> print_value(addr) <> " "
  <> print_value(vec) <> " offset=" <> int.to_string(offset)
  <> print_lane(lane) <> print_memidx(mem)
SimdStoreLane(mem, width, addr, offset, lane, vec) ->  // as above, "simd.store_lane"
```
`print_lane(lane) = " lane=" <> int.to_string(lane)` (mandatory, mirrors `print_seg`);
`print_simd_load_kind` maps each `SimdLoadKind` to its word (§A.5).

## C. Parser wiring (concrete Gleam sketches)

**`parse_valtype`** — one arm (`"v128" -> Ok(#(TV128, rest))`). **`parse_value`** — one arm:
```gleam
"v128.const" -> parse_v128_const(rest)
```
```gleam
/// Parses `v128.const 0x<32 hex>` into `ConstV128` (D5-exact raw bytes). TOTAL. Reuses the
/// data-segment hex path (`parse_hexbytes` → `hex_to_bytes`, which already rejects odd-length),
/// then enforces the structural 16-byte length so every `ConstV128` holds exactly 16 bytes.
/// A non-`0x`/odd/≠16-byte payload is `BadNumberLiteral` — no new ParseError variant.
fn parse_v128_const(toks) -> Result(#(Value, List(PToken)), ParseError) {
  use #(bytes, rest) <- result.try(parse_hexbytes(toks))
  case bit_array.byte_size(bytes) {
    16 -> Ok(#(ConstV128(bytes), rest))
    _ -> Error(BadNumberLiteral(line_of(toks), col_of(toks), "v128.const (need 16 bytes)"))
  }
}
```

**`parse_expr`** — six new keyword arms (fits the exact-string `case kw` dispatch verbatim; every
new keyword is a distinct `TWord`):
```gleam
"simd"           -> parse_simd(rest)            // op word via string_to_simdop, then value list
"simd.shuffle"   -> parse_simd_shuffle(rest)    // [lanes] a b
"simd.load"      -> parse_simd_load(rest)       // loadkind addr offset= [mem=]
"simd.store"     -> parse_simd_store(rest)      // addr value offset= [mem=]
"simd.load_lane" -> parse_simd_load_lane(rest)  // width addr vec offset= lane= [mem=]
"simd.store_lane"-> parse_simd_store_lane(rest) // width addr vec offset= lane= [mem=]
```
```gleam
/// Parses `simd <simdop> (args)`. Mirrors `parse_num`: read the op word, resolve via
/// `string_to_simdop` (UnknownOp on a bad mnemonic), then a value list. Arity is NOT checked
/// (syntax only). TOTAL.
fn parse_simd(toks) -> Result(#(Expr, List(PToken)), ParseError) {
  case toks {
    [PToken(TWord(w), l, c), ..rest] ->
      case string_to_simdop(w) {
        Ok(op) -> { use #(args, r) <- result.try(parse_value_list(rest)); Ok(#(Simd(op, args), r)) }
        Error(_) -> Error(UnknownOp(l, c, w))
      }
    [PToken(t, l, c), ..] -> Error(UnexpectedToken(l, c, "simd op", describe(t)))
    [] -> Error(UnexpectedEnd("simd op"))
  }
}
```
`string_to_simdop` mirrors `simdop_to_string`: split the word on `"."`, match the family, resolve
the `simd_shape` (via `parse_simd_shape`), and — for the seven shared int/float mnemonics — select
the constructor by `is_int_shape(shape)`; the fixed conversion/narrow/dot strings match literally;
extract/replace parse the trailing lane int. Any unrecognised mnemonic/shape/lane is `Error(Nil)`
→ surfaced as `UnknownOp` by `parse_simd`. `parse_simd_load` reads a `<loadkind>` word via
`string_to_simd_load_kind`, then `parse_value` (addr), a mandatory `offset=`, and
`parse_opt_kv(_, "mem")`. `parse_simd_load_lane`/`parse_simd_store_lane` read a bare
`expect_number` width, addr, vec, a mandatory `offset=`, a mandatory `parse_lane`, and optional
`mem=`. `parse_simd_shuffle` reads `parse_lane_list` (bracketed int list) then two values.

**Totality (unchanged invariant).** Every new branch reuses the existing total helpers
(`parse_value`, `parse_value_list`, `expect_word`, `expect_number`, `parse_hexbytes`,
`parse_opt_kv`) — each returns `Error` (never panics) on the empty/wrong token. Unknown SIMD
mnemonics / load-kinds surface as `UnknownOp`; a `v128` where a reftype is required is
`UnexpectedToken`; a non-16-byte `v128.const` is `BadNumberLiteral`. **No new `ParseError`
variant is needed** — the existing six suffice (matching P5-02).

---

## D. Backward-compat & conformance-neutrality (the I7 story for `.ir`)

Every IR4 addition is a **new keyword** (`v128`, `v128.const`, `simd`, `simd.shuffle`,
`simd.load*`, `simd.store*`) or a **new arm on `print_valtype`/`print_value`**; **no existing
spelling changes.** A Phase-1..5-shaped module — no `TV128`, no `ConstV128`, no `Simd*` node, a
single 32-bit memory, no cross-module import — therefore prints **byte-identically to Phase-5**
under this unit's printer. In particular:

| Construct | Phase-5-shaped module prints as | Byte-identical? |
|---|---|---|
| any non-v128 valtype | unchanged (`i32`/`funcref`/…) | yes |
| any non-SIMD expr | unchanged | yes |
| single 32-bit memory | `memory (min N [max M])` | yes |
| memory64 memory | `memory i64 (min N)` | yes (P5 spelling) |
| `i64`-addressed load/store | `mem.load i64 … mem=1` | yes (P5 spelling) |
| cross-module / host function import | `import "…" "…" : …` | yes (P5 `ImportFn`) |

The DoD asserts this concretely: the five existing goldens re-print byte-identically and the
Phase-5 `legacy_module_byte_identical_test` stays green **verbatim** (its expected string is
unchanged). This is the `.ir`-level face of I7 (byte-identical-by-default); the emitted-Core
byte-identity headline is `emit_core`'s (06).

---

## E. Worked example — the hand-authored Phase-6 golden (`simd.ir`)

A single module exercising, by hand, the SIMD/v128 surface — written by **reading §A** (never
printer-generated — D7), with an independently hand-built expected `Module` in the test. It
includes a `v128.const` with a **NaN-payload lane, a `-0.0` lane, a `+Inf` lane, and a normal
lane** (the D5 fidelity proof), integer + float lane ops, extract/replace/splat, a shuffle, a
swizzle, a conversion + a narrow + a dot, and the SIMD-memory family at memory index 0 **and** a
second (memory64) memory (confirming i64 addressing coexists).

```
; simd — a hand-authored Phase-6 golden. Exercises, in ONE module and by reading the grammar
; delta (specs/phase-6/ir-grammar-delta.md), never printer-generated (D7): the v128 value type,
; a v128.const carrying a NaN-payload lane / a -0.0 lane / a +Inf lane / a normal lane (D5
; byte-exact), integer + float lane arithmetic, comparisons yielding masks, bitmask / all_true,
; splat / extract / replace lane, shuffle (16 immediates) + swizzle, a trunc_sat conversion, a
; narrow, a dot, and the SIMD memory family (load / store / load_splat / load_extend / load_zero
; / load_lane / store_lane) at memory 0 AND a memory64 memory. Independent oracle vs collusion.
module @simd {
  numerics true
  memory (min 1 max 4)
  memory i64 (min 1)
  func @kernel ( %p:i32, %vin:v128 ) -> (v128) {
    ; f32x4 lanes [0x7fc00001 (qNaN+payload), 0x80000000 (-0.0), 0x7f800000 (+Inf), 0x3f800000 (1.0)]
    let (%c) = values (v128.const 0x0100c07f000000800000807f0000803f) ;
    let (%a) = simd v.add.i32x4 (%vin, %c) ;
    let (%mn) = simd v.min_s.i16x8 (%a, %vin) ;
    let (%sh) = simd v.shr_u.i32x4 (%a, i32.const 3) ;
    let (%mask) = simd v.lt_s.i32x4 (%a, %vin) ;
    let (%bm) = simd v.bitmask.i32x4 (%mask) ;
    let (%at) = simd v.all_true.i8x16 (%a) ;
    let (%fa) = simd v.add.f32x4 (%c, %vin) ;
    let (%fq) = simd v.sqrt.f64x2 (%fa) ;
    let (%pm) = simd v.pmin.f32x4 (%fa, %c) ;
    let (%sp) = simd v.splat.i32x4 (%p) ;
    let (%rl) = simd v.replace_lane.f32x4.2 (%fa, f32.const 0x3f800000) ;
    let (%el) = simd v.extract_lane_u.i8x16.7 (%a) ;
    let (%sw) = simd v.swizzle (%a, %sp) ;
    let (%sf) = simd.shuffle [0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23] %a %vin ;
    let (%ts) = simd v.trunc_sat_s.i32x4.f32x4 (%fa) ;
    let (%nw) = simd v.narrow_s.i8x16.i16x8 (%a, %mn) ;
    let (%dt) = simd v.dot_s.i32x4.i16x8 (%mn, %mn) ;
    let (%ld) = simd.load v128 %p offset=0 ;
    let (%lsp) = simd.load splat32 %p offset=0 mem=0 ;
    let (%lex) = simd.load extend8x8_u %p offset=0 ;
    let (%lz) = simd.load zero64 %p offset=0 ;
    let (%ll) = simd.load_lane 16 %p %a offset=0 lane=3 ;
    let () = simd.store %p %a offset=0 ;
    let () = simd.store_lane 8 %p %a offset=0 lane=0 ;
    let (%big) = mem.load i64 8 %p offset=0 mem=1 ;
    return (%sf)
  }
}
```

The expected `Module` is built by hand in `roundtrip_test.gleam` (a `simd_module()` builder). In
particular the v128 const is built as the exact 16-byte `BitArray`
`<<0x01,0x00,0xc0,0x7f, 0x00,0x00,0x00,0x80, 0x00,0x00,0x80,0x7f, 0x00,0x00,0x80,0x3f>>`, and the
test asserts `parse_module(read_golden("simd.ir")) == Ok(simd_module())` **plus**
`check_roundtrip(simd_module())` (print then re-parse stable). Two independently authored artifacts
agreeing is what defeats printer/parser collusion; the by-hand byte layout of the NaN-payload lane
is what proves D5 fidelity survives the round-trip.

---

## Effect / soundness / security note

- **Totality is the security property.** `parse_module` runs on **untrusted text** (a dumped
  `.ir`, a fixture, a fuzz input). A panic on malformed input is a denial-of-service / sandbox
  concern, so the parser stays total across the entire IR4 extension: every new branch reuses
  helpers that return typed `ParseError`, never `let assert`/`panic`/`todo`. The negative/fuzz
  corpus (§DoD 5) proves it — including the SIMD-specific garbage (a bad `v128.const` length, an
  unknown `simd` mnemonic, an unknown load-kind, a missing `lane=`/`offset=`, a bad shape tag).
- **No new capability surface.** The printer/parser are pure `String ↔ Module` functions with no
  I/O, no ambient authority, and no evaluation. They do not link a runtime, build a dispatch
  closure, or bounds-check a SIMD memory access — the SIMD-memory bounds-check → trap
  (`rt_mem`/`emit_core`), the D3a no-ambient-`apply` cross-module dispatch (`link`/`emit_core`),
  and the v128 opacity in Safe mode live downstream (I6), not here. This unit only *renders and
  re-reads names and shapes*.
- **v128 bit-exactness carries over from the float discipline.** `ConstV128` prints as raw
  zero-preserving `0x`-hex bytes, so NaN-payload lanes, `-0.0` lanes, and saturation bit patterns
  are lossless (D5) — the same guarantee `ConstF32`/`ConstF64` already have, one width up. The
  16-byte-length check keeps every parsed `ConstV128` lane-decodable downstream.
- **Effect classification is not this unit's concern.** `ir/effect.gleam` (owned by the keystone
  01) classifies `Simd` as **pure** (participates in const-fold/DCE like `Num`) and the
  SIMD-memory nodes as **barriers** (effectful, non-reorderable). The printer/parser are
  effect-agnostic — they render/read structure only, so an effect-classification change never
  touches this unit.
- **Syntax, not semantics.** The parser does **not** validate lane-index ranges, shuffle-list
  length/range, `SimdShape`/op compatibility, v128 operand arity, or memory-index bounds — it
  builds a well-formed `Module` and defers all meaning to `validate`/`lower`/`emit_core`/`rt_simd`.
  A syntactically valid but semantically nonsensical `.ir` (e.g. `simd v.add.i32x4 (%a)` with one
  operand, or a shuffle with 17 lanes) parses fine and is rejected later; that separation is
  intentional (D4/D7). The one exception is the `v128.const` 16-byte length (a literal
  well-formedness check, argued in Deviations).

---

## Deviations from the provisional surface (ARGUED)

1. **v128 textual encoding = raw hex bytes only (canonical), `v128.const 0x<32 hex>`.** The brief
   offered hex-bytes / i8x16 / i32x4 forms; PROVISIONAL-SURFACE §A leaves it open. I fix **one**
   canonical spelling — the raw 16 little-endian bytes — because (a) it is the *only* form that is
   byte-exact for **every** bit pattern with no interpretation, so NaN payloads / `-0.0` /
   saturation lanes survive trivially (D5 — the load-bearing requirement for the SIMD differential
   oracle); (b) it is neutral (D6) — "a 128-bit value's bytes", not a WASM lane-typed literal; (c)
   it reuses the existing `print_hexbytes`/`hex_to_bytes` machinery verbatim and matches the
   established `ConstF32(bits)`-as-raw-hex discipline. A typed-lane authoring form would be a
   *second* spelling that (for float lanes) re-introduces float parsing and its rounding hazards.
   **Reconciliation may add a parser-only typed-lane input alias** (printer stays raw hex) for
   ergonomics; the default is raw-hex-only. (Flagged §OQ 3.)
2. **The parser enforces `ConstV128` = exactly 16 bytes.** PROVISIONAL-SURFACE documents
   "`ConstV128(bytes: BitArray) // NEW — exactly 16 bytes" but assigns no owner for the check. I
   place it in the parser as a *structural* literal-well-formedness check (the same class as
   rejecting odd-length hex), not a semantic one, because `ConstV128`'s type contract promises 16
   bytes and the downstream lane decode (`<<a:32/little, …>>` in `rt_simd`/`emit_core`) assumes it —
   a wrong-length literal is a corrupt value, not a mis-typed program. This deliberately **differs**
   from how I treat shuffle-lane counts and lane-index ranges (left to `validate`), because those
   are *typing* rules over structurally-fine operands, whereas a v128 literal's byte count is
   intrinsic to the value's representation. Uses the existing `BadNumberLiteral` — no new error.
3. **SIMD op mnemonics use the neutral `v.<op>[.<shape>][.<lane>]` scheme, not the WASM opcode
   strings.** PROVISIONAL-SURFACE §C names the `SimdOp` *constructors* but not their `.ir`
   spellings. I derive spellings by the same transform the IR already applies to scalars
   (`i32.add` → `i.add.32`): the vector namespace `v.`, then the op, then the lane-shape tag. This
   keeps D6 (no `i32x4.add` opcode string in the IR text) and mirrors `numop_to_string`. The
   lane-shape tags (`i8x16`…`f64x2`) are retained as *generic lane geometry* (N×W), which I argue is
   as neutral as the scalar width tag `32` — a future vector-capable frontend reuses them.
4. **The int/float shape tag selects the `S*`-vs-`F*` constructor for the seven shared mnemonics**
   (`add`/`sub`/`mul`/`neg`/`abs`/`eq`/`ne`). This makes the spelling **bijective over the valid
   surface** (`v.add.i32x4`↔`SAdd(I32x4)`, `v.add.f32x4`↔`FAdd(F32x4)`). **Recommendation to the
   keystone (P6-01):** give the integer-family and float-family `SimdOp` constructors **disjoint
   shape types** (e.g. `SAdd(IntShape)` / `FAdd(FloatShape)`) so the semantically-impossible
   `SAdd(F32x4)` is *unrepresentable* — then the spelling is bijective over the whole enum, not just
   the valid surface, and no "impossible value fails to round-trip" edge exists. If P6-01 keeps a
   single `SimdShape`, my selection rule still round-trips every valid module; only the never-
   constructed invalid combos (an int op on a float shape) fall outside the bijection, which no
   corpus and no lowering produces. (Flagged §Seams.)
5. **`i8x16.shuffle` is a dedicated `simd.shuffle` node/keyword; `i8x16.swizzle` is a `Simd` op
   (`v.swizzle`).** PROVISIONAL-SURFACE §D already proposes `SimdShuffle` as a dedicated `Expr`;
   I adopt it because 16 immediate indices are a *list* that does not bake into a single op word,
   whereas swizzle takes only dynamic v128 operands (no immediates) and rides `Simd` cleanly. The
   shuffle lane list is spelled as a bracketed int list (mirroring the `elem` init list), **not**
   length/range-checked by the parser (validate's job) — deliberately different from the v128 const
   length check (deviation 2), for the reason argued there.
6. **SIMD-memory family = dedicated nodes with a single-word `loadkind` + a mandatory `lane=`
   decorator.** I adopt the provisional dedicated-nodes pick (open Q (a)) and fix the *textual*
   shape: the `SimdLoadKind` is one neutral word (`v128`/`splat32`/`extend8x8_u`/`zero64`) resolved
   by a `string_to_simd_load_kind` table (mirroring `string_to_convop`), the width is a bare number
   token, and `lane=` is a new **mandatory** decorator (mirroring `seg=`). This keeps `parse_expr`'s
   exact-string dispatch (six clean keywords) and reuses the omit-when-zero `mem=` machinery. If
   reconciliation instead makes the SIMD-memory family *extended `MemLoad`/`MemStore` access kinds*
   (open Q (a)'s alternative), this section's node spellings collapse into the `mem.load`/
   `mem.store` grammar — I flag the seam and lean dedicated-nodes (cleaner, lossless).

---

## Verification — Definition of Done (D8)

Tests assert the **D7 contract and the §A grammar**, not whatever the printer happens to emit (no
change-detector tests). Spec-objective: the corpus is derived from the **fixed-width SIMD
instruction set** (what forms must exist — every standardized lane op, every SIMD-memory kind, the
v128 value/const, the shuffle immediates) and the round-trip property `parse(print(m)) == m` is the
algebraic invariant asserted.

1. **Round-trip property** holds via `module_equal` (`==`, bit-exact by construction — D5) on the
   extended full-surface corpus:
   - the `TV128` valtype in **every** valtype position (param/local/global/functype/`mem.load`
     result);
   - a `ConstV128` in `value` position with the **NaN-payload / `-0.0` / `+Inf` / normal** lanes,
     **and** an all-zero and an all-ones v128 (byte-exactness at the boundaries);
   - **every `SimdOp` constructor** carried by `Simd` — enumerate via a `simd_op_corpus()` that
     lists one op per constructor across all applicable shapes (int arithmetic/compare/shift/
     bitmask/all_true/avgr/mul, the shape-agnostic bitwise + any_true, splat, extract_s/extract_u/
     replace at multiple lanes, float arithmetic/compare/pmin/pmax/sqrt/rounding, every
     narrow/extend/extmul/extadd_pairwise/dot/q15/popcnt, every trunc_sat/convert/demote/promote,
     swizzle) — each round-trips;
   - `SimdShuffle` with a 16-index list (and a 0-length and a 17-length list — the parser
     round-trips any length, since it does not length-check);
   - **every SIMD-memory node**: `SimdLoad` at each `SimdLoadKind` (`V128`, `Splat(8/16/32/64)`,
     `Extend(P8x8/P16x4/P32x2, s/u)`, `Zero(32/64)`), `SimdStore`, `SimdLoadLane`/`SimdStoreLane`
     at each width (8/16/32/64) and several lane indices, **each at memory index 0 (`mem=`
     omitted) and non-zero**;
   - a **memory64** memory + an `i64`-addressed `mem.load`/`store` coexisting with SIMD (confirms
     the inherited P5 spelling is untouched);
   - a **cross-module** function import (`ImportFn` with a non-`spectest` module name) round-trips
     byte-identically.
2. **Golden suite (independent oracle).** The hand-authored `simd.ir` (§E) parses to its by-hand
   expected `Module` and re-prints + re-parses stably (`check_roundtrip`). The **five** existing
   goldens `add`/`sum_to`/`fib`/`mem_table`/`refs_bulk` **still parse** to their expected modules
   and **re-print byte-identically** — proving the IR4 growth perturbed no legacy spelling.
3. **Discrimination tests** (prove no new field is dropped — each pair round-trips to **distinct**
   `Module`s):
   - `Simd(SAdd(I32x4), …)` vs `Simd(FAdd(F32x4), …)` (the shape tag selects the int/float family;
     spellings `v.add.i32x4` vs `v.add.f32x4` are distinct);
   - `SExtractLaneS(I8x16, 0)` vs `SExtractLaneS(I8x16, 15)` (lane immediate not dropped);
   - `SExtractLaneS(I8x16, 3)` vs `SExtractLaneU(I8x16, 3)` (sign not dropped);
   - `SimdShuffle([0..15])` vs `SimdShuffle([16..31])` (lane list not dropped);
   - `SimdLoad(_, V128, …)` vs `Splat(32)` vs `Zero(32)` vs `Extend(P8x8, True)` (kind not dropped);
   - `SimdLoadLane(_, 8, …, lane:0, …)` vs `SimdLoadLane(_, 32, …, lane:3, …)` (width **and** lane
     not dropped);
   - a `SimdStore` at `mem=0` vs `mem=1` (the memidx decorator not dropped);
   - two `ConstV128`s differing in a **single NaN-payload bit** round-trip to distinct `Module`s
     (D5 lane-payload distinctness — the SIMD analogue of `nan_payloads_are_distinct`);
   - a `v128` param vs an `i64` param (valtype not conflated).
4. **v128 bit-fidelity + coexistence.** A dedicated test builds a `ConstV128` for a signaling NaN,
   a quiet NaN with a distinct payload, `-0.0`, `+0.0`, `+Inf`, `-Inf`, and a subnormal lane, and
   asserts each round-trips to the byte-identical `BitArray`; a v128 global alongside the existing
   `ConstF32`/`ConstF64` NaN cases proves the numeric-fidelity tests still pass with the new value.
5. **Negative / fuzz corpus** returns the expected typed `ParseError` and **none panics**
   (totality): `v128.const 0xdead` (short — `BadNumberLiteral`), `v128.const 0x…{34 hex}` (too
   long — `BadNumberLiteral`), `simd v.bogus.i32x4 ()` (unknown mnemonic — `UnknownOp`),
   `simd v.add.i128x1 ()` (bad shape — `UnknownOp`), `simd v.extract_lane_s.i8x16.x (…)` (non-int
   lane — `UnknownOp`), `simd.load frob %a offset=0` (unknown load-kind — `UnknownOp`/
   `UnexpectedToken`), `simd.load v128 %a` (missing `offset=` — `UnexpectedEnd`/`UnexpectedToken`),
   `simd.load_lane 16 %a %v offset=0` (missing `lane=` — `UnexpectedEnd`/`UnexpectedToken`),
   `simd.shuffle 0 1 %a %b` (missing `[` — `UnexpectedToken`), and `func @f (%x:v128q) …` (bad
   valtype — `UnexpectedToken`). Reaching the end of the garbage battery without crashing the
   runner is the totality proof; fold them into the existing
   `negative_garbage_inputs_never_panic_test` and/or named per-variant tests.
6. **Byte-identity (I7).** The Phase-5 `legacy_module_byte_identical_test` stays green with its
   expected string **unchanged**; add a check that each of the five prior goldens re-prints to its
   exact prior text; add a memory64 + cross-module-import module and assert its printed `.ir`
   contains **no** SIMD/v128 token (the additions are inert for a non-SIMD module).
7. **Build hygiene.** `gleam format --check src test` clean; `gleam build` has **ZERO warnings**
   (no `todo` / placeholder arm may remain in printer or parser — every exhaustive match over
   `ValType`/`Value`/`Expr`/`SimdOp`/`SimdShape`/`SimdLoadKind` is fully implemented); `gleam test`
   green (≥ the current count; every prior round-trip/golden test stays green).
8. **Docs (D8).** Every new/changed public and private function documented: `simdop_to_string`/
   `string_to_simdop`, `simd_shape_str`/`parse_simd_shape`/`is_int_shape`, `print_simd_load_kind`/
   `string_to_simd_load_kind`, `print_lane`/`parse_lane`, `print_lane_list`/`parse_lane_list`,
   `print_v128_const`/`parse_v128_const`, `parse_simd`/`parse_simd_load`/`parse_simd_store`/
   `parse_simd_load_lane`/`parse_simd_store_lane`/`parse_simd_shuffle`, and the updated doc comments
   on `print_valtype`/`print_value`/`print_expr`/`parse_valtype`/`parse_value`/`parse_expr` — each
   stating the contract, the `Ok`/`Error` semantics, and (for the parser) why it cannot panic.
9. **Grammar reconciled.** `specs/phase-6/ir-grammar-delta.md` exists and matches the
   implementation exactly (§A is its content), cross-linked from `specs/phase-5/ir-grammar-delta.md`
   like the Phase-2/5 deltas.

**Proving the goal:** (a) full-surface round-trip green (every `SimdOp`, every SIMD-memory kind,
the v128 value/const, shuffle) + (b) the hand-authored `simd.ir` parsing *and* re-printing stably
defeat printer/parser collusion; (c) the discrimination tests prove no new field is silently
dropped; (d) the v128 NaN/`-0.0`/`±Inf` bit-fidelity test proves D5 survived one width up; (e) the
negative corpus returning typed errors proves totality held across the extension; (f) the
byte-identity tests prove the IR4 growth is conformance-neutral by default (I7).

## What this unit leaves

Once `.ir` round-trips the IR4 surface, every Phase-6 stage regains its golden-file boundary for
the new surface:

- **05 (lower)** can golden-test "WASM AST4 → IR4" by emitting `.ir` and diffing against a
  hand-written expected `.ir` (SIMD op lowering, the SIMD-memory nodes, the `Idx64` address-width
  threading, cross-module import lowering).
- **06 (emit_core)** can be driven from a hand-written IR4 `.ir` fixture (a SIMD slice, a
  v128-const, a SIMD-memory op at a non-zero memory index, an `i64`-addressed load) — an end-to-end
  backend test with no frontend needed.
- **07 (rt_simd)** can snapshot the IR of a `simd/*.wast` module at any seam and hand-author a v128
  const with an exact NaN-payload lane to feed a differential lane test.
- **10/11 (conformance)** can dump/load IR4 at any seam for differential tests and snapshot the IR
  of a SIMD spec-suite module.

This unit gates none of them (the round-trip is a property, not a bound interface), so it can land
any time after `«IR4-FROZEN»`.

## Cross-unit seams & open questions (for reconciliation)

- **SEAM — the `SimdOp` enum boundary is owned by P6-01** (`«IR4-FROZEN»`). This unit's spelling
  table (§A.3) is authoritative for the `.ir` *mnemonics* and must track whatever constructor set
  01 freezes; §A.3 is written against PROVISIONAL-SURFACE §C. If 01 splits/merges a constructor
  (e.g. folds the `_low`/`_high` extend halves into a field), 02 re-spells to stay bijective. The
  `SimdOp`→`rt_simd`-function binding is a **different** namespace owned by 06 — not this unit.
- **SEAM — the int/float shape-type decision (Deviation 4).** Recommend disjoint `IntShape`/
  `FloatShape` in 01 so `SAdd(F32x4)` is unrepresentable; 02's spelling is bijective either way.
- **SEAM — the full-width `extract_lane` constructor (Deviation, §A.3.2 †).** 01/03 fix which
  constructor `i32x4.extract_lane`/`i64x2`/`f32x4`/`f64x2` map to (sign-free); 02 spells it
  bijectively per (constructor, shape, lane).
- **SEAM — the `SimdLoadKind` shape (open Q (a)).** If reconciliation makes the SIMD-memory family
  *extended `MemLoad`/`MemStore` access kinds* instead of dedicated nodes, §A.5's node spellings
  collapse into the `mem.load`/`mem.store` grammar. 02 leans dedicated-nodes (cleaner, lossless);
  flag the seam so 01/03/06/07 agree before 02 spells it.
- **OQ 1 — new `TrapReason`?** PROVISIONAL-SURFACE says likely **none** (SIMD is total; SIMD memory
  + memory64 reuse `MemoryOutOfBounds`; unlinkable is a link-time error, not a runtime trap). If 01
  adds one, add exactly one snake_case arm to `trapreason_to_string`/`string_to_trapreason` — no
  design impact.
- **OQ 2 — typed-lane `v128.const` input alias?** The default is raw-hex-only (Deviation 1). If
  reconciliation wants author ergonomics, add a *parser-only* `v128.const i32x4 a b c d` (and the
  other shapes) alias that desugars to the same 16 bytes; the printer stays raw hex so canonical
  form is unambiguous and byte-exact. I lean raw-hex-only.
- **OQ 3 — lane-shape tag spelling.** I use `i8x16`…`f64x2` (the standard lane geometry) as neutral
  tags (Deviation 3). If reconciliation deems them too WASM-ish, a fully-neutral alternative is
  `<elem>.<count>` (`i8.16`, `f64.2`); I lean the standard notation (readable, unambiguous, generic).
- **Ownership of `roundtrip_test.gleam` between P6-01 and P6-02.** As in Phases 2/5, P6-01 minimally
  updates the constructors to compile; P6-02 owns the real corpus + the new golden. Confirm this
  split so the test file is not double-owned.
