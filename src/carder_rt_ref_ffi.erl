%%% carder_rt_ref_ffi — the forge-proof reference-value tuple shim for `rt_ref`
%%% (Phase-5 keystone, R1).
%%%
%%% Hand-written Erlang, so it carries the `carder_` namespace prefix
%%% (overview §5) and can NEVER collide with an OTP module — exactly like
%%% `carder_rt_state_ffi`. Pure term construction / pattern matching: no NIF,
%%% no process state, cannot crash the node.
%%%
%%% Why a shim: the reference value model (R1) is three tagged Core Erlang terms
%%% that Gleam's `dynamic` API cannot construct/inspect ergonomically:
%%%   null       -> {ref_null}          (a reserved 1-tuple; collision-proof)
%%%   externref  -> {ref_extern, Term}  (Term opaque; the box makes a host term
%%%                                       uncollidable with null / a funcref)
%%%   funcref    -> {FuncType, Closure}  (UNCHANGED from Phase-2 table entries — a
%%%                                       funcref value *is* a table-entry shape,
%%%                                       so `call_indirect` stays byte-identical)
%%% `null_ref/0`/`wrap_extern/1` build the first two; `is_null/1`/`is_extern/1`
%%% classify by structural match (never by comparing to attacker data). A funcref
%%% is neither, so `rt_ref:classify_ref` reports it by elimination.
-module(carder_rt_ref_ffi).
-export([null_ref/0, wrap_extern/1, is_null/1, is_extern/1]).

%% null_ref() -> {ref_null}
%% The single null sentinel shared by both reftypes (R1). `ref.is_null` is
%% `X =:= {ref_null}` for either funcref or externref.
null_ref() -> {ref_null}.

%% wrap_extern(Term) -> {ref_extern, Term}
%% Box an opaque host term as an externref. The wrapper makes the term
%% uncollidable with the null sentinel and with a funcref 2-tuple even if the
%% host hands back `{ref_null}` — `{ref_extern, {ref_null}}` is NOT null.
wrap_extern(Term) -> {ref_extern, Term}.

%% is_null(X) -> boolean()
%% True iff X is the null sentinel. Structural equality against the reserved
%% 1-tuple; no host value can forge it (Safe code cannot construct `{ref_null}`).
is_null(X) -> X =:= {ref_null}.

%% is_extern(X) -> boolean()
%% True iff X is a wrapped externref `{ref_extern, _}`. A funcref `{FuncType,
%% Closure}` has an arbitrary first element (never the atom `ref_extern` from a
%% build-controlled `ref.func`), so the two never collide.
is_extern({ref_extern, _}) -> true;
is_extern(_) -> false.
