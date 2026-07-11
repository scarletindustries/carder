//// Unit P4-08 — pipeline binding-threading + CLI tier/strategy selection tests.
////
//// These prove the three jobs of P4-08 against the SPEC/decisions (not the emitter output —
//// no change-detector tests):
////
//// 1. **The CLI selects each posture, fail-closed, through `link/1` alone** (decision #5,
////    G3/G6, P5). `resolve_binding` composes the axis flags into one coherent `Binding` and
////    validates it through `profiles.link/1`; a Safe + `nif` request and an uncapped
////    `atomics`/`ceiling` build are rejected fail-closed; the `--tier atomics` coupling makes
////    `mem_module` follow the declared tier (`rt_mem_atomics`, not the base's stale `paged`).
//// 2. **The run-ABI works under `Threaded` + `atomics`** (G7). A stateful module round-trips
////    and PERSISTS state across two invokes on one instance (the FFI threaded loop threads the
////    `InstanceState` record `St'`); a *pure* export under a `Threaded` build returns the right
////    value (the uniform threaded export ABI); an `atomics` build links `rt_mem_atomics` and
////    runs; and `add`/`sum_to` return byte-identical results across every `(strategy × tier)`.
//// 3. **Every stage stays independently invokable** under a Phase-4 posture — `to-core
////    --portable`, `emit --tier atomics` each print their stage's output.

import gleam/option
import gleam/string
import twocore
import twocore/ir
import twocore/pipeline
import twocore/runtime/instance.{type Binding, Atomics, Binding, Nif, Threaded}
import twocore/runtime/profiles

const corpus = "test/twocore/conformance/corpus"

const golden = "test/twocore/ir/golden"

// ─────────────────────────────── fixtures ───────────────────────────────

/// A pure `add(i32, i32) -> i32` module (memoryless) — the pure-export fixture: under a
/// `Threaded` build it must present the uniform `add(St, A, B) -> {Sum, St}` ABI and still
/// compute the spec sum.
fn add_module() -> ir.Module {
  ir.Module(
    name: "twocore@tier@add",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        name: "add",
        params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
        result: [ir.TI32],
        locals: [],
        body: ir.Let(
          ["r"],
          ir.Num(ir.IAdd(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
          ir.Return([ir.Var("r")]),
        ),
      ),
    ],
    exports: [ir.ExportFn("add", "add")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// A stateful module with a mutable global `g0` (init `7`) exporting `get`/`set` — the fixture
/// for cross-invoke state persistence: `set(99)` then `get()` on the SAME instance must observe
/// the persisted `99`.
fn global_module() -> ir.Module {
  ir.Module(
    name: "twocore@tier@global",
    uses_numerics: True,
    memories: [],
    globals: [ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(7)]))],
    imports: [],
    functions: [
      ir.Function("get", [], [ir.TI32], [], ir.GlobalGet("g0")),
      ir.Function(
        "set",
        [ir.Local("v", ir.TI32)],
        [],
        [],
        ir.Let([], ir.GlobalSet("g0", ir.Var("v")), ir.Values([])),
      ),
    ],
    exports: [ir.ExportFn("get", "get"), ir.ExportFn("set", "set")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// A linear-memory module (1 page) exporting `store32`/`load32` — the fixture that genuinely
/// EXERCISES the linked `rt_mem`/`rt_mem_atomics` backend: `store32(0, X)` then `load32(0)`
/// must return `X`.
fn memory_module() -> ir.Module {
  ir.Module(
    name: "twocore@tier@mem",
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        "store32",
        [ir.Local("addr", ir.TI32), ir.Local("val", ir.TI32)],
        [],
        [],
        ir.Let(
          [],
          ir.MemStore(
            0,
            ir.MemAccess(4, False),
            ir.Var("addr"),
            ir.Var("val"),
            0,
          ),
          ir.Values([]),
        ),
      ),
      ir.Function(
        "load32",
        [ir.Local("addr", ir.TI32)],
        [ir.TI32],
        [],
        ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("addr"), 0, ir.TI32),
      ),
    ],
    exports: [
      ir.ExportFn("store32", "store32"),
      ir.ExportFn("load32", "load32"),
    ],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

// ─────────────────────────────── run-ABI helpers ───────────────────────────────

/// Compile `module` under `binding` through the WHOLE run-ABI (`ir_to_core → core_to_beam →
/// instantiate → invoke_instance → stop_instance`) and return the single invoke's outcome. The
/// run-ABI self-detects the state strategy, so this drives both the `Cell` and `Threaded`
/// conventions with no per-strategy code here (unit P4-08 §C.2).
fn run_one(
  binding: Binding,
  module: ir.Module,
  export: String,
  args: List(Int),
) -> pipeline.RunResult {
  let assert Ok(core) = pipeline.ir_to_core(module, binding)
  let assert Ok(beam) = pipeline.core_to_beam(core, module.name)
  let assert Ok(proc) = pipeline.instantiate(beam, module.name)
  let result = pipeline.invoke_instance(proc, export, args)
  pipeline.stop_instance(proc)
  result
}

/// A Safe binding switched to the tier-P `Threaded` state strategy (same runtime modules, only
/// the codegen shape / run-ABI convention differ).
fn threaded() -> Binding {
  Binding(..profiles.safe(), state_strategy: Threaded)
}

/// A Safe binding on the tier-O `Atomics` memory over a BOUNDED cap (`safe_max_pages: 16`, well
/// under `atomics_reserve_cap_pages`), tier→module coupled via `resolve_tiers` so `mem_module`
/// is `rt_mem_atomics`. Without the bounded cap `link`/`a_fresh` would fail closed.
fn atomics_capped() -> Binding {
  profiles.resolve_tiers(
    Binding(..profiles.safe(), mem_tier: Atomics, safe_max_pages: 16),
  )
}

// ════════════════════ 1. the run-ABI under Threaded (state travels as a value) ════════════════════

/// THE headline run-ABI proof: under a `Threaded` build, state PERSISTS across two SEPARATE
/// invokes on one instance — `set(99)` then `get()` observes `99`. The instance's state lives in
/// the `InstanceState` record the owned process threads across invokes (a loop variable, not a
/// pdict cell); the run-ABI signature is unchanged. (Spec: `global.set`/`global.get` semantics;
/// P4-08 §C — cross-invoke threading.)
pub fn threaded_state_persists_across_invokes_test() {
  let m = global_module()
  let assert Ok(core) = pipeline.ir_to_core(m, threaded())
  let assert Ok(beam) = pipeline.core_to_beam(core, m.name)
  let assert Ok(proc) = pipeline.instantiate(beam, m.name)
  // get reads the constant init 7.
  assert pipeline.invoke_instance(proc, "get", []) == pipeline.Returned([7])
  // set 99 — the threaded record is updated inside the owned process.
  let _ = pipeline.invoke_instance(proc, "set", [99])
  // get on the NEXT invoke sees 99 — state persisted across invokes via the threaded value.
  assert pipeline.invoke_instance(proc, "get", []) == pipeline.Returned([99])
  pipeline.stop_instance(proc)
}

/// A PURE export under a `Threaded` build returns the right value (the §C.2 uniform threaded
/// export ABI cross-check on unit 02): `add` reaches no state, yet its export threads `St`
/// through unchanged and still computes `add(2,3) == 5`.
pub fn threaded_pure_export_returns_value_test() {
  assert run_one(threaded(), add_module(), "add", [2, 3])
    == pipeline.Returned([5])
}

/// A `Threaded` memory build round-trips through the run-ABI: `store32(0, X)` then `load32(0)`
/// returns `X`, threaded across invokes (spec `exec/memory` little-endian round-trip).
pub fn threaded_memory_roundtrip_test() {
  let m = memory_module()
  let assert Ok(core) = pipeline.ir_to_core(m, threaded())
  let assert Ok(beam) = pipeline.core_to_beam(core, m.name)
  let assert Ok(proc) = pipeline.instantiate(beam, m.name)
  let _ = pipeline.invoke_instance(proc, "store32", [0, 305_419_896])
  assert pipeline.invoke_instance(proc, "load32", [0])
    == pipeline.Returned([305_419_896])
  pipeline.stop_instance(proc)
}

// ════════════════════ 2. the atomics tier links + runs through the run-ABI ════════════════════

/// An `atomics` build LINKS `rt_mem_atomics` (the tier→module coupling ran) AND runs: the
/// emitted `.core` names `twocore@runtime@rt_mem_atomics` (not the base's stale `rt_mem`), and a
/// memory round-trip through the run-ABI returns the stored bits — so the tier-O backend is
/// exercised end-to-end, byte-identically to the paged result. (Spec `exec/memory`; G5/G7.)
pub fn atomics_build_links_and_runs_test() {
  let m = memory_module()
  let binding = atomics_capped()
  // the tier is a MODULE SWAP the emitter links via `mem_module` (G5).
  let assert Ok(core) = pipeline.ir_to_core(m, binding)
  assert string.contains(core, "twocore@runtime@rt_mem_atomics")
  assert !string.contains(core, "'twocore@runtime@rt_mem':")
  // and it runs — the tier-O backend round-trips a store/load.
  let assert Ok(beam) = pipeline.core_to_beam(core, m.name)
  let assert Ok(proc) = pipeline.instantiate(beam, m.name)
  let _ = pipeline.invoke_instance(proc, "store32", [0, 305_419_896])
  assert pipeline.invoke_instance(proc, "load32", [0])
    == pipeline.Returned([305_419_896])
  pipeline.stop_instance(proc)
}

/// The G7 byte-identity bar: `add(2,3) == 5` returns the SAME spec-correct result across every
/// shipped `(state_strategy × mem_tier)` combination — `safe()`, `+Threaded`,
/// `+Atomics(capped)`, `+both` — proving a Phase-4 posture never changes an observable answer.
pub fn add_byte_identical_across_postures_test() {
  let both =
    profiles.resolve_tiers(
      Binding(..threaded(), mem_tier: Atomics, safe_max_pages: 16),
    )
  assert run_one(profiles.safe(), add_module(), "add", [2, 3])
    == pipeline.Returned([5])
  assert run_one(threaded(), add_module(), "add", [2, 3])
    == pipeline.Returned([5])
  assert run_one(atomics_capped(), add_module(), "add", [2, 3])
    == pipeline.Returned([5])
  assert run_one(both, add_module(), "add", [2, 3]) == pipeline.Returned([5])
}

// ════════════════════ 3. resolve_binding — the CLI axis selector (fail-closed, link/1) ════════════════════

/// The fail-closed DEFAULT: no flags → Safe / `Cell` / `Paged` (D4). Leaving it requires a named
/// token; omission never yields a non-default posture.
pub fn resolve_binding_default_is_safe_cell_paged_test() {
  let assert Ok(b) =
    twocore.resolve_binding(
      profiles.safe(),
      False,
      False,
      option.None,
      option.None,
      option.None,
    )
  assert b.mode == instance.Safe
  assert b.state_strategy == instance.Cell
  assert b.mem_tier == instance.Paged
}

/// `--threaded` selects `state_strategy: Threaded` (the record-threading build).
pub fn resolve_binding_threaded_test() {
  let assert Ok(b) =
    twocore.resolve_binding(
      profiles.safe(),
      True,
      False,
      option.None,
      option.None,
      option.None,
    )
  assert b.state_strategy == Threaded
}

/// `--tier atomics` (with a bounded cap) sets `mem_tier: Atomics` AND couples `mem_module` to
/// `rt_mem_atomics` via `resolve_tiers` (P5) — the declared tier is NOT advisory: the module the
/// seam links follows it, not the base's stale `paged` module.
pub fn resolve_binding_atomics_couples_module_test() {
  let assert Ok(b) =
    twocore.resolve_binding(
      profiles.safe(),
      False,
      False,
      option.Some(Atomics),
      option.None,
      option.Some(16),
    )
  assert b.mem_tier == Atomics
  assert b.mem_module == "twocore@runtime@rt_mem_atomics"
}

/// `--portable` yields `profiles.portable()` and `--ceiling` (with a bounded cap) yields the
/// Unsafe/`Atomics` perf posture — the two composed deployment profiles selectable by name.
pub fn resolve_binding_composed_profiles_test() {
  let assert Ok(p) =
    twocore.resolve_binding(
      profiles.portable(),
      False,
      False,
      option.None,
      option.None,
      option.None,
    )
  assert p == profiles.portable()

  let assert Ok(c) =
    twocore.resolve_binding(
      profiles.ceiling(),
      False,
      False,
      option.None,
      option.None,
      option.Some(16),
    )
  assert c.mode == instance.Unsafe
  assert c.mem_tier == Atomics
}

/// Safe + `nif` is REJECTED fail-closed at the CLI (G6): a Safe base with `--tier nif` returns
/// an `Error` whose message names the incoherence — never silently downgraded to `paged`.
pub fn resolve_binding_safe_nif_rejected_test() {
  let result =
    twocore.resolve_binding(
      profiles.safe(),
      False,
      False,
      option.Some(Nif),
      option.None,
      option.None,
    )
  let assert Error(msg) = result
  assert string.contains(msg, "nif")
}

/// `nif` memory is reachable by ALSO naming an Unsafe base: `--unsafe --tier nif` is accepted
/// (the fail-closed rule is Safe-specific, G6).
pub fn resolve_binding_unsafe_nif_accepted_test() {
  let assert Ok(b) =
    twocore.resolve_binding(
      profiles.unsafe(),
      False,
      False,
      option.Some(Nif),
      option.None,
      option.None,
    )
  assert b.mem_tier == Nif
}

/// An uncapped `atomics` build is REJECTED fail-closed (P6): without a bounded cap the tier-O
/// reservation would exceed the node-safe ceiling, so `resolve_binding` returns an `Error` that
/// names the cap requirement — never a silent 4 GiB pre-allocation, never a paged fallback.
pub fn resolve_binding_uncapped_atomics_rejected_test() {
  let assert Error(msg) =
    twocore.resolve_binding(
      profiles.safe(),
      False,
      False,
      option.Some(Atomics),
      option.None,
      option.None,
    )
  assert string.contains(msg, "cap")
}

/// An uncapped `--ceiling` build is likewise REJECTED fail-closed (its inherited `safe_max_pages`
/// exceeds the reserve cap), and supplying a bounded `--cap` admits it — the packaged perf build
/// engages only over a bounded memory reservation (P6/§C).
pub fn resolve_binding_ceiling_requires_cap_test() {
  let assert Error(msg) =
    twocore.resolve_binding(
      profiles.ceiling(),
      False,
      False,
      option.None,
      option.None,
      option.None,
    )
  assert string.contains(msg, "cap")

  let assert Ok(_) =
    twocore.resolve_binding(
      profiles.ceiling(),
      False,
      False,
      option.None,
      option.None,
      option.Some(16),
    )
}

// ════════════════════ CLI end-to-end (every posture runs through `twocore.run`) ════════════════════

/// `run --threaded add.wasm add 2 3` prints `5` — a `Threaded` build runs end-to-end through the
/// strategy-aware run-ABI, byte-identical to the default (G7).
pub fn cli_run_threaded_add_test() {
  assert twocore.run([
      "run",
      "--threaded",
      corpus <> "/add.wasm",
      "add",
      "2",
      "3",
    ])
    == Ok("5")
}

/// `run --threaded sum_to.wasm sum_to 100` prints `5050` — the constant-space loop runs under
/// the record-threading convention with the SAME spec result as `Cell`.
pub fn cli_run_threaded_sum_to_test() {
  assert twocore.run([
      "run",
      "--threaded",
      corpus <> "/sum_to.wasm",
      "sum_to",
      "100",
    ])
    == Ok("5050")
}

/// `run --portable add.wasm add 2 3` prints `5` — the runs-anywhere composed profile runs
/// end-to-end through the CLI.
pub fn cli_run_portable_add_test() {
  assert twocore.run([
      "run",
      "--portable",
      corpus <> "/add.wasm",
      "add",
      "2",
      "3",
    ])
    == Ok("5")
}

/// `run --ceiling --cap 16 add.wasm add 2 3` prints `5` — the perf posture (Unsafe/atomics) runs
/// end-to-end once a bounded cap is named.
pub fn cli_run_ceiling_capped_add_test() {
  assert twocore.run([
      "run",
      "--ceiling",
      "--cap",
      "16",
      corpus <> "/add.wasm",
      "add",
      "2",
      "3",
    ])
    == Ok("5")
}

/// `run --tier nif …` (Safe base) is REJECTED end-to-end (exit non-zero) with a message naming
/// the incoherence — the CLI face of Safe-forbids-nif (G6). It never runs.
pub fn cli_run_safe_nif_rejected_test() {
  let assert Error(msg) =
    twocore.run(["run", "--tier", "nif", corpus <> "/add.wasm", "add", "2", "3"])
  assert string.contains(msg, "nif")
}

/// `run --tier atomics …` without `--cap` is REJECTED end-to-end (uncapped atomics is
/// fail-closed) with a message naming the cap requirement.
pub fn cli_run_uncapped_atomics_rejected_test() {
  let assert Error(msg) =
    twocore.run([
      "run",
      "--tier",
      "atomics",
      corpus <> "/add.wasm",
      "add",
      "2",
      "3",
    ])
  assert string.contains(msg, "cap")
}

/// Two base flags are REJECTED (they are mutually exclusive, §B.1).
pub fn cli_conflicting_base_flags_rejected_test() {
  let assert Error(_) =
    twocore.run([
      "run",
      "--portable",
      "--unsafe",
      corpus <> "/add.wasm",
      "add",
      "2",
      "3",
    ])
}

// ════════════════════ 3. every stage stays independently invokable (decision #5) ════════════════════

/// `to-core --portable <in.ir>` prints the `Threaded`/`paged` `.core` WITHOUT running it — the
/// stage stays independently invokable under a Phase-4 posture (no stage folded away).
pub fn cli_to_core_portable_independently_invokable_test() {
  let assert Ok(text) =
    twocore.run(["to-core", "--portable", golden <> "/add.ir"])
  assert string.contains(text, "module 'add'")
}

/// `emit --tier atomics --cap 16 <mem.ir>` prints the `atomics`-linked codegen — the raw
/// `emit_core` stage, selecting the tier-O backend, remains independently invokable.
pub fn cli_emit_tier_atomics_links_module_test() {
  let assert Ok(text) =
    twocore.run([
      "emit",
      "--tier",
      "atomics",
      "--cap",
      "16",
      golden <> "/mem_table.ir",
    ])
  assert string.contains(text, "twocore@runtime@rt_mem_atomics")
}
