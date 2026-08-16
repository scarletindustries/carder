%%% carder_rt_state_test_ffi — test-only catch helper for unit 03 (`rt_state`).
%%%
%%% Catching an Erlang exception is not expressible in pure Gleam (this
%%% gleam_erlang version exposes no `rescue`), so the fail-closed tests need a
%%% shim to assert that an op on an un-seeded cell RAISES rather than returning
%%% garbage — without crashing the test runner. Mirrors `carder_rt_test_ffi` /
%%% `carder_emit_test_ffi`, but generic: it catches a 0-arity fun of ANY raise
%%% shape (rt_state's fail-closed guard is a `panic`, not a `{wasm_trap, _}`).
%%%
%%% Namespace hygiene (overview §5): prefixed `carder_` so it can never collide
%%% with an OTP module. Pure: no NIF, cannot crash the node.
-module(carder_rt_state_test_ffi).
-export([catch_thunk/1]).

%% catch_thunk(F) -> {ok, V} | {error, ReasonBin}
%%
%% Run the 0-arity fun F. On a normal return yield `{ok, V}` (a Gleam `Ok`); if
%% it raises/exits/throws (any class), yield `{error, ReasonBin}` (a Gleam
%% `Error`) with the reason rendered as a UTF-8 binary (a Gleam `String`). The
%% fail-closed tests assert `result.is_error` on the result — i.e. that the op
%% raised at all — which is the E3 contract (never read garbage).
catch_thunk(F) ->
    try F() of
        V -> {ok, V}
    catch
        _Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}
    end.
