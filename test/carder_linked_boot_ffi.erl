%%% carder_linked_boot_ffi — the bare-node isolation boot harness (Phase 11 · P11-05).
%%%
%%% TRUST BOUNDARY: this is TEST-ONLY infrastructure. It is NOT the OTP-compiler-
%%% internals trust boundary of `src/carder_linker_ffi.erl`/`carder_codegen_ffi.erl`
%%% — it only uses `os`, `file`/`filelib`, `compile`, `code`, `unicode`, and
%%% `erlang`/`erlang:open_port`. Its job is to PROVE, by measurement, that a linked
%%% `.beam` is genuinely self-contained: it spawns a FRESH OS `erl` (not an in-VM
%%% peer/slave node — those can share the parent's `ERL_LIBS`/paths) with a scrubbed
%%% environment and an isolated code path containing ONLY the module under test, then
%%% runs an in-child `code:which/1` gate over a representative closure set that HALTS
%%% NONZERO on any hit. Isolation is therefore measured, never assumed: a leaky path
%%% fails loudly (exit 3) instead of yielding a false green.
%%%
%%% Namespace: hand-written Erlang under `test/`, so it carries the `carder_` prefix
%%% (same convention as the seven existing `test/carder_*_ffi.erl` shims). It touches
%%% no unit-owned source file.
%%%
%%% Frozen public API (`«BARE-NODE-HARNESS-PROVEN»`), consumed by P11-06 · L2:
%%%   compile_source/2  — manufacture a fixture `.beam` from Erlang source (no linker).
%%%   boot_invoke/5     — boot a `.beam` on a scrubbed/isolated child, seed-then-call.
%%%   which_in_parent/1 — `code:which/1` in the PARENT (anti-vacuity: prove gate atoms real).
%%%
%%% Frozen exit-code + stdout contract of the child spawned by boot_invoke/5:
%%%   {0,   <<"RESULT:<~0p of package>\n">>}  — ran clean (gate passed, export returned)
%%%   {0,   <<"TRAP:<~0p of reason>\n">>}     — export trapped (gate passed; a trap is not a leak)
%%%   {3,   <<"LEAK:<mod>\n">>}               — isolation gate HIT: a closure module was reachable
%%%   {4,   <<"NOLOAD:<mod>\n">>}             — the module under test was not on the child path
%%%   {124, <<...,"HARNESS:child timed out">>}— defensive: the child exceeded the bound (CI safety)
%%%   {127, <<"erl not found">>}              — no `erl` on PATH
%%% A `RESULT:` line at exit 0 PROVES isolation held, because the gate halts BEFORE the
%%% invoke on any hit — so success is unreachable while any closure module is on the path.
-module(carder_linked_boot_ffi).
-export([compile_source/2, boot_invoke/5, which_in_parent/1]).

%% Wall-clock bound (ms) on a single child. Cold `erl` start is ~sub-second; this is a
%% generous CI-robustness ceiling so a hung/never-halting child is reaped (exit 124)
%% rather than blocking the suite forever. Every well-formed fixture halts in well under
%% this, so it never fires in the normal path.
-define(CHILD_TIMEOUT_MS, 60000).

%% The representative closure set the in-child gate probes for absence. One
%% `carder@runtime@*` runtime module, one `gleam@*` module, the hand-written
%% `gleam_stdlib` FFI, and the shared `carder@ir` leaf — a cross-section of every
%% mergeable bucket in the frozen link-closure manifest (P11-02). If ANY resolves in
%% the child, `-pa`/env isolation leaked and the child halts 3. Kept as a literal in
%% the runner text (see runner/3).
%% -> ['carder@runtime@rt_mem', 'gleam@list', gleam_stdlib, 'carder@ir']

%% ─────────────────────────── compile_source/2 ───────────────────────────

%% Compile hand-authored Erlang `Source` (whose `-module` MUST be `ModuleName`) into a
%% `.beam` binary, deterministically, WITHOUT the linker (P11-03). Lets the self-test
%% manufacture genuinely-self-contained fixture `.beam`s (and, in the negative test, a
%% stub `carder@` leak module) at test time.
%%
%% Params:
%%   ModuleName :: atom()  — the fixture module atom; the on-disk `.erl` base name is
%%                           `atom_to_list(ModuleName)`, so it MUST equal the source's
%%                           `-module(...)` or `compile` warns/errors.
%%   Source     :: binary()— UTF-8 Erlang source text.
%% Returns (Gleam `Result(BitArray, String)`):
%%   {ok, Beam :: binary()}          — the compiled module binary.
%%   {error, Reason :: binary()}     — compile errors, rendered as UTF-8 text.
%% Failure modes: a temp-dir write failure crashes (`ok = …` match) — a genuinely broken
%% environment, not an expected error. Compile errors are returned as `{error, _}`.
compile_source(ModuleName, Source) ->
    Dir = fresh_dir("carder_boot_src"),
    ok = filelib:ensure_dir(filename:join(Dir, "keep")),
    Base = filename:join(Dir, atom_to_list(ModuleName)),
    ErlFile = Base ++ ".erl",
    ok = file:write_file(ErlFile, Source),
    Result =
        case compile:file(Base, [binary, return_errors, return_warnings, deterministic]) of
            {ok, _Mod, Beam} -> {ok, Beam};
            {ok, _Mod, Beam, _Warnings} -> {ok, Beam};
            {error, Errors, Warnings} ->
                {error, unicode:characters_to_binary(
                    io_lib:format("compile failed: ~p (warnings: ~p)", [Errors, Warnings]))};
            error ->
                {error, <<"compile failed">>}
        end,
    _ = file:del_dir_r(Dir),
    Result.

%% ─────────────────────────── boot_invoke/5 ───────────────────────────

%% Boot `Beam` on a FRESH, environment-scrubbed, code-path-isolated `erl` and, in ONE
%% child process, run the seed-then-call protocol (R6): `ModuleName:instantiate()` to
%% seed the per-instance cell, THEN the requested export — so the pdict cell survives
%% across the two calls. Returns the child's exit status + combined stdout/stderr for
%% the parent to parse against the frozen contract (see module header).
%%
%% Isolation is IMPLEMENTED by two independent mechanisms and then MEASURED:
%%   (1) env scrub — the port `{env, …}` option removes `ERL_LIBS` (which is how the
%%       parent test VM's `…/carder/ebin` `carder@*`/`gleam@*` beams would otherwise
%%       reach a child) plus the flag-injection vectors `ERL_FLAGS`/`ERL_AFLAGS`/
%%       `ERL_ZFLAGS`; `-boot no_dot_erlang` neutralises `~/.erlang` auto-exec.
%%   (2) isolated `-pa` — only `LinkDir` (holding exactly `ModuleName.beam`) is added
%%       to the child path; `Extra` beams go on a SEPARATE `-pa ExtraDir` so the
%%       isolated case has exactly one file reachable.
%%   (measure) the in-child gate (runner/3 (b)) probes the representative closure set
%%       and halts 3 on any hit — so a future `-pa`/env regression fails here, loudly.
%%
%% Params:
%%   Beam       :: binary()               — the module-under-test `.beam`.
%%   ModuleName :: atom()                 — its module atom; `code:which/1` resolves it
%%                                          to `LinkDir/ModuleName.beam`.
%%   Fun        :: atom()                 — the export to invoke after instantiate.
%%   Args       :: [term()]               — invoke args; re-embedded via `~w`, so they
%%                                          must be re-readable terms (ints/atoms/tuples/
%%                                          lists/binaries — no pids/refs/funs).
%%   Extra      :: [{atom(), binary()}]   — extra `{Mod, Beam}` pairs written to a
%%                                          SEPARATE `-pa` dir; `[]` for the isolated
%%                                          case. The negative self-test injects a
%%                                          `carder@` module here to fire the gate.
%% Returns (Gleam `#(Int, String)`): `{ExitStatus :: integer(), Output :: binary()}`.
%% Failure modes: no `erl` on PATH -> `{127, <<"erl not found">>}` (never crashes);
%% a child exceeding `?CHILD_TIMEOUT_MS` -> `{124, …}` with the port force-closed. Temp
%% dirs are `del_dir_r`'d best-effort before returning.
boot_invoke(Beam, ModuleName, Fun, Args, Extra) ->
    case os:find_executable("erl") of
        false -> {127, <<"erl not found">>};
        Exe -> boot_invoke_1(Exe, Beam, ModuleName, Fun, Args, Extra)
    end.

boot_invoke_1(Exe, Beam, ModuleName, Fun, Args, Extra) ->
    LinkDir = fresh_dir("carder_boot_link"),
    ok = filelib:ensure_dir(filename:join(LinkDir, "keep")),
    %% Write the `.beam` under its OWN declared module name, so `code:which(M)`
    %% resolves to a real, LOADABLE file iff `M` matches the beam. For P11-06 this is
    %% identical to `<ModuleName>.beam` (link_program guarantees the returned atom ==
    %% the beam's declared module), but it makes the NOLOAD guard meaningful: a
    %% `ModuleName` that disagrees with the beam yields `non_existing` (exit 4) instead
    %% of a confusing load-mismatch trap. (Refines `05-bare-node-harness.md` §3 step 2,
    %% which sketched `<ModuleName>.beam` and left NOLOAD unreachable on a name mismatch.)
    BeamModule = beam_module_name(Beam, ModuleName),
    ok = file:write_file(filename:join(LinkDir, atom_to_list(BeamModule) ++ ".beam"), Beam),
    {ExtraPa, ExtraDirs} = write_extra(Extra),
    RunnerBin = runner(ModuleName, Fun, Args),
    PortArgs =
        ["-noshell", "-boot", "no_dot_erlang", "-pa", LinkDir]
        ++ ExtraPa
        ++ ["-eval", RunnerBin],
    %% Each entry `{Var, false}` REMOVES the variable from the child's environment.
    Env = [{"ERL_LIBS", false}, {"ERL_FLAGS", false},
           {"ERL_AFLAGS", false}, {"ERL_ZFLAGS", false}],
    Port = erlang:open_port(
        {spawn_executable, Exe},
        [{args, PortArgs}, {env, Env}, exit_status, stderr_to_stdout, binary, hide]),
    Deadline = erlang:monotonic_time(millisecond) + ?CHILD_TIMEOUT_MS,
    Result = collect(Port, <<>>, Deadline),
    _ = file:del_dir_r(LinkDir),
    lists:foreach(fun(D) -> file:del_dir_r(D) end, ExtraDirs),
    Result.

%% Write the `Extra` `{Mod, Beam}` pairs into a fresh, SEPARATE dir and return
%% `{["-pa", Dir], [Dir]}`; for the empty (isolated) case return `{[], []}` so NO extra
%% `-pa` is added and the child sees exactly one file. Keeping `Extra` off `LinkDir` is
%% what makes the isolated case genuinely one-file.
write_extra([]) ->
    {[], []};
write_extra(Extra) ->
    ExtraDir = fresh_dir("carder_boot_extra"),
    ok = filelib:ensure_dir(filename:join(ExtraDir, "keep")),
    lists:foreach(
        fun({Mod, Bin}) ->
            ok = file:write_file(filename:join(ExtraDir, atom_to_list(Mod) ++ ".beam"), Bin)
        end,
        Extra),
    {["-pa", ExtraDir], [ExtraDir]}.

%% Build the in-child runner as an Erlang expression string (an iolist, flattened to a
%% binary for the `-eval` argv element — a binary is accepted verbatim and needs no
%% shell quoting since it is a separate `{args, …}` element). The `~p`/`~0p`/`~n` inside
%% the emitted text are LITERAL characters in the child's own `io:format` calls (not
%% processed here); only `ModuleName`/`Fun`/`Args` are substituted, via `~w`, which
%% renders them re-readably (quoting atoms with `@`). The runner is a single
%% comma-separated expression sequence terminated by `.` (accepted by `erl -eval`) and
%% ALWAYS halts, so `-noshell` never lingers:
%%
%%   (a) NOLOAD guard — the module under test must be on the child path (else halt 4);
%%   (b) ISOLATION GATE — every representative closure module must be `non_existing`
%%       (else print `LEAK:` and halt 3): isolation MEASURED, not assumed;
%%   (c) SEED-THEN-CALL — `M:instantiate()` in THIS process, then self-detect the state
%%       ABI from its return (`ok` => Cell: `apply(M,F,Args)`; `{instance_state,…}` =>
%%       Threaded: `element(1, apply(M,F,[St|Args]))`), print `RESULT:` and halt 0; any
%%       trap is caught, printed as `TRAP:` and halt 0 (a trap is NOT an isolation
%%       failure). Mirrors the cell/threaded self-detection in
%%       `carder_harness_ffi:start_common/2`.
runner(ModuleName, Fun, Args) ->
    MStr = io_lib:format("~w", [ModuleName]),
    FStr = io_lib:format("~w", [Fun]),
    ArgsStr = io_lib:format("~w", [Args]),
    Runner =
        ["case code:which(", MStr, ") of non_existing -> io:format(\"NOLOAD:~p~n\",[",
         MStr, "]), halt(4); _ -> ok end, ",
         "lists:foreach(fun(Md) -> case code:which(Md) of non_existing -> ok; "
         "_ -> io:format(\"LEAK:~p~n\",[Md]), halt(3) end end, ",
         "['carder@runtime@rt_mem','gleam@list',gleam_stdlib,'carder@ir']), ",
         "try St0 = ", MStr, ":instantiate(), ",
         "Pkg = case St0 of ok -> apply(", MStr, ", ", FStr, ", ", ArgsStr, "); ",
         "T when is_tuple(T), element(1,T) =:= instance_state -> "
         "element(1, apply(", MStr, ", ", FStr, ", [St0|", ArgsStr, "])) end, ",
         "io:format(\"RESULT:~0p~n\", [Pkg]), halt(0) ",
         "catch _:R -> io:format(\"TRAP:~0p~n\", [R]), halt(0) end."],
    iolist_to_binary(Runner).

%% Drain the child port's stdout/stderr into one binary until it exits, bounded by
%% `Deadline` (monotonic ms). On the deadline the port is force-closed and `{124, …}`
%% is returned so a hung child cannot block the suite. Mirrors
%% `carder_harness_ffi:collect/2`, plus the bound.
collect(Port, Acc, Deadline) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Bytes}} -> collect(Port, <<Acc/binary, Bytes/binary>>, Deadline);
        {Port, {exit_status, Code}} -> {Code, Acc}
    after Remaining ->
        try erlang:port_close(Port) catch _:_ -> ok end,
        {124, <<Acc/binary, "HARNESS:child timed out">>}
    end.

%% ─────────────────────────── which_in_parent/1 ───────────────────────────

%% `code:which/1` in the PARENT (test) VM. Used ONLY by the anti-vacuity self-test to
%% prove the gate atoms are REAL — a module the parent build can resolve — so the
%% child's `non_existing` is a genuine absence, not a typo that would make the gate pass
%% vacuously.
%%
%% Returns (Gleam `Result(String, Nil)`):
%%   {ok, Path :: binary()}   — `Mod` is loaded or on the parent path (its `.beam` path,
%%                              or the atom `preloaded`/`cover_compiled` rendered as text).
%%   {error, nil}             — `code:which/1` returned `non_existing` (marshals to the
%%                              Gleam `Error(Nil)`; NOT the bare `error` atom).
%% (Spec note: `05-bare-node-harness.md` §4 sketched a bare `error` return; the frozen
%% Gleam binding is `Result(String, Nil)`, whose `Error(Nil)` wire shape is `{error, nil}`
%% — the repo-wide convention, e.g. `src/carder_rt_state_ffi.erl`. `{error, nil}` is used.)
which_in_parent(Mod) ->
    case code:which(Mod) of
        non_existing -> {error, nil};
        Path when is_list(Path) -> {ok, unicode:characters_to_binary(Path)};
        Other -> {ok, unicode:characters_to_binary(io_lib:format("~p", [Other]))}
    end.

%% The module atom DECLARED inside `Beam` (via `beam_lib:info/1`), or `Default` if it
%% cannot be read (a malformed beam — never in practice, since `Beam` comes from
%% `compile_source/2` or the linker). Used to name the `.beam` file on disk so a loader
%% can resolve it, independently of the caller-supplied `ModuleName`.
beam_module_name(Beam, Default) ->
    try beam_lib:info(Beam) of
        Info when is_list(Info) ->
            case lists:keyfind(module, 1, Info) of
                {module, M} -> M;
                false -> Default
            end;
        _ -> Default
    catch
        _:_ -> Default
    end.

%% A writable, per-call unique temp dir path under `$TMPDIR` (or `/tmp`). Not created
%% here — the caller `filelib:ensure_dir/1`s it. The monotonic-unique suffix prevents
%% collisions across concurrent/repeated calls.
fresh_dir(Prefix) ->
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              T -> T
          end,
    filename:join(Tmp, Prefix ++ "_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).
