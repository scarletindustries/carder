//// Security + semantics tests for the Porffor `rt_host` shim (P7-08 §A/§B). These assert the
//// **measured Porffor 0.61.13 intrinsic semantics** (`precompile.js`/`wrap.js` — `a`=print,
//// `b`=printChar, `c`=time, `d`=timeOrigin) and the **fail-closed** capability boundary (spec
//// §4.5.4 — an unprovided import is not callable), never "whatever the code emits".
////
//// Isolation (F4/E1): a seeded policy + the output buffer are process-local, so every assertion
//// runs in its OWN spawned process (`in_process`) — seeds/buffers cannot leak across tests.

import gleam/erlang/process
import gleeunit/should
import twocore/ir
import twocore/runtime/instance.{HostDenyAll, HostWhitelist}
import twocore/runtime/profiles
import twocore/runtime/rt_host

/// Run `action`; `Ok(#(cap, name))` iff it raised `{capability_denied, Cap, Name}`, else `Error`.
@external(erlang, "twocore_rt_test_ffi", "host_denial")
fn host_denial(action: fn() -> a) -> Result(#(String, String), String)

/// Run `thunk`, reporting `Ok(value)` on a normal return or `Error(text)` on any raise.
@external(erlang, "twocore_rt_state_test_ffi", "catch_thunk")
fn catch_thunk(thunk: fn() -> a) -> Result(a, String)

/// Run `work` in a FRESH process (isolated pdict) and return its value.
fn in_process(work: fn() -> a) -> a {
  let reply = process.new_subject()
  let _ = process.spawn(fn() { process.send(reply, work()) })
  let assert Ok(value) = process.receive(reply, within: 5000)
  value
}

/// The Porffor host posture as a `HostPolicy` (the whitelist admitting the four `""` intrinsics).
fn porffor_policy() -> instance.HostPolicy {
  HostWhitelist(profiles.porffor_allow())
}

/// Seed `policy`, dispatch `call_host(cap, name, args)`, and capture BOTH the call result and the
/// resulting output buffer — all in ONE fresh process (so the buffer written by the handler is
/// the one we read).
fn dispatch_and_capture(
  policy: instance.HostPolicy,
  cap: String,
  name: String,
  args: List(Int),
) -> #(Result(List(Int), String), BitArray) {
  in_process(fn() {
    rt_host.seed_policy(policy)
    let result = catch_thunk(fn() { rt_host.call_host(cap, name, args) })
    let buffer = rt_host.porffor_output()
    #(result, buffer)
  })
}

// ── print (a): a number → its ECMAScript decimal string, appended to the buffer ──────────────

/// `call_host("", "a", [f64_bits(42.0)])` returns `[]` AND the buffer gains the bytes `"42"`
/// (Porffor `print`, `i => print(i.toString())`).
pub fn print_appends_number_test() {
  let #(result, buffer) =
    dispatch_and_capture(porffor_policy(), "", "a", [0x4045000000000000])
  result |> should.equal(Ok([]))
  buffer |> should.equal(<<"42">>)
}

/// A `NaN` argument prints `"NaN"` (the special bit pattern, §F).
pub fn print_appends_nan_test() {
  let #(result, buffer) =
    dispatch_and_capture(porffor_policy(), "", "a", [0x7FF8000000000000])
  result |> should.equal(Ok([]))
  buffer |> should.equal(<<"NaN">>)
}

// ── printChar (b): a code unit → its UTF-8 byte(s), appended ──────────────────────────────────

/// `call_host("", "b", [f64_bits(65.0)])` returns `[]` AND the buffer gains `"A"`
/// (Porffor `printChar`, `i => print(String.fromCharCode(i))`).
pub fn print_char_appends_ascii_test() {
  let #(result, buffer) =
    dispatch_and_capture(porffor_policy(), "", "b", [0x4050400000000000])
  result |> should.equal(Ok([]))
  buffer |> should.equal(<<"A">>)
}

/// Effect order is preserved: successive print/printChar calls concatenate in call order (the
/// `CallHost` barrier — the buffer accumulates). `printChar(72)` then `print(9)` then
/// `printChar(33)` → `"H9!"`.
pub fn buffer_preserves_order_test() {
  let buffer =
    in_process(fn() {
      rt_host.seed_policy(porffor_policy())
      // 'H' = 72.0 bits, 9.0 bits, '!' = 33.0 bits
      let _ = rt_host.call_host("", "b", [0x4052000000000000])
      let _ = rt_host.call_host("", "a", [0x4022000000000000])
      let _ = rt_host.call_host("", "b", [0x4040800000000000])
      rt_host.porffor_output()
    })
  buffer |> should.equal(<<"H9!">>)
}

// ── time / timeOrigin (c / d): a deterministic f64 result ─────────────────────────────────────

/// `time` and `timeOrigin` return a single f64 result (the raw bits of the deterministic `0.0`,
/// §B.2), and write nothing to the buffer.
pub fn time_returns_scalar_test() {
  let #(result, buffer) = dispatch_and_capture(porffor_policy(), "", "c", [])
  result |> should.equal(Ok([0]))
  buffer |> should.equal(<<>>)

  let #(result2, _) = dispatch_and_capture(porffor_policy(), "", "d", [])
  result2 |> should.equal(Ok([0]))
}

// ── fail-closed (J3/J5): an unprovided intrinsic, or a denied posture, denies ─────────────────

/// An `""` name OUTSIDE {a,b,c,d} (e.g. a future `""."e"`, the PGO `profileLocalSet`) is DENIED
/// under `porffor()` — the four-arm universe is the whole authority surface; never a silent stub.
pub fn unprovided_intrinsic_denies_test() {
  in_process(fn() {
    rt_host.seed_policy(porffor_policy())
    host_denial(fn() { rt_host.call_host("", "e", [0]) })
  })
  |> should.equal(Ok(#("", "e")))
}

/// Under the fail-closed deny-all default, EVERY Porffor intrinsic denies — a Porffor module
/// linked without the `porffor()` whitelist gets no host authority (the same fail-closed
/// conjunction as any capability).
pub fn intrinsics_denied_under_deny_all_test() {
  in_process(fn() {
    rt_host.seed_policy(HostDenyAll)
    host_denial(fn() { rt_host.call_host("", "a", [0x4045000000000000]) })
  })
  |> should.equal(Ok(#("", "a")))
}

// ── the intrinsic FuncType signature face (§B.5) ─────────────────────────────────────────────

/// `porffor_func_type` returns each intrinsic's declared signature (print/printChar `[f64] -> []`;
/// time/timeOrigin `[] -> [f64]`), and `Error(Nil)` for an unknown letter.
pub fn porffor_func_type_signatures_test() {
  rt_host.porffor_func_type("a")
  |> should.equal(Ok(ir.FuncType([ir.TF64], [])))
  rt_host.porffor_func_type("b")
  |> should.equal(Ok(ir.FuncType([ir.TF64], [])))
  rt_host.porffor_func_type("c")
  |> should.equal(Ok(ir.FuncType([], [ir.TF64])))
  rt_host.porffor_func_type("d")
  |> should.equal(Ok(ir.FuncType([], [ir.TF64])))
  rt_host.porffor_func_type("e") |> should.equal(Error(Nil))
}

/// The pinned letter→builtin map (§A.3) is the four creation-order idents — a legible constant so
/// a Porffor version bump is a conscious re-measure.
pub fn porffor_intrinsics_pin_test() {
  rt_host.porffor_intrinsics
  |> should.equal([
    #("a", "print"),
    #("b", "printChar"),
    #("c", "time"),
    #("d", "timeOrigin"),
  ])
}

// ── the buffer self-initialises empty + seeds empty ──────────────────────────────────────────

/// A never-printed instance reads `<<>>` (the buffer self-initialises empty per process, E1), and
/// `porffor_seed_output` explicitly clears it.
pub fn buffer_empty_by_default_test() {
  in_process(fn() { rt_host.porffor_output() })
  |> should.equal(<<>>)

  in_process(fn() {
    rt_host.seed_policy(porffor_policy())
    let _ = rt_host.call_host("", "a", [0x4045000000000000])
    rt_host.porffor_seed_output()
    rt_host.porffor_output()
  })
  |> should.equal(<<>>)
}
