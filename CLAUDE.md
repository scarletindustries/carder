# carder

A Gleam project (targets Erlang/BEAM by default). Built and tested with the standard Gleam toolchain — **Gleam 1.17+**, Erlang/OTP, and `gleeunit` for tests.

---

## Definition of Done

A change is **not done** until all of the following hold. Treat this as a hard gate, not a checklist to skim.

### 1. Tests pass and new code is tested

- **Always run the existing tests** before and after a change: `gleam test`. A change that breaks existing tests is not done.
- **Always write tests for new code.** Every new public function or behavior gets test coverage.
- **Write objective tests against the spec, not the implementation.** Do *not* write tests that merely lock in whatever the current code happens to output (change-detector tests). Go back to the **original specification** for the behavior — for WebAssembly semantics that means the [WebAssembly spec](https://webassembly.github.io/spec/), for any other behavior the relevant RFC/standard/design doc — and assert what the spec says *should* happen. If a test and the spec disagree, the spec wins and the code is wrong.
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
/// Decodes a single LEB128-encoded unsigned integer from `bytes`.
///
/// Returns `Ok(#(value, rest))` where `rest` is the unconsumed tail, or
/// `Error(Truncated)` if the input ends mid-number. Per the WebAssembly
/// spec, values wider than 32 bits are rejected with `Error(Overflow)`.
pub fn decode_uleb128(bytes: BitArray) -> Result(#(Int, BitArray), DecodeError) {
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

- Entry point: `src/carder.gleam` (`pub fn main`).
- Add new modules under `src/carder/` and import them as `import carder/<module>` (e.g. `src/carder/decoder.gleam` → `import carder/decoder`).
- Tests live under `test/`, mirroring the `src/` layout. `gleeunit` auto-discovers every function whose name ends in `_test`. Run a focused module with `gleam test -- <module>`.
- This is a **Gleam** codebase — ignore any parent-directory JavaScript/Bun guidance; it does not apply here. To target JavaScript instead of Erlang, set `target = "javascript"` in `gleam.toml`.
- Prefer total functions returning `Result`/`Option` over partial functions; reserve `let assert`/`panic` for genuinely-impossible states and document them when used.

---

## Commits & pull requests

- **Never Claude-brand commits or PRs.** Do **not** add `Co-Authored-By: Claude ...` trailers to commit messages, and do **not** add "Generated with Claude Code" (or any similar attribution) to PR bodies or commit messages.
- Write commit messages describing the change and its intent, as a human author would.
- **Commit frequently.** Each commit should be a single logical unit of work — small, self-contained, and independently reviewable. Prefer many focused commits over one large one, to make review easier.
- Only commit or push when explicitly asked. If on `main`, branch first.
