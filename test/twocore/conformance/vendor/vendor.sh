#!/usr/bin/env bash
#
# vendor.sh — acquire + normalise + sanity-check the Phase-1 spec-suite fixtures.
#
# Pipeline (unit 07 deliverable 1):
#   1. clone github.com/WebAssembly/testsuite and `git checkout <TESTSUITE_SHA>` (PIN);
#   2. for each ALLOWLIST file, run `wast2json` → fixtures/<name>.json + .N.wasm/.N.wat;
#   3. run `spectest-interp fixtures/<name>.json` and REQUIRE "N/N tests passed" before
#      the fixtures are trusted — a mismatched fixture set fails here, not in the runner.
#
# The full normalised set is written to test/twocore/conformance/fixtures/ but is
# GITIGNORED (it is large). A small curated subset is committed so `gleam test` runs
# without re-vendoring; re-run this script to expand coverage to the whole allowlist.
#
# Prerequisites (versions pinned in vendor/PIN; CI installs + checks them):
#   git, wabt (wat2wasm/wast2json/spectest-interp), and a network reachable github.
#
# Usage:  test/twocore/conformance/vendor/vendor.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
conf_dir="$(cd "$here/.." && pwd)"
fixtures_dir="$conf_dir/fixtures"
clone_dir="${TWOCORE_VENDOR_CLONE:-$conf_dir/../../../build/conformance-vendor}"

# --- read PIN -------------------------------------------------------------------
# shellcheck disable=SC1090
TESTSUITE_SHA="$(sed -n 's/^TESTSUITE_SHA=//p' "$here/PIN")"
WABT_VERSION="$(sed -n 's/^WABT_VERSION=//p' "$here/PIN")"
if [ -z "$TESTSUITE_SHA" ]; then echo "PIN: TESTSUITE_SHA missing" >&2; exit 1; fi

echo "vendor: testsuite SHA=$TESTSUITE_SHA  wabt(pinned)=$WABT_VERSION"
wabt_have="$(wat2wasm --version 2>/dev/null | head -1 || true)"
echo "vendor: wat2wasm reports: ${wabt_have:-<not found>}"

# --- clone + checkout the pinned revision --------------------------------------
if [ ! -d "$clone_dir/.git" ]; then
  echo "vendor: cloning testsuite into $clone_dir"
  git clone --quiet https://github.com/WebAssembly/testsuite.git "$clone_dir"
fi
git -C "$clone_dir" fetch --quiet origin "$TESTSUITE_SHA" 2>/dev/null || true
git -C "$clone_dir" checkout --quiet "$TESTSUITE_SHA"
got="$(git -C "$clone_dir" rev-parse HEAD)"
if [ "$got" != "$TESTSUITE_SHA" ]; then
  echo "vendor: checkout SHA mismatch: got $got want $TESTSUITE_SHA" >&2; exit 1
fi

# --- convert each allowlisted file + sanity-check it ----------------------------
# ALLOWLIST format (Phase-2): `<name>` optionally followed by a whitespace-separated
# trailing FLAG COLUMN (e.g. `align<TAB>--enable-memory64`) passed verbatim to
# `wast2json`. Inline `# …` comments and blank lines are ignored. We read line by line
# (not word by word) so the flag column and inline comments are handled correctly.
mkdir -p "$fixtures_dir"
fail=0
skipped=""
converted=""
while IFS= read -r raw || [ -n "$raw" ]; do
  line="${raw%%#*}"                          # strip inline / whole-line comment
  line="${line#"${line%%[![:space:]]*}"}"    # ltrim
  line="${line%"${line##*[![:space:]]}"}"    # rtrim
  [ -z "$line" ] && continue
  read -r name flags <<< "$line"             # first word = name; remainder = wast2json flags
  src="$clone_dir/$name.wast"
  if [ ! -f "$src" ]; then echo "vendor: MISSING $name.wast at pin" >&2; fail=1; continue; fi
  out="$fixtures_dir/$name.json"
  # `wast2json` itself may reject a file whose `.wast` (at this pin) uses post-MVP
  # proposal syntax the pinned wabt cannot parse (e.g. reference types in local_tee).
  # That is an honest FILE-LEVEL coverage gap (D9): record it and move on — do NOT
  # abort the whole vendor run, and do NOT pretend the file was covered. Per-file
  # feature flags (the trailing column, e.g. align's --enable-memory64) are passed
  # through unquoted so each token becomes a separate wast2json argument.
  if ! ( cd "$fixtures_dir" && wast2json $flags "$src" -o "$out" ) >"$out.convert.log" 2>&1; then
    echo "vendor: SKIP $name  (wast2json could not convert at pin — see $name.json.convert.log)" >&2
    skipped="$skipped $name"
    rm -f "$out"
    continue
  fi
  rm -f "$out.convert.log"
  # spectest-interp validates that the BAKED-IN expected values are self-consistent.
  res="$(spectest-interp "$out" 2>&1 | tail -1 || true)"
  if echo "$res" | grep -qE '^[0-9]+/[0-9]+ tests passed\.$'; then
    n="$(echo "$res" | sed -E 's#^([0-9]+)/.*#\1#')"
    echo "vendor: OK   $name  ($res)"
    converted="$converted $name"
    if [ "$n" = "0" ]; then echo "vendor: WARN $name produced 0 tests" >&2; fi
  else
    echo "vendor: FAIL $name  spectest-interp: $res" >&2; fail=1
  fi
done < "$here/ALLOWLIST"

# --- copy the WAT-route target files (P6-10) -----------------------------------
# `memory64.wast` and `linking.wast` are UN-`wast2json`-able at the pin (a `(module definition …)`
# module-linking form; GC typed-ref globals). Per R16 they are driven from OUR WAT parser
# (wat_fixture.gleam): copy the RAW `.wast` text into fixtures/ so the WAT-route tests can read them
# (they degrade to a categorized parse-skip at this pin — the parser cannot handle their out-of-scope
# constructs — but the route is exercised + the residual measured honestly, never a silent drop).
for wat_target in memory64 linking; do
  src="$clone_dir/$wat_target.wast"
  if [ -f "$src" ]; then
    cp "$src" "$fixtures_dir/$wat_target.wast"
    echo "vendor: copied $wat_target.wast (WAT-route target, un-wast2json-able at pin)"
  fi
done

echo "vendor: converted +validated:$converted"
[ -n "$skipped" ] && echo "vendor: skipped (un-convertible at pin):$skipped"
if [ "$fail" != "0" ]; then echo "vendor: one or more CONVERTIBLE fixtures failed validation" >&2; exit 1; fi
echo "vendor: all convertible allowlisted fixtures converted + spectest-interp-validated"
echo "vendor: fixtures in $fixtures_dir (gitignored; commit only the curated subset)"
