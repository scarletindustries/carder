%%% carder_rt_table_ets_test_ffi — test-only observability helpers for the
%%% tier-O ETS funcref-table backend (`rt_table_ets`, unit P4-06).
%%%
%%% These assert the two properties the ETS backend must uphold that are not
%%% observable through the pure Gleam interface:
%%%
%%%  1. LIFECYCLE / no leak (§C/§D): `new/0` deletes the prior private table this
%%%     process created, so a re-instantiation in a reused process never leaks —
%%%     the count of `carder_rt_table` tables this process owns stays bounded.
%%%  2. PRIVACY (§C, G8): the table is `private`, so a SECOND process cannot read
%%%     it (a cross-process read raises), proving it is process-local storage and
%%%     never shared memory.
%%%
%%% Namespace hygiene (overview §5): prefixed `carder_` so it can never collide
%%% with an OTP module. Pure: no NIF, cannot crash the node.
-module(carder_rt_table_ets_test_ffi).
-export([owned_table_count/0, private_blocks_other_process/1]).

%% The 1-based tuple position of the `tid` field in the `rt_table_ets.EtsTable`
%% handle. Gleam compiles `EtsTable(tid, size)` to `{ets_table, Tid, Size}`, so
%% the `tid` is element 2 (element 1 is the constructor tag).
-define(TID_POS, 2).

%% owned_table_count() -> Count
%%
%% The number of `carder_rt_table` ETS tables currently owned by the CALLING
%% process. After a first `new/0` this is 1; after a re-`new/0` in the same
%% process it is STILL 1 (the prior table was deleted — no leak), never 2.
owned_table_count() ->
    Self = self(),
    length([T || T <- ets:all(),
                 ets:info(T, owner) =:= Self,
                 ets:info(T, name) =:= carder_rt_table]).

%% private_blocks_other_process(Handle) -> boolean()
%%
%% Spawn a SEPARATE process and have it attempt to read the ETS table inside the
%% opaque `Handle` (the `rt_table_ets.EtsTable`, whose `tid` is element 2).
%% Returns `true` iff the read was BLOCKED (raised) — i.e. the table is `private`
%% and confined to its owner. Returns `false` if the other process could read it
%% (a privacy violation) or on timeout.
private_blocks_other_process(Handle) ->
    Tid = element(?TID_POS, Handle),
    Parent = self(),
    Ref = make_ref(),
    spawn(fun() ->
        Outcome =
            try ets:lookup(Tid, 0) of
                _ -> readable
            catch
                _:_ -> blocked
            end,
        Parent ! {Ref, Outcome}
    end),
    receive
        {Ref, Outcome} -> Outcome =:= blocked
    after 5000 -> false
    end.
