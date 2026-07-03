//// Spec-grounded tests for `rt_state` (unit 03) — the per-instance cell holder.
////
//// Assertions target WebAssembly instantiation/global semantics and the unit's E1/E3
//// contracts, NOT whatever the implementation happens to emit:
////
//// - **Globals exec** — `global.get` returns the current value; `global.set` writes exactly
////   the named global (<https://webassembly.github.io/spec/core/exec/instructions.html>).
//// - **Floats are raw bits (D5)** — f32/f64 globals are stored/returned as the raw IEEE-754
////   bit pattern `Int`, bit-exact, never via a BEAM double
////   (<https://webassembly.github.io/spec/core/syntax/values.html#floating-point>).
//// - **Instantiation installs fresh state** — a (re)instantiation resets memory/table/globals
////   (<https://webassembly.github.io/spec/core/exec/modules.html#instantiation>); two
////   instantiations never observe each other's state (E1 isolation).
//// - **Fail-closed (E3)** — an op on an un-seeded cell raises rather than reading garbage.
////
//// Exceptions are caught via the namespace-hygienic `twocore_rt_state_test_ffi` helper
//// (pure Gleam cannot `catch`).

import gleam/dynamic
import gleam/result
import gleeunit/should
import twocore/runtime/rt_meter
import twocore/runtime/rt_state.{FullDecl, StateDecl}

/// Run `thunk` and report whether it raised: `Ok(value)` on a normal return, `Error(text)`
/// on any raise/exit/throw. The fail-closed tests assert `result.is_error` — i.e. the op
/// raised at all (E3: never read garbage). See `twocore_rt_state_test_ffi`.
@external(erlang, "twocore_rt_state_test_ffi", "catch_thunk")
fn catch_thunk(thunk: fn() -> a) -> Result(a, String)

// ── 1. Global round-trip (global.set / global.get exec semantics) ──────────────

/// `seed`ing two globals then `global_set`/`global_get` round-trips the named global, and
/// a write to one global leaves the other untouched (global.set targets exactly one cell).
pub fn global_round_trip_test() {
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [#("g", 7), #("h", 100)],
    table: dynamic.nil(),
  ))

  // Initial inits are visible.
  rt_state.global_get("g") |> should.equal(7)
  rt_state.global_get("h") |> should.equal(100)

  // A write to g round-trips and does not disturb h.
  rt_state.global_set("g", 42)
  rt_state.global_get("g") |> should.equal(42)
  rt_state.global_get("h") |> should.equal(100)

  // A second write overwrites only the named global.
  rt_state.global_set("g", 43)
  rt_state.global_get("g") |> should.equal(43)
  rt_state.global_get("h") |> should.equal(100)
}

// ── 2. Float globals are bit-exact (D5: raw IEEE-754 bits, never a BEAM double) ─

/// f32/f64 globals carrying NaN-payload, `-0.0`, and `±Inf` bit patterns (as `Int`) survive
/// seed and `global_set`/`global_get` IDENTICALLY. A BEAM-double round-trip would mangle a
/// NaN payload / signalling bit or collapse `-0.0`; rt_state must store the `Int` verbatim.
pub fn float_globals_are_bit_exact_test() {
  // Raw bit patterns (as Int) for representative non-finite/edge floats.
  let f32_nan_payload = 0x7FC00001
  // quiet NaN, payload 1
  let f32_neg_zero = 0x80000000
  let f32_pos_inf = 0x7F800000
  let f32_neg_inf = 0xFF800000
  let f64_nan_payload = 0x7FF8000000000001
  let f64_neg_zero = 0x8000000000000000
  let f64_pos_inf = 0x7FF0000000000000

  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [
      #("f32_nan", f32_nan_payload),
      #("f32_nz", f32_neg_zero),
      #("f32_pinf", f32_pos_inf),
      #("f32_ninf", f32_neg_inf),
      #("f64_nan", f64_nan_payload),
      #("f64_nz", f64_neg_zero),
      #("f64_pinf", f64_pos_inf),
    ],
    table: dynamic.nil(),
  ))

  rt_state.global_get("f32_nan") |> should.equal(f32_nan_payload)
  rt_state.global_get("f32_nz") |> should.equal(f32_neg_zero)
  rt_state.global_get("f32_pinf") |> should.equal(f32_pos_inf)
  rt_state.global_get("f32_ninf") |> should.equal(f32_neg_inf)
  rt_state.global_get("f64_nan") |> should.equal(f64_nan_payload)
  rt_state.global_get("f64_nz") |> should.equal(f64_neg_zero)
  rt_state.global_get("f64_pinf") |> should.equal(f64_pos_inf)

  // A SET of a NaN payload is equally bit-exact (write path, not just the seed path).
  rt_state.global_set("f64_nz", f64_nan_payload)
  rt_state.global_get("f64_nz") |> should.equal(f64_nan_payload)
}

// ── 3. Fail-closed on an un-seeded cell (E3 — never read garbage) ──────────────

/// Without a `seed` (here forced via `clear`), every accessor RAISES rather than fabricating
/// a zeroed cell: `mem_get`/`table_get`/`global_get`/`global_set` all fail closed. (Reading
/// garbage out of an empty pdict is the bug this guard exists to prevent.)
pub fn fail_closed_on_unseeded_cell_test() {
  rt_state.clear()

  catch_thunk(fn() { rt_state.mem_get() })
  |> result.is_error
  |> should.be_true
  catch_thunk(fn() { rt_state.table_get() })
  |> result.is_error
  |> should.be_true
  catch_thunk(fn() { rt_state.global_get("g") })
  |> result.is_error
  |> should.be_true
  catch_thunk(fn() { rt_state.global_set("g", 0) })
  |> result.is_error
  |> should.be_true
  catch_thunk(fn() { rt_state.mem_put(dynamic.nil()) })
  |> result.is_error
  |> should.be_true
  catch_thunk(fn() { rt_state.table_put(dynamic.nil()) })
  |> result.is_error
  |> should.be_true
}

/// An accessor SUCCEEDS once the cell is seeded — the fail-closed guard is exactly the
/// un-seeded case, not a blanket refusal (proves test 3 is meaningful, not vacuous).
pub fn accessor_succeeds_once_seeded_test() {
  rt_state.clear()
  catch_thunk(fn() { rt_state.global_get("g") })
  |> result.is_error
  |> should.be_true

  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [#("g", 5)],
    table: dynamic.nil(),
  ))
  catch_thunk(fn() { rt_state.global_get("g") })
  |> should.equal(Ok(5))
}

/// An undeclared global also fails closed even on a SEEDED cell (an internal invariant
/// violation, distinct from the un-seeded case — both are unreachable under validation).
pub fn fail_closed_on_undeclared_global_test() {
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [#("g", 1)],
    table: dynamic.nil(),
  ))
  catch_thunk(fn() { rt_state.global_get("does_not_exist") })
  |> result.is_error
  |> should.be_true
}

// ── 4. (Re)seed installs fresh state, discarding the prior cell ────────────────

/// A second `seed` RESETS the cell: none of the first instantiation's globals/mem/table
/// survive (WASM instantiation installs fresh state). `g` takes B's value, B's mem is in
/// place, and A-only globals are gone (read fails closed).
pub fn reseed_resets_prior_state_test() {
  let mem_a = dynamic.string("mem-A")
  let mem_b = dynamic.string("mem-B")

  rt_state.seed(StateDecl(
    mem: mem_a,
    globals: [#("g", 1), #("a_only", 111)],
    table: dynamic.nil(),
  ))
  rt_state.global_set("g", 1000)

  // Re-seed: fresh cell. Everything from A is discarded wholesale.
  rt_state.seed(StateDecl(
    mem: mem_b,
    globals: [#("g", 9)],
    table: dynamic.nil(),
  ))

  rt_state.global_get("g") |> should.equal(9)
  rt_state.mem_get() |> should.equal(mem_b)
  // A's `a_only` global did not survive the reset.
  catch_thunk(fn() { rt_state.global_get("a_only") })
  |> result.is_error
  |> should.be_true
}

// ── 5. Isolation across two seed cycles in one process (E1) ────────────────────

/// In ONE process, two instantiations never observe each other's globals. Seed cycle A sets
/// `g=1`; cycle B sets `g=2`; after B, `global_get("g")` is `2`, never `1`.
pub fn isolation_across_seed_cycles_test() {
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [#("g", 1)],
    table: dynamic.nil(),
  ))
  rt_state.global_get("g") |> should.equal(1)

  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [#("g", 2)],
    table: dynamic.nil(),
  ))
  rt_state.global_get("g") |> should.equal(2)
}

// ── 6. The cell key is fixed & namespaced — no collision with rt_meter's fuel ──

/// Interleaving `rt_meter.charge` with `seed`/`global_set`/`global_get` proves the two pdict
/// cells live under DISTINCT keys: global ops never change the fuel total and `charge` never
/// changes a global (key hygiene / D3a — one fixed namespaced key per concern).
pub fn cell_key_does_not_collide_with_meter_fuel_test() {
  rt_meter.reset_fuel()
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [#("g", 5)],
    table: dynamic.nil(),
  ))

  rt_meter.charge(10)
  // A global write must not touch the fuel counter.
  rt_state.global_set("g", 99)
  rt_meter.fuel_consumed() |> should.equal(10)

  // A charge must not touch any global.
  rt_meter.charge(7)
  rt_state.global_get("g") |> should.equal(99)
  rt_meter.fuel_consumed() |> should.equal(17)

  // A re-seed (atomic reset of the whole cell) must not zero the fuel counter either.
  rt_state.seed(StateDecl(
    mem: dynamic.nil(),
    globals: [#("g", 1)],
    table: dynamic.nil(),
  ))
  rt_meter.fuel_consumed() |> should.equal(17)
}

// ── 7. Opaque field round-trip (rt_mem / rt_table own the value shapes) ────────

/// `mem_put`/`mem_get` (and `table_put`/`table_get`) round-trip an OPAQUE `Dynamic`
/// unchanged, `seed` installs the decl's mem/table, and writing one field leaves the other
/// (and the globals) intact. Sentinel `Dynamic`s stand in for 04/05's real shapes — rt_state
/// never inspects them.
pub fn opaque_field_round_trip_test() {
  let mem0 = dynamic.string("mem-0")
  let tbl0 = dynamic.list([dynamic.int(1), dynamic.int(2)])

  rt_state.seed(StateDecl(mem: mem0, globals: [#("g", 7)], table: tbl0))
  rt_state.mem_get() |> should.equal(mem0)
  rt_state.table_get() |> should.equal(tbl0)

  // Replace mem; table + globals are untouched.
  let mem1 = dynamic.int(123_456)
  rt_state.mem_put(mem1)
  rt_state.mem_get() |> should.equal(mem1)
  rt_state.table_get() |> should.equal(tbl0)
  rt_state.global_get("g") |> should.equal(7)

  // Replace table; mem + globals are untouched.
  let tbl1 = dynamic.string("tbl-1")
  rt_state.table_put(tbl1)
  rt_state.table_get() |> should.equal(tbl1)
  rt_state.mem_get() |> should.equal(mem1)
  rt_state.global_get("g") |> should.equal(7)
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tier-P (threaded) surface — pure, value-threaded, NO process dictionary (unit 03).
//
// These assert the SAME WebAssembly global/instantiation semantics as the cell suite
// above, but against the purely-functional record threaded call-to-call (keystone §A):
//
// - **`fresh` builds the declared record** — instantiation installs fresh state
//   (<https://webassembly.github.io/spec/core/exec/modules.html#instantiation>).
// - **`fresh` ≡ `seed` (G7 parity)** — a `Threaded` build and a `Cell` build start from
//   byte-identical state, so they compute identical results.
// - **Globals exec, purely** — `global.set` writes exactly the named global and
//   `global.get` reads it, with value semantics: the ORIGINAL record is never mutated
//   (<https://webassembly.github.io/spec/core/exec/instructions.html#variable-instructions>).
// - **Floats are raw bits (D5)** — bit-exact through the record, never a BEAM double.
// - **No ambient state (E3/G6)** — two records in one process never share, and the
//   tier-P surface writes NOTHING to the process dictionary (runs-anywhere).
// ═══════════════════════════════════════════════════════════════════════════════

// ── P1. `fresh` builds the record from the decl (thread round-trip) ────────────

/// `fresh(StateDecl(...))` yields a record holding exactly the declared inits: the declared
/// global reads back through `t_global_get`, and the opaque `mem`/`table` sentinels project
/// back verbatim through the field seam. (The threaded box holds the declared state.)
pub fn fresh_builds_declared_record_test() {
  let sentinel_m = dynamic.string("mem-sentinel")
  let sentinel_t = dynamic.list([dynamic.int(1), dynamic.int(2)])

  let st =
    rt_state.fresh(StateDecl(
      mem: sentinel_m,
      globals: [#("g", 7)],
      table: sentinel_t,
    ))

  rt_state.t_global_get(st, "g") |> should.equal(7)
  rt_state.mem(st) |> should.equal(sentinel_m)
  rt_state.table(st) |> should.equal(sentinel_t)
}

// ── P2. `fresh` ≡ `seed` materialisation (G7 parity) ───────────────────────────

/// For ONE `StateDecl`, the record `fresh` returns is field-by-field identical to the record
/// the cell path (`seed`) installs: every declared global matches (`t_global_get` over the
/// threaded record == `global_get` over the seeded cell), and the `mem`/`table` sentinels
/// match. Pins that a `Threaded` build and a `Cell` build start from BYTE-IDENTICAL state
/// (G7 — the shared `build` constructor), so they cannot diverge.
pub fn fresh_matches_seed_materialisation_test() {
  let sentinel_m = dynamic.string("mem-parity")
  let sentinel_t = dynamic.string("table-parity")
  let decl =
    StateDecl(
      mem: sentinel_m,
      globals: [#("g", 7), #("h", 9)],
      table: sentinel_t,
    )

  // Threaded materialisation.
  let st = rt_state.fresh(decl)

  // Cell materialisation of the SAME decl.
  rt_state.seed(decl)

  // Field-by-field parity.
  rt_state.t_global_get(st, "g")
  |> should.equal(rt_state.global_get("g"))
  rt_state.t_global_get(st, "h")
  |> should.equal(rt_state.global_get("h"))
  rt_state.mem(st) |> should.equal(rt_state.mem_get())
  rt_state.table(st) |> should.equal(rt_state.table_get())
}

// ── P3. Threaded global get/set — value semantics (the original is never mutated) ─

/// `t_global_set` returns a NEW record with only the named global rebound; the ORIGINAL
/// record is unchanged (value semantics / purity). After `st2 = t_global_set(st1, "g", 42)`:
/// `st2` sees `g == 42` and the untouched `h == 9`, while `st1` STILL sees `g == 7`. This is
/// the property the cell strategy cannot have (its write mutates the one shared cell).
pub fn threaded_global_set_is_pure_test() {
  let st1 =
    rt_state.fresh(StateDecl(
      mem: dynamic.nil(),
      globals: [#("g", 7), #("h", 9)],
      table: dynamic.nil(),
    ))

  let st2 = rt_state.t_global_set(st1, "g", 42)

  // The updated record: only `g` changed.
  rt_state.t_global_get(st2, "g") |> should.equal(42)
  rt_state.t_global_get(st2, "h") |> should.equal(9)

  // The ORIGINAL record is untouched (immutability / value semantics).
  rt_state.t_global_get(st1, "g") |> should.equal(7)
  rt_state.t_global_get(st1, "h") |> should.equal(9)
}

/// A threaded write to an UNDECLARED global fails closed: `t_global_get` of a name that was
/// never in the decl `panic`s (an internal invariant violation, NOT a WASM trap; unreachable
/// post-validation) rather than fabricating a value.
pub fn threaded_global_get_fails_closed_on_undeclared_test() {
  let st =
    rt_state.fresh(StateDecl(
      mem: dynamic.nil(),
      globals: [#("g", 1)],
      table: dynamic.nil(),
    ))
  catch_thunk(fn() { rt_state.t_global_get(st, "does_not_exist") })
  |> result.is_error
  |> should.be_true
}

// ── P4. Float globals are bit-exact through the record (D5) ────────────────────

/// f32/f64 globals carrying NaN-payload, `-0.0`, and `±Inf` bit patterns (as `Int`) survive
/// `fresh` and `t_global_set`/`t_global_get` IDENTICALLY — a BEAM-double round-trip would
/// mangle a NaN payload / signalling bit or collapse `-0.0`. The threaded record stores the
/// `Int` verbatim, exactly like the cell path.
pub fn threaded_float_globals_are_bit_exact_test() {
  let f32_nan_payload = 0x7FC00001
  let f32_neg_zero = 0x80000000
  let f32_pos_inf = 0x7F800000
  let f32_neg_inf = 0xFF800000
  let f64_nan_payload = 0x7FF8000000000001
  let f64_neg_zero = 0x8000000000000000
  let f64_pos_inf = 0x7FF0000000000000

  let st =
    rt_state.fresh(StateDecl(
      mem: dynamic.nil(),
      globals: [
        #("f32_nan", f32_nan_payload),
        #("f32_nz", f32_neg_zero),
        #("f32_pinf", f32_pos_inf),
        #("f32_ninf", f32_neg_inf),
        #("f64_nan", f64_nan_payload),
        #("f64_nz", f64_neg_zero),
        #("f64_pinf", f64_pos_inf),
      ],
      table: dynamic.nil(),
    ))

  rt_state.t_global_get(st, "f32_nan") |> should.equal(f32_nan_payload)
  rt_state.t_global_get(st, "f32_nz") |> should.equal(f32_neg_zero)
  rt_state.t_global_get(st, "f32_pinf") |> should.equal(f32_pos_inf)
  rt_state.t_global_get(st, "f32_ninf") |> should.equal(f32_neg_inf)
  rt_state.t_global_get(st, "f64_nan") |> should.equal(f64_nan_payload)
  rt_state.t_global_get(st, "f64_nz") |> should.equal(f64_neg_zero)
  rt_state.t_global_get(st, "f64_pinf") |> should.equal(f64_pos_inf)

  // A SET of a NaN payload is equally bit-exact (write path, not just the fresh path).
  let st2 = rt_state.t_global_set(st, "f64_nz", f64_nan_payload)
  rt_state.t_global_get(st2, "f64_nz") |> should.equal(f64_nan_payload)
}

// ── P5. Two threaded instances in ONE process never share (E3/G6) ──────────────

/// Because the state is a VALUE, one process can hold two independent instances with no
/// cross-talk and no pdict. Build `a` (`g=1`) and `b` (`g=2`); set `a2 = t_global_set(a, "g",
/// 99)`. Then `b` is untouched (`2`), the original `a` is untouched (`1`), and only `a2`
/// reflects `99`. There is NO ambient state to isolate — the strongest per-instance isolation.
pub fn two_threaded_instances_never_share_test() {
  let a =
    rt_state.fresh(StateDecl(
      mem: dynamic.nil(),
      globals: [#("g", 1)],
      table: dynamic.nil(),
    ))
  let b =
    rt_state.fresh(StateDecl(
      mem: dynamic.nil(),
      globals: [#("g", 2)],
      table: dynamic.nil(),
    ))

  let a2 = rt_state.t_global_set(a, "g", 99)

  rt_state.t_global_get(b, "g") |> should.equal(2)
  rt_state.t_global_get(a, "g") |> should.equal(1)
  rt_state.t_global_get(a2, "g") |> should.equal(99)
}

// ── P6. Tier-P links no pdict — runs-anywhere, behavioural (G6) ─────────────────

/// After a sequence of tier-P ops (`fresh`, `t_global_set`, `with_mem`) in a freshly-cleared
/// process, the process-dictionary cell is STILL un-seeded: the cell accessor (`mem_get`)
/// still fails closed. This proves the tier-P surface wrote NOTHING to the process dictionary
/// — the runs-anywhere property (the tier-P sub-graph reaches none of the module's three
/// pdict externals). (G6.)
pub fn tier_p_surface_writes_no_pdict_test() {
  // Start from a guaranteed-un-seeded cell.
  rt_state.clear()

  // A full tier-P working set — none of these may touch the pdict.
  let st =
    rt_state.fresh(StateDecl(
      mem: dynamic.string("m"),
      globals: [#("g", 1)],
      table: dynamic.string("t"),
    ))
  let st = rt_state.t_global_set(st, "g", 2)
  let st = rt_state.with_mem(st, dynamic.string("m2"))
  let st = rt_state.with_table(st, dynamic.string("t2"))

  // The threaded record carries the effects...
  rt_state.t_global_get(st, "g") |> should.equal(2)
  rt_state.mem(st) |> should.equal(dynamic.string("m2"))

  // ...but the cell was never seeded: the cell accessor still fails closed.
  catch_thunk(fn() { rt_state.mem_get() })
  |> result.is_error
  |> should.be_true
}

// ── P7. Record field seam round-trip (opacity — rt_state never inspects mem/table) ─

/// `with_mem`/`mem` and `with_table`/`table` round-trip an OPAQUE `Dynamic` unchanged, and
/// rebinding one field leaves the others intact: `with_mem(st, m)` changes `mem` but not
/// `table` or the globals; `with_table(st, t)` changes `table` but not `mem`. Sentinel
/// `Dynamic`s stand in for 04/06's real mem/table shapes — proving `rt_state` never inspects
/// them (the opacity seam the tier-P `rt_mem`/`rt_table` wrappers sit on).
pub fn record_field_seam_round_trip_test() {
  let st =
    rt_state.fresh(StateDecl(
      mem: dynamic.string("m0"),
      globals: [#("g", 7)],
      table: dynamic.string("t0"),
    ))

  // Rebind mem: mem changes, table + globals untouched.
  let m1 = dynamic.int(123_456)
  let st_m = rt_state.with_mem(st, m1)
  rt_state.mem(st_m) |> should.equal(m1)
  rt_state.table(st_m) |> should.equal(rt_state.table(st))
  rt_state.t_global_get(st_m, "g") |> should.equal(7)

  // Rebind table: table changes, mem + globals untouched.
  let t1 = dynamic.list([dynamic.int(9)])
  let st_t = rt_state.with_table(st, t1)
  rt_state.table(st_t) |> should.equal(t1)
  rt_state.mem(st_t) |> should.equal(rt_state.mem(st))
  rt_state.t_global_get(st_t, "g") |> should.equal(7)
}

// ═══════════════════════════════════════════════════════════════════════════════
// Unit 09 — the GENERAL seeding surface (`FullDecl` + `seed_full`/`fresh_full`): the
// multi-memory / multi-table / imported-state / reference-global / passive-drop surface
// (R5/R7/R8/R2). Assertions target WebAssembly instantiation semantics:
//
// - **Dense index-keyed vectors, imported-first (R7/H3)** — `mems`/`tables` are seeded in
//   INDEX ORDER; imports occupy the low indices (spec §2.5.1 — imports precede definitions),
//   so `mem_at(i)`/`table_at(i)` read back the i-th element unchanged.
// - **Reference globals (R8)** — funcref/externref globals live on the parallel `ref_globals`
//   map, keyed by name, opaque `Dynamic` (never a raw-bit `Int`).
// - **Passive drop-state (R2)** — a fresh instance drops NOTHING; `drop_data`/`drop_elem` set
//   the flag, `data_dropped`/`elem_dropped` query it (spec §4.4.9 `data.drop`/`elem.drop`).
// - **`fresh_full` ≡ `seed_full` (G7 parity)** — the threaded and cell paths materialise
//   byte-identical state through the shared `build_full`.
// ═══════════════════════════════════════════════════════════════════════════════

// ── F1. `seed_full` seeds N memories/tables in index order (imported-first) ─────

/// `seed_full` installs a dense memories vector and tables vector in INDEX ORDER: seeding
/// `mems = [imported, defined0, defined1]` reads back `mem_at(0) == imported`, `mem_at(1)`,
/// `mem_at(2)` — imports at the low indices (R7/H3). Tables likewise. Rebinding one index leaves
/// the rest intact.
pub fn seed_full_indexes_memories_and_tables_test() {
  let m_imported = dynamic.string("mem-imported")
  let m_def0 = dynamic.string("mem-def0")
  let m_def1 = dynamic.string("mem-def1")
  let t_imported = dynamic.string("tbl-imported")
  let t_def0 = dynamic.string("tbl-def0")

  rt_state.seed_full(
    rt_state.FullDecl(
      mems: [m_imported, m_def0, m_def1],
      globals: [#("g", 5)],
      tables: [t_imported, t_def0],
      ref_globals: [],
    ),
  )

  // Memories read back in index order; imported memory is at index 0.
  rt_state.mem_at(0) |> should.equal(m_imported)
  rt_state.mem_at(1) |> should.equal(m_def0)
  rt_state.mem_at(2) |> should.equal(m_def1)
  // The index-0 alias sees the same default memory.
  rt_state.mem_get() |> should.equal(m_imported)

  // Tables read back in index order; imported table at index 0.
  rt_state.table_at(0) |> should.equal(t_imported)
  rt_state.table_at(1) |> should.equal(t_def0)

  // Rebinding memory index 1 leaves 0 and 2 untouched.
  let m_def0b = dynamic.string("mem-def0-b")
  rt_state.with_mem_at(1, m_def0b)
  rt_state.mem_at(0) |> should.equal(m_imported)
  rt_state.mem_at(1) |> should.equal(m_def0b)
  rt_state.mem_at(2) |> should.equal(m_def1)

  // The numeric global was seeded alongside.
  rt_state.global_get("g") |> should.equal(5)
}

// ── F2. Reference globals seed + round-trip on the parallel path (R8) ────────────

/// `seed_full` installs reference-typed globals into the parallel `ref_globals` map (R8): a
/// funcref and an externref global read back through `ref_global_get`, `ref_global_set` rebinds
/// exactly one, and the raw-bit `globals` path is untouched (the two coexist).
pub fn seed_full_reference_globals_round_trip_test() {
  let rf = dynamic.string("a-funcref")
  let re = dynamic.string("an-externref")

  rt_state.seed_full(
    rt_state.FullDecl(
      mems: [dynamic.nil()],
      globals: [#("n", 42)],
      tables: [dynamic.nil()],
      ref_globals: [#("rf", rf), #("re", re)],
    ),
  )

  rt_state.ref_global_get("rf") |> should.equal(rf)
  rt_state.ref_global_get("re") |> should.equal(re)
  // The numeric global lives on the separate raw-bit path, unaffected.
  rt_state.global_get("n") |> should.equal(42)

  // A ref write rebinds exactly the named reference global.
  let re2 = dynamic.int(999)
  rt_state.ref_global_set("re", re2)
  rt_state.ref_global_get("re") |> should.equal(re2)
  rt_state.ref_global_get("rf") |> should.equal(rf)
}

// ── F3. Passive drop-state: fresh instance drops nothing; drop/query are real (R2) ─

/// A freshly `seed_full`ed instance has dropped NO passive segment; `drop_data`/`drop_elem` set
/// the flag and `data_dropped`/`elem_dropped` query it (spec §4.4.9). Data and element drop-state
/// are independent, and drop is idempotent.
pub fn seed_full_passive_drop_state_test() {
  rt_state.seed_full(
    rt_state.FullDecl(
      mems: [dynamic.nil()],
      globals: [],
      tables: [dynamic.nil()],
      ref_globals: [],
    ),
  )

  // Fresh: nothing dropped.
  rt_state.data_dropped(0) |> should.be_false
  rt_state.data_dropped(3) |> should.be_false
  rt_state.elem_dropped(0) |> should.be_false

  // Drop data segment 3: it (and only it) is now dropped; element state untouched.
  rt_state.drop_data(3)
  rt_state.data_dropped(3) |> should.be_true
  rt_state.data_dropped(0) |> should.be_false
  rt_state.elem_dropped(3) |> should.be_false

  // Drop element segment 1: independent of data drops. Idempotent re-drop is a no-op.
  rt_state.drop_elem(1)
  rt_state.drop_elem(1)
  rt_state.elem_dropped(1) |> should.be_true
  rt_state.data_dropped(1) |> should.be_false
}

// ── F4. `fresh_full` ≡ `seed_full` materialisation (G7 parity) + threaded twins ──

/// The threaded `fresh_full` builds a record field-identical to the cell `seed_full` for ONE
/// `FullDecl`: every memory/table index projects equal through `t_mem_at`/`t_table_at`, reference
/// globals through `t_ref_global_get`, and drop-state starts empty. Pins that `Threaded` and
/// `Cell` start from BYTE-IDENTICAL state (G7).
pub fn fresh_full_matches_seed_full_test() {
  let m0 = dynamic.string("m0")
  let m1 = dynamic.string("m1")
  let t0 = dynamic.string("t0")
  let rf = dynamic.string("rf")
  let decl =
    rt_state.FullDecl(
      mems: [m0, m1],
      globals: [#("n", 7)],
      tables: [t0],
      ref_globals: [#("r", rf)],
    )

  let st = rt_state.fresh_full(decl)
  rt_state.seed_full(decl)

  // Memories: index-by-index parity, imported-first order preserved.
  rt_state.t_mem_at(st, 0) |> should.equal(rt_state.mem_at(0))
  rt_state.t_mem_at(st, 1) |> should.equal(rt_state.mem_at(1))
  rt_state.t_mem_at(st, 0) |> should.equal(m0)
  rt_state.t_mem_at(st, 1) |> should.equal(m1)

  // Tables, numeric global, and reference global parity.
  rt_state.t_table_at(st, 0) |> should.equal(rt_state.table_at(0))
  rt_state.t_global_get(st, "n") |> should.equal(rt_state.global_get("n"))
  rt_state.t_ref_global_get(st, "r")
  |> should.equal(rt_state.ref_global_get("r"))

  // Drop-state starts empty in the threaded record too, and its twins are pure.
  rt_state.t_data_dropped(st, 0) |> should.be_false
  let st2 = rt_state.t_drop_data(st, 0)
  rt_state.t_data_dropped(st2, 0) |> should.be_true
  // Value semantics: the original record is unchanged.
  rt_state.t_data_dropped(st, 0) |> should.be_false
}

// ── boxed non-numeric globals hold v128 (S6) ───────────────────────────────────
//
// A `v128` global is a 16-byte `BitArray` (`<<_:128>>`) — a `Dynamic` that CANNOT live in the
// numeric-`Int` `globals` map (D5 byte-identity) but boxes in the parallel `ref_globals` map
// exactly like a reference value (S6). These prove the SAME boxed accessors round-trip a v128
// bit-exact (16 raw little-endian bytes, including high/sign bytes), seeded from the state decl.
// (The spec value model: a v128 is 16 raw bytes, no lane interpretation —
// <https://webassembly.github.io/spec/core/syntax/values.html#vectors>.)

/// Two distinct 16-byte v128 bit patterns — the second mixes high/sign bytes (a `-0.0`-style top
/// byte + `0xFF` lane bytes) so a lossy round-trip (e.g. through a BEAM double or a truncating
/// path) would corrupt it. Kept as raw `BitArray`s (D5 — the bits, never a decoded structure).
fn v128_a() -> BitArray {
  <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>
}

fn v128_b() -> BitArray {
  <<0xFF, 0xFE, 0, 0, 0, 0, 0, 0x80, 0x7F, 0xC0, 0, 1, 0, 0, 0, 0>>
}

/// CELL path: a v128 global seeded through `FullDecl.ref_globals` reads back bit-exact via
/// `ref_global_get`, and a `global.set` of a new v128 (`ref_global_set`) round-trips — the SAME
/// boxed accessors reference globals use (S6). The 16 raw bytes survive verbatim.
pub fn ref_global_boxes_v128_round_trip_test() {
  let a = v128_a()
  let b = v128_b()
  rt_state.seed_full(
    FullDecl(mems: [], globals: [], tables: [], ref_globals: [
      #("v", dynamic.bit_array(a)),
    ]),
  )

  // The seeded v128 reads back bit-exact.
  rt_state.ref_global_get("v") |> should.equal(dynamic.bit_array(a))

  // `global.set` of a new v128 round-trips (16 raw bytes, high/sign bytes intact).
  rt_state.ref_global_set("v", dynamic.bit_array(b))
  rt_state.ref_global_get("v") |> should.equal(dynamic.bit_array(b))
}

/// THREADED path: the same v128 round-trip through the pure `fresh_full`/`t_ref_global_*` twins,
/// with value semantics — a `t_ref_global_set` returns a NEW record; the original is unchanged
/// (S6 + the §10 uniform-threading rule).
pub fn t_ref_global_boxes_v128_round_trip_test() {
  let a = v128_a()
  let b = v128_b()
  let st0 =
    rt_state.fresh_full(
      FullDecl(mems: [], globals: [], tables: [], ref_globals: [
        #("v", dynamic.bit_array(a)),
      ]),
    )

  rt_state.t_ref_global_get(st0, "v") |> should.equal(dynamic.bit_array(a))

  let st1 = rt_state.t_ref_global_set(st0, "v", dynamic.bit_array(b))
  rt_state.t_ref_global_get(st1, "v") |> should.equal(dynamic.bit_array(b))
  // Value semantics: the original record still holds the seeded v128.
  rt_state.t_ref_global_get(st0, "v") |> should.equal(dynamic.bit_array(a))
}
