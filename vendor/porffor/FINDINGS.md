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

## 7. Function `.prototype` is `undefined` at scale — the func lut ⛔→✅ (TWO bugs)

With §6 + §6b fixed, `[run]` died during **module init** at acorn's **first prototype-method assignment**
`Position.prototype.offset = …`, because **`Position.prototype` was `undefined`** (and in fact
`Position.name`/`.length` were `""`/`0` too, and it happened for a freshly-defined constructor as well →
a **global** failure, not Position-specific). The surfaced `RangeError: Invalid typed array length` is a
red herring — `wrap.js read()`/`porfToJSValue` crashing while converting the *real* thrown error (clamp
absurd lengths in `read()` to unmask it — see `diagnostics/DIAGNOSTICS.md`).

A function's `.name`/`.length`/`.prototype` come from the **func lut** — a per-indirect-function table
(`__Porffor_funcLut_length/flags/name`, read at `funcIndex * bytesPerFuncLut + off`), and prototype
creation is gated by `ecma262.IsConstructor` reading the lut's `constr` flag (`_internal_object.ts`).
**Two independent bugs corrupt the lut:**

**Bug A — the lut is capped at 2 pages.** `bytesPerFuncLut = min(⌊pageSize·2 / nIndirect⌋, maxNameLen+8)`,
but a valid entry needs ≥ 7 bytes (2 length + 1 flags + 4 nameLen). Past ~4681 indirect funcs the ⌊⌋
term drops below 7, so the write stride (7) ≠ read stride (bytesPerFuncLut) and entries corrupt each
other's `constr` byte. Reproduced with `diagnostics/scale-test.mjs`: 6000 funcs (bytesPerFuncLut=5) work,
8000 (=4) fail; 8000 *non-indirect* funcs work (only the INDIRECT count matters). **Fix:** grow the func
lut to **16 pages** (`allocLargePage` + the `pageSize*16` budget in `bytesPerFuncLut`), keeping
bytesPerFuncLut ≥ 7 for up to ~37k indirect funcs. Data always fits (`nIndirect·bytesPerFuncLut ≤ budget`
by the `min`).

**Bug B (the self-hosting one) — a page-name / string-literal COLLISION.** The lut is *page*-allocated,
so its data-segment offset should be `pages.get('#func lut') * pageSize`. But the data emitter resolves
offsets as `pages.allocs.get(x.page) ?? pages.get(x.page)*pageSize`, and `pages.allocs` is keyed by
*interned string content*. **The Porffor bundle contains the string literal `'#func lut'`** (it IS the
Porffor compiler), so `allocBytes` interns it and `pages.allocs['#func lut']` **shadows the page offset**
→ the lut is written to the string's offset while reads use the page offset → every func-lut read returns
0. (`--debug-func-lut` + an emit-offset print showed base=16384 but data emitted at 2938067.) **Fix:**
store an explicit `offset` on the func-lut data segment and honour it in the emitter (and the section
size pre-count), so a colliding string can't move it. This bug is *invisible* off self-hosting and is a
clean example of why compiling-Porffor-with-Porffor surfaces bugs nothing else does.

Both fixes live in `scripts/porffor-codegen-fixes.sh` (applied to the vendored compiler by
`apply-patches.sh` and to the npx tool by `patch-build-tool.sh` — §7b). With them, `Position.prototype`
works and init advances from statement ~54 to ~470.

## 8. The runtime frontier — missing builtins & Porffor semantics gaps (HERE)

Past §7, init advances through a *sequence* of Porffor limitations (each localized with
`diagnostics/instrument-init.mjs`; the fixes so far live in `apply-patches.sh` / `codemod.mjs`):

- **`String.prototype.replace` is not implemented** (native `typeof "x".replace` is undefined). acorn's
  `wordsRegexp` uses `words.replace(/ /g,"|")`. `.split`/`.join` DO work (they resolve as method *calls*
  even though `typeof x.split` is undefined), so `apply-patches.sh` #8 rewrites it to
  `words.split(" ").join("|")`. (The other ~20 `.replace` sites are debug/disassembler-path, not hit by
  the probe — a real `String.prototype.replace` builtin is future work.)
- **`process` is not defined** — Porffor's Prefs/CLI code reads `process.argv`/`process.stdout` at init.
  `codemod.mjs` prepends a harmless `process` stub (real `process` under Node).
- **`globalThis.X = …` does not create a readable bare global `X`** (native: `globalThis.Prefs={}` then
  bare `Prefs` throws "Prefs is not defined"). Porffor sets globals via `globalThis.X` and reads them
  bare everywhere (Prefs, precompile, pageSize, …). `codemod.mjs` rewrites `globalThis.X` → bare `X` and
  declares those as module `var`s — EXCEPT names that are also local `let/const/var` bindings (e.g.
  `let importFuncs = globalThis.importFuncs = []`, which would become a TDZ self-reference). The proper
  fix is a Porffor `generateIdent` fallback to `globalThis[name]` for undeclared globals — future work.
- **optional call on a nullish base doesn't short-circuit** — `file2?.endsWith(".ts")` with `file2`
  undefined should be `undefined`, but Porffor evaluates `file2?.endsWith` to undefined and then CALLS
  it → `TypeError: undefined is not a function` (native: `var u; u?.m()` throws). Plain optional MEMBER
  access works; only optional CALLs are broken. `codemod.mjs` transform #3 rewrites `X?.m(a)` →
  `((_t)=>_t==null?undefined:_t.m(a))(X)` (single-eval, keeps `this`). **This advanced init from ~470
  to ~703** (it fixed many sites), which uncovered the fundamental wall below.

## 8b. THE FUNDAMENTAL WALL: Porffor has no closures over enclosing-function locals ⛔ (HERE)

At init statement ~703 (`var invOpcodes = inv(Opcodes2)` where
`inv = (obj, keyMap = x=>x) => Object.keys(obj).reduce((acc,x2)=>{ acc[keyMap(obj[x2])]=x2; … })`),
`[run]` fails `ReferenceError: keyMap is not defined`. Minimal native repros isolate it precisely:

| construct | result |
|---|---|
| `var g = () => G+1` capturing a **module global** `G` | **works** (101) |
| `(a) => { var g = () => a+1; return g() }` capturing an **enclosing param** | ❌ `a is not defined` |
| `function outer(a){ function inner(){ return a } return inner() }` | ❌ (same) |
| `(a) => [1,2].reduce((acc,x) => acc+a, 0)` (capture in a builtin callback) | ❌ `a is not defined` |

**Porffor 0.61.13 does not implement closures that capture enclosing-function locals/parameters** —
only closures over module-level globals work. This is not a codemod-able construct or a missing builtin;
it is a **major compiler feature**. The Porffor compiler uses capturing closures *pervasively* (every
`.map`/`.reduce`/`.filter`/`.sort`/`.find` callback that references an outer variable, plus nested
codegen helpers over `scope`/`func`), so self-hosting cannot get much past here until Porffor gains
closure support. **This is the real reason upstream Porffor self-hosting is unsolved** — the earlier
items (§6–§8) were a tractable sequence of bugs/missing-builtins; this is a foundational gap.

Options for the next agent (all large): (a) wait for / port upstream Porffor closure support and
re-vendor; (b) implement closure capture in the vendored Porffor codegen (heap-allocated environments —
substantial); (c) a codemod that lambda-lifts capturing callbacks (see below). There is no quick patch.

### 8b.1 Lambda-lift experiment (`lambda-lift/`) — advances the frontier, but has a hard ceiling

Option (c) was prototyped in `vendor/porffor/lambda-lift/` (kept OUT of the main build; opt-in). Instead
of classic lambda-lifting (blocked — Porffor's `.bind` is broken, so no partial application), it
**globalizes captured variables**: Porffor closures over *module globals* work, so for each function it
promotes params/locals that nested closures read into fresh module globals, with save/restore at
entry/exits (recursion-safe; plain assignments, since Porffor's `try/finally`+closure is broken). Verified
correct on `inv` and via a Node correctness oracle.

Result: globalizing `inv` clears the init `keyMap` wall and lets `compileJS` run into **actual
compilation** — real progress. **But the ceiling is fundamental:** globalization is only sound for
NON-ESCAPING closures (run synchronously within the function — array-method callbacks). The compiler has
many **escaping** closures that outlive their function and thus can't be lifted — e.g. `comptime`'s
`Object.defineProperty(..., { set(x){ x.comptime = comptime2 } })` setter. On the bundle ~6 captures are
safely globalized and **~66 escape** and are skipped; the next blocker after `inv` is a `this`-capture
(esbuild's `this$1`), then the escaping ones. No codemod can eliminate escaping closures — they need real
closure support. So lambda-lifting **extends reach but is not a complete path to `[run]` GREEN**. See
`lambda-lift/README.md` for the mechanism, the ceiling, and how to run/wire it in.

This is the long tail CONTINUE.md warned about; §6–§8 cleared the tractable part. Each fix advanced
`[run]` further (init stmt 54 → 703 of 733); the closure wall is where the effort/return changes shape.

**Progress ladder:** won't-validate → **[validate] GREEN** (§4) → memory-trap → **parser runs** (§5) →
**empty-string null-ptr** (§6) → **wide-regex init** (§6b) → **func-`.prototype`/func-lut** (§7, 2 bugs)
→ **missing-builtins + globalThis + optional-call** (§8, all FIXED) → **closures-over-locals**
(§8b, HERE — fundamental, init stmt ~703/733). Downstream (porffor.beam, `fe_js`, CLI `.js`) gated on
`[run]` printing `probe_len=`.

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
