//// Tests for the whole-program Core-Erlang linker (Phase 11 · P11-03).
////
//// These assert against the DEFINED behavior of the Core Erlang merge (the
//// R-decisions in `specs/phase-11/RECONCILIATION.md`) and against ordinary
//// integer/WASM arithmetic — NOT against whatever bytes the compiler happens to
//// emit. The headline is an in-process DIFFERENTIAL (O5): a linked, self-
//// contained module must return bit-identical, trap-identical results to the
//// normal in-process path. The merge is EXECUTED for real here (built, loaded,
//// called), so the differential is proof, not assertion.
////
//// Canonical references: the Core Erlang language spec + the WebAssembly spec
//// (i32.clz counts leading zero bits; i32.add is modulo 2^32).

import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import gleam/string
import twocore/backend/beam_link.{
  AmbientAuthorityFound, MalformedCore, MangleCollision, MissingClosureModule,
  UnmergeableConstruct,
}
import twocore/backend/build_beam
import twocore/backend/core_erlang.{
  CApplyExpr, CAtom, CCall, CFun, CModule, CVar, FName, FunDef,
}
import twocore/backend/eaf
import twocore/backend/emit_core
import twocore/backend/link_manifest
import twocore/ir
import twocore/pipeline
import twocore/runtime/instance

// ───────────────────────── test-only externals ─────────────────────────

/// Apply `M:F(Args)` capturing a trap/denial as `Error(text)` (see
/// `test/twocore_emit_test_ffi.erl`) — the same harness the emit e2e tests use.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

/// Install a synthetic discovered closure module on disk so the linker's real
/// acquisition path can reach it (returns the `ok` atom, discarded).
@external(erlang, "twocore_linker_test_ffi", "install_synth")
fn install_synth(name: String, src: String) -> Atom

// ───────────────────────────── plumbing ─────────────────────────────

/// Emit `module` to the backend `CModule` (as `build_beam`/the linker consume
/// it). `let assert` here is the test's success contract — a failure to emit is
/// a genuine test failure.
fn gen_cmod(module: ir.Module) -> core_erlang.CModule {
  let assert Ok(cm) = emit_core.emit_module(module, instance.safe_default())
  cm
}

/// Lower a backend `CModule` to the abstract FORMS the linker consumes.
fn forms_of(cm: core_erlang.CModule) -> List(eaf.Form) {
  let assert Ok(forms) = eaf.module_forms(cm)
  forms
}

/// A tiny synthetic generated module: one exported function `fname/arity`
/// whose body is `body` over params `params` — the forms-level replacement for
/// the hand-written `.core` text fixtures the pre-EAF linker consumed.
fn synth_forms(
  name: String,
  fname: String,
  params: List(String),
  body: core_erlang.CExpr,
) -> List(eaf.Form) {
  let arity = list.length(params)
  forms_of(
    CModule(name: name, exports: [FName(fname, arity)], attributes: [], defs: [
      FunDef(FName(fname, arity), CFun(params, body)),
    ]),
  )
}

/// The frozen OTP-ambient allowlist (the DCE stop-set) the linker consumes.
fn ambient() -> List(String) {
  link_manifest.ambient_allowlist()
}

/// A numerics-only IR module (memories/globals/tables empty) exporting each
/// function by its own name — the smallest `rt_*` closure.
fn num_module(name: String, functions: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: functions,
    exports: list.map(functions, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// `clz(x) = i32.clz(x)` — a unary numeric op routing to `rt_num:i32_clz`.
fn clz_fn() -> ir.Function {
  ir.Function(
    name: "clz",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.Num(ir.IClz(ir.W32), [ir.Var("p0")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// `add(a, b) = i32.add(a, b)` — a binary numeric op. `i32.add` is INLINED as a BEAM guard
/// BIF (`band('+'(a, b), 2^32−1)`), so it leaves NO `rt_num:i32_add` seam in the merge.
fn add_fn() -> ir.Function {
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
  )
}

/// `rotl(a, b) = i32.rotl(a, b)` — a binary numeric op that STAYS on the `rt_num` seam
/// (rotate is not inlined), so it emits a `call 'twocore@runtime@rt_num':'i32_rotl'(a, b)` and
/// therefore appears in the merge as the mangled def `rt_num__i32_rotl/2`. Used as a genuinely
/// seam-reaching function for the DCE / mangling assertions now that `i32.add` is inlined away.
fn rotl_fn() -> ir.Function {
  ir.Function(
    name: "rotl",
    params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.Num(ir.IRotl(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

// ════════════════════ 1. In-process smoke DIFFERENTIAL (O5, the headline) ════════════════════

/// THE proof: a linked, self-contained numerics module returns BIT-IDENTICAL,
/// TRAP-IDENTICAL results to the normal in-process path (O5). Executed for real
/// — the merge is built, loaded, and called. `i32.clz(1) == 31` (31 leading zero
/// bits, the critique's exact value), `i32.clz(0) == 32`, and `i32.add` wraps
/// modulo 2^32 (`0x7FFFFFFF + 1 == 0x80000000`). The in-process result (thin
/// module over the resident runtime) is captured FIRST, then the merged module
/// hot-replaces it and is called — the two must agree.
pub fn smoke_differential_numerics_test() {
  let name = "twocore@link@smoke_num"
  let cmod = gen_cmod(num_module(name, [clz_fn(), add_fn()]))
  let core = forms_of(cmod)
  let clz = atom.create("clz")
  let add = atom.create("add")

  // in-process path (the oracle): thin module calling the resident rt_num.
  let assert Ok(inproc) = build_beam.compile_and_load(cmod)
  let r_clz1 = catch_apply(inproc, clz, [1])
  let r_clz0 = catch_apply(inproc, clz, [0])
  let r_add = catch_apply(inproc, add, [2_147_483_647, 1])

  // spec sanity on the oracle itself (grounds the differential in WASM semantics).
  assert r_clz1 == Ok(31)
  assert r_clz0 == Ok(32)
  assert r_add == Ok(2_147_483_648)

  // linked path: self-contained merged module, hot-replacing the same name.
  let assert Ok(#(mod, beam)) = beam_link.link_program(core, name, ambient())
  assert atom.to_string(mod) == name
  let assert Ok(loaded) = build_beam.load_module(mod, "linked.beam", beam)
  assert loaded == mod

  // DIFFERENTIAL: linked ≡ in-process, value + trap identical.
  assert catch_apply(mod, clz, [1]) == r_clz1
  assert catch_apply(mod, clz, [0]) == r_clz0
  assert catch_apply(mod, add, [2_147_483_647, 1]) == r_add
}

/// The returned `Atom` equals the module name declared inside the emitted
/// `.beam` (P11-05 relies on this to resolve the child via `code:which`). The
/// merged module is loadable purely by that atom.
pub fn returned_atom_matches_beam_name_test() {
  let name = "twocore@link@atomname"
  let core = forms_of(gen_cmod(num_module(name, [add_fn()])))
  let assert Ok(#(mod, beam)) = beam_link.link_program(core, name, ambient())
  // load under the returned atom; the load succeeds only if the atom matches
  // the name baked into the beam.
  let assert Ok(loaded) = build_beam.load_module(mod, "x.beam", beam)
  assert atom.to_string(loaded) == name
  assert catch_apply(mod, atom.create("add"), [40, 2]) == Ok(42)
}

/// R4 edge-(a) regression (the metering-closure blocker): a Safe-mode
/// (`MeterFuel`) tier-P import-free module lowered through the REAL pipeline
/// (`ir_lower` inserts `charge` metering, so the fuel/metering runtime is
/// reached) whose `rt_meter` closure CAPTURES `fun gleam@dynamic@decode:
/// decode_int/1`. The capture's TARGET def (and everything it transitively
/// reaches, e.g. `gleam@dynamic@decode:run/2`) must survive DCE — a capture is
/// a reachability EDGE, not only a rewrite target (R4 (a)). Before the fix the
/// linked module traps `undef` (`…decode__run/2 → decode__decode_int/1`) on the
/// first `charge`; after, it runs and returns the spec-correct WASM values. This
/// is the case the direct-`emit_core` smoke never exercised (no `ir_lower` ⇒ no
/// metering closure).
pub fn safe_metered_fun_capture_target_survives_dce_test() {
  let name = "twocore@link@metered"
  let assert Ok(cmod) =
    pipeline.ir_to_cmod(
      num_module(name, [clz_fn(), add_fn()]),
      instance.safe_default(),
    )
  let core = forms_of(cmod)
  let assert Ok(#(mod, beam)) = beam_link.link_program(core, name, ambient())
  let assert Ok(_) = build_beam.load_module(mod, "metered.beam", beam)

  // seed the metered instance, then call exports — the fuel-metering closure
  // path (which applies the captured decode_int) must not `undef`.
  let assert Ok(_) = catch_apply(mod, atom.create("instantiate"), [])
  assert catch_apply(mod, atom.create("clz"), [1]) == Ok(31)
  assert catch_apply(mod, atom.create("add"), [2_147_483_647, 1])
    == Ok(2_147_483_648)
}

// ════════════════════ 2. R6 — instantiate is a DCE root; state runtime survives ════════════════════

/// R6: the synthesized `instantiate/0` is a reachability ROOT, so the whole seed
/// + memory/state runtime survives DCE. A merged STATEFUL module (a memory +
/// store/load) instantiates (seeds the per-instance cell) and round-trips a
/// value — proving the state runtime was NOT stripped (an unseeded cell would
/// trap/undef). `instantiate` then invoke run in one process (the pdict cell).
pub fn instantiate_root_state_survives_dce_test() {
  let name = "twocore@link@stateful"
  let store =
    ir.Function(
      "store32",
      [ir.Local("addr", ir.TI32), ir.Local("val", ir.TI32)],
      [],
      [],
      ir.Let(
        [],
        ir.MemStore(0, ir.MemAccess(4, False), ir.Var("addr"), ir.Var("val"), 0),
        ir.Values([]),
      ),
    )
  let load =
    ir.Function(
      "load32",
      [ir.Local("addr", ir.TI32)],
      [ir.TI32],
      [],
      ir.MemLoad(0, ir.MemAccess(4, False), ir.Var("addr"), 0, ir.TI32),
    )
  let module =
    ir.Module(
      name: name,
      uses_numerics: True,
      memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
      globals: [],
      imports: [],
      functions: [store, load],
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
  let core = forms_of(gen_cmod(module))
  let assert Ok(#(mod, beam)) = beam_link.link_program(core, name, ambient())
  let assert Ok(_) = build_beam.load_module(mod, "stateful.beam", beam)

  // seed the cell, then round-trip a full i32 word — the state runtime survived.
  let assert Ok(_) = catch_apply(mod, atom.create("instantiate"), [])
  let assert Ok(_) = catch_apply(mod, atom.create("store32"), [0, 305_419_896])
  assert catch_apply(mod, atom.create("load32"), [0]) == Ok(305_419_896)
}

// ════════════════════ 3. R4 — fun-captures are first-class (reachability + rewrite) ════════════════════

/// R4 (must-pass): a closure reaching `twocore@runtime@rt_simd:f32x4_add/2`,
/// which CAPTURES `fun twocore@runtime@rt_num:f32_add/2` (a distinct Core node —
/// an external `fun` value in a literal). The merged module must (a) LOAD with
/// no `undef` (the capture target survives DCE), (b) keep the capture target as
/// a mangled local DEF, and (c) rewrite the capture to a self-module `make_fun`
/// with NO residual `twocore@runtime@rt_num` remote reference. `rt_num:f32_add`
/// is referenced ONLY via the capture here, so its presence is the adversarial
/// proof that captures are followed for reachability (a capture-ignoring merge
/// WOULD dangle).
pub fn fun_capture_is_first_class_test() {
  let name = "twocore@link@capture"
  // a generated module that reaches the capture-bearing rt_simd function.
  let core =
    synth_forms(
      name,
      "use",
      ["A", "B"],
      CCall(CAtom("twocore@runtime@rt_simd"), CAtom("f32x4_add"), [
        CVar("A"),
        CVar("B"),
      ]),
    )

  // (a) it links + loads (no undef anywhere in the closure).
  let assert Ok(#(mod, beam)) = beam_link.link_program(core, name, ambient())
  let assert Ok(_) = build_beam.load_module(mod, "capture.beam", beam)

  // (b/c) inspect the merged Core: the capture target is a mangled local DEF,
  // the capture is rewritten to a self make_fun, and NO residual rt_num capture.
  let assert Ok(#(_, text)) = beam_link.link_to_core(core, name, ambient())
  assert string.contains(text, "'twocore@runtime@rt_num__f32_add'/2 =")
  // the rewritten capture references the merged module + mangled name.
  assert string.contains(text, "'twocore@runtime@rt_num__f32_add'")
  // no external `fun 'twocore@runtime@rt_num':...` capture literal survives.
  assert !string.contains(text, "fun 'twocore@runtime@rt_num'")
}

// ════════════════════ 4. DCE soundness ════════════════════

/// DCE soundness: a closure function NOT reachable from the roots is ABSENT from
/// the merged output. The numerics module uses only `i32.clz`/`i32.rotl` (both still on the
/// `rt_num` seam — `i32.add` is inlined and would leave no seam to observe), so an unrelated
/// `rt_num` export (e.g. `f64_sqrt`) must NOT appear as a merged def.
pub fn dce_drops_unreachable_test() {
  let name = "twocore@link@dce"
  let core = forms_of(gen_cmod(num_module(name, [clz_fn(), rotl_fn()])))
  let assert Ok(#(_, text)) = beam_link.link_to_core(core, name, ambient())
  // i32_clz + i32_rotl ARE reached (defs present).
  assert string.contains(text, "'twocore@runtime@rt_num__i32_clz'/1 =")
  assert string.contains(text, "'twocore@runtime@rt_num__i32_rotl'/2 =")
  // an unreferenced runtime function is DCE'd out.
  assert !string.contains(text, "'twocore@runtime@rt_num__f64_sqrt'/1 =")
}

/// The DCE stop-set holds: `code`/`net_kernel`/`timer` (frozen `dce_only_remotes`
/// — reachable only via `gleam_erlang_ffi`'s UNUSED helpers) do NOT survive the
/// linker's function-level DCE. The numerics module's `instantiate` pulls
/// `gleam_erlang_ffi` (via `rt_host` → `gleam@erlang@atom:decoder`), so if DCE
/// were module-granular those three remotes would leak — they must not.
pub fn dce_only_remotes_do_not_survive_test() {
  let name = "twocore@link@ambient"
  let core = forms_of(gen_cmod(num_module(name, [clz_fn(), add_fn()])))
  let assert Ok(#(_, text)) = beam_link.link_to_core(core, name, ambient())
  assert !string.contains(text, "call 'code':")
  assert !string.contains(text, "call 'net_kernel':")
  assert !string.contains(text, "call 'timer':")
}

// ════════════════════ 5. R10 — deterministic output ════════════════════

/// R10: linking twice on the same input + fixed `module_name` yields a
/// BYTE-IDENTICAL `.beam` (deterministic compile + stripped file/line
/// annotations + sorted merge order). Byte-stability is what makes the artifact
/// diffable/cacheable.
pub fn deterministic_output_test() {
  let name = "twocore@link@determinism"
  let core = forms_of(gen_cmod(num_module(name, [clz_fn(), add_fn()])))
  let assert Ok(#(_, beam1)) = beam_link.link_program(core, name, ambient())
  let assert Ok(#(_, beam2)) = beam_link.link_program(core, name, ambient())
  assert beam1 == beam2
}

// ════════════════════ 6. R9 — structural D3a self-check (fail-closed refuse-to-emit) ════════════════════

/// R9 (must-NOT): a generated module containing `erlang:apply` (a data-driven
/// MFA apply) is REFUSED — the linker fails closed with `AmbientAuthorityFound`
/// BEFORE emitting a binary, rather than baking ambient authority into the
/// artifact.
pub fn d3a_rejects_erlang_apply_test() {
  let name = "twocore@link@apply"
  let core =
    synth_forms(
      name,
      "f",
      ["M", "A"],
      CCall(CAtom("erlang"), CAtom("apply"), [
        CVar("M"),
        CAtom("g"),
        CVar("A"),
      ]),
    )
  let assert Error(AmbientAuthorityFound(_)) =
    beam_link.link_program(core, name, ambient())
}

/// R9 (must-NOT flag): a legitimate first-class `apply Op(Args)` (`CApplyExpr`,
/// documented D3a-legal) is NOT flagged — it applies a closure value, not an
/// attacker-chosen MFA. The merge succeeds.
pub fn d3a_allows_first_class_apply_test() {
  let name = "twocore@link@firstclass"
  let core = synth_forms(name, "f", ["F"], CApplyExpr(CVar("F"), [CAtom("x")]))
  let assert Ok(_) = beam_link.link_program(core, name, ambient())
}

// ════════════════════ 7. R7 — fail-closed at link time (never a runtime undef) ════════════════════

/// R7 (fail-closed): a closure reaching an off-ambient module whose Core cannot
/// be located surfaces at LINK time as `MissingClosureModule`, never as a
/// runtime `undef` on the bare node.
pub fn fail_closed_missing_module_test() {
  let name = "twocore@link@missing"
  let core =
    synth_forms(
      name,
      "f",
      ["X"],
      CCall(CAtom("twocore@runtime@does_not_exist"), CAtom("g"), [CVar("X")]),
    )
  let assert Error(MissingClosureModule("twocore@runtime@does_not_exist")) =
    beam_link.link_program(core, name, ambient())
}

// ════════════════════ 8. R12 — mangle collision (synthetic __-bearing module) ════════════════════

/// R12: same-named functions across closure modules merge cleanly because the
/// mangle scheme is `'M__F'/A` (full module atom in the name). The numerics
/// smoke already merges `rt_num` + the `gleam@*` closure with no collision; this
/// asserts the merged module actually defines the distinctly-mangled names.
pub fn mangle_disambiguates_same_named_functions_test() {
  let name = "twocore@link@mangle"
  let core = forms_of(gen_cmod(num_module(name, [clz_fn(), rotl_fn()])))
  let assert Ok(#(_, text)) = beam_link.link_to_core(core, name, ambient())
  // the runtime `i32_rotl` (a still-seamed op) is mangled with its full module atom — never
  // bare. (`i32.add` is inlined and leaves no seam to observe here.)
  assert string.contains(text, "'twocore@runtime@rt_num__i32_rotl'/2 =")
}

/// R12 fail-closed: a DISCOVERED closure module whose atom itself contains the
/// `"__"` separator breaks mangle injectivity and is rejected with
/// `MangleCollision`. A synthetic `foo__bar` module is installed and reached.
pub fn mangle_collision_on_separator_bearing_module_test() {
  let _ =
    install_synth(
      "foo__bar",
      "-module(foo__bar).\n-export([g/1]).\ng(X) -> X.\n",
    )
  let name = "twocore@link@collide"
  let core =
    synth_forms(
      name,
      "f",
      ["X"],
      CCall(CAtom("foo__bar"), CAtom("g"), [
        CVar("X"),
      ]),
    )
  let assert Error(MangleCollision(_, _)) =
    beam_link.link_program(core, name, ambient())
}

// ════════════════════ 9. R15 — unmergeable construct (synthetic -on_load) ════════════════════

/// R15: a closure module carrying an `-on_load` directive cannot be merged into
/// a `.beam` (it runs code at load time). A synthetic `on_load` module is
/// installed and reached → `UnmergeableConstruct`. (No shipped tier-P/O module
/// has one; this keeps it so.)
pub fn unmergeable_on_load_module_test() {
  let _ =
    install_synth(
      "twocore_link_onload_synth",
      "-module(twocore_link_onload_synth).\n-on_load(init/0).\n"
        <> "-export([f/0]).\ninit() -> ok.\nf() -> 1.\n",
    )
  let name = "twocore@link@onload"
  let core =
    synth_forms(
      name,
      "f",
      [],
      CCall(CAtom("twocore_link_onload_synth"), CAtom("f"), []),
    )
  let assert Error(UnmergeableConstruct(_)) =
    beam_link.link_program(core, name, ambient())
}

// ════════════════════ 10. Trust boundary — malformed input never crashes ════════════════════

/// Trust boundary (fail-closed, D8): a semantically broken generated module
/// (a body referencing an unbound variable — rejected by `erl_lint` inside the
/// linker's `to_core` acquisition) yields `Error(MalformedCore(_))` — never a
/// panic. Captured normally (no `let assert`) so a crash would fail the test.
pub fn malformed_core_yields_typed_error_test() {
  let core = synth_forms("twocore@link@broken", "f", [], CVar("Unbound"))
  let result = beam_link.link_program(core, "twocore@link@broken", ambient())
  let assert Error(MalformedCore(_)) = result
}

/// Trust boundary: a generated `.core` whose declared module name does NOT match
/// the requested `module_name` is rejected as `MalformedCore` (the returned atom
/// must be trustworthy for P11-05's `code:which`).
pub fn declared_name_mismatch_yields_typed_error_test() {
  let core = forms_of(gen_cmod(num_module("twocore@link@actual", [add_fn()])))
  let assert Error(MalformedCore(_)) =
    beam_link.link_program(core, "twocore@link@requested", ambient())
}
