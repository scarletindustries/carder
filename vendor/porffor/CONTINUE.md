# CONTINUE HERE — self-hosting Porffor (kickstart for the next agent)

You are picking up an in-progress effort. **Read this whole file first**, then `FINDINGS.md` and
`README.md` (same dir). This file is written to be fully self-contained — you should not need any
prior conversation context.

## The mission (one paragraph)

2core is a Gleam→Core-Erlang WebAssembly engine (Phases 1–7 complete, on `main`). The goal here is
**"JS on the BEAM with no JS runtime on the user's machine"**: compile Porffor (a JS→Wasm compiler
*written in JS*) *with Porffor* into a `porffor.wasm`, run **that** on 2core → `porffor.beam`, then a
thin `fe_js` frontend does `JS source → porffor.beam (in-BEAM) → Wasm bytes → the existing fe_wasm
frontend → IR → Core Erlang → BEAM`. CLI dispatches by extension: `.wasm`→fe_wasm, `.js`→fe_js. **All
compilation stays in-BEAM.** Porffor cannot self-host out of the box; we vendor + patch + codemod it
in `vendor/porffor/` until it self-compiles into a *working* wasm. **Do NOT contact the upstream
Porffor project — this is our own out-of-scope experiment.**

## Current state — the progress ladder

`won't-validate → [validate] GREEN → memory-trap → parser-runs → empty-string(FIXED) →
wide-regex-init(FIXED) → func-.prototype/func-lut(FIXED) → **missing-builtins+globalThis+optional-call (HERE)** → [run] GREEN → integrate`

Init now advances from statement ~54 to **~470** (of 733). Fixed since the last handoff:

- ✅ **`Regex parse: Invalid flag`** — NOT a flag bug: `makeString` returns null ptr 0 for `''`, which
  reads garbage at address 0 at bundle scale. Fixed → reserved zero slot. FINDINGS §6.
- ✅ **`TypeError: Invalid regular expression`** — acorn's wide-utf16 identifier regexes made lazy
  (Porffor regex engine is bytestring-only). FINDINGS §6b.
- ✅ **function `.prototype` is `undefined`** — the **func lut**, two bugs: (A) it's capped at 2 pages so
  `bytesPerFuncLut` drops below the 7-byte min entry past ~4681 indirect funcs, corrupting the `constr`
  flag → grown to 16 pages; (B) a self-hosting-only **collision**: the bundle contains the string literal
  `'#func lut'`, which interns into `pages.allocs` and shadows the func-lut *page* offset → the lut is
  written to the wrong place and all func-lut reads return 0 → pinned to an explicit page offset. Both in
  `scripts/porffor-codegen-fixes.sh`. FINDINGS §7.
- ✅ **`.replace` missing / `process` undefined / `globalThis.X` not readable bare** — `apply-patches.sh`
  #8 rewrites acorn's `wordsRegexp` `.replace(/ /g,"|")` → `.split(" ").join("|")`; `codemod.mjs`
  prepends a `process` stub and rewrites `globalThis.X` → bare `X` (+declares vars). FINDINGS §8.
- ⛔ **CURRENT BUG:** `[run]` dies in init at `types2 = … || file2?.endsWith(".ts")`. With `file2`
  undefined, `file2?.endsWith(".ts")` should short-circuit to `undefined`, but Porffor **calls
  `endsWith` on undefined** → `TypeError: undefined is not a function`. Porffor's optional-chain
  `a?.b(args)` short-circuits the member access but NOT the call (reproduces natively:
  `var u; u?.endsWith(".ts")`). Next: fix Porffor's optional-call codegen, OR codemod
  `X?.m(a)` → `X == null ? undefined : X.m(a)`. Then the next semantic bug surfaces — keep going with the
  `diagnostics/` loop. Full detail: **FINDINGS §8.**

## Reproduce in 2 commands

```bash
cd /Users/scotthiett/IdeaProjects/wasm2core/vendor/porffor
./build.sh            # pristine upstream --patch(incl. empty-string+lazy-regex)--> esbuild@esnext --codemod--> dist/porffor.compiler.js
                      #   Node sanity should print: probe_len=NNNNN magic_ok=true   (pure compiler works)
./selfhost-check.sh   # patches the build tool (patch-build-tool.sh), compiles WITH Porffor -> dist/porffor.wasm, then [validate] + [run]
                      #   expect: [validate] GREEN, [run] RED (RangeError: Invalid typed array length — the func-.prototype wall, FINDINGS §7)
```

**Fast localization of the current bug (no 10 s bundle rebuild):**
```bash
node diagnostics/scale-test.mjs 8000 > /tmp/s.js && npx porffor run --module /tmp/s.js   # -> TypeError: Cannot set property of undefined
node diagnostics/scale-test.mjs 6000 > /tmp/s.js && npx porffor run --module /tmp/s.js   # -> proto_object=true (works)
```
Then bisect the threshold and find the Porffor constant it maps to. See `diagnostics/DIAGNOSTICS.md`.

## Environment & tools (important — some are non-obvious)

- **Porffor**: `npx porffor …` (v0.61.13, latest; auto-installs). Subcommands you'll use:
  - `npx porffor wasm --module <in.js> <out.wasm>` — compile JS→wasm to a file.
  - `npx porffor wasm -d --module <in.js> <out.wasm>` — `-d` adds **function NAMES** to the wasm (use
    with `wasm-tools print` to map a failing func index → source name).
  - `npx porffor run --module <in.js>` — compile AND run (in V8, with Porffor's proper runtime/memory).
  - Porffor install dir (for grepping its source): `` PORF=$(find ~/.npm -maxdepth 6 -type d -name porffor | head -1) ``
    (currently `/Users/scotthiett/.npm/_npx/*/node_modules/porffor`). acorn: `$PORF/../../node_modules/acorn`.
- **wasm-tools**: `wasm-tools validate --features=all <wasm>` and `wasm-tools print <wasm>`.
  ⚠️ **ALWAYS pass `--features=all`** — Porffor emits *legacy* exception handling (`try 0x06`/`catch
  0x07`), which default `validate` rejects → **false "func N failed" alarms** (this cost me an hour;
  the real blocker `generateCall` fails *with* `--features=all` too, the false ones don't).
- **esbuild**: `npx --yes esbuild <entry> --bundle --format=esm --platform=neutral --target=esnext
  --outfile=<out>`. ⚠️ **ALWAYS `--target=esnext`** — the neutral default *downlevels* `?.`/`??` into
  ternaries, which (a) changes what Porffor compiles and (b) **erases syntactic codemod fixes**.
- **@babel/core**: needed by `codemod.mjs`; `build.sh` installs it into `vendor/porffor/node_modules`
  on demand (gitignored, build-time only).
- **No `timeout` command.** Use `perl -e 'alarm N; exec @ARGV' <cmd> <args...>` as the timeout wrapper.
- node / npm / npx / bun are all available. A full `porf wasm` of the 2.5 MB bundle takes ~10 s.

## What's in `vendor/porffor/` (all committed on `main`)

```
upstream/                 PRISTINE Porffor 0.61.13 compiler/*.js + node_modules/acorn + LICENSE — DO NOT EDIT.
                          Patches are applied to a COPY by build.sh (keeps upstream diffable across updates).
src/entry.js              the pure compileJS(code) entry (imports ../upstream/compiler; no fs/Node).
scripts/apply-patches.sh  the 7 patches (see below). Idempotent; run against a working copy.
scripts/patch-build-tool.sh  applies the codegen fixes to the npx porffor TOOL (see FINDINGS §7b two-copies).
codemod.mjs               POST-esbuild @babel/core transforms. Extend this as you find new constructs.
build.sh                  the pipeline. selfhost-check.sh  the RED/GREEN gate. bisect.sh  the localizer.
diagnostics/              instrument-init.mjs / instrument-sites.mjs / scale-test.mjs + DIAGNOSTICS.md
                          (the tools that found §6/§7 — USE THESE for the next `[run]` bug).
README.md  FINDINGS.md    the runbook + the full debugging record (READ BOTH).
dist/                     build artifacts (gitignored, regenerated).
```

## Everything already found & fixed

1. **The pure compiler extracts cleanly.** `compiler/index.js` default-exports `(code, module) => out`
   where `out.wasm` is the assembled bytes. The Node coupling is only in CLI output paths a pure
   `compile(code)` never reaches.
2. **Strip patches** (in `apply-patches.sh`, applied to a working copy): `index.js` `node:fs`→`undefined`,
   `execSync`→`undefined`, `import toc from './2c.js'` (direct-`eval`)→`() => ''`; `wrap.js` `node:fs`→
   `undefined`.
3. **acorn-static patch** (patch #5): `parse.js` loads the parser via a *dynamic computed* import
   `await import((globalThis.document ? 'https://esm.sh/' : '') + parser)` which esbuild leaves EXTERNAL
   → Porffor stubs the parser → the OOB trap. The patch forces `import * as _acorn2core from 'acorn'`.
   **This is why acorn is now inlined and the parser runs.**
4. **esbuild `--target=esnext`** (in build.sh) — keep `?.`/`??` for Porffor + the codemod.
5. **The validation blocker + codemod**: `generateCall` in `codegen.js` (lines ~2230–2765) is the SOLE
   function that failed `--features=all` validation, via a **double-optional `?.length`**:
   `func?.returns?.length === 0` (2 occurrences, lines ~2750–2751). Porffor's `.length` is i32; the
   double-optional short-circuit branch is f64 (undefined) → `type mismatch: expected i32, found f64`.
   `codemod.mjs` rewrites `<optional-chain>?.length` → `((_oc)=>_oc==null?undefined:_oc.length)(<base>)`
   (single-eval, structurally different so esbuild can't fold it back). → `[validate]` GREEN.
   - ⚠️ **esbuild NORMALIZES parenthesization** — `(a?.b)?.length` collapses to `a?.b?.length` (same
     AST). So the codemod MUST run post-esbuild AND emit a structurally-different form (temp/IIFE/guard),
     NOT parens.
6. **acorn wide-regex lazy** (patch #6): `nonASCIIidentifierStart`/`nonASCIIidentifier` eager
   `new RegExp("[…wide utf16…]")` → made lazy; Porffor's regex engine is bytestring-only. FINDINGS §6b.
7. **empty-string null-pointer fix** (patch #7 + `patch-build-tool.sh`): `makeString('')` returned the
   null pointer `0`; reading `''` at address 0 gave garbage at bundle scale → the "Invalid flag" wall.
   Now points `''` at a reserved zero slot. **This is the fix that cleared "Invalid flag".** FINDINGS §6.
   - ⚠️ Codegen fixes must go in BOTH the vendored compiler (patch #7) AND the npx tool
     (`patch-build-tool.sh`, run by `selfhost-check.sh`). See FINDINGS §7b.

## THE CURRENT BUG — function `.prototype` is `undefined` at scale (your target)

- **Symptom:** `./selfhost-check.sh` → `[run] RED (RangeError: Invalid typed array length: 1939865600)`.
  That RangeError is a **red herring** — Porffor's `porffor run` glue crashes converting the *real*
  thrown error (a `TypeError` whose message is itself garbled). See the `wrap.js read()` clamp trick in
  `diagnostics/DIAGNOSTICS.md` to unmask it.
- **Real fault:** module init throws at acorn's FIRST `X.prototype.method = …` assignment
  (`Position.prototype.offset = …`) because **`Position.prototype === undefined`** (while
  `typeof Position === "function"`). This breaks every prototype-based class → all of acorn.
- **Measured:** it is **scale-dependent, driven by total function count.** The exact `Position` pattern,
  and 6000 dummy indirect functions + a constructor, WORK in isolation; **≥ 8000 functions reproduces
  `TypeError: Cannot set property of undefined`**. The bundle has **11692 functions / 5588 indirect**.
  `--page-size` changes don't help (they trade it for `memory access out of bounds`).

**Recipe to attack it (FAST loop — no 10 s bundle rebuild):**
1. Reproduce + bisect the threshold with `diagnostics/scale-test.mjs <N>` (6000 works, 8000 fails);
   narrow N and note whether the threshold is a round/`2^k` number or ties to `bytesPerFuncLut`.
2. Find how a **user function's `.prototype` is materialized/looked-up at runtime** in Porffor's
   `compiler/codegen.js` — trace the `funcRef` → prototype path and `__Porffor_object_setPrototype`;
   and the func-lut sizing `bytesPerFuncLut = min(⌊pageSize·2 / nIndirect⌋, maxNameLen+8)` (shrinks with
   more indirect funcs). The overflowing constant/region is the fix target.
3. Fix it in BOTH Porffor copies (patch the vendored compiler via `apply-patches.sh`, and the tool via
   `patch-build-tool.sh`). Rebuild + re-check.
4. When `[run]` clears, the NEXT semantic bug (if any) surfaces — repeat with the `diagnostics/` tools.
   This is a **sequence of semantic self-compile bugs**; that's why upstream self-hosting is unsolved.
   Keep going until `[run]` prints `probe_len=…`. Full detail: **FINDINGS §7.**

## The bisection method (how the `generateCall` construct was found — reuse it)

To localize a construct in a failing function `F` (source lines `[a..b]`):
1. Compute `F`'s **brace-balanced statement boundaries** (running `{`-minus-`}` depth back to 0).
2. For boundary `K`: rebuild with `F`'s body = `lines[a..K] + 'return [];'`, re-bundle (`--target=esnext`),
   `porffor wasm`, `wasm-tools validate --features=all`.
3. Binary-search `K`: VALID ⇒ bug after `K`; INVALID ⇒ at/before `K`. **Only trust brace-balanced `K`**
   — an unbalanced cut is a *build* failure (esbuild errors), not an invalid wasm; distinguish them.
4. Once at a statement, swap sub-expressions to isolate the trigger; confirm with a minimal repro.
`./bisect.sh whichfn` automates naming the first `--features=all`-failing function. For **runtime**
(post-validate) bugs there's no validator — localize by *behaviour*: shrink the input (`''`/`1`),
stub suspected functions to `return`, or `-d` + trap-trace.

## Gotchas that cost me time (don't repeat)

- `wasm-tools validate` WITHOUT `--features=all` → false failures (legacy EH). Also it flagged
  `_normalizeTimeZoneId` — a red herring (it uses `try/catch`); the real one is `generateCall`.
- esbuild normalizes parens (see §5 above) AND downlevels `?.`/`??` without `--target=esnext`.
- **"Porffor compiled it (exit 0)" ≠ "it works."** Porffor silently STUBS things it can't
  handle (unresolved dynamic imports, unsupported ops) → valid-looking but DEAD wasm. Always check it
  actually RUNS (`[run]`), not just validates.
- `porffor run` uses V8 (supports EH, lenient); `wasm-tools validate --features=all` is stricter. Use
  both — V8 caught the branch-arity bug, wasm-tools pinned the type mismatch.

## The end-game — integration once `[run]` is GREEN

When `dist/porffor.wasm` compiles JS correctly, do this (all in-BEAM):
1. **ABI:** `entry.js` currently hardcodes the input + prints a length. For real use, the wasm must
   accept a **JS source string** and return the **Wasm bytes**. Options: export a
   `compileJS(srcPtr, srcLen) -> (outPtr, outLen)` shim from the bundle (write the source into the
   wasm's linear memory, read the byte array out), OR drive it through Porffor's `(f64, i32)` value
   ABI. See `src/twocore/runtime/porffor_abi.gleam` in the main project — it already decodes Porffor
   `(f64,i32)` values + console output (Phase 7); extend it to *encode a string arg* + *decode a
   Uint8Array/bytes result*.
2. **porffor.wasm → porffor.beam:** run `dist/porffor.wasm` through 2core's own pipeline
   (`src/twocore/pipeline.gleam`: decode→validate→lower→emit→build_beam). Note the self-hosted
   porffor.wasm uses **legacy EH (try/catch)** — 2core's **Phase 7** handles exactly that — plus SIMD,
   bulk memory, call_indirect, multi-value, all already supported (Phases 1–6). So 2core CAN compile it.
   Commit `porffor.beam` (or generate it in a build step).
3. **fe_js frontend:** a new `src/twocore/frontend/js/…` (or reuse the porffor shim): `JS string →
   porffor.beam.compileJS (in-BEAM) → Wasm bytes → the existing fe_wasm decode→…→emit → BEAM`.
4. **CLI dispatch** (`src/twocore.gleam`): pick the frontend by extension — `.wasm` → fe_wasm; `.js` →
   fe_js. All compilation in-BEAM, no Node/JS runtime at runtime.

## Rules / conventions

- Keep `upstream/` PRISTINE; all edits go through `apply-patches.sh` (so a Porffor update is a clean
  re-vendor + re-verify — see the "Updating Porffor" prompt in README.md).
- Codemod fixes go in `codemod.mjs` (post-esbuild, structurally-different, verified vs `node`).
- 2core repo rules (CLAUDE.md): no Claude branding in commits/PRs; commit frequently, small logical
  units; the repo is Gleam — `gleam format`/`gleam build`/`gleam test` for any *main-project* code;
  `vendor/` is a separate JS subtree that doesn't affect the Gleam build. Commit + push to `main`
  after each unit of progress. Update `FINDINGS.md`/`README.md` status as you go.
- Don't commit `dist/` or babel `node_modules` (already gitignored).

**Start now:** `cd vendor/porffor && ./build.sh && ./selfhost-check.sh`, watch it go RED on the regex
flag, then work the "attack it" recipe above.
