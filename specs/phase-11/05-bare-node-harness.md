# Phase 11 · P11-05 — Bare-node isolation harness (proven first)

> **Status:** unclaimed · **Owner:** one agent · **Freeze produced:** `«BARE-NODE-HARNESS-PROVEN»`.
> **Depends on:** nothing but the `.beam`-file contract ⇒ **fully parallel** (Wave A, alongside P11-03/P11-04).
> Read order: `00-overview.md` → `RECONCILIATION.md` → this doc. RECONCILIATION wins on any conflict.

## §1 Goal

Deliver the **measured** bare-node isolation harness the capstone (P11-06 · L2) trusts, plus the self-test that
proves it works. This is the test-first mandate from `RECONCILIATION.md` R16 ("novel infra that must be proven
before the capstone trusts it") and it operationalizes two acceptance rows from `00-overview.md` §1 —
**"Single artifact"** (loads via `erl -pa <dir with only that file>` on a node with no `twocore@*`/`gleam@*`
reachable) and **"Bare-node proof"** (the linker output is *actually booted* on a clean node — measured, not
asserted, mirroring the Phase-10 "runs 100k iters in constant space" precedent in `03-phase-workflow.md` §8).

Concretely, P11-05 builds a harness that:
1. spawns a **fresh OS `erl`** (not an in-VM peer/slave node) with a **scrubbed environment** (`ERL_LIBS` and
   the flag-injection vectors dropped) and an **isolated `-pa`** containing *only* the linked `.beam`;
2. runs an **in-child gate** that `code:which/1`-probes a representative closure set and **halts nonzero on any
   hit** — so isolation is *measured*, never assumed (R6/O5 hygiene: a bare node has nothing else on the path);
3. **seeds then invokes in one process** (R6: `instantiate/0` then the export in the same process, so the pdict
   cell survives — with cell/threaded self-detection mirroring the existing run-ABI), and prints a parseable
   `RESULT:` / `TRAP:` line.

It does **not** run the corpus differential or the D3a structural check (those are the capstone, P11-06). It
ships the harness and a self-test that proves the harness both **reports success** on a hand-authored trivial
self-contained `.beam` **and fails (nonzero) when a `twocore@` module is deliberately placed on the child path**.

## §2 Depends on / Produces

- **Consumes:** no freeze. The only interface it needs is "a `.beam` binary + its module atom" (P11-03's
  `beam_link.link_program -> Result(#(Atom, BitArray), LinkError)` returns exactly this pair — see §7). The
  self-test manufactures its own fixture `.beam`s at test time, so P11-05 can land before P11-03.
- **Produces:** `«BARE-NODE-HARNESS-PROVEN»` — the frozen FFI signature + the stdout/exit-code contract (§3) that
  P11-06's L2 bare-node differential builds against.

## §3 What it owns + design

**Files (D1 one-owner):**
- **create** `test/twocore_linked_boot_ffi.erl` — the port-spawn harness FFI. Hand-written Erlang ⇒ it carries
  the `twocore_` namespace prefix (same convention as the seven existing `test/*.erl` FFI shims, e.g.
  `test/twocore_conformance_ffi.erl`, all of which `gleam` compiles and exposes via `@external`). It reuses the
  proven spawn/collect pattern from `test/twocore_conformance_ffi.erl:279` (`run/2` → `open_port({spawn_executable,
  Exe}, [{args,…}, exit_status, stderr_to_stdout, binary, hide])`) and `:287` (`collect/2`), and the
  seed-then-invoke + cell/threaded self-detection from `:80` (`start_common/2`, incl. the `instance_state`
  tag-match at `:93` and `render_reason/1` at `:198`).
- **create** `test/twocore/backend/linked_boot_test.gleam` — the gleeunit self-test module (alongside the other
  backend suites in `test/twocore/backend/`). Its `@external` bindings live at the top of this same file (one
  owned Gleam module; no separate binding module needed).

**Why a fresh OS `erl`, not a peer node (the load-bearing isolation argument).** A newly-exec'd `erl` computes
its own code path from its **own** `$ROOT` install + `-pa`/`-pz` + `ERL_LIBS` — it does **not** inherit the
parent test VM's runtime-added paths (where `build/dev/erlang/twocore/ebin`'s `twocore@*`/`gleam@*` beams live).
A `peer`/`slave` node can share `ERL_LIBS`/paths, so it would *not* prove isolation. Spawning a fresh executable
is what makes the `code:which == non_existing` gate meaningful — and we still **measure** it rather than trust it.

**FFI public API (frozen by `«BARE-NODE-HARNESS-PROVEN»`):**

```erlang
%% Compile a hand-authored fixture module to a .beam binary (deterministic), so the
%% self-test can manufacture self-contained fixtures WITHOUT the linker (P11-03).
%% {ok, Beam} | {error, RenderedReason}.
compile_source(ModuleName :: atom(), Source :: binary()) -> {ok, binary()} | {error, binary()}.

%% Boot Beam on a fresh, scrubbed, isolated erl and run instantiate/0 then Fun(Args)
%% in ONE process. Extra = additional {Mod,Beam} pairs written to a SEPARATE -pa dir
%% (empty [] for the isolated case; the negative self-test injects a twocore@ module
%% here to prove the gate fires). Returns {ExitStatus, CombinedStdoutStderr}.
boot_invoke(Beam :: binary(), ModuleName :: atom(), Fun :: atom(),
            Args :: [term()], Extra :: [{atom(), binary()}]) -> {integer(), binary()}.

%% code:which/1 IN THE PARENT — used to prove the gate atoms are REAL (non-vacuous).
which_in_parent(Mod :: atom()) -> {ok, binary()} | error.
```

**Gleam bindings (top of `linked_boot_test.gleam`):**

```gleam
@external(erlang, "twocore_linked_boot_ffi", "compile_source")
fn compile_source(module: Atom, source: String) -> Result(BitArray, String)

@external(erlang, "twocore_linked_boot_ffi", "boot_invoke")
fn boot_invoke(beam: BitArray, module: Atom, function: Atom,
               args: List(Int), extra: List(#(Atom, BitArray))) -> #(Int, String)

@external(erlang, "twocore_linked_boot_ffi", "which_in_parent")
fn which_in_parent(module: Atom) -> Result(String, Nil)
```

(`args: List(Int)` matches the raw-int invoke shape used by `catch_apply`/`call_instance`; Erlang is untyped, so
P11-06 may bind the same `boot_invoke/5` with `List(Dynamic)` if it needs term/reference args — the
`call_instance`/`call_instance_terms` precedent.)

**Boot mechanics (inside `boot_invoke/5`):**
1. `Exe = os:find_executable("erl")` (mirrors `find_executable/1`); if `false`, return `{127, <<"erl not found">>}`.
2. Make a unique temp dir `LinkDir` under the system temp (`os:getenv("TMPDIR")`|`/tmp` + a
   `erlang:unique_integer([positive,monotonic])` suffix); write `Beam` to `LinkDir/<ModuleName>.beam` (the
   `.beam`-file contract: `code:which(M)` resolves `M` to `M.beam` on the path). Write each `Extra` pair into a
   **separate** `ExtraDir` (kept out of `LinkDir` so the isolated case has *exactly one* file on the path).
3. Spawn: `erl -noshell -boot no_dot_erlang -pa LinkDir [-pa ExtraDir] -eval "<Runner>"`.
   - `-boot no_dot_erlang` neutralizes `~/.erlang` auto-exec (a code-path injection vector).
   - Env scrub via the `{env, [...]}` port option, each set to `false` to **remove** it:
     `ERL_LIBS`, `ERL_FLAGS`, `ERL_AFLAGS`, `ERL_ZFLAGS`.
   - Options otherwise identical to `run/2`: `exit_status, stderr_to_stdout, binary, hide`; collect with the
     `collect/2` loop → `{ExitStatus, Output}`.
4. `del_dir_r` the temp dirs (best-effort) before returning.

**The in-child `<Runner>`** (built with `io_lib:format`, `~w` for re-parseable embedded literals; runs in the
`-eval` init process ⇒ one process, so the pdict cell persists across `instantiate` → invoke):

```erlang
%% (a) NOLOAD guard: the linked module itself must be on the child path.
case code:which(M) of non_existing -> io:format("NOLOAD:~p~n",[M]), halt(4); _ -> ok end,
%% (b) ISOLATION GATE (measured): representative closure set must ALL be absent.
lists:foreach(fun(Md) -> case code:which(Md) of
                             non_existing -> ok;
                             _ -> io:format("LEAK:~p~n",[Md]), halt(3)
                         end end,
    ['twocore@runtime@rt_mem','gleam@list',gleam_stdlib,'twocore@ir']),
%% (c) seed-then-invoke in THIS process, cell/threaded self-detected (mirrors start_common/2).
try  St0 = M:instantiate(),
     Pkg = case St0 of
             ok -> apply(M, F, Args);                                   % Cell
             T when is_tuple(T), element(1,T) =:= instance_state ->     % Threaded
                 element(1, apply(M, F, [St0 | Args]))                  % {Pkg, St'} → Pkg
           end,
     io:format("RESULT:~0p~n", [Pkg]), halt(0)
catch _:R -> io:format("TRAP:~0p~n", [R]), halt(0) end.
```

**Frozen exit-code + stdout contract** (`«BARE-NODE-HARNESS-PROVEN»`):

| Exit | stdout line | Meaning |
|---|---|---|
| `0` | `RESULT:<~0p of package>` | ran clean; `~0p` of a bare integer *is* the raw bit pattern (D5) — the parent string-compares against an oracle rendered the same way |
| `0` | `TRAP:<~0p of reason>` | export trapped; reason text is substring-matchable (e.g. `wasm_trap`) |
| `3` | `LEAK:<mod>` | **isolation gate hit** — a closure module was reachable ⇒ the gate gates |
| `4` | `NOLOAD:<mod>` | the linked module itself was not on the child path (harness/path bug) |
| `127`| `erl not found` | `erl` not on PATH |

`apply/3` here is the **harness** invoking a build-fixed export — it is not ambient authority in the *artifact*
(D3a governs the merged `.core`, checked structurally by P11-03/P11-06, not this harness process).

## §4 The work

1. Create `test/twocore_linked_boot_ffi.erl` with `-module(twocore_linked_boot_ffi).` and export
   `compile_source/2, boot_invoke/5, which_in_parent/1`. Add module-level `%%%` docs stating the trust boundary
   (test-only, spawns a scrubbed child; not the OTP-internals boundary of the codegen shim — it only uses `os`,
   `file`, `compile`, `code`, `erlang`).
2. Implement `compile_source/2`: write `Source` to `Tmp/<Mod>.erl`, `compile:file(File, [binary, return_errors,
   deterministic, {outdir,…}])` (or `compile:file` returning `{ok, Mod, Beam}`); fold errors to a UTF-8 binary
   via `io_lib:format`, exactly like the existing shims. Clean up the temp `.erl`.
3. Implement `boot_invoke/5` per §3: temp dirs, write `.beam`(s), format `<Runner>`, `open_port` with the
   scrubbed `{env,…}`, `collect/2`, `del_dir_r`. Factor `collect/2` (copy the conformance pattern verbatim).
4. Implement `which_in_parent/1`: `case code:which(Mod) of non_existing -> error; P -> {ok, list_to_binary(P)} end`.
5. Create `test/twocore/backend/linked_boot_test.gleam` with the three `@external` bindings and the fixture
   source strings (see §5). Add `///`/`////` doc comments on every binding and test.
6. `gleam format` · `gleam build` (zero warnings — Erlang side must be `erlc`-warning-free: no unused vars,
   guard the `Extra`-empty case) · `gleam test -- twocore/backend/linked_boot_test`.

## §5 Tests (`test/twocore/backend/linked_boot_test.gleam`)

Cited against `00-overview.md` §1 (rows "Single artifact"/"Bare-node proof"), R6 (seed-then-call), and the
"measured, not asserted" precedent (`03-phase-workflow.md` §8). Fixtures are hand-authored (no linker dependency):

- **Positive fixture** `SELF` — `compile_source('twocore_link_selftest_ok', …)` with body:
  `instantiate() -> ok.` · `answer() -> 42.` · `boom() -> erlang:error({wasm_trap, unreachable}).` ·
  `tinst() -> {instance_state, 7}.` · `tanswer(St) -> {element(2,St) + 35, St}.` (calls only `erlang:error`/`+`
  ⇒ genuinely self-contained: no `twocore@`/`gleam@` edge).

1. `gate_atoms_are_real_test` — **anti-vacuity guard.** Assert `which_in_parent/1` is `Ok(_)` for
   `gleam@list`, `gleam_stdlib`, `twocore@ir` (and `twocore@runtime@rt_mem`) in the *parent* build, so the
   child's `non_existing` is a real absence, not a typo. (Closes the "misspelled gate ⇒ vacuous pass" hole.)
2. `reports_result_on_trivial_selfcontained_beam_test` — `boot_invoke(SELF, module, answer, [], [])` ⇒
   exit `0` and stdout **contains** `"RESULT:42"`. Because the gate halts *before* invoke on any hit, a
   `RESULT:` line at exit 0 **proves isolation held** (the "Single artifact" acceptance row, measured).
3. `gate_fires_when_twocore_module_on_child_path_test` — **the "gate gates" proof.** Compile an empty stub
   `compile_source('twocore@runtime@rt_mem', "-module('twocore@runtime@rt_mem'). -export([]).")`, then
   `boot_invoke(SELF, module, answer, [], [#('twocore@runtime@rt_mem', stub)])` ⇒ exit `3`, stdout contains
   `"LEAK:"` and does **NOT** contain `"RESULT:"`. (Adversarial must-NOT: the harness must refuse to report
   success when a runtime module is reachable.)
4. `reports_trap_on_trapping_export_test` — `boot_invoke(SELF, module, boom, [], [])` ⇒ exit `0`, stdout
   contains `"TRAP:"` and the reason substring `"wasm_trap"`; must **NOT** contain `"RESULT:"`. (Proves the
   trap path and that a trap ≠ isolation failure.)
5. `threaded_instance_shape_is_self_detected_test` — `boot_invoke(SELF, module, tanswer, [], [])`: `tinst`?
   no — the runner calls `M:instantiate()`; add `instantiate() -> {instance_state, 7}.` **variant** as a second
   fixture `SELF_THREADED` (its `instantiate/0` returns the record, `answer(St) -> {element(2,St)+35, St}`),
   `boot_invoke(SELF_THREADED, module, answer, [], [])` ⇒ exit `0`, `"RESULT:42"`. (Covers the Threaded branch
   of the cell/threaded self-detection so P11-06 can drive tier-O threaded builds.)
6. `noload_when_module_absent_test` — `boot_invoke(SELF_beam, 'wrong_module_name', answer, [], [])` (module
   atom that does not match the written `.beam`) ⇒ exit `4`, stdout contains `"NOLOAD:"`. (Proves the harness
   distinguishes a path/harness bug from a trap.)

## §6 Definition of Done (`03-phase-workflow.md` §9, made concrete)

1. **Spec-cited tests** — the six cases above, each tied to an acceptance behavior (isolation measured; gate
   gates; seed-then-invoke one-process; trap vs result vs leak vs noload). Adversarial must-NOTs present
   (test 3: no `RESULT:` under a leak; test 4: no `RESULT:` under a trap).
2. **Doc comments** — `%%%`/`%%` on every FFI function (contract: params, return shape, failure modes, the
   halt-code contract) and `////`/`///` on the Gleam module + every binding/test.
3. `gleam format --check src test` clean.
4. `gleam build` zero warnings — including the Erlang FFI under `erlc` (no unused vars; total case clauses).
5. `gleam test -- twocore/backend/linked_boot_test` passes; the full suite stays green (harness is additive,
   touches no unit-owned source and no pipeline/registration point).
6. Announce `«BARE-NODE-HARNESS-PROVEN»` in `state.md` with the frozen §3 contract.

## §7 What it leaves

- **To P11-06 (capstone · L2):** the frozen `boot_invoke/5` + `compile_source/2` + `which_in_parent/1` FFI and
  the exit-code/stdout contract (§3). L2 feeds P11-06 the pair straight from `beam_link.link_program` — the
  returned `Atom` is `ModuleName`, the returned `BitArray` is `Beam` — over the **import-free** tier-P/O subset
  (R13/R14: import-bearing modules are rejected pre-link, so `instantiate/0` always holds ⇒ the harness needs no
  `instantiate/1` path). L2 runs `boot_invoke` per corpus case, parses `RESULT:`/`TRAP:`, and diffs against the
  in-process oracle rendered with the same `~0p`, plus the bare-node constant-space proof.
- **To the reconciler / no one else:** nothing is handed to P11-01/02/03/04 — P11-05 is a leaf with no
  downstream API those units consume.
