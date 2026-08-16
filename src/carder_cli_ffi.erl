%% Unit 11c — CLI / run-invoke FFI shim (the catching-apply seam for `pipeline:invoke`).
%%
%% Hand-written Erlang, so it carries the `carder_` namespace prefix (overview §5), never
%% `lists`/`maps`/`erlang`. It exists only so the run/invoke ABU (`pipeline.gleam`) can
%% apply a freshly-loaded generated export and capture a trap / capability-denial WITHOUT
%% crashing the calling process — Gleam on OTP 29 has no generic exception rescue in this
%% dependency set (gleam_erlang 1.3), so the catch must live in Erlang.
%%
%% The doc (11d) asked unit 04 to add a catching-apply path to its `carder_codegen_ffi`
%% shim; that seam was not present and 04's file is single-owned (D1, must not be edited),
%% so the seam is provided here instead. It touches no unit-owned source file.
-module(carder_cli_ffi).
-export([catch_apply/3, start_instance/1, start_instance_with/2,
         call_instance/3, stop_instance/1, module_name/1, bench_instance/4,
         porffor_output/1, mem_size/1]).

%% Apply Mod:Fun(Args) on the loaded generated module. On a normal return yield
%% `{ok, V}` (a Gleam `Ok(Int)`) where V is the result rendered as an integer (the raw
%% value / IEEE-754 bit pattern, per D5). If the call raises/exits/throws — a trap raised
%% by `rt_trap` as error-class `{wasm_trap, Kind}`, or a deny-all `{capability_denied,
%% Cap, Name}` — yield `{error, Reason}` (a Gleam `Error(String)`) with Reason rendered as
%% a UTF-8 binary so the caller can substring-match the spec trap phrase. Never crashes the
%% caller.
catch_apply(Mod, Fun, Args) ->
    try erlang:apply(Mod, Fun, Args) of
        V -> {ok, V}
    catch
        _Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}
    end.

%% ── one-instance-one-process run-ABI (unit 11 E1/E5; unit P4-08 threaded ABI) ─
%%
%% One instance is ONE owned process. Two calling conventions, self-detected from
%% `instantiate/0`'s RETURN value (unit P4-08 §C.2) — the run-ABI stays
%% signature-stable, so `pipeline.gleam` never grows a `Binding` parameter:
%%
%%   * `Cell` (state_strategy: Cell — the Phase-2/3 default). The instance's mutable
%%     state (memory page-map, mutable globals, table) lives in the process
%%     DICTIONARY. `instantiate/0` seeds the cell and returns the atom `'ok'`; each
%%     invoke applies `Module:Fun(Args)` in that same process (`instance_loop`), so
%%     the export reads this instance's pdict cell and cross-invoke state persists.
%%
%%   * `Threaded` (state_strategy: Threaded — the tier-P runs-anywhere build). The
%%     instance state travels as a PURELY-FUNCTIONAL `InstanceState` record (Gleam
%%     tuple `{instance_state, Mem, Globals, Table}`), never in the pdict.
%%     `instantiate/0` RETURNS that record; each export presents the uniform threaded
%%     ABI `Module:Fun(St, Args…) -> {Package, St'}` (unit 02). `threaded_loop`
%%     HOLDS the record as a loop variable, passes it LEADING to every invoke,
%%     extracts the `{Package, St'}` pair, and threads `St'` into the next invoke —
%%     so state persists across invokes as a value, not in a cell. The harness needs
%%     NO per-export arity/classification knowledge: every export is uniform.
%%
%%   start_instance(Module) -> {ok, Pid} | {error, Reason}   %% spawn + instantiate IN it
%%   call_instance(Pid, Fun, Args) -> {ok, V} | {error, Reason}   %% apply IN it
%%   stop_instance(Pid) -> nil.                              %% exit → cell/record GC'd

%% Spawn the instance process and run instantiate/0 in it; block until it reports
%% success or an instantiation-time trap. Discriminate the state strategy from the
%% return value: the atom `'ok'` → the `Cell` loop; the `{instance_state,_,_,_}`
%% record → the `Threaded` loop carrying that record. Any other shape is a
%% fail-closed error (never assumed Cell).
start_instance(Module) ->
    start_common(Module, fun() -> Module:instantiate() end).

%% Like start_instance/1, but for an IMPORT-BEARING module whose generated entry is
%% `instantiate/1(Imports)` (P7-08 / R4): run `Module:instantiate(Imports)` in the owned
%% process, where `Imports` is the positional `[Provided ...]` list link:link_imports +
%% link:link_func_imports returned (handed over opaquely as one argument). Same cell/threaded
%% self-detection + receive loop as start_instance/1 — the ABI difference is only the arity of
%% the instantiate call. Used by pipeline:run_porffor for a Porffor module (which imports its
%% console intrinsics from module "").
start_instance_with(Module, Imports) ->
    start_common(Module, fun() -> Module:instantiate(Imports) end).

%% Shared spawn+seed+loop for both the arity-0 and arity-1 instantiate ABIs. `RunInstantiate`
%% is a 0-arg fun that performs the generated `instantiate/0` or `instantiate/1(Imports)` IN the
%% spawned process (so it seeds THAT process's cell / builds THAT record).
start_common(Module, RunInstantiate) ->
    Parent = self(),
    Pid = spawn(fun() ->
        Outcome =
            try RunInstantiate() of
                Ret -> {ok, Ret}
            catch
                _Class:Reason:Stack -> {error, render_reason(Reason, Stack)}
            end,
        case Outcome of
            {ok, ok} ->
                Parent ! {started, self(), ok},
                instance_loop(Module);
            {ok, St} when is_tuple(St), element(1, St) =:= instance_state ->
                %% Match the `InstanceState` record by its TAG, not its arity — the
                %% Phase-5 record grew (multi-memory/table vectors + drop-state +
                %% ref-globals), so an arity-fixed `{instance_state,_,_,_}` pattern would
                %% wrongly fall through to the fail-closed branch below.
                Parent ! {started, self(), ok},
                threaded_loop(Module, St);
            {ok, Other} ->
                Parent ! {started, self(),
                    {error, unicode:characters_to_binary(io_lib:format(
                        "unexpected instantiate return: ~0p", [Other]))}};
            {error, _} = Err ->
                Parent ! {started, self(), Err}
        end
    end),
    receive
        {started, Pid, ok} -> {ok, Pid};
        {started, Pid, {error, Why}} -> {error, Why}
    end.

%% Run apply(Module, Fun, Args) inside the instance's own process; a trap surfaces
%% as {error, RenderedReason}.
call_instance(Pid, Fun, Args) ->
    Ref = make_ref(),
    Pid ! {invoke, Fun, Args, self(), Ref},
    receive
        {result, Ref, Result} -> Result
    end.

%% Drain THIS instance's Porffor console output buffer (P7-08, §E/§H.2). The buffer is a
%% process-DICTIONARY cell in the instance's owned process (rt_host:append_output writes it
%% during a print/printChar intrinsic call), so it MUST be read IN that process — this routes a
%% {porffor_output, ...} message into the instance loop, which runs rt_host:porffor_output/0
%% there and replies with the raw byte stream (a binary). Returns <<>> for a never-printed
%% instance. Used by pipeline:run_porffor after invoking the entry `m`.
porffor_output(Pid) ->
    Ref = make_ref(),
    Pid ! {porffor_output, self(), Ref},
    receive
        {porffor_output_reply, Ref, Bin} -> Bin
    end.

%% Read the module name baked into a .beam binary (needed to load a prebuilt .beam whose
%% filename need not match its module name). Returns {ok, BinaryName} | {error, Binary}.
module_name(Bin) ->
    try beam_lib:version(Bin) of
        {ok, {Mod, _}} -> {ok, atom_to_binary(Mod, utf8)};
        {error, beam_lib, R} ->
            {error, unicode:characters_to_binary(io_lib:format("~0p", [R]))}
    catch
        _:_ -> {error, <<"not a .beam file">>}
    end.

%% Benchmark: run Fun(Args) N times INSIDE the instance's process (so the process-local
%% memory/global cell is live) and time only the N calls. Returns {ok, {Micros, LastResult}}
%% | {error, RenderedReason}. Micros is the wall time (microseconds) for all N invocations,
%% excluding load/instantiate and the message round-trip (which happens once).
bench_instance(Pid, Fun, Args, N) ->
    Ref = make_ref(),
    Pid ! {bench, Fun, Args, N, self(), Ref},
    receive
        {result, Ref, Result} -> Result
    end.

%% Ask the instance process to exit (its pdict cell is GC'd with it).
stop_instance(Pid) ->
    Pid ! stop,
    nil.

%% Ask the instance process to report memory 0's size (64 KiB pages), read IN that
%% process so it reflects the guest's real linear-memory footprint (the Cell mem cell
%% / Threaded state record are both process-local). A memory-less guest reports 0.
%% Backs embed:mem_size / pipeline:mem_size_instance.
mem_size(Pid) ->
    %% Monitor so a DEAD guest yields 0 instead of blocking forever (the guest is
    %% spawned unlinked/unmonitored, so a bare `receive` would wait on a reply that
    %% never comes). A LIVE-but-busy guest still serialises behind its in-flight
    %% invoke — correct, and the sole driver (the dance actor) is itself blocked
    %% during an invoke, so it cannot race a mem_size against one.
    Ref = monitor(process, Pid),
    Pid ! {mem_size, self(), Ref},
    receive
        {mem_size_reply, Ref, Pages} ->
            demonitor(Ref, [flush]),
            Pages;
        {'DOWN', Ref, process, Pid, _} -> 0
    end.

instance_loop(Module) ->
    receive
        {invoke, Fun, Args, From, Ref} ->
            Result =
                try erlang:apply(Module, Fun, Args) of
                    V -> {ok, V}
                catch
                    _Class:Reason -> {error, render_reason(Reason)}
                end,
            From ! {result, Ref, Result},
            instance_loop(Module);
        {bench, Fun, Args, N, From, Ref} ->
            Result =
                try
                    T0 = erlang:monotonic_time(microsecond),
                    Last = bench_loop(Module, Fun, Args, N, undefined),
                    T1 = erlang:monotonic_time(microsecond),
                    {ok, {T1 - T0, Last}}
                catch
                    _Class:Reason -> {error, render_reason(Reason)}
                end,
            From ! {result, Ref, Result},
            instance_loop(Module);
        {porffor_output, From, Ref} ->
            %% Read this instance's Porffor console buffer IN this process (P7-08 §E). The
            %% rt_host module reference is build-fixed (never a data-derived atom, D3a).
            Bin = try 'carder@runtime@rt_host':porffor_output()
                  catch _:_ -> <<>> end,
            From ! {porffor_output_reply, Ref, Bin},
            instance_loop(Module);
        {mem_size, From, Ref} ->
            %% Report memory 0's size in 64 KiB pages, read IN this process (the Cell
            %% memory lives in this process's dictionary). A memory-less guest → 0.
            %% D3a: the rt_mem module reference is build-fixed, never data-derived.
            Pages = try 'carder@runtime@rt_mem':size()
                    catch _:_ -> 0 end,
            From ! {mem_size_reply, Ref, Pages},
            instance_loop(Module);
        stop ->
            ok
    end.

bench_loop(_M, _F, _A, 0, Last) -> Last;
bench_loop(M, F, A, N, _) ->
    R = erlang:apply(M, F, A),
    bench_loop(M, F, A, N - 1, R).

%% The `Threaded` instance loop (unit P4-08 §C). Holds the `InstanceState` record
%% `St` as a loop variable. Every export presents the uniform threaded ABI
%% `Module:Fun(St, Args…) -> {Package, St'}`: apply with `St` LEADING, extract the
%% `{Package, St'}` pair, reply with `Package` (the same value shape the Cell loop
%% returns — bare value / `'ok'` / N-tuple), and RECURSE carrying `St'`, so the next
%% invoke sees the updated state (cross-invoke persistence as a value). A trap /
%% capability-denial replies `{error, Reason}` and recurses with the UNCHANGED `St`
%% (trap-before-write — the failed op mutated nothing).
threaded_loop(Module, St) ->
    receive
        {invoke, Fun, Args, From, Ref} ->
            Outcome =
                try erlang:apply(Module, Fun, [St | Args]) of
                    {Pkg, St2} -> {ok, Pkg, St2}
                catch
                    _Class:Reason -> {error, render_reason(Reason)}
                end,
            case Outcome of
                {ok, Result, NextSt} ->
                    From ! {result, Ref, {ok, Result}},
                    threaded_loop(Module, NextSt);
                {error, _} = Err ->
                    From ! {result, Ref, Err},
                    threaded_loop(Module, St)
            end;
        {bench, Fun, Args, N, From, Ref} ->
            Outcome =
                try
                    T0 = erlang:monotonic_time(microsecond),
                    {Last, StN} = threaded_bench_loop(Module, Fun, Args, N, undefined, St),
                    T1 = erlang:monotonic_time(microsecond),
                    {ok, T1 - T0, Last, StN}
                catch
                    _Class:Reason -> {error, render_reason(Reason)}
                end,
            case Outcome of
                {ok, Micros, LastResult, NextSt} ->
                    From ! {result, Ref, {ok, {Micros, LastResult}}},
                    threaded_loop(Module, NextSt);
                {error, _} = Err ->
                    From ! {result, Ref, Err},
                    threaded_loop(Module, St)
            end;
        {porffor_output, From, Ref} ->
            %% Same Porffor console drain as the Cell loop (P7-08 §E); the buffer is a
            %% process-local pdict cell independent of the threaded InstanceState record.
            Bin = try 'carder@runtime@rt_host':porffor_output()
                  catch _:_ -> <<>> end,
            From ! {porffor_output_reply, Ref, Bin},
            threaded_loop(Module, St);
        {mem_size, From, Ref} ->
            %% Threaded twin of the Cell `mem_size`: memory 0 lives in the `St`
            %% record, so read its page count via rt_mem:t_size/1. Memory-less → 0.
            Pages = try 'carder@runtime@rt_mem':t_size(St)
                    catch _:_ -> 0 end,
            From ! {mem_size_reply, Ref, Pages},
            threaded_loop(Module, St);
        stop ->
            ok
    end.

threaded_bench_loop(_M, _F, _A, 0, Last, St) -> {Last, St};
threaded_bench_loop(M, F, A, N, _, St) ->
    {R, St2} = erlang:apply(M, F, [St | A]),
    threaded_bench_loop(M, F, A, N - 1, R, St2).

render_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
render_reason(Reason, Stack) ->
    Top = case Stack of [F|_] -> F; _ -> none end,
    unicode:characters_to_binary(io_lib:format("~0p @ ~0p", [Reason, Top])).
