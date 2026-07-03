# Self-hosting Porffor — findings & debugging record

Everything below is **measured** against Porffor 0.61.13 + `wasm-tools` + Node 22. It is the map for
continuing the work (and for the update runbook in [README.md](README.md)).

## 1. The pure compiler is easy to extract (the user's plan works)

`compiler/index.js` already default-exports `(code, module) => out`, where **`out.wasm`** is the
assembled Wasm byte array (confirmed: `wrap.js:510` destructures `{ wasm } = compile(source, module)`).
The Node coupling is tiny and lives only in **CLI output paths** a pure `compile(code)` never reaches:

- `index.js:29` `const fs = … await import('node:fs')` — used only behind `outFile`/`Prefs.wasm`/`Prefs.native`.
- `index.js:30` `const execSync = … await import('node:child_process')` — native path only.
- `index.js` `import toc from './2c.js'` — the Wasm→C compiler; uses a direct **`eval()`** (rejected by
  both esbuild and Porffor); only reached for `native`/`c` output.
- `wrap.js:7` `const fs = …` — pulled in transitively via `pgo.js`.

`scripts/apply-patches.sh` stubs these (→ `undefined` / `() => ''`). Everything else (acorn, all of
codegen, temporal, …) is pure JS. **The bundled `compileJS` runs correctly in Node** —
`compileJS('console.log(1+2)')` → 29,169 bytes, magic `00 61 73 6d`.

## 2. esbuild must use `--target=esnext` (a subtle trap)

esbuild's `--platform=neutral` default target **downlevels `?.`/`??`** into ternaries. That (a) changes
what Porffor compiles (Porffor supports `?.` natively) and (b) **erases syntactic codemod fixes** —
`(a?.b)?.length` is the *same AST* as `a?.b?.length`, so esbuild folds the parens away. Consequences:

- always bundle with `--target=esnext` so `?.`/`??` reach Porffor + the codemod intact;
- the **codemod must run POST-esbuild** and emit **structurally-different** code (a temp/guard/IIFE),
  not a parenthesization esbuild can normalize back.

## 3. `generateCall` is the SOLE validation blocker

Compiling the bundle with Porffor produces a 24 MB `porffor.wasm` that fails
`wasm-tools validate --features=all` at **`func $generateCall`** (codegen.js) —
`type mismatch: expected i32, found f64`. (Note: validate WITHOUT `--features=all` also flags
Temporal's `_normalizeTimeZoneId` — a **false alarm**: it uses legacy `try/catch`, which validate
rejects unless legacy-exceptions is enabled. Always use `--features=all`.)

**Proof it's the sole blocker:** stub `generateCall`'s body with `return []` → the entire 24 MB
self-compiled bundle **validates clean**. Every other function self-compiles correctly.

## 4. The exact breaking construct (validation) + the fix

Bisecting `generateCall` (method in §6) localized it to two lines (codegen.js 2750/2751):

```js
func?.returns?.length === 0 || (… && importedFuncs[importedFuncs[name]]?.returns?.length === 0)
```

Minimal repro (each compiled with `porffor wasm` + `wasm-tools validate --features=all`):

| JS | validates? |
|---|---|
| `o?.a?.length` | **INVALID** ← the trigger (needs no comparison) |
| `o?.a?.b` (non-`length` prop) | VALID |
| `o.a?.length` (single optional) | VALID |
| `o?.a === 0` (single optional, no `.length`) | VALID |

**The construct: a `?.length` whose base is ITSELF an optional chain** (`X?.Y?.length`). Porffor's
`.length` yields an i32; the double-optional short-circuit branch is an f64 (undefined); the merge
mistypes. Semantics-preserving fixes (all VALID, all match `node`): parens `(X?.Y)?.length` *(but
esbuild folds it — §2)*, a guard `X?.Y != null && X.Y.length`, or the single-eval IIFE
`((_t)=>_t==null?undefined:_t.length)(X?.Y)` — `codemod.mjs` emits the last (general, side-effect-safe).

With this codemod applied post-esbuild, **`porffor.wasm` VALIDATES.** ✅

## 5. The acorn-inline fix — the memory trap was a MISSING PARSER, not a codegen bug

The first validating `porffor.wasm` **trapped `memory access out of bounds`** even compiling `'1'`.
Root cause (found by checking whether acorn's code was actually in the bundle — it was NOT): `parse.js`
loads the parser via a **dynamic, computed import**:

```js
const mod = (await import((globalThis.document ? 'https://esm.sh/' : '') + parser)); // parser = 'acorn'
```

esbuild can't statically resolve a computed specifier, so it left acorn **external**. Node resolves it
at runtime (which is why the bundle "worked" in Node), but **Porffor stubs the unresolved dynamic
import** → the self-hosted compiler had **no parser** → calling the stub returned garbage → OOB.

**Fix (patch #5 in `apply-patches.sh`):** force a static `import * as _acorn from 'acorn'` and use
`_acorn.parse`. esbuild then inlines acorn (bundle 2.5 MB → 2.7 MB, acorn code present). **The memory
trap is GONE.** (We only support acorn — the JS path; not the TS/browser/@babel/meriyah/oxc parsers.)

## 6. The runtime frontier (current wall) ⛔

With acorn inlined, `[validate]` is GREEN and `[run]` now fails **later and differently**:

```
SyntaxError: Regex parse: Invalid flag
```

The self-hosted compiler runs (acorn parses), but a regex construction hits an invalid flag. This is
**not** a missing feature — every flag (`g i m s u y d`) works in *native* `porf run`. So the flags
string is being **corrupted by a self-compile miscompilation** (Porffor mis-compiling its own — or
acorn's — dynamic `new RegExp(src, flags)` / flag-string handling). Like §5's original symptom this is
a *semantic* self-compile bug, but much narrower now (a specific regex-flag path, not the whole parser).

Approaches to localize: (a) shrink the input to `''`/`1` to see if it's parser-init vs input-driven;
(b) grep acorn + codegen for `new RegExp(` with a computed flags argument and test each in isolation
via `porffor run`; (c) build with `-d`, trap-trace to the constructing function. This is why upstream
Porffor self-hosting is unsolved — the semantic layer is a sequence of these.

**Progress ladder:** won't-validate → **[validate] GREEN** (§4 codemod) → memory-trap → **parser runs**
(§5 acorn-inline) → regex-flag (§6, here). **Downstream (porffor.beam, `fe_js`, CLI `.js` dispatch) is
gated on `[run]` GREEN.**

## 7. Bisection method (reusable)

To narrow a construct within a failing function `F` (spans source lines `[a..b]`):

1. Compute `F`'s **brace-balanced statement boundaries** (lines where running `{`-minus-`}` depth,
   relative to the body, returns to 0).
2. For a boundary `K`: rebuild the compiler with `F`'s body replaced by `lines[a..K] + 'return [];'`,
   re-bundle (`--target=esnext`), re-compile with Porffor, `wasm-tools validate --features=all`.
3. **Binary-search `K`**: VALID ⇒ bug is after `K`; INVALID ⇒ at/before `K`. (Only trust brace-
   balanced `K` — an unbalanced cut is a *build* failure, not an invalid wasm; distinguish them.)
4. Once down to a statement, swap sub-expressions to isolate the trigger, and confirm with a minimal
   `porffor wasm` repro. `bisect.sh whichfn` automates step 0 (naming the failing function).
