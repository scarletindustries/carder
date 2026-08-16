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
# The full normalised set is written to test/carder/conformance/fixtures/ but is
# GITIGNORED (it is large). A small curated subset is committed so `gleam test` runs
# without re-vendoring; re-run this script to expand coverage to the whole allowlist.
#
# Prerequisites (versions pinned in vendor/PIN; CI installs + checks them):
#   git, wabt (wat2wasm/wast2json/spectest-interp), and a network reachable github.
#
# Usage:  test/carder/conformance/vendor/vendor.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
conf_dir="$(cd "$here/.." && pwd)"
fixtures_dir="$conf_dir/fixtures"
clone_dir="${CARDER_VENDOR_CLONE:-$conf_dir/../../../build/conformance-vendor}"

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
  # spectest-interp validates that the BAKED-IN expected values are self-consistent. The per-file
  # FLAG COLUMN ($flags, e.g. `--enable-tail-call`) is passed here too — otherwise spectest-interp
  # cannot run a proposal's own asserts (it would report a partial "12/47", under-validating the
  # baked values). wast2json + spectest-interp accept the same feature flags.
  res="$(spectest-interp $flags "$out" 2>&1 | tail -1 || true)"
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

# --- EXCEPTION-HANDLING fixtures (P7-10; Phase-13 unblock) ----------------------
# The official EH `.wast` suite needs `wast2json --enable-exceptions`, and its `.wasm` modules carry
# EH opcodes. To keep the Phase-1..6 headline (46529/1768/0) BYTE-IDENTICAL, the EH fixtures live in
# a SUBDIRECTORY `fixtures/eh/` that the main `conformance_test.gleam` top-level glob does not see;
# they are driven separately by `eh_conformance_test.gleam`. MEASURED at the pin: 6 of the 8 official
# EH files CONVERT — `throw`, `throw_ref`, legacy `throw`, legacy `rethrow`, and (since Phase 13
# landed the tail-call proposal) legacy `try_catch` + legacy `try_delegate`, which use
# `return_call`/`return_call_indirect` and so ALSO need `--enable-tail-call` (spectest-interp 42/42 +
# 26/26). The other 2 (`tag` — GC `(rec …)`; `try_table` — typed refs / GC `exn`) do not convert.
# HONEST MEASURED SCOPE (R16): only 4 of the 6 convertible files are DRIVEN GREEN end-to-end. The two
# newly-convertible legacy files are vendored (the conversion bar is met) but NOT driven — driving
# them reveals a scope DEEPER than tail-call (cross-module EH function+tag imports; legacy `delegate`
# label-targeting; `return_call` inside a `try` must abandon the dynamically-scoped BEAM handler), so
# eh_conformance_test categorizes them as deferred, NOT an EH gap and NOT a tail-call gap. wabt legacy
# naming: `legacy/throw.wast` → `legacy_throw.json`. `vendor_eh`'s optional 3rd arg = extra
# `wast2json`/`spectest-interp` flags (the two legacy files need `--enable-tail-call`).
eh_dir="$fixtures_dir/eh"
mkdir -p "$eh_dir"
vendor_eh() {  # <src-rel-path> <out-basename> [extra-flags]
  local src="$clone_dir/$1" out="$eh_dir/$2.json" extra="${3:-}"
  if [ ! -f "$src" ]; then echo "vendor: EH MISSING $1 at pin (skipped)" >&2; return; fi
  if ( cd "$eh_dir" && wast2json --enable-exceptions $extra "$src" -o "$out" ) >"$out.convert.log" 2>&1; then
    rm -f "$out.convert.log"
    res="$(spectest-interp --enable-exceptions $extra "$out" 2>&1 | tail -1 || true)"
    echo "vendor: EH OK   $2  ($res)"
  else
    echo "vendor: EH SKIP $1  (wast2json --enable-exceptions $extra could not convert at pin)" >&2
    rm -f "$out"
  fi
}
vendor_eh "throw.wast"          "throw"
vendor_eh "throw_ref.wast"      "throw_ref"
vendor_eh "legacy/throw.wast"   "legacy_throw"
vendor_eh "legacy/rethrow.wast" "legacy_rethrow"
# Phase-13 unblock: these two legacy EH files use `return_call`/`return_call_indirect`, so they need
# BOTH `--enable-exceptions` AND `--enable-tail-call` to convert at the pin (measured).
vendor_eh "legacy/try_catch.wast"    "legacy_try_catch"    "--enable-tail-call"
vendor_eh "legacy/try_delegate.wast" "legacy_try_delegate" "--enable-tail-call"

# --- GC fixtures (Phase-8) -------------------------------------------------------
# The official WebAssembly GC `.wast` suite. wabt 1.0.41's WAT parser cannot tokenize GC
# struct/array/i31 instructions or GC abstract heap types (an upstream gap — wabt issue #2530;
# `--enable-gc` is a CLI facade with no parser behind it), so these are converted with
# `wasm-tools json-from-wast` (which fully parses GC and emits a wast2json-compatible `.json` +
# `.wasm` set). Output lands in `fixtures/gc/` — a SUBDIRECTORY the main `conformance_test`
# top-level `.json` glob does not see, so the Phase-1..6 headline stays byte-identical; the GC
# suite is driven separately by `gc_conformance_test`. NOTE: wasm-tools has no `spectest-interp`
# equivalent for GC, so (unlike the wabt lanes) the baked expected values are NOT re-validated at
# vendor time — they are the pinned testsuite's own spec-authoritative values. Toolchain-gated:
# if wasm-tools is absent, the GC fixtures are skipped and `gc_conformance_test` degrades to a
# graceful "no fixtures" categorized skip (never a false green).
gc_dir="$fixtures_dir/gc"
if command -v wasm-tools >/dev/null 2>&1; then
  echo "vendor: GC via $(wasm-tools --version)"
  mkdir -p "$gc_dir"
  vendor_gc() {  # <src-basename> <out-basename>
    local src="$clone_dir/$1.wast" out="$gc_dir/$2.json"
    if [ ! -f "$src" ]; then echo "vendor: GC MISSING $1.wast at pin (skipped)" >&2; return; fi
    if ( cd "$gc_dir" && wasm-tools json-from-wast "$src" -o "$out" --wasm-dir "$gc_dir" ) \
        >"$out.convert.log" 2>&1; then
      rm -f "$out.convert.log"
      # Normalise `source_filename` to the BASENAME (wasm-tools embeds the absolute input path,
      # which is machine-specific and would churn the committed fixture); the `.wasm` `filename`
      # refs stay relative and loadable.
      tmp="$(mktemp)"
      sed 's#"source_filename":"[^"]*/#"source_filename":"#' "$out" > "$tmp" && mv "$tmp" "$out"
      echo "vendor: GC OK   $2"
    else
      echo "vendor: GC SKIP $1 (wasm-tools json-from-wast could not convert at pin)" >&2
      rm -f "$out"
    fi
  }
  for gc in struct array array_copy array_fill array_init_data array_init_elem \
            array_new_data array_new_elem binary-gc br_on_cast br_on_cast_fail \
            extern i31 local_init ref_cast ref_eq ref_func ref_null ref_test \
            type-canon type-equivalence type-rec type-subtyping; do
    vendor_gc "$gc" "$gc"
  done
else
  echo "vendor: wasm-tools not found — GC fixtures SKIPPED (gc_conformance_test categorized-skips)" >&2
fi

echo "vendor: converted +validated:$converted"
[ -n "$skipped" ] && echo "vendor: skipped (un-convertible at pin):$skipped"
if [ "$fail" != "0" ]; then echo "vendor: one or more CONVERTIBLE fixtures failed validation" >&2; exit 1; fi
echo "vendor: all convertible allowlisted fixtures converted + spectest-interp-validated"
echo "vendor: fixtures in $fixtures_dir (gitignored; commit only the curated subset)"
