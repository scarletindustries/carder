# test262 conformance harness for the 2core JS compiler

Runs a scoped slice of [tc39/test262](https://github.com/tc39/test262) through the
2core JavaScript frontend (`src/twocore/frontend/js`) to measure ECMAScript
conformance and surface the highest-value bugs and feature gaps.

> **Not official conformance.** The real test262 harness (`assert.js` / `sta.js`)
> attaches properties to function objects, uses `new` on plain functions, and does
> value-based `instanceof` — none of which this compiler supports yet, so the
> official harness cannot even load. `runner.erl` instead prepends a **shim
> harness** of plain top-level functions and rewrites `assert.sameValue(` →
> `assertSameValue(` (etc.) in each test body, then compiles and runs the body.
> This measures **positive feature correctness** on the areas we implement — the
> useful signal for driving the compiler forward. Making the official harness run
> is its own project (functions-as-objects + plain-function `new` + value-based
> `instanceof`).

## Setup

```sh
bash test262/fetch.sh      # clone/update ~54k tests into test262/suite (gitignored)
gleam build                # runner loads build/dev/erlang/*/ebin
```

## Run

From the repo root, pass the suite root then one or more directories under it:

```sh
escript test262/runner.erl test262/suite test/built-ins/Math
escript test262/runner.erl test262/suite test/built-ins/Array/prototype test/language/expressions/addition
```

It prints a per-outcome tally, an overall pass rate, and a **per-area table sorted
by fixable failures** (the areas with the most reachable work). Per-file failure
detail (with the compiler's error message) is written to `$T262_DETAIL`
(default `/tmp/t262_detail.txt`) — read it to see exactly what to fix.

## Outcome buckets

| bucket | meaning |
|---|---|
| `pass` | compiled, ran, all assertions held |
| `fail_assert` | ran but produced a wrong value — a real correctness bug |
| `runtime_error` | crashed while running (badarith, type error, …) — a real bug |
| `compile_unsupported` | a clean `unsupported: …` — a feature gap (the message names it) |
| `compile_backend` / `compile_other` | a backend/emit crash — a real bug, not a graceful error |
| `skip_flag` / `skip_include` / `skip_negative` | needs module/raw/async/onlyStrict, a harness include we don't shim, or is a negative test — not counted as run |

The loop this feeds is captured in the `test262-conformance` skill.
