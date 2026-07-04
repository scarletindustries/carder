# Phase 11 · P11-04 — CLI `--link` + `build_beam` entry + fail-closed gate

> **Status:** spec, unclaimed · **Owner:** one agent · **Produces freeze:** none ·
> **Depends on:** `«LINKER-IFACE-FROZEN»` (P11-03 signature) + `«CLOSURE-FROZEN»` (P11-02 manifest).
> Read order: `00-overview.md` → `RECONCILIATION.md` (authoritative) → this doc.

## §1 Goal

Wire the whole-program linker into the compiler's user surface: a `--link` flag on the `to-beam-wasm`
verb that, when named, merges the generated module's runtime dependency closure into a single
self-contained `.beam` and writes it; **absent, the output is byte-identical to today** (default off).
Add the composing `build_beam` entry (generated `.core` → `beam_link.link_program` with the ambient
allowlist from the manifest → merged `.beam`), and the **pre-link fail-closed gate** that rejects the
two build shapes a bare-node artifact cannot honor. Decisions implemented:

- **R13** — `--link` is on the `to-beam-wasm` verb **only** (it carries a `Binding`; the `.core`-input
  `to-beam` verb has no binding → deferred). The `--link` tier check lives at the **CLI/linker
  boundary**, NOT `profiles.link/1` (which is runtime instantiation, never on the link path).
- **R14** — an **import-bearing** module is link-time rejected: it compiles to `instantiate/1(Imports)`
  needing providers at instance time, and a bare node has none.
- **O4/O8** — `--link` is tier-restricted (tier **P/O** only); tier-**N** (`nif`) is a link-time
  rejection with a typed error and non-zero exit. Default off ⇒ conformance-neutral, byte-identical.

## §2 Depends on / Produces

- **Consumes `«LINKER-IFACE-FROZEN»` (P11-03)** — `beam_link.link_program/3` + the `LinkError` variants
  (built against the *signature* only; P11-04's own suite does not depend on the linker *body* — §5).
- **Consumes `«CLOSURE-FROZEN»` (P11-02)** — `link_manifest.ambient_allowlist() -> List(String)`, the
  fixed OTP-ambient stop-set the `build_beam` entry hands to `link_program`.
- **Produces no freeze milestone.** It is a leaf wiring unit; nothing downstream depends on a P11-04
  interface except the capstone (P11-06), which drives the `--link` CLI path over the corpus.

## §3 What it owns + design

**Files (D1 one-owner-per-file):**
- **edit** `src/twocore.gleam` — the `--link` flag (scoped to `to-beam-wasm`), the pre-link gate, the
  linked branch of `cmd_to_beam_wasm`.
- **edit** `src/twocore/backend/build_beam.gleam` — the new `link_beam/2` entry (the documented
  cross-file reach from the overview §4 ownership map). Adds imports of `twocore/backend/beam_link`
  (P11-03) and `twocore/backend/link_manifest` (P11-02) — a one-way dependency, no cycle (`beam_link`
  carries its own `twocore_linker_ffi.erl` and never imports `build_beam`).

### 3.1 The `build_beam` linked entry

`build_beam.gleam` today (`build_beam.gleam:69`) exposes `compile_core/1` (Core text → in-VM `.beam`)
for the non-linked path (`pipeline.core_to_beam`, `pipeline.gleam:504`). The linked analog composes the
manifest's ambient set with the linker:

```gleam
/// Merge a generated module's Core Erlang with its whole runtime dependency closure into ONE
/// self-contained `.beam` — the `--link` path (the linked analog of `compile_core/1`).
///
/// - `generated_core`: the emitted `.core` TEXT for the generated module (UTF-8, byte-aligned),
///   exactly as `pipeline.ir_to_core` produced it — its `module` header names the merged module.
/// - `module_name`: the generated module's name (`ir.Module.name`); passed through so the linker can
///   locate the generated module within the acquired closure and name the merged output.
/// - Returns `Ok(#(merged_module_atom, merged_beam))` — one self-contained binary that loads on a
///   bare OTP node — or the linker's typed `LinkError` (off-allowlist remote, unmergeable construct,
///   Core-acquisition failure, …). Fail-closed: never emits a partial/authority-bearing artifact.
pub fn link_beam(
  generated_core: BitArray,
  module_name: String,
) -> Result(#(Atom, BitArray), beam_link.LinkError) {
  beam_link.link_program(
    generated_core,
    module_name,
    link_manifest.ambient_allowlist(),
  )
}
```

This is the single point that binds "which OTP modules stay remote" (the manifest, R7) to a link — the
CLI never re-spells the allowlist.

### 3.2 The pre-link fail-closed gate

A pure predicate over the resolved `Binding` + the source `ir.Module`, testable without a process. It
lives in the CLI (`twocore.gleam`) because the import check needs the `ir.Module` (`ir.gleam:88`,
field `imports: List(ImportDecl)`, `ir.gleam:94`), which the `.core`-text `build_beam` entry does not
see.

```gleam
/// Why the pre-link gate refuses a `--link` build (R13/R14). Each is a fail-closed refusal surfaced
/// as a non-zero-exit CLI error, NEVER a silent downgrade.
pub type LinkGateError {
  /// The linear-memory tier is tier-N (`Nif`): native code cannot be merged into a `.beam` (O4/O8).
  /// DISTINCT from `profiles.SafeForbidsNif` — this fires for tier-N under ANY mode (Unsafe+Nif too).
  LinkTierNif
  /// The module declares ≥1 import → it compiles to `instantiate/1(Imports)`, which needs providers a
  /// bare node lacks (R14). `count` is the number of declared imports (diagnostic).
  LinkImportBearing(count: Int)
}

/// Fail-closed gate run BEFORE a `--link` build (R13/R14). Two checks, in order:
///   1. `Error(LinkTierNif)` iff `binding.mem_tier == Nif` — input-independent; not delegated to
///      `profiles.link/1` (R13), which legitimately ADMITS Unsafe+Nif for the non-linked path.
///   2. `Error(LinkImportBearing(n))` iff `m.imports != []` — any import decl means unmet external
///      providers on a bare node (conservative: also rejects import-but-uncalled, fail-closed).
/// `Ok(Nil)` for a tier-P/O, import-free module. Total; reads only build-time fields.
pub fn link_gate(binding: Binding, m: ir.Module) -> Result(Nil, LinkGateError)

/// Human-readable rendering of a `LinkGateError` for CLI stderr (mirrors `describe_link_error/1`).
fn describe_link_gate_error(e: LinkGateError) -> String
```

**Why the tier check is NOT in `profiles.link/1` (R13).** `profiles.validate_binding`
(`profiles.gleam:529`) rejects only `Safe, Nif` (`SafeForbidsNif`); Unsafe+Nif is a *valid runtime
binding* that `link/1` (`profiles.gleam:566`) returns `Ok` for — it is a legitimate posture for the
in-process / non-linked path. The "no NIF under `--link`" rule is a **packaging** constraint
orthogonal to runtime coherence, so it must be a separate gate that fires only under `--link`; folding
it into `link/1` would wrongly reject Unsafe+Nif for the ordinary build path too.

**Why `imports != []` is the right predicate.** The generated entry is `instantiate/1` exactly when
`emit_core.count_import_slots(module) > 0` (`emit_core.gleam:398`, `:4731`). Rejecting *any* non-empty
`imports` is the fail-closed superset (it also refuses a function import that is never called, whose
arity would in fact stay 0) — deliberately conservative and requiring no reach into `emit_core`'s
private helpers (D1). `on_load`/NIF-load directives that only appear *inside the closure* are NOT the
CLI gate's job — the **linker** discovers them structurally as `UnmergeableConstruct` (R13; handoff §7).

### 3.3 `--link` flag scoping (R13)

`--link` is recognized only on `to-beam-wasm`. Add a `link: Bool` field to the `Axes` record
(`twocore.gleam:156`) and a `["--link", ..rest]` arm to `do_split_axis_flags`
(`twocore.gleam:185`). Scoping is enforced at the two `with_binding` call sites (`twocore.gleam:359`):

- **`to-beam-wasm`** (`twocore.gleam:119`) reads `axes.link` and routes to the linked branch.
- **every other compile verb** (`emit`/`to-core`/`run`) rejects `axes.link == True` fail-closed with a
  typed message ("`--link` is only valid on `to-beam-wasm`"), so the flag cannot silently no-op.
- **`to-beam`/`build`** (`.core` input, `twocore.gleam:115`) reject a `--link` token explicitly
  (R13 deferral — no binding to gate on).

`cmd_to_beam_wasm` (`twocore.gleam:489`) gains the `link` bool. Non-linked branch is **unchanged**
(byte-identical). Linked branch:

```
read_bits(input) → source_to_ir(bytes) = m            (pipeline.gleam:423)
→ link_gate(binding, m)                                 (§3.2, fail-closed)
→ pipeline.ir_to_core(m, binding) = core               (pipeline.gleam:481)
→ build_beam.link_beam(from_string(core), m.name)      (§3.1)
→ simplifile.write_bits(output, merged_beam)           ("wrote <output>")
```

## §4 The work (ordered, buildable)

1. Read `RECONCILIATION.md` R13/R14 + P11-02's `ambient_allowlist/0` and P11-03's `link_program/3` +
   `LinkError` in `state.md` (the freezes you build against).
2. `build_beam.gleam`: add the `beam_link` + `link_manifest` imports and `link_beam/2` (§3.1) with its
   doc comment. `gleam build` — zero warnings.
3. `twocore.gleam`: add `link: Bool` to `Axes` (default `False`); parse `--link` in
   `do_split_axis_flags`; thread it so only `to-beam-wasm` consumes it and the other verbs reject it
   (§3.3).
4. Add `LinkGateError`, `link_gate/2` (pub, for tests), `describe_link_gate_error/1` (§3.2).
5. Extend `cmd_to_beam_wasm` with the `link` bool + the linked branch (§3.3); map a `LinkError` to a
   stderr string via a `describe` helper and `beam_link`'s error text; halt non-zero on any gate/link
   failure (the existing `main`/`run` contract, `twocore.gleam:74`).
6. Update `usage/0` (`twocore.gleam:629`): document `--link` on the `to-beam-wasm` line and that it is
   tier-P/O + import-free only.
7. Write the tests (§5); `gleam format`; `gleam test` green.

## §5 Tests

Spec-cited (R13/R14/O4) + adversarial "must-NOT" fixtures. Construct minimal `ir.Module`s inline (the
`add_module()` shape in `test/twocore/pipeline_opt_test.gleam:33`).

**`test/twocore/link_gate_test.gleam`** (pure — no linker body needed, green independently):
- `gate_rejects_nif_tier_test` — `link_gate(Binding(..unsafe(), mem_tier: Nif, …), import_free)` ==
  `Error(LinkTierNif)`. Assert `profiles.link(binding)` is `Ok` for the SAME Unsafe+Nif binding
  (`profiles.gleam:566`) — proving the tier gate is the CLI/linker-boundary enforcement point, NOT
  `link/1` (R13).
- `gate_rejects_import_bearing_test` — a module with `imports: [ir.ImportFn("env", "log", …)]` and one
  with `imports: [ir.ImportGlobal(…)]` each → `Error(LinkImportBearing(1))` under `safe()`.
- `gate_admits_import_free_tier_po_test` — a pure `add` module under `safe()` (tier-P) and under a
  bounded-cap `ceiling()` (tier-O `Atomics`) → `Ok(Nil)`.

**`test/twocore/cli_link_flag_test.gleam`** (drives `twocore.run/1`, as `cli_test.gleam`):
- `link_flag_rejected_on_non_link_verbs_test` — `run(["emit", "--link", p])`,
  `run(["to-core", "--link", p])`, `run(["run", "--link", p, "f"])` each `Error` (flag not valid there;
  short-circuits before file IO). `run(["to-beam", "--link", "x.core"])` `Error` (R13 deferral).
- `default_off_byte_identical_test` — `run(["to-beam-wasm", add.wasm, out])` (no `--link`) writes a
  `.beam` whose bytes equal the pre-existing `pipeline.core_to_beam` output for the same source+binding
  (the non-linked branch is untouched). Full corpus byte-identity is the capstone's (P11-06).
- `linked_build_smoke_test` — once P11-03's `link_program` is landed:
  `run(["to-beam-wasm", "--link", add.wasm, out])` returns `Ok("wrote …")`, exactly ONE file is
  written, and `exec`/`load` of it returns the same value as the non-linked build. Gated on the linker
  body; the flag/gate tests above are the P11-04-independent green.

Acceptance-table ties: *Default unchanged* → `default_off_byte_identical_test`; *tier-N rejected* (O4)
→ `gate_rejects_nif_tier_test`; *import-bearing rejected* (R14) → `gate_rejects_import_bearing_test`;
*single artifact produced* → `linked_build_smoke_test` (bare-node proof itself is P11-06/P11-05).

## §6 Definition of Done (§9, made concrete)

- Spec-cited tests (R13/R14/O4) green, including the adversarial must-NOT gate fixtures; the
  Unsafe+Nif `link/1`-Ok-but-gate-rejects assertion pins R13.
- Doc comments (contract, not restatement) on `link_beam/2`, `link_gate/2`, `LinkGateError`, the new
  `Axes.link` field, and the `--link` usage line.
- `gleam format --check src test` clean; `gleam build` zero warnings.
- The unit's suite passes; the whole prior suite stays green and **byte-identical** with `--link`
  absent (default off — nothing on the non-linked path changed).

## §7 What it leaves (handoff)

- **→ P11-06 (capstone):** a working `to-beam-wasm --link <in.wasm> <out.beam>` CLI path producing one
  merged `.beam` — the exact command the acceptance table's "single artifact" + bare-node rows drive.
  The gate's tier-P/O + import-free restriction defines the linkable corpus subset P11-06 differentials.
- **→ P11-03 (linker):** the CLI gate handles ONLY tier-N + import-bearing at the boundary; `on_load` /
  NIF-load *inside the closure* is the linker's `UnmergeableConstruct` discovery (R13) — the two guards
  are complementary and both fail-closed.
