#!/usr/bin/env bash
#
# gen-conformance-svg.sh — render the WebAssembly spec-suite conformance graph.
#
# Runs the Phase-1 conformance gleeunit test (`spec_suite_allowlist_test`), parses
# the per-file and TOTAL `pass/skip/fail` report it prints to stdout, and writes a
# self-contained, GitHub-README-renderable SVG to docs/wasm-conformance.svg.
#
# The image reflects whatever `*.json` fixtures are present under
# test/twocore/conformance/fixtures/. A fresh checkout only ships the curated
# subset; for the FULL allowlist numbers, regenerate the (gitignored) fixtures
# first — either run test/twocore/conformance/vendor/vendor.sh by hand, or set
# RUN_VENDOR=1 when invoking this script:
#
#     RUN_VENDOR=1 scripts/gen-conformance-svg.sh
#
# The chart has two parts, so that EVERY top-level testsuite `.wast` file is
# represented (not just the ones we drive):
#   1. "Run" — one stacked pass/skip/fail bar per file that produced a report
#      line (the allowlisted slice the conformance test actually measured).
#   2. "Not run (skipped)" — a compact grid of every other top-level `.wast`
#      file in the pinned testsuite. These are enumerated from the vendored
#      checkout (TESTSUITE_DIR, default build/conformance-vendor) and shown as
#      file-level skips: we do not convert/drive them, so we do NOT invent
#      per-assertion numbers for them — they are counted once, as a file. The
#      run/not-run split is derived by set-differencing the enumerated files
#      against the report's per-file lines (cross-checked with the allowlist).
#
# Dependencies: bash, awk, gleam (+ the vendor toolchain only if RUN_VENDOR=1).
# No Hex/npm deps, no network at render time. Inline-styled SVG only (no external
# fonts/links/images), so it renders identically in a GitHub README.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

conf_test="twocore/conformance/conformance_test"
out_svg="docs/wasm-conformance.svg"
pin="test/twocore/conformance/vendor/PIN"
allowlist="test/twocore/conformance/vendor/ALLOWLIST"
# Vendored testsuite checkout to enumerate. Top-level `.wast` files only; any
# `proposals/` subdirectory is naturally excluded (the glob matches files, not
# the subdir). Override with TESTSUITE_DIR if the checkout lives elsewhere.
testsuite_dir="${TESTSUITE_DIR:-build/conformance-vendor}"

# Optionally regenerate the full (gitignored) fixture set before measuring.
if [ "${RUN_VENDOR:-0}" = "1" ]; then
  echo "gen-conformance-svg: RUN_VENDOR=1 → regenerating fixtures via vendor.sh" >&2
  bash test/twocore/conformance/vendor/vendor.sh
fi

# Run the conformance test; its stdout carries the per-file + TOTAL report.
echo "gen-conformance-svg: running conformance test ($conf_test) ..." >&2
report="$(gleam test -- "$conf_test" 2>&1 || true)"

# Keep the run-block HEADERS ("=== … — <label> ===") and the report lines ("<file>.json pass=…"
# and the TOTAL line). The headers let awk isolate the ONE full, unfiltered profile run (Phase 5
# runs the suite SEVEN times — the two full profiles + the five filtered tier-matrix combos — and
# only the full Safe run carries the complete per-file breakdown + the enlarged-allowlist TOTAL).
lines="$(printf '%s\n' "$report" \
  | grep -E '(=== Phase-3 spec-suite|(\.json| TOTAL) +pass=[0-9]+ +skip=[0-9]+ +fail=[0-9]+)' || true)"

if ! printf '%s\n' "$lines" | grep -q 'TOTAL'; then
  echo "gen-conformance-svg: ERROR — no TOTAL report line in conformance output." >&2
  echo "gen-conformance-svg: did the conformance test compile/run? Output follows:" >&2
  printf '%s\n' "$report" >&2
  exit 1
fi

# Provenance read from the vendor PIN + allowlist (shown in the SVG footnote).
sha="$(sed -n 's/^TESTSUITE_SHA=//p' "$pin" | head -1)"
sha7="${sha:0:7}"
wabt="$(sed -n 's/^WABT_VERSION=//p' "$pin" | head -1)"
allow_count="$(grep -vcE '^[[:space:]]*#|^[[:space:]]*$' "$allowlist" || echo 0)"

# Enumerate EVERY top-level testsuite `.wast` file (basename, `.wast` stripped),
# sorted. awk set-differences this list against the report's per-file lines: any
# enumerated file that produced no report line is rendered as a "not run" skip.
allfiles_tmp="$(mktemp "${TMPDIR:-/tmp}/2core-allwast.XXXXXX")"
trap 'rm -f "$allfiles_tmp"' EXIT
if compgen -G "$testsuite_dir/*.wast" > /dev/null 2>&1; then
  for f in "$testsuite_dir"/*.wast; do
    b="$(basename "$f")"
    printf '%s\n' "${b%.wast}"
  done | LC_ALL=C sort > "$allfiles_tmp"
else
  echo "gen-conformance-svg: WARN — no testsuite checkout at '$testsuite_dir'; the" >&2
  echo "gen-conformance-svg:        'not run' grid will be empty (only measured files shown)." >&2
  : > "$allfiles_tmp"
fi

mkdir -p "$(dirname "$out_svg")"

# Emit the SVG. The awk program uses single-quoted XML attributes, so it is supplied
# from a quoted here-doc via process substitution (no bash expansion / quoting
# conflicts); the report lines arrive on stdin, the provenance scalars through -v.
printf '%s\n' "$lines" \
  | awk -v sha="$sha7" -v wabt="$wabt" -v allow="$allow_count" -v allfiles="$allfiles_tmp" -f <(cat <<'AWK'
function commas(x,   s, out) {
  s = sprintf("%d", x); out = ""
  while (length(s) > 3) { out = "," substr(s, length(s) - 2) out; s = substr(s, 1, length(s) - 3) }
  return s out
}
# Parse each report line into the per-file arrays (or the TOTAL accumulators). Only the FULL Safe
# run (unfiltered — the enlarged Phase-5 allowlist, 21525 pass) feeds the chart; the filtered
# tier-matrix combos print a tier-touching SUBSET (fewer passes) and the Unsafe run duplicates the
# Safe totals, so gate on the Safe full-profile header ("Baseline optimizer + enforcing fuel").
/=== Phase-3 spec-suite/ {
  active = ($0 ~ /Baseline optimizer \+ enforcing fuel/) ? 1 : 0
  next
}
!active { next }
{
  name = $1; p = 0; s = 0; f = 0
  for (i = 1; i <= NF; i++) {
    if      ($i ~ /^pass=/) p = substr($i, 6) + 0
    else if ($i ~ /^skip=/) s = substr($i, 6) + 0
    else if ($i ~ /^fail=/) f = substr($i, 6) + 0
  }
  if (name == "TOTAL") { tP = p; tS = s; tF = f; next }
  sub(/\.json$/, "", name)
  # Only the full Safe block is active here, so each file appears once; the `seen` guard is a
  # belt-and-braces dedup (a file line is idempotent — the counts are tier-/profile-neutral, H7).
  if (name in seen) next
  seen[name] = 1
  n++; fn[n] = name; fp[n] = p; fs[n] = s; ff[n] = f
}
END {
  # Order run rows by passing count, descending (stable enough for the chart).
  for (a = 1; a <= n; a++) ord[a] = a
  for (a = 1; a < n; a++) {
    m = a
    for (b = a + 1; b <= n; b++) if (fp[ord[b]] > fp[ord[m]]) m = b
    t = ord[a]; ord[a] = ord[m]; ord[m] = t
  }

  # ---- "not run" set: every enumerated testsuite file with NO report line. We drive only the
  # files that produced counts above (the allowlisted, wast2json-convertible slice); the rest are
  # honest file-level skips (we do not run them, so no per-assertion numbers are fabricated). ----
  gm = 0
  if (allfiles != "") {
    while ((getline nm < allfiles) > 0) {
      if (nm == "" || (nm in seen)) continue
      gm++; skipf[gm] = nm
    }
    close(allfiles)
  }
  totalFiles = n + gm

  # ---- palette (GitHub-ish) ----
  ink = "#1f2328"; muted = "#57606a"; faint = "#8c959f"; track = "#eaeef2"
  gBar = "#3fb950"; sBar = "#d0d7de"; rBar = "#f85149"
  gTxt = "#1a7f37"; sTxt = "#6e7781"; rTxt = "#cf222e"
  skFill = "#f6f8fa"; skStroke = "#d0d7de"; skTxt = "#8c959f"

  # ---- geometry ----
  W = 720
  secAy = 133                       # "Run" section label baseline
  y0 = 150; rowH = 22.5; barH = 13  # run bars
  labelRightX = 150; barX = 162; barW = 384; countRightX = 704
  barsBottom = y0 + n * rowH

  # not-run grid (column-major so each column reads alphabetically top→bottom)
  secBy = barsBottom + 30           # "Not run" section label baseline
  gridTop = secBy + 12
  gridLeft = 24; gridRight = 704
  gridCols = 3; gridRowH = 15; swatch = 10
  gridRows = int((gm + gridCols - 1) / gridCols)
  if (gm == 0) gridRows = 0
  colW = (gridRight - gridLeft) / gridCols
  gridBottom = gridTop + gridRows * gridRowH

  fn1Y = gridBottom + 24; fn2Y = fn1Y + 15
  H = fn2Y + 16

  # ---- derived headline stats (assertion-level, over the RUN files only) ----
  inscope = tP + tS + tF
  attempted = tP + tF
  attPct = attempted > 0 ? sprintf("%.0f", tP * 100.0 / attempted) : "0"
  covPct = inscope   > 0 ? sprintf("%.0f", tP * 100.0 / inscope)   : "0"
  pillBg = tF == 0 ? "#dafbe1" : "#ffebe9"
  pillTx = tF == 0 ? "#1a7f37" : "#cf222e"

  font = "system-ui, -apple-system, Segoe UI, Helvetica, Arial, sans-serif"

  print "<svg xmlns='http://www.w3.org/2000/svg' width='" W "' height='" H "' viewBox='0 0 " W " " H "' xml:space='preserve' font-family='" font "'>"
  print "  <rect x='0.5' y='0.5' width='" (W - 1) "' height='" (H - 1) "' rx='10' fill='#ffffff' stroke='#d0d7de'/>"

  # ---- header ----
  print "  <text x='24' y='34' font-size='19' font-weight='700' fill='" ink "'>WebAssembly spec-suite conformance</text>"
  print "  <text x='24' y='58' font-size='12.5' fill='" muted "'><tspan fill='" gTxt "' font-weight='600'>" commas(tP) "</tspan> passing  ·  <tspan fill='" sTxt "' font-weight='600'>" commas(tS) "</tspan> out of scope  ·  <tspan fill='" (tF == 0 ? gTxt : rTxt) "' font-weight='600'>" commas(tF) "</tspan> failing</text>"
  print "  <text x='24' y='80' font-size='11.5' fill='" muted "'><tspan fill='" ink "' font-weight='600'>" attPct "%</tspan>&#160;of attempted assertions pass  ·  <tspan fill='" ink "' font-weight='600'>" covPct "%</tspan>&#160;in-scope coverage</text>"

  # ---- 0-failing pill (top-right) ----
  print "  <rect x='608' y='16' width='96' height='26' rx='13' fill='" pillBg "'/>"
  print "  <text x='656' y='33' font-size='12' font-weight='600' text-anchor='middle' fill='" pillTx "'>✓ " commas(tF) " failing</text>"

  # ---- legend ----
  legY = 104
  print "  <rect x='24'  y='" (legY - 9) "' width='11' height='11' rx='2.5' fill='" gBar "'/><text x='41'  y='" legY "' font-size='11' fill='" muted "'>passing (in scope)</text>"
  print "  <rect x='196' y='" (legY - 9) "' width='11' height='11' rx='2.5' fill='" sBar "'/><text x='213' y='" legY "' font-size='11' fill='" muted "'>out of scope (skipped)</text>"
  print "  <rect x='392' y='" (legY - 9) "' width='11' height='11' rx='2.5' fill='" rBar "'/><text x='409' y='" legY "' font-size='11' fill='" muted "'>failing</text>"
  print "  <rect x='470' y='" (legY - 9) "' width='11' height='11' rx='2.5' fill='" skFill "' stroke='" skStroke "'/><text x='487' y='" legY "' font-size='11' fill='" muted "'>not run (skipped)</text>"

  print "  <line x1='24' y1='116' x2='704' y2='116' stroke='" track "'/>"

  # ---- section A: files we run ----
  print "  <text x='24' y='" secAy "' font-size='12' font-weight='700' fill='" ink "'>Run <tspan font-weight='400' fill='" faint "'>· " n " files · real pass/skip/fail</tspan></text>"

  # ---- one stacked bar per run file ----
  for (k = 1; k <= n; k++) {
    j = ord[k]
    yt = y0 + (k - 1) * rowH
    tb = yt + 10            # text baseline, vertically centred in the bar
    tot = fp[j] + fs[j] + ff[j]
    if (tot <= 0) tot = 1
    gw = barW * fp[j] / tot
    sw = barW * fs[j] / tot
    rw = barW * ff[j] / tot

    print "  <text x='" labelRightX "' y='" tb "' font-size='10' text-anchor='end' fill='" muted "'>" fn[j] "</text>"
    print "  <rect x='" barX "' y='" yt "' width='" barW "' height='" barH "' rx='3' fill='" track "'/>"
    print "  <clipPath id='c" k "'><rect x='" barX "' y='" yt "' width='" barW "' height='" barH "' rx='3'/></clipPath>"
    printf "  <g clip-path='url(#c%d)'>", k
    printf "<rect x='%s' y='%s' width='%.2f' height='%s' fill='%s'/>", barX, yt, gw, barH, gBar
    printf "<rect x='%.2f' y='%s' width='%.2f' height='%s' fill='%s'/>", barX + gw, yt, sw, barH, sBar
    if (rw > 0) printf "<rect x='%.2f' y='%s' width='%.2f' height='%s' fill='%s'/>", barX + gw + sw, yt, rw, barH, rBar
    print "</g>"

    line = "  <text x='" countRightX "' y='" tb "' font-size='9.5' text-anchor='end'>"
    line = line "<tspan fill='" gTxt "' font-weight='600'>" fp[j] "</tspan><tspan fill='" muted "'> pass</tspan>"
    line = line "<tspan fill='" muted "'>  ·  </tspan>"
    line = line "<tspan fill='" sTxt "' font-weight='600'>" fs[j] "</tspan><tspan fill='" muted "'> skip</tspan>"
    if (ff[j] > 0)
      line = line "<tspan fill='" muted "'>  ·  </tspan><tspan fill='" rTxt "' font-weight='600'>" ff[j] "</tspan><tspan fill='" muted "'> fail</tspan>"
    line = line "</text>"
    print line
  }

  # ---- section B: files we do NOT run — shown as file-level skips (transparency grid) ----
  if (gm > 0) {
    print "  <text x='24' y='" secBy "' font-size='12' font-weight='700' fill='" ink "'>Not run <tspan font-weight='400' fill='" faint "'>· " gm " of " totalFiles " top-level files · shown as skip (not driven)</tspan></text>"
    for (g = 1; g <= gm; g++) {
      idx = g - 1
      col = int(idx / gridRows)
      row = idx % gridRows
      cx = gridLeft + col * colW
      cyTop = gridTop + row * gridRowH
      cyBase = cyTop + swatch
      printf "  <rect x='%.2f' y='%s' width='%s' height='%s' rx='2' fill='%s' stroke='%s'/>", cx, cyTop, swatch, swatch, skFill, skStroke
      printf "<text x='%.2f' y='%s' font-size='9.5' fill='%s'>%s</text>\n", cx + swatch + 6, cyBase, skTxt, skipf[g]
    }
  }

  # ---- footnotes ----
  print "  <text x='24' y='" fn1Y "' font-size='9.5' fill='" muted "'>Phase 6: the complete standardized WebAssembly 2.0 surface — fixed-width SIMD (v128 + the ~236 lane instructions, emulated lane-wise), the memory64 runtime (documented spec-aligned page cap), and cross-module function linking. Pass roughly doubled (+25,004, the 59 simd_*.wast files); " commas(tF) " failing under every shipped tier. Residual out of scope (each a separate proposal): relaxed-SIMD, GC-proposal typed references, module-linking, exception-handling, SIMD text-format.</text>"
  print "  <text x='24' y='" fn2Y "' font-size='9' fill='" faint "'>Source: WebAssembly/testsuite @ " sha " · wabt " wabt " · " totalFiles " top-level .wast: " n " run / " gm " skip · " allow " allowlisted · regenerate: scripts/gen-conformance-svg.sh</text>"

  print "</svg>"
}
AWK
) > "$out_svg"

echo "gen-conformance-svg: wrote $out_svg" >&2
