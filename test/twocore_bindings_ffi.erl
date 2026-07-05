%%% twocore_bindings_ffi — the shared compile+call harness for the Phase-12 typed
%%% host-language bindings (P12-01 companion, R25b).
%%%
%%% TRUST BOUNDARY: TEST-ONLY infrastructure. It is NOT the OTP-compiler-internals trust
%%% boundary of `src/twocore_*_ffi.erl` — it only uses `os`, `file`/`filelib`, `compile`,
%%% `beam_lib`, `code`, `unicode`, and `erlang`/`erlang:open_port`. Namespace: hand-written
%%% Erlang under `test/`, so it carries the `twocore_` prefix (same convention as the other
%%% `test/twocore_*_ffi.erl` shims). It touches no unit-owned source file and is imported by
%%% nothing on the default pipeline.
%%%
%%% WHY IT LANDS IN THE KEYSTONE (R25b): the three Wave-A emitter units (P12-02/03/04) each
%%% need to COMPILE their emitted binding with the real toolchain and CALL an export through
%%% it in their OWN Definition of Done — without duplicating a per-unit mini-FFI and without
%%% blocking on the capstone (P12-06). Pulling the shared shell-out+load FFI forward here gives
%%% them one frozen surface. The intended usage is "compile ONCE per (language × module), CALL
%%% many exports" (toolchain spawn is slow) — the Gleam callers cache the loaded module atom.
%%%
%%% Frozen public API (consumed by P12-02/03/04/06):
%%%   which/1               — probe a toolchain executable on PATH (gate Elixir best-effort).
%%%   compile_load_erlang/2 — compile+load hand/emitted Erlang source(s) IN-VM (fast).
%%%   compile_load_gleam/2  — stage a temp Gleam project, `gleam build`, load the beams.
%%%   compile_load_elixir/2 — `elixirc` the emitted `.ex` source(s), load the beams.
%%%   call/3                — apply `M:F(Args)`, exceptions captured as `{error, Text}`.
%%%   purge/1               — fully unload a binding module between per-language runs (R16).
%%%   is_loaded/1           — whether a module atom currently has code resident (R16 probe).
%%%
%%% Each `compile_load_*` takes `Files :: [{FileName :: binary(), Content :: binary()}]` (the
%%% on-disk basename WITH extension, e.g. `<<"foo_bindings.gleam">>`, and its UTF-8 source) plus
%%% `Main :: atom()` (the loaded module atom to return on success). ALL produced beams are
%%% loaded (so a Gleam binding's companion `.erl` shim, or a multi-module Elixir file, resolve);
%%% `Main` is what the caller then drives with `call/3`. Returns `{ok, Main}` or `{error, Text}`
%%% (a UTF-8 binary of the toolchain diagnostics) — repo `Result(_, _)` convention.
-module(twocore_bindings_ffi).
-export([which/1, compile_load_erlang/2, compile_load_gleam/2,
         compile_load_elixir/2, call/3, purge/1, is_loaded/1]).

%% Wall-clock bound (ms) on a single toolchain spawn (`gleam build`/`elixirc`). Cold starts are
%% sub-second here; this is a generous CI-robustness ceiling so a hung child is reaped rather
%% than blocking the suite forever.
-define(SPAWN_TIMEOUT_MS, 120000).

%% ─────────────────────────── which/1 ───────────────────────────

%% Locate executable `Exe` on `PATH`. Used to gate the best-effort Elixir arm (P8) — an absent
%% `elixirc` is a categorized SKIP, never a false green.
%%
%% Params: `Exe :: binary()` (e.g. `<<"elixirc">>`).
%% Returns (Gleam `Result(String, Nil)`):
%%   {ok, Path :: binary()} — the absolute path to the executable.
%%   {error, nil}           — not found (marshals to Gleam `Error(Nil)`; the repo convention,
%%                            e.g. `src/twocore_rt_state_ffi.erl`).
which(Exe) ->
    case os:find_executable(binary_to_list(Exe)) of
        false -> {error, nil};
        Path -> {ok, unicode:characters_to_binary(Path)}
    end.

%% ─────────────────────────── compile_load_erlang/2 ───────────────────────────

%% Compile each `.erl` in `Files` with the IN-VM Erlang compiler (`compile:file`, no external
%% spawn — fast and always available since Erlang IS the BEAM) and load the resulting beam. Serves
%% the Erlang emitter (P12-03) AND the Gleam emitter's companion `.erl` catch shim (P12-02).
%%
%% Params:
%%   Files :: [{FileName :: binary(), Content :: binary()}] — each `FileName` ends `.erl` and its
%%            base MUST equal the source's `-module(...)`.
%%   Main  :: atom() — the module atom to return on success.
%% Returns: {ok, Main} | {error, Text :: binary()} (compile diagnostics on the first failure).
compile_load_erlang(Files, Main) ->
    Dir = fresh_dir("twocore_bindings_erl"),
    ok = filelib:ensure_dir(filename:join(Dir, "keep")),
    Result = compile_load_erlang_1(Files, Dir),
    _ = file:del_dir_r(Dir),
    case Result of
        ok -> {ok, Main};
        {error, _} = E -> E
    end.

compile_load_erlang_1([], _Dir) -> ok;
compile_load_erlang_1([{FileName, Content} | Rest], Dir) ->
    Path = filename:join(Dir, binary_to_list(FileName)),
    ok = file:write_file(Path, Content),
    Base = filename:rootname(Path),
    case compile:file(Base, [binary, return_errors, return_warnings, deterministic]) of
        {ok, Mod, Beam} ->
            ok = load_beam(Mod, FileName, Beam),
            compile_load_erlang_1(Rest, Dir);
        {ok, Mod, Beam, _Warnings} ->
            ok = load_beam(Mod, FileName, Beam),
            compile_load_erlang_1(Rest, Dir);
        {error, Errors, Warnings} ->
            {error, unicode:characters_to_binary(
                io_lib:format("erlang compile failed for ~s: ~p (warnings: ~p)",
                              [FileName, Errors, Warnings]))};
        error ->
            {error, unicode:characters_to_binary(
                io_lib:format("erlang compile failed for ~s", [FileName]))}
    end.

%% ─────────────────────────── compile_load_gleam/2 ───────────────────────────

%% Stage a minimal, DEPENDENCY-FREE Gleam project in a temp dir (a `gleam.toml` + `src/` holding
%% the emitted `.gleam` and its companion `.erl` shim — Gleam discovers native FFI tree-wide under
%% `src/`, R22), run `gleam build --target erlang`, then load EVERY compiled beam from the
%% project's `ebin`. Serves the Gleam emitter (P12-02). The generated bindings use only the Gleam
%% prelude (`Int`/`Float`/`Result`/`BitArray`/tuples) + `@external` FFI, so the project needs no
%% `gleam_stdlib` dependency and builds offline.
%%
%% Params:
%%   Files :: [{FileName :: binary(), Content :: binary()}] — the `src/` files (`.gleam`/`.erl`).
%%   Main  :: atom() — the loaded binding module atom to return (Gleam mangles `foo_bindings.gleam`
%%            to the module atom `foo_bindings`).
%% Returns: {ok, Main} | {error, Text} (`gleam` absent, or the build's stdout/stderr on failure).
compile_load_gleam(Files, Main) ->
    case os:find_executable("gleam") of
        false -> {error, <<"gleam toolchain not available">>};
        Exe -> compile_load_gleam_1(Exe, Files, Main)
    end.

compile_load_gleam_1(Exe, Files, Main) ->
    Proj = "twocore_binding_probe",
    Dir = fresh_dir("twocore_bindings_gleam"),
    Src = filename:join(Dir, "src"),
    ok = filelib:ensure_dir(filename:join(Src, "keep")),
    Toml = ["name = \"", Proj, "\"\ntarget = \"erlang\"\nversion = \"1.0.0\"\n"],
    ok = file:write_file(filename:join(Dir, "gleam.toml"), iolist_to_binary(Toml)),
    lists:foreach(
        fun({FileName, Content}) ->
            ok = file:write_file(filename:join(Src, binary_to_list(FileName)), Content)
        end, Files),
    {Exit, Output} = run_port(Exe, ["build", "--target", "erlang"], Dir),
    Result =
        case Exit of
            0 ->
                Ebin = filename:join([Dir, "build", "dev", "erlang", Proj, "ebin"]),
                load_all_beams(Ebin),
                {ok, Main};
            _ ->
                {error, prefix(<<"gleam build failed: ">>, Output)}
        end,
    _ = file:del_dir_r(Dir),
    Result.

%% ─────────────────────────── compile_load_elixir/2 ───────────────────────────

%% Compile the emitted `.ex` source(s) with `elixirc` into a temp dir, then load EVERY produced
%% beam (Elixir mangles `defmodule Foo` to the module atom `'Elixir.Foo'`). Serves the Elixir
%% emitter (P12-04). BEST-EFFORT (P8/R23): if `elixirc` is absent this returns `{error, …}` and the
%% caller categorizes a skip. To avoid pulling the Elixir stdlib onto the VM at call time, the
%% emitted bindings catch traps Erlang-style (`:error, {:wasm_trap, _}`), so a loaded binding runs
%% with zero `Elixir.*` runtime deps (R23) — this FFI only needs `elixirc` present to COMPILE.
%%
%% Params:
%%   Files :: [{FileName :: binary(), Content :: binary()}] — each `FileName` ends `.ex`.
%%   Main  :: atom() — the loaded module atom to return (e.g. `'Elixir.Foo'`).
%% Returns: {ok, Main} | {error, Text} (`elixirc` absent, or its stderr on failure).
compile_load_elixir(Files, Main) ->
    case os:find_executable("elixirc") of
        false -> {error, <<"elixir toolchain not available">>};
        Exe -> compile_load_elixir_1(Exe, Files, Main)
    end.

compile_load_elixir_1(Exe, Files, Main) ->
    Dir = fresh_dir("twocore_bindings_elixir"),
    Out = filename:join(Dir, "ebin"),
    ok = filelib:ensure_dir(filename:join(Out, "keep")),
    Names =
        lists:map(
            fun({FileName, Content}) ->
                Name = binary_to_list(FileName),
                ok = file:write_file(filename:join(Dir, Name), Content),
                Name
            end, Files),
    {Exit, Output} = run_port(Exe, Names ++ ["-o", "ebin"], Dir),
    Result =
        case Exit of
            0 ->
                load_all_beams(Out),
                {ok, Main};
            _ ->
                {error, prefix(<<"elixirc failed: ">>, Output)}
        end,
    _ = file:del_dir_r(Dir),
    Result.

%% ─────────────────────────── call/3 ───────────────────────────

%% Apply `M:F(Args)` and return its value, capturing ANY BEAM exception as `{error, Text}`. The
%% typed binding itself already wraps a WASM trap as an in-band `Result`/tagged tuple, so a normal
%% call returns that native value verbatim; this catch is a safety net so an emitter bug (a wrong
%% arity ⇒ `undef`, a `badmatch`) surfaces as a clean `{error, …}` string in the test rather than
%% crashing the whole suite. It is NOT a trap-classification mechanism.
%%
%% Params: `M`/`F :: atom()`, `Args :: [term()]`.
%% Returns (Gleam `Result(Dynamic, String)`): {ok, Value} | {error, Text :: binary()}.
call(M, F, Args) ->
    try
        {ok, erlang:apply(M, F, Args)}
    catch
        Class:Reason:_ ->
            {error, unicode:characters_to_binary(
                io_lib:format("~p:~p on ~p:~p/~p", [Class, Reason, M, F, length(Args)]))}
    end.

%% ─────────────────────────── purge/1 ───────────────────────────

%% Fully unload module `Mod` from the VM so a subsequent load of a DIFFERENT-language
%% binding under the SAME module atom cannot leave stale code resident (R16). The
%% Gleam binding `<base>_bindings` and the Erlang binding `<base>_bindings` share ONE
%% BEAM atom; the capstone loads them into one VM in sequence, so between per-language
%% runs it MUST unload the previous language's binding — otherwise the two co-reside
%% (BEAM keeps current+old code per module) and a later reload either dispatches into
%% the wrong-language module (a silent false green — observed) or fails `{error,
%% not_purged}`. `purge` removes any old code, deletes the current export, then removes
%% that too, leaving the atom unloaded and safe to reload fresh.
%%
%% Params: `Mod :: atom()` (the binding module atom, e.g. `twocore_wasm_x_bindings`).
%% Returns (Gleam `Nil`): the atom `nil`. Idempotent + total: purging/deleting an
%% already-absent module is a harmless `false`, never an error.
purge(Mod) ->
    _ = code:purge(Mod),
    _ = code:delete(Mod),
    _ = code:purge(Mod),
    nil.

%% ─────────────────────────── is_loaded/1 ───────────────────────────

%% Whether module atom `Mod` currently has code resident (loaded) in the VM. Used by the R16
%% clobber test to distinguish "resident (possibly the wrong-language binding)" from "fully
%% unloaded by `purge`". `code:is_loaded/1` yields `{file, _}` when loaded and `false` when not.
%%
%% Params: `Mod :: atom()`.
%% Returns (Gleam `Bool`): `true` iff `Mod` is loaded, else `false`.
is_loaded(Mod) ->
    case code:is_loaded(Mod) of
        false -> false;
        _ -> true
    end.

%% ─────────────────────────── internal helpers ───────────────────────────

%% Load a single beam binary under its DECLARED module name (read from the beam, not the file
%% basename — `code:load_binary/3` requires the atom to match the beam or returns `{error, badfile}`).
load_beam(_DerivedMod, FileName, Beam) ->
    Mod = beam_declared_module(Beam),
    case code:load_binary(Mod, binary_to_list(FileName), Beam) of
        {module, Mod} -> ok;
        {error, R} ->
            erlang:error({load_binary_failed, Mod, R})
    end.

%% Load EVERY `*.beam` under directory `Ebin` (an emitted project can produce several: the binding
%% module, its `@@main`, a companion module). Each is loaded by its declared module name so the
%% loaded set is complete before the temp dir is deleted.
load_all_beams(Ebin) ->
    case filelib:wildcard(filename:join(Ebin, "*.beam")) of
        [] -> ok;
        Beams ->
            lists:foreach(
                fun(BeamPath) ->
                    {ok, Bin} = file:read_file(BeamPath),
                    Mod = beam_declared_module(Bin),
                    _ = code:load_binary(Mod, BeamPath, Bin),
                    ok
                end, Beams)
    end.

%% The module atom DECLARED inside a beam binary (via `beam_lib:info/1`).
beam_declared_module(Beam) ->
    Info = beam_lib:info(Beam),
    {module, Mod} = lists:keyfind(module, 1, Info),
    Mod.

%% Spawn `Exe Args` with cwd `Cwd`, draining combined stdout/stderr into one binary until exit,
%% bounded by `?SPAWN_TIMEOUT_MS`. Returns `{ExitStatus :: integer(), Output :: binary()}` (124 on
%% timeout, with the port force-closed). Mirrors the port pattern in `twocore_linked_boot_ffi`.
run_port(Exe, Args, Cwd) ->
    Port = erlang:open_port(
        {spawn_executable, Exe},
        [{args, Args}, {cd, Cwd}, exit_status, stderr_to_stdout, binary, hide]),
    Deadline = erlang:monotonic_time(millisecond) + ?SPAWN_TIMEOUT_MS,
    collect(Port, <<>>, Deadline).

collect(Port, Acc, Deadline) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Bytes}} -> collect(Port, <<Acc/binary, Bytes/binary>>, Deadline);
        {Port, {exit_status, Code}} -> {Code, Acc}
    after Remaining ->
        try erlang:port_close(Port) catch _:_ -> ok end,
        {124, <<Acc/binary, "HARNESS:toolchain timed out">>}
    end.

%% Prepend a UTF-8 label to a (possibly large) diagnostic binary.
prefix(Label, Output) -> <<Label/binary, Output/binary>>.

%% A writable, per-call unique temp dir path under `$TMPDIR` (or `/tmp`). Not created here — the
%% caller `filelib:ensure_dir/1`s it. The monotonic-unique suffix prevents collisions.
fresh_dir(Prefix) ->
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              T -> T
          end,
    filename:join(Tmp, Prefix ++ "_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).
