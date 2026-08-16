%%% carder_rt_js_ffi — the JS-semantics engine behind `rt_js` (the `"js"`
%%% capability boundary, Phase-8 unit 05 / HANDOFF-arc-frontend.md §4).
%%%
%%% Hand-written Erlang, so it carries the `carder_` namespace prefix
%%% (overview §5) and can NEVER collide with an OTP module — exactly like
%%% `carder_codegen_ffi`/`carder_rt_state_ffi`. Tier-P/O: pure BEAM terms +
%%% process-dictionary cells, no NIF, cannot crash the node.
%%%
%%% Why an FFI shim at all: every op here is DYNAMIC by nature — it inspects an
%%% arbitrary BEAM term's runtime shape (`is_integer`/`is_binary`/`is_reference`
%%% guards), catches `badarith` to resolve IEEE overflow into the ±Infinity
%%% sentinels, and reads/writes the process dictionary (the same
%%% instance-state-in-pdict model as `rt_state`'s `cell` strategy). Expressing
%%% that through gleam_stdlib's `dynamic` decoders would be long and slow;
%%% pattern-matching it in Erlang is direct and zero-copy. `rt_js.gleam` is the
%%% typed facade (the module `emit_core` actually targets); every public
%%% function there delegates 1:1 to a function here.
%%%
%%% ## The value model (FIXED — shared with the arc JS emitter)
%%%
%%% - number: a native BEAM integer or float. NaN / +Infinity / -Infinity are
%%%   the sentinel atoms `js_nan` / `js_inf` / `js_neg_inf` (BEAM floats cannot
%%%   represent them).
%%% - boolean: the atoms `true` / `false`. undefined: `undefined`. null: `null`.
%%% - string: a UTF-8 binary.
%%% - cell (mutable storage): an `erlang:make_ref()` keyed into the process
%%%   dictionary under `{carder_rt_js_cell, Ref}`.
%%% - object: a cell whose pdict value is a map from binary keys to term
%%%   values; numeric keys are normalized to their JS string form.
%%% - function: a BEAM fun (built by the IR's `make_closure`).
%%% - error: `erlang:error({js_error, Kind, Detail})`, Kind an atom such as
%%%   `type_error`. (JS try/catch integration is a later milestone.)
%%%
%%% ## Known divergences from ECMAScript (documented, deliberate for v1)
%%%
%%% - Integer arithmetic is exact BEAM bignum arithmetic — it never loses
%%%   precision or overflows to a float the way a JS double does (2^53 + 1 is
%%%   exact here). This is inherent to the int-as-smi encoding.
%%% - `to_string` of a non-integral float uses `float_to_binary/2 [short]`
%%%   (shortest round-trip, same principle as Number::toString) but Erlang's
%%%   exponent formatting differs from JS at the extremes: Erlang prints
%%%   `1.0e30` where JS prints `1e+30`, and JS only switches to exponent form
%%%   below 1e-6 / at-or-above 1e21. Integral floats < 1e21 print without the
%%%   `.0` (matching JS `String(5.0) =:= "5"`).
%%% - String→number coercion (`eq`, relational ops) parses decimal forms,
%%%   `Infinity` variants, and the `.5`/`5.`/`1e3` shapes; it does NOT parse
%%%   the `0x`/`0o`/`0b` radix prefixes (they coerce to NaN here).
%%% - Relational compare of two strings is byte-wise lexicographic on the
%%%   UTF-8 binaries. This equals code-POINT order, which diverges from JS's
%%%   UTF-16 code-UNIT order for astral-plane vs U+E000..U+FFFF comparisons
%%%   (e.g. "\x{10000}" < "\x{FFFF}" is true in JS, false here).
%%% - Objects/functions coerce to NaN in relational ops (no ToPrimitive walk
%%%   yet) and are a `type_error` on the string-concat path of `add`.
%%% - A finite/finite division that overflows only through BIGNUM→float
%%%   conversion (operands beyond 1.797e308) resolves to ±Infinity by sign;
%%%   exact-magnitude information is unrepresentable in a JS number anyway.
-module(carder_rt_js_ffi).

-export([
    add/2, sub/2, mul/2, neg/1, divide/2, modulo/2,
    lt/2, le/2, gt/2, ge/2, strict_eq/2, eq/2,
    truthy/1, to_string/1, type_of/1,
    cell_new/1, cell_get/1, cell_set/2,
    new_object/0, get_prop/2, set_prop/3, has_prop/2,
    empty_list/0, console_log/1, not_callable/1
]).

%% The pdict key of a cell (namespaced so it can never collide with
%% `rt_state`'s instance key or a generated module's own keys).
-define(CELL_KEY(Ref), {carder_rt_js_cell, Ref}).

%% ───────────────────────── errors ─────────────────────────

%% Raise the JS runtime error convention: `{js_error, Kind, Detail}`.
type_error(Detail) -> erlang:error({js_error, type_error, Detail}).

%% ───────────────────────── classification ─────────────────────────

%% The JS type of a BEAM term under the fixed value model. `other` is any
%% term the model does not name (tuples/maps/lists/pids — internal reprs).
js_type(V) when is_integer(V); is_float(V) -> number;
js_type(js_nan) -> number;
js_type(js_inf) -> number;
js_type(js_neg_inf) -> number;
js_type(true) -> boolean;
js_type(false) -> boolean;
js_type(V) when is_binary(V) -> string;
js_type(undefined) -> undefined;
js_type(null) -> null;
js_type(V) when is_reference(V) -> object;
js_type(V) when is_function(V) -> function;
js_type(_) -> other.

%% Normalize a JS number into the internal numeric domain
%% `number() | nan | inf | neg_inf`; any non-number is a type_error (the
%% arithmetic ops' contract).
num_of(V) when is_integer(V); is_float(V) -> V;
num_of(js_nan) -> nan;
num_of(js_inf) -> inf;
num_of(js_neg_inf) -> neg_inf;
num_of(V) -> type_error(V).

%% Internal numeric domain → the external sentinel atoms.
out(nan) -> js_nan;
out(inf) -> js_inf;
out(neg_inf) -> js_neg_inf;
out(N) -> N.

%% ±infinity by sign (S < 0 → -Infinity).
signed_inf(S) when S < 0 -> neg_inf;
signed_inf(_) -> inf.

%% Sign of a NONZERO number (overflow-resolution paths only).
sign(N) when N < 0 -> -1;
sign(_) -> 1.

%% Sign of any number, honouring a float zero's IEEE sign bit (so 1/-0.0 can
%% resolve to -Infinity). An integer 0 counts as positive (JS has no int -0).
zero_aware_sign(N) when is_float(N) ->
    case <<N/float>> of
        <<1:1, _:63>> -> -1;
        _ -> 1
    end;
zero_aware_sign(N) when N < 0 -> -1;
zero_aware_sign(_) -> 1.

%% ±0.0 by sign (finite / ±Infinity → a signed zero, per IEEE).
signed_zero(S) when S < 0 -> -0.0;
signed_zero(_) -> 0.0.

bool_int(true) -> 1;
bool_int(false) -> 0.

%% ───────────────────────── arithmetic ─────────────────────────

%% JS `+`. Either operand a string → concatenation (the other operand coerced
%% via to_string; only primitives are coercible — an object/fun is a
%% type_error, no ToPrimitive walk yet). Otherwise numeric, sentinel-aware.
add(A, B) when is_binary(A); is_binary(B) ->
    <<(concat_operand(A))/binary, (concat_operand(B))/binary>>;
add(A, B) ->
    out(nadd(num_of(A), num_of(B))).

%% A string-concat operand: numbers, booleans, null, undefined and strings
%% coerce via to_string; objects/funs/other are a type_error (v1 — no
%% ToPrimitive).
concat_operand(V) ->
    case js_type(V) of
        object -> type_error(V);
        function -> type_error(V);
        other -> type_error(V);
        _ -> to_string(V)
    end.

%% IEEE add over the internal domain. NaN propagates; Inf + -Inf is NaN; a
%% finite float overflow resolves to ±Infinity (same-sign operands, so the
%% sign is the first operand's).
nadd(nan, _) -> nan;
nadd(_, nan) -> nan;
nadd(inf, neg_inf) -> nan;
nadd(neg_inf, inf) -> nan;
nadd(inf, _) -> inf;
nadd(_, inf) -> inf;
nadd(neg_inf, _) -> neg_inf;
nadd(_, neg_inf) -> neg_inf;
nadd(A, B) ->
    try A + B catch error:badarith -> signed_inf(sign(A)) end.

%% JS binary `-` (numeric only). Same-signed-infinity difference is NaN; an
%% overflow of A - B carries A's sign (|A| dominates when it overflows).
sub(A, B) ->
    out(nsub(num_of(A), num_of(B))).

nsub(nan, _) -> nan;
nsub(_, nan) -> nan;
nsub(inf, inf) -> nan;
nsub(neg_inf, neg_inf) -> nan;
nsub(inf, _) -> inf;
nsub(neg_inf, _) -> neg_inf;
nsub(_, inf) -> neg_inf;
nsub(_, neg_inf) -> inf;
nsub(A, B) ->
    try A - B catch error:badarith -> signed_inf(sign(A)) end.

%% JS `*` (numeric only). Infinity × 0 is NaN; otherwise signs multiply; a
%% finite float overflow resolves to ±Infinity by the operands' signs.
mul(A, B) ->
    out(nmul(num_of(A), num_of(B))).

nmul(nan, _) -> nan;
nmul(_, nan) -> nan;
nmul(inf, B) -> inf_times(1, B);
nmul(neg_inf, B) -> inf_times(-1, B);
nmul(A, inf) -> inf_times(1, A);
nmul(A, neg_inf) -> inf_times(-1, A);
nmul(A, B) ->
    try A * B catch error:badarith -> signed_inf(sign(A) * sign(B)) end.

%% ±Infinity × X: another infinity multiplies signs; any zero is NaN; a
%% nonzero finite scales the sign.
inf_times(S, inf) -> signed_inf(S);
inf_times(S, neg_inf) -> signed_inf(-S);
inf_times(_, B) when B == 0 -> nan;
inf_times(S, B) -> signed_inf(S * sign(B)).

%% JS unary `-` (numeric only). NaN stays NaN; infinities flip. (An integer 0
%% negates to integer 0 — the int encoding has no -0; JS's -0 arises only on
%% the float side, where -(0.0) is a true -0.0.)
neg(A) ->
    out(nneg(num_of(A))).

nneg(nan) -> nan;
nneg(inf) -> neg_inf;
nneg(neg_inf) -> inf;
nneg(N) -> -N.

%% JS `/`. Always real division (7/2 is 3.5). x/±0 is ±Infinity by the signs
%% (0/0 NaN); ±Inf/±Inf is NaN; finite/±Inf is a signed zero; a finite float
%% overflow (or a beyond-double bignum conversion) resolves to ±Infinity.
divide(A, B) ->
    out(ndiv(num_of(A), num_of(B))).

ndiv(nan, _) -> nan;
ndiv(_, nan) -> nan;
ndiv(A, B) when
    (A =:= inf orelse A =:= neg_inf), (B =:= inf orelse B =:= neg_inf)
->
    nan;
ndiv(inf, B) -> signed_inf(zero_aware_sign(B));
ndiv(neg_inf, B) -> signed_inf(-zero_aware_sign(B));
ndiv(A, inf) -> signed_zero(zero_aware_sign(A));
ndiv(A, neg_inf) -> signed_zero(-zero_aware_sign(A));
ndiv(A, B) when B == 0 ->
    case A == 0 of
        true -> nan;
        false -> signed_inf(zero_aware_sign(A) * zero_aware_sign(B))
    end;
ndiv(A, B) ->
    try A / B catch error:badarith -> signed_inf(sign(A) * sign(B)) end.

%% JS `%` — fmod with the DIVIDEND's sign. y = ±0 or non-finite x → NaN;
%% finite x with infinite y → x. Integer pairs use exact `rem` (same sign
%% rule); mixed/float pairs use math:fmod. A bignum beyond double range
%% cannot fmod (badarith) → NaN, documented.
modulo(A, B) ->
    out(nmod(num_of(A), num_of(B))).

nmod(nan, _) -> nan;
nmod(_, nan) -> nan;
nmod(inf, _) -> nan;
nmod(neg_inf, _) -> nan;
nmod(A, inf) -> A;
nmod(A, neg_inf) -> A;
nmod(_, B) when B == 0 -> nan;
nmod(A, B) when is_integer(A), is_integer(B) -> A rem B;
nmod(A, B) ->
    try math:fmod(A, B) catch error:badarith -> nan end.

%% ───────────────────────── comparisons ─────────────────────────

%% The four relational ops: 1|0 int terms. Two strings compare byte-wise
%% lexicographically (see the module-header divergence note); anything else
%% coerces to a number (booleans → 0/1, null → 0, undefined → NaN, strings →
%% parsed, objects/funs → NaN). Any NaN-involving compare is 0.
lt(A, B) -> rel(A, B, [lt]).
le(A, B) -> rel(A, B, [lt, eq]).
gt(A, B) -> rel(A, B, [gt]).
ge(A, B) -> rel(A, B, [gt, eq]).

rel(A, B, Wanted) ->
    case js_cmp(A, B) of
        undefined -> 0;
        Order -> bool_int(lists:member(Order, Wanted))
    end.

%% lt | eq | gt, or `undefined` when NaN is involved (every relation false).
js_cmp(A, B) when is_binary(A), is_binary(B) ->
    if
        A =:= B -> eq;
        A < B -> lt;
        true -> gt
    end;
js_cmp(A, B) ->
    ncmp(coerce_num(A), coerce_num(B)).

%% ToNumber-ish coercion for the relational operators (NOT the arithmetic
%% ops, which type_error on non-numbers).
coerce_num(V) ->
    case js_type(V) of
        number -> num_of(V);
        boolean -> bool_int(V);
        null -> 0;
        undefined -> nan;
        string -> str_to_num(V);
        %% object/function/other → NaN (no ToPrimitive yet — header note).
        _ -> nan
    end.

ncmp(nan, _) -> undefined;
ncmp(_, nan) -> undefined;
ncmp(inf, inf) -> eq;
ncmp(neg_inf, neg_inf) -> eq;
ncmp(inf, _) -> gt;
ncmp(_, inf) -> lt;
ncmp(neg_inf, _) -> lt;
ncmp(_, neg_inf) -> gt;
ncmp(A, B) ->
    if
        A == B -> eq;
        A < B -> lt;
        true -> gt
    end.

%% JS `===`: same JS type AND same value. NaN ≠ NaN; +0 == -0; ints and
%% floats are ONE number type (1 === 1.0). Objects/cells compare by ref
%% identity; strings by binary equality; funs by fun identity.
strict_eq(A, B) ->
    TA = js_type(A),
    case TA =:= js_type(B) of
        false -> 0;
        true ->
            case TA of
                number -> num_strict_eq(num_of(A), num_of(B));
                _ -> bool_int(A =:= B)
            end
    end.

num_strict_eq(nan, _) -> 0;
num_strict_eq(_, nan) -> 0;
num_strict_eq(inf, inf) -> 1;
num_strict_eq(neg_inf, neg_inf) -> 1;
%% a lone sentinel against a finite number (or the opposite infinity) — the
%% matching-pair clauses above caught the equal cases.
num_strict_eq(X, Y) when is_atom(X); is_atom(Y) -> 0;
num_strict_eq(X, Y) -> bool_int(X == Y).

%% The JS `==` SUBSET: strict equality, plus null == undefined, number ==
%% string (string coerced to number), and boolean → number coercion. An
%% object against a primitive is 0 (no ToPrimitive yet); object == object is
%% ref identity via the strict path.
eq(A, B) ->
    case strict_eq(A, B) of
        1 -> 1;
        0 -> loose_eq(js_type(A), js_type(B), A, B)
    end.

loose_eq(null, undefined, _, _) -> 1;
loose_eq(undefined, null, _, _) -> 1;
loose_eq(number, string, A, B) -> num_strict_eq(num_of(A), str_to_num(B));
loose_eq(string, number, A, B) -> num_strict_eq(str_to_num(A), num_of(B));
loose_eq(boolean, _, A, B) -> eq(bool_int(A), B);
loose_eq(_, boolean, A, B) -> eq(A, bool_int(B));
loose_eq(_, _, _, _) -> 0.

%% ───────────────────────── truthiness / coercion ─────────────────────────

%% JS ToBoolean → 1|0. Falsy: false, null, undefined, NaN, all numeric
%% zeros (0, 0.0, -0.0), the empty string. Everything else — including empty
%% objects and every fun — is truthy.
truthy(false) -> 0;
truthy(null) -> 0;
truthy(undefined) -> 0;
truthy(js_nan) -> 0;
truthy(V) when is_integer(V); is_float(V) ->
    case V == 0 of
        true -> 0;
        false -> 1
    end;
truthy(<<>>) -> 0;
truthy(_) -> 1.

%% JS ToString → a binary. Strings pass through; integral floats < 1e21 print
%% integer-style (String(5.0) = "5"); other floats use [short] (shortest
%% round-trip — exponent FORMATTING diverges from Number::toString at the
%% extremes, header note). Objects (and internal reprs) are "[object
%% Object]"; funs are the "function" placeholder.
to_string(V) when is_binary(V) -> V;
to_string(V) when is_integer(V) -> integer_to_binary(V);
to_string(V) when is_float(V) ->
    case trunc(V) == V andalso abs(V) < 1.0e21 of
        true -> integer_to_binary(trunc(V));
        false -> float_to_binary(V, [short])
    end;
to_string(true) -> <<"true">>;
to_string(false) -> <<"false">>;
to_string(null) -> <<"null">>;
to_string(undefined) -> <<"undefined">>;
to_string(js_nan) -> <<"NaN">>;
to_string(js_inf) -> <<"Infinity">>;
to_string(js_neg_inf) -> <<"-Infinity">>;
to_string(V) when is_function(V) -> <<"function">>;
%% references (objects/cells) and any internal repr (tuple/map/list/…).
to_string(_) -> <<"[object Object]">>.

%% JS `typeof` → a binary. Sentinel numbers are "number"; null is famously
%% "object"; cells/objects (refs) are "object"; funs are "function".
type_of(V) ->
    case js_type(V) of
        number -> <<"number">>;
        boolean -> <<"boolean">>;
        string -> <<"string">>;
        undefined -> <<"undefined">>;
        null -> <<"object">>;
        function -> <<"function">>;
        object -> <<"object">>;
        other -> <<"object">>
    end.

%% ───────────────────────── string → number ─────────────────────────

%% JS Number(string): trimmed; "" → 0; "±Infinity" → ±inf; decimal integer or
%% float, with the JS-legal-but-Erlang-illegal shapes (".5", "5.", "1e3")
%% normalized before binary_to_float. Radix prefixes ("0x10") → NaN (header
%% divergence note).
str_to_num(Bin) ->
    T = string:trim(Bin),
    case T of
        <<>> -> 0;
        <<"Infinity">> -> inf;
        <<"+Infinity">> -> inf;
        <<"-Infinity">> -> neg_inf;
        _ ->
            try
                binary_to_integer(T)
            catch
                error:badarg ->
                    try
                        binary_to_float(float_fixup(T))
                    catch
                        error:badarg -> nan
                    end
            end
    end.

%% binary_to_float demands a digit on BOTH sides of the dot and a dot before
%% an exponent; JS Number() does not. Rewrite ".5" → "0.5", "5." → "5.0",
%% "1e3" → "1.0e3" (sign prefix preserved); a bare "." stays invalid.
float_fixup(B) ->
    {Sign, Body} =
        case B of
            <<"-", R/binary>> -> {<<"-">>, R};
            <<"+", R/binary>> -> {<<>>, R};
            _ -> {<<>>, B}
        end,
    {Mant, Exp} =
        case binary:split(Body, [<<"e">>, <<"E">>]) of
            [M, E] -> {M, <<"e", E/binary>>};
            [M] -> {M, <<>>}
        end,
    <<Sign/binary, (fix_mantissa(Mant))/binary, Exp/binary>>.

fix_mantissa(<<>>) -> <<>>;
fix_mantissa(<<".">>) -> <<".">>;
fix_mantissa(M) ->
    M1 =
        case M of
            <<".", _/binary>> -> <<"0", M/binary>>;
            _ -> M
        end,
    case binary:match(M1, <<".">>) of
        nomatch ->
            <<M1/binary, ".0">>;
        _ ->
            case binary:last(M1) of
                $. -> <<M1/binary, "0">>;
                _ -> M1
            end
    end.

%% ───────────────────────── cells ─────────────────────────

%% A fresh mutable cell holding Init: a make_ref() keyed into THIS process's
%% dictionary (the same one-instance-one-process model as rt_state's `cell`
%% strategy — cells live and die with the instance process).
cell_new(Init) ->
    Ref = erlang:make_ref(),
    erlang:put(?CELL_KEY(Ref), Init),
    Ref.

%% The cell's current value. (An absent key reads as the atom `undefined` —
%% indistinguishable from a stored `undefined`, which is semantically the
%% same JS value.) A non-ref receiver is a type_error.
cell_get(Ref) when is_reference(Ref) -> erlang:get(?CELL_KEY(Ref));
cell_get(V) -> type_error(V).

%% Store V in the cell; returns `undefined` (JS assignment-as-expression is
%% the emitter's concern, not the cell's).
cell_set(Ref, V) when is_reference(Ref) ->
    erlang:put(?CELL_KEY(Ref), V),
    undefined;
cell_set(Ref, _) ->
    type_error(Ref).

%% ───────────────────────── objects ─────────────────────────

%% A fresh empty object: a cell holding an empty map (binary keys → values).
new_object() ->
    cell_new(#{}).

%% The object's backing map; a non-ref, a dead ref, or a cell holding a
%% non-map is a type_error (an object receiver was required).
obj_map(Obj) when is_reference(Obj) ->
    case erlang:get(?CELL_KEY(Obj)) of
        M when is_map(M) -> M;
        _ -> type_error(Obj)
    end;
obj_map(Obj) ->
    type_error(Obj).

%% Property keys are binaries; a NUMBER key normalizes to its JS string form
%% (5, 5.0 and "5" are the same key — to_string's integral-float rule does
%% this). Any other key type is a type_error (no ToPropertyKey walk yet).
prop_key(K) when is_binary(K) -> K;
prop_key(K) ->
    case js_type(K) of
        number -> to_string(K);
        _ -> type_error(K)
    end.

%% obj[key] — the stored value, or `undefined` when absent. No prototype
%% chain yet (v1: own properties only).
get_prop(Obj, Key) ->
    maps:get(prop_key(Key), obj_map(Obj), undefined).

%% obj[key] = v — stores and returns v (the value of a JS assignment).
set_prop(Obj, Key, V) ->
    erlang:put(?CELL_KEY(Obj), maps:put(prop_key(Key), V, obj_map(Obj))),
    V.

%% key in obj → 1|0 (own properties only, like get_prop).
has_prop(Obj, Key) ->
    bool_int(maps:is_key(prop_key(Key), obj_map(Obj))).

%% ───────────────────────── lists / console / misc ─────────────────────────

%% The empty BEAM list [] — the nil tail every args-cons-list build starts
%% from (the IR has no [] literal; see the registry note).
empty_list() -> [].

%% console.log(...args) — takes ONE term, the cons list of the arguments.
%% Prints them space-separated on one line (strings bare, numbers/atoms via
%% the to_string rules, objects "[object Object]", funs "function") and
%% returns `undefined`. A non-list is a type_error (the emitter always passes
%% the args list).
console_log(Args) when is_list(Args) ->
    Line = lists:join(<<" ">>, [to_string(A) || A <- Args]),
    io:put_chars([Line, $\n]),
    undefined;
console_log(V) ->
    type_error(V).

%% The emitter's guard for `callee(...)` where the callee failed is_fun:
%% always raises the JS TypeError convention carrying the offending value.
not_callable(V) ->
    erlang:error({js_error, type_error, V}).
