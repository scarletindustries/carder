#!/usr/bin/env bash
# apply-lambda-lift.sh — OPT-IN: run the lambda-lift codemod in-place on dist/porffor.compiler.js
# (globalize non-escaping captured variables so Porffor's closures can read them — see README.md).
#
# Kept separate from build.sh on purpose: this is an EXPERIMENT that advances `[run]` but does not make
# it GREEN (escaping closures can't be lifted — README "The ceiling"). Run it AFTER ./build.sh, then
# ./selfhost-check.sh will use the lifted bundle. To undo, just re-run ./build.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE="dist/porffor.compiler.js"
[ -f "$BUNDLE" ] || { echo "run ./build.sh first (missing $BUNDLE)"; exit 1; }

echo "[apply-lambda-lift] transforming $BUNDLE in place ..."
node lambda-lift/lambda-lift.mjs "$BUNDLE" "$BUNDLE.ll" "$@"
mv "$BUNDLE.ll" "$BUNDLE"

echo "[apply-lambda-lift] Node sanity (must still print probe_len): $(node "$BUNDLE" 2>&1 | tail -1)"
echo "[apply-lambda-lift] done — now run ./selfhost-check.sh (the bundle is lambda-lifted)."
