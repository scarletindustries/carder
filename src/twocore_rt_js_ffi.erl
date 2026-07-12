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
    new_object/0, get_prop/2, set_prop/3, define_data/3, define_accessor/4,
    static_get/2, static_get_chain/2, static_set/3, has_prop/2, delete_prop/2,
    new_array/1, array_push/2, array_pop/1, is_array/1, array_spread_into/2,
    array_from/1, array_flat/1, array_fill/2, array_at/2,
    apply_fn/2, array_to_list/1,
    str_pad_start/3, str_pad_end/3, string_from_char_code/1,
    string_from_code_point/1, string_raw/2, date_now/0,
    array_flat_map/2, array_find_last/2, array_find_last_index/2,
    array_last_index_of/2, num_to_fixed/2,
    to_string_dispatch/1, num_to_string_radix/2,
    new_regex/2, regex_test/2, regex_source/1, regex_flags/1, str_match/2,
    new_map/1, new_set/1, js_m_set/2, js_m_get/2, js_m_add/2, js_m_has/2,
    js_m_delete/2, js_m_clear/2, js_m_foreach/2,
    array_map/2, array_filter/2, array_foreach/2, array_reduce/3,
    array_reduce1/2, array_reduce_right/3, array_reduce_right1/2,
    array_some/2, array_every/2, array_find/2,
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
    object_rest/2,
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
%% JS Math.round is round-half-toward-+Infinity. The naive floor(x + 0.5) is
%% NOT equivalent: for the largest double below 0.5 (0.49999999999999994) the
%% sum rounds up to 1.0, giving 1 instead of 0. Compare the fraction directly:
%% frac >= 0.5 rounds up (ties to +Infinity), otherwise down.
munary_finite(round, N) ->
    F = as_float(N),
    Fl = floor(F),
    case F - Fl >= 0.5 of
        true -> Fl + 1;
        false -> Fl
    end;
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
%% math:pow with a negative base and a non-integer exponent raises badarith, so
%% cube the magnitude and restore the sign — Math.cbrt(-8) = -2.
munary_finite(cbrt, N) -> math:pow(abs(as_float(N)), 1.0 / 3.0) * cbrt_sign(N);
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
        {js_regex, _, Flags, Src} -> <<"/", Src/binary, "/", Flags/binary>>;
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

%% Static class fields live in the process dictionary keyed by a module-qualified
%% class name (`ModuleName$Class`, unique per compiled JS module) so two modules
%% that both declare `class C` do not share static state. `Class`/`Field` are
%% binaries. static_set returns the assigned value; static_get returns `undefined`
%% for an unset field.
static_get(Class, Field) ->
    maps:get(Field, static_map(Class), undefined).

%% Read a static field along the inheritance chain: `Keys` is the receiver class
%% key first, then its ancestors. The first class that OWNS the field wins (an
%% assignment to an inherited static creates an own property on the receiver, so
%% the receiver's own key must be consulted before the declaring ancestor's).
static_get_chain([], _Field) ->
    undefined;
static_get_chain([Key | Rest], Field) ->
    M = static_map(Key),
    case maps:is_key(Field, M) of
        true -> maps:get(Field, M);
        false -> static_get_chain(Rest, Field)
    end.

static_set(Class, Field, V) ->
    erlang:put({js_static_class, Class}, maps:put(Field, V, static_map(Class))),
    V.

static_map(Class) ->
    case erlang:get({js_static_class, Class}) of
        undefined -> #{};
        M -> M
    end.

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
        {js_array, Len, Map} ->
            array_get(Len, Map, Key);
        {js_regex, _, Flags, Src} ->
            case Key of
                <<"source">> -> Src;
                <<"flags">> -> Flags;
                <<"global">> -> has_flag(Flags, $g);
                <<"ignoreCase">> -> has_flag(Flags, $i);
                <<"multiline">> -> has_flag(Flags, $m);
                _ -> undefined
            end;
        {js_map, D} ->
            case Key of
                <<"size">> -> maps:size(D);
                _ -> undefined
            end;
        {js_set, D} ->
            case Key of
                <<"size">> -> maps:size(D);
                _ -> undefined
            end;
        M when is_map(M) ->
            resolve_get(maps:get(prop_key(Key), M, undefined));
        _ ->
            type_error(Recv)
    end;
get_prop(Recv, Key) when is_binary(Recv) ->
    string_prop(Recv, Key);
get_prop(Recv, _Key) ->
    type_error(Recv).

%% Resolve a stored property value: if it is an accessor, invoke its getter
%% (a `this`-bound 0-arg closure); a setter-only accessor reads as `undefined`.
%% A plain value passes through. JS values are never raw tuples, so the
%% `{js_accessor, …}` marker is unambiguous.
resolve_get({js_accessor, G, _}) when is_function(G) -> call_cb(G, []);
resolve_get({js_accessor, _, _}) -> undefined;
resolve_get(V) -> V.

%% recv[key] = v — stores and returns v (the value of a JS assignment).
set_prop(Recv, Key, V) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_array, Len, Map} ->
            array_set(Recv, Len, Map, Key, V);
        M when is_map(M) ->
            K = prop_key(Key),
            case maps:get(K, M, undefined) of
                %% accessor with a setter: invoke it (this-bound), don't store.
                {js_accessor, _, S} when is_function(S) ->
                    call_cb(S, [V]),
                    V;
                %% getter-only accessor: assignment is ignored (non-strict mode).
                {js_accessor, _, _} ->
                    V;
                _ ->
                    erlang:put(?CELL_KEY(Recv), maps:put(K, V, M)),
                    V
            end;
        _ ->
            type_error(Recv)
    end;
set_prop(Recv, _Key, _V) ->
    type_error(Recv).

%% Define an own DATA property `Key = V` on `Obj`, storing directly and
%% unconditionally — bypassing set_prop's accessor check so it overwrites any
%% existing value OR accessor at that key (JS [[DefineOwnProperty]] semantics,
%% used to install methods and class fields, which shadow same-named accessors).
define_data(Obj, Key, V) when is_reference(Obj) ->
    case erlang:get(?CELL_KEY(Obj)) of
        M when is_map(M) ->
            erlang:put(?CELL_KEY(Obj), maps:put(prop_key(Key), V, M)),
            V;
        _ ->
            type_error(Obj)
    end;
define_data(Obj, _, _) ->
    type_error(Obj).

%% Install an accessor property `{js_accessor, Getter, Setter}` on `Obj` under
%% `Key`. Getter/Setter are `this`-bound closures (0-arg / 1-arg) or `undefined`.
%% Stored directly (bypassing the setter check in set_prop) so it defines/replaces
%% the property. Returns `undefined` (the value of a class/object accessor decl).
define_accessor(Obj, Key, Getter, Setter) when is_reference(Obj) ->
    case erlang:get(?CELL_KEY(Obj)) of
        M when is_map(M) ->
            erlang:put(
                ?CELL_KEY(Obj),
                maps:put(prop_key(Key), {js_accessor, Getter, Setter}, M)
            ),
            undefined;
        _ ->
            type_error(Obj)
    end;
define_accessor(Obj, _, _, _) ->
    type_error(Obj).

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
    case canonical_index(K) of
        {ok, I} -> I;
        error -> K
    end;
array_key(K) -> prop_key(K).

%% A binary key is an array index only if it is the canonical decimal form of an
%% integer in [0, 2^32 - 1). "01", "-1", "1.0" and out-of-range values are plain
%% string properties (they must NOT bump `length`).
canonical_index(K) ->
    try
        I = binary_to_integer(K),
        case I >= 0 andalso I < 4294967295 andalso integer_to_binary(I) =:= K of
            true -> {ok, I};
            false -> error
        end
    catch
        error:badarg -> error
    end.

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
    %% `undefined` (an omitted argument passed explicitly) uses the default " ";
    %% an empty pad string means "no filler available", so the string is
    %% returned unchanged even when it is shorter than the target.
    PadStr =
        case Pad of
            undefined -> <<" ">>;
            _ -> to_string(Pad)
        end,
    case Cur >= Target orelse PadStr =:= <<>> of
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

%% String.fromCharCode(...codes) — build a string from the emitter's cons list
%% of codes. Each code is a UTF-16 code UNIT: JS applies ToUint16 (mod 2^16), so
%% e.g. fromCharCode(65601) === fromCharCode(65) === "A".
string_from_char_code(Codes) ->
    from_cps([(trunc(as_float(coerce_num(C))) band 16#FFFF) || C <- Codes]).

%% String.fromCodePoint(...points) — build a string from full Unicode code
%% points (unlike fromCharCode, no ToUint16 masking). Each argument must be an
%% integer in [0, 0x10FFFF]; a fractional, negative, or out-of-range value is a
%% RangeError (signalled here as a js_error, like other range violations).
string_from_code_point(Codes) ->
    from_cps([code_point_of(C) || C <- Codes]).

code_point_of(C) ->
    case coerce_num(C) of
        N when is_number(N) ->
            I = trunc(N),
            case I == N andalso I >= 0 andalso I =< 16#10FFFF of
                true -> I;
                false -> type_error(C)
            end;
        _ ->
            type_error(C)
    end.

%% String.raw(template, ...substitutions) — the default tagged-template tag
%% (§22.1.2.4): concatenate the RAW literal segments (template.raw), inserting
%% ToString(substitution[i]) after each segment except the last. A missing
%% substitution is `undefined` ("undefined"). `Subs` is the cons-list of args.
string_raw(Template, Subs) ->
    Raw = get_prop(Template, <<"raw">>),
    {Len, Map} = arr_content(Raw),
    raw_join(arr_list(Len, Map), Subs, <<>>).

raw_join([], _Subs, Acc) ->
    Acc;
raw_join([Seg], _Subs, Acc) ->
    <<Acc/binary, (to_string(Seg))/binary>>;
raw_join([Seg | Rest], Subs, Acc) ->
    Acc1 = <<Acc/binary, (to_string(Seg))/binary>>,
    %% A missing substitution contributes the empty string, not "undefined"
    %% (§22.1.3.4 appends a substitution only when one is present).
    {Sub, Subs1} =
        case Subs of
            [S | R] -> {S, R};
            [] -> {<<>>, []}
        end,
    raw_join(Rest, Subs1, <<Acc1/binary, (to_string(Sub))/binary>>).

%% Date.now() — milliseconds since the Unix epoch.
date_now() ->
    erlang:system_time(millisecond).

%% ── Map / Set ────────────────────────────────────────────
%% A Map is a cell `{js_map, Data}` (Erlang map: JS-value key → value); a Set is
%% `{js_set, Data}` (value → true). Keys use Erlang term equality (object identity for
%% refs, value for primitives; NaN keys work via the js_nan sentinel). The method names
%% (set/get/add/has/delete/clear/forEach) DELEGATE to a user method of the same name
%% when the receiver is a plain object, so they don't clobber user APIs. Iteration order
%% is the backing map's, not insertion order (a v1 deviation).

new_map(Init) ->
    M = cell_new({js_map, #{}}),
    case is_array(Init) of
        1 ->
            {Len, Map} = arr_content(Init),
            lists:foreach(
                fun(Pair) ->
                    case is_array(Pair) of
                        1 ->
                            {_, PM} = arr_content(Pair),
                            js_m_set(M, [maps:get(0, PM, undefined), maps:get(1, PM, undefined)]);
                        0 ->
                            ok
                    end
                end,
                arr_list(Len, Map)
            );
        0 ->
            ok
    end,
    M.

new_set(Init) ->
    S = cell_new({js_set, #{}}),
    case is_array(Init) of
        1 ->
            {Len, Map} = arr_content(Init),
            lists:foreach(fun(V) -> js_m_add(S, [V]) end, arr_list(Len, Map));
        0 ->
            ok
    end,
    S.

%% Each collection method takes the receiver + the FULL argument list, so that a
%% delegated user method (when the receiver is a plain object) gets all its arguments.

js_m_set(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, D} ->
            erlang:put(?CELL_KEY(Recv), {js_map, maps:put(arg(Args, 0), arg(Args, 1), D)}),
            Recv;
        _ ->
            delegate(Recv, <<"set">>, Args)
    end.

js_m_get(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, D} -> maps:get(arg(Args, 0), D, undefined);
        _ -> delegate(Recv, <<"get">>, Args)
    end.

js_m_add(Recv, Args) ->
    case cell_tag(Recv) of
        {js_set, D} ->
            erlang:put(?CELL_KEY(Recv), {js_set, maps:put(arg(Args, 0), true, D)}),
            Recv;
        _ ->
            delegate(Recv, <<"add">>, Args)
    end.

js_m_has(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, D} -> maps:is_key(arg(Args, 0), D);
        {js_set, D} -> maps:is_key(arg(Args, 0), D);
        _ -> delegate(Recv, <<"has">>, Args)
    end.

js_m_delete(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, D} ->
            erlang:put(?CELL_KEY(Recv), {js_map, maps:remove(arg(Args, 0), D)}),
            true;
        {js_set, D} ->
            erlang:put(?CELL_KEY(Recv), {js_set, maps:remove(arg(Args, 0), D)}),
            true;
        _ ->
            delegate(Recv, <<"delete">>, Args)
    end.

js_m_clear(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, _} ->
            erlang:put(?CELL_KEY(Recv), {js_map, #{}}),
            undefined;
        {js_set, _} ->
            erlang:put(?CELL_KEY(Recv), {js_set, #{}}),
            undefined;
        _ ->
            delegate(Recv, <<"clear">>, Args)
    end.

%% forEach across arrays, Maps (fn(v, k, m)), Sets (fn(v, v, s)), or a user method.
js_m_foreach(Recv, Args) ->
    Fn = arg(Args, 0),
    case is_array(Recv) of
        1 ->
            array_foreach(Recv, Fn);
        0 ->
            case cell_tag(Recv) of
                {js_map, D} ->
                    maps:foreach(fun(K, V) -> call_cb(Fn, [V, K, Recv]) end, D),
                    undefined;
                {js_set, D} ->
                    maps:foreach(fun(V, _) -> call_cb(Fn, [V, V, Recv]) end, D),
                    undefined;
                _ ->
                    delegate(Recv, <<"forEach">>, Args)
            end
    end.

%% The cell's tagged content, or `undefined` for a non-reference (so the delegate path
%% is taken for primitives / plain values).
cell_tag(Recv) when is_reference(Recv) -> erlang:get(?CELL_KEY(Recv));
cell_tag(_) -> undefined.

arg([], _) -> undefined;
arg([X | _], 0) -> X;
arg([_ | Xs], N) -> arg(Xs, N - 1).

delegate(Recv, Name, Args) ->
    case get_prop(Recv, Name) of
        F when is_function(F) -> call_cb(F, Args);
        _ -> type_error(Recv)
    end.

%% ── regex ────────────────────────────────────────────────
%% A regex `/pat/flags` is a cell holding `{js_regex, CompiledMP, Flags, Source}`.
%% Backed by Erlang's `re` (PCRE), which is largely JS-compatible.

new_regex(Pattern, Flags) ->
    P = to_string(Pattern),
    F = to_string(Flags),
    case re:compile(P, re_opts(F)) of
        {ok, MP} -> cell_new({js_regex, MP, F, P});
        {error, _} -> type_error(Pattern)
    end.

re_opts(Flags) ->
    Base = [unicode],
    lists:foldl(
        fun({Ch, Opt}, Acc) ->
            case has_flag(Flags, Ch) of
                true -> [Opt | Acc];
                false -> Acc
            end
        end,
        Base,
        [{$i, caseless}, {$m, multiline}, {$s, dotall}]
    ).

has_flag(Flags, Ch) -> binary:match(Flags, <<Ch>>) =/= nomatch.

is_regex(X) when is_reference(X) ->
    case erlang:get(?CELL_KEY(X)) of
        {js_regex, _, _, _} -> true;
        _ -> false
    end;
is_regex(_) ->
    false.

regex_content(Re) ->
    case erlang:get(?CELL_KEY(Re)) of
        {js_regex, MP, Flags, Src} -> {MP, Flags, Src};
        _ -> type_error(Re)
    end.

%% re.test(str) → boolean.
regex_test(Re, Str) ->
    {MP, _F, _S} = regex_content(Re),
    case re:run(to_string(Str), MP, [{capture, none}]) of
        match -> true;
        nomatch -> false
    end.

%% re.source / re.flags.
regex_source(Re) ->
    {_MP, _F, S} = regex_content(Re),
    S.
regex_flags(Re) ->
    {_MP, F, _S} = regex_content(Re),
    F.

%% str.match(re) → array of matches (global) or [full, groups…] (non-global), else null.
str_match(Str, Re) ->
    {MP, Flags, _S} = regex_content(Re),
    S = to_string(Str),
    case has_flag(Flags, $g) of
        true ->
            case re:run(S, MP, [global, {capture, first, binary}]) of
                {match, Ms} -> new_array([M || [M] <- Ms]);
                match -> new_array([]);
                nomatch -> null
            end;
        false ->
            case re:run(S, MP, [{capture, all, binary}]) of
                {match, Groups} -> new_array(Groups);
                nomatch -> null
            end
    end.

%% str.replace / str.split when the pattern is a regex.
str_replace_regex(Str, Re, Repl) ->
    {MP, Flags, _S} = regex_content(Re),
    ReplErl = js_repl_to_erl(to_string(Repl)),
    Opts =
        case has_flag(Flags, $g) of
            true -> [global, {return, binary}];
            false -> [{return, binary}]
        end,
    re:replace(to_string(Str), MP, ReplErl, Opts).

str_split_regex(Str, Re) ->
    {MP, _Flags, _S} = regex_content(Re),
    new_array(re:split(to_string(Str), MP, [{return, binary}])).

%% Translate a JS replacement string's `$1`/`$&`/`$$` into `re:replace`'s `\1`/`\0`/`$`.
js_repl_to_erl(Bin) -> iolist_to_binary(repl_scan(Bin)).
repl_scan(<<"$$", R/binary>>) -> [$$ | repl_scan(R)];
repl_scan(<<"$&", R/binary>>) -> [<<"\\0">> | repl_scan(R)];
repl_scan(<<$$, D, R/binary>>) when D >= $0, D =< $9 -> [$\\, D | repl_scan(R)];
repl_scan(<<C, R/binary>>) -> [C | repl_scan(R)];
repl_scan(<<>>) -> [].

%% Apply a JS function value to a runtime-length argument list (behind call spread
%% `f(...args)`); arity-adaptive like a callback.
apply_fn(F, Args) when is_function(F) -> call_cb(F, Args);
apply_fn(F, _Args) -> not_callable(F).

%% The array's elements as a plain Erlang list (behind call spread into a variadic
%% sink like `console.log(...xs)` or building a spread argument list).
array_to_list(Recv) ->
    {Len, Map} = arr_content(Recv),
    arr_list(Len, Map).

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

%% reduceRight(fn, init?) — fold from the last element to the first; the callback
%% receives (acc, element, index, array) with the true descending index.
array_reduce_right(Recv, Fn, Init) ->
    {Len, Map} = arr_content(Recv),
    arredr(Fn, Recv, redr_pairs(Len, Map), Init).
array_reduce_right1(Recv, Fn) ->
    {Len, Map} = arr_content(Recv),
    case redr_pairs(Len, Map) of
        [] -> type_error(Recv);
        [{_, First} | Rest] -> arredr(Fn, Recv, Rest, First)
    end.

%% {index, element} pairs from the last index down to 0.
redr_pairs(0, _Map) -> [];
redr_pairs(Len, Map) ->
    [{I, maps:get(I, Map, undefined)} || I <- lists:seq(Len - 1, 0, -1)].

arredr(_, _, [], Acc) -> Acc;
arredr(Fn, Arr, [{I, X} | Rest], Acc) ->
    arredr(Fn, Arr, Rest, call_cb(Fn, [Acc, X, I, Arr])).

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

%% includes → a JS boolean atom. Unlike indexOf (which uses ===), Array.includes
%% uses SameValueZero, so `[NaN].includes(NaN)` is true.
array_includes(Recv, X) when is_binary(Recv) -> array_index_of(Recv, X) =/= -1;
array_includes(Recv, X) ->
    {Len, Map} = arr_content(Recv),
    a_incl(arr_list(Len, Map), X).
a_incl([], _) -> false;
a_incl([E | Es], X) ->
    case same_value_zero(E, X) of
        true -> true;
        false -> a_incl(Es, X)
    end.

%% SameValueZero: like ===, except NaN equals NaN (+0/-0 already equate under
%% strict_eq). Used by Array.prototype.includes.
same_value_zero(A, B) ->
    case is_nan_val(A) andalso is_nan_val(B) of
        true -> true;
        false -> strict_eq(A, B) =:= 1
    end.

is_nan_val(js_nan) -> true;
is_nan_val(nan) -> true;
is_nan_val(_) -> false.

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
str_split(Str, Sep) when is_reference(Sep) ->
    case is_regex(Sep) of
        true -> str_split_regex(Str, Sep);
        false -> new_array([Str])
    end;
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
str_replace(Str, Search, Repl) when is_reference(Search) ->
    case is_regex(Search) of
        true -> str_replace_regex(Str, Search, Repl);
        false -> str_replace_plain(Str, Search, Repl)
    end;
str_replace(Str, Search, Repl) ->
    str_replace_plain(Str, Search, Repl).

str_replace_plain(Str, Search, Repl) ->
    ReplBin = to_string(Repl),
    case to_string(Search) of
        <<>> ->
            <<(expand_repl(ReplBin, <<>>, <<>>, Str))/binary, Str/binary>>;
        SearchBin ->
            case binary:match(Str, SearchBin) of
                nomatch ->
                    Str;
                {Pos, Len} ->
                    Before = binary:part(Str, 0, Pos),
                    Match = binary:part(Str, Pos, Len),
                    After = binary:part(Str, Pos + Len, byte_size(Str) - Pos - Len),
                    Expanded = expand_repl(ReplBin, Match, Before, After),
                    <<Before/binary, Expanded/binary, After/binary>>
            end
    end.

%% Expand the `$` substitution patterns JS applies in a STRING replacement:
%% `$$`→`$`, `$&`→the match, `` $` ``→text before the match, `$'`→text after.
%% `$n` and any other `$x` are left literal (numbered groups need a regex).
expand_repl(Repl, Match, Before, After) ->
    expand_repl(Repl, Match, Before, After, <<>>).
expand_repl(<<>>, _, _, _, Acc) ->
    Acc;
expand_repl(<<$$, C, R/binary>>, M, B, A, Acc) ->
    Sub =
        case C of
            $$ -> <<$$>>;
            $& -> M;
            % `$\`` — text before the match
            96 -> B;
            $' -> A;
            _ -> <<$$, C>>
        end,
    expand_repl(R, M, B, A, <<Acc/binary, Sub/binary>>);
expand_repl(<<C, R/binary>>, M, B, A, Acc) ->
    expand_repl(R, M, B, A, <<Acc/binary, C>>).

%% str.replaceAll(search, repl) — every occurrence, with the same `$` expansion
%% (`` $` ``/`$'` reference the whole original string, tracked via the offset).
str_replace_all(Str, Search, Repl) ->
    ReplBin = to_string(Repl),
    case to_string(Search) of
        <<>> -> Str;
        SearchBin -> ra_expand(Str, SearchBin, ReplBin, Str, 0, <<>>)
    end.

ra_expand(Rest, SearchBin, ReplBin, Full, Off, Acc) ->
    case binary:match(Rest, SearchBin) of
        nomatch ->
            <<Acc/binary, Rest/binary>>;
        {Pos, Len} ->
            Skipped = binary:part(Rest, 0, Pos),
            Match = binary:part(Rest, Pos, Len),
            AbsStart = Off + Pos,
            Before = binary:part(Full, 0, AbsStart),
            After = binary:part(Full, AbsStart + Len, byte_size(Full) - AbsStart - Len),
            Expanded = expand_repl(ReplBin, Match, Before, After),
            TailStart = Pos + Len,
            Tail = binary:part(Rest, TailStart, byte_size(Rest) - TailStart),
            ra_expand(
                Tail,
                SearchBin,
                ReplBin,
                Full,
                AbsStart + Len,
                <<Acc/binary, Skipped/binary, Expanded/binary>>
            )
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

%% parseFloat(str) — the value of the longest leading substring that is a
%% decimal float literal (sign, digits, optional fraction, optional exponent),
%% or Infinity; trailing garbage is ignored; NaN if no such prefix exists.
%% Unlike string:to_float this accepts "1e3" and ".5".
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
            case pf_prefix(Str) of
                <<>> ->
                    js_nan;
                Tok ->
                    try
                        binary_to_integer(Tok)
                    catch
                        error:badarg ->
                            try
                                binary_to_float(float_fixup(Tok))
                            catch
                                error:badarg -> js_nan
                            end
                    end
            end
    end.

%% Longest leading decimal-float literal of `Str` (empty ⇒ no number).
pf_prefix(Str) ->
    {Sign, R0} =
        case Str of
            <<"+", R/binary>> -> {<<>>, R};
            <<"-", R/binary>> -> {<<"-">>, R};
            _ -> {<<>>, Str}
        end,
    {IntPart, R1} = pf_digits(R0, <<>>),
    {FracPart, R2} =
        case R1 of
            <<".", R1b/binary>> ->
                {FD, R1c} = pf_digits(R1b, <<>>),
                {<<".", FD/binary>>, R1c};
            _ ->
                {<<>>, R1}
        end,
    HasDigit = IntPart =/= <<>> orelse (FracPart =/= <<>> andalso FracPart =/= <<".">>),
    case HasDigit of
        false ->
            <<>>;
        true ->
            {ExpPart, _} = pf_exp(R2),
            <<Sign/binary, IntPart/binary, FracPart/binary, ExpPart/binary>>
    end.

pf_digits(<<C, R/binary>>, Acc) when C >= $0, C =< $9 -> pf_digits(R, <<Acc/binary, C>>);
pf_digits(R, Acc) -> {Acc, R}.

%% An exponent (`e`/`E`, optional sign, ≥1 digit); if no digit follows, the `e`
%% is not part of the number, so nothing is consumed.
pf_exp(<<E, R/binary>>) when E =:= $e; E =:= $E ->
    {ESign, R1} =
        case R of
            <<"+", Rp/binary>> -> {<<"+">>, Rp};
            <<"-", Rp/binary>> -> {<<"-">>, Rp};
            _ -> {<<>>, R}
        end,
    case pf_digits(R1, <<>>) of
        {<<>>, _} -> {<<>>, <<E, R/binary>>};
        {Ds, R2} -> {<<E, ESign/binary, Ds/binary>>, R2}
    end;
pf_exp(R) ->
    {<<>>, R}.

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

%% keys are listed WITHOUT invoking getters; values/entries resolve accessors.
object_keys(O) -> new_array([K || {K, _} <- obj_pairs(O)]).
object_values(O) -> new_array([resolve_get(V) || {_, V} <- obj_pairs(O)]).
object_entries(O) ->
    new_array([new_array([K, resolve_get(V)]) || {K, V} <- obj_pairs(O)]).

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
    lists:foreach(
        fun({K, V}) -> set_prop(Target, K, resolve_get(V)) end, obj_pairs(Source)
    ),
    Target;
object_assign_into(Target, _Source) ->
    Target.

%% Object-rest destructuring `{ a, ...rest } = obj`: a NEW object with `obj`'s own
%% enumerable properties except those named in `Excluded` (an array of key
%% strings). Getters are invoked (the copied value is a data property).
object_rest(Obj, Excluded) when is_reference(Obj) ->
    ExKeys = excluded_keys(Excluded),
    Rest = new_object(),
    lists:foreach(
        fun({K, V}) ->
            case lists:member(K, ExKeys) of
                true -> ok;
                false -> set_prop(Rest, K, resolve_get(V))
            end
        end,
        obj_pairs(Obj)
    ),
    Rest;
object_rest(_Obj, _Excluded) ->
    new_object().

excluded_keys(Excluded) when is_reference(Excluded) ->
    {Len, Map} = arr_content(Excluded),
    [to_string(K) || K <- arr_list(Len, Map)];
excluded_keys(_) ->
    [].

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
esc_byte($\b) -> <<"\\b">>;
esc_byte($\f) -> <<"\\f">>;
%% Any other control character (< U+0020) must be a \u00XX escape — a raw
%% control byte inside a JSON string is invalid JSON. Non-ASCII UTF-8 bytes
%% (>= 0x80) are left untouched: JSON does not require them to be escaped.
esc_byte(B) when B < 16#20 -> unicode_escape(B);
esc_byte(B) -> <<B>>.

%% Lower-case \u00XX escape for a control byte, matching JSON.stringify output.
unicode_escape(B) ->
    H = string:lowercase(integer_to_binary(B, 16)),
    Pad = binary:copy(<<"0">>, 4 - byte_size(H)),
    <<"\\u", Pad/binary, H/binary>>.

json_ref(Ref) ->
    case erlang:get(?CELL_KEY(Ref)) of
        {js_array, Len, Map} ->
            json_arr(arr_list(Len, Map));
        M when is_map(M) ->
            %% resolve getters so serialization sees the produced value.
            json_obj([{K, resolve_get(V)} || {K, V} <- maps:to_list(M)]);
        _ ->
            skip
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
json_pstr(<<$\\, $b, R/binary>>, Acc) -> json_pstr(R, [$\b | Acc]);
json_pstr(<<$\\, $f, R/binary>>, Acc) -> json_pstr(R, [$\f | Acc]);
%% A high surrogate followed by a low surrogate is one astral code point;
%% decoding each \u escape independently would corrupt e.g. an emoji.
json_pstr(<<$\\, $u, H1:4/binary, $\\, $u, H2:4/binary, R/binary>>, Acc) ->
    case {hex4(H1), hex4(H2)} of
        {C1, C2} when
            is_integer(C1),
            is_integer(C2),
            C1 >= 16#D800,
            C1 =< 16#DBFF,
            C2 >= 16#DC00,
            C2 =< 16#DFFF
        ->
            CP = 16#10000 + (C1 - 16#D800) * 16#400 + (C2 - 16#DC00),
            json_pstr(R, [CP | Acc]);
        {C1, _} when is_integer(C1) ->
            %% not a valid pair: keep the first unit, re-scan the second escape.
            json_pstr(<<$\\, $u, H2/binary, R/binary>>, [C1 | Acc]);
        _ ->
            error
    end;
json_pstr(<<$\\, $u, H:4/binary, R/binary>>, Acc) ->
    case hex4(H) of
        error -> error;
        C -> json_pstr(R, [C | Acc])
    end;
json_pstr(<<C/utf8, R/binary>>, Acc) -> json_pstr(R, [C | Acc]);
json_pstr(_, _) -> error.

%% Parse exactly four hex digits to an integer, or `error` on a non-hex digit.
hex4(H) ->
    try binary_to_integer(H, 16) of
        I -> I
    catch
        error:badarg -> error
    end.

json_pnum(B) ->
    {Tok, Rest} = json_num_tok(B, []),
    case json_num_val(Tok) of
        error -> error;
        V -> {ok, V, Rest}
    end.

%% Parse a JSON number token to an integer or float. Unlike string:to_float,
%% this accepts exponent forms without a decimal point ("1e3") and leading-dot
%% forms by normalising through float_fixup, so `JSON.parse("1e3")` === 1000.
json_num_val(Tok) ->
    try
        binary_to_integer(Tok)
    catch
        error:badarg ->
            try
                binary_to_float(float_fixup(Tok))
            catch
                error:badarg -> error
            end
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

%% `]` closes the array only at the start or after a value — never straight
%% after a comma, so a trailing comma (`[1,]`) is a SyntaxError, per the JSON
%% grammar. After a comma another value is required (json_parr_val).
json_parr(<<$], R/binary>>, Acc) ->
    {ok, new_array(lists:reverse(Acc)), R};
json_parr(B, Acc) ->
    json_parr_val(B, Acc).

json_parr_val(B, Acc) ->
    case json_val(B) of
        {ok, V, R} ->
            case json_ws(R) of
                <<$,, R2/binary>> -> json_parr_val(json_ws(R2), [V | Acc]);
                <<$], R2/binary>> -> {ok, new_array(lists:reverse([V | Acc])), R2};
                _ -> error
            end;
        error ->
            error
    end.

%% `}` closes the object only at the start or after a member — never straight
%% after a comma, so a trailing comma (`{"a":1,}`) is a SyntaxError. After a
%% comma another `"key": value` member is required (json_pobj_member).
json_pobj(<<$}, R/binary>>, Obj) ->
    {ok, Obj, R};
json_pobj(B, Obj) ->
    json_pobj_member(B, Obj).

json_pobj_member(<<$", R/binary>>, Obj) ->
    case json_pstr(R, []) of
        {ok, Key, R1} ->
            case json_ws(R1) of
                <<$:, R2/binary>> ->
                    case json_val(json_ws(R2)) of
                        {ok, V, R3} ->
                            set_prop(Obj, Key, V),
                            case json_ws(R3) of
                                <<$,, R4/binary>> -> json_pobj_member(json_ws(R4), Obj);
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
json_pobj_member(_, _) ->
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
