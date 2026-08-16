%% Test-only FFI shim for the unit P4-02 (`emit_core` THREADED seam) end-to-end tests.
%%
%% Hand-written Erlang, so it carries the `carder_` namespace prefix (overview §5). It
%% hand-drives the `state_strategy: Threaded` run-ABI that unit 08 will own: under `Threaded`
%% the generated `instantiate/0` RETURNS the `InstanceState` record (not `'ok'`), every export
%% takes that record as its LEADING argument, and returns `{Package, St'}` — the updated record
%% threaded back out. This shim captures the record, threads it across successive invokes, and
%% turns a trap / capability-denial into `{error, Reason}` instead of crashing the test process.
%% It does not touch any unit-owned source file.
-module(carder_threaded_test_ffi).
-export([instantiate/1, instantiate_with/2, invoke/4]).

%% Run Mod:instantiate() and YIELD the threaded instance-state record.
%% On success `{ok, St}` (a Gleam `Ok(Dynamic)` — the record travels opaquely); on a trap at
%% instantiation (e.g. an out-of-bounds active data/element segment) `{error, ReasonBin}`.
instantiate(Mod) ->
    try Mod:instantiate() of
        St -> {ok, St}
    catch
        _Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}
    end.

%% Run Mod:instantiate(Imports) (the `instantiate/1` ABI of an import-bearing module, P5-06/09)
%% and YIELD the threaded instance-state record. `Imports` is the positional `[Provided ...]`
%% list `link:link_imports` returns. Same capture semantics as `instantiate/1`.
instantiate_with(Mod, Imports) ->
    try Mod:instantiate(Imports) of
        St -> {ok, St}
    catch
        _Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}
    end.

%% Apply Mod:F(St, Args...) — the threaded export ABI. A state-reaching export returns
%% `{Package, St'}`; YIELD `{ok, {Package, St'}}` (a Gleam `Ok(#(Dynamic, Dynamic))`) so the
%% caller can assert on the result AND thread `St'` into the next invoke. A trap /
%% capability-denial yields `{error, ReasonBin}`.
invoke(Mod, F, St, Args) ->
    try erlang:apply(Mod, F, [St | Args]) of
        {Package, St2} -> {ok, {Package, St2}}
    catch
        _Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}
    end.
