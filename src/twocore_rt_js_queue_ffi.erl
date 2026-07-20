%%% Backing store for the microtask job queue (`rt_js_types.JobQueue`) —
%%% Erlang's `queue` module (two-list Okasaki FIFO). O(1) amortized in/out vs
%%% a List+append O(n) per enqueue. Vendored verbatim from arc's
%%% `arc_job_queue_ffi.erl` (M1a §10).
-module(twocore_rt_js_queue_ffi).
-export([job_queue_new/0, job_queue_push/2, job_queue_pop/1,
         job_queue_is_empty/1, job_queue_to_list/1]).

job_queue_new() -> queue:new().
job_queue_push(Q, Item) -> queue:in(Item, Q).
job_queue_pop(Q) ->
    case queue:out(Q) of
        {{value, Item}, Q2} -> {some, {Item, Q2}};
        {empty, _} -> none
    end.
job_queue_is_empty(Q) -> queue:is_empty(Q).
job_queue_to_list(Q) -> queue:to_list(Q).
