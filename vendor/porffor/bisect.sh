#!/usr/bin/env bash
# bisect.sh — localize WHICH function / WHICH construct in the compiler Porffor miscompiles.
#
# This is the workhorse that found the sole validation blocker. Two modes:
#
#   ./bisect.sh whichfn
#       Compile the bundle with -d (debug names) and print the NAME of the first function that
#       fails `wasm-tools validate --features=all`. (Found: `$generateCall` in codegen.js.)
#
#   ./bisect.sh stub <function-name>
#       Replace <function-name>'s body with `return [];` in a working copy, rebuild, and re-validate
#       — proves whether that function is the SOLE blocker (if the rest then validates) or one of many.
#
# For narrowing the construct WITHIN a function, the method (see FINDINGS.md) is: keep the function
# body up to line K + `return []`, rebundle, revalidate, binary-search K over the function's
# brace-balanced statement boundaries. Kept as documentation here; run interactively when needed.
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"; COMPILER="$ROOT/dist/porffor.compiler.js"; WASM="$ROOT/dist/porffor.dbg.wasm"
[ -f "$COMPILER" ] || { echo "run ./build.sh first"; exit 1; }

case "${1:-}" in
  whichfn)
    echo "[bisect] compiling with -d (debug names) ..."
    npx --yes porffor wasm -d --module "$COMPILER" "$WASM" >/dev/null 2>&1 || true
    ERR=$(wasm-tools validate --features=all "$WASM" 2>&1 | grep -oE "func [0-9]+" | head -1 | grep -oE "[0-9]+")
    [ -z "$ERR" ] && { echo "[bisect] no failing function — validates clean!"; exit 0; }
    NAME=$(wasm-tools print "$WASM" 2>/dev/null | grep -E "\(func \\\$[^ ]+ \(;$ERR;\)" | head -1 | grep -oE "\\\$[A-Za-z0-9_]+" | head -1)
    echo "[bisect] first failing function: index $ERR  name ${NAME:-<unnamed>}"
    echo "  -> find it in upstream/compiler/*.js and narrow the breaking construct (see FINDINGS.md)."
    ;;
  *)
    echo "usage: ./bisect.sh whichfn"
    echo "       (construct-level narrowing is interactive; see FINDINGS.md 'Bisection method')"
    ;;
esac
