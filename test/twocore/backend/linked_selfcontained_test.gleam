//// Phase 11 · P11-06 — the CAPSTONE. **PHASE 11 PROVEN.**
////
//// Proves the `phase-11/00-overview.md` §1 acceptance table for `--link`: a single
//// self-contained `.beam` — the generated module with its whole `twocore@`/`gleam@`
//// runtime closure merged in and dead code stripped — is byte-behaviour-identical to the
//// normal in-process path AND boots on a bare OTP node. The proof is objective and
//// differential: it never asserts against "whatever bytes the compiler emits", it asserts
//// against the WebAssembly spec (`corpus/*.expected`, bit-pattern values, spec trap phrases)
//// and against the linked-vs-non-linked DIFFERENTIAL (O5 — a pure packaging transform must
//// change no observable). Two layers plus three correctness-hygiene assertions:
////
//// - **L1 — in-process linked ≡ non-linked differential (isolates merge-correctness, cheap).**
////   Over the corpus × `{Safe,Unsafe} × {Cell,Threaded} × {Paged,Atomics}`, the LINKED output
////   (via `beam_link.link_program`, loaded in-process) must return bit-identical, trap-identical
////   `Outcome`s to the non-linked oracle (`driver.pipeline_with`). Fun-captures (R4),
////   intra-module apply (R5) and the `instantiate/N` DCE root (R6) fall out as organic
////   regressions. One authored import-bearing fixture (an imported `spectest` global) exercises
////   the merged `instantiate/1` in-process (honest-scope home, R14 keeps it out of L2).
//// - **L2 — bare-node differential (measured, not asserted).** Over the import-free subset ×
////   `state_strategy × {tier-P, tier-O}`, the P11-05 harness (`twocore_linked_boot_ffi`) boots a
////   scrubbed fresh `erl` with only the merged `.beam` on `-pa`, its `code:which` gate proving no
////   `twocore@`/`gleam@` reachable, and its value/trap must match the in-process oracle. Plus a
////   `sum_to(100000)` constant-space proof (mirrors the "runs 100k iters in constant space"
////   precedent).
//// - **Determinism (R10):** `link_program` twice ⇒ byte-identical `.beam`.
//// - **D3a (R9):** a structural assertion over the *merged* Core of the whole corpus — no
////   `erlang:apply`, no off-allowlist remote, no residual off-closure fun-capture — complementing
////   the linker's built-in fail-closed self-check. Plus the R11 export-set check.
//// - **Fail-closed confirm (R13/R14):** `--link` + tier-N and `--link` + import-bearing are
////   refused with a typed error (P11-04 owns the primary CLI test; this confirms the gate).
////
//// Spec anchors: numerics <https://webassembly.github.io/spec/core/exec/numerics.html>,
//// bounds/traps <https://webassembly.github.io/spec/core/exec/instructions.html>. Every value
//// is bit-pattern-compared (D5/D7); every trap via `runner.trap_matches` / raw-reason identity.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import twocore
import twocore/backend/beam_link.{
  type LinkError, AmbientAuthorityFound, CoreAcquisitionFailed, MalformedCore,
  MangleCollision, MissingClosureModule, OffAllowlistRemote,
  UnmergeableConstruct,
}
import twocore/backend/build_beam
import twocore/backend/core_erlang
import twocore/backend/core_printer
import twocore/backend/eaf
import twocore/backend/link_manifest
import twocore/conformance/driver
import twocore/conformance/ffi
import twocore/conformance/runner
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/lower
import twocore/frontend/wasm/validate
import twocore/ir
import twocore/pipeline.{Returned, Trapped}
import twocore/runtime/instance.{
  type Binding, Atomics, Binding, Cell, Nif, Paged, TableAtomics, TablePaged,
  Threaded,
}
import twocore/runtime/link
import twocore/runtime/profiles
import twocore/tier/combos

// ───────────────────────── test-only externals ─────────────────────────

/// Boot `beam` on a FRESH, environment-scrubbed, code-path-isolated `erl` (P11-05) and, in ONE
/// child, run `instantiate()` then invoke `function(args)` (seed-then-call, R6). `extra` are extra
/// `#(mod, beam)` pairs on a SEPARATE `-pa` (`[]` = the isolated case L2 uses). Returns
/// `#(exit_status, combined_stdout)`: exit `0` + `RESULT:<v>` = ran clean (isolation HELD — the
/// in-child gate halts before invoke on any leak), `0` + `TRAP:<r>` = trapped, `3` + `LEAK:` =
/// gate hit, `4` + `NOLOAD:` = not on child path, `127` = no `erl`.
@external(erlang, "twocore_linked_boot_ffi", "boot_invoke")
fn boot_invoke(
  beam: BitArray,
  module: Atom,
  function: Atom,
  args: List(Int),
  extra: List(#(Atom, BitArray)),
) -> #(Int, String)

/// Apply `M:F(Args)` in the calling process, catching a trap/denial as `Error(text)` — the same
/// seam the emit e2e / `beam_link` tests use, retyped for the `instantiate/1(Imports)` ABI's single
/// `Dynamic` argument.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply_dyn(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

/// Identity coercion to `Dynamic` (identity at runtime) — hands the positional `List(Provided)`
/// import vector to a merged `instantiate/1` as one opaque argument (the driver's shape ABI).
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

// ───────────────────────── shared plumbing ─────────────────────────

/// The frozen OTP-ambient allowlist (the DCE stop-set) every merge in this suite consumes (R7).
fn ambient() -> List(String) {
  link_manifest.ambient_allowlist()
}

/// Lower a backend `CModule` to the abstract FORMS the linker consumes
/// (`let assert` — a lowering failure is a genuine test failure).
fn forms_of(cmod: core_erlang.CModule) -> List(eaf.Form) {
  let assert Ok(forms) = eaf.module_forms(cmod)
  forms
}

/// Render a `LinkError` as a one-line diagnostic covering ALL SEVEN variants (so a merge failure
/// surfaces a readable reason instead of a `let assert` panic). Contract: total; the returned
/// string names the offending module/detail. Used by the linked driver's error channel and the
/// L2/D3a drivers.
fn describe_link_error(e: LinkError) -> String {
  case e {
    OffAllowlistRemote(m, f) -> "off-allowlist remote " <> m <> ":" <> f
    MissingClosureModule(m) -> "missing closure module " <> m
    AmbientAuthorityFound(d) -> "ambient authority: " <> d
    UnmergeableConstruct(d) -> "unmergeable construct: " <> d
    MangleCollision(a, b) -> "mangle collision " <> a <> "/" <> b
    MalformedCore(d) -> "malformed core: " <> d
    CoreAcquisitionFailed(m, r) -> "core acquisition failed " <> m <> ": " <> r
  }
}

// ───────────────────────── the L1 linked driver ─────────────────────────
//
// A `runner.Driver` identical to `driver.pipeline_with(binding)` (the oracle) EXCEPT the tail:
// where the oracle does `build_beam.compile_and_load(core)` (a THIN module over the resident
// runtime), the linked driver does `beam_link.link_program(core, name, ambient) → load_module` (a
// SELF-CONTAINED merged module). Everything upstream — decode/validate/lower, the import link, the
// `ir_to_core(binding)` codegen — is the SAME public chain the oracle runs, so the differential
// isolates the merge as the only difference. Because L1 asserts linked ≡ oracle, any drift of this
// ported chain from the oracle's private `instantiate_typed` would itself turn the differential red
// — the replica is self-checking.

/// Build the linked driver for `binding`: the oracle's `invoke`/`check_frontend`/`get_global`
/// unchanged, with the instantiate seam swapped to interpose the whole-program merge at the
/// `.core → .beam` boundary. Only `instantiate`/`instantiate_env` are used by `combos.evaluate`;
/// the AST seam is unused here.
fn linked_driver(binding: Binding) -> runner.Driver {
  runner.Driver(
    check_frontend: driver.check_frontend,
    instantiate: fn(bytes) {
      linked_instantiate(binding, bytes, driver.empty_env())
    },
    invoke: driver.invoke,
    instantiate_env: fn(bytes, env) { linked_instantiate(binding, bytes, env) },
    instantiate_ast: fn(_m, _env) { Error("linked driver: ast path unused") },
    check_frontend_ast: driver.check_frontend_ast,
    get_global: driver.get_global,
  )
}

/// Compile `bytes` under `binding` through the REAL pipeline, MERGE the result into a self-contained
/// `.beam` (`link_program`), load it, and instantiate it in its own owned process (E5) — the linked
/// analog of `driver.instantiate_under`. Mirrors `driver.gleam`'s private `instantiate_typed`,
/// swapping ONLY `compile_and_load` for `link_program` + `load_module`.
///
/// - `binding`: the build-time posture (mode × tiers × strategy) — drives `ir_to_core`.
/// - `bytes`: the `.wasm` module bytes.
/// - `env`: the import environment (`spectest` is built into `link.link_imports`; extra providers
///   come from `env`). `combos.evaluate` passes the empty env.
/// - Returns `Ok(Instance)` (a live merged instance) or `Error(reason)` for any stage that rejects
///   fail-closed (decode/validate/lower/link/`link_program`/load/instantiate-trap) — never a panic.
fn linked_instantiate(
  binding: Binding,
  bytes: BitArray,
  env: runner.ImportEnv,
) -> Result(runner.Instance, String) {
  use m <- result.try(
    decode.decode(bytes)
    |> result.map_error(fn(e) { "decode: " <> string.inspect(e) }),
  )
  use tm <- result.try(
    validate.validate(m)
    |> result.map_error(fn(e) { "validate: " <> string.inspect(e) }),
  )
  use irmod0 <- result.try(
    lower.lower(tm)
    |> result.map_error(fn(e) { "lower: " <> string.inspect(e) }),
  )
  let irmod = ir.Module(..irmod0, name: uniquify(irmod0.name))
  use state_provided <- result.try(
    link.link_imports(irmod, env.providers)
    |> result.map_error(fn(e) { "link: " <> link.import_error_phrase(e) }),
  )
  use provided <- result.try(case module_calls_import(irmod) {
    False -> Ok(state_provided)
    True ->
      case func_imports_all_provided(irmod, env.providers) {
        False ->
          Error(
            "link: unknown import (host capability not provided under the deny-all host)",
          )
        True ->
          link.link_func_imports(irmod, env.providers)
          |> result.map(fn(fp) { list.append(state_provided, fp) })
          |> result.map_error(fn(e) { "link: " <> link.import_error_phrase(e) })
      }
  })
  use cmod <- result.try(
    pipeline.ir_to_cmod(irmod, binding)
    |> result.map_error(pipeline.describe),
  )
  // THE ONE DIFFERENCE from the oracle: merge the runtime closure IN, rather than call it out.
  use pair <- result.try(
    beam_link.link_program(forms_of(cmod), irmod.name, ambient())
    |> result.map_error(fn(e) { "link_program: " <> describe_link_error(e) }),
  )
  let #(mod_atom, beam) = pair
  use loaded <- result.try(
    build_beam.load_module(mod_atom, "linked.beam", beam)
    |> result.map_error(fn(r) { "load: " <> r }),
  )
  let started = case provided {
    [] -> ffi.start_instance(loaded)
    _ -> ffi.start_instance_with(loaded, to_dynamic(provided))
  }
  case started {
    Ok(proc) ->
      Ok(runner.Instance(
        proc: proc,
        exports: export_types(irmod),
        func_sigs: dict.new(),
      ))
    Error(trap) -> Error("instantiate: " <> trap)
  }
}

/// Append a process-unique suffix so concurrent linked builds never share a BEAM module atom (a
/// name collision would hot-replace the earlier module). Mirrors `driver.gleam`'s `uniquify`.
fn uniquify(name: String) -> String {
  name <> "_" <> int.to_string(ffi.unique_int())
}

/// Build `export name → result value-types` for the merged instance's `invoke` tag dispatch —
/// mirrors `driver.gleam`'s private `export_types` (function exports → result types; exported
/// globals → the global's declared type as a 0-arg accessor; tables/memories/tags omitted).
fn export_types(m: ir.Module) -> dict.Dict(String, List(ir.ValType)) {
  let by_fn =
    list.fold(m.functions, dict.new(), fn(acc, f) {
      dict.insert(acc, f.name, f.result)
    })
  let by_global =
    list.fold(m.globals, dict.new(), fn(acc, g) {
      dict.insert(acc, g.name, g.ty)
    })
  let by_global =
    list.fold(m.imports, by_global, fn(acc, imp) {
      case imp {
        ir.ImportGlobal(_, name, ty, _) -> dict.insert(acc, name, ty)
        _ -> acc
      }
    })
  list.fold(m.exports, dict.new(), fn(acc, e) {
    case e {
      ir.ExportFn(export_name, fn_name) ->
        case dict.get(by_fn, fn_name) {
          Ok(results) -> dict.insert(acc, export_name, results)
          Error(_) -> acc
        }
      ir.ExportGlobal(export_name, global_name) ->
        case dict.get(by_global, global_name) {
          Ok(ty) -> dict.insert(acc, export_name, [ty])
          Error(_) -> acc
        }
      ir.ExportTable(..) | ir.ExportMemory(..) | ir.ExportTag(..) -> acc
    }
  })
}

/// True iff `module` CALLS an imported function (contains a `CallImport`) — mirrors the oracle's
/// gate for weaving the function-import dispatch vector into `instantiate/1`.
fn module_calls_import(module: ir.Module) -> Bool {
  list.any(module.functions, fn(f) { expr_calls_import(f.body) })
}

/// True iff `expr` (recursively) contains a `CallImport` — mirrors `driver.gleam`'s private helper.
fn expr_calls_import(expr: ir.Expr) -> Bool {
  case expr {
    ir.CallImport(..) -> True
    ir.Let(_, rhs, body) -> expr_calls_import(rhs) || expr_calls_import(body)
    ir.If(_, _, t, e) -> expr_calls_import(t) || expr_calls_import(e)
    ir.Switch(_, _, arms, default) ->
      list.any(arms, fn(a) {
        let ir.SwitchArm(_, b) = a
        expr_calls_import(b)
      })
      || expr_calls_import(default)
    ir.Block(_, _, body) -> expr_calls_import(body)
    ir.Loop(_, _, _, body) -> expr_calls_import(body)
    ir.Charge(_, body) -> expr_calls_import(body)
    _ -> False
  }
}

/// True iff EVERY function import resolves to a REAL provider (`spectest` or a registered instance)
/// — mirrors the oracle so an under-provided host capability (e.g. `hostimport`'s `env.forbidden`)
/// is rejected fail-closed IDENTICALLY in the linked path.
fn func_imports_all_provided(
  module: ir.Module,
  providers: List(link.Provider),
) -> Bool {
  list.all(module.imports, fn(imp) {
    case imp {
      ir.ImportFn(capability, _name, _ty) ->
        capability == "spectest" || is_registered(capability, providers)
      _ -> True
    }
  })
}

/// True iff some `Registered` provider carries the link-name `capability`.
fn is_registered(capability: String, providers: List(link.Provider)) -> Bool {
  list.any(providers, fn(p) {
    let link.Registered(link_name, _exports) = p
    link_name == capability
  })
}

// ───────────────────────── the binding matrix (8) ─────────────────────────

/// The 8-way L1 posture matrix: `{Safe, Unsafe} × {Cell, Threaded} × {Paged, Atomics}` — tier-N
/// (`nif`) is excluded (O8: a NIF cannot be merged). The four Safe points come through the shipped
/// `combos.binding_for`; the four Unsafe points overlay `profiles.unsafe()` with the bounded Safe
/// cap and the same `compose`/`validate_binding` surface (never re-spelling a `rt_mem_*` atom).
fn link_bindings() -> List(#(String, Binding)) {
  [
    #("safe·cell·paged", combos.binding_for(combos.cell_paged)),
    #("safe·threaded·paged", combos.binding_for(combos.threaded_paged)),
    #("safe·cell·atomics", combos.binding_for(combos.cell_atomics)),
    #("safe·threaded·atomics", combos.binding_for(combos.threaded_atomics)),
    #("unsafe·cell·paged", unsafe_binding(Cell, Paged, TablePaged)),
    #("unsafe·threaded·paged", unsafe_binding(Threaded, Paged, TablePaged)),
    #("unsafe·cell·atomics", unsafe_binding(Cell, Atomics, TableAtomics)),
    #(
      "unsafe·threaded·atomics",
      unsafe_binding(Threaded, Atomics, TableAtomics),
    ),
  ]
}

/// Compose a coherent Unsafe `Binding` over the three tier axes with the bounded Safe cap (so an
/// atomics point links, P6). Panics via `let assert` only for a policy-incoherent composition — the
/// matrix never lists one, so it documents the G6 invariant.
fn unsafe_binding(
  strategy: instance.StateStrategy,
  mem: instance.MemTier,
  table: instance.TableTier,
) -> Binding {
  let capped = Binding(..profiles.unsafe(), safe_max_pages: combos.cap_pages)
  let composed = profiles.compose(capped, strategy, mem, table)
  let assert Ok(b) = profiles.validate_binding(composed)
  b
}

/// The two Unsafe tier-P bindings (Cell + Threaded) the reference/SIMD/EH extended corpus is driven
/// under — both calling conventions over pure-BEAM paged memory, avoiding the atomics reservation
/// edge on the larger-memory programs (`mem64`/`multimem`/`simdmem`). Unsafe (`MeterOff`) is used so
/// the oracle is SPEC-CORRECT over the whole extended set: under Safe (`MeterFuel`) the large-memory
/// `mem64` grows past its default fuel budget and traps `fuel_exhausted` (a fuel-budget property of
/// the Safe posture, identical in linked AND oracle — so the merge is still correct — but not a
/// `.expected` value). The Safe/metered posture is fully covered on the tier-sensitive CORE corpus
/// (headline, 8-way) and on the metering fun-capture regression; the extended corpus's job here is
/// the reference/SIMD/EH merge surface, which is posture-independent.
fn extended_bindings() -> List(#(String, Binding)) {
  [
    #("unsafe·cell·paged", unsafe_binding(Cell, Paged, TablePaged)),
    #("unsafe·threaded·paged", unsafe_binding(Threaded, Paged, TablePaged)),
  ]
}

// ───────────────────────── the corpus ─────────────────────────

/// The tier-sensitive value corpus (numerics, memory, table, globals, instantiation traps) — the
/// programs `combos` proves tier/strategy-safe; driven under the FULL 8-way matrix.
fn core_corpus() -> List(String) {
  combos.corpus_programs
}

/// The reference / SIMD / bulk / EH `.expected`-bearing programs — driven under the two Safe tier-P
/// bindings. These carry the R4 fun-capture surface (`simddot` → `rt_simd`'s remote captures) and
/// the `rt_exn` closure (`eh*`), so their linked ≡ oracle identity IS the R4/R5 regression at scale.
fn extended_corpus() -> List(String) {
  [
    "reftab", "simddot", "simdmem", "simdxform", "bulkmem", "mem64", "multimem",
    "ehthrow", "ehcatch", "ehcatchall", "ehnested", "ehrethrow",
  ]
}

/// The differential failures for ONE program under ONE binding: the oracle's spec-correctness
/// violations, the linked module's spec-correctness violations, AND the cross-path identity
/// violations (linked `Outcome`-list must equal the oracle's, bit-pattern + trap). Empty ⇒ the
/// linked artifact is spec-correct AND a byte-behaviour-identical packaging of the oracle (O5).
fn program_failures(binding: Binding, name: String) -> List(String) {
  let #(o_outs, o_fails) = combos.evaluate(driver.pipeline_with(binding), name)
  let #(l_outs, l_fails) = combos.evaluate(linked_driver(binding), name)
  list.flatten([
    o_fails,
    l_fails,
    combos.identity_across(name, [#("oracle", o_outs), #("linked", l_outs)]),
  ])
}

// ════════════════════ L1 — in-process linked ≡ non-linked differential ════════════════════

/// **L1 headline (O5; acceptance *Result-identical* / *Conformance neutral*).** Over the
/// tier-sensitive core corpus × the FULL 8-way `{Safe,Unsafe} × {Cell,Threaded} × {Paged,Atomics}`
/// matrix, every linked artifact returns bit-pattern-identical, trap-identical `Outcome`s to the
/// non-linked in-process oracle AND is spec-correct against `.expected`. A single merge bug (a
/// dropped def, a mis-mangled call, a stripped `instantiate` root) changes an `Outcome` and turns
/// this red on the exact program+binding. This is the phase's headline correctness bar.
pub fn l1_linked_equals_nonlinked_full_matrix_test() {
  let failures =
    list.flat_map(link_bindings(), fn(lb) {
      let #(_label, binding) = lb
      list.flat_map(core_corpus(), fn(name) { program_failures(binding, name) })
    })
  assert failures == []
}

/// **L1 extended corpus (R4/R5 regression at scale).** The reference / SIMD / bulk / EH corpus ×
/// `{Safe cell·paged, Safe threaded·paged}`: linked ≡ oracle over programs whose closure reaches the
/// fun-capture-bearing `rt_simd` (R4) and the `rt_exn` exception runtime — if the linker missed a
/// capture as a reachability root/rewrite target the merged module would `undef`, caught here.
pub fn l1_extended_corpus_linked_equals_nonlinked_test() {
  let failures =
    list.flat_map(extended_bindings(), fn(lb) {
      let #(_label, binding) = lb
      list.flat_map(extended_corpus(), fn(name) {
        program_failures(binding, name)
      })
    })
  assert failures == []
}

/// **R4 regression (fun-captures are first-class).** `simddot`'s closure reaches
/// `twocore@runtime@rt_simd` whose dispatch CAPTURES `fun twocore@runtime@rt_num:*` values, and a
/// Safe (metered) numeric build's closure captures `fun gleam@dynamic@decode:decode_int/1`. Both
/// linked builds must LOAD and run bit-identically to the oracle — a capture is a reachability EDGE
/// (its target def must survive DCE) AND a rewrite target (→ a self-module funref). Driven as a
/// focused, self-pinpointing pair.
pub fn l1_fun_capture_reachability_test() {
  // simddot under Unsafe (the rt_simd remote-capture surface).
  assert program_failures(profiles.unsafe(), "simddot") == []
  // a Safe (MeterFuel) numeric build — the metering closure captures gleam@dynamic@decode.
  assert program_failures(combos.binding_for(combos.cell_paged), "add") == []
}

/// **R5 regression (intra-module apply links).** Every corpus program that spans several helper
/// functions is merged: a missed self-module mangle of an intra-module literal-`apply` fails
/// `core_lint` at link time, so `link_program` returns `Error` and the differential cannot even
/// build. Asserts `link_program` returns `Ok` for a cross-helper program under all 8 bindings.
pub fn l1_intra_module_apply_links_test() {
  let failures =
    list.flat_map(link_bindings(), fn(lb) {
      let #(label, binding) = lb
      case linked_beam("fib", binding) {
        Ok(_) -> []
        Error(reason) -> [label <> ": fib failed to link: " <> reason]
      }
    })
  assert failures == []
}

/// **R6 regression (`instantiate/N` is a DCE root; the state runtime survives).** `mem` (memory
/// round-trip + OOB traps) and `gvar` (mutable globals) require the seed/state runtime: if
/// `instantiate/N` were not a reachability root the seed + memory/global runtime would be DCE'd and
/// exports would read an unseeded cell → trap/undef. The merged modules must reproduce the oracle's
/// values across all 8 bindings.
pub fn l1_instantiate_root_seeds_state_test() {
  let failures =
    list.flat_map(link_bindings(), fn(lb) {
      let #(_label, binding) = lb
      list.flat_map(["mem", "gvar"], fn(name) {
        program_failures(binding, name)
      })
    })
  assert failures == []
}

/// **L1 import-bearing (honest-scope home, R6/R14).** An authored module importing
/// `spectest.global_i32` (= 666) and reading it from an export. Its merged `instantiate/1` seeds the
/// provided import vector (a reachability root) and the export reads the provided global — proving
/// import-bearing merge-correctness IN-PROCESS (a bare node has no providers, so this is omitted
/// from L2, R14). Driven under Safe (metered) to also exercise the metering closure through the
/// merge.
pub fn l1_import_bearing_instantiate1_merges_test() {
  let m = import_bearing_module("twocore@link@importfix")
  let binding = combos.binding_for(combos.cell_paged)
  let assert Ok(cmod) = pipeline.ir_to_cmod(m, binding)
  let assert Ok(#(mod, beam)) =
    beam_link.link_program(forms_of(cmod), m.name, ambient())
  let assert Ok(_) = build_beam.load_module(mod, "importfix.beam", beam)
  let assert Ok(imports) = link.link_imports(m, [])
  // seed the merged instantiate/1 with the provided import vector, then read the global.
  let assert Ok(_) =
    catch_apply_dyn(mod, atom.create("instantiate"), [to_dynamic(imports)])
  assert catch_apply(mod, atom.create("read_global"), []) == Ok(666)
}

/// An import-bearing `ir.Module`: imports `spectest.global_i32 : i32` (its local name is the
/// positional `g0`) and exports `read_global` returning it — the smallest merged `instantiate/1`
/// fixture (mirrors the `emit_core_e2e` import module).
fn import_bearing_module(name: String) -> ir.Module {
  ir.Module(
    name: name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [ir.ImportGlobal("spectest", "global_i32", ir.TI32, False)],
    functions: [
      ir.Function("read_global", [], [ir.TI32], [], ir.GlobalGet("g0")),
    ],
    exports: [ir.ExportFn("read_global", "read_global")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

// ════════════════════ Determinism (R10) ════════════════════

/// **R10 (determinism / O7).** `link_program` run twice on the same input + fixed module name yields
/// a BYTE-IDENTICAL `.beam` (deterministic compile + stripped file/line annotations + sorted merge
/// order). Byte-stability is what makes the linked artifact diffable/cacheable. Checked over a
/// stateful program (its closure spans the memory + numeric + state runtime).
pub fn determinism_link_twice_byte_identical_test() {
  let assert Ok(bytes) = combos.read_wasm("mem")
  let assert Ok(m) = pipeline.source_to_ir(bytes)
  let assert Ok(cmod) = pipeline.ir_to_cmod(m, profiles.unsafe())
  let forms = forms_of(cmod)
  let assert Ok(#(_, beam1)) = beam_link.link_program(forms, m.name, ambient())
  let assert Ok(#(_, beam2)) = beam_link.link_program(forms, m.name, ambient())
  assert beam1 == beam2
}

// ════════════════════ D3a (R9) + exports (R11) — structural over the merged corpus ════════════════════

/// **R9 (D3a positive, over the whole import-free corpus).** For every corpus artifact, the MERGED
/// Core must contain: no `erlang:apply` (data-driven MFA authority), no residual off-closure
/// fun-capture (`fun 'twocore@…'`/`fun 'gleam@…'` — all rewritten to self-module funrefs), and no
/// surviving remote call to any module OFF the OTP-ambient allowlist (every in-closure remote is
/// rewritten to a local apply). This is an INDEPENDENT structural check complementing the linker's
/// built-in fail-closed self-check (whose passing is itself proven by `link_to_core` returning `Ok`
/// over the corpus — the cerl-level "no data-driven apply" the built-in check owns). Passing over a
/// corpus that CONTAINS legitimate first-class `apply Op(Args)` (`call_indirect`, EH) is the proof
/// of no false-positive: those render as `apply …`, never `call 'MOD':`, so they are not flagged.
pub fn d3a_structural_over_merged_corpus_test() {
  let corpus = list.append(core_corpus(), extended_corpus())
  let failures = list.flat_map(corpus, d3a_failures)
  assert failures == []
}

/// The D3a structural failures for `name`'s merged Core (empty ⇒ clean). Programs that do not
/// compile/merge under Unsafe (the import-bearing `hostimport`, whose funcidx is out of range with
/// imports absent) are skipped — they never reach a bare node (R14). A merge that fails the linker's
/// OWN fail-closed D3a check surfaces as an `Error` from `link_to_core` and is reported.
fn d3a_failures(name: String) -> List(String) {
  let assert Ok(bytes) = combos.read_wasm(name)
  let assert Ok(m) = pipeline.source_to_ir(bytes)
  case pipeline.ir_to_cmod(m, profiles.unsafe()) {
    // Import-bearing / out-of-scope programs never compile to a linkable core; skip (not a bare-node
    // artifact). The differential (L1) already proves they REJECT identically.
    Error(_) -> []
    Ok(cmod) ->
      case beam_link.link_to_core(forms_of(cmod), m.name, ambient()) {
        Error(e) -> [
          name <> ": link_to_core failed: " <> describe_link_error(e),
        ]
        Ok(#(_, text)) -> d3a_text_failures(name, text)
      }
  }
}

/// The structural predicate over merged Core TEXT. Sound against false-positives because in Core the
/// three forbidden shapes have UNAMBIGUOUS renderings distinct from legitimate first-class applies:
/// a remote call is `call 'MOD':'FUN'(…)`; `erlang:apply` is `call 'erlang':'apply'(…)`; an external
/// fun-capture is `fun 'MOD':…`; whereas a first-class/`call_indirect` apply is `apply Op(…)` (no
/// `call '`, no `fun '`) and a merged-local funref carries no module atom — none are matched here.
fn d3a_text_failures(name: String, text: String) -> List(String) {
  let off_allowlist =
    remote_call_modules(text)
    |> set.from_list
    |> set.to_list
    |> list.filter(fn(mo) { !link_manifest.is_ambient(mo) })
  list.flatten([
    case off_allowlist {
      [] -> []
      _ -> [name <> ": off-allowlist remotes " <> string.inspect(off_allowlist)]
    },
    fail_if(
      string.contains(text, "call 'erlang':'apply'"),
      name <> ": erlang:apply survived the merge",
    ),
    fail_if(
      string.contains(text, "fun 'twocore@"),
      name <> ": residual off-closure twocore@ fun-capture",
    ),
    fail_if(
      string.contains(text, "fun 'gleam@"),
      name <> ": residual off-closure gleam@ fun-capture",
    ),
  ])
}

/// `[msg]` when `cond`, else `[]` — a one-line conditional failure accumulator.
fn fail_if(cond: Bool, msg: String) -> List(String) {
  case cond {
    True -> [msg]
    False -> []
  }
}

/// Every module named as the target of a remote `call 'MOD':…` in merged Core `text` (with
/// duplicates). Core renders a remote call as `call 'MODULE':'FUN'(…)` with the module quoted and no
/// apostrophe inside a module atom, so splitting on `call '` then on `':` yields the module atom
/// cleanly. Local calls use `apply …` (no `call '`), so only genuine remotes are extracted.
fn remote_call_modules(text: String) -> List(String) {
  case string.split(text, "call '") {
    [_first, ..rest] ->
      list.filter_map(rest, fn(frag) {
        case string.split_once(frag, "':") {
          Ok(#(mo, _)) -> Ok(mo)
          Error(_) -> Error(Nil)
        }
      })
    _ -> []
  }
}

/// **R11 (merged exports are EXACTLY original + `instantiate/N` + `module_info`).** The non-linked
/// generated Core header declares exactly the public exports + `instantiate/N`; the merged module
/// must export that SAME set plus the synthesized `module_info/{0,1}` — no leaked per-module
/// `module_info` of the runtime, no exported runtime helper. Checked over a representative subset
/// (pure, stateful, globals, references).
pub fn merged_exports_exactly_original_plus_instantiate_plus_module_info_test() {
  let failures =
    list.flat_map(["add", "mem", "gvar", "reftab"], export_failures)
  assert failures == []
}

/// The R11 export-set failure for `name` (empty ⇒ exact). Expected = the THIN generated header's
/// exports (public + `instantiate/N`) ∪ `{module_info/0, module_info/1}`; actual = the merged
/// header's exports. Any extra or missing export is reported.
fn export_failures(name: String) -> List(String) {
  let assert Ok(bytes) = combos.read_wasm(name)
  let assert Ok(m) = pipeline.source_to_ir(bytes)
  let assert Ok(cmod) = pipeline.ir_to_cmod(m, profiles.unsafe())
  let core = core_printer.print_module(cmod)
  let assert Ok(#(_, merged)) =
    beam_link.link_to_core(forms_of(cmod), m.name, ambient())
  let expected =
    set.union(
      set.from_list(header_exports(core)),
      set.from_list(["module_info/0", "module_info/1"]),
    )
  let actual = set.from_list(header_exports(merged))
  case actual == expected {
    True -> []
    False -> [
      name
      <> ": exports "
      <> string.inspect(set.to_list(actual))
      <> " want "
      <> string.inspect(set.to_list(expected)),
    ]
  }
}

/// The `name/arity` export tokens declared in a Core module header's `[ … ]` list (quotes and
/// whitespace stripped). The header's bracket list is the export declaration; no nested brackets
/// appear inside it, so the first `[ … ]` is the whole set.
fn header_exports(core: String) -> List(String) {
  case string.split_once(core, "[") {
    Error(_) -> []
    Ok(#(_, after)) ->
      case string.split_once(after, "]") {
        Error(_) -> []
        Ok(#(inside, _)) ->
          string.split(inside, ",")
          |> list.map(fn(tok) { tok |> string.replace("'", "") |> string.trim })
          |> list.filter(fn(t) { t != "" })
      }
  }
}

// ════════════════════ L2 — bare-node differential (measured, not asserted) ════════════════════
//
// Over the IMPORT-FREE subset × state_strategy × {tier-P, tier-O}: link → boot the merged `.beam` on
// a scrubbed isolated `erl` (P11-05) → the child's value/trap must equal the in-process oracle
// (`pipeline.run_source`). A `RESULT:` at exit 0 PROVES isolation held (the in-child gate halts
// before the invoke on any `twocore@`/`gleam@` hit), so the differential is also the isolation proof.

/// One bare-node point: the program, export, args, the binding it is built under, and the label.
type L2Point {
  L2Point(
    program: String,
    export_: String,
    args: List(Int),
    label: String,
    binding: Binding,
  )
}

/// The L2 subset (import-free) × strategy × tier — numeric (`sum_to`), memory round-trip + OOB trap
/// (`mem`), div/overflow traps (`intops`), pure-v128 (`simddot`), references + a null-slot trap
/// (`reftab`). Distributed so the four state×tier corners (cell/threaded × paged/atomics) are each
/// covered on the bare node, plus both a value and a trap point.
fn l2_points() -> List(L2Point) {
  let cp = combos.binding_for(combos.cell_paged)
  let tp = combos.binding_for(combos.threaded_paged)
  let ca = combos.binding_for(combos.cell_atomics)
  let ta = combos.binding_for(combos.threaded_atomics)
  [
    // numeric — threaded·paged (tier-P) + cell·atomics (tier-O).
    L2Point("sum_to", "sum_to", [100], "threaded·paged", tp),
    L2Point("sum_to", "sum_to", [10], "cell·atomics", ca),
    // memory round-trip (value) + OOB (trap), across cell·paged and threaded·atomics.
    L2Point("mem", "roundtrip", [0, 42], "cell·paged", cp),
    L2Point("mem", "load", [65_533], "cell·paged", cp),
    L2Point("mem", "roundtrip", [4, 67_305_985], "threaded·atomics", ta),
    // integer traps — divide-by-zero + signed overflow (value + traps), cell·paged.
    L2Point("intops", "divs", [4_294_967_289, 2], "cell·paged", cp),
    L2Point("intops", "divu", [10, 0], "cell·paged", cp),
    L2Point("intops", "divs", [2_147_483_648, 4_294_967_295], "cell·paged", cp),
    // pure-v128 — cell·paged (tier-P) + threaded·atomics (tier-O).
    L2Point("simddot", "dot8", [10], "cell·paged", cp),
    L2Point("simddot", "dot8", [4], "threaded·atomics", ta),
    // references + table — a value and a null-slot trap, cell·paged.
    L2Point("reftab", "size", [], "cell·paged", cp),
    L2Point("reftab", "callnull", [7], "cell·paged", cp),
  ]
}

/// **L2 headline (acceptance *Single artifact* + *Bare-node proof*).** Each subset point: merge →
/// boot the self-contained `.beam` on a scrubbed isolated `erl` with the closure gate active → the
/// child's value/trap equals the in-process oracle (bit/trap identical), on a node with NO
/// `twocore@`/`gleam@` reachable. Any leak (`LEAK:`), missing module (`NOLOAD:`), or value/trap
/// divergence is reported.
pub fn l2_bare_node_import_free_differential_test() {
  let failures = list.flat_map(l2_points(), l2_point_failures)
  assert failures == []
}

/// The bare-node differential failures for one `L2Point` (empty ⇒ the child matched the in-process
/// oracle bit/trap-identically on an isolated node).
fn l2_point_failures(p: L2Point) -> List(String) {
  let assert Ok(bytes) = combos.read_wasm(p.program)
  let oracle = pipeline.run_source(bytes, p.binding, p.export_, p.args)
  let where = p.program <> "." <> p.export_ <> " [" <> p.label <> "]"
  case linked_beam_pair(p.program, p.binding) {
    Error(reason) -> [where <> ": link failed: " <> reason]
    Ok(#(mod, beam)) -> {
      let #(code, out) =
        boot_invoke(beam, mod, atom.create(p.export_), p.args, [])
      compare_child(where, oracle, code, out)
    }
  }
}

/// Diff the child's `#(exit, stdout)` against the in-process oracle `RunResult`. A non-`RESULT`/
/// non-`TRAP` exit (a leak, a NOLOAD, a timeout, no-erl) is a distinct, named failure so a harness
/// regression is legible. A value point must produce `RESULT:<oracle bits>`; a trap point must
/// produce `TRAP:` carrying the oracle's raw reason (both rendered `~0p` of the same
/// `{wasm_trap,Kind}` term, so the child stdout contains the oracle reason verbatim).
fn compare_child(
  where: String,
  oracle: Result(pipeline.RunResult, pipeline.PipelineError),
  code: Int,
  out: String,
) -> List(String) {
  case code {
    3 -> [where <> ": ISOLATION LEAK on the child path — " <> out]
    4 -> [
      where <> ": merged module not loadable on the child (NOLOAD) — " <> out,
    ]
    124 -> [where <> ": child timed out"]
    127 -> [where <> ": no erl on PATH (cannot run the bare-node proof)"]
    0 ->
      case oracle {
        Ok(Returned([v])) ->
          case parse_result_int(out) {
            Ok(cv) ->
              case cv == v {
                True -> []
                False -> [
                  where
                  <> ": child RESULT "
                  <> int.to_string(cv)
                  <> " != oracle "
                  <> int.to_string(v),
                ]
              }
            Error(_) -> [
              where
              <> ": expected RESULT "
              <> int.to_string(v)
              <> ", child said: "
              <> out,
            ]
          }
        Ok(Trapped(reason)) ->
          case string.contains(out, "TRAP:") && string.contains(out, reason) {
            True -> []
            False -> [
              where <> ": child «" <> out <> "» != oracle trap " <> reason,
            ]
          }
        other -> [
          where <> ": unexpected oracle outcome " <> string.inspect(other),
        ]
      }
    other -> [where <> ": child exit " <> int.to_string(other) <> " — " <> out]
  }
}

/// Parse the integer a child's `RESULT:<int>` line carries (up to the newline). `Error(Nil)` if no
/// `RESULT:` line or it is non-integer (a trap / leak).
fn parse_result_int(out: String) -> Result(Int, Nil) {
  case string.split_once(out, "RESULT:") {
    Error(_) -> Error(Nil)
    Ok(#(_, rest)) -> {
      let line = case string.split_once(rest, "\n") {
        Ok(#(h, _)) -> h
        Error(_) -> rest
      }
      int.parse(string.trim(line))
    }
  }
}

/// **L2 isolation gate fired (acceptance *Single artifact*).** A REAL merged module boots to
/// `RESULT:55` at exit 0 with `extra = []` (only the merged `.beam` on `-pa`). By the harness
/// contract the in-child `code:which` gate HALTS before the invoke on any `twocore@`/`gleam@` hit,
/// so a `RESULT:` at exit 0 PROVES the gate ran and reported clean — nothing else was reachable. The
/// *negative* direction (the gate fires on a leak) is P11-05's proven self-test; this confirms it
/// reports clean for a genuine linked artifact.
pub fn l2_bare_node_isolation_gate_fires_test() {
  let assert Ok(#(mod, beam)) =
    linked_beam_pair("sum_to", combos.binding_for(combos.cell_paged))
  let #(code, out) = boot_invoke(beam, mod, atom.create("sum_to"), [10], [])
  assert code == 0
  assert string.contains(out, "RESULT:55")
  assert !string.contains(out, "LEAK:")
  assert !string.contains(out, "NOLOAD:")
}

/// **Constant space on the bare node (acceptance *Bare-node proof* — "runs 100k iters in constant
/// space").** Two complementary measurements on the SELF-CONTAINED artifact:
///   (a) BARE NODE — `sum_to(100000)` boots on the isolated child and COMPLETES at exit 0 with the
///       oracle's exact (i32-wrapped) value; a per-iteration leak would exhaust the child's bounded
///       default heap and it would not complete (reaped at the timeout) — so completion IS the
///       bare-node constant-space evidence.
///   (b) MEASURED — the merged module's `sum_to` at n=1000 vs n=100000, GC'd via `ffi.gc_and_memory`
///       (the Phase-2/4 constant-space instrument), asserts `mem_big < mem_small * 4`: the linked
///       artifact's own runtime holds the loop in constant space.
pub fn l2_constant_space_sum_to_100000_bare_node_test() {
  let binding = combos.binding_for(combos.cell_paged)
  let assert Ok(bytes) = combos.read_wasm("sum_to")
  let assert Ok(pipeline.Returned([want])) =
    pipeline.run_source(bytes, binding, "sum_to", [100_000])

  // (a) bare node: 100k iterations complete on the isolated child with the exact wrapped value.
  let assert Ok(#(mod, beam)) = linked_beam_pair("sum_to", binding)
  let #(code, out) =
    boot_invoke(beam, mod, atom.create("sum_to"), [100_000], [])
  assert code == 0
  let assert Ok(cv) = parse_result_int(out)
  assert cv == want

  // (b) measured constant space on the merged artifact (its own runtime), in-process.
  let assert Ok(m) = pipeline.source_to_ir(bytes)
  let um = ir.Module(..m, name: m.name <> "_cspace")
  let assert Ok(cmod2) = pipeline.ir_to_cmod(um, binding)
  let assert Ok(#(mod2, beam2)) =
    beam_link.link_program(forms_of(cmod2), um.name, ambient())
  let assert Ok(_) = build_beam.load_module(mod2, "cspace.beam", beam2)

  let assert Ok(small) = ffi.start_instance(mod2)
  let assert Ok(_) = ffi.call_instance(small, atom.create("sum_to"), [1000])
  let mem_small = ffi.gc_and_memory(small)
  let assert Ok(big) = ffi.start_instance(mod2)
  let assert Ok(_) = ffi.call_instance(big, atom.create("sum_to"), [100_000])
  let mem_big = ffi.gc_and_memory(big)
  assert mem_big < mem_small * 4
  ffi.stop_instance(small)
  ffi.stop_instance(big)
}

// ════════════════════ fail-closed confirm (R13/R14) ════════════════════

/// **Fail-closed confirm (R13/R14).** The `--link` pre-link gate refuses tier-N and import-bearing
/// modules with a typed error (P11-04 owns the primary CLI test; this confirms it end-to-end): a
/// tier-N build is `LinkTierNif` (a NIF cannot be merged, under any mode), an import-bearing module
/// is `LinkImportBearing` (a bare node has no providers), and an import-free tier-P module is
/// admitted.
pub fn cli_link_rejects_tier_n_and_import_bearing_test() {
  let nif = profiles.resolve_tiers(Binding(..profiles.unsafe(), mem_tier: Nif))
  assert twocore.link_gate(nif, gate_module([])) == Error(twocore.LinkTierNif)

  let imp =
    gate_module([ir.ImportGlobal("spectest", "global_i32", ir.TI32, False)])
  assert twocore.link_gate(profiles.safe(), imp)
    == Error(twocore.LinkImportBearing(1))

  assert twocore.link_gate(profiles.safe(), gate_module([])) == Ok(Nil)
}

/// A minimal `ir.Module` carrying exactly `imports` — the only field (besides the binding's tier)
/// the `--link` gate reads.
fn gate_module(imports: List(ir.ImportDecl)) -> ir.Module {
  ir.Module(
    name: "twocore@link@gate",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: imports,
    functions: [],
    exports: [],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

// ───────────────────────── link helpers ─────────────────────────

/// Merge corpus `name` under `binding` into a self-contained `.beam`, returning `#(module_atom,
/// beam)`. `Error(reason)` on any compile/merge failure. The generated module name is uniquified so
/// repeated links never collide on a BEAM atom.
fn linked_beam_pair(
  name: String,
  binding: Binding,
) -> Result(#(Atom, BitArray), String) {
  let assert Ok(bytes) = combos.read_wasm(name)
  case pipeline.source_to_ir(bytes) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(m0) -> {
      let m = ir.Module(..m0, name: uniquify(m0.name))
      case pipeline.ir_to_cmod(m, binding) {
        Error(e) -> Error(pipeline.describe(e))
        Ok(cmod) ->
          beam_link.link_program(forms_of(cmod), m.name, ambient())
          |> result.map_error(describe_link_error)
      }
    }
  }
}

/// `Ok(Nil)` iff corpus `name` links under `binding` (the R5 "it merges at all" check), else the
/// failing reason.
fn linked_beam(name: String, binding: Binding) -> Result(Nil, String) {
  linked_beam_pair(name, binding) |> result.map(fn(_) { Nil })
}
