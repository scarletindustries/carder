#!/usr/bin/env bash
# patch-build-tool.sh — apply our Porffor codegen/assemble fixes to the *build tool* (the `npx porffor`
# install that compiles dist/porffor.compiler.js into dist/porffor.wasm).
#
# WHY THIS EXISTS. There are two copies of Porffor in play (FINDINGS §7b):
#   1. vendored `upstream/compiler` -> bundled into porffor.wasm  (patched by scripts/apply-patches.sh)
#   2. the `npx porffor` install     -> the TOOL that compiles the bundle  (patched HERE)
# A codegen bug in the tool corrupts the bundle it emits; the SAME bug in the vendored compiler
# corrupts the user code porffor.wasm later emits. So genuine Porffor codegen bugs must be fixed in
# BOTH. apply-patches.sh handles (1); this script handles (2). Both delegate to the single source of
# truth: scripts/porffor-codegen-fixes.sh (empty-string, func-lut sizing, func-lut offset collision).
#
# Idempotent. Safe to run before every compile. We DO NOT contact upstream Porffor.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

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

bash "$HERE/porffor-codegen-fixes.sh" "$PORF"
