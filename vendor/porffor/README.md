# `vendor/porffor` — self-hosting Porffor for an in-BEAM JS frontend

> 🚧 **Work in progress. If you are continuing this effort, read [`CONTINUE.md`](CONTINUE.md) FIRST**
> — it is a full, self-contained kickstart (current state, the reproduce loop, every fix so far, the
> gotchas, the current bug + how to attack it, and the end-game integration plan).

**Goal.** Turn [Porffor](https://github.com/CanadaHonk/porffor) (a JS→Wasm compiler *written in JS*)
into a **pure, Node-free `compileJS(code) → wasmBytes` function**, compile *that* with Porffor to
`porffor.wasm`, and run it on 2core's Wasm engine → `porffor.beam`. Result: `2core compile foo.js`
with the JS→Wasm step happening **entirely in-BEAM** — no JS runtime on the user's machine.

> ⚠️ **This is out of scope for the upstream Porffor project — it is our own experiment. Do NOT open
> issues / PRs upstream about self-hosting failures found here.** We vendor Porffor so we can patch
> and mess around freely without bothering them. Pinned version + provenance: [`UPSTREAM_VERSION.txt`](UPSTREAM_VERSION.txt).

## Layout

```
upstream/              pristine vendored Porffor compiler (compiler/*.js) + node_modules/acorn — DO NOT edit
src/entry.js           the pure compileJS(code) entry (no fs, no Node)
scripts/apply-patches.sh   strips node:fs / execSync / 2c-eval from a WORKING COPY (upstream stays clean)
codemod.mjs            POST-esbuild @babel/core transforms rewriting constructs Porffor self-miscompiles
build.sh               upstream --(patch)--> esbuild@esnext --(codemod)--> dist/porffor.compiler.js
selfhost-check.sh      compiles the bundle WITH Porffor -> validates -> runs; the RED/GREEN gate
bisect.sh              localizes which function/construct Porffor miscompiles
FINDINGS.md            the debugging record + current status of each checkpoint
dist/                  build artifacts (gitignored)
```

## The pipeline

```
upstream/compiler + acorn
   │  scripts/apply-patches.sh   (strip node:fs / execSync / 2c.js eval — all CLI-only, never in pure compile)
   ▼
   │  esbuild --bundle --target=esnext   (inline acorn + everything; KEEP ?./?? — Porffor supports them,
   │                                       and downleveling erases the codemod's structural fixes)
   ▼
   │  codemod.mjs   (rewrite Porffor-miscompiled constructs into equivalent forms — see FINDINGS.md)
   ▼
dist/porffor.compiler.js   →   [Porffor]   →   dist/porffor.wasm   →   [2core]   →   porffor.beam
```

## Build & check

```bash
./build.sh            # -> dist/porffor.compiler.js (also runs a Node sanity: prints probe_len=...)
./selfhost-check.sh   # compiles it WITH Porffor, then [validate] and [run]
```

## Current status (Porffor 0.61.13) — see FINDINGS.md for detail

- **pure compiler works in Node** ✅ — `compileJS('console.log(1+2)')` → a valid Wasm binary.
- **`[validate]` GREEN** ✅ — after the codemod, the self-compiled `porffor.wasm` passes
  `wasm-tools validate --features=all`. The sole validation blocker was ONE construct in
  `codegen.js` `generateCall` (a double-optional `?.length`); `codemod.mjs` fixes it (FINDINGS §3–4).
- **parser now runs** ✅ — the initial `memory access out of bounds` trap was **acorn not being
  inlined** (a dynamic computed import esbuild left external → Porffor stubbed the parser). Patch #5
  makes acorn a static import; the trap is gone (FINDINGS §5).
- **`[run]` RED** ⛔ — now fails later with `SyntaxError: Regex parse: Invalid flag`: a *semantic*
  self-compile bug corrupting a regex flags string (all flags work in native Porffor). Narrower than
  before; the current frontier (FINDINGS §6). Downstream (porffor.beam, `fe_js`, CLI `.js` dispatch)
  is gated on `[run]` going GREEN.
- **progress ladder:** won't-validate → **validate GREEN** → memory-trap → **parser runs** → regex-flag.

## Updating Porffor — the standard prompt

Porffor is experimental and moves fast; self-hosting improves as it matures. Re-vendoring is a
routine, scripted task. **To kick off a Porffor update, hand an agent this prompt:**

> **Update the vendored Porffor in `vendor/porffor` to version `<X.Y.Z>` (or latest) and re-check
> self-hosting.** Steps: (1) `npm view porffor version` to pick the target; (2) fetch it
> (`npx porffor@<ver>`), copy its `compiler/*.js` into `vendor/porffor/upstream/compiler/` and its
> `node_modules/acorn` into `vendor/porffor/upstream/node_modules/acorn`, and update
> `UPSTREAM_VERSION.txt`. (3) Re-verify the patch surface: `scripts/apply-patches.sh` targets exactly
> the `node:fs` / `execSync` / `2c.js`-import lines — if the new version moved/renamed them, update
> the patch's match-regexes (keep the patches minimal and behaviour-neutral: they only strip CLI
> output-path Node coupling that pure `compile(code)` never reaches). (4) `./build.sh` then
> `./selfhost-check.sh`. (5) If `[validate]` is RED, run `./bisect.sh whichfn` to name the failing
> function, then narrow the construct with the bisection method in `FINDINGS.md` and add a transform
> to `codemod.mjs` (POST-esbuild, structurally-different so esbuild can't fold it back; verify the
> rewrite is semantics-preserving vs `node`). (6) If `[run]` is RED, it's a semantic self-compile bug
> — see `FINDINGS.md 'Runtime wall'`; localize by behaviour (the validator won't point at it).
> (7) Update the "Current status" section + `FINDINGS.md`. Do NOT contact the upstream Porffor project.
> When `[run]` goes GREEN, wire `porffor.wasm → porffor.beam` and the `fe_js` frontend + CLI dispatch
> (`.js → Porffor→BEAM`, `.wasm → wasm frontend`), keeping all compilation in-BEAM.
