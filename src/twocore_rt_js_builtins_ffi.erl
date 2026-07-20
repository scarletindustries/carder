%%% twocore_rt_js_builtins_ffi — the M4→M6 native-dispatch seam.
%%%
%%% `rt_js_call.gleam:83-98` forward-declares `dispatch_native/4` and
%%% `dispatch_native_construct/4` as `@external(erlang,
%%% "twocore_rt_js_builtins_ffi", ...)` so `rt_js_call` can compile before
%%% `rt_js_builtins` exists (SPEC §7.M6 — @external targets are unresolved by
%%% `gleam check`). This shim just forwards to the real Gleam bodies in
%%% `twocore@runtime@rt_js_builtins` — the ONE place native dispatch lives.
%%%
%%% Hand-written Erlang, so it carries the `twocore_` namespace prefix
%%% (overview §5) and cannot collide with an OTP module.
-module(twocore_rt_js_builtins_ffi).
-export([dispatch_native/4, dispatch_native_construct/4]).

%% dispatch_native(St, Tag, This, Args) -> {JsVal, St'}.
dispatch_native(St, Tag, This, Args) ->
    twocore@runtime@rt_js_builtins:dispatch_native(St, Tag, This, Args).

%% dispatch_native_construct(St, Tag, Args, NewTarget) -> {Handle, St'}.
dispatch_native_construct(St, Tag, Args, NewTarget) ->
    twocore@runtime@rt_js_builtins:dispatch_native_construct(St, Tag, Args, NewTarget).
