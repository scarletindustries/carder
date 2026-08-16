%%% carder_rt_table_ets_ffi — the thin shim over the ERTS `ets` BIFs for the
%%% tier-O funcref-table backend (`rt_table_ets`, unit P4-06).
%%%
%%% Hand-written Erlang, so it carries the `carder_` namespace prefix
%%% (overview §5) and can NEVER collide with an OTP module — exactly like
%%% `carder_rt_state_ffi` / `carder_rt_mem_atomics_ffi`. Tier-O: `ets` is
%%% ERTS-native (no custom C, no NIF), memory-safe by construction, CANNOT crash
%%% the node. The table is created `private` (only the owning instance process
%%% can read it) and UNNAMED (an unregistered label — a `named_table` would take
%%% a node-global name and collide with a second instance process on the same
%%% node, breaking the one-instance-one-process isolation, E1). The `Tid` is
%%% therefore process-local and never shared (G8, the shared-memory hard
%%% non-goal).
%%%
%%% ## Lifecycle — the delete-prior discipline (§C/§D)
%%%
%%% A `private` ETS table is auto-deleted when its owner process dies, but is NOT
%%% garbage-collected while the process lives. Under one-instance-one-process a
%%% reused process that re-instantiates would LEAK the prior table. So `new/0`
%%% deletes any prior table THIS process created (tracked under a process-local
%%% pdict key) before creating the fresh one — the `rt_state.clear`-then-`seed`
%%% reset discipline, adapted for a non-GC'd resource. The tracking key is
%%% `carder_rt_table_ets_tid`; it cannot collide with `rt_state`'s
%%% `carder_rt_state` cell key.
-module(carder_rt_table_ets_ffi).
-export([new/0, insert/3, lookup/2, delete/2]).

%% The process-local pdict key under which `new/0` tracks the table it last
%% created, so a re-instantiation can delete it (no leak).
-define(TID_KEY, carder_rt_table_ets_tid).

%% new() -> Tid
%%
%% Create a fresh PRIVATE `set` ETS table (keyed on element 1 of each stored
%% `{Slot, Entry}` tuple) owned by the calling process, first deleting any prior
%% table this process created (§C lifecycle — no leak on re-instantiation). The
%% label atom `carder_rt_table` is an unregistered name (no `named_table`), so
%% two instance processes never collide. Returns the opaque `Tid`.
new() ->
    case erlang:get(?TID_KEY) of
        undefined -> ok;
        Old ->
            %% Deleting an already-gone table would raise `badarg`; idempotent
            %% cleanup must never itself crash, so swallow any such error.
            try ets:delete(Old) catch _:_ -> ok end
    end,
    Tid = ets:new(carder_rt_table, [set, private, {keypos, 1}]),
    erlang:put(?TID_KEY, Tid),
    Tid.

%% insert(Tid, Key, Entry) -> nil
%%
%% Insert the type-tagged closure `Entry` at slot `Key` (a `set` upsert),
%% mutating the table IN PLACE. `Entry` is the opaque `#(FuncType, closure)`
%% term the build-controlled `init_elem` supplies — stored natively, invoked
%% only via a direct fun application on the Gleam side (never `apply/3`, D3a).
%% Returns the Gleam `Nil` atom so the caller can type it `-> Nil`.
insert(Tid, Key, Entry) ->
    ets:insert(Tid, {Key, Entry}),
    nil.

%% lookup(Tid, Key) -> {ok, Entry} | {error, nil}
%%
%% Read slot `Key`. Yields `{ok, Entry}` (a Gleam `Ok`, the stored
%% `#(FuncType, closure)` term as an opaque value) when the slot is filled, or
%% `{error, nil}` (a Gleam `Error(Nil)`) when it is null/absent — exactly the
%% guard-2 (`UninitializedElement`) signal. No copy beyond the single small
%% entry term.
lookup(Tid, Key) ->
    case ets:lookup(Tid, Key) of
        [{Key, Entry}] -> {ok, Entry};
        [] -> {error, nil}
    end.

%% delete(Tid, Key) -> nil
%%
%% Remove slot `Key`, mutating the table IN PLACE. Deleting an absent key is a
%% no-op (`ets:delete/2` never raises on a missing key). Used to represent a
%% `table.set`/`fill`/`copy` of the null reference: a null slot is an ABSENT key
%% (so `call_indirect`'s guard-2 stays byte-identical — absent ⇒ uninitialised).
%% Returns the Gleam `Nil` atom so the caller can type it `-> Nil`.
delete(Tid, Key) ->
    ets:delete(Tid, Key),
    nil.
