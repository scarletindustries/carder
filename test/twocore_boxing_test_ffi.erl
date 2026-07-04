%% Test-only FFI shim for the Phase-8 unit-04 (term↔numeric boxing bridge) e2e tests.
%%
%% Hand-written Erlang, so it carries the `twocore_` namespace prefix (overview §5), and
%% it touches no unit-owned source file. Its sole job is to compute the raw IEEE-754 bit
%% pattern of a native float — the D5 representation the boxing bridge round-trips — so the
%% test can DERIVE its float constants from readable decimal literals (1.5, 2.5, 4.0)
%% instead of hand-encoding hex. (Trap-capturing `catch_apply/3` is reused from
%% `twocore_emit_test_ffi`.)
-module(twocore_boxing_test_ffi).
-export([f64_bits/1, f32_bits/1]).

%% The raw 64-bit IEEE-754 pattern of a FINITE double `F`, as an integer in [0, 2^64).
%% Only called on finite values (NaN/±Inf are supplied to the test as hex bit patterns
%% directly, since `<<F/float>>` cannot ENCODE them — the very reason D5 keeps floats as
%% bits).
f64_bits(F) ->
    <<B:64>> = <<F/float>>,
    B.

%% The raw 32-bit IEEE-754 pattern of `F` rounded to binary32, as an integer in [0, 2^32).
f32_bits(F) ->
    <<B:32>> = <<F:32/float>>,
    B.
