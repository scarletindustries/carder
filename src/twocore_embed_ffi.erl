-module(twocore_embed_ffi).

%% Deserialize a `twocore/embed` artifact blob (produced by `to_artifact`, i.e.
%% `erlang:term_to_binary/1` of a `Compiled` record) back into the term, catching
%% a malformed / truncated / foreign binary rather than crashing the caller.
%%
%% `[safe]` refuses to fabricate atoms not already present on the node — an
%% artifact only references constructor atoms from code that is already loaded
%% (it was produced by this same compiler), so a valid artifact always decodes,
%% while a corrupt one fails closed as `{error, _}`.
-export([from_binary/1]).

from_binary(Bin) ->
    try {ok, binary_to_term(Bin, [safe])}
    catch _:_ -> {error, <<"malformed 2core artifact">>} end.
