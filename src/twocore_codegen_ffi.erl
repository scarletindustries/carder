%%% twocore_codegen_ffi — the «FFI-SHIM» (Unit 04).
%%%
%%% Turns Erlang Abstract Format *forms* (built in-memory by
%%% `twocore/backend/eaf`) into a loaded `.beam` module inside the running VM.
%%% This is the backend's last seam (decision D10): everything the codegen
%%% units (03/08/10/11) produce is run through here to prove it is real,
%%% preemptible BEAM code.
%%%
%%% Module-name hygiene (overview §5): compiled/loaded module names share one
%%% flat Erlang namespace with OTP. This hand-written FFI module is prefixed
%%% `twocore_` so it can NEVER collide with an OTP module (`compile`, `lists`,
%%% …); generated modules are prefixed `twocore@…`.
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
-module(twocore_codegen_ffi).
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
%%
%% Options: `binary` returns the `.beam` in-memory (never touches disk);
%% `return_errors`/`return_warnings` select the tuple (not printed) report
%% shapes; `nowarn_unused_vars` silences the one warning class alpha-renamed
%% codegen output legitimately triggers en masse (fresh pattern binders used
%% as wildcards), keeping the warning list from growing O(module) on large
%% guests.
compile_forms(Forms) when is_list(Forms) ->
    try compile:forms(Forms, [binary, return_errors, return_warnings,
                              nowarn_unused_vars]) of
        {ok, Mod, Beam, _W} -> {ok, {Mod, Beam}};
        {ok, Mod, Beam}     -> {ok, {Mod, Beam}};
        {error, Errs, _W}   -> {error, fmt_errs(Errs)};
        error               -> {error, [<<"module: compile:forms failed">>]}
    catch
        Class:Reason ->
            Msg = io_lib:format("compiler crashed: ~0p:~0p", [Class, Reason]),
            {error, [unicode:characters_to_binary(Msg)]}
    end.

%% forms_to_erl(Forms) -> Binary
%%
%% Pretty-print abstract forms as Erlang SOURCE text (`erl_pp`) — the debug /
%% inspection surface (the CLI's `to-erl`). Total for well-formed forms; a
%% malformed node is rendered by erl_pp's own fallback rather than crashing
%% the dump.
forms_to_erl(Forms) when is_list(Forms) ->
    unicode:characters_to_binary([[erl_pp:form(F), $\n] || F <- Forms]).

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
