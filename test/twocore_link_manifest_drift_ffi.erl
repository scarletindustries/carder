%% Read-only BEAM-introspection FFI for the P11-02 link-closure DRIFT test.
%%
%% It recomputes the runtime link closure + surviving-remote set from the CURRENT build's shipped
%% `.beam` files (NOT from the frozen manifest), so a future runtime change (a new `import`, a new
%% `@external`, a new remote call target) is caught by `link_manifest_drift_test` rather than by the
%% phase-closing capstone. It performs no mutation, spawns nothing, loads no code — it only reads the
%% `imports`/`attributes` chunks via `beam_lib`.
%%
%% The reachability walk is MODULE-granularity over the `beam_lib` `imports` chunk, which records
%% `fun M:F/A` captures as well as direct calls (verified: `rt_simd` reaches `rt_num` only via
%% fun-captures, and they appear here) — so the walk is R4-complete. "In-closure" is decided
%% mechanically: a reached module is in-closure iff a `.beam` for it exists under
%% `build/dev/erlang/*/ebin` (our packages); otherwise it is an OTP-ambient surviving remote.
-module(twocore_link_manifest_drift_ffi).
-export([closure/1, mergeability_violations/1]).

%% All dependency `ebin` directories of the current build (relative to the project root, which is the
%% cwd under `gleam test`).
ebin_dirs() ->
    filelib:wildcard("build/dev/erlang/*/ebin").

%% {ok, Path} if a `.beam` for Mod exists in any of our ebin dirs; `error` otherwise (⇒ OTP-ambient).
beam_path(Mod) ->
    File = atom_to_list(Mod) ++ ".beam",
    Found = lists:filtermap(
        fun(Dir) ->
            P = filename:join(Dir, File),
            case filelib:is_file(P) of
                true -> {true, P};
                false -> false
            end
        end,
        ebin_dirs()),
    case Found of
        [P | _] -> {ok, P};
        [] -> error
    end.

in_closure(Mod) -> beam_path(Mod) =/= error.

%% The set of external modules Mod references (direct calls AND `fun M:F/A` captures), via the
%% `imports` chunk.
imported_modules(Mod) ->
    {ok, Path} = beam_path(Mod),
    case beam_lib:chunks(Path, [imports]) of
        {ok, {_, [{imports, Imports}]}} ->
            lists:usort([M || {M, _F, _A} <- Imports]);
        _ ->
            []
    end.

%% closure(RootBinaries) -> {RuntimeBins, GleamBins, FfiBins, RemoteBins}
%%
%% RootBinaries: the runtime-root module atoms as UTF-8 binaries (Gleam strings). Returns four sorted
%% lists of UTF-8 binaries: the in-closure `twocore@runtime@*` modules, the in-closure `gleam@*`
%% modules, the in-closure hand-FFI `.erl` modules, and the surviving remote (OTP-ambient) targets.
closure(RootBinaries) ->
    Roots = [binary_to_atom(B, utf8) || B <- RootBinaries],
    {Closure, Remotes} = walk(Roots, sets:from_list(Roots), sets:new()),
    ClosureMods = sets:to_list(Closure),
    Runtime = sort_bins([M || M <- ClosureMods, has_prefix("twocore@runtime@", M)]),
    Gleam = sort_bins([M || M <- ClosureMods, has_prefix("gleam@", M)]),
    Ffi = sort_bins([M || M <- ClosureMods,
                          not has_prefix("twocore@", M),
                          not has_prefix("gleam@", M)]),
    Rem = sort_bins(sets:to_list(Remotes)),
    {Runtime, Gleam, Ffi, Rem}.

walk([], Closure, Remotes) ->
    {Closure, Remotes};
walk([Mod | Rest], Closure, Remotes) ->
    Imported = imported_modules(Mod),
    {Closure1, Remotes1, NewWork} =
        lists:foldl(
            fun(M, {C, R, W}) ->
                case in_closure(M) of
                    true ->
                        case sets:is_element(M, C) of
                            true -> {C, R, W};
                            false -> {sets:add_element(M, C), R, [M | W]}
                        end;
                    false ->
                        {C, sets:add_element(M, R), W}
                end
            end,
            {Closure, Remotes, []},
            Imported),
    walk(NewWork ++ Rest, Closure1, Remotes1).

%% mergeability_violations(ClosureBinaries) ->
%%     {OnLoadBins, BehaviourBins, PersistentTermBins, NifBins, DoubleAtBins}
%%
%% ClosureBinaries: the in-closure module atoms as UTF-8 binaries. Returns, for each forbidden
%% construct (R15), the sorted list of offending module binaries (all-empty ⇒ the closure is
%% mergeable). Read-only: only `attributes`/`imports` chunks are inspected.
mergeability_violations(ClosureBinaries) ->
    Mods = [binary_to_atom(B, utf8) || B <- ClosureBinaries],
    OnLoad = sort_bins([M || M <- Mods, has_on_load(M)]),
    Behaviour = sort_bins([M || M <- Mods, has_behaviour(M)]),
    PersistentTerm = sort_bins([M || M <- Mods, imports_module(M, persistent_term)]),
    Nif = sort_bins([M || M <- Mods, loads_nif(M)]),
    DoubleAt = sort_bins([M || M <- Mods, has_substr("@@", M)]),
    {OnLoad, Behaviour, PersistentTerm, Nif, DoubleAt}.

module_attributes(Mod) ->
    {ok, Path} = beam_path(Mod),
    case beam_lib:chunks(Path, [attributes]) of
        {ok, {_, [{attributes, Attrs}]}} -> Attrs;
        _ -> []
    end.

has_on_load(Mod) ->
    proplists:get_value(on_load, module_attributes(Mod)) =/= undefined.

has_behaviour(Mod) ->
    Attrs = module_attributes(Mod),
    Behaviours = proplists:get_value(behaviour, Attrs, [])
        ++ proplists:get_value(behavior, Attrs, []),
    Behaviours =/= [].

imports_module(Mod, Target) ->
    lists:member(Target, imported_modules(Mod)).

loads_nif(Mod) ->
    {ok, Path} = beam_path(Mod),
    case beam_lib:chunks(Path, [imports]) of
        {ok, {_, [{imports, Imports}]}} ->
            lists:any(fun({erlang, load_nif, _}) -> true; (_) -> false end, Imports);
        _ ->
            false
    end.

has_prefix(Prefix, Mod) -> lists:prefix(Prefix, atom_to_list(Mod)).

has_substr(Sub, Mod) -> string:find(atom_to_list(Mod), Sub) =/= nomatch.

sort_bins(Mods) -> lists:sort([atom_to_binary(M, utf8) || M <- Mods]).
