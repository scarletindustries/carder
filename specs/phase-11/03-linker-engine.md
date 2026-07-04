# Phase 11 · P11-03 — The `cerl` linker engine

> **Status:** spec, unclaimed · **Owner:** one agent · **Produces freeze:** `«LINKER-IFACE-FROZEN»` ·
> **Depends on:** `«CLOSURE-FROZEN»` (P11-02). **This is the crux of the phase.**
> Read order: `00-overview.md` → `RECONCILIATION.md` (authoritative) → this doc.

## §1 Goal

Deliver the whole-program **Core Erlang merge + DCE** engine: given the generated module's `.core` text
and the frozen OTP-ambient allowlist, produce a **single self-contained `.beam`** whose only remaining
remote calls are to standard OTP modules — every `twocore@*`/`gleam@*` dependency merged in, dead code
stripped, no ambient authority. It reuses the compiler's own Core machinery via a `cerl` FFI shim, the
same OTP-29-internals trust boundary as `twocore_codegen_ffi.erl` (verified end-to-end during the
critique: real runtime modules merged, compiled via `from_core`, loaded, ran result-identical).

Implements: **R1** (Core acquisition), **R4** (function-value captures are first-class), **R5** (the
three rewrite node-classes + forwarding-wrapper bodies), **R6** (reachability roots), **R9** (built-in
structural, fail-closed D3a self-check), **R10** (deterministic output), **R11** (`module_info`/attribute
handling). Honors the permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8):
**D3a** no ambient authority, **D5/D7** bit-identity, **trap-preservation**.

## §2 Depends on / Produces

- **Consumes** `«CLOSURE-FROZEN»` (P11-02): `link_manifest.ambient_allowlist()` (the DCE stop-set), the
  frozen Core-acquisition rule, and the mangle/mergeability invariants.
- **Produces** `«LINKER-IFACE-FROZEN»`: the public `beam_link` signatures + `LinkError` variants below,
  so P11-04 (CLI) and P11-06 (capstone) build against them in parallel. Plus the in-process smoke
  differential (numerics-only closure) passing.

## §3 What it owns + design

**Files (D1 one-owner):**
- **create** `src/twocore/backend/beam_link.gleam` — the typed Gleam orchestration + public API.
- **create** `src/twocore_linker_ffi.erl` — the `cerl`/`cerl_trees` surgery (trust boundary, its own tests).

**Public API (the frozen interface):**

```gleam
/// Merge the generated module + its transitive twocore/gleam closure into ONE self-contained .beam.
/// `generated_core`  : the emitted .core TEXT (as build_beam.compile_core consumes).
/// `module_name`     : the generated module's atom name (== the .core `module` header == ir.Module.name);
///                     it BOTH locates the generated module and names the merged output. Callers that
///                     load multiple linked modules concurrently pass a uniquified name (R10/capstone).
/// `ambient`         : link_manifest.ambient_allowlist() — modules DCE walks up to but not into.
/// Ok(#(atom, beam)) : `atom` is GUARANTEED to equal the module name declared inside `beam`
///                     (P11-05 resolves the child via code:which(atom) against `<atom>.beam`).
pub fn link_program(
  generated_core: BitArray, module_name: String, ambient: List(String),
) -> Result(#(Atom, BitArray), LinkError)

/// Same merge, returning the merged Core Erlang TEXT *before* compilation — the seam P11-06 uses to
/// independently re-run the structural D3a assertion and to inspect DCE. Single-sourced with
/// link_program (which is `link_to_core` ∘ deterministic-compile).
pub fn link_to_core(
  generated_core: BitArray, module_name: String, ambient: List(String),
) -> Result(#(Atom, String), LinkError)

pub type LinkError {
  OffAllowlistRemote(module: String, fun: String)   // a surviving remote call to a non-ambient, non-closure module
  MissingClosureModule(module: String)              // an in-closure module whose Core could not be found
  AmbientAuthorityFound(detail: String)             // D3a: erlang:apply / data-driven apply / residual off-closure capture
  UnmergeableConstruct(detail: String)              // -on_load / load_nif / named-public ETS / behaviour in a closure module
  MangleCollision(a: String, b: String)             // R12 invariant violated (a module atom contained "__")
  MalformedCore(detail: String)                     // core_scan/core_parse/core_lint rejected input
  CoreAcquisitionFailed(module: String, reason: String)
}
```

**The algorithm** (all AST surgery in `twocore_linker_ffi.erl` over `cerl` records; Gleam side is the
typed wrapper + error mapping):

1. **Acquire the generated module's Core** — `core_scan:string/1` → `core_parse:parse/1` → `#c_module{}`
   (the path already in `twocore_codegen_ffi.erl`). Its declared name must equal `module_name`.
2. **Discover the closure by reachability (R6).** Worklist from the ROOTS — the generated module's
   public exports **+ the synthesized `instantiate/N`** (seeds the per-instance cell; DCE-ing it makes
   exports read an unseeded cell → trap) **+ every fun-capture literal** **+ `module_info`**. For each
   referenced module `M`: if `M ∈ ambient` → leave it a remote call (stop); else `M` is in-closure —
   acquire its Core via `beam_lib:chunks(code:which(M),[debug_info])` → `Backend:debug_info(core_v1,…)`
   → `#c_module{}` (R1; `compile:file(F,[to_core])` fallback), then keep walking its reachable defs.
   `CoreAcquisitionFailed`/`MissingClosureModule` on failure. **Edges followed = remote `#c_call`,
   intra-module `apply`, AND fun-capture literals** (`fun M:F/A` and bare `fun F/A`) — R4: a capture is
   a distinct Core node, and missing it both strips live targets and leaves dangling refs.
3. **Reject unmergeable constructs (R15).** If any closure module carries `-on_load`, a `load_nif`, a
   named/public ETS creation, a `behaviour`, or `persistent_term` → `UnmergeableConstruct` (verified
   absent in tier-P/O today; this keeps it so).
4. **Mangle every DEFINED function** `M:F/A` → local `'M__F'/A` (via `cerl:c_fname`), asserting the R12
   invariant (`M` contains no `__` → `MangleCollision` otherwise). **Rewrite the three node classes
   (R5)** via `cerl_trees:map`: (1) in-closure remote `#c_call` → local `apply` of the mangled name;
   (2) intra-module local `apply` on a literal `fname` → the self-mangled name (**omitting this fails
   `core_lint` with `undefined_function` for every internal helper** — verified); (3) fun-capture
   literals → mangled (`fun 'MergedMod':'M__F'/A` for external, mangled local for bare). **Also rewrite
   the generated module's forwarding-wrapper export bodies** (`apply 'fn_name'/arity(…)`). Ambient
   remote calls are left untouched.
5. **DCE.** Keep only defs transitively reachable from the roots (step 2); everything else is dropped —
   this is the DCE. (`gleam_stdlib`/`gleam@*` are pulled whole then trimmed here.)
6. **Assemble one `#c_module{}` (R11).** Strip `module_info/{0,1}` and per-module `file`/`export_type`/
   `type` attrs from every source module; synthesize exactly one `module_info/{0,1}` for the merged
   atom; export **exactly** the generated module's original public exports **+ `instantiate/N` +
   `module_info`**. Sort defs deterministically (R10).
7. **Structural D3a self-check (R9), fail-closed.** Scan the merged `cerl` and reject
   (`AmbientAuthorityFound`): any `#c_call{module=erlang,name=apply}`, any `apply` whose operator is a
   **data-derived variable**, any residual fun-capture to an off-closure/off-ambient module, any remote
   `#c_call` to a module neither the merged atom nor on `ambient` (→ `OffAllowlistRemote`). It **must
   not** flag legitimate first-class `apply Op(Args)` (`CApplyExpr`, documented D3a-legal in
   `core_erlang.gleam`) nor the now-local mangled funref applies. This is the **same predicate** P11-06
   calls independently over `link_to_core` output.
8. **Deterministic compile (R10).** `core_lint:module/1` (→ `MalformedCore` on failure), then
   `compile:forms(Merged, [from_core, binary, deterministic, return_errors])`, with `file` module attrs
   + per-node file annotations stripped/normalized so the bytes depend only on merge order + mangling +
   DCE. Return `#(atom(module_name), beam)`.

## §4 The work

1. Land the `beam_link.gleam` skeleton (types + `link_program`/`link_to_core` heads returning a
   `todo`-free conservative `Error(MalformedCore("unimplemented"))`) so `«LINKER-IFACE-FROZEN»` publishes
   and P11-04/P11-06 unblock. Announce in `state.md`.
2. `twocore_linker_ffi.erl`: acquisition (steps 1–2) for a **two-module synthetic closure**; get a merge
   compiling+loading+running (proves `beam_lib debug_info core_v1` + `from_core`).
3. Add the full rewrite (step 4, all three classes) + DCE (step 5) + assembly (step 6).
4. **Smoke sub-milestone:** link a **numerics-only** generated module (`memories:[]`, no table/exn — the
   smallest `rt_*` closure) and prove it IN-PROCESS value+trap-identical to the normal pipeline. Iterate
   here (cheap) before P11-06's bare node.
5. Add the structural D3a self-check (step 7) + deterministic compile (step 8) + `file`-attr stripping.
6. Wire `link_program = link_to_core |> compile`; full error mapping; doc comments.

## §5 Tests (spec = Core Erlang semantics + the R-decisions)

- **Trust-boundary shim** (mirrors `build_beam_test`): a synthetic 2–3 module closure merges, compiles,
  loads, returns the correct value; malformed Core → `Error(MalformedCore(_))`, never a crash.
- **R4 fun-capture regression (must-pass):** a closure reaching `fun twocore@runtime@rt_num:f32_add/2`
  (remote) and a bare local `fun F/A` (as in `rt_simd`) — the merged module runs with no `undef`; a
  negative variant asserts a capture-ignoring merge WOULD dangle.
- **R5 intra-module-apply regression:** merging a real runtime module (e.g. `rt_num`) with internal
  helpers compiles (guards the `undefined_function` `core_lint` failure).
- **R6 instantiate-root:** a stateful module's `instantiate/N` + state runtime survive DCE (export reads a
  seeded cell, not a trap).
- **DCE soundness:** an unreachable closure function is ABSENT from `link_to_core` output; a function
  reachable ONLY via a fun-capture is PRESENT (adversarial).
- **R12 mangle:** two closure modules with same-named functions merge cleanly; a synthetic `__`-bearing
  module atom → `MangleCollision`.
- **R9 D3a (structural, must-NOT):** inject a synthetic `erlang:apply`/data-derived apply/off-closure
  capture → `AmbientAuthorityFound`; assert legitimate `apply Op(Args)` (`CApplyExpr`) and mangled-local
  funref applies do NOT trip it.
- **R7 fail-closed:** a closure reaching an off-ambient, non-acquirable module → `OffAllowlistRemote`/
  `MissingClosureModule` at link time (not a runtime `undef`).
- **R10 determinism:** `link_program` twice on the same input + fixed `module_name` → byte-identical
  `BitArray`.
- **R15:** a synthetic closure module carrying `-on_load` → `UnmergeableConstruct`.

## §6 Definition of Done

Spec-cited tests above green (incl. the adversarial must-NOTs); the in-process numerics smoke
differential value+trap-identical to the normal pipeline; `link_program` returns an `Atom` equal to the
merged `.beam`'s declared module name; every public function doc-commented (contract + failure modes);
`gleam format --check` clean; `gleam build` zero warnings; the full existing suite + conformance triple
unchanged (this unit adds a new module, touches no default path). `«LINKER-IFACE-FROZEN»` announced in
`state.md`.

## §7 What it leaves

- **P11-04 (CLI):** calls `beam_link.link_program(generated_core, module_name, ambient_allowlist())`;
  the returned `#(Atom, BitArray)` is written straight to disk / loaded.
- **P11-05 (harness):** relies on the guarantee that the returned `Atom` == the `.beam`'s declared module
  name (it resolves the child via `code:which(Atom)`).
- **P11-06 (capstone):** uses `link_to_core` to independently re-run the structural D3a assertion over
  the merged Core, and relies on `link_program` being **name-parametric** (pass a uniquified
  `module_name` for concurrent loads; assert R10 determinism only on the fixed-name, no-load path).
