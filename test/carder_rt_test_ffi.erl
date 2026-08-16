%%% carder_rt_test_ffi — test-only helpers for unit 09 (runtime defaults).
%%%
%%% Catching an Erlang exception is not expressible in pure Gleam (this
%%% gleam_erlang version exposes no `rescue`), so these tiny helpers let the
%%% spec tests assert the *class* and *shape* of the errors `rt_trap` and
%%% `rt_host` raise — exactly as unit 07's conformance matcher will
%%% (`try ... catch error:{wasm_trap, Kind}`).
%%%
%%% Namespace hygiene (overview §5): prefixed `carder_` so it can never
%%% collide with an OTP module. Pure: no NIF, cannot crash the node.
-module(carder_rt_test_ffi).
-export([trap_kind/1, host_denial/1]).

%% trap_kind(F) -> {ok, KindBin} | {error, DescBin}
%%
%% Run the 0-arity fun F. Succeed ONLY if F raises an ERROR-class exception
%% whose reason is exactly {wasm_trap, Kind} with Kind an atom, returning
%% {ok, Kind-as-utf8-binary}. Every other outcome is a contract violation,
%% reported as {error, Description}:
%%   - F returned normally        -> "returned_normally:<term>"
%%   - wrong class (throw/exit)   -> "<class>:<reason>"
%%   - error with another shape   -> "<class>:<reason>"
%% Because only the {wasm_trap, atom} ERROR shape yields {ok, _}, the test
%% proves the exception *class* and the *term shape*, not merely "it raised".
trap_kind(F) ->
    try F() of
        V -> {error, iolist_to_binary(io_lib:format("returned_normally:~p", [V]))}
    catch
        error:{wasm_trap, Kind} when is_atom(Kind) ->
            {ok, atom_to_binary(Kind, utf8)};
        Class:Reason ->
            {error, iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.

%% host_denial(F) -> {ok, {CapBin, NameBin}} | {error, DescBin}
%%
%% Like trap_kind/1 but for the deny-all host: succeed ONLY if F raises an
%% ERROR-class {capability_denied, Cap, Name}, returning the echoed capability
%% and name (as binaries) so the test can assert the denial identifies what was
%% rejected. Any other outcome -> {error, Description} as above.
host_denial(F) ->
    try F() of
        V -> {error, iolist_to_binary(io_lib:format("returned_normally:~p", [V]))}
    catch
        error:{capability_denied, Cap, Name} ->
            {ok, {to_bin(Cap), to_bin(Name)}};
        Class:Reason ->
            {error, iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.

%% Normalize an echoed capability/name to a binary (Gleam String). Values
%% passed from Gleam are already binaries; atoms/other terms are rendered.
to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A)   -> atom_to_binary(A, utf8);
to_bin(X)                   -> iolist_to_binary(io_lib:format("~p", [X])).
