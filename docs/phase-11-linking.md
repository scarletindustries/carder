# `--link` — self-contained single-`.beam` output

> Phase 11 reference. `--link` is an optional flag on the **build** verb (`to-beam`/`build`
> in carder, `build` in a frontend such as scribbler) that merges the runtime
> dependency closure into the generated module, producing **one `.beam` that loads and runs on a bare
> Erlang/OTP node** — no `carder` app on the code path. The default (non-`--link`) output is
> unchanged and byte-identical.

## 1. What it is (and is not)

By default (see [`../specs/01-status.md`](../specs/01-status.md) §5) an emitted `.beam` is a **thin
module** of module-qualified calls into a shared runtime — `call 'carder@runtime@rt_num':'i32_add'(…)`
— that must already be resident on the target node. Copy that module to a bare node and its first
runtime call fails `undef`.

`--link` removes that dependency for a single build. It runs the **same** compile pipeline (decode →
validate → lower → `ir_to_core` under the chosen `Binding`), then performs a **whole-program Core Erlang
merge**: the generated module plus its entire transitive `carder@*`/`gleam@*`/FFI closure are merged
into one module, dead code stripped, so the only remaining remote calls are to OTP modules present on
every node. The result is a single self-contained `.beam`.

```
# carder (IR in):
to-beam --link app.ir app.beam
# scribbler (wasm in) — the same flag, passed straight through to carder:
build   --link app.wasm app.beam
# → one app.beam; loads via `erl -pa <dir with only app.beam>` and runs `app:<export>(args)`
#   on a node with NO carder@*/gleam@* beams reachable.
```

It is **not** an escript, an OTP release, or a multi-module bundle. It links **one** generated module +
the runtime, for **one** chosen `(mode × state_strategy × mem_tier)` build. It does not change the
default emission, the IR, the optimizer, or any runtime semantics: `--link` is a pure packaging
transform, and the linked artifact is behaviour-identical (bit pattern + traps) to the in-process path.

## 2. The merge, at a high level

The engine is `beam_link.link_program` (Gleam orchestration) over `carder_linker_ffi.erl` (the `cerl`
surgery, pinned to OTP 29 — the same compiler-internals trust boundary as `carder_codegen_ffi`):

1. **Acquire Core.** The generated module from its `.core` text (`core_scan`/`core_parse`); every
   discovered closure member from its RESIDENT `.beam` via `beam_lib` `debug_info(core_v1)` (no `.erl`
   needed). The enumerated closure + acquisition rule are frozen in `link_manifest.gleam`.
2. **Reachability.** A worklist from the generated module's public exports **+ `instantiate/N`** (a DCE
   root — it seeds per-instance memory/table/global/fuel state; without it the whole seed runtime would
   be stripped and exports would read an unseeded cell), following **three** edge kinds: remote
   `#c_call`s, intra-module `apply` on a literal function name, and **`fun M:F/A` function-value
   captures** (a distinct Core node — both a reachability edge and a rewrite target).
3. **DCE.** Only reached function definitions are assembled; everything else is simply never included —
   that is the dead-code elimination.
4. **Mangle + rewrite.** Every DISCOVERED module's def is renamed to a fresh local `'M__F'/A` (the full
   module atom in the name ⇒ injective; asserted `__`-free at manifest freeze). The generated module is
   the mangle IDENTITY, so its public export names stay callable. Every in-closure remote call, literal
   intra-module apply, and fun-capture is rewritten to the local mangled name (via `cerl_trees:map`).
5. **Hygiene + deterministic compile.** One synthesized `module_info/{0,1}`, all source attrs dropped,
   node annotations stripped, sorted def order → `compile:forms([from_core, binary, deterministic])`.
   Linking the same input twice yields a **byte-identical** `.beam` (R10).

The returned atom is guaranteed to equal the module name declared inside the `.beam`. `link_to_core`
exposes the merged Core TEXT before compilation (the seam the capstone uses for an independent D3a
assertion).

## 3. Scope (tier-P/O) and the three rejections

`--link` is **fail-closed**. It supports **tier-P and tier-O** builds only, and refuses three things:

- **tier-N (`nif`)** — a NIF runs custom native code that cannot be baked into a `.beam`. Rejected at
  the CLI/linker boundary (`carder.link_gate → LinkTierNif`) under **any** mode (Unsafe+`nif` too).
  This is distinct from `profiles.link/1`, which legitimately admits Unsafe+`nif` for the ordinary
  non-linked build.
- **import-bearing modules** — a module with WASM imports compiles to `instantiate/1(Imports)` and needs
  providers at instance time; a bare node has none. Rejected (`LinkImportBearing(n)`, R14).
- **unmergeable constructs in the closure** — an `-on_load` directive or an OTP behaviour (a load-time
  callback / NIF loader). None exist in the tier-P/O closure; the linker discovers any structurally and
  refuses (`UnmergeableConstruct`). A drift test keeps the closure free of them.

Every `LinkError` (`OffAllowlistRemote`, `MissingClosureModule`, `AmbientAuthorityFound`,
`UnmergeableConstruct`, `MangleCollision`, `MalformedCore`, `CoreAcquisitionFailed`) surfaces at **link
time** — a missing dependency is never a runtime `undef` on the target node.

## 4. The D3a guarantee — no ambient authority survives the merge

The linked artifact preserves the security invariant of the normal path: **no data-driven authority**.
The merge neither introduces nor leaves any `apply(Var, …)` on an attacker-chosen MFA; every in-closure
call becomes a static local call, and the only remote calls remaining target the **fixed OTP-ambient
allowlist** — the 15 ERTS+kernel+stdlib modules (`erlang, lists, maps, binary, math, ets, atomics,
unicode, string, io, io_lib, io_lib_format, base64, rand, uri_string`) present on every OTP install.
`erlang` being on the allowlist does **not** sanction `erlang:apply` — that is rejected structurally.

This is enforced two ways: a **built-in, fail-closed structural check** in the linker (a `cerl` walk
that refuses to emit on `erlang:apply`, a computed-module remote, an off-allowlist remote, or a residual
off-closure fun-capture), **and** an independent structural assertion over the merged Core of the whole
corpus in the capstone. Neither flags a legitimate first-class `apply Op(Args)` (`call_indirect`, EH
handlers) — those are `apply` nodes carrying no module atom, distinct from a `call 'MOD':…` remote.

## 5. Naming — `link` is three-way overloaded (R17)

Three unrelated things in this codebase are called "link". They are distinct:

| Name | Module | What it does |
|---|---|---|
| `profiles.link/1` | `runtime/profiles.gleam` | **Runtime instantiation** — the sole validated `Binding → Instance` seam (fail-closed tier/policy gate). Never on the `--link` path. |
| `link.link_imports` / `link_func_imports` | `runtime/link.gleam` | **Import weaving** — resolves a module's WASM imports against `spectest` + registered providers at instantiate time. |
| `beam_link.link_program` | `backend/beam_link.gleam` | **Whole-program merge** — the `--link` engine described here. |

The new entry is deliberately named `link_program` (not `link`) to avoid confusion with either of the
other two.

## 6. Proof (Phase 11 capstone, P11-06)

`test/carder/backend/linked_selfcontained_test.gleam` proves the acceptance table objectively — every
value is bit-pattern-compared against the WebAssembly spec (`corpus/*.expected`), every trap against its
spec phrase, and the linked output is diffed against the non-linked in-process oracle:

- **L1 — in-process differential.** Over the corpus × `{Safe,Unsafe} × {Cell,Threaded} × {Paged,Atomics}`,
  every linked artifact returns bit-identical, trap-identical results to the non-linked oracle
  (`driver.pipeline_with`). Fun-captures (R4), intra-module apply (R5) and the `instantiate/N` root (R6)
  fall out as organic regressions; an authored import-bearing fixture exercises the merged
  `instantiate/1` in-process.
- **L2 — bare-node differential.** Over the import-free subset × strategy × tier, the P11-05 harness
  boots a scrubbed fresh `erl` with only the merged `.beam` on `-pa`, its `code:which` gate proving no
  `carder@`/`gleam@` reachable, and each value/trap matches the in-process oracle — plus a
  `sum_to(100000)` constant-space proof.
- **Determinism (R10):** `link_program` twice ⇒ byte-identical `.beam`.
- **D3a (R9):** structural assertion over the merged Core of the whole corpus.
- **Exports (R11):** the merged module exports exactly the original exports + `instantiate/N` +
  `module_info`.

## 7. Deferred follow-ups

- `.core`-input `--link` on `to-beam` (no `Binding` present to gate tier-N/imports, R13).
- Import-bearing bare-node linking (needs a provider-baking story, R14).
- tier-N/NIF merge (O8).
- Multi-module link (several generated WASM modules into one artifact).
- The single-`.beam` runtime-**dispatch** binding (B1) — runtime *selection* at instance time, distinct
  from `--link`'s runtime *inclusion*.
