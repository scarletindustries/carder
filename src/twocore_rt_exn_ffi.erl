%%% twocore_rt_exn_ffi — the build-fixed WASM-exception term shim for `rt_exn`
%%% (Phase-7, J1/J5; T3/T6/T7/T9).
%%%
%%% Hand-written Erlang, so it carries the `twocore_` namespace prefix (overview
%%% §5) and can NEVER collide with an OTP module — exactly like
%%% `twocore_rt_ref_ffi`/`twocore_rt_state_ffi`. Pure term construction /
%%% pattern matching + native raise: no NIF, no process state, cannot crash the
%%% node.
%%%
%%% Why a shim: the exception representation is a fixed-atom tuple that Gleam's
%%% `dynamic` API cannot construct/destructure or raise ergonomically:
%%%
%%%   WASM exception -> {wasm_exn, TagId, Payload}   (3-tuple; T6 Cell-only — NO
%%%                                                    state field). TagId is the
%%%                                                    module-local tag index (an
%%%                                                    Int, T4); Payload is the
%%%                                                    operand value list.
%%%   exnref (caught) -> {ref_exn, Reason}           (T9 reason-only box; reuses
%%%                                                    rt_ref's box discipline —
%%%                                                    uncollidable with {ref_null}
%%%                                                    / {ref_extern,_} / a funcref).
%%%
%%% ## Raise CLASS (frozen — coordinate with P7-06's catch)
%%%
%%% A `{wasm_exn, …}` is raised at **ERROR class** (`erlang:error/1`), so it rides
%%% the SAME catchable channel as `rt_trap`'s error-class `{wasm_trap, Kind}`
%%% (rt_exn.gleam module doc): the emitted top-level run-ABI catches `error:R` once
%%% and dispatches on the term shape ({wasm_exn,_,_} => UncaughtException,
%%% {wasm_trap,_} => Trapped — T8). The per-clause `try…catch <C,R,S>` P7-06 emits
%%% catches ALL classes and decides caught-vs-reraise by the TERM SHAPE (match_tag /
%%% is_wasm_exn), so correctness never depends on the class — the class is only a
%%% distinctness convenience. `reraise/3` preserves whatever class was caught.
-module(twocore_rt_exn_ffi).
-export([throw_exn/2, match_tag/2, is_wasm_exn/1, capture_exnref/1,
         reraise/3, rethrow_exnref/1, is_exnref/1]).

%% throw_exn(TagId, Payload) -> no_return()
%% Build the build-fixed exception term and raise it (ERROR class — same channel
%% as a {wasm_trap,_} trap; the catch dispatches on the term shape, not the class).
%% D3a: the shape is fixed, `Payload` is carried as DATA — never an apply target.
throw_exn(TagId, Payload) -> erlang:error({wasm_exn, TagId, Payload}).

%% match_tag(Reason, TagId) -> {ok, Payload} | {error, nil}
%% The per-clause catch match (`catch $t`): Ok iff Reason is a wasm exn of EXACTLY
%% TagId (T4 — one identity for throw + catch). A DIFFERENT tag, a {wasm_trap,_}
%% trap, or any other BEAM term -> {error, nil} (the caller re-raises). {ok,_}/
%% {error, nil} is the Gleam Result(_, Nil) wire shape.
match_tag({wasm_exn, TagId, Payload}, TagId) -> {ok, Payload};
match_tag(_, _) -> {error, nil}.

%% is_wasm_exn(Reason) -> boolean()
%% The `catch_all` gate (T7, LOAD-BEARING): true ONLY for a wasm exn
%% {wasm_exn,_,_}. NEVER true for a {wasm_trap,_} trap (incl. fuel_exhausted /
%% memory_out_of_bounds), a BEAM error, or an exit — so a `catch_all` built on it
%% lets a trap PROPAGATE (a trap is not a WASM exception; the sandbox floor).
is_wasm_exn({wasm_exn, _, _}) -> true;
is_wasm_exn(_) -> false.

%% capture_exnref(Reason) -> {ref_exn, Reason}
%% Box a caught `Reason` as an opaque, forge-proof exnref (T9 reason-only). Total
%% over any Reason (in practice only ever a {wasm_exn,_,_}, since it is called only
%% after a positive match — traps are never caught). The box makes the caught
%% exception uncollidable with {ref_null} / {ref_extern,_} / a funcref, and OPAQUE
%% (no unwrap is exported — Safe code cannot read TagId/Payload).
capture_exnref(Reason) -> {ref_exn, Reason}.

%% reraise(Class, Reason, Stacktrace) -> no_return()
%% Faithfully re-raise a non-matching caught exception, preserving class + reason +
%% stacktrace (spec §4.4.9 unwinding — an unmatched exception propagates UNCHANGED
%% to the next outer handler; a trap that entered a `try` escapes it identically).
reraise(Class, Reason, Stacktrace) -> erlang:raise(Class, Reason, Stacktrace).

%% rethrow_exnref({ref_exn, Reason}) -> no_return()   (throw_ref of a NON-null exnref)
%% Re-raise the captured reason as a FRESH raise (T9 — WASM exceptions carry NO
%% observable stacktrace, so a fresh raise point is spec-faithful; contrast
%% reraise/3, which preserves the stack for a pass-through). ERROR class, to match
%% throw_exn's channel (so a re-thrown exnref is indistinguishable from an original
%% throw at the top-level run-ABI).
rethrow_exnref({ref_exn, Reason}) -> erlang:error(Reason).

%% is_exnref(X) -> boolean()   (structural {ref_exn,_} test; opaque — no unwrap)
%% A funcref {FuncType, Closure}, an externref {ref_extern,_}, a null {ref_null}, a
%% raw thrown {wasm_exn,_,_} (3-tuple), a v128 binary, and an Int all fail to match.
is_exnref({ref_exn, _}) -> true;
is_exnref(_) -> false.
