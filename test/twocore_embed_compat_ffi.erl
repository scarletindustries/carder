%%% Test helper: fabricate a PRE-`extra`-field embed artifact.
%%%
%%% Before the `Compiled` record gained its helper-chunk `extra` field, `to_artifact` produced the
%%% 3-element tuple `{compiled, Beam, Module}`. This builds exactly that legacy blob so a test can
%%% prove the current `from_artifact` upgrades it (durable caches survive a compiler upgrade).
-module(twocore_embed_compat_ffi).
-export([legacy_artifact/2]).

legacy_artifact(Beam, Module) ->
    erlang:term_to_binary({compiled, Beam, Module}).
