#!/usr/bin/env escript
%% test262 conformance runner for the 2core JS compiler.
%%
%% This is NOT official conformance. The real test262 harness (assert.js / sta.js)
%% attaches properties to function objects, uses `new` on plain functions, and
%% does value-based `instanceof` — none of which this compiler supports yet, so the
%% official harness cannot even load. Instead we prepend a SHIM harness of plain
%% top-level functions and rewrite `assert.sameValue(` -> `assertSameValue(` (etc.)
%% in each test body, then compile+run the body. This measures POSITIVE feature
%% correctness on the areas we implement — the useful signal for driving the
%% compiler forward.
%%
%% Usage (from the repo root, after `gleam build`):
%%   escript test262/runner.erl test262/suite <dir> [<dir> ...]
%% where each <dir> is relative to the suite root, e.g. test/built-ins/Math
%%
%% Per-file failure detail is written to $T262_DETAIL (default /tmp/t262_detail.txt)
%% and a per-area table (sorted by fixable failures) is printed to help pick the
%% next issue area to work on.

-mode(compile).

shim() ->
    <<"function $sv(a,e){ if(a===e){ return a!==0||1/a===1/e; } return a!==a&&e!==e; }\n"
      "function assert(c,m){ if(c!==true) throw \"T262FAIL\"; }\n"
      "function assertSameValue(a,e,m){ if(!$sv(a,e)) throw \"T262FAIL\"; }\n"
      "function assertNotSameValue(a,e,m){ if($sv(a,e)) throw \"T262FAIL\"; }\n"
      "function assertThrows(T,fn,m){ try{ fn(); }catch(e){ return; } throw \"T262FAIL\"; }\n"
      "function assertCompareArray(a,e,m){ if(a.length!==e.length) throw \"T262FAIL\"; for(let i=0;i<a.length;i++){ if(!$sv(a[i],e[i])) throw \"T262FAIL\"; } }\n">>.

main([Root | Dirs]) when Dirs =/= [] ->
    code:add_pathsz(filelib:wildcard("build/dev/erlang/*/ebin")),
    DetailPath = os:getenv("T262_DETAIL", "/tmp/t262_detail.txt"),
    Files0 = lists:flatmap(
        fun(D) -> filelib:wildcard(filename:join([Root, D, "**", "*.js"])) end, Dirs),
    Files = [F || F <- Files0, not is_fixture(F)],
    io:format("~p test files across ~p dir(s); detail -> ~s~n",
        [length(Files), length(Dirs), DetailPath]),
    {ok, Log} = file:open(DetailPath, [write, {encoding, utf8}]),
    {Tally, Areas} = lists:foldl(
        fun({F, N}, {T, A}) ->
            {Outcome, Detail} = run_one(F, N),
            case is_skip(Outcome) orelse Outcome =:= pass of
                true -> ok;
                false ->
                    DB = iolist_to_binary(Detail),
                    io:format(Log, "~-22s ~s :: ~ts~n",
                        [Outcome, rel(Root, F),
                         binary:part(DB, 0, min(180, byte_size(DB)))])
            end,
            {bump(Outcome, T), tally_area(area_of(Root, F), Outcome, A)}
        end, {#{}, #{}}, lists:zip(Files, lists:seq(1, length(Files)))),
    file:close(Log),
    print_summary(Tally),
    print_areas(Areas);
main(_) ->
    io:format("usage: escript test262/runner.erl <suite-root> <dir> [<dir>...]~n"
              "  e.g. escript test262/runner.erl test262/suite test/built-ins/Math~n").

bump(K, M) -> maps:update_with(K, fun(X) -> X + 1 end, 1, M).

is_skip(O) -> lists:member(O, [skip_flag, skip_include, skip_negative]).

print_summary(Tally) ->
    Order = [pass, fail_assert, runtime_error, compile_unsupported, compile_parse,
             compile_backend, compile_lower_other, compile_other,
             skip_flag, skip_include, skip_negative],
    io:format("~n==== RESULTS ====~n"),
    [io:format("  ~-20s ~p~n", [K, maps:get(K, Tally, 0)]) || K <- Order],
    Total = maps:fold(fun(_, V, A) -> A + V end, 0, Tally),
    Ran = maps:get(pass, Tally, 0) + maps:get(fail_assert, Tally, 0)
        + maps:get(runtime_error, Tally, 0),
    io:format("  ~-20s ~p~n", [total, Total]),
    io:format("~n  RAN (loaded+executed): ~p   PASS: ~p   => ~.1f% of run~n",
        [Ran, maps:get(pass, Tally, 0), pct(maps:get(pass, Tally, 0), Ran)]),
    io:format("  PASS as %% of ALL files: ~.1f%~n",
        [pct(maps:get(pass, Tally, 0), Total)]).

%% Per-area table sorted by "fixable" (non-pass, non-skip) failures descending —
%% the areas with the most reachable work.
print_areas(Areas) ->
    Rows = [{Area, maps:get(fixable, M, 0), maps:get(pass, M, 0),
             maps:get(ran, M, 0)}
            || {Area, M} <- maps:to_list(Areas)],
    Sorted = lists:reverse(lists:keysort(2, Rows)),
    io:format("~n==== AREAS (most fixable failures first) ====~n"),
    io:format("  ~-42s ~8s ~6s ~6s~n", ["area", "fixable", "pass", "ran"]),
    [io:format("  ~-42s ~8p ~6p ~6p~n", [A, Fx, P, R])
     || {A, Fx, P, R} <- lists:sublist(Sorted, 25), Fx > 0].

tally_area(Area, Outcome, Acc) ->
    M0 = maps:get(Area, Acc, #{}),
    M1 = case Outcome of
        pass -> inc(inc(M0, pass), ran);
        fail_assert -> inc(inc(M0, fixable), ran);
        runtime_error -> inc(inc(M0, fixable), ran);
        _ ->
            case is_skip(Outcome) of
                true -> M0;
                false -> inc(M0, fixable)  %% compile_* failures
            end
    end,
    maps:put(Area, M1, Acc).

inc(M, K) -> maps:update_with(K, fun(X) -> X + 1 end, 1, M).

pct(_, 0) -> 0.0;
pct(A, B) -> 100.0 * A / B.

is_fixture(F) -> lists:suffix("_FIXTURE.js", filename:basename(F)).

rel(Root, F) -> string:prefix(F, Root ++ "/").

%% Area = the path under `test/`, first three segments (e.g. built-ins/Array/prototype).
area_of(Root, F) ->
    Rel = case rel(Root, F) of nomatch -> F; R -> R end,
    Parts = filename:split(filename:dirname(Rel)),
    Trimmed = case Parts of ["test" | Rest] -> Rest; P -> P end,
    string:join(lists:sublist(Trimmed, 3), "/").

run_one(File, N) ->
    {ok, Bin} = file:read_file(File),
    Src = unicode:characters_to_binary(Bin),
    {Meta, Body} = split_frontmatter(Src),
    case classify_skip(Meta) of
        {skip, Why} -> {Why, ""};
        run ->
            Full = <<(shim())/binary, "\n", (rewrite(Body))/binary>>,
            ModName = list_to_binary("twocore@t262@m" ++ integer_to_list(N)),
            try twocore@frontend@js:compile_and_load(Full, ModName) of
                {ok, Mod} -> execute(Mod);
                {error, Err} -> classify_compile_error(Err)
            catch
                Ce:Re -> {compile_other, io_lib:format("~p:~p", [Ce, Re])}
            end
    end.

execute(Mod) ->
    try erlang:apply(Mod, main, []) of
        _ -> {pass, ""}
    catch
        C:R ->
            RStr = lists:flatten(io_lib:format("~p ~p", [C, R])),
            case string:find(RStr, "T262FAIL") of
                nomatch -> {runtime_error, RStr};
                _ -> {fail_assert, ""}
            end
    end.

classify_compile_error({parse_error, B}) -> {compile_parse, B};
classify_compile_error({lower_error, B}) ->
    case string:find(B, "unsupported") of
        nomatch -> {compile_lower_other, B};
        _ -> {compile_unsupported, B}
    end;
classify_compile_error({backend_error, B}) -> {compile_backend, B};
classify_compile_error(Other) -> {compile_other, io_lib:format("~p", [Other])}.

%% Frontmatter is the YAML between `/*---` and `---*/`.
split_frontmatter(Src) ->
    case string:split(Src, "/*---") of
        [_Pre, Rest] ->
            case string:split(Rest, "---*/") of
                [Meta, Body] -> {Meta, Body};
                _ -> {<<>>, Src}
            end;
        _ -> {<<>>, Src}
    end.

classify_skip(Meta) ->
    Flags = bracket_list(Meta, "flags"),
    Includes = bracket_list(Meta, "includes"),
    HasNegative = string:find(Meta, "negative:") =/= nomatch,
    Bad = ["module", "raw", "async", "onlyStrict", "CanBlockIsFalse"],
    AllowedIncl = ["compareArray.js"],
    case {lists:any(fun(F) -> lists:member(F, Bad) end, Flags),
          HasNegative,
          [I || I <- Includes, not lists:member(I, AllowedIncl)]} of
        {true, _, _} -> {skip, skip_flag};
        {_, true, _} -> {skip, skip_negative};
        {_, _, [_ | _]} -> {skip, skip_include};
        _ -> run
    end.

bracket_list(Meta, Key) ->
    case re:run(Meta, Key ++ ":\\s*\\[([^\\]]*)\\]",
                [{capture, [1], list}, dotall]) of
        {match, [Inner]} ->
            [string:trim(T) || T <- string:split(Inner, ",", all), T =/= ""];
        nomatch -> []
    end.

rewrite(Body) ->
    L1 = re:replace(Body, "assert\\.sameValue\\(", "assertSameValue(", [global]),
    L2 = re:replace(L1, "assert\\.notSameValue\\(", "assertNotSameValue(", [global]),
    L3 = re:replace(L2, "assert\\.throws\\(", "assertThrows(", [global]),
    L4 = re:replace(L3, "assert\\.compareArray\\(", "assertCompareArray(", [global]),
    iolist_to_binary(L4).
