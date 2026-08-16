%%% carder_rt_mem_nif_ffi — the tier-N («nif») linear-memory NIF SHIM (S15-01 keystone).
%%%
%%% Hand-written Erlang under `src/`, so it carries the `carder_` namespace prefix (overview §5,
%%% same convention as `carder_rt_mem_atomics_ffi`) and can NEVER collide with an OTP module. Unlike
%%% the tier-O atomics shim (which is PURE ERLANG over the `atomics` BIFs — no NIF), THIS is the FIRST
%%% real NIF: every exported function is a `load_nif`-backed stub. At `-on_load` the module tries to
%%% attach the compiled `.so`; each stub then either dispatches into C (once attached) or raises the
%%% honest `nif_error(nif_not_loaded)`.
%%%
%%% FROZEN CONVENTIONS (this is the «NIF-BUILD-FROZEN» shim surface — S15-02/03/04 bind to it VERBATIM
%%% and never edit this file):
%%%
%%%   (a) ERL_NIF_INIT MODULE ATOM = THIS module = `carder_rt_mem_nif_ffi`. `load_nif` attaches NIFs
%%%       to the module in whose code it runs, and `ERL_NIF_INIT`'s first token MUST name that same
%%%       module. So S15-02's `c_src/carder_rt_mem_nif.c` declares
%%%       `ERL_NIF_INIT(carder_rt_mem_nif_ffi, …)` — NOT `carder_rt_mem_nif`. (Verified live by the
%%%       keystone build test: with the `_ffi`-suffixed atom, `load_nif` attaches and `nif_ping()`
%%%       dispatches to C.)
%%%
%%%   (b) THE `.so` BASENAME is `carder_rt_mem_nif` (the file on disk is `carder_rt_mem_nif.so`;
%%%       `load_nif`'s path arg is the basename WITHOUT the extension). `-on_load` resolves it via the
%%%       `CARDER_RT_MEM_NIF_SO` env override (the TEST-TIME load path — the build FFI sets it to the
%%%       freshly-compiled tempdir base, then force-reloads this module to re-run `-on_load`) then
%%%       `priv/carder_rt_mem_nif` (the DEPLOYMENT path — a prebuilt per-platform `.so`, a documented
%%%       follow-on, not built this phase).
%%%
%%%   (c) SOFT LOAD. `init/0` returns `ok` EVEN WHEN `load_nif` fails, so the shim always loads and its
%%%       stubs stay callable — raising the honest `nif_not_loaded` (or, for `nif_available/0`,
%%%       returning `false`) rather than making the module unloadable (`undef`). The paged-delegate
%%%       (`rt_mem_nif.gleam`, untouched this unit) never calls this shim, so at keystone time the shim
%%%       is INERT unless the build test force-loads it — an absent `.so` cannot perturb the default
%%%       suite.
%%%
%%% THE EXPORT TABLE is the frozen ABI seam (keystone §3.3): 14 memory ops + `nif_ping` +
%%% `nif_available` = 16 exports, all `nif_`-prefixed so no name collides with a BEAM auto-imported BIF
%%% (`size`/`init`/`copy`/`fill`). Every op stub raises `nif_error(nif_not_loaded)`; `nif_available/0`
%%% instead returns the atom `false` (the runtime paged-delegate fallback probe the S15-02 Gleam heads
%%% dispatch on). At keystone ONLY `nif_ping/0` gets a real C body; the rest stay stubs until S15-02's
%%% `.c` lands and is attached by the same `load_nif`.
-module(carder_rt_mem_nif_ffi).
-on_load(init/0).

-export([nif_ping/0, nif_available/0, nif_fresh/2, nif_size/1, nif_grow/2, nif_load/5,
         nif_store/4, nif_init_data/3, nif_load_bytes/3, nif_store_bytes/3, nif_fill/4,
         nif_copy/5, nif_init/5, nif_to_flat/1, nif_load_unchecked/5, nif_store_unchecked/4]).

%% ─────────────────────────── -on_load bootstrap ───────────────────────────

%% Resolve the `.so` and attach its NIFs to this module. SOFT: returns `ok` regardless of whether
%% `load_nif` succeeds, so the shim is always loadable and its stubs stay callable.
%%
%% Load path: the `CARDER_RT_MEM_NIF_SO` env override (test-time, set by the build FFI to the
%% freshly-compiled tempdir base) takes precedence, else `priv/carder_rt_mem_nif` (deployment
%% follow-on). The path is a `.so` basename WITHOUT the extension (a `load_nif` convention).
%% Returns: `ok` (always — the soft-load decision).
init() ->
    Base =
        case os:getenv("CARDER_RT_MEM_NIF_SO") of
            false ->
                %% Deployment path (a documented follow-on, not built this phase). `code:priv_dir/1`
                %% may itself be `{error, bad_name}` before the app dir exists; guard it so `-on_load`
                %% never crashes the module load.
                case code:priv_dir(carder) of
                    {error, _} -> "carder_rt_mem_nif";
                    Priv -> filename:join(Priv, "carder_rt_mem_nif")
                end;
            Path ->
                Path
        end,
    _ = erlang:load_nif(Base, 0),
    ok.

%% ─────────────────────────── the probe + availability exports ───────────────────────────

%% nif_ping() -> 'pong'
%%
%% The keystone toolchain probe: the ONLY export whose real C body lands in S15-01. When the `.so` is
%% attached it returns the atom `pong`; unattached it raises `nif_error(nif_not_loaded)`. A green
%% `pong` proves the ENTIRE pipe (erl_nif.h resolution, the committed `.h` compiling, resource-type
%% registration, `ERL_NIF_INIT` dispatch, term marshalling).
nif_ping() -> erlang:nif_error(nif_not_loaded).

%% nif_available() -> boolean()
%%
%% Whether the native `.so` is loaded. THE STUB RETURNS `false` (not `nif_error`) so the runtime
%% paged-delegate fallback probe answers honestly when no `.so` is attached; S15-02's real C body
%% returns `true`. This is the ONE export whose stub is a value, not a raise — the S15-02 Gleam heads
%% dispatch native-vs-paged on it.
nif_available() -> false.

%% ─────────────────────────── the 14 memory-op stubs (S15-02 fills the C) ───────────────────────────
%%
%% Each raises `nif_error(nif_not_loaded)` until S15-02's `.c` is attached. The names/arities/argument
%% order below are the FROZEN ABI (keystone §3.3) the Gleam @externals and the C `nif_funcs[]` bind to.
%% The effective address is a SINGLE combined `Ea` operand (`ea = addr + offset`, computed no-wrap as a
%% BEAM bignum Gleam-side); the C never re-adds addr+offset.

%% nif_fresh(ByteLen, MaxBytes) -> Resource. Allocate the reserved buffer; zero-fill `[0,ByteLen)`.
nif_fresh(_ByteLen, _MaxBytes) -> erlang:nif_error(nif_not_loaded).

%% nif_size(Resource) -> Pages :: integer(). `byte_len div 65536`.
nif_size(_Resource) -> erlang:nif_error(nif_not_loaded).

%% nif_grow(Resource, DeltaPages) -> PrevPages :: integer() | -1. Bump the watermark within
%% `max_bytes`, zero-filling the new region; `-1` if the delta would exceed the reservation.
nif_grow(_Resource, _DeltaPages) -> erlang:nif_error(nif_not_loaded).

%% nif_load(Resource, Bytes, Signed, ResultWidth, Ea) -> {ok, integer()} | {error, memory_out_of_bounds}.
%% LITTLE-endian; sign/zero-extend to ResultWidth per Signed.
nif_load(_Resource, _Bytes, _Signed, _ResultWidth, _Ea) -> erlang:nif_error(nif_not_loaded).

%% nif_store(Resource, Bytes, Ea, Value) -> ok | {error, memory_out_of_bounds}. Trap-before-write.
nif_store(_Resource, _Bytes, _Ea, _Value) -> erlang:nif_error(nif_not_loaded).

%% nif_init_data(Resource, Ea, Data :: binary()) -> ok | {error, memory_out_of_bounds}. Active data init.
nif_init_data(_Resource, _Ea, _Data) -> erlang:nif_error(nif_not_loaded).

%% nif_load_bytes(Resource, Ea, N) -> {ok, binary()} | {error, memory_out_of_bounds}. The SIMD byte seam.
nif_load_bytes(_Resource, _Ea, _N) -> erlang:nif_error(nif_not_loaded).

%% nif_store_bytes(Resource, Ea, Data :: binary()) -> ok | {error, memory_out_of_bounds}. The SIMD byte seam.
nif_store_bytes(_Resource, _Ea, _Data) -> erlang:nif_error(nif_not_loaded).

%% nif_fill(Resource, Dest, Value, Count) -> ok | {error, memory_out_of_bounds}. All-or-nothing.
nif_fill(_Resource, _Dest, _Value, _Count) -> erlang:nif_error(nif_not_loaded).

%% nif_copy(DstRes, SrcRes, Dst, Src, Count) -> ok | {error, memory_out_of_bounds}. The `_at` twins
%% select the two resources Gleam-side (overlap-safe copy in C).
nif_copy(_DstRes, _SrcRes, _Dst, _Src, _Count) -> erlang:nif_error(nif_not_loaded).

%% nif_init(Resource, Seg :: binary(), Dst, Src, Count) -> ok | {error, memory_out_of_bounds}.
%% The Gleam head supplies the segment bytes.
nif_init(_Resource, _Seg, _Dst, _Src, _Count) -> erlang:nif_error(nif_not_loaded).

%% nif_to_flat(Resource) -> binary(). The whole in-bounds byte image (`[0,byte_len)`); the differential
%% hook, tests only.
nif_to_flat(_Resource) -> erlang:nif_error(nif_not_loaded).

%% nif_load_unchecked(Resource, Bytes, Signed, ResultWidth, Ea) -> integer(). NO bounds compare (a raw
%% deref) — S15-02 fills the C. The Phase-10 loop-versioning guard proves the range in-bounds first.
nif_load_unchecked(_Resource, _Bytes, _Signed, _ResultWidth, _Ea) -> erlang:nif_error(nif_not_loaded).

%% nif_store_unchecked(Resource, Bytes, Ea, Value) -> ok. NO bounds compare (a raw deref) — S15-02 fills.
nif_store_unchecked(_Resource, _Bytes, _Ea, _Value) -> erlang:nif_error(nif_not_loaded).
