# Specification: A Multi-Frontend Compiler Platform Targeting the BEAM

**Status:** Canonical architecture specification. The vision below is **substantially implemented** — Phases 1–15 are done and proven on `main` (the complete WebAssembly 2.0 fixed-width surface, Safe/Unsafe modes, the trust-tier ladder, the memory optimizer, JS-on-the-BEAM via Porffor reached & measured, `--link` self-contained output, typed host-language bindings, WASM tail calls, cross-module funcref-in-`elem` init, and a production tier-N C NIF). **Since 2026-08-16 the platform is split across repos: this repo (`carder`) is the shared IR and everything below it; each frontend is its own repo** — `scribbler` (WebAssembly, `scarletindustries/scribbler`) and `arc` (JavaScript, `alii/arc`). This document remains the enduring design reference for the backend and for the contract a frontend builds against; for *what is actually built* see [`01-status.md`](01-status.md), for *what is planned but not yet built* see [`02-roadmap.md`](02-roadmap.md), for *the frontend contract in full* see [`FRONTEND-API.md`](FRONTEND-API.md), and for *how phases are scoped & implemented* see [`03-phase-workflow.md`](03-phase-workflow.md). The live per-phase ledger is [`state.md`](state.md).
**Audience:** A downstream planning agent and the agent swarm that implements it.

**The shape of the thing.** A compiler that lowers multiple source languages into **one shared, language-neutral IR (ours)**, and emits **Core Erlang** from that IR so the result runs **fast and preemptively on the BEAM** — compiled, not interpreted. WASM was the first frontend (and transitively gives Rust→Erlang and, via **Porffor**, JS→Erlang — a stated goal: *any Porffor application runs via carder on the BEAM*, "JS on the BEAM"); JS via arc is the second; an Erlang/Gleam frontend follows as an additional frontend. All frontends share one IR, one optimizer, one backend, one standard library, and one security model — **and none of them has any code in this repo.**

**Three governing constraints (unchanged):**
1. **Built in Gleam** (build-time, on the BEAM).
2. **Generated code is pure Core Erlang.** Native code underneath is a per-deployment, per-layer choice (§10), never a global property.
3. **Every component is modular** — each stage and layer is a narrow, independently-invokable interface with many interchangeable implementations. This is the security model *and* the replaceability model (§13). The frontend/backend seam (§8.4) is the strongest instance of this rule: it is a **repo boundary**, not just a module boundary.

**Faithfulness beats raw speed; breadth and parallelism beat minimal effort** (implemented by a large agent swarm).

---

## 1. The platform vision (what's now vs. later)

```
   FRONTENDS (per-language → IR)         SHARED MIDDLE-END            BACKEND          RUNTIME
 ┌───────────────────────────┐
 │ WASM   (scribbler repo)   │─┐      ┌──────────────────┐     ┌──────────────┐   ┌──────────────┐
 │ Rust   (via WASM)         │ ├────▶ │   SHARED IR      │────▶│ IR → Core    │──▶│ shared rt +  │
 │ JS via Porffor (scribbler)│ │      │  + optimizer     │     │ Erlang AST → │   │ optional     │
 │ JS native   (arc repo)    │ │      │  + stdlib/cap    │     │ .core → BEAM │   │ linear-mem   │
 │ Erlang/Gleam (later, own  │─┘      │    lowering      │     └──────────────┘   │ subsystem    │
 │              repo)        │        └──────────────────┘                       └──────────────┘
 └───────────────────────────┘
   ── other repos ──────────▶│◀────────────────── THIS REPO (carder) ──────────────────────────▶
         each stage is a public, independently-callable interface; the IR has a textual form
```

- **Now:** the shared IR, the IR→Core-Erlang backend, the Safe/Unsafe security modes, the runtime tier ladder, the stdlib scaffolding, the embedder API, and the shared CLI vocabulary — all in this repo. The WebAssembly frontend (and with it Rust→WASM→IR→Erlang, and JS-via-Porffor) is **scribbler**.
- **Goal, reached — JS on the BEAM via Porffor:** JS via **Porffor** (JS→WASM AOT) feeding the WASM frontend → *any Porffor application runs via carder on the BEAM*. The Porffor-ABI host environment is supplied by **scribbler** as a `link.Provider.Namespace` (§8.4); carder hard-codes no host module by name.
- **Now, elsewhere:** a **native JS frontend** (arc) built directly against [`FRONTEND-API.md`](FRONTEND-API.md) — the way past Porffor's coverage ceiling and its closure wall.
- **Later:** an **Erlang/Gleam frontend** (write Gleam, deploy to the platform, provably unable to take over the VM via Safe mode) — which would likewise be its own repo.

The decisions in §2 are what had to be made **up front** — even though most frontends came later, and in other repos — so the platform never had to be rebuilt to accept them. The split in 2026-08 is the proof they held: the WASM frontend lifted out of the tree without a single IR change.

---

## 2. Decisions to lock now (the load-bearing ones)

These keep the IR frontend-agnostic and every stage independently targetable. Get them right up front; they are expensive to retrofit.

1. **The IR is language-neutral and the stable public target** — *not* WASM-shaped. No WASM-isms (linear memory, stack typing, fixed-width-only numerics) baked into the IR core. WASM is one frontend that lowers *into* the IR. **Post-split this is enforced structurally: no source language appears anywhere in this repo.**
2. **Linear memory is an optional IR feature**, declared per module — so term-based frontends (JS, Gleam) don't pay for it and don't link the memory runtime.
3. **IR control flow is structured** (block/loop/if/switch/break/continue/return; no arbitrary `goto`). Every frontend either is already structured (WASM, JS, Gleam) or relooper-izes before the IR. This keeps the backend (one uniform `letrec`+tail-call lowering) simple.
4. **Dual value model:** a high-level **term model** (BEAM-native values — the default, used by JS/Gleam/Erlang) and an opt-in **fixed-width numeric + linear-memory model** (used by WASM/Rust), with explicit conversion ops between them. Don't force JS objects through linear memory, nor WASM bytes through Erlang terms.
5. **Every stage boundary is a public, independently-invokable API, and the IR has a canonical, serializable textual form** (`.ir`). Any part of the chain can be driven, dumped, and tested in isolation — this is the explicit requirement that each link be callable independently. It is also what makes a cross-repo frontend practical: `.ir` is a file two repos can exchange, freeze and diff.
6. **`call_host` is the single capability boundary.** Stdlib calls and imported host functions both route through one IR node; Safe/Unsafe enforcement lives there and nowhere else. Fail closed.
7. **The standard library is defined at the IR level** (Gleam-style: tiny built-in surface, most of stdlib is a library targeting the IR), so it's identical across all frontends and swappable by security mode.
8. **Safe / Unsafe are global modes** that select stdlib implementation, the BEAM-function allowlist, optimization posture, runtime trust tier, and metering — in one switch (§6). The vocabulary that names them (`carder/cli`) is published **once** and imported by every frontend's binary, so postures cannot drift between tools.
9. **Compiled is the primary route, not interpreted**, and compiling to *Erlang* (not a long-running NIF) is what preserves BEAM preemption (§9.2). Interpreted-vs-compiled stays formally open, but the spec commits to compiled with an interpreter only as a fallback for unsupported features.
10. **Runtime splits in two:** a **shared runtime** (numerics, traps, instance state, host/capability dispatch, metering, stdlib) used by every frontend, and an **optional linear-memory subsystem** (memory, tables) linked only for modules that use linear memory.

---

## 3. The shared IR (concrete design)

The IR is a structured, functional, language-neutral IR that targets the BEAM. Concrete shape:

- **Module** = functions + declarations (globals; optional memories; optional tables; imports; exports; data/element segments for memory-using modules). A module flags whether it uses the **linear-memory subsystem**; if not, it uses term values throughout and links no memory runtime.
- **Function** = name, typed params + locals, body (an expression tree), with **proper tail-call semantics** (so the backend's tail calls become constant-space BEAM loops).
- **Control flow — structured only:** `block`, `loop`, `if/else`, `switch` (multi-way), `break(label)`, `continue(label)`, `return`. Labels by name; the backend resolves them to `letrec` continuation functions.
- **Values — two first-class layers:**
  - **Term values** (default): map directly to BEAM terms — bignum ints, floats, atoms, binaries, tuples, lists, maps, closures, plus a boxed `dynamic` for JS semantics. Frontends: JS/Gleam/Erlang.
  - **Low-level numerics + linear memory** (opt-in): `i32/i64/f32/f64` with explicit wrap/overflow/trap semantics, and a byte-addressable linear memory with typed load/store. Frontends: WASM/Rust.
  - **Explicit conversions** between the two (box an `i32` into a term; read memory bytes into a binary; etc.). No implicit bridging.
- **Operations:** low-level numeric ops (width-tagged; semantics in §9.1); term construction/destructuring (cons/tuple/map build + pattern match); memory load/store (low-level path only).
- **Calls — three kinds, all first-class:**
  - `call_direct(fn, args)` — to another IR function.
  - `call_indirect(table, idx, type, args)` — dynamic dispatch with a **runtime type check** (WASM funcref, JS first-class functions/methods, closures). Mismatch ⇒ trap.
  - `call_host(capability, name, args)` — the **sole gated boundary** to anything outside the module's own values/memory: imported host functions *and* stdlib calls both lower to this. Safe/Unsafe capability checks attach here.
- **Effects:** `trap(reason)`; `charge(cost)` (metering; inserted by the middle-end when enabled).
- **Textual form (`.ir`):** a stable, human-readable, round-trippable representation (think LLVM `.ll`). It is the contract between frontends and the middle-end, makes the IR independently targetable by external tools, and lets every stage be unit-tested by feeding/dumping `.ir`. It is now also the **inter-repo** contract: carder's own test corpus is checked-in `.ir` (§11), and a frontend can hand carder a bug report as a single file.

This IR is rich enough for dynamic languages (term model, `dynamic`, closures, host calls) and low-level languages (fixed-width numerics, linear memory) without forcing either into the other's shape — decision #1/#2/#4 made concrete. The complete, authoritative statement of what a frontend may emit is [`FRONTEND-API.md`](FRONTEND-API.md).

---

## 4. Pipeline & layer map

Every row is an independently-implementable, independently-auditable, independently-invokable module. **The IR is the seam between frontend and middle-end — and, since the split, between repos.** Rows above the seam are listed for the complete picture; they are not in this repo.

| # | Stage / layer | Interface | Repo | Phase | Axis | Security boundary | Initial implementations |
|---|---|---|---|---|---|---|---|
| **Frontends** (source → IR) — *each in its own repo, none in carder* |
| FW | WASM frontend | `scribbler/wasm/*` | **scribbler** | build | — | — | decode→validate→canon→lower→IR |
| FJ | JS frontend | Porffor→WASM, or `arc` | **scribbler / arc** | build | — | — | Porffor JS→WASM→scribbler; arc emits IR directly |
| FE | Erlang/Gleam frontend | `fe_beam` | *(later, own repo)* | build | — | **yes** (restricts unsafe) | ingest→restrict→IR |
| **Shared middle-end** (IR → IR) |
| M1 | IR core + textual form | `carder/ir` | carder | build | — | — | the IR module + `.ir` reader/writer |
| M2 | Optimizer | `carder/middle/ir_opt` | carder | build | optimization | — | `baseline`, `aggressive` (incl. trust-assuming passes) |
| M3 | Stdlib + capability lowering | `carder/middle/ir_lower` | carder | build | **policy** | **yes** | resolves stdlib, applies allowlist, inserts metering |
| **Backend** (IR → BEAM) |
| B1 | Emitter (IR → Core Erlang) | `carder/backend/emit_core` | carder | build | format+binding+instrumentation | partial | `core_text` (default), `cerl_ast` |
| B2 | Driver (.core → .beam) | `carder/backend/build_beam` | carder | build | mechanism | — | `forms`, `file` |
| B3 | Self-contained linking / bindings | `beam_link`, `bindings` | carder | build | packaging | **yes** (`link_gate`) | `--link`, typed `.gleam`/`.erl`/`.ex` |
| **Shared runtime** (linked into output) |
| R-num | Numerics | `rt_num` | carder | run | **trust P/N** | — | `bif` (P, default), `nif` (N) |
| R-trap | Traps | `rt_trap` | carder | run | — | — | `error` |
| R-state | Instance state | `rt_state` | carder | run | **trust P/O** | — (sets convention) | `threaded` (P), `pdict`/`ets` (O) |
| R-host | Host/capability dispatch | `rt_host` | carder | run | **capability** | **yes** | `deny_all` (default), `whitelist`, `open` |
| R-link | Import resolution / providers | `runtime/link` | carder | run | **capability** | **yes** | `Registered`, `ProvidedFunc`, **`Namespace`** (frontend-supplied) |
| R-meter | Metering | `rt_meter` | carder | run | **policy** | **yes** | `none`, `fuel` |
| R-std | Standard library | `rt_stdlib` | carder | run/build | **policy** | **yes** | `own` (Safe), `passthrough` (Unsafe) |
| R-bif | BEAM-function gate | `rt_bif` | carder | build | **capability** | **yes** | `allowlist` (Safe), `open` (Unsafe) |
| **Optional linear-memory subsystem** (only if the module uses linear memory) |
| R-mem | Memory | `rt_mem` | carder | run | **trust P/O/N** | **yes** | `paged` (P), `atomics` (O), `nif` (N); + `rebuild` oracle |
| R-tab | Tables | `rt_table` | carder | run | **trust P/O** | **yes** | `map` (P), `ets`/`atomics` (O) |
| **Linker / entry points** |
| I | Instantiation | `rt_instance`, `profiles` | carder | run | — | — | wires chosen runtime impls per instance/mode |
| X | Drivers | `carder/pipeline`, `carder/embed`, `carder/cli` | carder | build/run | — | **yes** (`resolve_binding`) | IR-entry pipeline, embedder API, shared CLI vocabulary |

Two axes of variation recur (carried from the modular design): **trust tier P/O/N** for mutable-state layers (P = pure language, no OTP-native state, no NIF, can't crash the node; O = OTP-standard native, memory-safe, no custom code; N = custom NIF, fastest, can crash the node), and **policy/capability/format** for the rest.

---

## 5. Backend: IR → Core Erlang

The backend is the proven structured-control→`letrec`+tail-call machinery, consuming the **shared IR**. It is uniform across frontends because the IR is — and, since the split, it has no way to be otherwise: nothing in this layer can name a source language.

- **Structured control flow → `letrec` of tail-recursive functions.** `block`→ forward-break continuation `K(vals…)`; `loop`→ body `L(vars…)` with `break`/`continue` as `apply` (tail self-call ⇒ constant-space iteration); `if`→ `case` on the condition with each arm returning the merged live-value list `<…>`; `switch`→ `case` selecting continuation functions (default arm); `return`→ return the value list; labels resolved via a compile-time label→continuation stack. Proper BEAM tail calls make loops constant-space and **preemptible** (§9.2).
- **Operand handling.** IR values are already named (frontends do their own SSA/stack-elimination before the IR — the WebAssembly frontend eliminates the operand stack in its own repo; JS/Gleam are already in named-variable form). The backend binds them with `let` and threads them through continuation parameters at merges (φ-nodes → arguments).
- **Calls.** `call_direct`→ `apply 'fn'/N(...)`; `call_indirect`→ `rt_table` dispatch + type check; `call_host`→ `rt_host`/`rt_stdlib` dispatch (the capability boundary); an *imported* function → `link.call_import` against the resolved provider (§8.4).
- **Numerics** route through `rt_num` (fidelity invariants §9.1); **memory** through `rt_mem` (bounds-checked → trap); **traps** through `rt_trap`.
- **Emission.** Build a **Gleam-native Core Erlang AST as custom types, then pretty-print to `.core` text** (not the Erlang `cerl` record API — awkward over FFI, loses type safety). Small, fiddly printer for Core Erlang's lexical rules (atom quoting, variable capitalization, function-name vars `'f'/N`, `-| [...]` annotations) with **its own unit tests**; assemble with a `string_tree` builder. Compile via Gleam `@external` FFI to a `compile:forms/2`/`from_core` shim. Emitter config sub-axes: format (`core_text`/`cerl_ast`), `state_strategy` (`threaded`/`cell`, driven by the `rt_state` tier — §10), and metering instrumentation on/off.
- **Codegen security invariants** (hold in every emitter impl): every memory/table op routes through the runtime (never a raw term op); no IR node lowers to an open `apply` of an attacker-chosen module/atom (no ambient authority) — **including** provider dispatch, which is always a first-class closure the caller supplied, never `apply/3` on program data.

---

## 6. Security: Safe and Unsafe modes

Two named, global modes (the user's framing), each a bundle of per-layer choices applied by the middle-end (`ir_lower`) and the linker (`profiles`/`rt_instance`):

- **Unsafe** — *emit the fastest possible code; near-native, potentially faster than hand-written Erlang via our own optimizations.* For deployments you run yourself.
  - Optimizer `aggressive` (incl. trust-assuming passes); stdlib `passthrough` (route to BEAM stdlib/BIFs where faster); BIF gate `open` (full BEAM access); runtime tiers may be O or N; metering `none`; host `whitelist`/`open` as configured.
- **Safe** — *sandboxed.* For untrusted / multi-tenant code (the platform case).
  - **Only a vetted allowlist of BEAM functions** (`rt_bif: allowlist`); **own reimplemented stdlib** (`rt_stdlib: own` — keep a few BEAM functions, e.g. `string:split`, and reinvent the rest so the surface is auditable); host `deny_all` by default (grant capabilities explicitly via `whitelist`); runtime tiers **P or O only** (no node-crashing NIFs — tier N is forbidden in Safe); metering **on** (`fuel`); optimizer restricted to trust-neutral passes.

**Why the stdlib and BIF gate are security layers, not conveniences.** In Safe mode the threat is untrusted code reaching BEAM functionality that can escape the sandbox, exhaust the node, or read ambient state. Trusting the full BEAM stdlib defeats that. So Safe mode trusts *almost none* of it: a small audited allowlist plus an in-house stdlib whose every function we control. Because the stdlib is defined at the IR level (§7), the same Safe stdlib serves every frontend.

**Fail closed.** Defaults are the safe choice (deny-all host, allowlist BIFs, full validation, metering on for untrusted). A misconfiguration must reduce capability, never expand it. The **instance is the unit of policy** (§10): Safe and Unsafe instances coexist on one node, identical generated code, different linked runtime.

**One gate, one vocabulary — across repos.** `carder/cli.resolve_binding` is the sole sanctioned `Binding → Instance` path (it composes the axis flags and routes them through `profiles.link/1`), and every frontend's CLI **imports** it rather than reimplementing it. A forked copy could drift into admitting `Safe` + tier-N, or an uncapped `atomics` build — precisely the invariant the gate exists to hold. Publishing the vocabulary once is therefore a security decision, not an ergonomic one.

---

## 7. The standard library

Modeled on Gleam's approach — a deliberately tiny built-in surface, with most of "the standard library" being a regular library that targets the IR. Because all frontends share the IR, **one stdlib is consistent across every language** on the platform.

- **Defined at the IR level.** Stdlib functions are either expressed *in* the IR (and compiled like any module) or are vetted `call_host` entries into the runtime. Either way they're frontend-agnostic.
- **Two implementations behind `rt_stdlib`:** `own` (in-house, vetted — Safe mode) and `passthrough` (delegates to BEAM stdlib where it's faster and the function is trusted — Unsafe mode). A few BEAM functions are retained in both (e.g. `string:split`); the rest are reimplemented for Safe mode.
- **Consequence for frontends.** A JS frontend's `Array.prototype.map`, a Gleam frontend's `list.map`, and a Rust-via-WASM iterator all bottom out in the same shared IR-level primitives and the same stdlib — consistent semantics and one place to audit. A *language* runtime (arc's `rt_js`, a wasm producer's intrinsics) is **not** stdlib: it lives in the frontend's repo and is reached through the seams in §8.4.

---

## 8. Frontends — out of repo, on a contract

Every frontend owns its source language, its emitter, and its language runtime; carder owns the IR and everything below it. This section is deliberately short: the details of each frontend live in that frontend's repo, and the contract between them is §8.4 plus [`FRONTEND-API.md`](FRONTEND-API.md).

### 8.1 WebAssembly — `scribbler` (its own repo)
The WASM frontend lives in **scribbler** (`scarletindustries/scribbler`): decode, validate, canonicalise, lower (`scribbler/wasm/{ast,decode,validate,canon,lower,wat}`), a wasm-entry pipeline and CLI, the wasm-producer host namespaces (`spectest`, TeaVM, Porffor), and the entire official WebAssembly spec-test conformance suite. It consumes carder as an ordinary Gleam package and stops at `carder/ir.Module`. **Rust→Erlang** falls out of the same path (Rust→WASM→IR→Erlang) — real, though not native-Rust speed. See scribbler's own `specs/00-high-level.md` (scribbler repo) for its architecture, and [`FRONTEND-API.md`](FRONTEND-API.md) for the contract it emits against.

### 8.2 JavaScript — Porffor via scribbler, or arc (their own repos)
Two roads, neither in this repo:
- **JS via Porffor** (CanadaHonk's AOT JS/TS→WASM compiler) chains **Porffor → scribbler → IR → Core Erlang**, delivering the stated goal — *any Porffor application runs via carder on the BEAM*. Porffor's Wasm uses its own runtime ABI rather than WASI; that ABI is supplied by **scribbler** (`scribbler/porffor/host`) as a `link.Provider.Namespace` (§8.4). It is bounded by Porffor itself: an experimental project supporting a limited subset of JS (historically on the order of a third of ECMA-262), with a known closure wall.
- **JS natively — arc** (`alii/arc`) emits carder IR directly from its own parser + scope analysis, using the term layer (closures, maps, `NumTerm` guarded arithmetic) and its own `rt_js` bound through `profiles.direct(DirectHost)`. This is the way past Porffor's ceiling. [`FRONTEND-API.md`](FRONTEND-API.md) is written with arc as its worked example.

### 8.3 Erlang/Gleam frontend (`fe_beam`, security boundary) — later, and its own repo
Ingest Core Erlang / Gleam, **restrict unsafe functionality** (disallow VM-escaping BIFs, enforce the Safe-mode allowlist), and emit IR. The payoff: *write Gleam, deploy to the platform, and be provably unable to take over the VM.* The restriction pass is the security boundary; it rejects (fails closed) rather than strips-and-hopes. Never taken by any phase; when it is, it follows the scribbler/arc precedent and lives in its own repo — carder's half is only whatever the IR + `ir_lower` boundary must expose (see [`02-roadmap.md`](02-roadmap.md) §A).

### 8.4 The frontend contract — three seams, and the rule that keeps carder language-neutral

This is the load-bearing part of the platform's multi-frontend claim. **A frontend uses exactly three seams, and carder gains no knowledge of any source language from any of them.**

1. **Compile and run: `carder/pipeline` (and `carder/embed`).** A frontend produces a `carder/ir.Module` and calls `pipeline.compile_ir(module, binding)` or `pipeline.run_ir(module, binding, export, args)` — plus `run_ir_chunked` / `ir_to_chunks` for large modules, `instantiate_with_provided` / `instantiate_with_host_providers` / `invoke_instance_pair` for driving an instance directly, and `classify_run_error` / `host_output` for observing outcomes. The embedder front door is `carder/embed.compile_ir(m, on_progress)` → `instantiate` / `invoke` / `stop` / `mem_read` / `mem_write`. **carder's entry types are IR types.** No stage below the IR branches on where the module came from; `PipelineError` names only carder's own stages (`IrLowerFailed`, `EmitFailed`, `BuildFailed`), and a frontend composes its own stage errors on top at exactly one seam.
2. **Bind a language runtime: `profiles.direct(DirectHost)`.** A source language's semantics (JS property lookup and coercion, an interpreter's builtins) reach compiled code only through `call_host(capability, op, args)`, dispatched against a **build-time table of `HostOp(module, function, kind)` literals** the frontend supplies. Adding an operation is a table entry in the frontend's repo — **never a carder change**, and never a dynamic `apply` on program data (D3a: no ambient authority).
3. **Supply host modules the source imports: `link.Provider.Namespace(link_name, func, state)`.** carder resolves an import `#(module, name)` **only** against the providers its caller handed it. It hard-codes **no** host module by name — the spec suite's `spectest`, a TeaVM guest's `teavmJso`, a Porffor guest's `""` intrinsics are all namespaces supplied by scribbler; a WASI environment would be one more. A `Namespace` resolver returns a term-native `ProvidedFunc(sig, closure)` matched against the declared type by equality, so reference-typed imports (which the numeric `rt_host` ABI cannot express) work without carder knowing what they mean. Omit a provider and the import fails closed.

Two supporting rules make the seams stick:

- **The shared CLI vocabulary (`carder/cli`) is imported, never forked** — the axis flags, `resolve_binding`'s security gate, `link_gate`, and the raw-bit value formatting. Every frontend binary therefore has the same postures with the same defaults and the same refusals (§6).
- **Source-language knowledge never enters carder.** No module name, capability name, host module, file extension, or spec quirk belonging to a source language may appear in this repo — that is what makes "one backend, many frontends" a fact rather than an aspiration, and it is why the 2026-08 extraction of the WASM frontend required no IR change. If a frontend needs something carder cannot express, the fix is a **more expressive IR/seam**, never a special case.

---

## 9. Numeric fidelity & execution semantics

### 9.1 Numeric fidelity invariants (part of the `rt_num` contract)
Exact or computations silently corrupt — these hold in every `rt_num` implementation:
- **Integers wrap two's-complement.** Erlang ints are bignums; **every** low-level op masks to width and reinterprets signedness as required; shift counts masked mod bit-width; signed values stored as unsigned bit patterns, sign-interpreted on demand (one documented convention).
- **Division traps:** `div_s INT_MIN/-1` (overflow) and `_/0` trap.
- **Floats are IEEE-754.** `f64`→ Erlang doubles directly; **`f32` rounded to single precision after every op** (no native 32-bit float — `<<X:32/float>>` round-trip); **NaN bit-pattern propagation/canonicalization** per spec; `min`/`max` differ from Erlang's on NaN; `reinterpret` is a pure bit cast.

(These are the low-level path's invariants — the ones a WASM-shaped frontend depends on; the term path uses BEAM-native arithmetic with its own, simpler semantics chosen by each frontend's language. The run/invoke ABI marshals both as **raw unsigned bit patterns**, D5.)

### 9.2 Execution model — preemptive, compiled
- **Compiling to Erlang gives BEAM preemption for free.** Generated code runs as ordinary BEAM code; the scheduler preempts at reduction boundaries, and our tail-recursive loops consume reductions and yield — so even tight loops are **fairly scheduled** — the same fair-scheduling property that makes JS-on-the-BEAM viable. This is a primary reason to compile (not interpret) and to compile **to Erlang** rather than run a long-running interpreter NIF (which would block a scheduler thread).
- **Implication for tier-N memory.** A NIF memory backend is fine because its operations are *per-access and short*; what must never exist is a *whole-program* native loop that runs uninterrupted. Keep native code at the granularity of a single memory/table op.
- **Interpreted vs compiled stays open but decided.** The compiled route is primary (near-native + preemptive). If an interpreter is ever built for not-yet-supported features, it must be process-per-instance and yield-aware so it inherits the same fairness.

---

## 10. Modularity, trust tiers & binding (carried forward)

The mechanism behind §4's layer map.

- **Trust tiers P/O/N** apply to mutable-state runtime layers (memory, tables, instance state, optionally numerics): **P** pure language (no OTP-native state, no NIF; cannot crash the node; runs anywhere — the true "no OTP, no NIF" build), **O** OTP-standard native (`atomics`/`ets`/process dict; memory-safe; no custom code), **N** custom NIF (fastest; can crash the node; permitted only where the deployment allows native code — and **never in Safe mode**). The axis is *whose native code runs and whether it can crash the node.*
- **Memory is the canonical layer** (`rt_mem`, security boundary, every access bounds-checked → trap): `rebuild` (oracle), **`paged`** immutable binaries (P, O(page), universal default, sparse-friendly), **`atomics`** (O, O(1), process-local — sharing is opt-in and we never share; the only cost is an atomic barrier, trivial vs a binary rebuild), **`nif`** (N, raw O(1), the ceiling, Unsafe-only). `grow` under `atomics` is the sharp edge (fixed-size at creation → pre-allocate to declared `max` or fall back to `paged`). Uniform behaviour signatures; build order `rebuild`→`paged`→`atomics`→`nif`.
- **Uniform-threading rule:** every mutating runtime op **returns the (possibly new) handle**; mutable backends return the same handle, immutable backends return the updated structure — one signature serves both.
- **The state layer sets the calling convention:** tier-P `rt_state` threads a purely functional instance record through every function (the zero-native build); tier-O holds handles in process-dictionary/ETS cells. So generated code is identical across memory/table/numeric tiers *given a fixed state tier*, and differs only across the state tier (`state_strategy = threaded | cell`).
- **Binding model** (how generated code stays backend-agnostic): **(B1) instance-level dispatch** (the instance record carries the chosen impl modules; enables different-trust instances on one node = the instance is the unit of security policy — still deferred, [`02-roadmap.md`](02-roadmap.md) §D), **(B2) link-time fixed binding** (zero indirection, one tier per node), **(B3) monomorphized build** (specialize against one backend; fastest; the shipped path).
- **Packaging** is a further, orthogonal choice: `--link` merges the runtime closure into one self-contained `.beam` for a bare OTP node, and `--bindings` emits typed `.gleam`/`.erl`/`.ex` companions. Both are gated (`cli.link_gate`) and both refuse postures they cannot honestly package (e.g. tier-N).

---

## 11. Correctness & conformance

**Source-language conformance belongs to the frontend that owns the language.** The official WebAssembly spec test suite — vendored, pinned, allowlisted, driven through the full pipeline and judged by a bit-pattern/NaN-class oracle — lives in **scribbler** (scribbler repo), which is also where the JS-via-Porffor corpus lives. carder's CI contains none of it, by design: no wabt, no wast2json, no vendored testsuite. That absence is a structural check that no source language leaked back in.

**What carder proves about itself, without any frontend:**
- **A checked-in `.ir` corpus.** carder's end-to-end suite is driven from `test/carder/ir/corpus/*.ir` (35 programs) with spec-sourced `.expected` values copied verbatim from where they were originally measured. It was measured at the split that `wasm → .beam` is **byte-identical** to `wasm → .ir → .beam` for all 32 corpus programs that came from wasm, so the proofs the corpus carries are unchanged by the extraction.
- **IR-level freezes and golden files.** Because the IR has a textual form (§3) and every stage is independently invokable, each stage is testable in isolation — feed `.ir`, dump `.ir`, diff; golden `.core` at the backend boundary; dedicated pretty-printer unit tests.
- **Optimizer differentials.** Every corpus program must produce identical results under `OptNone ≡ Baseline ≡ Aggressive`; the memory optimizer's passes are additionally proven against the `rebuild` memory oracle.
- **The tier/strategy matrix.** Identical results under every shipped `(state_strategy × mem_tier [× table_tier])` binding, plus the tier-N differential and the C-bounds fuzz that make the NIF's bounds check a *tested* trust boundary.
- **Interface-conformance suites.** Every implementation of an interface passes one shared suite for that interface (the `rebuild` memory oracle and the `bif` numerics are the references the optimized/native impls are differentially tested against). "Done" = passes the interface suite, not "compiles."
- **The `--link` capstone.** A linked artifact must run on a **bare OTP node** with no carder in the code path — the strongest single statement that the generated code plus its runtime closure is self-contained.

**Swarm angle:** per-interface suites, the corpus matrix, and (in the frontend repos) the spec suites are all embarrassingly parallel — partition across agents.

---

## 12. Scope, proposals, non-goals
- **Frontend scope is the frontend's.** The WASM phasing that got us here (Phase 1 — WASM 1.0 + multi-value + sign-extension + non-trapping float-to-int; Phase 2 — bulk memory, reference types, `memory64`, multiple memories, tail calls, SIMD; Phase 3 / separate — exception handling, GC, stack switching, component model) is history that happened in this repo and **now continues in scribbler**; its open items are scribbler's roadmap. carder's half of any remaining proposal is only what the IR or the runtime must grow ([`02-roadmap.md`](02-roadmap.md) §B).
- **WASI** is just a host namespace — a `link.Provider.Namespace` supplied by a frontend or an embedder — deliberately **out of core**. The browser DOM is out of scope entirely.
- **Hard non-goal: WASM threads / shared memory.** Every memory tier is single-threaded / process-local by design; cross-process shared mutable memory conflicts with one-instance-one-process and with the preemptive per-process model. Single-threaded across all tiers and modes.
- **Hard non-goal: any source-language knowledge in this repo** (§8.4). No decoder, no parser, no language runtime, no host module named after a producer toolchain.
- **Frontend roadmap:** WASM (scribbler, shipped) → Rust-via-WASM (falls out) → JS-via-Porffor (goal reached, bounded by Porffor) → JS-native (arc) → Erlang/Gleam (later, own repo).

---

## 13. Work breakdown (interface-first, platform-shaped)

*Historical, and still the shape of the work.* Wave 0 defined every interface first, which is what made the frontends separable at all.

**Wave 0 — define every interface (done first; unblocked all parallel work).**
- The IR: `ir` module + the **`.ir` textual reader/writer** (the platform's keystone — frontends and middle-end both depend on it; built first).
- Frontend contracts: the IR contract itself, now published as [`FRONTEND-API.md`](FRONTEND-API.md) (the internal stage design of any given frontend belongs to its repo).
- Middle-end: `ir_opt`, `ir_lower` (stdlib + capability + metering).
- Backend: `emit_core` (+ config sub-axes), `build_beam`.
- Runtime behaviours: `rt_num`, `rt_trap`, `rt_state`, `rt_host`, `link`, `rt_meter`, `rt_stdlib`, `rt_bif`, `rt_mem`, `rt_table`, `rt_instance`.
- **W0-scaffold:** Gleam project, `compile`/`file` FFI shim, build driver.

**Then each cell is an independent work item** (definition of done = its conformance suite):
- **IR:** core types; `.ir` parser/printer; round-trip tests.
- **Optimizer:** `baseline`; `aggressive` (trust-assuming passes flagged Unsafe-only); the memory optimizer.
- **Stdlib + capability lowering (`ir_lower`):** stdlib resolution; BIF allowlist enforcement; metering insertion.
- **Backend:** Core AST + **pretty-printer** (own tests); `state_strategy` threaded/cell; `cerl_ast` alt; `forms`/`file` drivers; `--link` packaging; typed bindings emitters.
- **Shared runtime:** `rt_num` `bif` (+ property tests) and `nif`; `rt_trap` `error`; `rt_state` `threaded`/`pdict`; `rt_host` `deny_all`/`whitelist`/`open`; `link` providers incl. frontend-supplied `Namespace`; `rt_meter` `none`/`fuel`; **`rt_stdlib` `own`/`passthrough`**; **`rt_bif` `allowlist`/`open`**.
- **Linear-memory subsystem:** `rt_mem` `rebuild`→`paged`→`atomics`→`nif`; `rt_table` `map`/`ets`/`atomics`.
- **Linker:** `rt_instance`/`profiles` + the named **Safe/Unsafe** profiles + `cli.resolve_binding`.
- **Stdlib library:** the in-house IR-level stdlib.
- **Correctness:** the `.ir` corpus + optimizer differentials + the tier matrix + per-interface suites (§11). *Partitionable across many agents.* Source-language conformance suites live in the frontend repos.
- **CLI/API:** drive any stage independently — `run`, `ir-lower`, `opt`, `emit`, `to-core`, `to-erl`, `to-beam`/`build` (with `--link` and `--bindings`), `exec` — per decision #5, plus `carder/embed` for embedders and `carder/cli` for the frontends' own binaries.

**Critical path to first end-to-end (historical, WASM):** Wave-0 (esp. `ir` + `.ir`) → decode → validate → stack-elim → structure→IR (all four now scribbler's) → `ir_lower` (Safe defaults) → `emit_core` + printer → `forms` driver → `paged` memory + `threaded` state + `bif` numerics + `deny_all` host + `own` stdlib. Everything else landed in parallel.

---

## 14. Summary for the next agent

carder is, in **Gleam**, the **backend of a multi-frontend compiler platform**: it takes **one shared, language-neutral IR (ours)** and emits **Core Erlang**, so code runs **fast and preemptively on the BEAM** — compiled, not interpreted. **Frontends are separate repos** — `scribbler` (WebAssembly, and with it Rust-via-WASM and JS-via-Porffor), `arc` (JavaScript), an Erlang/Gleam frontend later — and each reaches carder through exactly three seams (§8.4): `pipeline.compile_ir`/`run_ir` (and `carder/embed`) to compile and run, `profiles.direct(DirectHost)` to bind a language runtime behind `call_host`, and `link.Provider.Namespace` to supply host modules carder has deliberately never heard of. **Source-language knowledge never enters this repo** — that rule is what makes the platform multi-frontend, and the 2026-08 extraction of the WASM frontend without a single IR change is the evidence it held.

The decisions locked at the start still bind: the **IR is language-neutral** (no WASM-isms in its core) with **linear memory as an optional feature**, **structured control flow** (no goto), a **dual value model** (BEAM-native terms + opt-in fixed-width/linear-memory) with explicit conversions, **every stage independently invokable with a canonical `.ir` textual form**, **`call_host` as the single capability boundary**, the **standard library defined at the IR level** (Gleam-style minimal-builtin, identical across frontends), and **Safe/Unsafe as global modes** — Unsafe emits the fastest possible near-native code (stdlib passthrough, full BIFs, tier-O/N runtime, no metering), Safe sandboxes (own vetted stdlib + a tiny BEAM-function allowlist, deny-all host, tier-P/O only — never NIFs, metering on), with `carder/cli.resolve_binding` as the one gate every binary imports rather than forks. The backend is the proven structured-control→`letrec`+tail-call lowering (loops = constant-space, preemptible BEAM iteration), with numerics routed through `rt_num` (exact two's-complement/IEEE/NaN/trap **fidelity invariants**) and memory through the **canonical tiered `rt_mem`** (`paged` pure default / `atomics` O(1) process-local / `nif` ceiling, never-in-Safe), all behind interfaces validated by **interface-conformance suites**, a checked-in `.ir` corpus, optimizer differentials, the tier matrix, and the `--link` bare-node capstone. Compiling to Erlang (not a long-running NIF) is what preserves BEAM preemption; tier-N native code stays per-operation. Threads/shared memory is a hard non-goal, and so is any source language in this tree.
