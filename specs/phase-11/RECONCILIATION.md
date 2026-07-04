# Phase 11 — RECONCILIATION (authoritative)

> Output of the scoping fan-out (3 framings) + adversarial critique (5 lenses) over
> [`00-overview.md`](00-overview.md), reconciled. **This file is AUTHORITATIVE: where it conflicts with
> the overview or a unit doc, this wins.** Implementer read order: `00-overview.md` → this file → unit
> doc. Decisions here are `R1–R17`.
>
> **Verdict: GO — with the changes below.** The single-`.beam` whole-program merge was **executed
> end-to-end on OTP 29.0.2** during the critique: real runtime modules (`rt_num` 184 defs, `rt_mem`,
> `gleam_stdlib`, `gleam@int`) were acquired as Core, mangled, merged, compiled via `from_core`, loaded,
> and returned results **identical** to the in-process runtime (`i32_clz(1)=31`, a cross-module
> `a→b__helper→b__bump→erlang:+` chain = 106). No showstopper to the artifact form. But the overview's
> linker algorithm is **incomplete in ways that would ship a silently-broken linker** — R4–R9 are the
> load-bearing corrections; build them in from the start.

---

## Seams resolved (the three the overview left open)

- **Seam #1 (merge mechanism) → `cerl` FFI. CONFIRMED BY EXECUTION.** See R1. Not a Gleam Core reader.
- **Seam #2 (split `twocore/ir`?) → NO. FROZEN.** See R2. `ir.gleam` imports only `gleam/list` +
  `gleam/option` (a verified clean leaf, 94 importers). Splitting is catastrophic for zero benefit.
- **Seam #3 (OTP-ambient allowlist) → mechanically derived + fail-closed against a fixed OTP set.** See R7.

---

## Reconciled decisions

### Mechanism & layering

**R1 — Merge via a `cerl` FFI shim; acquire Core from the shipped `.beam` first.** `twocore_linker_ffi.erl`
(the same OTP-compiler-internals trust boundary as the existing `twocore_codegen_ffi.erl`, pinned OTP 29).
Per-module Core acquisition, **frozen in the manifest**: (a) **primary** —
`beam_lib:chunks(Beam,[debug_info])` → `Backend:debug_info(core_v1, …)` → `#c_module{}` straight from the
already-resident runtime `.beam` (needs no `.erl` on disk; verified on `rt_num`/`gleam_stdlib`/`gleam@int`/
`twocore_rt_exn_ffi`); (b) **fallback** — `compile:file(F,[to_core])` on the `.erl` source; (c) the
**generated** module — the existing `core_scan`/`core_parse` on its `.core` text. A Gleam Core reader is
rejected: it re-implements the full Core grammar `core_erlang.gleam` deliberately omits (receive, general
binaries, complex guards/map patterns) and still must reach `compile:forms` — more code, no less pin.

**R2 — Do NOT split `twocore/ir`.** Verified: it imports only `gleam/list` + `gleam/option`; it reaches
zero frontend/middle/backend. The runtime depends on it directly (for `TrapReason`/`FuncType`/`ValType`
types, which are inline term-building at the use site, not calls into `twocore@ir`), and function-level
DCE strips the unused IR machinery. A split would ripple across 94 importers to solve a non-problem.

**R3 — The only real inversion is `OptLevel`, and it is type-only.** `runtime/instance.gleam:74` and
`runtime/profiles.gleam:53` import `twocore/middle/ir_opt` **solely** for the `OptLevel` enum — a type
reference erased in Core (no call edge), but a source-layer inversion that fails the "zero compiler
modules" grep. O1 relocates `OptLevel { OptNone Baseline Aggressive }` (a bare 3-arm enum) to a leaf
module. **Full reach set** (Gleam has no constructor re-export, so every reference must repoint):
`middle/ir_opt.gleam`, `runtime/instance.gleam`, `runtime/profiles.gleam`, **plus ~7 test files** that
name the constructors (`differential_test`, `baseline_test`, `memory_differential_test`,
`phase10_capstone_test`, `aggressive_test`, `opt_iface_freeze_test`, `profiles_test`). `pipeline.gleam`,
`twocore.gleam`, `aggressive.gleam` need **no** change (OptLevel appears only in their doc comments).
Default output stays byte-identical (constructors compile to the same unqualified atoms). **The
`opt_iface_freeze_test` edit is a deliberate, reviewed change to the optimizer's public type
*location*, not its behavior** — the overview §0 line "does not touch the optimizer" is refined to
"does not change optimizer *behavior*."

### The linker algorithm (the load-bearing corrections)

**R4 — Function-value captures (`fun M:F/A`) are first-class. [BLOCKER — 4 critics]** The tier-P/O
closure contains **332 module-qualified fun-captures + 43 bare local ones** (`fun
twocore@runtime@rt_num:f32_add/2` in `rt_simd` dispatch; `fun gleam@dynamic@decode:decode_int/1` in
`rt_meter`, which is unconditionally in-closure). Captures are a **distinct Core node kind, not calls**.
The linker MUST treat them as both (a) **reachability roots/edges** — else DCE strips the target and the
capture dangles; and (b) **rewrite targets** — external `fun M:F/A` → `fun 'MergedMod':'M__F'/A`, bare
local `fun F/A` → the mangled local. Missing this is simultaneously a correctness break (`undef` on a
bare node, latent until that op runs) **and** a D3a hole (on a non-bare node a leftover remote capture
resolves to a shadowable module).

**R5 — The rewrite covers THREE node classes (verified by a failed-then-fixed merge).** (1) in-closure
remote `#c_call` → local apply of the mangled name; (2) **intra-module local `apply` on a literal fname
→ the self-module-mangled name** (the first merge failed `core_lint` with `undefined_function` for every
internal helper until this was added); (3) fun-capture literals (R4). **Also** the generated module's
forwarding-wrapper export bodies (`apply 'fn_name'/arity(…)`) must be mangled. Walk uniformly via
`cerl_trees:map`.

**R6 — Reachability roots = public exports + `instantiate/N` + fun-captures + `module_info`.** The
synthesized `instantiate/N` seeds the per-instance cell (`rt_host:seed_policy`, fuel, memory/table
state); if it is not a DCE root, the whole seed + state runtime is stripped and exports read an unseeded
cell → trap/undef. The bare-node acceptance must follow the **seed-then-call** protocol
(`instantiate` then invoke, in one process for the pdict cell).

**R7 — OTP-ambient allowlist: mechanically derived, fail-closed against a fixed OTP set.** Compute
`(surviving remote-call targets after DCE) − (in-closure modules)`; every element must belong to a
**fixed, documented ERTS+kernel+stdlib set** shipped on every OTP install. **Measured floor** (bigger
than the overview's sketch — driven by the merged `gleam_stdlib`): `erlang, lists, maps, binary, math,
ets, atomics, unicode, string, io, io_lib, io_lib_format, base64, rand, uri_string` (some DCE away).
**Fail closed** (typed `LinkError`) on any remote target neither in-closure nor in the fixed set — a
missing-closure surfaces at **link time**, never as a runtime `undef`. `erlang` being allowed does **not**
permit `erlang:apply` (R9). Resolve `gleam_stdlib`'s `dynamic:classify` (confirm DCE-eliminated or map
to its real module). Do **not** widen the allowlist reactively to make a program link — that is itself a
D3a hole.

**R8 — The manifest must include package-level FFI `.erl`, notably `gleam_stdlib.erl`.** It is the
hand-written FFI where `gleam_stdlib:identity` (used ~31× for D5 bit-identity coercions) lives — neither a
`gleam@*` module nor a `twocore_rt_*` shim, so the overview's `.erl` bucket misses it → link fails closed
or the coercion path `undef`s on a bare node. The `.erl` bucket = **any hand-written FFI `.erl` reachable
from the closure, derived from the actual `@external` targets** in reachable Gleam modules (not a
hand-typed list): the 5 `twocore_rt_*_ffi` + `gleam_stdlib.erl` (+ whatever else `@external` resolves to).

**R9 — The D3a check is STRUCTURAL over `cerl`, not a text grep.** Reject `#c_call{module=erlang,
name=apply}` (remote MFA apply), any apply whose operand is a **data-derived variable**, any residual
fun-capture to an off-closure/off-allowlist module, and any remote call off the allowlist. It must **not**
flag legitimate first-class `apply Op(Args)` (`CApplyExpr` — the runtime emits these; `core_erlang.gleam`
documents them D3a-legal) nor the now-local mangled funref applies. A naive `grep apply` false-positives
on the 332+ legitimate captures/applies. Extend the existing `emit_core_security_test` discipline to the
merged artifact. **Built into the linker as a fail-closed refuse-to-emit, AND independently asserted by
the capstone.**

### Correctness hygiene

**R10 — Determinism (O7): `deterministic` flag + strip `file` attrs/annotations + sorted order.**
`compile:forms` is invoked today **without** `deterministic`, and even with it the source path leaks into
the `.beam` via the preserved `file` attribute/annotations. Pass `deterministic`, strip/normalize `file`
module attrs + per-node file annotations, and use a sorted merge/def order. Lock with a
link-twice-byte-identical test.

**R11 — `module_info` + attributes.** Strip `module_info/{0,1}` from every closure module; synthesize
exactly one pair for the merged module atom. Drop per-module `file`/`export_type`/`type` attrs; normalize
a single `compile` attr set. The merged module exports **exactly** the original public exports +
`instantiate/N` + synthesized `module_info`.

**R12 — Mangle injectivity is an asserted invariant.** `'M__F'/A` is injective only because no in-closure
module atom contains `__` (verified: atoms use `@`/single `_`). **Assert `__`-free at manifest freeze;
fail closed** if a future module violates it (or switch to a collision-proof separator/escape).

### Scope & fail-closed

**R13 — `--link` scoped to `to-beam-wasm` this phase; `.core`-input `--link` deferred.** The `to-beam`
(`.core`-input) verb carries **no binding/profile**, so tier-N/import fail-closed cannot be enforced on
it. Scope `--link` to `to-beam-wasm` (binding present). The tier-N + `--link` rejection lives at the
**linker/CLI boundary**, NOT `profiles.link/1` (which is runtime instantiation, never on the link path).

**R14 — Import-bearing modules are link-time rejected.** A WASM module with function imports compiles to
`instantiate/1(Imports)` needing providers at instance time; a bare node has none. Reject import-bearing
modules with a typed error this phase (honest-scope addition).

**R15 — Freeze the mergeability invariants + a drift guard.** Verified ABSENT in tier-P/O and required to
stay so: NIF/`-on_load`, named/public ETS (ETS is call-time `private` unnamed), OTP
application/supervisor, `persistent_term`, `gleam@@main`. Freeze a structural test asserting their
absence over the manifest, **plus a drift test** that recomputes the transitive closure + surviving-remote
set from the current build and diffs against the frozen manifest/allowlist — so a future runtime change
(a new `import`, a new `@external`) fails *this* test, not the capstone.

### Process

**R16 — Revised 6-unit split; decisions and units are separately numbered.** O2 (linker) and O4
(capstone) were over-scoped for one owner; the manifest is separable inert data; the bare-node harness is
novel infra that must be proven before the capstone trusts it. **Decisions stay `O1–O8`; units are
`P11-01 … P11-06`** (this fixes the overview's conflation of `O`-numbers for both). See the table below.

**R17 — Name the new entry distinctly; `link` is 3-way overloaded.** `profiles.link/1` (runtime
instantiation), `runtime/link.gleam` (import weaving), and the new whole-program merge must not be
confused. Name the public entry `beam_link.link_program` (or `merge`) and add a one-line disambiguation in
`docs/phase-11-linking.md`.

---

## Revised unit split (supersedes `00-overview.md` §3/§4)

| Unit | Title | Owns | Freeze |
|---|---|---|---|
| **P11-01** | Keystone: runtime layer split | Relocate `OptLevel` to a leaf module; repoint `ir_opt`/`instance`/`profiles` + the ~7 test files (R3); freeze seam #2 as "no `ir` split" (R2); `link_layer_freeze_test` grep asserts runtime reaches zero compiler modules. Default output byte-identical. | `«RT-LAYER-FROZEN»` |
| **P11-02** | Link-closure manifest + allowlist + acquisition + invariants | `link_manifest.gleam`: the enumerated closure (incl. `gleam_stdlib.erl` and derived FFI `.erl`, R8), the per-module Core-acquisition method (R1), the **mechanically-derived** OTP-ambient allowlist (R7), the `__`-free mangle invariant (R12), the mergeability invariants + **drift test** (R15). All data + tests; changes no behavior. | `«CLOSURE-FROZEN»` |
| **P11-03** | The `cerl` linker engine | `twocore_linker_ffi.erl` + `backend/beam_link.gleam` (`link_program`, R17): acquire → reachability over **calls + applies + fun-captures + `instantiate/N` root** (R4/R6) → mangle **3 node classes + wrapper bodies** (R5) → DCE → `module_info`/attrs/determinism (R10/R11) → `from_core`; **built-in structural D3a self-check, fail-closed** (R9). In-process smoke differential on a numerics-only closure. | `«LINKER-IFACE-FROZEN»` |
| **P11-04** | CLI `--link` + `build_beam` entry + fail-closed gate | `--link` on `to-beam-wasm` only (R13); linked `build_beam` entry; tier-N + import-bearing + `on_load` rejection at the linker/CLI boundary (R13/R14). Default off ⇒ byte-identical. | — |
| **P11-05** | Bare-node isolation harness (proven first) | `twocore_linked_boot_ffi.erl`: spawn a fresh `erl` with scrubbed env (drop `ERL_LIBS`) + isolated `-pa`; an in-child `code:which == non_existing` gate over a representative closure set that **halts nonzero on any hit** (isolation measured, not assumed). A harness self-test proves it reports success on a hand-authored trivial self-contained `.beam` **and fails** when a `twocore@` module is on the child path. | `«BARE-NODE-HARNESS-PROVEN»` |
| **P11-06** | Capstone | **L1** in-process linked≡non-linked differential over the full corpus × mode × state × tier P/O (bit-pattern + trap identical); **L2** bare-node differential over the import-free subset + a constant-space proof on the bare node; determinism byte-check (R10); D3a structural assertion over the corpus (R9); `docs/phase-11-linking.md`; `01-status.md` §5. **PHASE 11 PROVEN.** | — |

**Waves.** Wave 0: P11-01 → P11-02. Wave A: P11-03 (crux) with P11-04 (CLI, against `«LINKER-IFACE-FROZEN»`)
and P11-05 (harness, depends on nothing) in parallel. Wave B: P11-06.

---

## Verified de-risking facts (do not re-investigate; do not over-engineer)

- **Merge is real on OTP 29.0.2** — acquire (`beam_lib` `debug_info core_v1`) → mangle → `core_lint` →
  `compile:forms([from_core,binary])` → `code:load_binary` → correct result, all executed.
- **`twocore/ir` is a clean leaf** (2 stdlib imports, 94 importers) — no split (R2).
- **The tier-P/O closure is genuinely mergeable** — no NIF/`-on_load`/behaviour/`parse_transform`/
  `persistent_term`/`gleam@@main`/app-start-ETS; ETS is call-time `private` unnamed; state is
  pdict/atomics at call time. tier-N correctly excluded.
- **No data-driven `apply`/`make_fun`/`list_to_atom` in the source closure** — so D3a (bit-identity +
  trap-preservation) *can* hold through an atom-safe `cerl` rewrite, provided R4/R9 are honored.
