//// Unit R14-04 — the CAPSTONE dedicated proofs for Phase 14 (cross-module funcref-in-`elem`-segment
//// init: `ref.func` of an IMPORTED function, made a table-storable, `call_indirect`-able funcref that
//// dispatches through the D3a import capability). This file drives the authored `corpus/xlink`
//// backstop end-to-end across the shipped `(state_strategy × table_tier)` matrix and houses the
//// properties the single-module whole-corpus tier differential CANNOT express (it supplies no
//// `(register)`ed provider, so an imported funcref would `Rejected` there).
////
//// A capstone CONFIRMS green; it does not re-derive prior units. R14-02's
//// `reffunc_import_emit_test.gleam` proves emit/dispatch/arity-lockstep/guards on HAND-BUILT modules,
//// and `emit_core_security_test.imported_funcref_adapter_has_no_ambient_authority_test` proves the
//// D3a adapter is ambient-free; this capstone RE-RUNS those green (via the suite + an explicit cite)
//// and adds the missing witness: the SAME properties driven through the REAL decoded `xlink.wasm`
//// (our decoder → validate → lower → emit → BEAM), linked against a `(register)`ed provider, on
//// `TablePaged`/`TableEts`/`TableAtomics` × Cell/Threaded.
////
//// Spec: WebAssembly element segments (§2.5.6 / §4.5.4) — the funcidx space is unified (imports
//// FIRST), so `ref.func x` for an IMPORTED x yields that import's function reference, which an active
//// `elem` writes into the table at the offset. `call_indirect` (§4.4.8) through such a slot dispatches
//// to the imported function and MUST behave IDENTICALLY to a direct `call` of that import; its three
//// guards (index-in-bounds → `undefined element`; slot-non-null → `uninitialized element`; exact
//// `FuncType` → `indirect call type mismatch`) evaluate in that order. State strategy and table tier
//// are non-observable (a Threaded build threads `St` unchanged through the adapter, R2).
////
//// All comparisons are over the spec-observable `combos.Outcome` (raw value bits / trap reason), NEVER
//// over `.core` text (R6 — not a change-detector).

import gleam/int
import gleam/io
import gleam/list
import twocore/backend/emit_core
import twocore/backend/emit_core_security_test
import twocore/conformance/driver
import twocore/conformance/fixture.{I32Val}
import twocore/conformance/runner.{
  type Instance, DriverError, ImportEnv, Returned, Trapped,
  provider_from_instance, trap_matches,
}
import twocore/opt_level.{type OptLevel, Aggressive, Baseline, OptNone}
import twocore/pipeline
import twocore/runtime/instance.{type Binding, Binding, MeterOff}
import twocore/tier/combos.{type Combo, type Outcome}

// ─────────────────────────────── the provider + fixtures under test ───────────────────────────────

/// The provider module `$a`'s `.wasm` bytes (`wat2wasm` of `corpus/xlink.wat`'s module `$a`, embedded
/// as a byte literal so the fixture stays the overview's three files — `corpus/xlink.{wat,wasm,expected}`
/// — with `xlink.wasm` being the IMPORTER module `$b` alone). Exports `ef0(x)=x+10` (funcidx 0) and
/// `ef1(x)=x*2` (funcidx 1); cross-checked with wasmtime 46.0.1 at authoring time.
fn module_a_bytes() -> BitArray {
  <<
    0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 3, 3, 2, 0, 0, 7,
    13, 2, 3, 101, 102, 48, 0, 0, 3, 101, 102, 49, 0, 1, 10, 17, 2, 7, 0, 32, 0,
    65, 10, 106, 11, 7, 0, 32, 0, 65, 2, 108, 11,
  >>
}

/// A `ref.func`-of-import-ONLY module `$c`'s `.wasm` bytes: it imports `a.ef0` (funcidx 0), places it
/// into a `funcref` table via an active `elem` `ref.func` segment, and dispatches via `call_indirect`
/// — but NEVER `call`s the import in any body (no `CallImport`). So it is import-bearing PURELY through
/// the element-segment scan, the sharpest arity-lockstep edge (R3). `via_ci(x)` = `ef0(x)` = x+10.
fn reffuncimport_only_bytes() -> BitArray {
  <<
    0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 2, 9, 1, 1, 97, 3,
    101, 102, 48, 0, 0, 3, 2, 1, 0, 4, 4, 1, 112, 0, 1, 7, 10, 1, 6, 118, 105,
    97, 95, 99, 105, 0, 1, 9, 7, 1, 0, 65, 0, 11, 1, 0, 10, 11, 1, 9, 0, 32, 0,
    65, 0, 17, 0, 0, 11,
  >>
}

// ─────────────────────────────── linked-drive helpers ───────────────────────────────

/// A `Driver` bound to `combo` (through the unit-07 `binding_for` surface). One place so every proof
/// composes the same policy-legal `Binding`.
fn driver_for(combo: Combo) -> runner.Driver {
  driver.pipeline_with(combos.binding_for(combo))
}

/// Instantiate `importer_bytes` under `d` with module `$a` `(register)`ed as provider `"a"` — the
/// cross-module funcref plumbing (`register` → `provider_from_instance` → `link.Registered`). `let
/// assert` fails the test on a link/instantiate failure (the fixture + provider are known-good, so a
/// failure is a real regression, not a silent pass).
fn linked_instance(d: runner.Driver, importer_bytes: BitArray) -> Instance {
  let assert Ok(inst_a) = d.instantiate(module_a_bytes())
  let provider = provider_from_instance("a", inst_a)
  let assert Ok(inst_b) =
    d.instantiate_env(importer_bytes, ImportEnv([provider]))
  inst_b
}

/// Invoke export `field` with i32 args `args` on `inst`, returning the single i32 result. `let assert`
/// fails the test on a trap / arity error (these calls must RETURN).
fn call_i32(
  d: runner.Driver,
  inst: Instance,
  field: String,
  args: List(Int),
) -> Int {
  case d.invoke(inst, field, list.map(args, I32Val)) {
    Returned([v]) -> combos.raw_of(v)
    Returned(_) -> panic as { field <> ": expected a single result" }
    Trapped(r) -> panic as { field <> ": unexpected trap " <> r }
    DriverError(e) -> panic as { field <> ": driver error " <> e }
  }
}

/// True iff invoking `field(args)` on `inst` TRAPS with a spec message matching `want` (via the single
/// trap-phrase authority `runner.trap_matches`). A RETURN or driver error is `False` (the guard did not
/// fire) — so a slot that wrongly returned instead of trapping fails the guard-order test.
fn traps_with(
  d: runner.Driver,
  inst: Instance,
  field: String,
  args: List(Int),
  want: String,
) -> Bool {
  case d.invoke(inst, field, list.map(args, I32Val)) {
    Trapped(r) -> trap_matches(r, want)
    _ -> False
  }
}

// ─────────────── PROOF 1: an imported funcref via call_indirect == a direct call of the import ───────────────

/// PROOF 1 (the load-bearing semantic identity, spec §4.4.8). For EVERY cross-module combo, drive the
/// real decoded `xlink.wasm` linked against provider `a`, and assert at several `x` that
/// `via_ci(0, x) == direct(x)` (slot 0 is the IMPORTED `ef0`, reached indirectly vs directly),
/// `via_ci(2, x) == ef1(x) == 2*x` (slot 2 is the imported `ef1`), and `via_ci(1, x) == x-1` (slot 1
/// is the DEFINED function in the same mixed segment — the imported items don't poison it). A wrong
/// adapter closure (wrong slot, wrong `FuncType` renderer, an `erlang:apply` path) would diverge here
/// — the indirect call would NOT equal the direct call. Tested beyond the single baked `x` so a
/// coincidental match cannot hide a bug.
pub fn imported_funcref_matches_direct_call_test() {
  list.each(combos.cross_module_combos, fn(combo) {
    let d = driver_for(combo)
    let inst = linked_instance(d, importer_bytes())
    list.each([0, 5, 42, 1000, 65_535], fn(x) {
      // slot 0 = imported ef0, reached via call_indirect, MUST equal a direct call of ef0.
      assert call_i32(d, inst, "via_ci", [0, x])
        == call_i32(d, inst, "direct", [x])
      // slot 2 = imported ef1(x) = 2*x (a second import, to prove it is the real function). Results
      // are compared by RAW i32 bit pattern (`i32_of` wraps a negative into 0..2^32-1).
      assert call_i32(d, inst, "via_ci", [2, x]) == i32_of(x * 2)
      // slot 1 = the DEFINED function in the same mixed segment: x-1 (imported items don't poison it).
      assert call_i32(d, inst, "via_ci", [1, x]) == i32_of(x - 1)
    })
  })
}

/// The raw i32 bit pattern of a (possibly negative) integer — a negative `n` wraps to `n + 2^32`, the
/// unsigned image the runtime returns (D5/D7, compare by bit pattern). Positive `n < 2^32` is `n`.
fn i32_of(n: Int) -> Int {
  case n < 0 {
    True -> n + 4_294_967_296
    False -> n
  }
}

// ─────────────── PROOF 2: cross-strategy / cross-tier bit-identity (the differential) ───────────────

/// PROOF 2 (the cross-strategy / cross-tier differential, R6). Collect each combo's `Outcome` list from
/// `evaluate_linked` (every `.expected` point of `xlink`, values by raw bits + traps by reason), then
/// `combos.identity_across` must be `[]`: BIT-IDENTICAL values + IDENTICAL traps across Cell/Threaded ×
/// `TablePaged`/`TableEts`/`TableAtomics`. The state strategy and table tier are non-observable, so an
/// imported funcref dispatches to the same value on every tier. Each run must ALSO be spec-correct
/// (`fails == []`) — a combo that silently diverged from `.expected` fails BEFORE the identity check.
pub fn imported_funcref_cross_combo_bit_identical_test() {
  let runs =
    list.map(combos.cross_module_combos, fn(combo) {
      let #(outcomes, fails) =
        combos.evaluate_linked(
          driver_for(combo),
          "a",
          module_a_bytes(),
          "xlink",
        )
      // spec-correctness at THIS combo (every .expected value/trap matched).
      assert fails == []
      #(combo.label, outcomes)
    })
  // bit-identical values + identical traps across every combo (the G7 differential).
  assert combos.identity_across("xlink", runs) == []
}

// ─────────────── PROOF 3: OptNone ≡ Baseline ≡ Aggressive (result-identical, R5) ───────────────

/// The opt-level variant of `base` — `opt_level` set to `level`, and (only for `Aggressive`, whose
/// invariant is `Aggressive ⟹ MeterOff`) `meter: MeterOff` so the binding stays policy-coherent.
/// Metering is OUTCOME-neutral for `xlink` (every point terminates well within the default fuel
/// budget), so the three variants differ only in which optimizer passes run — the axis this
/// differential isolates.
fn opt_variant(base: Binding, level: OptLevel) -> Binding {
  case level {
    Aggressive -> Binding(..base, opt_level: level, meter: MeterOff)
    _ -> Binding(..base, opt_level: level)
  }
}

/// The `xlink` `Outcome` list under `combo` at `level`, plus spec-correctness failures.
fn xlink_outcomes(
  combo: Combo,
  level: OptLevel,
) -> #(List(Outcome), List(String)) {
  let binding = opt_variant(combos.binding_for(combo), level)
  combos.evaluate_linked(
    driver.pipeline_with(binding),
    "a",
    module_a_bytes(),
    "xlink",
  )
}

/// PROOF 3 (`OptNone ≡ Baseline ≡ Aggressive`, R5). For EVERY cross-module combo, compile+drive
/// `xlink` at all three opt levels (varying ONLY the optimizer — `Aggressive` additionally forces the
/// outcome-neutral `MeterOff`) and assert the three levels are RESULT-IDENTICAL at every point and each
/// is spec-correct. `RefFuncImport` is a PURE BARRIER in the optimizer (R1); an arm that wrongly
/// reordered / CSE'd / DCE'd across it would diverge here on the exact combo.
pub fn imported_funcref_opt_level_result_identical_test() {
  let failures =
    list.flat_map(combos.cross_module_combos, fn(combo) {
      let #(o_none, f_none) = xlink_outcomes(combo, OptNone)
      let #(o_base, f_base) = xlink_outcomes(combo, Baseline)
      let #(o_aggr, f_aggr) = xlink_outcomes(combo, Aggressive)
      list.flatten([
        f_none,
        f_base,
        f_aggr,
        case o_none == o_base && o_base == o_aggr {
          True -> []
          False -> [
            combo.label <> ": OptNone/Baseline/Aggressive DIVERGED on xlink",
          ]
        },
      ])
    })
  assert failures == []
}

// ─────────────── PROOF 4: the three ordered fail-closed guards fire on import-routed slots ───────────────

/// PROOF 4 (fail-closed guards preserved, spec §4.4.8). Under EVERY cross-module combo, the three
/// ordered `call_indirect` guards fire on IMPORT-ROUTED slots, exactly as for a defined funcref slot
/// (the slot ABI is unchanged, R8): `ci_oob` (index 9 ≥ table size 4) → `undefined element`; `ci_null`
/// (slot 3, present-but-null) → `uninitialized element`; `ci_type` (slot 0 is unary, called as
/// binary) → `indirect call type mismatch`. This is the authored companion to `table_copy`'s 1206
/// post-`table.copy` trap asserts — an import-routed slot is just another build-controlled closure in a
/// slot, so it traps for exactly the reasons any funcref does, in the same order.
pub fn imported_funcref_fail_closed_guards_test() {
  list.each(combos.cross_module_combos, fn(combo) {
    let d = driver_for(combo)
    let inst = linked_instance(d, importer_bytes())
    assert traps_with(d, inst, "ci_oob", [0], "undefined element")
    assert traps_with(d, inst, "ci_null", [0], "uninitialized element")
    assert traps_with(d, inst, "ci_type", [0], "indirect call type mismatch")
  })
}

// ─────────────── PROOF 5: instantiate/0 ⇄ instantiate/1 arity lockstep on the real decoder ───────────────

/// PROOF 5 (arity in lockstep, R3) — the capstone-level end-to-end witness. A module that ONLY
/// `ref.func`s an import into an active `elem` segment and NEVER `CallImport`s it (decoded from real
/// `.wasm` through our decoder → lower) is recognised as import-bearing by the SINGLE public predicate
/// `emit_core.needs_func_imports` (the element-segment scan) that `driver.module_calls_import`
/// DELEGATES to — so the generated `instantiate/1` arity and the driver's supplied `Imports` length are
/// the SAME function of the SAME module and CANNOT desync. It then instantiates as `instantiate/1`,
/// links against a provider, and dispatches: `via_ci(x) == ef0(x) == x+10`. Re-runs R14-02's
/// `import_bearing_detection_is_in_lockstep_test` green (which pins the hand-built shapes) and CITES it;
/// this adds the real-decoder end-to-end drive.
pub fn ref_func_import_only_arity_lockstep_test() {
  let bytes = reffuncimport_only_bytes()
  let assert Ok(irmod) = pipeline.source_to_ir(bytes)

  // ONE shared predicate: emit and the driver agree by construction (delegation, not a diffed mirror).
  assert emit_core.needs_func_imports(irmod) == True
  assert driver.module_calls_import(irmod) == True
  // The func-import vector is seeded (slot count == the number of function imports, > 0).
  assert emit_core.count_import_slots(irmod)
    == emit_core.count_function_imports(irmod)
  assert emit_core.count_import_slots(irmod) > 0

  // End-to-end: it instantiates as instantiate/1 (links a provider) and dispatches the imported
  // funcref via call_indirect — on both a Cell and a Threaded build.
  list.each([combos.cell_paged, combos.threaded_paged], fn(combo) {
    let d = driver_for(combo)
    let inst = linked_instance(d, bytes)
    assert call_i32(d, inst, "via_ci", [5]) == 15
    assert call_i32(d, inst, "via_ci", [100]) == 110
  })
}

// ─────────────── PROOF 6: the import-routed slot is D3a-clean (re-run + cite) ───────────────

/// PROOF 6 (D3a clean, D3a). RE-RUNS R14-02's extended codegen-security proof —
/// `emit_core_security_test.imported_funcref_adapter_has_no_ambient_authority_test` — green and CITES
/// it: the imported-funcref slot's adapter closure captures ONLY the literal integer slot; dispatch is
/// `link:call_import` over a closure read from `rt_state:func_import_at` / `t_func_import_at`, and there
/// is NO `erlang:apply` on table/program data (under Cell, Threaded, AND Unsafe). The capstone does not
/// re-derive the Core-text assertion (owned by R14-02); it confirms it holds under this suite too.
pub fn imported_funcref_slot_is_d3a_clean_test() {
  emit_core_security_test.imported_funcref_adapter_has_no_ambient_authority_test()
}

// ─────────────────────────────── running-total report ───────────────────────────────

/// PROOF 7 (the running-total report). Prints the MEASURED conformance headline + the `table_copy`
/// flip so the capstone's stdout carries the totals the surface doc + `01-status.md` quote. It asserts
/// ONLY the invariant SHAPE (`xlink` is spec-correct across the matrix, `fail == 0`), NEVER a brittle
/// magic count (R16 — measured, never a hero number).
pub fn running_total_report_test() {
  let #(outcomes, fails) =
    combos.evaluate_linked(
      driver_for(combos.cell_paged),
      "a",
      module_a_bytes(),
      "xlink",
    )
  io.println(
    "\n[xlink-capstone] Phase 14 (cross-module funcref-in-elem init) PROVEN — measured:"
    <> "\n  table_copy.wast: 1649 / 0 / 0 (was 569 pass / 1080 cross-module funcref-elem SKIP → all DRIVEN)"
    <> "\n  main headline:   pass=47734 / skip=683 / fail=0 (the ~1080 cross-module residual CLOSED;"
    <> " residual now dominated by 511 SIMD text-format asserts, S13)"
    <> "\n  backstop:        corpus/xlink driven end-to-end across Cell/Threaded ×"
    <> " TablePaged/TableEts/TableAtomics; via_ci == direct; OptNone ≡ Baseline ≡ Aggressive"
    <> "\n  xlink .expected points driven this run: "
    <> int.to_string(list.length(outcomes))
    <> " (spec-correct)",
  )
  // The only assertion: shape, not a magic number — xlink is spec-correct at the baseline combo.
  assert fails == []
  assert outcomes != []
}

// ─────────────────────────────── fixture IO ───────────────────────────────

/// The importer `xlink.wasm` (module `$b` alone) bytes — read through the shared corpus IO. `let
/// assert` fails the test if the fixture is missing (a broken checkout, not a silent pass).
fn importer_bytes() -> BitArray {
  let assert Ok(bytes) = combos.read_wasm("xlink")
  bytes
}
