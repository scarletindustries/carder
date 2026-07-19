%%% twocore_linker_ffi — the whole-program Core-Erlang linker (Phase 11 · P11-03).
%%%
%%% Merges a generated (wasm-derived) module and its ENTIRE transitive
%%% twocore/gleam dependency closure into ONE self-contained `.beam` whose only
%%% remaining remote calls are to the fixed OTP-ambient allowlist — every
%%% `twocore@*`/`gleam@*` dependency merged in, dead code stripped, no ambient
%%% authority. It is the same OTP-29-internals trust boundary as
%%% `twocore_codegen_ffi.erl` (decision D10 / R1); it reuses the compiler's own
%%% `cerl`/`cerl_trees`/`core_lint`/`core_pp`/`compile` machinery.
%%%
%%% PINNED TO OTP 29. Relies on the compiler-internal `cerl`/`cerl_trees`/
%%% `core_lint`/`core_pp` modules, the `debug_info` chunk `core_v1` backend
%%% contract, and the (undocumented) `from_core` entry for compiling the merged
%%% cerl — all of which may change between OTP releases. Verified on OTP 29.
%%% (The GENERATED module now arrives as documented Erlang Abstract Format
%%% forms and is lowered to cerl via the compiler's own `to_core` pass; the
%%% textual `core_scan`/`core_parse` route is gone.)
%%%
%%% ── The algorithm (spec §3, decisions R1/R4/R5/R6/R9/R10/R11) ─────────────
%%%
%%% 1. ACQUIRE the generated module's Core from its ABSTRACT FORMS via the
%%%    compiler's own `to_core` pass (`compile:forms/2` stopped at Core), with
%%%    the auto-added `module_info/0,1` stripped. Its declared module name must
%%%    equal `ModuleName`.
%%% 2. REACHABILITY (R6): a worklist from the ROOTS — the generated module's
%%%    exports (public exports + the synthesized `instantiate/N`) — following
%%%    THREE edge kinds (R4): remote `#c_call` to an in-closure module, an
%%%    intra-module local `apply` on an `fname`, AND a fun-capture literal
%%%    (`fun M:F/A`, which `debug_info` reconstructs as a `literal` node wrapping
%%%    an external `fun` VALUE). Edges to an ambient module STOP (left remote).
%%%    Each first-reached in-closure module `M` is acquired via
%%%    `beam_lib:chunks(code:which(M),[debug_info])` → `Backend:debug_info(
%%%    core_v1,…)` (R1; `compile:file(F,[to_core])` fallback).
%%% 3. REJECT unmergeable constructs (R15): `-on_load`/behaviour attrs in any
%%%    closure module (verified absent in tier-P/O; this keeps it so).
%%% 4. MANGLE + REWRITE (R5) via `cerl_trees:map`, per module: every DEFINED
%%%    function `M:F/A` gets a fresh local name `mangle(M,F)/A` (the generated
%%%    module is the identity — it KEEPS its names so its public exports stay
%%%    callable; every discovered module `M` becomes `'M__F'`, injective because
%%%    no in-closure atom contains `__`, R12). The three node classes are then
%%%    rewritten: (1) in-closure remote `#c_call` → local `apply` of the mangled
%%%    name; (2) intra-module local `apply` on an `fname` → the self-mangled
%%%    name; (3) fun-captures — EVERY external `fun M:F/A` embedded in a literal,
%%%    whether bare or nested inside a compound term (tuple/list/map, e.g. gleam's
%%%    `{decoder, fun …/1}`) — an in-closure target becomes a bare LOCAL funref
%%%    `'M__F'/A` (a `c_fname` value the compiler sees as a call-graph edge, so
%%%    it does NOT DCE the target back out — an `erlang:make_fun` of a literal
%%%    local name WOULD be silently stripped), an ambient target stays external
%%%    as `erlang:make_fun(M,F,A)`. Ambient remote calls are left untouched.
%%% 5. DCE: only reached defs are assembled — everything else is dropped.
%%% 6. ASSEMBLE one `#c_module{}` (R11): strip every source `module_info/{0,1}`
%%%    and all module attributes; synthesize exactly one `module_info/{0,1}`
%%%    pair for the merged atom; export exactly the generated module's original
%%%    exports + `module_info/{0,1}`. Sort defs deterministically (R10) and
%%%    strip all node annotations (so the bytes depend only on merge order +
%%%    mangling + DCE, not source line/file info).
%%% 7. STRUCTURAL D3a SELF-CHECK (R9), fail-closed refuse-to-emit: reject
%%%    `erlang:apply`, any remote call to a module neither the merged atom nor
%%%    on the allowlist, any computed-module remote call, and any residual
%%%    fun-capture to an off-closure/off-allowlist module. Legitimate first-class
%%%    `apply Op(Args)` and the now-local mangled funref applies are NOT flagged.
%%% 8. DETERMINISTIC COMPILE (R10): `core_lint:module/1` then
%%%    `compile:forms(Merged,[from_core,binary,deterministic,return_errors])`.
%%%
%%% ── Error contract ──────────────────────────────────────────────────────
%%% Every failure returns `{error, {TagBin, ABin, BBin}}` — a flat 3-binary
%%% tuple the Gleam side (`beam_link`) maps onto its `LinkError` variants with
%%% no term decoding. Unused fields are `<<>>`. The tags are:
%%%   off_allowlist_remote | missing_closure_module | ambient_authority |
%%%   unmergeable_construct | mangle_collision | malformed_core |
%%%   core_acquisition_failed.
-module(twocore_linker_ffi).
-export([link_program/3, link_to_core/3]).

-define(SEP, "__").

%% ── Public entry points ───────────────────────────────────────────────────

%% link_program(GeneratedForms, ModuleName, Ambient)
%%   -> {ok, {Module :: atom(), Beam :: binary()}} | {error, ErrTuple}
%%
%% Merge + deterministic-compile to a loadable `.beam`. `GeneratedForms` is the
%% generated module's Erlang Abstract Format form list (what
%% `twocore/backend/eaf` emits); `ModuleName` is the merged module's atom name
%% (binary); `Ambient` is a list of allowlist module-name binaries (the DCE
%% stop-set). On success the returned Module atom equals the name declared
%% inside the returned Beam.
link_program(GeneratedForms, ModuleName, Ambient) ->
    case build_merged(GeneratedForms, ModuleName, Ambient) of
        {ok, {Name, CMod}} -> compile_merged(Name, CMod);
        {error, _} = E -> E
    end.

%% link_to_core(GeneratedForms, ModuleName, Ambient)
%%   -> {ok, {Module :: atom(), CoreText :: binary()}} | {error, ErrTuple}
%%
%% The SAME merge as `link_program`, returning the merged Core Erlang TEXT
%% *before* compilation — the seam P11-06 uses to independently re-run the
%% structural D3a assertion and inspect DCE. Single-sourced with `link_program`
%% via `build_merged/3` (both run the fail-closed D3a self-check).
link_to_core(GeneratedForms, ModuleName, Ambient) ->
    case build_merged(GeneratedForms, ModuleName, Ambient) of
        {ok, {Name, CMod}} ->
            Txt = unicode:characters_to_binary(core_pp:format(CMod)),
            {ok, {Name, Txt}};
        {error, _} = E -> E
    end.

%% ── The merge pipeline (steps 1–7) ────────────────────────────────────────

%% Produce the merged `#c_module{}` (name + cerl), fail-closed. Wrapped in a
%% catch so any unexpected internal crash surfaces as a typed `malformed_core`
%% error rather than a raw exception across the FFI boundary (D8, fail-closed).
build_merged(GeneratedForms, ModuleNameBin, AmbientBins) ->
    try
        MergedName = binary_to_atom(ModuleNameBin, utf8),
        Ambient = sets:from_list([binary_to_atom(B, utf8) || B <- AmbientBins]),
        %% (1) acquire the generated module from its abstract FORMS.
        GenCMod = acquire_generated(GeneratedForms, MergedName),
        %% (2) reachability + lazy acquisition of the discovered closure.
        St0 = #{merged => MergedName, ambient => Ambient,
                mods => #{MergedName => index_module(GenCMod)},
                reached => sets:new()},
        Roots = [{MergedName, key(E)} || E <- cerl:module_exports(GenCMod)],
        St1 = reach(Roots, St0),
        %% (3) reject unmergeable constructs across every acquired module.
        ok = check_mergeable(maps:get(mods, St1)),
        %% assert the mangle-injectivity precondition (R12) over discovered mods.
        ok = check_mangle_injective(maps:keys(maps:get(mods, St1)), MergedName),
        %% (4/5/6) mangle + rewrite reached defs (DCE = only reached), assemble.
        CMod = assemble(St1, GenCMod),
        %% (7) structural D3a self-check, fail-closed refuse-to-emit.
        ok = d3a_check(CMod, MergedName, Ambient),
        {ok, {MergedName, CMod}}
    catch
        throw:{link_error, ErrTuple} -> {error, ErrTuple};
        Class:Reason:Stack ->
            {error, {<<"malformed_core">>,
                     iolist_to_binary(io_lib:format("~p:~p ~p",
                                                    [Class, Reason, Stack])),
                     <<>>}}
    end.

%% Abort the merge with a typed error (unwound by `build_merged`'s catch).
fail(Tag, A, B) -> throw({link_error, {Tag, bin(A), bin(B)}}).

bin(B) when is_binary(B) -> B;
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(L) when is_list(L) -> iolist_to_binary(L);
bin(X) -> iolist_to_binary(io_lib:format("~p", [X])).

%% ── (1) Core acquisition ──────────────────────────────────────────────────

%% Lower the generated module's abstract FORMS to a `#c_module{}` via the
%% compiler's own `to_core` pass in-process (`compile:forms/2` — the same
%% documented entry the plain build uses, stopped at the Core stage), strip the
%% auto-added `module_info/0,1` defs/exports (the merge assembles its own pair
%% for the merged atom — and the pre-EAF generated Core never carried them),
%% and check that the declared module name matches the caller's `ModuleName`
%% (the merged output name). `malformed_core` on a compile failure or a name
%% mismatch.
acquire_generated(Forms, MergedName) when is_list(Forms) ->
    case compile:forms(Forms, [to_core, binary, return_errors,
                               nowarn_unused_vars]) of
        {ok, _Mod, CMod0} ->
            CMod = strip_module_info(CMod0),
            Declared = cerl:atom_val(cerl:module_name(CMod)),
            case Declared =:= MergedName of
                true -> CMod;
                false ->
                    fail(<<"malformed_core">>,
                         io_lib:format("generated module declares '~s' "
                                       "but link requested '~s'",
                                       [Declared, MergedName]),
                         <<>>)
            end;
        {error, Errs, _W} ->
            fail(<<"malformed_core">>,
                 io_lib:format("to_core failed: ~0p", [Errs]), <<>>);
        Other ->
            fail(<<"malformed_core">>,
                 io_lib:format("to_core failed: ~0p", [Other]), <<>>)
    end.

%% Drop the compiler-added `module_info/0,1` definitions + exports from a
%% freshly `to_core`-compiled generated module, restoring the invariant the
%% merge pipeline was built on (the generated module defines no module_info;
%% `assemble` emits the merged pair itself).
strip_module_info(CMod) ->
    Defs = [D || {V, _} = D <- cerl:module_defs(CMod),
                 not is_module_info(cerl:var_name(V))],
    Exports = [E || E <- cerl:module_exports(CMod),
                    not is_module_info(cerl:var_name(E))],
    cerl:update_c_module(CMod, cerl:module_name(CMod), Exports,
                         cerl:module_attrs(CMod), Defs).

is_module_info({module_info, 0}) -> true;
is_module_info({module_info, 1}) -> true;
is_module_info(_) -> false.

%% Acquire a DISCOVERED in-closure module's `#c_module{}` from its RESIDENT
%% `.beam` via the `debug_info` `core_v1` backend (R1 primary); fall back to
%% `compile:file(F,[to_core])` on the `.erl` source when no `core_v1` chunk is
%% present. `missing_closure_module` if the beam cannot be located,
%% `core_acquisition_failed` if neither path yields Core.
acquire_discovered(Mod) ->
    case code:which(Mod) of
        non_existing -> fail(<<"missing_closure_module">>, Mod, <<>>);
        Path when is_list(Path) ->
            case core_from_debug_info(Path, Mod) of
                {ok, CMod} -> CMod;
                error ->
                    case core_from_source(Mod) of
                        {ok, CMod} -> CMod;
                        error ->
                            fail(<<"core_acquisition_failed">>, Mod,
                                 <<"no core_v1 debug_info and no compilable "
                                   "source">>)
                    end
            end;
        Other ->
            fail(<<"core_acquisition_failed">>, Mod,
                 io_lib:format("code:which returned ~p", [Other]))
    end.

core_from_debug_info(Path, Mod) ->
    case beam_lib:chunks(Path, [debug_info]) of
        {ok, {Mod, [{debug_info, {debug_info_v1, Backend, Data}}]}} ->
            try Backend:debug_info(core_v1, Mod, Data, []) of
                {ok, CMod} -> {ok, CMod};
                _ -> error
            catch _:_ -> error
            end;
        _ -> error
    end.

core_from_source(Mod) ->
    Src = case code:where_is_file(atom_to_list(Mod) ++ ".erl") of
              non_existing -> non_existing;
              P -> P
          end,
    case Src of
        non_existing -> error;
        Path ->
            case compile:file(Path, [to_core, binary, return_errors]) of
                {ok, Mod, CMod} -> {ok, CMod};
                {ok, Mod, CMod, _Ws} -> {ok, CMod};
                _ -> error
            end
    end.

%% ── (2) Reachability ──────────────────────────────────────────────────────

%% Index a module's defs into #{ {F,A} => FunNode } for O(1) lookup, keeping the
%% original `#c_module{}` for its export/attr lists.
index_module(CMod) ->
    Defs = maps:from_list([{key(N), F} || {N, F} <- cerl:module_defs(CMod)]),
    #{cmod => CMod, defs => Defs}.

%% The {FunAtom, Arity} key of an `fname` node.
key(FName) -> {cerl:fname_id(FName), cerl:fname_arity(FName)}.

%% Worklist reachability. `St` carries `merged`, `ambient`, `mods` (atom =>
%% indexed module), and `reached` (set of {Module, {F,A}}). Returns the final
%% `St` with every transitively-reachable def marked and every in-closure module
%% acquired.
reach([], St) -> St;
reach([{M, FA} = Item | Rest], St) ->
    Reached = maps:get(reached, St),
    case sets:is_element(Item, Reached) of
        true -> reach(Rest, St);
        false ->
            St1 = St#{reached := sets:add_element(Item, Reached)},
            {Body, St2} = lookup_def(M, FA, St1),
            case Body of
                none -> reach(Rest, St2);
                _ ->
                    Edges = edges(Body, M, St2),
                    reach(Edges ++ Rest, St2)
            end
    end.

%% Look up the FunNode for {M,{F,A}}, acquiring M on first touch. `module_info`
%% is synthesized for the merged module, so a lookup of it returns `none` (never
%% walked into a source module_info). A referenced-but-undefined function in an
%% acquired module also returns `none` (it is simply not a live edge — e.g. an
%% imported BIF stub); it will surface at `core_lint` if actually applied.
lookup_def(M, {F, _A} = FA, St) ->
    {Mods1, St1} = ensure_acquired(M, St),
    Idx = maps:get(M, Mods1),
    Defs = maps:get(defs, Idx),
    case maps:find(FA, Defs) of
        {ok, Body} -> {Body, St1};
        error when F =:= module_info -> {none, St1};
        error -> {none, St1}
    end.

%% Ensure module M is acquired (generated is preloaded; discovered acquired
%% lazily). Returns the (possibly-updated) `mods` map and state.
ensure_acquired(M, St) ->
    Mods = maps:get(mods, St),
    case maps:is_key(M, Mods) of
        true -> {Mods, St};
        false ->
            CMod = acquire_discovered(M),
            Mods1 = Mods#{M => index_module(CMod)},
            {Mods1, St#{mods := Mods1}}
    end.

%% Collect the reachability edges out of a function body (R4/R6). Follows:
%%   - remote `#c_call` to a literal in-closure module → {TgtM, {TgtF, arity}}
%%     (ambient targets stop — no edge);
%%   - intra-module `apply` on an `fname` → {M, {F, A}};
%%   - EVERY fun-capture embedded in a literal (`fun TgtM:TgtF/A`), whether a
%%     bare `#c_literal{val=Fun}` OR nested inside a compound literal term (a
%%     tuple/list/map — e.g. gleam's `{decoder, fun …:decode_int/1}`), to an
%%     in-closure module → {TgtM, {TgtF, A}} (ambient captures stop). Missing the
%%     NESTED form both strips the target (DCE) and leaves a dangling off-closure
%%     capture — the R4 edge-(a) requirement.
edges(Body, M, St) ->
    Ambient = maps:get(ambient, St),
    cerl_trees:fold(
      fun(Node, Acc) ->
              case cerl:type(Node) of
                  literal ->
                      lists:foldl(
                        fun({TgtM, TgtF, Ar}, A) ->
                                case sets:is_element(TgtM, Ambient) of
                                    true -> A;
                                    false -> [{TgtM, {TgtF, Ar}} | A]
                                end
                        end, Acc, term_ext_funs(cerl:concrete(Node)));
                  _ ->
                      case classify(Node) of
                          {remote, TgtM, TgtF, Ar} ->
                              case sets:is_element(TgtM, Ambient) of
                                  true -> Acc;
                                  false -> [{TgtM, {TgtF, Ar}} | Acc]
                              end;
                          {local_apply, F, A} -> [{M, {F, A}} | Acc];
                          other -> Acc
                      end
              end
      end, [], Body).

%% Classify a NON-literal Core node as a reachability/rewrite-relevant edge, or
%% `other`. Shared by `edges/3` (walk) and the rewriter so the two never diverge.
%% Fun-capture LITERALs are handled separately (a single literal can carry zero
%% or many captures — see `term_ext_funs/1`).
classify(Node) ->
    case cerl:type(Node) of
        call ->
            Mod = cerl:call_module(Node),
            Fun = cerl:call_name(Node),
            case cerl:is_literal(Mod) andalso cerl:is_literal(Fun) of
                true ->
                    {remote, cerl:concrete(Mod), cerl:concrete(Fun),
                     length(cerl:call_args(Node))};
                false -> other
            end;
        apply ->
            Op = cerl:apply_op(Node),
            case cerl:is_c_fname(Op) of
                true -> {local_apply, cerl:fname_id(Op), cerl:fname_arity(Op)};
                false -> other
            end;
        _ -> other
    end.

%% Every EXTERNAL fun (`fun M:F/A`) embedded ANYWHERE in a constant term value —
%% bare, or nested inside a tuple/list/map. This is how `debug_info core_v1`
%% reconstructs `fun M:F/A` captures (R4): as a `literal` node wrapping the
%% actual fun term (which may itself be wrapped in a data structure such as
%% gleam's `Decoder` record `{decoder, Fun}`). Returns `[{M, F, A}]`.
term_ext_funs(V) when is_function(V) ->
    case erlang:fun_info(V, type) of
        {type, external} ->
            {module, M} = erlang:fun_info(V, module),
            {name, F} = erlang:fun_info(V, name),
            {arity, A} = erlang:fun_info(V, arity),
            [{M, F, A}];
        _ -> []
    end;
term_ext_funs(V) when is_tuple(V) ->
    lists:flatmap(fun term_ext_funs/1, tuple_to_list(V));
term_ext_funs(V) when is_map(V) ->
    lists:flatmap(fun term_ext_funs/1, maps:keys(V)) ++
        lists:flatmap(fun term_ext_funs/1, maps:values(V));
term_ext_funs([H | T]) -> term_ext_funs(H) ++ term_ext_funs(T);
term_ext_funs(_) -> [].

%% ── (3) Mergeability guard (R15) ──────────────────────────────────────────

%% Reject any acquired closure module carrying an `-on_load` directive or a
%% `behaviour`/`behavior` attribute (a NIF loader, OTP behaviour, or load-time
%% callback cannot be merged). Verified absent in tier-P/O; this keeps it so.
check_mergeable(Mods) ->
    maps:foreach(
      fun(M, Idx) ->
              CMod = maps:get(cmod, Idx),
              lists:foreach(
                fun({K, _V}) ->
                        case cerl:atom_val(K) of
                            on_load ->
                                fail(<<"unmergeable_construct">>,
                                     io_lib:format("~s carries -on_load", [M]),
                                     <<>>);
                            behaviour ->
                                fail(<<"unmergeable_construct">>,
                                     io_lib:format("~s is an OTP behaviour", [M]),
                                     <<>>);
                            behavior ->
                                fail(<<"unmergeable_construct">>,
                                     io_lib:format("~s is an OTP behaviour", [M]),
                                     <<>>);
                            _ -> ok
                        end
                end, cerl:module_attrs(CMod))
      end, Mods),
    ok.

%% Assert the R12 mangle-injectivity precondition: no DISCOVERED in-closure
%% module atom contains the `__` separator (the generated module keeps its own
%% names, so it is exempt). `mangle_collision` otherwise.
check_mangle_injective(Modules, MergedName) ->
    lists:foreach(
      fun(M) when M =:= MergedName -> ok;
         (M) ->
              case string:find(atom_to_list(M), ?SEP) of
                  nomatch -> ok;
                  _ -> fail(<<"mangle_collision">>, M,
                            io_lib:format("module atom contains '~s'", [?SEP]))
              end
      end, Modules),
    ok.

%% ── (4/5/6) Mangle, rewrite, DCE, assemble ────────────────────────────────

%% Assemble the merged `#c_module{}` from the reached set: mangle+rewrite each
%% reached def (DCE = only reached defs included), synthesize the merged
%% `module_info/{0,1}`, export exactly the generated exports + `module_info`,
%% drop all attributes, sort deterministically, and strip node annotations.
assemble(St, GenCMod) ->
    MergedName = maps:get(merged, St),
    Ambient = maps:get(ambient, St),
    Mods = maps:get(mods, St),
    Reached = sets:to_list(maps:get(reached, St)),
    RCtx = #{merged => MergedName, ambient => Ambient},
    Defs0 =
        lists:filtermap(
          fun({M, {F, _A} = FA}) when F =/= module_info ->
                  Idx = maps:get(M, Mods),
                  case maps:find(FA, maps:get(defs, Idx)) of
                      {ok, Body} ->
                          NewName = mangle(M, FA, MergedName),
                          NewBody = strip_ann(rewrite(Body, M, RCtx)),
                          {true, {NewName, NewBody}};
                      error -> false
                  end;
             ({_M, _FA}) -> false
          end, Reached),
    %% (6) synthesized module_info/{0,1} for the merged atom.
    Infos = module_info_defs(MergedName),
    Defs = sort_defs(Defs0 ++ Infos),
    %% export exactly the generated module's original exports + module_info.
    GenExports = [strip_ann(E) || E <- cerl:module_exports(GenCMod)],
    Exports = dedup(GenExports ++ [cerl:c_fname(module_info, 0),
                                   cerl:c_fname(module_info, 1)]),
    cerl:c_module(cerl:c_atom(MergedName), Exports, [], Defs).

%% The fresh local name for a DEFINED function `M:F/A`. The generated module
%% (M == MergedName) is the IDENTITY so its public exports stay callable under
%% their original names; every discovered module becomes `'M__F'` (the full
%% module atom in the name ⇒ collision-free, R12).
mangle(M, {F, A}, MergedName) when M =:= MergedName -> cerl:c_fname(F, A);
mangle(M, {F, A}, _MergedName) ->
    cerl:c_fname(list_to_atom(atom_to_list(M) ++ ?SEP ++ atom_to_list(F)), A).

%% Rewrite the THREE node classes (R5) in a function body defined in module `M`,
%% via a single bottom-up `cerl_trees:map`. `RCtx` carries the merged name and
%% the ambient set.
rewrite(Body, M, RCtx) ->
    MergedName = maps:get(merged, RCtx),
    Ambient = maps:get(ambient, RCtx),
    cerl_trees:map(
      fun(Node) ->
              case cerl:type(Node) of
                  literal ->
                      %% (3) fun-captures — bare OR nested in a compound literal.
                      case term_ext_funs(cerl:concrete(Node)) of
                          [] -> Node;
                          _ ->
                              term_to_expr(cerl:concrete(Node), MergedName,
                                           Ambient)
                      end;
                  _ ->
                      case classify(Node) of
                          {remote, TgtM, TgtF, Ar} ->
                              case sets:is_element(TgtM, Ambient) of
                                  true -> Node;   %% ambient remote → untouched
                                  false ->
                                      %% (1) in-closure remote → local mangled apply
                                      Name = mangle(TgtM, {TgtF, Ar}, MergedName),
                                      cerl:c_apply(Name, cerl:call_args(Node))
                              end;
                          {local_apply, F, A} ->
                              %% (2) intra-module apply → self-mangled name
                              NewOp = mangle(M, {F, A}, MergedName),
                              cerl:c_apply(NewOp, cerl:apply_args(Node));
                          other -> Node
                      end
              end
      end, Body).

%% Rebuild a constant term `V` (which contains at least one embedded external
%% fun) as a Core EXPRESSION, replacing every embedded `fun M:F/A` capture:
%%   - an IN-CLOSURE target → a bare LOCAL funref `'M__F'/A` (a `c_fname` used as
%%     a value). This is critical: `erlang:make_fun('Merged','M__F',A)` is opaque
%%     to the Erlang compiler's OWN reachability so `compile:forms` would DCE the
%%     (non-exported) target back out → runtime `undef`; a bare local funref IS a
%%     call-graph edge, so the target survives the compile (verified).
%%   - an AMBIENT target → `erlang:make_fun(M, F, A)` (stays external; the
%%     compiler needs to keep nothing local, and the module is on every node).
%% Compound structure (tuple/list/map) is reconstructed with `c_tuple`/`c_cons`/
%% `c_map`; leaves with no fun are re-abstracted verbatim. So a nested capture
%% like `{decoder, fun …:decode_int/1}` becomes `{'decoder', 'M__decode_int'/1}`.
term_to_expr(V, MergedName, Ambient) when is_function(V) ->
    case erlang:fun_info(V, type) of
        {type, external} ->
            {module, M} = erlang:fun_info(V, module),
            {name, F} = erlang:fun_info(V, name),
            {arity, A} = erlang:fun_info(V, arity),
            case sets:is_element(M, Ambient) of
                true ->
                    cerl:c_call(cerl:c_atom(erlang), cerl:c_atom(make_fun),
                                [cerl:c_atom(M), cerl:c_atom(F), cerl:c_int(A)]);
                false -> mangle(M, {F, A}, MergedName)
            end;
        _ -> cerl:abstract(V)
    end;
term_to_expr(V, MergedName, Ambient) when is_tuple(V) ->
    cerl:c_tuple([term_to_expr(E, MergedName, Ambient) || E <- tuple_to_list(V)]);
term_to_expr(V, MergedName, Ambient) when is_map(V) ->
    cerl:c_map([cerl:c_map_pair(term_to_expr(K, MergedName, Ambient),
                                term_to_expr(Val, MergedName, Ambient))
                || {K, Val} <- maps:to_list(V)]);
term_to_expr([H | T], MergedName, Ambient) ->
    cerl:c_cons(term_to_expr(H, MergedName, Ambient),
                term_to_expr(T, MergedName, Ambient));
term_to_expr(V, _MergedName, _Ambient) -> cerl:abstract(V).

%% Recursively clear every node annotation (file/line metadata) so identical
%% merges are byte-identical (R10) regardless of source location.
strip_ann(Node) ->
    cerl_trees:map(fun(N) -> cerl:set_ann(N, []) end, Node).

%% The synthesized `module_info/0` and `module_info/1` for the merged atom
%% (R11) — the standard `erlang:get_module_info` bodies. `erlang` is ambient.
module_info_defs(MergedName) ->
    F0 = cerl:c_fname(module_info, 0),
    B0 = cerl:c_fun([], cerl:c_call(cerl:c_atom(erlang),
                                    cerl:c_atom(get_module_info),
                                    [cerl:c_atom(MergedName)])),
    X = cerl:c_var('X'),
    F1 = cerl:c_fname(module_info, 1),
    B1 = cerl:c_fun([X], cerl:c_call(cerl:c_atom(erlang),
                                     cerl:c_atom(get_module_info),
                                     [cerl:c_atom(MergedName), X])),
    [{F0, B0}, {F1, B1}].

%% Deterministic def order (R10): by function name then arity.
sort_defs(Defs) ->
    lists:sort(
      fun({A, _}, {B, _}) ->
              {atom_to_list(cerl:fname_id(A)), cerl:fname_arity(A)} =<
                  {atom_to_list(cerl:fname_id(B)), cerl:fname_arity(B)}
      end, Defs).

%% Deduplicate export fnames by {id, arity}, preserving first-seen order.
dedup(FNames) ->
    {Out, _} =
        lists:foldl(
          fun(F, {Acc, Seen}) ->
                  K = key(F),
                  case sets:is_element(K, Seen) of
                      true -> {Acc, Seen};
                      false -> {[F | Acc], sets:add_element(K, Seen)}
                  end
          end, {[], sets:new()}, FNames),
    lists:reverse(Out).

%% ── (7) Structural D3a self-check (R9), fail-closed ────────────────────────

%% Scan the assembled merged module and REFUSE TO EMIT on any ambient-authority
%% construct: `erlang:apply`, a computed-module remote call, a remote call to a
%% module neither the merged atom nor on the allowlist, or a residual fun-capture
%% to an off-closure/off-allowlist module. Legitimate first-class `apply Op(Args)`
%% and now-local mangled funref applies are NOT flagged (they are `apply` nodes,
%% not `call` nodes, and carry no module atom). Every in-closure remote call
%% should already have been rewritten to a local apply, so a surviving one is a
%% linker bug surfaced here as `off_allowlist_remote` rather than a runtime undef.
d3a_check(CMod, MergedName, Ambient) ->
    lists:foreach(
      fun({_N, Fun}) ->
              cerl_trees:fold(fun(Node, _) -> d3a_node(Node, MergedName, Ambient) end,
                              ok, Fun)
      end, cerl:module_defs(CMod)),
    ok.

d3a_node(Node, MergedName, Ambient) ->
    case cerl:type(Node) of
        call ->
            Mod = cerl:call_module(Node),
            Fun = cerl:call_name(Node),
            case cerl:is_literal(Mod) of
                false ->
                    fail(<<"ambient_authority">>,
                         <<"remote call with a computed (data-derived) module">>,
                         <<>>);
                true ->
                    M = cerl:concrete(Mod),
                    %% erlang:apply is the ambient-authority MFA apply — reject
                    %% regardless of `erlang` being on the allowlist.
                    case cerl:is_literal(Fun) andalso cerl:concrete(Fun) =:= apply
                         andalso M =:= erlang of
                        true ->
                            fail(<<"ambient_authority">>,
                                 <<"erlang:apply (data-driven MFA apply)">>, <<>>);
                        false ->
                            case M =:= MergedName orelse sets:is_element(M, Ambient) of
                                true -> ok;
                                false ->
                                    FnB = case cerl:is_literal(Fun) of
                                              true -> bin(cerl:concrete(Fun));
                                              false -> <<"?">>
                                          end,
                                    %% A residual make_fun capturing an off-closure
                                    %% module is an ambient-authority hole (R4/R9).
                                    fail(<<"off_allowlist_remote">>, M, FnB)
                            end
                    end
            end;
        literal ->
            %% After the rewrite NO literal should carry an external fun (bare OR
            %% nested in a compound term) to an off-closure/off-allowlist module —
            %% those all became local funrefs / `make_fun` calls (step 4). A
            %% residual one is a rewrite MISS and a D3a hole (it would resolve to a
            %% shadowable off-node module), so fail closed (R4/R9).
            case [MF || {Mc, _, _} = MF <- term_ext_funs(cerl:concrete(Node)),
                        Mc =/= MergedName, not sets:is_element(Mc, Ambient)] of
                [] -> ok;
                [{Mc, Fc, _} | _] ->
                    fail(<<"ambient_authority">>,
                         io_lib:format("residual off-closure capture ~s:~s",
                                       [Mc, Fc]), <<>>)
            end;
        _ -> ok
    end.

%% ── (8) Deterministic compile ─────────────────────────────────────────────

%% Lint then deterministically compile the merged `#c_module{}` to a `.beam`.
%% `malformed_core` on a lint or compile diagnostic (rendered human-readably);
%% asserts the compiled module name equals the merged name.
compile_merged(MergedName, CMod) ->
    case core_lint:module(CMod) of
        {ok, _Ws} -> compile_forms(MergedName, CMod);
        {error, Es, _Ws} ->
            fail(<<"malformed_core">>, fmt_lint(Es), <<>>)
    end.

compile_forms(MergedName, CMod) ->
    case compile:forms(CMod, [from_core, binary, deterministic,
                              return_errors, return_warnings]) of
        {ok, MergedName, Beam, _Ws} -> {ok, {MergedName, Beam}};
        {ok, MergedName, Beam} -> {ok, {MergedName, Beam}};
        {ok, Other, _Beam, _Ws} ->
            fail(<<"malformed_core">>,
                 io_lib:format("compiled name ~p =/= merged ~p",
                               [Other, MergedName]), <<>>);
        {error, Es, _Ws} -> fail(<<"malformed_core">>, fmt_compile(Es), <<>>)
    end.

%% ── diagnostic rendering ───────────────────────────────────────────────────

fmt_lint(Es) ->
    iolist_to_binary(
      lists:join("; ", [io_lib:format("~p", [E]) || E <- Es])).

fmt_compile(Es) ->
    iolist_to_binary(
      lists:join("; ",
                 [Mod:format_error(Desc)
                  || {_File, EIs} <- Es, {_Loc, Mod, Desc} <- EIs])).
