# Phase 11 · P11-01 — Keystone: runtime layer split

> **Status:** unclaimed · **Owner:** — · **Freezes** `«RT-LAYER-FROZEN»`. Goes first and alone (Wave 0);
> lands green with default emission byte-identical. Read order: `00-overview.md` → `RECONCILIATION.md`
> (authoritative) → this doc.

## §1 Goal

Make the runtime a clean layer whose transitive dependency closure reaches **zero** compiler modules, so
`--link` (P11-03) has a well-defined merge closure. This unit implements exactly the two structural
decisions the reconciliation kept, and nothing else:

- **R2 — do NOT split `twocore/ir`.** Verified clean leaf: `src/twocore/ir.gleam:54-55` imports only
  `gleam/list` + `gleam/option` (94 importers; the runtime references its `TrapReason`/`FuncType`/`ValType`
  types by inline term-building, not call edges, and DCE strips the unused machinery). Seam #2 is **frozen
  closed**; no `ir/types` split. This unit only *asserts and locks* that fact — it writes no `ir` code.
- **R3 — relocate `OptLevel` to a new leaf module.** The only real layer inversion is type-only:
  `runtime/instance.gleam:74` and `runtime/profiles.gleam:53` import `twocore/middle/ir_opt` **solely** for
  the `OptLevel` enum (a type reference erased in Core — no call edge, but a source-layer inversion that
  fails the "zero compiler modules" grep). Move `OptLevel { OptNone Baseline Aggressive }` to a
  dependency-free leaf and repoint every reference.

Realizes acceptance-table row **"Clean layering"** (O1). Default (`--link`-off) output stays
**byte-identical** (O8 / permanent invariant "WASM byte-identical by default"): the three constructors
lower to the same unqualified Core atoms regardless of which Gleam module defines them, so no downstream
`.core`/`.beam` byte changes (R3). The `opt_iface_freeze_test` edit is a **deliberate, reviewed change to
the optimizer's public type *location*, not its behavior** (R3) — it re-imports `OptLevel` from its new
home; every assertion it makes is unchanged.

## §2 Depends on / Produces

- **Depends on:** nothing (Wave 0, the keystone).
- **Produces:** `«RT-LAYER-FROZEN»` — the runtime layer boundary (runtime reaches zero compiler modules,
  grep-verified by a committed test) with default output byte-identical. This unblocks **P11-02** (manifest
  enumerates the now-clean closure), **P11-03** (linker), **P11-04** (CLI), **P11-05/06**.

## §3 What it owns + design

**Create — `src/twocore/opt_level.gleam`** (leaf, imports nothing; D1 owner = P11-01):

```gleam
//// The optimizer's public opt-level enum, relocated to a dependency-free leaf so the runtime
//// (`instance`/`profiles`) reaches zero compiler modules (Phase-11 R3 / «RT-LAYER-FROZEN»).
//// Behavior is unchanged from its prior home in `middle/ir_opt`; only the definition's LOCATION
//// moved. Gleam has no constructor re-export, so every reference imports the constructors here.

pub type OptLevel {
  OptNone
  Baseline
  Aggressive
}
```

The `OptNone` spelling (not `None`) is retained deliberately: files that thread the level also import
`gleam/option.None`, and `OptNone`/`Baseline`/`Aggressive` collide with nothing, so they import
**unqualified** with no clash (this is the original rationale documented at `ir_opt.gleam:22-28`).

**Edit — `src/twocore/middle/ir_opt.gleam`** (owner = middle-end; deliberate keystone reach, recorded in
`state.md`): delete the `pub type OptLevel {…}` block at **lines 35-39** and add
`import twocore/opt_level.{type OptLevel, Aggressive, Baseline, OptNone}`. `ir_opt` keeps `optimize/2`
(`:59`) and `pipeline/1` (`:82`, which pattern-matches `OptNone`/`Baseline`/`Aggressive` at `:84-86`)
verbatim — they now reference the imported type/constructors. Its `import gleam/list` (`:12`) means no
`None` collision. `ir_opt` does **not** re-export `OptLevel` (Gleam can't), so downstream imports from
`opt_level` directly.

**Edit — `src/twocore/runtime/instance.gleam:74`**: replace
`import twocore/middle/ir_opt.{type OptLevel, Baseline}` with
`import twocore/opt_level.{type OptLevel, Baseline}`. The `Binding.opt_level: OptLevel` field (`:266`) and
`safe_default`'s `opt_level: Baseline` (`:313`) are otherwise untouched. This edit is what removes the
runtime's last compiler-module import.

**Edit — `src/twocore/runtime/profiles.gleam:53`**: replace `import twocore/middle/ir_opt.{Aggressive}`
with `import twocore/opt_level.{Aggressive}` (used at the unsafe/ceiling constructors, e.g. `:287`).

**No change** (R3, verified): `pipeline.gleam` (only calls `ir_opt.optimize(m, binding.opt_level)` at
`:470` — passes the level through, never names a constructor in code), `twocore.gleam` (names "Baseline"/
"Aggressive" only in a help string at `:637`), `middle/ir_opt/aggressive.gleam` (constructors appear only
in doc comments; it imports `pass` only). After these edits, `grep -rn "import twocore/(frontend|middle|
backend)" src/twocore/runtime/` returns **empty** (currently it returns exactly `instance.gleam:74` +
`profiles.gleam:53`).

**Create — `test/twocore/middle/link_layer_freeze_test.gleam`** (owner = P11-01): the grep-freeze. Uses
`simplifile.read` (already a dep; used in `cli_test.gleam`) to read each `src/twocore/runtime/*.gleam` and
assert none contains an `import twocore/frontend` / `import twocore/middle` / `import twocore/backend`
line; and, because `ir` is the only non-runtime `twocore` module a runtime module may reach, assert
`src/twocore/ir.gleam`'s import block is exactly `gleam/list` + `gleam/option` (anchoring R2 — this makes
the direct scan transitively sufficient).

## §4 The work

1. Create `src/twocore/opt_level.gleam` with the type above + module/type doc comments; it imports nothing.
2. Edit `ir_opt.gleam`: delete the type block (`:35-39`), add the `opt_level` import; `gleam build`.
3. Edit `instance.gleam:74` and `profiles.gleam:53` to import from `opt_level`; `gleam build`.
4. Repoint the **seven** test files (Gleam has no constructor re-export). Constructors collide with nothing,
   so unqualified imports are safe. Per-file:

   | Test file | Current | Action |
   |---|---|---|
   | `test/twocore/middle/opt_iface_freeze_test.gleam:23` | `import …/ir_opt.{Aggressive, Baseline, OptNone}` | change to bare `import twocore/middle/ir_opt` (still uses `ir_opt.optimize` at `:105-109`) **+** add `import twocore/opt_level.{Aggressive, Baseline, OptNone}` |
   | `test/twocore/runtime/profiles_test.gleam:6` | `import …/ir_opt.{Aggressive, Baseline}` | repoint entirely → `import twocore/opt_level.{Aggressive, Baseline}` (no `ir_opt.` calls remain) |
   | `test/twocore/optimize/differential_test.gleam:38` | `import …/ir_opt` (uses `ir_opt.OptNone/Baseline/Aggressive` at `:86-88` only) | repoint entirely → `import twocore/opt_level.{Aggressive, Baseline, OptNone}`; rewrite `ir_opt.X`→`X` |
   | `test/twocore/optimize/phase10_capstone_test.gleam:13` | `import …/ir_opt` | keep (uses `ir_opt.optimize`) **+** add `import twocore/opt_level.{Baseline, OptNone}`; rewrite `ir_opt.OptNone/Baseline`→bare |
   | `test/twocore/optimize/baseline_test.gleam:16` | `import …/ir_opt` | keep (uses `ir_opt.optimize`) **+** add `import twocore/opt_level.{Baseline, OptNone}`; rewrite constructor refs |
   | `test/twocore/optimize/memory_differential_test.gleam:14` | `import …/ir_opt` | keep (uses `ir_opt.optimize`) **+** add `import twocore/opt_level.{Aggressive, Baseline, OptNone}`; rewrite constructor refs |
   | `test/twocore/optimize/aggressive_test.gleam:20` | `import …/ir_opt` | keep (uses `ir_opt.optimize`) **+** add `import twocore/opt_level.{Aggressive, Baseline, OptNone}`; rewrite constructor refs |

   (The distinction: a file that still calls `ir_opt.optimize`/`ir_opt.pipeline` keeps its `ir_opt` import
   and *adds* an `opt_level` import; a file that referenced `ir_opt` only for constructors repoints wholly.)
5. Create `test/twocore/middle/link_layer_freeze_test.gleam` (§3).
6. `gleam format` → `gleam test` (full suite) → `gleam build` (zero warnings).
7. Record the deliberate cross-file reaches (`ir_opt`/`instance`/`profiles` + the 7 tests) in `state.md` and
   mark `«RT-LAYER-FROZEN» FROZEN ✓`.

## §5 Tests

- **`link_layer_freeze_test` — `runtime_reaches_zero_compiler_modules_test`** (the freeze; O1 "Clean
  layering"): asserts no `src/twocore/runtime/*.gleam` imports `twocore/frontend|middle|backend`. This is
  the grep the acceptance table names; it must *fail* on today's tree (before the edits) and pass after —
  encode it against the invariant, not the current output.
- **`link_layer_freeze_test` — `ir_is_a_clean_leaf_test`** (R2): asserts `ir.gleam`'s imports are exactly
  `gleam/list` + `gleam/option` — locks seam #2 closed so a future `ir` edit that reaches a compiler module
  breaks *this* test, not P11-03.
- **`opt_iface_freeze_test`** (amended, R3): unchanged assertions — `optimize(m, OptNone) == m` (`:105`),
  Baseline/Aggressive idempotence (`:106-109`), the `Aggressive ⟹ MeterOff` coupling (`:196-210`) — now
  proving the type resolves from its new home. This is the reviewed location-not-behavior change.
- **`differential_test` / `baseline_test` / `memory_differential_test` / `aggressive_test`** stay green:
  they exercise `OptNone ≡ Baseline ≡ Aggressive` value/trap identity through the repointed constructors,
  which is the operational proof that relocation changed no behavior.
- **`profiles_test`** stays green: `safe*` ⇒ `Baseline`, `unsafe()`/`ceiling()` ⇒ `Aggressive` — proves the
  constructors still carry the same profile meaning from the new module.
- **Byte-identity (O8):** the full suite (`gleam test`, all `*_test`) staying green + the conformance triple
  unchanged is the standing evidence; structurally, no-arg constructors lower to module-independent atoms so
  emitted `.core`/`.beam` are unchanged. **No adversarial "must-NOT" fixture is owed** — this unit adds no
  new runtime behavior; its only sharp edge (a residual runtime→compiler import) is exactly what the freeze
  test forbids.

## §6 Definition of Done (§9, concrete)

1. `src/twocore/opt_level.gleam` exists as a dependency-free leaf exporting
   `pub type OptLevel { OptNone Baseline Aggressive }`; `ir_opt`/`instance`/`profiles` + all seven test
   files import from it; `grep -rn "import twocore/(frontend|middle|backend)" src/twocore/runtime/` is empty.
2. Doc comments (`////` module, `///` type) on `opt_level.gleam` stating it is a relocation (location, not
   behavior) and why `OptNone` avoids the `gleam/option.None` clash.
3. `gleam format --check src test` clean.
4. `gleam build` zero warnings.
5. `gleam test` fully green (baseline 1827 tests, +2 from `link_layer_freeze_test`); conformance triple
   unchanged (46,529 / 1,768 / 0); default emission byte-identical.
6. `«RT-LAYER-FROZEN»` announced in `state.md` with the recorded cross-file reaches.

## §7 What it leaves

- **To P11-02 (`«CLOSURE-FROZEN»`):** a runtime layer whose transitive closure is compiler-module-free, so
  `link_manifest.gleam` can enumerate the merge closure (`runtime/rt_*` + `instance`/`profiles`/`link`/
  `porffor_abi` + reachable `gleam@*` + FFI `.erl`) without pulling any `frontend|middle|backend` module,
  and the leaf `opt_level` (a type erased in Core) needs no manifest entry.
- **To P11-03 (`«LINKER-IFACE-FROZEN»`):** the "zero compiler modules" invariant the linker's reachability
  DCE relies on — the closure it walks contains no compiler code to accidentally drag in or mangle.
- **To P11-06 (capstone):** `link_layer_freeze_test` is the durable guard the capstone's acceptance table
  cites for "Clean layering"; the capstone confirms it green, it does not re-derive it.
