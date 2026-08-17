%%% carder_codegen_ffi — the «FFI-SHIM» (Unit 04).
%%%
%%% Turns Erlang Abstract Format *forms* (built in-memory by
%%% `carder/backend/eaf`) into a loaded `.beam` module inside the running VM.
%%% This is the backend's last seam (decision D10): everything the codegen
%%% units (03/08/10/11) produce is run through here to prove it is real,
%%% preemptible BEAM code.
%%%
%%% Module-name hygiene (overview §5): compiled/loaded module names share one
%%% flat Erlang namespace with OTP. This hand-written FFI module is prefixed
%%% `carder_` so it can NEVER collide with an OTP module (`compile`, `lists`,
%%% …); generated modules are prefixed `carder@…`.
%%%
%%% Why abstract forms (NOT textual Core Erlang): the previous backend printed
%%% `.core` text and re-parsed it with the compiler-internal
%%% `core_scan`/`core_parse` modules plus the UNDOCUMENTED textual `from_core`
%%% entry — an OTP-release-fragile print→re-parse round trip that also cost an
%%% ~85 MB text transient on large guests. Abstract forms are the DOCUMENTED
%%% `erts/absform` contract consumed natively by `compile:forms/2`: no text, no
%%% scanner, no parser, stable across OTP releases.
%%%
%%% Error-shape normalization: `compile:forms` reports
%%%   {error, [{File,[ErrInfo]}], _W}   (per-file nested)
%%% where ErrInfo = {Loc, Mod, Desc}, Desc is a TERM (not a string), and Loc is
%%% {Line,Col} | Line | none. We fold it into ONE flat `[Binary]` list of
%%% "<loc>: <message>" lines (message via `Mod:format_error/1`), so the Gleam
%%% `Result(_, [String])` is stable. A crash inside the compiler on a malformed
%%% form list is caught and rendered the same way (fail-closed, D8 — the shim
%%% never brings the build VM down on bad input).
-module(carder_codegen_ffi).
-export([id/1, compile_forms/1, forms_to_erl/1, load_module/3]).

%% id(Term) -> Term.
%%
%% The identity coercion the Gleam side uses to forget a node tuple's Gleam
%% type (a Gleam tuple IS the Erlang term, so building an abstract-format node
%% from Gleam is a plain tuple literal passed through here).
id(X) -> X.

%% compile_forms(Forms) -> {ok, {Module, Beam}} | {error, [Binary]}
%%
%% Forms is a list of Erlang Abstract Format forms (`-module`/`-export`
%% attributes + `{function,…}` forms — `erts/absform`). On success the returned
%% Module atom is taken from the `-module` attribute. On failure every
%% diagnostic is returned as a flat list of human-readable "<loc>: <message>"
%% binaries.
compile_forms(Forms) when is_list(Forms) ->
    compile_forms_guarded(Forms, []).

%% forms_to_erl(Forms) -> Binary
%%
%% Pretty-print abstract forms as Erlang SOURCE text (`erl_pp`) — the debug /
%% inspection surface (the CLI's `to-erl`). Total for well-formed forms; a
%% malformed node is rendered by erl_pp's own fallback rather than crashing
%% the dump.
forms_to_erl(Forms) when is_list(Forms) ->
    unicode:characters_to_binary([[erl_pp:form(F), $\n] || F <- Forms]).

%% perf5 CFunRef workaround: emit_core now emits bare `'jsf_K'/N` fun-ref
%% VALUES for zero-capture closures (perf5_cfunref_zero_capture). On some
%% OTP-29 builds many such refs inside one large js_main crash beam_ssa_opt's
%% ssa_opt_type_start (fun-type-lattice badmatch — an OTP-internal error, not
%% a diagnostic). Retry once with `no_type_opt` (whole type-opt phase off; the
%% finest-grained safe skip per ../arc/test/emit_carder_cfunref_spike.gleam). OTP
%% 29's fold_comp (compile.erl:1333) already wraps every pass in try/catch and
%% returns pass crashes as a CLEAN {error,[{F,[{none,compile,{crash,…}}]}],W}
%% — so the retry must key off that descriptor, not (only) a raised exception.
%% A clean {error,…} WITHOUT a crash descriptor is a real diagnostic and
%% surfaces unchanged, so well-formed modules keep the full optimizer.
%% Options: `binary` returns the `.beam` in-memory (never touches disk);
%% `return_errors`/`return_warnings` select the tuple (not printed) report
%% shapes; `nowarn_unused_vars` silences the one warning class alpha-renamed
%% codegen output legitimately triggers en masse (fresh pattern binders used
%% as wildcards), keeping the warning list from growing O(module) on large
%% guests. Speed knobs, measured on the raytrace forms: no_bool_opt /
%% no_share_opt / no_bsm_opt / no_recv_opt each land within 4% of the
%% compile:forms baseline (their passes cost <0.5 s combined) and are NOT
%% set; no_ssa_opt halves it but at +36% .beam with every SSA optimisation
%% off. `no_type_opt` (== no_ssa_opt_type_start/continue/finish; start+continue
%% alone crash ssa_opt_type_finish) cuts the 294k-word raytrace forms 835 ms
%% -> 713 ms (min of 5, load ~15) but the v8v7 raytrace ROW came out +7.7%
%% (122,121 -> 131,484 µs, min of 3 interleaved, load 10-15; richards /
%% deltablue / crypto within noise), so it is NOT set either — the type
%% passes are the ones that delete guards. `no_ssa_opt_sink` IS set: with
%% `time`, ssa_opt_sink alone was 4.5 s of beam_ssa_opt's 9.0 s (it only
%% moves get_tuple_element later on the path; it never removes work), and
%% skipping it took the 1.72M-word raytrace forms from 11.7 s to 7.0 s (min
%% of 2) at -0.1% .beam bytes, with the v8v7 probe's richards/deltablue/
%% crypto/raytrace ROWs unchanged within noise (min of 3).
compile_forms_guarded(Forms, Extra) ->
    Opts = [binary, return_errors, return_warnings, nowarn_unused_vars,
            no_ssa_opt_sink | Extra],
    try compile:forms(Forms, Opts) of
        {ok, Mod, Beam, _W} -> {ok, {Mod, Beam}};
        {ok, Mod, Beam}     -> {ok, {Mod, Beam}};
        {error, Errs, _W} when Extra =:= [] ->
            case has_crash_desc(Errs) of
                true ->
                    io:format(standard_error,
                              "[codegen] no_type_opt retry (crash-desc) mod=~p~n",
                              [forms_module(Forms)]),
                    case compile_forms_guarded(Forms, [no_type_opt]) of
                        {ok, _} = Ok  -> Ok;
                        {error, Msgs} -> {error, fmt_errs(Errs) ++ Msgs}
                    end;
                false -> {error, fmt_errs(Errs)}
            end;
        {error, Errs, _W}   -> {error, fmt_errs(Errs)};
        error               -> {error, [<<"module: compile:forms failed">>]}
    catch
        Class:Reason when Extra =:= [] ->
            io:format(standard_error,
                      "[codegen] no_type_opt retry (catch ~p:~0p) mod=~p~n",
                      [Class, Reason, forms_module(Forms)]),
            case compile_forms_guarded(Forms, [no_type_opt]) of
                {ok, _} = Ok -> Ok;
                {error, Msgs} ->
                    {error, [crash_line(Class, Reason) | Msgs]}
            end;
        Class:Reason ->
            {error, [crash_line(Class, Reason)]}
    end.

%% The module name from a form list's `-module` attribute, for the retry log
%% line only. `unknown` when absent (a malformed list the compiler will reject
%% anyway) — never crashes the diagnostic path.
forms_module(Forms) ->
    case [M || {attribute, _, module, M} <- Forms] of
        [Mod | _] -> Mod;
        []        -> unknown
    end.

%% True iff the compiler's per-file error list carries an internal-pass-crash
%% descriptor (compile.erl fold_comp emits {none,compile,{crash,Pass,R,Stk}}).
has_crash_desc(Errs) ->
    lists:any(fun({_F, EIs}) ->
                  lists:any(fun({_, compile, {crash, _, _, _}}) -> true;
                               (_) -> false
                            end, EIs)
              end, Errs).

%% One-line rendering of an OTP-compiler crash so the Gleam side sees a
%% List(String) diagnostic (never a raw exit) even when the retry also fails.
crash_line(Class, Reason) ->
    R = iolist_to_binary(io_lib:format("~0p", [Reason])),
    Head = case byte_size(R) > 200 of
               true  -> <<(binary:part(R, 0, 200))/binary, "...">>;
               false -> R
           end,
    <<"module: OTP compiler crashed (", (atom_to_binary(Class, utf8))/binary,
      "): ", Head/binary>>.

%% Flatten the compiler's per-file nested error list into one flat list of
%% rendered binary lines.
fmt_errs(Errs) -> lists:flatten([[fmt_one(EI) || EI <- EIs] || {_F, EIs} <- Errs]).

%% Render one ErrInfo `{Loc, Mod, Desc}` into a "<loc>: <message>" binary.
%% Desc is a TERM; render it via the reporting module's `format_error/1`.
fmt_one({Loc, Mod, Desc}) ->
    Msg = unicode:characters_to_binary(Mod:format_error(Desc)),
    <<(loc_bin(Loc))/binary, ": ", Msg/binary>>.

%% Normalize the three location shapes to text. `none` (module-level) -> "module".
loc_bin({L, _C})              -> integer_to_binary(L);
loc_bin(L) when is_integer(L) -> integer_to_binary(L);
loc_bin(none)                 -> <<"module">>.

%% load_module(Mod, Filename, Beam) -> {ok, Mod} | {error, Binary}
%%
%% Loads a `.beam` binary into the CURRENT VM (D10). Mod must match the name
%% baked into Beam. Filename is metadata only (surfaced by `code:which`). On
%% rejection the VM's error atom is returned as a binary (e.g. <<"sticky_directory">>).
%%
%% Filename normalization: `code:load_binary/3` requires a `file:filename()`,
%% i.e. an Erlang STRING (char list) — it raises `function_clause` on a binary.
%% A Gleam `String` crosses the FFI as a binary, so we convert it to a char list
%% here (`unicode:characters_to_list/1` is idempotent for lists, so a list
%% caller also works).
load_module(Mod, Filename, Beam) ->
    FnList = unicode:characters_to_list(Filename),
    case code:load_binary(Mod, FnList, Beam) of
        {module, Mod}  -> {ok, Mod};
        {error, What}  -> {error, atom_to_binary(What, utf8)}
    end.
