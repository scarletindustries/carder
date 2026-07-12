%%% twocore_rt_js_ffi — the JS-semantics engine behind `rt_js` (the `"js"`
%%% capability boundary, Phase-8 unit 05 / HANDOFF-arc-frontend.md §4).
%%%
%%% Hand-written Erlang, so it carries the `twocore_` namespace prefix
%%% (overview §5) and can NEVER collide with an OTP module — exactly like
%%% `twocore_codegen_ffi`/`twocore_rt_state_ffi`. Tier-P/O: pure BEAM terms +
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
%%%   dictionary under `{twocore_rt_js_cell, Ref}`.
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
-module(twocore_rt_js_ffi).

-export([
    add/2, sub/2, mul/2, neg/1, divide/2, modulo/2,
    lt/2, le/2, gt/2, ge/2, strict_eq/2, eq/2,
    truthy/1, to_number/1, to_string/1, type_of/1,
    bit_and/2, bit_or/2, bit_xor/2, bit_not/1, shl/2, shr/2, ushr/2, pow/2,
    math_unary/2, math_binary/3, math_reduce/2, math_random/0,
    cell_new/1, cell_get/1, cell_set/2,
    new_object/0, get_prop/2, set_prop/3, has_prop/2, delete_prop/2,
    new_array/1, array_push/2, array_pop/1, is_array/1, array_spread_into/2,
    array_from/1, array_flat/1, array_fill/2, array_at/2,
    str_pad_start/3, str_pad_end/3, string_from_char_code/1, date_now/0,
    array_flat_map/2, array_find_last/2, array_find_last_index/2,
    array_last_index_of/2, num_to_fixed/2,
    to_string_dispatch/1, num_to_string_radix/2,
    array_map/2, array_filter/2, array_foreach/2, array_reduce/3,
    array_reduce1/2, array_some/2, array_every/2, array_find/2,
    array_find_index/2, array_index_of/2, array_includes/2, array_join/2,
    array_slice/3, array_concat/2, array_reverse/1, array_shift/1,
    array_unshift/2, array_sort/2,
    str_char_at/2, str_char_code_at/2, str_upper/1, str_lower/1,
    str_substring/3, str_split/2, str_trim/1, str_trim_start/1,
    str_trim_end/1, str_repeat/2, str_starts_with/2, str_ends_with/2,
    str_replace/3, str_replace_all/3,
    parse_int/2, parse_float/1, is_nan/1, is_finite/1, is_nullish/1,
    number_is_nan/1, number_is_finite/1, number_is_integer/1,
    object_keys/1, object_values/1, object_entries/1, object_assign_into/2,
    object_from_entries/1,
    json_stringify/1, json_parse/1,
    empty_list/0, console_log/1, not_callable/1
]).

%% The pdict key of a cell (namespaced so it can never collide with
%% `rt_state`'s instance key or a generated module's own keys).
-define(CELL_KEY(Ref), {twocore_rt_js_cell, Ref}).

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
        %% only an internal (non-JS) repr is unrepresentable; objects/arrays/functions
        %% take their to_string (`[object Object]` / comma-join / `function`).
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

%% JS ToNumber (behind unary `+` and `Number(x)`). Reuses the same coercion as the
%% relational operators — booleans/null/undefined/strings/objects per the spec — then
%% `out` maps the internal numeric domain back to a JS term (nan → js_nan, etc.).
to_number(A) ->
    out(coerce_num(A)).

%% ── bitwise / shift ops ──────────────────────────────────────────────────
%% JS bitwise operators coerce each operand with ToInt32 (or ToUint32 for the
%% left of `>>>` and both shift counts), operate on 32-bit two's-complement,
%% and yield a signed int32 — except `>>>`, whose result is an unsigned uint32.

%% ToUint32: ToNumber, truncate toward zero, take the low 32 bits. Non-finite → 0.
%% Erlang's `band 16#FFFFFFFF` gives the two's-complement low word for any integer
%% (incl. negatives), which is exactly ToUint32 on the truncated value.
js_to_uint32(V) ->
    case coerce_num(V) of
        nan -> 0;
        inf -> 0;
        neg_inf -> 0;
        N when is_integer(N) -> N band 16#FFFFFFFF;
        N when is_float(N) -> trunc(N) band 16#FFFFFFFF
    end.

%% ToInt32: reinterpret the uint32 as signed two's-complement.
js_to_int32(V) ->
    wrap_int32(js_to_uint32(V)).

%% Reinterpret an Erlang integer's low 32 bits as a signed int32.
wrap_int32(I) ->
    U = I band 16#FFFFFFFF,
    case U >= 16#80000000 of
        true -> U - 16#100000000;
        false -> U
    end.

bit_and(A, B) -> js_to_int32(A) band js_to_int32(B).
bit_or(A, B) -> js_to_int32(A) bor js_to_int32(B).
bit_xor(A, B) -> js_to_int32(A) bxor js_to_int32(B).
%% ~a == -(ToInt32(a)) - 1, always in int32 range.
bit_not(A) -> bnot js_to_int32(A).
%% Shift count is ToUint32(b) & 31; the `<<` result is re-wrapped to int32.
shl(A, B) -> wrap_int32(js_to_int32(A) bsl (js_to_uint32(B) band 31)).
%% `>>` is a sign-propagating (arithmetic) shift on the signed int32.
shr(A, B) -> js_to_int32(A) bsr (js_to_uint32(B) band 31).
%% `>>>` is a zero-fill (logical) shift on the UNSIGNED uint32; result stays uint32.
ushr(A, B) -> js_to_uint32(A) bsr (js_to_uint32(B) band 31).

%% ── exponentiation ───────────────────────────────────────────────────────
%% JS `**` (Number::exponentiate). Operands coerce via ToNumber; the many
%% spec special cases (±0 exponent → 1, NaN, the infinities, negative base
%% with a non-integer exponent → NaN) are handled explicitly, and the finite
%% integer/integer case stays exact (native BEAM integer power).
pow(A, B) ->
    out(npow(coerce_num(A), coerce_num(B))).

npow(_Base, Exp) when Exp == 0 -> 1;
npow(nan, _) -> nan;
npow(_, nan) -> nan;
npow(Base, inf) -> npow_exp_pinf(Base);
npow(Base, neg_inf) -> npow_exp_ninf(Base);
npow(inf, Exp) when Exp > 0 -> inf;
npow(inf, _) -> 0;
npow(neg_inf, Exp) when Exp > 0 ->
    case is_odd_int(Exp) of
        true -> neg_inf;
        false -> inf
    end;
npow(neg_inf, _) -> 0;
npow(Base, Exp) when is_integer(Base), is_integer(Exp), Exp >= 0 ->
    int_pow(Base, Exp);
npow(Base, Exp) ->
    case Base < 0 andalso not is_int_valued(Exp) of
        true -> nan;
        false ->
            try math:pow(js_to_float(Base), js_to_float(Exp)) catch
                error:badarith ->
                    case Base < 0 andalso is_odd_int(Exp) of
                        true -> neg_inf;
                        false -> inf
                    end
            end
    end.

%% x ** (+Infinity): |x|>1 → +Inf, |x|=1 → NaN, |x|<1 → +0.
npow_exp_pinf(inf) -> inf;
npow_exp_pinf(neg_inf) -> inf;
npow_exp_pinf(Base) ->
    A = abs_num(Base),
    if
        A > 1 -> inf;
        A == 1 -> nan;
        true -> 0
    end.

%% x ** (-Infinity): |x|>1 → +0, |x|=1 → NaN, |x|<1 → +Inf.
npow_exp_ninf(inf) -> 0;
npow_exp_ninf(neg_inf) -> 0;
npow_exp_ninf(Base) ->
    A = abs_num(Base),
    if
        A > 1 -> 0;
        A == 1 -> nan;
        true -> inf
    end.

abs_num(N) when N < 0 -> -N;
abs_num(N) -> N.

js_to_float(N) when is_integer(N) -> float(N);
js_to_float(N) -> N.

is_int_valued(N) when is_integer(N) -> true;
is_int_valued(N) when is_float(N) -> N == trunc(N);
is_int_valued(_) -> false.

is_odd_int(N) ->
    case is_int_valued(N) of
        true -> trunc(N) rem 2 =/= 0;
        false -> false
    end.

%% Exact integer exponentiation by squaring (Exp >= 0).
int_pow(B, E) -> int_pow(B, E, 1).
int_pow(_, 0, Acc) -> Acc;
int_pow(B, E, Acc) ->
    Acc2 =
        case E band 1 of
            1 -> Acc * B;
            _ -> Acc
        end,
    int_pow(B * B, E bsr 1, Acc2).

%% ── Math ──────────────────────────────────────────────────
%% `Math.method(...)`. The method name is passed as an atom; each function coerces its
%% argument(s) with ToNumber, operates over the internal `number|nan|inf|neg_inf`
%% domain, and `out`s a JS number. `Math.PI`/`Math.E`/… constants are inlined by the
%% frontend, not routed here.

%% Math.random() → a float in (0,1).
math_random() -> rand:uniform().

%% Unary Math functions.
math_unary(Method, X) ->
    out(munary(Method, coerce_num(X))).

munary(Method, nan) ->
    %% floor/ceil/round/trunc/abs/… of NaN are all NaN.
    case Method of
        _ -> nan
    end;
munary(Method, inf) -> munary_inf(Method, 1);
munary(Method, neg_inf) -> munary_inf(Method, -1);
munary(Method, N) -> munary_finite(Method, N).

munary_inf(abs, _) -> inf;
munary_inf(sign, S) -> S;
munary_inf(floor, S) -> inf_of(S);
munary_inf(ceil, S) -> inf_of(S);
munary_inf(round, S) -> inf_of(S);
munary_inf(trunc, S) -> inf_of(S);
munary_inf(sqrt, 1) -> inf;
munary_inf(cbrt, S) -> inf_of(S);
munary_inf(exp, 1) -> inf;
munary_inf(exp, -1) -> 0;
munary_inf(log, 1) -> inf;
munary_inf(log2, 1) -> inf;
munary_inf(log10, 1) -> inf;
munary_inf(_, _) -> nan.

inf_of(1) -> inf;
inf_of(-1) -> neg_inf.

munary_finite(floor, N) -> floor(as_float(N));
munary_finite(ceil, N) -> ceil(as_float(N));
%% JS Math.round is round-half-toward-+Infinity: floor(x + 0.5).
munary_finite(round, N) -> floor(as_float(N) + 0.5);
munary_finite(trunc, N) -> trunc(as_float(N));
munary_finite(abs, N) -> abs(N);
munary_finite(sign, N) ->
    if
        N > 0 -> 1;
        N < 0 -> -1;
        true -> 0
    end;
munary_finite(sqrt, N) when N < 0 -> nan;
munary_finite(sqrt, N) -> math:sqrt(as_float(N));
munary_finite(cbrt, N) -> math:pow(as_float(N), 1.0 / 3.0) * cbrt_sign(N);
munary_finite(exp, N) -> guard_inf(fun() -> math:exp(as_float(N)) end);
munary_finite(log, N) when N < 0 -> nan;
munary_finite(log, N) when N == 0 -> neg_inf;
munary_finite(log, N) -> math:log(as_float(N));
munary_finite(log2, N) when N < 0 -> nan;
munary_finite(log2, N) when N == 0 -> neg_inf;
munary_finite(log2, N) -> math:log2(as_float(N));
munary_finite(log10, N) when N < 0 -> nan;
munary_finite(log10, N) when N == 0 -> neg_inf;
munary_finite(log10, N) -> math:log10(as_float(N));
munary_finite(sin, N) -> math:sin(as_float(N));
munary_finite(cos, N) -> math:cos(as_float(N));
munary_finite(tan, N) -> math:tan(as_float(N));
munary_finite(asin, N) when N < -1; N > 1 -> nan;
munary_finite(asin, N) -> math:asin(as_float(N));
munary_finite(acos, N) when N < -1; N > 1 -> nan;
munary_finite(acos, N) -> math:acos(as_float(N));
munary_finite(atan, N) -> math:atan(as_float(N));
munary_finite(_, _) -> nan.

%% cbrt of a negative base uses the real (negative) root.
cbrt_sign(N) when N < 0 -> -1.0;
cbrt_sign(_) -> 1.0.

as_float(N) when is_integer(N) -> float(N);
as_float(N) -> N.

%% Evaluate a float computation, mapping an overflow (badarith) to +Infinity.
guard_inf(F) ->
    try
        F()
    catch
        error:badarith -> inf
    end.

%% Binary Math functions: Math.pow(a,b), Math.atan2(y,x).
math_binary(pow, A, B) -> pow(A, B);
math_binary(atan2, A, B) ->
    out(matan2(coerce_num(A), coerce_num(B))).

matan2(nan, _) -> nan;
matan2(_, nan) -> nan;
matan2(Y, X) -> math:atan2(inf_to_num(Y), inf_to_num(X)).

inf_to_num(inf) -> 1.7976931348623157e308;
inf_to_num(neg_inf) -> -1.7976931348623157e308;
inf_to_num(N) -> as_float(N).

%% Variadic Math.min / Math.max / Math.hypot over the emitter's cons list of args.
math_reduce(Method, Args) ->
    out(mreduce(Method, [coerce_num(A) || A <- Args])).

mreduce(min, []) -> inf;
mreduce(max, []) -> neg_inf;
mreduce(hypot, []) -> 0;
mreduce(Method, Nums) ->
    case lists:member(nan, Nums) of
        true when Method =/= hypot -> nan;
        _ -> mreduce_go(Method, Nums)
    end.

mreduce_go(min, Nums) -> lists:foldl(fun mmin/2, hd(Nums), tl(Nums));
mreduce_go(max, Nums) -> lists:foldl(fun mmax/2, hd(Nums), tl(Nums));
mreduce_go(hypot, Nums) ->
    Sum = lists:foldl(fun(N, A) -> A + hypot_sq(N) end, 0.0, Nums),
    math:sqrt(Sum).

hypot_sq(inf) -> inf_to_num(inf);
hypot_sq(neg_inf) -> inf_to_num(inf);
hypot_sq(N) -> as_float(N) * as_float(N).

mmin(inf, B) -> B;
mmin(A, inf) -> A;
mmin(neg_inf, _) -> neg_inf;
mmin(_, neg_inf) -> neg_inf;
mmin(A, B) when A =< B -> A;
mmin(_, B) -> B.

mmax(neg_inf, B) -> B;
mmax(A, neg_inf) -> A;
mmax(inf, _) -> inf;
mmax(_, inf) -> inf;
mmax(A, B) when A >= B -> A;
mmax(_, B) -> B.

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
%% an array renders as its comma-joined elements; other refs are objects.
to_string(V) when is_reference(V) ->
    case erlang:get(?CELL_KEY(V)) of
        {js_array, Len, Map} -> array_to_string(Len, Map);
        _ -> <<"[object Object]">>
    end;
%% any internal repr (tuple/map/list/…).
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

%% Property keys are binaries; a NUMBER key normalizes to its JS string form
%% (5, 5.0 and "5" are the same key — to_string's integral-float rule does
%% this). Any other key type is a type_error (no ToPropertyKey walk yet).
prop_key(K) when is_binary(K) -> K;
prop_key(K) ->
    case js_type(K) of
        number -> to_string(K);
        _ -> type_error(K)
    end.

%% recv[key] — the stored value, or `undefined` when absent. Dispatches on the
%% cell content: a `{js_array,…}` is an array (integer indices + `length`), a
%% map is a plain object. No prototype chain yet (v1: own properties only).
get_prop(Recv, Key) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_array, Len, Map} -> array_get(Len, Map, Key);
        M when is_map(M) -> maps:get(prop_key(Key), M, undefined);
        _ -> type_error(Recv)
    end;
get_prop(Recv, Key) when is_binary(Recv) ->
    string_prop(Recv, Key);
get_prop(Recv, _Key) ->
    type_error(Recv).

%% recv[key] = v — stores and returns v (the value of a JS assignment).
set_prop(Recv, Key, V) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_array, Len, Map} -> array_set(Recv, Len, Map, Key, V);
        M when is_map(M) ->
            erlang:put(?CELL_KEY(Recv), maps:put(prop_key(Key), V, M)),
            V;
        _ -> type_error(Recv)
    end;
set_prop(Recv, _Key, _V) ->
    type_error(Recv).

%% delete recv[key] — remove the property; always returns `true` (non-strict).
delete_prop(Recv, Key) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_array, Len, Map} ->
            erlang:put(?CELL_KEY(Recv), {js_array, Len, maps:remove(array_key(Key), Map)}),
            true;
        M when is_map(M) ->
            erlang:put(?CELL_KEY(Recv), maps:remove(prop_key(Key), M)),
            true;
        _ ->
            true
    end;
delete_prop(_Recv, _Key) ->
    true.

%% key in recv → 1|0 (own properties only, like get_prop).
has_prop(Recv, Key) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_array, _Len, Map} -> array_has(Map, Key);
        M when is_map(M) -> bool_int(maps:is_key(prop_key(Key), M));
        _ -> type_error(Recv)
    end;
has_prop(Recv, _Key) ->
    type_error(Recv).

%% ───────────────────────── arrays ─────────────────────────
%% A JS array is a cell holding `{js_array, Length, Map}`, where Map maps a
%% dense-ish set of integer indices (plus any string properties) to values.
%% `typeof` is still "object" (a cell is a reference); `Array.isArray` and the
%% array-aware `to_string`/property ops distinguish it by the tagged content.

%% [e0, e1, …] — build the array from the emitter's cons list of elements.
new_array(List) when is_list(List) ->
    {Len, Map} =
        lists:foldl(
            fun(E, {I, M}) -> {I + 1, maps:put(I, E, M)} end,
            {0, #{}},
            List
        ),
    cell_new({js_array, Len, Map});
new_array(V) ->
    type_error(V).

%% Normalize an array property key: an integer index stays an integer, a
%% canonical numeric string becomes that index, `length` is left as-is, and
%% every other key is an ordinary (string) property.
array_key(K) when is_integer(K) -> K;
array_key(K) when is_float(K) ->
    case K == trunc(K) of
        true -> trunc(K);
        false -> to_string(K)
    end;
array_key(<<"length">>) -> <<"length">>;
array_key(K) when is_binary(K) ->
    try
        binary_to_integer(K)
    catch
        error:badarg -> K
    end;
array_key(K) -> prop_key(K).

array_get(Len, _Map, <<"length">>) -> Len;
array_get(_Len, Map, Key) -> maps:get(array_key(Key), Map, undefined).

%% `arr.length = n` truncates (drops indices >= n) or extends the length.
array_set(Recv, _Len, Map, <<"length">>, V) ->
    NewLen = js_to_uint32(V),
    Map2 = maps:filter(
        fun(K, _) -> not (is_integer(K) andalso K >= NewLen) end,
        Map
    ),
    erlang:put(?CELL_KEY(Recv), {js_array, NewLen, Map2}),
    V;
array_set(Recv, Len, Map, Key, V) ->
    K = array_key(Key),
    NewLen =
        case is_integer(K) andalso K >= Len of
            true -> K + 1;
            false -> Len
        end,
    erlang:put(?CELL_KEY(Recv), {js_array, NewLen, maps:put(K, V, Map)}),
    V.

array_has(_Map, <<"length">>) -> 1;
array_has(Map, Key) -> bool_int(maps:is_key(array_key(Key), Map)).

%% arr.push(...vals) — append each (emitter passes a cons list); returns the
%% new length.
array_push(Recv, Vals) when is_reference(Recv), is_list(Vals) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_array, Len, Map} ->
            {NewLen, NewMap} =
                lists:foldl(
                    fun(V, {I, M}) -> {I + 1, maps:put(I, V, M)} end,
                    {Len, Map},
                    Vals
                ),
            erlang:put(?CELL_KEY(Recv), {js_array, NewLen, NewMap}),
            NewLen;
        _ -> type_error(Recv)
    end;
array_push(Recv, _Vals) ->
    type_error(Recv).

%% arr.pop() — remove and return the last element (undefined when empty).
array_pop(Recv) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_array, 0, _Map} ->
            undefined;
        {js_array, Len, Map} ->
            I = Len - 1,
            V = maps:get(I, Map, undefined),
            erlang:put(?CELL_KEY(Recv), {js_array, I, maps:remove(I, Map)}),
            V;
        _ ->
            type_error(Recv)
    end;
array_pop(Recv) ->
    type_error(Recv).

%% Array.from(x) — a new array from an array (copy), a string (its chars), or an
%% array-like; a non-iterable yields an empty array.
array_from(X) when is_reference(X) ->
    case erlang:get(?CELL_KEY(X)) of
        {js_array, Len, Map} -> new_array(arr_list(Len, Map));
        _ -> new_array([])
    end;
array_from(X) when is_binary(X) ->
    new_array([from_cps([C]) || C <- cps(X)]);
array_from(_X) ->
    new_array([]).

%% arr.flat() — flatten one level (array elements are spread in).
array_flat(Recv) ->
    {Len, Map} = arr_content(Recv),
    new_array(lists:flatmap(fun flat_one/1, arr_list(Len, Map))).
flat_one(E) ->
    case is_array(E) of
        1 ->
            {L, M} = arr_content(E),
            arr_list(L, M);
        0 ->
            [E]
    end.

%% arr.fill(v) — set every element to v (in place); returns the array.
array_fill(Recv, V) ->
    {Len, _Map} = arr_content(Recv),
    arr_store(Recv, lists:duplicate(Len, V)).

%% arr.at(i) / str.at(i) — element at index i (negative counts from the end), else
%% undefined.
array_at(Recv, I) when is_binary(Recv) ->
    Cps = cps(Recv),
    nth_char(Cps, at_index(I, length(Cps)), undefined);
array_at(Recv, I) ->
    {Len, Map} = arr_content(Recv),
    Idx = at_index(I, Len),
    case Idx >= 0 andalso Idx < Len of
        true -> maps:get(Idx, Map, undefined);
        false -> undefined
    end.

at_index(I, Len) ->
    N =
        case coerce_num(I) of
            nan -> 0;
            inf -> Len;
            neg_inf -> -1;
            Num -> trunc(as_float(Num))
        end,
    case N < 0 of
        true -> Len + N;
        false -> N
    end.

%% str.padStart(n, pad) / padEnd — pad to length n with `pad` (default a space).
str_pad_start(Str, N, Pad) ->
    do_pad(Str, N, Pad, start).
str_pad_end(Str, N, Pad) ->
    do_pad(Str, N, Pad, 'end').

do_pad(Str, N, Pad, Where) ->
    Target =
        case coerce_num(N) of
            nan -> 0;
            _ -> trunc(as_float(coerce_num(N)))
        end,
    Cps = cps(Str),
    Cur = length(Cps),
    PadStr =
        case to_string(Pad) of
            <<>> -> <<" ">>;
            P -> P
        end,
    case Cur >= Target of
        true ->
            Str;
        false ->
            Fill = pad_fill(PadStr, Target - Cur),
            case Where of
                start -> <<Fill/binary, Str/binary>>;
                'end' -> <<Str/binary, Fill/binary>>
            end
    end.

%% Build `count` code points from repeating PadStr.
pad_fill(PadStr, Count) ->
    PadCps = cps(PadStr),
    from_cps(take_cps(PadCps, PadCps, Count)).
take_cps(_All, _Cur, 0) -> [];
take_cps(All, [], Count) -> take_cps(All, All, Count);
take_cps(All, [C | Rest], Count) -> [C | take_cps(All, Rest, Count - 1)].

%% String.fromCharCode(...codes) — build a string from the emitter's cons list of codes.
string_from_char_code(Codes) ->
    from_cps([trunc(as_float(coerce_num(C))) || C <- Codes]).

%% Date.now() — milliseconds since the Unix epoch.
date_now() ->
    erlang:system_time(millisecond).

%% Spread `...value` into `target` (in place): an array contributes its elements, a
%% string its characters. Behind array-literal spread `[...a]`.
array_spread_into(Target, Value) when is_reference(Value) ->
    case erlang:get(?CELL_KEY(Value)) of
        {js_array, Len, Map} -> array_push(Target, arr_list(Len, Map));
        _ -> type_error(Value)
    end;
array_spread_into(Target, Value) when is_binary(Value) ->
    array_push(Target, [from_cps([C]) || C <- cps(Value)]);
array_spread_into(_Target, Value) ->
    type_error(Value).

%% Array.isArray(x) → 1|0.
is_array(Recv) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_array, _, _} -> 1;
        _ -> 0
    end;
is_array(_) ->
    0.

%% JS Array.prototype.toString — elements joined with "," (null/undefined
%% render as the empty string).
array_to_string(0, _Map) ->
    <<>>;
array_to_string(Len, Map) ->
    Parts = [array_elem_str(maps:get(I, Map, undefined)) || I <- lists:seq(0, Len - 1)],
    iolist_to_binary(lists:join(<<",">>, Parts)).

array_elem_str(undefined) -> <<>>;
array_elem_str(null) -> <<>>;
array_elem_str(V) -> to_string(V).

%% ── array iteration methods ──────────────────────────────
%% These take a JS callback (a BEAM fun from MakeClosure). JS callbacks tolerate
%% extra/missing arguments, but BEAM funs are arity-strict, so `call_cb` applies the
%% fun with EXACTLY its own arity (padding with `undefined`), letting `x => …`,
%% `(x, i) => …`, and `(x, i, arr) => …` all work.

%% The array cell's `{Length, Map}`; a non-array is a type_error.
arr_content(Recv) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_array, Len, Map} -> {Len, Map};
        _ -> type_error(Recv)
    end;
arr_content(Recv) ->
    type_error(Recv).

%% Ordered element list.
arr_list(0, _Map) -> [];
arr_list(Len, Map) -> [maps:get(I, Map, undefined) || I <- lists:seq(0, Len - 1)].

%% Store an element list back into `Recv`, returning `Recv`.
arr_store(Recv, List) ->
    {Len, Map} =
        lists:foldl(fun(V, {I, M}) -> {I + 1, maps:put(I, V, M)} end, {0, #{}}, List),
    erlang:put(?CELL_KEY(Recv), {js_array, Len, Map}),
    Recv.

%% Apply a JS callback with its own arity (pad missing args with `undefined`).
call_cb(Fn, Args) ->
    {arity, A} = erlang:fun_info(Fn, arity),
    Padded = Args ++ lists:duplicate(max(0, A - length(Args)), undefined),
    erlang:apply(Fn, lists:sublist(Padded, A)).

array_map(Recv, Fn) ->
    {Len, Map} = arr_content(Recv),
    new_array(amap(Fn, Recv, arr_list(Len, Map), 0)).
amap(_, _, [], _) -> [];
amap(Fn, Arr, [X | Xs], I) -> [call_cb(Fn, [X, I, Arr]) | amap(Fn, Arr, Xs, I + 1)].

array_filter(Recv, Fn) ->
    {Len, Map} = arr_content(Recv),
    new_array(afilter(Fn, Recv, arr_list(Len, Map), 0)).
afilter(_, _, [], _) -> [];
afilter(Fn, Arr, [X | Xs], I) ->
    case truthy(call_cb(Fn, [X, I, Arr])) of
        1 -> [X | afilter(Fn, Arr, Xs, I + 1)];
        0 -> afilter(Fn, Arr, Xs, I + 1)
    end.

array_foreach(Recv, Fn) ->
    {Len, Map} = arr_content(Recv),
    aforeach(Fn, Recv, arr_list(Len, Map), 0),
    undefined.
aforeach(_, _, [], _) -> ok;
aforeach(Fn, Arr, [X | Xs], I) ->
    call_cb(Fn, [X, I, Arr]),
    aforeach(Fn, Arr, Xs, I + 1).

%% reduce with an explicit initial accumulator.
array_reduce(Recv, Fn, Init) ->
    {Len, Map} = arr_content(Recv),
    areduce(Fn, Recv, arr_list(Len, Map), 0, Init).
areduce(_, _, [], _, Acc) -> Acc;
areduce(Fn, Arr, [X | Xs], I, Acc) ->
    areduce(Fn, Arr, Xs, I + 1, call_cb(Fn, [Acc, X, I, Arr])).

%% reduce with no initial accumulator (first element seeds it; empty → TypeError).
array_reduce1(Recv, Fn) ->
    {Len, Map} = arr_content(Recv),
    case arr_list(Len, Map) of
        [] -> type_error(Recv);
        [First | Rest] -> areduce(Fn, Recv, Rest, 1, First)
    end.

array_some(Recv, Fn) ->
    {Len, Map} = arr_content(Recv),
    asome(Fn, Recv, arr_list(Len, Map), 0).
asome(_, _, [], _) -> false;
asome(Fn, Arr, [X | Xs], I) ->
    case truthy(call_cb(Fn, [X, I, Arr])) of
        1 -> true;
        0 -> asome(Fn, Arr, Xs, I + 1)
    end.

array_every(Recv, Fn) ->
    {Len, Map} = arr_content(Recv),
    aevery(Fn, Recv, arr_list(Len, Map), 0).
aevery(_, _, [], _) -> true;
aevery(Fn, Arr, [X | Xs], I) ->
    case truthy(call_cb(Fn, [X, I, Arr])) of
        0 -> false;
        1 -> aevery(Fn, Arr, Xs, I + 1)
    end.

array_find(Recv, Fn) ->
    {Len, Map} = arr_content(Recv),
    afind(Fn, Recv, arr_list(Len, Map), 0).
afind(_, _, [], _) -> undefined;
afind(Fn, Arr, [X | Xs], I) ->
    case truthy(call_cb(Fn, [X, I, Arr])) of
        1 -> X;
        0 -> afind(Fn, Arr, Xs, I + 1)
    end.

array_find_index(Recv, Fn) ->
    {Len, Map} = arr_content(Recv),
    afindi(Fn, Recv, arr_list(Len, Map), 0).
afindi(_, _, [], _) -> -1;
afindi(Fn, Arr, [X | Xs], I) ->
    case truthy(call_cb(Fn, [X, I, Arr])) of
        1 -> I;
        0 -> afindi(Fn, Arr, Xs, I + 1)
    end.

%% arr.flatMap(fn) — map then flatten one level.
array_flat_map(Recv, Fn) ->
    {Len, Map} = arr_content(Recv),
    new_array(lists:flatmap(
        fun({X, I}) -> flat_one(call_cb(Fn, [X, I, Recv])) end,
        index_pairs(arr_list(Len, Map))
    )).

index_pairs(L) -> index_pairs(L, 0).
index_pairs([], _) -> [];
index_pairs([X | Xs], I) -> [{X, I} | index_pairs(Xs, I + 1)].

%% arr.findLast(fn) / findLastIndex(fn) — like find/findIndex, from the end.
array_find_last(Recv, Fn) ->
    {Len, Map} = arr_content(Recv),
    afind_last(Fn, Recv, index_pairs(arr_list(Len, Map)), undefined).
afind_last(_, _, [], Acc) -> Acc;
afind_last(Fn, Arr, [{X, I} | Rest], Acc) ->
    case truthy(call_cb(Fn, [X, I, Arr])) of
        1 -> afind_last(Fn, Arr, Rest, X);
        0 -> afind_last(Fn, Arr, Rest, Acc)
    end.

array_find_last_index(Recv, Fn) ->
    {Len, Map} = arr_content(Recv),
    afind_last_i(Fn, Recv, index_pairs(arr_list(Len, Map)), -1).
afind_last_i(_, _, [], Acc) -> Acc;
afind_last_i(Fn, Arr, [{X, I} | Rest], Acc) ->
    case truthy(call_cb(Fn, [X, I, Arr])) of
        1 -> afind_last_i(Fn, Arr, Rest, I);
        0 -> afind_last_i(Fn, Arr, Rest, Acc)
    end.

%% arr.lastIndexOf(x) — last strict-equal index, or -1.
array_last_index_of(Recv, X) ->
    {Len, Map} = arr_content(Recv),
    alast_idx(index_pairs(arr_list(Len, Map)), X, -1).
alast_idx([], _, Acc) -> Acc;
alast_idx([{E, I} | Rest], X, Acc) ->
    case strict_eq(E, X) of
        1 -> alast_idx(Rest, X, I);
        0 -> alast_idx(Rest, X, Acc)
    end.

%% recv.toString() — a user-defined `toString` method (a function property) wins;
%% otherwise the default ToString.
to_string_dispatch(Recv) when is_reference(Recv) ->
    case get_prop(Recv, <<"toString">>) of
        F when is_function(F) -> F();
        _ -> to_string(Recv)
    end;
to_string_dispatch(Recv) ->
    to_string(Recv).

%% num.toString(radix) — base-`radix` (2..36) integer string; else default ToString.
num_to_string_radix(N, Radix) ->
    R =
        case coerce_num(Radix) of
            nan -> 10;
            _ -> trunc(as_float(coerce_num(Radix)))
        end,
    case R >= 2 andalso R =< 36 andalso R =/= 10 of
        false ->
            to_string(N);
        true ->
            case coerce_num(N) of
                Num when is_integer(Num) ->
                    list_to_binary(string:lowercase(integer_to_list(Num, R)));
                _ ->
                    to_string(N)
            end
    end.

%% num.toFixed(d) — fixed-point string with `d` decimals.
num_to_fixed(N, D) ->
    Digits =
        case coerce_num(D) of
            nan -> 0;
            _ -> max(0, trunc(as_float(coerce_num(D))))
        end,
    case coerce_num(N) of
        nan -> <<"NaN">>;
        inf -> <<"Infinity">>;
        neg_inf -> <<"-Infinity">>;
        Num -> float_to_binary(as_float(Num), [{decimals, Digits}])
    end.

%% ── array value methods ──────────────────────────────────

array_index_of(Recv, X) when is_binary(Recv) -> str_index_of(Recv, X);
array_index_of(Recv, X) ->
    {Len, Map} = arr_content(Recv),
    aidx(arr_list(Len, Map), 0, X).
aidx([], _, _) -> -1;
aidx([E | Es], I, X) ->
    case strict_eq(E, X) of
        1 -> I;
        0 -> aidx(Es, I + 1, X)
    end.

%% includes → a JS boolean atom.
array_includes(Recv, X) ->
    array_index_of(Recv, X) =/= -1.

array_join(Recv, Sep) ->
    {Len, Map} = arr_content(Recv),
    SepBin = to_string(Sep),
    Parts = [array_elem_str(E) || E <- arr_list(Len, Map)],
    iolist_to_binary(lists:join(SepBin, Parts)).

%% slice(start?, end?) with negative-from-end indices; `undefined` = defaulted.
array_slice(Recv, Start, End) when is_binary(Recv) -> str_slice(Recv, Start, End);
array_slice(Recv, Start, End) ->
    {Len, Map} = arr_content(Recv),
    S = slice_index(Start, Len, 0),
    E = slice_index(End, Len, Len),
    new_array(lists:sublist(arr_list(Len, Map), S + 1, max(0, E - S))).

slice_index(undefined, _Len, Default) -> Default;
slice_index(V, Len, _Default) ->
    N =
        case coerce_num(V) of
            nan -> 0;
            inf -> Len;
            neg_inf -> 0;
            Num -> trunc(as_float(Num))
        end,
    case N < 0 of
        true -> max(Len + N, 0);
        false -> min(N, Len)
    end.

%% concat(...items) — spreads array items, appends others as single elements. On a
%% string receiver it is string concatenation (each item ToString'd).
array_concat(Recv, Others) when is_binary(Recv) ->
    iolist_to_binary([Recv | [to_string(O) || O <- Others]]);
array_concat(Recv, Others) ->
    {Len, Map} = arr_content(Recv),
    new_array(arr_list(Len, Map) ++ lists:flatmap(fun concat_part/1, Others)).
concat_part(V) ->
    case is_array(V) of
        1 ->
            {L, M} = arr_content(V),
            arr_list(L, M);
        0 ->
            [V]
    end.

array_reverse(Recv) ->
    {Len, Map} = arr_content(Recv),
    arr_store(Recv, lists:reverse(arr_list(Len, Map))).

array_shift(Recv) ->
    {Len, Map} = arr_content(Recv),
    case arr_list(Len, Map) of
        [] ->
            undefined;
        [First | Rest] ->
            arr_store(Recv, Rest),
            First
    end.

array_unshift(Recv, Vals) ->
    {Len, Map} = arr_content(Recv),
    arr_store(Recv, Vals ++ arr_list(Len, Map)),
    Len + length(Vals).

%% sort(cmp?) — in place. Default order is by ToString (JS default); a comparator
%% orders A before B when cmp(A, B) <= 0.
array_sort(Recv, Cmp) ->
    {Len, Map} = arr_content(Recv),
    L = arr_list(Len, Map),
    Sorted =
        case Cmp of
            undefined -> lists:sort(fun(A, B) -> to_string(A) =< to_string(B) end, L);
            _ -> lists:sort(fun(A, B) -> sort_lte(call_cb(Cmp, [A, B])) end, L)
        end,
    arr_store(Recv, Sorted).

sort_lte(V) ->
    case coerce_num(V) of
        nan -> true;
        neg_inf -> true;
        inf -> false;
        N -> N =< 0
    end.

%% ── strings ──────────────────────────────────────────────
%% Strings are UTF-8 binaries. `.length`, indexing, `charAt`, `slice`, `substring` use
%% Unicode CODE POINTS (correct for the BMP; astral chars count as 1, not the 2 UTF-16
%% units JS uses — a documented v1 deviation). Substring search (indexOf/includes/
%% split/replace/starts/ends) is exact (UTF-8 is prefix-free).

cps(Bin) -> unicode:characters_to_list(Bin).
from_cps(L) -> unicode:characters_to_binary(L).

%% str.length or str[i].
string_prop(Str, <<"length">>) ->
    length(cps(Str));
string_prop(Str, Key) ->
    case str_to_index(Key) of
        {ok, I} -> nth_char(cps(Str), I, undefined);
        error -> undefined
    end.

str_to_index(K) when is_integer(K) -> {ok, K};
str_to_index(K) when is_float(K) ->
    case K == trunc(K) of
        true -> {ok, trunc(K)};
        false -> error
    end;
str_to_index(K) when is_binary(K) ->
    try
        {ok, binary_to_integer(K)}
    catch
        error:badarg -> error
    end;
str_to_index(_) -> error.

%% The 1-char string at code-point index I, or `OutOfRange` when absent.
nth_char(Cps, I, OutOfRange) when I >= 0 ->
    case I < length(Cps) of
        true -> from_cps([lists:nth(I + 1, Cps)]);
        false -> OutOfRange
    end;
nth_char(_, _, OutOfRange) ->
    OutOfRange.

%% str.charAt(i) → the 1-char string, or "" out of range.
str_char_at(Str, I) ->
    case str_to_index(I) of
        {ok, Idx} -> nth_char(cps(Str), Idx, <<>>);
        error -> nth_char(cps(Str), 0, <<>>)
    end.

%% str.charCodeAt(i) → the code point as a number, or NaN out of range.
str_char_code_at(Str, I) ->
    case str_to_index(I) of
        {ok, Idx} ->
            Cps = cps(Str),
            case Idx >= 0 andalso Idx < length(Cps) of
                true -> lists:nth(Idx + 1, Cps);
                false -> js_nan
            end;
        error ->
            js_nan
    end.

str_upper(Str) -> unicode:characters_to_binary(string:uppercase(Str)).
str_lower(Str) -> unicode:characters_to_binary(string:lowercase(Str)).

%% str.indexOf(sub) → first code-point index of `sub`, or -1 ("" → 0).
str_index_of(Str, Sub) ->
    SubBin = to_string(Sub),
    case SubBin of
        <<>> ->
            0;
        _ ->
            case binary:match(Str, SubBin) of
                nomatch -> -1;
                {Pos, _} -> length(cps(binary:part(Str, 0, Pos)))
            end
    end.

%% str.slice(start?, end?) — negative-from-end code-point slice.
str_slice(Str, Start, End) ->
    Cps = cps(Str),
    Len = length(Cps),
    S = slice_index(Start, Len, 0),
    E = slice_index(End, Len, Len),
    from_cps(lists:sublist(Cps, S + 1, max(0, E - S))).

%% str.substring(start?, end?) — clamps negatives to 0 and swaps if start > end.
str_substring(Str, Start, End) ->
    Cps = cps(Str),
    Len = length(Cps),
    S0 = sub_index(Start, Len, 0),
    E0 = sub_index(End, Len, Len),
    {S, E} =
        case S0 =< E0 of
            true -> {S0, E0};
            false -> {E0, S0}
        end,
    from_cps(lists:sublist(Cps, S + 1, max(0, E - S))).

sub_index(undefined, _Len, Default) -> Default;
sub_index(V, Len, _Default) ->
    N =
        case coerce_num(V) of
            nan -> 0;
            inf -> Len;
            neg_inf -> 0;
            Num -> trunc(as_float(Num))
        end,
    min(max(N, 0), Len).

%% str.split(sep?) → array. No arg → [str]; "" → the characters; else split on `sep`.
str_split(Str, undefined) ->
    new_array([Str]);
str_split(Str, Sep) ->
    case to_string(Sep) of
        <<>> -> new_array([from_cps([C]) || C <- cps(Str)]);
        SepBin -> new_array(binary:split(Str, SepBin, [global]))
    end.

str_trim(Str) -> unicode:characters_to_binary(string:trim(Str)).
str_trim_start(Str) -> unicode:characters_to_binary(string:trim(Str, leading)).
str_trim_end(Str) -> unicode:characters_to_binary(string:trim(Str, trailing)).

str_repeat(Str, N) ->
    Count =
        case coerce_num(N) of
            nan -> 0;
            inf -> type_error(N);
            neg_inf -> type_error(N);
            Num -> trunc(as_float(Num))
        end,
    case Count < 0 of
        true -> type_error(N);
        false -> binary:copy(Str, Count)
    end.

str_starts_with(Str, Prefix) ->
    P = to_string(Prefix),
    PS = byte_size(P),
    byte_size(Str) >= PS andalso binary:part(Str, 0, PS) =:= P.

str_ends_with(Str, Suffix) ->
    S = to_string(Suffix),
    SS = byte_size(S),
    SZ = byte_size(Str),
    SZ >= SS andalso binary:part(Str, SZ - SS, SS) =:= S.

%% str.replace(search, repl) — the FIRST occurrence (string search; no regex in v1).
str_replace(Str, Search, Repl) ->
    ReplBin = to_string(Repl),
    case to_string(Search) of
        <<>> ->
            <<ReplBin/binary, Str/binary>>;
        SearchBin ->
            case binary:match(Str, SearchBin) of
                nomatch ->
                    Str;
                {Pos, Len} ->
                    Before = binary:part(Str, 0, Pos),
                    After = binary:part(Str, Pos + Len, byte_size(Str) - Pos - Len),
                    <<Before/binary, ReplBin/binary, After/binary>>
            end
    end.

%% str.replaceAll(search, repl) — every occurrence.
str_replace_all(Str, Search, Repl) ->
    ReplBin = to_string(Repl),
    case to_string(Search) of
        <<>> -> Str;
        SearchBin -> binary:replace(Str, SearchBin, ReplBin, [global])
    end.

%% ── global functions ─────────────────────────────────────

%% parseInt(str, radix) — leading integer in the given radix (auto-detects 0x → 16;
%% default 10); non-numeric prefix → NaN.
parse_int(S, RadixArg) ->
    Str = string:trim(to_string(S), leading),
    {Sign, Rest0} =
        case Str of
            <<"-", R/binary>> -> {-1, R};
            <<"+", R/binary>> -> {1, R};
            _ -> {1, Str}
        end,
    Radix0 =
        case coerce_num(RadixArg) of
            nan -> 0;
            inf -> 0;
            neg_inf -> 0;
            N -> trunc(as_float(N))
        end,
    {Radix, Rest} = resolve_radix(Radix0, Rest0),
    case Radix >= 2 andalso Radix =< 36 of
        false ->
            js_nan;
        true ->
            case take_digits(Rest, Radix, []) of
                [] -> js_nan;
                Digits -> Sign * list_to_integer(Digits, Radix)
            end
    end.

resolve_radix(0, <<"0x", R/binary>>) -> {16, R};
resolve_radix(0, <<"0X", R/binary>>) -> {16, R};
resolve_radix(0, R) -> {10, R};
resolve_radix(16, <<"0x", R/binary>>) -> {16, R};
resolve_radix(16, <<"0X", R/binary>>) -> {16, R};
resolve_radix(Radix, R) -> {Radix, R}.

take_digits(<<C, Rest/binary>>, Radix, Acc) ->
    case digit_val(C) of
        V when V >= 0, V < Radix -> take_digits(Rest, Radix, [C | Acc]);
        _ -> lists:reverse(Acc)
    end;
take_digits(<<>>, _Radix, Acc) ->
    lists:reverse(Acc).

digit_val(C) when C >= $0, C =< $9 -> C - $0;
digit_val(C) when C >= $a, C =< $z -> C - $a + 10;
digit_val(C) when C >= $A, C =< $Z -> C - $A + 10;
digit_val(_) -> -1.

%% parseFloat(str) — leading decimal/float (or Infinity); else NaN.
parse_float(S) ->
    Str = string:trim(to_string(S), leading),
    case Str of
        <<"Infinity", _/binary>> ->
            js_inf;
        <<"+Infinity", _/binary>> ->
            js_inf;
        <<"-Infinity", _/binary>> ->
            js_neg_inf;
        _ ->
            case string:to_float(Str) of
                {error, _} ->
                    case string:to_integer(Str) of
                        {error, _} -> js_nan;
                        {I, _} -> float(I)
                    end;
                {F, _} ->
                    F
            end
    end.

%% isNaN(x) / isFinite(x) — coerce with ToNumber first (the global forms).
is_nan(X) ->
    case coerce_num(X) of
        nan -> true;
        _ -> false
    end.

is_finite(X) ->
    case coerce_num(X) of
        nan -> false;
        inf -> false;
        neg_inf -> false;
        _ -> true
    end.

%% Number.isNaN / Number.isFinite — NO coercion (only actual numbers qualify).
number_is_nan(js_nan) -> true;
number_is_nan(_) -> false.

number_is_finite(X) when is_integer(X); is_float(X) -> true;
number_is_finite(_) -> false.

number_is_integer(X) when is_integer(X) -> true;
number_is_integer(X) when is_float(X) -> X == trunc(X);
number_is_integer(_) -> false.

%% ── Object statics ───────────────────────────────────────
%% NOTE: key order follows the backing map's iteration order, not JS insertion order
%% (a v1 deviation). Own enumerable string keys only.

obj_pairs(O) when is_reference(O) ->
    case erlang:get(?CELL_KEY(O)) of
        M when is_map(M) -> maps:to_list(M);
        {js_array, Len, Map} -> [{integer_to_binary(I), maps:get(I, Map, undefined)} || I <- lists:seq(0, Len - 1)];
        _ -> type_error(O)
    end;
obj_pairs(O) ->
    type_error(O).

%% is `x` null or undefined? → i32 1|0 (behind `??` and `?.`).
is_nullish(null) -> 1;
is_nullish(undefined) -> 1;
is_nullish(_) -> 0.

object_keys(O) -> new_array([K || {K, _} <- obj_pairs(O)]).
object_values(O) -> new_array([V || {_, V} <- obj_pairs(O)]).
object_entries(O) -> new_array([new_array([K, V]) || {K, V} <- obj_pairs(O)]).

%% Object.fromEntries(pairs) — build an object from an array of [key, value] arrays.
object_from_entries(Entries) when is_reference(Entries) ->
    {Len, Map} = arr_content(Entries),
    O = new_object(),
    lists:foreach(
        fun(Pair) ->
            case is_array(Pair) of
                1 ->
                    {_, M} = arr_content(Pair),
                    set_prop(O, to_string(maps:get(0, M, undefined)), maps:get(1, M, undefined));
                0 ->
                    ok
            end
        end,
        arr_list(Len, Map)
    ),
    O;
object_from_entries(_) ->
    new_object().

%% Copy `source`'s own properties into `target` (in place); behind object spread
%% `{...o}` and `Object.assign`. A null/undefined/primitive source is a no-op.
object_assign_into(Target, Source) when is_reference(Source) ->
    lists:foreach(fun({K, V}) -> set_prop(Target, K, V) end, obj_pairs(Source)),
    Target;
object_assign_into(Target, _Source) ->
    Target.

%% ── JSON ─────────────────────────────────────────────────

%% JSON.stringify(v) — a JSON binary, or `undefined` for undefined/function/other.
json_stringify(V) ->
    case json_enc(V) of
        skip -> undefined;
        Io -> iolist_to_binary(Io)
    end.

json_enc(V) ->
    case js_type(V) of
        number -> json_num(V);
        boolean -> to_string(V);
        string -> json_str(V);
        null -> <<"null">>;
        undefined -> skip;
        function -> skip;
        object -> json_ref(V);
        other -> skip
    end.

json_num(js_nan) -> <<"null">>;
json_num(js_inf) -> <<"null">>;
json_num(js_neg_inf) -> <<"null">>;
json_num(N) -> to_string(N).

json_str(Bin) -> [$", json_escape(Bin), $"].

json_escape(Bin) -> [esc_byte(B) || <<B>> <= Bin].

esc_byte($") -> <<"\\\"">>;
esc_byte($\\) -> <<"\\\\">>;
esc_byte($\n) -> <<"\\n">>;
esc_byte($\t) -> <<"\\t">>;
esc_byte($\r) -> <<"\\r">>;
esc_byte(B) -> <<B>>.

json_ref(Ref) ->
    case erlang:get(?CELL_KEY(Ref)) of
        {js_array, Len, Map} -> json_arr(arr_list(Len, Map));
        M when is_map(M) -> json_obj(maps:to_list(M));
        _ -> skip
    end.

json_arr(List) ->
    Elems = [json_elem(E) || E <- List],
    [$[, lists:join($,, Elems), $]].

%% array elements that don't serialize (undefined/function) become null.
json_elem(E) ->
    case json_enc(E) of
        skip -> <<"null">>;
        Io -> Io
    end.

json_obj(Pairs) ->
    KVs =
        lists:filtermap(
            fun({K, Val}) ->
                case json_enc(Val) of
                    skip -> false;
                    Io -> {true, [json_str(K), $:, Io]}
                end
            end,
            Pairs
        ),
    [${, lists:join($,, KVs), $}].

%% JSON.parse(str) — parse JSON text to JS terms (numbers, binaries, true/false/null,
%% arrays, objects). Malformed input is a type_error.
json_parse(Str) ->
    Bin = to_string(Str),
    case json_val(json_ws(Bin)) of
        {ok, V, Rest} ->
            case json_ws(Rest) of
                <<>> -> V;
                _ -> type_error(Str)
            end;
        error ->
            type_error(Str)
    end.

json_ws(<<C, R/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    json_ws(R);
json_ws(B) ->
    B.

json_val(<<"true", R/binary>>) -> {ok, true, R};
json_val(<<"false", R/binary>>) -> {ok, false, R};
json_val(<<"null", R/binary>>) -> {ok, null, R};
json_val(<<$", R/binary>>) -> json_pstr(R, []);
json_val(<<$[, R/binary>>) -> json_parr(json_ws(R), []);
json_val(<<${, R/binary>>) -> json_pobj(json_ws(R), new_object());
json_val(<<C, _/binary>> = B) when C =:= $-; C >= $0, C =< $9 -> json_pnum(B);
json_val(_) -> error.

json_pstr(<<$", R/binary>>, Acc) ->
    {ok, unicode:characters_to_binary(lists:reverse(Acc)), R};
json_pstr(<<$\\, $", R/binary>>, Acc) -> json_pstr(R, [$" | Acc]);
json_pstr(<<$\\, $\\, R/binary>>, Acc) -> json_pstr(R, [$\\ | Acc]);
json_pstr(<<$\\, $/, R/binary>>, Acc) -> json_pstr(R, [$/ | Acc]);
json_pstr(<<$\\, $n, R/binary>>, Acc) -> json_pstr(R, [$\n | Acc]);
json_pstr(<<$\\, $t, R/binary>>, Acc) -> json_pstr(R, [$\t | Acc]);
json_pstr(<<$\\, $r, R/binary>>, Acc) -> json_pstr(R, [$\r | Acc]);
json_pstr(<<$\\, $u, H:4/binary, R/binary>>, Acc) ->
    json_pstr(R, [binary_to_integer(H, 16) | Acc]);
json_pstr(<<C/utf8, R/binary>>, Acc) -> json_pstr(R, [C | Acc]);
json_pstr(_, _) -> error.

json_pnum(B) ->
    {Tok, Rest} = json_num_tok(B, []),
    case string:to_float(Tok) of
        {error, _} ->
            case string:to_integer(Tok) of
                {error, _} -> error;
                {I, <<>>} -> {ok, I, Rest};
                _ -> error
            end;
        {F, <<>>} ->
            {ok, F, Rest}
    end.

json_num_tok(<<C, R/binary>>, Acc) when
    C >= $0, C =< $9;
    C =:= $-;
    C =:= $+;
    C =:= $.;
    C =:= $e;
    C =:= $E
->
    json_num_tok(R, [C | Acc]);
json_num_tok(R, Acc) ->
    {list_to_binary(lists:reverse(Acc)), R}.

json_parr(<<$], R/binary>>, Acc) ->
    {ok, new_array(lists:reverse(Acc)), R};
json_parr(B, Acc) ->
    case json_val(B) of
        {ok, V, R} ->
            case json_ws(R) of
                <<$,, R2/binary>> -> json_parr(json_ws(R2), [V | Acc]);
                <<$], R2/binary>> -> {ok, new_array(lists:reverse([V | Acc])), R2};
                _ -> error
            end;
        error ->
            error
    end.

json_pobj(<<$}, R/binary>>, Obj) ->
    {ok, Obj, R};
json_pobj(<<$", R/binary>>, Obj) ->
    case json_pstr(R, []) of
        {ok, Key, R1} ->
            case json_ws(R1) of
                <<$:, R2/binary>> ->
                    case json_val(json_ws(R2)) of
                        {ok, V, R3} ->
                            set_prop(Obj, Key, V),
                            case json_ws(R3) of
                                <<$,, R4/binary>> -> json_pobj(json_ws(R4), Obj);
                                <<$}, R4/binary>> -> {ok, Obj, R4};
                                _ -> error
                            end;
                        error ->
                            error
                    end;
                _ ->
                    error
            end;
        error ->
            error
    end;
json_pobj(_, _) ->
    error.

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
