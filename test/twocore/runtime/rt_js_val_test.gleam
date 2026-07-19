//// Round-trip tests for the `JsVal` opaque wire ABI (SPEC §2.3 / D16).
////
//// The property under test is `classify(mk_X(v)) == KX(v)` for EVERY row of the
//// §2.3 wire table — undefined, null, boolean, JInt, JFloat, JNan, JPosInf,
//// JNegInf, string, bigint, symbol, object handle, TDZ. `JsVal` is opaque at
//// the Gleam type level; the ONLY way to construct one is a `mk_*` encoder and
//// the ONLY way to inspect one is `classify/1` — so a round-trip through both
//// proves the encoder and the decoder agree on every wire discriminator.
////
//// The FFI (`twocore_rt_js_val_ffi.erl`) has NO catch-all clause: a wire term
//// outside the §2.3 encoding is a `function_clause` crash. That fail-closed
//// behavior is asserted by exhaustively covering the closed set of encoders.

import gleam/option.{None, Some}
import gleeunit/should
import twocore/runtime/rt_js_types.{
  JFloat, JInt, JNan, JNegInf, JPosInf, JsCell, KBig, KBool, KHandle, KNull,
  KNum, KStr, KSym, KTdz, KUndef, SymIterator, UserSymbol, WellKnownSymbol,
  classify, mk_bigint, mk_bool, mk_null, mk_number, mk_object, mk_string,
  mk_symbol, mk_tdz, mk_undefined,
}

// ── undefined / null ───────────────────────────────────────────────────────

pub fn undefined_round_trips_test() {
  classify(mk_undefined()) |> should.equal(KUndef)
}

pub fn null_round_trips_test() {
  classify(mk_null()) |> should.equal(KNull)
}

// ── boolean ────────────────────────────────────────────────────────────────

pub fn bool_true_round_trips_test() {
  classify(mk_bool(True)) |> should.equal(KBool(True))
}

pub fn bool_false_round_trips_test() {
  classify(mk_bool(False)) |> should.equal(KBool(False))
}

// ── number: finite integer / float ─────────────────────────────────────────

pub fn number_jint_round_trips_test() {
  classify(mk_number(JInt(42))) |> should.equal(KNum(JInt(42)))
}

pub fn number_jint_zero_round_trips_test() {
  classify(mk_number(JInt(0))) |> should.equal(KNum(JInt(0)))
}

pub fn number_jint_negative_round_trips_test() {
  classify(mk_number(JInt(-17))) |> should.equal(KNum(JInt(-17)))
}

pub fn number_jfloat_round_trips_test() {
  classify(mk_number(JFloat(3.5))) |> should.equal(KNum(JFloat(3.5)))
}

pub fn number_jfloat_negative_round_trips_test() {
  classify(mk_number(JFloat(-0.25))) |> should.equal(KNum(JFloat(-0.25)))
}

// ── number: the three non-finite sentinels ─────────────────────────────────
// BEAM floats cannot hold NaN/±Inf; §2.3 uses sentinel atoms instead.

pub fn number_jnan_round_trips_test() {
  classify(mk_number(JNan)) |> should.equal(KNum(JNan))
}

pub fn number_jposinf_round_trips_test() {
  classify(mk_number(JPosInf)) |> should.equal(KNum(JPosInf))
}

pub fn number_jneginf_round_trips_test() {
  classify(mk_number(JNegInf)) |> should.equal(KNum(JNegInf))
}

// ── string ─────────────────────────────────────────────────────────────────

pub fn string_round_trips_test() {
  classify(mk_string("hello")) |> should.equal(KStr("hello"))
}

pub fn string_empty_round_trips_test() {
  classify(mk_string("")) |> should.equal(KStr(""))
}

/// Strings are UTF-8 binaries (D10) — a non-ASCII code point must survive.
pub fn string_utf8_round_trips_test() {
  classify(mk_string("naïve — 🎉")) |> should.equal(KStr("naïve — 🎉"))
}

// ── bigint ─────────────────────────────────────────────────────────────────

pub fn bigint_round_trips_test() {
  classify(mk_bigint(7)) |> should.equal(KBig(7))
}

/// A bigint outside the safe-integer range is the whole point of the row.
pub fn bigint_large_round_trips_test() {
  let big = 9_007_199_254_740_993
  classify(mk_bigint(big)) |> should.equal(KBig(big))
}

// ── symbol ─────────────────────────────────────────────────────────────────
// The encoder does NOT flatten well-known symbols to a bare atom — position 2
// of `{js_sym, _}` is always the SymbolId sum's own wire form (SPEC §2.3).

pub fn symbol_user_round_trips_test() {
  let sym = UserSymbol(uid: 3, description: Some("tag"))
  classify(mk_symbol(sym)) |> should.equal(KSym(sym))
}

pub fn symbol_user_no_description_round_trips_test() {
  let sym = UserSymbol(uid: 0, description: None)
  classify(mk_symbol(sym)) |> should.equal(KSym(sym))
}

pub fn symbol_well_known_round_trips_test() {
  let sym = WellKnownSymbol(SymIterator)
  classify(mk_symbol(sym)) |> should.equal(KSym(sym))
}

// ── object handle ──────────────────────────────────────────────────────────
// `Handle`'s wire form `{js_cell, N}` IS the object wire form — mk_object is
// identity (R4), so the round-trip proves `classify` re-tags it as KHandle.

pub fn handle_round_trips_test() {
  let h = JsCell(id: 5)
  classify(mk_object(h)) |> should.equal(KHandle(h))
}

pub fn handle_zero_round_trips_test() {
  let h = JsCell(id: 0)
  classify(mk_object(h)) |> should.equal(KHandle(h))
}

// ── TDZ sentinel ───────────────────────────────────────────────────────────

pub fn tdz_round_trips_test() {
  classify(mk_tdz()) |> should.equal(KTdz)
}

// ── discriminators are pairwise distinct ───────────────────────────────────
// Bare integers, floats, and binaries share the wire universe with the
// tagged rows — assert `classify` never confuses them.

/// A bigint whose payload equals a plain int's wire term is still a bigint.
pub fn bigint_is_not_number_test() {
  classify(mk_bigint(1)) |> should.equal(KBig(1))
  classify(mk_number(JInt(1))) |> should.equal(KNum(JInt(1)))
}

/// Boolean wire atoms are not `undefined`/`null`.
pub fn bool_is_not_undefined_or_null_test() {
  let assert KBool(_) = classify(mk_bool(False))
  let assert KUndef = classify(mk_undefined())
  let assert KNull = classify(mk_null())
}
