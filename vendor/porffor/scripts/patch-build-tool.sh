#!/usr/bin/env bash
# patch-build-tool.sh — apply our Porffor CODEGEN fixes to the *build tool* (the `npx porffor`
# install that compiles dist/porffor.compiler.js into dist/porffor.wasm).
#
# WHY THIS EXISTS. There are two copies of Porffor in play:
#   1. vendored `upstream/compiler` -> bundled into porffor.wasm  (patched by scripts/apply-patches.sh)
#   2. the `npx porffor` install     -> the TOOL that compiles the bundle  (patched HERE)
# A codegen bug in the tool corrupts the bundle it emits; the SAME bug in the vendored compiler
# corrupts the user code porffor.wasm later emits. So genuine Porffor codegen bugs must be fixed in
# BOTH. apply-patches.sh handles (1); this script handles (2).
#
# Currently one fix: `makeString('')` returns the null pointer 0, so an empty string reads garbage
# at memory address 0 in a large program -> `Regex parse: Invalid flag` etc. (see FINDINGS §7).
# We repoint empty strings at a reserved, statically-zero slot via `allocStr`.
#
# Idempotent. Safe to run before every compile. We DO NOT contact upstream Porffor (out-of-scope
# experiment) — the fix lives here. If a Porffor update moves the target line, update the matcher.
set -uo pipefail

# Locate the porffor the pipeline actually runs (npx cache). Allow override via $PORFFOR_DIR.
PORF="${PORFFOR_DIR:-}"
if [ -z "$PORF" ]; then
  PORF="$(find "$HOME/.npm" -maxdepth 6 -type d -name porffor 2>/dev/null | head -1)"
fi
if [ -z "$PORF" ] || [ ! -f "$PORF/compiler/codegen.js" ]; then
  echo "[patch-build-tool] could not locate npx porffor codegen.js (looked in \$PORFFOR_DIR / ~/.npm)."
  echo "[patch-build-tool] run 'npx porffor --version' once to populate the npx cache, then retry."
  exit 1
fi

python3 - "$PORF/compiler/codegen.js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'if (str.length === 0) return [ number(0) ];'
new = "if (str.length === 0) return [ number(allocStr(scope, '', bytestring)) ]; // [2core] empty string -> reserved zero slot, not null ptr 0 (FINDINGS §7)"
if '[2core] empty string' in s:
    print("[patch-build-tool] tool codegen.js: empty-string fix already present -> " + p)
elif old in s:
    s = s.replace(old, new, 1)
    open(p, 'w').write(s)
    print("[patch-build-tool] tool codegen.js: empty string -> reserved zero slot -> " + p)
else:
    print("[patch-build-tool] WARNING: makeString empty-string line not found in " + p + " (Porffor changed?)")
    sys.exit(1)
PY
