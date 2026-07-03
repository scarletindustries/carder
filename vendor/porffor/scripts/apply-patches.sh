#!/usr/bin/env bash
# apply-patches.sh — strip the Node/dynamic coupling from a WORKING COPY of the vendored Porffor
# compiler so it can be bundled into a pure, self-contained JS→Wasm function.
#
# `upstream/` is kept PRISTINE (a clean copy of npm porffor@0.61.13). build.sh copies it into a
# working directory and runs this script there. The patch surface is tiny and stable across Porffor
# releases (re-verify with `git diff` after an update — see README.md "Updating Porffor").
#
# All three edits target code that a pure `compile(code)` call never executes (CLI output-file /
# native paths), so stubbing them is behaviour-neutral for our use.
#
# Usage: apply-patches.sh <working-compiler-dir>
set -euo pipefail
DIR="${1:?usage: apply-patches.sh <working-compiler-dir>}"

patch_line() {  # file  match-regex  replacement
  local f="$DIR/$1" re="$2" repl="$3"
  if grep -qE "$re" "$f"; then
    perl -i -pe "s|$re|$repl|" "$f"
  fi
}

# 1+2. index.js — strip the two Node dynamic imports (fs / child_process). Both are only used behind
#      `outFile`/`Prefs.native`/`Prefs.wasm` guards that pure in-memory compilation never hits.
patch_line compiler/index.js \
  'const fs = \(typeof process\?\.version.*' \
  'const fs = undefined; \/\/ [2core] strip node:fs dynamic import (CLI output path only)'
patch_line compiler/index.js \
  'const execSync = \(typeof process\?\.version.*' \
  'const execSync = undefined; \/\/ [2core] strip node:child_process (native path only)'

# 3. index.js — stub the 2c.js import (Wasm→C compiler). It uses a direct `eval()` (which both
#    esbuild and Porffor reject) and is only reached for `native`/`c` output, never pure compile.
patch_line compiler/index.js \
  "import toc from './2c.js';" \
  "const toc = () => ''; \/\/ [2core] stub 2c.js (direct-eval; native/c output only)"

# 4. wrap.js — same node:fs strip (pulled in transitively via pgo.js in the import graph).
patch_line compiler/wrap.js \
  'const fs = \(typeof process\?\.version.*' \
  'const fs = undefined; \/\/ [2core] strip node:fs dynamic import'

# 5. parse.js — make the acorn parser a STATIC import so esbuild INLINES it. Upstream loads the
#    parser via a dynamic, computed specifier: `await import((globalThis.document ? 'https://esm.sh/'
#    : '') + parser)`. esbuild can't statically resolve that → it leaves acorn external → Node resolves
#    it at runtime but PORFFOR stubs it → the self-hosted compiler has NO PARSER → it traps
#    `memory access out of bounds`. Forcing a static `import * as _acorn from 'acorn'` inlines the
#    parser. We only support acorn (JS; not the TS/browser/@babel/meriyah/oxc paths).
python3 - "$DIR/compiler/parse.js" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
if '_acorn2core' not in s:
    s = "import * as _acorn2core from 'acorn'; // [2core] static acorn so esbuild inlines the parser\n" + s
    s = re.sub(
        r"const mod = \(await import\(\(globalThis\.document.*?\+ parser\)\);\s*\n\s*if \(mod\.parseSync\) parse = mod\.parseSync;\s*\n\s*else parse = mod\.parse;",
        "parse = _acorn2core.parse; // [2core] static acorn",
        s, flags=re.S)
    open(p, 'w').write(s)
    print("[apply-patches] parse.js: acorn made static (inlinable)")
PY

# 6. acorn — make the two WIDE (utf-16) identifier-class regexes LAZY. Upstream builds
#    `nonASCIIidentifierStart`/`nonASCIIidentifier` eagerly at module init via
#    `new RegExp("[" + <chars with code points up to 0xffdc> + "]")`. Porffor's regex engine
#    only accepts BYTESTRING patterns (`__Porffor_regex_compile(patternStr: bytestring, ...)`),
#    so constructing a wide-char pattern throws `TypeError: Invalid regular expression` — even in
#    native Porffor. Normally acorn runs in the *tool* (Node) so this never bites; but self-hosted,
#    acorn runs IN the wasm and the eager init throws before any input is parsed. These two regexes
#    are `.test()`ed ONLY for code points >= 0xaa (non-ASCII identifiers), so deferring construction
#    to first use means ASCII source never triggers them. (Compiling JS with genuinely non-ASCII
#    identifiers still hits Porffor's wide-regex limitation — documented future work.)
# esbuild resolves the ESM entry (dist/acorn.mjs); Node resolves the CJS entry (dist/acorn.js).
# Patch BOTH so the fix reaches the bundle regardless of which acorn build is pulled in.
for _acorn_f in "$DIR/node_modules/acorn/dist/acorn.mjs" "$DIR/node_modules/acorn/dist/acorn.js"; do
python3 - "$_acorn_f" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
if '_nas2core' not in s:
    s = s.replace(
        'var nonASCIIidentifierStart = new RegExp("[" + nonASCIIidentifierStartChars + "]");',
        'var _nasStart2core = null; var nonASCIIidentifierStart = { test: function (_nas2core) { return (_nasStart2core || (_nasStart2core = new RegExp("[" + nonASCIIidentifierStartChars + "]"))).test(_nas2core); } };',
        1)
    s = s.replace(
        'var nonASCIIidentifier = new RegExp("[" + nonASCIIidentifierStartChars + nonASCIIidentifierChars + "]");',
        'var _nasAll2core = null; var nonASCIIidentifier = { test: function (_nas2core) { return (_nasAll2core || (_nasAll2core = new RegExp("[" + nonASCIIidentifierStartChars + nonASCIIidentifierChars + "]"))).test(_nas2core); } };',
        1)
    open(p, 'w').write(s)
    print("[apply-patches] acorn: wide identifier-class regexes made lazy (%s)" % p.split('/')[-1])
PY
done

# 7. codegen.js — empty string literals must NOT be the null pointer 0. Upstream `makeString`
#    returns `[ number(0) ]` for `''` (relying on "memory at 0 is 0 anyway"). But reading a
#    bytestring/string at address 0 returns whatever is at the START of linear memory, which in a
#    large program (the self-hosted compiler) is NON-ZERO — so an empty regex-flags string `''`
#    reads a garbage length and throws `SyntaxError: Regex parse: Invalid flag` (and similar for any
#    empty-string byte read). Fix: point empty strings at a reserved, statically-zero slot via
#    `allocStr` instead of 0. This is a genuine Porffor self-compile bug (see FINDINGS §7); we fix
#    it in BOTH the vendored compiler (here -> porffor.wasm compiles user '' correctly) and the
#    build tool (scripts/patch-build-tool.sh -> the tool compiles the bundle's '' correctly).
python3 - "$DIR/compiler/codegen.js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'if (str.length === 0) return [ number(0) ];'
new = "if (str.length === 0) return [ number(allocStr(scope, '', bytestring)) ]; // [2core] empty string -> reserved zero slot, not null ptr 0 (FINDINGS §7)"
if '[2core] empty string' not in s and old in s:
    s = s.replace(old, new, 1)
    open(p, 'w').write(s)
    print("[apply-patches] codegen.js: empty string -> reserved zero slot (not null ptr 0)")
elif '[2core] empty string' in s:
    print("[apply-patches] codegen.js: empty-string fix already present")
else:
    print("[apply-patches] WARNING codegen.js: makeString empty-string line not found (Porffor changed?)")
PY

echo "[apply-patches] stripped node:fs / execSync / 2c-eval + static-acorn + lazy-wide-regex + empty-string-fix in $DIR"
grep -n "\[2core\]" "$DIR/compiler/index.js" "$DIR/compiler/wrap.js" "$DIR/compiler/codegen.js" || true
