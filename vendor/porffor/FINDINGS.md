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

## 6. The "Regex parse: Invalid flag" wall was NOT a flag bug — it was the empty string ⛔→✅

The prior wall (`SyntaxError: Regex parse: Invalid flag`, input-independent, fires at acorn init) was
mis-diagnosed as a corrupted *flags* string from a dynamic `new RegExp(pattern, flags)`. It is not.

**How it was actually found (the method matters — reuse it):**
- Porffor lowers a regex **literal** `/pat/flags` into a *runtime* call `RegExp("pat", "flags")` with
  BOTH operands as string literals (codegen.js `generateExp`/`decl.regex`). So the culprit is a regex
  **literal**, and it calls the builtin `RegExp` directly — a `new RegExp` wrapper never sees it.
- Instrumenting the bundle with **baked string-literal markers** before each regex construction
  (`(console.log("<<REG N>>"), <ctor>)`) and running under `porffor run` pinpointed **site 0** =
  acorn's `keywordRelationalOperator = /^in(stanceof)?$/` → `RegExp("^in(stanceof)?$", "")`.
- A probe wrapper logging the operands separately showed: **pattern correct, but the empty flags `""`
  arrived with `length = 197` of garbage**. The empty string was reading garbage memory.

**Root cause (a real Porffor self-compile bug):** `makeString` returns **`[ number(0) ]` — the null
pointer — for every empty string literal `''`** (codegen.js ~5686), and `makeData` skips writing
length-0 data ("memory at 0 is 0 anyway"). Reading a bytestring at address 0 reads `memory[0..4]`.
In a *small* program that's 0 (so `''` works — every isolated repro passes); in the **26 MB
self-hosted bundle** address 0 is non-zero, so `''` reads a garbage length → the regex flag loop sees
bogus bytes → "Invalid flag". The same latent bug corrupts *any* empty-string byte read at scale.

**Fix (carried, applied in BOTH Porffor copies — see §8 note on the two copies):** point empty strings
at a reserved, statically-zero slot instead of 0:
```js
// makeString(str): was  ->  if (str.length === 0) return [ number(0) ];
if (str.length === 0) return [ number(allocStr(scope, '', bytestring)) ];
```
`allocStr('')` reserves an interned 4-byte region in static data that is never written (stays 0), so
`''.length === 0`. → the "Invalid flag" wall is GONE. (`scripts/apply-patches.sh` patch #7 for the
vendored compiler; `scripts/patch-build-tool.sh` for the npx build tool.)

## 6b. Wide (utf-16) regex patterns at acorn init ⛔→✅

Past the empty-string fix, `[run]` hit `TypeError: Invalid regular expression`, localized (same marker
method) to acorn's `nonASCIIidentifierStart = new RegExp("[" + <chars up to 0xffdc> + "]")`. Porffor's
`__Porffor_regex_compile(patternStr: bytestring, …)` **only accepts bytestring patterns** — a wide
pattern throws, even natively. Acorn normally runs in the *tool* (Node) so this never bites; self-hosted
it runs in the wasm and the *eager* init throws. These two regexes are `.test()`ed only for code points
≥ 0xaa, so `apply-patches.sh` patch #6 makes them **lazy** (memoized on first use). ASCII input never
constructs them. (Compiling JS with genuinely non-ASCII identifiers still needs real wide-regex support
in Porffor's engine — documented future work.)

## 7. The current wall: function `.prototype` is `undefined` past ~7–8k functions ⛔ (HERE)

With §6 + §6b fixed, `[run]` now dies during **module init**, not while compiling. Chain of diagnosis:
- The surfaced error is `RangeError: Invalid typed array length: 1939865600` — but that is a **red
  herring** from Porffor's *value-conversion* glue (`wrap.js read()`/`porfToJSValue`): the wasm threw
  an exception and `porffor run` crashes trying to read the thrown Error's corrupted `.message`
  string. Temporarily clamping absurd lengths in `wrap.js read()` (a diagnostic patch) reveals the
  real thrown error: **`TypeError` (message itself garbled by the same string-at-scale corruption).**
- Bracketing every **top-level init statement** with markers (`diagnostics/instrument-init.mjs`)
  pinned the throw to acorn's **first prototype-method assignment**:
  `Position.prototype.offset = function offset(n){ … }` — the assignment throws because
  **`Position.prototype` is `undefined`** (boolean-probed: `Position.prototype === undefined` → `true`,
  while `typeof Position === "function"`).
- This is the **first** `X.prototype.method = …` in the whole bundle, so it breaks **every**
  prototype-based class — i.e. all of acorn.

**It is scale-dependent, driven by TOTAL function count (not the constructor's own index):**
- The exact `Position` pattern, and even 6000 dummy indirect functions + a constructor, **work** in
  isolation (`diagnostics/scale-test.mjs`).
- At **≥ 8000** functions the minimal repro reproduces `TypeError: Cannot set property of undefined`.
  (At ≥ 10000 an *unrelated* limit appears: "local count too large" in the indirect wrapper.)
- The bundle has **11692 functions / 5588 indirect** (wasm table size) — over the threshold — and
  `Position` (an early, low-index function) fails anyway → it's a **global** resource keyed to total
  function count, not the constructor's index.
- Increasing `--page-size` does **not** help (it trades the throw for `memory access out of bounds`).

**Unresolved:** the exact Porffor constant/region that overflows around 7–8k functions and stops
function prototypes from being materialized. Candidates to chase next: how a user function's
`.prototype` object is allocated/looked-up at runtime (search codegen for the funcRef→prototype path
and `__Porffor_object_setPrototype`); the func-lut sizing (`bytesPerFuncLut = min(⌊pageSize·2 /
nIndirect⌋, maxNameLen+8)` shrinks with more indirect funcs); and whether prototype resolution reads a
per-function region sized by total func count. A clean minimal repro exists (`scale8000.js`), so this
can be bisected in a **fast** loop without the 10 s bundle compile.

**Progress ladder:** won't-validate → **[validate] GREEN** (§4) → memory-trap → **parser runs** (§5) →
regex-flag = **empty-string null-ptr** (§6, FIXED) → **wide-regex init** (§6b, FIXED) →
**func-`.prototype`-at-scale** (§7, HERE). Downstream (porffor.beam, `fe_js`, CLI `.js`) gated on `[run]`.

## 7b. The two Porffor copies (important for any codegen fix)

There are **two** Porffor 0.61.13 installs, and a real codegen bug must be fixed in BOTH:
1. **vendored** `upstream/compiler` → bundled into `porffor.wasm` (the compiler-as-data). Patched by
   `scripts/apply-patches.sh`. Fixing here makes `porffor.wasm` emit correct code for *user* JS.
2. **`npx porffor`** (the tool) → compiles the bundle into `porffor.wasm` (the compiler-as-tool).
   Patched by `scripts/patch-build-tool.sh` (called from `selfhost-check.sh`). Fixing here makes the
   *bundle itself* compile correctly.
A fix in only one leaves the other's output corrupt. The eventual clean design is to compile the
bundle **with itself** (in Node), collapsing the two into one patched copy — see CONTINUE.md.

## 8. Bisection method (reusable)

To narrow a construct within a failing function `F` (spans source lines `[a..b]`):

1. Compute `F`'s **brace-balanced statement boundaries** (lines where running `{`-minus-`}` depth,
   relative to the body, returns to 0).
2. For a boundary `K`: rebuild the compiler with `F`'s body replaced by `lines[a..K] + 'return [];'`,
   re-bundle (`--target=esnext`), re-compile with Porffor, `wasm-tools validate --features=all`.
3. **Binary-search `K`**: VALID ⇒ bug is after `K`; INVALID ⇒ at/before `K`. (Only trust brace-
   balanced `K` — an unbalanced cut is a *build* failure, not an invalid wasm; distinguish them.)
4. Once down to a statement, swap sub-expressions to isolate the trigger, and confirm with a minimal
   `porffor wasm` repro. `bisect.sh whichfn` automates step 0 (naming the failing function).
