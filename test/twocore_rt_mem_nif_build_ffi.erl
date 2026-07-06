%%% twocore_rt_mem_nif_build_ffi — the toolchain-gated tier-N NIF build+load harness (S15-01 keystone).
%%%
%%% TRUST BOUNDARY: TEST-ONLY infrastructure. Like `twocore_bindings_ffi`, it is NOT the
%%% OTP-compiler-internals trust boundary of `src/twocore_*_ffi.erl`; it only uses `os`,
%%% `file`/`filelib`, `code`, `unicode`, and `erlang:open_port`. Hand-written Erlang under `test/`, so
%%% it carries the `twocore_` prefix (same convention as the other `test/twocore_*_ffi.erl` shims). It
%%% touches no unit-owned source file and is imported by nothing on the default pipeline.
%%%
%%% WHAT IT PROVES (the «NIF-BUILD-FROZEN» pipe): it compiles a C `erl_nif` NIF at TEST TIME via a
%%% `cc`-gated `cc -shared -fPIC …` into a tempdir `.so`, force-reloads the `twocore_rt_mem_nif_ffi`
%%% shim so `-on_load` attaches it, and calls a NIF through it. Modelled on `twocore_bindings_ffi`'s
%%% `which/1` + `run_port/3` + `fresh_dir/1` (the Phase-12 test-time-compile template). When no C
%%% toolchain is on PATH it returns `skip_no_toolchain` — a CATEGORIZED SKIP, never a false green (S6).
%%%
%%% FROZEN EXPORTS (the build-gate signature S15-02/03/04 call to compile the REAL
%%% `c_src/twocore_rt_mem_nif.c` at test time):
%%%   which/1              — probe a toolchain executable on PATH ({ok,Path} | {error,nil}).
%%%   cc/0                 — resolve `cc`, fallback `gcc` ({ok,Path} | {error,nil}).
%%%   compile_load_probe/0 — compile the EMBEDDED `nif_ping` probe `.c` + load (the keystone proof).
%%%   compile_load_cnif/0  — compile the COMMITTED `c_src/twocore_rt_mem_nif.c` + load (downstream).
%%%
%%% Each `compile_load_*` returns `loaded | skip_no_toolchain | {build_error, Text :: binary()}`, which
%%% marshals directly onto the Gleam `BuildResult` custom type (`loaded → Loaded`,
%%% `skip_no_toolchain → SkipNoToolchain`, `{build_error, Bin} → BuildError(String)`).
-module(twocore_rt_mem_nif_build_ffi).
-export([which/1, cc/0, compile_load_probe/0, compile_load_cnif/0]).

%% The frozen shim module (the `-on_load`/`load_nif` target) and the `.so` basename this harness builds.
-define(SHIM, twocore_rt_mem_nif_ffi).
-define(SO_BASE, "twocore_rt_mem_nif").

%% Wall-clock bound (ms) on a single `cc` spawn. A cold `cc` is sub-second here; this is a generous
%% CI-robustness ceiling so a hung child is reaped rather than blocking the suite forever.
-define(SPAWN_TIMEOUT_MS, 120000).

%% ─────────────────────────── which/1, cc/0 (the gate) ───────────────────────────

%% Locate executable `Exe` on `PATH` (the toolchain gate, `twocore_bindings_ffi:52-56`).
%%
%% Params: `Exe :: binary()` (e.g. `<<"cc">>`).
%% Returns (Gleam `Result(String, Nil)`): `{ok, Path :: binary()}` | `{error, nil}` (not found).
which(Exe) ->
    case os:find_executable(binary_to_list(Exe)) of
        false -> {error, nil};
        Path -> {ok, unicode:characters_to_binary(Path)}
    end.

%% Resolve a C compiler: `cc` first, then `gcc` (CI ubuntu ships both; macOS `cc` is clang).
%%
%% Returns (Gleam `Result(String, Nil)`): `{ok, Path :: binary()}` | `{error, nil}` (neither present).
cc() ->
    case which(<<"cc">>) of
        {ok, _} = Ok -> Ok;
        {error, nil} -> which(<<"gcc">>)
    end.

%% ─────────────────────────── compile_load_probe/0, compile_load_cnif/0 ───────────────────────────

%% Compile the EMBEDDED `nif_ping` probe `.c` (never a committed `c_src/*.c`, keeping
%% `c_src/twocore_rt_mem_nif.c` S15-02's) against the committed `c_src/twocore_rt_mem_nif.h`, then load
%% + verify. THE keystone proof.
%%
%% Returns: `loaded` | `skip_no_toolchain` | `{build_error, binary()}`.
compile_load_probe() ->
    compile_and_load(probe_c_source()).

%% Compile the COMMITTED `c_src/twocore_rt_mem_nif.c` (owned by S15-02) against the committed
%% `c_src/twocore_rt_mem_nif.h`, then load + verify. Called by S15-02/03/04's per-op differential; at
%% keystone time the `.c` does not exist yet, so this returns a clear `{build_error, _}` (never called
%% by the keystone's own tests).
%%
%% Returns: `loaded` | `skip_no_toolchain` | `{build_error, binary()}`.
compile_load_cnif() ->
    case read_repo_file("c_src/twocore_rt_mem_nif.c") of
        {ok, CSource} ->
            compile_and_load(CSource);
        {error, _} ->
            {build_error,
                <<"c_src/twocore_rt_mem_nif.c not found (owned by S15-02, not built this unit)">>}
    end.

%% ─────────────────────────── the shared compile+load machinery ───────────────────────────

%% Gate → resolve erl_nif.h → stage tempdir → compile → reload shim → verify → cleanup. `CSource` is
%% the `.c` body to compile (the embedded probe, or the committed cnif). Every failure that is NOT a
%% missing toolchain is a LOUD `{build_error, _}` (a broken pipe is a bug, never a skip).
compile_and_load(CSource) ->
    case cc() of
        {error, nil} ->
            %% The categorized skip — checked BEFORE any compile (S6). Never a false green.
            skip_no_toolchain;
        {ok, CcBin} ->
            case read_repo_file("c_src/twocore_rt_mem_nif.h") of
                {error, _} ->
                    {build_error, <<"c_src/twocore_rt_mem_nif.h not found">>};
                {ok, Header} ->
                    Cc = binary_to_list(CcBin),
                    Dir = fresh_dir("twocore_rt_mem_nif_build"),
                    ok = filelib:ensure_dir(filename:join(Dir, "keep")),
                    Result = stage_compile_load(Cc, Dir, Header, CSource),
                    _ = file:del_dir_r(Dir),
                    Result
            end
    end.

%% Write the sources, compile with the platform flag vector, then force-reload the shim + verify.
stage_compile_load(Cc, Dir, Header, CSource) ->
    CPath = filename:join(Dir, ?SO_BASE ++ ".c"),
    HPath = filename:join(Dir, ?SO_BASE ++ ".h"),
    SoPath = filename:join(Dir, ?SO_BASE ++ ".so"),
    Base = filename:join(Dir, ?SO_BASE),
    ok = file:write_file(HPath, Header),
    ok = file:write_file(CPath, CSource),
    case erts_include() of
        {error, Text} ->
            {build_error, Text};
        {ok, Inc} ->
            {Exit, Output} = run_port(Cc, cflags(Inc, SoPath, CPath), Dir),
            case Exit of
                0 -> reload_and_verify(Base);
                _ -> {build_error, prefix(<<"cc failed: ">>, Output)}
            end
    end.

%% Point the shim's `-on_load` at the freshly-built `.so` (via the env override), force-reload it so
%% `-on_load` re-runs and `load_nif` attaches, then verify by calling `nif_ping()`.
reload_and_verify(Base) ->
    os:putenv("TWOCORE_RT_MEM_NIF_SO", Base),
    _ = code:purge(?SHIM),
    _ = code:delete(?SHIM),
    case code:load_file(?SHIM) of
        {module, ?SHIM} -> verify_ping();
        {error, What} ->
            {build_error,
                unicode:characters_to_binary(
                    io_lib:format("shim reload failed: ~p", [What]))}
    end.

%% Call the just-attached `nif_ping()` and classify. `pong ⇒ loaded`; a raised `nif_not_loaded` means
%% the soft `-on_load` swallowed a `load_nif` failure ⇒ a LOUD `{build_error, load_nif_failed}` (a
%% broken pipe is a bug, never a skip).
verify_ping() ->
    try ?SHIM:nif_ping() of
        pong ->
            loaded;
        Other ->
            {build_error,
                unicode:characters_to_binary(
                    io_lib:format("nif_ping returned ~p (expected pong)", [Other]))}
    catch
        error:nif_not_loaded ->
            {build_error,
                <<"load_nif_failed: nif_ping stub still active — the .so compiled but did not attach">>};
        Class:Reason ->
            {build_error,
                unicode:characters_to_binary(
                    io_lib:format("nif_ping raised ~p:~p", [Class, Reason]))}
    end.

%% ─────────────────────────── erl_nif.h resolution + cc flags ───────────────────────────

%% The erl_nif.h include dir — a ROBUST candidate-list resolver (keystone §3.5). The brief's bare
%% `code:lib_dir(erts, include)` is NOT reliable: on homebrew OTP 29 it returns a HEADER-LESS path
%% (`…/lib/erlang/lib/erts-<vsn>/include` — no `erl_nif.h`). Try candidates in order; pick the first
%% where `erl_nif.h` actually exists.
%%
%% Returns: `{ok, Dir :: string()}` | `{error, Text :: binary()}` (no candidate holds the header).
erts_include() ->
    Root = code:root_dir(),
    Vsn = erlang:system_info(version),
    Candidates =
        [filename:join([Root, "erts-" ++ Vsn, "include"]),         %% confirmed macOS OTP 29 + Linux
         filename:join([Root, "usr", "include"]),                  %% confirmed macOS OTP 29 fallback
         filename:join(code:lib_dir(erts), "include")],            %% the brief's suggestion (non-deprecated
                                                                   %% form of code:lib_dir(erts, include)) — some layouts only
    Found = [D || D <- Candidates, filelib:is_file(filename:join(D, "erl_nif.h"))],
    case Found of
        [Dir | _] ->
            {ok, Dir};
        [] ->
            {error,
                unicode:characters_to_binary(
                    io_lib:format("erl_nif.h not found in any of ~p", [Candidates]))}
    end.

%% The `os:type()`-selected `cc` flag vector (keystone §3.5, EMPIRICALLY CONFIRMED live on macOS clang).
%%
%%   common        : -shared -fPIC -O2 -I<Inc> -o <So> <C>
%%   {unix,darwin} : + -undefined dynamic_lookup  (MANDATORY — a NIF's enif_* symbols are undefined at
%%                     link time and resolved from the host beam at load; macOS `ld` REJECTS them
%%                     without this. Confirmed live: plain `-shared -fPIC` fails
%%                     "Undefined symbols … _enif_make_atom …", adding it yields `pong`.)
%%   {unix,linux}  : + (nothing) — `-shared` suffices; Linux `ld` allows undefined symbols by default.
cflags(Inc, So, C) ->
    Platform =
        case os:type() of
            {unix, darwin} -> ["-undefined", "dynamic_lookup"];
            _ -> []
        end,
    ["-shared", "-fPIC", "-O2", "-I" ++ Inc] ++ Platform ++ ["-o", So, C].

%% ─────────────────────────── the embedded `nif_ping` probe `.c` ───────────────────────────

%% The throwaway probe source (a binary constant, NOT a committed `c_src/*.c`). It `#include`s the
%% COMMITTED `.h`, opens the frozen resource type in its `load` callback, defines `nif_ping → "pong"`,
%% and declares `ERL_NIF_INIT(twocore_rt_mem_nif_ffi, …)`. One compile therefore proves the WHOLE
%% toolchain path in one shot: erl_nif.h resolution, the committed `.h` compiling, resource-type
%% registration, `ERL_NIF_INIT` dispatch, and term marshalling back to Erlang.
probe_c_source() ->
    <<
        "#include <erl_nif.h>\n"
        "#include \"twocore_rt_mem_nif.h\"\n"
        "\n"
        "static ErlNifResourceType *TWOCORE_MEM_RT = NULL;\n"
        "\n"
        "static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {\n"
        "    (void)priv_data; (void)load_info;\n"
        "    ErlNifResourceType *rt = enif_open_resource_type(\n"
        "        env, NULL, TWOCORE_RT_MEM_NIF_RESOURCE, NULL, ERL_NIF_RT_CREATE, NULL);\n"
        "    if (rt == NULL) return -1;\n"
        "    TWOCORE_MEM_RT = rt;\n"
        "    return 0;\n"
        "}\n"
        "\n"
        "static ERL_NIF_TERM nif_ping(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {\n"
        "    (void)argc; (void)argv;\n"
        "    return enif_make_atom(env, \"pong\");\n"
        "}\n"
        "\n"
        "static ErlNifFunc nif_funcs[] = {\n"
        "    {\"nif_ping\", 0, nif_ping, 0}\n"
        "};\n"
        "\n"
        "ERL_NIF_INIT(twocore_rt_mem_nif_ffi, nif_funcs, load, NULL, NULL, NULL)\n"
    >>.

%% ─────────────────────────── generic helpers (mirroring twocore_bindings_ffi) ───────────────────────────

%% Read a repo file at `RelPath` relative to the test cwd (the project root — `gleam test` runs there,
%% e.g. it reads `test/twocore/conformance/corpus/…`). Returns `{ok, binary()}` | `{error, term()}`.
read_repo_file(RelPath) ->
    file:read_file(RelPath).

%% Spawn `Cc Args` with cwd `Cwd`, draining combined stdout/stderr into one binary until exit, bounded
%% by `?SPAWN_TIMEOUT_MS`. Returns `{ExitStatus :: integer(), Output :: binary()}` (124 on timeout, with
%% the port force-closed). The exact port pattern of `twocore_bindings_ffi:277-292`.
run_port(Cc, Args, Cwd) ->
    Port = erlang:open_port(
        {spawn_executable, Cc},
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
        {124, <<Acc/binary, "HARNESS:cc timed out">>}
    end.

%% Prepend a UTF-8 label to a (possibly large) diagnostic binary.
prefix(Label, Output) -> <<Label/binary, Output/binary>>.

%% A writable, per-call unique temp dir path under `$TMPDIR` (or `/tmp`). Not created here — the caller
%% `filelib:ensure_dir/1`s it. The monotonic-unique suffix prevents collisions.
fresh_dir(Prefix) ->
    Tmp =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            T -> T
        end,
    filename:join(Tmp, Prefix ++ "_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).
