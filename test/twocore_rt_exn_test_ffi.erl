%%% twocore_rt_exn_test_ffi — test-only catch helpers for unit P7-07 (rt_exn).
%%%
%%% Catching a BEAM exception is not expressible in pure Gleam, so these tiny
%%% helpers let the spec tests RAISE via `rt_exn`/`rt_trap` and recover the
%%% caught `{Class, Reason, Stacktrace}` back into Gleam, where the real
%%% `rt_exn.match_tag`/`is_wasm_exn`/`reraise`/`throw_ref` are then exercised on
%%% the genuine caught terms. This mirrors how `emit_core` (P7-06) will emit a
%%% `try … catch <C, R, S>` and route the caught reason through the same helpers.
%%%
%%% The catch is `_Class:Reason:_Stack` — it catches EVERY class (error, throw,
%%% exit), exactly like the Core Erlang `try…catch` P7-06 emits, so the tests
%%% dispatch on the TERM SHAPE (`{wasm_exn,_,_}`), never the class (T7).
%%%
%%% Namespace hygiene (overview §5): prefixed `twocore_` so it can never collide
%%% with an OTP module. Pure: no NIF, cannot crash the node. Because F is invoked
%%% INSIDE a `try`, a raise never escapes to the eunit runner.
-module(twocore_rt_exn_test_ffi).
-export([caught_reason/1, caught_class/1, caught_stack/1]).

%% caught_reason(F) -> Reason
%% Run the 0-arity fun F and return the caught exception's Reason term (any
%% class). If F returns WITHOUT raising, fail loudly (a contract violation the
%% test must surface) — a silent success would let a missing-raise bug pass.
caught_reason(F) ->
    try F() of
        V -> erlang:error({test_helper_expected_raise_but_returned, V})
    catch
        _Class:Reason:_Stack -> Reason
    end.

%% caught_class(F) -> atom()   (error | throw | exit)
%% Run F and return the CLASS of the caught exception, so a test can assert
%% `reraise/3` preserved it. Fails loudly if F returns without raising.
caught_class(F) ->
    try F() of
        V -> erlang:error({test_helper_expected_raise_but_returned, V})
    catch
        Class:_Reason:_Stack -> Class
    end.

%% caught_stack(F) -> [term()]
%% Run F and return the STACKTRACE of the caught exception, so a test can feed a
%% genuine BEAM stacktrace back into `reraise/3`. Fails loudly if F returns.
caught_stack(F) ->
    try F() of
        V -> erlang:error({test_helper_expected_raise_but_returned, V})
    catch
        _Class:_Reason:Stack -> Stack
    end.
