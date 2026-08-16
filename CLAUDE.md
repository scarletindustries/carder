# carder

The compiler **backend**: a shared, language-neutral IR lowered to Core Erlang and compiled to
loadable `.beam` modules, plus the BEAM runtime the emitted code calls into.

A Gleam project (targets Erlang/BEAM by default). Built and tested with the standard Gleam
toolchain — **Gleam 1.16+**, Erlang/OTP, and `gleeunit` for tests.

## carder is the backend — frontends live elsewhere

carder does **not** know any source language. A frontend owns its source format, lowers it into
`carder/ir`, and calls carder's public API. Frontends live in their own repos and depend on this
one as an ordinary Gleam package:

| frontend | source | repo |
|---|---|---|
| scribbler | WebAssembly | `scarletindustries/scribbler` |
| arc | JavaScript | `alii/arc` |

**Never add source-language knowledge to this repo.** No wasm binary/text format, no JS syntax,
no producer-toolchain shim (TeaVM, Porffor), no source-language conformance suite. If a task
seems to need one, the right change is almost always a more general seam here plus the specific
knowledge in the frontend — the existing examples are `link.Provider.Namespace` (a frontend
supplies a host module carder has never heard of) and `instance.DirectHost` (a frontend supplies
its own runtime op table).

The frontend-facing contract is [`specs/FRONTEND-API.md`](specs/FRONTEND-API.md); the shared CLI
vocabulary every frontend binary imports is `src/carder/cli.gleam`. Both are public API — a
breaking change to either breaks every frontend, with no deprecation window.

---

## Definition of Done

A change is **not done** until all of the following hold. Treat this as a hard gate, not a checklist to skim.

### 1. Tests pass and new code is tested

- **Always run the existing tests** before and after a change: `gleam test`. A change that breaks existing tests is not done.
- **Always write tests for new code.** Every new public function or behavior gets test coverage.
- **Write objective tests against the spec, not the implementation.** Do *not* write tests that merely lock in whatever the current code happens to output (change-detector tests). Go back to the **original specification** for the behavior — for Core Erlang and the BEAM that means the [Core Erlang specification](https://www.erlang.org/doc/apps/compiler/) and the Erlang/OTP docs, for the IR's own semantics [`specs/FRONTEND-API.md`](specs/FRONTEND-API.md) and the IR grammar, for anything else the relevant RFC/standard/design doc — and assert what the spec says *should* happen. If a test and the spec disagree, the spec wins and the code is wrong.
- **Test inputs are `.ir`, not source.** There is no frontend in this repo, so an end-to-end test starts from a `.ir` file (`test/carder/ir/corpus/*.ir`, with its spec-sourced `.expected` values alongside) or from a hand-built `ir.Module` (`test/carder/milestone0_test.gleam` is the model). Never reach for a `.wasm`.
- When a bug is found, first add a failing test that encodes the correct (spec-defined) behavior, then fix the code until it passes.

### 2. Every function is documented for the next agent

- **Always write documentation comments** so a future agent can understand the code without reading the body. Documentation is research speed for whoever comes next — invest in it.
- Document the **contract**, not a restatement of the name. For each public function describe:
  - **What** it does (the intent / invariant it upholds).
  - **Parameters** — meaning, units, accepted ranges, and any assumptions.
  - **Return value** — including the semantics of `Result(a, e)` / `Option(a)`: what `Ok`/`Error`/`Some`/`None` each mean here.
  - **Failure modes** — what inputs produce `Error`, and anything that can panic (`let assert`, `panic`, partial functions).
- Use Gleam doc comments:
  - `////` — module-level docs at the top of a file (what this module is for).
  - `///` — documentation for the function / type / constant that immediately follows. These render in `gleam docs` and show in editor hovers.
  - `//` — ordinary inline comment (not documentation).

```gleam
/// Compile a `CModule` to an in-memory `.beam` binary WITHOUT loading it: lower to Erlang
/// Abstract Format and compile in-process via `compile:forms/2`.
///
/// Returns `Ok(beam_bytes)`, or `Error(BuildFailed(diagnostics))` carrying the compiler's
/// messages if the forms are rejected. Total — a malformed module becomes `Error`, never a
/// panic. `cmod.name` is the atom baked into the binary; the caller owns its uniqueness,
/// because loading two modules under one atom silently replaces the first.
pub fn cmod_to_beam(cmod: CModule) -> Result(BitArray, PipelineError) {
  // ...
}
```

### 3. Formatting and build are clean

- **Always run `gleam format`.** CI runs `gleam format --check src test` and **will fail the build if the code is not formatted** — so format before every commit and never push unformatted code.
- `gleam build` compiles with no warnings.

---

## Commands

| Task | Command |
|------|---------|
| Install/resolve deps | `gleam deps download` |
| Build | `gleam build` |
| Run the entry point | `gleam run` |
| Run all tests | `gleam test` |
| Format code | `gleam format` |
| Check formatting (CI) | `gleam format --check src test` |
| Generate HTML docs | `gleam docs build` |

The typical inner loop: **edit → `gleam format` → `gleam test`**.

---

## Project layout & conventions

- Entry point: `src/carder.gleam` (`pub fn main`) — the IR-entry CLI (`run`, `ir-lower`, `opt`, `emit`, `to-core`, `to-erl`, `to-beam`/`build`, `exec`, `help`).
- Add new modules under `src/carder/` and import them as `import carder/<module>` (e.g. `src/carder/decoder.gleam` → `import carder/decoder`).
- Layers, outermost first: `carder/ir*` (the IR + its text form) → `carder/middle/**` (policy pass + optimizer) → `carder/backend/**` (Core Erlang, linking, bindings) → `carder/runtime/**` (what the emitted code calls at run time). `test/carder/middle/link_layer_freeze_test.gleam` enforces that `runtime/**` imports none of the others.
- Every Erlang FFI file must be named `carder_*_ffi.erl`. BEAM module names are one flat global atom namespace with no package scoping, so an unprefixed `.erl` can be silently shadowed by a consumer package's file of the same name — **no compiler error and no warning**. CI greps for this.
- Tests live under `test/`, mirroring the `src/` layout. `gleeunit` auto-discovers every function whose name ends in `_test`. Run a focused module with `gleam test -- <module>`.
- This is a **Gleam** codebase — ignore any parent-directory JavaScript/Bun guidance; it does not apply here. To target JavaScript instead of Erlang, set `target = "javascript"` in `gleam.toml`.
- Prefer total functions returning `Result`/`Option` over partial functions; reserve `let assert`/`panic` for genuinely-impossible states and document them when used.

---

## Commits & pull requests

- **Never Claude-brand commits or PRs.** Do **not** add `Co-Authored-By: Claude ...` trailers to commit messages, and do **not** add "Generated with Claude Code" (or any similar attribution) to PR bodies or commit messages.
- Write commit messages describing the change and its intent, as a human author would.
- **Commit frequently.** Each commit should be a single logical unit of work — small, self-contained, and independently reviewable. Prefer many focused commits over one large one, to make review easier.
- Only commit or push when explicitly asked. If on `main`, branch first.
