-module(twocore_embed_ffi).

%% Deserialize a `twocore/embed` artifact blob (produced by `to_artifact`, i.e.
%% `erlang:term_to_binary/1` of a `Compiled` record) back into the term, catching
%% a malformed / truncated / foreign binary rather than crashing the caller.
%%
%% We deliberately do NOT pass `[safe]`. `[safe]` refuses to fabricate atoms not
%% already present on the node — which assumes the CONSUMER has itself run the
%% compiler (so every constructor atom in the artifact is already interned from
%% loaded code). That assumption holds when a node compiles its own guests, but
%% it BREAKS for the ahead-of-time / precompiled path: an embedder (e.g. Dance)
%% can cache an artifact compiled OFF the node and load it on a worker that never
%% runs the compiler at all, so the artifact's `ir.Module` constructor atoms were
%% never interned there and `[safe]` rejects an otherwise-valid artifact as
%% `malformed`. Artifacts are TRUSTED input — they come only from this compiler
%% via the embedder's authenticated compile/deploy cache (never from an untrusted
%% network peer), and the decoded term is inert data (its `.beam` field is loaded
%% as code, which is the artifact's whole purpose; no field is ever applied as a
%% fun), so decoding without `[safe]` is safe here. A corrupt/truncated blob still
%% fails closed as `{error, _}` via the catch, and downstream `instantiate`
%% rejects a well-formed-but-wrong-shape term.
-export([from_binary/1]).

from_binary(Bin) ->
    try {ok, binary_to_term(Bin)}
    catch _:_ -> {error, <<"malformed 2core artifact">>} end.
