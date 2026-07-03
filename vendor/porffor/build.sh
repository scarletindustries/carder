#!/usr/bin/env bash
# build.sh — turn the vendored Porffor compiler into a pure, self-contained JS→Wasm bundle:
#   pristine upstream/  --(patch)-->  working copy  --(esbuild@esnext)-->  bundle  --(codemod)-->  dist/porffor.compiler.js
#
# The output `dist/porffor.compiler.js` is a single Node-free ESM file exporting `compileJS(code)`,
# ready to be self-compiled with Porffor (see selfhost-check.sh). Requires: node, npx (esbuild +
# @babel/core are fetched on demand), and the vendored upstream/ + upstream/node_modules/acorn.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
WORK="$ROOT/dist/work"
OUT="$ROOT/dist/porffor.compiler.js"
BUNDLE="$ROOT/dist/porffor.bundle.js"

echo "[build] 1/4  copy pristine upstream -> working copy"
rm -rf "$WORK"; mkdir -p "$WORK"
cp -R "$ROOT/upstream/compiler" "$WORK/compiler"
cp -R "$ROOT/upstream/node_modules" "$WORK/node_modules"
cp "$ROOT/src/entry.js" "$WORK/entry.js"
# entry.js imports ../upstream/compiler; rewrite to the local working copy
perl -i -pe "s|\.\./upstream/compiler/index\.js|./compiler/index.js|" "$WORK/entry.js"

echo "[build] 2/4  apply strip patches (node:fs / execSync / 2c-eval)"
bash "$ROOT/scripts/apply-patches.sh" "$WORK"

echo "[build] 3/4  esbuild bundle (--target=esnext: keep ?. / ?? for Porffor + the codemod)"
npx --yes esbuild "$WORK/entry.js" --bundle --format=esm --platform=neutral --target=esnext \
  --outfile="$BUNDLE" --log-level=error

echo "[build] 4/4  post-esbuild codemod (rewrite the Porffor-miscompiled constructs)"
# @babel/core is a build-time tool (gitignored, not vendored); install on demand.
if ! node -e "require.resolve('@babel/core')" 2>/dev/null; then
  echo "[build]      installing @babel/core (build-time only) ..."
  ( cd "$ROOT" && npm install --silent --no-audit --no-fund @babel/core >/dev/null 2>&1 )
fi
node "$ROOT/codemod.mjs" "$BUNDLE" "$OUT"

echo "[build] done -> $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
echo "[build] sanity (Node): $(node "$OUT" 2>&1 | tail -1)"
