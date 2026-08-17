%% Test-only direct-host ops for the `ReadMiss` differential test
%% (`test/carder/backend/direct_host_test.gleam`). Hand-written Erlang, so it carries the
%% `carder_` namespace prefix (overview §5).
-module(carder_readmiss_test_ffi).
-export([probe/2, slow/2]).

%% The value-only probe: `miss` for key 0, otherwise the doubled key. Never touches `St`.
probe(_St, 0) -> miss;
probe(_St, N) -> N * 2.

%% The `Mut` kernel the miss arm falls to: `{V, St'}` with `St` threaded back unchanged.
slow(St, N) -> {N + 100, St}.
