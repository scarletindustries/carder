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

echo "[apply-patches] stripped node:fs / execSync / 2c-eval + static-acorn in $DIR"
grep -n "\[2core\]" "$DIR/compiler/index.js" "$DIR/compiler/wrap.js" || true
