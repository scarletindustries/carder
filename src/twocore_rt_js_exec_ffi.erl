%%% twocore_rt_js_exec_ffi — the top-level protected apply for a compiled
%%% JS module's `js_main/3` entry (SPEC §19.8; run_js_beam / run_js_beam_in).
%%%
%%% Hand-written Erlang, so it carries the `twocore_` namespace prefix
%%% (overview §5) and can NEVER collide with an OTP module — exactly like
%%% `twocore_rt_js_call_ffi`. Pure apply + native try/catch: no NIF, no
%%% process state, cannot crash the node.
%%%
%%% Why a shim: the M20 harness must catch the SAME `{wasm_exn, 0, [St, V]}`
%%% term that `twocore_rt_js_store_ffi:t_throw/2` raises (R2 payload order
%%% `[St, V]`) at the OUTERMOST frame — an uncaught JS throw unwinds all the
%%% way to `js_main`'s caller — and recover BOTH the mutated `St'` (so
%%% `t_console_bytes` sees console lines emitted before the throw) AND the
%%% thrown JsVal. Gleam has no `try…catch` over an opaque `erlang:apply/3`.
%%% Any OTHER error class/shape (a `{wasm_trap,_}`, a fuel raise, an engine
%%% bug) is caught here too and rendered as a diagnostic `js_crashed` — the
%%% harness surfaces it as a diff failure rather than crashing the test run.
-module(twocore_rt_js_exec_ffi).
-export([apply_js_main/2]).

%% apply_js_main(Mod, St) -> {JsExecOutcome, St'}
%% Apply `Mod:js_main(St, Frame, [])` — the compiled top-level entry (D4
%% CompiledFn ABI: `fun(St, Frame, Args) -> {V, St'}`). `Frame` is the D5
%% top-level frame `{undefined,undefined,undefined,undefined}` (this=undefined,
%% active_func/home_object/new_target all undefined at Script top). `Args`
%% is `[]` (a Script entry takes no arguments). Wraps the outcome as a Gleam
%% `pipeline.JsExecOutcome` wire term:
%%   * `{js_returned, V}` — normal completion; V is the (undefined) js_main
%%     return value; St' is the final threaded state.
%%   * `{js_threw, E}` — uncaught JS exception (R2: state FIRST, thrown value
%%     SECOND in the payload list); E is the thrown JsVal; St' is the mutated
%%     state at throw-time.
%%   * `{js_crashed, Reason}` — a trap or any other BEAM error; Reason is the
%%     rendered term; St' is the INPUT St (unchanged — no recoverable state).
apply_js_main(Mod, St) ->
    %% Drop any stale own-data-prop overlay from a prior run so re-applying
    %% a shared seed observes an identical fresh realm; flush on every exit
    %% path so the returned St' is self-contained (see obj_ffi header).
    twocore_rt_js_obj_ffi:jsv_clear(),
    Frame = {undefined, undefined, undefined, undefined},
    try Mod:js_main(St, Frame, []) of
        {V, St2} -> {{js_returned, V}, twocore_rt_js_obj_ffi:jsv_flush(St2)}
    catch
        error:{wasm_exn, 0, [St2, E]} ->
            {{js_threw, E}, twocore_rt_js_obj_ffi:jsv_flush(St2)};
        Class:Reason:Stk ->
            twocore_rt_js_obj_ffi:jsv_clear(),
            {{js_crashed, render_reason(Class, Reason, Stk)}, St}
    end.

%% Render a non-wasm_exn crash as a UTF-8 binary for `Error(String)`. Mirrors
%% `twocore_cli_ffi:catch_apply`'s `~0p` formatting so the same trap phrases
%% (`{wasm_trap,int_div_by_zero}` etc.) are substring-matchable, plus the
%% class + top of the stack for engine-bug diagnosis.
render_reason(Class, Reason, Stk) ->
    Top = case Stk of [H | _] -> H; [] -> no_stack end,
    unicode:characters_to_binary(
        io_lib:format("~0p:~0p at ~0p", [Class, Reason, Top])).
