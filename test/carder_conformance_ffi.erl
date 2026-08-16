%% Test-only FFI shim for the unit-07 conformance harness.
%%
%% Hand-written Erlang, so it carries the `carder_` namespace prefix (overview §5).
%% It lives under `test/` and exists ONLY to give the Gleam conformance harness the
%% few host capabilities Gleam's stdlib does not provide: invoking a freshly-loaded
%% generated module while catching a trap, reading fixture files from disk, parsing
%% JSON (via OTP's built-in `json`), listing a directory, and shelling out to the
%% Tier-B reference engine. It touches no unit-owned source file.
-module(carder_conformance_ffi).
-export([catch_apply/3, read_file/1, parse_json/1, list_dir/1, run/2,
         find_executable/1, unique_int/0,
         start_instance/1, start_instance_with/2, call_instance/3,
         result_list/2, extern_payload/1, gc_classify/1, stop_instance/1,
         gc_and_memory/1, spy_reset/0, spy_mark/0, spy_called/0]).

%% Force a garbage collection on process Pid, then report its total memory in bytes
%% (heap + stack + message queue + pdict). Used by the constant-space store-loop test to
%% assert the `cell` state strategy does not accumulate per-iteration memory — after GC,
%% a constant-space loop's live memory is bounded by the (constant) page-map, not the
%% iteration count. Returns 0 for a dead process.
gc_and_memory(Pid) ->
    erlang:garbage_collect(Pid),
    case erlang:process_info(Pid, memory) of
        {memory, M} -> M;
        undefined -> 0
    end.

%% ── one-instance-one-process run-ABI (unit 11, E1/E5) ───────────────────────
%%
%% The instance's mutable state (memory page-map, mutable globals, table) lives in
%% the process dictionary of ONE owned process (the `cell` strategy). So an
%% instance's `instantiate/0` AND every one of its invokes must run in that SAME
%% process, or an export reads the caller's empty pdict and returns garbage. These
%% three functions give the Gleam driver/pipeline that owned process:
%%
%%   start_instance(Module) -> {ok, Pid} | {error, Reason}
%%       spawn a process; run Module:instantiate() IN it (seeds ITS pdict cell).
%%       An instantiation-time trap (OOB active segment / trapping start) replies
%%       {error, RenderedReason} and the process exits. On success the process
%%       enters a receive loop holding the cell for the instance's lifetime.
%%   call_instance(Pid, Fun, Args) -> {ok, V} | {error, Reason}
%%       message round-trip: the instance process runs apply(Module, Fun, Args) in
%%       ITS OWN process (reads ITS cell) and replies. A trap is {error, Reason}.
%%   stop_instance(Pid) -> nil
%%       ask the process to exit; its pdict cell is auto-GC'd with it.
%%
%% (Re)instantiating a module starts a FRESH process → a FRESH zeroed cell, so
%% per-instance isolation + reset-on-(re)instantiation are automatic, and
%% cross-invoke state PERSISTS because successive invokes hit the same process.

%% Spawn the instance process and run instantiate/0 in it, blocking until the
%% process reports whether instantiation succeeded or trapped.
%%
%% Strategy-aware (unit P4-08 §C.2 / unit P4-09), mirroring the CLI shim
%% `carder_cli_ffi`: the state strategy is self-detected from `instantiate/0`'s
%% RETURN value, so the conformance driver drives BOTH calling conventions with no
%% per-strategy code in Gleam and no `Binding` parameter on the run-ABI. The atom
%% `'ok'` → the `Cell` loop (state in the pdict cell); the `{instance_state,_,_,_}`
%% record → the `Threaded` loop carrying that record as a value (the tier-P
%% runs-anywhere build, no pdict instance cell). Any other shape is a fail-closed
%% error (never assumed Cell). The `Cell` path is byte-identical to the previous
%% Cell-only shim, so the Phase-1/2/3 corpus + spec suite are unaffected; the
%% `Threaded` branch is purely additive (unit P4-09 is the first to drive the whole
%% corpus under `Threaded` through this driver, and unit 11 reuses it).
start_instance(Module) ->
    start_common(Module, fun() -> Module:instantiate() end).

%% Like start_instance/1, but for an import-bearing module whose generated entry is
%% `instantiate/1(Imports)` (unit P5-11 / R4): run `Module:instantiate(Imports)` in the
%% owned process, where `Imports` is the positional `[Provided ...]` list `link:link_imports`
%% returned (handed over opaquely as one Dynamic argument). The same cell/threaded
%% self-detection + receive loop as start_instance/1 — the ABI difference is only the arity of
%% the instantiate call.
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
                _Class:Reason -> {error, render_reason(Reason)}
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
                        "unexpected instantiate/0 return: ~0p", [Other]))}};
            {error, _} = Err ->
                Parent ! {started, self(), Err}
        end
    end),
    receive
        {started, Pid, ok} -> {ok, Pid};
        {started, Pid, {error, Why}} -> {error, Why}
    end.

%% Run apply(Module, Fun, Args) inside the instance's own process and return its
%% outcome to the caller; a trap surfaces as {error, RenderedReason}.
call_instance(Pid, Fun, Args) ->
    Ref = make_ref(),
    Pid ! {invoke, Fun, Args, self(), Ref},
    receive
        {result, Ref, Result} -> Result
    end.

%% Unpack an invoke result PACKAGE into a flat list of its `Arity` values (unit P5-11, the
%% multi-value run-ABI R17). A generated function returns exactly one BEAM term, so the WASM
%% result vector is packaged at the boundary: 0 results → a unit placeholder (dropped here → []);
%% 1 result → the bare value ([V]); N≥2 results → an N-tuple `{V1,…,Vn}` (destructured with
%% tuple_to_list). This is symmetric across the Cell and Threaded ABIs (the Threaded loop already
%% unwrapped `{Package, St'}` to `Package`, which is exactly this same package). Each element is a
%% raw value / IEEE-754 bit pattern (numeric) or a reference term (rt_ref shape).
result_list(Arity, V) ->
    case Arity of
        0 -> [];
        1 -> [V];
        _ -> tuple_to_list(V)
    end.

%% Extract the host-identity payload of an externref `{ref_extern, T}` (unit P5-11 / R18) —
%% the `N` a `ref.extern N` carried, so the harness can compare a returned externref by IDENTITY
%% (`rt_ref:classify_ref` reports it is an externref; this reads which one). Called only after
%% classify says ExternRef, so the match always succeeds; the fallback keeps it total.
extern_payload({ref_extern, T}) -> T;
extern_payload(_) -> 0.

%% Classify a returned GC reference term into a coarse kind string (Phase-8 GC), for the
%% conformance oracle. Structural only — it NEVER dereferences the instance's arena (that lives in
%% the instance's own process dictionary; a returned `{gc, Id}` handle is a dangling id here,
%% R-GC1), so a bare 2-tuple `{gc, Id}` classifies coarsely as `<<"gc_heap">>`. A future engine
%% handle retag to `{gc, struct|array, Id}` self-describes across the process copy and is matched
%% here first (`gc_struct`/`gc_array`) so this reads precise kinds with no further change.
gc_classify({ref_null})          -> <<"null">>;
gc_classify({i31, _})            -> <<"i31">>;
gc_classify({gc, struct, _})     -> <<"gc_struct">>;
gc_classify({gc, array, _})      -> <<"gc_array">>;
gc_classify({gc, _})             -> <<"gc_heap">>;
gc_classify({ref_extern, _})     -> <<"extern">>;
gc_classify({ref_exn, _})        -> <<"exn">>;
gc_classify(_)                   -> <<"func">>.

%% Ask the instance process to exit (its pdict cell is GC'd with it).
stop_instance(Pid) ->
    Pid ! stop,
    nil.

%% The `Cell` instance process's receive loop: it owns the seeded pdict cell and
%% runs every invoke in-process so each one reads ITS state (arity-stable
%% `Module:Fun(Args)`).
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
        stop ->
            ok
    end.

%% The `Threaded` instance loop (unit P4-08 §C / unit P4-09), mirroring the CLI shim
%% `carder_cli_ffi:threaded_loop/2`. Holds the purely-functional `InstanceState`
%% record `St` as a loop variable — no pdict instance cell. Every export presents the
%% uniform threaded ABI `Module:Fun(St, Args…) -> {Package, St'}`: apply with `St`
%% LEADING, extract the `{Package, St'}` pair, reply with `Package` (the SAME value
%% shape the Cell loop returns, so the Gleam driver reads both identically), and
%% RECURSE carrying `St'` — so cross-invoke state persists as a value. A trap /
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
        stop ->
            ok
    end.

%% Render a caught trap/exit reason as a UTF-8 binary so the Gleam caller can
%% substring-match the spec trap phrase (e.g. `{wasm_trap, memory_out_of_bounds}`).
render_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).

%% A one-bit per-process spy used by the routing self-test to PROVE the partition:
%% `assert_invalid`/`assert_malformed` must reach only `check_frontend`, never
%% `instantiate`. `spy_mark/0` is wired into a spy driver's `instantiate`; after a run
%% the test asserts `spy_called/0` is still `false`. Process-local (gleeunit runs each
%% test synchronously in one process), so no cross-test bleed.
spy_reset() -> erlang:put(carder_spy_instantiate, false), nil.
spy_mark() -> erlang:put(carder_spy_instantiate, true), nil.
spy_called() -> erlang:get(carder_spy_instantiate) =:= true.

%% A process-independent strictly-positive unique integer. The harness appends it to
%% a generated module's name so that loading many modules from one `.wast` file (a
%% multi-module fixture, e.g. const/traps) does not collide on a single BEAM module
%% name and clobber earlier loads (`code:load_binary` replaces by name).
unique_int() ->
    erlang:unique_integer([positive, monotonic]).

%% Apply M:F(Args). On a normal return yield `{ok, V}` (a Gleam `Ok`); if the call
%% raises/exits/throws, yield `{error, Reason}` (a Gleam `Error`) with `Reason`
%% rendered as a UTF-8 binary so the caller can substring-match the trap text (e.g.
%% that a div-by-zero surfaced as `{wasm_trap, int_div_by_zero}`). `V` is whatever
%% the generated function returned — for the Phase-1 numeric surface that is an
%% Erlang integer (the raw value/bit pattern, per D5); the Gleam caller only reads it
%% as an integer when the spec expects a single numeric result.
catch_apply(M, F, Args) ->
    try erlang:apply(M, F, Args) of
        V -> {ok, V}
    catch
        _Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}
    end.

%% Read a file's raw bytes. `{ok, Binary}` (a Gleam `Ok(BitArray)`) or `{error, Msg}`
%% (a Gleam `Error(String)`) with the POSIX reason rendered as text. Used to load the
%% vendored `.wasm`/`.json` fixtures and the corpus `.wasm`/`.expected` files.
read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Parse a JSON binary into an Erlang term (maps with binary keys, lists, binaries,
%% integers) using OTP's built-in `json:decode/1`. `{ok, Term}` (a Gleam
%% `Ok(Dynamic)`) or `{error, Msg}` on malformed JSON. wast2json output is well-formed
%% and keeps every numeric value as a STRING, so numbers never lose precision here.
parse_json(Bin) ->
    try json:decode(Bin) of
        Term -> {ok, Term}
    catch
        _Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% List a directory's entries (file names only, not full paths). `{ok, [Binary]}` or
%% `{error, Msg}`. Used to discover which `*.json` fixtures are present so the runner
%% adapts to the committed curated subset or a freshly re-vendored full set.
list_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            {ok, [unicode:characters_to_binary(N) || N <- Names]};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Resolve an executable's absolute path via PATH. `{ok, PathBinary}` if found,
%% `{error, <<"not found">>}` otherwise. Lets the Tier-B wasmtime adapter SKIP
%% gracefully (rather than fail the suite) when the engine is not installed.
find_executable(Name) ->
    case os:find_executable(unicode:characters_to_list(Name)) of
        false -> {error, <<"not found">>};
        Path -> {ok, unicode:characters_to_binary(Path)}
    end.

%% Run an external program with a list of string arguments, capturing combined
%% stdout+stderr and the exit status. Returns `#{exit => Int, output => Binary}` as a
%% 2-tuple `{Exit, Output}` (a Gleam `#(Int, String)`). stderr is folded into stdout
%% so a `wasmtime` trap line ("wasm trap: ...") and a normal result line are both
%% visible to the Tier-B adapter. Tier-B only — never on the Tier-A path.
run(Program, Args) ->
    Exe = unicode:characters_to_list(Program),
    ArgL = [unicode:characters_to_list(A) || A <- Args],
    Port = erlang:open_port(
        {spawn_executable, Exe},
        [{args, ArgL}, exit_status, stderr_to_stdout, binary, hide]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, Bytes}} -> collect(Port, <<Acc/binary, Bytes/binary>>);
        {Port, {exit_status, Code}} -> {Code, Acc}
    end.
