#!/usr/bin/env bash
# carder Phase-4 benchmark revisit (unit P4-10, overview G8) — HONEST numbers, methodology +
# limitations in docs/phase-4-benchmark.md. Holds the committed smoke wasm (CRC-32 / SHA-256 /
# DEFLATE real crates) FIXED and varies only the linked `Binding` along the Phase-4 tier axes:
#
#   build         Binding (schematic)                        isolates
#   ----------------------------------------------------------------------------------------
#   safe          safe()            — Cell + Paged            the Phase-3 baseline (the number we beat)
#   atomics-safe  safe() + Atomics  — Cell + Atomics + --cap  THE memory-tier delta (mem_tier the ONLY change)
#   portable      portable()        — Threaded + Paged        threading overhead / runs-anywhere posture
#   unsafe-paged  unsafe()          — Cell + Paged + Aggr     the optimizer delta on paged (now compilable)
#   ceiling       ceiling() + --cap — Cell + Atomics + Aggr   the fastest build (all levers at once)
#   nif           ceiling()+tier N  — Cell + Nif + Aggr       the tier-N native-memory ceiling (Phase 15)
#
# The `nif` build (Phase 15) is the tier-N analogue of `ceiling`: all levers at once (Aggressive +
# Unsafe + the unchecked loop-versioned arm) but with linear memory served by a REAL erl_nif C backend
# over a reserved raw byte buffer, instead of the tier-O atomics words. tier-N is Unsafe-only and
# RESERVES like atomics, so it rides `--ceiling` with `--tier nif` overriding the memory tier and the
# same mandatory `--cap`. Because `gleam build` has NO native pre-build hook, the `.so` is compiled
# OUT OF BAND here (§0.5) — a toolchain-gated `cc -shared -fPIC` reusing the frozen keystone flag
# vector — then pointed at via `CARDER_RT_MEM_NIF_SO` so the shim's `-on_load` attaches it and
# `rt_mem_nif` dispatches native (else the paged-delegate fallback, byte-identical). No `cc` (or a
# build failure) ⇒ the `nif` column is a CATEGORIZED DASH, never a fabricated (or paged-delegate)
# number. This out-of-band `.so` step is the production `priv/*.so` packaging follow-on in miniature.
#
# Each build is compiled to a persisted `.beam` under its Binding via `to-beam-wasm`, is
# CORRECTNESS-GATED bit-exact vs wasmtime BEFORE it is timed (a fast number that is wrong is not a
# number), then timed with `exec -n N` (invocations ONLY — excludes compile/load/instantiate). The
# hand-written pure-Erlang CRC-32 baseline and the native NIF ceilings (crypto/zlib) are the
# unchanged Phase-3 references. No hero number.
#
# The atomics tier is FIXED-SIZE at creation, so `atomics`/`ceiling` bake a lowered page cap
# (`--cap $CAP`) sized above each kernel's peak `memory.grow` watermark (crc32/sha256 = 18 pages,
# deflate = 22 pages on the reported inputs; see the report). The default CAP=1024 (64 MiB) exceeds
# all three and sits well below the 4096-page atomics reserve cap. A cap below the working set makes
# `grow` return -1 and changes the result — the correctness gate catches it and aborts non-zero.
#
# NOTE (compile-time, honest): the Aggressive optimizer (unsafe/ceiling) inlines the 80-function
# module; with the post-P3 whole-module node ceiling it now TERMINATES (~90 s wall each on the
# reference machine) rather than the Phase-3 `n/a`. Compile time is a one-time cost EXCLUDED from the
# exec timing; the generous COMPILE_TIMEOUT is only a safety net — a build is reported `n/a` ONLY if
# it genuinely fails to finish, with the reason.
#
# Usage: ./smoke/bench.sh [REPEAT] [CAP] [COMPILE_TIMEOUT_SECS]   (defaults: 100, 1024, 300)
set -uo pipefail
cd "$(dirname "$0")/.."                       # repo root
WASM=smoke/target/wasm32v1-none/release/carder_smoke.wasm
REL=smoke/target/wasm32v1-none/release
REPEAT=${1:-100}
CAP=${2:-1024}
COMPILE_TIMEOUT=${3:-300}
OUT=build/bench
mkdir -p "$OUT"

# Portable timeout (macOS lacks GNU `timeout`): run "$@" and kill it after $1 seconds.
run_to() {
  local secs=$1; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) & local w=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill -9 "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $rc
}

# ── 0. the wasm must be built + import-free ─────────────────────────────────────────────────
if [ ! -f "$WASM" ]; then
  echo "== building smoke wasm (cargo) =="
  ( cd smoke && cargo build --release --target wasm32v1-none ) || { echo "cargo build failed"; exit 1; }
fi
imp=$(wasm-tools print "$WASM" 2>/dev/null | grep -c '(import' || true)
[ "${imp:-1}" = 0 ] || { echo "FAIL: $imp imports (carder has no import support)"; exit 1; }
echo "== smoke wasm: $(wc -c <"$WASM") bytes, $(wasm-tools print "$WASM"|grep -c '(func ') funcs, 0 imports =="
gleam build >/dev/null 2>&1

# ── 0.5 the out-of-band tier-N `.so` (Phase 15) — toolchain-gated, else the `nif` column dashes ──
# `gleam build` compiles `src/*.erl` but NOT `c_src/*.c` (Gleam has no native pre-build hook — the
# exact constraint Phase 15 turns on), so the tier-N native memory backend is compiled here, once,
# reusing the FROZEN keystone build recipe (`test/carder_rt_mem_nif_build_ffi.erl`): resolve `cc`
# (fallback `gcc`) + the `erl_nif.h` include dir via the candidate-list resolver (the bare
# `code:lib_dir(erts,include)` is header-less on homebrew OTP 29), and carry the platform flag vector
# (`-undefined dynamic_lookup` is MANDATORY on darwin — a NIF's `enif_*` symbols are undefined at link
# time and resolved from the host beam at load). Success ⇒ point `-on_load` at the `.so` via the env
# override so `rt_mem_nif` runs NATIVE; absence/failure ⇒ HAVE_NIF=0 and the `nif` column is a
# categorized dash (never the paged-delegate timing mislabelled as native).
HAVE_NIF=0
CC_BIN="$(command -v cc || command -v gcc || true)"
if [ -n "$CC_BIN" ] && [ -f c_src/carder_rt_mem_nif.c ]; then
  # erl_nif.h include dir — the frozen candidate-list resolver (pick the first that holds the header).
  ERTS_INC="$(erl -noshell -eval '
    Root = code:root_dir(), Vsn = erlang:system_info(version),
    Cs = [filename:join([Root,"erts-"++Vsn,"include"]),
          filename:join([Root,"usr","include"]),
          filename:join(code:lib_dir(erts),"include")],
    F = [D || D <- Cs, filelib:is_file(filename:join(D,"erl_nif.h"))],
    case F of [Dir|_] -> io:format("~s",[Dir]); [] -> ok end, halt().' 2>/dev/null)"
  if [ -n "$ERTS_INC" ] && [ -f "$ERTS_INC/erl_nif.h" ]; then
    PLATFORM_FLAGS=(); [ "$(uname -s)" = "Darwin" ] && PLATFORM_FLAGS=(-undefined dynamic_lookup)
    SO="$OUT/carder_rt_mem_nif.so"; SO_BASE="$OUT/carder_rt_mem_nif"
    if "$CC_BIN" -shared -fPIC -O2 -I"$ERTS_INC" "${PLATFORM_FLAGS[@]}" -o "$SO" c_src/carder_rt_mem_nif.c 2>"$OUT/cc.log"; then
      # `-on_load` reads this env override (basename, no extension); exported so `gleam run -- exec`
      # (both the correctness gate and the timing loop) inherits it and dispatches native.
      export CARDER_RT_MEM_NIF_SO="$SO_BASE"
      HAVE_NIF=1
      echo "== tier-N .so built: $SO ($(wc -c <"$SO") bytes) via $CC_BIN — native memory ENGAGED =="
    else
      echo "== tier-N .so build FAILED (see $OUT/cc.log) — nif column will dash =="
    fi
  else
    echo "== tier-N: erl_nif.h not resolved — nif column will dash =="
  fi
else
  echo "== tier-N: no C toolchain (cc/gcc) on PATH — nif column will categorize a dash =="
fi

# ── 1. the tier build matrix (one program, three knobs) ─────────────────────────────────────
# Parallel arrays: build name · the `to-beam-wasm` axis flags that select its Binding. The 6th build
# (`nif`, Phase 15) rides `--ceiling` with `--tier nif` overriding the memory tier (Unsafe-only + the
# mandatory reservation `--cap`); it is measured only when HAVE_NIF=1 (else a categorized dash).
BUILDS=(   "safe"  "atomics-safe"                    "portable"    "unsafe-paged" "ceiling"               "nif" )
FLAGS=(    ""      "--tier atomics --cap $CAP"       "--portable"  "--unsafe"     "--ceiling --cap $CAP"  "--ceiling --tier nif --cap $CAP" )
NB=${#BUILDS[@]}                                   # number of builds (the NS stride) — was hardcoded 5
# The three kernels: export · input · repeat count (deflate is heavier, so fewer repeats).
DREPEAT=$(( REPEAT/5 > 20 ? 20 : REPEAT/5 )); [ "$DREPEAT" -lt 5 ] && DREPEAT=5
SPEC_FN=(  "crc32"  "sha256_word"  "deflate_roundtrip" )
SPEC_ARG=( "4096"   "4096"         "2000" )
SPEC_REP=( "$REPEAT" "$REPEAT"     "$DREPEAT" )

# `exec -n N` prints "<result>\n<N> call(s) · <us> us total · <ns> ns/call".
exec_ns()  { gleam run -- exec -n "$1" "$2" "$3" "$4" 2>/dev/null | sed -n '2p' | awk '{print $(NF-1)}'; }
exec_val() { gleam run -- exec -n "$1" "$2" "$3" "$4" 2>/dev/null | sed -n '1p'; }
ratio()    { awk -v s="$1" -v u="$2" 'BEGIN{ if (s ~ /^[0-9]+$/ && u ~ /^[0-9]+$/ && s+0>0) printf "%.1f", u/s; else printf "n/a" }'; }
u32()      { awk -v x="$1" 'BEGIN{ m=4294967296; v=(x%m); if (v<0) v+=m; printf "%d", v }'; }

# ── 2. compile each build to a persisted .beam, then correctness-gate it bit-exact vs wasmtime ──
echo "== compile each tier build to .beam + gate bit-exact vs wasmtime (cap=$CAP pages) =="
declare -a HAVE                                    # HAVE[i]=1 iff build i compiled AND gated OK
# Precompute the wasmtime oracle (u32) for each kernel once.
declare -a ORACLE
for k in "${!SPEC_FN[@]}"; do
  w=$(cd "$REL" && wasmtime run --invoke "${SPEC_FN[$k]}" carder_smoke.wasm "${SPEC_ARG[$k]}" 2>/dev/null | tail -1)
  ORACLE[$k]=$(u32 "$w")
done
for i in "${!BUILDS[@]}"; do
  name=${BUILDS[$i]}; beam="$OUT/smoke.$name.beam"; rm -f "$beam"
  # tier-N: no `.so` (no `cc` or a build failure) ⇒ categorized dash, NOT a paged-delegate number
  # mislabelled as native. Skip compiling/timing it so the column prints n/a (the honest dash).
  if [ "$name" = "nif" ] && [ "${HAVE_NIF:-0}" != 1 ]; then
    HAVE[$i]=0; echo "  nif → n/a (no C toolchain / .so build failed — categorized; native tier not measured)"; continue
  fi
  # shellcheck disable=SC2086   (FLAGS entries are intentionally word-split into flags)
  if run_to "$COMPILE_TIMEOUT" gleam run -- to-beam-wasm ${FLAGS[$i]} "$WASM" "$beam" >/dev/null 2>&1 && [ -f "$beam" ]; then
    gate_ok=1
    for k in "${!SPEC_FN[@]}"; do
      v=$(exec_val 1 "$beam" "${SPEC_FN[$k]}" "${SPEC_ARG[$k]}")
      if [ "$(u32 "${v:-x}")" != "${ORACLE[$k]}" ]; then
        echo "  FAIL: $name not bit-exact vs wasmtime on ${SPEC_FN[$k]}(${SPEC_ARG[$k]}): got '$v', want ${ORACLE[$k]}"
        gate_ok=0
      fi
    done
    if [ "$gate_ok" = 1 ]; then
      HAVE[$i]=1; echo "  $name → $beam ($(wc -c <"$beam") bytes) · gated bit-exact"
    else
      HAVE[$i]=0; echo "== correctness gate failed: aborting (a wrong fast number is never reported) =="; exit 1
    fi
  else
    HAVE[$i]=0; echo "  $name → n/a (compile did not finish within ${COMPILE_TIMEOUT}s — see report)"
  fi
done

# ── 3. hand-written pure-Erlang CRC-32 + native-NIF ceilings via an escript ──────────────────
BASE="$OUT/baseline.escript"
cat > "$BASE" <<'ESCRIPT'
#!/usr/bin/env escript
%%! -noshell
% Hand-written pure-Erlang baselines. Each kernel recomputes `gen(N)` per call, exactly as the
% wasm exports do, so the per-call work matches. crc32 is hand-written (table-driven); sha256 and
% zlib are native NIF ceilings (clearly labelled in the report), NOT hand-written Erlang.
main([RepS, NcrcS, NshaS, NdefS, DrepS]) ->
    R = list_to_integer(RepS), Dr = list_to_integer(DrepS),
    Ncrc = list_to_integer(NcrcS), Nsha = list_to_integer(NshaS), Ndef = list_to_integer(NdefS),
    T = crc_table(),
    bench("erlang_crc32",  fun() -> crc32(gen(Ncrc), T) end, R),
    bench("native_sha256", fun() -> sha_word(gen(Nsha)) end, R),
    bench("native_zlib",   fun() -> Z = gen(Ndef), C = zlib:compress(Z), Z = zlib:uncompress(C), ok end, Dr),
    io:format("erlang_crc32_value ~p~n", [crc32(gen(Ncrc), T)]),
    ok.

bench(Label, Fun, R) ->
    _ = Fun(),
    {Micros, _} = timer:tc(fun() -> loop(Fun, R) end),
    io:format("~s ~p ns/call~n", [Label, (Micros * 1000) div R]).
loop(_, 0) -> ok;
loop(F, K) -> _ = F(), loop(F, K - 1).

gen(N) -> list_to_binary(gen(N, 16#12345678, [])).
gen(0, _, Acc) -> lists:reverse(Acc);
gen(K, S, Acc) ->
    S2 = (S * 1664525 + 1013904223) band 16#FFFFFFFF,
    gen(K - 1, S2, [(S2 bsr 24) band 16#FF | Acc]).

crc_table() -> list_to_tuple([crc_e(N, 8) || N <- lists:seq(0, 255)]).
crc_e(C, 0) -> C;
crc_e(C, K) when C band 1 =:= 1 -> crc_e((C bsr 1) bxor 16#EDB88320, K - 1);
crc_e(C, K) -> crc_e(C bsr 1, K - 1).
crc32(Bin, T) -> crc32(Bin, 16#FFFFFFFF, T) bxor 16#FFFFFFFF.
crc32(<<B, Rest/binary>>, Crc, T) ->
    crc32(Rest, (Crc bsr 8) bxor element(((Crc bxor B) band 16#FF) + 1, T), T);
crc32(<<>>, Crc, _) -> Crc.

sha_word(Bin) -> <<W:32/big, _/binary>> = crypto:hash(sha256, Bin), W.
ESCRIPT
BASE_OUT=$(escript "$BASE" "$REPEAT" 4096 4096 2000 "$DREPEAT" 2>/dev/null)
ERL_CRC=$(echo "$BASE_OUT"  | awk '/erlang_crc32 /{print $2}')
NAT_SHA=$(echo "$BASE_OUT"  | awk '/native_sha256 /{print $2}')
NAT_ZLIB=$(echo "$BASE_OUT" | awk '/native_zlib /{print $2}')
ERL_CRC_VAL=$(echo "$BASE_OUT" | awk '/erlang_crc32_value /{print $2}')
REF=("$ERL_CRC" "$NAT_SHA" "$NAT_ZLIB")             # per-kernel hand-Erl/native reference

# ── 4. time each build × kernel, then print the per-kernel matrix + derived ratios ──────────
echo "== timing (crc/sha REPEAT=$REPEAT, deflate=$DREPEAT calls; ns/call, invocations only) =="
# NS[k*NB + i] = ns/call of kernel k under build i ("n/a" if the build did not compile / dashed).
declare -a NS
for k in "${!SPEC_FN[@]}"; do
  for i in "${!BUILDS[@]}"; do
    if [ "${HAVE[$i]:-0}" = 1 ]; then
      NS[$((k*NB+i))]=$(exec_ns "${SPEC_REP[$k]}" "$OUT/smoke.${BUILDS[$i]}.beam" "${SPEC_FN[$k]}" "${SPEC_ARG[$k]}")
    else
      NS[$((k*NB+i))]="n/a"
    fi
  done
done

echo
printf "%-20s %13s %13s %13s %13s %13s %13s %16s\n" \
  "kernel" "safe/paged" "atomics-safe" "portable" "unsafe-paged" "ceiling" "nif (tier-N)" "hand-Erl/native"
KLABEL=("crc32(4096)" "sha256_word(4096)" "deflate_rt(2000)")
for k in "${!SPEC_FN[@]}"; do
  printf "%-20s %10s ns %10s ns %10s ns %10s ns %10s ns %10s ns %13s ns\n" \
    "${KLABEL[$k]}" \
    "${NS[$((k*NB+0))]}" "${NS[$((k*NB+1))]}" "${NS[$((k*NB+2))]}" "${NS[$((k*NB+3))]}" "${NS[$((k*NB+4))]}" "${NS[$((k*NB+5))]}" "${REF[$k]}"
done
echo
echo "== derived ratios per kernel =="
printf "%-20s %20s %20s %22s %18s\n" "kernel" "paged→atomics (×faster)" "atomics→nif (×faster)" "nif→ref (× slower)" "ceiling→ref (× slower)"
for k in "${!SPEC_FN[@]}"; do
  paged=${NS[$((k*NB+0))]}; atom=${NS[$((k*NB+1))]}; ceil=${NS[$((k*NB+4))]}; nif=${NS[$((k*NB+5))]}
  printf "%-20s %20s %20s %22s %18s\n" \
    "${KLABEL[$k]}" \
    "$(ratio "$atom" "$paged")×" \
    "$(ratio "$nif" "$atom")×" \
    "$(ratio "${REF[$k]}" "$nif")×" \
    "$(ratio "${REF[$k]}" "$ceil")×"
done
echo
echo "crc32(4096): carder=$(exec_val 1 "$OUT/smoke.safe.beam" crc32 4096)  hand-written-Erlang=$ERL_CRC_VAL  (bit-identical head-to-head; both cross-check vs wasmtime in run.sh)"
echo "hand-Erl/native col: crc32 = hand-written PURE Erlang; sha256/deflate = native NIF ceiling (crypto/zlib), NOT hand-written."
echo "paged→atomics = safe/paged ÷ atomics-safe (mem_tier the ONLY change → the pure tier-O effect); atomics→nif = the tier-O→tier-N memory delta; nif/ceiling→ref = the residual to hand-written-Erlang/native."
echo "nif (tier-N): REAL erl_nif C backend over a reserved raw byte buffer — measured ONLY when the .so built (HAVE_NIF=$HAVE_NIF); a dash means no C toolchain (categorized, never a paged-delegate number mislabelled native)."
