#!/usr/bin/env bash
# selfhost-check.sh — the RED/GREEN gate for "can the current vendored Porffor self-host?"
#
# It compiles dist/porffor.compiler.js (the pure bundle from build.sh) WITH Porffor into
# dist/porffor.wasm, then reports three escalating checkpoints:
#   [validate]  does the self-compiled wasm pass `wasm-tools validate --features=all`?  (types OK)
#   [run]       does running it actually compile a JS snippet (functions correctly)?     (semantics OK)
# When both are GREEN, dist/porffor.wasm is a working, Node-free, in-Wasm JS→Wasm compiler that
# 2core can turn into porffor.beam. See FINDINGS.md for the current status of each checkpoint.
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
COMPILER="$ROOT/dist/porffor.compiler.js"
WASM="$ROOT/dist/porffor.wasm"

[ -f "$COMPILER" ] || { echo "[selfhost] run ./build.sh first (missing $COMPILER)"; exit 1; }

echo "[selfhost] compiling the pure bundle WITH Porffor -> porffor.wasm ..."
if ! npx --yes porffor wasm --module "$COMPILER" "$WASM" 2>/tmp/porf_selfhost.log; then
  echo "[selfhost] RED: Porffor failed to compile the bundle"; tail -3 /tmp/porf_selfhost.log; exit 1
fi
echo "[selfhost] porffor.wasm = $(wc -c < "$WASM" | tr -d ' ') bytes"

echo -n "[validate] wasm-tools validate --features=all: "
if wasm-tools validate --features=all "$WASM" 2>/tmp/porf_val.log; then
  echo "GREEN (types valid)"
else
  echo "RED"; head -3 /tmp/porf_val.log
  echo "  -> use ./bisect.sh to localize the failing function + construct, add a codemod transform."
  exit 2
fi

echo -n "[run] execute the self-hosted compiler on a snippet: "
RUN=$(npx --yes porffor run --module "$COMPILER" 2>&1 | tail -1)
if echo "$RUN" | grep -q "probe_len="; then
  echo "GREEN ($RUN) — SELF-HOSTING WORKS"
else
  echo "RED ($RUN)"
  echo "  -> the wasm validates but mis-runs: a SEMANTIC self-compile bug (no validator to point at)."
  echo "     Next frontier — see FINDINGS.md 'Runtime wall'."
  exit 3
fi
