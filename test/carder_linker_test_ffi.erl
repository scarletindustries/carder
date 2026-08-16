%%% carder_linker_test_ffi — test-only helper for the P11-03 linker suite.
%%%
%%% Mirrors the existing `test/carder_*_test_ffi.erl` convention (a hand-written
%%% `.erl` under `test/`). It installs a SYNTHETIC discovered closure module on
%%% disk so the linker's real acquisition path (`beam_lib` `debug_info core_v1`
%%% off `code:which(M)`) can reach it — the only way to exercise the
%%% `MangleCollision` (R12, a `__`-bearing module atom) and `UnmergeableConstruct`
%%% (R15, an `-on_load` module) fail-closed paths against a REAL beam, since no
%%% shipped closure module violates those invariants.
-module(carder_linker_test_ffi).
-export([install_synth/2]).

%% install_synth(NameBin, ErlSrcBin) -> ok
%%
%% Compile the Erlang SOURCE `ErlSrcBin` (whose `-module` must be `NameBin`) with
%% `debug_info`, write the `.beam` to a temp dir, and load it from that path so
%% `code:which(Name)` resolves to a real file the linker can `beam_lib:chunks`.
%% Idempotent: re-installing purges + reloads.
install_synth(NameBin, ErlSrcBin) ->
    Name = binary_to_atom(NameBin, utf8),
    Dir = synth_dir(),
    ok = filelib:ensure_dir(filename:join(Dir, "keep")),
    Base = filename:join(Dir, atom_to_list(Name)),
    ErlFile = Base ++ ".erl",
    BeamFile = Base ++ ".beam",
    ok = file:write_file(ErlFile, ErlSrcBin),
    {ok, Name, Beam} = compile:file(ErlFile, [debug_info, binary, return_errors]),
    ok = file:write_file(BeamFile, Beam),
    _ = code:purge(Name),
    {module, Name} = code:load_binary(Name, BeamFile, Beam),
    ok.

%% A writable per-run temp dir for the synthetic beams.
synth_dir() ->
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              T -> T
          end,
    filename:join(Tmp, "carder_linker_synth").
