%%% carder_rt_mem_atomics_ffi — the thin shim over the ERTS `atomics` BIFs for
%%% the tier-O linear-memory backend (`rt_mem_atomics`, unit P4-04).
%%%
%%% Hand-written Erlang, so it carries the `carder_` namespace prefix
%%% (overview §5) and can NEVER collide with an OTP module — exactly like
%%% `carder_rt_state_ffi`. Tier-O: `atomics` is ERTS-native (no custom C, no
%%% NIF), so it is memory-safe by construction and CANNOT crash the node. The
%%% array is PROCESS-LOCAL and never shared across processes (G8, the
%%% threads/shared-memory hard non-goal).
%%%
%%% Why `{signed, false}`: an unsigned 64-bit word gives a clean `0..2^64-1`
%%% value range, which is exactly what `rt_mem_atomics` packs bytes into (a
%%% little-endian word is `Σ byte[k]·256^k`). A signed array would wrap the top
%%% bit into a negative Erlang integer, complicating the byte codec for zero
%%% correctness benefit.
%%%
%%% An out-of-range index raises a catchable `badarg` (node-safe) — but
%%% `rt_mem_atomics` bounds-checks the effective address BEFORE deriving any
%%% index, so a bad index is unreachable on the happy path (defense-in-depth:
%%% even a bounds bug cannot read or write outside the reserved array).
-module(carder_rt_mem_atomics_ffi).
-export([new/1, get/2, put/3]).

%% new(Arity) -> Ref
%%
%% Allocate a fresh `atomics` array of `Arity` unsigned 64-bit words, all
%% zero-initialised (`atomics:new/2` zero-fills). `Arity` must be `>= 1`;
%% `rt_mem_atomics` guarantees this (it reserves at least one word).
new(Arity) ->
    atomics:new(Arity, [{signed, false}]).

%% get(Ref, Ix) -> Word
%%
%% Read the 1-indexed word `Ix` (a `0..2^64-1` integer). No copy.
get(Ref, Ix) ->
    atomics:get(Ref, Ix).

%% put(Ref, Ix, Val) -> nil
%%
%% Write `Val` (a `0..2^64-1` integer) into the 1-indexed word `Ix`, mutating
%% the shared array IN PLACE. Returns the Gleam `Nil` atom (`nil`) so the Gleam
%% side can type it `-> Nil` without inspecting the BIF's `ok`.
put(Ref, Ix, Val) ->
    atomics:put(Ref, Ix, Val),
    nil.
