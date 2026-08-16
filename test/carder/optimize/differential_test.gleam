//// Unit P3-11 capstone — the WHOLE-CORPUS optimizer + Safe/Unsafe differentials (proofs
//// 1, 2, 3 of the unit doc; F1/F2/F4/F5/F6).
////
//// These are DIFFERENTIAL tests: they hold the *program* fixed and vary the `Binding`, then
//// assert two compilations agree on every spec-observable behaviour — never on `.core` text or
//// IR shape (which the optimizer/mode is *allowed* to change). Each run is reduced to one
//// normalized `Outcome` per program point (raw result bits per D7, or the raw trap reason), so
//// "did the optimizer change anything?" is a single `==`.
////
//// Two assertions are load-bearing at every proof, exactly as F2 requires (no change-detector
//// tests, D8):
////   1. **cross-compilation identity** — the raw `Outcome`s are byte-identical across the varied
////      bindings (the optimizer / the Unsafe posture changed nothing observable), and
////   2. **spec-correctness** — that shared outcome equals the `.expected` value, which is SOURCED
////      FROM THE SPEC (`corpus/*.expected`, cited from the vendored `.wast` / wasmtime). Identity
////      alone could pass on a mutually-broken pair; `.expected` alone is just the existing
////      acceptance test. Together they are F2.
////
//// Spec anchors for the corpus values: numerics
//// <https://webassembly.github.io/spec/core/exec/numerics.html>, bounds/traps
//// <https://webassembly.github.io/spec/core/exec/instructions.html> — cited per program inside
//// each `.expected`.

import carder/conformance/corpus.{
  type Expect, InstantiateTraps, Rejects, Returns, Traps,
}
import carder/conformance/driver
import carder/conformance/ffi
import carder/conformance/fixture.{
  type SpecValue, F32Bits, F32Nan, F64Bits, F64Nan, I32Val, I64Val,
}
import carder/conformance/oracle
import carder/conformance/runner.{type Driver, DriverError, Returned, Trapped}
import carder/opt_level.{Aggressive, Baseline, OptNone}
import carder/pipeline
import carder/runtime/instance.{type Binding, Binding}
import carder/runtime/profiles
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string

const corpus_dir = "test/carder/conformance/corpus"

/// Every Phase-1+Phase-2 acceptance-corpus program that carries a spec-sourced `.expected`
/// (the authored `corpus/*.wat`). `growcap`/`iso`/`memloop` are excluded — they have no
/// `.expected` and are driven by dedicated Phase-2 tests (Safe cap / isolation / constant
/// space), not by a value oracle.
const corpus_programs: List(String) = [
  "add", "intops", "sum_to", "fib", "fac", "floatops", "hostimport", "mem",
  "callind", "gvar", "memgrow", "trunc", "trapstart", "oobdata",
]

/// The spec-observable outcome of compiling+running one program point — the ONLY thing F2
/// requires two compilations to agree on. `Value` carries the RAW bit pattern (D7) so NaN
/// payloads / `-0.0` / i32-i64 wrap are exact; `Trap`/`InstantiateTrap` carry the raw
/// `{wasm_trap,…}` reason (stable across optimizer levels — the reason atom is not an
/// optimization); `Rejected` = the module failed to build a runnable instance (fail-closed,
/// D4); `Instantiated` marks a module that (wrongly) built when the spec expects rejection or an
/// instantiation trap, so the differential still compares it structurally.
pub type Outcome {
  Value(bits: List(Int))
  Trap(reason: String)
  InstantiateTrap(reason: String)
  Rejected
  Instantiated
}

// ─────────────────────────── Proof 1 — optimizer soundness (F1/F2) ───────────────────────────

/// PROOF 1 (F1/F2), the headline correctness gate. For every corpus program, the three optimizer
/// levels — `OptNone`, `Baseline`, `Aggressive` — differ in EXACTLY ONE `Binding` field
/// (`opt_level`, spread over `profiles.safe()`), so the optimizer is the only variable. Each
/// level must (a) match the spec-sourced `.expected` value, and (b) produce a raw `Outcome`
/// BYTE-IDENTICAL to the other two. A single unsound rewrite (a CSE-of-load-across-store, a trap
/// hoisted past a guard, a mis-elided effect) changes an `Outcome` and turns this red on the
/// exact program.
///
/// `Aggressive` runs under a Safe runtime ON PURPOSE (unit doc §B): `Aggressive` adds
/// charge-elision, which touches only the fuel instrumentation (a policy overlay, not a WASM
/// semantic, F5) — so eliding it under `MeterFuel` changes fuel accounting but NOT the WASM
/// `Outcome`, which is exactly the invariant under test (the default budget is generous, so
/// `FuelExhausted` never fires; proof 4 tests the trap separately).
pub fn optimizer_soundness_differential_test() {
  let base = profiles.safe()
  let none = pipeline_at(Binding(..base, opt_level: OptNone))
  let baseline = pipeline_at(Binding(..base, opt_level: Baseline))
  let aggressive = pipeline_at(Binding(..base, opt_level: Aggressive))

  let failures =
    list.flat_map(corpus_programs, fn(name) {
      let #(o_none, f_none) = evaluate(none, name)
      let #(o_base, f_base) = evaluate(baseline, name)
      let #(o_aggr, f_aggr) = evaluate(aggressive, name)
      list.flatten([
        // (a) spec-correctness at every level (defeats consistently-wrong)
        f_none,
        f_base,
        f_aggr,
        // (b) cross-level raw identity (defeats "the optimizer changed a value/trap")
        identity_failures(name, "OptNone≡Baseline", o_none, o_base),
        identity_failures(name, "Baseline≡Aggressive", o_base, o_aggr),
      ])
    })

  assert failures == []
}

// ─────────────────────── Proof 2 — Safe ≡ Unsafe (F4/F6) ───────────────────────

/// PROOF 2 (F4/F6). The SAME corpus under `profiles.safe()` and `profiles.unsafe()` gives the
/// identical spec-correct `Outcome` for every program point. Safe and Unsafe are TWO DISTINCT
/// B3 builds (`ir_lower` compiles metering in/out; the optimizer runs at build time), so this
/// bundles the whole Unsafe posture at once — `Aggressive` optimizer, `MeterOff`, `BifOpen`,
/// `StdlibPassthrough`, `HostOpen` — and asserts NONE of them changed an answer. `Unsafe ≠
/// incorrect`: WASM has no undefined behaviour, so nothing Unsafe relaxes may change a corpus
/// result (F8). `StdlibPassthrough ≡ StdlibOwn` is exercised transitively wherever the corpus
/// calls a shared stdlib function (unit 06 owns the focused differential; this owns the
/// end-to-end one).
pub fn safe_unsafe_differential_test() {
  let safe = pipeline_at(profiles.safe())
  let unsafe = pipeline_at(profiles.unsafe())

  let failures =
    list.flat_map(corpus_programs, fn(name) {
      let #(o_safe, f_safe) = evaluate(safe, name)
      let #(o_unsafe, f_unsafe) = evaluate(unsafe, name)
      list.flatten([
        f_safe,
        f_unsafe,
        identity_failures(name, "Safe≡Unsafe", o_safe, o_unsafe),
      ])
    })

  assert failures == []
}

// ─────────────────────── Proof 3 — zero-overhead Unsafe (F5) ───────────────────────

/// PROOF 3 (F5), zero-overhead Unsafe. `MeterOff` means `ir_lower` inserts NO `Charge` nodes at
/// all — not no-op charges, *absent* ones — so the emitted `.core` differs from Safe by exactly
/// the instrumentation. Proven as a robust text-level assertion on a metered corpus function
/// (`sum_to`, whose loop is charged under Safe): the Safe `.core` instruments (`charge` sites +
/// the `rt_meter:seed_fuel` in `instantiate/0`), the Unsafe `.core` has ZERO `charge` and ZERO
/// `rt_meter` occurrences ANYWHERE. Together with proof 2 (the two `.core`s compute the same
/// answers) this is F5's "differ exactly by the instrumentation".
pub fn unsafe_zero_overhead_charge_test() {
  let assert Ok(m) = pipeline.source_to_ir(read_bytes("sum_to"))
  let assert Ok(safe_core) = pipeline.ir_to_core(m, profiles.safe())
  let assert Ok(unsafe_core) = pipeline.ir_to_core(m, profiles.unsafe())

  // Safe instruments: at least one `charge` site and the `rt_meter` seed/charge references.
  assert count_occurrences(safe_core, "charge") > 0
  assert count_occurrences(safe_core, "rt_meter") > 0

  // Unsafe: no charge calls at all, and no `seed_fuel` either — the metering module is never
  // referenced in a `MeterOff` build.
  assert count_occurrences(unsafe_core, "charge") == 0
  assert count_occurrences(unsafe_core, "rt_meter") == 0
}

// ─────────────────────────────── evaluation machinery ───────────────────────────────

/// Compile+instantiate every module in a corpus program under `binding`, driving each `.expected`
/// point, and return `#(outcomes, failures)`:
/// - `outcomes`: one raw `Outcome` per program point (or a single module-level outcome for a
///   `reject` / `instantiate`-trap program) — the input to the cross-compilation identity check.
/// - `failures`: the spec-correctness violations at THIS binding (empty ⇒ every point matched
///   `.expected`). Total — never panics; a compile-stage rejection of a value program is itself a
///   recorded `Outcome` + failure, so a level that fails to build shows up in BOTH checks.
fn evaluate(d: Driver, name: String) -> #(List(Outcome), List(String)) {
  let assert Ok(bytes) = read_wasm(name)
  let assert Ok(text) = read_expected(name)
  let assert Ok(expects) = corpus.parse(text)

  case expects {
    [Rejects] ->
      case d.instantiate(bytes) {
        Error(_) -> #([Rejected], [])
        Ok(_) -> #([Instantiated], [name <> ": expected REJECT, but it built"])
      }
    [InstantiateTraps(want)] ->
      case d.instantiate(bytes) {
        Ok(_) -> #([Instantiated], [
          name <> ": expected instantiation TRAP, but it built",
        ])
        Error(reason) ->
          case string.split_once(reason, "instantiate: ") {
            Ok(#(_, trap)) -> #(
              [InstantiateTrap(trap)],
              trap_spec_failures(name, trap, want),
            )
            Error(_) -> #([Rejected], [
              name
              <> ": expected instantiation trap, got compile rejection: "
              <> reason,
            ])
          }
      }
    _ ->
      case d.instantiate(bytes) {
        Error(reason) -> #([Rejected], [
          name <> ": module failed to instantiate: " <> reason,
        ])
        Ok(inst) ->
          list.fold(expects, #([], []), fn(acc, ex) {
            let #(outs, fails) = acc
            let #(o, f) = run_point(d, inst, name, ex)
            #(list.append(outs, [o]), list.append(fails, f))
          })
      }
  }
}

/// Drive one `.expected` value point and reduce it to `#(raw_outcome, spec_failures)`. `Returns`
/// compares via the oracle (NaN-class aware, bit-exact otherwise); `Traps` compares the runtime
/// reason against the spec phrase via `runner.trap_matches`. A `DriverError` (e.g. an
/// out-of-scope multi-value result) is a spec-check failure here — every corpus point is in scope.
fn run_point(
  d: Driver,
  inst,
  name: String,
  ex: Expect,
) -> #(Outcome, List(String)) {
  case ex {
    Rejects | InstantiateTraps(_) -> #(Instantiated, [
      name <> ": misplaced module-level expectation",
    ])
    Returns(field, args, results) ->
      case d.invoke(inst, field, args) {
        Returned(actuals) -> {
          let outcome = Value(list.map(actuals, raw_of))
          case oracle.matches_all(actuals, results) {
            True -> #(outcome, [])
            False -> #(outcome, [
              name
              <> ": "
              <> field
              <> " got "
              <> string.inspect(actuals)
              <> " want "
              <> string.inspect(results),
            ])
          }
        }
        Trapped(r) -> #(Trap(r), [
          name <> ": " <> field <> " expected return, trapped " <> r,
        ])
        DriverError(e) -> #(Instantiated, [
          name <> ": " <> field <> " driver error " <> e,
        ])
      }
    Traps(field, args, want) ->
      case d.invoke(inst, field, args) {
        Trapped(r) -> #(
          Trap(r),
          trap_spec_failures(name <> ":" <> field, r, want),
        )
        Returned(vs) -> #(Value(list.map(vs, raw_of)), [
          name
          <> ": "
          <> field
          <> " expected trap '"
          <> want
          <> "', returned "
          <> string.inspect(vs),
        ])
        DriverError(e) -> #(Instantiated, [
          name <> ": " <> field <> " driver error " <> e,
        ])
      }
  }
}

/// The spec-correctness failures for a caught trap `reason` against the expected spec phrase
/// `want` — empty iff `runner.trap_matches` accepts it (the single trap-phrase authority,
/// mirroring `rt_trap.spec_trap_message`).
fn trap_spec_failures(
  where: String,
  reason: String,
  want: String,
) -> List(String) {
  case runner.trap_matches(reason, want) {
    True -> []
    False -> [
      where <> ": trapped " <> reason <> " want spec phrase '" <> want <> "'",
    ]
  }
}

/// The cross-compilation identity failures: the two raw outcome-lists must be `==`. A mismatch
/// means a varied `Binding` field (the optimizer level, or the whole Unsafe posture) CHANGED an
/// observable — the F2 red flag.
fn identity_failures(
  name: String,
  which: String,
  a: List(Outcome),
  b: List(Outcome),
) -> List(String) {
  case a == b {
    True -> []
    False -> [
      name
      <> " ["
      <> which
      <> "]: outcomes diverged: "
      <> string.inspect(a)
      <> " vs "
      <> string.inspect(b),
    ]
  }
}

/// The raw bit pattern a result `SpecValue` carries (D5/D7). The driver tags every WASM result at
/// its declared width, so only the `*Bits`/`*Val` variants appear here; a NaN tag (never produced
/// by the driver) maps to `0` to stay total.
fn raw_of(v: SpecValue) -> Int {
  case v {
    I32Val(b) | I64Val(b) | F32Bits(b) | F64Bits(b) -> b
    F32Nan(_) | F64Nan(_) -> 0
    // Reference values carry no raw bits (this differential corpus is numeric); 0 stays total.
    fixture.NullRef(_) | fixture.ExternRefVal(_) | fixture.FuncRefVal(_) -> 0
    // A GC ref carries no raw bits either (this corpus is numeric); 0 stays total.
    fixture.GcRef(_) -> 0
    // A v128 is compared lane-wise, never as a scalar; this differential corpus is numeric.
    fixture.V128Val(_, _) -> 0
  }
}

/// A `Driver` that compiles + instantiates every module under `binding` (proof-1/2 seam).
fn pipeline_at(binding: Binding) -> Driver {
  driver.pipeline_with(binding)
}

// ─────────────────────────────── fixture IO / text ───────────────────────────────

fn read_wasm(name: String) -> Result(BitArray, String) {
  ffi.read_file(corpus_dir <> "/" <> name <> ".wasm")
}

fn read_bytes(name: String) -> BitArray {
  let assert Ok(b) = read_wasm(name)
  b
}

fn read_expected(name: String) -> Result(String, String) {
  use bytes <- result.try(ffi.read_file(
    corpus_dir <> "/" <> name <> ".expected",
  ))
  bit_array.to_string(bytes) |> result.replace_error("non-UTF8 .expected")
}

/// Count non-overlapping occurrences of `needle` in `haystack` (`n` splits ⇒ `n-1` occurrences).
/// Used only by the zero-overhead `.core` assertion (proof 3).
fn count_occurrences(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}
