%%% carder_rt_state_ffi — the sound pdict presence-check shim for `rt_state`
%%% (unit 03, «CELL-STATE-ABI-FROZEN»).
%%%
%%% Hand-written Erlang, so it carries the `carder_` namespace prefix
%%% (overview §5) and can NEVER collide with an OTP module — exactly like
%%% `carder_codegen_ffi`/`carder_cli_ffi`. Tier-O: pure process-dictionary
%%% access, no NIF, cannot crash the node.
%%%
%%% Why a shim at all: `rt_state` must distinguish a PRESENT instance cell from
%%% an UN-SEEDED one (fail-closed, E3). `erlang:get/1` returns the atom
%%% `undefined` for an absent key, and `rt_state` never stores `undefined`, so
%%% `undefined` reliably means "no cell". Pattern-matching that atom is trivial
%%% and zero-copy in Erlang; expressing the same presence test in this
%%% gleam_stdlib version's `dynamic` API is awkward. So this one function does it.
%%%
%%% By reference, NOT a deep copy: `erlang:get/1` returns the stored term by
%%% reference; wrapping it in `{ok, State}` shares the SAME heap term (the 2-tuple
%%% just points at it). This preserves the constant-space property generated code
%%% relies on — there is no O(state) copy of the cell on a read.
-module(carder_rt_state_ffi).
-export([read_cell/1]).

%% read_cell(Key) -> {ok, State} | {error, nil}
%%
%% Read the instance cell stored under Key in THIS process's dictionary. If the
%% key is set, yield `{ok, State}` (a Gleam `Ok(InstanceState)`) with State shared
%% by reference. If it is absent (`erlang:get/1` returns `undefined`), yield
%% `{error, nil}` (a Gleam `Error(Nil)`) so `rt_state` can fail closed instead of
%% reading garbage. `rt_state` is the sole writer of this key and never stores the
%% atom `undefined`, so `undefined` unambiguously means "un-seeded".
read_cell(Key) ->
    case erlang:get(Key) of
        undefined -> {error, nil};
        State -> {ok, State}
    end.
