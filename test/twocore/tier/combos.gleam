//// Unit P4-09 — the shipped `(state_strategy × mem_tier × table_tier)` combination matrix
//// and the ONE `binding_for/1` constructor that composes each coherent, policy-legal `Binding`
//// through the unit-07 profile/linker surface (D1: this suite never re-spells a `rt_mem_*`
//// module name — every tier→module coupling goes through `profiles.compose`/`resolve_tiers`/
//// `validate_binding`). It also carries the small, reused evaluation machinery every proof in
//// `test/twocore/tier/**` shares: the normalized spec-observable `Outcome`, the corpus driver,
//// and the two load-bearing checks (spec-correctness against `.expected` + cross-combination
//// byte-identity), so "did the tier change anything?" is a single `==` (D7/D8, no
//// change-detector).
////
//// This is a **support module** (no `_test` functions), imported by the five proof suites.
//// Spec anchors are cited per corpus program inside each `corpus/*.expected` (numerics
//// <https://webassembly.github.io/spec/core/exec/numerics.html>, bounds/traps
//// <https://webassembly.github.io/spec/core/exec/instructions.html>).

import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import twocore/conformance/corpus.{
  type Expect, InstantiateTraps, Rejects, Returns, Traps,
}
import twocore/conformance/ffi
import twocore/conformance/fixture.{
  type SpecValue, F32Bits, F32Nan, F64Bits, F64Nan, I32Val, I64Val,
}
import twocore/conformance/oracle
import twocore/conformance/runner.{
  type Driver, type Instance, DriverError, Returned, Trapped,
}
import twocore/runtime/instance.{
  type Binding, type MemTier, type Mode, type StateStrategy, type TableTier,
  Atomics, Binding, Cell, Nif, Paged, Safe, TableAtomics, TablePaged, Threaded,
  Unsafe,
}
import twocore/runtime/profiles

/// The absolute path of the shared acceptance corpus (the spec-`.expected`-bearing
/// `corpus/*.wat` Phase-1/2 authored). This suite drives the SAME corpus every acceptance /
/// Phase-3 differential drives — held fixed, varied only over the tier axes.
pub const corpus_dir = "test/twocore/conformance/corpus"

/// The Phase-1+2 acceptance-corpus programs that carry a spec-sourced `.expected` (the value
/// oracle). `growcap`/`iso`/`memloop` are excluded — they have no `.expected` and are driven by
/// dedicated tests (Safe cap / isolation / constant space), exactly as the Phase-3 capstone
/// scoped them. Memory/table/global programs (`mem`/`memgrow`/`oobdata`/`callind`/`gvar`) are the
/// tier-sensitive ones; the pure-numeric programs pin that the threaded seam adds no change to
/// pure functions (keystone §A.3).
///
/// `tailrec` (Phase 13) is the tail-call program: a `return_call` self-loop, a mutually-recursive
/// even/odd, a `return_call_indirect` self-loop through a table slot, plus the three ordered
/// indirect fail-closed traps (undefined → uninitialized → type-mismatch). It uses a `funcref`
/// table + `elem`, so under the Phase-13 funcref-ABI change (funcref closures became package-ABI
/// tail-transparent) it is a **result-identical**, NOT byte-identical, module: its indirect tail
/// call threads `cur` under `threaded`, so its emitted Core differs across `cell`/`threaded`, but
/// the differential asserts identical VALUES + TRAPS (the `Outcome`), not identical Core bytes — so
/// it stays green across every combo. (The constant-stack space proof to 1,000,000 lives in the
/// dedicated `tier/tailcall_capstone_test.gleam`, exactly as `sum_to`'s space proof does.)
pub const corpus_programs: List(String) = [
  "add", "intops", "sum_to", "fib", "fac", "floatops", "hostimport", "mem",
  "callind", "gvar", "memgrow", "trunc", "trapstart", "oobdata", "tailrec",
]

/// The bounded Safe max-pages cap this suite bakes into EVERY combination (D1/P6). A finite,
/// small cap is required so an `Atomics` build links: `atomics` `fresh` pre-allocates to the
/// effective max, and `profiles.validate_binding` fail-closes an uncapped/over-cap atomics
/// binding (unit 07 §C). `16` pages is comfortably below the `atomics` reserve cap (4096) — so
/// every atomics combo links and reserves ≤ 16 pages — and comfortably ABOVE every corpus
/// program's actual footprint (`mem` = 1 page, `memgrow` declared max 1), so the cap NEVER
/// changes a spec-observable result: `effective_max = min(declared_max ?? cap, cap, 65536)`
/// stays the declared max for every corpus program. Using it uniformly keeps `binding_for` a
/// single source and keeps the whole corpus byte-identical to `.expected`.
pub const cap_pages: Int = 16

// ─────────────────────────────── the combination matrix (§A) ───────────────────────────────

/// A shipped deployment point on the trust-tier lattice: a state strategy × memory tier × table
/// tier × the policy each tier is legal under (G3/G6 — `Nif` only under Unsafe). `label` names
/// the point in failure messages so a divergence pins the exact combination.
pub type Combo {
  Combo(
    label: String,
    strategy: StateStrategy,
    mem: MemTier,
    table: TableTier,
    policy: Mode,
  )
}

/// The Phase-2/3 baseline: tier-O `Cell` state + tier-P `Paged` memory, Safe.
pub const cell_paged = Combo("cell×paged", Cell, Paged, TablePaged, Safe)

/// The runs-anywhere / `portable` point: tier-P `Threaded` state + `Paged` memory + `TablePaged`
/// table (tier-P on every axis), Safe.
pub const threaded_paged = Combo(
  "threaded×paged",
  Threaded,
  Paged,
  TablePaged,
  Safe,
)

/// The tier-O O(1) node-safe point under the `Cell` calling convention.
pub const cell_atomics = Combo(
  "cell×atomics",
  Cell,
  Atomics,
  TableAtomics,
  Safe,
)

/// The tier-O O(1) point under the `Threaded` calling convention — the combination most likely
/// to surface a threading bug (the mutable backend returns the same mutated ref under both
/// calling conventions, keystone §A.2).
pub const threaded_atomics = Combo(
  "threaded×atomics",
  Threaded,
  Atomics,
  TableAtomics,
  Safe,
)

/// The tier-N `nif` ceiling — WHERE IT SHIPS (G8): a node-safe skeleton delegating to the paged
/// core (the production C NIF is documented-deferred), so it LINKS and must be byte-identical
/// like the rest. `Nif` is Unsafe-only (G6), so this point is `Unsafe`; its `TablePaged` table
/// keeps the point node-safe. Included because the skeleton loads on a bare BEAM.
pub const cell_nif = Combo("cell×nif", Cell, Nif, TablePaged, Unsafe)

/// The `portable` deployment profile as a `Combo` — an alias of `threaded_paged` (Safe, tier-P
/// on every axis), the point proofs 3/4 name directly.
pub const portable = threaded_paged

/// The combinations Phase 4 SHIPS (overview §1 acceptance). The oracle reference is the
/// spec-sourced `.expected`, so all of these must equal it — hence each other.
pub const shipped: List(Combo) = [
  cell_paged,
  threaded_paged,
  cell_atomics,
  threaded_atomics,
  cell_nif,
]

/// The metered (Safe ⇒ `MeterFuel`) shipped combos — every non-`Nif` point. The `Nif` ceiling is
/// Unsafe (`MeterOff`), so it carries no fuel counter and is excluded from the fuel-parity proof
/// (§B.1). These four each thread the SAME tight budget when metered.
pub const metered: List(Combo) = [
  cell_paged,
  threaded_paged,
  cell_atomics,
  threaded_atomics,
]

/// Build the coherent, policy-legal `Binding` for a `Combo` (D1: through the unit-07 surface
/// ONLY — never spelling a `rt_mem_*` module name). Bases on `profiles.unsafe()` for an `Unsafe`
/// point (the `Nif` ceiling) and `profiles.safe()` otherwise, bakes the bounded `cap_pages` Safe
/// cap (so an atomics combo links, P6), then `profiles.compose` sets the three tier axes AND
/// (via `resolve_tiers`) the matching `mem_module`/`table_module`, and `validate_binding` gates
/// it fail-closed.
///
/// - `c`: a shipped `Combo`.
/// - Returns the coherent `Binding` ready for `driver.pipeline_with`. Panics via `let assert`
///   iff the combination is policy-incoherent (e.g. a hand-built `Safe + Nif`) — which `shipped`
///   never lists, so the assert is unreachable and documents the G6 invariant. Total for every
///   shipped combo.
pub fn binding_for(c: Combo) -> Binding {
  let base = case c.policy {
    Safe -> profiles.safe()
    Unsafe -> profiles.unsafe()
  }
  let capped = Binding(..base, safe_max_pages: cap_pages)
  let composed = profiles.compose(capped, c.strategy, c.mem, c.table)
  let assert Ok(binding) = profiles.validate_binding(composed)
  binding
}

/// Build the metered `Binding` for a `Combo` with a LOWERED per-instance CPU-fuel `budget` (§B.1)
/// — `binding_for(c)` with `fuel_budget` overridden. Only the four `metered` combos use it; the
/// override touches no tier field (`fuel_budget` is a policy field `resolve_tiers` never rewrites),
/// so the tier coupling stays coherent.
pub fn binding_for_metered(c: Combo, budget: Int) -> Binding {
  Binding(..binding_for(c), fuel_budget: budget)
}

// ─────────────────────────────── the normalized outcome (§A) ───────────────────────────────

/// The spec-observable outcome of compiling+running one program point under one `Combo` — the
/// ONLY thing the differential requires two combinations to agree on. `Value` carries the RAW bit
/// pattern (D7 — NaN payloads / `-0.0` / i32↔i64 wrap exact); `Trap`/`InstantiateTrap` carry the
/// raw `{wasm_trap,…}` reason (stable across tiers — the trap reason is not a tier property);
/// `Rejected` = failed to build a runnable instance (fail-closed, D4); `Instantiated` marks a
/// module that (wrongly) built when the spec expects rejection or an instantiation trap, so the
/// differential still compares it structurally. The comparison is NEVER over `.core` text or the
/// linked module name (which the tier is allowed to change) — only over spec-observable behaviour.
pub type Outcome {
  Value(bits: List(Int))
  Trap(reason: String)
  InstantiateTrap(reason: String)
  Rejected
  Instantiated
}

// ─────────────────────────────── evaluation machinery ───────────────────────────────

/// Compile+instantiate every module in a corpus program under a `Driver` (already bound to one
/// combo), driving each `.expected` point, and return `#(outcomes, failures)`:
/// - `outcomes`: one raw `Outcome` per program point (or a single module-level outcome for a
///   `reject` / `instantiate`-trap program) — the input to the cross-combination identity check.
/// - `failures`: the spec-correctness violations at THIS combo (empty ⇒ every point matched
///   `.expected`). Total — never panics; a compile-stage rejection of a value program is itself a
///   recorded `Outcome` + failure, so a combo that fails to build shows up in BOTH checks.
pub fn evaluate(d: Driver, name: String) -> #(List(Outcome), List(String)) {
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
/// reason against the spec phrase via `runner.trap_matches`. A `DriverError` (an out-of-scope
/// multi-value result) is a spec-check failure here — every corpus point is in scope.
fn run_point(
  d: Driver,
  inst: Instance,
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
/// `want` — empty iff `runner.trap_matches` accepts it (the single trap-phrase authority).
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

/// The cross-combination identity failures for one program: every combo's raw outcome-list must
/// equal the FIRST combo's (the baseline). A mismatch means a varied tier axis CHANGED an
/// observable — the G7 red flag, naming the exact diverging combination.
///
/// - `name`: the program under test (for the failure message).
/// - `runs`: `#(combo_label, outcomes)` for every combination, baseline first.
/// - Returns the empty list iff all combinations agree, else one message per diverging combo.
pub fn identity_across(
  name: String,
  runs: List(#(String, List(Outcome))),
) -> List(String) {
  case runs {
    [] -> []
    [#(_base_label, base), ..rest] ->
      list.flat_map(rest, fn(r) {
        let #(label, outs) = r
        case outs == base {
          True -> []
          False -> [
            name
            <> " ["
            <> label
            <> " ≢ baseline]: "
            <> string.inspect(base)
            <> " vs "
            <> string.inspect(outs),
          ]
        }
      })
  }
}

/// The raw bit pattern a result `SpecValue` carries (D5/D7). The driver tags every WASM result at
/// its declared width, so only the `*Bits`/`*Val` variants appear here; a NaN tag (never produced
/// by the driver) maps to `0` to stay total.
pub fn raw_of(v: SpecValue) -> Int {
  case v {
    I32Val(b) | I64Val(b) | F32Bits(b) | F64Bits(b) -> b
    F32Nan(_) | F64Nan(_) -> 0
    // Reference values carry no raw bits (the acceptance corpus is numeric); 0 keeps it total.
    fixture.NullRef(_) | fixture.ExternRefVal(_) | fixture.FuncRefVal(_) -> 0
    // A v128 is compared lane-wise, never as a scalar; this differential corpus is numeric.
    fixture.V128Val(_, _) -> 0
  }
}

// ─────────────────────────────── fixture IO ───────────────────────────────

/// Read a corpus program's `.wasm` bytes. `Ok(bytes)` / `Error(posix_reason)`.
pub fn read_wasm(name: String) -> Result(BitArray, String) {
  ffi.read_file(corpus_dir <> "/" <> name <> ".wasm")
}

/// Read a corpus program's `.expected` text. `Ok(text)` / `Error(reason)`.
pub fn read_expected(name: String) -> Result(String, String) {
  use bytes <- result.try(ffi.read_file(
    corpus_dir <> "/" <> name <> ".expected",
  ))
  bit_array.to_string(bytes) |> result.replace_error("non-UTF8 .expected")
}

/// Count non-overlapping occurrences of `needle` in `haystack` (`n` splits ⇒ `n-1` occurrences).
/// Used by the runs-anywhere `.core` grep (§E).
pub fn count_occurrences(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}
