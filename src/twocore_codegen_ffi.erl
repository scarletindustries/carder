%%% twocore_codegen_ffi — the «FFI-SHIM» (Unit 04).
%%%
%%% Turns Core Erlang *text* into a loaded `.beam` module inside the running
%%% VM. This is the backend's last seam (decision D10): everything the codegen
%%% units (03/08/10/11) produce is run through here to prove it is real,
%%% preemptible BEAM code.
%%%
%%% Module-name hygiene (overview §5): compiled/loaded module names share one
%%% flat Erlang namespace with OTP. This hand-written FFI module is prefixed
%%% `twocore_` so it can NEVER collide with an OTP module (`compile`, `lists`,
%%% …); generated modules are prefixed `twocore@…`.
%%%
%%% PINNED TO OTP 29. The in-memory text path relies on the compiler-internal
%%% modules `core_scan`/`core_parse` and on the UNDOCUMENTED textual `from_core`
%%% format, both of which may change between OTP releases. Verified on OTP 29.
%%%
%%% Why scan→parse→forms (NOT `compile:forms` on text): `compile:forms/2` with
%%% `from_core` expects cerl records (`#c_module{}`), not `.core` text — feeding
%%% it text crashes inside `core_lint`. So the path MUST be
%%%   core_scan:string/1 → core_parse:parse/1 → #c_module{}
%%%     → compile:forms(CMod, [from_core, binary, return_errors, return_warnings]).
%%%
%%% Error-shape normalization: the three failing stages report differently —
%%%   core_scan:string  -> {error, ErrInfo, End}
%%%   core_parse:parse  -> {error, ErrInfo}                 (bare, one level)
%%%   compile:forms     -> {error, [{File,[ErrInfo]}], _W}  (per-file nested)
%%% where ErrInfo = {Loc, Mod, Desc}, Desc is a TERM (not a string), and Loc is
%%% {Line,Col} | Line | none. We fold all three into ONE flat `[Binary]` list of
%%% "<loc>: <message>" lines (message via `Mod:format_error/1`), so the Gleam
%%% `Result(_, [String])` is stable regardless of which stage failed. NOTE: the
%%% scan/parse branches wrap their single rendered line in a list (`[fmt_one(EI)]`)
%%% so the error slot is ALWAYS a flat `[Binary]` — matching the Gleam FFI type
%%% `List(String)`. (The unit-04 doc's verbatim shim returned a bare binary here,
%%% which is inconsistent with the `compile:forms` branch and with the declared
%%% Gleam type; this is the documented-contract shape.)
-module(twocore_codegen_ffi).
-export([compile_core/1, load_module/3]).

%% compile_core(CoreBin) -> {ok, {Module, Beam}} | {error, [Binary]}
%%
%% CoreBin is `.core` source TEXT as a (byte-aligned) binary. On success the
%% returned Module atom is taken from the `.core` `module` header, not any
%% filename. On failure every diagnostic from whichever stage failed is
%% returned as a flat list of human-readable "<loc>: <message>" binaries.
%%
%% PERF (compile memory): `core_printer` pretty-prints with an indent that GROWS
%% per nesting level, and a large guest (a TeaVM/Java module) lowers to functions
%% nested hundreds of `let`/`letrec` levels deep — so a ~277 KB wasm becomes ~85 MB
%% of `.core`, of which ~94% is leading whitespace. That is catastrophic HERE
%% (only): `unicode:characters_to_list/1` turns the 85 MB binary into an ~1.4 GB
%% char list, and `core_scan` chews the lot, blowing the compile up to ~12 GiB and
%% OOM-killing a memory-capped node. The whitespace is INSIGNIFICANT to the scanner
%% (tokens stay separated by the newlines we keep), so we strip each line's leading
%% indentation before scanning — dropping the text ~15x and peak compile memory
%% ~11x (measured: 11.74 GiB -> ~1.0 GiB) with a byte-identical `.beam`. The
%% pretty-printed text `core_printer` returns is untouched (tests/debug still read
%% it); only this compile path sees the compact form.
compile_core(CoreBin) when is_binary(CoreBin) ->
    Str = unicode:characters_to_list(strip_indent(CoreBin)),
    case core_scan:string(Str) of
        {ok, Toks, _End} ->
            case core_parse:parse(Toks) of
                {ok, CMod} ->
                    case compile:forms(CMod, [from_core, binary, return_errors, return_warnings]) of
                        {ok, Mod, Beam, _W} -> {ok, {Mod, Beam}};
                        {ok, Mod, Beam}     -> {ok, {Mod, Beam}};
                        {error, Errs, _W}   -> {error, fmt_errs(Errs)}
                    end;
                {error, EI} -> {error, [fmt_one(EI)]}
            end;
        {error, EI, _End} -> {error, [fmt_one(EI)]}
    end.

%% Strip each line's LEADING indentation (spaces/tabs) while keeping the newlines
%% that separate tokens — semantics-preserving for the Core scanner. Sub-binaries
%% from `binary:split` are cheap references into `CoreBin`; the rejoined result is
%% the ~6 MB of real content (vs ~85 MB of mostly-whitespace input).
strip_indent(CoreBin) ->
    Lines = binary:split(CoreBin, <<"\n">>, [global]),
    iolist_to_binary(lists:join(<<"\n">>, [trim_leading(L) || L <- Lines])).

trim_leading(<<$\s, Rest/binary>>) -> trim_leading(Rest);
trim_leading(<<$\t, Rest/binary>>) -> trim_leading(Rest);
trim_leading(Line) -> Line.

%% Flatten the compiler's per-file nested error list into one flat list of
%% rendered binary lines. `fmt_one` already returns a single binary, so we wrap
%% it in a list for `core_parse`/`core_scan` (bare ErrInfo) callers below.
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
%% caller also works). (The unit-04 doc's verbatim shim passed Filename straight
%% through, which only works when called from Erlang with a list literal; from
%% Gleam it must be converted.)
load_module(Mod, Filename, Beam) ->
    FnList = unicode:characters_to_list(Filename),
    case code:load_binary(Mod, FnList, Beam) of
        {module, Mod}  -> {ok, Mod};
        {error, What}  -> {error, atom_to_binary(What, utf8)}
    end.
