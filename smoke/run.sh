#!/usr/bin/env bash
# carder smoke test: build real external crates to a no-import, MVP-only wasm, gate it,
# and differential-test each export through carder (compile → .beam → run on the BEAM)
# against wasmtime. Requires: rustc + `rustup target add wasm32v1-none`, wasm-tools,
# wasmtime, and the carder Gleam toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."                       # repo root
WASM=smoke/target/wasm32v1-none/release/carder_smoke.wasm
REL=smoke/target/wasm32v1-none/release

echo "== build (cargo fetches + statically links the real crates) =="
( cd smoke && cargo build --release --target wasm32v1-none )

echo "== gate: import-free + MVP-only =="
imp=$(wasm-tools print "$WASM" | grep -c '(import' || true)
bulk=$(wasm-tools print "$WASM" | grep -cE 'memory\.(copy|fill|init)|data\.drop|v128|ref\.(func|null)' || true)
[ "$imp" = 0 ]  || { echo "FAIL: $imp imports (carder has no import support)"; exit 1; }
[ "$bulk" = 0 ] || { echo "FAIL: $bulk bulk-memory/simd/reftype ops (carder is MVP-only)"; exit 1; }
wasm-tools validate --features=wasm1,mutable-global "$WASM" && echo "  import-free, MVP-valid ($(wc -c <"$WASM") bytes, $(wasm-tools print "$WASM"|grep -c '(func ') funcs)"

echo "== differential: carder (on the BEAM) vs wasmtime =="
gleam build >/dev/null 2>&1
u32() { python3 -c "import sys;print(int(sys.argv[1])&0xffffffff)" "$1"; }
fail=0
for spec in "crc32 50" "crc32 4096" "sha256_word 50" "sha256_word 4096" "deflate_roundtrip 200" "deflate_roundtrip 2000"; do
  fn=${spec% *}; arg=${spec#* }
  g=$(gleam run -- run "$WASM" "$fn" "$arg" 2>/dev/null | tail -1)
  w=$(cd "$REL" && wasmtime run --invoke "$fn" carder_smoke.wasm "$arg" 2>/dev/null | tail -1)
  if [ -n "$g" ] && [ "$(u32 "$g")" = "$(u32 "$w")" ]; then st=ok; else st="MISMATCH"; fail=1; fi
  printf "  %-24s carder=%-11s wasmtime=%-11s %s\n" "$spec" "$g" "$w" "$st"
done
[ "$fail" = 0 ] && echo "== ALL MATCH ==" || { echo "== FAILURES =="; exit 1; }
