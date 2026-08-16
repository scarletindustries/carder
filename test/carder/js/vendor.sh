#!/usr/bin/env bash
# vendor.sh — regenerate the JS corpus fixtures (P7-09).
#
# For every corpus/<category>/<name>.js this:
#   1. compiles it with the PINNED Porffor (`porffor wasm src.js out.wasm`) -> <name>.wasm
#   2. bakes Porffor's own execution stdout (`porffor run src.js`, the T13 oracle) -> <name>.expected
#
# The .wasm + .expected are COMMITTED so the Tier-A headline test judges every program without a
# live Porffor/Node install (mirroring test/carder/porffor/fixtures/ + conformance/vendor). Re-run
# after a corpus edit or a pinned Porffor bump (a bump is a REVIEWED change — see PIN). Node is used
# at bake time to CROSS-CHECK the reference (a porf!=node program is a documented divergence recorded
# in corpus.gleam, never a corpus entry we hold carder to). Skips gracefully if Porffor is absent.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
corpus="$here/corpus"

# Resolve a Porffor CLI: prefer an npx-cached binary (fast), else `npx porffor`.
porf_bin="$(ls "$HOME"/.npm/_npx/*/node_modules/.bin/porf 2>/dev/null | head -1 || true)"
if [ -n "$porf_bin" ]; then
  PORF=(node "$porf_bin")
elif command -v npx >/dev/null 2>&1; then
  PORF=(npx --yes porffor)
else
  echo "vendor.sh: no Porffor toolchain (npx/porf) on PATH — cannot vendor." >&2
  exit 1
fi

echo "vendor.sh: using Porffor -> $("${PORF[@]}" --version 2>/dev/null | tail -1)"

count=0
diverge=0
while IFS= read -r js; do
  name="${js%.js}"
  # 1. compile to wasm
  if ! "${PORF[@]}" wasm "$js" "$name.wasm" >/dev/null 2>&1; then
    echo "  COMPILE_FAIL  ${js#"$corpus"/}" >&2
    continue
  fi
  # 2. bake porf run stdout (the oracle), stderr dropped (an uncaught throw's message is not stdout)
  "${PORF[@]}" "$js" >"$name.expected" 2>/dev/null || true
  # cross-check against Node (logical, ANSI-stripped) — report a divergence, don't fail
  if command -v node >/dev/null 2>&1; then
    porf_logical="$(sed $'s/\x1b\\[[0-9;]*m//g' "$name.expected")"
    node_logical="$(node "$js" 2>/dev/null || true)"
    if [ "$porf_logical" != "$node_logical" ]; then
      echo "  porf!=node    ${js#"$corpus"/}   porf=[$porf_logical] node=[$node_logical]" >&2
      diverge=$((diverge + 1))
    fi
  fi
  count=$((count + 1))
done < <(find "$corpus" -name '*.js' | sort)

echo "vendor.sh: vendored $count program(s); $diverge porf!=node divergence(s) (categorized in corpus.gleam)."
