//// Unit P4-09 — PROOF 3: constant space under `threaded` (§D, G4).
////
//// Threading a state record adds a loop-carried LEADING parameter and returns a NEW record per
//// store — the exact concern E1 flagged and G4 requires PROVEN, not asserted. The `threaded`
//// instance-state record is a FIXED-SIZE box (`InstanceState(mem, globals, table)` pointing at
//// immutable structures, keystone §A.2), so threading it through a loop does not grow the stack,
//// and each store REBINDS the box (a new 3-tuple sharing two of three fields), never the loop
//// frame. The back-edge stays the tail `apply 'L'(St', vs…)` the Phase-1 template already emits.
////
//// Two programs, run under `threaded`, measured with `ffi.gc_and_memory` — the SAME instrument the
//// Phase-2 `store_loop_constant_space_test` and Phase-3 `spin_traps_in_constant_space_test` use:
////   - `sum_to` — a PURE loop (no stateful op → keystone §A.3 keeps its Phase-1 signature, no `St`
////     threaded), so it must stay constant-space AND byte-identical to `cell`: a pure function pays
////     nothing for the threaded strategy.
////   - `memloop`'s store-loop (`i32.store` EVERY iteration) — threads `St` as a leading param and
////     rebinds the box each store; it must complete, return the byte-identical result to `cell`,
////     and use live process memory bounded by a small constant across a 100× input spread (a
////     per-iteration record leak WOULD blow this up ~100×).
////
//// Preemption is inherent (G4): the threaded loop is ordinary BEAM code under the runtime's
//// reduction counter — the test's COMPLETION of a 100k-iteration loop without unbounded growth is
//// the evidence. Spec: variable/memory instructions
//// <https://webassembly.github.io/spec/core/exec/instructions.html>.

import gleam/erlang/atom
import gleam/int
import twocore/backend/build_beam
import twocore/conformance/ffi
import twocore/ir
import twocore/pipeline
import twocore/runtime/instance.{type Binding, Binding}
import twocore/tier/combos

/// Compile corpus `name` through the full pipeline under `binding` and LOAD it, returning its
/// BEAM module atom (a process-unique name per call so repeated loads never clobber). Drive the
/// loaded module via `ffi.start_instance`, which self-detects the state strategy from
/// `instantiate/0`'s return (`InstanceState` record → the threaded loop).
fn compile_load(name: String, binding: Binding) -> atom.Atom {
  let assert Ok(bytes) = combos.read_wasm(name)
  let assert Ok(m0) = pipeline.source_to_ir(bytes)
  let m =
    ir.Module(..m0, name: m0.name <> "_" <> int.to_string(ffi.unique_int()))
  let assert Ok(cmod) = pipeline.ir_to_cmod(m, binding)
  let assert Ok(mod) = build_beam.compile_and_load(cmod)
  mod
}

/// A threaded×atomics binding with a SMALL bounded cap (`safe_max_pages: 2`) so `memloop`'s
/// no-max memory reserves only 2 pages under `atomics` (well under the reserve cap) — keeping the
/// constant-space measurement dominated by the loop, not a large fixed reservation.
fn threaded_atomics_small_cap() -> Binding {
  Binding(..combos.binding_for(combos.threaded_atomics), safe_max_pages: 2)
}

// ─────────────────────────── PROOF 3a: sum_to (pure loop) ───────────────────────────

/// PROOF 3a (G4). `sum_to` under `threaded×paged` (portable) is a PURE loop, so it stays
/// constant-space: a small `n` and a 100×-larger `n` both complete with live process memory
/// bounded by a small constant (a loop-carried / accumulating leak would blow this up ~100×).
/// Measured via `ffi.gc_and_memory` after the call.
pub fn sum_to_constant_space_threaded_test() {
  let mod = compile_load("sum_to", combos.binding_for(combos.portable))

  let assert Ok(small) = ffi.start_instance(mod)
  let assert Ok(_) = ffi.call_instance(small, atom.create("sum_to"), [1000])
  let mem_small = ffi.gc_and_memory(small)

  let assert Ok(big) = ffi.start_instance(mod)
  let assert Ok(_) = ffi.call_instance(big, atom.create("sum_to"), [100_000])
  let mem_big = ffi.gc_and_memory(big)

  // 100× the iterations stays under a small constant factor of the small run's live memory.
  assert mem_big < mem_small * 4

  ffi.stop_instance(small)
  ffi.stop_instance(big)
}

/// PROOF 3a (byte-identical cross-check). `sum_to` under `threaded×paged` returns the SAME result
/// as under `cell×paged` — the spec value `sum_to(100) == 5050` (no i32 wrap), and the large
/// `sum_to(100000)` wraps identically under both strategies (the value property; §B is the value
/// property, this restates it as the local G4 invariant). A pure function pays nothing for the
/// threaded strategy.
pub fn sum_to_threaded_matches_cell_test() {
  let threaded = compile_load("sum_to", combos.binding_for(combos.portable))
  let cell = compile_load("sum_to", combos.binding_for(combos.cell_paged))
  let assert Ok(tp) = ffi.start_instance(threaded)
  let assert Ok(cp) = ffi.start_instance(cell)

  // Spec value (no wrap): Σ1..100 = 5050 under both strategies.
  assert ffi.call_instance(tp, atom.create("sum_to"), [100]) == Ok(5050)
  assert ffi.call_instance(cp, atom.create("sum_to"), [100]) == Ok(5050)

  // Large input wraps i32 IDENTICALLY under threaded and cell (byte-identical, D7).
  let t_big = ffi.call_instance(tp, atom.create("sum_to"), [100_000])
  let c_big = ffi.call_instance(cp, atom.create("sum_to"), [100_000])
  assert t_big == c_big

  ffi.stop_instance(tp)
  ffi.stop_instance(cp)
}

// ─────────────────────────── PROOF 3b: memloop (the real store-loop property) ───────────────────────────

/// PROOF 3b (G4), the real property. The `memloop` store-loop (`i32.store` EVERY iteration) under
/// `threaded×paged` threads `St` as a leading param and rebinds the box each store; it must
/// complete, return the byte-identical result to `cell` (`store_loop(n) == n-1`), and use live
/// process memory bounded by a small constant across a 100× input spread. A per-iteration record
/// leak WOULD blow this up ~100×.
pub fn store_loop_constant_space_threaded_paged_test() {
  let mod = compile_load("memloop", combos.binding_for(combos.portable))

  let assert Ok(small) = ffi.start_instance(mod)
  assert ffi.call_instance(small, atom.create("store_loop"), [1000]) == Ok(999)
  let mem_small = ffi.gc_and_memory(small)

  let assert Ok(big) = ffi.start_instance(mod)
  assert ffi.call_instance(big, atom.create("store_loop"), [100_000])
    == Ok(99_999)
  let mem_big = ffi.gc_and_memory(big)

  // Constant space under the state-threaded loop (paged: superseded records are garbage, GC'd).
  assert mem_big < mem_small * 4

  ffi.stop_instance(small)
  ffi.stop_instance(big)
}

/// PROOF 3b under `threaded×atomics`. The record's `mem` slot is the SAME mutable ref rebound to
/// itself each store, so the box is truly fixed-size — an even tighter constant. The store-loop
/// completes at 100k iterations, returns `99999`, and stays bounded (a small bounded cap keeps the
/// atomics reservation from dominating the measurement).
pub fn store_loop_constant_space_threaded_atomics_test() {
  let mod = compile_load("memloop", threaded_atomics_small_cap())

  let assert Ok(small) = ffi.start_instance(mod)
  assert ffi.call_instance(small, atom.create("store_loop"), [1000]) == Ok(999)
  let mem_small = ffi.gc_and_memory(small)

  let assert Ok(big) = ffi.start_instance(mod)
  assert ffi.call_instance(big, atom.create("store_loop"), [100_000])
    == Ok(99_999)
  let mem_big = ffi.gc_and_memory(big)

  assert mem_big < mem_small * 4

  ffi.stop_instance(small)
  ffi.stop_instance(big)
}

/// PROOF 3b (byte-identical cross-check). `store_loop(100000) == 99999` under `threaded×paged`,
/// `threaded×atomics`, AND `cell×paged` alike — the constant-space bound is the SPACE property;
/// this is the VALUE property; together they are G4.
pub fn store_loop_threaded_matches_cell_test() {
  let tp = compile_load("memloop", combos.binding_for(combos.portable))
  let ta = compile_load("memloop", threaded_atomics_small_cap())
  let cp = compile_load("memloop", combos.binding_for(combos.cell_paged))
  let assert Ok(tpp) = ffi.start_instance(tp)
  let assert Ok(tap) = ffi.start_instance(ta)
  let assert Ok(cpp) = ffi.start_instance(cp)

  let call = fn(m) {
    ffi.call_instance(m, atom.create("store_loop"), [100_000])
  }
  assert call(tpp) == Ok(99_999)
  assert call(tap) == Ok(99_999)
  assert call(cpp) == Ok(99_999)

  ffi.stop_instance(tpp)
  ffi.stop_instance(tap)
  ffi.stop_instance(cpp)
}
