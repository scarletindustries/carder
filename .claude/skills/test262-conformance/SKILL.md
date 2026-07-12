---
name: test262-conformance
description: Raise the 2core JavaScript compiler's ECMAScript conformance by running tc39/test262 through it. Use when asked to improve JS/ECMAScript conformance, "run test262", measure coverage, or find and fix spec gaps/bugs in the JS frontend (src/twocore/frontend/js + the rt_js runtime). Encodes the loop: pick an issue area, run it, rank the failures, fix the highest-ROI one, add spec tests, and re-measure.
---

# test262 conformance loop

Drive the 2core JavaScript compiler toward ECMAScript conformance by running
[tc39/test262](https://github.com/tc39/test262) through it and fixing what fails.

## The honest caveat (read first)

This is **not official conformance**. The real test262 harness (`assert.js`/`sta.js`)
attaches properties to function objects, uses `new` on plain functions, and does
value-based `instanceof` — none of which this compiler supports, so the official
harness cannot even load. `test262/runner.erl` instead prepends a **shim harness**
of plain top-level functions and rewrites `assert.sameValue(` → `assertSameValue(`
(etc.) in each test body, then compiles and runs the body. So the numbers measure
**positive feature correctness on the areas we implement** — the right signal for
moving the compiler forward, but do not call it "official test262 %".

## Setup (once per machine)

```sh
bash test262/fetch.sh    # clone/update ~54k tests into test262/suite (gitignored)
gleam build              # the runner loads build/dev/erlang/*/ebin
```

## The loop

1. **Pick an issue area.** If the user named one, use it. Otherwise run a broad
   directory and read the per-area table (sorted by fixable failures) to choose:
   ```sh
   escript test262/runner.erl test262/suite test/built-ins/Array/prototype
   ```
   Prefer an area with many `fixable` failures that share ONE root cause (a single
   missing method/global, or one wrong special-value branch) — that maximizes
   tests-fixed-per-change. Avoid areas dominated by `skip_include` (they need a
   harness feature we don't have) — those aren't reachable yet.

2. **Run the area** and read the detail:
   ```sh
   escript test262/runner.erl test262/suite test/built-ins/Math/pow
   sort /tmp/t262_detail.txt | uniq -c | sort -rn | head        # rank the reasons
   grep -E '^(fail_assert|runtime_error|compile_backend|compile_other)' /tmp/t262_detail.txt
   ```
   `fail_assert` / `runtime_error` / `compile_backend` / `compile_other` are **real
   bugs** (ran-but-wrong, crashed, or the emitter panicked) — fix these first, they
   are the strongest signal. `compile_unsupported` names a missing feature in its
   message (e.g. `unsupported: Math.imul(…)`); rank them and pick the most common.

3. **Read a few of the actual failing test files** to learn the exact spec behavior
   (they cite `esid`/`es6id` and often quote the algorithm in an `info:` block).
   Write the fix against THAT behavior, not against a guess.

4. **Fix it** (see "Where fixes go" below).

5. **Add spec-driven tests** to `test/js_compiler_test.gleam` — assert what the spec
   says, mirroring the test262 case, NOT whatever the code currently emits. Use
   `num("…expr…")` for a single expression, or `compile("function f(){…}")` +
   `call(m, "f", [])` for multi-statement bodies. Assert NaN/Infinity via a boolean
   (`num("… === Infinity ? 1 : 0")`).

6. **Gate:** `gleam format && gleam test` — must be green and warning-free.

7. **Re-run the area** and confirm the number moved (this is the payoff and the
   regression check):
   ```sh
   escript test262/runner.erl test262/suite test/built-ins/Math/pow
   ```

8. **Commit** one focused change (see "Rules"). Then repeat from step 1.

## Where fixes go

- **A missing/wrong builtin** (a Math fn, an Array/String method, `Object.*`, a
  global) → the RUNTIME. Adding a `CallHost("js", op, …)` op takes **three places**:
  1. the Erlang impl + `-export` in `src/twocore_rt_js_ffi.erl`,
  2. a literal arm in `resolve_js` in `src/twocore/backend/emit_core.gleam` (the
     closed allow-list — this is the only authority surface),
  3. the `@external` in `src/twocore/runtime/rt_js.gleam`.
  Then route the call in `src/twocore/frontend/js/lower.gleam`
  (`lower_instance_method` for `x.method(…)`, `lower_static_call` /
  `math_arity` for `Namespace.fn(…)`).
- **A boolean-VALUE result** (like `Array.includes`) returns the Erlang atom
  `true`/`false`; a boolean OPERATOR/predicate returns i32 `1`/`0`. Match neighbours.
- **New syntax that reduces to existing constructs** → desugar in `lower.gleam`
  (no runtime surface). New value types → a tagged cell + ops.
- The module header of `lower.gleam` documents the supported subset and every
  deviation — read it before extending, and update it when you add a feature.

## Rules (from CLAUDE.md — hard gates)

- Always `gleam format` (CI fails on unformatted) and keep `gleam build` warning-free.
- Tests are **spec-driven**, never change-detectors: assert what the ECMAScript spec
  says; if a test and the code disagree, the spec wins and the code is wrong.
- **Never** Claude-brand commits/PRs (no `Co-Authored-By: Claude`, no "Generated with
  Claude"). Write the message as a human author, describing the change and its intent.
- Commit frequently — one focused logical change per commit. Only commit/push when
  asked; if on `main`, branch first. (The JS work lives on `experiment/js-frontend`.)

## Where NOT to waste time

- **Areas dominated by `skip_include`** (need `propertyHelper.js`, `testTypedArray.js`,
  etc.) — unreachable until the harness features exist.
- **`Object.defineProperty` / descriptors, `Symbol`, `Proxy`** — large, pervasive;
  only tackle deliberately, not as a side-quest.
- **The official-harness unlock** (functions-as-property-bearing-objects +
  plain-function `new` + value-based `instanceof`) is a real project on its own; it
  would convert this from a shim estimate into true conformance, but don't start it
  mid-loop.
- **`yield*` and `async`/`await`** — known-hard; see the `js-compiler-on-2core` memory.
