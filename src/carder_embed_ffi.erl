-module(carder_embed_ffi).

%% Deserialize a `carder/embed` artifact blob (produced by `to_artifact`, i.e.
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
    try upgrade(binary_to_term(Bin))
    catch _:_ -> {error, <<"malformed carder artifact">>} end.

%% Back-compat for the `extra` (helper-chunk) field added to the `Compiled` record. An artifact
%% serialized BEFORE that field existed is the 3-element tuple `{compiled, Beam, Module}`; the
%% current record is the 4-element `{compiled, Beam, Module, Extra}`. A node running the newer
%% compiler must still boot a deployment whose artifact was cached by the OLDER compiler (the cache
%% is durable and survives a worker upgrade), so rewrite the legacy shape to the current one with an
%% empty helper-chunk list — a pre-chunking guest simply has no helper modules. Any already-current
%% (4-tuple) or otherwise-shaped term passes through untouched; a genuinely-malformed blob still
%% fails closed via the catch in `from_binary/1` (and the downstream `instantiate` shape check).
upgrade({compiled, Beam, Module}) -> {ok, {compiled, Beam, Module, []}};
upgrade(Term) -> {ok, Term}.
