//// The conformance oracle — the SINGLE place a result is judged spec-correct.
////
//// Two rules, both straight from the WebAssembly spec
//// (<https://webassembly.github.io/spec/core/>):
////
//// 1. **Bit-pattern equality for concrete values.** Integers and concrete floats
////    compare by EXACT unsigned bit pattern, masked to the type's width. This is
////    correct for floats too because 2core stores floats as raw IEEE-754 bits (D5),
////    so a returned `f32` IS its `0x????????` pattern — `-0.0` (`0x80000000`) and
////    `+0.0` (`0x00000000`) are therefore (correctly) distinct, and the wast2json
////    `value` is the decimal of those same bits.
//// 2. **NaN by CLASS, never by bit-equality.** A NaN has many valid encodings, so an
////    expected NaN matches a whole class of patterns
////    (<https://webassembly.github.io/spec/core/syntax/values.html#floating-point>,
////    <https://webassembly.github.io/spec/core/exec/numerics.html>):
////      - a value is a NaN of a width iff its exponent field is all-ones AND its
////        payload (mantissa) is non-zero;
////      - **canonical** ⇔ payload is exactly the MSB bit (`0x40_0000` for f32,
////        `0x8_0000_0000_0000` for f64);
////      - **arithmetic** ⇔ payload MSB is set, the rest arbitrary;
////      - the **sign bit is ignored** for both.
////    (Canonical is a strict subset of arithmetic.)

import gleam/int
import twocore/conformance/fixture.{
  type NanKind, type SpecValue, AnyRefK, Arithmetic, ArrayRefK, Canonical,
  EqRefK, ExternRefVal, F32Bits, F32Nan, F64Bits, F64Nan, FuncRefVal, GcHeapK,
  GcRef, I31RefK, I32Val, I64Val, NullRef, StructRefK, V128Val,
}

// IEEE-754 binary32 field masks (sign|exp[8]|payload[23]).
const f32_exp_mask: Int = 0xFF

const f32_payload_mask: Int = 0x7FFFFF

const f32_payload_msb: Int = 0x400000

// IEEE-754 binary64 field masks (sign|exp[11]|payload[52]).
const f64_exp_mask: Int = 0x7FF

const f64_payload_mask: Int = 0xFFFFFFFFFFFFF

const f64_payload_msb: Int = 0x8000000000000

/// True iff `actual` satisfies the spec's `expected`.
///
/// The comparison is driven by `expected`'s type: concrete `expected` (`I32Val`,
/// `I64Val`, `F32Bits`, `F64Bits`) demands an EXACT width-masked bit match against
/// `actual`'s raw bits; a NaN `expected` (`F32Nan`, `F64Nan`) demands `actual` be a
/// NaN of the right CLASS (sign ignored). `actual` is expected to be a concrete value
/// (the BEAM returns concrete bits); its own tag is not trusted — only its raw bits
/// are read and reinterpreted at `expected`'s width, so an `actual` tagged loosely
/// (e.g. all results carried as one numeric family) still compares correctly.
pub fn matches(actual: SpecValue, expected: SpecValue) -> Bool {
  case expected {
    // Numeric expectations reject a REFERENCE actual outright (the families are disjoint — a null's
    // raw_bits is 0, which must NOT masquerade as the numeric 0). In real runs the driver tags an
    // actual at the export's declared type, so this only guards against a mis-tagged reference.
    I32Val(e) -> !is_ref(actual) && mask(raw_bits(actual), 32) == mask(e, 32)
    I64Val(e) -> !is_ref(actual) && mask(raw_bits(actual), 64) == mask(e, 64)
    F32Bits(e) -> !is_ref(actual) && mask(raw_bits(actual), 32) == mask(e, 32)
    F64Bits(e) -> !is_ref(actual) && mask(raw_bits(actual), 64) == mask(e, 64)
    F32Nan(k) -> !is_ref(actual) && is_f32_nan(mask(raw_bits(actual), 32), k)
    F64Nan(k) -> !is_ref(actual) && is_f64_nan(mask(raw_bits(actual), 64), k)
    // Reference comparison (P5-11 / R18), per the spec reference-value model
    // (<https://webassembly.github.io/spec/core/syntax/types.html#reference-types>):
    //  - a null expectation matches a null actual of EITHER reftype (the null sentinel is
    //    shared; a null slot's reftype is not observable at the value layer);
    //  - an externref matches by IDENTITY (the `ref.extern N` handle must round-trip exactly);
    //  - a funcref matches any NON-NULL funcref (our funcref is an opaque type-tagged entry;
    //    the suite's funcref checks are null-vs-non-null, so identity is deliberately not
    //    compared — documented, not silently lenient).
    NullRef(_) ->
      case actual {
        NullRef(_) -> True
        _ -> False
      }
    ExternRefVal(a) ->
      case actual {
        ExternRefVal(b) -> a == b
        _ -> False
      }
    FuncRefVal(_) ->
      case actual {
        FuncRefVal(_) -> True
        _ -> False
      }
    // GC abstract-heap-type comparison (Phase-8 GC), per the WASM GC subtype lattice
    // (<https://webassembly.github.io/spec/core/valid/types.html#subtyping>):
    // `any ⊇ eq ⊇ {struct, array, i31}`; `none`/null is bottom. The EXPECTED is a kind pattern; the
    // ACTUAL is the harness's classification of the returned GC term. A returned `{gc, Id}` handle
    // classifies coarsely to `GcHeapK` (struct-vs-array is not observable in the harness process —
    // the arena is instance-process-local, R-GC1), so `structref`/`arrayref` accept `GcHeapK`
    // leniently (documented — the static export type guarantees the kind; mirrors the funcref
    // identity leniency above); `eqref`/`anyref` accept it by the lattice regardless. A null actual
    // never satisfies a NON-null GC kind (that is `NullRef`, matched above).
    GcRef(exp_kind) ->
      case actual {
        GcRef(act_kind) -> gc_kind_matches(exp_kind, act_kind)
        _ -> False
      }
    // v128 comparison (P6-10 / M3), per the spec vector value model
    // (<https://webassembly.github.io/spec/core/syntax/values.html#vectors>) + vector-instruction
    // semantics. A `v128` is correct iff EVERY lane is correct at the EXPECTED's lane
    // interpretation — this CANNOT be a raw 16-byte `==`, because a float-lane result may be a NaN
    // whose payload bits are implementation-chosen but spec-legal (canonical/arithmetic), matched
    // by CLASS not bit pattern. So we reconstruct the actual's 16-byte image, re-decode it at the
    // expected's `lane_type`, and compare each lane with the SAME scalar `matches` used for scalar
    // floats (integer lanes by exact bit-equality, f32/f64 lanes by bit-equality OR NaN-class).
    // Both `nan:canonical` and `nan:arithmetic` accept the canonical NaN rt_num/rt_simd produce
    // (canonical ⊂ arithmetic — see `nan_class`).
    V128Val(exp_lane, exp_lanes) ->
      case actual {
        V128Val(act_lane, act_lanes) -> {
          let image = fixture.v128_pack(act_lanes, act_lane)
          let reinterpreted = fixture.v128_unpack(image, exp_lane)
          matches_all(reinterpreted, exp_lanes)
        }
        _ -> False
      }
  }
}

/// Compare a list of actual results against the expected list: same length and every
/// position `matches`. Phase-1 functions return 0 or 1 result; this generalises to the
/// multi-value case for free.
pub fn matches_all(actual: List(SpecValue), expected: List(SpecValue)) -> Bool {
  case actual, expected {
    [], [] -> True
    [a, ..ar], [e, ..er] ->
      case matches(a, e) {
        True -> matches_all(ar, er)
        False -> False
      }
    _, _ -> False
  }
}

/// The raw unsigned bit pattern carried by a concrete `SpecValue`. NaN-class values
/// carry no concrete bits and yield `0` (they are only ever the `expected`, never the
/// `actual`, so this is never read for them).
fn raw_bits(v: SpecValue) -> Int {
  case v {
    I32Val(b) | I64Val(b) | F32Bits(b) | F64Bits(b) -> b
    F32Nan(_) | F64Nan(_) -> 0
    // Reference values carry no numeric bits (they are compared as references, never as bits).
    NullRef(_) | ExternRefVal(_) | FuncRefVal(_) | GcRef(_) -> 0
    // A v128 is compared lane-wise (see `matches`), never as a single scalar bit pattern.
    V128Val(_, _) -> 0
  }
}

/// True iff `v` is a reference value (null / externref / funcref / GC heap ref) — the disjointness
/// guard so a numeric expectation never matches a reference actual.
fn is_ref(v: SpecValue) -> Bool {
  case v {
    NullRef(_) | ExternRefVal(_) | FuncRefVal(_) | GcRef(_) -> True
    _ -> False
  }
}

/// Judge a returned GC ref's classified kind (`actual`) against a spec kind pattern (`expected`),
/// per the WASM GC subtype lattice `any ⊇ eq ⊇ {struct, array, i31}`.
///
/// `GcHeapK` is the coarse actual for a `{gc, Id}` handle (struct-vs-array not observable in the
/// harness process, R-GC1): it satisfies `structref`/`arrayref` leniently and `eqref`/`anyref` by
/// the lattice. `I31RefK` is precise (i31 self-describes). This is total over `GcRefKind`.
fn gc_kind_matches(
  expected: fixture.GcRefKind,
  actual: fixture.GcRefKind,
) -> Bool {
  case expected, actual {
    // any ref satisfies `anyref`.
    AnyRefK, _ -> True
    // eqref: i31/struct/array (and the coarse gc-heap), never a bare `AnyRefK` host ref.
    EqRefK, I31RefK
    | EqRefK, StructRefK
    | EqRefK, ArrayRefK
    | EqRefK, GcHeapK
    -> True
    // Concrete kinds: exact, or the coarse gc-heap actual (documented leniency).
    StructRefK, StructRefK | StructRefK, GcHeapK -> True
    ArrayRefK, ArrayRefK | ArrayRefK, GcHeapK -> True
    I31RefK, I31RefK -> True
    _, _ -> False
  }
}

/// Mask `n` to the low `width` bits (`width` ∈ {32, 64}) — the unsigned bit pattern.
fn mask(n: Int, width: Int) -> Int {
  int.bitwise_and(n, two_pow(width) - 1)
}

fn two_pow(n: Int) -> Int {
  case n {
    32 -> 0x100000000
    64 -> 0x10000000000000000
    _ -> do_two_pow(n, 1)
  }
}

fn do_two_pow(n: Int, acc: Int) -> Int {
  case n {
    0 -> acc
    _ -> do_two_pow(n - 1, acc * 2)
  }
}

/// True iff the 32-bit pattern `bits` is a NaN of class `kind` (sign ignored).
fn is_f32_nan(bits: Int, kind: NanKind) -> Bool {
  let exp = int.bitwise_and(int.bitwise_shift_right(bits, 23), f32_exp_mask)
  let payload = int.bitwise_and(bits, f32_payload_mask)
  let is_nan = exp == f32_exp_mask && payload != 0
  nan_class(is_nan, payload, f32_payload_msb, kind)
}

/// True iff the 64-bit pattern `bits` is a NaN of class `kind` (sign ignored).
fn is_f64_nan(bits: Int, kind: NanKind) -> Bool {
  let exp = int.bitwise_and(int.bitwise_shift_right(bits, 52), f64_exp_mask)
  let payload = int.bitwise_and(bits, f64_payload_mask)
  let is_nan = exp == f64_exp_mask && payload != 0
  nan_class(is_nan, payload, payload_msb_64(), kind)
}

fn payload_msb_64() -> Int {
  f64_payload_msb
}

fn nan_class(is_nan: Bool, payload: Int, msb: Int, kind: NanKind) -> Bool {
  case is_nan, kind {
    False, _ -> False
    // Canonical: payload is exactly the single MSB bit (rest zero).
    True, Canonical -> payload == msb
    // Arithmetic: payload MSB set, remaining bits arbitrary (canonical included).
    True, Arithmetic -> int.bitwise_and(payload, msb) != 0
  }
}
